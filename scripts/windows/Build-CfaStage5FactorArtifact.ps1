#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V6MatchesPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [Parameter(Mandatory=$true)][string]$BatchTimingReceiptPath,
    [string]$PgHost='localhost',
    [ValidateRange(1,65535)][int]$PgPort=5432,
    [string]$PgUser='postgres',
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [ValidateRange(30,900)][int]$StatementTimeoutSeconds=300,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$FactorContract='INITIAL_7_FACTOR_V1'
$ExpectedAf001Sha='569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAliasSha='11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'
$ExpectedStage4Sha='8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedResponseId='RET_USD_UTC_DAY_OBS_LOG'
$ExpectedStage4Rows=37058
$ExpectedStage4Bases=434
$ExpectedStage3Rows=22060
$ExpectedStage3MatchedAssets=282
$ExpectedStage3DistinctRecords=18503
$ExpectedNewsPopulationAssets=431
$ExpectedSlots=8736
$ExpectedDownloaded=7163
$ExpectedProviderMissing=1573
$ExpectedMarketAvailable=36505
$ExpectedMarketMissing=553
$ExpectedNews24Available=27267
$ExpectedNews24Incomplete=9518
$ExpectedNews24Outside=273
$ExpectedNews6Available=28849
$ExpectedNews6Incomplete=7936
$ExpectedNews6Outside=273
$AvailabilityLagMinutes=15
$Q2Start=[datetime]::SpecifyKind([datetime]::ParseExact('2025-04-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)
$Q2End=[datetime]::SpecifyKind([datetime]::ParseExact('2025-07-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)

function Find-Psql {
    $cmd=Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if($null-ne$cmd){return $cmd.Source}
    $found=@(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue|Sort-Object FullName -Descending)
    if($found.Count-eq0){throw 'psql.exe could not be found.'}
    return $found[0].FullName
}

function Invoke-PsqlText {
    param([string]$PsqlExe,[string]$Database,[string]$Sql)
    $errFile=[IO.Path]::GetTempFileName()
    try {
        $stdout=@(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2>$errFile)
        $exitCode=$LASTEXITCODE
        $stderr=if(Test-Path -LiteralPath $errFile){((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)|ForEach-Object{[string]$_})-join[Environment]::NewLine}else{''}
        $text=($stdout|ForEach-Object{if($null-ne$_){[string]$_}})-join[Environment]::NewLine
        if($exitCode-ne0){throw "psql failed for database '$Database' (exit $exitCode).`n$stderr`n$text"}
        return $text
    }
    finally{Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue}
}

function Invoke-PsqlCsv {
    param([string]$PsqlExe,[string]$Database,[string]$Query)
    $q=$Query.Trim();while($q.EndsWith(';')){$q=$q.Substring(0,$q.Length-1).TrimEnd()}
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Get-Sha { param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Write-Utf8NoBom {
    param([string]$Path,[AllowNull()][string]$Content)
    if($null-eq$Content){$Content=''}
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Require-Columns {
    param([object]$Row,[string[]]$Names,[string]$Label)
    $props=@($Row.PSObject.Properties.Name)
    foreach($name in $Names){if($props-notcontains$name){throw "$Label required column missing: $name"}}
}

function Parse-BoolStrict {
    param([object]$Value,[string]$Label)
    $x=([string]$Value).Trim().ToLowerInvariant()
    if($x-in@('true','t')){return $true}
    if($x-in@('false','f')){return $false}
    throw "Malformed boolean for ${Label}: '$Value'"
}

function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $n=0.0
    if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"}
    if([double]::IsNaN($n)-or[double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"}
    return $n
}

function Parse-Gdelt14 {
    param([string]$Text,[string]$Label)
    if($Text-notmatch'^\d{14}$'){throw "Malformed 14-digit timestamp for ${Label}: '$Text'"}
    $dt=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($Text,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$dt)){throw "Unparseable timestamp for ${Label}: '$Text'"}
    return [datetime]::SpecifyKind($dt,[DateTimeKind]::Utc)
}

function Get-RecordBatchUtc {
    param([string]$RecordId)
    $m=[regex]::Match($RecordId,'^(?<batch>\d{14})-(?:T)?\d+$',[Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if(-not$m.Success){throw "Malformed GKGRECORDID: '$RecordId'"}
    return Parse-Gdelt14 $m.Groups['batch'].Value "record_id $RecordId"
}

function Parse-UtcSecond {
    param([object]$Value,[string]$Label)
    $text=([string]$Value).Trim();$dt=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($text,'yyyy-MM-ddTHH:mm:ssZ',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$dt)){throw "Malformed UTC timestamp for ${Label}: '$Value'"}
    return [datetime]::SpecifyKind($dt,[DateTimeKind]::Utc)
}

function Measure-ShiftedWindow {
    param([datetime]$CutoffUtc,[int]$Hours,[hashtable]$SlotByKey)
    $expected=[int](($Hours*60)/15)
    $batchEnd=$CutoffUtc.AddMinutes(-$AvailabilityLagMinutes)
    $batchStart=$batchEnd.AddHours(-$Hours)
    [int]$downloaded=0;[int]$providerMissing=0;[int]$outside=0;[int]$registryMissing=0;[int]$other=0
    for($i=0;$i-lt$expected;$i++){
        $t=$batchStart.AddMinutes(15*$i)
        if($t-lt$Q2Start-or$t-ge$Q2End){$outside++;continue}
        $key=$t.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$SlotByKey.ContainsKey($key)){$registryMissing++;continue}
        $status=[string]$SlotByKey[$key].status
        if($status-eq'downloaded'){$downloaded++}
        elseif($status-eq'provider_missing'){$providerMissing++}
        else{$other++}
    }
    $complete=($downloaded-eq$expected-and$providerMissing-eq0-and$outside-eq0-and$registryMissing-eq0-and$other-eq0)
    return [pscustomobject]@{hours=$Hours;batch_start=$batchStart;batch_end=$batchEnd;complete=$complete;downloaded=$downloaded;provider_missing=$providerMissing;outside=$outside;registry_missing=$registryMissing;other=$other}
}

function Add-ReviewReason {
    param([hashtable]$Selection,[object]$Row,[string]$Reason)
    $key=([string]$Row.base_asset_id)+'|'+([string]$Row.response_day_utc)
    if(-not$Selection.ContainsKey($key)){$Selection[$key]=[pscustomobject]@{row=$Row;reasons=(New-Object System.Collections.ArrayList)}}
    if(-not($Selection[$key].reasons-contains$Reason)){[void]$Selection[$key].reasons.Add($Reason)}
}

function Invoke-SelfTest {
    $batch=Get-RecordBatchUtc '20250401003000-T8'
    if($batch.ToString('yyyyMMddHHmmss',$Invariant)-ne'20250401003000'){throw 'Record batch parser self-test failed.'}
    $slots=@{};$start=$Q2Start
    for($i=0;$i-lt96;$i++){$t=$start.AddMinutes(15*$i);$slots[$t.ToString('yyyyMMddHHmmss',$Invariant)]=[pscustomobject]@{status='downloaded'}}
    $w=Measure-ShiftedWindow $start.AddDays(1).AddMinutes(15) 24 $slots
    if(-not[bool]$w.complete-or[int]$w.downloaded-ne96){throw 'Shifted window self-test failed.'}
    $ret=[math]::Log(110.0/100.0);$range=[math]::Log(120.0/90.0)
    if([math]::Abs($ret-0.09531017980432493)-gt1e-12-or$range-le0){throw 'Market formula self-test failed.'}
    $newsRows=@([pscustomobject]@{record_id='20250401003000-1'})
    'abc' -match 'a'|Out-Null
    if($newsRows.Count-ne1){throw 'Automatic $Matches regression failed.'}
    $groupProbe=@('A','A','B'|Group-Object)
    if(@($groupProbe|Where-Object { $_.Count -gt 1 }).Count-ne1){throw 'Explicit grouped-count filter self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

$oldPassword=$env:PGPASSWORD
$oldPgOptions=$env:PGOPTIONS
$bstr=[IntPtr]::Zero
try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $Stage3V6MatchesPath=(Resolve-Path -LiteralPath $Stage3V6MatchesPath).ProviderPath
    $Stage4ResponsesPath=(Resolve-Path -LiteralPath $Stage4ResponsesPath).ProviderPath
    $BatchTimingReceiptPath=(Resolve-Path -LiteralPath $BatchTimingReceiptPath).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage5-factor-artifact'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null

    $contract=Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage5-factor-contract.md') -Raw
    foreach($marker in @('CFA-S5-006','CFA-S5-007','CFA-S5-011','CFA-S5-013','PASS','CFA-S5-008','UNVERIFIED',$FactorContract)){
        if($marker-eq$FactorContract){continue}
        if($contract-notmatch[regex]::Escape($marker)){throw "Stage 5 contract marker missing: $marker"}
    }
    foreach($factorId in @('MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1','NEWS_V6_MATCH_COUNT_24H_LAG15','NEWS_V6_MATCH_COUNT_6H_LAG15','NEWS_V6_SOURCE_COUNT_24H_LAG15')){
        if($contract-notmatch[regex]::Escape($factorId)){throw "Approved factor missing from Stage 5 contract: $factorId"}
    }

    $afPath=Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    if((Get-Sha $afPath)-ne$ExpectedAf001Sha){throw 'AF-001 SHA-256 mismatch.'}
    $af=@(Import-Csv -LiteralPath $afPath)
    Require-Columns $af[0] @('source_member_ordinal','pair_token_opaque','base_asset_id','quote_exchange_symbol','research_eligible') 'AF-001'
    $eligible=@($af|Where-Object{Parse-BoolStrict $_.research_eligible "AF-001 $($_.pair_token_opaque)"})
    $usd=@($eligible|Where-Object{([string]$_.quote_exchange_symbol).Trim()-ceq'USD'})
    $usdBases=@($usd|Select-Object -ExpandProperty base_asset_id -Unique)
    if($usd.Count-ne434-or$usdBases.Count-ne434){throw "Direct-USD AF population changed: pairs=$($usd.Count) bases=$($usdBases.Count)."}
    if(@($usd|Group-Object base_asset_id|Where-Object { $_.Count -gt 1 }).Count-ne0){throw 'Direct-USD AF base ambiguity detected.'}
    $afByBase=@{};$afByOrdinal=@{}
    foreach($r in $usd){$afByBase[[string]$r.base_asset_id]=$r;$afByOrdinal[([string]$r.source_member_ordinal).Trim()]=$r}

    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if((Get-Sha $aliasPath)-ne$ExpectedAliasSha){throw 'Stage 3 alias registry SHA-256 mismatch.'}
    $aliases=@(Import-Csv -LiteralPath $aliasPath)
    $newsPopulation=@($aliases|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($newsPopulation.Count-ne$ExpectedNewsPopulationAssets){throw "News population changed: $($newsPopulation.Count)."}

    if((Get-Sha $Stage4ResponsesPath)-ne$ExpectedStage4Sha){throw 'Stage 4 response CSV SHA-256 mismatch.'}
    $responses=@(Import-Csv -LiteralPath $Stage4ResponsesPath)
    if($responses.Count-ne$ExpectedStage4Rows){throw "Stage 4 response rows changed: $($responses.Count)."}
    Require-Columns $responses[0] @('response_id','base_asset_id','pair_token_opaque','source_member_ordinal','response_day_utc','predictor_cutoff_utc') 'Stage 4 responses'
    $responseIds=@($responses|Select-Object -ExpandProperty response_id -Unique)
    if($responseIds.Count-ne1-or[string]$responseIds[0]-ne$ExpectedResponseId){throw 'Stage 4 response identity changed.'}
    $responseBases=@($responses|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($responseBases.Count-ne$ExpectedStage4Bases){throw "Stage 4 response base count changed: $($responseBases.Count)."}
    $responseKeySet=New-Object 'Collections.Generic.HashSet[string]'
    foreach($r in $responses){
        $key=([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc)
        if(-not$responseKeySet.Add($key)){throw "Duplicate Stage 4 response key: $key"}
        if(-not$afByBase.ContainsKey([string]$r.base_asset_id)){throw "Response base outside direct-USD AF population: $($r.base_asset_id)"}
        $a=$afByBase[[string]$r.base_asset_id]
        if(([string]$r.source_member_ordinal).Trim()-ne([string]$a.source_member_ordinal).Trim()-or[string]$r.pair_token_opaque-ne[string]$a.pair_token_opaque){throw "Response/AF lineage mismatch: $key"}
    }

    $stage3SummaryPath=Join-Path (Split-Path -Parent $Stage3V6MatchesPath) 'stage3-match-summary.json'
    if(-not(Test-Path -LiteralPath $stage3SummaryPath -PathType Leaf)){throw 'Stage 3 V6 sibling summary missing.'}
    $stage3Summary=Get-Content -LiteralPath $stage3SummaryPath -Raw|ConvertFrom-Json
    if([string]$stage3Summary.run_status-ne'PASS'-or[string]$stage3Summary.matching_contract-ne'CANDIDATE_V6'){throw 'Stage 3 summary is not PASS CANDIDATE_V6.'}
    $stage3Sha=Get-Sha $Stage3V6MatchesPath
    if($stage3Sha-ne([string]$stage3Summary.output.matches_sha256).ToLowerInvariant()){throw 'Stage 3 V6 match SHA-256 mismatch.'}
    $newsRows=@(Import-Csv -LiteralPath $Stage3V6MatchesPath)
    if($newsRows.Count-ne$ExpectedStage3Rows){throw "Stage 3 V6 rows changed: $($newsRows.Count)."}
    Require-Columns $newsRows[0] @('base_asset_id','record_id','gdelt_date_utc','source_common_name','archive_file') 'Stage 3 V6 matches'

    $batchReceipt=Get-Content -LiteralPath $BatchTimingReceiptPath -Raw|ConvertFrom-Json
    if([string]$batchReceipt.status-ne'PASS'-or[string]$batchReceipt.policy-ne'GDELT_RECORD_BATCH_PLUS_ONE_HEARTBEAT'-or[int]$batchReceipt.availability_lag_minutes-ne15){throw 'Batch timing receipt is not the validated lag-15 policy.'}
    if([string]$batchReceipt.gates.'CFA-S5-013'-ne'PASS'-or[string]$batchReceipt.gates.'CFA-S5-011'-ne'PASS'){throw 'Batch timing receipt gates are not PASS.'}
    if([string]$batchReceipt.sources.stage3_matches_sha256-ne$stage3Sha-or[string]$batchReceipt.sources.stage4_responses_sha256-ne$ExpectedStage4Sha){throw 'Batch timing receipt source hashes do not match current inputs.'}
    if([int]$batchReceipt.shifted_24h.complete_response_days-ne68-or[long]$batchReceipt.shifted_24h.available_in_population_response_rows-ne$ExpectedNews24Available-or[long]$batchReceipt.shifted_24h.source_incomplete_in_population_response_rows-ne$ExpectedNews24Incomplete-or[long]$batchReceipt.shifted_24h.outside_news_population_response_rows-ne$ExpectedNews24Outside){throw 'Batch timing receipt 24h partition changed.'}
    if([int]$batchReceipt.shifted_6h.complete_response_days-ne72-or[long]$batchReceipt.shifted_6h.available_in_population_response_rows-ne$ExpectedNews6Available-or[long]$batchReceipt.shifted_6h.source_incomplete_in_population_response_rows-ne$ExpectedNews6Incomplete-or[long]$batchReceipt.shifted_6h.outside_news_population_response_rows-ne$ExpectedNews6Outside){throw 'Batch timing receipt 6h partition changed.'}
    $sourceSlotsPath=(Resolve-Path -LiteralPath ([string]$batchReceipt.sources.source_slots_csv)).ProviderPath
    $sourceSlotsSha=Get-Sha $sourceSlotsPath
    $sourceSlots=@(Import-Csv -LiteralPath $sourceSlotsPath)
    if($sourceSlots.Count-ne$ExpectedSlots){throw "Source slot row count changed: $($sourceSlots.Count)."}
    Require-Columns $sourceSlots[0] @('object_key','slot_key','status','http_status','payload_sha256') 'Source slots'
    $slotByKey=@{};[int]$downloaded=0;[int]$providerMissing=0;[int]$other=0
    foreach($s in $sourceSlots){
        $key=([string]$s.slot_key).Trim();if($key-notmatch'^\d{14}$'){throw "Malformed source slot key: $key"};if($slotByKey.ContainsKey($key)){throw "Duplicate source slot key: $key"};$slotByKey[$key]=$s
        if([string]$s.status-eq'downloaded'){$downloaded++}elseif([string]$s.status-eq'provider_missing'){$providerMissing++}else{$other++}
    }
    if($downloaded-ne$ExpectedDownloaded-or$providerMissing-ne$ExpectedProviderMissing-or$other-ne0){throw 'Source slot status accounting changed.'}

    $newsByAsset=@{};$assetRecordKeys=New-Object 'Collections.Generic.HashSet[string]';$matchedAssets=New-Object 'Collections.Generic.HashSet[string]';$recordIds=New-Object 'Collections.Generic.HashSet[string]'
    foreach($n in $newsRows){
        $base=[string]$n.base_asset_id;$rid=[string]$n.record_id;$k=$base+'|'+$rid
        if(-not$assetRecordKeys.Add($k)){throw "Duplicate V6 asset/record key: $k"};[void]$matchedAssets.Add($base);[void]$recordIds.Add($rid)
        if($newsPopulation-notcontains$base){throw "V6 match asset outside news population: $base"}
        if([string]::IsNullOrWhiteSpace([string]$n.source_common_name)){throw "Blank source_common_name in V6 row: $rid"}
        $batch=Get-RecordBatchUtc $rid
        $archiveText=([string]$n.archive_file).Substring(0,14);$archiveBatch=Parse-Gdelt14 $archiveText "archive $($n.archive_file)"
        if($batch-ne$archiveBatch){throw "V6 record/archive batch mismatch: $rid"}
        $batchKey=$batch.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$slotByKey.ContainsKey($batchKey)-or[string]$slotByKey[$batchKey].status-ne'downloaded'){throw "V6 batch not on downloaded slot: $rid"}
        if(-not$newsByAsset.ContainsKey($base)){$newsByAsset[$base]=New-Object System.Collections.ArrayList}
        [void]$newsByAsset[$base].Add([pscustomobject]@{available=$batch.AddMinutes(15);source=[string]$n.source_common_name;record_id=$rid})
    }
    if($matchedAssets.Count-ne$ExpectedStage3MatchedAssets-or$recordIds.Count-ne$ExpectedStage3DistinctRecords){throw 'Stage 3 distinct counts changed.'}

    $windowByDay=@{}
    foreach($dayText in @($responses|Select-Object -ExpandProperty response_day_utc -Unique|Sort-Object)){
        $cutoff=[datetime]::SpecifyKind([datetime]::ParseExact([string]$dayText,'yyyy-MM-dd',$Invariant),[DateTimeKind]::Utc)
        $windowByDay[[string]$dayText]=[pscustomobject]@{w24=(Measure-ShiftedWindow $cutoff 24 $slotByKey);w6=(Measure-ShiftedWindow $cutoff 6 $slotByKey)}
    }

    $ordinalList=(@($afByOrdinal.Keys|ForEach-Object{[long]$_}|Sort-Object)-join',')
    $psql=Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    $securePassword=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000) -c TimeZone=UTC"
    $version=Invoke-PsqlText -PsqlExe $psql -Database 'asrp' -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $integrity=@(Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT count(DISTINCT source_member_ordinal)::bigint AS observed_usd_pairs,
       count(*) FILTER (WHERE open_price IS NULL OR high_price IS NULL OR low_price IS NULL OR close_price IS NULL)::bigint AS null_ohlc_rows,
       count(*) FILTER (WHERE open_price<=0 OR high_price<=0 OR low_price<=0 OR close_price<=0)::bigint AS nonpositive_ohlc_rows,
       count(*) FILTER (WHERE NOT canonical_eligible)::bigint AS canonical_ineligible_rows,
       count(*) FILTER (WHERE NOT in_source_window)::bigint AS outside_source_window_rows,
       count(*) FILTER (WHERE NOT minute_aligned)::bigint AS nonminute_rows,
       count(*) FILTER (WHERE cardinality(quality_flags)>0)::bigint AS quality_flagged_rows,
       count(*) FILTER (WHERE duplicate_class IS NOT NULL)::bigint AS duplicate_class_rows
FROM asrp.q2_market_1m_observations
WHERE source_member_ordinal IN ($ordinalList)
"@|ConvertFrom-Csv)[0]
    if([long]$integrity.observed_usd_pairs-ne434){throw 'Direct-USD market pair coverage changed.'}
    foreach($name in @('null_ohlc_rows','nonpositive_ohlc_rows','canonical_ineligible_rows','outside_source_window_rows','nonminute_rows','quality_flagged_rows','duplicate_class_rows')){if([long]$integrity.$name-ne0){throw "Direct-USD market integrity failure: $name=$($integrity.$name)"}}

    $dailyCsv=Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
WITH eligible AS (
    SELECT source_member_ordinal,candle_start_utc,physical_record_number,raw_record_sha256,open_price,high_price,low_price,close_price,
           (candle_start_utc AT TIME ZONE 'UTC')::date AS utc_day
    FROM asrp.q2_market_1m_observations
    WHERE source_member_ordinal IN ($ordinalList)
      AND canonical_eligible AND in_source_window AND minute_aligned
      AND cardinality(quality_flags)=0 AND duplicate_class IS NULL
),
daily AS (
    SELECT source_member_ordinal,utc_day,count(*)::bigint AS obs_count,
           min(candle_start_utc) AS first_start,max(candle_start_utc) AS last_start
    FROM eligible GROUP BY source_member_ordinal,utc_day
),
firsts AS (
    SELECT DISTINCT ON (source_member_ordinal,utc_day)
           source_member_ordinal,utc_day,candle_start_utc AS first_ts,open_price AS first_open,
           physical_record_number AS first_phys,raw_record_sha256 AS first_sha
    FROM eligible ORDER BY source_member_ordinal,utc_day,candle_start_utc,physical_record_number
),
lasts AS (
    SELECT DISTINCT ON (source_member_ordinal,utc_day)
           source_member_ordinal,utc_day,candle_start_utc AS last_ts,close_price AS last_close,
           physical_record_number AS last_phys,raw_record_sha256 AS last_sha
    FROM eligible ORDER BY source_member_ordinal,utc_day,candle_start_utc DESC,physical_record_number DESC
),
highs AS (
    SELECT DISTINCT ON (source_member_ordinal,utc_day)
           source_member_ordinal,utc_day,candle_start_utc AS high_ts,high_price AS max_high,
           physical_record_number AS high_phys,raw_record_sha256 AS high_sha
    FROM eligible ORDER BY source_member_ordinal,utc_day,high_price DESC,candle_start_utc,physical_record_number
),
lows AS (
    SELECT DISTINCT ON (source_member_ordinal,utc_day)
           source_member_ordinal,utc_day,candle_start_utc AS low_ts,low_price AS min_low,
           physical_record_number AS low_phys,raw_record_sha256 AS low_sha
    FROM eligible ORDER BY source_member_ordinal,utc_day,low_price,candle_start_utc,physical_record_number
)
SELECT d.source_member_ordinal,d.utc_day,d.obs_count,
       f.first_ts,f.first_open,f.first_phys,f.first_sha,
       l.last_ts,l.last_close,l.last_phys,l.last_sha,
       h.high_ts,h.max_high,h.high_phys,h.high_sha,
       w.low_ts,w.min_low,w.low_phys,w.low_sha
FROM daily d
JOIN firsts f USING(source_member_ordinal,utc_day)
JOIN lasts l USING(source_member_ordinal,utc_day)
JOIN highs h USING(source_member_ordinal,utc_day)
JOIN lows w USING(source_member_ordinal,utc_day)
ORDER BY d.source_member_ordinal,d.utc_day
"@
    $daily=@($dailyCsv|ConvertFrom-Csv)
    if($daily.Count-ne$ExpectedStage4Rows){throw "Direct-USD market day count changed: $($daily.Count)."}
    $dailyMap=@{}
    foreach($d in $daily){
        $key=([string]$d.source_member_ordinal).Trim()+'|'+([string]$d.utc_day)
        if($dailyMap.ContainsKey($key)){throw "Duplicate direct-USD daily aggregate: $key"}
        $dailyMap[$key]=$d
    }

    $factorRows=New-Object System.Collections.ArrayList
    $daySummary=@{}
    [long]$marketAvailable=0;[long]$marketMissing=0
    [long]$news24Available=0;[long]$news24Incomplete=0;[long]$news24Outside=0
    [long]$news6Available=0;[long]$news6Incomplete=0;[long]$news6Outside=0

    foreach($r in @($responses|Sort-Object response_day_utc,base_asset_id)){
        $base=[string]$r.base_asset_id;$dayText=[string]$r.response_day_utc;$cutoff=Parse-UtcSecond $r.predictor_cutoff_utc "response cutoff $base $dayText"
        $expectedCutoff=[datetime]::SpecifyKind([datetime]::ParseExact($dayText,'yyyy-MM-dd',$Invariant),[DateTimeKind]::Utc)
        if($cutoff-ne$expectedCutoff){throw "Response cutoff/day mismatch: $base $dayText"}
        $ordinal=([string]$r.source_member_ordinal).Trim();$priorDay=$cutoff.AddDays(-1).ToString('yyyy-MM-dd',$Invariant);$mkey=$ordinal+'|'+$priorDay
        $marketReason='NONE';$mRet=$null;$mRange=$null;$mCount=$null;$mSpan=$null
        $mFirstTs=$null;$mLastTs=$null;$mFirstOpen=$null;$mLastClose=$null;$mMaxHigh=$null;$mMinLow=$null
        $mFirstPhys=$null;$mLastPhys=$null;$mHighPhys=$null;$mLowPhys=$null;$mFirstSha=$null;$mLastSha=$null;$mHighSha=$null;$mLowSha=$null;$mHighTs=$null;$mLowTs=$null
        if(-not$dailyMap.ContainsKey($mkey)){$marketReason='NO_PRIOR_ACTIVE_MARKET_DAY';$marketMissing++}
        else{
            $m=$dailyMap[$mkey];$marketAvailable++
            $firstOpen=Parse-DoubleStrict $m.first_open "first open $mkey";$lastClose=Parse-DoubleStrict $m.last_close "last close $mkey";$maxHigh=Parse-DoubleStrict $m.max_high "max high $mkey";$minLow=Parse-DoubleStrict $m.min_low "min low $mkey"
            if($firstOpen-le0-or$lastClose-le0-or$maxHigh-le0-or$minLow-le0){throw "Nonpositive market aggregate price: $mkey"}
            $mRet=[math]::Log($lastClose/$firstOpen);$mRange=[math]::Log($maxHigh/$minLow);$mCount=[long]$m.obs_count
            $firstTs=[datetime]::Parse([string]$m.first_ts,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime();$lastTs=[datetime]::Parse([string]$m.last_ts,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
            $mSpan=[long][math]::Round(($lastTs-$firstTs).TotalMinutes)
            if($mCount-lt1-or$mSpan-lt0-or[double]::IsNaN($mRet)-or[double]::IsInfinity($mRet)-or[double]::IsNaN($mRange)-or[double]::IsInfinity($mRange)){throw "Invalid market factor values: $mkey"}
            $mFirstTs=$firstTs.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);$mLastTs=$lastTs.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);$mHighTs=([datetime]::Parse([string]$m.high_ts,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()).ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);$mLowTs=([datetime]::Parse([string]$m.low_ts,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()).ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)
            $mFirstOpen=[string]$m.first_open;$mLastClose=[string]$m.last_close;$mMaxHigh=[string]$m.max_high;$mMinLow=[string]$m.min_low;$mFirstPhys=[string]$m.first_phys;$mLastPhys=[string]$m.last_phys;$mHighPhys=[string]$m.high_phys;$mLowPhys=[string]$m.low_phys;$mFirstSha=[string]$m.first_sha;$mLastSha=[string]$m.last_sha;$mHighSha=[string]$m.high_sha;$mLowSha=[string]$m.low_sha
        }

        $windows=$windowByDay[$dayText];$w24=$windows.w24;$w6=$windows.w6
        $inNewsPopulation=($newsPopulation-contains$base)
        $reason24='NONE';$reason6='NONE';$n24=$null;$n6=$null;$s24=$null
        if(-not$inNewsPopulation){$reason24='OUTSIDE_NEWS_POPULATION';$reason6='OUTSIDE_NEWS_POPULATION';$news24Outside++;$news6Outside++}
        else{
            if(-not[bool]$w24.complete){$reason24='SOURCE_WINDOW_INCOMPLETE';$news24Incomplete++}else{$news24Available++}
            if(-not[bool]$w6.complete){$reason6='SOURCE_WINDOW_INCOMPLETE';$news6Incomplete++}else{$news6Available++}
            if($reason24-eq'NONE'-or$reason6-eq'NONE'){
                [long]$c24=0;[long]$c6=0;$sources24=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                if($newsByAsset.ContainsKey($base)){
                    $start24=$cutoff.AddHours(-24);$start6=$cutoff.AddHours(-6)
                    foreach($n in @($newsByAsset[$base].ToArray())){
                        $a=[datetime]$n.available
                        if($a-ge$start24-and$a-lt$cutoff){$c24++;[void]$sources24.Add([string]$n.source)}
                        if($a-ge$start6-and$a-lt$cutoff){$c6++}
                    }
                }
                if($reason24-eq'NONE'){$n24=$c24;$s24=[long]$sources24.Count}
                if($reason6-eq'NONE'){$n6=$c6}
            }
        }

        $row=[pscustomobject][ordered]@{
            base_asset_id=$base;response_day_utc=$dayText;predictor_cutoff_utc=[string]$r.predictor_cutoff_utc;pair_token_opaque=[string]$r.pair_token_opaque;source_member_ordinal=$ordinal;
            market_missing_reason=$marketReason;market_window_start_utc=$cutoff.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);market_window_end_exclusive_utc=$cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);
            MKT_RET_USD_UTC_DAY_OBS_L1=if($null-eq$mRet){$null}else{$mRet.ToString('R',$Invariant)};
            MKT_RANGE_LOG_UTC_DAY_L1=if($null-eq$mRange){$null}else{$mRange.ToString('R',$Invariant)};
            MKT_OBS_COUNT_UTC_DAY_L1=if($null-eq$mCount){$null}else{[string]$mCount};
            MKT_OBS_SPAN_MIN_UTC_DAY_L1=if($null-eq$mSpan){$null}else{[string]$mSpan};
            market_first_candle_start_utc=$mFirstTs;market_last_candle_start_utc=$mLastTs;market_high_witness_candle_start_utc=$mHighTs;market_low_witness_candle_start_utc=$mLowTs;
            market_first_open_price_usd=$mFirstOpen;market_last_close_price_usd=$mLastClose;market_max_high_price_usd=$mMaxHigh;market_min_low_price_usd=$mMinLow;
            market_first_physical_record_number=$mFirstPhys;market_last_physical_record_number=$mLastPhys;market_high_witness_physical_record_number=$mHighPhys;market_low_witness_physical_record_number=$mLowPhys;
            market_first_raw_record_sha256=$mFirstSha;market_last_raw_record_sha256=$mLastSha;market_high_witness_raw_record_sha256=$mHighSha;market_low_witness_raw_record_sha256=$mLowSha;
            news_population_status=if($inNewsPopulation){'IN_POPULATION'}else{'OUTSIDE_NEWS_POPULATION'};news_availability_lag_minutes='15';
            news_24h_missing_reason=$reason24;news_24h_availability_window_start_utc=$cutoff.AddHours(-24).ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_24h_availability_window_end_exclusive_utc=$cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_24h_batch_window_start_utc=$w24.batch_start.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_24h_batch_window_end_exclusive_utc=$w24.batch_end.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_24h_window_complete=[string][bool]$w24.complete;
            NEWS_V6_MATCH_COUNT_24H_LAG15=if($null-eq$n24){$null}else{[string]$n24};NEWS_V6_SOURCE_COUNT_24H_LAG15=if($null-eq$s24){$null}else{[string]$s24};
            news_6h_missing_reason=$reason6;news_6h_availability_window_start_utc=$cutoff.AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_6h_availability_window_end_exclusive_utc=$cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_6h_batch_window_start_utc=$w6.batch_start.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_6h_batch_window_end_exclusive_utc=$w6.batch_end.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);news_6h_window_complete=[string][bool]$w6.complete;
            NEWS_V6_MATCH_COUNT_6H_LAG15=if($null-eq$n6){$null}else{[string]$n6}
        }
        [void]$factorRows.Add($row)

        if(-not$daySummary.ContainsKey($dayText)){$daySummary[$dayText]=[pscustomobject]@{response_day_utc=$dayText;response_rows=0;market_available_rows=0;market_missing_rows=0;news24_available_rows=0;news24_incomplete_rows=0;news24_outside_rows=0;news6_available_rows=0;news6_incomplete_rows=0;news6_outside_rows=0}}
        $ds=$daySummary[$dayText];$ds.response_rows++
        if($marketReason-eq'NONE'){$ds.market_available_rows++}else{$ds.market_missing_rows++}
        if($reason24-eq'NONE'){$ds.news24_available_rows++}elseif($reason24-eq'SOURCE_WINDOW_INCOMPLETE'){$ds.news24_incomplete_rows++}else{$ds.news24_outside_rows++}
        if($reason6-eq'NONE'){$ds.news6_available_rows++}elseif($reason6-eq'SOURCE_WINDOW_INCOMPLETE'){$ds.news6_incomplete_rows++}else{$ds.news6_outside_rows++}
    }

    if($factorRows.Count-ne$ExpectedStage4Rows){throw "Factor row count mismatch: $($factorRows.Count)."}
    if($marketAvailable-ne$ExpectedMarketAvailable-or$marketMissing-ne$ExpectedMarketMissing){throw "Market availability mismatch: $marketAvailable / $marketMissing"}
    if($news24Available-ne$ExpectedNews24Available-or$news24Incomplete-ne$ExpectedNews24Incomplete-or$news24Outside-ne$ExpectedNews24Outside){throw "News 24h partition mismatch: $news24Available / $news24Incomplete / $news24Outside"}
    if($news6Available-ne$ExpectedNews6Available-or$news6Incomplete-ne$ExpectedNews6Incomplete-or$news6Outside-ne$ExpectedNews6Outside){throw "News 6h partition mismatch: $news6Available / $news6Incomplete / $news6Outside"}

    foreach($row in $factorRows){
        if($row.market_missing_reason-eq'NONE'){
            $ret=Parse-DoubleStrict $row.MKT_RET_USD_UTC_DAY_OBS_L1 'market return';$range=Parse-DoubleStrict $row.MKT_RANGE_LOG_UTC_DAY_L1 'market range';$first=Parse-DoubleStrict $row.market_first_open_price_usd 'first';$last=Parse-DoubleStrict $row.market_last_close_price_usd 'last';$hi=Parse-DoubleStrict $row.market_max_high_price_usd 'high';$lo=Parse-DoubleStrict $row.market_min_low_price_usd 'low'
            if([math]::Abs($ret-[math]::Log($last/$first))-gt1e-12-or[math]::Abs($range-[math]::Log($hi/$lo))-gt1e-12){throw "Market formula reconciliation failed: $($row.base_asset_id) $($row.response_day_utc)"}
            if([long]$row.MKT_OBS_COUNT_UTC_DAY_L1-lt1-or[long]$row.MKT_OBS_SPAN_MIN_UTC_DAY_L1-lt0){throw 'Market count/span invalid.'}
        }else{
            foreach($name in @('MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1')){if(-not[string]::IsNullOrWhiteSpace([string]$row.$name)){throw "Market missing row has value: $name"}}
        }
        if($row.news_24h_missing_reason-eq'NONE'){
            if([long]$row.NEWS_V6_MATCH_COUNT_24H_LAG15-lt0-or[long]$row.NEWS_V6_SOURCE_COUNT_24H_LAG15-lt0-or[long]$row.NEWS_V6_SOURCE_COUNT_24H_LAG15-gt[long]$row.NEWS_V6_MATCH_COUNT_24H_LAG15){throw '24h news factor invalid.'}
        }elseif(-not[string]::IsNullOrWhiteSpace([string]$row.NEWS_V6_MATCH_COUNT_24H_LAG15)-or-not[string]::IsNullOrWhiteSpace([string]$row.NEWS_V6_SOURCE_COUNT_24H_LAG15)){throw '24h missing row has value.'}
        if($row.news_6h_missing_reason-eq'NONE'){if([long]$row.NEWS_V6_MATCH_COUNT_6H_LAG15-lt0){throw '6h news factor invalid.'}}elseif(-not[string]::IsNullOrWhiteSpace([string]$row.NEWS_V6_MATCH_COUNT_6H_LAG15)){throw '6h missing row has value.'}
        if($row.news_24h_missing_reason-eq'NONE'-and$row.news_6h_missing_reason-eq'NONE'-and[long]$row.NEWS_V6_MATCH_COUNT_6H_LAG15-gt[long]$row.NEWS_V6_MATCH_COUNT_24H_LAG15){throw '6h match count exceeds complete 24h match count.'}
    }

    $factorPath=Join-Path $runDir 'stage5-candidate-factors.csv'
    @($factorRows.ToArray())|Export-Csv -LiteralPath $factorPath -NoTypeInformation -Encoding UTF8
    $dayPath=Join-Path $runDir 'stage5-candidate-factor-day-summary.csv'
    @($daySummary.Values|Sort-Object response_day_utc)|Export-Csv -LiteralPath $dayPath -NoTypeInformation -Encoding UTF8

    $selection=@{}
    $sorted=@($factorRows.ToArray()|Sort-Object response_day_utc,base_asset_id)
    foreach($x in @($sorted|Select-Object -First 5)){Add-ReviewReason $selection $x 'EARLIEST'}
    foreach($x in @($sorted|Select-Object -Last 5)){Add-ReviewReason $selection $x 'LATEST'}
    foreach($x in @($sorted|Where-Object{$_.market_missing_reason-ne'NONE'}|Select-Object -First 10)){Add-ReviewReason $selection $x 'MARKET_MISSING'}
    foreach($x in @($sorted|Where-Object{$_.news_24h_missing_reason-eq'SOURCE_WINDOW_INCOMPLETE'}|Select-Object -First 10)){Add-ReviewReason $selection $x 'NEWS24_INCOMPLETE'}
    foreach($x in @($sorted|Where-Object{$_.news_6h_missing_reason-eq'SOURCE_WINDOW_INCOMPLETE'}|Select-Object -First 10)){Add-ReviewReason $selection $x 'NEWS6_INCOMPLETE'}
    foreach($x in @($sorted|Where-Object{$_.news_population_status-eq'OUTSIDE_NEWS_POPULATION'}|Select-Object -First 10)){Add-ReviewReason $selection $x 'OUTSIDE_NEWS_POPULATION'}
    foreach($x in @($factorRows.ToArray()|Where-Object{$_.market_missing_reason-eq'NONE'}|Sort-Object @{Expression={[math]::Abs([double]$_.MKT_RET_USD_UTC_DAY_OBS_L1)};Descending=$true}|Select-Object -First 10)){Add-ReviewReason $selection $x 'LARGEST_ABS_MARKET_RETURN'}
    foreach($x in @($factorRows.ToArray()|Where-Object{$_.news_24h_missing_reason-eq'NONE'}|Sort-Object @{Expression={[long]$_.NEWS_V6_MATCH_COUNT_24H_LAG15};Descending=$true}|Select-Object -First 10)){Add-ReviewReason $selection $x 'LARGEST_NEWS24_COUNT'}
    foreach($x in @($factorRows.ToArray()|Where-Object{$_.news_6h_missing_reason-eq'NONE'}|Sort-Object @{Expression={[long]$_.NEWS_V6_MATCH_COUNT_6H_LAG15};Descending=$true}|Select-Object -First 10)){Add-ReviewReason $selection $x 'LARGEST_NEWS6_COUNT'}
    $review=New-Object System.Collections.ArrayList
    foreach($k in @($selection.Keys|Sort-Object)){
        $state=$selection[$k];$o=[ordered]@{review_reason=(@($state.reasons.ToArray())-join'|')};foreach($p in $state.row.PSObject.Properties){$o[$p.Name]=$p.Value};[void]$review.Add([pscustomobject]$o)
    }
    $reviewPath=Join-Path $runDir 'stage5-candidate-factor-review-sample.csv'
    @($review.ToArray())|Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8

    $factorSha=Get-Sha $factorPath;$daySha=Get-Sha $dayPath;$reviewSha=Get-Sha $reviewPath;$batchReceiptSha=Get-Sha $BatchTimingReceiptPath
    $zero24=@($factorRows.ToArray()|Where-Object{$_.news_24h_missing_reason-eq'NONE'-and[long]$_.NEWS_V6_MATCH_COUNT_24H_LAG15-eq0}).Count
    $zero6=@($factorRows.ToArray()|Where-Object{$_.news_6h_missing_reason-eq'NONE'-and[long]$_.NEWS_V6_MATCH_COUNT_6H_LAG15-eq0}).Count
    $receipt=[ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_5';factor_contract=$FactorContract;grain='base_asset_id,response_day_utc';row_count=$factorRows.Count;distinct_bases=$responseBases.Count;min_response_day='2025-04-01';max_response_day='2025-06-30';
        sources=[ordered]@{af001_sha256=$ExpectedAf001Sha;stage4_responses_path=$Stage4ResponsesPath;stage4_responses_sha256=$ExpectedStage4Sha;stage3_matches_path=$Stage3V6MatchesPath;stage3_matches_sha256=$stage3Sha;batch_timing_receipt_path=$BatchTimingReceiptPath;batch_timing_receipt_sha256=$batchReceiptSha;source_slots_path=$sourceSlotsPath;source_slots_sha256=$sourceSlotsSha;market_relation='asrp.q2_market_1m_observations'};
        factors=@('MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1','NEWS_V6_MATCH_COUNT_24H_LAG15','NEWS_V6_MATCH_COUNT_6H_LAG15','NEWS_V6_SOURCE_COUNT_24H_LAG15');
        missingness=[ordered]@{market=[ordered]@{available=$marketAvailable;missing=$marketMissing;missing_reason='NO_PRIOR_ACTIVE_MARKET_DAY'};news24=[ordered]@{available=$news24Available;source_incomplete=$news24Incomplete;outside_population=$news24Outside;valid_zero_match_rows=$zero24};news6=[ordered]@{available=$news6Available;source_incomplete=$news6Incomplete;outside_population=$news6Outside;valid_zero_match_rows=$zero6}};
        timing=[ordered]@{predictor_cutoff='response_day_utc 00:00:00Z';market_window='[d-1d,d)';news_policy='A_NEWS=B(record_id)+15m';news24_availability_window='[d-24h,d)';news6_availability_window='[d-6h,d)'};
        outputs=[ordered]@{factor_csv=$factorPath;factor_csv_sha256=$factorSha;day_summary_csv=$dayPath;day_summary_csv_sha256=$daySha;review_sample_csv=$reviewPath;review_sample_csv_sha256=$reviewSha;review_rows=$review.Count};
        gates=[ordered]@{'CFA-S5-006'='PASS';'CFA-S5-007'='PASS';'CFA-S5-008'='PASS';'CFA-S5-009'='BLOCKED'};
        next_action='Directly review the candidate factor artifact/review sample, validate hashes, formulas, missingness, source-window boundaries, and lineage before Stage 5 freeze.'
    }
    $receiptPath=Join-Path $runDir 'stage5-candidate-factor-receipt.json'
    Write-Utf8NoBom $receiptPath (($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR ARTIFACT CONSTRUCTION: VALIDATION CANDIDATE'
    Write-Host "Factor rows: $($factorRows.Count)"
    Write-Host "Distinct bases: $($responseBases.Count)"
    Write-Host "Market available / missing: $marketAvailable / $marketMissing"
    Write-Host "News24 available / incomplete / outside: $news24Available / $news24Incomplete / $news24Outside"
    Write-Host "News6 available / incomplete / outside: $news6Available / $news6Incomplete / $news6Outside"
    Write-Host "Review rows: $($review.Count)"
    Write-Host 'CFA-S5-006 market factor definitions: PASS'
    Write-Host 'CFA-S5-007 news factor definitions: PASS'
    Write-Host 'CFA-S5-008 factor artifact construction: PASS'
    Write-Host 'CFA-S5-009 Stage 5 freeze: BLOCKED'
    Write-Host "Review CSV: $reviewPath"
    Write-Host "Candidate receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR ARTIFACT CONSTRUCTION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
finally {
    if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    if($null-eq$oldPassword){Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$oldPassword}
    if($null-eq$oldPgOptions){Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue}else{$env:PGOPTIONS=$oldPgOptions}
}
