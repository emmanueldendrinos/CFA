#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V2RunRoot,
    [string]$RepoRoot = '',
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedArchives = 7163
$ExpectedRows = 9183757L
$ExpectedMalformedRows = 5L
$ExpectedAliasRegistrySha256 = '11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Csv {
    param([object]$Value)
    $s = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($s.Contains('"')) { $s = $s.Replace('"','""') }
    if ($s.Contains(',') -or $s.Contains('"') -or $s.Contains("`r") -or $s.Contains("`n")) { return '"' + $s + '"' }
    return $s
}
function Write-CsvRow {
    param([IO.StreamWriter]$Writer,[object[]]$Values)
    $Writer.WriteLine((@($Values | ForEach-Object { Csv $_ }) -join ','))
}
function Parse-Bool {
    param([object]$Value,[string]$Label)
    $x = ([string]$Value).Trim().ToLowerInvariant()
    if ($x -eq 'true') { return $true }
    if ($x -eq 'false') { return $false }
    throw "Malformed boolean in ${Label}: '$Value'"
}
function Alias-Key {
    param([string]$Base,[string]$Alias)
    return $Base.Trim() + '|' + $Alias.Trim().ToLowerInvariant()
}
function Is-DefaultSymbolOnly {
    param([object]$AliasRow)
    return (([string]$AliasRow.alias_type) -eq 'kraken_base_symbol' -and ([string]$AliasRow.alias_source) -eq 'AF001_KRAKEN_SYMBOL')
}
function Test-TitleCryptoReason {
    param([string]$ContextReasons)
    foreach ($part in @($ContextReasons -split '\|')) { if ($part.Trim() -eq 'TITLE_CRYPTO') { return $true } }
    return $false
}
function Get-FileSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-ParentV2 {
    param([string]$RunRoot,[string]$AliasPath)
    $summaryPath = Join-Path $RunRoot 'stage3-match-summary.json'
    $matchPath = Join-Path $RunRoot 'stage3-news-matches.csv'
    $rejectPath = Join-Path $RunRoot 'stage3-context-rejects.csv'
    $samplePath = Join-Path $RunRoot 'stage3-match-samples.csv'
    foreach ($path in @($summaryPath,$matchPath,$rejectPath,$samplePath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required V2 artifact missing: $path" } }
    $s = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ([string]$s.run_status -ne 'PASS') { throw 'Parent V2 run_status is not PASS.' }
    if ([string]$s.matching_contract -ne 'CANDIDATE_V2') { throw "Parent matching_contract is '$($s.matching_contract)', expected CANDIDATE_V2." }
    if ([int]$s.source.archive_files -ne $ExpectedArchives) { throw 'Parent V2 archive count differs from frozen Stage 3 source.' }
    if ([long]$s.source.rows_scanned -ne $ExpectedRows) { throw 'Parent V2 row count differs from corrected Stage 3 source.' }
    if ([long]$s.source.malformed_field_count_rows -ne $ExpectedMalformedRows) { throw 'Parent V2 malformed row count differs from corrected Stage 3 source.' }
    if ([long]$s.source.missing_critical_rows -ne 0) { throw 'Parent V2 contains missing critical rows.' }
    if ([long]$s.matching.duplicate_asset_record_matches -ne 0) { throw 'Parent V2 contains duplicate asset/record matches.' }
    if ([string]$s.output.alias_registry_sha256 -ne $ExpectedAliasRegistrySha256) { throw 'Parent V2 alias registry hash differs from frozen registry.' }
    if ((Get-FileSha $AliasPath) -ne $ExpectedAliasRegistrySha256) { throw 'Current Stage 3 alias registry hash differs from frozen registry.' }
    if ((Get-FileSha $matchPath) -ne ([string]$s.output.matches_sha256).ToLowerInvariant()) { throw 'Parent V2 matches hash mismatch.' }
    if ((Get-FileSha $rejectPath) -ne ([string]$s.output.rejects_sha256).ToLowerInvariant()) { throw 'Parent V2 rejects hash mismatch.' }
    if ((Get-FileSha $samplePath) -ne ([string]$s.output.samples_sha256).ToLowerInvariant()) { throw 'Parent V2 samples hash mismatch.' }
    return [pscustomobject]@{summary=$s;summary_path=$summaryPath;match_path=$matchPath;reject_path=$rejectPath;sample_path=$samplePath}
}
function Get-AliasTools {
    param([object[]]$Aliases)
    $byKey=@{};$short=@{};$assets=@{}
    foreach ($a in $Aliases) {
        $base=([string]$a.base_asset_id).Trim();$text=([string]$a.alias_text).Trim();$key=Alias-Key $base $text
        if ([string]::IsNullOrWhiteSpace($base) -or [string]::IsNullOrWhiteSpace($text)) { throw 'Blank base_asset_id or alias_text in Stage 3 alias registry.' }
        if ($text.Contains('|')) { throw "Stage 3 alias contains reserved pipe delimiter: $base / $text" }
        if ($byKey.ContainsKey($key)) { throw "Duplicate Stage 3 alias key: $key" }
        $isDefault=Is-DefaultSymbolOnly $a;$isShort=($isDefault -and $text.Length -le 2)
        $meta=[pscustomobject]@{base_asset_id=$base;alias_text=$text;default_symbol_only=$isDefault;short_default_symbol=$isShort;approved_nondefault=(-not $isDefault)}
        $byKey[$key]=$meta;if($isShort){$short[$key]=$true};$assets[$base]=$true
    }
    if ($assets.Count -ne 431) { throw "Stage 3 alias registry covers $($assets.Count) assets; expected 431." }
    return [pscustomobject]@{byKey=$byKey;short=$short;asset_count=$assets.Count;alias_count=$Aliases.Count}
}
function Classify-MatchRow {
    param([object]$Row,[object]$Tools)
    $base=([string]$Row.base_asset_id).Trim();$aliasTexts=@(([string]$Row.matched_aliases -split '\|') | ForEach-Object {$_.Trim()} | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if ($aliasTexts.Count -eq 0) { throw "V2 match $base/$($Row.record_id) has no matched aliases." }
    $shortAliases=New-Object System.Collections.ArrayList;$approvedNondefault=$false
    foreach ($text in $aliasTexts) {
        $key=Alias-Key $base $text
        if (-not $Tools.byKey.ContainsKey($key)) { throw "V2 match references alias absent from frozen registry: $base / $text" }
        $meta=$Tools.byKey[$key]
        if ([bool]$meta.short_default_symbol) { [void]$shortAliases.Add([string]$meta.alias_text) }
        if ([bool]$meta.approved_nondefault) { $approvedNondefault=$true }
    }
    $titleCrypto=Test-TitleCryptoReason ([string]$Row.context_reasons)
    $drop=($shortAliases.Count -gt 0 -and -not $approvedNondefault -and -not $titleCrypto)
    $reason=if($drop){'SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO'}elseif($shortAliases.Count-eq0){'NOT_SHORT_DEFAULT'}elseif($approvedNondefault){'APPROVED_NONDEFAULT_SAME_RECORD'}else{'TITLE_CRYPTO'}
    return [pscustomobject]@{drop=$drop;reason=$reason;short_aliases=@($shortAliases.ToArray());approved_nondefault=$approvedNondefault;title_crypto=$titleCrypto}
}
function Invoke-Transform {
    param([string]$RunRoot,[string]$Repo,[string]$OutRoot)
    $aliasPath=Join-Path $Repo 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if (-not (Test-Path -LiteralPath $aliasPath -PathType Leaf)) { throw 'Frozen Stage 3 alias registry is missing.' }
    $aliases=@(Import-Csv -LiteralPath $aliasPath);$tools=Get-AliasTools $aliases
    $parent=Assert-ParentV2 $RunRoot $aliasPath
    if (Test-Path -LiteralPath $OutRoot) {
        if (@(Get-ChildItem -LiteralPath $OutRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw "OutputRoot must be empty: $OutRoot" }
    } else { New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null }
    $OutRoot=(Resolve-Path -LiteralPath $OutRoot).ProviderPath

    $matchOut=Join-Path $OutRoot 'stage3-news-matches.csv';$newRejectOut=Join-Path $OutRoot 'stage3-v3-short-symbol-rejects.csv';$sampleOut=Join-Path $OutRoot 'stage3-match-samples.csv'
    $utf8=New-Object Text.UTF8Encoding($false);$mw=New-Object IO.StreamWriter -ArgumentList $matchOut,$false,$utf8;$rw=New-Object IO.StreamWriter -ArgumentList $newRejectOut,$false,$utf8
    Write-CsvRow $mw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons')
    Write-CsvRow $rw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons','short_default_aliases','v3_filter_reason')
    $matchLookup=@{};$seen=New-Object 'Collections.Generic.HashSet[string]';$matchedAssets=New-Object 'Collections.Generic.HashSet[string]';[long]$parentRows=0;[long]$kept=0;[long]$removed=0
    try {
        foreach($r in @(Import-Csv -LiteralPath $parent.match_path)) {
            $parentRows++;$base=[string]$r.base_asset_id;$record=[string]$r.record_id;$key=$base+'|'+$record
            if (-not $seen.Add($key)) { throw "Duplicate parent V2 asset/record match: $key" }
            $c=Classify-MatchRow $r $tools;$matchLookup[$key]=[pscustomobject]@{classification=$c;row=$r}
            if([bool]$c.drop){Write-CsvRow $rw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons,(@($c.short_aliases)-join'|'),$c.reason);$removed++}
            else{Write-CsvRow $mw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons);[void]$matchedAssets.Add($base);$kept++}
        }
    } finally { $mw.Dispose();$rw.Dispose() }
    if ($parentRows -ne [long]$parent.summary.matching.unique_asset_record_matches) { throw 'Parent V2 match CSV row count differs from parent summary.' }
    if ($parentRows -ne ($kept+$removed)) { throw 'V3 match accounting does not reconcile.' }

    $sampleRows=New-Object System.Collections.ArrayList
    foreach($r in @(Import-Csv -LiteralPath $parent.sample_path)) {
        $v2Status=([string]$r.match_status).Trim();$base=([string]$r.base_asset_id).Trim();$alias=([string]$r.alias_text).Trim();$aliasKey=Alias-Key $base $alias
        if (-not $tools.byKey.ContainsKey($aliasKey)) { throw "V2 sample references unknown alias: $base / $alias" }
        $meta=$tools.byKey[$aliasKey];$fullKey=$base+'|'+([string]$r.record_id).Trim();$approvedSame=$false;$v3Status=$v2Status;$filterReason='V2_UNCHANGED'
        if($v2Status-eq'MATCH'){
            if(-not$matchLookup.ContainsKey($fullKey)){throw "V2 MATCH sample has no parent asset/record match: $fullKey"}
            $class=$matchLookup[$fullKey].classification;$approvedSame=[bool]$class.approved_nondefault
            if([bool]$meta.short_default_symbol -and [bool]$class.drop){$v3Status='REJECT_V3_SHORT_SYMBOL_TITLE_CONTEXT';$filterReason='SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO'}
            elseif([bool]$meta.short_default_symbol -and$approvedSame){$filterReason='APPROVED_NONDEFAULT_SAME_RECORD'}
            elseif([bool]$meta.short_default_symbol){$filterReason='TITLE_CRYPTO'}
            else{$filterReason='NOT_SHORT_DEFAULT'}
        } elseif($v2Status-eq'REJECT_CONTEXT'){$filterReason='V2_CONTEXT_REJECT'} else { throw "Unexpected V2 sample status: $v2Status" }
        [void]$sampleRows.Add([pscustomobject][ordered]@{v3_match_status=$v3Status;v3_filter_reason=$filterReason;v2_match_status=$v2Status;v3_short_default_symbol=[bool]$meta.short_default_symbol;v3_approved_nondefault_same_record=$approvedSame;base_asset_id=$base;alias_text=$alias;requires_crypto_context=[string]$r.requires_crypto_context;record_id=[string]$r.record_id;gdelt_date_utc=[string]$r.gdelt_date_utc;source_common_name=[string]$r.source_common_name;document_identifier=[string]$r.document_identifier;page_title=[string]$r.page_title;matched_surfaces=[string]$r.matched_surfaces;econ_bitcoin_theme=[string]$r.econ_bitcoin_theme;title_crypto_anchor=[string]$r.title_crypto_anchor;context_reason=[string]$r.context_reason})
    }
    @($sampleRows.ToArray()) | Export-Csv -LiteralPath $sampleOut -NoTypeInformation -Encoding UTF8

    $newRejectSamples=@($sampleRows | Where-Object v3_match_status -eq 'REJECT_V3_SHORT_SYMBOL_TITLE_CONTEXT')
    $ipRegression=@($newRejectSamples | Where-Object { $_.base_asset_id -eq 'IP' -and $_.alias_text -ceq 'IP' -and $_.page_title -match 'IP Infrastructure' })
    if ($ipRegression.Count -eq 0) { throw 'Observed V2 IP/Internet Protocol regression case was not rejected in V3 samples.' }
    $omRetention=@($sampleRows | Where-Object { $_.base_asset_id -eq 'OM' -and $_.alias_text -ceq 'OM' -and $_.v3_match_status -eq 'MATCH' -and (Parse-Bool $_.title_crypto_anchor 'OM title_crypto_anchor') })
    if ($omRetention.Count -eq 0) { throw 'Reviewed OM title-crypto retention case is absent from V3 samples.' }

    $summaryPath=Join-Path $OutRoot 'stage3-match-summary.json';$summary=[ordered]@{
        run_status='PASS';implementation='v3-short-default-symbol-postfilter';matching_contract='CANDIDATE_V3';rule='Default Kraken symbol-only aliases of length 1-2 may not survive ECON_BITCOIN alone; require TITLE_CRYPTO unless an independently approved non-default alias for the same asset also matched the record.'
        gates=[ordered]@{'CFA-S3F-001'='PASS';'CFA-S3F-002'='PASS';'CFA-S3F-003'='PASS';'CFA-S3F-004'='PASS';'CFA-S3F-005'='PASS';'CFA-S3F-006'='PASS';'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'}
        source=[ordered]@{archive_files=$ExpectedArchives;rows_scanned=$ExpectedRows;malformed_field_count_rows=$ExpectedMalformedRows;missing_critical_rows=0;source_validation='INHERITED_FROM_HASH_VERIFIED_PARENT_V2'}
        parent_v2=[ordered]@{run_root=$RunRoot;summary_sha256=(Get-FileSha $parent.summary_path);matches_sha256=(Get-FileSha $parent.match_path);rejects_sha256=(Get-FileSha $parent.reject_path);samples_sha256=(Get-FileSha $parent.sample_path);unique_asset_record_matches=$parentRows}
        matching=[ordered]@{news_assets=431;alias_rows=$tools.alias_count;parent_asset_record_matches=$parentRows;removed_v3_short_symbol_matches=$removed;unique_asset_record_matches=$kept;matched_assets=$matchedAssets.Count;duplicate_asset_record_matches=0;v3_short_symbol_sample_rejects=$newRejectSamples.Count}
        output=[ordered]@{matches_path=$matchOut;matches_sha256=(Get-FileSha $matchOut);new_rejects_path=$newRejectOut;new_rejects_sha256=(Get-FileSha $newRejectOut);samples_path=$sampleOut;samples_sha256=(Get-FileSha $sampleOut);parent_context_rejects_path=$parent.reject_path;parent_context_rejects_sha256=(Get-FileSha $parent.reject_path);alias_registry_sha256=(Get-FileSha $aliasPath)}
        semantic_review='UNVERIFIED';freeze_news_matching='BLOCKED'
    }
    Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
    Write-Host ''
    Write-Host 'CFA STAGE 3 V3 SHORT-SYMBOL POST-FILTER: PASS'
    Write-Host ("Parent V2 matches: {0}" -f $parentRows)
    Write-Host ("V3 retained matches: {0}" -f $kept)
    Write-Host ("V3 newly rejected matches: {0}" -f $removed)
    Write-Host ("Matched assets: {0} of 431" -f $matchedAssets.Count)
    Write-Host 'CFA-S3-005 bounded semantic review: UNVERIFIED'
    Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
    Write-Host ("V3 evidence directory: {0}" -f $OutRoot)
    return $OutRoot
}
function Invoke-SelfTest {
    $aliases=@(
        [pscustomobject]@{base_asset_id='IP';alias_text='IP';alias_type='kraken_base_symbol';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='OM';alias_text='OM';alias_type='kraken_base_symbol';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='ABC';alias_text='ABC';alias_type='kraken_base_symbol';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='IP';alias_text='Story Protocol';alias_type='manual_core_name';alias_source='AF003_APPROVED_ALIAS'}
    )
    $byKey=@{};$short=@{};$assets=@{};foreach($a in $aliases){$key=Alias-Key $a.base_asset_id $a.alias_text;$d=Is-DefaultSymbolOnly $a;$byKey[$key]=[pscustomobject]@{base_asset_id=$a.base_asset_id;alias_text=$a.alias_text;default_symbol_only=$d;short_default_symbol=($d-and([string]$a.alias_text).Length-le2);approved_nondefault=(-not$d)}}
    $tools=[pscustomobject]@{byKey=$byKey;short=$short;asset_count=3;alias_count=4}
    $ip=[pscustomobject]@{base_asset_id='IP';record_id='1';matched_aliases='IP';context_reasons='ECON_BITCOIN'};$c=Classify-MatchRow $ip $tools;if(-not$c.drop){throw 'IP ECON-only short default must be rejected.'}
    $om=[pscustomobject]@{base_asset_id='OM';record_id='2';matched_aliases='OM';context_reasons='ECON_BITCOIN|TITLE_CRYPTO'};$c=Classify-MatchRow $om $tools;if($c.drop){throw 'OM with TITLE_CRYPTO must survive.'}
    $approved=[pscustomobject]@{base_asset_id='IP';record_id='3';matched_aliases='IP|Story Protocol';context_reasons='ECON_BITCOIN|NOT_REQUIRED'};$c=Classify-MatchRow $approved $tools;if($c.drop-or-not$c.approved_nondefault){throw 'Approved non-default co-match must survive.'}
    $long=[pscustomobject]@{base_asset_id='ABC';record_id='4';matched_aliases='ABC';context_reasons='ECON_BITCOIN'};$c=Classify-MatchRow $long $tools;if($c.drop){throw 'Three-character default symbol must be unchanged.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}
try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$Stage3V2RunRoot=(Resolve-Path -LiteralPath $Stage3V2RunRoot).ProviderPath
    [void](Invoke-Transform $Stage3V2RunRoot $RepoRoot $OutputRoot);exit 0
}catch{Write-Host '';Write-Host 'CFA STAGE 3 V3 SHORT-SYMBOL POST-FILTER: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
