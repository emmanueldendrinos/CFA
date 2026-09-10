#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage7ValidationReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage9ValidationReceiptPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage7ValidationReceiptSha='e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756'
$ExpectedStage9ValidationReceiptSha='fee93242132aa46dd11a6f969a49679d51559533a9870255cc928f4a875079bf'
$ExpectedModelReadySha='fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024'
$ExpectedStage9RunReceiptSha='f505f5a3210d543aaa71a5bf352cbb8849c8cb2237923aa7dc018f65cfe5abda'

$NewsFactors=@(
    'NEWS_V6_MATCH_COUNT_24H_LAG15',
    'NEWS_V6_MATCH_COUNT_6H_LAG15',
    'NEWS_V6_SOURCE_COUNT_24H_LAG15'
)

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
. (Join-Path $PSScriptRoot 'CfaStage9AnalysisData.ps1')

function Get-CfaS10Sha {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Require-CfaS10File {param([string]$Path,[string]$Label);$resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"};return $resolved}
function Parse-CfaS10Double {param([object]$Value,[string]$Label);$parsed=0.0;if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$parsed)){throw "Malformed numeric for ${Label}: '$Value'"};if([double]::IsNaN($parsed)-or[double]::IsInfinity($parsed)){throw "Non-finite numeric for ${Label}: '$Value'"};return $parsed}
function Format-CfaS10Double {param([double]$Value);if([double]::IsNaN($Value)){return 'NaN'};return $Value.ToString('R',$Invariant)}

function Get-CfaS10Mean {
    param([System.Collections.IList]$Values)
    if($Values.Count -lt 1){return [double]::NaN}
    $sum=0.0;foreach($value in $Values){$sum += [double]$value};return $sum/$Values.Count
}

function Get-CfaS10SampleSd {
    param([System.Collections.IList]$Values)
    if($Values.Count -lt 2){return [double]::NaN}
    $mean=Get-CfaS10Mean $Values;$ss=0.0;foreach($value in $Values){$delta=[double]$value-$mean;$ss += $delta*$delta};return [math]::Sqrt($ss/($Values.Count-1))
}

function Get-CfaS10Pearson {
    param([System.Collections.IList]$Left,[System.Collections.IList]$Right)
    if($Left.Count -ne $Right.Count -or $Left.Count -lt 2){return [double]::NaN}
    $leftMean=Get-CfaS10Mean $Left;$rightMean=Get-CfaS10Mean $Right;$cross=0.0;$leftSq=0.0;$rightSq=0.0
    for($i=0;$i-lt$Left.Count;$i++){$ld=[double]$Left[$i]-$leftMean;$rd=[double]$Right[$i]-$rightMean;$cross += $ld*$rd;$leftSq += $ld*$ld;$rightSq += $rd*$rd}
    if($leftSq -le 0 -or $rightSq -le 0){return [double]::NaN};return $cross/[math]::Sqrt($leftSq*$rightSq)
}

function Get-CfaS10NearestRank90 {
    param([System.Collections.IList]$Values)
    if($Values.Count -lt 1){return [double]::NaN}
    [double[]]$sorted=@($Values|ForEach-Object{[double]$_}|Sort-Object)
    $rank=[int][math]::Ceiling(0.90*$sorted.Count);if($rank-lt1){$rank=1};return [double]$sorted[$rank-1]
}

function Get-CfaS10Median {
    param([System.Collections.IList]$Values)
    if($Values.Count-lt1){return [double]::NaN}
    [double[]]$sorted=@($Values|ForEach-Object{[double]$_}|Sort-Object)
    $n=$sorted.Count
    if(($n%2)-eq1){return [double]$sorted[[int](($n-1)/2)]}
    $left=[int]($n/2-1);$right=[int]($n/2);return ([double]$sorted[$left]+[double]$sorted[$right])/2.0
}

