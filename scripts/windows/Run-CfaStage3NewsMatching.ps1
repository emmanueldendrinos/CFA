#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = '',
    [string]$OutputRoot = '',
    [ValidateRange(1,50)][int]$MaxSamplesPerAlias = 10,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedFieldCount = 27
$ExpectedArchives = 7163
$ExpectedRows = 9091236L
$ExpectedMalformedRows = 5L
$RecordIdIndex = 0
$DateIndex = 1
$SourceCommonNameIndex = 3
$DocumentIdentifierIndex = 4
$V2ThemesIndex = 8
$V2PersonsIndex = 12
$V2OrganizationsIndex = 14
$AllNamesIndex = 23
$ExtrasIndex = 26

$CryptoTitleRegex = New-Object System.Text.RegularExpressions.Regex(
    '(?<![\p{L}\p{N}])(?:crypto|cryptocurrency|cryptocurrencies|blockchain|token|tokens|coin|coins|web3|defi|nft|nfts|staking|wallet|wallets|digital\s+asset|digital\s+assets)(?![\p{L}\p{N}])',
    ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
)

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}

function Normalize-Bool {
    param([object]$Value)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return $true }
    if ($text -eq 'false') { return $false }
    throw "Malformed boolean: $Value"
}

function Get-AliasKey {
    param([string]$Base,[string]$Alias)
    return $Base + '|' + $Alias.Trim().ToLowerInvariant()
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

function Test-EconBitcoinTheme {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($block in @($Text -split ';')) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $comma = $block.LastIndexOf(',')
        $name = if ($comma -gt 0) { $block.Substring(0,$comma).Trim() } else { $block.Trim() }
        if ($name.Equals('ECON_BITCOIN',[System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function New-AliasTools {
    param([object[]]$Aliases)
    $lookup = @{}
    $texts = @()
    foreach ($a in $Aliases) {
        $text = ([string]$a.alias_text).Trim()
        $norm = $text.ToLowerInvariant()
        $key = Get-AliasKey -Base ([string]$a.base_asset_id) -Alias $text
        if (-not $lookup.ContainsKey($norm)) { $lookup[$norm] = @() }
        $lookup[$norm] += $key
        $texts += $text
    }
    $parts = @($texts | Sort-Object -Unique | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    $regex = New-Object System.Text.RegularExpressions.Regex(
        ('(?<![\p{L}\p{N}])(?:' + ($parts -join '|') + ')(?![\p{L}\p{N}])'),
        ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    )
    return [pscustomobject]@{lookup=$lookup;regex=$regex}
}

function Add-SurfaceHit {
    param([hashtable]$Hits,[string]$Key,[string]$Surface)
    if (-not $Hits.ContainsKey($Key)) { $Hits[$Key] = @{} }
    $Hits[$Key][$Surface] = $true
}

function Test-AliasAccepted {
    param([bool]$RequiresContext,[bool]$EconBitcoin,[bool]$TitleCrypto)
    if (-not $RequiresContext) { return $true }
    return ($EconBitcoin -or $TitleCrypto)
}

function Invoke-SelfTest {
    $p = Parse-OffsetNames 'Bitcoin,10;Broken;Ethereum,25'
    if ($p.items.Count -ne 2 -or $p.malformed -ne 1 -or $p.items[0].name -ne 'Bitcoin') { throw 'offset parser' }
    if (-not (Test-EconBitcoinTheme 'ECON_BITCOIN,5;OTHER,1')) { throw 'theme exact match' }
    if (Test-EconBitcoinTheme 'ECON_BITCOINISH,5') { throw 'theme false positive' }
    $title = Get-PageTitle 'x<PAGE_TITLE>Bitcoin Cash &amp; crypto rally</PAGE_TITLE>y'
    if ($title -ne 'Bitcoin Cash & crypto rally') { throw 'title parser' }
    if (-not $CryptoTitleRegex.IsMatch($title)) { throw 'crypto title anchor' }
    $aliases = @(
        [pscustomobject]@{base_asset_id='XXBT';alias_text='Bitcoin';alias_type='manual_core_name';requires_crypto_context='False'},
        [pscustomobject]@{base_asset_id='BCH';alias_text='Bitcoin Cash';alias_type='manual_core_name';requires_crypto_context='False'}
    )
    $tools = New-AliasTools $aliases
    $matches = @($tools.regex.Matches('Bitcoin Cash rises while Bitcoin falls'))
    if ($matches.Count -ne 2 -or $matches[0].Value -ne 'Bitcoin Cash' -or $matches[1].Value -ne 'Bitcoin') { throw 'longest title alias matching' }
    if (Test-AliasAccepted -RequiresContext $true -EconBitcoin $false -TitleCrypto $false) { throw 'context rejection' }
    if (-not (Test-AliasAccepted -RequiresContext $true -EconBitcoin $true -TitleCrypto $false)) { throw 'theme context acceptance' }
    if (-not (Test-AliasAccepted -RequiresContext $false -EconBitcoin $false -TitleCrypto $false)) { throw 'context-free acceptance' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $ArchiveRoot = Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025' }
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $parent = Join-Path $documents 'CFA-local\stage3-news-matching'
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $OutputRoot = Join-Path $parent ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    }
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    $pairPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv'
    $semanticPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Alias-Semantic-Decisions.csv'
    foreach ($p in @($pairPath,$aliasPath,$semanticPath)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing active Stage 3 input: $p" } }

    $pairs = @(Import-Csv -LiteralPath $pairPath)
    $aliases = @(Import-Csv -LiteralPath $aliasPath)
    $semantic = @(Import-Csv -LiteralPath $semanticPath)
    if ($aliases.Count -ne 45) { throw "Expected 45 aliases; observed $($aliases.Count)." }
    if ($semantic.Count -ne 45) { throw "Expected 45 semantic decisions; observed $($semantic.Count)." }

    $marketIds = @($pairs | Where-Object { (Normalize-Bool $_.research_eligible) } | ForEach-Object { [string]$_.base_asset_id } | Sort-Object -Unique)
    if ($marketIds.Count -ne 435) { throw "Expected 435 eligible Kraken base assets; observed $($marketIds.Count)." }
    $marketSet = @{}; foreach ($id in $marketIds) { $marketSet[$id] = $true }

    $semanticByKey = @{}
    foreach ($s in $semantic) {
        $key = Get-AliasKey -Base ([string]$s.base_asset_id) -Alias ([string]$s.alias_text)
        if ($semanticByKey.ContainsKey($key)) { throw "Duplicate semantic decision key: $key" }
        $semanticByKey[$key] = $s
    }

    $aliasByKey = @{}
    $aliasAssets = @{}
    foreach ($a in $aliases) {
        $key = Get-AliasKey -Base ([string]$a.base_asset_id) -Alias ([string]$a.alias_text)
        if ($aliasByKey.ContainsKey($key)) { throw "Duplicate alias key: $key" }
        if (-not $marketSet.ContainsKey([string]$a.base_asset_id)) { throw "Alias base not in eligible Kraken universe: $key" }
        $requires = Normalize-Bool $a.requires_crypto_context
        if (-not $semanticByKey.ContainsKey($key)) { throw "Alias lacks semantic decision: $key" }
        $s = $semanticByKey[$key]
        if ([string]$s.semantic_decision -ne 'APPROVED_ALIAS_IDENTITY') { throw "Alias identity is not approved: $key" }
        if ([string]$s.alias_type -ne [string]$a.alias_type) { throw "Alias type mismatch: $key" }
        if ((Normalize-Bool $s.source_requires_crypto_context) -ne $requires) { throw "Alias context flag mismatch: $key" }
        $aliasByKey[$key] = [pscustomobject]@{
            base_asset_id=[string]$a.base_asset_id
            alias_text=[string]$a.alias_text
            alias_type=[string]$a.alias_type
            requires_crypto_context=$requires
        }
        $aliasAssets[[string]$a.base_asset_id] = $true
    }
    if ($aliasAssets.Count -ne 43) { throw "Expected aliases across 43 Kraken assets; observed $($aliasAssets.Count)." }
    if ($semanticByKey.Count -ne $aliasByKey.Count) { throw 'Semantic decision and alias key sets differ.' }

    $tools = New-AliasTools -Aliases $aliases
    $files = @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip' | Where-Object { $_.Name -match '^\d{14}\.gkg\.csv\.zip$' } | Sort-Object Name)
    if ($files.Count -ne $ExpectedArchives) { throw "Expected $ExpectedArchives GKG archives; observed $($files.Count)." }

    $matchesOut = @()
    $rejectsOut = @()
    $samplesOut = @()
    $sampleCount = @{}
    $seenMatchKeys = @{}
    $duplicateMatchKeys = 0L
    $totalRows = 0L
    $malformedRows = 0L
    $missingCriticalRows = 0L
    $malformedEntityBlocks = 0L
    $aliasCandidates = 0L
    $acceptedAliasHits = 0L
    $rejectedAliasHits = 0L
    $lenientUtf8 = New-Object System.Text.UTF8Encoding($false,$false)
    $archiveOrdinal = 0

    foreach ($file in $files) {
        $archiveOrdinal++
        if ($archiveOrdinal -eq 1 -or ($archiveOrdinal % 250) -eq 0) { Write-Host ("Stage 3 GKG scan archives: {0}/{1}" -f $archiveOrdinal,$files.Count) }
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
            $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
            if ($entries.Count -ne 1) { throw "Expected one data entry in archive $($file.Name); observed $($entries.Count)." }
            $stream = $entries[0].Open()
            $reader = $null
            try {
                $reader = New-Object System.IO.StreamReader($stream,$lenientUtf8,$false,65536,$false)
                $rowOrdinal = 0L
                while (($line = $reader.ReadLine()) -ne $null) {
                    $rowOrdinal++
                    $totalRows++
                    $fields = $line.Split([char]9)
                    if ($fields.Count -ne $ExpectedFieldCount) { $malformedRows++; continue }
                    $recordId = [string]$fields[$RecordIdIndex]
                    $dateUtc = [string]$fields[$DateIndex]
                    $documentIdentifier = [string]$fields[$DocumentIdentifierIndex]
                    if ([string]::IsNullOrWhiteSpace($recordId) -or $dateUtc -notmatch '^\d{14}$' -or [string]::IsNullOrWhiteSpace($documentIdentifier)) { $missingCriticalRows++; continue }

                    $hits = @{}
                    foreach ($surfaceDef in @(@('ALLNAMES',$AllNamesIndex),@('V2PERSONS',$V2PersonsIndex),@('V2ORGANIZATIONS',$V2OrganizationsIndex))) {
                        $parsed = Parse-OffsetNames -Text ([string]$fields[$surfaceDef[1]])
                        $malformedEntityBlocks += [long]$parsed.malformed
                        foreach ($item in $parsed.items) {
                            $norm = $item.name.Trim().ToLowerInvariant()
                            if (-not $tools.lookup.ContainsKey($norm)) { continue }
                            foreach ($key in $tools.lookup[$norm]) { Add-SurfaceHit -Hits $hits -Key $key -Surface ([string]$surfaceDef[0]) }
                        }
                    }

                    $pageTitle = Get-PageTitle -Extras ([string]$fields[$ExtrasIndex])
                    if (-not [string]::IsNullOrWhiteSpace($pageTitle)) {
                        foreach ($m in @($tools.regex.Matches($pageTitle))) {
                            $norm = $m.Value.ToLowerInvariant()
                            if (-not $tools.lookup.ContainsKey($norm)) { continue }
                            foreach ($key in $tools.lookup[$norm]) { Add-SurfaceHit -Hits $hits -Key $key -Surface 'PAGE_TITLE' }
                        }
                    }
                    if ($hits.Count -eq 0) { continue }

                    $econBitcoin = Test-EconBitcoinTheme -Text ([string]$fields[$V2ThemesIndex])
                    $titleCrypto = (-not [string]::IsNullOrWhiteSpace($pageTitle) -and $CryptoTitleRegex.IsMatch($pageTitle))
                    $acceptedByBase = @{}

                    foreach ($key in @($hits.Keys | Sort-Object)) {
                        $aliasCandidates++
                        $a = $aliasByKey[$key]
                        $accepted = Test-AliasAccepted -RequiresContext ([bool]$a.requires_crypto_context) -EconBitcoin $econBitcoin -TitleCrypto $titleCrypto
                        $contextReason = if (-not [bool]$a.requires_crypto_context) { 'NOT_REQUIRED' } elseif ($econBitcoin -and $titleCrypto) { 'ECON_BITCOIN|TITLE_CRYPTO' } elseif ($econBitcoin) { 'ECON_BITCOIN' } elseif ($titleCrypto) { 'TITLE_CRYPTO' } else { 'NONE' }
                        $status = if ($accepted) { 'MATCH' } else { 'REJECT_CONTEXT' }
                        if ($accepted) {
                            $acceptedAliasHits++
                            $base = [string]$a.base_asset_id
                            if (-not $acceptedByBase.ContainsKey($base)) { $acceptedByBase[$base] = [pscustomobject]@{aliases=@{};surfaces=@{};context=@{}} }
                            $state = $acceptedByBase[$base]
                            $state.aliases[[string]$a.alias_text] = $true
                            foreach ($surface in $hits[$key].Keys) { $state.surfaces[[string]$surface] = $true }
                            $state.context[$contextReason] = $true
                        } else {
                            $rejectedAliasHits++
                            $rejectsOut += [pscustomobject]@{
                                base_asset_id=[string]$a.base_asset_id
                                alias_text=[string]$a.alias_text
                                record_id=$recordId
                                gdelt_date_utc=$dateUtc
                                source_common_name=[string]$fields[$SourceCommonNameIndex]
                                document_identifier=$documentIdentifier
                                archive_file=$file.Name
                                row_ordinal=$rowOrdinal
                                matched_surfaces=(@($hits[$key].Keys | Sort-Object) -join '|')
                                context_reason=$contextReason
                            }
                        }

                        $sampleKey = ([string]$a.base_asset_id)+'|'+([string]$a.alias_text).ToLowerInvariant()+'|'+$status
                        if (-not $sampleCount.ContainsKey($sampleKey)) { $sampleCount[$sampleKey] = 0 }
                        if ([int]$sampleCount[$sampleKey] -lt $MaxSamplesPerAlias) {
                            $samplesOut += [pscustomobject]@{
                                match_status=$status
                                base_asset_id=[string]$a.base_asset_id
                                alias_text=[string]$a.alias_text
                                requires_crypto_context=[bool]$a.requires_crypto_context
                                record_id=$recordId
                                gdelt_date_utc=$dateUtc
                                source_common_name=[string]$fields[$SourceCommonNameIndex]
                                document_identifier=$documentIdentifier
                                page_title=$pageTitle
                                matched_surfaces=(@($hits[$key].Keys | Sort-Object) -join '|')
                                econ_bitcoin_theme=$econBitcoin
                                title_crypto_anchor=$titleCrypto
                                context_reason=$contextReason
                            }
                            $sampleCount[$sampleKey] = [int]$sampleCount[$sampleKey] + 1
                        }
                    }

                    foreach ($base in @($acceptedByBase.Keys | Sort-Object)) {
                        $matchKey = $base+'|'+$recordId
                        if ($seenMatchKeys.ContainsKey($matchKey)) { $duplicateMatchKeys++; continue }
                        $seenMatchKeys[$matchKey] = $true
                        $state = $acceptedByBase[$base]
                        $matchesOut += [pscustomobject]@{
                            base_asset_id=$base
                            record_id=$recordId
                            gdelt_date_utc=$dateUtc
                            source_common_name=[string]$fields[$SourceCommonNameIndex]
                            document_identifier=$documentIdentifier
                            archive_file=$file.Name
                            row_ordinal=$rowOrdinal
                            matched_aliases=(@($state.aliases.Keys | Sort-Object) -join '|')
                            matched_surfaces=(@($state.surfaces.Keys | Sort-Object) -join '|')
                            context_reasons=(@($state.context.Keys | Sort-Object) -join '|')
                        }
                    }
                }
            }
            finally {
                if ($null -ne $reader) { $reader.Dispose() } else { $stream.Dispose() }
            }
        }
        finally { if ($null -ne $zip) { $zip.Dispose() } }
    }

    $matchPath = Join-Path $OutputRoot 'stage3-news-matches.csv'
    $rejectPath = Join-Path $OutputRoot 'stage3-context-rejects.csv'
    $samplePath = Join-Path $OutputRoot 'stage3-match-samples.csv'
    $matchesOut | Sort-Object base_asset_id,gdelt_date_utc,record_id | Export-Csv -LiteralPath $matchPath -NoTypeInformation -Encoding UTF8
    $rejectsOut | Sort-Object base_asset_id,alias_text,gdelt_date_utc,record_id | Export-Csv -LiteralPath $rejectPath -NoTypeInformation -Encoding UTF8
    $samplesOut | Sort-Object base_asset_id,alias_text,match_status,gdelt_date_utc,record_id | Export-Csv -LiteralPath $samplePath -NoTypeInformation -Encoding UTF8

    $matchedAssets = @($matchesOut | ForEach-Object { [string]$_.base_asset_id } | Sort-Object -Unique)
    $shapeGate = if ($totalRows -eq $ExpectedRows -and $malformedRows -eq $ExpectedMalformedRows -and $missingCriticalRows -eq 0) { 'PASS' } else { 'FAIL' }
    $runGate = if ($files.Count -eq $ExpectedArchives -and $shapeGate -eq 'PASS' -and $duplicateMatchKeys -eq 0) { 'PASS' } else { 'FAIL' }

    $summary = [ordered]@{
        run_status=$runGate
        gates=[ordered]@{
            'CFA-S3-001'='PASS'
            'CFA-S3-002'=$shapeGate
            'CFA-S3-003'='PASS'
            'CFA-S3-004'=$runGate
            'CFA-S3-005'='UNVERIFIED'
            'CFA-S3-006'='BLOCKED'
        }
        source=[ordered]@{
            archive_root=$ArchiveRoot
            archive_files=$files.Count
            rows_scanned=$totalRows
            malformed_field_count_rows=$malformedRows
            missing_critical_rows=$missingCriticalRows
            malformed_entity_blocks=$malformedEntityBlocks
            AF_001_sha256=(Get-FileHash -LiteralPath $pairPath -Algorithm SHA256).Hash.ToLowerInvariant()
            AF_003_sha256=(Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()
            alias_semantic_decisions_sha256=(Get-FileHash -LiteralPath $semanticPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        matching=[ordered]@{
            alias_rows=$aliases.Count
            alias_assets=$aliasAssets.Count
            alias_candidates=$aliasCandidates
            accepted_alias_hits=$acceptedAliasHits
            rejected_context_alias_hits=$rejectedAliasHits
            unique_asset_record_matches=$matchesOut.Count
            matched_assets=$matchedAssets.Count
            duplicate_asset_record_matches=$duplicateMatchKeys
        }
        output=[ordered]@{
            matches_path=$matchPath
            matches_sha256=(Get-FileHash -LiteralPath $matchPath -Algorithm SHA256).Hash.ToLowerInvariant()
            rejects_path=$rejectPath
            rejects_sha256=(Get-FileHash -LiteralPath $rejectPath -Algorithm SHA256).Hash.ToLowerInvariant()
            samples_path=$samplePath
            samples_sha256=(Get-FileHash -LiteralPath $samplePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $summaryJsonPath = Join-Path $OutputRoot 'stage3-match-summary.json'
    Write-Utf8NoBom -Path $summaryJsonPath -Content (($summary | ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Stage 3 Kraken / GDELT News Matching Run')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- Run status: '+$runGate)
    [void]$b.AppendLine('- Archives: '+$files.Count)
    [void]$b.AppendLine('- Rows scanned: '+$totalRows)
    [void]$b.AppendLine('- Malformed 27-field rows: '+$malformedRows)
    [void]$b.AppendLine('- Alias candidates: '+$aliasCandidates)
    [void]$b.AppendLine('- Accepted alias hits: '+$acceptedAliasHits)
    [void]$b.AppendLine('- Context rejects: '+$rejectedAliasHits)
    [void]$b.AppendLine('- Unique asset/record matches: '+$matchesOut.Count)
    [void]$b.AppendLine('- Matched Kraken assets: '+$matchedAssets.Count+' of 43 alias-covered assets')
    [void]$b.AppendLine('- Duplicate asset/record matches: '+$duplicateMatchKeys)
    [void]$b.AppendLine('')
    [void]$b.AppendLine('CFA-S3-005 remains UNVERIFIED until the bounded accepted/rejected sample file is directly reviewed. No news factor is defined by this run.')
    $summaryMdPath = Join-Path $OutputRoot 'stage3-match-summary.md'
    Write-Utf8NoBom -Path $summaryMdPath -Content $b.ToString()

    Write-Host 'CFA STAGE 3 KRAKEN / GDELT NEWS MATCHING: COMPLETE'
    Write-Host ('Evidence directory: '+$OutputRoot)
    Write-Host ('Rows scanned: '+$totalRows)
    Write-Host ('Unique asset/record matches: '+$matchesOut.Count)
    Write-Host ('Context rejects: '+$rejectedAliasHits)
    Write-Host ('CFA-S3-004 full Q2 matching run: '+$runGate)
    Write-Host 'CFA-S3-005 bounded sample review: UNVERIFIED'
    Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
    if ($runGate -ne 'PASS') { exit 2 }
    exit 0
}
catch {
    Write-Host 'CFA STAGE 3 KRAKEN / GDELT NEWS MATCHING: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
