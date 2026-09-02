Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CfaIndependentTolerance=1e-12

function Solve-CfaIndependentSystem {
    param($CoefficientMatrix,[double[]]$RightSide,[int]$Dimension)
    $work=[double[,]]::new($Dimension,$Dimension+1)
    for($row=0;$row -lt $Dimension;$row++){
        for($col=0;$col -lt $Dimension;$col++){$work[$row,$col]=$CoefficientMatrix[$row,$col]}
        $work[$row,$Dimension]=$RightSide[$row]
    }
    for($col=0;$col -lt $Dimension;$col++){
        $pivotRow=$col
        $pivotValue=$work[$col,$col]
        $pivotAbs=[math]::Abs($pivotValue)
        for($candidate=$col+1;$candidate -lt $Dimension;$candidate++){
            $cell=$work[$candidate,$col]
            $cellAbs=[math]::Abs($cell)
            if($cellAbs -gt $pivotAbs){$pivotAbs=$cellAbs;$pivotRow=$candidate}
        }
        if($pivotAbs -le $script:CfaIndependentTolerance){throw "Independent singular system at column $col"}
        if($pivotRow -ne $col){
            for($swapCol=$col;$swapCol -le $Dimension;$swapCol++){
                $tmp=$work[$col,$swapCol]
                $work[$col,$swapCol]=$work[$pivotRow,$swapCol]
                $work[$pivotRow,$swapCol]=$tmp
            }
        }
        for($row=$col+1;$row -lt $Dimension;$row++){
            $ratio=$work[$row,$col]/$work[$col,$col]
            $work[$row,$col]=0.0
            for($inner=$col+1;$inner -le $Dimension;$inner++){$work[$row,$inner]-=$ratio*$work[$col,$inner]}
        }
    }
    $answer=[double[]]::new($Dimension)
    for($row=$Dimension-1;$row -ge 0;$row--){
        $rhs=$work[$row,$Dimension]
        for($col=$row+1;$col -lt $Dimension;$col++){$rhs-=$work[$row,$col]*$answer[$col]}
        $diag=$work[$row,$row]
        if([math]::Abs($diag) -le $script:CfaIndependentTolerance){throw "Independent singular backsolve at row $row"}
        $answer[$row]=$rhs/$diag
        if([double]::IsNaN($answer[$row]) -or [double]::IsInfinity($answer[$row])){throw 'Independent linear solve produced non-finite value.'}
    }
    return ,$answer
}

function Get-CfaIndependentPlsPath {
    param($PredictorMatrix,[double[]]$CenteredResponse,[int]$MaxComponents)
    $rowCount=$PredictorMatrix.GetLength(0)
    $predictorCount=$PredictorMatrix.GetLength(1)
    if($rowCount -ne $CenteredResponse.Count){throw 'Independent PLS row mismatch.'}
    if($MaxComponents -lt 1 -or $MaxComponents -gt $predictorCount){throw 'Independent invalid component count.'}

    $residualPredictors=[double[,]]::new($rowCount,$predictorCount)
    $residualResponse=[double[]]::new($rowCount)
    for($row=0;$row -lt $rowCount;$row++){
        $residualResponse[$row]=$CenteredResponse[$row]
        for($col=0;$col -lt $predictorCount;$col++){$residualPredictors[$row,$col]=$PredictorMatrix[$row,$col]}
    }

    $weights=[double[,]]::new($predictorCount,$MaxComponents)
    $loadings=[double[,]]::new($predictorCount,$MaxComponents)
    $responseLoadings=[double[]]::new($MaxComponents)
    $coefficientPath=New-Object System.Collections.ArrayList

    for($componentIndex=0;$componentIndex -lt $MaxComponents;$componentIndex++){
        $crossProduct=[double[]]::new($predictorCount)
        $crossNormSquared=0.0
        for($col=0;$col -lt $predictorCount;$col++){
            $sum=0.0
            for($row=0;$row -lt $rowCount;$row++){$sum+=$residualPredictors[$row,$col]*$residualResponse[$row]}
            $crossProduct[$col]=$sum
            $crossNormSquared+=$sum*$sum
        }
        $crossNorm=[math]::Sqrt($crossNormSquared)
        if($crossNorm -le $script:CfaIndependentTolerance){throw "Independent degenerate weight at component $($componentIndex+1)"}

        $componentWeight=[double[]]::new($predictorCount)
        for($col=0;$col -lt $predictorCount;$col++){
            $componentWeight[$col]=$crossProduct[$col]/$crossNorm
            $weights[$col,$componentIndex]=$componentWeight[$col]
        }

        $score=[double[]]::new($rowCount)
        $scoreNormSquared=0.0
        for($row=0;$row -lt $rowCount;$row++){
            $sum=0.0
            for($col=0;$col -lt $predictorCount;$col++){$sum+=$residualPredictors[$row,$col]*$componentWeight[$col]}
            $score[$row]=$sum
            $scoreNormSquared+=$sum*$sum
        }
        if($scoreNormSquared -le $script:CfaIndependentTolerance){throw "Independent degenerate score at component $($componentIndex+1)"}

        $componentLoading=[double[]]::new($predictorCount)
        for($col=0;$col -lt $predictorCount;$col++){
            $sum=0.0
            for($row=0;$row -lt $rowCount;$row++){$sum+=$residualPredictors[$row,$col]*$score[$row]}
            $componentLoading[$col]=$sum/$scoreNormSquared
            $loadings[$col,$componentIndex]=$componentLoading[$col]
        }

        $responseNumerator=0.0
        for($row=0;$row -lt $rowCount;$row++){$responseNumerator+=$residualResponse[$row]*$score[$row]}
        $responseLoading=$responseNumerator/$scoreNormSquared
        if([double]::IsNaN($responseLoading) -or [double]::IsInfinity($responseLoading)){throw 'Independent non-finite response loading.'}
        $responseLoadings[$componentIndex]=$responseLoading

        for($row=0;$row -lt $rowCount;$row++){
            $scoreValue=$score[$row]
            for($col=0;$col -lt $predictorCount;$col++){$residualPredictors[$row,$col]-=$scoreValue*$componentLoading[$col]}
            $residualResponse[$row]-=$scoreValue*$responseLoading
        }

        $componentCount=$componentIndex+1
        $ptw=[double[,]]::new($componentCount,$componentCount)
        $q=[double[]]::new($componentCount)
        for($left=0;$left -lt $componentCount;$left++){
            $q[$left]=$responseLoadings[$left]
            for($right=0;$right -lt $componentCount;$right++){
                $sum=0.0
                for($col=0;$col -lt $predictorCount;$col++){$sum+=$loadings[$col,$left]*$weights[$col,$right]}
                $ptw[$left,$right]=$sum
            }
        }
        $rotation=Solve-CfaIndependentSystem $ptw $q $componentCount
        $beta=[double[]]::new($predictorCount)
        for($col=0;$col -lt $predictorCount;$col++){
            $sum=0.0
            for($component=0;$component -lt $componentCount;$component++){$sum+=$weights[$col,$component]*$rotation[$component]}
            $beta[$col]=$sum
            if([double]::IsNaN($beta[$col]) -or [double]::IsInfinity($beta[$col])){throw 'Independent non-finite PLS coefficient.'}
        }
        [void]$coefficientPath.Add($beta)
    }
    return [pscustomobject]@{betas=@($coefficientPath.ToArray())}
}

