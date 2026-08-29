#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CfaLocalRoot = '',
    [string]$ExternalDriveRoot = 'D:\',
    [long]$MaxCopyBytes = 20971520,
    [long]$MaxHashBytes = 134217728
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Get-LatestDirectory {
    param([Parameter(Mandatory)][string]$Parent)
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $Parent -Directory -Force -ErrorAction Stop |
        Sort-Object Name -Descending |
        Select-Object -First 1
}

function Get-Sha256Maybe {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File,[long]$LimitBytes)
    if ($File.Length -gt $LimitBytes) { return $null }
    return (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Add-EvidenceFile {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$DestinationDir,
        [AllowEmptyCollection()][Parameter(Mandatory)][System.Collections.ArrayList]$Index
    )

    $hash = Get-Sha256Maybe -File $File -LimitBytes $MaxHashBytes
    $copied = $false
    $destination = ''
    if ($File.Length -le $MaxCopyBytes) {
        if (-not (Test-Path -LiteralPath $DestinationDir -PathType Container)) {
            New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
        }
        $destination = Join-Path $DestinationDir $File.Name
        Copy-Item -LiteralPath $File.FullName -Destination $destination -Force
        $copied = $true

        $copiedFile = Get-Item -LiteralPath $destination -Force
        if ($copiedFile.Length -ne $File.Length) {
            throw "Copied evidence size mismatch: $($File.FullName)"
        }
        if ($null -ne $hash) {
            $copiedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($copiedHash -ne $hash) {
                throw "Copied evidence SHA-256 mismatch: $($File.FullName)"
            }
        }
    }

    [void]$Index.Add([pscustomobject]@{
        role = $Role
        source_path = $File.FullName
        file_name = $File.Name
        size_bytes = [long]$File.Length
        sha256 = $hash
        copied = $copied
        destination_path = $destination
    })
}

if ([string]::IsNullOrWhiteSpace($CfaLocalRoot)) {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $CfaLocalRoot = Join-Path $documents 'CFA-local'
}

if (-not (Test-Path -LiteralPath $CfaLocalRoot -PathType Container)) {
    throw "CFA-local root not found: $CfaLocalRoot"
}
if (-not (Test-Path -LiteralPath $ExternalDriveRoot -PathType Container)) {
    throw "External drive root not found: $ExternalDriveRoot"
}

