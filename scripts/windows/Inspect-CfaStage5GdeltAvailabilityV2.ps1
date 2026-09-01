#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost='localhost',
    [ValidateRange(1,65535)][int]$PgPort=5432,
    [string]$PgUser='postgres',
    [string]$DatabaseName='cfa',
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [ValidateRange(30,900)][int]$StatementTimeoutSeconds=180,
    [ValidateRange(10,120)][int]$HttpTimeoutSeconds=60,
    [ValidateRange(1,64)][int]$HttpConcurrency=16,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedContractSha='11f3d81f61533efd0b1984c8f84da3e68128c05142923f4e7a62a76c8de9002e'
$ExpectedSlots=8736
$ExpectedDownloaded=7163
$ExpectedProviderMissing=1573
$BucketName='data.gdeltproject.org'
$GcsObjectMetadataBase='https://storage.googleapis.com/storage/v1/b/data.gdeltproject.org/o/'
$MetadataFields='name,timeCreated,updated,generation,size,md5Hash'

function Find-Psql {
    $cmd=Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if($null-ne$cmd){return $cmd.Source}
    $found=@(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue|Sort-Object FullName -Descending)
    if($found.Count-eq0){throw 'psql.exe could not be found.'}
    return $found[0].FullName
}

function Invoke-PsqlText {
    param([string]$PsqlExe,[string]$Database,[string]$Sql)
    $errFile=[IO.Path]::GetTempFileName()
    try {
        $stdout=@(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2>$errFile)
        $exitCode=$LASTEXITCODE
        $stderr=if(Test-Path -LiteralPath $errFile){((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)|ForEach-Object{[string]$_})-join[Environment]::NewLine}else{''}
        $text=($stdout|ForEach-Object{if($null-ne$_){[string]$_}})-join[Environment]::NewLine
        if($exitCode-ne0){throw "psql failed for database '$Database' (exit $exitCode).`n$stderr`n$text"}
        return $text
    }
    finally{Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue}
}

