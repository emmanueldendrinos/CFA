#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CandidateReceiptPath = '',
    [string]$ReviewCsvPath = '',
    [string]$RepoRoot = '',
    [string]$OutputRoot = '',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$ExpectedResponseId = 'RET_USD_UTC_DAY_OBS_LOG'
$ExpectedContract = 'CANDIDATE_UTC_DAY_OBSERVED_V3'
$ExpectedResponseRows = 37058
$ExpectedDistinctBases = 434
$ExpectedReviewRows = 49
$ExpectedCandidateSha256 = 'd76659f58d2d0ca7bc8dba9af3bc7782968dfb36ba98c3f7ad2cbf5a0b7e1ad2'
$ExpectedReviewSha256 = '07458d4f73546e3e380b322c728623d8f72663f0909a4493d60ea23ca83a351c'
$ExpectedResponsesSha256 = '8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedDaySummarySha256 = '7402e19fb05014de59e90b0a2c7173eab40615dca6d2a831b454850d964267a6'

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([string]$Path,[AllowNull()][string]$Content)
    if ($null -eq $Content) { $Content = '' }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}

function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $n = 0.0
    if (-not [double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)) { throw "Malformed numeric value for ${Label}: '$Value'" }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { throw "Non-finite numeric value for ${Label}: '$Value'" }
    return $n
}

