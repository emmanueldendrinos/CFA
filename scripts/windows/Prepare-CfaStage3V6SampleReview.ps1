#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Stage3V6RunRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [ValidateRange(1,10)][int]$PerStratum = 2,
    [ValidateRange(20,500)][int]$MaxReviewRows = 180,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
}

function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StableSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Parse-Bool {
    param([object]$Value, [string]$Label)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return $true }
    if ($text -eq 'false') { return $false }
    throw "Malformed boolean ${Label}: $Value"
}

function Assert-V6Logic {
    param([object[]]$Rows)
    $errors = New-Object System.Collections.ArrayList
    $ordinal = 0
    foreach ($row in $Rows) {
        $ordinal++
        try {
            $v6Status = ([string]$row.v6_match_status).Trim()
            $v5Status = ([string]$row.v5_match_status).Trim()
            $reason = ([string]$row.v6_filter_reason).Trim()
            $short = Parse-Bool $row.v5_short_default_symbol "row $ordinal short"
            $approved = Parse-Bool $row.v5_approved_nondefault_same_record "row $ordinal approved"
            $structured = Parse-Bool $row.v5_structured_symbol_exact "row $ordinal structured"
            $parenthetical = Parse-Bool $row.v5_parenthetical_market_ticker "row $ordinal parenthetical"
            $localMarket = Parse-Bool $row.v6_local_market_context "row $ordinal local"

            if ($v6Status -notin @('MATCH','REJECT_CONTEXT','REJECT_V5_SHORT_SYMBOL_CONTEXT','REJECT_V6_SHORT_SYMBOL_LOCAL_MARKET_CONTEXT')) {
                throw "unexpected V6 status '$v6Status'"
            }

            if ($v6Status -eq 'REJECT_V6_SHORT_SYMBOL_LOCAL_MARKET_CONTEXT') {
                if ($v5Status -ne 'MATCH' -or -not $short -or $approved -or $structured -or $parenthetical -or $localMarket -or $reason -ne 'SHORT_DEFAULT_REQUIRES_LOCAL_MARKET_OR_HIGH_SPECIFICITY') {
                    throw 'new V6 reject lineage inconsistent'
                }
            }
            elseif ($v6Status -eq 'REJECT_V5_SHORT_SYMBOL_CONTEXT') {
                if ($v5Status -ne 'REJECT_V5_SHORT_SYMBOL_CONTEXT' -or $reason -ne 'V5_SHORT_SYMBOL_REJECT_PRESERVED') {
                    throw 'V5 short reject not preserved'
                }
            }
            elseif ($v6Status -eq 'REJECT_CONTEXT') {
                if ($v5Status -ne 'REJECT_CONTEXT' -or $reason -ne 'V2_CONTEXT_REJECT') {
                    throw 'context reject not preserved'
                }
            }
            else {
                if ($v5Status -ne 'MATCH') { throw 'V6 match does not originate from V5 match' }
                if (-not $short -and $reason -ne 'NOT_SHORT_DEFAULT') { throw 'non-short reason mismatch' }
                if ($short -and -not ($approved -or $structured -or $parenthetical -or $localMarket)) {
                    throw 'short V6 match lacks high-specificity evidence'
                }
            }
        }
        catch { [void]$errors.Add("row ${ordinal}: $($_.Exception.Message)") }
    }
    return [pscustomobject]@{
        status = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
        error_count = $errors.Count
        errors = @($errors.ToArray())
    }
}

