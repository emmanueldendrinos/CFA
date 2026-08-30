#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = 'D:\CFA-bulk\source\gdelt-gkg-q2-2025',
    [string]$OutputRoot = '',
    [ValidateRange(1,64)][int]$WorkerCount = [Math]::Max(1,[Environment]::ProcessorCount),
    [ValidateRange(1,50)][int]$MaxSamplesPerAlias = 10,
    [switch]$KeepWorkerFiles,
    [switch]$WorkerMode,
    [ValidateRange(0,100000)][int]$WorkerId = 0,
    [ValidateRange(0,100000)][int]$WorkerStart = 0,
    [ValidateRange(0,100000)][int]$WorkerEnd = 0,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedFieldCount = 27
$ExpectedArchives = 7163
$ExpectedRows = 9183757L
$ExpectedMalformedRows = 5L
$ExpectedAliasRegistrySha256 = '11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'
$RecordIdIndex=0;$DateIndex=1;$SourceIndex=3;$DocumentIndex=4;$ThemesIndex=8;$PersonsIndex=12;$OrganizationsIndex=14;$AllNamesIndex=23;$ExtrasIndex=26
$StrongCryptoTitleRegex = New-Object System.Text.RegularExpressions.Regex('(?<![\p{L}\p{N}])(?:crypto|cryptocurrency|cryptocurrencies|blockchain|web3|defi|nft|nfts|digital\s+asset|digital\s+assets|stablecoin|stablecoins|altcoin|altcoins|meme\s+coin|meme\s+coins)(?![\p{L}\p{N}])',([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))

function Write-Utf8NoBom { param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};[IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false))) }
function Bool { param([object]$Value);$x=([string]$Value).Trim().ToLowerInvariant();if($x-eq'true'){return $true};if($x-eq'false'){return $false};throw "Malformed boolean: $Value" }
function AliasKey { param([string]$Base,[string]$Alias);return $Base+'|'+$Alias.Trim().ToLowerInvariant() }
function Csv { param([object]$Value);$s=if($null-eq$Value){''}else{[string]$Value};if($s.Contains('"')){$s=$s.Replace('"','""')};if($s.Contains(',')-or$s.Contains('"')-or$s.Contains("`r")-or$s.Contains("`n")){return '"'+$s+'"'};return $s }
function Write-CsvRow { param([IO.StreamWriter]$Writer,[object[]]$Values);$Writer.WriteLine((@($Values|ForEach-Object{Csv $_})-join',')) }
function Add-Hit { param([hashtable]$Hits,[string]$Key,[string]$Surface);if(-not$Hits.ContainsKey($Key)){$Hits[$Key]=@{}};$Hits[$Key][$Surface]=$true }
function Accepted { param([bool]$RequiresContext,[bool]$Econ,[bool]$TitleCrypto);if(-not$RequiresContext){return $true};return($Econ-or$TitleCrypto) }

function Parse-OffsetNames {
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
function Get-PageTitle { param([string]$Extras);if([string]::IsNullOrWhiteSpace($Extras)){return ''};$m=[regex]::Match($Extras,'<PAGE_TITLE>(.*?)</PAGE_TITLE>',[Text.RegularExpressions.RegexOptions]::IgnoreCase);if(-not$m.Success){return ''};return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
function Test-EconBitcoin { param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return $false};foreach($block in @($Text-split';')){if([string]::IsNullOrWhiteSpace($block)){continue};$comma=$block.LastIndexOf(',');$name=if($comma-gt0){$block.Substring(0,$comma).Trim()}else{$block.Trim()};if($name.Equals('ECON_BITCOIN',[StringComparison]::OrdinalIgnoreCase)){return $true}};return $false }
function Is-DefaultSymbolOnly { param([object]$AliasRow);return(([string]$AliasRow.alias_type)-eq'kraken_base_symbol'-and([string]$AliasRow.alias_source)-eq'AF001_KRAKEN_SYMBOL') }

function New-PhraseRegex {
    param([string[]]$Texts,[bool]$IgnoreCase)
    $parts=@($Texts|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique|Sort-Object Length -Descending|ForEach-Object{[regex]::Escape($_)})
    if($parts.Count-eq0){return $null}
    $options=[Text.RegularExpressions.RegexOptions]::CultureInvariant
    if($IgnoreCase){$options=$options-bor[Text.RegularExpressions.RegexOptions]::IgnoreCase}
    return New-Object Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:'+($parts-join'|')+')(?![\p{L}\p{N}])'),$options)
}

