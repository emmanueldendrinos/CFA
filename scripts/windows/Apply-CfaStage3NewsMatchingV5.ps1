#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V2RunRoot,
    [Parameter(Mandatory=$true)][string]$ImpactRunRoot,
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
$ExpectedArchiveScanSha256 = '1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba'
$ExpectedFieldCount = 27
$RecordIdIndex = 0
$DateIndex = 1
$SourceIndex = 3
$DocumentIndex = 4
$ThemesIndex = 8
$PersonsIndex = 12
$OrganizationsIndex = 14
$AllNamesIndex = 23
$ExtrasIndex = 26

$MarketAnchorRegex = New-Object System.Text.RegularExpressions.Regex(
    '(?<![\p{L}\p{N}])(?:price|market\s+cap(?:italization|italisation)?|market\s+capitalization|market\s+capitalisation|volume|trading|trade|trades|exchange|token|coin|crypto|cryptocurrency)(?![\p{L}\p{N}])',
    ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
)

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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
function Row-Key {
    param([string]$Archive,[object]$Ordinal)
    return $Archive.Trim().ToLowerInvariant() + '|' + ([long]$Ordinal).ToString()
}
function Has-Reason {
    param([string]$Reasons,[string]$Reason)
    foreach ($part in @($Reasons -split '\|')) { if ($part.Trim() -eq $Reason) { return $true } }
    return $false
}
function Is-DefaultSymbolOnly {
    param([object]$AliasRow)
    return (([string]$AliasRow.alias_type) -eq 'kraken_base_symbol' -and ([string]$AliasRow.alias_source) -eq 'AF001_KRAKEN_SYMBOL')
}
function Parse-OffsetNames {
    param([string]$Text)
    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    foreach ($block in @($Text -split ';')) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $comma = $block.LastIndexOf(',')
        if ($comma -le 0 -or $comma -ge ($block.Length - 1)) { continue }
        $name = $block.Substring(0,$comma).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$items.Add($name) }
    }
    return @($items.ToArray())
}
function Get-PageTitle {
    param([string]$Extras)
    if ([string]::IsNullOrWhiteSpace($Extras)) { return '' }
    $m = [regex]::Match($Extras,'<PAGE_TITLE>(.*?)</PAGE_TITLE>',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return '' }
    return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}
function Test-TitleSymbolToken {
    param([string]$Title,[string]$Symbol)
    if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Symbol)) { return $false }
    $pattern = '(?<![\p{L}\p{N}_])' + [regex]::Escape($Symbol) + '(?![\p{L}\p{N}_])'
    return [regex]::IsMatch($Title,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
}
function Test-ParentheticalMarketTicker {
    param([string]$Title,[string]$Symbol)
    if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Symbol)) { return $false }
    $pattern = '\(\s*' + [regex]::Escape($Symbol) + '\s*\)'
    $ticker = [regex]::IsMatch($Title,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
    return ($ticker -and $MarketAnchorRegex.IsMatch($Title))
}
function Test-StructuredExact {
    param([object]$Raw,[string]$Symbol)
    foreach ($name in @($Raw.structured_names)) { if ([string]$name -ceq $Symbol) { return $true } }
    return $false
}

