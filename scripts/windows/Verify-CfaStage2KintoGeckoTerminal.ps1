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

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $encoding=New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$encoding)
}
function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try{return(($sha.ComputeHash($Bytes)|ForEach-Object{$_.ToString('x2')})-join'')}finally{$sha.Dispose()}
}
function Get-PropertyValue {
    param([object]$Object,[string]$PropertyName)
    if($null-eq$Object){return $null}
    if($Object-is[System.Collections.IDictionary]){
        foreach($key in @($Object.Keys)){if(([string]$key).Equals($PropertyName,[System.StringComparison]::Ordinal)){return $Object[$key]}}
        return $null
    }
    foreach($property in @($Object.PSObject.Properties)){if(([string]$property.Name).Equals($PropertyName,[System.StringComparison]::Ordinal)){return $property.Value}}
    return $null
}
function Convert-CfaJsonObject {
    param([string]$Json)
    try{return($Json|ConvertFrom-Json)}
    catch{
        $primary=$_.Exception.Message
        try{
            Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop|Out-Null
            $serializer=New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength=67108864
            return $serializer.DeserializeObject($Json)
        }catch{throw("GeckoTerminal JSON parse failed. ConvertFrom-Json: {0}; JavaScriptSerializer: {1}"-f$primary,$_.Exception.Message)}
    }
}
function Convert-TokenInfoResponse {
    param([byte[]]$Bytes)
    $json=(New-Object System.Text.UTF8Encoding($false,$true)).GetString($Bytes)
    $root=Convert-CfaJsonObject $json
    $data=Get-PropertyValue $root 'data'
    if($null-eq$data){throw 'GeckoTerminal response missing data object.'}
    $type=[string](Get-PropertyValue $data 'type')
    if($type-ne'token'){throw("GeckoTerminal response type is not token: {0}"-f$type)}
    $attributes=Get-PropertyValue $data 'attributes'
    if($null-eq$attributes){throw 'GeckoTerminal response missing attributes object.'}
    $address=[string](Get-PropertyValue $attributes 'address')
    $name=[string](Get-PropertyValue $attributes 'name')
    $symbol=[string](Get-PropertyValue $attributes 'symbol')
    if([string]::IsNullOrWhiteSpace($address)){throw 'GeckoTerminal token info missing address.'}
    if([string]::IsNullOrWhiteSpace($name)){throw 'GeckoTerminal token info missing name.'}
    if([string]::IsNullOrWhiteSpace($symbol)){throw 'GeckoTerminal token info missing symbol.'}
    $coinIdValue=Get-PropertyValue $attributes 'coingecko_coin_id'
    $coinId=if($null-eq$coinIdValue){''}else{[string]$coinIdValue}
    return [pscustomobject]@{
        resource_id=[string](Get-PropertyValue $data 'id')
        address=$address
        name=$name
        symbol=$symbol
        coingecko_coin_id=$coinId
    }
}
function Invoke-GeckoTerminalRequest {
    param([string]$Url,[int]$MaxAttempts=4)
    for($attempt=1;$attempt-le$MaxAttempts;$attempt++){
        $request=$null;$response=$null
        try{
            $request=[System.Net.HttpWebRequest]::Create($Url)
            $request.Method='GET'
            $request.UserAgent='CFA-stage2-kinto-geckoterminal-evidence/1.0'
            $request.Accept='application/json;version=20230203'
            $request.Timeout=45000
            $request.ReadWriteTimeout=45000
            $response=[System.Net.HttpWebResponse]$request.GetResponse()
            $stream=$response.GetResponseStream();$memory=New-Object System.IO.MemoryStream
            try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()}
            return [pscustomobject]@{status_code=[int]$response.StatusCode;bytes=$bytes;error=''}
        }catch [System.Net.WebException]{
            $status=0;$body=[byte[]]@();$message=$_.Exception.Message
            if($null-ne$_.Exception.Response){
                $webResponse=[System.Net.HttpWebResponse]$_.Exception.Response
                $status=[int]$webResponse.StatusCode
                try{$stream=$webResponse.GetResponseStream();$memory=New-Object System.IO.MemoryStream;try{$stream.CopyTo($memory);$body=$memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()}}catch{}
                try{$webResponse.Dispose()}catch{}
            }
            if(($status-eq429-or$status-ge500)-and$attempt-lt$MaxAttempts){Start-Sleep -Seconds ([Math]::Min(30,5*$attempt));continue}
            return [pscustomobject]@{status_code=$status;bytes=$body;error=$message}
        }finally{if($null-ne$response){try{$response.Dispose()}catch{}}}
    }
    throw 'Unreachable GeckoTerminal request state.'
}
function Test-Seeds {
    param([object[]]$Seeds)
    if($Seeds.Count-ne2){throw("Expected exactly 2 Kinto GeckoTerminal seeds; observed {0}."-f$Seeds.Count)}
    $roles=@{};$addresses=@{}
    foreach($seed in $Seeds){
        if([string]$seed.base_asset_id-ne'K'){throw 'Kinto GeckoTerminal seed base_asset_id must be K.'}
        if([string]$seed.network_id-ne'arbitrum'){throw 'Kinto GeckoTerminal network_id must be arbitrum.'}
        $address=[string]$seed.token_address
        if($address-notmatch'^0x[0-9a-fA-F]{40}$'){throw("Invalid Kinto token address: {0}"-f$address)}
        if($addresses.ContainsKey($address.ToLowerInvariant())){throw("Duplicate Kinto token address: {0}"-f$address)}
        $addresses[$address.ToLowerInvariant()]=$true
        $role=[string]$seed.temporal_role
        if(@('Q2_2025_ACTIVE_CONTRACT','POST_Q2_MIGRATED_CONTRACT')-notcontains$role){throw("Unsupported Kinto temporal role: {0}"-f$role)}
        if($roles.ContainsKey($role)){throw("Duplicate Kinto temporal role: {0}"-f$role)}
        $roles[$role]=$true
        if([string]::IsNullOrWhiteSpace([string]$seed.seed_basis)){throw("Kinto seed basis is empty: {0}"-f$role)}
    }
    foreach($required in @('Q2_2025_ACTIVE_CONTRACT','POST_Q2_MIGRATED_CONTRACT')){if(-not$roles.ContainsKey($required)){throw("Missing Kinto temporal role: {0}"-f$required)}}
}
function Assert-Throws {
    param([scriptblock]$Script,[string]$Pattern)
    $caught=$false
    try{&$Script}catch{$caught=$true;if($_.Exception.Message-notmatch$Pattern){throw("Unexpected failure. Expected /{0}/; observed: {1}"-f$Pattern,$_.Exception.Message)}}
    if(-not$caught){throw("Expected failure matching /{0}/ but call succeeded."-f$Pattern)}
}
function Invoke-SelfTest {
    $json='{"data":{"id":"arbitrum_0xabc","type":"token","attributes":{"address":"0x0000000000000000000000000000000000000abc","name":"Kinto","symbol":"K","coingecko_coin_id":"kinto-stable-id"}}}'
    $bytes=(New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $parsed=Convert-TokenInfoResponse $bytes
    if($parsed.name-ne'Kinto'-or$parsed.symbol-ne'K'-or$parsed.coingecko_coin_id-ne'kinto-stable-id'){throw 'Kinto GeckoTerminal response parser failed.'}
    $nullJson='{"data":{"id":"arbitrum_0xabc","type":"token","attributes":{"address":"0x0000000000000000000000000000000000000abc","name":"Kinto","symbol":"K","coingecko_coin_id":null}}}'
    $nullParsed=Convert-TokenInfoResponse ((New-Object System.Text.UTF8Encoding($false)).GetBytes($nullJson))
    if(-not[string]::IsNullOrWhiteSpace($nullParsed.coingecko_coin_id)){throw 'Null CoinGecko ID must remain empty.'}
    if((Get-Sha256Bytes $bytes).Length-ne64){throw 'SHA-256 calculation failed.'}
    $seeds=@(
        [pscustomobject]@{base_asset_id='K';network_id='arbitrum';token_address='0x010700ab046dd8e92b0e3587842080df36364ed3';temporal_role='Q2_2025_ACTIVE_CONTRACT';seed_basis='old'},
        [pscustomobject]@{base_asset_id='K';network_id='arbitrum';token_address='0x6ba19ee69d5dde3ab70185c801fa404f66fedb58';temporal_role='POST_Q2_MIGRATED_CONTRACT';seed_basis='new'}
    )
    Test-Seeds $seeds
    Assert-Throws {Test-Seeds @($seeds[0],$seeds[0])} 'Duplicate Kinto token address|Duplicate Kinto temporal role'
    Assert-Throws {Convert-TokenInfoResponse ((New-Object System.Text.UTF8Encoding($false)).GetBytes('{"data":{"type":"pool","attributes":{}}}'))} 'not token'
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $seedPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-GeckoTerminal-Kinto-Seeds.csv'
    if(-not(Test-Path -LiteralPath $seedPath -PathType Leaf)){throw 'Kinto GeckoTerminal seed registry missing.'}
    $seeds=@(Import-Csv -LiteralPath $seedPath);Test-Seeds $seeds
    $rows=@();$ordinal=0
    foreach($seed in $seeds){
        $ordinal++;if($ordinal-gt1-and$DelayMs-gt0){Start-Sleep -Milliseconds $DelayMs}
        $network=[string]$seed.network_id;$address=[string]$seed.token_address
        $url=$ApiRoot.TrimEnd('/')+'/networks/'+[Uri]::EscapeDataString($network)+'/tokens/'+[Uri]::EscapeDataString($address)+'/info'
        Write-Host ("GeckoTerminal Kinto token info: {0}/{1} {2} {3}"-f$ordinal,$seeds.Count,[string]$seed.temporal_role,$address)
        $result=Invoke-GeckoTerminalRequest $url
        $sha='';$resourceId='';$returnedAddress='';$name='';$symbol='';$coinId='';$parseStatus='NOT_APPLICABLE';$parseError=''
        if($result.bytes.Length-gt0){$sha=Get-Sha256Bytes $result.bytes}
        if($result.status_code-eq200){
            try{
                $parsed=Convert-TokenInfoResponse $result.bytes
                $resourceId=$parsed.resource_id;$returnedAddress=$parsed.address;$name=$parsed.name;$symbol=$parsed.symbol;$coinId=$parsed.coingecko_coin_id
                if(-not$returnedAddress.Equals($address,[System.StringComparison]::OrdinalIgnoreCase)){$parseStatus='FAIL_RETURNED_ADDRESS_MISMATCH'}else{$parseStatus='PASS'}
            }catch{$parseStatus='FAIL_PARSE';$parseError=$_.Exception.Message}
        }
        $errorText=[string]$result.error
        if(-not[string]::IsNullOrWhiteSpace($parseError)){$errorText=if([string]::IsNullOrWhiteSpace($errorText)){$parseError}else{$errorText+' | '+$parseError}}
        $identityStatus=if($result.status_code-eq200-and$parseStatus-eq'PASS'-and-not[string]::IsNullOrWhiteSpace($coinId)){'PASS_EXPLICIT_COINGECKO_ID'}elseif($result.status_code-eq200-and$parseStatus-eq'PASS'){'UNVERIFIED_EMPTY_COINGECKO_ID'}else{'UNVERIFIED_REQUEST_OR_PARSE'}
        $rows+=[pscustomobject]@{
            base_asset_id=[string]$seed.base_asset_id
            network_id=$network
            token_address=$address
            temporal_role=[string]$seed.temporal_role
            http_status=[int]$result.status_code
            response_sha256=$sha
            response_bytes=[int64]$result.bytes.Length
            parse_status=$parseStatus
            resource_id=$resourceId
            returned_address=$returnedAddress
            returned_name=$name
            returned_symbol=$symbol
            coingecko_coin_id=$coinId
            identity_status=$identityStatus
            request_url=$url
            seed_basis=[string]$seed.seed_basis
            error_message=$errorText
        }
    }
    $csvPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-GeckoTerminal-Kinto-Evidence.csv'
    $rows|Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $q2=@($rows|Where-Object{[string]$_.temporal_role-eq'Q2_2025_ACTIVE_CONTRACT'})
    if($q2.Count-ne1){throw 'Expected exactly one Q2 Kinto evidence row.'}
    $q2Status=if([string]$q2[0].identity_status-eq'PASS_EXPLICIT_COINGECKO_ID'){'PASS'}else{'UNVERIFIED'}
    $allIds=@($rows|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_.coingecko_coin_id)}|ForEach-Object{[string]$_.coingecko_coin_id}|Select-Object -Unique)
    $continuity=if($allIds.Count-eq1-and@($rows|Where-Object{[string]$_.identity_status-eq'PASS_EXPLICIT_COINGECKO_ID'}).Count-eq2){'PASS_SAME_EXPLICIT_ID'}elseif($allIds.Count-gt1){'FAIL_DIFFERENT_EXPLICIT_IDS'}else{'UNVERIFIED'}
    $builder=New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# CFA Stage 2 Kinto GeckoTerminal Evidence')
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('- Seed rows: '+$rows.Count)
    [void]$builder.AppendLine('- Q2 active-contract explicit CoinGecko ID gate: '+$q2Status)
    [void]$builder.AppendLine('- Old/new contract CoinGecko-ID continuity: '+$continuity)
    [void]$builder.AppendLine('- Q2 coingecko_coin_id: '+[string]$q2[0].coingecko_coin_id)
    [void]$builder.AppendLine('- Evidence CSV SHA-256: '+(Get-FileHash -LiteralPath $csvPath -Algorithm SHA256).Hash.ToLowerInvariant())
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('Source endpoint: GeckoTerminal public API v2 /networks/{network}/tokens/{address}/info using Accept application/json;version=20230203. Mapping approval is not implied by this acquisition receipt.')
    Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-kinto-geckoterminal-evidence.md') $builder.ToString()
    Write-Host 'CFA STAGE 2 KINTO GECKOTERMINAL EVIDENCE: COMPLETE'
    Write-Host ('Q2 explicit CoinGecko ID gate: '+$q2Status)
    Write-Host ('Contract continuity: '+$continuity)
    Write-Host ('Q2 CoinGecko ID: '+[string]$q2[0].coingecko_coin_id)
    if($continuity-eq'FAIL_DIFFERENT_EXPLICIT_IDS'){exit 1}
    exit 0
}catch{Write-Host 'CFA STAGE 2 KINTO GECKOTERMINAL EVIDENCE: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
