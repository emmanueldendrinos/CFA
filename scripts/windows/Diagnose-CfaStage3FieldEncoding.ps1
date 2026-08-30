#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ArchiveRoot = 'D:\CFA-bulk\source\gdelt-gkg-q2-2025',
    [Parameter(Mandatory=$true)][string]$ArchiveScanCsv,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [ValidateRange(1,500)][int]$MaxDetailRowsPerArchive = 50,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedArchives = 7163
$ExpectedMalformedRows = 5L
$CriticalIndexes0Based = [int[]]@(0,1,3,4,8,12,14,23,26)

$scannerSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public sealed class CfaS3Utf8Result {
 public long Rows; public long Malformed; public long InvalidRows; public long InvalidFields; public long CriticalInvalidRows;
 public Dictionary<int,long> InvalidByField = new Dictionary<int,long>();
}
public static class CfaS3Utf8Scanner {
 private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false,true);
 private static bool Contains(int[] xs,int x){if(xs==null)return false;for(int i=0;i<xs.Length;i++)if(xs[i]==x)return true;return false;}
 public static CfaS3Utf8Result Scan(Stream stream,int expected,int[] critical){
  CfaS3Utf8Result r=new CfaS3Utf8Result();byte[] chunk=new byte[65536];using(MemoryStream line=new MemoryStream(65536)){
   int read;while((read=stream.Read(chunk,0,chunk.Length))>0){int start=0;for(int i=0;i<read;i++){if(chunk[i]==10){if(i>start)line.Write(chunk,start,i-start);Process(line.ToArray(),expected,critical,r);line.SetLength(0);start=i+1;}}if(start<read)line.Write(chunk,start,read-start);}if(line.Length>0)Process(line.ToArray(),expected,critical,r);
  }return r;
 }
 private static void Process(byte[] raw,int expected,int[] critical,CfaS3Utf8Result r){int len=raw.Length;if(len>0&&raw[len-1]==13)len--;r.Rows++;List<int> starts=new List<int>();List<int> lens=new List<int>();int s=0;for(int i=0;i<len;i++){if(raw[i]==9){starts.Add(s);lens.Add(i-s);s=i+1;}}starts.Add(s);lens.Add(len-s);if(starts.Count!=expected)r.Malformed++;bool invalid=false;bool criticalInvalid=false;for(int f=0;f<starts.Count;f++){try{StrictUtf8.GetString(raw,starts[f],lens[f]);}catch(DecoderFallbackException){invalid=true;r.InvalidFields++;long n=0;if(r.InvalidByField.TryGetValue(f,out n)){}r.InvalidByField[f]=n+1;if(Contains(critical,f))criticalInvalid=true;}}if(invalid)r.InvalidRows++;if(criticalInvalid)r.CriticalInvalidRows++;}
}
'@
if (-not ('CfaS3Utf8Scanner' -as [type])) { Add-Type -TypeDefinition $scannerSource -Language CSharp }

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $p = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Get-Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Invoke-SelfTest {
    function New-LineBytes([int]$InvalidIndex,[int]$FieldCount) {
        $bytes = New-Object 'Collections.Generic.List[byte]'
        for ($i=0; $i -lt $FieldCount; $i++) {
            if ($i -gt 0) { $bytes.Add([byte]9) }
            foreach ($b in [Text.Encoding]::ASCII.GetBytes('f' + $i)) { $bytes.Add($b) }
            if ($i -eq $InvalidIndex) { $bytes.Add([byte]0xE6) }
        }
        $bytes.Add([byte]10)
        return $bytes.ToArray()
    }
    $all = New-Object 'Collections.Generic.List[byte]'
    foreach ($idx in @(-1,8,10,26)) { foreach ($b in (New-LineBytes $idx 27)) { $all.Add($b) } }
    foreach ($b in (New-LineBytes -1 28)) { $all.Add($b) }
    $ms = New-Object IO.MemoryStream(,$all.ToArray())
    try { $r = [CfaS3Utf8Scanner]::Scan($ms,27,$CriticalIndexes0Based) } finally { $ms.Dispose() }
    if ($r.Rows -ne 5) { throw 'row count' }
    if ($r.InvalidRows -ne 3) { throw 'invalid row count' }
    if ($r.CriticalInvalidRows -ne 2) { throw 'Stage 3 critical field UTF-8 detection' }
    if ($r.Malformed -ne 1) { throw 'malformed field detection' }
    Write-Host 'SELF-TEST: PASS'
}
if ($SelfTest) { try { Invoke-SelfTest; exit 0 } catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 } }

