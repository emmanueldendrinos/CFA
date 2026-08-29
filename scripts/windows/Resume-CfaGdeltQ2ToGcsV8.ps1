#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ResumeRunRoot,
    [string]$ProjectId = 'asrp-gdelt-recovery',
    [string]$BucketName = 'asrp-gdelt-recovery-cfa-gdelt-q2-2025',
    [string]$BucketLocation = 'EU',
    [ValidateSet('STANDARD','NEARLINE','COLDLINE','ARCHIVE')][string]$StorageClass = 'STANDARD',
    [string]$Prefix = 'raw/gdelt-gkg-q2-2025',
    [string]$ArchiveRoot = 'C:\Users\Emmanuel\Documents\CFA-local\gdelt-gkg-q2-2025',
    [string]$PgHost = 'localhost',
    [ValidateRange(1,65535)][int]$PgPort = 5432,
    [string]$PgUser = 'postgres',
    [string]$DatabaseName = 'cfa',
    [ValidateRange(1,64)][int]$ProcessCount = 1,
    [ValidateRange(1,64)][int]$ThreadCount = 1,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$OldSnippet = @'
        if([string]::IsNullOrWhiteSpace($objectName)){continue}
        if($map.ContainsKey($objectName)){throw "Duplicate cloud listing: $objectName"}
'@

$NewSnippet = @'
        if([string]::IsNullOrWhiteSpace($objectName)){continue}
        $sizeValue=Get-PropertyValue $o @('size','sizeBytes')
        $md5Value=[string](Get-PropertyValue $o @('md5Hash','md5_hash'))

        # gcloud storage ls can emit folder/prefix entries in addition to
        # actual cloud objects. Reconciliation is defined only over objects.
        if((-not[string]::IsNullOrWhiteSpace($type) -and $type-ne'cloud_object') -or
           ($objectName.EndsWith('/') -and $null-eq$sizeValue -and [string]::IsNullOrWhiteSpace($md5Value))){
            continue
        }

        if($map.ContainsKey($objectName)){throw "Duplicate cloud listing: $objectName"}
'@

function Get-V7Path {
    $p=Join-Path $PSScriptRoot 'Resume-CfaGdeltQ2ToGcsV7.ps1'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "V7 resume source missing: $p"}
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function Get-ObjectPropertyValue {
    param([object]$Object,[string[]]$Names)
    if($null-eq$Object){return $null}
    foreach($name in $Names){
        $p=$Object.PSObject.Properties[$name]
        if($null-ne$p){return $p.Value}
    }
    return $null
}

function New-PatchedV7 {
    param([string]$SourcePath,[string]$DestinationPath)

    $text=[System.IO.File]::ReadAllText($SourcePath)
    $matches=([regex]::Matches($text,[regex]::Escape($OldSnippet))).Count
    if($matches-ne1){throw "Expected exactly one V7 object-map insertion point; observed $matches."}

    $patched=$text.Replace($OldSnippet,$NewSnippet)
    if($patched-eq$text){throw 'V8 prefix-entry patch made no change.'}
    if($patched.Contains($OldSnippet)){throw 'V7 prefix-unsafe insertion point survived V8 patch.'}

    [System.IO.File]::WriteAllText($DestinationPath,$patched,$Utf8NoBom)

    $tokens=$null;$errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile($DestinationPath,[ref]$tokens,[ref]$errors)|Out-Null
    if($errors.Count-gt0){
        throw ('Patched V8/V7 artifact failed parsing: '+(($errors|ForEach-Object{$_.Message})-join'; '))
    }

    return $patched
}

function Import-PatchedCloudParser {
    param([string]$PatchedText)

    $pattern='(?s)\$NewConvertBlock\s*=\s*@''\r?\n(?<body>function Convert-CloudJsonToMap \{.*?\r?\n\})\r?\n''@'
    $m=[regex]::Match($PatchedText,$pattern)
    if(-not$m.Success){throw 'Could not locate patched V7 Convert-CloudJsonToMap definition.'}

    function Get-PropertyValue {
        param([object]$Object,[string[]]$Names)
        if($null-eq$Object){return $null}
        foreach($n in $Names){
            $p=$Object.PSObject.Properties[$n]
            if($null-ne$p){return $p.Value}
        }
        return $null
    }

    Invoke-Expression $m.Groups['body'].Value

    $prefix='raw/gdelt-gkg-q2-2025/'
    $folderJson='[{"type":"prefix","url":"gs://bucket/'+$prefix+'","metadata":{"name":"'+$prefix+'"}}]'
    $folderMap=Convert-CloudJsonToMap -Json $folderJson -BucketUri 'gs://bucket'
    if($folderMap.Count-ne0){throw 'Typed prefix entry leaked into cloud object map.'}

    $typelessFolderJson='[{"url":"gs://bucket/'+$prefix+'","metadata":{"name":"'+$prefix+'"}}]'
    $typelessFolderMap=Convert-CloudJsonToMap -Json $typelessFolderJson -BucketUri 'gs://bucket'
    if($typelessFolderMap.Count-ne0){throw 'Typeless directory entry leaked into cloud object map.'}

    $objectName='raw/gdelt-gkg-q2-2025/archives/2025/04/03/20250403064500.gkg.csv.zip'
    $objectJson='[{"type":"cloud_object","url":"gs://bucket/'+$objectName+'#1788008032631044","metadata":{"name":"'+$objectName+'","size":"3","md5Hash":"kAFQmDzST7DWlj99KOF/cg=="}}]'
    $objectMap=Convert-CloudJsonToMap -Json $objectJson -BucketUri 'gs://bucket'
    if($objectMap.Count-ne1 -or -not$objectMap.ContainsKey($objectName)){
        throw 'Actual cloud object was not preserved while filtering prefixes.'
    }
}

function Invoke-SelfTest {
    $root=Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gcs-v8-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    try{
        $src=Get-V7Path
        $dst=Join-Path $root 'patched-v7.ps1'
        $patched=New-PatchedV7 -SourcePath $src -DestinationPath $dst
        Import-PatchedCloudParser -PatchedText $patched
        Write-Host 'SELF-TEST: PASS'
    }finally{
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{
        Write-Host 'SELF-TEST: FAIL'
        Write-Host $_.Exception.Message
        if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
        exit 1
    }
}

$temp=Join-Path ([System.IO.Path]::GetTempPath()) ('Resume-CfaGdeltQ2ToGcs-patched-v8-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
    $source=Get-V7Path
    $patched=New-PatchedV7 -SourcePath $source -DestinationPath $temp
    Import-PatchedCloudParser -PatchedText $patched

    Write-Host ('Patched V8/V7 resume artifact: '+$temp)
    Write-Host 'Directory/prefix + generation regression: PASS'

    $args=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$temp,
        '-ResumeRunRoot',$ResumeRunRoot,
        '-ProjectId',$ProjectId,
        '-BucketName',$BucketName,
        '-BucketLocation',$BucketLocation,
        '-StorageClass',$StorageClass,
        '-Prefix',$Prefix,
        '-ArchiveRoot',$ArchiveRoot,
        '-PgHost',$PgHost,
        '-PgPort',[string]$PgPort,
        '-PgUser',$PgUser,
        '-DatabaseName',$DatabaseName,
        '-ProcessCount',[string]$ProcessCount,
        '-ThreadCount',[string]$ThreadCount
    )

    & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @args
    exit $LASTEXITCODE
}catch{
    Write-Host 'CFA GDELT GCS ARCHIVE RESUME V8: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
