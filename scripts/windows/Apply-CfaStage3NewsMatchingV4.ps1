#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V2RunRoot,
    [Parameter(Mandatory=$true)][string]$Stage3V3RunRoot,
    [Parameter(Mandatory=$true)][string]$ImpactRunRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedArchives = 7163
$ExpectedRows = 9183757L
$ExpectedMalformedRows = 5L
$ExpectedCriticalInvalidRows = 126L
$ExpectedArchiveScanSha256 = '1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba'

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
function Row-Key {
    param([string]$Archive,[object]$Ordinal)
    return $Archive.Trim().ToLowerInvariant() + '|' + ([long]$Ordinal).ToString()
}
function Identity-Key {
    param([object]$Record,[object]$Date,[object]$Source,[object]$Document)
    return ([string]$Record) + '|' + ([string]$Date) + '|' + ([string]$Source) + '|' + ([string]$Document)
}
function Parse-Bool {
    param([object]$Value,[string]$Label)
    $x = ([string]$Value).Trim().ToLowerInvariant()
    if ($x -eq 'true') { return $true }
    if ($x -eq 'false') { return $false }
    throw "Malformed boolean in ${Label}: '$Value'"
}

function Assert-V2 {
    param([string]$Root)
    $summary = Join-Path $Root 'stage3-match-summary.json'
    $matches = Join-Path $Root 'stage3-news-matches.csv'
    $rejects = Join-Path $Root 'stage3-context-rejects.csv'
    $samples = Join-Path $Root 'stage3-match-samples.csv'
    foreach ($path in @($summary,$matches,$rejects,$samples)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required V2 artifact missing: $path" }
    }
    $s = Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
    if ([string]$s.run_status -ne 'PASS' -or [string]$s.matching_contract -ne 'CANDIDATE_V2') { throw 'Parent V2 is not PASS CANDIDATE_V2.' }
    if ([int]$s.source.archive_files -ne $ExpectedArchives -or [long]$s.source.rows_scanned -ne $ExpectedRows -or [long]$s.source.malformed_field_count_rows -ne $ExpectedMalformedRows) { throw 'Parent V2 source shape mismatch.' }
    if ((Get-Sha $matches) -ne ([string]$s.output.matches_sha256).ToLowerInvariant()) { throw 'Parent V2 matches hash mismatch.' }
    if ((Get-Sha $rejects) -ne ([string]$s.output.rejects_sha256).ToLowerInvariant()) { throw 'Parent V2 rejects hash mismatch.' }
    if ((Get-Sha $samples) -ne ([string]$s.output.samples_sha256).ToLowerInvariant()) { throw 'Parent V2 samples hash mismatch.' }
    return [pscustomobject]@{summary=$s;summary_path=$summary;matches=$matches;rejects=$rejects;samples=$samples}
}
function Assert-V3 {
    param([string]$Root)
    $summary = Join-Path $Root 'stage3-match-summary.json'
    $matches = Join-Path $Root 'stage3-news-matches.csv'
    $shortRejects = Join-Path $Root 'stage3-v3-short-symbol-rejects.csv'
    $samples = Join-Path $Root 'stage3-match-samples.csv'
    foreach ($path in @($summary,$matches,$shortRejects,$samples)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required V3 artifact missing: $path" }
    }
    $s = Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
    if ([string]$s.run_status -ne 'PASS' -or [string]$s.matching_contract -ne 'CANDIDATE_V3') { throw 'V3 input is not PASS CANDIDATE_V3.' }
    if ((Get-Sha $matches) -ne ([string]$s.output.matches_sha256).ToLowerInvariant()) { throw 'V3 matches hash mismatch.' }
    if ((Get-Sha $shortRejects) -ne ([string]$s.output.new_rejects_sha256).ToLowerInvariant()) { throw 'V3 short-reject hash mismatch.' }
    if ((Get-Sha $samples) -ne ([string]$s.output.samples_sha256).ToLowerInvariant()) { throw 'V3 samples hash mismatch.' }
    return [pscustomobject]@{summary=$s;summary_path=$summary;matches=$matches;short_rejects=$shortRejects;samples=$samples}
}
function Assert-Impact {
    param([string]$Root,[string]$V2Root)
    $summary = Join-Path $Root 'stage3-critical-utf8-impact-summary.json'
    if (-not (Test-Path -LiteralPath $summary -PathType Leaf)) { throw "Impact summary missing: $summary" }
    $s = Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
    if ([string]$s.status -ne 'PASS' -or [string]$s.diagnostic -ne 'CRITICAL_UTF8_V2_IMPACT') { throw 'Impact diagnostic is not PASS.' }
    if ([string]$s.archive_scan_sha256 -ne $ExpectedArchiveScanSha256) { throw 'Impact archive-scan hash mismatch.' }
    if ([long]$s.critical_utf8_exclusion_rows -ne $ExpectedCriticalInvalidRows -or [long]$s.known_malformed_rows -ne $ExpectedMalformedRows) { throw 'Impact counts differ from observed hard-gate evidence.' }
    if ([string]$s.gates.'CFA-S3F-011' -ne 'PASS' -or [string]$s.gates.'CFA-S3F-012' -ne 'PASS') { throw 'Impact diagnostic gates are not PASS.' }
    $exclusions = [string]$s.outputs.exclusions_csv
    if (-not (Test-Path -LiteralPath $exclusions -PathType Leaf)) { throw 'Impact exclusion CSV missing.' }
    if ((Get-Sha $exclusions) -ne ([string]$s.outputs.exclusions_sha256).ToLowerInvariant()) { throw 'Impact exclusion hash mismatch.' }
    $impactParent = (Resolve-Path -LiteralPath ([string]$s.parent_v2_run)).ProviderPath
    $requestedParent = (Resolve-Path -LiteralPath $V2Root).ProviderPath
    if ($impactParent -ne $requestedParent) { throw 'Impact diagnostic parent V2 differs from requested parent.' }
    return [pscustomobject]@{summary=$s;summary_path=$summary;exclusions=$exclusions}
}

