#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ArchiveRoot = 'D:\CFA-bulk\source\gdelt-gkg-q2-2025',
    [Parameter(Mandatory=$true)][string]$ArchiveScanCsv,
    [Parameter(Mandatory=$true)][string]$Stage3V2RunRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedArchives = 7163
$ExpectedRows = 9183757L
$ExpectedMalformedRows = 5L
$ExpectedIssueArchives = 139
$ExpectedCriticalInvalidRows = 126L
$ExpectedArchiveScanSha256 = '1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba'
$CriticalIndexes0Based = [int[]]@(0,1,3,4,8,12,14,23,26)

$scannerSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public sealed class CfaS3ImpactRow {
    public long RowOrdinal { get; set; }
    public int FieldCount { get; set; }
    public string InvalidFields0Based { get; set; }
    public string CriticalInvalidFields0Based { get; set; }
    public string RawLineSha256 { get; set; }
    public string RecordIdLenient { get; set; }
    public string DateLenient { get; set; }
    public string SourceLenient { get; set; }
    public string DocumentLenient { get; set; }
}

public sealed class CfaS3ImpactResult {
    public long Rows { get; set; }
    public long Malformed { get; set; }
    public long InvalidRows { get; set; }
    public long CriticalInvalidRows { get; set; }
    public Dictionary<int,long> InvalidByField { get; set; }
    public List<CfaS3ImpactRow> CriticalRows { get; set; }
    public CfaS3ImpactResult() {
        InvalidByField = new Dictionary<int,long>();
        CriticalRows = new List<CfaS3ImpactRow>();
    }
}

public static class CfaS3ImpactScanner {
    private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false,true);
    private static readonly UTF8Encoding LenientUtf8 = new UTF8Encoding(false,false);

    private static bool Contains(int[] values,int value) {
        if (values == null) return false;
        for (int i=0;i<values.Length;i++) if (values[i] == value) return true;
        return false;
    }
    private static string JoinInts(List<int> values) {
        if (values == null || values.Count == 0) return "";
        return String.Join("|", values.ToArray());
    }
    private static string Sha256(byte[] bytes,int length) {
        using (SHA256 sha = SHA256.Create()) {
            byte[] hash = sha.ComputeHash(bytes,0,length);
            StringBuilder sb = new StringBuilder(hash.Length * 2);
            for (int i=0;i<hash.Length;i++) sb.Append(hash[i].ToString("x2"));
            return sb.ToString();
        }
    }
    private static string DecodeField(byte[] raw,List<int> starts,List<int> lengths,int index) {
        if (index < 0 || index >= starts.Count) return "";
        return LenientUtf8.GetString(raw,starts[index],lengths[index]);
    }
    private static void Process(byte[] raw,int expected,int[] critical,CfaS3ImpactResult result) {
        int len = raw.Length;
        if (len > 0 && raw[len-1] == 13) len--;
        result.Rows++;
        List<int> starts = new List<int>();
        List<int> lengths = new List<int>();
        int start = 0;
        for (int i=0;i<len;i++) {
            if (raw[i] == 9) {
                starts.Add(start); lengths.Add(i-start); start=i+1;
            }
        }
        starts.Add(start); lengths.Add(len-start);
        if (starts.Count != expected) result.Malformed++;

        List<int> invalid = new List<int>();
        List<int> criticalInvalid = new List<int>();
        for (int field=0;field<starts.Count;field++) {
            try { StrictUtf8.GetString(raw,starts[field],lengths[field]); }
            catch (DecoderFallbackException) {
                invalid.Add(field);
                long n=0; result.InvalidByField.TryGetValue(field,out n); result.InvalidByField[field]=n+1;
                if (Contains(critical,field)) criticalInvalid.Add(field);
            }
        }
        if (invalid.Count > 0) result.InvalidRows++;
        if (criticalInvalid.Count > 0) {
            result.CriticalInvalidRows++;
            CfaS3ImpactRow row = new CfaS3ImpactRow();
            row.RowOrdinal = result.Rows;
            row.FieldCount = starts.Count;
            row.InvalidFields0Based = JoinInts(invalid);
            row.CriticalInvalidFields0Based = JoinInts(criticalInvalid);
            row.RawLineSha256 = Sha256(raw,len);
            row.RecordIdLenient = DecodeField(raw,starts,lengths,0);
            row.DateLenient = DecodeField(raw,starts,lengths,1);
            row.SourceLenient = DecodeField(raw,starts,lengths,3);
            row.DocumentLenient = DecodeField(raw,starts,lengths,4);
            result.CriticalRows.Add(row);
        }
    }
    public static CfaS3ImpactResult Scan(Stream stream,int expected,int[] critical) {
        CfaS3ImpactResult result = new CfaS3ImpactResult();
        byte[] chunk = new byte[65536];
        using (MemoryStream line = new MemoryStream(65536)) {
            int read;
            while ((read = stream.Read(chunk,0,chunk.Length)) > 0) {
                int segmentStart=0;
                for (int i=0;i<read;i++) {
                    if (chunk[i] == 10) {
                        if (i > segmentStart) line.Write(chunk,segmentStart,i-segmentStart);
                        Process(line.ToArray(),expected,critical,result);
                        line.SetLength(0);
                        segmentStart=i+1;
                    }
                }
                if (segmentStart < read) line.Write(chunk,segmentStart,read-segmentStart);
            }
            if (line.Length > 0) Process(line.ToArray(),expected,critical,result);
        }
        return result;
    }
}
'@
if (-not ('CfaS3ImpactScanner' -as [type])) { Add-Type -TypeDefinition $scannerSource -Language CSharp }

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Get-Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Row-Key { param([string]$Archive,[object]$Ordinal); return $Archive.Trim().ToLowerInvariant() + '|' + ([long]$Ordinal).ToString() }
function Identity-Key { param([object]$Record,[object]$Date,[object]$Source,[object]$Document); return ([string]$Record) + '|' + ([string]$Date) + '|' + ([string]$Source) + '|' + ([string]$Document) }

