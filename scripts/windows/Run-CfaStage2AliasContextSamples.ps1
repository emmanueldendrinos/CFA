#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$ForceRescan,[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-LatestValidRun{
 param([string]$Parent)
 if(-not(Test-Path -LiteralPath $Parent -PathType Container)){return $null}
 foreach($run in @(Get-ChildItem -LiteralPath $Parent -Directory -Force|Sort-Object Name -Descending)){
   $summaryPath=Join-Path $run.FullName 'context-diagnostic-summary.csv';$aliasPath=Join-Path $run.FullName 'alias-context-summary.csv';$samplePath=Join-Path $run.FullName 'sample-context-evidence.csv'
   if(-not((Test-Path $summaryPath -PathType Leaf)-and(Test-Path $aliasPath -PathType Leaf)-and(Test-Path $samplePath -PathType Leaf))){continue}
   $summary=@(Import-Csv $summaryPath);$aliases=@(Import-Csv $aliasPath);$samples=@(Import-Csv $samplePath)
   if($summary.Count-ne1){continue};if([string]$summary[0].rule_status-ne'DIAGNOSTIC_ONLY_NOT_APPROVED'){continue};if($samples.Count-ne[int]$summary[0].sample_rows){continue};if($aliases.Count-ne[int]$summary[0].aliases_with_samples){continue}
   return $run
 }
 return $null
}
function Invoke-Child{param([string]$Path,[string[]]$Arguments);& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments | ForEach-Object{Write-Host $_};$code=$LASTEXITCODE;if($code-ne0){throw "Child failed ${code}: $Path"}}
function Invoke-SelfTest{$root=Join-Path([System.IO.Path]::GetTempPath())('cfa-alias-context-run-'+[guid]::NewGuid().ToString('N'));try{$p=Join-Path $root 'gdelt-alias-context-samples\20260101-test';New-Item -ItemType Directory -Path $p -Force|Out-Null;[System.IO.File]::WriteAllText((Join-Path $p 'context-diagnostic-summary.csv'),"sample_rows,aliases_with_samples,rule_status`n2,1,DIAGNOSTIC_ONLY_NOT_APPROVED`n");@([pscustomobject]@{base_asset_id='A';alias_text='Alpha'})|Export-Csv (Join-Path $p 'alias-context-summary.csv') -NoTypeInformation;@([pscustomobject]@{record_id='1'},[pscustomobject]@{record_id='2'})|Export-Csv (Join-Path $p 'sample-context-evidence.csv') -NoTypeInformation;$r=Get-LatestValidRun (Join-Path $root 'gdelt-alias-context-samples');if($null-eq$r-or$r.Name-ne'20260101-test'){throw 'reuse detection'};Write-Host 'SELF-TEST: PASS'}finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $parent=Join-Path([Environment]::GetFolderPath('MyDocuments'))'CFA-local\gdelt-alias-context-samples'
 $run=$null;if(-not$ForceRescan){$run=Get-LatestValidRun $parent}
 if($null-ne$run){Write-Host ('Reusing completed alias context sample diagnostic: '+$run.Name)}else{Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Analyze-CfaStage2AliasContextSamples.ps1') -Arguments @('-RepoRoot',$RepoRoot)}
 Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Sync-CfaStage2AliasContextSamples.ps1') -Arguments @('-RepoRoot',$RepoRoot)
 Write-Host '';Write-Host '=== CFA STAGE 2 ALIAS CONTEXT SAMPLE STATUS ===';Write-Host 'Sample diagnostic publication : PASS';Write-Host 'Alias semantic validation      : UNVERIFIED';Write-Host 'Reason: candidate context signals are diagnostic-only until reviewed against collision samples.';Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE RUNNER: PASS'
}catch{Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE RUNNER: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