function Parse-Utc {
    param([object]$Value,[string]$Label)
    try { return [DateTimeOffset]::Parse([string]$Value,$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime }
    catch { throw "Malformed UTC timestamp for ${Label}: '$Value'" }
}

function Assert-ResponseRow {
    param([object]$Row,[string]$Label)
    if ([string]$Row.response_id -cne $ExpectedResponseId) { throw "$Label response_id mismatch." }
    $day = [datetime]::ParseExact([string]$Row.response_day_utc,'yyyy-MM-dd',$Invariant)
    $dayUtc = [datetime]::SpecifyKind($day,[DateTimeKind]::Utc)
    $cutoff = Parse-Utc $Row.predictor_cutoff_utc "$Label predictor_cutoff_utc"
    $windowStart = Parse-Utc $Row.response_window_start_utc "$Label response_window_start_utc"
    $windowEnd = Parse-Utc $Row.response_window_end_exclusive_utc "$Label response_window_end_exclusive_utc"
    $available = Parse-Utc $Row.response_available_utc "$Label response_available_utc"
    $firstTs = Parse-Utc $Row.first_candle_start_utc "$Label first_candle_start_utc"
    $lastTs = Parse-Utc $Row.last_candle_start_utc "$Label last_candle_start_utc"
    if ($cutoff -ne $dayUtc -or $windowStart -ne $dayUtc) { throw "$Label cutoff/window-start mismatch." }
    if ($windowEnd -ne $dayUtc.AddDays(1) -or $available -ne $windowEnd) { throw "$Label window-end/availability mismatch." }
    if ($firstTs -lt $cutoff -or $firstTs -ge $windowEnd) { throw "$Label first selected observation is outside the response window." }
    if ($lastTs -lt $firstTs -or $lastTs -ge $windowEnd) { throw "$Label last selected observation is outside/order-invalid." }
    $firstMinutes = $firstTs.Hour*60 + $firstTs.Minute
    $lastLag = 1439-($lastTs.Hour*60 + $lastTs.Minute)
    $span = [int](($lastTs-$firstTs).TotalMinutes)
    if ([int]$Row.first_minutes_after_midnight -ne $firstMinutes) { throw "$Label first_minutes_after_midnight mismatch." }
    if ([int]$Row.last_minutes_before_midnight -ne $lastLag) { throw "$Label last_minutes_before_midnight mismatch." }
    if ([int]$Row.observed_span_minutes_between_starts -ne $span) { throw "$Label observed_span mismatch." }
    $first = Parse-DoubleStrict $Row.first_open_price_usd "$Label first_open_price_usd"
    $last = Parse-DoubleStrict $Row.last_close_price_usd "$Label last_close_price_usd"
    $actual = Parse-DoubleStrict $Row.response_value_log_return "$Label response_value_log_return"
    if ($first -le 0 -or $last -le 0) { throw "$Label contains a non-positive selected price." }
    $expected = [Math]::Log($last/$first)
    if ([Math]::Abs($actual-$expected) -gt 1e-12) { throw "$Label formula mismatch." }
    foreach ($name in @('first_raw_record_sha256','last_raw_record_sha256')) {
        if ([string]$Row.$name -cnotmatch '^[0-9a-f]{64}$') { throw "$Label $name is not a lowercase SHA-256." }
    }
    foreach ($name in @('first_physical_record_number','last_physical_record_number')) {
        $v = 0L
        if (-not [long]::TryParse([string]$Row.$name,[ref]$v) -or $v -le 0) { throw "$Label $name is invalid." }
    }
}

function Invoke-SelfTest {
    $row = [pscustomobject]@{
        response_id=$ExpectedResponseId;base_asset_id='A';pair_token_opaque='AUSD';source_member_ordinal='1';response_day_utc='2025-04-02';
        predictor_cutoff_utc='2025-04-02T00:00:00Z';response_window_start_utc='2025-04-02T00:00:00Z';response_window_end_exclusive_utc='2025-04-03T00:00:00Z';response_available_utc='2025-04-03T00:00:00Z';
        first_candle_start_utc='2025-04-02T00:03:00Z';last_candle_start_utc='2025-04-02T19:00:00Z';first_minutes_after_midnight='3';last_minutes_before_midnight='299';observed_span_minutes_between_starts='1137';
        first_open_price_usd='100';last_close_price_usd='110';response_value_log_return=([Math]::Log(1.1).ToString('R',$Invariant));first_physical_record_number='1';last_physical_record_number='2';first_raw_record_sha256=('a'*64);last_raw_record_sha256=('b'*64)
    }
    Assert-ResponseRow $row 'selftest'
    $bad = $row.PSObject.Copy(); $bad.first_candle_start_utc='2025-04-01T23:59:00Z'
    $failed=$false
    try { Assert-ResponseRow $bad 'negative selftest' } catch { $failed=$true }
    if (-not $failed) { throw 'Negative self-test did not reject a pre-cutoff observation.' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if ([string]::IsNullOrWhiteSpace($CandidateReceiptPath) -or -not (Test-Path -LiteralPath $CandidateReceiptPath -PathType Leaf)) { throw 'CandidateReceiptPath must identify the exact local V3 candidate receipt.' }
    if ([string]::IsNullOrWhiteSpace($ReviewCsvPath) -or -not (Test-Path -LiteralPath $ReviewCsvPath -PathType Leaf)) { throw 'ReviewCsvPath must identify the exact local V3 review CSV.' }
    $CandidateReceiptPath = (Resolve-Path -LiteralPath $CandidateReceiptPath).ProviderPath
    $ReviewCsvPath = (Resolve-Path -LiteralPath $ReviewCsvPath).ProviderPath
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage4-freeze-v3' }
    $runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $contractPath = Join-Path $RepoRoot 'docs\evidence\stage4-response-contract.md'
    $reviewEvidencePath = Join-Path $RepoRoot 'docs\evidence\stage4-v3-bounded-response-review-20260831.md'
    $adjudicationPath = Join-Path $RepoRoot 'docs\evidence\stage4-v3-review-adjudication-20260831.json'
    foreach ($p in @($contractPath,$reviewEvidencePath,$adjudicationPath)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Required Stage 4 freeze evidence missing: $p" } }
    $contract = Get-Content -LiteralPath $contractPath -Raw
    $reviewEvidence = Get-Content -LiteralPath $reviewEvidencePath -Raw
    if ($contract -notmatch 'CFA-S4-014' -or $contract -notmatch 'CFA-S4-015') { throw 'Stage 4 contract is missing V3 review/freeze gates.' }
    if ($reviewEvidence -notmatch 'V3_DIRECT_REVIEW_PASS' -or $reviewEvidence -notmatch 'CFA-S4-014.*PASS') { throw 'Checked-in V3 direct review is not PASS.' }

    if ((Get-Sha $CandidateReceiptPath) -ne $ExpectedCandidateSha256) { throw 'V3 candidate receipt SHA-256 mismatch.' }
    if ((Get-Sha $ReviewCsvPath) -ne $ExpectedReviewSha256) { throw 'V3 review CSV SHA-256 mismatch.' }
    $candidate = Get-Content -LiteralPath $CandidateReceiptPath -Raw | ConvertFrom-Json
    if ([string]$candidate.status -cne 'VALIDATION_CANDIDATE' -or [string]$candidate.stage -cne 'CFA_STAGE_4') { throw 'Candidate receipt status/stage mismatch.' }
    if ([string]$candidate.response_contract -cne $ExpectedContract -or [string]$candidate.response_id -cne $ExpectedResponseId) { throw 'Candidate response contract/ID mismatch.' }
    if ([int]$candidate.direct_usd_pairs -ne 434 -or [int]$candidate.direct_usd_bases -ne 434 -or [int]$candidate.active_usd_pair_days -ne $ExpectedResponseRows -or [int]$candidate.response_rows -ne $ExpectedResponseRows -or [int]$candidate.distinct_response_bases -ne $ExpectedDistinctBases) { throw 'Candidate response counts do not match the frozen V3 candidate.' }
    if ([string]$candidate.min_response_day -cne '2025-04-01' -or [string]$candidate.max_response_day -cne '2025-06-30') { throw 'Candidate response day range mismatch.' }
    if ([string]$candidate.responses_sha256 -cne $ExpectedResponsesSha256 -or [string]$candidate.review_sample_sha256 -cne $ExpectedReviewSha256 -or [string]$candidate.day_summary_sha256 -cne $ExpectedDaySummarySha256) { throw 'Candidate-declared artifact SHA-256 values changed.' }
    if ([string]$candidate.gates.'CFA-S4-012' -cne 'PASS' -or [string]$candidate.gates.'CFA-S4-013' -cne 'PASS' -or [string]$candidate.gates.'CFA-S4-014' -cne 'UNVERIFIED' -or [string]$candidate.gates.'CFA-S4-015' -cne 'BLOCKED') { throw 'Candidate gate state is not the expected pre-freeze state.' }

    $adjudication = Get-Content -LiteralPath $adjudicationPath -Raw | ConvertFrom-Json
    if ([string]$adjudication.candidate_receipt_sha256 -cne $ExpectedCandidateSha256 -or [string]$adjudication.review_csv_sha256 -cne $ExpectedReviewSha256) { throw 'Adjudication manifest artifact hashes do not match the frozen review.' }
    if ([int]$adjudication.review_rows -ne $ExpectedReviewRows -or [string]$adjudication.review_conclusion -cne 'PASS' -or [int]$adjudication.decision_summary.PASS -ne $ExpectedReviewRows -or [int]$adjudication.decision_summary.FAIL -ne 0 -or [int]$adjudication.decision_summary.UNVERIFIED -ne 0) { throw 'Adjudication manifest is not an all-PASS 49-row decision set.' }

    $reviewRows = @(Import-Csv -LiteralPath $ReviewCsvPath)
    if ($reviewRows.Count -ne $ExpectedReviewRows) { throw "Review row count mismatch: $($reviewRows.Count)." }
    $decisions = @($adjudication.decisions)
    if ($decisions.Count -ne $ExpectedReviewRows) { throw 'Adjudication decision row count mismatch.' }
    $reviewSeen=@{}
    for ($i=0; $i -lt $reviewRows.Count; $i++) {
        $r=$reviewRows[$i]; $d=$decisions[$i]; $label="review row $($i+1)"
        if ([int]$d.row_ordinal -ne ($i+1) -or [string]$d.base_asset_id -cne [string]$r.base_asset_id -or [string]$d.response_day_utc -cne [string]$r.response_day_utc -or [string]$d.review_reason -cne [string]$r.review_reason -or [string]$d.decision -cne 'PASS') { throw "$label does not match the checked-in PASS adjudication." }
        $key=([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc)
        if ($reviewSeen.ContainsKey($key)) { throw "Duplicate review response key: $key" }
        $reviewSeen[$key]=$true
        Assert-ResponseRow $r $label
    }

    $responsesPath = [string]$candidate.responses_csv
    $daySummaryPath = [string]$candidate.day_summary_csv
    if (-not (Test-Path -LiteralPath $responsesPath -PathType Leaf)) { throw "Full V3 responses CSV is missing at receipt path: $responsesPath" }
    if (-not (Test-Path -LiteralPath $daySummaryPath -PathType Leaf)) { throw "V3 day-summary CSV is missing at receipt path: $daySummaryPath" }
    if ((Get-Sha $responsesPath) -ne $ExpectedResponsesSha256) { throw 'Full V3 responses CSV SHA-256 mismatch.' }
    if ((Get-Sha $daySummaryPath) -ne $ExpectedDaySummarySha256) { throw 'V3 day-summary CSV SHA-256 mismatch.' }

    $responses=@(Import-Csv -LiteralPath $responsesPath)
    if ($responses.Count -ne $ExpectedResponseRows) { throw "Full response row count mismatch: $($responses.Count)." }
    $seen=@{}; $baseSeen=@{}
    for ($i=0; $i -lt $responses.Count; $i++) {
        $r=$responses[$i]; $key=([string]$r.base_asset_id)+'|'+([string]$r.response_day_utc)
        if ($seen.ContainsKey($key)) { throw "Duplicate full response key: $key" }
        $seen[$key]=$true; $baseSeen[[string]$r.base_asset_id]=$true
        Assert-ResponseRow $r "full response row $($i+1)"
    }
    if ($baseSeen.Count -ne $ExpectedDistinctBases) { throw "Distinct full response base count mismatch: $($baseSeen.Count)." }

    $daySummary=@(Import-Csv -LiteralPath $daySummaryPath)
    if ($daySummary.Count -ne 91) { throw "Day-summary row count mismatch: $($daySummary.Count), expected 91 Q2 UTC days." }
    $sum=0L; $daySeen=@{}
    foreach ($r in $daySummary) {
        if ($daySeen.ContainsKey([string]$r.response_day_utc)) { throw "Duplicate day-summary date: $($r.response_day_utc)" }
        $daySeen[[string]$r.response_day_utc]=$true
        $count=[long]$r.response_rows; $distinct=[long]$r.distinct_bases
        if ($count -le 0 -or $distinct -le 0 -or $distinct -gt $count) { throw "Invalid day-summary counts for $($r.response_day_utc)." }
        $sum += $count
    }
    if ($sum -ne $ExpectedResponseRows) { throw "Day-summary response total mismatch: $sum." }

    $freezeReceipt=[ordered]@{
        status='STAGE4_FROZEN';stage='CFA_STAGE_4';response_contract='FROZEN_UTC_DAY_OBSERVED_V3';response_id=$ExpectedResponseId;
        candidate_receipt_sha256=$ExpectedCandidateSha256;review_csv_sha256=$ExpectedReviewSha256;responses_sha256=$ExpectedResponsesSha256;day_summary_sha256=$ExpectedDaySummarySha256;
        adjudication_manifest_sha256=(Get-Sha $adjudicationPath);response_rows=$ExpectedResponseRows;distinct_response_bases=$ExpectedDistinctBases;review_rows=$ExpectedReviewRows;
        min_response_day='2025-04-01';max_response_day='2025-06-30';formula='ln(last_observed_close_within_d / first_observed_open_within_d)';
        response_semantics='observed within-UTC-day log return; not a fixed-duration 24-hour return';
        gates=[ordered]@{'CFA-S4-001'='PASS';'CFA-S4-002'='PASS';'CFA-S4-003'='PASS';'CFA-S4-004'='FAIL';'CFA-S4-005'='FAIL';'CFA-S4-006'='BLOCKED';'CFA-S4-007'='PASS';'CFA-S4-008'='FAIL';'CFA-S4-009'='FAIL';'CFA-S4-011'='FAIL';'CFA-S4-012'='PASS';'CFA-S4-013'='PASS';'CFA-S4-014'='PASS';'CFA-S4-015'='PASS'};
        next_stage='CFA Stage 5 candidate-factor definition may begin only from this exact frozen response artifact and the previously frozen upstream stages.'
    }
    $receiptPath=Join-Path $runDir 'stage4-v3-freeze-receipt.json'
    Write-Utf8NoBom $receiptPath (($freezeReceipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 4 V3 RESPONSE FREEZE: PASS'
    Write-Host "Response rows: $ExpectedResponseRows"
    Write-Host "Distinct response bases: $ExpectedDistinctBases"
    Write-Host "Review rows adjudicated PASS: $ExpectedReviewRows"
    Write-Host 'CFA-S4-014 direct V3 review: PASS'
    Write-Host 'CFA-S4-015 freeze responses: PASS'
    Write-Host "Freeze receipt: $receiptPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 4 V3 RESPONSE FREEZE: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
