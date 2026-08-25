#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [ValidateRange(5,300)][int]$StatementTimeoutSeconds = 60,
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

function Convert-CsvText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text | ConvertFrom-Csv)
}

function Quote-Ident {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Unsafe PostgreSQL identifier: $Value" }
    return '"' + $Value + '"'
}

$oldPassword = $env:PGPASSWORD
$oldPgOptions = $env:PGOPTIONS
$bstr = [IntPtr]::Zero

try {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $OutputRoot = Join-Path $documents 'CFA-local\legacy-lineage'
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
    $readOnly = Invoke-PsqlText -PsqlExe $psql -Database 'postgres' -Sql 'SHOW default_transaction_read_only;'
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'PostgreSQL returned no server version.' }
    if ($readOnly -ne 'on') { throw "Read-only session guard failed. Received: '$readOnly'" }

    Write-Host "PostgreSQL: $version"
    Write-Host "Session mode: default_transaction_read_only=$readOnly"
    Write-Host "Statement timeout: $StatementTimeoutSeconds seconds"
    Write-Host ''

    $coreTargets = @(
        [pscustomobject]@{ Database='asrp'; Schema='asrp'; Table='q2_market_1m_observations' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp'; Table='q2_raw_records' },
        [pscustomobject]@{ Database='srp';  Schema='srp';  Table='ohlcvt_1m_2025q2' }
    )

    $metadataTargets = @(
        [pscustomobject]@{ Database='asrp'; Schema='asrp';      Table='q2_import_stage' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp_hype'; Table='acquisition_runs' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp_hype'; Table='acquisition_objects' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp_hype'; Table='protocol_contracts' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp_hype'; Table='run_events' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp_hype'; Table='source_registry' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp_hype'; Table='subjects' },
        [pscustomobject]@{ Database='asrp'; Schema='asrp_hype'; Table='subject_terms' },
        [pscustomobject]@{ Database='srp';  Schema='srp';       Table='pair_identity_map' },
        [pscustomobject]@{ Database='srp';  Schema='srp';       Table='q2_spike_hype_handoff' },
        [pscustomobject]@{ Database='srp';  Schema='srp';       Table='q2_spike_hype_samples' }
    )

    $allTargets = @($coreTargets + $metadataTargets)
    $structureSummary = New-Object System.Collections.Generic.List[object]

    foreach ($db in @('asrp','srp')) {
        $targetsForDb = @($allTargets | Where-Object { $_.Database -eq $db })
        $predicateParts = New-Object System.Collections.Generic.List[string]
        foreach ($t in $targetsForDb) {
            $s = $t.Schema.Replace("'", "''")
            $r = $t.Table.Replace("'", "''")
            $predicateParts.Add("(n.nspname = '$s' AND c.relname = '$r')")
        }
        $predicate = $predicateParts -join ' OR '

        $columnsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $db -Query @"
SELECT
    current_database() AS database_name,
    n.nspname AS schema_name,
    c.relname AS relation_name,
    a.attnum AS ordinal_position,
    a.attname AS column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    a.attnotnull AS not_null,
    pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) AS default_expression
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
WHERE a.attnum > 0
  AND a.attisdropped = false
  AND ($predicate)
ORDER BY n.nspname, c.relname, a.attnum
"@
        Set-Content -LiteralPath (Join-Path $runDir "$db-target-columns.csv") -Value $columnsCsv -Encoding UTF8

        $constraintsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $db -Query @"
SELECT
    current_database() AS database_name,
    n.nspname AS schema_name,
    c.relname AS relation_name,
    con.conname AS constraint_name,
    con.contype AS constraint_type,
    pg_catalog.pg_get_constraintdef(con.oid, true) AS definition
FROM pg_catalog.pg_constraint con
JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE ($predicate)
ORDER BY n.nspname, c.relname, con.conname
"@
        Set-Content -LiteralPath (Join-Path $runDir "$db-target-constraints.csv") -Value $constraintsCsv -Encoding UTF8

        $indexesCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $db -Query @"
SELECT
    current_database() AS database_name,
    schemaname AS schema_name,
    tablename AS relation_name,
    indexname AS index_name,
    indexdef AS definition
FROM pg_catalog.pg_indexes
WHERE (schemaname, tablename) IN (
    SELECT n.nspname, c.relname
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE $predicate
)
ORDER BY schemaname, tablename, indexname
"@
        Set-Content -LiteralPath (Join-Path $runDir "$db-target-indexes.csv") -Value $indexesCsv -Encoding UTF8

        $commentsCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $db -Query @"
SELECT
    current_database() AS database_name,
    n.nspname AS schema_name,
    c.relname AS relation_name,
    pg_catalog.obj_description(c.oid, 'pg_class') AS relation_comment
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE $predicate
ORDER BY n.nspname, c.relname
"@
        Set-Content -LiteralPath (Join-Path $runDir "$db-target-comments.csv") -Value $commentsCsv -Encoding UTF8

        $columnObjects = @(Convert-CsvText $columnsCsv)
        foreach ($t in $targetsForDb) {
            $count = @($columnObjects | Where-Object { $_.schema_name -eq $t.Schema -and $_.relation_name -eq $t.Table }).Count
            $structureSummary.Add([pscustomobject]@{
                database_name = $db
                relation_name = "$($t.Schema).$($t.Table)"
                column_count = $count
            })
        }
    }

    Write-Host 'Exporting small lineage/reference tables...'
    $exportSummary = New-Object System.Collections.Generic.List[object]

    foreach ($t in $metadataTargets) {
        $schemaIdent = Quote-Ident $t.Schema
        $tableIdent = Quote-Ident $t.Table
        $safeName = ($t.Database + '-' + $t.Schema + '-' + $t.Table) -replace '[^A-Za-z0-9._-]', '_'
        Write-Host "  $($t.Database):$($t.Schema).$($t.Table)"

        try {
            $csv = Invoke-PsqlCsv -PsqlExe $psql -Database $t.Database -Query "SELECT * FROM $schemaIdent.$tableIdent"
            $path = Join-Path $runDir "$safeName.csv"
            Set-Content -LiteralPath $path -Value $csv -Encoding UTF8
            $rows = @(Convert-CsvText $csv).Count
            $exportSummary.Add([pscustomobject]@{
                database_name = $t.Database
                relation_name = "$($t.Schema).$($t.Table)"
                status = 'PASS'
                exported_rows = $rows
                error = ''
            })
        }
        catch {
            $exportSummary.Add([pscustomobject]@{
                database_name = $t.Database
                relation_name = "$($t.Schema).$($t.Table)"
                status = 'UNVERIFIED'
                exported_rows = ''
                error = $_.Exception.Message
            })
        }
    }

    $structureSummary | Export-Csv -LiteralPath (Join-Path $runDir 'structure-summary.csv') -NoTypeInformation -Encoding UTF8
    $exportSummary | Export-Csv -LiteralPath (Join-Path $runDir 'lineage-export-summary.csv') -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host '=== TARGET STRUCTURE SUMMARY ==='
    $structureSummary | Format-Table -AutoSize

    Write-Host ''
    Write-Host '=== LINEAGE EXPORT SUMMARY ==='
    $exportSummary | Format-Table -AutoSize

    Write-Host ''
    Write-Host '=== CORE MARKET COLUMNS ==='
    foreach ($t in $coreTargets) {
        $columnFile = Join-Path $runDir "$($t.Database)-target-columns.csv"
        $rows = @(Import-Csv -LiteralPath $columnFile | Where-Object { $_.schema_name -eq $t.Schema -and $_.relation_name -eq $t.Table })
        Write-Host "[$($t.Database):$($t.Schema).$($t.Table)]"
        foreach ($row in $rows) {
            Write-Host ("  {0}. {1} :: {2} :: not_null={3}" -f $row.ordinal_position, $row.column_name, $row.data_type, $row.not_null)
        }
        Write-Host ''
    }

    Write-Host "Evidence directory: $runDir"
    Write-Host 'READ-ONLY LEGACY LINEAGE INSPECTION: COMPLETE'
    Write-Host 'No database objects or rows were modified.'
}
catch {
    Write-Host ''
    Write-Host 'READ-ONLY LEGACY LINEAGE INSPECTION: FAIL'
    Write-Host $_.Exception.Message
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
}
