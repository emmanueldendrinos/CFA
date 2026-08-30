#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V5RunRoot,
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = 'D:\CFA-bulk\source\gdelt-gkg-q2-2025',
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedArchives = 7163
$ExpectedRawRows = 9183757L
$ExpectedMalformedRows = 5L
$ExpectedUtf8Exclusions = 126L
$ExpectedEligibleRows = 9183626L
$ExpectedAliasRegistrySha256 = '11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'
$ExpectedFieldCount = 27
$AllNamesIndex = 23
$PersonsIndex = 12
$OrganizationsIndex = 14
$ExtrasIndex = 26

$ParentheticalMarketAnchorRegex = New-Object System.Text.RegularExpressions.Regex(
    '(?<![\p{L}\p{N}])(?:price|market\s+cap(?:italization|italisation)?|market\s+capitalization|market\s+capitalisation|volume|trading|trade|trades|exchange|token|coin|crypto|cryptocurrency)(?![\p{L}\p{N}])',
    ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
)
$StrongLocalMarketRegex = New-Object System.Text.RegularExpressions.Regex(
    '(?<![\p{L}\p{N}])(?:price|rally|rallies|rallied|surge|surges|surged|gain|gains|gained|rise|rises|rose|jump|jumps|jumped|drop|drops|dropped|fall|falls|fell|down|up|volume|market\s+cap(?:italization|italisation)?|market\s+capitalization|market\s+capitalisation|trading|trade|trades)(?![\p{L}\p{N}])',
    ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
)

