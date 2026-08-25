#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$EvidenceRoot = '',
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

function Get-LatestRun {
    param([string]$ParentPath)
    if (-not (Test-Path -LiteralPath $ParentPath -PathType Container)) { throw "Stage 2 evidence directory missing: $ParentPath" }
    $runs = @(Get-ChildItem -LiteralPath $ParentPath -Directory -Force | Sort-Object Name -Descending)
    if ($runs.Count -eq 0) { throw "No CoinGecko identity evidence runs found under: $ParentPath" }
    return $runs[0]
}

function Require-File {
    param([System.IO.DirectoryInfo]$Run,[string]$Name)
    $path = Join-Path $Run.FullName $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required Stage 2 evidence file missing from $($Run.Name): $Name" }
    return $path
}

function Get-TextWithoutBom {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return $text.TrimEnd("`r","`n")
}

function Count-Decision {
    param([object[]]$Rows,[string]$Decision)
    return @($Rows | Where-Object { [string]$_.cfa_independent_review_decision -eq $Decision }).Count
}

function Write-Stage2Receipt {
    param([string]$EvidenceRootPath,[string]$RepoRootPath)

    $run = Get-LatestRun -ParentPath (Join-Path $EvidenceRootPath 'coingecko-identity')
    $summaryPath = Require-File -Run $run -Name 'run-summary.csv'
    $sourcePath = Require-File -Run $run -Name 'source-files.csv'
    $bridgePath = Require-File -Run $run -Name 'mapping-bridge-evidence.csv'

    $summary = @(Import-Csv -LiteralPath $summaryPath)
    $sources = @(Import-Csv -LiteralPath $sourcePath)
    $bridges = @(Import-Csv -LiteralPath $bridgePath)

    if ($summary.Count -ne 1) { throw "Stage 2 run summary cardinality must be exactly 1; observed $($summary.Count)." }
    if ($bridges.Count -ne 435) { throw "Stage 2 bridge evidence must contain 435 assets; observed $($bridges.Count)." }
    if ([int]$summary[0].candidate_assets -ne 435) { throw "Stage 2 run summary candidate_assets must be 435; observed $($summary[0].candidate_assets)." }
    if ($sources.Count -lt 2) { throw "Stage 2 source manifest is unexpectedly small: $($sources.Count) rows." }

    $allowedDecisions = @('APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE','UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES','UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE')
    $badDecisions = @($bridges | Where-Object { $allowedDecisions -notcontains [string]$_.cfa_independent_review_decision })
    if ($badDecisions.Count -gt 0) { throw "Stage 2 bridge evidence contains $($badDecisions.Count) unsupported decision values." }

    foreach ($source in $sources) {
        if ([string]$source.sha256 -notmatch '^[0-9a-f]{64}$') { throw "Malformed source SHA-256 for $($source.file_name)." }
        if ([long]$source.bytes -le 0) { throw "Non-positive source byte count for $($source.file_name)." }
        if ([string]::IsNullOrWhiteSpace([string]$source.source_url)) { throw "Missing source URL for $($source.file_name)." }
    }

    $approve = Count-Decision -Rows $bridges -Decision 'APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE'
    $multiple = Count-Decision -Rows $bridges -Decision 'UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES'
    $noBridge = Count-Decision -Rows $bridges -Decision 'UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE'
    if (($approve + $multiple + $noBridge) -ne 435) { throw 'Stage 2 decision accounting does not total 435.' }

    $csvOutput = Join-Path $RepoRootPath 'docs\evidence\stage2-coingecko-bridge-evidence.csv'
    $bridges | Sort-Object base_asset_id | Export-Csv -LiteralPath $csvOutput -NoTypeInformation -Encoding UTF8

    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Stage 2 Local CoinGecko / Kraken Bridge Evidence')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Curated evidence from a fresh local CoinGecko public-API acquisition. Raw JSON responses remain under Documents\CFA-local and outside Git. This receipt records source hashes and the bounded 435-asset bridge result only.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- Evidence run: ' + $run.Name)
    [void]$b.AppendLine('- Candidate assets: 435')
    [void]$b.AppendLine('- Unique current Kraken pair bridges: ' + $approve)
    [void]$b.AppendLine('- Multiple current Kraken pair bridges: ' + $multiple)
    [void]$b.AppendLine('- No current Kraken pair bridge: ' + $noBridge)
    [void]$b.AppendLine('- Raw source files: ' + $sources.Count)
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Run summary')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('```csv')
    [void]$b.AppendLine((Get-TextWithoutBom -Path $summaryPath))
    [void]$b.AppendLine('```')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Raw source file manifest')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('```csv')
    [void]$b.AppendLine((Get-TextWithoutBom -Path $sourcePath))
    [void]$b.AppendLine('```')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Local evidence file hashes')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('| File | SHA-256 |')
    [void]$b.AppendLine('|---|---|')
    foreach ($path in @($summaryPath,$sourcePath,$bridgePath)) {
        [void]$b.AppendLine('| ' + [System.IO.Path]::GetFileName($path) + ' | ' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() + ' |')
    }
    [void]$b.AppendLine('')
    [void]$b.AppendLine('The full normalized 435-asset bridge table is published separately as docs/evidence/stage2-coingecko-bridge-evidence.csv. A unique bridge is independent current evidence that a CoinGecko candidate ID is presently associated with one or more matching Kraken market pairs; it does not by itself validate news aliases.')

    $receiptOutput = Join-Path $RepoRootPath 'docs\evidence\latest-stage2-local.md'
    Write-Utf8NoBom -Path $receiptOutput -Content $b.ToString()

    return [pscustomobject]@{run_id=$run.Name;receipt_path=$receiptOutput;bridge_path=$csvOutput;approve=$approve;multiple=$multiple;no_bridge=$noBridge}
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-stage2-publish-' + [guid]::NewGuid().ToString('N'))
    try {
        $evidenceRoot = Join-Path $root 'CFA-local'
        $run = Join-Path $evidenceRoot 'coingecko-identity\20260101-test'
        $repo = Join-Path $root 'repo'
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs\evidence') -Force | Out-Null

        Write-Utf8NoBom -Path (Join-Path $run 'run-summary.csv') -Content "run_id,candidate_assets,approved_current_kraken_pair_bridge,unverified_multiple_bridges,unverified_no_bridge`n20260101-test,435,435,0,0`n"
        $manifest = "file_name,sha256,bytes,record_count,source_url`ncoins-list.json,$('a'*64),100,10,https://example.invalid/coins`nkraken-tickers-page-001.json,$('b'*64),200,20,https://example.invalid/tickers`n"
        Write-Utf8NoBom -Path (Join-Path $run 'source-files.csv') -Content $manifest
        $rows = @()
        for ($i=1; $i -le 435; $i++) {
            $rows += [pscustomobject]@{base_asset_id=('A{0:D3}' -f $i);base_exchange_symbol=('A{0:D3}' -f $i);quote_exchange_symbols='USD';candidate_count=1;candidate_ids=('coin-'+$i);active_candidate_ids=('coin-'+$i);kraken_pair_bridge_candidate_ids=('coin-'+$i);kraken_pair_bridge_counts=(('coin-'+$i)+':1');cfa_independent_review_decision='APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE';approved_candidate_id=('coin-'+$i)}
        }
        $rows | Export-Csv -LiteralPath (Join-Path $run 'mapping-bridge-evidence.csv') -NoTypeInformation -Encoding UTF8

        $result = Write-Stage2Receipt -EvidenceRootPath $evidenceRoot -RepoRootPath $repo
        if (-not (Test-Path -LiteralPath $result.receipt_path -PathType Leaf)) { throw 'Self-test failed: Stage 2 receipt missing.' }
        if (-not (Test-Path -LiteralPath $result.bridge_path -PathType Leaf)) { throw 'Self-test failed: Stage 2 bridge output missing.' }
        $text = [System.IO.File]::ReadAllText($result.receipt_path)
        if (-not $text.Contains('20260101-test') -or -not $text.Contains('Unique current Kraken pair bridges: 435')) { throw 'Self-test failed: receipt content missing.' }
        if ($text.Contains($root)) { throw 'Self-test failed: absolute local path leaked into receipt.' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $EvidenceRoot = (Resolve-Path -LiteralPath $EvidenceRoot).ProviderPath
    $result = Write-Stage2Receipt -EvidenceRootPath $EvidenceRoot -RepoRootPath $RepoRoot
    Write-Host ('Stage 2 evidence run: ' + $result.run_id)
    Write-Host ('Unique current Kraken pair bridges: ' + $result.approve)
    Write-Host ('Multiple current Kraken pair bridges: ' + $result.multiple)
    Write-Host ('No current Kraken pair bridge: ' + $result.no_bridge)
    Write-Host 'CFA STAGE 2 EVIDENCE PUBLISH: PASS'
}
catch {
    Write-Host 'CFA STAGE 2 EVIDENCE PUBLISH: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
