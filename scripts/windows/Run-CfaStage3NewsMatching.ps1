#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [string]$ArchiveRoot='',
    [string]$OutputRoot='',
    [ValidateRange(1,50)][int]$MaxSamplesPerAlias=10,
    [switch]$ValidateInputsOnly,
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedFieldCount=27
$ExpectedArchives=7163
$ExpectedRows=9183757L
$ExpectedMalformedRows=5L
$RecordIdIndex=0;$DateIndex=1;$SourceIndex=3;$DocumentIndex=4;$ThemesIndex=8;$PersonsIndex=12;$OrganizationsIndex=14;$AllNamesIndex=23;$ExtrasIndex=26
$CryptoTitleRegex=New-Object System.Text.RegularExpressions.Regex('(?<![\p{L}\p{N}])(?:crypto|cryptocurrency|cryptocurrencies|blockchain|token|tokens|coin|coins|web3|defi|nft|nfts|staking|wallet|wallets|digital\s+asset|digital\s+assets)(?![\p{L}\p{N}])',([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))
$MarketTitleRegex=New-Object System.Text.RegularExpressions.Regex('(?<![\p{L}\p{N}])(?:price|prices|trading|trades|market|markets|rally|rallies|surge|surges|soar|soars|jump|jumps|gain|gains|drop|drops|dip|dips|fall|falls|slide|slides|bull|bullish|bear|bearish|support|resistance|volume|volumes|futures|etf|etfs|exchange|exchanges|mining|staking|treasury|holder|holders|investor|investors|mainnet|airdrop|airdrops)(?![\p{L}\p{N}])',([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))
$AllowedPolicies=@('DIRECT_NAME','CONTEXT_NAME','TITLE_CRYPTO_NAME','STRICT_SYMBOL_TITLE')

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};[IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))}
function Bool{param([object]$Value);$x=([string]$Value).Trim().ToLowerInvariant();if($x-eq'true'){return $true};if($x-eq'false'){return $false};throw "Malformed boolean: $Value"}
function AliasKey{param([string]$Base,[string]$Alias);return $Base+'|'+$Alias.Trim().ToLowerInvariant()}
function Csv{param([object]$Value);$s=if($null-eq$Value){''}else{[string]$Value};if($s.Contains('"')){$s=$s.Replace('"','""')};if($s.Contains(',')-or$s.Contains('"')-or$s.Contains("`r")-or$s.Contains("`n")){return '"'+$s+'"'};return $s}
function Write-CsvRow{param([IO.StreamWriter]$Writer,[object[]]$Values);$Writer.WriteLine((@($Values|ForEach-Object{Csv $_})-join','))}

function Parse-OffsetNames{
 param([string]$Text)
 $items=@();$malformed=0
 if([string]::IsNullOrWhiteSpace($Text)){return [pscustomobject]@{items=$items;malformed=0}}
 foreach($block in @($Text-split';')){
   if([string]::IsNullOrWhiteSpace($block)){continue};$comma=$block.LastIndexOf(',')
   if($comma-le0-or$comma-ge($block.Length-1)){$malformed++;continue}
   $name=$block.Substring(0,$comma).Trim();$offsetText=$block.Substring($comma+1).Trim();$offset=0
   if([string]::IsNullOrWhiteSpace($name)-or-not[int]::TryParse($offsetText,[ref]$offset)){$malformed++;continue}
   $items+=[pscustomobject]@{name=$name;offset=$offset}
 }
 return [pscustomobject]@{items=$items;malformed=$malformed}
}
function Get-PageTitle{param([string]$Extras);if([string]::IsNullOrWhiteSpace($Extras)){return ''};$m=[regex]::Match($Extras,'<PAGE_TITLE>(.*?)</PAGE_TITLE>',[Text.RegularExpressions.RegexOptions]::IgnoreCase);if(-not$m.Success){return ''};return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)}
function Test-EconBitcoin{param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return $false};foreach($block in @($Text-split';')){if([string]::IsNullOrWhiteSpace($block)){continue};$comma=$block.LastIndexOf(',');$name=if($comma-gt0){$block.Substring(0,$comma).Trim()}else{$block.Trim()};if($name.Equals('ECON_BITCOIN',[StringComparison]::OrdinalIgnoreCase)){return $true}};return $false}
function Add-Hit{param([hashtable]$Hits,[string]$Key,[string]$Surface);if(-not$Hits.ContainsKey($Key)){$Hits[$Key]=@{}};$Hits[$Key][$Surface]=$true}

