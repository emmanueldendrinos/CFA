#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [string]$ArchiveRoot='',
    [string]$OutputRoot='',
    [ValidateRange(1,100)][int]$MaxSamplesPerAlias=12,
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedFieldCount=27
$RecordIdIndex=0
$DateIndex=1
$SourceCommonNameIndex=3
$DocumentIdentifierIndex=4
$AllNamesIndex=23

function Write-Utf8NoBom{param([string]$Path,[string]$Content);$p=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $p -PathType Container)){New-Item -ItemType Directory -Path $p -Force|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($Path,$Content,$e)}
function Normalize-Bool{param([object]$Value);$t=([string]$Value).Trim().ToLowerInvariant();if($t-eq'true'){return $true};if($t-eq'false'){return $false};throw "Malformed boolean: $Value"}
function Parse-AllNames{
    param([string]$Text)
    $result=@();$malformed=0
    if([string]::IsNullOrWhiteSpace($Text)){return [pscustomobject]@{items=$result;malformed=0}}
    foreach($block in @($Text -split ';')){
        if([string]::IsNullOrWhiteSpace($block)){continue}
        $comma=$block.LastIndexOf(',')
        if($comma -le 0 -or $comma -ge ($block.Length-1)){$malformed++;continue}
        $name=$block.Substring(0,$comma).Trim();$offsetText=$block.Substring($comma+1).Trim();$offset=0
        if([string]::IsNullOrWhiteSpace($name)-or-not[int]::TryParse($offsetText,[ref]$offset)){$malformed++;continue}
        $result += [pscustomobject]@{name=$name;offset=$offset}
    }
    return [pscustomobject]@{items=$result;malformed=$malformed}
}
function New-AliasState{param([object]$Row)
    return [pscustomobject]@{
        base_asset_id=[string]$Row.base_asset_id;alias_text=[string]$Row.alias_text;alias_type=[string]$Row.alias_type;requires_crypto_context=(Normalize-Bool $Row.requires_crypto_context);mapping_tier=[string]$Row.mapping_tier;
        mention_count=0L;document_count=0L;context_supported_document_count=0L;distinct_sources=@{};first_date='';last_date='';samples=New-Object System.Collections.ArrayList
    }
}
function Invoke-SelfTest{
    $p=Parse-AllNames -Text 'Bitcoin,10;World Cup,25;ACME,40';if($p.items.Count-ne3-or$p.malformed-ne0){throw 'allnames parser'};if($p.items[1].name-ne'World Cup'-or$p.items[1].offset-ne25){throw 'allnames values'}
    $bad=Parse-AllNames -Text 'Bitcoin,10;badblock';if($bad.malformed-ne1){throw 'malformed block'}
    if($AllNamesIndex-ne23-or$ExpectedFieldCount-ne27){throw 'schema constants'}
    Write-Host 'SELF-TEST: PASS'
}
if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;exit 1}}

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))};$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $docs=[Environment]::GetFolderPath('MyDocuments')
    if([string]::IsNullOrWhiteSpace($ArchiveRoot)){$ArchiveRoot=Join-Path $docs 'CFA-local\gdelt-gkg-q2-2025'};$ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){$OutputRoot=Join-Path $docs 'CFA-local\gdelt-alias-validation'};if(-not(Test-Path -LiteralPath $OutputRoot -PathType Container)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv';$aliases=@(Import-Csv -LiteralPath $aliasPath);if($aliases.Count-ne45){throw "Expected 45 aliases; observed $($aliases.Count)."}
    $states=@{};$lookup=@{};$contextFreeNames=@{}
    foreach($row in $aliases){$key=([string]$row.base_asset_id)+'|'+([string]$row.alias_text).ToLowerInvariant();if($states.ContainsKey($key)){throw "Duplicate alias key: $key"};$state=New-AliasState $row;$states[$key]=$state;$norm=([string]$row.alias_text).Trim().ToLowerInvariant();if(-not$lookup.ContainsKey($norm)){$lookup[$norm]=@()};$lookup[$norm]+=$key;if(-not$state.requires_crypto_context){$contextFreeNames[$norm]=$true}}
    $files=@(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip'|Where-Object{$_.Name-match'^\d{14}\.gkg\.csv\.zip$'}|Sort-Object Name);if($files.Count-ne7163){throw "Expected 7163 downloaded GKG archives from verified source receipt; observed $($files.Count)."}
    $archiveRows=@();$sampleRows=@();$totalRows=0L;$malformedFieldRows=0L;$malformedAllNames=0L;$utf8FailureArchives=0;$entryCountFailures=0
    $strictUtf8=New-Object System.Text.UTF8Encoding($false,$true)
    $archiveOrdinal=0
    foreach($file in $files){
        $archiveOrdinal++;if(($archiveOrdinal%250)-eq0){Write-Host ("Alias scan archives: {0}/{1}" -f $archiveOrdinal,$files.Count)}
        $zip=$null;$rowsThisArchive=0L;$malformedThisArchive=0L;$utf8Status='PASS';$entryStatus='PASS'
        try{
            $zip=[System.IO.Compression.ZipFile]::OpenRead($file.FullName);$entries=@($zip.Entries|Where-Object{-not[string]::IsNullOrWhiteSpace($_.Name)});if($entries.Count-ne1){$entryCountFailures++;$entryStatus='FAIL';continue}
            $stream=$entries[0].Open();$reader=$null
            try{
                $reader=New-Object System.IO.StreamReader($stream,$strictUtf8,$false,65536,$false)
                while(($line=$reader.ReadLine()) -ne $null){
                    $rowsThisArchive++;$totalRows++
                    $fields=$line.Split([char]9)
                    if($fields.Count-ne$ExpectedFieldCount){$malformedFieldRows++;$malformedThisArchive++;continue}
                    $parsed=Parse-AllNames -Text $fields[$AllNamesIndex];$malformedAllNames += [long]$parsed.malformed
                    if($parsed.items.Count-eq0){continue}
                    $matchedKeys=@{};$presentNames=@{}
                    foreach($item in $parsed.items){$norm=$item.name.ToLowerInvariant();$presentNames[$norm]=$true;if($lookup.ContainsKey($norm)){foreach($key in $lookup[$norm]){$state=$states[$key];$state.mention_count=[long]$state.mention_count+1;$matchedKeys[$key]=$true}}}
                    if($matchedKeys.Count-eq0){continue}
                    $hasContextAnchor=$false;foreach($n in $presentNames.Keys){if($contextFreeNames.ContainsKey($n)){$hasContextAnchor=$true;break}}
                    foreach($key in $matchedKeys.Keys){
                        $state=$states[$key];$state.document_count=[long]$state.document_count+1
                        if($state.requires_crypto_context -and $hasContextAnchor){$state.context_supported_document_count=[long]$state.context_supported_document_count+1}
                        $source=[string]$fields[$SourceCommonNameIndex];if(-not[string]::IsNullOrWhiteSpace($source)){$state.distinct_sources[$source]=$true}
                        $date=[string]$fields[$DateIndex];if([string]::IsNullOrWhiteSpace($state.first_date)-or$date-lt$state.first_date){$state.first_date=$date};if([string]::IsNullOrWhiteSpace($state.last_date)-or$date-gt$state.last_date){$state.last_date=$date}
                        if($state.samples.Count-lt$MaxSamplesPerAlias){[void]$state.samples.Add([pscustomobject]@{base_asset_id=$state.base_asset_id;alias_text=$state.alias_text;requires_crypto_context=$state.requires_crypto_context;record_id=[string]$fields[$RecordIdIndex];date_utc=$date;source_common_name=$source;document_identifier=[string]$fields[$DocumentIdentifierIndex];context_anchor_present=$hasContextAnchor})}
                    }
                }
            }catch[System.Text.DecoderFallbackException]{$utf8FailureArchives++;$utf8Status='FAIL'}finally{if($null-ne$reader){$reader.Dispose()}else{$stream.Dispose()}}
        }finally{if($null-ne$zip){$zip.Dispose()}}
        $archiveRows += [pscustomobject]@{archive_file=$file.Name;rows_scanned=$rowsThisArchive;malformed_field_count_rows=$malformedThisArchive;utf8_status=$utf8Status;entry_count_status=$entryStatus}
    }
    $aliasRows=@()
    foreach($key in @($states.Keys|Sort-Object)){
        $s=$states[$key];$semantic='UNVERIFIED_NOT_OBSERVED';if($s.document_count-gt0){if($s.requires_crypto_context){$semantic='UNVERIFIED_CONTEXT_RULE_REQUIRED'}else{$semantic='OBSERVED_EXACT_PROPER_NAME'}}
        $aliasRows += [pscustomobject]@{base_asset_id=$s.base_asset_id;alias_text=$s.alias_text;alias_type=$s.alias_type;requires_crypto_context=$s.requires_crypto_context;mapping_tier=$s.mapping_tier;mention_count=$s.mention_count;document_count=$s.document_count;context_supported_document_count=$s.context_supported_document_count;context_unsupported_document_count=([long]$s.document_count-[long]$s.context_supported_document_count);distinct_source_count=$s.distinct_sources.Count;first_date_utc=$s.first_date;last_date_utc=$s.last_date;semantic_observation_status=$semantic}
        foreach($sample in $s.samples){$sampleRows += $sample}
    }
    $run=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N');$dir=Join-Path $OutputRoot $run;New-Item -ItemType Directory -Path $dir -Force|Out-Null
    $aliasRows|Sort-Object base_asset_id,alias_text|Export-Csv -LiteralPath (Join-Path $dir 'alias-validation.csv') -NoTypeInformation -Encoding UTF8
    $sampleRows|Sort-Object base_asset_id,alias_text,date_utc|Export-Csv -LiteralPath (Join-Path $dir 'alias-samples.csv') -NoTypeInformation -Encoding UTF8
    $archiveRows|Export-Csv -LiteralPath (Join-Path $dir 'archive-scan.csv') -NoTypeInformation -Encoding UTF8
    $observed=@($aliasRows|Where-Object{$_.document_count-gt0}).Count;$notObserved=45-$observed;$contextRequired=@($aliasRows|Where-Object{$_.requires_crypto_context-eq'True'-or$_.requires_crypto_context-eq$true}).Count
    @([pscustomobject]@{run_id=$run;archive_files=$files.Count;rows_scanned=$totalRows;malformed_field_count_rows=$malformedFieldRows;malformed_allnames_blocks=$malformedAllNames;utf8_failure_archives=$utf8FailureArchives;entry_count_failures=$entryCountFailures;alias_rows=45;observed_aliases=$observed;not_observed_aliases=$notObserved;context_required_aliases=$contextRequired;allnames_field_position_1_based=24;expected_record_field_count=27})|Export-Csv -LiteralPath (Join-Path $dir 'validation-summary.csv') -NoTypeInformation -Encoding UTF8
    Write-Host "Evidence directory: $dir";Write-Host "Rows scanned: $totalRows";Write-Host "Observed aliases: $observed / 45";Write-Host "Malformed field-count rows: $malformedFieldRows";Write-Host "UTF-8 failure archives: $utf8FailureArchives";Write-Host 'CFA STAGE 2 ALIAS VALIDATION: COMPLETE'
    if($malformedFieldRows-gt0-or$utf8FailureArchives-gt0-or$entryCountFailures-gt0){exit 2}
}catch{Write-Host 'CFA STAGE 2 ALIAS VALIDATION: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}
