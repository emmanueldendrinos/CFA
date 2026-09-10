Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CfaStage9Invariant=[Globalization.CultureInfo]::InvariantCulture

function Get-CfaStage9Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Require-CfaStage9File { param([string]$Path,[string]$Label); $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath; if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"}; return $resolved }
function Parse-CfaStage9Double { param([object]$Value,[string]$Label); $parsed=0.0; if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$script:CfaStage9Invariant,[ref]$parsed)){throw "Malformed numeric for ${Label}: '$Value'"}; if([double]::IsNaN($parsed)-or[double]::IsInfinity($parsed)){throw "Non-finite numeric for ${Label}: '$Value'"}; return $parsed }

function Get-CfaStage9MeanSd {
    param([double[]]$Values,[string]$Label)
    if($Values.Count -lt 2){throw "$Label requires at least two values."}
    $sum=0.0
    foreach($value in $Values){$sum += $value}
    $mean=$sum/$Values.Count
    $sumSq=0.0
    foreach($value in $Values){$delta=$value-$mean;$sumSq += $delta*$delta}
    $sd=[math]::Sqrt($sumSq/($Values.Count-1))
    if([double]::IsNaN($mean)-or[double]::IsInfinity($mean)-or[double]::IsNaN($sd)-or[double]::IsInfinity($sd)){throw "$Label produced non-finite statistics."}
    return [pscustomobject]@{n=$Values.Count;mean=$mean;sd=$sd}
}

function Get-CfaStage9PreprocessSpec {
    param([object[]]$FitRows,[string[]]$FactorIds)
    if($FitRows.Count -lt 2){throw 'Stage 9 fit population is too small.'}
    $predictorSpecs=@{}
    foreach($factorId in $FactorIds){
        $values=[double[]]::new($FitRows.Count)
        for($rowIndex=0;$rowIndex -lt $FitRows.Count;$rowIndex++){$values[$rowIndex]=Parse-CfaStage9Double $FitRows[$rowIndex].PSObject.Properties[$factorId].Value "$factorId fit row $rowIndex"}
        $stats=Get-CfaStage9MeanSd $values $factorId
        if($stats.sd -le 0){throw "Non-positive fitted predictor SD: $factorId"}
        $predictorSpecs[$factorId]=[pscustomobject]@{center=$stats.mean;scale=$stats.sd;n=$stats.n}
    }
    $responseValues=[double[]]::new($FitRows.Count)
    for($rowIndex=0;$rowIndex -lt $FitRows.Count;$rowIndex++){$responseValues[$rowIndex]=Parse-CfaStage9Double $FitRows[$rowIndex].response_value_log_return "response fit row $rowIndex"}
    $responseSum=0.0;foreach($value in $responseValues){$responseSum += $value};$responseCenter=$responseSum/$responseValues.Count
    return [pscustomobject]@{predictors=$predictorSpecs;response_center=$responseCenter;fit_n=$FitRows.Count}
}

function Convert-CfaStage9ProcessedData {
    param([object[]]$Rows,$Spec,[string[]]$FactorIds)
    $rowCount=$Rows.Count;$predictorCount=$FactorIds.Count
    $matrix=[double[,]]::new($rowCount,$predictorCount)
    $responseRaw=[double[]]::new($rowCount)
    $responseCentered=[double[]]::new($rowCount)
    for($rowIndex=0;$rowIndex -lt $rowCount;$rowIndex++){
        $responseValue=Parse-CfaStage9Double $Rows[$rowIndex].response_value_log_return "response row $rowIndex"
        $responseRaw[$rowIndex]=$responseValue
        $responseCentered[$rowIndex]=$responseValue-[double]$Spec.response_center
        for($factorIndex=0;$factorIndex -lt $predictorCount;$factorIndex++){
            $factorId=$FactorIds[$factorIndex]
            $factorSpec=$Spec.predictors[$factorId]
            if($null -eq $factorSpec){throw "Missing preprocessing spec for $factorId"}
            $factorValue=Parse-CfaStage9Double $Rows[$rowIndex].PSObject.Properties[$factorId].Value "$factorId row $rowIndex"
            $matrix[$rowIndex,$factorIndex]=($factorValue-[double]$factorSpec.center)/[double]$factorSpec.scale
        }
    }
    return [pscustomobject]@{X=$matrix;y_raw=$responseRaw;y_centered=$responseCentered;response_center=[double]$Spec.response_center}
}

function Get-CfaStage9Pearson {
    param([double[]]$Left,[double[]]$Right,[string]$Label)
    if($Left.Count -ne $Right.Count -or $Left.Count -lt 2){throw "$Label correlation vector mismatch."}
    $leftMean=($Left|Measure-Object -Average).Average;$rightMean=($Right|Measure-Object -Average).Average
    $cross=0.0;$leftSq=0.0;$rightSq=0.0
    for($index=0;$index -lt $Left.Count;$index++){$leftDelta=$Left[$index]-$leftMean;$rightDelta=$Right[$index]-$rightMean;$cross += $leftDelta*$rightDelta;$leftSq += $leftDelta*$leftDelta;$rightSq += $rightDelta*$rightDelta}
    if($leftSq -le 0 -or $rightSq -le 0){return [double]::NaN}
    return $cross/[math]::Sqrt($leftSq*$rightSq)
}

