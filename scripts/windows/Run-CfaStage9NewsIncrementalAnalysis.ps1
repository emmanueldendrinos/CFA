#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage7ValidationReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage8ValidationReceiptPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage7ValidationReceiptSha='e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756'
$ExpectedStage8ValidationReceiptSha='950503a0400cd42be9c33b78fc9744c11cdf03b5c860c6f37c2abf9253c9ed33'
$ExpectedModelReadySha='fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024'
$ExpectedStage8SelectedModelSha='8aaf69b56756dd45001514e4029065719bec9e1cde425830e2b7e4219f632250'
$ExpectedStage8FullValidationRmse=0.068614084978703485
$ExpectedStage8FullTestRmse=0.058926318333538494
$ExpectedStage8SelectedComponents=3

$MarketFactors=@(
    'MKT_RET_USD_UTC_DAY_OBS_L1',
    'MKT_RANGE_LOG_UTC_DAY_L1',
    'MKT_OBS_COUNT_UTC_DAY_L1',
    'MKT_OBS_SPAN_MIN_UTC_DAY_L1'
)
$NewsFactors=@(
    'NEWS_V6_MATCH_COUNT_24H_LAG15',
    'NEWS_V6_MATCH_COUNT_6H_LAG15',
    'NEWS_V6_SOURCE_COUNT_24H_LAG15'
)
$FullFactors=@($MarketFactors+$NewsFactors)

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
. (Join-Path $PSScriptRoot 'CfaStage8PlsData.ps1')
. (Join-Path $PSScriptRoot 'CfaStage8PlsCore.ps1')
. (Join-Path $PSScriptRoot 'CfaStage9AnalysisData.ps1')

function Test-CfaStage9Near {
    param([double]$Left,[double]$Right,[double]$Tolerance=1e-10)
    $scale=[math]::Max(1.0,[math]::Max([math]::Abs($Left),[math]::Abs($Right)))
    return [math]::Abs($Left-$Right) -le ($Tolerance*$scale)
}

function New-CfaStage9MetricRow {
    param([string]$Surface,[string]$Family,[int]$Components,[string]$Phase,$Metrics)
    return [pscustomobject][ordered]@{
        surface=$Surface;family=$Family;phase=$Phase;components=$Components;n=$Metrics.n;
        rmse=$Metrics.rmse.ToString('R',$Invariant);mae=$Metrics.mae.ToString('R',$Invariant);
        sse=$Metrics.sse.ToString('R',$Invariant);predictive_r2_vs_response_mean=$Metrics.predictive_r2.ToString('R',$Invariant)
    }
}

