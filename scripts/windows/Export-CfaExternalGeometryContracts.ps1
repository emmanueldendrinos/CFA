#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PsqlPath = 'C:\Program Files\PostgreSQL\18\bin\psql.exe',
    [string]$HostName = 'localhost',
    [ValidateRange(1,65535)][int]$Port = 5432,
    [string]$UserName = 'postgres',
    [string]$OutputRoot = '',
    [string]$InventoryRunId = '20260829-065450-2e86a9154d9846ae8b5ac5ce3c695272',
    [string]$InventoryZipSha256 = 'e829005b03fc30a317dd6bcd5b08fa42c41ba9ffcc0be928acf9ffc2263a5423',
    [switch]$ValidateOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# CFA-EXT-006: bounded exact-row export only. These are small contract,
# definition, provenance and active-PLS compatibility tables discovered by the
# directly inspected external PostgreSQL inventory. Bulk geometry values remain
# in their source databases and are not copied by this artifact.
$Targets = [ordered]@{
    srp = @(
        'srp.definitions',
        'srp.source_archives',
        'srp.processing_runs',
        'srp.schema_versions',
        'srp.market_pairs',
        'srp.pair_identity_map',
        'srp.q2_institutional_factor_taxonomy',
        'srp.q2_spike_magnitude_feature_thresholds',
        'srp.research_sot_questions',
        'srp.research_sot_file_register'
    )
    asrp = @(
        'asrp.source_files',
        'asrp.q2_import_contracts',
        'asrp.q2_import_runs',
        'asrp.processing_runs',
        'asrp.project_state',
        'asrp_analysis.q2_analysis_contracts',
        'asrp_analysis.q2_analysis_runs',
        'asrp_analysis.q2_phase_receipts',
        'asrp_hype.protocol_contracts'
    )
    pls_trading = @(
        'pls.scanner_setup',
        'pls.scanner_setup_version',
        'pls.scanner_run',
        'pls.scanner_candidate',
        'pls.ai_research_session',
        'pls.ai_score_result',
        'pls.ai_source'
    )
}

$RoutineSchemas = [ordered]@{
    srp = @('srp')
    asrp = @('asrp','asrp_analysis')
    pls_trading = @('pls')
}

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
    $parent = Join-Path $documents 'CFA-local\external-geometry-contracts'
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

function Split-QualifiedName {
    param([string]$QualifiedName)
    $parts = $QualifiedName.Split('.')
    if($parts.Count-ne2){ throw "Expected schema.table, observed: $QualifiedName" }
    foreach($p in $parts){
        if($p -notmatch '^[a-z_][a-z0-9_]*$'){ throw "Unsafe identifier component: $p" }
    }
    return $parts
}

function New-TableExportSql {
    param([string]$QualifiedName)
    $parts = Split-QualifiedName $QualifiedName
    $schema = $parts[0]
    $table = $parts[1]
    $sql = @"
SELECT to_jsonb(t)::text AS row_json
FROM \"$schema\".\"$table\" AS t
ORDER BY to_jsonb(t)::text;
"@
    Assert-ReadOnlySql $QualifiedName $sql
    return $sql
}

function New-RoutineExportSql {
    param([string[]]$Schemas)
    $quoted = @($Schemas | ForEach-Object {
        if($_ -notmatch '^[a-z_][a-z0-9_]*$'){ throw "Unsafe routine schema: $_" }
        "'" + $_.Replace("'","''") + "'"
    }) -join ','
    $sql = @"
SELECT jsonb_build_object(
           'schema_name', n.nspname,
           'routine_name', p.proname,
           'routine_type', CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END,
           'identity_arguments', pg_get_function_identity_arguments(p.oid),
           'result_type', pg_get_function_result(p.oid),
           'language', l.lanname,
           'volatility', p.provolatile,
           'definition', pg_get_functiondef(p.oid),
           'comment', COALESCE(obj_description(p.oid,'pg_proc'),'')
       )::text AS row_json
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
JOIN pg_language l ON l.oid=p.prolang
WHERE n.nspname IN ($quoted)
  AND p.prokind IN ('f','p')
ORDER BY n.nspname,p.proname,pg_get_function_identity_arguments(p.oid);
"@
    Assert-ReadOnlySql 'routine_export' $sql
    return $sql
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
    if($exit-ne0){
        throw "psql failed for database '$Database' with exit code ${exit}:`n$($lines -join [Environment]::NewLine)"
    }
    Write-Utf8NoBom $OutputPath @($lines | ForEach-Object { [string]$_ })
    return $lines
}

function DataRowCount {
    param([string[]]$Lines)
    if($null-eq$Lines -or $Lines.Count-le1){ return 0 }
    return $Lines.Count-1
}

