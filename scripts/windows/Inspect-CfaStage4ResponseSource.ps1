#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [ValidateRange(15,600)][int]$StatementTimeoutSeconds = 120,
    [string]$RepoRoot = '',
    [string]$OutputRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedAf001Sha256 = '569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAf001Rows = 1059
$ExpectedEligibleRows = 1058
$ExpectedEligibleBaseAssets = 435
$ExpectedMarketRows = 14055089L
$ExpectedMarketPairs = 1058L
$ExpectedMarketMinUtc = '2025-04-01 00:00:00+00'
$ExpectedMarketMaxUtc = '2025-06-30 23:59:00+00'

function Find-Psql {
    $cmd = Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    $found = @(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    if ($found.Count -eq 0) { throw 'psql.exe could not be found.' }
    return $found[0].FullName
}

function Invoke-PsqlText {
    param(
        [Parameter(Mandatory=$true)][string]$PsqlExe,
        [Parameter(Mandatory=$true)][string]$Database,
        [Parameter(Mandatory=$true)][string]$Sql
    )
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $stdout = @(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2> $errFile)
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            $stderr = ((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        }
        $text = ($stdout | ForEach-Object { if ($null -ne $_) { [string]$_ } }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            $message = if ([string]::IsNullOrWhiteSpace($stderr)) { $text } else { $stderr }
            throw "psql failed for database '$Database' (exit $exitCode).`n$message"
        }
        return $text
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
}

function Invoke-PsqlCsv {
    param(
        [Parameter(Mandatory=$true)][string]$PsqlExe,
        [Parameter(Mandatory=$true)][string]$Database,
        [Parameter(Mandatory=$true)][string]$Query
    )
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Convert-CsvText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text | ConvertFrom-Csv)
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory=$true)][string]$Path,[AllowNull()][string]$Content)
    if ($null -eq $Content) { $Content = '' }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Get-Sha {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Parse-BoolStrict {
    param([object]$Value,[string]$Label)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return $true }
    if ($text -eq 'false') { return $false }
    throw "Malformed boolean for ${Label}: '$Value'"
}

function Escape-SqlLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace("'","''")
}

function Get-AfPopulation {
    param([object[]]$Rows)
    if ($Rows.Count -ne $ExpectedAf001Rows) { throw "AF-001 row count mismatch: $($Rows.Count), expected $ExpectedAf001Rows." }
    $required = @('source_member_ordinal','pair_token_opaque','base_asset_id','quote_asset_id','base_exchange_symbol','quote_exchange_symbol','research_eligible')
    $props = @($Rows[0].PSObject.Properties.Name)
    foreach ($name in $required) { if ($props -notcontains $name) { throw "AF-001 required column missing: $name" } }

    $eligible = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        if (Parse-BoolStrict $r.research_eligible "AF-001 $($r.pair_token_opaque) research_eligible") { [void]$eligible.Add($r) }
    }
    if ($eligible.Count -ne $ExpectedEligibleRows) { throw "AF-001 eligible row count mismatch: $($eligible.Count), expected $ExpectedEligibleRows." }

    $eligibleBases = @($eligible | Select-Object -ExpandProperty base_asset_id -Unique)
    if ($eligibleBases.Count -ne $ExpectedEligibleBaseAssets) { throw "AF-001 eligible base count mismatch: $($eligibleBases.Count), expected $ExpectedEligibleBaseAssets." }

    $usd = @($eligible | Where-Object { ([string]$_.quote_exchange_symbol).Trim() -ceq 'USD' })
    $duplicates = @($usd | Group-Object { ([string]$_.base_asset_id).Trim() } | Where-Object Count -gt 1 | ForEach-Object {
        [pscustomobject]@{
            base_asset_id = $_.Name
            eligible_usd_pair_count = $_.Count
            pair_tokens = (@($_.Group | ForEach-Object { [string]$_.pair_token_opaque }) -join '|')
            source_member_ordinals = (@($_.Group | ForEach-Object { [string]$_.source_member_ordinal }) -join '|')
        }
    } | Sort-Object base_asset_id)

    $quotes = @($eligible | Group-Object { ([string]$_.quote_exchange_symbol).Trim() } | ForEach-Object {
        [pscustomobject]@{
            quote_exchange_symbol = $_.Name
            eligible_pair_rows = $_.Count
            distinct_base_assets = @($_.Group | Select-Object -ExpandProperty base_asset_id -Unique).Count
        }
    } | Sort-Object quote_exchange_symbol)

    return [pscustomobject]@{
        eligible = @($eligible.ToArray())
        eligible_base_assets = $eligibleBases
        usd = $usd
        duplicate_usd_bases = $duplicates
        quote_coverage = $quotes
    }
}

