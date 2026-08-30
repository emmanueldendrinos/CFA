#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [ValidateRange(30,900)][int]$StatementTimeoutSeconds = 300,
    [string]$RepoRoot = '',
    [string]$OutputRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ResponseId = 'RET_USD_1D_LOG'
$ExpectedAf001Sha256 = '569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAf001Rows = 1059
$ExpectedEligibleRows = 1058
$ExpectedEligibleBaseAssets = 435
$ExpectedDirectUsdPairs = 434
$ExpectedDirectUsdBases = 434
$ExpectedMissingDirectUsdBases = 1
$ExpectedMarketRows = 14055089L
$ExpectedMarketPairs = 1058L
$ExpectedMarketMinUtc = '2025-04-01 00:00:00+00'
$ExpectedMarketMaxUtc = '2025-06-30 23:59:00+00'
$Q2Start = [datetime]::SpecifyKind([datetime]'2025-04-01T00:00:00',[DateTimeKind]::Utc)
$Q2EndExclusive = [datetime]::SpecifyKind([datetime]'2025-07-01T00:00:00',[DateTimeKind]::Utc)
$Invariant = [Globalization.CultureInfo]::InvariantCulture

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

function Get-Sha {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory=$true)][string]$Path,[AllowNull()][string]$Content)
    if ($null -eq $Content) { $Content = '' }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Parse-BoolStrict {
    param([object]$Value,[string]$Label)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return $true }
    if ($text -eq 'false') { return $false }
    throw "Malformed boolean for ${Label}: '$Value'"
}

function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $number = 0.0
    if (-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$number)) {
        throw "Malformed numeric value for ${Label}: '$Value'"
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "Non-finite numeric value for ${Label}: '$Value'" }
    return $number
}

function Format-Utc {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)
}

