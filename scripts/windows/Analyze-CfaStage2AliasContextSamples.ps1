#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = '',
    [string]$RecoveryRoot = '',
    [string]$OutputRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedFieldCount = 27
$RecordIdIndex = 0
$SourceCommonNameIndex = 3
$DocumentIdentifierIndex = 4
$V2ThemesIndex = 8
$ExtrasIndex = 26

$StrongCryptoRegex = New-Object System.Text.RegularExpressions.Regex(
    '(?<![\p{L}\p{N}])(?:crypto(?:currency|currencies)?|blockchain|defi|web3|nfts?|stablecoins?|altcoins?|memecoins?|meme\s+coins?|airdrops?|staking|wallets?|digital\s+assets?)(?![\p{L}\p{N}])',
    ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
)
$MediumCryptoRegex = New-Object System.Text.RegularExpressions.Regex(
    '(?<![\p{L}\p{N}])(?:tokens?|coins?|price(?:s)?|market\s+cap(?:italization)?|trading\s+volume|exchanges?|etfs?|protocols?|chains?)(?![\p{L}\p{N}])',
    ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
)

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}

function Get-Sha256String {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-PageTitle {
    param([string]$Extras)
    if ([string]::IsNullOrWhiteSpace($Extras)) { return '' }
    $m = [regex]::Match($Extras,'<PAGE_TITLE>(.*?)</PAGE_TITLE>',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return '' }
    return [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}

function Get-V2ThemeNames {
    param([string]$Text)
    $set = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $set }
    foreach ($block in @($Text -split ';')) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $comma = $block.LastIndexOf(',')
        $name = if ($comma -gt 0) { $block.Substring(0,$comma).Trim() } else { $block.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($name)) { $set[$name.ToUpperInvariant()] = $true }
    }
    return $set
}

