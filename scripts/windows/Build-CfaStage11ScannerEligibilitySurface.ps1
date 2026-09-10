#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CalibrationSummaryPath,
    [string]$PgHost='localhost',
    [ValidateRange(1,65535)][int]$PgPort=5432,
    [string]$PgUser='postgres',
    [ValidateRange(60,3600)][int]$StatementTimeoutSeconds=1800,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Inv=[Globalization.CultureInfo]::InvariantCulture

$ExpectedV2ReceiptSha='8cc47c32ce258dd60716937dd765d5f10097745d559ddd1bd3fa348b07409217'
$ExpectedV2ValidationSha='21eb940accc1c50fda15f81ced19bf05bdac59b1d23e00243e9bb77f92d668ad'
$ExpectedStage10RunSha='5736a74a5d20021b88589e066ad0a98b3ea7efc5d346c3413e2298b7c007bf34'
$ExpectedStage7ValidationSha='e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756'
$ExpectedModelReadySha='fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024'
$ExpectedAfSha='569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAssets=418
$ExpectedScans=8639
$ExpectedMarketRows=14055089L
$ExpectedPairs=1058
$Q2Start=[datetime]::SpecifyKind([datetime]'2025-04-01T00:00:00',[DateTimeKind]::Utc)
$Q2End=[datetime]::SpecifyKind([datetime]'2025-07-01T00:00:00',[DateTimeKind]::Utc)
$FirstScan=$Q2Start.AddDays(1).AddMinutes(15)

if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath

