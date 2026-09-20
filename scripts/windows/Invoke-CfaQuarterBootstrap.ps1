#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$QuarterId = '',
    [string]$ManifestPath = '',
    [string]$OutputRoot = '',
    [switch]$NoWrite,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-ContractValidation {
    param([Parameter(Mandatory)][string]$Message)
    throw (New-Object System.IO.InvalidDataException -ArgumentList $Message)
}

function Get-PropertyNames {
    param([AllowNull()][object]$Object)
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-RequiredProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )
    if ($null -eq $Object) { Stop-ContractValidation "$Context is null." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { Stop-ContractValidation "$Context is missing required property '$Name'." }
    return $property.Value
}

function Assert-ExactProperties {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Context
    )
    if ($null -eq $Object) { Stop-ContractValidation "$Context is null." }
    $actual = @(Get-PropertyNames -Object $Object)
    $missing = @($Allowed | Where-Object { $actual -notcontains $_ })
    $unexpected = @($actual | Where-Object { $Allowed -notcontains $_ })
    if ($missing.Count -gt 0) {
        Stop-ContractValidation ("{0} is missing properties: {1}." -f $Context,($missing -join ', '))
    }
    if ($unexpected.Count -gt 0) {
        Stop-ContractValidation ("{0} has unexpected properties: {1}." -f $Context,($unexpected -join ', '))
    }
}

function Assert-NonEmptyString {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Context
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        Stop-ContractValidation "$Context must be a non-empty string."
    }
}

function Assert-ExactStringArray {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Actual,
        [AllowEmptyCollection()][string[]]$Expected,
        [Parameter(Mandatory)][string]$Context
    )
    $values = @($Actual | ForEach-Object { [string]$_ })
    if ($values.Count -ne $Expected.Count) {
        Stop-ContractValidation ("{0} count mismatch: expected {1}, observed {2}." -f $Context,$Expected.Count,$values.Count)
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($values[$index] -cne $Expected[$index]) {
            Stop-ContractValidation ("{0}[{1}] mismatch: expected '{2}', observed '{3}'." -f $Context,$index,$Expected[$index],$values[$index])
        }
    }
}

function ConvertFrom-ExactUtcText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Context
    )
    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $valid = [DateTimeOffset]::TryParseExact(
        $Text,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [Globalization.CultureInfo]::InvariantCulture,
        $styles,
        [ref]$parsed
    )
    if (-not $valid) { Stop-ContractValidation "$Context must use exact UTC format yyyy-MM-ddTHH:mm:ssZ." }
    return $parsed
}

function Get-RawUtcText {
    param(
        [Parameter(Mandatory)][string]$RawJson,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][string]$Context
    )
    $pattern = '"' + [regex]::Escape($PropertyName) + '"\s*:\s*"(?<value>[^"]*)"'
    $matches = [regex]::Matches($RawJson,$pattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($matches.Count -ne 1) {
        Stop-ContractValidation "$Context must occur exactly once as a JSON string."
    }
    $value = $matches[0].Groups['value'].Value
    if ($value -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
        Stop-ContractValidation "$Context must use exact UTC format yyyy-MM-ddTHH:mm:ssZ."
    }
    return $value
}

function Get-FileSha256Lower {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Context
    )
    Assert-NonEmptyString -Value $RelativePath -Context $Context
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        Stop-ContractValidation "$Context must be repository-relative."
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        Stop-ContractValidation "$Context resolves outside the repository root."
    }
    return $candidate
}

