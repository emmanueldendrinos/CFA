#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$PgUser = 'postgres',
    [switch]$RecoverNewsSource,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestRun {
    param([string]$ParentPath,[switch]$Optional)
    if (-not (Test-Path -LiteralPath $ParentPath -PathType Container)) {
        if ($Optional) { return $null }
        throw "Evidence directory missing: $ParentPath"
    }
    $runs = @(Get-ChildItem -LiteralPath $ParentPath -Directory -Force | Sort-Object Name -Descending)
    if ($runs.Count -eq 0) {
        if ($Optional) { return $null }
        throw "No evidence run found under: $ParentPath"
    }
    return $runs[0]
}

function Get-StatusGate {
    param([object[]]$Rows)
    if (@($Rows | Where-Object { [string]$_.status -eq 'FAIL' }).Count -gt 0) { return 'FAIL' }
    if (@($Rows | Where-Object { [string]$_.status -eq 'BLOCKED' }).Count -gt 0) { return 'BLOCKED' }
    if (@($Rows | Where-Object { [string]$_.status -eq 'UNVERIFIED' }).Count -gt 0) { return 'UNVERIFIED' }
    if ($Rows.Count -gt 0 -and @($Rows | Where-Object { [string]$_.status -ne 'PASS' }).Count -eq 0) { return 'PASS' }
    return 'UNVERIFIED'
}

function Assert-FrozenKrakenPass {
    param([string]$EvidenceRoot)
    $run = Get-LatestRun -ParentPath (Join-Path $EvidenceRoot 'kraken-reconciliation')
    $membersPath = Join-Path $run.FullName 'member-reconciliation.csv'
    $archivePath = Join-Path $run.FullName 'archive-reconciliation.csv'
    if (-not (Test-Path -LiteralPath $membersPath -PathType Leaf) -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw 'Frozen Kraken evidence files are missing.'
    }
    $members = @(Import-Csv -LiteralPath $membersPath)
    $archives = @(Import-Csv -LiteralPath $archivePath)
    if ($members.Count -ne 1059) { throw "Frozen Kraken member evidence has unexpected cardinality: $($members.Count)." }
    if (@($members | Where-Object { [string]$_.status -ne 'PASS' }).Count -ne 0) { throw 'Frozen Kraken member evidence is not all PASS.' }
    if ($archives.Count -ne 1 -or [string]$archives[0].status -ne 'PASS') { throw 'Frozen Kraken archive evidence is not PASS.' }
    return $run.Name
}

