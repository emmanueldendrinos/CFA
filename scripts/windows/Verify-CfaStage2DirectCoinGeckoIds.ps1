#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [string]$ApiRoot='https://api.coingecko.com/api/v3',
    [ValidateRange(1000,30000)][int]$DelayMs=6000,
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Get-Sha256Bytes{param([byte[]]$Bytes);$s=[System.Security.Cryptography.SHA256]::Create();try{return(($s.ComputeHash($Bytes)|ForEach-Object{$_.ToString('x2')})-join'')}finally{$s.Dispose()}}
function Get-PropertyValue{
 param([object]$Object,[string]$PropertyName)
 if($null-eq$Object){return $null}
 if($Object-is[System.Collections.IDictionary]){
   foreach($key in @($Object.Keys)){
     if(([string]$key).Equals($PropertyName,[System.StringComparison]::Ordinal)){return $Object[$key]}
   }
   return $null
 }
 foreach($property in @($Object.PSObject.Properties)){
   if(([string]$property.Name).Equals($PropertyName,[System.StringComparison]::Ordinal)){return $property.Value}
 }
 return $null
}
function Convert-CfaJsonObject{
 param([string]$Json)
 try{return($Json|ConvertFrom-Json)}
 catch{
   $primaryError=$_.Exception.Message
   try{
     Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop|Out-Null
     $serializer=New-Object System.Web.Script.Serialization.JavaScriptSerializer
     $serializer.MaxJsonLength=67108864
     return $serializer.DeserializeObject($Json)
   }catch{
     throw ("CoinGecko JSON parse failed. ConvertFrom-Json: {0}; JavaScriptSerializer: {1}"-f$primaryError,$_.Exception.Message)
   }
 }
}
function Convert-Response{
 param([byte[]]$Bytes,[string]$ExpectedId)
 $json=(New-Object System.Text.UTF8Encoding($false,$true)).GetString($Bytes)
 $o=Convert-CfaJsonObject $json
 $idValue=Get-PropertyValue $o 'id';$nameValue=Get-PropertyValue $o 'name';$symbolValue=Get-PropertyValue $o 'symbol'
 if([string]::IsNullOrWhiteSpace([string]$idValue)){throw "CoinGecko response missing id for $ExpectedId"}
 if([string]::IsNullOrWhiteSpace([string]$nameValue)){throw "CoinGecko response missing name for $ExpectedId"}
 if([string]::IsNullOrWhiteSpace([string]$symbolValue)){throw "CoinGecko response missing symbol for $ExpectedId"}
 $homepageValue='';$links=Get-PropertyValue $o 'links';$homepages=@(Get-PropertyValue $links 'homepage');foreach($h in $homepages){if(-not[string]::IsNullOrWhiteSpace([string]$h)){$homepageValue=[string]$h;break}}
 $platform=[string](Get-PropertyValue $o 'asset_platform_id');$contract=[string](Get-PropertyValue $o 'contract_address')
 return [pscustomobject]@{id=[string]$idValue;name=[string]$nameValue;symbol=[string]$symbolValue;asset_platform_id=$platform;contract_address=$contract;homepage=$homepageValue}
}
function Invoke-CoinRequest{
 param([string]$Url,[int]$MaxAttempts=4)
 for($attempt=1;$attempt-le$MaxAttempts;$attempt++){
   $req=$null;$resp=$null
   try{
     $req=[System.Net.HttpWebRequest]::Create($Url);$req.Method='GET';$req.UserAgent='CFA-stage2-direct-coingecko-id-evidence/1.2';$req.Timeout=45000;$req.ReadWriteTimeout=45000
     $resp=[System.Net.HttpWebResponse]$req.GetResponse();$stream=$resp.GetResponseStream();$ms=New-Object System.IO.MemoryStream
     try{$stream.CopyTo($ms);$bytes=$ms.ToArray()}finally{$ms.Dispose();$stream.Dispose()}
     return [pscustomobject]@{status_code=[int]$resp.StatusCode;bytes=$bytes;error=''}
   }catch [System.Net.WebException]{
     $status=0;$body=[byte[]]@();$err=$_.Exception.Message
     if($null-ne$_.Exception.Response){$wr=[System.Net.HttpWebResponse]$_.Exception.Response;$status=[int]$wr.StatusCode;try{$s=$wr.GetResponseStream();$m=New-Object System.IO.MemoryStream;try{$s.CopyTo($m);$body=$m.ToArray()}finally{$m.Dispose();$s.Dispose()}}catch{};try{$wr.Dispose()}catch{}}
     if(($status-eq429-or$status-ge500)-and$attempt-lt$MaxAttempts){Start-Sleep -Seconds ([Math]::Min(30,5*$attempt));continue}
     return [pscustomobject]@{status_code=$status;bytes=$body;error=$err}
   }finally{if($null-ne$resp){try{$resp.Dispose()}catch{}}}
 }
 throw 'unreachable'
}
function Invoke-SelfTest{
 $b=(New-Object System.Text.UTF8Encoding($false)).GetBytes('{"id":"x","name":"Asset X","symbol":"xx","asset_platform_id":"ethereum","contract_address":"0x1","links":{"homepage":["https://x.example"]}}')
 $r=Convert-Response $b 'x';if($r.id-ne'x'-or$r.name-ne'Asset X'-or$r.symbol-ne'xx'-or$r.homepage-ne'https://x.example'){throw 'response parser'}
 $minimal=(New-Object System.Text.UTF8Encoding($false)).GetBytes('{"id":"y","name":"Asset Y","symbol":"yy","links":null}')
 $m=Convert-Response $minimal 'y';if($m.id-ne'y'-or$m.homepage-ne''){throw 'minimal response parser'}
 $emptyKey=(New-Object System.Text.UTF8Encoding($false)).GetBytes('{"id":"z","name":"Asset Z","symbol":"zz","links":{"homepage":["https://z.example"]},"detail_platforms":{"":{"decimal_place":6}}}')
 $z=Convert-Response $emptyKey 'z';if($z.id-ne'z'-or$z.name-ne'Asset Z'-or$z.symbol-ne'zz'-or$z.homepage-ne'https://z.example'){throw 'empty-key response parser'}
 if((Get-Sha256Bytes $b).Length-ne64){throw 'sha256'}
 Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
 if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
 $seedPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Direct-CoinGecko-ID-Seeds.csv';$decisionPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv'
 $seeds=@(Import-Csv -LiteralPath $seedPath);if($seeds.Count-le0){throw 'Direct CoinGecko ID seed set is empty.'}
 $decisions=@(Import-Csv -LiteralPath $decisionPath);$byBase=@{};foreach($d in $decisions){$byBase[[string]$d.base_asset_id]=$d}
 foreach($s in $seeds){$b=[string]$s.base_asset_id;if(-not$byBase.ContainsKey($b)){throw "Seed base missing from mapping decisions: $b"};if([string]$byBase[$b].mapping_status-ne'UNVERIFIED'){throw "Direct-ID seed base no longer UNVERIFIED: $b"}}
 $rows=@();$ordinal=0
 foreach($s in $seeds){
   $ordinal++;if($ordinal-gt1){Start-Sleep -Milliseconds $DelayMs}
   $id=[string]$s.candidate_id;$url=$ApiRoot.TrimEnd('/')+'/coins/'+[Uri]::EscapeDataString($id)+'?localization=false&tickers=false&market_data=false&community_data=false&developer_data=false&sparkline=false'
   Write-Host ("Direct CoinGecko ID: {0}/{1} {2}/{3}"-f$ordinal,$seeds.Count,[string]$s.base_asset_id,$id)
   $r=Invoke-CoinRequest $url;$sha='';$name='';$symbol='';$returnedId='';$platform='';$contract='';$homepageValue='';$parseStatus='NOT_APPLICABLE';$parseError=''
   if($r.bytes.Length-gt0){$sha=Get-Sha256Bytes $r.bytes}
   if($r.status_code-eq200){
     try{$o=Convert-Response $r.bytes $id;$returnedId=$o.id;$name=$o.name;$symbol=$o.symbol;$platform=$o.asset_platform_id;$contract=$o.contract_address;$homepageValue=$o.homepage;$parseStatus=if($returnedId-eq$id){'PASS'}else{'FAIL_RETURNED_ID_MISMATCH'}}
     catch{$parseStatus='FAIL_PARSE';$parseError=$_.Exception.Message}
   }
   $errorText=[string]$r.error;if(-not[string]::IsNullOrWhiteSpace($parseError)){$errorText=if([string]::IsNullOrWhiteSpace($errorText)){$parseError}else{$errorText+' | '+$parseError}}
   $rows+=[pscustomobject]@{base_asset_id=[string]$s.base_asset_id;requested_candidate_id=$id;http_status=$r.status_code;response_sha256=$sha;response_bytes=$r.bytes.Length;parse_status=$parseStatus;returned_id=$returnedId;returned_name=$name;returned_symbol=$symbol;asset_platform_id=$platform;contract_address=$contract;homepage=$homepageValue;seed_basis=[string]$s.seed_basis;request_url=$url;error_message=$errorText}
 }
 $csv=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Direct-CoinGecko-ID-Evidence.csv';$rows|Sort-Object base_asset_id,requested_candidate_id|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
 $ok=@($rows|Where-Object{$_.http_status-eq200-and$_.parse_status-eq'PASS'}).Count;$notFound=@($rows|Where-Object{$_.http_status-eq404}).Count;$parseFailures=@($rows|Where-Object{$_.http_status-eq200-and$_.parse_status-ne'PASS'}).Count;$other=@($rows|Where-Object{$_.http_status-ne200-and$_.http_status-ne404}).Count
 $b=New-Object System.Text.StringBuilder;[void]$b.AppendLine('# CFA Stage 2 Direct CoinGecko ID Evidence');[void]$b.AppendLine('');[void]$b.AppendLine('- Seed rows: '+$seeds.Count);[void]$b.AppendLine('- HTTP 200 + returned-id PASS: '+$ok);[void]$b.AppendLine('- HTTP 404: '+$notFound);[void]$b.AppendLine('- HTTP 200 parse/nonmatching failures: '+$parseFailures);[void]$b.AppendLine('- Other HTTP failures: '+$other);[void]$b.AppendLine('');[void]$b.AppendLine('Each seed is verified directly against the keyless CoinGecko `/coins/{id}` endpoint. Response bytes are not committed; SHA-256 and bounded identity fields are published. 404s, parse anomalies, and other source failures remain explicit UNVERIFIED evidence and are not converted into mapping decisions.');[void]$b.AppendLine('');[void]$b.AppendLine('Evidence table: `candidate-analysis/CFA-Stage2-Direct-CoinGecko-ID-Evidence.csv`.');Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-direct-coingecko-id-evidence.md') $b.ToString()
 Write-Host ('Seed rows: '+$seeds.Count);Write-Host ('Verified direct IDs: '+$ok);Write-Host ('HTTP 404: '+$notFound);Write-Host ('Parse/nonmatching failures: '+$parseFailures);Write-Host ('Other HTTP failures: '+$other);Write-Host 'CFA STAGE 2 DIRECT COINGECKO ID EVIDENCE: PASS'
 if($other-gt0-or$parseFailures-gt0){exit 2}
}catch{Write-Host 'CFA STAGE 2 DIRECT COINGECKO ID EVIDENCE: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
