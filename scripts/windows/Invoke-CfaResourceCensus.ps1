#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ManifestPath = 'config/quarters/2026Q1.json',
    [string]$KrakenRoot = '',
    [string]$EvidenceRoot = '',
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$MaintenanceDatabase = 'postgres',
    [string]$PsqlPath = '',
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:issues = New-Object 'System.Collections.Generic.List[object]'
$script:fileCount = 0L

function Add-Issue([string]$Scope,[string]$Target,[string]$Reason) {
    $script:issues.Add([pscustomobject]@{scope=$Scope;target=$Target;status='FAIL';reason=$Reason})
}
function Write-Json([string]$Path,[object]$Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 30
    [IO.File]::WriteAllText($Path,$json,(New-Object Text.UTF8Encoding($false)))
}
function Get-Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-CanonicalSha([string]$Path) {
    $utf8 = New-Object Text.UTF8Encoding($false,$true)
    $s = $utf8.GetString([IO.File]::ReadAllBytes($Path)).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($s))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A required path is empty.' }
    return [IO.Path]::GetFullPath($Path)
}
function Test-Under([string]$Child,[string]$Parent) {
    $p = (Get-FullPath $Parent).TrimEnd([char[]]@('/','\'))
    $c = (Get-FullPath $Child).TrimEnd([char[]]@('/','\'))
    return ($c.Equals($p,[StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($p+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))
}
function Assert-Root([string]$Path) {
    $full = Get-FullPath $Path
    if ($full.TrimEnd([char[]]@('/','\')) -eq [IO.Path]::GetPathRoot($full).TrimEnd([char[]]@('/','\'))) { throw 'A volume root is not an allowed census target.' }
    $ancestor = $full
    while (-not [string]::IsNullOrEmpty($ancestor)) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse-point ancestor is not allowed: $ancestor"
            }
        }
        $parent = ([IO.DirectoryInfo]::new($ancestor)).Parent
        if ($null -eq $parent) { break }
        $ancestor = $parent.FullName
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer) { throw "Census root is not a directory: $full" }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse-point root is not allowed: $full" }
    }
    return $full
}
function Find-Psql {
    if (-not [string]::IsNullOrWhiteSpace($PsqlPath)) {
        if (-not (Test-Path -LiteralPath $PsqlPath -PathType Leaf)) { throw 'Specified psql executable is missing.' }
        return (Resolve-Path -LiteralPath $PsqlPath).ProviderPath
    }
    foreach ($name in @('psql.exe','psql')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { return $cmd.Source }
    }
    if ($env:OS -eq 'Windows_NT') {
        $found = @(Get-ChildItem -Path 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if ($found.Count -gt 0) { return $found[0].FullName }
    }
    throw 'psql executable was not found.'
}
function Invoke-CatalogJson([string]$Psql,[string]$Database,[string]$Query) {
    # A database name is a literal environment value, never an expandable -d conninfo.
    $env:PGDATABASE = $Database
    $env:PGHOST = $PgHost
    $env:PGPORT = [string]$PgPort
    $env:PGUSER = $PgUser
    $errPath = [IO.Path]::GetTempFileName()
    try {
        $sql = "BEGIN READ ONLY; SET LOCAL search_path = pg_catalog; $Query; COMMIT;"
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $out = @(& $Psql -X -w -A -t -q -v ON_ERROR_STOP=1 -c $sql 2>$errPath)
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previous }
        if ($code -ne 0) { throw "Catalog query failed (psql exit $code). Check local server, credentials, and database access; server diagnostics are not exported." }
        $text = ($out | ForEach-Object {[string]$_}) -join "`n"
        try { $parsed = $text | ConvertFrom-Json } catch { throw 'PostgreSQL returned malformed catalog JSON.' }
        if ($null -eq $parsed -or $null -eq $parsed.PSObject.Properties['read_only'] -or [string]$parsed.read_only -cne 'on') {
            throw 'PostgreSQL did not prove transaction_read_only=on.'
        }
        return $parsed
    } finally { Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue }
}
function Add-FileRow([IO.StreamWriter]$Writer,[object]$Row) {
    $Writer.WriteLine((ConvertTo-Json -InputObject $Row -Depth 6 -Compress))
    $script:fileCount++
    if (($script:fileCount % 100) -eq 0) { Write-Host ("Inventoried {0} files; hashing continues..." -f $script:fileCount) }
}
function Get-FileObservation([IO.FileInfo]$File,[string]$RootId,[string]$Root) {
    $row = [ordered]@{root_id=$RootId;relative_path=$File.FullName.Substring($Root.TrimEnd([char[]]@('/','\')).Length+1);length_bytes=$null;last_write_utc=$null;sha256=$null;status='FAIL'}
    try {
        $File.Refresh()
        $length = $File.Length
        $ticks = $File.LastWriteTimeUtc.Ticks
        $row.length_bytes = $length
        $row.last_write_utc = $File.LastWriteTimeUtc.ToString('o')
        if ($length -gt 134217728) { Write-Host ("Hashing large file: {0} ({1} bytes)" -f $File.Name,$length) }
        $stream = [IO.File]::Open($File.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
            finally { $sha.Dispose() }
        } finally { $stream.Dispose() }
        $File.Refresh()
        if ($File.Length -ne $length -or $File.LastWriteTimeUtc.Ticks -ne $ticks) { throw 'File changed during hashing.' }
        $row.sha256 = $hash
        $row.status = 'PASS'
    } catch { Add-Issue 'FILE' ($RootId+':'+$row.relative_path) 'Unable to obtain a stable readable file hash.' }
    return [pscustomobject]$row
}
function Invoke-FileInventory([string]$Root,[string]$RootId,[string]$Exclude,[IO.StreamWriter]$Writer) {
    $before = $script:issues.Count
    $beforeCount = $script:fileCount
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Add-Issue 'ROOT' $RootId 'Confirmed root is missing.'
    } else {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop()
            try { $items = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) }
            catch { Add-Issue 'DIRECTORY' $directory 'Directory could not be enumerated.'; continue }
            foreach ($item in $items) {
                if (Test-Under $item.FullName $Exclude) { continue }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    Add-Issue 'REPARSE_POINT' $item.FullName 'Not followed; discovery is incomplete at this boundary.'
                    continue
                }
                if ($item.PSIsContainer) { $stack.Push($item.FullName) }
                else { Add-FileRow $Writer (Get-FileObservation $item $RootId $Root) }
            }
        }
    }
    return [pscustomobject]@{id=$RootId;path=$Root;status=$(if($script:issues.Count -eq $before){'PASS'}else{'FAIL'});files_count=($script:fileCount-$beforeCount)}
}
function Invoke-SelfTests {
    if (-not (Test-Under (Join-Path ([IO.Path]::GetTempPath()) 'alpha/b') (Join-Path ([IO.Path]::GetTempPath()) 'alpha'))) { throw 'Containment positive test failed.' }
    if (Test-Under (Join-Path ([IO.Path]::GetTempPath()) 'alpha-other') (Join-Path ([IO.Path]::GetTempPath()) 'alpha')) { throw 'Containment sibling test failed.' }
    $temp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($temp,"a`r`nb`r`n",(New-Object Text.UTF8Encoding($true)))
        if ((Get-CanonicalSha $temp) -cne '911169ddaaf146aff539f58c26c489af3b892dff0fe283c1c264c65ae5aa59a2') { throw 'Canonical hash test failed.' }
        $row = Get-FileObservation (Get-Item -LiteralPath $temp) 'TEST' ([IO.Path]::GetDirectoryName($temp))
        $roundtrip = ConvertTo-Json -InputObject @($row) -Depth 6 | ConvertFrom-Json
        if (@($roundtrip).Count -ne 1 -or $row.status -cne 'PASS' -or $row.sha256 -cne (Get-Sha $temp)) { throw 'File hash/JSON array test failed.' }
        $encoded = ConvertTo-Json -InputObject ([pscustomobject]@{relative_path=("space [] ' " + [char]0x03B1 + '.csv');sha256=$null}) -Compress
        $decoded = $encoded | ConvertFrom-Json
        if ($decoded.relative_path -cne ("space [] ' " + [char]0x03B1 + '.csv') -or $null -ne $decoded.sha256) { throw 'JSONL quoting/Unicode/null roundtrip failed.' }
        $script:issues.Clear()
    } finally { Remove-Item -LiteralPath $temp -Force }
    Write-Host 'CENSUS SELF-TEST: PASS'
}
if ($SelfTest) { try { Invoke-SelfTests; exit 0 } catch { Write-Error $_; exit 1 } }

$saved = @{}
foreach ($name in @('PGPASSWORD','PGOPTIONS','PGCONNECT_TIMEOUT','PGCLIENTENCODING','PGDATABASE','PGHOST','PGPORT','PGUSER','PGSERVICE','PGSERVICEFILE','PGHOSTADDR')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
$exitCode = 1
$runDir = $null
$writer = $null
$bstr = [IntPtr]::Zero
$oldConsoleEncoding = [Console]::OutputEncoding
$oldOutputEncoding = $OutputEncoding
try {
    foreach ($name in @('PGSERVICE','PGSERVICEFILE','PGHOSTADDR')) { Remove-Item -LiteralPath ('Env:'+ $name) -ErrorAction SilentlyContinue }
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $OutputEncoding = New-Object Text.UTF8Encoding($false)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '../..' }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if (-not [IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath = Join-Path $RepoRoot $ManifestPath }
    $ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).ProviderPath
    $engine = (Get-Process -Id $PID).Path
    & $engine -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'scripts/windows/Invoke-CfaQuarterBootstrap.ps1') -RepoRoot $RepoRoot -ManifestPath $ManifestPath -NoWrite | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Bootstrap validation failed; no census was attempted.' }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $quarter = [string]$manifest.quarter_id
    $manifestSha = Get-CanonicalSha $ManifestPath
    $sotSha = Get-Sha (Join-Path $RepoRoot ([string]$manifest.authority.sot_path))
    $head = @(& git -C $RepoRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $head.Count -ne 1) { throw 'Cannot identify repository HEAD.' }
    if ([string]::IsNullOrWhiteSpace($PgHost) -or [string]::IsNullOrWhiteSpace($PgUser) -or [string]::IsNullOrWhiteSpace($MaintenanceDatabase)) { throw 'PostgreSQL host/user/maintenance database must not be empty.' }
    if (-not [string]::IsNullOrWhiteSpace($PsqlPath) -and -not (Test-Path -LiteralPath $PsqlPath -PathType Leaf)) { throw 'Specified psql executable is missing.' }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($KrakenRoot)) { $KrakenRoot = Join-Path $documents 'Projects/Kraken' }
    if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot = Join-Path $documents 'CFA-local' }
    $KrakenRoot = Assert-Root $KrakenRoot
    $EvidenceRoot = Assert-Root $EvidenceRoot
    if ((Test-Under $KrakenRoot $EvidenceRoot) -or (Test-Under $EvidenceRoot $KrakenRoot)) { throw 'Input roots must not overlap.' }
    if ((Test-Under $EvidenceRoot $RepoRoot) -or (Test-Under $RepoRoot $EvidenceRoot)) { throw 'Evidence root must not overlap the repository.' }
    if ((Test-Under $KrakenRoot $RepoRoot) -or (Test-Under $RepoRoot $KrakenRoot)) { throw 'Kraken root must not overlap the repository.' }
    $evidenceExisted = Test-Path -LiteralPath $EvidenceRoot -PathType Container
    $exclude = Join-Path $EvidenceRoot 'resource-census'
    if (Test-Path -LiteralPath $exclude) { Assert-Root $exclude | Out-Null }
    $quarterOutput = Join-Path $exclude $quarter
    if (Test-Path -LiteralPath $quarterOutput) { Assert-Root $quarterOutput | Out-Null }
    $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N')
    $runDir = Join-Path $quarterOutput $runId
    New-Item -ItemType Directory -Path $runDir -ErrorAction Stop | Out-Null
    Write-Host "Evidence directory: $runDir"
    Write-Host 'Reading all files in the confirmed roots; large archives can take time to hash.'
    $started = [DateTime]::UtcNow.ToString('o')
    $writer = [IO.StreamWriter]::new((Join-Path $runDir 'files.jsonl'),$false,(New-Object Text.UTF8Encoding($false)))
    $roots = @()
    try {
        $roots += Invoke-FileInventory $KrakenRoot 'KRAKEN' $exclude $writer
        if ($evidenceExisted) { $roots += Invoke-FileInventory $EvidenceRoot 'CFA_LOCAL' $exclude $writer }
        else {
            Add-Issue 'ROOT' 'CFA_LOCAL' 'Confirmed root was missing before creation of the evidence output directory.'
            $roots += [pscustomobject]@{id='CFA_LOCAL';path=$EvidenceRoot;status='FAIL';files_count=0}
        }
    } finally { $writer.Dispose(); $writer = $null }

    $catalogs = New-Object 'System.Collections.Generic.List[object]'
    $dbQuery = @'
SELECT json_build_object('read_only',current_setting('transaction_read_only'),
 'databases',COALESCE((SELECT json_agg(d ORDER BY d.database_name) FROM
 (SELECT datname AS database_name, datallowconn AS allow_connections
  FROM pg_database WHERE NOT datistemplate) d),'[]'::json))
'@
    $catalogQuery = @'
SELECT json_build_object(
 'database_name',current_database(), 'server_version',current_setting('server_version'),
 'read_only',current_setting('transaction_read_only'), 'status','PASS',
 'schemas',COALESCE((SELECT json_agg(s ORDER BY s.schema_name) FROM
  (SELECT nspname AS schema_name FROM pg_namespace
   WHERE nspname <> 'information_schema' AND left(nspname,3) <> 'pg_') s),'[]'::json),
 'relations',COALESCE((SELECT json_agg(r ORDER BY r.schema_name,r.relation_name) FROM
  (SELECT n.nspname AS schema_name,c.relname AS relation_name,c.relkind AS relation_kind,
   CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END AS estimated_rows
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname <> 'information_schema' AND left(n.nspname,3) <> 'pg_'
   AND c.relkind IN ('r','p','v','m','f')) r),'[]'::json),
 'columns',COALESCE((SELECT json_agg(a ORDER BY a.schema_name,a.relation_name,a.ordinal_position) FROM
  (SELECT n.nspname AS schema_name,c.relname AS relation_name,a.attname AS column_name,
   a.attnum AS ordinal_position,format_type(a.atttypid,a.atttypmod) AS data_type,a.attnotnull AS not_null
   FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE a.attnum>0 AND NOT a.attisdropped AND n.nspname <> 'information_schema'
   AND left(n.nspname,3) <> 'pg_' AND c.relkind IN ('r','p','v','m','f')) a),'[]'::json))
'@
    try {
        $psql = Find-Psql
        if ([string]::IsNullOrEmpty($env:PGPASSWORD)) {
            $secure = Read-Host "PostgreSQL password for '$PgUser' (not stored in evidence)" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr); $bstr = [IntPtr]::Zero
        }
        $env:PGOPTIONS = '-c default_transaction_read_only=on -c statement_timeout=60000 -c lock_timeout=5000'
        $env:PGCONNECT_TIMEOUT = '5'
        $env:PGCLIENTENCODING = 'UTF8'
        $discovery = Invoke-CatalogJson $psql $MaintenanceDatabase $dbQuery
        if ($null -eq $discovery.PSObject.Properties['databases'] -or @($discovery.databases).Count -eq 0) { throw 'No non-template databases were returned.' }
        foreach ($db in @($discovery.databases)) {
            $dbName = [string]$db.database_name
            Write-Host "Inspecting PostgreSQL catalogs: $dbName"
            try {
                if (-not [bool]$db.allow_connections) { throw 'Database disallows connections.' }
                $result = Invoke-CatalogJson $psql $dbName $catalogQuery
                if ([string]$result.database_name -cne $dbName) { throw 'Connected database identity did not match the discovered name.' }
                foreach ($field in @('schemas','relations','columns','server_version')) {
                    if ($null -eq $result.PSObject.Properties[$field]) { throw "Missing catalog field: $field" }
                }
                $catalogs.Add($result)
            } catch {
                Add-Issue 'DATABASE' $dbName $_.Exception.Message
                $catalogs.Add([pscustomobject]@{database_name=$dbName;status='FAIL';schemas=@();relations=@();columns=@();read_only=$null;server_version=$null})
            }
        }
    } catch { Add-Issue 'POSTGRESQL' $PgHost $_.Exception.Message }
    Write-Json (Join-Path $runDir 'catalogs.json') @($catalogs.ToArray())
    Write-Json (Join-Path $runDir 'errors.json') @($script:issues.ToArray())
    $artifacts = @()
    foreach ($file in @('files.jsonl','catalogs.json','errors.json')) {
        $path = Join-Path $runDir $file
        $artifacts += [pscustomobject]@{path=$file;sha256=(Get-Sha $path);bytes=(Get-Item -LiteralPath $path).Length}
    }
    $receipt = [ordered]@{
        schema='cfa.resource-census/v1';task_id='Q1-RES-001';quarter_id=$quarter;run_id=$runId;
        started_utc=$started;finished_utc=[DateTime]::UtcNow.ToString('o');
        collection_status=$(if($script:issues.Count -eq 0){'PASS'}else{'FAIL'});
        task_status='UNVERIFIED';stage1_status='BLOCKED';
        manifest_sha256=$manifestSha;manifest_canonicalization='UTF8_LF_NO_BOM';sot_sha256=$sotSha;
        repository_head=([string]$head[0]).Trim();runner_sha256=(Get-Sha $PSCommandPath);
        runner_hash_policy='EXACT_LOCAL_BYTES';powershell_version=$PSVersionTable.PSVersion.ToString();
        roots=$roots;output_exclusion=$exclude;files_count=$script:fileCount;errors_count=$script:issues.Count;
        postgres=[ordered]@{host=$PgHost;port=$PgPort;user=$PgUser;maintenance_database=$MaintenanceDatabase;database_count=$catalogs.Count;read_only_required=$true};
        estimated_rows_policy='pg_class.reltuples catalog estimate only; negative means unknown; never exact row counts';
        coverage_status='UNVERIFIED';artifacts=$artifacts
    }
    $receiptPath = Join-Path $runDir 'receipt.json'
    Write-Json $receiptPath $receipt
    Write-Host "Collection: $($receipt.collection_status); Q1-RES-001: UNVERIFIED; Stage 1: BLOCKED"
    Write-Host "Receipt: $receiptPath"
    Write-Host "Receipt SHA-256: $(Get-Sha $receiptPath)"
    $exitCode = if ($script:issues.Count -eq 0) { 0 } else { 2 }
} catch {
    Write-Host 'CENSUS: FAIL'
    Write-Host $_.Exception.Message
    if ($null -ne $runDir) {
        $exitCode = 2
        Add-Issue 'RUN' 'census' 'Unexpected collection failure; incomplete evidence must not be accepted.'
        try { Write-Json (Join-Path $runDir 'failure.json') @($script:issues.ToArray()) } catch { }
    }
} finally {
    if ($null -ne $writer) { $writer.Dispose() }
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) { Remove-Item -LiteralPath ('Env:'+ $name) -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
    }
    [Console]::OutputEncoding = $oldConsoleEncoding
    $OutputEncoding = $oldOutputEncoding
}
exit $exitCode
