#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$ForceRescan,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestValidRun {
    param([string]$Parent)
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { return $null }
    foreach ($run in @(Get-ChildItem -LiteralPath $Parent -Directory -Force | Sort-Object Name -Descending)) {
        $summaryPath = Join-Path $run.FullName 'recovery-summary.csv'
        $aliasPath = Join-Path $run.FullName 'alias-recovery.csv'
        if (-not ((Test-Path -LiteralPath $summaryPath -PathType Leaf) -and (Test-Path -LiteralPath $aliasPath -PathType Leaf))) { continue }
        $summary = @(Import-Csv -LiteralPath $summaryPath)
        $aliases = @(Import-Csv -LiteralPath $aliasPath)
        if ($summary.Count -ne 1 -or $aliases.Count -ne 45) { continue }
        if ([int]$summary[0].archive_files -ne 7163) { continue }
        if ([long]$summary[0].quarantined_rows -ne [long]$summary[0].expected_quarantined_rows) { continue }
        return $run
    }
    return $null
}

function Invoke-Child {
    param([string]$Path,[string[]]$Arguments)
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host ([string]$line) }
    if ($code -ne 0) { throw "Child failed ${code}: $Path" }
}

function Convert-RecoveryExitCodeToGate {
    param([int]$ExitCode)
    if ($ExitCode -eq 0) { return 'PASS' }
    if ($ExitCode -eq 2) { return 'FAIL' }
    throw "Unexpected recovery scan exit code: $ExitCode"
}

function Invoke-Recovery {
    param([string]$Path,[string[]]$Arguments)
    # Capture child stdout locally so progress/reporting text does not become part of
    # the function's success-output stream. Only the exit code determines the gate.
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1)
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Host ([string]$line) }
    return (Convert-RecoveryExitCodeToGate -ExitCode $code)
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-alias-recovery-run-' + [guid]::NewGuid().ToString('N'))
    try {
        $runPath = Join-Path $root 'gdelt-alias-recovery\20260101-test'
        New-Item -ItemType Directory -Path $runPath -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runPath 'recovery-summary.csv'),"archive_files,quarantined_rows,expected_quarantined_rows`n7163,5,5`n")
        $rows = @()
        for ($i=1; $i -le 45; $i++) { $rows += [pscustomobject]@{base_asset_id=('A'+$i)} }
        $rows | Export-Csv -LiteralPath (Join-Path $runPath 'alias-recovery.csv') -NoTypeInformation
        $resolved = Get-LatestValidRun -Parent (Join-Path $root 'gdelt-alias-recovery')
        if ($null -eq $resolved -or $resolved.Name -ne '20260101-test') { throw 'reuse detection' }
        if ((Convert-RecoveryExitCodeToGate 0) -ne 'PASS') { throw 'exit 0 gate' }
        if ((Convert-RecoveryExitCodeToGate 2) -ne 'FAIL') { throw 'exit 2 gate' }
        $blocked = $false
        try { [void](Convert-RecoveryExitCodeToGate 1) } catch { $blocked = $true }
        if (-not $blocked) { throw 'unexpected exit code not blocked' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $parent = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\gdelt-alias-recovery'

    $run = $null
    $gate = 'UNVERIFIED'
    if (-not $ForceRescan) { $run = Get-LatestValidRun -Parent $parent }

    if ($null -ne $run) {
        Write-Host ('Reusing completed alias recovery evidence: ' + $run.Name)
        $gate = 'PASS'
    }
    else {
        $gate = Invoke-Recovery -Path (Join-Path $RepoRoot 'scripts\windows\Recover-CfaStage2AliasObservations.ps1') -Arguments @('-RepoRoot',$RepoRoot)
    }

    if ($gate -ne 'PASS') { throw 'Alias recovery parser/quarantine gate is not PASS.' }

    Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Sync-CfaStage2AliasRecovery.ps1') -Arguments @('-RepoRoot',$RepoRoot)

    Write-Host ''
    Write-Host '=== CFA STAGE 2 ALIAS RECOVERY STATUS ==='
    Write-Host ('Recovered parser/quarantine gate : ' + $gate)
    Write-Host 'Alias semantic validation        : REVIEW_REQUIRED'
    Write-Host 'Reason: multi-surface observation evidence is published; context-sensitive aliases still require semantic review.'
    Write-Host 'CFA STAGE 2 ALIAS RECOVERY RUNNER: PASS'
}
catch {
    Write-Host 'CFA STAGE 2 ALIAS RECOVERY RUNNER: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
