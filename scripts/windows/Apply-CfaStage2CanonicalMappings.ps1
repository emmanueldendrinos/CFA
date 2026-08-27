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
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$encoding)
}

function Assert-Throws {
    param([scriptblock]$Script,[string]$Pattern)
    $caught = $false
    try { & $Script }
    catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw ('Unexpected failure. Expected /{0}/; observed: {1}' -f $Pattern,$_.Exception.Message)
        }
    }
    if (-not $caught) { throw ('Expected failure matching /{0}/ but call succeeded.' -f $Pattern) }
}

function Assert-HttpsSource {
    param([string]$Text,[string]$ExpectedHostSuffix,[string]$Label)
    $uri = $null
    if (-not [Uri]::TryCreate($Text,[UriKind]::Absolute,[ref]$uri)) {
        throw ('{0} is not an absolute URL: {1}' -f $Label,$Text)
    }
    if (-not $uri.Scheme.Equals('https',[System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('{0} must use HTTPS: {1}' -f $Label,$Text)
    }
    $host = [string]$uri.Host
    $suffix = '.' + $ExpectedHostSuffix
    $hostOk = $host.Equals($ExpectedHostSuffix,[System.StringComparison]::OrdinalIgnoreCase) -or $host.EndsWith($suffix,[System.StringComparison]::OrdinalIgnoreCase)
    if (-not $hostOk) {
        throw ('{0} host is outside {1}: {2}' -f $Label,$ExpectedHostSuffix,$host)
    }
}

function Get-ExistingAdjudicationBases {
    param([string]$Root)
    $paths = @(
        'candidate-analysis\CFA-Stage2-Mapping-Adjudications.csv',
        'candidate-analysis\CFA-Stage2-Mapping-Adjudications-02.csv',
        'candidate-analysis\CFA-Stage2-Mapping-Adjudications-03.csv',
        'candidate-analysis\CFA-Stage2-Mapping-Expanded-Adjudications.csv',
        'candidate-analysis\CFA-Stage2-Mapping-Direct-Adjudications.csv'
    )
    $seen = @{}
    foreach ($relative in $paths) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw ('Existing adjudication registry missing: {0}' -f $relative)
        }
        foreach ($row in @(Import-Csv -LiteralPath $path)) {
            $base = [string]$row.base_asset_id
            if ([string]::IsNullOrWhiteSpace($base)) {
                throw ('Existing adjudication has an empty base_asset_id: {0}' -f $relative)
            }
            if ($seen.ContainsKey($base)) {
                throw ('Duplicate existing adjudication base across registries: {0}' -f $base)
            }
            $seen[$base] = $relative
        }
    }
    return $seen
}

