#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunReceiptPath,
    [Parameter(Mandatory=$true)][string]$ValidationReceiptPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Inv=[Globalization.CultureInfo]::InvariantCulture
$ExpectedAssets=418
$ExpectedScans=8639
$ExpectedMarketRows=836
$ExpectedBreadthRows=17278

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath

function Sha-S11c{param([string]$p);return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function File-S11c{param([string]$p,[string]$label);$x=(Resolve-Path -LiteralPath $p -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $x -PathType Leaf)){throw "$label is not a file: $x"};return $x}
function D-S11c{param($v,[string]$label);$x=0.0;if(-not[double]::TryParse(([string]$v),[Globalization.NumberStyles]::Float,$Inv,[ref]$x)){throw "Malformed numeric for ${label}: '$v'"};if([double]::IsNaN($x)-or[double]::IsInfinity($x)){throw "Non-finite numeric for ${label}: '$v'"};return $x}
function Percentile-S11c{param([double[]]$Values,[double]$P);if($Values.Count-lt1){return [double]::NaN};[double[]]$s=@($Values|Sort-Object);$rank=[int][math]::Ceiling($P*$s.Count);if($rank-lt1){$rank=1};if($rank-gt$s.Count){$rank=$s.Count};return [double]$s[$rank-1]}
function Fmt-S11c{param([double]$v);if([double]::IsNaN($v)){return 'NaN'};return $v.ToString('R',$Inv)}
function Json-S11c{param([string]$p,$v);[IO.File]::WriteAllText($p,(($v|ConvertTo-Json -Depth 12)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}
function Bool-S11c{param($v);$x=([string]$v).Trim().ToLowerInvariant();if($x-in@('true','t')){return $true};if($x-in@('false','f')){return $false};throw "Malformed boolean: $v"}

function SelfTest-S11c{
    [double[]]$v=@(1,2,3,4,5,6,7,8,9,10)
    if((Percentile-S11c $v 0.10)-ne1){throw 'p10 self-test failed'}
    if((Percentile-S11c $v 0.50)-ne5){throw 'p50 self-test failed'}
    if((Percentile-S11c $v 0.90)-ne9){throw 'p90 self-test failed'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{SelfTest-S11c;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
    $RunReceiptPath=File-S11c $RunReceiptPath 'Stage 11 V2 receipt'
    $ValidationReceiptPath=File-S11c $ValidationReceiptPath 'Stage 11 V2R1 validation receipt'
    $runSha=Sha-S11c $RunReceiptPath;$validationSha=Sha-S11c $ValidationReceiptPath
    $r=Get-Content -LiteralPath $RunReceiptPath -Raw|ConvertFrom-Json
    $v=Get-Content -LiteralPath $ValidationReceiptPath -Raw|ConvertFrom-Json
    if([string]$r.status-ne'VALIDATION_CANDIDATE'-or[string]$r.stage-ne'CFA_STAGE_11'-or[string]$r.run-ne'SCANNER_SOURCE_READINESS_V2'){throw 'Stage 11 V2 receipt identity mismatch.'}
    if([string]$v.status-ne'PASS'-or[string]$v.stage-ne'CFA_STAGE_11_INDEPENDENT_VALIDATION'-or[string]$v.run-ne'SCANNER_SOURCE_READINESS_V2'){throw 'Stage 11 validation receipt identity/status mismatch.'}
    if([string]$v.candidate_receipt_sha256-ne$runSha){throw 'Validation receipt does not bind the supplied V2 candidate receipt.'}
    if([string]$v.gates.'CFA-S11-006'-ne'PASS'){throw 'CFA-S11-006 is not PASS in validation receipt.'}
    if([int]$v.counts.scanner_assets-ne$ExpectedAssets-or[int]$v.counts.candidate_scans-ne$ExpectedScans-or[int]$v.counts.market_summary_rows-ne$ExpectedMarketRows-or[int]$v.counts.market_breadth_rows-ne$ExpectedBreadthRows){throw 'Validated Stage 11 cardinalities changed.'}

    foreach($name in @('news_readiness_summary','market_readiness_summary','market_breadth_readiness','source_entry_reconciliation')){
        $p=File-S11c ([string]$r.outputs.$name) $name
        if((Sha-S11c $p)-ne([string]$r.outputs.($name+'_sha256')).ToLowerInvariant()){throw "Output hash mismatch: $name"}
    }

    $marketPath=File-S11c ([string]$r.outputs.market_readiness_summary) 'market readiness summary'
    $breadthPath=File-S11c ([string]$r.outputs.market_breadth_readiness) 'market breadth readiness'
    $newsSummaryPath=File-S11c ([string]$r.outputs.news_readiness_summary) 'news readiness summary'
    $entryPath=File-S11c ([string]$r.outputs.source_entry_reconciliation) 'source entry reconciliation'
    $market=@(Import-Csv -LiteralPath $marketPath);$breadth=@(Import-Csv -LiteralPath $breadthPath);$newsSummary=@(Import-Csv -LiteralPath $newsSummaryPath)
    if($market.Count-ne$ExpectedMarketRows-or$breadth.Count-ne$ExpectedBreadthRows-or$newsSummary.Count-ne2){throw 'Calibration input row counts changed.'}

    $entry=Get-Content -LiteralPath $entryPath -Raw|ConvertFrom-Json
    $profilePath=File-S11c ([string]$entry.stage10.profile) 'Stage 10 profile'
    if((Sha-S11c $profilePath)-ne([string]$entry.stage10.profile_sha256).ToLowerInvariant()){throw 'Stage 10 profile hash mismatch.'}
    $profile=@(Import-Csv -LiteralPath $profilePath);if($profile.Count-ne$ExpectedAssets){throw 'Stage 10 profile row count changed.'}
    $supportedNews=@($profile|Where-Object{Bool-S11c $_.sufficient_all_24h}).Count
    $supportedNoReversal=@($profile|Where-Object{(Bool-S11c $_.sufficient_all_24h)-and[int]$_.train_test_direction_reversal_indicators-eq0}).Count

    $supportGrid=New-Object Collections.ArrayList
    foreach($h in @(60,240)){
        $rows=@($market|Where-Object{[int]$_.horizon_minutes-eq$h});if($rows.Count-ne$ExpectedAssets){throw "Market rows changed for ${h}m: $($rows.Count)"}
        $thresholds=if($h-eq60){@(1,15,30,45,55,60)}else{@(1,60,120,180,220,240)}
        foreach($t in $thresholds){
            $p10Pass=@($rows|Where-Object{(D-S11c $_.p10_obs "${h}m p10_obs")-ge$t}).Count
            $medianPass=@($rows|Where-Object{(D-S11c $_.median_obs "${h}m median_obs")-ge$t}).Count
            [void]$supportGrid.Add([pscustomobject][ordered]@{horizon_minutes=$h;observation_threshold=$t;assets_with_p10_obs_at_least_threshold=$p10Pass;asset_share_p10=(Fmt-S11c ($p10Pass/[double]$ExpectedAssets));assets_with_median_obs_at_least_threshold=$medianPass;asset_share_median=(Fmt-S11c ($medianPass/[double]$ExpectedAssets))})
        }
    }

    $marketDist=New-Object Collections.ArrayList
    foreach($h in @(60,240)){
        $rows=@($market|Where-Object{[int]$_.horizon_minutes-eq$h})
        foreach($field in @('any_share','p10_obs','median_obs','p90_obs','p90_start_gap_minutes','p90_end_gap_minutes')){
            [double[]]$vals=@($rows|ForEach-Object{D-S11c $_.$field "${h}m $field"})
            [void]$marketDist.Add([pscustomobject][ordered]@{horizon_minutes=$h;field=$field;min=Fmt-S11c (($vals|Measure-Object -Minimum).Minimum);p10=Fmt-S11c (Percentile-S11c $vals 0.10);p50=Fmt-S11c (Percentile-S11c $vals 0.50);p90=Fmt-S11c (Percentile-S11c $vals 0.90);max=Fmt-S11c (($vals|Measure-Object -Maximum).Maximum)})
        }
    }

    $breadthSummary=New-Object Collections.ArrayList
    foreach($h in @(60,240)){
        $rows=@($breadth|Where-Object{[int]$_.horizon_minutes-eq$h});if($rows.Count-ne$ExpectedScans){throw "Breadth rows changed for ${h}m: $($rows.Count)"}
        [double[]]$vals=@($rows|ForEach-Object{D-S11c $_.assets_with_any "${h}m assets_with_any"})
        [void]$breadthSummary.Add([pscustomobject][ordered]@{horizon_minutes=$h;scan_count=$rows.Count;min_assets=[int](($vals|Measure-Object -Minimum).Minimum);p01_assets=[int](Percentile-S11c $vals 0.01);p05_assets=[int](Percentile-S11c $vals 0.05);p10_assets=[int](Percentile-S11c $vals 0.10);p50_assets=[int](Percentile-S11c $vals 0.50);p90_assets=[int](Percentile-S11c $vals 0.90);max_assets=[int](($vals|Measure-Object -Maximum).Maximum)})
        foreach($t in @(50,100,150,200,250,300,350,400)){
            $pass=@($rows|Where-Object{[int]$_.assets_with_any-ge$t}).Count
            [void]$breadthSummary.Add([pscustomobject][ordered]@{horizon_minutes=$h;scan_count=$rows.Count;threshold_assets=$t;scans_passing=$pass;share_passing=Fmt-S11c ($pass/[double]$rows.Count)})
        }
    }

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Split-Path -Parent $RunReceiptPath}
    if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $gridPath=Join-Path $OutputRoot 'stage11-calibration-market-observation-threshold-grid.csv'
    $distPath=Join-Path $OutputRoot 'stage11-calibration-market-distributions.csv'
    $breadthSummaryPath=Join-Path $OutputRoot 'stage11-calibration-breadth-summary.csv'
    $summaryPath=Join-Path $OutputRoot 'stage11-calibration-input-summary.json'
    @($supportGrid.ToArray())|Export-Csv -LiteralPath $gridPath -NoTypeInformation -Encoding UTF8
    @($marketDist.ToArray())|Export-Csv -LiteralPath $distPath -NoTypeInformation -Encoding UTF8
    @($breadthSummary.ToArray())|Export-Csv -LiteralPath $breadthSummaryPath -NoTypeInformation -Encoding UTF8

    $n24=@($newsSummary|Where-Object{[int]$_.horizon_hours-eq24})[0];$n6=@($newsSummary|Where-Object{[int]$_.horizon_hours-eq6})[0]
    $summary=[ordered]@{
        status='PASS';stage='CFA_STAGE_11_CALIBRATION_INPUTS';forward_outcomes_inspected=$false;
        source_readiness=[ordered]@{v2_receipt=$RunReceiptPath;v2_receipt_sha256=$runSha;independent_validation_receipt=$ValidationReceiptPath;independent_validation_receipt_sha256=$validationSha;scanner_assets=$ExpectedAssets;candidate_scans=$ExpectedScans};
        news=[ordered]@{news24_complete_scans=[int]$n24.complete_scans;news24_complete_share=[string]$n24.complete_share;news6_complete_scans=[int]$n6.complete_scans;news6_complete_share=[string]$n6.complete_share};
        stage10_profile_context=[ordered]@{supported_24h_news_symbols=$supportedNews;supported_24h_without_train_test_direction_reversal_indicators=$supportedNoReversal;note='Historical Stage 10 profile is descriptive context only; full-period profile values must not be used as scan-time predictors in the historical scanner backtest.'};
        predefined_source_support_grids=[ordered]@{market_60m_observation_thresholds=@(1,15,30,45,55,60);market_240m_observation_thresholds=@(1,60,120,180,220,240);market_breadth_thresholds=@(50,100,150,200,250,300,350,400)};
        outputs=[ordered]@{market_observation_threshold_grid=$gridPath;market_observation_threshold_grid_sha256=Sha-S11c $gridPath;market_distributions=$distPath;market_distributions_sha256=Sha-S11c $distPath;breadth_summary=$breadthSummaryPath;breadth_summary_sha256=Sha-S11c $breadthSummaryPath}
    }
    Json-S11c $summaryPath $summary

    Write-Host ''
    Write-Host 'CFA STAGE 11 SCANNER CALIBRATION INPUT SUMMARY: PASS'
    Write-Host "Scanner assets / candidate scans: $ExpectedAssets / $ExpectedScans"
    Write-Host "GDELT complete scans 24h / 6h: $($n24.complete_scans) / $($n6.complete_scans)"
    Write-Host "Stage10 descriptive news-supported symbols / no-direction-reversal indicators: $supportedNews / $supportedNoReversal"
    foreach($h in @(60,240)){
        $b=@($breadthSummary|Where-Object{[int]$_.horizon_minutes-eq$h-and$null-ne$_.p50_assets})[0]
        Write-Host ("Market breadth {0}m min / p10 / median / p90 / max: {1} / {2} / {3} / {4} / {5}" -f $h,$b.min_assets,$b.p10_assets,$b.p50_assets,$b.p90_assets,$b.max_assets)
    }
    Write-Host 'Forward outcomes inspected: False'
    Write-Host "Market threshold grid: $gridPath"
    Write-Host "Market distributions: $distPath"
    Write-Host "Breadth summary: $breadthSummaryPath"
    Write-Host "Calibration input summary: $summaryPath"
    Write-Host "V2 receipt SHA-256: $runSha"
    Write-Host "Independent validation receipt SHA-256: $validationSha"
    exit 0
}
catch{
    Write-Host ''
    Write-Host 'CFA STAGE 11 SCANNER CALIBRATION INPUT SUMMARY: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
