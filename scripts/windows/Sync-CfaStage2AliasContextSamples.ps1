#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$AllowedPaths=@(
 'docs/evidence/stage2-alias-context-samples.md',
 'docs/evidence/stage2-alias-context-sample-summary.csv',
 'docs/evidence/stage2-alias-context-sample-evidence.csv'
)

function Invoke-Git{
 param([string]$Root,[string[]]$Arguments)
 Push-Location $Root
 $old=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';$o=@(& git @Arguments 2>&1);$code=$LASTEXITCODE;$text=($o|ForEach-Object{[string]$_})-join[Environment]::NewLine;if($code-ne0){throw "git $($Arguments-join' ') failed with exit code $code.`n$text"};return $text.Trim()}
 finally{$ErrorActionPreference=$old;Pop-Location}
}
function Split-Lines{param([AllowEmptyString()][string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text-split"`r?`n"|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}
function Assert-Allowed{param([AllowEmptyString()][string]$Status);foreach($line in @(Split-Lines $Status)){$ok=$false;foreach($p in $AllowedPaths){if($line.EndsWith($p)-or$line.EndsWith($p.Replace('/','\'))){$ok=$true;break}};if(-not$ok){throw "Unexpected working-tree change during alias context sync: $line"}}}
function Assert-Paths{param([string[]]$Paths);foreach($p in @($Paths)){if([string]::IsNullOrWhiteSpace($p)){continue};if($AllowedPaths-notcontains$p){throw "Unexpected staged path: $p"}}}

function Invoke-SelfTest{
 $root=Join-Path([System.IO.Path]::GetTempPath())('cfa-alias-context-sync-'+[guid]::NewGuid().ToString('N'))
 try{
   New-Item -ItemType Directory -Path $root -Force|Out-Null
   [void](Invoke-Git -Root $root -Arguments @('init'))
   $top=Invoke-Git -Root $root -Arguments @('rev-parse','--show-toplevel')
   if([System.IO.Path]::GetFullPath($top).TrimEnd('\')-ne[System.IO.Path]::GetFullPath($root).TrimEnd('\')){throw 'real Git invocation failed'}
   Assert-Allowed "?? docs/evidence/stage2-alias-context-samples.md`n?? docs/evidence/stage2-alias-context-sample-summary.csv"
   $paths=@(Split-Lines "docs/evidence/stage2-alias-context-samples.md`ndocs/evidence/stage2-alias-context-sample-summary.csv")
   Assert-Paths $paths
   $blocked=$false;try{Assert-Allowed " M README.md"}catch{$blocked=$true};if(-not$blocked){throw 'unrelated change not blocked'}
   Write-Host 'SELF-TEST: PASS'
 }finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
 $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $branch=Invoke-Git -Root $RepoRoot -Arguments @('branch','--show-current');if([string]::IsNullOrWhiteSpace($branch)){throw 'Current branch unresolved.'}
 $pre=Invoke-Git -Root $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all');Assert-Allowed $pre
 [void](Invoke-Git -Root $RepoRoot -Arguments @('pull','--ff-only','origin',$branch))
 $publisher=Join-Path $RepoRoot 'scripts\windows\Publish-CfaStage2AliasContextSamples.ps1'
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -SelfTest;if($LASTEXITCODE-ne0){throw 'Context publisher self-test failed.'}
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher;if($LASTEXITCODE-ne0){throw 'Context publisher failed.'}
 $after=Invoke-Git -Root $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all');Assert-Allowed $after
 if(@(Split-Lines $after).Count-gt0){[void](Invoke-Git -Root $RepoRoot -Arguments (@('add','--')+$AllowedPaths));$staged=@(Split-Lines (Invoke-Git -Root $RepoRoot -Arguments @('diff','--cached','--name-only')));Assert-Paths $staged;if($staged.Count-gt0){[void](Invoke-Git -Root $RepoRoot -Arguments @('commit','-m','Update CFA Stage 2 alias context sample evidence'));[void](Invoke-Git -Root $RepoRoot -Arguments @('push','origin',$branch))}}
 [void](Invoke-Git -Root $RepoRoot -Arguments @('fetch','origin',$branch));$local=Invoke-Git -Root $RepoRoot -Arguments @('rev-parse','HEAD');$remote=Invoke-Git -Root $RepoRoot -Arguments @('rev-parse',"origin/$branch");if($local-ne$remote){throw "Local/remote mismatch $local $remote"}
 $final=Invoke-Git -Root $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all');if(-not[string]::IsNullOrWhiteSpace($final)){throw "Repository not clean after alias context sync.`n$final"}
 foreach($p in $AllowedPaths){$found=Invoke-Git -Root $RepoRoot -Arguments @('ls-tree','-r','--name-only',"origin/$branch",'--',$p);if([string]::IsNullOrWhiteSpace($found)){throw "Published context evidence missing on remote: $p"}}
 Write-Host "Published alias context sample evidence commit: $local";Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE SYNC: PASS'
}catch{Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE SYNC: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
