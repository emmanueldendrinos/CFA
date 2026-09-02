#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage5ValidationReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Invariant=[Globalization.CultureInfo]::InvariantCulture

$ExpectedStage4Sha='8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedFactorSha='c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b'
$ExpectedRows=37058
$ExpectedBases=434
$ExpectedDays=91
$ExpectedMarketAvailable=36505
$ExpectedMarketMissing=553
$ExpectedNews24Available=27267
$ExpectedNews24Incomplete=9518
$ExpectedNews24Outside=273
$ExpectedNews6Available=28849
$ExpectedNews6Incomplete=7936
$ExpectedNews6Outside=273
$FactorIds=@(
    'MKT_RET_USD_UTC_DAY_OBS_L1',
    'MKT_RANGE_LOG_UTC_DAY_L1',
    'MKT_OBS_COUNT_UTC_DAY_L1',
    'MKT_OBS_SPAN_MIN_UTC_DAY_L1',
    'NEWS_V6_MATCH_COUNT_24H_LAG15',
    'NEWS_V6_MATCH_COUNT_6H_LAG15',
    'NEWS_V6_SOURCE_COUNT_24H_LAG15'
)

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Require-File {
    param([string]$Path,[string]$Label)
    $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"}
    return $resolved
}

function Require-Columns {
    param([object]$Row,[string[]]$Names,[string]$Label)
    $props=@($Row.PSObject.Properties.Name)
    foreach($name in $Names){if($props-notcontains$name){throw "$Label required column missing: $name"}}
}

function Is-Blank {
    param([object]$Value)
    return [string]::IsNullOrWhiteSpace([string]$Value)
}

function Has-ReplacementChar {
    param([object]$Value)
    return ([string]$Value).IndexOf([char]0xFFFD) -ge 0
}

function Parse-DoubleStrict {
    param([object]$Value,[string]$Label)
    $n=0.0
    if(-not[double]::TryParse(([string]$Value),[Globalization.NumberStyles]::Float,$Invariant,[ref]$n)){throw "Malformed numeric for ${Label}: '$Value'"}
    if([double]::IsNaN($n)-or[double]::IsInfinity($n)){throw "Non-finite numeric for ${Label}: '$Value'"}
    return $n
}

function Parse-LongStrict {
    param([object]$Value,[string]$Label)
    $n=[long]0
    if(-not[long]::TryParse(([string]$Value),[Globalization.NumberStyles]::Integer,$Invariant,[ref]$n)){throw "Malformed integer for ${Label}: '$Value'"}
    return $n
}

function Parse-BoolStrict {
    param([object]$Value,[string]$Label)
    $x=([string]$Value).Trim().ToLowerInvariant()
    if($x-in@('true','t')){return $true}
    if($x-in@('false','f')){return $false}
    throw "Malformed boolean for ${Label}: '$Value'"
}

function Parse-Day {
    param([object]$Value,[string]$Label)
    $text=([string]$Value).Trim()
    $dt=[datetime]::MinValue
    if(-not[datetime]::TryParseExact($text,'yyyy-MM-dd',$Invariant,[Globalization.DateTimeStyles]::None,[ref]$dt)){throw "Malformed day for ${Label}: '$Value'"}
    return [datetime]::SpecifyKind($dt,[DateTimeKind]::Utc)
}

function Parse-Utc {
    param([object]$Value,[string]$Label)
    $text=([string]$Value).Trim()
    $dto=[DateTimeOffset]::MinValue
    if(-not[DateTimeOffset]::TryParseExact($text,'yyyy-MM-ddTHH:mm:ssZ',$Invariant,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$dto)){throw "Malformed UTC timestamp for ${Label}: '$Value'"}
    return $dto.UtcDateTime
}

function Format-Utc {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'",$Invariant)
}

function Require-Hex64 {
    param([object]$Value,[string]$Label)
    $text=([string]$Value).Trim()
    if($text-notmatch'^[0-9a-fA-F]{64}$'){throw "Malformed SHA-256 for ${Label}: '$Value'"}
}

function New-Stat {
    return [ordered]@{non_null=[long]0;null=[long]0;min=$null;max=$null;unique=(New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))}
}

function Add-StatNull {
    param([hashtable]$Stat)
    $Stat.null=[long]$Stat.null+1
}

function Add-StatValue {
    param([hashtable]$Stat,[double]$Value,[string]$RawText)
    $Stat.non_null=[long]$Stat.non_null+1
    if($null-eq$Stat.min-or$Value-lt[double]$Stat.min){$Stat.min=$Value}
    if($null-eq$Stat.max-or$Value-gt[double]$Stat.max){$Stat.max=$Value}
    [void]$Stat.unique.Add($RawText)
}

