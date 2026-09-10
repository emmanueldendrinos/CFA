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
$ExpectedStage8ValidationReceiptSha='950503a0400cd42be9c33b78fc9744c11cdf03b5c860c6f37c2abf9253c9ed33'
$ExpectedModelReadySha='fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024'
$ExpectedStage8SelectedModelSha='8aaf69b56756dd45001514e4029065719bec9e1cde425830e2b7e4219f632250'
$MarketFactors=@('MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1')
$NewsFactors=@('NEWS_V6_MATCH_COUNT_24H_LAG15','NEWS_V6_MATCH_COUNT_6H_LAG15','NEWS_V6_SOURCE_COUNT_24H_LAG15')
$FullFactors=@($MarketFactors+$NewsFactors)

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
. (Join-Path $PSScriptRoot 'CfaStage8IndependentPlsCore.ps1')

function Get-CfaS9VerifySha {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Require-CfaS9VerifyFile {param([string]$Path,[string]$Label);$resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"};return $resolved}
function Parse-CfaS9VerifyDouble {param([object]$Value,[string]$Label);$parsed=0.0;if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$parsed)){throw "Malformed numeric for ${Label}: '$Value'"};if([double]::IsNaN($parsed)-or[double]::IsInfinity($parsed)){throw "Non-finite numeric for ${Label}: '$Value'"};return $parsed}
function Test-CfaS9VerifyNear {param([double]$Left,[double]$Right,[double]$Tolerance=1e-10);$scale=[math]::Max(1.0,[math]::Max([math]::Abs($Left),[math]::Abs($Right)));return [math]::Abs($Left-$Right)-le($Tolerance*$scale)}
function Test-CfaS9VerifyMaybeNaN {param([object]$Observed,[double]$Expected,[string]$Label);if([double]::IsNaN($Expected)){if(([string]$Observed)-ne'NaN'){throw "$Label expected NaN."};return};$value=Parse-CfaS9VerifyDouble $Observed $Label;if(-not(Test-CfaS9VerifyNear $value $Expected)){throw "$Label mismatch: observed=$value expected=$Expected"}}

function Get-CfaS9VerifyMeanSd {
    param([double[]]$Values,[string]$Label)
    if($Values.Count-lt2){throw "$Label requires at least two values."}
    $sum=0.0;foreach($value in $Values){$sum+=$value};$mean=$sum/$Values.Count
    $ss=0.0;foreach($value in $Values){$delta=$value-$mean;$ss+=$delta*$delta};$sd=[math]::Sqrt($ss/($Values.Count-1))
    if([double]::IsNaN($mean)-or[double]::IsInfinity($mean)-or[double]::IsNaN($sd)-or[double]::IsInfinity($sd)){throw "$Label statistics are non-finite."}
    return [pscustomobject]@{mean=$mean;sd=$sd;n=$Values.Count}
}

function Get-CfaS9VerifyPreprocessSpec {
    param([object[]]$FitRows,[string[]]$FactorIds)
    if($FitRows.Count-lt2){throw 'Independent Stage 9 fit set is too small.'}
    $predictors=@{}
    foreach($factorId in $FactorIds){
        $values=[double[]]::new($FitRows.Count)
        for($i=0;$i-lt$FitRows.Count;$i++){$values[$i]=Parse-CfaS9VerifyDouble $FitRows[$i].PSObject.Properties[$factorId].Value "$factorId fit row $i"}
        $stats=Get-CfaS9VerifyMeanSd $values $factorId
        if($stats.sd-le0){throw "Non-positive independent predictor SD: $factorId"}
        $predictors[$factorId]=[pscustomobject]@{center=$stats.mean;scale=$stats.sd}
    }
    $responseSum=0.0
    foreach($row in $FitRows){$responseSum+=Parse-CfaS9VerifyDouble $row.response_value_log_return 'fit response'}
    return [pscustomobject]@{predictors=$predictors;response_center=($responseSum/$FitRows.Count)}
}

function Convert-CfaS9VerifyProcessed {
    param([object[]]$Rows,$Spec,[string[]]$FactorIds)
    $n=$Rows.Count;$p=$FactorIds.Count;$matrix=[double[,]]::new($n,$p);$raw=[double[]]::new($n);$centered=[double[]]::new($n)
    for($i=0;$i-lt$n;$i++){
        $response=Parse-CfaS9VerifyDouble $Rows[$i].response_value_log_return "response row $i";$raw[$i]=$response;$centered[$i]=$response-[double]$Spec.response_center
        for($j=0;$j-lt$p;$j++){$factorId=$FactorIds[$j];$factorSpec=$Spec.predictors[$factorId];if($null-eq$factorSpec){throw "Missing independent preprocessing spec: $factorId"};$value=Parse-CfaS9VerifyDouble $Rows[$i].PSObject.Properties[$factorId].Value "$factorId row $i";$matrix[$i,$j]=($value-[double]$factorSpec.center)/[double]$factorSpec.scale}
    }
    return [pscustomobject]@{X=$matrix;y_raw=$raw;y_centered=$centered;response_center=[double]$Spec.response_center}
}

