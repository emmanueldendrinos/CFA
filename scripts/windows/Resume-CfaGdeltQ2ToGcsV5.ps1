#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResumeRunRoot,
    [string]$ProjectId = 'asrp-gdelt-recovery',
    [string]$BucketName = 'asrp-gdelt-recovery-cfa-gdelt-q2-2025',
    [string]$BucketLocation = 'EU',
    [ValidateSet('STANDARD','NEARLINE','COLDLINE','ARCHIVE')][string]$StorageClass = 'STANDARD',
    [string]$Prefix = 'raw/gdelt-gkg-q2-2025',
    [string]$ArchiveRoot = 'C:\Users\Emmanuel\Documents\CFA-local\gdelt-gkg-q2-2025',
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$DatabaseName = 'cfa',
    [ValidateRange(1,64)][int]$ProcessCount = 4,
    [ValidateRange(1,64)][int]$ThreadCount = 8,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ExpectedContractSha = '11f3d81f61533efd0b1984c8f84da3e68128c05142923f4e7a62a76c8de9002e'
$ExpectedDownloaded = 7163
$ExpectedProviderMissing = 1573

function Find-GcloudApplication {
    $candidates=@(
        (Join-Path $env:LOCALAPPDATA 'Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'),
        'C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd',
        'C:\Program Files\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd'
    )
    foreach($name in @('gcloud.cmd','gcloud.exe')){
        $cmd=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if($null-ne$cmd){return $cmd.Source}
    }
    foreach($p in $candidates){if(Test-Path -LiteralPath $p -PathType Leaf){return (Resolve-Path -LiteralPath $p).ProviderPath}}
    throw 'gcloud.cmd/gcloud.exe not found.'
}

function Find-PsqlApplication {
    $cmd=Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if($null-ne$cmd){return $cmd.Source}
    $fallback='C:\Program Files\PostgreSQL\18\bin\psql.exe'
    if(Test-Path -LiteralPath $fallback -PathType Leaf){return $fallback}
    throw 'psql.exe not found.'
}

function Invoke-Gcloud {
    param([string]$Gcloud,[string[]]$Arguments,[switch]$AllowNonzero)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdoutLines=@(& $Gcloud @Arguments 2>$err)
        $code=$LASTEXITCODE
        $rawStderr=$null
        if(Test-Path -LiteralPath $err){$rawStderr=Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue}
        $stdoutText=[string](($stdoutLines|ForEach-Object{[string]$_})-join[Environment]::NewLine)
        $stderrText=if($null-eq$rawStderr){''}else{[string]$rawStderr}
        if($code-ne0 -and -not$AllowNonzero){throw ('gcloud failed (exit '+$code+'): '+($Arguments-join' ')+'`n'+$stderrText)}
        [pscustomobject]@{ExitCode=$code;Stdout=$stdoutText.Trim();Stderr=$stderrText.Trim()}
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}

function Invoke-PsqlCsv {
    param([string]$Psql,[string]$Query)
    $q=$Query.Trim();while($q.EndsWith(';')){$q=$q.Substring(0,$q.Length-1).TrimEnd()}
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdout=@(& $Psql -X -w -h $PgHost -p $PgPort -U $PgUser -d $DatabaseName -A -t -q -v ON_ERROR_STOP=1 -c "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);" 2>$err)
        $code=$LASTEXITCODE
        $stderr=if(Test-Path -LiteralPath $err){[string](Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)}else{''}
        if($code-ne0){throw "psql failed (exit $code): $stderr"}
        return (($stdout|ForEach-Object{[string]$_})-join[Environment]::NewLine).Trim()
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}

function Csv {
    param([AllowNull()][object]$Value)
    $s=if($null-eq$Value){''}else{[string]$Value}
    if($s.Contains('"')){$s=$s.Replace('"','""')}
    if($s.Contains(',')-or$s.Contains('"')-or$s.Contains("`r")-or$s.Contains("`n")){return '"'+$s+'"'}
    $s
}

