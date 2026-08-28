#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [string]$ArchiveRoot='',
    [ValidateRange(1,100000)][int]$StartIndex=2600,
    [ValidateRange(1,100000)][int]$Count=500,
    [ValidateRange(0,256)][int]$WorkerCount=0,
    [string]$OutputRoot='',
    [switch]$KeepTemporaryFiles,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Utf8=New-Object System.Text.UTF8Encoding($false)
$BroadAnchors=@('bitcoin','ethereum','crypto','cryptocurrency','cryptocurrencies','blockchain','token','tokens','stablecoin','stablecoins','defi','decentralized finance','web3','nft','nfts','digital asset','digital assets','digital currency','digital currencies','staking','airdrop','airdrops','wallet','wallets','altcoin','altcoins','memecoin','memecoins','crypto market','cryptocurrency market')

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}

function Get-ExceptionLines {
    param([System.Exception]$Exception,[int]$Depth=0)
    $indent=('  '*$Depth)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($indent+$Exception.GetType().FullName+': '+$Exception.Message)
    if($Exception -is [System.AggregateException]){
        $flat=$Exception.Flatten()
        foreach($inner in $flat.InnerExceptions){foreach($line in @(Get-ExceptionLines $inner ($Depth+1))){$lines.Add($line)}}
    }elseif($null-ne$Exception.InnerException){
        foreach($line in @(Get-ExceptionLines $Exception.InnerException ($Depth+1))){$lines.Add($line)}
    }
    return $lines.ToArray()
}

function Get-DiagnosticCSharp {
    param([string]$InventoryScript)
    $text=Get-Content -LiteralPath $InventoryScript -Raw
    $pattern='(?s)\$CSharp=@''\r?\n(?<code>.*?)\r?\n''@'
    $m=[regex]::Match($text,$pattern)
    if(-not$m.Success){throw 'Could not extract embedded C# scanner source from inventory artifact.'}
    $code=$m.Groups['code'].Value
    if($code-notmatch'namespace CfaStage3Context'){throw 'Expected scanner namespace not found.'}
    $code=$code.Replace('namespace CfaStage3Context','namespace CfaStage3ContextDiagnostic')
    $old='delegate(string path,ParallelLoopState loopState,WorkerState local){ProcessArchive(path,local);return local;}'
    $new='delegate(string path,ParallelLoopState loopState,WorkerState local){try{ProcessArchive(path,local);return local;}catch(Exception ex){throw new InvalidOperationException("ARCHIVE_FAILURE|"+path+"|"+ex.GetType().FullName+"|"+ex.Message,ex);}}'
    if(-not$code.Contains($old)){throw 'Parallel archive delegate shape changed; diagnostic patch cannot be applied safely.'}
    $code=$code.Replace($old,$new)
    return $code
}

function Install-DiagnosticScanner {
    param([string]$Code)
    if('CfaStage3ContextDiagnostic.ParallelScanner' -as [type]){return}
    if($PSVersionTable.PSVersion.Major-ge6){
        Add-Type -TypeDefinition $Code -Language CSharp
    }else{
        $refs=@(
            [System.IO.Compression.ZipArchive].Assembly.Location,
            [System.IO.Compression.ZipFile].Assembly.Location
        )|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique
        Add-Type -TypeDefinition $Code -Language CSharp -ReferencedAssemblies $refs
    }
}

