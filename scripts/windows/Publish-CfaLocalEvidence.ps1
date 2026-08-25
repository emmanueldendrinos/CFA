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
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-LatestRunDirectory {
    param([Parameter(Mandatory)][string]$ParentPath)

    if (-not (Test-Path -LiteralPath $ParentPath -PathType Container)) {
        throw "Evidence parent directory does not exist: $ParentPath"
    }

    $runs = @(Get-ChildItem -LiteralPath $ParentPath -Directory -Force | Sort-Object Name -Descending)
    if ($runs.Count -eq 0) {
        throw "No evidence run directories found under: $ParentPath"
    }

    return $runs[0]
}

function Get-RequiredEvidenceFile {
    param(
        [Parameter(Mandatory)][System.IO.DirectoryInfo]$RunDirectory,
        [Parameter(Mandatory)][string]$Name
    )

    $path = Join-Path $RunDirectory.FullName $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required evidence file is missing from run '$($RunDirectory.Name)': $Name"
    }
    return $path
}

function Get-TextForReceipt {
    param([Parameter(Mandatory)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    return $text.TrimEnd("`r","`n")
}

function Add-EvidenceHash {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$HashRows,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Path
    )

    $HashRows.Add([pscustomobject]@{
        category = $Category
        run_id = $RunId
        file_name = [System.IO.Path]::GetFileName($Path)
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    })
}

function Add-CsvSection {
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$HashRows,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Path
    )

    Add-EvidenceHash -HashRows $HashRows -Category $Category -RunId $RunId -Path $Path
    [void]$Builder.AppendLine("### $Title")
    [void]$Builder.AppendLine('')
    [void]$Builder.AppendLine('```csv')
    [void]$Builder.AppendLine((Get-TextForReceipt -Path $Path))
    [void]$Builder.AppendLine('```')
    [void]$Builder.AppendLine('')
}

function Get-StatusCount {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [Parameter(Mandatory)][string]$Status
    )
    return @($Rows | Where-Object { [string]$_.status -eq $Status }).Count
}

