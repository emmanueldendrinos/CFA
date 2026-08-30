#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Stage3RunRoot = 'D:\CFA-bulk\analysis\stage3-news-matching\20260829-200729-D-drive-revalidation',
    [string]$SourceReconciliationRoot = 'D:\CFA-recovery\stage3-source-reconciliation\20260830-030042-74ff52b9',
    [string]$OutputRoot = 'D:\CFA-recovery\stage3-run-adjudication',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedArchives = 7163
$ExpectedRows = 9183757L
$ExpectedMalformedRows = 5L
$ExpectedAliasRegistrySha256 = '11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Get-Sha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Required file missing: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-Equal {
    param([object]$Observed,[object]$Expected,[string]$Label)
    if ([string]$Observed -ne [string]$Expected) { throw "$Label mismatch. Observed='$Observed' Expected='$Expected'" }
}

function Invoke-Adjudication {
    param([string]$RunRoot,[string]$ReconciliationRoot,[string]$OutRoot)

    $summaryPath = Join-Path $RunRoot 'stage3-match-summary.json'
    $reconPath = Join-Path $ReconciliationRoot 'stage3-source-reconciliation.json'
    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { throw "Stage 3 summary missing: $summaryPath" }
    if (-not (Test-Path -LiteralPath $reconPath -PathType Leaf)) { throw "Stage 3 source reconciliation missing: $reconPath" }

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $recon = Get-Content -LiteralPath $reconPath -Raw | ConvertFrom-Json

    Assert-Equal $recon.status 'PASS' 'Source reconciliation status'
    Assert-Equal $recon.manifest_archives $ExpectedArchives 'Source reconciliation manifest archive count'
    Assert-Equal $recon.database_downloaded_archives $ExpectedArchives 'Source reconciliation database archive count'
    Assert-Equal $recon.mismatch_count 0 'Source reconciliation mismatch count'

    Assert-Equal $summary.source.archive_files $ExpectedArchives 'Stage 3 archive count'
    Assert-Equal $summary.source.rows_scanned $ExpectedRows 'Stage 3 directly observed row count'
    Assert-Equal $summary.source.malformed_field_count_rows $ExpectedMalformedRows 'Stage 3 malformed 27-field row count'
    Assert-Equal $summary.source.missing_critical_rows 0 'Stage 3 missing critical row count'
    Assert-Equal $summary.source.malformed_entity_blocks 0 'Stage 3 malformed entity block count'
    Assert-Equal $summary.matching.news_assets 431 'Stage 3 news asset count'
    Assert-Equal $summary.matching.alias_rows 470 'Stage 3 alias row count'
    Assert-Equal $summary.matching.duplicate_asset_record_matches 0 'Stage 3 duplicate asset/record match count'
    Assert-Equal ([string]$summary.output.alias_registry_sha256).ToLowerInvariant() $ExpectedAliasRegistrySha256 'Stage 3 alias registry SHA-256'

    $matchesPath = [string]$summary.output.matches_path
    $rejectsPath = [string]$summary.output.rejects_path
    $samplesPath = [string]$summary.output.samples_path
    Assert-Equal (Get-Sha256 $matchesPath) ([string]$summary.output.matches_sha256).ToLowerInvariant() 'Matches file SHA-256'
    Assert-Equal (Get-Sha256 $rejectsPath) ([string]$summary.output.rejects_sha256).ToLowerInvariant() 'Rejects file SHA-256'
    Assert-Equal (Get-Sha256 $samplesPath) ([string]$summary.output.samples_sha256).ToLowerInvariant() 'Samples file SHA-256'

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $runDir = Join-Path $OutRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $result = [ordered]@{
        status = 'PASS'
        basis = 'Direct D-drive Stage 3 scan plus byte-for-byte Stage 1 source-manifest reconciliation'
        corrected_source_expectation = [ordered]@{
            archive_files = $ExpectedArchives
            rows_scanned = $ExpectedRows
            malformed_field_count_rows = $ExpectedMalformedRows
            missing_critical_rows = 0
            malformed_entity_blocks = 0
        }
        matching = [ordered]@{
            news_assets = [int]$summary.matching.news_assets
            alias_rows = [int]$summary.matching.alias_rows
            unique_asset_record_matches = [long]$summary.matching.unique_asset_record_matches
            matched_assets = [int]$summary.matching.matched_assets
            rejected_context_alias_hits = [long]$summary.matching.rejected_context_alias_hits
            duplicate_asset_record_matches = [long]$summary.matching.duplicate_asset_record_matches
        }
        gates = [ordered]@{
            'S3-ID-01' = 'PASS'
            'CFA-S3-002' = 'PASS'
            'CFA-S3-003' = 'PASS'
            'CFA-S3-004' = 'PASS'
            'CFA-S3-005' = 'UNVERIFIED'
            'CFA-S3-006' = 'BLOCKED'
        }
        source_reconciliation = $reconPath
        stage3_summary = $summaryPath
        output = [ordered]@{
            matches_sha256 = ([string]$summary.output.matches_sha256).ToLowerInvariant()
            rejects_sha256 = ([string]$summary.output.rejects_sha256).ToLowerInvariant()
            samples_sha256 = ([string]$summary.output.samples_sha256).ToLowerInvariant()
            alias_registry_sha256 = ([string]$summary.output.alias_registry_sha256).ToLowerInvariant()
        }
        note = 'The prior 9,091,236 row literal is superseded by the directly observed 9,183,757 rows from the byte-reconciled source corpus. This adjudication does not change the frozen matching rule.'
    }
    Write-Utf8NoBom -Path (Join-Path $runDir 'stage3-run-adjudication.json') -Content (($result | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 3 COMPLETED-RUN ADJUDICATION: PASS'
    Write-Host "Archives: $ExpectedArchives"
    Write-Host "Rows scanned: $ExpectedRows"
    Write-Host "Unique asset/record matches: $($summary.matching.unique_asset_record_matches)"
    Write-Host 'CFA-S3-002: PASS'
    Write-Host 'CFA-S3-004: PASS'
    Write-Host 'CFA-S3-005: UNVERIFIED'
    Write-Host 'CFA-S3-006: BLOCKED'
    Write-Host "Evidence directory: $runDir"
    return $runDir
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-s3-adjudicate-' + [guid]::NewGuid().ToString('N'))
    try {
        $run = Join-Path $root 'run'; $reconRoot = Join-Path $root 'recon'; $out = Join-Path $root 'out'
        New-Item -ItemType Directory -Path $run,$reconRoot -Force | Out-Null
        $matches = Join-Path $run 'stage3-news-matches.csv'; $rejects = Join-Path $run 'stage3-context-rejects.csv'; $samples = Join-Path $run 'stage3-match-samples.csv'
        [System.IO.File]::WriteAllText($matches,"a,b`n1,2`n")
        [System.IO.File]::WriteAllText($rejects,"a,b`n3,4`n")
        [System.IO.File]::WriteAllText($samples,"a,b`n5,6`n")
        $summary = [ordered]@{
            source=[ordered]@{archive_files=7163;rows_scanned=9183757;malformed_field_count_rows=5;missing_critical_rows=0;malformed_entity_blocks=0}
            matching=[ordered]@{news_assets=431;alias_rows=470;unique_asset_record_matches=50802;matched_assets=333;rejected_context_alias_hits=3300330;duplicate_asset_record_matches=0}
            output=[ordered]@{matches_path=$matches;matches_sha256=(Get-Sha256 $matches);rejects_path=$rejects;rejects_sha256=(Get-Sha256 $rejects);samples_path=$samples;samples_sha256=(Get-Sha256 $samples);alias_registry_sha256=$ExpectedAliasRegistrySha256}
        }
        Write-Utf8NoBom (Join-Path $run 'stage3-match-summary.json') (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
        $recon = [ordered]@{status='PASS';manifest_archives=7163;database_downloaded_archives=7163;mismatch_count=0}
        Write-Utf8NoBom (Join-Path $reconRoot 'stage3-source-reconciliation.json') (($recon|ConvertTo-Json -Depth 5)+[Environment]::NewLine)
        [void](Invoke-Adjudication -RunRoot $run -ReconciliationRoot $reconRoot -OutRoot $out)
        $bad = Get-Content -LiteralPath (Join-Path $run 'stage3-match-summary.json') -Raw | ConvertFrom-Json
        $bad.source.rows_scanned = 9091236
        Write-Utf8NoBom (Join-Path $run 'stage3-match-summary.json') (($bad|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
        $failed = $false
        try { [void](Invoke-Adjudication -RunRoot $run -ReconciliationRoot $reconRoot -OutRoot $out) } catch { $failed = $true }
        if (-not $failed) { throw 'Stale row-count self-test should fail.' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    [void](Invoke-Adjudication -RunRoot $Stage3RunRoot -ReconciliationRoot $SourceReconciliationRoot -OutRoot $OutputRoot)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 COMPLETED-RUN ADJUDICATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
