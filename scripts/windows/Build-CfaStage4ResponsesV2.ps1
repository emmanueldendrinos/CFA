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

$ResponseId = 'RET_USD_1D_LOG_LAST_OBS'
$ExpectedAf001Sha256 = '569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAf001Rows = 1059
$ExpectedEligibleRows = 1058
$ExpectedEligibleBaseAssets = 435
$ExpectedDirectUsdPairs = 434
$ExpectedDirectUsdBases = 434
$ExpectedActiveUsdPairDays = 37058
$ExpectedResponses = 36505
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

function Build-ResponseRows {
    param([object[]]$DailyCloses)
    $byKey = @{}
    foreach ($c in $DailyCloses) {
        $key = ([string]$c.base_asset_id) + '|' + ([datetime]$c.utc_day).ToString('yyyy-MM-dd',$Invariant)
        if ($byKey.ContainsKey($key)) { throw "Duplicate daily-close key: $key" }
        $byKey[$key] = $c
    }
    $result = New-Object System.Collections.ArrayList
    foreach ($c in @($DailyCloses | Sort-Object base_asset_id,utc_day)) {
        $day = [datetime]$c.utc_day
        if ($day -lt $Q2Start.AddDays(1) -or $day -ge $Q2EndExclusive) { continue }
        $prevDay = $day.AddDays(-1)
        $prevKey = ([string]$c.base_asset_id) + '|' + $prevDay.ToString('yyyy-MM-dd',$Invariant)
        if (-not $byKey.ContainsKey($prevKey)) { continue }
        $p = $byKey[$prevKey]
        $prior = [double]$p.close_price_value
        $current = [double]$c.close_price_value
        $value = [Math]::Log($current / $prior)
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "Non-finite response for $($c.base_asset_id) $day" }
        $cutoff = [datetime]::SpecifyKind($day,[DateTimeKind]::Utc)
        $available = $cutoff.AddDays(1)
        $priorTs = [datetime]$p.candle_start_utc_value
        $currentTs = [datetime]$c.candle_start_utc_value
        [void]$result.Add([pscustomobject][ordered]@{
            response_id = $ResponseId
            base_asset_id = [string]$c.base_asset_id
            pair_token_opaque = [string]$c.pair_token_opaque
            source_member_ordinal = [string]$c.source_member_ordinal
            response_day_utc = $day.ToString('yyyy-MM-dd',$Invariant)
            predictor_cutoff_utc = Format-Utc $cutoff
            response_available_utc = Format-Utc $available
            prior_close_candle_start_utc = Format-Utc $priorTs
            current_close_candle_start_utc = Format-Utc $currentTs
            prior_minutes_before_midnight = [string]$p.minutes_before_midnight
            current_minutes_before_midnight = [string]$c.minutes_before_midnight
            elapsed_minutes_between_close_starts = [string][int](($currentTs - $priorTs).TotalMinutes)
            prior_close_price_usd = [string]$p.close_price_text
            current_close_price_usd = [string]$c.close_price_text
            response_value_log_return = $value.ToString('R',$Invariant)
            prior_physical_record_number = [string]$p.physical_record_number
            current_physical_record_number = [string]$c.physical_record_number
            prior_raw_record_sha256 = [string]$p.raw_record_sha256
            current_raw_record_sha256 = [string]$c.raw_record_sha256
        })
    }
    return @($result.ToArray())
}

