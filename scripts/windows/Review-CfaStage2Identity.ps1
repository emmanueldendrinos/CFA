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
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
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

function Get-ReviewState {
    param([int]$Count)
    if ($Count -eq 0) { return 'UNVERIFIED_NO_CURRENT_CANDIDATE' }
    if ($Count -eq 1) { return 'UNVERIFIED_SINGLE_CANDIDATE_REVIEW_REQUIRED' }
    return 'UNVERIFIED_AMBIGUOUS_CANDIDATES'
}

function Invoke-SelfTest {
    if ((Get-ReviewState -Count 0) -ne 'UNVERIFIED_NO_CURRENT_CANDIDATE') { throw 'zero candidate state' }
    if ((Get-ReviewState -Count 1) -ne 'UNVERIFIED_SINGLE_CANDIDATE_REVIEW_REQUIRED') { throw 'single candidate state' }
    if (-not (Set-Equals -A @('a','b') -B @('b','a'))) { throw 'set equality' }
    if ((Get-Sha256Text -Text '') -ne 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') { throw 'sha256' }
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
    $candidatePath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv'
    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv'
    foreach ($p in @($pairPath,$candidatePath,$aliasPath)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Missing source: $p" } }

    $pairs = @(Import-Csv -LiteralPath $pairPath)
    $candidates = @(Import-Csv -LiteralPath $candidatePath)
    $aliases = @(Import-Csv -LiteralPath $aliasPath)
    $eligiblePairs = @($pairs | Where-Object { (Normalize-BoolText $_.research_eligible) -eq 'True' })

    $pairSummary = @{}
    foreach ($p in $eligiblePairs) {
        $id = [string]$p.base_asset_id
        if (-not $pairSummary.ContainsKey($id)) {
            $pairSummary[$id] = [pscustomobject]@{ pair_count=0; obs=0L; symbols=@{} }
        }
        $s = $pairSummary[$id]
        $s.pair_count = [int]$s.pair_count + 1
        $s.obs = [long]$s.obs + [long]$p.typed_observation_count
        $s.symbols[[string]$p.base_exchange_symbol] = $true
    }

    $candidateByBase = @{}
    foreach ($c in $candidates) {
        $id = [string]$c.base_asset_id
        if ($candidateByBase.ContainsKey($id)) { throw "Duplicate candidate base_asset_id: $id" }
        $candidateByBase[$id] = $c
    }

    $marketIds = @($pairSummary.Keys | Sort-Object)
    $candidateIds = @($candidateByBase.Keys | Sort-Object)
    $review = @()
    $candidateTotal = 0L
    $parseFail=0; $shapeFail=0; $hashFail=0; $countFail=0; $idFail=0; $pairFail=0; $obsFail=0; $symbolFail=0; $sourceApproved=0

    foreach ($id in $candidateIds) {
        $c = $candidateByBase[$id]
        $candidateCount = [int]$c.current_candidate_count
        $candidateTotal += $candidateCount
        $summary = $null
        if ($pairSummary.ContainsKey($id)) { $summary = $pairSummary[$id] }
        $pairObserved = if ($null -eq $summary) { 0 } else { [int]$summary.pair_count }
        $obsObserved = if ($null -eq $summary) { 0L } else { [long]$summary.obs }
        $symbolValues = @()
        if ($null -ne $summary) { $symbolValues = @($summary.symbols.Keys | Sort-Object) }
        $symbolObserved = if ($symbolValues.Count -eq 1) { [string]$symbolValues[0] } else { ($symbolValues -join '|') }

        $pairStatus='PASS'; if ($pairObserved -ne [int]$c.q2_pair_count) { $pairStatus='FAIL'; $pairFail++ }
        $obsStatus='PASS'; if ($obsObserved -ne [long]$c.q2_typed_observation_count) { $obsStatus='FAIL'; $obsFail++ }
        $symbolStatus='PASS'; if ($symbolValues.Count -ne 1 -or $symbolObserved -ne [string]$c.base_exchange_symbol) { $symbolStatus='FAIL'; $symbolFail++ }

        $jsonStatus='PASS'; $jsonCountStatus='PASS'; $idStatus='PASS'; $parsed=@()
        try {
            $rawParsed = ([string]$c.candidate_records_json) | ConvertFrom-Json
            if ($null -ne $rawParsed) { $parsed = @($rawParsed) }
        }
        catch { $jsonStatus='FAIL'; $parseFail++ }
        if ($jsonStatus -eq 'PASS' -and $parsed.Count -ne $candidateCount) { $jsonCountStatus='FAIL'; $countFail++ }

        $parsedIds = @()
        if ($jsonStatus -eq 'PASS') {
            foreach ($obj in $parsed) {
                if ($null -eq $obj) { $shapeFail++; continue }
                $idProp = $obj.PSObject.Properties['id']
                if ($null -eq $idProp -or [string]::IsNullOrWhiteSpace([string]$idProp.Value)) { $shapeFail++; continue }
                $parsedIds += [string]$idProp.Value
            }
            $declared = @()
            if (-not [string]::IsNullOrWhiteSpace([string]$c.current_candidate_ids)) { $declared = @(([string]$c.current_candidate_ids) -split '\|') }
            if (-not (Set-Equals -A $parsedIds -B $declared)) { $idStatus='FAIL'; $idFail++ }
        }

        $hashStatus='PASS'
        $hashObserved = Get-Sha256Text -Text ([string]$c.candidate_records_json)
        if ($hashObserved -ne ([string]$c.candidate_records_sha256).ToLowerInvariant()) { $hashStatus='FAIL'; $hashFail++ }
        if ((Normalize-BoolText $c.mapping_approved) -eq 'True') { $sourceApproved++ }

        $review += [pscustomobject]@{
            base_asset_id=$id
            base_exchange_symbol=[string]$c.base_exchange_symbol
            market_pair_count_observed=$pairObserved
            market_observation_count_observed=$obsObserved
            current_candidate_count=$candidateCount
            current_candidate_ids=[string]$c.current_candidate_ids
            current_candidate_names=[string]$c.current_candidate_names
            pair_count_status=$pairStatus
            observation_count_status=$obsStatus
            exchange_symbol_status=$symbolStatus
            candidate_json_parse_status=$jsonStatus
            candidate_json_count_status=$jsonCountStatus
            candidate_id_set_status=$idStatus
            candidate_json_sha256_status=$hashStatus
            source_mapping_approved=(Normalize-BoolText $c.mapping_approved)
            cfa_mapping_decision='UNVERIFIED'
            cfa_mapping_review_state=(Get-ReviewState -Count $candidateCount)
        }
    }

    $aliasReview=@(); $aliasMissing=0; $aliasDup=0; $aliasBadContext=0; $seen=@{}
    foreach ($a in $aliases) {
        $id=[string]$a.base_asset_id; $text=[string]$a.alias_text; $key=$id+'|'+$text.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { $aliasDup++ } else { $seen[$key]=$true }
        $link='PASS'; if (-not $candidateByBase.ContainsKey($id)) { $link='FAIL'; $aliasMissing++ }
        $context=Normalize-BoolText $a.requires_crypto_context
        $contextStatus='PASS'; if ($context -notin @('True','False')) { $contextStatus='FAIL'; $aliasBadContext++ }
        $aliasReview += [pscustomobject]@{
            base_asset_id=$id; alias_text=$text; alias_type=[string]$a.alias_type; requires_crypto_context=$context;
            mapping_tier=[string]$a.mapping_tier; structural_base_link_status=$link; context_flag_status=$contextStatus;
            cfa_alias_semantic_status='UNVERIFIED'
        }
    }

    $aliasAssets=@($aliases | ForEach-Object { [string]$_.base_asset_id } | Sort-Object -Unique)
    $single=@($review | Where-Object {[int]$_.current_candidate_count -eq 1}).Count
    $ambiguous=@($review | Where-Object {[int]$_.current_candidate_count -gt 1}).Count
    $none=@($review | Where-Object {[int]$_.current_candidate_count -eq 0}).Count

    $s2_001='FAIL'; if ($eligiblePairs.Count -eq 1058 -and $marketIds.Count -eq 435 -and (Set-Equals $marketIds $candidateIds)) { $s2_001='PASS' }
    $s2_002='FAIL'; if ($candidates.Count -eq 435 -and $parseFail -eq 0 -and $shapeFail -eq 0 -and $hashFail -eq 0 -and $countFail -eq 0 -and $idFail -eq 0 -and $pairFail -eq 0 -and $obsFail -eq 0 -and $symbolFail -eq 0) { $s2_002='PASS' }
    $s2_004='FAIL'; if ($aliases.Count -eq 45 -and $aliasAssets.Count -eq 43 -and $aliasMissing -eq 0 -and $aliasDup -eq 0 -and $aliasBadContext -eq 0) { $s2_004='PASS' }

    $gates=@()
    $gates += [pscustomobject]@{gate_id='CFA-S2-001';status=$s2_001;name='Eligible Kraken base-asset universe reconciliation';observed=("eligible_pairs={0}; market_assets={1}; candidate_assets={2}" -f $eligiblePairs.Count,$marketIds.Count,$candidateIds.Count)}
    $gates += [pscustomobject]@{gate_id='CFA-S2-002';status=$s2_002;name='CoinGecko candidate-file structural integrity';observed=("rows={0}; candidates={1}; parse_fail={2}; shape_fail={3}; hash_fail={4}; count_fail={5}; id_fail={6}; pair_fail={7}; obs_fail={8}; symbol_fail={9}" -f $candidates.Count,$candidateTotal,$parseFail,$shapeFail,$hashFail,$countFail,$idFail,$pairFail,$obsFail,$symbolFail)}
    $gates += [pscustomobject]@{gate_id='CFA-S2-003';status='UNVERIFIED';name='CoinGecko mapping decisions';observed=("source_approved={0}; single={1}; ambiguous={2}; none={3}" -f $sourceApproved,$single,$ambiguous,$none)}
    $gates += [pscustomobject]@{gate_id='CFA-S2-004';status=$s2_004;name='Alias seed structural linkage';observed=("rows={0}; assets={1}; missing={2}; duplicates={3}; bad_context={4}" -f $aliases.Count,$aliasAssets.Count,$aliasMissing,$aliasDup,$aliasBadContext)}
    $gates += [pscustomobject]@{gate_id='CFA-S2-005';status='UNVERIFIED';name='Alias semantic validation';observed='manual seed references only'}
    $gates += [pscustomobject]@{gate_id='CFA-S2-006';status='BLOCKED';name='Advance to news matching definition';observed='CFA-S2-003 and CFA-S2-005 unresolved'}

    $review | Sort-Object -Property current_candidate_count,market_observation_count_observed,base_asset_id -Descending | Export-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-CoinGecko-Review-Queue.csv') -NoTypeInformation -Encoding UTF8
    $aliasReview | Sort-Object -Property base_asset_id,alias_text | Export-Csv -LiteralPath (Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Alias-Review.csv') -NoTypeInformation -Encoding UTF8

    $snapshot=[ordered]@{
        source_hashes=[ordered]@{
            AF_001=(Get-FileHash -LiteralPath $pairPath -Algorithm SHA256).Hash.ToLowerInvariant()
            AF_002=(Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
            AF_003=(Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        counts=[ordered]@{eligible_pair_rows=$eligiblePairs.Count;eligible_base_assets=$marketIds.Count;candidate_rows=$candidates.Count;candidate_records=$candidateTotal;single=$single;ambiguous=$ambiguous;none=$none;source_approved=$sourceApproved;alias_rows=$aliases.Count;alias_assets=$aliasAssets.Count}
        gates=$gates
    }
    Write-Utf8NoBom -Path (Join-Path $RepoRoot 'docs\evidence\stage2-identity-review.json') -Content (($snapshot | ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    $b=New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Stage 2 Identity / Mapping / Alias Structural Review')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Derived only from current SoT-registered AF-001/AF-002/AF-003. This review does not approve CoinGecko mappings or alias semantics.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine("Eligible Kraken pair rows: $($eligiblePairs.Count); eligible base assets: $($marketIds.Count); candidate rows: $($candidates.Count); candidate records: $candidateTotal.")
    [void]$b.AppendLine("Single candidate: $single; ambiguous: $ambiguous; none: $none; source-approved mappings: $sourceApproved; aliases: $($aliases.Count) across $($aliasAssets.Count) assets.")
    [void]$b.AppendLine('')
    [void]$b.AppendLine('| Gate | Status | Observed |')
    [void]$b.AppendLine('|---|---|---|')
    foreach($g in $gates){[void]$b.AppendLine('| '+$g.gate_id+' '+$g.name+' | '+$g.status+' | '+([string]$g.observed).Replace('|','\|')+' |')}
    [void]$b.AppendLine('')
    [void]$b.AppendLine('CFA-S2-001/002/004 are structural gates. CFA-S2-003 requires independent CoinGecko mapping evidence and explicit decisions. CFA-S2-005 requires raw-news alias validation. CFA-S2-006 remains BLOCKED until those are resolved.')
    Write-Utf8NoBom -Path (Join-Path $RepoRoot 'docs\evidence\stage2-identity-review.md') -Content $b.ToString()

    $failCount=@($gates | Where-Object {$_.status -eq 'FAIL'}).Count
    foreach($g in $gates){Write-Host ($g.gate_id+' '+$g.status+' - '+$g.name)}
    if($failCount -gt 0){exit 2}
    Write-Host 'CFA STAGE 2 STRUCTURAL REVIEW: COMPLETE'
}
catch {
    Write-Host 'CFA STAGE 2 STRUCTURAL REVIEW: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
