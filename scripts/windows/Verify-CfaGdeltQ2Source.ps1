#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$DatabaseName = 'cfa',
    [string]$ArchiveRoot = '',
    [string]$OutputRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedStartUtc = [datetimeoffset]::Parse('2025-04-01T00:00:00+00:00')
$ExpectedEndExclusiveUtc = [datetimeoffset]::Parse('2025-07-01T00:00:00+00:00')
$ExpectedCadenceMinutes = 15
$ExpectedSlotCount = 8736
$ExpectedSourceProduct = 'GDELT 2.0 native/base GKG fifteen-minute update archives'
$ExpectedUrlTemplate = 'https://storage.googleapis.com/data.gdeltproject.org/gdeltv2/{object_key}.gkg.csv.zip'

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
    try {
        $stdout = @(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2> $errFile)
        $exitCode = $LASTEXITCODE
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) { $stderr = ((Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine }
        $text = ($stdout | ForEach-Object { if ($null -ne $_) { [string]$_ } }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            $message = if ([string]::IsNullOrWhiteSpace($stderr)) { $text } else { $stderr }
            throw "psql failed for database '$Database' (exit $exitCode).`n$message"
        }
        return $text.Trim()
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
}

function Invoke-PsqlCsv {
    param([string]$PsqlExe,[string]$Database,[string]$Query)
    $q = $Query.Trim()
    while ($q.EndsWith(';')) { $q = $q.Substring(0,$q.Length-1).TrimEnd() }
    return Invoke-PsqlText -PsqlExe $PsqlExe -Database $Database -Sql "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-ExpectedContractSha {
    $canonical = $ExpectedSourceProduct + '|' + $ExpectedStartUtc.ToString('o') + '|' + $ExpectedEndExclusiveUtc.ToString('o') + '|' + $ExpectedCadenceMinutes + '|' + $ExpectedUrlTemplate
    return Get-Sha256Text -Text $canonical
}

function Get-GateStatus {
    param([object[]]$Rows)
    if ($Rows.Count -eq 0) { return 'UNVERIFIED' }
    if (@($Rows | Where-Object { [string]$_.status -eq 'FAIL' }).Count -gt 0) { return 'FAIL' }
    if (@($Rows | Where-Object { [string]$_.status -eq 'UNVERIFIED' }).Count -gt 0) { return 'UNVERIFIED' }
    if (@($Rows | Where-Object { [string]$_.status -ne 'PASS' }).Count -eq 0) { return 'PASS' }
    return 'UNVERIFIED'
}

function New-Check {
    param([string]$Id,[bool]$Pass,[AllowNull()][object]$Observed,[AllowNull()][object]$Expected)
    return [pscustomobject]@{ check_id=$Id; status=if($Pass){'PASS'}else{'FAIL'}; observed=$Observed; expected=$Expected }
}

function Invoke-SelfTest {
    if ((Get-ExpectedContractSha) -notmatch '^[0-9a-f]{64}$') { throw 'Self-test failed: expected contract SHA.' }
    $checks = @(
        (New-Check -Id 'A' -Pass $true -Observed 1 -Expected 1),
        (New-Check -Id 'B' -Pass $true -Observed 0 -Expected 0)
    )
    if ((Get-GateStatus -Rows $checks) -ne 'PASS') { throw 'Self-test failed: PASS gate.' }
    $checks += (New-Check -Id 'C' -Pass $false -Observed 1 -Expected 0)
    if ((Get-GateStatus -Rows $checks) -ne 'FAIL') { throw 'Self-test failed: FAIL gate.' }

    $temp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($temp,'abc',(New-Object System.Text.UTF8Encoding($false)))
        $hash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') { throw 'Self-test failed: file SHA.' }
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

$oldPassword = $env:PGPASSWORD
$oldPgOptions = $env:PGOPTIONS
$bstr = [IntPtr]::Zero
$ownsPassword = $false

try {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) { $ArchiveRoot = Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $documents 'CFA-local\gdelt-q2-source-verification' }
    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) { throw "GDELT archive root does not exist: $ArchiveRoot" }
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $runDir = Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($env:PGPASSWORD)) {
        $securePassword = Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $ownsPassword = $true
    }
    $env:PGOPTIONS = '-c default_transaction_read_only=on -c statement_timeout=120000'

    $psql = Find-Psql
    $contractSha = Get-ExpectedContractSha
    Write-Host "Using psql: $psql"
    Write-Host "Evidence directory: $runDir"
    Write-Host "Contract SHA-256: $contractSha"
    Write-Host 'Session mode: default_transaction_read_only=on'

    $contractCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT contract_sha256,source_product,interval_start_utc,interval_end_exclusive_utc,cadence_minutes,nominal_slot_count,url_template