function Stable-Sha256Text {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-AfPopulation {
    param([object[]]$Rows)
    if ($Rows.Count -ne $ExpectedAf001Rows) { throw "AF-001 row count mismatch: $($Rows.Count), expected $ExpectedAf001Rows." }
    $required = @('source_member_ordinal','pair_token_opaque','base_asset_id','quote_exchange_symbol','research_eligible')
    foreach ($name in $required) {
        if (@($Rows[0].PSObject.Properties.Name) -notcontains $name) { throw "AF-001 required column missing: $name" }
    }
    $eligible = @($Rows | Where-Object { Parse-BoolStrict $_.research_eligible "AF-001 $($_.pair_token_opaque) research_eligible" })
    if ($eligible.Count -ne $ExpectedEligibleRows) { throw "AF-001 eligible row count mismatch: $($eligible.Count), expected $ExpectedEligibleRows." }
    $eligibleBases = @($eligible | Select-Object -ExpandProperty base_asset_id -Unique)
    if ($eligibleBases.Count -ne $ExpectedEligibleBaseAssets) { throw "AF-001 eligible base count mismatch: $($eligibleBases.Count), expected $ExpectedEligibleBaseAssets." }
    $usd = @($eligible | Where-Object { ([string]$_.quote_exchange_symbol).Trim() -ceq 'USD' })
    $usdBases = @($usd | Select-Object -ExpandProperty base_asset_id -Unique)
    $dup = @($usd | Group-Object { ([string]$_.base_asset_id).Trim() } | Where-Object Count -gt 1)
    $missing = @($eligibleBases | Where-Object { $usdBases -notcontains $_ } | Sort-Object)
    if ($usd.Count -ne $ExpectedDirectUsdPairs) { throw "Direct-USD pair count changed: $($usd.Count), expected $ExpectedDirectUsdPairs." }
    if ($usdBases.Count -ne $ExpectedDirectUsdBases) { throw "Direct-USD base count changed: $($usdBases.Count), expected $ExpectedDirectUsdBases." }
    if ($dup.Count -ne 0) { throw "Direct-USD base ambiguity detected for $($dup.Count) base asset(s)." }
    if ($missing.Count -ne $ExpectedMissingDirectUsdBases) { throw "Assets without direct USD changed: $($missing.Count), expected $ExpectedMissingDirectUsdBases." }
    return [pscustomobject]@{ eligible=$eligible; eligible_bases=$eligibleBases; usd=$usd; usd_bases=$usdBases; missing_usd_bases=$missing }
}

function Assert-MarketSchema {
    param([object[]]$Columns)
    if ($Columns.Count -ne 19) { throw "Market schema column count changed: $($Columns.Count), expected 19 from direct Stage 4 observation." }
    $by = @{}
    foreach ($c in $Columns) { $by[[string]$c.column_name] = $c }
    foreach ($name in @('source_member_ordinal','pair_token_opaque','physical_record_number','raw_record_sha256','candle_start_utc','open_price','high_price','low_price','close_price','canonical_eligible','in_source_window','minute_aligned','quality_flags','duplicate_class')) {
        if (-not $by.ContainsKey($name)) { throw "Required market column missing: $name" }
    }
    if ([string]$by['candle_start_utc'].data_type -ne 'timestamp with time zone') { throw "candle_start_utc type is '$($by['candle_start_utc'].data_type)', expected timestamp with time zone." }
    foreach ($name in @('open_price','high_price','low_price','close_price')) {
        if ([string]$by[$name].data_type -notin @('numeric','double precision','real')) { throw "$name is not a supported numeric type: $($by[$name].data_type)" }
    }
    foreach ($name in @('canonical_eligible','in_source_window','minute_aligned')) {
        if ([string]$by[$name].data_type -ne 'boolean') { throw "$name is not boolean: $($by[$name].data_type)" }
    }
    return $by
}

function Build-ResponseRows {
    param([object[]]$ValidCloses)
    $byKey = @{}
    foreach ($c in $ValidCloses) {
        $day = [datetime]$c.response_day
        $key = ([string]$c.base_asset_id) + '|' + $day.ToString('yyyy-MM-dd',$Invariant)
        if ($byKey.ContainsKey($key)) { throw "Duplicate daily close key: $key" }
        $byKey[$key] = $c
    }

    $rows = New-Object System.Collections.ArrayList
    foreach ($c in @($ValidCloses | Sort-Object base_asset_id,response_day)) {
        $day = [datetime]$c.response_day
        if ($day -lt $Q2Start.AddDays(1) -or $day -ge $Q2EndExclusive) { continue }
        $previousDay = $day.AddDays(-1)
        $prevKey = ([string]$c.base_asset_id) + '|' + $previousDay.ToString('yyyy-MM-dd',$Invariant)
        if (-not $byKey.ContainsKey($prevKey)) { continue }
        $p = $byKey[$prevKey]
        $priorPrice = [double]$p.close_price_value
        $currentPrice = [double]$c.close_price_value
        if ($priorPrice -le 0 -or $currentPrice -le 0) { throw "Non-positive close reached response builder for $($c.base_asset_id) / $day" }
        $response = [Math]::Log($currentPrice / $priorPrice)
        if ([double]::IsNaN($response) -or [double]::IsInfinity($response)) { throw "Non-finite response generated for $($c.base_asset_id) / $day" }
        $cutoff = [datetime]::SpecifyKind($day,[DateTimeKind]::Utc)
        $available = $cutoff.AddDays(1)
        [void]$rows.Add([pscustomobject][ordered]@{
            response_id = $ResponseId
            base_asset_id = [string]$c.base_asset_id
            pair_token_opaque = [string]$c.pair_token_opaque
            source_member_ordinal = [string]$c.source_member_ordinal
            response_day_utc = $day.ToString('yyyy-MM-dd',$Invariant)
            predictor_cutoff_utc = Format-Utc $cutoff
            response_window_start_utc = Format-Utc $cutoff
            response_window_end_exclusive_utc = Format-Utc $available
            prior_close_candle_start_utc = [string]$p.candle_start_utc
            current_close_candle_start_utc = [string]$c.candle_start_utc
            prior_close_price_usd = [string]$p.close_price_text
            current_close_price_usd = [string]$c.close_price_text
            response_value_log_return = $response.ToString('R',$Invariant)
            response_available_utc = Format-Utc $available
            prior_physical_record_number = [string]$p.physical_record_number
            current_physical_record_number = [string]$c.physical_record_number
            prior_raw_record_sha256 = [string]$p.raw_record_sha256
            current_raw_record_sha256 = [string]$c.raw_record_sha256
        })
    }
    return @($rows.ToArray())
}

function Invoke-SelfTest {
    $fake = @(
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1';response_day=[datetime]'2025-04-01';candle_start_utc='2025-04-01T23:59:00Z';close_price_text='100';close_price_value=100.0;physical_record_number='1';raw_record_sha256=('a'*64)},
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1';response_day=[datetime]'2025-04-02';candle_start_utc='2025-04-02T23:59:00Z';close_price_text='110';close_price_value=110.0;physical_record_number='2';raw_record_sha256=('b'*64)},
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1';response_day=[datetime]'2025-04-04';candle_start_utc='2025-04-04T23:59:00Z';close_price_text='121';close_price_value=121.0;physical_record_number='3';raw_record_sha256=('c'*64)}
    )
    $r = @(Build-ResponseRows $fake)
    if ($r.Count -ne 1) { throw "Self-test expected exactly one consecutive-day response, observed $($r.Count)." }
    if ($r[0].response_day_utc -ne '2025-04-02') { throw 'Self-test response day mismatch.' }
    $observed = Parse-DoubleStrict $r[0].response_value_log_return 'selftest response'
    if ([Math]::Abs($observed - [Math]::Log(1.1)) -gt 1e-12) { throw 'Self-test log-return formula mismatch.' }
    if ($r[0].predictor_cutoff_utc -ne '2025-04-02T00:00:00Z' -or $r[0].response_available_utc -ne '2025-04-03T00:00:00Z') { throw 'Self-test cutoff/availability timing mismatch.' }
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
        $OutputRoot = Join-Path $documents 'CFA-local\stage4-responses'
    }
    $runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $stage3Contract = Join-Path $RepoRoot 'docs\evidence\stage3-news-matching-v3-contract.md'
    if (-not (Test-Path -LiteralPath $stage3Contract -PathType Leaf)) { throw 'Frozen Stage 3 contract missing.' }
    $stage3Text = Get-Content -LiteralPath $stage3Contract -Raw
    if ($stage3Text -notmatch 'STAGE3_FROZEN' -or $stage3Text -notmatch 'CFA-S3-006' -or $stage3Text -notmatch 'Freeze news matching\s*\|\s*PASS') { throw 'Stage 3 entry gate is not PASS.' }

    $afPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    if ((Get-Sha $afPath) -ne $ExpectedAf001Sha256) { throw 'AF-001 SHA-256 mismatch.' }
    $population = Get-AfPopulation @(Import-Csv -LiteralPath $afPath)

    $usdPopulationPath = Join-Path $runDir 'stage4-usd-response-population.csv'
    @($population.usd | Select-Object source_member_ordinal,pair_token_opaque,base_asset_id,quote_asset_id,base_exchange_symbol,quote_exchange_symbol,resolution_status,resolution_method,pair_status) | Export-Csv -LiteralPath $usdPopulationPath -NoTypeInformation -Encoding UTF8
    $missingUsdPath = Join-Path $runDir 'stage4-base-assets-without-direct-usd.csv'
    @($population.missing_usd_bases | ForEach-Object { [pscustomobject]@{base_asset_id=[string]$_} }) | Export-Csv -LiteralPath $missingUsdPath -NoTypeInformation -Encoding UTF8

    $ordinalMap = @{}
    foreach ($u in $population.usd) {
        $key = ([string]$u.source_member_ordinal).Trim()
        if ($ordinalMap.ContainsKey($key)) { throw "Duplicate AF-001 source_member_ordinal in USD population: $key" }
        $ordinalMap[$key] = $u
    }
    $ordinalList = (@($ordinalMap.Keys | ForEach-Object { [long]$_ } | Sort-Object) -join ',')

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    Write-Host ("Frozen direct-USD response pairs: {0}" -f $population.usd.Count)
    Write-Host ("Frozen direct-USD response bases: {0}" -f $population.usd_bases.Count)
    Write-Host ("Base assets without direct USD: {0} ({1})" -f $population.missing_usd_bases.Count,($population.missing_usd_bases -join '|'))

    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000)"
    $version = Invoke-PsqlText -PsqlExe $psql -Database 'asrp' -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $columnsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT ordinal_position,column_name,data_type,udt_name,is_nullable,numeric_precision,numeric_scale,datetime_precision