function Test-MandatoryCase {
    param([object]$Item, [string]$Label)
    $row = $Item.row
    switch ($Label) {
        'IP Exchange reject' { return ($row.base_asset_id -eq 'IP' -and $row.page_title -match 'IP Exchange' -and $row.v6_match_status -eq 'REJECT_V6_SHORT_SYMBOL_LOCAL_MARKET_CONTEXT') }
        'OM rally retain' { return ($row.base_asset_id -eq 'OM' -and $row.page_title -match 'OM rally' -and $row.v6_match_status -eq 'MATCH') }
        'OP_RETURN reject' { return ($row.base_asset_id -eq 'OP' -and $row.page_title -match 'OP_RETURN' -and $row.v6_match_status -eq 'REJECT_V5_SHORT_SYMBOL_CONTEXT') }
        'IP infrastructure reject' { return ($row.base_asset_id -eq 'IP' -and $row.page_title -match 'IP Infrastructure' -and $row.v6_match_status -eq 'REJECT_V5_SHORT_SYMBOL_CONTEXT') }
        'Arweave ticker retain' { return ($row.base_asset_id -eq 'AR' -and $row.page_title -match 'Arweave \(AR\)' -and $row.v6_match_status -eq 'MATCH') }
        'Story ticker retain' { return ($row.base_asset_id -eq 'IP' -and $row.page_title -match 'Story \(IP\)' -and $row.v6_match_status -eq 'MATCH') }
        default { throw "Unknown mandatory V6 review label: $Label" }
    }
}

function Select-ReviewRows {
    param([object[]]$Rows, [int]$Take, [int]$Maximum)
    $prepared = New-Object System.Collections.ArrayList
    foreach ($row in $Rows) {
        $surface = ([string]$row.matched_surfaces).Trim()
        if ([string]::IsNullOrWhiteSpace($surface)) { $surface = 'NONE' }
        $stratum = ([string]$row.v6_match_status) + '|' + ([string]$row.v6_filter_reason) + '|' + $surface
        $key = ([string]$row.base_asset_id) + '|' + ([string]$row.alias_text).ToLowerInvariant() + '|' + ([string]$row.record_id) + '|' + ([string]$row.v6_match_status)
        [void]$prepared.Add([pscustomobject]@{ row=$row; stratum=$stratum; stable_hash=(Get-StableSha256 $key) })
    }

    $selected = New-Object System.Collections.ArrayList
    foreach ($group in @($prepared | Group-Object stratum | Sort-Object Name)) {
        foreach ($item in @($group.Group | Sort-Object stable_hash | Select-Object -First $Take)) {
            [void]$selected.Add($item)
        }
    }

    $mandatoryLabels = @('IP Exchange reject','OM rally retain','OP_RETURN reject','IP infrastructure reject','Arweave ticker retain','Story ticker retain')
    $mandatory = New-Object System.Collections.ArrayList
    foreach ($label in $mandatoryLabels) {
        $candidate = @($prepared | Where-Object { Test-MandatoryCase $_ $label } | Sort-Object stable_hash | Select-Object -First 1)
        if ($candidate.Count -eq 0) { throw "Mandatory V6 review case missing: $label" }
        [void]$mandatory.Add($candidate[0])
        if (@($selected | Where-Object { $_.stable_hash -eq $candidate[0].stable_hash }).Count -eq 0) {
            [void]$selected.Add($candidate[0])
        }
    }

    if ($selected.Count -gt $Maximum) {
        $mandatoryHashes = @{}
        foreach ($item in $mandatory) { $mandatoryHashes[$item.stable_hash] = $true }
        $rest = @($selected | Where-Object { -not $mandatoryHashes.ContainsKey($_.stable_hash) } | Sort-Object stable_hash | Select-Object -First ([Math]::Max(0, $Maximum - $mandatory.Count)))
        $trimmed = New-Object System.Collections.ArrayList
        foreach ($item in @($mandatory.ToArray()) + $rest) { [void]$trimmed.Add($item) }
        $selected = $trimmed
    }
    return @($selected.ToArray())
}

