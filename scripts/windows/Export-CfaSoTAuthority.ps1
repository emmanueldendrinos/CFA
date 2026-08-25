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
    if ($null -eq ('System.IO.Compression.ZipFile' -as [type])) {
        throw 'System.IO.Compression.ZipFile is unavailable.'
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-ZipEntryText {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][string]$EntryName,
        [switch]$Optional
    )

    $entry = $Archive.GetEntry($EntryName)
    if ($null -eq $entry) {
        if ($Optional) { return $null }
        throw "Required XLSX entry is missing: $EntryName"
    }

    $stream = $null
    $reader = $null
    try {
        $stream = $entry.Open()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function New-XmlDocument {
    param([Parameter(Mandatory)][string]$Text)
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $false
    $doc.LoadXml($Text)
    return $doc
}

function Get-ColumnIndexFromReference {
    param([Parameter(Mandatory)][string]$Reference)

    $letters = ([regex]::Match($Reference, '^[A-Za-z]+')).Value.ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($letters)) {
        throw "Cell reference has no column letters: $Reference"
    }

    [int]$index = 0
    foreach ($ch in $letters.ToCharArray()) {
        $index = ($index * 26) + ([int][char]$ch - [int][char]'A' + 1)
    }
    return $index - 1
}

function Get-ColumnLabel {
    param([Parameter(Mandatory)][int]$Index)

    [int]$n = $Index + 1
    $label = ''
    while ($n -gt 0) {
        $rem = ($n - 1) % 26
        $label = ([char]([int][char]'A' + $rem)) + $label
        $n = [math]::Floor(($n - 1) / 26)
    }
    return $label
}

function Get-NodeTextParts {
    param([AllowNull()][System.Xml.XmlNode]$Node)
    if ($null -eq $Node) { return '' }

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($textNode in $Node.SelectNodes(".//*[local-name()='t']")) {
        $parts.Add([string]$textNode.InnerText)
    }
    if ($parts.Count -gt 0) { return ($parts -join '') }
    return [string]$Node.InnerText
}

function Get-SharedStrings {
    param([Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive)

    $text = Get-ZipEntryText -Archive $Archive -EntryName 'xl/sharedStrings.xml' -Optional
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $doc = New-XmlDocument -Text $text
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($si in $doc.SelectNodes("//*[local-name()='si']")) {
        $values.Add((Get-NodeTextParts -Node $si))
    }
    return @($values)
}

function Get-CellText {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Cell,
        [Parameter(Mandatory)][object[]]$SharedStrings
    )

    $type = [string]$Cell.GetAttribute('t')
    $formulaNode = $Cell.SelectSingleNode("./*[local-name()='f']")
    $valueNode = $Cell.SelectSingleNode("./*[local-name()='v']")

    if ($null -ne $formulaNode) {
        $formula = [string]$formulaNode.InnerText
        $cached = if ($null -ne $valueNode) { [string]$valueNode.InnerText } else { '' }
        if ([string]::IsNullOrWhiteSpace($cached)) { return '=' + $formula }
        return ('=' + $formula + ' => ' + $cached)
    }

    switch ($type) {
        's' {
            if ($null -eq $valueNode -or [string]::IsNullOrWhiteSpace([string]$valueNode.InnerText)) { return '' }
            [int]$sharedIndex = 0
            if (-not [int]::TryParse([string]$valueNode.InnerText, [ref]$sharedIndex)) {
                throw "Invalid shared-string index in cell $($Cell.GetAttribute('r'))."
            }
            if ($sharedIndex -lt 0 -or $sharedIndex -ge $SharedStrings.Count) {
                throw "Shared-string index out of range in cell $($Cell.GetAttribute('r'))."
            }
            return [string]$SharedStrings[$sharedIndex]
        }
        'inlineStr' {
            return Get-NodeTextParts -Node $Cell.SelectSingleNode("./*[local-name()='is']")
        }
        'b' {
            if ($null -eq $valueNode) { return '' }
            return $(if ([string]$valueNode.InnerText -eq '1') { 'TRUE' } else { 'FALSE' })
        }
        default {
            if ($null -ne $valueNode) { return [string]$valueNode.InnerText }
            return ''
        }
    }
}

