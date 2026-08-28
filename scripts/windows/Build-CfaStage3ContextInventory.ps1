#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [string]$ArchiveRoot='',
    [string]$OutputRoot='',
    [ValidateRange(100,5000)][int]$BatchRows=500,
    [switch]$KeepHashShards,
    [switch]$ValidateInputsOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ExpectedFieldCount=27
$ExpectedArchives=7163
$ExpectedRows=9183757L
$ExpectedMalformedRows=5L
$ExpectedValidRows=9183752L
$RecordIdIndex=0;$DateIndex=1;$SourceIndex=3;$DocumentIndex=4;$ThemesIndex=8;$PersonsIndex=12;$OrganizationsIndex=14;$AllNamesIndex=23;$ExtrasIndex=26
$ContextSchemaVersion='CFA_STAGE3_CONTEXT_V1'
$UnbiasedTarget=15000
$NegativeTarget=15000
$EdgeTarget=10000
$Utf8=New-Object System.Text.UTF8Encoding($false)
$BroadAnchors=@(
    'bitcoin','ethereum','crypto','cryptocurrency','cryptocurrencies','blockchain','token','tokens',
    'stablecoin','stablecoins','defi','decentralized finance','web3','nft','nfts','digital asset','digital assets',
    'digital currency','digital currencies','staking','airdrop','airdrops','wallet','wallets','altcoin','altcoins',
    'memecoin','memecoins','crypto market','cryptocurrency market'
)

function Write-Utf8NoBom {
    param([string]$Path,[string]$Content)
    $parent=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
    [System.IO.File]::WriteAllText($Path,$Content,(New-Object System.Text.UTF8Encoding($false)))
}
function Csv {
    param([AllowNull()][object]$Value)
    $s=if($null-eq$Value){''}else{[string]$Value}
    if($s.Contains('"')){$s=$s.Replace('"','""')}
    if($s.Contains(',')-or$s.Contains('"')-or$s.Contains("`r")-or$s.Contains("`n")){return '"'+$s+'"'}
    return $s
}
function Write-CsvRow {
    param([System.IO.StreamWriter]$Writer,[object[]]$Values)
    $Writer.WriteLine((@($Values|ForEach-Object{Csv $_})-join','))
}
function Sha256Text {
    param([string]$Text)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try{return (($sha.ComputeHash($Utf8.GetBytes($Text))|ForEach-Object{$_.ToString('x2')})-join'')}
    finally{$sha.Dispose()}
}
function Get-PageTitle {
    param([string]$Extras)
    if([string]::IsNullOrWhiteSpace($Extras)){return ''}
    $m=[regex]::Match($Extras,'<PAGE_TITLE>(.*?)</PAGE_TITLE>',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not$m.Success){return ''}
    return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}
