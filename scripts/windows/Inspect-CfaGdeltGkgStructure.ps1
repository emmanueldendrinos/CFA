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
    param([System.IO.Stream]$Stream,[int]$MaxRows)
    $counts=@{};$sampled=0;$utf8Valid=0;$utf8Invalid=0;$crlf=0;$lfOnly=0;$maxBytes=0
    $utf8 = New-Object System.Text.UTF8Encoding($false,$true)
    $buffer = New-Object System.Collections.Generic.List[byte]
    $reader = New-Object System.IO.BinaryReader($Stream)
    try {
        while($sampled -lt $MaxRows -and $Stream.Position -lt $Stream.Length){
            $b=$reader.ReadByte()
            if($b -eq 10){
                $bytes=$buffer.ToArray();$buffer.Clear();$sampled++
                if($bytes.Length -gt $maxBytes){$maxBytes=$bytes.Length}
                $end=$bytes.Length
                if($end -gt 0 -and $bytes[$end-1] -eq 13){$crlf++;$end--}else{$lfOnly++}
                $tabs=0;for($i=0;$i -lt $end;$i++){if($bytes[$i] -eq 9){$tabs++}}
                $fields=$tabs+1
                if(-not $counts.ContainsKey($fields)){$counts[$fields]=0};$counts[$fields]=[int]$counts[$fields]+1
                try{[void]$utf8.GetString($bytes,0,$end);$utf8Valid++}catch{$utf8Invalid++}
            } else {
                $buffer.Add($b)
            }
        }
        if($sampled -lt $MaxRows -and $buffer.Count -gt 0){
            $bytes=$buffer.ToArray();$sampled++
            if($bytes.Length -gt $maxBytes){$maxBytes=$bytes.Length}
            $tabs=0;for($i=0;$i -lt $bytes.Length;$i++){if($bytes[$i] -eq 9){$tabs++}}
            $fields=$tabs+1;if(-not $counts.ContainsKey($fields)){$counts[$fields]=0};$counts[$fields]=[int]$counts[$fields]+1
            try{[void]$utf8.GetString($bytes);$utf8Valid++}catch{$utf8Invalid++}
        }
    }
    finally{$reader.Dispose()}
    return [pscustomobject]@{sampled_rows=$sampled;field_counts=$counts;utf8_valid_rows=$utf8Valid;utf8_invalid_rows=$utf8Invalid;crlf_rows=$crlf;lf_only_rows=$lfOnly;max_line_bytes=$maxBytes}
}

function Inspect-Archives {
    param([string[]]$Paths,[int]$Rows)
    $archiveRows=@();$distribution=@()
    foreach($path in $Paths){
        $file=Get-Item -LiteralPath $path
        $zip=$null
        try{
            $zip=[System.IO.Compression.ZipFile]::OpenRead($file.FullName)
            $entries=@($zip.Entries | Where-Object {-not [string]::IsNullOrWhiteSpace($_.Name)})
            if($entries.Count -lt 1){throw "ZIP contains no file entries: $($file.Name)"}
            $entry=$entries[0]
            $stream=$entry.Open()
            try{$m=Get-LineMetrics -Stream $stream -MaxRows $Rows}finally{$stream.Dispose()}
            $keys=@($m.field_counts.Keys | Sort-Object {[int]$_})
            foreach($k in $keys){$distribution += [pscustomobject]@{archive_file=$file.Name;entry_name=$entry.FullName;field_count=[int]$k;sampled_rows=[int]$m.field_counts[$k]}}
            $objectKey=[regex]::Match($file.Name,'^(\d{14})').Groups[1].Value
            $archiveRows += [pscustomobject]@{
                object_key=$objectKey;archive_file=$file.Name;archive_sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();archive_bytes=[long]$file.Length;
                zip_entry_count=$entries.Count;inspected_entry=$entry.FullName;entry_uncompressed_bytes=[long]$entry.Length;entry_compressed_bytes=[long]$entry.CompressedLength;
                sampled_rows=[int]$m.sampled_rows;distinct_field_counts=($keys -join '|');min_field_count=if($keys.Count){[int]$keys[0]}else{0};max_field_count=if($keys.Count){[int]$keys[$keys.Count-1]}else{0};
                utf8_valid_rows=[int]$m.utf8_valid_rows;utf8_invalid_rows=[int]$m.utf8_invalid_rows;crlf_rows=[int]$m.crlf_rows;lf_only_rows=[int]$m.lf_only_rows;max_line_bytes=[int]$m.max_line_bytes
            }
        } finally {if($null -ne $zip){$zip.Dispose()}}
    }
    return [pscustomobject]@{archives=$archiveRows;distribution=$distribution}
}