function Resolve-WorksheetEntryName {
    param([Parameter(Mandatory)][string]$Target)

    $normalized = $Target.Replace('\\','/').TrimStart('/')
    if ($normalized.StartsWith('xl/', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalized
    }
    if ($normalized.StartsWith('../')) {
        while ($normalized.StartsWith('../')) { $normalized = $normalized.Substring(3) }
        return ('xl/' + $normalized)
    }
    return ('xl/' + $normalized)
}

function Get-WorkbookSheetDescriptors {
    param([Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive)

    $workbook = New-XmlDocument -Text (Get-ZipEntryText -Archive $Archive -EntryName 'xl/workbook.xml')
    $rels = New-XmlDocument -Text (Get-ZipEntryText -Archive $Archive -EntryName 'xl/_rels/workbook.xml.rels')

    $descriptors = New-Object System.Collections.Generic.List[object]
    $relationshipNamespace = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

    foreach ($sheet in $workbook.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']")) {
        $sheetName = [string]$sheet.GetAttribute('name')
        $relationshipId = [string]$sheet.GetAttribute('id', $relationshipNamespace)
        if ([string]::IsNullOrWhiteSpace($relationshipId)) {
            throw "Worksheet '$sheetName' is missing its relationship ID."
        }

        $relationship = $null
        foreach ($candidate in $rels.SelectNodes("//*[local-name()='Relationship']")) {
            if ([string]$candidate.Attributes['Id'].Value -eq $relationshipId) {
                $relationship = $candidate
                break
            }
        }
        if ($null -eq $relationship) {
            throw "Worksheet relationship '$relationshipId' was not found for '$sheetName'."
        }

        $target = [string]$relationship.Attributes['Target'].Value
        $descriptors.Add([pscustomobject]@{
            name = $sheetName
            relationship_id = $relationshipId
            entry_name = (Resolve-WorksheetEntryName -Target $target)
        })
    }

    if ($descriptors.Count -eq 0) { throw 'No worksheets were found in CFA-SoT.xlsx.' }
    return @($descriptors)
}

function Get-WorksheetSnapshot {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][object]$Descriptor,
        [Parameter(Mandatory)][object[]]$SharedStrings
    )

    $doc = New-XmlDocument -Text (Get-ZipEntryText -Archive $Archive -EntryName ([string]$Descriptor.entry_name))
    $rowObjects = New-Object System.Collections.Generic.List[object]
    [int]$maxColumnIndex = -1

    foreach ($row in $doc.SelectNodes("//*[local-name()='sheetData']/*[local-name()='row']")) {
        $valuesByColumn = @{}
        [int]$rowNumber = 0
        [void][int]::TryParse([string]$row.Attributes['r'].Value, [ref]$rowNumber)

        foreach ($cellNode in $row.SelectNodes("./*[local-name()='c']")) {
            $cell = [System.Xml.XmlElement]$cellNode
            $reference = [string]$cell.GetAttribute('r')
            $columnIndex = Get-ColumnIndexFromReference -Reference $reference
            if ($columnIndex -gt $maxColumnIndex) { $maxColumnIndex = $columnIndex }
            $valuesByColumn[$columnIndex] = Get-CellText -Cell $cell -SharedStrings $SharedStrings
        }

        if ($valuesByColumn.Count -gt 0) {
            $rowObjects.Add([pscustomobject]@{
                row_number = $rowNumber
                values_by_column = $valuesByColumn
            })
        }
    }

    $normalizedRows = New-Object System.Collections.Generic.List[object]
    foreach ($rowObject in $rowObjects) {
        $values = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -le $maxColumnIndex; $i++) {
            if ($rowObject.values_by_column.ContainsKey($i)) {
                $values.Add([string]$rowObject.values_by_column[$i])
            }
            else {
                $values.Add('')
            }
        }
        $normalizedRows.Add([pscustomobject]@{
            row_number = [int]$rowObject.row_number
            values = @($values)
        })
    }

    return [pscustomobject]@{
        name = [string]$Descriptor.name
        entry_name = [string]$Descriptor.entry_name
        max_column_index = $maxColumnIndex
        rows = @($normalizedRows)
    }
}

function Escape-MarkdownCell {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('|','\\|').Replace("`r",' ').Replace("`n",' <br> ')
}