function Resolve-Inputs {
    if([string]::IsNullOrWhiteSpace($script:RepoRoot)){$script:RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $script:RepoRoot=(Resolve-Path -LiteralPath $script:RepoRoot).ProviderPath
    $inventory=Join-Path $script:RepoRoot 'scripts\windows\Build-CfaStage3ContextInventory.ps1'
    if(-not(Test-Path -LiteralPath $inventory -PathType Leaf)){throw "Inventory artifact missing: $inventory"}
    $aliasPath=Join-Path $script:RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if(-not(Test-Path -LiteralPath $aliasPath -PathType Leaf)){throw "Alias registry missing: $aliasPath"}
    $aliases=@(Import-Csv -LiteralPath $aliasPath -Encoding UTF8)
    if($aliases.Count-ne470){throw "Expected 470 candidate alias rows; observed $($aliases.Count)."}
    return [pscustomobject]@{Inventory=$inventory;AliasPath=$aliasPath;Aliases=$aliases}
}

try {
    $inputs=Resolve-Inputs
    $code=Get-DiagnosticCSharp $inputs.Inventory
    Install-DiagnosticScanner $code
    if($SelfTest){
        $probe=New-Object System.InvalidOperationException -ArgumentList 'outer',(New-Object System.IO.InvalidDataException 'inner')
        $lines=@(Get-ExceptionLines $probe)
        if($lines.Count-lt2-or($lines-join"`n")-notmatch'InvalidDataException'){throw 'Nested exception formatter self-test failed.'}
        Write-Host 'SELF-TEST: PASS'
        exit 0
    }

    $documents=[Environment]::GetFolderPath('MyDocuments')
    if([string]::IsNullOrWhiteSpace($ArchiveRoot)){$ArchiveRoot=Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025'}
    if(-not(Test-Path -LiteralPath $ArchiveRoot -PathType Container)){throw "Archive root missing: $ArchiveRoot"}
    $ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    $all=@(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip'|Where-Object{$_.Name-match'^\d{14}\.gkg\.csv\.zip$'}|Sort-Object Name)
    if($all.Count-ne7163){throw "Expected 7163 archives; observed $($all.Count)."}
    $zero=$StartIndex-1
    if($zero-ge$all.Count){throw "StartIndex $StartIndex exceeds archive count $($all.Count)."}
    $take=[math]::Min($Count,$all.Count-$zero)
    $slice=@($all[$zero..($zero+$take-1)])

    if([string]::IsNullOrWhiteSpace($OutputRoot)){
        $parent=Join-Path $documents 'CFA-local\stage3-context-diagnostic'
        if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        $OutputRoot=Join-Path $parent ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    }
    New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
    $OutputRoot=(Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    $temp=Join-Path $OutputRoot '_temp';New-Item -ItemType Directory -Path $temp -Force|Out-Null
    $workers=if($WorkerCount-le0){[Environment]::ProcessorCount}else{$WorkerCount}
    $drive=Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($OutputRoot).Substring(0,1)) -ErrorAction SilentlyContinue

    Write-Host ('Diagnostic archive slice: '+$StartIndex+'..'+($StartIndex+$take-1)+' of 7163')
    Write-Host ('First archive: '+$slice[0].Name)
    Write-Host ('Last archive : '+$slice[-1].Name)
    Write-Host ('Workers      : '+$workers+' | logical_processors='+[Environment]::ProcessorCount)
    if($null-ne$drive){Write-Host ('Output free GB: '+[math]::Round($drive.Free/1GB,2))}

    $aliasTexts=@($inputs.Aliases|ForEach-Object{([string]$_.alias_text).Trim()})
    $baseIds=@($inputs.Aliases|ForEach-Object{([string]$_.base_asset_id).Trim()})
    try {
        $scan=[CfaStage3ContextDiagnostic.ParallelScanner]::Run(@($slice.FullName),$temp,$aliasTexts,$baseIds,$BroadAnchors,$workers,0)
        $summary=[ordered]@{
            status='PASS_NO_RUNTIME_FAILURE_IN_SLICE'
            start_index=$StartIndex
            count=$take
            first_archive=$slice[0].Name
            last_archive=$slice[-1].Name
            logical_processors=$scan.LogicalProcessorCount
            worker_count=$scan.WorkerCount
            archives_processed=$scan.ArchivesProcessed
            rows_scanned=$scan.TotalRows
            rows_per_second=[math]::Round($scan.RowsPerSecond,2)
        }
        Write-Utf8NoBom (Join-Path $OutputRoot 'diagnostic-summary.json') (($summary|ConvertTo-Json -Depth 5)+[Environment]::NewLine)
        Write-Host ('DIAGNOSTIC RESULT: PASS_NO_RUNTIME_FAILURE_IN_SLICE | rows='+$scan.TotalRows+' | rows/sec='+[math]::Round($scan.RowsPerSecond,2))
        exit 0
    } catch {
        $lines=@(Get-ExceptionLines $_.Exception)
        $payload=(@('DIAGNOSTIC RESULT: RUNTIME_FAILURE','start_index='+$StartIndex,'count='+$take,'first_archive='+$slice[0].Name,'last_archive='+$slice[-1].Name)+$lines)-join[Environment]::NewLine
        Write-Utf8NoBom (Join-Path $OutputRoot 'diagnostic-failure.txt') ($payload+[Environment]::NewLine)
        Write-Host 'DIAGNOSTIC RESULT: RUNTIME_FAILURE'
        foreach($line in $lines){Write-Host $line}
        Write-Host ('Diagnostic evidence: '+$OutputRoot)
        exit 2
    } finally {
        if(-not$KeepTemporaryFiles){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
    }
} catch {
    Write-Host 'CFA STAGE 3 PARALLEL FAILURE DIAGNOSTIC: FAIL'
    foreach($line in @(Get-ExceptionLines $_.Exception)){Write-Host $line}
    exit 1
}
