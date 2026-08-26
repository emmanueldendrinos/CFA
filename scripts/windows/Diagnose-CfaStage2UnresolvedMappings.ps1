#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Split-Pipe{param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text-split'\|'|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})}

function Build-Diagnostic{
 param([object[]]$Decisions,[object[]]$PairRows)
 $unresolved=@($Decisions|Where-Object{$_.mapping_status-eq'UNVERIFIED'})
 $pairsByBase=@{};foreach($p in $PairRows){$b=[string]$p.base_asset_id;if(-not$pairsByBase.ContainsKey($b)){$pairsByBase[$b]=@()};$pairsByBase[$b]+=$p}
 $rows=@()
 foreach($d in $unresolved){
   $base=[string]$d.base_asset_id;$pairs=@(if($pairsByBase.ContainsKey($base)){$pairsByBase[$base]}else{@()})
   $candidateIds=@(Split-Pipe ([string]$d.candidate_ids));$candidateCount=@($candidateIds).Count
   $exchangeSymbols=@($pairs|ForEach-Object{[string]$_.base_exchange_symbol}|Where-Object{$_}|Sort-Object -Unique)
   $wsBaseSymbols=@();foreach($p in $pairs){$ws=[string]$p.official_wsname;if($ws-match'^([^/]+)/'){$wsBaseSymbols+=$Matches[1]}};$wsBaseSymbols=@($wsBaseSymbols|Sort-Object -Unique)
   $quotes=@($pairs|ForEach-Object{[string]$_.quote_exchange_symbol}|Where-Object{$_}|Sort-Object -Unique)
   $pairKeys=@($pairs|ForEach-Object{[string]$_.official_pair_key}|Where-Object{$_}|Sort-Object -Unique)
   $obs=0L;foreach($p in $pairs){$obs+=[long]$p.typed_observation_count}
   $shape=if($candidateCount-eq0){'NO_CANDIDATE'}elseif($candidateCount-eq1){'SINGLE_CANDIDATE_NO_CURRENT_BRIDGE'}else{'MULTIPLE_CANDIDATES_NO_CURRENT_BRIDGE'}
   $symbolMismatch=(@($exchangeSymbols).Count-eq1-and@($wsBaseSymbols).Count-eq1-and$exchangeSymbols[0]-ne$wsBaseSymbols[0])
   $rows+=[pscustomobject]@{base_asset_id=$base;base_exchange_symbols=($exchangeSymbols-join'|');ws_base_symbols=($wsBaseSymbols-join'|');candidate_count=$candidateCount;candidate_ids=($candidateIds-join'|');diagnostic_shape=$shape;exchange_vs_ws_symbol_mismatch=$symbolMismatch;eligible_pair_rows=@($pairs).Count;quote_symbols=($quotes-join'|');official_pair_key_count=@($pairKeys).Count;typed_observations=$obs;prior_basis=[string]$d.decision_basis;prior_evidence=[string]$d.evidence_note}
 }
 return @($rows|Sort-Object diagnostic_shape,base_asset_id)
}

function Write-Outputs{param([string]$Root,[object[]]$Rows)
 $csv=Join-Path $Root 'candidate-analysis\CFA-Stage2-Unresolved-Mapping-Diagnostic.csv';$Rows|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $no=@($Rows|Where-Object{$_.diagnostic_shape-eq'NO_CANDIDATE'}).Count;$single=@($Rows|Where-Object{$_.diagnostic_shape-eq'SINGLE_CANDIDATE_NO_CURRENT_BRIDGE'}).Count;$multi=@($Rows|Where-Object{$_.diagnostic_shape-eq'MULTIPLE_CANDIDATES_NO_CURRENT_BRIDGE'}).Count;$mismatch=@($Rows|Where-Object{$_.exchange_vs_ws_symbol_mismatch-eq$true}).Count
 $b=New-Object System.Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 2 Unresolved Mapping Diagnostic');[void]$b.AppendLine('');[void]$b.AppendLine('- Unresolved mappings: '+@($Rows).Count);[void]$b.AppendLine('- No CoinGecko candidate: '+$no);[void]$b.AppendLine('- Single candidate / no current Kraken bridge: '+$single);[void]$b.AppendLine('- Multiple candidates / no current Kraken bridge: '+$multi);[void]$b.AppendLine('- Kraken exchange-symbol vs wsname-base mismatch: '+$mismatch);[void]$b.AppendLine('');[void]$b.AppendLine('This is classification evidence only. It does not approve a mapping or treat current absence as historical rejection.');[void]$b.AppendLine('');[void]$b.AppendLine('Diagnostic table: `candidate-analysis/CFA-Stage2-Unresolved-Mapping-Diagnostic.csv`.')
 $md=Join-Path $Root 'docs\evidence\stage2-unresolved-mapping-diagnostic.md';Write-Utf8NoBom $md $b.ToString();return [pscustomobject]@{no=$no;single=$single;multi=$multi;mismatch=$mismatch;md=$md;csv=$csv}
}

function Invoke-SelfTest{$d=@([pscustomobject]@{base_asset_id='A';candidate_ids='x';mapping_status='UNVERIFIED';decision_basis='x';evidence_note='x'},[pscustomobject]@{base_asset_id='B';candidate_ids='';mapping_status='UNVERIFIED';decision_basis='x';evidence_note='x'});$p=@([pscustomobject]@{base_asset_id='A';base_exchange_symbol='AA';official_wsname='AA/USD';quote_exchange_symbol='USD';official_pair_key='AUSD';typed_observation_count=5});$r=@(Build-Diagnostic $d $p);if(@($r).Count-ne2-or@($r|Where-Object{$_.diagnostic_shape-eq'SINGLE_CANDIDATE_NO_CURRENT_BRIDGE'}).Count-ne1){throw 'diagnostic self-test'};Write-Host 'SELF-TEST: PASS'}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$dec=@(Import-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv'));$pairs=@(Import-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'));$rows=@(Build-Diagnostic $dec $pairs);if(@($rows).Count-ne111){throw "Expected 111 unresolved mappings; observed $(@($rows).Count)."};$x=Write-Outputs $RepoRoot $rows;Write-Host ('Unresolved mappings: '+@($rows).Count);Write-Host ('No candidate: '+$x.no);Write-Host ('Single candidate/no bridge: '+$x.single);Write-Host ('Multiple candidates/no bridge: '+$x.multi);Write-Host ('Exchange/ws symbol mismatches: '+$x.mismatch);Write-Host 'CFA STAGE 2 UNRESOLVED MAPPING DIAGNOSTIC: PASS'}catch{Write-Host 'CFA STAGE 2 UNRESOLVED MAPPING DIAGNOSTIC: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
