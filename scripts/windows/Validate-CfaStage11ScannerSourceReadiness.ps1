#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunReceiptPath,
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
$ExpectedScannerAssets=418
$ExpectedStage3Rows=22060
$ExpectedStage3Assets=282
$ExpectedStage3Records=18503
$ExpectedSourceSlots=8736
$ExpectedDownloadedSlots=7163
$ExpectedProviderMissingSlots=1573
$Q2Start=[datetime]::SpecifyKind([datetime]'2025-04-01T00:00:00',[DateTimeKind]::Utc)
$Q2End=[datetime]::SpecifyKind([datetime]'2025-07-01T00:00:00',[DateTimeKind]::Utc)
$FirstScan=$Q2Start.AddHours(24).AddMinutes(15)

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath

function Sha-S11v {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function File-S11v {param([string]$Path,[string]$Label);$p=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "$Label is not a file: $p"};return $p}
function Bool-S11v {param([object]$Value);$x=([string]$Value).Trim().ToLowerInvariant();if($x-in@('true','t','1')){return $true};if($x-in@('false','f','0')){return $false};throw "Malformed boolean '$Value'"}
function Dbl-S11v {param([object]$Value,[string]$Label);$n=0.0;if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"};if([double]::IsNaN($n)-or[double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"};return $n}
function Near-S11v {param([double]$A,[double]$B,[double]$Tol=1e-10);$s=[math]::Max(1.0,[math]::Max([math]::Abs($A),[math]::Abs($B)));return [math]::Abs($A-$B)-le($Tol*$s)}
function Utc-S11v {param([datetime]$Value);return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)}
function Json-S11v {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 12)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}
function RequireCols-S11v {param([object]$Row,[string[]]$Names,[string]$Label);$p=@($Row.PSObject.Properties.Name);foreach($n in $Names){if($p-notcontains$n){throw "$Label missing column: $n"}}}
function FindPsql-S11v {$c=Get-Command 'psql.exe' -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;if($null-ne$c){return $c.Source};$f=@(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue|Sort-Object FullName -Descending);if($f.Count-eq0){throw 'psql.exe could not be found.'};return $f[0].FullName}
function PsqlText-S11v {param([string]$Exe,[string]$Sql);$err=[IO.Path]::GetTempFileName();try{$o=@(& $Exe -X -h $PgHost -p $PgPort -U $PgUser -d asrp -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2>$err);$code=$LASTEXITCODE;$e=if(Test-Path -LiteralPath $err){(Get-Content -LiteralPath $err -ErrorAction SilentlyContinue)-join[Environment]::NewLine}else{''};$t=($o|ForEach-Object{if($null-ne$_){[string]$_}})-join[Environment]::NewLine;if($code-ne0){throw "psql failed (exit $code).`n$e`n$t"};return $t}finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}}
function PsqlCsv-S11v {param([string]$Exe,[string]$Query);$q=$Query.Trim();while($q.EndsWith(';')){$q=$q.Substring(0,$q.Length-1).TrimEnd()};return PsqlText-S11v $Exe "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"}
function CsvRows-S11v {param([string]$Text);if([string]::IsNullOrWhiteSpace($Text)){return @()};return @($Text|ConvertFrom-Csv)}
function Window-S11v {param([datetime]$Scan,[int]$Hours,[hashtable]$Slots);$end=$Scan.AddMinutes(-15);$start=$end.AddHours(-$Hours);$need=$Hours*4;$d=0;$p=0;$m=0;$o=0;for($i=0;$i-lt$need;$i++){$k=$start.AddMinutes(15*$i).ToString('yyyyMMddHHmmss',$Invariant);if(-not$Slots.ContainsKey($k)){$m++;continue};$s=[string]$Slots[$k].status;if($s-ceq'downloaded'){$d++}elseif($s-ceq'provider_missing'){$p++}else{$o++}};return [pscustomobject]@{complete=($d-eq$need-and$p-eq0-and$m-eq0-and$o-eq0);downloaded=$d;provider_missing=$p;registry_missing=$m}}
function MaybeNear-S11v {param([object]$A,[object]$B,[string]$Label);$sa=([string]$A).Trim();$sb=([string]$B).Trim();if($sa-eq''-or$sb-eq''){if($sa-ne$sb){throw "$Label blank mismatch"};return};if(-not(Near-S11v (Dbl-S11v $sa $Label) (Dbl-S11v $sb $Label))){throw "$Label numeric mismatch: $sa vs $sb"}}

