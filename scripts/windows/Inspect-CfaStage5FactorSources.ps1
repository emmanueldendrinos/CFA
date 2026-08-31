#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V6MatchesPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$Stage3ArchiveRoot = 'D:\CFA-bulk\source\gdelt-gkg-q2-2025',
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

$Invariant = [Globalization.CultureInfo]::InvariantCulture
$ExpectedAf001Sha256 = '569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedStage3AliasSha256 = '11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'
$ExpectedStage4ResponsesSha256 = '8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedResponseId = 'RET_USD_UTC_DAY_OBS_LOG'
$ExpectedAf001Rows = 1059
$ExpectedEligibleRows = 1058
$ExpectedEligibleBases = 435
$ExpectedDirectUsdPairs = 434
$ExpectedDirectUsdBases = 434
$ExpectedStage3AliasRows = 470
$ExpectedStage3NewsAssets = 431
$ExpectedStage3Matches = 22060
$ExpectedStage3MatchedAssets = 282
$ExpectedStage3DistinctRecords = 18503
$ExpectedStage3Archives = 7163
$ExpectedStage4Rows = 37058
$ExpectedStage4Bases = 434
$ExpectedMarketRows = 14055089L
$ExpectedMarketPairs = 1058L

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

function Parse-GdeltUtc {
    param([object]$Value,[string]$Label)
    $text = ([string]$Value).Trim()
    if ($text -notmatch '^\d{14}$') { throw "Malformed GDELT timestamp for ${Label}: '$Value'" }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($text,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$dt)) { throw "Unparseable GDELT timestamp for ${Label}: '$Value'" }
    return [datetime]::SpecifyKind($dt,[DateTimeKind]::Utc)
}

function Require-Columns {
    param([object]$Row,[string[]]$Names,[string]$Label)
    $props = @($Row.PSObject.Properties.Name)
    foreach ($name in $Names) { if ($props -notcontains $name) { throw "$Label required column missing: $name" } }
}

function Get-AfPopulation {
    param([object[]]$Rows)
    if ($Rows.Count -ne $ExpectedAf001Rows) { throw "AF-001 row count mismatch: $($Rows.Count)." }
    Require-Columns $Rows[0] @('source_member_ordinal','pair_token_opaque','base_asset_id','quote_exchange_symbol','research_eligible') 'AF-001'
    $eligible = @($Rows | Where-Object { Parse-BoolStrict $_.research_eligible "AF-001 $($_.pair_token_opaque) research_eligible" })
    if ($eligible.Count -ne $ExpectedEligibleRows) { throw "AF-001 eligible rows changed: $($eligible.Count)." }
    $eligibleBases = @($eligible | Select-Object -ExpandProperty base_asset_id -Unique)
    if ($eligibleBases.Count -ne $ExpectedEligibleBases) { throw "AF-001 eligible bases changed: $($eligibleBases.Count)." }
    $usd = @($eligible | Where-Object { ([string]$_.quote_exchange_symbol).Trim() -ceq 'USD' })
    $usdBases = @($usd | Select-Object -ExpandProperty base_asset_id -Unique)
    if ($usd.Count -ne $ExpectedDirectUsdPairs -or $usdBases.Count -ne $ExpectedDirectUsdBases) { throw "Direct-USD population changed: pairs=$($usd.Count), bases=$($usdBases.Count)." }
    if (@($usd | Group-Object base_asset_id | Where-Object Count -gt 1).Count -ne 0) { throw 'Duplicate direct-USD base identities detected.' }
    return [pscustomobject]@{ eligible=$eligible; eligible_bases=$eligibleBases; usd=$usd; usd_bases=$usdBases }
}