function Get-AliasTools {
    param([object[]]$Aliases)
    $byKey = @{}
    $assets = @{}
    foreach ($a in $Aliases) {
        $base = ([string]$a.base_asset_id).Trim()
        $text = ([string]$a.alias_text).Trim()
        if ([string]::IsNullOrWhiteSpace($base) -or [string]::IsNullOrWhiteSpace($text)) { throw 'Blank Stage 3 alias.' }
        if ($text.Contains('|')) { throw "Alias contains reserved pipe delimiter: $base / $text" }
        $key = Alias-Key $base $text
        if ($byKey.ContainsKey($key)) { throw "Duplicate Stage 3 alias key: $key" }
        $default = Is-DefaultSymbolOnly $a
        $byKey[$key] = [pscustomobject]@{
            base_asset_id = $base
            alias_text = $text
            default_symbol_only = $default
            short_default_symbol = ($default -and $text.Length -le 2)
            approved_nondefault = (-not $default)
        }
        $assets[$base] = $true
    }
    if ($assets.Count -ne 431) { throw "Alias registry covers $($assets.Count) assets; expected 431." }
    return [pscustomobject]@{byKey=$byKey;asset_count=$assets.Count;alias_count=$Aliases.Count}
}
function Get-MatchAliasMetadata {
    param([object]$Row,[object]$Tools)
    $base = ([string]$Row.base_asset_id).Trim()
    $short = New-Object System.Collections.ArrayList
    $approved = $false
    foreach ($textRaw in @(([string]$Row.matched_aliases) -split '\|')) {
        $text = $textRaw.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $key = Alias-Key $base $text
        if (-not $Tools.byKey.ContainsKey($key)) { throw "V2 match references alias absent from frozen registry: $base / $text" }
        $meta = $Tools.byKey[$key]
        if ([bool]$meta.short_default_symbol) { [void]$short.Add([string]$meta.alias_text) }
        if ([bool]$meta.approved_nondefault) { $approved = $true }
    }
    return [pscustomobject]@{short_aliases=@($short.ToArray());approved_nondefault=$approved}
}
function Classify-ShortMatch {
    param([object]$Row,[object]$AliasMeta,[object]$Raw)
    if (@($AliasMeta.short_aliases).Count -eq 0) {
        return [pscustomobject]@{keep=$true;reason='NOT_SHORT_DEFAULT';approved_nondefault=$false;title_valid=$false;structured_exact=$false;parenthetical_market=$false;short_aliases=@()}
    }
    if ([bool]$AliasMeta.approved_nondefault) {
        return [pscustomobject]@{keep=$true;reason='APPROVED_NONDEFAULT_SAME_RECORD';approved_nondefault=$true;title_valid=$false;structured_exact=$false;parenthetical_market=$false;short_aliases=@($AliasMeta.short_aliases)}
    }
    $titleCrypto = Has-Reason ([string]$Row.context_reasons) 'TITLE_CRYPTO'
    $anyTitle = $false
    $anyStructured = $false
    $anyParenthetical = $false
    foreach ($symbol in @($AliasMeta.short_aliases)) {
        if (Test-TitleSymbolToken ([string]$Raw.page_title) $symbol) { $anyTitle = $true }
        if (Test-StructuredExact $Raw $symbol) { $anyStructured = $true }
        if (Test-ParentheticalMarketTicker ([string]$Raw.page_title) $symbol) { $anyParenthetical = $true }
    }
    if ($anyParenthetical) {
        return [pscustomobject]@{keep=$true;reason='PAREN_TICKER_MARKET';approved_nondefault=$false;title_valid=$anyTitle;structured_exact=$anyStructured;parenthetical_market=$true;short_aliases=@($AliasMeta.short_aliases)}
    }
    if ($titleCrypto -and ($anyTitle -or $anyStructured)) {
        return [pscustomobject]@{keep=$true;reason='TITLE_CRYPTO_TOKEN_OR_STRUCTURED';approved_nondefault=$false;title_valid=$anyTitle;structured_exact=$anyStructured;parenthetical_market=$false;short_aliases=@($AliasMeta.short_aliases)}
    }
    return [pscustomobject]@{keep=$false;reason='SHORT_DEFAULT_REQUIRES_VALID_CONTEXT';approved_nondefault=$false;title_valid=$anyTitle;structured_exact=$anyStructured;parenthetical_market=$false;short_aliases=@($AliasMeta.short_aliases)}
}

