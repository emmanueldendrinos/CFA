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

$OldInvokeBlock = @'
function Invoke-Gcloud {
    param([string]$Gcloud,[string[]]$Arguments,[switch]$AllowNonzero)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdoutLines=@(& $Gcloud @Arguments 2>$err)
        $code=$LASTEXITCODE
        $rawStderr=$null
        if(Test-Path -LiteralPath $err){$rawStderr=Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue}
        $stdoutText=[string](($stdoutLines|ForEach-Object{[string]$_})-join[Environment]::NewLine)
        $stderrText=if($null-eq$rawStderr){''}else{[string]$rawStderr}
        if($code-ne0 -and -not$AllowNonzero){throw ('gcloud failed (exit '+$code+'): '+($Arguments-join' ')+'`n'+$stderrText)}
        [pscustomobject]@{ExitCode=$code;Stdout=$stdoutText.Trim();Stderr=$stderrText.Trim()}
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}
'@

$NewInvokeBlock = @'
function Invoke-Gcloud {
    param([string]$Gcloud,[string[]]$Arguments,[switch]$AllowNonzero)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdoutLines=@()
        $code=$null
        $oldInvokeEap=$ErrorActionPreference
        try{
            $ErrorActionPreference='Continue'
            $stdoutLines=@(& $Gcloud @Arguments 2>$err)
            $code=$LASTEXITCODE
        }finally{
            $ErrorActionPreference=$oldInvokeEap
        }
        $rawStderr=$null
        if(Test-Path -LiteralPath $err){$rawStderr=Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue}
        $stdoutText=[string](($stdoutLines|ForEach-Object{[string]$_})-join[Environment]::NewLine)
        $stderrText=if($null-eq$rawStderr){''}else{[string]$rawStderr}
        if($code-ne0 -and -not$AllowNonzero){throw ('gcloud failed (exit '+$code+'): '+($Arguments-join' ')+'`n'+$stderrText)}
        [pscustomobject]@{ExitCode=[int]$code;Stdout=$stdoutText.Trim();Stderr=$stderrText.Trim()}
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}
'@

$OldConvertBlock = @'
function Convert-CloudJsonToMap {
    param([string]$Json,[string]$BucketUri)
    if([string]::IsNullOrWhiteSpace($Json)){return @{}}
    $parsed=$Json|ConvertFrom-Json
    $items=if($parsed -is [System.Array]){@($parsed)}else{@($parsed)}
    $map=@{}
    foreach($entry in $items){
        $o=$entry
        $metadata=Get-PropertyValue $entry @('metadata')
        $type=[string](Get-PropertyValue $entry @('type'))
        if($null-ne$metadata -and ($type-eq'cloud_object' -or [string]::IsNullOrWhiteSpace($type))){$o=$metadata}
        $url=[string](Get-PropertyValue $entry @('url'))
        if([string]::IsNullOrWhiteSpace($url)){$url=[string](Get-PropertyValue $o @('url'))}
        $name=[string](Get-PropertyValue $o @('name'))
        if([string]::IsNullOrWhiteSpace($url)){
            if([string]::IsNullOrWhiteSpace($name)){continue}
            $url=if($name.StartsWith('gs://',[StringComparison]::Ordinal)){$name}else{$BucketUri+'/'+$name.TrimStart('/')}
        }
        $prefixUri=$BucketUri+'/'
        $objectName=if($url.StartsWith($prefixUri,[StringComparison]::Ordinal)){$url.Substring($prefixUri.Length)}else{$url.TrimStart('/')}
        if($map.ContainsKey($objectName)){throw "Duplicate cloud listing: $objectName"}
        $map[$objectName]=$o
    }
    $map
}
'@

$NewConvertBlock = @'
function Convert-CloudJsonToMap {
    param([string]$Json,[string]$BucketUri)
    if([string]::IsNullOrWhiteSpace($Json)){return @{}}
    $parsed=$Json|ConvertFrom-Json
    $items=if($parsed -is [System.Array]){@($parsed)}else{@($parsed)}
    $map=@{}
    $prefixUri=$BucketUri+'/'
    foreach($entry in $items){
        $o=$entry
        $metadata=Get-PropertyValue $entry @('metadata')
        $type=[string](Get-PropertyValue $entry @('type'))
        if($null-ne$metadata -and ($type-eq'cloud_object' -or [string]::IsNullOrWhiteSpace($type))){$o=$metadata}

        # Cloud Storage metadata.name is the logical object name and does not
        # include the generation. Prefer it over gcloud's versioned URL.
        $name=[string](Get-PropertyValue $o @('name'))
        $objectName=''
        if(-not[string]::IsNullOrWhiteSpace($name)){
            if($name.StartsWith($prefixUri,[StringComparison]::Ordinal)){
                $objectName=$name.Substring($prefixUri.Length)
            }elseif($name.StartsWith('gs://',[StringComparison]::Ordinal)){
                $objectName=$name.Substring($name.IndexOf('/',5)+1)
            }else{
                $objectName=$name.TrimStart('/')
            }
        }else{
            $url=[string](Get-PropertyValue $entry @('url'))
            if([string]::IsNullOrWhiteSpace($url)){$url=[string](Get-PropertyValue $o @('url'))}
            if([string]::IsNullOrWhiteSpace($url)){continue}
            $logicalUrl=[regex]::Replace($url,'#[0-9]+$','')
            $objectName=if($logicalUrl.StartsWith($prefixUri,[StringComparison]::Ordinal)){$logicalUrl.Substring($prefixUri.Length)}else{$logicalUrl.TrimStart('/')}
        }

        if([string]::IsNullOrWhiteSpace($objectName)){continue}
        if($map.ContainsKey($objectName)){throw "Duplicate cloud listing: $objectName"}
        $map[$objectName]=$o
    }
    $map
}
'@