function Write-Utf8NoBom { param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};[IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false))) }
function Get-Sha { param([string]$Path);return(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Csv { param([object]$Value);$s=if($null-eq$Value){''}else{[string]$Value};if($s.Contains('"')){$s=$s.Replace('"','""')};if($s.Contains(',')-or$s.Contains('"')-or$s.Contains("`r")-or$s.Contains("`n")){return '"'+$s+'"'};return $s }
function Write-CsvRow { param([IO.StreamWriter]$Writer,[object[]]$Values);$Writer.WriteLine((@($Values|ForEach-Object{Csv $_})-join',')) }
function Parse-Bool { param([object]$Value,[string]$Label);$x=([string]$Value).Trim().ToLowerInvariant();if($x-eq'true'){return $true};if($x-eq'false'){return $false};throw "Malformed boolean in ${Label}: '$Value'" }
function Alias-Key { param([string]$Base,[string]$Alias);return $Base.Trim()+'|'+$Alias.Trim().ToLowerInvariant() }
function Row-Key { param([string]$Archive,[object]$Ordinal);return $Archive.Trim().ToLowerInvariant()+'|'+([long]$Ordinal).ToString() }
function Is-DefaultSymbolOnly { param([object]$AliasRow);return(([string]$AliasRow.alias_type)-eq'kraken_base_symbol'-and([string]$AliasRow.alias_source)-eq'AF001_KRAKEN_SYMBOL') }
function Parse-OffsetNames {
    param([string]$Text)
    $items=New-Object System.Collections.ArrayList
    if([string]::IsNullOrWhiteSpace($Text)){return @()}
    foreach($block in @($Text-split';')){$comma=$block.LastIndexOf(',');if($comma-le0){continue};$name=$block.Substring(0,$comma).Trim();if(-not[string]::IsNullOrWhiteSpace($name)){[void]$items.Add($name)}}
    return @($items.ToArray())
}
function Get-PageTitle { param([string]$Extras);if([string]::IsNullOrWhiteSpace($Extras)){return ''};$m=[regex]::Match($Extras,'<PAGE_TITLE>(.*?)</PAGE_TITLE>',[Text.RegularExpressions.RegexOptions]::IgnoreCase);if(-not$m.Success){return ''};return[Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
function Test-TitleSymbolToken {
    param([string]$Title,[string]$Symbol)
    if([string]::IsNullOrWhiteSpace($Title)-or[string]::IsNullOrWhiteSpace($Symbol)){return $false}
    $pattern='(?<![\p{L}\p{N}_])'+[regex]::Escape($Symbol)+'(?![\p{L}\p{N}_])'
    return[regex]::IsMatch($Title,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
}
function Test-ParentheticalMarketTicker {
    param([string]$Title,[string]$Symbol)
    if([string]::IsNullOrWhiteSpace($Title)-or[string]::IsNullOrWhiteSpace($Symbol)){return $false}
    $pattern='\(\s*'+[regex]::Escape($Symbol)+'\s*\)'
    return([regex]::IsMatch($Title,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)-and$ParentheticalMarketAnchorRegex.IsMatch($Title))
}
function Test-StructuredExact { param([object]$Raw,[string]$Symbol);foreach($name in @($Raw.structured_names)){if([string]$name-ceq$Symbol){return $true}};return $false }
function Test-LocalMarketEvidence {
    param([string]$Title,[string]$Symbol)
    if(-not(Test-TitleSymbolToken $Title $Symbol)){return $false}
    $pattern='(?<![\p{L}\p{N}_])'+[regex]::Escape($Symbol)+'(?![\p{L}\p{N}_])'
    foreach($m in @([regex]::Matches($Title,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant))){
        $start=[Math]::Max(0,$m.Index-48);$end=[Math]::Min($Title.Length,$m.Index+$m.Length+48);$window=$Title.Substring($start,$end-$start)
        if($StrongLocalMarketRegex.IsMatch($window)){return $true}
    }
    return $false
}
function Get-AliasTools {
    param([object[]]$Aliases)
    $byKey=@{};$assets=@{}
    foreach($a in $Aliases){$base=([string]$a.base_asset_id).Trim();$text=([string]$a.alias_text).Trim();$key=Alias-Key $base $text;if($byKey.ContainsKey($key)){throw "Duplicate Stage 3 alias key: $key"};$default=Is-DefaultSymbolOnly $a;$byKey[$key]=[pscustomobject]@{short_default_symbol=($default-and$text.Length-le2);approved_nondefault=(-not$default);alias_text=$text};$assets[$base]=$true}
    if($assets.Count-ne431){throw "Alias registry covers $($assets.Count) assets; expected 431."}
    return[pscustomobject]@{byKey=$byKey;asset_count=$assets.Count;alias_count=$Aliases.Count}
}
function Get-MatchAliasMetadata {
    param([object]$Row,[object]$Tools)
    $base=([string]$Row.base_asset_id).Trim();$short=New-Object System.Collections.ArrayList;$approved=$false
    foreach($raw in @(([string]$Row.matched_aliases)-split'\|')){$text=$raw.Trim();if([string]::IsNullOrWhiteSpace($text)){continue};$key=Alias-Key $base $text;if(-not$Tools.byKey.ContainsKey($key)){throw "V5 match references alias absent from registry: $base / $text"};$m=$Tools.byKey[$key];if([bool]$m.short_default_symbol){[void]$short.Add([string]$m.alias_text)};if([bool]$m.approved_nondefault){$approved=$true}}
    return[pscustomobject]@{short_aliases=@($short.ToArray());approved_nondefault=$approved}
}
function Assert-V5 {
    param([string]$Root,[string]$AliasPath)
    $summaryPath=Join-Path $Root 'stage3-match-summary.json';$matches=Join-Path $Root 'stage3-news-matches.csv';$rejects=Join-Path $Root 'stage3-v5-short-symbol-rejects.csv';$samples=Join-Path $Root 'stage3-match-samples.csv'
    foreach($p in @($summaryPath,$matches,$rejects,$samples)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required V5 artifact missing: $p"}}
    $s=Get-Content -LiteralPath $summaryPath -Raw|ConvertFrom-Json
    if([string]$s.run_status-ne'PASS'-or[string]$s.matching_contract-ne'CANDIDATE_V5'){throw'Input is not PASS CANDIDATE_V5.'}
    if([long]$s.source.raw_rows-ne$ExpectedRawRows-or[long]$s.source.malformed_rows_excluded-ne$ExpectedMalformedRows-or[long]$s.source.utf8_rows_excluded-ne$ExpectedUtf8Exclusions-or[long]$s.source.eligible_rows-ne$ExpectedEligibleRows-or[int]$s.source.archive_files-ne$ExpectedArchives){throw'V5 source/eligibility shape mismatch.'}
    if([string]$s.gates.'CFA-S3F-016'-ne'PASS'-or[string]$s.gates.'CFA-S3F-017'-ne'PASS'-or[string]$s.gates.'CFA-S3F-018'-ne'PASS'){throw'V5 mechanical gates are not PASS.'}
    if((Get-Sha $AliasPath)-ne$ExpectedAliasRegistrySha256){throw'Current alias registry differs from frozen registry.'}
    if((Get-Sha $matches)-ne([string]$s.output.matches_sha256).ToLowerInvariant()){throw'V5 matches hash mismatch.'}
    if((Get-Sha $rejects)-ne([string]$s.output.short_rejects_sha256).ToLowerInvariant()){throw'V5 rejects hash mismatch.'}
    if((Get-Sha $samples)-ne([string]$s.output.samples_sha256).ToLowerInvariant()){throw'V5 samples hash mismatch.'}
    return[pscustomobject]@{summary=$s;summary_path=$summaryPath;matches=$matches;rejects=$rejects;samples=$samples}
}
function Classify-V6 {
    param([object]$Row,[object]$Meta,[object]$Raw)
    if(@($Meta.short_aliases).Count-eq0){return[pscustomobject]@{keep=$true;reason='NOT_SHORT_DEFAULT';local_market=$false;structured=$false;parenthetical=$false;approved=$false;short_aliases=@()}}
    if([bool]$Meta.approved_nondefault){return[pscustomobject]@{keep=$true;reason='APPROVED_NONDEFAULT_SAME_RECORD';local_market=$false;structured=$false;parenthetical=$false;approved=$true;short_aliases=@($Meta.short_aliases)}}
    $structured=$false;$parenthetical=$false;$local=$false
    foreach($symbol in @($Meta.short_aliases)){if(Test-StructuredExact $Raw $symbol){$structured=$true};if(Test-ParentheticalMarketTicker ([string]$Raw.page_title) $symbol){$parenthetical=$true};if(Test-LocalMarketEvidence ([string]$Raw.page_title) $symbol){$local=$true}}
    if($parenthetical){return[pscustomobject]@{keep=$true;reason='PAREN_TICKER_MARKET';local_market=$local;structured=$structured;parenthetical=$true;approved=$false;short_aliases=@($Meta.short_aliases)}}
    if($structured){return[pscustomobject]@{keep=$true;reason='STRUCTURED_EXACT_SHORT_SYMBOL';local_market=$local;structured=$true;parenthetical=$false;approved=$false;short_aliases=@($Meta.short_aliases)}}
    if($local){return[pscustomobject]@{keep=$true;reason='TITLE_LOCAL_MARKET_SHORT_SYMBOL';local_market=$true;structured=$false;parenthetical=$false;approved=$false;short_aliases=@($Meta.short_aliases)}}
    return[pscustomobject]@{keep=$false;reason='SHORT_DEFAULT_REQUIRES_LOCAL_MARKET_OR_HIGH_SPECIFICITY';local_market=$false;structured=$false;parenthetical=$false;approved=$false;short_aliases=@($Meta.short_aliases)}
}
function Invoke-SelfTest {
    if(Test-LocalMarketEvidence 'New Cryptocurrency Releases - Grade, IP Exchange, AMALAS' 'IP'){throw'IP Exchange must not satisfy strong local market evidence.'}
    if(-not(Test-LocalMarketEvidence 'Why could OM rally despite weakness in the crypto market?' 'OM')){throw'OM rally must satisfy strong local market evidence.'}
    if(Test-TitleSymbolToken 'Bitcoin debate on OP_RETURN limits' 'OP'){throw'OP_RETURN must not be a valid OP title token.'}
    if(-not(Test-ParentheticalMarketTicker 'Story (IP) Price Down 9.6%' 'IP')){throw'Story (IP) price must satisfy parenthetical market ticker.'}
    $raw=[pscustomobject]@{page_title='New Cryptocurrency Releases - Grade, IP Exchange, AMALAS';structured_names=@()};$row=[pscustomobject]@{};$meta=[pscustomobject]@{short_aliases=@('IP');approved_nondefault=$false};if([bool](Classify-V6 $row $meta $raw).keep){throw'IP Exchange V6 regression must reject.'}
    $raw=[pscustomobject]@{page_title='Why could OM rally despite weakness in the crypto market?';structured_names=@()};$meta=[pscustomobject]@{short_aliases=@('OM');approved_nondefault=$false};$c=Classify-V6 $row $meta $raw;if(-not[bool]$c.keep-or[string]$c.reason-ne'TITLE_LOCAL_MARKET_SHORT_SYMBOL'){throw'OM rally V6 regression must retain.'}
    $raw=[pscustomobject]@{page_title='Any title';structured_names=@('IP')};$meta=[pscustomobject]@{short_aliases=@('IP');approved_nondefault=$false};if(-not[bool](Classify-V6 $row $meta $raw).keep){throw'Exact structured short symbol must retain.'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath;$Stage3V5RunRoot=(Resolve-Path -LiteralPath $Stage3V5RunRoot).ProviderPath
    if(Test-Path -LiteralPath $OutputRoot){if(@(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue).Count-gt0){throw "OutputRoot must be empty: $OutputRoot"}}else{New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null};$OutputRoot=(Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv';if(-not(Test-Path -LiteralPath $aliasPath -PathType Leaf)){throw'Frozen Stage 3 alias registry missing.'}
    $aliases=@(Import-Csv -LiteralPath $aliasPath);$tools=Get-AliasTools $aliases;$v5=Assert-V5 $Stage3V5RunRoot $aliasPath
    $v5Matches=@(Import-Csv -LiteralPath $v5.matches);$targetByArchive=@{};$metaByAssetRecord=@{};$seen=New-Object 'Collections.Generic.HashSet[string]'
    foreach($r in $v5Matches){$assetRecord=([string]$r.base_asset_id)+'|'+([string]$r.record_id);if(-not$seen.Add($assetRecord)){throw "Duplicate V5 asset/record: $assetRecord"};$meta=Get-MatchAliasMetadata $r $tools;$metaByAssetRecord[$assetRecord]=$meta;if(@($meta.short_aliases).Count-gt0){$a=([string]$r.archive_file).Trim();if(-not$targetByArchive.ContainsKey($a)){$targetByArchive[$a]=@{}};$targetByArchive[$a][[long]$r.row_ordinal]=$true}}
    $files=@{};foreach($f in @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip')){if($f.Name-match'^\d{14}\.gkg\.csv\.zip$'){if($files.ContainsKey($f.Name)){throw "Duplicate raw archive: $($f.Name)"};$files[$f.Name]=$f.FullName}};if($files.Count-ne$ExpectedArchives){throw "Current source has $($files.Count) archives; expected $ExpectedArchives."}
    $rawByKey=@{};$lenient=New-Object Text.UTF8Encoding($false,$false);$n=0
    foreach($archive in @($targetByArchive.Keys|Sort-Object)){$n++;if($n-eq1-or($n%100)-eq0){Write-Host("V6 short-symbol raw-title archives: {0}/{1}"-f$n,$targetByArchive.Count)};if(-not$files.ContainsKey($archive)){throw "Target archive missing: $archive"};$targets=$targetByArchive[$archive];$max=[long](@($targets.Keys|Measure-Object -Maximum).Maximum);$zip=$null;try{$zip=[IO.Compression.ZipFile]::OpenRead([string]$files[$archive]);$entries=@($zip.Entries|Where-Object{-not[string]::IsNullOrWhiteSpace($_.Name)});if($entries.Count-ne1){throw "Expected one entry in $archive"};$reader=New-Object IO.StreamReader -ArgumentList $entries[0].Open(),$lenient,$false,65536,$false;try{[long]$ord=0;while(($line=$reader.ReadLine())-ne$null){$ord++;if($ord-gt$max){break};if(-not$targets.ContainsKey($ord)){continue};$fields=$line.Split([char]9);if($fields.Count-ne$ExpectedFieldCount){throw "Target V5 match points to malformed raw row: $archive / $ord"};$names=New-Object System.Collections.ArrayList;foreach($idx in @($AllNamesIndex,$PersonsIndex,$OrganizationsIndex)){foreach($name in @(Parse-OffsetNames ([string]$fields[$idx]))){[void]$names.Add($name)}};$rawByKey[(Row-Key $archive $ord)]=[pscustomobject]@{page_title=(Get-PageTitle ([string]$fields[$ExtrasIndex]));structured_names=@($names.ToArray())}}finally{$reader.Dispose()}}finally{if($null-ne$zip){$zip.Dispose()}}}
    $expectedTargets=0;foreach($a in $targetByArchive.Keys){$expectedTargets+=$targetByArchive[$a].Count};if($rawByKey.Count-ne$expectedTargets){throw "Raw recovery incomplete: expected $expectedTargets, observed $($rawByKey.Count)."}

    $matchOut=Join-Path $OutputRoot 'stage3-news-matches.csv';$rejectOut=Join-Path $OutputRoot 'stage3-v6-local-market-rejects.csv';$sampleOut=Join-Path $OutputRoot 'stage3-match-samples.csv';$utf8=New-Object Text.UTF8Encoding($false);$mw=New-Object IO.StreamWriter -ArgumentList $matchOut,$false,$utf8;$rw=New-Object IO.StreamWriter -ArgumentList $rejectOut,$false,$utf8
    Write-CsvRow $mw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons')
    Write-CsvRow $rw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons','short_default_aliases','v6_filter_reason','page_title')
    $classByAssetRecord=@{};$matchedAssets=New-Object 'Collections.Generic.HashSet[string]';[long]$kept=0;[long]$removed=0
    try{foreach($r in $v5Matches){$assetRecord=([string]$r.base_asset_id)+'|'+([string]$r.record_id);$meta=$metaByAssetRecord[$assetRecord];if(@($meta.short_aliases).Count-eq0){$class=[pscustomobject]@{keep=$true;reason='NOT_SHORT_DEFAULT';local_market=$false;structured=$false;parenthetical=$false;approved=$false;short_aliases=@()}}else{$key=Row-Key ([string]$r.archive_file) $r.row_ordinal;if(-not$rawByKey.ContainsKey($key)){throw "Missing raw row: $key"};$class=Classify-V6 $r $meta $rawByKey[$key]};$classByAssetRecord[$assetRecord]=$class;if([bool]$class.keep){Write-CsvRow $mw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons);[void]$matchedAssets.Add([string]$r.base_asset_id);$kept++}else{$key=Row-Key ([string]$r.archive_file) $r.row_ordinal;Write-CsvRow $rw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons,(@($class.short_aliases)-join'|'),$class.reason,[string]$rawByKey[$key].page_title);$removed++}}}finally{$mw.Dispose();$rw.Dispose()}
    if(($kept+$removed)-ne$v5Matches.Count){throw'V6 match accounting does not reconcile.'}

    $sampleRows=New-Object System.Collections.ArrayList
    foreach($s in @(Import-Csv -LiteralPath $v5.samples)){$v5Status=([string]$s.v5_match_status).Trim();$v6Status=$v5Status;$reason='V5_STATUS_PRESERVED';$local=$false;$base=([string]$s.base_asset_id).Trim();$alias=([string]$s.alias_text).Trim();if($v5Status-eq'MATCH'){$short=Parse-Bool $s.v5_short_default_symbol "sample short";if(-not$short){$reason='NOT_SHORT_DEFAULT'}elseif(Parse-Bool $s.v5_approved_nondefault_same_record 'sample approved'){$reason='APPROVED_NONDEFAULT_SAME_RECORD'}elseif(Parse-Bool $s.v5_parenthetical_market_ticker 'sample parenthetical'){$reason='PAREN_TICKER_MARKET'}elseif(Parse-Bool $s.v5_structured_symbol_exact 'sample structured'){$reason='STRUCTURED_EXACT_SHORT_SYMBOL'}else{$local=Test-LocalMarketEvidence ([string]$s.page_title) $alias;if($local){$reason='TITLE_LOCAL_MARKET_SHORT_SYMBOL'}else{$v6Status='REJECT_V6_SHORT_SYMBOL_LOCAL_MARKET_CONTEXT';$reason='SHORT_DEFAULT_REQUIRES_LOCAL_MARKET_OR_HIGH_SPECIFICITY'}}}elseif($v5Status-eq'REJECT_CONTEXT'){$reason='V2_CONTEXT_REJECT'}elseif($v5Status-eq'REJECT_V5_SHORT_SYMBOL_CONTEXT'){$reason='V5_SHORT_SYMBOL_REJECT_PRESERVED'}else{throw "Unexpected V5 sample status: $v5Status"};[void]$sampleRows.Add([pscustomobject][ordered]@{v6_match_status=$v6Status;v6_filter_reason=$reason;v6_local_market_context=$local;v5_match_status=$v5Status;v5_filter_reason=[string]$s.v5_filter_reason;v2_match_status=[string]$s.v2_match_status;v5_short_default_symbol=[string]$s.v5_short_default_symbol;v5_approved_nondefault_same_record=[string]$s.v5_approved_nondefault_same_record;v5_title_symbol_valid=[string]$s.v5_title_symbol_valid;v5_structured_symbol_exact=[string]$s.v5_structured_symbol_exact;v5_parenthetical_market_ticker=[string]$s.v5_parenthetical_market_ticker;base_asset_id=$base;alias_text=$alias;requires_crypto_context=[string]$s.requires_crypto_context;record_id=[string]$s.record_id;gdelt_date_utc=[string]$s.gdelt_date_utc;source_common_name=[string]$s.source_common_name;document_identifier=[string]$s.document_identifier;page_title=[string]$s.page_title;matched_surfaces=[string]$s.matched_surfaces;econ_bitcoin_theme=[string]$s.econ_bitcoin_theme;title_crypto_anchor=[string]$s.title_crypto_anchor;context_reason=[string]$s.context_reason})}
    @($sampleRows.ToArray())|Export-Csv -LiteralPath $sampleOut -NoTypeInformation -Encoding UTF8
    $ipx=@($sampleRows|Where-Object{$_.base_asset_id-eq'IP'-and$_.alias_text-ceq'IP'-and$_.page_title-match'IP Exchange'-and$_.v6_match_status-eq'REJECT_V6_SHORT_SYMBOL_LOCAL_MARKET_CONTEXT'});if($ipx.Count-eq0){throw'IP Exchange false-positive regression was not rejected by V6.'}
    $om=@($sampleRows|Where-Object{$_.base_asset_id-eq'OM'-and$_.alias_text-ceq'OM'-and$_.page_title-match'OM rally'-and$_.v6_match_status-eq'MATCH'});if($om.Count-eq0){throw'OM rally retention regression is absent in V6.'}
    foreach($pattern in @('Arweave \(AR\)','Story \(IP\)')){if(@($sampleRows|Where-Object{$_.page_title-match$pattern-and$_.v6_match_status-eq'MATCH'}).Count-eq0){throw "Required parenthetical regression missing: $pattern"}}

    $summaryPath=Join-Path $OutputRoot 'stage3-match-summary.json';$summary=[ordered]@{run_status='PASS';implementation='v6-short-default-local-market-postfilter';matching_contract='CANDIDATE_V6';rule='Starting from hash-verified V5, retain short default symbols on approved non-default same-record support, exact structured symbol evidence, parenthetical ticker plus market anchor, or standalone title symbol with strong local market-action evidence; otherwise reject.';source=[ordered]@{raw_rows=$ExpectedRawRows;malformed_rows_excluded=$ExpectedMalformedRows;utf8_rows_excluded=$ExpectedUtf8Exclusions;eligible_rows=$ExpectedEligibleRows;archive_files=$ExpectedArchives};parent_v5=[ordered]@{run_root=$Stage3V5RunRoot;summary_sha256=(Get-Sha $v5.summary_path);matches_sha256=(Get-Sha $v5.matches);rejects_sha256=(Get-Sha $v5.rejects);samples_sha256=(Get-Sha $v5.samples)};matching=[ordered]@{parent_v5_matches=$v5Matches.Count;retained_asset_record_matches=$kept;removed_v6_short_symbol_matches=$removed;matched_assets=$matchedAssets.Count;targeted_raw_rows=$rawByKey.Count;targeted_raw_archives=$targetByArchive.Count;duplicate_asset_record_matches=0};output=[ordered]@{matches_path=$matchOut;matches_sha256=(Get-Sha $matchOut);new_rejects_path=$rejectOut;new_rejects_sha256=(Get-Sha $rejectOut);samples_path=$sampleOut;samples_sha256=(Get-Sha $sampleOut);parent_v5_short_rejects_path=$v5.rejects;parent_v5_short_rejects_sha256=(Get-Sha $v5.rejects);alias_registry_sha256=(Get-Sha $aliasPath)};gates=[ordered]@{'CFA-S3F-008'='FAIL';'CFA-S3F-011'='PASS';'CFA-S3F-012'='PASS';'CFA-S3F-014'='FAIL';'CFA-S3F-016'='PASS';'CFA-S3F-017'='PASS';'CFA-S3F-018'='PASS';'CFA-S3F-019'='FAIL';'CFA-S3F-020'='BLOCKED';'CFA-S3F-021'='PASS';'CFA-S3F-022'='PASS';'CFA-S3F-023'='UNVERIFIED';'CFA-S3F-024'='BLOCKED';'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'};semantic_review='UNVERIFIED';freeze_news_matching='BLOCKED'}
    Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
    Write-Host '';Write-Host 'CFA STAGE 3 V6 LOCAL-MARKET SHORT-SYMBOL CORRECTION: PASS';Write-Host("Parent V5 matches: {0}"-f$v5Matches.Count);Write-Host("V6 retained matches: {0}"-f$kept);Write-Host("V6 newly rejected short-symbol matches: {0}"-f$removed);Write-Host("Matched assets: {0} of 431"-f$matchedAssets.Count);Write-Host 'CFA-S3F-023 direct V6 semantic review: UNVERIFIED';Write-Host 'CFA-S3-006 freeze news matching: BLOCKED';Write-Host("V6 evidence directory: {0}"-f$OutputRoot);exit 0
}catch{Write-Host '';Write-Host 'CFA STAGE 3 V6 LOCAL-MARKET SHORT-SYMBOL CORRECTION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