function Invoke-SelfTest {
    if($Targets.Keys.Count-ne3){ throw 'Expected exactly srp, asrp and pls_trading targets.' }
    if($Targets.Contains('cri_trading_terminal') -or $Targets.Contains('pls_trading_pre_v130')){
        throw 'Out-of-scope predecessor database entered target set.'
    }
    $expected=@('srp','asrp','pls_trading')
    if((@($Targets.Keys)-join ',')-cne($expected-join',')){ throw 'Target database order differs.' }
    foreach($db in $Targets.Keys){
        foreach($table in $Targets[$db]){ [void](New-TableExportSql $table) }
        [void](New-RoutineExportSql $RoutineSchemas[$db])
    }
    $bad='DELETE FROM x;'
    $rejected=$false
    try{ Assert-ReadOnlySql 'bad' $bad }catch{ $rejected=$true }
    if(-not$rejected){ throw 'Mutating SQL guard failed.' }
    if($InventoryZipSha256 -notmatch '^[0-9a-f]{64}$'){ throw 'Inventory ZIP SHA-256 shape differs.' }
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{ Invoke-SelfTest; exit 0 }
    catch{ Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    Invoke-SelfTest | Out-Null
    if(-not(Test-Path -LiteralPath $PsqlPath -PathType Leaf)){ throw "psql not found: $PsqlPath" }
    $version = (& $PsqlPath --version 2>&1 | Out-String).Trim()
    if($LASTEXITCODE-ne0){ throw 'Could not execute psql --version.' }
    if($ValidateOnly){
        Write-Host "CFA EXTERNAL GEOMETRY CONTRACT EXPORT INPUTS: PASS | $version"
        exit 0
    }

    $runRoot=New-RunRoot
    $secure=Read-Host "PostgreSQL password for '$UserName'" -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try{ $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally{ [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    $oldPassword=$env:PGPASSWORD
    $oldOptions=$env:PGOPTIONS
    $env:PGPASSWORD=$plain
    $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=300000'
    $plain=$null

    try{
        $receipts=@()
        foreach($db in $Targets.Keys){
            $dbRoot=Join-Path $runRoot $db
            New-Item -ItemType Directory -Path $dbRoot -Force | Out-Null
            Write-Host "Bounded contract export: $db"
            foreach($qualified in $Targets[$db]){
                $parts=Split-QualifiedName $qualified
                $file=($parts[0]+'__'+$parts[1]+'.jsonl')
                $path=Join-Path $dbRoot $file
                $sql=New-TableExportSql $qualified
                $lines=@(Invoke-PsqlQuery $db $sql $path)
                $rows=DataRowCount $lines
                $receipts += [pscustomobject][ordered]@{
                    database=$db
                    source_object=$qualified
                    export_type='table_rows_jsonl'
                    rows=$rows
                    relative_path=($db+'\'+$file)
                    bytes=(Get-Item -LiteralPath $path).Length
                    sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
            $routinePath=Join-Path $dbRoot 'owned_routines.jsonl'
            $routineSql=New-RoutineExportSql $RoutineSchemas[$db]
            $routineLines=@(Invoke-PsqlQuery $db $routineSql $routinePath)
            $receipts += [pscustomobject][ordered]@{
                database=$db
                source_object=(@($RoutineSchemas[$db])-join',')
                export_type='owned_routine_definitions_jsonl'
                rows=(DataRowCount $routineLines)
                relative_path=($db+'\owned_routines.jsonl')
                bytes=(Get-Item -LiteralPath $routinePath).Length
                sha256=(Get-FileHash -LiteralPath $routinePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }

        $manifestPath=Join-Path $runRoot 'external-geometry-contract-manifest.csv'
        $manifest=@('database,source_object,export_type,rows,relative_path,bytes,sha256')
        foreach($r in $receipts){
            $fields=@($r.database,$r.source_object,$r.export_type,$r.rows,$r.relative_path,$r.bytes,$r.sha256) | ForEach-Object {
                '"'+([string]$_).Replace('"','""')+'"'
            }
            $manifest += ($fields-join',')
        }
        Write-Utf8NoBom $manifestPath $manifest

        $summary=[ordered]@{
            run_status='PASS'
            task_status=[ordered]@{ 'CFA-EXT-006'='PASS' }
            source_inventory_run_id=$InventoryRunId
            source_inventory_zip_sha256=$InventoryZipSha256
            psql_version=$version
            host=$HostName
            port=$Port
            user=$UserName
            default_transaction_read_only='on'
            statement_timeout_ms=300000
            target_databases=@($Targets.Keys)
            exported_object_count=$receipts.Count
            manifest_sha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            exports=$receipts
        }
        $summaryPath=Join-Path $runRoot 'external-geometry-contract-summary.json'
        [System.IO.File]::WriteAllText($summaryPath,(($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine),$Utf8)

        Write-Host ''
        Write-Host 'CFA EXTERNAL GEOMETRY CONTRACT EXPORT: PASS'
        Write-Host ('Evidence directory: '+$runRoot)
        Write-Host ('Exported objects: '+$receipts.Count)
        Write-Host ('Source inventory run: '+$InventoryRunId)
        exit 0
    } finally {
        $env:PGPASSWORD=$oldPassword
        $env:PGOPTIONS=$oldOptions
    }
} catch {
    Write-Host 'CFA EXTERNAL GEOMETRY CONTRACT EXPORT: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){ Write-Host $_.ScriptStackTrace }
    exit 1
}
