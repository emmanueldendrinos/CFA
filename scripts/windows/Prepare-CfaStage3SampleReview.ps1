#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Stage3RunRoot = 'D:\CFA-bulk\analysis\stage3-news-matching\20260829-200729-D-drive-revalidation',
    [string]$OutputRoot = 'D:\CFA-recovery\stage3-sample-review',
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
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Parse-Bool {
    param([object]$Value,[string]$Label)
    $x = ([string]$Value).Trim().ToLowerInvariant()
    if ($x -eq 'true') { return $true }
    if ($x -eq 'false') { return $false }
    throw "Malformed boolean in ${Label}: '$Value'"
}

function Get-StableSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-SampleLogic {
    param([object[]]$Rows)
    $errors = New-Object System.Collections.ArrayList
    $ordinal = 0
    foreach ($r in $Rows) {
        $ordinal++
        try {
            $status = ([string]$r.match_status).Trim()
            $requires = Parse-Bool $r.requires_crypto_context "row $ordinal requires_crypto_context"
            $econ = Parse-Bool $r.econ_bitcoin_theme "row $ordinal econ_bitcoin_theme"
            $title = Parse-Bool $r.title_crypto_anchor "row $ordinal title_crypto_anchor"
            $reason = ([string]$r.context_reason).Trim()
            if ($status -notin @('MATCH','REJECT_CONTEXT')) { throw "unexpected match_status '$status'" }
            if ($status -eq 'REJECT_CONTEXT') {
                if (-not $requires) { throw 'context rejection for alias that does not require context' }
                if ($econ -or $title) { throw 'context rejection despite qualifying context evidence' }
                if ($reason -ne 'NONE') { throw "context rejection has reason '$reason' instead of NONE" }
            }
            elseif (-not $requires) {
                if ($reason -ne 'NOT_REQUIRED') { throw "context-free MATCH has reason '$reason' instead of NOT_REQUIRED" }
            }
            else {
                if (-not ($econ -or $title)) { throw 'context-required MATCH lacks qualifying context evidence' }
                $expected = if ($econ -and $title) {'ECON_BITCOIN|TITLE_CRYPTO'} elseif ($econ) {'ECON_BITCOIN'} else {'TITLE_CRYPTO'}
                if ($reason -ne $expected) { throw "MATCH context reason '$reason' != '$expected'" }
            }
        }
        catch { [void]$errors.Add("row ${ordinal}: $($_.Exception.Message)") }
    }
    return [pscustomobject]@{status=if($errors.Count-eq0){'PASS'}else{'FAIL'};error_count=$errors.Count;errors=@($errors.ToArray())}
}

function Select-ReviewRows {
    param([object[]]$Rows,[int]$TakePerStratum,[int]$Maximum)
    $prepared = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        $surface = ([string]$r.matched_surfaces).Trim()
        if ([string]::IsNullOrWhiteSpace($surface)) { $surface = 'NONE' }
        $stratum = (([string]$r.match_status).Trim()) + '|' + (([string]$r.requires_crypto_context).Trim().ToLowerInvariant()) + '|' + (([string]$r.context_reason).Trim()) + '|' + $surface
        $stableKey = ([string]$r.base_asset_id) + '|' + ([string]$r.alias_text).ToLowerInvariant() + '|' + ([string]$r.record_id) + '|' + ([string]$r.match_status)
        [void]$prepared.Add([pscustomobject]@{row=$r;stratum=$stratum;stable_hash=(Get-StableSha256 $stableKey)})
    }

    $selected = New-Object System.Collections.ArrayList
    foreach ($group in @($prepared | Group-Object stratum | Sort-Object Name)) {
        foreach ($item in @($group.Group | Sort-Object stable_hash | Select-Object -First $TakePerStratum)) { [void]$selected.Add($item) }
    }
    if ($selected.Count -gt $Maximum) {
        $selected = New-Object System.Collections.ArrayList
        foreach ($item in @($prepared | Sort-Object stable_hash | Select-Object -First $Maximum)) { [void]$selected.Add($item) }
    }
    return @($selected.ToArray())
}

