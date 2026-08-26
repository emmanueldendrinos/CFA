#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null};$enc=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$enc)}
function Key{param([string]$Base,[string]$Alias);return $Base+'|'+$Alias.ToLowerInvariant()}

$Official=@{
 'ATOM|cosmos'=[pscustomobject]@{url='https://cosmos.network/';claim='Official Cosmos site identifies Cosmos Hub as the home of ATOM; Cosmos is an approved operational news alias for the ATOM asset.'}
 'AVAX|avalanche'=[pscustomobject]@{url='https://docs.avax.network/docs/primary-network/avax-token';claim='Official Avalanche documentation identifies AVAX as the native utility token of Avalanche.'}
 'DAI|dai'=[pscustomobject]@{url='https://makerdao.com/en/whitepaper/';claim='Official MakerDAO/Sky whitepaper identifies Dai as the protocol stablecoin.'}
 'OP|optimism'=[pscustomobject]@{url='https://specs.optimism.io/governance/gov-token.html';claim='Official OP Stack specification identifies token name Optimism and token symbol OP.'}
 'XXDG|doge'=[pscustomobject]@{url='https://foundation.dogecoin.com/announcements/2022-09-12-wdoge-bridge/';claim='Official Dogecoin Foundation material uses Doge as shorthand for Dogecoin; case-insensitive DOGE is approved as a contextual symbol alias.'}
 'XXLM|stellar'=[pscustomobject]@{url='https://resources.stellar.org/hubfs/Asset_Issuance_on_Stellar.pdf';claim='Official Stellar material identifies lumens (XLM) as the native currency of Stellar; Stellar is an approved operational news alias for XLM.'}
 'MKR|makerdao'=[pscustomobject]@{url='https://makerdao.com/en/';claim='Official MakerDAO material identifies MKR holders as governing the Maker Protocol and states MakerDAO is now Sky; MakerDAO is an approved operational news alias for MKR.'}
}

function Resolve-AliasSemantics{
 param([object[]]$Recovery,[object[]]$ContextSummary)
 $ctx=@{};foreach($r in $ContextSummary){$ctx[(Key ([string]$r.base_asset_id) ([string]$r.alias_text))]=$r}
 $out=@()
 foreach($r in $Recovery){
   $key=Key ([string]$r.base_asset_id) ([string]$r.alias_text)
   $sample=$null;if($ctx.ContainsKey($key)){$sample=$ctx[$key]}
   $strict=if($null-ne$sample){[int]$sample.strict_rule_rows}else{0}
   $observed=[long]$r.any_surface_document_count
   $decision='UNVERIFIED';$evidenceType='';$evidenceRef='';$note=''
   if($strict-gt0){
     $decision='APPROVED_ALIAS_IDENTITY';$evidenceType='GDELT_HIGH_CONFIDENCE_CRYPTO_CONTEXT_SAMPLE';$evidenceRef='docs/evidence/stage2-alias-context-sample-evidence.csv';$note="At least one bounded GDELT recovery sample satisfies the conservative diagnostic context rule; strict_rule_rows=$strict. This approves alias identity only, not the Stage 3 matching rule."
   }elseif($Official.ContainsKey($key)){
     $decision='APPROVED_ALIAS_IDENTITY';$evidenceType='OFFICIAL_PROJECT_CORROBORATION';$evidenceRef=[string]$Official[$key].url;$note=[string]$Official[$key].claim+' Collision/context handling remains a Stage 3 requirement.'
   }else{
     $note="No high-confidence GDELT context sample and no separately reviewed official corroboration. observed_documents=$observed."
   }
   $out += [pscustomobject]@{base_asset_id=[string]$r.base_asset_id;alias_text=[string]$r.alias_text;alias_type=[string]$r.alias_type;source_requires_crypto_context=[string]$r.requires_crypto_context;observed_documents=$observed;strict_context_sample_rows=$strict;semantic_decision=$decision;evidence_type=$evidenceType;evidence_reference=$evidenceRef;decision_note=$note}
 }
 return @($out|Sort-Object base_asset_id,alias_text)
}

