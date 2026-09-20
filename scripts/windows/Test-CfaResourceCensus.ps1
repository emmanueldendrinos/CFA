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
$utf8 = New-Object System.Text.UTF8Encoding($false,$true)

function Assert-CensusTest {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Resource census test failed: $Message" }
}

function Get-QuotedNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW/C-runtime quoting; also accepted by .NET on Unix.
    $escaped = [regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped = [regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"' + $escaped + '"'
}

function Invoke-TestProcess {
    param([string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds = 180)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = (($Arguments | ForEach-Object { Get-QuotedNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Unable to start test subprocess.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
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

function Invoke-RunnerTest {
    param([string]$Name,[string[]]$ExtraArguments,[int]$ExpectedExit)
    $result = Invoke-TestProcess $script:ShellExecutable (@('-NoLogo','-NoProfile','-NonInteractive','-File',$script:Runner,'-RepoRoot',$script:ResolvedRepo) + $ExtraArguments)
    Assert-CensusTest (-not (($result.stdout + $result.stderr).Contains('cfa-test-placeholder-not-secret'))) ("{0}: subprocess output must not disclose PGPASSWORD." -f $Name)
    Assert-CensusTest ($result.exit_code -eq $ExpectedExit) ("{0}: expected exit {1}, got {2}. stdout: {3} stderr: {4}" -f $Name,$ExpectedExit,$result.exit_code,$result.stdout,$result.stderr)
    $script:Checks.Add($Name)
    Write-Host "PASS: $Name"
    return $result
}

function Get-OnlyNewReceipt {
    param([string]$EvidenceRoot,[string[]]$Previous)
    $receipts = @(Get-ChildItem -LiteralPath (Join-Path $EvidenceRoot 'resource-census') -Filter 'receipt.json' -Recurse -File | Where-Object { $Previous -notcontains $_.FullName })
    Assert-CensusTest ($receipts.Count -eq 1) 'Exactly one new receipt must be written for each collection.'
    return $receipts[0].FullName
}

function Assert-Receipt {
    param([string]$Path,[string]$ExpectedCollectionStatus,[int]$ExpectedFiles)
    $directory = Split-Path -Parent $Path
    $receipt = [System.IO.File]::ReadAllText($Path,$script:Utf8) | ConvertFrom-Json
    Assert-CensusTest ($receipt.collection_status -ceq $ExpectedCollectionStatus) 'Collection status must reflect exact collection result.'
    Assert-CensusTest ($receipt.task_status -ceq 'UNVERIFIED') 'Collection must not approve Q1-RES-001.'
    Assert-CensusTest ($receipt.stage1_status -ceq 'BLOCKED') 'Collection must not advance Stage 1.'
    Assert-CensusTest ($receipt.manifest_sha256 -ceq $script:ManifestSha) 'Canonical manifest hash must match the exact input manifest.'
    Assert-CensusTest ($receipt.files_count -eq $ExpectedFiles) "File inventory count must equal $ExpectedFiles."
    Assert-CensusTest ($receipt.artifacts -is [System.Array]) 'Receipt artifacts must remain an array.'
    $paths = @($receipt.artifacts | ForEach-Object { [string]$_.path })
    Assert-CensusTest (@($paths | Select-Object -Unique).Count -eq $paths.Count) 'Artifact paths must be unique.'
    foreach ($required in @('catalogs.json','errors.json','files.jsonl')) {
        Assert-CensusTest ($paths -contains $required) "Artifact inventory must include $required."
    }
    foreach ($artifact in $receipt.artifacts) {
        Assert-CensusTest (-not [System.IO.Path]::IsPathRooted([string]$artifact.path)) 'Artifact inventory paths must be relative.'
        $artifactPath = [System.IO.Path]::GetFullPath((Join-Path $directory ([string]$artifact.path)))
        Assert-CensusTest ($artifactPath.StartsWith($directory + [System.IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Artifacts may not escape the run directory.'
        Assert-CensusTest (Test-Path -LiteralPath $artifactPath -PathType Leaf) "Artifact must exist: $artifactPath"
        Assert-CensusTest ((Get-Sha $artifactPath) -ceq [string]$artifact.sha256) "Exact artifact hash must match: $artifactPath"
        Assert-CensusTest ((Get-Item -LiteralPath $artifactPath).Length -eq $artifact.bytes) "Exact artifact bytes must match: $artifactPath"
        Assert-CensusTest (-not [System.IO.File]::ReadAllText($artifactPath,$script:Utf8).Contains('cfa-test-placeholder-not-secret')) 'Evidence artifacts must not contain the password sentinel.'
    }
    $errorsRaw = [System.IO.File]::ReadAllText((Join-Path $directory 'errors.json'),$script:Utf8)
    Assert-CensusTest ($errorsRaw.TrimStart().StartsWith('[')) 'errors.json must be an array, including empty collections.'
    $errors = @($errorsRaw | ConvertFrom-Json)
    Assert-CensusTest ($errors.Count -eq $receipt.errors_count) 'Error accounting must reconcile.'
    if ($ExpectedCollectionStatus -ceq 'PASS') { Assert-CensusTest ($errors.Count -eq 0) 'PASS collection may not hide errors.' }
    else { Assert-CensusTest ($errors.Count -gt 0) 'Failed collection must include explicit errors.' }
    $catalogRaw = [System.IO.File]::ReadAllText((Join-Path $directory 'catalogs.json'),$script:Utf8)
    Assert-CensusTest ($catalogRaw.TrimStart().StartsWith('[')) 'catalogs.json must be an array, including empty collections.'
    $catalogs = @($catalogRaw | ConvertFrom-Json)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in [System.IO.File]::ReadLines((Join-Path $directory 'files.jsonl'),$script:Utf8)) {
        Assert-CensusTest (-not [string]::IsNullOrWhiteSpace($line)) 'JSONL may not contain blank records.'
        $row = $line | ConvertFrom-Json
        Assert-CensusTest ($null -ne $row -and $null -ne $row.PSObject.Properties['relative_path']) 'Each JSONL line must contain one metadata object.'
        $rows.Add($row)
        if ($row.status -ceq 'PASS') {
            $root = @($receipt.roots | Where-Object { $_.id -ceq $row.root_id })
            Assert-CensusTest ($root.Count -eq 1) 'Every file must identify exactly one input root.'
            $source = Join-Path ([string]$root[0].path) ([string]$row.relative_path)
            Assert-CensusTest ((Get-Sha $source) -ceq $row.sha256) 'File SHA-256 must match the exact preserved source bytes.'
            Assert-CensusTest ((Get-Item -LiteralPath $source).Length -eq $row.length_bytes) 'File byte length must match the exact source.'
            Assert-CensusTest (-not $source.StartsWith([string]$receipt.output_exclusion,[StringComparison]::OrdinalIgnoreCase)) 'Census output subtree must not re-enter source inventory.'
        }
    }
    Assert-CensusTest ($rows.Count -eq $receipt.files_count) 'Every JSONL line must reconcile to files_count.'
    return [pscustomobject]@{ receipt=$receipt; catalogs=$catalogs; files=$rows.ToArray(); directory=$directory }
}

function Invoke-FixtureSql {
    param([string]$Database,[string]$Sql)
    $oldDatabase = [Environment]::GetEnvironmentVariable('PGDATABASE','Process')
    try {
        [Environment]::SetEnvironmentVariable('PGDATABASE',$Database,'Process')
        $result = Invoke-TestProcess $script:ResolvedPsql @('-X','-w','-h',$PgHost,'-p',[string]$PgPort,'-U',$PgUser,'-v','ON_ERROR_STOP=1','-A','-t','-c',$Sql)
        Assert-CensusTest ($result.exit_code -eq 0) ("Disposable PostgreSQL fixture command failed: " + $result.stderr)
        return $result.stdout.Trim()
    }
    finally { [Environment]::SetEnvironmentVariable('PGDATABASE',$oldDatabase,'Process') }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Join-Path $PSScriptRoot '..\..' }
$script:ResolvedRepo = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
$script:Runner = Join-Path $script:ResolvedRepo 'scripts/windows/Invoke-CfaResourceCensus.ps1'
$script:ShellExecutable = (Get-Process -Id $PID).Path
$script:Utf8 = $utf8
$manifest = Join-Path $script:ResolvedRepo 'config/quarters/2026Q1.json'
$script:ManifestSha = Get-CanonicalSha $manifest
if ([string]::IsNullOrWhiteSpace($TestOutputRoot)) { $TestOutputRoot = [System.IO.Path]::GetTempPath() }
$runRoot = Join-Path ([System.IO.Path]::GetFullPath($TestOutputRoot)) ('cfa-census-tests-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($runRoot) | Out-Null
Write-Host "Test evidence: $runRoot"
$originalPassword = [Environment]::GetEnvironmentVariable('PGPASSWORD','Process')
$originalEncoding = [Environment]::GetEnvironmentVariable('PGCLIENTENCODING','Process')
$originalConnectionEnvironment = @{}
foreach ($name in @('PGSERVICE','PGSERVICEFILE','PGHOSTADDR')) {
    $originalConnectionEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,$null,'Process')
}
try {
    # Test-only placeholder, not a credential. It prevents an interactive prompt.
    [Environment]::SetEnvironmentVariable('PGPASSWORD','cfa-test-placeholder-not-secret','Process')
    [Environment]::SetEnvironmentVariable('PGCLIENTENCODING','UTF8','Process')
    foreach ($scriptPath in @($script:Runner,$PSCommandPath)) {
        $tokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors) | Out-Null
        Assert-CensusTest ($parseErrors.Count -eq 0) ("PowerShell parsing: " + $scriptPath)
    }
    $script:Checks.Add('Parse runner and tests in the current target shell')
    Invoke-RunnerTest 'Runner self-tests' @('-SelfTest') 0 | Out-Null

    $kraken = Join-Path $runRoot ("Kraken space 'quote' " + [char]0x03A9)
    $evidence = Join-Path $runRoot ("Evidence space 'quote' " + [char]0x03A9)
    [System.IO.Directory]::CreateDirectory($kraken) | Out-Null
    [System.IO.Directory]::CreateDirectory($evidence) | Out-Null
    $badManifest = Join-Path $runRoot 'malformed.json'
    New-TestFile $badManifest '{"quarter_id":'
    $baseArguments = @('-KrakenRoot',$kraken,'-EvidenceRoot',$evidence)
    Invoke-RunnerTest 'Malformed manifest is a preflight failure' ($baseArguments + @('-ManifestPath',$badManifest)) 1 | Out-Null
    Invoke-RunnerTest 'Missing psql executable is a preflight failure' ($baseArguments + @('-PsqlPath',(Join-Path $runRoot 'missing-psql.exe'))) 1 | Out-Null

    if ($PostgresIntegration) {
        Assert-CensusTest ($PgHost -ceq '127.0.0.1' -and $PgPort -eq 55432 -and $PgUser -ceq 'cfa_census_ci') 'Integration DDL is restricted to the isolated CI endpoint and role.'
        Assert-CensusTest (-not [string]::IsNullOrWhiteSpace($DisposableDataDirectory)) 'Explicit disposable PostgreSQL data directory is mandatory.'
        $expectedData = (Resolve-Path -LiteralPath $DisposableDataDirectory).ProviderPath.TrimEnd('\','/')
        Assert-CensusTest (Test-Path -LiteralPath (Join-Path $expectedData 'PG_VERSION') -PathType Leaf) 'Disposable directory must contain PG_VERSION.'
        Assert-CensusTest (Test-Path -LiteralPath (Join-Path $expectedData 'postmaster.pid') -PathType Leaf) 'Disposable instance must be running.'
        $script:ResolvedPsql = (Resolve-Path -LiteralPath $PsqlPath).ProviderPath
        $actualData = Invoke-FixtureSql 'postgres' "SELECT current_setting('data_directory');"
        Assert-CensusTest ([System.IO.Path]::GetFullPath($actualData).TrimEnd('\','/') -ieq $expectedData) 'Connected server must be the explicitly identified disposable instance before any DDL.'
        $script:Checks.Add('Disposable PostgreSQL identity proved before fixture DDL')

        $oddDatabase = "census = 'quote' `"double`" \ " + [char]0x03A9
        $quotedOddDatabase = '"' + $oddDatabase.Replace('"','""') + '"'
        Invoke-FixtureSql 'postgres' 'CREATE DATABASE cfa;' | Out-Null
        Invoke-FixtureSql 'postgres' ('CREATE DATABASE ' + $quotedOddDatabase + ';') | Out-Null
        Invoke-FixtureSql 'cfa' 'CREATE SCHEMA empty_schema; CREATE SCHEMA "pgX"; CREATE TABLE "pgX"."quoted table" ("id space" bigint, "value" numeric(10,2), "note" text);' | Out-Null
        Invoke-FixtureSql $oddDatabase 'CREATE SCHEMA "empty odd schema"; CREATE TABLE public.fixture (id integer);' | Out-Null
        $script:Checks.Add('PostgreSQL fixtures: cfa, unusual database, pgX, empty schemas, typed columns')

        New-TestFile (Join-Path $kraken 'not-quarter-labelled.bin') ("source " + [char]0x03A9 + "`r`n")
        New-TestFile (Join-Path $kraken "nested 'quote'/empty.txt") ''
        New-TestFile (Join-Path $evidence ('metadata ' + [char]0x03A9 + '.txt')) "fixture`n"
        New-TestFile (Join-Path $evidence 'resource-census/old-fixture/previous.json') '{"must_be_excluded":true}'
        $sourceFiles = @(Get-ChildItem -LiteralPath $kraken,$evidence -Recurse -File)
        $preserved = @{}
        foreach ($file in $sourceFiles) { $preserved[$file.FullName] = Get-Sha $file.FullName }
        $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $tracked = Invoke-TestProcess $git @('-C',$script:ResolvedRepo,'ls-files','-z')
        Assert-CensusTest ($tracked.exit_code -eq 0) 'Repository tracked input inventory must be readable.'
        foreach ($relative in $tracked.stdout.Split([char]0)) {
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                $path = Join-Path $script:ResolvedRepo $relative
                if (Test-Path -LiteralPath $path -PathType Leaf) { $preserved[$path] = Get-Sha $path }
            }
        }
        $preserved[$script:Runner] = Get-Sha $script:Runner
        $connectionArguments = @('-PgHost',$PgHost,'-PgPort',[string]$PgPort,'-PgUser',$PgUser,'-PsqlPath',$script:ResolvedPsql)
        $bogusServiceFile = Join-Path $runRoot 'bogus-pg-service.conf'
        New-TestFile $bogusServiceFile "[census_bogus_service]`nhost=192.0.2.1`nport=1`nuser=wrong_user`ndbname=wrong_database`n"
        [Environment]::SetEnvironmentVariable('PGSERVICE','census_bogus_service','Process')
        [Environment]::SetEnvironmentVariable('PGSERVICEFILE',$bogusServiceFile,'Process')
        [Environment]::SetEnvironmentVariable('PGHOSTADDR','192.0.2.1','Process')
        Invoke-RunnerTest 'Exact full census with live disposable PostgreSQL' ($baseArguments + $connectionArguments) 0 | Out-Null
        foreach ($name in @('PGSERVICE','PGSERVICEFILE','PGHOSTADDR')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
        $script:Checks.Add('Inherited libpq service/host-address overrides cannot redirect the confirmed endpoint')
        $firstPath = Get-OnlyNewReceipt $evidence @()
        $first = Assert-Receipt $firstPath 'PASS' 3
        $firstReceiptHash = Get-Sha $firstPath
        $dbNames = @($first.catalogs | ForEach-Object { $_.database_name })
        Assert-CensusTest ($dbNames -contains 'cfa' -and $dbNames -contains 'postgres' -and $dbNames -ccontains $oddDatabase) 'Every non-template database, including cfa and the exact unusual name, must be inventoried.'
        Assert-CensusTest ($dbNames -notcontains 'template0' -and $dbNames -notcontains 'template1') 'Template databases must not enter the population.'
        Assert-CensusTest (@($dbNames | Select-Object -Unique).Count -eq $dbNames.Count) 'Database evidence must have no name collisions.'
        foreach ($database in $first.catalogs) {
            Assert-CensusTest ($database.status -ceq 'PASS' -and $database.read_only -ceq 'on') 'Every successful database catalog must prove a READ ONLY transaction.'
            Assert-CensusTest (-not [string]::IsNullOrWhiteSpace([string]$database.server_version)) 'Actual PostgreSQL version must be recorded.'
            Assert-CensusTest ($database.schemas -is [System.Array] -and $database.relations -is [System.Array] -and $database.columns -is [System.Array]) 'Database catalogs must preserve array shapes.'
        }
        $cfa = @($first.catalogs | Where-Object { $_.database_name -ceq 'cfa' })[0]
        Assert-CensusTest (@($cfa.schemas | Where-Object { $_.schema_name -ceq 'empty_schema' }).Count -eq 1) 'Empty user schemas must be visible.'
        Assert-CensusTest (@($cfa.schemas | Where-Object { $_.schema_name -ceq 'pgX' }).Count -eq 1) 'pgX must not be lost to a broad pg_ wildcard filter.'
        $relation = @($cfa.relations | Where-Object { $_.schema_name -ceq 'pgX' -and $_.relation_name -ceq 'quoted table' })
        Assert-CensusTest ($relation.Count -eq 1 -and $null -ne $relation[0].PSObject.Properties['estimated_rows']) 'Relations must retain exact identifiers and label catalog estimates.'
        $columns = @($cfa.columns | Where-Object { $_.schema_name -ceq 'pgX' -and $_.relation_name -ceq 'quoted table' })
        Assert-CensusTest ($columns.Count -eq 3) 'All fixture columns must be present.'
        Assert-CensusTest (@($columns | Where-Object { $_.column_name -ceq 'value' -and $_.data_type -ceq 'numeric(10,2)' }).Count -eq 1) 'Type precision/scale must be retained.'
        $script:Checks.Add('Receipt, JSON arrays, streaming JSONL, exact source/artifact hashes and catalog assertions')

        Invoke-RunnerTest 'Repeat execution produces a distinct immutable run' ($baseArguments + $connectionArguments) 0 | Out-Null
        $secondPath = Get-OnlyNewReceipt $evidence @($firstPath)
        Assert-Receipt $secondPath 'PASS' 3 | Out-Null
        Assert-CensusTest ((Get-Sha $firstPath) -ceq $firstReceiptHash) 'Repeated execution must not overwrite prior evidence.'

        $emptyKraken = Join-Path $runRoot 'empty Kraken'
        $emptyEvidence = Join-Path $runRoot 'empty Evidence'
        [System.IO.Directory]::CreateDirectory($emptyKraken) | Out-Null
        [System.IO.Directory]::CreateDirectory($emptyEvidence) | Out-Null
        Invoke-RunnerTest 'Empty roots remain a valid zero-file collection' (@('-KrakenRoot',$emptyKraken,'-EvidenceRoot',$emptyEvidence) + $connectionArguments) 0 | Out-Null
        Assert-Receipt (Get-OnlyNewReceipt $emptyEvidence @()) 'PASS' 0 | Out-Null

        if ($env:OS -ceq 'Windows_NT') {
            $junction = Join-Path $runRoot 'junction-to-Kraken'
            New-Item -ItemType Junction -Path $junction -Value $kraken | Out-Null
            $junctionEvidence = Join-Path $runRoot 'junction-output'
            [System.IO.Directory]::CreateDirectory($junctionEvidence) | Out-Null
            Invoke-RunnerTest 'Input root below a junction is rejected before output creation' (@('-KrakenRoot',(Join-Path $junction "nested 'quote'"),'-EvidenceRoot',$junctionEvidence) + $connectionArguments) 1 | Out-Null
            Assert-CensusTest (-not (Test-Path -LiteralPath (Join-Path $junctionEvidence 'resource-census'))) 'Rejected ancestor junction must not create a census output subtree.'
        }

        $missingEvidence = Join-Path $runRoot 'missing-root-output'
        [System.IO.Directory]::CreateDirectory($missingEvidence) | Out-Null
        Invoke-RunnerTest 'Missing Kraken root is explicit collection failure' (@('-KrakenRoot',(Join-Path $runRoot 'absent Kraken'),'-EvidenceRoot',$missingEvidence) + $connectionArguments) 2 | Out-Null
        Assert-Receipt (Get-OnlyNewReceipt $missingEvidence @()) 'FAIL' 0 | Out-Null

        $absentEvidence = Join-Path $runRoot 'originally-absent-evidence'
        Assert-CensusTest (-not (Test-Path -LiteralPath $absentEvidence)) 'Missing evidence-root fixture must not exist before invocation.'
        Invoke-RunnerTest 'Missing evidence input root is recorded despite creating its output directory' (@('-KrakenRoot',$emptyKraken,'-EvidenceRoot',$absentEvidence) + $connectionArguments) 2 | Out-Null
        Assert-Receipt (Get-OnlyNewReceipt $absentEvidence @()) 'FAIL' 0 | Out-Null

        $unsafeEvidence = Join-Path $runRoot 'unsafe-root-output'
        [System.IO.Directory]::CreateDirectory($unsafeEvidence) | Out-Null
        $volumeRoot = [System.IO.Path]::GetPathRoot($runRoot)
        Invoke-RunnerTest 'Volume-root traversal is rejected before output creation' (@('-KrakenRoot',$volumeRoot,'-EvidenceRoot',$unsafeEvidence) + $connectionArguments) 1 | Out-Null
        Assert-CensusTest (-not (Test-Path -LiteralPath (Join-Path $unsafeEvidence 'resource-census'))) 'Rejected volume root must not create output.'
        Invoke-RunnerTest 'Overlapping input roots are rejected before output creation' (@('-KrakenRoot',$runRoot,'-EvidenceRoot',$unsafeEvidence) + $connectionArguments) 1 | Out-Null
        Assert-CensusTest (-not (Test-Path -LiteralPath (Join-Path $unsafeEvidence 'resource-census'))) 'Rejected root overlap must not create output.'

        $offlineEvidence = Join-Path $runRoot 'offline-output'
        [System.IO.Directory]::CreateDirectory($offlineEvidence) | Out-Null
        # Reserve an unserved TCP port to make the failure independent of host services.
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback,0)
        $listener.Start()
        try {
            $offlinePort = $listener.LocalEndpoint.Port
            Invoke-RunnerTest 'Offline endpoint is explicit collection failure' @('-KrakenRoot',$emptyKraken,'-EvidenceRoot',$offlineEvidence,'-PgHost','127.0.0.1','-PgPort',[string]$offlinePort,'-PgUser',$PgUser,'-PsqlPath',$script:ResolvedPsql) 2 | Out-Null
        }
        finally { $listener.Stop() }
        Assert-Receipt (Get-OnlyNewReceipt $offlineEvidence @()) 'FAIL' 0 | Out-Null

        Invoke-FixtureSql 'postgres' 'CREATE DATABASE census_disallowed ALLOW_CONNECTIONS false;' | Out-Null
        $partialEvidence = Join-Path $runRoot 'partial-output'
        [System.IO.Directory]::CreateDirectory($partialEvidence) | Out-Null
        Invoke-RunnerTest 'Partial catalog discovery cannot pass' (@('-KrakenRoot',$emptyKraken,'-EvidenceRoot',$partialEvidence) + $connectionArguments) 2 | Out-Null
        $partial = Assert-Receipt (Get-OnlyNewReceipt $partialEvidence @()) 'FAIL' 0
        $disallowed = @($partial.catalogs | Where-Object { $_.database_name -ceq 'census_disallowed' })
        Assert-CensusTest ($disallowed.Count -eq 1 -and $disallowed[0].status -ceq 'FAIL') 'Disallowed databases must be retained as failures, not filtered away.'
        Assert-CensusTest (@($partial.catalogs | Where-Object { $_.database_name -ceq 'cfa' -and $_.status -ceq 'PASS' }).Count -eq 1) 'One inaccessible database must not erase successful evidence.'

        foreach ($path in $preserved.Keys) { Assert-CensusTest ((Get-Sha $path) -ceq $preserved[$path]) ("Input must remain byte-identical: " + $path) }
        $script:Checks.Add('All tracked repository files, census runner, sources and prior-output fixture preserved byte-for-byte')
        Assert-CensusTest ((Invoke-FixtureSql 'cfa' 'SELECT count(*) FROM "pgX"."quoted table";') -ceq '0') 'Catalog census must not insert source records.'
    }
    $summary = [ordered]@{
        status='PASS'; powershell_version=[string]$PSVersionTable.PSVersion
        shell=$script:ShellExecutable; postgres_integration=[bool]$PostgresIntegration
        runner_sha256=(Get-Sha $script:Runner); manifest_sha256=$script:ManifestSha
        checks=@($script:Checks.ToArray()); q1_local_status='UNVERIFIED'; stage1_status='BLOCKED'
    }
    [System.IO.File]::WriteAllText((Join-Path $runRoot 'test-summary.json'),($summary | ConvertTo-Json -Depth 10),$utf8)
    Write-Host ("PASS: {0} checks; PostgreSQL integration={1}. User-local census remains UNVERIFIED." -f $script:Checks.Count,[bool]$PostgresIntegration)
}
finally {
    [Environment]::SetEnvironmentVariable('PGPASSWORD',$originalPassword,'Process')
    [Environment]::SetEnvironmentVariable('PGCLIENTENCODING',$originalEncoding,'Process')
    foreach ($name in $originalConnectionEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$originalConnectionEnvironment[$name],'Process') }
}
