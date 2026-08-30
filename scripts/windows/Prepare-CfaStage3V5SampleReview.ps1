#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage3V5RunRoot,
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
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path,$Content,(New-Object Text.UTF8Encoding($false)))
}
function Get-Sha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-StableSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Parse-Bool {
    param([object]$Value,[string]$Label)
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq 'true') { return $true }
    if ($text -eq 'false') { return $false }
    throw "Malformed boolean in ${Label}: '$Value'"
}

function Assert-V5Logic {
    param([object[]]$Rows)
    $errors = New-Object System.Collections.ArrayList
    $ordinal = 0
    foreach ($r in $Rows) {
        $ordinal++
        try {
            $v5 = ([string]$r.v5_match_status).Trim()
            $v2 = ([string]$r.v2_match_status).Trim()
            $reason = ([string]$r.v5_filter_reason).Trim()
            $short = Parse-Bool $r.v5_short_default_symbol "row $ordinal short"
            $approved = Parse-Bool $r.v5_approved_nondefault_same_record "row $ordinal approved"
            $titleValid = Parse-Bool $r.v5_title_symbol_valid "row $ordinal title-valid"
            $structured = Parse-Bool $r.v5_structured_symbol_exact "row $ordinal structured"
            $parenthetical = Parse-Bool $r.v5_parenthetical_market_ticker "row $ordinal parenthetical"
            $titleCrypto = Parse-Bool $r.title_crypto_anchor "row $ordinal title-crypto"
            $requires = Parse-Bool $r.requires_crypto_context "row $ordinal requires-context"
            $econ = Parse-Bool $r.econ_bitcoin_theme "row $ordinal econ"

            if ($v5 -notin @('MATCH','REJECT_CONTEXT','REJECT_V5_SHORT_SYMBOL_CONTEXT')) { throw "unexpected V5 status '$v5'" }
            if ($v2 -notin @('MATCH','REJECT_CONTEXT')) { throw "unexpected V2 status '$v2'" }

            if ($v5 -eq 'MATCH') {
                if ($v2 -ne 'MATCH') { throw 'V5 MATCH must originate from V2 MATCH.' }
                if (-not $short) {
                    if ($reason -ne 'NOT_SHORT_DEFAULT') { throw 'Non-short V5 MATCH reason mismatch.' }
                }
                elseif ($approved) {
                    if ($reason -ne 'APPROVED_NONDEFAULT_SAME_RECORD') { throw 'Approved non-default V5 reason mismatch.' }
                }
                elseif ($parenthetical) {
                    if ($reason -ne 'PAREN_TICKER_MARKET') { throw 'Parenthetical ticker V5 reason mismatch.' }
                }
                elseif ($titleCrypto -and ($titleValid -or $structured)) {
                    if ($reason -ne 'TITLE_CRYPTO_TOKEN_OR_STRUCTURED') { throw 'Title-crypto V5 reason mismatch.' }
                }
                else { throw 'Short-symbol V5 MATCH lacks an allowed retention condition.' }
            }
            elseif ($v5 -eq 'REJECT_CONTEXT') {
                if ($v2 -ne 'REJECT_CONTEXT') { throw 'V5 context reject must originate from V2 context reject.' }
                if (-not $requires -or $econ -or $titleCrypto) { throw 'Context reject has qualifying context or context-free alias.' }
                if (([string]$r.context_reason).Trim() -ne 'NONE') { throw 'Context reject reason must be NONE.' }
                if ($reason -ne 'V2_CONTEXT_REJECT') { throw 'V5 context-reject lineage reason mismatch.' }
            }
            else {
                if ($v2 -ne 'MATCH') { throw 'V5 short-symbol rejection must originate from V2 MATCH.' }
                if (-not $short) { throw 'V5 short-symbol rejection is not a short default symbol.' }
                if ($approved -or $parenthetical -or ($titleCrypto -and ($titleValid -or $structured))) { throw 'V5 short-symbol rejection satisfies a retention condition.' }
                if ($reason -ne 'SHORT_DEFAULT_REQUIRES_VALID_CONTEXT') { throw 'V5 short-symbol rejection reason mismatch.' }
            }
        }
        catch { [void]$errors.Add("row ${ordinal}: $($_.Exception.Message)") }
    }
    return [pscustomobject]@{status=if($errors.Count -eq 0){'PASS'}else{'FAIL'};error_count=$errors.Count;errors=@($errors.ToArray())}
}

