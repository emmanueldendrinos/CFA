#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V3RunRoot,
    [Parameter(Mandatory=$true)][string]$OutputRoot,
    [ValidateRange(1,10)][int]$PerStratum = 2,
    [ValidateRange(20,500)][int]$MaxReviewRows = 180,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Parse-Bool {
    param([object]$Value,[string]$Label)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return $true }
    if ($text -eq 'false') { return $false }
    throw "Malformed boolean in ${Label}: '$Value'"
}
function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-StableSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-V3Logic {
    param([object[]]$Rows)
    $errors = New-Object System.Collections.ArrayList
    $ordinal = 0
    foreach ($r in $Rows) {
        $ordinal++
        try {
            $v3 = ([string]$r.v3_match_status).Trim()
            $v2 = ([string]$r.v2_match_status).Trim()
            $reason = ([string]$r.v3_filter_reason).Trim()
            $requires = Parse-Bool $r.requires_crypto_context "row $ordinal requires_crypto_context"
            $econ = Parse-Bool $r.econ_bitcoin_theme "row $ordinal econ_bitcoin_theme"
            $title = Parse-Bool $r.title_crypto_anchor "row $ordinal title_crypto_anchor"
            $short = Parse-Bool $r.v3_short_default_symbol "row $ordinal short"
            $approved = Parse-Bool $r.v3_approved_nondefault_same_record "row $ordinal approved"

            if ($v3 -notin @('MATCH','REJECT_CONTEXT','REJECT_V3_SHORT_SYMBOL_TITLE_CONTEXT')) { throw "unexpected V3 status '$v3'" }
            if ($v2 -notin @('MATCH','REJECT_CONTEXT')) { throw "unexpected V2 status '$v2'" }

            if ($v3 -eq 'REJECT_V3_SHORT_SYMBOL_TITLE_CONTEXT') {
                if ($v2 -ne 'MATCH') { throw 'V3 short-symbol rejection must originate from V2 MATCH' }
                if (-not $short) { throw 'V3 short-symbol rejection is not a short default symbol' }
                if ($approved) { throw 'V3 short-symbol rejection has approved non-default same-record support' }
                if ($title) { throw 'V3 short-symbol rejection has TITLE_CRYPTO evidence' }
                if ($reason -ne 'SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO') { throw "V3 short-symbol rejection reason is '$reason'" }
            }
            elseif ($v3 -eq 'REJECT_CONTEXT') {
                if ($v2 -ne 'REJECT_CONTEXT') { throw 'V3 context rejection must preserve V2 context rejection' }
                if (-not $requires -or $econ -or $title) { throw 'V2/V3 context rejection has qualifying context or context-free alias' }
                if (([string]$r.context_reason).Trim() -ne 'NONE') { throw 'V2/V3 context rejection reason must be NONE' }
                if ($reason -ne 'V2_CONTEXT_REJECT') { throw 'V3 context rejection lineage reason mismatch' }
            }
            else {
                if ($v2 -ne 'MATCH') { throw 'V3 MATCH must originate from V2 MATCH' }
                if ($short -and -not $approved -and -not $title) { throw 'Short default V3 MATCH lacks TITLE_CRYPTO or approved non-default same-record evidence' }
                if ($short -and $approved -and $reason -ne 'APPROVED_NONDEFAULT_SAME_RECORD') { throw 'Approved non-default short-symbol retention reason mismatch' }
                if ($short -and -not $approved -and $title -and $reason -ne 'TITLE_CRYPTO') { throw 'TITLE_CRYPTO short-symbol retention reason mismatch' }
                if (-not $short -and $reason -ne 'NOT_SHORT_DEFAULT') { throw 'Non-short V3 MATCH reason mismatch' }
            }
        }
        catch { [void]$errors.Add("row ${ordinal}: $($_.Exception.Message)") }
    }
    return [pscustomobject]@{
        status = if ($errors.Count -eq 0) {'PASS'} else {'FAIL'}
        error_count = $errors.Count
        errors = @($errors.ToArray())
    }
}

