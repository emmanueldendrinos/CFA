#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Split-Pipe{param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text-split'\|'|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}
function Get-OptionalText{param([object]$Object,[string]$Name);if($null-eq$Object){return ''};$p=$Object.PSObject.Properties[$Name];if($null-eq$p){return ''};return [string]$p.Value}
function Get-AdjudicationEvidenceText{param([object]$Adj);$text=([string]$Adj.review_note+' Source: '+[string]$Adj.evidence_source_url);$secondary=Get-OptionalText $Adj 'secondary_evidence_url';if(-not[string]::IsNullOrWhiteSpace($secondary)){$text+=' Secondary source: '+$secondary};return $text}
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
 if($status-eq'UNVERIFIED'){
   if(-not[string]::IsNullOrWhiteSpace([string]$Adj.approved_coingecko_id)){throw "UNVERIFIED adjudication cannot carry CoinGecko id: $base"}
   if(-not([string]$Adj.observed_kraken_ticker).Equals([string]$BridgeRow.base_exchange_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw "UNVERIFIED Kraken ticker evidence mismatch for $base"}
   if([string]::IsNullOrWhiteSpace([string]$Adj.evidence_basis)-or[string]::IsNullOrWhiteSpace([string]$Adj.evidence_source_url)-or[string]::IsNullOrWhiteSpace([string]$Adj.observed_kraken_name)){throw "Incomplete UNVERIFIED adjudication evidence for $base"}
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
function Validate-ExpandedAdjudication{
 param([object]$Adj,[object]$BridgeRow,[object[]]$ExpandedEvidenceRows)
 $base=[string]$BridgeRow.base_asset_id;$status=[string]$Adj.decision_status
 if($status-ne'APPROVED'){throw "Expanded adjudication must be APPROVED for ${base}: $status"}
 $id=[string]$Adj.approved_coingecko_id;if([string]::IsNullOrWhiteSpace($id)){throw "Expanded adjudication missing CoinGecko id: $base"}
 $af002Ids=@(Split-Pipe ([string]$BridgeRow.candidate_ids));if($af002Ids-contains$id){throw "Expanded adjudication id already exists in AF-002 candidate set for ${base}: $id"}
 $matches=@($ExpandedEvidenceRows|Where-Object{[string]$_.base_asset_id-eq$base-and[string]$_.candidate_id-eq$id})
 if($matches.Count-ne1){throw "Expected one expanded CoinGecko evidence row for $base/${id}; observed $($matches.Count)."}
 $record=$matches[0]
 if([string]$record.candidate_name-ne[string]$Adj.expected_candidate_name){throw "Expanded candidate name mismatch for $base/${id}: evidence=$([string]$record.candidate_name) registry=$([string]$Adj.expected_candidate_name)"}
 if(-not([string]$record.candidate_symbol).Equals([string]$Adj.expected_candidate_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw "Expanded candidate symbol mismatch for $base/$id"}
 if(([string]$record.already_in_af002).Equals('True',[System.StringComparison]::OrdinalIgnoreCase)){throw "Expanded evidence unexpectedly marks candidate as already in AF-002 for $base/$id"}
 if(-not([string]$Adj.observed_kraken_ticker).Equals([string]$BridgeRow.base_exchange_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw "Expanded Kraken ticker evidence mismatch for $base"}
 if([string]::IsNullOrWhiteSpace([string]$Adj.evidence_source_url)-or[string]::IsNullOrWhiteSpace([string]$Adj.observed_kraken_name)){throw "Incomplete expanded adjudication evidence for $base"}
}
function Validate-DirectAdjudication{
 param([object]$Adj,[object]$BridgeRow,[object[]]$DirectEvidenceRows)
 $base=[string]$BridgeRow.base_asset_id;$status=[string]$Adj.decision_status
 if($status-ne'APPROVED'){throw "Direct adjudication must be APPROVED for ${base}: $status"}
 $id=[string]$Adj.approved_coingecko_id;if([string]::IsNullOrWhiteSpace($id)){throw "Direct adjudication missing CoinGecko id: $base"}
 $matches=@($DirectEvidenceRows|Where-Object{[string]$_.base_asset_id-eq$base-and[string]$_.requested_candidate_id-eq$id})
 if($matches.Count-ne1){throw "Expected one direct CoinGecko evidence row for $base/${id}; observed $($matches.Count)."}
 $record=$matches[0]
 if(([int]$record.http_status) -ne 200){throw "Direct CoinGecko evidence is not HTTP 200 for $base/${id}: $([string]$record.http_status)"}
 if([string]$record.parse_status-ne'PASS'){throw "Direct CoinGecko evidence parse status is not PASS for $base/${id}: $([string]$record.parse_status)"}
 if([string]$record.returned_id-ne$id){throw "Direct CoinGecko returned-id mismatch for $base/${id}: $([string]$record.returned_id)"}
 if(-not(([string]$record.response_sha256) -match '^[0-9a-fA-F]{64}$')){throw "Direct CoinGecko response SHA-256 invalid for $base/${id}"}
 if(([int64]$record.response_bytes) -le 0){throw "Direct CoinGecko response is empty for $base/${id}"}
 if([string]$record.returned_name-ne[string]$Adj.expected_returned_name){throw "Direct CoinGecko name mismatch for $base/${id}: evidence=$([string]$record.returned_name) registry=$([string]$Adj.expected_returned_name)"}
 if(-not([string]$record.returned_symbol).Equals([string]$Adj.expected_returned_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw "Direct CoinGecko symbol mismatch for $base/${id}"}
 $expectedPlatform=Get-OptionalText $Adj 'expected_asset_platform_id';if(-not[string]::IsNullOrWhiteSpace($expectedPlatform)-and[string]$record.asset_platform_id-ne$expectedPlatform){throw "Direct CoinGecko asset platform mismatch for $base/${id}"}
 $expectedContract=Get-OptionalText $Adj 'expected_contract_address';if(-not[string]::IsNullOrWhiteSpace($expectedContract)-and[string]$record.contract_address-ne$expectedContract){throw "Direct CoinGecko contract mismatch for $base/${id}"}
 if(-not([string]$Adj.observed_kraken_ticker).Equals([string]$BridgeRow.base_exchange_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw "Direct Kraken ticker evidence mismatch for $base"}
 if([string]::IsNullOrWhiteSpace([string]$Adj.evidence_basis)-or[string]::IsNullOrWhiteSpace([string]$Adj.evidence_source_url)-or[string]::IsNullOrWhiteSpace([string]$Adj.observed_kraken_name)){throw "Incomplete direct adjudication evidence for $base"}
}
function Resolve-Decision{
 param([object]$Row,[object]$Adj,[object]$CandidateRow,[object]$ExpandedAdj,[object[]]$ExpandedEvidenceRows,[object]$DirectAdj,[object[]]$DirectEvidenceRows)
 $base=[string]$Row.base_asset_id
 if($null-ne$Adj){
   Validate-Adjudication $Adj $Row $CandidateRow
   $evidence=Get-AdjudicationEvidenceText $Adj;$status=[string]$Adj.decision_status
   if($status-eq'NOT_APPLICABLE'){return [pscustomobject]@{status='NOT_APPLICABLE';id='';basis=[string]$Adj.evidence_basis;evidence=$evidence}}
   if($status-eq'UNVERIFIED'){return [pscustomobject]@{status='UNVERIFIED';id='';basis=[string]$Adj.evidence_basis;evidence=$evidence}}
   return [pscustomobject]@{status='APPROVED';id=[string]$Adj.approved_coingecko_id;basis=[string]$Adj.evidence_basis;evidence=$evidence}
 }
 if($null-ne$ExpandedAdj){
   Validate-ExpandedAdjudication $ExpandedAdj $Row $ExpandedEvidenceRows
   return [pscustomobject]@{status='APPROVED';id=[string]$ExpandedAdj.approved_coingecko_id;basis=[string]$ExpandedAdj.evidence_basis;evidence=(Get-AdjudicationEvidenceText $ExpandedAdj)}
 }
 if($null-ne$DirectAdj){
   Validate-DirectAdjudication $DirectAdj $Row $DirectEvidenceRows
   return [pscustomobject]@{status='APPROVED';id=[string]$DirectAdj.approved_coingecko_id;basis=[string]$DirectAdj.evidence_basis;evidence=(Get-AdjudicationEvidenceText $DirectAdj)}
 }
 if($base-eq'EDGE'){return [pscustomobject]@{status='APPROVED';id='definitive';basis='ADJUDICATED_KRAKEN_TEMPORAL_IDENTITY';evidence='Kraken Definitive/EDGE listed 2025-03-28; Kraken edgeX listed 2026-05-05 under EDGEX, after Q2.'}}
 if($base-eq'LIT'){return [pscustomobject]@{status='APPROVED';id='litentry';basis='ADJUDICATED_KRAKEN_TEMPORAL_IDENTITY';evidence='Kraken LIT identifies Litentry; Lighter uses Kraken ticker LIGHTER and its token generation postdates Q2 2025.'}}
 if([string]$Row.cfa_independent_review_decision-eq'APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE'-and-not[string]::IsNullOrWhiteSpace([string]$Row.approved_candidate_id)){
   return [pscustomobject]@{status='APPROVED';id=[string]$Row.approved_candidate_id;basis='UNIQUE_CURRENT_KRAKEN_PAIR_BRIDGE';evidence=('CoinGecko/Kraken bridge count evidence: '+[string]$Row.kraken_pair_bridge_counts)}
 }
 return [pscustomobject]@{status='UNVERIFIED';id='';basis=[string]$Row.cfa_independent_review_decision;evidence='No unique independently verified CoinGecko-to-Kraken identity bridge; no inference applied.'}
}
function Assert-Throws{
 param([scriptblock]$Script,[string]$Pattern)
 $caught=$false
 try{&$Script}catch{$caught=$true;if($_.Exception.Message-notmatch$Pattern){throw "Unexpected failure. Expected /$Pattern/; observed: $($_.Exception.Message)"}}
 if(-not$caught){throw "Expected failure matching /$Pattern/ but call succeeded."}
}
function Invoke-SelfTest{
 $candidate=[pscustomobject]@{base_asset_id='ABC';candidate_records_json='[{"id":"abc","symbol":"abc","name":"Asset ABC","platforms":{}}]'}
 $row=[pscustomobject]@{base_asset_id='ABC';base_exchange_symbol='ABC';candidate_ids='abc';cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='';kraken_pair_bridge_counts='abc:0'}
 $adj=[pscustomobject]@{decision_status='APPROVED';approved_coingecko_id='abc';expected_candidate_name='Asset ABC';expected_candidate_symbol='abc';evidence_basis='TEST';evidence_source_url='https://example.invalid';secondary_evidence_url='https://secondary.invalid';observed_kraken_name='Asset ABC';observed_kraken_ticker='ABC';review_note='test'}
 $r=Resolve-Decision $row $adj $candidate $null @() $null @();if($r.status-ne'APPROVED'-or$r.id-ne'abc'-or$r.evidence-notmatch'Secondary source'){throw 'adjudication approval'}
 $unverifiedAdj=[pscustomobject]@{decision_status='UNVERIFIED';approved_coingecko_id='';evidence_basis='TOKEN_VERSION_CONFLICT';evidence_source_url='https://example.invalid/version';secondary_evidence_url='';observed_kraken_name='Asset ABC';observed_kraken_ticker='ABC';review_note='conflict'}
 $ur=Resolve-Decision $row $unverifiedAdj $candidate $null @() $null @();if($ur.status-ne'UNVERIFIED'-or-not[string]::IsNullOrWhiteSpace([string]$ur.id)){throw 'explicit UNVERIFIED adjudication'}
 $expandedRow=[pscustomobject]@{base_asset_id='EXP';base_exchange_symbol='OLD';candidate_ids='wrong';cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='';kraken_pair_bridge_counts='wrong:0'}
 $expandedAdj=[pscustomobject]@{decision_status='APPROVED';approved_coingecko_id='new-id';expected_candidate_name='New Asset';expected_candidate_symbol='new';evidence_basis='EXPANDED_TEST';evidence_source_url='https://example.invalid';observed_kraken_name='New Asset';observed_kraken_ticker='OLD';review_note='expanded'}
 $expandedEvidence=@([pscustomobject]@{base_asset_id='EXP';candidate_id='new-id';candidate_name='New Asset';candidate_symbol='new';already_in_af002='False'})
 $xr=Resolve-Decision $expandedRow $null $null $expandedAdj $expandedEvidence $null @();if($xr.status-ne'APPROVED'-or$xr.id-ne'new-id'){throw 'expanded adjudication approval'}
 $directRow=[pscustomobject]@{base_asset_id='DIR';base_exchange_symbol='DIR';candidate_ids='';cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='';kraken_pair_bridge_counts=''}
 $directAdj=[pscustomobject]@{decision_status='APPROVED';approved_coingecko_id='direct-id';expected_returned_name='Direct Asset';expected_returned_symbol='new';expected_asset_platform_id='ethereum';expected_contract_address='0xabc';evidence_basis='DIRECT_TEST';evidence_source_url='https://example.invalid/direct';secondary_evidence_url='';observed_kraken_name='Direct Asset';observed_kraken_ticker='DIR';review_note='direct'}
 $directRecord=[pscustomobject]@{base_asset_id='DIR';requested_candidate_id='direct-id';http_status='200';response_sha256=(('a'*64)-join'');response_bytes='123';parse_status='PASS';returned_id='direct-id';returned_name='Direct Asset';returned_symbol='new';asset_platform_id='ethereum';contract_address='0xabc'}
 $directEvidence=@($directRecord)
 $dr=Resolve-Decision $directRow $null $null $null @() $directAdj $directEvidence;if($dr.status-ne'APPROVED'-or$dr.id-ne'direct-id'){throw 'direct adjudication approval'}
 $direct404=[pscustomobject]@{base_asset_id='DIR';requested_candidate_id='direct-id';http_status='404';response_sha256=(('b'*64)-join'');response_bytes='26';parse_status='NOT_APPLICABLE';returned_id='';returned_name='';returned_symbol='';asset_platform_id='';contract_address=''}
 Assert-Throws {Validate-DirectAdjudication $directAdj $directRow @($direct404)} 'not HTTP 200'
 $wrongId=[pscustomobject]@{base_asset_id='DIR';requested_candidate_id='direct-id';http_status='200';response_sha256=(('c'*64)-join'');response_bytes='123';parse_status='PASS';returned_id='other';returned_name='Direct Asset';returned_symbol='new';asset_platform_id='ethereum';contract_address='0xabc'}
 Assert-Throws {Validate-DirectAdjudication $directAdj $directRow @($wrongId)} 'returned-id mismatch'
 Assert-Throws {Validate-DirectAdjudication $directAdj $directRow @($directRecord,$directRecord)} 'observed 2'
 $badContractAdj=[pscustomobject]@{decision_status='APPROVED';approved_coingecko_id='direct-id';expected_returned_name='Direct Asset';expected_returned_symbol='new';expected_asset_platform_id='ethereum';expected_contract_address='0xdef';evidence_basis='DIRECT_TEST';evidence_source_url='https://example.invalid/direct';secondary_evidence_url='';observed_kraken_name='Direct Asset';observed_kraken_ticker='DIR';review_note='direct'}
 Assert-Throws {Validate-DirectAdjudication $badContractAdj $directRow $directEvidence} 'contract mismatch'
 $fiatRow=[pscustomobject]@{base_asset_id='ZUSD';base_exchange_symbol='USD';candidate_ids='x';cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id='';kraken_pair_bridge_counts='x:0'}
 $fiatAdj=[pscustomobject]@{decision_status='NOT_APPLICABLE';approved_coingecko_id='';evidence_basis='FIAT';evidence_source_url='repo';observed_kraken_name='US Dollar';observed_kraken_ticker='USD';review_note='fiat'};$fr=Resolve-Decision $fiatRow $fiatAdj $null $null @() $null @();if($fr.status-ne'NOT_APPLICABLE'){throw 'fiat N/A'}
 $e=[pscustomobject]@{base_asset_id='EDGE';base_exchange_symbol='EDGE';candidate_ids='definitive|edgex';cfa_independent_review_decision='UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES';approved_candidate_id='';kraken_pair_bridge_counts='definitive:1|edgex:1'};$er=Resolve-Decision $e $null $null $null @() $null @();if($er.id-ne'definitive'){throw 'EDGE override'}
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
 $expandedAdjPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Expanded-Adjudications.csv';if(-not(Test-Path -LiteralPath $expandedAdjPath -PathType Leaf)){throw 'Expanded mapping adjudication registry missing.'};$expandedAdjs=@(Import-Csv -LiteralPath $expandedAdjPath);$expandedAdjByBase=@{};foreach($a in $expandedAdjs){$b=[string]$a.base_asset_id;if($expandedAdjByBase.ContainsKey($b)-or$adjByBase.ContainsKey($b)){throw "Duplicate/overlapping expanded mapping adjudication: $b"};$expandedAdjByBase[$b]=$a}
 $expandedEvidencePath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Expanded-CoinGecko-Candidates.csv';if(-not(Test-Path -LiteralPath $expandedEvidencePath -PathType Leaf)){throw 'Expanded CoinGecko candidate evidence missing.'};$expandedEvidenceRows=@(Import-Csv -LiteralPath $expandedEvidencePath);if($expandedEvidenceRows.Count-le0){throw 'Expanded CoinGecko candidate evidence is empty.'}
 $directAdjPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Direct-Adjudications.csv';if(-not(Test-Path -LiteralPath $directAdjPath -PathType Leaf)){throw 'Direct mapping adjudication registry missing.'};$directAdjs=@(Import-Csv -LiteralPath $directAdjPath);$directAdjByBase=@{};foreach($a in $directAdjs){$b=[string]$a.base_asset_id;if([string]::IsNullOrWhiteSpace($b)){throw 'Direct adjudication base is empty.'};if($directAdjByBase.ContainsKey($b)-or$adjByBase.ContainsKey($b)-or$expandedAdjByBase.ContainsKey($b)){throw "Duplicate/overlapping direct mapping adjudication: $b"};$directAdjByBase[$b]=$a}
 $directEvidencePath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Direct-CoinGecko-ID-Evidence.csv';if(-not(Test-Path -LiteralPath $directEvidencePath -PathType Leaf)){throw 'Direct CoinGecko ID evidence missing.'};$directEvidenceRows=@(Import-Csv -LiteralPath $directEvidencePath);if($directEvidenceRows.Count-le0){throw 'Direct CoinGecko ID evidence is empty.'};$directEvidenceKeys=@{};foreach($record in $directEvidenceRows){$b=[string]$record.base_asset_id;$id=[string]$record.requested_candidate_id;if([string]::IsNullOrWhiteSpace($b)-or[string]::IsNullOrWhiteSpace($id)){throw 'Direct CoinGecko evidence has empty base/id key.'};$key=$b+"`n"+$id;if($directEvidenceKeys.ContainsKey($key)){throw "Duplicate direct CoinGecko evidence key: $b/$id"};$directEvidenceKeys[$key]=$true}
 $out=@();foreach($row in $rows){$base=[string]$row.base_asset_id;$adj=if($adjByBase.ContainsKey($base)){$adjByBase[$base]}else{$null};$expandedAdj=if($expandedAdjByBase.ContainsKey($base)){$expandedAdjByBase[$base]}else{$null};$directAdj=if($directAdjByBase.ContainsKey($base)){$directAdjByBase[$base]}else{$null};$candidate=if($candidateByBase.ContainsKey($base)){$candidateByBase[$base]}else{$null};$d=Resolve-Decision $row $adj $candidate $expandedAdj $expandedEvidenceRows $directAdj $directEvidenceRows;$out+=[pscustomobject]@{base_asset_id=$base;base_exchange_symbol=[string]$row.base_exchange_symbol;candidate_ids=[string]$row.candidate_ids;mapping_status=$d.status;approved_coingecko_id=$d.id;decision_basis=$d.basis;evidence_note=$d.evidence}}
 foreach($b in @($adjByBase.Keys)+@($expandedAdjByBase.Keys)+@($directAdjByBase.Keys)){if(@($rows|Where-Object{[string]$_.base_asset_id-eq$b}).Count-ne1){throw "Adjudication base not found exactly once in bridge evidence: $b"}}
 $approved=@($out|Where-Object{$_.mapping_status-eq'APPROVED'});$unverified=@($out|Where-Object{$_.mapping_status-eq'UNVERIFIED'});$na=@($out|Where-Object{$_.mapping_status-eq'NOT_APPLICABLE'});if(($approved.Count+$unverified.Count+$na.Count)-ne435){throw 'Mapping decision accounting mismatch.'}
 $expectedNewApproved=@($adjs|Where-Object{$_.decision_status-eq'APPROVED'}).Count+$expandedAdjs.Count+$directAdjs.Count;$expectedNa=@($adjs|Where-Object{$_.decision_status-eq'NOT_APPLICABLE'}).Count;if($approved.Count-ne(324+$expectedNewApproved)-or$na.Count-ne$expectedNa){throw "Unexpected adjudication accounting: approved=$($approved.Count) na=$($na.Count) adjudicatedApproved=$expectedNewApproved registryNA=$expectedNa"}
 $csv=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv';$out|Sort-Object base_asset_id|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $registryHashes=@($adjPaths|ForEach-Object{(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()})
 $gate=if($unverified.Count-eq0){'PASS'}else{'UNVERIFIED'};$snapshot=[ordered]@{source_bridge_sha256=(Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant();adjudication_registry_sha256s=($registryHashes-join'|');expanded_adjudication_sha256=(Get-FileHash -LiteralPath $expandedAdjPath -Algorithm SHA256).Hash.ToLowerInvariant();expanded_candidate_evidence_sha256=(Get-FileHash -LiteralPath $expandedEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant();direct_adjudication_sha256=(Get-FileHash -LiteralPath $directAdjPath -Algorithm SHA256).Hash.ToLowerInvariant();direct_coingecko_evidence_sha256=(Get-FileHash -LiteralPath $directEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant();direct_adjudication_rows=$directAdjs.Count;direct_evidence_rows=$directEvidenceRows.Count;decision_rows=$out.Count;approved=$approved.Count;not_applicable=$na.Count;unverified=$unverified.Count;gate_status=$gate;blocking_reason=if($unverified.Count-eq0){''}else{([string]$unverified.Count+' assets still lack independently verified CoinGecko mapping identity.')}}
 $json=Join-Path $RepoRoot 'docs\evidence\stage2-mapping-decisions.json';Write-Utf8NoBom $json (($snapshot|ConvertTo-Json -Depth 6)+[Environment]::NewLine)
 $b=New-Object System.Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 2 Mapping Decisions');[void]$b.AppendLine('');[void]$b.AppendLine('- Decision rows: 435');[void]$b.AppendLine('- APPROVED: '+$approved.Count);[void]$b.AppendLine('- NOT_APPLICABLE: '+$na.Count);[void]$b.AppendLine('- UNVERIFIED: '+$unverified.Count);[void]$b.AppendLine('- CFA-S2-003: '+$gate);[void]$b.AppendLine('');[void]$b.AppendLine('322 approvals are backed by a unique current CoinGecko/Kraken pair bridge. EDGE and LIT are temporal adjudications. Contained adjudications are validated against AF-002 and may also explicitly preserve an UNVERIFIED conflict. Expanded adjudications are validated against separately published hashed CoinGecko reference evidence and never modify AF-002. Direct adjudications are validated against published direct `/coins/{id}` response evidence, with the direct evidence file hash recorded in the snapshot. Fiat bases are explicitly NOT_APPLICABLE. Unlisted cases remain UNVERIFIED.');[void]$b.AppendLine('');[void]$b.AppendLine('Decision table: candidate-analysis/CFA-Stage2-Mapping-Decisions.csv');[void]$b.AppendLine('Contained adjudication registries: candidate-analysis/CFA-Stage2-Mapping-Adjudications.csv, candidate-analysis/CFA-Stage2-Mapping-Adjudications-02.csv, candidate-analysis/CFA-Stage2-Mapping-Adjudications-03.csv');[void]$b.AppendLine('Expanded adjudication registry: candidate-analysis/CFA-Stage2-Mapping-Expanded-Adjudications.csv');[void]$b.AppendLine('Expanded candidate evidence: candidate-analysis/CFA-Stage2-Expanded-CoinGecko-Candidates.csv');[void]$b.AppendLine('Direct adjudication registry: candidate-analysis/CFA-Stage2-Mapping-Direct-Adjudications.csv');[void]$b.AppendLine('Direct CoinGecko evidence: candidate-analysis/CFA-Stage2-Direct-CoinGecko-ID-Evidence.csv');Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-mapping-decisions.md') $b.ToString()
 Write-Host 'CFA STAGE 2 MAPPING DECISIONS: COMPLETE';Write-Host ('APPROVED: '+$approved.Count);Write-Host ('NOT_APPLICABLE: '+$na.Count);Write-Host ('UNVERIFIED: '+$unverified.Count);Write-Host ('CFA-S2-003: '+$gate)
}catch{Write-Host 'CFA STAGE 2 MAPPING DECISIONS: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
