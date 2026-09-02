#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidateReceiptPath,
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
$ExpectedEligibleRows=27152
$ExpectedEligibleBases=418
$ExpectedEligibleDays=68
$ExpectedModelRows=26337
$ExpectedEmbargoRows=815
$ExpectedTrainRows=15648
$ExpectedValidationRows=5323
$ExpectedTestRows=5366
$ExpectedEmbargo1Rows=404
$ExpectedEmbargo2Rows=411
$ExpectedEmbargo1Day='2025-05-17'
$ExpectedEmbargo2Day='2025-05-31'
$ResponseId='RET_USD_UTC_DAY_OBS_LOG'
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
    if(-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"}
    if([double]::IsNaN($n) -or [double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"}
    return $n
}

function Parse-Day {
    param([object]$Value,[string]$Label)
    $d=[datetime]::MinValue
    if(-not [datetime]::TryParseExact(([string]$Value),'yyyy-MM-dd',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$d)){throw "Malformed day for ${Label}: '$Value'"}
    return [datetime]::SpecifyKind($d,[DateTimeKind]::Utc)
}

function Format-Utc {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)
}

function Get-MeanSd {
    param([double[]]$Values,[string]$Label)
    if($Values.Count -lt 2){throw "Too few observations for ${Label}: $($Values.Count)"}
    $sum=0.0
    foreach($v in $Values){$sum += $v}
    $mean=$sum/$Values.Count
    $ss=0.0
    foreach($v in $Values){$d=$v-$mean;$ss += ($d*$d)}
    $sd=[math]::Sqrt($ss/($Values.Count-1))
    if([double]::IsNaN($sd) -or [double]::IsInfinity($sd) -or $sd -le 0){throw "Non-positive/non-finite sample SD for $Label"}
    return [pscustomobject]@{n=$Values.Count;mean=$mean;sd=$sd}
}

function Nearly-Equal {
    param([double]$A,[double]$B,[double]$Tolerance=1e-12)
    $scale=[math]::Max(1.0,[math]::Max([math]::Abs($A),[math]::Abs($B)))
    return ([math]::Abs($A-$B) -le ($Tolerance*$scale))
}

function Get-DayRoles {
    param([string[]]$Days)
    if($Days.Count -ne 68){throw "Day-role rule requires exactly 68 eligible days; observed $($Days.Count)."}
    $map=@{}
    for($i=0;$i -lt $Days.Count;$i++){
        $index=$i+1
        if($index -le 40){$role='TRAIN'}
        elseif($index -eq 41){$role='EMBARGO_TRAIN_VALIDATION'}
        elseif($index -le 54){$role='VALIDATION'}
        elseif($index -eq 55){$role='EMBARGO_VALIDATION_TEST'}
        else{$role='TEST'}
        $map[$Days[$i]]=$role
    }
    return $map
}

function Invoke-SelfTest {
    $v=Get-MeanSd ([double[]](1.0,2.0,3.0)) 'selftest'
    if(-not (Nearly-Equal $v.mean 2.0) -or -not (Nearly-Equal $v.sd 1.0)){throw 'Mean/SD self-test failed.'}
    $days=1..68|ForEach-Object{('2025-01-{0:D2}' -f $_)}
    $roles=Get-DayRoles ([string[]]$days)
    $counts=@{}
    foreach($role in $roles.Values){if(-not $counts.ContainsKey($role)){$counts[$role]=0};$counts[$role]++}
    if($counts.TRAIN -ne 40 -or $counts.EMBARGO_TRAIN_VALIDATION -ne 1 -or $counts.VALIDATION -ne 13 -or $counts.EMBARGO_VALIDATION_TEST -ne 1 -or $counts.TEST -ne 13){throw 'Day-role self-test failed.'}
    $d=Parse-Day '2025-05-16' 'selftest day'
    if((Format-Utc $d.AddDays(1)) -ne '2025-05-17T00:00:00Z'){throw 'Response-availability self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $contractPath=Require-File (Join-Path $RepoRoot 'docs\evidence\stage7-model-ready-contract.md') 'Stage 7 contract'
    $contract=Get-Content -LiteralPath $contractPath -Raw
    foreach($marker in @('MODEL_READY_DATASET_PASS','CFA-S7-007','CFA-S7-008','40 TRAIN / 13 validation / 13 test','BENCH_PRIOR_MARKET_RETURN','sample standard deviation')){if($contract -notmatch [regex]::Escape($marker)){throw "Stage 7 contract marker missing: $marker"}}

    $CandidateReceiptPath=Require-File $CandidateReceiptPath 'Stage 7 candidate receipt'
    $candidateReceiptSha=Get-Sha $CandidateReceiptPath
    $receipt=Get-Content -LiteralPath $CandidateReceiptPath -Raw|ConvertFrom-Json
    if([string]$receipt.status -ne 'VALIDATION_CANDIDATE' -or [string]$receipt.stage -ne 'CFA_STAGE_7' -or [string]$receipt.design -ne 'MODEL_READY_V1'){throw 'Stage 7 candidate receipt identity/status mismatch.'}
    foreach($id in 1..7){$gate=('CFA-S7-{0:D3}' -f $id);if([string]$receipt.gates.$gate -ne 'PASS'){throw "Candidate prerequisite gate is not PASS: $gate"}}
    if([string]$receipt.gates.'CFA-S7-008' -ne 'BLOCKED'){throw 'Candidate receipt CFA-S7-008 status changed unexpectedly.'}
    if([string]$receipt.sources.stage6_validation_receipt_sha256 -ne $ExpectedStage6ReceiptSha -or [string]$receipt.sources.stage4_responses_sha256 -ne $ExpectedStage4Sha -or [string]$receipt.sources.factor_csv_sha256 -ne $ExpectedFactorSha){throw 'Candidate receipt frozen-source hash mismatch.'}
    if([long]$receipt.eligibility.rows -ne $ExpectedEligibleRows -or [int]$receipt.eligibility.bases -ne $ExpectedEligibleBases -or [int]$receipt.eligibility.days -ne $ExpectedEligibleDays){throw 'Candidate receipt eligibility cardinality mismatch.'}
    if([long]$receipt.split.model_rows -ne $ExpectedModelRows -or [long]$receipt.split.embargo_rows -ne $ExpectedEmbargoRows){throw 'Candidate receipt model/embargo row count mismatch.'}

    $eligibilityReceiptPath=Require-File ([string]$receipt.sources.eligibility_receipt) 'Stage 7 eligibility receipt'
    if((Get-Sha $eligibilityReceiptPath) -ne [string]$receipt.sources.eligibility_receipt_sha256){throw 'Candidate eligibility-receipt SHA mismatch.'}
    $elig=Get-Content -LiteralPath $eligibilityReceiptPath -Raw|ConvertFrom-Json
    if([string]$elig.status -ne 'PASS' -or [string]$elig.stage -ne 'CFA_STAGE_7' -or [string]$elig.diagnostic -ne 'MODEL_ELIGIBILITY_V1'){throw 'Eligibility receipt identity/status mismatch.'}
    if([string]$elig.sources.stage6_validation_receipt_sha256 -ne $ExpectedStage6ReceiptSha -or [string]$elig.sources.stage4_responses_sha256 -ne $ExpectedStage4Sha -or [string]$elig.sources.factor_csv_sha256 -ne $ExpectedFactorSha){throw 'Eligibility receipt frozen-source hash mismatch.'}

    $eligiblePath=Require-File ([string]$elig.outputs.all_seven_eligible_keys) 'All-seven eligible keys'
    if((Get-Sha $eligiblePath) -ne [string]$receipt.sources.eligible_keys_sha256 -or (Get-Sha $eligiblePath) -ne [string]$elig.outputs.all_seven_eligible_keys_sha256){throw 'Eligible-key hash mismatch across receipts.'}
    $responsePath=Require-File ([string]$elig.sources.stage4_responses) 'Frozen Stage 4 responses'
    $factorPath=Require-File ([string]$elig.sources.factor_csv) 'Frozen Stage 5 factors'
    if((Get-Sha $responsePath) -ne $ExpectedStage4Sha -or (Get-Sha $factorPath) -ne $ExpectedFactorSha){throw 'Frozen Stage 4/5 file hash mismatch.'}

    $assignmentPath=Require-File ([string]$receipt.outputs.split_assignment) 'Split assignment'
    $embargoPath=Require-File ([string]$receipt.outputs.embargo_exclusions) 'Embargo exclusions'
    $modelPath=Require-File ([string]$receipt.outputs.model_ready_candidate) 'Model-ready candidate'
    $preprocessPath=Require-File ([string]$receipt.outputs.preprocessing_parameters) 'Preprocessing parameters'
    $benchmarkPath=Require-File ([string]$receipt.benchmarks.plan_path) 'Benchmark plan'
    foreach($x in @(
        @($assignmentPath,[string]$receipt.outputs.split_assignment_sha256,'split assignment'),
        @($embargoPath,[string]$receipt.outputs.embargo_exclusions_sha256,'embargo exclusions'),
        @($modelPath,[string]$receipt.outputs.model_ready_candidate_sha256,'model-ready candidate'),
        @($preprocessPath,[string]$receipt.outputs.preprocessing_parameters_sha256,'preprocessing parameters'),
        @($benchmarkPath,[string]$receipt.benchmarks.plan_sha256,'benchmark plan')
    )){if((Get-Sha $x[0]) -ne $x[1]){throw "Candidate output SHA mismatch: $($x[2])"}}

    $eligible=@(Import-Csv -LiteralPath $eligiblePath)
    $assignment=@(Import-Csv -LiteralPath $assignmentPath)
    $embargo=@(Import-Csv -LiteralPath $embargoPath)
    $model=@(Import-Csv -LiteralPath $modelPath)
    $preprocess=@(Import-Csv -LiteralPath $preprocessPath)
    $responses=@(Import-Csv -LiteralPath $responsePath)
    $factors=@(Import-Csv -LiteralPath $factorPath)
    $benchmark=Get-Content -LiteralPath $benchmarkPath -Raw|ConvertFrom-Json

    if($eligible.Count -ne $ExpectedEligibleRows -or $assignment.Count -ne $ExpectedEligibleRows){throw 'Eligible/assignment row count mismatch.'}
    if($model.Count -ne $ExpectedModelRows -or $embargo.Count -ne $ExpectedEmbargoRows){throw 'Model/embargo row count mismatch.'}
    if($preprocess.Count -ne 16){throw "Preprocessing row count changed: $($preprocess.Count), expected 16."}

    Require-Columns $assignment[0] @('base_asset_id','response_day_utc','design_role','pair_token_opaque','source_member_ordinal') 'Split assignment'
    Require-Columns $embargo[0] @('base_asset_id','response_day_utc','design_role','pair_token_opaque','source_member_ordinal','exclusion_reason') 'Embargo exclusions'
    $modelExpectedColumns=@('base_asset_id','response_day_utc','predictor_cutoff_utc','design_role','pair_token_opaque','source_member_ordinal')+$FactorIds+@('response_id','response_value_log_return')
    $modelColumns=@($model[0].PSObject.Properties.Name)
    if(($modelColumns -join '|') -cne ($modelExpectedColumns -join '|')){throw "Model-ready column/order mismatch: $($modelColumns -join '|')"}
    Require-Columns $preprocess[0] @('phase','variable','kind','fit_roles','n','center','scale','policy') 'Preprocessing parameters'

    $responseByKey=@{}
    foreach($r in $responses){$k=([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc);if($responseByKey.ContainsKey($k)){throw "Duplicate response key: $k"};$responseByKey[$k]=$r}
    $factorByKey=@{}
    $recomputedEligible=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($f in $factors){
        $k=([string]$f.base_asset_id)+'|'+([string]$f.response_day_utc)
        if($factorByKey.ContainsKey($k)){throw "Duplicate factor key: $k"}
        $factorByKey[$k]=$f
        if(([string]$f.market_missing_reason -eq 'NONE') -and ([string]$f.news_24h_missing_reason -eq 'NONE') -and ([string]$f.news_6h_missing_reason -eq 'NONE')){[void]$recomputedEligible.Add($k)}
    }
    if($recomputedEligible.Count -ne $ExpectedEligibleRows){throw "Recomputed all-seven eligibility count changed: $($recomputedEligible.Count)."}

    $eligibleSet=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $eligibleDays=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $eligibleBases=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($e in $eligible){
        $k=([string]$e.base_asset_id)+'|'+([string]$e.response_day_utc)
        if(-not $eligibleSet.Add($k)){throw "Duplicate eligible key: $k"}
        if(-not $recomputedEligible.Contains($k)){throw "Eligibility artifact contains non-eligible key: $k"}
        [void]$eligibleDays.Add([string]$e.response_day_utc);[void]$eligibleBases.Add([string]$e.base_asset_id)
    }
    foreach($k in $recomputedEligible){if(-not $eligibleSet.Contains($k)){throw "Recomputed eligible key absent from eligibility artifact: $k"}}
    if($eligibleDays.Count -ne $ExpectedEligibleDays -or $eligibleBases.Count -ne $ExpectedEligibleBases){throw 'Eligible distinct day/base count mismatch.'}

    $sortedDays=@($eligibleDays|Sort-Object)
    $roleByDay=Get-DayRoles ([string[]]$sortedDays)
    if([string]$sortedDays[40] -ne $ExpectedEmbargo1Day -or [string]$sortedDays[54] -ne $ExpectedEmbargo2Day){throw 'Embargo-day derivation mismatch.'}

    $assignmentByKey=@{}
    $roleRows=@{TRAIN=[long]0;EMBARGO_TRAIN_VALIDATION=[long]0;VALIDATION=[long]0;EMBARGO_VALIDATION_TEST=[long]0;TEST=[long]0}
    $roleBases=@{}
    $roleDays=@{}
    foreach($role in $roleRows.Keys){$roleBases[$role]=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$roleDays[$role]=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)}
    $lastAssignmentSort=''
    foreach($a in $assignment){
        $base=[string]$a.base_asset_id;$day=[string]$a.response_day_utc;$k=$base+'|'+$day
        if($assignmentByKey.ContainsKey($k)){throw "Duplicate assignment key: $k"}
        if(-not $eligibleSet.Contains($k)){throw "Assignment key outside eligibility: $k"}
        $expectedRole=[string]$roleByDay[$day]
        if([string]$a.design_role -ne $expectedRole){throw "Assignment role mismatch: $k expected=$expectedRole actual=$($a.design_role)"}
        $r=$responseByKey[$k]
        if([string]$a.pair_token_opaque -cne [string]$r.pair_token_opaque -or ([string]$a.source_member_ordinal).Trim() -cne ([string]$r.source_member_ordinal).Trim()){throw "Assignment lineage mismatch: $k"}
        $sortKey=$day+'|'+$base
        if($lastAssignmentSort -ne '' -and [string]::CompareOrdinal($lastAssignmentSort,$sortKey) -gt 0){throw "Assignment ordering mismatch at $k"}
        $lastAssignmentSort=$sortKey
        $assignmentByKey[$k]=$a
        $roleRows[$expectedRole]=([long]$roleRows[$expectedRole])+1
        [void]$roleBases[$expectedRole].Add($base);[void]$roleDays[$expectedRole].Add($day)
    }
    if($assignmentByKey.Count -ne $eligibleSet.Count){throw 'Assignment/eligible key cardinality mismatch.'}
    if($roleDays.TRAIN.Count -ne 40 -or $roleDays.EMBARGO_TRAIN_VALIDATION.Count -ne 1 -or $roleDays.VALIDATION.Count -ne 13 -or $roleDays.EMBARGO_VALIDATION_TEST.Count -ne 1 -or $roleDays.TEST.Count -ne 13){throw 'Role day counts mismatch.'}
    if($roleRows.TRAIN -ne $ExpectedTrainRows -or $roleRows.EMBARGO_TRAIN_VALIDATION -ne $ExpectedEmbargo1Rows -or $roleRows.VALIDATION -ne $ExpectedValidationRows -or $roleRows.EMBARGO_VALIDATION_TEST -ne $ExpectedEmbargo2Rows -or $roleRows.TEST -ne $ExpectedTestRows){throw 'Role row counts mismatch.'}
    if($roleBases.TRAIN.Count -ne 410 -or $roleBases.VALIDATION.Count -ne 414 -or $roleBases.TEST.Count -ne 418){throw 'Model role base counts mismatch.'}
    if([long]$receipt.split.train.rows -ne $roleRows.TRAIN -or [int]$receipt.split.train.bases -ne $roleBases.TRAIN.Count -or [long]$receipt.split.validation.rows -ne $roleRows.VALIDATION -or [int]$receipt.split.validation.bases -ne $roleBases.VALIDATION.Count -or [long]$receipt.split.test.rows -ne $roleRows.TEST -or [int]$receipt.split.test.bases -ne $roleBases.TEST.Count){throw 'Receipt model-role split counts mismatch.'}
    if([string]$receipt.split.embargo_train_validation.day -ne $ExpectedEmbargo1Day -or [long]$receipt.split.embargo_train_validation.rows -ne $ExpectedEmbargo1Rows -or [string]$receipt.split.embargo_validation_test.day -ne $ExpectedEmbargo2Day -or [long]$receipt.split.embargo_validation_test.rows -ne $ExpectedEmbargo2Rows){throw 'Receipt embargo split mismatch.'}

    $modelSet=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $numericByRole=@{TRAIN=@{};VALIDATION=@{};TEST=@{}}
    foreach($role in @('TRAIN','VALIDATION','TEST')){
        $numericByRole[$role]['response_value_log_return']=New-Object System.Collections.ArrayList
        foreach($id in $FactorIds){$numericByRole[$role][$id]=New-Object System.Collections.ArrayList}
    }
    $lastModelSort=''
    foreach($m in $model){
        $base=[string]$m.base_asset_id;$day=[string]$m.response_day_utc;$k=$base+'|'+$day;$role=[string]$m.design_role
        if($role -notin @('TRAIN','VALIDATION','TEST')){throw "Invalid model role: $k $role"}
        if(-not $modelSet.Add($k)){throw "Duplicate model key: $k"}
        if(-not $assignmentByKey.ContainsKey($k) -or [string]$assignmentByKey[$k].design_role -ne $role){throw "Model/assignment role mismatch: $k"}
        $dayValue=Parse-Day $day "$k day"
        if([string]$m.predictor_cutoff_utc -cne (Format-Utc $dayValue)){throw "Model predictor cutoff mismatch: $k"}
        if([string]$m.response_id -ne $ResponseId){throw "Model response ID mismatch: $k"}
        $r=$responseByKey[$k];$f=$factorByKey[$k]
        if([string]$m.pair_token_opaque -cne [string]$r.pair_token_opaque -or ([string]$m.source_member_ordinal).Trim() -cne ([string]$r.source_member_ordinal).Trim()){throw "Model lineage mismatch: $k"}
        if([string]$m.response_value_log_return -cne [string]$r.response_value_log_return){throw "Model response value differs from frozen Stage 4: $k"}
        $rv=Parse-DoubleStrict $m.response_value_log_return "$k response"
        [void]$numericByRole[$role]['response_value_log_return'].Add($rv)
        foreach($id in $FactorIds){
            $value=[string]$m.PSObject.Properties[$id].Value
            if([string]::IsNullOrWhiteSpace($value)){throw "Blank model predictor: $k $id"}
            if($value -cne [string]$f.PSObject.Properties[$id].Value){throw "Model predictor differs from frozen Stage 5: $k $id"}
            [void]$numericByRole[$role][$id].Add((Parse-DoubleStrict $value "$k $id"))
        }
        $sortKey=$day+'|'+$base
        if($lastModelSort -ne '' -and [string]::CompareOrdinal($lastModelSort,$sortKey) -gt 0){throw "Model ordering mismatch at $k"}
        $lastModelSort=$sortKey
    }

    $embargoSet=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $lastEmbargoSort=''
    foreach($e in $embargo){
        $base=[string]$e.base_asset_id;$day=[string]$e.response_day_utc;$k=$base+'|'+$day;$role=[string]$e.design_role
        if($role -notin @('EMBARGO_TRAIN_VALIDATION','EMBARGO_VALIDATION_TEST')){throw "Invalid embargo role: $k $role"}
        if([string]$e.exclusion_reason -ne 'TEMPORAL_EMBARGO'){throw "Invalid embargo exclusion reason: $k"}
        if(-not $embargoSet.Add($k)){throw "Duplicate embargo key: $k"}
        if($modelSet.Contains($k)){throw "Key appears in model and embargo: $k"}
        if(-not $assignmentByKey.ContainsKey($k) -or [string]$assignmentByKey[$k].design_role -ne $role){throw "Embargo/assignment role mismatch: $k"}
        $r=$responseByKey[$k]
        if([string]$e.pair_token_opaque -cne [string]$r.pair_token_opaque -or ([string]$e.source_member_ordinal).Trim() -cne ([string]$r.source_member_ordinal).Trim()){throw "Embargo lineage mismatch: $k"}
        $sortKey=$day+'|'+$base
        if($lastEmbargoSort -ne '' -and [string]::CompareOrdinal($lastEmbargoSort,$sortKey) -gt 0){throw "Embargo ordering mismatch at $k"}
        $lastEmbargoSort=$sortKey
    }
    if($modelSet.Count + $embargoSet.Count -ne $eligibleSet.Count){throw 'Model + embargo key accounting mismatch.'}
    foreach($k in $eligibleSet){if(-not $modelSet.Contains($k) -and -not $embargoSet.Contains($k)){throw "Eligible key unaccounted for: $k"}}

    $trainDays=@($roleDays.TRAIN|Sort-Object)
    $validationDays=@($roleDays.VALIDATION|Sort-Object)
    $testDays=@($roleDays.TEST|Sort-Object)
    $trainEnd=Parse-Day $trainDays[$trainDays.Count-1] 'train end'
    $validationStart=Parse-Day $validationDays[0] 'validation start'
    $validationEnd=Parse-Day $validationDays[$validationDays.Count-1] 'validation end'
    $testStart=Parse-Day $testDays[0] 'test start'
    if($trainEnd.AddDays(1) -ge $validationStart){throw 'Train response availability is not strictly before validation start.'}
    if($validationEnd.AddDays(1) -ge $testStart){throw 'Train+validation response availability is not strictly before test start.'}
    if([string]$receipt.split.train.start_day -ne $trainDays[0] -or [string]$receipt.split.train.end_day -ne $trainDays[$trainDays.Count-1] -or [string]$receipt.split.validation.start_day -ne $validationDays[0] -or [string]$receipt.split.validation.end_day -ne $validationDays[$validationDays.Count-1] -or [string]$receipt.split.test.start_day -ne $testDays[0] -or [string]$receipt.split.test.end_day -ne $testDays[$testDays.Count-1]){throw 'Receipt chronological boundaries mismatch.'}

    $preprocessByKey=@{}
    foreach($p in $preprocess){
        $pk=([string]$p.phase)+'|'+([string]$p.variable)
        if($preprocessByKey.ContainsKey($pk)){throw "Duplicate preprocessing parameter: $pk"}
        $preprocessByKey[$pk]=$p
    }
    foreach($phase in @('VALIDATION_FIT','TEST_REFIT')){
        $fitRoles=if($phase -eq 'VALIDATION_FIT'){@('TRAIN')}else{@('TRAIN','VALIDATION')}
        $expectedFitRoles=($fitRoles -join '+')
        foreach($id in $FactorIds){
            $pk=$phase+'|'+$id
            if(-not $preprocessByKey.ContainsKey($pk)){throw "Missing preprocessing parameter: $pk"}
            $vals=New-Object System.Collections.ArrayList
            foreach($role in $fitRoles){foreach($x in $numericByRole[$role][$id]){[void]$vals.Add([double]$x)}}
            $ms=Get-MeanSd ([double[]]$vals.ToArray()) "$phase $id"
            $p=$preprocessByKey[$pk]
            if([string]$p.kind -ne 'PREDICTOR' -or [string]$p.fit_roles -ne $expectedFitRoles -or [string]$p.policy -ne 'CENTER_AND_SAMPLE_SD_SCALE'){throw "Predictor preprocessing metadata mismatch: $pk"}
            if([long]$p.n -ne $ms.n){throw "Predictor preprocessing n mismatch: $pk"}
            $center=Parse-DoubleStrict $p.center "$pk center";$scale=Parse-DoubleStrict $p.scale "$pk scale"
            if(-not (Nearly-Equal $center $ms.mean) -or -not (Nearly-Equal $scale $ms.sd)){throw "Predictor preprocessing statistic mismatch: $pk"}
        }
        $ypk=$phase+'|response_value_log_return'
        if(-not $preprocessByKey.ContainsKey($ypk)){throw "Missing response preprocessing parameter: $ypk"}
        $yvals=New-Object System.Collections.ArrayList
        foreach($role in $fitRoles){foreach($x in $numericByRole[$role]['response_value_log_return']){[void]$yvals.Add([double]$x)}}
        $ysum=0.0;foreach($x in $yvals){$ysum += [double]$x};$ymean=$ysum/$yvals.Count
        $yp=$preprocessByKey[$ypk]
        if([string]$yp.kind -ne 'RESPONSE' -or [string]$yp.fit_roles -ne $expectedFitRoles -or [string]$yp.policy -ne 'CENTER_ONLY' -or [string]$yp.scale -ne '1'){throw "Response preprocessing metadata mismatch: $ypk"}
        if([long]$yp.n -ne $yvals.Count){throw "Response preprocessing n mismatch: $ypk"}
        if(-not (Nearly-Equal (Parse-DoubleStrict $yp.center "$ypk center") $ymean)){throw "Response preprocessing center mismatch: $ypk"}
    }
    if($preprocessByKey.Count -ne 16){throw 'Unexpected preprocessing parameter keys.'}

    if([string]$benchmark.version -ne 'STAGE7_BENCHMARK_PLAN_V1'){throw 'Benchmark plan version mismatch.'}
    if([string]$benchmark.validation.evaluate_role -ne 'VALIDATION' -or (@($benchmark.validation.fit_roles) -join '+') -ne 'TRAIN'){throw 'Benchmark validation phase mismatch.'}
    if([string]$benchmark.test.evaluate_role -ne 'TEST' -or (@($benchmark.test.fit_roles) -join '+') -ne 'TRAIN+VALIDATION' -or [string]$benchmark.test.component_choice_source -ne 'VALIDATION_ONLY'){throw 'Benchmark test phase mismatch.'}
    $benchmarkIds=@($benchmark.benchmarks|ForEach-Object{[string]$_.id})
    if(($benchmarkIds -join '|') -ne 'BENCH_ZERO_RETURN|BENCH_PRIOR_MARKET_RETURN|BENCH_RESPONSE_MEAN'){throw 'Benchmark ID/order mismatch.'}
    if([string]$benchmark.metrics.primary -ne 'RMSE' -or (@($benchmark.metrics.secondary) -join '|') -ne 'MAE|PREDICTIVE_R2_VS_BENCH_RESPONSE_MEAN'){throw 'Benchmark metric identity mismatch.'}
    if([string]$benchmark.component_selection.criterion -ne 'LOWEST_VALIDATION_RMSE' -or [string]$benchmark.component_selection.tie_break -ne 'SMALLER_COMPONENT_COUNT' -or -not [bool]$benchmark.component_selection.test_metrics_forbidden){throw 'Component-selection policy mismatch.'}

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Split-Path -Parent $CandidateReceiptPath}
    if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $checksPath=Join-Path $OutputRoot 'stage7-model-ready-independent-validation-checks.csv'
    $validationReceiptPath=Join-Path $OutputRoot 'stage7-model-ready-independent-validation.json'
    $checks=@(
        [pscustomobject]@{check_id='SOURCE_HASHES';status='PASS';detail='Stage 6, Stage 4, Stage 5 and eligibility lineage reconciled'},
        [pscustomobject]@{check_id='ELIGIBILITY_KEYS';status='PASS';detail='27152 all-seven keys independently recomputed'},
        [pscustomobject]@{check_id='SPLIT_ASSIGNMENT';status='PASS';detail='40/1/13/1/13 chronological roles and row counts reconciled'},
        [pscustomobject]@{check_id='EMBARGO_AVAILABILITY';status='PASS';detail='fit responses available strictly before next evaluation segment'},
        [pscustomobject]@{check_id='MODEL_MATRIX';status='PASS';detail='26337 model keys/values/order match frozen Stage 4/5'},
        [pscustomobject]@{check_id='PREPROCESSING';status='PASS';detail='16 parameters recomputed from permitted fit roles'},
        [pscustomobject]@{check_id='BENCHMARK_PLAN';status='PASS';detail='benchmark, metrics and validation-only component selection identity reconciled'},
        [pscustomobject]@{check_id='OUTPUT_HASHES';status='PASS';detail='candidate receipt output hashes reconcile'}
    )
    $checks|Export-Csv -LiteralPath $checksPath -NoTypeInformation -Encoding UTF8

    $validation=[ordered]@{
        status='PASS';stage='CFA_STAGE_7';validation='INDEPENDENT_MODEL_READY_V1';candidate_receipt_path=$CandidateReceiptPath;candidate_receipt_sha256=$candidateReceiptSha;
        sources=[ordered]@{eligibility_receipt=$eligibilityReceiptPath;eligibility_receipt_sha256=(Get-Sha $eligibilityReceiptPath);stage6_validation_receipt_sha256=$ExpectedStage6ReceiptSha;stage4_responses_sha256=$ExpectedStage4Sha;factor_csv_sha256=$ExpectedFactorSha;eligible_keys_sha256=(Get-Sha $eligiblePath)};
        split=[ordered]@{train=[ordered]@{days=40;rows=$roleRows.TRAIN;bases=$roleBases.TRAIN.Count;start_day=$trainDays[0];end_day=$trainDays[$trainDays.Count-1]};embargo_train_validation=[ordered]@{day=$ExpectedEmbargo1Day;rows=$roleRows.EMBARGO_TRAIN_VALIDATION};validation=[ordered]@{days=13;rows=$roleRows.VALIDATION;bases=$roleBases.VALIDATION.Count;start_day=$validationDays[0];end_day=$validationDays[$validationDays.Count-1]};embargo_validation_test=[ordered]@{day=$ExpectedEmbargo2Day;rows=$roleRows.EMBARGO_VALIDATION_TEST};test=[ordered]@{days=13;rows=$roleRows.TEST;bases=$roleBases.TEST.Count;start_day=$testDays[0];end_day=$testDays[$testDays.Count-1]};model_rows=$model.Count;embargo_rows=$embargo.Count};
        outputs=[ordered]@{split_assignment=$assignmentPath;split_assignment_sha256=(Get-Sha $assignmentPath);embargo_exclusions=$embargoPath;embargo_exclusions_sha256=(Get-Sha $embargoPath);model_ready=$modelPath;model_ready_sha256=(Get-Sha $modelPath);preprocessing_parameters=$preprocessPath;preprocessing_parameters_sha256=(Get-Sha $preprocessPath);benchmark_plan=$benchmarkPath;benchmark_plan_sha256=(Get-Sha $benchmarkPath);validation_checks=$checksPath;validation_checks_sha256=(Get-Sha $checksPath)};
        checks=[ordered]@{eligibility_recomputed='PASS';key_union='PASS';role_order='PASS';embargo_response_availability='PASS';model_values_vs_frozen_sources='PASS';preprocessing_recomputed='PASS';benchmark_identity='PASS';hashes='PASS'};
        gates=[ordered]@{'CFA-S7-001'='PASS';'CFA-S7-002'='PASS';'CFA-S7-003'='PASS';'CFA-S7-004'='PASS';'CFA-S7-005'='PASS';'CFA-S7-006'='PASS';'CFA-S7-007'='PASS';'CFA-S7-008'='UNVERIFIED'};
        next_action='Record exact independent-validation and candidate artifact hashes in repository evidence, then freeze CFA-S7-008 before Stage 8 PLS programming.'
    }
    [IO.File]::WriteAllText($validationReceiptPath,(($validation|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    $validationReceiptSha=Get-Sha $validationReceiptPath

    Write-Host ''
    Write-Host 'CFA STAGE 7 INDEPENDENT MODEL-READY VALIDATION: PASS'
    Write-Host "Eligible / model / embargo rows: $ExpectedEligibleRows / $($model.Count) / $($embargo.Count)"
    Write-Host "TRAIN / VALIDATION / TEST rows: $($roleRows.TRAIN) / $($roleRows.VALIDATION) / $($roleRows.TEST)"
    Write-Host "Embargo days: $ExpectedEmbargo1Day / $ExpectedEmbargo2Day"
    Write-Host 'Preprocessing parameters independently validated: 16'
    Write-Host 'Benchmark plan independently validated: PASS'
    Write-Host 'CFA-S7-003 through CFA-S7-007: PASS'
    Write-Host 'CFA-S7-008 independent validation/freeze: UNVERIFIED'
    Write-Host "Candidate receipt SHA-256: $candidateReceiptSha"
    Write-Host "Model-ready CSV SHA-256: $(Get-Sha $modelPath)"
    Write-Host "Split assignment SHA-256: $(Get-Sha $assignmentPath)"
    Write-Host "Embargo exclusions SHA-256: $(Get-Sha $embargoPath)"
    Write-Host "Preprocessing parameters SHA-256: $(Get-Sha $preprocessPath)"
    Write-Host "Benchmark plan SHA-256: $(Get-Sha $benchmarkPath)"
    Write-Host "Validation checks SHA-256: $(Get-Sha $checksPath)"
    Write-Host "Validation receipt SHA-256: $validationReceiptSha"
    Write-Host "Validation checks: $checksPath"
    Write-Host "Validation receipt: $validationReceiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 7 INDEPENDENT MODEL-READY VALIDATION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