function Invoke-CfaStage9FamilySurface {
    param(
        [string]$Surface,[string]$Family,[object[]]$FitRows,[object[]]$SelectionRows,[object[]]$EvaluationRows,
        [string[]]$FactorIds,[int]$MaxComponents
    )
    $selectionSpec=Get-CfaStage9PreprocessSpec $FitRows $FactorIds
    $fitProcessed=Convert-CfaStage9ProcessedData $FitRows $selectionSpec $FactorIds
    $selectionProcessed=Convert-CfaStage9ProcessedData $SelectionRows $selectionSpec $FactorIds
    $componentPath=Fit-CfaPls1Path $fitProcessed.X $fitProcessed.y_centered $MaxComponents
    $selectionMetricRows=New-Object System.Collections.ArrayList
    $selectedComponents=0;$bestRmse=[double]::PositiveInfinity
    for($componentCount=1;$componentCount -le $MaxComponents;$componentCount++){
        $beta=[double[]]$componentPath.betas[$componentCount-1]
        $predictions=Predict-CfaPlsOriginal $selectionProcessed.X $beta $fitProcessed.response_center
        $metrics=Get-CfaRegressionMetrics $selectionProcessed.y_raw $predictions $fitProcessed.response_center
        [void]$selectionMetricRows.Add((New-CfaStage9MetricRow $Surface $Family $componentCount 'SELECTION_VALIDATION' $metrics))
        if($metrics.rmse -lt $bestRmse){$bestRmse=$metrics.rmse;$selectedComponents=$componentCount}
    }
    if($selectedComponents -lt 1){throw "$Surface $Family component selection failed."}

    $refitRows=@($FitRows+$SelectionRows)
    $evaluationSpec=Get-CfaStage9PreprocessSpec $refitRows $FactorIds
    $refitProcessed=Convert-CfaStage9ProcessedData $refitRows $evaluationSpec $FactorIds
    $evaluationProcessed=Convert-CfaStage9ProcessedData $EvaluationRows $evaluationSpec $FactorIds
    $refitPath=Fit-CfaPls1Path $refitProcessed.X $refitProcessed.y_centered $selectedComponents
    $selectedBeta=[double[]]$refitPath.betas[$selectedComponents-1]
    $evaluationPredictions=Predict-CfaPlsOriginal $evaluationProcessed.X $selectedBeta $refitProcessed.response_center
    $evaluationMetrics=Get-CfaRegressionMetrics $evaluationProcessed.y_raw $evaluationPredictions $refitProcessed.response_center

    $predictionRows=New-Object System.Collections.ArrayList
    for($rowIndex=0;$rowIndex -lt $EvaluationRows.Count;$rowIndex++){
        [void]$predictionRows.Add([pscustomobject][ordered]@{
            surface=$Surface;family=$Family;base_asset_id=[string]$EvaluationRows[$rowIndex].base_asset_id;
            response_day_utc=[string]$EvaluationRows[$rowIndex].response_day_utc;
            actual_response=[string]$EvaluationRows[$rowIndex].response_value_log_return;
            prediction=$evaluationPredictions[$rowIndex].ToString('R',$Invariant)
        })
    }

    return [pscustomobject]@{
        surface=$Surface;family=$Family;selected_components=$selectedComponents;
        selection_metric_rows=@($selectionMetricRows.ToArray());evaluation_metrics=$evaluationMetrics;
        evaluation_metric_row=(New-CfaStage9MetricRow $Surface $Family $selectedComponents 'EVALUATION' $evaluationMetrics);
        prediction_rows=@($predictionRows.ToArray());evaluation_spec=$evaluationSpec
    }
}

function Add-CfaStage9SurfaceResults {
    param([string]$Surface,[object[]]$FitRows,[object[]]$SelectionRows,[object[]]$EvaluationRows,[System.Collections.ArrayList]$SelectionOut,[System.Collections.ArrayList]$EvaluationOut,[System.Collections.ArrayList]$PredictionOut)
    $families=@(
        [pscustomobject]@{id='S9_MARKET_ONLY';factors=$MarketFactors;max_components=4},
        [pscustomobject]@{id='S9_NEWS_ONLY';factors=$NewsFactors;max_components=3},
        [pscustomobject]@{id='S9_FULL_7';factors=$FullFactors;max_components=7}
    )
    $results=@{}
    foreach($familySpec in $families){
        $result=Invoke-CfaStage9FamilySurface $Surface $familySpec.id $FitRows $SelectionRows $EvaluationRows $familySpec.factors $familySpec.max_components
        $results[$familySpec.id]=$result
        foreach($row in $result.selection_metric_rows){[void]$SelectionOut.Add($row)}
        [void]$EvaluationOut.Add($result.evaluation_metric_row)
        foreach($row in $result.prediction_rows){[void]$PredictionOut.Add($row)}
    }
    return $results
}