function Invoke-SelfTest {
    $fake = New-Object System.Collections.ArrayList
    for ($i=1; $i -le $ExpectedAf001Rows; $i++) {
        $base = if ($i -le $ExpectedEligibleBaseAssets) { 'A' + $i } else { 'A' + ((($i - 1) % $ExpectedEligibleBaseAssets) + 1) }
        $eligible = ($i -le $ExpectedEligibleRows)
        $quote = if (($i % 3) -eq 0) { 'USD' } elseif (($i % 3) -eq 1) { 'EUR' } else { 'XBT' }
        [void]$fake.Add([pscustomobject]@{
            source_member_ordinal=$i
            pair_token_opaque=('PAIR'+$i)
            base_asset_id=$base
            quote_asset_id=('Q'+$quote)
            base_exchange_symbol=$base
            quote_exchange_symbol=$quote
            research_eligible=if($eligible){'True'}else{'False'}
        })
    }
    # The generic fabricated data cannot satisfy the exact 435 eligible-base count because
    # the single ineligible final row may be the only occurrence of its synthetic base.
    # Test the low-level invariants separately instead of calling Get-AfPopulation.
    if (-not (Parse-BoolStrict 'True' 'selftest')) { throw 'Boolean True parsing failed.' }
    if (Parse-BoolStrict 'False' 'selftest') { throw 'Boolean False parsing failed.' }
    if ((Escape-SqlLiteral "O'HARE") -ne "O''HARE") { throw 'SQL literal escaping failed.' }
    $probe = @(
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal=1;quote_exchange_symbol='USD'},
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD2';source_member_ordinal=2;quote_exchange_symbol='USD'},
        [pscustomobject]@{base_asset_id='B';pair_token_opaque='BEUR';source_member_ordinal=3;quote_exchange_symbol='EUR'}
    )
    $dup = @($probe | Where-Object quote_exchange_symbol -eq 'USD' | Group-Object base_asset_id | Where-Object Count -gt 1)
    if ($dup.Count -ne 1 -or $dup[0].Name -ne 'A') { throw 'USD duplicate-base detection failed.' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

$oldPassword = $env:PGPASSWORD
$oldPgOptions = $env:PGOPTIONS
$bstr = [IntPtr]::Zero

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $OutputRoot = Join-Path $documents 'CFA-local\stage4-response-source'
    }
    $runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $stage3Contract = Join-Path $RepoRoot 'docs\evidence\stage3-news-matching-v3-contract.md'
    if (-not (Test-Path -LiteralPath $stage3Contract -PathType Leaf)) { throw 'Frozen Stage 3 contract missing.' }
    $stage3Text = Get-Content -LiteralPath $stage3Contract -Raw
    if ($stage3Text -notmatch 'STAGE3_FROZEN' -or $stage3Text -notmatch 'CFA-S3-006' -or $stage3Text -notmatch 'Freeze news matching\s*\|\s*PASS') {
        throw 'Stage 3 frozen entry gate is not evidenced as PASS in the current contract.'
    }

    $afPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    if (-not (Test-Path -LiteralPath $afPath -PathType Leaf)) { throw 'AF-001 is missing from the repository.' }
    $afSha = Get-Sha $afPath
    if ($afSha -ne $ExpectedAf001Sha256) { throw "AF-001 SHA-256 mismatch: $afSha" }
    $afRows = @(Import-Csv -LiteralPath $afPath)
    $population = Get-AfPopulation $afRows

    $quotePath = Join-Path $runDir 'stage4-quote-coverage.csv'
    $usdPath = Join-Path $runDir 'stage4-usd-pair-candidates.csv'
    $dupPath = Join-Path $runDir 'stage4-usd-duplicate-bases.csv'
    @($population.quote_coverage) | Export-Csv -LiteralPath $quotePath -NoTypeInformation -Encoding UTF8
    @($population.usd | Select-Object source_member_ordinal,pair_token_opaque,base_asset_id,quote_asset_id,base_exchange_symbol,quote_exchange_symbol,resolution_status,resolution_method,pair_status) | Export-Csv -LiteralPath $usdPath -NoTypeInformation -Encoding UTF8
    if (@($population.duplicate_usd_bases).Count -gt 0) { @($population.duplicate_usd_bases) | Export-Csv -LiteralPath $dupPath -NoTypeInformation -Encoding UTF8 }
    else { 'base_asset_id,eligible_usd_pair_count,pair_tokens,source_member_ordinals' | Set-Content -LiteralPath $dupPath -Encoding UTF8 }

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    Write-Host "AF-001 SHA-256: $afSha"
    Write-Host ("Eligible direct-USD pair rows: {0}" -f @($population.usd).Count)
    Write-Host ("Distinct direct-USD base assets: {0}" -f @($population.usd | Select-Object -ExpandProperty base_asset_id -Unique).Count)
    Write-Host ("Duplicate direct-USD base identities: {0}" -f @($population.duplicate_usd_bases).Count)

    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $timeoutMs = $StatementTimeoutSeconds * 1000
    $env:PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=$timeoutMs"

    $version = Invoke-PsqlText -PsqlExe $psql -Database 'asrp' -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $columnsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT
    ordinal_position,
    column_name,
    data_type,
    udt_name,
    is_nullable,
    numeric_precision,
    numeric_scale,
    datetime_precision