function Get-CfaS10SymbolFactorMetric {
    param([object[]]$Rows,[string]$Asset,[string]$Surface,[string]$FactorId)
    $factor=New-Object System.Collections.ArrayList;$signed=New-Object System.Collections.ArrayList;$absolute=New-Object System.Collections.ArrayList
    $zeroSigned=New-Object System.Collections.ArrayList;$positiveSigned=New-Object System.Collections.ArrayList;$zeroAbs=New-Object System.Collections.ArrayList;$positiveAbs=New-Object System.Collections.ArrayList
    $min=[double]::PositiveInfinity;$max=[double]::NegativeInfinity
    foreach($row in $Rows){
        $fv=Parse-CfaS10Double $row.PSObject.Properties[$FactorId].Value "$Asset $Surface $FactorId";$rv=Parse-CfaS10Double $row.response_value_log_return "$Asset $Surface response"
        [void]$factor.Add($fv);[void]$signed.Add($rv);[void]$absolute.Add([math]::Abs($rv));if($fv-lt$min){$min=$fv};if($fv-gt$max){$max=$fv}
        if($fv-eq0){[void]$zeroSigned.Add($rv);[void]$zeroAbs.Add([math]::Abs($rv))}else{[void]$positiveSigned.Add($rv);[void]$positiveAbs.Add([math]::Abs($rv))}
    }
    $n=$Rows.Count;$zero=$zeroSigned.Count;$positive=$positiveSigned.Count
    $support=if($n-ge20-and$zero-ge5-and$positive-ge5){'SUFFICIENT_FOR_DIRECTIONAL_DIAGNOSTIC'}else{'INSUFFICIENT_SUPPORT'}
    $zeroMean=Get-CfaS10Mean $zeroSigned;$positiveMean=Get-CfaS10Mean $positiveSigned;$zeroAbsMean=Get-CfaS10Mean $zeroAbs;$positiveAbsMean=Get-CfaS10Mean $positiveAbs
    $directionEffect=if([double]::IsNaN($zeroMean)-or[double]::IsNaN($positiveMean)){[double]::NaN}else{$positiveMean-$zeroMean}
    $magnitudeEffect=if([double]::IsNaN($zeroAbsMean)-or[double]::IsNaN($positiveAbsMean)){[double]::NaN}else{$positiveAbsMean-$zeroAbsMean}
    return [pscustomobject][ordered]@{
        base_asset_id=$Asset;surface=$Surface;factor_id=$FactorId;n=$n;zero_news_rows=$zero;positive_news_rows=$positive;
        news_coverage_rate=Format-CfaS10Double ($positive/[double]$n);mean=Format-CfaS10Double (Get-CfaS10Mean $factor);sample_sd=Format-CfaS10Double (Get-CfaS10SampleSd $factor);min=Format-CfaS10Double $min;max=Format-CfaS10Double $max;
        pearson_signed_return=Format-CfaS10Double (Get-CfaS10Pearson $factor $signed);pearson_absolute_return=Format-CfaS10Double (Get-CfaS10Pearson $factor $absolute);
        mean_signed_zero=Format-CfaS10Double $zeroMean;mean_signed_positive=Format-CfaS10Double $positiveMean;direction_effect_positive_minus_zero=Format-CfaS10Double $directionEffect;
        mean_absolute_zero=Format-CfaS10Double $zeroAbsMean;mean_absolute_positive=Format-CfaS10Double $positiveAbsMean;magnitude_effect_positive_minus_zero=Format-CfaS10Double $magnitudeEffect;
        directional_support=$support;magnitude_support=if($support-eq'SUFFICIENT_FOR_DIRECTIONAL_DIAGNOSTIC'){'SUFFICIENT_FOR_MAGNITUDE_DIAGNOSTIC'}else{'INSUFFICIENT_SUPPORT'}
    }
}

