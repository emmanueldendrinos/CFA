#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$SoTSnapshotJson = '',
    [string]$OutputMarkdown = '',
    [string]$OutputJson = '',
    [switch]$RepairExactEncodingVariant,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}

function Get-Sha256Bytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-StrictUtf8Text {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $enc = New-Object System.Text.UTF8Encoding($false,$true)
    $text = $enc.GetString($Bytes)
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function New-Variant {
    param([string]$Name,[string]$Text,[bool]$Bom)
    $enc = New-Object System.Text.UTF8Encoding($Bom)
    $payload = $enc.GetBytes($Text)
    if ($Bom) {
        $preamble = $enc.GetPreamble()
        $bytes = New-Object byte[] ($preamble.Length + $payload.Length)
        [Array]::Copy($preamble,0,$bytes,0,$preamble.Length)
        [Array]::Copy($payload,0,$bytes,$preamble.Length,$payload.Length)
    } else {
        $bytes = $payload
    }
    return [pscustomobject]@{ name=$Name; bytes=$bytes; size_bytes=[long]$bytes.Length; sha256=(Get-Sha256Bytes -Bytes $bytes) }
}

function Get-EncodingVariants {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $text = Get-StrictUtf8Text -Bytes $Bytes
    $lf = $text.Replace("`r`n","`n").Replace("`r","`n")
    $crlf = $lf.Replace("`n","`r`n")
    return @(
        (New-Variant -Name 'UTF8_LF_NO_BOM' -Text $lf -Bom $false),
        (New-Variant -Name 'UTF8_CRLF_NO_BOM' -Text $crlf -Bom $false),
        (New-Variant -Name 'UTF8_LF_BOM' -Text $lf -Bom $true),
        (New-Variant -Name 'UTF8_CRLF_BOM' -Text $crlf -Bom $true)
    )
}

function Get-CsvShape {
    param([Parameter(Mandatory)][string]$Path)
    $rows = @(Import-Csv -LiteralPath $Path)
    [int]$columns = 0
    if ($rows.Count -gt 0) { $columns = @($rows[0].PSObject.Properties).Count }
    return [pscustomobject]@{ data_rows=[long]$rows.Count; columns=$columns }
}

function Get-LineEndingSummary {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $text = Get-StrictUtf8Text -Bytes $Bytes
    $crlf = [regex]::Matches($text,"`r`n").Count
    $remaining = $text.Replace("`r`n",'')
    $lfOnly = [regex]::Matches($remaining,"`n").Count
    $crOnly = [regex]::Matches($remaining,"`r").Count
    $bom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    return [pscustomobject]@{ crlf=$crlf; lf_only=$lfOnly; cr_only=$crOnly; utf8_bom=$bom }
}

function Get-Registry {
    param([Parameter(Mandatory)][string]$SnapshotPath)
    $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    $sheets = @($snapshot.sheets | Where-Object { [string]$_.name -eq 'Analyzed Files' })
    if ($sheets.Count -ne 1) { throw "Expected one Analyzed Files sheet; observed $($sheets.Count)." }
    $registry = @()
    foreach ($row in $sheets[0].rows) {
        $v = @($row.values)
        if ($v.Count -lt 6) { continue }
        $id = [string]$v[0]
        if ($id -notmatch '^AF-00[1-3]$') { continue }
        $registry += ,([pscustomobject]@{
            source_id=$id
            file_name=[string]$v[1]
            expected_sha256=([string]$v[2]).ToLowerInvariant()
            expected_bytes=[long]$v[3]
            expected_data_rows=[long]$v[4]
            expected_columns=[int]$v[5]
            role=if($v.Count -gt 6){[string]$v[6]}else{''}
            authority=if($v.Count -gt 7){[string]$v[7]}else{''}
            boundary=if($v.Count -gt 8){[string]$v[8]}else{''}
        })
    }
    if ($registry.Count -ne 3) { throw "Expected AF-001, AF-002, AF-003; observed $($registry.Count) registry rows." }
    return $registry
}

function Resolve-SourceFile {
    param([Parameter(Mandatory)][string]$RepoRootPath,[Parameter(Mandatory)][string]$FileName)
    $folder = Join-Path $RepoRootPath 'candidate-analysis'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "candidate-analysis directory missing: $folder" }
    $matches = @(Get-ChildItem -LiteralPath $folder -File -Force | Where-Object { $_.Name -eq $FileName })
    if ($matches.Count -ne 1) { throw "Expected one candidate-analysis/$FileName; observed $($matches.Count)." }
    return $matches[0]
}

