#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$WorkbookPath = '',
    [string]$MarkdownPath = '',
    [string]$JsonPath = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-XlsxSupport {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$encoding)
}

function Get-EntryText {
    param([System.IO.Compression.ZipArchive]$Archive,[string]$Name,[switch]$Optional)
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) {
        if ($Optional) { return $null }
        throw "Required XLSX entry missing: $Name"
    }
    $stream = $null
    $reader = $null
    try {
        $stream = $entry.Open()
        $reader = New-Object System.IO.StreamReader($stream,[System.Text.Encoding]::UTF8,$true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function New-XmlDoc {
    param([string]$Text)
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $false
    $doc.LoadXml($Text)
    return $doc
}

function Get-ColumnIndex {
    param([string]$Reference)
    $letters = ([regex]::Match($Reference,'^[A-Za-z]+')).Value.ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($letters)) { throw "Invalid cell reference: $Reference" }
    [int]$value = 0
    foreach ($ch in $letters.ToCharArray()) {
        $value = ($value * 26) + ([int][char]$ch - [int][char]'A' + 1)
    }
    return $value - 1
}

function Get-ColumnLabel {
    param([int]$Index)
    [int]$n = $Index + 1
    $label = ''
    while ($n -gt 0) {
        $rem = ($n - 1) % 26
        $label = ([char]([int][char]'A' + $rem)) + $label
        $n = [int][math]::Floor(($n - 1) / 26)
    }
    return $label
}

function Get-TextParts {
    param([System.Xml.XmlNode]$Node)
    if ($null -eq $Node) { return '' }
    $parts = @()
    foreach ($t in $Node.SelectNodes(".//*[local-name()='t']")) { $parts += ,[string]$t.InnerText }
    if ($parts.Count -gt 0) { return ($parts -join '') }
    return [string]$Node.InnerText
}

function Get-SharedStrings {
    param([System.IO.Compression.ZipArchive]$Archive)
    $text = Get-EntryText -Archive $Archive -Name 'xl/sharedStrings.xml' -Optional
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $doc = New-XmlDoc -Text $text
    $items = @()
    foreach ($si in $doc.SelectNodes("//*[local-name()='si']")) { $items += ,(Get-TextParts -Node $si) }
    return $items
}

function Get-CellValue {
    param([System.Xml.XmlElement]$Cell,[object[]]$SharedStrings)
    $type = [string]$Cell.GetAttribute('t')
    $formula = $Cell.SelectSingleNode("./*[local-name()='f']")
    $value = $Cell.SelectSingleNode("./*[local-name()='v']")

    if ($null -ne $formula) {
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value.InnerText)) {
            return ('=' + [string]$formula.InnerText + ' => ' + [string]$value.InnerText)
        }
        return ('=' + [string]$formula.InnerText)
    }

    if ($type -eq 's') {
        if ($null -eq $value) { return '' }
        [int]$idx = -1
        if (-not [int]::TryParse([string]$value.InnerText,[ref]$idx)) { throw 'Invalid shared string index.' }
        if ($idx -lt 0 -or $idx -ge $SharedStrings.Count) { throw 'Shared string index out of range.' }
        return [string]$SharedStrings[$idx]
    }
    if ($type -eq 'inlineStr') { return Get-TextParts -Node $Cell.SelectSingleNode("./*[local-name()='is']") }
    if ($type -eq 'b') {
        if ($null -eq $value) { return '' }
        if ([string]$value.InnerText -eq '1') { return 'TRUE' }
        return 'FALSE'
    }
    if ($null -ne $value) { return [string]$value.InnerText }
    return ''
}

function Resolve-SheetEntry {
    param([string]$Target)
    $targetText = $Target.Replace('\\','/').TrimStart('/')
    while ($targetText.StartsWith('../')) { $targetText = $targetText.Substring(3) }
    if ($targetText.StartsWith('xl/')) { return $targetText }
    return ('xl/' + $targetText)
}

function Get-SheetDescriptors {
    param([System.IO.Compression.ZipArchive]$Archive)
    $workbook = New-XmlDoc -Text (Get-EntryText -Archive $Archive -Name 'xl/workbook.xml')
    $rels = New-XmlDoc -Text (Get-EntryText -Archive $Archive -Name 'xl/_rels/workbook.xml.rels')
    $relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $result = @()

    foreach ($sheet in $workbook.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']")) {
        $name = [string]$sheet.GetAttribute('name')
        $rid = [string]$sheet.GetAttribute('id',$relNs)
        $target = $null
        foreach ($rel in $rels.SelectNodes("//*[local-name()='Relationship']")) {
            if ([string]$rel.Attributes['Id'].Value -eq $rid) { $target = [string]$rel.Attributes['Target'].Value; break }
        }
        if ([string]::IsNullOrWhiteSpace($target)) { throw "Relationship not found for sheet '$name'." }
        $result += ,([pscustomobject]@{ name=$name; entry_name=(Resolve-SheetEntry -Target $target) })
    }
    if ($result.Count -eq 0) { throw 'No worksheets found in workbook.' }
    return $result
}

