#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = '',
    [string]$AliasEvidenceRoot = '',
    [string]$OutputRoot = '',
    [ValidateRange(1,500)][int]$MaxDetailRowsPerArchive = 50,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scannerSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public sealed class CfaGkgByteDetail {
    public long RowOrdinal { get; set; }
    public int FieldCount { get; set; }
    public bool InvalidUtf8 { get; set; }
    public string InvalidFieldIndexes1Based { get; set; }
    public bool AllNamesInvalidUtf8 { get; set; }
    public bool CriticalFieldInvalidUtf8 { get; set; }
    public string FirstInvalidSequenceHex { get; set; }
    public string RawLineSha256 { get; set; }
}

public sealed class CfaGkgByteScanResult {
    public long Rows { get; set; }
    public long MalformedFieldCountRows { get; set; }
    public long InvalidUtf8Rows { get; set; }
    public long InvalidUtf8Fields { get; set; }
    public long AllNamesInvalidUtf8Rows { get; set; }
    public long CriticalFieldInvalidUtf8Rows { get; set; }
    public Dictionary<int,long> FieldCountDistribution { get; set; }
    public Dictionary<string,long> InvalidSequenceDistribution { get; set; }
    public List<CfaGkgByteDetail> Details { get; set; }

    public CfaGkgByteScanResult() {
        FieldCountDistribution = new Dictionary<int,long>();
        InvalidSequenceDistribution = new Dictionary<string,long>(StringComparer.OrdinalIgnoreCase);
        Details = new List<CfaGkgByteDetail>();
    }
}

public static class CfaGkgByteScanner {
    private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

    private static bool Contains(int[] values, int value) {
        if (values == null) return false;
        for (int i = 0; i < values.Length; i++) if (values[i] == value) return true;
        return false;
    }

    private static string Hex(byte[] bytes) {
        if (bytes == null || bytes.Length == 0) return "";
        StringBuilder sb = new StringBuilder(bytes.Length * 2);
        for (int i = 0; i < bytes.Length; i++) sb.Append(bytes[i].ToString("X2"));
        return sb.ToString();
    }

    private static string Sha256(byte[] bytes, int length) {
        using (SHA256 sha = SHA256.Create()) {
            byte[] hash = sha.ComputeHash(bytes, 0, length);
            StringBuilder sb = new StringBuilder(hash.Length * 2);
            for (int i = 0; i < hash.Length; i++) sb.Append(hash[i].ToString("x2"));
            return sb.ToString();
        }
    }

    private static void ProcessLine(byte[] raw, int rawLength, int expectedFieldCount, int allNamesIndex0Based, int[] criticalIndexes0Based, int maxDetails, CfaGkgByteScanResult result) {
        if (rawLength > 0 && raw[rawLength - 1] == 13) rawLength--;
        result.Rows++;

        List<int> starts = new List<int>();
        List<int> lengths = new List<int>();
        int start = 0;
        for (int i = 0; i < rawLength; i++) {
            if (raw[i] == 9) {
                starts.Add(start);
                lengths.Add(i - start);
                start = i + 1;
            }
        }
        starts.Add(start);
        lengths.Add(rawLength - start);

        int fieldCount = starts.Count;
        long current;
        if (!result.FieldCountDistribution.TryGetValue(fieldCount, out current)) current = 0;
        result.FieldCountDistribution[fieldCount] = current + 1;
        bool malformed = fieldCount != expectedFieldCount;
        if (malformed) result.MalformedFieldCountRows++;

        List<int> invalidFields = new List<int>();
        bool allNamesInvalid = false;
        bool criticalInvalid = false;
        string firstInvalidHex = "";

        for (int fieldIndex = 0; fieldIndex < fieldCount; fieldIndex++) {
            try {
                StrictUtf8.GetString(raw, starts[fieldIndex], lengths[fieldIndex]);
            }
            catch (DecoderFallbackException ex) {
                invalidFields.Add(fieldIndex + 1);
                result.InvalidUtf8Fields++;
                if (fieldIndex == allNamesIndex0Based) allNamesInvalid = true;
                if (Contains(criticalIndexes0Based, fieldIndex)) criticalInvalid = true;
                string hex = Hex(ex.BytesUnknown);
                if (String.IsNullOrEmpty(firstInvalidHex)) firstInvalidHex = hex;
                if (!String.IsNullOrEmpty(hex)) {
                    long n;
                    if (!result.InvalidSequenceDistribution.TryGetValue(hex, out n)) n = 0;
                    result.InvalidSequenceDistribution[hex] = n + 1;
                }
            }
        }

        bool invalid = invalidFields.Count > 0;
        if (invalid) result.InvalidUtf8Rows++;
        if (allNamesInvalid) result.AllNamesInvalidUtf8Rows++;
        if (criticalInvalid) result.CriticalFieldInvalidUtf8Rows++;

        if ((invalid || malformed) && result.Details.Count < maxDetails) {
            CfaGkgByteDetail d = new CfaGkgByteDetail();
            d.RowOrdinal = result.Rows;
            d.FieldCount = fieldCount;
            d.InvalidUtf8 = invalid;
            d.InvalidFieldIndexes1Based = String.Join("|", invalidFields.ToArray());
            d.AllNamesInvalidUtf8 = allNamesInvalid;
            d.CriticalFieldInvalidUtf8 = criticalInvalid;
            d.FirstInvalidSequenceHex = firstInvalidHex;
            d.RawLineSha256 = Sha256(raw, rawLength);
            result.Details.Add(d);
        }
    }

