#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RunReceiptPath,
    [string]$PgHost='localhost',
    [ValidateRange(1,65535)][int]$PgPort=5432,
    [string]$PgUser='postgres',
    [ValidateRange(60,1800)][int]$StatementTimeoutSeconds=900,
    [string]$RepoRoot='',
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ExpectedStage10ProfileSha='2d625ed8a79f17cf2a6ac21e22fea62fa3a1a04f9cfa51d9b0ec7ef861e304fd'
$ExpectedAf001Sha='569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f'
$ExpectedAssets=418
$ExpectedScans=8639
if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
function Sha-S11r{param([string]$p);return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function File-S11r{param([string]$p,[string]$l);$x=(Resolve-Path -LiteralPath $p -ErrorAction Stop).ProviderPath;if(-not(Test-Path -LiteralPath $x -PathType Leaf)){throw "$l is not a file: $x"};return $x}
function Bool-S11r{param($v);$x=([string]$v).Trim().ToLowerInvariant();if($x-in@('true','t')){return $true};if($x-in@('false','f')){return $false};throw "Malformed boolean: $v"}
function FindPsql-S11r{$c=Get-Command psql.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;if($null-ne$c){return $c.Source};$f=@(Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -File -ErrorAction SilentlyContinue|Sort-Object FullName -Descending);if($f.Count-eq0){throw 'psql.exe not found'};return $f[0].FullName}
function PsqlText-S11r{param($exe,$sql);$e=[IO.Path]::GetTempFileName();try{$o=@(& $exe -X -h $PgHost -p $PgPort -U $PgUser -d asrp -A -t -q -v ON_ERROR_STOP=1 -c $sql 2>$e);$c=$LASTEXITCODE;$err=(Get-Content -LiteralPath $e -ErrorAction SilentlyContinue)-join[Environment]::NewLine;$t=($o|ForEach-Object{[string]$_})-join[Environment]::NewLine;if($c-ne0){throw "psql failed ($c).`n$err`n$t"};return $t}finally{Remove-Item $e -Force -ErrorAction SilentlyContinue}}
function PsqlCsv-S11r{param($exe,$q);$q=$q.Trim();return PsqlText-S11r $exe "COPY (`n$q`n) TO STDOUT WITH (FORMAT CSV, HEADER TRUE);"}
function Json-S11r{param($p,$v);[IO.File]::WriteAllText($p,(($v|ConvertTo-Json -Depth 12)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))}
function SelfTest-S11r{$s='2025-04-02T00:15:00Z';if($s-notmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'){throw 'UTC regex self-test failed'};Write-Host 'SELF-TEST: PASS'}
if($SelfTest){try{SelfTest-S11r;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}
$oldPwd=$env:PGPASSWORD;$oldOpt=$env:PGOPTIONS;$b=[IntPtr]::Zero
try{
    $RunReceiptPath=File-S11r $RunReceiptPath 'Stage 11 V1 receipt';$v1Sha=Sha-S11r $RunReceiptPath;$r=Get-Content -LiteralPath $RunReceiptPath -Raw|ConvertFrom-Json
    if([string]$r.status-ne'VALIDATION_CANDIDATE'-or[string]$r.run-ne'SCANNER_SOURCE_READINESS_V1'){throw 'Input is not Stage 11 V1 candidate.'}
    foreach($name in @('source_entry_reconciliation','news_scan_window_readiness','news_readiness_summary','market_readiness_summary','market_breadth_readiness')){$p=File-S11r ([string]$r.outputs.$name) $name;$hs=[string]$r.outputs.($name+'_sha256');if((Sha-S11r $p)-ne$hs){throw "V1 output hash mismatch: $name"}}
    $entryPath=File-S11r ([string]$r.outputs.source_entry_reconciliation) 'source entry';$entry=Get-Content -LiteralPath $entryPath -Raw|ConvertFrom-Json
    $profilePath=File-S11r ([string]$entry.stage10.profile) 'Stage 10 profile';if((Sha-S11r $profilePath)-ne$ExpectedStage10ProfileSha){throw 'Stage 10 profile hash mismatch'};$profile=@(Import-Csv $profilePath);$assets=@($profile|ForEach-Object{[string]$_.base_asset_id}|Sort-Object -Unique);if($assets.Count-ne$ExpectedAssets){throw 'Stage 10 asset count mismatch'}
    $afPath=File-S11r (Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv') 'AF-001';if((Sha-S11r $afPath)-ne$ExpectedAf001Sha){throw 'AF-001 hash mismatch'};$af=@(Import-Csv $afPath);$usd=@($af|Where-Object{(Bool-S11r $_.research_eligible)-and([string]$_.quote_exchange_symbol).Trim()-ceq'USD'});$map=@{};foreach($x in $usd){$map[[string]$x.base_asset_id]=$x};$vals=New-Object Collections.ArrayList;foreach($a in $assets){if(-not$map.ContainsKey($a)){throw "No USD mapping for $a"};[void]$vals.Add("("+([string]$map[$a].source_member_ordinal).Trim()+",'"+$a.Replace("'","''")+"')")};$values=$vals.ToArray()-join','
    $psql=FindPsql-S11r;$secure=Read-Host "PostgreSQL password for '$PgUser'" -AsSecureString;$b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure);$env:PGPASSWORD=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b);$env:PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=$($StatementTimeoutSeconds*1000)";if((PsqlText-S11r $psql "SELECT current_setting('default_transaction_read_only');").Trim()-ne'on'){throw 'PostgreSQL is not read-only'}
    $q=@"
WITH scanner_assets(source_member_ordinal,base_asset_id) AS (VALUES $values),
bins AS MATERIALIZED (
 SELECT m.source_member_ordinal,date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00') bin_start,count(*)::int obs_count
 FROM asrp.q2_market_1m_observations m JOIN scanner_assets a USING(source_member_ordinal)
 WHERE m.candle_start_utc>=timestamptz '2025-04-01 00:00:00+00' AND m.candle_start_utc<timestamptz '2025-07-01 00:00:00+00'
 AND m.canonical_eligible AND m.in_source_window AND m.minute_aligned AND cardinality(m.quality_flags)=0 AND m.duplicate_class IS NULL
 GROUP BY m.source_member_ordinal,date_bin(interval '15 minutes',m.candle_start_utc,timestamptz '2025-04-01 00:00:00+00')
),grid AS MATERIALIZED (
 SELECT a.base_asset_id,g.bin_start,coalesce(b.obs_count,0)::int obs_count FROM scanner_assets a
 CROSS JOIN generate_series(timestamptz '2025-04-01 00:00:00+00',timestamptz '2025-06-30 23:45:00+00',interval '15 minutes') g(bin_start)
 LEFT JOIN bins b ON b.source_member_ordinal=a.source_member_ordinal AND b.bin_start=g.bin_start
),roll AS MATERIALIZED (
 SELECT base_asset_id,bin_start+interval '15 minutes' scan_ts,
 sum(obs_count) OVER(PARTITION BY base_asset_id ORDER BY bin_start ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) obs60,
 sum(obs_count) OVER(PARTITION BY base_asset_id ORDER BY bin_start ROWS BETWEEN 15 PRECEDING AND CURRENT ROW) obs240 FROM grid
),x AS (
 SELECT base_asset_id,scan_ts,v.horizon_minutes,v.obs_count FROM roll
 CROSS JOIN LATERAL(VALUES(60,obs60),(240,obs240))v(horizon_minutes,obs_count)
 WHERE scan_ts>=timestamptz '2025-04-02 00:15:00+00' AND scan_ts<timestamptz '2025-07-01 00:00:00+00'
)
SELECT to_char(scan_ts AT TIME ZONE 'UTC','YYYY-MM-DD')||'T'||to_char(scan_ts AT TIME ZONE 'UTC','HH24:MI:SS')||'Z' scan_timestamp_utc,
 horizon_minutes,count(*) FILTER(WHERE obs_count>0)::int assets_with_any,(count(*) FILTER(WHERE obs_count>0)::double precision/418.0) breadth_share
FROM x GROUP BY scan_ts,horizon_minutes ORDER BY scan_ts,horizon_minutes
"@
    $rows=@((PsqlCsv-S11r $psql $q)|ConvertFrom-Csv);if($rows.Count-ne($ExpectedScans*2)){throw "Corrected breadth row count mismatch: $($rows.Count)"}
    $bad=@($rows|Where-Object{([string]$_.scan_timestamp_utc)-notmatch'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'});if($bad.Count-ne0){throw "Malformed corrected timestamps: $($bad.Count)"};$dups=@($rows|Group-Object scan_timestamp_utc,horizon_minutes|Where-Object{$_.Count-ne1});if($dups.Count-ne0){throw "Duplicate corrected breadth keys: $($dups.Count)"}
    $dir=Split-Path -Parent $RunReceiptPath;$breadthV2=Join-Path $dir 'stage11-market-breadth-readiness-v2.csv';$receiptV2=Join-Path $dir 'stage11-source-readiness-run-receipt-v2.json';$rows|Export-Csv -LiteralPath $breadthV2 -NoTypeInformation -Encoding UTF8
    $v2=[ordered]@{status='VALIDATION_CANDIDATE';stage='CFA_STAGE_11';run='SCANNER_SOURCE_READINESS_V2';correction='V1 breadth scan_timestamp_utc serialization invalid; V2 regenerates breadth only with canonical UTC timestamps';prior_v1_receipt=$RunReceiptPath;prior_v1_receipt_sha256=$v1Sha;sources=$r.sources;scan_clock=$r.scan_clock;market_probe=$r.market_probe;outputs=[ordered]@{source_entry_reconciliation=$r.outputs.source_entry_reconciliation;source_entry_reconciliation_sha256=$r.outputs.source_entry_reconciliation_sha256;news_scan_window_readiness=$r.outputs.news_scan_window_readiness;news_scan_window_readiness_sha256=$r.outputs.news_scan_window_readiness_sha256;news_readiness_summary=$r.outputs.news_readiness_summary;news_readiness_summary_sha256=$r.outputs.news_readiness_summary_sha256;market_readiness_summary=$r.outputs.market_readiness_summary;market_readiness_summary_sha256=$r.outputs.market_readiness_summary_sha256;market_breadth_readiness=$breadthV2;market_breadth_readiness_sha256=(Sha-S11r $breadthV2)};gates=[ordered]@{'CFA-S11-001'='PASS';'CFA-S11-002'='PASS';'CFA-S11-003'='PASS';'CFA-S11-004'='PASS';'CFA-S11-005'='PASS';'CFA-S11-006'='BLOCKED';'CFA-S11-007'='BLOCKED';'CFA-S11-008'='BLOCKED'}};Json-S11r $receiptV2 $v2
    Write-Host '';Write-Host 'CFA STAGE 11 BREADTH TIMESTAMP V2 REPAIR: VALIDATION CANDIDATE';Write-Host "Corrected breadth rows: $($rows.Count)";Write-Host "Unique breadth keys: $($rows.Count)";Write-Host 'Forward outcomes inspected: False';Write-Host "Corrected breadth: $breadthV2";Write-Host "V2 receipt: $receiptV2";exit 0
}catch{Write-Host '';Write-Host 'CFA STAGE 11 BREADTH TIMESTAMP V2 REPAIR: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}finally{if($b-ne[IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)};$env:PGPASSWORD=$oldPwd;$env:PGOPTIONS=$oldOpt}
