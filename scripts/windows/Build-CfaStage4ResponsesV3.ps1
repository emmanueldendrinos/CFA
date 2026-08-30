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

$ResponseId = 'RET_USD_UTC_DAY_OBS_LOG'
$ExpectedAf001Sha256 = '569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAf001Rows = 1059
$ExpectedEligibleRows = 1058
$ExpectedEligibleBaseAssets = 435
$ExpectedDirectUsdPairs = 434
$ExpectedDirectUsdBases = 434
$ExpectedActiveUsdPairDays = 37058
$ExpectedMarketRows = 14055089L
$ExpectedMarketPairs = 1058L
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
    param([string]$PsqlExe,[string]$Database,[string]$Sql)
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $stdout = @(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2> $errFile)
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path -LiteralPath $errFile) { ((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine } else { '' }
        $text = ($stdout | ForEach-Object { if ($null -ne $_) { [string]$_ } }) -join [Environment]::NewLine
        if ($exitCode -ne 0) { throw "psql failed for database '$Database' (exit $exitCode).`n$stderr`n$text" }
        return $text
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
}

function Invoke-PsqlCsv {
    param([string]$PsqlExe,[string]$Database,[string]$Query)
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Convert-CsvText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text | ConvertFrom-Csv)
}

function Write-Utf8NoBom {
    param([string]$Path,[AllowNull()][string]$Content)
    if ($null -eq $Content) { $Content = '' }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Parse-BoolStrict {
    param([object]$Value,[string]$Label)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true' -or $text -eq 't') { return $true }
    if ($text -eq 'false' -or $text -eq 'f') { return $false }
    throw "Malformed boolean for ${Label}: '$Value'"
}

function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $number = 0.0
    if (-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$number)) { throw "Malformed numeric value for ${Label}: '$Value'" }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "Non-finite numeric value for ${Label}: '$Value'" }
    return $number
}

function Format-Utc {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)
}

function Get-AfPopulation {
    param([object[]]$Rows)
    if ($Rows.Count -ne $ExpectedAf001Rows) { throw "AF-001 row count mismatch: $($Rows.Count)." }
    $required = @('source_member_ordinal','pair_token_opaque','base_asset_id','quote_exchange_symbol','research_eligible')
    foreach ($name in $required) { if (@($Rows[0].PSObject.Properties.Name) -notcontains $name) { throw "AF-001 required column missing: $name" } }
    $eligible = @($Rows | Where-Object { Parse-BoolStrict $_.research_eligible "AF-001 $($_.pair_token_opaque) research_eligible" })
    if ($eligible.Count -ne $ExpectedEligibleRows) { throw "AF-001 eligible row count mismatch: $($eligible.Count)." }
    $eligibleBases = @($eligible | Select-Object -ExpandProperty base_asset_id -Unique)
    if ($eligibleBases.Count -ne $ExpectedEligibleBaseAssets) { throw "AF-001 eligible base count mismatch: $($eligibleBases.Count)." }
    $usd = @($eligible | Where-Object { ([string]$_.quote_exchange_symbol).Trim() -ceq 'USD' })
    $usdBases = @($usd | Select-Object -ExpandProperty base_asset_id -Unique)
    if ($usd.Count -ne $ExpectedDirectUsdPairs -or $usdBases.Count -ne $ExpectedDirectUsdBases) { throw "Direct-USD population changed: pairs=$($usd.Count), bases=$($usdBases.Count)." }
    if (@($usd | Group-Object base_asset_id | Where-Object Count -gt 1).Count -ne 0) { throw 'Direct-USD base ambiguity detected.' }
    return [pscustomobject]@{ eligible=$eligible; eligible_bases=$eligibleBases; usd=$usd; usd_bases=$usdBases }
}

