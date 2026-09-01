#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidateReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$SourcePath=Join-Path $PSScriptRoot 'Validate-CfaStage5FactorArtifact.ps1'
if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "Source validator missing: $SourcePath"}

if([string]::IsNullOrWhiteSpace($RepoRoot)){$EffectiveRepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}else{$EffectiveRepoRoot=$RepoRoot}
$EffectiveRepoRoot=(Resolve-Path -LiteralPath $EffectiveRepoRoot).ProviderPath
if(-not(Test-Path -LiteralPath (Join-Path $EffectiveRepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv') -PathType Leaf)){throw "CFA repository-root preflight failed: $EffectiveRepoRoot"}

$text=[IO.File]::ReadAllText($SourcePath)
$target=@'
    foreach($k in $dayAgg.Keys){if(-not$dayByKey.ContainsKey($k)){throw "Missing day-summary row: $k"};$d=$dayByKey[$k];foreach($p in @('response_rows','market_available_rows','market_missing_rows','news24_available_rows','news24_incomplete_rows','news24_outside_rows','news6_available_rows','news6_incomplete_rows','news6_outside_rows')){if((Parse-LongStrict $d.$p "$k day summary $p")-ne[long]$dayAgg[$k][$p]){throw "Day-summary mismatch: $k $p"}}}
'@
$replacement=@'
    foreach($k in $dayAgg.Keys){
        if(-not$dayByKey.ContainsKey($k)){throw "Missing day-summary row: $k"}
        $d=$dayByKey[$k]
        foreach($p in @('response_rows','market_available_rows','market_missing_rows','news24_available_rows','news24_incomplete_rows','news24_outside_rows','news6_available_rows','news6_incomplete_rows','news6_outside_rows')){
            $expectedValue=[long]($dayAgg[$k][$p])
            $observedValue=Parse-LongStrict $d.$p "$k day summary $p"
            if($observedValue-ne$expectedValue){throw "Day-summary mismatch: $k $p"}
        }
    }
'@
$count=[regex]::Matches($text,[regex]::Escape($target),[Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
if($count-ne1){throw "V2 repair target occurrence count changed: expected 1, observed $count."}
$text=$text.Replace($target,$replacement)
if($text.Contains('-ne[long]$dayAgg[$k][$p]')){throw 'Ambiguous day-summary cast remained after V2 repair.'}
if(-not$text.Contains('$expectedValue=[long]($dayAgg[$k][$p])')){throw 'Explicit day-summary expected-value repair missing.'}

$tempPath=Join-Path ([IO.Path]::GetTempPath()) ('CFA-Stage5-FactorArtifactValidatorV2-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    [IO.File]::WriteAllText($tempPath,$text,(New-Object Text.UTF8Encoding($false)))
    $argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$tempPath,'-CandidateReceiptPath',$CandidateReceiptPath,'-Stage4ResponsesPath',$Stage4ResponsesPath,'-RepoRoot',$EffectiveRepoRoot)
    if(-not[string]::IsNullOrWhiteSpace($OutputRoot)){$argsList+=@('-OutputRoot',$OutputRoot)}
    if($SelfTest){$argsList+='-SelfTest'}
    & powershell.exe @argsList
    $code=$LASTEXITCODE;if($null-eq$code){$code=0};exit $code
}
finally{Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue}
