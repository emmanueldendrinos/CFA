Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:CfaIndependentInvariant=[Globalization.CultureInfo]::InvariantCulture

function Get-CfaIndependentSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Require-CfaIndependentFile {
    param([string]$Path,[string]$Label)
    $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"}
    return $resolved
}

function Parse-CfaIndependentDouble {
    param([object]$Value,[string]$Label)
    $parsed=0.0
    if(-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$script:CfaIndependentInvariant,[ref]$parsed)){throw "Malformed independent numeric for ${Label}: '$Value'"}
    if([double]::IsNaN($parsed) -or [double]::IsInfinity($parsed)){throw "Non-finite independent numeric for ${Label}: '$Value'"}
    return $parsed
}

function Test-CfaIndependentNear {
    param([double]$Observed,[double]$Expected,[double]$Tolerance=1e-11)
    $scale=[math]::Max(1.0,[math]::Max([math]::Abs($Observed),[math]::Abs($Expected)))
    return ([math]::Abs($Observed-$Expected) -le ($Tolerance*$scale))
}

function Get-CfaIndependentPreprocessMap {
    param([object[]]$Rows)
    $map=@{}
    foreach($row in $Rows){
        $key=([string]$row.phase)+'|'+([string]$row.variable)
        if($map.ContainsKey($key)){throw "Duplicate independent preprocessing key: $key"}
        $map[$key]=$row
    }
    if($map.Count -ne 16){throw "Expected 16 preprocessing rows, observed $($map.Count)."}
    return $map
}

function New-CfaIndependentProcessedData {
    param([object[]]$Rows,[hashtable]$ParameterMap,[string]$Phase,[string[]]$FactorIds)
    $rowCount=$Rows.Count
    $predictorCount=$FactorIds.Count
    $processedMatrix=[double[,]]::new($rowCount,$predictorCount)
    $rawResponse=[double[]]::new($rowCount)
    $centeredResponse=[double[]]::new($rowCount)
    $responseParameter=$ParameterMap[$Phase+'|response_value_log_return']
    if($null -eq $responseParameter){throw "Missing independent response preprocessing: $Phase"}
    $responseCenter=Parse-CfaIndependentDouble $responseParameter.center "$Phase response center"
    for($rowIndex=0;$rowIndex -lt $rowCount;$rowIndex++){
        $responseValue=Parse-CfaIndependentDouble $Rows[$rowIndex].response_value_log_return "$Phase response row $rowIndex"
        $rawResponse[$rowIndex]=$responseValue
        $centeredResponse[$rowIndex]=$responseValue-$responseCenter
        for($factorIndex=0;$factorIndex -lt $predictorCount;$factorIndex++){
            $factorId=$FactorIds[$factorIndex]
            $parameter=$ParameterMap[$Phase+'|'+$factorId]
            if($null -eq $parameter){throw "Missing independent predictor preprocessing: $Phase $factorId"}
            $center=Parse-CfaIndependentDouble $parameter.center "$Phase $factorId center"
            $scale=Parse-CfaIndependentDouble $parameter.scale "$Phase $factorId scale"
            if($scale -le 0){throw "Non-positive independent predictor scale: $Phase $factorId"}
            $property=$Rows[$rowIndex].PSObject.Properties[$factorId]
            if($null -eq $property){throw "Missing independent predictor property: $factorId"}
            $rawPredictor=Parse-CfaIndependentDouble $property.Value "$Phase $factorId row $rowIndex"
            $processedMatrix[$rowIndex,$factorIndex]=($rawPredictor-$center)/$scale
        }
    }
    return [pscustomobject]@{X=$processedMatrix;y_raw=$rawResponse;y_centered=$centeredResponse;response_center=$responseCenter}
}

function Get-CfaIndependentBenchmarkPredictions {
    param([object[]]$Rows,[string]$BenchmarkId,[double]$ResponseMean)
    $predictions=[double[]]::new($Rows.Count)
    for($rowIndex=0;$rowIndex -lt $Rows.Count;$rowIndex++){
        switch($BenchmarkId){
            'BENCH_ZERO_RETURN' {$predictions[$rowIndex]=0.0}
            'BENCH_PRIOR_MARKET_RETURN' {$predictions[$rowIndex]=Parse-CfaIndependentDouble $Rows[$rowIndex].MKT_RET_USD_UTC_DAY_OBS_L1 "prior market row $rowIndex"}
            'BENCH_RESPONSE_MEAN' {$predictions[$rowIndex]=$ResponseMean}
            default {throw "Unknown independent benchmark: $BenchmarkId"}
        }
    }
    return ,$predictions
}

function Get-CfaIndependentPredictionMap {
    param([object[]]$Rows,[string]$Label)
    $map=@{}
    foreach($row in $Rows){
        $key=([string]$row.base_asset_id)+'|'+([string]$row.response_day_utc)
        if($map.ContainsKey($key)){throw "Duplicate $Label prediction key: $key"}
        $map[$key]=$row
    }
    return $map
}

function Test-CfaStage8IndependentData {
    $factorIds=@('F1','F2')
    $rows=@(
        [pscustomobject]@{response_value_log_return='3';F1='12';F2='16';MKT_RET_USD_UTC_DAY_OBS_L1='0.2'},
        [pscustomobject]@{response_value_log_return='5';F1='8';F2='24';MKT_RET_USD_UTC_DAY_OBS_L1='-0.1'}
    )
    $map=@{
        'SELF|response_value_log_return'=[pscustomobject]@{center='4'}
        'SELF|F1'=[pscustomobject]@{center='10';scale='2'}
        'SELF|F2'=[pscustomobject]@{center='20';scale='4'}
    }
    $processed=New-CfaIndependentProcessedData $rows $map 'SELF' $factorIds
    if($processed.X.GetLength(0) -ne 2 -or $processed.X.GetLength(1) -ne 2){throw 'Independent data matrix shape self-test failed.'}
    $a=$processed.X[0,0];$b=$processed.X[0,1];$c=$processed.X[1,0];$d=$processed.X[1,1]
    if(-not(Test-CfaIndependentNear $a 1.0) -or -not(Test-CfaIndependentNear $b -1.0) -or -not(Test-CfaIndependentNear $c -1.0) -or -not(Test-CfaIndependentNear $d 1.0)){throw 'Independent data matrix value self-test failed.'}
    $bench=Get-CfaIndependentBenchmarkPredictions @($rows[0]) 'BENCH_PRIOR_MARKET_RETURN' 0.0
    if($bench.Count -ne 1 -or -not(Test-CfaIndependentNear $bench[0] 0.2)){throw 'Independent benchmark vector self-test failed.'}
    return $true
}