function Invoke-SelfTest {
    $set = @{}
    $set[(Row-Key 'A.zip' 2)] = $true
    if (-not $set.ContainsKey((Row-Key 'A.zip' 2))) { throw 'Exclusion key lookup failed.' }
    if ($set.ContainsKey((Row-Key 'A.zip' 3))) { throw 'Exclusion key false positive.' }
    $critical = 126L
    $malformed = 5L
    $overlap = 2L
    $eligible = $ExpectedRows - $malformed - ($critical - $overlap)
    if ($eligible -ne 9183628L) { throw 'Eligible source row calculation failed.' }
    Write-Host 'SELF-TEST: PASS'
}
if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    $Stage3V2RunRoot = (Resolve-Path -LiteralPath $Stage3V2RunRoot).ProviderPath
    $Stage3V3RunRoot = (Resolve-Path -LiteralPath $Stage3V3RunRoot).ProviderPath
    $ImpactRunRoot = (Resolve-Path -LiteralPath $ImpactRunRoot).ProviderPath
    if (Test-Path -LiteralPath $OutputRoot) {
        if (@(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw "OutputRoot must be empty: $OutputRoot" }
    }
    else { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    $v2 = Assert-V2 $Stage3V2RunRoot
    $v3 = Assert-V3 $Stage3V3RunRoot
    $impact = Assert-Impact $ImpactRunRoot $Stage3V2RunRoot
    $v3Parent = (Resolve-Path -LiteralPath ([string]$v3.summary.parent_v2.run_root)).ProviderPath
    if ($v3Parent -ne $Stage3V2RunRoot) { throw 'V3 parent V2 differs from requested parent.' }
    if ([string]$v3.summary.parent_v2.summary_sha256 -ne (Get-Sha $v2.summary_path)) { throw 'V3 parent V2 summary hash mismatch.' }

    $exclusionRows = @(Import-Csv -LiteralPath $impact.exclusions)
    if ($exclusionRows.Count -ne $ExpectedCriticalInvalidRows) { throw 'Exclusion manifest row count mismatch.' }
    $exclusionByKey = @{}
    $identitySet = @{}
    [long]$exclusionMalformed = 0
    foreach ($e in $exclusionRows) {
        $key = Row-Key ([string]$e.archive_file) $e.row_ordinal
        if ($exclusionByKey.ContainsKey($key)) { throw "Duplicate exclusion key: $key" }
        if ([string]::IsNullOrWhiteSpace([string]$e.raw_line_sha256)) { throw "Blank raw line hash: $key" }
        $exclusionByKey[$key] = $e
        if (Parse-Bool $e.malformed_field_count "exclusion $key malformed") { $exclusionMalformed++ }
        $identitySet[(Identity-Key $e.record_id_lenient $e.gdelt_date_utc_lenient $e.source_common_name_lenient $e.document_identifier_lenient)] = $true
    }
    $eligibleRows = $ExpectedRows - $ExpectedMalformedRows - ($ExpectedCriticalInvalidRows - $exclusionMalformed)

    $keptMatches = New-Object System.Collections.ArrayList
    $excludedMatches = New-Object System.Collections.ArrayList
    $matchedAssets = New-Object 'Collections.Generic.HashSet[string]'
    $v3MatchRows = @(Import-Csv -LiteralPath $v3.matches)
    foreach ($r in $v3MatchRows) {
        $key = Row-Key ([string]$r.archive_file) $r.row_ordinal
        if ($exclusionByKey.ContainsKey($key)) { [void]$excludedMatches.Add($r) }
        else { [void]$keptMatches.Add($r); [void]$matchedAssets.Add([string]$r.base_asset_id) }
    }

    $keptShort = New-Object System.Collections.ArrayList
    $excludedShort = New-Object System.Collections.ArrayList
    foreach ($r in @(Import-Csv -LiteralPath $v3.short_rejects)) {
        $key = Row-Key ([string]$r.archive_file) $r.row_ordinal
        if ($exclusionByKey.ContainsKey($key)) { [void]$excludedShort.Add($r) }
        else { [void]$keptShort.Add($r) }
    }

    $keptContext = New-Object System.Collections.ArrayList
    $excludedContext = New-Object System.Collections.ArrayList
    foreach ($r in @(Import-Csv -LiteralPath $v2.rejects)) {
        $key = Row-Key ([string]$r.archive_file) $r.row_ordinal
        if ($exclusionByKey.ContainsKey($key)) { [void]$excludedContext.Add($r) }
        else { [void]$keptContext.Add($r) }
    }

    $keptSamples = New-Object System.Collections.ArrayList
    $excludedSamples = New-Object System.Collections.ArrayList
    foreach ($r in @(Import-Csv -LiteralPath $v3.samples)) {
        $identity = Identity-Key $r.record_id $r.gdelt_date_utc $r.source_common_name $r.document_identifier
        if ($identitySet.ContainsKey($identity)) { [void]$excludedSamples.Add($r); continue }
        [void]$keptSamples.Add([pscustomobject][ordered]@{
            v4_match_status=[string]$r.v3_match_status;v4_filter_reason='ELIGIBLE_UTF8_THEN_V3';v4_eligible='True'
            v3_match_status=[string]$r.v3_match_status;v3_filter_reason=[string]$r.v3_filter_reason;v2_match_status=[string]$r.v2_match_status
            v3_short_default_symbol=[string]$r.v3_short_default_symbol;v3_approved_nondefault_same_record=[string]$r.v3_approved_nondefault_same_record
            base_asset_id=[string]$r.base_asset_id;alias_text=[string]$r.alias_text;requires_crypto_context=[string]$r.requires_crypto_context
            record_id=[string]$r.record_id;gdelt_date_utc=[string]$r.gdelt_date_utc;source_common_name=[string]$r.source_common_name;document_identifier=[string]$r.document_identifier
            page_title=[string]$r.page_title;matched_surfaces=[string]$r.matched_surfaces;econ_bitcoin_theme=[string]$r.econ_bitcoin_theme
            title_crypto_anchor=[string]$r.title_crypto_anchor;context_reason=[string]$r.context_reason
        })
    }

    $matchesPath = Join-Path $OutputRoot 'stage3-news-matches.csv'
    $contextPath = Join-Path $OutputRoot 'stage3-context-rejects.csv'
    $shortPath = Join-Path $OutputRoot 'stage3-v4-short-symbol-rejects.csv'
    $samplesPath = Join-Path $OutputRoot 'stage3-match-samples.csv'
    $utf8MatchPath = Join-Path $OutputRoot 'stage3-v4-utf8-excluded-matches.csv'
    $utf8ContextPath = Join-Path $OutputRoot 'stage3-v4-utf8-excluded-context-rejects.csv'
    $utf8ShortPath = Join-Path $OutputRoot 'stage3-v4-utf8-excluded-short-symbol-rejects.csv'
    $utf8SamplePath = Join-Path $OutputRoot 'stage3-v4-utf8-excluded-samples.csv'

    @($keptMatches.ToArray()) | Export-Csv -LiteralPath $matchesPath -NoTypeInformation -Encoding UTF8
    @($keptContext.ToArray()) | Export-Csv -LiteralPath $contextPath -NoTypeInformation -Encoding UTF8
    @($keptShort.ToArray()) | Export-Csv -LiteralPath $shortPath -NoTypeInformation -Encoding UTF8
    @($keptSamples.ToArray()) | Export-Csv -LiteralPath $samplesPath -NoTypeInformation -Encoding UTF8
    @($excludedMatches.ToArray()) | Export-Csv -LiteralPath $utf8MatchPath -NoTypeInformation -Encoding UTF8
    @($excludedContext.ToArray()) | Export-Csv -LiteralPath $utf8ContextPath -NoTypeInformation -Encoding UTF8
    @($excludedShort.ToArray()) | Export-Csv -LiteralPath $utf8ShortPath -NoTypeInformation -Encoding UTF8
    @($excludedSamples.ToArray()) | Export-Csv -LiteralPath $utf8SamplePath -NoTypeInformation -Encoding UTF8

    $summary = [ordered]@{
        run_status='PASS'
        implementation='v4-critical-utf8-eligibility-plus-v3-short-symbol'
        matching_contract='CANDIDATE_V4'
        rule='Exclude every raw row with invalid UTF-8 in Stage 3-used fields at archive_file/row_ordinal/raw_line_sha256 grain, then apply the frozen V3 short-default-symbol rule to remaining eligible rows.'
        gates=[ordered]@{'CFA-S3F-008'='FAIL';'CFA-S3F-011'='PASS';'CFA-S3F-012'='PASS';'CFA-S3F-013'='PASS';'CFA-S3F-014'='UNVERIFIED';'CFA-S3F-015'='BLOCKED';'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'}
        source=[ordered]@{archive_files=$ExpectedArchives;rows_scanned=$ExpectedRows;malformed_field_count_rows=$ExpectedMalformedRows;critical_utf8_exclusion_rows=$ExpectedCriticalInvalidRows;critical_utf8_exclusion_malformed_rows=$exclusionMalformed;critical_utf8_exclusion_nonmalformed_rows=($ExpectedCriticalInvalidRows-$exclusionMalformed);eligible_rows=$eligibleRows;archive_scan_sha256=$ExpectedArchiveScanSha256}
        parent_v2=[ordered]@{run_root=$Stage3V2RunRoot;summary_sha256=(Get-Sha $v2.summary_path);matches_sha256=(Get-Sha $v2.matches);rejects_sha256=(Get-Sha $v2.rejects);samples_sha256=(Get-Sha $v2.samples)}
        parent_v3=[ordered]@{run_root=$Stage3V3RunRoot;summary_sha256=(Get-Sha $v3.summary_path);matches_sha256=(Get-Sha $v3.matches);short_rejects_sha256=(Get-Sha $v3.short_rejects);samples_sha256=(Get-Sha $v3.samples)}
        utf8_impact=[ordered]@{run_root=$ImpactRunRoot;summary_sha256=(Get-Sha $impact.summary_path);exclusions_sha256=(Get-Sha $impact.exclusions)}
        matching=[ordered]@{v3_retained_matches=$v3MatchRows.Count;removed_v4_utf8_matches=$excludedMatches.Count;unique_asset_record_matches=$keptMatches.Count;matched_assets=$matchedAssets.Count;v4_context_rejects=$keptContext.Count;v4_short_symbol_rejects=$keptShort.Count;excluded_v2_context_rejects=$excludedContext.Count;excluded_v3_short_symbol_rejects=$excludedShort.Count;excluded_v3_samples=$excludedSamples.Count}
        output=[ordered]@{matches_path=$matchesPath;matches_sha256=(Get-Sha $matchesPath);context_rejects_path=$contextPath;context_rejects_sha256=(Get-Sha $contextPath);short_rejects_path=$shortPath;short_rejects_sha256=(Get-Sha $shortPath);samples_path=$samplesPath;samples_sha256=(Get-Sha $samplesPath);utf8_excluded_matches_path=$utf8MatchPath;utf8_excluded_matches_sha256=(Get-Sha $utf8MatchPath);utf8_excluded_context_rejects_path=$utf8ContextPath;utf8_excluded_context_rejects_sha256=(Get-Sha $utf8ContextPath);utf8_excluded_short_rejects_path=$utf8ShortPath;utf8_excluded_short_rejects_sha256=(Get-Sha $utf8ShortPath);utf8_excluded_samples_path=$utf8SamplePath;utf8_excluded_samples_sha256=(Get-Sha $utf8SamplePath)}
        semantic_review='UNVERIFIED'
        freeze_news_matching='BLOCKED'
    }
    $summaryPath = Join-Path $OutputRoot 'stage3-match-summary.json'
    Write-Utf8NoBom $summaryPath (($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 3 V4 UTF-8 ELIGIBILITY CORRECTION: PASS'
    Write-Host ("Eligible source rows: {0}" -f $eligibleRows)
    Write-Host ("V4 retained matches: {0}" -f $keptMatches.Count)
    Write-Host ("UTF-8-excluded V3 matches: {0}" -f $excludedMatches.Count)
    Write-Host ("UTF-8-excluded V2 context rejects: {0}" -f $excludedContext.Count)
    Write-Host ("UTF-8-excluded V3 samples: {0}" -f $excludedSamples.Count)
    Write-Host 'CFA-S3F-014 semantic review: UNVERIFIED'
    Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
    Write-Host ("V4 evidence directory: {0}" -f $OutputRoot)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V4 UTF-8 ELIGIBILITY CORRECTION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
