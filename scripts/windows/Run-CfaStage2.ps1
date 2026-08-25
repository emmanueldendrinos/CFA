#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Stage1Pass {
    param([string]$RepoRootPath)
    $path = Join-Path $RepoRootPath 'docs\stage1-validation-status.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Stage 1 status receipt is missing.' }
    $text = [System.IO.File]::ReadAllText($path)
    foreach ($gate in @('CFA-S1-009','CFA-S1-010')) {
        $pattern = '\|\s*' + [regex]::Escape($gate) + '[^|]*\|\s*PASS\s*\|'
        if ($text -notmatch $pattern) { throw "Stage 1 prerequisite is not PASS in control receipt: $gate" }
    }
}

function Assert-Stage2StructuralPass {
    param([string]$RepoRootPath)
    $path = Join-Path $RepoRootPath 'docs\evidence\stage2-identity-review.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Stage 2 structural review JSON is missing.' }
    $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($gateId in @('CFA-S2-001','CFA-S2-002','CFA-S2-004')) {
        $matches = @($obj.gates | Where-Object { [string]$_.gate_id -eq $gateId })
        if ($matches.Count -ne 1 -or [string]$matches[0].status -ne 'PASS') { throw "Stage 2 structural prerequisite is not PASS: $gateId" }
    }
}

function Invoke-Child {
    param([string]$Path,[string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required Stage 2 child script missing: $Path" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Stage 2 child script failed with exit code ' + $LASTEXITCODE + ': ' + $Path) }
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-stage2-run-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path (Join-Path $root 'docs\evidence') -Force | Out-Null
        $status = @'
| Gate | Status | Evidence |
|---|---|---|
| CFA-S1-009 Advance to identity approval | PASS | x |
| CFA-S1-010 News source acquisition completeness | PASS | y |
'@
        [System.IO.File]::WriteAllText((Join-Path $root 'docs\stage1-validation-status.md'),$status)
        $json = [ordered]@{gates=@([pscustomobject]@{gate_id='CFA-S2-001';status='PASS'},[pscustomobject]@{gate_id='CFA-S2-002';status='PASS'},[pscustomobject]@{gate_id='CFA-S2-004';status='PASS'})} | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $root 'docs\evidence\stage2-identity-review.json'),$json)
        Assert-Stage1Pass -RepoRootPath $root
        Assert-Stage2StructuralPass -RepoRootPath $root
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
    Assert-Stage1Pass -RepoRootPath $RepoRoot
    Assert-Stage2StructuralPass -RepoRootPath $RepoRoot

    Write-Host 'Stage 1 prerequisite: PASS'
    Write-Host 'Stage 2 structural prerequisites CFA-S2-001/002/004: PASS'
    Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Acquire-CfaCoinGeckoIdentityEvidence.ps1') -Arguments @('-RepoRoot',$RepoRoot)
    Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Sync-CfaStage2Evidence.ps1') -Arguments @('-RepoRoot',$RepoRoot)

    Write-Host ''
    Write-Host '=== CFA STAGE 2 EVIDENCE STATUS ==='
    Write-Host 'CFA-S2-001 Eligible Kraken base-asset universe reconciliation : PASS'
    Write-Host 'CFA-S2-002 CoinGecko candidate-file structural integrity      : PASS'
    Write-Host 'CFA-S2-004 Alias seed structural linkage                     : PASS'
    Write-Host 'CFA-S2-003 CoinGecko mapping decisions                       : REVIEW_REQUIRED'
    Write-Host 'CFA-S2-005 Alias semantic validation                         : UNVERIFIED'
    Write-Host 'CFA-S2-006 Advance to news matching definition               : BLOCKED'
    Write-Host 'Independent CoinGecko/Kraken bridge evidence is published for repository review.'
}
catch {
    Write-Host 'CFA STAGE 2 RUNNER: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
