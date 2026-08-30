#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ArchiveRoot = 'D:\CFA-bulk\source\gdelt-gkg-q2-2025',
    [string]$OutputRoot = '',
    [ValidateRange(1,64)][int]$WorkerCount = [Math]::Max(1,[Environment]::ProcessorCount),
    [ValidateRange(1,50)][int]$MaxSamplesPerAlias = 10,
    [switch]$KeepWorkerFiles,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedArchives = 7163
$ExpectedRows = 9183757L
$ExpectedMalformedRows = 5L
$ExpectedAliasRegistrySha256 = '11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $p = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Csv {
    param([object]$Value)
    $s = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($s.Contains('"')) { $s = $s.Replace('"','""') }
    if ($s.Contains(',') -or $s.Contains('"') -or $s.Contains("`r") -or $s.Contains("`n")) { return '"' + $s + '"' }
    return $s
}
function Write-CsvRow {
    param([IO.StreamWriter]$Writer,[object[]]$Values)
    $Writer.WriteLine((@($Values | ForEach-Object { Csv $_ }) -join ','))
}
function Quote-Arg {
    param([string]$Value)
    return '"' + $Value.Replace('"','\"') + '"'
}
function Get-ArchiveFiles {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "GDELT archive root missing: $Root" }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.gkg.csv.zip' | Where-Object { $_.Name -match '^\d{14}\.gkg\.csv\.zip$' } | Sort-Object Name)
}
function Get-WorkerRanges {
    param([int]$Count,[int]$Workers)
    $actual = [Math]::Min($Count,[Math]::Max(1,$Workers))
    $ranges = New-Object System.Collections.ArrayList
    $base = [Math]::Floor($Count / $actual)
    $extra = $Count % $actual
    $start = 0
    for ($i=0; $i -lt $actual; $i++) {
        $size = [int]$base + $(if ($i -lt $extra) { 1 } else { 0 })
        $end = $start + $size - 1
        [void]$ranges.Add([pscustomobject]@{id=$i;start=$start;end=$end;count=$size})
        $start = $end + 1
    }
    return @($ranges.ToArray())
}
function Get-WorkerDir {
    param([string]$WorkersRoot,[int]$Id)
    return Join-Path $WorkersRoot ('worker-{0:00}' -f $Id)
}
function Test-WorkerComplete {
    param([string]$WorkersRoot,[object]$Range)
    $dir = Get-WorkerDir $WorkersRoot ([int]$Range.id)
    $summaryPath = Join-Path $dir 'worker-summary.json'
    foreach ($path in @($summaryPath,(Join-Path $dir 'matches.csv'),(Join-Path $dir 'rejects.csv'),(Join-Path $dir 'samples.csv'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $path).Length -le 0) { return $false }
    }
    try { $s = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json } catch { return $false }
    if ([int]$s.worker_id -ne [int]$Range.id) { return $false }
    if ([int]$s.start_index -ne [int]$Range.start) { return $false }
    if ([int]$s.end_index -ne [int]$Range.end) { return $false }
    if ([int]$s.archive_count -ne [int]$Range.count) { return $false }
    return $true
}
function Find-ActiveWorkerProcess {
    param([string]$WorkerScript,[string]$WorkerDir,[int]$WorkerId)
    $needleScript = [IO.Path]::GetFileName($WorkerScript)
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $cmd = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        if ($cmd.IndexOf($needleScript,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($cmd.IndexOf($WorkerDir,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($cmd.IndexOf(('-WorkerId ' + $WorkerId),[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        return [int]$p.ProcessId
    }
    return 0
}
function Copy-BodyLines {
    param([string]$Source,[IO.StreamWriter]$Destination)
    $reader = New-Object IO.StreamReader $Source
    try {
        [void]$reader.ReadLine()
        while (($line = $reader.ReadLine()) -ne $null) { $Destination.WriteLine($line) }
    }
    finally { $reader.Dispose() }
}
function Merge-Workers {
    param([string]$WorkersRoot,[object[]]$Ranges,[string]$FinalRoot,[int]$SampleCap)
    $matchPath = Join-Path $FinalRoot 'stage3-news-matches.csv'
    $rejectPath = Join-Path $FinalRoot 'stage3-context-rejects.csv'
    $samplePath = Join-Path $FinalRoot 'stage3-match-samples.csv'
    $utf8 = New-Object Text.UTF8Encoding($false)
    $mw = New-Object IO.StreamWriter -ArgumentList $matchPath,$false,$utf8
    $rw = New-Object IO.StreamWriter -ArgumentList $rejectPath,$false,$utf8
    $sw = New-Object IO.StreamWriter -ArgumentList $samplePath,$false,$utf8
    Write-CsvRow $mw @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons')
    Write-CsvRow $rw @('base_asset_id','alias_text','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_surfaces','context_reason')
    Write-CsvRow $sw @('match_status','base_asset_id','alias_text','requires_crypto_context','record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','matched_surfaces','econ_bitcoin_theme','title_crypto_anchor','context_reason')
    $seen = New-Object 'Collections.Generic.HashSet[string]'
    $matchedAssets = New-Object 'Collections.Generic.HashSet[string]'
    $sampleCount = @{}
    [long]$matchRows = 0
    [long]$crossWorkerDuplicates = 0
    try {
        foreach ($range in @($Ranges | Sort-Object id)) {
            $dir = Get-WorkerDir $WorkersRoot ([int]$range.id)
            foreach ($r in @(Import-Csv -LiteralPath (Join-Path $dir 'matches.csv'))) {
                $key = [string]$r.base_asset_id + '|' + [string]$r.record_id
                if (-not $seen.Add($key)) { $crossWorkerDuplicates++; continue }
                [void]$matchedAssets.Add([string]$r.base_asset_id)
                Write-CsvRow $mw @($r.base_asset_id,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.archive_file,$r.row_ordinal,$r.matched_aliases,$r.matched_surfaces,$r.context_reasons)
                $matchRows++
            }
            Copy-BodyLines -Source (Join-Path $dir 'rejects.csv') -Destination $rw
            foreach ($r in @(Import-Csv -LiteralPath (Join-Path $dir 'samples.csv'))) {
                $key = [string]$r.base_asset_id + '|' + ([string]$r.alias_text).ToLowerInvariant() + '|' + [string]$r.match_status
                if (-not $sampleCount.ContainsKey($key)) { $sampleCount[$key] = 0 }
                if ([int]$sampleCount[$key] -ge $SampleCap) { continue }
                Write-CsvRow $sw @($r.match_status,$r.base_asset_id,$r.alias_text,$r.requires_crypto_context,$r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.page_title,$r.matched_surfaces,$r.econ_bitcoin_theme,$r.title_crypto_anchor,$r.context_reason)
                $sampleCount[$key] = [int]$sampleCount[$key] + 1
            }
        }
    }
    finally { $mw.Dispose(); $rw.Dispose(); $sw.Dispose() }
    return [pscustomobject]@{match_rows=$matchRows;cross_worker_duplicates=$crossWorkerDuplicates;matched_assets=$matchedAssets.Count;matches_path=$matchPath;rejects_path=$rejectPath;samples_path=$samplePath}
}
function Get-FailureText {
    param([string]$Dir)
    $out = if (Test-Path -LiteralPath (Join-Path $Dir 'stdout.log')) { Get-Content -LiteralPath (Join-Path $Dir 'stdout.log') -Raw } else { '' }
    $err = if (Test-Path -LiteralPath (Join-Path $Dir 'stderr.log')) { Get-Content -LiteralPath (Join-Path $Dir 'stderr.log') -Raw } else { '' }
    return ($out + [Environment]::NewLine + $err).Trim()
}
function Invoke-SelfTest {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('cfa-s3-v2r1-' + [guid]::NewGuid().ToString('N'))
    try {
        $workers = Join-Path $root '_workers'; $final = Join-Path $root 'final'
        New-Item -ItemType Directory -Path $workers,$final -Force | Out-Null
        $ranges = @([pscustomobject]@{id=0;start=0;end=1;count=2},[pscustomobject]@{id=1;start=2;end=3;count=2})
        for ($i=0; $i -lt 2; $i++) {
            $d = Get-WorkerDir $workers $i; New-Item -ItemType Directory -Path $d -Force | Out-Null
            $m = @('base_asset_id,record_id,gdelt_date_utc,source_common_name,document_identifier,archive_file,row_ordinal,matched_aliases,matched_surfaces,context_reasons')
            if ($i -eq 0) { $m += @('A,1,d,s,u,a,1,x,ALLNAMES,NOT_REQUIRED','B,2,d,s,u,a,2,y,PAGE_TITLE,NOT_REQUIRED') } else { $m += @('A,1,d,s,u,b,1,x,ALLNAMES,NOT_REQUIRED','C,3,d,s,u,b,2,z,PAGE_TITLE,NOT_REQUIRED') }
            [IO.File]::WriteAllLines((Join-Path $d 'matches.csv'),$m)
            [IO.File]::WriteAllLines((Join-Path $d 'rejects.csv'),@('base_asset_id,alias_text,record_id,gdelt_date_utc,source_common_name,document_identifier,archive_file,row_ordinal,matched_surfaces,context_reason',("R$i,x,$i,d,s,u,a,1,ALLNAMES,NONE")))
            [IO.File]::WriteAllLines((Join-Path $d 'samples.csv'),@('match_status,base_asset_id,alias_text,requires_crypto_context,record_id,gdelt_date_utc,source_common_name,document_identifier,page_title,matched_surfaces,econ_bitcoin_theme,title_crypto_anchor,context_reason',("MATCH,A,x,False,$i,d,s,u,t,ALLNAMES,False,False,NOT_REQUIRED")))
            $r = $ranges[$i]
            $summary = [ordered]@{worker_id=$i;start_index=$r.start;end_index=$r.end;archive_count=$r.count;rows_scanned=10;malformed_field_count_rows=0;missing_critical_rows=0;malformed_entity_blocks=0;alias_candidates=1;accepted_alias_hits=1;rejected_context_alias_hits=1;partial_unique_matches=2;partial_duplicate_matches=0;partial_matched_assets=2}
            Write-Utf8NoBom (Join-Path $d 'worker-summary.json') (($summary | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
            if (-not (Test-WorkerComplete $workers $r)) { throw "worker completion contract $i" }
        }
        $merged = Merge-Workers $workers $ranges $final 1
        if ($merged.match_rows -ne 3 -or $merged.cross_worker_duplicates -ne 1) { throw 'deterministic merge dedupe' }
        if (@(Import-Csv $merged.samples_path).Count -ne 1) { throw 'global sample cap' }
        $text = Get-Content -LiteralPath $PSCommandPath -Raw
        if ($text -match '\.ExitCode') { throw 'R1 must not depend on Process.ExitCode' }
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $ArchiveRoot = (Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw 'OutputRoot is required for R1 so completed worker outputs can be resumed safely.' }
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    $workerScript = Join-Path $PSScriptRoot 'Run-CfaStage3NewsMatchingParallelV2.ps1'
    if (-not (Test-Path -LiteralPath $workerScript -PathType Leaf)) { throw 'Stage 3 V2 worker script is missing.' }
    $builder = Join-Path $PSScriptRoot 'Build-CfaStage3NewsAliases.ps1'
    $global:LASTEXITCODE = $null; & $builder -RepoRoot $RepoRoot
    $buildCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($buildCode -ne 0) { throw "S3-ID-01 alias build failed with exit $buildCode." }
    $global:LASTEXITCODE = 0
    $aliasPath = Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if ((Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedAliasRegistrySha256) { throw 'Alias registry SHA-256 differs from frozen Stage 3 registry.' }

    $files = Get-ArchiveFiles $ArchiveRoot
    if ($files.Count -ne $ExpectedArchives) { throw "Expected $ExpectedArchives GKG archives; observed $($files.Count)." }
    $ranges = @(Get-WorkerRanges $files.Count $WorkerCount)
    $workersRoot = Join-Path $OutputRoot '_workers'
    New-Item -ItemType Directory -Path $workersRoot -Force | Out-Null

    $reused = New-Object System.Collections.ArrayList
    $running = New-Object System.Collections.ArrayList
    $launched = New-Object System.Collections.ArrayList
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    foreach ($range in $ranges) {
        $dir = Get-WorkerDir $workersRoot ([int]$range.id)
        if (Test-WorkerComplete $workersRoot $range) { [void]$reused.Add([int]$range.id); continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $activePid = Find-ActiveWorkerProcess $workerScript $dir ([int]$range.id)
        if ($activePid -gt 0) { [void]$running.Add([pscustomobject]@{pid=$activePid;range=$range;dir=$dir}); continue }
        $stdout = Join-Path $dir 'stdout.log'; $stderr = Join-Path $dir 'stderr.log'
        $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-Arg $workerScript),'-WorkerMode','-RepoRoot',(Quote-Arg $RepoRoot),'-ArchiveRoot',(Quote-Arg $ArchiveRoot),'-OutputRoot',(Quote-Arg $dir),'-WorkerId',[string]$range.id,'-WorkerStart',[string]$range.start,'-WorkerEnd',[string]$range.end,'-MaxSamplesPerAlias',[string]$MaxSamplesPerAlias)
        $p = Start-Process -FilePath $exe -ArgumentList $args -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        [void]$launched.Add([pscustomobject]@{process=$p;range=$range;dir=$dir})
    }

    Write-Host ("Stage 3 V2 R1: workers={0} reused={1} already_running={2} launched={3}" -f $ranges.Count,$reused.Count,$running.Count,$launched.Count)

    foreach ($item in @($running.ToArray())) {
        Wait-Process -Id ([int]$item.pid) -ErrorAction SilentlyContinue
        if (-not (Test-WorkerComplete $workersRoot $item.range)) { throw "Existing worker $($item.range.id) ended without a complete worker contract.`n$(Get-FailureText $item.dir)" }
    }
    foreach ($item in @($launched.ToArray())) {
        $item.process.WaitForExit()
        if (-not (Test-WorkerComplete $workersRoot $item.range)) { throw "Worker $($item.range.id) ended without a complete worker contract.`n$(Get-FailureText $item.dir)" }
    }
    foreach ($range in $ranges) { if (-not (Test-WorkerComplete $workersRoot $range)) { throw "Worker $($range.id) is incomplete after R1 orchestration." } }

    [long]$total=0;[long]$malformed=0;[long]$missing=0;[long]$blocks=0;[long]$candidates=0;[long]$accepted=0;[long]$rejected=0;[long]$localDuplicates=0
    foreach ($range in $ranges) {
        $dir = Get-WorkerDir $workersRoot ([int]$range.id)
        $ws = Get-Content -LiteralPath (Join-Path $dir 'worker-summary.json') -Raw | ConvertFrom-Json
        $total += [long]$ws.rows_scanned; $malformed += [long]$ws.malformed_field_count_rows; $missing += [long]$ws.missing_critical_rows; $blocks += [long]$ws.malformed_entity_blocks
        $candidates += [long]$ws.alias_candidates; $accepted += [long]$ws.accepted_alias_hits; $rejected += [long]$ws.rejected_context_alias_hits; $localDuplicates += [long]$ws.partial_duplicate_matches
    }
    $merge = Merge-Workers $workersRoot $ranges $OutputRoot $MaxSamplesPerAlias
    $duplicates = $localDuplicates + [long]$merge.cross_worker_duplicates
    $shapeGate = if ($total -eq $ExpectedRows -and $malformed -eq $ExpectedMalformedRows -and $missing -eq 0) { 'PASS' } else { 'FAIL' }
    $runGate = if ($shapeGate -eq 'PASS' -and $duplicates -eq 0) { 'PASS' } else { 'FAIL' }
    $summary = [ordered]@{
        run_status=$runGate; implementation='parallel-v2-precision-hardened-r1'; worker_count=$ranges.Count; matching_contract='CANDIDATE_V2'; reused_workers=$reused.Count; already_running_workers=$running.Count; launched_workers=$launched.Count
        gates=[ordered]@{'S3-ID-01'='PASS';'CFA-S3-002'=$shapeGate;'CFA-S3-003'='PASS';'CFA-S3-004'=$runGate;'CFA-S3-005'='UNVERIFIED';'CFA-S3-006'='BLOCKED'}
        source=[ordered]@{archive_root=$ArchiveRoot;archive_files=$files.Count;rows_scanned=$total;malformed_field_count_rows=$malformed;missing_critical_rows=$missing;malformed_entity_blocks=$blocks}
        matching=[ordered]@{news_assets=431;alias_rows=470;alias_candidates=$candidates;accepted_alias_hits=$accepted;rejected_context_alias_hits=$rejected;unique_asset_record_matches=$merge.match_rows;matched_assets=$merge.matched_assets;duplicate_asset_record_matches=$duplicates}
        output=[ordered]@{matches_path=$merge.matches_path;matches_sha256=(Get-FileHash $merge.matches_path -Algorithm SHA256).Hash.ToLowerInvariant();rejects_path=$merge.rejects_path;rejects_sha256=(Get-FileHash $merge.rejects_path -Algorithm SHA256).Hash.ToLowerInvariant();samples_path=$merge.samples_path;samples_sha256=(Get-FileHash $merge.samples_path -Algorithm SHA256).Hash.ToLowerInvariant();alias_registry_sha256=(Get-FileHash $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    Write-Utf8NoBom (Join-Path $OutputRoot 'stage3-match-summary.json') (($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    if (-not $KeepWorkerFiles) { foreach ($range in $ranges) { $d=Get-WorkerDir $workersRoot ([int]$range.id); foreach ($name in @('matches.csv','rejects.csv','samples.csv')) { Remove-Item -LiteralPath (Join-Path $d $name) -Force -ErrorAction SilentlyContinue } } }

    Write-Host ''
    Write-Host 'CFA STAGE 3 V2 R1 PARALLEL KRAKEN / GDELT NEWS MATCHING: COMPLETE'
    Write-Host ("Workers: {0} | reused: {1} | already running: {2} | launched: {3}" -f $ranges.Count,$reused.Count,$running.Count,$launched.Count)
    Write-Host ("Rows scanned: {0}" -f $total)
    Write-Host ("Unique asset/record matches: {0}" -f $merge.match_rows)
    Write-Host ("Matched assets: {0} of 431" -f $merge.matched_assets)
    Write-Host ("Context rejects: {0}" -f $rejected)
    Write-Host ("CFA-S3-004 full Q2 matching run: {0}" -f $runGate)
    Write-Host 'CFA-S3-005 bounded sample review: UNVERIFIED'
    Write-Host 'CFA-S3-006 freeze news matching: BLOCKED'
    Write-Host ("Evidence directory: {0}" -f $OutputRoot)
    if ($runGate -ne 'PASS') { exit 2 }
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V2 R1 PARALLEL KRAKEN / GDELT NEWS MATCHING: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
