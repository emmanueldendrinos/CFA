#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectId = '',
    [string]$BucketName = '',
    [string]$BucketLocation = 'EU',
    [ValidateSet('STANDARD','NEARLINE','COLDLINE','ARCHIVE')][string]$StorageClass = 'STANDARD',
    [string]$Prefix = 'raw/gdelt-gkg-q2-2025',
    [string]$ArchiveRoot = '',
    [string]$EvidenceRoot = '',
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$DatabaseName = 'cfa',
    [ValidateRange(1,64)][int]$ProcessCount = 4,
    [ValidateRange(1,64)][int]$ThreadCount = 8,
    [bool]$CreateBucketIfMissing = $true,
    [switch]$ValidateOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$ExpectedContractSha = '11f3d81f61533efd0b1984c8f84da3e68128c05142923f4e7a62a76c8de9002e'
$ExpectedSlots = 8736
$ExpectedDownloaded = 7163
$ExpectedProviderMissing = 1573
$ExpectedUnresolved = 0

function Find-Application {
    param([string[]]$Names,[string]$Fallback='')
    foreach($name in $Names){
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if($null-ne$cmd){ return $cmd.Source }
    }
    if(-not[string]::IsNullOrWhiteSpace($Fallback) -and (Test-Path -LiteralPath $Fallback -PathType Leaf)){
        return (Resolve-Path -LiteralPath $Fallback).ProviderPath
    }
    throw ('Required application not found: '+($Names -join ', '))
}

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [System.IO.File]::WriteAllText($Path,$Content,$Utf8NoBom)
}

function Csv {
    param([AllowNull()][object]$Value)
    $s=if($null-eq$Value){''}else{[string]$Value}
    if($s.Contains('"')){$s=$s.Replace('"','""')}
    if($s.Contains(',')-or$s.Contains('"')-or$s.Contains("`r")-or$s.Contains("`n")){return '"'+$s+'"'}
    return $s
}

function Get-ObjectPropertyValue {
    param([object]$Object,[string[]]$Names)
    foreach($name in $Names){
        $p=$Object.PSObject.Properties[$name]
        if($null-ne$p){return $p.Value}
    }
    return $null
}

function Invoke-PsqlText {
    param([string]$Psql,[string]$Database,[string]$Sql)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdout=@(& $Psql -X -w -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2>$err)
        $code=$LASTEXITCODE
        $stderr=if(Test-Path -LiteralPath $err){(Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)}else{''}
        if($code-ne0){throw "psql failed for database '$Database' (exit $code): $stderr"}
        return (($stdout|ForEach-Object{[string]$_})-join[Environment]::NewLine).Trim()
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}

function Invoke-PsqlCsv {
    param([string]$Psql,[string]$Database,[string]$Query)
    $q=$Query.Trim()
    while($q.EndsWith(';')){$q=$q.Substring(0,$q.Length-1).TrimEnd()}
    return Invoke-PsqlText $Psql $Database "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Invoke-Gcloud {
    param([string]$Gcloud,[string[]]$Arguments,[switch]$AllowNonzero)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdout=@(& $Gcloud @Arguments 2>$err)
        $code=$LASTEXITCODE
        $stderr=if(Test-Path -LiteralPath $err){(Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)}else{''}
        if($code-ne0 -and -not$AllowNonzero){
            throw ('gcloud failed (exit '+$code+'): '+($Arguments-join' ')+'`n'+$stderr)
        }
        return [pscustomobject]@{ExitCode=$code;Stdout=(($stdout|ForEach-Object{[string]$_})-join[Environment]::NewLine).Trim();Stderr=$stderr.Trim()}
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}

