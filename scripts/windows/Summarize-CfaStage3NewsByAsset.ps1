#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3RunRoot,
    [string]$OutputCsv = '',
    [string[]]$Symbols = @('SOL','BTC','ETH','XRP','DOGE','ADA','AVAX','DOT'),
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NewsSummary {
    param([object[]]$Rows)
    $counts = @{}
    $records = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in $Rows) {
        $asset = ([string]$r.base_asset_id).Trim()
        $record = ([string]$r.record_id).Trim()
        if ([string]::IsNullOrWhiteSpace($asset) -or [string]::IsNullOrWhiteSpace($record)) { throw 'Blank base_asset_id or record_id in match output.' }
        if (-not $counts.ContainsKey($asset)) { $counts[$asset] = 0L }
        $counts[$asset] = [long]$counts[$asset] + 1L
        [void]$records.Add($record)
    }
    $byAsset = @($counts.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ base_asset_id=[string]$_.Key; news_instances=[long]$_.Value }
    } | Sort-Object @{Expression='news_instances';Descending=$true}, @{Expression='base_asset_id';Descending=$false})

    $values = @($byAsset | ForEach-Object { [long]$_.news_instances } | Sort-Object)
    [double]$average = 0
    [double]$median = 0
    if ($values.Count -gt 0) {
        $average = ([double](($values | Measure-Object -Sum).Sum)) / [double]$values.Count
        if (($values.Count % 2) -eq 1) { $median = [double]$values[[int][Math]::Floor($values.Count/2)] }
        else { $median = ([double]$values[($values.Count/2)-1] + [double]$values[$values.Count/2]) / 2.0 }
    }
    return [pscustomobject]@{
        total_asset_record_pairs = [long]$Rows.Count
        distinct_news_records = [long]$records.Count
        matched_assets = [int]$byAsset.Count
        average_news_instances_per_matched_asset = $average
        median_news_instances_per_matched_asset = $median
        by_asset = $byAsset
    }
}

function Invoke-SelfTest {
    $rows = @(
        [pscustomobject]@{base_asset_id='SOL';record_id='r1'},
        [pscustomobject]@{base_asset_id='SOL';record_id='r2'},
        [pscustomobject]@{base_asset_id='ETH';record_id='r2'},
        [pscustomobject]@{base_asset_id='ETH';record_id='r3'},
        [pscustomobject]@{base_asset_id='BTC';record_id='r4'},
        [pscustomobject]@{base_asset_id='BTC';record_id='r5'}
    )
    $s = Get-NewsSummary -Rows $rows
    if ($s.total_asset_record_pairs -ne 6) { throw 'pair count' }
    if ($s.distinct_news_records -ne 5) { throw 'distinct record count' }
    if ($s.matched_assets -ne 3) { throw 'asset count' }
    $sol = @($s.by_asset | Where-Object base_asset_id -eq 'SOL')[0]
    if ($sol.news_instances -ne 2) { throw 'SOL count' }
    if ([Math]::Abs($s.average_news_instances_per_matched_asset - 2.0) -gt 0.000001) { throw 'average' }
    if ([Math]::Abs($s.median_news_instances_per_matched_asset - 2.0) -gt 0.000001) { throw 'median' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    $matchPath = Join-Path $Stage3RunRoot 'stage3-news-matches.csv'
    if (-not (Test-Path -LiteralPath $matchPath -PathType Leaf)) { throw "Stage 3 match file missing: $matchPath" }
    $rows = @(Import-Csv -LiteralPath $matchPath)
    if ($rows.Count -eq 0) { throw 'Stage 3 match file is empty.' }
    $required = @('base_asset_id','record_id')
    $props = @($rows[0].PSObject.Properties.Name)
    foreach ($name in $required) { if ($props -notcontains $name) { throw "Required column missing: $name" } }

    $summary = Get-NewsSummary -Rows $rows
    if ([string]::IsNullOrWhiteSpace($OutputCsv)) { $OutputCsv = Join-Path $Stage3RunRoot 'stage3-news-counts-by-asset.csv' }
    @($summary.by_asset) | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host 'CFA STAGE 3 NEWS COUNTS BY ASSET: PASS'
    Write-Host ("Asset/news pairs: {0}" -f $summary.total_asset_record_pairs)
    Write-Host ("Distinct GDELT news records across all matched assets: {0}" -f $summary.distinct_news_records)
    Write-Host ("Matched assets: {0}" -f $summary.matched_assets)
    Write-Host ("Average news instances per matched asset: {0:N2}" -f $summary.average_news_instances_per_matched_asset)
    Write-Host ("Median news instances per matched asset: {0:N2}" -f $summary.median_news_instances_per_matched_asset)
    Write-Host ''
    Write-Host 'Requested symbols:'
    foreach ($symbol in $Symbols) {
        $row = @($summary.by_asset | Where-Object base_asset_id -eq $symbol | Select-Object -First 1)
        $count = if ($row.Count -eq 0) { 0 } else { [long]$row[0].news_instances }
        Write-Host ("{0}: {1}" -f $symbol,$count)
    }
    Write-Host ''
    Write-Host 'Top 25 assets by news instances:'
    @($summary.by_asset | Select-Object -First 25) | Format-Table base_asset_id,news_instances -AutoSize | Out-String | Write-Host
    Write-Host ("CSV: {0}" -f $OutputCsv)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 NEWS COUNTS BY ASSET: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
