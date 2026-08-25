#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[string]$EvidenceRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Get-LatestRun{param([string]$Parent);if(-not(Test-Path -LiteralPath $Parent -PathType Container)){throw "Diagnostic evidence root missing: $Parent"};$runs=@(Get-ChildItem -LiteralPath $Parent -Directory -Force|Sort-Object Name -Descending);if($runs.Count-eq0){throw "No diagnostic runs under: $Parent"};return $runs[0]}
function Require-File{param([System.IO.DirectoryInfo]$Run,[string]$Name);$p=Join-Path $Run.FullName $Name;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required diagnostic file missing from $($Run.Name): $Name"};return $p}
function Get-Text{param([string]$Path);$t=[System.IO.File]::ReadAllText($Path);if($t.Length-gt0-and[int][char]$t[0]-eq0xFEFF){$t=$t.Substring(1)};return $t.TrimEnd("`r","`n")}

function Write-Receipt{
 param([string]$RepoRootPath,[string]$EvidenceRootPath)
 $run=Get-LatestRun (Join-Path $EvidenceRootPath 'gdelt-alias-diagnostics')
 $summaryPath=Require-File $run 'diagnostic-summary.csv';$archivePath=Require-File $run 'archive-diagnostics.csv';$rowPath=Require-File $run 'row-diagnostics.csv';$seqPath=Require-File $run 'invalid-sequence-summary.csv'
 $summary=@(Import-Csv $summaryPath);$archives=@(Import-Csv $archivePath);$seq=@(Import-Csv $seqPath)
 if($summary.Count-ne1){throw 'Diagnostic summary cardinality must be 1.'}
 if([int]$summary[0].issue_archives-ne$archives.Count){throw "Diagnostic archive count mismatch: summary=$($summary[0].issue_archives) rows=$($archives.Count)"}
 $archiveOut=Join-Path $RepoRootPath 'docs\evidence\stage2-alias-archive-diagnostics.csv';$archives|Sort-Object archive_file|Export-Csv -LiteralPath $archiveOut -NoTypeInformation -Encoding UTF8
 $b=New-Object System.Text.StringBuilder
 [void]$b.AppendLine('# CFA Stage 2 Alias Byte Diagnostics');[void]$b.AppendLine('');[void]$b.AppendLine('Targeted byte-level diagnosis of only the archives flagged by the full GKG alias scan. No article text is published. Raw-row traceability uses SHA-256 and field indexes only.');[void]$b.AppendLine('');[void]$b.AppendLine('- Diagnostic run: '+$run.Name);[void]$b.AppendLine('- Source alias validation run: '+[string]$summary[0].source_alias_validation_run);[void]$b.AppendLine('- Issue archives: '+[string]$summary[0].issue_archives);[void]$b.AppendLine('')
 [void]$b.AppendLine('## Diagnostic summary');[void]$b.AppendLine('');[void]$b.AppendLine('```csv');[void]$b.AppendLine((Get-Text $summaryPath));[void]$b.AppendLine('```');[void]$b.AppendLine('')
 [void]$b.AppendLine('## Invalid UTF-8 sequence summary');[void]$b.AppendLine('');[void]$b.AppendLine('```csv');[void]$b.AppendLine((Get-Text $seqPath));[void]$b.AppendLine('```');[void]$b.AppendLine('')
 [void]$b.AppendLine('The bounded per-archive diagnostic table is published separately as docs/evidence/stage2-alias-archive-diagnostics.csv. Full row-level diagnostics remain local.');[void]$b.AppendLine('')
 foreach($p in @($summaryPath,$archivePath,$rowPath,$seqPath)){[void]$b.AppendLine('- '+[System.IO.Path]::GetFileName($p)+' SHA-256: '+(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant())}
 $mdOut=Join-Path $RepoRootPath 'docs\evidence\stage2-alias-byte-diagnostics.md';Write-Utf8NoBom $mdOut $b.ToString()
 return [pscustomobject]@{run_id=$run.Name;summary=$summary[0];md_path=$mdOut;archive_path=$archiveOut}
}

function Invoke-SelfTest{
 $root=Join-Path([System.IO.Path]::GetTempPath())('cfa-alias-diag-pub-'+[guid]::NewGuid().ToString('N'))
 try{$e=Join-Path $root 'CFA-local\gdelt-alias-diagnostics\20260101-test';$r=Join-Path $root 'repo';New-Item -ItemType Directory -Path $e -Force|Out-Null;New-Item -ItemType Directory -Path (Join-Path $r 'docs\evidence') -Force|Out-Null;Write-Utf8NoBom (Join-Path $e 'diagnostic-summary.csv') "run_id,source_alias_validation_run,issue_archives`n20260101-test,source,2`n";@([pscustomobject]@{archive_file='a';status='PASS_NONCRITICAL_UTF8_ONLY'},[pscustomobject]@{archive_file='b';status='FAIL_CRITICAL_FIELD_UTF8'})|Export-Csv (Join-Path $e 'archive-diagnostics.csv') -NoTypeInformation -Encoding UTF8;Write-Utf8NoBom (Join-Path $e 'row-diagnostics.csv') "archive_file,row_ordinal`na,1`n";Write-Utf8NoBom (Join-Path $e 'invalid-sequence-summary.csv') "invalid_sequence_hex,occurrence_count`nE6,1`n";$x=Write-Receipt $r (Join-Path $root 'CFA-local');if(-not(Test-Path $x.md_path)){throw 'md missing'};if(-not(Test-Path $x.archive_path)){throw 'archive output missing'};$t=[System.IO.File]::ReadAllText($x.md_path);if(-not$t.Contains('20260101-test')){throw 'run id missing'};if($t.Contains($root)){throw 'path leak'};Write-Host 'SELF-TEST: PASS'}finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}
try{if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};if([string]::IsNullOrWhiteSpace($EvidenceRoot)){$EvidenceRoot=Join-Path([Environment]::GetFolderPath('MyDocuments'))'CFA-local'};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$EvidenceRoot=(Resolve-Path -LiteralPath $EvidenceRoot).ProviderPath;$x=Write-Receipt $RepoRoot $EvidenceRoot;Write-Host ('Alias diagnostic run: '+$x.run_id);Write-Host ('Issue archives: '+[string]$x.summary.issue_archives);Write-Host ('Raw malformed field-count rows: '+[string]$x.summary.raw_malformed_field_count_rows);Write-Host ('Strict UTF-8 invalid rows: '+[string]$x.summary.strict_utf8_invalid_rows);Write-Host ('ALLNAMES UTF-8 invalid rows: '+[string]$x.summary.allnames_utf8_invalid_rows);Write-Host ('Critical-field UTF-8 invalid rows: '+[string]$x.summary.critical_field_utf8_invalid_rows);Write-Host ('Fieldwise recovery candidate: '+[string]$x.summary.fieldwise_recovery_candidate);Write-Host 'CFA STAGE 2 ALIAS DIAGNOSTIC PUBLISH: PASS'}catch{Write-Host 'CFA STAGE 2 ALIAS DIAGNOSTIC PUBLISH: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