function Get-GitEvidence {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$BaseCommit
    )
    $git = Get-Command 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { $git = Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($null -eq $git) { Stop-ContractValidation 'Git is required to verify the frozen repository base commit.' }

    $headOutput = @(& $git.Source -C $Root rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $headOutput.Count -ne 1) {
        Stop-ContractValidation 'Unable to resolve the current repository HEAD.'
    }
    $head = ([string]$headOutput[0]).Trim().ToLowerInvariant()
    if ($head -notmatch '^[0-9a-f]{40}$') { Stop-ContractValidation "Repository HEAD is not a full commit SHA: $head" }

    & $git.Source -C $Root cat-file -e ($BaseCommit + '^{commit}') 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-ContractValidation "Frozen base commit is not present in this repository: $BaseCommit" }

    & $git.Source -C $Root merge-base --is-ancestor $BaseCommit $head 2>$null
    if ($LASTEXITCODE -ne 0) {
        Stop-ContractValidation "Frozen base commit $BaseCommit is not an ancestor of current HEAD $head."
    }

    return [pscustomobject]@{
        base_commit_sha = $BaseCommit
        current_head_sha = $head
        base_is_ancestor = $true
    }
}

function Test-CfaQuarterContract {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][string]$RawJson,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedManifestPath
    )

    Assert-ExactProperties -Object $Contract -Allowed @(
        'contract_schema','contract_version','contract_id','quarter_id','created_utc',
        'interval','authority','execution','resources','stage_plan'
    ) -Context 'contract'

    if ([string](Get-RequiredProperty $Contract 'contract_schema' 'contract') -cne 'cfa.quarter-bootstrap/v1') {
        Stop-ContractValidation 'Unsupported contract_schema.'
    }
    $contractVersion = [string](Get-RequiredProperty $Contract 'contract_version' 'contract')
    if ($contractVersion -notmatch '^1\.[0-9]+\.[0-9]+$') { Stop-ContractValidation 'contract_version must be a v1 semantic version.' }

    $quarterId = [string](Get-RequiredProperty $Contract 'quarter_id' 'contract')
    if ($quarterId -notmatch '^(?<year>[0-9]{4})Q(?<quarter>[1-4])$') {
        Stop-ContractValidation 'quarter_id must match YYYYQ[1-4].'
    }
    $year = [int]$Matches.year
    $quarter = [int]$Matches.quarter
    $quarterToken = 'Q' + $quarter
    $contractId = [string](Get-RequiredProperty $Contract 'contract_id' 'contract')
    if ($contractId -cne ($quarterToken + '-CTL-001')) {
        Stop-ContractValidation "contract_id must be $quarterToken-CTL-001 for $quarterId."
    }
    Get-RequiredProperty $Contract 'created_utc' 'contract' | Out-Null
    $createdUtcText = Get-RawUtcText -RawJson $RawJson -PropertyName 'created_utc' -Context 'created_utc'
    $createdUtc = ConvertFrom-ExactUtcText -Text $createdUtcText -Context 'created_utc'

    $interval = Get-RequiredProperty $Contract 'interval' 'contract'
    Assert-ExactProperties -Object $interval -Allowed @('start_utc','end_exclusive_utc','time_zone','semantics') -Context 'interval'
    if ([string]$interval.time_zone -cne 'UTC') { Stop-ContractValidation 'interval.time_zone must be UTC.' }
    if ([string]$interval.semantics -cne 'HALF_OPEN') { Stop-ContractValidation 'interval.semantics must be HALF_OPEN.' }
    $startUtcText = Get-RawUtcText -RawJson $RawJson -PropertyName 'start_utc' -Context 'interval.start_utc'
    $endExclusiveUtcText = Get-RawUtcText -RawJson $RawJson -PropertyName 'end_exclusive_utc' -Context 'interval.end_exclusive_utc'
    $start = ConvertFrom-ExactUtcText -Text $startUtcText -Context 'interval.start_utc'
    $endExclusive = ConvertFrom-ExactUtcText -Text $endExclusiveUtcText -Context 'interval.end_exclusive_utc'
    $expectedStart = [DateTimeOffset]::new($year,(($quarter - 1) * 3 + 1),1,0,0,0,[TimeSpan]::Zero)
    $expectedEnd = $expectedStart.AddMonths(3)
    if ($start -ne $expectedStart -or $endExclusive -ne $expectedEnd) {
        Stop-ContractValidation ("Quarter bounds mismatch for {0}: expected [{1},{2}), observed [{3},{4})." -f $quarterId,$expectedStart.ToString('o'),$expectedEnd.ToString('o'),$start.ToString('o'),$endExclusive.ToString('o'))
    }
    if ($createdUtc -lt $endExclusive) { Stop-ContractValidation 'created_utc cannot precede the contracted quarter end.' }

    $authority = Get-RequiredProperty $Contract 'authority' 'contract'
    Assert-ExactProperties -Object $authority -Allowed @(
        'repository','base_commit_sha','sot_path','sot_sha256','sot_snapshot_path',
        'automation_plan_path','registered_source_ids','required_data_ids'
    ) -Context 'authority'
    if ([string]$authority.repository -cne 'emmanueldendrinos/CFA') { Stop-ContractValidation 'authority.repository must be emmanueldendrinos/CFA.' }
    $baseCommit = ([string]$authority.base_commit_sha).ToLowerInvariant()
    if ($baseCommit -notmatch '^[0-9a-f]{40}$') { Stop-ContractValidation 'authority.base_commit_sha must be a full lowercase commit SHA.' }
    $expectedSotSha = ([string]$authority.sot_sha256).ToLowerInvariant()
    if ($expectedSotSha -notmatch '^[0-9a-f]{64}$') { Stop-ContractValidation 'authority.sot_sha256 must be a lowercase SHA-256.' }
    Assert-ExactStringArray -Actual @($authority.registered_source_ids) -Expected @('AF-001','AF-002','AF-003') -Context 'authority.registered_source_ids'

    $requiredDataIds = @($authority.required_data_ids)
    $expectedDataIds = @('DATA-001','DATA-002','DATA-003')
    if ($requiredDataIds.Count -ne $expectedDataIds.Count) { Stop-ContractValidation 'authority.required_data_ids must contain exactly DATA-001 through DATA-003.' }
    for ($index = 0; $index -lt $expectedDataIds.Count; $index++) {
        $entry = $requiredDataIds[$index]
        Assert-ExactProperties -Object $entry -Allowed @('id','status','reason') -Context "authority.required_data_ids[$index]"
        if ([string]$entry.id -cne $expectedDataIds[$index]) { Stop-ContractValidation "authority.required_data_ids[$index].id mismatch." }
        if ([string]$entry.status -cne 'UNVERIFIED') { Stop-ContractValidation "$($entry.id) must remain UNVERIFIED until it is present in an authorized SoT revision." }
        Assert-NonEmptyString -Value $entry.reason -Context "$($entry.id).reason"
        if ([string]$entry.reason -notmatch '(?i)no equivalence') { Stop-ContractValidation "$($entry.id).reason must state that no equivalence is assumed." }
    }

    $sotPath = Resolve-RepoPath -Root $Root -RelativePath ([string]$authority.sot_path) -Context 'authority.sot_path'
    if (-not (Test-Path -LiteralPath $sotPath -PathType Leaf)) { Stop-ContractValidation "CFA SoT is missing: $sotPath" }
    $observedSotSha = Get-FileSha256Lower -Path $sotPath
    if ($observedSotSha -cne $expectedSotSha) {
        Stop-ContractValidation "CFA SoT SHA-256 mismatch: expected $expectedSotSha, observed $observedSotSha."
    }

    $snapshotPath = Resolve-RepoPath -Root $Root -RelativePath ([string]$authority.sot_snapshot_path) -Context 'authority.sot_snapshot_path'
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { Stop-ContractValidation "SoT snapshot is missing: $snapshotPath" }
    try { $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json }
    catch { Stop-ContractValidation "SoT snapshot JSON is malformed: $($_.Exception.Message)" }
    if ([string]$snapshot.source_file -cne [string]$authority.sot_path) { Stop-ContractValidation 'SoT snapshot source_file does not match authority.sot_path.' }
    if (([string]$snapshot.source_sha256).ToLowerInvariant() -cne $expectedSotSha) { Stop-ContractValidation 'SoT snapshot source_sha256 does not match authority.sot_sha256.' }
    if (@($snapshot.authority_id_hits).Count -ne 0) { Stop-ContractValidation 'SoT snapshot now contains authority-ID hits; DATA-001/002/003 must be explicitly reconciled before this contract can pass.' }

    $automationPlanPath = Resolve-RepoPath -Root $Root -RelativePath ([string]$authority.automation_plan_path) -Context 'authority.automation_plan_path'
    if (-not (Test-Path -LiteralPath $automationPlanPath -PathType Leaf)) { Stop-ContractValidation "Automation plan is missing: $automationPlanPath" }

    $execution = Get-RequiredProperty $Contract 'execution' 'contract'
    Assert-ExactProperties -Object $execution -Allowed @(
        'runner_path','mode','acquire_data','modify_source_files','modify_postgresql',
        'advance_stage_1','allow_prior_quarter_observations_as_expectations'
    ) -Context 'execution'
    if ([string]$execution.mode -cne 'VALIDATE_ONLY') { Stop-ContractValidation 'execution.mode must be VALIDATE_ONLY.' }
    foreach ($flagName in @('acquire_data','modify_source_files','modify_postgresql','advance_stage_1','allow_prior_quarter_observations_as_expectations')) {
        $flag = Get-RequiredProperty $execution $flagName 'execution'
        if (-not ($flag -is [bool])) { Stop-ContractValidation "execution.$flagName must be Boolean." }
        if ([bool]$flag) { Stop-ContractValidation "execution.$flagName must be false in the bootstrap contract." }
    }
    $runnerPath = Resolve-RepoPath -Root $Root -RelativePath ([string]$execution.runner_path) -Context 'execution.runner_path'
    if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) { Stop-ContractValidation "Bootstrap runner is missing: $runnerPath" }

    $resources = @($Contract.resources)
    $expectedResources = @(
        [pscustomobject]@{id=($quarterToken + '-RES-001-GITHUB');kind='GITHUB_REPOSITORY';status='PASS'},
        [pscustomobject]@{id=($quarterToken + '-RES-001-KRAKEN');kind='KRAKEN_SOURCE';status='UNVERIFIED'},
        [pscustomobject]@{id=($quarterToken + '-RES-001-CFA-LOCAL');kind='LOCAL_EVIDENCE_ROOT';status='UNVERIFIED'},
        [pscustomobject]@{id=($quarterToken + '-RES-001-POSTGRESQL');kind='POSTGRESQL';status='UNVERIFIED'},
        [pscustomobject]@{id=($quarterToken + '-RES-001-NEWS');kind='NEWS_SOURCE';status='UNVERIFIED'}
    )
    if ($resources.Count -ne $expectedResources.Count) { Stop-ContractValidation 'resources must contain the five frozen bootstrap resources.' }
    for ($index = 0; $index -lt $expectedResources.Count; $index++) {
        $resource = $resources[$index]
        $expected = $expectedResources[$index]
        Assert-ExactProperties -Object $resource -Allowed @('id','kind','status','locator','observation','reason') -Context "resources[$index]"
        if ([string]$resource.id -cne [string]$expected.id) { Stop-ContractValidation "resources[$index].id mismatch." }
        if ([string]$resource.kind -cne [string]$expected.kind) { Stop-ContractValidation "$($resource.id).kind mismatch." }
        if ([string]$resource.status -cne [string]$expected.status) { Stop-ContractValidation "$($resource.id).status must be $($expected.status)." }
        Assert-NonEmptyString -Value $resource.reason -Context "$($resource.id).reason"
        if ([string]$resource.status -eq 'UNVERIFIED') {
            if ($null -ne $resource.locator -or $null -ne $resource.observation) {
                Stop-ContractValidation "$($resource.id) must not contain an inferred locator or observation while UNVERIFIED."
            }
        }
        else {
            Assert-NonEmptyString -Value $resource.locator -Context "$($resource.id).locator"
            Assert-NonEmptyString -Value $resource.observation -Context "$($resource.id).observation"
        }
    }
    if ([string]$resources[0].observation -notmatch [regex]::Escape($baseCommit)) {
        Stop-ContractValidation 'The GitHub resource observation must name the frozen base commit.'
    }
    if ([string]$resources[0].locator -cne 'https://github.com/emmanueldendrinos/CFA') {
        Stop-ContractValidation 'The GitHub resource locator does not match the controlling repository.'
    }
    if ([string]$resources[0].observation -cne ('main@' + $baseCommit)) {
        Stop-ContractValidation 'The GitHub resource observation must be the exact frozen main commit.'
    }

    $expectedStageIds = @(
        ($quarterToken + '-RES-001'),($quarterToken + '-S1-001'),($quarterToken + '-S1-002'),
        ($quarterToken + '-S1-003'),($quarterToken + '-S1-004'),($quarterToken + '-S1-005'),
        ($quarterToken + '-S2-001'),($quarterToken + '-S2-002'),($quarterToken + '-S3-001'),
        ($quarterToken + '-S3-002'),($quarterToken + '-S3-003'),($quarterToken + '-S4-001'),
        ($quarterToken + '-S5-001'),($quarterToken + '-S6-001'),($quarterToken + '-S7-001'),
        ($quarterToken + '-S8-001')
    )
    $stagePlan = @($Contract.stage_plan)
    if ($stagePlan.Count -ne $expectedStageIds.Count) { Stop-ContractValidation "stage_plan does not contain the complete frozen $quarterToken sequence." }
    for ($index = 0; $index -lt $expectedStageIds.Count; $index++) {
        $stage = $stagePlan[$index]
        Assert-ExactProperties -Object $stage -Allowed @('order','id','status','depends_on','purpose') -Context "stage_plan[$index]"
        if ([int]$stage.order -ne $index) { Stop-ContractValidation "stage_plan[$index].order must equal $index." }
        if ([string]$stage.id -cne $expectedStageIds[$index]) { Stop-ContractValidation "stage_plan[$index].id mismatch." }
        $expectedStatus = if ($index -eq 0) { 'UNVERIFIED' } else { 'BLOCKED' }
        if ([string]$stage.status -cne $expectedStatus) { Stop-ContractValidation "$($stage.id).status must be $expectedStatus at bootstrap." }
        $expectedDependencies = if ($index -eq 0) { @() } else { @($expectedStageIds[$index - 1]) }
        Assert-ExactStringArray -Actual @($stage.depends_on) -Expected $expectedDependencies -Context "$($stage.id).depends_on"
        Assert-NonEmptyString -Value $stage.purpose -Context "$($stage.id).purpose"
    }

    foreach ($forbiddenPattern in @(
        '(?i)"(?:expected|observed)_(?:row|member|pair|asset|slot)_count"\s*:',
        '(?i)"(?:market|news)_table"\s*:',
        '(?i)"source_archive"\s*:'
    )) {
        if ($RawJson -match $forbiddenPattern) {
            Stop-ContractValidation 'Source-specific observations are not permitted in a bootstrap manifest.'
        }
    }

    $gitEvidence = Get-GitEvidence -Root $Root -BaseCommit $baseCommit
    $manifestSha = Get-FileSha256Lower -Path $ResolvedManifestPath
    $checks = @(
        [pscustomobject]@{id=($quarterToken + '-CTL-001-MANIFEST');status='PASS';evidence=$manifestSha},
        [pscustomobject]@{id=($quarterToken + '-CTL-002-INTERVAL');status='PASS';evidence=('[{0},{1})' -f $startUtcText,$endExclusiveUtcText)},
        [pscustomobject]@{id=($quarterToken + '-CTL-003-AUTHORITY');status='PASS';evidence=$observedSotSha},
        [pscustomobject]@{id=($quarterToken + '-CTL-004-DATA-IDS');status='PASS';evidence='DATA-001/002/003 explicitly UNVERIFIED; no AF equivalence assumed'},
        [pscustomobject]@{id=($quarterToken + '-CTL-005-NO-CARRY');status='PASS';evidence='No prior-quarter source observations or cardinalities are contracted'},
        [pscustomobject]@{id=($quarterToken + '-CTL-006-READ-ONLY');status='PASS';evidence='VALIDATE_ONLY; all mutation/acquisition/advance flags false'},
        [pscustomobject]@{id=($quarterToken + '-CTL-007-SEQUENCE');status='PASS';evidence=($expectedStageIds -join '>')}
    )

    return [pscustomobject]@{
        contract_schema = 'cfa.quarter-bootstrap-receipt/v1'
        contract_id = $contractId
        quarter_id = $quarterId
        status = 'PASS'
        validated_utc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        manifest_path = [System.IO.Path]::GetFullPath($ResolvedManifestPath)
        manifest_sha256 = $manifestSha
        sot_sha256 = $observedSotSha
        git = $gitEvidence
        checks = $checks
        next_gate = [pscustomobject]@{
            id = ($quarterToken + '-RES-001')
            status = 'UNVERIFIED'
            reason = "Local Kraken, CFA-local, PostgreSQL, and $quarterToken news resources require direct read-only inventory."
        }
    }
}

