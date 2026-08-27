#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom {
 param([string]$Path,[string]$Content)
 $parent=Split-Path -Parent $Path
 if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
 [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}
function Key { param([string]$Base,[string]$Alias); return $Base+'|'+$Alias.Trim().ToLowerInvariant() }
function Test-Decisions {
 param([object[]]$Rows)
 if($Rows.Count-ne45){throw "Expected 45 alias semantic decisions; observed $($Rows.Count)."}
 $seen=@{}
 foreach($r in $Rows){
   $key=Key ([string]$r.base_asset_id) ([string]$r.alias_text)
   if($seen.ContainsKey($key)){throw "Duplicate alias semantic decision: $key"};$seen[$key]=$true
   if([string]$r.semantic_decision-ne'APPROVED_ALIAS_IDENTITY'){throw "Alias identity is not approved: $key"}
   if([string]::IsNullOrWhiteSpace([string]$r.alias_type)){throw "Alias type missing: $key"}
   $ctx=([string]$r.source_requires_crypto_context).Trim().ToLowerInvariant()
   if($ctx-notin@('true','false')){throw "Malformed context flag: $key"}
 }
 return $seen.Count
}
function Invoke-SelfTest {
 $rows=@();for($i=1;$i-le45;$i++){$rows+=[pscustomobject]@{base_asset_id='A'+$i;alias_text='Alias'+$i;alias_type='name';source_requires_crypto_context='False';semantic_decision='APPROVED_ALIAS_IDENTITY'}}
 if((Test-Decisions $rows)-ne45){throw 'decision self-test'}
 Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
 $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $csv=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Alias-Semantic-Decisions.csv'
 if(-not(Test-Path -LiteralPath $csv -PathType Leaf)){throw 'Alias semantic decision registry is missing.'}
 $rows=@(Import-Csv -LiteralPath $csv)
 $approved=Test-Decisions $rows
 $gate=if($approved-eq45){'PASS'}else{'UNVERIFIED'}
 $advance=if($gate-eq'PASS'){'PASS'}else{'BLOCKED'}
 $obj=[ordered]@{
   generated_at_utc=[DateTime]::UtcNow.ToString('o')
   decision_rows=$rows.Count
   approved_alias_identities=$approved
   unverified_alias_identities=$rows.Count-$approved
   active_news_identity_path='Kraken base asset -> approved AF-003 alias -> raw GDELT record'
   coingecko_status='NOT_APPLICABLE_TO_NEWS_MATCHING'
   gates=@(
     [ordered]@{gate_id='CFA-S2-005';status=$gate;reason='All 45 frozen AF-003 alias identities are approved.'},
     [ordered]@{gate_id='CFA-S2-006';status=$advance;reason='Stage 3 entry depends on Kraken coverage and alias readiness; CoinGecko is not an active dependency.'}
   )
 }
 Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-alias-semantic-decisions.json') (($obj|ConvertTo-Json -Depth 8)+[Environment]::NewLine)
 $b=New-Object System.Text.StringBuilder
 [void]$b.AppendLine('# CFA Stage 2 Alias Semantic Decisions')
 [void]$b.AppendLine('')
 [void]$b.AppendLine('- Decision rows: '+$rows.Count)
 [void]$b.AppendLine('- APPROVED_ALIAS_IDENTITY: '+$approved)
 [void]$b.AppendLine('- CFA-S2-005 Alias semantic validation: '+$gate)
 [void]$b.AppendLine('- CFA-S2-006 Advance to news matching definition: '+$advance)
 [void]$b.AppendLine('- CoinGecko: NOT_APPLICABLE to active news matching')
 [void]$b.AppendLine('')
 [void]$b.AppendLine('Scope: this registry validates which AF-003 aliases belong to which Kraken assets. The exact deterministic matching rule is frozen separately in `docs/evidence/stage3-simple-news-matching-contract.md`.')
 Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-alias-semantic-decisions.md') $b.ToString()
 Write-Host ('Alias semantic decisions: '+$rows.Count)
 Write-Host ('Approved alias identities: '+$approved)
 Write-Host ('CFA-S2-005: '+$gate)
 Write-Host ('CFA-S2-006: '+$advance)
 if($gate-ne'PASS'){exit 2}
 Write-Host 'CFA STAGE 2 ALIAS SEMANTIC RESOLUTION: PASS'
 exit 0
}catch{Write-Host 'CFA STAGE 2 ALIAS SEMANTIC RESOLUTION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