FROM information_schema.columns
WHERE table_schema='asrp' AND table_name='q2_market_1m_observations'
ORDER BY ordinal_position
'@
    $columnsPath = Join-Path $runDir 'stage4-market-columns.csv'
    Write-Utf8NoBom $columnsPath ($columnsCsv + [Environment]::NewLine)
    $columns = @(Convert-CsvText $columnsCsv)
    $schema = Assert-MarketSchema $columns

    $marketSummaryCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT count(*)::bigint AS exact_rows,
       count(DISTINCT pair_token_opaque)::bigint AS pair_token_count,
       min(candle_start_utc) AS min_candle_start_utc,
       max(candle_start_utc) AS max_candle_start_utc,
       count(*) FILTER (WHERE NOT in_source_window)::bigint AS outside_source_window_rows,
       count(*) FILTER (WHERE NOT minute_aligned)::bigint AS non_minute_aligned_rows,
       count(*) FILTER (WHERE NOT canonical_eligible)::bigint AS canonical_ineligible_rows,
       count(*) FILTER (WHERE cardinality(quality_flags)>0)::bigint AS quality_flagged_rows,
       count(*) FILTER (WHERE duplicate_class IS NOT NULL)::bigint AS duplicate_class_rows
FROM asrp.q2_market_1m_observations
'@
    $marketSummary = @(Convert-CsvText $marketSummaryCsv)[0]
    if ([long]$marketSummary.exact_rows -ne $ExpectedMarketRows -or [long]$marketSummary.pair_token_count -ne $ExpectedMarketPairs) { throw 'Market source cardinality differs from frozen Stage 1 evidence.' }
    if ([long]$marketSummary.outside_source_window_rows -ne 0 -or [long]$marketSummary.non_minute_aligned_rows -ne 0 -or [long]$marketSummary.canonical_ineligible_rows -ne 0 -or [long]$marketSummary.quality_flagged_rows -ne 0 -or [long]$marketSummary.duplicate_class_rows -ne 0) { throw 'Market source integrity no longer matches frozen Stage 1 evidence.' }

    $usdIntegrityCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT count(*)::bigint AS exact_rows,
       count(DISTINCT source_member_ordinal)::bigint AS observed_usd_pairs,
       count(*) FILTER (WHERE open_price IS NULL OR high_price IS NULL OR low_price IS NULL OR close_price IS NULL)::bigint AS null_ohlc_rows,
       count(*) FILTER (WHERE open_price<=0 OR high_price<=0 OR low_price<=0 OR close_price<=0)::bigint AS nonpositive_ohlc_rows,
       count(*) FILTER (WHERE lower(open_price::text) IN ('nan','infinity','-infinity') OR lower(high_price::text) IN ('nan','infinity','-infinity') OR lower(low_price::text) IN ('nan','infinity','-infinity') OR lower(close_price::text) IN ('nan','infinity','-infinity'))::bigint AS nonfinite_ohlc_rows,
       count(*) FILTER (WHERE high_price < low_price OR high_price < GREATEST(open_price,close_price) OR low_price > LEAST(open_price,close_price))::bigint AS ohlc_order_failures,
       count(*) FILTER (WHERE NOT canonical_eligible OR NOT in_source_window OR NOT minute_aligned OR cardinality(quality_flags)>0 OR duplicate_class IS NOT NULL)::bigint AS eligibility_failures