function Select-ReviewRows {
    param([object[]]$Rows,[int]$Take,[int]$Maximum)
    $prepared = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        $surface = ([string]$r.matched_surfaces).Trim()
        if ([string]::IsNullOrWhiteSpace($surface)) { $surface = 'NONE' }
        $stratum = ([string]$r.v5_match_status) + '|' + ([string]$r.requires_crypto_context).ToLowerInvariant() + '|' + ([string]$r.v5_filter_reason) + '|' + $surface
        $key = ([string]$r.base_asset_id) + '|' + ([string]$r.alias_text).ToLowerInvariant() + '|' + ([string]$r.record_id) + '|' + ([string]$r.v5_match_status)
        [void]$prepared.Add([pscustomobject]@{row=$r;stratum=$stratum;stable_hash=(Get-StableSha256 $key)})
    }

    $selected = New-Object System.Collections.ArrayList
    foreach ($group in @($prepared | Group-Object stratum | Sort-Object Name)) {
        foreach ($item in @($group.Group | Sort-Object stable_hash | Select-Object -First $Take)) { [void]$selected.Add($item) }
    }

    $mandatoryPredicates = @(
        { param($x) $x.row.base_asset_id -eq 'OP' -and $x.row.alias_text -ceq 'OP' -and $x.row.page_title -match 'OP_RETURN' -and $x.row.v5_match_status -eq 'REJECT_V5_SHORT_SYMBOL_CONTEXT' },
        { param($x) $x.row.base_asset_id -eq 'AR' -and $x.row.alias_text -ceq 'AR' -and $x.row.page_title -match 'Arweave \(AR\)' -and $x.row.v5_match_status -eq 'MATCH' },
        { param($x) $x.row.base_asset_id -eq 'IP' -and $x.row.alias_text -ceq 'IP' -and $x.row.page_title -match 'Story \(IP\)' -and $x.row.v5_match_status -eq 'MATCH' },
        { param($x) $x.row.base_asset_id -eq 'IP' -and $x.row.alias_text -ceq 'IP' -and $x.row.page_title -match 'IP Infrastructure' -and $x.row.v5_match_status -eq 'REJECT_V5_SHORT_SYMBOL_CONTEXT' }
    )
    foreach ($predicate in $mandatoryPredicates) {
        $candidate = @($prepared | Where-Object { & $predicate $_ } | Sort-Object stable_hash | Select-Object -First 1)
        if ($candidate.Count -eq 0) { throw 'Required V5 semantic regression review case missing.' }
        if (@($selected | Where-Object { $_.stable_hash -eq $candidate[0].stable_hash }).Count -eq 0) { [void]$selected.Add($candidate[0]) }
    }

    if ($selected.Count -gt $Maximum) {
        $mandatoryHashes = @{}
        foreach ($item in $selected) {
            $isMandatory = $false
            foreach ($predicate in $mandatoryPredicates) { if (& $predicate $item) { $isMandatory = $true; break } }
            if ($isMandatory) { $mandatoryHashes[$item.stable_hash] = $true }
        }
        $mandatory = @($selected | Where-Object { $mandatoryHashes.ContainsKey($_.stable_hash) })
        $rest = @($selected | Where-Object { -not $mandatoryHashes.ContainsKey($_.stable_hash) } | Sort-Object stable_hash | Select-Object -First ([Math]::Max(0,$Maximum-$mandatory.Count)))
        $selected = New-Object System.Collections.ArrayList
        foreach ($item in @($mandatory + $rest)) { [void]$selected.Add($item) }
    }
    return @($selected.ToArray())
}