function Test-Source {
    param([Parameter(Mandatory)][object]$Registry,[Parameter(Mandatory)][string]$RepoRootPath,[bool]$Repair)
    $file = Resolve-SourceFile -RepoRootPath $RepoRootPath -FileName ([string]$Registry.file_name)
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $shape = Get-CsvShape -Path $file.FullName
    $observedSha = Get-Sha256Bytes -Bytes $bytes
    [long]$observedBytes = $bytes.Length

    $rowStatus = if ($shape.data_rows -eq [long]$Registry.expected_data_rows) { 'PASS' } else { 'FAIL' }
    $columnStatus = if ($shape.columns -eq [int]$Registry.expected_columns) { 'PASS' } else { 'FAIL' }
    $byteStatus = if ($observedBytes -eq [long]$Registry.expected_bytes) { 'PASS' } else { 'FAIL' }
    $hashStatus = if ($observedSha -eq [string]$Registry.expected_sha256) { 'PASS' } else { 'FAIL' }
    $repairVariant = ''
    $repairStatus = 'NOT_APPLICABLE'

    if (($byteStatus -ne 'PASS' -or $hashStatus -ne 'PASS') -and $rowStatus -eq 'PASS' -and $columnStatus -eq 'PASS') {
        $exact = @((Get-EncodingVariants -Bytes $bytes) | Where-Object {
            $_.size_bytes -eq [long]$Registry.expected_bytes -and $_.sha256 -eq [string]$Registry.expected_sha256
        })
        if ($exact.Count -eq 1) {
            $repairVariant = [string]$exact[0].name
            $repairStatus = 'EXACT_RECONSTRUCTION_AVAILABLE'
            if ($Repair) {
                [System.IO.File]::WriteAllBytes($file.FullName,[byte[]]$exact[0].bytes)
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                $observedSha = Get-Sha256Bytes -Bytes $bytes
                $observedBytes = [long]$bytes.Length
                $byteStatus = if ($observedBytes -eq [long]$Registry.expected_bytes) { 'PASS' } else { 'FAIL' }
                $hashStatus = if ($observedSha -eq [string]$Registry.expected_sha256) { 'PASS' } else { 'FAIL' }
                if ($byteStatus -ne 'PASS' -or $hashStatus -ne 'PASS') { throw "Exact repair failed verification for $($Registry.source_id)." }
                $repairStatus = 'REPAIRED_AND_VERIFIED'
            }
        } elseif ($exact.Count -gt 1) {
            $repairStatus = 'AMBIGUOUS_EXACT_RECONSTRUCTION'
        } else {
            $repairStatus = 'NO_EXACT_ENCODING_RECONSTRUCTION'
        }
    }

    $line = Get-LineEndingSummary -Bytes $bytes
    $overall = if ($rowStatus -eq 'PASS' -and $columnStatus -eq 'PASS' -and $byteStatus -eq 'PASS' -and $hashStatus -eq 'PASS') { 'PASS' } else { 'FAIL' }
    return [pscustomobject]@{
        source_id=[string]$Registry.source_id
        file_name=[string]$Registry.file_name
        repo_relative_path=('candidate-analysis/' + $file.Name)
        expected_sha256=[string]$Registry.expected_sha256
        observed_sha256=$observedSha
        hash_status=$hashStatus
        expected_bytes=[long]$Registry.expected_bytes
        observed_bytes=$observedBytes
        byte_status=$byteStatus
        expected_data_rows=[long]$Registry.expected_data_rows
        observed_data_rows=[long]$shape.data_rows
        row_status=$rowStatus
        expected_columns=[int]$Registry.expected_columns
        observed_columns=[int]$shape.columns
        column_status=$columnStatus
        crlf_count=[int]$line.crlf
        lf_only_count=[int]$line.lf_only
        cr_only_count=[int]$line.cr_only
        utf8_bom=[bool]$line.utf8_bom
        exact_repair_variant=$repairVariant
        repair_status=$repairStatus
        overall_status=$overall
        role=[string]$Registry.role
        authority=[string]$Registry.authority
        boundary=[string]$Registry.boundary
    }
}