function Invoke-SelfTest {
    if (-not (Parse-BoolStrict 'True' 'selftest true')) { throw 'Self-test failed: True was not parsed as true.' }
    if (-not (Parse-BoolStrict 't' 'selftest PostgreSQL t')) { throw 'Self-test failed: PostgreSQL t was not parsed as true.' }
    if (Parse-BoolStrict 'False' 'selftest false') { throw 'Self-test failed: False was not parsed as false.' }
    if (Parse-BoolStrict 'f' 'selftest PostgreSQL f') { throw 'Self-test failed: PostgreSQL f was not parsed as false.' }
    $fake = @(
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1';utc_day=[datetime]'2025-04-01';candle_start_utc_value=[datetime]'2025-04-01T18:00:00Z';close_price_text='100';close_price_value=100.0;minutes_before_midnight=359;physical_record_number='1';raw_record_sha256=('a'*64)},
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1';utc_day=[datetime]'2025-04-02';candle_start_utc_value=[datetime]'2025-04-02T12:00:00Z';close_price_text='110';close_price_value=110.0;minutes_before_midnight=719;physical_record_number='2';raw_record_sha256=('b'*64)},
        [pscustomobject]@{base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1';utc_day=[datetime]'2025-04-04';candle_start_utc_value=[datetime]'2025-04-04T23:58:00Z';close_price_text='121';close_price_value=121.0;minutes_before_midnight=1;physical_record_number='3';raw_record_sha256=('c'*64)}
    )
    $r = @(Build-ResponseRows $fake)
    if ($r.Count -ne 1) { throw "Self-test expected one response, observed $($r.Count)." }
    if ($r[0].response_day_utc -ne '2025-04-02') { throw 'Self-test bridged a missing day.' }
    $v = Parse-DoubleStrict $r[0].response_value_log_return 'selftest'
    if ([Math]::Abs($v-[Math]::Log(1.1)) -gt 1e-12) { throw 'Self-test formula mismatch.' }
    if ($r[0].current_minutes_before_midnight -ne '719') { throw 'Self-test did not preserve day-end lag.' }
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
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage4-responses-v2' }
    $runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $contractPath = Join-Path $RepoRoot 'docs\evidence\stage4-response-contract.md'
    $contract = Get-Content -LiteralPath $contractPath -Raw
    if ($contract -notmatch 'LAST_OBSERVED_RULE_FROZEN_FOR_VALIDATION' -or $contract -notmatch 'CFA-S4-008' -or $contract -notmatch 'Define corrected last-observed-daily-close response rule\s*\|\s*PASS') { throw 'Corrected Stage 4 response rule is not frozen as PASS for validation.' }

    $afPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    if ((Get-Sha $afPath) -ne $ExpectedAf001Sha256) { throw 'AF-001 SHA-256 mismatch.' }
    $population = Get-AfPopulation @(Import-Csv -LiteralPath $afPath)
    $ordinalMap = @{}
    foreach ($u in $population.usd) { $ordinalMap[([string]$u.source_member_ordinal).Trim()] = $u }
    $ordinalList = (@($ordinalMap.Keys | ForEach-Object { [long]$_ } | Sort-Object) -join ',')

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    Write-Host "Corrected response ID: $ResponseId"
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
SELECT DISTINCT ON (source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date)
       source_member_ordinal,pair_token_opaque,(candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day,
       candle_start_utc,close_price,physical_record_number,raw_record_sha256,
       canonical_eligible,in_source_window,minute_aligned,cardinality(quality_flags) AS quality_flag_count,duplicate_class,
       (1439-((extract(hour FROM candle_start_utc AT TIME ZONE 'UTC')::int*60)+extract(minute FROM candle_start_utc AT TIME ZONE 'UTC')::int))::int AS minutes_before_midnight
FROM asrp.q2_market_1m_observations
WHERE source_member_ordinal IN ($ordinalList)
ORDER BY source_member_ordinal,(candle_start_utc AT TIME ZONE 'UTC')::date,candle_start_utc DESC,physical_record_number DESC
"@
    $dailySourcePath = Join-Path $runDir 'stage4-last-observed-daily-close-source.csv'
    Write-Utf8NoBom $dailySourcePath ($dailyCsv + [Environment]::NewLine)
    $dailyRaw = @(Convert-CsvText $dailyCsv)
    if ($dailyRaw.Count -ne $ExpectedActiveUsdPairDays) { throw "Active USD pair-day count changed: $($dailyRaw.Count), expected $ExpectedActiveUsdPairDays." }

    $daily = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($r in $dailyRaw) {
        $ord = ([string]$r.source_member_ordinal).Trim()
        if (-not $ordinalMap.ContainsKey($ord)) { throw "Unexpected USD ordinal: $ord" }
        $af = $ordinalMap[$ord]
        if (([string]$r.pair_token_opaque).Trim() -ne ([string]$af.pair_token_opaque).Trim()) { throw "Pair token mismatch for ordinal $ord." }
        $day = [datetime]::ParseExact([string]$r.utc_day,'yyyy-MM-dd',$Invariant)
        $key = ([string]$af.base_asset_id) + '|' + $day.ToString('yyyy-MM-dd',$Invariant)
        if ($seen.ContainsKey($key)) { throw "Duplicate daily last-close key: $key" }
        $seen[$key] = $true
        if (-not (Parse-BoolStrict $r.canonical_eligible 'canonical_eligible') -or -not (Parse-BoolStrict $r.in_source_window 'in_source_window') -or -not (Parse-BoolStrict $r.minute_aligned 'minute_aligned') -or [int]$r.quality_flag_count -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$r.duplicate_class)) { throw "Invalid selected daily close: $key" }
        $price = Parse-DoubleStrict $r.close_price "close_price $key"
        if ($price -le 0) { throw "Non-positive selected daily close: $key" }
        $ts = [DateTimeOffset]::Parse([string]$r.candle_start_utc,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
        if ($ts.Date -ne $day.Date) { throw "Selected close timestamp/day mismatch: $key" }
        [void]$daily.Add([pscustomobject]@{
            base_asset_id=[string]$af.base_asset_id;pair_token_opaque=[string]$af.pair_token_opaque;source_member_ordinal=$ord;
            utc_day=$day;candle_start_utc_value=$ts;close_price_text=[string]$r.close_price;close_price_value=$price;
            minutes_before_midnight=[int]$r.minutes_before_midnight;physical_record_number=[string]$r.physical_record_number;raw_record_sha256=[string]$r.raw_record_sha256
        })
    }

    $responses = @(Build-ResponseRows @($daily.ToArray()))
    if ($responses.Count -ne $ExpectedResponses) { throw "Corrected response count changed: $($responses.Count), expected $ExpectedResponses." }
    if (@($responses | Group-Object { $_.base_asset_id + '|' + $_.response_day_utc } | Where-Object Count -gt 1).Count -ne 0) { throw 'Duplicate corrected response keys observed.' }

    $formulaFailures = 0
    $timingFailures = 0
    foreach ($r in $responses) {
        $prior = Parse-DoubleStrict $r.prior_close_price_usd 'prior close'
        $current = Parse-DoubleStrict $r.current_close_price_usd 'current close'
        $actual = Parse-DoubleStrict $r.response_value_log_return 'response'
        if ([Math]::Abs($actual-[Math]::Log($current/$prior)) -gt 1e-12) { $formulaFailures++ }
        $day = [datetime]::ParseExact([string]$r.response_day_utc,'yyyy-MM-dd',$Invariant)
        $cutoff = [DateTimeOffset]::Parse([string]$r.predictor_cutoff_utc).UtcDateTime
        $available = [DateTimeOffset]::Parse([string]$r.response_available_utc).UtcDateTime
        $priorTs = [DateTimeOffset]::Parse([string]$r.prior_close_candle_start_utc).UtcDateTime
        $currentTs = [DateTimeOffset]::Parse([string]$r.current_close_candle_start_utc).UtcDateTime
        if ($cutoff -ne [datetime]::SpecifyKind($day,[DateTimeKind]::Utc) -or $available -ne $cutoff.AddDays(1) -or $priorTs.Date -ne $day.AddDays(-1).Date -or $currentTs.Date -ne $day.Date) { $timingFailures++ }
    }
    if ($formulaFailures -ne 0 -or $timingFailures -ne 0) { throw "Full response validation failed: formula=$formulaFailures timing=$timingFailures" }

    $responsePath = Join-Path $runDir 'stage4-responses.csv'
    $responses | Export-Csv -LiteralPath $responsePath -NoTypeInformation -Encoding UTF8

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
    foreach($r in @($responses | Sort-Object response_day_utc,base_asset_id | Select-Object -First 5)){&$addSample $r 'EARLIEST'}
    foreach($r in @($responses | Sort-Object response_day_utc,base_asset_id -Descending | Select-Object -First 5)){&$addSample $r 'LATEST'}
    foreach($r in @($responses | Sort-Object {[Math]::Abs([double]::Parse($_.response_value_log_return,$Invariant))} -Descending | Select-Object -First 10)){&$addSample $r 'LARGEST_ABS_RETURN'}
    foreach($r in @($responses | Sort-Object {[int]$_.current_minutes_before_midnight} -Descending | Select-Object -First 10)){&$addSample $r 'LARGEST_CURRENT_DAY_END_LAG'}
    foreach($r in @($responses | Sort-Object {[int]$_.prior_minutes_before_midnight} -Descending | Select-Object -First 10)){&$addSample $r 'LARGEST_PRIOR_DAY_END_LAG'}
    $samplePath = Join-Path $runDir 'stage4-response-review-sample.csv'
    @($sample.ToArray()) | Export-Csv -LiteralPath $samplePath -NoTypeInformation -Encoding UTF8

    $daySummaryPath = Join-Path $runDir 'stage4-response-day-summary.csv'
    @($responses | Group-Object response_day_utc | ForEach-Object { [pscustomobject]@{response_day_utc=$_.Name;response_rows=$_.Count;distinct_bases=@($_.Group|Select-Object -ExpandProperty base_asset_id -Unique).Count} } | Sort-Object response_day_utc) | Export-Csv -LiteralPath $daySummaryPath -NoTypeInformation -Encoding UTF8

    $receipt = [ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_4';response_contract='CANDIDATE_LAST_OBSERVED_V2';response_id=$ResponseId;
        source_relation='asrp.q2_market_1m_observations';af001_sha256=$ExpectedAf001Sha256;direct_usd_pairs=$ExpectedDirectUsdPairs;direct_usd_bases=$ExpectedDirectUsdBases;
        active_usd_pair_days=$dailyRaw.Count;response_rows=$responses.Count;distinct_response_bases=@($responses|Select-Object -ExpandProperty base_asset_id -Unique).Count;
        min_response_day=(@($responses|Sort-Object response_day_utc|Select-Object -First 1)[0].response_day_utc);max_response_day=(@($responses|Sort-Object response_day_utc -Descending|Select-Object -First 1)[0].response_day_utc);
        formula='ln(last_observed_close_on_d / last_observed_close_on_d_minus_1)';missing_policy='exclude if either consecutive UTC day has no valid direct-USD observation; no imputation/carry/interpolation/substitution';
        responses_csv=$responsePath;responses_sha256=(Get-Sha $responsePath);review_sample_csv=$samplePath;review_sample_sha256=(Get-Sha $samplePath);day_summary_csv=$daySummaryPath;day_summary_sha256=(Get-Sha $daySummaryPath);
        gates=[ordered]@{'CFA-S4-002'='PASS';'CFA-S4-003'='PASS';'CFA-S4-004'='FAIL';'CFA-S4-005'='FAIL';'CFA-S4-007'='PASS';'CFA-S4-008'='PASS';'CFA-S4-009'='PASS';'CFA-S4-010'='BLOCKED'};
        next_action='Directly review every row in review_sample_csv and freeze only if no formula, timing, boundary, missingness, or lineage defect remains.'
    }
    $receiptPath = Join-Path $runDir 'stage4-response-candidate.json'
    Write-Utf8NoBom $receiptPath (($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 4 CORRECTED RESPONSE CONSTRUCTION: VALIDATION CANDIDATE'
    Write-Host "Response rows: $($responses.Count)"
    Write-Host "Distinct response bases: $(@($responses|Select-Object -ExpandProperty base_asset_id -Unique).Count)"
    Write-Host "Active USD pair-days: $($dailyRaw.Count)"
    Write-Host "Review rows: $($sample.Count)"
    Write-Host 'CFA-S4-008 corrected response rule: PASS'
    Write-Host 'CFA-S4-009 corrected response construction: PASS'
    Write-Host 'CFA-S4-010 freeze responses: BLOCKED'
    Write-Host "Review CSV: $samplePath"
    Write-Host "Candidate receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 4 CORRECTED RESPONSE CONSTRUCTION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD=$oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS=$oldPgOptions }
}