function Get-CfaS10SignStability {
    param($Earlier,$Later,[string]$Property)
    if($Earlier.directional_support-ne'SUFFICIENT_FOR_DIRECTIONAL_DIAGNOSTIC'-or$Later.directional_support-ne'SUFFICIENT_FOR_DIRECTIONAL_DIAGNOSTIC'){return 'UNRESOLVED_SUPPORT'}
    $a=[string]$Earlier.PSObject.Properties[$Property].Value;$b=[string]$Later.PSObject.Properties[$Property].Value
    if($a-eq'NaN'-or$b-eq'NaN'){return 'UNRESOLVED_SUPPORT'}
    $av=Parse-CfaS10Double $a $Property;$bv=Parse-CfaS10Double $b $Property
    if(($av-lt0-and$bv-gt0)-or($av-gt0-and$bv-lt0)){return 'SIGN_REVERSAL'};return 'SAME_SIGN'
}

function New-CfaS10DayCache {
    param([object[]]$Rows)
    $cache=@{}
    foreach($dayGroup in ($Rows|Group-Object response_day_utc)){
        $ordered=@($dayGroup.Group|Sort-Object @{Expression={[double]$_.response_value_log_return}},base_asset_id)
        $values=[double[]]::new($ordered.Count);$index=@{}
        for($i=0;$i-lt$ordered.Count;$i++){$values[$i]=Parse-CfaS10Double $ordered[$i].response_value_log_return 'day return';$index[[string]$ordered[$i].base_asset_id]=$i}
        $cache[[string]$dayGroup.Name]=[pscustomobject]@{values=$values;index_by_asset=$index;n=$ordered.Count;median=(Get-CfaS10Median $values)}
    }
    return $cache
}

function Get-CfaS10LeaveOneOutMedian {
    param($DayCache,[string]$Asset)
    $n=[int]$DayCache.n;if($n-lt2){return [double]::NaN};$remove=[int]$DayCache.index_by_asset[$Asset];$remaining=$n-1
    if(($remaining%2)-eq1){$k=[int](($remaining-1)/2);$orig=if($remove-le$k){$k+1}else{$k};return [double]$DayCache.values[$orig]}
    $k1=[int]($remaining/2-1);$k2=[int]($remaining/2);$o1=if($remove-le$k1){$k1+1}else{$k1};$o2=if($remove-le$k2){$k2+1}else{$k2};return ([double]$DayCache.values[$o1]+[double]$DayCache.values[$o2])/2.0
}

function Get-CfaS10RollingMarketFit {
    param([object[]]$History,$DayCacheMap,[string]$Asset)
    if($History.Count-lt15){return $null}
    $use=@($History|Select-Object -Last 20);$x=New-Object System.Collections.ArrayList;$y=New-Object System.Collections.ArrayList
    foreach($row in $use){$day=[string]$row.response_day_utc;$market=Get-CfaS10LeaveOneOutMedian $DayCacheMap[$day] $Asset;if(-not[double]::IsNaN($market)){[void]$x.Add($market);[void]$y.Add((Parse-CfaS10Double $row.response_value_log_return 'rolling response'))}}
    if($x.Count-lt15){return $null};$xm=Get-CfaS10Mean $x;$ym=Get-CfaS10Mean $y;$cross=0.0;$xx=0.0
    for($i=0;$i-lt$x.Count;$i++){$dx=[double]$x[$i]-$xm;$cross+=$dx*([double]$y[$i]-$ym);$xx+=$dx*$dx}
    if($xx-le0){return $null};$beta=$cross/$xx;$alpha=$ym-$beta*$xm;return [pscustomobject]@{n=$x.Count;alpha=$alpha;beta=$beta}
}

function Test-CfaS10SelfTest {
    $p90=Get-CfaS10NearestRank90 @(1,2,3,4,5,6,7,8,9,10);if($p90-ne9){throw 'Nearest-rank p90 self-test failed.'}
    $median=Get-CfaS10Median @(1,2,3,4);if($median-ne2.5){throw 'Median self-test failed.'}
    $cache=[pscustomobject]@{n=4;values=[double[]]@(1,2,3,4);index_by_asset=@{A=0;B=1;C=2;D=3}}
    $exB=Get-CfaS10LeaveOneOutMedian $cache 'B';if($exB-ne3){throw 'Leave-one-out median self-test failed.'}
    return $true
}

