#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$SourceRoot = '',
    [string]$OutputRoot = '',
    [switch]$SelfTest
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

function Get-CandidatePropertyNames {
    param([AllowNull()][object]$Candidate)

    if ($null -eq $Candidate) { return @() }

    if ($Candidate -is [System.Collections.IDictionary]) {
        return @($Candidate.Keys | ForEach-Object { [string]$_ })
    }

    return @($Candidate.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Get-CandidateValue {
    param(
        [AllowNull()][object]$Candidate,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Candidate) { return $null }

    if ($Candidate -is [System.Collections.IDictionary]) {
        if ($Candidate.Contains($Name)) { return $Candidate[$Name] }
        return $null
    }

    foreach ($property in $Candidate.PSObject.Properties) {
        if ([string]$property.Name -eq $Name) { return $property.Value }
    }
    return $null
}

function Test-CandidateRecord {
    param([AllowNull()][object]$Candidate)

    if ($null -eq $Candidate) { return $false }

    $propertyNames = @(Get-CandidatePropertyNames -Candidate $Candidate)
    foreach ($key in @('source_container','local_member_path','local_sha256','expected_sha256','hash_match')) {
        if (-not ($propertyNames -contains $key)) { return $false }
    }
    return $true
}

function Get-CandidateShapeDescription {
    param([AllowNull()][object]$Candidate)

    if ($null -eq $Candidate) {
        return [pscustomobject]@{
            runtime_type = '<null>'
            property_names = ''
        }
    }

    return [pscustomobject]@{
        runtime_type = $Candidate.GetType().FullName
        property_names = ((Get-CandidatePropertyNames -Candidate $Candidate) -join ';')
    }
}

function Get-MatchingLocationSummary {
    param([Parameter(Mandatory)][object[]]$MatchingCandidates)

    $locations = New-Object System.Collections.Generic.List[string]
    [int]$invalid = 0

    foreach ($matchCandidate in $MatchingCandidates) {
        if (-not (Test-CandidateRecord -Candidate $matchCandidate)) {
            $invalid++
            continue
        }

        $container = [string](Get-CandidateValue -Candidate $matchCandidate -Name 'source_container')
        $memberPath = [string](Get-CandidateValue -Candidate $matchCandidate -Name 'local_member_path')
        if ([string]::IsNullOrWhiteSpace($container) -or [string]::IsNullOrWhiteSpace($memberPath)) {
            $invalid++
            continue
        }

        $locations.Add($container + '::' + $memberPath)
    }

    return [pscustomobject]@{
        text = ($locations -join ';')
        invalid_count = $invalid
    }
}

function Initialize-ZipSupport {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    if ($null -eq ('System.IO.Compression.ZipFile' -as [type])) {
        throw 'System.IO.Compression.ZipFile is unavailable after loading compression assemblies.'
    }
}

function Invoke-SelfTest {
    Initialize-ZipSupport

    $candidateHashtable = @{
        source_container = 'sample.zip'
        local_member_path = 'sample.csv'
        local_sha256 = ('a' * 64)
        expected_sha256 = ('a' * 64)
        hash_match = $true
    }
    $candidateObject = [pscustomobject]@{
        source_container = 'sample-2.zip'
        local_member_path = 'sample-2.csv'
        local_sha256 = ('b' * 64)
        expected_sha256 = ('b' * 64)
        hash_match = $true
    }
    $candidateMalformed = [pscustomobject]@{ hash_match = $true }

    if (-not (Test-CandidateRecord -Candidate $candidateHashtable)) {
        throw 'Self-test failed: valid hashtable candidate was rejected.'
    }
    if (-not (Test-CandidateRecord -Candidate $candidateObject)) {
        throw 'Self-test failed: valid PSCustomObject candidate was rejected.'
    }
    if (Test-CandidateRecord -Candidate $candidateMalformed) {
        throw 'Self-test failed: malformed candidate was accepted.'
    }

    # Mirror the real reconciliation storage path exactly: a hashtable of arrays.
    # Avoid Generic.List[object] here because Windows PowerShell collection adaptation
    # can vary by runtime and is not required for this bounded workload.
    $candidateStore = @{}
    $candidateStore['1'] = @()
    $candidateStore['1'] = @($candidateStore['1']) + ,$candidateHashtable
    $candidateStore['1'] = @($candidateStore['1']) + ,$candidateObject
    $candidateStore['1'] = @($candidateStore['1']) + ,$candidateMalformed

    $candidateList = @($candidateStore['1'])
    $validCandidates = @($candidateList | Where-Object { Test-CandidateRecord -Candidate $_ })
    if ($validCandidates.Count -ne 2) {
        throw "Self-test failed: expected two valid candidates after hashtable/array storage round-trip, found $($validCandidates.Count)."
    }

    $hashMatches = @($validCandidates | Where-Object { (Get-CandidateValue -Candidate $_ -Name 'hash_match') -eq $true })
    if ($hashMatches.Count -ne 2) {
        throw "Self-test failed: expected two hash matches after hashtable/array storage round-trip, found $($hashMatches.Count)."
    }

    # Regression test: -match/-notmatch mutate PowerShell's automatic $Matches
    # variable. The reconciliation must not store candidate state in that name.
    $regexProbe = ('c' * 64) -match '^[0-9a-f]{64}$'
    if (-not $regexProbe) {
        throw 'Self-test failed: regex probe did not match as expected.'
    }

    $locationSummary = Get-MatchingLocationSummary -MatchingCandidates $hashMatches
    if ($locationSummary.text -ne 'sample.zip::sample.csv;sample-2.zip::sample-2.csv') {
        throw "Self-test failed: hash-match locations were corrupted after regex evaluation: '$($locationSummary.text)'."
    }
    if ([int]$locationSummary.invalid_count -ne 0) {
        throw "Self-test failed: expected zero invalid hash-match locations, found $($locationSummary.invalid_count)."
    }

    $malformedSummary = Get-MatchingLocationSummary -MatchingCandidates @($candidateMalformed)
    if ([int]$malformedSummary.invalid_count -ne 1) {
        throw "Self-test failed: expected one invalid malformed candidate, found $($malformedSummary.invalid_count)."
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-zip-selftest-' + [guid]::NewGuid().ToString('N'))
    $sourceDir = Join-Path $tempRoot 'source'
    $zipPath = Join-Path $tempRoot 'sample.zip'

    try {
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceDir 'sample.csv') -Value '1,2,3' -Encoding ASCII
        Compress-Archive -Path (Join-Path $sourceDir 'sample.csv') -DestinationPath $zipPath -Force

        $archive = $null
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
            if ($archive.Entries.Count -ne 1) {
                throw "Self-test failed: expected one ZIP entry, found $($archive.Entries.Count)."
            }
            $entryStream = $null
            try {
                $entryStream = $archive.Entries[0].Open()
                $hash = Get-StreamSha256 -Stream $entryStream
            }
            finally {
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
            if ($hash -notmatch '^[0-9a-f]{64}$') {
                throw 'Self-test failed: ZIP entry SHA-256 was malformed.'
            }
        }
        finally {
            if ($null -ne $archive) { $archive.Dispose() }
        }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'SELF-TEST: PASS'
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

    Initialize-ZipSupport

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

        $record = @{
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
        $memberResults[$ordinal] = @()
    }

    $allLocalFiles = @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -Force | Sort-Object FullName)
    if ($allLocalFiles.Count -eq 0) {
        throw "No source files found under $SourceRoot"
    }

    # Prefer the exact archive filename recorded by PostgreSQL. This avoids
    # hashing/opening unrelated quarters. Only fall back to all ZIP files if
    # the recorded source archive filename is absent locally.
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

    $exactArchiveCandidates = @($allLocalFiles | Where-Object { $expectedArchiveNames.Contains($_.Name) })

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
                        $targetOrdinal = [string]$target['ordinal']
                        $targetExpectedHash = [string]$target['expected_sha256']
                        $candidate = [pscustomobject]@{
                            source_container = $relative
                            local_member_path = $entry.FullName
                            local_sha256 = $entryHash
                            expected_sha256 = $targetExpectedHash
                            hash_match = ($entryHash -eq $targetExpectedHash)
                        }
                        $memberResults[$targetOrdinal] = @($memberResults[$targetOrdinal]) + ,$candidate
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
                    $targetOrdinal = [string]$target['ordinal']
                    $targetExpectedHash = [string]$target['expected_sha256']
                    $candidate = [pscustomobject]@{
                        source_container = $relative
                        local_member_path = $relative
                        local_sha256 = $fileHash
                        expected_sha256 = $targetExpectedHash
                        hash_match = ($fileHash -eq $targetExpectedHash)
                    }
                    $memberResults[$targetOrdinal] = @($memberResults[$targetOrdinal]) + ,$candidate
                }
            }
        }
    }

    $resultRows = New-Object System.Collections.Generic.List[object]
    $shapeDiagnostics = New-Object System.Collections.Generic.List[object]
    $matched = 0
    $missing = 0
    $mismatched = 0
    $ambiguous = 0
    $shapeUnverified = 0

    foreach ($m in $members) {
        $ordinal = [string]$m.source_member_ordinal
        $candidates = @($memberResults[$ordinal])
        $validCandidates = @($candidates | Where-Object { Test-CandidateRecord -Candidate $_ })
        $invalidCandidates = @($candidates | Where-Object { -not (Test-CandidateRecord -Candidate $_) })
        $invalidCandidateCount = $invalidCandidates.Count
        $hashMatches = @($validCandidates | Where-Object { (Get-CandidateValue -Candidate $_ -Name 'hash_match') -eq $true })

        foreach ($invalidCandidate in $invalidCandidates) {
            $shape = Get-CandidateShapeDescription -Candidate $invalidCandidate
            $shapeDiagnostics.Add([pscustomobject]@{
                source_member_ordinal = $ordinal
                member_path_raw = [string]$m.member_path_raw
                runtime_type = [string]$shape.runtime_type
                property_names = [string]$shape.property_names
            })
        }

        if ($invalidCandidateCount -gt 0) {
            $status = 'UNVERIFIED_CANDIDATE_SHAPE'
            $shapeUnverified++
        }
        elseif ($hashMatches.Count -eq 1) {
            $status = 'PASS'
            $matched++
        }
        elseif ($hashMatches.Count -gt 1) {
            $status = 'AMBIGUOUS'
            $ambiguous++
        }
        elseif ($validCandidates.Count -eq 0) {
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

        $locationSummary = Get-MatchingLocationSummary -MatchingCandidates $hashMatches
        if ([int]$locationSummary.invalid_count -gt 0 -and $status -eq 'PASS') {
            $status = 'UNVERIFIED_CANDIDATE_SHAPE'
            $matched--
            $shapeUnverified++
        }

        $resultRows.Add([pscustomobject]@{
            source_member_ordinal = $ordinal
            member_path_raw = [string]$m.member_path_raw
            expected_sha256 = $expectedHash.ToLowerInvariant()
            candidate_count = $candidates.Count
            valid_candidate_count = $validCandidates.Count
            invalid_candidate_shape_count = $invalidCandidateCount + [int]$locationSummary.invalid_count
            matching_candidate_count = $hashMatches.Count
            status = $status
            matching_locations = [string]$locationSummary.text
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
            matching_local_files = ($matchingLocal | ForEach-Object { [string]$_.relative_path }) -join ';'
            status = if ($matchingLocal.Count -eq 1) { 'PASS' } elseif ($matchingLocal.Count -gt 1) { 'AMBIGUOUS' } else { 'UNVERIFIED' }
        })
    }

    $localInventory | Export-Csv -LiteralPath (Join-Path $runDir 'local-file-inventory.csv') -NoTypeInformation -Encoding UTF8
    $resultRows | Export-Csv -LiteralPath (Join-Path $runDir 'member-reconciliation.csv') -NoTypeInformation -Encoding UTF8
    $archiveRows | Export-Csv -LiteralPath (Join-Path $runDir 'archive-reconciliation.csv') -NoTypeInformation -Encoding UTF8
    $shapeDiagnostics | Export-Csv -LiteralPath (Join-Path $runDir 'candidate-shape-diagnostics.csv') -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host '=== KRAKEN MEMBER RECONCILIATION ==='
    Write-Host "Database manifest members       : $($members.Count)"
    Write-Host "Local files discovered          : $($allLocalFiles.Count)"
    Write-Host "Archive files inspected         : $($filesToInspect.Count)"
    Write-Host "Candidate member objects        : $candidateCount"
    Write-Host "PASS                            : $matched"
    Write-Host "MISSING                         : $missing"
    Write-Host "HASH_MISMATCH                   : $mismatched"
    Write-Host "AMBIGUOUS                       : $ambiguous"
    Write-Host "UNVERIFIED_CANDIDATE_SHAPE      : $shapeUnverified"

    if ($shapeDiagnostics.Count -gt 0) {
        Write-Host ''
        Write-Host 'First invalid candidate shape:'
        $shapeDiagnostics | Select-Object -First 1 | Format-List source_member_ordinal,member_path_raw,runtime_type,property_names
    }

    Write-Host ''
    Write-Host '=== ARCHIVE RECONCILIATION ==='
    $archiveRows | Format-List import_run_id,source_archive_relative_path,expected_source_archive_sha256,matching_local_file_count,matching_local_files,status
    Write-Host ''
    Write-Host "Evidence directory: $runDir"
    Write-Host 'READ-ONLY KRAKEN RECONCILIATION: COMPLETE'
    Write-Host 'No Kraken file was modified or extracted. No PostgreSQL object or row was modified.'
}
catch {
    Write-Host ''
    Write-Host 'READ-ONLY KRAKEN RECONCILIATION: FAIL'
    Write-Host $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Write-Host $_.ScriptStackTrace
    }
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