function Get-CfaS9VerifyPearson {
    param([double[]]$Left,[double[]]$Right,[string]$Label)
    if($Left.Count-ne$Right.Count-or$Left.Count-lt2){throw "$Label correlation vector mismatch."}
    $leftSum=0.0;$rightSum=0.0;for($i=0;$i-lt$Left.Count;$i++){$leftSum+=$Left[$i];$rightSum+=$Right[$i]};$leftMean=$leftSum/$Left.Count;$rightMean=$rightSum/$Right.Count
    $cross=0.0;$leftSq=0.0;$rightSq=0.0
    for($i=0;$i-lt$Left.Count;$i++){$ld=$Left[$i]-$leftMean;$rd=$Right[$i]-$rightMean;$cross+=$ld*$rd;$leftSq+=$ld*$ld;$rightSq+=$rd*$rd}
    if($leftSq-le0-or$rightSq-le0){return [double]::NaN};return $cross/[math]::Sqrt($leftSq*$rightSq)
}

function Get-CfaS9VerifyPositiveMedian {
    param([object[]]$FitRows,[string]$FactorId)
    $positive=New-Object System.Collections.ArrayList
    foreach($row in $FitRows){$value=Parse-CfaS9VerifyDouble $row.PSObject.Properties[$FactorId].Value "$FactorId positive median";if($value-gt0){[void]$positive.Add($value)}}
    if($positive.Count-lt1){throw "No positive independent fit values for $FactorId"}
    [double[]]$sorted=@($positive.ToArray()|Sort-Object);$count=$sorted.Count
    if(($count%2)-eq1){return [double]$sorted[[int](($count-1)/2)]};$left=[int]($count/2-1);$right=[int]($count/2);return ([double]$sorted[$left]+[double]$sorted[$right])/2.0
}

function Get-CfaS9VerifyFactorSummary {
    param([object[]]$Rows,[string]$FactorId,[string]$Surface)
    $n=$Rows.Count;$factor=[double[]]::new($n);$signed=[double[]]::new($n);$absolute=[double[]]::new($n);$zeros=0
    for($i=0;$i-lt$n;$i++){$fv=Parse-CfaS9VerifyDouble $Rows[$i].PSObject.Properties[$FactorId].Value "$FactorId diagnostic $i";$rv=Parse-CfaS9VerifyDouble $Rows[$i].response_value_log_return "diagnostic response $i";$factor[$i]=$fv;$signed[$i]=$rv;$absolute[$i]=[math]::Abs($rv);if($fv-eq0){$zeros++}}
    $stats=Get-CfaS9VerifyMeanSd $factor "$FactorId diagnostic";$min=($factor|Measure-Object -Minimum).Minimum;$max=($factor|Measure-Object -Maximum).Maximum
    return [pscustomobject]@{surface=$Surface;factor_id=$FactorId;n=$n;mean=$stats.mean;sample_sd=$stats.sd;min=[double]$min;max=[double]$max;zero_share=$zeros/[double]$n;pearson_signed_return=(Get-CfaS9VerifyPearson $factor $signed "$FactorId signed");pearson_absolute_return=(Get-CfaS9VerifyPearson $factor $absolute "$FactorId absolute")}
}

function Get-CfaS9VerifyIntensityGroups {
    param([object[]]$FitRows,[object[]]$EvalRows,[string]$FactorId,[string]$Surface)
    $median=Get-CfaS9VerifyPositiveMedian $FitRows $FactorId;$groups=@{ZERO=New-Object System.Collections.ArrayList;LOW_POSITIVE=New-Object System.Collections.ArrayList;HIGH_POSITIVE=New-Object System.Collections.ArrayList}
    foreach($row in $EvalRows){$factor=Parse-CfaS9VerifyDouble $row.PSObject.Properties[$FactorId].Value "$FactorId group factor";$response=Parse-CfaS9VerifyDouble $row.response_value_log_return "$FactorId group response";$group=if($factor-eq0){'ZERO'}elseif($factor-le$median){'LOW_POSITIVE'}else{'HIGH_POSITIVE'};[void]$groups[$group].Add($response)}
    $out=New-Object System.Collections.ArrayList
    foreach($group in @('ZERO','LOW_POSITIVE','HIGH_POSITIVE')){$values=$groups[$group];$signed=[double]::NaN;$absolute=[double]::NaN;if($values.Count-gt0){$signedSum=0.0;$absSum=0.0;foreach($value in $values){$signedSum+=[double]$value;$absSum+=[math]::Abs([double]$value)};$signed=$signedSum/$values.Count;$absolute=$absSum/$values.Count};[void]$out.Add([pscustomobject]@{surface=$Surface;factor_id=$FactorId;fit_positive_median=$median;intensity_group=$group;n=$values.Count;mean_signed_response=$signed;mean_absolute_response=$absolute})}
    return @($out.ToArray())
}

