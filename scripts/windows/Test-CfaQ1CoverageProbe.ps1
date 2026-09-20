#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$TestOutputRoot = '',
    [switch]$PostgresIntegration,
    [string]$PsqlPath = '',
    [string]$DisposableDataDirectory = '',
    [string]$PgHost = '127.0.0.1',
    [int]$PgPort = 55432,
    [string]$PgUser = 'cfa_census_ci'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Checks = New-Object 'System.Collections.Generic.List[string]'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false,$true)
$script:Sentinel = 'cfa-q1-test-placeholder-not-secret'

function Assert-ProbeTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Q1 coverage test failed: $Message" }
}

function Restore-TestEnvironmentVariable {
    param([string]$Name,[AllowNull()][object]$Value)
    if ($null -eq $Value) { Remove-Item -LiteralPath ('Env:' + $Name) -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($Name,$Value,'Process') }
}

function Get-QuotedNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW/C-runtime quoting; also accepted by .NET on Unix.
    $escaped = [regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped = [regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"' + $escaped + '"'
}

function Invoke-TestProcess {
    param([string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds = 180,[AllowNull()][object]$InputText = $null)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = (($Arguments | ForEach-Object { Get-QuotedNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = ($null -ne $InputText)
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Unable to start test subprocess.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputText) {
            # Native Windows argv is not a Unicode SQL transport. Write the
            # exact UTF-8 bytes to psql stdin, without shell or code-page conversion.
            $inputBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$InputText)
            $process.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw "Test subprocess exceeded $TimeoutSeconds seconds."
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            exit_code = $process.ExitCode
            stdout = $stdout.GetAwaiter().GetResult()
            stderr = $stderr.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CanonicalSha {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path,(New-Object System.Text.UTF8Encoding($false,$true)))
    $text = $text.Replace("`r`n","`n").Replace("`r","`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash((New-Object System.Text.UTF8Encoding($false)).GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function New-TestFile {
    param([string]$Path,[AllowEmptyString()][string]$Text)
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path,$Text,(New-Object System.Text.UTF8Encoding($false)))
}

function Write-TestJson {
    param([string]$Path,[AllowNull()][object]$Value)
    New-TestFile $Path (ConvertTo-Json -InputObject $Value -Depth 40)
}

function Read-TestJson {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path,$script:Utf8) | ConvertFrom-Json
}

function Invoke-Probe {
    param([string]$Name,[string[]]$Arguments,[int]$ExpectedExit)
    $result = Invoke-TestProcess $script:ShellExecutable (@('-NoLogo','-NoProfile','-NonInteractive','-File',$script:Runner,'-RepoRoot',$script:ResolvedRepo) + $Arguments) 100
    Assert-ProbeTest (-not (($result.stdout + $result.stderr).Contains($script:Sentinel))) "$Name must not disclose PGPASSWORD."
    Assert-ProbeTest ($result.exit_code -eq $ExpectedExit) ("{0}: expected exit {1}, got {2}. stdout: {3} stderr: {4}" -f $Name,$ExpectedExit,$result.exit_code,$result.stdout,$result.stderr)
    $script:Checks.Add($Name)
    Write-Host "PASS: $Name"
    return $result
}

function New-ZipFixture {
    param([string]$Path,[string]$Mode = 'valid')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $first = "1767225600,10,12,9,11,3,2`n1767225660,11,13,10,12,4,3`n"
    $second = "1775001480,20,22,19,21,5,4`n1775001540,21,23,20,22,6,5`n"
    switch ($Mode) {
        'empty' { $first = ''; $second = '' }
        'csv' { $first = "1767225600,10,12,9,11,3`n" }
        'duplicate-time' { $first = "1767225600,10,12,9,11,3,2`n1767225600,10,12,9,11,3,2`n" }
        'decreasing-time' { $first = "1767225660,10,12,9,11,3,2`n1767225600,10,12,9,11,3,2`n" }
        'before-q1' { $first = "1767225540,10,12,9,11,3,2`n" }
        'at-q1-end' { $first = "1775001600,10,12,9,11,3,2`n" }
        'off-minute' { $first = "1767225601,10,12,9,11,3,2`n" }
        'nonfinite' { $first = "1767225600,NaN,12,9,11,3,2`n" }
        'invalid-values' { $first = "1767225600,10,8,9,11,-3,2.5`n" }
    }
    $members = @(
        [pscustomobject]@{name='XBTUSD_1.csv';bytes=$script:Utf8.GetBytes($first)},
        [pscustomobject]@{name='ETHUSD_1.csv';bytes=$script:Utf8.GetBytes($second)},
        # Deliberately not a CSV: other intervals must only be hashed.
        [pscustomobject]@{name='XBTUSD_5.csv';bytes=$script:Utf8.GetBytes('other interval synthetic bytes')}
    )
    if ($Mode -ceq 'utf8') { $members[0].bytes = [byte[]]@(0xc3,0x28,0x0a) }
    if ($Mode -ceq 'unsafe-path') { $members[0].name = '../XBTUSD_1.csv' }
    if ($Mode -ceq 'duplicate-path') { $members[1].name = 'XBTUSD_1.csv' }
    $stream = [System.IO.File]::Open($Path,[System.IO.FileMode]::Create,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    $zip = New-Object System.IO.Compression.ZipArchive($stream,[System.IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach ($member in $members) {
            $entry = $zip.CreateEntry($member.name)
            $output = $entry.Open()
            try { $output.Write($member.bytes,0,$member.bytes.Length) }
            finally { $output.Dispose() }
        }
    }
    finally { $zip.Dispose(); $stream.Dispose() }
}

function Update-CensusArtifacts {
    param([string]$CensusDirectory)
    $receiptPath = Join-Path $CensusDirectory 'receipt.json'
    $receipt = Read-TestJson $receiptPath
    foreach ($artifact in $receipt.artifacts) {
        $path = Join-Path $CensusDirectory $artifact.path
        $artifact.sha256 = Get-Sha $path
        $artifact.bytes = (Get-Item -LiteralPath $path).Length
    }
    Write-TestJson $receiptPath $receipt
}

function New-SyntheticFixture {
    param([string]$Name,[string]$ArchiveMode = 'valid')
    $directory = Join-Path $script:RunRoot ($Name + " space 'quote' " + [char]0x03a9)
    $kraken = Join-Path $directory 'Kraken'
    $evidence = Join-Path $directory 'CFA-local'
    $census = Join-Path $evidence 'resource-census/synthetic'
    [System.IO.Directory]::CreateDirectory($kraken) | Out-Null
    [System.IO.Directory]::CreateDirectory($census) | Out-Null
    $archive = Join-Path $kraken 'Kraken_OHLCVT_Q1_2026.zip'
    New-ZipFixture $archive $ArchiveMode
    $file = [ordered]@{root_id='KRAKEN';relative_path='Kraken_OHLCVT_Q1_2026.zip';extension='.zip';length_bytes=(Get-Item -LiteralPath $archive).Length;last_write_utc=(Get-Item -LiteralPath $archive).LastWriteTimeUtc.ToString('o');sha256=(Get-Sha $archive);status='PASS'}
    New-TestFile (Join-Path $census 'files.jsonl') ((ConvertTo-Json -InputObject $file -Compress) + "`n")
    $catalogs = @('srp','cfa') | ForEach-Object {
        [ordered]@{database_name=$_;server_version='synthetic';read_only='on';status='PASS';schemas=@();relations=@();columns=@()}
    }
    Write-TestJson (Join-Path $census 'catalogs.json') @($catalogs)
    Write-TestJson (Join-Path $census 'errors.json') @()
    $receipt = [ordered]@{
        schema='cfa.resource-census/v1';task_id='Q1-RES-001';quarter_id='2026Q1';run_id='synthetic';started_utc='2026-09-20T00:00:00Z';finished_utc='2026-09-20T00:00:01Z'
        collection_status='PASS';task_status='UNVERIFIED';stage1_status='BLOCKED';manifest_sha256=$script:ManifestSha;manifest_canonicalization='UTF8_LF_NO_BOM';sot_sha256=(Get-Sha $script:SotPath)
        repository_head=$script:RepositoryHead;runner_sha256=(Get-Sha $script:CensusRunner);runner_hash_policy='EXACT_LOCAL_BYTES';powershell_version=[string]$PSVersionTable.PSVersion
        roots=@([ordered]@{id='KRAKEN';path=$kraken;status='PASS';files_count=1},[ordered]@{id='CFA_LOCAL';path=$evidence;status='PASS';files_count=0})
        output_exclusion=(Join-Path $evidence 'resource-census');files_count=1;errors_count=0
        postgres=[ordered]@{host=$PgHost;port=$PgPort;user=$PgUser;maintenance_database='postgres';database_count=2;read_only_required=$true}
        estimated_rows_policy='synthetic fixture';coverage_status='UNVERIFIED';artifacts=@()
    }
    $receipt.artifacts = @('files.jsonl','catalogs.json','errors.json') | ForEach-Object {
        $path = Join-Path $census $_
        [ordered]@{path=$_;sha256=(Get-Sha $path);bytes=(Get-Item -LiteralPath $path).Length}
    }
    Write-TestJson (Join-Path $census 'receipt.json') $receipt
    return [pscustomobject]@{directory=$directory;kraken=$kraken;evidence=$evidence;census=$census;archive=$archive}
}

function Get-ProbeArguments {
    param([object]$Fixture,[string]$Psql = $script:ShellExecutable,[int]$Port = $PgPort)
    return @('-CensusDirectory',$Fixture.census,'-ExpectedCensusReceiptSha256',(Get-Sha (Join-Path $Fixture.census 'receipt.json')),'-PgHost',$PgHost,'-PgPort',[string]$Port,'-PgUser',$PgUser,'-PsqlPath',$Psql)
}

function Get-ProbeReceipts {
    param([object]$Fixture)
    $root = Join-Path $Fixture.evidence 'q1-coverage-probe/2026Q1'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Filter 'receipt.json' -Recurse -File | ForEach-Object { $_.FullName })
}

function Assert-ProbeReceipt {
    param([string]$Path,[string]$Collection,[string]$Checks = '')
    $directory = Split-Path -Parent $Path
    $receipt = Read-TestJson $Path
    Assert-ProbeTest ($receipt.schema -ceq 'cfa.q1-coverage-probe/v1' -and $receipt.task_id -ceq 'Q1-COV-001') 'Receipt must identify the frozen Q1 coverage format.'
    Assert-ProbeTest ($receipt.quarter_id -ceq '2026Q1') 'Receipt must identify the authorized quarter.'
    Assert-ProbeTest ($receipt.collection_status -ceq $Collection) "Expected collection $Collection."
    if ($Checks) { Assert-ProbeTest ($receipt.checks_status -ceq $Checks) "Expected checks $Checks." }
    Assert-ProbeTest ($receipt.task_status -ceq 'UNVERIFIED' -and $receipt.stage1_status -ceq 'BLOCKED' -and $receipt.local_status -ceq 'UNVERIFIED') 'Fixture evidence cannot approve any task or stage.'
    Assert-ProbeTest ($receipt.runner_sha256 -ceq (Get-Sha $script:Runner)) 'Receipt must bind the exact tested runner bytes.'
    Assert-ProbeTest ($receipt.repository_head -ceq $script:RepositoryHead) 'Receipt must bind the exact tested repository HEAD.'
    Assert-ProbeTest ($receipt.manifest_sha256 -ceq $script:ManifestSha -and $receipt.sot_sha256 -ceq (Get-Sha $script:SotPath)) 'Frozen manifest and SoT must match.'
    Assert-ProbeTest ($receipt.artifacts -is [System.Array]) 'Artifacts must preserve array shape.'
    $paths = @($receipt.artifacts | ForEach-Object { [string]$_.path })
    Assert-ProbeTest ($paths.Count -eq 6 -and @($paths | Select-Object -Unique).Count -eq 6) 'Exactly six unique artifacts must be inventoried.'
    foreach ($required in @('archive-members.jsonl','archive-summary.json','market.json','news.json','reconciliation.json','errors.json')) {
        Assert-ProbeTest ($paths -ccontains $required) "Required evidence is absent: $required"
    }
    foreach ($artifact in $receipt.artifacts) {
        Assert-ProbeTest (-not [System.IO.Path]::IsPathRooted([string]$artifact.path)) 'Artifact paths must be relative.'
        $artifactPath = [System.IO.Path]::GetFullPath((Join-Path $directory $artifact.path))
        Assert-ProbeTest ($artifactPath.StartsWith($directory + [System.IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Artifact paths must remain inside the run.'
        Assert-ProbeTest ((Get-Sha $artifactPath) -ceq $artifact.sha256 -and (Get-Item -LiteralPath $artifactPath).Length -eq $artifact.bytes) 'Artifact hashes and byte counts must match the exact file.'
        $text = [System.IO.File]::ReadAllText($artifactPath,$script:Utf8)
        Assert-ProbeTest (-not $text.Contains($script:Sentinel)) 'Evidence may not contain the password sentinel.'
        Assert-ProbeTest (-not $text.Contains('URL_MUST_NOT_BE_EXPORTED')) 'News evidence must exclude URL fields.'
    }
    $errorsText = [System.IO.File]::ReadAllText((Join-Path $directory 'errors.json'),$script:Utf8)
    $errors = ('{"items":' + $errorsText + '}') | ConvertFrom-Json
    Assert-ProbeTest ($errors.items -is [System.Array] -and @($errors.items).Count -eq $receipt.errors_count) 'Empty and nonempty errors must preserve array shape and reconcile.'
    $reconciliation = Read-TestJson (Join-Path $directory 'reconciliation.json')
    Assert-ProbeTest ($reconciliation.checks -is [System.Array]) 'Reconciliation checks must always be an array.'
    Assert-ProbeTest ($reconciliation.member_lineage_status -ceq 'UNVERIFIED' -and $reconciliation.row_value_equivalence_status -ceq 'UNVERIFIED') 'Matching aggregates must not overclaim member lineage or raw-row equivalence.'
    return [pscustomobject]@{receipt=$receipt;directory=$directory;archive=(Read-TestJson (Join-Path $directory 'archive-summary.json'));market=(Read-TestJson (Join-Path $directory 'market.json'));news=(Read-TestJson (Join-Path $directory 'news.json'));reconciliation=$reconciliation}
}

function Invoke-CollectionCase {
    param([string]$Name,[object]$Fixture,[int]$ExpectedExit,[string]$Collection,[string]$Checks = '',[string[]]$ExtraArguments = @())
    $before = @(Get-ProbeReceipts $Fixture)
    Invoke-Probe $Name ((Get-ProbeArguments $Fixture $script:ResolvedPsql) + $ExtraArguments) $ExpectedExit | Out-Null
    $after = @(Get-ProbeReceipts $Fixture | Where-Object { $before -notcontains $_ })
    Assert-ProbeTest ($after.Count -eq 1) 'Every collection must create exactly one distinct receipt.'
    return Assert-ProbeReceipt $after[0] $Collection $Checks
}

function Invoke-FixtureSql {
    param([string]$Database,[string]$Sql)
    $result = Invoke-TestProcess $script:ResolvedPsql @('-X','-w','-h',$PgHost,'-p',[string]$PgPort,'-U',$PgUser,'-d',('postgresql:///' + [Uri]::EscapeDataString($Database)),'-v','ON_ERROR_STOP=1','-A','-t','-f','-') 45 $Sql
    Assert-ProbeTest ($result.exit_code -eq 0) ('Disposable PostgreSQL fixture command failed: ' + $result.stderr)
    return $result.stdout.Trim()
}

# Column names and PostgreSQL types mirror the observed census catalogs.
# Deliberately omit constraints so corruption cases can be constructed explicitly.
function New-DatabaseFixtures {
    Invoke-FixtureSql 'postgres' 'CREATE DATABASE srp;' | Out-Null
    Invoke-FixtureSql 'srp' @'
CREATE SCHEMA srp;
CREATE TABLE srp.ohlcvt_1m_2026q1 (
  pair_id bigint,
  ts_utc timestamp with time zone,
  open_price double precision,
  high_price double precision,
  low_price double precision,
  close_price double precision,
  vwap double precision,
  volume double precision,
  trade_count integer,
  source_archive_id bigint,
  processing_run_id bigint
);
CREATE TABLE srp.source_archives (
  source_archive_id bigint,
  exchange text,
  dataset_type text,
  archive_name text,
  archive_full_path text,
  period_label text,
  size_bytes bigint,
  sha256 character(64),
  inventory_json_path text,
  inventory_csv_path text,
  zip_entry_count integer,
  one_minute_files integer,
  pair_count integer,
  status text,
  registered_at_utc timestamp with time zone,
  imported_at_utc timestamp with time zone
);
CREATE TABLE srp.market_pairs (
  pair_id bigint,
  exchange text,
  pair_code text,
  base_asset text,
  quote_asset text,
  market_type text,
  first_seen_utc timestamp with time zone,
  last_seen_utc timestamp with time zone,
  metadata_json jsonb
);
CREATE TABLE srp.processing_runs (
  processing_run_id bigint,
  process_name text,
  process_version text,
  source_archive_id bigint,
  config_json jsonb,
  config_sha256 character(64),
  started_at_utc timestamp with time zone,
  completed_at_utc timestamp with time zone,
  status text,
  input_rows bigint,
  output_rows bigint,
  error_text text
);
'@ | Out-Null
    Invoke-FixtureSql 'postgres' 'CREATE DATABASE cfa;' | Out-Null
    Invoke-FixtureSql 'cfa' @'
CREATE SCHEMA source_news;
CREATE TABLE source_news.source_contracts (
  contract_sha256 text,
  source_product text,
  interval_start_utc timestamp with time zone,
  interval_end_exclusive_utc timestamp with time zone,
  cadence_minutes integer,
  nominal_slot_count integer,
  url_template text,
  created_at_utc timestamp with time zone,
  created_by_git_commit text
);
CREATE TABLE source_news.source_slots (
  contract_sha256 text,
  object_key text,
  archive_timestamp_utc timestamp with time zone,
  secure_url text,
  status text,
  attempt_count integer,
  http_status integer,
  expected_content_length bigint,
  observed_size_bytes bigint,
  payload_sha256 text,
  provider_md5_base64 text,
  observed_md5_base64 text,
  provider_md5_status text,
  local_relative_path text,
  zip_entry_count integer,
  last_attempt_at_utc timestamp with time zone,
  error_code text
);
'@ | Out-Null
}

function Set-ValidMarketRows {
    Invoke-FixtureSql 'srp' @'
TRUNCATE srp.ohlcvt_1m_2026q1;
INSERT INTO srp.ohlcvt_1m_2026q1 VALUES
(1,'2026-01-01 00:00:00+00',10,12,9,11,NULL,3,2,1,1),
(1,'2026-01-01 00:01:00+00',11,13,10,12,NULL,4,3,1,1),
(2,'2026-03-31 23:58:00+00',20,22,19,21,NULL,5,4,1,1),
(2,'2026-03-31 23:59:00+00',21,23,20,22,NULL,6,5,1,1);
'@ | Out-Null
}

function Set-ValidLineage {
    param([object]$Fixture)
    $hash = Get-Sha $Fixture.archive
    $size = (Get-Item -LiteralPath $Fixture.archive).Length
    Invoke-FixtureSql 'srp' @"
TRUNCATE srp.source_archives, srp.market_pairs, srp.processing_runs;
INSERT INTO srp.source_archives
(source_archive_id,exchange,dataset_type,archive_name,archive_full_path,period_label,size_bytes,sha256,zip_entry_count,one_minute_files,pair_count,status,registered_at_utc)
VALUES (1,'kraken','OHLCVT','Kraken_OHLCVT_Q1_2026.zip','synthetic/fixture.zip','2026Q1',$size,'$hash',3,2,2,'IMPORTED','2026-09-20 00:00+00');
INSERT INTO srp.market_pairs (pair_id,exchange,pair_code,base_asset,quote_asset,market_type,metadata_json)
VALUES (1,'kraken','XBTUSD','XBT','USD','spot','{}'),(2,'kraken','ETHUSD','ETH','USD','spot','{}');
INSERT INTO srp.processing_runs (processing_run_id,process_name,process_version,source_archive_id,config_json,started_at_utc,status,input_rows,output_rows)
VALUES (1,'synthetic-import','fixture',1,'{}','2026-09-20 00:00+00','SUCCESS',4,4);
"@ | Out-Null
}

function Set-ValidNewsRows {
    Invoke-FixtureSql 'cfa' @'
TRUNCATE source_news.source_contracts, source_news.source_slots;
INSERT INTO source_news.source_contracts VALUES
(repeat('a',64),'synthetic product','2026-01-01 00:00+00','2026-04-01 00:00+00',15,8640,'URL_MUST_NOT_BE_EXPORTED','2026-09-20 00:00+00',NULL);
INSERT INTO source_news.source_slots
(contract_sha256,object_key,archive_timestamp_utc,secure_url,status,attempt_count,http_status,expected_content_length,observed_size_bytes,payload_sha256)
VALUES
(repeat('a',64),'q1-start','2026-01-01 00:00+00','URL_MUST_NOT_BE_EXPORTED','SUCCESS',1,200,25,25,repeat('b',64)),
(repeat('a',64),'q1-last','2026-03-31 23:45+00','URL_MUST_NOT_BE_EXPORTED','SUCCESS',1,200,25,25,repeat('c',64)),
(repeat('a',64),'before-q1','2025-12-31 23:45+00','URL_MUST_NOT_BE_EXPORTED','SUCCESS',1,200,25,25,repeat('d',64)),
(repeat('a',64),'at-q1-end','2026-04-01 00:00+00','URL_MUST_NOT_BE_EXPORTED','SUCCESS',1,200,25,25,repeat('e',64));
'@ | Out-Null
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '../..' }
$script:ResolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$script:Runner = Join-Path $script:ResolvedRepo 'scripts/windows/Invoke-CfaQ1CoverageProbe.ps1'
$script:CensusRunner = Join-Path $script:ResolvedRepo 'scripts/windows/Invoke-CfaResourceCensus.ps1'
$script:ShellExecutable = (Get-Process -Id $PID).Path
$script:ResolvedPsql = $script:ShellExecutable
$manifestPath = Join-Path $script:ResolvedRepo 'config/quarters/2026Q1.json'
$manifest = Read-TestJson $manifestPath
$script:ManifestSha = Get-CanonicalSha $manifestPath
$script:SotPath = Join-Path $script:ResolvedRepo $manifest.authority.sot_path
$git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$head = Invoke-TestProcess $git @('-C',$script:ResolvedRepo,'rev-parse','HEAD')
Assert-ProbeTest ($head.exit_code -eq 0 -and $head.stdout.Trim() -cmatch '^[0-9a-f]{40}$') 'Exact checkout HEAD must be readable.'
$script:RepositoryHead = $head.stdout.Trim()
if ([string]::IsNullOrWhiteSpace($TestOutputRoot)) { $TestOutputRoot = [System.IO.Path]::GetTempPath() }
$script:RunRoot = Join-Path ([System.IO.Path]::GetFullPath($TestOutputRoot)) ('cfa-q1-probe-tests-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($script:RunRoot) | Out-Null
Write-Host "Synthetic test evidence: $script:RunRoot"
$originalEnvironment = @{}
foreach ($name in @('PGPASSWORD','PGCLIENTENCODING','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGDATABASE','PGOPTIONS','PGHOST','PGPORT','PGUSER','PGPASSFILE','PGSSLMODE','PGTARGETSESSIONATTRS')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
}
try {
    [Environment]::SetEnvironmentVariable('PGPASSWORD',$script:Sentinel,'Process')
    [Environment]::SetEnvironmentVariable('PGCLIENTENCODING','UTF8','Process')
    foreach ($scriptPath in @($script:Runner,$PSCommandPath,(Join-Path $script:ResolvedRepo 'scripts/windows/Get-CfaQ1CoverageQueries.ps1'))) {
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
        Assert-ProbeTest ($parseErrors.Count -eq 0) ("PowerShell parsing: " + $scriptPath)
        if ($scriptPath -ceq $script:Runner) {
            $parameters = @{}
            foreach ($parameter in $ast.ParamBlock.Parameters) { $parameters[$parameter.Name.VariablePath.UserPath] = $parameter }
            Assert-ProbeTest ($parameters.PgHost.DefaultValue.Value -ceq 'localhost') 'Default host must remain localhost.'
            Assert-ProbeTest ($parameters.PgPort.DefaultValue.Value -eq 5432) 'Default port must remain 5432.'
            Assert-ProbeTest ($parameters.PgUser.DefaultValue.Value -ceq 'postgres') 'Default role must remain postgres.'
            Assert-ProbeTest ($parameters.StatementTimeoutSeconds.DefaultValue.Value -eq 300) 'Default statement timeout must remain bounded at 300 seconds.'
        }
    }
    $script:Checks.Add('Parse runner, query module and test; verify target endpoint defaults')
    Invoke-Probe 'Runner and archive component self-tests' @('-SelfTest') 0 | Out-Null

    $good = New-SyntheticFixture 'valid'
    $goodArgs = Get-ProbeArguments $good
    Invoke-Probe 'Missing census directory fails preflight' @('-CensusDirectory',(Join-Path $script:RunRoot 'missing'),'-PsqlPath',$script:ShellExecutable) 1 | Out-Null
    $badExpected = @($goodArgs)
    $badExpected[[Array]::IndexOf($badExpected,'-ExpectedCensusReceiptSha256') + 1] = ('0' * 64)
    Invoke-Probe 'Wrong explicitly expected census receipt hash fails preflight' $badExpected 1 | Out-Null
    $damaged = New-SyntheticFixture 'tampered-census'
    [System.IO.File]::AppendAllText((Join-Path $damaged.census 'catalogs.json'),' ',$script:Utf8)
    Invoke-Probe 'Tampered census artifact fails before collection' (Get-ProbeArguments $damaged) 1 | Out-Null
    $missingArtifact = New-SyntheticFixture 'missing-census-artifact'
    Remove-Item -LiteralPath (Join-Path $missingArtifact.census 'files.jsonl')
    Invoke-Probe 'Missing census artifact fails before collection' (Get-ProbeArguments $missingArtifact) 1 | Out-Null
    $badShape = New-SyntheticFixture 'bad-census-shape'
    New-TestFile (Join-Path $badShape.census 'catalogs.json') '{}'
    Update-CensusArtifacts $badShape.census
    Invoke-Probe 'Hash-valid malformed census array fails preflight' (Get-ProbeArguments $badShape) 1 | Out-Null
    foreach ($fixture in @($good,$damaged,$missingArtifact,$badShape)) { Assert-ProbeTest (@(Get-ProbeReceipts $fixture).Count -eq 0) 'Census preflight failures must not create run evidence.' }

    foreach ($mode in @('empty','csv','utf8','duplicate-time','decreasing-time','before-q1','at-q1-end','off-minute','nonfinite','invalid-values','unsafe-path','duplicate-path')) {
        $fixture = New-SyntheticFixture ('archive-' + $mode) $mode
        $result = Invoke-CollectionCase ("Archive rejects $mode and blocks both database probes") $fixture 2 'FAIL'
        Assert-ProbeTest ($result.market.status -ceq 'BLOCKED' -and $result.news.status -ceq 'BLOCKED') 'Archive failure must block every database query.'
    }

    $tamperedArchive = New-SyntheticFixture 'tampered-archive'
    [System.IO.File]::AppendAllText($tamperedArchive.archive,'tampered',$script:Utf8)
    $tamperedResult = Invoke-CollectionCase 'Archive hash mismatch leaves explicit failure evidence' $tamperedArchive 2 'FAIL'
    Assert-ProbeTest ($tamperedResult.market.status -ceq 'BLOCKED' -and $tamperedResult.news.status -ceq 'BLOCKED') 'Tampered archive must block database probes.'
    $missingArchive = New-SyntheticFixture 'missing-archive'
    Remove-Item -LiteralPath $missingArchive.archive
    Invoke-Probe 'Missing archive fails preflight' (Get-ProbeArguments $missingArchive) 1 | Out-Null

    if ($env:OS -ceq 'Windows_NT') {
        $junction = Join-Path $script:RunRoot 'junction-to-census'
        New-Item -ItemType Junction -Path $junction -Value $good.census | Out-Null
        $junctionArgs = @($goodArgs)
        $junctionArgs[[Array]::IndexOf($junctionArgs,'-CensusDirectory') + 1] = $junction
        Invoke-Probe 'Junction ancestor in census path is rejected' $junctionArgs 1 | Out-Null
    }

    if ($PostgresIntegration) {
        Assert-ProbeTest ($PgHost -ceq '127.0.0.1' -and $PgPort -eq 55432 -and $PgUser -ceq 'cfa_census_ci') 'Fixture DDL is restricted to the isolated CI endpoint and role.'
        Assert-ProbeTest (-not [string]::IsNullOrWhiteSpace($DisposableDataDirectory)) 'Explicit disposable PostgreSQL data directory is mandatory.'
        $expectedData = (Resolve-Path -LiteralPath $DisposableDataDirectory).ProviderPath.TrimEnd('\','/')
        Assert-ProbeTest (Test-Path -LiteralPath (Join-Path $expectedData 'PG_VERSION') -PathType Leaf) 'Disposable directory must contain PG_VERSION.'
        Assert-ProbeTest (Test-Path -LiteralPath (Join-Path $expectedData 'postmaster.pid') -PathType Leaf) 'Disposable instance must be running.'
        $script:ResolvedPsql = (Resolve-Path -LiteralPath $PsqlPath).ProviderPath
        $actualData = Invoke-FixtureSql 'postgres' "SELECT current_setting('data_directory');"
        Assert-ProbeTest ([System.IO.Path]::GetFullPath($actualData).TrimEnd('\','/') -ieq $expectedData) 'Connected server must match the explicit disposable data directory before any DDL.'
        $script:Checks.Add('Disposable PostgreSQL identity proved before fixture DDL')
        New-DatabaseFixtures
        Set-ValidLineage $good
        Set-ValidMarketRows
        Set-ValidNewsRows

        # Generate the integration binding through the exact delivered census
        # subprocess, using only synthetic roots and the disposable instance.
        $censusResult = Invoke-TestProcess $script:ShellExecutable @('-NoLogo','-NoProfile','-NonInteractive','-File',$script:CensusRunner,'-RepoRoot',$script:ResolvedRepo,'-KrakenRoot',$good.kraken,'-EvidenceRoot',$good.evidence,'-PsqlPath',$script:ResolvedPsql,'-PgHost',$PgHost,'-PgPort',[string]$PgPort,'-PgUser',$PgUser)
        Assert-ProbeTest ($censusResult.exit_code -eq 0) ('Synthetic census generation failed: ' + $censusResult.stdout + $censusResult.stderr)
        $censusPaths = @(Get-ChildItem -LiteralPath (Join-Path $good.evidence 'resource-census') -Filter 'receipt.json' -Recurse -File | Where-Object { $_.DirectoryName -cne $good.census })
        Assert-ProbeTest ($censusPaths.Count -eq 1) 'Exactly one actual census must bind the integration fixture.'
        $good.census = $censusPaths[0].DirectoryName
        $preserved = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $good.kraken,$good.census -File -Recurse)) { $preserved[$file.FullName] = Get-Sha $file.FullName }
        $tracked = Invoke-TestProcess $git @('-C',$script:ResolvedRepo,'ls-files','-z')
        Assert-ProbeTest ($tracked.exit_code -eq 0) 'Tracked-file inventory must be readable.'
        foreach ($relative in $tracked.stdout.Split([char]0)) {
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                $path = Join-Path $script:ResolvedRepo $relative
                if (Test-Path -LiteralPath $path -PathType Leaf) { $preserved[$path] = Get-Sha $path }
            }
        }
        foreach ($name in @('Invoke-CfaQ1CoverageProbe.ps1','Get-CfaQ1CoverageQueries.ps1','CfaQ1ArchiveProbe.cs')) {
            $path = Join-Path $script:ResolvedRepo ('scripts/windows/' + $name)
            $preserved[$path] = Get-Sha $path
        }
        $bogusService = Join-Path $script:RunRoot 'bogus-service.conf'
        New-TestFile $bogusService "[q1_bogus]`nhost=192.0.2.1`nport=1`nuser=wrong`ndbname=wrong`n"
        [Environment]::SetEnvironmentVariable('PGSERVICE','q1_bogus','Process')
        [Environment]::SetEnvironmentVariable('PGSERVICEFILE',$bogusService,'Process')
        [Environment]::SetEnvironmentVariable('PGHOSTADDR','192.0.2.1','Process')
        [Environment]::SetEnvironmentVariable('PGDATABASE','wrong','Process')
        [Environment]::SetEnvironmentVariable('PGOPTIONS','-c default_transaction_read_only=off -c search_path=public','Process')
        $first = Invoke-CollectionCase 'Exact Q1 runner succeeds despite inherited libpq routing overrides' $good 0 'PASS' 'PASS'
        foreach ($name in @('PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGDATABASE','PGOPTIONS')) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
        Assert-ProbeTest ($first.archive.member_count -eq 3 -and $first.archive.one_minute_member_count -eq 2 -and $first.archive.rows -eq 4) 'Archive inventory must include every member and count only one-minute rows.'
        $memberLines = @([System.IO.File]::ReadLines((Join-Path $first.directory 'archive-members.jsonl'),$script:Utf8))
        Assert-ProbeTest ($memberLines.Count -eq 3) 'Streaming member JSONL must contain one record per ZIP member.'
        $members = @($memberLines | ForEach-Object { $_ | ConvertFrom-Json })
        $zip = [System.IO.Compression.ZipFile]::OpenRead($good.archive)
        try {
            foreach ($entry in $zip.Entries) {
                $observed = @($members | Where-Object { $_.member_path -ceq $entry.FullName })
                Assert-ProbeTest ($observed.Count -eq 1) 'Every exact member name must appear once.'
                $source = $entry.Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $hash = (($sha.ComputeHash($source) | ForEach-Object { $_.ToString('x2') }) -join '') }
                finally { $source.Dispose(); $sha.Dispose() }
                Assert-ProbeTest ($observed[0].sha256 -ceq $hash -and $observed[0].length_bytes -eq $entry.Length) 'Every uncompressed member hash and size must match independently read bytes.'
                Assert-ProbeTest ($observed[0].days -is [Array] -and $observed[0].errors -is [Array]) 'Member day and error inventories must preserve array shapes.'
                if ($entry.FullName -ceq 'XBTUSD_5.csv') { Assert-ProbeTest ($observed[0].is_one_minute -eq $false -and $observed[0].rows -eq 0) 'Other intervals must be hashed without one-minute CSV parsing.' }
            }
        }
        finally { $zip.Dispose() }
        Assert-ProbeTest ($first.market.source_archives -is [Array] -and @($first.market.source_archives).Count -eq 1 -and $first.market.processing_runs -is [Array] -and @($first.market.processing_runs).Count -eq 1) 'Singleton source and run lineage must remain arrays.'
        Assert-ProbeTest ($first.market.read_only -ceq 'on' -and $first.news.read_only -ceq 'on') 'Both database snapshots must prove READ ONLY.'
        Assert-ProbeTest ($first.market.transaction_isolation -ceq 'repeatable read' -and $first.news.transaction_isolation -ceq 'repeatable read') 'Both database snapshots must prove REPEATABLE READ.'
        Assert-ProbeTest ($first.market.time_zone -ceq 'UTC' -and $first.news.time_zone -ceq 'UTC') 'Both database snapshots must use UTC.'
        Assert-ProbeTest ($first.market.summary.total_rows -eq 4 -and $first.market.summary.q1_rows -eq 4 -and $first.market.summary.outside_q1_rows -eq 0) 'Market exact start and final-minute boundaries must reconcile.'
        Assert-ProbeTest ($first.market.per_pair -is [Array] -and @($first.market.per_pair).Count -eq 2) 'Two pair summaries must preserve array shape.'
        Assert-ProbeTest ($first.news.summary.q1_slot_rows -eq 2 -and $first.news.summary.outside_q1_slot_rows -eq 2) 'News Q1 must include the start and exclude the exact end.'
        Assert-ProbeTest ($first.news.contracts -is [Array] -and @($first.news.contracts).Count -eq 1) 'Singleton contracts must remain arrays.'
        foreach ($file in @(Get-ChildItem -LiteralPath $first.directory -File)) { $preserved[$file.FullName] = Get-Sha $file.FullName }
        $second = Invoke-CollectionCase 'Repeat execution preserves prior evidence in a distinct directory' $good 0 'PASS' 'PASS'
        Assert-ProbeTest ($first.directory -cne $second.directory) 'Run directories must be unique.'

        $environmentWrapper = Join-Path $script:RunRoot 'check-environment-restoration.ps1'
        $environmentArguments = Join-Path $script:RunRoot 'environment-runner-arguments.json'
        Write-TestJson $environmentArguments ([ordered]@{
            RepoRoot=$script:ResolvedRepo;CensusDirectory=$good.census
            ExpectedCensusReceiptSha256=(Get-Sha (Join-Path $good.census 'receipt.json'))
            PgHost=$PgHost;PgPort=$PgPort;PgUser=$PgUser;PsqlPath=$script:ResolvedPsql
        })
        New-TestFile $environmentWrapper @'
#requires -Version 5.1
param([string]$Runner,[string]$ArgumentsFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:PGHOST='192.0.2.1'; $env:PGPORT='1'; $env:PGUSER='wrong'; $env:PGDATABASE='wrong'
$env:PGOPTIONS='-c default_transaction_read_only=off'; $env:PGCONNECT_TIMEOUT='93'; $env:PGCLIENTENCODING='LATIN1'
$names=@('PGPASSWORD','PGOPTIONS','PGCONNECT_TIMEOUT','PGCLIENTENCODING','PGDATABASE','PGHOST','PGPORT','PGUSER','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGTARGETSESSIONATTRS')
$before=@{}
foreach($name in $names) { $before[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$argumentMetadata=[System.IO.File]::ReadAllText($ArgumentsFile,(New-Object System.Text.UTF8Encoding($false,$true))) | ConvertFrom-Json
$runnerParameters=@{}
foreach($property in $argumentMetadata.PSObject.Properties) { $runnerParameters[$property.Name]=$property.Value }
& $Runner @runnerParameters
if($LASTEXITCODE -ne 0) { throw 'Exact runner failed in environment restoration wrapper.' }
foreach($name in $names) {
    $after=[Environment]::GetEnvironmentVariable($name,'Process')
    if($after -cne $before[$name]) { throw ('Environment was not restored: '+$name) }
}
Write-Host 'ENVIRONMENT_RESTORATION_PASS'
'@
        $beforeEnvironmentReceipts = @(Get-ProbeReceipts $good)
        $environmentResult = Invoke-TestProcess $script:ShellExecutable @('-NoLogo','-NoProfile','-NonInteractive','-File',$environmentWrapper,'-Runner',$script:Runner,'-ArgumentsFile',$environmentArguments)
        Assert-ProbeTest ($environmentResult.exit_code -eq 0 -and $environmentResult.stdout.Contains('ENVIRONMENT_RESTORATION_PASS')) ('Environment restoration wrapper failed: ' + $environmentResult.stdout + $environmentResult.stderr)
        Assert-ProbeTest (-not ($environmentResult.stdout + $environmentResult.stderr).Contains($script:Sentinel)) 'Environment wrapper output must not disclose PGPASSWORD.'
        $environmentReceipts = @(Get-ProbeReceipts $good | Where-Object { $beforeEnvironmentReceipts -notcontains $_ })
        Assert-ProbeTest ($environmentReceipts.Count -eq 1) 'Environment wrapper must execute exactly one real collection.'
        Assert-ProbeReceipt $environmentReceipts[0] 'PASS' 'PASS' | Out-Null
        $script:Checks.Add('Exact runner restores inherited libpq environment in the invoking PowerShell process')

        Invoke-FixtureSql 'srp' "DELETE FROM srp.ohlcvt_1m_2026q1 WHERE pair_id=2 AND ts_utc='2026-03-31 23:59+00';" | Out-Null
        Invoke-CollectionCase 'Archive and database aggregate mismatch is an explicit failed check' $good 2 'PASS' 'FAIL' | Out-Null
        Set-ValidMarketRows
        foreach ($case in @(
            @{name='duplicate pair-time key';sql='INSERT INTO srp.ohlcvt_1m_2026q1 SELECT * FROM srp.ohlcvt_1m_2026q1 WHERE pair_id=1 LIMIT 1;'},
            @{name='nonfinite OHLCVT';sql="UPDATE srp.ohlcvt_1m_2026q1 SET open_price='NaN'::float8 WHERE pair_id=1;"},
            @{name='infinite OHLCVT';sql="UPDATE srp.ohlcvt_1m_2026q1 SET volume='Infinity'::float8 WHERE pair_id=1;"},
            @{name='invalid OHLCVT';sql='UPDATE srp.ohlcvt_1m_2026q1 SET high_price=1,volume=-1 WHERE pair_id=1;'},
            @{name='null required market value';sql='UPDATE srp.ohlcvt_1m_2026q1 SET open_price=NULL WHERE pair_id=1;'},
            @{name='unknown pair';sql='UPDATE srp.ohlcvt_1m_2026q1 SET pair_id=999 WHERE pair_id=1;'},
            @{name='missing source archive';sql='UPDATE srp.ohlcvt_1m_2026q1 SET source_archive_id=999 WHERE pair_id=1;'},
            @{name='missing processing run';sql='UPDATE srp.ohlcvt_1m_2026q1 SET processing_run_id=999 WHERE pair_id=1;'},
            @{name='outside market Q1 interval';sql="UPDATE srp.ohlcvt_1m_2026q1 SET ts_utc='2026-04-01 00:00+00' WHERE pair_id=1;"}
        )) {
            Invoke-FixtureSql 'srp' $case.sql | Out-Null
            Invoke-CollectionCase ('Market detects ' + $case.name) $good 2 'PASS' 'FAIL' | Out-Null
            Set-ValidMarketRows
        }
        Invoke-FixtureSql 'srp' 'UPDATE srp.processing_runs SET source_archive_id=999;' | Out-Null
        Invoke-CollectionCase 'Processing run archive mismatch fails lineage checks' $good 2 'PASS' 'FAIL' | Out-Null
        Set-ValidLineage $good

        Invoke-FixtureSql 'srp' 'ALTER TABLE srp.ohlcvt_1m_2026q1 ALTER COLUMN volume TYPE numeric;' | Out-Null
        $schemaFailure = Invoke-CollectionCase 'Schema drift fails market while preserving independent news discovery' $good 2 'FAIL' 'FAIL'
        Assert-ProbeTest ($schemaFailure.market.status -ceq 'FAIL' -and $schemaFailure.news.database_name -ceq 'cfa') 'Market failure must not erase independent news evidence.'
        Invoke-FixtureSql 'srp' 'ALTER TABLE srp.ohlcvt_1m_2026q1 ALTER COLUMN volume TYPE double precision;' | Out-Null

        Invoke-FixtureSql 'srp' 'TRUNCATE srp.ohlcvt_1m_2026q1;' | Out-Null
        $emptyMarket = Invoke-CollectionCase 'Empty market is explicit mismatch with empty arrays' $good 2 'PASS' 'FAIL'
        Assert-ProbeTest ($emptyMarket.market.per_pair -is [Array] -and @($emptyMarket.market.per_pair).Count -eq 0) 'Empty market summaries must remain arrays.'
        Set-ValidMarketRows
        Invoke-FixtureSql 'cfa' 'TRUNCATE source_news.source_slots, source_news.source_contracts;' | Out-Null
        $emptyNews = Invoke-CollectionCase 'Missing Q1 news contracts and slots remain explicit diagnostic evidence' $good 2 'PASS' 'FAIL'
        Assert-ProbeTest ($emptyNews.news.summary.q1_contracts_missing -eq $true -and $emptyNews.news.summary.q1_slots_missing -eq $true) 'Empty news population must be explicitly marked missing.'
        Assert-ProbeTest ($emptyNews.news.contracts -is [Array] -and @($emptyNews.news.contracts).Count -eq 0 -and $emptyNews.news.per_contract -is [Array] -and @($emptyNews.news.per_contract).Count -eq 0) 'Empty news collections must remain arrays.'
        Set-ValidNewsRows

        # Reserve an unserved local endpoint, and explicitly bind that synthetic
        # endpoint in its census receipt, to exercise connection failure after preflight.
        $offline = New-SyntheticFixture 'offline-endpoint'
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback,0)
        $listener.Start()
        try {
            $offlinePort = $listener.LocalEndpoint.Port
            $offlineReceipt = Read-TestJson (Join-Path $offline.census 'receipt.json')
            $offlineReceipt.postgres.port = $offlinePort
            Write-TestJson (Join-Path $offline.census 'receipt.json') $offlineReceipt
            Invoke-Probe 'Offline PostgreSQL endpoint records both failures' (Get-ProbeArguments $offline $script:ResolvedPsql $offlinePort) 2 | Out-Null
            $offlineResult = Assert-ProbeReceipt (@(Get-ProbeReceipts $offline)[0]) 'FAIL' 'FAIL'
            Assert-ProbeTest ($offlineResult.market.status -ceq 'FAIL' -and $offlineResult.news.status -ceq 'FAIL') 'Both unavailable databases must be recorded.'
        }
        finally { $listener.Stop() }

        # Hold one ordinary fixture table lock in a separate session. The runner's
        # five-second statement/lock bound must fail market and continue to news.
        $lockStart = New-Object System.Diagnostics.ProcessStartInfo
        $lockStart.FileName = $script:ResolvedPsql
        $lockStart.Arguments = ((@('-X','-w','-h',$PgHost,'-p',[string]$PgPort,'-U',$PgUser,'-d','srp','-v','ON_ERROR_STOP=1','-A','-t','-q','-f','-') | ForEach-Object { Get-QuotedNativeArgument $_ }) -join ' ')
        $lockStart.UseShellExecute = $false
        $lockStart.RedirectStandardInput = $true
        $lockStart.RedirectStandardOutput = $true
        $lockStart.RedirectStandardError = $true
        $locker = New-Object System.Diagnostics.Process
        $locker.StartInfo = $lockStart
        try {
            Assert-ProbeTest ($locker.Start()) 'Fixture lock session must start.'
            $locker.StandardInput.WriteLine("BEGIN; LOCK TABLE srp.ohlcvt_1m_2026q1 IN ACCESS EXCLUSIVE MODE;`n\echo LOCK_HELD")
            $locker.StandardInput.Flush()
            $ready = $locker.StandardOutput.ReadLineAsync()
            Assert-ProbeTest ($ready.Wait(10000) -and $ready.Result -ceq 'LOCK_HELD') 'Fixture lock must be confirmed before timeout test.'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $timeoutResult = Invoke-CollectionCase 'Bounded statement or lock timeout preserves independent news' $good 2 'FAIL' 'FAIL' @('-StatementTimeoutSeconds','5')
            $watch.Stop()
            Assert-ProbeTest ($watch.Elapsed.TotalSeconds -lt 45 -and $timeoutResult.market.status -ceq 'FAIL' -and $timeoutResult.news.database_name -ceq 'cfa') 'Timeout must be bounded and leave news diagnostics available.'
        }
        finally {
            if (-not $locker.HasExited) { $locker.StandardInput.WriteLine('ROLLBACK;'); $locker.StandardInput.Close(); if (-not $locker.WaitForExit(5000)) { $locker.Kill(); $locker.WaitForExit() } }
            $locker.Dispose()
        }

        foreach ($path in $preserved.Keys) { Assert-ProbeTest ((Get-Sha $path) -ceq $preserved[$path]) ('Preserved bytes changed: ' + $path) }
        Assert-ProbeTest ((Invoke-FixtureSql 'srp' 'SELECT count(*) FROM srp.ohlcvt_1m_2026q1;') -ceq '4') 'Read-only probe must preserve the restored market source rows.'
        Assert-ProbeTest ((Invoke-FixtureSql 'cfa' 'SELECT count(*) FROM source_news.source_slots;') -ceq '4') 'Read-only probe must preserve the restored news source rows.'
        $script:Checks.Add('Repository, source ZIP, original census, prior probe evidence and database fixtures remain unchanged by probes')
    }
    $summary = [ordered]@{
        status='PASS';powershell_version=[string]$PSVersionTable.PSVersion;shell=$script:ShellExecutable;postgres_integration=[bool]$PostgresIntegration
        runner_sha256=(Get-Sha $script:Runner);manifest_sha256=$script:ManifestSha;repository_head=$script:RepositoryHead
        checks=@($script:Checks.ToArray());q1_cov_001_local_status='UNVERIFIED';stage1_status='BLOCKED';evidence_population='SYNTHETIC FIXTURES ONLY'
    }
    Write-TestJson (Join-Path $script:RunRoot 'test-summary.json') $summary
    Write-Host ("PASS: {0} checks; PostgreSQL integration={1}. User-local coverage remains UNVERIFIED." -f $script:Checks.Count,[bool]$PostgresIntegration)
}
finally {
    foreach ($name in $originalEnvironment.Keys) { Restore-TestEnvironmentVariable $name $originalEnvironment[$name] }
}