function Assert-MarketSchema {
    param([object[]]$Columns)
    if ($Columns.Count -ne 19) { throw "Market schema column count changed: $($Columns.Count), expected 19." }
    $by = @{}
    foreach ($c in $Columns) { $by[[string]$c.column_name] = $c }
    foreach ($name in @('source_member_ordinal','pair_token_opaque','physical_record_number','raw_record_sha256','candle_start_utc','open_price','high_price','low_price','close_price','canonical_eligible','in_source_window','minute_aligned','quality_flags','duplicate_class')) {
        if (-not $by.ContainsKey($name)) { throw "Required market column missing: $name" }
    }
    if ([string]$by['candle_start_utc'].data_type -ne 'timestamp with time zone') { throw 'candle_start_utc is not timestamptz.' }
    foreach ($name in @('open_price','high_price','low_price','close_price')) {
        if ([string]$by[$name].data_type -notin @('numeric','double precision','real')) { throw "$name is not numeric." }
    }
}

function Build-ResponseRow {
    param([object]$DailyRow,[object]$AfRow)
    $day = [datetime]$DailyRow.utc_day_value
    $cutoff = [datetime]::SpecifyKind($day,[DateTimeKind]::Utc)
    $available = $cutoff.AddDays(1)
    $firstTs = [datetime]$DailyRow.first_candle_start_utc_value
    $lastTs = [datetime]$DailyRow.last_candle_start_utc_value
    if ($firstTs -lt $cutoff -or $firstTs -ge $available) { throw "First observation outside response window: $($AfRow.base_asset_id) $day" }
    if ($lastTs -lt $cutoff -or $lastTs -ge $available) { throw "Last observation outside response window: $($AfRow.base_asset_id) $day" }
    if ($firstTs -gt $lastTs) { throw "First observation after last observation: $($AfRow.base_asset_id) $day" }
    $firstOpen = [double]$DailyRow.first_open_price_value
    $lastClose = [double]$DailyRow.last_close_price_value
    if ($firstOpen -le 0 -or $lastClose -le 0) { throw "Non-positive selected response price: $($AfRow.base_asset_id) $day" }
    $value = [Math]::Log($lastClose / $firstOpen)
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "Non-finite response: $($AfRow.base_asset_id) $day" }
    return [pscustomobject][ordered]@{
        response_id = $ResponseId
        base_asset_id = [string]$AfRow.base_asset_id
        pair_token_opaque = [string]$AfRow.pair_token_opaque
        source_member_ordinal = [string]$AfRow.source_member_ordinal
        response_day_utc = $day.ToString('yyyy-MM-dd',$Invariant)
        predictor_cutoff_utc = Format-Utc $cutoff
        response_window_start_utc = Format-Utc $cutoff
        response_window_end_exclusive_utc = Format-Utc $available
        response_available_utc = Format-Utc $available
        first_candle_start_utc = Format-Utc $firstTs
        last_candle_start_utc = Format-Utc $lastTs
        first_minutes_after_midnight = [string]$DailyRow.first_minutes_after_midnight
        last_minutes_before_midnight = [string]$DailyRow.last_minutes_before_midnight
        observed_span_minutes_between_starts = [string]$DailyRow.observed_span_minutes_between_starts
        first_open_price_usd = [string]$DailyRow.first_open_price_text
        last_close_price_usd = [string]$DailyRow.last_close_price_text
        response_value_log_return = $value.ToString('R',$Invariant)
        first_physical_record_number = [string]$DailyRow.first_physical_record_number
        last_physical_record_number = [string]$DailyRow.last_physical_record_number
        first_raw_record_sha256 = [string]$DailyRow.first_raw_record_sha256
        last_raw_record_sha256 = [string]$DailyRow.last_raw_record_sha256
    }
}

