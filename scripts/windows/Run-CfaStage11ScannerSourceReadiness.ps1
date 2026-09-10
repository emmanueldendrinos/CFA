#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage5CandidateReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage10RunReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage10ValidationReceiptPath,
    [string]$PgHost='localhost',
    [ValidateRange(1,65535)][int]$PgPort=5432,
    [string]$PgUser='postgres',
    [ValidateRange(60,1800)][int]$StatementTimeoutSeconds=900,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage10RunSha='5736a74a5d20021b88589e066ad0a98b3ea7efc5d346c3413e2298b7c007bf34'
$ExpectedStage10ValidationSha='5f65a24eebbe386dfed2ac840ff0cd730b3b8eb0b17b2ff05e34e70a4a050c85'
$ExpectedStage10ProfileSha='2d625ed8a79f17cf2a6ac21e22fea62fa3a1a04f9cfa51d9b0ec7ef861e304fd'
$ExpectedStage5FactorSha='c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b'
$ExpectedAf001Sha='569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedMarketRows=14055089L
$ExpectedMarketPairs=1058
$ExpectedDirectUsd=434
$ExpectedScannerAssets=418
$ExpectedStage3Rows=22060
$ExpectedStage3Assets=282
$ExpectedStage3Records=18503
$ExpectedSourceSlots=8736
$ExpectedDownloadedSlots=7163
$ExpectedProviderMissingSlots=1573
$Q2Start=[datetime]::SpecifyKind([datetime]'2025-04-01T00:00:00',[DateTimeKind]::Utc)
$Q2End=[datetime]::SpecifyKind([datetime]'2025-07-01T00:00:00',[DateTimeKind]::Utc)
$FirstCandidateScan=$Q2Start.AddHours(24).AddMinutes(15)

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath

function Get-S11Sha {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Require-S11File {param([string]$Path,[string]$Label);$p=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "$Label is not a file: $p"};return $p}
function Write-S11Json {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 12)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}
function Format-S11Utc {param([datetime]$Value);return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)}
function Parse-S11Bool {param([object]$Value,[string]$Label);$x=([string]$Value).Trim().ToLowerInvariant();if($x-in@('true','t')){return $true};if($x-in@('false','f')){return $false};throw "Malformed boolean for ${Label}: '$Value'"}
function Require-S11Columns {param([object]$Row,[string[]]$Names,[string]$Label);$props=@($Row.PSObject.Properties.Name);foreach($name in $Names){if($props-notcontains$name){throw "$Label required column missing: $name"}}}
function Parse-S11Batch {param([string]$RecordId);$m=[regex]::Match($RecordId,'^(?<batch>\d{14})-(?:T)?\d+$',[Text.RegularExpressions.RegexOptions]::CultureInvariant);if(-not$m.Success){throw "Malformed GKG record_id: $RecordId"};$dt=[datetime]::MinValue;if(-not[datetime]::TryParseExact($m.Groups['batch'].Value,'yyyyMMddHHmmss',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$dt)){throw "Unparseable GKG batch: $RecordId"};return [datetime]::SpecifyKind($dt,[DateTimeKind]::Utc)}

function Find-S11Psql {
    $cmd=Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if($null-ne$cmd){return $cmd.Source}
    $found=@(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue|Sort-Object FullName -Descending)
    if($found.Count-eq0){throw 'psql.exe could not be found.'};return $found[0].FullName
}
function Invoke-S11PsqlText {param([string]$PsqlExe,[string]$Database,[string]$Sql);$err=[IO.Path]::GetTempFileName();try{$out=@(& $PsqlExe -X -h $PgHost -p $PgPort -U $PgUser -d $Database -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2>$err);$code=$LASTEXITCODE;$stderr=if(Test-Path -LiteralPath $err){(Get-Content -LiteralPath $err -ErrorAction SilentlyContinue)-join[Environment]::NewLine}else{''};$text=($out|ForEach-Object{if($null-ne$_){[string]$_}})-join[Environment]::NewLine;if($code-ne0){throw "psql failed for database '$Database' (exit $code).`n$stderr`n$text"};return $text}finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}}
function Invoke-S11PsqlCsv {param([string]$PsqlExe,[string]$Database,[string]$Query);$q=$Query.Trim();while($q.EndsWith(';')){$q=$q.Substring(0,$q.Length-1).TrimEnd()};return Invoke-S11PsqlText $PsqlExe $Database "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"}
function Convert-S11CsvText {param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text|ConvertFrom-Csv)}

