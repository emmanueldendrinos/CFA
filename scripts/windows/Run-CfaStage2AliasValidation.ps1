#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$ForceRescan,[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-LatestValidAliasRun{
 param([string]$Parent)
 if(-not(Test-Path -LiteralPath $Parent -PathType Container)){return $null}
 foreach($run in @(Get-ChildItem -LiteralPath $Parent -Directory -Force|Sort-Object Name -Descending)){
   $s=Join-Path $run.FullName 'validation-summary.csv';$a=Join-Path $run.FullName 'alias-validation.csv';$p=Join-Path $run.FullName 'alias-samples.csv';$r=Join-Path $run.FullName 'archive-scan.csv'
   if(-not((Test-Path $s -PathType Leaf)-and(Test-Path $a -PathType Leaf)-and(Test-Path $p -PathType Leaf)-and(Test-Path $r -PathType Leaf))){continue}
   $summary=@(Import-Csv $s);$aliases=@(Import-Csv $a);if($summary.Count-ne1-or$aliases.Count-ne45){continue};if([int]$summary[0].archive_files-ne7163){continue}
   return $run
 }
 return $null
}
function Invoke-Child{param([string]$Path,[string[]]$Arguments);& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments;$code=$LASTEXITCODE;if($code-ne0){throw "Child failed ${code}: $Path"}}
function Invoke-AliasScan{param([string]$Path,[string[]]$Arguments);& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments;$code=$LASTEXITCODE;if($code-eq0){return 'PASS'};if($code-eq2){return 'FAIL'};throw "Alias scan execution failed ${code}: $Path"}
function Invoke-SelfTest{$root=Join-Path([System.IO.Path]::GetTempPath())('cfa-alias-run-'+[guid]::NewGuid().ToString('N'));try{$p=Join-Path $root 'gdelt-alias-validation\20260101-test';New-Item -ItemType Directory -Path $p -Force|Out-Null;[System.IO.File]::WriteAllText((Join-Path $p 'validation-summary.csv'),"archive_files`n7163`n");$rows=@();for($i=1;$i-le45;$i++){$rows+=[pscustomobject]@{base_asset_id=('A'+$i)}};$rows|Export-Csv (Join-Path $p 'alias-validation.csv') -NoTypeInformation;foreach($n in @('alias-samples.csv','archive-scan.csv')){[System.IO.File]::WriteAllText((Join-Path $p $n),"x`n")};$r=Get-LatestValidAliasRun (Join-Path $root 'gdelt-alias-validation');if($null-eq$r-or$r.Name-ne'20260101-test'){throw 'reuse detection'};Write-Host 'SELF-TEST: PASS'}finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$evidenceParent=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\gdelt-alias-validation'
 $run=$null;$scanGate='UNVERIFIED'
 if(-not$ForceRescan){$run=Get-LatestValidAliasRun $evidenceParent}
 if($null-ne$run){Write-Host ('Reusing completed alias validation evidence: '+$run.Name);$summary=@(Import-Csv (Join-Path $run.FullName 'validation-summary.csv'));$bad=[int]$summary[0].malformed_field_count_rows+[int]$summary[0].utf8_failure_archives+[int]$summary[0].entry_count_failures;$scanGate=if($bad-eq0){'PASS'}else{'FAIL'}}else{$scanGate=Invoke-AliasScan (Join-Path $RepoRoot 'scripts\windows\Validate-CfaStage2Aliases.ps1') @('-RepoRoot',$RepoRoot)}
 Invoke-Child (Join-Path $RepoRoot 'scripts\windows\Sync-CfaStage2Evidence.ps1') @('-RepoRoot',$RepoRoot)
 Write-Host '';Write-Host '=== CFA STAGE 2 ALIAS EVIDENCE STATUS ===';Write-Host ('Full GKG parser/encoding gate : '+$scanGate);Write-Host 'CFA-S2-005 Alias semantic validation: UNVERIFIED';Write-Host 'Reason: observation/collision evidence is published; context-required aliases still require an approved context rule.'
}catch{Write-Host 'CFA STAGE 2 ALIAS RUNNER: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
