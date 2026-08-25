#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$OutputRoot = '',
    [ValidateRange(1,20)][int]$MaxHttpAttempts = 6,
    [ValidateRange(1,100)][int]$MaxTickerPages = 50,
    [ValidateRange(1000,15000)][int]$RequestDelayMilliseconds = 3000,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$ApiRoot = 'https://api.coingecko.com/api/v3'
$CoinsListUrl = $ApiRoot + '/coins/list?include_platform=true'
$KrakenTickersTemplate = $ApiRoot + '/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page={page}'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}

function Get-Sha256Text {
    param([AllowEmptyString()][string]$Text)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object {$_.ToString('x2')}) -join '') }
    finally { $sha.Dispose() }
}

function Invoke-CgGet {
    param([System.Net.Http.HttpClient]$Client,[string]$Url)
    for($attempt=1;$attempt -le $MaxHttpAttempts;$attempt++){
        $response=$null
        try {
            $response=$Client.GetAsync($Url).GetAwaiter().GetResult()
            $status=[int]$response.StatusCode
            $body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if($response.IsSuccessStatusCode){ return $body }
            if($status -eq 429 -or $status -ge 500){
                if($attempt -lt $MaxHttpAttempts){ Start-Sleep -Seconds ([Math]::Min(120,[Math]::Pow(2,$attempt))); continue }
            }
            throw "CoinGecko HTTP $status for $Url"
        }
        catch {
            if($attempt -ge $MaxHttpAttempts){ throw }
            Start-Sleep -Seconds ([Math]::Min(120,[Math]::Pow(2,$attempt)))
        }
        finally { if($null -ne $response){$response.Dispose()} }
    }
    throw "CoinGecko request exhausted retries: $Url"
}

function Get-StringProperty {
    param([object]$Object,[string]$Name)
    if($null -eq $Object){return ''}
    $p=$Object.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return ''}
    return [string]$p.Value
}

function Get-BoolProperty {
    param([object]$Object,[string]$Name)
    if($null -eq $Object){return $false}
    $p=$Object.PSObject.Properties[$Name]
    if($null -eq $p -or $null -eq $p.Value){return $false}
    return [bool]$p.Value
}

function Get-BridgeDecision {
    param([string[]]$CandidateIds,[object[]]$Tickers,[string]$BaseSymbol,[string[]]$QuoteSymbols)
    $bridgeCounts=@{}
    foreach($id in $CandidateIds){$bridgeCounts[$id]=0}
    foreach($t in $Tickers){
        $coinId=Get-StringProperty $t 'coin_id'
        if(-not $bridgeCounts.ContainsKey($coinId)){continue}
        $market=$t.PSObject.Properties['market']
        $marketId=''
        if($null -ne $market -and $null -ne $market.Value){$marketId=Get-StringProperty $market.Value 'identifier'}
        if($marketId -ne 'kraken'){continue}
        if((Get-BoolProperty $t 'is_anomaly')){continue}
        if((Get-BoolProperty $t 'is_stale')){continue}
        $base=Get-StringProperty $t 'base'
        $target=Get-StringProperty $t 'target'
        if(-not $base.Equals($BaseSymbol,[StringComparison]::OrdinalIgnoreCase)){continue}
        $quoteMatch=$false
        foreach($q in $QuoteSymbols){if($target.Equals($q,[StringComparison]::OrdinalIgnoreCase)){$quoteMatch=$true;break}}
        if(-not $quoteMatch){continue}
        $bridgeCounts[$coinId]=[int]$bridgeCounts[$coinId]+1
    }
    $bridged=@($bridgeCounts.Keys | Where-Object {[int]$bridgeCounts[$_] -gt 0} | Sort-Object)
    $decision='UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE';$approved=''
    if($bridged.Count -eq 1){$decision='APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE';$approved=$bridged[0]}
    elseif($bridged.Count -gt 1){$decision='UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES'}
    return [pscustomobject]@{decision=$decision;approved_candidate_id=$approved;bridged_candidate_ids=($bridged -join '|');bridge_counts=$bridgeCounts}
}

