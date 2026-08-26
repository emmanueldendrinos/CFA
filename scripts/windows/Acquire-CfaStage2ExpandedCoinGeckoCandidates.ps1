#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ApiRoot = 'https://api.coingecko.com/api/v3',
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    $enc=New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path,$Content,$enc)
}
function Split-Pipe {
    param([string]$Text)
    if([string]::IsNullOrWhiteSpace($Text)){return @()}
    return @($Text-split'\|'|ForEach-Object{$_.Trim()}|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
}
function Get-Sha256Bytes {
    param([byte[]]$Bytes)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try{return (($sha.ComputeHash($Bytes)|ForEach-Object{$_.ToString('x2')})-join'')}
    finally{$sha.Dispose()}
}
function Convert-CoinListJson {
    param([string]$Json)
    if([string]::IsNullOrWhiteSpace($Json)){throw 'CoinGecko coins/list JSON is empty.'}
    $trimmed=$Json.TrimStart()
    if(-not$trimmed.StartsWith('[')){throw 'CoinGecko coins/list response is not a top-level JSON array.'}
    $parsed=ConvertFrom-Json -InputObject $Json
    $coins=@()
    if($parsed -is [System.Array]){$coins=@($parsed)}else{$coins=@($parsed|ForEach-Object{$_})}
    if($coins.Count-eq0){throw 'CoinGecko coins/list parsed to zero records.'}
    foreach($coin in @($coins|Select-Object -First 3)){
        foreach($property in @('id','name','symbol')){if($coin.PSObject.Properties.Name-notcontains$property){throw "Unexpected CoinGecko coins/list record shape: missing $property"}}
    }
    return $coins
}
function Match-Candidates {
    param([object]$Seed,[object[]]$Coins,[string[]]$ExistingIds)
    $names=@(Split-Pipe ([string]$Seed.query_names));$symbols=@(Split-Pipe ([string]$Seed.query_symbols))
    $nameSet=@{};foreach($n in $names){$nameSet[$n.ToLowerInvariant()]=$true}
    $symbolSet=@{};foreach($s in $symbols){$symbolSet[$s.ToLowerInvariant()]=$true}
    $rows=@()
    foreach($coin in $Coins){
        $name=[string]$coin.name;$symbol=[string]$coin.symbol;$id=[string]$coin.id
        $nameMatch=$nameSet.ContainsKey($name.ToLowerInvariant());$symbolMatch=$symbolSet.ContainsKey($symbol.ToLowerInvariant())
        if(-not($nameMatch-or$symbolMatch)){continue}
        $score=if($nameMatch-and$symbolMatch){100}elseif($nameMatch){80}else{60}
        $reasons=@();if($nameMatch){$reasons+='EXACT_SEED_NAME'};if($symbolMatch){$reasons+='EXACT_SEED_SYMBOL'}
        $rows+=[pscustomobject]@{
            base_asset_id=[string]$Seed.base_asset_id
            kraken_q2_name=[string]$Seed.kraken_q2_name
            kraken_q2_ticker=[string]$Seed.kraken_q2_ticker
            candidate_id=$id
            candidate_name=$name
            candidate_symbol=$symbol
            match_score=$score
            match_reasons=($reasons-join'|')
            already_in_af002=(@($ExistingIds)-contains$id)
            kraken_evidence_url=[string]$Seed.kraken_evidence_url
            evidence_note=[string]$Seed.evidence_note
        }
    }
    return @($rows|Sort-Object @{Expression='match_score';Descending=$true},candidate_name,candidate_id)
}
function Invoke-SelfTest {
    $parsed=@(Convert-CoinListJson '[{"id":"bitcoin","name":"Bitcoin","symbol":"btc"},{"id":"other","name":"Other","symbol":"xbt"},{"id":"nope","name":"Nope","symbol":"zzz"}]')
    if($parsed.Count-ne3){throw "JSON array expansion cardinality: $($parsed.Count)"}
    $bad=$false;try{Convert-CoinListJson '{"id":"bitcoin","name":"Bitcoin","symbol":"btc"}'|Out-Null}catch{$bad=$true};if(-not$bad){throw 'top-level array guard'}
    $seed=[pscustomobject]@{base_asset_id='X';kraken_q2_name='Bitcoin';kraken_q2_ticker='XBT';query_names='Bitcoin';query_symbols='BTC|XBT';kraken_evidence_url='https://example.invalid';evidence_note='test'}
    $rows=@(Match-Candidates $seed $parsed @('other'))
    if($rows.Count-ne2){throw 'match cardinality'}
    $btc=@($rows|Where-Object{$_.candidate_id-eq'bitcoin'})[0];if($btc.match_score-ne100-or$btc.already_in_af002-ne$false){throw 'bitcoin match'}
    $other=@($rows|Where-Object{$_.candidate_id-eq'other'})[0];if($other.match_score-ne60-or$other.already_in_af002-ne$true){throw 'existing candidate flag'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

try {
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $seedPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Expanded-Candidate-Seeds.csv'
    $decisionPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Mapping-Decisions.csv'
    if(-not(Test-Path -LiteralPath $seedPath -PathType Leaf)){throw 'Expanded candidate seed file missing.'}
    $seeds=@(Import-Csv -LiteralPath $seedPath);if($seeds.Count-le0){throw 'Expanded candidate seed set is empty.'}
    $decisions=@(Import-Csv -LiteralPath $decisionPath);if($decisions.Count-ne435){throw 'Mapping decisions must contain 435 rows.'}
    $decisionByBase=@{};foreach($d in $decisions){$decisionByBase[[string]$d.base_asset_id]=$d}
    foreach($seed in $seeds){$base=[string]$seed.base_asset_id;if(-not$decisionByBase.ContainsKey($base)){throw "Seed base is absent from mapping decisions: $base"};if([string]$decisionByBase[$base].mapping_status-ne'UNVERIFIED'){throw "Expanded candidate seed is no longer UNVERIFIED: $base"}}

    # Platforms are intentionally omitted: this evidence layer needs only CoinGecko id/name/symbol,
    # and the smaller official response is more robust under Windows PowerShell 5.1.
    $url=$ApiRoot.TrimEnd('/')+'/coins/list?include_platform=false'
    $client=New-Object System.Net.WebClient
    try{$client.Headers['User-Agent']='CFA-stage2-expanded-candidate-evidence/1.1';$bytes=$client.DownloadData($url)}finally{$client.Dispose()}
    if($bytes.Length-le0){throw 'CoinGecko coins/list response is empty.'}
    $sourceSha=Get-Sha256Bytes $bytes
    $json=(New-Object System.Text.UTF8Encoding($false,$true)).GetString($bytes)
    $coins=@(Convert-CoinListJson $json);if($coins.Count-lt10000){throw "CoinGecko coins/list record count unexpectedly small: $($coins.Count)"}

    $out=@();$summary=@()
    foreach($seed in $seeds){
        $decision=$decisionByBase[[string]$seed.base_asset_id];$existing=@(Split-Pipe ([string]$decision.candidate_ids))
        $matches=@(Match-Candidates $seed $coins $existing);$out+=$matches
        $summary+=[pscustomobject]@{base_asset_id=[string]$seed.base_asset_id;match_rows=$matches.Count;score_100=@($matches|Where-Object{$_.match_score-eq100}).Count;score_80=@($matches|Where-Object{$_.match_score-eq80}).Count;score_60=@($matches|Where-Object{$_.match_score-eq60}).Count;new_candidate_rows=@($matches|Where-Object{$_.already_in_af002-eq$false}).Count}
    }
    $csvPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Expanded-CoinGecko-Candidates.csv'
    $out|Sort-Object base_asset_id,@{Expression='match_score';Descending=$true},candidate_name,candidate_id|Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $summaryPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage2-Expanded-CoinGecko-Summary.csv'
    $summary|Sort-Object base_asset_id|Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

    $b=New-Object System.Text.StringBuilder
    [void]$b.AppendLine('# CFA Stage 2 Expanded CoinGecko Candidate Evidence');[void]$b.AppendLine('')
    [void]$b.AppendLine('- Source endpoint: `'+$url+'`')
    [void]$b.AppendLine('- Source SHA-256: `'+$sourceSha+'`')
    [void]$b.AppendLine('- Source bytes: '+$bytes.Length)
    [void]$b.AppendLine('- CoinGecko reference records: '+$coins.Count)
    [void]$b.AppendLine('- Expansion seeds: '+$seeds.Count)
    [void]$b.AppendLine('- Candidate evidence rows: '+$out.Count)
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Exact seed-name and seed-symbol matches are collected from CoinGecko keyless public reference data. This is candidate-expansion evidence only: it does not modify AF-002 or approve any mapping. Any later expanded mapping must cite an independently reviewed Kraken identity and validate the chosen CoinGecko id/name/symbol against this evidence table.')
    [void]$b.AppendLine('')
    [void]$b.AppendLine('Tables: `candidate-analysis/CFA-Stage2-Expanded-CoinGecko-Candidates.csv` and `candidate-analysis/CFA-Stage2-Expanded-CoinGecko-Summary.csv`.')
    Write-Utf8NoBom (Join-Path $RepoRoot 'docs\evidence\stage2-expanded-coingecko-candidates.md') $b.ToString()
    Write-Host ('CoinGecko reference records: '+$coins.Count);Write-Host ('Expansion seeds: '+$seeds.Count);Write-Host ('Candidate evidence rows: '+$out.Count);Write-Host 'CFA STAGE 2 EXPANDED COINGECKO CANDIDATE EVIDENCE: PASS'
}
catch {Write-Host 'CFA STAGE 2 EXPANDED COINGECKO CANDIDATE EVIDENCE: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
