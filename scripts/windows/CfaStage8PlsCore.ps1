Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CfaPlsTolerance=1e-12

function Solve-CfaLinearSystem {
    param($Matrix,[double[]]$RightHandSide,[int]$Dimension)
    $aug=[double[,]]::new($Dimension,$Dimension+1)
    for($row=0;$row -lt $Dimension;$row++){
        for($col=0;$col -lt $Dimension;$col++){$aug[$row,$col]=$Matrix[$row,$col]}
        $aug[$row,$Dimension]=$RightHandSide[$row]
    }
    for($pivotCol=0;$pivotCol -lt $Dimension;$pivotCol++){
        $pivotRow=$pivotCol
        $pivotCell=$aug[$pivotCol,$pivotCol]
        $maxAbs=[math]::Abs($pivotCell)
        for($candidateRow=$pivotCol+1;$candidateRow -lt $Dimension;$candidateRow++){
            $candidateCell=$aug[$candidateRow,$pivotCol]
            $candidateAbs=[math]::Abs($candidateCell)
            if($candidateAbs -gt $maxAbs){$maxAbs=$candidateAbs;$pivotRow=$candidateRow}
        }
        if($maxAbs -le $script:CfaPlsTolerance){throw "Singular linear system at column $pivotCol"}
        if($pivotRow -ne $pivotCol){
            for($col=$pivotCol;$col -le $Dimension;$col++){
                $tmp=$aug[$pivotCol,$col]
                $aug[$pivotCol,$col]=$aug[$pivotRow,$col]
                $aug[$pivotRow,$col]=$tmp
            }
        }
        for($row=$pivotCol+1;$row -lt $Dimension;$row++){
            $factor=$aug[$row,$pivotCol]/$aug[$pivotCol,$pivotCol]
            $aug[$row,$pivotCol]=0.0
            for($col=$pivotCol+1;$col -le $Dimension;$col++){$aug[$row,$col]-=$factor*$aug[$pivotCol,$col]}
        }
    }
    $solution=[double[]]::new($Dimension)
    for($row=$Dimension-1;$row -ge 0;$row--){
        $sum=$aug[$row,$Dimension]
        for($col=$row+1;$col -lt $Dimension;$col++){$sum-=$aug[$row,$col]*$solution[$col]}
        $denominator=$aug[$row,$row]
        if([math]::Abs($denominator) -le $script:CfaPlsTolerance){throw "Singular backsolve at row $row"}
        $solution[$row]=$sum/$denominator
        if([double]::IsNaN($solution[$row]) -or [double]::IsInfinity($solution[$row])){throw 'Non-finite linear-system solution.'}
    }
    return $solution
}

function Fit-CfaPls1Path {
    param($PredictorMatrix,[double[]]$CenteredResponse,[int]$MaxComponents)
    $rowCount=$PredictorMatrix.GetLength(0)
    $predictorCount=$PredictorMatrix.GetLength(1)
    if($rowCount -ne $CenteredResponse.Count){throw 'PLS X/Y row mismatch.'}
    if($MaxComponents -lt 1 -or $MaxComponents -gt $predictorCount){throw 'Invalid PLS component count.'}

    $residualX=[double[,]]::new($rowCount,$predictorCount)
    $residualY=[double[]]::new($rowCount)
    for($row=0;$row -lt $rowCount;$row++){
        $residualY[$row]=$CenteredResponse[$row]
        for($col=0;$col -lt $predictorCount;$col++){$residualX[$row,$col]=$PredictorMatrix[$row,$col]}
    }

    $weightMatrix=[double[,]]::new($predictorCount,$MaxComponents)
    $loadingMatrix=[double[,]]::new($predictorCount,$MaxComponents)
    $qVector=[double[]]::new($MaxComponents)
    $betaPath=New-Object System.Collections.ArrayList

    for($componentIndex=0;$componentIndex -lt $MaxComponents;$componentIndex++){
        $covarianceVector=[double[]]::new($predictorCount)
        for($col=0;$col -lt $predictorCount;$col++){
            $sum=0.0
            for($row=0;$row -lt $rowCount;$row++){$sum+=$residualX[$row,$col]*$residualY[$row]}
            $covarianceVector[$col]=$sum
        }
        $weightNormSq=0.0
        foreach($value in $covarianceVector){$weightNormSq+=$value*$value}
        $weightNorm=[math]::Sqrt($weightNormSq)
        if($weightNorm -le $script:CfaPlsTolerance){throw "Degenerate PLS weight norm at component $($componentIndex+1)"}

        $weightVector=[double[]]::new($predictorCount)
        for($col=0;$col -lt $predictorCount;$col++){
            $weightVector[$col]=$covarianceVector[$col]/$weightNorm
            $weightMatrix[$col,$componentIndex]=$weightVector[$col]
        }

        $scoreVector=[double[]]::new($rowCount)
        $scoreNormSq=0.0
        for($row=0;$row -lt $rowCount;$row++){
            $sum=0.0
            for($col=0;$col -lt $predictorCount;$col++){$sum+=$residualX[$row,$col]*$weightVector[$col]}
            $scoreVector[$row]=$sum
            $scoreNormSq+=$sum*$sum
        }
        if($scoreNormSq -le $script:CfaPlsTolerance){throw "Degenerate PLS score norm at component $($componentIndex+1)"}

        $loadingVector=[double[]]::new($predictorCount)
        for($col=0;$col -lt $predictorCount;$col++){
            $sum=0.0
            for($row=0;$row -lt $rowCount;$row++){$sum+=$residualX[$row,$col]*$scoreVector[$row]}
            $loadingVector[$col]=$sum/$scoreNormSq
            $loadingMatrix[$col,$componentIndex]=$loadingVector[$col]
        }

        $qNumerator=0.0
        for($row=0;$row -lt $rowCount;$row++){$qNumerator+=$residualY[$row]*$scoreVector[$row]}
        $qScalar=$qNumerator/$scoreNormSq
        $qVector[$componentIndex]=$qScalar
        if([double]::IsNaN($qScalar) -or [double]::IsInfinity($qScalar)){throw "Non-finite PLS q at component $($componentIndex+1)"}

        for($row=0;$row -lt $rowCount;$row++){
            $score=$scoreVector[$row]
            for($col=0;$col -lt $predictorCount;$col++){$residualX[$row,$col]-=$score*$loadingVector[$col]}
            $residualY[$row]-=$score*$qScalar
        }

        $componentCount=$componentIndex+1
        $ptw=[double[,]]::new($componentCount,$componentCount)
        $qSubset=[double[]]::new($componentCount)
        for($left=0;$left -lt $componentCount;$left++){
            $qSubset[$left]=$qVector[$left]
            for($right=0;$right -lt $componentCount;$right++){
                $sum=0.0
                for($col=0;$col -lt $predictorCount;$col++){$sum+=$loadingMatrix[$col,$left]*$weightMatrix[$col,$right]}
                $ptw[$left,$right]=$sum
            }
        }
        $rotationWeights=Solve-CfaLinearSystem $ptw $qSubset $componentCount
        $beta=[double[]]::new($predictorCount)
        for($col=0;$col -lt $predictorCount;$col++){
            $sum=0.0
            for($component=0;$component -lt $componentCount;$component++){$sum+=$weightMatrix[$col,$component]*$rotationWeights[$component]}
            $beta[$col]=$sum
            if([double]::IsNaN($beta[$col]) -or [double]::IsInfinity($beta[$col])){throw "Non-finite PLS beta at component $componentCount"}
        }
        [void]$betaPath.Add($beta)
    }
    return [pscustomobject]@{betas=@($betaPath.ToArray())}
}