function Get-PropertyValue {
    param([object]$Object,[string[]]$Names)
    if($null-eq$Object){return $null}
    foreach($n in $Names){$p=$Object.PSObject.Properties[$n];if($null-ne$p){return $p.Value}}
    $null
}

function Convert-CloudJsonToMap {
    param([string]$Json,[string]$BucketUri)
    if([string]::IsNullOrWhiteSpace($Json)){return @{}}
    $parsed=$Json|ConvertFrom-Json
    $items=if($parsed -is [System.Array]){@($parsed)}else{@($parsed)}
    $map=@{}
    foreach($entry in $items){
        $o=$entry
        $metadata=Get-PropertyValue $entry @('metadata')
        $type=[string](Get-PropertyValue $entry @('type'))
        if($null-ne$metadata -and ($type-eq'cloud_object' -or [string]::IsNullOrWhiteSpace($type))){$o=$metadata}
        $url=[string](Get-PropertyValue $entry @('url'))
        if([string]::IsNullOrWhiteSpace($url)){$url=[string](Get-PropertyValue $o @('url'))}
        $name=[string](Get-PropertyValue $o @('name'))
        if([string]::IsNullOrWhiteSpace($url)){
            if([string]::IsNullOrWhiteSpace($name)){continue}
            $url=if($name.StartsWith('gs://',[StringComparison]::Ordinal)){$name}else{$BucketUri+'/'+$name.TrimStart('/')}
        }
        $prefixUri=$BucketUri+'/'
        $objectName=if($url.StartsWith($prefixUri,[StringComparison]::Ordinal)){$url.Substring($prefixUri.Length)}else{$url.TrimStart('/')}
        if($map.ContainsKey($objectName)){throw "Duplicate cloud listing: $objectName"}
        $map[$objectName]=$o
    }
    $map
}

function Get-CloudObjects {
    param([string]$Gcloud,[string]$RawUri,[string]$BucketUri)
    $r=Invoke-Gcloud -Gcloud $Gcloud -Arguments @('storage','ls','--recursive','--json',$RawUri) -AllowNonzero:$true
    if($r.ExitCode-ne0){
        if($r.Stderr -match '(?i)(not found|no urls matched|matched no objects)'){return @{}}
        throw ('Cloud listing failed: '+$r.Stderr)
    }
    Convert-CloudJsonToMap -Json $r.Stdout -BucketUri $BucketUri
}

function Assert-CloudSubsetMatchesManifest {
    param([hashtable]$CloudMap,[object[]]$Manifest,[switch]$RequireComplete)
    $manifestByName=@{};foreach($m in $Manifest){$manifestByName[[string]$m.gcs_object_name]=$m}
    foreach($name in $CloudMap.Keys){
        if(-not$manifestByName.ContainsKey($name)){throw "Unexpected cloud object in raw prefix: $name"}
        $m=$manifestByName[$name];$o=$CloudMap[$name]
        $size=[string](Get-PropertyValue $o @('size','sizeBytes'))
        $md5=[string](Get-PropertyValue $o @('md5Hash','md5_hash'))
        if([string]::IsNullOrWhiteSpace($size)-or[long]$size-ne[long]$m.size_bytes){throw "Existing cloud size mismatch: $name"}
        if([string]::IsNullOrWhiteSpace($md5)-or$md5-ne[string]$m.md5_base64){throw "Existing cloud MD5 mismatch: $name"}
    }
    if($RequireComplete -and $CloudMap.Count-ne$Manifest.Count){throw "Cloud object count mismatch: observed=$($CloudMap.Count) expected=$($Manifest.Count)"}
}

