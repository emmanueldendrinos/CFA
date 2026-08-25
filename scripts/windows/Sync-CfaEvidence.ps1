#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-KnownCommandDebris {
    param([Parameter(Mandatory)][string]$RepoRootPath)

    $debrisPath = Join-Path $RepoRootPath '-File'
    if (-not (Test-Path -LiteralPath $debrisPath)) {
        return $false
    }

    $item = Get-Item -LiteralPath $debrisPath -Force
    if ($item.PSIsContainer) {
        throw "Refusing to remove '$debrisPath' because it is a directory, not the known zero-byte command artifact."
    }
    if ([long]$item.Length -ne 0) {
        throw "Refusing to remove '$debrisPath' because it is not zero bytes (observed $($item.Length) bytes)."
    }

    Remove-Item -LiteralPath $debrisPath -Force
    if (Test-Path -LiteralPath $debrisPath) {
        throw "Failed to remove known command artifact: $debrisPath"
    }

    Write-Host "Removed known zero-byte command artifact: $debrisPath"
    return $true
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Push-Location $WorkingDirectory
    try {
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$text"
        }
        return $text.Trim()
    }
    finally {
        Pop-Location
    }
}

function Assert-PublishedEvidenceState {
    param(
        [Parameter(Mandatory)][string]$LocalHead,
        [Parameter(Mandatory)][string]$RemoteHead,
        [AllowEmptyString()][string]$WorkingTreeStatus,
        [AllowEmptyString()][string]$RemoteReceiptPaths
    )

    if ([string]::IsNullOrWhiteSpace($LocalHead) -or [string]::IsNullOrWhiteSpace($RemoteHead)) {
        throw 'Local or remote HEAD could not be resolved after evidence publication.'
    }
    if ($LocalHead -ne $RemoteHead) {
        throw "Evidence publication did not converge local and remote HEAD. Local=$LocalHead Remote=$RemoteHead"
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingTreeStatus)) {
        throw "Repository is not clean after evidence publication.`n$WorkingTreeStatus"
    }

    $receiptPath = 'docs/evidence/latest-local-validation.md'
    $remotePaths = @($RemoteReceiptPaths -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($remotePaths.Count -ne 1 -or $remotePaths[0] -ne $receiptPath) {
        throw "Published evidence receipt is not present exactly once on the remote branch. Observed: $RemoteReceiptPaths"
    }
}

function Invoke-SelfTest {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-evidence-sync-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

        $emptyDebris = Join-Path $tempRoot '-File'
        [System.IO.File]::WriteAllBytes($emptyDebris, [byte[]]@())
        $removed = Remove-KnownCommandDebris -RepoRootPath $tempRoot
        if (-not $removed -or (Test-Path -LiteralPath $emptyDebris)) {
            throw 'Self-test failed: zero-byte -File artifact was not removed.'
        }

        $removedAgain = Remove-KnownCommandDebris -RepoRootPath $tempRoot
        if ($removedAgain) {
            throw 'Self-test failed: absent debris was reported as removed.'
        }

        $nonEmptyDebris = Join-Path $tempRoot '-File'
        [System.IO.File]::WriteAllText($nonEmptyDebris, 'preserve-me')
        $blocked = $false
        try {
            [void](Remove-KnownCommandDebris -RepoRootPath $tempRoot)
        }
        catch {
            $blocked = $true
        }
        if (-not $blocked) {
            throw 'Self-test failed: non-empty -File artifact was not blocked.'
        }
        if (-not (Test-Path -LiteralPath $nonEmptyDebris -PathType Leaf)) {
            throw 'Self-test failed: non-empty -File artifact was deleted.'
        }
        if ([System.IO.File]::ReadAllText($nonEmptyDebris) -ne 'preserve-me') {
            throw 'Self-test failed: non-empty -File artifact was modified.'
        }

        Assert-PublishedEvidenceState `
            -LocalHead ('a' * 40) `
            -RemoteHead ('a' * 40) `
            -WorkingTreeStatus '' `
            -RemoteReceiptPaths 'docs/evidence/latest-local-validation.md'

        $stateBlocked = $false
        try {
            Assert-PublishedEvidenceState `
                -LocalHead ('a' * 40) `
                -RemoteHead ('b' * 40) `
                -WorkingTreeStatus '' `
                -RemoteReceiptPaths 'docs/evidence/latest-local-validation.md'
        }
        catch {
            $stateBlocked = $true
        }
        if (-not $stateBlocked) {
            throw 'Self-test failed: local/remote HEAD mismatch was not blocked.'
        }

        $receiptBlocked = $false
        try {
            Assert-PublishedEvidenceState `
                -LocalHead ('a' * 40) `
                -RemoteHead ('a' * 40) `
                -WorkingTreeStatus '' `
                -RemoteReceiptPaths ''
        }
        catch {
            $receiptBlocked = $true
        }
        if (-not $receiptBlocked) {
            throw 'Self-test failed: missing remote receipt was not blocked.'
        }

        Write-Host 'SELF-TEST: PASS'
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    try {
        Invoke-SelfTest
        exit 0
    }
    catch {
        Write-Host 'SELF-TEST: FAIL'
        Write-Host $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) { Write-Host $_.ScriptStackTrace }
        exit 1
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

    $repoTop = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse','--show-toplevel')
    if ([System.IO.Path]::GetFullPath($repoTop).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')) {
        throw "RepoRoot is not the Git repository top level: $RepoRoot"
    }

    $branch = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('branch','--show-current')
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Could not determine current Git branch.' }

    [void](Remove-KnownCommandDebris -RepoRootPath $RepoRoot)

    $status = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "Repository still has uncommitted changes after guarded debris cleanup.`n$status"
    }

    [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('pull','--ff-only','origin',$branch))

    $publisher = Join-Path $RepoRoot 'scripts\windows\Publish-CfaLocalEvidence.ps1'
    if (-not (Test-Path -LiteralPath $publisher -PathType Leaf)) {
        throw "Evidence publisher not found: $publisher"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "Evidence publisher self-test failed with exit code $LASTEXITCODE."
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -CommitAndPush
    if ($LASTEXITCODE -ne 0) {
        throw "Evidence publication failed with exit code $LASTEXITCODE."
    }

    [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('fetch','origin',$branch))
    $localHead = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse','HEAD')
    $remoteHead = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse',"origin/$branch")
    $finalStatus = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    $remoteReceiptPaths = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('ls-tree','-r','--name-only',"origin/$branch",'--','docs/evidence/latest-local-validation.md')

    Assert-PublishedEvidenceState `
        -LocalHead $localHead `
        -RemoteHead $remoteHead `
        -WorkingTreeStatus $finalStatus `
        -RemoteReceiptPaths $remoteReceiptPaths

    Write-Host "Published evidence commit: $localHead"
    Write-Host 'Remote receipt: docs/evidence/latest-local-validation.md'
    Write-Host 'CFA EVIDENCE SYNC: PASS'
}
catch {
    Write-Host 'CFA EVIDENCE SYNC: FAIL'
    Write-Host $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) { Write-Host $_.ScriptStackTrace }
    exit 1
}
