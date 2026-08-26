#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[string]$EvidenceRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Get-LatestRun{param([string]$Parent);if(-not(Test-Path -LiteralPath $Parent -PathType Container)){throw "Context evidence root missing: $Parent"};$runs=@(Get-ChildItem -LiteralPath $Parent -Directory -Force|Sort-Object Name -Descending);if($runs.Count-eq0){throw "No context evidence runs under: $Parent"};return $runs[0]}
function Require-File{param([System.IO.DirectoryInfo]$Run,[string]$Name);$p=Join-Path $Run.FullName $Name;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required context evidence missing from $($Run.Name): $Name"};return $p}
function Get-Text{param([string]$Path);$t=[System.IO.File]::ReadAllText($Path);if($t.Length-gt0-and[int][char]$t[0]-eq0xFEFF){$t=$t.Substring(1)};return $t.TrimEnd("`r","`n")}

function Write-Receipt{
 param([string]$RepoRootPath,[string]$EvidenceRootPath)
 $run=Get-LatestRun (Join-Path $EvidenceRootPath 'gdelt-alias-context-samples')
 $summaryPath=Require-File $run 'context-diagnostic-summary.csv';$aliasPath=Require-File $run 'alias-context-summary.csv';$samplePath=Require-File $run 'sample-context-evidence.csv'
 $summary=@(Import-Csv $summaryPath);$aliases=@(Import-Csv $aliasPath);$samples=@(Import-Csv $samplePath)
 if($summary.Count-ne1){throw 'Context diagnostic summary cardinality must be 1.'}
 if($samples.Count-ne[int]$summary[0].sample_rows){throw "Context sample row count mismatch: summary=$($summary[0].sample_rows) rows=$($samples.Count)"}
 if($aliases.Count-ne[int]$summary[0].aliases_with_samples){throw "Alias context summary row count mismatch: summary=$($summary[0].aliases_with_samples) rows=$($aliases.Count)"}
 if([string]$summary[0].rule_status-ne'DIAGNOSTIC_ONLY_NOT_APPROVED'){throw 'Context rule status must remain diagnostic-only.'}

 $aliasOut=Join-Path $RepoRootPath 'docs\evidence\stage2-alias-context-sample-summary.csv'
 $sampleOut=Join-Path $RepoRootPath 'docs\evidence\stage2-alias-context-sample-evidence.csv'
 $aliases|Sort-Object base_asset_id,alias_text|Export-Csv -LiteralPath $aliasOut -NoTypeInformation -Encoding UTF8
 $samples|Sort-Object base_asset_id,alias_text,date_utc,record_id|Export-Csv -LiteralPath $sampleOut -NoTypeInformation -Encoding UTF8

 $b=New-Object System.Text.StringBuilder
 [void]$b.AppendLine('# CFA Stage 2 Alias Context Sample Diagnostic');[void]$b.AppendLine('')
 [void]$b.AppendLine('Bounded semantic-context diagnostic over the published alias-recovery sample set. This is diagnostic evidence only and does not approve a news-matching rule. Article titles are not published; SHA-256 plus derived flags preserve bounded traceability.');[void]$b.AppendLine('')
 [void]$b.AppendLine('- Diagnostic run: '+$run.Name);[void]$b.AppendLine('- Source recovery run: '+[string]$summary[0].source_recovery_run);[void]$b.AppendLine('- Sample rows: '+[string]$summary[0].sample_rows);[void]$b.AppendLine('- Aliases with samples: '+[string]$summary[0].aliases_with_samples);[void]$b.AppendLine('- Archives opened: '+[string]$summary[0].archive_files_opened);[void]$b.AppendLine('- Rule status: DIAGNOSTIC_ONLY_NOT_APPROVED');[void]$b.AppendLine('')
 [void]$b.AppendLine('## Diagnostic contract');[void]$b.AppendLine('');[void]$b.AppendLine('```csv');[void]$b.AppendLine((Get-Text $summaryPath));[void]$b.AppendLine('```');[void]$b.AppendLine('')
 [void]$b.AppendLine('Published tables: docs/evidence/stage2-alias-context-sample-summary.csv and docs/evidence/stage2-alias-context-sample-evidence.csv.');[void]$b.AppendLine('')
 foreach($p in @($summaryPath,$aliasPath,$samplePath)){[void]$b.AppendLine('- '+[System.IO.Path]::GetFileName($p)+' SHA-256: '+(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant())}
 $mdOut=Join-Path $RepoRootPath 'docs\evidence\stage2-alias-context-samples.md';Write-Utf8NoBom $mdOut $b.ToString()
 return [pscustomobject]@{run_id=$run.Name;summary=$summary[0];md_path=$mdOut;alias_path=$aliasOut;sample_path=$sampleOut}
}

function Invoke-SelfTest{
 $root=Join-Path([System.IO.Path]::GetTempPath())('cfa-alias-context-pub-'+[guid]::NewGuid().ToString('N'))
 try{$e=Join-Path $root 'CFA-local\gdelt-alias-context-samples\20260101-test';$r=Join-Path $root 'repo';New-Item -ItemType Directory -Path $e -Force|Out-Null;New-Item -ItemType Directory -Path (Join-Path $r 'docs\evidence') -Force|Out-Null;Write-Utf8NoBom (Join-Path $e 'context-diagnostic-summary.csv') "run_id,source_recovery_run,sample_rows,aliases_with_samples,archive_files_opened,rule_status`n20260101-test,recovery,2,1,1,DIAGNOSTIC_ONLY_NOT_APPROVED`n";@([pscustomobject]@{base_asset_id='A';alias_text='Alpha';sample_rows=2})|Export-Csv (Join-Path $e 'alias-context-summary.csv') -NoTypeInformation -Encoding UTF8;@([pscustomobject]@{base_asset_id='A';alias_text='Alpha';date_utc='20250101000000';record_id='1'},[pscustomobject]@{base_asset_id='A';alias_text='Alpha';date_utc='20250101000000';record_id='2'})|Export-Csv (Join-Path $e 'sample-context-evidence.csv') -NoTypeInformation -Encoding UTF8;$x=Write-Receipt $r (Join-Path $root 'CFA-local');if(-not(Test-Path $x.md_path)){throw 'md missing'};if(-not(Test-Path $x.alias_path)){throw 'alias table missing'};if(-not(Test-Path $x.sample_path)){throw 'sample table missing'};$t=[System.IO.File]::ReadAllText($x.md_path);if(-not$t.Contains('20260101-test')){throw 'run id missing'};if($t.Contains($root)){throw 'path leak'};Write-Host 'SELF-TEST: PASS'}finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}
try{if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};if([string]::IsNullOrWhiteSpace($EvidenceRoot)){$EvidenceRoot=Join-Path([Environment]::GetFolderPath('MyDocuments'))'CFA-local'};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$EvidenceRoot=(Resolve-Path -LiteralPath $EvidenceRoot).ProviderPath;$x=Write-Receipt $RepoRoot $EvidenceRoot;Write-Host ('Alias context diagnostic run: '+$x.run_id);Write-Host ('Sample rows: '+[string]$x.summary.sample_rows);Write-Host ('Aliases with samples: '+[string]$x.summary.aliases_with_samples);Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE PUBLISH: PASS'}catch{Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE PUBLISH: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
