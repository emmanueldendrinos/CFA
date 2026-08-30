#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$target = Join-Path $PSScriptRoot 'Run-CfaStage3NewsMatchingParallelV2R1.ps1'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($target,[ref]$tokens,[ref]$errors)
if($errors.Count-gt0){$errors|ForEach-Object{Write-Host $_.Message};throw 'R1 parse failure.'}

$exitCodeMembers=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Member.Value -eq 'ExitCode'},$true))
if($exitCodeMembers.Count-ne0){throw 'R1 contains forbidden Process ExitCode property access.'}

$functions=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($fn in $functions){Invoke-Expression $fn.Extent.Text}

$ranges=@(Get-WorkerRanges 7163 8)
if($ranges.Count-ne8){throw 'Expected eight ranges.'}
if($ranges[0].start-ne0-or$ranges[0].end-ne895-or$ranges[0].count-ne896){throw 'Worker 0 range mismatch.'}
if($ranges[7].start-ne6268-or$ranges[7].end-ne7162-or$ranges[7].count-ne895){throw 'Worker 7 range mismatch.'}

$root=Join-Path ([IO.Path]::GetTempPath()) ('cfa-s3-r1-test-'+[guid]::NewGuid().ToString('N'))
try{
  $workers=Join-Path $root '_workers';$final=Join-Path $root 'final';New-Item -ItemType Directory -Path $workers,$final -Force|Out-Null
  $rs=@([pscustomobject]@{id=0;start=0;end=1;count=2},[pscustomobject]@{id=1;start=2;end=3;count=2})
  for($i=0;$i-lt2;$i++){
    $d=Get-WorkerDir $workers $i;New-Item -ItemType Directory -Path $d -Force|Out-Null
    $m=@('base_asset_id,record_id,gdelt_date_utc,source_common_name,document_identifier,archive_file,row_ordinal,matched_aliases,matched_surfaces,context_reasons')
    if($i-eq0){$m+=@('A,1,d,s,u,a,1,x,ALLNAMES,NOT_REQUIRED','B,2,d,s,u,a,2,y,PAGE_TITLE,NOT_REQUIRED')}else{$m+=@('A,1,d,s,u,b,1,x,ALLNAMES,NOT_REQUIRED','C,3,d,s,u,b,2,z,PAGE_TITLE,NOT_REQUIRED')}
    [IO.File]::WriteAllLines((Join-Path $d 'matches.csv'),$m)
    [IO.File]::WriteAllLines((Join-Path $d 'rejects.csv'),@('base_asset_id,alias_text,record_id,gdelt_date_utc,source_common_name,document_identifier,archive_file,row_ordinal,matched_surfaces,context_reason',("R$i,x,$i,d,s,u,a,1,ALLNAMES,NONE")))
    [IO.File]::WriteAllLines((Join-Path $d 'samples.csv'),@('match_status,base_asset_id,alias_text,requires_crypto_context,record_id,gdelt_date_utc,source_common_name,document_identifier,page_title,matched_surfaces,econ_bitcoin_theme,title_crypto_anchor,context_reason',("MATCH,A,x,False,$i,d,s,u,t,ALLNAMES,False,False,NOT_REQUIRED")))
    $r=$rs[$i]
    $summary=[ordered]@{worker_id=$i;start_index=$r.start;end_index=$r.end;archive_count=$r.count;rows_scanned=10;malformed_field_count_rows=0;missing_critical_rows=0;malformed_entity_blocks=0;alias_candidates=1;accepted_alias_hits=1;rejected_context_alias_hits=1;partial_unique_matches=2;partial_duplicate_matches=0;partial_matched_assets=2}
    Write-Utf8NoBom (Join-Path $d 'worker-summary.json') (($summary|ConvertTo-Json -Depth 4)+[Environment]::NewLine)
    if(-not(Test-WorkerComplete $workers $r)){throw "Worker completion contract failed: $i"}
  }
  $badPath=Join-Path (Get-WorkerDir $workers 1) 'worker-summary.json';$bad=Get-Content $badPath -Raw|ConvertFrom-Json;$bad.end_index=99;Write-Utf8NoBom $badPath (($bad|ConvertTo-Json -Depth 4)+[Environment]::NewLine)
  if(Test-WorkerComplete $workers $rs[1]){throw 'Corrupt range should fail worker completion contract.'}
  $bad.end_index=3;Write-Utf8NoBom $badPath (($bad|ConvertTo-Json -Depth 4)+[Environment]::NewLine)
  if(-not(Test-WorkerComplete $workers $rs[1])){throw 'Restored worker completion contract should pass.'}
  $merged=Merge-Workers $workers $rs $final 1
  if($merged.match_rows-ne3-or$merged.cross_worker_duplicates-ne1){throw 'Deterministic merge/dedupe failed.'}
  if(@(Import-Csv $merged.samples_path).Count-ne1){throw 'Global sample cap failed.'}
}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}

$text=Get-Content -LiteralPath $target -Raw
foreach($marker in @('Find-ActiveWorkerProcess','Test-WorkerComplete','reused_workers','worker-summary.json')){if($text -notmatch [regex]::Escape($marker)){throw "R1 resume marker missing: $marker"}}
Write-Host 'V2 R1 CONTROLLER TEST: PASS'
