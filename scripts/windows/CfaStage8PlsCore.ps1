Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CfaPlsTolerance=1e-12

function Solve-CfaLinearSystem {
    param([double[,]]$A,[double[]]$B,[int]$N)
    $aug=[double[,]]::new($N,$N+1)
    for($i=0;$i -lt $N;$i++){
        for($j=0;$j -lt $N;$j++){$aug[$i,$j]=$A[$i,$j]}
        $aug[$i,$N]=$B[$i]
    }
    for($col=0;$col -lt $N;$col++){
        $pivot=$col;$max=[math]::Abs($aug[$col,$col])
        for($r=$col+1;$r -lt $N;$r++){
            $v=[math]::Abs($aug[$r,$col]);if($v -gt $max){$max=$v;$pivot=$r}
        }
        if($max -le $script:CfaPlsTolerance){throw "Singular linear system at column $col"}
        if($pivot -ne $col){
            for($j=$col;$j -le $N;$j++){$tmp=$aug[$col,$j];$aug[$col,$j]=$aug[$pivot,$j];$aug[$pivot,$j]=$tmp}
        }
        for($r=$col+1;$r -lt $N;$r++){
            $factor=$aug[$r,$col]/$aug[$col,$col]
            $aug[$r,$col]=0.0
            for($j=$col+1;$j -le $N;$j++){$aug[$r,$j]-=$factor*$aug[$col,$j]}
        }
    }
    $x=New-Object double[] $N
    for($i=$N-1;$i -ge 0;$i--){
        $sum=$aug[$i,$N]
        for($j=$i+1;$j -lt $N;$j++){$sum-=$aug[$i,$j]*$x[$j]}
        $den=$aug[$i,$i]
        if([math]::Abs($den) -le $script:CfaPlsTolerance){throw "Singular backsolve at row $i"}
        $x[$i]=$sum/$den
        if([double]::IsNaN($x[$i]) -or [double]::IsInfinity($x[$i])){throw 'Non-finite linear-system solution.'}
    }
    return $x
}

function Fit-CfaPls1Path {
    param([double[,]]$X,[double[]]$Y,[int]$MaxComponents)
    $n=$X.GetLength(0);$p=$X.GetLength(1)
    if($n -ne $Y.Count){throw 'PLS X/Y row mismatch.'}
    if($MaxComponents -lt 1 -or $MaxComponents -gt $p){throw 'Invalid PLS component count.'}
    $E=[double[,]]::new($n,$p);$f=New-Object double[] $n
    for($i=0;$i -lt $n;$i++){$f[$i]=$Y[$i];for($j=0;$j -lt $p;$j++){$E[$i,$j]=$X[$i,$j]}}
    $W=[double[,]]::new($p,$MaxComponents);$P=[double[,]]::new($p,$MaxComponents);$Q=New-Object double[] $MaxComponents
    $betas=New-Object System.Collections.ArrayList
    for($h=0;$h -lt $MaxComponents;$h++){
        $c=New-Object double[] $p
        for($j=0;$j -lt $p;$j++){$sum=0.0;for($i=0;$i -lt $n;$i++){$sum+=$E[$i,$j]*$f[$i]};$c[$j]=$sum}
        $normSq=0.0;foreach($v in $c){$normSq+=$v*$v};$norm=[math]::Sqrt($normSq)
        if($norm -le $script:CfaPlsTolerance){throw "Degenerate PLS weight norm at component $($h+1)"}
        $w=New-Object double[] $p
        for($j=0;$j -lt $p;$j++){$w[$j]=$c[$j]/$norm;$W[$j,$h]=$w[$j]}
        $t=New-Object double[] $n;$tt=0.0
        for($i=0;$i -lt $n;$i++){$sum=0.0;for($j=0;$j -lt $p;$j++){$sum+=$E[$i,$j]*$w[$j]};$t[$i]=$sum;$tt+=$sum*$sum}
        if($tt -le $script:CfaPlsTolerance){throw "Degenerate PLS score norm at component $($h+1)"}
        $pvec=New-Object double[] $p
        for($j=0;$j -lt $p;$j++){$sum=0.0;for($i=0;$i -lt $n;$i++){$sum+=$E[$i,$j]*$t[$i]};$pvec[$j]=$sum/$tt;$P[$j,$h]=$pvec[$j]}
        $qsum=0.0;for($i=0;$i -lt $n;$i++){$qsum+=$f[$i]*$t[$i]};$q=$qsum/$tt;$Q[$h]=$q
        if([double]::IsNaN($q) -or [double]::IsInfinity($q)){throw "Non-finite PLS q at component $($h+1)"}
        for($i=0;$i -lt $n;$i++){$ti=$t[$i];for($j=0;$j -lt $p;$j++){$E[$i,$j]-=$ti*$pvec[$j]};$f[$i]-=$ti*$q}
        $H=$h+1;$A=[double[,]]::new($H,$H);$b=New-Object double[] $H
        for($r=0;$r -lt $H;$r++){$b[$r]=$Q[$r];for($col=0;$col -lt $H;$col++){$sum=0.0;for($j=0;$j -lt $p;$j++){$sum+=$P[$j,$r]*$W[$j,$col]};$A[$r,$col]=$sum}}
        $z=Solve-CfaLinearSystem $A $b $H;$beta=New-Object double[] $p
        for($j=0;$j -lt $p;$j++){$sum=0.0;for($r=0;$r -lt $H;$r++){$sum+=$W[$j,$r]*$z[$r]};$beta[$j]=$sum;if([double]::IsNaN($beta[$j]) -or [double]::IsInfinity($beta[$j])){throw "Non-finite PLS beta at component $H"}}
        [void]$betas.Add($beta)
    }
    return [pscustomobject]@{betas=@($betas.ToArray())}
}

