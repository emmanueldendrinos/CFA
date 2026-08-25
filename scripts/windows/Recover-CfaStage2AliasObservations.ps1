#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = '',
    [string]$DiagnosticRoot = '',
    [string]$OutputRoot = '',
    [ValidateRange(1,100)][int]$MaxSamplesPerAlias = 12,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Web

$ExpectedFieldCount = 27
$RecordIdIndex = 0
$DateIndex = 1
$SourceCommonNameIndex = 3
$DocumentIdentifierIndex = 4
$V2PersonsIndex = 12
$V2OrganizationsIndex = 14
$AllNamesIndex = 23
$ExtrasIndex = 26

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}

function Normalize-Bool {
    param([object]$Value)
    $t = ([string]$Value).Trim().ToLowerInvariant()
    if ($t -eq 'true') { return $true }
    if ($t -eq 'false') { return $false }
    throw "Malformed boolean: $Value"
}

function Get-LatestDiagnosticRun {
    param([string]$Parent)
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw "Alias diagnostic root missing: $Parent" }
    foreach ($run in @(Get-ChildItem -LiteralPath $Parent -Directory -Force | Sort-Object Name -Descending)) {
        $path = Join-Path $run.FullName 'diagnostic-summary.csv'
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $run }
    }
    throw "No usable alias diagnostic run found under: $Parent"
}

function Parse-OffsetNames {
    param([string]$Text)
    $items = @()
    $malformed = 0
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{items=$items;malformed=0} }
    foreach ($block in @($Text -split ';')) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $comma = $block.LastIndexOf(',')
        if ($comma -le 0 -or $comma -ge ($block.Length - 1)) { $malformed++; continue }
        $name = $block.Substring(0,$comma).Trim()
        $offsetText = $block.Substring($comma + 1).Trim()
        $offset = 0
        if ([string]::IsNullOrWhiteSpace($name) -or -not [int]::TryParse($offsetText,[ref]$offset)) { $malformed++; continue }
        $items += [pscustomobject]@{name=$name;offset=$offset}
    }
    return [pscustomobject]@{items=$items;malformed=$malformed}
}

function Get-PageTitle {
    param([string]$Extras)
    if ([string]::IsNullOrWhiteSpace($Extras)) { return '' }
    $m = [regex]::Match($Extras,'<PAGE_TITLE>(.*?)</PAGE_TITLE>',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return '' }
    return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}

function New-AliasState {
    param([object]$Row)
    return [pscustomobject]@{
        base_asset_id = [string]$Row.base_asset_id
        alias_text = [string]$Row.alias_text
        alias_type = [string]$Row.alias_type
        requires_crypto_context = (Normalize-Bool $Row.requires_crypto_context)
        mapping_tier = [string]$Row.mapping_tier
        allnames_document_count = 0L
        persons_document_count = 0L
        organizations_document_count = 0L
        title_document_count = 0L
        any_surface_document_count = 0L
        candidate_context_supported_document_count = 0L
        distinct_sources = @{}
        first_date = ''
        last_date = ''
        samples = New-Object System.Collections.ArrayList
    }
}

