#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$CensusDirectory = '',
    [string]$ExpectedCensusReceiptSha256 = 'b0f00361efba3a6737bae8480b4e5b64a4a3b827acaeb4df223f8457a6605023',
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$PsqlPath = '',
    [ValidateRange(5,900)][int]$StatementTimeoutSeconds = 300,
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
function Invoke-ProbeJson([string]$Database,[string]$Query,[string]$SchemaQuery) {
    # A zero-row SELECT takes relation read locks without reading source rows.
    # Keep these locks, schema checks and aggregates in one read-only snapshot.
    $relations=if($Database -ceq 'srp'){'ONLY srp.ohlcvt_1m_2026q1, ONLY srp.source_archives, ONLY srp.market_pairs, ONLY srp.processing_runs'}else{'ONLY source_news.source_contracts, ONLY source_news.source_slots'}
    $schemaSql=$SchemaQuery.Trim().TrimEnd(';')
    $dataSql=$Query.Trim().TrimEnd(';')
    $sql=@"
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL search_path=pg_catalog;
SET LOCAL TIME ZONE 'UTC';
SELECT (s.result->>'schema_ok')::boolean AS ok,s.result::text AS observation
FROM ($schemaSql) s(result)
\gset q1initial_
\if :q1initial_ok
SELECT 1 FROM $relations WHERE false;
SELECT (s.result->>'schema_ok')::boolean AS ok,s.result::text AS observation
FROM ($schemaSql) s(result)
\gset q1schema_
\if :q1schema_ok
SELECT d.result || jsonb_build_object('schema_observation', :'q1schema_observation'::jsonb)
FROM ($dataSql) d(result);
\else
SELECT :'q1schema_observation'::jsonb || jsonb_build_object('schema_observation', :'q1schema_observation'::jsonb,'status','FAIL');
\endif
\else
SELECT :'q1initial_observation'::jsonb || jsonb_build_object('schema_observation', :'q1initial_observation'::jsonb,'status','FAIL');
\endif
COMMIT;
"@
    $args=@('-X','-w','-A','-t','-q','-d',('postgresql:///'+[Uri]::EscapeDataString($Database)),'-v','ON_ERROR_STOP=1','-f','-')
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$script:ResolvedPsql
    $start.Arguments=(($args | ForEach-Object { Quote-Native $_ }) -join ' ')
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=$script:Utf8; $start.StandardErrorEncoding=$script:Utf8
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        Require ($process.Start()) 'Could not start the read-only PostgreSQL probe.'
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $bytes=$script:Utf8.GetBytes($sql)
        $process.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
        $process.StandardInput.Close()
        if(-not $process.WaitForExit(($StatementTimeoutSeconds+20)*1000)) {
            $process.Kill(); $process.WaitForExit()
            throw 'Read-only PostgreSQL probe exceeded its process timeout.'
        }
        $process.WaitForExit()
        # Do not export server diagnostics: they may contain server-defined values.
        $null=$stderr.GetAwaiter().GetResult()
        Require ($process.ExitCode -eq 0) 'Read-only PostgreSQL query failed; check local access, schema, or statement timeout.'
        $result=$stdout.GetAwaiter().GetResult() | ConvertFrom-Json
        Require ($null -ne $result -and $result.read_only -ceq 'on' -and $result.database_name -ceq $Database -and $result.transaction_isolation -ceq 'repeatable read' -and $result.time_zone -ceq 'UTC') 'PostgreSQL identity, READ ONLY, isolation, or UTC verification failed.'
        return $result
    } finally { $process.Dispose() }
}
function Initialize-ArchiveHelper {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ($null -eq ('CfaQ1Coverage.ArchiveProbe' -as [type])) {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Add-Type -Path (Join-Path $PSScriptRoot 'CfaQ1ArchiveProbe.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll')
        } else { Add-Type -Path (Join-Path $PSScriptRoot 'CfaQ1ArchiveProbe.cs') }
    }
}
function Invoke-Q1Reconciliation([object]$Archive,[object]$Market,[object]$News) {
    $s=$Market.summary
    Add-Check 'Q1-COV-001-MARKET-ROWS' ($s.total_rows -gt 0 -and $s.total_rows -eq $Archive.rows -and $s.q1_rows -eq $s.total_rows) 'Exact market rows must equal the inspected one-minute archive rows and lie within Q1.'
    foreach($name in @('outside_q1_rows','null_pair_id_rows','null_timestamp_rows','null_source_archive_id_rows','null_processing_run_id_rows','nonfinite_timestamp_rows','off_minute_rows','nonfinite_ohlcvt_rows','invalid_ohlcvt_rows','unknown_pair_rows','pair_metadata_missing_rows','missing_source_archive_rows','nonselected_source_archive_rows','missing_processing_run_rows','processing_run_archive_mismatch_rows','duplicate_pair_time_keys','duplicate_extra_rows','duplicate_pair_metadata_ids','duplicate_source_archive_ids','duplicate_processing_run_ids')) {
        Require ($null -ne $s.PSObject.Properties[$name] -and $null -ne $s.$name) ('Missing market summary field: '+$name)
        Add-Check ('Q1-COV-001-MARKET-'+$name) ($s.$name -eq 0) ('Observed '+$name+' must be zero.')
    }
    foreach($name in @('open_price','high_price','low_price','close_price','volume','trade_count')) {
        Require ($null -ne $s.nulls.PSObject.Properties[$name] -and $null -ne $s.nulls.$name) ('Missing market null counter: '+$name)
        Add-Check ('Q1-COV-001-MARKET-null-'+$name) ($s.nulls.$name -eq 0) ('The archive field '+$name+' must be represented for every imported row.')
    }
    $registrations=@($Market.source_archives | Where-Object {$_.matches_selected_archive_sha256 -eq $true})
    Add-Check 'Q1-COV-001-ARCHIVE-REGISTRATION' ($registrations.Count -eq 1 -and $s.selected_archive_registration_count -eq 1) 'One unambiguous archive registration must match the exact inspected archive hash.'
    if($registrations.Count -eq 1) {
        Add-Check 'Q1-COV-001-ARCHIVE-BYTES' ($registrations[0].size_bytes -eq $sourceRow.length_bytes) 'Registered compressed bytes must equal the census-verified archive size.'
    }
    $members=@($Archive.members | Where-Object {$_.is_one_minute -eq $true})
    $pairs=@($Market.per_pair)
    $pairMatch=($members.Count -eq $pairs.Count)
    $dayMatch=$true
    foreach($member in $members) {
        $pair=@($pairs | Where-Object {$_.pair_code -ceq $member.pair_code})
        if($pair.Count -ne 1) {$pairMatch=$false;$dayMatch=$false;continue}
        if($pair[0].rows -ne $member.rows -or $pair[0].min_epoch -ne $member.min_epoch -or $pair[0].max_epoch -ne $member.max_epoch -or $pair[0].pair_metadata_match_count -ne 1) {$pairMatch=$false}
        $days=@($Market.per_pair_day | Where-Object {$_.pair_id -eq $pair[0].pair_id})
        if($days.Count -ne @($member.days).Count){$dayMatch=$false}
        foreach($day in $member.days) {
            $matching=@($days | Where-Object {[string]$_.day_utc -ceq [string]$day.day_utc})
            if($matching.Count -ne 1 -or $matching[0].row_count -ne $day.rows){$dayMatch=$false}
        }
    }
    Add-Check 'Q1-COV-001-PAIR-AGGREGATES' $pairMatch 'Every exact member pair code must map once to matching database row counts and bounds; this is not identity approval.'
    Add-Check 'Q1-COV-001-PAIR-DAY-COUNTS' $dayMatch 'Every member pair/day count must match the database snapshot.'
    if($null -ne $News.PSObject.Properties['summary']) {
        Add-Check 'Q1-COV-001-NEWS-Q1-PRESENCE' ($News.summary.q1_contract_count -gt 0 -and $News.summary.q1_slot_rows -gt 0) 'At least one Q1-overlapping contract and one Q1 slot must be observed; completeness and payload validity remain UNVERIFIED.'
        $newsLinks=$true
        foreach($contract in $News.per_contract) {
            if($contract.missing_contract_link_rows -ne 0 -or $contract.outside_contract_window_rows -ne 0){$newsLinks=$false}
        }
        Add-Check 'Q1-COV-001-NEWS-Q1-CONTRACT-LINKS' $newsLinks 'Q1 slots must reference existing contracts whose intervals contain their timestamps.'
    }
}
if($SelfTest) {
    try {
        Initialize-ArchiveHelper
        $tests=[CfaQ1Coverage.ArchiveProbe]::SelfTest()
        Write-Host ('COVERAGE SELF-TEST: PASS; '+$tests.Count+' archive checks')
        exit 0
    } catch { Write-Host 'COVERAGE SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

$saved=@{}; $runDir=$null; $archiveLock=$null; $secretPtr=[IntPtr]::Zero; $exitCode=1
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
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($line in [IO.File]::ReadLines((Join-Path $CensusDirectory 'files.jsonl'),$script:Utf8)) {
        $row=$line | ConvertFrom-Json
        Require ($roots.ContainsKey([string]$row.root_id) -and $row.status -ceq 'PASS' -and $row.sha256 -cmatch '^[0-9a-f]{64}$' -and $null -ne $row.length_bytes -and $row.length_bytes -ge 0) 'Malformed census file row.'
        $rel=[string]$row.relative_path
        Require (-not [string]::IsNullOrWhiteSpace($rel) -and -not [IO.Path]::IsPathRooted($rel) -and $rel -notmatch '(^|[\\/])\.\.([\\/]|$)' -and $rel -notmatch ':') 'Unsafe census relative path.'
        Require ($seen.Add($row.root_id+':'+$rel.Replace('\','/'))) 'Duplicate census file path.'
        $fileCount++; $rootCounts[$row.root_id]++
        if($row.root_id -ceq 'KRAKEN' -and $rel -ceq 'Kraken_OHLCVT_Q1_2026.zip') { $sourceRow=$row }
    }
    Require ($fileCount -eq $census.files_count) 'Census file count mismatch.'
    foreach($root in $census.roots){Require ($rootCounts[$root.id] -eq $root.files_count) 'Census per-root file count mismatch.'}
    Require ($null -ne $sourceRow) 'The Q1 archive was not discovered in the preceding census.'
    $archivePath=Assert-SafePath (Join-Path $kraken $sourceRow.relative_path)
    Require (Test-Path -LiteralPath $archivePath -PathType Leaf) 'The census-identified archive is missing.'
    $quarterOutput=Assert-SafePath (Join-Path $evidence 'q1-coverage-probe/2026Q1')
    Require (-not (Test-Under $CensusDirectory $quarterOutput) -and -not (Test-Under $quarterOutput $CensusDirectory)) 'Output must not overlap the input census.'
    $script:ResolvedPsql=Find-Psql
    Initialize-ArchiveHelper
    . (Join-Path $PSScriptRoot 'Get-CfaQ1CoverageQueries.ps1')
    $runId=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N')
    $proposedRunDir=Join-Path $quarterOutput $runId
    New-Item -ItemType Directory -Path $proposedRunDir -ErrorAction Stop | Out-Null
    $runDir=$proposedRunDir
    Write-Host "Evidence directory: $runDir"
    $started=[DateTime]::UtcNow.ToString('o')
    $archiveSummary=[pscustomobject]@{status='BLOCKED';reason='Archive inspection has not completed.'}
    $market=[pscustomobject]@{status='BLOCKED';reason='Archive inspection must pass first.'}
    $news=[pscustomobject]@{status='BLOCKED';reason='Archive inspection must pass first.'}
    [IO.File]::WriteAllText((Join-Path $runDir 'archive-members.jsonl'),'',$script:Utf8)
    try {
        Write-Host 'Rechecking the Q1 archive hash and streaming its members; this can take several minutes.'
        $archiveLock=[IO.File]::Open($archivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $archiveInfo=Get-Item -LiteralPath $archivePath
        $beforeTicks=$archiveInfo.LastWriteTimeUtc.Ticks
        $hash=Get-Sha $archivePath
        Require ($hash -ceq $sourceRow.sha256 -and $archiveInfo.Length -eq $sourceRow.length_bytes) 'Archive bytes differ from the verified census.'
        $scan=[CfaQ1Coverage.ArchiveProbe]::Scan($archivePath)
        $writer=[IO.StreamWriter]::new((Join-Path $runDir 'archive-members.jsonl'),$false,$script:Utf8)
        try { foreach($member in $scan.members){$writer.WriteLine((ConvertTo-Json -InputObject $member -Depth 12 -Compress))} }
        finally {$writer.Dispose()}
        $archiveSummary=$scan | Select-Object * -ExcludeProperty members
        $archiveInfo.Refresh()
        Require ($archiveInfo.Length -eq $sourceRow.length_bytes -and $archiveInfo.LastWriteTimeUtc.Ticks -eq $beforeTicks -and (Get-Sha $archivePath) -ceq $hash) 'Archive changed during inspection.'
        Add-Check 'Q1-COV-001-ARCHIVE' ($scan.status -ceq 'PASS') 'All members hashed; one-minute data must satisfy the frozen archive checks.'
        Require ($scan.status -ceq 'PASS') 'Archive member/content checks failed; see archive evidence. Later probes are blocked.'
    } catch {
        $archiveSummary.status='FAIL'
        $archiveSummary | Add-Member -NotePropertyName inspection_failure -NotePropertyValue $_.Exception.Message -Force
        Add-Issue 'ARCHIVE' $_.Exception.Message
    }
    finally { if($null -ne $archiveLock){$archiveLock.Dispose();$archiveLock=$null} }
    Write-Json (Join-Path $runDir 'archive-summary.json') $archiveSummary
    if($script:Issues.Count -eq 0) {
        foreach($name in @('PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGDATABASE','PGTARGETSESSIONATTRS')){Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}
        $env:PGHOST=$PgHost; $env:PGPORT=[string]$PgPort; $env:PGUSER=$PgUser
        $env:PGCONNECT_TIMEOUT='5'; $env:PGCLIENTENCODING='UTF8'
        $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout='+($StatementTimeoutSeconds*1000)+' -c lock_timeout=5000'
        $credentialsReady=$true
        try {
            if([string]::IsNullOrEmpty($env:PGPASSWORD)) {
                $secure=Read-Host "PostgreSQL password for '$PgUser' (not stored in evidence)" -AsSecureString
                try {$secretPtr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)}
                finally {if($secretPtr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr);$secretPtr=[IntPtr]::Zero};$secure.Dispose()}
            }
        } catch {
            $credentialsReady=$false
            $market=[pscustomobject]@{status='BLOCKED';reason='PostgreSQL credentials were unavailable.'}
            $news=[pscustomobject]@{status='BLOCKED';reason='PostgreSQL credentials were unavailable.'}
            Add-Issue 'POSTGRESQL' 'Password input was unavailable; database probes were not attempted.'
        }
        if($credentialsReady) {
        try {
            Write-Host 'Inspecting Q1 market coverage and lineage in srp (read only).'
            $schema=$null
            $market=Invoke-ProbeJson 'srp' (Get-Q1MarketQuery -ArchiveSha256 $hash) (Get-Q1MarketSchemaQuery)
            $schema=$market.schema_observation
            Require ($schema.schema_ok -eq $true) 'Market schema differs from the observed contract.'
        } catch {$market=[pscustomobject]@{status='FAIL';reason=$_.Exception.Message;schema_observation=$schema};Add-Issue 'MARKET' $_.Exception.Message}
        try {
            Write-Host 'Inspecting Q1 news contract and slot metadata in cfa (read only).'
            $schema=$null
            $news=Invoke-ProbeJson 'cfa' (Get-Q1NewsQuery) (Get-Q1NewsSchemaQuery)
            $schema=$news.schema_observation
            Require ($schema.schema_ok -eq $true) 'News schema differs from the observed contract.'
        } catch {$news=[pscustomobject]@{status='FAIL';reason=$_.Exception.Message;schema_observation=$schema};Add-Issue 'NEWS' $_.Exception.Message}
        }
    }
    Write-Json (Join-Path $runDir 'market.json') $market
    Write-Json (Join-Path $runDir 'news.json') $news
    # Aggregate checks are reconciled below; they never approve row-value equivalence.
    if($null -ne $market.PSObject.Properties['summary']) {
        Invoke-Q1Reconciliation $scan $market $news
    }
    $failed=@($script:Checks.ToArray() | Where-Object {$_.status -ceq 'FAIL'}).Count
    $reconciliation=[ordered]@{status=$(if($script:Issues.Count -eq 0 -and $failed -eq 0){'PASS'}else{'FAIL'});checks=@($script:Checks.ToArray());member_lineage_status='UNVERIFIED';row_value_equivalence_status='UNVERIFIED';news_payload_verification_status='UNVERIFIED';data_ids=@(@{id='DATA-001';status='UNVERIFIED'},@{id='DATA-002';status='UNVERIFIED'},@{id='DATA-003';status='UNVERIFIED'});stage1_status='BLOCKED';limitations=@('Archive and PostgreSQL aggregates do not prove row-value equality or authoritative member lineage.','News slot metadata does not prove payload availability, validity, or an approved Q1 population.','No market eligibility or missing-minute policy has been approved.','Database observations are snapshot-consistent within each query, not a cross-database atomic snapshot.')}
    Write-Json (Join-Path $runDir 'reconciliation.json') $reconciliation
    Write-Json (Join-Path $runDir 'errors.json') @($script:Issues.ToArray())
    $artifacts=@()
    foreach($name in @('archive-members.jsonl','archive-summary.json','market.json','news.json','reconciliation.json','errors.json')) {
        $path=Join-Path $runDir $name
        $artifacts += [pscustomobject]@{path=$name;sha256=(Get-Sha $path);bytes=(Get-Item -LiteralPath $path).Length}
    }
    $codeFiles=@()
    foreach($name in @('Invoke-CfaQ1CoverageProbe.ps1','CfaQ1ArchiveProbe.cs','Get-CfaQ1CoverageQueries.ps1')){$codeFiles += [pscustomobject]@{path=('scripts/windows/'+$name);sha256=(Get-Sha (Join-Path $PSScriptRoot $name))}}
    $receipt=[ordered]@{schema='cfa.q1-coverage-probe/v1';task_id='Q1-COV-001';quarter_id='2026Q1';run_id=$runId;started_utc=$started;finished_utc=[DateTime]::UtcNow.ToString('o');collection_status=$(if($script:Issues.Count -eq 0){'PASS'}else{'FAIL'});checks_status=$reconciliation.status;task_status='UNVERIFIED';local_status='UNVERIFIED';stage1_status='BLOCKED';census_receipt_sha256=$ExpectedCensusReceiptSha256;census_repository_head=$census.repository_head;manifest_sha256=$manifestSha;sot_sha256=$sotSha;repository_head=$head[0];runner_sha256=(Get-Sha $PSCommandPath);code_files=$codeFiles;powershell_version=$PSVersionTable.PSVersion.ToString();interval=$manifest.interval;archive_sha256=$sourceRow.sha256;archive_length_bytes=$sourceRow.length_bytes;postgres=@{host=$PgHost;port=$PgPort;user=$PgUser;databases=@('srp','cfa');read_only_required=$true;statement_timeout_seconds=$StatementTimeoutSeconds};errors_count=$script:Issues.Count;artifacts=$artifacts}
    $outReceipt=Join-Path $runDir 'receipt.json';Write-Json $outReceipt $receipt
    Write-Host "Collection: $($receipt.collection_status); Checks: $($receipt.checks_status); Q1-COV-001-LOCAL: UNVERIFIED; Stage 1: BLOCKED"
    Write-Host "Receipt: $outReceipt"
    Write-Host "Receipt SHA-256: $(Get-Sha $outReceipt)"
    $exitCode=if($script:Issues.Count -eq 0 -and $failed -eq 0){0}else{2}
} catch {
    Write-Host 'Q1 COVERAGE PROBE: FAIL'; Write-Host $_.Exception.Message
    if($null -ne $runDir) {
        $exitCode=2;Add-Issue 'RUN' 'Unexpected failure; incomplete evidence must not be accepted.'
        try{Write-Json (Join-Path $runDir 'failure.json') @($script:Issues.ToArray())}catch{}
    }
} finally {
    if($null -ne $archiveLock){$archiveLock.Dispose()}
    if($secretPtr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)}
    foreach($name in $saved.Keys) {
        if($null -eq $saved[$name]){Remove-Item -LiteralPath ('Env:'+$name) -ErrorAction SilentlyContinue}
        else{[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
    }
}
exit $exitCode
