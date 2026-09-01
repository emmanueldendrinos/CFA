#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidateReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage4Sha='8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedStage3Sha='c1741dc7ae8de4272fa3c55f59c9efb035e4e72b0c330939b1e12caa6742d20c'
$ExpectedAliasSha='11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'
$ExpectedRows=37058
$ExpectedBases=434
$ExpectedDays=91
$ExpectedReviewRows=46
$ExpectedStage3Rows=22060
$ExpectedStage3Assets=282
$ExpectedStage3Records=18503
$ExpectedNewsPopulation=431
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
$Q2Start=[datetime]::SpecifyKind([datetime]::ParseExact('2025-04-01','yyyy-MM-dd',$Invariant),[DateTimeKind]::Utc)
$Q2End=[datetime]::SpecifyKind([datetime]::ParseExact('2025-07-01','yyyy-MM-dd',$Invariant),[DateTimeKind]::Utc)
$FactorIds=@(
    'MKT_RET_USD_UTC_DAY_OBS_L1',
    'MKT_RANGE_LOG_UTC_DAY_L1',
    'MKT_OBS_COUNT_UTC_DAY_L1',
    'MKT_OBS_SPAN_MIN_UTC_DAY_L1',
    'NEWS_V6_MATCH_COUNT_24H_LAG15',
    'NEWS_V6_MATCH_COUNT_6H_LAG15',
    'NEWS_V6_SOURCE_COUNT_24H_LAG15'
)

function Get-Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Require-File { param([string]$Path,[string]$Label); if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "$Label missing: $Path"}; return (Resolve-Path -LiteralPath $Path).ProviderPath }
function Require-Columns {
    param([object]$Row,[string[]]$Names,[string]$Label)
    $props=@($Row.PSObject.Properties.Name)
    foreach($n in $Names){if($props-notcontains$n){throw "$Label required column missing: $n"}}
}
function Parse-Day {
    param([string]$Text,[string]$Label)
    if($Text-notmatch'^\d{4}-\d{2}-\d{2}$'){throw "Malformed day for ${Label}: '$Text'"}
    $d=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($Text,'yyyy-MM-dd',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$d)){throw "Unparseable day for ${Label}: '$Text'"}
    return [datetime]::SpecifyKind($d,[DateTimeKind]::Utc)
}
function Parse-UtcZ {
    param([object]$Value,[string]$Label)
    $t=([string]$Value).Trim()
    if($t-notmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'){throw "Malformed UTC timestamp for ${Label}: '$Value'"}
    $d=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($t.Substring(0,19),'yyyy-MM-ddTHH:mm:ss',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$d)){throw "Unparseable UTC timestamp for ${Label}: '$Value'"}
    return [datetime]::SpecifyKind($d,[DateTimeKind]::Utc)
}
function Parse-Gdelt14 {
    param([string]$Text,[string]$Label)
    if($Text-notmatch'^\d{14}$'){throw "Malformed GDELT timestamp for ${Label}: '$Text'"}
    $d=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($Text,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$d)){throw "Unparseable GDELT timestamp for ${Label}: '$Text'"}
    return [datetime]::SpecifyKind($d,[DateTimeKind]::Utc)
}
function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $n=0.0
    if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"}
    if([double]::IsNaN($n)-or[double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"}
    return $n
}
function Parse-LongStrict {
    param([object]$Value,[string]$Label)
    $n=[long]0
    if(-not[long]::TryParse(([string]$Value),[Globalization.NumberStyles]::Integer,$Invariant,[ref]$n)){throw "Malformed integer for ${Label}: '$Value'"}
    return $n
}
function Is-Blank { param([object]$Value); return [string]::IsNullOrWhiteSpace([string]$Value) }
function Bool-Text {
    param([object]$Value,[string]$Label)
    $x=([string]$Value).Trim().ToLowerInvariant()
    if($x-eq'true'){return $true}; if($x-eq'false'){return $false}; throw "Malformed boolean text for ${Label}: '$Value'"
}
function Measure-Window {
    param([datetime]$Cutoff,[int]$Hours,[hashtable]$Slots)
    $expected=[int](($Hours*60)/15)
    $batchEnd=$Cutoff.AddMinutes(-15)
    $batchStart=$batchEnd.AddHours(-$Hours)
    [int]$downloaded=0;[int]$providerMissing=0;[int]$outside=0;[int]$registryMissing=0;[int]$other=0
    for($i=0;$i-lt$expected;$i++){
        $t=$batchStart.AddMinutes(15*$i)
        if($t-lt$Q2Start-or$t-ge$Q2End){$outside++;continue}
        $key=$t.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$Slots.ContainsKey($key)){$registryMissing++;continue}
        $status=[string]$Slots[$key].status
        if($status-eq'downloaded'){$downloaded++}elseif($status-eq'provider_missing'){$providerMissing++}else{$other++}
    }
    $complete=($downloaded-eq$expected-and$providerMissing-eq0-and$outside-eq0-and$registryMissing-eq0-and$other-eq0)
    return [pscustomobject]@{complete=$complete;batch_start=$batchStart;batch_end=$batchEnd;downloaded=$downloaded;provider_missing=$providerMissing;outside=$outside;registry_missing=$registryMissing;other=$other}
}
function Require-Hex64 { param([object]$Value,[string]$Label); if(([string]$Value)-notmatch'^[0-9a-fA-F]{64}$'){throw "Malformed SHA-256 for ${Label}: '$Value'"} }