function Get-MatchedTerms {
    param([System.Text.RegularExpressions.Regex]$Regex,[string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Regex.Matches($Text) | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-LatestRecoveryRun {
    param([string]$Parent)
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw "Alias recovery root missing: $Parent" }
    foreach ($run in @(Get-ChildItem -LiteralPath $Parent -Directory -Force | Sort-Object Name -Descending)) {
        $summaryPath = Join-Path $run.FullName 'recovery-summary.csv'
        $aliasPath = Join-Path $run.FullName 'alias-recovery.csv'
        $samplePath = Join-Path $run.FullName 'alias-recovery-samples.csv'
        if (-not ((Test-Path -LiteralPath $summaryPath -PathType Leaf) -and (Test-Path -LiteralPath $aliasPath -PathType Leaf) -and (Test-Path -LiteralPath $samplePath -PathType Leaf))) { continue }
        $summary = @(Import-Csv -LiteralPath $summaryPath)
        $aliases = @(Import-Csv -LiteralPath $aliasPath)
        if ($summary.Count -ne 1 -or $aliases.Count -ne 45) { continue }
        if ([int]$summary[0].archive_files -ne 7163) { continue }
        if ([long]$summary[0].quarantined_rows -ne [long]$summary[0].expected_quarantined_rows) { continue }
        return $run
    }
    throw "No valid alias recovery run found under: $Parent"
}

function New-AliasRegexAndMap {
    param([object[]]$AliasRows)
    $aliasToBases = @{}
    $texts = @()
    foreach ($row in $AliasRows) {
        $text = ([string]$row.alias_text).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $norm = $text.ToLowerInvariant()
        if (-not $aliasToBases.ContainsKey($norm)) { $aliasToBases[$norm] = @{} }
        $aliasToBases[$norm][[string]$row.base_asset_id] = $true
        $texts += $text
    }
    $parts = @($texts | Sort-Object -Unique | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    $rx = New-Object System.Text.RegularExpressions.Regex(
        ('(?<![\p{L}\p{N}])(?:' + ($parts -join '|') + ')(?![\p{L}\p{N}])'),
        ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    )
    return [pscustomobject]@{regex=$rx;alias_to_bases=$aliasToBases}
}

function Get-OtherAliasBases {
    param(
        [System.Text.RegularExpressions.Regex]$AliasRegex,
        [hashtable]$AliasToBases,
        [string]$Title,
        [string]$CurrentBase
    )
    $bases = @{}
    if ([string]::IsNullOrWhiteSpace($Title)) { return $bases }
    foreach ($m in @($AliasRegex.Matches($Title))) {
        $norm = $m.Value.ToLowerInvariant()
        if (-not $AliasToBases.ContainsKey($norm)) { continue }
        foreach ($base in $AliasToBases[$norm].Keys) {
            if ([string]$base -ne $CurrentBase) { $bases[[string]$base] = $true }
        }
    }
    return $bases
}

function Invoke-SelfTest {
    $themes = Get-V2ThemeNames 'ECON_BITCOIN,10;TAX_FNCACT_INVESTOR,20;'
    if (-not $themes.ContainsKey('ECON_BITCOIN')) { throw 'theme parser' }
    $title = Get-PageTitle 'x<PAGE_TITLE>Bitcoin &amp; crypto rally</PAGE_TITLE>y'
    if ($title -ne 'Bitcoin & crypto rally') { throw 'title parser' }
    $strong = @(Get-MatchedTerms -Regex $StrongCryptoRegex -Text $title)
    if ($strong -notcontains 'crypto') { throw 'strong lexical anchor' }
    $aliases = @(
        [pscustomobject]@{base_asset_id='XXBT';alias_text='Bitcoin'},
        [pscustomobject]@{base_asset_id='XETH';alias_text='Ethereum'},
        [pscustomobject]@{base_asset_id='XXBT';alias_text='BTC'}
    )
    $x = New-AliasRegexAndMap -AliasRows $aliases
    $other = Get-OtherAliasBases -AliasRegex $x.regex -AliasToBases $x.alias_to_bases -Title 'Bitcoin and Ethereum rally' -CurrentBase 'XXBT'
    if ($other.Count -ne 1 -or -not $other.ContainsKey('XETH')) { throw 'other alias base detection' }
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
    if ([string]::IsNullOrWhiteSpace($RecoveryRoot)) { $RecoveryRoot = Join-Path $docs 'CFA-local\gdelt-alias-recovery' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $docs 'CFA-local\gdelt-alias-context-samples' }
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $RecoveryRoot = (Resolve-Path -LiteralPath $RecoveryRoot).ProviderPath
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }

    $recoveryRun = Get-LatestRecoveryRun -Parent $RecoveryRoot
    $samplePath = Join-Path $recoveryRun.FullName 'alias-recovery-samples.csv'
    $samples = @(Import-Csv -LiteralPath $samplePath)
    if ($samples.Count -le 0) { throw 'Alias recovery sample set is empty.' }

    $aliasSeedPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv'
    $aliasSeeds = @(Import-Csv -LiteralPath $aliasSeedPath)
    if ($aliasSeeds.Count -ne 45) { throw "Expected 45 alias seeds; observed $($aliasSeeds.Count)." }
    $aliasTools = New-AliasRegexAndMap -AliasRows $aliasSeeds

    $rawByName = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip')) {
        if ($rawByName.ContainsKey($file.Name)) { throw "Duplicate raw archive filename: $($file.Name)" }
        $rawByName[$file.Name] = $file.FullName
    }

    $samplesByArchive = @{}
    foreach ($sample in $samples) {
        $date = [string]$sample.date_utc
        if ($date -notmatch '^\d{14}$') { throw "Malformed sample date_utc: $date" }
        $archiveName = $date + '.gkg.csv.zip'
        if (-not $samplesByArchive.ContainsKey($archiveName)) { $samplesByArchive[$archiveName] = @() }
        $samplesByArchive[$archiveName] += $sample
    }

    $results = @()
    $foundCount = 0
    $lenientUtf8 = New-Object System.Text.UTF8Encoding($false,$false)
    $archiveOrdinal = 0
    foreach ($archiveName in @($samplesByArchive.Keys | Sort-Object)) {
        $archiveOrdinal++
        if (($archiveOrdinal % 50) -eq 0 -or $archiveOrdinal -eq 1) { Write-Host ("Context sample archives: {0}/{1}" -f $archiveOrdinal,$samplesByArchive.Count) }
        if (-not $rawByName.ContainsKey($archiveName)) { throw "Raw archive missing for sample diagnostic: $archiveName" }
        $targets = @{}
        foreach ($sample in @($samplesByArchive[$archiveName])) {
            $rid = [string]$sample.record_id
            if (-not $targets.ContainsKey($rid)) { $targets[$rid] = @() }
            $targets[$rid] += $sample
        }

        $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$rawByName[$archiveName])
        try {
            $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
            if ($entries.Count -ne 1) { throw "Expected one ZIP entry in $archiveName; observed $($entries.Count)." }
            $stream = $entries[0].Open()
            $reader = $null
            try {
                $reader = New-Object System.IO.StreamReader($stream,$lenientUtf8,$false,65536,$false)
                while (($line = $reader.ReadLine()) -ne $null) {
                    $fields = $line.Split([char]9)
                    if ($fields.Count -ne $ExpectedFieldCount) { continue }
                    $rid = [string]$fields[$RecordIdIndex]
                    if (-not $targets.ContainsKey($rid)) { continue }
                    $title = Get-PageTitle -Extras $fields[$ExtrasIndex]
                    $themeNames = Get-V2ThemeNames -Text $fields[$V2ThemesIndex]
                    $strongTerms = @(Get-MatchedTerms -Regex $StrongCryptoRegex -Text $title)
                    $mediumTerms = @(Get-MatchedTerms -Regex $MediumCryptoRegex -Text $title)
                    foreach ($sample in @($targets[$rid])) {
                        if ([string]$fields[$DocumentIdentifierIndex] -ne [string]$sample.document_identifier) { throw "Document identifier mismatch for $rid" }
                        $otherBases = Get-OtherAliasBases -AliasRegex $aliasTools.regex -AliasToBases $aliasTools.alias_to_bases -Title $title -CurrentBase ([string]$sample.base_asset_id)
                        $econBitcoin = $themeNames.ContainsKey('ECON_BITCOIN')
                        $strictRule = ($econBitcoin -or $strongTerms.Count -gt 0 -or ($otherBases.Count -gt 0 -and $mediumTerms.Count -gt 0))
                        $broadRule = ($strictRule -or $mediumTerms.Count -gt 0 -or $otherBases.Count -gt 0)
                        $results += [pscustomobject]@{
                            base_asset_id=[string]$sample.base_asset_id
                            alias_text=[string]$sample.alias_text
                            requires_crypto_context=[string]$sample.requires_crypto_context
                            record_id=$rid
                            date_utc=[string]$sample.date_utc
                            source_common_name=[string]$fields[$SourceCommonNameIndex]
                            document_identifier=[string]$fields[$DocumentIdentifierIndex]
                            matched_surfaces=[string]$sample.matched_surfaces
                            prior_candidate_context_anchor=[string]$sample.candidate_context_anchor_present
                            page_title_sha256=(Get-Sha256String -Text $title)
                            econ_bitcoin_theme=$econBitcoin
                            strong_crypto_lexical=($strongTerms.Count -gt 0)
                            strong_anchor_terms=($strongTerms -join '|')
                            medium_crypto_lexical=($mediumTerms.Count -gt 0)
                            medium_anchor_terms=($mediumTerms -join '|')
                            other_asset_alias_count=$otherBases.Count
                            other_asset_aliases=(@($otherBases.Keys | Sort-Object) -join '|')
                            candidate_context_rule_strict=$strictRule
                            candidate_context_rule_broad=$broadRule
                        }
                        $foundCount++
                    }
                    $targets.Remove($rid)
                    if ($targets.Count -eq 0) { break }
                }
            }
            finally { if ($null -ne $reader) { $reader.Dispose() } else { $stream.Dispose() } }
        }
        finally { $zip.Dispose() }
        if ($targets.Count -ne 0) { throw "Unresolved sample record IDs remain in $archiveName: $(@($targets.Keys) -join ',')" }
    }

    if ($foundCount -ne $samples.Count -or $results.Count -ne $samples.Count) { throw "Sample accounting mismatch: expected=$($samples.Count) found=$foundCount results=$($results.Count)" }

    $aliasSummary = @()
    foreach ($group in @($results | Group-Object base_asset_id,alias_text)) {
        $rows = @($group.Group)
        $first = $rows[0]
        $aliasSummary += [pscustomobject]@{
            base_asset_id=[string]$first.base_asset_id
            alias_text=[string]$first.alias_text
            requires_crypto_context=[string]$first.requires_crypto_context
            sample_rows=$rows.Count
            econ_bitcoin_theme_rows=@($rows | Where-Object { $_.econ_bitcoin_theme -eq $true }).Count
            strong_crypto_lexical_rows=@($rows | Where-Object { $_.strong_crypto_lexical -eq $true }).Count
            medium_crypto_lexical_rows=@($rows | Where-Object { $_.medium_crypto_lexical -eq $true }).Count
            other_asset_alias_rows=@($rows | Where-Object { [int]$_.other_asset_alias_count -gt 0 }).Count
            strict_rule_rows=@($rows | Where-Object { $_.candidate_context_rule_strict -eq $true }).Count
            broad_rule_rows=@($rows | Where-Object { $_.candidate_context_rule_broad -eq $true }).Count
            prior_anchor_rows=@($rows | Where-Object { [string]$_.prior_candidate_context_anchor -eq 'True' }).Count
        }
    }

    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $runDir = Join-Path $OutputRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $results | Sort-Object base_asset_id,alias_text,date_utc,record_id | Export-Csv -LiteralPath (Join-Path $runDir 'sample-context-evidence.csv') -NoTypeInformation -Encoding UTF8
    $aliasSummary | Sort-Object base_asset_id,alias_text | Export-Csv -LiteralPath (Join-Path $runDir 'alias-context-summary.csv') -NoTypeInformation -Encoding UTF8
    @([pscustomobject]@{
        run_id=$runId
        source_recovery_run=$recoveryRun.Name
        sample_rows=$samples.Count
        aliases_with_samples=@($aliasSummary).Count
        archive_files_opened=$samplesByArchive.Count
        matching_theme='ECON_BITCOIN'
        strong_lexical_terms='crypto|cryptocurrency|cryptocurrencies|blockchain|defi|web3|nft|nfts|stablecoin|stablecoins|altcoin|altcoins|memecoin|memecoins|meme coin|meme coins|airdrop|airdrops|staking|wallet|wallets|digital asset|digital assets'
        medium_lexical_terms='token|tokens|coin|coins|price|prices|market cap|market capitalization|trading volume|exchange|exchanges|etf|etfs|protocol|protocols|chain|chains'
        rule_status='DIAGNOSTIC_ONLY_NOT_APPROVED'
    }) | Export-Csv -LiteralPath (Join-Path $runDir 'context-diagnostic-summary.csv') -NoTypeInformation -Encoding UTF8

    Write-Host "Evidence directory: $runDir"
    Write-Host "Sample rows analyzed: $($samples.Count)"
    Write-Host "Aliases with samples: $($aliasSummary.Count)"
    Write-Host "Archives opened: $($samplesByArchive.Count)"
    Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE DIAGNOSTIC: PASS'
}
catch {
    Write-Host 'CFA STAGE 2 ALIAS CONTEXT SAMPLE DIAGNOSTIC: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