function Predict-CfaPlsOriginal {
    param($PredictorMatrix,[double[]]$Beta,[double]$ResponseCenter)
    $rowCount=$PredictorMatrix.GetLength(0)
    $predictorCount=$PredictorMatrix.GetLength(1)
    $predictions=[double[]]::new($rowCount)
    for($row=0;$row -lt $rowCount;$row++){
        $sum=$ResponseCenter
        for($col=0;$col -lt $predictorCount;$col++){$sum+=$PredictorMatrix[$row,$col]*$Beta[$col]}
        if([double]::IsNaN($sum) -or [double]::IsInfinity($sum)){throw 'Non-finite PLS prediction.'}
        $predictions[$row]=$sum
    }
    return $predictions
}

function Get-CfaRegressionMetrics {
    param([double[]]$Actual,[double[]]$Predicted,[double]$MeanBenchmark)
    if($Actual.Count -ne $Predicted.Count -or $Actual.Count -lt 1){throw 'Metric vector mismatch.'}
    $sse=0.0;$sae=0.0;$meanSse=0.0
    for($row=0;$row -lt $Actual.Count;$row++){
        $error=$Predicted[$row]-$Actual[$row]
        $sse+=$error*$error
        $sae+=[math]::Abs($error)
        $meanError=$Actual[$row]-$MeanBenchmark
        $meanSse+=$meanError*$meanError
    }
    if($meanSse -le $script:CfaPlsTolerance){throw 'Response-mean benchmark SSE is non-positive.'}
    $rmse=[math]::Sqrt($sse/$Actual.Count)
    $mae=$sae/$Actual.Count
    $predictiveR2=1.0-($sse/$meanSse)
    foreach($value in @($sse,$rmse,$mae,$predictiveR2)){if([double]::IsNaN($value) -or [double]::IsInfinity($value)){throw 'Non-finite metric.'}}
    return [pscustomobject]@{n=$Actual.Count;sse=$sse;rmse=$rmse;mae=$mae;predictive_r2=$predictiveR2;mean_benchmark_sse=$meanSse}
}

function Test-CfaStage8PlsCore {
    $predictors=[double[,]]::new(5,2)
    $fixture=@(@(-2.0,-1.0),@(-1.0,0.0),@(0.0,1.0),@(1.0,1.0),@(2.0,3.0))
    for($row=0;$row -lt 5;$row++){for($col=0;$col -lt 2;$col++){$predictors[$row,$col]=$fixture[$row][$col]}}
    [double[]]$response=@(-3.0,-2.0,-1.0,1.0,1.0)
    $path=Fit-CfaPls1Path $predictors $response 2
    $beta=[double[]]$path.betas[1]
    if([math]::Abs($beta[0]-2.0) -gt 1e-10 -or [math]::Abs($beta[1]+1.0) -gt 1e-10){throw "PLS coefficient self-test failed: $($beta[0]), $($beta[1])"}
    $predictions=Predict-CfaPlsOriginal $predictors $beta 0.0
    for($row=0;$row -lt 5;$row++){if([math]::Abs($predictions[$row]-$response[$row]) -gt 1e-10){throw "PLS prediction self-test failed at row $row"}}
    $metrics=Get-CfaRegressionMetrics $response $predictions 0.0
    if($metrics.rmse -gt 1e-10 -or $metrics.mae -gt 1e-10){throw 'Metric self-test failed.'}
    if(-not(Test-CfaStage8PlsData)){throw 'PLS data/preprocessing self-test returned false.'}
    return $true
}