function Get-ResolvedInputs {
    param([string]$RootArgument,[string]$QuarterArgument,[string]$ManifestArgument)
    $root = $RootArgument
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Stop-ContractValidation "Repository root does not exist: $root" }
    $root = (Resolve-Path -LiteralPath $root).ProviderPath

    $manifest = $ManifestArgument
    if ([string]::IsNullOrWhiteSpace($manifest)) {
        if ($QuarterArgument -notmatch '^[0-9]{4}Q[1-4]$') {
            Stop-ContractValidation 'Specify -ManifestPath or a -QuarterId matching YYYYQ[1-4].'
        }
        $manifest = Join-Path $root ('config\quarters\' + $QuarterArgument + '.json')
    }
    elseif (-not [System.IO.Path]::IsPathRooted($manifest)) {
        $manifest = Join-Path $root $manifest
    }
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Stop-ContractValidation "Quarter manifest does not exist: $manifest" }
    $manifest = (Resolve-Path -LiteralPath $manifest).ProviderPath
    return [pscustomobject]@{root=$root;manifest=$manifest}
}

function Read-ContractJson {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw
    try { $contract = $raw | ConvertFrom-Json }
    catch { Stop-ContractValidation "Quarter manifest JSON is malformed: $($_.Exception.Message)" }
    if ($null -eq $contract) { Stop-ContractValidation 'Quarter manifest JSON produced a null contract.' }
    return [pscustomobject]@{raw=$raw;contract=$contract}
}

