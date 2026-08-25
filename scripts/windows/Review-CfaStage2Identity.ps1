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

function Get-Sha256Text {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Normalize-BoolText {
    param([AllowNull()][object]$Value)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return 'True' }
    if ($text -eq 'false') { return 'False' }
    return ''
}

function Get-MappingReviewState {
    param([int]$CandidateCount)
    if ($CandidateCount -eq 0) { return 'UNVERIFIED_NO_CURRENT_CANDIDATE' }
    if ($CandidateCount -eq 1) { return 'UNVERIFIED_SINGLE_CANDIDATE_REVIEW_REQUIRED' }
    return 'UNVERIFIED_AMBIGUOUS_CANDIDATES' }
}

function Set-Equals {
    param([string[]]$A,[string[]]$B)
    $aa = @($A | Sort-Object -Unique)
    $bb = @($B | Sort-Object -Unique)
    if ($aa.Count -ne $bb.Count) { return $false }
    for ($i=0; $i -lt $aa.Count; $i++) { if ($aa[$i] -ne $bb[$i]) { return $false } }
    return $true
}

function Invoke-SelfTest {
    if ((Get-MappingReviewState -CandidateCount 0) -ne 'UNVERIFIED_NO_CURRENT_CANDIDATE') { throw 'Self-test failed: zero-candidate state.' }
    if ((Get-MappingReviewState -CandidateCount 1) -ne 'UNVERIFIED_SINGLE_CANDIDATE_REVIEW_REQUIRED') { throw 'Self-test failed: single-candidate state.' }
    if ((Get-MappingReviewState -CandidateCount 2) -ne 'UNVERIFIED_AMBIGUOUS_CANDIDATES') { throw 'Self-test failed: ambiguous state.' }
    if (-not (Set-Equals -A @('a','b') -B @('b','a'))) { throw 'Self-test failed: set equality.' }
    if ((Get-Sha256Text -Text '') -ne 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') { throw 'Self-test failed: SHA-256.' }
    if ((Normalize-BoolText -Value 'TRUE') -ne 'True') { throw 'Self-test failed: boolean normalization.' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

    $pairPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    $candidatePath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv'
    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv'
    foreach ($path in @($pairPath,$candidatePath,$aliasPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required Stage 2 source file missing: $path" } }

    $pairs = @(Import-Csv -LiteralPath $pairPath)
    $candidates = @(Import-Csv -LiteralPath $candidatePath)
    $aliases = @(Import-Csv -LiteralPath $aliasPath)
    $eligiblePairs = @($pairs | Where-Object { (Normalize-BoolText -Value $_.research_eligible) -eq 'True' })

    $pairGroups = @{}
    foreach ($row in $eligiblePairs) {
        $id = [string]$row.base_asset_id
        if (-not $pairGroups.ContainsKey($id)) { $pairGroups[$id] = @() }
        $pairGroups[$id] += $row
    }

    $candidateByBase = @{}
    foreach ($row in $candidates) {
        $id = [string]$row.base_asset_id
        if ($candidateByBase.ContainsKey($id)) { throw "Duplicate candidate row for base_asset_id: $id" }
        $candidateByBase[$id] = $row
    }

    $marketBaseIds = @($pairGroups.Keys | Sort-Object)
    $candidateBaseIds = @($candidateByBase.Keys | Sort-Object)

    $reviewRows = @()
    $jsonHashMismatch = 0
    $jsonParseFailure = 0
    $jsonCountMismatch = 0
    $candidateIdMismatch = 0
    $pairCountMismatch = 0
    $observationCountMismatch = 0
    $exchangeSymbolMismatch = 0
    $approvedSourceRows = 0
    $candidateRecordTotal = 0L

    foreach ($baseId in $candidateBaseIds) {
        $row = $candidateByBase[$baseId]
        $marketRows = if ($pairGroups.ContainsKey($baseId)) { @($pairGroups[$baseId]) } else { @() }
        $observedPairCount = $marketRows.Count
        $observedObs = 0L
        foreach ($m in $marketRows) { $observedObs += [long]$m.typed_observation_count }
        $symbols = @($marketRows | ForEach-Object { [string]$_.base_exchange_symbol } | Sort-Object -Unique)
        $observedSymbol = if ($symbols.Count -eq 1) { $symbols[0] } else { ($symbols -join '|') }

        $pairCountStatus = if ($observedPairCount -eq [int]$row.q2_pair_count) { 'PASS' } else { $pairCountMismatch++; 'FAIL' }
        $obsCountStatus = if ($observedObs -eq [long]$row.q2_typed_observation_count) { 'PASS' } else { $observationCountMismatch++; 'FAIL' }
        $symbolStatus = if ($symbols.Count -eq 1 -and $observedSymbol -eq [string]$row.base_exchange_symbol) { 'PASS' } else { $exchangeSymbolMismatch++; 'FAIL' }

        $jsonStatus = 'PASS'
        $jsonCountStatus = 'PASS'
        $idSetStatus = 'PASS'
        $parsed = @()
        try { $parsed = @(([string]$row.candidate_records_json) | ConvertFrom-Json) }
        catch { $jsonParseFailure++; $jsonStatus = 'FAIL' }

        $candidateCount = [int]$row.current_candidate_count
        $candidateRecordTotal += $candidateCount
        if ($jsonStatus -eq 'PASS' -and $parsed.Count -ne $candidateCount) { $jsonCountMismatch++; $jsonCountStatus = 'FAIL' }
        if ($jsonStatus -eq 'PASS') {
            $parsedIds = @($parsed | ForEach-Object { [string]$_.id })
            $declaredIds = if ([string]::IsNullOrWhiteSpace([string]$row.current_candidate_ids)) { @() } else { @(([string]$row.current_candidate_ids) -split '\|') }
            if (-not (Set-Equals -A $parsedIds -B $declaredIds)) { $candidateIdMismatch++; $idSetStatus = 'FAIL' }
        }

        $hashObserved = Get-Sha256Text -Text ([string]$row.candidate_records_json)
        $hashStatus = if ($hashObserved -eq ([string]$row.candidate_records_sha256).ToLowerInvariant()) { 'PASS' } else { $jsonHashMismatch++; 'FAIL' }
        if ((Normalize-BoolText -Value $row.mapping_approved) -eq 'True') { $approvedSourceRows++ }

        $reviewRows += [pscustomobject]@{
            base_asset_id=$baseId
            base_exchange_symbol=[string]$row.base_exchange_symbol
            market_pair_count_observed=$observedPairCount
            candidate_pair_count_recorded=[int]$row.q2_pair_count
            pair_count_status=$pairCountStatus
            market_observation_count_observed=$observedObs
            candidate_observation_count_recorded=[long]$row.q2_typed_observation_count
            observation_count_status=$obsCountStatus
            market_exchange_symbol_observed=$observedSymbol
            exchange_symbol_status=$symbolStatus
            current_candidate_count=$candidateCount
            current_candidate_ids=[string]$row.current_candidate_ids
            current_candidate_names=[string]$row.current_candidate_names
            candidate_json_parse_status=$jsonStatus
            candidate_json_count_status=$jsonCountStatus
            candidate_id_set_status=$idSetStatus
            candidate_json_sha256_status=$hashStatus
            source_mapping_status=[string]$row.mapping_status
            source_mapping_approved=(Normalize-BoolText -Value $row.mapping_approved)
            cfa_mapping_decision='UNVERIFIED'
            cfa_mapping_review_state=(Get-MappingReviewState -CandidateCount $candidateCount)
            cfa_mapping_decision_basis='CoinGecko candidate scan only; R-009 requires independent review and explicit approval or rejection.'
        }
    }

    $aliasRows = @()
    $aliasMissingBase = 0
    $aliasDuplicate = 0
    $aliasMalformedContext = 0
    $aliasKeySeen = @{}
    foreach ($row in $aliases) {
        $baseId = [string]$row.base_asset_id
        $aliasText = [string]$row.alias_text
        $key = $baseId + '|' + $aliasText.ToLowerInvariant()
        if ($aliasKeySeen.ContainsKey($key)) { $aliasDuplicate++ } else { $aliasKeySeen[$key] = $true }
        $baseStatus = if ($candidateByBase.ContainsKey($baseId)) { 'PASS' } else { $aliasMissingBase++; 'FAIL' }
        $context = Normalize-BoolText -Value $row.requires_crypto_context
        $contextStatus = if ($context -in @('True','False')) { 'PASS' } else { $aliasMalformedContext++; 'FAIL' }
        $aliasRows += [pscustomobject]@{
            base_asset_id=$baseId
            alias_text=$aliasText
            alias_type=[string]$row.alias_type
            requires_crypto_context=$context
            mapping_tier=[string]$row.mapping_tier
            structural_base_link_status=$baseStatus
            context_flag_status=$contextStatus
            cfa_alias_semantic_status='UNVERIFIED'
            cfa_alias_review_basis='Manual seed reference only; R-010 requires validation against raw news before semantic approval.'
        }
    }

    $aliasBaseIds = @($aliases | ForEach-Object { [string]$_.base_asset_id } | Sort-Object -Unique)

    $gates = @()
    $gates += [pscustomobject]@{ gate_id='CFA-S2-001'; gate_name='Eligible Kraken base-asset universe reconciliation'; status=if($eligiblePairs.Count -eq 1058 -and $marketBaseIds.Count -eq 435 -and (Set-Equals -A $marketBaseIds -B $candidateBaseIds)){'PASS'}else{'FAIL'}; observed=("eligible_pairs={0}; market_assets={1}; candidate_assets={2}" -f $eligiblePairs.Count,$marketBaseIds.Count,$candidateBaseIds.Count); expected='1058 eligible pairs; 435 identical base assets' }
    $gates += [pscustomobject]@{ gate_id='CFA-S2-002'; gate_name='CoinGecko candidate-file structural integrity'; status=if($candidates.Count -eq 435 -and $jsonParseFailure -eq 0 -and $jsonHashMismatch -eq 0 -and $jsonCountMismatch -eq 0 -and $candidateIdMismatch -eq 0 -and $pairCountMismatch -eq 0 -and $observationCountMismatch -eq 0 -and $exchangeSymbolMismatch -eq 0){'PASS'}else{'FAIL'}; observed=("rows={0}; candidate_records={1}; json_parse_fail={2}; hash_mismatch={3}; json_count_mismatch={4}; id_set_mismatch={5}; pair_mismatch={6}; obs_mismatch={7}; symbol_mismatch={8}" -f $candidates.Count,$candidateRecordTotal,$jsonParseFailure,$jsonHashMismatch,$jsonCountMismatch,$candidateIdMismatch,$pairCountMismatch,$observationCountMismatch,$exchangeSymbolMismatch); expected='435 internally reconciled rows; zero structural mismatches' }
    $gates += [pscustomobject]@{ gate_id='CFA-S2-003'; gate_name='CoinGecko mapping decisions'; status='UNVERIFIED'; observed=("source_approved={0}; single={1}; ambiguous={2}; none={3}" -f $approvedSourceRows,@($reviewRows | Where-Object {$_.current_candidate_count -eq 1}).Count,@($reviewRows | Where-Object {$_.current_candidate_count -gt 1}).Count,@($reviewRows | Where-Object {$_.current_candidate_count -eq 0}).Count); expected='Explicit CFA approve/reject decision for each asset based on independent review' }
    $gates += [pscustomobject]@{ gate_id='CFA-S2-004'; gate_name='Alias seed structural linkage'; status=if($aliases.Count -eq 45 -and $aliasBaseIds.Count -eq 43 -and $aliasMissingBase -eq 0 -and $aliasDuplicate -eq 0 -and $aliasMalformedContext -eq 0){'PASS'}else{'FAIL'}; observed=("rows={0}; assets={1}; missing_base={2}; duplicates={3}; malformed_context={4}" -f $aliases.Count,$aliasBaseIds.Count,$aliasMissingBase,$aliasDuplicate,$aliasMalformedContext); expected='45 rows; 43 assets; zero structural failures' }
    $gates += [pscustomobject]@{ gate_id='CFA-S2-005'; gate_name='Alias semantic validation'; status='UNVERIFIED'; observed='manual seed references only'; expected='Validated against CFA raw GDELT source before approval' }
    $gates += [pscustomobject]@{ gate_id='CFA-S2-006'; gate_name='Advance to news matching definition'; status='BLOCKED'; observed='CFA-S2-003 and CFA-S2-005 unresolved'; expected='All required Stage 2 identity/mapping/alias gates PASS or justified NOT_APPLICABLE' }

    $queuePath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-CoinGecko-Review-Queue.csv'
    $aliasReviewPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Alias-Review.csv'
    $reviewRows | Sort-Object @{Expression='current_candidate_count';Descending=$true}, @{Expression='market_observation_count_observed';Descending=$true}, base_asset_id | Export-Csv -LiteralPath $queuePath -NoTypeInformation -Encoding UTF8
    $aliasRows | Sort-Object base_asset_id,alias_text | Export-Csv -LiteralPath $aliasReviewPath -NoTypeInformation -Encoding UTF8

    $snapshot = [ordered]@{
        source_files=[ordered]@{
            AF_001=[ordered]@{ file_name=[System.IO.Path]::GetFileName($pairPath); sha256=(Get-FileHash -LiteralPath $pairPath -Algorithm SHA256).Hash.ToLowerInvariant(); rows=$pairs.Count }
            AF_002=[ordered]@{ file_name=[System.IO.Path]::GetFileName($candidatePath); sha256=(Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant(); rows=$candidates.Count }
            AF_003=[ordered]@{ file_name=[System.IO.Path]::GetFileName($aliasPath); sha256=(Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant(); rows=$aliases.Count }
        }
        counts=[ordered]@{
            eligible_pair_rows=$eligiblePairs.Count
            eligible_base_assets=$marketBaseIds.Count
            candidate_rows=$candidates.Count
            current_candidate_records=$candidateRecordTotal
            single_candidate_assets=@($reviewRows | Where-Object {$_.current_candidate_count -eq 1}).Count
            ambiguous_candidate_assets=@($reviewRows | Where-Object {$_.current_candidate_count -gt 1}).Count
            no_candidate_assets=@($reviewRows | Where-Object {$_.current_candidate_count -eq 0}).Count
            source_mapping_approved_rows=$approvedSourceRows
            alias_rows=$aliases.Count
            alias_assets=$aliasBaseIds.Count
        }
        gates=$gates
    }
    $jsonPath = Join-Path $RepoRoot 'docs\evidence\stage2-identity-review.json'
    Write-Utf8NoBom -Path $jsonPath -Content (($snapshot | ConvertTo-Json -Depth 12) + [Environment]::NewLine)

    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Stage 2 Identity / Mapping / Alias Structural Review')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('This receipt is derived only from the current SoT-registered AF-001/AF-002/AF-003 files. It does not approve CoinGecko mappings or alias semantics. Candidate and manual-alias records remain references until independently reviewed under R-009/R-010.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Counts')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- Eligible Kraken pair rows: ' + $eligiblePairs.Count)
    [void]$b.AppendLine('- Eligible base assets: ' + $marketBaseIds.Count)
    [void]$b.AppendLine('- CoinGecko candidate rows: ' + $candidates.Count)
    [void]$b.AppendLine('- Current candidate records: ' + $candidateRecordTotal)
    [void]$b.AppendLine('- Single-candidate assets: ' + @($reviewRows | Where-Object {$_.current_candidate_count -eq 1}).Count)
    [void]$b.AppendLine('- Ambiguous-candidate assets: ' + @($reviewRows | Where-Object {$_.current_candidate_count -gt 1}).Count)
    [void]$b.AppendLine('- No-current-candidate assets: ' + @($reviewRows | Where-Object {$_.current_candidate_count -eq 0}).Count)
    [void]$b.AppendLine('- Source-approved mappings: ' + $approvedSourceRows)
    [void]$b.AppendLine('- Alias rows / assets: ' + $aliases.Count + ' / ' + $aliasBaseIds.Count)
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Hard gates')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('| Gate | Status | Observed | Expected |')
    [void]$b.AppendLine('|---|---|---|---|')
    foreach ($g in $gates) { [void]$b.AppendLine('| ' + $g.gate_id + ' ' + $g.gate_name + ' | ' + $g.status + ' | ' + ([string]$g.observed).Replace('|','\|') + ' | ' + ([string]$g.expected).Replace('|','\|') + ' |') }
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Decision boundary')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('CFA-S2-001/002/004 test structural identity consistency only. CFA-S2-003 remains UNVERIFIED because the candidate scan is not independent mapping approval. CFA-S2-005 remains UNVERIFIED because manual aliases have not yet been validated against the CFA-owned raw GDELT archive set. News matching definition remains BLOCKED until those upstream decisions are resolved.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Derived review files:')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- candidate-analysis/CFA-Stage2-CoinGecko-Review-Queue.csv')
    [void]$b.AppendLine('- candidate-analysis/CFA-Stage2-Alias-Review.csv')
    $mdPath = Join-Path $RepoRoot 'docs\evidence\stage2-identity-review.md'
    Write-Utf8NoBom -Path $mdPath -Content $b.ToString()

    $failCount = @($gates | Where-Object {$_.status -eq 'FAIL'}).Count
    Write-Host ('Stage 2 structural FAIL gates: ' + $failCount)
    foreach ($g in $gates) { Write-Host ($g.gate_id + ' ' + $g.status + ' - ' + $g.gate_name) }
    if ($failCount -gt 0) { exit 2 }
    Write-Host 'CFA STAGE 2 STRUCTURAL REVIEW: COMPLETE'
}
catch {
    Write-Host 'CFA STAGE 2 STRUCTURAL REVIEW: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