function Get-AliasTools {
    param([object[]]$Rows)
    $byKey=@{};$lookup=@{};$global=@{};$assets=@{};$approvedTexts=@();$symbolTexts=@()
    foreach($r in $Rows){
        $base=[string]$r.base_asset_id;$alias=([string]$r.alias_text).Trim();$key=AliasKey $base $alias
        if([string]::IsNullOrWhiteSpace($base)-or[string]::IsNullOrWhiteSpace($alias)){throw 'Stage 3 alias has empty base or alias.'}
        if($byKey.ContainsKey($key)){throw "Duplicate Stage 3 alias key: $key"}
        $ctx=Bool $r.requires_crypto_context;$defaultSymbol=Is-DefaultSymbolOnly $r
        $byKey[$key]=[pscustomobject]@{base_asset_id=$base;alias_text=$alias;alias_type=[string]$r.alias_type;requires_crypto_context=$ctx;alias_source=[string]$r.alias_source;default_symbol_only=$defaultSymbol}
        $norm=$alias.ToLowerInvariant();if(-not$lookup.ContainsKey($norm)){$lookup[$norm]=@()};$lookup[$norm]+=$key
        if(-not$global.ContainsKey($norm)){$global[$norm]=@{}};$global[$norm][$base]=$true;$assets[$base]=$true
        if($defaultSymbol){$symbolTexts+=$alias}else{$approvedTexts+=$alias}
    }
    if($assets.Count-ne431){throw "Stage 3 alias registry covers $($assets.Count) assets; expected 431."}
    foreach($norm in $global.Keys){if(@($global[$norm].Keys).Count-gt1){throw "Cross-asset Stage 3 alias collision: $norm"}}
    return [pscustomobject]@{byKey=$byKey;lookup=$lookup;approvedRegex=(New-PhraseRegex $approvedTexts $true);symbolRegex=(New-PhraseRegex $symbolTexts $false);assetCount=$assets.Count;aliasCount=$Rows.Count}
}

function Add-StructuredHits {
    param([hashtable]$Hits,[object]$Tools,[object[]]$Items,[string]$Surface)
    foreach($item in $Items){
        $norm=([string]$item.name).Trim().ToLowerInvariant();if(-not$Tools.lookup.ContainsKey($norm)){continue}
        foreach($key in $Tools.lookup[$norm]){$a=$Tools.byKey[$key];if([bool]$a.default_symbol_only-and-not(([string]$item.name).Trim()-ceq[string]$a.alias_text)){continue};Add-Hit $Hits $key $Surface}
    }
}
function Add-TitleHits {
    param([hashtable]$Hits,[object]$Tools,[string]$Title)
    if([string]::IsNullOrWhiteSpace($Title)){return}
    if($null-ne$Tools.approvedRegex){foreach($m in @($Tools.approvedRegex.Matches($Title))){$norm=$m.Value.ToLowerInvariant();if($Tools.lookup.ContainsKey($norm)){foreach($key in $Tools.lookup[$norm]){if(-not[bool]$Tools.byKey[$key].default_symbol_only){Add-Hit $Hits $key 'PAGE_TITLE'}}}}}
    if($null-ne$Tools.symbolRegex){foreach($m in @($Tools.symbolRegex.Matches($Title))){$norm=$m.Value.ToLowerInvariant();if($Tools.lookup.ContainsKey($norm)){foreach($key in $Tools.lookup[$norm]){if([bool]$Tools.byKey[$key].default_symbol_only){Add-Hit $Hits $key 'PAGE_TITLE'}}}}}
}

