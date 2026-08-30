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
$ExpectedArchiveScanSha256 = '1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Get-Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Invoke-ChildScript {
    param([string]$Path,[hashtable]$NamedArguments)
    $global:LASTEXITCODE = $null
    & $Path @NamedArguments
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
    foreach ($candidate in @('D:\CFA-bulk\analysis\stage3-news-matching',$env:TEMP,(Join-Path $docs 'CFA-local'),'D:\CFA-recovery')) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Container)) { [void]$roots.Add($candidate) }
    }
    $found = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'stage3-match-summary.json' -ErrorAction SilentlyContinue)) {
            if (Test-V2Candidate $file.FullName) { [void]$found.Add($file) }
        }
    }
    if ($found.Count -eq 0) { throw 'No local PASS CANDIDATE_V2 Stage 3 run was found. Supply -Stage3V2RunRoot explicitly.' }
    return (@($found | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0].Directory.FullName)
}
function Find-ArchiveScan {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $roots = @((Join-Path $docs 'CFA-local'),'D:\CFA-recovery')
    $found = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'archive-scan.csv' -ErrorAction SilentlyContinue)) {
            try { if ((Get-Sha $file.FullName) -eq $ExpectedArchiveScanSha256) { [void]$found.Add($file) } } catch {}
        }
    }
    if ($found.Count -eq 0) { throw 'Exact reproduced Stage 2 archive-scan.csv was not found. Supply -ArchiveScanCsv explicitly.' }
    return (@($found | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0].FullName)
}
function Invoke-SelfTest {
    foreach ($name in @('Diagnose-CfaStage3CriticalUtf8Impact.ps1','Apply-CfaStage3NewsMatchingV3.ps1','Apply-CfaStage3NewsMatchingV4.ps1','Prepare-CfaStage3V4SampleReview.ps1','Summarize-CfaStage3NewsByAsset.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Required V4 component missing: $name" }
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('cfa-s3v4-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        [IO.File]::WriteAllText($temp,"param([string]`$A,[string]`$B)`nif(`$A -ne 'alpha' -or `$B -ne 'beta'){exit 9}`nexit 0`n",(New-Object Text.UTF8Encoding($false)))
        Invoke-ChildScript -Path $temp -NamedArguments @{A='alpha';B='beta'}
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
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
    if ((Get-Sha $ArchiveScanCsv) -ne $ExpectedArchiveScanSha256) { throw 'Selected archive scan does not match the exact reproduced Stage 2 hash.' }

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $base = 'D:\CFA-bulk\analysis\stage3-news-matching'
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Default Stage 3 analysis root missing: $base" }
        $OutputRoot = Join-Path $base ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-v4-finalization-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    }
    if (Test-Path -LiteralPath $OutputRoot) {
        if (@(Get-ChildItem -LiteralPath $OutputRoot -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw "OutputRoot must be empty: $OutputRoot" }
    }
    else { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    Write-Host ("Selected parent V2 run: {0}" -f $Stage3V2RunRoot)
    Write-Host ("Selected Stage 2 archive scan: {0}" -f $ArchiveScanCsv)
    Write-Host ("V4 finalization evidence root: {0}" -f $OutputRoot)

    $impactRoot = Join-Path $OutputRoot 'utf8-impact'
    $v3Root = Join-Path $OutputRoot 'v3-semantic'
    $v4Root = Join-Path $OutputRoot 'v4'
    $reviewRoot = Join-Path $OutputRoot 'review'
    New-Item -ItemType Directory -Path $impactRoot,$reviewRoot -Force | Out-Null

    $impactScript = Join-Path $PSScriptRoot 'Diagnose-CfaStage3CriticalUtf8Impact.ps1'
    Invoke-ChildScript -Path $impactScript -NamedArguments @{ArchiveRoot=$ArchiveRoot;ArchiveScanCsv=$ArchiveScanCsv;Stage3V2RunRoot=$Stage3V2RunRoot;OutputRoot=$impactRoot}
    $impactSummary = @(Get-ChildItem -LiteralPath $impactRoot -Recurse -File -Filter 'stage3-critical-utf8-impact-summary.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($impactSummary.Count -ne 1) { throw 'Critical UTF-8 impact summary not found.' }
    $impact = Get-Content -LiteralPath $impactSummary[0].FullName -Raw | ConvertFrom-Json
    if ([string]$impact.status -ne 'PASS' -or [string]$impact.gates.'CFA-S3F-011' -ne 'PASS' -or [string]$impact.gates.'CFA-S3F-012' -ne 'PASS') { throw 'Critical UTF-8 impact gates did not PASS.' }
    $impactRunRoot = $impactSummary[0].Directory.FullName

    $v3Script = Join-Path $PSScriptRoot 'Apply-CfaStage3NewsMatchingV3.ps1'
    Invoke-ChildScript -Path $v3Script -NamedArguments @{Stage3V2RunRoot=$Stage3V2RunRoot;RepoRoot=$RepoRoot;OutputRoot=$v3Root}
    $v3Summary = Get-Content -LiteralPath (Join-Path $v3Root 'stage3-match-summary.json') -Raw | ConvertFrom-Json
    if ([string]$v3Summary.run_status -ne 'PASS' -or [string]$v3Summary.matching_contract -ne 'CANDIDATE_V3') { throw 'V3 semantic correction did not PASS.' }

    $v4Script = Join-Path $PSScriptRoot 'Apply-CfaStage3NewsMatchingV4.ps1'
    Invoke-ChildScript -Path $v4Script -NamedArguments @{Stage3V2RunRoot=$Stage3V2RunRoot;Stage3V3RunRoot=$v3Root;ImpactRunRoot=$impactRunRoot;OutputRoot=$v4Root}
    $v4SummaryPath = Join-Path $v4Root 'stage3-match-summary.json'
    $v4 = Get-Content -LiteralPath $v4SummaryPath -Raw | ConvertFrom-Json
    if ([string]$v4.run_status -ne 'PASS' -or [string]$v4.matching_contract -ne 'CANDIDATE_V4' -or [string]$v4.gates.'CFA-S3F-013' -ne 'PASS') { throw 'V4 eligibility correction did not PASS.' }

    $reviewScript = Join-Path $PSScriptRoot 'Prepare-CfaStage3V4SampleReview.ps1'
    Invoke-ChildScript -Path $reviewScript -NamedArguments @{Stage3V4RunRoot=$v4Root;OutputRoot=$reviewRoot}
    $reviewSummary = @(Get-ChildItem -LiteralPath $reviewRoot -Recurse -File -Filter 'stage3-v4-bounded-sample-review-summary.json' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    if ($reviewSummary.Count -ne 1) { throw 'V4 bounded-review summary not found.' }
    $review = Get-Content -LiteralPath $reviewSummary[0].FullName -Raw | ConvertFrom-Json
    if ([string]$review.status -ne 'PASS') { throw 'V4 bounded-review preparation did not PASS.' }

    $countScript = Join-Path $PSScriptRoot 'Summarize-CfaStage3NewsByAsset.ps1'
    Invoke-ChildScript -Path $countScript -NamedArguments @{Stage3RunRoot=$v4Root}
    $countsPath = Join-Path $v4Root 'stage3-news-counts-by-asset.csv'
    if (-not (Test-Path -LiteralPath $countsPath -PathType Leaf)) { throw 'V4 per-asset news count output missing.' }

    $reviewCsv = [string]$review.output_review_csv
    $final = [ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_3';matching_contract='CANDIDATE_V4';parent_v2_run=$Stage3V2RunRoot;archive_scan_csv=$ArchiveScanCsv;archive_scan_sha256=(Get-Sha $ArchiveScanCsv)
        utf8_impact_summary=$impactSummary[0].FullName;utf8_impact_summary_sha256=(Get-Sha $impactSummary[0].FullName);v3_run_root=$v3Root;v3_summary_sha256=(Get-Sha (Join-Path $v3Root 'stage3-match-summary.json'))
        v4_run_root=$v4Root;v4_summary_sha256=(Get-Sha $v4SummaryPath);review_summary=$reviewSummary[0].FullName;review_summary_sha256=(Get-Sha $reviewSummary[0].FullName);review_csv=$reviewCsv;review_csv_sha256=(Get-Sha $reviewCsv)
        news_counts_csv=$countsPath;news_counts_sha256=(Get-Sha $countsPath)
        gates=[ordered]@{'CFA-S3F-008'='FAIL';'CFA-S3F-011'='PASS';'CFA-S3F-012'='PASS';'CFA-S3F-013'='PASS';'CFA-S3F-014'='UNVERIFIED';'CFA-S3F-015'='BLOCKED';'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'}
        next_action='Directly review every row in review_csv. Stage 3 may freeze only if the corrected V4 bounded review has no obvious false positive or false negative and the review evidence is recorded.'
    }
    $finalPath = Join-Path $OutputRoot 'stage3-v4-finalization-candidate.json'
    Write-Utf8NoBom $finalPath (($final | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 3 V4 FINALIZATION: VALIDATION CANDIDATE'
    Write-Host 'CFA-S3F-008 historical encoding gate: FAIL (preserved)'
    Write-Host 'CFA-S3F-011 critical UTF-8 exclusion manifest: PASS'
    Write-Host 'CFA-S3F-012 exact V2 impact reconciliation: PASS'
    Write-Host 'CFA-S3F-013 corrected V4 candidate: PASS'
    Write-Host 'CFA-S3F-014 direct bounded semantic review: UNVERIFIED'
    Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
    Write-Host ("Review CSV: {0}" -f $reviewCsv)
    Write-Host ("Candidate receipt: {0}" -f $finalPath)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V4 FINALIZATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
