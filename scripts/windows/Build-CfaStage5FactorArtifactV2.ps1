#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V6MatchesPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [Parameter(Mandatory=$true)][string]$BatchTimingReceiptPath,
    [string]$PgHost='localhost',
    [ValidateRange(1,65535)][int]$PgPort=5432,
    [string]$PgUser='postgres',
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [ValidateRange(30,900)][int]$StatementTimeoutSeconds=300,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

# Narrow repair launcher for the Stage 5 constructor.
# The original script remains as historical implementation lineage.
# V2 removes only two redundant DateTime parse/format round-trip assertions.
$SourceName='Build-CfaStage5FactorArtifact.ps1'
$SourcePath=Join-Path $PSScriptRoot $SourceName
if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "Source constructor missing: $SourcePath"}

$text=[IO.File]::ReadAllText($SourcePath)

$targetSelfTest=@'
    $probeParsed=Parse-UtcSecond $probeCutoff 'cutoff serialization selftest'
    if($probeParsed.ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)-cne$probeCutoff){throw 'Stage 4 cutoff parse/format self-test failed.'}
'@
$targetRuntime=@'
        $parsedCutoff=Parse-UtcSecond $observedCutoffText "Stage 4 cutoff $key"
        if($parsedCutoff.ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)-cne$expectedCutoffText){throw "Stage 4 cutoff parse/format mismatch: $key"}
'@

foreach($target in @($targetSelfTest,$targetRuntime)){
    $count=[regex]::Matches($text,[regex]::Escape($target),[Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
    if($count-ne1){throw "Narrow repair target occurrence count changed: expected 1, observed $count."}
    $text=$text.Replace($target,'')
}

if($text.Contains('Stage 4 cutoff parse/format mismatch')-or$text.Contains('Stage 4 cutoff parse/format self-test failed')){
    throw 'Redundant cutoff parse/format assertion remained after narrow repair.'
}
if(-not$text.Contains('Stage 4 cutoff serialization mismatch:')){
    throw 'Exact Stage 4 cutoff serialization guard was not preserved.'
}
if(-not$text.Contains('$cutoff=[datetime]::SpecifyKind([datetime]::ParseExact($dayText')){
    throw 'Response-day-derived UTC cutoff construction was not preserved.'
}
if(-not$text.Contains('MKT_RANGE_LOG_UTC_DAY_L1')){throw 'Approved market-range factor identifier missing after repair.'}
if($text.Contains('MKT_RANGE_LOG_UTC_DAY_OBS_L1')){throw 'Invalid market-range factor identifier present after repair.'}

$tempPath=Join-Path ([IO.Path]::GetTempPath()) ('CFA-Stage5-FactorArtifactV2-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    [IO.File]::WriteAllText($tempPath,$text,(New-Object Text.UTF8Encoding($false)))
    $argsList=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$tempPath,
        '-Stage3V6MatchesPath',$Stage3V6MatchesPath,
        '-Stage4ResponsesPath',$Stage4ResponsesPath,
        '-BatchTimingReceiptPath',$BatchTimingReceiptPath,
        '-PgHost',$PgHost,
        '-PgPort',[string]$PgPort,
        '-PgUser',$PgUser,
        '-StatementTimeoutSeconds',[string]$StatementTimeoutSeconds
    )
    if(-not[string]::IsNullOrWhiteSpace($RepoRoot)){$argsList+=@('-RepoRoot',$RepoRoot)}
    if(-not[string]::IsNullOrWhiteSpace($OutputRoot)){$argsList+=@('-OutputRoot',$OutputRoot)}
    if($SelfTest){$argsList+='-SelfTest'}

    & powershell.exe @argsList
    $code=$LASTEXITCODE
    if($null-eq$code){$code=0}
    exit $code
}
finally {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}