function Write-EvidenceSnapshot {
    param(
        [Parameter(Mandatory)][string]$EvidenceRootPath,
        [Parameter(Mandatory)][string]$RepoRootPath
    )

    $krakenRun = Get-LatestRunDirectory -ParentPath (Join-Path $EvidenceRootPath 'kraken-reconciliation')
    $newsRun = Get-LatestRunDirectory -ParentPath (Join-Path $EvidenceRootPath 'news-source-coverage')

    $krakenMemberPath = Get-RequiredEvidenceFile -RunDirectory $krakenRun -Name 'member-reconciliation.csv'
    $krakenArchivePath = Get-RequiredEvidenceFile -RunDirectory $krakenRun -Name 'archive-reconciliation.csv'

    $newsRunPath = Get-RequiredEvidenceFile -RunDirectory $newsRun -Name 'acquisition-runs.csv'
    $newsProtocolPath = Get-RequiredEvidenceFile -RunDirectory $newsRun -Name 'protocol-contracts.csv'
    $newsObjectSummaryPath = Get-RequiredEvidenceFile -RunDirectory $newsRun -Name 'acquisition-object-summary.csv'
    $newsChecksPath = Get-RequiredEvidenceFile -RunDirectory $newsRun -Name 'coverage-checks.csv'
    $newsFactorsPath = Get-RequiredEvidenceFile -RunDirectory $newsRun -Name 'factor-table-counts.csv'
    $newsEventsPath = Get-RequiredEvidenceFile -RunDirectory $newsRun -Name 'latest-run-events.csv'

    $krakenMembers = @(Import-Csv -LiteralPath $krakenMemberPath)
    $krakenArchives = @(Import-Csv -LiteralPath $krakenArchivePath)
    $newsChecks = @(Import-Csv -LiteralPath $newsChecksPath)

    if ($krakenMembers.Count -eq 0) { throw 'Kraken member reconciliation is empty.' }
    if ($krakenArchives.Count -eq 0) { throw 'Kraken archive reconciliation is empty.' }
    if ($newsChecks.Count -eq 0) { throw 'News coverage checks are empty.' }

    $builder = New-Object System.Text.StringBuilder
    $hashRows = New-Object System.Collections.Generic.List[object]

    [void]$builder.AppendLine('# CFA Local Validation Evidence Snapshot')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('This is a curated validation receipt. Raw market/news data, full generated outputs, credentials, database backups, and temporary files remain outside Git. The source evidence files remain under `Documents\CFA-local`; this receipt records bounded summaries plus SHA-256 lineage so the evidence can be reviewed through the CFA repository.')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('## Source runs')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine("- Kraken reconciliation run: $($krakenRun.Name).")
    [void]$builder.AppendLine("- News source coverage run: $($newsRun.Name).")
    [void]$builder.AppendLine('')

    [void]$builder.AppendLine('## Kraken reconciliation summary')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine("- Manifest member rows: $($krakenMembers.Count).")
    foreach ($status in @('PASS','MISSING','HASH_MISMATCH','AMBIGUOUS','UNVERIFIED_CANDIDATE_SHAPE')) {
        [void]$builder.AppendLine("- $($status): $(Get-StatusCount -Rows $krakenMembers -Status $status).")
    }
    [void]$builder.AppendLine("- Archive PASS: $(Get-StatusCount -Rows $krakenArchives -Status 'PASS').")
    [void]$builder.AppendLine('')

    Add-CsvSection -Builder $builder -HashRows $hashRows -Category 'kraken' -RunId $krakenRun.Name -Title 'Archive reconciliation' -Path $krakenArchivePath
    Add-EvidenceHash -HashRows $hashRows -Category 'kraken' -RunId $krakenRun.Name -Path $krakenMemberPath

    $newsFail = Get-StatusCount -Rows $newsChecks -Status 'FAIL'
    $newsUnverified = Get-StatusCount -Rows $newsChecks -Status 'UNVERIFIED'
    $newsPass = Get-StatusCount -Rows $newsChecks -Status 'PASS'

    [void]$builder.AppendLine('## News source coverage summary')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine("- Coverage checks PASS: $newsPass.")
    [void]$builder.AppendLine("- Coverage checks FAIL: $newsFail.")
    [void]$builder.AppendLine("- Coverage checks UNVERIFIED: $newsUnverified.")
    [void]$builder.AppendLine('')

    Add-CsvSection -Builder $builder -HashRows $hashRows -Category 'news' -RunId $newsRun.Name -Title 'Coverage checks' -Path $newsChecksPath
    Add-CsvSection -Builder $builder -HashRows $hashRows -Category 'news' -RunId $newsRun.Name -Title 'Acquisition run' -Path $newsRunPath
    Add-CsvSection -Builder $builder -HashRows $hashRows -Category 'news' -RunId $newsRun.Name -Title 'Protocol contract' -Path $newsProtocolPath
    Add-CsvSection -Builder $builder -HashRows $hashRows -Category 'news' -RunId $newsRun.Name -Title 'Acquisition object summary' -Path $newsObjectSummaryPath
    Add-CsvSection -Builder $builder -HashRows $hashRows -Category 'news' -RunId $newsRun.Name -Title 'Hype table counts' -Path $newsFactorsPath
    Add-CsvSection -Builder $builder -HashRows $hashRows -Category 'news' -RunId $newsRun.Name -Title 'Latest bounded run events' -Path $newsEventsPath

    [void]$builder.AppendLine('## Source evidence SHA-256')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('| Category | Run ID | File | SHA-256 |')
    [void]$builder.AppendLine('|---|---|---|---|')
    foreach ($row in $hashRows) {
        [void]$builder.AppendLine("| $($row.category) | $($row.run_id) | $($row.file_name) | $($row.sha256) |")
    }
    [void]$builder.AppendLine('')

    $receiptPath = Join-Path $RepoRootPath 'docs\evidence\latest-local-validation.md'
    Write-Utf8NoBom -Path $receiptPath -Content $builder.ToString()

    return [pscustomobject]@{
        receipt_path = $receiptPath
        kraken_run_id = $krakenRun.Name
        news_run_id = $newsRun.Name
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Push-Location $WorkingDirectory
    try {
        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$text"
        }
        return $text.Trim()
    }
    finally {
        Pop-Location
    }
}

