Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CfaInvariant=[Globalization.CultureInfo]::InvariantCulture

function Get-CfaSha {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Require-CfaFile {param([string]$Path,[string]$Label);$resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"};return $resolved}
function Parse-CfaDouble {param([object]$Value,[string]$Label);$number=0.0;if(-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$script:CfaInvariant,[ref]$number)){throw "Malformed numeric for ${Label}: '$Value'"};if([double]::IsNaN($number)-or[double]::IsInfinity($number)){throw "Non-finite numeric for ${Label}: '$Value'"};return $number}
function Get-CfaPreprocessMap {param([object[]]$Rows);$map=@{};foreach($row in $Rows){$key=([string]$row.phase)+'|'+([string]$row.variable);if($map.ContainsKey($key)){throw "Duplicate preprocessing row: $key"};$map[$key]=$row};if($map.Count-ne16){throw 'Expected 16 preprocessing rows.'};return $map}

function Build-CfaProcessed {
    param([object[]]$Rows,[hashtable]$Map,[string]$Phase,[string[]]$FactorIds)
    $rowCount=$Rows.Count
    $predictorCount=$FactorIds.Count
    $processedMatrix=[double[,]]::new($rowCount,$predictorCount)
    $rawResponse=[double[]]::new($rowCount)
    $centeredResponse=[double[]]::new($rowCount)
    $responseParameter=$Map[$Phase+'|response_value_log_return']
    if($null-eq$responseParameter){throw "Missing response preprocessing: $Phase"}
    $responseCenter=Parse-CfaDouble $responseParameter.center "$Phase response center"
    for($rowIndex=0;$rowIndex-lt$rowCount;$rowIndex++){
        $responseValue=Parse-CfaDouble $Rows[$rowIndex].response_value_log_return "$Phase y $rowIndex"
        $rawResponse[$rowIndex]=$responseValue
        $centeredResponse[$rowIndex]=$responseValue-$responseCenter
        for($predictorIndex=0;$predictorIndex-lt$predictorCount;$predictorIndex++){
            $factorId=$FactorIds[$predictorIndex]
            $predictorParameter=$Map[$Phase+'|'+$factorId]
            if($null-eq$predictorParameter){throw "Missing predictor preprocessing: $Phase $factorId"}
            $predictorCenter=Parse-CfaDouble $predictorParameter.center "$Phase $factorId center"
            $predictorScale=Parse-CfaDouble $predictorParameter.scale "$Phase $factorId scale"
            if($predictorScale-le0){throw "Non-positive scale: $Phase $factorId"}
            $rawPredictor=Parse-CfaDouble $Rows[$rowIndex].PSObject.Properties[$factorId].Value "$Phase $factorId row $rowIndex"
            $processedMatrix[$rowIndex,$predictorIndex]=($rawPredictor-$predictorCenter)/$predictorScale
        }
    }
    return [pscustomobject]@{X=$processedMatrix;y_raw=$rawResponse;y_centered=$centeredResponse;response_center=$responseCenter}
}

function Get-CfaBenchmarkPred {
    param([object[]]$Rows,[string]$Id,[double]$Mean)
    $predictions=[double[]]::new($Rows.Count)
    for($rowIndex=0;$rowIndex-lt$Rows.Count;$rowIndex++){
        if($Id-eq'BENCH_ZERO_RETURN'){$predictions[$rowIndex]=0}
        elseif($Id-eq'BENCH_PRIOR_MARKET_RETURN'){$predictions[$rowIndex]=Parse-CfaDouble $Rows[$rowIndex].MKT_RET_USD_UTC_DAY_OBS_L1 "prior market $rowIndex"}
        elseif($Id-eq'BENCH_RESPONSE_MEAN'){$predictions[$rowIndex]=$Mean}
        else{throw "Unknown benchmark $Id"}
    }
    return ,$predictions
}

function New-CfaMetricRow {
    param([string]$Segment,[string]$Id,$Metric)
    return [pscustomobject][ordered]@{segment=$Segment;model_id=$Id;n=$Metric.n;rmse=$Metric.rmse.ToString('R',$script:CfaInvariant);mae=$Metric.mae.ToString('R',$script:CfaInvariant);sse=$Metric.sse.ToString('R',$script:CfaInvariant);predictive_r2_vs_response_mean=$Metric.predictive_r2.ToString('R',$script:CfaInvariant)}
}

function Test-CfaStage8PlsData {
    $factorIds=@('F1','F2')
    $rows=@(
        [pscustomobject]@{response_value_log_return='3';F1='12';F2='16'},
        [pscustomobject]@{response_value_log_return='5';F1='8';F2='24'}
    )
    $map=@{
        'SELFTEST|response_value_log_return'=[pscustomobject]@{center='4'}
        'SELFTEST|F1'=[pscustomobject]@{center='10';scale='2'}
        'SELFTEST|F2'=[pscustomobject]@{center='20';scale='4'}
    }
    $processed=Build-CfaProcessed $rows $map 'SELFTEST' $factorIds
    if($processed.X.GetLength(0)-ne2-or$processed.X.GetLength(1)-ne2){throw 'Processed matrix dimension self-test failed.'}
    $cell00=$processed.X[0,0]
    $cell01=$processed.X[0,1]
    $cell10=$processed.X[1,0]
    $cell11=$processed.X[1,1]
    if([math]::Abs($cell00-1.0)-gt1e-12-or[math]::Abs($cell01+1.0)-gt1e-12-or[math]::Abs($cell10+1.0)-gt1e-12-or[math]::Abs($cell11-1.0)-gt1e-12){throw 'Processed predictor self-test failed.'}
    $centered0=$processed.y_centered[0]
    $centered1=$processed.y_centered[1]
    if([math]::Abs($centered0+1.0)-gt1e-12-or[math]::Abs($centered1-1.0)-gt1e-12){throw 'Processed response self-test failed.'}
    $prior=Get-CfaBenchmarkPred @([pscustomobject]@{MKT_RET_USD_UTC_DAY_OBS_L1='0.25'}) 'BENCH_PRIOR_MARKET_RETURN' 0.0
    $prior0=$prior[0]
    if($prior.Count-ne1-or[math]::Abs($prior0-0.25)-gt1e-12){throw 'Benchmark prediction self-test failed.'}
    return $true
}