function Export-AuthoritySnapshot {
    param(
        [Parameter(Mandatory)][string]$InputWorkbook,
        [Parameter(Mandatory)][string]$OutputMarkdown,
        [Parameter(Mandatory)][string]$OutputJson
    )

    Initialize-XlsxSupport
    $resolvedWorkbook = (Resolve-Path -LiteralPath $InputWorkbook).ProviderPath
    $workbookHash = (Get-FileHash -LiteralPath $resolvedWorkbook -Algorithm SHA256).Hash.ToLowerInvariant()
    $fileInfo = Get-Item -LiteralPath $resolvedWorkbook

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedWorkbook)
        $sharedStrings = @(Get-SharedStrings -Archive $archive)
        $descriptors = @(Get-WorkbookSheetDescriptors -Archive $archive)
        $sheets = New-Object System.Collections.Generic.List[object]

        foreach ($descriptor in $descriptors) {
            $sheets.Add((Get-WorksheetSnapshot -Archive $archive -Descriptor $descriptor -SharedStrings $sharedStrings))
        }
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }

    $authorityHits = New-Object System.Collections.Generic.List[object]
    foreach ($sheet in $sheets) {
        foreach ($row in $sheet.rows) {
            $joined = (($row.values | ForEach-Object { [string]$_ }) -join ' | ')
            $matches = [regex]::Matches($joined, '(?i)DATA-\d{3}')
            foreach ($match in $matches) {
                $authorityHits.Add([pscustomobject]@{
                    id = $match.Value.ToUpperInvariant()
                    sheet = [string]$sheet.name
                    row_number = [int]$row.row_number
                    values = @($row.values)
                })
            }
        }
    }

    $snapshot = [ordered]@{
        source_file = 'CFA-SoT.xlsx'
        source_size_bytes = [long]$fileInfo.Length
        source_sha256 = $workbookHash
        sheets = @($sheets)
        authority_id_hits = @($authorityHits)
    }

    $json = $snapshot | ConvertTo-Json -Depth 20
    Write-Utf8NoBom -Path $OutputJson -Content ($json + [Environment]::NewLine)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# CFA Source of Truth — Text Authority Snapshot')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('Generated reproducibly from `CFA-SoT.xlsx` without Excel automation. The workbook remains the authority; this text snapshot exists only so its current contents can be reviewed and reconciled through Git.')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine("- Workbook size bytes: $($fileInfo.Length)")
    [void]$builder.AppendLine("- Workbook SHA-256: `$workbookHash`")
    [void]$builder.AppendLine("- Worksheet count: $($sheets.Count)")
    [void]$builder.AppendLine('')

    [void]$builder.AppendLine('## Authority-ID hits')
    [void]$builder.AppendLine('')
    if ($authorityHits.Count -eq 0) {
        [void]$builder.AppendLine('No `DATA-###` identifiers were found.')
        [void]$builder.AppendLine('')
    }
    else {
        [void]$builder.AppendLine('| ID | Sheet | Row | Row values |')
        [void]$builder.AppendLine('|---|---|---:|---|')
        foreach ($hit in $authorityHits) {
            $rowText = (($hit.values | ForEach-Object { Escape-MarkdownCell -Text ([string]$_) }) -join ' / ')
            [void]$builder.AppendLine("| $($hit.id) | $(Escape-MarkdownCell -Text $hit.sheet) | $($hit.row_number) | $rowText |")
        }
        [void]$builder.AppendLine('')
    }

    foreach ($sheet in $sheets) {
        [void]$builder.AppendLine("## Sheet: $(Escape-MarkdownCell -Text $sheet.name)")
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine("XLSX entry: `$($sheet.entry_name)`")
        [void]$builder.AppendLine('')

        if ($sheet.rows.Count -eq 0 -or $sheet.max_column_index -lt 0) {
            [void]$builder.AppendLine('_No populated cells._')
            [void]$builder.AppendLine('')
            continue
        }

        $headers = New-Object System.Collections.Generic.List[string]
        $separators = New-Object System.Collections.Generic.List[string]
        $headers.Add('Row')
        $separators.Add('---:')
        for ($i = 0; $i -le $sheet.max_column_index; $i++) {
            $headers.Add((Get-ColumnLabel -Index $i))
            $separators.Add('---')
        }
        [void]$builder.AppendLine('| ' + ($headers -join ' | ') + ' |')
        [void]$builder.AppendLine('| ' + ($separators -join ' | ') + ' |')

        foreach ($row in $sheet.rows) {
            $cells = New-Object System.Collections.Generic.List[string]
            $cells.Add([string]$row.row_number)
            foreach ($value in $row.values) {
                $cells.Add((Escape-MarkdownCell -Text ([string]$value)))
            }
            [void]$builder.AppendLine('| ' + ($cells -join ' | ') + ' |')
        }
        [void]$builder.AppendLine('')
    }

    Write-Utf8NoBom -Path $OutputMarkdown -Content $builder.ToString()

    return [pscustomobject]@{
        workbook_sha256 = $workbookHash
        markdown_path = $OutputMarkdown
        json_path = $OutputJson
        sheet_count = $sheets.Count
        authority_hit_count = $authorityHits.Count
    }
}