function Get-MatchPolicy{
 param([object]$AliasRow,[hashtable]$Overrides)
 $base=[string]$AliasRow.base_asset_id;$alias=([string]$AliasRow.alias_text).Trim();$key=AliasKey $base $alias;$type=[string]$AliasRow.alias_type
 if($type-eq'kraken_base_symbol'-or$type-eq'manual_core_symbol'){return 'STRICT_SYMBOL_TITLE'}
 if($Overrides.ContainsKey($key)){return [string]$Overrides[$key].match_policy}
 if(Bool $AliasRow.requires_crypto_context){return 'CONTEXT_NAME'}
 return 'DIRECT_NAME'
}

function Test-StrictSymbolEvidence{
 param([string]$Alias,[string]$Title)
 if([string]::IsNullOrWhiteSpace($Alias)-or[string]::IsNullOrWhiteSpace($Title)){return $false}
 $esc=[regex]::Escape($Alias)
 $symbol='(?<![\p{L}\p{N}])'+$esc+'(?![\p{L}\p{N}])'
 $assetMarker='(?i:(?<![\p{L}\p{N}])(?:token|tokens|coin|coins|price|prices|trading|volume|volumes|rally|rallies|surge|surges|soar|soars|jump|jumps|gain|gains|drop|drops|dip|dips|fall|falls|slide|slides|bull|bullish|bear|bearish|support|resistance|futures|etf|etfs|staking|airdrop|airdrops|mainnet|holder|holders|investor|investors)(?![\p{L}\p{N}]))'
 $cashtag='\$'+$esc+'(?![\p{L}\p{N}])'
 $local='(?:'+$cashtag+'|'+$symbol+'.{0,16}?'+$assetMarker+'|'+$assetMarker+'.{0,16}?'+$symbol+')'
 return [regex]::IsMatch($Title,$local,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Test-ContextNameEvidence{
 param([string]$Alias,[string]$Title)
 if([string]::IsNullOrWhiteSpace($Alias)-or[string]::IsNullOrWhiteSpace($Title)){return $false}
 $esc=[regex]::Escape($Alias)
 $name='(?<![\p{L}\p{N}])'+$esc+'(?![\p{L}\p{N}])'
 $ctx='(?i:(?<![\p{L}\p{N}])(?:token|tokens|coin|coins|stablecoin|stablecoins|price|prices|network|blockchain|protocol|chain|ecosystem|layer|mainnet|staking|trading|volume|futures|etf|exchange|foundation|labs|dao|hub|wallet|treasury|holder|holders|investor|investors|ceo)(?![\p{L}\p{N}]))'
 $pattern='(?:'+$name+'.{0,24}?'+$ctx+'|'+$ctx+'.{0,24}?'+$name+')'
 return [regex]::IsMatch($Title,$pattern,([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))
}

function Accepted{
 param([string]$Policy,[bool]$RequiresContext,[bool]$Econ,[bool]$TitleCrypto,[bool]$ContextNameEvidence,[bool]$StrictSymbolEvidence)
 switch($Policy){
   'DIRECT_NAME'{if($RequiresContext){throw 'DIRECT_NAME cannot require crypto context.'};return $true}
   'CONTEXT_NAME'{if(-not$RequiresContext){throw 'CONTEXT_NAME must require crypto context.'};return $ContextNameEvidence}
   'TITLE_CRYPTO_NAME'{if($RequiresContext){throw 'TITLE_CRYPTO_NAME must not carry the source context-required flag.'};return $TitleCrypto}
   'STRICT_SYMBOL_TITLE'{if(-not$RequiresContext){throw 'STRICT_SYMBOL_TITLE must require crypto context.'};return $StrictSymbolEvidence}
   default{throw "Unknown Stage 3 match policy: $Policy"}
 }
}

function Get-AliasTools{
 param([object[]]$Rows,[object[]]$OverrideRows)
 $overrides=@{}
 foreach($o in $OverrideRows){
   $base=[string]$o.base_asset_id;$alias=([string]$o.alias_text).Trim();$policy=[string]$o.match_policy;$key=AliasKey $base $alias
   if([string]::IsNullOrWhiteSpace($base)-or[string]::IsNullOrWhiteSpace($alias)){throw 'Stage 3 match override has empty base or alias.'}
   if([string]::IsNullOrWhiteSpace([string]$o.evidence_run_id)-or[string]::IsNullOrWhiteSpace([string]$o.evidence_record_id)-or[string]::IsNullOrWhiteSpace([string]$o.reason)){throw "Stage 3 match override is missing evidence lineage: $key"}
   if([string]$o.evidence_record_id-notmatch'^\d{14}-\d+$'){throw "Stage 3 match override has malformed evidence_record_id: $key => $($o.evidence_record_id)"}
   if($overrides.ContainsKey($key)){throw "Duplicate Stage 3 match override: $key"}
   if($AllowedPolicies-notcontains$policy){throw "Invalid Stage 3 match override policy: $policy for $key"}
   $overrides[$key]=$o
 }
 $byKey=@{};$nameLookup=@{};$symbolLookup=@{};$global=@{};$assets=@{};$nameAliases=@();$symbolAliases=@()
 foreach($r in $Rows){
   $base=[string]$r.base_asset_id;$alias=([string]$r.alias_text).Trim();$key=AliasKey $base $alias
   if([string]::IsNullOrWhiteSpace($base)-or[string]::IsNullOrWhiteSpace($alias)){throw 'Stage 3 alias has empty base or alias.'}
   if($byKey.ContainsKey($key)){throw "Duplicate Stage 3 alias key: $key"}
   $ctx=Bool $r.requires_crypto_context;$policy=Get-MatchPolicy $r $overrides
   if($AllowedPolicies-notcontains$policy){throw "Invalid Stage 3 match policy: $policy for $key"}
   $byKey[$key]=[pscustomobject]@{base_asset_id=$base;alias_text=$alias;alias_type=[string]$r.alias_type;requires_crypto_context=$ctx;alias_source=[string]$r.alias_source;match_policy=$policy}
   if($policy-eq'STRICT_SYMBOL_TITLE'){
     if(-not$symbolLookup.ContainsKey($alias)){$symbolLookup[$alias]=@()};$symbolLookup[$alias]+=$key;$symbolAliases+=$alias
   }else{
     $norm=$alias.ToLowerInvariant();if(-not$nameLookup.ContainsKey($norm)){$nameLookup[$norm]=@()};$nameLookup[$norm]+=$key;$nameAliases+=$alias
   }
   $normGlobal=$alias.ToLowerInvariant();if(-not$global.ContainsKey($normGlobal)){$global[$normGlobal]=@{}};$global[$normGlobal][$base]=$true;$assets[$base]=$true
 }
 if($assets.Count-ne431){throw "Stage 3 alias registry covers $($assets.Count) assets; expected 431."}
 foreach($key in $overrides.Keys){if(-not$byKey.ContainsKey($key)){throw "Stage 3 match override does not reference an active alias: $key"};if([string]$byKey[$key].match_policy-ne[string]$overrides[$key].match_policy){throw "Stage 3 match override not applied: $key"}}
 $collisions=@();foreach($norm in $global.Keys){$bases=@($global[$norm].Keys);if($bases.Count-gt1){$collisions+=$norm+'=>' + (($bases|Sort-Object)-join'|')}}
 if($collisions.Count-gt0){throw 'Cross-asset Stage 3 alias collisions: '+($collisions-join';')}
 $nameParts=@($nameAliases|Sort-Object -Unique|Sort-Object Length -Descending|ForEach-Object{[regex]::Escape($_)})
 $symbolParts=@($symbolAliases|Sort-Object -Unique|Sort-Object Length -Descending|ForEach-Object{[regex]::Escape($_)})
 $nameRegex=if($nameParts.Count-gt0){New-Object Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:'+($nameParts-join'|')+')(?![\p{L}\p{N}])'),([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))}else{$null}
 $symbolRegex=if($symbolParts.Count-gt0){New-Object Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:'+($symbolParts-join'|')+')(?![\p{L}\p{N}])'),[Text.RegularExpressions.RegexOptions]::CultureInvariant)}else{$null}
 return [pscustomobject]@{byKey=$byKey;nameLookup=$nameLookup;symbolLookup=$symbolLookup;nameRegex=$nameRegex;symbolRegex=$symbolRegex;assetCount=$assets.Count;aliasCount=$Rows.Count;overrideCount=$overrides.Count}
}

function Invoke-SelfTest{
 if($ExpectedArchives-ne7163-or$ExpectedRows-ne9183757L-or$ExpectedMalformedRows-ne5L){throw 'source accounting constants'}
 $p=Parse-OffsetNames 'Bitcoin,10;Broken;Ethereum,25';if($p.items.Count-ne2-or$p.malformed-ne1){throw 'offset parser'}
 if(-not(Test-EconBitcoin 'ECON_BITCOIN,5;OTHER,1')){throw 'theme match'};if(Test-EconBitcoin 'ECON_BITCOINISH,5'){throw 'theme false positive'}
 $title=Get-PageTitle 'x<PAGE_TITLE>Bitcoin Cash &amp; crypto rally</PAGE_TITLE>y';if($title-ne'Bitcoin Cash & crypto rally'){throw 'title parser'};if(-not$CryptoTitleRegex.IsMatch($title)){throw 'crypto title anchor'};if(-not$MarketTitleRegex.IsMatch($title)){throw 'market title anchor'}
 if(-not(Accepted 'DIRECT_NAME' $false $false $false $false $false)){throw 'direct-name acceptance'}
 if(Accepted 'CONTEXT_NAME' $true $true $true $false $false){throw 'context-name must not accept global context alone'};if(-not(Test-ContextNameEvidence 'Optimism' 'Optimism network token price rises')){throw 'context-name local evidence'};if(Test-ContextNameEvidence 'Optimism' 'Crypto optimism continues as markets rally'){throw 'generic optimism false positive'};if(-not(Accepted 'CONTEXT_NAME' $true $false $false $true $false)){throw 'context-name local acceptance'}
 if(Accepted 'TITLE_CRYPTO_NAME' $false $true $false $false $false){throw 'title-only name must not accept ECON_BITCOIN alone'};if(-not(Accepted 'TITLE_CRYPTO_NAME' $false $false $true $false $false)){throw 'title-only name crypto acceptance'}
 if(Test-StrictSymbolEvidence 'S' "Trump's crypto sherpa"){throw 'possessive S false positive'}
 if(Test-StrictSymbolEvidence 'S' 'U.S. crypto policy'){throw 'U.S. S false positive'}
 if(-not(Test-StrictSymbolEvidence 'S' '$S token price jumps')){throw 'single-letter explicit symbol evidence'}
 if(Test-StrictSymbolEvidence 'DOGE' 'DOGE aide involved in consumer bureau cuts'){throw 'DOGE government false positive'}
 if(-not(Test-StrictSymbolEvidence 'DOGE' 'DOGE price jumps as crypto market rallies')){throw 'DOGE market evidence'}
 if(Test-StrictSymbolEvidence 'ATH' 'Bitcoin ATH fails hype; retail demand is down'){throw 'ATH acronym false positive'}
 if(-not(Test-StrictSymbolEvidence 'BTC' 'BTC price hits 100000')){throw 'BTC price evidence'}
 if((Csv 'a,b')-ne'"a,b"'){throw 'CSV escape'}
 Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $builder=Join-Path $PSScriptRoot 'Build-CfaStage3NewsAliases.ps1';if(-not(Test-Path -LiteralPath $builder -PathType Leaf)){throw 'Stage 3 alias builder is missing.'}
 $global:LASTEXITCODE=$null;& $builder -RepoRoot $RepoRoot;$buildCode=if($null-eq$LASTEXITCODE){0}else{[int]$LASTEXITCODE};if($buildCode-ne0){throw "S3-ID-01 alias build failed with exit $buildCode."};$global:LASTEXITCODE=0
 $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv';$overridePath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-Alias-Match-Overrides.csv'
 foreach($p in @($aliasPath,$overridePath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Stage 3 matcher input missing: $p"}}
 $aliases=@(Import-Csv -LiteralPath $aliasPath);$overrides=@(Import-Csv -LiteralPath $overridePath);$tools=Get-AliasTools $aliases $overrides
 Write-Host ('Stage 3 alias input: assets='+$tools.assetCount+' aliases='+$tools.aliasCount+' overrides='+$tools.overrideCount)
 if($ValidateInputsOnly){Write-Host 'CFA STAGE 3 MATCHER INPUT VALIDATION: PASS';exit 0}

 $documents=[Environment]::GetFolderPath('MyDocuments');if([string]::IsNullOrWhiteSpace($ArchiveRoot)){$ArchiveRoot=Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025'};if(-not(Test-Path -LiteralPath $ArchiveRoot -PathType Container)){throw "GDELT archive root missing: $ArchiveRoot"};$ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
 if([string]::IsNullOrWhiteSpace($OutputRoot)){$parent=Join-Path $documents 'CFA-local\stage3-news-matching';if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null};$OutputRoot=Join-Path $parent ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))}
 if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null};$OutputRoot=(Resolve-Path -LiteralPath $OutputRoot).ProviderPath
 $files=@(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip'|Where-Object{$_.Name-match'^\d{14}\.gkg\.csv\.zip$'}|Sort-Object Name);if($files.Count-ne$ExpectedArchives){throw "Expected $ExpectedArchives GKG archives; observed $($files.Count)."}

 $matchPath=Join-Path $OutputRoot 'stage3-news-matches.csv';$rejectPath=Join-Path $OutputRoot 'stage3-context-rejects.csv';$samplePath=Join-Path $OutputRoot 'stage3-match-samples.csv';$utf8=New-Object Text.UTF8Encoding($false)
 $matchWriter=New-Object IO.StreamWriter -ArgumentList $matchPath,$false,$utf8;$rejectWriter=New-Object IO.StreamWriter -ArgumentList $rejectPath,$false,$utf8;$sampleWriter=New-Object IO.StreamWriter -ArgumentList $samplePath,$false,$utf8
 Write-CsvRow $matchWriter @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons')
 Write-CsvRow $rejectWriter @('base_asset_id','alias_text','match_policy','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_surfaces','context_reason')
 Write-CsvRow $sampleWriter @('match_status','base_asset_id','alias_text','match_policy','requires_crypto_context','record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','matched_surfaces','econ_bitcoin_theme','title_crypto_anchor','title_market_anchor','context_name_evidence','strict_symbol_evidence','context_reason')

 $sampleCount=@{};$seen=New-Object 'Collections.Generic.HashSet[string]';$matchedAssets=New-Object 'Collections.Generic.HashSet[string]';$lenient=New-Object Text.UTF8Encoding($false,$false)
 [long]$total=0;[long]$malformedRows=0;[long]$missingCritical=0;[long]$malformedBlocks=0;[long]$aliasCandidates=0;[long]$acceptedHits=0;[long]$rejectedHits=0;[long]$matchRows=0;[long]$duplicateMatches=0;$archiveOrdinal=0
 try{
  foreach($file in $files){
   $archiveOrdinal++;if($archiveOrdinal-eq1-or($archiveOrdinal%250)-eq0){Write-Host ("Stage 3 GKG scan archives: {0}/{1}"-f$archiveOrdinal,$files.Count)}
   $zip=$null;try{
    $zip=[IO.Compression.ZipFile]::OpenRead($file.FullName);$entries=@($zip.Entries|Where-Object{-not[string]::IsNullOrWhiteSpace($_.Name)});if($entries.Count-ne1){throw "Expected one data entry in $($file.Name); observed $($entries.Count)."}
    $stream=$entries[0].Open();$reader=New-Object IO.StreamReader -ArgumentList $stream,$lenient,$false,65536,$false
    try{
     [long]$rowOrdinal=0
     while(($line=$reader.ReadLine())-ne$null){
      $rowOrdinal++;$total++;$fields=$line.Split([char]9);if($fields.Count-ne$ExpectedFieldCount){$malformedRows++;continue}
      $recordId=[string]$fields[$RecordIdIndex];$date=[string]$fields[$DateIndex];$doc=[string]$fields[$DocumentIndex];if([string]::IsNullOrWhiteSpace($recordId)-or$date-notmatch'^\d{14}$'-or[string]::IsNullOrWhiteSpace($doc)){$missingCritical++;continue}
      $hits=@{}
      foreach($surface in @(@('ALLNAMES',$AllNamesIndex),@('V2PERSONS',$PersonsIndex),@('V2ORGANIZATIONS',$OrganizationsIndex))){
       $parsed=Parse-OffsetNames ([string]$fields[$surface[1]]);$malformedBlocks+=[long]$parsed.malformed
       foreach($item in $parsed.items){
        $name=[string]$item.name;$norm=$name.Trim().ToLowerInvariant();if($tools.nameLookup.ContainsKey($norm)){foreach($key in $tools.nameLookup[$norm]){Add-Hit $hits $key ([string]$surface[0])}}
        $exact=$name.Trim();if($tools.symbolLookup.ContainsKey($exact)){foreach($key in $tools.symbolLookup[$exact]){Add-Hit $hits $key ([string]$surface[0])}}
       }
      }
      $title=Get-PageTitle ([string]$fields[$ExtrasIndex])
      if(-not[string]::IsNullOrWhiteSpace($title)){
       if($null-ne$tools.nameRegex){foreach($m in @($tools.nameRegex.Matches($title))){$norm=$m.Value.ToLowerInvariant();if($tools.nameLookup.ContainsKey($norm)){foreach($key in $tools.nameLookup[$norm]){Add-Hit $hits $key 'PAGE_TITLE'}}}}
       if($null-ne$tools.symbolRegex){foreach($m in @($tools.symbolRegex.Matches($title))){$exact=$m.Value;if($tools.symbolLookup.ContainsKey($exact)){foreach($key in $tools.symbolLookup[$exact]){Add-Hit $hits $key 'PAGE_TITLE'}}}}
      }
      if($hits.Count-eq0){continue}
      $econ=Test-EconBitcoin ([string]$fields[$ThemesIndex]);$titleCrypto=(-not[string]::IsNullOrWhiteSpace($title)-and$CryptoTitleRegex.IsMatch($title));$titleMarket=(-not[string]::IsNullOrWhiteSpace($title)-and$MarketTitleRegex.IsMatch($title));$acceptedByBase=@{}
      foreach($key in @($hits.Keys|Sort-Object)){
       $aliasCandidates++;$a=$tools.byKey[$key];$contextName=if([string]$a.match_policy-eq'CONTEXT_NAME'){Test-ContextNameEvidence ([string]$a.alias_text) $title}else{$false};$strictSymbol=if([string]$a.match_policy-eq'STRICT_SYMBOL_TITLE'){Test-StrictSymbolEvidence ([string]$a.alias_text) $title}else{$false};$ok=Accepted ([string]$a.match_policy) ([bool]$a.requires_crypto_context) $econ $titleCrypto $contextName $strictSymbol
       $reason=switch([string]$a.match_policy){'DIRECT_NAME'{'NOT_REQUIRED'}'CONTEXT_NAME'{if($contextName){'CONTEXT_NAME_LOCAL'}else{'CONTEXT_NAME_LOCAL_MISSING'}}'TITLE_CRYPTO_NAME'{if($titleCrypto){'TITLE_CRYPTO_REQUIRED'}else{'TITLE_CRYPTO_MISSING'}}'STRICT_SYMBOL_TITLE'{if($strictSymbol){'STRICT_SYMBOL_LOCAL'}else{'STRICT_SYMBOL_TITLE_EVIDENCE_MISSING'}}default{'NONE'}}
       $status=if($ok){'MATCH'}else{'REJECT_CONTEXT'}
       if($ok){$acceptedHits++;$base=[string]$a.base_asset_id;if(-not$acceptedByBase.ContainsKey($base)){$acceptedByBase[$base]=[pscustomobject]@{aliases=@{};surfaces=@{};context=@{}}};$state=$acceptedByBase[$base];$state.aliases[[string]$a.alias_text]=$true;foreach($surfaceName in $hits[$key].Keys){$state.surfaces[[string]$surfaceName]=$true};$state.context[$reason]=$true}
       else{$rejectedHits++;Write-CsvRow $rejectWriter @([string]$a.base_asset_id,[string]$a.alias_text,[string]$a.match_policy,$recordId,$date,[string]$fields[$SourceIndex],$doc,$file.Name,$rowOrdinal,(@($hits[$key].Keys|Sort-Object)-join'|'),$reason)}
       $sampleKey=([string]$a.base_asset_id)+'|'+([string]$a.alias_text).ToLowerInvariant()+'|'+$status;if(-not$sampleCount.ContainsKey($sampleKey)){$sampleCount[$sampleKey]=0};if([int]$sampleCount[$sampleKey]-lt$MaxSamplesPerAlias){Write-CsvRow $sampleWriter @($status,[string]$a.base_asset_id,[string]$a.alias_text,[string]$a.match_policy,[bool]$a.requires_crypto_context,$recordId,$date,[string]$fields[$SourceIndex],$doc,$title,(@($hits[$key].Keys|Sort-Object)-join'|'),$econ,$titleCrypto,$titleMarket,$contextName,$strictSymbol,$reason);$sampleCount[$sampleKey]=[int]$sampleCount[$sampleKey]+1}
      }
      foreach($base in @($acceptedByBase.Keys|Sort-Object)){$matchKey=$base+'|'+$recordId;if(-not$seen.Add($matchKey)){$duplicateMatches++;continue};[void]$matchedAssets.Add($base);$state=$acceptedByBase[$base];Write-CsvRow $matchWriter @($base,$recordId,$date,[string]$fields[$SourceIndex],$doc,$file.Name,$rowOrdinal,(@($state.aliases.Keys|Sort-Object)-join'|'),(@($state.surfaces.Keys|Sort-Object)-join'|'),(@($state.context.Keys|Sort-Object)-join'|'));$matchRows++}
     }
    }finally{$reader.Dispose()}
   }finally{if($null-ne$zip){$zip.Dispose()}}
  }
 }finally{$matchWriter.Dispose();$rejectWriter.Dispose();$sampleWriter.Dispose()}

 $shapeGate=if($total-eq$ExpectedRows-and$malformedRows-eq$ExpectedMalformedRows-and$missingCritical-eq0){'PASS'}else{'FAIL'};$runGate=if($shapeGate-eq'PASS'-and$duplicateMatches-eq0){'PASS'}else{'FAIL'}
 $summary=[ordered]@{run_status=$runGate;gates=[ordered]@{'S3-ID-01'='PASS';'CFA-S3-002'=$shapeGate;'CFA-S3-003'='PASS';'CFA-S3-004'=$runGate;'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'};source=[ordered]@{archive_root=$ArchiveRoot;archive_files=$files.Count;rows_scanned=$total;malformed_field_count_rows=$malformedRows;missing_critical_rows=$missingCritical;malformed_entity_blocks=$malformedBlocks};matching=[ordered]@{news_assets=431;alias_rows=$tools.aliasCount;match_policy_overrides=$tools.overrideCount;alias_candidates=$aliasCandidates;accepted_alias_hits=$acceptedHits;rejected_context_alias_hits=$rejectedHits;unique_asset_record_matches=$matchRows;matched_assets=$matchedAssets.Count;duplicate_asset_record_matches=$duplicateMatches};output=[ordered]@{matches_path=$matchPath;matches_sha256=(Get-FileHash $matchPath -Algorithm SHA256).Hash.ToLowerInvariant();rejects_path=$rejectPath;rejects_sha256=(Get-FileHash $rejectPath -Algorithm SHA256).Hash.ToLowerInvariant();samples_path=$samplePath;samples_sha256=(Get-FileHash $samplePath -Algorithm SHA256).Hash.ToLowerInvariant();alias_registry_sha256=(Get-FileHash $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant();match_override_sha256=(Get-FileHash $overridePath -Algorithm SHA256).Hash.ToLowerInvariant()}}
 Write-Utf8NoBom (Join-Path $OutputRoot 'stage3-match-summary.json') (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
 $b=New-Object Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 3 Kraken / GDELT News Matching Run');[void]$b.AppendLine('');[void]$b.AppendLine('- Run status: '+$runGate);[void]$b.AppendLine('- News assets: 431');[void]$b.AppendLine('- Alias rows: '+$tools.aliasCount);[void]$b.AppendLine('- Match-policy overrides: '+$tools.overrideCount);[void]$b.AppendLine('- Archives: '+$files.Count);[void]$b.AppendLine('- Rows scanned: '+$total);[void]$b.AppendLine('- Malformed 27-field rows: '+$malformedRows);[void]$b.AppendLine('- Unique asset/record matches: '+$matchRows);[void]$b.AppendLine('- Matched assets: '+$matchedAssets.Count+' of 431');[void]$b.AppendLine('- Context rejects: '+$rejectedHits);[void]$b.AppendLine('- Duplicate asset/record matches: '+$duplicateMatches);[void]$b.AppendLine('');[void]$b.AppendLine('CFA-S3-005 remains UNVERIFIED until the revised bounded accepted/rejected samples are directly reviewed. The prior 20260827 sample review failed and invalidated the previous matching output. No news factor is defined by this run.');Write-Utf8NoBom (Join-Path $OutputRoot 'stage3-match-summary.md') $b.ToString()
 Write-Host 'CFA STAGE 3 KRAKEN / GDELT NEWS MATCHING: COMPLETE';Write-Host ('Evidence directory: '+$OutputRoot);Write-Host ('Rows scanned: '+$total);Write-Host ('Unique asset/record matches: '+$matchRows);Write-Host ('Matched assets: '+$matchedAssets.Count+' of 431');Write-Host ('Context rejects: '+$rejectedHits);Write-Host ('CFA-S3-004 full Q2 matching run: '+$runGate);Write-Host 'CFA-S3-005 revised bounded sample review: UNVERIFIED';Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
 if($runGate-ne'PASS'){exit 2};exit 0
}catch{Write-Host 'CFA STAGE 3 KRAKEN / GDELT NEWS MATCHING: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
