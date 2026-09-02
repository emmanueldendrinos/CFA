#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Stage6ValidationReceiptPath,
    [string]$OutputPath='',
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
$ExpectedVariables=@(
    'response_value_log_return',
    'MKT_RET_USD_UTC_DAY_OBS_L1',
    'MKT_RANGE_LOG_UTC_DAY_L1',
    'MKT_OBS_COUNT_UTC_DAY_L1',
    'MKT_OBS_SPAN_MIN_UTC_DAY_L1',
    'NEWS_V6_MATCH_COUNT_24H_LAG15',
    'NEWS_V6_MATCH_COUNT_6H_LAG15',
    'NEWS_V6_SOURCE_COUNT_24H_LAG15'
)

function Get-Sha([string]$Path){
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Require-File([string]$Path,[string]$Label){
    $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if(-not(Test-Path -LiteralPath $resolved -PathType Leaf)){throw "$Label is not a file: $resolved"}
    return $resolved
}
function Require-Equal([object]$Actual,[object]$Expected,[string]$Label){
    if([string]$Actual -cne [string]$Expected){throw "$Label mismatch: observed='$Actual' expected='$Expected'"}
}
function Test-Receipt([object]$Receipt,[string]$RejectPath,[string]$DiagnosticsPath){
    Require-Equal $Receipt.status 'PASS' 'Stage 6 status'
    Require-Equal $Receipt.stage 'CFA_STAGE_6' 'Stage 6 identity'
    Require-Equal $Receipt.validation 'DATA_QUALITY_LEAKAGE_V1' 'Stage 6 validation identity'
    Require-Equal $Receipt.sources.stage4_responses_sha256 $ExpectedStage4Sha 'Stage 4 SHA-256'
    Require-Equal $Receipt.sources.factor_csv_sha256 $ExpectedFactorSha 'Stage 5 factor SHA-256'
    if([long]$Receipt.cardinality.rows-ne$ExpectedRows-or[int]$Receipt.cardinality.bases-ne$ExpectedBases-or[int]$Receipt.cardinality.days-ne$ExpectedDays){throw 'Stage 6 cardinality mismatch.'}
    if([long]$Receipt.violations.count-ne0){throw "Stage 6 receipt contains blocking violations: $($Receipt.violations.count)"}
    foreach($id in 1..8){$gate=('CFA-S6-{0:D3}' -f $id);Require-Equal $Receipt.gates.$gate 'PASS' "$gate status"}
    Require-Equal $Receipt.gates.'CFA-S6-009' 'BLOCKED' 'CFA-S6-009 pre-freeze status'
    Require-Equal (Get-Sha $RejectPath) ([string]$Receipt.violations.reject_csv_sha256).ToLowerInvariant() 'Reject CSV SHA-256'
    Require-Equal (Get-Sha $DiagnosticsPath) ([string]$Receipt.diagnostics.descriptive_csv_sha256).ToLowerInvariant() 'Diagnostics CSV SHA-256'
}

function Invoke-SelfTest {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('CFA-S6-Finalizer-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    try {
        $reject=Join-Path $root 'reject.csv';[IO.File]::WriteAllText($reject,"key,gate,reason,detail`r`n",(New-Object Text.UTF8Encoding($false)))
        $diag=Join-Path $root 'diag.csv';@($ExpectedVariables|ForEach-Object{[pscustomobject]@{variable=$_;non_null='1';null='0';min='0';max='1';unique_count='1'}})|Export-Csv -LiteralPath $diag -NoTypeInformation -Encoding UTF8
        $receipt=[pscustomobject]@{
            status='PASS';stage='CFA_STAGE_6';validation='DATA_QUALITY_LEAKAGE_V1';
            sources=[pscustomobject]@{stage4_responses_sha256=$ExpectedStage4Sha;factor_csv_sha256=$ExpectedFactorSha};
            cardinality=[pscustomobject]@{rows=$ExpectedRows;bases=$ExpectedBases;days=$ExpectedDays};
            violations=[pscustomobject]@{count=0;reject_csv_sha256=(Get-Sha $reject)};
            diagnostics=[pscustomobject]@{descriptive_csv_sha256=(Get-Sha $diag)};
            gates=[pscustomobject]@{'CFA-S6-001'='PASS';'CFA-S6-002'='PASS';'CFA-S6-003'='PASS';'CFA-S6-004'='PASS';'CFA-S6-005'='PASS';'CFA-S6-006'='PASS';'CFA-S6-007'='PASS';'CFA-S6-008'='PASS';'CFA-S6-009'='BLOCKED'}
        }
        Test-Receipt $receipt $reject $diag
        Write-Host 'SELF-TEST: PASS'
    }
    finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try {
    $receiptPath=Require-File $Stage6ValidationReceiptPath 'Stage 6 validation receipt'
    $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
    $rejectPath=Require-File ([string]$receipt.violations.reject_csv) 'Stage 6 reject CSV'
    $diagnosticsPath=Require-File ([string]$receipt.diagnostics.descriptive_csv) 'Stage 6 diagnostics CSV'
    $stage4Path=Require-File ([string]$receipt.sources.stage4_responses_path) 'Frozen Stage 4 responses'
    $stage5ReceiptPath=Require-File ([string]$receipt.sources.stage5_validation_receipt_path) 'Frozen Stage 5 validation receipt'
    $factorPath=Require-File ([string]$receipt.sources.factor_csv) 'Frozen Stage 5 factor CSV'

    Require-Equal (Get-Sha $stage4Path) $ExpectedStage4Sha 'Actual Stage 4 SHA-256'
    Require-Equal (Get-Sha $factorPath) $ExpectedFactorSha 'Actual factor CSV SHA-256'
    Require-Equal (Get-Sha $stage5ReceiptPath) ([string]$receipt.sources.stage5_validation_receipt_sha256).ToLowerInvariant() 'Stage 5 validation receipt SHA-256'
    Test-Receipt $receipt $rejectPath $diagnosticsPath

    $rejectLines=@(Get-Content -LiteralPath $rejectPath)
    if($rejectLines.Count-ne1-or$rejectLines[0]-cne'key,gate,reason,detail'){throw 'Reject CSV is not the expected header-only zero-violation artifact.'}

    $diag=@(Import-Csv -LiteralPath $diagnosticsPath)
    if($diag.Count-ne$ExpectedVariables.Count){throw "Diagnostics row count mismatch: $($diag.Count)"}
    $observedVariables=@($diag|ForEach-Object{[string]$_.variable})
    if(($observedVariables-join'|')-cne($ExpectedVariables-join'|')){throw 'Diagnostics variable set/order mismatch.'}
    foreach($row in $diag){foreach($name in @('non_null','null','unique_count')){$n=[long]0;if(-not[long]::TryParse([string]$row.$name,[ref]$n)-or$n-lt0){throw "Malformed diagnostics integer: $($row.variable) $name"}}}

    $freeze=[ordered]@{
        status='PASS';stage='CFA_STAGE_6';freeze_candidate='DQ_LEAKAGE_V1';
        validation_receipt_path=$receiptPath;validation_receipt_sha256=(Get-Sha $receiptPath);
        reject_csv=$rejectPath;reject_csv_sha256=(Get-Sha $rejectPath);
        descriptive_diagnostics_csv=$diagnosticsPath;descriptive_diagnostics_csv_sha256=(Get-Sha $diagnosticsPath);
        stage4_responses_sha256=$ExpectedStage4Sha;factor_csv_sha256=$ExpectedFactorSha;
        gates=[ordered]@{'CFA-S6-001'='PASS';'CFA-S6-002'='PASS';'CFA-S6-003'='PASS';'CFA-S6-004'='PASS';'CFA-S6-005'='PASS';'CFA-S6-006'='PASS';'CFA-S6-007'='PASS';'CFA-S6-008'='PASS';'CFA-S6-009'='UNVERIFIED'};
        next_action='Record these exact hashes in repository evidence, then promote CFA-S6-009 to PASS.'
    }
    if([string]::IsNullOrWhiteSpace($OutputPath)){$OutputPath=Join-Path (Split-Path -Parent $receiptPath) 'stage6-freeze-candidate.json'}
    [IO.File]::WriteAllText($OutputPath,(($freeze|ConvertTo-Json -Depth 8)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host 'CFA STAGE 6 FREEZE CANDIDATE: PASS'
    Write-Host "Validation receipt SHA-256: $($freeze.validation_receipt_sha256)"
    Write-Host "Reject CSV SHA-256: $($freeze.reject_csv_sha256)"
    Write-Host "Descriptive diagnostics SHA-256: $($freeze.descriptive_diagnostics_csv_sha256)"
    Write-Host "Freeze candidate SHA-256: $(Get-Sha $OutputPath)"
    Write-Host 'CFA-S6-001 through CFA-S6-008: PASS'
    Write-Host 'CFA-S6-009 Stage 6 freeze: UNVERIFIED'
    Write-Host "Freeze candidate: $OutputPath"
    exit 0
}
catch {
    Write-Host ''
    Write-Host 'CFA STAGE 6 FREEZE CANDIDATE: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
