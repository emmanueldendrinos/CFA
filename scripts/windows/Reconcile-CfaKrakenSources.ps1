#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$SourceRoot = '',
    [string]$OutputRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-Psql {
    $cmd = Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }

    $found = @(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    if ($found.Count -eq 0) { throw 'psql.exe could not be found.' }
    return $found[0].FullName
}

function Invoke-PsqlText {
    param(
        [Parameter(Mandatory)][string]$PsqlExe,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Sql
    )

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = @(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2> $errFile)
        $exitCode = $LASTEXITCODE
        $stderr = ''

        if (Test-Path -LiteralPath $errFile) {
            $stderr = ((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        }

        $text = ($stdout | ForEach-Object { if ($null -ne $_) { [string]$_ } }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            $message = if ([string]::IsNullOrWhiteSpace($stderr)) { $text } else { $stderr }
            throw "psql failed for database '$Database' (exit $exitCode).`n$message"
        }
        return $text
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PsqlCsv {
    param(
        [Parameter(Mandatory)][string]$PsqlExe,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query
    )

    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Normalize-MemberPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path.Replace('\','/').TrimStart('/')).ToLowerInvariant()
}

function Get-StreamSha256 {
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Stream)
        return ([System.BitConverter]::ToString($hash)).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$oldPassword = $env:PGPASSWORD
$oldPgOptions = $env:PGOPTIONS
$bstr = [IntPtr]::Zero

try {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
        $SourceRoot = Join-Path $documents 'Projects\Kraken'
    }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path $documents 'CFA-local\kraken-reconciliation'
    }
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Kraken source root does not exist: $SourceRoot"
    }

    # Windows PowerShell 5.1 does not reliably preload these assemblies.
    # Load both explicitly before any ZIP types are referenced at runtime.
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    if ($null -eq ('System.IO.Compression.ZipFile' -as [type])) {
        throw 'System.IO.Compression.ZipFile is unavailable after loading compression assemblies.'
    }

    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
    $runDir = Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Kraken source root: $SourceRoot"
    Write-Host "Evidence directory: $runDir"

    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    $env:PGOPTIONS = '-c default_transaction_read_only=on -c statement_timeout=60000'
    $version = Invoke-PsqlText -PsqlExe $psql -Database 'asrp' -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $runsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT
    import_run_id,
    source_archive_relative_path,
    source_archive_sha256,
    source_manifest_sha256,
    selected_member_manifest_sha256,
    raw_archive_fingerprint_sha256,
    typed_archive_fingerprint_sha256
FROM asrp.q2_import_runs
ORDER BY import_run_id
'@

    $membersCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT
    import_run_id,
    source_member_ordinal,
    member_path_raw,
    expected_content_sha256,
    observed_content_sha256,
    member_raw_fingerprint_sha256,
    member_typed_fingerprint_sha256
FROM asrp.q2_import_members
ORDER BY import_run_id, source_member_ordinal
'@

    Set-Content -LiteralPath (Join-Path $runDir 'q2-import-runs.csv') -Value $runsCsv -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $runDir 'q2-import-members.csv') -Value $membersCsv -Encoding UTF8

    $runs = @($runsCsv | ConvertFrom-Csv)
    $members = @($membersCsv | ConvertFrom-Csv)

    if ($runs.Count -eq 0) { throw 'No rows found in asrp.q2_import_runs.' }
    if ($members.Count -eq 0) { throw 'No rows found in asrp.q2_import_members.' }

    $expectedByNormalizedPath = @{}
    $expectedByBaseName = @{}
    $memberResults = @{}

    foreach ($m in $members) {
        $ordinal = [string]$m.source_member_ordinal
        $rawPath = [string]$m.member_path_raw
        $normalized = Normalize-MemberPath $rawPath
        $baseName = [System.IO.Path]::GetFileName($rawPath).ToLowerInvariant()

        $expectedHash = [string]$m.expected_content_sha256
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
            $expectedHash = [string]$m.observed_content_sha256
        }
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
            throw "No valid expected/observed SHA-256 for source member ordinal $ordinal."
        }
        $expectedHash = $expectedHash.ToLowerInvariant()

        $record = [pscustomobject]@{
            ordinal = $ordinal
            member_path_raw = $rawPath
            normalized_path = $normalized
            base_name = $baseName
            expected_sha256 = $expectedHash
        }

        $expectedByNormalizedPath[$normalized] = $record
        if (-not $expectedByBaseName.ContainsKey($baseName)) {
            $expectedByBaseName[$baseName] = New-Object System.Collections.Generic.List[object]
        }
        $expectedByBaseName[$baseName].Add($record)
        $memberResults[$ordinal] = New-Object System.Collections.Generic.List[object]
    }

    $allLocalFiles = @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force | Sort-Object FullName)
    if ($allLocalFiles.Count -eq 0) {
        throw "No source files found under $SourceRoot"
    }

    # Prefer the exact archive filename recorded by PostgreSQL. This avoids
    # hashing/opening unrelated Kraken quarters. If it is absent, fall back to
    # ZIP files so renamed copies can still be investigated.
    $expectedArchiveNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($run in $runs) {
        $archivePath = [string]$run.source_archive_relative_path
        if (-not [string]::IsNullOrWhiteSpace($archivePath)) {
            $archiveName = [System.IO.Path]::GetFileName($archivePath)
            if (-not [string]::IsNullOrWhiteSpace($archiveName)) {
                [void]$expectedArchiveNames.Add($archiveName)
            }
        }
    }

    $exactArchiveCandidates = @(
        $allLocalFiles | Where-Object { $expectedArchiveNames.Contains($_.Name) }
    )

    if ($exactArchiveCandidates.Count -gt 0) {
        $filesToInspect = $exactArchiveCandidates
        Write-Host "Recorded archive filename found locally; inspecting only $($filesToInspect.Count) exact candidate(s)."
    }
    else {
        $filesToInspect = @($allLocalFiles | Where-Object { $_.Extension -ieq '.zip' })
        Write-Host 'Recorded archive filename not found locally; falling back to all ZIP files.'
    }

    if ($filesToInspect.Count -eq 0) {
        throw 'No candidate source archive files were found.'
    }

    $localInventory = New-Object System.Collections.Generic.List[object]
    $candidateCount = 0

    foreach ($file in $filesToInspect) {
        $relative = $file.FullName.Substring($SourceRoot.TrimEnd('\','/').Length).TrimStart('\','/').Replace('\','/')
        $extension = $file.Extension.ToLowerInvariant()

        Write-Host "Inspecting source file: $relative"
        $fileHash = Get-FileSha256 -Path $file.FullName

        $localInventory.Add([pscustomobject]@{
            relative_path = $relative
            size_bytes = $file.Length
            sha256 = $fileHash
            kind = if ($extension -eq '.zip') { 'ZIP' } else { 'FILE' }
        })

        if ($extension -eq '.zip') {
            $archive = $null
            try {
                # ZipFile.OpenRead is supported by Windows PowerShell 5.1 once
                # System.IO.Compression and FileSystem are explicitly loaded.
                $archive = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)

                foreach ($entry in $archive.Entries) {
                    if ([string]::IsNullOrEmpty($entry.Name)) { continue }

                    $entryNorm = Normalize-MemberPath $entry.FullName
                    $entryBase = $entry.Name.ToLowerInvariant()
                    $targets = New-Object System.Collections.Generic.List[object]

                    if ($expectedByNormalizedPath.ContainsKey($entryNorm)) {
                        $targets.Add($expectedByNormalizedPath[$entryNorm])
                    }
                    elseif ($expectedByBaseName.ContainsKey($entryBase)) {
                        foreach ($target in $expectedByBaseName[$entryBase]) {
                            $targets.Add($target)
                        }
                    }

                    if ($targets.Count -eq 0) { continue }

                    $candidateCount++
                    $entryStream = $null
                    try {
                        $entryStream = $entry.Open()
                        $entryHash = Get-StreamSha256 -Stream $entryStream
                    }
                    finally {
                        if ($null -ne $entryStream) { $entryStream.Dispose() }
                    }

                    foreach ($target in $targets) {
                        $memberResults[$target.ordinal].Add([pscustomobject]@{
                            source_container = $relative
                            local_member_path = $entry.FullName
                            local_sha256 = $entryHash
                            expected_sha256 = $target.expected_sha256
                            hash_match = ($entryHash -eq $target.expected_sha256)
                        })
                    }
                }
            }
            finally {
                if ($null -ne $archive) { $archive.Dispose() }
            }
        }
        else {
            $base = $file.Name.ToLowerInvariant()
            if ($expectedByBaseName.ContainsKey($base)) {
                $candidateCount++
                foreach ($target in $expectedByBaseName[$base]) {
                    $memberResults[$target.ordinal].Add([pscustomobject]@{
                        source_container = $relative
                        local_member_path = $relative
                        local_sha256 = $fileHash
                        expected_sha256 = $target.expected_sha256
                        hash_match = ($fileHash -eq $target.expected_sha256)
                    })
                }
            }
        }
    }

    $resultRows = New-Object System.Collections.Generic.List[object]
    $matched = 0
    $missing = 0
    $mismatched = 0
    $ambiguous = 0

    foreach ($m in $members) {
        $ordinal = [string]$m.source_member_ordinal
        $candidates = $memberResults[$ordinal]
        $matches = @($candidates | Where-Object { $_.hash_match -eq $true })

        if ($matches.Count -eq 1) {
            $status = 'PASS'
            $matched++
        }
        elseif ($matches.Count -gt 1) {
            $status = 'AMBIGUOUS'
            $ambiguous++
        }
        elseif ($candidates.Count -eq 0) {
            $status = 'MISSING'
            $missing++
        }
        else {
            $status = 'HASH_MISMATCH'
            $mismatched++
        }

        $expectedHash = [string]$m.expected_content_sha256
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
            $expectedHash = [string]$m.observed_content_sha256
        }

        $resultRows.Add([pscustomobject]@{
            source_member_ordinal = $ordinal
            member_path_raw = [string]$m.member_path_raw
            expected_sha256 = $expectedHash.ToLowerInvariant()
            candidate_count = $candidates.Count
            matching_candidate_count = $matches.Count
            status = $status
            matching_locations = ($matches | ForEach-Object { "$($_.source_container)::$($_.local_member_path)" }) -join ';'
        })
    }

    $archiveRows = New-Object System.Collections.Generic.List[object]
    foreach ($run in $runs) {
        $expectedArchiveHash = ([string]$run.source_archive_sha256).ToLowerInvariant()
        $matchingLocal = @($localInventory | Where-Object { $_.sha256 -eq $expectedArchiveHash })

        $archiveRows.Add([pscustomobject]@{
            import_run_id = $run.import_run_id
            source_archive_relative_path = $run.source_archive_relative_path
            expected_source_archive_sha256 = $expectedArchiveHash
            matching_local_file_count = $matchingLocal.Count
            matching_local_files = ($matchingLocal | ForEach-Object { $_.relative_path }) -join ';'
            status = if ($matchingLocal.Count -eq 1) { 'PASS' } elseif ($matchingLocal.Count -gt 1) { 'AMBIGUOUS' } else { 'UNVERIFIED' }
        })
    }

    $localInventory | Export-Csv -LiteralPath (Join-Path $runDir 'local-file-inventory.csv') -NoTypeInformation -Encoding UTF8
    $resultRows | Export-Csv -LiteralPath (Join-Path $runDir 'member-reconciliation.csv') -NoTypeInformation -Encoding UTF8
    $archiveRows | Export-Csv -LiteralPath (Join-Path $runDir 'archive-reconciliation.csv') -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host '=== KRAKEN MEMBER RECONCILIATION ==='
    Write-Host "Database manifest members : $($members.Count)"
    Write-Host "Local files discovered    : $($allLocalFiles.Count)"
    Write-Host "Archive files inspected   : $($filesToInspect.Count)"
    Write-Host "Candidate member objects  : $candidateCount"
    Write-Host "PASS                      : $matched"
    Write-Host "MISSING                   : $missing"
    Write-Host "HASH_MISMATCH             : $mismatched"
    Write-Host "AMBIGUOUS                 : $ambiguous"
    Write-Host ''
    Write-Host '=== ARCHIVE RECONCILIATION ==='
    $archiveRows | Format-Table -AutoSize
    Write-Host ''
    Write-Host "Evidence directory: $runDir"
    Write-Host 'READ-ONLY KRAKEN RECONCILIATION: COMPLETE'
    Write-Host 'No Kraken file was modified or extracted. No PostgreSQL object or row was modified.'
}
catch {
    Write-Host ''
    Write-Host 'READ-ONLY KRAKEN RECONCILIATION: FAIL'
    Write-Host $_.Exception.Message
}
finally {
    if ($null -eq $oldPgOptions) {
        Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue
    }
    else {
        $env:PGOPTIONS = $oldPgOptions
    }

    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    if ($null -eq $oldPassword) {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
    else {
        $env:PGPASSWORD = $oldPassword
    }
}