function Write-Receipt {
    param([Parameter(Mandatory)][object[]]$Results,[string]$MarkdownPath,[string]$JsonPath)
    $allPass = (@($Results | Where-Object { $_.overall_status -ne 'PASS' }).Count -eq 0)
    Write-Utf8NoBom -Path $JsonPath -Content (([ordered]@{ all_pass=$allPass; results=$Results } | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Reference Source Reconciliation')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Exact current repository bytes and parsed CSV shape compared against AF-001/AF-002/AF-003 in the current CFA SoT authority snapshot.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('| Source | Rows | Columns | Bytes | SHA-256 | Repair | Overall |')
    [void]$b.AppendLine('|---|---|---|---|---|---|---|')
    foreach ($r in $Results) {
        [void]$b.AppendLine('| ' + $r.source_id + ' | ' + $r.row_status + ' ' + $r.observed_data_rows + '/' + $r.expected_data_rows + ' | ' + $r.column_status + ' ' + $r.observed_columns + '/' + $r.expected_columns + ' | ' + $r.byte_status + ' ' + $r.observed_bytes + '/' + $r.expected_bytes + ' | ' + $r.hash_status + ' | ' + $r.repair_status + ' ' + $r.exact_repair_variant + ' | ' + $r.overall_status + ' |')
    }
    [void]$b.AppendLine('')
    foreach ($r in $Results) {
        [void]$b.AppendLine('## ' + $r.source_id + ' — ' + $r.file_name)
        [void]$b.AppendLine('')
        [void]$b.AppendLine('- Expected SHA-256: ' + $r.expected_sha256)
        [void]$b.AppendLine('- Observed SHA-256: ' + $r.observed_sha256)
        [void]$b.AppendLine('- Line endings: CRLF=' + $r.crlf_count + ', LF-only=' + $r.lf_only_count + ', CR-only=' + $r.cr_only_count)
        [void]$b.AppendLine('- UTF-8 BOM: ' + $r.utf8_bom)
        [void]$b.AppendLine('- Authority: ' + $r.authority)
        [void]$b.AppendLine('- Boundary: ' + $r.boundary)
        [void]$b.AppendLine('')
    }
    Write-Utf8NoBom -Path $MarkdownPath -Content $b.ToString()
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-ref-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path (Join-Path $root 'candidate-analysis') -Force | Out-Null
        $path = Join-Path $root 'candidate-analysis\sample.csv'
        $lf = "a,b`n1,2`n3,4`n"
        $crlf = $lf.Replace("`n","`r`n")
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllBytes($path,$enc.GetBytes($lf))
        $expected = $enc.GetBytes($crlf)
        $registry = [pscustomobject]@{ source_id='AF-001'; file_name='sample.csv'; expected_sha256=(Get-Sha256Bytes -Bytes $expected); expected_bytes=[long]$expected.Length; expected_data_rows=2; expected_columns=2; role='test'; authority='test'; boundary='test' }
        $before = Test-Source -Registry $registry -RepoRootPath $root -Repair $false
        if ($before.overall_status -ne 'FAIL' -or $before.repair_status -ne 'EXACT_RECONSTRUCTION_AVAILABLE') { throw 'Self-test failed: exact reconstruction not identified.' }
        $after = Test-Source -Registry $registry -RepoRootPath $root -Repair $true
        if ($after.overall_status -ne 'PASS' -or $after.repair_status -ne 'REPAIRED_AND_VERIFIED') { throw 'Self-test failed: repair did not verify.' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($SoTSnapshotJson)) { $SoTSnapshotJson = Join-Path $RepoRoot 'docs\evidence\sot-authority-snapshot.json' }
    if ([string]::IsNullOrWhiteSpace($OutputMarkdown)) { $OutputMarkdown = Join-Path $RepoRoot 'docs\evidence\reference-source-reconciliation.md' }
    if ([string]::IsNullOrWhiteSpace($OutputJson)) { $OutputJson = Join-Path $RepoRoot 'docs\evidence\reference-source-reconciliation.json' }
    if (-not (Test-Path -LiteralPath $SoTSnapshotJson -PathType Leaf)) { throw "SoT snapshot JSON missing: $SoTSnapshotJson" }

    $registry = @(Get-Registry -SnapshotPath $SoTSnapshotJson)
    $results = @()
    foreach ($entry in $registry) { $results += ,(Test-Source -Registry $entry -RepoRootPath $RepoRoot -Repair ([bool]$RepairExactEncodingVariant)) }
    Write-Receipt -Results $results -MarkdownPath $OutputMarkdown -JsonPath $OutputJson
    foreach ($r in $results) { Write-Host ($r.source_id + ': ' + $r.overall_status + ' | ' + $r.repair_status + ' ' + $r.exact_repair_variant) }
    $failed = @($results | Where-Object { $_.overall_status -ne 'PASS' })
    if ($failed.Count -eq 0) { Write-Host 'CFA REFERENCE SOURCE RECONCILIATION: PASS'; exit 0 }
    Write-Host ('CFA REFERENCE SOURCE RECONCILIATION: FAIL (' + $failed.Count + ' source(s))')
    exit 2
}
catch {
    Write-Host 'CFA REFERENCE SOURCE RECONCILIATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