function Invoke-SelfTest {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-evidence-publisher-' + [guid]::NewGuid().ToString('N'))
    $evidence = Join-Path $tempRoot 'CFA-local'
    $repo = Join-Path $tempRoot 'repo'
    $krakenRun = Join-Path $evidence 'kraken-reconciliation\20260101-010101-testkraken'
    $newsRun = Join-Path $evidence 'news-source-coverage\20260101-020202-testnews'

    try {
        New-Item -ItemType Directory -Path $krakenRun -Force | Out-Null
        New-Item -ItemType Directory -Path $newsRun -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repo 'docs\evidence') -Force | Out-Null

        Write-Utf8NoBom -Path (Join-Path $krakenRun 'member-reconciliation.csv') -Content "source_member_ordinal,status`n1,PASS`n2,PASS`n"
        Write-Utf8NoBom -Path (Join-Path $krakenRun 'archive-reconciliation.csv') -Content "import_run_id,status`nabc,PASS`n"

        Write-Utf8NoBom -Path (Join-Path $newsRun 'acquisition-runs.csv') -Content "run_id,status,expected_object_count`nr1,running,10`n"
        Write-Utf8NoBom -Path (Join-Path $newsRun 'protocol-contracts.csv') -Content "protocol_id,selected_object_count`np1,10`n"
        Write-Utf8NoBom -Path (Join-Path $newsRun 'acquisition-object-summary.csv') -Content "exact_object_rows,distinct_payload_sha256,null_payload_sha256_rows`n2,2,0`n"
        Write-Utf8NoBom -Path (Join-Path $newsRun 'coverage-checks.csv') -Content "check_id,status,observed,expected`nA,PASS,1,1`nB,FAIL,2,10`n"
        Write-Utf8NoBom -Path (Join-Path $newsRun 'factor-table-counts.csv') -Content "relation_name,exact_rows`nsubjects,3`n"
        Write-Utf8NoBom -Path (Join-Path $newsRun 'latest-run-events.csv') -Content "event_id,event_type,message`n1,error,boom`n"

        $result = Write-EvidenceSnapshot -EvidenceRootPath $evidence -RepoRootPath $repo
        if (-not (Test-Path -LiteralPath $result.receipt_path -PathType Leaf)) {
            throw 'Self-test failed: receipt was not created.'
        }

        $receipt = [System.IO.File]::ReadAllText($result.receipt_path)
        foreach ($expectedText in @(
            'Kraken reconciliation run: 20260101-010101-testkraken',
            '- PASS: 2.',
            '- Coverage checks FAIL: 1.',
            '1,error,boom',
            'Source evidence SHA-256'
        )) {
            if (-not $receipt.Contains($expectedText)) {
                throw "Self-test failed: receipt did not contain expected text: $expectedText"
            }
        }

        if ($receipt.Contains($tempRoot)) {
            throw 'Self-test failed: absolute temporary path leaked into receipt.'
        }

        Write-Host 'SELF-TEST: PASS'
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    try {
        Invoke-SelfTest
        exit 0
    }
    catch {
        Write-Host 'SELF-TEST: FAIL'
        Write-Host $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) { Write-Host $_.ScriptStackTrace }
        exit 1
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }
    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $EvidenceRoot = Join-Path $documents 'CFA-local'
    }

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $EvidenceRoot = (Resolve-Path -LiteralPath $EvidenceRoot).ProviderPath

    if ($CommitAndPush) {
        $repoTop = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('rev-parse','--show-toplevel')
        if ([System.IO.Path]::GetFullPath($repoTop).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')) {
            throw "RepoRoot is not the Git repository top level: $RepoRoot"
        }

        $beforeStatus = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
        if (-not [string]::IsNullOrWhiteSpace($beforeStatus)) {
            throw "Repository has uncommitted changes. Refusing to mix evidence publication with unrelated work.`n$beforeStatus"
        }

        $branch = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('branch','--show-current')
        if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Could not determine current Git branch.' }
        [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('pull','--ff-only','origin',$branch))
    }

    $result = Write-EvidenceSnapshot -EvidenceRootPath $EvidenceRoot -RepoRootPath $RepoRoot
    Write-Host "Evidence receipt: $($result.receipt_path)"
    Write-Host "Kraken run: $($result.kraken_run_id)"
    Write-Host "News run: $($result.news_run_id)"

    if ($CommitAndPush) {
        $relativeReceipt = 'docs/evidence/latest-local-validation.md'
        $receiptStatus = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all','--',$relativeReceipt)
        if ([string]::IsNullOrWhiteSpace($receiptStatus)) {
            Write-Host 'Evidence receipt is unchanged; nothing to commit or push.'
            exit 0
        }

        $overallStatus = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('status','--porcelain','--untracked-files=all')
        $statusLines = @($overallStatus -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($line in $statusLines) {
            if (-not $line.EndsWith($relativeReceipt.Replace('/','\')) -and -not $line.EndsWith($relativeReceipt)) {
                throw "Unexpected working-tree change detected after receipt generation: $line"
            }
        }

        [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('add','--',$relativeReceipt))
        $staged = Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('diff','--cached','--name-only')
        $stagedLines = @($staged -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($stagedLines.Count -ne 1 -or $stagedLines[0] -ne $relativeReceipt) {
            throw "Unexpected staged paths. Expected only '$relativeReceipt'; observed: $staged"
        }

        $message = "Update CFA local evidence snapshot: Kraken $($result.kraken_run_id), news $($result.news_run_id)"
        [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('commit','-m',$message))
        [void](Invoke-Git -WorkingDirectory $RepoRoot -Arguments @('push','origin',$branch))
        Write-Host "Evidence receipt committed and pushed on branch '$branch'."
    }
}
catch {
    Write-Host 'CFA EVIDENCE PUBLISH: FAIL'
    Write-Host $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) { Write-Host $_.ScriptStackTrace }
    exit 1
}
