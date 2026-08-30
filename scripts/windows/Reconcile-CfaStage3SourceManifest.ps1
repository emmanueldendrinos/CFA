#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MigrationReceiptRoot = 'D:\CFA-recovery\migration\20260829-184015-ba57875c',
    [string]$OutputRoot = 'D:\CFA-recovery\stage3-source-reconciliation',
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$DatabaseName = 'cfa',
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
    param([string]$PsqlExe,[string]$Database,[string]$Sql)
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
        return $text.Trim()
    }
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PsqlCsv {
    param([string]$PsqlExe,[string]$Database,[string]$Query)
    $q = $Query.Trim()
    while ($q.EndsWith(';')) { $q = $q.Substring(0,$q.Length-1).TrimEnd() }
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Get-ObjectKeyFromPath {
    param([string]$Path)
    $name = [System.IO.Path]::GetFileName([string]$Path)
    $m = [regex]::Match($name,'^(\d{14})\.gkg\.csv\.zip$')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

function Convert-ManifestRows {
    param([object[]]$Rows)
    $result = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        $key = Get-ObjectKeyFromPath ([string]$r.relative_path)
        if ($null -eq $key) { continue }
        [void]$result.Add([pscustomobject]@{
            object_key = $key
            relative_path = [string]$r.relative_path
            size_bytes = [long]$r.size_bytes
            sha256 = ([string]$r.sha256).ToLowerInvariant()
        })
    }
    return @($result.ToArray())
}

function Compare-SourceRecords {
    param([object[]]$Manifest,[object[]]$DatabaseRows)
    $errors = New-Object System.Collections.ArrayList
    if ($Manifest.Count -ne 7163) { [void]$errors.Add("Manifest archive count $($Manifest.Count) != 7163") }
    if ($DatabaseRows.Count -ne 7163) { [void]$errors.Add("Database downloaded archive count $($DatabaseRows.Count) != 7163") }

    $manifestByKey = @{}
    foreach ($m in $Manifest) {
        $key = [string]$m.object_key
        if ($manifestByKey.ContainsKey($key)) { [void]$errors.Add("Duplicate manifest key: $key"); continue }
        $manifestByKey[$key] = $m
    }

    $dbByKey = @{}
    foreach ($d in $DatabaseRows) {
        $key = [string]$d.object_key
        if ($dbByKey.ContainsKey($key)) { [void]$errors.Add("Duplicate database key: $key"); continue }
        $dbByKey[$key] = $d
    }

    foreach ($key in @($manifestByKey.Keys | Sort-Object)) {
        if (-not $dbByKey.ContainsKey($key)) { [void]$errors.Add("Missing database key: $key"); continue }
        $m = $manifestByKey[$key]
        $d = $dbByKey[$key]
        if ([long]$m.size_bytes -ne [long]$d.observed_size_bytes) { [void]$errors.Add("Size mismatch $key manifest=$($m.size_bytes) db=$($d.observed_size_bytes)") }
        if ([string]::IsNullOrWhiteSpace([string]$d.payload_sha256)) { [void]$errors.Add("NULL database SHA-256: $key") }
        elseif (([string]$m.sha256).ToLowerInvariant() -ne ([string]$d.payload_sha256).ToLowerInvariant()) { [void]$errors.Add("SHA-256 mismatch: $key") }
    }
    foreach ($key in @($dbByKey.Keys | Sort-Object)) {
        if (-not $manifestByKey.ContainsKey($key)) { [void]$errors.Add("Database key absent from manifest: $key") }
    }

    return [pscustomobject]@{
        status = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
        manifest_count = $Manifest.Count
        database_count = $DatabaseRows.Count
        error_count = $errors.Count
        errors = @($errors.ToArray())
    }
}

function Find-GdeltManifest {
    param([string]$ReceiptRoot)
    if (-not (Test-Path -LiteralPath $ReceiptRoot -PathType Container)) { throw "Migration receipt root missing: $ReceiptRoot" }
    $candidates = @(Get-ChildItem -LiteralPath $ReceiptRoot -File -Filter '*-destination-manifest.csv' -ErrorAction Stop | Sort-Object Name)
    foreach ($file in $candidates) {
        $rows = @(Import-Csv -LiteralPath $file.FullName)
        $archives = @(Convert-ManifestRows -Rows $rows)
        if ($archives.Count -eq 7163) {
            return [pscustomobject]@{ file=$file; archives=$archives }
        }
    }
    throw 'No destination manifest containing exactly 7,163 GDELT archive rows was found.'
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-SelfTest {
    $manifest = New-Object System.Collections.ArrayList
    $db = New-Object System.Collections.ArrayList
    for ($i=0; $i -lt 7163; $i++) {
        $key = (20250401000000L + $i).ToString()
        $hash = ('a' * 60) + ($i % 10000).ToString('0000')
        [void]$manifest.Add([pscustomobject]@{object_key=$key;size_bytes=100+$i;sha256=$hash})
        [void]$db.Add([pscustomobject]@{object_key=$key;observed_size_bytes=100+$i;payload_sha256=$hash})
    }
    $ok = Compare-SourceRecords -Manifest @($manifest.ToArray()) -DatabaseRows @($db.ToArray())
    if ($ok.status -ne 'PASS') { throw 'Matching manifest/database self-test should PASS.' }
    $db[12].payload_sha256 = 'b' * 64
    $bad = Compare-SourceRecords -Manifest @($manifest.ToArray()) -DatabaseRows @($db.ToArray())
    if ($bad.status -ne 'FAIL' -or $bad.error_count -lt 1) { throw 'Hash corruption self-test should FAIL.' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

$oldPassword = $env:PGPASSWORD
$bstr = [IntPtr]::Zero
try {
    $manifestSelection = Find-GdeltManifest -ReceiptRoot $MigrationReceiptRoot
    Write-Host "Migration manifest: $($manifestSelection.file.FullName)"
    Write-Host "Manifest GDELT archives: $($manifestSelection.archives.Count)"

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    $csv = Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT object_key, observed_size_bytes, payload_sha256, local_relative_path
FROM source_news.source_slots
WHERE status='downloaded'
ORDER BY object_key
"@
    $dbRows = @($csv | ConvertFrom-Csv)
    $result = Compare-SourceRecords -Manifest @($manifestSelection.archives) -DatabaseRows $dbRows

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $runDir = Join-Path $OutputRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $summary = [ordered]@{
        status = $result.status
        migration_manifest = $manifestSelection.file.FullName
        manifest_archives = $result.manifest_count
        database_downloaded_archives = $result.database_count
        mismatch_count = $result.error_count
        mismatches = @($result.errors | Select-Object -First 100)
        database = $DatabaseName
        source_relation = 'source_news.source_slots'
    }
    Write-Utf8NoBom -Path (Join-Path $runDir 'stage3-source-reconciliation.json') -Content (($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    Write-Host ''
    Write-Host "CFA STAGE 3 SOURCE MANIFEST RECONCILIATION: $($result.status)"
    Write-Host "Manifest archives: $($result.manifest_count)"
    Write-Host "Database downloaded archives: $($result.database_count)"
    Write-Host "Mismatches: $($result.error_count)"
    Write-Host "Evidence directory: $runDir"
    if ($result.status -ne 'PASS') { exit 2 }
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 SOURCE MANIFEST RECONCILIATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
}
