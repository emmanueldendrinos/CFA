#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$DocumentsRoot = '',
    [string]$ExternalDriveRoot = 'D:\',
    [switch]$Execute,
    [switch]$SelfTest,
    [string]$ExpectedQ2Sha256 = '36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c',
    [switch]$SkipFreeSpaceCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RetainedStage3Run = '20260828-125505-1d682a2599b245f7bdb06ce44a69764a'
$RetainedDbDiscoveryRun = '20260825-111030-269c48acc9ee4e0293c31c8a79d034e6'
$RetainedExternalPgRun = '20260829-065450-2e86a9154d9846ae8b5ac5ce3c695272'

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-PathWithin {
    param([Parameter(Mandatory)][string]$Child,[Parameter(Mandatory)][string]$Parent)
    $c = (Get-NormalizedFullPath $Child) + '\'
    $p = (Get-NormalizedFullPath $Parent) + '\'
    return $c.StartsWith($p,[System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePathCompat {
    param([Parameter(Mandatory)][string]$BasePath,[Parameter(Mandatory)][string]$FullPath)
    $base = (Get-NormalizedFullPath $BasePath) + '\'
    $full = Get-NormalizedFullPath $FullPath
    if (-not $full.StartsWith($base,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside base path. Base='$BasePath' Full='$FullPath'"
    }
    return $full.Substring($base.Length)
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-TreeManifest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Role
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Required source directory missing: $Root"
    }
    $rows = New-Object System.Collections.ArrayList
    $files = @([System.IO.Directory]::EnumerateFiles((Get-NormalizedFullPath $Root),'*',[System.IO.SearchOption]::AllDirectories) | Sort-Object)
    foreach ($path in $files) {
        $info = Get-Item -LiteralPath $path -Force
        [void]$rows.Add([pscustomobject]@{
            role = $Role
            relative_path = (Get-RelativePathCompat -BasePath $Root -FullPath $info.FullName)
            size_bytes = [long]$info.Length
            sha256 = (Get-Sha256 -Path $info.FullName)
            last_write_utc = $info.LastWriteTimeUtc.ToString('o')
        })
    }
    $rows | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding UTF8
    return $rows
}

function Compare-Manifests {
    param(
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][object[]]$Observed,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Expected.Count -ne $Observed.Count) {
        throw "$Label file-count mismatch: expected $($Expected.Count), observed $($Observed.Count)"
    }
    $obsByPath = @{}
    foreach ($row in $Observed) {
        $key = ([string]$row.relative_path).ToLowerInvariant()
        if ($obsByPath.ContainsKey($key)) { throw "$Label duplicate destination relative path: $($row.relative_path)" }
        $obsByPath[$key] = $row
    }
    foreach ($row in $Expected) {
        $key = ([string]$row.relative_path).ToLowerInvariant()
        if (-not $obsByPath.ContainsKey($key)) { throw "$Label missing destination file: $($row.relative_path)" }
        $other = $obsByPath[$key]
        if ([long]$row.size_bytes -ne [long]$other.size_bytes) { throw "$Label size mismatch: $($row.relative_path)" }
        if ([string]$row.sha256 -ne [string]$other.sha256) { throw "$Label SHA-256 mismatch: $($row.relative_path)" }
    }
}

function Invoke-RobocopyTree {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $logPath = Join-Path $script:ReceiptRoot ('robocopy-' + ([guid]::NewGuid().ToString('N')) + '.log')
    $args = @($Source,$Destination,'/E','/COPY:DAT','/DCOPY:T','/R:2','/W:2','/MT:8','/XJ','/NP','/NFL','/NDL','/TEE',('/LOG:' + $logPath))
    & robocopy.exe @args | Out-Host
    $code = [int]$LASTEXITCODE
    if ($code -ge 8) { throw "Robocopy failed with exit code $code. Log: $logPath" }
    return $code
}

function Copy-TreeVerified {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label
    )
    Write-Host ''
    Write-Host "Hashing source tree: $Label"
    $safe = $Label -replace '[^A-Za-z0-9._-]','_'
    $srcManifestPath = Join-Path $script:ReceiptRoot ($safe + '-source-manifest.csv')
    $dstManifestPath = Join-Path $script:ReceiptRoot ($safe + '-destination-manifest.csv')
    $sourceManifest = @(Get-TreeManifest -Root $Source -ManifestPath $srcManifestPath -Role ($Label + '_SOURCE'))
    if ($sourceManifest.Count -eq 0) { throw "Required retained tree is empty: $Source" }
    if ($Execute) {
        Write-Host "Copying verified tree: $Label"
        [void](Invoke-RobocopyTree -Source $Source -Destination $Destination)
    } else {
        Write-Host "PLAN ONLY: would copy '$Source' -> '$Destination'"
        return [pscustomobject]@{label=$Label;source=$Source;destination=$Destination;files=$sourceManifest.Count;bytes=[long](($sourceManifest|Measure-Object -Property size_bytes -Sum).Sum);status='PLANNED'}
    }
    Write-Host "Hashing destination tree: $Label"
    $destinationManifest = @(Get-TreeManifest -Root $Destination -ManifestPath $dstManifestPath -Role ($Label + '_DESTINATION'))
    Compare-Manifests -Expected $sourceManifest -Observed $destinationManifest -Label $Label
    return [pscustomobject]@{label=$Label;source=$Source;destination=$Destination;files=$sourceManifest.Count;bytes=[long](($sourceManifest|Measure-Object -Property size_bytes -Sum).Sum);status='PASS'}
}

function Copy-FileVerified {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$ExpectedSha256 = ''
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Required retained file missing: $Source" }
    $sourceInfo = Get-Item -LiteralPath $Source -Force
    $sourceHash = Get-Sha256 -Path $Source
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $sourceHash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$Label source hash does not match frozen expected SHA-256. Observed=$sourceHash Expected=$ExpectedSha256"
    }
    if (-not $Execute) {
        Write-Host "PLAN ONLY: would copy '$Source' -> '$Destination'"
        return [pscustomobject]@{label=$Label;source=$Source;destination=$Destination;files=1;bytes=[long]$sourceInfo.Length;status='PLANNED';sha256=$sourceHash}
    }
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::Copy($Source,$Destination,$true)
    $destInfo = Get-Item -LiteralPath $Destination -Force
    $destInfo.LastWriteTimeUtc = $sourceInfo.LastWriteTimeUtc
    if ($destInfo.Length -ne $sourceInfo.Length) { throw "$Label destination size mismatch." }
    $destHash = Get-Sha256 -Path $Destination
    if ($destHash -ne $sourceHash) { throw "$Label destination SHA-256 mismatch." }
    return [pscustomobject]@{label=$Label;source=$Source;destination=$Destination;files=1;bytes=[long]$sourceInfo.Length;status='PASS';sha256=$sourceHash}
}

