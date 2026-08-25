#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AllowedPaths = @(
    'docs/evidence/latest-stage2-local.md',
    'docs/evidence/stage2-coingecko-bridge-evidence.csv'
)

function Invoke-Git {
    param([string]$WorkingDirectory,[string[]]$Arguments)
    Push-Location $WorkingDirectory
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$text" }
        return $text.Trim()
    }
    finally { $ErrorActionPreference = $oldPreference; Pop-Location }
}

function Split-GitLines {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Remove-KnownCommandDebris {
    param([string]$RepoRootPath)
    $path = Join-Path $RepoRootPath '-File'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.PSIsContainer -or [long]$item.Length -ne 0) { throw "Refusing to remove unexpected -File object: $path" }
    Remove-Item -LiteralPath $path -Force
}

function Assert-OnlyAllowedChanges {
    param([AllowEmptyString()][string]$StatusText)
    $lines = @(Split-GitLines -Text $StatusText)
    foreach ($line in $lines) {
        $matched = $false
        foreach ($path in $AllowedPaths) {
            if ($line.EndsWith($path) -or $line.EndsWith($path.Replace('/','\'))) { $matched = $true; break }
        }
        if (-not $matched) { throw "Unexpected working-tree change during Stage 2 sync: $line" }
    }
}

function Assert-OnlyAllowedPaths {
    param([string[]]$Paths)
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($AllowedPaths -notcontains $path) { throw "Unexpected staged path: $path" }
    }
}

function Assert-PublishedState {
    param([string]$LocalHead,[string]$RemoteHead,[AllowEmptyString()][string]$Status,[string[]]$RemotePaths)
    if ([string]::IsNullOrWhiteSpace($LocalHead) -or $LocalHead -ne $RemoteHead) { throw "Stage 2 evidence sync did not converge local/remote HEAD. Local=$LocalHead Remote=$RemoteHead" }
    if (-not [string]::IsNullOrWhiteSpace($Status)) { throw "Repository is not clean after Stage 2 sync.`n$Status" }
    $observed = @($RemotePaths | Sort-Object)
    $expected = @($AllowedPaths | Sort-Object)
    if ($observed.Count -ne $expected.Count) { throw 'Remote Stage 2 evidence path count mismatch.' }
    for ($i=0; $i -lt $expected.Count; $i++) { if ($observed[$i] -ne $expected[$i]) { throw "Remote Stage 2 evidence mismatch: $($observed[$i]) vs $($expected[$i])" } }
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-stage2-sync-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $twoChanges = "?? docs/evidence/latest-stage2-local.md`n?? docs/evidence/stage2-coingecko-bridge-evidence.csv"
        Assert-OnlyAllowedChanges -StatusText $twoChanges
        $split = @(Split-GitLines -Text "docs/evidence/latest-stage2-local.md`ndocs/evidence/stage2-coingecko-bridge-evidence.csv")
        if ($split.Count -ne 2) { throw "Self-test failed: multiline Git output did not split into two paths; observed $($split.Count)." }
        Assert-OnlyAllowedPaths -Paths $split
        $blocked = $false
        try { Assert-OnlyAllowedChanges -StatusText "?? docs/evidence/latest-stage2-local.md`n M README.md" } catch { $blocked = $true }
        if (-not $blocked) { throw 'Self-test failed: unrelated change not blocked.' }
        Assert-PublishedState -LocalHead ('a'*40) -RemoteHead ('a'*40) -Status '' -RemotePaths $AllowedPaths
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
    $top = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse','--show-toplevel')
    if ([System.IO.Path]::GetFullPath($top).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')) { throw 'RepoRoot is not repository top level.' }
    $branch = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('branch','--show-current')
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Current Git branch is unresolved.' }

    Remove-KnownCommandDebris -RepoRootPath $RepoRoot

    # A prior failed Stage 2 sync may have already generated/staged exactly the two
    # authorized evidence files. Preserve and recover that state; block everything else.
    $preStatus = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    Assert-OnlyAllowedChanges -StatusText $preStatus

    [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('pull','--ff-only','origin',$branch))

    $publisher = Join-Path $RepoRoot 'scripts\windows\Publish-CfaStage2Evidence.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'Stage 2 publisher self-test failed.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher
    if ($LASTEXITCODE -ne 0) { throw 'Stage 2 publisher failed.' }

    $after = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    Assert-OnlyAllowedChanges -StatusText $after
    $changed = @(Split-GitLines -Text $after)
    if ($changed.Count -gt 0) {
        [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments (@('add','--') + $AllowedPaths))
        $stagedText = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('diff','--cached','--name-only')
        $staged = @(Split-GitLines -Text $stagedText)
        Assert-OnlyAllowedPaths -Paths $staged
        if ($staged.Count -gt 0) {
            [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('commit','-m','Update CFA Stage 2 local evidence'))
            [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('push','origin',$branch))
        }
    }

    [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('fetch','origin',$branch))
    $local = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse','HEAD')
    $remote = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse',"origin/$branch")
    $finalStatus = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    $remotePaths = @()
    foreach ($path in $AllowedPaths) {
        $found = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('ls-tree','-r','--name-only',"origin/$branch",'--',$path)
        if (-not [string]::IsNullOrWhiteSpace($found)) { $remotePaths += @(Split-GitLines -Text $found) }
    }
    Assert-PublishedState -LocalHead $local -RemoteHead $remote -Status $finalStatus -RemotePaths $remotePaths
    Write-Host "Published Stage 2 evidence commit: $local"
    Write-Host 'CFA STAGE 2 EVIDENCE SYNC: PASS'
}
catch {
    Write-Host 'CFA STAGE 2 EVIDENCE SYNC: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}