function Invoke-SelfTest {
    $rows = New-Object System.Collections.ArrayList
    $cases = @(
        [pscustomobject]@{base='OP';alias='OP';title='Bitcoin debate over OP_RETURN';v5='REJECT_V5_SHORT_SYMBOL_CONTEXT';v2='MATCH';short='True';approved='False';titleValid='False';structured='False';parenthetical='False';titleCrypto='True';requires='True';econ='True';reason='SHORT_DEFAULT_REQUIRES_VALID_CONTEXT';ctx='ECON_BITCOIN|TITLE_CRYPTO';surface='PAGE_TITLE'},
        [pscustomobject]@{base='AR';alias='AR';title='Arweave (AR) Reaches Market Capitalization Milestone';v5='MATCH';v2='MATCH';short='True';approved='False';titleValid='True';structured='False';parenthetical='True';titleCrypto='False';requires='True';econ='True';reason='PAREN_TICKER_MARKET';ctx='ECON_BITCOIN';surface='PAGE_TITLE'},
        [pscustomobject]@{base='IP';alias='IP';title='Story (IP) Price Down 9.6%';v5='MATCH';v2='MATCH';short='True';approved='False';titleValid='True';structured='False';parenthetical='True';titleCrypto='False';requires='True';econ='True';reason='PAREN_TICKER_MARKET';ctx='ECON_BITCOIN';surface='PAGE_TITLE'},
        [pscustomobject]@{base='IP';alias='IP';title='North Korean Hackers Use Russian IP Infrastructure';v5='REJECT_V5_SHORT_SYMBOL_CONTEXT';v2='MATCH';short='True';approved='False';titleValid='True';structured='False';parenthetical='False';titleCrypto='False';requires='True';econ='True';reason='SHORT_DEFAULT_REQUIRES_VALID_CONTEXT';ctx='ECON_BITCOIN';surface='PAGE_TITLE'},
        [pscustomobject]@{base='OM';alias='OM';title='Why could OM rally despite weakness in the crypto market?';v5='MATCH';v2='MATCH';short='True';approved='False';titleValid='True';structured='False';parenthetical='False';titleCrypto='True';requires='True';econ='False';reason='TITLE_CRYPTO_TOKEN_OR_STRUCTURED';ctx='TITLE_CRYPTO';surface='PAGE_TITLE'},
        [pscustomobject]@{base='RLC';alias='RLC';title='Tech companies debut new products at RLC';v5='REJECT_CONTEXT';v2='REJECT_CONTEXT';short='False';approved='False';titleValid='False';structured='False';parenthetical='False';titleCrypto='False';requires='True';econ='False';reason='V2_CONTEXT_REJECT';ctx='NONE';surface='PAGE_TITLE'},
        [pscustomobject]@{base='APT';alias='Aptos';title='Aptos market update';v5='MATCH';v2='MATCH';short='False';approved='False';titleValid='False';structured='False';parenthetical='False';titleCrypto='False';requires='False';econ='False';reason='NOT_SHORT_DEFAULT';ctx='NOT_REQUIRED';surface='PAGE_TITLE'}
    )
    $i = 0
    foreach ($case in $cases) {
        $i++
        [void]$rows.Add([pscustomobject]@{
            v5_match_status=$case.v5;v5_filter_reason=$case.reason;v2_match_status=$case.v2;v5_short_default_symbol=$case.short;v5_approved_nondefault_same_record=$case.approved;v5_title_symbol_valid=$case.titleValid;v5_structured_symbol_exact=$case.structured;v5_parenthetical_market_ticker=$case.parenthetical
            base_asset_id=$case.base;alias_text=$case.alias;requires_crypto_context=$case.requires;record_id='rec'+$i;gdelt_date_utc='20250401000000';source_common_name='x';document_identifier='https://example.test/'+$i;page_title=$case.title;matched_surfaces=$case.surface;econ_bitcoin_theme=$case.econ;title_crypto_anchor=$case.titleCrypto;context_reason=$case.ctx
        })
    }
    for ($j=8; $j -le 40; $j++) {
        [void]$rows.Add([pscustomobject]@{
            v5_match_status='MATCH';v5_filter_reason='NOT_SHORT_DEFAULT';v2_match_status='MATCH';v5_short_default_symbol='False';v5_approved_nondefault_same_record='False';v5_title_symbol_valid='False';v5_structured_symbol_exact='False';v5_parenthetical_market_ticker='False'
            base_asset_id='A'+$j;alias_text='Alias '+$j;requires_crypto_context='False';record_id='rec'+$j;gdelt_date_utc='20250401000000';source_common_name='x';document_identifier='https://example.test/'+$j;page_title='title '+$j;matched_surfaces=if(($j%2)-eq0){'PAGE_TITLE'}else{'ALLNAMES'};econ_bitcoin_theme='False';title_crypto_anchor='False';context_reason='NOT_REQUIRED'
        })
    }
    $logic = Assert-V5Logic @($rows.ToArray())
    if ($logic.status -ne 'PASS') { throw "V5 self-test logic failed: $(@($logic.errors) -join '; ')" }
    $selected = @(Select-ReviewRows @($rows.ToArray()) 2 180)
    foreach ($base in @('OP','AR','IP')) { if (@($selected | Where-Object { $_.row.base_asset_id -eq $base }).Count -eq 0) { throw "Mandatory V5 review case missing: $base" } }
    Write-Host 'SELF-TEST: PASS'
}
if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }; exit 1 }
}