function Assert-DuplicateFile {
    param(
        [Parameter(Mandatory)][string]$Canonical,
        [Parameter(Mandatory)][string]$Duplicate,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Canonical -PathType Leaf)) { throw "$Label canonical file missing: $Canonical" }
    if (-not (Test-Path -LiteralPath $Duplicate -PathType Leaf)) { throw "$Label duplicate file missing: $Duplicate" }
    $a = Get-Item -LiteralPath $Canonical -Force
    $b = Get-Item -LiteralPath $Duplicate -Force
    if ($a.Length -ne $b.Length) { throw "$Label duplicate size mismatch." }
    $ha = Get-Sha256 -Path $Canonical
    $hb = Get-Sha256 -Path $Duplicate
    if ($ha -ne $hb) { throw "$Label duplicate SHA-256 mismatch. Canonical=$ha Duplicate=$hb" }
    return [pscustomobject]@{label=$Label;canonical=$Canonical;duplicate=$Duplicate;size_bytes=[long]$a.Length;sha256=$ha;status='PASS'}
}

function Get-DirectoryBytes {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return [long]0 }
    [long]$sum = 0
    foreach ($path in [System.IO.Directory]::EnumerateFiles((Get-NormalizedFullPath $Root),'*',[System.IO.SearchOption]::AllDirectories)) { $sum += [long](Get-Item -LiteralPath $path -Force).Length }
    return $sum
}