function Invoke-SelfTest {
    $ticker=[pscustomobject]@{base='ABC';target='USD';coin_id='coin-a';is_anomaly=$false;is_stale=$false;market=[pscustomobject]@{identifier='kraken'}}
    $r=Get-BridgeDecision -CandidateIds @('coin-a','coin-b') -Tickers @($ticker) -BaseSymbol 'ABC' -QuoteSymbols @('USD')
    if($r.decision -ne 'APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE' -or $r.approved_candidate_id -ne 'coin-a'){throw 'bridge decision'}
    $ticker2=[pscustomobject]@{base='ABC';target='USD';coin_id='coin-b';is_anomaly=$false;is_stale=$false;market=[pscustomobject]@{identifier='kraken'}}
    $r2=Get-BridgeDecision -CandidateIds @('coin-a','coin-b') -Tickers @($ticker,$ticker2) -BaseSymbol 'ABC' -QuoteSymbols @('USD')
    if($r2.decision -ne 'UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES'){throw 'ambiguous bridge'}
    $stale=[pscustomobject]@{base='ABC';target='USD';coin_id='coin-a';is_anomaly=$false;is_stale=$true;market=[pscustomobject]@{identifier='kraken'}}
    $r3=Get-BridgeDecision -CandidateIds @('coin-a') -Tickers @($stale) -BaseSymbol 'ABC' -QuoteSymbols @('USD')
    if($r3.decision -ne 'UNVERIFIED_NO_CURRENT_KRAKEN_PAIR_BRIDGE'){throw 'stale ticker exclusion'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

$client=$null
try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'CFA-local\coingecko-identity'}
    if(-not (Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $runId=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N')
    $runDir=Join-Path $OutputRoot $runId;New-Item -ItemType Directory -Path $runDir -Force|Out-Null

    $pairPath=Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv'
    $candidatePath=Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv'
    $pairs=@(Import-Csv -LiteralPath $pairPath | Where-Object {([string]$_.research_eligible).ToLowerInvariant() -eq 'true'})
    $candidates=@(Import-Csv -LiteralPath $candidatePath)

    $pairByBase=@{}
    foreach($p in $pairs){
        $id=[string]$p.base_asset_id
        if(-not $pairByBase.ContainsKey($id)){$pairByBase[$id]=[pscustomobject]@{base_symbols=@{};quote_symbols=@{}}}
        $pairByBase[$id].base_symbols[[string]$p.base_exchange_symbol]=$true
        $pairByBase[$id].quote_symbols[[string]$p.quote_exchange_symbol]=$true
    }

    $handler=New-Object System.Net.Http.HttpClientHandler
    $client=New-Object System.Net.Http.HttpClient -ArgumentList $handler
    $client.Timeout=[TimeSpan]::FromSeconds(120)
    [void]$client.DefaultRequestHeaders.UserAgent.ParseAdd('CFA-identity-evidence/1.0')

    Write-Host 'CoinGecko API mode: keyless public (no account/API key)'
    Write-Host 'Acquiring CoinGecko active coins list...'
    $coinsJson=Invoke-CgGet -Client $client -Url $CoinsListUrl
    $coinsPath=Join-Path $runDir 'coins-list.json';Write-Utf8NoBom $coinsPath $coinsJson
    $coins=@($coinsJson|ConvertFrom-Json)
    $coinById=@{}
    foreach($coin in $coins){$id=Get-StringProperty $coin 'id';if(-not [string]::IsNullOrWhiteSpace($id)){$coinById[$id]=$coin}}
    Start-Sleep -Milliseconds $RequestDelayMilliseconds

    $allTickers=@();$pageFiles=@();$page=1
    while($page -le $MaxTickerPages){
        $url=$KrakenTickersTemplate.Replace('{page}',[string]$page)
        Write-Host "Acquiring CoinGecko Kraken tickers page $page..."
        $json=Invoke-CgGet -Client $client -Url $url
        $path=Join-Path $runDir ('kraken-tickers-page-{0:D3}.json' -f $page);Write-Utf8NoBom $path $json
        $obj=$json|ConvertFrom-Json;$tickers=@($obj.tickers)
        $pageFiles += $path;$allTickers += $tickers
        if($tickers.Count -lt 100){break}
        $page++;Start-Sleep -Milliseconds $RequestDelayMilliseconds
    }
    if($page -gt $MaxTickerPages){throw 'Ticker pagination exceeded MaxTickerPages without terminal short page.'}

    $evidence=@();$approve=0;$multi=0;$noBridge=0
    foreach($c in $candidates){
        $baseId=[string]$c.base_asset_id
        $candidateIds=@();if(-not [string]::IsNullOrWhiteSpace([string]$c.current_candidate_ids)){$candidateIds=@(([string]$c.current_candidate_ids)-split '\|')}
        $active=@($candidateIds|Where-Object {$coinById.ContainsKey($_)}|Sort-Object)
        $baseSymbols=@();$quotes=@();if($pairByBase.ContainsKey($baseId)){$baseSymbols=@($pairByBase[$baseId].base_symbols.Keys|Sort-Object);$quotes=@($pairByBase[$baseId].quote_symbols.Keys|Sort-Object)}
        $baseSymbol=if($baseSymbols.Count -eq 1){$baseSymbols[0]}else{''}
        $bridge=Get-BridgeDecision -CandidateIds $candidateIds -Tickers $allTickers -BaseSymbol $baseSymbol -QuoteSymbols $quotes
        if($bridge.decision -eq 'APPROVE_CURRENT_KRAKEN_PAIR_BRIDGE'){$approve++}elseif($bridge.decision -eq 'UNVERIFIED_MULTIPLE_KRAKEN_PAIR_BRIDGES'){$multi++}else{$noBridge++}
        $countParts=@();foreach($id in $candidateIds){$countParts += ($id+':'+[string][int]$bridge.bridge_counts[$id])}
        $evidence += [pscustomobject]@{
            base_asset_id=$baseId;base_exchange_symbol=[string]$c.base_exchange_symbol;quote_exchange_symbols=($quotes -join '|');
            candidate_count=[int]$c.current_candidate_count;candidate_ids=($candidateIds -join '|');active_candidate_ids=($active -join '|');
            kraken_pair_bridge_candidate_ids=$bridge.bridged_candidate_ids;kraken_pair_bridge_counts=($countParts -join '|');
            cfa_independent_review_decision=$bridge.decision;approved_candidate_id=$bridge.approved_candidate_id
        }
    }
    $evidence|Sort-Object base_asset_id|Export-Csv -LiteralPath (Join-Path $runDir 'mapping-bridge-evidence.csv') -NoTypeInformation -Encoding UTF8

    $sourceRows=@();$sourceRows += [pscustomobject]@{file_name='coins-list.json';sha256=(Get-FileHash $coinsPath -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item $coinsPath).Length;record_count=$coins.Count;source_url=$CoinsListUrl}
    foreach($pf in $pageFiles){$pageNo=[int]([regex]::Match([System.IO.Path]::GetFileName($pf),'(\d{3})').Groups[1].Value);$json=[System.IO.File]::ReadAllText($pf);$o=$json|ConvertFrom-Json;$sourceRows += [pscustomobject]@{file_name=[System.IO.Path]::GetFileName($pf);sha256=(Get-FileHash $pf -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item $pf).Length;record_count=@($o.tickers).Count;source_url=$KrakenTickersTemplate.Replace('{page}',[string]$pageNo)}}
    $sourceRows|Export-Csv -LiteralPath (Join-Path $runDir 'source-files.csv') -NoTypeInformation -Encoding UTF8
    @([pscustomobject]@{run_id=$runId;api_tier='keyless_public';authentication='none';coins_list_records=$coins.Count;kraken_ticker_records=$allTickers.Count;ticker_pages=$pageFiles.Count;approved_current_kraken_pair_bridge=$approve;unverified_multiple_bridges=$multi;unverified_no_bridge=$noBridge;candidate_assets=$candidates.Count;retrieved_at_utc=[datetimeoffset]::UtcNow.ToString('o')}) | Export-Csv -LiteralPath (Join-Path $runDir 'run-summary.csv') -NoTypeInformation -Encoding UTF8
    Write-Host "Evidence directory: $runDir"
    Write-Host "Candidate assets: $($candidates.Count)"
    Write-Host "Kraken ticker records: $($allTickers.Count)"
    Write-Host "Unique current Kraken pair bridges: $approve"
    Write-Host "Multiple current bridges: $multi"
    Write-Host "No current bridge: $noBridge"
    Write-Host 'CFA COINGECKO IDENTITY EVIDENCE ACQUISITION: PASS'
}
catch{Write-Host 'CFA COINGECKO IDENTITY EVIDENCE ACQUISITION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
finally{if($null -ne $client){$client.Dispose()}}