try {
    $Stage3V5RunRoot = (Resolve-Path -LiteralPath $Stage3V5RunRoot).ProviderPath
    if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
    $OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    $summaryPath = Join-Path $Stage3V5RunRoot 'stage3-match-summary.json'
    $samplePath = Join-Path $Stage3V5RunRoot 'stage3-match-samples.csv'
    foreach ($path in @($summaryPath,$samplePath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "V5 artifact missing: $path" } }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if ([string]$summary.run_status -ne 'PASS' -or [string]$summary.matching_contract -ne 'CANDIDATE_V5') { throw 'V5 summary is not PASS CANDIDATE_V5.' }
    if ((Get-Sha $samplePath) -ne ([string]$summary.output.samples_sha256).ToLowerInvariant()) { throw 'V5 sample hash differs from summary.' }
    $rows = @(Import-Csv -LiteralPath $samplePath)
    if ($rows.Count -eq 0) { throw 'V5 sample file is empty.' }
    $required = @('v5_match_status','v5_filter_reason','v2_match_status','v5_short_default_symbol','v5_approved_nondefault_same_record','v5_title_symbol_valid','v5_structured_symbol_exact','v5_parenthetical_market_ticker','base_asset_id','alias_text','requires_crypto_context','record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','matched_surfaces','econ_bitcoin_theme','title_crypto_anchor','context_reason')
    $props = @($rows[0].PSObject.Properties.Name)
    foreach ($name in $required) { if ($props -notcontains $name) { throw "Required V5 sample column missing: $name" } }
    $logic = Assert-V5Logic $rows
    if ($logic.status -ne 'PASS') { throw "V5 sample logic validation failed: $(@($logic.errors | Select-Object -First 5) -join '; ')" }
    $selected = @(Select-ReviewRows $rows $PerStratum $MaxReviewRows)
    if ($selected.Count -lt 20) { throw "V5 bounded review unexpectedly small: $($selected.Count) rows." }

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $runDir = Join-Path $OutputRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $reviewPath = Join-Path $runDir 'stage3-v5-bounded-sample-review.csv'
    $out = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($item in $selected) {
        $i++
        $r = $item.row
        [void]$out.Add([pscustomobject][ordered]@{
            review_row_id=('S3V5R-{0:000}' -f $i);stratum=$item.stratum;stable_hash=$item.stable_hash;v5_match_status=[string]$r.v5_match_status;v5_filter_reason=[string]$r.v5_filter_reason;v2_match_status=[string]$r.v2_match_status
            v5_short_default_symbol=[string]$r.v5_short_default_symbol;v5_approved_nondefault_same_record=[string]$r.v5_approved_nondefault_same_record;v5_title_symbol_valid=[string]$r.v5_title_symbol_valid;v5_structured_symbol_exact=[string]$r.v5_structured_symbol_exact;v5_parenthetical_market_ticker=[string]$r.v5_parenthetical_market_ticker
            base_asset_id=[string]$r.base_asset_id;alias_text=[string]$r.alias_text;requires_crypto_context=[string]$r.requires_crypto_context;record_id=[string]$r.record_id;gdelt_date_utc=[string]$r.gdelt_date_utc;source_common_name=[string]$r.source_common_name;document_identifier=[string]$r.document_identifier;page_title=[string]$r.page_title;matched_surfaces=[string]$r.matched_surfaces;econ_bitcoin_theme=[string]$r.econ_bitcoin_theme;title_crypto_anchor=[string]$r.title_crypto_anchor;context_reason=[string]$r.context_reason;review_decision='';review_note=''
        })
    }
    @($out.ToArray()) | Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8
    $summaryOut = [ordered]@{
        status='PASS';source_v5_summary_sha256=(Get-Sha $summaryPath);source_v5_sample_sha256=(Get-Sha $samplePath);source_rows=$rows.Count;automatic_logic_validation='PASS';review_rows=$out.Count
        selection_rule='SHA-256 deterministic stratification plus mandatory OP_RETURN reject, Arweave (AR) retain, Story (IP) retain, and IP Infrastructure reject regression cases'
        direct_semantic_review='UNVERIFIED';output_review_csv=$reviewPath;output_review_sha256=(Get-Sha $reviewPath);gate_CFA_S3F_019='UNVERIFIED';gate_CFA_S3_005='UNVERIFIED';gate_CFA_S3_006='BLOCKED'
    }
    Write-Utf8NoBom (Join-Path $runDir 'stage3-v5-bounded-sample-review-summary.json') (($summaryOut | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Write-Host ''
    Write-Host 'CFA STAGE 3 V5 BOUNDED SAMPLE PREPARATION: PASS'
    Write-Host ("Source sample rows: {0}" -f $rows.Count)
    Write-Host ("Review rows: {0}" -f $out.Count)
    Write-Host 'Automatic V5 rule consistency: PASS'
    Write-Host 'Direct semantic review: UNVERIFIED'
    Write-Host ("Review CSV: {0}" -f $reviewPath)
    Write-Host ("Evidence directory: {0}" -f $runDir)
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 3 V5 BOUNDED SAMPLE PREPARATION: FAIL'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    exit 1
}
