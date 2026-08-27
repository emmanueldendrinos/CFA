#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [string]$ApiRoot='https://api.geckoterminal.com/api/v2',
    [ValidateRange(0,30000)][int]$DelayMs=7000,
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Get-Sha256Bytes{param([byte[]]$Bytes);$s=[System.Security.Cryptography.SHA256]::Create();try{return(($s.ComputeHash($Bytes)|ForEach-Object{$_.ToString('x2')})-join'')}finally{$s.Dispose()}}
function Get-PropertyValue{param([object]$Object,[string]$Name);if($null-eq$Object){return $null};if($Object-is[System.Collections.IDictionary]){foreach($k in @($Object.Keys)){if(([string]$k).Equals($Name,[System.StringComparison]::Ordinal)){return $Object[$k]}};return $null};foreach($p in @($Object.PSObject.Properties)){if(([string]$p.Name).Equals($Name,[System.StringComparison]::Ordinal)){return $p.Value}};return $null}
function Convert-CfaJsonObject{param([string]$Json);try{return($Json|ConvertFrom-Json)}catch{$primary=$_.Exception.Message;try{Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop|Out-Null;$serializer=New-Object System.Web.Script.Serialization.JavaScriptSerializer;$serializer.MaxJsonLength=67108864;return $serializer.DeserializeObject($Json)}catch{throw("GeckoTerminal JSON parse failed. ConvertFrom-Json: {0}; JavaScriptSerializer: {1}"-f$primary,$_.Exception.Message)}}}
function Convert-TokenResponse{
    param([byte[]]$Bytes)
    $json=(New-Object System.Text.UTF8Encoding($false,$true)).GetString($Bytes);$root=Convert-CfaJsonObject $json;$data=Get-PropertyValue $root 'data'
    if($null-eq$data){throw 'GeckoTerminal response missing data object.'};$type=[string](Get-PropertyValue $data 'type');if($type-ne'token'){throw("GeckoTerminal response type is not token: {0}"-f$type)}
    $a=Get-PropertyValue $data 'attributes';if($null-eq$a){throw 'GeckoTerminal response missing attributes object.'};$address=[string](Get-PropertyValue $a 'address');$name=[string](Get-PropertyValue $a 'name');$symbol=[string](Get-PropertyValue $a 'symbol')
    if([string]::IsNullOrWhiteSpace($address)-or[string]::IsNullOrWhiteSpace($name)-or[string]::IsNullOrWhiteSpace($symbol)){throw 'GeckoTerminal token identity fields are incomplete.'}
    $idValue=Get-PropertyValue $a 'coingecko_coin_id';$id=if($null-eq$idValue){''}else{[string]$idValue}
    return [pscustomobject]@{resource_id=[string](Get-PropertyValue $data 'id');address=$address;name=$name;symbol=$symbol;coingecko_coin_id=$id}
}
function Invoke-GeckoTerminalRequest{
    param([string]$Url,[int]$MaxAttempts=4)
    for($attempt=1;$attempt-le$MaxAttempts;$attempt++){$response=$null;try{$request=[System.Net.HttpWebRequest]::Create($Url);$request.Method='GET';$request.UserAgent='CFA-stage2-xrep-geckoterminal-evidence/1.0';$request.Accept='application/json;version=20230203';$request.Timeout=45000;$request.ReadWriteTimeout=45000;$response=[System.Net.HttpWebResponse]$request.GetResponse();$stream=$response.GetResponseStream();$memory=New-Object System.IO.MemoryStream;try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()};return [pscustomobject]@{status_code=[int]$response.StatusCode;bytes=$bytes;error=''}}catch [System.Net.WebException]{$status=0;$body=[byte[]]@();$message=$_.Exception.Message;if($null-ne$_.Exception.Response){$wr=[System.Net.HttpWebResponse]$_.Exception.Response;$status=[int]$wr.StatusCode;try{$stream=$wr.GetResponseStream();$memory=New-Object System.IO.MemoryStream;try{$stream.CopyTo($memory);$body=$memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()}}catch{};try{$wr.Dispose()}catch{}};if(($status-eq429-or$status-ge500)-and$attempt-lt$MaxAttempts){Start-Sleep -Seconds ([Math]::Min(30,5*$attempt));continue};return [pscustomobject]@{status_code=$status;bytes=$body;error=$message}}finally{if($null-ne$response){try{$response.Dispose()}catch{}}}}
    throw 'Unreachable GeckoTerminal request state.'
}
function Test-Seeds{
    param([object[]]$Seeds)
    if($Seeds.Count-ne2){throw("Expected exactly 2 XREP/REPV2 seeds; observed {0}."-f$Seeds.Count)};$roles=@{};$addresses=@{}
    foreach($seed in $Seeds){if(@('XREP','REPV2')-notcontains[string]$seed.base_asset_id){throw("Unsupported XREP seed base: {0}"-f[string]$seed.base_asset_id)};if([string]$seed.network_id-ne'eth'){throw 'XREP network_id must be eth.'};$address=[string]$seed.token_address;if($address-notmatch'^0x[0-9a-fA-F]{40}$'){throw("Invalid XREP token address: {0}"-f$address)};$key=$address.ToLowerInvariant();if($addresses.ContainsKey($key)){throw("Duplicate XREP token address: {0}"-f$address)};$addresses[$key]=$true;$role=[string]$seed.token_role;if(@('Q2_XREP_REPV1','Q2_REPV2')-notcontains$role){throw("Unsupported XREP token role: {0}"-f$role)};if($roles.ContainsKey($role)){throw("Duplicate XREP token role: {0}"-f$role)};$roles[$role]=$true;if([string]::IsNullOrWhiteSpace([string]$seed.source_url)-or[string]::IsNullOrWhiteSpace([string]$seed.seed_basis)){throw("Incomplete XREP seed metadata: {0}"-f$role)}}
    foreach($r in @('Q2_XREP_REPV1','Q2_REPV2')){if(-not$roles.ContainsKey($r)){throw("Missing XREP token role: {0}"-f$r)}}
}
function Get-RoleSignal{
    param([object[]]$Rows,[string]$Role)
    $roleRows=@($Rows|Where-Object{[string]$_.token_role-eq$Role});if($roleRows.Count-ne2){return [pscustomobject]@{status='FAIL_ENDPOINT_CARDINALITY';id=''}}
    if(@($roleRows|Where-Object{[int]$_.http_status-ne200-or[string]$_.parse_status-ne'PASS'}).Count-gt0){return [pscustomobject]@{status='UNVERIFIED_REQUEST_OR_PARSE';id=''}}
    $ids=@($roleRows|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_.coingecko_coin_id)}|ForEach-Object{[string]$_.coingecko_coin_id}|Select-Object -Unique)
    if($ids.Count-eq0){return [pscustomobject]@{status='UNVERIFIED_EMPTY_COINGECKO_ID';id=''}}
    if($ids.Count-ne1-or@($roleRows|Where-Object{[string]$_.coingecko_coin_id-ne$ids[0]}).Count-gt0){return [pscustomobject]@{status='FAIL_ENDPOINT_ID_DISAGREEMENT';id=($ids-join'|')}}
    return [pscustomobject]@{status='PASS_EXPLICIT_COINGECKO_ID';id=$ids[0]}
}
function Get-MappingSignal{
    param([object[]]$Rows)
    $v1=Get-RoleSignal $Rows 'Q2_XREP_REPV1';$v2=Get-RoleSignal $Rows 'Q2_REPV2'
    if($v1.status-like'FAIL_*'-or$v2.status-like'FAIL_*'){return [pscustomobject]@{status='FAIL_EVIDENCE_INCONSISTENCY';repv1_id=$v1.id;repv2_id=$v2.id}}
    if($v1.status-ne'PASS_EXPLICIT_COINGECKO_ID'){return [pscustomobject]@{status='UNVERIFIED_REPV1_NO_EXPLICIT_ID';repv1_id=$v1.id;repv2_id=$v2.id}}
    if($v2.status-eq'PASS_EXPLICIT_COINGECKO_ID' -and $v1.id.Equals($v2.id,[System.StringComparison]::Ordinal)){return [pscustomobject]@{status='UNVERIFIED_SAME_EXPLICIT_ID_CONFLICT';repv1_id=$v1.id;repv2_id=$v2.id}}
    return [pscustomobject]@{status='CANDIDATE_DISTINCT_REPV1_ID';repv1_id=$v1.id;repv2_id=$v2.id}
}
function Assert-Throws{param([scriptblock]$Script,[string]$Pattern);$caught=$false;try{&$Script}catch{$caught=$true;if($_.Exception.Message-notmatch$Pattern){throw("Unexpected failure. Expected /{0}/; observed: {1}"-f$Pattern,$_.Exception.Message)}};if(-not$caught){throw("Expected failure matching /{0}/ but call succeeded."-f$Pattern)}}
function Invoke-SelfTest{
    $seeds=@([pscustomobject]@{base_asset_id='XREP';network_id='eth';token_address='0x1985365e9f78359a9b6ad760e32412f4a445e862';token_role='Q2_XREP_REPV1';source_url='https://example.invalid/v1';seed_basis='v1'},[pscustomobject]@{base_asset_id='REPV2';network_id='eth';token_address='0x221657776846890989a759ba2973e427dff5c9bb';token_role='Q2_REPV2';source_url='https://example.invalid/v2';seed_basis='v2'});Test-Seeds $seeds
    $json='{"data":{"id":"eth_0xabc","type":"token","attributes":{"address":"0x0000000000000000000000000000000000000abc","name":"Reputation","symbol":"REP","coingecko_coin_id":"rep-v1-id"}}}';$bytes=(New-Object System.Text.UTF8Encoding($false)).GetBytes($json);$p=Convert-TokenResponse $bytes;if($p.coingecko_coin_id-ne'rep-v1-id'-or(Get-Sha256Bytes $bytes).Length-ne64){throw 'XREP response parser/hash self-test failed.'}
    $rows=@();foreach($endpoint in @('info','token_data')){$rows+=[pscustomobject]@{token_role='Q2_XREP_REPV1';http_status='200';parse_status='PASS';coingecko_coin_id='rep-v1-id'};$rows+=[pscustomobject]@{token_role='Q2_REPV2';http_status='200';parse_status='PASS';coingecko_coin_id='augur'}};$signal=Get-MappingSignal $rows;if($signal.status-ne'CANDIDATE_DISTINCT_REPV1_ID'){throw 'Distinct-ID signal self-test failed.'}
    $empty=@($rows|ForEach-Object{$copy=$_.PSObject.Copy();if($copy.token_role-eq'Q2_XREP_REPV1'){$copy.coingecko_coin_id=''};$copy});if((Get-MappingSignal $empty).status-ne'UNVERIFIED_REPV1_NO_EXPLICIT_ID'){throw 'Empty REPv1 ID self-test failed.'}
    $same=@($rows|ForEach-Object{$copy=$_.PSObject.Copy();$copy.coingecko_coin_id='augur';$copy});if((Get-MappingSignal $same).status-ne'UNVERIFIED_SAME_EXPLICIT_ID_CONFLICT'){throw 'Same-ID conflict self-test failed.'}
    Assert-Throws {Test-Seeds @($seeds[0],$seeds[0])} 'Duplicate XREP token address|Duplicate XREP token role';Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath;$seedPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-GeckoTerminal-Xrep-Seeds.csv';if(-not(Test-Path -LiteralPath $seedPath -PathType Leaf)){throw 'XREP GeckoTerminal seed registry missing.'};$seeds=@(Import-Csv -LiteralPath $seedPath);Test-Seeds $seeds
    $endpointSpecs=@([pscustomobject]@{name='token_info';suffix='/info'},[pscustomobject]@{name='token_data';suffix=''})
    $rows=@();$ordinal=0;$total=$seeds.Count*$endpointSpecs.Count
    foreach($seed in $seeds){foreach($endpoint in $endpointSpecs){$ordinal++;if($ordinal-gt1-and$DelayMs-gt0){Start-Sleep -Milliseconds $DelayMs};$network=[string]$seed.network_id;$address=[string]$seed.token_address;$url=$ApiRoot.TrimEnd('/')+'/networks/'+[Uri]::EscapeDataString($network)+'/tokens/'+[Uri]::EscapeDataString($address)+[string]$endpoint.suffix;Write-Host("GeckoTerminal XREP identity: {0}/{1} {2} {3} {4}"-f$ordinal,$total,[string]$seed.token_role,[string]$endpoint.name,$address);$result=Invoke-GeckoTerminalRequest $url;$sha='';$rid='';$returnedAddress='';$name='';$symbol='';$coinId='';$parseStatus='NOT_APPLICABLE';$parseError='';if($result.bytes.Length-gt0){$sha=Get-Sha256Bytes $result.bytes};if($result.status_code-eq200){try{$parsed=Convert-TokenResponse $result.bytes;$rid=$parsed.resource_id;$returnedAddress=$parsed.address;$name=$parsed.name;$symbol=$parsed.symbol;$coinId=$parsed.coingecko_coin_id;$parseStatus=if($returnedAddress.Equals($address,[System.StringComparison]::OrdinalIgnoreCase)){'PASS'}else{'FAIL_RETURNED_ADDRESS_MISMATCH'}}catch{$parseStatus='FAIL_PARSE';$parseError=$_.Exception.Message}};$errorText=[string]$result.error;if(-not[string]::IsNullOrWhiteSpace($parseError)){$errorText=if([string]::IsNullOrWhiteSpace($errorText)){$parseError}else{$errorText+' | '+$parseError}};$identityStatus=if($result.status_code-eq200-and$parseStatus-eq'PASS'-and-not[string]::IsNullOrWhiteSpace($coinId)){'PASS_EXPLICIT_COINGECKO_ID'}elseif($result.status_code-eq200-and$parseStatus-eq'PASS'){'UNVERIFIED_EMPTY_COINGECKO_ID'}else{'UNVERIFIED_REQUEST_OR_PARSE'};$rows+=[pscustomobject]@{base_asset_id=[string]$seed.base_asset_id;network_id=$network;token_address=$address;token_role=[string]$seed.token_role;endpoint_type=[string]$endpoint.name;http_status=[int]$result.status_code;response_sha256=$sha;response_bytes=[int64]$result.bytes.Length;parse_status=$parseStatus;resource_id=$rid;returned_address=$returnedAddress;returned_name=$name;returned_symbol=$symbol;coingecko_coin_id=$coinId;identity_status=$identityStatus;request_url=$url;source_url=[string]$seed.source_url;seed_basis=[string]$seed.seed_basis;error_message=$errorText}}}
    $csvPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-GeckoTerminal-Xrep-Evidence.csv';$rows|Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8;$signal=Get-MappingSignal $rows;$builder=New-Object System.Text.StringBuilder;[void]$builder.AppendLine('# CFA Stage 2 XREP GeckoTerminal Evidence');[void]$builder.AppendLine('');[void]$builder.AppendLine('- Evidence rows: '+$rows.Count);[void]$builder.AppendLine('- REPv1 explicit CoinGecko ID: '+$signal.repv1_id);[void]$builder.AppendLine('- REPv2 explicit CoinGecko ID: '+$signal.repv2_id);[void]$builder.AppendLine('- Mapping signal: '+$signal.status);[void]$builder.AppendLine('- Evidence CSV SHA-256: '+(Get-FileHash -LiteralPath $csvPath -Algorithm SHA256).Hash.ToLowerInvariant());[void]$builder.AppendLine('');[void]$builder.AppendLine('Source endpoints: GeckoTerminal public API v2 token-info and token-data endpoints using network id eth. A mapping approval requires separate adjudication; this receipt does not approve XREP.');Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-xrep-geckoterminal-evidence.md') $builder.ToString();Write-Host 'CFA STAGE 2 XREP GECKOTERMINAL EVIDENCE: COMPLETE';Write-Host('REPv1 CoinGecko ID: '+$signal.repv1_id);Write-Host('REPv2 CoinGecko ID: '+$signal.repv2_id);Write-Host('Mapping signal: '+$signal.status);if($signal.status-eq'FAIL_EVIDENCE_INCONSISTENCY'){exit 1};exit 0
}catch{Write-Host 'CFA STAGE 2 XREP GECKOTERMINAL EVIDENCE: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
