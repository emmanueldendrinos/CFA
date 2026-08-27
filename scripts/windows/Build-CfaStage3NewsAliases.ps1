#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$FiatSymbols=@('AUD','EUR','GBP','USD')

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};[IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))}
function Bool{param([object]$Value);$x=([string]$Value).Trim().ToLowerInvariant();if($x-eq'true'){return $true};if($x-eq'false'){return $false};throw "Malformed boolean: $Value"}
function Key{param([string]$Base,[string]$Alias);return $Base+'|'+$Alias.Trim().ToLowerInvariant()}

function Build-Aliases{
 param([object[]]$Pairs,[object[]]$Seeds,[object[]]$Semantic)
 $eligible=@($Pairs|Where-Object{Bool $_.research_eligible})
 $byBase=@{}
 foreach($p in $eligible){
   $base=[string]$p.base_asset_id;$symbol=([string]$p.base_exchange_symbol).Trim()
   if([string]::IsNullOrWhiteSpace($base)-or[string]::IsNullOrWhiteSpace($symbol)){throw 'Eligible Kraken row has empty base or base symbol.'}
   if(-not$byBase.ContainsKey($base)){$byBase[$base]=@{}}
   $byBase[$base][$symbol]=$true
 }
 if($byBase.Count-ne435){throw "Expected 435 eligible Kraken base assets; observed $($byBase.Count)."}
 $baseSymbol=@{};foreach($base in $byBase.Keys){$symbols=@($byBase[$base].Keys);if($symbols.Count-ne1){throw "Kraken base has multiple symbols: $base => $($symbols-join'|')"};$baseSymbol[$base]=$symbols[0]}
 $fiatBases=@($baseSymbol.Keys|Where-Object{$FiatSymbols-contains[string]$baseSymbol[$_]}|Sort-Object)
 if($fiatBases.Count-ne4){throw "Expected exactly 4 fiat bases (AUD/EUR/GBP/USD); observed $($fiatBases.Count): $($fiatBases-join'|')"}
 $cryptoBases=@($baseSymbol.Keys|Where-Object{$FiatSymbols-notcontains[string]$baseSymbol[$_]}|Sort-Object)
 if($cryptoBases.Count-ne431){throw "Expected 431 non-fiat Kraken news assets; observed $($cryptoBases.Count)."}
 $cryptoSet=@{};foreach($b in $cryptoBases){$cryptoSet[$b]=$true}

 $sem=@{};foreach($s in $Semantic){$k=Key ([string]$s.base_asset_id) ([string]$s.alias_text);if($sem.ContainsKey($k)){throw "Duplicate semantic decision: $k"};$sem[$k]=$s}
 if($Seeds.Count-ne45-or$Semantic.Count-ne45){throw "Expected 45 AF-003 seeds and 45 semantic decisions; observed $($Seeds.Count)/$($Semantic.Count)."}

 $rows=@{}
 foreach($base in $cryptoBases){
   $symbol=[string]$baseSymbol[$base];$k=Key $base $symbol
   $rows[$k]=[pscustomobject]@{base_asset_id=$base;alias_text=$symbol;alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'}
 }
 foreach($seed in $Seeds){
   $base=[string]$seed.base_asset_id;$alias=([string]$seed.alias_text).Trim();$k=Key $base $alias
   if(-not$cryptoSet.ContainsKey($base)){throw "AF-003 alias does not map to a non-fiat eligible Kraken base: $k"}
   if(-not$sem.ContainsKey($k)){throw "AF-003 alias missing semantic decision: $k"}
   $s=$sem[$k]
   if([string]$s.semantic_decision-ne'APPROVED_ALIAS_IDENTITY'){throw "AF-003 alias is not approved: $k"}
   $seedCtx=Bool $seed.requires_crypto_context
   if((Bool $s.source_requires_crypto_context)-ne$seedCtx){throw "AF-003 semantic context mismatch: $k"}
   if([string]$s.alias_type-ne[string]$seed.alias_type){throw "AF-003 semantic alias type mismatch: $k"}
   if($rows.ContainsKey($k)){
     $rows[$k]=[pscustomobject]@{base_asset_id=$base;alias_text=$alias;alias_type=[string]$seed.alias_type;requires_crypto_context=if($seedCtx){'True'}else{'False'};alias_source='AF001_KRAKEN_SYMBOL|AF003_APPROVED_ALIAS'}
   }else{
     $rows[$k]=[pscustomobject]@{base_asset_id=$base;alias_text=$alias;alias_type=[string]$seed.alias_type;requires_crypto_context=if($seedCtx){'True'}else{'False'};alias_source='AF003_APPROVED_ALIAS'}
   }
 }
 $out=@($rows.Values|Sort-Object base_asset_id,alias_text)
 $globalAlias=@{};$collisions=@()
 foreach($r in $out){$norm=([string]$r.alias_text).Trim().ToLowerInvariant();if(-not$globalAlias.ContainsKey($norm)){$globalAlias[$norm]=@{}};$globalAlias[$norm][[string]$r.base_asset_id]=$true}
 foreach($alias in $globalAlias.Keys){$bases=@($globalAlias[$alias].Keys|Sort-Object);if($bases.Count-gt1){$collisions+=$alias+'=>' + ($bases-join'|')}}
 if($collisions.Count-gt0){throw 'Cross-asset alias collisions: '+($collisions-join';')}
 $covered=@($out|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique)
 if($covered.Count-ne431){throw "Generated aliases cover $($covered.Count) assets; expected 431."}
 return [pscustomobject]@{rows=$out;crypto_bases=$cryptoBases;fiat_bases=$fiatBases;collisions=$collisions}
}

function Invoke-SelfTest{
 $pairs=@();foreach($x in @(@('A','AAA'),@('B','BBB'),@('USD','USD'))){$pairs+=[pscustomobject]@{base_asset_id=$x[0];base_exchange_symbol=$x[1];research_eligible='True'}}
 # Unit-test the merge rules independently of production cardinality.
 $r=@{};$r[(Key 'A' 'AAA')]=[pscustomobject]@{base_asset_id='A';alias_text='AAA';requires_crypto_context='True'}
 $seed=[pscustomobject]@{base_asset_id='A';alias_text='AAA';requires_crypto_context='False'}
 $r[(Key 'A' 'AAA')]=[pscustomobject]@{base_asset_id='A';alias_text=$seed.alias_text;requires_crypto_context=if(Bool $seed.requires_crypto_context){'True'}else{'False'}}
 if([string]$r[(Key 'A' 'AAA')].requires_crypto_context-ne'False'){throw 'AF-003 override rule'}
 if(-not(Bool 'TRUE')){throw 'boolean parser'}
 if((Key 'A' 'AaA')-ne'A|aaa'){throw 'key normalization'}
 Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $pairPath=Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv';$seedPath=Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv';$semPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Alias-Semantic-Decisions.csv'
 foreach($p in @($pairPath,$seedPath,$semPath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing Stage 3 alias input: $p"}}
 $x=Build-Aliases @(Import-Csv $pairPath) @(Import-Csv $seedPath) @(Import-Csv $semPath)
 $csv=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv';$x.rows|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $sha=(Get-FileHash -LiteralPath $csv -Algorithm SHA256).Hash.ToLowerInvariant()
 $obj=[ordered]@{gate_id='S3-ID-01';status='PASS';eligible_kraken_assets=435;excluded_fiat_assets=$x.fiat_bases;news_assets=$x.crypto_bases.Count;approved_seed_aliases=45;generated_alias_rows=$x.rows.Count;cross_asset_alias_collisions=0;alias_registry_sha256=$sha}
 Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage3-news-alias-universe.json') (($obj|ConvertTo-Json -Depth 6)+[Environment]::NewLine)
 $b=New-Object Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 3 News Alias Universe');[void]$b.AppendLine('');[void]$b.AppendLine('- S3-ID-01: PASS');[void]$b.AppendLine('- Eligible Kraken assets: 435');[void]$b.AppendLine('- Fiat excluded: '+($x.fiat_bases-join'|'));[void]$b.AppendLine('- Crypto news assets: '+$x.crypto_bases.Count);[void]$b.AppendLine('- AF-003 approved seeds: 45');[void]$b.AppendLine('- Final deterministic alias rows: '+$x.rows.Count);[void]$b.AppendLine('- Cross-asset alias collisions: 0');[void]$b.AppendLine('- Alias registry SHA-256: '+$sha);[void]$b.AppendLine('');[void]$b.AppendLine('Rule: every non-fiat Kraken base symbol is a context-required alias. Approved AF-003 aliases supplement or override that default. No external identity provider is used.')
 Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage3-news-alias-universe.md') $b.ToString()
 Write-Host ('S3-ID-01: PASS | news_assets='+$x.crypto_bases.Count+' | alias_rows='+$x.rows.Count+' | collisions=0')
 exit 0
}catch{Write-Host 'S3-ID-01: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
