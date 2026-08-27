#requires -Version 5.1
[CmdletBinding()]
param([string]$RepoRoot='',[switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$Specs=@(
    [pscustomobject]@{id='AF-001';path='candidate-analysis\ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv';sha='569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f';bytes=355619;rows=1059;cols=16},
    [pscustomobject]@{id='AF-003';path='candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv';sha='8c75e334be54e888b17a70d7945dc43ff2f2d789126eefaee11b4a6d078f7fc4';bytes=4621;rows=45;cols=6}
)

function Test-One {
    param([string]$Root,[object]$Spec)
    $path=Join-Path $Root ([string]$Spec.path)
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw("Missing active news input {0}: {1}"-f$Spec.id,$path)}
    $item=Get-Item -LiteralPath $path
    $sha=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $rows=@(Import-Csv -LiteralPath $path)
    $cols=0
    if($rows.Count-gt0){$cols=@($rows[0].PSObject.Properties).Count}
    if($sha-ne[string]$Spec.sha){throw("{0} SHA-256 mismatch: expected={1} observed={2}"-f$Spec.id,$Spec.sha,$sha)}
    if([long]$item.Length-ne[long]$Spec.bytes){throw("{0} byte-count mismatch: expected={1} observed={2}"-f$Spec.id,$Spec.bytes,$item.Length)}
    if($rows.Count-ne[int]$Spec.rows){throw("{0} row-count mismatch: expected={1} observed={2}"-f$Spec.id,$Spec.rows,$rows.Count)}
    if($cols-ne[int]$Spec.cols){throw("{0} column-count mismatch: expected={1} observed={2}"-f$Spec.id,$Spec.cols,$cols)}
    return [pscustomobject]@{source_id=$Spec.id;sha256=$sha;bytes=[long]$item.Length;rows=$rows.Count;columns=$cols;status='PASS'}
}

function Invoke-SelfTest {
    if($Specs.Count-ne2){throw 'active spec count'}
    if(@($Specs|Where-Object{$_.id-eq'AF-002'}).Count-ne0){throw 'CoinGecko must not be an active news input'}
    if([string]$Specs[0].sha-notmatch'^[0-9a-f]{64}$'){throw 'sha shape'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $results=@();foreach($spec in $Specs){$results+=Test-One -Root $RepoRoot -Spec $spec}
    foreach($r in $results){Write-Host ($r.source_id+': PASS | sha256='+$r.sha256+' | rows='+$r.rows+' | columns='+$r.columns)}
    Write-Host 'CFA ACTIVE KRAKEN / GDELT NEWS INPUTS: PASS'
    exit 0
}catch{Write-Host 'CFA ACTIVE KRAKEN / GDELT NEWS INPUTS: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
