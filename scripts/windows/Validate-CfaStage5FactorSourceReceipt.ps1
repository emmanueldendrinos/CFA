#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InspectionReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage3V6MatchesPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$ExpectedStage3Matches=22060
$ExpectedStage3MatchedAssets=282
$ExpectedStage3DistinctRecords=18503
$ExpectedStage4Rows=37058
$ExpectedStage4Bases=434
$ExpectedResponseId='RET_USD_UTC_DAY_OBS_LOG'
$ExpectedStage4ResponsesSha256='8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004'
$ExpectedResponseOnly=@('ZAUD','ZEUR','ZGBP')
$ExpectedNewsPopulation=431
$ExpectedIntersection=431
$ExpectedPriorAvailable=36505
$ExpectedPriorMissing=553

function Get-Sha { param([string]$Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-Utf8NoBom { param([string]$Path,[string]$Content); $p=Split-Path -Parent $Path; if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null}; [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false))) }
function Require-Columns { param([object]$Row,[string[]]$Names,[string]$Label); $props=@($Row.PSObject.Properties.Name); foreach($name in $Names){if($props -notcontains $name){throw "$Label required column missing: $name"}} }

function Invoke-SelfTest {
    $rows=@(
        [pscustomobject]@{base_asset_id='A';record_id='1'},
        [pscustomobject]@{base_asset_id='A';record_id='2'},
        [pscustomobject]@{base_asset_id='B';record_id='2'}
    )
    $keys=New-Object 'Collections.Generic.HashSet[string]'
    $records=New-Object 'Collections.Generic.HashSet[string]'
    $assets=New-Object 'Collections.Generic.HashSet[string]'
    foreach($r in $rows){if(-not $keys.Add(([string]$r.base_asset_id)+'|'+([string]$r.record_id))){throw 'duplicate self-test'};[void]$records.Add([string]$r.record_id);[void]$assets.Add([string]$r.base_asset_id)}
    if($keys.Count-ne3-or$records.Count-ne2-or$assets.Count-ne2){throw 'count self-test'}
    $responseOnly=@('ZGBP','ZAUD','ZEUR')|Sort-Object
    if(@(Compare-Object $responseOnly ($ExpectedResponseOnly|Sort-Object)).Count-ne0){throw 'population self-test'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $InspectionReceiptPath=(Resolve-Path -LiteralPath $InspectionReceiptPath).ProviderPath
    $Stage3V6MatchesPath=(Resolve-Path -LiteralPath $Stage3V6MatchesPath).ProviderPath
    $Stage4ResponsesPath=(Resolve-Path -LiteralPath $Stage4ResponsesPath).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\stage5-factor-source-correction'}
    $runDir=Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force|Out-Null

    $contract=Get-Content -LiteralPath (Join-Path $RepoRoot 'docs\evidence\stage5-factor-contract.md') -Raw
    if($contract -notmatch 'CFA-S5-001[^\r\n]*PASS'){throw 'Stage 5 entry gate is not PASS.'}

    $legacySha=Get-Sha $InspectionReceiptPath
    $legacy=Get-Content -LiteralPath $InspectionReceiptPath -Raw|ConvertFrom-Json
    if([string]$legacy.status-ne'VALIDATION_CANDIDATE'-or[string]$legacy.stage-ne'CFA_STAGE_5'-or[string]$legacy.stage4_entry-ne'PASS'){throw 'Input is not a Stage 5 validation-candidate receipt.'}
    if([int]$legacy.populations.response_direct_usd_bases-ne$ExpectedStage4Bases){throw 'Legacy receipt response population changed.'}
    if([int]$legacy.populations.stage3_news_population_assets-ne$ExpectedNewsPopulation-or[int]$legacy.populations.intersection_assets-ne$ExpectedIntersection){throw 'Legacy receipt news/intersection population changed.'}
    $responseOnly=@($legacy.populations.response_only_assets|ForEach-Object{[string]$_}|Sort-Object)
    if(@(Compare-Object $responseOnly ($ExpectedResponseOnly|Sort-Object)).Count-ne0){throw "Response-only population mismatch: $($responseOnly-join', ')."}
    if([int]$legacy.populations.news_only_no_direct_usd_response_assets-ne0){throw 'Unexpected news-only assets in legacy receipt.'}
    if([int]$legacy.news.matched_assets-ne$ExpectedStage3MatchedAssets-or[int]$legacy.news.distinct_record_ids-ne$ExpectedStage3DistinctRecords){throw 'Legacy receipt Stage 3 set counts changed.'}
    if([long]$legacy.availability.response_rows_with_prior_calendar_day_active_market-ne$ExpectedPriorAvailable-or[long]$legacy.availability.response_rows_without_prior_calendar_day_active_market-ne$ExpectedPriorMissing){throw 'Legacy receipt prior-day availability changed.'}
    if([string]$legacy.market.open_price_type-ne'numeric'-or[string]$legacy.market.high_price_type-ne'numeric'-or[string]$legacy.market.low_price_type-ne'numeric'-or[string]$legacy.market.close_price_type-ne'numeric'-or[string]$legacy.market.base_volume_type-ne'numeric'-or[string]$legacy.market.trade_count_type-ne'bigint'){throw 'Legacy receipt market factor-field types changed.'}

    $stage3SummaryPath=Join-Path (Split-Path -Parent $Stage3V6MatchesPath) 'stage3-match-summary.json'
    if(-not(Test-Path -LiteralPath $stage3SummaryPath -PathType Leaf)){throw 'Sibling Stage 3 V6 summary missing.'}
    $stage3Summary=Get-Content -LiteralPath $stage3SummaryPath -Raw|ConvertFrom-Json
    if([string]$stage3Summary.run_status-ne'PASS'-or[string]$stage3Summary.matching_contract-ne'CANDIDATE_V6'){throw 'Sibling Stage 3 summary is not PASS CANDIDATE_V6.'}
    $stage3Sha=Get-Sha $Stage3V6MatchesPath
    if($stage3Sha-ne([string]$stage3Summary.output.matches_sha256).ToLowerInvariant()){throw 'Stage 3 V6 match hash mismatch.'}
    $v6Matches=@(Import-Csv -LiteralPath $Stage3V6MatchesPath)
    if($v6Matches.Count-ne$ExpectedStage3Matches){throw "Stage 3 V6 match rows changed: $($v6Matches.Count)."}
    Require-Columns $v6Matches[0] @('base_asset_id','record_id','gdelt_date_utc') 'Stage 3 V6 matches'
    $keys=New-Object 'Collections.Generic.HashSet[string]'
    $records=New-Object 'Collections.Generic.HashSet[string]'
    $assets=New-Object 'Collections.Generic.HashSet[string]'
    foreach($row in $v6Matches){$key=([string]$row.base_asset_id)+'|'+([string]$row.record_id);if(-not$keys.Add($key)){throw "Duplicate Stage 3 asset/record key: $key"};[void]$records.Add([string]$row.record_id);[void]$assets.Add([string]$row.base_asset_id);if(([string]$row.gdelt_date_utc)-notmatch'^\d{14}$'){throw "Malformed GDELT date: $($row.gdelt_date_utc)"}}
    if($assets.Count-ne$ExpectedStage3MatchedAssets-or$records.Count-ne$ExpectedStage3DistinctRecords){throw 'Independent Stage 3 set counts do not reconcile.'}

    if((Get-Sha $Stage4ResponsesPath)-ne$ExpectedStage4ResponsesSha256){throw 'Stage 4 response CSV SHA-256 mismatch.'}
    $responses=@(Import-Csv -LiteralPath $Stage4ResponsesPath)
    if($responses.Count-ne$ExpectedStage4Rows){throw "Stage 4 response rows changed: $($responses.Count)."}
    Require-Columns $responses[0] @('response_id','base_asset_id') 'Stage 4 responses'
    $ids=@($responses|Select-Object -ExpandProperty response_id -Unique)
    if($ids.Count-ne1-or[string]$ids[0]-ne$ExpectedResponseId){throw 'Stage 4 response ID changed.'}
    $bases=@($responses|Select-Object -ExpandProperty base_asset_id -Unique)
    if($bases.Count-ne$ExpectedStage4Bases){throw 'Stage 4 response base count changed.'}

    $legacyMatchRows=[long]$legacy.news.match_rows
    $reportingDefect=($legacyMatchRows-ne$ExpectedStage3Matches)
    if(-not$reportingDefect){throw 'Expected legacy reporting defect is absent; do not use correction path on a clean receipt.'}

    $corrected=[ordered]@{
        status='PASS'
        stage='CFA_STAGE_5_SOURCE_ENTRY'
        correction='POWERSHELL_MATCHES_AUTOMATIC_VARIABLE_COLLISION'
        legacy_receipt_path=$InspectionReceiptPath
        legacy_receipt_sha256=$legacySha
        legacy_reported_match_rows=$legacyMatchRows
        corrected_match_rows=$v6Matches.Count
        stage3_v6_matches_path=$Stage3V6MatchesPath
        stage3_v6_matches_sha256=$stage3Sha
        stage4_responses_path=$Stage4ResponsesPath
        stage4_responses_sha256=(Get-Sha $Stage4ResponsesPath)
        populations=[ordered]@{
            response_direct_usd_bases=$ExpectedStage4Bases
            stage3_news_population_assets=$ExpectedNewsPopulation
            intersection_assets=$ExpectedIntersection
            response_only_outside_news_population_assets=$ExpectedResponseOnly.Count
            response_only_assets=$ExpectedResponseOnly
            news_only_no_direct_usd_response_assets=0
        }
        news=[ordered]@{
            match_rows=$v6Matches.Count
            matched_assets=$assets.Count
            distinct_record_ids=$records.Count
            min_match_timestamp_utc=[string]$legacy.news.min_match_timestamp_utc
            max_match_timestamp_utc=[string]$legacy.news.max_match_timestamp_utc
            min_archive_timestamp_utc=[string]$legacy.news.min_archive_timestamp_utc
            max_archive_timestamp_utc=[string]$legacy.news.max_archive_timestamp_utc
        }
        market=$legacy.market
        availability=$legacy.availability
        gates=[ordered]@{
            'CFA-S5-001'='PASS'
            'CFA-S5-002'='PASS'
            'CFA-S5-003'='PASS'
            'CFA-S5-004'='PASS'
            'CFA-S5-005'='PASS'
            'CFA-S5-006'='BLOCKED'
            'CFA-S5-007'='BLOCKED'
            'CFA-S5-008'='BLOCKED'
            'CFA-S5-009'='BLOCKED'
        }
    }
    $out=Join-Path $runDir 'stage5-factor-source-corrected-receipt.json'
    Write-Utf8NoBom $out (($corrected|ConvertTo-Json -Depth 10)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR SOURCE RECEIPT CORRECTION: PASS'
    Write-Host "Legacy reported V6 match rows: $legacyMatchRows"
    Write-Host "Corrected V6 match rows: $($v6Matches.Count)"
    Write-Host "V6 matched assets: $($assets.Count)"
    Write-Host "V6 distinct records: $($records.Count)"
    Write-Host "Response/news intersection: $ExpectedIntersection"
    Write-Host "Response-only outside news population: $($ExpectedResponseOnly.Count) [$($ExpectedResponseOnly-join', ')]"
    Write-Host "Prior active market available/missing: $ExpectedPriorAvailable / $ExpectedPriorMissing"
    Write-Host 'CFA-S5-002 population reconciliation: PASS'
    Write-Host 'CFA-S5-003 news source/schema/timestamp verification: PASS'
    Write-Host 'CFA-S5-004 market factor-source verification: PASS'
    Write-Host 'CFA-S5-005 prior-window availability measurement: PASS'
    Write-Host "Corrected receipt: $out"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 5 FACTOR SOURCE RECEIPT CORRECTION: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
