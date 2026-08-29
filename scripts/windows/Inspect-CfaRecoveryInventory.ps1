#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ExternalDriveRoot = 'D:\',
    [string]$OutputBase = '',
    [string[]]$Roots = @(),
    [long]$HashMaxBytes = 268435456,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DocumentsPath {
    $p = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($p)) { return (Join-Path $HOME 'Documents') }
    return $p
}

function Get-RootKind {
    param([string]$Path)
    $leaf = [System.IO.Path]::GetFileName($Path.TrimEnd('\')).ToLowerInvariant()
    switch ($leaf) {
        'cfa-local' { return 'CFA_LOCAL' }
        'cfa-bulk' { return 'EXTERNAL_CFA' }
        'cfa-recovery' { return 'EXTERNAL_CFA' }
        'cfa' { return 'CFA_REPO' }
        'asrp' { return 'ASRP_LEGACY' }
        'srp' { return 'SRP_LEGACY' }
        default { return 'OTHER' }
    }
}

function Test-Bulk {
    param([System.IO.FileInfo]$File)
    $ext = $File.Extension.ToLowerInvariant()
    if ($File.Length -ge 536870912) { return $true }
    if (@('.zip','.7z','.rar','.gz','.bz2','.xz','.zst','.tar','.dump','.backup','.bak','.db','.sqlite','.sqlite3','.parquet','.feather','.arrow') -contains $ext) { return $true }
    if ($File.FullName -match '(?i)(gdelt-gkg|kraken_ohlcvt|[\\/]archives[\\/])') { return $true }
    return $false
}

function Test-ControlFile {
    param([System.IO.FileInfo]$File)
    $ext = $File.Extension.ToLowerInvariant()
    if (@('.ps1','.psm1','.psd1','.py','.sql','.md','.json','.yaml','.yml','.toml','.ini','.cfg','.xlsx','.xls','.csv','.tsv','.txt','.r') -contains $ext) { return $true }
    return ($File.Name -match '(?i)(readme|manifest|requirements|pyproject|package\.json)')
}

function Test-RecoveryLead {
    param([System.IO.FileInfo]$File)
    return ($File.FullName -match '(?i)(PLS|7[._-]?8[._-]?1|partial[ _-]*least|spike|factor|response|hype|news|market|benchmark|validation|SoT|contract)')
}

function Get-Action {
    param([string]$Kind,[bool]$Bulk,[bool]$Lead,[bool]$Control)
    if ($Bulk) { return 'KEEP_EXTERNAL_OR_REVIEW_BULK' }
    if (($Kind -eq 'SRP_LEGACY' -or $Kind -eq 'ASRP_LEGACY') -and $Lead) { return 'LEGACY_RECOVERY_LEAD_UNVERIFIED' }
    if ($Kind -eq 'SRP_LEGACY' -or $Kind -eq 'ASRP_LEGACY') { return 'LEGACY_REFERENCE_ONLY' }
    if (($Kind -eq 'CFA_REPO' -or $Kind -eq 'CFA_LOCAL') -and $Control) { return 'KEEP_CFA_CONTROL_OR_EVIDENCE' }
    if ($Lead) { return 'REVIEW_RECOVERY_LEAD' }
    return 'REVIEW'
}

function Invoke-Git {
    param([string]$Repo,[string[]]$GitArgs)
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = @(& git -C $Repo @GitArgs 2>$null)
        $code = $LASTEXITCODE
        if ($code -ne 0) { return '' }
        return (($out | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }
    finally {
        $ErrorActionPreference = $old
    }
}

function Invoke-Inventory {
    param(
        [string]$ExternalRoot,
        [string]$OutBase,
        [string[]]$ExplicitRoots,
        [long]$MaxHashBytes
    )

    if (-not (Test-Path -LiteralPath $ExternalRoot -PathType Container)) {
        throw "External drive/root not found: $ExternalRoot"
    }

    if ([string]::IsNullOrWhiteSpace($OutBase)) {
        $OutBase = Join-Path $ExternalRoot 'CFA-recovery\inventory'
    }

    $docs = Get-DocumentsPath
    $projects = Join-Path $docs 'Projects'

    $candidateRoots = @(
        (Join-Path $projects 'SRP'),
        (Join-Path $projects 'ASRP'),
        (Join-Path $projects 'CFA'),
        (Join-Path $docs 'CFA-local'),
        (Join-Path $ExternalRoot 'SRP'),
        (Join-Path $ExternalRoot 'ASRP'),
        (Join-Path $ExternalRoot 'CFA'),
        (Join-Path $ExternalRoot 'CFA-local'),
        (Join-Path $ExternalRoot 'CFA-bulk')
    ) + @($ExplicitRoots)

    $seen = @{}
    $activeRoots = @()
    foreach ($root in $candidateRoots) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) { continue }
        try { $full = [System.IO.Path]::GetFullPath([string]$root).TrimEnd('\') }
        catch { continue }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (Test-Path -LiteralPath $full -PathType Container) { $activeRoots += $full }
    }

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $outDir = Join-Path $OutBase $runId
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $fileRows = @()
    $rootRows = @()
    $gitRows = @()
    $historyRows = @()
    $errors = @()

    foreach ($root in $activeRoots) {
        $kind = Get-RootKind -Path $root
        Write-Host ("Inventory: {0} -> {1}" -f $kind,$root)

        $items = @()
        try {
            $items = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -notmatch '(?i)[\\/](\.git|node_modules|\.venv|venv|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|bin|obj)[\\/]'
                })
        }
        catch {
            $errors += [pscustomobject]@{ scope='scan'; path=$root; message=$_.Exception.Message }
        }

        [long]$rootBytes = 0
        [int]$rootBulk = 0
        [int]$rootLeads = 0

        foreach ($file in $items) {
            $bulk = Test-Bulk -File $file
            $control = Test-ControlFile -File $file
            $lead = Test-RecoveryLead -File $file
            if ($bulk) { $rootBulk++ }
            if ($lead) { $rootLeads++ }
            $rootBytes += [long]$file.Length

            $sha = ''
            $hashStatus = 'NOT_REQUESTED'
            if (-not $bulk -and ($control -or $lead) -and $file.Length -le $MaxHashBytes) {
                try {
                    $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    $hashStatus = 'PASS'
                }
                catch {
                    $hashStatus = 'ERROR'
                    $errors += [pscustomobject]@{ scope='hash'; path=$file.FullName; message=$_.Exception.Message }
                }
            }
            elseif ($bulk) { $hashStatus = 'SKIPPED_BULK' }
            elseif ($file.Length -gt $MaxHashBytes) { $hashStatus = 'SKIPPED_SIZE' }

            $relative = $file.FullName.Substring($root.Length).TrimStart('\')
            $fileRows += [pscustomobject]@{
                root_path = $root
                root_kind = $kind
                relative_path = $relative
                full_path = $file.FullName
                name = $file.Name
                extension = $file.Extension.ToLowerInvariant()
                size_bytes = [long]$file.Length
                last_write_utc = $file.LastWriteTimeUtc.ToString('o')
                is_bulk = $bulk
                is_control = $control
                is_recovery_lead = $lead
                sha256 = $sha
                hash_status = $hashStatus
                recommended_action = (Get-Action -Kind $kind -Bulk $bulk -Lead $lead -Control $control)
            }
        }

        $rootRows += [pscustomobject]@{
            root_path = $root
            root_kind = $kind
            file_count = $items.Count
            total_bytes = $rootBytes
            bulk_files = $rootBulk
            recovery_leads = $rootLeads
        }

        if (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container) {
            $head = Invoke-Git -Repo $root -GitArgs @('rev-parse','HEAD')
            $branch = Invoke-Git -Repo $root -GitArgs @('rev-parse','--abbrev-ref','HEAD')
            $tags = Invoke-Git -Repo $root -GitArgs @('tag','--list')
            $branches = Invoke-Git -Repo $root -GitArgs @('branch','-a','--no-color')
            $status = Invoke-Git -Repo $root -GitArgs @('status','--porcelain=v1')
            $matchingTags = @($tags -split "`n" | Where-Object { $_ -match '(?i)(PLS|7[._-]?8[._-]?1|spike|factor|hype)' }) -join ' | '
            $matchingBranches = @($branches -split "`n" | Where-Object { $_ -match '(?i)(PLS|7[._-]?8[._-]?1|spike|factor|hype)' }) -join ' | '
            $dirtyCount = if ([string]::IsNullOrWhiteSpace($status)) { 0 } else { @($status -split "`n").Count }

            $gitRows += [pscustomobject]@{
                repo_path = $root
                head = $head
                branch = $branch
                dirty_path_count = $dirtyCount
                matching_tags = $matchingTags
                matching_branches = $matchingBranches
            }

            $history = Invoke-Git -Repo $root -GitArgs @(
                'log','--all','--date=iso-strict',
                '--pretty=format:%H%x09%ad%x09%D%x09%s',
                '--regexp-ignore-case',
                '--grep=PLS','--grep=7.8.1','--grep=spike','--grep=factor','--grep=hype','--grep=response',
                '-n','250'
            )
            if (-not [string]::IsNullOrWhiteSpace($history)) {
                foreach ($line in ($history -split "`n")) {
                    $parts = $line -split "`t",4
                    if ($parts.Count -eq 4) {
                        $historyRows += [pscustomobject]@{
                            repo_path = $root
                            commit = $parts[0]
                            commit_date = $parts[1]
                            refs = $parts[2]
                            subject = $parts[3]
                        }
                    }
                }
            }
        }
    }

    $fileRows | Sort-Object root_path,relative_path | Export-Csv -LiteralPath (Join-Path $outDir 'files.csv') -NoTypeInformation -Encoding UTF8
    $rootRows | Sort-Object root_path | Export-Csv -LiteralPath (Join-Path $outDir 'roots.csv') -NoTypeInformation -Encoding UTF8
    @($fileRows | Where-Object { $_.is_recovery_lead }) | Sort-Object root_path,relative_path | Export-Csv -LiteralPath (Join-Path $outDir 'recovery-candidates.csv') -NoTypeInformation -Encoding UTF8
    @($fileRows | Where-Object { $_.is_bulk }) | Sort-Object size_bytes -Descending | Export-Csv -LiteralPath (Join-Path $outDir 'bulk-data.csv') -NoTypeInformation -Encoding UTF8
    $gitRows | Export-Csv -LiteralPath (Join-Path $outDir 'git-repositories.csv') -NoTypeInformation -Encoding UTF8
    $historyRows | Sort-Object commit_date -Descending | Export-Csv -LiteralPath (Join-Path $outDir 'git-recovery-history.csv') -NoTypeInformation -Encoding UTF8
    $errors | Export-Csv -LiteralPath (Join-Path $outDir 'errors.csv') -NoTypeInformation -Encoding UTF8

    $driveLines = @("external_root=$ExternalRoot")
    try {
        $driveName = ([System.IO.Path]::GetPathRoot($ExternalRoot)).TrimEnd('\').TrimEnd(':')
        $drive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop
        $driveLines += "free_bytes=$([long]$drive.Free)"
        $driveLines += "used_bytes=$([long]$drive.Used)"
    }
    catch {
        $driveLines += 'drive_capacity_status=UNVERIFIED'
    }
    $driveLines += ''
    $driveLines += 'TOP_LEVEL:'
    foreach ($item in @(Get-ChildItem -LiteralPath $ExternalRoot -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($item.PSIsContainer) { $driveLines += ("DIR`t{0}" -f $item.FullName) }
        else { $driveLines += ("FILE`t{0}`t{1}" -f [long]$item.Length,$item.FullName) }
    }
    $driveLines | Set-Content -LiteralPath (Join-Path $outDir 'external-drive.txt') -Encoding UTF8

    [long]$allBytes = [long](($fileRows | Measure-Object -Property size_bytes -Sum).Sum)
    [long]$bulkBytes = [long](($fileRows | Where-Object { $_.is_bulk } | Measure-Object -Property size_bytes -Sum).Sum)
    $plsLeads = @($fileRows | Where-Object { $_.full_path -match '(?i)(PLS|7[._-]?8[._-]?1|partial[ _-]*least)' })

    $summary = @(
        '# CFA Recovery Inventory',
        '',
        "- Run ID: $runId",
        "- Roots: $($rootRows.Count)",
        "- Files: $($fileRows.Count)",
        "- Total bytes: $allBytes",
        "- Bulk bytes: $bulkBytes",
        "- Recovery leads: $(@($fileRows | Where-Object { $_.is_recovery_lead }).Count)",
        "- PLS/7.8.1 path-name leads: $($plsLeads.Count)",
        "- Errors: $($errors.Count)",
        '',
        'Inventory-only: no source file is moved, copied, renamed, deleted, uploaded, or modified.',
        '',
        'Review recovery-candidates.csv, bulk-data.csv, git-repositories.csv, and git-recovery-history.csv before migration.'
    )
    $summary | Set-Content -LiteralPath (Join-Path $outDir 'summary.md') -Encoding UTF8

    $hashRows = @()
    foreach ($outFile in @(Get-ChildItem -LiteralPath $outDir -File -Force | Sort-Object Name)) {
        $hashRows += [pscustomobject]@{
            file = $outFile.Name
            size_bytes = [long]$outFile.Length
            sha256 = (Get-FileHash -LiteralPath $outFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $hashRows | Export-Csv -LiteralPath (Join-Path $outDir 'inventory-artifact-hashes.csv') -NoTypeInformation -Encoding UTF8

    $bundle = Join-Path $outDir 'inventory-bundle.zip'
    $bundleNames = @(
        'summary.md','roots.csv','recovery-candidates.csv','bulk-data.csv',
        'git-repositories.csv','git-recovery-history.csv','external-drive.txt',
        'errors.csv','inventory-artifact-hashes.csv'
    )
    $bundleInputs = @()
    foreach ($name in $bundleNames) {
        $p = Join-Path $outDir $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { $bundleInputs += $p }
    }
    Compress-Archive -LiteralPath $bundleInputs -DestinationPath $bundle -CompressionLevel Optimal -Force

    Write-Host ''
    Write-Host 'CFA RECOVERY INVENTORY: PASS'
    Write-Host ("Output: {0}" -f $outDir)
    Write-Host ("Bundle: {0}" -f $bundle)
    return $outDir
}

if ($SelfTest) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-recovery-selftest-' + [guid]::NewGuid().ToString('N'))
    try {
        $external = Join-Path $tmp 'external'
        $srp = Join-Path $tmp 'SRP'
        $asrp = Join-Path $tmp 'ASRP'
        $cfa = Join-Path $tmp 'CFA'
        $cfaLocal = Join-Path $tmp 'CFA-local'
        foreach ($d in @($external,$srp,$asrp,$cfa,$cfaLocal)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

        Set-Content -LiteralPath (Join-Path $srp 'README.md') -Value 'SRP fixture' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $asrp 'PLS-7.8.1-analysis.ps1') -Value 'Write-Output "fixture"' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $cfa 'CFA-SoT-test.md') -Value 'CFA fixture' -Encoding UTF8
        $archiveDir = Join-Path $cfaLocal 'gdelt-gkg-q2-2025\archives\2025\04\01'
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $archiveDir '20250401000000.gkg.csv.zip') -Value 'bulk fixture' -Encoding UTF8

        $fixturePaths = @(
            (Join-Path $srp 'README.md'),
            (Join-Path $asrp 'PLS-7.8.1-analysis.ps1'),
            (Join-Path $cfa 'CFA-SoT-test.md'),
            (Join-Path $archiveDir '20250401000000.gkg.csv.zip')
        )
        $before = @{}
        foreach ($p in $fixturePaths) { $before[$p] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

        & git -C $asrp init -q
        & git -C $asrp config user.name 'CFA SelfTest'
        & git -C $asrp config user.email 'cfa-selftest@example.invalid'
        & git -C $asrp add -- 'PLS-7.8.1-analysis.ps1'
        & git -C $asrp commit -q -m 'PLS 7.8.1 fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Self-test git commit failed.' }
        & git -C $asrp tag 'pls-7.8.1-fixture'
        if ($LASTEXITCODE -ne 0) { throw 'Self-test git tag failed.' }

        $outBase = Join-Path $external 'inventory-test'
        $outDir = Invoke-Inventory -ExternalRoot $external -OutBase $outBase -ExplicitRoots @($srp,$asrp,$cfa,$cfaLocal) -MaxHashBytes 1048576

        foreach ($name in @('files.csv','roots.csv','recovery-candidates.csv','bulk-data.csv','git-repositories.csv','git-recovery-history.csv','summary.md','inventory-bundle.zip')) {
            if (-not (Test-Path -LiteralPath (Join-Path $outDir $name) -PathType Leaf)) { throw "Self-test output missing: $name" }
        }

        $files = @(Import-Csv -LiteralPath (Join-Path $outDir 'files.csv'))
        if (@($files | Where-Object { $_.name -eq 'PLS-7.8.1-analysis.ps1' }).Count -ne 1) { throw 'Self-test PLS file inventory failed.' }

        $recovery = @(Import-Csv -LiteralPath (Join-Path $outDir 'recovery-candidates.csv'))
        if (@($recovery | Where-Object { $_.name -eq 'PLS-7.8.1-analysis.ps1' }).Count -ne 1) { throw 'Self-test recovery classification failed.' }

        $bulk = @(Import-Csv -LiteralPath (Join-Path $outDir 'bulk-data.csv'))
        if (@($bulk | Where-Object { $_.name -eq '20250401000000.gkg.csv.zip' }).Count -ne 1) { throw 'Self-test bulk classification failed.' }

        $repos = @(Import-Csv -LiteralPath (Join-Path $outDir 'git-repositories.csv'))
        $repo = @($repos | Where-Object { $_.repo_path -eq $asrp })
        if ($repo.Count -ne 1 -or [string]$repo[0].matching_tags -notmatch 'pls-7\.8\.1-fixture') { throw 'Self-test Git tag discovery failed.' }

        $history = @(Import-Csv -LiteralPath (Join-Path $outDir 'git-recovery-history.csv'))
        if (@($history | Where-Object { $_.subject -eq 'PLS 7.8.1 fixture' }).Count -ne 1) { throw 'Self-test Git history discovery failed.' }

        foreach ($p in $fixturePaths) {
            $after = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
            if ($after -ne $before[$p]) { throw "Self-test source mutation detected: $p" }
        }

        Write-Host 'CFA RECOVERY INVENTORY SELF-TEST: PASS'
        exit 0
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-Inventory -ExternalRoot $ExternalDriveRoot -OutBase $OutputBase -ExplicitRoots $Roots -MaxHashBytes $HashMaxBytes | Out-Null