function Invoke-SelfTest {
    $p = Parse-OffsetNames 'Bitcoin,10;World Cup,25'
    if ($p.items.Count -ne 2 -or $p.items[0].name -ne 'Bitcoin') { throw 'offset-name parser' }
    $title = Get-PageTitle 'x<PAGE_TITLE>Bitcoin &amp; Ethereum rally</PAGE_TITLE>y'
    if ($title -ne 'Bitcoin & Ethereum rally') { throw 'page title parser' }
    $aliases = @('Artificial Superintelligence Alliance','Bitcoin Cash','Bitcoin','BTC')
    $parts = @($aliases | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    $rx = New-Object System.Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:' + ($parts -join '|') + ')(?![\p{L}\p{N}])'),([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant))
    $matches = @($rx.Matches('Bitcoin Cash rises while Bitcoin falls'))
    if ($matches.Count -ne 2 -or $matches[0].Value -ne 'Bitcoin Cash' -or $matches[1].Value -ne 'Bitcoin') { throw 'title alias regex' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $ArchiveRoot = Join-Path $docs 'CFA-local\gdelt-gkg-q2-2025' }
    if ([string]::IsNullOrWhiteSpace($DiagnosticRoot)) { $DiagnosticRoot = Join-Path $docs 'CFA-local\gdelt-alias-diagnostics' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $docs 'CFA-local\gdelt-alias-recovery' }
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $DiagnosticRoot = (Resolve-Path -LiteralPath $DiagnosticRoot).ProviderPath
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }

    $diagRun = Get-LatestDiagnosticRun -Parent $DiagnosticRoot
    $diagSummary = @(Import-Csv -LiteralPath (Join-Path $diagRun.FullName 'diagnostic-summary.csv'))
    if ($diagSummary.Count -ne 1) { throw 'Alias diagnostic summary cardinality must be exactly one.' }
    if ([int]$diagSummary[0].allnames_utf8_invalid_rows -ne 0) { throw 'Recovery blocked: ALLNAMES has invalid UTF-8 rows.' }
    if ([int]$diagSummary[0].critical_field_utf8_invalid_rows -ne 0) { throw 'Recovery blocked: critical GKG fields have invalid UTF-8 rows.' }
    $expectedQuarantineRows = [int]$diagSummary[0].raw_malformed_field_count_rows
    if ($expectedQuarantineRows -le 0) { throw 'Recovery contract expected at least one diagnosed malformed row.' }

    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv'
    $aliases = @(Import-Csv -LiteralPath $aliasPath)
    if ($aliases.Count -ne 45) { throw "Expected 45 aliases; observed $($aliases.Count)." }

    $states = @{}
    $lookup = @{}
    $contextFreeKeys = @{}
    $aliasTexts = @()
    foreach ($row in $aliases) {
        $norm = ([string]$row.alias_text).Trim().ToLowerInvariant()
        $key = ([string]$row.base_asset_id) + '|' + $norm
        if ($states.ContainsKey($key)) { throw "Duplicate alias key: $key" }
        $state = New-AliasState $row
        $states[$key] = $state
        if (-not $lookup.ContainsKey($norm)) { $lookup[$norm] = @() }
        $lookup[$norm] += $key
        $aliasTexts += [string]$row.alias_text
        if (-not $state.requires_crypto_context) { $contextFreeKeys[$key] = $true }
    }

    $uniqueAliasTexts = @($aliasTexts | Sort-Object -Unique)
    $patternParts = @($uniqueAliasTexts | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    $titleRegex = New-Object System.Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:' + ($patternParts -join '|') + ')(?![\p{L}\p{N}])'),([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant))
    $cryptoContextRegex = New-Object System.Text.RegularExpressions.Regex('(?<![\p{L}\p{N}])(?:crypto|cryptocurrency|blockchain|token|coin|web3|defi|nft)(?![\p{L}\p{N}])',([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant))

    $files = @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip' | Where-Object { $_.Name -match '^\d{14}\.gkg\.csv\.zip$' } | Sort-Object Name)
    if ($files.Count -ne 7163) { throw "Expected 7163 downloaded GKG archives; observed $($files.Count)." }

    $lenientUtf8 = New-Object System.Text.UTF8Encoding($false,$false)
    $archiveRows = @()
    $sampleRows = @()
    $quarantineRows = @()
    $totalRows = 0L
    $quarantined = 0L
    $entryCountFailures = 0
    $malformedEntityBlocks = 0L
    $ordinal = 0

    foreach ($file in $files) {
        $ordinal++
        if (($ordinal % 250) -eq 0) { Write-Host ("Recovery alias scan archives: {0}/{1}" -f $ordinal,$files.Count) }
        $zip = $null
        $rowsThis = 0L
        $quarantineThis = 0L
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
            $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
            if ($entries.Count -ne 1) {
                $entryCountFailures++
                $archiveRows += [pscustomobject]@{archive_file=$file.Name;rows_scanned=0;quarantined_rows=0;entry_count_status='FAIL'}
                continue
            }
            $stream = $entries[0].Open()
            $reader = $null
            try {
                $reader = New-Object System.IO.StreamReader($stream,$lenientUtf8,$false,65536,$false)
                $rowOrdinal = 0L
                while (($line = $reader.ReadLine()) -ne $null) {
                    $rowOrdinal++
                    $rowsThis++
                    $totalRows++
                    $fields = $line.Split([char]9)
                    if ($fields.Count -ne $ExpectedFieldCount) {
                        $quarantined++
                        $quarantineThis++
                        if ($quarantineRows.Count -lt 100) {
                            $quarantineRows += [pscustomobject]@{archive_file=$file.Name;row_ordinal=$rowOrdinal;observed_field_count=$fields.Count;reject_reason='RAW_FIELD_COUNT_NOT_27'}
                        }
                        continue
                    }

                    $surfaceByKey = @{}
                    foreach ($surfaceDef in @(
                        @('ALLNAMES',$AllNamesIndex),
                        @('V2PERSONS',$V2PersonsIndex),
                        @('V2ORGANIZATIONS',$V2OrganizationsIndex)
                    )) {
                        $parsed = Parse-OffsetNames -Text $fields[$surfaceDef[1]]
                        $malformedEntityBlocks += [long]$parsed.malformed
                        foreach ($item in $parsed.items) {
                            $norm = $item.name.ToLowerInvariant()
                            if (-not $lookup.ContainsKey($norm)) { continue }
                            foreach ($key in $lookup[$norm]) {
                                if (-not $surfaceByKey.ContainsKey($key)) { $surfaceByKey[$key] = @{} }
                                $surfaceByKey[$key][$surfaceDef[0]] = $true
                            }
                        }
                    }

                    $title = Get-PageTitle -Extras $fields[$ExtrasIndex]
                    if (-not [string]::IsNullOrWhiteSpace($title)) {
                        foreach ($m in @($titleRegex.Matches($title))) {
                            $norm = $m.Value.ToLowerInvariant()
                            if (-not $lookup.ContainsKey($norm)) { continue }
                            foreach ($key in $lookup[$norm]) {
                                if (-not $surfaceByKey.ContainsKey($key)) { $surfaceByKey[$key] = @{} }
                                $surfaceByKey[$key]['PAGE_TITLE'] = $true
                            }
                        }
                    }

                    if ($surfaceByKey.Count -eq 0) { continue }
                    $hasContextAnchor = $false
                    if (-not [string]::IsNullOrWhiteSpace($title) -and $cryptoContextRegex.IsMatch($title)) { $hasContextAnchor = $true }
                    if (-not $hasContextAnchor) {
                        foreach ($matchedKey in $surfaceByKey.Keys) {
                            if ($contextFreeKeys.ContainsKey($matchedKey)) { $hasContextAnchor = $true; break }
                        }
                    }

                    foreach ($key in $surfaceByKey.Keys) {
                        $state = $states[$key]
                        $surfaces = $surfaceByKey[$key]
                        if ($surfaces.ContainsKey('ALLNAMES')) { $state.allnames_document_count = [long]$state.allnames_document_count + 1 }
                        if ($surfaces.ContainsKey('V2PERSONS')) { $state.persons_document_count = [long]$state.persons_document_count + 1 }
                        if ($surfaces.ContainsKey('V2ORGANIZATIONS')) { $state.organizations_document_count = [long]$state.organizations_document_count + 1 }
                        if ($surfaces.ContainsKey('PAGE_TITLE')) { $state.title_document_count = [long]$state.title_document_count + 1 }
                        $state.any_surface_document_count = [long]$state.any_surface_document_count + 1
                        if ($state.requires_crypto_context -and $hasContextAnchor) { $state.candidate_context_supported_document_count = [long]$state.candidate_context_supported_document_count + 1 }
                        $source = [string]$fields[$SourceCommonNameIndex]
                        if (-not [string]::IsNullOrWhiteSpace($source)) { $state.distinct_sources[$source] = $true }
                        $date = [string]$fields[$DateIndex]
                        if ([string]::IsNullOrWhiteSpace($state.first_date) -or $date -lt $state.first_date) { $state.first_date = $date }
                        if ([string]::IsNullOrWhiteSpace($state.last_date) -or $date -gt $state.last_date) { $state.last_date = $date }
                        if ($state.samples.Count -lt $MaxSamplesPerAlias) {
                            [void]$state.samples.Add([pscustomobject]@{
                                base_asset_id=$state.base_asset_id;alias_text=$state.alias_text;requires_crypto_context=$state.requires_crypto_context;
                                record_id=[string]$fields[$RecordIdIndex];date_utc=$date;source_common_name=$source;document_identifier=[string]$fields[$DocumentIdentifierIndex];
                                matched_surfaces=(@($surfaces.Keys | Sort-Object) -join '|');candidate_context_anchor_present=$hasContextAnchor
                            })
                        }
                    }
                }
            }
            finally {
                if ($null -ne $reader) { $reader.Dispose() }
                else { $stream.Dispose() }
            }
        }
        finally { if ($null -ne $zip) { $zip.Dispose() } }
        $archiveRows += [pscustomobject]@{archive_file=$file.Name;rows_scanned=$rowsThis;quarantined_rows=$quarantineThis;entry_count_status='PASS'}
    }

    $aliasRows = @()
    foreach ($key in @($states.Keys | Sort-Object)) {
        $s = $states[$key]
        $status = 'UNVERIFIED_NOT_OBSERVED'
        if ($s.any_surface_document_count -gt 0) {
            if ($s.requires_crypto_context) { $status = 'OBSERVED_CONTEXT_REVIEW_REQUIRED' }
            else { $status = 'OBSERVED_MULTI_SURFACE' }
        }
        $aliasRows += [pscustomobject]@{
            base_asset_id=$s.base_asset_id;alias_text=$s.alias_text;alias_type=$s.alias_type;requires_crypto_context=$s.requires_crypto_context;mapping_tier=$s.mapping_tier;
            allnames_document_count=$s.allnames_document_count;persons_document_count=$s.persons_document_count;organizations_document_count=$s.organizations_document_count;title_document_count=$s.title_document_count;
            any_surface_document_count=$s.any_surface_document_count;candidate_context_supported_document_count=$s.candidate_context_supported_document_count;
            candidate_context_unsupported_document_count=([long]$s.any_surface_document_count-[long]$s.candidate_context_supported_document_count);distinct_source_count=$s.distinct_sources.Count;
            first_date_utc=$s.first_date;last_date_utc=$s.last_date;semantic_observation_status=$status
        }
        foreach ($sample in $s.samples) { $sampleRows += $sample }
    }

    $run = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $dir = Join-Path $OutputRoot $run
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $aliasRows | Sort-Object base_asset_id,alias_text | Export-Csv -LiteralPath (Join-Path $dir 'alias-recovery.csv') -NoTypeInformation -Encoding UTF8
    $sampleRows | Sort-Object base_asset_id,alias_text,date_utc | Export-Csv -LiteralPath (Join-Path $dir 'alias-recovery-samples.csv') -NoTypeInformation -Encoding UTF8
    $archiveRows | Export-Csv -LiteralPath (Join-Path $dir 'archive-scan.csv') -NoTypeInformation -Encoding UTF8
    $quarantineRows | Export-Csv -LiteralPath (Join-Path $dir 'quarantine-rows.csv') -NoTypeInformation -Encoding UTF8

    $observed = @($aliasRows | Where-Object { [long]$_.any_surface_document_count -gt 0 }).Count
    $contextObserved = @($aliasRows | Where-Object { ($_.requires_crypto_context -eq 'True' -or $_.requires_crypto_context -eq $true) -and [long]$_.any_surface_document_count -gt 0 }).Count
    @([pscustomobject]@{
        run_id=$run;source_diagnostic_run=$diagRun.Name;archive_files=$files.Count;rows_scanned=$totalRows;quarantined_rows=$quarantined;expected_quarantined_rows=$expectedQuarantineRows;
        entry_count_failures=$entryCountFailures;malformed_entity_blocks=$malformedEntityBlocks;alias_rows=45;observed_aliases=$observed;not_observed_aliases=(45-$observed);
        context_required_aliases=@($aliasRows|Where-Object{$_.requires_crypto_context-eq'True'-or$_.requires_crypto_context-eq$true}).Count;context_required_observed_aliases=$contextObserved;
        recovery_policy='QUARANTINE_NON_27_FIELD_ROWS;UTF8_REPLACEMENT_NONCRITICAL_ONLY;CRITICAL_AND_ALLNAMES_STRICT_VALIDATED_BY_DIAGNOSTIC';matching_surfaces='ALLNAMES|V2PERSONS|V2ORGANIZATIONS|PAGE_TITLE'
    }) | Export-Csv -LiteralPath (Join-Path $dir 'recovery-summary.csv') -NoTypeInformation -Encoding UTF8

    Write-Host "Evidence directory: $dir"
    Write-Host "Rows scanned: $totalRows"
    Write-Host "Quarantined malformed rows: $quarantined (expected $expectedQuarantineRows)"
    Write-Host "Observed aliases across all surfaces: $observed / 45"
    Write-Host "Context-required observed aliases: $contextObserved"
    Write-Host 'CFA STAGE 2 ALIAS RECOVERY OBSERVATION: COMPLETE'

    if ($entryCountFailures -gt 0 -or $quarantined -ne $expectedQuarantineRows) { exit 2 }
}
catch {
    Write-Host 'CFA STAGE 2 ALIAS RECOVERY OBSERVATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
