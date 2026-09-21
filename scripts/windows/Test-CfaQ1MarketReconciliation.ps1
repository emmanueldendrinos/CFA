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
$script:Sentinel = 'cfa-q1-reconcile-placeholder-not-secret'

function Assert-ProbeTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Q1 market reconciliation test failed: $Message" }
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


function Invoke-FixtureSql {
    param([string]$Database,[string]$Sql)
    $result = Invoke-TestProcess $script:ResolvedPsql @('-X','-w','-h',$PgHost,'-p',[string]$PgPort,'-U',$PgUser,'-d',('postgresql:///' + [Uri]::EscapeDataString($Database)),'-v','ON_ERROR_STOP=1','-A','-t','-f','-') 45 $Sql
    Assert-ProbeTest ($result.exit_code -eq 0) ('Disposable PostgreSQL fixture command failed: ' + $result.stderr)
    return $result.stdout.Trim()
}


function New-DatabaseFixtures {
    Invoke-FixtureSql 'postgres' 'CREATE DATABASE srp;' | Out-Null
    Invoke-FixtureSql 'srp' @'
CREATE SCHEMA srp;
CREATE TABLE srp.ohlcvt_1m (
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
) PARTITION BY RANGE (ts_utc);
CREATE TABLE srp.ohlcvt_1m_2026q1 PARTITION OF srp.ohlcvt_1m FOR VALUES FROM ('2026-01-01 00:00:00+00') TO ('2026-04-01 00:00:00+00');
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
VALUES (1,'Kraken','OHLCVT','Kraken_OHLCVT_Q1_2026.zip','synthetic/fixture.zip','2026-Q1',$size,'$hash',3,2,2,'IMPORTED','2026-09-20 00:00+00');
INSERT INTO srp.market_pairs (pair_id,exchange,pair_code,base_asset,quote_asset,market_type,metadata_json)
VALUES (1,'Kraken','XBTUSD','XBT','USD','spot','{}'),(2,'Kraken','ETHUSD','ETH','USD','spot','{}');
INSERT INTO srp.processing_runs (processing_run_id,process_name,process_version,source_archive_id,config_json,started_at_utc,status,input_rows,output_rows)
VALUES (1,'synthetic-import','fixture',1,'{}','2026-09-20 00:00+00','SUCCESS',4,4);
"@ | Out-Null
}

function Invoke-Reconciliation {
    param([string]$Name,[string[]]$Arguments,[int]$ExpectedExit)
    $result = Invoke-TestProcess $script:ShellExecutable (@('-NoLogo','-NoProfile','-NonInteractive','-File',$script:Runner,'-RepoRoot',$script:ResolvedRepo) + $Arguments) 150
    Assert-ProbeTest (-not (($result.stdout + $result.stderr).Contains($script:Sentinel))) "$Name must not disclose the password sentinel."
    Assert-ProbeTest ($result.exit_code -eq $ExpectedExit) ("{0}: expected exit {1}, got {2}. stdout: {3} stderr: {4}" -f $Name,$ExpectedExit,$result.exit_code,$result.stdout,$result.stderr)
    $script:Checks.Add($Name)
    Write-Host "PASS: $Name"
    return $result
}

function Get-ReconciliationArguments {
    param([object]$Fixture,[int]$Port = $PgPort)
    return @('-CensusDirectory',$Fixture.census,'-CoverageDirectory',$Fixture.coverage,'-ExpectedCensusReceiptSha256',(Get-Sha (Join-Path $Fixture.census 'receipt.json')),'-ExpectedCoverageReceiptSha256',(Get-Sha (Join-Path $Fixture.coverage 'receipt.json')),'-PgHost',$PgHost,'-PgPort',[string]$Port,'-PgUser',$PgUser,'-PsqlPath',$script:ResolvedPsql)
}

function Get-ReconciliationReceipts {
    param([object]$Fixture)
    $root = Join-Path $Fixture.evidence 'q1-market-reconciliation/2026Q1'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Filter receipt.json -Recurse -File | ForEach-Object { $_.FullName })
}

