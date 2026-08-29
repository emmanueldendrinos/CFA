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

$OldBlock = @'
function Invoke-Gcloud {
    param([string]$Gcloud,[string[]]$Arguments,[switch]$AllowNonzero)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdout=@(& $Gcloud @Arguments 2>$err)
        $code=$LASTEXITCODE
        $stderr=if(Test-Path -LiteralPath $err){(Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)}else{''}
        if($code-ne0 -and -not$AllowNonzero){
            throw ('gcloud failed (exit '+$code+'): '+($Arguments-join' ')+'`n'+$stderr)
        }
        return [pscustomobject]@{ExitCode=$code;Stdout=(($stdout|ForEach-Object{[string]$_})-join[Environment]::NewLine).Trim();Stderr=$stderr.Trim()}
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}
'@

$NewBlock = @'
function Invoke-Gcloud {
    param([string]$Gcloud,[string[]]$Arguments,[switch]$AllowNonzero)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdoutLines=@(& $Gcloud @Arguments 2>$err)
        $code=$LASTEXITCODE
        $rawStderr=$null
        if(Test-Path -LiteralPath $err){
            $rawStderr=Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue
        }
        $stdoutText=[string](($stdoutLines|ForEach-Object{[string]$_})-join[Environment]::NewLine)
        $stderrText=if($null-eq$rawStderr){''}else{[string]$rawStderr}
        if($code-ne0 -and -not$AllowNonzero){
            throw ('gcloud failed (exit '+$code+'): '+($Arguments-join' ')+'`n'+$stderrText)
        }
        return [pscustomobject]@{
            ExitCode=$code
            Stdout=$stdoutText.Trim()
            Stderr=$stderrText.Trim()
        }
    }finally{Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue}
}
'@

function Get-SourcePath {
    $p=Join-Path $PSScriptRoot 'Archive-CfaGdeltQ2ToGcs.ps1'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Base uploader missing: $p"}
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function New-PatchedArtifact {
    param([string]$SourcePath,[string]$DestinationPath)
    $text=[System.IO.File]::ReadAllText($SourcePath)
    $matches=([regex]::Matches($text,[regex]::Escape($OldBlock))).Count
    if($matches-ne1){throw "Expected exactly one original Invoke-Gcloud block; observed $matches."}
    $patched=$text.Replace($OldBlock,$NewBlock)
    if($patched-eq$text){throw 'Invoke-Gcloud block replacement made no change.'}
    if($patched.Contains($OldBlock)){throw 'Original Invoke-Gcloud block survived replacement.'}
    [System.IO.File]::WriteAllText($DestinationPath,$patched,$Utf8NoBom)
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($DestinationPath,[ref]$tokens,[ref]$errors)
    if($errors.Count-gt0){throw ('Patched uploader failed parsing: '+(($errors|ForEach-Object{$_.Message})-join'; '))}
    return $ast
}

function Invoke-PatchedFunctionRegression {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $functions=@($Ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Gcloud'},$true))
    if($functions.Count-ne1){throw "Expected exactly one patched Invoke-Gcloud function; observed $($functions.Count)."}
    Invoke-Expression $functions[0].Extent.Text
    $cmd=$env:ComSpec
    if([string]::IsNullOrWhiteSpace($cmd)){throw 'ComSpec is unavailable for wrapper regression test.'}
    $r=Invoke-Gcloud $cmd @('/d','/c','exit','0')
    if($r.ExitCode-ne0){throw 'Zero-output wrapper regression returned nonzero.'}
    if($null-eq$r.Stdout -or $null-eq$r.Stderr){throw 'Wrapper regression returned null text property.'}
    if($r.Stdout-ne'' -or $r.Stderr-ne''){throw 'Zero-output wrapper regression returned unexpected text.'}
}

function Invoke-SelfTest {
    $root=Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gcs-v3-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    try{
        $src=Get-SourcePath
        $dst=Join-Path $root 'patched.ps1'
        $ast=New-PatchedArtifact $src $dst
        Invoke-PatchedFunctionRegression $ast
        $out=[System.IO.File]::ReadAllText($dst)
        if($out -notmatch [regex]::Escape('$stdoutText=[string]')){throw 'Patched stdout normalization missing.'}
        if($out -notmatch [regex]::Escape("`$stderrText=if(`$null-eq`$rawStderr){''}")){throw 'Patched stderr normalization missing.'}
        Write-Host 'SELF-TEST: PASS'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

$temp=Join-Path ([System.IO.Path]::GetTempPath()) ('Archive-CfaGdeltQ2ToGcs-patched-v3-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
    $source=Get-SourcePath
    $ast=New-PatchedArtifact $source $temp
    Invoke-PatchedFunctionRegression $ast
    Write-Host ('Patched archival artifact: '+$temp)
    Write-Host 'Invoke-Gcloud zero-output regression: PASS'
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
    exit $LASTEXITCODE
}catch{
    Write-Host 'CFA GDELT GCS ARCHIVE V3: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