function Select-ReviewRows {
    param([object[]]$Rows,[int]$Take,[int]$Maximum)
    $prepared = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        $surface = ([string]$r.matched_surfaces).Trim()
        if ([string]::IsNullOrWhiteSpace($surface)) { $surface = 'NONE' }
        $stratum = ([string]$r.v3_match_status) + '|' + ([string]$r.requires_crypto_context).ToLowerInvariant() + '|' + ([string]$r.v3_filter_reason) + '|' + $surface
        $key = ([string]$r.base_asset_id) + '|' + ([string]$r.alias_text).ToLowerInvariant() + '|' + ([string]$r.record_id) + '|' + ([string]$r.v3_match_status)
        [void]$prepared.Add([pscustomobject]@{row=$r;stratum=$stratum;stable_hash=(Get-StableSha256 $key)})
    }

    $selected = New-Object System.Collections.ArrayList
    foreach ($g in @($prepared | Group-Object stratum | Sort-Object Name)) {
        foreach ($item in @($g.Group | Sort-Object stable_hash | Select-Object -First $Take)) { [void]$selected.Add($item) }
    }

    foreach ($regression in @(
        @{base='IP';alias='IP';status='REJECT_V3_SHORT_SYMBOL_TITLE_CONTEXT'},
        @{base='OM';alias='OM';status='MATCH'}
    )) {
        $candidate = @($prepared | Where-Object {
            $_.row.base_asset_id -eq $regression.base -and
            $_.row.alias_text -ceq $regression.alias -and
            $_.row.v3_match_status -eq $regression.status
        } | Sort-Object stable_hash | Select-Object -First 1)
        if ($candidate.Count -eq 0) { throw "Required V3 regression review case missing: $($regression.base) / $($regression.status)" }
        $exists = @($selected | Where-Object { $_.stable_hash -eq $candidate[0].stable_hash }).Count -gt 0
        if (-not $exists) { [void]$selected.Add($candidate[0]) }
    }

    if ($selected.Count -gt $Maximum) {
        $mandatory = @($selected | Where-Object {
            ($_.row.base_asset_id -eq 'IP' -and $_.row.alias_text -ceq 'IP' -and $_.row.v3_match_status -eq 'REJECT_V3_SHORT_SYMBOL_TITLE_CONTEXT') -or
            ($_.row.base_asset_id -eq 'OM' -and $_.row.alias_text -ceq 'OM' -and $_.row.v3_match_status -eq 'MATCH')
        })
        $rest = @($selected | Where-Object {
            $candidateHash = $_.stable_hash
            @($mandatory | Where-Object { $_.stable_hash -eq $candidateHash }).Count -eq 0
        } | Sort-Object stable_hash | Select-Object -First ([Math]::Max(0,$Maximum-$mandatory.Count)))
        $selected = New-Object System.Collections.ArrayList
        foreach ($item in @($mandatory + $rest)) { [void]$selected.Add($item) }
    }
    return @($selected.ToArray())
}

