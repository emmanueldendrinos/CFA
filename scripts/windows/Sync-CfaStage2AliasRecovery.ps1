#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AllowedPaths = @(
    'docs/evidence/stage2-alias-recovery.md',
    'docs/evidence/stage2-alias-recovery.csv',
    'docs/evidence/stage2-alias-recovery-samples.csv',
    'docs/evidence/stage2-alias-quarantine.csv'
)

function Invoke-Git {
    param(
        [string]$Root,
        [string[]]$Arguments
    )
    Push-Location $Root
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed $exitCode`n$text"
        }
        return $text.Trim()
    }
    finally {
        $ErrorActionPreference = $oldPreference
        Pop-Location
    }
}

function Split-Lines {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-Allowed {
    param([AllowEmptyString()][string]$Status)
    foreach ($line in @(Split-Lines -Text $Status)) {
        $ok = $false
        foreach ($path in $AllowedPaths) {
            if ($line.EndsWith($path) -or $line.EndsWith($path.Replace('/','\'))) {
                $ok = $true
                break
            }
        }
        if (-not $ok) { throw "Unexpected working-tree change during alias recovery sync: $line" }
    }
}

function Assert-Paths {
    param([string[]]$Paths)
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($AllowedPaths -notcontains $path) { throw "Unexpected staged path: $path" }
    }
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-alias-recovery-sync-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        # Exercise the real Invoke-Git path so automatic-variable collisions or
        # argument-binding failures cannot pass CI unnoticed.
        [void](Invoke-Git -Root $root -Arguments @('init'))
        $inside = Invoke-Git -Root $root -Arguments @('rev-parse','--is-inside-work-tree')
        if ($inside -ne 'true') { throw "Invoke-Git self-test failed; observed: $inside" }

        $status = "?? docs/evidence/stage2-alias-recovery.md`n?? docs/evidence/stage2-alias-quarantine.csv"
        Assert-Allowed -Status $status
        $split = @(Split-Lines -Text "docs/evidence/stage2-alias-recovery.md`ndocs/evidence/stage2-alias-quarantine.csv")
        if ($split.Count -ne 2) { throw 'line split' }
        Assert-Paths -Paths $split

        $blocked = $false
        try { Assert-Allowed -Status " M README.md" } catch { $blocked = $true }
        if (-not $blocked) { throw 'unrelated change not blocked' }

        Write-Host 'SELF-TEST: PASS'
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
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

    $branch = Invoke-Git -Root $RepoRoot -Arguments @('branch','--show-current')
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Branch unresolved.' }

    # Preserve only previously generated authorized recovery evidence from a
    # failed sync attempt; block any unrelated working-tree changes.
    $preStatus = Invoke-Git -Root $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    Assert-Allowed -Status $preStatus

    [void](Invoke-Git -Root $RepoRoot -Arguments @('pull','--ff-only','origin',$branch))

    $publisher = Join-Path $RepoRoot 'scripts\windows\Publish-CfaStage2AliasRecovery.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher -SelfTest
    if ($LASTEXITCODE -ne 0) { throw 'Publisher self-test failed.' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publisher
    if ($LASTEXITCODE -ne 0) { throw 'Publisher failed.' }

    $after = Invoke-Git -Root $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    Assert-Allowed -Status $after
    $changed = @(Split-Lines -Text $after)

    if ($changed.Count -gt 0) {
        [void](Invoke-Git -Root $RepoRoot -Arguments (@('add','--') + $AllowedPaths))
        $staged = @(Split-Lines -Text (Invoke-Git -Root $RepoRoot -Arguments @('diff','--cached','--name-only')))
        Assert-Paths -Paths $staged
        if ($staged.Count -gt 0) {
            [void](Invoke-Git -Root $RepoRoot -Arguments @('commit','-m','Update CFA Stage 2 alias recovery evidence'))
            [void](Invoke-Git -Root $RepoRoot -Arguments @('push','origin',$branch))
        }
    }

    [void](Invoke-Git -Root $RepoRoot -Arguments @('fetch','origin',$branch))
    $local = Invoke-Git -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    $remote = Invoke-Git -Root $RepoRoot -Arguments @('rev-parse',"origin/$branch")
    if ($local -ne $remote) { throw "Local/remote mismatch $local $remote" }

    $finalStatus = Invoke-Git -Root $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
    if (-not [string]::IsNullOrWhiteSpace($finalStatus)) {
        throw "Repository not clean.`n$finalStatus"
    }

    foreach ($path in $AllowedPaths) {
        $found = Invoke-Git -Root $RepoRoot -Arguments @('ls-tree','-r','--name-only',"origin/$branch",'--',$path)
        if ($found -ne $path) { throw "Published alias recovery evidence missing from remote: $path" }
    }

    Write-Host "Published alias recovery evidence commit: $local"
    Write-Host 'CFA STAGE 2 ALIAS RECOVERY SYNC: PASS'
}
catch {
    Write-Host 'CFA STAGE 2 ALIAS RECOVERY SYNC: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