function Invoke-SelfTest {
    if((Parse-LongStrict '12' 'long')-ne12){throw 'Integer self-test failed.'}
    if([math]::Abs((Parse-DoubleStrict '1.25' 'double')-1.25)-gt1e-12){throw 'Double self-test failed.'}
    if(-not(Parse-BoolStrict 'True' 'bool')){throw 'Boolean self-test failed.'}
    $d=Parse-Day '2025-04-02' 'day'
    if((Format-Utc $d)-ne'2025-04-02T00:00:00Z'){throw 'Day/UTC self-test failed.'}
    $u=Parse-Utc '2025-04-02T12:34:00Z' 'utc'
    if((Format-Utc $u)-ne'2025-04-02T12:34:00Z'){throw 'UTC parser self-test failed.'}
    Require-Hex64 ('a'*64) 'sha'
    if(-not(Has-ReplacementChar ([string][char]0xFFFD))){throw 'Replacement-character self-test failed.'}
    $failed=$false
    try{[void](Parse-LongStrict '1.5' 'bad integer')}catch{$failed=$true}
    if(-not$failed){throw 'Malformed-integer failure-path self-test failed.'}
    $failed=$false
    try{[void](Parse-DoubleStrict 'NaN' 'bad double')}catch{$failed=$true}
    if(-not$failed){throw 'Non-finite failure-path self-test failed.'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $contractPath=Require-File (Join-Path $RepoRoot 'docs\evidence\stage6-data-quality-leakage-contract.md') 'Stage 6 contract'
    $stage5ContractPath=Require-File (Join-Path $RepoRoot 'docs\evidence\stage5-factor-contract.md') 'Stage 5 contract'
    $stage6Contract=Get-Content -LiteralPath $contractPath -Raw
    $stage5Contract=Get-Content -LiteralPath $stage5ContractPath -Raw
    foreach($marker in @('CFA-S6-001','CFA-S6-008','CFA-S6-009','STAGE6_ACTIVE')){if($stage6Contract-notmatch[regex]::Escape($marker)){throw "Stage 6 contract marker missing: $marker"}}
    foreach($marker in @('STAGE5_FROZEN','CFA-S5-014','CFA-S5-009','PASS',$ExpectedFactorSha)){if($stage5Contract-notmatch[regex]::Escape($marker)){throw "Frozen Stage 5 contract marker missing: $marker"}}

    $Stage5ValidationReceiptPath=Require-File $Stage5ValidationReceiptPath 'Stage 5 validation receipt'
    $Stage4ResponsesPath=Require-File $Stage4ResponsesPath 'Stage 4 responses'
    if((Get-Sha $Stage4ResponsesPath)-ne$ExpectedStage4Sha){throw 'Frozen Stage 4 response SHA-256 mismatch.'}

    $v5=Get-Content -LiteralPath $Stage5ValidationReceiptPath -Raw|ConvertFrom-Json
    if([string]$v5.status-ne'PASS'-or[string]$v5.stage-ne'CFA_STAGE_5'-or[string]$v5.validation-ne'INDEPENDENT_FACTOR_ARTIFACT_V1'){throw 'Stage 5 validation receipt identity/status mismatch.'}
    if([string]$v5.gates.'CFA-S5-008'-ne'PASS'-or[string]$v5.gates.'CFA-S5-014'-ne'PASS'){throw 'Stage 5 validation prerequisite gates are not PASS.'}
    $factorPath=Require-File ([string]$v5.factor_csv) 'Frozen Stage 5 factor CSV'
    $factorSha=Get-Sha $factorPath
    if($factorSha-ne$ExpectedFactorSha-or$factorSha-ne([string]$v5.factor_csv_sha256).ToLowerInvariant()){throw 'Frozen Stage 5 factor SHA-256 mismatch.'}
    if([long]$v5.row_count-ne$ExpectedRows-or[int]$v5.distinct_bases-ne$ExpectedBases-or[int]$v5.days-ne$ExpectedDays){throw 'Stage 5 validation receipt cardinality mismatch.'}

    $responses=@(Import-Csv -LiteralPath $Stage4ResponsesPath)
    $factors=@(Import-Csv -LiteralPath $factorPath)
    if($responses.Count-ne$ExpectedRows-or$factors.Count-ne$ExpectedRows){throw "Frozen row count mismatch: responses=$($responses.Count) factors=$($factors.Count)."}

    Require-Columns $responses[0] @(
        'response_id','base_asset_id','pair_token_opaque','source_member_ordinal','response_day_utc','predictor_cutoff_utc',
        'response_window_start_utc','response_window_end_exclusive_utc','response_available_utc','first_candle_start_utc','last_candle_start_utc',
        'first_minutes_after_midnight','last_minutes_before_midnight','observed_span_minutes_between_starts','first_open_price_usd','last_close_price_usd',
        'response_value_log_return','first_physical_record_number','last_physical_record_number','first_raw_record_sha256','last_raw_record_sha256'
    ) 'Stage 4 responses'
    Require-Columns $factors[0] @(
        'base_asset_id','response_day_utc','predictor_cutoff_utc','pair_token_opaque','source_member_ordinal',
        'market_missing_reason','market_window_start_utc','market_window_end_exclusive_utc',
        'MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1',
        'market_first_candle_start_utc','market_last_candle_start_utc','market_high_witness_candle_start_utc','market_low_witness_candle_start_utc',
        'market_first_open_price_usd','market_last_close_price_usd','market_max_high_price_usd','market_min_low_price_usd',
        'market_first_physical_record_number','market_last_physical_record_number','market_high_witness_physical_record_number','market_low_witness_physical_record_number',
        'market_first_raw_record_sha256','market_last_raw_record_sha256','market_high_witness_raw_record_sha256','market_low_witness_raw_record_sha256',
        'news_population_status','news_availability_lag_minutes','news_24h_missing_reason','news_24h_availability_window_start_utc','news_24h_availability_window_end_exclusive_utc',
        'news_24h_batch_window_start_utc','news_24h_batch_window_end_exclusive_utc','news_24h_window_complete','NEWS_V6_MATCH_COUNT_24H_LAG15','NEWS_V6_SOURCE_COUNT_24H_LAG15',
        'news_6h_missing_reason','news_6h_availability_window_start_utc','news_6h_availability_window_end_exclusive_utc','news_6h_batch_window_start_utc','news_6h_batch_window_end_exclusive_utc','news_6h_window_complete','NEWS_V6_MATCH_COUNT_6H_LAG15'
    ) 'Stage 5 factors'

    $responseByKey=@{}
    $responseBases=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $responseDays=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $stats=@{response_value_log_return=(New-Stat)}
    foreach($name in $FactorIds){$stats[$name]=New-Stat}
    $violations=New-Object System.Collections.ArrayList

    foreach($r in $responses){
        $base=([string]$r.base_asset_id).Trim();$dayText=([string]$r.response_day_utc).Trim();$key=$base+'|'+$dayText
        if($responseByKey.ContainsKey($key)){[void]$violations.Add([pscustomobject]@{key=$key;gate='CFA-S6-002';reason='DUPLICATE_RESPONSE_KEY';detail=''})}else{$responseByKey[$key]=$r}
        [void]$responseBases.Add($base);[void]$responseDays.Add($dayText)
        try {
            if([string]$r.response_id-ne'RET_USD_UTC_DAY_OBS_LOG'){throw 'response_id mismatch'}
            $day=Parse-Day $dayText $key
            $cutoffText=Format-Utc $day;$availableText=Format-Utc $day.AddDays(1)
            if(([string]$r.predictor_cutoff_utc).Trim()-cne$cutoffText){throw 'predictor cutoff mismatch'}
            if(([string]$r.response_window_start_utc).Trim()-cne$cutoffText){throw 'response window start mismatch'}
            if(([string]$r.response_window_end_exclusive_utc).Trim()-cne$availableText){throw 'response window end mismatch'}
            if(([string]$r.response_available_utc).Trim()-cne$availableText){throw 'response availability mismatch'}
            $firstTs=Parse-Utc $r.first_candle_start_utc "$key first response candle";$lastTs=Parse-Utc $r.last_candle_start_utc "$key last response candle"
            if($firstTs-lt$day-or$firstTs-ge$day.AddDays(1)-or$lastTs-lt$day-or$lastTs-ge$day.AddDays(1)-or$firstTs-gt$lastTs){throw 'response candle boundary/order failure'}
            $firstMin=Parse-LongStrict $r.first_minutes_after_midnight "$key first minutes";$lastLag=Parse-LongStrict $r.last_minutes_before_midnight "$key last lag";$span=Parse-LongStrict $r.observed_span_minutes_between_starts "$key response span"
            if($firstMin-lt0-or$firstMin-gt1439-or$lastLag-lt0-or$lastLag-gt1439-or$span-lt0-or$span-gt1439){throw 'response timing-domain failure'}
            $spanExpected=[long][math]::Round(($lastTs-$firstTs).TotalMinutes);if($span-ne$spanExpected){throw 'response span mismatch'}
            $open=Parse-DoubleStrict $r.first_open_price_usd "$key first response open";$close=Parse-DoubleStrict $r.last_close_price_usd "$key last response close";$resp=Parse-DoubleStrict $r.response_value_log_return "$key response"
            if($open-le0-or$close-le0){throw 'nonpositive response price'}
            if([math]::Abs($resp-[math]::Log($close/$open))-gt1e-12){throw 'response formula mismatch'}
            if((Parse-LongStrict $r.first_physical_record_number "$key first response physical")-lt1-or(Parse-LongStrict $r.last_physical_record_number "$key last response physical")-lt1){throw 'invalid response physical record number'}
            Require-Hex64 $r.first_raw_record_sha256 "$key first response sha";Require-Hex64 $r.last_raw_record_sha256 "$key last response sha"
            foreach($p in $r.PSObject.Properties){if(Has-ReplacementChar $p.Value){throw "replacement character in response column $($p.Name)"}}
            Add-StatValue $stats.response_value_log_return $resp ([string]$r.response_value_log_return)
        } catch {
            [void]$violations.Add([pscustomobject]@{key=$key;gate='CFA-S6-004/CFA-S6-005';reason='RESPONSE_DQ_OR_TIMING';detail=$_.Exception.Message})
        }
    }

    if($responseBases.Count-ne$ExpectedBases-or$responseDays.Count-ne$ExpectedDays){[void]$violations.Add([pscustomobject]@{key='';gate='CFA-S6-002';reason='RESPONSE_CARDINALITY';detail="bases=$($responseBases.Count) days=$($responseDays.Count)"})}

    $factorByKey=@{};$factorBases=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);$factorDays=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $lastSortKey=''
    [long]$marketAvailable=0;[long]$marketMissing=0
    [long]$news24Available=0;[long]$news24Incomplete=0;[long]$news24Outside=0
    [long]$news6Available=0;[long]$news6Incomplete=0;[long]$news6Outside=0

    $marketValueFields=@('MKT_RET_USD_UTC_DAY_OBS_L1','MKT_RANGE_LOG_UTC_DAY_L1','MKT_OBS_COUNT_UTC_DAY_L1','MKT_OBS_SPAN_MIN_UTC_DAY_L1')
    $marketWitnessFields=@(
        'market_first_candle_start_utc','market_last_candle_start_utc','market_high_witness_candle_start_utc','market_low_witness_candle_start_utc',
        'market_first_open_price_usd','market_last_close_price_usd','market_max_high_price_usd','market_min_low_price_usd',
        'market_first_physical_record_number','market_last_physical_record_number','market_high_witness_physical_record_number','market_low_witness_physical_record_number',
        'market_first_raw_record_sha256','market_last_raw_record_sha256','market_high_witness_raw_record_sha256','market_low_witness_raw_record_sha256'
    )

    foreach($row in $factors){
        $base=([string]$row.base_asset_id).Trim();$dayText=([string]$row.response_day_utc).Trim();$key=$base+'|'+$dayText
        if($factorByKey.ContainsKey($key)){[void]$violations.Add([pscustomobject]@{key=$key;gate='CFA-S6-002';reason='DUPLICATE_FACTOR_KEY';detail=''})}else{$factorByKey[$key]=$row}
        [void]$factorBases.Add($base);[void]$factorDays.Add($dayText)
        $sortKey=$dayText+'|'+$base
        if($lastSortKey-ne''-and[string]::CompareOrdinal($lastSortKey,$sortKey)-gt0){[void]$violations.Add([pscustomobject]@{key=$key;gate='CFA-S6-002';reason='NONDETERMINISTIC_FACTOR_ORDER';detail="prior=$lastSortKey current=$sortKey"})}
        $lastSortKey=$sortKey
        if(-not$responseByKey.ContainsKey($key)){[void]$violations.Add([pscustomobject]@{key=$key;gate='CFA-S6-002';reason='FACTOR_KEY_NOT_IN_RESPONSE';detail=''}) ; continue}
        $r=$responseByKey[$key]

        try {
            foreach($p in $row.PSObject.Properties){if(Has-ReplacementChar $p.Value){throw "replacement character in factor column $($p.Name)"}}
            if(([string]$row.pair_token_opaque)-cne([string]$r.pair_token_opaque-or([string]$row.source_member_ordinal).Trim()-cne([string]$r.source_member_ordinal).Trim()){throw 'factor/response lineage mismatch'}
            $day=Parse-Day $dayText $key;$cutoffText=Format-Utc $day
            if(([string]$row.predictor_cutoff_utc).Trim()-cne$cutoffText){throw 'factor predictor cutoff mismatch'}
            $marketStart=Format-Utc $day.AddDays(-1)
            if(([string]$row.market_window_start_utc).Trim()-cne$marketStart-or([string]$row.market_window_end_exclusive_utc).Trim()-cne$cutoffText){throw 'market window mismatch'}

            $marketReason=[string]$row.market_missing_reason
            if($marketReason-eq'NONE'){
                $marketAvailable++
                foreach($name in $marketValueFields){if(Is-Blank $row.PSObject.Properties[$name].Value){throw "defined market row missing $name"}}
                foreach($name in $marketWitnessFields){if(Is-Blank $row.PSObject.Properties[$name].Value){throw "defined market row missing witness $name"}}
                $mRet=Parse-DoubleStrict $row.MKT_RET_USD_UTC_DAY_OBS_L1 "$key market return";$mRange=Parse-DoubleStrict $row.MKT_RANGE_LOG_UTC_DAY_L1 "$key market range";$mCount=Parse-LongStrict $row.MKT_OBS_COUNT_UTC_DAY_L1 "$key market count";$mSpan=Parse-LongStrict $row.MKT_OBS_SPAN_MIN_UTC_DAY_L1 "$key market span"
                if($mRange-lt0-or$mCount-lt1-or$mSpan-lt0-or$mSpan-gt1439){throw 'market factor domain failure'}
                $mOpen=Parse-DoubleStrict $row.market_first_open_price_usd "$key market open";$mClose=Parse-DoubleStrict $row.market_last_close_price_usd "$key market close";$mHigh=Parse-DoubleStrict $row.market_max_high_price_usd "$key market high";$mLow=Parse-DoubleStrict $row.market_min_low_price_usd "$key market low"
                if($mOpen-le0-or$mClose-le0-or$mHigh-le0-or$mLow-le0-or$mHigh-lt$mLow){throw 'market witness price domain failure'}
                if([math]::Abs($mRet-[math]::Log($mClose/$mOpen))-gt1e-12-or[math]::Abs($mRange-[math]::Log($mHigh/$mLow))-gt1e-12){throw 'market formula mismatch'}
                $first=Parse-Utc $row.market_first_candle_start_utc "$key market first";$last=Parse-Utc $row.market_last_candle_start_utc "$key market last";$hiTs=Parse-Utc $row.market_high_witness_candle_start_utc "$key market high witness";$loTs=Parse-Utc $row.market_low_witness_candle_start_utc "$key market low witness"
                foreach($t in @($first,$last,$hiTs,$loTs)){if($t-lt$day.AddDays(-1)-or$t-ge$day){throw 'market witness at/outside cutoff window'}}
                if($first-gt$last){throw 'market first/last order failure'}
                if([long][math]::Round(($last-$first).TotalMinutes)-ne$mSpan){throw 'market span mismatch'}
                foreach($name in @('market_first_physical_record_number','market_last_physical_record_number','market_high_witness_physical_record_number','market_low_witness_physical_record_number')){if((Parse-LongStrict $row.PSObject.Properties[$name].Value "$key $name")-lt1){throw "invalid $name"}}
                foreach($name in @('market_first_raw_record_sha256','market_last_raw_record_sha256','market_high_witness_raw_record_sha256','market_low_witness_raw_record_sha256')){Require-Hex64 $row.PSObject.Properties[$name].Value "$key $name"}
                Add-StatValue $stats.MKT_RET_USD_UTC_DAY_OBS_L1 $mRet ([string]$row.MKT_RET_USD_UTC_DAY_OBS_L1)
                Add-StatValue $stats.MKT_RANGE_LOG_UTC_DAY_L1 $mRange ([string]$row.MKT_RANGE_LOG_UTC_DAY_L1)
                Add-StatValue $stats.MKT_OBS_COUNT_UTC_DAY_L1 ([double]$mCount) ([string]$row.MKT_OBS_COUNT_UTC_DAY_L1)
                Add-StatValue $stats.MKT_OBS_SPAN_MIN_UTC_DAY_L1 ([double]$mSpan) ([string]$row.MKT_OBS_SPAN_MIN_UTC_DAY_L1)
            } elseif($marketReason-eq'NO_PRIOR_ACTIVE_MARKET_DAY') {
                $marketMissing++
                foreach($name in $marketValueFields){if(-not(Is-Blank $row.PSObject.Properties[$name].Value)){throw "market missing row contains $name"};Add-StatNull $stats[$name]}
                foreach($name in $marketWitnessFields){if(-not(Is-Blank $row.PSObject.Properties[$name].Value)){throw "market missing row contains witness $name"}}
            } else {throw "invalid market missingness reason '$marketReason'"}

            if(([string]$row.news_availability_lag_minutes).Trim()-cne'15'){throw 'news availability lag is not 15'}
            $expected24Start=Format-Utc $day.AddHours(-24);$expected6Start=Format-Utc $day.AddHours(-6);$expectedBatchEnd=Format-Utc $day.AddMinutes(-15);$expectedBatch24Start=Format-Utc $day.AddHours(-24).AddMinutes(-15);$expectedBatch6Start=Format-Utc $day.AddHours(-6).AddMinutes(-15)
            if(([string]$row.news_24h_availability_window_start_utc).Trim()-cne$expected24Start-or([string]$row.news_24h_availability_window_end_exclusive_utc).Trim()-cne$cutoffText-or([string]$row.news_24h_batch_window_start_utc).Trim()-cne$expectedBatch24Start-or([string]$row.news_24h_batch_window_end_exclusive_utc).Trim()-cne$expectedBatchEnd){throw '24h news timing window mismatch'}
            if(([string]$row.news_6h_availability_window_start_utc).Trim()-cne$expected6Start-or([string]$row.news_6h_availability_window_end_exclusive_utc).Trim()-cne$cutoffText-or([string]$row.news_6h_batch_window_start_utc).Trim()-cne$expectedBatch6Start-or([string]$row.news_6h_batch_window_end_exclusive_utc).Trim()-cne$expectedBatchEnd){throw '6h news timing window mismatch'}
            $complete24=Parse-BoolStrict $row.news_24h_window_complete "$key news24 complete";$complete6=Parse-BoolStrict $row.news_6h_window_complete "$key news6 complete"
            $reason24=[string]$row.news_24h_missing_reason;$reason6=[string]$row.news_6h_missing_reason;$pop=[string]$row.news_population_status
            $n24=$null;$s24=$null;$n6=$null
            if($reason24-eq'NONE'){
                $news24Available++;if(-not$complete24){throw '24h defined row marked incomplete'};if($pop-ne'IN_POPULATION'){throw '24h defined row outside population'}
                $n24=Parse-LongStrict $row.NEWS_V6_MATCH_COUNT_24H_LAG15 "$key news24";$s24=Parse-LongStrict $row.NEWS_V6_SOURCE_COUNT_24H_LAG15 "$key source24";if($n24-lt0-or$s24-lt0-or$s24-gt$n24){throw '24h news domain failure'}
                Add-StatValue $stats.NEWS_V6_MATCH_COUNT_24H_LAG15 ([double]$n24) ([string]$row.NEWS_V6_MATCH_COUNT_24H_LAG15);Add-StatValue $stats.NEWS_V6_SOURCE_COUNT_24H_LAG15 ([double]$s24) ([string]$row.NEWS_V6_SOURCE_COUNT_24H_LAG15)
            } elseif($reason24-eq'SOURCE_WINDOW_INCOMPLETE') {
                $news24Incomplete++;if($complete24){throw '24h incomplete row marked complete'};if($pop-ne'IN_POPULATION'){throw '24h source-incomplete row outside population'};if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)-and-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)){throw '24h incomplete row contains values'}
                if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)-or-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)){throw '24h incomplete row contains partial value'}
                Add-StatNull $stats.NEWS_V6_MATCH_COUNT_24H_LAG15;Add-StatNull $stats.NEWS_V6_SOURCE_COUNT_24H_LAG15
            } elseif($reason24-eq'OUTSIDE_NEWS_POPULATION') {
                $news24Outside++;if($pop-ne'OUTSIDE_NEWS_POPULATION'){throw '24h outside row population status mismatch'};if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_24H_LAG15)-or-not(Is-Blank $row.NEWS_V6_SOURCE_COUNT_24H_LAG15)){throw '24h outside row contains value'}
                Add-StatNull $stats.NEWS_V6_MATCH_COUNT_24H_LAG15;Add-StatNull $stats.NEWS_V6_SOURCE_COUNT_24H_LAG15
            } else {throw "invalid 24h news missingness reason '$reason24'"}

            if($reason6-eq'NONE'){
                $news6Available++;if(-not$complete6){throw '6h defined row marked incomplete'};if($pop-ne'IN_POPULATION'){throw '6h defined row outside population'}
                $n6=Parse-LongStrict $row.NEWS_V6_MATCH_COUNT_6H_LAG15 "$key news6";if($n6-lt0){throw '6h news domain failure'};Add-StatValue $stats.NEWS_V6_MATCH_COUNT_6H_LAG15 ([double]$n6) ([string]$row.NEWS_V6_MATCH_COUNT_6H_LAG15)
            } elseif($reason6-eq'SOURCE_WINDOW_INCOMPLETE') {
                $news6Incomplete++;if($complete6){throw '6h incomplete row marked complete'};if($pop-ne'IN_POPULATION'){throw '6h source-incomplete row outside population'};if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_6H_LAG15)){throw '6h incomplete row contains value'};Add-StatNull $stats.NEWS_V6_MATCH_COUNT_6H_LAG15
            } elseif($reason6-eq'OUTSIDE_NEWS_POPULATION') {
                $news6Outside++;if($pop-ne'OUTSIDE_NEWS_POPULATION'){throw '6h outside row population status mismatch'};if(-not(Is-Blank $row.NEWS_V6_MATCH_COUNT_6H_LAG15)){throw '6h outside row contains value'};Add-StatNull $stats.NEWS_V6_MATCH_COUNT_6H_LAG15
            } else {throw "invalid 6h news missingness reason '$reason6'"}
            if($null-ne$n24-and$null-ne$n6-and$n6-gt$n24){throw '6h news count exceeds 24h news count'}
        } catch {
            [void]$violations.Add([pscustomobject]@{key=$key;gate='CFA-S6-002/CFA-S6-003/CFA-S6-004/CFA-S6-006/CFA-S6-007/CFA-S6-008';reason='FACTOR_DQ_OR_LEAKAGE';detail=$_.Exception.Message})
        }
    }

    if($factorBases.Count-ne$ExpectedBases-or$factorDays.Count-ne$ExpectedDays){[void]$violations.Add([pscustomobject]@{key='';gate='CFA-S6-002';reason='FACTOR_CARDINALITY';detail="bases=$($factorBases.Count) days=$($factorDays.Count)"})}
    if($factorByKey.Count-ne$responseByKey.Count){[void]$violations.Add([pscustomobject]@{key='';gate='CFA-S6-002';reason='KEY_SET_CARDINALITY';detail="factors=$($factorByKey.Count) responses=$($responseByKey.Count)"})}
    foreach($key in $responseByKey.Keys){if(-not$factorByKey.ContainsKey($key)){[void]$violations.Add([pscustomobject]@{key=$key;gate='CFA-S6-002';reason='RESPONSE_KEY_NOT_IN_FACTORS';detail=''})}}

    if($marketAvailable-ne$ExpectedMarketAvailable-or$marketMissing-ne$ExpectedMarketMissing){[void]$violations.Add([pscustomobject]@{key='';gate='CFA-S6-003';reason='MARKET_PARTITION';detail="$marketAvailable/$marketMissing"})}
    if($news24Available-ne$ExpectedNews24Available-or$news24Incomplete-ne$ExpectedNews24Incomplete-or$news24Outside-ne$ExpectedNews24Outside){[void]$violations.Add([pscustomobject]@{key='';gate='CFA-S6-003';reason='NEWS24_PARTITION';detail="$news24Available/$news24Incomplete/$news24Outside"})}
    if($news6Available-ne$ExpectedNews6Available-or$news6Incomplete-ne$ExpectedNews6Incomplete-or$news6Outside-ne$ExpectedNews6Outside){[void]$violations.Add([pscustomobject]@{key='';gate='CFA-S6-003';reason='NEWS6_PARTITION';detail="$news6Available/$news6Incomplete/$news6Outside"})}

    $statRows=New-Object System.Collections.ArrayList
    foreach($name in @('response_value_log_return')+$FactorIds){
        $st=$stats[$name]
        [void]$statRows.Add([pscustomobject][ordered]@{
            variable=$name;non_null=[long]$st.non_null;null=[long]$st.null;
            min=if($null-eq$st.min){$null}else{([double]$st.min).ToString('R',$Invariant)};
            max=if($null-eq$st.max){$null}else{([double]$st.max).ToString('R',$Invariant)};
            unique_count=$st.unique.Count
        })
    }

    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage6-data-quality'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null
    $rejectPath=Join-Path $runDir 'stage6-dq-leakage-rejects.csv'
    if($violations.Count-eq0){[IO.File]::WriteAllText($rejectPath,"key,gate,reason,detail`r`n",(New-Object Text.UTF8Encoding($false)))}else{@($violations.ToArray())|Export-Csv -LiteralPath $rejectPath -NoTypeInformation -Encoding UTF8}
    $statsPath=Join-Path $runDir 'stage6-dq-descriptive-diagnostics.csv'
    @($statRows.ToArray())|Export-Csv -LiteralPath $statsPath -NoTypeInformation -Encoding UTF8

    $pass=($violations.Count-eq0)
    $gateStatus=if($pass){'PASS'}else{'FAIL'}
    $receipt=[ordered]@{
        status=$gateStatus;stage='CFA_STAGE_6';validation='DATA_QUALITY_LEAKAGE_V1';
        sources=[ordered]@{stage4_responses_path=$Stage4ResponsesPath;stage4_responses_sha256=(Get-Sha $Stage4ResponsesPath);stage5_validation_receipt_path=$Stage5ValidationReceiptPath;stage5_validation_receipt_sha256=(Get-Sha $Stage5ValidationReceiptPath);factor_csv=$factorPath;factor_csv_sha256=$factorSha};
        cardinality=[ordered]@{rows=$factors.Count;bases=$factorBases.Count;days=$factorDays.Count};
        missingness=[ordered]@{market=[ordered]@{available=$marketAvailable;missing=$marketMissing};news24=[ordered]@{available=$news24Available;source_incomplete=$news24Incomplete;outside_population=$news24Outside};news6=[ordered]@{available=$news6Available;source_incomplete=$news6Incomplete;outside_population=$news6Outside}};
        violations=[ordered]@{count=$violations.Count;reject_csv=$rejectPath;reject_csv_sha256=(Get-Sha $rejectPath)};
        diagnostics=[ordered]@{descriptive_csv=$statsPath;descriptive_csv_sha256=(Get-Sha $statsPath)};
        gates=[ordered]@{'CFA-S6-001'=$gateStatus;'CFA-S6-002'=$gateStatus;'CFA-S6-003'=$gateStatus;'CFA-S6-004'=$gateStatus;'CFA-S6-005'=$gateStatus;'CFA-S6-006'=$gateStatus;'CFA-S6-007'=$gateStatus;'CFA-S6-008'=$gateStatus;'CFA-S6-009'='BLOCKED'};
        next_action=if($pass){'Record exact Stage 6 receipt/reject/diagnostic hashes and freeze CFA-S6-009 only after repository evidence is updated.'}else{'Adjudicate every Stage 6 reject; do not advance to Stage 7 while any blocking violation remains.'}
    }
    $receiptPath=Join-Path $runDir 'stage6-dq-leakage-validation.json'
    [IO.File]::WriteAllText($receiptPath,(($receipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    if($pass){
        Write-Host 'CFA STAGE 6 DATA QUALITY AND LEAKAGE VALIDATION: PASS'
        Write-Host "Rows / bases / days: $($factors.Count) / $($factorBases.Count) / $($factorDays.Count)"
        Write-Host "Market available / missing: $marketAvailable / $marketMissing"
        Write-Host "News24 available / incomplete / outside: $news24Available / $news24Incomplete / $news24Outside"
        Write-Host "News6 available / incomplete / outside: $news6Available / $news6Incomplete / $news6Outside"
        Write-Host 'Blocking violations: 0'
        foreach($id in 1..8){Write-Host ("CFA-S6-{0:D3}: PASS" -f $id)}
        Write-Host 'CFA-S6-009 Stage 6 freeze: BLOCKED'
    } else {
        Write-Host 'CFA STAGE 6 DATA QUALITY AND LEAKAGE VALIDATION: FAIL'
        Write-Host "Blocking violations: $($violations.Count)"
        Write-Host 'CFA-S6-001 through CFA-S6-008: FAIL'
        Write-Host 'CFA-S6-009 Stage 6 freeze: BLOCKED'
    }
    Write-Host "Reject CSV: $rejectPath"
    Write-Host "Descriptive diagnostics CSV: $statsPath"
    Write-Host "Validation receipt: $receiptPath"
    if($pass){exit 0}else{exit 1}
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 6 DATA QUALITY AND LEAKAGE VALIDATION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