function Get-FileDualHash {
    param([string]$Path)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    $md5=[System.Security.Cryptography.MD5]::Create()
    $stream=[System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    try{
        $buffer=New-Object byte[] (4MB)
        while(($read=$stream.Read($buffer,0,$buffer.Length))-gt0){
            [void]$sha.TransformBlock($buffer,0,$read,$buffer,0)
            [void]$md5.TransformBlock($buffer,0,$read,$buffer,0)
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0)
        [void]$md5.TransformFinalBlock((New-Object byte[] 0),0,0)
        return [pscustomobject]@{
            Sha256Hex=(($sha.Hash|ForEach-Object{$_.ToString('x2')})-join'')
            Md5Hex=(($md5.Hash|ForEach-Object{$_.ToString('x2')})-join'')
            Md5Base64=[Convert]::ToBase64String($md5.Hash)
        }
    }finally{$stream.Dispose();$sha.Dispose();$md5.Dispose()}
}

function Normalize-Prefix {
    param([string]$Value)
    $v=$Value.Replace('\\','/').Trim('/')
    if([string]::IsNullOrWhiteSpace($v)){throw 'GCS raw prefix must not be blank.'}
    if($v -match '//'){throw 'GCS raw prefix contains an empty path segment.'}
    return $v
}

function Normalize-BucketName {
    param([string]$Value)
    $v=$Value.Trim().ToLowerInvariant()
    if($v -notmatch '^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$'){throw "Invalid GCS bucket name: $Value"}
    return $v
}

function Invoke-SelfTest {
    $temp=[System.IO.Path]::GetTempFileName()
    try{
        [System.IO.File]::WriteAllText($temp,'abc',$Utf8NoBom)
        $h=Get-FileDualHash $temp
        if($h.Sha256Hex-ne'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'){throw 'SHA-256 self-test failed.'}
        if($h.Md5Hex-ne'900150983cd24fb0d6963f7d28e17f72'){throw 'MD5 self-test failed.'}
        if((Normalize-Prefix '/raw/gdelt/')-ne'raw/gdelt'){throw 'Prefix normalization self-test failed.'}
        if((Normalize-BucketName 'abc-cfa-123')-ne'abc-cfa-123'){throw 'Bucket normalization self-test failed.'}
        $rejected=$false
        try{Normalize-BucketName 'Bad Bucket'|Out-Null}catch{$rejected=$true}
        if(-not$rejected){throw 'Invalid bucket self-test failed.'}
        Write-Host 'SELF-TEST: PASS'
    }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}
}

$oldPgPassword=$env:PGPASSWORD
$oldPgOptions=$env:PGOPTIONS
$oldPcu=$env:CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED
$oldProcesses=$env:CLOUDSDK_STORAGE_PROCESS_COUNT
$oldThreads=$env:CLOUDSDK_STORAGE_THREAD_COUNT
$bstr=[IntPtr]::Zero

