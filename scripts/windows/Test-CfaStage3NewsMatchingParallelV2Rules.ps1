#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MatcherPath = (Join-Path $PSScriptRoot 'Run-CfaStage3NewsMatchingParallelV2.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -LiteralPath $MatcherPath -PathType Leaf)) { throw "Matcher missing: $MatcherPath" }
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $MatcherPath),[ref]$tokens,[ref]$errors)
    if($errors.Count-gt0){throw 'Matcher parse errors prevent rule regression test.'}

    $needed=@('Bool','AliasKey','Add-Hit','Is-DefaultSymbolOnly','New-PhraseRegex','Get-AliasTools','Add-TitleHits')
    foreach($name in $needed){
        $fn=$ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if($null-eq$fn){throw "Required matcher function missing: $name"}
        Invoke-Expression $fn.Extent.Text
    }

    $source=Get-Content -LiteralPath $MatcherPath
    $anchorLine=@($source|Where-Object{$_ -match '^\$StrongCryptoTitleRegex\s*='}|Select-Object -First 1)
    if($anchorLine.Count-ne1){throw 'StrongCryptoTitleRegex assignment not found.'}
    Invoke-Expression $anchorLine[0]

    $aliases=New-Object System.Collections.ArrayList
    foreach($r in @(
        [pscustomobject]@{base_asset_id='NEAR';alias_text='NEAR';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='TERM';alias_text='TERM';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='SKY';alias_text='SKY';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='GRASS';alias_text='GRASS';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='BAL';alias_text='BAL';alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'},
        [pscustomobject]@{base_asset_id='ARB';alias_text='Arbitrum';alias_type='manual_core_name';requires_crypto_context='False';alias_source='AF003_APPROVED_ALIAS'}
    )){[void]$aliases.Add($r)}
    for($i=1;$aliases.Count-lt431;$i++){
        $id=('ZZTEST{0:000}'-f$i)
        [void]$aliases.Add([pscustomobject]@{base_asset_id=$id;alias_text=$id;alias_type='kraken_base_symbol';requires_crypto_context='True';alias_source='AF001_KRAKEN_SYMBOL'})
    }
    $tools=Get-AliasTools @($aliases.ToArray())

    foreach($case in @(
        [pscustomobject]@{title='BTC set for a Near-Term bounce';forbidden='NEAR|near'},
        [pscustomobject]@{title='Shifting sentiment? Short-Term Bitcoin holders';forbidden='TERM|term'},
        [pscustomobject]@{title='Sky-High Revolution as Satellites Supercharge Blockchain Speed';forbidden='SKY|sky'},
        [pscustomobject]@{title='Garden expert shares £1 coin hack to help grass seeds grow';forbidden='GRASS|grass'}
    )){
        $hits=@{};Add-TitleHits $hits $tools $case.title
        if($hits.ContainsKey($case.forbidden)){throw "False-positive regression: $($case.title)"}
    }

    $hits=@{};Add-TitleHits $hits $tools 'Binance to delist BADGER, BAL, 12 more tokens on April 16'
    if(-not$hits.ContainsKey('BAL|bal')){throw 'Uppercase BAL symbol evidence was not retained.'}
    $hits=@{};Add-TitleHits $hits $tools "Arbitrum's rise mirrors market strength"
    if(-not$hits.ContainsKey('ARB|arbitrum')){throw 'Approved long-form alias evidence was not retained.'}

    if($StrongCryptoTitleRegex.IsMatch('Garden expert shares £1 coin hack')){throw 'Generic standalone coin incorrectly supplies V2 crypto context.'}
    if(-not$StrongCryptoTitleRegex.IsMatch('New meme coins to invest in')){throw 'Meme coin phrase should supply V2 crypto context.'}
    if(-not$StrongCryptoTitleRegex.IsMatch('Blockchain speed increases')){throw 'Blockchain should supply V2 crypto context.'}

    Write-Host 'V2 RULE REGRESSION TEST: PASS'
    exit 0
}
catch {
    Write-Host 'V2 RULE REGRESSION TEST: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
