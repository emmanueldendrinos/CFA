#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    [string]$HostName = 'localhost',
    [ValidateRange(1,65535)][int]$Port = 5432,
    [string]$UserName = 'postgres',
    [string]$MaintenanceDatabase = 'postgres',
    [string]$OutputRoot = '',
    [switch]$ValidateOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$KeywordPattern = '(srp|asrp|geometry|proximity|spike|opportunity|factor|feature|response|ql|qt|hype|news|kraken|ohlc|market|candidate|event|regime|tail|adverse|favorable)'

function Write-Utf8NoBom {
    param([string]$Path,[string[]]$Lines)
    $parent = Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllLines($Path,$Lines,$Utf8)
}

function New-RunRoot {
    if(-not[string]::IsNullOrWhiteSpace($OutputRoot)){
        New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
        return (Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $parent = Join-Path $documents 'CFA-local\external-postgres-inventory'
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $name = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $path = Join-Path $parent $name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return (Resolve-Path -LiteralPath $path).ProviderPath
}

function Assert-ReadOnlySql {
    param([string]$Name,[string]$Sql)
    if([string]::IsNullOrWhiteSpace($Sql)){ throw "SQL $Name is blank." }
    $normalized = [regex]::Replace($Sql,'(?s)/\*.*?\*/',' ')
    $normalized = [regex]::Replace($normalized,'(?m)--.*$',' ')
    if($normalized -match '(?i)\b(insert|update|delete|merge|create|alter|drop|truncate|grant|revoke|vacuum|analyze|reindex|cluster|refresh|call|do|copy)\b'){
        throw "SQL $Name contains a forbidden mutating/admin keyword."
    }
    if($normalized -notmatch '(?i)^\s*(select|with)\b'){
        throw "SQL $Name is not a SELECT/WITH query."
    }
}

$SqlDatabases = @'
SELECT datname
FROM pg_database
WHERE datallowconn
  AND NOT datistemplate
ORDER BY datname;
'@

$SqlDatabaseMeta = @'
SELECT current_database() AS database_name,
       current_setting('server_version') AS server_version,
       current_setting('TimeZone') AS timezone,
       current_setting('default_transaction_read_only') AS default_transaction_read_only;
'@

$SqlSchemas = @'
SELECT n.nspname AS schema_name,
       COALESCE(obj_description(n.oid,'pg_namespace'),'') AS comment
FROM pg_namespace n
WHERE n.nspname !~ '^pg_'
  AND n.nspname <> 'information_schema'
ORDER BY n.nspname;
'@

$SqlRelations = @'
SELECT n.nspname AS schema_name,
       c.relname AS object_name,
       CASE c.relkind
         WHEN 'r' THEN 'table'
         WHEN 'p' THEN 'partitioned_table'
         WHEN 'v' THEN 'view'
         WHEN 'm' THEN 'materialized_view'
         WHEN 'f' THEN 'foreign_table'
         ELSE c.relkind::text
       END AS object_type,
       CASE WHEN c.relkind IN ('r','p','m') THEN pg_total_relation_size(c.oid) ELSE 0 END AS total_bytes,
       CASE WHEN c.relkind IN ('r','p','m') THEN c.reltuples::bigint ELSE NULL END AS estimated_rows,
       COALESCE(obj_description(c.oid,'pg_class'),'') AS comment
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname !~ '^pg_'
  AND n.nspname <> 'information_schema'
  AND c.relkind IN ('r','p','v','m','f')
ORDER BY n.nspname,c.relname;
'@

$SqlColumns = @'
SELECT n.nspname AS schema_name,
       c.relname AS object_name,
       a.attnum AS ordinal_position,
       a.attname AS column_name,
       pg_catalog.format_type(a.atttypid,a.atttypmod) AS data_type,
       a.attnotnull AS not_null,
       COALESCE(pg_get_expr(ad.adbin,ad.adrelid),'') AS default_expression,
       COALESCE(col_description(c.oid,a.attnum),'') AS comment
FROM pg_attribute a
JOIN pg_class c ON c.oid=a.attrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
LEFT JOIN pg_attrdef ad ON ad.adrelid=a.attrelid AND ad.adnum=a.attnum
WHERE a.attnum > 0
  AND NOT a.attisdropped
  AND n.nspname !~ '^pg_'
  AND n.nspname <> 'information_schema'
  AND c.relkind IN ('r','p','v','m','f')
ORDER BY n.nspname,c.relname,a.attnum;
'@

$SqlRoutines = @'
SELECT n.nspname AS schema_name,
       p.proname AS routine_name,
       CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS routine_type,
       l.lanname AS language,
       pg_get_function_identity_arguments(p.oid) AS identity_arguments,
       pg_get_function_result(p.oid) AS result_type,
       p.provolatile AS volatility,
       md5(pg_get_functiondef(p.oid)) AS definition_md5,
       COALESCE(obj_description(p.oid,'pg_proc'),'') AS comment
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
JOIN pg_language l ON l.oid=p.prolang
WHERE n.nspname !~ '^pg_'
  AND n.nspname <> 'information_schema'
  AND p.prokind IN ('f','p')
ORDER BY n.nspname,p.proname,identity_arguments;
'@

$SqlCandidateObjects = @"
WITH relations AS (
    SELECT CASE c.relkind
             WHEN 'r' THEN 'table'
             WHEN 'p' THEN 'partitioned_table'
             WHEN 'v' THEN 'view'
             WHEN 'm' THEN 'materialized_view'
             WHEN 'f' THEN 'foreign_table'
             ELSE c.relkind::text
           END AS object_type,
           n.nspname AS schema_name,
           c.relname AS object_name,
           CASE WHEN c.relkind IN ('r','p','m') THEN pg_total_relation_size(c.oid) ELSE 0 END AS total_bytes,
           COALESCE(obj_description(c.oid,'pg_class'),'') AS comment
    FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname !~ '^pg_'
      AND n.nspname <> 'information_schema'
      AND c.relkind IN ('r','p','v','m','f')
), routines AS (
    SELECT CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS object_type,
           n.nspname AS schema_name,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS object_name,
           0::bigint AS total_bytes,
           COALESCE(obj_description(p.oid,'pg_proc'),'') AS comment
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname !~ '^pg_'
      AND n.nspname <> 'information_schema'
      AND p.prokind IN ('f','p')
), all_objects AS (
    SELECT * FROM relations
    UNION ALL
    SELECT * FROM routines
)
SELECT object_type,schema_name,object_name,total_bytes,comment
FROM all_objects
WHERE schema_name ~* '$KeywordPattern'
   OR object_name ~* '$KeywordPattern'
   OR comment ~* '$KeywordPattern'
ORDER BY schema_name,object_type,object_name;
"@

$Queries = [ordered]@{
    databases = $SqlDatabases
    database_meta = $SqlDatabaseMeta
    schemas = $SqlSchemas
    relations = $SqlRelations
    columns = $SqlColumns
    routines = $SqlRoutines
    candidate_objects = $SqlCandidateObjects
}

function Invoke-PsqlQuery {
    param([string]$Database,[string]$Sql,[string]$OutputPath)
    $args = @(
        '-X','-w','-v','ON_ERROR_STOP=1',
        '-h',$HostName,'-p',[string]$Port,'-U',$UserName,'-d',$Database,
        '-A','-F',"`t",'-P','footer=off','-P','null=\N',
        '-c',$Sql
    )
    $lines = @(& $PsqlPath @args 2>&1)
    $exit = $LASTEXITCODE
    if($exit -ne 0){
        throw "psql failed for database '$Database' with exit code ${exit}:`n$($lines -join [Environment]::NewLine)"
    }
    Write-Utf8NoBom $OutputPath @($lines | ForEach-Object { [string]$_ })
    return $lines
}

function DataRowCount {
    param([string[]]$Lines)
    if($null-eq$Lines -or $Lines.Count -le 1){ return 0 }
    return $Lines.Count - 1
}

function Invoke-SelfTest {
    foreach($entry in $Queries.GetEnumerator()){
        Assert-ReadOnlySql $entry.Key $entry.Value
    }
    $bad='DELETE FROM x;'
    $rejected=$false
    try{ Assert-ReadOnlySql 'bad' $bad }catch{ $rejected=$true }
    if(-not$rejected){ throw 'Mutating SQL guard failed.' }
    if($KeywordPattern -notmatch 'geometry' -or $KeywordPattern -notmatch 'srp' -or $KeywordPattern -notmatch 'hype'){
        throw 'Candidate keyword pattern self-test failed.'
    }
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{ Invoke-SelfTest; exit 0 }
    catch{ Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    foreach($entry in $Queries.GetEnumerator()){ Assert-ReadOnlySql $entry.Key $entry.Value }
    if(-not(Test-Path -LiteralPath $PsqlPath -PathType Leaf)){ throw "psql not found: $PsqlPath" }
    $version = (& $PsqlPath --version 2>&1 | Out-String).Trim()
    if($LASTEXITCODE -ne 0){ throw 'Could not execute psql --version.' }
    if($ValidateOnly){
        Write-Host "CFA EXTERNAL POSTGRES INVENTORY INPUTS: PASS | $version"
        exit 0
    }

    $runRoot = New-RunRoot
    $secure = Read-Host "PostgreSQL password for '$UserName'" -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $oldPassword=$env:PGPASSWORD
    $oldOptions=$env:PGOPTIONS
    $env:PGPASSWORD=$plain
    $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=300000'
    $plain=$null

    try {
        $databaseListPath=Join-Path $runRoot 'databases.tsv'
        $dbLines=@(Invoke-PsqlQuery $MaintenanceDatabase $SqlDatabases $databaseListPath)
        $databases=@($dbLines | Select-Object -Skip 1 | Where-Object { -not[string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
        if($databases.Count-eq0){ throw 'No connectable non-template databases were returned.' }

        $databaseReceipts=@()
        foreach($db in $databases){
            $safeName=($db -replace '[^A-Za-z0-9_.-]','_')
            $dbRoot=Join-Path $runRoot $safeName
            New-Item -ItemType Directory -Path $dbRoot -Force | Out-Null
            Write-Host "Read-only inventory: $db"
            $receipt=[ordered]@{ database=$db; status='PASS'; error=''; schemas=0; relations=0; columns=0; routines=0; candidate_objects=0; outputs=@{} }
            try {
                foreach($name in @('database_meta','schemas','relations','columns','routines','candidate_objects')){
                    $path=Join-Path $dbRoot ($name+'.tsv')
                    $lines=@(Invoke-PsqlQuery $db $Queries[$name] $path)
                    $count=DataRowCount $lines
                    switch($name){
                        'schemas' {$receipt.schemas=$count}
                        'relations' {$receipt.relations=$count}
                        'columns' {$receipt.columns=$count}
                        'routines' {$receipt.routines=$count}
                        'candidate_objects' {$receipt.candidate_objects=$count}
                    }
                    $receipt.outputs[$name]=[ordered]@{
                        path=$path
                        rows=$count
                        bytes=(Get-Item -LiteralPath $path).Length
                        sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                }
            } catch {
                $receipt.status='UNVERIFIED'
                $receipt.error=$_.Exception.Message
            }
            $databaseReceipts += [pscustomobject]$receipt
        }

        $summary=[ordered]@{
            run_status=if(@($databaseReceipts|Where-Object{$_.status-ne'PASS'}).Count-eq0){'PASS'}else{'UNVERIFIED'}
            task_status=[ordered]@{
                'CFA-EXT-004'=if(@($databaseReceipts|Where-Object{$_.status-ne'PASS'}).Count-eq0){'PASS'}else{'UNVERIFIED'}
                'CFA-EXT-005'='BLOCKED'
            }
            psql_version=$version
            host=$HostName
            port=$Port
            user=$UserName
            maintenance_database=$MaintenanceDatabase
            default_transaction_read_only='on'
            statement_timeout_ms=300000
            databases=$databaseReceipts
        }
        $summaryPath=Join-Path $runRoot 'external-postgres-inventory-summary.json'
        [System.IO.File]::WriteAllText($summaryPath,(($summary|ConvertTo-Json -Depth 12)+[Environment]::NewLine),$Utf8)

        $manifest=@('relative_path,bytes,sha256')
        foreach($file in @(Get-ChildItem -LiteralPath $runRoot -File -Recurse | Sort-Object FullName)){
            if($file.FullName-eq$summaryPath){ continue }
            $rel=$file.FullName.Substring($runRoot.Length).TrimStart('\')
            $manifest += ('"'+$rel.Replace('"','""')+'",'+$file.Length+','+(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
        }
        $manifestPath=Join-Path $runRoot 'external-postgres-inventory-manifest.csv'
        Write-Utf8NoBom $manifestPath $manifest

        Write-Host ''
        Write-Host 'CFA EXTERNAL POSTGRES INVENTORY: COMPLETE'
        Write-Host ('Evidence directory: '+$runRoot)
        Write-Host ('Run status: '+$summary.run_status)
        foreach($r in $databaseReceipts){
            Write-Host ($r.database+': '+$r.status+' | schemas='+$r.schemas+' relations='+$r.relations+' routines='+$r.routines+' candidate_objects='+$r.candidate_objects)
        }
        if($summary.run_status-ne'PASS'){ exit 2 }
        exit 0
    } finally {
        $env:PGPASSWORD=$oldPassword
        $env:PGOPTIONS=$oldOptions
    }
} catch {
    Write-Host 'CFA EXTERNAL POSTGRES INVENTORY: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){ Write-Host $_.ScriptStackTrace }
    exit 1
}
