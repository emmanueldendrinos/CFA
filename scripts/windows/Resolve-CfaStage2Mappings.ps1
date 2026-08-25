#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Resolve-Decision{param([object]$Row)
  $base=[string]$Row.base_asset_id
  if($base -eq 'EDGE'){return [pscustomobject]@{status='APPROVED';id='definitive';basis='ADJUDICATED_KRAKEN_TEMPORAL_IDENTITY';evidence='Kraken Definitive/EDGE listed 2025-03-28; Kraken edgeX listed 2026-05-05 under EDGEX, after Q2.'}}
  if($base -eq 'LIT'){return [pscustomobject]@{status='APPROVED';id='litentry';basis='ADJUDICATED_KRAKEN_TEMPORAL_IDENTITY';evidence='Kraken LIT identifies Litentry; Lighter uses Kraken ticker LIGHTER and its token generation postdates Q2 2025.'}}
  if([string]$Row.cfa_independent_review_decision -eq 'APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE' -and -not [string]::IsNullOrWhiteSpace([string]$Row.approved_candidate_id)){
    return [pscustomobject]@{status='APPROVED';id=[string]$Row.approved_candidate_id;basis='UNIQUE_CURRENT_KRAKEN_PAIR_BRIDGE';evidence=('CoinGecko/Kraken bridge count evidence: '+[string]$Row.kraken_pair_bridge_counts)}
  }
  return [pscustomobject]@{status='UNVERIFIED';id='';basis=[string]$Row.cfa_independent_review_decision;evidence='No unique independently verified CoinGecko-to-Kraken identity bridge; no inference applied.'}
}
function Invoke-SelfTest{
 $a=[pscustomobject]@{base_asset_id='ABC';cfa_independent_review_decision='APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='abc';kraken_pair_bridge_counts='abc:2'};$r=Resolve-Decision $a;if($r.status-ne'APPROVED'-or$r.id-ne'abc'){throw 'bridge approval'}
 $e=[pscustomobject]@{base_asset_id='EDGE';cfa_independent_review_decision='UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES';approved_candidate_id='';kraken_pair_bridge_counts='definitive:1|edgex:1'};$er=Resolve-Decision $e;if($er.id-ne'definitive'){throw 'EDGE override'}
 $n=[pscustomobject]@{base_asset_id='XYZ';cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='';kraken_pair_bridge_counts='x:0'};$nr=Resolve-Decision $n;if($nr.status-ne'UNVERIFIED'){throw 'unverified'}
 Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}
try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $src=Join-Path $RepoRoot 'docs\evidence\stage2-coingecko-bridge-evidence.csv';if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw 'Published bridge evidence missing.'}
 $rows=@(Import-Csv -LiteralPath $src);if($rows.Count-ne435){throw "Expected 435 bridge rows; observed $($rows.Count)."}
 $out=@();foreach($row in $rows){$d=Resolve-Decision $row;$out+=[pscustomobject]@{base_asset_id=[string]$row.base_asset_id;base_exchange_symbol=[string]$row.base_exchange_symbol;candidate_ids=[string]$row.candidate_ids;mapping_status=$d.status;approved_coingecko_id=$d.id;decision_basis=$d.basis;evidence_note=$d.evidence}}
 $approved=@($out|Where-Object{$_.mapping_status-eq'APPROVED'});$unverified=@($out|Where-Object{$_.mapping_status-eq'UNVERIFIED'});if($approved.Count-ne324-or$unverified.Count-ne111){throw "Unexpected mapping accounting: approved=$($approved.Count) unverified=$($unverified.Count)."}
 $csv=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv';$out|Sort-Object base_asset_id|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $snapshot=[ordered]@{source_bridge_sha256=(Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant();decision_rows=$out.Count;approved=$approved.Count;unverified=$unverified.Count;adjudicated=@('EDGE=definitive','LIT=litentry');gate_status='UNVERIFIED';blocking_reason='111 assets still lack independently verified CoinGecko mapping identity.'}
 $json=Join-Path $RepoRoot 'docs\evidence\stage2-mapping-decisions.json';Write-Utf8NoBom $json (($snapshot|ConvertTo-Json -Depth 6)+[Environment]::NewLine)
 $b=New-Object System.Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 2 Mapping Decisions');[void]$b.AppendLine('');[void]$b.AppendLine('- Decision rows: 435');[void]$b.AppendLine('- APPROVED: 324');[void]$b.AppendLine('- UNVERIFIED: 111');[void]$b.AppendLine('- CFA-S2-003: UNVERIFIED');[void]$b.AppendLine('');[void]$b.AppendLine('322 approvals are backed by a unique current CoinGecko/Kraken pair bridge from the published local evidence. EDGE and LIT are separately adjudicated from direct Kraken temporal identity evidence. The remaining 111 assets are not inferred from symbol similarity or candidate count and remain UNVERIFIED.');[void]$b.AppendLine('');[void]$b.AppendLine('Decision table: candidate-analysis/CFA-Stage2-Mapping-Decisions.csv');Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-mapping-decisions.md') $b.ToString()
 Write-Host 'CFA STAGE 2 MAPPING DECISIONS: COMPLETE';Write-Host 'APPROVED: 324';Write-Host 'UNVERIFIED: 111';Write-Host 'CFA-S2-003: UNVERIFIED'
}catch{Write-Host 'CFA STAGE 2 MAPPING DECISIONS: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