function Assert-ParentV2 {
    param([string]$RunRoot)
    $summaryPath=Join-Path $RunRoot 'stage3-match-summary.json'
    $matchPath=Join-Path $RunRoot 'stage3-news-matches.csv'
    $rejectPath=Join-Path $RunRoot 'stage3-context-rejects.csv'
    $samplePath=Join-Path $RunRoot 'stage3-match-samples.csv'
    foreach($p in @($summaryPath,$matchPath,$rejectPath,$samplePath)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Required V2 artifact missing: $p"}}
    $s=Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if([string]$s.run_status -ne 'PASS' -or [string]$s.matching_contract -ne 'CANDIDATE_V2'){throw 'Parent V2 summary is not PASS CANDIDATE_V2.'}
    if([int]$s.source.archive_files -ne $ExpectedArchives -or [long]$s.source.rows_scanned -ne $ExpectedRows){throw 'Parent V2 source shape differs from frozen Stage 3 source.'}
    if([long]$s.source.malformed_field_count_rows -ne $ExpectedMalformedRows){throw 'Parent V2 malformed row count differs from frozen source.'}
    if((Get-Sha $matchPath) -ne ([string]$s.output.matches_sha256).ToLowerInvariant()){throw 'Parent V2 matches hash mismatch.'}
    if((Get-Sha $rejectPath) -ne ([string]$s.output.rejects_sha256).ToLowerInvariant()){throw 'Parent V2 rejects hash mismatch.'}
    if((Get-Sha $samplePath) -ne ([string]$s.output.samples_sha256).ToLowerInvariant()){throw 'Parent V2 samples hash mismatch.'}
    return [pscustomobject]@{summary=$s;summary_path=$summaryPath;match_path=$matchPath;reject_path=$rejectPath;sample_path=$samplePath}
}

function New-TestLineBytes {
    param([int]$FieldCount,[int]$InvalidField)
    $bytes=New-Object 'Collections.Generic.List[byte]'
    for($i=0;$i-lt$FieldCount;$i++){
        if($i-gt0){$bytes.Add([byte]9)}
        foreach($b in [Text.Encoding]::ASCII.GetBytes('f'+$i)){$bytes.Add($b)}
        if($i-eq$InvalidField){$bytes.Add([byte]0xE6)}
    }
    $bytes.Add([byte]10);return $bytes.ToArray()
}
function Invoke-SelfTest {
    $all=New-Object 'Collections.Generic.List[byte]'
    foreach($spec in @(@(27,-1),@(27,8),@(27,10),@(28,26))){foreach($b in (New-TestLineBytes -FieldCount $spec[0] -InvalidField $spec[1])){$all.Add($b)}}
    $ms=New-Object IO.MemoryStream(,$all.ToArray())
    try{$r=[CfaS3ImpactScanner]::Scan($ms,27,$CriticalIndexes0Based)}finally{$ms.Dispose()}
    if($r.Rows-ne4){throw 'Self-test row count.'}
    if($r.Malformed-ne1){throw 'Self-test malformed count.'}
    if($r.InvalidRows-ne3){throw 'Self-test invalid row count.'}
    if($r.CriticalInvalidRows-ne2){throw 'Self-test critical invalid row count.'}
    if($r.CriticalRows.Count-ne2){throw 'Self-test detail count.'}
    if([string]$r.CriticalRows[0].CriticalInvalidFields0Based -ne '8'){throw 'Self-test critical field detail.'}
    if((Row-Key 'A.zip' 7) -ne 'a.zip|7'){throw 'Self-test row key.'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try {
    $ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $ArchiveScanCsv=(Resolve-Path -LiteralPath $ArchiveScanCsv).ProviderPath
    $Stage3V2RunRoot=(Resolve-Path -LiteralPath $Stage3V2RunRoot).ProviderPath
    if((Get-Sha $ArchiveScanCsv) -ne $ExpectedArchiveScanSha256){throw 'Archive scan hash differs from frozen reproduced Stage 2 evidence.'}
    if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $OutputRoot=(Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    $parent=Assert-ParentV2 $Stage3V2RunRoot

    $scan=@(Import-Csv -LiteralPath $ArchiveScanCsv)
    if($scan.Count-ne$ExpectedArchives){throw "Archive scan rows $($scan.Count); expected $ExpectedArchives."}
    $props=@($scan[0].PSObject.Properties.Name)
    foreach($name in @('archive_file','utf8_status','malformed_field_count_rows','entry_count_status')){if($props-notcontains$name){throw "Archive scan missing column: $name"}}
    $issue=@($scan|Where-Object{([string]$_.utf8_status).Trim()-ne'PASS'-or[long]$_.malformed_field_count_rows-gt0-or([string]$_.entry_count_status).Trim()-ne'PASS'})
    if($issue.Count-ne$ExpectedIssueArchives){throw "Issue archive count $($issue.Count); expected $ExpectedIssueArchives."}

    $files=@{}
    foreach($f in @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip')){
        if($f.Name-match'^\d{14}\.gkg\.csv\.zip$'){
            if($files.ContainsKey($f.Name)){throw "Duplicate source archive filename: $($f.Name)"}
            $files[$f.Name]=$f.FullName
        }
    }
    if($files.Count-ne$ExpectedArchives){throw "Current source archive count $($files.Count); expected $ExpectedArchives."}

    $exclusions=New-Object System.Collections.ArrayList
    $exclusionByKey=@{};$identityToKeys=@{};$fieldCounts=@{};[long]$totalMalformed=0;[long]$totalCritical=0;$ordinal=0
    foreach($src in $issue){
        $ordinal++;$name=([string]$src.archive_file).Trim();if(-not$files.ContainsKey($name)){throw "Issue archive missing from current source: $name"}
        if($ordinal-eq1-or($ordinal%25)-eq0){Write-Host ("Critical UTF-8 impact archives: {0}/{1}" -f $ordinal,$issue.Count)}
        $path=[string]$files[$name];$archiveSha=Get-Sha $path;$zip=$null
        try{
            $zip=[IO.Compression.ZipFile]::OpenRead($path);$entries=@($zip.Entries|Where-Object{-not[string]::IsNullOrWhiteSpace($_.Name)})
            if($entries.Count-ne1){throw "Issue archive has $($entries.Count) data entries: $name"}
            $stream=$entries[0].Open();try{$r=[CfaS3ImpactScanner]::Scan($stream,27,$CriticalIndexes0Based)}finally{$stream.Dispose()}
            $totalMalformed += [long]$r.Malformed;$totalCritical += [long]$r.CriticalInvalidRows
            foreach($k in $r.InvalidByField.Keys){if(-not$fieldCounts.ContainsKey([int]$k)){$fieldCounts[[int]$k]=0L};$fieldCounts[[int]$k]=[long]$fieldCounts[[int]$k]+[long]$r.InvalidByField[$k]}
            foreach($d in $r.CriticalRows){
                $key=Row-Key $name $d.RowOrdinal;if($exclusionByKey.ContainsKey($key)){throw "Duplicate exclusion row key: $key"}
                $row=[pscustomobject][ordered]@{archive_file=$name;archive_sha256=$archiveSha;row_ordinal=[long]$d.RowOrdinal;field_count=[int]$d.FieldCount;malformed_field_count=([int]$d.FieldCount-ne27);invalid_fields_0_based=[string]$d.InvalidFields0Based;critical_invalid_fields_0_based=[string]$d.CriticalInvalidFields0Based;raw_line_sha256=[string]$d.RawLineSha256;record_id_lenient=[string]$d.RecordIdLenient;gdelt_date_utc_lenient=[string]$d.DateLenient;source_common_name_lenient=[string]$d.SourceLenient;document_identifier_lenient=[string]$d.DocumentLenient}
                $exclusionByKey[$key]=$row;[void]$exclusions.Add($row)
                $ik=Identity-Key $d.RecordIdLenient $d.DateLenient $d.SourceLenient $d.DocumentLenient;if(-not$identityToKeys.ContainsKey($ik)){$identityToKeys[$ik]=New-Object System.Collections.ArrayList};[void]$identityToKeys[$ik].Add($key)
            }
        }finally{if($null-ne$zip){$zip.Dispose()}}
    }
    if($totalMalformed-ne$ExpectedMalformedRows){throw "Observed malformed rows $totalMalformed; expected $ExpectedMalformedRows."}
    if($totalCritical-ne$ExpectedCriticalInvalidRows-or$exclusions.Count-ne$ExpectedCriticalInvalidRows){throw "Observed Stage 3 critical UTF-8 rows $($exclusions.Count); expected $ExpectedCriticalInvalidRows."}

    $matchOverlap=New-Object System.Collections.ArrayList
    foreach($r in @(Import-Csv -LiteralPath $parent.match_path)){
        $key=Row-Key ([string]$r.archive_file) $r.row_ordinal;if($exclusionByKey.ContainsKey($key)){$e=$exclusionByKey[$key];[void]$matchOverlap.Add([pscustomobject][ordered]@{archive_file=$e.archive_file;row_ordinal=$e.row_ordinal;raw_line_sha256=$e.raw_line_sha256;critical_invalid_fields_0_based=$e.critical_invalid_fields_0_based;base_asset_id=[string]$r.base_asset_id;record_id=[string]$r.record_id;gdelt_date_utc=[string]$r.gdelt_date_utc;source_common_name=[string]$r.source_common_name;document_identifier=[string]$r.document_identifier;matched_aliases=[string]$r.matched_aliases;matched_surfaces=[string]$r.matched_surfaces;context_reasons=[string]$r.context_reasons})}
    }
    $rejectOverlap=New-Object System.Collections.ArrayList
    foreach($r in @(Import-Csv -LiteralPath $parent.reject_path)){
        $key=Row-Key ([string]$r.archive_file) $r.row_ordinal;if($exclusionByKey.ContainsKey($key)){$e=$exclusionByKey[$key];[void]$rejectOverlap.Add([pscustomobject][ordered]@{archive_file=$e.archive_file;row_ordinal=$e.row_ordinal;raw_line_sha256=$e.raw_line_sha256;critical_invalid_fields_0_based=$e.critical_invalid_fields_0_based;base_asset_id=[string]$r.base_asset_id;alias_text=[string]$r.alias_text;record_id=[string]$r.record_id;gdelt_date_utc=[string]$r.gdelt_date_utc;source_common_name=[string]$r.source_common_name;document_identifier=[string]$r.document_identifier;matched_surfaces=[string]$r.matched_surfaces;context_reason=[string]$r.context_reason})}
    }
    $sampleOverlap=New-Object System.Collections.ArrayList;[long]$ambiguousSampleIdentity=0
    foreach($r in @(Import-Csv -LiteralPath $parent.sample_path)){
        $ik=Identity-Key $r.record_id $r.gdelt_date_utc $r.source_common_name $r.document_identifier
        if($identityToKeys.ContainsKey($ik)){
            $keys=@($identityToKeys[$ik].ToArray());if($keys.Count-ne1){$ambiguousSampleIdentity++}
            [void]$sampleOverlap.Add([pscustomobject][ordered]@{v2_match_status=[string]$r.match_status;base_asset_id=[string]$r.base_asset_id;alias_text=[string]$r.alias_text;record_id=[string]$r.record_id;gdelt_date_utc=[string]$r.gdelt_date_utc;source_common_name=[string]$r.source_common_name;document_identifier=[string]$r.document_identifier;matching_exclusion_row_keys=($keys-join';');identity_key_count=$keys.Count})
        }
    }

    $runId=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8);$runDir=Join-Path $OutputRoot $runId;New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $exclusionPath=Join-Path $runDir 'stage3-critical-utf8-exclusions.csv';$matchPath=Join-Path $runDir 'stage3-critical-utf8-v2-match-overlap.csv';$rejectPath=Join-Path $runDir 'stage3-critical-utf8-v2-reject-overlap.csv';$samplePath=Join-Path $runDir 'stage3-critical-utf8-v2-sample-overlap.csv';$fieldPath=Join-Path $runDir 'stage3-critical-utf8-field-summary.csv'
    @($exclusions.ToArray())|Sort-Object archive_file,row_ordinal|Export-Csv -LiteralPath $exclusionPath -NoTypeInformation -Encoding UTF8
    @($matchOverlap.ToArray())|Export-Csv -LiteralPath $matchPath -NoTypeInformation -Encoding UTF8
    @($rejectOverlap.ToArray())|Export-Csv -LiteralPath $rejectPath -NoTypeInformation -Encoding UTF8
    @($sampleOverlap.ToArray())|Export-Csv -LiteralPath $samplePath -NoTypeInformation -Encoding UTF8
    $fieldRows=New-Object System.Collections.ArrayList;foreach($k in @($fieldCounts.Keys|Sort-Object)){[void]$fieldRows.Add([pscustomobject]@{field_index_0_based=[int]$k;field_index_1_based=([int]$k+1);invalid_field_occurrences=[long]$fieldCounts[$k];stage3_critical=($CriticalIndexes0Based-contains[int]$k)})};@($fieldRows.ToArray())|Export-Csv -LiteralPath $fieldPath -NoTypeInformation -Encoding UTF8

    $summary=[ordered]@{status='PASS';stage='CFA_STAGE_3';diagnostic='CRITICAL_UTF8_V2_IMPACT';source_archive_root=$ArchiveRoot;archive_scan_csv=$ArchiveScanCsv;archive_scan_sha256=(Get-Sha $ArchiveScanCsv);parent_v2_run=$Stage3V2RunRoot;parent_v2_summary_sha256=(Get-Sha $parent.summary_path);issue_archives_scanned=$issue.Count;known_malformed_rows=$totalMalformed;critical_utf8_exclusion_rows=$exclusions.Count;v2_match_overlap_rows=$matchOverlap.Count;v2_reject_overlap_rows=$rejectOverlap.Count;v2_sample_overlap_rows=$sampleOverlap.Count;v2_sample_ambiguous_identity_rows=$ambiguousSampleIdentity;critical_indexes_0_based=(@($CriticalIndexes0Based)-join'|');outputs=[ordered]@{exclusions_csv=$exclusionPath;exclusions_sha256=(Get-Sha $exclusionPath);match_overlap_csv=$matchPath;match_overlap_sha256=(Get-Sha $matchPath);reject_overlap_csv=$rejectPath;reject_overlap_sha256=(Get-Sha $rejectPath);sample_overlap_csv=$samplePath;sample_overlap_sha256=(Get-Sha $samplePath);field_summary_csv=$fieldPath;field_summary_sha256=(Get-Sha $fieldPath)};gates=[ordered]@{'CFA-S3F-008'='FAIL';'CFA-S3F-011'='PASS';'CFA-S3F-012'='PASS';'CFA-S3F-013'='BLOCKED';'CFA-S3-006'='BLOCKED'};next_action='Define and validate a corrected matching candidate that excludes every manifest row before applying the short-default-symbol rule.'}
    $summaryPath=Join-Path $runDir 'stage3-critical-utf8-impact-summary.json';Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 8)+[Environment]::NewLine)
    Write-Host ''
    Write-Host 'CFA STAGE 3 CRITICAL UTF-8 IMPACT DIAGNOSTIC: PASS'
    Write-Host ("Critical UTF-8 exclusion rows: {0}" -f $exclusions.Count)
    Write-Host ("V2 match overlap rows: {0}" -f $matchOverlap.Count)
    Write-Host ("V2 reject overlap rows: {0}" -f $rejectOverlap.Count)
    Write-Host ("V2 sample overlap rows: {0}" -f $sampleOverlap.Count)
    Write-Host ("V2 sample ambiguous identity rows: {0}" -f $ambiguousSampleIdentity)
    Write-Host ("Evidence directory: {0}" -f $runDir)
    Write-Host ("Impact summary: {0}" -f $summaryPath)
    exit 0
}
catch{
    Write-Host ''
    Write-Host 'CFA STAGE 3 CRITICAL UTF-8 IMPACT DIAGNOSTIC: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
