#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepoRoot='',
    [string]$ArchiveRoot='',
    [string]$OutputRoot='',
    [ValidateRange(100,5000)][int]$BatchRows=500,
    [ValidateRange(0,256)][int]$WorkerCount=0,
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
$ContextSchemaVersion='CFA_STAGE3_CONTEXT_V1'
$SamplingSchemaVersion='CFA_STAGE3_SAMPLE_V2'
$UnbiasedTarget=15000
$NegativeTarget=15000
$EdgeTarget=10000
$UnbiasedRankByteExclusive=2
$NegativeRankByteExclusive=2
$EdgeRankByteExclusive=32
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
function Open-CandidateWriter {
    param([string]$Path,[string[]]$Header)
    $w=New-Object System.IO.StreamWriter -ArgumentList $Path,$false,$Utf8
    Write-CsvRow $w $Header
    return $w
}
function Select-Stratum {
    param([string[]]$CandidatePaths,[int]$Target,[System.Collections.Generic.HashSet[string]]$AlreadySelectedLineages,[System.IO.StreamWriter]$SelectionWriter,[string[]]$Header)
    $rows=@(
        foreach($candidatePath in @($CandidatePaths|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object)){
            if(Test-Path -LiteralPath $candidatePath -PathType Leaf){
                Import-Csv -LiteralPath $candidatePath -Encoding UTF8
            }
        }
    )|Sort-Object selection_rank
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
    foreach($r in @(Import-Csv -LiteralPath $SelectionPath -Encoding UTF8)){
        $hash=[string]$r.context_sha256
        if(-not$states.ContainsKey($hash)){$states[$hash]=[pscustomobject]@{row=$r;count=0;strata=@{}}}
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

$CSharp=@'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace CfaStage3Context
{
    public sealed class ScanResult
    {
        public int LogicalProcessorCount;
        public int WorkerCount;
        public int ArchivesProcessed;
        public long TotalRows;
        public long MalformedRows;
        public long MissingCriticalRows;
        public long ValidRows;
        public long BlankTitleRows;
        public long BlankThemesRows;
        public long BlankPersonsRows;
        public long BlankOrganizationsRows;
        public long BlankAllNamesRows;
        public long BlankSourceRows;
        public long ReplacementRows;
        public long DiscoveryCandidates;
        public long DiscoveryNegatives;
        public long UnbiasedOversample;
        public long NegativeOversample;
        public long EdgeOversample;
        public double ElapsedSeconds;
        public double RowsPerSecond;
        public string[] UnbiasedCandidateFiles;
        public string[] NegativeCandidateFiles;
        public string[] EdgeCandidateFiles;
    }

    internal sealed class RowFields
    {
        public string RecordId;
        public string Date;
        public string Source;
        public string Document;
        public string Themes;
        public string Persons;
        public string Organizations;
        public string AllNames;
        public string Extras;
    }

    internal sealed class DiscoverySignals
    {
        public bool Candidate;
        public bool BroadAnchor;
        public string CandidateAssets;
        public string CandidateAliases;
        public int CandidateAssetCount;
    }

    internal sealed class WorkerSummary
    {
        public int Archives;
        public long TotalRows;
        public long MalformedRows;
        public long MissingCriticalRows;
        public long ValidRows;
        public long BlankTitleRows;
        public long BlankThemesRows;
        public long BlankPersonsRows;
        public long BlankOrganizationsRows;
        public long BlankAllNamesRows;
        public long BlankSourceRows;
        public long ReplacementRows;
        public long DiscoveryCandidates;
        public long DiscoveryNegatives;
        public long UnbiasedOversample;
        public long NegativeOversample;
        public long EdgeOversample;
        public string UnbiasedFile;
        public string NegativeFile;
        public string EdgeFile;
    }

    internal sealed class WorkerState : IDisposable
    {
        private readonly UTF8Encoding utf8 = new UTF8Encoding(false);
        public readonly SHA256 SamplingHasher = SHA256.Create();
        public readonly SHA256 ContextHasher = SHA256.Create();
        public readonly StreamWriter UnbiasedWriter;
        public readonly StreamWriter NegativeWriter;
        public readonly StreamWriter EdgeWriter;
        public readonly string UnbiasedFile;
        public readonly string NegativeFile;
        public readonly string EdgeFile;

        public int Archives;
        public long TotalRows;
        public long MalformedRows;
        public long MissingCriticalRows;
        public long ValidRows;
        public long BlankTitleRows;
        public long BlankThemesRows;
        public long BlankPersonsRows;
        public long BlankOrganizationsRows;
        public long BlankAllNamesRows;
        public long BlankSourceRows;
        public long ReplacementRows;
        public long DiscoveryCandidates;
        public long DiscoveryNegatives;
        public long UnbiasedOversample;
        public long NegativeOversample;
        public long EdgeOversample;

        public WorkerState(string tempRoot, int workerId, string header)
        {
            UnbiasedFile = Path.Combine(tempRoot, String.Format(CultureInfo.InvariantCulture, "worker-{0:D3}-unbiased.csv", workerId));
            NegativeFile = Path.Combine(tempRoot, String.Format(CultureInfo.InvariantCulture, "worker-{0:D3}-negative.csv", workerId));
            EdgeFile = Path.Combine(tempRoot, String.Format(CultureInfo.InvariantCulture, "worker-{0:D3}-edge.csv", workerId));
            UnbiasedWriter = new StreamWriter(UnbiasedFile, false, utf8, 65536);
            NegativeWriter = new StreamWriter(NegativeFile, false, utf8, 65536);
            EdgeWriter = new StreamWriter(EdgeFile, false, utf8, 65536);
            UnbiasedWriter.WriteLine(header);
            NegativeWriter.WriteLine(header);
            EdgeWriter.WriteLine(header);
        }

        public WorkerSummary ToSummary()
        {
            WorkerSummary s = new WorkerSummary();
            s.Archives = Archives;
            s.TotalRows = TotalRows;
            s.MalformedRows = MalformedRows;
            s.MissingCriticalRows = MissingCriticalRows;
            s.ValidRows = ValidRows;
            s.BlankTitleRows = BlankTitleRows;
            s.BlankThemesRows = BlankThemesRows;
            s.BlankPersonsRows = BlankPersonsRows;
            s.BlankOrganizationsRows = BlankOrganizationsRows;
            s.BlankAllNamesRows = BlankAllNamesRows;
            s.BlankSourceRows = BlankSourceRows;
            s.ReplacementRows = ReplacementRows;
            s.DiscoveryCandidates = DiscoveryCandidates;
            s.DiscoveryNegatives = DiscoveryNegatives;
            s.UnbiasedOversample = UnbiasedOversample;
            s.NegativeOversample = NegativeOversample;
            s.EdgeOversample = EdgeOversample;
            s.UnbiasedFile = UnbiasedFile;
            s.NegativeFile = NegativeFile;
            s.EdgeFile = EdgeFile;
            return s;
        }

        public void Dispose()
        {
            UnbiasedWriter.Dispose();
            NegativeWriter.Dispose();
            EdgeWriter.Dispose();
            SamplingHasher.Dispose();
            ContextHasher.Dispose();
        }
    }

    public static class ParallelScanner
    {
        private const string ContextSchemaVersion = "CFA_STAGE3_CONTEXT_V1";
        private const string SamplingSchemaVersion = "CFA_STAGE3_SAMPLE_V2";
        private const int UnbiasedRankByteExclusive = 2;
        private const int NegativeRankByteExclusive = 2;
        private const int EdgeRankByteExclusive = 32;
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        private static readonly object ProgressLock = new object();
        private static Regex AliasRegex;
        private static Regex AnchorRegex;
        private static Dictionary<string, string[]> AliasLookup;
        private static long GlobalRows;
        private static long GlobalArchives;
        private static long NextProgressRows;
        private static Stopwatch Clock;
        private static long ExpectedRowsForProgress;
        private static int ExpectedArchivesForProgress;
        private static int WorkerSequence;

        private const string Header = "sample_stratum,selection_rank,lineage_key,context_sha256,context_byte_length,archive_file,archive_timestamp_utc,row_ordinal,record_id,gdelt_date_utc,source_common_name,document_identifier,page_title,themes_raw,persons_raw,organizations_raw,all_names_raw,extras_raw,context_replacement_present,discovery_candidate,discovery_broad_anchor,discovery_candidate_asset_count,discovery_candidate_asset_ids,discovery_candidate_aliases";

        public static ScanResult Run(string[] archivePaths, string tempRoot, string[] aliasTexts, string[] baseAssetIds, string[] anchors, int workerCount, long expectedRows)
        {
            if (archivePaths == null || archivePaths.Length == 0) throw new ArgumentException("archivePaths");
            if (aliasTexts == null || baseAssetIds == null || aliasTexts.Length != baseAssetIds.Length) throw new ArgumentException("alias inputs");
            if (anchors == null || anchors.Length == 0) throw new ArgumentException("anchors");
            Directory.CreateDirectory(tempRoot);
            BuildTools(aliasTexts, baseAssetIds, anchors);

            int logical = Environment.ProcessorCount;
            int degree = workerCount <= 0 ? logical : workerCount;
            if (degree < 1) degree = 1;
            if (degree > 256) degree = 256;

            GlobalRows = 0;
            GlobalArchives = 0;
            NextProgressRows = 250000;
            ExpectedRowsForProgress = expectedRows;
            ExpectedArchivesForProgress = archivePaths.Length;
            WorkerSequence = 0;
            Clock = Stopwatch.StartNew();
            ConcurrentBag<WorkerSummary> summaries = new ConcurrentBag<WorkerSummary>();

            Console.WriteLine("Context inventory parallel: workers=" + degree.ToString(CultureInfo.InvariantCulture) +
                              " | logical_processors=" + logical.ToString(CultureInfo.InvariantCulture) +
                              " | archives=" + archivePaths.Length.ToString(CultureInfo.InvariantCulture));

            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = degree;

            Parallel.ForEach<string, WorkerState>(
                archivePaths,
                options,
                delegate
                {
                    int id = Interlocked.Increment(ref WorkerSequence);
                    return new WorkerState(tempRoot, id, Header);
                },
                delegate(string path, ParallelLoopState loopState, WorkerState local)
                {
                    ProcessArchive(path, local);
                    return local;
                },
                delegate(WorkerState local)
                {
                    WorkerSummary summary = local.ToSummary();
                    local.Dispose();
                    summaries.Add(summary);
                });

            Clock.Stop();
            ScanResult r = new ScanResult();
            r.LogicalProcessorCount = logical;
            r.WorkerCount = degree;
            List<string> u = new List<string>();
            List<string> n = new List<string>();
            List<string> e = new List<string>();

            foreach (WorkerSummary s in summaries)
            {
                r.ArchivesProcessed += s.Archives;
                r.TotalRows += s.TotalRows;
                r.MalformedRows += s.MalformedRows;
                r.MissingCriticalRows += s.MissingCriticalRows;
                r.ValidRows += s.ValidRows;
                r.BlankTitleRows += s.BlankTitleRows;
                r.BlankThemesRows += s.BlankThemesRows;
                r.BlankPersonsRows += s.BlankPersonsRows;
                r.BlankOrganizationsRows += s.BlankOrganizationsRows;
                r.BlankAllNamesRows += s.BlankAllNamesRows;
                r.BlankSourceRows += s.BlankSourceRows;
                r.ReplacementRows += s.ReplacementRows;
                r.DiscoveryCandidates += s.DiscoveryCandidates;
                r.DiscoveryNegatives += s.DiscoveryNegatives;
                r.UnbiasedOversample += s.UnbiasedOversample;
                r.NegativeOversample += s.NegativeOversample;
                r.EdgeOversample += s.EdgeOversample;
                u.Add(s.UnbiasedFile);
                n.Add(s.NegativeFile);
                e.Add(s.EdgeFile);
            }
            u.Sort(StringComparer.Ordinal);
            n.Sort(StringComparer.Ordinal);
            e.Sort(StringComparer.Ordinal);
            r.UnbiasedCandidateFiles = u.ToArray();
            r.NegativeCandidateFiles = n.ToArray();
            r.EdgeCandidateFiles = e.ToArray();
            r.ElapsedSeconds = Clock.Elapsed.TotalSeconds;
            r.RowsPerSecond = r.ElapsedSeconds > 0.0 ? ((double)r.TotalRows / r.ElapsedSeconds) : 0.0;
            return r;
        }

        private static void BuildTools(string[] aliasTexts, string[] baseAssetIds, string[] anchors)
        {
            Dictionary<string, HashSet<string>> tempLookup = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> uniqueAliases = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < aliasTexts.Length; i++)
            {
                string alias = (aliasTexts[i] ?? String.Empty).Trim();
                string baseId = (baseAssetIds[i] ?? String.Empty).Trim();
                if (alias.Length == 0 || baseId.Length == 0) throw new InvalidOperationException("Blank alias input.");
                uniqueAliases.Add(alias);
                HashSet<string> bases;
                if (!tempLookup.TryGetValue(alias, out bases))
                {
                    bases = new HashSet<string>(StringComparer.Ordinal);
                    tempLookup.Add(alias, bases);
                }
                bases.Add(baseId);
            }
            AliasLookup = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, HashSet<string>> kv in tempLookup)
            {
                string[] values = new string[kv.Value.Count];
                kv.Value.CopyTo(values);
                Array.Sort(values, StringComparer.Ordinal);
                AliasLookup.Add(kv.Key, values);
            }

            List<string> aliases = new List<string>(uniqueAliases);
            aliases.Sort(delegate(string a, string b)
            {
                int c = b.Length.CompareTo(a.Length);
                return c != 0 ? c : StringComparer.OrdinalIgnoreCase.Compare(a, b);
            });
            StringBuilder aliasPattern = new StringBuilder();
            aliasPattern.Append("(?<![\\p{L}\\p{N}])(?:");
            for (int i = 0; i < aliases.Count; i++)
            {
                if (i > 0) aliasPattern.Append("|");
                aliasPattern.Append(Regex.Escape(aliases[i]));
            }
            aliasPattern.Append(")(?![\\p{L}\\p{N}])");

            List<string> anchorList = new List<string>();
            for (int i = 0; i < anchors.Length; i++)
            {
                string value = (anchors[i] ?? String.Empty).Trim();
                if (value.Length > 0 && !anchorList.Contains(value)) anchorList.Add(value);
            }
            anchorList.Sort(delegate(string a, string b)
            {
                int c = b.Length.CompareTo(a.Length);
                return c != 0 ? c : StringComparer.OrdinalIgnoreCase.Compare(a, b);
            });
            StringBuilder anchorPattern = new StringBuilder();
            anchorPattern.Append("(?<![\\p{L}\\p{N}])(?:");
            for (int i = 0; i < anchorList.Count; i++)
            {
                if (i > 0) anchorPattern.Append("|");
                anchorPattern.Append(Regex.Escape(anchorList[i]));
            }
            anchorPattern.Append(")(?![\\p{L}\\p{N}])");

            RegexOptions opts = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled;
            AliasRegex = new Regex(aliasPattern.ToString(), opts);
            AnchorRegex = new Regex(anchorPattern.ToString(), opts);
        }

        private static void ProcessArchive(string path, WorkerState w)
        {
            string archiveName = Path.GetFileName(path);
            string stamp = archiveName.Substring(0, 14);
            DateTime dt = DateTime.ParseExact(stamp, "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
            string archiveTimestamp = dt.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
            long archiveRows = 0;

            using (ZipArchive zip = ZipFile.OpenRead(path))
            {
                ZipArchiveEntry entry = null;
                int entries = 0;
                foreach (ZipArchiveEntry candidate in zip.Entries)
                {
                    if (!String.IsNullOrWhiteSpace(candidate.Name))
                    {
                        entry = candidate;
                        entries++;
                    }
                }
                if (entries != 1 || entry == null) throw new InvalidDataException("Expected one data entry in " + archiveName + "; observed " + entries.ToString(CultureInfo.InvariantCulture) + ".");

                using (Stream entryStream = entry.Open())
                using (StreamReader reader = new StreamReader(entryStream, new UTF8Encoding(false, false), false, 65536))
                {
                    string line;
                    long rowOrdinal = 0;
                    while ((line = reader.ReadLine()) != null)
                    {
                        rowOrdinal++;
                        archiveRows++;
                        w.TotalRows++;

                        RowFields f;
                        if (!TryParseFields(line, out f))
                        {
                            w.MalformedRows++;
                            continue;
                        }
                        if (String.IsNullOrWhiteSpace(f.RecordId) || !IsFourteenDigits(f.Date) || String.IsNullOrWhiteSpace(f.Document))
                        {
                            w.MissingCriticalRows++;
                            continue;
                        }
                        w.ValidRows++;

                        string title = GetPageTitle(f.Extras);
                        if (String.IsNullOrWhiteSpace(title)) w.BlankTitleRows++;
                        if (String.IsNullOrWhiteSpace(f.Themes)) w.BlankThemesRows++;
                        if (String.IsNullOrWhiteSpace(f.Persons)) w.BlankPersonsRows++;
                        if (String.IsNullOrWhiteSpace(f.Organizations)) w.BlankOrganizationsRows++;
                        if (String.IsNullOrWhiteSpace(f.AllNames)) w.BlankAllNamesRows++;
                        if (String.IsNullOrWhiteSpace(f.Source)) w.BlankSourceRows++;

                        bool replacement = ContainsReplacement(f.Source, f.Document, title, f.Themes, f.Persons, f.Organizations, f.AllNames, f.Extras);
                        if (replacement) w.ReplacementRows++;

                        bool candidate = TestCandidate(title, f.Document, f.Themes, f.Persons, f.Organizations, f.AllNames);
                        if (candidate) w.DiscoveryCandidates++; else w.DiscoveryNegatives++;

                        byte[] rankBytes = ComputeSamplingRank(w.SamplingHasher, archiveName, rowOrdinal, f.RecordId);
                        bool uSelect = ((int)rankBytes[0] < UnbiasedRankByteExclusive);
                        bool nSelect = (!candidate && (int)rankBytes[1] < NegativeRankByteExclusive);
                        bool eSelect = (candidate && (int)rankBytes[2] < EdgeRankByteExclusive);
                        if (!(uSelect || nSelect || eSelect)) continue;

                        DiscoverySignals sig = GetSignals(title, f.Document, f.Themes, f.Persons, f.Organizations, f.AllNames);
                        if (sig.Candidate != candidate) throw new InvalidDataException("Fast/detailed discovery mismatch at " + archiveName + " row " + rowOrdinal.ToString(CultureInfo.InvariantCulture) + ".");
                        string contextHash;
                        int contextBytes;
                        ComputeContextHash(w.ContextHasher, f.Source, f.Document, title, f.Themes, f.Persons, f.Organizations, f.AllNames, f.Extras, out contextHash, out contextBytes);
                        string rankHex = BytesToHex(rankBytes);
                        string lineage = archiveName + "|" + rowOrdinal.ToString(CultureInfo.InvariantCulture) + "|" + f.RecordId;

                        if (uSelect)
                        {
                            WriteCandidate(w.UnbiasedWriter, "UNBIASED", rankHex, lineage, contextHash, contextBytes, archiveName, archiveTimestamp, rowOrdinal, f, title, replacement, sig);
                            w.UnbiasedOversample++;
                        }
                        if (nSelect)
                        {
                            WriteCandidate(w.NegativeWriter, "RETRIEVAL_NEGATIVE", RotateHex(rankHex, 1), lineage, contextHash, contextBytes, archiveName, archiveTimestamp, rowOrdinal, f, title, replacement, sig);
                            w.NegativeOversample++;
                        }
                        if (eSelect)
                        {
                            WriteCandidate(w.EdgeWriter, "ASSET_EDGE", RotateHex(rankHex, 2), lineage, contextHash, contextBytes, archiveName, archiveTimestamp, rowOrdinal, f, title, replacement, sig);
                            w.EdgeOversample++;
                        }
                    }
                }
            }

            w.Archives++;
            long rowsNow = Interlocked.Add(ref GlobalRows, archiveRows);
            long archivesNow = Interlocked.Increment(ref GlobalArchives);
            MaybeReport(rowsNow, archivesNow);
        }

        private static void MaybeReport(long rowsNow, long archivesNow)
        {
            lock (ProgressLock)
            {
                bool rowDue = rowsNow >= NextProgressRows;
                bool archiveDue = archivesNow == 1 || (archivesNow % 100) == 0 || archivesNow == ExpectedArchivesForProgress;
                if (!rowDue && !archiveDue) return;
                while (rowsNow >= NextProgressRows) NextProgressRows += 250000;
                double seconds = Clock.Elapsed.TotalSeconds;
                double rate = seconds > 0.0 ? ((double)rowsNow / seconds) : 0.0;
                Console.WriteLine("Context inventory progress: archives=" + archivesNow.ToString(CultureInfo.InvariantCulture) +
                                  "/" + ExpectedArchivesForProgress.ToString(CultureInfo.InvariantCulture) +
                                  " | rows=" + rowsNow.ToString(CultureInfo.InvariantCulture) +
                                  "/" + ExpectedRowsForProgress.ToString(CultureInfo.InvariantCulture) +
                                  " | " + Math.Round(rate, 1).ToString(CultureInfo.InvariantCulture) + " rows/sec");
            }
        }

        private static bool TryParseFields(string line, out RowFields f)
        {
            f = new RowFields();
            int column = 0;
            int start = 0;
            int length = line.Length;
            for (int i = 0; i <= length; i++)
            {
                if (i == length || line[i] == '\t')
                {
                    int len = i - start;
                    switch (column)
                    {
                        case 0: f.RecordId = line.Substring(start, len); break;
                        case 1: f.Date = line.Substring(start, len); break;
                        case 3: f.Source = line.Substring(start, len); break;
                        case 4: f.Document = line.Substring(start, len); break;
                        case 8: f.Themes = line.Substring(start, len); break;
                        case 12: f.Persons = line.Substring(start, len); break;
                        case 14: f.Organizations = line.Substring(start, len); break;
                        case 23: f.AllNames = line.Substring(start, len); break;
                        case 26: f.Extras = line.Substring(start, len); break;
                    }
                    column++;
                    start = i + 1;
                }
            }
            return column == 27;
        }

        private static bool IsFourteenDigits(string s)
        {
            if (s == null || s.Length != 14) return false;
            for (int i = 0; i < s.Length; i++) if (s[i] < '0' || s[i] > '9') return false;
            return true;
        }

        private static string GetPageTitle(string extras)
        {
            if (String.IsNullOrWhiteSpace(extras)) return String.Empty;
            const string open = "<PAGE_TITLE>";
            const string close = "</PAGE_TITLE>";
            int start = extras.IndexOf(open, StringComparison.OrdinalIgnoreCase);
            if (start < 0) return String.Empty;
            int contentStart = start + open.Length;
            int end = extras.IndexOf(close, contentStart, StringComparison.OrdinalIgnoreCase);
            if (end < contentStart) return String.Empty;
            return WebUtility.HtmlDecode(extras.Substring(contentStart, end - contentStart));
        }

        private static bool ContainsReplacement(params string[] values)
        {
            for (int i = 0; i < values.Length; i++)
            {
                string s = values[i];
                if (s != null && s.IndexOf('\uFFFD') >= 0) return true;
            }
            return false;
        }

        private static bool TestCandidate(params string[] values)
        {
            for (int i = 0; i < values.Length; i++)
            {
                string s = values[i];
                if (String.IsNullOrEmpty(s)) continue;
                if (AnchorRegex.IsMatch(s)) return true;
                if (AliasRegex.IsMatch(s)) return true;
            }
            return false;
        }

        private static DiscoverySignals GetSignals(string title, string url, string themes, string persons, string organizations, string allNames)
        {
            string searchText = String.Join("\n", new string[] { title ?? String.Empty, url ?? String.Empty, themes ?? String.Empty, persons ?? String.Empty, organizations ?? String.Empty, allNames ?? String.Empty });
            SortedSet<string> assets = new SortedSet<string>(StringComparer.Ordinal);
            SortedSet<string> aliases = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            MatchCollection matches = AliasRegex.Matches(searchText);
            foreach (Match m in matches)
            {
                string[] bases;
                if (AliasLookup.TryGetValue(m.Value, out bases))
                {
                    aliases.Add(m.Value);
                    for (int i = 0; i < bases.Length; i++) assets.Add(bases[i]);
                }
            }
            DiscoverySignals s = new DiscoverySignals();
            s.BroadAnchor = AnchorRegex.IsMatch(searchText);
            s.Candidate = s.BroadAnchor || assets.Count > 0;
            s.CandidateAssets = String.Join("|", new List<string>(assets).ToArray());
            s.CandidateAliases = String.Join("|", new List<string>(aliases).ToArray());
            s.CandidateAssetCount = assets.Count;
            return s;
        }

        private static byte[] ComputeSamplingRank(SHA256 hasher, string archiveName, long rowOrdinal, string recordId)
        {
            string canonical = SamplingSchemaVersion + "|" + archiveName + "|" + rowOrdinal.ToString(CultureInfo.InvariantCulture) + "|" + recordId;
            return hasher.ComputeHash(Utf8.GetBytes(canonical));
        }

        private static void ComputeContextHash(SHA256 hasher, string source, string document, string title, string themes, string persons, string organizations, string allNames, string extras, out string hash, out int byteLength)
        {
            string[] fields = new string[] { source, document, title, themes, persons, organizations, allNames, extras };
            StringBuilder b = new StringBuilder();
            b.Append(ContextSchemaVersion).Append("|");
            for (int i = 0; i < fields.Length; i++)
            {
                string s = fields[i] ?? String.Empty;
                int n = Utf8.GetByteCount(s);
                b.Append(n.ToString(CultureInfo.InvariantCulture)).Append(":").Append(s).Append("|");
            }
            byte[] bytes = Utf8.GetBytes(b.ToString());
            hash = BytesToHex(hasher.ComputeHash(bytes));
            byteLength = bytes.Length;
        }

        private static string BytesToHex(byte[] bytes)
        {
            return BitConverter.ToString(bytes).Replace("-", String.Empty).ToLowerInvariant();
        }

        private static string RotateHex(string hex, int byteOffset)
        {
            int chars = byteOffset * 2;
            if (chars <= 0) return hex;
            return hex.Substring(chars) + hex.Substring(0, chars);
        }

        private static void WriteCandidate(StreamWriter writer, string stratum, string rank, string lineage, string contextHash, int contextBytes, string archiveName, string archiveTimestamp, long rowOrdinal, RowFields f, string title, bool replacement, DiscoverySignals sig)
        {
            string[] values = new string[] {
                stratum,
                rank,
                lineage,
                contextHash,
                contextBytes.ToString(CultureInfo.InvariantCulture),
                archiveName,
                archiveTimestamp,
                rowOrdinal.ToString(CultureInfo.InvariantCulture),
                f.RecordId ?? String.Empty,
                f.Date ?? String.Empty,
                f.Source ?? String.Empty,
                f.Document ?? String.Empty,
                title ?? String.Empty,
                f.Themes ?? String.Empty,
                f.Persons ?? String.Empty,
                f.Organizations ?? String.Empty,
                f.AllNames ?? String.Empty,
                f.Extras ?? String.Empty,
                replacement.ToString(),
                sig.Candidate.ToString(),
                sig.BroadAnchor.ToString(),
                sig.CandidateAssetCount.ToString(CultureInfo.InvariantCulture),
                sig.CandidateAssets ?? String.Empty,
                sig.CandidateAliases ?? String.Empty
            };
            WriteCsvRow(writer, values);
        }

        private static void WriteCsvRow(StreamWriter writer, string[] values)
        {
            for (int i = 0; i < values.Length; i++)
            {
                if (i > 0) writer.Write(',');
                writer.Write(Csv(values[i]));
            }
            writer.WriteLine();
        }

        private static string Csv(string value)
        {
            string s = value ?? String.Empty;
            bool quote = s.IndexOf(',') >= 0 || s.IndexOf('"') >= 0 || s.IndexOf('\r') >= 0 || s.IndexOf('\n') >= 0;
            if (s.IndexOf('"') >= 0) s = s.Replace("\"", "\"\"");
            return quote ? "\"" + s + "\"" : s;
        }
    }
}
'@

function Install-ParallelScanner {
    if('CfaStage3Context.ParallelScanner' -as [type]){return}
    $refs=@(
        [System.IO.Compression.ZipArchive].Assembly.Location,
        [System.IO.Compression.ZipFile].Assembly.Location,
        [System.Threading.Tasks.Parallel].Assembly.Location,
        [System.Net.WebUtility].Assembly.Location
    )|Where-Object{-not[string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique
    Add-Type -TypeDefinition $CSharp -Language CSharp -ReferencedAssemblies $refs
}

function New-SyntheticGkgArchive {
    param([string]$Path,[int]$Seed,[int]$Rows)
    $dir=Split-Path -Parent $Path
    if(-not(Test-Path -LiteralPath $dir -PathType Container)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
    $fs=[System.IO.File]::Open($Path,[System.IO.FileMode]::Create,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    $zip=New-Object System.IO.Compression.ZipArchive -ArgumentList $fs,[System.IO.Compression.ZipArchiveMode]::Create,$false
    try{
        $entry=$zip.CreateEntry(([System.IO.Path]::GetFileNameWithoutExtension($Path)+'.csv'),[System.IO.Compression.CompressionLevel]::Fastest)
        $writer=New-Object System.IO.StreamWriter -ArgumentList $entry.Open(),$Utf8
        try{
            foreach($i in 1..$Rows){
                $f=New-Object string[] 27
                $f[0]="r-$Seed-$i";$f[1]='20250401000000';$f[3]='example.test';$f[4]="https://example.test/$Seed/$i"
                if(($i%3)-eq0){
                    $f[8]='ECON_BITCOIN';$f[23]='Avalanche';$f[26]='<PAGE_TITLE>Avalanche (AVAX) and Bitcoin update</PAGE_TITLE>'
                }elseif(($i%5)-eq0){
                    $f[14]='KeyCorp';$f[23]='KeyCorp';$f[26]='<PAGE_TITLE>KeyCorp (NYSE:KEY) stock update</PAGE_TITLE>'
                }else{
                    $f[26]='<PAGE_TITLE>Local weather forecast</PAGE_TITLE>'
                }
                $writer.WriteLine(($f-join"`t"))
            }
        }finally{$writer.Dispose()}
    }finally{$zip.Dispose();$fs.Dispose()}
}
function Get-CandidateSignature {
    param([string[]]$Paths)
    return (@(
        foreach($p in @($Paths|Sort-Object)){
            if(Test-Path -LiteralPath $p -PathType Leaf){Import-Csv -LiteralPath $p -Encoding UTF8}
        }
    )|Sort-Object sample_stratum,selection_rank,lineage_key|ForEach-Object{
        ([string]$_.sample_stratum)+'|'+([string]$_.selection_rank)+'|'+([string]$_.lineage_key)+'|'+([string]$_.context_sha256)
    })-join"`n"
}
function Invoke-SelfTest {
    Install-ParallelScanner
    $root=Join-Path ([System.IO.Path]::GetTempPath()) ('cfa-context-parallel-'+[guid]::NewGuid().ToString('N'))
    $source=Join-Path $root 'source';$out1=Join-Path $root 'one';$outN=Join-Path $root 'many'
    New-Item -ItemType Directory -Path $source,$out1,$outN -Force|Out-Null
    try{
        $paths=@()
        foreach($n in 0..11){
            $name=([datetime]::new(2025,4,1,0,0,0,[DateTimeKind]::Utc).AddMinutes(15*$n).ToString('yyyyMMddHHmmss'))+'.gkg.csv.zip'
            $p=Join-Path $source $name;New-SyntheticGkgArchive $p ($n+1) 200;$paths+=$p
        }
        $aliases=@('AVAX','KEY');$bases=@('AVAX','KEY')
        $one=[CfaStage3Context.ParallelScanner]::Run($paths,$out1,$aliases,$bases,$BroadAnchors,1,2400)
        $manyWorkers=[math]::Min(4,[Environment]::ProcessorCount);if($manyWorkers-lt1){$manyWorkers=1}
        $many=[CfaStage3Context.ParallelScanner]::Run($paths,$outN,$aliases,$bases,$BroadAnchors,$manyWorkers,2400)
        foreach($prop in @('ArchivesProcessed','TotalRows','MalformedRows','MissingCriticalRows','ValidRows','DiscoveryCandidates','DiscoveryNegatives','UnbiasedOversample','NegativeOversample','EdgeOversample')){
            if([string]$one.$prop-ne[string]$many.$prop){throw "parallel counter determinism: $prop"}
        }
        if($one.TotalRows-ne2400-or$one.ValidRows-ne2400-or$one.ArchivesProcessed-ne12){throw 'parallel synthetic source accounting'}
        $sig1=(Get-CandidateSignature (@($one.UnbiasedCandidateFiles)+@($one.NegativeCandidateFiles)+@($one.EdgeCandidateFiles)))
        $sigN=(Get-CandidateSignature (@($many.UnbiasedCandidateFiles)+@($many.NegativeCandidateFiles)+@($many.EdgeCandidateFiles)))
        if($sig1-ne$sigN){throw 'parallel candidate-set determinism'}
        Write-Host ('SELF-TEST: PASS | logical_processors='+[Environment]::ProcessorCount+' | parallel_workers_tested='+$manyWorkers)
    }finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}

if($SelfTest){try{Invoke-SelfTest;exit 0}catch{Write-Host 'SELF-TEST: FAIL';Write-Host $_.Exception.Message;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace};exit 1}}

$header=@(
    'sample_stratum','selection_rank','lineage_key','context_sha256','context_byte_length','archive_file','archive_timestamp_utc','row_ordinal',
    'record_id','gdelt_date_utc','source_common_name','document_identifier','page_title','themes_raw','persons_raw','organizations_raw',
    'all_names_raw','extras_raw','context_replacement_present','discovery_candidate','discovery_broad_anchor','discovery_candidate_asset_count',
    'discovery_candidate_asset_ids','discovery_candidate_aliases'
)

try{
    Install-ParallelScanner
    if([string]::IsNullOrWhiteSpace($RepoRoot)){$RepoRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))}
    $RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $aliasPath=Join-Path $RepoRoot 'candidate-analysis\CFA-Stage3-News-Aliases.csv'
    if(-not(Test-Path -LiteralPath $aliasPath -PathType Leaf)){throw "Candidate alias registry missing: $aliasPath"}
    $aliasRows=@(Import-Csv -LiteralPath $aliasPath -Encoding UTF8)
    if($aliasRows.Count-ne470){throw "Expected 470 candidate alias rows; observed $($aliasRows.Count)."}
    $aliasTexts=@($aliasRows|ForEach-Object{([string]$_.alias_text).Trim()})
    $baseIds=@($aliasRows|ForEach-Object{([string]$_.base_asset_id).Trim()})
    $effectiveWorkers=if($WorkerCount-le0){[Environment]::ProcessorCount}else{$WorkerCount}
    if($ValidateInputsOnly){
        Write-Host ('CFA STAGE 3 CONTEXT INVENTORY INPUTS: PASS | aliases='+$aliasRows.Count+' | anchors='+$BroadAnchors.Count+' | sampling='+$SamplingSchemaVersion+' | logical_processors='+[Environment]::ProcessorCount+' | workers='+$effectiveWorkers)
        exit 0
    }

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
    New-Item -ItemType Directory -Path $tempRoot -Force|Out-Null

    $files=@(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Filter '*.gkg.csv.zip'|Where-Object{$_.Name-match'^\d{14}\.gkg\.csv\.zip$'}|Sort-Object Name)
    if($files.Count-ne$ExpectedArchives){throw "Expected $ExpectedArchives downloaded GKG archives; observed $($files.Count)."}

    $scan=[CfaStage3Context.ParallelScanner]::Run(@($files.FullName),$tempRoot,$aliasTexts,$baseIds,$BroadAnchors,$effectiveWorkers,$ExpectedRows)
    if($scan.ArchivesProcessed-ne$ExpectedArchives){throw "Parallel scanner processed $($scan.ArchivesProcessed) archives, expected $ExpectedArchives."}

    $selectionPath=Join-Path $OutputRoot 'context-discovery-selection.csv'
    $selectionWriter=Open-CandidateWriter $selectionPath $header
    $selectedLineages=New-Object 'System.Collections.Generic.HashSet[string]'
    try{
        $selU=Select-Stratum @($scan.UnbiasedCandidateFiles) $UnbiasedTarget $selectedLineages $selectionWriter $header
        $selN=Select-Stratum @($scan.NegativeCandidateFiles) $NegativeTarget $selectedLineages $selectionWriter $header
        $selE=Select-Stratum @($scan.EdgeCandidateFiles) $EdgeTarget $selectedLineages $selectionWriter $header
    }finally{$selectionWriter.Dispose()}

    $readingPath=Join-Path $OutputRoot 'context-discovery-reading.csv'
    $reading=Build-ReadingPopulation $selectionPath $readingPath $OutputRoot $BatchRows
    $manifestPath=Join-Path $OutputRoot 'context-discovery-batch-manifest.csv'
    $manifestWriter=New-Object System.IO.StreamWriter -ArgumentList $manifestPath,$false,$Utf8
    try{
        Write-CsvRow $manifestWriter @('batch_file','rows','bytes','sha256','stratum_counts')
        foreach($b in $reading.manifest){Write-CsvRow $manifestWriter @($b.file,$b.rows,$b.bytes,$b.sha256,$b.stratum_counts)}
    }finally{$manifestWriter.Dispose()}

    $sourceGate=if($scan.TotalRows-eq$ExpectedRows-and$scan.MalformedRows-eq$ExpectedMalformedRows-and$scan.ValidRows-eq$ExpectedValidRows-and$scan.MissingCriticalRows-eq0){'PASS'}else{'FAIL'}
    $sampleGate=if($selU-eq$UnbiasedTarget-and$selN-eq$NegativeTarget-and$selE-eq$EdgeTarget-and$selectedLineages.Count-eq($UnbiasedTarget+$NegativeTarget+$EdgeTarget)-and$reading.unique_contexts-gt0){'PASS'}else{'FAIL'}
    $runGate=if($sourceGate-eq'PASS'-and$sampleGate-eq'PASS'){'PASS'}else{'FAIL'}
    $summary=[ordered]@{
        run_status=$runGate
        gates=[ordered]@{'S3-CTX-001'='PASS';'S3-CTX-002'=$sourceGate;'S3-CTX-003'=$sampleGate;'S3-CTX-004'='BLOCKED';'S3-CTX-005'='BLOCKED';'S3-CTX-006'='BLOCKED';'S3-CTX-007'='BLOCKED';'S3-CTX-008'='BLOCKED'}
        execution=[ordered]@{logical_processor_count=$scan.LogicalProcessorCount;worker_count=$scan.WorkerCount;scan_elapsed_seconds=[math]::Round($scan.ElapsedSeconds,3);scan_rows_per_second=[math]::Round($scan.RowsPerSecond,2)}
        source=[ordered]@{archive_files=$files.Count;archives_processed=$scan.ArchivesProcessed;rows_scanned=$scan.TotalRows;malformed_field_count_rows=$scan.MalformedRows;missing_critical_rows=$scan.MissingCriticalRows;valid_context_rows=$scan.ValidRows}
        context=[ordered]@{schema_version=$ContextSchemaVersion;global_context_cardinality_status='NOT_APPLICABLE';selected_unique_context_sha256=$reading.unique_contexts;selected_repeated_occurrences=($selectedLineages.Count-$reading.unique_contexts);replacement_present_rows=$scan.ReplacementRows;blank_page_title_rows=$scan.BlankTitleRows;blank_themes_rows=$scan.BlankThemesRows;blank_persons_rows=$scan.BlankPersonsRows;blank_organizations_rows=$scan.BlankOrganizationsRows;blank_all_names_rows=$scan.BlankAllNamesRows;blank_source_rows=$scan.BlankSourceRows}
        discovery=[ordered]@{sampling_schema_version=$SamplingSchemaVersion;provisional_candidate_rows=$scan.DiscoveryCandidates;provisional_negative_rows=$scan.DiscoveryNegatives;unbiased_oversample_rows=$scan.UnbiasedOversample;negative_oversample_rows=$scan.NegativeOversample;edge_oversample_rows=$scan.EdgeOversample;selected_unbiased=$selU;selected_retrieval_negative=$selN;selected_asset_edge=$selE;selected_source_rows=$selectedLineages.Count;selected_unique_reading_contexts=$reading.unique_contexts;batch_rows=$BatchRows;batch_files=$reading.manifest.Count}
        outputs=[ordered]@{discovery_selection=$selectionPath;discovery_selection_sha256=(Get-FileHash -LiteralPath $selectionPath -Algorithm SHA256).Hash.ToLowerInvariant();discovery_reading=$readingPath;discovery_reading_sha256=(Get-FileHash -LiteralPath $readingPath -Algorithm SHA256).Hash.ToLowerInvariant();batch_manifest=$manifestPath;batch_manifest_sha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant();candidate_alias_registry_sha256=(Get-FileHash -LiteralPath $aliasPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $summaryPath=Join-Path $OutputRoot 'context-inventory-summary.json'
    Write-Utf8NoBom $summaryPath (($summary|ConvertTo-Json -Depth 10)+[Environment]::NewLine)
    $md=New-Object System.Text.StringBuilder
    [void]$md.AppendLine('# CFA Stage 3 Context Inventory Run');[void]$md.AppendLine('')
    [void]$md.AppendLine('- Run status: '+$runGate)
    [void]$md.AppendLine('- Logical processors: '+$scan.LogicalProcessorCount)
    [void]$md.AppendLine('- Scan workers: '+$scan.WorkerCount)
    [void]$md.AppendLine('- Archives: '+$files.Count)
    [void]$md.AppendLine('- Rows scanned: '+$scan.TotalRows)
    [void]$md.AppendLine('- Valid context rows: '+$scan.ValidRows)
    [void]$md.AppendLine('- Malformed field-count rows: '+$scan.MalformedRows)
    [void]$md.AppendLine('- Scan rows/sec: '+([math]::Round($scan.RowsPerSecond,2)))
    [void]$md.AppendLine('- Provisional discovery candidates: '+$scan.DiscoveryCandidates)
    [void]$md.AppendLine('- Provisional discovery negatives: '+$scan.DiscoveryNegatives)
    [void]$md.AppendLine('- Selected discovery source rows: '+$selectedLineages.Count)
    [void]$md.AppendLine('- Unique selected contexts to read: '+$reading.unique_contexts)
    [void]$md.AppendLine('- Batch files: '+$reading.manifest.Count)
    [void]$md.AppendLine('')
    [void]$md.AppendLine('No asset identity, crypto relevance, event type, event direction, materiality, or event-cluster conclusion is emitted by this run.')
    Write-Utf8NoBom (Join-Path $OutputRoot 'context-inventory-summary.md') $md.ToString()

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host 'CFA STAGE 3 CONTEXT INVENTORY: COMPLETE'
    Write-Host ('Evidence directory: '+$OutputRoot)
    Write-Host ('Logical processors: '+$scan.LogicalProcessorCount+' | workers='+$scan.WorkerCount)
    Write-Host ('Rows scanned: '+$scan.TotalRows+' | rows/sec='+([math]::Round($scan.RowsPerSecond,2)))
    Write-Host ('Provisional candidates: '+$scan.DiscoveryCandidates)
    Write-Host ('Provisional negatives: '+$scan.DiscoveryNegatives)
    Write-Host ('Discovery selected source rows: '+$selectedLineages.Count+' | unbiased='+$selU+' negative='+$selN+' edge='+$selE)
    Write-Host ('Unique selected contexts to read: '+$reading.unique_contexts)
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