function Invoke-SelfTest {
    $d=Parse-Day '2025-04-02' 'selftest'
    if($d.AddDays(-1).ToString('yyyy-MM-dd',$Invariant)-ne'2025-04-01'){throw 'Day arithmetic self-test failed.'}
    $z=Parse-UtcZ '2025-04-02T01:02:03Z' 'selftest'
    if($z.Hour-ne1-or$z.Minute-ne2-or$z.Second-ne3){throw 'UTC parser self-test failed.'}
    $slots=@{};$s=$Q2Start
    for($i=0;$i-lt96;$i++){$t=$s.AddMinutes(15*$i);$slots[$t.ToString('yyyyMMddHHmmss',$Invariant)]=[pscustomobject]@{status='downloaded'}}
    $w=Measure-Window $Q2Start.AddDays(1).AddMinutes(15) 24 $slots
    if(-not$w.complete-or$w.downloaded-ne96){throw 'Window self-test failed.'}
    $ret=[math]::Log(110/100);$range=[math]::Log(120/90)
    if([math]::Abs($ret-0.09531017980432493)-gt1e-12-or$range-le0){throw 'Formula self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $CandidateReceiptPath=Require-File $CandidateReceiptPath 'Candidate receipt'
    $Stage4ResponsesPath=Require-File $Stage4ResponsesPath 'Stage 4 responses'
    $aliasPath=Require-File (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv') 'Stage 3 alias registry'
    if((Get-Sha $aliasPath)-ne$ExpectedAliasSha){throw 'Stage 3 alias registry SHA-256 mismatch.'}
    if((Get-Sha $Stage4ResponsesPath)-ne$ExpectedStage4Sha){throw 'Stage 4 response SHA-256 mismatch.'}

    $receipt=Get-Content -LiteralPath $CandidateReceiptPath -Raw|ConvertFrom-Json
    if([string]$receipt.status-ne'VALIDATION_CANDIDATE'-or[string]$receipt.stage-ne'CFA_STAGE_5'-or[string]$receipt.factor_contract-ne'INITIAL_7_FACTOR_V1'){throw 'Candidate receipt identity/status mismatch.'}
    if([long]$receipt.row_count-ne$ExpectedRows-or[int]$receipt.distinct_bases-ne$ExpectedBases){throw 'Candidate receipt row/base count mismatch.'}
    if([string]$receipt.gates.'CFA-S5-008'-ne'PASS'-or[string]$receipt.gates.'CFA-S5-009'-ne'BLOCKED'){throw 'Candidate receipt gate status mismatch.'}
    if([string]$receipt.sources.stage4_responses_sha256-ne$ExpectedStage4Sha-or[string]$receipt.sources.stage3_matches_sha256-ne$ExpectedStage3Sha){throw 'Candidate receipt frozen source hashes mismatch.'}
    $receiptFactors=@($receipt.factors|ForEach-Object{[string]$_})
    if(($receiptFactors-join'|')-ne($FactorIds-join'|')){throw 'Candidate receipt factor list/order mismatch.'}

    $factorPath=Require-File ([string]$receipt.outputs.factor_csv) 'Candidate factor CSV'
    $dayPath=Require-File ([string]$receipt.outputs.day_summary_csv) 'Candidate day summary CSV'
    $reviewPath=Require-File ([string]$receipt.outputs.review_sample_csv) 'Candidate review CSV'
    $stage3Path=Require-File ([string]$receipt.sources.stage3_matches_path) 'Stage 3 V6 matches'
    $slotsPath=Require-File ([string]$receipt.sources.source_slots_path) 'GDELT source slots'
    $batchReceiptPath=Require-File ([string]$receipt.sources.batch_timing_receipt_path) 'Batch timing receipt'

    if((Get-Sha $factorPath)-ne([string]$receipt.outputs.factor_csv_sha256).ToLowerInvariant()){throw 'Candidate factor CSV hash mismatch.'}
    if((Get-Sha $dayPath)-ne([string]$receipt.outputs.day_summary_csv_sha256).ToLowerInvariant()){throw 'Candidate day-summary CSV hash mismatch.'}
    if((Get-Sha $reviewPath)-ne([string]$receipt.outputs.review_sample_csv_sha256).ToLowerInvariant()){throw 'Candidate review CSV hash mismatch.'}
    if((Get-Sha $stage3Path)-ne$ExpectedStage3Sha){throw 'Stage 3 V6 SHA-256 mismatch.'}
    if((Get-Sha $slotsPath)-ne([string]$receipt.sources.source_slots_sha256).ToLowerInvariant()){throw 'Source-slot CSV hash mismatch.'}
    if((Get-Sha $batchReceiptPath)-ne([string]$receipt.sources.batch_timing_receipt_sha256).ToLowerInvariant()){throw 'Batch-timing receipt hash mismatch.'}

    $batchReceipt=Get-Content -LiteralPath $batchReceiptPath -Raw|ConvertFrom-Json
    if([string]$batchReceipt.status-ne'PASS'-or[string]$batchReceipt.policy-ne'GDELT_RECORD_BATCH_PLUS_ONE_HEARTBEAT'-or[int]$batchReceipt.availability_lag_minutes-ne15){throw 'Batch-timing receipt policy/status mismatch.'}
    if([string]$batchReceipt.gates.'CFA-S5-013'-ne'PASS'-or[string]$batchReceipt.gates.'CFA-S5-011'-ne'PASS'){throw 'Batch-timing prerequisite gates are not PASS.'}

    $stage4=@(Import-Csv -LiteralPath $Stage4ResponsesPath)
    $factors=@(Import-Csv -LiteralPath $factorPath)
    $days=@(Import-Csv -LiteralPath $dayPath)
    $review=@(Import-Csv -LiteralPath $reviewPath)
    $stage3=@(Import-Csv -LiteralPath $stage3Path)
    $slots=@(Import-Csv -LiteralPath $slotsPath)
    $aliases=@(Import-Csv -LiteralPath $aliasPath)

    if($stage4.Count-ne$ExpectedRows-or$factors.Count-ne$ExpectedRows){throw "Stage4/factor row count mismatch: $($stage4.Count) / $($factors.Count)."}
    if($days.Count-ne$ExpectedDays){throw "Day-summary row count mismatch: $($days.Count)."}
    if($review.Count-ne$ExpectedReviewRows-or[long]$receipt.outputs.review_rows-ne$ExpectedReviewRows){throw "Review row count mismatch: $($review.Count)."}
    if($stage3.Count-ne$ExpectedStage3Rows){throw "Stage 3 row count mismatch: $($stage3.Count)."}
    if($slots.Count-ne$ExpectedSlots){throw "Source-slot count mismatch: $($slots.Count)."}

    Require-Columns $stage4[0] @('base_asset_id','response_day_utc','predictor_cutoff_utc','pair_token_opaque','source_member_ordinal') 'Stage 4'
    Require-Columns $factors[0] @('base_asset_id','response_day_utc','predictor_cutoff_utc','pair_token_opaque','source_member_ordinal','market_missing_reason','market_window_start_utc','market_window_end_exclusive_utc','MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1','market_first_candle_start_utc','market_last_candle_start_utc','market_high_witness_candle_start_utc','market_low_witness_candle_start_utc','market_first_open_price_usd','market_last_close_price_usd','market_max_high_price_usd','market_min_low_price_usd','market_first_physical_record_number','market_last_physical_record_number','market_high_witness_physical_record_number','market_low_witness_physical_record_number','market_first_raw_record_sha256','market_last_raw_record_sha256','market_high_witness_raw_record_sha256','market_low_witness_raw_record_sha256','news_population_status','news_availability_lag_minutes','news_24h_missing_reason','news_24h_availability_window_start_utc','news_24h_availability_window_end_exclusive_utc','news_24h_batch_window_start_utc','news_24h_batch_window_end_exclusive_utc','news_24h_window_complete','NEWS_V6_MATCH_COUNT_24H_LAG15','NEWS_V6_SOURCE_COUNT_24H_LAG15','news_6h_missing_reason','news_6h_availability_window_start_utc','news_6h_availability_window_end_exclusive_utc','news_6h_batch_window_start_utc','news_6h_batch_window_end_exclusive_utc','news_6h_window_complete','NEWS_V6_MATCH_COUNT_6H_LAG15') 'Candidate factors'
    Require-Columns $stage3[0] @('base_asset_id','record_id','source_common_name','archive_file') 'Stage 3 V6'
    Require-Columns $slots[0] @('slot_key','status') 'Source slots'
    Require-Columns $review[0] @('review_reason','base_asset_id','response_day_utc') 'Review sample'

    $newsPopulation=@($aliases|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($newsPopulation.Count-ne$ExpectedNewsPopulation){throw "News population count mismatch: $($newsPopulation.Count)."}
    $newsPopSet=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($a in $newsPopulation){[void]$newsPopSet.Add([string]$a)}

    $slotByKey=@{};[int]$downloaded=0;[int]$providerMissing=0;[int]$otherSlots=0
    foreach($s in $slots){$k=([string]$s.slot_key).Trim();if($k-notmatch'^\d{14}$'){throw "Malformed slot key: $k"};if($slotByKey.ContainsKey($k)){throw "Duplicate slot key: $k"};$slotByKey[$k]=$s;if([string]$s.status-eq'downloaded'){$downloaded++}elseif([string]$s.status-eq'provider_missing'){$providerMissing++}else{$otherSlots++}}
    if($downloaded-ne$ExpectedDownloaded-or$providerMissing-ne$ExpectedProviderMissing-or$otherSlots-ne0){throw "Source-slot status mismatch: $downloaded / $providerMissing / $otherSlots"}

    $newsByAsset=@{};$assetRecord=New-Object 'Collections.Generic.HashSet[string]';$matchedAssets=New-Object 'Collections.Generic.HashSet[string]';$records=New-Object 'Collections.Generic.HashSet[string]'
    foreach($n in $stage3){
        $base=[string]$n.base_asset_id;$rid=[string]$n.record_id;$key=$base+'|'+$rid
        if(-not$assetRecord.Add($key)){throw "Duplicate Stage 3 asset/record key: $key"}
        [void]$matchedAssets.Add($base);[void]$records.Add($rid)
        if(-not$newsPopSet.Contains($base)){throw "Stage 3 matched asset outside news population: $base"}
        if(Is-Blank $n.source_common_name){throw "Blank source_common_name: $rid"}
        $m=[regex]::Match($rid,'^(?<batch>\d{14})-(?:T)?\d+$')
        if(-not$m.Success){throw "Malformed Stage 3 record_id: $rid"}
        $batch=Parse-Gdelt14 $m.Groups['batch'].Value "record_id $rid"
        $archive=([string]$n.archive_file).Substring(0,14)
        if($archive-ne$m.Groups['batch'].Value){throw "Record/archive batch mismatch: $rid"}
        $sk=$batch.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$slotByKey.ContainsKey($sk)-or[string]$slotByKey[$sk].status-ne'downloaded'){throw "Record batch not on downloaded slot: $rid"}
        if(-not$newsByAsset.ContainsKey($base)){$newsByAsset[$base]=New-Object System.Collections.ArrayList}
        [void]$newsByAsset[$base].Add([pscustomobject]@{available=$batch.AddMinutes(15);source=[string]$n.source_common_name;record_id=$rid})
    }
    if($matchedAssets.Count-ne$ExpectedStage3Assets-or$records.Count-ne$ExpectedStage3Records){throw "Stage 3 distinct count mismatch: $($matchedAssets.Count) / $($records.Count)."}

    $stage4ByKey=@{};foreach($r in $stage4){$k=([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc);if($stage4ByKey.ContainsKey($k)){throw "Duplicate Stage 4 key: $k"};$stage4ByKey[$k]=$r}
    $factorByKey=@{};$lastSortKey='';[long]$marketAvailable=0;[long]$marketMissing=0;[long]$n24Avail=0;[long]$n24Inc=0;[long]$n24Out=0;[long]$n6Avail=0;[long]$n6Inc=0;[long]$n6Out=0
    $dayAgg=@{}

    foreach($row in $factors){
        $base=[string]$row.base_asset_id;$dayText=([string]$row.response_day_utc).Trim();$key=$base+'|'+$dayText
        if($factorByKey.ContainsKey($key)){throw "Duplicate factor key: $key"};$factorByKey[$key]=$row
        $sortKey=$dayText+'|'+$base;if($lastSortKey-ne''-and[string]::CompareOrdinal($lastSortKey,$sortKey)-gt0){throw "Factor CSV is not deterministically sorted at $key"};$lastSortKey=$sortKey
        if(-not$stage4ByKey.ContainsKey($key)){throw "Factor key absent from Stage 4: $key"}
        $r=$stage4ByKey[$key]
        if([string]$row.pair_token_opaque-ne[string]$r.pair_token_opaque-or([string]$row.source_member_ordinal).Trim()-ne([string]$r.source_member_ordinal).Trim()){throw "Factor/Stage4 pair lineage mismatch: $key"}
        $expectedCutoff=$dayText+'T00:00:00Z';if(([string]$row.predictor_cutoff_utc).Trim()-cne$expectedCutoff-or([string]$r.predictor_cutoff_utc).Trim()-cne$expectedCutoff){throw "Predictor cutoff mismatch: $key"}
        $cutoff=Parse-Day $dayText "factor $key"
        $prior=$cutoff.AddDays(-1)
        $mStart=$prior.ToString('yyyy-MM-dd',$Invariant)+'T00:00:00Z';$mEnd=$expectedCutoff
        if(([string]$row.market_window_start_utc).Trim()-cne$mStart-or([string]$row.market_window_end_exclusive_utc).Trim()-cne$mEnd){throw "Market window mismatch: $key"}

        $marketReason=[string]$row.market_missing_reason
        if($marketReason-eq'NONE'){
            $marketAvailable++
            $ret=Parse-DoubleStrict $row.MKT_RET_USD_UTC_DAY_OBS_L1 "$key market return";$range=Parse-DoubleStrict $row.MKT_RANGE_LOG_UTC_DAY_L1 "$key market range";$count=Parse-LongStrict $row.MKT_OBS_COUNT_UTC_DAY_L1 "$key market count";$span=Parse-LongStrict $row.MKT_OBS_SPAN_MIN_UTC_DAY_L1 "$key market span"
            $open=Parse-DoubleStrict $row.market_first_open_price_usd "$key first open";$close=Parse-DoubleStrict $row.market_last_close_price_usd "$key last close";$high=Parse-DoubleStrict $row.market_max_high_price_usd "$key max high";$low=Parse-DoubleStrict $row.market_min_low_price_usd "$key min low"
            if($open-le0-or$close-le0-or$high-le0-or$low-le0-or$count-lt1-or$span-lt0-or$high-lt$low){throw "Invalid market witness/value domain: $key"}
            if([math]::Abs($ret-[math]::Log($close/$open))-gt1e-12-or[math]::Abs($range-[math]::Log($high/$low))-gt1e-12){throw "Market formula mismatch: $key"}
            $first=Parse-UtcZ $row.market_first_candle_start_utc "$key first candle";$last=Parse-UtcZ $row.market_last_candle_start_utc "$key last candle";$hiTs=Parse-UtcZ $row.market_high_witness_candle_start_utc "$key high witness";$loTs=Parse-UtcZ $row.market_low_witness_candle_start_utc "$key low witness"
            foreach($t in @($first,$last,$hiTs,$loTs)){if($t-lt$prior-or$t-ge$cutoff){throw "Market witness outside prior-day window: $key"}}
            if($first-gt$last){throw "Market first/last ordering failure: $key"}
            $spanCalc=[long][math]::Round(($last-$first).TotalMinutes);if($spanCalc-ne$span){throw "Market span mismatch: $key observed=$span expected=$spanCalc"}
            foreach($p in @('market_first_physical_record_number','market_last_physical_record_number','market_high_witness_physical_record_number','market_low_witness_physical_record_number')){if((Parse-LongStrict $row.$p "$key $p")-lt1){throw "Invalid physical record number: $key $p"}}
            foreach($p in @('market_first_raw_record_sha256','market_last_raw_record_sha256','market_high_witness_raw_record_sha256','market_low_witness_raw_record_sha256')){Require-Hex64 $row.$p "$key $p"}
        }elseif($marketReason-eq'NO_PRIOR_ACTIVE_MARKET_DAY'){
            $marketMissing++
            foreach($p in @('MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1','market_first_candle_start_utc','market_last_candle_start_utc','market_high_witness_candle_start_utc','market_low_witness_candle_start_utc','market_first_open_price_usd','market_last_close_price_usd','market_max_high_price_usd','market_min_low_price_usd','market_first_physical_record_number','market_last_physical_record_number','market_high_witness_physical_record_number','market_low_witness_physical_record_number','market_first_raw_record_sha256','market_last_raw_record_sha256','market_high_witness_raw_record_sha256','market_low_witness_raw_record_sha256')){if(-not(Is-Blank $row.$p)){throw "Market-missing row contains value: $key $p"}}
        }else{throw "Unexpected market missingness reason: $key '$marketReason'"}

        $inPop=$newsPopSet.Contains($base);$expectedPop=if($inPop){'IN_POPULATION'}else{'OUTSIDE_NEWS_POPULATION'}
        if([string]$row.news_population_status-ne$expectedPop-or[string]$row.news_availability_lag_minutes-ne'15'){throw "News population/lag mismatch: $key"}
        $w24=Measure-Window $cutoff 24 $slotByKey;$w6=Measure-Window $cutoff 6 $slotByKey
        $aw24Start=$cutoff.AddHours(-24).ToString('yyyy-MM-ddTHH:mm:ss',$Invariant)+'Z';$aw6Start=$cutoff.AddHours(-6).ToString('yyyy-MM-ddTHH:mm:ss',$Invariant)+'Z';$cutoffText=$expectedCutoff
        if([string]$row.news_24h_availability_window_start_utc-ne$aw24Start-or[string]$row.news_24h_availability_window_end_exclusive_utc-ne$cutoffText-or[string]$row.news_6h_availability_window_start_utc-ne$aw6Start-or[string]$row.news_6h_availability_window_end_exclusive_utc-ne$cutoffText){throw "News availability window mismatch: $key"}
        if([string]$row.news_24h_batch_window_start_utc-ne($w24.batch_start.ToString('yyyy-MM-ddTHH:mm:ss',$Invariant)+'Z')-or[string]$row.news_24h_batch_window_end_exclusive_utc-ne($w24.batch_end.ToString('yyyy-MM-ddTHH:mm:ss',$Invariant)+'Z')-or[string]$row.news_6h_batch_window_start_utc-ne($w6.batch_start.ToString('yyyy-MM-ddTHH:mm:ss',$Invariant)+'Z')-or[string]$row.news_6h_batch_window_end_exclusive_utc-ne($w6.batch_end.ToString('yyyy-MM-ddTHH:mm:ss',$Invariant)+'Z')){throw "News batch window mismatch: $key"}
        if((Bool-Text $row.news_24h_window_complete "$key news24 complete")-ne[bool]$w24.complete-or(Bool-Text $row.news_6h_window_complete "$key news6 complete")-ne[bool]$w6.complete){throw "News completeness flag mismatch: $key"}

        $reason24=[string]$row.news_24h_missing_reason;$reason6=[string]$row.news_6h_missing_reason
        if(-not$inPop){$exp24='OUTSIDE_NEWS_POPULATION';$exp6='OUTSIDE_NEWS_POPULATION'}else{$exp24=if($w24.complete){'NONE'}else{'SOURCE_WINDOW_INCOMPLETE'};$exp6=if($w6.complete){'NONE'}else{'SOURCE_WINDOW_INCOMPLETE'}}
        if($reason24-ne$exp24-or$reason6-ne$exp6){throw "News missingness reason mismatch: $key 24=$reason24/$exp24 6=$reason6/$exp6"}

        [long]$c24=0;[long]$c6=0;$src24=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        if($newsByAsset.ContainsKey($base)){
            $start24=$cutoff.AddHours(-24);$start6=$cutoff.AddHours(-6)
            foreach($n in @($newsByAsset[$base].ToArray())){$a=[datetime]$n.available;if($a-ge$start24-and$a-lt$cutoff){$c24++;[void]$src24.Add([string]$n.source)};if($a-ge$start6-and$a-lt$cutoff){$c6++}}
        }
        if($reason24-eq'NONE'){$n24Avail++;if((Parse-LongStrict $row.NEWS_V6_MATCH_COUNT_24H_LAG15 "$key news24")-ne$c24-or(Parse-LongStrict $row.NEWS_V6_SOURCE_COUNT_24H_LAG15 "$key source24")-ne[long]$src24.Count){throw "24h news recomputation mismatch: $key"}}elseif($reason24-eq'SOURCE_WINDOW_INCOMPLETE'){$n24Inc++;if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)-and$false){}}else{$n24Out++}
        if($reason24-ne'NONE' -and (-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15) -or -not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15))){throw "24h missing row contains factor value: $key"}
        if($reason6-eq'NONE'){$n6Avail++;if((Parse-LongStrict $row.NEWS_V6_MATCH_COUNT_6H_LAG15 "$key news6")-ne$c6){throw "6h news recomputation mismatch: $key"}}elseif($reason6-eq'SOURCE_WINDOW_INCOMPLETE'){$n6Inc++}else{$n6Out++}
        if($reason6-ne'NONE' -and -not(Is-Blank $row.NEWS_V6_MATCH_COUNT_6H_LAG15)){throw "6h missing row contains factor value: $key"}
        if($reason24-eq'NONE'-and$reason6-eq'NONE'-and$c6-gt$c24){throw "6h count exceeds 24h count: $key"}

        if(-not$dayAgg.ContainsKey($dayText)){$dayAgg[$dayText]=[ordered]@{response_rows=0;market_available_rows=0;market_missing_rows=0;news24_available_rows=0;news24_incomplete_rows=0;news24_outside_rows=0;news6_available_rows=0;news6_incomplete_rows=0;news6_outside_rows=0}}
        $da=$dayAgg[$dayText];$da.response_rows++;if($marketReason-eq'NONE'){$da.market_available_rows++}else{$da.market_missing_rows++};if($reason24-eq'NONE'){$da.news24_available_rows++}elseif($reason24-eq'SOURCE_WINDOW_INCOMPLETE'){$da.news24_incomplete_rows++}else{$da.news24_outside_rows++};if($reason6-eq'NONE'){$da.news6_available_rows++}elseif($reason6-eq'SOURCE_WINDOW_INCOMPLETE'){$da.news6_incomplete_rows++}else{$da.news6_outside_rows++}
    }

    if($factorByKey.Count-ne$stage4ByKey.Count){throw 'Factor/Stage4 key cardinality mismatch.'}
    foreach($k in $stage4ByKey.Keys){if(-not$factorByKey.ContainsKey($k)){throw "Stage4 key absent from factor artifact: $k"}}
    $factorBases=@($factors|Select-Object -ExpandProperty base_asset_id -Unique);if($factorBases.Count-ne$ExpectedBases){throw "Factor distinct base count mismatch: $($factorBases.Count)."}
    if($marketAvailable-ne$ExpectedMarketAvailable-or$marketMissing-ne$ExpectedMarketMissing){throw "Market partition mismatch: $marketAvailable / $marketMissing"}
    if($n24Avail-ne$ExpectedNews24Available-or$n24Inc-ne$ExpectedNews24Incomplete-or$n24Out-ne$ExpectedNews24Outside){throw "News24 partition mismatch: $n24Avail / $n24Inc / $n24Out"}
    if($n6Avail-ne$ExpectedNews6Available-or$n6Inc-ne$ExpectedNews6Incomplete-or$n6Out-ne$ExpectedNews6Outside){throw "News6 partition mismatch: $n6Avail / $n6Inc / $n6Out"}

    $dayByKey=@{};foreach($d in $days){$k=[string]$d.response_day_utc;if($dayByKey.ContainsKey($k)){throw "Duplicate day-summary row: $k"};$dayByKey[$k]=$d}
    if($dayAgg.Count-ne$ExpectedDays-or$dayByKey.Count-ne$ExpectedDays){throw 'Day-summary day cardinality mismatch.'}
    foreach($k in $dayAgg.Keys){if(-not$dayByKey.ContainsKey($k)){throw "Missing day-summary row: $k"};$d=$dayByKey[$k];foreach($p in @('response_rows','market_available_rows','market_missing_rows','news24_available_rows','news24_incomplete_rows','news24_outside_rows','news6_available_rows','news6_incomplete_rows','news6_outside_rows')){if((Parse-LongStrict $d.$p "$k day summary $p")-ne[long]$dayAgg[$k][$p]){throw "Day-summary mismatch: $k $p"}}}

    $reviewReasons=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $reviewValidation=New-Object System.Collections.ArrayList
    foreach($rv in $review){$k=([string]$rv.base_asset_id)+'|'+([string]$rv.response_day_utc);if(-not$factorByKey.ContainsKey($k)){throw "Review key absent from factor artifact: $k"};$src=$factorByKey[$k];foreach($p in $src.PSObject.Properties){if(([string]$rv.($p.Name))-cne([string]$p.Value){throw "Review row differs from factor artifact: $k column=$($p.Name)"}};foreach($reason in (([string]$rv.review_reason)-split'\|')){if(-not[string]::IsNullOrWhiteSpace($reason)){[void]$reviewReasons.Add($reason)}};[void]$reviewValidation.Add([pscustomobject][ordered]@{base_asset_id=$rv.base_asset_id;response_day_utc=$rv.response_day_utc;review_reason=$rv.review_reason;validation_status='PASS'})}
    foreach($reason in @('EARLIEST','LATEST','MARKET_MISSING','NEWS24_INCOMPLETE','NEWS6_INCOMPLETE','OUTSIDE_NEWS_POPULATION','LARGEST_ABS_MARKET_RETURN','LARGEST_NEWS24_COUNT','LARGEST_NEWS6_COUNT')){if(-not$reviewReasons.Contains($reason)){throw "Review sample coverage reason missing: $reason"}}

    if([long]$receipt.missingness.market.available-ne$marketAvailable-or[long]$receipt.missingness.market.missing-ne$marketMissing-or[long]$receipt.missingness.news24.available-ne$n24Avail-or[long]$receipt.missingness.news24.source_incomplete-ne$n24Inc-or[long]$receipt.missingness.news24.outside_population-ne$n24Out-or[long]$receipt.missingness.news6.available-ne$n6Avail-or[long]$receipt.missingness.news6.source_incomplete-ne$n6Inc-or[long]$receipt.missingness.news6.outside_population-ne$n6Out){throw 'Candidate receipt missingness counts do not reconcile validated artifact.'}

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Split-Path -Parent $CandidateReceiptPath}
    if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $validationReviewPath=Join-Path $OutputRoot 'stage5-factor-artifact-validation-review.csv'
    @($reviewValidation.ToArray())|Export-Csv -LiteralPath $validationReviewPath -NoTypeInformation -Encoding UTF8
    $validationReceiptPath=Join-Path $OutputRoot 'stage5-factor-artifact-validation.json'
    $out=[ordered]@{
        status='PASS';stage='CFA_STAGE_5';validation='INDEPENDENT_FACTOR_ARTIFACT_V1';candidate_receipt_path=$CandidateReceiptPath;candidate_receipt_sha256=(Get-Sha $CandidateReceiptPath);factor_csv=$factorPath;factor_csv_sha256=(Get-Sha $factorPath);day_summary_csv=$dayPath;day_summary_csv_sha256=(Get-Sha $dayPath);review_csv=$reviewPath;review_csv_sha256=(Get-Sha $reviewPath);validation_review_csv=$validationReviewPath;validation_review_csv_sha256=(Get-Sha $validationReviewPath);row_count=$factors.Count;distinct_bases=$factorBases.Count;days=$dayAgg.Count;review_rows=$review.Count;market=[ordered]@{available=$marketAvailable;missing=$marketMissing};news24=[ordered]@{available=$n24Avail;source_incomplete=$n24Inc;outside_population=$n24Out};news6=[ordered]@{available=$n6Avail;source_incomplete=$n6Inc;outside_population=$n6Out};checks=[ordered]@{candidate_hashes='PASS';stage4_key_identity='PASS';deterministic_order='PASS';market_formula_and_witness_windows='PASS';market_missingness='PASS';news_slot_completeness_recomputed='PASS';news_v6_counts_recomputed='PASS';news_source_counts_recomputed='PASS';news_missingness='PASS';day_summary='PASS';review_sample_exactness_and_coverage='PASS'};gates=[ordered]@{'CFA-S5-008'='PASS';'CFA-S5-014'='PASS';'CFA-S5-009'='UNVERIFIED'};next_action='Record exact validated artifact hashes in the Stage 5 contract and freeze CFA-S5-009 only after repository evidence is updated.'
    }
    [IO.File]::WriteAllText($validationReceiptPath,(($out|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR ARTIFACT INDEPENDENT VALIDATION: PASS'
    Write-Host "Factor rows / bases / days: $($factors.Count) / $($factorBases.Count) / $($dayAgg.Count)"
    Write-Host "Market available / missing: $marketAvailable / $marketMissing"
    Write-Host "News24 available / incomplete / outside: $n24Avail / $n24Inc / $n24Out"
    Write-Host "News6 available / incomplete / outside: $n6Avail / $n6Inc / $n6Out"
    Write-Host "Review rows independently validated: $($review.Count)"
    Write-Host 'CFA-S5-008 factor artifact construction: PASS'
    Write-Host 'CFA-S5-014 independent factor artifact validation: PASS'
    Write-Host 'CFA-S5-009 Stage 5 freeze: UNVERIFIED'
    Write-Host "Factor CSV SHA-256: $(Get-Sha $factorPath)"
    Write-Host "Validation review CSV: $validationReviewPath"
    Write-Host "Validation receipt: $validationReceiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR ARTIFACT INDEPENDENT VALIDATION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
