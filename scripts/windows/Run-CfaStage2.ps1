#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Stage1Pass {
    param([string]$Root)
    $path = Join-Path $Root 'docs\stage1-validation-status.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Stage 1 status receipt missing.' }
    $text = [System.IO.File]::ReadAllText($path)
    foreach ($gate in @('CFA-S1-009','CFA-S1-010')) {
        $pattern = '\|\s*' + [regex]::Escape($gate) + '[^|]*\|\s*PASS\s*\|'
        if ($text -notmatch $pattern) { throw "Stage 1 prerequisite not PASS: $gate" }
    }
}

function Assert-Stage2StructuralPass {
    param([string]$Root)
    $path = Join-Path $Root 'docs\evidence\stage2-identity-review.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Stage 2 structural review missing.' }
    $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    foreach ($gate in @('CFA-S2-001','CFA-S2-002','CFA-S2-004')) {
        $matches = @($obj.gates | Where-Object { [string]$_.gate_id -eq $gate })
        if ($matches.Count -ne 1 -or [string]$matches[0].status -ne 'PASS') {
            throw "Stage 2 structural prerequisite not PASS: $gate"
        }
    }
}

function Invoke-Child {
    param([string]$Path,[string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing child script: $Path" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Child failed ' + $LASTEXITCODE + ': ' + $Path) }
}

function Get-ReusableCoinGeckoRun {
    param([string]$EvidenceRoot)
    $parent = Join-Path $EvidenceRoot 'coingecko-identity'
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return $null }

    $runs = @(Get-ChildItem -LiteralPath $parent -Directory -Force | Sort-Object Name -Descending)
    foreach ($run in $runs) {
        $summaryPath = Join-Path $run.FullName 'run-summary.csv'
        $bridgePath = Join-Path $run.FullName 'mapping-bridge-evidence.csv'
        $sourcePath = Join-Path $run.FullName 'source-files.csv'
        if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf)) { continue }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }

        try {
            $summary = @(Import-Csv -LiteralPath $summaryPath)
            $bridges = @(Import-Csv -LiteralPath $bridgePath)
            $sources = @(Import-Csv -LiteralPath $sourcePath)
            if ($summary.Count -ne 1) { continue }
            if ([int]$summary[0].candidate_assets -ne 435) { continue }
            if ($bridges.Count -ne 435) { continue }
            if ($sources.Count -lt 2) { continue }

            $allowed = @(
                'APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE',
                'UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES',
                'UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE'
            )
            if (@($bridges | Where-Object { $allowed -notcontains [string]$_.cfa_independent_review_decision }).Count -ne 0) { continue }
            return $run
        }
        catch { continue }
    }
    return $null
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-s2-run-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path (Join-Path $root 'docs\evidence') -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $root 'docs\stage1-validation-status.md'),
            "| Gate | Status |`n|---|---|`n| CFA-S1-009 Advance | PASS |`n| CFA-S1-010 News | PASS |`n"
        )
        $json = [ordered]@{
            gates = @(
                [pscustomobject]@{gate_id='CFA-S2-001';status='PASS'},
                [pscustomobject]@{gate_id='CFA-S2-002';status='PASS'},
                [pscustomobject]@{gate_id='CFA-S2-004';status='PASS'}
            )
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $root 'docs\evidence\stage2-identity-review.json'),$json)
        Assert-Stage1Pass -Root $root
        Assert-Stage2StructuralPass -Root $root

        $evidenceRoot = Join-Path $root 'CFA-local'
        $run = Join-Path $evidenceRoot 'coingecko-identity\20260825-test'
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $run 'run-summary.csv'),"candidate_assets`n435`n")
        [System.IO.File]::WriteAllText((Join-Path $run 'source-files.csv'),"file_name`na`nb`n")
        $rows = @()
        for ($i = 1; $i -le 435; $i++) {
            $rows += [pscustomobject]@{base_asset_id=('A{0:D3}' -f $i);cfa_independent_review_decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE'}
        }
        $rows | Export-Csv -LiteralPath (Join-Path $run 'mapping-bridge-evidence.csv') -NoTypeInformation -Encoding UTF8
        $reusable = Get-ReusableCoinGeckoRun -EvidenceRoot $evidenceRoot
        if ($null -eq $reusable -or $reusable.Name -ne '20260825-test') { throw 'Reusable CoinGecko evidence detection failed.' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $evidenceRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local'

    Assert-Stage1Pass -Root $RepoRoot
    Assert-Stage2StructuralPass -Root $RepoRoot
    Write-Host 'Stage 1 prerequisite: PASS'
    Write-Host 'Stage 2 structural prerequisites CFA-S2-001/002/004: PASS'

    $reusable = Get-ReusableCoinGeckoRun -EvidenceRoot $evidenceRoot
    if ($null -ne $reusable) {
        Write-Host ('Reusing completed CoinGecko identity evidence: ' + $reusable.Name)
    }
    else {
        Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Acquire-CfaCoinGeckoIdentityEvidence.ps1') -Arguments @('-RepoRoot',$RepoRoot)
    }

    Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Inspect-CfaGdeltGkgStructure.ps1') -Arguments @()
    Invoke-Child -Path (Join-Path $RepoRoot 'scripts\windows\Sync-CfaStage2Evidence.ps1') -Arguments @('-RepoRoot',$RepoRoot)

    Write-Host ''
    Write-Host '=== CFA STAGE 2 EVIDENCE STATUS ==='
    Write-Host 'CFA-S2-001 Eligible Kraken base-asset universe reconciliation : PASS'
    Write-Host 'CFA-S2-002 CoinGecko candidate-file structural integrity      : PASS'
    Write-Host 'CFA-S2-004 Alias seed structural linkage                     : PASS'
    Write-Host 'CFA-S2-003 CoinGecko mapping decisions                       : REVIEW_REQUIRED'
    Write-Host 'CFA-S2-005 Alias semantic validation                         : UNVERIFIED'
    Write-Host 'CFA-S2-006 Advance to news matching definition               : BLOCKED'
    Write-Host 'CoinGecko/Kraken bridge evidence and binary-safe GDELT structure evidence are published for repository review.'
}
catch {
    Write-Host 'CFA STAGE 2 RUNNER: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