function Assert-SafeRoots {
    param(
        [Parameter(Mandatory)][string]$Documents,
        [Parameter(Mandatory)][string]$External,
        [Parameter(Mandatory)][string]$Srp,
        [Parameter(Mandatory)][string]$Asrp,
        [Parameter(Mandatory)][string]$Cfa,
        [Parameter(Mandatory)][string]$CfaLocal
    )
    $docs = Get-NormalizedFullPath $Documents
    $ext = Get-NormalizedFullPath $External
    if (-not $SelfTest -and [string]::Equals([System.IO.Path]::GetPathRoot($docs),[System.IO.Path]::GetPathRoot($ext),[System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ExternalDriveRoot must be on a different volume from DocumentsRoot."
    }
    foreach ($p in @($Srp,$Asrp,$Cfa,$CfaLocal)) { if (-not (Test-PathWithin -Child $p -Parent $docs)) { throw "Safety boundary failure: path is outside DocumentsRoot: $p" } }
    if (-not (Test-Path -LiteralPath $Cfa -PathType Container)) { throw "CFA repository missing: $Cfa" }
    if (-not (Test-Path -LiteralPath (Join-Path $Cfa '.git') -PathType Container) -and -not (Test-Path -LiteralPath (Join-Path $Cfa '.git') -PathType Leaf)) { throw "CFA repository .git marker missing: $Cfa" }
    if (Test-PathWithin -Child $Cfa -Parent $Srp) { throw 'CFA repository unexpectedly inside SRP delete root.' }
    if (Test-PathWithin -Child $Cfa -Parent $Asrp) { throw 'CFA repository unexpectedly inside ASRP delete root.' }
    if (Test-PathWithin -Child $Cfa -Parent $CfaLocal) { throw 'CFA repository unexpectedly inside CFA-local delete root.' }
}

function Remove-LegacyRoot {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)
    if (-not $Execute) { Write-Host "PLAN ONLY: would delete $Label -> $Path"; return }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Delete root unexpectedly missing before deletion: $Path" }
    Write-Host "Deleting verified legacy root: $Label -> $Path"
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) { throw "Deletion verification failed: $Path" }
}

