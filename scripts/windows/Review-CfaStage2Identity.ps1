#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}

function Normalize-BoolText {
    param([AllowNull()][object]$Value)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return 'True' }
    if ($text -eq 'false') { return 'False' }
    return ''
}

function Set-Equals {
    param([string[]]$A,[string[]]$B)
    $aa = @($A | Sort-Object -Unique)
    $bb = @($B | Sort-Object -Unique)
    if ($aa.Count -ne $bb.Count) { return $false }
    for ($i=0; $i -lt $aa.Count; $i++) { if ($aa[$i] -ne $bb[$i]) { return $false } }
    return $true
}

function Get-AliasKey {
    param([string]$Base,[string]$Alias)
    return $Base + '|' + $Alias.Trim().ToLowerInvariant()
}

function Invoke-SelfTest {
    if (-not (Set-Equals -A @('a','b') -B @('b','a'))) { throw 'set equality' }
    if ((Normalize-BoolText 'TRUE') -ne 'True' -or (Normalize-BoolText 'false') -ne 'False') { throw 'bool normalization' }
    if ((Get-AliasKey -Base 'XXBT' -Alias 'Bitcoin') -ne 'XXBT|bitcoin') { throw 'alias key' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

    $pairPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv'
    $semanticPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Alias-Semantic-Decisions.csv'
    foreach ($p in @($pairPath,$aliasPath,$semanticPath)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing source: $p" } }

    $pairs = @(Import-Csv -LiteralPath $pairPath)
    $aliases = @(Import-Csv -LiteralPath $aliasPath)
    $semantic = @(Import-Csv -LiteralPath $semanticPath)
    $eligiblePairs = @($pairs | Where-Object { (Normalize-BoolText $_.research_eligible) -eq 'True' })
    $marketIds = @($eligiblePairs | ForEach-Object { [string]$_.base_asset_id } | Sort-Object -Unique)
    $marketSet = @{}; foreach ($id in $marketIds) { $marketSet[$id] = $true }

    $semanticByKey = @{}
    $semanticDuplicate = 0
    foreach ($s in $semantic) {
        $key = Get-AliasKey -Base ([string]$s.base_asset_id) -Alias ([string]$s.alias_text)
        if ($semanticByKey.ContainsKey($key)) { $semanticDuplicate++; continue }
        $semanticByKey[$key] = $s
    }

    $aliasReview = @()
    $aliasMissing = 0; $aliasDup = 0; $aliasBadContext = 0; $semanticMissing = 0; $semanticMismatch = 0; $semanticUnapproved = 0
    $seen = @{}
    foreach ($a in $aliases) {
        $id = [string]$a.base_asset_id
        $text = [string]$a.alias_text
        $key = Get-AliasKey -Base $id -Alias $text
        if ($seen.ContainsKey($key)) { $aliasDup++ } else { $seen[$key] = $true }

        $link = 'PASS'
        if (-not $marketSet.ContainsKey($id)) { $link = 'FAIL'; $aliasMissing++ }

        $context = Normalize-BoolText $a.requires_crypto_context
        $contextStatus = 'PASS'
        if ($context -notin @('True','False')) { $contextStatus = 'FAIL'; $aliasBadContext++ }

        $semanticStatus = 'UNVERIFIED'
        if (-not $semanticByKey.ContainsKey($key)) {
            $semanticMissing++
        } else {
            $s = $semanticByKey[$key]
            $semanticStatus = [string]$s.semantic_decision
            if ([string]$s.alias_type -ne [string]$a.alias_type -or (Normalize-BoolText $s.source_requires_crypto_context) -ne $context) { $semanticMismatch++ }
            if ($semanticStatus -ne 'APPROVED_ALIAS_IDENTITY') { $semanticUnapproved++ }
        }

        $aliasReview += [pscustomobject]@{
            base_asset_id=$id
            alias_text=$text
            alias_type=[string]$a.alias_type
            requires_crypto_context=$context
            structural_base_link_status=$link
            context_flag_status=$contextStatus
            cfa_alias_semantic_status=$semanticStatus
        }
    }

    $aliasAssets = @($aliases | ForEach-Object { [string]$_.base_asset_id } | Sort-Object -Unique)
    $approvedSemantic = @($semantic | Where-Object { [string]$_.semantic_decision -eq 'APPROVED_ALIAS_IDENTITY' }).Count

    $s2_001 = if ($eligiblePairs.Count -eq 1058 -and $marketIds.Count -eq 435) { 'PASS' } else { 'FAIL' }
    $s2_004 = if ($aliases.Count -eq 45 -and $aliasAssets.Count -eq 43 -and $aliasMissing -eq 0 -and $aliasDup -eq 0 -and $aliasBadContext -eq 0) { 'PASS' } else { 'FAIL' }
    $s2_005 = if ($semantic.Count -eq 45 -and $approvedSemantic -eq 45 -and $semanticDuplicate -eq 0 -and $semanticMissing -eq 0 -and $semanticMismatch -eq 0 -and $semanticUnapproved -eq 0) { 'PASS' } else { 'UNVERIFIED' }
    $s2_006 = if ($s2_001 -eq 'PASS' -and $s2_004 -eq 'PASS' -and $s2_005 -eq 'PASS') { 'PASS' } else { 'BLOCKED' }

    $gates = @(
        [pscustomobject]@{gate_id='CFA-S2-001';status=$s2_001;name='Eligible Kraken base-asset universe reconciliation';observed=("eligible_pairs={0}; market_assets={1}" -f $eligiblePairs.Count,$marketIds.Count)},
        [pscustomobject]@{gate_id='CFA-S2-002';status='NOT_APPLICABLE';name='CoinGecko candidate-file structural integrity';observed='Removed from active CFA news workflow by user directive 2026-08-27; historical evidence retained only for lineage.'},
        [pscustomobject]@{gate_id='CFA-S2-003';status='NOT_APPLICABLE';name='CoinGecko mapping decisions';observed='Removed from active CFA news workflow by user directive 2026-08-27; no CoinGecko identity is required for GDELT matching.'},
        [pscustomobject]@{gate_id='CFA-S2-004';status=$s2_004;name='Kraken-to-news alias structural linkage';observed=("rows={0}; assets={1}; missing={2}; duplicates={3}; bad_context={4}" -f $aliases.Count,$aliasAssets.Count,$aliasMissing,$aliasDup,$aliasBadContext)},
        [pscustomobject]@{gate_id='CFA-S2-005';status=$s2_005;name='Alias semantic validation';observed=("decision_rows={0}; approved={1}; missing={2}; duplicate={3}; mismatch={4}; unapproved={5}" -f $semantic.Count,$approvedSemantic,$semanticMissing,$semanticDuplicate,$semanticMismatch,$semanticUnapproved)},
        [pscustomobject]@{gate_id='CFA-S2-006';status=$s2_006;name='Advance to news matching definition';observed=if($s2_006-eq'PASS'){'Kraken coverage and all 45 news aliases are validated; CoinGecko is not part of the active news path.'}else{'Kraken or alias readiness remains unresolved.'}}
    )

    $aliasReview | Sort-Object -Property base_asset_id,alias_text | Export-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Alias-Review.csv') -NoTypeInformation -Encoding UTF8

    $snapshot = [ordered]@{
        scope_change='USER_DIRECTIVE_2026-08-27_REMOVE_COINGECKO_FROM_ACTIVE_NEWS_PATH'
        source_hashes=[ordered]@{
            AF_001=(Get-FileHash -LiteralPath $pairPath -Algorithm SHA256).Hash.ToLowerInvariant()
            AF_003=(Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()
            alias_semantic_decisions=(Get-FileHash -LiteralPath $semanticPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        counts=[ordered]@{
            eligible_pair_rows=$eligiblePairs.Count
            eligible_base_assets=$marketIds.Count
            alias_rows=$aliases.Count
            alias_assets=$aliasAssets.Count
            approved_alias_identities=$approvedSemantic
        }
        gates=$gates
    }
    Write-Utf8NoBom -Path (Join-Path $RepoRoot 'docs\evidence\stage2-identity-review.json') -Content (($snapshot | ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Stage 2 Kraken / GDELT Alias Readiness')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Active news identity path: Kraken market asset -> approved AF-003 alias -> raw GDELT record. CoinGecko is NOT_APPLICABLE for news matching and is retained only as historical lineage.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine("Eligible Kraken pair rows: $($eligiblePairs.Count); eligible base assets: $($marketIds.Count); aliases: $($aliases.Count) across $($aliasAssets.Count) assets; approved alias identities: $approvedSemantic.")
    [void]$b.AppendLine('')
    [void]$b.AppendLine('| Gate | Status | Observed |')
    [void]$b.AppendLine('|---|---|---|')
    foreach ($g in $gates) { [void]$b.AppendLine('| '+$g.gate_id+' '+$g.name+' | '+$g.status+' | '+([string]$g.observed).Replace('|','/')+' |') }
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Historical CoinGecko evidence and scripts are not inputs to this active gate and are not required to proceed to Stage 3.')
    Write-Utf8NoBom -Path (Join-Path $RepoRoot 'docs\evidence\stage2-identity-review.md') -Content $b.ToString()

    foreach ($g in $gates) { Write-Host ($g.gate_id+' '+$g.status+' - '+$g.name) }
    Write-Host 'CFA STAGE 2 KRAKEN / GDELT ALIAS READINESS: COMPLETE'
    if ($s2_006 -ne 'PASS') { exit 2 }
    exit 0
}
catch {
    Write-Host 'CFA STAGE 2 KRAKEN / GDELT ALIAS READINESS: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
