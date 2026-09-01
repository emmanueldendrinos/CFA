#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CandidateReceiptPath,
    [Parameter(Mandatory=$true)][string]$Stage4ResponsesPath,
    [string]$RepoRoot='',
    [string]$OutputRoot='',
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$SourcePath=Join-Path $PSScriptRoot 'Validate-CfaStage5FactorArtifact.ps1'
if(-not(Test-Path -LiteralPath $SourcePath -PathType Leaf)){throw "Source validator missing: $SourcePath"}

if([string]::IsNullOrWhiteSpace($RepoRoot)){$EffectiveRepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}else{$EffectiveRepoRoot=$RepoRoot}
$EffectiveRepoRoot=(Resolve-Path -LiteralPath $EffectiveRepoRoot).ProviderPath
if(-not(Test-Path -LiteralPath (Join-Path $EffectiveRepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv') -PathType Leaf)){throw "CFA repository-root preflight failed: $EffectiveRepoRoot"}

$text=[IO.File]::ReadAllText($SourcePath)

$targetDay=@'
    foreach($k in $dayAgg.Keys){if(-not$dayByKey.ContainsKey($k)){throw "Missing day-summary row: $k"};$d=$dayByKey[$k];foreach($p in @('response_rows','market_available_rows','market_missing_rows','news24_available_rows','news24_incomplete_rows','news24_outside_rows','news6_available_rows','news6_incomplete_rows','news6_outside_rows')){if((Parse-LongStrict $d.$p "$k day summary $p")-ne[long]$dayAgg[$k][$p]){throw "Day-summary mismatch: $k $p"}}}
'@
$replacementDay=@'
    foreach($k in $dayAgg.Keys){
        if(-not$dayByKey.ContainsKey($k)){throw "Missing day-summary row: $k"}
        $d=$dayByKey[$k]
        foreach($p in @('response_rows','market_available_rows','market_missing_rows','news24_available_rows','news24_incomplete_rows','news24_outside_rows','news6_available_rows','news6_incomplete_rows','news6_outside_rows')){
            $expectedValue=[long]($dayAgg[$k][$p])
            $observedValue=Parse-LongStrict $d.$p "$k day summary $p"
            if($observedValue-ne$expectedValue){throw "Day-summary mismatch: $k $p"}
        }
    }
'@
$targetReview=@'
    foreach($rv in $review){$k=([string]$rv.base_asset_id)+'|'+([string]$rv.response_day_utc);if(-not$factorByKey.ContainsKey($k)){throw "Review key absent from factor artifact: $k"};$src=$factorByKey[$k];foreach($p in $src.PSObject.Properties){if(([string]$rv.($p.Name))-cne([string]$p.Value){throw "Review row differs from factor artifact: $k column=$($p.Name)"}};foreach($reason in (([string]$rv.review_reason)-split'\|')){if(-not[string]::IsNullOrWhiteSpace($reason)){[void]$reviewReasons.Add($reason)}};[void]$reviewValidation.Add([pscustomobject][ordered]@{base_asset_id=$rv.base_asset_id;response_day_utc=$rv.response_day_utc;review_reason=$rv.review_reason;validation_status='PASS'})}
'@
$replacementReview=@'
    foreach($rv in $review){
        $k=([string]$rv.base_asset_id)+'|'+([string]$rv.response_day_utc)
        if(-not$factorByKey.ContainsKey($k)){throw "Review key absent from factor artifact: $k"}
        $src=$factorByKey[$k]
        foreach($p in $src.PSObject.Properties){
            $reviewProp=$rv.PSObject.Properties[$p.Name]
            if($null-eq$reviewProp){throw "Review column missing: $k column=$($p.Name)"}
            $observedReviewValue=[string]$reviewProp.Value
            $expectedReviewValue=[string]$p.Value
            if($observedReviewValue-cne$expectedReviewValue){throw "Review row differs from factor artifact: $k column=$($p.Name)"}
        }
        foreach($reason in (([string]$rv.review_reason)-split'\|')){if(-not[string]::IsNullOrWhiteSpace($reason)){[void]$reviewReasons.Add($reason)}}
        [void]$reviewValidation.Add([pscustomobject][ordered]@{base_asset_id=$rv.base_asset_id;response_day_utc=$rv.response_day_utc;review_reason=$rv.review_reason;validation_status='PASS'})
    }
'@

foreach($pair in @(
    [pscustomobject]@{Name='day-summary';Target=$targetDay;Replacement=$replacementDay},
    [pscustomobject]@{Name='review-property';Target=$targetReview;Replacement=$replacementReview}
)){
    $count=[regex]::Matches($text,[regex]::Escape($pair.Target),[Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
    if($count-ne1){throw "V2 $($pair.Name) repair target occurrence count changed: expected 1, observed $count."}
    $text=$text.Replace($pair.Target,$pair.Replacement)
}

if($text.Contains('-ne[long]$dayAgg[$k][$p]')){throw 'Ambiguous day-summary cast remained after V2 repair.'}
if($text.Contains('$rv.($p.Name)')){throw 'Ambiguous dynamic review property access remained after V2 repair.'}
if(-not$text.Contains('$expectedValue=[long]($dayAgg[$k][$p])')){throw 'Explicit day-summary expected-value repair missing.'}
if(-not$text.Contains('$reviewProp=$rv.PSObject.Properties[$p.Name]')){throw 'Explicit review-property repair missing.'}

$tempPath=Join-Path ([IO.Path]::GetTempPath()) ('CFA-Stage5-FactorArtifactValidatorV2-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
    [IO.File]::WriteAllText($tempPath,$text,(New-Object Text.UTF8Encoding($false)))
    $argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$tempPath,'-CandidateReceiptPath',$CandidateReceiptPath,'-Stage4ResponsesPath',$Stage4ResponsesPath,'-RepoRoot',$EffectiveRepoRoot)
    if(-not[string]::IsNullOrWhiteSpace($OutputRoot)){$argsList+=@('-OutputRoot',$OutputRoot)}
    if($SelfTest){$argsList+='-SelfTest'}
    & powershell.exe @argsList
    $code=$LASTEXITCODE;if($null-eq$code){$code=0};exit $code
}
finally{Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue}
