#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$DatabaseName = 'cfa',
    [ValidateRange(1,100)][int]$BatchSize = 20,
    [ValidateRange(1,20)][int]$MaxTotalAttempts = 5,
    [ValidateRange(1,10)][int]$HttpAttemptsPerObject = 3,
    [ValidateRange(15,900)][int]$HttpTimeoutSeconds = 180,
    [ValidateRange(0,1000000)][int]$MaxObjects = 0,
    [string]$ArchiveRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

$ContractStartUtc = [datetimeoffset]::Parse('2025-04-01T00:00:00+00:00')
$ContractEndExclusiveUtc = [datetimeoffset]::Parse('2025-07-01T00:00:00+00:00')
$CadenceMinutes = 15
$SourceProduct = 'GDELT 2.0 native/base GKG fifteen-minute update archives'
$UrlTemplate = 'https://storage.googleapis.com/data.gdeltproject.org/gdeltv2/{object_key}.gkg.csv.zip'

function Find-Psql {
    $cmd = Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    $found = @(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    if ($found.Count -eq 0) { throw 'psql.exe could not be found.' }
    return $found[0].FullName
}

function Invoke-PsqlText {
    param([string]$PsqlExe,[string]$Database,[string]$Sql)
    $errFile = [System.IO.Path]::GetTempFileName()
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
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
        return $text.Trim()
    }
    finally {
        $ErrorActionPreference = $oldPreference
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Normalize-SqlSubquery {
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { throw 'SQL subquery is empty.' }
    $q = $Query.Trim()
    while ($q.EndsWith(';')) { $q = $q.Substring(0,$q.Length-1).TrimEnd() }
    if ([string]::IsNullOrWhiteSpace($q)) { throw 'SQL subquery contains no statement.' }
    return $q
}

function Invoke-PsqlCsv {
    param([string]$PsqlExe,[string]$Database,[string]$Query)
    $q = Normalize-SqlSubquery -Query $Query
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-ContractCanonicalText {
    return ($SourceProduct + '|' + $ContractStartUtc.ToString('o') + '|' + $ContractEndExclusiveUtc.ToString('o') + '|' + $CadenceMinutes + '|' + $UrlTemplate)
}
function Get-ContractSha256 { return Get-Sha256Text -Text (Get-ContractCanonicalText) }
function Get-NominalSlotCount { return [int](($ContractEndExclusiveUtc - $ContractStartUtc).TotalMinutes / $CadenceMinutes) }
function Get-ObjectKey { param([datetimeoffset]$Timestamp) return $Timestamp.UtcDateTime.ToString('yyyyMMddHHmmss',[Globalization.CultureInfo]::InvariantCulture) }
function Get-SecureUrl { param([string]$ObjectKey) return $UrlTemplate.Replace('{object_key}',$ObjectKey) }

function Sql-Literal {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 'NULL' }
    if ($Value -is [int] -or $Value -is [long]) { return [string]$Value }
    $text = [string]$Value
    if ([string]::IsNullOrEmpty($text)) { return 'NULL' }
    return "'" + $text.Replace("'","''") + "'"
}

function Convert-HexToBase64 {
    param([string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex) -or ($Hex.Length % 2) -ne 0) { return '' }
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i*2,2),16) }
    return [Convert]::ToBase64String($bytes)
}

function Get-ProviderMd5Base64 {
    param([System.Net.Http.HttpResponseMessage]$Response)
    try {
        foreach ($headerValue in @($Response.Headers.GetValues('x-goog-hash'))) {
            foreach ($part in ([string]$headerValue -split ',')) {
                $p = $part.Trim()
                if ($p.StartsWith('md5=',[StringComparison]::OrdinalIgnoreCase)) { return $p.Substring(4) }
            }
        }
    }
    catch { }
    if ($null -ne $Response.Content.Headers.ContentMD5) { return [Convert]::ToBase64String([byte[]]$Response.Content.Headers.ContentMD5) }
    return ''
}

