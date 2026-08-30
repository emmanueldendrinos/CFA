#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = 'D:\CFA-bulk\source\gdelt-gkg-q2-2025',
    [string]$Stage3V2RunRoot = '',
    [string]$ArchiveScanCsv = '',
    [string]$OutputRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedRows = 9183757L
$ExpectedArchives = 7163

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $p = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Get-Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Invoke-ChildScript {
    param([string]$Path,[object[]]$Arguments)
    $global:LASTEXITCODE = $null
    & $Path @Arguments
    $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $global:LASTEXITCODE = 0
    if ($code -ne 0) { throw "Child script failed with exit ${code}: $Path" }
}
function Test-V2Candidate {
    param([string]$SummaryPath)
    try {
        $s = Get-Content -LiteralPath $SummaryPath -Raw | ConvertFrom-Json
        $root = Split-Path -Parent $SummaryPath
        if ([string]$s.run_status -ne 'PASS' -or [string]$s.matching_contract -ne 'CANDIDATE_V2') { return $false }
        if ([long]$s.source.rows_scanned -ne $ExpectedRows -or [int]$s.source.archive_files -ne $ExpectedArchives) { return $false }
        foreach ($name in @('stage3-news-matches.csv','stage3-context-rejects.csv','stage3-match-samples.csv')) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) { return $false }
        }
        return $true
    }
    catch { return $false }
}
function Find-V2Run {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $roots = New-Object System.Collections.ArrayList
    foreach ($r in @('D:\CFA-bulk\analysis\stage3-news-matching',$env:TEMP,(Join-Path $docs 'CFA-local'),'D:\CFA-recovery')) {
        if (-not [string]::IsNullOrWhiteSpace($r) -and (Test-Path -LiteralPath $r -PathType Container)) { [void]$roots.Add($r) }
    }
    $candidates = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'stage3-match-summary.json' -ErrorAction SilentlyContinue)) {
            if (Test-V2Candidate $f.FullName) { [void]$candidates.Add($f) }
        }
    }
    if ($candidates.Count -eq 0) { throw 'No local PASS CANDIDATE_V2 Stage 3 run was found in the bounded CFA analysis/evidence roots. Supply -Stage3V2RunRoot explicitly.' }
    $chosen = @($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
    return $chosen.Directory.FullName
}
function Test-ArchiveScanCandidate {
    param([string]$Path)
    try {
        $rows = @(Import-Csv -LiteralPath $Path)
        if ($rows.Count -ne $ExpectedArchives) { return $false }
        $p = @($rows[0].PSObject.Properties.Name)
        foreach ($n in @('archive_file','utf8_status','malformed_field_count_rows','entry_count_status')) { if ($p -notcontains $n) { return $false } }
        return $true
    }
    catch { return $false }
}
function Find-ArchiveScan {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $roots = New-Object System.Collections.ArrayList
    foreach ($r in @((Join-Path $docs 'CFA-local'),'D:\CFA-recovery')) { if (Test-Path -LiteralPath $r -PathType Container) { [void]$roots.Add($r) } }
    $candidates = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'archive-scan.csv' -ErrorAction SilentlyContinue)) {
            if (Test-ArchiveScanCandidate $f.FullName) { [void]$candidates.Add($f) }
        }
    }
    if ($candidates.Count -eq 0) { throw 'No 7,163-row Stage 2 GDELT archive-scan.csv was found in CFA-local or D:\CFA-recovery. Supply -ArchiveScanCsv explicitly.' }
    return (@($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0].FullName)
}
function Invoke-SelfTest {
    $valid=[pscustomobject]@{run_status='PASS';matching_contract='CANDIDATE_V2';source=[pscustomobject]@{rows_scanned=$ExpectedRows;archive_files=$ExpectedArchives}}
    if ([string]$valid.matching_contract -ne 'CANDIDATE_V2' -or [long]$valid.source.rows_scanned -ne $ExpectedRows) { throw 'V2 discovery contract' }
    foreach ($name in @('Apply-CfaStage3NewsMatchingV3.ps1','Prepare-CfaStage3V3SampleReview.ps1','Diagnose-CfaStage3FieldEncoding.ps1','Summarize-CfaStage3NewsByAsset.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Required finalization component missing: $name" }
    }
    Write-Host 'SELF-TEST: PASS'
}
if ($SelfTest) { try { Invoke-SelfTest; exit 0 } catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 } }

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($Stage3V2RunRoot)) { $Stage3V2RunRoot = Find-V2Run }
    $Stage3V2RunRoot = (Resolve-Path -LiteralPath $Stage3V2RunRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($ArchiveScanCsv)) { $ArchiveScanCsv = Find-ArchiveScan }
    $ArchiveScanCsv = (Resolve-Path -LiteralPath $ArchiveScanCsv).ProviderPath
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $base = 'D:\CFA-bulk\analysis\stage3-news-matching'
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Default Stage 3 analysis root missing: $base" }
        $OutputRoot = Join-Path $base ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-v3-finalization-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    }
    if (Test-Path -LiteralPath $OutputRoot) {
        if (@(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw "OutputRoot must be empty: $OutputRoot" }
    }
    else { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    Write-Host ("Selected parent V2 run: {0}" -f $Stage3V2RunRoot)
    Write-Host ("Selected Stage 2 archive scan: {0}" -f $ArchiveScanCsv)
    Write-Host ("Finalization evidence root: {0}" -f $OutputRoot)
    $encodingRoot = Join-Path $OutputRoot 'encoding'
    $v3Root = Join-Path $OutputRoot 'v3'
    $reviewRoot = Join-Path $OutputRoot 'review'
    New-Item -ItemType Directory -Path $encodingRoot,$reviewRoot -Force | Out-Null

    $encodingScript = Join-Path $PSScriptRoot 'Diagnose-CfaStage3FieldEncoding.ps1'
    Invoke-ChildScript $encodingScript @('-ArchiveRoot',$ArchiveRoot,'-ArchiveScanCsv',$ArchiveScanCsv,'-OutputRoot',$encodingRoot)
    $encodingSummary = @(Get-ChildItem -LiteralPath $encodingRoot -Recurse -File -Filter 'stage3-encoding-summary.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($encodingSummary.Count -ne 1) { throw 'Stage 3 encoding summary not found after audit.' }
    $enc = Get-Content -LiteralPath $encodingSummary[0].FullName -Raw | ConvertFrom-Json
    if ([string]$enc.status -ne 'PASS') { throw 'Stage 3 encoding hard gate did not PASS.' }

    $applyScript = Join-Path $PSScriptRoot 'Apply-CfaStage3NewsMatchingV3.ps1'
    Invoke-ChildScript $applyScript @('-Stage3V2RunRoot',$Stage3V2RunRoot,'-RepoRoot',$RepoRoot,'-OutputRoot',$v3Root)
    $v3SummaryPath = Join-Path $v3Root 'stage3-match-summary.json'
    $v3 = Get-Content -LiteralPath $v3SummaryPath -Raw | ConvertFrom-Json
    if ([string]$v3.run_status -ne 'PASS' -or [string]$v3.matching_contract -ne 'CANDIDATE_V3') { throw 'V3 post-filter hard gate did not PASS.' }

    $reviewScript = Join-Path $PSScriptRoot 'Prepare-CfaStage3V3SampleReview.ps1'
    Invoke-ChildScript $reviewScript @('-Stage3V3RunRoot',$v3Root,'-OutputRoot',$reviewRoot)
    $reviewSummary = @(Get-ChildItem -LiteralPath $reviewRoot -Recurse -File -Filter 'stage3-v3-bounded-sample-review-summary.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($reviewSummary.Count -ne 1) { throw 'V3 bounded review summary not found.' }
    $review = Get-Content -LiteralPath $reviewSummary[0].FullName -Raw | ConvertFrom-Json
    if ([string]$review.status -ne 'PASS') { throw 'V3 bounded review preparation hard gate did not PASS.' }

    $countScript = Join-Path $PSScriptRoot 'Summarize-CfaStage3NewsByAsset.ps1'
    Invoke-ChildScript $countScript @('-Stage3RunRoot',$v3Root)
    $countsPath = Join-Path $v3Root 'stage3-news-counts-by-asset.csv'
    if (-not (Test-Path -LiteralPath $countsPath -PathType Leaf)) { throw 'V3 per-asset news count output missing.' }
    $reviewCsv = [string]$review.output_review_csv
    $final=[ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_3';parent_v2_run=$Stage3V2RunRoot;archive_scan_csv=$ArchiveScanCsv;archive_scan_sha256=(Get-Sha $ArchiveScanCsv)
        encoding_summary=$encodingSummary[0].FullName;encoding_summary_sha256=(Get-Sha $encodingSummary[0].FullName);v3_run_root=$v3Root;v3_summary_sha256=(Get-Sha $v3SummaryPath)
        review_summary=$reviewSummary[0].FullName;review_summary_sha256=(Get-Sha $reviewSummary[0].FullName);review_csv=$reviewCsv;review_csv_sha256=(Get-Sha $reviewCsv)
        news_counts_csv=$countsPath;news_counts_sha256=(Get-Sha $countsPath)
        gates=[ordered]@{'CFA-S3F-001'='PASS';'CFA-S3F-002'='PASS';'CFA-S3F-003'='PASS';'CFA-S3F-004'='PASS';'CFA-S3F-005'='PASS';'CFA-S3F-006'='PASS';'CFA-S3F-007'='PASS';'CFA-S3F-008'='PASS';'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED';'CFA-S3F-010'='BLOCKED'}
        next_action='Directly review every row in review_csv. Stage 3 may be frozen only if no obvious false positive or false negative is found and the review evidence is recorded.'
    }
    $finalPath = Join-Path $OutputRoot 'stage3-v3-finalization-candidate.json'
    Write-Utf8NoBom $finalPath (($final | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Write-Host ''
    Write-Host 'CFA STAGE 3 V3 FINALIZATION: VALIDATION CANDIDATE'
    Write-Host 'Mechanical/encoding gates: PASS'
    Write-Host 'CFA-S3-005 direct bounded semantic review: UNVERIFIED'
    Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
    Write-Host ("Review CSV: {0}" -f $reviewCsv)
    Write-Host ("Candidate receipt: {0}" -f $finalPath)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V3 FINALIZATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
