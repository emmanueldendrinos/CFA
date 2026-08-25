#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$AllowedPaths=@(
 'docs/evidence/latest-stage2-local.md',
 'docs/evidence/stage2-coingecko-bridge-evidence.csv',
 'docs/evidence/stage2-alias-validation.csv',
 'docs/evidence/stage2-alias-samples.csv'
)

function Invoke-Git{param([string]$WorkingDirectory,[string[]]$Arguments);Push-Location $WorkingDirectory;$old=$ErrorActionPreference;try{$ErrorActionPreference='Continue';$o=@(& git @Arguments 2>&1);$code=$LASTEXITCODE;$text=($o|ForEach-Object{[string]$_})-join[Environment]::NewLine;if($code-ne0){throw "git $($Arguments-join' ') failed with exit code $code.`n$text"};return $text.Trim()}finally{$ErrorActionPreference=$old;Pop-Location}}
function Split-GitLines{param([AllowEmptyString()][string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text-split"`r?`n"|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}
function Remove-KnownCommandDebris{param([string]$RepoRootPath);$p=Join-Path $RepoRootPath '-File';if(-not(Test-Path -LiteralPath $p)){return};$i=Get-Item -LiteralPath $p -Force;if($i.PSIsContainer-or[long]$i.Length-ne0){throw "Refusing to remove unexpected -File object: $p"};Remove-Item -LiteralPath $p -Force}
function Assert-OnlyAllowedChanges{param([AllowEmptyString()][string]$StatusText);foreach($line in @(Split-GitLines $StatusText)){$ok=$false;foreach($path in $AllowedPaths){if($line.EndsWith($path)-or$line.EndsWith($path.Replace('/','\'))){$ok=$true;break}};if(-not$ok){throw "Unexpected working-tree change during Stage 2 sync: $line"}}}
function Assert-OnlyAllowedPaths{param([string[]]$Paths);foreach($p in @($Paths)){if([string]::IsNullOrWhiteSpace($p)){continue};if($AllowedPaths-notcontains$p){throw "Unexpected staged path: $p"}}}
function Get-ExistingPublishPaths{param([string]$Root);$r=@();foreach($p in $AllowedPaths){if(Test-Path -LiteralPath (Join-Path $Root ($p.Replace('/','\'))) -PathType Leaf){$r+=$p}};return $r}
function Assert-PublishedState{param([string]$LocalHead,[string]$RemoteHead,[AllowEmptyString()][string]$Status,[string[]]$RemotePaths,[string[]]$ExpectedPaths);if([string]::IsNullOrWhiteSpace($LocalHead)-or$LocalHead-ne$RemoteHead){throw "Stage 2 evidence sync did not converge local/remote HEAD. Local=$LocalHead Remote=$RemoteHead"};if(-not[string]::IsNullOrWhiteSpace($Status)){throw "Repository is not clean after Stage 2 sync.`n$Status"};$o=@($RemotePaths|Sort-Object);$e=@($ExpectedPaths|Sort-Object);if($o.Count-ne$e.Count){throw "Remote Stage 2 evidence path count mismatch. Observed=$($o.Count) Expected=$($e.Count)"};for($i=0;$i-lt$e.Count;$i++){if($o[$i]-ne$e[$i]){throw "Remote Stage 2 evidence mismatch: $($o[$i]) vs $($e[$i])"}}}
function Invoke-SelfTest{$root=Join-Path([System.IO.Path]::GetTempPath())('cfa-s2-sync-'+[guid]::NewGuid().ToString('N'));try{New-Item -ItemType Directory -Path (Join-Path $root 'docs\evidence') -Force|Out-Null;[System.IO.File]::WriteAllText((Join-Path $root 'docs\evidence\latest-stage2-local.md'),'x');[System.IO.File]::WriteAllText((Join-Path $root 'docs\evidence\stage2-coingecko-bridge-evidence.csv'),'x');$core=@(Get-ExistingPublishPaths $root);if($core.Count-ne2){throw 'core publish path count'};[System.IO.File]::WriteAllText((Join-Path $root 'docs\evidence\stage2-alias-validation.csv'),'x');[System.IO.File]::WriteAllText((Join-Path $root 'docs\evidence\stage2-alias-samples.csv'),'x');$all=@(Get-ExistingPublishPaths $root);if($all.Count-ne4){throw 'alias publish path count'};Assert-OnlyAllowedChanges "?? docs/evidence/latest-stage2-local.md`n?? docs/evidence/stage2-alias-validation.csv";$split=@(Split-GitLines "docs/evidence/latest-stage2-local.md`ndocs/evidence/stage2-alias-validation.csv");Assert-OnlyAllowedPaths $split;Assert-PublishedState ('a'*40) ('a'*40) '' $all $all;Write-Host 'SELF-TEST: PASS'}finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $top=Invoke-Git $RepoRoot @('rev-parse','--show-toplevel');if([System.IO.Path]::GetFullPath($top).TrimEnd('\')-ne[System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')){throw 'RepoRoot is not repository top level.'};$branch=Invoke-Git $RepoRoot @('branch','--show-current');if([string]::IsNullOrWhiteSpace($branch)){throw 'Current Git branch is unresolved.'}
 Remove-KnownCommandDebris $RepoRoot;$pre=Invoke-Git $RepoRoot @('status','--porcelain','--untracked-files=all');Assert-OnlyAllowedChanges $pre
 [void](Invoke-Git $RepoRoot @('pull','--ff-only','origin',$branch))
 $publisher=Join-Path $RepoRoot 'scripts\windows\Publish-CfaStage2Evidence.ps1';& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -SelfTest;if($LASTEXITCODE-ne0){throw 'Stage 2 publisher self-test failed.'};& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher;if($LASTEXITCODE-ne0){throw 'Stage 2 publisher failed.'}
 $after=Invoke-Git $RepoRoot @('status','--porcelain','--untracked-files=all');Assert-OnlyAllowedChanges $after;$changed=@(Split-GitLines $after);$publishPaths=@(Get-ExistingPublishPaths $RepoRoot)
 if($changed.Count-gt0){[void](Invoke-Git $RepoRoot (@('add','--')+$publishPaths));$staged=@(Split-GitLines (Invoke-Git $RepoRoot @('diff','--cached','--name-only')));Assert-OnlyAllowedPaths $staged;if($staged.Count-gt0){[void](Invoke-Git $RepoRoot @('commit','-m','Update CFA Stage 2 local evidence'));[void](Invoke-Git $RepoRoot @('push','origin',$branch))}}
 [void](Invoke-Git $RepoRoot @('fetch','origin',$branch));$local=Invoke-Git $RepoRoot @('rev-parse','HEAD');$remote=Invoke-Git $RepoRoot @('rev-parse',"origin/$branch");$final=Invoke-Git $RepoRoot @('status','--porcelain','--untracked-files=all');$remotePaths=@();foreach($p in $publishPaths){$found=Invoke-Git $RepoRoot @('ls-tree','-r','--name-only',"origin/$branch",'--',$p);if(-not[string]::IsNullOrWhiteSpace($found)){$remotePaths+=@(Split-GitLines $found)}};Assert-PublishedState $local $remote $final $remotePaths $publishPaths
 Write-Host "Published Stage 2 evidence commit: $local";Write-Host 'CFA STAGE 2 EVIDENCE SYNC: PASS'
}catch{Write-Host 'CFA STAGE 2 EVIDENCE SYNC: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