function Test-ZipStructure {
    param([string]$Path)
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        if ($entries.Count -lt 1) { throw 'ZIP archive contains no file entries.' }
        return $entries.Count
    }
    finally { if ($null -ne $zip) { $zip.Dispose() } }
}

function Get-GitCommit {
    param([string]$RepoRoot)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $value = (& git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and ([string]$value) -match '^[0-9a-f]{40}$') { return [string]$value }
    }
    catch { }
    finally { $ErrorActionPreference = $oldPreference }
    return $null
}

function Get-ErrorCode {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return 'unknown_error' }
    return 'e_' + (Get-Sha256Text -Text $Message).Substring(0,20)
}

function Ensure-CfaDatabase {
    param([string]$PsqlExe)
    $exists = Invoke-PsqlText -PsqlExe $PsqlExe -Database 'postgres' -Sql ("SELECT count(*) FROM pg_database WHERE datname=" + (Sql-Literal $DatabaseName) + ';')
    if ([int]$exists -eq 0) {
        if ($DatabaseName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'DatabaseName contains unsupported characters.' }
        Write-Host "Creating PostgreSQL database: $DatabaseName"
        [void](Invoke-PsqlText -PsqlExe $PsqlExe -Database 'postgres' -Sql ("CREATE DATABASE " + $DatabaseName + " WITH TEMPLATE=template0 ENCODING='UTF8';"))
    }
}

