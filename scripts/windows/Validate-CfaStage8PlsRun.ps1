#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunReceiptPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage7ValidationReceiptSha='e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756'
$ExpectedModelSha='fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024'
$ExpectedPreprocessSha='8a2a02676236b31d05dbdba6e11f8cd4f4086973448958337e0ee50c52329578'
$ExpectedBenchmarkSha='9b2fd8c9deae62b7c8bf1e04df6ec4d8926844fb8becd995e1efacb927399f9c'
$ExpectedTrainRows=15648
$ExpectedValidationRows=5323
$ExpectedTestRows=5366
$FactorIds=@(
    'MKT_RET_USD_UTC_DAY_OBS_L1',
    'MKT_RANGE_LOG_UTC_DAY_L1',
    'MKT_OBS_COUNT_UTC_DAY_L1',
    'MKT_OBS_SPAN_MIN_UTC_DAY_L1',
    'NEWS_V6_MATCH_COUNT_24H_LAG15',
    'NEWS_V6_MATCH_COUNT_6H_LAG15',
    'NEWS_V6_SOURCE_COUNT_24H_LAG15'
)

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
. (Join-Path $PSScriptRoot 'CfaStage8IndependentPlsCore.ps1')
. (Join-Path $PSScriptRoot 'CfaStage8IndependentData.ps1')

function Assert-CfaIndependentMetric {
    param($Observed,$Expected,[string]$Label)
    foreach($name in @('rmse','mae','sse','predictive_r2')){
        $observedValue=Parse-CfaIndependentDouble $Observed.$name "$Label observed $name"
        $expectedValue=[double]$Expected.$name
        if(-not(Test-CfaIndependentNear $observedValue $expectedValue)){throw "$Label $name mismatch: observed=$observedValue expected=$expectedValue"}
    }
}

function Assert-CfaPredictionRows {
    param([object[]]$CandidateRows,[object[]]$SourceRows,[double[]]$PlsPredictions,[hashtable]$Benchmarks,[string]$Label)
    if($CandidateRows.Count -ne $SourceRows.Count){throw "$Label prediction row count mismatch."}
    for($rowIndex=0;$rowIndex -lt $SourceRows.Count;$rowIndex++){
        $candidate=$CandidateRows[$rowIndex]
        $source=$SourceRows[$rowIndex]
        $candidateKey=([string]$candidate.base_asset_id)+'|'+([string]$candidate.response_day_utc)
        $sourceKey=([string]$source.base_asset_id)+'|'+([string]$source.response_day_utc)
        if($candidateKey -cne $sourceKey){throw "$Label prediction key/order mismatch at row $rowIndex"}
        $actual=Parse-CfaIndependentDouble $candidate.actual_response "$Label actual row $rowIndex"
        $sourceActual=Parse-CfaIndependentDouble $source.response_value_log_return "$Label source actual row $rowIndex"
        if(-not(Test-CfaIndependentNear $actual $sourceActual)){throw "$Label actual-response mismatch at $sourceKey"}
        $candidatePls=Parse-CfaIndependentDouble $candidate.pls_prediction "$Label PLS row $rowIndex"
        if(-not(Test-CfaIndependentNear $candidatePls $PlsPredictions[$rowIndex])){throw "$Label PLS prediction mismatch at $sourceKey"}
        foreach($pair in @(
            @('bench_zero_return','BENCH_ZERO_RETURN'),
            @('bench_prior_market_return','BENCH_PRIOR_MARKET_RETURN'),
            @('bench_response_mean','BENCH_RESPONSE_MEAN')
        )){
            $property=[string]$pair[0]
            $benchmarkId=[string]$pair[1]
            $candidateBenchmark=Parse-CfaIndependentDouble $candidate.PSObject.Properties[$property].Value "$Label $benchmarkId row $rowIndex"
            if(-not(Test-CfaIndependentNear $candidateBenchmark $Benchmarks[$benchmarkId][$rowIndex])){throw "$Label benchmark prediction mismatch: $benchmarkId $sourceKey"}
        }
    }
}

