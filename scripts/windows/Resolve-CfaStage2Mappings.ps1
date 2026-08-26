#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Split-Pipe{param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text-split'\|'|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}
function Get-OptionalText{param([object]$Object,[string]$Name);if($null-eq$Object){return ''};$p=$Object.PSObject.Properties[$Name];if($null-eq$p){return ''};return [string]$p.Value}
function Get-CandidateRecord{
 param([object]$CandidateRow,[string]$Id)
 if($null-eq$CandidateRow){throw 'Candidate row is null.'}
 try{$records=@(([string]$CandidateRow.candidate_records_json|ConvertFrom-Json))}catch{throw "Malformed AF-002 JSON for $([string]$CandidateRow.base_asset_id): $($_.Exception.Message)"}
 $matches=@($records|Where-Object{[string]$_.id-eq$Id});if($matches.Count-ne1){throw "Expected exactly one AF-002 candidate record for $([string]$CandidateRow.base_asset_id)/$Id; observed $($matches.Count)."};return $matches[0]
}
function Validate-Adjudication{
 param([object]$Adj,[object]$BridgeRow,[object]$CandidateRow)
 $status=[string]$Adj.decision_status;$base=[string]$BridgeRow.base_asset_id
 if($status-eq'NOT_APPLICABLE'){
   if(-not[string]::IsNullOrWhiteSpace([string]$Adj.approved_coingecko_id)){throw "NOT_APPLICABLE adjudication cannot carry CoinGecko id: $base"}
   if(@('AUD','EUR','GBP','USD')-notcontains([string]$BridgeRow.base_exchange_symbol)){throw "NOT_APPLICABLE base is not an approved fiat code: $base/$([string]$BridgeRow.base_exchange_symbol)"}
   return
 }
 if($status-ne'APPROVED'){throw "Unsupported adjudication status for ${base}: $status"}
 $id=[string]$Adj.approved_coingecko_id;if([string]::IsNullOrWhiteSpace($id)){throw "Approved adjudication missing CoinGecko id: $base"}
 $ids=@(Split-Pipe ([string]$BridgeRow.candidate_ids));if($ids-notcontains$id){throw "Adjudicated CoinGecko id $id is not in AF-002 candidate set for $base"}
 $record=Get-CandidateRecord $CandidateRow $id
 if([string]$record.name-ne[string]$Adj.expected_candidate_name){throw "Candidate name mismatch for $base/${id}: AF-002=$([string]$record.name) registry=$([string]$Adj.expected_candidate_name)"}
 if(-not([string]$record.symbol).Equals([string]$Adj.expected_candidate_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw "Candidate symbol mismatch for $base/$id"}
 if(-not([string]$Adj.observed_kraken_ticker).Equals([string]$BridgeRow.base_exchange_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw "Kraken ticker evidence mismatch for $base"}
 if([string]::IsNullOrWhiteSpace([string]$Adj.evidence_source_url)-or[string]::IsNullOrWhiteSpace([string]$Adj.observed_kraken_name)){throw "Incomplete adjudication evidence for $base"}
}
function Resolve-Decision{
 param([object]$Row,[object]$Adj,[object]$CandidateRow)
 $base=[string]$Row.base_asset_id
 if($null-ne$Adj){
   Validate-Adjudication $Adj $Row $CandidateRow
   $evidence=([string]$Adj.review_note+' Source: '+[string]$Adj.evidence_source_url)
   $secondary=Get-OptionalText $Adj 'secondary_evidence_url';if(-not[string]::IsNullOrWhiteSpace($secondary)){$evidence+=' Secondary source: '+$secondary}
   if([string]$Adj.decision_status-eq'NOT_APPLICABLE'){return [pscustomobject]@{status='NOT_APPLICABLE';id='';basis=[string]$Adj.evidence_basis;evidence=$evidence}}
   return [pscustomobject]@{status='APPROVED';id=[string]$Adj.approved_coingecko_id;basis=[string]$Adj.evidence_basis;evidence=$evidence}
 }
 if($base-eq'EDGE'){return [pscustomobject]@{status='APPROVED';id='definitive';basis='ADJUDICATED_KRAKEN_TEMPORAL_IDENTITY';evidence='Kraken Definitive/EDGE listed 2025-03-28; Kraken edgeX listed 2026-05-05 under EDGEX, after Q2.'}}
 if($base-eq'LIT'){return [pscustomobject]@{status='APPROVED';id='litentry';basis='ADJUDICATED_KRAKEN_TEMPORAL_IDENTITY';evidence='Kraken LIT identifies Litentry; Lighter uses Kraken ticker LIGHTER and its token generation postdates Q2 2025.'}}
 if([string]$Row.cfa_independent_review_decision-eq'APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE'-and-not[string]::IsNullOrWhiteSpace([string]$Row.approved_candidate_id)){
   return [pscustomobject]@{status='APPROVED';id=[string]$Row.approved_candidate_id;basis='UNIQUE_CURRENT_KRAKEN_PAIR_BRIDGE';evidence=('CoinGecko/Kraken bridge count evidence: '+[string]$Row.kraken_pair_bridge_counts)}
 }
 return [pscustomobject]@{status='UNVERIFIED';id='';basis=[string]$Row.cfa_independent_review_decision;evidence='No unique independently verified CoinGecko-to-Kraken identity bridge; no inference applied.'}
}
function Invoke-SelfTest{
 $candidate=[pscustomobject]@{base_asset_id='ABC';candidate_records_json='[{"id":"abc","symbol":"abc","name":"Asset ABC","platforms":{}}]'}
 $row=[pscustomobject]@{base_asset_id='ABC';base_exchange_symbol='ABC';candidate_ids='abc';cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='';kraken_pair_bridge_counts='abc:0'}
 $adj=[pscustomobject]@{decision_status='APPROVED';approved_coingecko_id='abc';expected_candidate_name='Asset ABC';expected_candidate_symbol='abc';evidence_basis='TEST';evidence_source_url='https://example.invalid';secondary_evidence_url='https://secondary.invalid';observed_kraken_name='Asset ABC';observed_kraken_ticker='ABC';review_note='test'}
 $r=Resolve-Decision $row $adj $candidate;if($r.status-ne'APPROVED'-or$r.id-ne'abc'-or$r.evidence-notmatch'Secondary source'){throw 'adjudication approval'}
 $fiatRow=[pscustomobject]@{base_asset_id='ZUSD';base_exchange_symbol='USD';candidate_ids='x';cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='';kraken_pair_bridge_counts='x:0'}
 $fiatAdj=[pscustomobject]@{decision_status='NOT_APPLICABLE';approved_coingecko_id='';evidence_basis='FIAT';evidence_source_url='repo';observed_kraken_name='US Dollar';observed_kraken_ticker='USD';review_note='fiat'};$fr=Resolve-Decision $fiatRow $fiatAdj $null;if($fr.status-ne'NOT_APPLICABLE'){throw 'fiat N/A'}
 $e=[pscustomobject]@{base_asset_id='EDGE';base_exchange_symbol='EDGE';candidate_ids='definitive|edgex';cfa_independent_review_decision='UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES';approved_candidate_id='';kraken_pair_bridge_counts='definitive:1|edgex:1'};$er=Resolve-Decision $e $null $null;if($er.id-ne'definitive'){throw 'EDGE override'}
 Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $src=Join-Path $RepoRoot 'docs\evidence\stage2-coingecko-bridge-evidence.csv';if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw 'Published bridge evidence missing.'}
 $rows=@(Import-Csv -LiteralPath $src);if($rows.Count-ne435){throw "Expected 435 bridge rows; observed $($rows.Count)."}
 $candidatePath=Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv';$candidateRows=@(Import-Csv -LiteralPath $candidatePath);if($candidateRows.Count-ne435){throw 'AF-002 row count must be 435.'};$candidateByBase=@{};foreach($c in $candidateRows){$b=[string]$c.base_asset_id;if($candidateByBase.ContainsKey($b)){throw "Duplicate AF-002 base: $b"};$candidateByBase[$b]=$c}
 $adjPaths=@(
   (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Adjudications.csv'),
   (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Adjudications-02.csv'),
   (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Adjudications-03.csv')
 )
 $adjs=@();foreach($p in $adjPaths){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Mapping adjudication registry missing: $p"};$adjs+=@(Import-Csv -LiteralPath $p)}
 $adjByBase=@{};foreach($a in $adjs){$b=[string]$a.base_asset_id;if($adjByBase.ContainsKey($b)){throw "Duplicate mapping adjudication across registries: $b"};$adjByBase[$b]=$a}
 $out=@();foreach($row in $rows){$base=[string]$row.base_asset_id;$adj=if($adjByBase.ContainsKey($base)){$adjByBase[$base]}else{$null};$candidate=if($candidateByBase.ContainsKey($base)){$candidateByBase[$base]}else{$null};$d=Resolve-Decision $row $adj $candidate;$out+=[pscustomobject]@{base_asset_id=$base;base_exchange_symbol=[string]$row.base_exchange_symbol;candidate_ids=[string]$row.candidate_ids;mapping_status=$d.status;approved_coingecko_id=$d.id;decision_basis=$d.basis;evidence_note=$d.evidence}}
 foreach($b in $adjByBase.Keys){if(@($rows|Where-Object{[string]$_.base_asset_id-eq$b}).Count-ne1){throw "Adjudication base not found exactly once in bridge evidence: $b"}}
 $approved=@($out|Where-Object{$_.mapping_status-eq'APPROVED'});$unverified=@($out|Where-Object{$_.mapping_status-eq'UNVERIFIED'});$na=@($out|Where-Object{$_.mapping_status-eq'NOT_APPLICABLE'});if(($approved.Count+$unverified.Count+$na.Count)-ne435){throw 'Mapping decision accounting mismatch.'}
 $expectedNewApproved=@($adjs|Where-Object{$_.decision_status-eq'APPROVED'}).Count;$expectedNa=@($adjs|Where-Object{$_.decision_status-eq'NOT_APPLICABLE'}).Count;if($approved.Count-ne(324+$expectedNewApproved)-or$na.Count-ne$expectedNa){throw "Unexpected adjudication accounting: approved=$($approved.Count) na=$($na.Count) registryApproved=$expectedNewApproved registryNA=$expectedNa"}
 $csv=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv';$out|Sort-Object base_asset_id|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $registryHashes=@($adjPaths|ForEach-Object{(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()})
 $gate=if($unverified.Count-eq0){'PASS'}else{'UNVERIFIED'};$snapshot=[ordered]@{source_bridge_sha256=(Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant();adjudication_registry_sha256s=($registryHashes-join'|');decision_rows=$out.Count;approved=$approved.Count;not_applicable=$na.Count;unverified=$unverified.Count;gate_status=$gate;blocking_reason=if($unverified.Count-eq0){''}else{([string]$unverified.Count+' assets still lack independently verified CoinGecko mapping identity.')}}
 $json=Join-Path $RepoRoot 'docs\evidence\stage2-mapping-decisions.json';Write-Utf8NoBom $json (($snapshot|ConvertTo-Json -Depth 6)+[Environment]::NewLine)
 $b=New-Object System.Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 2 Mapping Decisions');[void]$b.AppendLine('');[void]$b.AppendLine('- Decision rows: 435');[void]$b.AppendLine('- APPROVED: '+$approved.Count);[void]$b.AppendLine('- NOT_APPLICABLE: '+$na.Count);[void]$b.AppendLine('- UNVERIFIED: '+$unverified.Count);[void]$b.AppendLine('- CFA-S2-003: '+$gate);[void]$b.AppendLine('');[void]$b.AppendLine('322 approvals are backed by a unique current CoinGecko/Kraken pair bridge. EDGE and LIT are temporal adjudications. Additional mappings are applied only from staged CFA mapping-adjudication registries after validating the selected CoinGecko ID, name and symbol against AF-002 and the observed Kraken ticker against the Q2 base symbol. Fiat bases are explicitly NOT_APPLICABLE. Unlisted cases remain UNVERIFIED.');[void]$b.AppendLine('');[void]$b.AppendLine('Decision table: candidate-analysis/CFA-Stage2-Mapping-Decisions.csv');[void]$b.AppendLine('Adjudication registries: candidate-analysis/CFA-Stage2-Mapping-Adjudications.csv, candidate-analysis/CFA-Stage2-Mapping-Adjudications-02.csv, and candidate-analysis/CFA-Stage2-Mapping-Adjudications-03.csv');Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-mapping-decisions.md') $b.ToString()
 Write-Host 'CFA STAGE 2 MAPPING DECISIONS: COMPLETE';Write-Host ('APPROVED: '+$approved.Count);Write-Host ('NOT_APPLICABLE: '+$na.Count);Write-Host ('UNVERIFIED: '+$unverified.Count);Write-Host ('CFA-S2-003: '+$gate)
}catch{Write-Host 'CFA STAGE 2 MAPPING DECISIONS: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
