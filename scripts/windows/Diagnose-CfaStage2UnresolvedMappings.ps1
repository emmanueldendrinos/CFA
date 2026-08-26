#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Split-Pipe{param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text-split'\|'|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}
function Get-CandidateDetails{
 param([object]$CandidateRow)
 if($null-eq$CandidateRow-or[string]::IsNullOrWhiteSpace([string]$CandidateRow.candidate_records_json)){return [pscustomobject]@{ids=@();names=@();symbols=@();triples=@()}}
 try{$records=@(([string]$CandidateRow.candidate_records_json|ConvertFrom-Json))}catch{throw "Malformed AF-002 candidate JSON for $([string]$CandidateRow.base_asset_id): $($_.Exception.Message)"}
 $ids=@();$names=@();$symbols=@();$triples=@()
 foreach($r in $records){$id=[string]$r.id;$name=[string]$r.name;$symbol=[string]$r.symbol;$ids+=$id;$names+=$name;$symbols+=$symbol;$triples+=(($id+'~'+$name+'~'+$symbol))}
 return [pscustomobject]@{ids=@($ids);names=@($names);symbols=@($symbols);triples=@($triples)}
}

function Build-Diagnostic{
 param([object[]]$Decisions,[object[]]$PairRows,[object[]]$CandidateRows)
 $unresolved=@($Decisions|Where-Object{$_.mapping_status-eq'UNVERIFIED'})
 $pairsByBase=@{};foreach($p in $PairRows){$b=[string]$p.base_asset_id;if(-not$pairsByBase.ContainsKey($b)){$pairsByBase[$b]=@()};$pairsByBase[$b]+=$p}
 $candidatesByBase=@{};foreach($c in $CandidateRows){$b=[string]$c.base_asset_id;if($candidatesByBase.ContainsKey($b)){throw "Duplicate AF-002 base_asset_id: $b"};$candidatesByBase[$b]=$c}
 $rows=@()
 foreach($d in $unresolved){
   $base=[string]$d.base_asset_id;$pairs=@(if($pairsByBase.ContainsKey($base)){$pairsByBase[$base]}else{@()})
   $candidateIds=@(Split-Pipe ([string]$d.candidate_ids));$candidateCount=@($candidateIds).Count
   $candidateRow=if($candidatesByBase.ContainsKey($base)){$candidatesByBase[$base]}else{$null};if($null-eq$candidateRow){throw "AF-002 row missing for unresolved base: $base"}
   $details=Get-CandidateDetails $candidateRow
   $jsonIds=@($details.ids|Sort-Object);$decisionIds=@($candidateIds|Sort-Object);if(($jsonIds-join'|')-ne($decisionIds-join'|')){throw "AF-002/decision candidate ID mismatch for $base"}
   $exchangeSymbols=@($pairs|ForEach-Object{[string]$_.base_exchange_symbol}|Where-Object{$_}|Sort-Object -Unique)
   $wsBaseSymbols=@();foreach($p in $pairs){$ws=[string]$p.official_wsname;if($ws-match'^([^/]+)/'){$wsBaseSymbols+=$Matches[1]}};$wsBaseSymbols=@($wsBaseSymbols|Sort-Object -Unique)
   $quotes=@($pairs|ForEach-Object{[string]$_.quote_exchange_symbol}|Where-Object{$_}|Sort-Object -Unique)
   $pairKeys=@($pairs|ForEach-Object{[string]$_.official_pair_key}|Where-Object{$_}|Sort-Object -Unique)
   $obs=0L;foreach($p in $pairs){$obs+=[long]$p.typed_observation_count}
   $shape=if($candidateCount-eq0){'NO_CANDIDATE'}elseif($candidateCount-eq1){'SINGLE_CANDIDATE_NO_CURRENT_BRIDGE'}else{'MULTIPLE_CANDIDATES_NO_CURRENT_BRIDGE'}
   $symbolMismatch=(@($exchangeSymbols).Count-eq1-and@($wsBaseSymbols).Count-eq1-and$exchangeSymbols[0]-ne$wsBaseSymbols[0])
   $singleSymbolExact=($candidateCount-eq1-and@($exchangeSymbols).Count-eq1-and([string]$details.symbols[0]).Equals([string]$exchangeSymbols[0],[System.StringComparison]::OrdinalIgnoreCase))
   $rows+=[pscustomobject]@{base_asset_id=$base;base_exchange_symbols=($exchangeSymbols-join'|');ws_base_symbols=($wsBaseSymbols-join'|');candidate_count=$candidateCount;candidate_ids=($candidateIds-join'|');candidate_names=(@($details.names)-join'|');candidate_symbols=(@($details.symbols)-join'|');candidate_id_name_symbol=(@($details.triples)-join'|');single_candidate_symbol_exact=$singleSymbolExact;diagnostic_shape=$shape;exchange_vs_ws_symbol_mismatch=$symbolMismatch;eligible_pair_rows=@($pairs).Count;quote_symbols=($quotes-join'|');official_pair_key_count=@($pairKeys).Count;typed_observations=$obs;prior_basis=[string]$d.decision_basis;prior_evidence=[string]$d.evidence_note}
 }
 return @($rows|Sort-Object diagnostic_shape,base_asset_id)
}