function Invoke-Prepare {
    param([string]$RunRoot,[string]$OutRoot,[int]$Take,[int]$Maximum)
    $summaryPath = Join-Path $RunRoot 'stage3-match-summary.json'
    $samplePath = Join-Path $RunRoot 'stage3-match-samples.csv'
    foreach ($path in @($summaryPath,$samplePath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "V3 evidence artifact missing: $path" }
    }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ([string]$summary.run_status -ne 'PASS' -or [string]$summary.matching_contract -ne 'CANDIDATE_V3') { throw 'V3 run summary is not a PASS CANDIDATE_V3 artifact.' }
    if ((Get-Sha $samplePath) -ne ([string]$summary.output.samples_sha256).ToLowerInvariant()) { throw 'V3 sample hash differs from V3 summary.' }

    $rows = @(Import-Csv -LiteralPath $samplePath)
    if ($rows.Count -eq 0) { throw 'V3 sample file is empty.' }
    $required = @('v3_match_status','v3_filter_reason','v2_match_status','v3_short_default_symbol','v3_approved_nondefault_same_record','base_asset_id','alias_text','requires_crypto_context','record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','matched_surfaces','econ_bitcoin_theme','title_crypto_anchor','context_reason')
    $props = @($rows[0].PSObject.Properties.Name)
    foreach ($name in $required) { if ($props -notcontains $name) { throw "Required V3 sample column missing: $name" } }

    $logic = Assert-V3Logic $rows
    if ($logic.status -ne 'PASS') { throw "V3 sample logic validation failed: $(@($logic.errors | Select-Object -First 5) -join '; ')" }
    $selected = @(Select-ReviewRows $rows $Take $Maximum)
    if ($selected.Count -lt 20) { throw "V3 bounded review set unexpectedly small: $($selected.Count) rows." }

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $runDir = Join-Path $OutRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $reviewPath = Join-Path $runDir 'stage3-v3-bounded-sample-review.csv'
    $out = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($item in $selected) {
        $i++
        $r = $item.row
        [void]$out.Add([pscustomobject][ordered]@{
            review_row_id=('S3V3R-{0:000}' -f $i);stratum=$item.stratum;stable_hash=$item.stable_hash;v3_match_status=[string]$r.v3_match_status
            v3_filter_reason=[string]$r.v3_filter_reason;v2_match_status=[string]$r.v2_match_status;v3_short_default_symbol=[string]$r.v3_short_default_symbol
            v3_approved_nondefault_same_record=[string]$r.v3_approved_nondefault_same_record;base_asset_id=[string]$r.base_asset_id;alias_text=[string]$r.alias_text
            requires_crypto_context=[string]$r.requires_crypto_context;record_id=[string]$r.record_id;gdelt_date_utc=[string]$r.gdelt_date_utc;source_common_name=[string]$r.source_common_name
            document_identifier=[string]$r.document_identifier;page_title=[string]$r.page_title;matched_surfaces=[string]$r.matched_surfaces;econ_bitcoin_theme=[string]$r.econ_bitcoin_theme
            title_crypto_anchor=[string]$r.title_crypto_anchor;context_reason=[string]$r.context_reason;review_decision='';review_note=''
        })
    }
    @($out.ToArray()) | Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8

    $summaryOut = [ordered]@{
        status='PASS';source_v3_summary_sha256=(Get-Sha $summaryPath);source_v3_sample_sha256=(Get-Sha $samplePath);source_rows=$rows.Count
        automatic_logic_validation='PASS';review_rows=$out.Count;selection_rule='SHA-256 deterministic stratification plus mandatory IP reject and OM retained regression cases'
        direct_semantic_review='UNVERIFIED';output_review_csv=$reviewPath;output_review_sha256=(Get-Sha $reviewPath);gate_CFA_S3_005='UNVERIFIED';gate_CFA_S3_006='BLOCKED'
    }
    Write-Utf8NoBom (Join-Path $runDir 'stage3-v3-bounded-sample-review-summary.json') (($summaryOut | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Write-Host ''
    Write-Host 'CFA STAGE 3 V3 BOUNDED SAMPLE PREPARATION: PASS'
    Write-Host ("Source sample rows: {0}" -f $rows.Count)
    Write-Host ("Review rows: {0}" -f $out.Count)
    Write-Host 'Automatic V3 rule consistency: PASS'
    Write-Host 'Direct semantic review: UNVERIFIED'
    Write-Host ("Review CSV: {0}" -f $reviewPath)
    Write-Host ("Evidence directory: {0}" -f $runDir)
    return $runDir
}

function Invoke-SelfTest {
    $rows = New-Object System.Collections.ArrayList
    for ($i=1; $i -le 36; $i++) {
        if ($i -eq 1) {
            $base='IP';$alias='IP';$v3='REJECT_V3_SHORT_SYMBOL_TITLE_CONTEXT';$v2='MATCH';$short='True';$approved='False';$econ='True';$title='False';$reason='SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO';$ctx='ECON_BITCOIN'
        }
        elseif ($i -eq 2) {
            $base='OM';$alias='OM';$v3='MATCH';$v2='MATCH';$short='True';$approved='False';$econ='True';$title='True';$reason='TITLE_CRYPTO';$ctx='ECON_BITCOIN|TITLE_CRYPTO'
        }
        elseif (($i % 3) -eq 0) {
            $base='R'+$i;$alias='R'+$i;$v3='REJECT_CONTEXT';$v2='REJECT_CONTEXT';$short='False';$approved='False';$econ='False';$title='False';$reason='V2_CONTEXT_REJECT';$ctx='NONE'
        }
        else {
            $base='A'+$i;$alias='Alias '+$i;$v3='MATCH';$v2='MATCH';$short='False';$approved='False';$econ='False';$title='False';$reason='NOT_SHORT_DEFAULT';$ctx='NOT_REQUIRED'
        }
        [void]$rows.Add([pscustomobject]@{
            v3_match_status=$v3;v3_filter_reason=$reason;v2_match_status=$v2;v3_short_default_symbol=$short;v3_approved_nondefault_same_record=$approved
            base_asset_id=$base;alias_text=$alias;requires_crypto_context=if ($v3 -eq 'MATCH' -and -not [bool]::Parse($short)) {'False'} else {'True'}
            record_id='rec'+$i;gdelt_date_utc='20250401000000';source_common_name='x';document_identifier='https://example.test/'+$i;page_title='title '+$i
            matched_surfaces=if (($i % 2) -eq 0) {'PAGE_TITLE'} else {'ALLNAMES'};econ_bitcoin_theme=$econ;title_crypto_anchor=$title;context_reason=$ctx
        })
    }
    $logic = Assert-V3Logic @($rows.ToArray())
    if ($logic.status -ne 'PASS') { throw "Valid V3 self-test rows failed: $(@($logic.errors) -join '; ')" }
    $selected = @(Select-ReviewRows @($rows.ToArray()) 2 180)
    if (@($selected | Where-Object { $_.row.base_asset_id -eq 'IP' }).Count -ne 1) { throw 'IP mandatory review case' }
    if (@($selected | Where-Object { $_.row.base_asset_id -eq 'OM' }).Count -ne 1) { throw 'OM mandatory review case' }
    $rows[0].v3_approved_nondefault_same_record = 'True'
    $bad = Assert-V3Logic @($rows.ToArray())
    if ($bad.status -ne 'FAIL') { throw 'Invalid V3 rejection should fail' }
    Write-Host 'SELF-TEST: PASS'
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}
try {
    $Stage3V3RunRoot = (Resolve-Path -LiteralPath $Stage3V3RunRoot).ProviderPath
    [void](Invoke-Prepare $Stage3V3RunRoot $OutputRoot $PerStratum $MaxReviewRows)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V3 BOUNDED SAMPLE PREPARATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