function Add-ZipTextEntry {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text
    )

    $entry = $Archive.CreateEntry($Name)
    $stream = $null
    $writer = $null
    try {
        $stream = $entry.Open()
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        $writer.Write($Text)
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Invoke-SelfTest {
    Initialize-XlsxSupport
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-sot-export-' + [guid]::NewGuid().ToString('N'))
    $xlsx = Join-Path $tempRoot 'test.xlsx'
    $markdown = Join-Path $tempRoot 'snapshot.md'
    $json = Join-Path $tempRoot 'snapshot.json'

    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $fileStream = [System.IO.File]::Open($xlsx, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $archive = $null
        try {
            $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            Add-ZipTextEntry -Archive $archive -Name 'xl/workbook.xml' -Text @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Authority" sheetId="1" r:id="rId1"/></sheets></workbook>
'@
            Add-ZipTextEntry -Archive $archive -Name 'xl/_rels/workbook.xml.rels' -Text @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
'@
            Add-ZipTextEntry -Archive $archive -Name 'xl/sharedStrings.xml' -Text @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4"><si><t>ID</t></si><si><t>File</t></si><si><t>DATA-001</t></si><si><t>sample.csv</t></si></sst>
'@
            Add-ZipTextEntry -Archive $archive -Name 'xl/worksheets/sheet1.xml' -Text @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row></sheetData></worksheet>
'@
        }
        finally {
            if ($null -ne $archive) { $archive.Dispose() }
            else { $fileStream.Dispose() }
        }

        $result = Export-AuthoritySnapshot -InputWorkbook $xlsx -OutputMarkdown $markdown -OutputJson $json
        if ($result.sheet_count -ne 1) { throw 'Self-test failed: expected one sheet.' }
        if ($result.authority_hit_count -ne 1) { throw 'Self-test failed: expected one DATA identifier hit.' }
        if ($result.workbook_sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Self-test failed: workbook SHA-256 is malformed.' }

        $markdownText = [System.IO.File]::ReadAllText($markdown)
        if (-not $markdownText.Contains('DATA-001') -or -not $markdownText.Contains('sample.csv')) {
            throw 'Self-test failed: exported markdown omitted expected authority values.'
        }

        $jsonObject = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        if ([string]$jsonObject.authority_id_hits[0].id -ne 'DATA-001') {
            throw 'Self-test failed: JSON authority hit was not preserved.'
        }

        Write-Host 'SELF-TEST: PASS'
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath

    if ([string]::IsNullOrWhiteSpace($WorkbookPath)) {
        $WorkbookPath = Join-Path $RepoRoot 'CFA-SoT.xlsx'
    }
    if ([string]::IsNullOrWhiteSpace($MarkdownPath)) {
        $MarkdownPath = Join-Path $RepoRoot 'docs\evidence\sot-authority-snapshot.md'
    }
    if ([string]::IsNullOrWhiteSpace($JsonPath)) {
        $JsonPath = Join-Path $RepoRoot 'docs\evidence\sot-authority-snapshot.json'
    }

    if (-not (Test-Path -LiteralPath $WorkbookPath -PathType Leaf)) {
        throw "CFA SoT workbook not found: $WorkbookPath"
    }

    $result = Export-AuthoritySnapshot -InputWorkbook $WorkbookPath -OutputMarkdown $MarkdownPath -OutputJson $JsonPath
    Write-Host "CFA SoT SHA-256: $($result.workbook_sha256)"
    Write-Host "Sheets exported: $($result.sheet_count)"
    Write-Host "Authority ID hits: $($result.authority_hit_count)"
    Write-Host "Markdown snapshot: $MarkdownPath"
    Write-Host "JSON snapshot: $JsonPath"
    Write-Host 'CFA SOT AUTHORITY EXPORT: PASS'
}
catch {
    Write-Host 'CFA SOT AUTHORITY EXPORT: FAIL'
    Write-Host $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) { Write-Host $_.ScriptStackTrace }
    exit 1
}