function Write-Outputs{
 param([string]$Root,[object[]]$Rows)
 $approved=@($Rows|Where-Object{$_.semantic_decision-eq'APPROVED_ALIAS_IDENTITY'}).Count;$unverified=$Rows.Count-$approved;$gate=if($Rows.Count-eq45-and$unverified-eq0){'PASS'}else{'UNVERIFIED'}
 $csv=Join-Path $Root 'candidate-analysis\CFA-Stage2-Alias-Semantic-Decisions.csv';$Rows|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $obj=[ordered]@{generated_at_utc=[DateTime]::UtcNow.ToString('o');decision_rows=$Rows.Count;approved_alias_identities=$approved;unverified_alias_identities=$unverified;gates=@([ordered]@{gate_id='CFA-S2-005';status=$gate;reason='Alias identity relationship only. Collision and context matching logic is deferred to Stage 3 news matching.'},[ordered]@{gate_id='CFA-S2-006';status='BLOCKED';reason='CFA-S2-003 CoinGecko mapping decisions remain unresolved; Stage 3 may not begin until upstream identity/mapping gates are resolved.'})}
 $json=Join-Path $Root 'docs\evidence\stage2-alias-semantic-decisions.json';Write-Utf8NoBom $json ($obj|ConvertTo-Json -Depth 8)
 $b=New-Object System.Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 2 Alias Semantic Decisions');[void]$b.AppendLine('');[void]$b.AppendLine('- Decision rows: '+$Rows.Count);[void]$b.AppendLine('- APPROVED_ALIAS_IDENTITY: '+$approved);[void]$b.AppendLine('- UNVERIFIED: '+$unverified);[void]$b.AppendLine('- CFA-S2-005 Alias semantic validation: '+$gate);[void]$b.AppendLine('- CFA-S2-006 Advance to news matching definition: BLOCKED');[void]$b.AppendLine('');[void]$b.AppendLine('Scope: these decisions validate the relationship between each AF-003 seed and its asset. They do **not** approve exact-string matching, the diagnostic strict/broad context rules, or any news-factor formula. Collision handling is a Stage 3 design requirement.');[void]$b.AppendLine('');[void]$b.AppendLine('Evidence policy: 38 aliases have at least one bounded GDELT sample satisfying the conservative high-confidence context diagnostic. Six collision-heavy observed aliases and the unobserved MakerDAO seed are independently corroborated by official project sources reviewed on 2026-08-26.');[void]$b.AppendLine('');[void]$b.AppendLine('Decision table: `candidate-analysis/CFA-Stage2-Alias-Semantic-Decisions.csv`.')
 $md=Join-Path $Root 'docs\evidence\stage2-alias-semantic-decisions.md';Write-Utf8NoBom $md $b.ToString()
 return [pscustomobject]@{approved=$approved;unverified=$unverified;gate=$gate;csv=$csv;json=$json;md=$md}
}

function Invoke-SelfTest{
 $r=@();$c=@();for($i=1;$i-le45;$i++){$base='A'+$i;$alias='Alias'+$i;$r+=[pscustomobject]@{base_asset_id=$base;alias_text=$alias;alias_type='x';requires_crypto_context='False';any_surface_document_count=1};$c+=[pscustomobject]@{base_asset_id=$base;alias_text=$alias;strict_rule_rows=1}}
 $x=Resolve-AliasSemantics $r $c;if($x.Count-ne45-or@($x|Where-Object{$_.semantic_decision-ne'APPROVED_ALIAS_IDENTITY'}).Count-ne0){throw 'resolver self-test'};Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $recovery=@(Import-Csv -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage2-alias-recovery.csv'));$context=@(Import-Csv -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage2-alias-context-sample-summary.csv'))
 if($recovery.Count-ne45){throw "Expected 45 recovery aliases; observed $($recovery.Count)."};if($context.Count-ne44){throw "Expected 44 sampled aliases; observed $($context.Count)."}
 $rows=Resolve-AliasSemantics $recovery $context;$x=Write-Outputs $RepoRoot $rows;Write-Host ('Alias semantic decisions: '+$rows.Count);Write-Host ('Approved alias identities: '+$x.approved);Write-Host ('Unverified alias identities: '+$x.unverified);Write-Host ('CFA-S2-005: '+$x.gate);Write-Host 'CFA-S2-006: BLOCKED';if($x.gate-ne'PASS'){exit 2};Write-Host 'CFA STAGE 2 ALIAS SEMANTIC RESOLUTION: PASS'
}catch{Write-Host 'CFA STAGE 2 ALIAS SEMANTIC RESOLUTION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
