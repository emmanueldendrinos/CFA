#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V6MatchesPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$PgHost='localhost',
    [ValidateRange(1,65535)][int]$PgPort=5432,
    [string]$PgUser='postgres',
    [string]$DatabaseName='cfa',
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [ValidateRange(30,900)][int]$StatementTimeoutSeconds=180,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$Invariant=[Globalization.CultureInfo]::InvariantCulture
$ExpectedContractSha='11f3d81f61533efd0b1984c8f84da3e68128c05142923f4e7a62a76c8de9002e'
$ExpectedContractStart=[datetime]::SpecifyKind([datetime]::ParseExact('2025-04-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)
$ExpectedContractEnd=[datetime]::SpecifyKind([datetime]::ParseExact('2025-07-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)
# PS51_NATIVE_PSQL_QUOTE_SAFE_EPOCH_SERIALIZATION: avoid embedded SQL double-quoted literals across Windows PowerShell native argument binding.
$ExpectedContractStartEpoch=1743465600L
$ExpectedContractEndEpoch=1751328000L
$ExpectedSlots=8736
$ExpectedDownloaded=7163
$ExpectedProviderMissing=1573
$ExpectedCadenceMinutes=15
$ExpectedStage3Matches=22060
$ExpectedStage3MatchedAssets=282
$ExpectedStage3DistinctRecords=18503
$ExpectedStage3NewsAssets=431
$ExpectedStage4Rows=37058
$ExpectedStage4Bases=434
$ExpectedResponseId='RET_USD_UTC_DAY_OBS_LOG'
$ExpectedStage4Sha='8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedAliasSha='11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'

function Find-Psql {
    $cmd=Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if($null-ne$cmd){return $cmd.Source}
    $found=@(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    if($found.Count-eq0){throw 'psql.exe could not be found.'}
    return $found[0].FullName
}

function Invoke-PsqlText {
    param([string]$PsqlExe,[string]$Database,[string]$Sql)
    $errFile=[IO.Path]::GetTempFileName()
    try {
        $stdout=@(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2> $errFile)
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
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

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

function Parse-GdeltUtc {
    param([object]$Value,[string]$Label)
    $text=([string]$Value).Trim()
    if($text-notmatch'^\d{14}$'){throw "Malformed GDELT timestamp for ${Label}: '$Value'"}
    $dt=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($text,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$dt)){throw "Unparseable GDELT timestamp for ${Label}: '$Value'"}
    return [datetime]::SpecifyKind($dt,[DateTimeKind]::Utc)
}

function Measure-Window {
    param([datetime]$CutoffUtc,[int]$Hours,[hashtable]$SlotByKey)
    $expected=[int](($Hours*60)/$ExpectedCadenceMinutes)
    $start=$CutoffUtc.AddHours(-$Hours)
    [int]$downloaded=0;[int]$providerMissing=0;[int]$outside=0;[int]$registryMissing=0;[int]$other=0
    for($i=0;$i-lt$expected;$i++){
        $slot=$start.AddMinutes($i*$ExpectedCadenceMinutes)
        if($slot-lt$ExpectedContractStart-or$slot-ge$ExpectedContractEnd){$outside++;continue}
        $key=$slot.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$SlotByKey.ContainsKey($key)){$registryMissing++;continue}
        $status=[string]$SlotByKey[$key].status
        if($status-eq'downloaded'){$downloaded++}
        elseif($status-eq'provider_missing'){$providerMissing++}
        else{$other++}
    }
    $complete=($downloaded-eq$expected-and$providerMissing-eq0-and$outside-eq0-and$registryMissing-eq0-and$other-eq0)
    return [pscustomobject]@{hours=$Hours;expected_slots=$expected;downloaded_slots=$downloaded;provider_missing_slots=$providerMissing;outside_contract_slots=$outside;registry_missing_slots=$registryMissing;other_status_slots=$other;complete=$complete}
}

function Invoke-SelfTest {
    $slotByKey=@{}
    $start=[datetime]::SpecifyKind([datetime]::ParseExact('2025-04-01 00:00:00','yyyy-MM-dd HH:mm:ss',$Invariant),[DateTimeKind]::Utc)
    for($i=0;$i-lt96;$i++){$t=$start.AddMinutes(15*$i);$slotByKey[$t.ToString('yyyyMMddHHmmss',$Invariant)]=[pscustomobject]@{status='downloaded'}}
    $cutoff=$start.AddDays(1)
    $w=Measure-Window $cutoff 24 $slotByKey
    if(-not[bool]$w.complete-or[int]$w.downloaded_slots-ne96){throw 'Complete 24h window self-test failed.'}
    $slotByKey[$start.AddHours(12).ToString('yyyyMMddHHmmss',$Invariant)]=[pscustomobject]@{status='provider_missing'}
    $w=Measure-Window $cutoff 24 $slotByKey
    if([bool]$w.complete-or[int]$w.provider_missing_slots-ne1){throw 'Provider-missing window self-test failed.'}
    $d=Parse-GdeltUtc '20250401001500' 'selftest'
    if($d.ToString('yyyy-MM-ddTHH:mm:ssZ',$Invariant)-ne'2025-04-01T00:15:00Z'){throw 'GDELT timestamp self-test failed.'}
    if($ExpectedContractStartEpoch-ne1743465600L-or$ExpectedContractEndEpoch-ne1751328000L){throw 'Contract epoch self-test failed.'}
    if(($ExpectedContractEndEpoch-$ExpectedContractStartEpoch)-ne7862400L){throw 'Contract epoch span self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

$oldPassword=$env:PGPASSWORD
$oldPgOptions=$env:PGOPTIONS
$bstr=[IntPtr]::Zero
try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $Stage3V6MatchesPath=(Resolve-Path -LiteralPath $Stage3V6MatchesPath).ProviderPath
    $Stage4ResponsesPath=(Resolve-Path -LiteralPath $Stage4ResponsesPath).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage5-news-window-coverage'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null

    $contractText=Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage5-factor-contract.md') -Raw
    foreach($marker in @('CFA-S5-002','CFA-S5-003','CFA-S5-004','CFA-S5-005','CFA-S5-006')){
        if($contractText-notmatch([regex]::Escape($marker)+'[^\r\n]*PASS')){throw "Stage 5 prerequisite is not PASS: $marker"}
    }
    if($contractText-notmatch'CFA-S5-010[^\r\n]*UNVERIFIED'){throw 'CFA-S5-010 is not UNVERIFIED in the current contract.'}

    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if((Get-Sha $aliasPath)-ne$ExpectedAliasSha){throw 'Stage 3 alias registry SHA-256 mismatch.'}
    $aliasRows=@(Import-Csv -LiteralPath $aliasPath)
    $newsPopulation=@($aliasRows|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($newsPopulation.Count-ne$ExpectedStage3NewsAssets){throw "Stage 3 news population changed: $($newsPopulation.Count)."}

    if((Get-Sha $Stage4ResponsesPath)-ne$ExpectedStage4Sha){throw 'Stage 4 response CSV SHA-256 mismatch.'}
    $responses=@(Import-Csv -LiteralPath $Stage4ResponsesPath)
    if($responses.Count-ne$ExpectedStage4Rows){throw "Stage 4 response row count changed: $($responses.Count)."}
    Require-Columns $responses[0] @('response_id','base_asset_id','response_day_utc','predictor_cutoff_utc') 'Stage 4 responses'
    $responseIds=@($responses|Select-Object -ExpandProperty response_id -Unique)
    if($responseIds.Count-ne1-or[string]$responseIds[0]-ne$ExpectedResponseId){throw 'Stage 4 response identity changed.'}
    $responseBases=@($responses|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($responseBases.Count-ne$ExpectedStage4Bases){throw "Stage 4 response base count changed: $($responseBases.Count)."}

    $stage3SummaryPath=Join-Path (Split-Path -Parent $Stage3V6MatchesPath) 'stage3-match-summary.json'
    if(-not(Test-Path -LiteralPath $stage3SummaryPath -PathType Leaf)){throw 'Stage 3 V6 sibling summary is missing.'}
    $stage3Summary=Get-Content -LiteralPath $stage3SummaryPath -Raw|ConvertFrom-Json
    if([string]$stage3Summary.run_status-ne'PASS'-or[string]$stage3Summary.matching_contract-ne'CANDIDATE_V6'){throw 'Stage 3 sibling summary is not PASS CANDIDATE_V6.'}
    $stage3MatchSha=Get-Sha $Stage3V6MatchesPath
    if($stage3MatchSha-ne([string]$stage3Summary.output.matches_sha256).ToLowerInvariant()){throw 'Stage 3 V6 match hash mismatch.'}
    $newsRows=@(Import-Csv -LiteralPath $Stage3V6MatchesPath)
    if($newsRows.Count-ne$ExpectedStage3Matches){throw "Stage 3 V6 match rows changed: $($newsRows.Count)."}
    Require-Columns $newsRows[0] @('base_asset_id','record_id','gdelt_date_utc','source_common_name','archive_file','row_ordinal') 'Stage 3 V6 matches'
    $assetRecordKeys=New-Object 'Collections.Generic.HashSet[string]'
    $matchedAssets=New-Object 'Collections.Generic.HashSet[string]'
    $recordIds=New-Object 'Collections.Generic.HashSet[string]'
    foreach($row in $newsRows){
        $key=([string]$row.base_asset_id)+'|'+([string]$row.record_id)
        if(-not$assetRecordKeys.Add($key)){throw "Duplicate V6 asset/record: $key"}
        [void]$matchedAssets.Add([string]$row.base_asset_id)
        [void]$recordIds.Add([string]$row.record_id)
    }
    if($matchedAssets.Count-ne$ExpectedStage3MatchedAssets-or$recordIds.Count-ne$ExpectedStage3DistinctRecords){throw 'Stage 3 V6 distinct counts changed.'}

    $psql=Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    $securePassword=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000) -c TimeZone=UTC"
    $version=Invoke-PsqlText -PsqlExe $psql -Database $DatabaseName -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $contractCsv=Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT contract_sha256,source_product,
       extract(epoch FROM interval_start_utc)::bigint AS interval_start_epoch,
       extract(epoch FROM interval_end_exclusive_utc)::bigint AS interval_end_exclusive_epoch,
       cadence_minutes,nominal_slot_count
FROM source_news.source_contracts
WHERE contract_sha256='$ExpectedContractSha'
"@
    $contracts=@($contractCsv|ConvertFrom-Csv)
    if($contracts.Count-ne1){throw "Expected one frozen GDELT source contract; observed $($contracts.Count)."}
    $contract=$contracts[0]
    if([int]$contract.cadence_minutes-ne$ExpectedCadenceMinutes-or[int]$contract.nominal_slot_count-ne$ExpectedSlots){throw 'Frozen GDELT contract cadence/slot count changed.'}
    if([long]$contract.interval_start_epoch-ne$ExpectedContractStartEpoch-or[long]$contract.interval_end_exclusive_epoch-ne$ExpectedContractEndEpoch){throw "Frozen GDELT contract interval changed: start_epoch=$($contract.interval_start_epoch) end_epoch=$($contract.interval_end_exclusive_epoch)."}

    $slotCsv=Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT object_key,
       to_char(archive_timestamp_utc AT TIME ZONE 'UTC','YYYYMMDDHH24MISS') AS slot_key,
       status,http_status,payload_sha256
FROM source_news.source_slots
WHERE contract_sha256='$ExpectedContractSha'
ORDER BY archive_timestamp_utc
"@
    $slotPath=Join-Path $runDir 'stage5-news-source-slots.csv'
    Write-Utf8NoBom $slotPath ($slotCsv+[Environment]::NewLine)
    $slots=@($slotCsv|ConvertFrom-Csv)
    if($slots.Count-ne$ExpectedSlots){throw "Frozen GDELT source slot count changed: $($slots.Count)."}
    $slotByKey=@{}
    [int]$downloadedCount=0;[int]$providerMissingCount=0;[int]$otherCount=0
    foreach($slot in $slots){
        $key=([string]$slot.slot_key).Trim()
        if($key-notmatch'^\d{14}$'){throw "Malformed source slot key: $key"}
        if($slotByKey.ContainsKey($key)){throw "Duplicate source slot key: $key"}
        $slotByKey[$key]=$slot
        $status=[string]$slot.status
        if($status-eq'downloaded'){
            $downloadedCount++
            if([string]::IsNullOrWhiteSpace([string]$slot.payload_sha256)){throw "Downloaded source slot missing payload SHA-256: $key"}
        }
        elseif($status-eq'provider_missing'){
            $providerMissingCount++
            if([string]$slot.http_status-ne'404'){throw "Provider-missing source slot is not HTTP 404: $key"}
        }
        else{$otherCount++}
    }
    if($downloadedCount-ne$ExpectedDownloaded-or$providerMissingCount-ne$ExpectedProviderMissing-or$otherCount-ne0){throw "Source slot status accounting changed: downloaded=$downloadedCount provider_missing=$providerMissingCount other=$otherCount"}

    [int]$matchNotDownloaded=0;[int]$misalignedMatchTimes=0
    foreach($row in $newsRows){
        $dt=Parse-GdeltUtc $row.gdelt_date_utc "record $($row.record_id)"
        if(($dt.Minute%15)-ne0-or$dt.Second-ne0){$misalignedMatchTimes++}
        $key=$dt.ToString('yyyyMMddHHmmss',$Invariant)
        if(-not$slotByKey.ContainsKey($key)-or[string]$slotByKey[$key].status-ne'downloaded'){$matchNotDownloaded++}
    }
    if($matchNotDownloaded-ne0){throw "V6 matches not mapping to downloaded source slots: $matchNotDownloaded"}
    if($misalignedMatchTimes-ne0){throw "V6 match timestamps not aligned to 15-minute source cadence: $misalignedMatchTimes"}

    $blankSourceNames=@($newsRows|Where-Object{[string]::IsNullOrWhiteSpace([string]$_.source_common_name)}).Count
    $distinctNonblankSources=@($newsRows|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_.source_common_name)}|Select-Object -ExpandProperty source_common_name -Unique).Count

    $responseDays=@($responses|Select-Object -ExpandProperty response_day_utc -Unique|Sort-Object)
    $dayRows=New-Object System.Collections.ArrayList
    [long]$rows24Available=0;[long]$rows24SourceIncomplete=0;[long]$rows24OutsidePopulation=0
    [long]$rows6Available=0;[long]$rows6SourceIncomplete=0;[long]$rows6OutsidePopulation=0
    [int]$complete24Days=0;[int]$complete6Days=0
    foreach($dayText in $responseDays){
        $day=[datetime]::SpecifyKind([datetime]::ParseExact([string]$dayText,'yyyy-MM-dd',$Invariant),[DateTimeKind]::Utc)
        $w24=Measure-Window $day 24 $slotByKey
        $w6=Measure-Window $day 6 $slotByKey
        if([bool]$w24.complete){$complete24Days++}
        if([bool]$w6.complete){$complete6Days++}
        $rowsForDay=@($responses|Where-Object{[string]$_.response_day_utc-eq[string]$dayText})
        $inPop=0;$outsidePop=0
        foreach($r in $rowsForDay){
            if($newsPopulation-contains[string]$r.base_asset_id){$inPop++}else{$outsidePop++}
        }
        $rows24OutsidePopulation+=$outsidePop
        $rows6OutsidePopulation+=$outsidePop
        if([bool]$w24.complete){$rows24Available+=$inPop}else{$rows24SourceIncomplete+=$inPop}
        if([bool]$w6.complete){$rows6Available+=$inPop}else{$rows6SourceIncomplete+=$inPop}
        [void]$dayRows.Add([pscustomobject][ordered]@{
            response_day_utc=[string]$dayText
            response_rows=$rowsForDay.Count
            response_rows_in_news_population=$inPop
            response_rows_outside_news_population=$outsidePop
            window_24h_complete=[bool]$w24.complete
            window_24h_expected_slots=[int]$w24.expected_slots
            window_24h_downloaded_slots=[int]$w24.downloaded_slots
            window_24h_provider_missing_slots=[int]$w24.provider_missing_slots
            window_24h_outside_contract_slots=[int]$w24.outside_contract_slots
            window_24h_registry_missing_slots=[int]$w24.registry_missing_slots
            window_24h_other_status_slots=[int]$w24.other_status_slots
            window_6h_complete=[bool]$w6.complete
            window_6h_expected_slots=[int]$w6.expected_slots
            window_6h_downloaded_slots=[int]$w6.downloaded_slots
            window_6h_provider_missing_slots=[int]$w6.provider_missing_slots
            window_6h_outside_contract_slots=[int]$w6.outside_contract_slots
            window_6h_registry_missing_slots=[int]$w6.registry_missing_slots
            window_6h_other_status_slots=[int]$w6.other_status_slots
        })
    }
    if(($rows24Available+$rows24SourceIncomplete+$rows24OutsidePopulation)-ne$ExpectedStage4Rows){throw '24h response-row availability accounting does not reconcile.'}
    if(($rows6Available+$rows6SourceIncomplete+$rows6OutsidePopulation)-ne$ExpectedStage4Rows){throw '6h response-row availability accounting does not reconcile.'}

    $dayPath=Join-Path $runDir 'stage5-news-window-coverage-by-day.csv'
    @($dayRows.ToArray())|Export-Csv -LiteralPath $dayPath -NoTypeInformation -Encoding UTF8
    $sourceNamePath=Join-Path $runDir 'stage5-news-source-name-summary.csv'
    @([pscustomobject][ordered]@{v6_match_rows=$newsRows.Count;blank_source_common_name_rows=$blankSourceNames;distinct_nonblank_source_common_names=$distinctNonblankSources})|Export-Csv -LiteralPath $sourceNamePath -NoTypeInformation -Encoding UTF8

    $complete24=@($dayRows|Where-Object{[bool]$_.window_24h_complete}|Select-Object -ExpandProperty response_day_utc)
    $complete6=@($dayRows|Where-Object{[bool]$_.window_6h_complete}|Select-Object -ExpandProperty response_day_utc)
    $summary=[ordered]@{
        status='PASS'
        stage='CFA_STAGE_5'
        source_contract=[ordered]@{contract_sha256=$ExpectedContractSha;interval_start_utc='2025-04-01T00:00:00Z';interval_end_exclusive_utc='2025-07-01T00:00:00Z';cadence_minutes=15;nominal_slots=$slots.Count;downloaded_slots=$downloadedCount;provider_missing_slots=$providerMissingCount;other_status_slots=$otherCount}
        stage3=[ordered]@{matches_sha256=$stage3MatchSha;match_rows=$newsRows.Count;matched_assets=$matchedAssets.Count;distinct_records=$recordIds.Count;matches_not_on_downloaded_slot=$matchNotDownloaded;misaligned_match_timestamps=$misalignedMatchTimes;blank_source_common_name_rows=$blankSourceNames;distinct_nonblank_source_common_names=$distinctNonblankSources}
        population=[ordered]@{response_rows=$responses.Count;response_bases=$responseBases.Count;news_population_assets=$newsPopulation.Count;response_only_assets=@($responseBases|Where-Object{$newsPopulation-notcontains$_})}
        window_24h=[ordered]@{response_days=$responseDays.Count;complete_response_days=$complete24Days;complete_days=@($complete24);available_in_population_response_rows=$rows24Available;source_incomplete_in_population_response_rows=$rows24SourceIncomplete;outside_news_population_response_rows=$rows24OutsidePopulation}
        window_6h=[ordered]@{response_days=$responseDays.Count;complete_response_days=$complete6Days;complete_days=@($complete6);available_in_population_response_rows=$rows6Available;source_incomplete_in_population_response_rows=$rows6SourceIncomplete;outside_news_population_response_rows=$rows6OutsidePopulation}
        outputs=[ordered]@{source_slots_csv=$slotPath;window_coverage_by_day_csv=$dayPath;source_name_summary_csv=$sourceNamePath}
        gates=[ordered]@{'CFA-S5-010'='PASS';'CFA-S5-007'='UNVERIFIED';'CFA-S5-008'='BLOCKED';'CFA-S5-009'='BLOCKED'}
        next_action='Define exact news-hype factors using only response rows inside the 431-asset news population and lookback windows with complete downloaded source slots. Incomplete or outside-population windows remain NULL, never zero.'
    }
    $receiptPath=Join-Path $runDir 'stage5-news-window-coverage.json'
    Write-Utf8NoBom $receiptPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 5 NEWS WINDOW COVERAGE DIAGNOSTIC: PASS'
    Write-Host "Source slots: $($slots.Count)"
    Write-Host "Downloaded / provider-missing: $downloadedCount / $providerMissingCount"
    Write-Host "V6 matches mapped to downloaded slots: $($newsRows.Count)"
    Write-Host "Blank source_common_name rows: $blankSourceNames"
    Write-Host "Distinct nonblank source_common_name values: $distinctNonblankSources"
    Write-Host "24h complete response days: $complete24Days / $($responseDays.Count)"
    Write-Host "24h available / source-incomplete / outside-population response rows: $rows24Available / $rows24SourceIncomplete / $rows24OutsidePopulation"
    Write-Host "6h complete response days: $complete6Days / $($responseDays.Count)"
    Write-Host "6h available / source-incomplete / outside-population response rows: $rows6Available / $rows6SourceIncomplete / $rows6OutsidePopulation"
    Write-Host 'CFA-S5-010 news source-slot lookback coverage: PASS'
    Write-Host 'CFA-S5-007 news factor definitions: UNVERIFIED'
    Write-Host "Diagnostic receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 NEWS WINDOW COVERAGE DIAGNOSTIC: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
finally {
    if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    if($null-eq$oldPassword){Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$oldPassword}
    if($null-eq$oldPgOptions){Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue}else{$env:PGOPTIONS=$oldPgOptions}
}