function Invoke-PsqlCsv {
    param([string]$PsqlExe,[string]$Database,[string]$Query)
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$Query`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Write-Utf8NoBom {
    param([string]$Path,[AllowNull()][string]$Content)
    if($null-eq$Content){$Content=''}
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Parse-Utc {
    param([object]$Value,[string]$Label)
    $text=([string]$Value).Trim()
    $dto=[datetimeoffset]::MinValue
    if(-not[datetimeoffset]::TryParse($text,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$dto)){throw "Malformed provider UTC timestamp for ${Label}: '$Value'"}
    return $dto.ToUniversalTime()
}

function Get-MetadataUri {
    param([string]$ObjectName)
    if($ObjectName-notmatch'^\d{14}\.gkg\.csv\.zip$'){throw "Malformed object name: $ObjectName"}
    return $GcsObjectMetadataBase+[uri]::EscapeDataString($ObjectName)+'?fields='+[uri]::EscapeDataString($MetadataFields)
}

function New-HttpClient {
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $handler=New-Object System.Net.Http.HttpClientHandler
    $client=New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout=[TimeSpan]::FromSeconds($HttpTimeoutSeconds)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('CFA-Stage5-GDELT-Availability-V2/1.0')
    return $client
}

function Invoke-MetadataBatch {
    param([System.Net.Http.HttpClient]$Client,[object[]]$Batch)
    $states=New-Object System.Collections.ArrayList
    foreach($slot in $Batch){
        $objectKey=[string]$slot.object_key
        $name=$objectKey+'.gkg.csv.zip'
        $uri=Get-MetadataUri $name
        $task=$Client.GetAsync($uri)
        [void]$states.Add([pscustomobject]@{slot=$slot;name=$name;uri=$uri;task=$task})
    }
    $tasks=@($states|ForEach-Object{$_.task})
    try{[System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks)}catch{}
    $results=New-Object System.Collections.ArrayList
    foreach($state in $states){
        $task=$state.task
        if($task.IsCanceled){[void]$results.Add([pscustomobject]@{slot=$state.slot;name=$state.name;status_code=0;metadata=$null;error='CANCELED'});continue}
        if($task.IsFaulted){[void]$results.Add([pscustomobject]@{slot=$state.slot;name=$state.name;status_code=0;metadata=$null;error=$task.Exception.GetBaseException().Message});continue}
        $response=$task.Result
        try{
            $status=[int]$response.StatusCode
            $body=$response.Content.ReadAsStringAsync().Result
            if($status-eq200){
                $metadata=$body|ConvertFrom-Json
                [void]$results.Add([pscustomobject]@{slot=$state.slot;name=$state.name;status_code=$status;metadata=$metadata;error=$null})
            }else{
                [void]$results.Add([pscustomobject]@{slot=$state.slot;name=$state.name;status_code=$status;metadata=$null;error=$body})
            }
        }
        finally{$response.Dispose()}
    }
    return @($results.ToArray())
}

function Invoke-SelfTest {
    $uri=Get-MetadataUri '20250401000000.gkg.csv.zip'
    if($uri-notmatch'20250401000000\.gkg\.csv\.zip'){throw 'Exact-object metadata URI self-test failed.'}
    if($uri-match'prefix='){throw 'Bucket-list prefix unexpectedly present.'}
    $created=Parse-Utc '2025-04-01T00:00:08.000Z' 'selftest'
    $slot=[datetimeoffset]::Parse('2025-04-01T00:00:00Z',$Invariant)
    if([long][math]::Round(($created-$slot).TotalSeconds)-ne8){throw 'Creation-lag self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

$oldPassword=$env:PGPASSWORD
$oldPgOptions=$env:PGOPTIONS
$bstr=[IntPtr]::Zero
$client=$null
try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage5-gdelt-availability-v2'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null

    $contractText=Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage5-factor-contract.md') -Raw
    if($contractText-notmatch'CFA-S5-010[^\r\n]*PASS'){throw 'CFA-S5-010 is not PASS in the current contract.'}
    if($contractText-notmatch'CFA-S5-011[^\r\n]*UNVERIFIED'){throw 'CFA-S5-011 is not UNVERIFIED in the current contract.'}

    $psql=Find-Psql
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    $securePassword=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000) -c TimeZone=UTC"
    $version=Invoke-PsqlText -PsqlExe $psql -Database $DatabaseName -Sql 'SHOW server_version;'
    Write-Host "PostgreSQL: $version"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $slotCsv=Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT object_key,
       to_char(archive_timestamp_utc AT TIME ZONE 'UTC','YYYYMMDDHH24MISS') AS slot_key,
       status,http_status,observed_size_bytes,payload_sha256,provider_md5_base64
FROM source_news.source_slots
WHERE contract_sha256='$ExpectedContractSha'
ORDER BY archive_timestamp_utc
"@
    $slots=@($slotCsv|ConvertFrom-Csv)
    if($slots.Count-ne$ExpectedSlots){throw "Frozen source slot count changed: $($slots.Count)."}
    $downloaded=@($slots|Where-Object{[string]$_.status-eq'downloaded'})
    $missing=@($slots|Where-Object{[string]$_.status-eq'provider_missing'})
    if($downloaded.Count-ne$ExpectedDownloaded-or$missing.Count-ne$ExpectedProviderMissing){throw "Frozen source status counts changed: downloaded=$($downloaded.Count) provider_missing=$($missing.Count)."}

    $client=New-HttpClient
    $probeSlot=$downloaded[0]
    $probe=@(Invoke-MetadataBatch -Client $client -Batch @($probeSlot))
    if($probe.Count-ne1){throw 'Exact-object metadata probe did not return one result.'}
    if([int]$probe[0].status_code-eq401-or[int]$probe[0].status_code-eq403){throw "Exact-object provider metadata is not anonymously readable (HTTP $($probe[0].status_code)). Bucket-list denial and exact-object metadata denial are distinct; CFA-S5-011 remains UNVERIFIED."}
    if([int]$probe[0].status_code-ne200){throw "Exact-object provider metadata probe failed for $($probe[0].name): HTTP $($probe[0].status_code) $($probe[0].error)"}
    Write-Host 'Exact-object provider metadata probe: PASS'

    $rows=New-Object System.Collections.ArrayList
    $creationLags=New-Object System.Collections.ArrayList
    $updateLags=New-Object System.Collections.ArrayList
    [long]$metadataMissing=0;[long]$httpFailures=0;[long]$identityFailures=0;[long]$sizeFailures=0;[long]$md5Comparable=0;[long]$md5Failures=0
    [long]$negativeCreationLag=0;[long]$creationLagGt15m=0;[long]$creationLagGt1h=0;[long]$creationLagGt24h=0

    for($offset=0;$offset-lt$downloaded.Count;$offset+=$HttpConcurrency){
        $end=[math]::Min($offset+$HttpConcurrency-1,$downloaded.Count-1)
        $batch=@($downloaded[$offset..$end])
        $batchResults=@(Invoke-MetadataBatch -Client $client -Batch $batch)
        foreach($result in $batchResults){
            $slot=$result.slot;$objectKey=[string]$slot.object_key;$name=$result.name
            if([int]$result.status_code-ne200){
                if([int]$result.status_code-eq404){$metadataMissing++}else{$httpFailures++}
                [void]$rows.Add([pscustomobject][ordered]@{object_key=$objectKey;object_name=$name;slot_key=$slot.slot_key;http_status=$result.status_code;metadata_status='FAILED';time_created_utc=$null;updated_utc=$null;creation_lag_seconds=$null;updated_lag_seconds=$null;generation=$null;provider_size_bytes=$null;frozen_size_bytes=$slot.observed_size_bytes;size_match=$false;provider_md5_base64=$null;frozen_provider_md5_base64=$slot.provider_md5_base64;md5_comparable=$false;md5_match=$false})
                continue
            }
            $item=$result.metadata
            if([string]$item.name-ne$name){$identityFailures++}
            $slotTime=[datetimeoffset]::ParseExact([string]$slot.slot_key,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
            $created=Parse-Utc $item.timeCreated $name
            $updated=Parse-Utc $item.updated $name
            $createLag=[long][math]::Round(($created-$slotTime).TotalSeconds)
            $updateLag=[long][math]::Round(($updated-$slotTime).TotalSeconds)
            [void]$creationLags.Add($createLag);[void]$updateLags.Add($updateLag)
            if($createLag-lt0){$negativeCreationLag++}
            if($createLag-gt900){$creationLagGt15m++}
            if($createLag-gt3600){$creationLagGt1h++}
            if($createLag-gt86400){$creationLagGt24h++}
            $sizeMatch=([long]$item.size-eq[long]$slot.observed_size_bytes)
            if(-not$sizeMatch){$sizeFailures++}
            $frozenMd5=([string]$slot.provider_md5_base64).Trim();$providerMd5=([string]$item.md5Hash).Trim()
            $md5Comparable=(-not[string]::IsNullOrWhiteSpace($frozenMd5))
            $md5Match=$false
            if($md5Comparable){$md5Comparable++;$md5Match=($providerMd5-eq$frozenMd5);if(-not$md5Match){$md5Failures++}}
            [void]$rows.Add([pscustomobject][ordered]@{object_key=$objectKey;object_name=$name;slot_key=$slot.slot_key;http_status=200;metadata_status='FOUND';time_created_utc=$created.ToString('o');updated_utc=$updated.ToString('o');creation_lag_seconds=$createLag;updated_lag_seconds=$updateLag;generation=[string]$item.generation;provider_size_bytes=[string]$item.size;frozen_size_bytes=[string]$slot.observed_size_bytes;size_match=$sizeMatch;provider_md5_base64=$providerMd5;frozen_provider_md5_base64=$frozenMd5;md5_comparable=$md5Comparable;md5_match=$md5Match})
        }
        $done=$end+1
        if($done-eq$downloaded.Count-or($done%512)-lt$HttpConcurrency){Write-Host "Exact-object provider metadata: $done / $($downloaded.Count)"}
    }

    $metadataPath=Join-Path $runDir 'stage5-gdelt-provider-object-metadata-v2.csv'
    @($rows.ToArray())|Export-Csv -LiteralPath $metadataPath -NoTypeInformation -Encoding UTF8
    $creationArray=@($creationLags.ToArray()|ForEach-Object{[long]$_})
    $updateArray=@($updateLags.ToArray()|ForEach-Object{[long]$_})
    $minCreate=if($creationArray.Count-gt0){[long](@($creationArray|Measure-Object -Minimum).Minimum)}else{$null}
    $maxCreate=if($creationArray.Count-gt0){[long](@($creationArray|Measure-Object -Maximum).Maximum)}else{$null}
    $minUpdate=if($updateArray.Count-gt0){[long](@($updateArray|Measure-Object -Minimum).Minimum)}else{$null}
    $maxUpdate=if($updateArray.Count-gt0){[long](@($updateArray|Measure-Object -Maximum).Maximum)}else{$null}

    $mechanicalPass=($metadataMissing-eq0-and$httpFailures-eq0-and$identityFailures-eq0-and$sizeFailures-eq0-and$md5Failures-eq0-and$creationArray.Count-eq$ExpectedDownloaded)
    $availabilityDecision='UNVERIFIED'
    $availabilityReason='Exact-object provider timeCreated/updated metadata establishes object creation/update timestamps but does not by itself prove historical public-readability timing or historical ACL state. CFA-S5-011 therefore remains UNVERIFIED pending an explicit evidence-backed availability rule.'
    $summary=[ordered]@{
        status=if($mechanicalPass){'PASS'}else{'FAIL'}
        stage='CFA_STAGE_5'
        implementation='V2_EXACT_OBJECT_METADATA_NO_BUCKET_LIST'
        source_contract_sha256=$ExpectedContractSha
        provider=[ordered]@{bucket=$BucketName;api=$GcsObjectMetadataBase;access_mode='exact_object_metadata';http_concurrency=$HttpConcurrency}
        frozen=[ordered]@{nominal_slots=$slots.Count;downloaded_slots=$downloaded.Count;provider_missing_slots=$missing.Count}
        reconciliation=[ordered]@{provider_metadata_found=$creationArray.Count;provider_metadata_missing=$metadataMissing;http_failures=$httpFailures;identity_failures=$identityFailures;size_mismatches=$sizeFailures;md5_comparable=$md5Comparable;md5_mismatches=$md5Failures}
        timing=[ordered]@{creation_lag_min_seconds=$minCreate;creation_lag_max_seconds=$maxCreate;updated_lag_min_seconds=$minUpdate;updated_lag_max_seconds=$maxUpdate;negative_creation_lags=$negativeCreationLag;creation_lag_gt_15m=$creationLagGt15m;creation_lag_gt_1h=$creationLagGt1h;creation_lag_gt_24h=$creationLagGt24h}
        outputs=[ordered]@{provider_object_metadata_csv=$metadataPath}
        gates=[ordered]@{'CFA-S5-012'=if($mechanicalPass){'PASS'}else{'FAIL'};'CFA-S5-011'=$availabilityDecision;'CFA-S5-007'='BLOCKED'}
        availability_reason=$availabilityReason
    }
    $receiptPath=Join-Path $runDir 'stage5-gdelt-provider-availability-v2.json'
    Write-Utf8NoBom $receiptPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
    if(-not$mechanicalPass){throw "Exact-object metadata reconciliation failed: missing=$metadataMissing http=$httpFailures identity=$identityFailures size=$sizeFailures md5=$md5Failures"}

    Write-Host ''
    Write-Host 'CFA STAGE 5 GDELT PROVIDER METADATA V2: PASS'
    Write-Host "Frozen downloaded objects: $($downloaded.Count)"
    Write-Host "Exact-object metadata found: $($creationArray.Count)"
    Write-Host "HTTP / size / comparable-MD5 mismatches: $httpFailures / $sizeFailures / $md5Failures"
    Write-Host "Creation lag seconds min / max: $minCreate / $maxCreate"
    Write-Host "Updated lag seconds min / max: $minUpdate / $maxUpdate"
    Write-Host "Creation lag >15m / >1h / >24h: $creationLagGt15m / $creationLagGt1h / $creationLagGt24h"
    Write-Host 'CFA-S5-012 provider object metadata reconciliation: PASS'
    Write-Host 'CFA-S5-011 historical information-availability semantics: UNVERIFIED'
    Write-Host 'CFA-S5-007 news factor definitions: BLOCKED'
    Write-Host "Metadata receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 GDELT PROVIDER METADATA V2: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
finally {
    if($null-ne$client){$client.Dispose()}
    if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    if($null-eq$oldPassword){Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$oldPassword}
    if($null-eq$oldPgOptions){Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue}else{$env:PGOPTIONS=$oldPgOptions}
}