function Predict-CfaPlsOriginal {
    param([double[,]]$X,[double[]]$Beta,[double]$ResponseCenter)
    $n=$X.GetLength(0);$p=$X.GetLength(1);$pred=New-Object double[] $n
    for($i=0;$i -lt $n;$i++){$sum=$ResponseCenter;for($j=0;$j -lt $p;$j++){$sum+=$X[$i,$j]*$Beta[$j]};if([double]::IsNaN($sum) -or [double]::IsInfinity($sum)){throw 'Non-finite PLS prediction.'};$pred[$i]=$sum}
    return $pred
}

function Get-CfaRegressionMetrics {
    param([double[]]$Actual,[double[]]$Predicted,[double]$MeanBenchmark)
    if($Actual.Count -ne $Predicted.Count -or $Actual.Count -lt 1){throw 'Metric vector mismatch.'}
    $sse=0.0;$sae=0.0;$meanSse=0.0
    for($i=0;$i -lt $Actual.Count;$i++){$e=$Predicted[$i]-$Actual[$i];$sse+=$e*$e;$sae+=[math]::Abs($e);$d=$Actual[$i]-$MeanBenchmark;$meanSse+=$d*$d}
    if($meanSse -le $script:CfaPlsTolerance){throw 'Response-mean benchmark SSE is non-positive.'}
    $rmse=[math]::Sqrt($sse/$Actual.Count);$mae=$sae/$Actual.Count;$r2=1.0-($sse/$meanSse)
    foreach($v in @($sse,$rmse,$mae,$r2)){if([double]::IsNaN($v) -or [double]::IsInfinity($v)){throw 'Non-finite metric.'}}
    return [pscustomobject]@{n=$Actual.Count;sse=$sse;rmse=$rmse;mae=$mae;predictive_r2=$r2;mean_benchmark_sse=$meanSse}
}

function Test-CfaStage8PlsCore {
    $X=[double[,]]::new(4,2);$vals=@(@(-1.0,-1.0),@(-1.0,1.0),@(1.0,-1.0),@(1.0,1.0))
    for($i=0;$i -lt 4;$i++){for($j=0;$j -lt 2;$j++){$X[$i,$j]=$vals[$i][$j]}}
    [double[]]$y=@(-1.0,-3.0,3.0,1.0)
    $path=Fit-CfaPls1Path $X $y 2;$beta=[double[]]$path.betas[1]
    if([math]::Abs($beta[0]-2.0) -gt 1e-10 -or [math]::Abs($beta[1]+1.0) -gt 1e-10){throw "PLS coefficient self-test failed: $($beta[0]), $($beta[1])"}
    $pred=Predict-CfaPlsOriginal $X $beta 0.0
    for($i=0;$i -lt 4;$i++){if([math]::Abs($pred[$i]-$y[$i]) -gt 1e-10){throw "PLS prediction self-test failed at row $i"}}
    $m=Get-CfaRegressionMetrics $y $pred 0.0
    if($m.rmse -gt 1e-10 -or $m.mae -gt 1e-10){throw 'Metric self-test failed.'}
    return $true
}
