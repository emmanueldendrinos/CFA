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

$ExpectedAf001Sha256 = '569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAf001Rows = 1059
$ExpectedEligibleRows = 1058
$ExpectedDirectUsdPairs = 434
$ExpectedDirectUsdBases = 434

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

function Get-UsdPopulation {
    param([object[]]$Rows)
    if ($Rows.Count -ne $ExpectedAf001Rows) { throw "AF-001 row count mismatch: $($Rows.Count)." }
    $eligible = @($Rows | Where-Object { Parse-BoolStrict $_.research_eligible 'research_eligible' })
    if ($eligible.Count -ne $ExpectedEligibleRows) { throw "AF-001 eligible row count mismatch: $($eligible.Count)." }
    $usd = @($eligible | Where-Object { ([string]$_.quote_exchange_symbol).Trim() -ceq 'USD' })
    if ($usd.Count -ne $ExpectedDirectUsdPairs) { throw "Direct-USD pair count mismatch: $($usd.Count)." }
    $bases = @($usd | Select-Object -ExpandProperty base_asset_id -Unique)
    if ($bases.Count -ne $ExpectedDirectUsdBases) { throw "Direct-USD base count mismatch: $($bases.Count)." }
    $dup = @($usd | Group-Object base_asset_id | Where-Object Count -gt 1)
    if ($dup.Count -ne 0) { throw "Direct-USD duplicate base identities found: $($dup.Count)." }
    return $usd
}

function Invoke-SelfTest {
    $minutes = @(1439,1438,1435,1420,1380,1000)
    $lags = @($minutes | ForEach-Object { 1439 - $_ })
    if ($lags[0] -ne 0 -or $lags[1] -ne 1 -or $lags[5] -ne 439) { throw 'Day-end lag arithmetic self-test failed.' }
    if (-not (Parse-BoolStrict 'True' 'selftest')) { throw 'Boolean parsing self-test failed.' }
    if (Parse-BoolStrict 'False' 'selftest') { throw 'Boolean false parsing self-test failed.' }
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
        $OutputRoot = Join-Path $documents 'CFA-local\stage4-day-end-diagnostic'
    }
    $runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $contractPath = Join-Path $RepoRoot 'docs\evidence\stage4-response-contract.md'
    if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) { throw 'Stage 4 response contract missing.' }
    $contract = Get-Content -LiteralPath $contractPath -Raw
    if ($contract -notmatch 'EXACT_2359_CANDIDATE_FAILED' -or $contract -notmatch 'CFA-S4-007') {
        throw 'Stage 4 contract does not record the exact-23:59 failure and diagnostic gate.'
    }

    $afPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    if ((Get-Sha $afPath) -ne $ExpectedAf001Sha256) { throw 'AF-001 SHA-256 mismatch.' }
    $afRows = @(Import-Csv -LiteralPath $afPath)
    $usd = @(Get-UsdPopulation $afRows)
    $ordinals = @($usd | ForEach-Object { [int]$_.source_member_ordinal } | Sort-Object)
    $ordinalList = ($ordinals -join ',')

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    Write-Host "Direct-USD pairs: $($usd.Count)"

    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000)"

    $version = Invoke-PsqlText -PsqlExe $psql -Database 'asrp' -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $schemaCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT column_name,data_type,udt_name,is_nullable,numeric_precision,numeric_scale,datetime_precision
FROM information_schema.columns
WHERE table_schema='asrp' AND table_name='q2_market_1m_observations'
  AND column_name IN ('source_member_ordinal','pair_token_opaque','physical_record_number','raw_record_sha256','candle_start_utc','close_price','canonical_eligible','in_source_window','minute_aligned','quality_flags','duplicate_class')
ORDER BY ordinal_position
'@
    $schemaPath = Join-Path $runDir 'stage4-day-end-required-schema.csv'
    Write-Utf8NoBom $schemaPath ($schemaCsv + [Environment]::NewLine)

    $pairSummaryCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
