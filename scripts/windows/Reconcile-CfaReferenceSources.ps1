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
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$encoding)
}

function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StrictUtf8Text {
    param([byte[]]$Bytes)
    $decoder = New-Object System.Text.UTF8Encoding($false,$true)
    $text = $decoder.GetString($Bytes)
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function Get-EncodingVariantCandidates {
    param([byte[]]$Bytes)
    $text = Get-StrictUtf8Text -Bytes $Bytes
    $normalized = $text.Replace("`r`n","`n").Replace("`r","`n")
    $lf = $normalized
    $crlf = $normalized.Replace("`n","`r`n")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)

    $candidates = @()
    foreach ($item in @(
        [pscustomobject]@{ name='UTF8_LF_NO_BOM'; text=$lf; encoding=$utf8NoBom; bom=$false },
        [pscustomobject]@{ name='UTF8_CRLF_NO_BOM'; text=$crlf; encoding=$utf8NoBom; bom=$false },
        [pscustomobject]@{ name='UTF8_LF_BOM'; text=$lf; encoding=$utf8Bom; bom=$true },
        [pscustomobject]@{ name='UTF8_CRLF_BOM'; text=$crlf; encoding=$utf8Bom; bom=$true }
    )) {
        $payload = $item.encoding.GetBytes([string]$item.text)
        if ($item.bom) {
            $preamble = $item.encoding.GetPreamble()
            $combined = New-Object byte[] ($preamble.Length + $payload.Length)
            [Array]::Copy($preamble,0,$combined,0,$preamble.Length)
            [Array]::Copy($payload,0,$combined,$preamble.Length,$payload.Length)
            $payload = $combined
        }
        $candidates += ,([pscustomobject]@{ name=$item.name; bytes=$payload; size_bytes=[long]$payload.Length; sha256=(Get-Sha256Bytes -Bytes $payload) })
    }
    return $candidates
}

function Get-LineEndingSummary {
    param([byte[]]$Bytes)
    $text = Get-StrictUtf8Text -Bytes $Bytes
    $crlf = [regex]::Matches($text,"`r`n").Count
    $withoutCrlf = $text.Replace("`r`n",'')
    $lfOnly = [regex]::Matches($withoutCrlf,"`n").Count
    $crOnly = [regex]::Matches($withoutCrlf,"`r").Count
    $hasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    return [pscustomobject]@{ crlf_count=$crlf; lf_only_count=$lfOnly; cr_only_count=$crOnly; utf8_bom=$hasBom }
}

function Get-CsvShape {
    param([string]$Path)
    $rows = @(Import-Csv -LiteralPath $Path)
    $columns = 0
    if ($rows.Count -gt 0) { $columns = @($rows[0].PSObject.Properties).Count }
    else {
        $header = Get-Content -LiteralPath $Path -TotalCount 1
        if (-not [string]::IsNullOrWhiteSpace($header)) { $columns = ($header -split ',').Count }
    }
    return [pscustomobject]@{ data_rows=$rows.Count; columns=$columns }
}

function Get-SourceRegistry {
    param([string]$SnapshotJsonPath)
    $snapshot = Get-Content -LiteralPath $SnapshotJsonPath -Raw | ConvertFrom-Json
    $sheet = @($snapshot.sheets | Where-Object { [string]$_.name -eq 'Analyzed Files' })
    if ($sheet.Count -ne 1) { throw "Expected exactly one 'Analyzed Files' sheet in SoT snapshot; observed $($sheet.Count)." }

    $registry = @()
    foreach ($row in $sheet[0].rows) {
        $values = @($row.values)
        if ($values.Count -lt 6) { continue }
        $id = [string]$values[0]
        if ($id -notmatch '^AF-00[1-3]$') { continue }
        $registry += ,([pscustomobject]@{
            source_id=$id
            file_name=[string]$values[1]
            expected_sha256=([string]$values[2]).ToLowerInvariant()
            expected_bytes=[long]$values[3]
            expected_data_rows=[long]$values[4]
            expected_columns=[int]$values[5]
            role=if($values.Count -gt 6){[string]$values[6]}else{''}
            authority=if($values.Count -gt 7){[string]$values[7]}else{''}
            boundary=if($values.Count -gt 8){[string]$values[8]}else{''}
        })
    }
    if ($registry.Count -ne 3) { throw "Expected AF-001/002/003 registry rows; observed $($registry.Count)." }
    return $registry
}