FROM source_news.source_contracts
WHERE contract_sha256='$contractSha'
"@
    $summaryCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT
    count(*)::bigint AS exact_slots,
    count(*) FILTER (WHERE status='downloaded')::bigint AS downloaded_slots,
    count(*) FILTER (WHERE status='provider_missing')::bigint AS provider_missing_slots,
    count(*) FILTER (WHERE status IN ('pending','network_failed','integrity_failed'))::bigint AS unresolved_slots,
    count(*) FILTER (WHERE status='downloaded' AND payload_sha256 IS NULL)::bigint AS downloaded_null_sha256,
    count(*) FILTER (WHERE status='provider_missing' AND http_status IS DISTINCT FROM 404)::bigint AS provider_missing_non_404,
    min(archive_timestamp_utc) AS min_slot_utc,
    max(archive_timestamp_utc) AS max_slot_utc
FROM source_news.source_slots
WHERE contract_sha256='$contractSha'
"@
    $downloadedCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT object_key,local_relative_path,observed_size_bytes,payload_sha256
FROM source_news.source_slots
WHERE contract_sha256='$contractSha' AND status='downloaded'
ORDER BY archive_timestamp_utc
"@
    $missingCsv = Invoke-PsqlCsv -PsqlExe $psql -Database $DatabaseName -Query @"
