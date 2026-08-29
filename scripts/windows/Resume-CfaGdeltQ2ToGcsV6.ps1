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
    [ValidateRange(1,64)][int]$ProcessCount = 4,
    [ValidateRange(1,64)][int]$ThreadCount = 8,
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

$NewBlock = @'
function Invoke-Gcloud {
    param([string]$Gcloud,[string[]]$Arguments,[switch]$AllowNonzero)
    $err=[System.IO.Path]::GetTempFileName()
    try{
        $stdoutLines=@()
        $code=$null
        $oldInvokeEap=$ErrorActionPreference
        try{
            # Windows PowerShell 5.1 promotes native stderr records according to
            # ErrorActionPreference even when stderr is redirected. The wrapper
            # owns exit-code enforcement, so native invocation must be Continue.
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

function Get-SourcePath {
    $p=Join-Path $PSScriptRoot 'Resume-CfaGdeltQ2ToGcsV5.ps1'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "V5 resume source missing: $p"}
    return (Resolve-Path -LiteralPath $p).ProviderPath
}

function New-PatchedArtifact {
    param([string]$SourcePath,[string]$DestinationPath)
    $text=[System.IO.File]::ReadAllText($SourcePath)
    $matches=([regex]::Matches($text,[regex]::Escape($OldBlock))).Count
    if($matches-ne1){throw "Expected exactly one V5 Invoke-Gcloud block; observed $matches."}
    $patched=$text.Replace($OldBlock,$NewBlock)
    if($patched-eq$text){throw 'V6 native-stderr patch made no change.'}
    if($patched.Contains($OldBlock)){throw 'V5 native-stderr wrapper survived V6 patch.'}
    [System.IO.File]::WriteAllText($DestinationPath,$patched,$Utf8NoBom)
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($DestinationPath,[ref]$tokens,[ref]$errors)
    if($errors.Count-gt0){throw ('Patched V6 artifact failed parsing: '+(($errors|ForEach-Object{$_.Message})-join'; '))}
    return $ast
}

function Invoke-NativeStderrRegression {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $functions=@($Ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Gcloud'},$true))
    if($functions.Count-ne1){throw "Expected exactly one patched Invoke-Gcloud function; observed $($functions.Count)."}
    Invoke-Expression $functions[0].Extent.Text
    if([string]::IsNullOrWhiteSpace($env:ComSpec)){throw 'ComSpec unavailable for native stderr regression.'}

    $old=$ErrorActionPreference
    try{
        $ErrorActionPreference='Stop'
        $cmdArgs=@('/d','/c','echo expected-native-stderr 1>&2 & exit /b 7')
        $r=Invoke-Gcloud -Gcloud $env:ComSpec -Arguments $cmdArgs -AllowNonzero:$true
        if($r.ExitCode-ne7){throw "Native stderr regression exit mismatch: $($r.ExitCode)"}
        if($r.Stderr -notmatch 'expected-native-stderr'){throw 'Native stderr was not captured.'}

        $controlled=$false
        try{Invoke-Gcloud -Gcloud $env:ComSpec -Arguments $cmdArgs|Out-Null}
        catch{
            if($_.Exception.Message -match 'gcloud failed \(exit 7\)' -and $_.Exception.Message -match 'expected-native-stderr'){$controlled=$true}
            else{throw}
        }
        if(-not$controlled){throw 'Nonzero native stderr did not reach controlled wrapper failure.'}
    }finally{$ErrorActionPreference=$old}
}

function Invoke-SelfTest {
    $root=Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-gcs-v6-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    try{
        $src=Get-SourcePath
        $dst=Join-Path $root 'patched-v6.ps1'
        $ast=New-PatchedArtifact -SourcePath $src -DestinationPath $dst
        Invoke-NativeStderrRegression -Ast $ast
        $text=[System.IO.File]::ReadAllText($dst)
        if($text -notmatch [regex]::Escape("`$ErrorActionPreference='Continue'")){throw 'V6 native invocation EAP guard missing.'}
        if($text -notmatch [regex]::Escape("-AllowNonzero:`$true")){throw 'V6 missing expected nonzero probe call.'}
        Write-Host 'SELF-TEST: PASS'
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

if($SelfTest){
    try{Invoke-SelfTest;exit 0}
    catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
}

$temp=Join-Path ([System.IO.Path]::GetTempPath()) ('Resume-CfaGdeltQ2ToGcs-patched-v6-'+[guid]::NewGuid().ToString('N')+'.ps1')
try{
    $source=Get-SourcePath
    $ast=New-PatchedArtifact -SourcePath $source -DestinationPath $temp
    Invoke-NativeStderrRegression -Ast $ast
    Write-Host ('Patched resume artifact: '+$temp)
    Write-Host 'Native stderr + nonzero regression: PASS'

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
    Write-Host 'CFA GDELT GCS ARCHIVE RESUME V6: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}finally{
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