function Get-ContextHashInfo {
    param([string[]]$Fields)
    $b=New-Object System.Text.StringBuilder
    [void]$b.Append($ContextSchemaVersion).Append('|')
    foreach($field in $Fields){
        $s=if($null-eq$field){''}else{[string]$field}
        $n=$Utf8.GetByteCount($s)
        [void]$b.Append($n).Append(':').Append($s).Append('|')
    }
    $canonical=$b.ToString()
    return [pscustomobject]@{sha256=(Sha256Text $canonical);byte_length=$Utf8.GetByteCount($canonical)}
}
function Contains-Replacement {
    param([string[]]$Fields)
    foreach($s in $Fields){if($null-ne$s-and([string]$s).IndexOf([char]0xFFFD)-ge0){return $true}}
    return $false
}
function New-Rank {
    param([string]$Stratum,[string]$ArchiveFile,[long]$RowOrdinal,[string]$RecordId)
    return Sha256Text ($Stratum+'|'+$ArchiveFile+'|'+$RowOrdinal+'|'+$RecordId)
}
function Rank-Selected {
    param([string]$Rank,[int]$FirstByteExclusive)
    return ([Convert]::ToInt32($Rank.Substring(0,2),16)-lt$FirstByteExclusive)
}
function Build-DiscoveryTools {
    param([object[]]$AliasRows)
    $lookup=@{};$parts=@()
    foreach($r in $AliasRows){
        $alias=([string]$r.alias_text).Trim();$base=([string]$r.base_asset_id).Trim()
        if([string]::IsNullOrWhiteSpace($alias)-or[string]::IsNullOrWhiteSpace($base)){throw 'Discovery alias registry contains blank base_asset_id or alias_text.'}
        $norm=$alias.ToLowerInvariant()
        if(-not$lookup.ContainsKey($norm)){$lookup[$norm]=@{}}
        $lookup[$norm][$base]=$true
        $parts+=$alias
    }
    $uniqueParts=@($parts|Sort-Object -Unique|Sort-Object Length -Descending|ForEach-Object{[regex]::Escape($_)})
    $aliasRegex=if($uniqueParts.Count-gt0){New-Object System.Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:'+($uniqueParts-join'|')+')(?![\p{L}\p{N}])'),([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))}else{$null}
    $anchorParts=@($BroadAnchors|Sort-Object Length -Descending|ForEach-Object{[regex]::Escape($_)})
    $anchorRegex=New-Object System.Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:'+($anchorParts-join'|')+')(?![\p{L}\p{N}])'),([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant))
    return [pscustomobject]@{aliasLookup=$lookup;aliasRegex=$aliasRegex;anchorRegex=$anchorRegex;aliasRows=$AliasRows.Count}
}
function Get-DiscoverySignals {
    param([object]$Tools,[string]$Title,[string]$Url,[string]$Themes,[string]$Persons,[string]$Organizations,[string]$AllNames)
    $searchText=($Title+"`n"+$Url+"`n"+$Themes+"`n"+$Persons+"`n"+$Organizations+"`n"+$AllNames)
    $assets=@{};$aliases=@{}
    if($null-ne$Tools.aliasRegex){
        foreach($m in @($Tools.aliasRegex.Matches($searchText))){
            $norm=$m.Value.ToLowerInvariant()
            if($Tools.aliasLookup.ContainsKey($norm)){
                $aliases[$m.Value]=$true
                foreach($base in $Tools.aliasLookup[$norm].Keys){$assets[[string]$base]=$true}
            }
        }
    }
    $broad=$Tools.anchorRegex.IsMatch($searchText)
    return [pscustomobject]@{
        candidate=($broad-or$assets.Count-gt0)
        broad_anchor=$broad
        candidate_assets=(@($assets.Keys|Sort-Object)-join'|')
        candidate_aliases=(@($aliases.Keys|Sort-Object)-join'|')
        candidate_asset_count=$assets.Count
    }
}
function Open-CandidateWriter {
    param([string]$Path,[string[]]$Header)
    $w=New-Object System.IO.StreamWriter -ArgumentList $Path,$false,$Utf8
    Write-CsvRow $w $Header
    return $w
}
function Write-DiscoveryCandidate {
    param([System.IO.StreamWriter]$Writer,[string]$Stratum,[string]$Rank,[object]$Data)
    Write-CsvRow $Writer @(
        $Stratum,$Rank,$Data.lineage_key,$Data.context_sha256,$Data.context_byte_length,$Data.archive_file,$Data.archive_timestamp_utc,$Data.row_ordinal,
        $Data.record_id,$Data.gdelt_date_utc,$Data.source_common_name,$Data.document_identifier,$Data.page_title,$Data.themes_raw,
        $Data.persons_raw,$Data.organizations_raw,$Data.all_names_raw,$Data.extras_raw,$Data.context_replacement_present,
        $Data.discovery_candidate,$Data.discovery_broad_anchor,$Data.discovery_candidate_asset_count,$Data.discovery_candidate_asset_ids,$Data.discovery_candidate_aliases
    )
}
function Select-Stratum {
    param([string]$CandidatePath,[int]$Target,[System.Collections.Generic.HashSet[string]]$AlreadySelectedLineages,[System.IO.StreamWriter]$SelectionWriter,[string[]]$Header)
    $rows=@(Import-Csv -LiteralPath $CandidatePath|Sort-Object selection_rank)
    $selected=0
    foreach($r in $rows){
        if($selected-ge$Target){break}
        $lineage=[string]$r.lineage_key
        if(-not$AlreadySelectedLineages.Add($lineage)){continue}
        Write-CsvRow $SelectionWriter @($Header|ForEach-Object{$r.$_})
        $selected++
    }
    return $selected
}
function Build-ReadingPopulation {
    param([string]$SelectionPath,[string]$ReadingPath,[string]$OutputRoot,[int]$BatchRows)
    $readingHeader=@(
        'context_sha256','context_byte_length','selection_occurrence_count','selection_strata','representative_lineage_key','archive_file','archive_timestamp_utc','row_ordinal',
        'record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','themes_raw','persons_raw','organizations_raw','all_names_raw','extras_raw',
        'context_replacement_present','discovery_candidate','discovery_broad_anchor','discovery_candidate_asset_count','discovery_candidate_asset_ids','discovery_candidate_aliases'
    )
    $states=@{}
    foreach($r in @(Import-Csv -LiteralPath $SelectionPath)){
        $hash=[string]$r.context_sha256
        if(-not$states.ContainsKey($hash)){
            $states[$hash]=[pscustomobject]@{row=$r;count=0;strata=@{}}
        }
        $st=$states[$hash];$st.count=[int]$st.count+1;$st.strata[[string]$r.sample_stratum]=$true
    }
    $rw=Open-CandidateWriter $ReadingPath $readingHeader
    $manifest=@();$batchWriter=$null;$batchIndex=0;$batchCount=0;$batchStrata=@{};$batchFile=''
    try{
        foreach($hash in @($states.Keys|Sort-Object)){
            $st=$states[$hash];$r=$st.row;$strata=(@($st.strata.Keys|Sort-Object)-join'|')
            $values=@(
                $r.context_sha256,$r.context_byte_length,$st.count,$strata,$r.lineage_key,$r.archive_file,$r.archive_timestamp_utc,$r.row_ordinal,
                $r.record_id,$r.gdelt_date_utc,$r.source_common_name,$r.document_identifier,$r.page_title,$r.themes_raw,$r.persons_raw,$r.organizations_raw,$r.all_names_raw,$r.extras_raw,
                $r.context_replacement_present,$r.discovery_candidate,$r.discovery_broad_anchor,$r.discovery_candidate_asset_count,$r.discovery_candidate_asset_ids,$r.discovery_candidate_aliases
            )
            Write-CsvRow $rw $values
            if($null-eq$batchWriter-or$batchCount-ge$BatchRows){
                if($null-ne$batchWriter){
                    $batchWriter.Dispose();$bp=Join-Path $OutputRoot $batchFile
                    $manifest += [pscustomobject]@{file=$batchFile;rows=$batchCount;bytes=(Get-Item -LiteralPath $bp).Length;sha256=(Get-FileHash -LiteralPath $bp -Algorithm SHA256).Hash.ToLowerInvariant();stratum_counts=($batchStrata.GetEnumerator()|Sort-Object Name|ForEach-Object{$_.Name+'='+$_.Value})-join'|'}
                }
                $batchIndex++;$batchFile=('context-discovery-batch-{0:D4}.csv'-f$batchIndex);$batchWriter=Open-CandidateWriter (Join-Path $OutputRoot $batchFile) $readingHeader;$batchCount=0;$batchStrata=@{}
            }
            Write-CsvRow $batchWriter $values;$batchCount++
            foreach($ss in $st.strata.Keys){if(-not$batchStrata.ContainsKey($ss)){$batchStrata[$ss]=0};$batchStrata[$ss]=[int]$batchStrata[$ss]+1}
        }
    }finally{
        $rw.Dispose()
        if($null-ne$batchWriter){
            $batchWriter.Dispose();$bp=Join-Path $OutputRoot $batchFile
            $manifest += [pscustomobject]@{file=$batchFile;rows=$batchCount;bytes=(Get-Item -LiteralPath $bp).Length;sha256=(Get-FileHash -LiteralPath $bp -Algorithm SHA256).Hash.ToLowerInvariant();stratum_counts=($batchStrata.GetEnumerator()|Sort-Object Name|ForEach-Object{$_.Name+'='+$_.Value})-join'|'}
        }
    }
    return [pscustomobject]@{unique_contexts=$states.Count;manifest=$manifest;header=$readingHeader}
}
function Invoke-SelfTest {
    $x=Get-ContextHashInfo @('a','b','','c','','','','')
    $y=Get-ContextHashInfo @('a','b','','c','','','','')
    $z=Get-ContextHashInfo @('ab','','','c','','','','')
    if($x.sha256-ne$y.sha256-or$x.sha256-eq$z.sha256){throw 'context canonical hash'}
    if((Get-PageTitle 'x<PAGE_TITLE>Avalanche (AVAX) &amp; Bitcoin</PAGE_TITLE>y')-ne'Avalanche (AVAX) & Bitcoin'){throw 'page title parser'}
    $aliases=@([pscustomobject]@{base_asset_id='AVAX';alias_text='AVAX'},[pscustomobject]@{base_asset_id='KEY';alias_text='KEY'})
    $t=Build-DiscoveryTools $aliases
    $a=Get-DiscoverySignals $t 'Avalanche (AVAX) rises' '' '' '' '' ''
    if(-not$a.candidate-or$a.candidate_assets-notmatch'AVAX'){throw 'alias discovery cue'}
    $k=Get-DiscoverySignals $t 'KeyCorp (NYSE:KEY) stock update' '' '' '' '' ''
    if(-not$k.candidate-or$k.candidate_assets-notmatch'KEY'){throw 'retrieval must retain ambiguous candidate rather than semantically reject it'}
    $b=Get-DiscoverySignals $t 'New blockchain protocol launches' '' '' '' '' ''
    if(-not$b.candidate-or-not$b.broad_anchor){throw 'broad crypto discovery cue'}
    $n=Get-DiscoverySignals $t 'Local weather forecast' '' '' '' '' ''
    if($n.candidate){throw 'obvious non-candidate cue'}
    if(-not(Rank-Selected ('00'+'0'*62) 2)){throw 'rank selection lower boundary'}
    if(Rank-Selected ('02'+'0'*62) 2){throw 'rank selection upper boundary'}
    if((Csv 'a,b')-ne'"a,b"'){throw 'csv escaping'}
    if(-not(Contains-Replacement @('ok',([string][char]0xFFFD)))){throw 'replacement detection'}
    if((Get-PageTitle 'no title here')-ne''){throw 'missing page title'}
    Write-Host 'SELF-TEST: PASS'
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

$header=@(
    'sample_stratum','selection_rank','lineage_key','context_sha256','context_byte_length','archive_file','archive_timestamp_utc','row_ordinal',
    'record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','themes_raw','persons_raw','organizations_raw',
    'all_names_raw','extras_raw','context_replacement_present','discovery_candidate','discovery_broad_anchor','discovery_candidate_asset_count',
    'discovery_candidate_asset_ids','discovery_candidate_aliases'
)

try{
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if(-not(Test-Path -LiteralPath $aliasPath -PathType Leaf)){throw "Candidate alias registry missing: $aliasPath"}
    $aliasRows=@(Import-Csv -LiteralPath $aliasPath)
    if($aliasRows.Count-ne470){throw "Expected 470 candidate alias rows; observed $($aliasRows.Count)."}
    $tools=Build-DiscoveryTools $aliasRows
    if($ValidateInputsOnly){Write-Host ('CFA STAGE 3 CONTEXT INVENTORY INPUTS: PASS | aliases='+$tools.aliasRows+' | anchors='+$BroadAnchors.Count);exit 0}

    $documents=[Environment]::GetFolderPath('MyDocuments')
    if([string]::IsNullOrWhiteSpace($ArchiveRoot)){$ArchiveRoot=Join-Path $documents 'CFA-local\gdelt-gkg-q2-2025'}
    if(-not(Test-Path -LiteralPath $ArchiveRoot -PathType Container)){throw "GDELT archive root missing: $ArchiveRoot"}
    $ArchiveRoot=(Resolve-Path -LiteralPath $ArchiveRoot).ProviderPath
    if([string]::IsNullOrWhiteSpace($OutputRoot)){
        $parent=Join-Path $documents 'CFA-local\stage3-context-inventory'
        if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        $OutputRoot=Join-Path $parent ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
    }
    New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null
    $OutputRoot=(Resolve-Path -LiteralPath $OutputRoot).ProviderPath
    $tempRoot=Join-Path $OutputRoot '_temp'
    $hashRoot=Join-Path $tempRoot 'context-hash-shards'
    New-Item -ItemType Directory -Path $hashRoot -Force|Out-Null

    $files=@(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip'|Where-Object{$_.Name-match'^\d{14}\.gkg\.csv\.zip$'}|Sort-Object Name)
    if($files.Count-ne$ExpectedArchives){throw "Expected $ExpectedArchives downloaded GKG archives; observed $($files.Count)."}

    $unbiasedCandidates=Join-Path $tempRoot 'unbiased-candidates.csv'
    $negativeCandidates=Join-Path $tempRoot 'negative-candidates.csv'
    $edgeCandidates=Join-Path $tempRoot 'edge-candidates.csv'
    New-Item -ItemType Directory -Path $tempRoot -Force|Out-Null
    $uw=Open-CandidateWriter $unbiasedCandidates $header
    $nw=Open-CandidateWriter $negativeCandidates $header
    $ew=Open-CandidateWriter $edgeCandidates $header
    $shardWriters=@{}

    [long]$total=0;[long]$malformed=0;[long]$missingCritical=0;[long]$valid=0
    [long]$blankTitle=0;[long]$blankThemes=0;[long]$blankPersons=0;[long]$blankOrganizations=0;[long]$blankAllNames=0;[long]$blankSource=0
    [long]$replacementRows=0;[long]$discoveryCandidates=0;[long]$discoveryNegatives=0
    [long]$unbiasedOversample=0;[long]$negativeOversample=0;[long]$edgeOversample=0
    $archiveOrdinal=0
    $lenient=New-Object System.Text.UTF8Encoding($false,$false)

    try{
        foreach($file in $files){
            $archiveOrdinal++
            if($archiveOrdinal-eq1-or($archiveOrdinal%250)-eq0){Write-Host ("Context inventory archives: {0}/{1}"-f$archiveOrdinal,$files.Count)}
            $stamp=[datetime]::ParseExact($file.BaseName.Substring(0,14),'yyyyMMddHHmmss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
            $archiveTimestamp=$stamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture)
            $zip=$null
            try{
                $zip=[System.IO.Compression.ZipFile]::OpenRead($file.FullName)
                $entries=@($zip.Entries|Where-Object{-not[string]::IsNullOrWhiteSpace($_.Name)})
                if($entries.Count-ne1){throw "Expected one data entry in $($file.Name); observed $($entries.Count)."}
                $stream=$entries[0].Open();$reader=New-Object System.IO.StreamReader -ArgumentList $stream,$lenient,$false,65536,$false
                try{
                    [long]$rowOrdinal=0
                    while(($line=$reader.ReadLine())-ne$null){
                        $rowOrdinal++;$total++
                        $fields=$line.Split([char]9)
                        if($fields.Count-ne$ExpectedFieldCount){$malformed++;continue}
                        $recordId=[string]$fields[$RecordIdIndex];$date=[string]$fields[$DateIndex];$doc=[string]$fields[$DocumentIndex]
                        if([string]::IsNullOrWhiteSpace($recordId)-or$date-notmatch'^\d{14}$'-or[string]::IsNullOrWhiteSpace($doc)){$missingCritical++;continue}
                        $valid++
                        $source=[string]$fields[$SourceIndex];$themes=[string]$fields[$ThemesIndex];$persons=[string]$fields[$PersonsIndex];$orgs=[string]$fields[$OrganizationsIndex];$allNames=[string]$fields[$AllNamesIndex];$extras=[string]$fields[$ExtrasIndex]
                        $title=Get-PageTitle $extras
                        if([string]::IsNullOrWhiteSpace($title)){$blankTitle++};if([string]::IsNullOrWhiteSpace($themes)){$blankThemes++};if([string]::IsNullOrWhiteSpace($persons)){$blankPersons++};if([string]::IsNullOrWhiteSpace($orgs)){$blankOrganizations++};if([string]::IsNullOrWhiteSpace($allNames)){$blankAllNames++};if([string]::IsNullOrWhiteSpace($source)){$blankSource++}
                        $replacement=Contains-Replacement @($source,$doc,$title,$themes,$persons,$orgs,$allNames,$extras);if($replacement){$replacementRows++}
                        $h=Get-ContextHashInfo @($source,$doc,$title,$themes,$persons,$orgs,$allNames,$extras)
                        $shard=$h.sha256.Substring(0,2)
                        if(-not$shardWriters.ContainsKey($shard)){
                            $sp=Join-Path $hashRoot ($shard+'.txt')
                            $shardWriters[$shard]=New-Object System.IO.StreamWriter -ArgumentList $sp,$false,$Utf8
                        }
                        $shardWriters[$shard].WriteLine($h.sha256+"`t"+$h.byte_length)
                        $sig=Get-DiscoverySignals $tools $title $doc $themes $persons $orgs $allNames
                        if($sig.candidate){$discoveryCandidates++}else{$discoveryNegatives++}
                        $data=[pscustomobject]@{
                            lineage_key=($file.Name+'|'+$rowOrdinal+'|'+$recordId);context_sha256=$h.sha256;context_byte_length=$h.byte_length;archive_file=$file.Name;archive_timestamp_utc=$archiveTimestamp;row_ordinal=$rowOrdinal;
                            record_id=$recordId;gdelt_date_utc=$date;source_common_name=$source;document_identifier=$doc;page_title=$title;themes_raw=$themes;persons_raw=$persons;
                            organizations_raw=$orgs;all_names_raw=$allNames;extras_raw=$extras;context_replacement_present=$replacement;discovery_candidate=$sig.candidate;
                            discovery_broad_anchor=$sig.broad_anchor;discovery_candidate_asset_count=$sig.candidate_asset_count;discovery_candidate_asset_ids=$sig.candidate_assets;discovery_candidate_aliases=$sig.candidate_aliases
                        }
                        $uRank=New-Rank 'UNBIASED' $file.Name $rowOrdinal $recordId
                        if(Rank-Selected $uRank 2){Write-DiscoveryCandidate $uw 'UNBIASED' $uRank $data;$unbiasedOversample++}
                        if(-not$sig.candidate){
                            $nRank=New-Rank 'RETRIEVAL_NEGATIVE' $file.Name $rowOrdinal $recordId
                            if(Rank-Selected $nRank 2){Write-DiscoveryCandidate $nw 'RETRIEVAL_NEGATIVE' $nRank $data;$negativeOversample++}
                        }else{
                            $eRank=New-Rank 'ASSET_EDGE' $file.Name $rowOrdinal $recordId
                            if(Rank-Selected $eRank 64){Write-DiscoveryCandidate $ew 'ASSET_EDGE' $eRank $data;$edgeOversample++}
                        }
                    }
                }finally{$reader.Dispose()}
            }finally{if($null-ne$zip){$zip.Dispose()}}
        }
    }finally{
        $uw.Dispose();$nw.Dispose();$ew.Dispose()
        foreach($w in $shardWriters.Values){$w.Dispose()}
    }

    [long]$distinctContexts=0;[long]$repeatedContextRows=0;[long]$hashLengthCollisions=0
    foreach($sp in @(Get-ChildItem -LiteralPath $hashRoot -File -Filter '*.txt'|Sort-Object Name)){
        $seen=New-Object 'System.Collections.Generic.Dictionary[string,long]'
        foreach($hashLine in [System.IO.File]::ReadLines($sp.FullName)){
            $tab=$hashLine.IndexOf("`t");if($tab-le0){throw "Malformed hash-shard row in $($sp.Name)."}
            $hash=$hashLine.Substring(0,$tab);[long]$len=0;if(-not[long]::TryParse($hashLine.Substring($tab+1),[ref]$len)){throw "Malformed hash length in $($sp.Name)."}
            if($seen.ContainsKey($hash)){$repeatedContextRows++;if([long]$seen[$hash]-ne$len){$hashLengthCollisions++}}
            else{$seen[$hash]=$len;$distinctContexts++}
        }
    }

    $selectionPath=Join-Path $OutputRoot 'context-discovery-selection.csv'
    $selectionWriter=Open-CandidateWriter $selectionPath $header
    $selectedLineages=New-Object 'System.Collections.Generic.HashSet[string]'
    try{
        $selU=Select-Stratum $unbiasedCandidates $UnbiasedTarget $selectedLineages $selectionWriter $header
        $selN=Select-Stratum $negativeCandidates $NegativeTarget $selectedLineages $selectionWriter $header
        $selE=Select-Stratum $edgeCandidates $EdgeTarget $selectedLineages $selectionWriter $header
    }finally{$selectionWriter.Dispose()}

    $readingPath=Join-Path $OutputRoot 'context-discovery-reading.csv'
    $reading=Build-ReadingPopulation $selectionPath $readingPath $OutputRoot $BatchRows
    $manifestPath=Join-Path $OutputRoot 'context-discovery-batch-manifest.csv'
    $manifestWriter=New-Object System.IO.StreamWriter -ArgumentList $manifestPath,$false,$Utf8
    try{
        Write-CsvRow $manifestWriter @('batch_file','rows','bytes','sha256','stratum_counts')
        foreach($b in $reading.manifest){Write-CsvRow $manifestWriter @($b.file,$b.rows,$b.bytes,$b.sha256,$b.stratum_counts)}
    }finally{$manifestWriter.Dispose()}

    $sourceGate=if($total-eq$ExpectedRows-and$malformed-eq$ExpectedMalformedRows-and$valid-eq$ExpectedValidRows-and$missingCritical-eq0-and$hashLengthCollisions-eq0-and($distinctContexts+$repeatedContextRows)-eq$valid){'PASS'}else{'FAIL'}
    $sampleGate=if($selU-eq$UnbiasedTarget-and$selN-eq$NegativeTarget-and$selE-eq$EdgeTarget-and$selectedLineages.Count-eq($UnbiasedTarget+$NegativeTarget+$EdgeTarget)-and$reading.unique_contexts-gt0){'PASS'}else{'FAIL'}
    $runGate=if($sourceGate-eq'PASS'-and$sampleGate-eq'PASS'){'PASS'}else{'FAIL'}
    $summary=[ordered]@{
        run_status=$runGate
        gates=[ordered]@{'S3-CTX-001'='PASS';'S3-CTX-002'=$sourceGate;'S3-CTX-003'=$sampleGate;'S3-CTX-004'='BLOCKED';'S3-CTX-005'='BLOCKED';'S3-CTX-006'='BLOCKED';'S3-CTX-007'='BLOCKED';'S3-CTX-008'='BLOCKED'}
        source=[ordered]@{archive_files=$files.Count;rows_scanned=$total;malformed_field_count_rows=$malformed;missing_critical_rows=$missingCritical;valid_context_rows=$valid}
        context=[ordered]@{schema_version=$ContextSchemaVersion;distinct_context_sha256=$distinctContexts;repeated_context_rows=$repeatedContextRows;hash_length_collision_count=$hashLengthCollisions;replacement_present_rows=$replacementRows;blank_page_title_rows=$blankTitle;blank_themes_rows=$blankThemes;blank_persons_rows=$blankPersons;blank_organizations_rows=$blankOrganizations;blank_all_names_rows=$blankAllNames;blank_source_rows=$blankSource}
        discovery=[ordered]@{provisional_candidate_rows=$discoveryCandidates;provisional_negative_rows=$discoveryNegatives;unbiased_oversample_rows=$unbiasedOversample;negative_oversample_rows=$negativeOversample;edge_oversample_rows=$edgeOversample;selected_unbiased=$selU;selected_retrieval_negative=$selN;selected_asset_edge=$selE;selected_source_rows=$selectedLineages.Count;selected_unique_reading_contexts=$reading.unique_contexts;batch_rows=$BatchRows;batch_files=$reading.manifest.Count}
        outputs=[ordered]@{discovery_selection=$selectionPath;discovery_selection_sha256=(Get-FileHash -LiteralPath $selectionPath -Algorithm SHA256).Hash.ToLowerInvariant();discovery_reading=$readingPath;discovery_reading_sha256=(Get-FileHash -LiteralPath $readingPath -Algorithm SHA256).Hash.ToLowerInvariant();batch_manifest=$manifestPath;batch_manifest_sha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant();candidate_alias_registry_sha256=(Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $summaryPath=Join-Path $OutputRoot 'context-inventory-summary.json'
    Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
    $md=New-Object System.Text.StringBuilder
    [void]$md.AppendLine('# CFA Stage 3 Context Inventory Run');[void]$md.AppendLine('');[void]$md.AppendLine('- Run status: '+$runGate);[void]$md.AppendLine('- Archives: '+$files.Count);[void]$md.AppendLine('- Rows scanned: '+$total);[void]$md.AppendLine('- Valid context rows: '+$valid);[void]$md.AppendLine('- Malformed field-count rows: '+$malformed);[void]$md.AppendLine('- Distinct context SHA-256 keys: '+$distinctContexts);[void]$md.AppendLine('- Repeated context rows: '+$repeatedContextRows);[void]$md.AppendLine('- Provisional discovery candidates: '+$discoveryCandidates);[void]$md.AppendLine('- Provisional discovery negatives: '+$discoveryNegatives);[void]$md.AppendLine('- Selected discovery source rows: '+$selectedLineages.Count);[void]$md.AppendLine('- Unique contexts to read: '+$reading.unique_contexts);[void]$md.AppendLine('- Batch files: '+$reading.manifest.Count);[void]$md.AppendLine('');[void]$md.AppendLine('No asset identity, crypto relevance, event type, event direction, materiality, or event-cluster conclusion is emitted by this run.')
    Write-Utf8NoBom (Join-Path $OutputRoot 'context-inventory-summary.md') $md.ToString()

    if(-not$KeepHashShards){Remove-Item -LiteralPath $hashRoot -Recurse -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $unbiasedCandidates,$negativeCandidates,$edgeCandidates -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $tempRoot -PathType Container){$remaining=@(Get-ChildItem -LiteralPath $tempRoot -Force);if($remaining.Count-eq0){Remove-Item -LiteralPath $tempRoot -Force -ErrorAction SilentlyContinue}}

    Write-Host 'CFA STAGE 3 CONTEXT INVENTORY: COMPLETE'
    Write-Host ('Evidence directory: '+$OutputRoot)
    Write-Host ('Rows scanned: '+$total)
    Write-Host ('Distinct context keys: '+$distinctContexts)
    Write-Host ('Repeated context rows: '+$repeatedContextRows)
    Write-Host ('Provisional candidates: '+$discoveryCandidates)
    Write-Host ('Provisional negatives: '+$discoveryNegatives)
    Write-Host ('Discovery selected source rows: '+$selectedLineages.Count+' | unbiased='+$selU+' negative='+$selN+' edge='+$selE);Write-Host ('Unique contexts to read: '+$reading.unique_contexts)
    Write-Host ('S3-CTX-002 context inventory: '+$sourceGate)
    Write-Host ('S3-CTX-003 discovery population: '+$sampleGate)
    Write-Host 'S3-CTX-004 contextual adjudication: BLOCKED pending direct review'
    if($runGate-ne'PASS'){exit 2};exit 0
}catch{
    Write-Host 'CFA STAGE 3 CONTEXT INVENTORY: FAIL'
    Write-Host $_.Exception.Message
    if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace}
    exit 1
}