function Invoke-SelfTest {
    $root=Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gkg-structure-'+[guid]::NewGuid().ToString('N'))
    try{
        New-Item -ItemType Directory -Path $root -Force|Out-Null
        $paths=@()
        foreach($key in @('20250401000000','20250515000000','20250630234500')){
            $path=Join-Path $root ($key+'.gkg.csv.zip');$paths+=$path
            $zip=[System.IO.Compression.ZipFile]::Open($path,[System.IO.Compression.ZipArchiveMode]::Create)
            try{$e=$zip.CreateEntry('sample.gkg.csv');$w=New-Object System.IO.StreamWriter($e.Open(),(New-Object System.Text.UTF8Encoding($false)));try{$w.Write("a`t1`tx`n"+"b`t2`ty`n")}finally{$w.Dispose()}}finally{$zip.Dispose()}
        }
        $r=Inspect-Archives -Paths $paths -Rows 10
        if($r.archives.Count -ne 3){throw 'archive count'}
        if(@($r.archives|Where-Object{$_.min_field_count -ne 3 -or $_.max_field_count -ne 3}).Count -ne 0){throw 'field count'}
        if(@($r.archives|Where-Object{$_.utf8_invalid_rows -ne 0}).Count -ne 0){throw 'utf8'}
        Write-Host 'SELF-TEST: PASS'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
    $docs=[Environment]::GetFolderPath('MyDocuments')
    if([string]::IsNullOrWhiteSpace($ArchiveRoot)){$ArchiveRoot=Join-Path $docs 'CFA-local\gdelt-gkg-q2-2025'}
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path $docs 'CFA-local\gdelt-gkg-structure'}
    $ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if(-not (Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $files=@(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip' | Where-Object {$_.Name -match '^\d{14}\.gkg\.csv\.zip$'} | Sort-Object Name)
    if($files.Count -lt 3){throw "At least three downloaded GKG archives are required; observed $($files.Count)."}
    $indexes=@(0,[int][Math]::Floor(($files.Count-1)/2),$files.Count-1)|Sort-Object -Unique
    $selected=@();foreach($i in $indexes){$selected+=$files[$i].FullName}
    if($selected.Count -ne 3){throw 'Could not select three distinct early/middle/late archives.'}
    $result=Inspect-Archives -Paths $selected -Rows $RowsPerArchive
    $runId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N');$runDir=Join-Path $OutputRoot $runId;New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $result.archives|Export-Csv -LiteralPath (Join-Path $runDir 'archive-structure.csv') -NoTypeInformation -Encoding UTF8
    $result.distribution|Export-Csv -LiteralPath (Join-Path $runDir 'field-count-distribution.csv') -NoTypeInformation -Encoding UTF8
    @([pscustomobject]@{run_id=$runId;downloaded_archive_files=$files.Count;selected_archives=$selected.Count;rows_per_archive_limit=$RowsPerArchive;total_sampled_rows=(@($result.archives|Measure-Object sampled_rows -Sum).Sum);total_utf8_invalid_rows=(@($result.archives|Measure-Object utf8_invalid_rows -Sum).Sum)})|Export-Csv -LiteralPath (Join-Path $runDir 'inspection-summary.csv') -NoTypeInformation -Encoding UTF8
    Write-Host "Evidence directory: $runDir"
    $result.archives|Format-Table object_key,sampled_rows,min_field_count,max_field_count,utf8_valid_rows,utf8_invalid_rows -AutoSize
    Write-Host 'CFA GDELT GKG STRUCTURE INSPECTION: PASS'
}catch{Write-Host 'CFA GDELT GKG STRUCTURE INSPECTION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