function Resolve-ExactRepoFile {
    param([string]$RepoRootPath,[string]$FileName)
    $matches = @(Get-ChildItem -LiteralPath $RepoRootPath -File -Recurse -Force | Where-Object {
        $_.Name -eq $FileName -and $_.FullName -notmatch '[\\/]\.git[\\/]'
    })
    if ($matches.Count -ne 1) { throw "Expected exactly one repository file named '$FileName'; observed $($matches.Count)." }
    return $matches[0]
}

function Test-AndMaybeRepairSource {
    param([object]$RegistryRow,[string]$RepoRootPath,[bool]$Repair)
    $file = Resolve-ExactRepoFile -RepoRootPath $RepoRootPath -FileName ([string]$RegistryRow.file_name)
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $shape = Get-CsvShape -Path $file.FullName
    $line = Get-LineEndingSummary -Bytes $bytes
    $rawSha = Get-Sha256Bytes -Bytes $bytes
    $rawSize = [long]$bytes.Length

    $rowStatus = if ([long]$shape.data_rows -eq [long]$RegistryRow.expected_data_rows) { 'PASS' } else { 'FAIL' }
    $columnStatus = if ([int]$shape.columns -eq [int]$RegistryRow.expected_columns) { 'PASS' } else { 'FAIL' }
    $byteStatus = if ($rawSize -eq [long]$RegistryRow.expected_bytes) { 'PASS' } else { 'FAIL' }
    $hashStatus = if ($rawSha -eq [string]$RegistryRow.expected_sha256) { 'PASS' } else { 'FAIL' }
    $repairVariant = ''
    $repairStatus = 'NOT_APPLICABLE'

    if (($hashStatus -ne 'PASS' -or $byteStatus -ne 'PASS') -and $rowStatus -eq 'PASS' -and $columnStatus -eq 'PASS') {
        $matchingVariants = @((Get-EncodingVariantCandidates -Bytes $bytes) | Where-Object {
            $_.sha256 -eq [string]$RegistryRow.expected_sha256 -and $_.size_bytes -eq [long]$RegistryRow.expected_bytes
        })
        if ($matchingVariants.Count -eq 1) {
            $repairVariant = [string]$matchingVariants[0].name
            $repairStatus = 'EXACT_RECONSTRUCTION_AVAILABLE'
            if ($Repair) {
                [System.IO.File]::WriteAllBytes($file.FullName,[byte[]]$matchingVariants[0].bytes)
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                $rawSha = Get-Sha256Bytes -Bytes $bytes
                $rawSize = [long]$bytes.Length
                $byteStatus = if ($rawSize -eq [long]$RegistryRow.expected_bytes) { 'PASS' } else { 'FAIL' }
                $hashStatus = if ($rawSha -eq [string]$RegistryRow.expected_sha256) { 'PASS' } else { 'FAIL' }
                $line = Get-LineEndingSummary -Bytes $bytes
                if ($byteStatus -eq 'PASS' -and $hashStatus -eq 'PASS') { $repairStatus = 'REPAIRED_AND_VERIFIED' } else { throw "Repair candidate for $($RegistryRow.source_id) did not verify after write." }
            }
        }
        elseif ($matchingVariants.Count -gt 1) {
            $repairStatus = 'AMBIGUOUS_EXACT_RECONSTRUCTION'
        }
        else {
            $repairStatus = 'NO_EXACT_ENCODING_RECONSTRUCTION'
        }
    }

    $overall = if ($rowStatus -eq 'PASS' -and $columnStatus -eq 'PASS' -and $byteStatus -eq 'PASS' -and $hashStatus -eq 'PASS') { 'PASS' } else { 'FAIL' }
    $relative = $file.FullName.Substring($RepoRootPath.TrimEnd('\\','/').Length).TrimStart('\\','/').Replace('\\','/')
    return [pscustomobject]@{
        source_id=[string]$RegistryRow.source_id
        file_name=[string]$RegistryRow.file_name
        repo_relative_path=$relative
        expected_sha256=[string]$RegistryRow.expected_sha256
        observed_sha256=$rawSha
        hash_status=$hashStatus
        expected_bytes=[long]$RegistryRow.expected_bytes
        observed_bytes=$rawSize
        byte_status=$byteStatus
        expected_data_rows=[long]$RegistryRow.expected_data_rows
        observed_data_rows=[long]$shape.data_rows
        row_status=$rowStatus
        expected_columns=[int]$RegistryRow.expected_columns
        observed_columns=[int]$shape.columns
        column_status=$columnStatus
        crlf_count=[int]$line.crlf_count
        lf_only_count=[int]$line.lf_only_count
        cr_only_count=[int]$line.cr_only_count
        utf8_bom=[bool]$line.utf8_bom
        exact_repair_variant=$repairVariant
        repair_status=$repairStatus
        overall_status=$overall
        role=[string]$RegistryRow.role
        authority=[string]$RegistryRow.authority
        boundary=[string]$RegistryRow.boundary
    }
}