function Get-CfaStage9PositiveMedian {
    param([object[]]$FitRows,[string]$FactorId)
    $positive=New-Object System.Collections.ArrayList
    foreach($row in $FitRows){$value=Parse-CfaStage9Double $row.PSObject.Properties[$FactorId].Value "$FactorId positive median";if($value -gt 0){[void]$positive.Add($value)}}
    if($positive.Count -lt 1){throw "No positive fit values for $FactorId"}
    [double[]]$sorted=@($positive.ToArray()|Sort-Object)
    $count=$sorted.Count
    if(($count % 2)-eq1){return [double]$sorted[[int](($count-1)/2)]}
    $leftIndex=[int]($count/2-1);$rightIndex=[int]($count/2)
    return ([double]$sorted[$leftIndex]+[double]$sorted[$rightIndex])/2.0
}

function Get-CfaStage9FactorSummary {
    param([object[]]$Rows,[string]$FactorId,[string]$Surface)
    $count=$Rows.Count
    $factorValues=[double[]]::new($count);$signed=[double[]]::new($count);$absolute=[double[]]::new($count)
    $zeroCount=0
    for($index=0;$index -lt $count;$index++){
        $factorValue=Parse-CfaStage9Double $Rows[$index].PSObject.Properties[$FactorId].Value "$FactorId diagnostic row $index"
        $responseValue=Parse-CfaStage9Double $Rows[$index].response_value_log_return "response diagnostic row $index"
        $factorValues[$index]=$factorValue;$signed[$index]=$responseValue;$absolute[$index]=[math]::Abs($responseValue);if($factorValue -eq 0){$zeroCount++}
    }
    $stats=Get-CfaStage9MeanSd $factorValues "$FactorId diagnostic"
    $min=($factorValues|Measure-Object -Minimum).Minimum;$max=($factorValues|Measure-Object -Maximum).Maximum
    $corrSigned=Get-CfaStage9Pearson $factorValues $signed "$FactorId signed"
    $corrAbs=Get-CfaStage9Pearson $factorValues $absolute "$FactorId absolute"
    return [pscustomobject][ordered]@{surface=$Surface;factor_id=$FactorId;n=$count;mean=$stats.mean;sample_sd=$stats.sd;min=$min;max=$max;zero_share=($zeroCount/[double]$count);pearson_signed_return=$corrSigned;pearson_absolute_return=$corrAbs}
}

function Get-CfaStage9IntensityGroups {
    param([object[]]$FitRows,[object[]]$EvalRows,[string]$FactorId,[string]$Surface)
    $positiveMedian=Get-CfaStage9PositiveMedian $FitRows $FactorId
    $groupValues=@{ZERO=New-Object System.Collections.ArrayList;LOW_POSITIVE=New-Object System.Collections.ArrayList;HIGH_POSITIVE=New-Object System.Collections.ArrayList}
    foreach($row in $EvalRows){
        $factorValue=Parse-CfaStage9Double $row.PSObject.Properties[$FactorId].Value "$FactorId group value"
        $responseValue=Parse-CfaStage9Double $row.response_value_log_return "$FactorId group response"
        $group=if($factorValue -eq 0){'ZERO'}elseif($factorValue -le $positiveMedian){'LOW_POSITIVE'}else{'HIGH_POSITIVE'}
        [void]$groupValues[$group].Add($responseValue)
    }
    $rows=New-Object System.Collections.ArrayList
    foreach($group in @('ZERO','LOW_POSITIVE','HIGH_POSITIVE')){
        $values=$groupValues[$group];$signedMean=[double]::NaN;$absoluteMean=[double]::NaN
        if($values.Count -gt 0){$signedSum=0.0;$absoluteSum=0.0;foreach($value in $values){$signedSum += [double]$value;$absoluteSum += [math]::Abs([double]$value)};$signedMean=$signedSum/$values.Count;$absoluteMean=$absoluteSum/$values.Count}
        [void]$rows.Add([pscustomobject][ordered]@{surface=$Surface;factor_id=$FactorId;fit_positive_median=$positiveMedian;intensity_group=$group;n=$values.Count;mean_signed_response=$signedMean;mean_absolute_response=$absoluteMean})
    }
    return @($rows.ToArray())
}

function Test-CfaStage9AnalysisData {
    $rows=@(
        [pscustomobject]@{response_value_log_return='-1';F1='0';F2='2'},
        [pscustomobject]@{response_value_log_return='1';F1='2';F2='4'},
        [pscustomobject]@{response_value_log_return='3';F1='4';F2='6'}
    )
    $spec=Get-CfaStage9PreprocessSpec $rows @('F1','F2')
    if([math]::Abs([double]$spec.response_center-1.0)-gt1e-12){throw 'Stage 9 response-center self-test failed.'}
    $processed=Convert-CfaStage9ProcessedData $rows $spec @('F1','F2')
    if($processed.X.GetLength(0)-ne3-or$processed.X.GetLength(1)-ne2){throw 'Stage 9 processed matrix dimension self-test failed.'}
    $cell00=$processed.X[0,0];$cell20=$processed.X[2,0]
    if([math]::Abs($cell00+1.0)-gt1e-12-or[math]::Abs($cell20-1.0)-gt1e-12){throw 'Stage 9 predictor standardization self-test failed.'}
    $median=Get-CfaStage9PositiveMedian $rows 'F1';if([math]::Abs($median-3.0)-gt1e-12){throw 'Stage 9 positive-median self-test failed.'}
    $summary=Get-CfaStage9FactorSummary $rows 'F1' 'SELFTEST';if($summary.n-ne3-or[math]::Abs($summary.zero_share-(1.0/3.0))-gt1e-12){throw 'Stage 9 factor-summary self-test failed.'}
    return $true
}
