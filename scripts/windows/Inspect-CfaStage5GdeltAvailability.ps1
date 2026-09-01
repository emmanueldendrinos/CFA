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
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedContractSha='11f3d81f61533efd0b1984c8f84da3e68128c05142923f4e7a62a76c8de9002e'
$ExpectedSlots=8736
$ExpectedDownloaded=7163
$ExpectedProviderMissing=1573
$ExpectedCadenceMinutes=15
$BucketName='data.gdeltproject.org'
$GcsListBase='https://storage.googleapis.com/storage/v1/b/data.gdeltproject.org/o'

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

function New-MetadataIndex {
    return New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
}

function Add-MetadataItem {
    param([object]$Index,[object]$Item)
    $name=[string]$Item.name
    if([string]::IsNullOrWhiteSpace($name)){throw 'Provider metadata item has blank name.'}
    if($Index.ContainsKey($name)){throw "Duplicate provider metadata object name: $name"}
    $Index.Add($name,$Item)
}

function Invoke-GcsListPrefix {
    param([string]$Prefix,[object]$Index)
    $pageToken=$null
    [int]$pages=0
    do {
        $uri=$GcsListBase+'?prefix='+[uri]::EscapeDataString($Prefix)+'&maxResults=1000&fields='+[uri]::EscapeDataString('nextPageToken,items(name,timeCreated,updated,generation,size,md5Hash)')
        if(-not[string]::IsNullOrWhiteSpace([string]$pageToken)){$uri+='&pageToken='+[uri]::EscapeDataString([string]$pageToken)}
        $pages++
        try {
            $response=Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $HttpTimeoutSeconds -ErrorAction Stop
        }
        catch { throw "Provider metadata list failed for prefix $Prefix page ${pages}: $($_.Exception.Message)" }
        foreach($item in @($response.items)){Add-MetadataItem $Index $item}
        $pageToken=if($null-ne$response.PSObject.Properties['nextPageToken']){[string]$response.nextPageToken}else{$null}
    } while(-not[string]::IsNullOrWhiteSpace([string]$pageToken))
    return $pages
}