if($SelfTest){
    try {
        if(-not(Test-CfaStage8PlsCore)){throw 'Stage 8 PLS core self-test failed.'}
        if(-not(Test-CfaStage9AnalysisData)){throw 'Stage 9 analysis-data self-test failed.'}
        Write-Host 'SELF-TEST: PASS';exit 0
    } catch {Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

try {
    $contractPath=Require-CfaStage9File (Join-Path $RepoRoot 'docs\evidence\stage9-news-incremental-contract.md') 'Stage 9 contract'
    $contract=Get-Content -LiteralPath $contractPath -Raw
    foreach($marker in @('S9_MARKET_ONLY','S9_NEWS_ONLY','S9_FULL_7','S9_INTERNAL_EVALUATION','INCREMENTAL_R2_NEWS_OVER_MARKET','POSTHOC_STAGE8_SPLIT')){if($contract -notmatch [regex]::Escape($marker)){throw "Stage 9 contract marker missing: $marker"}}
    $stage8Contract=Get-Content -LiteralPath (Require-CfaStage9File (Join-Path $RepoRoot 'docs\evidence\stage8-pls-contract.md') 'Stage 8 contract') -Raw
    if($stage8Contract -notmatch 'STAGE8_FROZEN' -or $stage8Contract -notmatch 'CFA-S8-008_PASS'){throw 'Frozen Stage 8 repository markers missing.'}

    $Stage7ValidationReceiptPath=Require-CfaStage9File $Stage7ValidationReceiptPath 'Stage 7 validation receipt'
    $Stage8ValidationReceiptPath=Require-CfaStage9File $Stage8ValidationReceiptPath 'Stage 8 validation receipt'
    if((Get-CfaStage9Sha $Stage7ValidationReceiptPath)-ne$ExpectedStage7ValidationReceiptSha){throw 'Stage 7 validation receipt SHA mismatch.'}
    if((Get-CfaStage9Sha $Stage8ValidationReceiptPath)-ne$ExpectedStage8ValidationReceiptSha){throw 'Stage 8 validation receipt SHA mismatch.'}

    $stage7=Get-Content -LiteralPath $Stage7ValidationReceiptPath -Raw|ConvertFrom-Json
    $stage8=Get-Content -LiteralPath $Stage8ValidationReceiptPath -Raw|ConvertFrom-Json
    if([string]$stage7.status-ne'PASS'-or[string]$stage7.stage-ne'CFA_STAGE_7'){throw 'Stage 7 receipt identity mismatch.'}
    if([string]$stage8.status-ne'PASS'-or[string]$stage8.stage-ne'CFA_STAGE_8'-or[string]$stage8.validation-ne'INDEPENDENT_PLS_RUN_V1'){throw 'Stage 8 receipt identity mismatch.'}
    if([int]$stage8.design.independently_selected_components-ne$ExpectedStage8SelectedComponents-or[bool]$stage8.design.test_used_for_selection){throw 'Stage 8 frozen selection identity mismatch.'}
    if([string]$stage8.candidate_outputs.selected_model_sha256-ne$ExpectedStage8SelectedModelSha){throw 'Stage 8 selected-model SHA mismatch.'}
    if(-not(Test-CfaStage9Near ([double]$stage8.selected_validation.rmse) $ExpectedStage8FullValidationRmse)-or-not(Test-CfaStage9Near ([double]$stage8.selected_test.rmse) $ExpectedStage8FullTestRmse)){throw 'Stage 8 frozen full-model metrics mismatch.'}

    $modelPath=Require-CfaStage9File ([string]$stage7.outputs.model_ready) 'Frozen model-ready CSV'
    if((Get-CfaStage9Sha $modelPath)-ne$ExpectedModelReadySha){throw 'Frozen model-ready CSV SHA mismatch.'}
    $model=@(Import-Csv -LiteralPath $modelPath)
    if($model.Count-ne26337){throw "Frozen model-ready row count mismatch: $($model.Count)"}
    $trainRows=@($model|Where-Object{[string]$_.design_role-eq'TRAIN'})
    $validationRows=@($model|Where-Object{[string]$_.design_role-eq'VALIDATION'})
    $testRows=@($model|Where-Object{[string]$_.design_role-eq'TEST'})
    if($trainRows.Count-ne15648-or$validationRows.Count-ne5323-or$testRows.Count-ne5366){throw 'Frozen Stage 7 role counts mismatch.'}

    $trainDays=@($trainRows|ForEach-Object{[string]$_.response_day_utc}|Sort-Object -Unique)
    if($trainDays.Count-ne40){throw "Expected 40 frozen TRAIN days; found $($trainDays.Count)."}
    $nestedRoleByDay=@{}
    $dayRoleRows=New-Object System.Collections.ArrayList
    for($dayIndex=0;$dayIndex-lt40;$dayIndex++){
        $ordinal=$dayIndex+1
        $role=if($ordinal-le17){'S9_DEV_TRAIN'}elseif($ordinal-eq18){'S9_EMBARGO_DEV_SELECTION'}elseif($ordinal-le26){'S9_SELECTION_VALIDATION'}elseif($ordinal-eq27){'S9_EMBARGO_SELECTION_EVALUATION'}else{'S9_INTERNAL_EVALUATION'}
        $day=$trainDays[$dayIndex];$nestedRoleByDay[$day]=$role
        $dayRows=@($trainRows|Where-Object{[string]$_.response_day_utc-ceq$day})
        $baseCount=@($dayRows|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique).Count
        [void]$dayRoleRows.Add([pscustomobject][ordered]@{day_ordinal=$ordinal;response_day_utc=$day;stage9_role=$role;rows=$dayRows.Count;bases=$baseCount})
    }
    $devRows=@($trainRows|Where-Object{$nestedRoleByDay[[string]$_.response_day_utc]-eq'S9_DEV_TRAIN'})
    $selectionRows=@($trainRows|Where-Object{$nestedRoleByDay[[string]$_.response_day_utc]-eq'S9_SELECTION_VALIDATION'})
    $internalEvalRows=@($trainRows|Where-Object{$nestedRoleByDay[[string]$_.response_day_utc]-eq'S9_INTERNAL_EVALUATION'})
    $embargo1Rows=@($trainRows|Where-Object{$nestedRoleByDay[[string]$_.response_day_utc]-eq'S9_EMBARGO_DEV_SELECTION'})
    $embargo2Rows=@($trainRows|Where-Object{$nestedRoleByDay[[string]$_.response_day_utc]-eq'S9_EMBARGO_SELECTION_EVALUATION'})
    if($devRows.Count+$selectionRows.Count+$internalEvalRows.Count+$embargo1Rows.Count+$embargo2Rows.Count-ne$trainRows.Count){throw 'Nested TRAIN row accounting mismatch.'}

    $parseDay={param([string]$Value);return [datetime]::ParseExact($Value,'yyyy-MM-dd',$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal)}
    $devEnd=&$parseDay $trainDays[16];$selectionStart=&$parseDay $trainDays[18];$selectionEnd=&$parseDay $trainDays[25];$evaluationStart=&$parseDay $trainDays[27]
    if($devEnd.AddDays(1)-ge$selectionStart){throw 'Nested dev response availability is not strictly before selection start.'}
    if($selectionEnd.AddDays(1)-ge$evaluationStart){throw 'Nested selection response availability is not strictly before internal evaluation start.'}

    $selectionMetricRows=New-Object System.Collections.ArrayList;$evaluationMetricRows=New-Object System.Collections.ArrayList;$predictionRows=New-Object System.Collections.ArrayList
    $nestedResults=Add-CfaStage9SurfaceResults 'NESTED_TRAIN' $devRows $selectionRows $internalEvalRows $selectionMetricRows $evaluationMetricRows $predictionRows
    $posthocResults=Add-CfaStage9SurfaceResults 'POSTHOC_STAGE8_SPLIT' $trainRows $validationRows $testRows $selectionMetricRows $evaluationMetricRows $predictionRows

    $posthocFull=$posthocResults['S9_FULL_7']
    if($posthocFull.selected_components-ne3){throw "Post-hoc full model did not reproduce Stage 8 selected component count: $($posthocFull.selected_components)"}
    if(-not(Test-CfaStage9Near $posthocFull.evaluation_metrics.rmse $ExpectedStage8FullTestRmse)){throw 'Post-hoc full model did not reproduce frozen Stage 8 TEST RMSE.'}

    $incrementalRows=New-Object System.Collections.ArrayList
    foreach($surfaceSpec in @(
        [pscustomobject]@{surface='NESTED_TRAIN';results=$nestedResults},
        [pscustomobject]@{surface='POSTHOC_STAGE8_SPLIT';results=$posthocResults}
    )){
        $market=$surfaceSpec.results['S9_MARKET_ONLY'].evaluation_metrics;$news=$surfaceSpec.results['S9_NEWS_ONLY'].evaluation_metrics;$full=$surfaceSpec.results['S9_FULL_7'].evaluation_metrics
        $incrementalR2=1.0-($full.sse/$market.sse)
        [void]$incrementalRows.Add([pscustomobject][ordered]@{
            surface=$surfaceSpec.surface;market_selected_components=$surfaceSpec.results['S9_MARKET_ONLY'].selected_components;
            news_selected_components=$surfaceSpec.results['S9_NEWS_ONLY'].selected_components;full_selected_components=$surfaceSpec.results['S9_FULL_7'].selected_components;
            market_rmse=$market.rmse.ToString('R',$Invariant);news_rmse=$news.rmse.ToString('R',$Invariant);full_rmse=$full.rmse.ToString('R',$Invariant);
            delta_rmse_full_minus_market=($full.rmse-$market.rmse).ToString('R',$Invariant);
            delta_mae_full_minus_market=($full.mae-$market.mae).ToString('R',$Invariant);
            incremental_r2_news_over_market=$incrementalR2.ToString('R',$Invariant);
            news_predictive_r2_vs_response_mean=$news.predictive_r2.ToString('R',$Invariant)
        })
    }

    $factorDiagnosticRows=New-Object System.Collections.ArrayList;$intensityGroupRows=New-Object System.Collections.ArrayList
    $nestedFitForDiagnostics=@($devRows+$selectionRows);$posthocFitForDiagnostics=@($trainRows+$validationRows)
    foreach($diagnosticSurface in @(
        [pscustomobject]@{surface='NESTED_TRAIN';fit=$nestedFitForDiagnostics;eval=$internalEvalRows},
        [pscustomobject]@{surface='POSTHOC_STAGE8_SPLIT';fit=$posthocFitForDiagnostics;eval=$testRows}
    )){
        foreach($factorId in $NewsFactors){
            [void]$factorDiagnosticRows.Add((Get-CfaStage9FactorSummary $diagnosticSurface.eval $factorId $diagnosticSurface.surface))
            foreach($groupRow in (Get-CfaStage9IntensityGroups $diagnosticSurface.fit $diagnosticSurface.eval $factorId $diagnosticSurface.surface)){[void]$intensityGroupRows.Add($groupRow)}
        }
    }

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage9-news-incremental'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $dayRolesPath=Join-Path $runDir 'stage9-nested-day-roles.csv'
    $componentMetricsPath=Join-Path $runDir 'stage9-model-family-component-metrics.csv'
    $evaluationMetricsPath=Join-Path $runDir 'stage9-model-family-evaluation-metrics.csv'
    $predictionsPath=Join-Path $runDir 'stage9-model-family-evaluation-predictions.csv'
    $incrementalPath=Join-Path $runDir 'stage9-news-incremental-comparison.csv'
    $factorDiagnosticsPath=Join-Path $runDir 'stage9-news-factor-diagnostics.csv'
    $intensityGroupsPath=Join-Path $runDir 'stage9-news-intensity-group-diagnostics.csv'
    $posthocMetricsPath=Join-Path $runDir 'stage9-posthoc-stage8-family-metrics.csv'
    $receiptPath=Join-Path $runDir 'stage9-news-incremental-run-receipt.json'

    @($dayRoleRows.ToArray())|Export-Csv -LiteralPath $dayRolesPath -NoTypeInformation -Encoding UTF8
    @($selectionMetricRows.ToArray())|Export-Csv -LiteralPath $componentMetricsPath -NoTypeInformation -Encoding UTF8
    @($evaluationMetricRows.ToArray())|Export-Csv -LiteralPath $evaluationMetricsPath -NoTypeInformation -Encoding UTF8
    @($predictionRows.ToArray())|Export-Csv -LiteralPath $predictionsPath -NoTypeInformation -Encoding UTF8
    @($incrementalRows.ToArray())|Export-Csv -LiteralPath $incrementalPath -NoTypeInformation -Encoding UTF8
    @($factorDiagnosticRows.ToArray())|ForEach-Object{
        $_.mean=([double]$_.mean).ToString('R',$Invariant);$_.sample_sd=([double]$_.sample_sd).ToString('R',$Invariant);$_.min=([double]$_.min).ToString('R',$Invariant);$_.max=([double]$_.max).ToString('R',$Invariant);$_.zero_share=([double]$_.zero_share).ToString('R',$Invariant);
        $_.pearson_signed_return=if([double]::IsNaN([double]$_.pearson_signed_return)){'NaN'}else{([double]$_.pearson_signed_return).ToString('R',$Invariant)};
        $_.pearson_absolute_return=if([double]::IsNaN([double]$_.pearson_absolute_return)){'NaN'}else{([double]$_.pearson_absolute_return).ToString('R',$Invariant)};$_
    }|Export-Csv -LiteralPath $factorDiagnosticsPath -NoTypeInformation -Encoding UTF8
    @($intensityGroupRows.ToArray())|ForEach-Object{
        $_.fit_positive_median=([double]$_.fit_positive_median).ToString('R',$Invariant);
        $_.mean_signed_response=if([double]::IsNaN([double]$_.mean_signed_response)){'NaN'}else{([double]$_.mean_signed_response).ToString('R',$Invariant)};
        $_.mean_absolute_response=if([double]::IsNaN([double]$_.mean_absolute_response)){'NaN'}else{([double]$_.mean_absolute_response).ToString('R',$Invariant)};$_
    }|Export-Csv -LiteralPath $intensityGroupsPath -NoTypeInformation -Encoding UTF8
    @($evaluationMetricRows.ToArray()|Where-Object{$_.surface-eq'POSTHOC_STAGE8_SPLIT'})|Export-Csv -LiteralPath $posthocMetricsPath -NoTypeInformation -Encoding UTF8

    $nestedIncremental=$incrementalRows[0];$posthocIncremental=$incrementalRows[1]
    $receipt=[ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_9';run='NEWS_INCREMENTAL_V1';interpretation='POSTHOC_EXPLORATORY_LEAKAGE_CONTROLLED';
        sources=[ordered]@{stage7_validation_receipt=$Stage7ValidationReceiptPath;stage7_validation_receipt_sha256=(Get-CfaStage9Sha $Stage7ValidationReceiptPath);stage8_validation_receipt=$Stage8ValidationReceiptPath;stage8_validation_receipt_sha256=(Get-CfaStage9Sha $Stage8ValidationReceiptPath);model_ready=$modelPath;model_ready_sha256=(Get-CfaStage9Sha $modelPath)};
        nested_split=[ordered]@{train_days=40;dev_train_days=17;embargo_1_day=$trainDays[17];selection_validation_days=8;embargo_2_day=$trainDays[26];internal_evaluation_days=13;dev_train_rows=$devRows.Count;selection_validation_rows=$selectionRows.Count;internal_evaluation_rows=$internalEvalRows.Count;embargo_rows=$embargo1Rows.Count+$embargo2Rows.Count};
        nested_results=[ordered]@{market_selected_components=$nestedResults['S9_MARKET_ONLY'].selected_components;news_selected_components=$nestedResults['S9_NEWS_ONLY'].selected_components;full_selected_components=$nestedResults['S9_FULL_7'].selected_components;delta_rmse_full_minus_market=[string]$nestedIncremental.delta_rmse_full_minus_market;incremental_r2_news_over_market=[string]$nestedIncremental.incremental_r2_news_over_market;news_predictive_r2_vs_response_mean=[string]$nestedIncremental.news_predictive_r2_vs_response_mean};
        posthoc_stage8_results=[ordered]@{market_selected_components=$posthocResults['S9_MARKET_ONLY'].selected_components;news_selected_components=$posthocResults['S9_NEWS_ONLY'].selected_components;full_selected_components=$posthocResults['S9_FULL_7'].selected_components;delta_rmse_full_minus_market=[string]$posthocIncremental.delta_rmse_full_minus_market;incremental_r2_news_over_market=[string]$posthocIncremental.incremental_r2_news_over_market;news_predictive_r2_vs_response_mean=[string]$posthocIncremental.news_predictive_r2_vs_response_mean};
        outputs=[ordered]@{
            nested_day_roles=$dayRolesPath;nested_day_roles_sha256=(Get-CfaStage9Sha $dayRolesPath);
            component_metrics=$componentMetricsPath;component_metrics_sha256=(Get-CfaStage9Sha $componentMetricsPath);
            evaluation_metrics=$evaluationMetricsPath;evaluation_metrics_sha256=(Get-CfaStage9Sha $evaluationMetricsPath);
            evaluation_predictions=$predictionsPath;evaluation_predictions_sha256=(Get-CfaStage9Sha $predictionsPath);
            incremental_comparison=$incrementalPath;incremental_comparison_sha256=(Get-CfaStage9Sha $incrementalPath);
            factor_diagnostics=$factorDiagnosticsPath;factor_diagnostics_sha256=(Get-CfaStage9Sha $factorDiagnosticsPath);
            intensity_groups=$intensityGroupsPath;intensity_groups_sha256=(Get-CfaStage9Sha $intensityGroupsPath);
            posthoc_metrics=$posthocMetricsPath;posthoc_metrics_sha256=(Get-CfaStage9Sha $posthocMetricsPath)
        };
        gates=[ordered]@{'CFA-S9-001'='PASS';'CFA-S9-002'='PASS';'CFA-S9-003'='PASS';'CFA-S9-004'='PASS';'CFA-S9-005'='PASS';'CFA-S9-006'='PASS';'CFA-S9-007'='BLOCKED';'CFA-S9-008'='BLOCKED'};
        next_action='Independently validate exact Stage 9 family fits, predictions, incremental estimands, factor diagnostics, group cutpoints and hashes before freezing research findings.'
    }
    [IO.File]::WriteAllText($receiptPath,(($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host 'CFA STAGE 9 NEWS-INCREMENTAL ANALYSIS: VALIDATION CANDIDATE'
    Write-Host "Nested TRAIN split rows dev / selection / eval / embargo: $($devRows.Count) / $($selectionRows.Count) / $($internalEvalRows.Count) / $($embargo1Rows.Count+$embargo2Rows.Count)"
    Write-Host "Nested embargo days: $($trainDays[17]) / $($trainDays[26])"
    Write-Host "Nested selected components market / news / full: $($nestedResults['S9_MARKET_ONLY'].selected_components) / $($nestedResults['S9_NEWS_ONLY'].selected_components) / $($nestedResults['S9_FULL_7'].selected_components)"
    Write-Host "Nested delta RMSE full-minus-market: $($nestedIncremental.delta_rmse_full_minus_market)"
    Write-Host "Nested incremental R2 news-over-market: $($nestedIncremental.incremental_r2_news_over_market)"
    Write-Host "Nested news-only predictive R2 vs response mean: $($nestedIncremental.news_predictive_r2_vs_response_mean)"
    Write-Host "Posthoc Stage8 selected components market / news / full: $($posthocResults['S9_MARKET_ONLY'].selected_components) / $($posthocResults['S9_NEWS_ONLY'].selected_components) / $($posthocResults['S9_FULL_7'].selected_components)"
    Write-Host "Posthoc Stage8 delta RMSE full-minus-market: $($posthocIncremental.delta_rmse_full_minus_market)"
    Write-Host "Posthoc Stage8 incremental R2 news-over-market: $($posthocIncremental.incremental_r2_news_over_market)"
    Write-Host "Posthoc Stage8 news-only predictive R2 vs response mean: $($posthocIncremental.news_predictive_r2_vs_response_mean)"
    Write-Host 'Interpretation status: POSTHOC / EXPLORATORY / LEAKAGE-CONTROLLED'
    Write-Host 'CFA-S9-001 through CFA-S9-006: PASS'
    Write-Host 'CFA-S9-007 independent validation: BLOCKED'
    Write-Host 'CFA-S9-008 research findings freeze: BLOCKED'
    Write-Host "Incremental comparison: $incrementalPath"
    Write-Host "News factor diagnostics: $factorDiagnosticsPath"
    Write-Host "News intensity groups: $intensityGroupsPath"
    Write-Host "Run receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 9 NEWS-INCREMENTAL ANALYSIS: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
