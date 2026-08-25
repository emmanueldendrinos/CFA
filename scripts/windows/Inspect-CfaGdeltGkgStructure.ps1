#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ArchiveRoot = '',
    [string]$OutputRoot = '',
    [ValidateRange(10,5000)][int]$RowsPerArchive = 500,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-LineMetrics {
    param(
        [System.IO.Stream]$Stream,
        [int]$MaxRows
    )

    $fieldCounts = @{}
    $sampledRows = 0
    $utf8ValidRows = 0
    $utf8InvalidRows = 0
    $crlfRows = 0
    $lfOnlyRows = 0
    $maxLineBytes = 0
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    $buffer = New-Object System.Collections.Generic.List[byte]

    while ($sampledRows -lt $MaxRows) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { break }
        $byte = [byte]$value

        if ($byte -eq 10) {
            $bytes = $buffer.ToArray()
            $buffer.Clear()
            $sampledRows++
            if ($bytes.Length -gt $maxLineBytes) { $maxLineBytes = $bytes.Length }

            $end = $bytes.Length
            if ($end -gt 0 -and $bytes[$end - 1] -eq 13) {
                $crlfRows++
                $end--
            } else {
                $lfOnlyRows++
            }

            $tabs = 0
            for ($i = 0; $i -lt $end; $i++) {
                if ($bytes[$i] -eq 9) { $tabs++ }
            }
            $fields = $tabs + 1
            if (-not $fieldCounts.ContainsKey($fields)) { $fieldCounts[$fields] = 0 }
            $fieldCounts[$fields] = [int]$fieldCounts[$fields] + 1

            try {
                [void]$utf8.GetString($bytes,0,$end)
                $utf8ValidRows++
            }
            catch {
                $utf8InvalidRows++
            }
        }
        else {
            $buffer.Add($byte)
        }
    }

    if ($sampledRows -lt $MaxRows -and $buffer.Count -gt 0) {
        $bytes = $buffer.ToArray()
        $sampledRows++
        if ($bytes.Length -gt $maxLineBytes) { $maxLineBytes = $bytes.Length }

        $tabs = 0
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 9) { $tabs++ }
        }
        $fields = $tabs + 1
        if (-not $fieldCounts.ContainsKey($fields)) { $fieldCounts[$fields] = 0 }
        $fieldCounts[$fields] = [int]$fieldCounts[$fields] + 1

        try {
            [void]$utf8.GetString($bytes)
            $utf8ValidRows++
        }
        catch {
            $utf8InvalidRows++
        }
    }

    return [pscustomobject]@{
        sampled_rows = $sampledRows
        field_counts = $fieldCounts
        utf8_valid_rows = $utf8ValidRows
        utf8_invalid_rows = $utf8InvalidRows
        crlf_rows = $crlfRows
        lf_only_rows = $lfOnlyRows
        max_line_bytes = $maxLineBytes
    }
}

function Inspect-Archives {
    param(
        [string[]]$Paths,
        [int]$Rows
    )

    $archiveRows = @()
    $distribution = @()

    foreach ($path in $Paths) {
        $file = Get-Item -LiteralPath $path
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
            $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
            if ($entries.Count -lt 1) { throw "ZIP contains no file entries: $($file.Name)" }

            $entry = $entries[0]
            $stream = $entry.Open()
            try {
                $metrics = Get-LineMetrics -Stream $stream -MaxRows $Rows
            }
            finally {
                $stream.Dispose()
            }

            $keys = @($metrics.field_counts.Keys | Sort-Object { [int]$_ })
            foreach ($key in $keys) {
                $distribution += [pscustomobject]@{
                    archive_file = $file.Name
                    entry_name = $entry.FullName
                    field_count = [int]$key
                    sampled_rows = [int]$metrics.field_counts[$key]
                }
            }

            $objectKey = [regex]::Match($file.Name,'^(\d{14})').Groups[1].Value
            $archiveRows += [pscustomobject]@{
                object_key = $objectKey
                archive_file = $file.Name
                archive_sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                archive_bytes = [long]$file.Length
                zip_entry_count = $entries.Count
                inspected_entry = $entry.FullName
                entry_uncompressed_bytes = [long]$entry.Length
                entry_compressed_bytes = [long]$entry.CompressedLength
                sampled_rows = [int]$metrics.sampled_rows
                distinct_field_counts = ($keys -join '|')
                min_field_count = if ($keys.Count -gt 0) { [int]$keys[0] } else { 0 }
                max_field_count = if ($keys.Count -gt 0) { [int]$keys[$keys.Count - 1] } else { 0 }
                utf8_valid_rows = [int]$metrics.utf8_valid_rows
                utf8_invalid_rows = [int]$metrics.utf8_invalid_rows
                crlf_rows = [int]$metrics.crlf_rows
                lf_only_rows = [int]$metrics.lf_only_rows
                max_line_bytes = [int]$metrics.max_line_bytes
            }
        }
        finally {
            if ($null -ne $zip) { $zip.Dispose() }
        }
    }

    return [pscustomobject]@{
        archives = $archiveRows
        distribution = $distribution
    }
}

