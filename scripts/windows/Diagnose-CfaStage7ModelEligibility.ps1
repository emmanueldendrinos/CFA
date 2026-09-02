#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage6ValidationReceiptPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage6ReceiptSha='5c8fd64d367af847ea1efa25e34cddca05239186282c6d97a4ca70de104a3089'
$ExpectedStage4Sha='8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedFactorSha='c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b'
$ExpectedRows=37058
$ExpectedBases=434
$ExpectedDays=91
$FactorIds=@(
    'MKT_RET_USD_UTC_DAY_OBS_L1',
    'MKT_RANGE_LOG_UTC_DAY_L1',
    'MKT_OBS_COUNT_UTC_DAY_L1',
    'MKT_OBS_SPAN_MIN_UTC_DAY_L1',
    'NEWS_V6_MATCH_COUNT_24H_LAG15',
    'NEWS_V6_MATCH_COUNT_6H_LAG15',
    'NEWS_V6_SOURCE_COUNT_24H_LAG15'
)

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Require-File {
    param([string]$Path,[string]$Label)
    $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"}
    return $resolved
}

function Require-Columns {
    param([object]$Row,[string[]]$Names,[string]$Label)
    $props=@($Row.PSObject.Properties.Name)
    foreach($name in $Names){if($props -notcontains $name){throw "$Label required column missing: $name"}}
}

