#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Resolve-RepoRelativeFile{
    param([string]$Root,[string]$Relative,[string]$Label)
    if([string]::IsNullOrWhiteSpace($Relative)){throw("{0} path is empty."-f$Label)}
    if([System.IO.Path]::IsPathRooted($Relative)){throw("{0} path must be repository-relative: {1}"-f$Label,$Relative)}
    $rootFull=[System.IO.Path]::GetFullPath($Root).TrimEnd('\','/');$full=[System.IO.Path]::GetFullPath((Join-Path $rootFull $Relative));$prefix=$rootFull+[System.IO.Path]::DirectorySeparatorChar
    if(-not($full.Equals($rootFull,[System.StringComparison]::OrdinalIgnoreCase)-or$full.StartsWith($prefix,[System.StringComparison]::OrdinalIgnoreCase))){throw("{0} path escapes repository root: {1}"-f$Label,$Relative)}
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw("{0} file missing: {1}"-f$Label,$Relative)}
    return $full
}
function Assert-Sha256{param([string]$Text,[string]$Label);if($Text-notmatch'^[0-9a-fA-F]{64}$'){throw("{0} is not SHA-256: {1}"-f$Label,$Text)}}
function Assert-HttpsHost{param([string]$Text,[string]$ExpectedHost,[string]$Label);$uri=$null;if(-not[Uri]::TryCreate($Text,[UriKind]::Absolute,[ref]$uri)){throw("{0} is not absolute URL: {1}"-f$Label,$Text)};if(-not$uri.Scheme.Equals('https',[System.StringComparison]::OrdinalIgnoreCase)){throw("{0} must use HTTPS."-f$Label)};if(-not$uri.Host.Equals($ExpectedHost,[System.StringComparison]::OrdinalIgnoreCase)){throw("{0} host mismatch: expected={1} observed={2}"-f$Label,$ExpectedHost,$uri.Host)}}
function Assert-XrepRows{
    param([object[]]$Rows,[object]$Blocker)
    if(@($Rows).Count-ne4){throw("XREP evidence must contain exactly 4 rows; observed {0}."-f@($Rows).Count)}
    $specs=@{
        'Q2_XREP_REPV1'=[pscustomobject]@{base='XREP';address=[string]$Blocker.q2_repv1_contract;name=[string]$Blocker.expected_repv1_name;symbol=[string]$Blocker.expected_repv1_symbol;id='';identity=[string]$Blocker.expected_repv1_identity_status}
        'Q2_REPV2'=[pscustomobject]@{base='REPV2';address=[string]$Blocker.q2_repv2_contract;name=[string]$Blocker.expected_repv2_name;symbol=[string]$Blocker.expected_repv2_symbol;id=[string]$Blocker.expected_repv2_coingecko_id;identity=[string]$Blocker.expected_repv2_identity_status}
    }
    $seen=@{}
    foreach($row in @($Rows)){
        $role=[string]$row.token_role;$endpoint=[string]$row.endpoint_type
        if(-not$specs.ContainsKey($role)){throw("Unsupported XREP token role: {0}"-f$role)}
        if(@('token_info','token_data')-notcontains$endpoint){throw("Unsupported XREP endpoint type: {0}"-f$endpoint)}
        $key=$role+'|'+$endpoint;if($seen.ContainsKey($key)){throw("Duplicate XREP evidence key: {0}"-f$key)};$seen[$key]=$true;$spec=$specs[$role]
        if([string]$row.base_asset_id-ne$spec.base){throw("XREP evidence base mismatch for {0}: {1}"-f$key,[string]$row.base_asset_id)}
        if([string]$row.network_id-ne'eth'){throw("XREP evidence network must be eth for {0}."-f$key)}
        if(-not([string]$row.token_address).Equals($spec.address,[System.StringComparison]::OrdinalIgnoreCase)){throw("XREP token address mismatch for {0}."-f$key)}
        if([int]$row.http_status-ne200-or[string]$row.parse_status-ne'PASS'){throw("XREP evidence request/parse must PASS for {0}: http={1} parse={2}"-f$key,[string]$row.http_status,[string]$row.parse_status)}
        if(-not([string]$row.returned_address).Equals($spec.address,[System.StringComparison]::OrdinalIgnoreCase)){throw("XREP returned address mismatch for {0}."-f$key)}
        if([string]$row.returned_name-ne$spec.name){throw("XREP returned name mismatch for {0}: {1}"-f$key,[string]$row.returned_name)}
        if(-not([string]$row.returned_symbol).Equals($spec.symbol,[System.StringComparison]::OrdinalIgnoreCase)){throw("XREP returned symbol mismatch for {0}: {1}"-f$key,[string]$row.returned_symbol)}
        if([string]$row.coingecko_coin_id-ne$spec.id){throw("XREP CoinGecko ID mismatch for {0}: expected={1} observed={2}"-f$key,$spec.id,[string]$row.coingecko_coin_id)}
        if([string]$row.identity_status-ne$spec.identity){throw("XREP identity status mismatch for {0}: {1}"-f$key,[string]$row.identity_status)}
        Assert-Sha256 ([string]$row.response_sha256) ("XREP response SHA-256 for {0}"-f$key);if([int64]$row.response_bytes-le0){throw("XREP response_bytes must be positive for {0}."-f$key)}
        Assert-HttpsHost ([string]$row.request_url) 'api.geckoterminal.com' ("XREP request URL for {0}"-f$key)
    }
    foreach($role in @($specs.Keys)){foreach($endpoint in @('token_info','token_data')){$key=$role+'|'+$endpoint;if(-not$seen.ContainsKey($key)){throw("XREP evidence missing key: {0}"-f$key)}}}
}
function Assert-Repv2DirectEvidence{
    param([object[]]$Rows,[object]$Blocker)
    $matches=@($Rows|Where-Object{[string]$_.base_asset_id-eq'REPV2'-and[string]$_.requested_candidate_id-eq[string]$Blocker.expected_repv2_coingecko_id})
    if($matches.Count-ne1){throw("Expected exactly one REPV2 direct evidence row; observed {0}."-f$matches.Count)};$row=$matches[0]
    if([int]$row.http_status-ne200-or[string]$row.parse_status-ne'PASS'){throw 'REPV2 direct CoinGecko evidence is not HTTP 200 / parse PASS.'}
    if([string]$row.returned_id-ne[string]$Blocker.expected_repv2_coingecko_id){throw("REPV2 direct returned ID mismatch: {0}"-f[string]$row.returned_id)}
    if(-not([string]$row.contract_address).Equals([string]$Blocker.q2_repv2_contract,[System.StringComparison]::OrdinalIgnoreCase)){throw("REPV2 direct contract mismatch: {0}"-f[string]$row.contract_address)}
    Assert-Sha256 ([string]$row.response_sha256) 'REPV2 direct response SHA-256';if([int64]$row.response_bytes-le0){throw 'REPV2 direct response_bytes must be positive.'}
}
function Invoke-Validation{
    param([string]$Root)
    $registryPath=Resolve-RepoRelativeFile $Root 'candidate-analysis\CFA-Stage2-Xrep-Blocker-Evidence.csv' 'XREP blocker registry';$blockers=@(Import-Csv -LiteralPath $registryPath)
    if($blockers.Count-ne1-or[string]$blockers[0].base_asset_id-ne'XREP'){throw 'XREP blocker registry must contain exactly one XREP row.'};$b=$blockers[0]
    Assert-Sha256 ([string]$b.evidence_sha256) 'XREP evidence SHA-256';foreach($name in @('q2_repv1_contract','q2_repv2_contract')){if([string]$b.$name-notmatch'^0x[0-9a-fA-F]{40}$'){throw("Invalid XREP contract in {0}."-f$name)}}
    if([string]$b.expected_repv1_symbol-ne'REP'-or[string]$b.expected_repv2_symbol-ne'REPv2'-or[string]$b.expected_repv2_coingecko_id-ne'augur'){throw 'XREP blocker expected version identities are invalid.'}
    $evidencePath=Resolve-RepoRelativeFile $Root ([string]$b.evidence_path) 'XREP GeckoTerminal evidence';$hash=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant();if($hash-ne([string]$b.evidence_sha256).ToLowerInvariant()){throw("XREP evidence hash mismatch: expected={0} observed={1}"-f[string]$b.evidence_sha256,$hash)};Assert-XrepRows @(Import-Csv -LiteralPath $evidencePath) $b
    $directPath=Resolve-RepoRelativeFile $Root ([string]$b.direct_evidence_path) 'Direct CoinGecko evidence';Assert-Repv2DirectEvidence @(Import-Csv -LiteralPath $directPath) $b
    $adjPath=Resolve-RepoRelativeFile $Root 'candidate-analysis\CFA-Stage2-Mapping-Adjudications-03.csv' 'Stage 2 mapping adjudication registry 03';$x=@(Import-Csv -LiteralPath $adjPath|Where-Object{[string]$_.base_asset_id-eq'XREP'});if($x.Count-ne1){throw("Expected exactly one XREP adjudication; observed {0}."-f$x.Count)};$adj=$x[0]
    if([string]$adj.decision_status-ne'UNVERIFIED'-or-not[string]::IsNullOrWhiteSpace([string]$adj.approved_coingecko_id)){throw 'XREP adjudication must remain UNVERIFIED with no approved ID.'}
    if([string]$adj.evidence_basis-ne'UNVERIFIED_REPV1_NO_EXPLICIT_COINGECKO_ID_AFTER_VERSION_SEPARATION'){throw("Unexpected XREP adjudication basis: {0}"-f[string]$adj.evidence_basis)}
    if([string]$adj.observed_kraken_ticker-ne'REP'){throw("XREP observed Kraken ticker must remain REP: {0}"-f[string]$adj.observed_kraken_ticker)}
    Assert-HttpsHost ([string]$adj.evidence_source_url) 'github.com' 'XREP adjudication primary source';$null=Resolve-RepoRelativeFile $Root ([string]$adj.secondary_evidence_url) 'XREP adjudication secondary evidence receipt'
    if([string]$adj.review_note-notmatch[regex]::Escape([string]$b.evidence_sha256)){throw 'XREP adjudication does not preserve frozen evidence hash.'}
    if([string]$adj.review_note-notmatch[regex]::Escape([string]$b.q2_repv1_contract)-or[string]$adj.review_note-notmatch[regex]::Escape([string]$b.q2_repv2_contract)){throw 'XREP adjudication does not preserve both contract identities.'}
    Write-Host 'CFA STAGE 2 XREP BLOCKER VALIDATION: PASS';Write-Host('XREP evidence SHA-256: '+$hash);Write-Host 'XREP mapping remains UNVERIFIED: REPv1 has no explicit CoinGecko stable ID while REPv2 is explicitly augur.'
}
function Assert-Throws{param([scriptblock]$Script,[string]$Pattern);$caught=$false;try{&$Script}catch{$caught=$true;if($_.Exception.Message-notmatch$Pattern){throw("Unexpected failure. Expected /{0}/; observed: {1}"-f$Pattern,$_.Exception.Message)}};if(-not$caught){throw("Expected failure matching /{0}/ but call succeeded."-f$Pattern)}}
function Invoke-SelfTest{
    $b=[pscustomobject]@{q2_repv1_contract='0x1985365e9f78359a9b6ad760e32412f4a445e862';q2_repv2_contract='0x221657776846890989a759ba2973e427dff5c9bb';expected_repv1_name='Reputation';expected_repv1_symbol='REP';expected_repv1_identity_status='UNVERIFIED_EMPTY_COINGECKO_ID';expected_repv2_name='Reputation';expected_repv2_symbol='REPv2';expected_repv2_coingecko_id='augur';expected_repv2_identity_status='PASS_EXPLICIT_COINGECKO_ID'}
    $rows=@();foreach($endpoint in @('token_info','token_data')){$rows+=[pscustomobject]@{base_asset_id='XREP';network_id='eth';token_address=$b.q2_repv1_contract;token_role='Q2_XREP_REPV1';endpoint_type=$endpoint;http_status='200';response_sha256=('a'*64);response_bytes='100';parse_status='PASS';returned_address=$b.q2_repv1_contract;returned_name='Reputation';returned_symbol='REP';coingecko_coin_id='';identity_status='UNVERIFIED_EMPTY_COINGECKO_ID';request_url=('https://api.geckoterminal.com/api/v2/networks/eth/tokens/'+$b.q2_repv1_contract)};$rows+=[pscustomobject]@{base_asset_id='REPV2';network_id='eth';token_address=$b.q2_repv2_contract;token_role='Q2_REPV2';endpoint_type=$endpoint;http_status='200';response_sha256=('b'*64);response_bytes='100';parse_status='PASS';returned_address=$b.q2_repv2_contract;returned_name='Reputation';returned_symbol='REPv2';coingecko_coin_id='augur';identity_status='PASS_EXPLICIT_COINGECKO_ID';request_url=('https://api.geckoterminal.com/api/v2/networks/eth/tokens/'+$b.q2_repv2_contract)}};Assert-XrepRows $rows $b
    $bad=@($rows|ForEach-Object{$_.PSObject.Copy()});$bad[0].coingecko_coin_id='augur';Assert-Throws {Assert-XrepRows $bad $b} 'CoinGecko ID mismatch'
    $direct=@([pscustomobject]@{base_asset_id='REPV2';requested_candidate_id='augur';http_status='200';parse_status='PASS';returned_id='augur';contract_address=$b.q2_repv2_contract;response_sha256=('c'*64);response_bytes='100'});Assert-Repv2DirectEvidence $direct $b
    $badDirect=@([pscustomobject]@{base_asset_id='REPV2';requested_candidate_id='augur';http_status='200';parse_status='PASS';returned_id='augur';contract_address=$b.q2_repv1_contract;response_sha256=('d'*64);response_bytes='100'});Assert-Throws {Assert-Repv2DirectEvidence $badDirect $b} 'contract mismatch';Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}
try{if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;Invoke-Validation $RepoRoot;exit 0}catch{Write-Host 'CFA STAGE 2 XREP BLOCKER VALIDATION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