function Invoke-SelfTest {
    $idx=New-MetadataIndex
    Add-MetadataItem $idx ([pscustomobject]@{name='20250401000000.gkg.csv.zip';timeCreated='2025-04-01T00:00:08.000Z';updated='2025-04-01T00:00:08.000Z';generation='1';size='123';md5Hash='abc='})
    if($idx.Count-ne1-or-not$idx.ContainsKey('20250401000000.gkg.csv.zip')){throw 'Metadata index self-test failed.'}
    $created=Parse-Utc $idx['20250401000000.gkg.csv.zip'].timeCreated 'selftest'
    $slot=[datetimeoffset]::Parse('2025-04-01T00:00:00Z',$Invariant)
    $lag=[long][math]::Round(($created-$slot).TotalSeconds)
    if($lag-ne8){throw 'Provider creation-lag self-test failed.'}
    $name='20250401000000.gkg.csv.zip'
    if($name-notmatch'^\d{14}\.gkg\.csv\.zip$'){throw 'Object-name self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

$oldPassword=$env:PGPASSWORD
$oldPgOptions=$env:PGOPTIONS
$bstr=[IntPtr]::Zero
try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage5-gdelt-availability'}
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
       status,http_status,observed_size_bytes,payload_sha256,provider_md5_base64,last_attempt_at_utc
FROM source_news.source_slots
WHERE contract_sha256='$ExpectedContractSha'
ORDER BY archive_timestamp_utc
"@
    $slots=@($slotCsv|ConvertFrom-Csv)
    if($slots.Count-ne$ExpectedSlots){throw "Frozen source slot count changed: $($slots.Count)."}
    $downloaded=@($slots|Where-Object{[string]$_.status-eq'downloaded'})
    $missing=@($slots|Where-Object{[string]$_.status-eq'provider_missing'})
    if($downloaded.Count-ne$ExpectedDownloaded-or$missing.Count-ne$ExpectedProviderMissing){throw "Frozen source status counts changed: downloaded=$($downloaded.Count) provider_missing=$($missing.Count)."}

    $prefixes=@($downloaded|ForEach-Object{([string]$_.object_key).Substring(0,8)}|Sort-Object -Unique)
    $metadata=New-MetadataIndex
    [int]$pageCount=0
    foreach($prefix in $prefixes){
        Write-Host "Provider metadata prefix: $prefix"
        $pageCount+=Invoke-GcsListPrefix -Prefix $prefix -Index $metadata
    }

    $rows=New-Object System.Collections.ArrayList
    [long]$metadataMissing=0;[long]$identityFailures=0;[long]$sizeFailures=0;[long]$md5Failures=0
    $creationLags=New-Object System.Collections.ArrayList
    $updateLags=New-Object System.Collections.ArrayList
    foreach($slot in $downloaded){
        $objectKey=[string]$slot.object_key
        if($objectKey-notmatch'^\d{14}$'){throw "Malformed frozen object key: $objectKey"}
        $name=$objectKey+'.gkg.csv.zip'
        if(-not$metadata.ContainsKey($name)){
            $metadataMissing++
            [void]$rows.Add([pscustomobject][ordered]@{object_key=$objectKey;object_name=$name;slot_key=$slot.slot_key;metadata_status='MISSING';time_created_utc=$null;updated_utc=$null;creation_lag_seconds=$null;updated_lag_seconds=$null;generation=$null;provider_size_bytes=$null;frozen_size_bytes=$slot.observed_size_bytes;size_match=$false;provider_md5_base64=$null;frozen_provider_md5_base64=$slot.provider_md5_base64;md5_match=$false})
            continue
        }
        $item=$metadata[$name]
        if([string]$item.name-ne$name){$identityFailures++}
        $slotTime=[datetimeoffset]::ParseExact([string]$slot.slot_key,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
        $created=Parse-Utc $item.timeCreated $name
        $updated=Parse-Utc $item.updated $name
        $createLag=[long][math]::Round(($created-$slotTime).TotalSeconds)
        $updateLag=[long][math]::Round(($updated-$slotTime).TotalSeconds)
        [void]$creationLags.Add($createLag);[void]$updateLags.Add($updateLag)
        $sizeMatch=([long]$item.size-eq[long]$slot.observed_size_bytes)
        if(-not$sizeMatch){$sizeFailures++}
        $frozenMd5=[string]$slot.provider_md5_base64
        $providerMd5=[string]$item.md5Hash
        $md5Match=if([string]::IsNullOrWhiteSpace($frozenMd5)){[string]::IsNullOrWhiteSpace($providerMd5)}else{$providerMd5-eq$frozenMd5}
        if(-not$md5Match){$md5Failures++}
        [void]$rows.Add([pscustomobject][ordered]@{
            object_key=$objectKey;object_name=$name;slot_key=$slot.slot_key;metadata_status='FOUND';time_created_utc=$created.ToString('o');updated_utc=$updated.ToString('o');creation_lag_seconds=$createLag;updated_lag_seconds=$updateLag;generation=[string]$item.generation;provider_size_bytes=[string]$item.size;frozen_size_bytes=[string]$slot.observed_size_bytes;size_match=$sizeMatch;provider_md5_base64=$providerMd5;frozen_provider_md5_base64=$frozenMd5;md5_match=$md5Match
        })
    }

    $metadataPath=Join-Path $runDir 'stage5-gdelt-provider-object-metadata.csv'
    @($rows.ToArray())|Export-Csv -LiteralPath $metadataPath -NoTypeInformation -Encoding UTF8

    $creationArray=@($creationLags.ToArray()|ForEach-Object{[long]$_})
    $updateArray=@($updateLags.ToArray()|ForEach-Object{[long]$_})
    $minCreate=if($creationArray.Count-gt0){[long](@($creationArray|Measure-Object -Minimum).Minimum)}else{$null}
    $maxCreate=if($creationArray.Count-gt0){[long](@($creationArray|Measure-Object -Maximum).Maximum)}else{$null}
    $minUpdate=if($updateArray.Count-gt0){[long](@($updateArray|Measure-Object -Minimum).Minimum)}else{$null}
    $maxUpdate=if($updateArray.Count-gt0){[long](@($updateArray|Measure-Object -Maximum).Maximum)}else{$null}

    $mechanicalPass=($metadataMissing-eq0-and$identityFailures-eq0-and$sizeFailures-eq0-and$md5Failures-eq0-and$creationArray.Count-eq$ExpectedDownloaded)
    $availabilityDecision='UNVERIFIED'
    $availabilityReason='Provider timeCreated/updated metadata establishes object creation/update timestamps but does not by itself prove historical public-readability timing. A separate explicit CFA availability decision is still required before news predictors may be approved.'

    $summary=[ordered]@{
        status=if($mechanicalPass){'PASS'}else{'FAIL'}
        stage='CFA_STAGE_5'
        source_contract_sha256=$ExpectedContractSha
        provider=[ordered]@{bucket=$BucketName;api=$GcsListBase;prefix_count=$prefixes.Count;api_pages=$pageCount}
        frozen=[ordered]@{nominal_slots=$slots.Count;downloaded_slots=$downloaded.Count;provider_missing_slots=$missing.Count}
        reconciliation=[ordered]@{provider_metadata_found=($downloaded.Count-$metadataMissing);provider_metadata_missing=$metadataMissing;identity_failures=$identityFailures;size_mismatches=$sizeFailures;md5_mismatches=$md5Failures}
        timing=[ordered]@{creation_lag_min_seconds=$minCreate;creation_lag_max_seconds=$maxCreate;updated_lag_min_seconds=$minUpdate;updated_lag_max_seconds=$maxUpdate}
        outputs=[ordered]@{provider_object_metadata_csv=$metadataPath}
        gate=[ordered]@{'CFA-S5-012'=if($mechanicalPass){'PASS'}else{'FAIL'};'CFA-S5-011'=$availabilityDecision;'CFA-S5-007'='BLOCKED'}
        availability_reason=$availabilityReason
    }
    $receiptPath=Join-Path $runDir 'stage5-gdelt-provider-availability.json'
    Write-Utf8NoBom $receiptPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    if(-not$mechanicalPass){throw "Provider metadata reconciliation failed: missing=$metadataMissing identity=$identityFailures size=$sizeFailures md5=$md5Failures"}

    Write-Host ''
    Write-Host 'CFA STAGE 5 GDELT PROVIDER METADATA INSPECTION: PASS'
    Write-Host "Frozen downloaded objects: $($downloaded.Count)"
    Write-Host "Provider metadata found: $($downloaded.Count-$metadataMissing)"
    Write-Host "Provider metadata pages: $pageCount"
    Write-Host "Size / MD5 mismatches: $sizeFailures / $md5Failures"
    Write-Host "Creation lag seconds min / max: $minCreate / $maxCreate"
    Write-Host "Updated lag seconds min / max: $minUpdate / $maxUpdate"
    Write-Host 'CFA-S5-012 provider object metadata reconciliation: PASS'
    Write-Host 'CFA-S5-011 historical information-availability semantics: UNVERIFIED'
    Write-Host 'CFA-S5-007 news factor definitions: BLOCKED'
    Write-Host "Metadata receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 GDELT PROVIDER METADATA INSPECTION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
finally {
    if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    if($null-eq$oldPassword){Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$oldPassword}
    if($null-eq$oldPgOptions){Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue}else{$env:PGOPTIONS=$oldPgOptions}
}