function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $n=0.0
    if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"}
    if([double]::IsNaN($n)-or[double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"}
    return $n
}

function New-Stat {
    return [pscustomobject]@{
        count=[long]0
        sum=[double]0
        sumsq=[double]0
        min=$null
        max=$null
        unique=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
    }
}

function Add-Stat {
    param([object]$Stat,[double]$Value,[string]$Text)
    $Stat.count=[long]$Stat.count+1
    $Stat.sum=[double]$Stat.sum+$Value
    $Stat.sumsq=[double]$Stat.sumsq+($Value*$Value)
    if($null-eq$Stat.min-or$Value-lt[double]$Stat.min){$Stat.min=$Value}
    if($null-eq$Stat.max-or$Value-gt[double]$Stat.max){$Stat.max=$Value}
    [void]$Stat.unique.Add($Text)
}

function Stat-Row {
    param([string]$Name,[object]$Stat)
    if([long]$Stat.count-lt1){throw "No complete-case observations for $Name"}
    $mean=[double]$Stat.sum/[long]$Stat.count
    $sd=0.0
    if([long]$Stat.count-gt1){
        $numerator=[double]$Stat.sumsq-([long]$Stat.count*$mean*$mean)
        if($numerator-lt0-and[math]::Abs($numerator)-lt1e-10){$numerator=0.0}
        if($numerator-lt0){throw "Negative sample-variance numerator for $Name"}
        $sd=[math]::Sqrt($numerator/([long]$Stat.count-1))
    }
    return [pscustomobject][ordered]@{
        variable=$Name
        count=[long]$Stat.count
        unique_count=$Stat.unique.Count
        min=([double]$Stat.min).ToString('R',$Invariant)
        max=([double]$Stat.max).ToString('R',$Invariant)
        mean=$mean.ToString('R',$Invariant)
        sample_sd=$sd.ToString('R',$Invariant)
    }
}

function Invoke-SelfTest {
    $s=New-Stat
    Add-Stat $s 1.0 '1'
    Add-Stat $s 2.0 '2'
    Add-Stat $s 3.0 '3'
    $r=Stat-Row 'x' $s
    if([long]$r.count-ne3-or[int]$r.unique_count-ne3){throw 'Stat count self-test failed.'}
    if([math]::Abs(([double]::Parse($r.mean,$Invariant))-2.0)-gt1e-12){throw 'Stat mean self-test failed.'}
    if([math]::Abs(([double]::Parse($r.sample_sd,$Invariant))-1.0)-gt1e-12){throw 'Stat SD self-test failed.'}
    $days=@('2025-04-01','2025-04-02','2025-04-03')
    $rows=@(
        [pscustomobject]@{response_day_utc='2025-04-01';base_asset_id='A'},
        [pscustomobject]@{response_day_utc='2025-04-02';base_asset_id='A'},
        [pscustomobject]@{response_day_utc='2025-04-02';base_asset_id='B'},
        [pscustomobject]@{response_day_utc='2025-04-03';base_asset_id='B'}
    )
    $cut=$days[1]
    $train=@($rows|Where-Object{$_.response_day_utc-cmp$cut -lt 0})
    $test=@($rows|Where-Object{$_.response_day_utc-cmp$cut -ge 0})
    if($train.Count-ne1-or$test.Count-ne3){throw 'Chronological split self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $contractPath=Require-File (Join-Path $RepoRoot 'docs\evidence\stage7-model-ready-contract.md') 'Stage 7 contract'
    $contract=Get-Content -LiteralPath $contractPath -Raw
    foreach($marker in @('STAGE7_ACTIVE','CFA-S7-001','CFA-S7-002','MODEL_ELIGIBILITY_UNVERIFIED')){if($contract-notmatch[regex]::Escape($marker)){throw "Stage 7 contract marker missing: $marker"}}

    $Stage6ValidationReceiptPath=Require-File $Stage6ValidationReceiptPath 'Stage 6 validation receipt'
    if((Get-Sha $Stage6ValidationReceiptPath)-ne$ExpectedStage6ReceiptSha){throw 'Stage 6 validation receipt SHA-256 mismatch.'}
    $s6=Get-Content -LiteralPath $Stage6ValidationReceiptPath -Raw|ConvertFrom-Json
    if([string]$s6.status-ne'PASS'-or[string]$s6.stage-ne'CFA_STAGE_6'-or[string]$s6.validation-ne'DATA_QUALITY_LEAKAGE_V1'){throw 'Stage 6 validation receipt identity/status mismatch.'}
    foreach($i in 1..8){$id=('CFA-S6-{0:D3}' -f $i);if([string]$s6.gates.$id-ne'PASS'){throw "Stage 6 prerequisite gate is not PASS: $id"}}
    if([long]$s6.violations.count-ne0){throw 'Stage 6 receipt contains blocking violations.'}
    if([long]$s6.cardinality.rows-ne$ExpectedRows-or[int]$s6.cardinality.bases-ne$ExpectedBases-or[int]$s6.cardinality.days-ne$ExpectedDays){throw 'Stage 6 receipt cardinality mismatch.'}
    if([string]$s6.sources.stage4_responses_sha256-ne$ExpectedStage4Sha-or[string]$s6.sources.factor_csv_sha256-ne$ExpectedFactorSha){throw 'Stage 6 frozen source hash mismatch.'}

    $responsePath=Require-File ([string]$s6.sources.stage4_responses_path) 'Frozen Stage 4 responses'
    $factorPath=Require-File ([string]$s6.sources.factor_csv) 'Frozen Stage 5 factors'
    if((Get-Sha $responsePath)-ne$ExpectedStage4Sha){throw 'Frozen Stage 4 response hash mismatch.'}
    if((Get-Sha $factorPath)-ne$ExpectedFactorSha){throw 'Frozen Stage 5 factor hash mismatch.'}

    $responses=@(Import-Csv -LiteralPath $responsePath)
    $factors=@(Import-Csv -LiteralPath $factorPath)
    if($responses.Count-ne$ExpectedRows-or$factors.Count-ne$ExpectedRows){throw "Row-count mismatch: responses=$($responses.Count) factors=$($factors.Count)"}
    Require-Columns $responses[0] @('base_asset_id','response_day_utc','predictor_cutoff_utc','response_value_log_return','pair_token_opaque','source_member_ordinal') 'Stage 4 responses'
    Require-Columns $factors[0] (@('base_asset_id','response_day_utc','market_missing_reason','news_24h_missing_reason','news_6h_missing_reason','news_population_status')+$FactorIds) 'Stage 5 factors'

    $responseByKey=@{}
    foreach($r in $responses){
        $key=([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc)
        if($responseByKey.ContainsKey($key)){throw "Duplicate Stage 4 key: $key"}
        $responseByKey[$key]=$r
    }

    $patterns=@{}
    $dayAgg=@{}
    $assetAgg=@{}
    $eligible=New-Object System.Collections.ArrayList
    $stats=@{response_value_log_return=(New-Stat)}
    foreach($id in $FactorIds){$stats[$id]=New-Stat}

    foreach($f in $factors){
        $base=[string]$f.base_asset_id
        $day=[string]$f.response_day_utc
        $key=$base+'|'+$day
        if(-not$responseByKey.ContainsKey($key)){throw "Factor key missing from responses: $key"}
        $r=$responseByKey[$key]
        $marketDefined=([string]$f.market_missing_reason-eq'NONE')
        $news24Defined=([string]$f.news_24h_missing_reason-eq'NONE')
        $news6Defined=([string]$f.news_6h_missing_reason-eq'NONE')
        $all7=($marketDefined-and$news24Defined-and$news6Defined)
        $pattern=([string]$f.market_missing_reason)+'|'+([string]$f.news_24h_missing_reason)+'|'+([string]$f.news_6h_missing_reason)+'|'+([string]$f.news_population_status)
        if(-not$patterns.ContainsKey($pattern)){$patterns[$pattern]=[pscustomobject]@{rows=[long]0;bases=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal));days=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))}}
        $patterns[$pattern].rows=[long]$patterns[$pattern].rows+1
        [void]$patterns[$pattern].bases.Add($base);[void]$patterns[$pattern].days.Add($day)

        if(-not$dayAgg.ContainsKey($day)){$dayAgg[$day]=[pscustomobject]@{response_rows=[long]0;market_available=[long]0;news24_available=[long]0;news6_available=[long]0;all7_eligible=[long]0;eligible_bases=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))}}
        $dayAgg[$day].response_rows=[long]$dayAgg[$day].response_rows+1
        if($marketDefined){$dayAgg[$day].market_available=[long]$dayAgg[$day].market_available+1}
        if($news24Defined){$dayAgg[$day].news24_available=[long]$dayAgg[$day].news24_available+1}
        if($news6Defined){$dayAgg[$day].news6_available=[long]$dayAgg[$day].news6_available+1}

        if(-not$assetAgg.ContainsKey($base)){$assetAgg[$base]=[pscustomobject]@{response_days=[long]0;all7_days=[long]0;first_all7='';last_all7=''}}
        $assetAgg[$base].response_days=[long]$assetAgg[$base].response_days+1

        if($all7){
            $dayAgg[$day].all7_eligible=[long]$dayAgg[$day].all7_eligible+1
            [void]$dayAgg[$day].eligible_bases.Add($base)
            $assetAgg[$base].all7_days=[long]$assetAgg[$base].all7_days+1
            if([string]::IsNullOrWhiteSpace([string]$assetAgg[$base].first_all7)-or[string]::CompareOrdinal($day,[string]$assetAgg[$base].first_all7)-lt0){$assetAgg[$base].first_all7=$day}
            if([string]::IsNullOrWhiteSpace([string]$assetAgg[$base].last_all7)-or[string]::CompareOrdinal($day,[string]$assetAgg[$base].last_all7)-gt0){$assetAgg[$base].last_all7=$day}
            [void]$eligible.Add([pscustomobject][ordered]@{base_asset_id=$base;response_day_utc=$day;pair_token_opaque=$r.pair_token_opaque;source_member_ordinal=$r.source_member_ordinal})
            $rv=Parse-DoubleStrict $r.response_value_log_return "$key response"
            Add-Stat $stats.response_value_log_return $rv ([string]$r.response_value_log_return)
            foreach($id in $FactorIds){
                $prop=$f.PSObject.Properties[$id]
                if($null-eq$prop-or[string]::IsNullOrWhiteSpace([string]$prop.Value)){throw "All-seven eligible row has blank factor: $key $id"}
                $v=Parse-DoubleStrict $prop.Value "$key $id"
                Add-Stat $stats[$id] $v ([string]$prop.Value)
            }
        }
    }

    if($responseByKey.Count-ne$factors.Count){throw 'Response/factor key cardinality mismatch.'}
    $eligibleRows=@($eligible.ToArray()|Sort-Object response_day_utc,base_asset_id)
    if($eligibleRows.Count-lt1){throw 'No all-seven-eligible rows observed.'}
    $eligibleBases=@($eligibleRows|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    $eligibleDays=@($eligibleRows|Select-Object -ExpandProperty response_day_utc -Unique|Sort-Object)

    $patternRows=New-Object System.Collections.ArrayList
    foreach($p in @($patterns.Keys|Sort-Object)){
        $x=$patterns[$p]
        [void]$patternRows.Add([pscustomobject][ordered]@{pattern=$p;rows=[long]$x.rows;distinct_bases=$x.bases.Count;distinct_days=$x.days.Count})
    }

    $dayRows=New-Object System.Collections.ArrayList
    foreach($day in @($dayAgg.Keys|Sort-Object)){
        $x=$dayAgg[$day]
        [void]$dayRows.Add([pscustomobject][ordered]@{response_day_utc=$day;response_rows=[long]$x.response_rows;market_available_rows=[long]$x.market_available;news24_available_rows=[long]$x.news24_available;news6_available_rows=[long]$x.news6_available;all7_eligible_rows=[long]$x.all7_eligible;all7_distinct_bases=$x.eligible_bases.Count})
    }

    $assetRows=New-Object System.Collections.ArrayList
    foreach($base in @($assetAgg.Keys|Sort-Object)){
        $x=$assetAgg[$base]
        [void]$assetRows.Add([pscustomobject][ordered]@{base_asset_id=$base;response_days=[long]$x.response_days;all7_eligible_days=[long]$x.all7_days;first_all7_eligible_day=[string]$x.first_all7;last_all7_eligible_day=[string]$x.last_all7})
    }

    $diagRows=New-Object System.Collections.ArrayList
    foreach($name in @('response_value_log_return')+$FactorIds){[void]$diagRows.Add((Stat-Row $name $stats[$name]))}

    $splitRows=New-Object System.Collections.ArrayList
    for($i=1;$i-lt$eligibleDays.Count;$i++){
        $cut=[string]$eligibleDays[$i]
        $train=@($eligibleRows|Where-Object{[string]::CompareOrdinal([string]$_.response_day_utc,$cut)-lt0})
        $test=@($eligibleRows|Where-Object{[string]::CompareOrdinal([string]$_.response_day_utc,$cut)-ge0})
        $trainDays=@($train|Select-Object -ExpandProperty response_day_utc -Unique|Sort-Object)
        $testDays=@($test|Select-Object -ExpandProperty response_day_utc -Unique|Sort-Object)
        $trainAssets=@($train|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
        $testAssets=@($test|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
        $trainSet=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($a in $trainAssets){[void]$trainSet.Add([string]$a)}
        $overlap=0
        foreach($a in $testAssets){if($trainSet.Contains([string]$a)){$overlap++}}
        [void]$splitRows.Add([pscustomobject][ordered]@{
            test_start_day=$cut
            train_start_day=$trainDays[0]
            train_end_day=$trainDays[$trainDays.Count-1]
            test_end_day=$testDays[$testDays.Count-1]
            train_days=$trainDays.Count
            test_days=$testDays.Count
            train_rows=$train.Count
            test_rows=$test.Count
            train_distinct_bases=$trainAssets.Count
            test_distinct_bases=$testAssets.Count
            base_overlap_count=$overlap
        })
    }

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage7-model-eligibility'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $patternsPath=Join-Path $runDir 'stage7-availability-patterns.csv'
    $daysPath=Join-Path $runDir 'stage7-eligibility-by-day.csv'
    $assetsPath=Join-Path $runDir 'stage7-eligibility-by-asset.csv'
    $eligiblePath=Join-Path $runDir 'stage7-all-seven-eligible-keys.csv'
    $diagPath=Join-Path $runDir 'stage7-complete-case-variable-diagnostics.csv'
    $splitPath=Join-Path $runDir 'stage7-chronological-split-candidates.csv'
    @($patternRows.ToArray())|Export-Csv -LiteralPath $patternsPath -NoTypeInformation -Encoding UTF8
    @($dayRows.ToArray())|Export-Csv -LiteralPath $daysPath -NoTypeInformation -Encoding UTF8
    @($assetRows.ToArray())|Export-Csv -LiteralPath $assetsPath -NoTypeInformation -Encoding UTF8
    $eligibleRows|Export-Csv -LiteralPath $eligiblePath -NoTypeInformation -Encoding UTF8
    @($diagRows.ToArray())|Export-Csv -LiteralPath $diagPath -NoTypeInformation -Encoding UTF8
    @($splitRows.ToArray())|Export-Csv -LiteralPath $splitPath -NoTypeInformation -Encoding UTF8

    $receipt=[ordered]@{
        status='PASS';stage='CFA_STAGE_7';diagnostic='MODEL_ELIGIBILITY_V1';
        sources=[ordered]@{stage6_validation_receipt=$Stage6ValidationReceiptPath;stage6_validation_receipt_sha256=(Get-Sha $Stage6ValidationReceiptPath);stage4_responses=$responsePath;stage4_responses_sha256=(Get-Sha $responsePath);factor_csv=$factorPath;factor_csv_sha256=(Get-Sha $factorPath)};
        frozen_input_cardinality=[ordered]@{rows=$ExpectedRows;bases=$ExpectedBases;days=$ExpectedDays};
        all_seven_eligible=[ordered]@{rows=$eligibleRows.Count;bases=$eligibleBases.Count;days=$eligibleDays.Count;first_day=$eligibleDays[0];last_day=$eligibleDays[$eligibleDays.Count-1]};
        outputs=[ordered]@{
            availability_patterns=$patternsPath;availability_patterns_sha256=(Get-Sha $patternsPath);
            eligibility_by_day=$daysPath;eligibility_by_day_sha256=(Get-Sha $daysPath);
            eligibility_by_asset=$assetsPath;eligibility_by_asset_sha256=(Get-Sha $assetsPath);
            all_seven_eligible_keys=$eligiblePath;all_seven_eligible_keys_sha256=(Get-Sha $eligiblePath);
            variable_diagnostics=$diagPath;variable_diagnostics_sha256=(Get-Sha $diagPath);
            chronological_split_candidates=$splitPath;chronological_split_candidates_sha256=(Get-Sha $splitPath)
        };
        gates=[ordered]@{'CFA-S7-001'='PASS';'CFA-S7-002'='PASS';'CFA-S7-003'='UNVERIFIED';'CFA-S7-004'='BLOCKED';'CFA-S7-005'='BLOCKED';'CFA-S7-006'='BLOCKED';'CFA-S7-007'='BLOCKED';'CFA-S7-008'='BLOCKED'};
        next_action='Inspect eligibility/time-support diagnostics, then freeze model population, chronological split, preprocessing, and benchmark plan without using held-out response performance.'
    }
    $receiptPath=Join-Path $runDir 'stage7-model-eligibility.json'
    [IO.File]::WriteAllText($receiptPath,(($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host 'CFA STAGE 7 MODEL ELIGIBILITY DIAGNOSTIC: PASS'
    Write-Host "Frozen rows / bases / days: $ExpectedRows / $ExpectedBases / $ExpectedDays"
    Write-Host "All-seven eligible rows / bases / days: $($eligibleRows.Count) / $($eligibleBases.Count) / $($eligibleDays.Count)"
    Write-Host "All-seven eligible first / last day: $($eligibleDays[0]) / $($eligibleDays[$eligibleDays.Count-1])"
    Write-Host "Availability patterns: $($patternRows.Count)"
    Write-Host "Chronological split candidates: $($splitRows.Count)"
    Write-Host 'CFA-S7-001 frozen Stage 6 entry: PASS'
    Write-Host 'CFA-S7-002 model eligibility/time support: PASS'
    Write-Host 'CFA-S7-003 model population/matrix: UNVERIFIED'
    Write-Host "Availability patterns CSV: $patternsPath"
    Write-Host "Eligibility by day CSV: $daysPath"
    Write-Host "Eligibility by asset CSV: $assetsPath"
    Write-Host "All-seven eligible keys CSV: $eligiblePath"
    Write-Host "Variable diagnostics CSV: $diagPath"
    Write-Host "Chronological split candidates CSV: $splitPath"
    Write-Host "Diagnostic receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 7 MODEL ELIGIBILITY DIAGNOSTIC: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
