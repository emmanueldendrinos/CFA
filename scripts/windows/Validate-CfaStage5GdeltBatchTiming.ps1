#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V6MatchesPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [Parameter(Mandatory=$true)][string]$NewsCoverageReceiptPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage3Rows=22060
$ExpectedStage3MatchedAssets=282
$ExpectedStage3DistinctRecords=18503
$ExpectedStage3NewsAssets=431
$ExpectedStage4Rows=37058
$ExpectedStage4Bases=434
$ExpectedResponseId='RET_USD_UTC_DAY_OBS_LOG'
$ExpectedStage4Sha='8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedAliasSha='11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'
$ExpectedSlots=8736
$ExpectedDownloaded=7163
$ExpectedProviderMissing=1573
$ExpectedContractStart=[datetime]::SpecifyKind([datetime]::ParseExact('2025-04-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)
$ExpectedContractEnd=[datetime]::SpecifyKind([datetime]::ParseExact('2025-07-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)
$AvailabilityLagMinutes=15

function Get-Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

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

function Parse-Gdelt14 {
    param([string]$Text,[string]$Label)
    if($Text-notmatch'^\d{14}$'){throw "Malformed 14-digit UTC timestamp for ${Label}: '$Text'"}
    $dt=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($Text,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$dt)){throw "Unparseable UTC timestamp for ${Label}: '$Text'"}
    return [datetime]::SpecifyKind($dt,[DateTimeKind]::Utc)
}

function Get-RecordBatchUtc {
    param([string]$RecordId)
    $m=[regex]::Match($RecordId,'^(?<batch>\d{14})-(?:T)?\d+$',[Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if(-not$m.Success){throw "Malformed GKGRECORDID: '$RecordId'"}
    return Parse-Gdelt14 $m.Groups['batch'].Value "record_id $RecordId"
}

function Get-ArchiveBatchUtc {
    param([string]$ArchiveFile)
    $m=[regex]::Match($ArchiveFile,'^(?<batch>\d{14})\.gkg\.csv\.zip$',[Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if(-not$m.Success){throw "Malformed retained archive filename: '$ArchiveFile'"}
    return Parse-Gdelt14 $m.Groups['batch'].Value "archive_file $ArchiveFile"
}

function Measure-ShiftedWindow {
    param([datetime]$CutoffUtc,[int]$Hours,[hashtable]$SlotByKey)
    $expected=[int](($Hours*60)/15)
    $batchEnd=$CutoffUtc.AddMinutes(-$AvailabilityLagMinutes)
    $batchStart=$batchEnd.AddHours(-$Hours)
    [int]$downloaded=0;[int]$providerMissing=0;[int]$outside=0;[int]$registryMissing=0;[int]$other=0
    for($i=0;$i-lt$expected;$i++){
        $slotTime=$batchStart.AddMinutes(15*$i)
        if($slotTime-lt$ExpectedContractStart-or$slotTime-ge$ExpectedContractEnd){$outside++;continue}
        $key=$slotTime.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$SlotByKey.ContainsKey($key)){$registryMissing++;continue}
        $status=[string]$SlotByKey[$key].status
        if($status-eq'downloaded'){$downloaded++}
        elseif($status-eq'provider_missing'){$providerMissing++}
        else{$other++}
    }
    $complete=($downloaded-eq$expected-and$providerMissing-eq0-and$outside-eq0-and$registryMissing-eq0-and$other-eq0)
    return [pscustomobject]@{
        hours=$Hours;expected_slots=$expected;batch_start_utc=$batchStart;batch_end_exclusive_utc=$batchEnd;
        downloaded_slots=$downloaded;provider_missing_slots=$providerMissing;outside_contract_slots=$outside;
        registry_missing_slots=$registryMissing;other_status_slots=$other;complete=$complete
    }
}

function Invoke-SelfTest {
    $r1=Get-RecordBatchUtc '20250401003000-5'
    $r2=Get-RecordBatchUtc '20250401004500-T8'
    if($r1.ToString('yyyyMMddHHmmss',$Invariant)-ne'20250401003000'-or$r2.ToString('yyyyMMddHHmmss',$Invariant)-ne'20250401004500'){throw 'Record batch parser self-test failed.'}
    $a=Get-ArchiveBatchUtc '20250401003000.gkg.csv.zip'
    if($a-ne$r1){throw 'Archive batch parser self-test failed.'}

    $slots=@{}
    $start=[datetime]::SpecifyKind([datetime]::ParseExact('2025-04-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)
    for($i=0;$i-lt96;$i++){
        $t=$start.AddMinutes(15*$i)
        $slots[$t.ToString('yyyyMMddHHmmss',$Invariant)]=[pscustomobject]@{status='downloaded'}
    }
    $cutoff=$start.AddDays(1).AddMinutes(15)
    $w=Measure-ShiftedWindow $cutoff 24 $slots
    if(-not[bool]$w.complete-or[int]$w.downloaded_slots-ne96){throw 'Shifted 24h complete-window self-test failed.'}
    $slots[$start.AddHours(12).ToString('yyyyMMddHHmmss',$Invariant)]=[pscustomobject]@{status='provider_missing'}
    $w=Measure-ShiftedWindow $cutoff 24 $slots
    if([bool]$w.complete-or[int]$w.provider_missing_slots-ne1){throw 'Shifted provider-missing self-test failed.'}

    # Regression: never use PowerShell automatic $Matches for retained-row storage.
    $newsRows=@([pscustomobject]@{record_id='20250401003000-1'})
    'abc' -match 'a' | Out-Null
    if($newsRows.Count-ne1){throw 'Automatic $Matches collision regression failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $Stage3V6MatchesPath=(Resolve-Path -LiteralPath $Stage3V6MatchesPath).ProviderPath
    $Stage4ResponsesPath=(Resolve-Path -LiteralPath $Stage4ResponsesPath).ProviderPath
    $NewsCoverageReceiptPath=(Resolve-Path -LiteralPath $NewsCoverageReceiptPath).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage5-gdelt-batch-timing'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null

    $contractText=Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage5-factor-contract.md') -Raw
    foreach($marker in @('CFA-S5-010','PASS','CFA-S5-013','UNVERIFIED','CFA-S5-011','A_NEWS(r) = B(r) + 15 minutes')){
        if($contractText-notmatch[regex]::Escape($marker)){throw "Current Stage 5 contract marker missing: $marker"}
    }

    $coverage=Get-Content -LiteralPath $NewsCoverageReceiptPath -Raw|ConvertFrom-Json
    if([string]$coverage.status-ne'PASS'){throw 'News coverage receipt is not PASS.'}
    if([string]$coverage.gates.'CFA-S5-010'-ne'PASS'){throw 'News coverage receipt does not have CFA-S5-010 PASS.'}
    if([int]$coverage.source_contract.nominal_slots-ne$ExpectedSlots-or[int]$coverage.source_contract.downloaded_slots-ne$ExpectedDownloaded-or[int]$coverage.source_contract.provider_missing_slots-ne$ExpectedProviderMissing){throw 'News coverage receipt source accounting changed.'}
    $sourceSlotsPath=(Resolve-Path -LiteralPath ([string]$coverage.outputs.source_slots_csv)).ProviderPath
    $sourceSlots=@(Import-Csv -LiteralPath $sourceSlotsPath)
    if($sourceSlots.Count-ne$ExpectedSlots){throw "Source slot CSV row count changed: $($sourceSlots.Count)."}
    Require-Columns $sourceSlots[0] @('object_key','slot_key','status','http_status','payload_sha256') 'source slot CSV'
    $slotByKey=@{}
    [int]$downloadedSlots=0;[int]$providerMissingSlots=0;[int]$otherSlots=0
    foreach($slot in $sourceSlots){
        $key=([string]$slot.slot_key).Trim()
        if($key-notmatch'^\d{14}$'){throw "Malformed source slot key: $key"}
        if($slotByKey.ContainsKey($key)){throw "Duplicate source slot key: $key"}
        $slotByKey[$key]=$slot
        if([string]$slot.status-eq'downloaded'){$downloadedSlots++}
        elseif([string]$slot.status-eq'provider_missing'){$providerMissingSlots++}
        else{$otherSlots++}
    }
    if($downloadedSlots-ne$ExpectedDownloaded-or$providerMissingSlots-ne$ExpectedProviderMissing-or$otherSlots-ne0){throw 'Source slot status accounting changed.'}

    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if((Get-Sha $aliasPath)-ne$ExpectedAliasSha){throw 'Stage 3 alias registry SHA-256 mismatch.'}
    $aliasRows=@(Import-Csv -LiteralPath $aliasPath)
    $newsPopulation=@($aliasRows|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($newsPopulation.Count-ne$ExpectedStage3NewsAssets){throw "Stage 3 news population changed: $($newsPopulation.Count)."}

    if((Get-Sha $Stage4ResponsesPath)-ne$ExpectedStage4Sha){throw 'Stage 4 response CSV SHA-256 mismatch.'}
    $responses=@(Import-Csv -LiteralPath $Stage4ResponsesPath)
    if($responses.Count-ne$ExpectedStage4Rows){throw "Stage 4 response rows changed: $($responses.Count)."}
    Require-Columns $responses[0] @('response_id','base_asset_id','response_day_utc','predictor_cutoff_utc') 'Stage 4 responses'
    $responseIds=@($responses|Select-Object -ExpandProperty response_id -Unique)
    if($responseIds.Count-ne1-or[string]$responseIds[0]-ne$ExpectedResponseId){throw 'Stage 4 response identity changed.'}
    $responseBases=@($responses|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($responseBases.Count-ne$ExpectedStage4Bases){throw "Stage 4 response base count changed: $($responseBases.Count)."}
    $responseOnly=@($responseBases|Where-Object{$newsPopulation-notcontains$_}|Sort-Object)
    if(($responseOnly-join',')-ne'ZAUD,ZEUR,ZGBP'){throw "Response-only news population changed: $($responseOnly-join',')."}

    $stage3SummaryPath=Join-Path (Split-Path -Parent $Stage3V6MatchesPath) 'stage3-match-summary.json'
    if(-not(Test-Path -LiteralPath $stage3SummaryPath -PathType Leaf)){throw 'Stage 3 sibling summary missing.'}
    $stage3Summary=Get-Content -LiteralPath $stage3SummaryPath -Raw|ConvertFrom-Json
    if([string]$stage3Summary.run_status-ne'PASS'-or[string]$stage3Summary.matching_contract-ne'CANDIDATE_V6'){throw 'Stage 3 sibling summary is not PASS CANDIDATE_V6.'}
    $stage3Sha=Get-Sha $Stage3V6MatchesPath
    if($stage3Sha-ne([string]$stage3Summary.output.matches_sha256).ToLowerInvariant()){throw 'Stage 3 V6 match SHA-256 mismatch.'}
    $newsRows=@(Import-Csv -LiteralPath $Stage3V6MatchesPath)
    if($newsRows.Count-ne$ExpectedStage3Rows){throw "Stage 3 V6 rows changed: $($newsRows.Count)."}
    Require-Columns $newsRows[0] @('base_asset_id','record_id','gdelt_date_utc','source_common_name','archive_file','row_ordinal') 'Stage 3 V6 matches'

    $assetRecordKeys=New-Object 'Collections.Generic.HashSet[string]'
    $matchedAssets=New-Object 'Collections.Generic.HashSet[string]'
    $recordIds=New-Object 'Collections.Generic.HashSet[string]'
    [long]$recordArchiveMismatch=0;[long]$misalignedBatch=0;[long]$batchNotDownloaded=0
    [long]$dateEqualsBatch=0;[long]$dateDiffersBatch=0
    [long]$deltaMin=[long]::MaxValue;[long]$deltaMax=[long]::MinValue
    $batchRows=New-Object System.Collections.ArrayList

    foreach($row in $newsRows){
        $key=([string]$row.base_asset_id)+'|'+([string]$row.record_id)
        if(-not$assetRecordKeys.Add($key)){throw "Duplicate V6 asset/record key: $key"}
        [void]$matchedAssets.Add([string]$row.base_asset_id)
        [void]$recordIds.Add([string]$row.record_id)

        $batch=Get-RecordBatchUtc ([string]$row.record_id)
        $archiveBatch=Get-ArchiveBatchUtc ([string]$row.archive_file)
        if($batch-ne$archiveBatch){$recordArchiveMismatch++}
        if(($batch.Minute%15)-ne0-or$batch.Second-ne0){$misalignedBatch++}
        $batchKey=$batch.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$slotByKey.ContainsKey($batchKey)-or[string]$slotByKey[$batchKey].status-ne'downloaded'){$batchNotDownloaded++}

        $articleDate=Parse-Gdelt14 ([string]$row.gdelt_date_utc) "gdelt_date_utc record $($row.record_id)"
        $delta=[long][math]::Round(($articleDate-$batch).TotalSeconds)
        if($delta-lt$deltaMin){$deltaMin=$delta};if($delta-gt$deltaMax){$deltaMax=$delta}
        if($delta-eq0){$dateEqualsBatch++}else{$dateDiffersBatch++}
        [void]$batchRows.Add([pscustomobject][ordered]@{
            base_asset_id=[string]$row.base_asset_id;record_id=[string]$row.record_id;archive_file=[string]$row.archive_file;
            gdelt_date_utc=[string]$row.gdelt_date_utc;batch_utc=$batch.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);
            conservative_available_utc=$batch.AddMinutes($AvailabilityLagMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);
            gdelt_date_minus_batch_seconds=$delta
        })
    }
    if($matchedAssets.Count-ne$ExpectedStage3MatchedAssets-or$recordIds.Count-ne$ExpectedStage3DistinctRecords){throw 'Stage 3 distinct matched-asset/record counts changed.'}
    if($recordArchiveMismatch-ne0-or$misalignedBatch-ne0-or$batchNotDownloaded-ne0){throw "Batch timing reconciliation failed: record_archive_mismatch=$recordArchiveMismatch misaligned=$misalignedBatch not_downloaded=$batchNotDownloaded"}

    $batchRowsPath=Join-Path $runDir 'stage5-v6-batch-timing-reconciliation.csv'
    @($batchRows.ToArray())|Export-Csv -LiteralPath $batchRowsPath -NoTypeInformation -Encoding UTF8

    $byDay=@{}
    foreach($r in $responses){
        $d=[string]$r.response_day_utc
        if(-not$byDay.ContainsKey($d)){$byDay[$d]=[pscustomobject]@{response_rows=0;in_population=0;outside_population=0}}
        $s=$byDay[$d];$s.response_rows++
        if($newsPopulation-contains[string]$r.base_asset_id){$s.in_population++}else{$s.outside_population++}
    }
    $responseDays=@($byDay.Keys|Sort-Object)
    $dayRows=New-Object System.Collections.ArrayList
    [long]$rows24Available=0;[long]$rows24Incomplete=0;[long]$rows24Outside=0
    [long]$rows6Available=0;[long]$rows6Incomplete=0;[long]$rows6Outside=0
    [int]$complete24Days=0;[int]$complete6Days=0
    foreach($dayText in $responseDays){
        $cutoff=[datetime]::SpecifyKind([datetime]::ParseExact($dayText,'yyyy-MM-dd',$Invariant),[DateTimeKind]::Utc)
        $w24=Measure-ShiftedWindow $cutoff 24 $slotByKey
        $w6=Measure-ShiftedWindow $cutoff 6 $slotByKey
        $counts=$byDay[$dayText]
        if([bool]$w24.complete){$complete24Days++;$rows24Available+=[long]$counts.in_population}else{$rows24Incomplete+=[long]$counts.in_population}
        if([bool]$w6.complete){$complete6Days++;$rows6Available+=[long]$counts.in_population}else{$rows6Incomplete+=[long]$counts.in_population}
        $rows24Outside+=[long]$counts.outside_population;$rows6Outside+=[long]$counts.outside_population
        [void]$dayRows.Add([pscustomobject][ordered]@{
            response_day_utc=$dayText;response_rows=[int]$counts.response_rows;response_rows_in_news_population=[int]$counts.in_population;response_rows_outside_news_population=[int]$counts.outside_population;
            lag_minutes=$AvailabilityLagMinutes;
            window_24h_batch_start_utc=$w24.batch_start_utc.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);window_24h_batch_end_exclusive_utc=$w24.batch_end_exclusive_utc.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);window_24h_complete=[bool]$w24.complete;window_24h_downloaded_slots=[int]$w24.downloaded_slots;window_24h_provider_missing_slots=[int]$w24.provider_missing_slots;window_24h_outside_contract_slots=[int]$w24.outside_contract_slots;
            window_6h_batch_start_utc=$w6.batch_start_utc.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);window_6h_batch_end_exclusive_utc=$w6.batch_end_exclusive_utc.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant);window_6h_complete=[bool]$w6.complete;window_6h_downloaded_slots=[int]$w6.downloaded_slots;window_6h_provider_missing_slots=[int]$w6.provider_missing_slots;window_6h_outside_contract_slots=[int]$w6.outside_contract_slots
        })
    }
    if(($rows24Available+$rows24Incomplete+$rows24Outside)-ne$ExpectedStage4Rows){throw 'Shifted 24h response-row accounting does not reconcile.'}
    if(($rows6Available+$rows6Incomplete+$rows6Outside)-ne$ExpectedStage4Rows){throw 'Shifted 6h response-row accounting does not reconcile.'}

    $dayPath=Join-Path $runDir 'stage5-lag15-news-window-coverage-by-day.csv'
    @($dayRows.ToArray())|Export-Csv -LiteralPath $dayPath -NoTypeInformation -Encoding UTF8

    $summary=[ordered]@{
        status='PASS';stage='CFA_STAGE_5';policy='GDELT_RECORD_BATCH_PLUS_ONE_HEARTBEAT';availability_lag_minutes=$AvailabilityLagMinutes;
        sources=[ordered]@{stage3_matches_path=$Stage3V6MatchesPath;stage3_matches_sha256=$stage3Sha;stage4_responses_path=$Stage4ResponsesPath;stage4_responses_sha256=$ExpectedStage4Sha;news_coverage_receipt=$NewsCoverageReceiptPath;source_slots_csv=$sourceSlotsPath};
        stage3=[ordered]@{rows=$newsRows.Count;matched_assets=$matchedAssets.Count;distinct_records=$recordIds.Count;record_archive_mismatches=$recordArchiveMismatch;misaligned_batch_timestamps=$misalignedBatch;batch_timestamps_not_downloaded=$batchNotDownloaded;gdelt_date_equals_batch_rows=$dateEqualsBatch;gdelt_date_differs_batch_rows=$dateDiffersBatch;gdelt_date_minus_batch_min_seconds=$deltaMin;gdelt_date_minus_batch_max_seconds=$deltaMax};
        population=[ordered]@{response_rows=$responses.Count;response_bases=$responseBases.Count;news_population_assets=$newsPopulation.Count;response_only_assets=@($responseOnly)};
        shifted_24h=[ordered]@{response_days=$responseDays.Count;complete_response_days=$complete24Days;available_in_population_response_rows=$rows24Available;source_incomplete_in_population_response_rows=$rows24Incomplete;outside_news_population_response_rows=$rows24Outside};
        shifted_6h=[ordered]@{response_days=$responseDays.Count;complete_response_days=$complete6Days;available_in_population_response_rows=$rows6Available;source_incomplete_in_population_response_rows=$rows6Incomplete;outside_news_population_response_rows=$rows6Outside};
        outputs=[ordered]@{batch_timing_reconciliation_csv=$batchRowsPath;shifted_window_coverage_by_day_csv=$dayPath};
        gates=[ordered]@{'CFA-S5-013'='PASS';'CFA-S5-011'='PASS';'CFA-S5-007'='UNVERIFIED';'CFA-S5-008'='BLOCKED';'CFA-S5-009'='BLOCKED'};
        next_action='Use the validated record-batch plus 15-minute availability rule and observed shifted-window counts to freeze exact news-factor definitions. Do not use gdelt_date_utc as the availability clock.'
    }
    $receiptPath=Join-Path $runDir 'stage5-gdelt-batch-timing.json'
    Write-Utf8NoBom $receiptPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 5 GDELT BATCH TIMING VALIDATION: PASS'
    Write-Host "V6 rows / matched assets / distinct records: $($newsRows.Count) / $($matchedAssets.Count) / $($recordIds.Count)"
    Write-Host "Record/archive mismatches: $recordArchiveMismatch"
    Write-Host "Misaligned batch timestamps: $misalignedBatch"
    Write-Host "Batch timestamps not on downloaded slots: $batchNotDownloaded"
    Write-Host "gdelt_date_utc equals / differs from batch: $dateEqualsBatch / $dateDiffersBatch"
    Write-Host "gdelt_date_utc - batch seconds min / max: $deltaMin / $deltaMax"
    Write-Host "24h lag15 complete response days: $complete24Days / $($responseDays.Count)"
    Write-Host "24h lag15 available / source-incomplete / outside-population response rows: $rows24Available / $rows24Incomplete / $rows24Outside"
    Write-Host "6h lag15 complete response days: $complete6Days / $($responseDays.Count)"
    Write-Host "6h lag15 available / source-incomplete / outside-population response rows: $rows6Available / $rows6Incomplete / $rows6Outside"
    Write-Host 'CFA-S5-013 V6 batch-timestamp reconciliation: PASS'
    Write-Host 'CFA-S5-011 historical information-availability policy: PASS'
    Write-Host 'CFA-S5-007 news factor definitions: UNVERIFIED'
    Write-Host "Validation receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 GDELT BATCH TIMING VALIDATION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