FROM information_schema.columns
WHERE table_schema = 'asrp'
  AND table_name = 'q2_market_1m_observations'
ORDER BY ordinal_position
'@
    $columnsPath = Join-Path $runDir 'stage4-market-columns.csv'
    Write-Utf8NoBom $columnsPath ($columnsCsv + [Environment]::NewLine)
    $columns = @(Convert-CsvText $columnsCsv)
    if ($columns.Count -eq 0) { throw 'Market relation schema query returned no columns.' }

    $summaryCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT
    count(*)::bigint AS exact_rows,
    count(DISTINCT pair_token_opaque)::bigint AS pair_token_count,
    min(candle_start_utc) AS min_candle_start_utc,
    max(candle_start_utc) AS max_candle_start_utc,
    count(*) FILTER (WHERE NOT in_source_window)::bigint AS outside_source_window_rows,
    count(*) FILTER (WHERE NOT minute_aligned)::bigint AS non_minute_aligned_rows,
    count(*) FILTER (WHERE NOT canonical_eligible)::bigint AS canonical_ineligible_rows,
    count(*) FILTER (WHERE cardinality(quality_flags) > 0)::bigint AS rows_with_quality_flags,
    count(*) FILTER (WHERE duplicate_class IS NOT NULL)::bigint AS rows_with_duplicate_class
FROM asrp.q2_market_1m_observations
'@
    $marketSummaryPath = Join-Path $runDir 'stage4-market-summary.csv'
    Write-Utf8NoBom $marketSummaryPath ($summaryCsv + [Environment]::NewLine)
    $marketSummaryRows = @(Convert-CsvText $summaryCsv)
    if ($marketSummaryRows.Count -ne 1) { throw 'Market summary did not return exactly one row.' }
    $ms = $marketSummaryRows[0]
    if ([long]$ms.exact_rows -ne $ExpectedMarketRows) { throw 'Market row count differs from frozen Stage 1 evidence.' }
    if ([long]$ms.pair_token_count -ne $ExpectedMarketPairs) { throw 'Market pair count differs from frozen Stage 1 evidence.' }
    if ([long]$ms.outside_source_window_rows -ne 0 -or [long]$ms.non_minute_aligned_rows -ne 0 -or [long]$ms.canonical_ineligible_rows -ne 0 -or [long]$ms.rows_with_quality_flags -ne 0 -or [long]$ms.rows_with_duplicate_class -ne 0) {
        throw 'Market source integrity differs from frozen Stage 1 evidence.'
    }

    $sampleCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT to_jsonb(t)::text AS row_json
