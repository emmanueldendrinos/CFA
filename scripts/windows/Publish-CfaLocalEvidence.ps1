#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$EvidenceRoot = '',
    [string]$RepoRoot = '',
    [switch]$CommitAndPush,
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
    param([string]$ParentPath,[switch]$Optional)
    if (-not (Test-Path -LiteralPath $ParentPath -PathType Container)) {
        if ($Optional) { return $null }
        throw "Evidence directory missing: $ParentPath"
    }
    $runs = @(Get-ChildItem -LiteralPath $ParentPath -Directory -Force | Sort-Object Name -Descending)
    if ($runs.Count -eq 0) {
        if ($Optional) { return $null }
        throw "No evidence runs found under: $ParentPath"
    }
    return $runs[0]
}

function Require-File {
    param([System.IO.DirectoryInfo]$Run,[string]$Name)
    $path = Join-Path $Run.FullName $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required evidence file missing from $($Run.Name): $Name" }
    return $path
}

function Add-HashRow {
    param([object[]]$Rows,[string]$Category,[string]$RunId,[string]$Path)
    $row = [pscustomobject]@{
        category=$Category
        run_id=$RunId
        file_name=[System.IO.Path]::GetFileName($Path)
        sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return @($Rows) + ,$row
}

function Get-ReceiptText {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return $text.TrimEnd("`r","`n")
}

function Add-CsvSection {
    param([System.Text.StringBuilder]$Builder,[object[]]$HashRows,[string]$Category,[string]$RunId,[string]$Title,[string]$Path)
    $updated = Add-HashRow -Rows $HashRows -Category $Category -RunId $RunId -Path $Path
    [void]$Builder.AppendLine('### ' + $Title)
    [void]$Builder.AppendLine('')
    [void]$Builder.AppendLine('```csv')
    [void]$Builder.AppendLine((Get-ReceiptText -Path $Path))
    [void]$Builder.AppendLine('```')
    [void]$Builder.AppendLine('')
    return $updated
}

function Count-Status {
    param([object[]]$Rows,[string]$Status)
    return @($Rows | Where-Object { [string]$_.status -eq $Status }).Count
}

function Write-Snapshot {
    param([string]$EvidenceRootPath,[string]$RepoRootPath)

    $kraken = Get-LatestRun -ParentPath (Join-Path $EvidenceRootPath 'kraken-reconciliation')
    $news = Get-LatestRun -ParentPath (Join-Path $EvidenceRootPath 'news-source-coverage')
    $diagnosis = Get-LatestRun -ParentPath (Join-Path $EvidenceRootPath 'news-acquisition-diagnosis') -Optional

    $krakenMembersPath = Require-File -Run $kraken -Name 'member-reconciliation.csv'
    $krakenArchivePath = Require-File -Run $kraken -Name 'archive-reconciliation.csv'
    $newsChecksPath = Require-File -Run $news -Name 'coverage-checks.csv'

    $krakenMembers = @(Import-Csv -LiteralPath $krakenMembersPath)
    $krakenArchive = @(Import-Csv -LiteralPath $krakenArchivePath)
    $newsChecks = @(Import-Csv -LiteralPath $newsChecksPath)
    if ($krakenMembers.Count -eq 0 -or $krakenArchive.Count -eq 0 -or $newsChecks.Count -eq 0) { throw 'Core evidence summaries must not be empty.' }

    $b = New-Object System.Text.StringBuilder
    $hashRows = @()
    [void]$b.AppendLine('# CFA Local Validation Evidence Snapshot')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Curated evidence receipt derived from direct CFA-local validation outputs. Raw market/news data, credentials, database backups, full generated outputs, and temporary files remain outside Git.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Source runs')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- Kraken reconciliation: ' + $kraken.Name)
    [void]$b.AppendLine('- News source coverage: ' + $news.Name)
    if ($null -ne $diagnosis) { [void]$b.AppendLine('- News acquisition diagnosis: ' + $diagnosis.Name) }
    [void]$b.AppendLine('')

    [void]$b.AppendLine('## Kraken reconciliation summary')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- Manifest members: ' + $krakenMembers.Count)
    foreach ($status in @('PASS','MISSING','HASH_MISMATCH','AMBIGUOUS','UNVERIFIED_CANDIDATE_SHAPE')) {
        [void]$b.AppendLine('- ' + $status + ': ' + (Count-Status -Rows $krakenMembers -Status $status))
    }
    [void]$b.AppendLine('- Archive PASS: ' + (Count-Status -Rows $krakenArchive -Status 'PASS'))
    [void]$b.AppendLine('')
    $hashRows = Add-CsvSection -Builder $b -HashRows $hashRows -Category 'kraken' -RunId $kraken.Name -Title 'Archive reconciliation' -Path $krakenArchivePath
    $hashRows = Add-HashRow -Rows $hashRows -Category 'kraken' -RunId $kraken.Name -Path $krakenMembersPath

    [void]$b.AppendLine('## News source coverage summary')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- PASS checks: ' + (Count-Status -Rows $newsChecks -Status 'PASS'))
    [void]$b.AppendLine('- FAIL checks: ' + (Count-Status -Rows $newsChecks -Status 'FAIL'))
    [void]$b.AppendLine('- UNVERIFIED checks: ' + (Count-Status -Rows $newsChecks -Status 'UNVERIFIED'))
    [void]$b.AppendLine('')

    foreach ($section in @(
        @('Coverage checks','coverage-checks.csv'),
        @('Acquisition run','acquisition-runs.csv'),
        @('Protocol contract','protocol-contracts.csv'),
        @('Acquisition object summary','acquisition-object-summary.csv'),
        @('Hype table counts','factor-table-counts.csv'),
        @('Latest bounded run events','latest-run-events.csv')
    )) {
        $path = Require-File -Run $news -Name $section[1]
        $hashRows = Add-CsvSection -Builder $b -HashRows $hashRows -Category 'news-coverage' -RunId $news.Name -Title $section[0] -Path $path
    }

    if ($null -ne $diagnosis) {
        [void]$b.AppendLine('## News acquisition diagnosis')
        [void]$b.AppendLine('')
        foreach ($section in @(
            @('Diagnosis checks','diagnosis-checks.csv'),
            @('Event type summary','event-type-summary.csv'),
            @('Object accounting','object-accounting.csv'),
            @('Completed-event accounting','completed-event-accounting.csv'),
            @('Duplicate non-null payload hashes','duplicate-non-null-payload-hashes.csv'),
            @('NULL payload-hash rows','null-payload-hash-rows.csv'),
            @('Completed-event gaps','completed-event-gaps.csv'),
            @('Latest non-completion events','latest-100-non-completion-events.csv'),
            @('ASRP hype tables','asrp-hype-tables.csv'),
            @('Core table columns','core-table-columns.csv')
        )) {
            $path = Require-File -Run $diagnosis -Name $section[1]
            $hashRows = Add-CsvSection -Builder $b -HashRows $hashRows -Category 'news-diagnosis' -RunId $diagnosis.Name -Title $section[0] -Path $path
        }
    }

    [void]$b.AppendLine('## Source evidence SHA-256')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('| Category | Run | File | SHA-256 |')
    [void]$b.AppendLine('|---|---|---|---|')
    foreach ($row in $hashRows) {
        [void]$b.AppendLine('| ' + $row.category + ' | ' + $row.run_id + ' | ' + $row.file_name + ' | ' + $row.sha256 + ' |')
    }
    [void]$b.AppendLine('')

    $receipt = Join-Path $RepoRootPath 'docs\evidence\latest-local-validation.md'
    Write-Utf8NoBom -Path $receipt -Content $b.ToString()
    return [pscustomobject]@{ receipt_path=$receipt; kraken_run=$kraken.Name; news_run=$news.Name; diagnosis_run=if($null -ne $diagnosis){$diagnosis.Name}else{''} }
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-publish-' + [guid]::NewGuid().ToString('N'))
    try {
        $evidence = Join-Path $root 'CFA-local'; $repo = Join-Path $root 'repo'
        $k = Join-Path $evidence 'kraken-reconciliation\20260101-k'; $n = Join-Path $evidence 'news-source-coverage\20260101-n'; $d = Join-Path $evidence 'news-acquisition-diagnosis\20260101-d'
        foreach ($dir in @($k,$n,$d,(Join-Path $repo 'docs\evidence'))) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-Utf8NoBom -Path (Join-Path $k 'member-reconciliation.csv') -Content "source_member_ordinal,status`n1,PASS`n"
        Write-Utf8NoBom -Path (Join-Path $k 'archive-reconciliation.csv') -Content "import_run_id,status`na,PASS`n"
        Write-Utf8NoBom -Path (Join-Path $n 'coverage-checks.csv') -Content "check_id,status,observed,expected`nA,FAIL,1,2`n"
        foreach ($name in @('acquisition-runs.csv','protocol-contracts.csv','acquisition-object-summary.csv','factor-table-counts.csv','latest-run-events.csv')) { Write-Utf8NoBom -Path (Join-Path $n $name) -Content "a,b`n1,2`n" }
        foreach ($name in @('diagnosis-checks.csv','event-type-summary.csv','object-accounting.csv','completed-event-accounting.csv','duplicate-non-null-payload-hashes.csv','null-payload-hash-rows.csv','completed-event-gaps.csv','latest-100-non-completion-events.csv','asrp-hype-tables.csv','core-table-columns.csv')) { Write-Utf8NoBom -Path (Join-Path $d $name) -Content "a,b`n1,2`n" }
        $r = Write-Snapshot -EvidenceRootPath $evidence -RepoRootPath $repo
        if (-not (Test-Path -LiteralPath $r.receipt_path -PathType Leaf)) { throw 'Self-test failed: receipt missing.' }
        $text = [System.IO.File]::ReadAllText($r.receipt_path)
        foreach ($required in @('20260101-k','20260101-n','20260101-d','News acquisition diagnosis','Source evidence SHA-256')) { if (-not $text.Contains($required)) { throw "Self-test failed: missing $required" } }
        if ($text.Contains($root)) { throw 'Self-test failed: absolute path leaked into receipt.' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ($CommitAndPush) { throw 'CommitAndPush is no longer supported here; use Sync-CfaEvidence.ps1 so Git mutation has one tested owner.' }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $EvidenceRoot = (Resolve-Path -LiteralPath $EvidenceRoot).ProviderPath
    $r = Write-Snapshot -EvidenceRootPath $EvidenceRoot -RepoRootPath $RepoRoot
    Write-Host ('Evidence receipt: ' + $r.receipt_path)
    Write-Host ('Kraken run: ' + $r.kraken_run)
    Write-Host ('News coverage run: ' + $r.news_run)
    if (-not [string]::IsNullOrWhiteSpace($r.diagnosis_run)) { Write-Host ('News diagnosis run: ' + $r.diagnosis_run) }
    Write-Host 'CFA EVIDENCE PUBLISH: PASS'
}
catch {
    Write-Host 'CFA EVIDENCE PUBLISH: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