function Invoke-CfaS9VerifyFamily {
    param([string]$Surface,[string]$Family,[object[]]$FitRows,[object[]]$SelectionRows,[object[]]$EvalRows,[string[]]$FactorIds,[int]$MaxComponents)
    $selectionSpec=Get-CfaS9VerifyPreprocessSpec $FitRows $FactorIds;$fit=Convert-CfaS9VerifyProcessed $FitRows $selectionSpec $FactorIds;$selection=Convert-CfaS9VerifyProcessed $SelectionRows $selectionSpec $FactorIds;$path=Get-CfaIndependentPlsPath $fit.X $fit.y_centered $MaxComponents
    $selectionMetrics=New-Object System.Collections.ArrayList;$selected=0;$best=[double]::PositiveInfinity
    for($component=1;$component-le$MaxComponents;$component++){$beta=[double[]]$path.betas[$component-1];$prediction=Get-CfaIndependentPredictions $selection.X $beta $fit.response_center;$metric=Get-CfaIndependentMetrics $selection.y_raw $prediction $fit.response_center;[void]$selectionMetrics.Add([pscustomobject]@{surface=$Surface;family=$Family;phase='SELECTION_VALIDATION';components=$component;n=$metric.n;rmse=$metric.rmse;mae=$metric.mae;sse=$metric.sse;predictive_r2_vs_response_mean=$metric.predictive_r2});if($metric.rmse-lt$best){$best=$metric.rmse;$selected=$component}}
    if($selected-lt1){throw "$Surface $Family independent component selection failed."}
    $refitRows=@($FitRows+$SelectionRows);$evalSpec=Get-CfaS9VerifyPreprocessSpec $refitRows $FactorIds;$refit=Convert-CfaS9VerifyProcessed $refitRows $evalSpec $FactorIds;$eval=Convert-CfaS9VerifyProcessed $EvalRows $evalSpec $FactorIds;$refitPath=Get-CfaIndependentPlsPath $refit.X $refit.y_centered $selected;$beta=[double[]]$refitPath.betas[$selected-1];$predictions=Get-CfaIndependentPredictions $eval.X $beta $refit.response_center;$metric=Get-CfaIndependentMetrics $eval.y_raw $predictions $refit.response_center
    return [pscustomobject]@{surface=$Surface;family=$Family;selected_components=$selected;selection_metrics=@($selectionMetrics.ToArray());evaluation_metric=[pscustomobject]@{surface=$Surface;family=$Family;phase='EVALUATION';components=$selected;n=$metric.n;rmse=$metric.rmse;mae=$metric.mae;sse=$metric.sse;predictive_r2_vs_response_mean=$metric.predictive_r2};evaluation_predictions=$predictions}
}

function Get-CfaS9VerifyFamilies {
    param([string]$Surface,[object[]]$FitRows,[object[]]$SelectionRows,[object[]]$EvalRows)
    $result=@{}
    $result['S9_MARKET_ONLY']=Invoke-CfaS9VerifyFamily $Surface 'S9_MARKET_ONLY' $FitRows $SelectionRows $EvalRows $MarketFactors 4
    $result['S9_NEWS_ONLY']=Invoke-CfaS9VerifyFamily $Surface 'S9_NEWS_ONLY' $FitRows $SelectionRows $EvalRows $NewsFactors 3
    $result['S9_FULL_7']=Invoke-CfaS9VerifyFamily $Surface 'S9_FULL_7' $FitRows $SelectionRows $EvalRows $FullFactors 7
    return $result
}

function Assert-CfaS9VerifyMetricRow {
    param($Observed,$Expected,[string]$Label)
    foreach($name in @('rmse','mae','sse','predictive_r2_vs_response_mean')){$observedValue=Parse-CfaS9VerifyDouble $Observed.PSObject.Properties[$name].Value "$Label $name";$expectedValue=[double]$Expected.PSObject.Properties[$name].Value;if(-not(Test-CfaS9VerifyNear $observedValue $expectedValue)){throw "$Label $name mismatch: observed=$observedValue expected=$expectedValue"}}
}

function Invoke-CfaS9VerifySelfTest {
    if(-not(Test-CfaStage8IndependentCore)){throw 'Independent PLS core self-test failed.'}
    $rows=@([pscustomobject]@{response_value_log_return='-1';F1='0';F2='2'},[pscustomobject]@{response_value_log_return='1';F1='2';F2='4'},[pscustomobject]@{response_value_log_return='3';F1='4';F2='6'})
    $spec=Get-CfaS9VerifyPreprocessSpec $rows @('F1','F2');if(-not(Test-CfaS9VerifyNear ([double]$spec.response_center) 1.0)){throw 'Independent Stage 9 center self-test failed.'}
    $processed=Convert-CfaS9VerifyProcessed $rows $spec @('F1','F2');if($processed.X.GetLength(0)-ne3-or$processed.X.GetLength(1)-ne2){throw 'Independent Stage 9 matrix self-test failed.'}
    $median=Get-CfaS9VerifyPositiveMedian $rows 'F1';if(-not(Test-CfaS9VerifyNear $median 3.0)){throw 'Independent Stage 9 median self-test failed.'}
    $summary=Get-CfaS9VerifyFactorSummary $rows 'F1' 'SELFTEST';if($summary.n-ne3-or-not(Test-CfaS9VerifyNear $summary.zero_share (1.0/3.0))){throw 'Independent Stage 9 factor-summary self-test failed.'}
    return $true
}