FROM (
    SELECT *
    FROM asrp.q2_market_1m_observations
    ORDER BY candle_start_utc, pair_token_opaque
    LIMIT 12
) t
'@
    $samplePath = Join-Path $runDir 'stage4-market-sample.csv'
    Write-Utf8NoBom $samplePath ($sampleCsv + [Environment]::NewLine)

    if (@($population.usd).Count -eq 0) { throw 'AF-001 contains no eligible direct-USD pairs.' }
    $valueRows = New-Object System.Collections.ArrayList
    foreach ($r in @($population.usd)) {
        $base = Escape-SqlLiteral ([string]$r.base_asset_id)
        $pair = Escape-SqlLiteral ([string]$r.pair_token_opaque)
        [void]$valueRows.Add("('$base','$pair')")
    }
    $valuesSql = @($valueRows.ToArray()) -join ",`n        "
    $coverageQuery = @"
WITH usd_pairs(base_asset_id,pair_token_opaque) AS (
    VALUES
        $valuesSql
), coverage AS (
    SELECT
        u.base_asset_id,
        u.pair_token_opaque,
        count(m.pair_token_opaque)::bigint AS exact_rows,
        min(m.candle_start_utc) AS min_candle_start_utc,
        max(m.candle_start_utc) AS max_candle_start_utc,
        count(DISTINCT (m.candle_start_utc AT TIME ZONE 'UTC')::date)::bigint AS distinct_utc_days,
        count(DISTINCT (m.candle_start_utc AT TIME ZONE 'UTC')::date) FILTER (
            WHERE (m.candle_start_utc AT TIME ZONE 'UTC')::time = time '00:00:00'
        )::bigint AS utc_days_with_0000,
        count(DISTINCT (m.candle_start_utc AT TIME ZONE 'UTC')::date) FILTER (
            WHERE (m.candle_start_utc AT TIME ZONE 'UTC')::time = time '23:59:00'
        )::bigint AS utc_days_with_2359,
        count(*) FILTER (WHERE m.pair_token_opaque IS NOT NULL AND NOT m.canonical_eligible)::bigint AS canonical_ineligible_rows,
        count(*) FILTER (WHERE m.pair_token_opaque IS NOT NULL AND cardinality(m.quality_flags) > 0)::bigint AS quality_flag_rows,
        count(*) FILTER (WHERE m.pair_token_opaque IS NOT NULL AND m.duplicate_class IS NOT NULL)::bigint AS duplicate_class_rows
    FROM usd_pairs u
    LEFT JOIN asrp.q2_market_1m_observations m
      ON m.pair_token_opaque = u.pair_token_opaque
    GROUP BY u.base_asset_id,u.pair_token_opaque
)
SELECT * FROM coverage ORDER BY base_asset_id,pair_token_opaque
"@
    $coverageCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query $coverageQuery
    $coveragePath = Join-Path $runDir 'stage4-usd-market-coverage.csv'
    Write-Utf8NoBom $coveragePath ($coverageCsv + [Environment]::NewLine)
    $coverageRows = @(Convert-CsvText $coverageCsv)
    if ($coverageRows.Count -ne @($population.usd).Count) { throw 'USD market coverage row count does not reconcile to AF-001 USD candidates.' }

    $zeroMarket = @($coverageRows | Where-Object { [long]$_.exact_rows -eq 0 })
    $coverageIntegrityFailures = @($coverageRows | Where-Object { [long]$_.canonical_ineligible_rows -ne 0 -or [long]$_.quality_flag_rows -ne 0 -or [long]$_.duplicate_class_rows -ne 0 })
    $priceLikeColumns = @($columns | Where-Object { ([string]$_.column_name) -match '(?i)(open|high|low|close|price|vwap|volume|trade)' } | Select-Object -ExpandProperty column_name)

    $summary = [ordered]@{
        status = 'VALIDATION_CANDIDATE'
        stage = 'CFA_STAGE_4'
        inspection = 'RESPONSE_SOURCE_SCHEMA_AND_USD_POPULATION'
        stage3_entry = [ordered]@{ contract_path=$stage3Contract; contract_sha256=(Get-Sha $stage3Contract); gate_CFA_S4_001='PASS' }
        af001 = [ordered]@{
            path=$afPath; sha256=$afSha; rows=$afRows.Count; eligible_rows=@($population.eligible).Count; eligible_base_assets=@($population.eligible_base_assets).Count
            eligible_usd_pair_rows=@($population.usd).Count; eligible_usd_base_assets=@($population.usd | Select-Object -ExpandProperty base_asset_id -Unique).Count; duplicate_usd_base_assets=@($population.duplicate_usd_bases).Count
        }
        market = [ordered]@{
            database='asrp'; relation='asrp.q2_market_1m_observations'; exact_rows=[long]$ms.exact_rows; pair_token_count=[long]$ms.pair_token_count
            min_candle_start_utc=[string]$ms.min_candle_start_utc; max_candle_start_utc=[string]$ms.max_candle_start_utc; schema_column_count=$columns.Count; price_like_column_names=$priceLikeColumns
        }
        usd_market = [ordered]@{
            coverage_rows=$coverageRows.Count; zero_market_pair_rows=$zeroMarket.Count; integrity_failure_pairs=$coverageIntegrityFailures.Count
            min_distinct_utc_days=if($coverageRows.Count -gt 0){[long](($coverageRows | Measure-Object -Property distinct_utc_days -Minimum).Minimum)}else{$null}
            max_distinct_utc_days=if($coverageRows.Count -gt 0){[long](($coverageRows | Measure-Object -Property distinct_utc_days -Maximum).Maximum)}else{$null}
            min_days_with_2359=if($coverageRows.Count -gt 0){[long](($coverageRows | Measure-Object -Property utc_days_with_2359 -Minimum).Minimum)}else{$null}
            max_days_with_2359=if($coverageRows.Count -gt 0){[long](($coverageRows | Measure-Object -Property utc_days_with_2359 -Maximum).Maximum)}else{$null}
        }
        outputs = [ordered]@{
            market_columns=$columnsPath; market_columns_sha256=(Get-Sha $columnsPath)
            market_sample=$samplePath; market_sample_sha256=(Get-Sha $samplePath)
            market_summary=$marketSummaryPath; market_summary_sha256=(Get-Sha $marketSummaryPath)
            quote_coverage=$quotePath; quote_coverage_sha256=(Get-Sha $quotePath)
            usd_pairs=$usdPath; usd_pairs_sha256=(Get-Sha $usdPath)
            usd_duplicate_bases=$dupPath; usd_duplicate_bases_sha256=(Get-Sha $dupPath)
            usd_market_coverage=$coveragePath; usd_market_coverage_sha256=(Get-Sha $coveragePath)
        }
        gates = [ordered]@{
            'CFA-S4-001'='PASS'
            'CFA-S4-002'='UNVERIFIED'
            'CFA-S4-003'='UNVERIFIED'
            'CFA-S4-004'='UNVERIFIED'
            'CFA-S4-005'='BLOCKED'
            'CFA-S4-006'='BLOCKED'
        }
        next_action = 'Review exact market columns/sample and direct-USD coverage. Do not compute or freeze responses until price semantics and daily-close boundary are explicitly approved.'
    }
    $summaryPath = Join-Path $runDir 'stage4-response-source-inspection.json'
    Write-Utf8NoBom $summaryPath (($summary | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 4 RESPONSE SOURCE INSPECTION: VALIDATION CANDIDATE'
    Write-Host ("Market schema columns: {0}" -f $columns.Count)
    Write-Host ("Price-like column names: {0}" -f ($priceLikeColumns -join ', '))
    Write-Host ("Eligible direct-USD pair rows: {0}" -f @($population.usd).Count)
    Write-Host ("Distinct direct-USD base assets: {0}" -f @($population.usd | Select-Object -ExpandProperty base_asset_id -Unique).Count)
    Write-Host ("Duplicate direct-USD base identities: {0}" -f @($population.duplicate_usd_bases).Count)
    Write-Host ("Direct-USD pairs with zero market rows: {0}" -f $zeroMarket.Count)
    Write-Host ("Direct-USD market integrity failures: {0}" -f $coverageIntegrityFailures.Count)
    Write-Host 'CFA-S4-002 market schema/price semantics: UNVERIFIED'
    Write-Host 'CFA-S4-003 direct-USD response population: UNVERIFIED'
    Write-Host 'CFA-S4-006 freeze responses: BLOCKED'
    Write-Host ("Candidate receipt: {0}" -f $summaryPath)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 4 RESPONSE SOURCE INSPECTION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
}
