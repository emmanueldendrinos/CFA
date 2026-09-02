#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage5ValidationReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$SourcePath=Join-Path $PSScriptRoot 'Validate-CfaStage6DataQualityLeakage.ps1'
if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "Stage 6 source validator missing: $SourcePath"}

if([string]::IsNullOrWhiteSpace($RepoRoot)){$EffectiveRepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}else{$EffectiveRepoRoot=$RepoRoot}
$EffectiveRepoRoot=(Resolve-Path -LiteralPath $EffectiveRepoRoot).ProviderPath
if(-not(Test-Path -LiteralPath (Join-Path $EffectiveRepoRoot 'docs\evidence\stage6-data-quality-leakage-contract.md') -PathType Leaf)){throw "CFA Stage 6 repository-root preflight failed: $EffectiveRepoRoot"}

$text=[IO.File]::ReadAllText($SourcePath)

$targetLineage=@'
            if(([string]$row.pair_token_opaque)-cne([string]$r.pair_token_opaque-or([string]$row.source_member_ordinal).Trim()-cne([string]$r.source_member_ordinal).Trim()){throw 'factor/response lineage mismatch'}
'@
$replacementLineage=@'
            $pairMismatch=([string]$row.pair_token_opaque)-cne([string]$r.pair_token_opaque)
            $ordinalMismatch=([string]$row.source_member_ordinal).Trim()-cne([string]$r.source_member_ordinal).Trim()
            if($pairMismatch -or $ordinalMismatch){throw 'factor/response lineage mismatch'}
'@

$targetSpan=@'
                if([long][math]::Round(($last-$first).TotalMinutes)-ne$mSpan){throw 'market span mismatch'}
'@
$replacementSpan=@'
                $marketSpanExpected=[long]([math]::Round(($last-$first).TotalMinutes))
                if($marketSpanExpected -ne $mSpan){throw 'market span mismatch'}
'@

$targetNews24Incomplete=@'
                $news24Incomplete++;if($complete24){throw '24h incomplete row marked complete'};if($pop-ne'IN_POPULATION'){throw '24h source-incomplete row outside population'};if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)-and-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)){throw '24h incomplete row contains values'}
                if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)-or-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)){throw '24h incomplete row contains partial value'}
'@
$replacementNews24Incomplete=@'
                $news24Incomplete++
                if($complete24){throw '24h incomplete row marked complete'}
                if($pop-ne'IN_POPULATION'){throw '24h source-incomplete row outside population'}
                $has24MatchValue=-not (Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)
                $has24SourceValue=-not (Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)
                if($has24MatchValue -or $has24SourceValue){throw '24h incomplete row contains value'}
'@

$targetNews24Outside=@'
                $news24Outside++;if($pop-ne'OUTSIDE_NEWS_POPULATION'){throw '24h outside row population status mismatch'};if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)-or-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)){throw '24h outside row contains value'}
'@
$replacementNews24Outside=@'
                $news24Outside++
                if($pop-ne'OUTSIDE_NEWS_POPULATION'){throw '24h outside row population status mismatch'}
                $has24MatchValue=-not (Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)
                $has24SourceValue=-not (Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)
                if($has24MatchValue -or $has24SourceValue){throw '24h outside row contains value'}
'@

$targetStatType=@'
function New-Stat {
    return [ordered]@{non_null=[long]0;null=[long]0;min=$null;max=$null;unique=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))}
}
'@
$replacementStatType=@'
function New-Stat {
    return @{non_null=[long]0;null=[long]0;min=$null;max=$null;unique=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))}
}
'@

$targetStatSelfTest=@'
    $failed=$false
    try{[void](Parse-DoubleStrict 'NaN' 'bad double')}catch{$failed=$true}
    if(-not$failed){throw 'Non-finite failure-path self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
'@
$replacementStatSelfTest=@'
    $failed=$false
    try{[void](Parse-DoubleStrict 'NaN' 'bad double')}catch{$failed=$true}
    if(-not$failed){throw 'Non-finite failure-path self-test failed.'}
    $statProbe=New-Stat
    Add-StatValue $statProbe 1.25 '1.25'
    Add-StatNull $statProbe
    if([long]$statProbe.non_null-ne1-or[long]$statProbe.null-ne1-or[double]$statProbe.min-ne1.25-or[double]$statProbe.max-ne1.25-or$statProbe.unique.Count-ne1){throw 'Statistics accumulator self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
'@

foreach($repair in @(
    [pscustomobject]@{Name='lineage';Target=$targetLineage;Replacement=$replacementLineage},
    [pscustomobject]@{Name='market-span';Target=$targetSpan;Replacement=$replacementSpan},
    [pscustomobject]@{Name='news24-incomplete';Target=$targetNews24Incomplete;Replacement=$replacementNews24Incomplete},
    [pscustomobject]@{Name='news24-outside';Target=$targetNews24Outside;Replacement=$replacementNews24Outside},
    [pscustomobject]@{Name='stat-type';Target=$targetStatType;Replacement=$replacementStatType},
    [pscustomobject]@{Name='stat-selftest';Target=$targetStatSelfTest;Replacement=$replacementStatSelfTest}
)){
    $count=[regex]::Matches($text,[regex]::Escape($repair.Target),[Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
    if($count-ne1){throw "Stage 6 V2 $($repair.Name) repair target occurrence count changed: expected 1, observed $count."}
    $text=$text.Replace($repair.Target,$repair.Replacement)
}

foreach($forbidden in @(
    'pair_token_opaque)-cne([string]$r.pair_token_opaque-or',
    '[long][math]::Round(($last-$first).TotalMinutes)-ne$mSpan',
    '-and-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)',
    '-or-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)',
    'return [ordered]@{non_null=[long]0;null=[long]0'
)){
    if($text.Contains($forbidden)){throw "Stage 6 V2 unsafe expression remained after repair: $forbidden"}
}
foreach($required in @('$pairMismatch=','$ordinalMismatch=','$marketSpanExpected=','$has24MatchValue=','$has24SourceValue=','return @{non_null=[long]0;null=[long]0','$statProbe=New-Stat','Statistics accumulator self-test failed.')){if(-not$text.Contains($required)){throw "Stage 6 V2 repair marker missing: $required"}}

$tokens=$null;$parseErrors=$null
[System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$parseErrors)|Out-Null
if($parseErrors.Count-gt0){
    foreach($e in $parseErrors){Write-Host "patched line $($e.Extent.StartLineNumber), col $($e.Extent.StartColumnNumber) :: <$($e.Extent.Text)> :: $($e.Message)"}
    throw 'Patched Stage 6 validator parse failed.'
}

$tempPath=Join-Path ([IO.Path]::GetTempPath()) ('CFA-Stage6-DQ-LeakageV2-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    [IO.File]::WriteAllText($tempPath,$text,(New-Object Text.UTF8Encoding($false)))
    $argsList=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$tempPath,
        '-Stage5ValidationReceiptPath',$Stage5ValidationReceiptPath,
        '-Stage4ResponsesPath',$Stage4ResponsesPath,
        '-RepoRoot',$EffectiveRepoRoot
    )
    if(-not[string]::IsNullOrWhiteSpace($OutputRoot)){$argsList+=@('-OutputRoot',$OutputRoot)}
    if($SelfTest){$argsList+='-SelfTest'}
    & powershell.exe @argsList
    $code=$LASTEXITCODE
    if($null-eq$code){$code=0}
    exit $code
}
finally{Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue}