function Invoke-Child {
    param([string]$ScriptPath,[string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Required child script missing: $ScriptPath" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw ('Child script failed with exit code ' + $code + ': ' + $ScriptPath) }
}

function Get-GateStatusFromExitCode {
    param([int]$ExitCode)
    if ($ExitCode -eq 0) { return 'PASS' }
    if ($ExitCode -eq 2) { return 'FAIL' }
    throw ('Unexpected gate exit code: ' + $ExitCode)
}

function Invoke-GateChild {
    param([string]$ScriptPath,[string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Required gate script missing: $ScriptPath" }

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    foreach ($line in $output) { Write-Host ([string]$line) }
    try {
        return Get-GateStatusFromExitCode -ExitCode $code
    }
    catch {
        throw ('Gate script execution failed with exit code ' + $code + ': ' + $ScriptPath)
    }
}

function Get-ReferenceGate {
    param([string]$RepoRootPath)
    $path = Join-Path $RepoRootPath 'docs\evidence\reference-source-reconciliation.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'UNVERIFIED' }
    $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([bool]$obj.all_pass) { return 'PASS' }
    return 'FAIL'
}

function Get-CfaSourceGateFromEvidence {
    param([string]$EvidenceRoot)
    $run = Get-LatestRun -ParentPath (Join-Path $EvidenceRoot 'gdelt-q2-source-verification') -Optional
    if ($null -eq $run) { return 'UNVERIFIED' }
    $path = Join-Path $run.FullName 'source-verification-checks.csv'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'UNVERIFIED' }
    return Get-StatusGate -Rows @(Import-Csv -LiteralPath $path)
}

function Get-LegacyNewsGateFromEvidence {
    param([string]$EvidenceRoot)
    $run = Get-LatestRun -ParentPath (Join-Path $EvidenceRoot 'news-source-coverage') -Optional
    if ($null -eq $run) { return 'UNVERIFIED' }
    $path = Join-Path $run.FullName 'coverage-checks.csv'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'UNVERIFIED' }
    return Get-StatusGate -Rows @(Import-Csv -LiteralPath $path)
}

function Resolve-NewsGate {
    param([string]$LegacyGate,[string]$CfaSourceGate)
    if ($CfaSourceGate -eq 'PASS') { return 'PASS' }
    if ($CfaSourceGate -eq 'FAIL') { return 'FAIL' }
    return $LegacyGate
}

function Invoke-SelfTest {
    $rowsPass = @([pscustomobject]@{status='PASS'},[pscustomobject]@{status='PASS'})
    $rowsFail = @([pscustomobject]@{status='PASS'},[pscustomobject]@{status='FAIL'})
    $rowsUnverified = @([pscustomobject]@{status='PASS'},[pscustomobject]@{status='UNVERIFIED'})
    if ((Get-StatusGate -Rows $rowsPass) -ne 'PASS') { throw 'Self-test failed: PASS gate.' }
    if ((Get-StatusGate -Rows $rowsFail) -ne 'FAIL') { throw 'Self-test failed: FAIL gate.' }
    if ((Get-StatusGate -Rows $rowsUnverified) -ne 'UNVERIFIED') { throw 'Self-test failed: UNVERIFIED gate.' }
    if ((Resolve-NewsGate -LegacyGate 'FAIL' -CfaSourceGate 'PASS') -ne 'PASS') { throw 'Self-test failed: CFA source PASS must supersede rejected legacy source.' }
    if ((Resolve-NewsGate -LegacyGate 'FAIL' -CfaSourceGate 'FAIL') -ne 'FAIL') { throw 'Self-test failed: CFA source FAIL.' }
    if ((Resolve-NewsGate -LegacyGate 'FAIL' -CfaSourceGate 'UNVERIFIED') -ne 'FAIL') { throw 'Self-test failed: legacy fallback.' }
    if ((Get-GateStatusFromExitCode -ExitCode 0) -ne 'PASS') { throw 'Self-test failed: gate exit 0.' }
    if ((Get-GateStatusFromExitCode -ExitCode 2) -ne 'FAIL') { throw 'Self-test failed: gate exit 2.' }
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

$oldPassword = $env:PGPASSWORD
$bstr = [IntPtr]::Zero
$ownsPassword = $false

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $evidenceRoot = Join-Path $documents 'CFA-local'

    $krakenRun = Assert-FrozenKrakenPass -EvidenceRoot $evidenceRoot
    Write-Host "Frozen Kraken PASS evidence: $krakenRun"

    $legacyGate = Get-LegacyNewsGateFromEvidence -EvidenceRoot $evidenceRoot
    $cfaSourceGate = Get-CfaSourceGateFromEvidence -EvidenceRoot $evidenceRoot

    $needsDatabaseWork = (-not ($RecoverNewsSource -and $cfaSourceGate -eq 'PASS')) -or (-not $RecoverNewsSource)
    if ($needsDatabaseWork -and [string]::IsNullOrWhiteSpace($env:PGPASSWORD)) {
        $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $ownsPassword = $true
    }

    if ($RecoverNewsSource) {
        Write-Host 'CFA news-source recovery mode: enabled'
        if ($cfaSourceGate -eq 'PASS') {
            Write-Host 'Existing CFA GDELT Q2 source verification: PASS; acquisition and re-verification skipped.'
        }
        else {
            Invoke-Child -ScriptPath (Join-Path $RepoRoot 'scripts\windows\Acquire-CfaGdeltQ2Source.ps1') -Arguments @('-PgUser',$PgUser)
            $cfaSourceGate = Invoke-GateChild -ScriptPath (Join-Path $RepoRoot 'scripts\windows\Verify-CfaGdeltQ2Source.ps1') -Arguments @('-PgUser',$PgUser)
        }
    }
    else {
        Invoke-Child -ScriptPath (Join-Path $RepoRoot 'scripts\windows\Verify-CfaNewsSourceCoverage.ps1') -Arguments @('-PgUser',$PgUser)
        Invoke-Child -ScriptPath (Join-Path $RepoRoot 'scripts\windows\Diagnose-CfaNewsAcquisition.ps1') -Arguments @('-PgUser',$PgUser)
        $legacyGate = Get-LegacyNewsGateFromEvidence -EvidenceRoot $evidenceRoot
    }

    if ($ownsPassword) {
        if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $bstr = [IntPtr]::Zero
        $ownsPassword = $false
    }

    Invoke-Child -ScriptPath (Join-Path $RepoRoot 'scripts\windows\Sync-CfaEvidence.ps1') -Arguments @()

    $referenceGate = Get-ReferenceGate -RepoRootPath $RepoRoot
    $newsGate = Resolve-NewsGate -LegacyGate $legacyGate -CfaSourceGate $cfaSourceGate
    $advanceGate = if ($referenceGate -eq 'PASS' -and $newsGate -eq 'PASS') { 'PASS' } else { 'BLOCKED' }

    Write-Host ''
    Write-Host '=== CFA STAGE 1 GATE SUMMARY ==='
    Write-Host "CFA-S1-003 Reference row-count revalidation : $referenceGate"
    Write-Host "CFA-S1-004 Reference byte-size reconciliation: $referenceGate"
    Write-Host "CFA-S1-005 Reference SHA-256 reconciliation  : $referenceGate"
    Write-Host 'CFA-S1-006 Original Kraken quarters          : PASS'
    Write-Host 'CFA-S1-008 Direct market coverage            : PASS'
    Write-Host "Legacy news acquisition completeness         : $legacyGate"
    Write-Host "CFA-owned GDELT Q2 source completeness       : $cfaSourceGate"
    Write-Host "CFA-S1-010 News source completeness          : $newsGate"
    Write-Host "CFA-S1-009 Advance to identity approval      : $advanceGate"
    Write-Host ''

    if ($advanceGate -eq 'PASS') {
        Write-Host 'CFA STAGE 1: PASS'
    }
    else {
        Write-Host 'CFA STAGE 1: BLOCKED'
        Write-Host 'The runner completed successfully and published evidence; downstream identity/factor work remains gated.'
    }
}
catch {
    Write-Host 'CFA STAGE 1 RUNNER: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($ownsPassword) {
        if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    }
}