function Assert-CanonicalRegistry {
    param(
        [object[]]$Registry,
        [object[]]$Decisions,
        [object[]]$BridgeRows,
        [hashtable]$ExistingBases
    )

    if (@($Registry).Count -le 0) { throw 'Canonical mapping adjudication registry is empty.' }
    $required = @(
        'base_asset_id','decision_status','approved_coingecko_id','observed_coingecko_name',
        'observed_coingecko_symbol','coingecko_page_url','source_observation_date_utc','evidence_basis',
        'kraken_source_url','observed_kraken_name','observed_kraken_ticker','evidence_scope','review_note'
    )
    $allowedBasis = @(
        'KRAKEN_PLUS_COINGECKO_CANONICAL_PAGE_ID',
        'KRAKEN_PLUS_COINGECKO_REBRAND_CANONICAL_PAGE_ID'
    )
    $bases = @{}
    $ids = @{}

    foreach ($row in $Registry) {
        foreach ($name in $required) {
            $property = $row.PSObject.Properties[$name]
            if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw ('Canonical adjudication missing required field {0} for base {1}.' -f $name,[string]$row.base_asset_id)
            }
        }

        $base = [string]$row.base_asset_id
        $id = [string]$row.approved_coingecko_id
        if ($bases.ContainsKey($base)) { throw ('Duplicate canonical adjudication base: {0}' -f $base) }
        if ($ids.ContainsKey($id)) { throw ('Duplicate canonical CoinGecko id across bases: {0}' -f $id) }
        $bases[$base] = $true
        $ids[$id] = $base

        if ([string]$row.decision_status -ne 'APPROVED') {
            throw ('Canonical adjudication must be APPROVED: {0}' -f $base)
        }
        if ($allowedBasis -notcontains [string]$row.evidence_basis) {
            throw ('Unsupported canonical evidence basis for {0}: {1}' -f $base,[string]$row.evidence_basis)
        }
        if ([string]$row.source_observation_date_utc -notmatch '^\d{4}-\d{2}-\d{2}$') {
            throw ('Canonical source observation date must be YYYY-MM-DD: {0}' -f $base)
        }
        Assert-HttpsSource -Text ([string]$row.coingecko_page_url) -ExpectedHostSuffix 'coingecko.com' -Label ('CoinGecko source for {0}' -f $base)
        Assert-HttpsSource -Text ([string]$row.kraken_source_url) -ExpectedHostSuffix 'kraken.com' -Label ('Kraken source for {0}' -f $base)

        if ($ExistingBases.ContainsKey($base)) {
            throw ('Canonical adjudication overlaps existing adjudication registry: {0}' -f $base)
        }

        $decisionMatches = @($Decisions | Where-Object { [string]$_.base_asset_id -eq $base })
        if ($decisionMatches.Count -ne 1) {
            throw ('Expected exactly one current mapping decision for canonical base {0}; observed {1}.' -f $base,$decisionMatches.Count)
        }
        $decision = $decisionMatches[0]
        if ([string]$decision.mapping_status -ne 'UNVERIFIED') {
            throw ('Canonical adjudication may only replace an UNVERIFIED mapping: {0}/{1}' -f $base,[string]$decision.mapping_status)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$decision.approved_coingecko_id)) {
            throw ('UNVERIFIED canonical target already carries an approved CoinGecko id: {0}' -f $base)
        }

        $bridgeMatches = @($BridgeRows | Where-Object { [string]$_.base_asset_id -eq $base })
        if ($bridgeMatches.Count -ne 1) {
            throw ('Expected exactly one bridge-evidence row for canonical base {0}; observed {1}.' -f $base,$bridgeMatches.Count)
        }
        $bridgeSymbol = [string]$bridgeMatches[0].base_exchange_symbol
        if (-not ([string]$row.observed_kraken_ticker).Equals($bridgeSymbol,[System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('Canonical Kraken ticker does not match bridge base symbol for {0}: observed={1} bridge={2}' -f $base,[string]$row.observed_kraken_ticker,$bridgeSymbol)
        }

        if ([string]$row.evidence_basis -eq 'KRAKEN_PLUS_COINGECKO_CANONICAL_PAGE_ID') {
            if (-not ([string]$row.observed_coingecko_symbol).Equals([string]$row.observed_kraken_ticker,[System.StringComparison]::OrdinalIgnoreCase)) {
                throw ('Non-rebrand canonical adjudication requires matching CoinGecko/Kraken symbols: {0}' -f $base)
            }
        }
        elseif ([string]$row.review_note -notmatch '(?i)rebrand') {
            throw ('Rebrand canonical adjudication must explicitly document rebrand continuity: {0}' -f $base)
        }
    }
}