try{
    $documents=[Environment]::GetFolderPath('MyDocuments')
    if([string]::IsNullOrWhiteSpace($ArchiveRoot)){$ArchiveRoot=Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025'}
    if([string]::IsNullOrWhiteSpace($EvidenceRoot)){$EvidenceRoot=Join-Path $documents 'CFA-local\gcs-gdelt-q2-archive'}
    if(-not(Test-Path -LiteralPath $ArchiveRoot -PathType Container)){throw "Archive root missing: $ArchiveRoot"}
    $ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    New-Item -ItemType Directory -Path $EvidenceRoot -Force|Out-Null
    $runId=(Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N')
    $runRoot=Join-Path $EvidenceRoot $runId
    New-Item -ItemType Directory -Path $runRoot -Force|Out-Null

    $psql=Find-Application @('psql.exe') 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
    $gcloud=Find-Application @('gcloud.cmd','gcloud.exe','gcloud')

    $active=(Invoke-Gcloud $gcloud @('auth','list','--filter=status:ACTIVE','--format=value(account)') ).Stdout
    if([string]::IsNullOrWhiteSpace($active)){
        Write-Host 'No active gcloud account. Starting interactive Google Cloud login...'
        $login=Invoke-Gcloud $gcloud @('auth','login')
        $active=(Invoke-Gcloud $gcloud @('auth','list','--filter=status:ACTIVE','--format=value(account)') ).Stdout
        if([string]::IsNullOrWhiteSpace($active)){throw 'Google Cloud authentication is still unavailable.'}
    }

    if([string]::IsNullOrWhiteSpace($ProjectId)){
        $ProjectId=(Invoke-Gcloud $gcloud @('config','get-value','project','--quiet')).Stdout
        if([string]::IsNullOrWhiteSpace($ProjectId)-or$ProjectId-eq'(unset)'){throw 'No Google Cloud project is configured. Re-run with -ProjectId <project-id>.'}
    }
    $ProjectId=$ProjectId.Trim()
    if([string]::IsNullOrWhiteSpace($BucketName)){$BucketName=$ProjectId+'-cfa-gdelt-q2-2025'}
    $BucketName=Normalize-BucketName $BucketName
    $Prefix=Normalize-Prefix $Prefix

    if([string]::IsNullOrWhiteSpace($env:PGPASSWORD)){
        $secure=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=300000'

    # Process-scoped Cloud SDK properties. Environment variables take precedence
    # over active gcloud configuration and are restored in finally.
    $env:CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED='False'
    $env:CLOUDSDK_STORAGE_PROCESS_COUNT=[string]$ProcessCount
    $env:CLOUDSDK_STORAGE_THREAD_COUNT=[string]$ThreadCount

    Write-Host ('Evidence directory : '+$runRoot)
    Write-Host ('GCloud account      : '+$active)
    Write-Host ('GCloud project      : '+$ProjectId)
    Write-Host ('GCS bucket          : gs://'+$BucketName)
    Write-Host ('GCS raw prefix      : '+$Prefix)
    Write-Host ('Archive root        : '+$ArchiveRoot)
    Write-Host ('Composite uploads   : DISABLED')
    Write-Host ('Transfer workers    : processes='+$ProcessCount+' threads='+$ThreadCount)

    $summaryCsv=Invoke-PsqlCsv $psql $DatabaseName @"
SELECT count(*)::bigint AS exact_slots,
       count(*) FILTER (WHERE status='downloaded')::bigint AS downloaded_slots,
       count(*) FILTER (WHERE status='provider_missing')::bigint AS provider_missing_slots,
       count(*) FILTER (WHERE status IN ('pending','network_failed','integrity_failed'))::bigint AS unresolved_slots
FROM source_news.source_slots
WHERE contract_sha256='$ExpectedContractSha'
"@
    $sourceCsv=Invoke-PsqlCsv $psql $DatabaseName @"
SELECT object_key,local_relative_path,observed_size_bytes,payload_sha256
FROM source_news.source_slots
WHERE contract_sha256='$ExpectedContractSha' AND status='downloaded'
ORDER BY archive_timestamp_utc
"@
    $s=@($summaryCsv|ConvertFrom-Csv)
    $rows=@($sourceCsv|ConvertFrom-Csv)
    if($s.Count-ne1){throw 'Source slot summary cardinality differs.'}
    $slot=$s[0]
    if([long]$slot.exact_slots-ne$ExpectedSlots){throw "Expected $ExpectedSlots source slots; observed $($slot.exact_slots)."}
    if([long]$slot.downloaded_slots-ne$ExpectedDownloaded){throw "Expected $ExpectedDownloaded downloaded slots; observed $($slot.downloaded_slots)."}
    if([long]$slot.provider_missing_slots-ne$ExpectedProviderMissing){throw "Expected $ExpectedProviderMissing provider-missing slots; observed $($slot.provider_missing_slots)."}
    if([long]$slot.unresolved_slots-ne$ExpectedUnresolved){throw "Expected zero unresolved slots; observed $($slot.unresolved_slots)."}
    if($rows.Count-ne$ExpectedDownloaded){throw "Downloaded source registry rows differ: $($rows.Count)."}

    $cloudNames=@{}
    $manifest=New-Object 'System.Collections.Generic.List[object]'
    $index=0
    foreach($r in $rows){
        $index++
        $relative=[string]$r.local_relative_path
        if([string]::IsNullOrWhiteSpace($relative)){throw "Blank local_relative_path for $($r.object_key)."}
        $local=Join-Path $ArchiveRoot ($relative.Replace('/','\'))
        if(-not(Test-Path -LiteralPath $local -PathType Leaf)){throw "Missing local source file: $local"}
        $name=[System.IO.Path]::GetFileName(([string]$r.object_key).Replace('/','\'))
        if([string]::IsNullOrWhiteSpace($name)-or$name-notmatch'^\d{14}\.gkg\.csv\.zip$'){throw "Unexpected GDELT object key: $($r.object_key)"}
        if($cloudNames.ContainsKey($name)){throw "Duplicate cloud object basename: $name"}
        $cloudNames[$name]=$true
        $item=Get-Item -LiteralPath $local
        if([long]$item.Length-ne[long]$r.observed_size_bytes){throw "Local size mismatch before hashing: $relative"}
        $h=Get-FileDualHash $local
        if($h.Sha256Hex-ne([string]$r.payload_sha256).ToLowerInvariant()){throw "Local SHA-256 mismatch: $relative"}
        $manifest.Add([pscustomobject]@{
            object_key=[string]$r.object_key
            local_relative_path=$relative.Replace('\\','/')
            cloud_object_name=$Prefix+'/'+$name
            size_bytes=[long]$item.Length
            sha256=$h.Sha256Hex
            md5_base64=$h.Md5Base64
        })
        if(($index%100)-eq0-or$index-eq$rows.Count){Write-Host ('Local integrity: '+$index+'/'+$rows.Count)}
    }

    $manifestPath=Join-Path $runRoot 'source-object-manifest.csv'
    $manifest|Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
    $uploadList=Join-Path $runRoot 'upload-paths.txt'
    [System.IO.File]::WriteAllLines($uploadList,@($manifest|ForEach-Object{Join-Path $ArchiveRoot (($_.local_relative_path).Replace('/','\'))}),$Utf8NoBom)

    if($ValidateOnly){
        Write-Host 'CFA GDELT GCS ARCHIVE INPUT VALIDATION: PASS'
        Write-Host ('Validated source rows: '+$manifest.Count)
        exit 0
    }

    $bucketUri='gs://'+$BucketName
    $bucketDescribe=Invoke-Gcloud $gcloud @('storage','buckets','describe',$bucketUri,'--project='+$ProjectId,'--format=value(name)','--quiet') -AllowNonzero
    if($bucketDescribe.ExitCode-ne0){
        if(-not$CreateBucketIfMissing){throw "GCS bucket does not exist or is inaccessible: $bucketUri"}
        Write-Host ('Creating bucket '+$bucketUri+' ...')
        Invoke-Gcloud $gcloud @('storage','buckets','create',$bucketUri,'--project='+$ProjectId,'--location='+$BucketLocation,'--default-storage-class='+$StorageClass,'--uniform-bucket-level-access','--public-access-prevention','--soft-delete-duration=7d','--quiet')|Out-Null
    }else{Write-Host ('Using existing bucket '+$bucketUri)}

    $rawUri=$bucketUri+'/'+$Prefix+'/'
    $transferManifest=Join-Path $runRoot 'gcloud-transfer-manifest.csv'
    Write-Host ('Uploading/reconciling '+$manifest.Count+' archives to '+$rawUri)
    $cpErr=[System.IO.Path]::GetTempFileName()
    try{
        Get-Content -LiteralPath $uploadList | & $gcloud storage cp -I $rawUri --no-clobber --manifest-path=$transferManifest --project=$ProjectId 2>$cpErr
        $cpCode=$LASTEXITCODE
        $cpStderr=if(Test-Path -LiteralPath $cpErr){Get-Content -LiteralPath $cpErr -Raw -ErrorAction SilentlyContinue}else{''}
        if($cpCode-ne0){throw "gcloud storage cp failed with exit code $cpCode.`n$cpStderr"}
    }finally{Remove-Item -LiteralPath $cpErr -Force -ErrorAction SilentlyContinue}

    Write-Host 'Reading remote object metadata for post-upload reconciliation...'
    $remoteResult=Invoke-Gcloud $gcloud @('storage','ls','--json',$bucketUri+'/'+$Prefix+'/**','--project='+$ProjectId)
    if([string]::IsNullOrWhiteSpace($remoteResult.Stdout)){throw 'Remote GCS listing is blank.'}
    $remoteParsed=@($remoteResult.Stdout|ConvertFrom-Json)
    $remoteByName=@{}
    foreach($o in $remoteParsed){
        $name=[string](Get-ObjectPropertyValue $o @('name','object_name'))
        if([string]::IsNullOrWhiteSpace($name)){continue}
        $name=$name.TrimStart('/')
        if($name.StartsWith($Prefix+'/',[System.StringComparison]::Ordinal)){
            if($remoteByName.ContainsKey($name)){throw "Duplicate live GCS object in listing: $name"}
            $remoteByName[$name]=$o
        }
    }
    if($remoteByName.Count-ne$ExpectedDownloaded){throw "Remote raw-prefix object count mismatch: expected $ExpectedDownloaded observed $($remoteByName.Count)."}

    $recon=New-Object 'System.Collections.Generic.List[object]'
    $fail=0
    foreach($m in $manifest){
        $remote=$remoteByName[[string]$m.cloud_object_name]
        if($null-eq$remote){
            $fail++
            $recon.Add([pscustomobject]@{cloud_object_name=$m.cloud_object_name;status='FAIL_MISSING';expected_size=$m.size_bytes;remote_size='';expected_md5=$m.md5_base64;remote_md5=''})
            continue
        }
        $sizeValue=Get-ObjectPropertyValue $remote @('size','size_bytes')
        $md5Value=Get-ObjectPropertyValue $remote @('md5_hash','md5Hash','md5')
        $sizeOk=([long]$sizeValue-eq[long]$m.size_bytes)
        $md5Ok=(-not[string]::IsNullOrWhiteSpace([string]$md5Value))-and([string]$md5Value-eq[string]$m.md5_base64)
        $status=if($sizeOk-and$md5Ok){'PASS'}elseif(-not$sizeOk-and-not$md5Ok){'FAIL_SIZE_MD5'}elseif(-not$sizeOk){'FAIL_SIZE'}else{'FAIL_MD5'}
        if($status-ne'PASS'){$fail++}
        $recon.Add([pscustomobject]@{cloud_object_name=$m.cloud_object_name;status=$status;expected_size=$m.size_bytes;remote_size=$sizeValue;expected_md5=$m.md5_base64;remote_md5=$md5Value})
    }
    $reconPath=Join-Path $runRoot 'cloud-reconciliation.csv'
    $recon|Export-Csv -LiteralPath $reconPath -NoTypeInformation -Encoding UTF8
    if($fail-ne0){throw "Cloud reconciliation failed for $fail object(s)."}

    $summary=[ordered]@{
        run_id=$runId
        run_status='PASS'
        task_status=[ordered]@{
            'CFA-GCS-001'='PASS'
            'CFA-GCS-002'='PASS'
            'CFA-GCS-003'='PASS'
            'CFA-GCS-004'='PASS'
            'CFA-GCS-005'='UNVERIFIED'
            'CFA-GCS-006'='BLOCKED'
        }
        source_contract_sha256=$ExpectedContractSha
        exact_slots=$ExpectedSlots
        downloaded_slots=$ExpectedDownloaded
        provider_missing_slots=$ExpectedProviderMissing
        gcloud_account=$active
        gcloud_project=$ProjectId
        bucket=$BucketName
        bucket_location=$BucketLocation
        storage_class=$StorageClass
        raw_prefix=$Prefix
        remote_object_count=$remoteByName.Count
        remote_reconciliation_failures=$fail
        local_source_deleted=$false
        deletion_safe_candidate=$false
    }
    $summaryPath=Join-Path $runRoot 'gcs-archive-summary.json'
    Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 8)+[Environment]::NewLine)

    $manifestCloudUri=$bucketUri+'/manifests/gdelt-gkg-q2-2025/'+$runId+'/'
    Invoke-Gcloud $gcloud @('storage','cp',$manifestPath,$reconPath,$summaryPath,$manifestCloudUri,'--project='+$ProjectId,'--no-clobber')|Out-Null
    $summary.task_status['CFA-GCS-005']='PASS'
    $summary.deletion_safe_candidate=$true
    Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 8)+[Environment]::NewLine)
    # Replace only the small summary in the manifest location so its final gate state is also in cloud.
    Invoke-Gcloud $gcloud @('storage','cp',$summaryPath,$manifestCloudUri,'--project='+$ProjectId)|Out-Null

    Write-Host ''
    Write-Host 'CFA GDELT GCS ARCHIVE: PASS'
    Write-Host ('Raw cloud objects      : '+$remoteByName.Count)
    Write-Host ('Remote mismatches      : '+$fail)
    Write-Host ('Source manifest         : '+$manifestPath)
    Write-Host ('Cloud reconciliation    : '+$reconPath)
    Write-Host ('Summary                 : '+$summaryPath)
    Write-Host ('Cloud manifest prefix   : '+$manifestCloudUri)
    Write-Host 'LOCAL SOURCE DELETION: BLOCKED pending direct review of this PASS receipt.'
    exit 0
}catch{
    Write-Host 'CFA GDELT GCS ARCHIVE: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    $env:PGPASSWORD=$oldPgPassword
    $env:PGOPTIONS=$oldPgOptions
    $env:CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=$oldPcu
    $env:CLOUDSDK_STORAGE_PROCESS_COUNT=$oldProcesses
    $env:CLOUDSDK_STORAGE_THREAD_COUNT=$oldThreads
    if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
}