function Get-ArchiveFiles { param([string]$Root);if(-not(Test-Path -LiteralPath $Root -PathType Container)){throw "GDELT archive root missing: $Root"};return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.gkg.csv.zip'|Where-Object{$_.Name-match'^\d{14}\.gkg\.csv\.zip$'}|Sort-Object Name) }
function Get-WorkerRanges { param([int]$Count,[int]$Workers);$actual=[Math]::Min($Count,[Math]::Max(1,$Workers));$ranges=New-Object System.Collections.ArrayList;$base=[Math]::Floor($Count/$actual);$extra=$Count%$actual;$start=0;for($i=0;$i-lt$actual;$i++){$size=[int]$base+$(if($i-lt$extra){1}else{0});$end=$start+$size-1;[void]$ranges.Add([pscustomobject]@{id=$i;start=$start;end=$end;count=$size});$start=$end+1};return @($ranges.ToArray()) }

function Invoke-Worker {
    param([string]$Repo,[string]$Archives,[string]$WorkerRoot,[int]$Start,[int]$End,[int]$Id,[int]$SampleCap)
    $aliasPath=Join-Path $Repo 'candidate-analysis\CFA-Stage3-News-Aliases.csv';if(-not(Test-Path -LiteralPath $aliasPath -PathType Leaf)){throw 'Generated Stage 3 alias registry missing.'}
    $aliases=@(Import-Csv -LiteralPath $aliasPath);$tools=Get-AliasTools $aliases;$files=Get-ArchiveFiles $Archives
    if($files.Count-ne$ExpectedArchives){throw "Expected $ExpectedArchives GKG archives; observed $($files.Count)."};if($Start-lt0-or$End-ge$files.Count-or$End-lt$Start){throw "Invalid worker range $Start..$End"}
    New-Item -ItemType Directory -Path $WorkerRoot -Force|Out-Null
    $matchPath=Join-Path $WorkerRoot 'matches.csv';$rejectPath=Join-Path $WorkerRoot 'rejects.csv';$samplePath=Join-Path $WorkerRoot 'samples.csv';$utf8=New-Object Text.UTF8Encoding($false)
    $mw=New-Object IO.StreamWriter -ArgumentList $matchPath,$false,$utf8;$rw=New-Object IO.StreamWriter -ArgumentList $rejectPath,$false,$utf8;$sw=New-Object IO.StreamWriter -ArgumentList $samplePath,$false,$utf8
    Write-CsvRow $mw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons')
    Write-CsvRow $rw @('base_asset_id','alias_text','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_surfaces','context_reason')
    Write-CsvRow $sw @('match_status','base_asset_id','alias_text','requires_crypto_context','record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','matched_surfaces','econ_bitcoin_theme','title_crypto_anchor','context_reason')
    $sampleCount=@{};$seen=New-Object 'Collections.Generic.HashSet[string]';$matchedAssets=New-Object 'Collections.Generic.HashSet[string]';$lenient=New-Object Text.UTF8Encoding($false,$false)
    [long]$total=0;[long]$malformedRows=0;[long]$missingCritical=0;[long]$malformedBlocks=0;[long]$aliasCandidates=0;[long]$acceptedHits=0;[long]$rejectedHits=0;[long]$matchRows=0;[long]$duplicateMatches=0
    try{
        for($fi=$Start;$fi-le$End;$fi++){
            $file=$files[$fi];if($fi-eq$Start-or(($fi-$Start+1)%250)-eq0){Write-Host ("Worker {0}: archives {1}/{2} (global {3}/{4})"-f$Id,($fi-$Start+1),($End-$Start+1),($fi+1),$files.Count)}
            $zip=$null;try{$zip=[IO.Compression.ZipFile]::OpenRead($file.FullName);$entries=@($zip.Entries|Where-Object{-not[string]::IsNullOrWhiteSpace($_.Name)});if($entries.Count-ne1){throw "Expected one data entry in $($file.Name); observed $($entries.Count)."};$stream=$entries[0].Open();$reader=New-Object IO.StreamReader -ArgumentList $stream,$lenient,$false,65536,$false
                try{[long]$rowOrdinal=0;while(($line=$reader.ReadLine())-ne$null){
                    $rowOrdinal++;$total++;$fields=$line.Split([char]9);if($fields.Count-ne$ExpectedFieldCount){$malformedRows++;continue}
                    $recordId=[string]$fields[$RecordIdIndex];$date=[string]$fields[$DateIndex];$doc=[string]$fields[$DocumentIndex];if([string]::IsNullOrWhiteSpace($recordId)-or$date-notmatch'^\d{14}$'-or[string]::IsNullOrWhiteSpace($doc)){$missingCritical++;continue}
                    $hits=@{}
                    foreach($surface in @(@('ALLNAMES',$AllNamesIndex),@('V2PERSONS',$PersonsIndex),@('V2ORGANIZATIONS',$OrganizationsIndex))){$parsed=Parse-OffsetNames ([string]$fields[$surface[1]]);$malformedBlocks+=[long]$parsed.malformed;Add-StructuredHits $hits $tools @($parsed.items) ([string]$surface[0])}
                    $title=Get-PageTitle ([string]$fields[$ExtrasIndex]);Add-TitleHits $hits $tools $title
                    if($hits.Count-eq0){continue};$econ=Test-EconBitcoin ([string]$fields[$ThemesIndex]);$titleCrypto=(-not[string]::IsNullOrWhiteSpace($title)-and$StrongCryptoTitleRegex.IsMatch($title));$acceptedByBase=@{}
                    foreach($key in @($hits.Keys|Sort-Object)){$aliasCandidates++;$a=$tools.byKey[$key];$ok=Accepted ([bool]$a.requires_crypto_context) $econ $titleCrypto;$reason=if(-not[bool]$a.requires_crypto_context){'NOT_REQUIRED'}elseif($econ-and$titleCrypto){'ECON_BITCOIN|TITLE_CRYPTO'}elseif($econ){'ECON_BITCOIN'}elseif($titleCrypto){'TITLE_CRYPTO'}else{'NONE'};$status=if($ok){'MATCH'}else{'REJECT_CONTEXT'}
                        if($ok){$acceptedHits++;$base=[string]$a.base_asset_id;if(-not$acceptedByBase.ContainsKey($base)){$acceptedByBase[$base]=[pscustomobject]@{aliases=@{};surfaces=@{};context=@{}}};$state=$acceptedByBase[$base];$state.aliases[[string]$a.alias_text]=$true;foreach($surfaceName in $hits[$key].Keys){$state.surfaces[[string]$surfaceName]=$true};$state.context[$reason]=$true}else{$rejectedHits++;Write-CsvRow $rw @([string]$a.base_asset_id,[string]$a.alias_text,$recordId,$date,[string]$fields[$SourceIndex],$doc,$file.Name,$rowOrdinal,(@($hits[$key].Keys|Sort-Object)-join'|'),$reason)}
                        $sampleKey=([string]$a.base_asset_id)+'|'+([string]$a.alias_text).ToLowerInvariant()+'|'+$status;if(-not$sampleCount.ContainsKey($sampleKey)){$sampleCount[$sampleKey]=0};if([int]$sampleCount[$sampleKey]-lt$SampleCap){Write-CsvRow $sw @($status,[string]$a.base_asset_id,[string]$a.alias_text,[bool]$a.requires_crypto_context,$recordId,$date,[string]$fields[$SourceIndex],$doc,$title,(@($hits[$key].Keys|Sort-Object)-join'|'),$econ,$titleCrypto,$reason);$sampleCount[$sampleKey]=[int]$sampleCount[$sampleKey]+1}}
                    foreach($base in @($acceptedByBase.Keys|Sort-Object)){$matchKey=$base+'|'+$recordId;if(-not$seen.Add($matchKey)){$duplicateMatches++;continue};[void]$matchedAssets.Add($base);$state=$acceptedByBase[$base];Write-CsvRow $mw @($base,$recordId,$date,[string]$fields[$SourceIndex],$doc,$file.Name,$rowOrdinal,(@($state.aliases.Keys|Sort-Object)-join'|'),(@($state.surfaces.Keys|Sort-Object)-join'|'),(@($state.context.Keys|Sort-Object)-join'|'));$matchRows++}
                }}finally{$reader.Dispose()}
            }finally{if($null-ne$zip){$zip.Dispose()}}
        }
    }finally{$mw.Dispose();$rw.Dispose();$sw.Dispose()}
    $summary=[ordered]@{worker_id=$Id;start_index=$Start;end_index=$End;archive_count=($End-$Start+1);rows_scanned=$total;malformed_field_count_rows=$malformedRows;missing_critical_rows=$missingCritical;malformed_entity_blocks=$malformedBlocks;alias_candidates=$aliasCandidates;accepted_alias_hits=$acceptedHits;rejected_context_alias_hits=$rejectedHits;partial_unique_matches=$matchRows;partial_duplicate_matches=$duplicateMatches;partial_matched_assets=$matchedAssets.Count}
    Write-Utf8NoBom (Join-Path $WorkerRoot 'worker-summary.json') (($summary|ConvertTo-Json -Depth 6)+[Environment]::NewLine);Write-Host ("Worker {0}: COMPLETE rows={1} matches={2} rejects={3}"-f$Id,$total,$matchRows,$rejectedHits)
}

function Copy-BodyLines { param([string]$Source,[IO.StreamWriter]$Destination);$reader=New-Object IO.StreamReader $Source;try{[void]$reader.ReadLine();while(($line=$reader.ReadLine())-ne$null){$Destination.WriteLine($line)}}finally{$reader.Dispose()} }
function Merge-Workers {
    param([string]$WorkersRoot,[object[]]$Ranges,[string]$FinalRoot,[int]$SampleCap)
    $matchPath=Join-Path $FinalRoot 'stage3-news-matches.csv';$rejectPath=Join-Path $FinalRoot 'stage3-context-rejects.csv';$samplePath=Join-Path $FinalRoot 'stage3-match-samples.csv';$utf8=New-Object Text.UTF8Encoding($false)
    $mw=New-Object IO.StreamWriter -ArgumentList $matchPath,$false,$utf8;$rw=New-Object IO.StreamWriter -ArgumentList $rejectPath,$false,$utf8;$sw=New-Object IO.StreamWriter -ArgumentList $samplePath,$false,$utf8
    Write-CsvRow $mw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons');Write-CsvRow $rw @('base_asset_id','alias_text','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_surfaces','context_reason');Write-CsvRow $sw @('match_status','base_asset_id','alias_text','requires_crypto_context','record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','matched_surfaces','econ_bitcoin_theme','title_crypto_anchor','context_reason')
    $seen=New-Object 'Collections.Generic.HashSet[string]';$matchedAssets=New-Object 'Collections.Generic.HashSet[string]';$sampleCount=@{};[long]$matchRows=0;[long]$crossWorkerDuplicates=0
    try{foreach($range in @($Ranges|Sort-Object id)){$dir=Join-Path $WorkersRoot ('worker-{0:00}'-f[int]$range.id);foreach($r in @(Import-Csv -LiteralPath (Join-Path $dir 'matches.csv'))){$key=[string]$r.base_asset_id+'|'+[string]$r.record_id;if(-not$seen.Add($key)){$crossWorkerDuplicates++;continue};[void]$matchedAssets.Add([string]$r.base_asset_id);Write-CsvRow $mw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons);$matchRows++};Copy-BodyLines (Join-Path $dir 'rejects.csv') $rw;foreach($r in @(Import-Csv -LiteralPath (Join-Path $dir 'samples.csv'))){$key=[string]$r.base_asset_id+'|'+([string]$r.alias_text).ToLowerInvariant()+'|'+[string]$r.match_status;if(-not$sampleCount.ContainsKey($key)){$sampleCount[$key]=0};if([int]$sampleCount[$key]-ge$SampleCap){continue};Write-CsvRow $sw @($r.match_status,$r.base_asset_id,$r.alias_text,$r.requires_crypto_context,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.page_title,$r.matched_surfaces,$r.econ_bitcoin_theme,$r.title_crypto_anchor,$r.context_reason);$sampleCount[$key]=[int]$sampleCount[$key]+1}}}finally{$mw.Dispose();$rw.Dispose();$sw.Dispose()}
    return [pscustomobject]@{match_rows=$matchRows;cross_worker_duplicates=$crossWorkerDuplicates;matched_assets=$matchedAssets.Count;matches_path=$matchPath;rejects_path=$rejectPath;samples_path=$samplePath}
}
function Quote-Arg { param([string]$Value);return '"'+$Value.Replace('"','\"')+'"' }