function Apply-CanonicalMappings {
    param([object[]]$Decisions,[object[]]$Registry)

    $canonicalByBase = @{}
    foreach ($row in $Registry) { $canonicalByBase[[string]$row.base_asset_id] = $row }

    $preApproved = @($Decisions | Where-Object { [string]$_.mapping_status -eq 'APPROVED' }).Count
    $preUnverified = @($Decisions | Where-Object { [string]$_.mapping_status -eq 'UNVERIFIED' }).Count
    $preNa = @($Decisions | Where-Object { [string]$_.mapping_status -eq 'NOT_APPLICABLE' }).Count
    $out = @()

    foreach ($decision in $Decisions) {
        $base = [string]$decision.base_asset_id
        if ($canonicalByBase.ContainsKey($base)) {
            $canonical = $canonicalByBase[$base]
            $note = ([string]$canonical.review_note + ' CoinGecko source: ' + [string]$canonical.coingecko_page_url + ' Kraken source: ' + [string]$canonical.kraken_source_url + ' Source observation date UTC: ' + [string]$canonical.source_observation_date_utc)
            $out += [pscustomobject]@{
                base_asset_id = $base
                base_exchange_symbol = [string]$decision.base_exchange_symbol
                candidate_ids = [string]$decision.candidate_ids
                mapping_status = 'APPROVED'
                approved_coingecko_id = [string]$canonical.approved_coingecko_id
                decision_basis = [string]$canonical.evidence_basis
                evidence_note = $note
            }
        }
        else {
            $out += [pscustomobject]@{
                base_asset_id = $base
                base_exchange_symbol = [string]$decision.base_exchange_symbol
                candidate_ids = [string]$decision.candidate_ids
                mapping_status = [string]$decision.mapping_status
                approved_coingecko_id = [string]$decision.approved_coingecko_id
                decision_basis = [string]$decision.decision_basis
                evidence_note = [string]$decision.evidence_note
            }
        }
    }

    $approved = @($out | Where-Object { [string]$_.mapping_status -eq 'APPROVED' }).Count
    $unverified = @($out | Where-Object { [string]$_.mapping_status -eq 'UNVERIFIED' }).Count
    $na = @($out | Where-Object { [string]$_.mapping_status -eq 'NOT_APPLICABLE' }).Count
    if ($out.Count -ne $Decisions.Count) { throw 'Canonical overlay changed mapping-decision cardinality.' }
    if ($approved -ne ($preApproved + $Registry.Count)) {
        throw ('Canonical approval accounting mismatch: before={0} canonical={1} after={2}' -f $preApproved,$Registry.Count,$approved)
    }
    if ($unverified -ne ($preUnverified - $Registry.Count)) {
        throw ('Canonical UNVERIFIED accounting mismatch: before={0} canonical={1} after={2}' -f $preUnverified,$Registry.Count,$unverified)
    }
    if ($na -ne $preNa) {
        throw ('Canonical overlay changed NOT_APPLICABLE count: before={0} after={1}' -f $preNa,$na)
    }

    return [pscustomobject]@{
        rows = @($out | Sort-Object base_asset_id)
        approved = $approved
        unverified = $unverified
        not_applicable = $na
    }
}