function Invoke-SelfTest {
    foreach ($probe in @('True','true','t')) { if (-not (Parse-BoolStrict $probe 'selftest true')) { throw "Boolean true parsing failed for $probe" } }
    foreach ($probe in @('False','false','f')) { if (Parse-BoolStrict $probe 'selftest false') { throw "Boolean false parsing failed for $probe" } }
    $af = [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1'}
    $daily = [pscustomobject]@{
        utc_day_value=[datetime]'2025-04-02';first_candle_start_utc_value=[datetime]'2025-04-02T00:03:00Z';last_candle_start_utc_value=[datetime]'2025-04-02T19:00:00Z';
        first_minutes_after_midnight=3;last_minutes_before_midnight=299;observed_span_minutes_between_starts=1137;
        first_open_price_text='100';first_open_price_value=100.0;last_close_price_text='110';last_close_price_value=110.0;
        first_physical_record_number='10';last_physical_record_number='99';first_raw_record_sha256=('a'*64);last_raw_record_sha256=('b'*64)
    }
    $r = Build-ResponseRow -DailyRow $daily -AfRow $af
    if ($r.response_id -ne $ResponseId) { throw 'Self-test response ID mismatch.' }
    if ($r.predictor_cutoff_utc -ne '2025-04-02T00:00:00Z' -or $r.response_available_utc -ne '2025-04-03T00:00:00Z') { throw 'Self-test cutoff/availability mismatch.' }
    if ([DateTimeOffset]::Parse($r.first_candle_start_utc).UtcDateTime -lt [DateTimeOffset]::Parse($r.predictor_cutoff_utc).UtcDateTime) { throw 'Self-test first price precedes cutoff.' }
    $v = Parse-DoubleStrict $r.response_value_log_return 'selftest response'
    if ([Math]::Abs($v-[Math]::Log(1.1)) -gt 1e-12) { throw 'Self-test formula mismatch.' }
    $single = [pscustomobject]@{
        utc_day_value=[datetime]'2025-04-03';first_candle_start_utc_value=[datetime]'2025-04-03T12:00:00Z';last_candle_start_utc_value=[datetime]'2025-04-03T12:00:00Z';
        first_minutes_after_midnight=720;last_minutes_before_midnight=719;observed_span_minutes_between_starts=0;
        first_open_price_text='20';first_open_price_value=20.0;last_close_price_text='21';last_close_price_value=21.0;
        first_physical_record_number='1';last_physical_record_number='1';first_raw_record_sha256=('c'*64);last_raw_record_sha256=('c'*64)
    }
    $singleResult = Build-ResponseRow -DailyRow $single -AfRow $af
    if ([Math]::Abs((Parse-DoubleStrict $singleResult.response_value_log_return 'single')-[Math]::Log(1.05)) -gt 1e-12) { throw 'Single-candle response self-test failed.' }
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
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage4-responses-v3' }
    $runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $contractPath = Join-Path $RepoRoot 'docs\evidence\stage4-response-contract.md'
    $contract = Get-Content -LiteralPath $contractPath -Raw
    if ($contract -notmatch 'RET_USD_UTC_DAY_OBS_LOG' -or $contract -notmatch 'CFA-S4-012' -or $contract -notmatch 'Define cutoff-safe V3 within-day observed return\s*\|\s*PASS') { throw 'V3 Stage 4 response rule is not frozen as PASS for validation.' }

    $afPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    if ((Get-Sha $afPath) -ne $ExpectedAf001Sha256) { throw 'AF-001 SHA-256 mismatch.' }
    $population = Get-AfPopulation @(Import-Csv -LiteralPath $afPath)
    $ordinalMap = @{}
    foreach ($u in $population.usd) { $ordinalMap[([string]$u.source_member_ordinal).Trim()] = $u }
    $ordinalList = (@($ordinalMap.Keys | ForEach-Object { [long]$_ } | Sort-Object) -join ',')

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    Write-Host "V3 response ID: $ResponseId"
    Write-Host "Direct-USD response pairs: $($population.usd.Count)"

    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000)"
    $version = Invoke-PsqlText -PsqlExe $psql -Database 'asrp' -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $columns = @(Convert-CsvText (Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT ordinal_position,column_name,data_type,udt_name,is_nullable,numeric_precision,numeric_scale,datetime_precision
FROM information_schema.columns
WHERE table_schema='asrp' AND table_name='q2_market_1m_observations'
ORDER BY ordinal_position
'@))
    Assert-MarketSchema $columns

    $marketSummary = @(Convert-CsvText (Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT count(*)::bigint AS exact_rows,count(DISTINCT pair_token_opaque)::bigint AS pair_token_count,
count(*) FILTER (WHERE NOT in_source_window)::bigint AS outside_source_window_rows,
count(*) FILTER (WHERE NOT minute_aligned)::bigint AS non_minute_aligned_rows,
count(*) FILTER (WHERE NOT canonical_eligible)::bigint AS canonical_ineligible_rows,
count(*) FILTER (WHERE cardinality(quality_flags)>0)::bigint AS quality_flagged_rows,
count(*) FILTER (WHERE duplicate_class IS NOT NULL)::bigint AS duplicate_class_rows
FROM asrp.q2_market_1m_observations
'@))[0]
    if ([long]$marketSummary.exact_rows -ne $ExpectedMarketRows -or [long]$marketSummary.pair_token_count -ne $ExpectedMarketPairs) { throw 'Frozen market cardinality changed.' }
    foreach ($n in @('outside_source_window_rows','non_minute_aligned_rows','canonical_ineligible_rows','quality_flagged_rows','duplicate_class_rows')) { if ([long]$marketSummary.$n -ne 0) { throw "Frozen market integrity failure: $n=$($marketSummary.$n)" } }

    $usdIntegrity = @(Convert-CsvText (Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT count(DISTINCT source_member_ordinal)::bigint AS observed_usd_pairs,
count(*) FILTER (WHERE open_price IS NULL OR high_price IS NULL OR low_price IS NULL OR close_price IS NULL)::bigint AS null_ohlc_rows,
count(*) FILTER (WHERE open_price<=0 OR high_price<=0 OR low_price<=0 OR close_price<=0)::bigint AS nonpositive_ohlc_rows,
count(*) FILTER (WHERE lower(open_price::text) IN ('nan','infinity','-infinity') OR lower(high_price::text) IN ('nan','infinity','-infinity') OR lower(low_price::text) IN ('nan','infinity','-infinity') OR lower(close_price::text) IN ('nan','infinity','-infinity'))::bigint AS nonfinite_ohlc_rows,
count(*) FILTER (WHERE high_price < low_price OR high_price < GREATEST(open_price,close_price) OR low_price > LEAST(open_price,close_price))::bigint AS ohlc_order_failures
FROM asrp.q2_market_1m_observations WHERE source_member_ordinal IN ($ordinalList)
"@))[0]
    if ([long]$usdIntegrity.observed_usd_pairs -ne $ExpectedDirectUsdPairs) { throw 'Direct-USD market pair coverage changed.' }
    foreach ($n in @('null_ohlc_rows','nonpositive_ohlc_rows','nonfinite_ohlc_rows','ohlc_order_failures')) { if ([long]$usdIntegrity.$n -ne 0) { throw "Direct-USD OHLC integrity failure: $n=$($usdIntegrity.$n)" } }

    $dailyCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
WITH first_rows AS (
    SELECT DISTINCT ON (source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date)
           source_member_ordinal,pair_token_opaque,(candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
           candle_start_utc AS first_candle_start_utc,open_price AS first_open_price,
           physical_record_number AS first_physical_record_number,raw_record_sha256 AS first_raw_record_sha256,
           canonical_eligible AS first_canonical_eligible,in_source_window AS first_in_source_window,
           minute_aligned AS first_minute_aligned,cardinality(quality_flags) AS first_quality_flag_count,
           duplicate_class AS first_duplicate_class
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    ORDER BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date,candle_start_utc ASC,physical_record_number ASC
), last_rows AS (
    SELECT DISTINCT ON (source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date)
           source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
           candle_start_utc AS last_candle_start_utc,close_price AS last_close_price,
           physical_record_number AS last_physical_record_number,raw_record_sha256 AS last_raw_record_sha256,
           canonical_eligible AS last_canonical_eligible,in_source_window AS last_in_source_window,
           minute_aligned AS last_minute_aligned,cardinality(quality_flags) AS last_quality_flag_count,
           duplicate_class AS last_duplicate_class
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
    ORDER BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date,candle_start_utc DESC,physical_record_number DESC
)
SELECT f.source_member_ordinal,f.pair_token_opaque,f.utc_day,
       f.first_candle_start_utc,f.first_open_price,f.first_physical_record_number,f.first_raw_record_sha256,
       f.first_canonical_eligible,f.first_in_source_window,f.first_minute_aligned,f.first_quality_flag_count,f.first_duplicate_class,
       l.last_candle_start_utc,l.last_close_price,l.last_physical_record_number,l.last_raw_record_sha256,
       l.last_canonical_eligible,l.last_in_source_window,l.last_minute_aligned,l.last_quality_flag_count,l.last_duplicate_class,
       ((extract(hour FROM f.first_candle_start_utc AT TIME ZONE 'UTC')::int*60)+extract(minute FROM f.first_candle_start_utc AT TIME ZONE 'UTC')::int)::int AS first_minutes_after_midnight,
       (1439-((extract(hour FROM l.last_candle_start_utc AT TIME ZONE 'UTC')::int*60)+extract(minute FROM l.last_candle_start_utc AT TIME ZONE 'UTC')::int))::int AS last_minutes_before_midnight,
       (extract(epoch FROM (l.last_candle_start_utc-f.first_candle_start_utc))/60)::int AS observed_span_minutes_between_starts
FROM first_rows f
JOIN last_rows l USING(source_member_ordinal,utc_day)
ORDER BY f.source_member_ordinal,f.utc_day
"@
    $sourcePath = Join-Path $runDir 'stage4-v3-first-last-source.csv'
    Write-Utf8NoBom $sourcePath ($dailyCsv + [Environment]::NewLine)
    $dailyRaw = @(Convert-CsvText $dailyCsv)
    if ($dailyRaw.Count -ne $ExpectedActiveUsdPairDays) { throw "V3 active pair-day count changed: $($dailyRaw.Count), expected $ExpectedActiveUsdPairDays." }

    $responses = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($r in $dailyRaw) {
        $ord = ([string]$r.source_member_ordinal).Trim()
        if (-not $ordinalMap.ContainsKey($ord)) { throw "Unexpected USD ordinal: $ord" }
        $af = $ordinalMap[$ord]
        if (([string]$r.pair_token_opaque).Trim() -ne ([string]$af.pair_token_opaque).Trim()) { throw "Pair token mismatch for ordinal $ord." }
        $day = [datetime]::ParseExact([string]$r.utc_day,'yyyy-MM-dd',$Invariant)
        $key = ([string]$af.base_asset_id) + '|' + $day.ToString('yyyy-MM-dd',$Invariant)
        if ($seen.ContainsKey($key)) { throw "Duplicate V3 response key: $key" }
        $seen[$key] = $true
        foreach ($prefix in @('first','last')) {
            if (-not (Parse-BoolStrict $r.($prefix+'_canonical_eligible') ($prefix+'_canonical_eligible')) -or
                -not (Parse-BoolStrict $r.($prefix+'_in_source_window') ($prefix+'_in_source_window')) -or
                -not (Parse-BoolStrict $r.($prefix+'_minute_aligned') ($prefix+'_minute_aligned')) -or
                [int]$r.($prefix+'_quality_flag_count') -ne 0 -or
                -not [string]::IsNullOrWhiteSpace([string]$r.($prefix+'_duplicate_class'))) { throw "Invalid selected $prefix row: $key" }
        }
        $firstOpen = Parse-DoubleStrict $r.first_open_price "first_open_price $key"
        $lastClose = Parse-DoubleStrict $r.last_close_price "last_close_price $key"
        if ($firstOpen -le 0 -or $lastClose -le 0) { throw "Non-positive selected V3 price: $key" }
        $firstTs = [DateTimeOffset]::Parse([string]$r.first_candle_start_utc,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
        $lastTs = [DateTimeOffset]::Parse([string]$r.last_candle_start_utc,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
        if ($firstTs.Date -ne $day.Date -or $lastTs.Date -ne $day.Date -or $firstTs -gt $lastTs) { throw "V3 first/last timestamp boundary failure: $key" }
        $firstMinutes = $firstTs.Hour*60 + $firstTs.Minute
        $lastLag = 1439-($lastTs.Hour*60 + $lastTs.Minute)
        $span = [int](($lastTs-$firstTs).TotalMinutes)
        if ([int]$r.first_minutes_after_midnight -ne $firstMinutes -or [int]$r.last_minutes_before_midnight -ne $lastLag -or [int]$r.observed_span_minutes_between_starts -ne $span) { throw "V3 timing-field reconciliation failure: $key" }
        $daily = [pscustomobject]@{
            utc_day_value=$day;first_candle_start_utc_value=$firstTs;last_candle_start_utc_value=$lastTs;
            first_minutes_after_midnight=$firstMinutes;last_minutes_before_midnight=$lastLag;observed_span_minutes_between_starts=$span;
            first_open_price_text=[string]$r.first_open_price;first_open_price_value=$firstOpen;last_close_price_text=[string]$r.last_close_price;last_close_price_value=$lastClose;
            first_physical_record_number=[string]$r.first_physical_record_number;last_physical_record_number=[string]$r.last_physical_record_number;
            first_raw_record_sha256=[string]$r.first_raw_record_sha256;last_raw_record_sha256=[string]$r.last_raw_record_sha256
        }
        [void]$responses.Add((Build-ResponseRow -DailyRow $daily -AfRow $af))
    }

    if ($responses.Count -ne $ExpectedActiveUsdPairDays) { throw "V3 response count changed: $($responses.Count), expected $ExpectedActiveUsdPairDays." }
    $responseArray = @($responses.ToArray())
    $distinctBases = @($responseArray | Select-Object -ExpandProperty base_asset_id -Unique).Count
    if ($distinctBases -ne $ExpectedDirectUsdBases) { throw "V3 distinct response base count changed: $distinctBases, expected $ExpectedDirectUsdBases." }

    $formulaFailures = 0
    $boundaryFailures = 0
    foreach ($r in $responseArray) {
        $first = Parse-DoubleStrict $r.first_open_price_usd 'V3 first open'
        $last = Parse-DoubleStrict $r.last_close_price_usd 'V3 last close'
        $actual = Parse-DoubleStrict $r.response_value_log_return 'V3 response'
        if ([Math]::Abs($actual-[Math]::Log($last/$first)) -gt 1e-12) { $formulaFailures++ }
        $cutoff = [DateTimeOffset]::Parse([string]$r.predictor_cutoff_utc).UtcDateTime
        $available = [DateTimeOffset]::Parse([string]$r.response_available_utc).UtcDateTime
        $firstTs = [DateTimeOffset]::Parse([string]$r.first_candle_start_utc).UtcDateTime
        $lastTs = [DateTimeOffset]::Parse([string]$r.last_candle_start_utc).UtcDateTime
        if ($available -ne $cutoff.AddDays(1) -or $firstTs -lt $cutoff -or $lastTs -lt $cutoff -or $firstTs -ge $available -or $lastTs -ge $available -or $firstTs -gt $lastTs) { $boundaryFailures++ }
    }
    if ($formulaFailures -ne 0 -or $boundaryFailures -ne 0) { throw "V3 full validation failed: formula=$formulaFailures boundary=$boundaryFailures" }

    $responsePath = Join-Path $runDir 'stage4-responses-v3.csv'
    $responseArray | Export-Csv -LiteralPath $responsePath -NoTypeInformation -Encoding UTF8

    $sampleMap = @{}
    $sample = New-Object System.Collections.ArrayList
    $addSample = {
        param($row,$reason)
        $key = $row.base_asset_id + '|' + $row.response_day_utc
        if (-not $sampleMap.ContainsKey($key)) {
            $sampleMap[$key]=$true
            $copy=[ordered]@{}
            foreach($p in $row.PSObject.Properties){$copy[$p.Name]=$p.Value}
            $copy['review_reason']=$reason
            [void]$sample.Add([pscustomobject]$copy)
        }
    }
    foreach($r in @($responseArray | Sort-Object response_day_utc,base_asset_id | Select-Object -First 5)){&$addSample $r 'EARLIEST'}
    foreach($r in @($responseArray | Sort-Object response_day_utc,base_asset_id -Descending | Select-Object -First 5)){&$addSample $r 'LATEST'}
    foreach($r in @($responseArray | Sort-Object {[Math]::Abs([double]::Parse($_.response_value_log_return,$Invariant))} -Descending | Select-Object -First 10)){&$addSample $r 'LARGEST_ABS_RETURN'}
    foreach($r in @($responseArray | Sort-Object {[int]$_.first_minutes_after_midnight} -Descending | Select-Object -First 10)){&$addSample $r 'LATEST_FIRST_OBSERVATION'}
    foreach($r in @($responseArray | Sort-Object {[int]$_.last_minutes_before_midnight} -Descending | Select-Object -First 10)){&$addSample $r 'EARLIEST_LAST_OBSERVATION'}
    foreach($r in @($responseArray | Sort-Object {[int]$_.observed_span_minutes_between_starts},response_day_utc,base_asset_id | Select-Object -First 10)){&$addSample $r 'SHORTEST_OBSERVED_SPAN'}
    $samplePath = Join-Path $runDir 'stage4-response-v3-review-sample.csv'
    @($sample.ToArray()) | Export-Csv -LiteralPath $samplePath -NoTypeInformation -Encoding UTF8

    $daySummaryPath = Join-Path $runDir 'stage4-response-v3-day-summary.csv'
    @($responseArray | Group-Object response_day_utc | ForEach-Object { [pscustomobject]@{response_day_utc=$_.Name;response_rows=$_.Count;distinct_bases=@($_.Group|Select-Object -ExpandProperty base_asset_id -Unique).Count} } | Sort-Object response_day_utc) | Export-Csv -LiteralPath $daySummaryPath -NoTypeInformation -Encoding UTF8

    $receipt = [ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_4';response_contract='CANDIDATE_UTC_DAY_OBSERVED_V3';response_id=$ResponseId;
        source_relation='asrp.q2_market_1m_observations';af001_sha256=$ExpectedAf001Sha256;direct_usd_pairs=$ExpectedDirectUsdPairs;direct_usd_bases=$ExpectedDirectUsdBases;
        active_usd_pair_days=$ExpectedActiveUsdPairDays;response_rows=$responseArray.Count;distinct_response_bases=$distinctBases;
        min_response_day=(@($responseArray|Sort-Object response_day_utc|Select-Object -First 1)[0].response_day_utc);max_response_day=(@($responseArray|Sort-Object response_day_utc -Descending|Select-Object -First 1)[0].response_day_utc);
        formula='ln(last_observed_close_within_d / first_observed_open_within_d)';response_semantics='observed within-UTC-day log return; not a fixed-duration 24-hour return';
        missing_policy='no row if UTC day has no valid direct-USD observation; no imputation/carry/interpolation/substitution';
        responses_csv=$responsePath;responses_sha256=(Get-Sha $responsePath);review_sample_csv=$samplePath;review_sample_sha256=(Get-Sha $samplePath);day_summary_csv=$daySummaryPath;day_summary_sha256=(Get-Sha $daySummaryPath);
        gates=[ordered]@{'CFA-S4-002'='PASS';'CFA-S4-003'='PASS';'CFA-S4-004'='FAIL';'CFA-S4-005'='FAIL';'CFA-S4-007'='PASS';'CFA-S4-008'='FAIL';'CFA-S4-009'='FAIL';'CFA-S4-011'='FAIL';'CFA-S4-012'='PASS';'CFA-S4-013'='PASS';'CFA-S4-014'='UNVERIFIED';'CFA-S4-015'='BLOCKED'};
        next_action='Directly review every row in review_sample_csv and freeze only if cutoff, first/last selection, formula, timing, observed-span semantics, and lineage are clean.'
    }
    $receiptPath = Join-Path $runDir 'stage4-response-v3-candidate.json'
    Write-Utf8NoBom $receiptPath (($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 4 V3 CUTOFF-SAFE RESPONSE CONSTRUCTION: VALIDATION CANDIDATE'
    Write-Host "Response rows: $($responseArray.Count)"
    Write-Host "Distinct response bases: $distinctBases"
    Write-Host "Review rows: $($sample.Count)"
    Write-Host 'CFA-S4-012 V3 response rule: PASS'
    Write-Host 'CFA-S4-013 V3 response construction: PASS'
    Write-Host 'CFA-S4-014 direct V3 review: UNVERIFIED'
    Write-Host 'CFA-S4-015 freeze responses: BLOCKED'
    Write-Host "Review CSV: $samplePath"
    Write-Host "Candidate receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 4 V3 CUTOFF-SAFE RESPONSE CONSTRUCTION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD=$oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS=$oldPgOptions }
}