WITH daily AS (
    SELECT
        source_member_ordinal,
        min(pair_token_opaque) AS pair_token_opaque,
        (candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
        count(*)::bigint AS rows_in_day,
        min(candle_start_utc) AS first_candle_utc,
        max(candle_start_utc) AS last_candle_utc,
        max((extract(hour FROM candle_start_utc AT TIME ZONE 'UTC')::int * 60) + extract(minute FROM candle_start_utc AT TIME ZONE 'UTC')::int) AS last_minute_of_day,
        count(*) FILTER (WHERE (candle_start_utc AT TIME ZONE 'UTC')::time = TIME '23:59:00')::bigint AS exact_2359_rows
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    GROUP BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date
), last_rows AS (
    SELECT DISTINCT ON (source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date)
        source_member_ordinal,
        (candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
        close_price,
        canonical_eligible,
        in_source_window,
        minute_aligned,
        cardinality(quality_flags) AS quality_flag_count,
        duplicate_class
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    ORDER BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date,candle_start_utc DESC,physical_record_number DESC
), paired AS (
    SELECT d.*,lr.close_price,lr.canonical_eligible,lr.in_source_window,lr.minute_aligned,lr.quality_flag_count,lr.duplicate_class,
           (1439-d.last_minute_of_day)::int AS minutes_before_midnight,
           CASE WHEN lr.close_price IS NULL OR lr.close_price::text IN ('NaN','Infinity','-Infinity') OR lr.close_price <= 0
                     OR NOT lr.canonical_eligible OR NOT lr.in_source_window OR NOT lr.minute_aligned
                     OR lr.quality_flag_count <> 0 OR lr.duplicate_class IS NOT NULL
                THEN 1 ELSE 0 END AS invalid_last_close
    FROM daily d
    JOIN last_rows lr USING(source_member_ordinal,utc_day)
)
SELECT
    source_member_ordinal,
    min(pair_token_opaque) AS pair_token_opaque,
    min(utc_day) AS min_active_day,
    max(utc_day) AS max_active_day,
    count(*)::bigint AS active_days,
    (max(utc_day)-min(utc_day)+1)::int AS calendar_days_in_active_span,
    ((max(utc_day)-min(utc_day)+1)-count(*))::bigint AS missing_days_inside_active_span,
    count(*) FILTER (WHERE exact_2359_rows > 0)::bigint AS days_with_exact_2359,
    count(*) FILTER (WHERE exact_2359_rows = 0)::bigint AS days_without_exact_2359,
    min(minutes_before_midnight)::int AS min_minutes_before_midnight,
    max(minutes_before_midnight)::int AS max_minutes_before_midnight,
    round(avg(minutes_before_midnight)::numeric,3) AS avg_minutes_before_midnight,
    count(*) FILTER (WHERE minutes_before_midnight = 0)::bigint AS lag_0_days,
    count(*) FILTER (WHERE minutes_before_midnight BETWEEN 1 AND 4)::bigint AS lag_1_4_days,
    count(*) FILTER (WHERE minutes_before_midnight BETWEEN 5 AND 14)::bigint AS lag_5_14_days,
    count(*) FILTER (WHERE minutes_before_midnight BETWEEN 15 AND 59)::bigint AS lag_15_59_days,
    count(*) FILTER (WHERE minutes_before_midnight BETWEEN 60 AND 359)::bigint AS lag_60_359_days,
    count(*) FILTER (WHERE minutes_before_midnight >= 360)::bigint AS lag_360_plus_days,
    sum(invalid_last_close)::bigint AS invalid_last_close_days
FROM paired
GROUP BY source_member_ordinal
ORDER BY source_member_ordinal
"@
    $pairSummaryPath = Join-Path $runDir 'stage4-day-end-pair-summary.csv'
    Write-Utf8NoBom $pairSummaryPath ($pairSummaryCsv + [Environment]::NewLine)
    $pairRows = @(Convert-CsvText $pairSummaryCsv)
    if ($pairRows.Count -ne $ExpectedDirectUsdPairs) { throw "Pair diagnostic returned $($pairRows.Count) pairs; expected $ExpectedDirectUsdPairs." }

    $globalCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
WITH daily AS (
    SELECT
        source_member_ordinal,
        (candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
        max(candle_start_utc) AS last_candle_utc,
        max((extract(hour FROM candle_start_utc AT TIME ZONE 'UTC')::int * 60) + extract(minute FROM candle_start_utc AT TIME ZONE 'UTC')::int) AS last_minute_of_day,
        count(*) FILTER (WHERE (candle_start_utc AT TIME ZONE 'UTC')::time = TIME '23:59:00')::bigint AS exact_2359_rows
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    GROUP BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date
), last_rows AS (
    SELECT DISTINCT ON (source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date)
        source_member_ordinal,
        (candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
        close_price,canonical_eligible,in_source_window,minute_aligned,
        cardinality(quality_flags) AS quality_flag_count,duplicate_class
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    ORDER BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date,candle_start_utc DESC,physical_record_number DESC
), valid_daily AS (
    SELECT d.*,lr.close_price,
           CASE WHEN lr.close_price IS NOT NULL AND lr.close_price::text NOT IN ('NaN','Infinity','-Infinity') AND lr.close_price > 0
                     AND lr.canonical_eligible AND lr.in_source_window AND lr.minute_aligned
                     AND lr.quality_flag_count = 0 AND lr.duplicate_class IS NULL
                THEN true ELSE false END AS valid_last_close,
           (1439-d.last_minute_of_day)::int AS minutes_before_midnight
    FROM daily d JOIN last_rows lr USING(source_member_ordinal,utc_day)
), candidates AS (
    SELECT cur.source_member_ordinal,cur.utc_day,
           cur.valid_last_close AS cur_valid,prev.valid_last_close AS prev_valid,
           cur.exact_2359_rows AS cur_2359,prev.exact_2359_rows AS prev_2359
    FROM valid_daily cur
    JOIN valid_daily prev
      ON prev.source_member_ordinal=cur.source_member_ordinal
     AND prev.utc_day=cur.utc_day-1
    WHERE cur.utc_day >= DATE '2025-04-02' AND cur.utc_day <= DATE '2025-06-30'
)
SELECT
    (SELECT count(DISTINCT source_member_ordinal) FROM valid_daily)::bigint AS pairs_with_any_active_day,
    (SELECT count(*) FROM valid_daily)::bigint AS active_pair_days,
    (SELECT count(*) FROM valid_daily WHERE exact_2359_rows > 0)::bigint AS active_pair_days_with_exact_2359,
    (SELECT count(*) FROM valid_daily WHERE exact_2359_rows = 0)::bigint AS active_pair_days_without_exact_2359,
    (SELECT count(DISTINCT source_member_ordinal) FROM valid_daily WHERE exact_2359_rows = 0)::bigint AS pairs_with_at_least_one_non2359_day,
    (SELECT count(*) FROM (SELECT source_member_ordinal FROM valid_daily GROUP BY source_member_ordinal HAVING sum(CASE WHEN exact_2359_rows>0 THEN 1 ELSE 0 END)=0) x)::bigint AS pairs_with_no_exact_2359_ever,
    (SELECT count(*) FROM valid_daily WHERE minutes_before_midnight=0)::bigint AS lag_0_pair_days,
    (SELECT count(*) FROM valid_daily WHERE minutes_before_midnight BETWEEN 1 AND 4)::bigint AS lag_1_4_pair_days,
    (SELECT count(*) FROM valid_daily WHERE minutes_before_midnight BETWEEN 5 AND 14)::bigint AS lag_5_14_pair_days,
    (SELECT count(*) FROM valid_daily WHERE minutes_before_midnight BETWEEN 15 AND 59)::bigint AS lag_15_59_pair_days,
    (SELECT count(*) FROM valid_daily WHERE minutes_before_midnight BETWEEN 60 AND 359)::bigint AS lag_60_359_pair_days,
    (SELECT count(*) FROM valid_daily WHERE minutes_before_midnight>=360)::bigint AS lag_360_plus_pair_days,
    (SELECT max(minutes_before_midnight) FROM valid_daily)::int AS max_minutes_before_midnight,
    (SELECT count(*) FROM valid_daily WHERE NOT valid_last_close)::bigint AS invalid_last_close_pair_days,
    (SELECT count(*) FROM candidates WHERE cur_valid AND prev_valid)::bigint AS consecutive_day_last_observed_candidates,
    (SELECT count(*) FROM candidates WHERE cur_valid AND prev_valid AND cur_2359>0 AND prev_2359>0)::bigint AS consecutive_day_exact2359_candidates
"@
    $globalPath = Join-Path $runDir 'stage4-day-end-global-summary.csv'
    Write-Utf8NoBom $globalPath ($globalCsv + [Environment]::NewLine)
    $globalRows = @(Convert-CsvText $globalCsv)
    if ($globalRows.Count -ne 1) { throw 'Global day-end summary did not return exactly one row.' }

    $frequencyCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
WITH daily AS (
    SELECT source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,max(candle_start_utc) AS last_candle_utc
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    GROUP BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date
)
SELECT to_char(last_candle_utc AT TIME ZONE 'UTC','HH24:MI') AS last_candle_time_utc,count(*)::bigint AS pair_days
FROM daily
GROUP BY 1
ORDER BY pair_days DESC,last_candle_time_utc DESC
"@
    $frequencyPath = Join-Path $runDir 'stage4-day-end-last-time-frequency.csv'
    Write-Utf8NoBom $frequencyPath ($frequencyCsv + [Environment]::NewLine)

    $worstCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
WITH daily AS (
    SELECT source_member_ordinal,min(pair_token_opaque) AS pair_token_opaque,(candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
           max(candle_start_utc) AS last_candle_utc,
           max((extract(hour FROM candle_start_utc AT TIME ZONE 'UTC')::int * 60) + extract(minute FROM candle_start_utc AT TIME ZONE 'UTC')::int) AS last_minute_of_day,
           count(*)::bigint AS rows_in_day
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    GROUP BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date
)
SELECT source_member_ordinal,pair_token_opaque,utc_day,last_candle_utc,(1439-last_minute_of_day)::int AS minutes_before_midnight,rows_in_day
FROM daily
ORDER BY minutes_before_midnight DESC,source_member_ordinal,utc_day
LIMIT 200
"@
    $worstPath = Join-Path $runDir 'stage4-day-end-worst-200.csv'
    Write-Utf8NoBom $worstPath ($worstCsv + [Environment]::NewLine)

    $aevoCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
WITH target AS (
    SELECT source_member_ordinal FROM asrp.q2_market_1m_observations WHERE pair_token_opaque='AEVOUSD' LIMIT 1
), daily AS (
    SELECT pair_token_opaque,(candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,min(candle_start_utc) AS first_candle_utc,max(candle_start_utc) AS last_candle_utc,count(*)::bigint AS rows_in_day,
           max((extract(hour FROM candle_start_utc AT TIME ZONE 'UTC')::int * 60) + extract(minute FROM candle_start_utc AT TIME ZONE 'UTC')::int) AS last_minute_of_day
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal=(SELECT source_member_ordinal FROM target)
    GROUP BY pair_token_opaque,(candle_start_utc AT TIME ZONE 'UTC')::date
)
SELECT pair_token_opaque,utc_day,first_candle_utc,last_candle_utc,(1439-last_minute_of_day)::int AS minutes_before_midnight,rows_in_day
FROM daily ORDER BY utc_day
"@
    $aevoPath = Join-Path $runDir 'stage4-day-end-AEVOUSD.csv'
    Write-Utf8NoBom $aevoPath ($aevoCsv + [Environment]::NewLine)

    $summary = $globalRows[0]
    $receipt = [ordered]@{
        status = 'PASS'
        stage = 'CFA_STAGE_4'
        diagnostic = 'DAY_END_COVERAGE'
        exact_2359_candidate_status = 'FAIL'
        direct_usd_pairs = $ExpectedDirectUsdPairs
        direct_usd_bases = $ExpectedDirectUsdBases
        pairs_with_no_exact_2359_ever = [long]$summary.pairs_with_no_exact_2359_ever
        active_pair_days = [long]$summary.active_pair_days
        active_pair_days_with_exact_2359 = [long]$summary.active_pair_days_with_exact_2359
        active_pair_days_without_exact_2359 = [long]$summary.active_pair_days_without_exact_2359
        max_minutes_before_midnight = [int]$summary.max_minutes_before_midnight
        invalid_last_close_pair_days = [long]$summary.invalid_last_close_pair_days
        consecutive_day_last_observed_candidates = [long]$summary.consecutive_day_last_observed_candidates
        consecutive_day_exact2359_candidates = [long]$summary.consecutive_day_exact2359_candidates
        outputs = [ordered]@{
            required_schema = $schemaPath
            pair_summary = $pairSummaryPath
            global_summary = $globalPath
            last_time_frequency = $frequencyPath
            worst_200 = $worstPath
            aevo_detail = $aevoPath
        }
        hashes = [ordered]@{
            required_schema_sha256 = Get-Sha $schemaPath
            pair_summary_sha256 = Get-Sha $pairSummaryPath
            global_summary_sha256 = Get-Sha $globalPath
            last_time_frequency_sha256 = Get-Sha $frequencyPath
            worst_200_sha256 = Get-Sha $worstPath
            aevo_detail_sha256 = Get-Sha $aevoPath
        }
        gates = [ordered]@{
            'CFA-S4-004' = 'FAIL'
            'CFA-S4-005' = 'FAIL'
            'CFA-S4-007' = 'PASS'
            'CFA-S4-008' = 'UNVERIFIED'
            'CFA-S4-009' = 'BLOCKED'
            'CFA-S4-010' = 'BLOCKED'
        }
        next_action = 'Use the measured day-end distribution to define one corrected response boundary rule. Do not reuse exact 23:59 unless the evidence justifies restricting the population.'
    }
    $receiptPath = Join-Path $runDir 'stage4-day-end-diagnostic.json'
    Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 4 DAY-END COVERAGE DIAGNOSTIC: PASS'
    Write-Host ("Pairs with no exact 23:59 ever: {0}" -f $receipt.pairs_with_no_exact_2359_ever)
    Write-Host ("Active USD pair-days: {0}" -f $receipt.active_pair_days)
    Write-Host ("Pair-days with exact 23:59: {0}" -f $receipt.active_pair_days_with_exact_2359)
    Write-Host ("Pair-days without exact 23:59: {0}" -f $receipt.active_pair_days_without_exact_2359)
    Write-Host ("Maximum last-candle lag before midnight: {0} minutes" -f $receipt.max_minutes_before_midnight)
    Write-Host ("Invalid last-close pair-days: {0}" -f $receipt.invalid_last_close_pair_days)
    Write-Host ("Consecutive-day candidates using last observed close: {0}" -f $receipt.consecutive_day_last_observed_candidates)
    Write-Host ("Consecutive-day candidates requiring exact 23:59: {0}" -f $receipt.consecutive_day_exact2359_candidates)
    Write-Host 'CFA-S4-007 day-end coverage diagnostic: PASS'
    Write-Host 'CFA-S4-008 corrected response rule: UNVERIFIED'
    Write-Host 'CFA-S4-010 freeze responses: BLOCKED'
    Write-Host ("Diagnostic receipt: {0}" -f $receiptPath)
    Write-Host ("Evidence directory: {0}" -f $runDir)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 4 DAY-END COVERAGE DIAGNOSTIC: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
}