function Invoke-SelfTest {
    $aliases=@([pscustomobject]@{base_asset_id='NEAR';alias_text='NEAR';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},[pscustomobject]@{base_asset_id='TERM';alias_text='TERM';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},[pscustomobject]@{base_asset_id='SKY';alias_text='SKY';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},[pscustomobject]@{base_asset_id='GRASS';alias_text='GRASS';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},[pscustomobject]@{base_asset_id='BAL';alias_text='BAL';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},[pscustomobject]@{base_asset_id='ARB';alias_text='Arbitrum';alias_type='manual_core_name';requires_crypto_context='False';alias_source='AF003_APPROVED_ALIAS'})
    $tools=Get-AliasTools $aliases;$h=@{};Add-TitleHits $h $tools 'BTC set for a Near-Term bounce';if($h.Count-ne0){throw 'NEAR ordinary-word title false positive'};$h=@{};Add-TitleHits $h $tools 'Short-Term Bitcoin holders';if($h.Count-ne0){throw 'TERM ordinary-word title false positive'};$h=@{};Add-TitleHits $h $tools 'Sky-High blockchain revolution';if($h.Count-ne0){throw 'SKY ordinary-word title false positive'};$h=@{};Add-TitleHits $h $tools 'grass seeds grow';if($h.Count-ne0){throw 'GRASS ordinary-word title false positive'};$h=@{};Add-TitleHits $h $tools 'Binance to delist BADGER, BAL, 12 more tokens';if(-not$h.ContainsKey('BAL|bal')){throw 'uppercase symbol title evidence'};$h=@{};Add-TitleHits $h $tools "Arbitrum's rise";if(-not$h.ContainsKey('ARB|arbitrum')){throw 'approved long-form title evidence'}
    if($StrongCryptoTitleRegex.IsMatch('Garden expert shares £1 coin hack')){throw 'generic coin must not be crypto context'};if(-not$StrongCryptoTitleRegex.IsMatch('New meme coins to invest in')){throw 'meme coin crypto context'};if(-not$StrongCryptoTitleRegex.IsMatch('Blockchain speed increases')){throw 'blockchain crypto context'}
    $ranges=@(Get-WorkerRanges 10 3);if($ranges.Count-ne3-or$ranges[0].end-ne3-or$ranges[2].end-ne9){throw 'worker range partition'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if($WorkerMode){Invoke-Worker $RepoRoot $ArchiveRoot $OutputRoot $WorkerStart $WorkerEnd $WorkerId $MaxSamplesPerAlias;exit 0}
    $builder=Join-Path $PSScriptRoot 'Build-CfaStage3NewsAliases.ps1';if(-not(Test-Path -LiteralPath $builder -PathType Leaf)){throw 'Stage 3 alias builder is missing.'};$global:LASTEXITCODE=$null;&$builder -RepoRoot $RepoRoot;$buildCode=if($null-eq$LASTEXITCODE){0}else{[int]$LASTEXITCODE};if($buildCode-ne0){throw "S3-ID-01 alias build failed with exit $buildCode."};$global:LASTEXITCODE=0
    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv';$aliases=@(Import-Csv -LiteralPath $aliasPath);$tools=Get-AliasTools $aliases;if((Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()-ne$ExpectedAliasRegistrySha256){throw 'Alias registry SHA-256 differs from frozen Stage 3 registry.'}
    $files=Get-ArchiveFiles $ArchiveRoot;if($files.Count-ne$ExpectedArchives){throw "Expected $ExpectedArchives GKG archives; observed $($files.Count)."}
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path 'D:\CFA-bulk\analysis\stage3-news-matching' ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-parallel-v2-'+[guid]::NewGuid().ToString('N').Substring(0,8))};New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null;$OutputRoot=(Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    $workersRoot=Join-Path $OutputRoot '_workers';New-Item -ItemType Directory -Path $workersRoot -Force|Out-Null;$ranges=@(Get-WorkerRanges $files.Count $WorkerCount);Write-Host ("Stage 3 V2 parallel scan: {0} archives across {1} worker process(es)"-f$files.Count,$ranges.Count)
    $exe=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$procs=New-Object System.Collections.ArrayList
    foreach($range in $ranges){$dir=Join-Path $workersRoot ('worker-{0:00}'-f[int]$range.id);New-Item -ItemType Directory -Path $dir -Force|Out-Null;$stdout=Join-Path $dir 'stdout.log';$stderr=Join-Path $dir 'stderr.log';$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-Arg $PSCommandPath),'-WorkerMode','-RepoRoot',(Quote-Arg $RepoRoot),'-ArchiveRoot',(Quote-Arg $ArchiveRoot),'-OutputRoot',(Quote-Arg $dir),'-WorkerId',[string]$range.id,'-WorkerStart',[string]$range.start,'-WorkerEnd',[string]$range.end,'-MaxSamplesPerAlias',[string]$MaxSamplesPerAlias);$p=Start-Process -FilePath $exe -ArgumentList $args -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr;[void]$procs.Add([pscustomobject]@{process=$p;range=$range;dir=$dir})}
    foreach($item in @($procs.ToArray())){$item.process.WaitForExit();if($item.process.ExitCode-ne0){$err=if(Test-Path (Join-Path $item.dir 'stderr.log')){Get-Content (Join-Path $item.dir 'stderr.log') -Raw}else{''};$out=if(Test-Path (Join-Path $item.dir 'stdout.log')){Get-Content (Join-Path $item.dir 'stdout.log') -Raw}else{''};throw "Worker $($item.range.id) failed with exit $($item.process.ExitCode).`n$out`n$err"}}
    [long]$total=0;[long]$malformed=0;[long]$missing=0;[long]$blocks=0;[long]$candidates=0;[long]$accepted=0;[long]$rejected=0;[long]$localDuplicates=0
    foreach($range in $ranges){$dir=Join-Path $workersRoot ('worker-{0:00}'-f[int]$range.id);$ws=Get-Content -LiteralPath (Join-Path $dir 'worker-summary.json') -Raw|ConvertFrom-Json;$total+=[long]$ws.rows_scanned;$malformed+=[long]$ws.malformed_field_count_rows;$missing+=[long]$ws.missing_critical_rows;$blocks+=[long]$ws.malformed_entity_blocks;$candidates+=[long]$ws.alias_candidates;$accepted+=[long]$ws.accepted_alias_hits;$rejected+=[long]$ws.rejected_context_alias_hits;$localDuplicates+=[long]$ws.partial_duplicate_matches}
    $merge=Merge-Workers $workersRoot $ranges $OutputRoot $MaxSamplesPerAlias;$duplicates=$localDuplicates+[long]$merge.cross_worker_duplicates;$shapeGate=if($total-eq$ExpectedRows-and$malformed-eq$ExpectedMalformedRows-and$missing-eq0){'PASS'}else{'FAIL'};$runGate=if($shapeGate-eq'PASS'-and$duplicates-eq0){'PASS'}else{'FAIL'}
    $summary=[ordered]@{run_status=$runGate;implementation='parallel-v2-precision-hardened';worker_count=$ranges.Count;matching_contract='CANDIDATE_V2';gates=[ordered]@{'S3-ID-01'='PASS';'CFA-S3-002'=$shapeGate;'CFA-S3-003'='PASS';'CFA-S3-004'=$runGate;'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'};source=[ordered]@{archive_root=$ArchiveRoot;archive_files=$files.Count;rows_scanned=$total;malformed_field_count_rows=$malformed;missing_critical_rows=$missing;malformed_entity_blocks=$blocks};matching=[ordered]@{news_assets=431;alias_rows=$tools.aliasCount;alias_candidates=$candidates;accepted_alias_hits=$accepted;rejected_context_alias_hits=$rejected;unique_asset_record_matches=$merge.match_rows;matched_assets=$merge.matched_assets;duplicate_asset_record_matches=$duplicates};output=[ordered]@{matches_path=$merge.matches_path;matches_sha256=(Get-FileHash $merge.matches_path -Algorithm SHA256).Hash.ToLowerInvariant();rejects_path=$merge.rejects_path;rejects_sha256=(Get-FileHash $merge.rejects_path -Algorithm SHA256).Hash.ToLowerInvariant();samples_path=$merge.samples_path;samples_sha256=(Get-FileHash $merge.samples_path -Algorithm SHA256).Hash.ToLowerInvariant();alias_registry_sha256=(Get-FileHash $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
    Write-Utf8NoBom (Join-Path $OutputRoot 'stage3-match-summary.json') (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
    if(-not$KeepWorkerFiles){foreach($range in $ranges){$d=Join-Path $workersRoot ('worker-{0:00}'-f[int]$range.id);foreach($name in @('matches.csv','rejects.csv','samples.csv')){Remove-Item -LiteralPath (Join-Path $d $name) -Force -ErrorAction SilentlyContinue}}}
    Write-Host '';Write-Host 'CFA STAGE 3 V2 PARALLEL KRAKEN / GDELT NEWS MATCHING: COMPLETE';Write-Host ("Workers: {0}"-f$ranges.Count);Write-Host ("Rows scanned: {0}"-f$total);Write-Host ("Unique asset/record matches: {0}"-f$merge.match_rows);Write-Host ("Matched assets: {0} of 431"-f$merge.matched_assets);Write-Host ("Context rejects: {0}"-f$rejected);Write-Host ("CFA-S3-004 full Q2 matching run: {0}"-f$runGate);Write-Host 'CFA-S3-005 bounded sample review: UNVERIFIED';Write-Host 'CFA-S3-006 freeze news matching: BLOCKED';Write-Host ("Evidence directory: {0}"-f$OutputRoot);if($runGate-ne'PASS'){exit 2};exit 0
}catch{Write-Host '';Write-Host 'CFA STAGE 3 V2 PARALLEL KRAKEN / GDELT NEWS MATCHING: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
