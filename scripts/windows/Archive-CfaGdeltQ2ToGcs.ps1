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

function Find-GcloudApplication {
    $fallbacks = @(
        (Join-Path $env:LOCALAPPDATA 'Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'),
        'C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd',
        'C:\Program Files\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
    )
    foreach($name in @('gcloud.cmd','gcloud.exe')){
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if($null-ne$cmd){ return $cmd.Source }
    }
    foreach($fallback in $fallbacks){
        if(Test-Path -LiteralPath $fallback -PathType Leaf){
            return (Resolve-Path -LiteralPath $fallback).ProviderPath
        }
    }
    throw 'Required Google Cloud CLI application not found. Expected gcloud.cmd/gcloud.exe; the PowerShell gcloud.ps1 wrapper is intentionally not used.'
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
    $gcloud=Find-GcloudApplication

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
    Write-Host ('GCloud application  : '+$gcloud)
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
    $sumRows=@($summaryCsv|ConvertFrom-Csv)
    if($sumRows.Count-ne1){throw 'Source registry summary did not return exactly one row.'}
    $s=$sumRows[0]
    if([long]$s.exact_slots-ne$ExpectedSlots -or [long]$s.downloaded_slots-ne$ExpectedDownloaded -or [long]$s.provider_missing_slots-ne$ExpectedProviderMissing -or [long]$s.unresolved_slots-ne$ExpectedUnresolved){
        throw ('Source registry accounting mismatch: slots='+$s.exact_slots+' downloaded='+$s.downloaded_slots+' provider_missing='+$s.provider_missing_slots+' unresolved='+$s.unresolved_slots)
    }

    $downloadCsv=Invoke-PsqlCsv $psql $DatabaseName @"
SELECT object_key,local_relative_path,observed_size_bytes,payload_sha256
FROM source_news.source_slots
WHERE contract_sha256='$ExpectedContractSha' AND status='downloaded'
ORDER BY archive_timestamp_utc,object_key
"@
    $sourceRows=@($downloadCsv|ConvertFrom-Csv)
    if($sourceRows.Count-ne$ExpectedDownloaded){throw "Downloaded source row count mismatch: $($sourceRows.Count)"}

    $manifestPath=Join-Path $runRoot 'source-object-manifest.csv'
    $mw=New-Object System.IO.StreamWriter -ArgumentList $manifestPath,$false,$Utf8NoBom
    try{
        $mw.WriteLine('object_key,local_relative_path,size_bytes,sha256_hex,md5_hex,md5_base64,gcs_object_name')
        $validated=0
        foreach($row in $sourceRows){
            $relative=[string]$row.local_relative_path
            if([string]::IsNullOrWhiteSpace($relative)){throw "Blank local path for $($row.object_key)"}
            $path=Join-Path $ArchiveRoot ($relative.Replace('/','\'))
            if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing local source file: $path"}
            $size=[long](Get-Item -LiteralPath $path).Length
            if($size-ne[long]$row.observed_size_bytes){throw "Local size mismatch: $relative"}
            $h=Get-FileDualHash $path
            if($h.Sha256Hex-ne([string]$row.payload_sha256).ToLowerInvariant()){throw "Local SHA-256 mismatch: $relative"}
            $objectName=$Prefix+'/'+($relative.Replace('\\','/').TrimStart('/'))
            $mw.WriteLine((@($row.object_key,$relative,$size,$h.Sha256Hex,$h.Md5Hex,$h.Md5Base64,$objectName)|ForEach-Object{Csv $_})-join',')
            $validated++
            if($validated-eq1 -or $validated%250-eq0){Write-Host ('Local source validation: '+$validated+'/'+$ExpectedDownloaded)}
        }
    }finally{$mw.Dispose()}

    if($ValidateOnly){
        Write-Host 'CFA GDELT GCS ARCHIVE INPUT VALIDATION: PASS'
        Write-Host ('Manifest: '+$manifestPath)
        exit 0
    }

    $bucketUri='gs://'+$BucketName
    $bucketDescribe=Invoke-Gcloud $gcloud @('storage','buckets','describe',$bucketUri,'--project='+$ProjectId,'--format=json') -AllowNonzero
    if($bucketDescribe.ExitCode-ne0){
        if(-not$CreateBucketIfMissing){throw "GCS bucket does not exist or is unavailable: $bucketUri"}
        Write-Host ('Creating GCS bucket: '+$bucketUri)
        Invoke-Gcloud $gcloud @('storage','buckets','create',$bucketUri,'--project='+$ProjectId,'--location='+$BucketLocation,'--default-storage-class='+$StorageClass,'--uniform-bucket-level-access','--public-access-prevention')|Out-Null
    }else{
        $bucketInfo=$bucketDescribe.Stdout|ConvertFrom-Json
        $remoteLocation=[string](Get-ObjectPropertyValue $bucketInfo @('location','locationType'))
        $remoteStorageClass=[string](Get-ObjectPropertyValue $bucketInfo @('storageClass','storage_class'))
        if(-not[string]::IsNullOrWhiteSpace($remoteLocation) -and $remoteLocation.ToUpperInvariant()-ne$BucketLocation.ToUpperInvariant()){
            throw "Existing bucket location differs: observed=$remoteLocation expected=$BucketLocation"
        }
        if(-not[string]::IsNullOrWhiteSpace($remoteStorageClass) -and $remoteStorageClass.ToUpperInvariant()-ne$StorageClass.ToUpperInvariant()){
            Write-Host "Existing bucket storage class differs from requested default: observed=$remoteStorageClass requested=$StorageClass; preserving existing bucket."
        }
    }

    $rawUri=$bucketUri+'/'+$Prefix+'/'
    Write-Host ('Uploading verified raw corpus to '+$rawUri)
    Invoke-Gcloud $gcloud @('storage','cp','--recursive','--no-clobber',$ArchiveRoot+'\*',$rawUri,'--project='+$ProjectId)|Out-Null

    Write-Host 'Listing cloud raw objects for independent reconciliation...'
    $list=(Invoke-Gcloud $gcloud @('storage','ls','--recursive',$rawUri,'--project='+$ProjectId,'--format=json')).Stdout
    $cloudObjects=@()
    if(-not[string]::IsNullOrWhiteSpace($list)){
        $parsed=$list|ConvertFrom-Json
        if($parsed -is [System.Array]){$cloudObjects=@($parsed)}else{$cloudObjects=@($parsed)}
    }

    $cloudByName=@{}
    foreach($o in $cloudObjects){
        $url=[string](Get-ObjectPropertyValue $o @('url','name'))
        if([string]::IsNullOrWhiteSpace($url)){continue}
        $prefixUri=$bucketUri+'/'
        $name=if($url.StartsWith($prefixUri,[StringComparison]::Ordinal)){$url.Substring($prefixUri.Length)}else{$url.TrimStart('/')}
        if($cloudByName.ContainsKey($name)){throw "Duplicate cloud object listing: $name"}
        $cloudByName[$name]=$o
    }

    $sourceManifest=@(Import-Csv -LiteralPath $manifestPath -Encoding UTF8)
    $reconPath=Join-Path $runRoot 'cloud-reconciliation.csv'
    $rw=New-Object System.IO.StreamWriter -ArgumentList $reconPath,$false,$Utf8NoBom
    $mismatches=0
    try{
        $rw.WriteLine('gcs_object_name,expected_size_bytes,observed_size_bytes,expected_md5_base64,observed_md5_base64,status')
        foreach($row in $sourceManifest){
            $name=[string]$row.gcs_object_name
            $status='PASS';$obsSize='';$obsMd5=''
            if(-not$cloudByName.ContainsKey($name)){$status='MISSING'}else{
                $o=$cloudByName[$name]
                $obsSize=[string](Get-ObjectPropertyValue $o @('size','sizeBytes'))
                $obsMd5=[string](Get-ObjectPropertyValue $o @('md5Hash','md5_hash'))
                if([string]::IsNullOrWhiteSpace($obsSize)-or[long]$obsSize-ne[long]$row.size_bytes){$status='SIZE_MISMATCH'}
                elseif([string]::IsNullOrWhiteSpace($obsMd5)-or$obsMd5-ne[string]$row.md5_base64){$status='MD5_MISMATCH'}
            }
            if($status-ne'PASS'){$mismatches++}
            $rw.WriteLine((@($name,$row.size_bytes,$obsSize,$row.md5_base64,$obsMd5,$status)|ForEach-Object{Csv $_})-join',' )
        }
    }finally{$rw.Dispose()}

    $extra=@($cloudByName.Keys|Where-Object{-not(@($sourceManifest.gcs_object_name)-contains$_)})
    $rawObjectCount=$cloudByName.Count
    $objectCountPass=$rawObjectCount-eq$ExpectedDownloaded
    $extraPass=$extra.Count-eq0
    $reconPass=$mismatches-eq0

    $manifestPrefix='manifests/gdelt-gkg-q2-2025/'+$runId
    $summaryPath=Join-Path $runRoot 'gcs-archive-summary.json'
    $summary=[ordered]@{
        run_id=$runId
        project_id=$ProjectId
        account=$active
        bucket=$BucketName
        bucket_location=$BucketLocation
        storage_class_requested=$StorageClass
        raw_prefix=$Prefix
        raw_object_count=$rawObjectCount
        expected_downloaded_objects=$ExpectedDownloaded
        provider_missing_slots=$ExpectedProviderMissing
        local_archive_root=$ArchiveRoot
        source_manifest_sha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        source_manifest_rows=$sourceManifest.Count
        cloud_reconciliation_sha256=(Get-FileHash -LiteralPath $reconPath -Algorithm SHA256).Hash.ToLowerInvariant()
        cloud_reconciliation_rows=$sourceManifest.Count
        cloud_mismatches=$mismatches
        extra_cloud_objects=$extra.Count
        checks=[ordered]@{
            'CFA-GCS-001'='PASS'
            'CFA-GCS-002'='PASS'
            'CFA-GCS-003'=if($objectCountPass){'PASS'}else{'FAIL'}
            'CFA-GCS-004'=if($reconPass){'PASS'}else{'FAIL'}
            'CFA-GCS-005'=if($extraPass){'PASS'}else{'FAIL'}
            'CFA-GCS-006'='BLOCKED'
        }
        local_deletion_authorized=$false
    }
    Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 8)+[Environment]::NewLine)

    $manifestUri=$bucketUri+'/'+$manifestPrefix+'/'
    Invoke-Gcloud $gcloud @('storage','cp',$manifestPath,$reconPath,$summaryPath,$manifestUri,'--project='+$ProjectId)|Out-Null

    $failed=@($summary.checks.GetEnumerator()|Where-Object{$_.Key-ne'CFA-GCS-006' -and $_.Value-ne'PASS'})
    Write-Host ''
    if($failed.Count-eq0){
        Write-Host 'CFA GDELT GCS ARCHIVE: PASS'
        Write-Host ('Raw cloud objects      : '+$rawObjectCount)
        Write-Host ('Remote mismatches      : '+$mismatches)
        Write-Host ('Source manifest         : '+$manifestPath)
        Write-Host ('Cloud reconciliation    : '+$reconPath)
        Write-Host ('Summary                 : '+$summaryPath)
        Write-Host ('Cloud manifest prefix   : '+$manifestUri)
        Write-Host 'LOCAL SOURCE DELETION: BLOCKED pending direct review of this PASS receipt.'
        exit 0
    }
    Write-Host 'CFA GDELT GCS ARCHIVE: FAIL'
    $failed|ForEach-Object{Write-Host ($_.Key+'='+$_.Value)}
    Write-Host ('Summary: '+$summaryPath)
    exit 1
}catch{
    Write-Host 'CFA GDELT GCS ARCHIVE: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    $env:PGPASSWORD=$oldPgPassword
    $env:PGOPTIONS=$oldPgOptions
    $env:CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=$oldPcu
    $env:CLOUDSDK_STORAGE_PROCESS_COUNT=$oldProcesses
    $env:CLOUDSDK_STORAGE_THREAD_COUNT=$oldThreads
}