function Invoke-PrepareReview {
    param([string]$RunRoot,[string]$OutRoot,[int]$TakePerStratum,[int]$Maximum)
    $samplePath = Join-Path $RunRoot 'stage3-match-samples.csv'
    if (-not (Test-Path -LiteralPath $samplePath -PathType Leaf)) { throw "Stage 3 sample file missing: $samplePath" }
    $rows = @(Import-Csv -LiteralPath $samplePath)
    if ($rows.Count -eq 0) { throw 'Stage 3 sample file is empty.' }

    $required = @('match_status','base_asset_id','alias_text','requires_crypto_context','record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','matched_surfaces','econ_bitcoin_theme','title_crypto_anchor','context_reason')
    $properties = @($rows[0].PSObject.Properties.Name)
    foreach ($name in $required) { if ($properties -notcontains $name) { throw "Required sample column missing: $name" } }

    $logic = Assert-SampleLogic -Rows $rows
    if ($logic.status -ne 'PASS') { throw "Sample logic validation failed with $($logic.error_count) error(s): $(@($logic.errors | Select-Object -First 5) -join '; ')" }

    $selected = @(Select-ReviewRows -Rows $rows -TakePerStratum $TakePerStratum -Maximum $Maximum)
    if ($selected.Count -lt 20) { throw "Bounded review set unexpectedly small: $($selected.Count) rows." }

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $runDir = Join-Path $OutRoot $runId
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $reviewPath = Join-Path $runDir 'stage3-bounded-sample-review.csv'

    $outputRows = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($item in $selected) {
        $i++
        $r = $item.row
        [void]$outputRows.Add([pscustomobject][ordered]@{
            review_row_id = ('S3R-{0:000}' -f $i)
            stratum = $item.stratum
            stable_hash = $item.stable_hash
            match_status = [string]$r.match_status
            base_asset_id = [string]$r.base_asset_id
            alias_text = [string]$r.alias_text
            requires_crypto_context = [string]$r.requires_crypto_context
            record_id = [string]$r.record_id
            gdelt_date_utc = [string]$r.gdelt_date_utc
            source_common_name = [string]$r.source_common_name
            document_identifier = [string]$r.document_identifier
            page_title = [string]$r.page_title
            matched_surfaces = [string]$r.matched_surfaces
            econ_bitcoin_theme = [string]$r.econ_bitcoin_theme
            title_crypto_anchor = [string]$r.title_crypto_anchor
            context_reason = [string]$r.context_reason
            review_decision = ''
            review_note = ''
        })
    }
    @($outputRows.ToArray()) | Export-Csv -LiteralPath $reviewPath -NoTypeInformation -Encoding UTF8

    $statusCounts = @($rows | Group-Object match_status | Sort-Object Name | ForEach-Object { [ordered]@{status=$_.Name;count=$_.Count} })
    $reviewStatusCounts = @($outputRows | Group-Object match_status | Sort-Object Name | ForEach-Object { [ordered]@{status=$_.Name;count=$_.Count} })
    $summary = [ordered]@{
        status = 'PASS'
        source_samples = $samplePath
        source_sample_sha256 = (Get-FileHash -LiteralPath $samplePath -Algorithm SHA256).Hash.ToLowerInvariant()
        source_rows = $rows.Count
        automatic_logic_validation = 'PASS'
        source_status_counts = $statusCounts
        review_rows = $outputRows.Count
        review_status_counts = $reviewStatusCounts
        per_stratum = $TakePerStratum
        max_review_rows = $Maximum
        selection_rule = 'SHA-256 deterministic selection stratified by match_status, requires_crypto_context, context_reason, and matched_surfaces'
        direct_semantic_review = 'UNVERIFIED'
        output_review_csv = $reviewPath
    }
    Write-Utf8NoBom (Join-Path $runDir 'stage3-bounded-sample-review-summary.json') (($summary|ConvertTo-Json -Depth 8)+[Environment]::NewLine)

    Write-Host ''
    Write-Host 'CFA STAGE 3 BOUNDED SAMPLE PREPARATION: PASS'
    Write-Host "Source sample rows: $($rows.Count)"
    Write-Host "Review rows: $($outputRows.Count)"
    Write-Host 'Automatic sample-logic validation: PASS'
    Write-Host 'Direct semantic review: UNVERIFIED'
    Write-Host "Review CSV: $reviewPath"
    Write-Host "Evidence directory: $runDir"
    return $runDir
}

function Invoke-SelfTest {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-s3-review-' + [guid]::NewGuid().ToString('N'))
    try {
        $run = Join-Path $root 'run'; $out = Join-Path $root 'out'; New-Item -ItemType Directory -Path $run -Force | Out-Null
        $rows = New-Object System.Collections.ArrayList
        $surfaces = @('ALLNAMES','PAGE_TITLE','V2PERSONS','V2ORGANIZATIONS','ALLNAMES|PAGE_TITLE','V2PERSONS|PAGE_TITLE')
        for ($i=1; $i -le 36; $i++) {
            $kind = $i % 3
            if ($kind -eq 0) { $status='REJECT_CONTEXT';$req='True';$econ='False';$title='False';$reason='NONE' }
            elseif ($kind -eq 1) { $status='MATCH';$req='True';$econ='True';$title='False';$reason='ECON_BITCOIN' }
            else { $status='MATCH';$req='False';$econ='False';$title='False';$reason='NOT_REQUIRED' }
            $surfaceIndex=[int]([Math]::Floor(($i-1)/3)%$surfaces.Count)
            $surface=$surfaces[$surfaceIndex]
            [void]$rows.Add([pscustomobject][ordered]@{match_status=$status;base_asset_id=('A'+$i);alias_text=('Alias '+$i);requires_crypto_context=$req;record_id=('R'+$i);gdelt_date_utc='20250401000000';source_common_name='example';document_identifier=('https://example.test/'+$i);page_title=('Title '+$i);matched_surfaces=$surface;econ_bitcoin_theme=$econ;title_crypto_anchor=$title;context_reason=$reason})
        }
        @($rows.ToArray()) | Export-Csv -LiteralPath (Join-Path $run 'stage3-match-samples.csv') -NoTypeInformation -Encoding UTF8
        [void](Invoke-PrepareReview -RunRoot $run -OutRoot $out -TakePerStratum 2 -Maximum 180)
        $logic = Assert-SampleLogic -Rows @($rows.ToArray()); if($logic.status-ne'PASS'){throw 'Valid synthetic rows should pass.'}
        $rows[0].context_reason='NOT_REQUIRED';$bad=Assert-SampleLogic -Rows @($rows.ToArray());if($bad.status-ne'FAIL'){throw 'Corrupted sample logic should fail.'}
        Write-Host 'SELF-TEST: PASS'
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($SelfTest) {
    try { Invoke-SelfTest; exit 0 }
    catch { Write-Host 'SELF-TEST: FAIL'; Write-Host $_.Exception.Message; exit 1 }
}

try { [void](Invoke-PrepareReview -RunRoot $Stage3RunRoot -OutRoot $OutputRoot -TakePerStratum $PerStratum -Maximum $MaxReviewRows); exit 0 }
catch { Write-Host ''; Write-Host 'CFA STAGE 3 BOUNDED SAMPLE PREPARATION: FAIL'; Write-Host $_.Exception.Message; if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}; exit 1 }