function Assert-V2 {
    param([string]$Root,[string]$AliasPath)
    $summaryPath = Join-Path $Root 'stage3-match-summary.json'
    $matchesPath = Join-Path $Root 'stage3-news-matches.csv'
    $rejectsPath = Join-Path $Root 'stage3-context-rejects.csv'
    $samplesPath = Join-Path $Root 'stage3-match-samples.csv'
    foreach ($p in @($summaryPath,$matchesPath,$rejectsPath,$samplesPath)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Required V2 artifact missing: $p" } }
    $s = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ([string]$s.run_status -ne 'PASS' -or [string]$s.matching_contract -ne 'CANDIDATE_V2') { throw 'Parent V2 is not PASS CANDIDATE_V2.' }
    if ([int]$s.source.archive_files -ne $ExpectedArchives -or [long]$s.source.rows_scanned -ne $ExpectedRawRows -or [long]$s.source.malformed_field_count_rows -ne $ExpectedMalformedRows) { throw 'Parent V2 source shape mismatch.' }
    if ([long]$s.source.missing_critical_rows -ne 0) { throw 'Parent V2 missing-critical count is nonzero.' }
    if ([long]$s.matching.duplicate_asset_record_matches -ne 0) { throw 'Parent V2 duplicate asset/record count is nonzero.' }
    if ((Get-Sha $AliasPath) -ne $ExpectedAliasRegistrySha256 -or ([string]$s.output.alias_registry_sha256).ToLowerInvariant() -ne $ExpectedAliasRegistrySha256) { throw 'Frozen alias registry hash mismatch.' }
    if ((Get-Sha $matchesPath) -ne ([string]$s.output.matches_sha256).ToLowerInvariant()) { throw 'Parent V2 matches hash mismatch.' }
    if ((Get-Sha $rejectsPath) -ne ([string]$s.output.rejects_sha256).ToLowerInvariant()) { throw 'Parent V2 rejects hash mismatch.' }
    if ((Get-Sha $samplesPath) -ne ([string]$s.output.samples_sha256).ToLowerInvariant()) { throw 'Parent V2 samples hash mismatch.' }
    return [pscustomobject]@{summary=$s;summary_path=$summaryPath;matches=$matchesPath;rejects=$rejectsPath;samples=$samplesPath}
}
function Assert-Impact {
    param([string]$Root,[string]$V2Root)
    $summaryPath = Join-Path $Root 'stage3-critical-utf8-impact-summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { throw "Impact summary missing: $summaryPath" }
    $s = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ([string]$s.status -ne 'PASS' -or [string]$s.diagnostic -ne 'CRITICAL_UTF8_V2_IMPACT') { throw 'Impact diagnostic is not PASS.' }
    if ([string]$s.archive_scan_sha256 -ne $ExpectedArchiveScanSha256) { throw 'Impact archive-scan hash mismatch.' }
    if ([long]$s.critical_utf8_exclusion_rows -ne $ExpectedUtf8Exclusions -or [long]$s.known_malformed_rows -ne $ExpectedMalformedRows) { throw 'Impact diagnostic counts differ from frozen evidence.' }
    if ([long]$s.v2_match_overlap_rows -ne 0 -or [long]$s.v2_reject_overlap_rows -ne 0 -or [long]$s.v2_sample_overlap_rows -ne 0 -or [long]$s.v2_sample_ambiguous_identity_rows -ne 0) { throw 'UTF-8 exclusion overlap is no longer zero.' }
    $exclusions = [string]$s.outputs.exclusions_csv
    if (-not (Test-Path -LiteralPath $exclusions -PathType Leaf)) { throw 'Impact exclusion CSV missing.' }
    if ((Get-Sha $exclusions) -ne ([string]$s.outputs.exclusions_sha256).ToLowerInvariant()) { throw 'Impact exclusion hash mismatch.' }
    if ((Resolve-Path -LiteralPath ([string]$s.parent_v2_run)).ProviderPath -ne (Resolve-Path -LiteralPath $V2Root).ProviderPath) { throw 'Impact diagnostic parent V2 differs from requested V2.' }
    return [pscustomobject]@{summary=$s;summary_path=$summaryPath;exclusions=$exclusions}
}

function Invoke-SelfTest {
    $raw = [pscustomobject]@{page_title='Bitcoin developers debate OP_RETURN limits';structured_names=@()}
    $row = [pscustomobject]@{context_reasons='ECON_BITCOIN|TITLE_CRYPTO'}
    $meta = [pscustomobject]@{short_aliases=@('OP');approved_nondefault=$false}
    $c = Classify-ShortMatch $row $meta $raw
    if ([bool]$c.keep) { throw 'OP inside OP_RETURN must not survive.' }

    $raw = [pscustomobject]@{page_title='Arweave (AR) Reaches Market Capitalization Milestone';structured_names=@()}
    $row = [pscustomobject]@{context_reasons='ECON_BITCOIN'}
    $meta = [pscustomobject]@{short_aliases=@('AR');approved_nondefault=$false}
    $c = Classify-ShortMatch $row $meta $raw
    if (-not [bool]$c.keep -or [string]$c.reason -ne 'PAREN_TICKER_MARKET') { throw 'Arweave (AR) parenthetical market ticker must survive.' }

    $raw = [pscustomobject]@{page_title='Story (IP) Price Down 9.6% Over Last 7 Days';structured_names=@()}
    $row = [pscustomobject]@{context_reasons='ECON_BITCOIN'}
    $meta = [pscustomobject]@{short_aliases=@('IP');approved_nondefault=$false}
    $c = Classify-ShortMatch $row $meta $raw
    if (-not [bool]$c.keep -or [string]$c.reason -ne 'PAREN_TICKER_MARKET') { throw 'Story (IP) parenthetical price ticker must survive.' }

    $raw = [pscustomobject]@{page_title='North Korean Hackers Use Russian IP Infrastructure';structured_names=@()}
    $row = [pscustomobject]@{context_reasons='ECON_BITCOIN'}
    $meta = [pscustomobject]@{short_aliases=@('IP');approved_nondefault=$false}
    $c = Classify-ShortMatch $row $meta $raw
    if ([bool]$c.keep) { throw 'Generic IP infrastructure title must remain rejected.' }

    $raw = [pscustomobject]@{page_title='Why could OM rally despite weakness in the crypto market?';structured_names=@()}
    $row = [pscustomobject]@{context_reasons='TITLE_CRYPTO'}
    $meta = [pscustomobject]@{short_aliases=@('OM');approved_nondefault=$false}
    $c = Classify-ShortMatch $row $meta $raw
    if (-not [bool]$c.keep -or [string]$c.reason -ne 'TITLE_CRYPTO_TOKEN_OR_STRUCTURED') { throw 'OM with valid title token and crypto title must survive.' }

    $raw = [pscustomobject]@{page_title='Optimism Weekly Update (OP)';structured_names=@()}
    $row = [pscustomobject]@{context_reasons='ECON_BITCOIN'}
    $meta = [pscustomobject]@{short_aliases=@('OP');approved_nondefault=$true}
    $c = Classify-ShortMatch $row $meta $raw
    if (-not [bool]$c.keep -or [string]$c.reason -ne 'APPROVED_NONDEFAULT_SAME_RECORD') { throw 'Approved non-default support must survive.' }

    Write-Host 'SELF-TEST: PASS'
}
if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $Stage3V2RunRoot = (Resolve-Path -LiteralPath $Stage3V2RunRoot).ProviderPath
    $ImpactRunRoot = (Resolve-Path -LiteralPath $ImpactRunRoot).ProviderPath
    if (Test-Path -LiteralPath $OutputRoot) {
        if (@(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw "OutputRoot must be empty: $OutputRoot" }
    }
    else { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if (-not (Test-Path -LiteralPath $aliasPath -PathType Leaf)) { throw 'Frozen Stage 3 alias registry missing.' }
    $aliases = @(Import-Csv -LiteralPath $aliasPath)
    $tools = Get-AliasTools $aliases
    $v2 = Assert-V2 $Stage3V2RunRoot $aliasPath
    $impact = Assert-Impact $ImpactRunRoot $Stage3V2RunRoot

    $exclusionSet = @{}
    foreach ($e in @(Import-Csv -LiteralPath $impact.exclusions)) {
        $key = Row-Key ([string]$e.archive_file) $e.row_ordinal
        if ($exclusionSet.ContainsKey($key)) { throw "Duplicate UTF-8 exclusion key: $key" }
        $exclusionSet[$key] = $true
    }
    if ($exclusionSet.Count -ne $ExpectedUtf8Exclusions) { throw 'UTF-8 exclusion manifest cardinality mismatch.' }

    $v2Matches = @(Import-Csv -LiteralPath $v2.matches)
    $targetByArchive = @{}
    $aliasMetaByMatch = @{}
    $matchRowByKey = @{}
    $seenAssetRecord = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($r in $v2Matches) {
        $assetRecord = ([string]$r.base_asset_id) + '|' + ([string]$r.record_id)
        if (-not $seenAssetRecord.Add($assetRecord)) { throw "Duplicate parent V2 asset/record match: $assetRecord" }
        $matchRowByKey[$assetRecord] = $r
        $meta = Get-MatchAliasMetadata $r $tools
        $aliasMetaByMatch[$assetRecord] = $meta
        $rowKey = Row-Key ([string]$r.archive_file) $r.row_ordinal
        if ($exclusionSet.ContainsKey($rowKey)) { throw "V2 match unexpectedly overlaps frozen UTF-8 exclusion: $rowKey" }
        if (@($meta.short_aliases).Count -gt 0) {
            $archive = ([string]$r.archive_file).Trim()
            if (-not $targetByArchive.ContainsKey($archive)) { $targetByArchive[$archive] = @{} }
            $ordinal = [long]$r.row_ordinal
            if (-not $targetByArchive[$archive].ContainsKey($ordinal)) { $targetByArchive[$archive][$ordinal] = $true }
        }
    }
    if ($v2Matches.Count -ne [long]$v2.summary.matching.unique_asset_record_matches) { throw 'Parent V2 match row count differs from summary.' }

    $files = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip')) {
        if ($file.Name -match '^\d{14}\.gkg\.csv\.zip$') {
            if ($files.ContainsKey($file.Name)) { throw "Duplicate raw archive filename: $($file.Name)" }
            $files[$file.Name] = $file.FullName
        }
    }
    if ($files.Count -ne $ExpectedArchives) { throw "Current source has $($files.Count) archives; expected $ExpectedArchives." }

    $rawByRowKey = @{}
    $lenient = New-Object Text.UTF8Encoding($false,$false)
    $archiveOrdinal = 0
    foreach ($archive in @($targetByArchive.Keys | Sort-Object)) {
        $archiveOrdinal++
        if (-not $files.ContainsKey($archive)) { throw "Target raw archive missing: $archive" }
        if ($archiveOrdinal -eq 1 -or ($archiveOrdinal % 100) -eq 0) { Write-Host ("V5 short-symbol raw-title archives: {0}/{1}" -f $archiveOrdinal,$targetByArchive.Count) }
        $targets = $targetByArchive[$archive]
        $maxTarget = [long](@($targets.Keys | Measure-Object -Maximum).Maximum)
        $zip = $null
        try {
            $zip = [IO.Compression.ZipFile]::OpenRead([string]$files[$archive])
            $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
            if ($entries.Count -ne 1) { throw "Expected one data entry in $archive; observed $($entries.Count)." }
            $stream = $entries[0].Open()
            $reader = New-Object IO.StreamReader -ArgumentList $stream,$lenient,$false,65536,$false
            try {
                [long]$rowOrdinal = 0
                while (($line = $reader.ReadLine()) -ne $null) {
                    $rowOrdinal++
                    if ($rowOrdinal -gt $maxTarget) { break }
                    if (-not $targets.ContainsKey($rowOrdinal)) { continue }
                    $fields = $line.Split([char]9)
                    if ($fields.Count -ne $ExpectedFieldCount) { throw "Targeted V2 match points to malformed raw row: $archive / $rowOrdinal" }
                    $names = New-Object System.Collections.ArrayList
                    foreach ($idx in @($AllNamesIndex,$PersonsIndex,$OrganizationsIndex)) {
                        foreach ($name in @(Parse-OffsetNames ([string]$fields[$idx]))) { [void]$names.Add($name) }
                    }
                    $key = Row-Key $archive $rowOrdinal
                    $rawByRowKey[$key] = [pscustomobject]@{
                        page_title = Get-PageTitle ([string]$fields[$ExtrasIndex])
                        structured_names = @($names.ToArray())
                    }
                }
            }
            finally { $reader.Dispose() }
        }
        finally { if ($null -ne $zip) { $zip.Dispose() } }
    }

    $expectedTargetRows = 0
    foreach ($archive in $targetByArchive.Keys) { $expectedTargetRows += $targetByArchive[$archive].Count }
    if ($rawByRowKey.Count -ne $expectedTargetRows) { throw "Target raw-row recovery incomplete: expected $expectedTargetRows, observed $($rawByRowKey.Count)." }

    $matchOut = Join-Path $OutputRoot 'stage3-news-matches.csv'
    $shortRejectOut = Join-Path $OutputRoot 'stage3-v5-short-symbol-rejects.csv'
    $sampleOut = Join-Path $OutputRoot 'stage3-match-samples.csv'
    $utf8 = New-Object Text.UTF8Encoding($false)
    $mw = New-Object IO.StreamWriter -ArgumentList $matchOut,$false,$utf8
    $rw = New-Object IO.StreamWriter -ArgumentList $shortRejectOut,$false,$utf8
    Write-CsvRow $mw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons')
    Write-CsvRow $rw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons','short_default_aliases','v5_filter_reason','page_title')

    $classByAssetRecord = @{}
    $matchedAssets = New-Object 'Collections.Generic.HashSet[string]'
    [long]$kept = 0
    [long]$removed = 0
    try {
        foreach ($r in $v2Matches) {
            $assetRecord = ([string]$r.base_asset_id) + '|' + ([string]$r.record_id)
            $meta = $aliasMetaByMatch[$assetRecord]
            if (@($meta.short_aliases).Count -eq 0) {
                $class = [pscustomobject]@{keep=$true;reason='NOT_SHORT_DEFAULT';approved_nondefault=$false;title_valid=$false;structured_exact=$false;parenthetical_market=$false;short_aliases=@()}
            }
            else {
                $rowKey = Row-Key ([string]$r.archive_file) $r.row_ordinal
                if (-not $rawByRowKey.ContainsKey($rowKey)) { throw "Missing targeted raw row for short-symbol match: $rowKey" }
                $class = Classify-ShortMatch $r $meta $rawByRowKey[$rowKey]
            }
            $classByAssetRecord[$assetRecord] = $class
            if ([bool]$class.keep) {
                Write-CsvRow $mw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons)
                [void]$matchedAssets.Add([string]$r.base_asset_id)
                $kept++
            }
            else {
                $rowKey = Row-Key ([string]$r.archive_file) $r.row_ordinal
                Write-CsvRow $rw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons,(@($class.short_aliases)-join'|'),$class.reason,[string]$rawByRowKey[$rowKey].page_title)
                $removed++
            }
        }
    }
    finally { $mw.Dispose(); $rw.Dispose() }
    if (($kept + $removed) -ne $v2Matches.Count) { throw 'V5 match accounting does not reconcile.' }

    $sampleRows = New-Object System.Collections.ArrayList
    foreach ($s in @(Import-Csv -LiteralPath $v2.samples)) {
        $v2Status = ([string]$s.match_status).Trim()
        $base = ([string]$s.base_asset_id).Trim()
        $alias = ([string]$s.alias_text).Trim()
        $aliasKey = Alias-Key $base $alias
        if (-not $tools.byKey.ContainsKey($aliasKey)) { throw "V2 sample references unknown alias: $base / $alias" }
        $aliasInfo = $tools.byKey[$aliasKey]
        $short = [bool]$aliasInfo.short_default_symbol
        $approved = $false
        $titleValid = $false
        $structuredExact = $false
        $parenthetical = $false
        $v5Status = $v2Status
        $reason = ''
        if ($v2Status -eq 'MATCH') {
            $assetRecord = $base + '|' + ([string]$s.record_id).Trim()
            if (-not $classByAssetRecord.ContainsKey($assetRecord)) { throw "V2 MATCH sample has no parent match classification: $assetRecord" }
            if ($short) {
                $fullClass = $classByAssetRecord[$assetRecord]
                $approved = [bool]$fullClass.approved_nondefault
                $titleValid = Test-TitleSymbolToken ([string]$s.page_title) $alias
                $structuredExact = (([string]$s.matched_surfaces) -match '(^|\|)(ALLNAMES|V2PERSONS|V2ORGANIZATIONS)(\||$)')
                $parenthetical = Test-ParentheticalMarketTicker ([string]$s.page_title) $alias
                $titleCrypto = Parse-Bool $s.title_crypto_anchor "sample $assetRecord title_crypto_anchor"
                if ($approved) { $reason = 'APPROVED_NONDEFAULT_SAME_RECORD' }
                elseif ($parenthetical) { $reason = 'PAREN_TICKER_MARKET' }
                elseif ($titleCrypto -and ($titleValid -or $structuredExact)) { $reason = 'TITLE_CRYPTO_TOKEN_OR_STRUCTURED' }
                else { $v5Status = 'REJECT_V5_SHORT_SYMBOL_CONTEXT'; $reason = 'SHORT_DEFAULT_REQUIRES_VALID_CONTEXT' }
            }
            else { $reason = 'NOT_SHORT_DEFAULT' }
        }
        elseif ($v2Status -eq 'REJECT_CONTEXT') { $reason = 'V2_CONTEXT_REJECT' }
        else { throw "Unexpected V2 sample status: $v2Status" }

        [void]$sampleRows.Add([pscustomobject][ordered]@{
            v5_match_status=$v5Status
            v5_filter_reason=$reason
            v2_match_status=$v2Status
            v5_short_default_symbol=$short
            v5_approved_nondefault_same_record=$approved
            v5_title_symbol_valid=$titleValid
            v5_structured_symbol_exact=$structuredExact
            v5_parenthetical_market_ticker=$parenthetical
            base_asset_id=$base
            alias_text=$alias
            requires_crypto_context=[string]$s.requires_crypto_context
            record_id=[string]$s.record_id
            gdelt_date_utc=[string]$s.gdelt_date_utc
            source_common_name=[string]$s.source_common_name
            document_identifier=[string]$s.document_identifier
            page_title=[string]$s.page_title
            matched_surfaces=[string]$s.matched_surfaces
            econ_bitcoin_theme=[string]$s.econ_bitcoin_theme
            title_crypto_anchor=[string]$s.title_crypto_anchor
            context_reason=[string]$s.context_reason
        })
    }
    @($sampleRows.ToArray()) | Export-Csv -LiteralPath $sampleOut -NoTypeInformation -Encoding UTF8

    $opReturn = @($sampleRows | Where-Object { $_.base_asset_id -eq 'OP' -and $_.alias_text -ceq 'OP' -and $_.page_title -match 'OP_RETURN' })
    if ($opReturn.Count -eq 0 -or @($opReturn | Where-Object v5_match_status -eq 'REJECT_V5_SHORT_SYMBOL_CONTEXT').Count -ne $opReturn.Count) { throw 'OP_RETURN regression case was not rejected by V5.' }
    $ar = @($sampleRows | Where-Object { $_.base_asset_id -eq 'AR' -and $_.alias_text -ceq 'AR' -and $_.page_title -match 'Arweave \(AR\)' -and $_.v5_match_status -eq 'MATCH' -and $_.v5_filter_reason -eq 'PAREN_TICKER_MARKET' })
    if ($ar.Count -eq 0) { throw 'Arweave (AR) parenthetical market regression case was not retained by V5.' }
    $ip = @($sampleRows | Where-Object { $_.base_asset_id -eq 'IP' -and $_.alias_text -ceq 'IP' -and $_.page_title -match 'Story \(IP\)' -and $_.v5_match_status -eq 'MATCH' -and $_.v5_filter_reason -eq 'PAREN_TICKER_MARKET' })
    if ($ip.Count -eq 0) { throw 'Story (IP) parenthetical price regression case was not retained by V5.' }
    $badIp = @($sampleRows | Where-Object { $_.base_asset_id -eq 'IP' -and $_.alias_text -ceq 'IP' -and $_.page_title -match 'IP Infrastructure' -and $_.v5_match_status -eq 'REJECT_V5_SHORT_SYMBOL_CONTEXT' })
    if ($badIp.Count -eq 0) { throw 'IP Infrastructure false-positive regression case is absent or not rejected in V5.' }

    $summaryPath = Join-Path $OutputRoot 'stage3-match-summary.json'
    $summary = [ordered]@{
        run_status='PASS'
        implementation='v5-short-default-targeted-raw-title-refinement'
        matching_contract='CANDIDATE_V5'
        rule='Short default symbols use underscore-aware title boundaries; retain on approved non-default same-record support, TITLE_CRYPTO plus valid title/structured symbol evidence, or exact parenthetical ticker plus market anchor; otherwise reject.'
        source=[ordered]@{raw_rows=$ExpectedRawRows;malformed_rows_excluded=$ExpectedMalformedRows;utf8_rows_excluded=$ExpectedUtf8Exclusions;eligible_rows=$ExpectedEligibleRows;archive_files=$ExpectedArchives}
        parent_v2=[ordered]@{run_root=$Stage3V2RunRoot;summary_sha256=(Get-Sha $v2.summary_path);matches_sha256=(Get-Sha $v2.matches);rejects_sha256=(Get-Sha $v2.rejects);samples_sha256=(Get-Sha $v2.samples)}
        utf8_impact=[ordered]@{run_root=$ImpactRunRoot;summary_sha256=(Get-Sha $impact.summary_path);exclusions_sha256=(Get-Sha $impact.exclusions);overlap_matches=0;overlap_rejects=0;overlap_samples=0}
        matching=[ordered]@{parent_asset_record_matches=$v2Matches.Count;retained_asset_record_matches=$kept;removed_v5_short_symbol_matches=$removed;matched_assets=$matchedAssets.Count;duplicate_asset_record_matches=0;targeted_raw_rows=$rawByRowKey.Count;targeted_raw_archives=$targetByArchive.Count}
        output=[ordered]@{matches_path=$matchOut;matches_sha256=(Get-Sha $matchOut);short_rejects_path=$shortRejectOut;short_rejects_sha256=(Get-Sha $shortRejectOut);samples_path=$sampleOut;samples_sha256=(Get-Sha $sampleOut);parent_context_rejects_path=$v2.rejects;parent_context_rejects_sha256=(Get-Sha $v2.rejects);alias_registry_sha256=(Get-Sha $aliasPath)}
        gates=[ordered]@{'CFA-S3F-008'='FAIL';'CFA-S3F-011'='PASS';'CFA-S3F-012'='PASS';'CFA-S3F-014'='FAIL';'CFA-S3F-016'='PASS';'CFA-S3F-017'='PASS';'CFA-S3F-018'='PASS';'CFA-S3F-019'='UNVERIFIED';'CFA-S3F-020'='BLOCKED';'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'}
        semantic_review='UNVERIFIED'
        freeze_news_matching='BLOCKED'
    }
    Write-Utf8NoBom $summaryPath (($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 3 V5 SHORT-SYMBOL REFINEMENT: PASS'
    Write-Host ("Targeted raw archives: {0}" -f $targetByArchive.Count)
    Write-Host ("Targeted raw rows: {0}" -f $rawByRowKey.Count)
    Write-Host ("Parent V2 matches: {0}" -f $v2Matches.Count)
    Write-Host ("V5 retained matches: {0}" -f $kept)
    Write-Host ("V5 short-symbol rejected matches: {0}" -f $removed)
    Write-Host ("Matched assets: {0} of 431" -f $matchedAssets.Count)
    Write-Host 'CFA-S3F-019 direct semantic review: UNVERIFIED'
    Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
    Write-Host ("V5 evidence directory: {0}" -f $OutputRoot)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V5 SHORT-SYMBOL REFINEMENT: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