function Get-SourcePath {
    $p=Join-Path $PSScriptRoot 'Resume-CfaGdeltQ2ToGcsV5.ps1'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "V5 resume source missing: $p"}
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function New-PatchedArtifact {
    param([string]$SourcePath,[string]$DestinationPath)
    $text=[System.IO.File]::ReadAllText($SourcePath)
    $invokeMatches=([regex]::Matches($text,[regex]::Escape($OldInvokeBlock))).Count
    $convertMatches=([regex]::Matches($text,[regex]::Escape($OldConvertBlock))).Count
    if($invokeMatches-ne1){throw "Expected exactly one V5 Invoke-Gcloud block; observed $invokeMatches."}
    if($convertMatches-ne1){throw "Expected exactly one V5 Convert-CloudJsonToMap block; observed $convertMatches."}
    $patched=$text.Replace($OldInvokeBlock,$NewInvokeBlock).Replace($OldConvertBlock,$NewConvertBlock)
    if($patched.Contains($OldInvokeBlock)){throw 'V5 native-stderr wrapper survived V7 patch.'}
    if($patched.Contains($OldConvertBlock)){throw 'V5 generation-unsafe cloud parser survived V7 patch.'}
    [System.IO.File]::WriteAllText($DestinationPath,$patched,$Utf8NoBom)
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($DestinationPath,[ref]$tokens,[ref]$errors)
    if($errors.Count-gt0){throw ('Patched V7 artifact failed parsing: '+(($errors|ForEach-Object{$_.Message})-join'; '))}
    return $ast
}

function Import-PatchedFunctions {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast,[string[]]$Names)
    foreach($name in $Names){
        $matches=@($Ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
        if($matches.Count-ne1){throw "Expected exactly one patched $name function; observed $($matches.Count)."}
        Invoke-Expression $matches[0].Extent.Text
    }
}

function Invoke-Regressions {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    Import-PatchedFunctions -Ast $Ast -Names @('Invoke-Gcloud','Get-PropertyValue','Convert-CloudJsonToMap')

    $old=$ErrorActionPreference
    try{
        $ErrorActionPreference='Stop'
        $cmdArgs=@('/d','/c','echo expected-native-stderr 1>&2 & exit /b 7')
        $r=Invoke-Gcloud -Gcloud $env:ComSpec -Arguments $cmdArgs -AllowNonzero:$true
        if($r.ExitCode-ne7 -or $r.Stderr -notmatch 'expected-native-stderr'){throw 'Native stderr regression failed.'}

        $observed='raw/gdelt-gkg-q2-2025/archives/2025/04/03/20250403064500.gkg.csv.zip'
        $wrapped='[{"type":"cloud_object","url":"gs://bucket/'+$observed+'#1788008032631044","metadata":{"name":"'+$observed+'","size":"3","md5Hash":"kAFQmDzST7DWlj99KOF/cg=="}}]'
        $m1=Convert-CloudJsonToMap -Json $wrapped -BucketUri 'gs://bucket'
        if(-not$m1.ContainsKey($observed)){throw 'Generation-bearing gcloud URL did not normalize to logical object name.'}
        if(@($m1.Keys|Where-Object{$_ -match '#1788008032631044$'}).Count-ne0){throw 'Generation suffix leaked into logical object key.'}

        $fallback='[{"url":"gs://bucket/raw/fallback.zip#123456789","size":"3","md5Hash":"kAFQmDzST7DWlj99KOF/cg=="}]'
        $m2=Convert-CloudJsonToMap -Json $fallback -BucketUri 'gs://bucket'
        if(-not$m2.ContainsKey('raw/fallback.zip')){throw 'URL-only generation fallback normalization failed.'}
    }finally{$ErrorActionPreference=$old}
}

function Invoke-SelfTest {
    $root=Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gcs-v7-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    try{
        $src=Get-SourcePath
        $dst=Join-Path $root 'patched-v7.ps1'
        $ast=New-PatchedArtifact -SourcePath $src -DestinationPath $dst
        Invoke-Regressions -Ast $ast
        Write-Host 'SELF-TEST: PASS'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

$temp=Join-Path ([System.IO.Path]::GetTempPath()) ('Resume-CfaGdeltQ2ToGcs-patched-v7-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
    $source=Get-SourcePath
    $ast=New-PatchedArtifact -SourcePath $source -DestinationPath $temp
    Invoke-Regressions -Ast $ast
    Write-Host ('Patched resume artifact: '+$temp)
    Write-Host 'Native stderr + generation regression: PASS'

    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$temp,
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
        '-ThreadCount',[string]$ThreadCount)
    & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @args
    exit $LASTEXITCODE
}catch{
    Write-Host 'CFA GDELT GCS ARCHIVE RESUME V7: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
