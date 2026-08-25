#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$ForceRediagnose,[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-LatestValidRun{param([string]$Parent);if(-not(Test-Path -LiteralPath $Parent -PathType Container)){return $null};foreach($run in @(Get-ChildItem -LiteralPath $Parent -Directory -Force|Sort-Object Name -Descending)){$s=Join-Path $run.FullName 'diagnostic-summary.csv';$a=Join-Path $run.FullName 'archive-diagnostics.csv';$r=Join-Path $run.FullName 'row-diagnostics.csv';$i=Join-Path $run.FullName 'invalid-sequence-summary.csv';if((Test-Path $s -PathType Leaf)-and(Test-Path $a -PathType Leaf)-and(Test-Path $r -PathType Leaf)-and(Test-Path $i -PathType Leaf)){$x=@(Import-Csv $s);if($x.Count-eq1-and[int]$x[0].issue_archives-gt0){return $run}}};return $null}
function Invoke-Child{param([string]$Path,[string[]]$Arguments);& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments;$code=$LASTEXITCODE;if($code-ne0){throw "Child failed ${code}: $Path"}}
function Invoke-SelfTest{$root=Join-Path([System.IO.Path]::GetTempPath())('cfa-alias-diag-run-'+[guid]::NewGuid().ToString('N'));try{$d=Join-Path $root 'gdelt-alias-diagnostics\20260101-test';New-Item -ItemType Directory -Path $d -Force|Out-Null;[System.IO.File]::WriteAllText((Join-Path $d 'diagnostic-summary.csv'),"issue_archives`n2`n");foreach($n in @('archive-diagnostics.csv','row-diagnostics.csv','invalid-sequence-summary.csv')){[System.IO.File]::WriteAllText((Join-Path $d $n),"x`n")};$r=Get-LatestValidRun (Join-Path $root 'gdelt-alias-diagnostics');if($null-eq$r-or$r.Name-ne'20260101-test'){throw 'reuse detection'};Write-Host 'SELF-TEST: PASS'}finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$parent=Join-Path([Environment]::GetFolderPath('MyDocuments'))'CFA-local\gdelt-alias-diagnostics'
 $run=$null;if(-not$ForceRediagnose){$run=Get-LatestValidRun $parent}
 if($null-ne$run){Write-Host ('Reusing completed alias byte diagnostics: '+$run.Name)}else{Invoke-Child (Join-Path $RepoRoot 'scripts\windows\Diagnose-CfaStage2AliasEncoding.ps1') @('-RepoRoot',$RepoRoot)}
 Invoke-Child (Join-Path $RepoRoot 'scripts\windows\Sync-CfaStage2AliasDiagnostics.ps1') @('-RepoRoot',$RepoRoot)
 Write-Host 'CFA STAGE 2 ALIAS DIAGNOSTIC RUNNER: PASS'
}catch{Write-Host 'CFA STAGE 2 ALIAS DIAGNOSTIC RUNNER: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
