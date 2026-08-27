#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-OptionalText {
    param([object]$Object,[string]$Name)
    if($null-eq$Object){return ''}
    $property=$Object.PSObject.Properties[$Name]
    if($null-eq$property){return ''}
    return [string]$property.Value
}
function Resolve-RepoRelativeFile {
    param([string]$Root,[string]$Relative,[string]$Label)
    if([string]::IsNullOrWhiteSpace($Relative)){throw("{0} path is empty."-f$Label)}
    if([System.IO.Path]::IsPathRooted($Relative)){throw("{0} path must be repository-relative: {1}"-f$Label,$Relative)}
    $rootFull=[System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full=[System.IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    $prefix=$rootFull+[System.IO.Path]::DirectorySeparatorChar
    if(-not($full.Equals($rootFull,[System.StringComparison]::OrdinalIgnoreCase)-or$full.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase))){throw("{0} path escapes repository root: {1}"-f$Label,$Relative)}
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw("{0} file missing: {1}"-f$Label,$Relative)}
    return $full
}
function Assert-Sha256Text {
    param([string]$Text,[string]$Label)
    if($Text-notmatch'^[0-9a-fA-F]{64}$'){throw("{0} is not a SHA-256 value: {1}"-f$Label,$Text)}
}
function Assert-HttpsHost {
    param([string]$Text,[string]$ExpectedHost,[string]$Label)
    $uri=$null
    if(-not[Uri]::TryCreate($Text,[UriKind]::Absolute,[ref]$uri)){throw("{0} is not an absolute URL: {1}"-f$Label,$Text)}
    if(-not$uri.Scheme.Equals('https',[System.StringComparison]::OrdinalIgnoreCase)){throw("{0} must use HTTPS: {1}"-f$Label,$Text)}
    if(-not$uri.Host.Equals($ExpectedHost,[System.StringComparison]::OrdinalIgnoreCase)){throw("{0} host mismatch: expected={1} observed={2}"-f$Label,$ExpectedHost,$uri.Host)}
}
function Assert-KintoEvidenceRows {
    param([object[]]$Rows,[object]$Blocker,[string]$Label)
    if(@($Rows).Count-ne2){throw("{0} must contain exactly 2 rows; observed {1}."-f$Label,@($Rows).Count)}
    $expectedByRole=@{
        'Q2_2025_ACTIVE_CONTRACT'=[string]$Blocker.q2_contract_address
        'POST_Q2_MIGRATED_CONTRACT'=[string]$Blocker.post_q2_contract_address
    }
    $seen=@{}
    foreach($row in @($Rows)){
        $role=[string]$row.temporal_role
        if(-not$expectedByRole.ContainsKey($role)){throw("{0} contains unsupported temporal_role: {1}"-f$Label,$role)}
        if($seen.ContainsKey($role)){throw("{0} contains duplicate temporal_role: {1}"-f$Label,$role)}
        $seen[$role]=$true
        $expectedAddress=$expectedByRole[$role]
        if([string]$row.base_asset_id-ne'K'){throw("{0} base_asset_id must be K for role {1}."-f$Label,$role)}
        if([string]$row.network_id-ne'arbitrum'){throw("{0} network_id must be arbitrum for role {1}."-f$Label,$role)}
        if(-not([string]$row.token_address).Equals($expectedAddress,[System.StringComparison]::OrdinalIgnoreCase)){throw("{0} token address mismatch for role {1}."-f$Label,$role)}
        if([int]$row.http_status-ne200){throw("{0} HTTP status must be 200 for role {1}; observed {2}."-f$Label,$role,[string]$row.http_status)}
        if([string]$row.parse_status-ne'PASS'){throw("{0} parse_status must be PASS for role {1}; observed {2}."-f$Label,$role,[string]$row.parse_status)}
        if(-not([string]$row.returned_address).Equals($expectedAddress,[System.StringComparison]::OrdinalIgnoreCase)){throw("{0} returned address mismatch for role {1}."-f$Label,$role)}
        if([string]$row.returned_name-ne[string]$Blocker.expected_name){throw("{0} returned name mismatch for role {1}: {2}"-f$Label,$role,[string]$row.returned_name)}
        if(-not([string]$row.returned_symbol).Equals([string]$Blocker.expected_symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw("{0} returned symbol mismatch for role {1}: {2}"-f$Label,$role,[string]$row.returned_symbol)}
        if(-not[string]::IsNullOrWhiteSpace([string]$row.coingecko_coin_id)){throw("{0} unexpectedly exposes CoinGecko ID for role {1}: {2}"-f$Label,$role,[string]$row.coingecko_coin_id)}
        if([string]$row.identity_status-ne[string]$Blocker.expected_identity_status){throw("{0} identity_status mismatch for role {1}: {2}"-f$Label,$role,[string]$row.identity_status)}
        Assert-Sha256Text ([string]$row.response_sha256) ("{0} response SHA-256 for {1}"-f$Label,$role)
        if([int64]$row.response_bytes-le0){throw("{0} response_bytes must be positive for role {1}."-f$Label,$role)}
        Assert-HttpsHost ([string]$row.request_url) 'api.geckoterminal.com' ("{0} request URL for {1}"-f$Label,$role)
    }
    foreach($required in @($expectedByRole.Keys)){if(-not$seen.ContainsKey($required)){throw("{0} missing temporal_role: {1}"-f$Label,$required)}}
}
function Assert-KintoDirect404 {
    param([object[]]$Rows)
    $matches=@($Rows|Where-Object{[string]$_.base_asset_id-eq'K'-and[string]$_.requested_candidate_id-eq'kinto'})
    if($matches.Count-ne1){throw("Expected exactly one direct K/kinto evidence row; observed {0}."-f$matches.Count)}
    $row=$matches[0]
    if([int]$row.http_status-ne404){throw("Direct K/kinto evidence must be HTTP 404; observed {0}."-f[string]$row.http_status)}
    if([string]$row.parse_status-ne'NOT_APPLICABLE'){throw("Direct K/kinto parse status must be NOT_APPLICABLE; observed {0}."-f[string]$row.parse_status)}
    if(-not[string]::IsNullOrWhiteSpace([string]$row.returned_id)){throw("Direct K/kinto evidence unexpectedly returned CoinGecko ID: {0}"-f[string]$row.returned_id)}
    Assert-Sha256Text ([string]$row.response_sha256) 'Direct K/kinto response SHA-256'
    if([int64]$row.response_bytes-le0){throw 'Direct K/kinto response_bytes must be positive.'}
}
function Invoke-Validation {
    param([string]$Root)
    $blockerRegistry=Resolve-RepoRelativeFile $Root 'candidate-analysis\CFA-Stage2-Kinto-Blocker-Evidence.csv' 'Kinto blocker registry'
    $blockers=@(Import-Csv -LiteralPath $blockerRegistry)
    if($blockers.Count-ne1-or[string]$blockers[0].base_asset_id-ne'K'){throw 'Kinto blocker registry must contain exactly one K row.'}
    $blocker=$blockers[0]
    Assert-Sha256Text ([string]$blocker.token_info_evidence_sha256) 'Kinto token-info evidence SHA-256'
    Assert-Sha256Text ([string]$blocker.token_data_evidence_sha256) 'Kinto token-data evidence SHA-256'
    foreach($addressName in @('q2_contract_address','post_q2_contract_address')){if((Get-OptionalText $blocker $addressName)-notmatch'^0x[0-9a-fA-F]{40}$'){throw("Invalid Kinto blocker contract address in {0}."-f$addressName)}}
    if([string]$blocker.expected_name-ne'Kinto'-or-not([string]$blocker.expected_symbol).Equals('K',[System.StringComparison]::OrdinalIgnoreCase)){throw 'Kinto blocker expected name/symbol must be Kinto/K.'}
    if([string]$blocker.expected_identity_status-ne'UNVERIFIED_EMPTY_COINGECKO_ID'){throw 'Kinto blocker expected identity status must preserve the empty-ID result.'}

    $infoPath=Resolve-RepoRelativeFile $Root ([string]$blocker.token_info_evidence_path) 'Kinto token-info evidence'
    $dataPath=Resolve-RepoRelativeFile $Root ([string]$blocker.token_data_evidence_path) 'Kinto token-data evidence'
    $directPath=Resolve-RepoRelativeFile $Root ([string]$blocker.direct_evidence_path) 'Direct CoinGecko evidence'
    $infoHash=(Get-FileHash -LiteralPath $infoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dataHash=(Get-FileHash -LiteralPath $dataPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if($infoHash-ne([string]$blocker.token_info_evidence_sha256).ToLowerInvariant()){throw("Kinto token-info evidence hash mismatch: expected={0} observed={1}"-f[string]$blocker.token_info_evidence_sha256,$infoHash)}
    if($dataHash-ne([string]$blocker.token_data_evidence_sha256).ToLowerInvariant()){throw("Kinto token-data evidence hash mismatch: expected={0} observed={1}"-f[string]$blocker.token_data_evidence_sha256,$dataHash)}
    Assert-KintoEvidenceRows @(Import-Csv -LiteralPath $infoPath) $blocker 'Kinto token-info evidence'
    Assert-KintoEvidenceRows @(Import-Csv -LiteralPath $dataPath) $blocker 'Kinto token-data evidence'
    Assert-KintoDirect404 @(Import-Csv -LiteralPath $directPath)

    $adjPath=Resolve-RepoRelativeFile $Root 'candidate-analysis\CFA-Stage2-Mapping-Adjudications-03.csv' 'Stage 2 mapping adjudication registry 03'
    $kRows=@(Import-Csv -LiteralPath $adjPath|Where-Object{[string]$_.base_asset_id-eq'K'})
    if($kRows.Count-ne1){throw("Expected exactly one K adjudication row; observed {0}."-f$kRows.Count)}
    $adj=$kRows[0]
    if([string]$adj.decision_status-ne'UNVERIFIED'){throw 'K adjudication must remain UNVERIFIED.'}
    if(-not[string]::IsNullOrWhiteSpace([string]$adj.approved_coingecko_id)){throw 'K UNVERIFIED adjudication cannot carry an approved CoinGecko ID.'}
    if([string]$adj.evidence_basis-ne'UNVERIFIED_KINTO_NO_EXPLICIT_COINGECKO_ID'){throw("Unexpected K adjudication basis: {0}"-f[string]$adj.evidence_basis)}
    if([string]$adj.observed_kraken_name-ne'Kinto'-or-not([string]$adj.observed_kraken_ticker).Equals('K',[System.StringComparison]::OrdinalIgnoreCase)){throw 'K adjudication must preserve Kraken Kinto/K identity.'}
    Assert-HttpsHost ([string]$adj.evidence_source_url) 'docs.kinto.xyz' 'K adjudication primary source'
    if([string]$adj.review_note-notmatch[regex]::Escape([string]$blocker.token_info_evidence_sha256)){throw 'K adjudication note does not preserve token-info evidence hash.'}
    if([string]$adj.review_note-notmatch[regex]::Escape([string]$blocker.token_data_evidence_sha256)){throw 'K adjudication note does not preserve token-data evidence hash.'}
    $secondary=[string]$adj.secondary_evidence_url
    $null=Resolve-RepoRelativeFile $Root $secondary 'K adjudication secondary evidence receipt'

    Write-Host 'CFA STAGE 2 KINTO BLOCKER VALIDATION: PASS'
    Write-Host ('Token-info evidence SHA-256: '+$infoHash)
    Write-Host ('Token-data evidence SHA-256: '+$dataHash)
    Write-Host 'K mapping remains UNVERIFIED: no explicit CoinGecko stable ID was returned by the validated public evidence paths.'
}
function Assert-Throws {
    param([scriptblock]$Script,[string]$Pattern)
    $caught=$false
    try{&$Script}catch{$caught=$true;if($_.Exception.Message-notmatch$Pattern){throw("Unexpected failure. Expected /{0}/; observed: {1}"-f$Pattern,$_.Exception.Message)}}
    if(-not$caught){throw("Expected failure matching /{0}/ but call succeeded."-f$Pattern)}
}
function Invoke-SelfTest {
    $blocker=[pscustomobject]@{q2_contract_address='0x010700ab046dd8e92b0e3587842080df36364ed3';post_q2_contract_address='0x6ba19ee69d5dde3ab70185c801fa404f66fedb58';expected_name='Kinto';expected_symbol='K';expected_identity_status='UNVERIFIED_EMPTY_COINGECKO_ID'}
    $rows=@(
        [pscustomobject]@{base_asset_id='K';network_id='arbitrum';token_address=$blocker.q2_contract_address;temporal_role='Q2_2025_ACTIVE_CONTRACT';http_status='200';response_sha256=('a'*64);response_bytes='100';parse_status='PASS';returned_address=$blocker.q2_contract_address;returned_name='Kinto';returned_symbol='K';coingecko_coin_id='';identity_status='UNVERIFIED_EMPTY_COINGECKO_ID';request_url=('https://api.geckoterminal.com/api/v2/networks/arbitrum/tokens/'+$blocker.q2_contract_address)},
        [pscustomobject]@{base_asset_id='K';network_id='arbitrum';token_address=$blocker.post_q2_contract_address;temporal_role='POST_Q2_MIGRATED_CONTRACT';http_status='200';response_sha256=('b'*64);response_bytes='100';parse_status='PASS';returned_address=$blocker.post_q2_contract_address;returned_name='Kinto';returned_symbol='K';coingecko_coin_id='';identity_status='UNVERIFIED_EMPTY_COINGECKO_ID';request_url=('https://api.geckoterminal.com/api/v2/networks/arbitrum/tokens/'+$blocker.post_q2_contract_address)}
    )
    Assert-KintoEvidenceRows $rows $blocker 'self-test'
    $bad=@($rows[0].PSObject.Copy(),$rows[1].PSObject.Copy());$bad[0].coingecko_coin_id='unexpected-id'
    Assert-Throws {Assert-KintoEvidenceRows $bad $blocker 'self-test-bad'} 'unexpectedly exposes CoinGecko ID'
    $direct=@([pscustomobject]@{base_asset_id='K';requested_candidate_id='kinto';http_status='404';parse_status='NOT_APPLICABLE';returned_id='';response_sha256=('c'*64);response_bytes='26'})
    Assert-KintoDirect404 $direct
    $directBad=@([pscustomobject]@{base_asset_id='K';requested_candidate_id='kinto';http_status='200';parse_status='PASS';returned_id='kinto';response_sha256=('d'*64);response_bytes='100'})
    Assert-Throws {Assert-KintoDirect404 $directBad} 'must be HTTP 404'
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}
try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    Invoke-Validation $RepoRoot
    exit 0
}catch{Write-Host 'CFA STAGE 2 KINTO BLOCKER VALIDATION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
