#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage7EligibilityReceiptPath,
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
$ExpectedFirstEligibleDay='2025-04-03'
$ExpectedLastEligibleDay='2025-06-14'
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

function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $n=0.0
    if(-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"}
    if([double]::IsNaN($n) -or [double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"}
    return $n
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

function Get-DayRoles {
    param([string[]]$Days)
    if($Days.Count -ne 68){throw "Day-role rule requires exactly 68 eligible days; observed $($Days.Count)."}
    $map=@{}
    for($i=0;$i -lt $Days.Count;$i++){
        $index=$i+1
        $role=''
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
    $days=1..68|ForEach-Object{('2025-01-{0:D2}' -f $_)}
    $roles=Get-DayRoles $days
    $counts=@{}
    foreach($r in $roles.Values){if(-not$counts.ContainsKey($r)){$counts[$r]=0};$counts[$r]++}
    if($counts.TRAIN -ne 40 -or $counts.EMBARGO_TRAIN_VALIDATION -ne 1 -or $counts.VALIDATION -ne 13 -or $counts.EMBARGO_VALIDATION_TEST -ne 1 -or $counts.TEST -ne 13){throw 'Day-role self-test failed.'}
    $s=Get-MeanSd ([double[]](1.0,2.0,3.0)) 'selftest'
    if([math]::Abs($s.mean-2.0) -gt 1e-12 -or [math]::Abs($s.sd-1.0) -gt 1e-12){throw 'Mean/SD self-test failed.'}
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
    foreach($marker in @('MODEL_ELIGIBILITY_PASS','40 TRAIN','13 validation','BENCH_ZERO_RETURN','sample standard deviation','CFA-S7-007')){if($contract -notmatch [regex]::Escape($marker)){throw "Stage 7 candidate contract marker missing: $marker"}}

    $Stage7EligibilityReceiptPath=Require-File $Stage7EligibilityReceiptPath 'Stage 7 eligibility receipt'
    $eligibilityReceiptSha=Get-Sha $Stage7EligibilityReceiptPath
    $elig=Get-Content -LiteralPath $Stage7EligibilityReceiptPath -Raw|ConvertFrom-Json
    if([string]$elig.status -ne 'PASS' -or [string]$elig.stage -ne 'CFA_STAGE_7' -or [string]$elig.diagnostic -ne 'MODEL_ELIGIBILITY_V1'){throw 'Stage 7 eligibility receipt identity/status mismatch.'}
    if([string]$elig.sources.stage6_validation_receipt_sha256 -ne $ExpectedStage6ReceiptSha){throw 'Eligibility receipt Stage 6 SHA mismatch.'}
    if([string]$elig.sources.stage4_responses_sha256 -ne $ExpectedStage4Sha -or [string]$elig.sources.factor_csv_sha256 -ne $ExpectedFactorSha){throw 'Eligibility receipt frozen source hash mismatch.'}
    if([long]$elig.all_seven_eligible.rows -ne $ExpectedEligibleRows -or [int]$elig.all_seven_eligible.bases -ne $ExpectedEligibleBases -or [int]$elig.all_seven_eligible.days -ne $ExpectedEligibleDays){throw 'Eligibility receipt cardinality mismatch.'}
    if([string]$elig.all_seven_eligible.first_day -ne $ExpectedFirstEligibleDay -or [string]$elig.all_seven_eligible.last_day -ne $ExpectedLastEligibleDay){throw 'Eligibility receipt date boundary mismatch.'}
    foreach($id in @('CFA-S7-001','CFA-S7-002')){if([string]$elig.gates.$id -ne 'PASS'){throw "Eligibility prerequisite is not PASS: $id"}}

    $eligiblePath=Require-File ([string]$elig.outputs.all_seven_eligible_keys) 'All-seven eligible keys'
    $patternsPath=Require-File ([string]$elig.outputs.availability_patterns) 'Availability patterns'
    $dayDiagPath=Require-File ([string]$elig.outputs.eligibility_by_day) 'Eligibility by day'
    $assetDiagPath=Require-File ([string]$elig.outputs.eligibility_by_asset) 'Eligibility by asset'
    $variableDiagPath=Require-File ([string]$elig.outputs.variable_diagnostics) 'Eligibility variable diagnostics'
    $splitDiagPath=Require-File ([string]$elig.outputs.chronological_split_candidates) 'Chronological split candidates'
    foreach($pair in @(
        @($eligiblePath,[string]$elig.outputs.all_seven_eligible_keys_sha256,'eligible keys'),
        @($patternsPath,[string]$elig.outputs.availability_patterns_sha256,'patterns'),
        @($dayDiagPath,[string]$elig.outputs.eligibility_by_day_sha256,'day diagnostics'),
        @($assetDiagPath,[string]$elig.outputs.eligibility_by_asset_sha256,'asset diagnostics'),
        @($variableDiagPath,[string]$elig.outputs.variable_diagnostics_sha256,'variable diagnostics'),
        @($splitDiagPath,[string]$elig.outputs.chronological_split_candidates_sha256,'split diagnostics')
    )){if((Get-Sha $pair[0]) -ne $pair[1]){throw "Eligibility output SHA mismatch: $($pair[2])"}}

    $responsePath=Require-File ([string]$elig.sources.stage4_responses) 'Frozen Stage 4 responses'
    $factorPath=Require-File ([string]$elig.sources.factor_csv) 'Frozen Stage 5 factors'
    if((Get-Sha $responsePath) -ne $ExpectedStage4Sha -or (Get-Sha $factorPath) -ne $ExpectedFactorSha){throw 'Frozen response/factor file hash mismatch.'}

    $eligible=@(Import-Csv -LiteralPath $eligiblePath)
    $responses=@(Import-Csv -LiteralPath $responsePath)
    $factors=@(Import-Csv -LiteralPath $factorPath)
    if($eligible.Count -ne $ExpectedEligibleRows){throw "Eligible-key row count mismatch: $($eligible.Count)"}
    if(@(Import-Csv -LiteralPath $patternsPath).Count -ne 8){throw 'Availability-pattern count mismatch.'}
    if(@(Import-Csv -LiteralPath $splitDiagPath).Count -ne 67){throw 'Chronological split-candidate count mismatch.'}

    $responseByKey=@{}
    foreach($r in $responses){$k=([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc);if($responseByKey.ContainsKey($k)){throw "Duplicate response key: $k"};$responseByKey[$k]=$r}
    $factorByKey=@{}
    foreach($f in $factors){$k=([string]$f.base_asset_id)+'|'+([string]$f.response_day_utc);if($factorByKey.ContainsKey($k)){throw "Duplicate factor key: $k"};$factorByKey[$k]=$f}

    $eligibleSeen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $eligibleBases=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $eligibleDaySet=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($e in $eligible){
        $base=[string]$e.base_asset_id;$day=[string]$e.response_day_utc;$k=$base+'|'+$day
        if(-not $eligibleSeen.Add($k)){throw "Duplicate eligible key: $k"}
        if(-not $responseByKey.ContainsKey($k) -or -not $factorByKey.ContainsKey($k)){throw "Eligible key missing upstream row: $k"}
        [void]$eligibleBases.Add($base);[void]$eligibleDaySet.Add($day)
    }
    if($eligibleBases.Count -ne $ExpectedEligibleBases -or $eligibleDaySet.Count -ne $ExpectedEligibleDays){throw 'Eligible distinct base/day count mismatch.'}
    $eligibleDays=@($eligibleDaySet|Sort-Object)
    if($eligibleDays[0] -ne $ExpectedFirstEligibleDay -or $eligibleDays[$eligibleDays.Count-1] -ne $ExpectedLastEligibleDay){throw 'Eligible day boundary mismatch.'}
    $roleByDay=Get-DayRoles ([string[]]$eligibleDays)

    $assignment=New-Object System.Collections.ArrayList
    $embargo=New-Object System.Collections.ArrayList
    $model=New-Object System.Collections.ArrayList
    $roleRows=@{TRAIN=[long]0;EMBARGO_TRAIN_VALIDATION=[long]0;VALIDATION=[long]0;EMBARGO_VALIDATION_TEST=[long]0;TEST=[long]0}
    $roleBases=@{}
    foreach($name in $roleRows.Keys){$roleBases[$name]=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)}

    $numericByRole=@{TRAIN=@{};VALIDATION=@{};TEST=@{}}
    foreach($role in @('TRAIN','VALIDATION','TEST')){
        $numericByRole[$role]['response_value_log_return']=New-Object System.Collections.ArrayList
        foreach($id in $FactorIds){$numericByRole[$role][$id]=New-Object System.Collections.ArrayList}
    }

    foreach($e in @($eligible|Sort-Object response_day_utc,base_asset_id)){
        $base=[string]$e.base_asset_id;$day=[string]$e.response_day_utc;$k=$base+'|'+$day;$role=[string]$roleByDay[$day]
        $r=$responseByKey[$k];$f=$factorByKey[$k]
        $roleRows[$role]=([long]$roleRows[$role])+1;[void]$roleBases[$role].Add($base)
        [void]$assignment.Add([pscustomobject][ordered]@{base_asset_id=$base;response_day_utc=$day;design_role=$role;pair_token_opaque=$r.pair_token_opaque;source_member_ordinal=$r.source_member_ordinal})
        if($role -like 'EMBARGO_*'){
            [void]$embargo.Add([pscustomobject][ordered]@{base_asset_id=$base;response_day_utc=$day;design_role=$role;pair_token_opaque=$r.pair_token_opaque;source_member_ordinal=$r.source_member_ordinal;exclusion_reason='TEMPORAL_EMBARGO'})
            continue
        }
        $rv=Parse-DoubleStrict $r.response_value_log_return "$k response"
        $row=[ordered]@{base_asset_id=$base;response_day_utc=$day;predictor_cutoff_utc=$r.predictor_cutoff_utc;design_role=$role;pair_token_opaque=$r.pair_token_opaque;source_member_ordinal=$r.source_member_ordinal}
        foreach($id in $FactorIds){
            $p=$f.PSObject.Properties[$id]
            if($null -eq $p -or [string]::IsNullOrWhiteSpace([string]$p.Value)){throw "Model row has blank predictor: $k $id"}
            $v=Parse-DoubleStrict $p.Value "$k $id"
            $row[$id]=[string]$p.Value
            [void]$numericByRole[$role][$id].Add($v)
        }
        $row['response_id']=$ResponseId
        $row['response_value_log_return']=[string]$r.response_value_log_return
        [void]$numericByRole[$role]['response_value_log_return'].Add($rv)
        [void]$model.Add([pscustomobject]$row)
    }

    if($roleRows.TRAIN -lt 1 -or $roleRows.VALIDATION -lt 1 -or $roleRows.TEST -lt 1 -or $roleRows.EMBARGO_TRAIN_VALIDATION -lt 1 -or $roleRows.EMBARGO_VALIDATION_TEST -lt 1){throw 'One or more design roles have zero rows.'}
    if($model.Count + $embargo.Count -ne $ExpectedEligibleRows){throw 'Model/embargo row accounting mismatch.'}

    $trainDays=$eligibleDays[0..39]
    $embargo1Day=$eligibleDays[40]
    $validationDays=$eligibleDays[41..53]
    $embargo2Day=$eligibleDays[54]
    $testDays=$eligibleDays[55..67]

    $preprocess=New-Object System.Collections.ArrayList
    foreach($phase in @('VALIDATION_FIT','TEST_REFIT')){
        $roles=if($phase -eq 'VALIDATION_FIT'){@('TRAIN')}else{@('TRAIN','VALIDATION')}
        foreach($id in $FactorIds){
            $vals=New-Object System.Collections.ArrayList
            foreach($role in $roles){foreach($v in $numericByRole[$role][$id]){[void]$vals.Add([double]$v)}}
            $ms=Get-MeanSd ([double[]]$vals.ToArray()) "$phase $id"
            [void]$preprocess.Add([pscustomobject][ordered]@{phase=$phase;variable=$id;kind='PREDICTOR';fit_roles=($roles -join '+');n=$ms.n;center=$ms.mean.ToString('R',$Invariant);scale=$ms.sd.ToString('R',$Invariant);policy='CENTER_AND_SAMPLE_SD_SCALE'})
        }
        $yvals=New-Object System.Collections.ArrayList
        foreach($role in $roles){foreach($v in $numericByRole[$role]['response_value_log_return']){[void]$yvals.Add([double]$v)}}
        $ysum=0.0;foreach($v in $yvals){$ysum += [double]$v};$ymean=$ysum/$yvals.Count
        [void]$preprocess.Add([pscustomobject][ordered]@{phase=$phase;variable='response_value_log_return';kind='RESPONSE';fit_roles=($roles -join '+');n=$yvals.Count;center=$ymean.ToString('R',$Invariant);scale='1';policy='CENTER_ONLY'})
    }

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage7-model-ready'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $assignmentPath=Join-Path $runDir 'stage7-split-assignment.csv'
    $embargoPath=Join-Path $runDir 'stage7-embargo-exclusions.csv'
    $modelPath=Join-Path $runDir 'stage7-model-ready-candidate.csv'
    $preprocessPath=Join-Path $runDir 'stage7-preprocessing-parameters.csv'
    $benchmarkPath=Join-Path $runDir 'stage7-benchmark-plan.json'
    $receiptPath=Join-Path $runDir 'stage7-model-ready-candidate-receipt.json'
    @($assignment.ToArray())|Export-Csv -LiteralPath $assignmentPath -NoTypeInformation -Encoding UTF8
    @($embargo.ToArray())|Export-Csv -LiteralPath $embargoPath -NoTypeInformation -Encoding UTF8
    @($model.ToArray())|Export-Csv -LiteralPath $modelPath -NoTypeInformation -Encoding UTF8
    @($preprocess.ToArray())|Export-Csv -LiteralPath $preprocessPath -NoTypeInformation -Encoding UTF8

    $benchmark=[ordered]@{
        version='STAGE7_BENCHMARK_PLAN_V1'
        validation=[ordered]@{fit_roles=@('TRAIN');evaluate_role='VALIDATION';response_mean_fit_roles=@('TRAIN')}
        test=[ordered]@{fit_roles=@('TRAIN','VALIDATION');evaluate_role='TEST';response_mean_fit_roles=@('TRAIN','VALIDATION');component_choice_source='VALIDATION_ONLY'}
        benchmarks=@(
            [ordered]@{id='BENCH_ZERO_RETURN';formula='prediction=0';fit='NONE'},
            [ordered]@{id='BENCH_PRIOR_MARKET_RETURN';formula='prediction=MKT_RET_USD_UTC_DAY_OBS_L1';fit='NONE'},
            [ordered]@{id='BENCH_RESPONSE_MEAN';formula='prediction=mean(response on fit roles)';fit='PHASE_SPECIFIC'}
        )
        metrics=[ordered]@{primary='RMSE';secondary=@('MAE','PREDICTIVE_R2_VS_BENCH_RESPONSE_MEAN');units='original response log-return units'}
        component_selection=[ordered]@{criterion='LOWEST_VALIDATION_RMSE';tie_break='SMALLER_COMPONENT_COUNT';test_metrics_forbidden=$true}
    }
    [IO.File]::WriteAllText($benchmarkPath,(($benchmark|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    $receipt=[ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_7';design='MODEL_READY_V1'
        sources=[ordered]@{eligibility_receipt=$Stage7EligibilityReceiptPath;eligibility_receipt_sha256=$eligibilityReceiptSha;stage6_validation_receipt_sha256=$ExpectedStage6ReceiptSha;stage4_responses_sha256=$ExpectedStage4Sha;factor_csv_sha256=$ExpectedFactorSha;eligible_keys_sha256=(Get-Sha $eligiblePath)}
        eligibility=[ordered]@{rows=$ExpectedEligibleRows;bases=$ExpectedEligibleBases;days=$ExpectedEligibleDays;first_day=$ExpectedFirstEligibleDay;last_day=$ExpectedLastEligibleDay}
        split=[ordered]@{
            train=[ordered]@{start_day=$trainDays[0];end_day=$trainDays[$trainDays.Count-1];days=40;rows=$roleRows.TRAIN;bases=$roleBases.TRAIN.Count}
            embargo_train_validation=[ordered]@{day=$embargo1Day;days=1;rows=$roleRows.EMBARGO_TRAIN_VALIDATION;bases=$roleBases.EMBARGO_TRAIN_VALIDATION.Count}
            validation=[ordered]@{start_day=$validationDays[0];end_day=$validationDays[$validationDays.Count-1];days=13;rows=$roleRows.VALIDATION;bases=$roleBases.VALIDATION.Count}
            embargo_validation_test=[ordered]@{day=$embargo2Day;days=1;rows=$roleRows.EMBARGO_VALIDATION_TEST;bases=$roleBases.EMBARGO_VALIDATION_TEST.Count}
            test=[ordered]@{start_day=$testDays[0];end_day=$testDays[$testDays.Count-1];days=13;rows=$roleRows.TEST;bases=$roleBases.TEST.Count}
            model_rows=$model.Count;embargo_rows=$embargo.Count
        }
        matrix=[ordered]@{response_id=$ResponseId;response_column='response_value_log_return';predictors=$FactorIds;missing_policy='ALL_SEVEN_REQUIRED_NO_IMPUTATION';grain='base_asset_id,response_day_utc'}
        preprocessing=[ordered]@{validation_fit='TRAIN_ONLY';test_refit='TRAIN_PLUS_VALIDATION';predictors='CENTER_AND_SAMPLE_SD_SCALE';response='CENTER_ONLY';zero_variance='BLOCKING_FAIL'}
        benchmarks=[ordered]@{plan_path=$benchmarkPath;plan_sha256=(Get-Sha $benchmarkPath);primary_metric='RMSE';secondary_metrics=@('MAE','PREDICTIVE_R2_VS_BENCH_RESPONSE_MEAN')}
        outputs=[ordered]@{split_assignment=$assignmentPath;split_assignment_sha256=(Get-Sha $assignmentPath);embargo_exclusions=$embargoPath;embargo_exclusions_sha256=(Get-Sha $embargoPath);model_ready_candidate=$modelPath;model_ready_candidate_sha256=(Get-Sha $modelPath);preprocessing_parameters=$preprocessPath;preprocessing_parameters_sha256=(Get-Sha $preprocessPath)}
        gates=[ordered]@{'CFA-S7-001'='PASS';'CFA-S7-002'='PASS';'CFA-S7-003'='PASS';'CFA-S7-004'='PASS';'CFA-S7-005'='PASS';'CFA-S7-006'='PASS';'CFA-S7-007'='PASS';'CFA-S7-008'='BLOCKED'}
        next_action='Independently validate the exact Stage 7 design/model-ready artifacts and freeze Stage 7 only after all hashes, split roles, preprocessing parameters, benchmark identity, and model-ready keys reconcile.'
    }
    [IO.File]::WriteAllText($receiptPath,(($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host 'CFA STAGE 7 MODEL-READY DESIGN CONSTRUCTION: VALIDATION CANDIDATE'
    Write-Host "Eligible rows / bases / days: $ExpectedEligibleRows / $ExpectedEligibleBases / $ExpectedEligibleDays"
    Write-Host "TRAIN days / rows / bases: 40 / $($roleRows.TRAIN) / $($roleBases.TRAIN.Count)"
    Write-Host "Embargo 1 day / rows: $embargo1Day / $($roleRows.EMBARGO_TRAIN_VALIDATION)"
    Write-Host "VALIDATION days / rows / bases: 13 / $($roleRows.VALIDATION) / $($roleBases.VALIDATION.Count)"
    Write-Host "Embargo 2 day / rows: $embargo2Day / $($roleRows.EMBARGO_VALIDATION_TEST)"
    Write-Host "TEST days / rows / bases: 13 / $($roleRows.TEST) / $($roleBases.TEST.Count)"
    Write-Host "Model rows / embargo rows: $($model.Count) / $($embargo.Count)"
    foreach($id in 3..7){Write-Host ("CFA-S7-{0:D3}: PASS" -f $id)}
    Write-Host 'CFA-S7-008 independent validation/freeze: BLOCKED'
    Write-Host "Model-ready candidate: $modelPath"
    Write-Host "Preprocessing parameters: $preprocessPath"
    Write-Host "Benchmark plan: $benchmarkPath"
    Write-Host "Candidate receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 7 MODEL-READY DESIGN CONSTRUCTION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
