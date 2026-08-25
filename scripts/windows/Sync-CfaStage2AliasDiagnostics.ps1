#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$AllowedPaths=@('docs/evidence/stage2-alias-byte-diagnostics.md','docs/evidence/stage2-alias-archive-diagnostics.csv')
function Invoke-Git{param([string]$WorkingDirectory,[string[]]$Arguments);Push-Location $WorkingDirectory;$old=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$o=@(& git @Arguments 2>&1);$code=$LASTEXITCODE;$text=($o|ForEach-Object{[string]$_})-join[Environment]::NewLine;if($code-ne0){throw "git $($Arguments-join' ') failed with exit code $code.`n$text"};return $text.Trim()}finally{$ErrorActionPreference=$old;Pop-Location}}
function Split-Lines{param([AllowEmptyString()][string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text-split"`r?`n"|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}
function Assert-AllowedStatus{param([AllowEmptyString()][string]$Text);foreach($line in @(Split-Lines $Text)){$ok=$false;foreach($p in $AllowedPaths){if($line.EndsWith($p)-or$line.EndsWith($p.Replace('/','\'))){$ok=$true;break}};if(-not$ok){throw "Unexpected working-tree change during alias diagnostic sync: $line"}}}
function Assert-AllowedPaths{param([string[]]$Paths);foreach($p in @($Paths)){if([string]::IsNullOrWhiteSpace($p)){continue};if($AllowedPaths-notcontains$p){throw "Unexpected staged path: $p"}}}
function Invoke-SelfTest{Assert-AllowedStatus "?? docs/evidence/stage2-alias-byte-diagnostics.md`n?? docs/evidence/stage2-alias-archive-diagnostics.csv";$p=@(Split-Lines "docs/evidence/stage2-alias-byte-diagnostics.md`ndocs/evidence/stage2-alias-archive-diagnostics.csv");Assert-AllowedPaths $p;if($p.Count-ne2){throw 'split count'};$blocked=$false;try{Assert-AllowedStatus "?? docs/evidence/stage2-alias-byte-diagnostics.md`n M README.md"}catch{$blocked=$true};if(-not$blocked){throw 'unrelated change not blocked'};Write-Host 'SELF-TEST: PASS'}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $branch=Invoke-Git $RepoRoot @('branch','--show-current');if([string]::IsNullOrWhiteSpace($branch)){throw 'Current Git branch unresolved.'}
 $pre=Invoke-Git $RepoRoot @('status','--porcelain','--untracked-files=all');Assert-AllowedStatus $pre
 [void](Invoke-Git $RepoRoot @('pull','--ff-only','origin',$branch))
 $pub=Join-Path $RepoRoot 'scripts\windows\Publish-CfaStage2AliasDiagnostics.ps1';& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pub -SelfTest;if($LASTEXITCODE-ne0){throw 'Alias diagnostic publisher self-test failed.'};& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pub;if($LASTEXITCODE-ne0){throw 'Alias diagnostic publisher failed.'}
 $after=Invoke-Git $RepoRoot @('status','--porcelain','--untracked-files=all');Assert-AllowedStatus $after
 if(@(Split-Lines $after).Count-gt0){[void](Invoke-Git $RepoRoot (@('add','--')+$AllowedPaths));$staged=@(Split-Lines (Invoke-Git $RepoRoot @('diff','--cached','--name-only')));Assert-AllowedPaths $staged;if($staged.Count-gt0){[void](Invoke-Git $RepoRoot @('commit','-m','Publish CFA Stage 2 alias byte diagnostics'));[void](Invoke-Git $RepoRoot @('push','origin',$branch))}}
 [void](Invoke-Git $RepoRoot @('fetch','origin',$branch));$local=Invoke-Git $RepoRoot @('rev-parse','HEAD');$remote=Invoke-Git $RepoRoot @('rev-parse',"origin/$branch");if($local-ne$remote){throw "Local/remote HEAD mismatch: $local vs $remote"};$final=Invoke-Git $RepoRoot @('status','--porcelain','--untracked-files=all');if(-not[string]::IsNullOrWhiteSpace($final)){throw "Repository not clean after diagnostic sync.`n$final"};foreach($p in $AllowedPaths){$found=Invoke-Git $RepoRoot @('ls-tree','-r','--name-only',"origin/$branch",'--',$p);if($found-ne$p){throw "Remote diagnostic evidence missing: $p"}}
 Write-Host "Published alias diagnostic evidence commit: $local";Write-Host 'CFA STAGE 2 ALIAS DIAGNOSTIC SYNC: PASS'
}catch{Write-Host 'CFA STAGE 2 ALIAS DIAGNOSTIC SYNC: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