function Invoke-SelfTest {
    $old=$env:CLOUDSDK_CORE_PROJECT
    try{
        $env:CLOUDSDK_CORE_PROJECT='test-project'
        $r=Invoke-Gcloud -Gcloud $env:ComSpec -Arguments @('/d','/c','exit','7') -AllowNonzero:$true
        if($r.ExitCode-ne7){throw 'Explicit AllowNonzero binding regression failed.'}
        $direct='[{"name":"raw/a.zip","size":"3","md5Hash":"kAFQmDzST7DWlj99KOF/cg=="}]'
        $wrapped='[{"type":"cloud_object","metadata":{"name":"raw/b.zip","size":"3","md5Hash":"kAFQmDzST7DWlj99KOF/cg=="}}]'
        $m1=Convert-CloudJsonToMap -Json $direct -BucketUri 'gs://bucket'
        $m2=Convert-CloudJsonToMap -Json $wrapped -BucketUri 'gs://bucket'
        if(-not$m1.ContainsKey('raw/a.zip') -or -not$m2.ContainsKey('raw/b.zip')){throw 'Cloud JSON shape regression failed.'}
        $args=@('storage','buckets','describe','gs://bucket','--format=json')
        if(@($args|Where-Object{$_ -match '^--project'}).Count-ne0){throw 'Describe command contains project flag.'}
        if($env:CLOUDSDK_CORE_PROJECT-ne'test-project'){throw 'Core project environment override failed.'}
        Write-Host 'SELF-TEST: PASS'
    }finally{$env:CLOUDSDK_CORE_PROJECT=$old}
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

$oldPgPassword=$env:PGPASSWORD
$oldPgOptions=$env:PGOPTIONS
$oldCoreProject=$env:CLOUDSDK_CORE_PROJECT
$oldPcu=$env:CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED
$oldProcesses=$env:CLOUDSDK_STORAGE_PROCESS_COUNT
$oldThreads=$env:CLOUDSDK_STORAGE_THREAD_COUNT
$bstr=[IntPtr]::Zero

try{
    if(-not(Test-Path -LiteralPath $ResumeRunRoot -PathType Container)){throw "Resume run root missing: $ResumeRunRoot"}
    $ResumeRunRoot=(Resolve-Path -LiteralPath $ResumeRunRoot).ProviderPath
    if(-not(Test-Path -LiteralPath $ArchiveRoot -PathType Container)){throw "Archive root missing: $ArchiveRoot"}
    $ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $manifestPath=Join-Path $ResumeRunRoot 'source-object-manifest.csv'
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw "Resume manifest missing: $manifestPath"}

    $manifest=@(Import-Csv -LiteralPath $manifestPath -Encoding UTF8)
    if($manifest.Count-ne$ExpectedDownloaded){throw "Resume manifest row count mismatch: $($manifest.Count)"}
    $manifestSha=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $gcloud=Find-GcloudApplication
    $psql=Find-PsqlApplication
    $active=(Invoke-Gcloud -Gcloud $gcloud -Arguments @('auth','list','--filter=status:ACTIVE','--format=value(account)')).Stdout
    if([string]::IsNullOrWhiteSpace($active)){throw 'No active gcloud account. Run gcloud.cmd auth login first.'}

    if([string]::IsNullOrWhiteSpace($env:PGPASSWORD)){
        $secure=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    $env:PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=300000'
    $env:CLOUDSDK_CORE_PROJECT=$ProjectId
    $env:CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED='False'
    $env:CLOUDSDK_STORAGE_PROCESS_COUNT=[string]$ProcessCount
    $env:CLOUDSDK_STORAGE_THREAD_COUNT=[string]$ThreadCount

    $registryCsv=Invoke-PsqlCsv $psql @"
SELECT object_key,local_relative_path,observed_size_bytes,payload_sha256
FROM source_news.source_slots
WHERE contract_sha256='$ExpectedContractSha' AND status='downloaded'
ORDER BY archive_timestamp_utc,object_key
"@
    $registry=@($registryCsv|ConvertFrom-Csv)
    if($registry.Count-ne$ExpectedDownloaded){throw "Registry downloaded row count mismatch: $($registry.Count)"}
    $db=@{};foreach($r in $registry){if($db.ContainsKey([string]$r.object_key)){throw "Duplicate registry object_key: $($r.object_key)"};$db[[string]$r.object_key]=$r}

    $seen=@{};$checked=0
    foreach($m in $manifest){
        $key=[string]$m.object_key
        if($seen.ContainsKey($key)){throw "Duplicate manifest object_key: $key"};$seen[$key]=$true
        if(-not$db.ContainsKey($key)){throw "Manifest object not in registry: $key"}
        $r=$db[$key]
        if([string]$m.local_relative_path-ne[string]$r.local_relative_path){throw "Resume path mismatch: $key"}
        if([long]$m.size_bytes-ne[long]$r.observed_size_bytes){throw "Resume size mismatch: $key"}
        if(([string]$m.sha256_hex).ToLowerInvariant()-ne([string]$r.payload_sha256).ToLowerInvariant()){throw "Resume SHA-256 mismatch: $key"}
        if(([string]$m.sha256_hex)-notmatch '^[0-9a-fA-F]{64}$'){throw "Invalid manifest SHA-256: $key"}
        if([string]::IsNullOrWhiteSpace([string]$m.md5_base64)){throw "Missing manifest MD5: $key"}
        $relative=[string]$m.local_relative_path
        $localPath=Join-Path $ArchiveRoot ($relative.Replace('/','\'))
        if(-not(Test-Path -LiteralPath $localPath -PathType Leaf)){throw "Local source missing since validation: $relative"}
        if([long](Get-Item -LiteralPath $localPath).Length-ne[long]$m.size_bytes){throw "Local source size changed since validation: $relative"}
        $expectedName=$Prefix.Trim('/')+'/'+$relative.Replace('\','/').TrimStart('/')
        if([string]$m.gcs_object_name-ne$expectedName){throw "Manifest GCS object name mismatch: $key"}
        $checked++
    }
    Write-Host "Resume manifest reconciliation: PASS | rows=$checked | manifest_sha256=$manifestSha"

    $bucketUri='gs://'+$BucketName
    $rawUri=$bucketUri+'/'+$Prefix.Trim('/')+'/'
    $describe=Invoke-Gcloud -Gcloud $gcloud -Arguments @('storage','buckets','describe',$bucketUri,'--format=json') -AllowNonzero:$true
    if($describe.ExitCode-ne0){
        if($describe.Stderr -notmatch '(?i)(not found|404)'){throw ('Bucket probe failed unexpectedly: '+$describe.Stderr)}
        Write-Host "Creating GCS bucket: $bucketUri"
        Invoke-Gcloud -Gcloud $gcloud -Arguments @('storage','buckets','create',$bucketUri,('--location='+$BucketLocation),('--default-storage-class='+$StorageClass),'--uniform-bucket-level-access')|Out-Null
        $verifyBucket=Invoke-Gcloud -Gcloud $gcloud -Arguments @('storage','buckets','describe',$bucketUri,'--format=json')
        if([string]::IsNullOrWhiteSpace($verifyBucket.Stdout)){throw 'Created bucket could not be described.'}
    }else{
        $bi=$describe.Stdout|ConvertFrom-Json
        $loc=[string](Get-PropertyValue $bi @('location'))
        if(-not[string]::IsNullOrWhiteSpace($loc)-and$loc.ToUpperInvariant()-ne$BucketLocation.ToUpperInvariant()){throw "Existing bucket location mismatch: $loc"}
    }

    $pre=Get-CloudObjects -Gcloud $gcloud -RawUri $rawUri -BucketUri $bucketUri
    Assert-CloudSubsetMatchesManifest -CloudMap $pre -Manifest $manifest
    Write-Host "Existing matching raw objects before resume: $($pre.Count)"

    Write-Host "Resuming upload to $rawUri"
    Invoke-Gcloud -Gcloud $gcloud -Arguments @('storage','rsync','--recursive',$ArchiveRoot,$rawUri)|Out-Null

    Write-Host 'Reconciling final cloud corpus...'
    $cloud=Get-CloudObjects -Gcloud $gcloud -RawUri $rawUri -BucketUri $bucketUri
    Assert-CloudSubsetMatchesManifest -CloudMap $cloud -Manifest $manifest -RequireComplete

    $reconPath=Join-Path $ResumeRunRoot 'cloud-reconciliation.csv'
    $rw=New-Object System.IO.StreamWriter -ArgumentList $reconPath,$false,$Utf8NoBom
    try{
        $rw.WriteLine('gcs_object_name,expected_size_bytes,observed_size_bytes,expected_md5_base64,observed_md5_base64,status')
        foreach($m in $manifest){
            $o=$cloud[[string]$m.gcs_object_name]
            $size=[string](Get-PropertyValue $o @('size','sizeBytes'))
            $md5=[string](Get-PropertyValue $o @('md5Hash','md5_hash'))
            $rw.WriteLine((@($m.gcs_object_name,$m.size_bytes,$size,$m.md5_base64,$md5,'PASS')|ForEach-Object{Csv $_})-join',')
        }
    }finally{$rw.Dispose()}

    $summaryPath=Join-Path $ResumeRunRoot 'gcs-archive-summary.json'
    $summary=[ordered]@{
        run_id=(Split-Path -Leaf $ResumeRunRoot)
        resumed_utc=(Get-Date).ToUniversalTime().ToString('o')
        project_id=$ProjectId
        account=$active
        bucket=$BucketName
        raw_prefix=$Prefix.Trim('/')
        raw_object_count=$cloud.Count
        expected_downloaded_objects=$ExpectedDownloaded
        provider_missing_slots=$ExpectedProviderMissing
        source_manifest_sha256=$manifestSha
        source_manifest_rows=$manifest.Count
        cloud_reconciliation_sha256=(Get-FileHash -LiteralPath $reconPath -Algorithm SHA256).Hash.ToLowerInvariant()
        cloud_reconciliation_rows=$manifest.Count
        checks=[ordered]@{
            'CFA-GCS-R01'='PASS'
            'CFA-GCS-R02'='PASS'
            'CFA-GCS-R03'='PASS'
            'CFA-GCS-R04'='PASS'
            'CFA-GCS-R05'='BLOCKED'
        }
        local_deletion_authorized=$false
    }
    [System.IO.File]::WriteAllText($summaryPath,(($summary|ConvertTo-Json -Depth 8)+[Environment]::NewLine),$Utf8NoBom)

    $manifestUri=$bucketUri+'/manifests/gdelt-gkg-q2-2025/'+(Split-Path -Leaf $ResumeRunRoot)+'/'
    Invoke-Gcloud -Gcloud $gcloud -Arguments @('storage','cp',$manifestPath,$reconPath,$summaryPath,$manifestUri)|Out-Null

    Write-Host ''
    Write-Host 'CFA GDELT GCS ARCHIVE RESUME: PASS'
    Write-Host ('Raw cloud objects      : '+$cloud.Count)
    Write-Host 'Remote mismatches      : 0'
    Write-Host ('Source manifest        : '+$manifestPath)
    Write-Host ('Cloud reconciliation   : '+$reconPath)
    Write-Host ('Summary                : '+$summaryPath)
    Write-Host ('Cloud manifest prefix  : '+$manifestUri)
    Write-Host 'LOCAL SOURCE DELETION: BLOCKED pending direct review of this PASS receipt.'
    exit 0
}catch{
    Write-Host 'CFA GDELT GCS ARCHIVE RESUME: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    $env:PGPASSWORD=$oldPgPassword
    $env:PGOPTIONS=$oldPgOptions
    $env:CLOUDSDK_CORE_PROJECT=$oldCoreProject
    $env:CLOUDSDK_STORAGE_PARALLEL_COMPOSITE_UPLOAD_ENABLED=$oldPcu
    $env:CLOUDSDK_STORAGE_PROCESS_COUNT=$oldProcesses
    $env:CLOUDSDK_STORAGE_THREAD_COUNT=$oldThreads
}