function Ensure-SourceSchema {
    param([string]$PsqlExe,[string]$ContractSha,[string]$GitCommit)
    $slotCount = Get-NominalSlotCount
    $ddl = @"
CREATE SCHEMA IF NOT EXISTS source_news;
CREATE TABLE IF NOT EXISTS source_news.source_contracts (
  contract_sha256 text PRIMARY KEY CHECK (contract_sha256 ~ '^[0-9a-f]{64}$'),
  source_product text NOT NULL,
  interval_start_utc timestamptz NOT NULL,
  interval_end_exclusive_utc timestamptz NOT NULL,
  cadence_minutes integer NOT NULL CHECK (cadence_minutes > 0),
  nominal_slot_count integer NOT NULL CHECK (nominal_slot_count > 0),
  url_template text NOT NULL,
  created_at_utc timestamptz NOT NULL DEFAULT clock_timestamp(),
  created_by_git_commit text NULL
);
CREATE TABLE IF NOT EXISTS source_news.source_slots (
  contract_sha256 text NOT NULL REFERENCES source_news.source_contracts(contract_sha256),
  object_key text NOT NULL CHECK (object_key ~ '^[0-9]{14}$'),
  archive_timestamp_utc timestamptz NOT NULL,
  secure_url text NOT NULL,
  status text NOT NULL CHECK (status IN ('pending','downloaded','provider_missing','network_failed','integrity_failed')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  http_status integer NULL,
  expected_content_length bigint NULL,
  observed_size_bytes bigint NULL,
  payload_sha256 text NULL,
  provider_md5_base64 text NULL,
  observed_md5_base64 text NULL,
  provider_md5_status text NULL CHECK (provider_md5_status IS NULL OR provider_md5_status IN ('PASS','FAIL','NOT_AVAILABLE')),
  local_relative_path text NULL,
  zip_entry_count integer NULL,
  last_attempt_at_utc timestamptz NULL,
  error_code text NULL,
  PRIMARY KEY (contract_sha256,object_key),
  UNIQUE (contract_sha256,archive_timestamp_utc)
);
CREATE INDEX IF NOT EXISTS ix_source_slots_status ON source_news.source_slots(contract_sha256,status,attempt_count,archive_timestamp_utc);
CREATE TABLE IF NOT EXISTS source_news.acquisition_runs (
  run_id uuid PRIMARY KEY,
  contract_sha256 text NOT NULL REFERENCES source_news.source_contracts(contract_sha256),
  started_at_utc timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at_utc timestamptz NULL,
  status text NOT NULL CHECK (status IN ('running','completed','blocked','partial','failed')),
  archive_root text NOT NULL,
  git_commit text NULL,
  processed_attempts integer NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS source_news.run_events (
  event_id bigserial PRIMARY KEY,
  run_id uuid NOT NULL REFERENCES source_news.acquisition_runs(run_id),
  object_key text NULL,
  event_at_utc timestamptz NOT NULL DEFAULT clock_timestamp(),
  event_type text NOT NULL,
  http_status integer NULL,
  error_code text NULL
);
INSERT INTO source_news.source_contracts(contract_sha256,source_product,interval_start_utc,interval_end_exclusive_utc,cadence_minutes,nominal_slot_count,url_template,created_by_git_commit)
VALUES ($(Sql-Literal $ContractSha),$(Sql-Literal $SourceProduct),TIMESTAMPTZ '2025-04-01 00:00:00+00',TIMESTAMPTZ '2025-07-01 00:00:00+00',$CadenceMinutes,$slotCount,$(Sql-Literal $UrlTemplate),$(Sql-Literal $GitCommit))
ON CONFLICT (contract_sha256) DO UPDATE SET
  source_product=EXCLUDED.source_product,
  interval_start_utc=EXCLUDED.interval_start_utc,
  interval_end_exclusive_utc=EXCLUDED.interval_end_exclusive_utc,
  cadence_minutes=EXCLUDED.cadence_minutes,
  nominal_slot_count=EXCLUDED.nominal_slot_count,
  url_template=EXCLUDED.url_template;
INSERT INTO source_news.source_slots(contract_sha256,object_key,archive_timestamp_utc,secure_url,status)
SELECT $(Sql-Literal $ContractSha),to_char(gs AT TIME ZONE 'UTC','YYYYMMDDHH24MISS'),gs,
       replace($(Sql-Literal $UrlTemplate),'{object_key}',to_char(gs AT TIME ZONE 'UTC','YYYYMMDDHH24MISS')),'pending'
FROM generate_series(TIMESTAMPTZ '2025-04-01 00:00:00+00',TIMESTAMPTZ '2025-07-01 00:00:00+00' - interval '15 minutes',interval '15 minutes') gs
ON CONFLICT (contract_sha256,object_key) DO NOTHING;
"@
    [void](Invoke-PsqlText -PsqlExe $PsqlExe -Database $DatabaseName -Sql $ddl)
    $observed = Invoke-PsqlText -PsqlExe $PsqlExe -Database $DatabaseName -Sql ("SELECT count(*) FROM source_news.source_slots WHERE contract_sha256=" + (Sql-Literal $ContractSha) + ';')
    if ([int]$observed -ne $slotCount) { throw "Source slot cardinality mismatch after initialization: observed $observed expected $slotCount." }
}

function Get-UnresolvedBatch {
    param([string]$PsqlExe,[string]$ContractSha)
    $csv = Invoke-PsqlCsv -PsqlExe $PsqlExe -Database $DatabaseName -Query @"
SELECT object_key,secure_url,attempt_count
FROM source_news.source_slots
WHERE contract_sha256=$(Sql-Literal $ContractSha)
  AND status IN ('pending','network_failed','integrity_failed')
  AND attempt_count < $MaxTotalAttempts
ORDER BY attempt_count,archive_timestamp_utc
LIMIT $BatchSize
"@
    if ([string]::IsNullOrWhiteSpace($csv)) { return @() }
    return @($csv | ConvertFrom-Csv)
}

function New-DownloadResult {
    param(
        [string]$ObjectKey,[string]$Status,[AllowNull()][object]$HttpStatus,
        [AllowNull()][object]$ExpectedLength,[AllowNull()][object]$ObservedSize,
        [AllowNull()][string]$Sha256,[AllowNull()][string]$ProviderMd5,
        [AllowNull()][string]$ObservedMd5,[AllowNull()][string]$Md5Status,
        [AllowNull()][string]$RelativePath,[AllowNull()][object]$ZipEntryCount,
        [AllowNull()][string]$ErrorCode
    )
    return [pscustomobject]@{
        object_key=$ObjectKey; status=$Status; http_status=$HttpStatus;
        expected_content_length=$ExpectedLength; observed_size_bytes=$ObservedSize;
        payload_sha256=$Sha256; provider_md5_base64=$ProviderMd5;
        observed_md5_base64=$ObservedMd5; provider_md5_status=$Md5Status;
        local_relative_path=$RelativePath; zip_entry_count=$ZipEntryCount; error_code=$ErrorCode
    }
}

function Invoke-ObjectDownload {
    param([System.Net.Http.HttpClient]$Client,[string]$ObjectKey,[string]$Url,[string]$ArchiveRootPath)
    $relative = 'archives/' + $ObjectKey.Substring(0,4) + '/' + $ObjectKey.Substring(4,2) + '/' + $ObjectKey.Substring(6,2) + '/' + $ObjectKey + '.gkg.csv.zip'
    $finalPath = Join-Path $ArchiveRootPath ($relative.Replace('/','\'))
    $dir = Split-Path -Parent $finalPath
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    for ($httpAttempt=1; $httpAttempt -le $HttpAttemptsPerObject; $httpAttempt++) {
        $tempPath = $finalPath + '.partial-' + [guid]::NewGuid().ToString('N')
        $response = $null; $input = $null; $output = $null
        $statusCode = $null
        try {
            try {
                $response = $Client.GetAsync($Url,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $statusCode = [int]$response.StatusCode
            }
            catch {
                if ($httpAttempt -ge $HttpAttemptsPerObject) {
                    return New-DownloadResult -ObjectKey $ObjectKey -Status 'network_failed' -HttpStatus $null -ExpectedLength $null -ObservedSize $null -Sha256 $null -ProviderMd5 $null -ObservedMd5 $null -Md5Status $null -RelativePath $null -ZipEntryCount $null -ErrorCode (Get-ErrorCode -Message $_.Exception.Message)
                }
                Start-Sleep -Seconds ([Math]::Min(30,2*$httpAttempt))
                continue
            }

            if ($statusCode -eq 404) {
                return New-DownloadResult -ObjectKey $ObjectKey -Status 'provider_missing' -HttpStatus 404 -ExpectedLength $null -ObservedSize $null -Sha256 $null -ProviderMd5 $null -ObservedMd5 $null -Md5Status $null -RelativePath $null -ZipEntryCount $null -ErrorCode $null
            }
            if (-not $response.IsSuccessStatusCode) {
                if ($httpAttempt -ge $HttpAttemptsPerObject) {
                    return New-DownloadResult -ObjectKey $ObjectKey -Status 'network_failed' -HttpStatus $statusCode -ExpectedLength $null -ObservedSize $null -Sha256 $null -ProviderMd5 $null -ObservedMd5 $null -Md5Status $null -RelativePath $null -ZipEntryCount $null -ErrorCode (Get-ErrorCode -Message ('HTTP status ' + $statusCode))
                }
                Start-Sleep -Seconds ([Math]::Min(30,2*$httpAttempt))
                continue
            }

            $expectedLength = $response.Content.Headers.ContentLength
            $providerMd5 = Get-ProviderMd5Base64 -Response $response
            try {
                $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $output = [System.IO.File]::Open($tempPath,[System.IO.FileMode]::Create,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
                $input.CopyTo($output); $output.Flush(); $output.Dispose(); $output=$null; $input.Dispose(); $input=$null
                $size = [long](Get-Item -LiteralPath $tempPath).Length
                if ($null -ne $expectedLength -and [long]$expectedLength -ne $size) { throw "Content-Length mismatch expected=$expectedLength observed=$size" }
                if ($size -le 0) { throw 'Downloaded payload is empty.' }
                $sha256 = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
                $md5Hex = (Get-FileHash -LiteralPath $tempPath -Algorithm MD5).Hash.ToLowerInvariant()
                $observedMd5 = Convert-HexToBase64 -Hex $md5Hex
                $md5Status = if ([string]::IsNullOrWhiteSpace($providerMd5)) { 'NOT_AVAILABLE' } elseif ($providerMd5 -eq $observedMd5) { 'PASS' } else { 'FAIL' }
                if ($md5Status -eq 'FAIL') { throw 'Provider MD5 does not match downloaded payload.' }
                $entryCount = Test-ZipStructure -Path $tempPath
                Move-Item -LiteralPath $tempPath -Destination $finalPath -Force
                return New-DownloadResult -ObjectKey $ObjectKey -Status 'downloaded' -HttpStatus $statusCode -ExpectedLength $expectedLength -ObservedSize $size -Sha256 $sha256 -ProviderMd5 $(if([string]::IsNullOrWhiteSpace($providerMd5)){$null}else{$providerMd5}) -ObservedMd5 $observedMd5 -Md5Status $md5Status -RelativePath $relative -ZipEntryCount $entryCount -ErrorCode $null
            }
            catch {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                if ($httpAttempt -ge $HttpAttemptsPerObject) {
                    return New-DownloadResult -ObjectKey $ObjectKey -Status 'integrity_failed' -HttpStatus $statusCode -ExpectedLength $expectedLength -ObservedSize $null -Sha256 $null -ProviderMd5 $(if([string]::IsNullOrWhiteSpace($providerMd5)){$null}else{$providerMd5}) -ObservedMd5 $null -Md5Status $null -RelativePath $null -ZipEntryCount $null -ErrorCode (Get-ErrorCode -Message $_.Exception.Message)
                }
                Start-Sleep -Seconds ([Math]::Min(30,2*$httpAttempt))
            }
        }
        finally {
            if ($null -ne $output) { $output.Dispose() }
            if ($null -ne $input) { $input.Dispose() }
            if ($null -ne $response) { $response.Dispose() }
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-BatchResults {
    param([string]$PsqlExe,[string]$ContractSha,[guid]$RunId,[object[]]$Results)
    if ($Results.Count -eq 0) { return }
    $sql = New-Object System.Text.StringBuilder
    [void]$sql.AppendLine('BEGIN;')
    foreach ($r in $Results) {
        $http = if ($null -eq $r.http_status) { 'NULL' } else { [string][int]$r.http_status }
        $expected = if ($null -eq $r.expected_content_length) { 'NULL' } else { [string][long]$r.expected_content_length }
        $observed = if ($null -eq $r.observed_size_bytes) { 'NULL' } else { [string][long]$r.observed_size_bytes }
        $zipCount = if ($null -eq $r.zip_entry_count) { 'NULL' } else { [string][int]$r.zip_entry_count }
        [void]$sql.AppendLine(@"
UPDATE source_news.source_slots SET
  status=$(Sql-Literal $r.status),attempt_count=attempt_count+1,http_status=$http,
  expected_content_length=$expected,observed_size_bytes=$observed,payload_sha256=$(Sql-Literal $r.payload_sha256),
  provider_md5_base64=$(Sql-Literal $r.provider_md5_base64),observed_md5_base64=$(Sql-Literal $r.observed_md5_base64),
  provider_md5_status=$(Sql-Literal $r.provider_md5_status),local_relative_path=$(Sql-Literal $r.local_relative_path),
  zip_entry_count=$zipCount,last_attempt_at_utc=clock_timestamp(),error_code=$(Sql-Literal $r.error_code)
WHERE contract_sha256=$(Sql-Literal $ContractSha) AND object_key=$(Sql-Literal $r.object_key);
INSERT INTO source_news.run_events(run_id,object_key,event_type,http_status,error_code)
VALUES ($(Sql-Literal $RunId.ToString()),$(Sql-Literal $r.object_key),$(Sql-Literal $r.status),$http,$(Sql-Literal $r.error_code));
"@)
    }
    [void]$sql.AppendLine("UPDATE source_news.acquisition_runs SET processed_attempts=processed_attempts+$($Results.Count) WHERE run_id=$(Sql-Literal $RunId.ToString());")
    [void]$sql.AppendLine('COMMIT;')
    [void](Invoke-PsqlText -PsqlExe $PsqlExe -Database $DatabaseName -Sql $sql.ToString())
}

function Invoke-SelfTest {
    if ((Get-NominalSlotCount) -ne 8736) { throw 'Self-test failed: Q2 nominal slot count.' }
    if ((Get-ObjectKey -Timestamp $ContractStartUtc) -ne '20250401000000') { throw 'Self-test failed: start object key.' }
    if ((Get-ObjectKey -Timestamp $ContractEndExclusiveUtc.AddMinutes(-15)) -ne '20250630234500') { throw 'Self-test failed: final object key.' }
    if ((Get-SecureUrl -ObjectKey '20250401000000') -ne 'https://storage.googleapis.com/data.gdeltproject.org/gdeltv2/20250401000000.gkg.csv.zip') { throw 'Self-test failed: source URL.' }
    if ((Get-ContractSha256) -notmatch '^[0-9a-f]{64}$') { throw 'Self-test failed: contract hash.' }
    if ((Convert-HexToBase64 -Hex 'd41d8cd98f00b204e9800998ecf8427e') -ne '1B2M2Y8AsgTpgAmY7PhCfg==') { throw 'Self-test failed: MD5 conversion.' }
    if ((Normalize-SqlSubquery -Query "SELECT 1;`r`n") -ne 'SELECT 1') { throw 'Self-test failed: SQL normalization.' }
    if ((Sql-Literal $null) -ne 'NULL') { throw 'Self-test failed: null SQL literal.' }
    if ((Sql-Literal '') -ne 'NULL') { throw 'Self-test failed: empty optional metadata SQL literal.' }
    if ((Sql-Literal 'PASS') -ne "'PASS'") { throw 'Self-test failed: non-empty SQL literal.' }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gdelt-source-selftest-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $zipPath = Join-Path $tempRoot 'sample.zip'
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath,[System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $zip.CreateEntry('sample.gkg.csv')
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try { $writer.WriteLine('sample') } finally { $writer.Dispose() }
        }
        finally { $zip.Dispose() }
        if ((Test-ZipStructure -Path $zipPath) -ne 1) { throw 'Self-test failed: ZIP structure.' }
        $r = New-DownloadResult -ObjectKey '20250401000000' -Status 'provider_missing' -HttpStatus 404 -ExpectedLength $null -ObservedSize $null -Sha256 $null -ProviderMd5 $null -ObservedMd5 $null -Md5Status $null -RelativePath $null -ZipEntryCount $null -ErrorCode $null
        if ([string]$r.status -ne 'provider_missing') { throw 'Self-test failed: provider-missing result classification.' }
        if ((Sql-Literal $r.provider_md5_status) -ne 'NULL') { throw 'Self-test failed: provider-missing MD5 status must serialize as SQL NULL.' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

$oldPassword=$env:PGPASSWORD; $oldPgOptions=$env:PGOPTIONS; $bstr=[IntPtr]::Zero; $ownsPassword=$false
$client=$null; $runId=[guid]::NewGuid(); $runInserted=$false
try {
    $repoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $documents=[Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $ArchiveRoot=Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025' }
    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) { New-Item -ItemType Directory -Path $ArchiveRoot -Force | Out-Null }
    $ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($env:PGPASSWORD)) {
        $securePassword=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
        $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr); $ownsPassword=$true
    }
    $env:PGOPTIONS='-c statement_timeout=120000'
    $psql=Find-Psql; $contractSha=Get-ContractSha256; $gitCommit=Get-GitCommit -RepoRoot $repoRoot
    Write-Host "Using psql: $psql"
    Write-Host "CFA database: $DatabaseName"
    Write-Host "Archive root: $ArchiveRoot"
    Write-Host "Contract SHA-256: $contractSha"
    Write-Host "Nominal Q2 slots: $(Get-NominalSlotCount)"
    Ensure-CfaDatabase -PsqlExe $psql
    Ensure-SourceSchema -PsqlExe $psql -ContractSha $contractSha -GitCommit $gitCommit
    [void](Invoke-PsqlText -PsqlExe $psql -Database $DatabaseName -Sql @"
INSERT INTO source_news.acquisition_runs(run_id,contract_sha256,status,archive_root,git_commit)
VALUES ($(Sql-Literal $runId.ToString()),$(Sql-Literal $contractSha),'running',$(Sql-Literal $ArchiveRoot),$(Sql-Literal $gitCommit));
"@)
    $runInserted=$true
    $handler=New-Object System.Net.Http.HttpClientHandler
    $handler.AutomaticDecompression=[System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $client=New-Object System.Net.Http.HttpClient -ArgumentList $handler
    $client.Timeout=[TimeSpan]::FromSeconds($HttpTimeoutSeconds)
    [void]$client.DefaultRequestHeaders.UserAgent.ParseAdd('CFA-source-acquisition/1.0')

    $processed=0
    while ($true) {
        $batch=@(Get-UnresolvedBatch -PsqlExe $psql -ContractSha $contractSha)
        if ($batch.Count -eq 0) { break }
        if ($MaxObjects -gt 0 -and $processed -ge $MaxObjects) { break }
        $results=@()
        foreach ($slot in $batch) {
            if ($MaxObjects -gt 0 -and $processed -ge $MaxObjects) { break }
            $result=Invoke-ObjectDownload -Client $client -ObjectKey ([string]$slot.object_key) -Url ([string]$slot.secure_url) -ArchiveRootPath $ArchiveRoot
            $results += $result; $processed++
            Write-Host ("{0} {1} HTTP={2}" -f $result.object_key,$result.status,$result.http_status)
        }
        Save-BatchResults -PsqlExe $psql -ContractSha $contractSha -RunId $runId -Results $results
    }

    $summaryCsv=Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT status,count(*)::bigint AS exact_slots FROM source_news.source_slots
WHERE contract_sha256=$(Sql-Literal $contractSha) GROUP BY status ORDER BY status
"@
    $summary=@($summaryCsv | ConvertFrom-Csv); $unresolved=0L
    foreach ($row in $summary) { if (([string]$row.status) -in @('pending','network_failed','integrity_failed')) { $unresolved += [long]$row.exact_slots } }
    $finalRunStatus=if($unresolved -eq 0){'completed'}elseif($MaxObjects -gt 0 -and $processed -ge $MaxObjects){'partial'}else{'blocked'}
    [void](Invoke-PsqlText -PsqlExe $psql -Database $DatabaseName -Sql ("UPDATE source_news.acquisition_runs SET status="+(Sql-Literal $finalRunStatus)+",completed_at_utc=clock_timestamp() WHERE run_id="+(Sql-Literal $runId.ToString())+';'))
    Write-Host ''
    Write-Host '=== CFA GDELT Q2 SOURCE ACQUISITION ==='
    $summary | Format-Table -AutoSize
    Write-Host "Processed attempts this run: $processed"
    Write-Host "Unresolved slots: $unresolved"
    Write-Host "Run status: $finalRunStatus"
    if ($unresolved -eq 0) { Write-Host 'CFA GDELT Q2 SOURCE ACQUISITION: COMPLETE' } else { Write-Host 'CFA GDELT Q2 SOURCE ACQUISITION: BLOCKED' }
}
catch {
    if ($runInserted) {
        try { $p=Find-Psql; [void](Invoke-PsqlText -PsqlExe $p -Database $DatabaseName -Sql ("UPDATE source_news.acquisition_runs SET status='failed',completed_at_utc=clock_timestamp() WHERE run_id="+(Sql-Literal $runId.ToString())+';')) } catch { }
    }
    Write-Host 'CFA GDELT Q2 SOURCE ACQUISITION: FAIL'; Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1
}
finally {
    if ($null -ne $client) { $client.Dispose() }
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS=$oldPgOptions }
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($ownsPassword) { if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD=$oldPassword } }
}