FROM asrp.q2_market_1m_observations
WHERE source_member_ordinal IN ($ordinalList)
"@
    $usdIntegrity = @(Convert-CsvText $usdIntegrityCsv)[0]
    if ([long]$usdIntegrity.observed_usd_pairs -ne $ExpectedDirectUsdPairs) { throw "Only $($usdIntegrity.observed_usd_pairs) direct-USD pairs have market rows; expected $ExpectedDirectUsdPairs." }
    foreach ($name in @('null_ohlc_rows','nonpositive_ohlc_rows','nonfinite_ohlc_rows','ohlc_order_failures','eligibility_failures')) {
        if ([long]$usdIntegrity.$name -ne 0) { throw "Direct-USD market integrity failure: $name=$($usdIntegrity.$name)" }
    }

    $boundaryCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT source_member_ordinal,
       min(pair_token_opaque) AS pair_token_opaque,
       count(*)::bigint AS exact_rows,
       min(candle_start_utc) AS min_candle_start_utc,
       max(candle_start_utc) AS max_candle_start_utc,
       count(DISTINCT (candle_start_utc AT TIME ZONE 'UTC')::date)::bigint AS active_utc_days,
       count(*) FILTER (WHERE (candle_start_utc AT TIME ZONE 'UTC')::time = TIME '00:00:00')::bigint AS utc_0000_candles,
       count(*) FILTER (WHERE (candle_start_utc AT TIME ZONE 'UTC')::time = TIME '23:59:00')::bigint AS utc_2359_candles