function Invoke-CfaStage8ValidatorSelfTest {
    if(-not(Test-CfaStage8IndependentCore)){throw 'Independent PLS core self-test returned false.'}
    if(-not(Test-CfaStage8IndependentData)){throw 'Independent data self-test returned false.'}
    $observed=[pscustomobject]@{rmse='1';mae='2';sse='3';predictive_r2='4'}
    $expected=[pscustomobject]@{rmse=1.0;mae=2.0;sse=3.0;predictive_r2=4.0}
    Assert-CfaIndependentMetric $observed $expected 'selftest metric'
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{Invoke-CfaStage8ValidatorSelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

try {
    $contractPath=Require-CfaIndependentFile (Join-Path $RepoRoot 'docs\evidence\stage8-pls-contract.md') 'Stage 8 contract'
    $contract=Get-Content -LiteralPath $contractPath -Raw
    foreach($marker in @('PLS_ALGORITHM_PASS','COMPONENT_SELECTION_PASS','Selected **3 components**','CFA-S8-007 = BLOCKED')){if($contract -notmatch [regex]::Escape($marker)){throw "Stage 8 validation prerequisite marker missing: $marker"}}

    $RunReceiptPath=Require-CfaIndependentFile $RunReceiptPath 'Stage 8 run receipt'
    $runReceiptSha=Get-CfaIndependentSha $RunReceiptPath
    $receipt=Get-Content -LiteralPath $RunReceiptPath -Raw|ConvertFrom-Json
    if([string]$receipt.status -ne 'VALIDATION_CANDIDATE' -or [string]$receipt.stage -ne 'CFA_STAGE_8' -or [string]$receipt.run -ne 'PLS1_NIPALS_V1'){throw 'Stage 8 run receipt identity mismatch.'}
    if([string]$receipt.sources.stage7_validation_receipt_sha256 -ne $ExpectedStage7ValidationReceiptSha){throw 'Stage 8 run Stage 7 receipt SHA mismatch.'}
    if([string]$receipt.sources.model_ready_sha256 -ne $ExpectedModelSha -or [string]$receipt.sources.preprocessing_parameters_sha256 -ne $ExpectedPreprocessSha -or [string]$receipt.sources.benchmark_plan_sha256 -ne $ExpectedBenchmarkSha){throw 'Stage 8 run frozen source SHA mismatch.'}
    if([int]$receipt.design.train_rows -ne $ExpectedTrainRows -or [int]$receipt.design.validation_rows -ne $ExpectedValidationRows -or [int]$receipt.design.test_rows -ne $ExpectedTestRows){throw 'Stage 8 run role cardinality mismatch.'}
    if((@($receipt.design.component_grid) -join ',') -ne '1,2,3,4,5,6,7'){throw 'Stage 8 run component grid mismatch.'}
    if([string]$receipt.design.selection_rule -ne 'LOWEST_VALIDATION_RMSE_THEN_SMALLER_COMPONENT_COUNT' -or [bool]$receipt.design.test_used_for_selection){throw 'Stage 8 run selection boundary mismatch.'}
    foreach($gate in 1..6){$id=('CFA-S8-{0:D3}' -f $gate);if([string]$receipt.gates.$id -ne 'PASS'){throw "Stage 8 candidate prerequisite gate is not PASS: $id"}}

    $stage7ReceiptPath=Require-CfaIndependentFile ([string]$receipt.sources.stage7_validation_receipt) 'Frozen Stage 7 validation receipt'
    if((Get-CfaIndependentSha $stage7ReceiptPath) -ne $ExpectedStage7ValidationReceiptSha){throw 'Frozen Stage 7 validation receipt file SHA mismatch.'}
    $stage7=Get-Content -LiteralPath $stage7ReceiptPath -Raw|ConvertFrom-Json
    if([string]$stage7.status -ne 'PASS' -or [string]$stage7.stage -ne 'CFA_STAGE_7' -or [string]$stage7.validation -ne 'INDEPENDENT_MODEL_READY_V1'){throw 'Frozen Stage 7 validation receipt identity mismatch.'}

    $modelPath=Require-CfaIndependentFile ([string]$stage7.outputs.model_ready) 'Frozen model-ready CSV'
    $preprocessPath=Require-CfaIndependentFile ([string]$stage7.outputs.preprocessing_parameters) 'Frozen preprocessing parameters'
    $benchmarkPlanPath=Require-CfaIndependentFile ([string]$stage7.outputs.benchmark_plan) 'Frozen benchmark plan'
    if((Get-CfaIndependentSha $modelPath) -ne $ExpectedModelSha -or (Get-CfaIndependentSha $preprocessPath) -ne $ExpectedPreprocessSha -or (Get-CfaIndependentSha $benchmarkPlanPath) -ne $ExpectedBenchmarkSha){throw 'Frozen Stage 7 file SHA mismatch during independent validation.'}

    $componentPath=Require-CfaIndependentFile ([string]$receipt.outputs.validation_component_metrics) 'Candidate component metrics'
    $validationPredictionsPath=Require-CfaIndependentFile ([string]$receipt.outputs.validation_selected_predictions) 'Candidate validation predictions'
    $testPredictionsPath=Require-CfaIndependentFile ([string]$receipt.outputs.test_selected_predictions) 'Candidate test predictions'
    $benchmarkMetricsPath=Require-CfaIndependentFile ([string]$receipt.outputs.benchmark_metrics) 'Candidate benchmark metrics'
    $coefficientsPath=Require-CfaIndependentFile ([string]$receipt.outputs.selected_coefficients) 'Candidate selected coefficients'
    $selectedModelPath=Require-CfaIndependentFile ([string]$receipt.outputs.selected_model) 'Candidate selected model'
    foreach($check in @(
        @($componentPath,[string]$receipt.outputs.validation_component_metrics_sha256,'component metrics'),
        @($validationPredictionsPath,[string]$receipt.outputs.validation_selected_predictions_sha256,'validation predictions'),
        @($testPredictionsPath,[string]$receipt.outputs.test_selected_predictions_sha256,'test predictions'),
        @($benchmarkMetricsPath,[string]$receipt.outputs.benchmark_metrics_sha256,'benchmark metrics'),
        @($coefficientsPath,[string]$receipt.outputs.selected_coefficients_sha256,'selected coefficients'),
        @($selectedModelPath,[string]$receipt.outputs.selected_model_sha256,'selected model')
    )){if((Get-CfaIndependentSha $check[0]) -ne [string]$check[1]){throw "Candidate output SHA mismatch: $($check[2])"}}

    $model=@(Import-Csv -LiteralPath $modelPath)
    if($model.Count -ne 26337){throw "Frozen model-ready count mismatch: $($model.Count)"}
    $train=@($model|Where-Object{[string]$_.design_role -eq 'TRAIN'})
    $validation=@($model|Where-Object{[string]$_.design_role -eq 'VALIDATION'})
    $test=@($model|Where-Object{[string]$_.design_role -eq 'TEST'})
    if($train.Count -ne $ExpectedTrainRows -or $validation.Count -ne $ExpectedValidationRows -or $test.Count -ne $ExpectedTestRows){throw 'Independent role row count mismatch.'}
    $trainValidation=@($model|Where-Object{[string]$_.design_role -in @('TRAIN','VALIDATION')})

    $preprocessMap=Get-CfaIndependentPreprocessMap @(Import-Csv -LiteralPath $preprocessPath)
    $benchmarkPlan=Get-Content -LiteralPath $benchmarkPlanPath -Raw|ConvertFrom-Json
    if([string]$benchmarkPlan.component_selection.criterion -ne 'LOWEST_VALIDATION_RMSE' -or [string]$benchmarkPlan.component_selection.tie_break -ne 'SMALLER_COMPONENT_COUNT' -or -not[bool]$benchmarkPlan.component_selection.test_metrics_forbidden){throw 'Frozen benchmark/selection plan mismatch.'}

    $trainProcessed=New-CfaIndependentProcessedData $train $preprocessMap 'VALIDATION_FIT' $FactorIds
    $validationProcessed=New-CfaIndependentProcessedData $validation $preprocessMap 'VALIDATION_FIT' $FactorIds
    $validationPath=Get-CfaIndependentPlsPath $trainProcessed.X $trainProcessed.y_centered 7

    $candidateComponentRows=@(Import-Csv -LiteralPath $componentPath)
    if($candidateComponentRows.Count -ne 7){throw 'Candidate component-metric row count mismatch.'}
    $independentComponentMetrics=@{}
    $independentValidationPredictions=@{}
    $selectedComponents=0
    $bestRmse=[double]::PositiveInfinity
    for($componentCount=1;$componentCount -le 7;$componentCount++){
        $beta=[double[]]$validationPath.betas[$componentCount-1]
        $predictions=Get-CfaIndependentPredictions $validationProcessed.X $beta $trainProcessed.response_center
        $metrics=Get-CfaIndependentMetrics $validationProcessed.y_raw $predictions $trainProcessed.response_center
        $independentComponentMetrics[$componentCount]=$metrics
        $independentValidationPredictions[$componentCount]=$predictions
        $candidate=$candidateComponentRows[$componentCount-1]
        if([int]$candidate.components -ne $componentCount -or [int]$candidate.n -ne $ExpectedValidationRows){throw "Candidate component row identity mismatch: $componentCount"}
        Assert-CfaIndependentMetric $candidate $metrics "component $componentCount"
        if($metrics.rmse -lt $bestRmse){$bestRmse=$metrics.rmse;$selectedComponents=$componentCount}
    }
    if($selectedComponents -lt 1){throw 'Independent component selection failed.'}
    if([int]$receipt.design.selected_components -ne $selectedComponents){throw "Candidate selected component mismatch: receipt=$($receipt.design.selected_components) independent=$selectedComponents"}

    $selectedModel=Get-Content -LiteralPath $selectedModelPath -Raw|ConvertFrom-Json
    if([string]$selectedModel.version -ne 'CFA_STAGE8_PLS1_NIPALS_V1' -or [int]$selectedModel.selected_components -ne $selectedComponents -or [bool]$selectedModel.test_used_for_selection){throw 'Selected-model identity/selection mismatch.'}
    if([string]$selectedModel.selection_rule -ne 'LOWEST_VALIDATION_RMSE_THEN_SMALLER_COMPONENT_COUNT'){throw 'Selected-model selection-rule mismatch.'}

    $validationBeta=[double[]]$validationPath.betas[$selectedComponents-1]
    $validationPredictions=[double[]]$independentValidationPredictions[$selectedComponents]
    $validationMetrics=$independentComponentMetrics[$selectedComponents]
    Assert-CfaIndependentMetric $selectedModel.validation $validationMetrics 'selected validation model'

    $trainValidationProcessed=New-CfaIndependentProcessedData $trainValidation $preprocessMap 'TEST_REFIT' $FactorIds
    $testProcessed=New-CfaIndependentProcessedData $test $preprocessMap 'TEST_REFIT' $FactorIds
    $testPath=Get-CfaIndependentPlsPath $trainValidationProcessed.X $trainValidationProcessed.y_centered $selectedComponents
    $testBeta=[double[]]$testPath.betas[$selectedComponents-1]
    $testPredictions=Get-CfaIndependentPredictions $testProcessed.X $testBeta $trainValidationProcessed.response_center
    $testMetrics=Get-CfaIndependentMetrics $testProcessed.y_raw $testPredictions $trainValidationProcessed.response_center
    Assert-CfaIndependentMetric $selectedModel.test $testMetrics 'selected test model'

    $validationBenchmarks=@{}
    $testBenchmarks=@{}
    foreach($benchmarkId in @('BENCH_ZERO_RETURN','BENCH_PRIOR_MARKET_RETURN','BENCH_RESPONSE_MEAN')){
        $validationBenchmarks[$benchmarkId]=Get-CfaIndependentBenchmarkPredictions $validation $benchmarkId $trainProcessed.response_center
        $testBenchmarks[$benchmarkId]=Get-CfaIndependentBenchmarkPredictions $test $benchmarkId $trainValidationProcessed.response_center
    }

    $candidateValidationPredictions=@(Import-Csv -LiteralPath $validationPredictionsPath)
    $candidateTestPredictions=@(Import-Csv -LiteralPath $testPredictionsPath)
    Assert-CfaPredictionRows $candidateValidationPredictions $validation $validationPredictions $validationBenchmarks 'VALIDATION'
    Assert-CfaPredictionRows $candidateTestPredictions $test $testPredictions $testBenchmarks 'TEST'

    $benchmarkMetricRows=@(Import-Csv -LiteralPath $benchmarkMetricsPath)
    if($benchmarkMetricRows.Count -ne 6){throw 'Candidate benchmark-metric row count mismatch.'}
    $benchmarkMetricMap=@{}
    foreach($row in $benchmarkMetricRows){
        $key=([string]$row.segment)+'|'+([string]$row.model_id)
        if($benchmarkMetricMap.ContainsKey($key)){throw "Duplicate benchmark metric key: $key"}
        $benchmarkMetricMap[$key]=$row
    }
    foreach($benchmarkId in @('BENCH_ZERO_RETURN','BENCH_PRIOR_MARKET_RETURN','BENCH_RESPONSE_MEAN')){
        $validationBenchmarkMetrics=Get-CfaIndependentMetrics $validationProcessed.y_raw $validationBenchmarks[$benchmarkId] $trainProcessed.response_center
        $testBenchmarkMetrics=Get-CfaIndependentMetrics $testProcessed.y_raw $testBenchmarks[$benchmarkId] $trainValidationProcessed.response_center
        Assert-CfaIndependentMetric $benchmarkMetricMap['VALIDATION|'+$benchmarkId] $validationBenchmarkMetrics "VALIDATION $benchmarkId"
        Assert-CfaIndependentMetric $benchmarkMetricMap['TEST|'+$benchmarkId] $testBenchmarkMetrics "TEST $benchmarkId"
    }

    $coefficientRows=@(Import-Csv -LiteralPath $coefficientsPath)
    if($coefficientRows.Count -ne 14){throw "Candidate coefficient row count mismatch: $($coefficientRows.Count)"}
    $coefficientMap=@{}
    foreach($row in $coefficientRows){
        $key=([string]$row.phase)+'|'+([string]$row.variable)
        if($coefficientMap.ContainsKey($key)){throw "Duplicate candidate coefficient key: $key"}
        $coefficientMap[$key]=$row
    }
    foreach($phaseInfo in @(
        [pscustomobject]@{phase='VALIDATION_FIT';beta=$validationBeta;responseCenter=$trainProcessed.response_center},
        [pscustomobject]@{phase='TEST_REFIT';beta=$testBeta;responseCenter=$trainValidationProcessed.response_center}
    )){
        for($factorIndex=0;$factorIndex -lt $FactorIds.Count;$factorIndex++){
            $factorId=$FactorIds[$factorIndex]
            $key=$phaseInfo.phase+'|'+$factorId
            if(-not $coefficientMap.ContainsKey($key)){throw "Missing candidate coefficient: $key"}
            $candidate=$coefficientMap[$key]
            if([int]$candidate.selected_components -ne $selectedComponents){throw "Candidate coefficient selected-component mismatch: $key"}
            $candidateBeta=Parse-CfaIndependentDouble $candidate.beta_preprocessed "$key beta"
            if(-not(Test-CfaIndependentNear $candidateBeta $phaseInfo.beta[$factorIndex])){throw "Candidate coefficient mismatch: $key"}
            $parameter=$preprocessMap[$phaseInfo.phase+'|'+$factorId]
            if([string]$candidate.predictor_center -cne [string]$parameter.center -or [string]$candidate.predictor_scale -cne [string]$parameter.scale){throw "Candidate coefficient preprocessing lineage mismatch: $key"}
            $candidateResponseCenter=Parse-CfaIndependentDouble $candidate.response_center "$key response center"
            if(-not(Test-CfaIndependentNear $candidateResponseCenter $phaseInfo.responseCenter)){throw "Candidate coefficient response-center mismatch: $key"}
        }
    }

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Split-Path -Parent $RunReceiptPath}
    if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $checksPath=Join-Path $OutputRoot 'stage8-pls-independent-validation-checks.csv'
    $validationReceiptPath=Join-Path $OutputRoot 'stage8-pls-independent-validation.json'
    $checks=@(
        [pscustomobject]@{check_id='FROZEN_ENTRY';status='PASS';detail='Stage 7 receipt/model/preprocessing/benchmark hashes reconciled'},
        [pscustomobject]@{check_id='COMPONENT_SWEEP';status='PASS';detail='Components 1..7 independently recomputed on TRAIN to VALIDATION'},
        [pscustomobject]@{check_id='SELECTION';status='PASS';detail=("Selected components independently reproduced: $selectedComponents")},
        [pscustomobject]@{check_id='VALIDATION_PREDICTIONS';status='PASS';detail='All validation selected-model and benchmark predictions reconciled'},
        [pscustomobject]@{check_id='TEST_BOUNDARY';status='PASS';detail='TEST processed only after independent validation selection was fixed'},
        [pscustomobject]@{check_id='TEST_PREDICTIONS';status='PASS';detail='All test selected-model and benchmark predictions reconciled'},
        [pscustomobject]@{check_id='COEFFICIENTS';status='PASS';detail='Validation-fit and test-refit coefficients independently recomputed'},
        [pscustomobject]@{check_id='OUTPUT_HASHES';status='PASS';detail='All Stage 8 candidate output hashes reconcile with run receipt'}
    )
    $checks|Export-Csv -LiteralPath $checksPath -NoTypeInformation -Encoding UTF8

    $validationReceipt=[ordered]@{
        status='PASS'
        stage='CFA_STAGE_8'
        validation='INDEPENDENT_PLS_RUN_V1'
        run_receipt=$RunReceiptPath
        run_receipt_sha256=$runReceiptSha
        frozen_sources=[ordered]@{
            stage7_validation_receipt_sha256=$ExpectedStage7ValidationReceiptSha
            model_ready_sha256=$ExpectedModelSha
            preprocessing_parameters_sha256=$ExpectedPreprocessSha
            benchmark_plan_sha256=$ExpectedBenchmarkSha
        }
        design=[ordered]@{
            train_rows=$ExpectedTrainRows
            validation_rows=$ExpectedValidationRows
            test_rows=$ExpectedTestRows
            component_grid=@(1,2,3,4,5,6,7)
            independently_selected_components=$selectedComponents
            selection_rule='LOWEST_VALIDATION_RMSE_THEN_SMALLER_COMPONENT_COUNT'
            test_used_for_selection=$false
        }
        selected_validation=[ordered]@{n=$validationMetrics.n;rmse=$validationMetrics.rmse;mae=$validationMetrics.mae;sse=$validationMetrics.sse;predictive_r2_vs_response_mean=$validationMetrics.predictive_r2}
        selected_test=[ordered]@{n=$testMetrics.n;rmse=$testMetrics.rmse;mae=$testMetrics.mae;sse=$testMetrics.sse;predictive_r2_vs_response_mean=$testMetrics.predictive_r2}
        candidate_outputs=[ordered]@{
            validation_component_metrics_sha256=(Get-CfaIndependentSha $componentPath)
            validation_selected_predictions_sha256=(Get-CfaIndependentSha $validationPredictionsPath)
            test_selected_predictions_sha256=(Get-CfaIndependentSha $testPredictionsPath)
            benchmark_metrics_sha256=(Get-CfaIndependentSha $benchmarkMetricsPath)
            selected_coefficients_sha256=(Get-CfaIndependentSha $coefficientsPath)
            selected_model_sha256=(Get-CfaIndependentSha $selectedModelPath)
        }
        validation_checks=$checksPath
        validation_checks_sha256=(Get-CfaIndependentSha $checksPath)
        gates=[ordered]@{
            'CFA-S8-001'='PASS';'CFA-S8-002'='PASS';'CFA-S8-003'='PASS';'CFA-S8-004'='PASS';'CFA-S8-005'='PASS';'CFA-S8-006'='PASS';'CFA-S8-007'='PASS';'CFA-S8-008'='UNVERIFIED'
        }
        next_action='Record exact Stage 8 run and independent-validation hashes in repository evidence, then freeze CFA-S8-008 without changing the selected component count or performance results.'
    }
    [IO.File]::WriteAllText($validationReceiptPath,(($validationReceipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    $validationReceiptSha=Get-CfaIndependentSha $validationReceiptPath

    Write-Host ''
    Write-Host 'CFA STAGE 8 INDEPENDENT PLS VALIDATION: PASS'
    Write-Host "TRAIN / VALIDATION / TEST rows: $ExpectedTrainRows / $ExpectedValidationRows / $ExpectedTestRows"
    Write-Host 'Component grid independently recomputed: 1..7'
    Write-Host "Selected components independently reproduced: $selectedComponents"
    Write-Host "VALIDATION RMSE / MAE / predictive R2: $($validationMetrics.rmse.ToString('R',$Invariant)) / $($validationMetrics.mae.ToString('R',$Invariant)) / $($validationMetrics.predictive_r2.ToString('R',$Invariant))"
    Write-Host "TEST RMSE / MAE / predictive R2: $($testMetrics.rmse.ToString('R',$Invariant)) / $($testMetrics.mae.ToString('R',$Invariant)) / $($testMetrics.predictive_r2.ToString('R',$Invariant))"
    Write-Host 'TEST used for component selection: False'
    Write-Host 'CFA-S8-007 independent validation: PASS'
    Write-Host 'CFA-S8-008 Stage 8 freeze: UNVERIFIED'
    Write-Host "Run receipt SHA-256: $runReceiptSha"
    Write-Host "Validation component metrics SHA-256: $(Get-CfaIndependentSha $componentPath)"
    Write-Host "Validation selected predictions SHA-256: $(Get-CfaIndependentSha $validationPredictionsPath)"
    Write-Host "TEST selected predictions SHA-256: $(Get-CfaIndependentSha $testPredictionsPath)"
    Write-Host "Benchmark metrics SHA-256: $(Get-CfaIndependentSha $benchmarkMetricsPath)"
    Write-Host "Selected coefficients SHA-256: $(Get-CfaIndependentSha $coefficientsPath)"
    Write-Host "Selected model SHA-256: $(Get-CfaIndependentSha $selectedModelPath)"
    Write-Host "Validation checks SHA-256: $(Get-CfaIndependentSha $checksPath)"
    Write-Host "Validation receipt SHA-256: $validationReceiptSha"
    Write-Host "Validation checks: $checksPath"
    Write-Host "Validation receipt: $validationReceiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 8 INDEPENDENT PLS VALIDATION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