function Assert-ReconciliationReceipt {
    param([string]$Path,[string]$Collection,[string]$Checks)
    $directory = Split-Path -Parent $Path
    $receipt = Read-TestJson $Path
    Assert-ProbeTest ($receipt.schema -ceq 'cfa.q1-market-reconciliation/v1' -and $receipt.task_id -ceq 'Q1-MKT-001') 'Receipt must identify this frozen task and schema.'
    Assert-ProbeTest ($receipt.quarter_id -ceq '2026Q1' -and $receipt.local_status -ceq 'UNVERIFIED' -and $receipt.stage1_status -ceq 'BLOCKED') 'Synthetic success cannot approve the local or stage gate.'
    Assert-ProbeTest ($receipt.collection_status -ceq $Collection -and $receipt.checks_status -ceq $Checks) 'Collection and comparison states must match the observed execution.'
    Assert-ProbeTest ($receipt.runner_sha256 -ceq (Get-Sha $script:Runner) -and $receipt.repository_head -ceq $script:RepositoryHead) 'Receipt must bind exact runner bytes and Git HEAD.'
    Assert-ProbeTest ($receipt.manifest_sha256 -ceq $script:ManifestSha -and $receipt.sot_sha256 -ceq (Get-Sha $script:SotPath)) 'Frozen manifest and SoT must remain bound.'
    $required = @('source-digests.tsv','member-evidence.jsonl','market-digests.tsv','market.json','schema.json','comparison.tsv','reconciliation.json','lineage.json','errors.json')
    Assert-ProbeTest ($receipt.artifacts -is [Array] -and @($receipt.artifacts).Count -eq 9) 'Exactly nine evidence artifacts must be inventoried.'
    $paths = @($receipt.artifacts | ForEach-Object { [string]$_.path })
    Assert-ProbeTest (@($paths | Select-Object -Unique).Count -eq 9) 'Artifact inventory paths must be unique.'
    foreach ($name in $required) { Assert-ProbeTest ($paths -ccontains $name) ('Missing artifact: ' + $name) }
    $runFiles=@(Get-ChildItem -LiteralPath $directory -File)
    Assert-ProbeTest ($runFiles.Count -eq 10 -and @($runFiles | Where-Object { $_.Name -cne 'receipt.json' -and $required -cnotcontains $_.Name }).Count -eq 0) 'Only receipt and its nine inventoried artifacts may remain, including after partial failure.'
    foreach ($artifact in $receipt.artifacts) {
        Assert-ProbeTest (-not [IO.Path]::IsPathRooted([string]$artifact.path)) 'Artifact paths must be relative.'
        $artifactPath = [IO.Path]::GetFullPath((Join-Path $directory $artifact.path))
        Assert-ProbeTest ($artifactPath.StartsWith($directory + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Every artifact must remain inside its output run.'
        Assert-ProbeTest ((Get-Sha $artifactPath) -ceq $artifact.sha256 -and (Get-Item -LiteralPath $artifactPath).Length -eq $artifact.bytes) 'Artifact hash and exact byte length must match.'
        $content = [IO.File]::ReadAllText($artifactPath,$script:Utf8)
        foreach ($forbidden in @($script:Sentinel,'CONFIG_VALUE_MUST_NOT_BE_EXPORTED','1767225600,10,12,9,11,3,2','URL_MUST_NOT_BE_EXPORTED')) {
            Assert-ProbeTest (-not $content.Contains($forbidden)) 'Evidence must exclude passwords, config values, news URLs and raw source rows.'
        }
    }
    $errorWrapper = ('{"items":' + [IO.File]::ReadAllText((Join-Path $directory 'errors.json'),$script:Utf8) + '}') | ConvertFrom-Json
    Assert-ProbeTest ($errorWrapper.items -is [Array] -and @($errorWrapper.items).Count -eq $receipt.errors_count) 'Errors must preserve empty/singleton array shape and reconcile.'
    $comparison = Read-TestJson (Join-Path $directory 'reconciliation.json')
    Assert-ProbeTest ($comparison.status -ceq $Checks -and $comparison.checks -is [Array]) 'Comparison state and check array must remain explicit.'
    Assert-ProbeTest ($comparison.historical_provenance_status -ceq 'UNVERIFIED' -and $comparison.stage1_status -ceq 'BLOCKED') 'Matching current values cannot prove historical import provenance or stage approval.'
    if ($Checks -ceq 'PASS') {
        Assert-ProbeTest ($comparison.current_content_status -ceq 'PASS' -and $comparison.canonicalization -ceq 'cfa.ohlcvt.binary52/v1') 'Successful value comparison must name the exact binary canonicalization.'
        foreach ($name in @('source-digests.tsv','market-digests.tsv')) {
            $lines = @([IO.File]::ReadLines((Join-Path $directory $name),$script:Utf8))
            Assert-ProbeTest ($lines.Count -eq 3 -and $lines[0] -ceq "pair_id`tday_utc`trows`tmin_epoch`tmax_epoch`tsha256") 'Fixture digests must contain the exact header and two pair/day rows.'
            foreach ($line in $lines[1..2]) { Assert-ProbeTest ($line.Split([char]9).Count -eq 6) 'Digest records must contain exactly six fields.' }
        }
    } else { Assert-ProbeTest ($comparison.current_content_status -cne 'PASS') 'A failed comparison cannot report current content PASS.' }
    return [pscustomobject]@{receipt=$receipt;directory=$directory;reconciliation=$comparison;market=(Read-TestJson (Join-Path $directory 'market.json'));schema=(Read-TestJson (Join-Path $directory 'schema.json'));lineage=(Read-TestJson (Join-Path $directory 'lineage.json'))}
}

function Invoke-ReconciliationCase {
    param([string]$Name,[object]$Fixture,[int]$ExpectedExit,[string]$Collection,[string]$Checks,[string[]]$ExtraArguments = @())
    $before = @(Get-ReconciliationReceipts $Fixture)
    Invoke-Reconciliation $Name ((Get-ReconciliationArguments $Fixture) + $ExtraArguments) $ExpectedExit | Out-Null
    $after = @(Get-ReconciliationReceipts $Fixture | Where-Object { $before -notcontains $_ })
    Assert-ProbeTest ($after.Count -eq 1) 'Each collection must create one unique new receipt.'
    return Assert-ReconciliationReceipt $after[0] $Collection $Checks
}

function Test-RestrictedPolicyLauncher {
    param([object]$Fixture)
    # Run the reproduction and corrected launch inside one disposable Restricted
    # parent. EncodedCommand carries inline commands, which Restricted permits;
    # the candidate itself is still loaded through -File in both child launches.
    $policyScopes = @('MachinePolicy','UserPolicy','CurrentUser','LocalMachine')
    $persistentBefore = @($policyScopes | ForEach-Object { [string](Get-ExecutionPolicy -Scope $_) })
    $processBefore = [string](Get-ExecutionPolicy -Scope Process)
    $environmentBefore = [Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference','Process')
    $receiptsBefore = @(Get-ReconciliationReceipts $Fixture)
    $reportPath = Join-Path $script:RunRoot launcher-policy-test.json
    $settings = [ordered]@{
        shell = $script:ShellExecutable
        runner = $script:Runner
        repository = $script:ResolvedRepo
        arguments = @(Get-ReconciliationArguments $Fixture)
        evidence_root = (Join-Path $Fixture.evidence 'q1-market-reconciliation/2026Q1')
        report_path = $reportPath
    }
    $settingsBase64 = [Convert]::ToBase64String($script:Utf8.GetBytes((ConvertTo-Json -InputObject $settings -Compress -Depth 5)))
    $wrapper = @(
        'function Get-QuotedNativeArgument {'
        ${function:Get-QuotedNativeArgument}.ToString()
        '}'
        'function Invoke-TestProcess {'
        ${function:Invoke-TestProcess}.ToString()
        '}'
        ('$settingsBase64 = ''' + $settingsBase64 + '''')
        @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($settingsBase64)) | ConvertFrom-Json
function Get-PersistentPolicies {
    $values = [ordered]@{}
    foreach ($scope in @('MachinePolicy','UserPolicy','CurrentUser','LocalMachine')) {
        $values[$scope] = [string](Get-ExecutionPolicy -Scope $scope)
    }
    return $values
}
function Get-EvidenceInventory {
    return @(Get-ChildItem -LiteralPath $settings.evidence_root -Force -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName })
}
$parentBefore = [string](Get-ExecutionPolicy)
$persistentBefore = Get-PersistentPolicies
if ($parentBefore -cne 'Restricted' -or [string](Get-ExecutionPolicy -Scope Process) -cne 'Restricted') {
    throw 'Restricted fixture policy was not effective; enforced Group Policy cannot be overridden by this test.'
}
$inventoryBefore = @(Get-EvidenceInventory)
$common = @('-NoProfile','-File',[string]$settings.runner,'-RepoRoot',[string]$settings.repository) + @($settings.arguments)
$rejected = Invoke-TestProcess ([string]$settings.shell) $common 150
if ($rejected.exit_code -eq 0 -or ($rejected.stdout + $rejected.stderr) -notmatch 'PSSecurityException|SecurityError|UnauthorizedAccess|running scripts is disabled') {
    throw ('Original launch did not reproduce the execution-policy rejection. stdout: ' + $rejected.stdout + ' stderr: ' + $rejected.stderr)
}
if ($rejected.stdout -match 'Evidence directory:' -or ($inventoryBefore -join "`n") -cne (@(Get-EvidenceInventory) -join "`n")) {
    throw 'The rejected launch must not create an evidence directory or artifact.'
}
$parentAfterRejection = [string](Get-ExecutionPolicy)
if ($parentAfterRejection -cne 'Restricted') { throw 'The rejected child changed its parent policy.' }
$correctedArguments = @('-NoProfile','-ExecutionPolicy','RemoteSigned','-File',[string]$settings.runner,'-RepoRoot',[string]$settings.repository) + @($settings.arguments)
$corrected = Invoke-TestProcess ([string]$settings.shell) $correctedArguments 150
if ($corrected.exit_code -ne 0) {
    throw ('Corrected launch failed. stdout: ' + $corrected.stdout + ' stderr: ' + $corrected.stderr)
}
$persistentAfter = Get-PersistentPolicies
$parentAfter = [string](Get-ExecutionPolicy)
if ($parentAfter -cne 'Restricted' -or [string](Get-ExecutionPolicy -Scope Process) -cne 'Restricted') {
    throw 'Corrected child must leave its parent Restricted.'
}
if ((ConvertTo-Json -InputObject $persistentBefore -Compress) -cne (ConvertTo-Json -InputObject $persistentAfter -Compress)) {
    throw 'Launcher must not change persistent execution-policy scopes.'
}
$report = [ordered]@{
    task_id = 'Q1-MKT-002'
    status = 'PASS'
    original_exit_code = $rejected.exit_code
    original_error = $rejected.stderr
    rejected_launch_created_evidence = $false
    corrected_exit_code = $corrected.exit_code
    corrected_stdout = $corrected.stdout
    parent_effective_before = $parentBefore
    parent_effective_after_rejection = $parentAfterRejection
    parent_effective_after_correction = $parentAfter
    persistent_policies_before = $persistentBefore
    persistent_policies_after = $persistentAfter
}
[IO.File]::WriteAllText([string]$settings.report_path,(ConvertTo-Json -InputObject $report -Depth 5),(New-Object Text.UTF8Encoding($false)))
Write-Output 'Q1-MKT-002-RESTRICTED-REJECTION-PASS'
Write-Output 'Q1-MKT-002-REMOTESIGNED-RECONCILIATION-PASS'
Write-Output 'Q1-MKT-002-POLICY-PRESERVATION-PASS'
'@
    ) -join "`n"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    Assert-ProbeTest ($encoded.Length -lt 30000) 'Inline policy-test command must fit the Windows native command-line limit.'
    $result = Invoke-TestProcess $script:ShellExecutable @('-NoProfile','-NonInteractive','-OutputFormat','Text','-ExecutionPolicy','Restricted','-EncodedCommand',$encoded) 330
    Assert-ProbeTest (-not (($result.stdout + $result.stderr).Contains($script:Sentinel))) 'Policy regression must not disclose the password sentinel.'
    Assert-ProbeTest ($result.exit_code -eq 0) ('Restricted-parent launcher regression failed. stdout: ' + $result.stdout + ' stderr: ' + $result.stderr)
    foreach ($marker in @('Q1-MKT-002-RESTRICTED-REJECTION-PASS','Q1-MKT-002-REMOTESIGNED-RECONCILIATION-PASS','Q1-MKT-002-POLICY-PRESERVATION-PASS')) {
        Assert-ProbeTest ($result.stdout.Contains($marker)) ('Missing launcher assertion: ' + $marker)
    }
    $persistentAfter = @($policyScopes | ForEach-Object { [string](Get-ExecutionPolicy -Scope $_) })
    Assert-ProbeTest (($persistentBefore -join ',') -ceq ($persistentAfter -join ',') -and $processBefore -ceq [string](Get-ExecutionPolicy -Scope Process)) 'Policy test must preserve the calling test process and all persistent policy scopes.'
    Assert-ProbeTest ($environmentBefore -ceq [Environment]::GetEnvironmentVariable('PSExecutionPolicyPreference','Process')) 'Policy test must preserve the calling process policy environment.'
    $report = Read-TestJson $reportPath
    Assert-ProbeTest ($report.status -ceq 'PASS' -and -not $report.rejected_launch_created_evidence -and $report.corrected_exit_code -eq 0) 'Saved policy evidence must reconcile with the subprocess assertions.'
    Assert-ProbeTest (-not ([IO.File]::ReadAllText($reportPath,$script:Utf8).Contains($script:Sentinel))) 'Policy evidence must exclude the password sentinel.'
    $newReceipts = @(Get-ReconciliationReceipts $Fixture | Where-Object { $receiptsBefore -notcontains $_ })
    Assert-ProbeTest ($newReceipts.Count -eq 1) 'Only the corrected launch may create a reconciliation receipt.'
    $validated = Assert-ReconciliationReceipt $newReceipts[0] PASS PASS
    $name = 'Restricted parent rejects original launch; process RemoteSigned completes reconciliation and preserves policies'
    $script:Checks.Add($name)
    Write-Host "PASS: $name"
    return $validated
}

function Copy-CoverageFixture {
    param([object]$Fixture,[string]$Name)
    $copy = Join-Path $Fixture.evidence ('coverage-copy-' + $Name)
    [IO.Directory]::CreateDirectory($copy) | Out-Null
    foreach ($file in @(Get-ChildItem -LiteralPath $Fixture.coverage -File)) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $copy $file.Name) }
    return [pscustomobject]@{directory=$Fixture.directory;kraken=$Fixture.kraken;evidence=$Fixture.evidence;census=$Fixture.census;coverage=$copy;archive=$Fixture.archive}
}

function Update-CoverageArtifact {
    param([object]$Fixture,[string]$Name)
    $receiptPath = Join-Path $Fixture.coverage receipt.json
    $receipt = Read-TestJson $receiptPath
    foreach ($artifact in $receipt.artifacts) {
        if ($artifact.path -ceq $Name) {
            $path = Join-Path $Fixture.coverage $Name
            $artifact.sha256 = Get-Sha $path
            $artifact.bytes = (Get-Item -LiteralPath $path).Length
        }
    }
    Write-TestJson $receiptPath $receipt
}

function Test-ReconciliationComponents {
    Add-Type -AssemblyName System.Numerics
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $enginePath = Join-Path $script:ResolvedRepo 'scripts/windows/CfaQ1MarketReconciliation.cs'
    if ($PSVersionTable.PSEdition -ceq 'Desktop') {
        Add-Type -Path $enginePath -ReferencedAssemblies @('System.dll','System.Core.dll','System.Numerics.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll')
    } else { Add-Type -Path $enginePath }
    foreach ($row in @(
        '1767225600,1,2,0.5,1.5,0,2147483648',
        '1767225600,1,2,0.5,1.5,0,-1',
        '1767225600,1,2,0.5,1.5,0,1.5',
        '1767225601,1,2,0.5,1.5,0,1',
        '1767225540,1,2,0.5,1.5,0,1',
        '1775001600,1,2,0.5,1.5,0,1',
        '1767225600,1,2,0.5,1.5,0',
        '1767225600,1,2,0.5,1.5,0,1,extra',
        '1767225600,1,2,0.5,1.5,NaN,1',
        '1767225600,1,2,0.5,1.5,1e309,1',
        '1767225600,1,2,0.5,1.5,1e-324,1',
        '1767225600,1,2,0.5,1.5,-1e-400,1',
        ('1767225600,1,2,0.5,1.5,0,1' + [char]0)
    )) {
        $rejected=$false
        try { $null=[CfaQ1Reconciliation.MarketReconciler]::CanonicalRowHex($row) } catch { $rejected=$true }
        Assert-ProbeTest $rejected 'Canonical rows must reject malformed, out-of-bound, null-terminated, overflow and nonzero-underflow inputs.'
    }
    $script:Checks.Add('Canonical rows reject malformed values, integer overflow, minute/Q1 boundaries and nonzero underflow')
    $header="pair_id`tday_utc`trows`tmin_epoch`tmax_epoch`tsha256`n"
    $digest='a'*64
    $valid="1`t2026-01-01`t1`t1767225600`t1767225600`t$digest`n"
    $source=Join-Path $script:RunRoot component-source.tsv
    $database=Join-Path $script:RunRoot component-market.tsv
    New-TestFile $source ($header+$valid)
    New-TestFile $database ($header+$valid)
    $result=[CfaQ1Reconciliation.MarketReconciler]::CompareDigests($source,$database,(Join-Path $script:RunRoot component-match.tsv))
    Assert-ProbeTest ($result.status -ceq 'PASS' -and $result.matched_row_count -eq 1) 'Independent matching single-record fingerprints must compare successfully.'
    $cases=@(
        @{name='missing';text=$header;field='missing_day_count'},
        @{name='extra';text=($header+$valid+"2`t2026-01-01`t1`t1767225600`t1767225600`t$digest`n");field='extra_day_count'},
        @{name='value';text=($header+$valid.Replace($digest,('b'*64)));field='mismatched_day_count'}
    )
    foreach ($case in $cases) {
        New-TestFile $database $case.text
        $result=[CfaQ1Reconciliation.MarketReconciler]::CompareDigests($source,$database,(Join-Path $script:RunRoot ('component-'+$case.name+'.tsv')))
        Assert-ProbeTest ($result.status -ceq 'FAIL' -and $result.($case.field) -eq 1) ('Explicit digest mismatch must be counted: '+$case.name)
    }
    $malformed=@(
        '',
        $valid,
        ($header+"1`t2026-01-01`t1`t1767225600"),
        ($header+$valid+$valid),
        ($header+$valid.Replace('2026-01-01','2025-12-31')),
        ($header+$valid.Replace("`t1`t1767225600","`t0`t1767225600")),
        ($header+$valid.Replace("`t1`t1767225600","`t1441`t1767225600")),
        ($header+$valid.Replace($digest,'not-a-sha256')),
        ($header+$valid.Replace("1`t2026","01`t2026")),
        ($header+"2`t2026-01-01`t1`t1767225600`t1767225600`t$digest`n"+$valid)
    )
    $index=0
    foreach ($text in $malformed) {
        New-TestFile $database $text
        $rejected=$false
        try { $null=[CfaQ1Reconciliation.MarketReconciler]::CompareDigests($source,$database,(Join-Path $script:RunRoot ('component-invalid-'+$index+'.tsv'))) } catch { $rejected=$true }
        Assert-ProbeTest $rejected ('Malformed/truncated fingerprint transport must fail: case '+$index)
        $index++
    }
    [IO.File]::WriteAllBytes($database,[byte[]]@(0xc3,0x28))
    $rejected=$false
    try { $null=[CfaQ1Reconciliation.MarketReconciler]::CompareDigests($source,$database,(Join-Path $script:RunRoot component-invalid-utf8.tsv)) } catch { $rejected=$true }
    Assert-ProbeTest $rejected 'Invalid UTF-8 fingerprint transport must fail.'
    $script:Checks.Add('Fingerprint parser rejects incomplete, malformed, duplicate, unordered, oversized and invalid UTF-8 transport')
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '../..' }
$script:ResolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$script:Runner = Join-Path $script:ResolvedRepo 'scripts/windows/Invoke-CfaQ1MarketReconciliation.ps1'
$script:CensusRunner = Join-Path $script:ResolvedRepo 'scripts/windows/Invoke-CfaResourceCensus.ps1'
$script:CoverageRunner = Join-Path $script:ResolvedRepo 'scripts/windows/Invoke-CfaQ1CoverageProbe.ps1'
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
if ([string]::IsNullOrWhiteSpace($TestOutputRoot)) { $TestOutputRoot = [IO.Path]::GetTempPath() }
$script:RunRoot = Join-Path ([IO.Path]::GetFullPath($TestOutputRoot)) ('cfa-q1-market-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:RunRoot) | Out-Null
Write-Host "Synthetic test evidence: $script:RunRoot"
$originalEnvironment = @{}
foreach ($name in @('PGPASSWORD','PGCLIENTENCODING','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGDATABASE','PGOPTIONS','PGHOST','PGPORT','PGUSER','PGPASSFILE','PGSSLMODE','PGTARGETSESSIONATTRS','PGCONNECT_TIMEOUT')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
}
try {
    [Environment]::SetEnvironmentVariable('PGPASSWORD',$script:Sentinel,'Process')
    [Environment]::SetEnvironmentVariable('PGCLIENTENCODING','UTF8','Process')
    foreach ($scriptPath in @($script:Runner,$PSCommandPath,(Join-Path $script:ResolvedRepo 'scripts/windows/Get-CfaQ1ReconciliationQueries.ps1'))) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
        Assert-ProbeTest ($parseErrors.Count -eq 0) ('PowerShell parsing: ' + $scriptPath)
        if ($scriptPath -ceq $script:Runner) {
            $parameters = @{}
            foreach ($parameter in $ast.ParamBlock.Parameters) { $parameters[$parameter.Name.VariablePath.UserPath] = $parameter }
            Assert-ProbeTest ($parameters.PgHost.DefaultValue.Value -ceq 'localhost' -and $parameters.PgPort.DefaultValue.Value -eq 5432 -and $parameters.PgUser.DefaultValue.Value -ceq 'postgres') 'Intended local endpoint defaults must remain unchanged.'
            Assert-ProbeTest ($parameters.StatementTimeoutSeconds.DefaultValue.Value -eq 900) 'Reconciliation statement timeout must default to 900 seconds.'
        }
    }
    $script:Checks.Add('Parse exact runner, query module and tests; verify intended endpoint defaults')
    Invoke-Reconciliation 'Exact runner canonicalization and component self-tests' @('-SelfTest') 0 | Out-Null
    Test-ReconciliationComponents
    Invoke-Reconciliation 'Missing bound evidence directories fail preflight' @('-CensusDirectory',(Join-Path $script:RunRoot missing),'-CoverageDirectory',(Join-Path $script:RunRoot missing2),'-PsqlPath',$script:ShellExecutable) 1 | Out-Null

    if ($PostgresIntegration) {
        Assert-ProbeTest ($PgHost -ceq '127.0.0.1' -and $PgPort -eq 55432 -and $PgUser -ceq 'cfa_census_ci') 'Fixture writes are restricted to the dedicated CI endpoint and role.'
        Assert-ProbeTest (-not [string]::IsNullOrWhiteSpace($DisposableDataDirectory)) 'Explicit disposable PostgreSQL directory is mandatory.'
        $expectedData = (Resolve-Path -LiteralPath $DisposableDataDirectory).ProviderPath.TrimEnd('\','/')
        Assert-ProbeTest ((Test-Path -LiteralPath (Join-Path $expectedData PG_VERSION)) -and (Test-Path -LiteralPath (Join-Path $expectedData postmaster.pid))) 'Disposable server must be initialized and running.'
        $script:ResolvedPsql = (Resolve-Path -LiteralPath $PsqlPath).ProviderPath
        $actualData = Invoke-FixtureSql postgres "SELECT current_setting('data_directory');"
        Assert-ProbeTest ([IO.Path]::GetFullPath($actualData).TrimEnd('\','/') -ieq $expectedData) 'Live database directory must match the explicitly disposable server before any DDL.'
        $script:Checks.Add('Disposable PostgreSQL identity proved before fixture writes')
        New-DatabaseFixtures
        $good = New-SyntheticFixture valid
        Set-ValidLineage $good
        Set-ValidMarketRows
        # News remains deliberately empty: its documented coverage failure is
        # allowed input, while every archive and market coverage check must pass.
        $inventoryPath = Join-Path $good.evidence 'synthetic-member-inventory.json'
        New-TestFile $inventoryPath '{"fixture":true,"members":["XBTUSD_1.csv","ETHUSD_1.csv"]}'
        $inventorySql = $inventoryPath.Replace("'","''")
        Invoke-FixtureSql srp "UPDATE srp.source_archives SET inventory_json_path='$inventorySql'; UPDATE srp.processing_runs SET config_json='{`"fixture_key`":`"CONFIG_VALUE_MUST_NOT_BE_EXPORTED`"}'::jsonb;" | Out-Null
        $censusResult = Invoke-TestProcess $script:ShellExecutable @('-NoLogo','-NoProfile','-NonInteractive','-File',$script:CensusRunner,'-RepoRoot',$script:ResolvedRepo,'-KrakenRoot',$good.kraken,'-EvidenceRoot',$good.evidence,'-PsqlPath',$script:ResolvedPsql,'-PgHost',$PgHost,'-PgPort',[string]$PgPort,'-PgUser',$PgUser)
        Assert-ProbeTest ($censusResult.exit_code -eq 0) ('Exact synthetic census failed: ' + $censusResult.stdout + $censusResult.stderr)
        $censusPaths = @(Get-ChildItem -LiteralPath (Join-Path $good.evidence resource-census) -Filter receipt.json -Recurse -File | Where-Object { $_.DirectoryName -cne $good.census })
        Assert-ProbeTest ($censusPaths.Count -eq 1) 'Exactly one actual census must bind the fixture.'
        $good.census = $censusPaths[0].DirectoryName
        $coverageResult = Invoke-TestProcess $script:ShellExecutable @('-NoLogo','-NoProfile','-NonInteractive','-File',$script:CoverageRunner,'-RepoRoot',$script:ResolvedRepo,'-CensusDirectory',$good.census,'-ExpectedCensusReceiptSha256',(Get-Sha (Join-Path $good.census receipt.json)),'-PgHost',$PgHost,'-PgPort',[string]$PgPort,'-PgUser',$PgUser,'-PsqlPath',$script:ResolvedPsql)
        Assert-ProbeTest ($coverageResult.exit_code -eq 2) ('Exact coverage must collect missing-news diagnostics: ' + $coverageResult.stdout + $coverageResult.stderr)
        $coveragePaths = @(Get-ChildItem -LiteralPath (Join-Path $good.evidence q1-coverage-probe) -Filter receipt.json -Recurse -File)
        Assert-ProbeTest ($coveragePaths.Count -eq 1) 'Exactly one actual coverage run must bind the fixture.'
        $good | Add-Member -NotePropertyName coverage -NotePropertyValue $coveragePaths[0].DirectoryName
        $priorReceipt = Read-TestJson $coveragePaths[0].FullName
        $priorChecks = Read-TestJson (Join-Path $good.coverage reconciliation.json)
        Assert-ProbeTest ($priorReceipt.collection_status -ceq 'PASS' -and @($priorChecks.checks | Where-Object { $_.status -ceq 'FAIL' -and $_.id -cne 'Q1-COV-001-NEWS-Q1-PRESENCE' }).Count -eq 0) 'Only the documented missing-news check may fail the bound coverage fixture.'
        $script:Checks.Add('Exact census and coverage runners bind the fixture while missing news remains explicit')

        $preserved = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $good.kraken,$good.census,$good.coverage -Recurse -File)) { $preserved[$file.FullName] = Get-Sha $file.FullName }
        $tracked = Invoke-TestProcess $git @('-C',$script:ResolvedRepo,'ls-files','-z')
        Assert-ProbeTest ($tracked.exit_code -eq 0) 'Tracked file inventory must be readable.'
        foreach ($relative in $tracked.stdout.Split([char]0)) {
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                $path = Join-Path $script:ResolvedRepo $relative
                if (Test-Path -LiteralPath $path -PathType Leaf) { $preserved[$path] = Get-Sha $path }
            }
        }
        $first = Invoke-ReconciliationCase 'Exact candidate reconciles every fixture row with historical provenance unresolved' $good 0 PASS PASS
        foreach ($file in @(Get-ChildItem -LiteralPath $first.directory -File)) { $preserved[$file.FullName] = Get-Sha $file.FullName }
        $second = Invoke-ReconciliationCase 'Repeat execution creates a new run and preserves prior evidence' $good 0 PASS PASS
        Assert-ProbeTest ($first.directory -cne $second.directory) 'Repeated execution must not overwrite earlier evidence.'
        if ($env:OS -ceq 'Windows_NT') {
            $policyRun = Test-RestrictedPolicyLauncher $good
            foreach ($file in @(Get-ChildItem -LiteralPath $policyRun.directory -File)) { $preserved[$file.FullName] = Get-Sha $file.FullName }
        }

        $badExpected = @(Get-ReconciliationArguments $good)
        $badExpected[[Array]::IndexOf($badExpected,'-ExpectedCoverageReceiptSha256') + 1] = ('0' * 64)
        Invoke-Reconciliation 'Wrong expected coverage receipt hash fails preflight' $badExpected 1 | Out-Null
        foreach ($case in @('tampered','missing','shape','unsafe-path','market-failure','endpoint')) {
            $copy = Copy-CoverageFixture $good $case
            switch ($case) {
                tampered { [IO.File]::AppendAllText((Join-Path $copy.coverage market.json),' ',$script:Utf8) }
                missing { Remove-Item -LiteralPath (Join-Path $copy.coverage archive-members.jsonl) }
                shape { New-TestFile (Join-Path $copy.coverage errors.json) '{}'; Update-CoverageArtifact $copy errors.json }
                unsafe-path { $r=Read-TestJson (Join-Path $copy.coverage receipt.json); $r.artifacts[0].path='../outside.tsv'; Write-TestJson (Join-Path $copy.coverage receipt.json) $r }
                market-failure { $r=Read-TestJson (Join-Path $copy.coverage reconciliation.json); $r.checks[0].status='FAIL'; Write-TestJson (Join-Path $copy.coverage reconciliation.json) $r; Update-CoverageArtifact $copy reconciliation.json }
                endpoint { $r=Read-TestJson (Join-Path $copy.coverage receipt.json); $r.postgres.port=1; Write-TestJson (Join-Path $copy.coverage receipt.json) $r }
            }
            $before = @(Get-ReconciliationReceipts $good).Count
            Invoke-Reconciliation ('Bound coverage rejects ' + $case) (Get-ReconciliationArguments $copy) 1 | Out-Null
            Assert-ProbeTest (@(Get-ReconciliationReceipts $good).Count -eq $before) 'Preflight rejection must not start a collection.'
        }
        if ($env:OS -ceq 'Windows_NT') {
            $junction = Join-Path $script:RunRoot junction-to-coverage
            New-Item -ItemType Junction -Path $junction -Value $good.coverage | Out-Null
            $junctionArgs = @(Get-ReconciliationArguments $good)
            $junctionArgs[[Array]::IndexOf($junctionArgs,'-CoverageDirectory') + 1] = $junction
            Invoke-Reconciliation 'Reparse ancestor in bound input path is rejected' $junctionArgs 1 | Out-Null
        }

        $archiveBytes=[IO.File]::ReadAllBytes($good.archive)
        $archiveWrite=(Get-Item -LiteralPath $good.archive).LastWriteTimeUtc
        try {
            [IO.File]::AppendAllText($good.archive,'changed-synthetic-archive',$script:Utf8)
            Invoke-ReconciliationCase 'Changed bound archive fails before database collection' $good 2 FAIL FAIL | Out-Null
        } finally {
            [IO.File]::WriteAllBytes($good.archive,$archiveBytes)
            [IO.File]::SetLastWriteTimeUtc($good.archive,$archiveWrite)
        }

        # A changed price preserves row counts, timestamps, pair/day counts,
        # extrema and all lineage. Only content fingerprints can detect it.
        Invoke-FixtureSql srp "UPDATE srp.ohlcvt_1m_2026q1 SET close_price=10.5 WHERE pair_id=1 AND ts_utc='2026-01-01 00:00+00';" | Out-Null
        $mutation = Invoke-ReconciliationCase 'Count-preserving valid OHLCVT mutation fails row-value equivalence' $good 2 PASS FAIL
        Assert-ProbeTest ((Invoke-FixtureSql srp 'SELECT count(*) FROM srp.ohlcvt_1m_2026q1;') -ceq '4') 'Mutation test must preserve the exact population.'
        Set-ValidMarketRows
        foreach ($case in @(
            @{name='same-day timestamp change';sql="UPDATE srp.ohlcvt_1m_2026q1 SET ts_utc='2026-01-01 00:02+00' WHERE pair_id=1 AND ts_utc='2026-01-01 00:01+00';"},
            @{name='missing row';sql="DELETE FROM srp.ohlcvt_1m_2026q1 WHERE pair_id=2 AND ts_utc='2026-03-31 23:59+00';"},
            @{name='duplicate pair-time key';sql='INSERT INTO srp.ohlcvt_1m_2026q1 SELECT * FROM srp.ohlcvt_1m_2026q1 WHERE pair_id=1 LIMIT 1;'},
            @{name='NULL required value';sql='UPDATE srp.ohlcvt_1m_2026q1 SET open_price=NULL WHERE pair_id=1;'},
            @{name='NaN value';sql="UPDATE srp.ohlcvt_1m_2026q1 SET volume='NaN'::float8 WHERE pair_id=1;"},
            @{name='infinite value';sql="UPDATE srp.ohlcvt_1m_2026q1 SET volume='Infinity'::float8 WHERE pair_id=1;"},
            @{name='off-minute timestamp';sql="UPDATE srp.ohlcvt_1m_2026q1 SET ts_utc=ts_utc+interval '1 second' WHERE pair_id=1;"},
            @{name='unknown pair';sql='UPDATE srp.ohlcvt_1m_2026q1 SET pair_id=999 WHERE pair_id=1;'},
            @{name='wrong source link';sql='UPDATE srp.ohlcvt_1m_2026q1 SET source_archive_id=999 WHERE pair_id=1;'},
            @{name='wrong run link';sql='UPDATE srp.ohlcvt_1m_2026q1 SET processing_run_id=999 WHERE pair_id=1;'},
            @{name='non-NULL synthesized VWAP';sql='UPDATE srp.ohlcvt_1m_2026q1 SET vwap=11 WHERE pair_id=1;'},
            @{name='empty selected population';sql='TRUNCATE srp.ohlcvt_1m_2026q1;'}
        )) {
            Invoke-FixtureSql srp $case.sql | Out-Null
            # Invalid populations may stop collection before digest comparison;
            # assert the contractual failed check and nonzero exit independently.
            $before = @(Get-ReconciliationReceipts $good)
            Invoke-Reconciliation ('Market rejects ' + $case.name) (Get-ReconciliationArguments $good) 2 | Out-Null
            $new = @(Get-ReconciliationReceipts $good | Where-Object { $before -notcontains $_ })
            Assert-ProbeTest ($new.Count -eq 1) 'A rejected market population must leave exactly one receipt.'
            $raw = Read-TestJson $new[0]
            Assert-ProbeTest ($raw.collection_status -cin @('PASS','FAIL') -and $raw.checks_status -ceq 'FAIL') 'Invalid population must fail comparison explicitly.'
            Assert-ReconciliationReceipt $new[0] $raw.collection_status FAIL | Out-Null
            Set-ValidMarketRows
        }
        foreach ($case in @(
            @{name='duplicate pair metadata';sql='INSERT INTO srp.market_pairs SELECT * FROM srp.market_pairs WHERE pair_id=1;'},
            @{name='wrong registered archive size';sql='UPDATE srp.source_archives SET size_bytes=size_bytes+1;'},
            @{name='duplicate selected archive registration';sql='INSERT INTO srp.source_archives SELECT * FROM srp.source_archives;'},
            @{name='processing run archive mismatch';sql='UPDATE srp.processing_runs SET source_archive_id=999;'}
        )) {
            Invoke-FixtureSql srp $case.sql | Out-Null
            $before = @(Get-ReconciliationReceipts $good)
            Invoke-Reconciliation ('Lineage rejects ' + $case.name) (Get-ReconciliationArguments $good) 2 | Out-Null
            $new = @(Get-ReconciliationReceipts $good | Where-Object { $before -notcontains $_ })
            Assert-ProbeTest ($new.Count -eq 1) 'Rejected lineage must leave a receipt.'
            $raw = Read-TestJson $new[0]
            Assert-ReconciliationReceipt $new[0] $raw.collection_status FAIL | Out-Null
            Set-ValidLineage $good
        }

        Invoke-FixtureSql srp 'ALTER TABLE srp.ohlcvt_1m ALTER COLUMN volume TYPE numeric;' | Out-Null
        Invoke-ReconciliationCase 'Catalog gate rejects builtin type drift before data reads' $good 2 FAIL FAIL | Out-Null
        Invoke-FixtureSql srp 'ALTER TABLE srp.ohlcvt_1m ALTER COLUMN volume TYPE double precision;' | Out-Null
        Invoke-FixtureSql srp 'ALTER TABLE srp.ohlcvt_1m_2026q1 ENABLE ROW LEVEL SECURITY;' | Out-Null
        try { Invoke-ReconciliationCase 'Catalog gate rejects RLS even for a bypass-capable fixture role' $good 2 FAIL FAIL | Out-Null }
        finally { Invoke-FixtureSql srp 'ALTER TABLE srp.ohlcvt_1m_2026q1 DISABLE ROW LEVEL SECURITY;' | Out-Null }
        Invoke-FixtureSql srp 'BEGIN; ALTER TABLE srp.ohlcvt_1m_2026q1 RENAME TO ohlcvt_1m_2026q1_fixture_table; CREATE VIEW srp.ohlcvt_1m_2026q1 AS SELECT * FROM srp.ohlcvt_1m_2026q1_fixture_table; COMMIT;' | Out-Null
        try { Invoke-ReconciliationCase 'Catalog gate rejects relation-kind drift before view access' $good 2 FAIL FAIL | Out-Null }
        finally { Invoke-FixtureSql srp 'BEGIN; DROP VIEW srp.ohlcvt_1m_2026q1; ALTER TABLE srp.ohlcvt_1m_2026q1_fixture_table RENAME TO ohlcvt_1m_2026q1; COMMIT;' | Out-Null }
        Invoke-FixtureSql srp 'ALTER TABLE srp.ohlcvt_1m DETACH PARTITION srp.ohlcvt_1m_2026q1;' | Out-Null
        try { Invoke-ReconciliationCase 'Catalog gate rejects a detached Q1 partition' $good 2 FAIL FAIL | Out-Null }
        finally { Invoke-FixtureSql srp "ALTER TABLE srp.ohlcvt_1m ATTACH PARTITION srp.ohlcvt_1m_2026q1 FOR VALUES FROM ('2026-01-01 00:00+00') TO ('2026-04-01 00:00+00');" | Out-Null }

        # Validate exact canonicalizer against independent PostgreSQL binary
        # send output, rather than checking hashes generated by the same code.
        foreach ($token in @('0','-0','0.1','1.230000','1.23e0','1.00000000000000011102230246251565404236316680908203125','1.00000000000000033306690738754696212708950042724609375','5e-324','2.2250738585072014e-308','1.7976931348623157e308')) {
            $expected = Invoke-FixtureSql srp ("SELECT encode(float8send(CASE WHEN '$token'::float8=0 THEN 0::float8 ELSE '$token'::float8 END),'hex');")
            $actual = [CfaQ1Reconciliation.MarketReconciler]::CanonicalDoubleHex($token)
            Assert-ProbeTest ($actual -ceq $expected) ('Independent PostgreSQL binary64 mismatch: ' + $token)
        }
        $script:Checks.Add('Canonical decimal rounding and normalized signed zero match independent PostgreSQL binary64')

        $bogusService = Join-Path $script:RunRoot bogus-service.conf
        New-TestFile $bogusService "[q1_bogus]`nhost=192.0.2.1`nport=1`nuser=wrong`ndbname=wrong`n"
        foreach ($item in @(@('PGSERVICE','q1_bogus'),@('PGSERVICEFILE',$bogusService),@('PGHOSTADDR','192.0.2.1'),@('PGDATABASE','wrong'),@('PGOPTIONS','-c default_transaction_read_only=off -c search_path=public'))) {
            [Environment]::SetEnvironmentVariable($item[0],$item[1],'Process')
        }
        try { Invoke-ReconciliationCase 'Inherited libpq routing overrides cannot redirect the exact runner' $good 0 PASS PASS | Out-Null }
        finally { foreach ($name in @('PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGDATABASE','PGOPTIONS')) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue } }

        $wrapper = Join-Path $script:RunRoot environment-restoration.ps1
        $argumentsFile = Join-Path $script:RunRoot environment-arguments.json
        Write-TestJson $argumentsFile ([ordered]@{RepoRoot=$script:ResolvedRepo;CensusDirectory=$good.census;CoverageDirectory=$good.coverage;ExpectedCensusReceiptSha256=(Get-Sha (Join-Path $good.census receipt.json));ExpectedCoverageReceiptSha256=(Get-Sha (Join-Path $good.coverage receipt.json));PgHost=$PgHost;PgPort=$PgPort;PgUser=$PgUser;PsqlPath=$script:ResolvedPsql})
        New-TestFile $wrapper @'
#requires -Version 5.1
param([string]$Runner,[string]$ArgumentsFile)
$ErrorActionPreference='Stop'
$env:PGHOST='192.0.2.1'; $env:PGPORT='1'; $env:PGUSER='wrong'; $env:PGDATABASE='wrong'
$env:PGOPTIONS='-c default_transaction_read_only=off'; $env:PGCONNECT_TIMEOUT='93'; $env:PGCLIENTENCODING='LATIN1'
$names=@('PGPASSWORD','PGOPTIONS','PGCONNECT_TIMEOUT','PGCLIENTENCODING','PGDATABASE','PGHOST','PGPORT','PGUSER','PGSERVICE','PGSERVICEFILE','PGHOSTADDR','PGTARGETSESSIONATTRS')
$before=@{}; foreach($name in $names){$before[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$metadata=[IO.File]::ReadAllText($ArgumentsFile,(New-Object Text.UTF8Encoding($false,$true))) | ConvertFrom-Json
$parameters=@{}; foreach($property in $metadata.PSObject.Properties){$parameters[$property.Name]=$property.Value}
& $Runner @parameters
if($LASTEXITCODE -ne 0){throw 'Runner failed in environment restoration test.'}
foreach($name in $names){if([Environment]::GetEnvironmentVariable($name,'Process') -cne $before[$name]){throw ('Environment changed: '+$name)}}
Write-Host 'ENVIRONMENT_RESTORATION_PASS'
'@
        $result = Invoke-TestProcess $script:ShellExecutable @('-NoLogo','-NoProfile','-NonInteractive','-File',$wrapper,'-Runner',$script:Runner,'-ArgumentsFile',$argumentsFile)
        Assert-ProbeTest ($result.exit_code -eq 0 -and $result.stdout.Contains('ENVIRONMENT_RESTORATION_PASS') -and -not ($result.stdout+$result.stderr).Contains($script:Sentinel)) 'Invoking-process libpq environment must be restored without disclosure.'
        $script:Checks.Add('Exact runner restores inherited libpq environment in the invoking process')

        # Bind a deliberately unserved loopback endpoint into separate copies
        # of both prerequisite receipts; the originals remain immutable.
        $offline=Copy-CoverageFixture $good offline
        $offlineCensus=Join-Path $good.evidence census-copy-offline
        [IO.Directory]::CreateDirectory($offlineCensus) | Out-Null
        foreach($file in @(Get-ChildItem -LiteralPath $good.census -File)){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $offlineCensus $file.Name)}
        $offline.census=$offlineCensus
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        $listener.Start()
        try {
            $offlinePort=$listener.LocalEndpoint.Port
            $r=Read-TestJson (Join-Path $offline.census receipt.json); $r.postgres.port=$offlinePort
            Write-TestJson (Join-Path $offline.census receipt.json) $r
            $r=Read-TestJson (Join-Path $offline.coverage receipt.json); $r.postgres.port=$offlinePort
            $r.census_receipt_sha256=Get-Sha (Join-Path $offline.census receipt.json)
            Write-TestJson (Join-Path $offline.coverage receipt.json) $r
            $before=@(Get-ReconciliationReceipts $offline)
            $watch=[Diagnostics.Stopwatch]::StartNew()
            Invoke-Reconciliation 'Offline bound endpoint leaves failed evidence and no partial transport file' (Get-ReconciliationArguments $offline $offlinePort) 2 | Out-Null
            $watch.Stop()
            Assert-ProbeTest ($watch.Elapsed.TotalSeconds -lt 45) 'Offline connection failure must be bounded.'
            $new=@(Get-ReconciliationReceipts $offline | Where-Object {$before -notcontains $_})
            Assert-ProbeTest ($new.Count -eq 1) 'Offline collection must leave one failure receipt.'
            Assert-ReconciliationReceipt $new[0] FAIL FAIL | Out-Null
        } finally {$listener.Stop()}

        $lockStart = New-Object Diagnostics.ProcessStartInfo
        $lockStart.FileName=$script:ResolvedPsql
        $lockStart.Arguments=((@('-X','-w','-h',$PgHost,'-p',[string]$PgPort,'-U',$PgUser,'-d','srp','-v','ON_ERROR_STOP=1','-A','-t','-q','-f','-') | ForEach-Object { Get-QuotedNativeArgument $_ }) -join ' ')
        $lockStart.UseShellExecute=$false; $lockStart.RedirectStandardInput=$true; $lockStart.RedirectStandardOutput=$true; $lockStart.RedirectStandardError=$true
        $locker=New-Object Diagnostics.Process; $locker.StartInfo=$lockStart
        try {
            Assert-ProbeTest ($locker.Start()) 'Fixture lock session must start.'
            $locker.StandardInput.WriteLine("BEGIN; LOCK TABLE srp.ohlcvt_1m_2026q1 IN ACCESS EXCLUSIVE MODE;`n\echo LOCK_HELD"); $locker.StandardInput.Flush()
            $ready=$locker.StandardOutput.ReadLineAsync()
            Assert-ProbeTest ($ready.Wait(10000) -and $ready.Result -ceq 'LOCK_HELD') 'Lock must be confirmed before the bounded timeout test.'
            $watch=[Diagnostics.Stopwatch]::StartNew()
            Invoke-ReconciliationCase 'Statement or lock timeout leaves failed bounded evidence' $good 2 FAIL FAIL @('-StatementTimeoutSeconds','5') | Out-Null
            $watch.Stop()
            Assert-ProbeTest ($watch.Elapsed.TotalSeconds -lt 45) 'Timed-out database work must be bounded.'
        }
        finally {
            if (-not $locker.HasExited) { $locker.StandardInput.WriteLine('ROLLBACK;'); $locker.StandardInput.Close(); if (-not $locker.WaitForExit(5000)) { $locker.Kill(); $locker.WaitForExit() } }
            $locker.Dispose()
        }

        foreach ($path in $preserved.Keys) { Assert-ProbeTest ((Get-Sha $path) -ceq $preserved[$path]) ('Preserved bytes changed: ' + $path) }
        Assert-ProbeTest ((Invoke-FixtureSql srp 'SELECT count(*) FROM srp.ohlcvt_1m_2026q1;') -ceq '4') 'Read-only runs must preserve restored source rows.'
        Assert-ProbeTest ((Invoke-FixtureSql cfa 'SELECT count(*) FROM source_news.source_slots;') -ceq '0') 'Market reconciliation must leave news untouched.'
        $script:Checks.Add('Source, bound evidence, prior runs, repository and database data are preserved')
    }
    $summary=[ordered]@{status='PASS';powershell_version=[string]$PSVersionTable.PSVersion;shell=$script:ShellExecutable;postgres_integration=[bool]$PostgresIntegration;runner_sha256=(Get-Sha $script:Runner);manifest_sha256=$script:ManifestSha;repository_head=$script:RepositoryHead;checks=@($script:Checks.ToArray());q1_mkt_001_local_status='UNVERIFIED';historical_provenance_status='UNVERIFIED';stage1_status='BLOCKED';evidence_population='SYNTHETIC FIXTURES ONLY'}
    Write-TestJson (Join-Path $script:RunRoot test-summary.json) $summary
    Write-Host ("PASS: {0} checks; PostgreSQL integration={1}. User-local reconciliation remains UNVERIFIED." -f $script:Checks.Count,[bool]$PostgresIntegration)
}
finally { foreach ($name in $originalEnvironment.Keys) { Restore-TestEnvironmentVariable $name $originalEnvironment[$name] } }
