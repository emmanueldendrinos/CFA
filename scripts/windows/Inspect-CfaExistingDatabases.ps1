#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$ExcludeDatabase = 'cfa',
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

$oldPassword = $env:PGPASSWORD
$bstr = [IntPtr]::Zero

try {
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $OutputRoot = Join-Path $documents 'CFA-local\db-discovery'
    }

    $runDir = Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $psql = Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"

    $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    $version = Invoke-PsqlText -PsqlExe $psql -Database 'postgres' -Sql 'SHOW server_version;'
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'PostgreSQL returned no server version.' }
    Write-Host "PostgreSQL: $version"

    $excludeLiteral = $ExcludeDatabase.Replace("'", "''")
    $databaseCsv = Invoke-PsqlCsv -PsqlExe $psql -Database 'postgres' -Query @"
SELECT
    d.datname AS database_name,
    pg_catalog.pg_get_userbyid(d.datdba) AS owner_name,
    pg_catalog.pg_database_size(d.datname) AS database_size_bytes
FROM pg_catalog.pg_database d
WHERE d.datistemplate = false
  AND d.datallowconn = true
  AND d.datname <> '$excludeLiteral'
ORDER BY d.datname
"@

    Set-Content -LiteralPath (Join-Path $runDir 'databases.csv') -Value $databaseCsv -Encoding UTF8
    $databases = @(Convert-CsvText $databaseCsv)
    if ($databases.Count -eq 0) { throw "No accessible non-template databases other than '$ExcludeDatabase' were found." }

    $summary = New-Object System.Collections.Generic.List[object]
    $signals = New-Object System.Collections.Generic.List[object]

    foreach ($dbRow in $databases) {
        $db = [string]$dbRow.database_name
        $safeDb = $db -replace '[^A-Za-z0-9._-]', '_'
        Write-Host "Inspecting: $db"

        try {
            $relationCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $db -Query @"
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
    CASE WHEN c.relkind IN ('r','p','m') THEN c.reltuples::bigint ELSE NULL END AS estimated_rows,
    CASE WHEN c.relkind IN ('r','p','m') THEN pg_catalog.pg_total_relation_size(c.oid) ELSE NULL END AS total_bytes
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname <> 'information_schema'
  AND n.nspname NOT LIKE 'pg_%'
  AND c.relkind IN ('r','p','v','m','f')
ORDER BY n.nspname, c.relname
"@

            $columnCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $db -Query @"
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    a.attnum AS ordinal_position,
    a.attname AS column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    a.attnotnull AS not_null
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname <> 'information_schema'
  AND n.nspname NOT LIKE 'pg_%'
  AND c.relkind IN ('r','p','v','m','f')
  AND a.attnum > 0
  AND a.attisdropped = false
ORDER BY n.nspname, c.relname, a.attnum
"@

            Set-Content -LiteralPath (Join-Path $runDir "$safeDb-relations.csv") -Value $relationCsv -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $runDir "$safeDb-columns.csv") -Value $columnCsv -Encoding UTF8

            $relations = @(Convert-CsvText $relationCsv)
            $columns = @(Convert-CsvText $columnCsv)

            foreach ($r in $relations) {
                $qualified = ([string]$r.schema_name) + '.' + ([string]$r.relation_name)
                if ($qualified -match '(?i)(kraken|market|trade|ohlc|price|pair|asset|news|gdelt|hype|analy|raw|stage)') {
                    $signals.Add([pscustomobject]@{
                        database_name = $db
                        schema_name = $r.schema_name
                        relation_name = $r.relation_name
                        relation_type = $r.relation_type
                        estimated_rows = $r.estimated_rows
                        total_bytes = $r.total_bytes
                        evidence_status = 'NAME_MATCH_ONLY'
                    })
                }
            }

            $summary.Add([pscustomobject]@{
                database_name = $db
                status = 'PASS'
                relation_count = $relations.Count
                column_count = $columns.Count
                error = ''
            })
        }
        catch {
            $summary.Add([pscustomobject]@{
                database_name = $db
                status = 'FAIL'
                relation_count = ''
                column_count = ''
                error = $_.Exception.Message
            })
        }
    }

    $summaryPath = Join-Path $runDir 'database-summary.csv'
    $signalPath = Join-Path $runDir 'name-triage.csv'
    $summary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8
    if ($signals.Count -gt 0) {
        $signals | Export-Csv -LiteralPath $signalPath -NoTypeInformation -Encoding UTF8
    } else {
        'database_name,schema_name,relation_name,relation_type,estimated_rows,total_bytes,evidence_status' | Set-Content -LiteralPath $signalPath -Encoding UTF8
    }

    Write-Host ''
    Write-Host '=== DATABASE SUMMARY ==='
    $summary | Format-Table -AutoSize
    Write-Host ''
    Write-Host '=== NAME TRIAGE ==='
    if ($signals.Count -gt 0) { $signals | Format-Table -AutoSize } else { Write-Host 'No matching relation names found.' }
    Write-Host ''
    Write-Host "Evidence directory: $runDir"
    Write-Host 'READ-ONLY DISCOVERY: COMPLETE'
}
catch {
    Write-Host ''
    Write-Host 'READ-ONLY DISCOVERY: FAIL'
    Write-Host $_.Exception.Message
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
}
