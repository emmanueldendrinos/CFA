#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [ValidateRange(5,600)][int]$StatementTimeoutSeconds = 90,
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

function Invoke-PsqlCsv {
    param(
        [Parameter(Mandatory)][string]$PsqlExe,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query
    )

    $sql = "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql $sql
}

function Save-CsvText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        Set-Content -LiteralPath $Path -Value '' -Encoding UTF8
    }
    else {
        Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
    }
}

function Invoke-ExactCount {
    param(
        [Parameter(Mandatory)][string]$PsqlExe,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$QualifiedRelation
    )

    try {
        $text = Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "SELECT count(*)::text FROM $QualifiedRelation;"
        if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^\d+$') {
            return [pscustomobject]@{
                database_name = $Database
                relation_name = $QualifiedRelation
                status = 'UNVERIFIED'
                exact_rows = ''
                error = "Unexpected COUNT(*) result: '$text'"
            }
        }

        return [pscustomobject]@{
            database_name = $Database
            relation_name = $QualifiedRelation
            status = 'PASS'
            exact_rows = [int64]$text
            error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            database_name = $Database
            relation_name = $QualifiedRelation
            status = 'UNVERIFIED'
            exact_rows = ''
            error = $_.Exception.Message
        }
    }
}

$oldPassword = $env:PGPASSWORD
$oldPgOptions = $env:PGOPTIONS
$bstr = [IntPtr]::Zero

try {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $OutputRoot = Join-Path $documents 'CFA-local\legacy-source-verification'
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
    $env:PGOPTIONS = "-c default_transaction_read_only=on -c statement_timeout=$timeoutMs -c lock_timeout=5000"

    $version = Invoke-PsqlText -PsqlExe $psql -Database 'postgres' -Sql 'SHOW server_version;'
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'PostgreSQL returned no server version.' }
    Write-Host "PostgreSQL: $version"
    Write-Host "Session mode: default_transaction_read_only=on"
    Write-Host "Statement timeout: $StatementTimeoutSeconds seconds"

    foreach ($db in @('asrp','srp')) {
        $probe = Invoke-PsqlText -PsqlExe $psql -Database $db -Sql 'SELECT current_database();'
        if ($probe -ne $db) { throw "Database verification failed for '$db'. Returned '$probe'." }
    }

    $asrpRelations = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'p' THEN 'partitioned_table'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized_view'
        WHEN 'f' THEN 'foreign_table'
        ELSE c.relkind::text
    END AS relation_type,
    c.relpersistence AS persistence_code,
    c.reltuples::bigint AS estimated_rows,
    pg_catalog.pg_relation_size(c.oid) AS relation_bytes,
    pg_catalog.pg_total_relation_size(c.oid) AS total_bytes,
    pg_catalog.obj_description(c.oid, 'pg_class') AS relation_comment
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('asrp','asrp_hype')
  AND c.relkind IN ('r','p','v','m','f')
ORDER BY n.nspname, c.relname
"@
    Save-CsvText -Path (Join-Path $runDir 'asrp-relations.csv') -Text $asrpRelations

    $asrpColumns = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    a.attnum AS ordinal_position,
    a.attname AS column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    a.attnotnull AS not_null,
    pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) AS default_expression,
    pg_catalog.col_description(c.oid, a.attnum) AS column_comment
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
WHERE n.nspname IN ('asrp','asrp_hype')
  AND c.relkind IN ('r','p','v','m','f')
  AND a.attnum > 0
  AND a.attisdropped = false
ORDER BY n.nspname, c.relname, a.attnum
"@
    Save-CsvText -Path (Join-Path $runDir 'asrp-columns.csv') -Text $asrpColumns

    $asrpConstraints = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    con.conname AS constraint_name,
    con.contype AS constraint_type,
    pg_catalog.pg_get_constraintdef(con.oid, true) AS constraint_definition
FROM pg_catalog.pg_constraint con
JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('asrp','asrp_hype')
ORDER BY n.nspname, c.relname, con.conname
"@
    Save-CsvText -Path (Join-Path $runDir 'asrp-constraints.csv') -Text $asrpConstraints

    $asrpIndexes = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT
    schemaname AS schema_name,
    tablename AS relation_name,
    indexname AS index_name,
    indexdef AS index_definition
FROM pg_catalog.pg_indexes
WHERE schemaname IN ('asrp','asrp_hype')
ORDER BY schemaname, tablename, indexname
"@
    Save-CsvText -Path (Join-Path $runDir 'asrp-indexes.csv') -Text $asrpIndexes

    $asrpLineageCandidates = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    a.attnum AS ordinal_position,
    a.attname AS column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    'NAME_MATCH_ONLY' AS evidence_status
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('asrp','asrp_hype')
  AND c.relkind IN ('r','p','v','m','f')
  AND a.attnum > 0
  AND a.attisdropped = false
  AND a.attname ~* '(sha|hash|source|load|file|path|member|reject|receipt|run|acquisition|provenance|lineage)'