function Write-Outputs{param([string]$Root,[object[]]$Rows)
 $csv=Join-Path $Root 'candidate-analysis\CFA-Stage2-Unresolved-Mapping-Diagnostic.csv';$Rows|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $no=@($Rows|Where-Object{$_.diagnostic_shape-eq'NO_CANDIDATE'}).Count;$single=@($Rows|Where-Object{$_.diagnostic_shape-eq'SINGLE_CANDIDATE_NO_CURRENT_BRIDGE'}).Count;$multi=@($Rows|Where-Object{$_.diagnostic_shape-eq'MULTIPLE_CANDIDATES_NO_CURRENT_BRIDGE'}).Count;$mismatch=@($Rows|Where-Object{$_.exchange_vs_ws_symbol_mismatch-eq$true}).Count;$singleExact=@($Rows|Where-Object{$_.diagnostic_shape-eq'SINGLE_CANDIDATE_NO_CURRENT_BRIDGE'-and$_.single_candidate_symbol_exact-eq$true}).Count
 $b=New-Object System.Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 2 Unresolved Mapping Diagnostic');[void]$b.AppendLine('');[void]$b.AppendLine('- Unresolved mappings: '+@($Rows).Count);[void]$b.AppendLine('- No CoinGecko candidate: '+$no);[void]$b.AppendLine('- Single candidate / no current Kraken bridge: '+$single);[void]$b.AppendLine('- Single candidate with exact AF-002 symbol match: '+$singleExact);[void]$b.AppendLine('- Multiple candidates / no current Kraken bridge: '+$multi);[void]$b.AppendLine('- Kraken exchange-symbol vs wsname-base mismatch: '+$mismatch);[void]$b.AppendLine('');[void]$b.AppendLine('Candidate name/symbol details are parsed directly from AF-002 candidate_records_json and reconciled back to the mapping-decision candidate ID set. This is classification evidence only. It does not approve a mapping or treat current absence as historical rejection.');[void]$b.AppendLine('');[void]$b.AppendLine('Diagnostic table: `candidate-analysis/CFA-Stage2-Unresolved-Mapping-Diagnostic.csv`.')
 $md=Join-Path $Root 'docs\evidence\stage2-unresolved-mapping-diagnostic.md';Write-Utf8NoBom $md $b.ToString();return [pscustomobject]@{no=$no;single=$single;singleExact=$singleExact;multi=$multi;mismatch=$mismatch;md=$md;csv=$csv}
}

function Invoke-SelfTest{
 $d=@([pscustomobject]@{base_asset_id='A';candidate_ids='x';mapping_status='UNVERIFIED';decision_basis='x';evidence_note='x'},[pscustomobject]@{base_asset_id='B';candidate_ids='';mapping_status='UNVERIFIED';decision_basis='x';evidence_note='x'})
 $p=@([pscustomobject]@{base_asset_id='A';base_exchange_symbol='AA';official_wsname='AA/USD';quote_exchange_symbol='USD';official_pair_key='AUSD';typed_observation_count=5})
 $c=@([pscustomobject]@{base_asset_id='A';candidate_records_json='[{"id":"x","symbol":"aa","name":"Asset A","platforms":{}}]'},[pscustomobject]@{base_asset_id='B';candidate_records_json='[]'})
 $r=@(Build-Diagnostic $d $p $c);if(@($r).Count-ne2-or@($r|Where-Object{$_.diagnostic_shape-eq'SINGLE_CANDIDATE_NO_CURRENT_BRIDGE'}).Count-ne1){throw 'diagnostic self-test'};$a=@($r|Where-Object{$_.base_asset_id-eq'A'})[0];if($a.candidate_names-ne'Asset A'-or$a.single_candidate_symbol_exact-ne$true){throw 'candidate detail self-test'};Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $dec=@(Import-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv'))
 $pairs=@(Import-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'))
 $candidates=@(Import-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv'))
 $rows=@(Build-Diagnostic $dec $pairs $candidates);if(@($rows).Count-ne111){throw "Expected 111 unresolved mappings; observed $(@($rows).Count)."};$x=Write-Outputs $RepoRoot $rows;Write-Host ('Unresolved mappings: '+@($rows).Count);Write-Host ('No candidate: '+$x.no);Write-Host ('Single candidate/no bridge: '+$x.single);Write-Host ('Single candidate/exact symbol: '+$x.singleExact);Write-Host ('Multiple candidates/no bridge: '+$x.multi);Write-Host ('Exchange/ws symbol mismatches: '+$x.mismatch);Write-Host 'CFA STAGE 2 UNRESOLVED MAPPING DIAGNOSTIC: PASS'
}catch{Write-Host 'CFA STAGE 2 UNRESOLVED MAPPING DIAGNOSTIC: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