function SelfTest-S11v {
    $slots=@{};$s=[datetime]::SpecifyKind([datetime]'2025-04-01T00:00:00',[DateTimeKind]::Utc);for($i=0;$i-lt96;$i++){$k=$s.AddMinutes(15*$i).ToString('yyyyMMddHHmmss',$Invariant);$slots[$k]=[pscustomobject]@{status='downloaded'}}
    $w=Window-S11v $s.AddDays(1).AddMinutes(15) 24 $slots;if(-not$w.complete-or$w.downloaded-ne96){throw 'window self-test'};$slots['20250401000000']=[pscustomobject]@{status='provider_missing'};$w=Window-S11v $s.AddDays(1).AddMinutes(15) 24 $slots;if($w.complete-or$w.provider_missing-ne1){throw 'missing-window self-test'}
    if(-not(Near-S11v 1.0 (1.0+1e-12))){throw 'near self-test'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{SelfTest-S11v;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

$oldPassword=$env:PGPASSWORD;$oldOptions=$env:PGOPTIONS;$bstr=[IntPtr]::Zero
try {
    $RunReceiptPath=File-S11v $RunReceiptPath 'Stage 11 run receipt';$runSha=Sha-S11v $RunReceiptPath;$r=Get-Content -LiteralPath $RunReceiptPath -Raw|ConvertFrom-Json
    if([string]$r.status-ne'VALIDATION_CANDIDATE'-or[string]$r.stage-ne'CFA_STAGE_11'-or[string]$r.run-ne'SCANNER_SOURCE_READINESS_V1'){throw 'Stage 11 run identity mismatch.'}
    foreach($g in 1..5){$id=('CFA-S11-{0:D3}'-f$g);if([string]$r.gates.$id-ne'PASS'){throw "Candidate gate not PASS: $id"}}
    if([string]$r.sources.stage10_run_receipt_sha256-ne$ExpectedStage10RunSha-or[string]$r.sources.stage10_validation_receipt_sha256-ne$ExpectedStage10ValidationSha-or[string]$r.sources.stage10_profile_sha256-ne$ExpectedStage10ProfileSha-or[string]$r.sources.stage5_factor_sha256-ne$ExpectedStage5FactorSha){throw 'Pinned upstream source hash mismatch.'}
    if([int]$r.scan_clock.cadence_minutes-ne15-or[int]$r.scan_clock.candidate_scans-ne8639-or[int]$r.market_probe.scanner_assets-ne$ExpectedScannerAssets-or-not[bool]$r.market_probe.no_minimum_support_threshold_applied){throw 'Stage 11 declared scan/readiness shape mismatch.'}

    $entryPath=File-S11v ([string]$r.outputs.source_entry_reconciliation) 'source entry';$newsScanPath=File-S11v ([string]$r.outputs.news_scan_window_readiness) 'news scan readiness';$newsSummaryPath=File-S11v ([string]$r.outputs.news_readiness_summary) 'news summary';$marketPath=File-S11v ([string]$r.outputs.market_readiness_summary) 'market summary';$breadthPath=File-S11v ([string]$r.outputs.market_breadth_readiness) 'market breadth'
    foreach($pair in @(@($entryPath,[string]$r.outputs.source_entry_reconciliation_sha256),@($newsScanPath,[string]$r.outputs.news_scan_window_readiness_sha256),@($newsSummaryPath,[string]$r.outputs.news_readiness_summary_sha256),@($marketPath,[string]$r.outputs.market_readiness_summary_sha256),@($breadthPath,[string]$r.outputs.market_breadth_readiness_sha256))){if((Sha-S11v $pair[0])-ne$pair[1]){throw "Output hash mismatch: $($pair[0])"}}

    $entry=Get-Content -LiteralPath $entryPath -Raw|ConvertFrom-Json
    if([string]$entry.status-ne'PASS'-or[int]$entry.stage10.scanner_assets-ne$ExpectedScannerAssets-or[string]$entry.stage10.run_receipt_sha256-ne$ExpectedStage10RunSha-or[string]$entry.stage10.validation_receipt_sha256-ne$ExpectedStage10ValidationSha-or[string]$entry.stage10.profile_sha256-ne$ExpectedStage10ProfileSha){throw 'Stage 11 source-entry Stage 10 reconciliation mismatch.'}
    if([string]$entry.stage5.factor_csv_sha256-ne$ExpectedStage5FactorSha){throw 'Stage 5 factor hash mismatch in entry.'}
    $profilePath=File-S11v ([string]$entry.stage10.profile) 'Stage 10 profile';if((Sha-S11v $profilePath)-ne$ExpectedStage10ProfileSha){throw 'Stage 10 profile file hash mismatch.'};$profile=@(Import-Csv -LiteralPath $profilePath);if($profile.Count-ne$ExpectedScannerAssets){throw 'Stage 10 profile row count mismatch.'};$assets=@($profile|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique);if($assets.Count-ne$ExpectedScannerAssets){throw 'Stage 10 profile asset uniqueness mismatch.'}

    $matchesPath=File-S11v ([string]$entry.stage5.stage3_matches) 'Stage 3 matches';if((Sha-S11v $matchesPath)-ne[string]$entry.stage5.stage3_matches_sha256){throw 'Stage 3 match hash mismatch.'};$matches=@(Import-Csv -LiteralPath $matchesPath);if($matches.Count-ne$ExpectedStage3Rows){throw 'Stage 3 match row count mismatch.'};$ma=@($matches|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique);$mr=@($matches|ForEach-Object{[string]$_.record_id}|Sort-Object -Unique);if($ma.Count-ne$ExpectedStage3Assets-or$mr.Count-ne$ExpectedStage3Records){throw 'Stage 3 match shape mismatch.'}
    $slotsPath=File-S11v ([string]$entry.stage5.source_slots) 'source slots';if((Sha-S11v $slotsPath)-ne[string]$entry.stage5.source_slots_sha256){throw 'Source slot hash mismatch.'};$slotRows=@(Import-Csv -LiteralPath $slotsPath);if($slotRows.Count-ne$ExpectedSourceSlots){throw 'Source slot row count mismatch.'};$slots=@{};$dl=0;$pm=0;foreach($x in $slotRows){$k=([string]$x.slot_key).Trim();if($slots.ContainsKey($k)){throw "Duplicate slot $k"};$slots[$k]=$x;if([string]$x.status-ceq'downloaded'){$dl++}elseif([string]$x.status-ceq'provider_missing'){$pm++}else{throw "Unexpected slot status $($x.status)"}};if($dl-ne$ExpectedDownloadedSlots-or$pm-ne$ExpectedProviderMissingSlots){throw 'Source-slot partition mismatch.'}

    $observedNews=@(Import-Csv -LiteralPath $newsScanPath);if($observedNews.Count-ne8639){throw "News scan rows mismatch: $($observedNews.Count)"};$n24=0;$n6=0;$both=0;$i=0
    for($scan=$FirstScan;$scan-lt$Q2End;$scan=$scan.AddMinutes(15)){$o=$observedNews[$i];$ts=Utc-S11v $scan;if([string]$o.scan_timestamp_utc-ne$ts){throw "News scan timestamp mismatch at $i"};$w24=Window-S11v $scan 24 $slots;$w6=Window-S11v $scan 6 $slots;if((Bool-S11v $o.news24_complete)-ne$w24.complete-or[int]$o.news24_downloaded_slots-ne$w24.downloaded-or[int]$o.news24_provider_missing_slots-ne$w24.provider_missing-or[int]$o.news24_registry_missing_slots-ne$w24.registry_missing){throw "24h news readiness mismatch at $ts"};if((Bool-S11v $o.news6_complete)-ne$w6.complete-or[int]$o.news6_downloaded_slots-ne$w6.downloaded-or[int]$o.news6_provider_missing_slots-ne$w6.provider_missing-or[int]$o.news6_registry_missing_slots-ne$w6.registry_missing){throw "6h news readiness mismatch at $ts"};if($w24.complete){$n24++};if($w6.complete){$n6++};if($w24.complete-and$w6.complete){$both++};$i++}
    if($n24-ne[int]$r.scan_clock.news24_complete_scans-or$n6-ne[int]$r.scan_clock.news6_complete_scans-or$both-ne[int]$r.scan_clock.both_news_windows_complete_scans){throw 'News completeness totals mismatch receipt.'}
    $ns=@(Import-Csv -LiteralPath $newsSummaryPath);if($ns.Count-ne2){throw 'News summary row count mismatch.'};foreach($x in $ns){$h=[int]$x.horizon_hours;$expected=if($h-eq24){$n24}elseif($h-eq6){$n6}else{throw 'Unexpected news summary horizon.'};if([int]$x.candidate_scans-ne8639-or[int]$x.complete_scans-ne$expected-or[int]$x.incomplete_scans-ne(8639-$expected)){throw "News summary mismatch for ${h}h"}}

    $afPath=File-S11v (Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv') 'AF-001';if((Sha-S11v $afPath)-ne$ExpectedAf001Sha){throw 'AF-001 hash mismatch.'};$af=@(Import-Csv -LiteralPath $afPath);$usd=@($af|Where-Object{(Bool-S11v $_.research_eligible)-and([string]$_.quote_exchange_symbol).Trim()-ceq'USD'});$map=@{};foreach($x in $usd){$map[[string]$x.base_asset_id]=$x};$vals=New-Object System.Collections.ArrayList;foreach($a in $assets){if(-not$map.ContainsKey($a)){throw "No direct-USD mapping for $a"};[void]$vals.Add("("+([string]$map[$a].source_member_ordinal).Trim()+",'"+$a.Replace("'","''")+"')")};$values=$vals.ToArray()-join','

    $psql=FindPsql-S11v;$secure=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString;$bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr);$env:PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000)";$version=(PsqlText-S11v $psql 'SHOW server_version;').Trim();$ro=(PsqlText-S11v $psql "SELECT current_setting('default_transaction_read_only');").Trim();if($ro-ne'on'){throw 'PostgreSQL is not read-only.'}
    $card=@(CsvRows-S11v (PsqlCsv-S11v $psql "SELECT count(*)::bigint row_count,count(DISTINCT pair_token_opaque)::int pair_count,min(candle_start_utc) min_ts,max(candle_start_utc) max_ts,count(*) FILTER (WHERE NOT canonical_eligible OR NOT in_source_window OR NOT minute_aligned OR cardinality(quality_flags)>0 OR duplicate_class IS NOT NULL)::bigint mechanically_invalid_rows FROM asrp.q2_market_1m_observations"))[0];if([long]$card.row_count-ne$ExpectedMarketRows-or[int]$card.pair_count-ne$ExpectedMarketPairs){throw 'Market cardinality mismatch.'};if([long]$card.mechanically_invalid_rows-ne[long]$entry.market.mechanically_invalid_rows){throw 'Mechanically-invalid market row count mismatch.'}

    $q=@"
WITH scanner_assets(source_member_ordinal,base_asset_id) AS (VALUES $values),
bins AS MATERIALIZED (
 SELECT m.source_member_ordinal,date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00') bin_start,
        count(*)::int obs_count,min(m.candle_start_utc) first_ts,max(m.candle_start_utc) last_ts
 FROM asrp.q2_market_1m_observations m JOIN scanner_assets a USING(source_member_ordinal)
 WHERE m.candle_start_utc>=timestamptz '2025-04-01 00:00:00+00' AND m.candle_start_utc<timestamptz '2025-07-01 00:00:00+00'
 AND m.canonical_eligible AND m.in_source_window AND m.minute_aligned AND cardinality(m.quality_flags)=0 AND m.duplicate_class IS NULL
 GROUP BY m.source_member_ordinal,date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00')
),grid AS MATERIALIZED (
 SELECT a.base_asset_id,g.bin_start,coalesce(b.obs_count,0)::int obs_count,b.first_ts,b.last_ts
 FROM scanner_assets a CROSS JOIN generate_series(timestamptz '2025-04-01 00:00:00+00',timestamptz '2025-06-30 23:45:00+00',interval '15 minutes') g(bin_start)
 LEFT JOIN bins b ON b.source_member_ordinal=a.source_member_ordinal AND b.bin_start=g.bin_start
),roll AS MATERIALIZED (
 SELECT base_asset_id,bin_start+interval '15 minutes' scan_ts,
 sum(obs_count) OVER(PARTITION BY base_asset_id ORDER BY bin_start RANGE BETWEEN interval '45 minutes' PRECEDING AND CURRENT ROW) obs60,
 min(first_ts) OVER(PARTITION BY base_asset_id ORDER BY bin_start RANGE BETWEEN interval '45 minutes' PRECEDING AND CURRENT ROW) first60,
 max(last_ts) OVER(PARTITION BY base_asset_id ORDER BY bin_start RANGE BETWEEN interval '45 minutes' PRECEDING AND CURRENT ROW) last60,
 sum(obs_count) OVER(PARTITION BY base_asset_id ORDER BY bin_start RANGE BETWEEN interval '225 minutes' PRECEDING AND CURRENT ROW) obs240,
 min(first_ts) OVER(PARTITION BY base_asset_id ORDER BY bin_start RANGE BETWEEN interval '225 minutes' PRECEDING AND CURRENT ROW) first240,
 max(last_ts) OVER(PARTITION BY base_asset_id ORDER BY bin_start RANGE BETWEEN interval '225 minutes' PRECEDING AND CURRENT ROW) last240
 FROM grid
),x AS MATERIALIZED (
 SELECT base_asset_id,scan_ts,v.horizon_minutes,v.obs_count,v.first_ts,v.last_ts,
 CASE WHEN v.obs_count>0 THEN extract(epoch FROM(v.last_ts-v.first_ts))/60.0 END span_minutes,
 CASE WHEN v.obs_count>0 THEN extract(epoch FROM(v.first_ts-(scan_ts-make_interval(mins=>v.horizon_minutes))))/60.0 END start_gap_minutes,
 CASE WHEN v.obs_count>0 THEN extract(epoch FROM(scan_ts-v.last_ts))/60.0 END end_gap_minutes
 FROM roll CROSS JOIN LATERAL(VALUES(60,obs60,first60,last60),(240,obs240,first240,last240))v(horizon_minutes,obs_count,first_ts,last_ts)
 WHERE scan_ts>=timestamptz '2025-04-02 00:15:00+00' AND scan_ts<timestamptz '2025-07-01 00:00:00+00'
),a AS (
 SELECT 'ASSET' row_type,base_asset_id,NULL::text scan_timestamp_utc,horizon_minutes,count(*)::bigint scan_count,count(*)FILTER(WHERE obs_count>0)::bigint windows_with_any,
 count(*)FILTER(WHERE obs_count>0)::double precision/count(*) any_share,min(obs_count)::double precision min_obs,percentile_disc(.10)WITHIN GROUP(ORDER BY obs_count)::double precision p10_obs,
 percentile_disc(.50)WITHIN GROUP(ORDER BY obs_count)::double precision median_obs,percentile_disc(.90)WITHIN GROUP(ORDER BY obs_count)::double precision p90_obs,max(obs_count)::double precision max_obs,
 percentile_disc(.50)WITHIN GROUP(ORDER BY span_minutes)FILTER(WHERE obs_count>0)::double precision median_span_minutes,percentile_disc(.90)WITHIN GROUP(ORDER BY span_minutes)FILTER(WHERE obs_count>0)::double precision p90_span_minutes,
 percentile_disc(.50)WITHIN GROUP(ORDER BY start_gap_minutes)FILTER(WHERE obs_count>0)::double precision median_start_gap_minutes,percentile_disc(.90)WITHIN GROUP(ORDER BY start_gap_minutes)FILTER(WHERE obs_count>0)::double precision p90_start_gap_minutes,
 percentile_disc(.50)WITHIN GROUP(ORDER BY end_gap_minutes)FILTER(WHERE obs_count>0)::double precision median_end_gap_minutes,percentile_disc(.90)WITHIN GROUP(ORDER BY end_gap_minutes)FILTER(WHERE obs_count>0)::double precision p90_end_gap_minutes,
 NULL::int assets_with_any,NULL::double precision breadth_share FROM x GROUP BY base_asset_id,horizon_minutes
),b AS (
 SELECT 'BREADTH' row_type,NULL::text base_asset_id,to_char(scan_ts AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') scan_timestamp_utc,horizon_minutes,NULL::bigint scan_count,NULL::bigint windows_with_any,NULL::double precision any_share,
 NULL::double precision min_obs,NULL::double precision p10_obs,NULL::double precision median_obs,NULL::double precision p90_obs,NULL::double precision max_obs,NULL::double precision median_span_minutes,NULL::double precision p90_span_minutes,NULL::double precision median_start_gap_minutes,NULL::double precision p90_start_gap_minutes,NULL::double precision median_end_gap_minutes,NULL::double precision p90_end_gap_minutes,
 count(*)FILTER(WHERE obs_count>0)::int assets_with_any,count(*)FILTER(WHERE obs_count>0)::double precision/418.0 breadth_share FROM x GROUP BY scan_ts,horizon_minutes
)
SELECT * FROM a UNION ALL SELECT * FROM b ORDER BY row_type,base_asset_id NULLS LAST,scan_timestamp_utc NULLS LAST,horizon_minutes
"@
    $calc=@(CsvRows-S11v (PsqlCsv-S11v $psql $q));$ca=@($calc|Where-Object{$_.row_type-eq'ASSET'});$cb=@($calc|Where-Object{$_.row_type-eq'BREADTH'});$oa=@(Import-Csv -LiteralPath $marketPath);$ob=@(Import-Csv -LiteralPath $breadthPath);if($ca.Count-ne836-or$oa.Count-ne836-or$cb.Count-ne17278-or$ob.Count-ne17278){throw 'Market readiness row counts mismatch.'}
    $caBy=@{};foreach($x in $ca){$caBy[([string]$x.base_asset_id)+'|'+([string]$x.horizon_minutes)]=$x};foreach($o in $oa){$k=([string]$o.base_asset_id)+'|'+([string]$o.horizon_minutes);if(-not$caBy.ContainsKey($k)){throw "Missing independent market key $k"};$c=$caBy[$k];foreach($n in @('scan_count','windows_with_any')){if([long]$o.$n-ne[long]$c.$n){throw "$k $n mismatch"}};foreach($n in @('any_share','min_obs','p10_obs','median_obs','p90_obs','max_obs','median_span_minutes','p90_span_minutes','median_start_gap_minutes','p90_start_gap_minutes','median_end_gap_minutes','p90_end_gap_minutes')){MaybeNear-S11v $o.$n $c.$n "$k $n"}}
    $cbBy=@{};foreach($x in $cb){$cbBy[([string]$x.scan_timestamp_utc)+'|'+([string]$x.horizon_minutes)]=$x};foreach($o in $ob){$k=([string]$o.scan_timestamp_utc)+'|'+([string]$o.horizon_minutes);if(-not$cbBy.ContainsKey($k)){throw "Missing independent breadth key $k"};$c=$cbBy[$k];if([int]$o.assets_with_any-ne[int]$c.assets_with_any){throw "$k assets_with_any mismatch"};MaybeNear-S11v $o.breadth_share $c.breadth_share "$k breadth_share"}

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Split-Path -Parent $RunReceiptPath};if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null};$checksPath=Join-Path $OutputRoot 'stage11-source-readiness-independent-validation-checks.csv';$receiptPath=Join-Path $OutputRoot 'stage11-source-readiness-independent-validation.json'
    $checks=@(
      [pscustomobject]@{check_id='S11V-001';status='PASS';detail='Pinned Stage10/Stage5 entry and candidate receipt reconciled'},
      [pscustomobject]@{check_id='S11V-002';status='PASS';detail='All Stage11 output hashes match receipt'},
      [pscustomobject]@{check_id='S11V-003';status='PASS';detail="News completeness independently recomputed for 8639 scans: 24h=$n24 6h=$n6 both=$both"},
      [pscustomobject]@{check_id='S11V-004';status='PASS';detail='PostgreSQL market cardinality/read-only state independently verified'},
      [pscustomobject]@{check_id='S11V-005';status='PASS';detail='836 asset-horizon readiness rows independently recomputed using RANGE windows'},
      [pscustomobject]@{check_id='S11V-006';status='PASS';detail='17278 breadth rows independently recomputed'},
      [pscustomobject]@{check_id='S11V-007';status='PASS';detail='No forward outcome or scanner performance metric used'}
    );$checks|Export-Csv -LiteralPath $checksPath -NoTypeInformation -Encoding UTF8
    $vr=[ordered]@{status='PASS';stage='CFA_STAGE_11_INDEPENDENT_VALIDATION';run='SCANNER_SOURCE_READINESS_V1';candidate_run_receipt=$RunReceiptPath;candidate_run_receipt_sha256=$runSha;postgresql_version=$version;default_transaction_read_only=$ro;counts=[ordered]@{scanner_assets=$ExpectedScannerAssets;candidate_scans=8639;news24_complete=$n24;news6_complete=$n6;both_news_complete=$both;market_asset_summary_rows=$oa.Count;market_breadth_rows=$ob.Count};validated_output_hashes=[ordered]@{source_entry=(Sha-S11v $entryPath);news_scan=(Sha-S11v $newsScanPath);news_summary=(Sha-S11v $newsSummaryPath);market_summary=(Sha-S11v $marketPath);market_breadth=(Sha-S11v $breadthPath)};checks_csv=$checksPath;checks_sha256=(Sha-S11v $checksPath);gates=[ordered]@{'CFA-S11-006'='PASS';'CFA-S11-007'='UNVERIFIED';'CFA-S11-008'='BLOCKED'}};Json-S11v $receiptPath $vr
    Write-Host '';Write-Host 'CFA STAGE 11 INDEPENDENT SCANNER SOURCE READINESS VALIDATION: PASS';Write-Host "Scanner assets / candidate scans: $ExpectedScannerAssets / 8639";Write-Host "GDELT 24h / 6h / both complete scans: $n24 / $n6 / $both";Write-Host "Market readiness rows asset-summary / breadth: $($oa.Count) / $($ob.Count)";Write-Host 'Forward outcomes inspected: False';Write-Host 'CFA-S11-006 independent validation: PASS';Write-Host 'CFA-S11-007 scanner calibration contract freeze: UNVERIFIED';Write-Host "Run receipt SHA-256: $runSha";Write-Host "Validation checks SHA-256: $(Sha-S11v $checksPath)";Write-Host "Validation receipt SHA-256: $(Sha-S11v $receiptPath)";Write-Host "Validation receipt: $receiptPath";exit 0
}
catch{Write-Host '';Write-Host 'CFA STAGE 11 INDEPENDENT SCANNER SOURCE READINESS VALIDATION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
finally{if($bstr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)};$env:PGPASSWORD=$oldPassword;$env:PGOPTIONS=$oldOptions}