FROM asrp.q2_market_1m_observations
WHERE source_member_ordinal IN ($ordinalList)
GROUP BY source_member_ordinal
ORDER BY source_member_ordinal
"@
    $boundaryPath = Join-Path $runDir 'stage4-usd-boundary-coverage.csv'
    Write-Utf8NoBom $boundaryPath ($boundaryCsv + [Environment]::NewLine)
    $boundaryRows = @(Convert-CsvText $boundaryCsv)
    if ($boundaryRows.Count -ne $ExpectedDirectUsdPairs) { throw "Boundary coverage has $($boundaryRows.Count) pairs; expected $ExpectedDirectUsdPairs." }
    foreach ($b in $boundaryRows) {
        $ord = ([string]$b.source_member_ordinal).Trim()
        if (-not $ordinalMap.ContainsKey($ord)) { throw "Boundary coverage returned non-USD ordinal $ord." }
        if (([string]$b.pair_token_opaque).Trim() -ne ([string]$ordinalMap[$ord].pair_token_opaque).Trim()) { throw "Pair token mismatch for source_member_ordinal $ord." }
        if ([long]$b.utc_2359_candles -le 0) { throw "Direct-USD pair $($b.pair_token_opaque) has no 23:59 UTC close candle." }
    }

    $closeCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT source_member_ordinal,pair_token_opaque,physical_record_number,raw_record_sha256,candle_start_utc,close_price,
       canonical_eligible,in_source_window,minute_aligned,cardinality(quality_flags) AS quality_flag_count,duplicate_class
FROM asrp.q2_market_1m_observations
WHERE source_member_ordinal IN ($ordinalList)
  AND (candle_start_utc AT TIME ZONE 'UTC')::time = TIME '23:59:00'