function Get-SheetSnapshot {
    param([System.IO.Compression.ZipArchive]$Archive,[object]$Descriptor,[object[]]$SharedStrings)
    $doc = New-XmlDoc -Text (Get-EntryText -Archive $Archive -Name ([string]$Descriptor.entry_name))
    $rawRows = @()
    [int]$maxCol = -1

    foreach ($row in $doc.SelectNodes("//*[local-name()='sheetData']/*[local-name()='row']")) {
        $map = @{}
        [int]$rowNo = 0
        if ($null -ne $row.Attributes['r']) { [void][int]::TryParse([string]$row.Attributes['r'].Value,[ref]$rowNo) }
        foreach ($node in $row.SelectNodes("./*[local-name()='c']")) {
            $cell = [System.Xml.XmlElement]$node
            $col = Get-ColumnIndex -Reference ([string]$cell.GetAttribute('r'))
            if ($col -gt $maxCol) { $maxCol = $col }
            $map[$col] = Get-CellValue -Cell $cell -SharedStrings $SharedStrings
        }
        if ($map.Count -gt 0) { $rawRows += ,([pscustomobject]@{ row_number=$rowNo; map=$map }) }
    }

    $rows = @()
    foreach ($raw in $rawRows) {
        $vals = @()
        for ($i=0; $i -le $maxCol; $i++) {
            if ($raw.map.ContainsKey($i)) { $vals += ,[string]$raw.map[$i] } else { $vals += ,'' }
        }
        $rows += ,([pscustomobject]@{ row_number=[int]$raw.row_number; values=$vals })
    }
    return [pscustomobject]@{ name=[string]$Descriptor.name; entry_name=[string]$Descriptor.entry_name; max_column_index=$maxCol; rows=$rows }
}

function Escape-Markdown {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('|','\\|').Replace("`r",' ').Replace("`n",' <br> ')
}