try {
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $ArchiveScanCsv = (Resolve-Path -LiteralPath $ArchiveScanCsv).ProviderPath
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    $scan = @(Import-Csv -LiteralPath $ArchiveScanCsv)
    if ($scan.Count -ne $ExpectedArchives) { throw "Archive scan contains $($scan.Count) rows; expected $ExpectedArchives." }
    $props = @($scan[0].PSObject.Properties.Name)
    foreach ($name in @('archive_file','utf8_status','malformed_field_count_rows','entry_count_status')) { if ($props -notcontains $name) { throw "Archive scan missing column: $name" } }

    $scanNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $scan) {
        if (-not $scanNames.Add(([string]$r.archive_file).Trim())) { throw "Duplicate archive in archive scan: $($r.archive_file)" }
    }
    $issue = @($scan | Where-Object { ([string]$_.utf8_status).Trim() -ne 'PASS' -or [long]$_.malformed_field_count_rows -gt 0 -or ([string]$_.entry_count_status).Trim() -ne 'PASS' })
    if ($issue.Count -eq 0) { throw 'Archive scan records no encoding or structural issue archives; expected prior Stage 2 diagnostics to identify the bounded issue set.' }

    $files = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip')) {
        if ($f.Name -match '^\d{14}\.gkg\.csv\.zip$') {
            if ($files.ContainsKey($f.Name)) { throw "Duplicate current source archive: $($f.Name)" }
            $files[$f.Name] = $f.FullName
        }
    }
    if ($files.Count -ne $ExpectedArchives) { throw "Current Stage 3 source contains $($files.Count) archives; expected $ExpectedArchives." }
    foreach ($name in $scanNames) { if (-not $files.ContainsKey($name)) { throw "Archive-scan source not present in current Stage 3 corpus: $name" } }

    $rows = New-Object System.Collections.ArrayList
    [long]$totalRows=0; [long]$totalMalformed=0; [long]$totalInvalid=0; [long]$totalCritical=0
    $fieldCounts=@{}; $ordinal=0
    foreach ($src in $issue) {
        $ordinal++
        $name = ([string]$src.archive_file).Trim()
        if (($ordinal % 25) -eq 0 -or $ordinal -eq 1) { Write-Host ("Stage 3 encoding audit archives: {0}/{1}" -f $ordinal,$issue.Count) }
        $path = [string]$files[$name]
        if ($props -contains 'archive_sha256' -and -not [string]::IsNullOrWhiteSpace([string]$src.archive_sha256)) {
            if ((Get-Sha $path) -ne ([string]$src.archive_sha256).Trim().ToLowerInvariant()) { throw "Current source hash differs from Stage 2 archive-scan evidence: $name" }
        }
        $zip = $null
        try {
            $zip = [IO.Compression.ZipFile]::OpenRead($path)
            $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
            if ($entries.Count -ne 1) { throw "Issue archive has $($entries.Count) data entries: $name" }
            $stream = $entries[0].Open()
            try { $r = [CfaS3Utf8Scanner]::Scan($stream,27,$CriticalIndexes0Based) } finally { $stream.Dispose() }
            $totalRows += [long]$r.Rows; $totalMalformed += [long]$r.Malformed; $totalInvalid += [long]$r.InvalidRows; $totalCritical += [long]$r.CriticalInvalidRows
            foreach ($k in $r.InvalidByField.Keys) {
                if (-not $fieldCounts.ContainsKey([int]$k)) { $fieldCounts[[int]$k] = 0L }
                $fieldCounts[[int]$k] = [long]$fieldCounts[[int]$k] + [long]$r.InvalidByField[$k]
            }
            [void]$rows.Add([pscustomobject]@{
                archive_file=$name; archive_sha256=(Get-Sha $path); rows_scanned=[long]$r.Rows; malformed_field_count_rows=[long]$r.Malformed
                strict_utf8_invalid_rows=[long]$r.InvalidRows; stage3_critical_field_utf8_invalid_rows=[long]$r.CriticalInvalidRows
                status=if ([long]$r.CriticalInvalidRows -eq 0) {'PASS_NO_STAGE3_CRITICAL_UTF8'} else {'FAIL_STAGE3_CRITICAL_UTF8'}
            })
        }
        finally { if ($null -ne $zip) { $zip.Dispose() } }
    }

    $fieldRows = New-Object System.Collections.ArrayList
    foreach ($k in @($fieldCounts.Keys | Sort-Object)) {
        [void]$fieldRows.Add([pscustomobject]@{field_index_0_based=[int]$k;field_index_1_based=([int]$k+1);invalid_field_occurrences=[long]$fieldCounts[$k];stage3_critical=($CriticalIndexes0Based -contains [int]$k)})
    }
    $gate = if ($totalCritical -eq 0 -and $totalMalformed -eq $ExpectedMalformedRows) {'PASS'} else {'FAIL'}
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $runDir = Join-Path $OutputRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    @($rows.ToArray()) | Export-Csv -LiteralPath (Join-Path $runDir 'stage3-encoding-archive-audit.csv') -NoTypeInformation -Encoding UTF8
    @($fieldRows.ToArray()) | Export-Csv -LiteralPath (Join-Path $runDir 'stage3-encoding-field-summary.csv') -NoTypeInformation -Encoding UTF8
    $summary=[ordered]@{
        status=$gate;source_archive_root=$ArchiveRoot;source_archive_count=$files.Count;source_archive_scan_csv=$ArchiveScanCsv;source_archive_scan_sha256=(Get-Sha $ArchiveScanCsv)
        archive_scan_rows=$scan.Count;issue_archives_scanned=$issue.Count;issue_archive_rows_scanned=$totalRows;known_malformed_rows=$totalMalformed;strict_utf8_invalid_rows=$totalInvalid
        stage3_critical_indexes_0_based=(@($CriticalIndexes0Based) -join '|');stage3_critical_field_utf8_invalid_rows=$totalCritical
        rule='Fields used by Stage 3 matcher must be strict UTF-8: record/date/source/document/themes/persons/organizations/allnames/extras (0,1,3,4,8,12,14,23,26). Known five malformed rows remain excluded by the frozen V2 source-shape gate.'
        gate_CFA_S3F_008=$gate
    }
    Write-Utf8NoBom (Join-Path $runDir 'stage3-encoding-summary.json') (($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine)
    Write-Host ''
    Write-Host ("CFA STAGE 3 CRITICAL-FIELD UTF-8 AUDIT: {0}" -f $gate)
    Write-Host ("Issue archives scanned: {0}" -f $issue.Count)
    Write-Host ("Strict UTF-8 invalid rows in issue set: {0}" -f $totalInvalid)
    Write-Host ("Stage 3 critical-field invalid rows: {0}" -f $totalCritical)
    Write-Host ("Known malformed rows: {0}" -f $totalMalformed)
    Write-Host ("Evidence directory: {0}" -f $runDir)
    if ($gate -ne 'PASS') { exit 2 }
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 CRITICAL-FIELD UTF-8 AUDIT: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