function Write-Receipt {
    param([object[]]$Results,[string]$MarkdownPath,[string]$JsonPath)
    $json = [ordered]@{ results=$Results; all_pass=(@($Results | Where-Object { $_.overall_status -ne 'PASS' }).Count -eq 0) } | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path $JsonPath -Content ($json + [Environment]::NewLine)

    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Reference Source Reconciliation')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Compared current repository bytes and parsed CSV shape against the exact AF-001/AF-002/AF-003 registry in the current CFA SoT authority snapshot.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('| Source | File | Rows | Columns | Bytes | SHA-256 | Repair | Overall |')
    [void]$b.AppendLine('|---|---|---|---|---|---|---|---|')
    foreach ($r in $Results) {
        [void]$b.AppendLine('| ' + $r.source_id + ' | ' + $r.file_name + ' | ' + $r.row_status + ' (' + $r.observed_data_rows + '/' + $r.expected_data_rows + ') | ' + $r.column_status + ' (' + $r.observed_columns + '/' + $r.expected_columns + ') | ' + $r.byte_status + ' (' + $r.observed_bytes + '/' + $r.expected_bytes + ') | ' + $r.hash_status + ' | ' + $r.repair_status + ' ' + $r.exact_repair_variant + ' | ' + $r.overall_status + ' |')
    }
    [void]$b.AppendLine('')
    foreach ($r in $Results) {
        [void]$b.AppendLine('## ' + $r.source_id)
        [void]$b.AppendLine('')
        [void]$b.AppendLine('- Repository path: ' + $r.repo_relative_path)
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
        New-Item -ItemType Directory -Path (Join-Path $root 'docs\evidence') -Force | Out-Null
        $path = Join-Path $root 'candidate-analysis\sample.csv'
        $lfText = "a,b`n1,2`n3,4`n"
        $crlfText = $lfText.Replace("`n","`r`n")
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllBytes($path,$enc.GetBytes($lfText))
        $expectedBytes = $enc.GetBytes($crlfText)
        $registry = [pscustomobject]@{ source_id='AF-001'; file_name='sample.csv'; expected_sha256=(Get-Sha256Bytes -Bytes $expectedBytes); expected_bytes=$expectedBytes.Length; expected_data_rows=2; expected_columns=2; role='test'; authority='test'; boundary='test' }
        $before = Test-AndMaybeRepairSource -RegistryRow $registry -RepoRootPath $root -Repair $false
        if ($before.overall_status -ne 'FAIL' -or $before.repair_status -ne 'EXACT_RECONSTRUCTION_AVAILABLE') { throw 'Self-test failed: exact CRLF reconstruction was not identified.' }
        $after = Test-AndMaybeRepairSource -RegistryRow $registry -RepoRootPath $root -Repair $true
        if ($after.overall_status -ne 'PASS' -or $after.repair_status -ne 'REPAIRED_AND_VERIFIED') { throw 'Self-test failed: exact reconstruction did not verify.' }
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
    if (-not (Test-Path -LiteralPath $SoTSnapshotJson -PathType Leaf)) { throw "SoT snapshot JSON not found: $SoTSnapshotJson" }

    $registry = @(Get-SourceRegistry -SnapshotJsonPath $SoTSnapshotJson)
    $results = @()
    foreach ($row in $registry) { $results += ,(Test-AndMaybeRepairSource -RegistryRow $row -RepoRootPath $RepoRoot -Repair ([bool]$RepairExactEncodingVariant)) }
    Write-Receipt -Results $results -MarkdownPath $OutputMarkdown -JsonPath $OutputJson

    $failed = @($results | Where-Object { $_.overall_status -ne 'PASS' })
    foreach ($r in $results) { Write-Host ($r.source_id + ': ' + $r.overall_status + ' | repair=' + $r.repair_status + ' ' + $r.exact_repair_variant) }
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