function Export-Snapshot {
    param([string]$InputWorkbook,[string]$OutMarkdown,[string]$OutJson)
    Initialize-XlsxSupport
    $resolved = (Resolve-Path -LiteralPath $InputWorkbook).ProviderPath
    $info = Get-Item -LiteralPath $resolved
    $hash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($resolved)
        $shared = @(Get-SharedStrings -Archive $archive)
        $descriptors = @(Get-SheetDescriptors -Archive $archive)
        $sheets = @()
        foreach ($descriptor in $descriptors) { $sheets += ,(Get-SheetSnapshot -Archive $archive -Descriptor $descriptor -SharedStrings $shared) }
    }
    finally { if ($null -ne $archive) { $archive.Dispose() } }

    $hits = @()
    foreach ($sheet in $sheets) {
        foreach ($row in $sheet.rows) {
            $joined = (($row.values | ForEach-Object { [string]$_ }) -join ' | ')
            foreach ($m in [regex]::Matches($joined,'(?i)DATA-\d{3}')) {
                $hits += ,([pscustomobject]@{ id=$m.Value.ToUpperInvariant(); sheet=[string]$sheet.name; row_number=[int]$row.row_number; values=@($row.values) })
            }
        }
    }

    $snapshot = [ordered]@{ source_file='CFA-SoT.xlsx'; source_size_bytes=[long]$info.Length; source_sha256=$hash; sheets=$sheets; authority_id_hits=$hits }
    Write-Utf8NoBom -Path $OutJson -Content (($snapshot | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

    $b = New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Source of Truth — Text Authority Snapshot')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Generated reproducibly from CFA-SoT.xlsx without Excel automation. The workbook remains the authority; this snapshot is a review surface only.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('- Workbook size bytes: ' + [string]$info.Length)
    [void]$b.AppendLine('- Workbook SHA-256: ' + $hash)
    [void]$b.AppendLine('- Worksheet count: ' + [string]$sheets.Count)
    [void]$b.AppendLine('')
    [void]$b.AppendLine('## Authority-ID hits')
    [void]$b.AppendLine('')
    if ($hits.Count -eq 0) {
        [void]$b.AppendLine('No DATA-### identifiers were found.')
    } else {
        [void]$b.AppendLine('| ID | Sheet | Row | Row values |')
        [void]$b.AppendLine('|---|---|---:|---|')
        foreach ($hit in $hits) {
            $rowText = (($hit.values | ForEach-Object { Escape-Markdown -Text ([string]$_) }) -join ' / ')
            [void]$b.AppendLine('| ' + $hit.id + ' | ' + (Escape-Markdown -Text $hit.sheet) + ' | ' + $hit.row_number + ' | ' + $rowText + ' |')
        }
    }
    [void]$b.AppendLine('')

    foreach ($sheet in $sheets) {
        [void]$b.AppendLine('## Sheet: ' + (Escape-Markdown -Text $sheet.name))
        [void]$b.AppendLine('')
        [void]$b.AppendLine('XLSX entry: ' + [string]$sheet.entry_name)
        [void]$b.AppendLine('')
        if ($sheet.rows.Count -eq 0 -or $sheet.max_column_index -lt 0) {
            [void]$b.AppendLine('_No populated cells._')
            [void]$b.AppendLine('')
            continue
        }
        $headers = @('Row'); $seps = @('---:')
        for ($i=0; $i -le $sheet.max_column_index; $i++) { $headers += ,(Get-ColumnLabel -Index $i); $seps += ,'---' }
        [void]$b.AppendLine('| ' + ($headers -join ' | ') + ' |')
        [void]$b.AppendLine('| ' + ($seps -join ' | ') + ' |')
        foreach ($row in $sheet.rows) {
            $cells = @([string]$row.row_number)
            foreach ($v in $row.values) { $cells += ,(Escape-Markdown -Text ([string]$v)) }
            [void]$b.AppendLine('| ' + ($cells -join ' | ') + ' |')
        }
        [void]$b.AppendLine('')
    }
    Write-Utf8NoBom -Path $OutMarkdown -Content $b.ToString()
    return [pscustomobject]@{ workbook_sha256=$hash; sheet_count=$sheets.Count; authority_hit_count=$hits.Count }
}

function Add-ZipText {
    param([System.IO.Compression.ZipArchive]$Archive,[string]$Name,[string]$Text)
    $entry = $Archive.CreateEntry($Name)
    $stream = $null; $writer = $null
    try {
        $stream = $entry.Open()
        $writer = New-Object System.IO.StreamWriter($stream,(New-Object System.Text.UTF8Encoding($false)))
        $writer.Write($Text)
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-SelfTest {
    Initialize-XlsxSupport
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-sot-' + [guid]::NewGuid().ToString('N'))
    $xlsx = Join-Path $root 'test.xlsx'; $md = Join-Path $root 'out.md'; $json = Join-Path $root 'out.json'
    try {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $fs = [System.IO.File]::Open($xlsx,[System.IO.FileMode]::Create,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        $zip = $null
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs,[System.IO.Compression.ZipArchiveMode]::Create,$false)
            Add-ZipText -Archive $zip -Name 'xl/workbook.xml' -Text '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Authority" sheetId="1" r:id="rId1"/></sheets></workbook>'
            Add-ZipText -Archive $zip -Name 'xl/_rels/workbook.xml.rels' -Text '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
            Add-ZipText -Archive $zip -Name 'xl/sharedStrings.xml' -Text '<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>ID</t></si><si><t>File</t></si><si><t>DATA-001</t></si><si><t>sample.csv</t></si></sst>'
            Add-ZipText -Archive $zip -Name 'xl/worksheets/sheet1.xml' -Text '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row></sheetData></worksheet>'
        }
        finally { if ($null -ne $zip) { $zip.Dispose() } else { $fs.Dispose() } }

        $r = Export-Snapshot -InputWorkbook $xlsx -OutMarkdown $md -OutJson $json
        if ($r.sheet_count -ne 1 -or $r.authority_hit_count -ne 1) { throw 'Self-test failed: wrong sheet or hit count.' }
        if ($r.workbook_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Self-test failed: malformed SHA-256.' }
        $mdText = [System.IO.File]::ReadAllText($md)
        if (-not $mdText.Contains('DATA-001') -or -not $mdText.Contains('sample.csv')) { throw 'Self-test failed: authority values missing.' }
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
    if ([string]::IsNullOrWhiteSpace($WorkbookPath)) { $WorkbookPath = Join-Path $RepoRoot 'CFA-SoT.xlsx' }
    if ([string]::IsNullOrWhiteSpace($MarkdownPath)) { $MarkdownPath = Join-Path $RepoRoot 'docs\evidence\sot-authority-snapshot.md' }
    if ([string]::IsNullOrWhiteSpace($JsonPath)) { $JsonPath = Join-Path $RepoRoot 'docs\evidence\sot-authority-snapshot.json' }
    if (-not (Test-Path -LiteralPath $WorkbookPath -PathType Leaf)) { throw "CFA SoT workbook not found: $WorkbookPath" }
    $r = Export-Snapshot -InputWorkbook $WorkbookPath -OutMarkdown $MarkdownPath -OutJson $JsonPath
    Write-Host ('CFA SoT SHA-256: ' + $r.workbook_sha256)
    Write-Host ('Sheets exported: ' + $r.sheet_count)
    Write-Host ('Authority ID hits: ' + $r.authority_hit_count)
    Write-Host 'CFA SOT AUTHORITY EXPORT: PASS'
}
catch {
    Write-Host 'CFA SOT AUTHORITY EXPORT: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
