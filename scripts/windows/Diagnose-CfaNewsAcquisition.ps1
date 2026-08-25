#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [ValidateRange(5,300)][int]$StatementTimeoutSeconds = 90,
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

function Get-StopClassification {
    param([string]$RunStatus,[string]$LatestEventType,[int]$RecordedErrorEventTypeCount)
    if ($RunStatus -eq 'completed') { return 'COMPLETED' }
    if ($LatestEventType -eq 'object_completed' -and $RecordedErrorEventTypeCount -eq 0) { return 'NO_RECORDED_FAILURE_AT_STOP' }
    if ($RecordedErrorEventTypeCount -gt 0) { return 'RECORDED_ERROR_EVENT_TYPE_PRESENT' }
    return 'NON_COMPLETION_WITHOUT_SUCCESSFUL_TERMINAL_OBJECT'
}

function Get-DuplicateHashStatus {
    param([long]$DuplicateHashGroupCount)
    if ($DuplicateHashGroupCount -eq 0) { return 'PASS' }
    return 'FAIL'
}

function Invoke-SelfTest {
    if ((Get-StopClassification -RunStatus 'running' -LatestEventType 'object_completed' -RecordedErrorEventTypeCount 0) -ne 'NO_RECORDED_FAILURE_AT_STOP') {
        throw 'Self-test failed: clean stop classification was incorrect.'
    }
    if ((Get-StopClassification -RunStatus 'running' -LatestEventType 'object_completed' -RecordedErrorEventTypeCount 1) -ne 'RECORDED_ERROR_EVENT_TYPE_PRESENT') {
        throw 'Self-test failed: recorded error classification was incorrect.'
    }
    if ((Get-DuplicateHashStatus -DuplicateHashGroupCount 0) -ne 'PASS') {
        throw 'Self-test failed: duplicate-hash PASS classification was incorrect.'
    }
    if ((Get-DuplicateHashStatus -DuplicateHashGroupCount 1) -ne 'FAIL') {
        throw 'Self-test failed: duplicate-hash FAIL classification was incorrect.'
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
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $documents 'CFA-local\news-acquisition-diagnosis' }
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

    $runCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT protocol_id, run_id, status, expected_object_count, calibration_object_count,
       started_at_utc, updated_at_utc, completed_at_utc, last_object_key
FROM asrp_hype.acquisition_runs
ORDER BY started_at_utc;
'@

    $protocolCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT protocol_id, source_product, interval_start_utc, interval_end_exclusive_utc,
       expected_slots, known_missing_slots, selected_object_count
FROM asrp_hype.protocol_contracts
ORDER BY installed_at_utc;
'@

    $eventTypesCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT event_type,
       count(*)::bigint AS exact_events,
       min(event_at_utc) AS first_event_at_utc,
       max(event_at_utc) AS last_event_at_utc,
       min(object_key) AS min_object_key,
       max(object_key) AS max_object_key
FROM asrp_hype.run_events
GROUP BY event_type
ORDER BY event_type;
'@

    $latestEventsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT protocol_id, run_id, event_id, event_at_utc, event_type, object_key, details_json
FROM asrp_hype.run_events
ORDER BY event_id DESC
LIMIT 100;
'@

    $nonCompletionEventsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT protocol_id, run_id, event_id, event_at_utc, event_type, object_key, details_json
FROM asrp_hype.run_events
WHERE event_type <> 'object_completed'
ORDER BY event_id DESC
LIMIT 100;
'@

    $objectAccountingCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
WITH r AS (
    SELECT last_object_key,
           CASE WHEN last_object_key ~ '^[0-9]{14}$'
                THEN to_timestamp(last_object_key, 'YYYYMMDDHH24MISS')
                ELSE NULL END AS last_object_ts
    FROM asrp_hype.acquisition_runs
    ORDER BY started_at_utc DESC
    LIMIT 1
)
SELECT count(*)::bigint AS exact_object_rows,
       count(*) FILTER (WHERE payload_sha256 IS NULL)::bigint AS null_payload_hash_rows,
       count(DISTINCT payload_sha256) FILTER (WHERE payload_sha256 IS NOT NULL)::bigint AS distinct_non_null_payload_hashes,
       count(*) FILTER (WHERE r.last_object_ts IS NOT NULL AND archive_timestamp_utc <= r.last_object_ts)::bigint AS rows_at_or_before_last_progress_key,
       count(*) FILTER (WHERE r.last_object_ts IS NOT NULL AND archive_timestamp_utc > r.last_object_ts)::bigint AS rows_after_last_progress_key,
       min(archive_timestamp_utc) FILTER (WHERE r.last_object_ts IS NOT NULL AND archive_timestamp_utc > r.last_object_ts) AS min_timestamp_after_last_progress_key,
       max(archive_timestamp_utc) FILTER (WHERE r.last_object_ts IS NOT NULL AND archive_timestamp_utc > r.last_object_ts) AS max_timestamp_after_last_progress_key
FROM asrp_hype.acquisition_objects o
CROSS JOIN r;
'@

    $duplicateHashesCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT payload_sha256,
       count(*)::bigint AS exact_rows,
       min(archive_timestamp_utc) AS min_archive_timestamp_utc,
       max(archive_timestamp_utc) AS max_archive_timestamp_utc
FROM asrp_hype.acquisition_objects
WHERE payload_sha256 IS NOT NULL
GROUP BY payload_sha256
HAVING count(*) > 1
ORDER BY exact_rows DESC, payload_sha256;
'@

    $nullHashRowsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT archive_timestamp_utc, to_jsonb(o)::text AS row_json
FROM asrp_hype.acquisition_objects o
WHERE payload_sha256 IS NULL
ORDER BY archive_timestamp_utc
LIMIT 50;
'@

    $completedAccountingCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT count(*)::bigint AS object_completed_events,
       count(DISTINCT object_key)::bigint AS distinct_completed_object_keys,
       min(object_key) AS min_completed_object_key,
       max(object_key) AS max_completed_object_key
FROM asrp_hype.run_events
WHERE event_type = 'object_completed';
'@

    $completionGapsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
WITH completed AS (
    SELECT event_id,
           object_key,
           to_timestamp(object_key, 'YYYYMMDDHH24MISS') AS object_ts
    FROM asrp_hype.run_events
    WHERE event_type = 'object_completed'
      AND object_key ~ '^[0-9]{14}$'
), ordered AS (
    SELECT event_id, object_key, object_ts,
           lag(object_key) OVER (ORDER BY object_ts, event_id) AS previous_object_key,
           lag(object_ts) OVER (ORDER BY object_ts, event_id) AS previous_object_ts
    FROM completed
)
SELECT previous_object_key, object_key,
       extract(epoch FROM (object_ts - previous_object_ts))/60.0 AS gap_minutes
FROM ordered
WHERE previous_object_ts IS NOT NULL
  AND object_ts - previous_object_ts > interval '15 minutes'
ORDER BY object_ts
LIMIT 500;
'@

    $schemaTablesCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'asrp_hype'
ORDER BY table_name;
'@

    $schemaColumnsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @'
SELECT table_name, ordinal_position, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'asrp_hype'
  AND table_name IN ('acquisition_objects','acquisition_runs','run_events','protocol_contracts')
ORDER BY table_name, ordinal_position;
'@

    $files = [ordered]@{
        'acquisition-run.csv' = $runCsv
        'protocol-contract.csv' = $protocolCsv
        'event-type-summary.csv' = $eventTypesCsv
        'latest-100-events.csv' = $latestEventsCsv
        'latest-100-non-completion-events.csv' = $nonCompletionEventsCsv
        'object-accounting.csv' = $objectAccountingCsv
        'duplicate-non-null-payload-hashes.csv' = $duplicateHashesCsv
        'null-payload-hash-rows.csv' = $nullHashRowsCsv
        'completed-event-accounting.csv' = $completedAccountingCsv
        'completed-event-gaps.csv' = $completionGapsCsv
        'asrp-hype-tables.csv' = $schemaTablesCsv
        'core-table-columns.csv' = $schemaColumnsCsv
    }
    foreach ($name in $files.Keys) { Set-Content -LiteralPath (Join-Path $runDir $name) -Value $files[$name] -Encoding UTF8 }

    $runs = @($runCsv | ConvertFrom-Csv)
    $eventTypes = @($eventTypesCsv | ConvertFrom-Csv)
    $latestEvents = @($latestEventsCsv | ConvertFrom-Csv)
    $objectAccounting = @($objectAccountingCsv | ConvertFrom-Csv)
    $duplicateHashes = @($duplicateHashesCsv | ConvertFrom-Csv)
    $completedAccounting = @($completedAccountingCsv | ConvertFrom-Csv)

    if ($runs.Count -ne 1) { throw "Expected exactly one acquisition run; observed $($runs.Count)." }
    if ($latestEvents.Count -eq 0) { throw 'No run events were returned.' }
    if ($objectAccounting.Count -ne 1) { throw 'Object accounting query did not return exactly one row.' }
    if ($completedAccounting.Count -ne 1) { throw 'Completed-event accounting query did not return exactly one row.' }

    $run = $runs[0]
    $latest = $latestEvents[0]
    $errorEventTypes = @($eventTypes | Where-Object { ([string]$_.event_type) -match '(?i)(fail|error|exception|abort|fatal)' })
    $stopClassification = Get-StopClassification -RunStatus ([string]$run.status) -LatestEventType ([string]$latest.event_type) -RecordedErrorEventTypeCount $errorEventTypes.Count

    $checks = New-Object System.Collections.Generic.List[object]
    $checks.Add([pscustomobject]@{ check_id='LATEST_EVENT_IS_OBJECT_COMPLETED'; status=if(([string]$latest.event_type -eq 'object_completed')){'PASS'}else{'FAIL'}; observed=[string]$latest.event_type; expected='object_completed' })
    $checks.Add([pscustomobject]@{ check_id='RECORDED_ERROR_EVENT_TYPES'; status=if($errorEventTypes.Count -eq 0){'PASS'}else{'FAIL'}; observed=$errorEventTypes.Count; expected='0' })
    $checks.Add([pscustomobject]@{ check_id='NON_NULL_PAYLOAD_HASH_DUPLICATE_GROUPS'; status=(Get-DuplicateHashStatus -DuplicateHashGroupCount $duplicateHashes.Count); observed=$duplicateHashes.Count; expected='0' })
    $checks.Add([pscustomobject]@{ check_id='NULL_PAYLOAD_HASH_ROWS'; status=if([long]$objectAccounting[0].null_payload_hash_rows -eq 0){'PASS'}else{'FAIL'}; observed=$objectAccounting[0].null_payload_hash_rows; expected='0' })
    $checks.Add([pscustomobject]@{ check_id='STOP_CLASSIFICATION'; status='UNVERIFIED'; observed=$stopClassification; expected='direct cause requires process/source evidence' })
    $checks | Export-Csv -LiteralPath (Join-Path $runDir 'diagnosis-checks.csv') -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host '=== NEWS ACQUISITION DIAGNOSIS ==='
    Write-Host "Latest event type                 : $($latest.event_type)"
    Write-Host "Latest event object key           : $($latest.object_key)"
    Write-Host "Recorded error-like event types   : $($errorEventTypes.Count)"
    Write-Host "Stop classification               : $stopClassification"
    Write-Host "Acquisition object rows           : $($objectAccounting[0].exact_object_rows)"
    Write-Host "Rows at/before last progress key  : $($objectAccounting[0].rows_at_or_before_last_progress_key)"
    Write-Host "Rows after last progress key      : $($objectAccounting[0].rows_after_last_progress_key)"
    Write-Host "Null payload hashes               : $($objectAccounting[0].null_payload_hash_rows)"
    Write-Host "Duplicate non-null hash groups    : $($duplicateHashes.Count)"
    Write-Host "object_completed events           : $($completedAccounting[0].object_completed_events)"
    Write-Host "Distinct completed object keys    : $($completedAccounting[0].distinct_completed_object_keys)"
    Write-Host "Evidence directory                : $runDir"
    Write-Host 'READ-ONLY NEWS ACQUISITION DIAGNOSIS: COMPLETE'
    Write-Host 'No PostgreSQL object or row was modified.'
}
catch {
    Write-Host 'READ-ONLY NEWS ACQUISITION DIAGNOSIS: FAIL'
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