function Copy-JsonObject {
    param([Parameter(Mandatory)][object]$Object)
    return (($Object | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
}

function Assert-ContractRejected {
    param(
        [Parameter(Mandatory)][object]$Contract,
        [Parameter(Mandatory)][string]$RawJson,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResolvedManifestPath,
        [Parameter(Mandatory)][string]$CaseName
    )
    $accepted = $false
    $rejectedByContract = $false
    try {
        Test-CfaQuarterContract -Contract $Contract -RawJson $RawJson -Root $Root -ResolvedManifestPath $ResolvedManifestPath | Out-Null
        $accepted = $true
    }
    catch {
        if ($_.Exception -is [System.IO.InvalidDataException]) { $rejectedByContract = $true }
        else { throw }
    }
    if ($accepted) { throw "Self-test failed: invalid case was accepted: $CaseName" }
    if (-not $rejectedByContract) { throw "Self-test failed: invalid case was not rejected by contract validation: $CaseName" }
}

function Invoke-SelfTest {
    param([string]$RootArgument,[string]$QuarterArgument,[string]$ManifestArgument)
    $inputs = Get-ResolvedInputs -RootArgument $RootArgument -QuarterArgument $QuarterArgument -ManifestArgument $ManifestArgument
    $loaded = Read-ContractJson -Path $inputs.manifest
    $receipt = Test-CfaQuarterContract -Contract $loaded.contract -RawJson $loaded.raw -Root $inputs.root -ResolvedManifestPath $inputs.manifest
    if ([string]$receipt.status -cne 'PASS') { throw 'Self-test failed: valid contract did not return PASS.' }

    $badBounds = Copy-JsonObject $loaded.contract
    $badBounds.interval.end_exclusive_utc = '2026-03-31T23:59:59Z'
    Assert-ContractRejected -Contract $badBounds -RawJson ($badBounds | ConvertTo-Json -Depth 20) -Root $inputs.root -ResolvedManifestPath $inputs.manifest -CaseName 'closed or truncated quarter boundary'

    $badDataId = Copy-JsonObject $loaded.contract
    $badDataId.authority.required_data_ids[0].status = 'PASS'
    Assert-ContractRejected -Contract $badDataId -RawJson ($badDataId | ConvertTo-Json -Depth 20) -Root $inputs.root -ResolvedManifestPath $inputs.manifest -CaseName 'unapproved DATA to AF equivalence'

    $badResource = Copy-JsonObject $loaded.contract
    $badResource.resources[1].locator = 'guessed-path'
    Assert-ContractRejected -Contract $badResource -RawJson ($badResource | ConvertTo-Json -Depth 20) -Root $inputs.root -ResolvedManifestPath $inputs.manifest -CaseName 'inferred locator on UNVERIFIED resource'

    $badExecution = Copy-JsonObject $loaded.contract
    $badExecution.execution.modify_postgresql = $true
    Assert-ContractRejected -Contract $badExecution -RawJson ($badExecution | ConvertTo-Json -Depth 20) -Root $inputs.root -ResolvedManifestPath $inputs.manifest -CaseName 'bootstrap PostgreSQL mutation'

    $badSequence = Copy-JsonObject $loaded.contract
    $badSequence.stage_plan[1].status = 'PASS'
    Assert-ContractRejected -Contract $badSequence -RawJson ($badSequence | ConvertTo-Json -Depth 20) -Root $inputs.root -ResolvedManifestPath $inputs.manifest -CaseName 'premature Stage 1 PASS'

    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest -RootArgument $RepoRoot -QuarterArgument $QuarterId -ManifestArgument $ManifestPath; exit 0 }
    catch {
        Write-Host 'SELF-TEST: FAIL'
        Write-Host $_.Exception.Message
        if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
        exit 1
    }
}

try {
    $inputs = Get-ResolvedInputs -RootArgument $RepoRoot -QuarterArgument $QuarterId -ManifestArgument $ManifestPath
    $loaded = Read-ContractJson -Path $inputs.manifest
    $receipt = Test-CfaQuarterContract -Contract $loaded.contract -RawJson $loaded.raw -Root $inputs.root -ResolvedManifestPath $inputs.manifest
    $receiptJson = $receipt | ConvertTo-Json -Depth 20

    Write-Host "CFA QUARTER BOOTSTRAP: $($receipt.status)"
    Write-Host "Contract: $($receipt.contract_id) | Quarter: $($receipt.quarter_id)"
    Write-Host "Manifest SHA-256: $($receipt.manifest_sha256)"
    Write-Host "Next gate: $($receipt.next_gate.id) = $($receipt.next_gate.status)"

    if (-not $NoWrite) {
        if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
            $documents = [Environment]::GetFolderPath('MyDocuments')
            if ([string]::IsNullOrWhiteSpace($documents)) { Stop-ContractValidation 'MyDocuments could not be resolved; specify -OutputRoot or use -NoWrite.' }
            $OutputRoot = Join-Path $documents 'CFA-local\quarter-bootstrap'
        }
        $runDir = Join-Path $OutputRoot ($receipt.quarter_id + '\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        $receiptPath = Join-Path $runDir 'bootstrap-receipt.json'
        [System.IO.File]::WriteAllText($receiptPath,$receiptJson,(New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Receipt: $receiptPath"
    }
    else {
        Write-Output $receiptJson
    }
    exit 0
}
catch {
    Write-Host 'CFA QUARTER BOOTSTRAP: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 2
}