if($SelfTest){try{if(-not(Invoke-CfaS9VerifySelfTest)){throw 'Independent Stage 9 self-test returned false.'};Write-Host 'SELF-TEST: PASS';exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try {
    $RunReceiptPath=Require-CfaS9VerifyFile $RunReceiptPath 'Stage 9 run receipt';$runReceiptSha=Get-CfaS9VerifySha $RunReceiptPath;$receipt=Get-Content -LiteralPath $RunReceiptPath -Raw|ConvertFrom-Json
    if([string]$receipt.status-ne'VALIDATION_CANDIDATE'-or[string]$receipt.stage-ne'CFA_STAGE_9'-or[string]$receipt.run-ne'NEWS_INCREMENTAL_V1'){throw 'Stage 9 run receipt identity mismatch.'}
    if([string]$receipt.interpretation-ne'POSTHOC_EXPLORATORY_LEAKAGE_CONTROLLED'){throw 'Stage 9 interpretation boundary mismatch.'}
    if([string]$receipt.sources.stage7_validation_receipt_sha256-ne$ExpectedStage7ValidationReceiptSha-or[string]$receipt.sources.stage8_validation_receipt_sha256-ne$ExpectedStage8ValidationReceiptSha-or[string]$receipt.sources.model_ready_sha256-ne$ExpectedModelReadySha){throw 'Stage 9 frozen source SHA mismatch.'}
    foreach($gate in 1..6){$id=('CFA-S9-{0:D3}'-f$gate);if([string]$receipt.gates.$id-ne'PASS'){throw "Stage 9 candidate gate is not PASS: $id"}}

    $stage7Path=Require-CfaS9VerifyFile ([string]$receipt.sources.stage7_validation_receipt) 'Stage 7 validation receipt';$stage8Path=Require-CfaS9VerifyFile ([string]$receipt.sources.stage8_validation_receipt) 'Stage 8 validation receipt';$modelPath=Require-CfaS9VerifyFile ([string]$receipt.sources.model_ready) 'Model-ready CSV'
    if((Get-CfaS9VerifySha $stage7Path)-ne$ExpectedStage7ValidationReceiptSha-or(Get-CfaS9VerifySha $stage8Path)-ne$ExpectedStage8ValidationReceiptSha-or(Get-CfaS9VerifySha $modelPath)-ne$ExpectedModelReadySha){throw 'Stage 9 frozen source file SHA mismatch.'}
    $stage8=Get-Content -LiteralPath $stage8Path -Raw|ConvertFrom-Json;if([string]$stage8.candidate_outputs.selected_model_sha256-ne$ExpectedStage8SelectedModelSha-or[int]$stage8.design.independently_selected_components-ne3-or[bool]$stage8.design.test_used_for_selection){throw 'Frozen Stage 8 result identity mismatch.'}

    $outputChecks=@(
        @('nested_day_roles','nested_day_roles_sha256'),@('component_metrics','component_metrics_sha256'),@('evaluation_metrics','evaluation_metrics_sha256'),@('evaluation_predictions','evaluation_predictions_sha256'),@('incremental_comparison','incremental_comparison_sha256'),@('factor_diagnostics','factor_diagnostics_sha256'),@('intensity_groups','intensity_groups_sha256'),@('posthoc_metrics','posthoc_metrics_sha256')
    );$paths=@{}
    foreach($pair in $outputChecks){$pathName=[string]$pair[0];$shaName=[string]$pair[1];$path=Require-CfaS9VerifyFile ([string]$receipt.outputs.PSObject.Properties[$pathName].Value) "Stage 9 $pathName";if((Get-CfaS9VerifySha $path)-ne[string]$receipt.outputs.PSObject.Properties[$shaName].Value){throw "Stage 9 output hash mismatch: $pathName"};$paths[$pathName]=$path}

    $model=@(Import-Csv -LiteralPath $modelPath);if($model.Count-ne26337){throw 'Stage 9 frozen model-ready count mismatch.'};$train=@($model|Where-Object{[string]$_.design_role-eq'TRAIN'});$validation=@($model|Where-Object{[string]$_.design_role-eq'VALIDATION'});$test=@($model|Where-Object{[string]$_.design_role-eq'TEST'});if($train.Count-ne15648-or$validation.Count-ne5323-or$test.Count-ne5366){throw 'Stage 9 frozen role count mismatch.'}
    $trainDays=@($train|ForEach-Object{[string]$_.response_day_utc}|Sort-Object -Unique);if($trainDays.Count-ne40){throw 'Stage 9 expected 40 TRAIN days.'}
    $roleByDay=@{};$expectedDayRoles=New-Object System.Collections.ArrayList
    for($i=0;$i-lt40;$i++){$ordinal=$i+1;$role=if($ordinal-le17){'S9_DEV_TRAIN'}elseif($ordinal-eq18){'S9_EMBARGO_DEV_SELECTION'}elseif($ordinal-le26){'S9_SELECTION_VALIDATION'}elseif($ordinal-eq27){'S9_EMBARGO_SELECTION_EVALUATION'}else{'S9_INTERNAL_EVALUATION'};$day=$trainDays[$i];$roleByDay[$day]=$role;$dayRows=@($train|Where-Object{[string]$_.response_day_utc-ceq$day});$bases=@($dayRows|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique).Count;[void]$expectedDayRoles.Add([pscustomobject]@{day_ordinal=$ordinal;response_day_utc=$day;stage9_role=$role;rows=$dayRows.Count;bases=$bases})}
    $dev=@($train|Where-Object{$roleByDay[[string]$_.response_day_utc]-eq'S9_DEV_TRAIN'});$selection=@($train|Where-Object{$roleByDay[[string]$_.response_day_utc]-eq'S9_SELECTION_VALIDATION'});$nestedEval=@($train|Where-Object{$roleByDay[[string]$_.response_day_utc]-eq'S9_INTERNAL_EVALUATION'});$embargo=@($train|Where-Object{$roleByDay[[string]$_.response_day_utc]-like'S9_EMBARGO_*'})
    if($dev.Count-ne6475-or$selection.Count-ne3140-or$nestedEval.Count-ne5246-or$embargo.Count-ne787){throw "Independent nested row counts mismatch: $($dev.Count)/$($selection.Count)/$($nestedEval.Count)/$($embargo.Count)"}
    if([string]$receipt.nested_split.embargo_1_day-ne$trainDays[17]-or[string]$receipt.nested_split.embargo_2_day-ne$trainDays[26]){throw 'Stage 9 nested embargo-day receipt mismatch.'}
    $candidateDayRoles=@(Import-Csv -LiteralPath $paths.nested_day_roles);if($candidateDayRoles.Count-ne40){throw 'Stage 9 day-role CSV count mismatch.'};for($i=0;$i-lt40;$i++){$expected=$expectedDayRoles[$i];$observed=$candidateDayRoles[$i];if([int]$observed.day_ordinal-ne$expected.day_ordinal-or[string]$observed.response_day_utc-cne$expected.response_day_utc-or[string]$observed.stage9_role-cne$expected.stage9_role-or[int]$observed.rows-ne$expected.rows-or[int]$observed.bases-ne$expected.bases){throw "Stage 9 day-role mismatch at ordinal $($i+1)"}}

    $nested=Get-CfaS9VerifyFamilies 'NESTED_TRAIN' $dev $selection $nestedEval;$posthoc=Get-CfaS9VerifyFamilies 'POSTHOC_STAGE8_SPLIT' $train $validation $test
    $expectedComponents=@{NESTED_TRAIN=@{'S9_MARKET_ONLY'=2;'S9_NEWS_ONLY'=1;'S9_FULL_7'=3};POSTHOC_STAGE8_SPLIT=@{'S9_MARKET_ONLY'=2;'S9_NEWS_ONLY'=1;'S9_FULL_7'=3}}
    foreach($surface in @('NESTED_TRAIN','POSTHOC_STAGE8_SPLIT')){$set=if($surface-eq'NESTED_TRAIN'){$nested}else{$posthoc};foreach($family in @('S9_MARKET_ONLY','S9_NEWS_ONLY','S9_FULL_7')){if($set[$family].selected_components-ne$expectedComponents[$surface][$family]){throw "$surface $family selected-component mismatch."}}}

    $componentRows=@(Import-Csv -LiteralPath $paths.component_metrics);if($componentRows.Count-ne28){throw "Stage 9 component metric row count mismatch: $($componentRows.Count)"};$cursor=0
    foreach($surface in @('NESTED_TRAIN','POSTHOC_STAGE8_SPLIT')){$set=if($surface-eq'NESTED_TRAIN'){$nested}else{$posthoc};foreach($family in @('S9_MARKET_ONLY','S9_NEWS_ONLY','S9_FULL_7')){foreach($expected in $set[$family].selection_metrics){$observed=$componentRows[$cursor];if([string]$observed.surface-cne$expected.surface-or[string]$observed.family-cne$expected.family-or[string]$observed.phase-cne'SELECTION_VALIDATION'-or[int]$observed.components-ne$expected.components-or[int]$observed.n-ne$expected.n){throw "Stage 9 component row identity mismatch at $cursor"};Assert-CfaS9VerifyMetricRow $observed $expected "component row $cursor";$cursor++}}}

    $evaluationRows=@(Import-Csv -LiteralPath $paths.evaluation_metrics);if($evaluationRows.Count-ne6){throw 'Stage 9 evaluation metric row count mismatch.'};$cursor=0
    foreach($surface in @('NESTED_TRAIN','POSTHOC_STAGE8_SPLIT')){$set=if($surface-eq'NESTED_TRAIN'){$nested}else{$posthoc};foreach($family in @('S9_MARKET_ONLY','S9_NEWS_ONLY','S9_FULL_7')){$expected=$set[$family].evaluation_metric;$observed=$evaluationRows[$cursor];if([string]$observed.surface-cne$surface-or[string]$observed.family-cne$family-or[string]$observed.phase-cne'EVALUATION'-or[int]$observed.components-ne$expected.components-or[int]$observed.n-ne$expected.n){throw "Stage 9 evaluation row identity mismatch at $cursor"};Assert-CfaS9VerifyMetricRow $observed $expected "evaluation row $cursor";$cursor++}}

    $predictionRows=@(Import-Csv -LiteralPath $paths.evaluation_predictions);$expectedPredictionCount=($nestedEval.Count*3)+($test.Count*3);if($predictionRows.Count-ne$expectedPredictionCount){throw "Stage 9 prediction row count mismatch: $($predictionRows.Count) expected=$expectedPredictionCount"};$cursor=0
    foreach($surfaceSpec in @([pscustomobject]@{surface='NESTED_TRAIN';set=$nested;rows=$nestedEval},[pscustomobject]@{surface='POSTHOC_STAGE8_SPLIT';set=$posthoc;rows=$test})){
        foreach($family in @('S9_MARKET_ONLY','S9_NEWS_ONLY','S9_FULL_7')){$pred=[double[]]$surfaceSpec.set[$family].evaluation_predictions;for($i=0;$i-lt$surfaceSpec.rows.Count;$i++){$observed=$predictionRows[$cursor];$source=$surfaceSpec.rows[$i];if([string]$observed.surface-cne$surfaceSpec.surface-or[string]$observed.family-cne$family-or[string]$observed.base_asset_id-cne[string]$source.base_asset_id-or[string]$observed.response_day_utc-cne[string]$source.response_day_utc){throw "Stage 9 prediction key/order mismatch at row $cursor"};$actual=Parse-CfaS9VerifyDouble $observed.actual_response "prediction actual $cursor";$sourceActual=Parse-CfaS9VerifyDouble $source.response_value_log_return "source actual $cursor";$estimate=Parse-CfaS9VerifyDouble $observed.prediction "prediction value $cursor";if(-not(Test-CfaS9VerifyNear $actual $sourceActual)-or-not(Test-CfaS9VerifyNear $estimate $pred[$i])){throw "Stage 9 prediction value mismatch at row $cursor"};$cursor++}}
    }

    $incrementalRows=@(Import-Csv -LiteralPath $paths.incremental_comparison);if($incrementalRows.Count-ne2){throw 'Stage 9 incremental comparison row count mismatch.'}
    $independentIncremental=@{}
    foreach($surface in @('NESTED_TRAIN','POSTHOC_STAGE8_SPLIT')){$set=if($surface-eq'NESTED_TRAIN'){$nested}else{$posthoc};$market=$set['S9_MARKET_ONLY'].evaluation_metric;$news=$set['S9_NEWS_ONLY'].evaluation_metric;$full=$set['S9_FULL_7'].evaluation_metric;$independentIncremental[$surface]=[pscustomobject]@{surface=$surface;market_selected_components=$set['S9_MARKET_ONLY'].selected_components;news_selected_components=$set['S9_NEWS_ONLY'].selected_components;full_selected_components=$set['S9_FULL_7'].selected_components;market_rmse=$market.rmse;news_rmse=$news.rmse;full_rmse=$full.rmse;delta_rmse_full_minus_market=($full.rmse-$market.rmse);delta_mae_full_minus_market=($full.mae-$market.mae);incremental_r2_news_over_market=(1.0-$full.sse/$market.sse);news_predictive_r2_vs_response_mean=$news.predictive_r2_vs_response_mean}}
    for($i=0;$i-lt2;$i++){$surface=if($i-eq0){'NESTED_TRAIN'}else{'POSTHOC_STAGE8_SPLIT'};$expected=$independentIncremental[$surface];$observed=$incrementalRows[$i];if([string]$observed.surface-cne$surface-or[int]$observed.market_selected_components-ne$expected.market_selected_components-or[int]$observed.news_selected_components-ne$expected.news_selected_components-or[int]$observed.full_selected_components-ne$expected.full_selected_components){throw "$surface incremental identity mismatch."};foreach($name in @('market_rmse','news_rmse','full_rmse','delta_rmse_full_minus_market','delta_mae_full_minus_market','incremental_r2_news_over_market','news_predictive_r2_vs_response_mean')){$ov=Parse-CfaS9VerifyDouble $observed.PSObject.Properties[$name].Value "$surface $name";$ev=[double]$expected.PSObject.Properties[$name].Value;if(-not(Test-CfaS9VerifyNear $ov $ev)){throw "$surface $name mismatch: observed=$ov expected=$ev"}}}

    $factorRows=@(Import-Csv -LiteralPath $paths.factor_diagnostics);if($factorRows.Count-ne6){throw 'Stage 9 factor diagnostic row count mismatch.'};$expectedFactorRows=New-Object System.Collections.ArrayList
    foreach($surfaceSpec in @([pscustomobject]@{surface='NESTED_TRAIN';rows=$nestedEval},[pscustomobject]@{surface='POSTHOC_STAGE8_SPLIT';rows=$test})){foreach($factorId in $NewsFactors){[void]$expectedFactorRows.Add((Get-CfaS9VerifyFactorSummary $surfaceSpec.rows $factorId $surfaceSpec.surface))}}
    for($i=0;$i-lt6;$i++){$o=$factorRows[$i];$e=$expectedFactorRows[$i];if([string]$o.surface-cne$e.surface-or[string]$o.factor_id-cne$e.factor_id-or[int]$o.n-ne$e.n){throw "Stage 9 factor diagnostic identity mismatch at $i"};foreach($name in @('mean','sample_sd','min','max','zero_share')){$ov=Parse-CfaS9VerifyDouble $o.PSObject.Properties[$name].Value "factor $i $name";$ev=[double]$e.PSObject.Properties[$name].Value;if(-not(Test-CfaS9VerifyNear $ov $ev)){throw "Stage 9 factor $i $name mismatch"}};Test-CfaS9VerifyMaybeNaN $o.pearson_signed_return ([double]$e.pearson_signed_return) "factor $i signed correlation";Test-CfaS9VerifyMaybeNaN $o.pearson_absolute_return ([double]$e.pearson_absolute_return) "factor $i absolute correlation"}

    $intensityRows=@(Import-Csv -LiteralPath $paths.intensity_groups);if($intensityRows.Count-ne18){throw 'Stage 9 intensity-group row count mismatch.'};$expectedIntensity=New-Object System.Collections.ArrayList;$nestedFit=@($dev+$selection);$posthocFit=@($train+$validation)
    foreach($surfaceSpec in @([pscustomobject]@{surface='NESTED_TRAIN';fit=$nestedFit;eval=$nestedEval},[pscustomobject]@{surface='POSTHOC_STAGE8_SPLIT';fit=$posthocFit;eval=$test})){foreach($factorId in $NewsFactors){foreach($row in (Get-CfaS9VerifyIntensityGroups $surfaceSpec.fit $surfaceSpec.eval $factorId $surfaceSpec.surface)){[void]$expectedIntensity.Add($row)}}}
    for($i=0;$i-lt18;$i++){$o=$intensityRows[$i];$e=$expectedIntensity[$i];if([string]$o.surface-cne$e.surface-or[string]$o.factor_id-cne$e.factor_id-or[string]$o.intensity_group-cne$e.intensity_group-or[int]$o.n-ne$e.n){throw "Stage 9 intensity identity mismatch at $i"};$median=Parse-CfaS9VerifyDouble $o.fit_positive_median "intensity $i median";if(-not(Test-CfaS9VerifyNear $median ([double]$e.fit_positive_median))){throw "Stage 9 intensity median mismatch at $i"};Test-CfaS9VerifyMaybeNaN $o.mean_signed_response ([double]$e.mean_signed_response) "intensity $i signed mean";Test-CfaS9VerifyMaybeNaN $o.mean_absolute_response ([double]$e.mean_absolute_response) "intensity $i absolute mean"}

    $posthocRows=@(Import-Csv -LiteralPath $paths.posthoc_metrics);if($posthocRows.Count-ne3){throw 'Stage 9 posthoc metrics row count mismatch.'};for($i=0;$i-lt3;$i++){$expected=$posthoc[@('S9_MARKET_ONLY','S9_NEWS_ONLY','S9_FULL_7')[$i]].evaluation_metric;$observed=$posthocRows[$i];if([string]$observed.surface-cne'POSTHOC_STAGE8_SPLIT'-or[string]$observed.family-cne$expected.family){throw "Stage 9 posthoc metric identity mismatch at $i"};Assert-CfaS9VerifyMetricRow $observed $expected "posthoc row $i"}

    $nestedInc=$independentIncremental['NESTED_TRAIN'];$posthocInc=$independentIncremental['POSTHOC_STAGE8_SPLIT']
    foreach($check in @(@($receipt.nested_results,$nestedInc,'nested'),@($receipt.posthoc_stage8_results,$posthocInc,'posthoc'))){$observed=$check[0];$expected=$check[1];$label=$check[2];if([int]$observed.market_selected_components-ne$expected.market_selected_components-or[int]$observed.news_selected_components-ne$expected.news_selected_components-or[int]$observed.full_selected_components-ne$expected.full_selected_components){throw "$label receipt component mismatch."};foreach($name in @('delta_rmse_full_minus_market','incremental_r2_news_over_market','news_predictive_r2_vs_response_mean')){$ov=Parse-CfaS9VerifyDouble $observed.PSObject.Properties[$name].Value "$label receipt $name";$ev=[double]$expected.PSObject.Properties[$name].Value;if(-not(Test-CfaS9VerifyNear $ov $ev)){throw "$label receipt $name mismatch."}}}

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Split-Path -Parent $RunReceiptPath};if(-not(Test-Path -LiteralPath $OutputRoot)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $checksPath=Join-Path $OutputRoot 'stage9-news-incremental-independent-validation-checks.csv';$validationPath=Join-Path $OutputRoot 'stage9-news-incremental-independent-validation.json'
    $checks=@(
        [pscustomobject]@{check_id='FROZEN_ENTRY';status='PASS';detail='Stage 7, Stage 8 and model-ready hashes reconciled'},
        [pscustomobject]@{check_id='NESTED_ROLES';status='PASS';detail='40 TRAIN days and two embargoes independently reproduced'},
        [pscustomobject]@{check_id='MODEL_FAMILIES';status='PASS';detail='Market-only, news-only and full PLS component paths independently recomputed on both surfaces'},
        [pscustomobject]@{check_id='INCREMENTAL_ESTIMANDS';status='PASS';detail='Delta RMSE/MAE and incremental R2 independently reproduced'},
        [pscustomobject]@{check_id='PREDICTIONS';status='PASS';detail='All nested and posthoc evaluation keys and PLS predictions reconciled'},
        [pscustomobject]@{check_id='FACTOR_DIAGNOSTICS';status='PASS';detail='News summaries and signed/absolute correlations independently reproduced'},
        [pscustomobject]@{check_id='INTENSITY_GROUPS';status='PASS';detail='Positive medians, group membership counts and response means independently reproduced'},
        [pscustomobject]@{check_id='OUTPUT_HASHES';status='PASS';detail='All Stage 9 candidate output hashes reconcile with run receipt'},
        [pscustomobject]@{check_id='INTERPRETATION_BOUNDARY';status='PASS';detail='Result remains POSTHOC / EXPLORATORY / LEAKAGE-CONTROLLED; no fresh external holdout exists'}
    );$checks|Export-Csv -LiteralPath $checksPath -NoTypeInformation -Encoding UTF8
    $validationReceipt=[ordered]@{status='PASS';stage='CFA_STAGE_9';validation='INDEPENDENT_NEWS_INCREMENTAL_V1';interpretation='POSTHOC_EXPLORATORY_LEAKAGE_CONTROLLED';run_receipt=$RunReceiptPath;run_receipt_sha256=$runReceiptSha;frozen_sources=[ordered]@{stage7_validation_receipt_sha256=$ExpectedStage7ValidationReceiptSha;stage8_validation_receipt_sha256=$ExpectedStage8ValidationReceiptSha;model_ready_sha256=$ExpectedModelReadySha;stage8_selected_model_sha256=$ExpectedStage8SelectedModelSha};nested_results=[ordered]@{market_selected_components=$nestedInc.market_selected_components;news_selected_components=$nestedInc.news_selected_components;full_selected_components=$nestedInc.full_selected_components;delta_rmse_full_minus_market=$nestedInc.delta_rmse_full_minus_market;delta_mae_full_minus_market=$nestedInc.delta_mae_full_minus_market;incremental_r2_news_over_market=$nestedInc.incremental_r2_news_over_market;news_predictive_r2_vs_response_mean=$nestedInc.news_predictive_r2_vs_response_mean};posthoc_stage8_results=[ordered]@{market_selected_components=$posthocInc.market_selected_components;news_selected_components=$posthocInc.news_selected_components;full_selected_components=$posthocInc.full_selected_components;delta_rmse_full_minus_market=$posthocInc.delta_rmse_full_minus_market;delta_mae_full_minus_market=$posthocInc.delta_mae_full_minus_market;incremental_r2_news_over_market=$posthocInc.incremental_r2_news_over_market;news_predictive_r2_vs_response_mean=$posthocInc.news_predictive_r2_vs_response_mean};candidate_output_hashes=[ordered]@{nested_day_roles_sha256=(Get-CfaS9VerifySha $paths.nested_day_roles);component_metrics_sha256=(Get-CfaS9VerifySha $paths.component_metrics);evaluation_metrics_sha256=(Get-CfaS9VerifySha $paths.evaluation_metrics);evaluation_predictions_sha256=(Get-CfaS9VerifySha $paths.evaluation_predictions);incremental_comparison_sha256=(Get-CfaS9VerifySha $paths.incremental_comparison);factor_diagnostics_sha256=(Get-CfaS9VerifySha $paths.factor_diagnostics);intensity_groups_sha256=(Get-CfaS9VerifySha $paths.intensity_groups);posthoc_metrics_sha256=(Get-CfaS9VerifySha $paths.posthoc_metrics)};validation_checks=$checksPath;validation_checks_sha256=(Get-CfaS9VerifySha $checksPath);gates=[ordered]@{'CFA-S9-001'='PASS';'CFA-S9-002'='PASS';'CFA-S9-003'='PASS';'CFA-S9-004'='PASS';'CFA-S9-005'='PASS';'CFA-S9-006'='PASS';'CFA-S9-007'='PASS';'CFA-S9-008'='UNVERIFIED'};next_action='Pin exact Stage 9 run and independent-validation hashes in repository evidence, then freeze the exploratory research findings without changing the estimands.'}
    [IO.File]::WriteAllText($validationPath,(($validationReceipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
    $validationSha=Get-CfaS9VerifySha $validationPath
    Write-Host ''
    Write-Host 'CFA STAGE 9 INDEPENDENT NEWS-INCREMENTAL VALIDATION: PASS'
    Write-Host "Nested rows dev / selection / eval / embargo: $($dev.Count) / $($selection.Count) / $($nestedEval.Count) / $($embargo.Count)"
    Write-Host "Nested selected components market / news / full: $($nestedInc.market_selected_components) / $($nestedInc.news_selected_components) / $($nestedInc.full_selected_components)"
    Write-Host "Nested delta RMSE full-minus-market: $($nestedInc.delta_rmse_full_minus_market.ToString('R',$Invariant))"
    Write-Host "Nested incremental R2 news-over-market: $($nestedInc.incremental_r2_news_over_market.ToString('R',$Invariant))"
    Write-Host "Nested news-only predictive R2 vs response mean: $($nestedInc.news_predictive_r2_vs_response_mean.ToString('R',$Invariant))"
    Write-Host "Posthoc selected components market / news / full: $($posthocInc.market_selected_components) / $($posthocInc.news_selected_components) / $($posthocInc.full_selected_components)"
    Write-Host "Posthoc delta RMSE full-minus-market: $($posthocInc.delta_rmse_full_minus_market.ToString('R',$Invariant))"
    Write-Host "Posthoc incremental R2 news-over-market: $($posthocInc.incremental_r2_news_over_market.ToString('R',$Invariant))"
    Write-Host "Posthoc news-only predictive R2 vs response mean: $($posthocInc.news_predictive_r2_vs_response_mean.ToString('R',$Invariant))"
    Write-Host 'Interpretation status: POSTHOC / EXPLORATORY / LEAKAGE-CONTROLLED'
    Write-Host 'CFA-S9-007 independent validation: PASS'
    Write-Host 'CFA-S9-008 research findings freeze: UNVERIFIED'
    Write-Host "Run receipt SHA-256: $runReceiptSha"
    foreach($pair in $outputChecks){$name=[string]$pair[0];Write-Host "$name SHA-256: $(Get-CfaS9VerifySha $paths[$name])"}
    Write-Host "Validation checks SHA-256: $(Get-CfaS9VerifySha $checksPath)"
    Write-Host "Validation receipt SHA-256: $validationSha"
    Write-Host "Validation checks: $checksPath"
    Write-Host "Validation receipt: $validationPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 9 INDEPENDENT NEWS-INCREMENTAL VALIDATION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