SELECT object_key,archive_timestamp_utc,http_status
FROM source_news.source_slots
WHERE contract_sha256='$contractSha' AND status='provider_missing'
ORDER BY archive_timestamp_utc
"@

    $contracts = @($contractCsv | ConvertFrom-Csv)
    $summaries = @($summaryCsv | ConvertFrom-Csv)
    $downloaded = @($downloadedCsv | ConvertFrom-Csv)
    $providerMissing = @($missingCsv | ConvertFrom-Csv)
    if ($summaries.Count -ne 1) { throw 'Slot summary did not return exactly one row.' }

    $fileChecks = @()
    $missingFiles = 0L
    $sizeMismatches = 0L
    $hashMismatches = 0L
    foreach ($row in $downloaded) {
        $relative = [string]$row.local_relative_path
        $path = if ([string]::IsNullOrWhiteSpace($relative)) { '' } else { Join-Path $ArchiveRoot ($relative.Replace('/','\')) }
        $exists = -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)
        $sizeStatus = 'UNVERIFIED'
        $hashStatus = 'UNVERIFIED'
        $observedFileSize = $null
        $observedHash = $null
        if (-not $exists) {
            $missingFiles++
        } else {
            $observedFileSize = [long](Get-Item -LiteralPath $path).Length
            if ($observedFileSize -eq [long]$row.observed_size_bytes) { $sizeStatus='PASS' } else { $sizeStatus='FAIL'; $sizeMismatches++ }
            $observedHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($observedHash -eq [string]$row.payload_sha256) { $hashStatus='PASS' } else { $hashStatus='FAIL'; $hashMismatches++ }
        }
        $fileChecks += [pscustomobject]@{ object_key=$row.object_key; exists=$exists; expected_size_bytes=$row.observed_size_bytes; observed_size_bytes=$observedFileSize; size_status=$sizeStatus; expected_sha256=$row.payload_sha256; observed_sha256=$observedHash; hash_status=$hashStatus }
    }

    $summary = $summaries[0]
    $checks = @()
    $checks += New-Check -Id 'CONTRACT_CARDINALITY' -Pass ($contracts.Count -eq 1) -Observed $contracts.Count -Expected 1
    if ($contracts.Count -eq 1) {
        $c = $contracts[0]
        $checks += New-Check -Id 'SOURCE_PRODUCT' -Pass ([string]$c.source_product -eq $ExpectedSourceProduct) -Observed $c.source_product -Expected $ExpectedSourceProduct
        $checks += New-Check -Id 'INTERVAL_START_UTC' -Pass ([datetimeoffset]::Parse([string]$c.interval_start_utc) -eq $ExpectedStartUtc) -Observed $c.interval_start_utc -Expected $ExpectedStartUtc.ToString('o')
        $checks += New-Check -Id 'INTERVAL_END_EXCLUSIVE_UTC' -Pass ([datetimeoffset]::Parse([string]$c.interval_end_exclusive_utc) -eq $ExpectedEndExclusiveUtc) -Observed $c.interval_end_exclusive_utc -Expected $ExpectedEndExclusiveUtc.ToString('o')
        $checks += New-Check -Id 'CADENCE_MINUTES' -Pass ([int]$c.cadence_minutes -eq $ExpectedCadenceMinutes) -Observed $c.cadence_minutes -Expected $ExpectedCadenceMinutes
        $checks += New-Check -Id 'CONTRACT_NOMINAL_SLOT_COUNT' -Pass ([int]$c.nominal_slot_count -eq $ExpectedSlotCount) -Observed $c.nominal_slot_count -Expected $ExpectedSlotCount
        $checks += New-Check -Id 'URL_TEMPLATE' -Pass ([string]$c.url_template -eq $ExpectedUrlTemplate) -Observed $c.url_template -Expected $ExpectedUrlTemplate
    }
    $checks += New-Check -Id 'SOURCE_SLOT_COUNT' -Pass ([long]$summary.exact_slots -eq $ExpectedSlotCount) -Observed $summary.exact_slots -Expected $ExpectedSlotCount
    $checks += New-Check -Id 'UNRESOLVED_SLOTS' -Pass ([long]$summary.unresolved_slots -eq 0) -Observed $summary.unresolved_slots -Expected 0
    $checks += New-Check -Id 'DOWNLOADED_NULL_SHA256' -Pass ([long]$summary.downloaded_null_sha256 -eq 0) -Observed $summary.downloaded_null_sha256 -Expected 0
    $checks += New-Check -Id 'PROVIDER_MISSING_HTTP_404' -Pass ([long]$summary.provider_missing_non_404 -eq 0) -Observed $summary.provider_missing_non_404 -Expected 0
    $checks += New-Check -Id 'LOCAL_FILES_MISSING' -Pass ($missingFiles -eq 0) -Observed $missingFiles -Expected 0
    $checks += New-Check -Id 'LOCAL_FILE_SIZE_MISMATCHES' -Pass ($sizeMismatches -eq 0) -Observed $sizeMismatches -Expected 0
    $checks += New-Check -Id 'LOCAL_FILE_SHA256_MISMATCHES' -Pass ($hashMismatches -eq 0) -Observed $hashMismatches -Expected 0
    $checks += New-Check -Id 'ACCOUNTING_TOTAL' -Pass (([long]$summary.downloaded_slots + [long]$summary.provider_missing_slots) -eq $ExpectedSlotCount) -Observed (([long]$summary.downloaded_slots + [long]$summary.provider_missing_slots)) -Expected $ExpectedSlotCount

    $gate = Get-GateStatus -Rows $checks
    $contracts | Export-Csv -LiteralPath (Join-Path $runDir 'source-contract.csv') -NoTypeInformation -Encoding UTF8
    $summaries | Export-Csv -LiteralPath (Join-Path $runDir 'slot-summary.csv') -NoTypeInformation -Encoding UTF8
    $providerMissing | Export-Csv -LiteralPath (Join-Path $runDir 'provider-missing-slots.csv') -NoTypeInformation -Encoding UTF8
    $fileChecks | Export-Csv -LiteralPath (Join-Path $runDir 'local-file-checks.csv') -NoTypeInformation -Encoding UTF8
    $checks | Export-Csv -LiteralPath (Join-Path $runDir 'source-verification-checks.csv') -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host '=== CFA GDELT Q2 SOURCE VERIFICATION ==='
    $checks | Format-Table -AutoSize
    Write-Host "Downloaded slots       : $($summary.downloaded_slots)"
    Write-Host "Provider-missing slots : $($summary.provider_missing_slots)"
    Write-Host "Gate                    : $gate"
    Write-Host "Evidence directory      : $runDir"
    if ($gate -eq 'PASS') {
        Write-Host 'CFA GDELT Q2 SOURCE VERIFICATION: PASS'
        exit 0
    }
    Write-Host 'CFA GDELT Q2 SOURCE VERIFICATION: FAIL'
    exit 2
}
catch {
    Write-Host 'CFA GDELT Q2 SOURCE VERIFICATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
finally {
    if ($null -eq $oldPgOptions) { Remove-Item Env:PGOPTIONS -ErrorAction SilentlyContinue } else { $env:PGOPTIONS = $oldPgOptions }
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($ownsPassword) {
        if ($null -eq $oldPassword) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $oldPassword }
    }
}