    public static CfaGkgByteScanResult Scan(Stream stream, int expectedFieldCount, int allNamesIndex0Based, int[] criticalIndexes0Based, int maxDetails) {
        CfaGkgByteScanResult result = new CfaGkgByteScanResult();
        byte[] chunk = new byte[65536];
        using (MemoryStream line = new MemoryStream(65536)) {
            int read;
            while ((read = stream.Read(chunk, 0, chunk.Length)) > 0) {
                int segmentStart = 0;
                for (int i = 0; i < read; i++) {
                    if (chunk[i] == 10) {
                        if (i > segmentStart) line.Write(chunk, segmentStart, i - segmentStart);
                        byte[] raw = line.ToArray();
                        ProcessLine(raw, raw.Length, expectedFieldCount, allNamesIndex0Based, criticalIndexes0Based, maxDetails, result);
                        line.SetLength(0);
                        segmentStart = i + 1;
                    }
                }
                if (segmentStart < read) line.Write(chunk, segmentStart, read - segmentStart);
            }
            if (line.Length > 0) {
                byte[] raw = line.ToArray();
                ProcessLine(raw, raw.Length, expectedFieldCount, allNamesIndex0Based, criticalIndexes0Based, maxDetails, result);
            }
        }
        return result;
    }
}
'@

if (-not ('CfaGkgByteScanner' -as [type])) { Add-Type -TypeDefinition $scannerSource -Language CSharp }

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}

function Get-LatestAliasRun {
    param([string]$Parent)
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw "Alias evidence root missing: $Parent" }
    foreach ($run in @(Get-ChildItem -LiteralPath $Parent -Directory -Force | Sort-Object Name -Descending)) {
        $scan = Join-Path $run.FullName 'archive-scan.csv'
        $summary = Join-Path $run.FullName 'validation-summary.csv'
        if ((Test-Path -LiteralPath $scan -PathType Leaf) -and (Test-Path -LiteralPath $summary -PathType Leaf)) { return $run }
    }
    throw "No usable alias validation run found under: $Parent"
}

function New-TestBytes {
    param([int]$FieldCount,[int]$InvalidField0Based)
    $list = New-Object System.Collections.Generic.List[byte]
    for ($i=0; $i -lt $FieldCount; $i++) {
        if ($i -gt 0) { $list.Add([byte]9) }
        foreach ($b in [System.Text.Encoding]::ASCII.GetBytes(('f' + $i))) { $list.Add($b) }
        if ($i -eq $InvalidField0Based) { $list.Add([byte]0xE6) }
    }
    $list.Add([byte]10)
    return $list.ToArray()
}