function Get-InspectionIndices {
    param([int]$FileCount)
    if ($FileCount -lt 3) { throw 'At least three files are required for first/middle/last inspection.' }

    $lastIndex = [int]($FileCount - 1)
    $middleIndex = [int][Math]::Floor(([double]$lastIndex) / 2.0)
    return @(0,$middleIndex,$lastIndex)
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gkg-structure-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $paths = @()
        foreach ($key in @('20250401000000','20250515000000','20250630234500')) {
            $path = Join-Path $root ($key + '.gkg.csv.zip')
            $paths += $path
            $zip = [System.IO.Compression.ZipFile]::Open($path,[System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $zip.CreateEntry('sample.gkg.csv')
                $writer = New-Object System.IO.StreamWriter($entry.Open(),(New-Object System.Text.UTF8Encoding($false)))
                try { $writer.Write("a`t1`tx`n" + "b`t2`ty`n") }
                finally { $writer.Dispose() }
            }
            finally { $zip.Dispose() }
        }

        $indices = @(Get-InspectionIndices -FileCount 7163)
        if ($indices.Count -ne 3 -or $indices[0] -ne 0 -or $indices[1] -ne 3581 -or $indices[2] -ne 7162) {
            throw 'Inspection index calculation failed.'
        }

        $result = Inspect-Archives -Paths $paths -Rows 10
        if ($result.archives.Count -ne 3) { throw 'archive count' }
        if (@($result.archives | Where-Object { $_.min_field_count -ne 3 -or $_.max_field_count -ne 3 }).Count -ne 0) { throw 'field count' }
        if (@($result.archives | Where-Object { $_.utf8_invalid_rows -ne 0 }).Count -ne 0) { throw 'utf8' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $ArchiveRoot = Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $documents 'CFA-local\gdelt-gkg-structure' }

    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }

    $files = @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip' |
        Where-Object { $_.Name -match '^\d{14}\.gkg\.csv\.zip$' } |
        Sort-Object Name)

    $fileCount = [int]$files.Count
    if ($fileCount -lt 3) { throw "At least three downloaded GKG archives required; observed $fileCount." }

    $indices = @(Get-InspectionIndices -FileCount $fileCount)
    $selected = @()
    foreach ($index in $indices) { $selected += $files[[int]$index].FullName }
    if ($selected.Count -ne 3) { throw 'Could not select three distinct archives.' }

    $result = Inspect-Archives -Paths $selected -Rows $RowsPerArchive
    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $runDir = Join-Path $OutputRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $result.archives | Export-Csv -LiteralPath (Join-Path $runDir 'archive-structure.csv') -NoTypeInformation -Encoding UTF8
    $result.distribution | Export-Csv -LiteralPath (Join-Path $runDir 'field-count-distribution.csv') -NoTypeInformation -Encoding UTF8

    $sampledRows = 0
    $invalidUtf8Rows = 0
    foreach ($archive in $result.archives) {
        $sampledRows += [int]$archive.sampled_rows
        $invalidUtf8Rows += [int]$archive.utf8_invalid_rows
    }

    @([pscustomobject]@{
        run_id = $runId
        downloaded_archive_files = $fileCount
        selected_archives = $selected.Count
        rows_per_archive_limit = $RowsPerArchive
        total_sampled_rows = $sampledRows
        total_utf8_invalid_rows = $invalidUtf8Rows
    }) | Export-Csv -LiteralPath (Join-Path $runDir 'inspection-summary.csv') -NoTypeInformation -Encoding UTF8

    Write-Host "Evidence directory: $runDir"
    $result.archives | Format-Table object_key,sampled_rows,min_field_count,max_field_count,utf8_valid_rows,utf8_invalid_rows -AutoSize
    Write-Host 'CFA GDELT GKG STRUCTURE INSPECTION: PASS'
}
catch {
    Write-Host 'CFA GDELT GKG STRUCTURE INSPECTION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