if($SelfTest){try{if(-not(Test-CfaS10SelfTest)){throw 'Stage 10 self-test returned false.'};Write-Host 'SELF-TEST: PASS';exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try {
    $contract=Get-Content -LiteralPath (Require-CfaS10File (Join-Path $RepoRoot 'docs\evidence\stage10-symbol-heterogeneity-contract.md') 'Stage 10 contract') -Raw
    foreach($marker in @('SUFFICIENT_FOR_DIRECTIONAL_DIAGNOSTIC','MARKET_MEDIAN_EX_A','NEWS_BURST_24H','LARGE_MOVE','nearest-rank','SCANNER_DESIGN_BLOCKED')){if($contract-notmatch[regex]::Escape($marker)){throw "Stage 10 contract marker missing: $marker"}}
    $stage9Contract=Get-Content -LiteralPath (Require-CfaS10File (Join-Path $RepoRoot 'docs\evidence\stage9-news-incremental-contract.md') 'Stage 9 contract') -Raw
    if($stage9Contract-notmatch'STAGE9_FROZEN'-or$stage9Contract-notmatch'CFA-S9-008_PASS'){throw 'Frozen Stage 9 repository markers missing.'}

    $Stage7ValidationReceiptPath=Require-CfaS10File $Stage7ValidationReceiptPath 'Stage 7 validation receipt';$Stage9ValidationReceiptPath=Require-CfaS10File $Stage9ValidationReceiptPath 'Stage 9 validation receipt'
    if((Get-CfaS10Sha $Stage7ValidationReceiptPath)-ne$ExpectedStage7ValidationReceiptSha){throw 'Stage 7 validation receipt SHA mismatch.'}
    if((Get-CfaS10Sha $Stage9ValidationReceiptPath)-ne$ExpectedStage9ValidationReceiptSha){throw 'Stage 9 validation receipt SHA mismatch.'}
    $stage7=Get-Content -LiteralPath $Stage7ValidationReceiptPath -Raw|ConvertFrom-Json;$stage9=Get-Content -LiteralPath $Stage9ValidationReceiptPath -Raw|ConvertFrom-Json
    if([string]$stage7.status-ne'PASS'-or[string]$stage7.stage-ne'CFA_STAGE_7'){throw 'Stage 7 receipt identity mismatch.'}
    if([string]$stage9.status-ne'PASS'-or[string]$stage9.stage-ne'CFA_STAGE_9'){throw 'Stage 9 receipt identity mismatch.'}
    if([string]$stage9.run_receipt_sha256-ne$ExpectedStage9RunReceiptSha){throw 'Stage 9 run receipt SHA mismatch.'}

    $modelPath=Require-CfaS10File ([string]$stage7.outputs.model_ready) 'Frozen Stage 7 model-ready CSV';if((Get-CfaS10Sha $modelPath)-ne$ExpectedModelReadySha){throw 'Frozen model-ready SHA mismatch.'}
    $model=@(Import-Csv -LiteralPath $modelPath);if($model.Count-ne26337){throw "Model-ready row count mismatch: $($model.Count)"}
    $assets=@($model|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique);$days=@($model|ForEach-Object{[string]$_.response_day_utc}|Sort-Object -Unique)

    $sensitivity=New-Object System.Collections.ArrayList;$metricMap=@{}
    foreach($asset in $assets){
        $assetRows=@($model|Where-Object{[string]$_.base_asset_id-ceq$asset}|Sort-Object response_day_utc)
        foreach($surface in @('ALL','TRAIN','VALIDATION','TEST')){
            $surfaceRows=if($surface-eq'ALL'){$assetRows}else{@($assetRows|Where-Object{[string]$_.design_role-eq$surface})}
            if($surfaceRows.Count-lt1){continue}
            foreach($factorId in $NewsFactors){$metric=Get-CfaS10SymbolFactorMetric $surfaceRows $asset $surface $factorId;[void]$sensitivity.Add($metric);$metricMap[$asset+'|'+$surface+'|'+$factorId]=$metric}
        }
    }

    $stability=New-Object System.Collections.ArrayList
    foreach($asset in $assets){foreach($factorId in $NewsFactors){foreach($pair in @(@('TRAIN','VALIDATION'),@('VALIDATION','TEST'),@('TRAIN','TEST'))){$earlier=$metricMap[$asset+'|'+$pair[0]+'|'+$factorId];$later=$metricMap[$asset+'|'+$pair[1]+'|'+$factorId];if($null-eq$earlier-or$null-eq$later){continue};[void]$stability.Add([pscustomobject][ordered]@{base_asset_id=$asset;factor_id=$factorId;earlier_surface=$pair[0];later_surface=$pair[1];signed_correlation_stability=(Get-CfaS10SignStability $earlier $later 'pearson_signed_return');direction_effect_stability=(Get-CfaS10SignStability $earlier $later 'direction_effect_positive_minus_zero');absolute_correlation_stability=(Get-CfaS10SignStability $earlier $later 'pearson_absolute_return');magnitude_effect_stability=(Get-CfaS10SignStability $earlier $later 'magnitude_effect_positive_minus_zero')})}}}

    $dayCache=New-CfaS10DayCache $model
    $marketReference=New-Object System.Collections.ArrayList
    foreach($day in $days){$dc=$dayCache[$day];[void]$marketReference.Add([pscustomobject][ordered]@{response_day_utc=$day;n_assets=$dc.n;market_median_return=(Format-CfaS10Double $dc.median)})}

    $events=New-Object System.Collections.ArrayList;$eventSummaryMap=@{}
    foreach($asset in $assets){
        $assetRows=@($model|Where-Object{[string]$_.base_asset_id-ceq$asset}|Sort-Object response_day_utc)
        for($i=0;$i-lt$assetRows.Count;$i++){
            $row=$assetRows[$i];$day=[string]$row.response_day_utc;$response=Parse-CfaS10Double $row.response_value_log_return "$asset $day response";$history=if($i-gt0){@($assetRows[0..($i-1)])}else{@()};$recent=if($history.Count-gt20){@($history|Select-Object -Last 20)}else{$history}
            $eventThreshold=[double]::NaN;$largeMove=$false;$eventSupport=$recent.Count-ge10
            if($eventSupport){$absHistory=@($recent|ForEach-Object{[math]::Abs((Parse-CfaS10Double $_.response_value_log_return 'event history'))});$eventThreshold=Get-CfaS10NearestRank90 $absHistory;$largeMove=([math]::Abs($response)-gt$eventThreshold)}
            $burst24=$false;$burst6=$false;$burstSource=$false;$q24=[double]::NaN;$q6=[double]::NaN;$qSource=[double]::NaN
            if($recent.Count-ge10){
                $vals24=@($recent|ForEach-Object{Parse-CfaS10Double $_.NEWS_V6_MATCH_COUNT_24H_LAG15 'news24 history'});$vals6=@($recent|ForEach-Object{Parse-CfaS10Double $_.NEWS_V6_MATCH_COUNT_6H_LAG15 'news6 history'});$valsSource=@($recent|ForEach-Object{Parse-CfaS10Double $_.NEWS_V6_SOURCE_COUNT_24H_LAG15 'source history'})
                $q24=Get-CfaS10NearestRank90 $vals24;$q6=Get-CfaS10NearestRank90 $vals6;$qSource=Get-CfaS10NearestRank90 $valsSource
                $cur24=Parse-CfaS10Double $row.NEWS_V6_MATCH_COUNT_24H_LAG15 'news24 current';$cur6=Parse-CfaS10Double $row.NEWS_V6_MATCH_COUNT_6H_LAG15 'news6 current';$curSource=Parse-CfaS10Double $row.NEWS_V6_SOURCE_COUNT_24H_LAG15 'source current'
                $burst24=($cur24-gt0-and$cur24-gt$q24);$burst6=($cur6-gt0-and$cur6-gt$q6);$burstSource=($curSource-gt0-and$curSource-gt$qSource)
            }
            $marketEx=Get-CfaS10LeaveOneOutMedian $dayCache[$day] $asset;$fit=Get-CfaS10RollingMarketFit $history $dayCache $asset;$marketComponent=[double]::NaN;$abnormal=[double]::NaN;$label='UNVERIFIED_EVENT_SUPPORT'
            if($eventSupport){if(-not$largeMove){$label='NON_EVENT'}elseif($null-eq$fit){$label='UNVERIFIED'}else{$marketComponent=$fit.alpha+$fit.beta*$marketEx;$abnormal=$response-$marketComponent;$anyBurst=$burst24-or$burst6-or$burstSource;if([math]::Abs($marketComponent)-ge[math]::Abs($abnormal)){$label=if($anyBurst){'MIXED'}else{'MARKET_DOMINANT'}}else{$label=if($anyBurst){'NEWS_ASSOCIATED_ABNORMAL'}else{'SYMBOL_SPECIFIC_NO_NEWS'}}}}
            [void]$events.Add([pscustomobject][ordered]@{base_asset_id=$asset;response_day_utc=$day;design_role=[string]$row.design_role;response_value_log_return=(Format-CfaS10Double $response);abs_response=(Format-CfaS10Double ([math]::Abs($response)));event_threshold_q90_abs_return=(Format-CfaS10Double $eventThreshold);large_move=$largeMove;market_median_ex_asset=(Format-CfaS10Double $marketEx);rolling_market_n=if($null-eq$fit){0}else{$fit.n};rolling_alpha=if($null-eq$fit){'NaN'}else{Format-CfaS10Double $fit.alpha};rolling_beta=if($null-eq$fit){'NaN'}else{Format-CfaS10Double $fit.beta};market_component=(Format-CfaS10Double $marketComponent);abnormal_return=(Format-CfaS10Double $abnormal);news24_q90=(Format-CfaS10Double $q24);news6_q90=(Format-CfaS10Double $q6);source24_q90=(Format-CfaS10Double $qSource);news_burst_24h=$burst24;news_burst_6h=$burst6;source_burst_24h=$burstSource;event_attribution=$label})
        }
    }

    $eventSummary=New-Object System.Collections.ArrayList
    foreach($asset in $assets){$rows=@($events|Where-Object{[string]$_.base_asset_id-ceq$asset});$large=@($rows|Where-Object{$_.large_move-eq$true});$classified=@($large|Where-Object{$_.event_attribution-in@('MARKET_DOMINANT','NEWS_ASSOCIATED_ABNORMAL','MIXED','SYMBOL_SPECIFIC_NO_NEWS')});$newsAssoc=@($classified|Where-Object{$_.event_attribution-eq'NEWS_ASSOCIATED_ABNORMAL'}).Count;$marketDom=@($classified|Where-Object{$_.event_attribution-eq'MARKET_DOMINANT'}).Count;$mixed=@($classified|Where-Object{$_.event_attribution-eq'MIXED'}).Count;$specific=@($classified|Where-Object{$_.event_attribution-eq'SYMBOL_SPECIFIC_NO_NEWS'}).Count;[void]$eventSummary.Add([pscustomobject][ordered]@{base_asset_id=$asset;rows=$rows.Count;large_move_events=$large.Count;classified_large_move_events=$classified.Count;market_dominant_events=$marketDom;news_associated_abnormal_events=$newsAssoc;mixed_events=$mixed;symbol_specific_no_news_events=$specific;news_associated_abnormal_share=if($classified.Count-gt0){Format-CfaS10Double ($newsAssoc/[double]$classified.Count)}else{'NaN'};market_dominant_share=if($classified.Count-gt0){Format-CfaS10Double ($marketDom/[double]$classified.Count)}else{'NaN'}})}

    $profile=New-Object System.Collections.ArrayList
    foreach($asset in $assets){$m24=$metricMap[$asset+'|ALL|NEWS_V6_MATCH_COUNT_24H_LAG15'];$m6=$metricMap[$asset+'|ALL|NEWS_V6_MATCH_COUNT_6H_LAG15'];$ms=$metricMap[$asset+'|ALL|NEWS_V6_SOURCE_COUNT_24H_LAG15'];$es=@($eventSummary|Where-Object{[string]$_.base_asset_id-ceq$asset})[0];$trainTest=@($stability|Where-Object{[string]$_.base_asset_id-ceq$asset-and$_.earlier_surface-eq'TRAIN'-and$_.later_surface-eq'TEST'});$reversals=@($trainTest|Where-Object{$_.signed_correlation_stability-eq'SIGN_REVERSAL'-or$_.direction_effect_stability-eq'SIGN_REVERSAL'}).Count;[void]$profile.Add([pscustomobject][ordered]@{base_asset_id=$asset;n=$m24.n;news24_coverage_rate=$m24.news_coverage_rate;news24_direction_effect=$m24.direction_effect_positive_minus_zero;news24_magnitude_effect=$m24.magnitude_effect_positive_minus_zero;news24_signed_correlation=$m24.pearson_signed_return;news24_absolute_correlation=$m24.pearson_absolute_return;news6_coverage_rate=$m6.news_coverage_rate;news6_direction_effect=$m6.direction_effect_positive_minus_zero;news6_magnitude_effect=$m6.magnitude_effect_positive_minus_zero;source24_coverage_rate=$ms.news_coverage_rate;source24_direction_effect=$ms.direction_effect_positive_minus_zero;source24_magnitude_effect=$ms.magnitude_effect_positive_minus_zero;sufficient_all_24h=($m24.directional_support-eq'SUFFICIENT_FOR_DIRECTIONAL_DIAGNOSTIC');train_test_direction_reversal_indicators=$reversals;large_move_events=$es.large_move_events;classified_large_move_events=$es.classified_large_move_events;news_associated_abnormal_events=$es.news_associated_abnormal_events;news_associated_abnormal_share=$es.news_associated_abnormal_share;market_dominant_events=$es.market_dominant_events;market_dominant_share=$es.market_dominant_share})}

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage10-symbol-heterogeneity'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $sensitivityPath=Join-Path $runDir 'stage10-symbol-news-sensitivity.csv';$stabilityPath=Join-Path $runDir 'stage10-symbol-temporal-stability.csv';$profilePath=Join-Path $runDir 'stage10-symbol-profile-summary.csv';$marketPath=Join-Path $runDir 'stage10-market-reference-by-day.csv';$eventPath=Join-Path $runDir 'stage10-symbol-event-attribution.csv';$eventSummaryPath=Join-Path $runDir 'stage10-event-attribution-summary-by-symbol.csv';$receiptPath=Join-Path $runDir 'stage10-symbol-heterogeneity-run-receipt.json'
    @($sensitivity.ToArray())|Sort-Object base_asset_id,surface,factor_id|Export-Csv -LiteralPath $sensitivityPath -NoTypeInformation -Encoding UTF8
    @($stability.ToArray())|Sort-Object base_asset_id,factor_id,earlier_surface,later_surface|Export-Csv -LiteralPath $stabilityPath -NoTypeInformation -Encoding UTF8
    @($profile.ToArray())|Sort-Object base_asset_id|Export-Csv -LiteralPath $profilePath -NoTypeInformation -Encoding UTF8
    @($marketReference.ToArray())|Sort-Object response_day_utc|Export-Csv -LiteralPath $marketPath -NoTypeInformation -Encoding UTF8
    @($events.ToArray())|Sort-Object response_day_utc,base_asset_id|Export-Csv -LiteralPath $eventPath -NoTypeInformation -Encoding UTF8
    @($eventSummary.ToArray())|Sort-Object base_asset_id|Export-Csv -LiteralPath $eventSummaryPath -NoTypeInformation -Encoding UTF8

    $sufficient24=@($profile|Where-Object{$_.sufficient_all_24h-eq$true}).Count;$newsEventSymbols=@($eventSummary|Where-Object{[int]$_.news_associated_abnormal_events-gt0}).Count;$marketDomSymbols=@($eventSummary|Where-Object{[int]$_.market_dominant_events-gt0}).Count
    $receipt=[ordered]@{status='VALIDATION_CANDIDATE';stage='CFA_STAGE_10';run='SYMBOL_HETEROGENEITY_V1';interpretation='POSTHOC_EXPLORATORY';sources=[ordered]@{stage7_validation_receipt=$Stage7ValidationReceiptPath;stage7_validation_receipt_sha256=(Get-CfaS10Sha $Stage7ValidationReceiptPath);stage9_validation_receipt=$Stage9ValidationReceiptPath;stage9_validation_receipt_sha256=(Get-CfaS10Sha $Stage9ValidationReceiptPath);model_ready=$modelPath;model_ready_sha256=(Get-CfaS10Sha $modelPath)};counts=[ordered]@{rows=$model.Count;assets=$assets.Count;days=$days.Count;sufficient_24h_symbols=$sufficient24;symbols_with_news_associated_abnormal_events=$newsEventSymbols;symbols_with_market_dominant_events=$marketDomSymbols};outputs=[ordered]@{symbol_news_sensitivity=$sensitivityPath;symbol_news_sensitivity_sha256=(Get-CfaS10Sha $sensitivityPath);symbol_temporal_stability=$stabilityPath;symbol_temporal_stability_sha256=(Get-CfaS10Sha $stabilityPath);symbol_profile_summary=$profilePath;symbol_profile_summary_sha256=(Get-CfaS10Sha $profilePath);market_reference_by_day=$marketPath;market_reference_by_day_sha256=(Get-CfaS10Sha $marketPath);symbol_event_attribution=$eventPath;symbol_event_attribution_sha256=(Get-CfaS10Sha $eventPath);event_attribution_summary_by_symbol=$eventSummaryPath;event_attribution_summary_by_symbol_sha256=(Get-CfaS10Sha $eventSummaryPath)};gates=[ordered]@{'CFA-S10-001'='PASS';'CFA-S10-002'='PASS';'CFA-S10-003'='PASS';'CFA-S10-004'='PASS';'CFA-S10-005'='PASS';'CFA-S10-006'='PASS';'CFA-S10-007'='BLOCKED';'CFA-S10-008'='BLOCKED'};next_action='Independently validate per-symbol sensitivity, stability, market reference, rolling burst thresholds and event-attribution outputs before scanner design.'}
    [IO.File]::WriteAllText($receiptPath,(($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    $topNews=@($profile|Where-Object{$_.sufficient_all_24h-eq$true-and$_.news24_absolute_correlation-ne'NaN'}|Sort-Object @{Expression={[math]::Abs([double]$_.news24_absolute_correlation)};Descending=$true}|Select-Object -First 10)
    Write-Host '';Write-Host 'CFA STAGE 10 PER-SYMBOL HETEROGENEITY: VALIDATION CANDIDATE';Write-Host "Rows / assets / days: $($model.Count) / $($assets.Count) / $($days.Count)";Write-Host "Symbols with sufficient ALL-period 24h news support: $sufficient24";Write-Host "Symbols with >=1 NEWS_ASSOCIATED_ABNORMAL large-move event: $newsEventSymbols";Write-Host "Symbols with >=1 MARKET_DOMINANT large-move event: $marketDomSymbols";Write-Host 'Top supported symbols by |24h news vs absolute-return correlation|:';foreach($r in $topNews){Write-Host ("  {0}: corr_abs={1}, corr_signed={2}, coverage={3}, magnitude_effect={4}" -f $r.base_asset_id,$r.news24_absolute_correlation,$r.news24_signed_correlation,$r.news24_coverage_rate,$r.news24_magnitude_effect)};Write-Host 'CFA-S10-001 through CFA-S10-006: PASS';Write-Host 'CFA-S10-007 independent validation: BLOCKED';Write-Host 'CFA-S10-008 scanner prerequisites freeze: BLOCKED';Write-Host "Profile summary: $profilePath";Write-Host "Event summary: $eventSummaryPath";Write-Host "Run receipt: $receiptPath";exit 0
}
catch {Write-Host '';Write-Host 'CFA STAGE 10 PER-SYMBOL HETEROGENEITY: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