ORDER BY n.nspname, c.relname, a.attnum
"@
    Save-CsvText -Path (Join-Path $runDir 'asrp-lineage-column-triage.csv') -Text $asrpLineageCandidates

    $srpRelations = Invoke-PsqlCsv -PsqlExe $psql -Database 'srp' -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'p' THEN 'partitioned_table'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized_view'
        WHEN 'f' THEN 'foreign_table'
        ELSE c.relkind::text
    END AS relation_type,
    c.relpersistence AS persistence_code,
    c.reltuples::bigint AS estimated_rows,
    pg_catalog.pg_relation_size(c.oid) AS relation_bytes,
    pg_catalog.pg_total_relation_size(c.oid) AS total_bytes,
    pg_catalog.obj_description(c.oid, 'pg_class') AS relation_comment
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'srp'
  AND c.relkind IN ('r','p','v','m','f')
ORDER BY c.relname
"@
    Save-CsvText -Path (Join-Path $runDir 'srp-relations.csv') -Text $srpRelations

    $srpColumns = Invoke-PsqlCsv -PsqlExe $psql -Database 'srp' -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    a.attnum AS ordinal_position,
    a.attname AS column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    a.attnotnull AS not_null,
    pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) AS default_expression,
    pg_catalog.col_description(c.oid, a.attnum) AS column_comment
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
WHERE n.nspname = 'srp'
  AND c.relkind IN ('r','p','v','m','f')
  AND a.attnum > 0
  AND a.attisdropped = false
ORDER BY c.relname, a.attnum
"@
    Save-CsvText -Path (Join-Path $runDir 'srp-columns.csv') -Text $srpColumns

    $srpConstraints = Invoke-PsqlCsv -PsqlExe $psql -Database 'srp' -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    con.conname AS constraint_name,
    con.contype AS constraint_type,
    pg_catalog.pg_get_constraintdef(con.oid, true) AS constraint_definition
FROM pg_catalog.pg_constraint con
JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'srp'
ORDER BY c.relname, con.conname
"@
    Save-CsvText -Path (Join-Path $runDir 'srp-constraints.csv') -Text $srpConstraints

    $srpIndexes = Invoke-PsqlCsv -PsqlExe $psql -Database 'srp' -Query @"
SELECT
    schemaname AS schema_name,
    tablename AS relation_name,
    indexname AS index_name,
    indexdef AS index_definition
FROM pg_catalog.pg_indexes
WHERE schemaname = 'srp'
ORDER BY tablename, indexname
"@
    Save-CsvText -Path (Join-Path $runDir 'srp-indexes.csv') -Text $srpIndexes

    $coreTargets = @(
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp.q2_import_stage' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp.q2_market_1m_observations' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp.q2_raw_records' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.acquisition_objects' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.acquisition_runs' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.asset_slot_factors' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.asset_source_slot_factors' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.market_slot_factors' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.protocol_contracts' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.run_events' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.source_registry' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.subject_terms' },
        [pscustomobject]@{ Database = 'asrp'; Relation = 'asrp_hype.subjects' },
        [pscustomobject]@{ Database = 'srp'; Relation = 'srp.ohlcvt_1m_2025q2' },
        [pscustomobject]@{ Database = 'srp'; Relation = 'srp.market_pairs' },
        [pscustomobject]@{ Database = 'srp'; Relation = 'srp.pair_identity_map' },
        [pscustomobject]@{ Database = 'srp'; Relation = 'srp.q2_spike_hype_handoff' },
        [pscustomobject]@{ Database = 'srp'; Relation = 'srp.q2_spike_hype_samples' }
    )

    $counts = New-Object System.Collections.Generic.List[object]
    Write-Host ''
    Write-Host 'Running controlled exact counts...'
    foreach ($target in $coreTargets) {
        Write-Host "  $($target.Database):$($target.Relation)"
        $result = Invoke-ExactCount -PsqlExe $psql -Database $target.Database -QualifiedRelation $target.Relation
        $counts.Add($result)
    }

    $countPath = Join-Path $runDir 'core-exact-counts.csv'
    $counts | Export-Csv -LiteralPath $countPath -NoTypeInformation -Encoding UTF8

    $asrpSampleTables = @(
        'asrp.q2_import_stage',
        'asrp_hype.acquisition_runs',
        'asrp_hype.protocol_contracts'
    )

    foreach ($relation in $asrpSampleTables) {
        $safe = $relation -replace '[^A-Za-z0-9._-]', '_'
        try {
            $sample = Invoke-PsqlCsv -PsqlExe $psql -Database 'asrp' -Query "SELECT * FROM $relation LIMIT 5"
            Save-CsvText -Path (Join-Path $runDir ("sample-$safe.csv")) -Text $sample
        }
        catch {
            Set-Content -LiteralPath (Join-Path $runDir ("sample-$safe-error.txt")) -Value $_.Exception.Message -Encoding UTF8
        }
    }

    $passCounts = @($counts | Where-Object { $_.status -eq 'PASS' }).Count
    $unverifiedCounts = @($counts | Where-Object { $_.status -eq 'UNVERIFIED' }).Count

    Write-Host ''
    Write-Host '=== CORE EXACT COUNTS ==='
    $counts | Format-Table database_name, relation_name, status, exact_rows -AutoSize
    Write-Host ''
    Write-Host "Exact count PASS       : $passCounts"
    Write-Host "Exact count UNVERIFIED : $unverifiedCounts"
    Write-Host "Evidence directory     : $runDir"
    Write-Host 'READ-ONLY LEGACY SOURCE VERIFICATION: COMPLETE'
    Write-Host 'No database objects or rows were modified.'
}
catch {
    Write-Host ''
    Write-Host 'READ-ONLY LEGACY SOURCE VERIFICATION: FAIL'
    Write-Host $_.Exception.Message
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
}
