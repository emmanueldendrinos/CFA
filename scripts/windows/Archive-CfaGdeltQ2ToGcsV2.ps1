#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectId = '',
    [string]$BucketName = '',
    [string]$BucketLocation = 'EU',
    [ValidateSet('STANDARD','NEARLINE','COLDLINE','ARCHIVE')][string]$StorageClass = 'STANDARD',
    [string]$Prefix = 'raw/gdelt-gkg-q2-2025',
    [string]$ArchiveRoot = '',
    [string]$EvidenceRoot = '',
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$DatabaseName = 'cfa',
    [ValidateRange(1,64)][int]$ProcessCount = 4,
    [ValidateRange(1,64)][int]$ThreadCount = 8,
    [switch]$ValidateOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$Buggy = 'Stderr=$stderr.Trim()'
$Fixed = 'Stderr=([string]$stderr).Trim()'

function Get-SourcePath {
    $p = Join-Path $PSScriptRoot 'Archive-CfaGdeltQ2ToGcs.ps1'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){ throw "Base uploader missing: $p" }
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function New-PatchedArtifact {
    param([string]$SourcePath,[string]$DestinationPath)
    $text=[System.IO.File]::ReadAllText($SourcePath)
    $matches=([regex]::Matches($text,[regex]::Escape($Buggy))).Count
    if($matches-ne1){ throw "Expected exactly one null-unsafe stderr expression; observed $matches." }
    $patched=$text.Replace($Buggy,$Fixed)
    if($patched-eq$text){ throw 'Null-safety patch made no change.' }
    [System.IO.File]::WriteAllText($DestinationPath,$patched,$Utf8NoBom)
    $tokens=$null;$errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($DestinationPath,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors.Count-gt0){ throw ('Patched uploader failed parsing: '+(($errors|ForEach-Object{$_.Message})-join'; ')) }
}

function Invoke-SelfTest {
    $root=Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gcs-v2-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    try{
        $src=Join-Path $root 'src.ps1';$dst=Join-Path $root 'dst.ps1'
        $sample="`$x=[pscustomobject]@{Stderr=`$stderr.Trim()}`r`n"
        [System.IO.File]::WriteAllText($src,$sample,$Utf8NoBom)
        New-PatchedArtifact $src $dst
        $out=[System.IO.File]::ReadAllText($dst)
        if($out -notmatch [regex]::Escape('Stderr=([string]$stderr).Trim()')){throw 'Patched stderr expression missing.'}
        if($out -match [regex]::Escape('Stderr=$stderr.Trim()')){throw 'Buggy stderr expression survived.'}
        $stderr=$null
        $safe=([string]$stderr).Trim()
        if($safe-ne''){throw 'Null-to-empty stderr regression test failed.'}
        Write-Host 'SELF-TEST: PASS'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}
}

$temp=Join-Path ([System.IO.Path]::GetTempPath()) ('Archive-CfaGdeltQ2ToGcs-patched-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
    $source=Get-SourcePath
    New-PatchedArtifact $source $temp
    Write-Host ('Patched archival artifact: '+$temp)
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$temp,
        '-ProjectId',$ProjectId,
        '-BucketName',$BucketName,
        '-BucketLocation',$BucketLocation,
        '-StorageClass',$StorageClass,
        '-Prefix',$Prefix,
        '-ArchiveRoot',$ArchiveRoot,
        '-EvidenceRoot',$EvidenceRoot,
        '-PgHost',$PgHost,
        '-PgPort',[string]$PgPort,
        '-PgUser',$PgUser,
        '-DatabaseName',$DatabaseName,
        '-ProcessCount',[string]$ProcessCount,
        '-ThreadCount',[string]$ThreadCount)
    if($ValidateOnly){$args+='-ValidateOnly'}
    & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @args
    $code=$LASTEXITCODE
    exit $code
}catch{
    Write-Host 'CFA GDELT GCS ARCHIVE V2: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
