// Q1-MKT-001: C# 5 / .NET Framework 4.5 and PowerShell 7 compatible.
// Exact decimal canonicalization and read-only, bounded source reconciliation.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace CfaQ1Reconciliation
{
    public sealed class MemberBinding
    {
        public string member_path;
        public string pair_code;
        public long pair_id;
        public string sha256;
        public long length_bytes;
        public long rows;
        public long min_epoch;
        public long max_epoch;
    }

    public sealed class ArchiveResult
    {
        public string status = "PASS";
        public long row_count;
        public long member_count;
        public long archive_member_count;
        public long day_count;
        public string canonicalization = MarketReconciler.Canonicalization;
    }

    public sealed class ComparisonResult
    {
        public string status = "PASS";
        public long source_day_count;
        public long database_day_count;
        public long matched_day_count;
        public long mismatched_day_count;
        public long missing_day_count;
        public long extra_day_count;
        public long source_row_count;
        public long database_row_count;
        public long matched_row_count;
        public long mismatched_row_count;
        public long mismatched_source_row_count;
        public long mismatched_database_row_count;
        public long missing_row_count;
        public long extra_row_count;
        public string canonicalization = MarketReconciler.Canonicalization;
    }

    public static class MarketReconciler
    {
        public const string Canonicalization = "cfa.ohlcvt.binary52/v1";
        private const long StartEpoch = 1767225600L;
        private const long EndEpoch = 1775001600L;
        private const int MaximumLineBytes = 4096;
        private const string DigestHeader = "pair_id\tday_utc\trows\tmin_epoch\tmax_epoch\tsha256";
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
        private static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        private static readonly byte[] Empty = new byte[0];
        private static readonly BigInteger[] PowersOfTen = MakePowers();

        private static InvalidDataException Invalid(string reason) { return new InvalidDataException("Q1-MKT-001:" + reason); }
        private static bool Fatal(Exception e) { return e is OutOfMemoryException || e is StackOverflowException || e is AccessViolationException; }
        private static string Count(long value) { return value.ToString(Invariant); }
        private static bool Digit(char c) { return c >= '0' && c <= '9'; }
        private static BigInteger[] MakePowers()
        {
            BigInteger[] values = new BigInteger[65];
            values[0] = BigInteger.One;
            for (int i = 1; i < values.Length; i++) values[i] = values[i - 1] * 10;
            return values;
        }
        private static BigInteger PowerOfTen(int exponent)
        {
            if (exponent < 0 || exponent > MaximumLineBytes + 400) throw Invalid("decimal_scale_out_of_range");
            return exponent < PowersOfTen.Length ? PowersOfTen[exponent] : BigInteger.Pow(10, exponent);
        }

        private sealed class Number
        {
            internal ulong bits;
            internal string digits;
            internal int scale;
            internal bool negative;
            internal bool IsZero { get { return digits.Length == 0; } }
        }

        private sealed class NumberParser
        {
            // Bound memory independently of the population. Repeated prices are common;
            // values are cached only after the complete strict grammar has been checked.
            private readonly Dictionary<string, Number> cache = new Dictionary<string, Number>(StringComparer.Ordinal);
            internal Number Parse(string text)
            {
                if (String.IsNullOrEmpty(text) || text.Length > MaximumLineBytes) throw Invalid("invalid_decimal_token");
                Number result;
                if (cache.TryGetValue(text, out result)) return result;
                result = ParseUncached(text);
                if (cache.Count >= 65536) cache.Clear();
                cache.Add(text, result);
                return result;
            }

            private static Number ParseUncached(string text)
            {
                int index = 0;
                bool negative = false;
                if (text[index] == '+' || text[index] == '-') { negative = text[index] == '-'; index++; }
                StringBuilder significant = new StringBuilder(text.Length);
                int digitCount = 0, fractionalDigits = 0;
                while (index < text.Length && Digit(text[index])) { significant.Append(text[index++]); digitCount++; }
                if (index < text.Length && text[index] == '.')
                {
                    index++;
                    while (index < text.Length && Digit(text[index])) { significant.Append(text[index++]); digitCount++; fractionalDigits++; }
                }
                if (digitCount == 0) throw Invalid("invalid_decimal_token");
                int exponent = 0;
                if (index < text.Length && (text[index] == 'e' || text[index] == 'E'))
                {
                    index++;
                    bool exponentNegative = false;
                    if (index < text.Length && (text[index] == '+' || text[index] == '-')) { exponentNegative = text[index] == '-'; index++; }
                    int exponentStart = index;
                    while (index < text.Length && Digit(text[index]))
                    {
                        // Saturate only after recognizing every exponent character.
                        if (exponent < 100000) exponent = Math.Min(100000, exponent * 10 + text[index] - '0');
                        index++;
                    }
                    if (index == exponentStart) throw Invalid("invalid_decimal_token");
                    if (exponentNegative) exponent = -exponent;
                }
                if (index != text.Length) throw Invalid("invalid_decimal_token");
                string allDigits = significant.ToString();
                int first = 0, last = allDigits.Length;
                while (first < last && allDigits[first] == '0') first++;
                if (first == last) return new Number { bits = 0, digits = "", scale = 0, negative = false };
                int scale = exponent - fractionalDigits;
                while (last > first && allDigits[last - 1] == '0') { last--; scale++; }
                string digits = allDigits.Substring(first, last - first);
                int decade = digits.Length + scale - 1;
                if (decade > 308) throw Invalid("decimal_overflow");
                if (decade < -324) throw Invalid("nonzero_decimal_underflow");
                BigInteger numerator;
                ulong small;
                if (digits.Length <= 19 && UInt64.TryParse(digits, NumberStyles.None, Invariant, out small)) numerator = new BigInteger(small);
                else numerator = BigInteger.Parse(digits, NumberStyles.None, Invariant);
                BigInteger denominator = BigInteger.One;
                if (scale >= 0) numerator *= PowerOfTen(scale);
                else denominator = PowerOfTen(-scale);
                ulong bits = RationalBits(numerator, denominator);
                if (negative) bits |= 0x8000000000000000UL;
                return new Number { bits = bits, digits = digits, scale = scale, negative = negative };
            }
        }

        private static int BitLength(BigInteger value)
        {
            byte[] bytes = value.ToByteArray();
            int index = bytes.Length - 1;
            while (index > 0 && bytes[index] == 0) index--;
            int bits = index * 8;
            byte most = bytes[index];
            while (most != 0) { bits++; most >>= 1; }
            return bits;
        }

        private static BigInteger RoundedQuotient(BigInteger numerator, BigInteger denominator, int shift)
        {
            if (shift >= 0) numerator <<= shift; else denominator <<= -shift;
            BigInteger remainder;
            BigInteger quotient = BigInteger.DivRem(numerator, denominator, out remainder);
            int comparison = (remainder << 1).CompareTo(denominator);
            if (comparison > 0 || (comparison == 0 && !quotient.IsEven)) quotient += BigInteger.One;
            return quotient;
        }

        private static ulong RationalBits(BigInteger numerator, BigInteger denominator)
        {
            int exponent = BitLength(numerator) - BitLength(denominator);
            int comparison = exponent >= 0 ? numerator.CompareTo(denominator << exponent) : (numerator << -exponent).CompareTo(denominator);
            if (comparison < 0) exponent--;
            if (exponent > 1023) throw Invalid("decimal_overflow");
            if (exponent < -1022)
            {
                BigInteger fraction = RoundedQuotient(numerator, denominator, 1074);
                if (fraction.IsZero) throw Invalid("nonzero_decimal_underflow");
                // 2^52 is the smallest normal value; its complete encoded bits
                // equal the rounded subnormal significand at this boundary.
                return (ulong)fraction;
            }
            BigInteger significand = RoundedQuotient(numerator, denominator, 52 - exponent);
            if (significand == (BigInteger.One << 53)) { significand >>= 1; exponent++; }
            if (exponent > 1023) throw Invalid("decimal_overflow");
            return ((ulong)(exponent + 1023) << 52) | ((ulong)significand - (1UL << 52));
        }

        private static int CompareNonnegative(Number a, Number b)
        {
            if (a.IsZero || b.IsZero) return a.IsZero ? (b.IsZero ? 0 : -1) : 1;
            int comparison = (a.digits.Length + a.scale).CompareTo(b.digits.Length + b.scale);
            if (comparison != 0) return comparison;
            int length = Math.Max(a.digits.Length, b.digits.Length);
            for (int i = 0; i < length; i++)
            {
                char x = i < a.digits.Length ? a.digits[i] : '0';
                char y = i < b.digits.Length ? b.digits[i] : '0';
                if (x != y) return x.CompareTo(y);
            }
            return 0;
        }

        private static long UnsignedInteger(string token)
        {
            if (String.IsNullOrEmpty(token)) throw Invalid("invalid_integer_token");
            for (int i = 0; i < token.Length; i++) if (!Digit(token[i])) throw Invalid("invalid_integer_token");
            long value;
            if (!Int64.TryParse(token, NumberStyles.None, Invariant, out value)) throw Invalid("integer_overflow");
            return value;
        }

        private static long ParseRow(string line, NumberParser parser, byte[] canonical)
        {
            if (String.IsNullOrEmpty(line) || line.Length > MaximumLineBytes) throw Invalid("invalid_csv_line");
            string[] fields = line.Split(',');
            if (fields.Length != 7) throw Invalid("invalid_csv_field_count");
            long timestamp = UnsignedInteger(fields[0]);
            if (timestamp < StartEpoch || timestamp >= EndEpoch || timestamp % 60L != 0) throw Invalid("invalid_q1_minute_epoch");
            Number open = parser.Parse(fields[1]), high = parser.Parse(fields[2]), low = parser.Parse(fields[3]), close = parser.Parse(fields[4]), volume = parser.Parse(fields[5]);
            if (open.IsZero || high.IsZero || low.IsZero || close.IsZero || open.negative || high.negative || low.negative || close.negative || volume.negative) throw Invalid("invalid_ohlcvt_sign");
            if (CompareNonnegative(high, low) < 0 || CompareNonnegative(high, open) < 0 || CompareNonnegative(high, close) < 0 || CompareNonnegative(open, low) < 0 || CompareNonnegative(close, low) < 0) throw Invalid("invalid_exact_ohlc_order");
            long trades = UnsignedInteger(fields[6]);
            if (trades > Int32.MaxValue) throw Invalid("trade_count_overflow");
            PutUInt64(canonical, 0, (ulong)timestamp);
            PutUInt64(canonical, 8, open.bits); PutUInt64(canonical, 16, high.bits); PutUInt64(canonical, 24, low.bits); PutUInt64(canonical, 32, close.bits); PutUInt64(canonical, 40, volume.bits);
            uint tradeBits = (uint)trades;
            for (int i = 0; i < 4; i++) canonical[48 + i] = (byte)(tradeBits >> (24 - i * 8));
            return timestamp;
        }

        private static void PutUInt64(byte[] bytes, int offset, ulong value)
        {
            for (int i = 0; i < 8; i++) bytes[offset + i] = (byte)(value >> (56 - i * 8));
        }
        private static string Hex(byte[] bytes)
        {
            const string alphabet = "0123456789abcdef";
            char[] characters = new char[bytes.Length * 2];
            for (int i = 0; i < bytes.Length; i++) { characters[i * 2] = alphabet[bytes[i] >> 4]; characters[i * 2 + 1] = alphabet[bytes[i] & 15]; }
            return new string(characters);
        }
        public static string CanonicalDoubleHex(string token)
        {
            byte[] bytes = new byte[8];
            PutUInt64(bytes, 0, new NumberParser().Parse(token).bits);
            return Hex(bytes);
        }
        public static string CanonicalRowHex(string line)
        {
            byte[] bytes = new byte[52];
            ParseRow(line, new NumberParser(), bytes);
            return Hex(bytes);
        }

        private static string NormalizedPath(string path)
        {
            if (String.IsNullOrEmpty(path) || path.Length > MaximumLineBytes || path[0] == '/' || path.IndexOf('\\') >= 0) throw Invalid("unsafe_member_path");
            string value = path.EndsWith("/", StringComparison.Ordinal) ? path.Substring(0, path.Length - 1) : path;
            string[] parts = value.Split('/');
            foreach (string part in parts)
            {
                if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal)) throw Invalid("unsafe_member_path");
                foreach (char c in part) if (c < 32 || c == 127 || ":\"<>|?*".IndexOf(c) >= 0) throw Invalid("unsafe_member_path");
                string stem = part.Split('.')[0].ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] >= '1' && stem[3] <= '9')) throw Invalid("unsafe_member_path");
            }
            return value.Normalize(NormalizationForm.FormC);
        }
        private static string OneMinutePair(string path)
        {
            if (!path.EndsWith("_1.csv", StringComparison.OrdinalIgnoreCase)) return null;
            string name = path.Substring(path.LastIndexOf('/') + 1);
            string pair = name.Substring(0, name.Length - 6);
            if (pair.Length == 0) throw Invalid("invalid_one_minute_pair");
            for (int i = 0; i < pair.Length; i++)
            {
                char c = pair[i];
                bool alphanumeric = Digit(c) || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
                if (!alphanumeric && (i == 0 || (c != '.' && c != '_' && c != '-'))) throw Invalid("invalid_one_minute_pair");
            }
            return pair;
        }
        private static bool HashValid(string value)
        {
            if (value == null || value.Length != 64) return false;
            foreach (char c in value) if (!Digit(c) && (c < 'a' || c > 'f')) return false;
            return true;
        }
        private static StreamWriter NewWriter(string path)
        {
            StreamWriter writer = new StreamWriter(new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read), Utf8, 65536);
            writer.NewLine = "\n";
            return writer;
        }
        private static string JsonString(string text)
        {
            StringBuilder result = new StringBuilder("\"");
            foreach (char c in text)
            {
                if (c == '"' || c == '\\') { result.Append('\\'); result.Append(c); }
                else if (c < 32) result.Append("\\u" + ((int)c).ToString("x4", Invariant));
                else result.Append(c);
            }
            return result.Append('"').ToString();
        }

        public static ArchiveResult ScanArchive(string archivePath, MemberBinding[] bindings, string[] allMemberPaths, string sourceDigestPath, string memberEvidencePath)
        {
            try { return ScanArchiveCore(archivePath, bindings, allMemberPaths, sourceDigestPath, memberEvidencePath); }
            catch (Exception e)
            {
                if (Fatal(e)) throw;
                if (e is InvalidDataException && e.Message.StartsWith("Q1-MKT-001:", StringComparison.Ordinal)) throw;
                throw Invalid("archive_read_or_evidence_write_failed:" + e.GetType().Name);
            }
        }

        private static ArchiveResult ScanArchiveCore(string archivePath, MemberBinding[] bindings, string[] allMemberPaths, string sourceDigestPath, string memberEvidencePath)
        {
            if (bindings == null || bindings.Length == 0 || allMemberPaths == null || allMemberPaths.Length == 0) throw Invalid("empty_archive_binding");
            HashSet<string> expected = new HashSet<string>(StringComparer.Ordinal);
            HashSet<string> normalized = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> regular = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string path in allMemberPaths)
            {
                string safe = NormalizedPath(path);
                if (!expected.Add(path) || !normalized.Add(safe)) throw Invalid("duplicate_inventory_path");
                if (!path.EndsWith("/", StringComparison.Ordinal)) regular.Add(safe);
            }
            foreach (string path in normalized)
                for (int slash = path.IndexOf('/'); slash >= 0; slash = path.IndexOf('/', slash + 1))
                    if (regular.Contains(path.Substring(0, slash))) throw Invalid("file_is_member_ancestor");
            HashSet<string> selectedPaths = new HashSet<string>(StringComparer.Ordinal);
            HashSet<string> pairs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<long> pairIds = new HashSet<long>();
            MemberBinding[] sorted = (MemberBinding[])bindings.Clone();
            foreach (MemberBinding binding in sorted)
            {
                if (binding == null || !expected.Contains(binding.member_path) || !selectedPaths.Add(binding.member_path) || binding.pair_id <= 0 || !pairIds.Add(binding.pair_id) || !pairs.Add(binding.pair_code ?? "") || String.IsNullOrEmpty(binding.pair_code) || !String.Equals(OneMinutePair(binding.member_path), binding.pair_code, StringComparison.Ordinal) || !HashValid(binding.sha256) || binding.length_bytes <= 0 || binding.rows <= 0 || binding.rows > 129600L || binding.min_epoch < StartEpoch || binding.max_epoch >= EndEpoch || binding.min_epoch > binding.max_epoch || binding.min_epoch % 60 != 0 || binding.max_epoch % 60 != 0 || binding.rows > (binding.max_epoch - binding.min_epoch) / 60L + 1L)
                    throw Invalid("invalid_selected_member_binding");
            }
            foreach (string path in allMemberPaths)
                if (OneMinutePair(path) != null && !selectedPaths.Contains(path)) throw Invalid("unbound_one_minute_member");
            Array.Sort(sorted, delegate(MemberBinding a, MemberBinding b) { return a.pair_id.CompareTo(b.pair_id); });
            ArchiveResult result = new ArchiveResult();
            NumberParser parser = new NumberParser();
            using (FileStream file = new FileStream(archivePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (ZipArchive archive = new ZipArchive(file, ZipArchiveMode.Read, true, Utf8))
            {
                if (archive.Entries.Count != allMemberPaths.Length) throw Invalid("archive_inventory_count_mismatch");
                Dictionary<string, ZipArchiveEntry> entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.Ordinal);
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    if (!expected.Contains(entry.FullName) || entries.ContainsKey(entry.FullName)) throw Invalid("archive_inventory_path_mismatch");
                    entries.Add(entry.FullName, entry);
                }
                using (StreamWriter digests = NewWriter(sourceDigestPath))
                using (StreamWriter evidence = NewWriter(memberEvidencePath))
                {
                    digests.WriteLine(DigestHeader);
                    byte[] buffer = new byte[65536];
                    foreach (MemberBinding binding in sorted)
                    {
                        ZipArchiveEntry entry = entries[binding.member_path];
                        if (entry.Length != binding.length_bytes) throw Invalid("member_declared_length_mismatch");
                        long byteCount = 0;
                        string hash;
                        using (MemberRows rows = new MemberRows(binding, parser, digests))
                        {
                            using (SHA256 sha = SHA256.Create())
                            using (Stream stream = entry.Open())
                            {
                                int read;
                                while ((read = stream.Read(buffer, 0, buffer.Length)) != 0)
                                {
                                    byteCount = checked(byteCount + read);
                                    if (byteCount > binding.length_bytes) throw Invalid("member_length_exceeds_binding");
                                    sha.TransformBlock(buffer, 0, read, buffer, 0);
                                    rows.Push(buffer, read);
                                }
                                sha.TransformFinalBlock(Empty, 0, 0);
                                hash = Hex(sha.Hash);
                            }
                            rows.Finish();
                            if (byteCount != binding.length_bytes || !String.Equals(hash, binding.sha256, StringComparison.Ordinal)) throw Invalid("member_byte_binding_mismatch");
                            if (rows.rowCount != binding.rows || rows.firstEpoch != binding.min_epoch || rows.lastEpoch != binding.max_epoch) throw Invalid("member_row_binding_mismatch");
                            result.row_count = checked(result.row_count + rows.rowCount);
                            result.day_count = checked(result.day_count + rows.dayCount);
                            result.member_count++;
                            evidence.WriteLine("{\"member_path\":" + JsonString(binding.member_path) + ",\"pair_code\":" + JsonString(binding.pair_code) + ",\"pair_id\":" + Count(binding.pair_id) + ",\"sha256\":" + JsonString(hash) + ",\"length_bytes\":" + Count(byteCount) + ",\"rows\":" + Count(rows.rowCount) + ",\"min_epoch\":" + Count(rows.firstEpoch) + ",\"max_epoch\":" + Count(rows.lastEpoch) + ",\"day_count\":" + Count(rows.dayCount) + ",\"status\":\"PASS\",\"canonicalization\":" + JsonString(Canonicalization) + "}");
                        }
                    }
                }
                result.archive_member_count = archive.Entries.Count;
            }
            if (result.row_count == 0 || result.day_count == 0) throw Invalid("empty_source_population");
            return result;
        }

        private sealed class MemberRows : IDisposable
        {
            private readonly MemberBinding binding;
            private readonly NumberParser parser;
            private readonly StreamWriter output;
            private readonly byte[] line = new byte[MaximumLineBytes];
            private readonly byte[] canonical = new byte[52];
            private int used;
            private bool previousCr;
            private long currentDay = -1, dayRows, dayFirst, dayLast;
            private SHA256 dayHash;
            internal long rowCount, firstEpoch, lastEpoch, dayCount;
            internal MemberRows(MemberBinding value, NumberParser numberParser, StreamWriter writer) { binding = value; parser = numberParser; output = writer; }
            internal void Push(byte[] bytes, int length)
            {
                for (int i = 0; i < length; i++)
                {
                    byte value = bytes[i];
                    if (previousCr) { previousCr = false; if (value == 10) continue; }
                    if (value == 10 || value == 13) { Consume(); previousCr = value == 13; }
                    else { if (used == line.Length) throw Invalid("csv_line_exceeds_bound"); line[used++] = value; }
                }
            }
            internal void Finish() { if (used != 0) Consume(); FlushDay(); }
            private void Consume()
            {
                if (used == 0) throw Invalid("empty_csv_row");
                string text = Utf8.GetString(line, 0, used);
                used = 0;
                long timestamp = ParseRow(text, parser, canonical);
                if (rowCount > 0 && timestamp <= lastEpoch) throw Invalid("duplicate_or_decreasing_epoch");
                if (rowCount == 0) firstEpoch = timestamp;
                lastEpoch = timestamp;
                rowCount++;
                if (rowCount > binding.rows) throw Invalid("member_rows_exceed_binding");
                long day = timestamp / 86400L;
                if (day != currentDay)
                {
                    FlushDay(); currentDay = day; dayRows = 0; dayFirst = timestamp; dayHash = SHA256.Create();
                }
                dayRows++; dayLast = timestamp;
                if (dayRows > 1440) throw Invalid("pair_day_exceeds_minute_population");
                dayHash.TransformBlock(canonical, 0, canonical.Length, canonical, 0);
            }
            private void FlushDay()
            {
                if (dayHash == null) return;
                dayHash.TransformFinalBlock(Empty, 0, 0);
                output.WriteLine(Count(binding.pair_id) + "\t" + Epoch.AddDays(currentDay).ToString("yyyy-MM-dd", Invariant) + "\t" + Count(dayRows) + "\t" + Count(dayFirst) + "\t" + Count(dayLast) + "\t" + Hex(dayHash.Hash));
                dayCount++; dayHash.Dispose(); dayHash = null;
            }
            public void Dispose() { if (dayHash != null) dayHash.Dispose(); }
        }

        private sealed class DigestRow
        {
            internal long pairId, rows, min, max;
            internal string day, hash;
        }
        private sealed class DigestReader : IDisposable
        {
            private readonly BufferedStream stream;
            private readonly byte[] buffer = new byte[1024];
            private DigestRow previous;
            private int pending = -1;
            internal DigestReader(string path)
            {
                stream = new BufferedStream(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read), 65536);
                try { if (!String.Equals(ReadLine(), DigestHeader, StringComparison.Ordinal)) throw Invalid("digest_header_mismatch"); }
                catch { stream.Dispose(); throw; }
            }
            private string ReadLine()
            {
                int used = 0;
                while (true)
                {
                    int value;
                    if (pending >= 0) { value = pending; pending = -1; } else value = stream.ReadByte();
                    if (value < 0) return used == 0 ? null : Utf8.GetString(buffer, 0, used);
                    if (value == 10) return Utf8.GetString(buffer, 0, used);
                    if (value == 13)
                    {
                        int next = stream.ReadByte();
                        if (next != 10) throw Invalid("invalid_digest_line_ending");
                        return Utf8.GetString(buffer, 0, used);
                    }
                    if (used == buffer.Length) throw Invalid("digest_line_exceeds_bound");
                    buffer[used++] = (byte)value;
                }
            }
            internal DigestRow Read()
            {
                string line = ReadLine();
                if (line == null) return null;
                string[] values = line.Split('\t');
                if (values.Length != 6) throw Invalid("digest_field_count_mismatch");
                DigestRow row = new DigestRow { pairId = CanonicalInteger(values[0]), day = values[1], rows = CanonicalInteger(values[2]), min = CanonicalInteger(values[3]), max = CanonicalInteger(values[4]), hash = values[5] };
                DateTime day;
                if (row.pairId <= 0 || row.rows <= 0 || row.rows > 1440 || row.min < StartEpoch || row.max >= EndEpoch || row.min > row.max || row.min % 60 != 0 || row.max % 60 != 0 || row.rows > (row.max - row.min) / 60L + 1L || (row.rows == 1 && row.min != row.max) || !HashValid(row.hash) || !DateTime.TryParseExact(row.day, "yyyy-MM-dd", Invariant, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out day)) throw Invalid("invalid_digest_row");
                long dayStart = (long)(day - Epoch).TotalSeconds;
                if (row.min < dayStart || row.max >= dayStart + 86400L) throw Invalid("digest_day_bounds_mismatch");
                if (previous != null && CompareKeys(previous, row) >= 0) throw Invalid("duplicate_or_unordered_digest_key");
                previous = row;
                return row;
            }
            private static long CanonicalInteger(string value)
            {
                long parsed = UnsignedInteger(value);
                if (!String.Equals(value, Count(parsed), StringComparison.Ordinal)) throw Invalid("noncanonical_digest_integer");
                return parsed;
            }
            public void Dispose() { stream.Dispose(); }
        }
        private static int CompareKeys(DigestRow a, DigestRow b)
        {
            int pair = a.pairId.CompareTo(b.pairId);
            return pair != 0 ? pair : StringComparer.Ordinal.Compare(a.day, b.day);
        }
        private static string DigestColumns(DigestRow row)
        {
            return row == null ? "\t\t\t" : Count(row.rows) + "\t" + Count(row.min) + "\t" + Count(row.max) + "\t" + row.hash;
        }

        public static ComparisonResult CompareDigests(string sourcePath, string marketPath, string comparisonPath)
        {
            try { return CompareDigestsCore(sourcePath, marketPath, comparisonPath); }
            catch (Exception e)
            {
                if (Fatal(e)) throw;
                if (e is InvalidDataException && e.Message.StartsWith("Q1-MKT-001:", StringComparison.Ordinal)) throw;
                throw Invalid("digest_read_or_evidence_write_failed:" + e.GetType().Name);
            }
        }
        private static ComparisonResult CompareDigestsCore(string sourcePath, string marketPath, string comparisonPath)
        {
            ComparisonResult result = new ComparisonResult();
            using (DigestReader source = new DigestReader(sourcePath))
            using (DigestReader database = new DigestReader(marketPath))
            using (StreamWriter output = NewWriter(comparisonPath))
            {
                output.WriteLine("pair_id\tday_utc\tstatus\tsource_rows\tsource_min_epoch\tsource_max_epoch\tsource_sha256\tdatabase_rows\tdatabase_min_epoch\tdatabase_max_epoch\tdatabase_sha256");
                DigestRow s = source.Read(), d = database.Read();
                while (s != null || d != null)
                {
                    int order = s == null ? 1 : (d == null ? -1 : CompareKeys(s, d));
                    DigestRow sourceRow = order <= 0 ? s : null;
                    DigestRow databaseRow = order >= 0 ? d : null;
                    DigestRow key = sourceRow ?? databaseRow;
                    string status;
                    if (sourceRow != null) { result.source_day_count++; result.source_row_count = checked(result.source_row_count + sourceRow.rows); }
                    if (databaseRow != null) { result.database_day_count++; result.database_row_count = checked(result.database_row_count + databaseRow.rows); }
                    if (order < 0) { status = "MISSING_DATABASE"; result.missing_day_count++; result.missing_row_count = checked(result.missing_row_count + sourceRow.rows); }
                    else if (order > 0) { status = "EXTRA_DATABASE"; result.extra_day_count++; result.extra_row_count = checked(result.extra_row_count + databaseRow.rows); }
                    else if (s.rows == d.rows && s.min == d.min && s.max == d.max && String.Equals(s.hash, d.hash, StringComparison.Ordinal))
                    {
                        status = "MATCH"; result.matched_day_count++; result.matched_row_count = checked(result.matched_row_count + s.rows);
                    }
                    else
                    {
                        status = "MISMATCH"; result.mismatched_day_count++; result.mismatched_source_row_count = checked(result.mismatched_source_row_count + s.rows); result.mismatched_database_row_count = checked(result.mismatched_database_row_count + d.rows);
                    }
                    if (status != "MATCH") result.status = "FAIL";
                    output.WriteLine(Count(key.pairId) + "\t" + key.day + "\t" + status + "\t" + DigestColumns(sourceRow) + "\t" + DigestColumns(databaseRow));
                    if (order <= 0) s = source.Read();
                    if (order >= 0) d = database.Read();
                }
            }
            result.mismatched_row_count = result.mismatched_source_row_count;
            if (result.source_day_count == 0 || result.database_day_count == 0) result.status = "FAIL";
            return result;
        }

        public static string SelfTest()
        {
            string[,] cases = {
                { "0", "0000000000000000" }, { "-0.000e999999", "0000000000000000" },
                { "1", "3ff0000000000000" }, { "-1", "bff0000000000000" }, { "0.1", "3fb999999999999a" },
                { "1.00000000000000011102230246251565404236316680908203125", "3ff0000000000000" },
                { "1.00000000000000033306690738754696212708950042724609375", "3ff0000000000002" },
                { "9007199254740993", "4340000000000000" }, { "5e-324", "0000000000000001" },
                { "2.4703282292062328e-324", "0000000000000001" }, { "2.2250738585072014e-308", "0010000000000000" },
                { "1.7976931348623157e308", "7fefffffffffffff" }
            };
            for (int i = 0; i < cases.GetLength(0); i++) if (CanonicalDoubleHex(cases[i, 0]) != cases[i, 1]) throw Invalid("self_test_decimal_case_" + Count(i));
            string[] rejected = { "", "NaN", "Infinity", "1e309", "1.7976931348623159e308", "1e-324", "2.4703282292062327e-324", "1\0", " 1", "1 ", ".", "1e", "1e+", "+", "1,2", "1_0" };
            foreach (string token in rejected)
            {
                bool failed = false;
                try { CanonicalDoubleHex(token); } catch (InvalidDataException) { failed = true; }
                if (!failed) throw Invalid("self_test_rejected_decimal");
            }
            string row = CanonicalRowHex("1767225600,1,2,0.5,1.5,-0,2147483647");
            if (row != "000000006955b9003ff000000000000040000000000000003fe00000000000003ff800000000000000000000000000007fffffff") throw Invalid("self_test_row_encoding");
            bool exactOrderFailed = false;
            try { CanonicalRowHex("1767225600,1.00000000000000001,1,1,1,0,1"); } catch (InvalidDataException) { exactOrderFailed = true; }
            if (!exactOrderFailed) throw Invalid("self_test_exact_ohlc_order");
            return "PASS";
        }
    }
}