function Sha-S11e {param([string]$Path);return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function File-S11e {param([string]$Path,[string]$Label);$p=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "$Label is not a file: $p"};return $p}
function Bool-S11e {param($Value,[string]$Label='boolean');$x=([string]$Value).Trim().ToLowerInvariant();if($x-in@('true','t')){return $true};if($x-in@('false','f')){return $false};throw "Malformed $Label: '$Value'"}
function D-S11e {param($Value,[string]$Label);$x=0.0;if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Inv,[ref]$x)){throw "Malformed numeric $Label: '$Value'"};if([double]::IsNaN($x)-or[double]::IsInfinity($x)){throw "Non-finite numeric $Label: '$Value'"};return $x}
function Utc-S11e {param([datetime]$Value);return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Inv)}
function Json-S11e {param([string]$Path,$Value);[IO.File]::WriteAllText($Path,(($Value|ConvertTo-Json -Depth 12)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}
function Pctl-S11e {param([double[]]$Values,[double]$P);if($Values.Count-lt1){throw 'Percentile on empty array'};[double[]]$s=@($Values|Sort-Object);$rank=[int][math]::Ceiling($P*$s.Count);if($rank-lt1){$rank=1};if($rank-gt$s.Count){$rank=$s.Count};return [double]$s[$rank-1]}
function FindPsql-S11e {$c=Get-Command psql.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;if($null-ne$c){return $c.Source};$f=@(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue|Sort-Object FullName -Descending);if($f.Count-eq0){throw 'psql.exe not found'};return $f[0].FullName}
function PsqlText-S11e {param([string]$Exe,[string]$Sql);$err=[IO.Path]::GetTempFileName();try{$out=@(& $Exe -X -h $PgHost -p $PgPort -U $PgUser -d asrp -A -t -q -v ON_ERROR_STOP=1 -c $Sql 2>$err);$code=$LASTEXITCODE;$stderr=(Get-Content -LiteralPath $err -ErrorAction SilentlyContinue)-join[Environment]::NewLine;$text=($out|ForEach-Object{if($null-ne$_){[string]$_}})-join[Environment]::NewLine;if($code-ne0){throw "psql failed ($code).`n$stderr`n$text"};return $text}finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}}
function PsqlCsv-S11e {param([string]$Exe,[string]$Query);$q=$Query.Trim();return PsqlText-S11e $Exe "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"}

function Get-HistoryActivation-S11e {
    param([object[]]$Rows,[string]$Asset)
    $ordered=@($Rows|Sort-Object response_day_utc)
    $n=0;$zero=0;$pos=0
    foreach($row in $ordered){
        $n++
        $v=D-S11e $row.NEWS_V6_MATCH_COUNT_24H_LAG15 "$Asset news24"
        if($v-eq0){$zero++}else{$pos++}
        if($n-ge20-and$zero-ge5-and$pos-ge5){
            $d=[datetime]::ParseExact([string]$row.response_day_utc,'yyyy-MM-dd',$Inv)
            $activation=$d.AddDays(1)
            return [pscustomobject]@{base_asset_id=$Asset;activation_date=$activation.ToString('yyyy-MM-dd',$Inv);trigger_response_day=[string]$row.response_day_utc;prior_rows=$n;zero_news_rows=$zero;positive_news_rows=$pos;history_supported=$true}
        }
    }
    return [pscustomobject]@{base_asset_id=$Asset;activation_date='';trigger_response_day='';prior_rows=$n;zero_news_rows=$zero;positive_news_rows=$pos;history_supported=$false}
}

function SelfTest-S11e {
    [double[]]$v=@(10,20,30,40,50,60,70,80,90,100)
    if((Pctl-S11e $v 0.10)-ne10-or(Pctl-S11e $v 0.50)-ne50-or(Pctl-S11e $v 0.90)-ne90){throw 'Percentile self-test failed'}
    $rows=New-Object Collections.ArrayList
    for($i=0;$i-lt20;$i++){
        $day=([datetime]'2025-04-01').AddDays($i).ToString('yyyy-MM-dd',$Inv)
        $news=if($i-lt10){'0'}else{'1'}
        [void]$rows.Add([pscustomobject]@{response_day_utc=$day;NEWS_V6_MATCH_COUNT_24H_LAG15=$news})
    }
    $a=Get-HistoryActivation-S11e @($rows.ToArray()) 'A'
    if(-not$a.history_supported-or$a.activation_date-ne'2025-04-21'-or$a.prior_rows-ne20-or$a.zero_news_rows-ne10-or$a.positive_news_rows-ne10){throw 'History activation self-test failed'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{SelfTest-S11e;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

$oldPwd=$env:PGPASSWORD;$oldOpt=$env:PGOPTIONS;$ptr=[IntPtr]::Zero
try{
    $contract=Get-Content -LiteralPath (File-S11e (Join-Path $RepoRoot 'docs\evidence\stage11-scanner-eligibility-contract.md') 'Stage 11 eligibility contract') -Raw
    foreach($marker in @('START_GAP_60 <= 15','END_GAP_60 <= 15','SPAN_60 >= 30','START_GAP_240 <= 30','SPAN_240 >= 180','nearest-rank p10','HISTORY_SUPPORTED','forward outcomes')){if($contract-notmatch[regex]::Escape($marker)){throw "Eligibility contract marker missing: $marker"}}

    $CalibrationSummaryPath=File-S11e $CalibrationSummaryPath 'calibration input summary'
    $calSha=Sha-S11e $CalibrationSummaryPath
    $cal=Get-Content -LiteralPath $CalibrationSummaryPath -Raw|ConvertFrom-Json
    if([string]$cal.status-ne'PASS'-or[string]$cal.stage-ne'CFA_STAGE_11_CALIBRATION_INPUTS'-or(Bool-S11e $cal.forward_outcomes_inspected 'forward_outcomes_inspected')){throw 'Calibration input summary identity/leakage state invalid.'}
    $v2Path=File-S11e ([string]$cal.source_readiness.v2_receipt) 'Stage 11 V2 receipt'
    $valPath=File-S11e ([string]$cal.source_readiness.independent_validation_receipt) 'Stage 11 V2R1 validation receipt'
    $v2Sha=Sha-S11e $v2Path;$valSha=Sha-S11e $valPath
    if($v2Sha-ne$ExpectedV2ReceiptSha-or$v2Sha-ne([string]$cal.source_readiness.v2_receipt_sha256).ToLowerInvariant()){throw 'Stage 11 V2 receipt SHA mismatch.'}
    if($valSha-ne$ExpectedV2ValidationSha-or$valSha-ne([string]$cal.source_readiness.independent_validation_receipt_sha256).ToLowerInvariant()){throw 'Stage 11 V2R1 validation receipt SHA mismatch.'}
    $v2=Get-Content -LiteralPath $v2Path -Raw|ConvertFrom-Json
    $val=Get-Content -LiteralPath $valPath -Raw|ConvertFrom-Json
    if([string]$v2.run-ne'SCANNER_SOURCE_READINESS_V2'-or[string]$val.status-ne'PASS'-or[string]$val.gates.'CFA-S11-006'-ne'PASS'){throw 'Validated Stage 11 source-readiness entry is not PASS.'}

    $entryPath=File-S11e ([string]$v2.outputs.source_entry_reconciliation) 'source entry reconciliation'
    $entry=Get-Content -LiteralPath $entryPath -Raw|ConvertFrom-Json
    $s10Path=File-S11e ([string]$entry.stage10.run_receipt) 'Stage 10 run receipt'
    if((Sha-S11e $s10Path)-ne$ExpectedStage10RunSha){throw 'Stage 10 run receipt SHA mismatch.'}
    $s10=Get-Content -LiteralPath $s10Path -Raw|ConvertFrom-Json
    $s7Path=File-S11e ([string]$s10.sources.stage7_validation_receipt) 'Stage 7 validation receipt'
    if((Sha-S11e $s7Path)-ne$ExpectedStage7ValidationSha){throw 'Stage 7 validation receipt SHA mismatch.'}
    $s7=Get-Content -LiteralPath $s7Path -Raw|ConvertFrom-Json
    $modelPath=File-S11e ([string]$s7.outputs.model_ready) 'Stage 7 model-ready CSV'
    if((Sha-S11e $modelPath)-ne$ExpectedModelReadySha){throw 'Stage 7 model-ready SHA mismatch.'}
    $model=@(Import-Csv -LiteralPath $modelPath)
    if($model.Count-ne26337){throw "Model-ready row count changed: $($model.Count)"}
    $required=@('base_asset_id','response_day_utc','NEWS_V6_MATCH_COUNT_24H_LAG15')
    foreach($name in $required){if(@($model[0].PSObject.Properties.Name)-notcontains$name){throw "Model-ready column missing: $name"}}
    $assets=@($model|Select-Object -ExpandProperty base_asset_id -Unique|Sort-Object)
    if($assets.Count-ne$ExpectedAssets){throw "Model-ready asset count changed: $($assets.Count)"}

    $history=New-Object Collections.ArrayList;$activationByAsset=@{}
    foreach($asset in $assets){$rows=@($model|Where-Object{[string]$_.base_asset_id-ceq$asset});$a=Get-HistoryActivation-S11e $rows $asset;[void]$history.Add($a);$activationByAsset[$asset]=[string]$a.activation_date}

    $afPath=File-S11e (Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv') 'AF-001'
    if((Sha-S11e $afPath)-ne$ExpectedAfSha){throw 'AF-001 SHA mismatch.'}
    $af=@(Import-Csv -LiteralPath $afPath)
    $usd=@($af|Where-Object{(Bool-S11e $_.research_eligible 'research_eligible')-and([string]$_.quote_exchange_symbol).Trim()-ceq'USD'})
    $map=@{};foreach($row in $usd){$map[[string]$row.base_asset_id]=$row}
    $values=New-Object Collections.ArrayList
    foreach($asset in $assets){
        if(-not$map.ContainsKey($asset)){throw "No direct-USD mapping for $asset"}
        $ord=([string]$map[$asset].source_member_ordinal).Trim();if($ord-notmatch'^\d+$'){throw "Non-numeric source_member_ordinal for ${asset}: $ord"}
        $escaped=$asset.Replace("'","''")
        $act=[string]$activationByAsset[$asset]
        $actSql=if([string]::IsNullOrWhiteSpace($act)){'NULL::date'}else{"DATE '$act'"}
        [void]$values.Add("($ord,'$escaped',$actSql)")
    }
    $assetValues=$values.ToArray()-join','

    $exe=FindPsql-S11e
    $secure=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString;$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    $env:PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000)"
    $version=(PsqlText-S11e $exe 'SHOW server_version;').Trim();$ro=(PsqlText-S11e $exe "SELECT current_setting('default_transaction_read_only');").Trim();if($ro-ne'on'){throw 'PostgreSQL session is not read-only.'}
    $card=@((PsqlCsv-S11e $exe "SELECT count(*)::bigint row_count,count(DISTINCT pair_token_opaque)::int pair_count FROM asrp.q2_market_1m_observations")|ConvertFrom-Csv)[0]
    if([long]$card.row_count-ne$ExpectedMarketRows-or[int]$card.pair_count-ne$ExpectedPairs){throw 'Frozen market cardinality mismatch.'}

    $q=@"
WITH scanner_assets(source_member_ordinal,base_asset_id,history_activation_date) AS (VALUES $assetValues),
bins AS MATERIALIZED (
  SELECT m.source_member_ordinal,
         date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00') AS bin_start,
         count(*)::int AS obs_count,min(m.candle_start_utc) AS first_ts,max(m.candle_start_utc) AS last_ts
  FROM asrp.q2_market_1m_observations m
  JOIN scanner_assets a USING(source_member_ordinal)
  WHERE m.candle_start_utc>=timestamptz '2025-04-01 00:00:00+00'
    AND m.candle_start_utc<timestamptz '2025-07-01 00:00:00+00'
    AND m.canonical_eligible AND m.in_source_window AND m.minute_aligned
    AND cardinality(m.quality_flags)=0 AND m.duplicate_class IS NULL
  GROUP BY m.source_member_ordinal,date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00')
),grid AS MATERIALIZED (
  SELECT a.source_member_ordinal,a.base_asset_id,a.history_activation_date,g.bin_start,
         coalesce(b.obs_count,0)::int AS obs_count,b.first_ts,b.last_ts
  FROM scanner_assets a
  CROSS JOIN generate_series(timestamptz '2025-04-01 00:00:00+00',timestamptz '2025-06-30 23:45:00+00',interval '15 minutes') g(bin_start)
  LEFT JOIN bins b ON b.source_member_ordinal=a.source_member_ordinal AND b.bin_start=g.bin_start
),roll AS MATERIALIZED (
  SELECT base_asset_id,history_activation_date,bin_start+interval '15 minutes' AS scan_ts,
         sum(obs_count) OVER w60 AS obs60,min(first_ts) OVER w60 AS first60,max(last_ts) OVER w60 AS last60,
         sum(obs_count) OVER w240 AS obs240,min(first_ts) OVER w240 AS first240,max(last_ts) OVER w240 AS last240
  FROM grid
  WINDOW w60 AS (PARTITION BY base_asset_id ORDER BY bin_start ROWS BETWEEN 3 PRECEDING AND CURRENT ROW),
         w240 AS (PARTITION BY base_asset_id ORDER BY bin_start ROWS BETWEEN 15 PRECEDING AND CURRENT ROW)
),x AS MATERIALIZED (
  SELECT base_asset_id,history_activation_date,scan_ts,z.horizon_minutes,z.obs_count,z.first_ts,z.last_ts,
         CASE WHEN z.obs_count>0 THEN extract(epoch FROM(z.first_ts-(scan_ts-make_interval(mins=>z.horizon_minutes))))/60.0 END AS start_gap,
         CASE WHEN z.obs_count>0 THEN extract(epoch FROM(scan_ts-z.last_ts))/60.0 END AS end_gap,
         CASE WHEN z.obs_count>0 THEN extract(epoch FROM(z.last_ts-z.first_ts))/60.0 END AS span_minutes
  FROM roll CROSS JOIN LATERAL(VALUES(60,obs60,first60,last60),(240,obs240,first240,last240))z(horizon_minutes,obs_count,first_ts,last_ts)
  WHERE scan_ts>=timestamptz '2025-04-02 00:15:00+00' AND scan_ts<timestamptz '2025-07-01 00:00:00+00'
),flags AS MATERIALIZED (
  SELECT *,
    CASE WHEN horizon_minutes=60 THEN (obs_count>=2 AND start_gap<=15 AND end_gap<=15 AND span_minutes>=30)
         WHEN horizon_minutes=240 THEN (obs_count>=2 AND start_gap<=30 AND end_gap<=15 AND span_minutes>=180)
         ELSE false END AS market_eligible,
    (history_activation_date IS NOT NULL AND (scan_ts AT TIME ZONE 'UTC')::date>=history_activation_date) AS history_supported
  FROM x
)
SELECT to_char(scan_ts AT TIME ZONE 'UTC','YYYY-MM-DD')||'T'||to_char(scan_ts AT TIME ZONE 'UTC','HH24:MI:SS')||'Z' AS scan_timestamp_utc,
       horizon_minutes,
       count(*) FILTER(WHERE market_eligible)::int AS eligible_market_assets,
       count(*) FILTER(WHERE history_supported)::int AS history_supported_assets,
       count(*) FILTER(WHERE market_eligible AND history_supported)::int AS market_and_history_eligible_assets
FROM flags
GROUP BY scan_ts,horizon_minutes
ORDER BY scan_ts,horizon_minutes
"@
    $surface=@((PsqlCsv-S11e $exe $q)|ConvertFrom-Csv)
    if($surface.Count-ne($ExpectedScans*2)){throw "Eligibility surface row count mismatch: $($surface.Count)"}
    $bad=@($surface|Where-Object{([string]$_.scan_timestamp_utc)-notmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'});if($bad.Count-ne0){throw "Malformed eligibility timestamps: $($bad.Count)"}
    $dups=@($surface|Group-Object scan_timestamp_utc,horizon_minutes|Where-Object{$_.Count-ne1});if($dups.Count-ne0){throw "Duplicate eligibility keys: $($dups.Count)"}

    $summaryRows=New-Object Collections.ArrayList;$breadthThreshold=@{}
    foreach($h in @(60,240)){
        $rows=@($surface|Where-Object{[int]$_.horizon_minutes-eq$h});[double[]]$vals=@($rows|ForEach-Object{[double]$_.eligible_market_assets})
        $min=[int](($vals|Measure-Object -Minimum).Minimum);$p10=[int](Pctl-S11e $vals 0.10);$p50=[int](Pctl-S11e $vals 0.50);$p90=[int](Pctl-S11e $vals 0.90);$max=[int](($vals|Measure-Object -Maximum).Maximum)
        $breadthThreshold[$h]=$p10;$pass=@($rows|Where-Object{[int]$_.eligible_market_assets-ge$p10}).Count
        [void]$summaryRows.Add([pscustomobject][ordered]@{horizon_minutes=$h;scan_count=$rows.Count;eligible_breadth_min=$min;eligible_breadth_p10=$p10;eligible_breadth_median=$p50;eligible_breadth_p90=$p90;eligible_breadth_max=$max;frozen_min_breadth_candidate=$p10;scans_meeting_candidate_breadth=$pass;share_meeting_candidate_breadth=($pass/[double]$rows.Count).ToString('R',$Inv)})
    }

    $newsPath=File-S11e ([string]$v2.outputs.news_scan_window_readiness) 'news scan readiness'
    $news=@(Import-Csv -LiteralPath $newsPath);if($news.Count-ne$ExpectedScans){throw 'News scan readiness row count changed.'}
    $surface60=@($surface|Where-Object{[int]$_.horizon_minutes-eq60});$s60=@{};foreach($row in $surface60){$s60[[string]$row.scan_timestamp_utc]=$row}
    $tech=New-Object Collections.ArrayList;$totalTechnical=0L;$eligibleScans=0
    foreach($nrow in $news){
        $ts=[string]$nrow.scan_timestamp_utc;if(-not$s60.ContainsKey($ts)){throw "Missing 60m eligibility scan: $ts"};$mrow=$s60[$ts]
        $newsEligible=(Bool-S11e $nrow.news24_complete 'news24_complete')-and(Bool-S11e $nrow.news6_complete 'news6_complete')
        $breadthPass=([int]$mrow.eligible_market_assets-ge[int]$breadthThreshold[60])
        $count=if($newsEligible-and$breadthPass){[int]$mrow.market_and_history_eligible_assets}else{0}
        if($count-gt0){$eligibleScans++};$totalTechnical+=$count
        [void]$tech.Add([pscustomobject][ordered]@{scan_timestamp_utc=$ts;news_eligible=$newsEligible;eligible_market_assets_60m=[int]$mrow.eligible_market_assets;frozen_min_breadth_candidate_60m=[int]$breadthThreshold[60];breadth_pass=$breadthPass;history_supported_assets=[int]$mrow.history_supported_assets;market_and_history_eligible_assets=[int]$mrow.market_and_history_eligible_assets;technical_eligible_symbol_scans=$count})
    }

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Split-Path -Parent $CalibrationSummaryPath}
    if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $historyPath=Join-Path $OutputRoot 'stage11-scanner-history-support-activation.csv'
    $surfacePath=Join-Path $OutputRoot 'stage11-scanner-source-only-eligibility-surface.csv'
    $summaryPath=Join-Path $OutputRoot 'stage11-scanner-source-only-eligibility-summary.csv'
    $techPath=Join-Path $OutputRoot 'stage11-scanner-technical-eligibility-by-scan.csv'
    $receiptPath=Join-Path $OutputRoot 'stage11-scanner-source-only-eligibility-receipt.json'
    @($history.ToArray())|Sort-Object base_asset_id|Export-Csv -LiteralPath $historyPath -NoTypeInformation -Encoding UTF8
    $surface|Export-Csv -LiteralPath $surfacePath -NoTypeInformation -Encoding UTF8
    @($summaryRows.ToArray())|Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8
    @($tech.ToArray())|Export-Csv -LiteralPath $techPath -NoTypeInformation -Encoding UTF8

    $histSupported=@($history|Where-Object{$_.history_supported}).Count
    $receipt=[ordered]@{
        status='VALIDATION_CANDIDATE';stage='CFA_STAGE_11';run='SCANNER_SOURCE_ONLY_ELIGIBILITY_V1';forward_outcomes_inspected=$false;
        sources=[ordered]@{calibration_summary=$CalibrationSummaryPath;calibration_summary_sha256=$calSha;stage11_v2_receipt=$v2Path;stage11_v2_receipt_sha256=$v2Sha;stage11_v2r1_validation=$valPath;stage11_v2r1_validation_sha256=$valSha;stage10_run_receipt=$s10Path;stage10_run_receipt_sha256=$ExpectedStage10RunSha;stage7_validation_receipt=$s7Path;stage7_validation_receipt_sha256=$ExpectedStage7ValidationSha;model_ready=$modelPath;model_ready_sha256=$ExpectedModelReadySha;market_relation='asrp.q2_market_1m_observations'};
        rules=[ordered]@{market60='obs>=2,start_gap<=15,end_gap<=15,span>=30';market240='obs>=2,start_gap<=30,end_gap<=15,span>=180';breadth_rule='nearest-rank p10 of eligible market breadth across 8639 candidate scans';history_support='prior model-ready rows>=20, zero news24>=5, positive news24>=5, response_day_utc < scan UTC date';news_support='24h AND 6h source windows complete'};
        counts=[ordered]@{assets=$ExpectedAssets;candidate_scans=$ExpectedScans;history_supported_assets_eventually=$histSupported;technical_eligible_scans=$eligibleScans;technical_eligible_symbol_scans=$totalTechnical};
        derived_thresholds=[ordered]@{market60_min_breadth=[int]$breadthThreshold[60];market240_min_breadth=[int]$breadthThreshold[240]};
        outputs=[ordered]@{history_activation=$historyPath;history_activation_sha256=(Sha-S11e $historyPath);eligibility_surface=$surfacePath;eligibility_surface_sha256=(Sha-S11e $surfacePath);eligibility_summary=$summaryPath;eligibility_summary_sha256=(Sha-S11e $summaryPath);technical_eligibility_by_scan=$techPath;technical_eligibility_by_scan_sha256=(Sha-S11e $techPath)};
        gates=[ordered]@{'CFA-S11-007A'='PASS';'CFA-S11-007B'='PASS';'CFA-S11-007C'='BLOCKED';'CFA-S11-007'='BLOCKED';'CFA-S11-008'='BLOCKED'}
    }
    Json-S11e $receiptPath $receipt

    Write-Host ''
    Write-Host 'CFA STAGE 11 SOURCE-ONLY SCANNER ELIGIBILITY: VALIDATION CANDIDATE'
    Write-Host "PostgreSQL: $version"
    Write-Host "Session mode: default_transaction_read_only=$ro"
    Write-Host "Assets / candidate scans: $ExpectedAssets / $ExpectedScans"
    Write-Host "History-supported assets eventually: $histSupported"
    foreach($row in @($summaryRows.ToArray())){Write-Host ("Eligible market breadth {0}m min / p10 / median / p90 / max: {1} / {2} / {3} / {4} / {5}" -f $row.horizon_minutes,$row.eligible_breadth_min,$row.eligible_breadth_p10,$row.eligible_breadth_median,$row.eligible_breadth_p90,$row.eligible_breadth_max)}
    Write-Host "Frozen breadth candidates 60m / 240m: $($breadthThreshold[60]) / $($breadthThreshold[240])"
    Write-Host "Scans with >=1 technically eligible symbol: $eligibleScans / $ExpectedScans"
    Write-Host "Total technically eligible symbol-scans: $totalTechnical"
    Write-Host 'Forward outcomes inspected: False'
    Write-Host 'CFA-S11-007A source-only eligibility rules: PASS'
    Write-Host 'CFA-S11-007B source-only eligibility surface: PASS'
    Write-Host 'CFA-S11-007C independent validation: BLOCKED'
    Write-Host 'CFA-S11-007 scanner eligibility freeze: BLOCKED'
    Write-Host "Eligibility summary: $summaryPath"
    Write-Host "Technical eligibility by scan: $techPath"
    Write-Host "Receipt: $receiptPath"
    exit 0
}catch{
    Write-Host ''
    Write-Host 'CFA STAGE 11 SOURCE-ONLY SCANNER ELIGIBILITY: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    if($ptr-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
    $env:PGPASSWORD=$oldPwd;$env:PGOPTIONS=$oldOpt
}
