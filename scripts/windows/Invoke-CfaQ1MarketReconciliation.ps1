#requires -Version 5.1
[CmdletBinding()]
param(
 [string]$RepoRoot='', [string]$CensusDirectory='', [string]$CoverageDirectory='',
 [string]$ExpectedCensusReceiptSha256='b0f00361efba3a6737bae8480b4e5b64a4a3b827acaeb4df223f8457a6605023',
 [string]$ExpectedCoverageReceiptSha256='0e3b551dbc5d5be7e9b85288922d5c3d05051b9337adad92fd5d3d59e4013a35',
 [string]$PgHost='localhost', [ValidateRange(1,65535)][int]$PgPort=5432,
 [string]$PgUser='postgres', [string]$PsqlPath='',
 [ValidateRange(5,3600)][int]$StatementTimeoutSeconds=900, [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:Utf8 = New-Object Text.UTF8Encoding($false,$true)
$script:Issues = New-Object 'System.Collections.Generic.List[object]'
$script:Checks = New-Object 'System.Collections.Generic.List[object]'

function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-Json([string]$Path,[object]$Value) {
    [IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 40),$script:Utf8)
}
function Read-Json([string]$Path) {
    # Wrapping preserves [] as an actual array on Windows PowerShell 5.1.
    $text = [IO.File]::ReadAllText($Path,$script:Utf8)
    $wrapper = ('{"value":' + $text + '}') | ConvertFrom-Json
    return ,$wrapper.value
}
function Require([bool]$Condition,[string]$Reason) { if (-not $Condition) { throw $Reason } }
function Add-Issue([string]$Scope,[string]$Reason) {
    $script:Issues.Add([pscustomobject]@{scope=$Scope;status='FAIL';reason=$Reason})
}
function Add-Check([string]$Id,[bool]$Condition,[string]$Reason) {
    $script:Checks.Add([pscustomobject]@{id=$Id;status=$(if($Condition){'PASS'}else{'FAIL'});reason=$Reason})
}
function Test-Under([string]$Child,[string]$Parent) {
    $c=[IO.Path]::GetFullPath($Child).TrimEnd([char[]]@('/','\'))
    $p=[IO.Path]::GetFullPath($Parent).TrimEnd([char[]]@('/','\'))
    return ($c.Equals($p,[StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($p+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))
}
function Assert-SafePath([string]$Path) {
    Require (-not [string]::IsNullOrWhiteSpace($Path)) 'A required path is empty.'
    $full=[IO.Path]::GetFullPath($Path)
    Require ($full.TrimEnd([char[]]@('/','\')) -ne [IO.Path]::GetPathRoot($full).TrimEnd([char[]]@('/','\'))) 'Volume-root targets are not allowed.'
    $a=$full
    while (-not [string]::IsNullOrEmpty($a)) {
        if (Test-Path -LiteralPath $a) {
            Require (-not ((Get-Item -LiteralPath $a -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse-point targets or ancestors are not allowed.'
        }
        $parent=([IO.DirectoryInfo]::new($a)).Parent
        if ($null -eq $parent) { break }; $a=$parent.FullName
    }
    return $full
}
function Get-CanonicalSha([string]$Path) {
    $text=[IO.File]::ReadAllText($Path,$script:Utf8).TrimStart([char]0xFEFF).Replace("`r`n","`n").Replace("`r","`n")
    $h=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($h.ComputeHash($script:Utf8.GetBytes($text))).Replace('-','').ToLowerInvariant() }
    finally { $h.Dispose() }
}
function Find-Psql {
    if (-not [string]::IsNullOrWhiteSpace($PsqlPath)) {
        Require (Test-Path -LiteralPath $PsqlPath -PathType Leaf) 'Specified psql executable is missing.'
        return (Resolve-Path -LiteralPath $PsqlPath).ProviderPath
    }
    foreach($name in @('psql.exe','psql')) {
        $cmd=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if($null -ne $cmd){return $cmd.Source}
    }
    if($env:OS -eq 'Windows_NT') {
        $found=@(Get-ChildItem -Path 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if($found.Count -gt 0){return $found[0].FullName}
    }
    throw 'psql executable was not found.'
}
function Quote-Native([AllowEmptyString()][string]$Value) {
    $s=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $s=[regex]::Replace($s,'(\\+)$','$1$1')
    return '"'+$s+'"'
}
function Hold-Evidence([string]$Path) {
    $safe=Assert-SafePath $Path
    if(-not $script:EvidenceLocks.ContainsKey($safe)) {
        $script:EvidenceLocks[$safe]=[IO.File]::Open($safe,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    }
}
function Initialize-Reconciliation {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.Numerics
    if($null -eq ('CfaQ1Reconciliation.MarketReconciler' -as [type])) {
        $helper=Join-Path $PSScriptRoot 'CfaQ1MarketReconciliation.cs'
        if($PSVersionTable.PSEdition -eq 'Desktop') {
            Add-Type -Path $helper -ReferencedAssemblies @('System.dll','System.Core.dll','System.Numerics.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll')
        } else { Add-Type -Path $helper }
    }
}
function New-Q1SnapshotDiagnostic {
    return [pscustomobject][ordered]@{runner_phase='PREPARE';sql_phase='NOT_STARTED';failure_class='UNKNOWN';sqlstate=$null;process_exit_code=$null;elapsed_ms=0L;stdout_bytes=0L;stderr_bytes=0L}
}
function Get-Q1SnapshotSqlPhases {
    return @('SESSION_SETUP','SCHEMA_INITIAL','LOCK_PAIRS','LOCK_ARCHIVES','LOCK_RUNS','LOCK_MARKET','SCHEMA_RECHECK','SCHEMA_TRANSPORT','MARKET_PREVALIDATION','MARKET_TRANSPORT','DIGESTS','COMMIT')
}
function Get-Q1SnapshotErrorDiagnostic([AllowEmptyString()][string]$StandardError,[Nullable[int]]$ExitCode) {
    # No input text, exception text or inferred SQLSTATE may leave this function.
    $classes=@{
        '08000'='CONNECTION_FAILURE';'08001'='CONNECTION_FAILURE';'08003'='CONNECTION_FAILURE';'08004'='CONNECTION_FAILURE';'08006'='CONNECTION_FAILURE';'08007'='CONNECTION_FAILURE';'08P01'='CONNECTION_FAILURE'
        '28000'='AUTHENTICATION_REJECTED';'28P01'='AUTHENTICATION_REJECTED'
        '42501'='SQL_ACCESS_DENIED';'55P03'='SQL_LOCK_TIMEOUT';'57014'='SQL_CANCELED'
        '53100'='SQL_RESOURCE_FAILURE';'53200'='SQL_RESOURCE_FAILURE';'53300'='SQL_RESOURCE_FAILURE';'53400'='SQL_RESOURCE_FAILURE';'54000'='SQL_RESOURCE_FAILURE';'54001'='SQL_RESOURCE_FAILURE';'54011'='SQL_RESOURCE_FAILURE';'58030'='SQL_RESOURCE_FAILURE'
        '42601'='SQL_QUERY_ERROR';'42703'='SQL_QUERY_ERROR';'42804'='SQL_QUERY_ERROR';'42883'='SQL_QUERY_ERROR';'42P01'='SQL_QUERY_ERROR';'42P02'='SQL_QUERY_ERROR';'22003'='SQL_DATA_ERROR';'22007'='SQL_DATA_ERROR';'22008'='SQL_DATA_ERROR';'22012'='SQL_DATA_ERROR';'22P02'='SQL_DATA_ERROR';'25P02'='SQL_TRANSACTION_ERROR';'25006'='SQL_TRANSACTION_ERROR'
        '57P01'='SERVER_UNAVAILABLE';'57P02'='SERVER_UNAVAILABLE';'57P03'='SERVER_UNAVAILABLE';'3D000'='DATABASE_UNAVAILABLE';'XX000'='SQL_INTERNAL_ERROR'
    }
    # VERBOSITY=sqlstate emits severity and code only after connection. Require
    # that exact record shape; never mistake five characters in raw text for it.
    $records=[regex]::Matches($StandardError,'(?m)^(?:psql:<stdin>:[0-9]+: )?(?:ERROR|FATAL|PANIC):[ \t]+([0-9A-Z]{5})[ \t]*\r?$')
    foreach($record in $records) {
        $state=$record.Groups[1].Value
        if($classes.ContainsKey($state)){return [pscustomobject]@{failure_class=$classes[$state];sqlstate=$state}}
    }
    # Initial libpq failures are not governed by psql's SQLSTATE verbosity.
    # Recognize only fixed failure phrases and retain no matching text/code.
    $kind='UNKNOWN'
    if($ExitCode -ne 2){return [pscustomobject]@{failure_class=$kind;sqlstate=$null}}
    if($StandardError -match '(?im)(?:FATAL:[ \t]+(?:password authentication failed|no pg_hba\.conf entry)|fe_sendauth: no password supplied|authentication method .* not supported)') {$kind='AUTHENTICATION_REJECTED'}
    elseif($StandardError -match '(?im)(?:connection to server .* failed: Connection refused|could not connect to server: Connection refused|actively refused it)') {$kind='CONNECTION_REFUSED'}
    elseif($StandardError -match '(?im)(?:connection to server .* failed: timeout expired|timeout expired)') {$kind='CONNECTION_TIMEOUT'}
    elseif($StandardError -match '(?im)(?:could not translate host name .* to address|could not resolve host name)') {$kind='HOST_RESOLUTION_FAILED'}
    elseif($StandardError -match '(?im)(?:SSL error:|server does not support SSL, but SSL was required|certificate verify failed)') {$kind='TLS_FAILURE'}
    return [pscustomobject]@{failure_class=$kind;sqlstate=$null}
}
function Initialize-Q1SnapshotDrain {
    if($null -ne ('CfaQ1SnapshotTransport.ErrorDrain' -as [type])){return}
    # The private ring holds at most 64 KiB, drains the entire byte stream, and
    # never writes stderr to disk or console. UTF-8 errors cannot stop draining.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
namespace CfaQ1SnapshotTransport {
 public sealed class DrainResult { public string Text; public long Bytes; }
 public static class ErrorDrain {
  public static Task<DrainResult> Start(Stream source) {
   return Task.Factory.StartNew(() => {
    byte[] ring = new byte[65536], buffer = new byte[4096];
    int position = 0, count = 0, n; long bytes = 0;
    while ((n = source.Read(buffer, 0, buffer.Length)) != 0) {
     bytes += n;
     for (int i = 0; i < n; i++) { ring[position] = buffer[i]; position = (position + 1) % ring.Length; if (count < ring.Length) count++; }
    }
    byte[] tail = new byte[count]; int first = count == ring.Length ? position : 0;
    for (int i = 0; i < count; i++) tail[i] = ring[(first + i) % ring.Length];
    return new DrainResult { Text = new UTF8Encoding(false, false).GetString(tail), Bytes = bytes };
   }, System.Threading.CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
  }
 }
}
'@
}
function Read-Q1SnapshotRecord([IO.StreamReader]$Reader) {
    while($null -ne ($record=$Reader.ReadLine())) {
        if($record.StartsWith('Q1_PHASE_',[StringComparison]::Ordinal)) {
            $phase=$record.Substring(9)
            $phases=Get-Q1SnapshotSqlPhases
            Require ($phases -ccontains $phase) 'Unrecognized snapshot phase marker.'
            # The failure scan may already have observed COMMIT. Parsing an
            # earlier record must not make that completed SQL work disappear.
            if([Array]::IndexOf($phases,$phase) -gt [Array]::IndexOf($phases,$script:SnapshotDiagnostic.sql_phase)) {$script:SnapshotDiagnostic.sql_phase=$phase}
        } else {return $record}
    }
    return $null
}
function Read-Q1SnapshotProtocol([string]$Transport,[string]$Directory) {
    $script:SnapshotDiagnostic.runner_phase='OUTPUT_OPEN'
    $reader=$null
    $writer=$null; $schema=$null; $market=$null; $hasDigests=$false; $ended=$false; $blocked=$false
    try {
        $reader=[IO.StreamReader]::new($Transport,$script:Utf8,$false)
        $script:SnapshotDiagnostic.runner_phase='OUTPUT_PROTOCOL'
        $line=Read-Q1SnapshotRecord $reader
        Require ($null -ne $line -and $line.StartsWith("SCHEMA`t",[StringComparison]::Ordinal)) 'Missing schema record in snapshot.'
        $script:SnapshotDiagnostic.runner_phase='SCHEMA_JSON'
        $schema=$line.Substring(7) | ConvertFrom-Json
        $script:SnapshotDiagnostic.runner_phase='OUTPUT_WRITE'
        Write-Json (Join-Path $Directory 'schema.json') $schema
        $script:SnapshotDiagnostic.runner_phase='OUTPUT_PROTOCOL'
        Require ($schema.database_name -ceq 'srp' -and $schema.read_only -ceq 'on' -and $schema.transaction_isolation -ceq 'repeatable read' -and $schema.time_zone -ceq 'UTC') 'Snapshot database, isolation or UTC identity mismatch.'
        $line=Read-Q1SnapshotRecord $reader
        if($null -ne $line -and $line.StartsWith("MARKET`t",[StringComparison]::Ordinal)) {
            Require ($schema.schema_ok -eq $true) 'Market metadata followed a rejected schema.'
            $script:SnapshotDiagnostic.runner_phase='MARKET_JSON'
            $market=$line.Substring(7) | ConvertFrom-Json
            $script:SnapshotDiagnostic.runner_phase='OUTPUT_WRITE'
            Write-Json (Join-Path $Directory 'market.json') $market
            $script:SnapshotDiagnostic.runner_phase='OUTPUT_PROTOCOL'
            $line=Read-Q1SnapshotRecord $reader
        }
        if($line -ceq 'BLOCKED') {$blocked=$true; $line=Read-Q1SnapshotRecord $reader}
        elseif($line -ceq 'DIGESTS') {
            Require ($null -ne $market -and $market.prevalidation_ok -eq $true) 'Digests followed rejected market prevalidation.'
            $script:SnapshotDiagnostic.runner_phase='OUTPUT_WRITE'
            $writer=[IO.StreamWriter]::new((Join-Path $Directory 'market-digests.tsv'),$false,$script:Utf8)
            $writer.NewLine="`n"
            $script:SnapshotDiagnostic.runner_phase='OUTPUT_PROTOCOL'
            $line=Read-Q1SnapshotRecord $reader
            Require ($line -ceq "pair_id`tday_utc`trows`tmin_epoch`tmax_epoch`tsha256") 'Malformed fingerprint header.'
            $script:SnapshotDiagnostic.runner_phase='OUTPUT_WRITE'
            $writer.WriteLine($line); $hasDigests=$true
            $script:SnapshotDiagnostic.runner_phase='OUTPUT_PROTOCOL'
            while($null -ne ($line=Read-Q1SnapshotRecord $reader) -and $line -cne 'END') {
                $script:SnapshotDiagnostic.runner_phase='OUTPUT_WRITE';$writer.WriteLine($line)
                $script:SnapshotDiagnostic.runner_phase='OUTPUT_PROTOCOL'
            }
        }
        Require ($line -ceq 'END' -and $null -eq $reader.ReadLine()) 'Snapshot completion marker is missing or has trailing output.'
        $ended=$true
    } catch {
        $script:SnapshotDiagnostic.failure_class=if($script:SnapshotDiagnostic.runner_phase -in @('SCHEMA_JSON','MARKET_JSON')){'JSON_PARSE_FAILURE'}elseif($script:SnapshotDiagnostic.runner_phase -in @('OUTPUT_OPEN','OUTPUT_WRITE')){'OUTPUT_TRANSPORT_FAILURE'}else{'OUTPUT_PROTOCOL_FAILURE'}
        throw 'Snapshot output did not satisfy its protocol.'
    } finally {
        $cleanupFailed=$false
        if($null -ne $writer){try{$writer.Dispose()}catch{$cleanupFailed=$true}}
        if($null -ne $reader){try{$reader.Dispose()}catch{$cleanupFailed=$true}}
        try{Remove-Item -LiteralPath $Transport -Force -ErrorAction Stop}catch{$cleanupFailed=$true}
        if($cleanupFailed){$script:SnapshotDiagnostic.failure_class='OUTPUT_TRANSPORT_FAILURE';throw 'Snapshot transport cleanup failed.'}
    }
    Require ($ended) 'Incomplete market snapshot.'
    return [pscustomobject]@{schema=$schema;market=$market;has_digests=$hasDigests;blocked=$blocked}
}
function Invoke-MarketSnapshot([string]$Sql,[string]$Directory) {
    $script:SnapshotDiagnostic=New-Q1SnapshotDiagnostic
    Initialize-Q1SnapshotDrain
    # Only metadata, fingerprints and literal phase markers reach this file.
    $transport=Join-Path $Directory 'snapshot.partial'
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$script:ResolvedPsql
    $arguments=@('-X','-w','-A','-t','-q','-d','postgresql:///srp','-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate','-v','SHOW_CONTEXT=never','-f','-')
    $start.Arguments=(($arguments | ForEach-Object {Quote-Native $_}) -join ' ')
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=$script:Utf8; $start.StandardErrorEncoding=$script:Utf8
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    $output=$null; $transportComplete=$false; $startedProcess=$false; $stdout=$null; $stderr=$null; $inputTask=$null
    $watch=[Diagnostics.Stopwatch]::StartNew(); $deadline=($StatementTimeoutSeconds*4+30)*1000
    $writeFailed=$false; $timedOut=$false; $transportFailed=$false
    try {
        $script:SnapshotDiagnostic.runner_phase='OUTPUT_OPEN'
        $output=[IO.File]::Open($transport,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $script:SnapshotDiagnostic.runner_phase='PROCESS_START'
        Require ($process.Start()) 'Could not start the read-only market snapshot.'
        $startedProcess=$true
        $stdout=$process.StandardOutput.BaseStream.CopyToAsync($output)
        $stderr=[CfaQ1SnapshotTransport.ErrorDrain]::Start($process.StandardError.BaseStream)
        $bytes=$script:Utf8.GetBytes($Sql)
        $script:SnapshotDiagnostic.runner_phase='INPUT_WRITE'
        try {
            $inputTask=$process.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
            if(-not $inputTask.Wait([int][Math]::Max(0,($deadline-$watch.ElapsedMilliseconds)))) {$timedOut=$true}
        } catch {$writeFailed=$true}
        if($timedOut){try{$process.Kill();$process.WaitForExit()}catch{$transportFailed=$true}}
        try {$process.StandardInput.Close()}catch{$writeFailed=$true}
        if(-not $timedOut) {
            if(-not $writeFailed){$script:SnapshotDiagnostic.runner_phase='PROCESS_WAIT'}
            if(-not $process.WaitForExit([int][Math]::Max(0,($deadline-$watch.ElapsedMilliseconds)))) {$timedOut=$true}
        }
    } catch {$transportFailed=$true}
    finally {
        if($startedProcess) {
            try {if(-not $process.HasExited){$process.Kill()};$process.WaitForExit();$script:SnapshotDiagnostic.process_exit_code=$process.ExitCode}catch{$transportFailed=$true}
        }
        if($null -ne $inputTask){try{$null=$inputTask.GetAwaiter().GetResult()}catch{$writeFailed=$true}}
        if($null -ne $stdout){try{$null=$stdout.GetAwaiter().GetResult()}catch{$transportFailed=$true}}
        if($null -ne $stderr){
            try {
                $drained=$stderr.GetAwaiter().GetResult()
                $script:SnapshotDiagnostic.stderr_bytes=$drained.Bytes
                $safeError=Get-Q1SnapshotErrorDiagnostic $drained.Text $script:SnapshotDiagnostic.process_exit_code
                $script:SnapshotDiagnostic.failure_class=$safeError.failure_class
                $script:SnapshotDiagnostic.sqlstate=$safeError.sqlstate
                $drained.Text=$null
            } catch {$transportFailed=$true}
        }
        if($null -ne $output){
            try{$script:SnapshotDiagnostic.stdout_bytes=$output.Length}catch{$transportFailed=$true}
            try{$output.Dispose()}catch{$transportFailed=$true}
        }
        $watch.Stop();$script:SnapshotDiagnostic.elapsed_ms=$watch.ElapsedMilliseconds
        try{$process.Dispose()}catch{$transportFailed=$true}
    }
    try {
        if(Test-Path -LiteralPath $transport) {
            # Even a nonzero process can have reached later SQL phases. Scan
            # only literal markers; never accept partial result records here.
            $markerReader=[IO.StreamReader]::new($transport,(New-Object Text.UTF8Encoding($false,$false)),$false)
            try {while($null -ne ($marker=$markerReader.ReadLine())) {
                if($marker.StartsWith('Q1_PHASE_',[StringComparison]::Ordinal) -and (Get-Q1SnapshotSqlPhases) -ccontains $marker.Substring(9)) {$script:SnapshotDiagnostic.sql_phase=$marker.Substring(9)}
            }} finally {$markerReader.Dispose()}
        }
        if($timedOut){$script:SnapshotDiagnostic.failure_class='PROCESS_TIMEOUT'}
        elseif($script:SnapshotDiagnostic.failure_class -ceq 'UNKNOWN') {
            if(-not $startedProcess -and $script:SnapshotDiagnostic.runner_phase -ceq 'PROCESS_START'){$script:SnapshotDiagnostic.failure_class='PROCESS_START_FAILURE'}
            elseif($writeFailed){$script:SnapshotDiagnostic.failure_class='INPUT_TRANSPORT_FAILURE'}
            elseif($transportFailed){$script:SnapshotDiagnostic.failure_class='OUTPUT_TRANSPORT_FAILURE'}
        }
        Require (-not $timedOut -and -not $writeFailed -and -not $transportFailed -and $script:SnapshotDiagnostic.process_exit_code -eq 0) 'Read-only market snapshot failed.'
        $transportComplete=$true
    } finally {
        if(-not $transportComplete){Remove-Item -LiteralPath $transport -Force -ErrorAction SilentlyContinue}
    }
    return Read-Q1SnapshotProtocol $transport $Directory
}
function Inspect-InventoryReferences([object]$Market,[object[]]$CensusFiles,[hashtable]$Roots) {
    $items=New-Object 'System.Collections.Generic.List[object]'
    foreach($archive in $Market.source_archives) {
        foreach($field in @('inventory_json_path','inventory_csv_path')) {
            $item=[ordered]@{source_archive_id=$archive.source_archive_id;kind=$field;registered_path=$null;status='UNVERIFIED';reason='No inventory reference is recorded.';sha256=$null;bytes=$null;census_match=$false}
            $value=$archive.$field; $item.registered_path=$value
            if(-not [string]::IsNullOrWhiteSpace([string]$value)) {
                $item.reason='Reference is outside the preceding census or unavailable; it was not read.'
                try {
                    if([IO.Path]::IsPathRooted([string]$value)) {
                        $full=[IO.Path]::GetFullPath([string]$value)
                        $inventoryMatches=@($CensusFiles | Where-Object { (Join-Path $Roots[$_.root_id] $_.relative_path) -ieq $full })
                        if($inventoryMatches.Count -eq 1) {
                            $full=Assert-SafePath $full
                            Hold-Evidence $full
                            $item.sha256=Get-Sha $full; $item.bytes=(Get-Item -LiteralPath $full).Length
                            $item.census_match=($item.sha256 -ceq $inventoryMatches[0].sha256 -and $item.bytes -eq $inventoryMatches[0].length_bytes)
                            $item.status=if($item.census_match){'PASS'}else{'FAIL'}
                            $item.reason=if($item.census_match){'Exact inventory bytes match the census; historical content authority is still unverified.'}else{'Referenced inventory bytes differ from the census.'}
                        }
                    }
                } catch {$item.status='UNVERIFIED';$item.reason='Referenced inventory could not be safely read within the census scope.'}
            }
            $items.Add([pscustomobject]$item)
        }
    }
    return ,@($items.ToArray())
}

if($SelfTest) {
    try {Initialize-Reconciliation; Require ([CfaQ1Reconciliation.MarketReconciler]::SelfTest() -ceq 'PASS') 'Canonicalization self-test failed.'; Write-Host 'RECONCILIATION SELF-TEST: PASS';exit 0}
    catch {Write-Host 'RECONCILIATION SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}
}
$script:EvidenceLocks=@{}; $saved=@{}; $runDir=$null; $archiveLock=$null; $exitCode=1
foreach($name in @('PGPASSWORD','PGOPTIONS','PGCONNECT_TIMEOUT','PGCLIENTENCODING','PGDATABASE','PGHOST','PGPORT','PGUSER','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGTARGETSESSIONATTRS')) {
    $saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}
try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=Join-Path $PSScriptRoot '../..'}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $manifestPath=Join-Path $RepoRoot 'config/quarters/2026Q1.json'
    $engine=(Get-Process -Id $PID).Path
    & $engine -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'scripts/windows/Invoke-CfaQuarterBootstrap.ps1') -RepoRoot $RepoRoot -ManifestPath $manifestPath -NoWrite | Out-Null
    Require ($LASTEXITCODE -eq 0) 'Bootstrap validation failed.'
    $manifest=Read-Json $manifestPath
    $manifestSha=Get-CanonicalSha $manifestPath
    $sotSha=Get-Sha (Join-Path $RepoRoot $manifest.authority.sot_path)
    $head=@(& git -C $RepoRoot rev-parse HEAD)
    Require ($LASTEXITCODE -eq 0 -and $head.Count -eq 1 -and $head[0] -cmatch '^[0-9a-f]{40}$') 'Cannot identify repository HEAD.'
    Require ($ExpectedCensusReceiptSha256 -cmatch '^[0-9a-f]{64}$') 'Expected census receipt SHA-256 is invalid.'
    $CensusDirectory=Assert-SafePath $CensusDirectory
    $receiptPath=Assert-SafePath (Join-Path $CensusDirectory 'receipt.json')
    Hold-Evidence $receiptPath
    Require ((Get-Sha $receiptPath) -ceq $ExpectedCensusReceiptSha256) 'Census receipt hash mismatch.'
    $census=Read-Json $receiptPath
    Require ($census.schema -ceq 'cfa.resource-census/v1' -and $census.task_id -ceq 'Q1-RES-001' -and $census.quarter_id -ceq '2026Q1') 'Unexpected census contract.'
    Require ($census.collection_status -ceq 'PASS' -and $census.errors_count -eq 0) 'The preceding census collection did not pass.'
    Require ($census.manifest_sha256 -ceq $manifestSha -and $census.sot_sha256 -ceq $sotSha) 'Census authority does not match the unchanged Q1 bootstrap.'
    Require ($census.runner_sha256 -ceq (Get-Sha (Join-Path $PSScriptRoot 'Invoke-CfaResourceCensus.ps1'))) 'Census runner identity mismatch.'
    Require ($census.repository_head -cmatch '^[0-9a-f]{40}$') 'Invalid census repository identity.'
    & git -C $RepoRoot merge-base --is-ancestor $census.repository_head $head[0]
    Require ($LASTEXITCODE -eq 0) 'Census revision is not an ancestor of this checkout.'
    Require ($census.artifacts -is [Array] -and $census.artifacts.Count -eq 3) 'Census artifacts must be a three-element array.'
    foreach($name in @('files.jsonl','catalogs.json','errors.json')) {
        $a=@($census.artifacts | Where-Object {$_.path -ceq $name})
        Require ($a.Count -eq 1) 'Missing or duplicate census artifact.'
        $path=Assert-SafePath (Join-Path $CensusDirectory $name)
        Hold-Evidence $path
        Require ($a[0].sha256 -cmatch '^[0-9a-f]{64}$' -and (Get-Sha $path) -ceq $a[0].sha256 -and (Get-Item -LiteralPath $path).Length -eq $a[0].bytes) 'Census artifact hash or byte length mismatch.'
    }
    $oldErrors=Read-Json (Join-Path $CensusDirectory 'errors.json')
    Require ($oldErrors -is [Array] -and $oldErrors.Count -eq 0) 'Census errors must be an empty array.'
    $catalogs=Read-Json (Join-Path $CensusDirectory 'catalogs.json')
    Require ($catalogs -is [Array] -and $catalogs.Count -eq $census.postgres.database_count) 'Census catalog count mismatch.'
    foreach($db in $catalogs) {
        Require ($db.status -ceq 'PASS' -and $db.read_only -ceq 'on' -and $db.schemas -is [Array] -and $db.relations -is [Array] -and $db.columns -is [Array]) 'Census catalog is failed or malformed.'
    }
    foreach($name in @('srp','cfa')) { Require (@($catalogs | Where-Object {$_.database_name -ceq $name}).Count -eq 1) 'Required database was not uniquely discovered by the census.' }
    Require ($census.postgres.host -ceq $PgHost -and $census.postgres.port -eq $PgPort -and $census.postgres.user -ceq $PgUser -and $census.postgres.read_only_required -eq $true) 'PostgreSQL endpoint must match the verified census.'
    Require ($census.roots -is [Array] -and $census.roots.Count -eq 2) 'Census roots must be an exact two-element array.'
    $roots=@{}; $rootCounts=@{}
    foreach($root in $census.roots) {
        Require ($root.id -cin @('KRAKEN','CFA_LOCAL') -and $root.status -ceq 'PASS' -and -not $roots.ContainsKey($root.id)) 'Invalid census root.'
        $roots[$root.id]=Assert-SafePath $root.path; $rootCounts[$root.id]=0L
        Require (Test-Path -LiteralPath $roots[$root.id] -PathType Container) 'A census source root is now missing.'
    }
    Require ($roots.Count -eq 2) 'Missing census root identity.'
    $kraken=$roots.KRAKEN; $evidence=$roots.CFA_LOCAL
    Require (-not (Test-Under $kraken $evidence) -and -not (Test-Under $evidence $kraken)) 'Source roots cannot overlap.'
    foreach($root in @($kraken,$evidence)) { Require (-not (Test-Under $root $RepoRoot) -and -not (Test-Under $RepoRoot $root)) 'Source roots cannot overlap the repository.' }
    $sourceRow=$null; $fileCount=0L
    $censusFiles=New-Object 'System.Collections.Generic.List[object]'
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($line in [IO.File]::ReadLines((Join-Path $CensusDirectory 'files.jsonl'),$script:Utf8)) {
        $row=$line | ConvertFrom-Json
        Require ($roots.ContainsKey([string]$row.root_id) -and $row.status -ceq 'PASS' -and $row.sha256 -cmatch '^[0-9a-f]{64}$' -and $null -ne $row.length_bytes -and $row.length_bytes -ge 0) 'Malformed census file row.'
        $rel=[string]$row.relative_path
        Require (-not [string]::IsNullOrWhiteSpace($rel) -and -not [IO.Path]::IsPathRooted($rel) -and $rel -notmatch '(^|[\\/])\.\.([\\/]|$)' -and $rel -notmatch ':') 'Unsafe census relative path.'
        Require ($seen.Add($row.root_id+':'+$rel.Replace('\','/'))) 'Duplicate census file path.'
        $fileCount++; $rootCounts[$row.root_id]++; $censusFiles.Add($row)
        if($row.root_id -ceq 'KRAKEN' -and $rel -ceq 'Kraken_OHLCVT_Q1_2026.zip') { $sourceRow=$row }
    }
    Require ($fileCount -eq $census.files_count) 'Census file count mismatch.'
    foreach($root in $census.roots){Require ($rootCounts[$root.id] -eq $root.files_count) 'Census per-root file count mismatch.'}
    Require ($null -ne $sourceRow) 'The Q1 archive was not discovered in the preceding census.'
    $archivePath=Assert-SafePath (Join-Path $kraken $sourceRow.relative_path)
    Require (Test-Path -LiteralPath $archivePath -PathType Leaf) 'The census-identified archive is missing.'
    $quarterOutput=Assert-SafePath (Join-Path $evidence 'q1-market-reconciliation/2026Q1')
    Require (-not (Test-Under $CensusDirectory $quarterOutput) -and -not (Test-Under $quarterOutput $CensusDirectory)) 'Output must not overlap the input census.'
    $script:ResolvedPsql=Find-Psql
    Require ($ExpectedCoverageReceiptSha256 -cmatch '^[0-9a-f]{64}$') 'Expected coverage receipt SHA-256 is invalid.'
    $CoverageDirectory=Assert-SafePath $CoverageDirectory
    foreach($inputDir in @($CoverageDirectory,$CensusDirectory)) {
        Require (-not (Test-Under $inputDir $quarterOutput) -and -not (Test-Under $quarterOutput $inputDir)) 'Output overlaps input evidence.'
        Require (Test-Under $inputDir $evidence) 'Input evidence must be inside the confirmed CFA-local root.'
    }
    Require ($CoverageDirectory -ine $CensusDirectory) 'Coverage and census directories must differ.'
    $coverageReceiptPath=Assert-SafePath (Join-Path $CoverageDirectory 'receipt.json')
    Hold-Evidence $coverageReceiptPath
    Require ((Get-Sha $coverageReceiptPath) -ceq $ExpectedCoverageReceiptSha256) 'Coverage receipt hash mismatch.'
    $coverage=Read-Json $coverageReceiptPath
    Require ($coverage.schema -ceq 'cfa.q1-coverage-probe/v1' -and $coverage.task_id -ceq 'Q1-COV-001' -and $coverage.quarter_id -ceq '2026Q1') 'Unexpected coverage contract.'
    Require ($coverage.collection_status -ceq 'PASS' -and $coverage.errors_count -eq 0) 'Coverage collection did not pass.'
    Require ($coverage.census_receipt_sha256 -ceq $ExpectedCensusReceiptSha256 -and $coverage.census_repository_head -ceq $census.repository_head) 'Coverage does not bind the selected census.'
    Require ($coverage.manifest_sha256 -ceq $manifestSha -and $coverage.sot_sha256 -ceq $sotSha) 'Coverage authority binding differs.'
    Require ($coverage.interval.start_utc -ceq '2026-01-01T00:00:00Z' -and $coverage.interval.end_exclusive_utc -ceq '2026-04-01T00:00:00Z' -and $coverage.interval.time_zone -ceq 'UTC' -and $coverage.interval.semantics -ceq 'HALF_OPEN') 'Coverage interval differs.'
    Require ($coverage.archive_sha256 -ceq $sourceRow.sha256 -and $coverage.archive_length_bytes -eq $sourceRow.length_bytes) 'Coverage archive binding differs.'
    Require ($coverage.postgres.host -ceq $PgHost -and $coverage.postgres.port -eq $PgPort -and $coverage.postgres.user -ceq $PgUser -and $coverage.postgres.read_only_required -eq $true) 'Coverage endpoint differs.'
    Require ($coverage.repository_head -cmatch '^[0-9a-f]{40}$') 'Invalid coverage repository identity.'
    & git -C $RepoRoot merge-base --is-ancestor $coverage.repository_head $head[0]
    Require ($LASTEXITCODE -eq 0) 'Coverage revision is not an ancestor of this checkout.'
    Require ($coverage.code_files -is [Array] -and $coverage.code_files.Count -eq 3) 'Coverage code inventory must have three entries.'
    foreach($name in @('Invoke-CfaQ1CoverageProbe.ps1','CfaQ1ArchiveProbe.cs','Get-CfaQ1CoverageQueries.ps1')) {
        $code=@($coverage.code_files | Where-Object {$_.path -ceq ('scripts/windows/'+$name)})
        Require ($code.Count -eq 1 -and $code[0].sha256 -ceq (Get-Sha (Join-Path $PSScriptRoot $name))) 'Frozen coverage code differs from the observed revision.'
    }
    Require ($coverage.runner_sha256 -ceq (Get-Sha (Join-Path $PSScriptRoot 'Invoke-CfaQ1CoverageProbe.ps1'))) 'Coverage runner identity differs.'
    Require ($coverage.artifacts -is [Array] -and $coverage.artifacts.Count -eq 6) 'Coverage artifact inventory must have six entries.'
    foreach($name in @('archive-members.jsonl','archive-summary.json','market.json','news.json','reconciliation.json','errors.json')) {
        $entry=@($coverage.artifacts | Where-Object {$_.path -ceq $name})
        Require ($entry.Count -eq 1) 'Missing or duplicate coverage artifact.'
        $path=Assert-SafePath (Join-Path $CoverageDirectory $name); Hold-Evidence $path
        Require ($entry[0].sha256 -cmatch '^[0-9a-f]{64}$' -and (Get-Sha $path) -ceq $entry[0].sha256 -and (Get-Item -LiteralPath $path).Length -eq $entry[0].bytes) 'Coverage artifact hash or size mismatch.'
    }
    $coverageErrors=Read-Json (Join-Path $CoverageDirectory 'errors.json')
    Require ($coverageErrors -is [Array] -and $coverageErrors.Count -eq 0) 'Coverage errors must be an empty array.'
    $priorArchive=Read-Json (Join-Path $CoverageDirectory 'archive-summary.json')
    $priorMarket=Read-Json (Join-Path $CoverageDirectory 'market.json')
    $priorNews=Read-Json (Join-Path $CoverageDirectory 'news.json')
    $priorChecks=Read-Json (Join-Path $CoverageDirectory 'reconciliation.json')
    Require ($priorArchive.status -ceq 'PASS' -and $priorArchive.issue_count -eq 0 -and $priorArchive.errors -is [Array] -and $priorArchive.errors.Count -eq 0 -and $priorArchive.source_stable -eq $true -and $priorArchive.rows -gt 0) 'Preceding archive evidence did not pass.'
    Require ($priorMarket.per_pair -is [Array] -and $priorMarket.per_pair_day -is [Array] -and $priorMarket.per_day -is [Array] -and $priorMarket.source_archives -is [Array] -and $priorMarket.processing_runs -is [Array]) 'Malformed preceding market array shapes.'
    Require ($priorMarket.database_name -ceq 'srp' -and $priorMarket.read_only -ceq 'on' -and $priorMarket.transaction_isolation -ceq 'repeatable read' -and $priorMarket.time_zone -ceq 'UTC' -and $priorMarket.schema_observation.schema_ok -eq $true -and $priorMarket.summary.total_rows -eq $priorArchive.rows) 'Malformed preceding market snapshot.'
    Require ($priorNews.contracts -is [Array] -and $priorNews.per_contract -is [Array] -and $priorNews.database_name -ceq 'cfa' -and $priorNews.metadata_only -eq $true) 'Malformed preceding news diagnostic.'
    $requiredChecks=@('ARCHIVE','MARKET-ROWS','ARCHIVE-REGISTRATION','ARCHIVE-BYTES','PAIR-AGGREGATES','PAIR-DAY-COUNTS','NEWS-Q1-PRESENCE','NEWS-Q1-CONTRACT-LINKS')
    foreach($name in @('outside_q1_rows','null_pair_id_rows','null_timestamp_rows','null_source_archive_id_rows','null_processing_run_id_rows','nonfinite_timestamp_rows','off_minute_rows','nonfinite_ohlcvt_rows','invalid_ohlcvt_rows','unknown_pair_rows','pair_metadata_missing_rows','missing_source_archive_rows','nonselected_source_archive_rows','missing_processing_run_rows','processing_run_archive_mismatch_rows','duplicate_pair_time_keys','duplicate_extra_rows','duplicate_pair_metadata_ids','duplicate_source_archive_ids','duplicate_processing_run_ids')) {$requiredChecks+=('MARKET-'+$name)}
    foreach($name in @('open_price','high_price','low_price','close_price','volume','trade_count')) {$requiredChecks+=('MARKET-null-'+$name)}
    Require ($priorChecks.checks -is [Array] -and $priorChecks.checks.Count -eq $requiredChecks.Count) 'Coverage check inventory is incomplete.'
    foreach($id in $requiredChecks) {
        $check=@($priorChecks.checks | Where-Object {$_.id -ceq ('Q1-COV-001-'+$id)})
        Require ($check.Count -eq 1) 'Missing or duplicate preceding check ID.'
        Require ($check[0].status -ceq 'PASS' -or ($id -ceq 'NEWS-Q1-PRESENCE' -and $check[0].status -ceq 'FAIL')) 'A preceding archive/market requirement did not pass.'
    }
    $pairs=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $pairIds=New-Object 'System.Collections.Generic.HashSet[long]'
    foreach($pair in $priorMarket.per_pair) {
        Require ($pair.pair_code -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -and $pair.exchange -ceq 'Kraken' -and $pair.pair_id -gt 0 -and $pair.pair_metadata_match_count -eq 1 -and $pair.rows -gt 0 -and $pair.rows -eq $pair.q1_rows) 'Invalid preceding pair binding.'
        Require (-not $pairs.ContainsKey($pair.pair_code) -and $pairIds.Add([long]$pair.pair_id)) 'Ambiguous preceding pair binding.'
        $pairs.Add($pair.pair_code,$pair)
    }
    Initialize-Reconciliation
    $bindings=New-Object 'System.Collections.Generic.List[CfaQ1Reconciliation.MemberBinding]'
    $allPaths=New-Object 'System.Collections.Generic.List[string]'
    $uniquePaths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $boundPairs=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [long]$boundRows=0
    foreach($line in [IO.File]::ReadLines((Join-Path $CoverageDirectory 'archive-members.jsonl'),$script:Utf8)) {
        $member=$line | ConvertFrom-Json
        Require ($member.read_complete -eq $true -and $member.sha256 -cmatch '^[0-9a-f]{64}$' -and $member.crc32 -cmatch '^[0-9a-f]{8}$' -and $member.crc32 -ceq $member.expected_crc32 -and $member.length_bytes -eq $member.declared_length_bytes -and $member.errors -is [Array] -and $member.errors.Count -eq 0 -and $member.days -is [Array]) 'Malformed preceding member evidence.'
        Require ($uniquePaths.Add([string]$member.member_path)) 'Duplicate preceding archive member.'
        $allPaths.Add([string]$member.member_path)
        if($member.is_one_minute -eq $true) {
            Require ($pairs.ContainsKey([string]$member.pair_code) -and $boundPairs.Add([string]$member.pair_code)) 'Member does not map uniquely to an observed pair.'
            $pair=$pairs[$member.pair_code]
            Require ($member.rows -gt 0 -and $member.rows -eq $pair.rows -and $member.min_epoch -eq $pair.min_epoch -and $member.max_epoch -eq $pair.max_epoch) 'Preceding member and pair aggregates differ.'
            $binding=New-Object CfaQ1Reconciliation.MemberBinding
            foreach($name in @('member_path','pair_code','sha256','length_bytes','rows','min_epoch','max_epoch')) {$binding.$name=$member.$name}
            $binding.pair_id=$pair.pair_id; $bindings.Add($binding); $boundRows+=$binding.rows
        }
    }
    Require ($allPaths.Count -eq $priorArchive.member_count -and $bindings.Count -eq $priorArchive.one_minute_member_count -and $bindings.Count -eq $pairs.Count -and $boundRows -eq $priorArchive.rows) 'Preceding member inventory totals differ.'
    . (Join-Path $PSScriptRoot 'Get-CfaQ1ReconciliationQueries.ps1')
    $codeFiles=@()
    foreach($name in @('Invoke-CfaQ1MarketReconciliation.ps1','CfaQ1MarketReconciliation.cs','Get-CfaQ1ReconciliationQueries.ps1')) {$codeFiles+=[pscustomobject]@{path=('scripts/windows/'+$name);sha256=(Get-Sha (Join-Path $PSScriptRoot $name))}}
    $runId=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N')
    $proposed=Join-Path $quarterOutput $runId
    New-Item -ItemType Directory -Path $proposed -ErrorAction Stop | Out-Null
    $runDir=$proposed; $started=[DateTime]::UtcNow.ToString('o')
    Write-Host "Evidence directory: $runDir"
    $artifactNames=@('source-digests.tsv','member-evidence.jsonl','market-digests.tsv','market.json','schema.json','comparison.tsv','reconciliation.json','lineage.json','errors.json')
    foreach($name in $artifactNames) {
        if($name.EndsWith('.json')) {Write-Json (Join-Path $runDir $name) ([ordered]@{status='BLOCKED';reason='Collection has not completed.'})}
    }
    $canonical='cfa.ohlcvt.binary52/v1'; $comparison=$null; $scan=$null; $snapshot=$null; $current='UNVERIFIED'
    $lineage=[ordered]@{status='UNVERIFIED';historical_provenance_status='UNVERIFIED';inventory_references=@();reason='Current content correspondence does not establish historical import-member attribution.'}
    try {
        Write-Host 'Verifying the bound Q1 archive and computing ordered source fingerprints.'
        $archiveLock=[IO.File]::Open($archivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $archiveInfo=Get-Item -LiteralPath $archivePath; $beforeTicks=$archiveInfo.LastWriteTimeUtc.Ticks
        Require ((Get-Sha $archivePath) -ceq $sourceRow.sha256 -and $archiveInfo.Length -eq $sourceRow.length_bytes) 'Q1 archive differs from the bound evidence.'
        $scan=[CfaQ1Reconciliation.MarketReconciler]::ScanArchive($archivePath,$bindings.ToArray(),$allPaths.ToArray(),(Join-Path $runDir 'source-digests.tsv'),(Join-Path $runDir 'member-evidence.jsonl'))
        Require ($scan.status -ceq 'PASS' -and $scan.row_count -eq $boundRows -and $scan.member_count -eq $bindings.Count -and $scan.canonicalization -ceq $canonical) 'Source fingerprint scan did not satisfy the frozen contract.'
        $archiveInfo.Refresh()
        Require ($archiveInfo.Length -eq $sourceRow.length_bytes -and $archiveInfo.LastWriteTimeUtc.Ticks -eq $beforeTicks -and (Get-Sha $archivePath) -ceq $sourceRow.sha256) 'Q1 archive changed during inspection.'
        Add-Check 'Q1-MKT-001-ARCHIVE' $true 'Bound archive and every selected member were verified.'
    } catch {Add-Issue 'ARCHIVE' 'Bound archive or source fingerprint verification failed.';Add-Check 'Q1-MKT-001-ARCHIVE' $false 'Inspect the local archive and bound evidence; no database probe was attempted.'}
    finally {if($null -ne $archiveLock){$archiveLock.Dispose();$archiveLock=$null}}
    if($script:Issues.Count -eq 0) {
        $script:SnapshotDiagnostic=New-Q1SnapshotDiagnostic
        try {
            $script:SnapshotDiagnostic.runner_phase='CONNECTION_SETUP'
            foreach($name in @('PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGDATABASE','PGTARGETSESSIONATTRS')) {Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}
            $env:PGHOST=$PgHost; $env:PGPORT=[string]$PgPort; $env:PGUSER=$PgUser
            $env:PGCONNECT_TIMEOUT='5'; $env:PGCLIENTENCODING='UTF8'
            $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout='+($StatementTimeoutSeconds*1000)+' -c lock_timeout=5000'
            if([string]::IsNullOrEmpty($env:PGPASSWORD)) {
                $secretPtr=[IntPtr]::Zero; $secure=Read-Host "PostgreSQL password for '$PgUser' (not stored in evidence)" -AsSecureString
                try {$secretPtr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)}
                finally {if($secretPtr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)};$secure.Dispose()}
            }
            Write-Host 'Computing PostgreSQL fingerprints in one read-only Q1 snapshot.'
            $snapshot=Invoke-MarketSnapshot (Get-Q1ReconciliationSql -ArchiveSha256 $sourceRow.sha256) $runDir
            $script:SnapshotDiagnostic.runner_phase='LINEAGE_CHECKS'
            Add-Check 'Q1-MKT-001-SNAPSHOT' ($snapshot.has_digests -and -not $snapshot.blocked) 'Schema and population invariants must pass before fingerprint aggregation.'
            if($snapshot.schema.schema_ok -ne $true) {Add-Issue 'SCHEMA' 'The current source schema failed its gate; value collection was blocked.'}
            if($null -ne $snapshot.market) {
                $live=$snapshot.market
                $lineage.inventory_references=Inspect-InventoryReferences $live $censusFiles.ToArray() $roots
                Add-Check 'Q1-MKT-001-LINEAGE-INVENTORY' (@($lineage.inventory_references | Where-Object {$_.status -ceq 'FAIL'}).Count -eq 0) 'Any safely readable census-bound inventory must retain its recorded bytes; unavailable references do not establish provenance.'
                $registrations=@($live.source_archives | Where-Object {$_.sha256 -ceq $sourceRow.sha256})
                $same=($registrations.Count -eq 1 -and $live.per_pair -is [Array] -and $live.per_pair.Count -eq $pairs.Count -and $live.summary.total_rows -eq $boundRows)
                if($registrations.Count -eq 1) {
                    $same=$same -and $registrations[0].size_bytes -eq $sourceRow.length_bytes -and $registrations[0].zip_entry_count -eq $allPaths.Count -and $registrations[0].one_minute_files -eq $bindings.Count -and $registrations[0].pair_count -eq $pairs.Count
                    $priorRegistrations=@($priorMarket.source_archives | Where-Object {$_.sha256 -ceq $sourceRow.sha256})
                    if($priorRegistrations.Count -ne 1 -or $registrations[0].source_archive_id -ne $priorRegistrations[0].source_archive_id) {$same=$false}
                    elseif($priorRegistrations.Count -eq 1) {
                        foreach($field in @('exchange','dataset_type','archive_name','period_label','status','registered_at_utc','imported_at_utc')) {
                            if($registrations[0].$field -cne $priorRegistrations[0].$field) {$same=$false}
                        }
                    }
                }
                if($live.processing_runs -isnot [Array] -or $live.processing_runs.Count -ne $priorMarket.processing_runs.Count) {$same=$false}
                foreach($run in $live.processing_runs) {
                    $priorRuns=@($priorMarket.processing_runs | Where-Object {$_.processing_run_id -eq $run.processing_run_id})
                    if($priorRuns.Count -ne 1) {$same=$false;continue}
                    foreach($field in @('process_name','process_version','source_archive_id','config_sha256','status','input_rows','output_rows','started_at_utc','completed_at_utc')) {
                        if($run.$field -cne $priorRuns[0].$field) {$same=$false}
                    }
                }
                $liveIds=New-Object 'System.Collections.Generic.HashSet[long]'
                foreach($pair in $live.per_pair) {
                    if(-not $pairs.ContainsKey([string]$pair.pair_code)) {$same=$false;continue}
                    $bound=$pairs[$pair.pair_code]
                    if(-not $liveIds.Add([long]$pair.pair_id) -or $pair.pair_id -ne $bound.pair_id -or $pair.exchange -cne 'Kraken' -or $pair.rows -ne $bound.rows -or $pair.min_epoch -ne $bound.min_epoch -or $pair.max_epoch -ne $bound.max_epoch) {$same=$false}
                }
                Add-Check 'Q1-MKT-001-LINEAGE-CURRENT' $same 'Current archive registration and exact pair mapping must match the bound observations.'
                if($snapshot.has_digests) {
                    $script:SnapshotDiagnostic.runner_phase='DIGEST_COMPARISON'
                    $comparison=[CfaQ1Reconciliation.MarketReconciler]::CompareDigests((Join-Path $runDir 'source-digests.tsv'),(Join-Path $runDir 'market-digests.tsv'),(Join-Path $runDir 'comparison.tsv'))
                    $equal=($comparison.status -ceq 'PASS' -and $comparison.source_row_count -eq $boundRows -and $comparison.database_row_count -eq $boundRows)
                    Add-Check 'Q1-MKT-001-VALUES' $equal 'Every ordered pair/day key, row count, timestamp bound and canonical fingerprint must match.'
                    $current=if($equal -and $same){'PASS'}else{'FAIL'}
                } else {$current='FAIL'}
            }
        } catch {
            $script:Issues.Add([pscustomobject]@{scope='POSTGRESQL';status='FAIL';reason='Market snapshot or fingerprint reconciliation failed; partial evidence is not a passing result.';diagnostic=$script:SnapshotDiagnostic})
            $current='UNVERIFIED'
        }
    }
    Write-Json (Join-Path $runDir 'lineage.json') $lineage
    $failed=@($script:Checks | Where-Object {$_.status -ceq 'FAIL'}).Count
    $status=if($script:Issues.Count -eq 0 -and $failed -eq 0 -and $current -ceq 'PASS'){'PASS'}else{'FAIL'}
    $reconciliation=[ordered]@{status=$status;current_content_status=$current;historical_provenance_status='UNVERIFIED';canonicalization=$canonical;source_summary=$scan;comparison=$comparison;checks=@($script:Checks.ToArray());data_ids=@(@{id='DATA-001';status='UNVERIFIED'},@{id='DATA-002';status='UNVERIFIED'},@{id='DATA-003';status='UNVERIFIED'});stage1_status='BLOCKED';limitations=@('Fingerprint agreement verifies current canonical source-to-table values; it does not establish historical importer member attribution.','Binary64 values use exact rounding and normalized zero; original decimal lexical formatting is not an equality target.','No news contract, eligibility, missing-minute policy, DATA identity or stage approval is inferred.')}
    Write-Json (Join-Path $runDir 'reconciliation.json') $reconciliation
    Write-Json (Join-Path $runDir 'errors.json') @($script:Issues.ToArray())
    $artifacts=@()
    foreach($name in $artifactNames) {
        $path=Join-Path $runDir $name
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){[IO.File]::WriteAllText($path,'',$script:Utf8)}
        $artifacts+=[pscustomobject]@{path=$name;sha256=(Get-Sha $path);bytes=(Get-Item -LiteralPath $path).Length}
    }
    foreach($code in $codeFiles) {Require ((Get-Sha (Join-Path $RepoRoot $code.path)) -ceq $code.sha256) 'Code changed during execution.'}
    $receipt=[ordered]@{schema='cfa.q1-market-reconciliation/v1';task_id='Q1-MKT-001';quarter_id='2026Q1';run_id=$runId;started_utc=$started;finished_utc=[DateTime]::UtcNow.ToString('o');collection_status=$(if($script:Issues.Count -eq 0){'PASS'}else{'FAIL'});checks_status=$status;task_status='UNVERIFIED';local_status='UNVERIFIED';current_content_status=$current;historical_provenance_status='UNVERIFIED';stage1_status='BLOCKED';canonicalization=$canonical;census_receipt_sha256=$ExpectedCensusReceiptSha256;coverage_receipt_sha256=$ExpectedCoverageReceiptSha256;coverage_repository_head=$coverage.repository_head;manifest_sha256=$manifestSha;sot_sha256=$sotSha;repository_head=$head[0];runner_sha256=(Get-Sha $PSCommandPath);code_files=$codeFiles;powershell_version=$PSVersionTable.PSVersion.ToString();interval=$manifest.interval;archive_sha256=$sourceRow.sha256;archive_length_bytes=$sourceRow.length_bytes;postgres=@{host=$PgHost;port=$PgPort;user=$PgUser;databases=@('srp');read_only_required=$true;statement_timeout_seconds=$StatementTimeoutSeconds;process_timeout_seconds=($StatementTimeoutSeconds*4+30)};errors_count=$script:Issues.Count;artifacts=$artifacts}
    $outReceipt=Join-Path $runDir 'receipt.json';Write-Json $outReceipt $receipt
    Write-Host "Collection: $($receipt.collection_status); Checks: $status; Current content: $current; Historical provenance: UNVERIFIED; Q1-MKT-001-LOCAL: UNVERIFIED; Stage 1: BLOCKED"
    Write-Host "Receipt: $outReceipt"
    Write-Host "Receipt SHA-256: $(Get-Sha $outReceipt)"
    $exitCode=if($status -ceq 'PASS'){0}else{2}
} catch {
    Write-Host 'Q1 MARKET RECONCILIATION: FAIL';Write-Host $_.Exception.Message
    if($null -ne $runDir) {$exitCode=2;try{Write-Json (Join-Path $runDir 'failure.json') @(@{status='FAIL';reason='Unexpected failure; incomplete evidence must not be accepted.'})}catch{}}
} finally {
    if($null -ne $archiveLock){$archiveLock.Dispose()}
    foreach($stream in $script:EvidenceLocks.Values){$stream.Dispose()}
    foreach($name in $saved.Keys) {
        if($null -eq $saved[$name]){Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}
        else{[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
    }
}
exit $exitCode