function Get-CfaIndependentPredictions {
    param($PredictorMatrix,[double[]]$Beta,[double]$ResponseCenter)
    $rowCount=$PredictorMatrix.GetLength(0)
    $predictorCount=$PredictorMatrix.GetLength(1)
    $predictions=[double[]]::new($rowCount)
    for($row=0;$row -lt $rowCount;$row++){
        $estimate=$ResponseCenter
        for($col=0;$col -lt $predictorCount;$col++){$estimate+=$PredictorMatrix[$row,$col]*$Beta[$col]}
        if([double]::IsNaN($estimate) -or [double]::IsInfinity($estimate)){throw 'Independent non-finite prediction.'}
        $predictions[$row]=$estimate
    }
    return ,$predictions
}

function Get-CfaIndependentMetrics {
    param([double[]]$Actual,[double[]]$Predicted,[double]$MeanBenchmark)
    if($Actual.Count -ne $Predicted.Count -or $Actual.Count -lt 1){throw 'Independent metric vector mismatch.'}
    $sse=0.0;$sae=0.0;$meanSse=0.0
    for($row=0;$row -lt $Actual.Count;$row++){
        $error=$Predicted[$row]-$Actual[$row]
        $sse+=$error*$error
        $sae+=[math]::Abs($error)
        $meanError=$Actual[$row]-$MeanBenchmark
        $meanSse+=$meanError*$meanError
    }
    if($meanSse -le $script:CfaIndependentTolerance){throw 'Independent response-mean denominator is non-positive.'}
    $rmse=[math]::Sqrt($sse/$Actual.Count)
    $mae=$sae/$Actual.Count
    $r2=1.0-($sse/$meanSse)
    foreach($value in @($sse,$rmse,$mae,$r2)){if([double]::IsNaN($value) -or [double]::IsInfinity($value)){throw 'Independent non-finite metric.'}}
    return [pscustomobject]@{n=$Actual.Count;sse=$sse;rmse=$rmse;mae=$mae;predictive_r2=$r2}
}

function Test-CfaStage8IndependentCore {
    $matrix=[double[,]]::new(5,2)
    $fixture=@(@(-2.0,-1.0),@(-1.0,0.0),@(0.0,1.0),@(1.0,1.0),@(2.0,3.0))
    for($row=0;$row -lt 5;$row++){for($col=0;$col -lt 2;$col++){$matrix[$row,$col]=$fixture[$row][$col]}}
    [double[]]$response=@(-3.0,-2.0,-1.0,1.0,1.0)
    $path=Get-CfaIndependentPlsPath $matrix $response 2
    $beta=[double[]]$path.betas[1]
    if([math]::Abs($beta[0]-2.0) -gt 1e-10 -or [math]::Abs($beta[1]+1.0) -gt 1e-10){throw 'Independent coefficient self-test failed.'}
    $pred=Get-CfaIndependentPredictions $matrix $beta 0.0
    for($row=0;$row -lt 5;$row++){if([math]::Abs($pred[$row]-$response[$row]) -gt 1e-10){throw 'Independent prediction self-test failed.'}}
    $metrics=Get-CfaIndependentMetrics $response $pred 0.0
    if($metrics.rmse -gt 1e-10 -or $metrics.mae -gt 1e-10){throw 'Independent metric self-test failed.'}
    return $true
}