function Invoke-SelfTest {
    foreach ($probe in @('True','true','t')) { if (-not (Parse-BoolStrict $probe 'true')) { throw 'Boolean true self-test failed.' } }
    foreach ($probe in @('False','false','f')) { if (Parse-BoolStrict $probe 'false') { throw 'Boolean false self-test failed.' } }
    $d = Parse-GdeltUtc '20250401001500' 'selftest'
    if ($d.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant) -ne '2025-04-01T00:15:00Z') { throw 'GDELT timestamp self-test failed.' }
    $response = @('A','B','C')
    $news = @('B','C','D')
    $onlyResponse = @($response | Where-Object { $news -notcontains $_ })
    $onlyNews = @($news | Where-Object { $response -notcontains $_ })
    if ($onlyResponse.Count -ne 1 -or $onlyResponse[0] -ne 'A' -or $onlyNews.Count -ne 1 -or $onlyNews[0] -ne 'D') { throw 'Set reconciliation self-test failed.' }
    $singleDifference = @(Compare-Object @('A') @())
    if ($singleDifference.Count -ne 1) { throw 'Strict-mode scalar Compare-Object count self-test failed.' }
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
    $Stage3V6MatchesPath = (Resolve-Path -LiteralPath $Stage3V6MatchesPath).ProviderPath
    $Stage4ResponsesPath = (Resolve-Path -LiteralPath $Stage4ResponsesPath).ProviderPath
    $Stage3ArchiveRoot = (Resolve-Path -LiteralPath $Stage3ArchiveRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage5-factor-sources' }
    $runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $stage4Contract = Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage4-response-contract.md') -Raw
    if ($stage4Contract -notmatch 'STAGE4_FROZEN' -or $stage4Contract -notmatch 'CFA-S4-015[^\r\n]*PASS') { throw 'Stage 4 is not frozen PASS in the repository contract.' }

    $stage5Contract = Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage5-factor-contract.md') -Raw
    if ($stage5Contract -notmatch 'CFA-S5-001[^\r\n]*PASS') { throw 'Stage 5 entry gate is not PASS.' }

    $afPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    if ((Get-Sha $afPath) -ne $ExpectedAf001Sha256) { throw 'AF-001 SHA-256 mismatch.' }
    $af = Get-AfPopulation @(Import-Csv -LiteralPath $afPath)

    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if ((Get-Sha $aliasPath) -ne $ExpectedStage3AliasSha256) { throw 'Stage 3 alias-registry SHA-256 mismatch.' }
    $aliasRows = @(Import-Csv -LiteralPath $aliasPath)
    if ($aliasRows.Count -ne $ExpectedStage3AliasRows) { throw "Stage 3 alias rows changed: $($aliasRows.Count)." }
    Require-Columns $aliasRows[0] @('base_asset_id','alias_text','alias_type','requires_crypto_context','alias_source') 'Stage 3 alias registry'
    $newsPopulation = @($aliasRows | Select-Object -ExpandProperty base_asset_id -Unique | Sort-Object)
    if ($newsPopulation.Count -ne $ExpectedStage3NewsAssets) { throw "Stage 3 news population changed: $($newsPopulation.Count)." }

    if ((Get-Sha $Stage4ResponsesPath) -ne $ExpectedStage4ResponsesSha256) { throw 'Stage 4 response CSV SHA-256 mismatch.' }
    $responses = @(Import-Csv -LiteralPath $Stage4ResponsesPath)
    if ($responses.Count -ne $ExpectedStage4Rows) { throw "Stage 4 response rows changed: $($responses.Count)." }
    Require-Columns $responses[0] @('response_id','base_asset_id','response_day_utc','predictor_cutoff_utc','response_available_utc') 'Stage 4 responses'
    $responseIds = @($responses | Select-Object -ExpandProperty response_id -Unique)
    if ($responseIds.Count -ne 1 -or [string]$responseIds[0] -ne $ExpectedResponseId) { throw "Stage 4 response ID set changed: $(@($responseIds) -join ', ')." }
    $responseBases = @($responses | Select-Object -ExpandProperty base_asset_id -Unique | Sort-Object)
    if ($responseBases.Count -ne $ExpectedStage4Bases) { throw "Stage 4 response bases changed: $($responseBases.Count)." }
    $afUsdBases = @($af.usd_bases | ForEach-Object { [string]$_ } | Sort-Object)
    if (@(Compare-Object $responseBases $afUsdBases).Count -ne 0) { throw 'Stage 4 response base set does not equal frozen AF-001 direct-USD base set.' }

    $intersection = @($responseBases | Where-Object { $newsPopulation -contains $_ })
    $responseOnly = @($responseBases | Where-Object { $newsPopulation -notcontains $_ })
    $newsOnly = @($newsPopulation | Where-Object { $responseBases -notcontains $_ })

    $populationRows = New-Object System.Collections.ArrayList
    foreach ($asset in $responseBases) {
        [void]$populationRows.Add([pscustomobject][ordered]@{
            base_asset_id=$asset
            in_response_direct_usd=$true
            in_stage3_news_population=($newsPopulation -contains $asset)
            population_class=if($newsPopulation -contains $asset){'INTERSECTION'}else{'RESPONSE_ONLY_OUTSIDE_NEWS_POPULATION'}
        })
    }
    foreach ($asset in $newsOnly) {
        [void]$populationRows.Add([pscustomobject][ordered]@{base_asset_id=$asset;in_response_direct_usd=$false;in_stage3_news_population=$true;population_class='NEWS_ONLY_NO_DIRECT_USD_RESPONSE'})
    }
    $populationPath = Join-Path $runDir 'stage5-population-reconciliation.csv'
    @($populationRows.ToArray()) | Sort-Object base_asset_id | Export-Csv -LiteralPath $populationPath -NoTypeInformation -Encoding UTF8

    $summaryPath = Join-Path (Split-Path -Parent $Stage3V6MatchesPath) 'stage3-match-summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { throw "Stage 3 V6 summary missing beside match CSV: $summaryPath" }
    $stage3Summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ([string]$stage3Summary.run_status -ne 'PASS' -or [string]$stage3Summary.matching_contract -ne 'CANDIDATE_V6') { throw 'Stage 3 match summary is not PASS CANDIDATE_V6.' }
    if ([long]$stage3Summary.matching.retained_asset_record_matches -ne $ExpectedStage3Matches -or [int]$stage3Summary.matching.matched_assets -ne $ExpectedStage3MatchedAssets -or [long]$stage3Summary.matching.duplicate_asset_record_matches -ne 0) { throw 'Stage 3 V6 summary matching counts changed.' }
    $matchesSha = Get-Sha $Stage3V6MatchesPath
    if ($matchesSha -ne ([string]$stage3Summary.output.matches_sha256).ToLowerInvariant()) { throw 'Stage 3 V6 match CSV hash does not match sibling summary.' }

    $matches = @(Import-Csv -LiteralPath $Stage3V6MatchesPath)
    if ($matches.Count -ne $ExpectedStage3Matches) { throw "Stage 3 V6 match rows changed: $($matches.Count)." }
    Require-Columns $matches[0] @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons') 'Stage 3 V6 matches'
    $matchKeys = New-Object 'Collections.Generic.HashSet[string]'
    $distinctRecordIds = New-Object 'Collections.Generic.HashSet[string]'
    $matchedAssetSet = New-Object 'Collections.Generic.HashSet[string]'
    $minNews = $null
    $maxNews = $null
    $dailyNews = @{}
    foreach ($m in $matches) {
        $key = ([string]$m.base_asset_id) + '|' + ([string]$m.record_id)
        if (-not $matchKeys.Add($key)) { throw "Duplicate Stage 3 asset/record key: $key" }
        [void]$distinctRecordIds.Add([string]$m.record_id)
        [void]$matchedAssetSet.Add([string]$m.base_asset_id)
        if ($newsPopulation -notcontains [string]$m.base_asset_id) { throw "Stage 3 match asset outside frozen news population: $($m.base_asset_id)" }
        $dt = Parse-GdeltUtc $m.gdelt_date_utc "record $($m.record_id)"
        if ($null -eq $minNews -or $dt -lt $minNews) { $minNews = $dt }
        if ($null -eq $maxNews -or $dt -gt $maxNews) { $maxNews = $dt }
        $day = $dt.ToString('yyyy-MM-dd',$Invariant)
        if (-not $dailyNews.ContainsKey($day)) { $dailyNews[$day] = 0L }
        $dailyNews[$day]++
    }
    if ($matchedAssetSet.Count -ne $ExpectedStage3MatchedAssets) { throw "Stage 3 distinct matched assets changed: $($matchedAssetSet.Count)." }
    if ($distinctRecordIds.Count -ne $ExpectedStage3DistinctRecords) { throw "Stage 3 distinct record IDs changed: $($distinctRecordIds.Count)." }
    $dailyNewsPath = Join-Path $runDir 'stage5-news-match-daily-counts.csv'
    @($dailyNews.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{utc_day=$_;asset_record_matches=$dailyNews[$_]} }) | Export-Csv -LiteralPath $dailyNewsPath -NoTypeInformation -Encoding UTF8

    $archiveFiles = @(Get-ChildItem -LiteralPath $Stage3ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip' | Where-Object { $_.Name -match '^\d{14}\.gkg\.csv\.zip$' } | Sort-Object Name)
    if ($archiveFiles.Count -ne $ExpectedStage3Archives) { throw "Stage 3 archive population changed: $($archiveFiles.Count)." }
    $archiveMin = Parse-GdeltUtc ($archiveFiles[0].Name.Substring(0,14)) 'earliest archive filename'
    $archiveMax = Parse-GdeltUtc ($archiveFiles[-1].Name.Substring(0,14)) 'latest archive filename'

    $priorMarketAvailable = 0L
    $priorMarketMissing = 0L
    $responseKeySet = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($r in $responses) { [void]$responseKeySet.Add(([string]$r.base_asset_id) + '|' + ([string]$r.response_day_utc)) }
    $priorDayByResponseDay = @{}
    foreach ($r in $responses) {
        $day = [datetime]::ParseExact([string]$r.response_day_utc,'yyyy-MM-dd',$Invariant)
        $prior = $day.AddDays(-1).ToString('yyyy-MM-dd',$Invariant)
        $priorKey = ([string]$r.base_asset_id) + '|' + $prior
        $present = $responseKeySet.Contains($priorKey)
        if ($present) { $priorMarketAvailable++ } else { $priorMarketMissing++ }
        $d = [string]$r.response_day_utc
        if (-not $priorDayByResponseDay.ContainsKey($d)) { $priorDayByResponseDay[$d] = [pscustomobject]@{response_day_utc=$d;response_rows=0;prior_active_market_rows=0;missing_prior_active_market_rows=0} }
        $s = $priorDayByResponseDay[$d]; $s.response_rows++
        if ($present) { $s.prior_active_market_rows++ } else { $s.missing_prior_active_market_rows++ }
    }
    $priorAvailabilityPath = Join-Path $runDir 'stage5-prior-day-market-availability.csv'
    @($priorDayByResponseDay.Values | Sort-Object response_day_utc) | Export-Csv -LiteralPath $priorAvailabilityPath -NoTypeInformation -Encoding UTF8

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
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
    $columnsPath = Join-Path $runDir 'stage5-market-columns.csv'
    Write-Utf8NoBom $columnsPath ($columnsCsv + [Environment]::NewLine)
    $columns = @(Convert-CsvText $columnsCsv)
    if ($columns.Count -ne 19) { throw "Market schema column count changed: $($columns.Count)." }
    $byName = @{}; foreach ($c in $columns) { $byName[[string]$c.column_name] = $c }
    foreach ($name in @('source_member_ordinal','pair_token_opaque','candle_start_utc','open_price','high_price','low_price','close_price','base_volume','trade_count','canonical_eligible','in_source_window','minute_aligned','quality_flags','duplicate_class')) { if (-not $byName.ContainsKey($name)) { throw "Required factor-source market column missing: $name" } }
    foreach ($name in @('open_price','high_price','low_price','close_price','base_volume')) { if ([string]$byName[$name].data_type -notin @('numeric','double precision','real','smallint','integer','bigint')) { throw "$name has unsupported factor numeric type: $($byName[$name].data_type)" } }
    if ([string]$byName['trade_count'].data_type -notin @('smallint','integer','bigint','numeric','double precision','real')) { throw "trade_count has unsupported numeric type: $($byName['trade_count'].data_type)" }
    if ([string]$byName['candle_start_utc'].data_type -ne 'timestamp with time zone') { throw 'candle_start_utc is not timestamptz.' }

    $ordinalList = (@($af.usd | ForEach-Object { [long]([string]$_.source_member_ordinal).Trim() } | Sort-Object) -join ',')
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
    foreach ($name in @('outside_source_window_rows','non_minute_aligned_rows','canonical_ineligible_rows','quality_flagged_rows','duplicate_class_rows')) { if ([long]$marketSummary.$name -ne 0) { throw "Frozen market integrity failure: $name=$($marketSummary.$name)" } }

    $factorIntegrity = @(Convert-CsvText (Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT count(DISTINCT source_member_ordinal)::bigint AS observed_usd_pairs,
count(*) FILTER (WHERE open_price IS NULL OR high_price IS NULL OR low_price IS NULL OR close_price IS NULL OR base_volume IS NULL OR trade_count IS NULL)::bigint AS null_factor_field_rows,
count(*) FILTER (WHERE open_price<=0 OR high_price<=0 OR low_price<=0 OR close_price<=0)::bigint AS nonpositive_price_rows,
count(*) FILTER (WHERE base_volume<0)::bigint AS negative_base_volume_rows,
count(*) FILTER (WHERE trade_count<0)::bigint AS negative_trade_count_rows,
min(candle_start_utc) AS min_candle_start_utc,max(candle_start_utc) AS max_candle_start_utc
FROM asrp.q2_market_1m_observations
WHERE source_member_ordinal IN ($ordinalList)
"@))[0]
    if ([long]$factorIntegrity.observed_usd_pairs -ne $ExpectedDirectUsdPairs) { throw 'Direct-USD market pair coverage changed.' }
    foreach ($name in @('null_factor_field_rows','nonpositive_price_rows','negative_base_volume_rows','negative_trade_count_rows')) { if ([long]$factorIntegrity.$name -ne 0) { throw "Market factor-source integrity failure: $name=$($factorIntegrity.$name)" } }

    $summary = [ordered]@{
        status='VALIDATION_CANDIDATE'
        stage='CFA_STAGE_5'
        stage4_entry='PASS'
        sources=[ordered]@{
            af001_sha256=$ExpectedAf001Sha256
            stage3_alias_registry_sha256=$ExpectedStage3AliasSha256
            stage3_v6_matches_path=$Stage3V6MatchesPath
            stage3_v6_matches_sha256=$matchesSha
            stage3_v6_summary_path=$summaryPath
            stage4_responses_path=$Stage4ResponsesPath
            stage4_responses_sha256=$ExpectedStage4ResponsesSha256
            stage3_archive_root=$Stage3ArchiveRoot
        }
        populations=[ordered]@{
            response_direct_usd_bases=$responseBases.Count
            stage3_news_population_assets=$newsPopulation.Count
            intersection_assets=$intersection.Count
            response_only_outside_news_population_assets=$responseOnly.Count
            response_only_assets=@($responseOnly)
            news_only_no_direct_usd_response_assets=$newsOnly.Count
            news_only_assets=@($newsOnly)
        }
        news=[ordered]@{
            match_rows=$matches.Count
            matched_assets=$matchedAssetSet.Count
            distinct_record_ids=$distinctRecordIds.Count
            min_match_timestamp_utc=$minNews.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)
            max_match_timestamp_utc=$maxNews.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)
            archive_files=$archiveFiles.Count
            min_archive_timestamp_utc=$archiveMin.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)
            max_archive_timestamp_utc=$archiveMax.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)
        }
        market=[ordered]@{
            schema_columns=$columns.Count
            open_price_type=[string]$byName['open_price'].data_type
            high_price_type=[string]$byName['high_price'].data_type
            low_price_type=[string]$byName['low_price'].data_type
            close_price_type=[string]$byName['close_price'].data_type
            base_volume_type=[string]$byName['base_volume'].data_type
            trade_count_type=[string]$byName['trade_count'].data_type
            observed_direct_usd_pairs=[long]$factorIntegrity.observed_usd_pairs
            min_direct_usd_candle_utc=[string]$factorIntegrity.min_candle_start_utc
            max_direct_usd_candle_utc=[string]$factorIntegrity.max_candle_start_utc
        }
        availability=[ordered]@{
            frozen_response_rows=$responses.Count
            response_rows_with_prior_calendar_day_active_market=$priorMarketAvailable
            response_rows_without_prior_calendar_day_active_market=$priorMarketMissing
        }
        outputs=[ordered]@{
            population_reconciliation_csv=$populationPath
            news_match_daily_counts_csv=$dailyNewsPath
            market_columns_csv=$columnsPath
            prior_day_market_availability_csv=$priorAvailabilityPath
        }
        gates=[ordered]@{
            'CFA-S5-001'='PASS'
            'CFA-S5-002'='PASS'
            'CFA-S5-003'='PASS'
            'CFA-S5-004'='PASS'
            'CFA-S5-005'='PASS'
            'CFA-S5-006'='BLOCKED'
            'CFA-S5-007'='BLOCKED'
            'CFA-S5-008'='BLOCKED'
            'CFA-S5-009'='BLOCKED'
        }
        next_action='Use observed population differences, timestamp/source boundaries, and prior-day availability to define exact initial factor formulas. Do not treat assets outside the Stage 3 news population as zero-news observations.'
    }
    $receiptPath = Join-Path $runDir 'stage5-factor-source-inspection.json'
    Write-Utf8NoBom $receiptPath (($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR SOURCE INSPECTION: VALIDATION CANDIDATE'
    Write-Host "Response/direct-USD bases: $($responseBases.Count)"
    Write-Host "Stage 3 news-population assets: $($newsPopulation.Count)"
    Write-Host "Intersection assets: $($intersection.Count)"
    Write-Host "Response-only outside news population: $($responseOnly.Count) [$(@($responseOnly)-join ', ')]"
    Write-Host "News-only without direct-USD response: $($newsOnly.Count) [$(@($newsOnly)-join ', ')]"
    Write-Host "V6 match rows: $($matches.Count)"
    Write-Host "V6 matched assets: $($matchedAssetSet.Count)"
    Write-Host "V6 distinct records: $($distinctRecordIds.Count)"
    Write-Host "News match UTC range: $($minNews.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)) -> $($maxNews.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant))"
    Write-Host "Archive UTC range: $($archiveMin.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)) -> $($archiveMax.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant))"
    Write-Host "Market factor fields: open=$($byName['open_price'].data_type), high=$($byName['high_price'].data_type), low=$($byName['low_price'].data_type), close=$($byName['close_price'].data_type), base_volume=$($byName['base_volume'].data_type), trade_count=$($byName['trade_count'].data_type)"
    Write-Host "Response rows with prior active market day: $priorMarketAvailable"
    Write-Host "Response rows without prior active market day: $priorMarketMissing"
    Write-Host 'CFA-S5-002 population reconciliation: PASS'
    Write-Host 'CFA-S5-003 news source/schema/timestamp verification: PASS'
    Write-Host 'CFA-S5-004 market factor-source verification: PASS'
    Write-Host 'CFA-S5-005 prior-window availability measurement: PASS'
    Write-Host 'CFA-S5-006 market factor definitions: BLOCKED'
    Write-Host 'CFA-S5-007 news factor definitions: BLOCKED'
    Write-Host "Inspection receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR SOURCE INSPECTION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD=$oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS=$oldPgOptions }
}