function Invoke-CfaMigration {
    param([Parameter(Mandatory)][string]$Docs,[Parameter(Mandatory)][string]$External)
    $docs = Get-NormalizedFullPath $Docs
    $external = Get-NormalizedFullPath $External
    $projects = Join-Path $docs 'Projects'
    $srp = Join-Path $projects 'SRP'
    $asrp = Join-Path $projects 'ASRP'
    $cfa = Join-Path $projects 'CFA'
    $cfaLocal = Join-Path $docs 'CFA-local'
    Assert-SafeRoots -Documents $docs -External $external -Srp $srp -Asrp $asrp -Cfa $cfa -CfaLocal $cfaLocal
    foreach ($required in @($srp,$asrp,$cfaLocal)) { if (-not (Test-Path -LiteralPath $required -PathType Container)) { throw "Required cleanup root missing: $required" } }

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $script:ReceiptRoot = Join-Path $external ('CFA-recovery\migration\' + $runId)
    New-Item -ItemType Directory -Path $script:ReceiptRoot -Force | Out-Null

    $gdeltSource = Join-Path $cfaLocal 'gdelt-gkg-q2-2025'
    $stage3Source = Join-Path $cfaLocal ('stage3-news-matching\' + $RetainedStage3Run)
    $dbDiscoverySource = Join-Path $cfaLocal ('db-discovery\' + $RetainedDbDiscoveryRun)
    $externalPgSource = Join-Path $cfaLocal ('external-postgres-inventory\' + $RetainedExternalPgRun)
    $gdeltDest = Join-Path $external 'CFA-bulk\source\gdelt-gkg-q2-2025'
    $stage3Dest = Join-Path $external ('CFA-bulk\analysis\stage3-news-matching\' + $RetainedStage3Run)
    $dbDiscoveryDest = Join-Path $external ('CFA-recovery\pls-evidence\db-discovery\' + $RetainedDbDiscoveryRun)
    $externalPgDest = Join-Path $external ('CFA-recovery\pls-evidence\external-postgres-inventory\' + $RetainedExternalPgRun)
    $krakenDestRoot = Join-Path $external 'CFA-bulk\source\kraken'

    $kraken = @(
        [pscustomobject]@{label='Kraken_Q2_2025';canonical=(Join-Path $asrp 'source\development\research_2025q2\Kraken_OHLCVT_Q2_2025.zip');duplicate=(Join-Path $srp 'packages\Kraken_OHLCVT_Q2_2025.zip');destination=(Join-Path $krakenDestRoot 'Kraken_OHLCVT_Q2_2025.zip');expected=$ExpectedQ2Sha256},
        [pscustomobject]@{label='Kraken_Q3_2025';canonical=(Join-Path $asrp 'source\sealed_validation\2025q3\Kraken_OHLCVT_Q3_2025.zip');duplicate=(Join-Path $srp 'packages\Kraken_OHLCVT_Q3_2025.zip');destination=(Join-Path $krakenDestRoot 'Kraken_OHLCVT_Q3_2025.zip');expected=''},
        [pscustomobject]@{label='Kraken_Q4_2025';canonical=(Join-Path $asrp 'source\future_reference\Kraken_OHLCVT_Q4_2025.zip');duplicate=(Join-Path $srp 'packages\Kraken_OHLCVT_Q4_2025.zip');destination=(Join-Path $krakenDestRoot 'Kraken_OHLCVT_Q4_2025.zip');expected=''},
        [pscustomobject]@{label='Kraken_Q1_2026';canonical=(Join-Path $asrp 'source\future_reference\Kraken_OHLCVT_Q1_2026.zip');duplicate=(Join-Path $srp 'packages\Kraken_OHLCVT_Q1_2026.zip');destination=(Join-Path $krakenDestRoot 'Kraken_OHLCVT_Q1_2026.zip');expected=''}
    )

    Write-Host 'Verifying duplicate Kraken archives before any deletion...'
    $duplicateChecks = New-Object System.Collections.ArrayList
    foreach ($k in $kraken) { [void]$duplicateChecks.Add((Assert-DuplicateFile -Canonical $k.canonical -Duplicate $k.duplicate -Label $k.label)) }
    $duplicateChecks | Export-Csv -LiteralPath (Join-Path $script:ReceiptRoot 'kraken-duplicate-verification.csv') -NoTypeInformation -Encoding UTF8

    [long]$retainedBytes = 0
    $retainedBytes += Get-DirectoryBytes -Root $gdeltSource
    $retainedBytes += Get-DirectoryBytes -Root $stage3Source
    $retainedBytes += Get-DirectoryBytes -Root $dbDiscoverySource
    $retainedBytes += Get-DirectoryBytes -Root $externalPgSource
    foreach ($k in $kraken) { $retainedBytes += [long](Get-Item -LiteralPath $k.canonical -Force).Length }

    if (-not $SkipFreeSpaceCheck) {
        $driveRoot = [System.IO.Path]::GetPathRoot($external)
        $driveInfo = New-Object System.IO.DriveInfo($driveRoot)
        [long]$requiredFree = $retainedBytes + 2147483648L
        if ($driveInfo.AvailableFreeSpace -lt $requiredFree) { throw "Insufficient free space on external drive. Required at least $requiredFree bytes; available $($driveInfo.AvailableFreeSpace)." }
    }

    $preflight = [ordered]@{run_id=$runId;generated_utc=(Get-Date).ToUniversalTime().ToString('o');execute=[bool]$Execute;documents_root=$docs;external_drive_root=$external;retained_bytes=$retainedBytes;delete_roots=@($srp,$asrp,$cfaLocal);preserved_cfa_repo=$cfa;postgres_policy='NOT_TOUCHED';pls_database_policy='NOT_TOUCHED';stage3_run=$RetainedStage3Run;db_discovery_run=$RetainedDbDiscoveryRun;external_postgres_inventory_run=$RetainedExternalPgRun}
    Write-Utf8NoBom -Path (Join-Path $script:ReceiptRoot 'preflight.json') -Content (($preflight | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    $results = New-Object System.Collections.ArrayList
    foreach ($k in $kraken) { [void]$results.Add((Copy-FileVerified -Source $k.canonical -Destination $k.destination -Label $k.label -ExpectedSha256 $k.expected)) }
    [void]$results.Add((Copy-TreeVerified -Source $gdeltSource -Destination $gdeltDest -Label 'GDELT_Q2_2025'))
    [void]$results.Add((Copy-TreeVerified -Source $stage3Source -Destination $stage3Dest -Label 'Stage3_Retained_Run'))
    [void]$results.Add((Copy-TreeVerified -Source $dbDiscoverySource -Destination $dbDiscoveryDest -Label 'PLS_Db_Discovery_Evidence'))
    [void]$results.Add((Copy-TreeVerified -Source $externalPgSource -Destination $externalPgDest -Label 'PLS_External_Postgres_Evidence'))
    $results | Export-Csv -LiteralPath (Join-Path $script:ReceiptRoot 'retained-copy-verification.csv') -NoTypeInformation -Encoding UTF8

    if ($Execute) {
        $failed = @($results | Where-Object { $_.status -ne 'PASS' })
        if ($failed.Count -gt 0) { throw 'Retained-copy verification contains non-PASS rows; deletion blocked.' }
        if (-not (Test-Path -LiteralPath $cfa -PathType Container)) { throw 'CFA repository disappeared before deletion; cleanup blocked.' }
        Remove-LegacyRoot -Path $srp -Label 'SRP'
        Remove-LegacyRoot -Path $asrp -Label 'ASRP'
        Remove-LegacyRoot -Path $cfaLocal -Label 'CFA-local'
        if (-not (Test-Path -LiteralPath $cfa -PathType Container)) { throw 'CFA repository preservation check failed after deletion.' }
        $deletion = @(
            [pscustomobject]@{label='SRP';path=$srp;status=if(Test-Path -LiteralPath $srp){'FAIL'}else{'PASS'}},
            [pscustomobject]@{label='ASRP';path=$asrp;status=if(Test-Path -LiteralPath $asrp){'FAIL'}else{'PASS'}},
            [pscustomobject]@{label='CFA-local';path=$cfaLocal;status=if(Test-Path -LiteralPath $cfaLocal){'FAIL'}else{'PASS'}},
            [pscustomobject]@{label='CFA-repo-preserved';path=$cfa;status=if(Test-Path -LiteralPath $cfa){'PASS'}else{'FAIL'}}
        )
        $deletion | Export-Csv -LiteralPath (Join-Path $script:ReceiptRoot 'deletion-verification.csv') -NoTypeInformation -Encoding UTF8
        if (@($deletion | Where-Object {$_.status -ne 'PASS'}).Count -gt 0) { throw 'Post-deletion verification failed.' }
    }

    $summary = New-Object System.Text.StringBuilder
    [void]$summary.AppendLine('# CFA Bulk Migration and Legacy Cleanup')
    [void]$summary.AppendLine('')
    [void]$summary.AppendLine("- Run ID: $runId")
    [void]$summary.AppendLine("- Mode: $(if($Execute){'EXECUTE'}else{'PLAN_ONLY'})")
    [void]$summary.AppendLine("- CFA repo preserved: $cfa")
    [void]$summary.AppendLine('- PostgreSQL / PLS databases: NOT TOUCHED')
    [void]$summary.AppendLine("- Receipt directory: $($script:ReceiptRoot)")
    [void]$summary.AppendLine('')
    [void]$summary.AppendLine('## Retained artifacts')
    [void]$summary.AppendLine('')
    [void]$summary.AppendLine('| Label | Files | Bytes | Status | Destination |')
    [void]$summary.AppendLine('|---|---:|---:|---|---|')
    foreach ($r in $results) { [void]$summary.AppendLine("| $($r.label) | $($r.files) | $($r.bytes) | $($r.status) | $($r.destination) |") }
    [void]$summary.AppendLine('')
    if ($Execute) { [void]$summary.AppendLine('Deletion occurred only after every retained item passed SHA-256 verification.') } else { [void]$summary.AppendLine('Plan only: no source file was copied or deleted.') }
    Write-Utf8NoBom -Path (Join-Path $script:ReceiptRoot 'summary.md') -Content $summary.ToString()

    $receiptFiles = @(Get-ChildItem -LiteralPath $script:ReceiptRoot -File -Force | Where-Object {$_.Name -ne 'receipt-hashes.csv'} | Sort-Object Name)
    $receiptHashes = foreach ($f in $receiptFiles) { [pscustomobject]@{file_name=$f.Name;size_bytes=[long]$f.Length;sha256=(Get-Sha256 -Path $f.FullName)} }
    $receiptHashes | Export-Csv -LiteralPath (Join-Path $script:ReceiptRoot 'receipt-hashes.csv') -NoTypeInformation -Encoding UTF8

    Write-Host ''
    if ($Execute) { Write-Host 'CFA BULK MIGRATION AND LEGACY CLEANUP: PASS' } else { Write-Host 'CFA BULK MIGRATION PLAN: PASS' }
    Write-Host "Receipt directory: $($script:ReceiptRoot)"
    Write-Host "CFA repository preserved: $cfa"
    Write-Host 'PostgreSQL / PLS databases: NOT TOUCHED'
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-migrate-selftest-' + [guid]::NewGuid().ToString('N'))
    $docs = Join-Path $root 'CDrive\Documents'
    $ext = Join-Path $root 'DDrive'
    try {
        $srp = Join-Path $docs 'Projects\SRP'
        $asrp = Join-Path $docs 'Projects\ASRP'
        $cfa = Join-Path $docs 'Projects\CFA'
        $local = Join-Path $docs 'CFA-local'
        New-Item -ItemType Directory -Path $srp,$asrp,$cfa,$local,$ext -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $cfa '.git') -Force | Out-Null
        'preserve-me' | Set-Content -LiteralPath (Join-Path $cfa 'marker.txt') -Encoding UTF8
        $paths = @(
            (Join-Path $asrp 'source\development\research_2025q2'),
            (Join-Path $asrp 'source\sealed_validation\2025q3'),
            (Join-Path $asrp 'source\future_reference'),
            (Join-Path $srp 'packages'),
            (Join-Path $local 'gdelt-gkg-q2-2025\archives\2025\04\01'),
            (Join-Path $local ('stage3-news-matching\' + $RetainedStage3Run)),
            (Join-Path $local ('db-discovery\' + $RetainedDbDiscoveryRun)),
            (Join-Path $local ('external-postgres-inventory\' + $RetainedExternalPgRun + '\pls_trading'))
        )
        foreach($p in $paths){ New-Item -ItemType Directory -Path $p -Force | Out-Null }
        $quarters = @{'Kraken_OHLCVT_Q2_2025.zip'='q2';'Kraken_OHLCVT_Q3_2025.zip'='q3';'Kraken_OHLCVT_Q4_2025.zip'='q4';'Kraken_OHLCVT_Q1_2026.zip'='q1'}
        foreach($name in $quarters.Keys){
            $content = $quarters[$name]
            $canon = switch($name){'Kraken_OHLCVT_Q2_2025.zip'{Join-Path $asrp 'source\development\research_2025q2'};'Kraken_OHLCVT_Q3_2025.zip'{Join-Path $asrp 'source\sealed_validation\2025q3'};default{Join-Path $asrp 'source\future_reference'}}
            [System.IO.File]::WriteAllText((Join-Path $canon $name),$content)
            [System.IO.File]::WriteAllText((Join-Path (Join-Path $srp 'packages') $name),$content)
        }
        [System.IO.File]::WriteAllText((Join-Path $local 'gdelt-gkg-q2-2025\archives\2025\04\01\a.zip'),'gdelt-a')
        [System.IO.File]::WriteAllText((Join-Path $local 'gdelt-gkg-q2-2025\archives\2025\04\01\b.zip'),'gdelt-b')
        [System.IO.File]::WriteAllText((Join-Path $local ('stage3-news-matching\' + $RetainedStage3Run + '\stage3-match-summary.json')),'{}')
        [System.IO.File]::WriteAllText((Join-Path $local ('db-discovery\' + $RetainedDbDiscoveryRun + '\pls_trading-columns.csv')),'a,b')
        [System.IO.File]::WriteAllText((Join-Path $local ('external-postgres-inventory\' + $RetainedExternalPgRun + '\pls_trading\columns.tsv')),"a`t b")
        [System.IO.File]::WriteAllText((Join-Path $srp 'delete-me.txt'),'legacy')
        [System.IO.File]::WriteAllText((Join-Path $asrp 'delete-me.txt'),'legacy')
        [System.IO.File]::WriteAllText((Join-Path $local 'delete-me.txt'),'legacy')
        $syntheticQ2 = Get-Sha256 -Path (Join-Path $asrp 'source\development\research_2025q2\Kraken_OHLCVT_Q2_2025.zip')
        $oldExecute=[bool]$Execute;$oldSkip=[bool]$SkipFreeSpaceCheck;$oldExpected=$ExpectedQ2Sha256
        try {$script:Execute=$true;$script:SkipFreeSpaceCheck=$true;$script:ExpectedQ2Sha256=$syntheticQ2;Invoke-CfaMigration -Docs $docs -External $ext}
        finally {$script:Execute=$oldExecute;$script:SkipFreeSpaceCheck=$oldSkip;$script:ExpectedQ2Sha256=$oldExpected}
        if(Test-Path -LiteralPath $srp){throw 'Self-test: SRP was not deleted.'}
        if(Test-Path -LiteralPath $asrp){throw 'Self-test: ASRP was not deleted.'}
        if(Test-Path -LiteralPath $local){throw 'Self-test: CFA-local was not deleted.'}
        if(-not(Test-Path -LiteralPath (Join-Path $cfa 'marker.txt') -PathType Leaf)){throw 'Self-test: CFA repo marker missing.'}
        if(-not(Test-Path -LiteralPath (Join-Path $ext 'CFA-bulk\source\kraken\Kraken_OHLCVT_Q2_2025.zip') -PathType Leaf)){throw 'Self-test: Q2 destination missing.'}
        if(-not(Test-Path -LiteralPath (Join-Path $ext 'CFA-bulk\source\gdelt-gkg-q2-2025\archives\2025\04\01\a.zip') -PathType Leaf)){throw 'Self-test: GDELT destination missing.'}
        $expected=@([pscustomobject]@{relative_path='x';size_bytes=1;sha256='a'});$observed=@([pscustomobject]@{relative_path='x';size_bytes=1;sha256='b'});$caught=$false
        try{Compare-Manifests -Expected $expected -Observed $observed -Label 'CorruptionTest'}catch{$caught=$true}
        if(-not $caught){throw 'Self-test: manifest corruption was not rejected.'}
        Write-Host 'SELFTEST: PASS'
    } finally { if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue} }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
if ([string]::IsNullOrWhiteSpace($DocumentsRoot)) { $DocumentsRoot=[Environment]::GetFolderPath('MyDocuments');if([string]::IsNullOrWhiteSpace($DocumentsRoot)){$DocumentsRoot=Join-Path $HOME 'Documents'} }
if (-not (Test-Path -LiteralPath $ExternalDriveRoot -PathType Container)) { throw "External drive root not found: $ExternalDriveRoot" }
Invoke-CfaMigration -Docs $DocumentsRoot -External $ExternalDriveRoot
