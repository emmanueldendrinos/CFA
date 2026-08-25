#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [ValidateRange(5,300)][int]$StatementTimeoutSeconds = 60,
    [string]$OutputRoot = '',
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
        return $text
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
}

function Invoke-PsqlCsv {
    param([string]$PsqlExe,[string]$Database,[string]$Query)
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Get-NonNullHashUniquenessStatus {
    param([long]$NonNullRows,[long]$DistinctNonNullHashes)
    if ($NonNullRows -eq $DistinctNonNullHashes) { return 'PASS' }
    return 'FAIL'
}

function Invoke-SelfTest {
    if ((Get-NonNullHashUniquenessStatus -NonNullRows 366 -DistinctNonNullHashes 366) -ne 'PASS') {
        throw 'Self-test failed: unique non-null payload hashes were rejected.'
    }
    if ((Get-NonNullHashUniquenessStatus -NonNullRows 366 -DistinctNonNullHashes 365) -ne 'FAIL') {
        throw 'Self-test failed: duplicate non-null payload hashes were not detected.'
    }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

$oldPassword = $env:PGPASSWORD
$oldPgOptions = $env:PGOPTIONS
$bstr = [IntPtr]::Zero
$ownsPassword = $false

try {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $documents 'CFA-local\news-source-coverage' }
    $runDir = Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"

    if ([string]::IsNullOrWhiteSpace($env:PGPASSWORD)) {
        $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $ownsPassword = $true
    }

    $env:PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds * 1000)"

    $version = Invoke-PsqlText -PsqlExe $psql -Database 'asrp' -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'
    Write-Host "Statement timeout: $StatementTimeoutSeconds seconds"

    $runCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT
    protocol_id,
    run_id,
    status,
    package_version,
    expected_object_count,
    expected_compressed_bytes,
    calibration_status,
    calibration_object_count,
    started_at_utc,
    updated_at_utc,
    completed_at_utc,
    last_object_key
FROM asrp_hype.acquisition_runs
ORDER BY started_at_utc
'@

    $protocolCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT
    protocol_id,
    source_id,
    analysis_run_id,
    import_run_id,
    source_product,
    interval_start_utc,
    interval_end_exclusive_utc,
    expected_slots,
    known_missing_slots,
    selected_object_count,
    selected_compressed_bytes,
    contract_sha256,
    limits_sha256,
    factor_protocol_sha256,
    ddl_sha256,
    parser_sha256,
    selection_sha256,
    installed_at_utc
FROM asrp_hype.protocol_contracts
ORDER BY installed_at_utc
'@

    $objectsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT
    count(*)::bigint AS exact_object_rows,
    count(*) FILTER (WHERE payload_sha256 IS NOT NULL)::bigint AS non_null_payload_sha256_rows,
    count(DISTINCT payload_sha256) FILTER (WHERE payload_sha256 IS NOT NULL)::bigint AS distinct_non_null_payload_sha256,
    count(*) FILTER (WHERE payload_sha256 IS NULL)::bigint AS null_payload_sha256_rows,
    min(archive_timestamp_utc) AS min_archive_timestamp_utc,
    max(archive_timestamp_utc) AS max_archive_timestamp_utc
FROM asrp_hype.acquisition_objects
'@

    $eventsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT *
FROM asrp_hype.run_events
ORDER BY event_id DESC
LIMIT 25
'@

    $factorCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT 'asset_slot_factors' AS relation_name, count(*)::bigint AS exact_rows FROM asrp_hype.asset_slot_factors
UNION ALL
SELECT 'asset_source_slot_factors', count(*)::bigint FROM asrp_hype.asset_source_slot_factors
UNION ALL
SELECT 'market_slot_factors', count(*)::bigint FROM asrp_hype.market_slot_factors
UNION ALL
SELECT 'source_registry', count(*)::bigint FROM asrp_hype.source_registry
UNION ALL
SELECT 'subjects', count(*)::bigint FROM asrp_hype.subjects
UNION ALL
SELECT 'subject_terms', count(*)::bigint FROM asrp_hype.subject_terms
ORDER BY relation_name
'@

    Set-Content -LiteralPath (Join-Path $runDir 'acquisition-runs.csv') -Value $runCsv -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $runDir 'protocol-contracts.csv') -Value $protocolCsv -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $runDir 'acquisition-object-summary.csv') -Value $objectsCsv -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $runDir 'latest-run-events.csv') -Value $eventsCsv -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $runDir 'factor-table-counts.csv') -Value $factorCsv -Encoding UTF8

    $runs = @($runCsv | ConvertFrom-Csv)
    $protocols = @($protocolCsv | ConvertFrom-Csv)
    $objectSummary = @($objectsCsv | ConvertFrom-Csv)
    $factors = @($factorCsv | ConvertFrom-Csv)

    if ($runs.Count -ne 1) { $runCardinalityStatus = 'UNVERIFIED' } else { $runCardinalityStatus = 'PASS' }
    if ($protocols.Count -ne 1) { $protocolCardinalityStatus = 'UNVERIFIED' } else { $protocolCardinalityStatus = 'PASS' }

    $checks = New-Object System.Collections.Generic.List[object]
    $checks.Add([pscustomobject]@{ check_id='ACQUISITION_RUN_CARDINALITY'; status=$runCardinalityStatus; observed=$runs.Count; expected='1' })
    $checks.Add([pscustomobject]@{ check_id='PROTOCOL_CONTRACT_CARDINALITY'; status=$protocolCardinalityStatus; observed=$protocols.Count; expected='1' })

    if ($runs.Count -eq 1 -and $protocols.Count -eq 1 -and $objectSummary.Count -eq 1) {
        $run = $runs[0]
        $protocol = $protocols[0]
        $objects = $objectSummary[0]
        $exactObjects = [long]$objects.exact_object_rows
        $selectedObjects = [long]$protocol.selected_object_count
        $expectedObjects = [long]$run.expected_object_count
        $nonNullHashRows = [long]$objects.non_null_payload_sha256_rows
        $distinctNonNullHashes = [long]$objects.distinct_non_null_payload_sha256

        $checks.Add([pscustomobject]@{ check_id='RUN_STATUS_COMPLETE'; status=if(([string]$run.status) -eq 'completed'){'PASS'}else{'FAIL'}; observed=[string]$run.status; expected='completed' })
        $checks.Add([pscustomobject]@{ check_id='RUN_COMPLETED_TIMESTAMP'; status=if([string]::IsNullOrWhiteSpace([string]$run.completed_at_utc)){'FAIL'}else{'PASS'}; observed=[string]$run.completed_at_utc; expected='non-null' })
        $checks.Add([pscustomobject]@{ check_id='SELECTED_VS_EXPECTED_OBJECTS'; status=if($selectedObjects -eq $expectedObjects){'PASS'}else{'FAIL'}; observed=$selectedObjects; expected=$expectedObjects })
        $checks.Add([pscustomobject]@{ check_id='ACQUIRED_VS_SELECTED_OBJECTS'; status=if($exactObjects -eq $selectedObjects){'PASS'}else{'FAIL'}; observed=$exactObjects; expected=$selectedObjects })
        $checks.Add([pscustomobject]@{ check_id='PAYLOAD_HASH_NULLS'; status=if([long]$objects.null_payload_sha256_rows -eq 0){'PASS'}else{'FAIL'}; observed=$objects.null_payload_sha256_rows; expected='0' })
        $checks.Add([pscustomobject]@{ check_id='PAYLOAD_HASH_NON_NULL_UNIQUENESS'; status=(Get-NonNullHashUniquenessStatus -NonNullRows $nonNullHashRows -DistinctNonNullHashes $distinctNonNullHashes); observed=$distinctNonNullHashes; expected=$nonNullHashRows })

        if (-not [string]::IsNullOrWhiteSpace([string]$objects.max_archive_timestamp_utc)) {
            $maxArchive = [datetimeoffset]::Parse([string]$objects.max_archive_timestamp_utc)
            $intervalEnd = [datetimeoffset]::Parse([string]$protocol.interval_end_exclusive_utc)
            $coverageEndStatus = if ($maxArchive -ge $intervalEnd.AddMinutes(-15)) { 'PASS' } else { 'FAIL' }
            $checks.Add([pscustomobject]@{ check_id='ARCHIVE_TIMESTAMP_REACHES_INTERVAL_END'; status=$coverageEndStatus; observed=$maxArchive.ToString('o'); expected=('>= ' + $intervalEnd.AddMinutes(-15).ToString('o')) })
        } else {
            $checks.Add([pscustomobject]@{ check_id='ARCHIVE_TIMESTAMP_REACHES_INTERVAL_END'; status='FAIL'; observed='NULL'; expected='non-null and reaches interval end' })
        }
    }

    $checks | Export-Csv -LiteralPath (Join-Path $runDir 'coverage-checks.csv') -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host '=== NEWS ACQUISITION RUN ==='
    $runs | Format-List
    Write-Host '=== NEWS PROTOCOL CONTRACT ==='
    $protocols | Format-List
    Write-Host '=== ACQUISITION OBJECT SUMMARY ==='
    $objectSummary | Format-List
    Write-Host '=== NEWS COVERAGE CHECKS ==='
    $checks | Format-Table -AutoSize
    Write-Host '=== HYPE TABLE COUNTS ==='
    $factors | Format-Table -AutoSize
    Write-Host ''

    $failCount = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
    $unverifiedCount = @($checks | Where-Object { $_.status -eq 'UNVERIFIED' }).Count
    Write-Host "Coverage checks FAIL       : $failCount"
    Write-Host "Coverage checks UNVERIFIED : $unverifiedCount"
    Write-Host "Evidence directory         : $runDir"
    Write-Host 'READ-ONLY NEWS SOURCE COVERAGE VERIFICATION: COMPLETE'
    Write-Host 'No PostgreSQL object or row was modified.'
}
catch {
    Write-Host ''
    Write-Host 'READ-ONLY NEWS SOURCE COVERAGE VERIFICATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($ownsPassword) {
        if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    }
}