function Measure-S11NewsWindow {
    param([datetime]$Scan,[int]$Hours,[hashtable]$Slots)
    $expected=$Hours*4;$end=$Scan.AddMinutes(-15);$start=$end.AddHours(-$Hours);$downloaded=0;$providerMissing=0;$missing=0;$other=0
    for($i=0;$i-lt$expected;$i++){$t=$start.AddMinutes(15*$i);$key=$t.ToString('yyyyMMddHHmmss',$Invariant);if(-not$Slots.ContainsKey($key)){$missing++;continue};$status=[string]$Slots[$key].status;if($status-ceq'downloaded'){$downloaded++}elseif($status-ceq'provider_missing'){$providerMissing++}else{$other++}}
    $complete=($downloaded-eq$expected-and$providerMissing-eq0-and$missing-eq0-and$other-eq0)
    return [pscustomobject]@{complete=$complete;downloaded=$downloaded;provider_missing=$providerMissing;registry_missing=$missing;other=$other;batch_start=$start;batch_end=$end}
}

function Invoke-S11SelfTest {
    $slots=@{};$start=[datetime]::SpecifyKind([datetime]'2025-04-01T00:00:00',[DateTimeKind]::Utc)
    for($i=0;$i-lt96;$i++){$t=$start.AddMinutes(15*$i);$slots[$t.ToString('yyyyMMddHHmmss',$Invariant)]=[pscustomobject]@{status='downloaded'}}
    $scan=$start.AddDays(1).AddMinutes(15);$w=Measure-S11NewsWindow $scan 24 $slots
    if(-not$w.complete-or$w.downloaded-ne96-or(Format-S11Utc $w.batch_start)-ne'2025-04-01T00:00:00Z'-or(Format-S11Utc $w.batch_end)-ne'2025-04-02T00:00:00Z'){throw '24h scan-window self-test failed.'}
    $b=Parse-S11Batch '20250401121500-T7';if((Format-S11Utc $b)-ne'2025-04-01T12:15:00Z'){throw 'GKG batch parser self-test failed.'}
    $slots['20250401000000']=[pscustomobject]@{status='provider_missing'};$w2=Measure-S11NewsWindow $scan 24 $slots;if($w2.complete-or$w2.provider_missing-ne1){throw 'Incomplete source-window self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-S11SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

$oldPassword=$env:PGPASSWORD;$oldOptions=$env:PGOPTIONS;$bstr=[IntPtr]::Zero
try {
    $contractPath=Require-S11File (Join-Path $RepoRoot 'docs\evidence\stage11-scanner-source-readiness-contract.md') 'Stage 11 source-readiness contract'
    $contract=Get-Content -LiteralPath $contractPath -Raw
    foreach($marker in @('A_NEWS(r) = B(r) + 15 minutes','15 minutes','60 minutes','240 minutes','SCANNER_IMPLEMENTATION_BLOCKED')){if($contract-notmatch[regex]::Escape($marker)){throw "Stage 11 contract marker missing: $marker"}}
    $stage10Contract=Get-Content -LiteralPath (Require-S11File (Join-Path $RepoRoot 'docs\evidence\stage10-symbol-heterogeneity-contract.md') 'Stage 10 contract') -Raw
    if($stage10Contract-notmatch'STAGE10_FROZEN'-or$stage10Contract-notmatch'CFA-S10-008'){throw 'Frozen Stage 10 repository markers missing.'}

    $Stage10RunReceiptPath=Require-S11File $Stage10RunReceiptPath 'Stage 10 run receipt';if((Get-S11Sha $Stage10RunReceiptPath)-ne$ExpectedStage10RunSha){throw 'Stage 10 run receipt SHA mismatch.'}
    $Stage10ValidationReceiptPath=Require-S11File $Stage10ValidationReceiptPath 'Stage 10 independent-validation receipt';if((Get-S11Sha $Stage10ValidationReceiptPath)-ne$ExpectedStage10ValidationSha){throw 'Stage 10 validation receipt SHA mismatch.'}
    $s10=Get-Content -LiteralPath $Stage10RunReceiptPath -Raw|ConvertFrom-Json
    if([string]$s10.stage-ne'CFA_STAGE_10'-or[string]$s10.run-ne'SYMBOL_HETEROGENEITY_V1'){throw 'Stage 10 run receipt identity mismatch.'}
    $profilePath=Require-S11File ([string]$s10.outputs.symbol_profile_summary) 'Stage 10 symbol profile';if((Get-S11Sha $profilePath)-ne$ExpectedStage10ProfileSha){throw 'Stage 10 profile SHA mismatch.'}
    $profile=@(Import-Csv -LiteralPath $profilePath);if($profile.Count-ne$ExpectedScannerAssets){throw "Stage 10 profile asset count mismatch: $($profile.Count)"};Require-S11Columns $profile[0] @('base_asset_id') 'Stage 10 profile';$scannerAssets=@($profile|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique);if($scannerAssets.Count-ne$ExpectedScannerAssets){throw 'Stage 10 profile contains duplicate/missing assets.'}

    $Stage5CandidateReceiptPath=Require-S11File $Stage5CandidateReceiptPath 'Stage 5 candidate factor receipt';$s5=Get-Content -LiteralPath $Stage5CandidateReceiptPath -Raw|ConvertFrom-Json
    if([string]$s5.status-ne'VALIDATION_CANDIDATE'-or[string]$s5.stage-ne'CFA_STAGE_5'){throw 'Stage 5 candidate receipt identity mismatch.'}
    $factorPath=Require-S11File ([string]$s5.outputs.factor_csv) 'Frozen Stage 5 factor CSV';if((Get-S11Sha $factorPath)-ne$ExpectedStage5FactorSha-or[string]$s5.outputs.factor_csv_sha256-ne$ExpectedStage5FactorSha){throw 'Stage 5 frozen factor hash does not reconcile candidate receipt.'}
    $matchesPath=Require-S11File ([string]$s5.sources.stage3_matches_path) 'Stage 3 V6 matches';$matchesSha=Get-S11Sha $matchesPath;if($matchesSha-ne([string]$s5.sources.stage3_matches_sha256).ToLowerInvariant()){throw 'Stage 3 matches hash does not match Stage 5 receipt.'}
    $batchPath=Require-S11File ([string]$s5.sources.batch_timing_receipt_path) 'GDELT batch timing receipt';if((Get-S11Sha $batchPath)-ne([string]$s5.sources.batch_timing_receipt_sha256).ToLowerInvariant()){throw 'Batch timing receipt hash mismatch.'}
    $slotsPath=Require-S11File ([string]$s5.sources.source_slots_path) 'GDELT source slots';if((Get-S11Sha $slotsPath)-ne([string]$s5.sources.source_slots_sha256).ToLowerInvariant()){throw 'Source-slot registry hash mismatch.'}
    $batchReceipt=Get-Content -LiteralPath $batchPath -Raw|ConvertFrom-Json
    if([string]$batchReceipt.status-ne'PASS'-or[string]$batchReceipt.policy-ne'GDELT_RECORD_BATCH_PLUS_ONE_HEARTBEAT'-or[int]$batchReceipt.availability_lag_minutes-ne15){throw 'Batch timing policy is not the frozen lag-15 policy.'}
    if([string]$batchReceipt.sources.stage3_matches_sha256-ne$matchesSha){throw 'Batch timing receipt does not bind the current Stage 3 match file.'}

    $matches=@(Import-Csv -LiteralPath $matchesPath);if($matches.Count-ne$ExpectedStage3Rows){throw "Stage 3 match row count mismatch: $($matches.Count)"};Require-S11Columns $matches[0] @('base_asset_id','record_id','gdelt_date_utc','source_common_name','document_identifier','archive_file','row_ordinal','matched_aliases','matched_surfaces','context_reasons') 'Stage 3 V6 matches'
    $matchAssets=@($matches|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique);$matchRecords=@($matches|ForEach-Object{[string]$_.record_id}|Sort-Object -Unique);if($matchAssets.Count-ne$ExpectedStage3Assets-or$matchRecords.Count-ne$ExpectedStage3Records){throw "Stage 3 V6 shape mismatch: assets=$($matchAssets.Count), records=$($matchRecords.Count)"}
    $misaligned=0;$outOfQ2=0
    foreach($row in $matches){$batch=Parse-S11Batch ([string]$row.record_id);if(($batch.Minute%15)-ne0-or$batch.Second-ne0){$misaligned++};if($batch-lt$Q2Start-or$batch-ge$Q2End){$outOfQ2++}}
    if($misaligned-ne0-or$outOfQ2-ne0){throw "Stage 3 batch timing mismatch: misaligned=$misaligned out_of_q2=$outOfQ2"}

    $slotRows=@(Import-Csv -LiteralPath $slotsPath);if($slotRows.Count-ne$ExpectedSourceSlots){throw "Source-slot count mismatch: $($slotRows.Count)"};Require-S11Columns $slotRows[0] @('slot_key','status') 'GDELT source slots'
    $slotMap=@{};$downloaded=0;$providerMissing=0;$otherStatus=0
    foreach($row in $slotRows){$key=([string]$row.slot_key).Trim();if($key-notmatch'^\d{14}$'){throw "Malformed source slot key: $key"};if($slotMap.ContainsKey($key)){throw "Duplicate source slot key: $key"};$slotMap[$key]=$row;$status=[string]$row.status;if($status-ceq'downloaded'){$downloaded++}elseif($status-ceq'provider_missing'){$providerMissing++}else{$otherStatus++}}
    if($downloaded-ne$ExpectedDownloadedSlots-or$providerMissing-ne$ExpectedProviderMissingSlots-or$otherStatus-ne0){throw "Source-slot status partition mismatch: downloaded=$downloaded provider_missing=$providerMissing other=$otherStatus"}

    $afPath=Require-S11File (Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv') 'AF-001';if((Get-S11Sha $afPath)-ne$ExpectedAf001Sha){throw 'AF-001 SHA mismatch.'};$af=@(Import-Csv -LiteralPath $afPath);Require-S11Columns $af[0] @('source_member_ordinal','base_asset_id','quote_exchange_symbol','research_eligible') 'AF-001'
    $directUsd=@($af|Where-Object{(Parse-S11Bool $_.research_eligible 'AF-001 research_eligible')-and([string]$_.quote_exchange_symbol).Trim()-ceq'USD'});if($directUsd.Count-ne$ExpectedDirectUsd){throw "Direct-USD mapping count mismatch: $($directUsd.Count)"};$usdByBase=@{};foreach($row in $directUsd){$base=[string]$row.base_asset_id;if($usdByBase.ContainsKey($base)){throw "Duplicate direct-USD base: $base"};$ordinal=([string]$row.source_member_ordinal).Trim();if($ordinal-notmatch'^\d+$'){throw "Non-numeric source_member_ordinal for ${base}: $ordinal"};$usdByBase[$base]=$row}
    $assetSqlRows=New-Object System.Collections.ArrayList
    foreach($asset in $scannerAssets){if(-not$usdByBase.ContainsKey($asset)){throw "Stage 10 scanner asset lacks frozen direct-USD mapping: $asset"};$escaped=$asset.Replace("'","''");[void]$assetSqlRows.Add("("+([string]$usdByBase[$asset].source_member_ordinal).Trim()+",'"+$escaped+"')")}
    $assetValues=$assetSqlRows.ToArray()-join','

    $newsRows=New-Object System.Collections.ArrayList;$complete24=0;$complete6=0;$completeBoth=0;$first24=$null;$last24=$null;$first6=$null;$last6=$null
    for($scan=$FirstCandidateScan;$scan-lt$Q2End;$scan=$scan.AddMinutes(15)){$w24=Measure-S11NewsWindow $scan 24 $slotMap;$w6=Measure-S11NewsWindow $scan 6 $slotMap;if($w24.complete){$complete24++;if($null-eq$first24){$first24=$scan};$last24=$scan};if($w6.complete){$complete6++;if($null-eq$first6){$first6=$scan};$last6=$scan};if($w24.complete-and$w6.complete){$completeBoth++};[void]$newsRows.Add([pscustomobject][ordered]@{scan_timestamp_utc=Format-S11Utc $scan;news24_complete=$w24.complete;news24_downloaded_slots=$w24.downloaded;news24_provider_missing_slots=$w24.provider_missing;news24_registry_missing_slots=$w24.registry_missing;news6_complete=$w6.complete;news6_downloaded_slots=$w6.downloaded;news6_provider_missing_slots=$w6.provider_missing;news6_registry_missing_slots=$w6.registry_missing})}
    $candidateScans=$newsRows.Count

    $psql=Find-S11Psql
    $secure=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString;$bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $env:PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000)"
    $version=(Invoke-S11PsqlText $psql 'asrp' 'SHOW server_version;').Trim();$readOnly=(Invoke-S11PsqlText $psql 'asrp' "SELECT current_setting('default_transaction_read_only');").Trim();if($readOnly-ne'on'){throw "PostgreSQL session is not read-only: $readOnly"}
    $schema=@(Convert-S11CsvText (Invoke-S11PsqlCsv $psql 'asrp' "SELECT ordinal_position,column_name,data_type,udt_name FROM information_schema.columns WHERE table_schema='asrp' AND table_name='q2_market_1m_observations' ORDER BY ordinal_position"));if($schema.Count-ne19){throw "Market schema column count mismatch: $($schema.Count)"};$schemaBy=@{};foreach($c in $schema){$schemaBy[[string]$c.column_name]=$c};foreach($name in @('source_member_ordinal','pair_token_opaque','physical_record_number','raw_record_sha256','candle_start_utc','open_price','high_price','low_price','close_price','canonical_eligible','in_source_window','minute_aligned','quality_flags','duplicate_class')){if(-not$schemaBy.ContainsKey($name)){throw "Market schema missing: $name"}};if([string]$schemaBy['candle_start_utc'].data_type-ne'timestamp with time zone'){throw 'Market candle_start_utc is not timestamptz.'}
    $marketCard=@(Convert-S11CsvText (Invoke-S11PsqlCsv $psql 'asrp' "SELECT count(*)::bigint AS row_count,count(DISTINCT pair_token_opaque)::int AS pair_count,min(candle_start_utc) AS min_ts,max(candle_start_utc) AS max_ts,count(*) FILTER (WHERE NOT canonical_eligible OR NOT in_source_window OR NOT minute_aligned OR cardinality(quality_flags)>0 OR duplicate_class IS NOT NULL)::bigint AS mechanically_invalid_rows FROM asrp.q2_market_1m_observations"))[0];if([long]$marketCard.row_count-ne$ExpectedMarketRows-or[int]$marketCard.pair_count-ne$ExpectedMarketPairs){throw 'Frozen market cardinality mismatch.'}

    $marketQuery=@"
WITH scanner_assets(source_member_ordinal,base_asset_id) AS (
    VALUES $assetValues
), bins AS MATERIALIZED (
    SELECT m.source_member_ordinal,
           date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00') AS bin_start,
           count(*)::int AS obs_count,
           min(m.candle_start_utc) AS first_ts,
           max(m.candle_start_utc) AS last_ts
    FROM asrp.q2_market_1m_observations m
    JOIN scanner_assets a USING(source_member_ordinal)
    WHERE m.candle_start_utc >= timestamptz '2025-04-01 00:00:00+00'
      AND m.candle_start_utc <  timestamptz '2025-07-01 00:00:00+00'
      AND m.canonical_eligible
      AND m.in_source_window
      AND m.minute_aligned
      AND cardinality(m.quality_flags)=0
      AND m.duplicate_class IS NULL
    GROUP BY m.source_member_ordinal,date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00')
), grid AS MATERIALIZED (
    SELECT a.source_member_ordinal,a.base_asset_id,g.bin_start,
           coalesce(b.obs_count,0)::int AS obs_count,b.first_ts,b.last_ts
    FROM scanner_assets a
    CROSS JOIN generate_series(timestamptz '2025-04-01 00:00:00+00',timestamptz '2025-06-30 23:45:00+00',interval '15 minutes') g(bin_start)
    LEFT JOIN bins b ON b.source_member_ordinal=a.source_member_ordinal AND b.bin_start=g.bin_start
), rolling AS MATERIALIZED (
    SELECT base_asset_id,bin_start+interval '15 minutes' AS scan_ts,
           sum(obs_count) OVER w60 AS obs60,min(first_ts) OVER w60 AS first60,max(last_ts) OVER w60 AS last60,
           sum(obs_count) OVER w240 AS obs240,min(first_ts) OVER w240 AS first240,max(last_ts) OVER w240 AS last240
    FROM grid
    WINDOW w60 AS (PARTITION BY base_asset_id ORDER BY bin_start ROWS BETWEEN 3 PRECEDING AND CURRENT ROW),
           w240 AS (PARTITION BY base_asset_id ORDER BY bin_start ROWS BETWEEN 15 PRECEDING AND CURRENT ROW)
), expanded AS MATERIALIZED (
    SELECT base_asset_id,scan_ts,v.horizon_minutes,v.obs_count,v.first_ts,v.last_ts,
           CASE WHEN v.obs_count>0 THEN extract(epoch FROM (v.last_ts-v.first_ts))/60.0 END AS span_minutes,
           CASE WHEN v.obs_count>0 THEN extract(epoch FROM (v.first_ts-(scan_ts-make_interval(mins=>v.horizon_minutes))))/60.0 END AS start_gap_minutes,
           CASE WHEN v.obs_count>0 THEN extract(epoch FROM (scan_ts-v.last_ts))/60.0 END AS end_gap_minutes
    FROM rolling
    CROSS JOIN LATERAL (VALUES
       (60,obs60,first60,last60),
       (240,obs240,first240,last240)
    ) v(horizon_minutes,obs_count,first_ts,last_ts)
    WHERE scan_ts >= timestamptz '2025-04-02 00:15:00+00' AND scan_ts < timestamptz '2025-07-01 00:00:00+00'
), asset_summary AS (
    SELECT 'ASSET'::text AS row_type,base_asset_id,NULL::text AS scan_timestamp_utc,horizon_minutes,
           count(*)::bigint AS scan_count,count(*) FILTER(WHERE obs_count>0)::bigint AS windows_with_any,
           (count(*) FILTER(WHERE obs_count>0)::double precision/count(*)) AS any_share,
           min(obs_count)::double precision AS min_obs,
           percentile_disc(0.10) WITHIN GROUP(ORDER BY obs_count)::double precision AS p10_obs,
           percentile_disc(0.50) WITHIN GROUP(ORDER BY obs_count)::double precision AS median_obs,
           percentile_disc(0.90) WITHIN GROUP(ORDER BY obs_count)::double precision AS p90_obs,
           max(obs_count)::double precision AS max_obs,
           percentile_disc(0.50) WITHIN GROUP(ORDER BY span_minutes) FILTER(WHERE obs_count>0)::double precision AS median_span_minutes,
           percentile_disc(0.90) WITHIN GROUP(ORDER BY span_minutes) FILTER(WHERE obs_count>0)::double precision AS p90_span_minutes,
           percentile_disc(0.50) WITHIN GROUP(ORDER BY start_gap_minutes) FILTER(WHERE obs_count>0)::double precision AS median_start_gap_minutes,
           percentile_disc(0.90) WITHIN GROUP(ORDER BY start_gap_minutes) FILTER(WHERE obs_count>0)::double precision AS p90_start_gap_minutes,
           percentile_disc(0.50) WITHIN GROUP(ORDER BY end_gap_minutes) FILTER(WHERE obs_count>0)::double precision AS median_end_gap_minutes,
           percentile_disc(0.90) WITHIN GROUP(ORDER BY end_gap_minutes) FILTER(WHERE obs_count>0)::double precision AS p90_end_gap_minutes,
           NULL::int AS assets_with_any,NULL::double precision AS breadth_share
    FROM expanded GROUP BY base_asset_id,horizon_minutes
), breadth AS (
    SELECT 'BREADTH'::text AS row_type,NULL::text AS base_asset_id,to_char(scan_ts AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') AS scan_timestamp_utc,horizon_minutes,
           NULL::bigint AS scan_count,NULL::bigint AS windows_with_any,NULL::double precision AS any_share,
           NULL::double precision AS min_obs,NULL::double precision AS p10_obs,NULL::double precision AS median_obs,NULL::double precision AS p90_obs,NULL::double precision AS max_obs,
           NULL::double precision AS median_span_minutes,NULL::double precision AS p90_span_minutes,NULL::double precision AS median_start_gap_minutes,NULL::double precision AS p90_start_gap_minutes,NULL::double precision AS median_end_gap_minutes,NULL::double precision AS p90_end_gap_minutes,
           count(*) FILTER(WHERE obs_count>0)::int AS assets_with_any,(count(*) FILTER(WHERE obs_count>0)::double precision/418.0) AS breadth_share
    FROM expanded GROUP BY scan_ts,horizon_minutes
)
SELECT * FROM asset_summary
UNION ALL
SELECT * FROM breadth
ORDER BY row_type,base_asset_id NULLS LAST,scan_timestamp_utc NULLS LAST,horizon_minutes
"@
    $marketCombined=@(Convert-S11CsvText (Invoke-S11PsqlCsv $psql 'asrp' $marketQuery));$marketAsset=@($marketCombined|Where-Object{$_.row_type-ceq'ASSET'});$marketBreadth=@($marketCombined|Where-Object{$_.row_type-ceq'BREADTH'});if($marketAsset.Count-ne($ExpectedScannerAssets*2)){throw "Market asset-summary row count mismatch: $($marketAsset.Count)"};if($marketBreadth.Count-ne($candidateScans*2)){throw "Market breadth row count mismatch: $($marketBreadth.Count), expected $($candidateScans*2)"}

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage11-scanner-source-readiness'};$runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $entryPath=Join-Path $runDir 'stage11-source-entry-reconciliation.json';$newsScanPath=Join-Path $runDir 'stage11-news-scan-window-readiness.csv';$newsSummaryPath=Join-Path $runDir 'stage11-news-readiness-summary.csv';$marketSummaryPath=Join-Path $runDir 'stage11-market-readiness-summary.csv';$breadthPath=Join-Path $runDir 'stage11-market-breadth-readiness.csv';$receiptPath=Join-Path $runDir 'stage11-source-readiness-run-receipt.json'

    @($newsRows.ToArray())|Export-Csv -LiteralPath $newsScanPath -NoTypeInformation -Encoding UTF8
    $newsSummary=@(
      [pscustomobject][ordered]@{horizon_hours=24;candidate_scans=$candidateScans;complete_scans=$complete24;incomplete_scans=$candidateScans-$complete24;complete_share=($complete24/[double]$candidateScans).ToString('R',$Invariant);first_complete_scan=if($null-eq$first24){''}else{Format-S11Utc $first24};last_complete_scan=if($null-eq$last24){''}else{Format-S11Utc $last24}},
      [pscustomobject][ordered]@{horizon_hours=6;candidate_scans=$candidateScans;complete_scans=$complete6;incomplete_scans=$candidateScans-$complete6;complete_share=($complete6/[double]$candidateScans).ToString('R',$Invariant);first_complete_scan=if($null-eq$first6){''}else{Format-S11Utc $first6};last_complete_scan=if($null-eq$last6){''}else{Format-S11Utc $last6}}
    );$newsSummary|Export-Csv -LiteralPath $newsSummaryPath -NoTypeInformation -Encoding UTF8
    $marketAsset|Select-Object base_asset_id,horizon_minutes,scan_count,windows_with_any,any_share,min_obs,p10_obs,median_obs,p90_obs,max_obs,median_span_minutes,p90_span_minutes,median_start_gap_minutes,p90_start_gap_minutes,median_end_gap_minutes,p90_end_gap_minutes|Export-Csv -LiteralPath $marketSummaryPath -NoTypeInformation -Encoding UTF8
    $marketBreadth|Select-Object scan_timestamp_utc,horizon_minutes,assets_with_any,breadth_share|Export-Csv -LiteralPath $breadthPath -NoTypeInformation -Encoding UTF8

    $entry=[ordered]@{status='PASS';stage='CFA_STAGE_11_SOURCE_READINESS';stage10=[ordered]@{run_receipt=$Stage10RunReceiptPath;run_receipt_sha256=$ExpectedStage10RunSha;validation_receipt=$Stage10ValidationReceiptPath;validation_receipt_sha256=$ExpectedStage10ValidationSha;profile=$profilePath;profile_sha256=$ExpectedStage10ProfileSha;scanner_assets=$ExpectedScannerAssets};stage5=[ordered]@{candidate_receipt=$Stage5CandidateReceiptPath;candidate_receipt_sha256=(Get-S11Sha $Stage5CandidateReceiptPath);factor_csv=$factorPath;factor_csv_sha256=$ExpectedStage5FactorSha;stage3_matches=$matchesPath;stage3_matches_sha256=$matchesSha;batch_timing_receipt=$batchPath;batch_timing_receipt_sha256=(Get-S11Sha $batchPath);source_slots=$slotsPath;source_slots_sha256=(Get-S11Sha $slotsPath)};news=[ordered]@{match_rows=$matches.Count;matched_assets=$matchAssets.Count;distinct_records=$matchRecords.Count;source_slots=$slotRows.Count;downloaded_slots=$downloaded;provider_missing_slots=$providerMissing;misaligned_record_batches=$misaligned};market=[ordered]@{relation='asrp.q2_market_1m_observations';postgresql_version=$version;default_transaction_read_only=$readOnly;row_count=[long]$marketCard.row_count;pair_count=[int]$marketCard.pair_count;min_timestamp=[string]$marketCard.min_ts;max_timestamp=[string]$marketCard.max_ts;mechanically_invalid_rows=[long]$marketCard.mechanically_invalid_rows;direct_usd_pairs=$directUsd.Count}}
    Write-S11Json $entryPath $entry
    $receipt=[ordered]@{status='VALIDATION_CANDIDATE';stage='CFA_STAGE_11';run='SCANNER_SOURCE_READINESS_V1';interpretation='SOURCE_COVERAGE_ONLY_NO_FORWARD_OUTCOMES';sources=[ordered]@{stage10_run_receipt_sha256=$ExpectedStage10RunSha;stage10_validation_receipt_sha256=$ExpectedStage10ValidationSha;stage10_profile_sha256=$ExpectedStage10ProfileSha;stage5_candidate_receipt_sha256=(Get-S11Sha $Stage5CandidateReceiptPath);stage5_factor_sha256=$ExpectedStage5FactorSha;stage3_matches_sha256=$matchesSha;source_slots_sha256=(Get-S11Sha $slotsPath);market_relation='asrp.q2_market_1m_observations'};scan_clock=[ordered]@{cadence_minutes=15;first_candidate_scan=Format-S11Utc $FirstCandidateScan;end_exclusive=Format-S11Utc $Q2End;candidate_scans=$candidateScans;news24_complete_scans=$complete24;news6_complete_scans=$complete6;both_news_windows_complete_scans=$completeBoth};market_probe=[ordered]@{horizons_minutes=@(60,240);scanner_assets=$ExpectedScannerAssets;asset_summary_rows=$marketAsset.Count;breadth_rows=$marketBreadth.Count;quality_rule='canonical_eligible AND in_source_window AND minute_aligned AND cardinality(quality_flags)=0 AND duplicate_class IS NULL';no_minimum_support_threshold_applied=$true};outputs=[ordered]@{source_entry_reconciliation=$entryPath;source_entry_reconciliation_sha256=(Get-S11Sha $entryPath);news_scan_window_readiness=$newsScanPath;news_scan_window_readiness_sha256=(Get-S11Sha $newsScanPath);news_readiness_summary=$newsSummaryPath;news_readiness_summary_sha256=(Get-S11Sha $newsSummaryPath);market_readiness_summary=$marketSummaryPath;market_readiness_summary_sha256=(Get-S11Sha $marketSummaryPath);market_breadth_readiness=$breadthPath;market_breadth_readiness_sha256=(Get-S11Sha $breadthPath)};gates=[ordered]@{'CFA-S11-001'='PASS';'CFA-S11-002'='PASS';'CFA-S11-003'='PASS';'CFA-S11-004'='PASS';'CFA-S11-005'='PASS';'CFA-S11-006'='BLOCKED';'CFA-S11-007'='BLOCKED';'CFA-S11-008'='BLOCKED'};next_action='Independently validate exact source-readiness outputs, then freeze live scanner calibration rules from source support before computing forward outcomes.'}
    Write-S11Json $receiptPath $receipt

    Write-Host '';Write-Host 'CFA STAGE 11 SCANNER SOURCE READINESS: VALIDATION CANDIDATE';Write-Host "PostgreSQL: $version";Write-Host "Session mode: default_transaction_read_only=$readOnly";Write-Host "Scanner assets / candidate 15m scans: $ExpectedScannerAssets / $candidateScans";Write-Host "GDELT 24h complete scans: $complete24 / $candidateScans";Write-Host "GDELT 6h complete scans: $complete6 / $candidateScans";Write-Host "Both GDELT windows complete scans: $completeBoth / $candidateScans";Write-Host "Market readiness rows asset-summary / breadth: $($marketAsset.Count) / $($marketBreadth.Count)";Write-Host 'Forward outcomes inspected: False';Write-Host 'CFA-S11-001 through CFA-S11-005: PASS';Write-Host 'CFA-S11-006 independent validation: BLOCKED';Write-Host 'CFA-S11-007 scanner calibration contract freeze: BLOCKED';Write-Host "News readiness summary: $newsSummaryPath";Write-Host "Market readiness summary: $marketSummaryPath";Write-Host "Market breadth readiness: $breadthPath";Write-Host "Run receipt: $receiptPath";exit 0
}
catch{Write-Host '';Write-Host 'CFA STAGE 11 SCANNER SOURCE READINESS: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
finally{if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)};$env:PGPASSWORD=$oldPassword;$env:PGOPTIONS=$oldOptions}