function Write-DecisionArtifacts {
    param(
        [string]$Root,
        [string]$CanonicalPath,
        [object[]]$Rows,
        [int]$Approved,
        [int]$Unverified,
        [int]$NotApplicable
    )

    $decisionCsv = Join-Path $Root 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv'
    $Rows | Export-Csv -LiteralPath $decisionCsv -NoTypeInformation -Encoding UTF8

    $remaining = (@($Rows | Where-Object { [string]$_.mapping_status -eq 'UNVERIFIED' } | Sort-Object base_asset_id | ForEach-Object { [string]$_.base_asset_id }) -join '|')
    $gate = if ($Unverified -eq 0) { 'PASS' } else { 'UNVERIFIED' }
    $blocking = if ($Unverified -eq 0) { '' } else { ([string]$Unverified + ' assets still lack independently verified CoinGecko mapping identity: ' + $remaining + '.') }

    $snapshotPath = Join-Path $Root 'docs\evidence\stage2-mapping-decisions.json'
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
        throw 'Stage 2 mapping decision snapshot missing before canonical overlay.'
    }
    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
    $ordered = [ordered]@{}
    foreach ($property in @($snapshot.PSObject.Properties)) { $ordered[[string]$property.Name] = $property.Value }
    $ordered['canonical_adjudication_sha256'] = (Get-FileHash -LiteralPath $CanonicalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ordered['canonical_adjudication_rows'] = @((Import-Csv -LiteralPath $CanonicalPath)).Count
    $ordered['decision_rows'] = $Rows.Count
    $ordered['approved'] = $Approved
    $ordered['not_applicable'] = $NotApplicable
    $ordered['unverified'] = $Unverified
    $ordered['gate_status'] = $gate
    $ordered['blocking_reason'] = $blocking
    Write-Utf8NoBom -Path $snapshotPath -Content (($ordered | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# CFA Stage 2 Mapping Decisions')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('- Decision rows: ' + $Rows.Count)
    [void]$builder.AppendLine('- APPROVED: ' + $Approved)
    [void]$builder.AppendLine('- NOT_APPLICABLE: ' + $NotApplicable)
    [void]$builder.AppendLine('- UNVERIFIED: ' + $Unverified)
    [void]$builder.AppendLine('- CFA-S2-003: ' + $gate)
    if ($Unverified -gt 0) { [void]$builder.AppendLine('- Remaining UNVERIFIED bases: ' + $remaining) }
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('322 approvals are backed by a unique current CoinGecko/Kraken pair bridge. EDGE and LIT are temporal adjudications. Contained adjudications are validated against AF-002 and may also explicitly preserve an UNVERIFIED conflict. Expanded adjudications are validated against separately published hashed CoinGecko reference evidence and never modify AF-002. Direct adjudications are validated against published direct `/coins/{id}` response evidence. Canonical-page adjudications apply only to previously UNVERIFIED rows and record directly inspected CoinGecko API-ID evidence plus independent Kraken identity evidence; they do not alter AF-002 or fabricate direct/list responses. Fiat bases are explicitly NOT_APPLICABLE. Unlisted cases remain UNVERIFIED.')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('Decision table: candidate-analysis/CFA-Stage2-Mapping-Decisions.csv')
    [void]$builder.AppendLine('Contained adjudication registries: candidate-analysis/CFA-Stage2-Mapping-Adjudications.csv, candidate-analysis/CFA-Stage2-Mapping-Adjudications-02.csv, candidate-analysis/CFA-Stage2-Mapping-Adjudications-03.csv')
    [void]$builder.AppendLine('Expanded adjudication registry: candidate-analysis/CFA-Stage2-Mapping-Expanded-Adjudications.csv')
    [void]$builder.AppendLine('Expanded candidate evidence: candidate-analysis/CFA-Stage2-Expanded-CoinGecko-Candidates.csv')
    [void]$builder.AppendLine('Direct adjudication registry: candidate-analysis/CFA-Stage2-Mapping-Direct-Adjudications.csv')
    [void]$builder.AppendLine('Direct CoinGecko evidence: candidate-analysis/CFA-Stage2-Direct-CoinGecko-ID-Evidence.csv')
    [void]$builder.AppendLine('Canonical-page adjudication registry: candidate-analysis/CFA-Stage2-Mapping-Canonical-Adjudications.csv')
    Write-Utf8NoBom -Path (Join-Path $Root 'docs\evidence\stage2-mapping-decisions.md') -Content $builder.ToString()
}

function Invoke-SelfTest {
    $decisions = @(
        [pscustomobject]@{base_asset_id='A';base_exchange_symbol='AA';candidate_ids='x';mapping_status='UNVERIFIED';approved_coingecko_id='';decision_basis='old';evidence_note='old'},
        [pscustomobject]@{base_asset_id='B';base_exchange_symbol='BB';candidate_ids='b';mapping_status='APPROVED';approved_coingecko_id='b';decision_basis='old';evidence_note='old'},
        [pscustomobject]@{base_asset_id='C';base_exchange_symbol='CC';candidate_ids='c';mapping_status='UNVERIFIED';approved_coingecko_id='';decision_basis='old';evidence_note='old'},
        [pscustomobject]@{base_asset_id='Z';base_exchange_symbol='USD';candidate_ids='';mapping_status='NOT_APPLICABLE';approved_coingecko_id='';decision_basis='fiat';evidence_note='fiat'}
    )
    $bridges = @(
        [pscustomobject]@{base_asset_id='A';base_exchange_symbol='AA'},
        [pscustomobject]@{base_asset_id='B';base_exchange_symbol='BB'},
        [pscustomobject]@{base_asset_id='C';base_exchange_symbol='CC'},
        [pscustomobject]@{base_asset_id='Z';base_exchange_symbol='USD'}
    )
    $row = [pscustomobject]@{
        base_asset_id='A';decision_status='APPROVED';approved_coingecko_id='coin-a';observed_coingecko_name='Asset A';observed_coingecko_symbol='AA';
        coingecko_page_url='https://www.coingecko.com/en/coins/coin-a';source_observation_date_utc='2026-08-27';evidence_basis='KRAKEN_PLUS_COINGECKO_CANONICAL_PAGE_ID';
        kraken_source_url='https://www.kraken.com/prices/asset-a';observed_kraken_name='Asset A';observed_kraken_ticker='AA';evidence_scope='test';review_note='test canonical identity'
    }
    Assert-CanonicalRegistry -Registry @($row) -Decisions $decisions -BridgeRows $bridges -ExistingBases @{}
    $applied = Apply-CanonicalMappings -Decisions $decisions -Registry @($row)
    if ($applied.approved -ne 2 -or $applied.unverified -ne 1 -or $applied.not_applicable -ne 1) { throw 'canonical success accounting' }
    $mapped = @($applied.rows | Where-Object { [string]$_.base_asset_id -eq 'A' })[0]
    if ($mapped.mapping_status -ne 'APPROVED' -or $mapped.approved_coingecko_id -ne 'coin-a') { throw 'canonical success mapping' }

    $badTicker = $row.PSObject.Copy(); $badTicker.observed_kraken_ticker = 'WRONG'
    Assert-Throws { Assert-CanonicalRegistry -Registry @($badTicker) -Decisions $decisions -BridgeRows $bridges -ExistingBases @{} } 'ticker does not match'
    $badUrl = $row.PSObject.Copy(); $badUrl.coingecko_page_url = 'https://example.com/coin-a'
    Assert-Throws { Assert-CanonicalRegistry -Registry @($badUrl) -Decisions $decisions -BridgeRows $bridges -ExistingBases @{} } 'outside coingecko.com'
    Assert-Throws { Assert-CanonicalRegistry -Registry @($row) -Decisions $decisions -BridgeRows $bridges -ExistingBases @{A='contained'} } 'overlaps existing'
    $duplicate = $row.PSObject.Copy()
    Assert-Throws { Assert-CanonicalRegistry -Registry @($row,$duplicate) -Decisions $decisions -BridgeRows $bridges -ExistingBases @{} } 'Duplicate canonical adjudication base'
    $approvedTarget = @($decisions | ForEach-Object { $_.PSObject.Copy() })
    (@($approvedTarget | Where-Object { [string]$_.base_asset_id -eq 'A' })[0]).mapping_status = 'APPROVED'
    Assert-Throws { Assert-CanonicalRegistry -Registry @($row) -Decisions $approvedTarget -BridgeRows $bridges -ExistingBases @{} } 'only replace an UNVERIFIED'
    $rebrand = $row.PSObject.Copy(); $rebrand.observed_coingecko_symbol = 'NEW'; $rebrand.evidence_basis = 'KRAKEN_PLUS_COINGECKO_REBRAND_CANONICAL_PAGE_ID'; $rebrand.review_note = 'explicit rebrand continuity test'
    Assert-CanonicalRegistry -Registry @($rebrand) -Decisions $decisions -BridgeRows $bridges -ExistingBases @{}
    $badRebrand = $rebrand.PSObject.Copy(); $badRebrand.review_note = 'migration without keyword'
    Assert-Throws { Assert-CanonicalRegistry -Registry @($badRebrand) -Decisions $decisions -BridgeRows $bridges -ExistingBases @{} } 'explicitly document rebrand'

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-canonical-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path (Join-Path $root 'candidate-analysis') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'docs\evidence') -Force | Out-Null
        $canonicalPath = Join-Path $root 'candidate-analysis\CFA-Stage2-Mapping-Canonical-Adjudications.csv'
        @($row) | Export-Csv -LiteralPath $canonicalPath -NoTypeInformation -Encoding UTF8
        $seedSnapshot = [ordered]@{decision_rows=4;approved=1;not_applicable=1;unverified=2;gate_status='UNVERIFIED';blocking_reason='old'}
        Write-Utf8NoBom -Path (Join-Path $root 'docs\evidence\stage2-mapping-decisions.json') -Content (($seedSnapshot | ConvertTo-Json) + [Environment]::NewLine)
        Write-DecisionArtifacts -Root $root -CanonicalPath $canonicalPath -Rows $applied.rows -Approved $applied.approved -Unverified $applied.unverified -NotApplicable $applied.not_applicable
        $snapshot = Get-Content -LiteralPath (Join-Path $root 'docs\evidence\stage2-mapping-decisions.json') -Raw | ConvertFrom-Json
        if ([int]$snapshot.approved -ne 2 -or [int]$snapshot.canonical_adjudication_rows -ne 1 -or [string]$snapshot.gate_status -ne 'UNVERIFIED') { throw 'canonical artifact snapshot' }
        $md = [System.IO.File]::ReadAllText((Join-Path $root 'docs\evidence\stage2-mapping-decisions.md'))
        if ($md -notmatch 'Remaining UNVERIFIED bases: C' -or $md -notmatch 'Canonical-page adjudication registry') { throw 'canonical artifact markdown' }
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch {
        Write-Host 'SELF-TEST: FAIL'
        Write-Host $_.Exception.Message
        if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
        exit 1
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

    $decisionPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv'
    $bridgePath = Join-Path $RepoRoot 'docs\evidence\stage2-coingecko-bridge-evidence.csv'
    $canonicalPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Canonical-Adjudications.csv'
    foreach ($path in @($decisionPath,$bridgePath,$canonicalPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw ('Required canonical overlay input missing: {0}' -f $path)
        }
    }

    $decisions = @(Import-Csv -LiteralPath $decisionPath)
    $bridges = @(Import-Csv -LiteralPath $bridgePath)
    $registry = @(Import-Csv -LiteralPath $canonicalPath)
    if ($decisions.Count -ne 435 -or $bridges.Count -ne 435) {
        throw ('Canonical overlay requires 435 decision and bridge rows; observed decisions={0} bridges={1}.' -f $decisions.Count,$bridges.Count)
    }

    $existing = Get-ExistingAdjudicationBases -Root $RepoRoot
    Assert-CanonicalRegistry -Registry $registry -Decisions $decisions -BridgeRows $bridges -ExistingBases $existing
    $result = Apply-CanonicalMappings -Decisions $decisions -Registry $registry
    Write-DecisionArtifacts -Root $RepoRoot -CanonicalPath $canonicalPath -Rows $result.rows -Approved $result.approved -Unverified $result.unverified -NotApplicable $result.not_applicable

    $gate = if ($result.unverified -eq 0) { 'PASS' } else { 'UNVERIFIED' }
    Write-Host 'CFA STAGE 2 CANONICAL MAPPING OVERLAY: COMPLETE'
    Write-Host ('Canonical approvals: {0}' -f $registry.Count)
    Write-Host ('APPROVED: {0}' -f $result.approved)
    Write-Host ('NOT_APPLICABLE: {0}' -f $result.not_applicable)
    Write-Host ('UNVERIFIED: {0}' -f $result.unverified)
    Write-Host ('CFA-S2-003: {0}' -f $gate)
}
catch {
    Write-Host 'CFA STAGE 2 CANONICAL MAPPING OVERLAY: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