ORDER BY source_member_ordinal,candle_start_utc
"@
    $closeSourcePath = Join-Path $runDir 'stage4-usd-2359-close-source.csv'
    Write-Utf8NoBom $closeSourcePath ($closeCsv + [Environment]::NewLine)
    $closeSource = @(Convert-CsvText $closeCsv)
    if ($closeSource.Count -eq 0) { throw 'No 23:59 UTC close source rows were returned.' }

    $validCloses = New-Object System.Collections.ArrayList
    $invalidCloseRows = 0
    $closeKeySeen = @{}
    foreach ($r in $closeSource) {
        $ord = ([string]$r.source_member_ordinal).Trim()
        if (-not $ordinalMap.ContainsKey($ord)) { throw "23:59 source row references unknown USD ordinal $ord." }
        $af = $ordinalMap[$ord]
        if (([string]$r.pair_token_opaque).Trim() -ne ([string]$af.pair_token_opaque).Trim()) { throw "23:59 pair token mismatch for ordinal $ord." }
        $ts = [DateTimeOffset]::Parse([string]$r.candle_start_utc,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
        if ($ts.TimeOfDay -ne [timespan]::FromHours(23).Add([timespan]::FromMinutes(59))) { throw "Non-23:59 row returned for $($r.pair_token_opaque): $ts" }
        $day = $ts.Date
        $key = ([string]$af.base_asset_id) + '|' + $day.ToString('yyyy-MM-dd',$Invariant)
        if ($closeKeySeen.ContainsKey($key)) { throw "Duplicate base/day 23:59 close: $key" }
        $closeKeySeen[$key] = $true
        $valid = (Parse-BoolStrict $r.canonical_eligible "close canonical_eligible") -and (Parse-BoolStrict $r.in_source_window "close in_source_window") -and (Parse-BoolStrict $r.minute_aligned "close minute_aligned") -and ([int]$r.quality_flag_count -eq 0) -and [string]::IsNullOrWhiteSpace([string]$r.duplicate_class)
        $price = 0.0
        try { $price = Parse-DoubleStrict $r.close_price "close_price $($r.pair_token_opaque) $day" } catch { $valid = $false }
        if ($price -le 0) { $valid = $false }
        if (-not $valid) { $invalidCloseRows++; continue }
        [void]$validCloses.Add([pscustomobject]@{
            base_asset_id=[string]$af.base_asset_id
            pair_token_opaque=[string]$af.pair_token_opaque
            source_member_ordinal=$ord
            response_day=$day
            candle_start_utc=Format-Utc $ts
            close_price_text=[string]$r.close_price
            close_price_value=$price
            physical_record_number=[string]$r.physical_record_number
            raw_record_sha256=[string]$r.raw_record_sha256
        })
    }
    if ($invalidCloseRows -ne 0) { throw "$invalidCloseRows invalid 23:59 close row(s) observed; response construction is blocked." }

    $responses = @(Build-ResponseRows @($validCloses.ToArray()))
    if ($responses.Count -eq 0) { throw 'Response construction produced zero rows.' }
    $responseKeyDup = @($responses | Group-Object { ([string]$_.base_asset_id) + '|' + ([string]$_.response_day_utc) } | Where-Object Count -gt 1)
    if ($responseKeyDup.Count -ne 0) { throw "Response duplicate keys observed: $($responseKeyDup.Count)" }

    $formulaFailures = 0
    $timingFailures = 0
    foreach ($r in $responses) {
        $prior = Parse-DoubleStrict $r.prior_close_price_usd 'prior close'
        $current = Parse-DoubleStrict $r.current_close_price_usd 'current close'
        $actual = Parse-DoubleStrict $r.response_value_log_return 'response value'
        $expected = [Math]::Log($current / $prior)
        if ([Math]::Abs($actual - $expected) -gt 1e-12) { $formulaFailures++ }
        $cutoff = [DateTimeOffset]::Parse([string]$r.predictor_cutoff_utc).UtcDateTime
        $available = [DateTimeOffset]::Parse([string]$r.response_available_utc).UtcDateTime
        $priorTs = [DateTimeOffset]::Parse([string]$r.prior_close_candle_start_utc).UtcDateTime
        $currentTs = [DateTimeOffset]::Parse([string]$r.current_close_candle_start_utc).UtcDateTime
        if ($available -ne $cutoff.AddDays(1) -or $priorTs -ne $cutoff.AddMinutes(-1) -or $currentTs -ne $available.AddMinutes(-1)) { $timingFailures++ }
    }
    if ($formulaFailures -ne 0 -or $timingFailures -ne 0) { throw "Response validation failed: formula_failures=$formulaFailures timing_failures=$timingFailures" }

    $responsePath = Join-Path $runDir 'stage4-responses.csv'
    $responses | Export-Csv -LiteralPath $responsePath -NoTypeInformation -Encoding UTF8

    $coverageRows = @($responses | Group-Object base_asset_id | ForEach-Object {
        $g = @($_.Group | Sort-Object response_day_utc)
        [pscustomobject]@{base_asset_id=$_.Name;response_rows=$g.Count;min_response_day_utc=$g[0].response_day_utc;max_response_day_utc=$g[-1].response_day_utc}
    } | Sort-Object base_asset_id)
    $coveragePath = Join-Path $runDir 'stage4-response-coverage-by-asset.csv'
    $coverageRows | Export-Csv -LiteralPath $coveragePath -NoTypeInformation -Encoding UTF8

    $samplePool = New-Object System.Collections.ArrayList
    foreach ($r in @($responses | Sort-Object response_day_utc,base_asset_id | Select-Object -First 10)) { [void]$samplePool.Add($r) }
    foreach ($r in @($responses | Sort-Object response_day_utc,base_asset_id -Descending | Select-Object -First 10)) { [void]$samplePool.Add($r) }
    $hashed = @($responses | ForEach-Object { [pscustomobject]@{hash=Stable-Sha256Text (([string]$_.base_asset_id)+'|'+([string]$_.response_day_utc));row=$_} } | Sort-Object hash | Select-Object -First 20)
    foreach ($x in $hashed) { [void]$samplePool.Add($x.row) }
    $sampleSeen = @{}
    $sample = New-Object System.Collections.ArrayList
    foreach ($r in $samplePool) {
        $k = ([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc)
        if (-not $sampleSeen.ContainsKey($k)) { $sampleSeen[$k]=$true; [void]$sample.Add($r) }
    }
    $samplePath = Join-Path $runDir 'stage4-response-review-sample.csv'
    @($sample.ToArray()) | Export-Csv -LiteralPath $samplePath -NoTypeInformation -Encoding UTF8

    $responseDays = @($responses | Select-Object -ExpandProperty response_day_utc -Unique | Sort-Object)
    $responseAssets = @($responses | Select-Object -ExpandProperty base_asset_id -Unique | Sort-Object)
    $firstDay = $responseDays[0]
    $lastDay = $responseDays[-1]
    if ($firstDay -lt '2025-04-02' -or $lastDay -gt '2025-06-30') { throw "Response boundary days invalid: $firstDay through $lastDay" }

    $summary = [ordered]@{
        status='VALIDATION_CANDIDATE'
        stage='CFA_STAGE_4'
        response_id=$ResponseId
        formula='ln(current_utc_day_2359_close_price_usd / prior_utc_day_2359_close_price_usd)'
        grain='base_asset_id,response_day_utc'
        predictor_cutoff='response_day_utc 00:00:00Z'
        response_window='[response_day_utc 00:00:00Z, response_day_utc+1 day 00:00:00Z)'
        response_available='response_day_utc+1 day 00:00:00Z'
        close_definition='close_price from exact 23:59 UTC one-minute candle; no fallback'
        unit='dimensionless natural-log return'
        missing_policy='exclude when either consecutive UTC-day 23:59 close is absent/invalid; no imputation, carry, interpolation, quote substitution, or cross-rate conversion'
        source=[ordered]@{
            relation='asrp.q2_market_1m_observations'
            market_rows=$ExpectedMarketRows
            market_pairs=$ExpectedMarketPairs
            market_min_utc=$ExpectedMarketMinUtc
            market_max_utc=$ExpectedMarketMaxUtc
            schema_columns=$columns.Count
            close_price_data_type=[string]$schema['close_price'].data_type
            candle_start_data_type=[string]$schema['candle_start_utc'].data_type
            af001_sha256=$ExpectedAf001Sha256
            direct_usd_pairs=$population.usd.Count
            direct_usd_bases=$population.usd_bases.Count
            bases_without_direct_usd=$population.missing_usd_bases.Count
            bases_without_direct_usd_ids=@($population.missing_usd_bases)
        }
        validation=[ordered]@{
            direct_usd_observed_pairs=[long]$usdIntegrity.observed_usd_pairs
            direct_usd_null_ohlc_rows=[long]$usdIntegrity.null_ohlc_rows
            direct_usd_nonpositive_ohlc_rows=[long]$usdIntegrity.nonpositive_ohlc_rows
            direct_usd_nonfinite_ohlc_rows=[long]$usdIntegrity.nonfinite_ohlc_rows
            direct_usd_ohlc_order_failures=[long]$usdIntegrity.ohlc_order_failures
            direct_usd_eligibility_failures=[long]$usdIntegrity.eligibility_failures
            boundary_pair_rows=$boundaryRows.Count
            valid_2359_close_rows=$validCloses.Count
            invalid_2359_close_rows=$invalidCloseRows
            response_rows=$responses.Count
            response_assets=$responseAssets.Count
            first_response_day_utc=$firstDay
            last_response_day_utc=$lastDay
            duplicate_response_keys=$responseKeyDup.Count
            formula_failures=$formulaFailures
            timing_failures=$timingFailures
        }
        outputs=[ordered]@{
            responses_csv=$responsePath
            responses_sha256=Get-Sha $responsePath
            review_sample_csv=$samplePath
            review_sample_sha256=Get-Sha $samplePath
            market_columns_csv=$columnsPath
            market_columns_sha256=Get-Sha $columnsPath
            usd_population_csv=$usdPopulationPath
            usd_population_sha256=Get-Sha $usdPopulationPath
            missing_usd_bases_csv=$missingUsdPath
            missing_usd_bases_sha256=Get-Sha $missingUsdPath
            boundary_coverage_csv=$boundaryPath
            boundary_coverage_sha256=Get-Sha $boundaryPath
            response_coverage_csv=$coveragePath
            response_coverage_sha256=Get-Sha $coveragePath
        }
        gates=[ordered]@{
            'CFA-S4-001'='PASS'
            'CFA-S4-002'='PASS'
            'CFA-S4-003'='PASS'
            'CFA-S4-004'='PASS'
            'CFA-S4-005'='PASS'
            'CFA-S4-006'='BLOCKED'
        }
        direct_review='UNVERIFIED'
        next_action='Verify candidate receipt and bounded response sample; freeze only if exact artifacts and semantics reconcile.'
    }
    $receiptPath = Join-Path $runDir 'stage4-response-candidate.json'
    Write-Utf8NoBom $receiptPath (($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 4 RESPONSE CONSTRUCTION: VALIDATION CANDIDATE'
    Write-Host ("Response ID: {0}" -f $ResponseId)
    Write-Host ("Direct-USD pairs/bases: {0}/{1}" -f $population.usd.Count,$population.usd_bases.Count)
    Write-Host ("Base assets without direct USD: {0}" -f ($population.missing_usd_bases -join '|'))
    Write-Host ("Valid 23:59 UTC closes: {0}" -f $validCloses.Count)
    Write-Host ("Response rows: {0}" -f $responses.Count)
    Write-Host ("Response assets: {0}" -f $responseAssets.Count)
    Write-Host ("Response day range: {0} through {1}" -f $firstDay,$lastDay)
    Write-Host 'CFA-S4-002: PASS'
    Write-Host 'CFA-S4-003: PASS'
    Write-Host 'CFA-S4-004: PASS'
    Write-Host 'CFA-S4-005: PASS'
    Write-Host 'CFA-S4-006 freeze responses: BLOCKED pending exact candidate/sample review'
    Write-Host ("Review sample: {0}" -f $samplePath)
    Write-Host ("Candidate receipt: {0}" -f $receiptPath)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 4 RESPONSE CONSTRUCTION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
}