$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$outputRoot = Join-Path $ExternalDriveRoot ('CFA-recovery\evidence\' + $runId)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$index = New-Object System.Collections.ArrayList
$sourceSelections = New-Object System.Collections.ArrayList

$externalPgParent = Join-Path $CfaLocalRoot 'external-postgres-inventory'
$externalPgRun = Get-LatestDirectory -Parent $externalPgParent
if ($null -ne $externalPgRun) {
    foreach ($dbName in @('pls_trading','pls_trading_pre_v130')) {
        $dbDir = Join-Path $externalPgRun.FullName $dbName
        if (-not (Test-Path -LiteralPath $dbDir -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $dbDir -File -Force | Sort-Object Name)) {
            Add-EvidenceFile -File $file -Role ('PLS_DB_STRUCTURE_' + $dbName.ToUpperInvariant()) -DestinationDir (Join-Path $outputRoot ('pls-db\' + $dbName)) -Index $index
        }
    }
    [void]$sourceSelections.Add([pscustomobject]@{ category='external_postgres_inventory'; selected_path=$externalPgRun.FullName })
}
else {
    [void]$sourceSelections.Add([pscustomobject]@{ category='external_postgres_inventory'; selected_path='UNVERIFIED_NOT_FOUND' })
}

$dbDiscoveryParent = Join-Path $CfaLocalRoot 'db-discovery'
$dbDiscoveryRun = Get-LatestDirectory -Parent $dbDiscoveryParent
if ($null -ne $dbDiscoveryRun) {
    foreach ($file in @(Get-ChildItem -LiteralPath $dbDiscoveryRun.FullName -File -Force |
        Where-Object { $_.Name -match '^(pls_trading|database-summary|name-triage)' } |
        Sort-Object Name)) {
        Add-EvidenceFile -File $file -Role 'PLS_DB_DISCOVERY_CROSSCHECK' -DestinationDir (Join-Path $outputRoot 'pls-db-discovery') -Index $index
    }
    [void]$sourceSelections.Add([pscustomobject]@{ category='db_discovery'; selected_path=$dbDiscoveryRun.FullName })
}
else {
    [void]$sourceSelections.Add([pscustomobject]@{ category='db_discovery'; selected_path='UNVERIFIED_NOT_FOUND' })
}

$stage3Parent = Join-Path $CfaLocalRoot 'stage3-news-matching'
$stage3Runs = @()
if (Test-Path -LiteralPath $stage3Parent -PathType Container) {
    $stage3Runs = @(Get-ChildItem -LiteralPath $stage3Parent -Directory -Force | Sort-Object Name -Descending)
}

$stage3Manifest = New-Object System.Collections.ArrayList
foreach ($run in $stage3Runs) {
    foreach ($name in @(
        'stage3-match-summary.json',
        'stage3-match-summary.md',
        'stage3-news-matches.csv',
        'stage3-context-rejects.csv',
        'stage3-match-samples.csv'
    )) {
        $path = Join-Path $run.FullName $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $file = Get-Item -LiteralPath $path -Force
        $hash = Get-Sha256Maybe -File $file -LimitBytes $MaxHashBytes
        [void]$stage3Manifest.Add([pscustomobject]@{
            run_id = $run.Name
            file_name = $file.Name
            size_bytes = [long]$file.Length
            sha256 = $hash
            hash_status = if ($null -eq $hash) { 'SKIPPED_SIZE' } else { 'PASS' }
            last_write_utc = $file.LastWriteTimeUtc.ToString('o')
        })
    }
}

if ($stage3Runs.Count -gt 0) {
    $latestStage3 = $stage3Runs[0]
    [void]$sourceSelections.Add([pscustomobject]@{ category='latest_stage3_news_matching'; selected_path=$latestStage3.FullName })
    foreach ($name in @('stage3-match-summary.json','stage3-match-summary.md','stage3-match-samples.csv')) {
        $path = Join-Path $latestStage3.FullName $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Add-EvidenceFile -File (Get-Item -LiteralPath $path -Force) -Role 'LATEST_STAGE3_BOUNDED_EVIDENCE' -DestinationDir (Join-Path $outputRoot 'stage3-latest') -Index $index
        }
    }
}
else {
    [void]$sourceSelections.Add([pscustomobject]@{ category='latest_stage3_news_matching'; selected_path='UNVERIFIED_NOT_FOUND' })
}

$indexPath = Join-Path $outputRoot 'evidence-index.csv'
$selectionPath = Join-Path $outputRoot 'source-selections.csv'
$stage3ManifestPath = Join-Path $outputRoot 'stage3-run-manifest.csv'
$index | Export-Csv -LiteralPath $indexPath -NoTypeInformation -Encoding UTF8
$sourceSelections | Export-Csv -LiteralPath $selectionPath -NoTypeInformation -Encoding UTF8
$stage3Manifest | Export-Csv -LiteralPath $stage3ManifestPath -NoTypeInformation -Encoding UTF8

$missingPls = @($sourceSelections | Where-Object { $_.category -eq 'external_postgres_inventory' -and $_.selected_path -eq 'UNVERIFIED_NOT_FOUND' }).Count
$missingStage3 = @($sourceSelections | Where-Object { $_.category -eq 'latest_stage3_news_matching' -and $_.selected_path -eq 'UNVERIFIED_NOT_FOUND' }).Count

$summary = New-Object System.Text.StringBuilder
[void]$summary.AppendLine('# CFA Recovery Evidence Collection')
[void]$summary.AppendLine('')
[void]$summary.AppendLine('Authority boundary: this bundle contains bounded evidence and recovery leads only. Legacy PLS database structure is not an approved CFA model, method, factor definition, or analytical conclusion.')
[void]$summary.AppendLine('')
[void]$summary.AppendLine("- Run ID: $runId")
[void]$summary.AppendLine("- CFA-local root: $CfaLocalRoot")
[void]$summary.AppendLine("- Evidence files indexed: $($index.Count)")
[void]$summary.AppendLine("- Stage 3 manifest rows: $($stage3Manifest.Count)")
[void]$summary.AppendLine("- PLS structure source present: $([string]($missingPls -eq 0))")
[void]$summary.AppendLine("- Stage 3 source present: $([string]($missingStage3 -eq 0))")
[void]$summary.AppendLine('')
[void]$summary.AppendLine('No PostgreSQL database or source file was modified. No legacy analytical conclusion is promoted to CFA authority.')
Write-Utf8NoBom -Path (Join-Path $outputRoot 'summary.md') -Content $summary.ToString()

$artifactRows = New-Object System.Collections.ArrayList
foreach ($file in @(Get-ChildItem -LiteralPath $outputRoot -File -Recurse -Force | Where-Object { $_.Name -ne 'recovery-evidence-bundle.zip' } | Sort-Object FullName)) {
    [void]$artifactRows.Add([pscustomobject]@{
        relative_path = $file.FullName.Substring($outputRoot.Length).TrimStart('\')
        size_bytes = [long]$file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}
$artifactRows | Export-Csv -LiteralPath (Join-Path $outputRoot 'artifact-hashes.csv') -NoTypeInformation -Encoding UTF8

$bundlePath = Join-Path $outputRoot 'recovery-evidence-bundle.zip'
$bundleInputs = @(Get-ChildItem -LiteralPath $outputRoot -Force | Where-Object { $_.Name -ne 'recovery-evidence-bundle.zip' } | Select-Object -ExpandProperty FullName)
Compress-Archive -LiteralPath $bundleInputs -DestinationPath $bundlePath -CompressionLevel Optimal -Force

Write-Host ''
Write-Host 'CFA RECOVERY EVIDENCE: PASS'
Write-Host ("Output: {0}" -f $outputRoot)
Write-Host ("Bundle: {0}" -f $bundlePath)
Write-Host ("Evidence files indexed: {0}" -f $index.Count)
Write-Host ("Stage 3 manifest rows: {0}" -f $stage3Manifest.Count)
