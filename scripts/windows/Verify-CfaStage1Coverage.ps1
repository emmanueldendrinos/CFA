#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [ValidateRange(15,600)][int]$StatementTimeoutSeconds = 120,
    [string]$OutputRoot = ''
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
    param(
        [Parameter(Mandatory)][string]$PsqlExe,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Sql
    )

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
    finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PsqlCsvText {
    param(
        [Parameter(Mandatory)][string]$PsqlExe,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query
    )
    $sql = "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql $sql
}

function Convert-CsvText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text | ConvertFrom-Csv)
}

function Quote-PgIdent {
    param([Parameter(Mandatory)][string]$Value)
    return '"' + $Value.Replace('"','""') + '"'
}

function Save-Text {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

function Invoke-BoundedCheck {
    param(
        [Parameter(Mandatory)][string]$PsqlExe,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$Query
    )

    try {
        $csv = Invoke-PsqlCsvText -PsqlExe $PsqlExe -Database $Database -Query $Query
        $rows = @(Convert-CsvText $csv)
        $detail = if ($rows.Count -gt 0) { ($rows | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine } else { '' }
        return [pscustomobject]@{ check_id=$CheckId; database=$Database; status='PASS'; detail=$detail; error='' }
    }
    catch {
        return [pscustomobject]@{ check_id=$CheckId; database=$Database; status='UNVERIFIED'; detail=''; error=$_.Exception.Message }
    }
}

$oldPassword = $env:PGPASSWORD
$oldPgOptions = $env:PGOPTIONS
$bstr = [IntPtr]::Zero

try {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $OutputRoot = Join-Path $documents 'CFA-local\stage1-coverage'
    }

    $runDir = Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"

    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    $timeoutMs = $StatementTimeoutSeconds * 1000
    $env:PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=$timeoutMs"

    $version = Invoke-PsqlText -PsqlExe $psql -Database 'postgres' -Sql 'SHOW server_version;'
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'PostgreSQL returned no server version.' }
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'
    Write-Host "Statement timeout: $StatementTimeoutSeconds seconds"
    Write-Host ''

    $asrpMarketCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database 'asrp' -Query @"
SELECT
    count(*)::bigint AS exact_rows,
    count(DISTINCT import_run_id)::bigint AS import_run_count,
    count(DISTINCT source_member_ordinal)::bigint AS source_member_ordinal_count,
    count(DISTINCT member_path_raw)::bigint AS member_path_count,
    count(DISTINCT pair_token_opaque)::bigint AS pair_token_count,
    min(source_epoch_seconds) AS min_source_epoch_seconds,
    max(source_epoch_seconds) AS max_source_epoch_seconds,
    min(candle_start_utc) AS min_candle_start_utc,
    max(candle_start_utc) AS max_candle_start_utc,
    count(*) FILTER (WHERE NOT in_source_window)::bigint AS outside_source_window_rows,
    count(*) FILTER (WHERE NOT minute_aligned)::bigint AS non_minute_aligned_rows,
    count(*) FILTER (WHERE canonical_eligible)::bigint AS canonical_eligible_rows,
    count(*) FILTER (WHERE NOT canonical_eligible)::bigint AS canonical_ineligible_rows,
    count(*) FILTER (WHERE cardinality(quality_flags) > 0)::bigint AS rows_with_quality_flags,
    count(*) FILTER (WHERE duplicate_class IS NOT NULL)::bigint AS rows_with_duplicate_class
FROM asrp.q2_market_1m_observations
"@
    Save-Text -Path (Join-Path $runDir 'asrp-market-summary.csv') -Text $asrpMarketCsv

    $asrpRawCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database 'asrp' -Query @"
SELECT
    count(*)::bigint AS exact_rows,
    count(DISTINCT import_run_id)::bigint AS import_run_count,
    count(DISTINCT source_member_ordinal)::bigint AS source_member_ordinal_count,
    count(DISTINCT member_path_raw)::bigint AS member_path_count,
    count(DISTINCT pair_token_opaque)::bigint AS pair_token_count,
    min(imported_at_utc) AS min_imported_at_utc,
    max(imported_at_utc) AS max_imported_at_utc,
    min(observed_field_count) AS min_observed_field_count,
    max(observed_field_count) AS max_observed_field_count,
    count(*) FILTER (WHERE quarantine_reason IS NOT NULL)::bigint AS quarantined_rows
FROM asrp.q2_raw_records
"@
    Save-Text -Path (Join-Path $runDir 'asrp-raw-summary.csv') -Text $asrpRawCsv

    $recordClassCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database 'asrp' -Query @"
SELECT record_class, count(*)::bigint AS rows
FROM asrp.q2_raw_records
GROUP BY record_class
ORDER BY record_class
"@
    Save-Text -Path (Join-Path $runDir 'asrp-record-class.csv') -Text $recordClassCsv

    $duplicateClassCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database 'asrp' -Query @"
SELECT COALESCE(duplicate_class, '<NULL>') AS duplicate_class, count(*)::bigint AS rows
FROM asrp.q2_market_1m_observations
GROUP BY duplicate_class
ORDER BY duplicate_class
"@
    Save-Text -Path (Join-Path $runDir 'asrp-duplicate-class.csv') -Text $duplicateClassCsv

    $srpMarketCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database 'srp' -Query @"
SELECT
    count(*)::bigint AS exact_rows,
    count(DISTINCT pair_id)::bigint AS pair_id_count,
    count(DISTINCT source_archive_id)::bigint AS source_archive_count,
    min(ts_utc) AS min_ts_utc,
    max(ts_utc) AS max_ts_utc,
    count(*) FILTER (WHERE vwap IS NULL)::bigint AS null_vwap_rows,
    count(*) FILTER (WHERE trade_count IS NULL)::bigint AS null_trade_count_rows,
    count(*) FILTER (WHERE processing_run_id IS NULL)::bigint AS null_processing_run_id_rows
FROM srp.ohlcvt_1m_2025q2
"@
    Save-Text -Path (Join-Path $runDir 'srp-market-summary.csv') -Text $srpMarketCsv

    $checks = New-Object System.Collections.Generic.List[object]
    Write-Host 'Running bounded duplicate and lineage checks...'

    $checks.Add((Invoke-BoundedCheck -PsqlExe $psql -Database 'asrp' -CheckId 'ASRP_MARKET_NATURAL_KEY_DUPLICATES' -Query @"
SELECT count(*)::bigint AS duplicate_key_groups, COALESCE(sum(n - 1),0)::bigint AS extra_rows
FROM (
    SELECT pair_token_opaque, candle_start_utc, count(*)::bigint AS n
    FROM asrp.q2_market_1m_observations
    GROUP BY pair_token_opaque, candle_start_utc
    HAVING count(*) > 1
) d
"@))

    $checks.Add((Invoke-BoundedCheck -PsqlExe $psql -Database 'asrp' -CheckId 'ASRP_RAW_PHYSICAL_KEY_DUPLICATES' -Query @"
SELECT count(*)::bigint AS duplicate_key_groups, COALESCE(sum(n - 1),0)::bigint AS extra_rows
FROM (
    SELECT source_member_ordinal, physical_record_number, count(*)::bigint AS n
    FROM asrp.q2_raw_records
    GROUP BY source_member_ordinal, physical_record_number
    HAVING count(*) > 1
) d
"@))

    $checks.Add((Invoke-BoundedCheck -PsqlExe $psql -Database 'srp' -CheckId 'SRP_Q2_NATURAL_KEY_DUPLICATES' -Query @"
SELECT count(*)::bigint AS duplicate_key_groups, COALESCE(sum(n - 1),0)::bigint AS extra_rows
FROM (
    SELECT pair_id, ts_utc, count(*)::bigint AS n
    FROM srp.ohlcvt_1m_2025q2
    GROUP BY pair_id, ts_utc
    HAVING count(*) > 1
) d
"@))

    $checks.Add((Invoke-BoundedCheck -PsqlExe $psql -Database 'asrp' -CheckId 'ASRP_RAW_WITHOUT_TYPED_MATCH' -Query @"
SELECT count(*)::bigint AS missing_typed_rows
FROM asrp.q2_raw_records r
LEFT JOIN asrp.q2_market_1m_observations m
  ON m.import_run_id = r.import_run_id
 AND m.source_member_ordinal = r.source_member_ordinal
 AND m.member_path_raw = r.member_path_raw
 AND m.pair_token_opaque = r.pair_token_opaque
 AND m.physical_record_number = r.physical_record_number
 AND m.raw_record_sha256 = r.raw_record_sha256
WHERE m.import_run_id IS NULL
"@))

    $checks.Add((Invoke-BoundedCheck -PsqlExe $psql -Database 'asrp' -CheckId 'ASRP_TYPED_WITHOUT_RAW_MATCH' -Query @"
SELECT count(*)::bigint AS missing_raw_rows
FROM asrp.q2_market_1m_observations m
LEFT JOIN asrp.q2_raw_records r
  ON r.import_run_id = m.import_run_id
 AND r.source_member_ordinal = m.source_member_ordinal
 AND r.member_path_raw = m.member_path_raw
 AND r.pair_token_opaque = m.pair_token_opaque
 AND r.physical_record_number = m.physical_record_number
 AND r.raw_record_sha256 = m.raw_record_sha256
WHERE r.import_run_id IS NULL
"@))

    $checks | Export-Csv -LiteralPath (Join-Path $runDir 'bounded-checks.csv') -NoTypeInformation -Encoding UTF8

    $lineageCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($db in @('asrp','srp')) {
        $candidateCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database $db -Query @"
SELECT
    current_database() AS database_name,
    n.nspname AS schema_name,
    c.relname AS relation_name,
    a.attname AS column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    c.reltuples::bigint AS estimated_rows
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE a.attnum > 0
  AND NOT a.attisdropped
  AND c.relkind IN ('r','p','v','m','f')
  AND n.nspname <> 'information_schema'
  AND n.nspname NOT LIKE 'pg_%'
  AND (
      c.relname ~* '(source|archive|import|load|run|file|object|acquisition|registry)'
      OR a.attname ~* '(sha|hash|path|archive|source|import|load|run|member|file|url|publish|event|timestamp|time)'
  )
ORDER BY n.nspname, c.relname, a.attnum
"@
        foreach ($row in @(Convert-CsvText $candidateCsv)) { $lineageCandidates.Add($row) }
    }
    $lineageCandidates | Export-Csv -LiteralPath (Join-Path $runDir 'lineage-candidates.csv') -NoTypeInformation -Encoding UTF8

    $smallTargets = @(
        [pscustomobject]@{ database='asrp'; schema='asrp'; table='q2_import_stage' },
        [pscustomobject]@{ database='asrp'; schema='asrp_hype'; table='acquisition_runs' },
        [pscustomobject]@{ database='asrp'; schema='asrp_hype'; table='protocol_contracts' },
        [pscustomobject]@{ database='srp'; schema='srp'; table='pair_identity_map' }
    )

    $profiles = New-Object System.Collections.Generic.List[object]
    $previewLines = New-Object System.Collections.Generic.List[string]

    foreach ($target in $smallTargets) {
        $schemaLiteral = $target.schema.Replace("'","''")
        $tableLiteral = $target.table.Replace("'","''")
        $columnsCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database $target.database -Query @"
SELECT column_name, data_type, ordinal_position
FROM information_schema.columns
WHERE table_schema = '$schemaLiteral'
  AND table_name = '$tableLiteral'
ORDER BY ordinal_position
"@
        $columns = @(Convert-CsvText $columnsCsv)

        foreach ($col in $columns) {
            $qSchema = Quote-PgIdent $target.schema
            $qTable = Quote-PgIdent $target.table
            $qColumn = Quote-PgIdent ([string]$col.column_name)
            $profileCsv = Invoke-PsqlCsvText -PsqlExe $psql -Database $target.database -Query "SELECT count(*)::bigint AS total_rows, count(*) FILTER (WHERE $qColumn IS NULL)::bigint AS null_rows, count(DISTINCT $qColumn::text)::bigint AS distinct_text_values, min($qColumn::text) AS min_text, max($qColumn::text) AS max_text FROM $qSchema.$qTable"
            $profileRows = @(Convert-CsvText $profileCsv)
            if ($profileRows.Count -gt 0) {
                $p = $profileRows[0]
                $profiles.Add([pscustomobject]@{
                    database_name=$target.database; relation_name=($target.schema + '.' + $target.table); column_name=$col.column_name; data_type=$col.data_type;
                    total_rows=$p.total_rows; null_rows=$p.null_rows; distinct_text_values=$p.distinct_text_values; min_text=$p.min_text; max_text=$p.max_text
                })
            }
        }

        $qSchema = Quote-PgIdent $target.schema
        $qTable = Quote-PgIdent $target.table
        $preview = Invoke-PsqlText -PsqlExe $psql -Database $target.database -Sql "SELECT row_to_json(t)::text FROM $qSchema.$qTable t LIMIT 5;"
        $previewLines.Add('[' + $target.database + ':' + $target.schema + '.' + $target.table + ']')
        if ([string]::IsNullOrWhiteSpace($preview)) { $previewLines.Add('<NO ROWS>') } else { $previewLines.Add($preview) }
        $previewLines.Add('')
    }

    $profiles | Export-Csv -LiteralPath (Join-Path $runDir 'small-table-column-profile.csv') -NoTypeInformation -Encoding UTF8
    Save-Text -Path (Join-Path $runDir 'lineage-previews.txt') -Text ($previewLines -join [Environment]::NewLine)

    Write-Host ''
    Write-Host '=== ASRP MARKET SUMMARY ==='
    @(Convert-CsvText $asrpMarketCsv) | Format-List
    Write-Host '=== ASRP RAW SUMMARY ==='
    @(Convert-CsvText $asrpRawCsv) | Format-List
    Write-Host '=== ASRP RAW RECORD CLASSES ==='
    @(Convert-CsvText $recordClassCsv) | Format-Table -AutoSize
    Write-Host '=== ASRP DUPLICATE CLASSES ==='
    @(Convert-CsvText $duplicateClassCsv) | Format-Table -AutoSize
    Write-Host '=== SRP Q2 MARKET SUMMARY ==='
    @(Convert-CsvText $srpMarketCsv) | Format-List
    Write-Host '=== BOUNDED CHECKS ==='
    $checks | Select-Object check_id,status,error | Format-Table -AutoSize
    Write-Host '=== LINEAGE CANDIDATE COLUMNS ==='
    $lineageCandidates | Where-Object { $_.column_name -match '(?i)(sha|hash|path|archive|source|import|load|run|file)' } | Select-Object -First 80 | Format-Table -AutoSize
    Write-Host '=== SMALL TABLE COLUMN PROFILES ==='
    $profiles | Format-Table -AutoSize
    Write-Host '=== LINEAGE PREVIEWS ==='
    $previewLines | ForEach-Object { Write-Host $_ }

    $passCount = @($checks | Where-Object { $_.status -eq 'PASS' }).Count
    $unverifiedCount = @($checks | Where-Object { $_.status -eq 'UNVERIFIED' }).Count
    Write-Host ''
    Write-Host "Bounded checks PASS       : $passCount"
    Write-Host "Bounded checks UNVERIFIED : $unverifiedCount"
    Write-Host "Evidence directory        : $runDir"
    Write-Host 'READ-ONLY STAGE 1 COVERAGE VERIFICATION: COMPLETE'
    Write-Host 'No database objects or rows were modified.'
}
catch {
    Write-Host ''
    Write-Host 'READ-ONLY STAGE 1 COVERAGE VERIFICATION: FAIL'
    Write-Host $_.Exception.Message
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
}
