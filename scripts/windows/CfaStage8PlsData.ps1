Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CfaInvariant=[Globalization.CultureInfo]::InvariantCulture

function Get-CfaSha {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Require-CfaFile {param([string]$Path,[string]$Label);$r=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $r -PathType Leaf)){throw "$Label is not a file: $r"};return $r}
function Parse-CfaDouble {param([object]$Value,[string]$Label);$n=0.0;if(-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$script:CfaInvariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"};if([double]::IsNaN($n)-or[double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"};return $n}
function Get-CfaPreprocessMap {param([object[]]$Rows);$m=@{};foreach($r in $Rows){$k=([string]$r.phase)+'|'+([string]$r.variable);if($m.ContainsKey($k)){throw "Duplicate preprocessing row: $k"};$m[$k]=$r};if($m.Count-ne16){throw 'Expected 16 preprocessing rows.'};return $m}
function Build-CfaProcessed {
    param([object[]]$Rows,[hashtable]$Map,[string]$Phase,[string[]]$FactorIds)
    $n=$Rows.Count;$p=$FactorIds.Count;$X=[double[,]]::new($n,$p);$yr=[double[]]::new($n);$yc=[double[]]::new($n)
    $yp=$Map[$Phase+'|response_value_log_return'];if($null-eq$yp){throw "Missing response preprocessing: $Phase"};$yCenter=Parse-CfaDouble $yp.center "$Phase response center"
    for($i=0;$i-lt$n;$i++){$y=Parse-CfaDouble $Rows[$i].response_value_log_return "$Phase y $i";$yr[$i]=$y;$yc[$i]=$y-$yCenter;for($j=0;$j-lt$p;$j++){$id=$FactorIds[$j];$pp=$Map[$Phase+'|'+$id];if($null-eq$pp){throw "Missing predictor preprocessing: $Phase $id"};$c=Parse-CfaDouble $pp.center "$Phase $id center";$s=Parse-CfaDouble $pp.scale "$Phase $id scale";if($s-le0){throw "Non-positive scale: $Phase $id"};$x=Parse-CfaDouble $Rows[$i].PSObject.Properties[$id].Value "$Phase $id row $i";$X[$i,$j]=($x-$c)/$s}}
    return [pscustomobject]@{X=$X;y_raw=$yr;y_centered=$yc;response_center=$yCenter}
}
function Get-CfaBenchmarkPred {param([object[]]$Rows,[string]$Id,[double]$Mean);$a=[double[]]::new($Rows.Count);for($i=0;$i-lt$Rows.Count;$i++){if($Id-eq'BENCH_ZERO_RETURN'){$a[$i]=0}elseif($Id-eq'BENCH_PRIOR_MARKET_RETURN'){$a[$i]=Parse-CfaDouble $Rows[$i].MKT_RET_USD_UTC_DAY_OBS_L1 "prior market $i"}elseif($Id-eq'BENCH_RESPONSE_MEAN'){$a[$i]=$Mean}else{throw "Unknown benchmark $Id"}};return $a}
function New-CfaMetricRow {param([string]$Segment,[string]$Id,$M);return [pscustomobject][ordered]@{segment=$Segment;model_id=$Id;n=$M.n;rmse=$M.rmse.ToString('R',$script:CfaInvariant);mae=$M.mae.ToString('R',$script:CfaInvariant);sse=$M.sse.ToString('R',$script:CfaInvariant);predictive_r2_vs_response_mean=$M.predictive_r2.ToString('R',$script:CfaInvariant)}}