function Invoke-SelfTest {
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($b in (New-TestBytes -FieldCount 27 -InvalidField0Based -1)) { $bytes.Add($b) }
    foreach ($b in (New-TestBytes -FieldCount 27 -InvalidField0Based 10)) { $bytes.Add($b) }
    foreach ($b in (New-TestBytes -FieldCount 27 -InvalidField0Based 23)) { $bytes.Add($b) }
    foreach ($b in (New-TestBytes -FieldCount 28 -InvalidField0Based -1)) { $bytes.Add($b) }
    $ms = New-Object System.IO.MemoryStream(,$bytes.ToArray())
    try { $r = [CfaGkgByteScanner]::Scan($ms,27,23,[int[]]@(0,1,3,4,23),50) }
    finally { $ms.Dispose() }
    if ($r.Rows -ne 4) { throw 'Self-test failed: row count.' }
    if ($r.InvalidUtf8Rows -ne 2) { throw 'Self-test failed: invalid UTF-8 row count.' }
    if ($r.AllNamesInvalidUtf8Rows -ne 1) { throw 'Self-test failed: ALLNAMES invalid count.' }
    if ($r.CriticalFieldInvalidUtf8Rows -ne 1) { throw 'Self-test failed: critical invalid count.' }
    if ($r.MalformedFieldCountRows -ne 1) { throw 'Self-test failed: malformed field count.' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $ArchiveRoot = Join-Path $docs 'CFA-local\gdelt-gkg-q2-2025' }
    if ([string]::IsNullOrWhiteSpace($AliasEvidenceRoot)) { $AliasEvidenceRoot = Join-Path $docs 'CFA-local\gdelt-alias-validation' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $docs 'CFA-local\gdelt-alias-diagnostics' }
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $AliasEvidenceRoot = (Resolve-Path -LiteralPath $AliasEvidenceRoot).ProviderPath
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }

    $aliasRun = Get-LatestAliasRun -Parent $AliasEvidenceRoot
    $scanRows = @(Import-Csv -LiteralPath (Join-Path $aliasRun.FullName 'archive-scan.csv'))
    $issueRows = @($scanRows | Where-Object { [string]$_.utf8_status -ne 'PASS' -or [long]$_.malformed_field_count_rows -gt 0 -or [string]$_.entry_count_status -ne 'PASS' })
    if ($issueRows.Count -eq 0) { throw 'Latest alias validation has no recorded parser/encoding issues to diagnose.' }

    $rawFiles = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip')) {
        if ($rawFiles.ContainsKey($file.Name)) { throw "Duplicate raw archive filename: $($file.Name)" }
        $rawFiles[$file.Name] = $file.FullName
    }

    $archiveDiagnostics = @()
    $detailRows = @()
    $sequenceCounts = @{}
    $totalRows = 0L; $totalMalformed = 0L; $totalInvalidRows = 0L; $totalInvalidFields = 0L; $totalAllNamesInvalid = 0L; $totalCriticalInvalid = 0L
    $ordinal = 0
    foreach ($issue in $issueRows) {
        $ordinal++
        $name = [string]$issue.archive_file
        if (-not $rawFiles.ContainsKey($name)) { throw "Raw archive missing for diagnostic: $name" }
        if (($ordinal % 25) -eq 0 -or $ordinal -eq 1) { Write-Host ("Diagnostic archives: {0}/{1}" -f $ordinal,$issueRows.Count) }
        $path = [string]$rawFiles[$name]
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
            $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
            if ($entries.Count -ne 1) {
                $archiveDiagnostics += [pscustomobject]@{archive_file=$name;archive_sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();entry_count=$entries.Count;rows_scanned=0;malformed_field_count_rows=0;strict_utf8_invalid_rows=0;strict_utf8_invalid_fields=0;allnames_utf8_invalid_rows=0;critical_field_utf8_invalid_rows=0;noncritical_only_utf8_invalid_rows=0;field_count_distribution='';status='FAIL_ENTRY_COUNT'}
                continue
            }
            $stream = $entries[0].Open()
            try { $r = [CfaGkgByteScanner]::Scan($stream,27,23,[int[]]@(0,1,3,4,23),$MaxDetailRowsPerArchive) }
            finally { $stream.Dispose() }

            $fieldParts = @()
            foreach ($k in @($r.FieldCountDistribution.Keys | Sort-Object)) { $fieldParts += (([string]$k) + ':' + ([string]$r.FieldCountDistribution[$k])) }
            $noncritical = [long]$r.InvalidUtf8Rows - [long]$r.CriticalFieldInvalidUtf8Rows
            $status = 'PASS_NONCRITICAL_UTF8_ONLY'
            if ([long]$r.MalformedFieldCountRows -gt 0) { $status = 'FAIL_RAW_FIELD_COUNT' }
            if ([long]$r.CriticalFieldInvalidUtf8Rows -gt 0) { $status = 'FAIL_CRITICAL_FIELD_UTF8' }
            $archiveDiagnostics += [pscustomobject]@{archive_file=$name;archive_sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();entry_count=$entries.Count;rows_scanned=[long]$r.Rows;malformed_field_count_rows=[long]$r.MalformedFieldCountRows;strict_utf8_invalid_rows=[long]$r.InvalidUtf8Rows;strict_utf8_invalid_fields=[long]$r.InvalidUtf8Fields;allnames_utf8_invalid_rows=[long]$r.AllNamesInvalidUtf8Rows;critical_field_utf8_invalid_rows=[long]$r.CriticalFieldInvalidUtf8Rows;noncritical_only_utf8_invalid_rows=$noncritical;field_count_distribution=($fieldParts -join '|');status=$status}

            foreach ($d in $r.Details) {
                $detailRows += [pscustomobject]@{archive_file=$name;row_ordinal=[long]$d.RowOrdinal;field_count=[int]$d.FieldCount;invalid_utf8=[bool]$d.InvalidUtf8;invalid_field_indexes_1_based=[string]$d.InvalidFieldIndexes1Based;allnames_invalid_utf8=[bool]$d.AllNamesInvalidUtf8;critical_field_invalid_utf8=[bool]$d.CriticalFieldInvalidUtf8;first_invalid_sequence_hex=[string]$d.FirstInvalidSequenceHex;raw_line_sha256=[string]$d.RawLineSha256}
            }
            foreach ($key in $r.InvalidSequenceDistribution.Keys) {
                if (-not $sequenceCounts.ContainsKey($key)) { $sequenceCounts[$key] = 0L }
                $sequenceCounts[$key] = [long]$sequenceCounts[$key] + [long]$r.InvalidSequenceDistribution[$key]
            }
            $totalRows += [long]$r.Rows; $totalMalformed += [long]$r.MalformedFieldCountRows; $totalInvalidRows += [long]$r.InvalidUtf8Rows; $totalInvalidFields += [long]$r.InvalidUtf8Fields; $totalAllNamesInvalid += [long]$r.AllNamesInvalidUtf8Rows; $totalCriticalInvalid += [long]$r.CriticalFieldInvalidUtf8Rows
        }
        finally { if ($null -ne $zip) { $zip.Dispose() } }
    }

    $sequenceRows = @()
    foreach ($key in @($sequenceCounts.Keys | Sort-Object)) { $sequenceRows += [pscustomobject]@{invalid_sequence_hex=$key;occurrence_count=[long]$sequenceCounts[$key]} }
    $candidateRecovery = if ($totalMalformed -eq 0 -and $totalCriticalInvalid -eq 0) { 'PASS_FIELDWISE_STRICT_UTF8_RECOVERY_CANDIDATE' } else { 'BLOCKED_BY_CRITICAL_OR_STRUCTURAL_FAILURES' }

    $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $runDir = Join-Path $OutputRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $archiveDiagnostics | Sort-Object archive_file | Export-Csv -LiteralPath (Join-Path $runDir 'archive-diagnostics.csv') -NoTypeInformation -Encoding UTF8
    $detailRows | Sort-Object archive_file,row_ordinal | Export-Csv -LiteralPath (Join-Path $runDir 'row-diagnostics.csv') -NoTypeInformation -Encoding UTF8
    $sequenceRows | Sort-Object @{Expression='occurrence_count';Descending=$true},invalid_sequence_hex | Export-Csv -LiteralPath (Join-Path $runDir 'invalid-sequence-summary.csv') -NoTypeInformation -Encoding UTF8
    @([pscustomobject]@{run_id=$runId;source_alias_validation_run=$aliasRun.Name;issue_archives=$issueRows.Count;diagnostic_rows_scanned=$totalRows;raw_malformed_field_count_rows=$totalMalformed;strict_utf8_invalid_rows=$totalInvalidRows;strict_utf8_invalid_fields=$totalInvalidFields;allnames_utf8_invalid_rows=$totalAllNamesInvalid;critical_field_utf8_invalid_rows=$totalCriticalInvalid;noncritical_only_utf8_invalid_rows=($totalInvalidRows-$totalCriticalInvalid);fieldwise_recovery_candidate=$candidateRecovery}) | Export-Csv -LiteralPath (Join-Path $runDir 'diagnostic-summary.csv') -NoTypeInformation -Encoding UTF8

    Write-Host "Evidence directory: $runDir"
    Write-Host "Issue archives diagnosed: $($issueRows.Count)"
    Write-Host "Raw malformed field-count rows: $totalMalformed"
    Write-Host "Strict UTF-8 invalid rows: $totalInvalidRows"
    Write-Host "ALLNAMES UTF-8 invalid rows: $totalAllNamesInvalid"
    Write-Host "Critical-field UTF-8 invalid rows: $totalCriticalInvalid"
    Write-Host "Fieldwise recovery candidate: $candidateRecovery"
    Write-Host 'CFA STAGE 2 ALIAS BYTE DIAGNOSTICS: PASS'
}
catch {
    Write-Host 'CFA STAGE 2 ALIAS BYTE DIAGNOSTICS: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