function Invoke-SelfTest {
    $rows = @(
        [pscustomobject]@{v6_match_status='REJECT_V6_SHORT_SYMBOL_LOCAL_MARKET_CONTEXT';v6_filter_reason='SHORT_DEFAULT_REQUIRES_LOCAL_MARKET_OR_HIGH_SPECIFICITY';v6_local_market_context='False';v5_match_status='MATCH';v5_short_default_symbol='True';v5_approved_nondefault_same_record='False';v5_structured_symbol_exact='False';v5_parenthetical_market_ticker='False';base_asset_id='IP';alias_text='IP';record_id='1';page_title='IP Exchange';matched_surfaces='PAGE_TITLE'},
        [pscustomobject]@{v6_match_status='MATCH';v6_filter_reason='TITLE_LOCAL_MARKET_SHORT_SYMBOL';v6_local_market_context='True';v5_match_status='MATCH';v5_short_default_symbol='True';v5_approved_nondefault_same_record='False';v5_structured_symbol_exact='False';v5_parenthetical_market_ticker='False';base_asset_id='OM';alias_text='OM';record_id='2';page_title='OM rally';matched_surfaces='PAGE_TITLE'}
    )
    $logic = Assert-V6Logic $rows
    if ($logic.status -ne 'PASS') { throw "V6 logic self-test failed: $(@($logic.errors) -join '; ')" }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try {
    $Stage3V6RunRoot = (Resolve-Path -LiteralPath $Stage3V6RunRoot).ProviderPath
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath

    $summaryPath = Join-Path $Stage3V6RunRoot 'stage3-match-summary.json'
    $samplePath = Join-Path $Stage3V6RunRoot 'stage3-match-samples.csv'
    foreach ($path in @($summaryPath, $samplePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "V6 artifact missing: $path" }
    }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ([string]$summary.run_status -ne 'PASS' -or [string]$summary.matching_contract -ne 'CANDIDATE_V6') { throw 'Input is not PASS CANDIDATE_V6.' }
    if ((Get-Sha $samplePath) -ne ([string]$summary.output.samples_sha256).ToLowerInvariant()) { throw 'V6 sample hash mismatch.' }

    $rows = @(Import-Csv -LiteralPath $samplePath)
    $logic = Assert-V6Logic $rows
    if ($logic.status -ne 'PASS') { throw "V6 sample logic failed: $(@($logic.errors | Select-Object -First 5) -join '; ')" }
    $selected = @(Select-ReviewRows $rows $PerStratum $MaxReviewRows)
    if ($selected.Count -lt 20) { throw "V6 review unexpectedly small: $($selected.Count)" }

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $runDir = Join-Path $OutputRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $reviewPath = Join-Path $runDir 'stage3-v6-bounded-sample-review.csv'
    $out = New-Object System.Collections.ArrayList
    $ordinal = 0
    foreach ($item in $selected) {
        $ordinal++
        $source = $item.row
        $ordered = [ordered]@{ review_row_id=('S3V6R-{0:000}' -f $ordinal); stratum=$item.stratum; stable_hash=$item.stable_hash }
        foreach ($name in @($source.PSObject.Properties.Name)) { $ordered[$name] = [string]$source.$name }
        $ordered['review_decision'] = ''
        $ordered['review_note'] = ''
        [void]$out.Add([pscustomobject]$ordered)
    }
    @($out.ToArray()) | Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8

    $summaryOut = [ordered]@{
        status='PASS'
        source_v6_summary_sha256=(Get-Sha $summaryPath)
        source_v6_sample_sha256=(Get-Sha $samplePath)
        source_rows=$rows.Count
        automatic_logic_validation='PASS'
        review_rows=$out.Count
        selection_rule='SHA-256 deterministic stratification plus mandatory IP Exchange, OM rally, OP_RETURN, IP infrastructure, Arweave (AR), Story (IP) cases'
        direct_semantic_review='UNVERIFIED'
        output_review_csv=$reviewPath
        output_review_sha256=(Get-Sha $reviewPath)
        gate_CFA_S3F_023='UNVERIFIED'
        gate_CFA_S3F_024='BLOCKED'
        gate_CFA_S3_005='UNVERIFIED'
        gate_CFA_S3_006='BLOCKED'
    }
    Write-Utf8NoBom (Join-Path $runDir 'stage3-v6-bounded-sample-review-summary.json') (($summaryOut | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 3 V6 BOUNDED SAMPLE PREPARATION: PASS'
    Write-Host ("Source sample rows: {0}" -f $rows.Count)
    Write-Host ("Review rows: {0}" -f $out.Count)
    Write-Host 'Automatic V6 rule consistency: PASS'
    Write-Host 'Direct semantic review: UNVERIFIED'
    Write-Host ("Review CSV: {0}" -f $reviewPath)
    Write-Host ("Evidence directory: {0}" -f $runDir)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V6 BOUNDED SAMPLE PREPARATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
