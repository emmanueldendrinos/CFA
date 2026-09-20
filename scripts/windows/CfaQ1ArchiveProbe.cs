// Q1-COV-001-ARCHIVE. C# 5 / .NET Framework 4.5 and PowerShell 7 compatible.
// No extraction, source writes, row samples, or network operations.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace CfaQ1Coverage
{
    public sealed class Q1ArchiveDay
    {
        public string day_utc;
        public long rows;
    }

    public sealed class Q1ArchiveMember
    {
        public string member_path;
        public string normalized_member_path;
        public bool is_directory;
        public bool is_one_minute;
        public string pair_code;
        public long declared_length_bytes;
        public long length_bytes;
        public bool read_complete;
        public string sha256;
        public string crc32;
        public string expected_crc32;
        public long rows;
        public long? min_epoch;
        public long? max_epoch;
        public long invalid_rows;
        public long out_of_q1_rows;
        public long off_minute_rows;
        public long duplicate_or_decreasing_rows;
        public Q1ArchiveDay[] days = new Q1ArchiveDay[0];
        public string days_scope = "parsed epochs in [2026-01-01,2026-04-01), including otherwise invalid rows";
        public string[] errors = new string[0];
    }

    public sealed class Q1ArchiveSummary
    {
        public string status = "FAIL";
        public long q1_start_epoch = 1767225600L;
        public long q1_end_epoch_exclusive = 1775001600L;
        public string scan_mode = "single FileStream/FileShare.Read; no extraction; exact-byte SHA-256 and central-directory CRC32 verification";
        public string row_count_scope = "physical rows in one-minute members, including invalid rows; terminal newline does not add a row";
        public int maximum_line_bytes = 4096;
        public long archive_length_bytes;
        public string archive_last_write_utc;
        public bool source_stable;
        public int member_count;
        public int directory_member_count;
        public int one_minute_member_count;
        public long rows;
        public long issue_count;
        public Q1ArchiveMember[] members = new Q1ArchiveMember[0];
        public string[] errors = new string[0];
    }

    public static class ArchiveProbe
    {
        private const long StartEpoch = 1767225600L;
        private const long EndEpoch = 1775001600L;
        private const int MaximumLineBytes = 4096;
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);
        private static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        private static readonly Regex IntervalName = new Regex(@"^(.+)_([0-9]+)\.csv$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private static readonly Regex PairName = new Regex(@"^[A-Za-z0-9][A-Za-z0-9._-]*$", RegexOptions.CultureInvariant);
        private static readonly uint[] CrcTable = MakeCrcTable();

        private sealed class CentralEntry
        {
            internal uint crc;
            internal long length;
            internal long compressed_length;
            internal long local_offset;
            internal long central_offset;
            internal byte[] name_bytes;
            internal ushort flags;
            internal ushort method;
        }

        public static Q1ArchiveSummary Scan(string archivePath)
        {
            Q1ArchiveSummary result = new Q1ArchiveSummary();
            List<Q1ArchiveMember> members = new List<Q1ArchiveMember>();
            List<string> errors = new List<string>();
            HashSet<string> paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> regularPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> pathAncestors = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> pairs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string fullPath = Path.GetFullPath(archivePath);
                using (FileStream file = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    long initialLength = file.Length;
                    DateTime initialWrite = File.GetLastWriteTimeUtc(fullPath);
                    result.archive_length_bytes = initialLength;
                    result.archive_last_write_utc = initialWrite.ToString("o", CultureInfo.InvariantCulture);
                    CentralEntry[] central = ReadCentralDirectory(file);
                    file.Position = 0;
                    using (ZipArchive archive = new ZipArchive(file, ZipArchiveMode.Read, true, StrictUtf8))
                    {
                        if (archive.Entries.Count != central.Length)
                            throw new InvalidDataException("central entry count mismatch");
                        for (int index = 0; index < archive.Entries.Count; index++)
                        {
                            ZipArchiveEntry entry = archive.Entries[index];
                            CentralEntry metadata = central[index];
                            Q1ArchiveMember member = new Q1ArchiveMember();
                            List<string> memberErrors = new List<string>();
                            member.member_path = entry.FullName;
                            member.is_directory = entry.FullName.EndsWith("/", StringComparison.Ordinal) || entry.FullName.EndsWith("\\", StringComparison.Ordinal);
                            member.declared_length_bytes = metadata.length;
                            member.expected_crc32 = metadata.crc.ToString("x8", CultureInfo.InvariantCulture);
                            members.Add(member);
                            if (member.is_directory) result.directory_member_count++;
                            string normalized;
                            if (!SafeMemberPath(entry.FullName, member.is_directory, out normalized)) memberErrors.Add("unsafe_member_path");
                            member.normalized_member_path = normalized;
                            if (normalized != null && !paths.Add(normalized)) memberErrors.Add("duplicate_normalized_member_path");
                            if (normalized != null)
                            {
                                bool ancestorConflict = !member.is_directory && pathAncestors.Contains(normalized);
                                for (int slash = normalized.IndexOf('/'); slash >= 0; slash = normalized.IndexOf('/', slash + 1))
                                {
                                    string ancestor = normalized.Substring(0, slash);
                                    if (regularPaths.Contains(ancestor)) ancestorConflict = true;
                                    pathAncestors.Add(ancestor);
                                }
                                if (!member.is_directory) regularPaths.Add(normalized);
                                if (ancestorConflict) memberErrors.Add("regular_file_is_member_path_ancestor");
                            }
                            ClassifyMember(member, memberErrors);
                            if (member.is_one_minute)
                            {
                                result.one_minute_member_count++;
                                if (member.pair_code != null && !pairs.Add(member.pair_code)) memberErrors.Add("duplicate_one_minute_pair_code");
                            }
                            if ((metadata.flags & 0x0041) != 0) memberErrors.Add("encrypted_member_unsupported");
                            if (metadata.method != 0 && metadata.method != 8) memberErrors.Add("compression_method_unsupported");
                            if (member.is_directory && metadata.length != 0) memberErrors.Add("directory_has_content");
                            try { ValidateLocalHeader(file, metadata); }
                            catch (Exception ex)
                            {
                                if (IsFatal(ex)) throw;
                                memberErrors.Add("local_header_invalid:" + ex.GetType().Name);
                            }
                            try
                            {
                                if (entry.Length != metadata.length || entry.CompressedLength != metadata.compressed_length)
                                    throw new InvalidDataException("central metadata mismatch");
                                ReadMember(entry, member, memberErrors);
                                if (member.length_bytes != metadata.length) memberErrors.Add("uncompressed_length_mismatch");
                                if (!String.Equals(member.crc32, member.expected_crc32, StringComparison.Ordinal)) memberErrors.Add("crc32_mismatch");
                            }
                            catch (Exception ex)
                            {
                                if (IsFatal(ex)) throw;
                                memberErrors.Add("member_unreadable:" + ex.GetType().Name);
                            }
                            if (member.is_one_minute)
                            {
                                if (member.rows == 0) memberErrors.Add("zero_one_minute_rows");
                                if (member.invalid_rows != 0) memberErrors.Add("invalid_rows:" + Count(member.invalid_rows));
                                if (member.out_of_q1_rows != 0) memberErrors.Add("out_of_q1_rows:" + Count(member.out_of_q1_rows));
                                if (member.off_minute_rows != 0) memberErrors.Add("off_minute_rows:" + Count(member.off_minute_rows));
                                if (member.duplicate_or_decreasing_rows != 0) memberErrors.Add("duplicate_or_decreasing_rows:" + Count(member.duplicate_or_decreasing_rows));
                                result.rows = checked(result.rows + member.rows);
                            }
                            member.errors = memberErrors.ToArray();
                            result.issue_count += memberErrors.Count;
                        }
                    }
                    result.source_stable = file.Length == initialLength && File.GetLastWriteTimeUtc(fullPath) == initialWrite;
                    if (!result.source_stable) errors.Add("archive_length_or_last_write_changed_during_scan");
                }
            }
            catch (Exception ex)
            {
                if (IsFatal(ex)) throw;
                errors.Add("archive_unreadable:" + ex.GetType().Name);
            }
            if (members.Count == 0) errors.Add("empty_archive_or_inventory_unavailable");
            if (result.one_minute_member_count == 0) errors.Add("no_one_minute_members");
            if (result.rows == 0) errors.Add("zero_total_one_minute_rows");
            result.members = members.ToArray();
            result.member_count = members.Count;
            result.errors = errors.ToArray();
            result.issue_count += errors.Count;
            result.status = result.issue_count == 0 && result.source_stable ? "PASS" : "FAIL";
            return result;
        }

        private static bool IsFatal(Exception ex)
        {
            return ex is OutOfMemoryException || ex is StackOverflowException || ex is AccessViolationException;
        }

        private static string Count(long value) { return value.ToString(CultureInfo.InvariantCulture); }

        private static bool SafeMemberPath(string value, bool directory, out string normalized)
        {
            normalized = null;
            if (String.IsNullOrEmpty(value)) return false;
            string candidate = value.Replace('\\', '/');
            if (directory) candidate = candidate.TrimEnd('/');
            try { normalized = candidate.Normalize(NormalizationForm.FormC); }
            catch (ArgumentException) { return false; }
            if (value.IndexOf('\\') >= 0 || candidate.Length == 0 || candidate[0] == '/') return false;
            string[] parts = candidate.Split('/');
            foreach (string part in parts)
            {
                if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".", StringComparison.Ordinal) || part.EndsWith(" ", StringComparison.Ordinal)) return false;
                foreach (char c in part)
                    if (c < 32 || c == 127 || ":\"<>|?*".IndexOf(c) >= 0) return false;
                string stem = part.Split('.')[0].ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                    (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal)) && stem[3] >= '1' && stem[3] <= '9')) return false;
            }
            return true;
        }

        private static void ClassifyMember(Q1ArchiveMember member, List<string> errors)
        {
            if (member.is_directory) return;
            string slashPath = member.member_path.Replace('\\', '/');
            string basename = slashPath.Substring(slashPath.LastIndexOf('/') + 1);
            Match match = IntervalName.Match(basename);
            if (!match.Success)
            {
                // Malformed CSV names are errors, including empty-pair _1.csv.
                // Names with a trailing dot/space cannot hide a one-minute member.
                string trimmed = basename.TrimEnd(' ', '.');
                if (trimmed.EndsWith(".csv", StringComparison.OrdinalIgnoreCase)) errors.Add("malformed_ohlcvt_member_name");
                if (trimmed.EndsWith("_1.csv", StringComparison.OrdinalIgnoreCase)) member.is_one_minute = true;
                return;
            }
            string pair = match.Groups[1].Value;
            int interval;
            bool validInterval = Int32.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out interval) && interval > 0;
            member.is_one_minute = validInterval && interval == 1;
            if (member.is_one_minute) member.pair_code = pair;
            if (!validInterval || !PairName.IsMatch(pair) || match.Groups[2].Value != interval.ToString(CultureInfo.InvariantCulture)) errors.Add("malformed_ohlcvt_member_name");
        }

        private static void ReadMember(ZipArchiveEntry entry, Q1ArchiveMember member, List<string> errors)
        {
            byte[] buffer = new byte[65536];
            uint crc = 0xffffffffU;
            LineCollector lines = member.is_one_minute ? new LineCollector(member) : null;
            using (SHA256 sha = SHA256.Create())
            using (Stream stream = entry.Open())
            {
                int length;
                while ((length = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    member.length_bytes = checked(member.length_bytes + length);
                    sha.TransformBlock(buffer, 0, length, buffer, 0);
                    for (int i = 0; i < length; i++) crc = CrcTable[(crc ^ buffer[i]) & 0xff] ^ (crc >> 8);
                    if (lines != null) lines.Push(buffer, length);
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                member.sha256 = Hex(sha.Hash);
                member.crc32 = (crc ^ 0xffffffffU).ToString("x8", CultureInfo.InvariantCulture);
                member.read_complete = true;
                if (lines != null) lines.Finish();
            }
        }

        private sealed class LineCollector
        {
            private readonly Q1ArchiveMember member;
            private readonly byte[] line = new byte[MaximumLineBytes];
            private readonly long[] dayCounts = new long[90];
            private int used;
            private bool oversized;
            private bool previousCr;
            private long? previousEpoch;

            internal LineCollector(Q1ArchiveMember memberValue) { member = memberValue; }

            internal void Push(byte[] bytes, int length)
            {
                for (int index = 0; index < length; index++)
                {
                    byte value = bytes[index];
                    if (previousCr)
                    {
                        previousCr = false;
                        if (value == 10) continue;
                    }
                    if (value == 10 || value == 13)
                    {
                        ConsumeLine();
                        previousCr = value == 13;
                    }
                    else if (used == line.Length) oversized = true;
                    else if (!oversized) line[used++] = value;
                }
            }

            internal void Finish()
            {
                if (used > 0 || oversized) ConsumeLine();
                List<Q1ArchiveDay> days = new List<Q1ArchiveDay>();
                for (int index = 0; index < dayCounts.Length; index++)
                    if (dayCounts[index] != 0)
                        days.Add(new Q1ArchiveDay { day_utc = Epoch.AddSeconds(StartEpoch).AddDays(index).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), rows = dayCounts[index] });
                member.days = days.ToArray();
            }

            private void ConsumeLine()
            {
                member.rows++;
                bool valid = !oversized;
                string text = null;
                if (valid)
                {
                    try { text = StrictUtf8.GetString(line, 0, used); }
                    catch (DecoderFallbackException) { valid = false; }
                }
                used = 0;
                oversized = false;
                if (valid)
                {
                    string[] fields = text.Split(',');
                    valid = fields.Length == 7;
                    if (valid)
                    {
                        long epoch;
                        bool validEpoch = UnsignedInteger(fields[0], out epoch);
                        if (validEpoch)
                        {
                            if (!member.min_epoch.HasValue || epoch < member.min_epoch.Value) member.min_epoch = epoch;
                            if (!member.max_epoch.HasValue || epoch > member.max_epoch.Value) member.max_epoch = epoch;
                            if (epoch < StartEpoch || epoch >= EndEpoch) member.out_of_q1_rows++;
                            else dayCounts[(int)((epoch - StartEpoch) / 86400L)]++;
                            if (epoch % 60L != 0) member.off_minute_rows++;
                            if (previousEpoch.HasValue && epoch <= previousEpoch.Value) member.duplicate_or_decreasing_rows++;
                            previousEpoch = epoch;
                        }
                        double open, high, low, close, volume;
                        long trades;
                        bool numbers = Number(fields[1], out open) & Number(fields[2], out high) & Number(fields[3], out low) & Number(fields[4], out close) & Number(fields[5], out volume);
                        bool validTrades = UnsignedInteger(fields[6], out trades) && trades <= Int32.MaxValue;
                        valid = validEpoch && numbers && validTrades && open > 0 && high > 0 && low > 0 && close > 0 && volume >= 0 && !NegativeNonzero(fields[5]) && high >= low && high >= open && high >= close && low <= open && low <= close &&
                            ExactAtLeast(fields[2], fields[3], high, low) && ExactAtLeast(fields[2], fields[1], high, open) && ExactAtLeast(fields[2], fields[4], high, close) && ExactAtLeast(fields[1], fields[3], open, low) && ExactAtLeast(fields[4], fields[3], close, low);
                    }
                }
                if (!valid) member.invalid_rows++;
            }
        }

        private static bool Number(string text, out double value)
        {
            value = 0;
            // TryParse accepts trailing NULs on some framework versions. Check
            // the whole ASCII numeric grammar before invoking the conversion.
            int index = 0, digits = 0;
            if (index < text.Length && (text[index] == '+' || text[index] == '-')) index++;
            while (index < text.Length && Digit(text[index])) { index++; digits++; }
            if (index < text.Length && text[index] == '.')
            {
                index++;
                while (index < text.Length && Digit(text[index])) { index++; digits++; }
            }
            if (digits == 0) return false;
            if (index < text.Length && (text[index] == 'e' || text[index] == 'E'))
            {
                index++;
                if (index < text.Length && (text[index] == '+' || text[index] == '-')) index++;
                int exponentStart = index;
                while (index < text.Length && Digit(text[index])) index++;
                if (index == exponentStart) return false;
            }
            return index == text.Length && Double.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out value) && !Double.IsNaN(value) && !Double.IsInfinity(value);
        }

        private static bool Digit(char value) { return value >= '0' && value <= '9'; }

        private static bool UnsignedInteger(string text, out long value)
        {
            value = 0;
            if (text.Length == 0) return false;
            foreach (char character in text) if (!Digit(character)) return false;
            return Int64.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value);
        }

        private static bool NegativeNonzero(string text)
        {
            if (text.Length == 0 || text[0] != '-') return false;
            for (int index = 1; index < text.Length && text[index] != 'e' && text[index] != 'E'; index++)
                if (text[index] >= '1' && text[index] <= '9') return true;
            return false;
        }

        private static bool ExactAtLeast(string left, string right, double leftValue, double rightValue)
        {
            if (leftValue > rightValue || String.Equals(left, right, StringComparison.Ordinal)) return true;
            // IEEE conversion is monotone, but two distinct decimal values can
            // round to the same double. Resolve ties using bounded digit strings.
            string leftDigits, rightDigits;
            int leftPower, rightPower;
            DecimalMagnitude(left, out leftDigits, out leftPower);
            DecimalMagnitude(right, out rightDigits, out rightPower);
            if (leftPower != rightPower) return leftPower > rightPower;
            int length = Math.Max(leftDigits.Length, rightDigits.Length);
            for (int index = 0; index < length; index++)
            {
                char leftDigit = index < leftDigits.Length ? leftDigits[index] : '0';
                char rightDigit = index < rightDigits.Length ? rightDigits[index] : '0';
                if (leftDigit != rightDigit) return leftDigit > rightDigit;
            }
            return true;
        }

        private static void DecimalMagnitude(string text, out string digits, out int power)
        {
            int exponentOffset = text.IndexOfAny(new char[] { 'e', 'E' });
            int end = exponentOffset >= 0 ? exponentOffset : text.Length;
            int exponent = 0;
            if (exponentOffset >= 0)
            {
                int index = exponentOffset + 1;
                bool negative = text[index] == '-';
                if (text[index] == '+' || negative) index++;
                // Nonzero finite positive doubles cannot require this bound;
                // saturation makes even arbitrarily long zero-padded exponents safe.
                while (index < text.Length) { exponent = Math.Min(1000000, exponent * 10 + text[index] - '0'); index++; }
                if (negative) exponent = -exponent;
            }
            int decimalPoint = text.IndexOf('.');
            int fractionalDigits = decimalPoint >= 0 && decimalPoint < end ? end - decimalPoint - 1 : 0;
            StringBuilder mantissa = new StringBuilder(end);
            for (int index = 0; index < end; index++) if (Digit(text[index])) mantissa.Append(text[index]);
            string allDigits = mantissa.ToString();
            int first = 0;
            while (first < allDigits.Length && allDigits[first] == '0') first++;
            digits = allDigits.Substring(first);
            power = exponent - fractionalDigits + digits.Length;
        }

        private static string Hex(byte[] bytes)
        {
            StringBuilder value = new StringBuilder(bytes.Length * 2);
            foreach (byte item in bytes) value.Append(item.ToString("x2", CultureInfo.InvariantCulture));
            return value.ToString();
        }

        private static uint[] MakeCrcTable()
        {
            uint[] table = new uint[256];
            for (uint index = 0; index < 256; index++)
            {
                uint value = index;
                for (int bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xedb88320U ^ (value >> 1) : value >> 1;
                table[index] = value;
            }
            return table;
        }

        // ZipArchive on .NET Framework does not guarantee CRC checks. Read the
        // central directory from the same locked handle and compare every CRC.
        // The tail and each central-directory record are bounded allocations.
        private static CentralEntry[] ReadCentralDirectory(FileStream file)
        {
            int tailLength = (int)Math.Min(file.Length, 65557L);
            byte[] tail = ReadAt(file, file.Length - tailLength, tailLength);
            int end = -1;
            for (int index = tail.Length - 22; index >= 0; index--)
                if (U32(tail, index) == 0x06054b50U && index + 22 + U16(tail, index + 20) == tail.Length) { end = index; break; }
            if (end < 0) throw new InvalidDataException("ZIP end record missing");
            if (U16(tail, end + 4) != 0 || U16(tail, end + 6) != 0 || U16(tail, end + 8) != U16(tail, end + 10)) throw new InvalidDataException("multi-disk ZIP unsupported");
            long entries = U16(tail, end + 10);
            long centralSize = U32(tail, end + 12);
            long centralOffset = U32(tail, end + 16);
            long endOffset = file.Length - tailLength + end;
            long centralLimit = endOffset;
            if (entries == 65535L || centralSize == UInt32.MaxValue || centralOffset == UInt32.MaxValue)
            {
                byte[] locator = ReadAt(file, endOffset - 20, 20);
                if (U32(locator, 0) != 0x07064b50U || U32(locator, 4) != 0 || U32(locator, 16) != 1) throw new InvalidDataException("ZIP64 locator invalid");
                long zip64Offset = U64(locator, 8);
                byte[] record = ReadAt(file, zip64Offset, 56);
                long recordLength = U64(record, 4);
                if (U32(record, 0) != 0x06064b50U || recordLength < 44 || zip64Offset > endOffset - 32 || recordLength != endOffset - 32 - zip64Offset || U32(record, 16) != 0 || U32(record, 20) != 0 || U64(record, 24) != U64(record, 32)) throw new InvalidDataException("ZIP64 end record invalid");
                entries = U64(record, 32);
                centralSize = U64(record, 40);
                centralOffset = U64(record, 48);
                centralLimit = zip64Offset;
            }
            if (entries > Int32.MaxValue || centralOffset > centralLimit || centralSize > centralLimit - centralOffset || entries > centralSize / 46) throw new InvalidDataException("central directory bounds invalid");
            long centralEnd = centralOffset + centralSize;
            CentralEntry[] result = new CentralEntry[(int)entries];
            long position = centralOffset;
            for (int index = 0; index < result.Length; index++)
            {
                if (position > centralEnd - 46) throw new InvalidDataException("truncated central directory");
                byte[] header = ReadAt(file, position, 46);
                if (U32(header, 0) != 0x02014b50U) throw new InvalidDataException("central header invalid");
                int nameLength = U16(header, 28), extraLength = U16(header, 30), commentLength = U16(header, 32);
                long next = position + 46L + nameLength + extraLength + commentLength;
                if (nameLength == 0 || next > centralEnd) throw new InvalidDataException("central record bounds invalid");
                CentralEntry item = new CentralEntry();
                item.flags = U16(header, 8);
                item.method = U16(header, 10);
                item.crc = U32(header, 16);
                item.compressed_length = U32(header, 20);
                item.length = U32(header, 24);
                item.local_offset = U32(header, 42);
                item.central_offset = centralOffset;
                item.name_bytes = ReadAt(file, position + 46L, nameLength);
                // Fail closed on invalid names on both framework runtimes.
                StrictUtf8.GetString(item.name_bytes);
                long disk = U16(header, 34);
                byte[] extra = ReadAt(file, position + 46L + nameLength, extraLength);
                bool foundZip64 = false;
                for (int offset = 0; offset < extra.Length; )
                {
                    if (extra.Length - offset < 4) throw new InvalidDataException("central extra field truncated");
                    int type = U16(extra, offset), size = U16(extra, offset + 2);
                    offset += 4;
                    if (size > extra.Length - offset) throw new InvalidDataException("central extra field bounds invalid");
                    if (type == 1)
                    {
                        if (foundZip64) throw new InvalidDataException("duplicate ZIP64 extra field");
                        foundZip64 = true;
                        int cursor = offset;
                        if (item.length == UInt32.MaxValue) item.length = Extra64(extra, ref cursor, offset + size);
                        if (item.compressed_length == UInt32.MaxValue) item.compressed_length = Extra64(extra, ref cursor, offset + size);
                        if (item.local_offset == UInt32.MaxValue) item.local_offset = Extra64(extra, ref cursor, offset + size);
                        if (disk == UInt16.MaxValue)
                        {
                            if (cursor > offset + size - 4) throw new InvalidDataException("ZIP64 disk field missing");
                            disk = U32(extra, cursor);
                        }
                    }
                    offset += size;
                }
                if ((!foundZip64 && (item.length == UInt32.MaxValue || item.compressed_length == UInt32.MaxValue || item.local_offset == UInt32.MaxValue || disk == UInt16.MaxValue)) || disk != 0 || item.local_offset >= centralOffset || item.compressed_length > centralOffset - item.local_offset) throw new InvalidDataException("central member metadata invalid");
                result[index] = item;
                position = next;
            }
            if (position != centralEnd) throw new InvalidDataException("unexpected central directory data");
            return result;
        }

        private static void ValidateLocalHeader(FileStream file, CentralEntry item)
        {
            byte[] header = ReadAt(file, item.local_offset, 30);
            if (U32(header, 0) != 0x04034b50U || U16(header, 6) != item.flags || U16(header, 8) != item.method) throw new InvalidDataException("local header differs from central header");
            int nameLength = U16(header, 26), extraLength = U16(header, 28);
            long dataOffset = item.local_offset + 30L + nameLength + extraLength;
            if (nameLength != item.name_bytes.Length || dataOffset > item.central_offset || item.compressed_length > item.central_offset - dataOffset) throw new InvalidDataException("local data bounds invalid");
            byte[] name = ReadAt(file, item.local_offset + 30L, nameLength);
            for (int index = 0; index < name.Length; index++)
                if (name[index] != item.name_bytes[index]) throw new InvalidDataException("local member name differs from central name");
            byte[] extra = ReadAt(file, item.local_offset + 30L + nameLength, extraLength);
            long length = U32(header, 22), compressedLength = U32(header, 18);
            bool foundZip64 = false;
            for (int offset = 0; offset < extra.Length; )
            {
                if (extra.Length - offset < 4) throw new InvalidDataException("local extra field truncated");
                int type = U16(extra, offset), size = U16(extra, offset + 2);
                offset += 4;
                if (size > extra.Length - offset) throw new InvalidDataException("local extra field bounds invalid");
                if (type == 1)
                {
                    if (foundZip64) throw new InvalidDataException("duplicate local ZIP64 extra field");
                    foundZip64 = true;
                    int cursor = offset;
                    if (length == UInt32.MaxValue) length = Extra64(extra, ref cursor, offset + size);
                    if (compressedLength == UInt32.MaxValue) compressedLength = Extra64(extra, ref cursor, offset + size);
                }
                offset += size;
            }
            if ((item.flags & 8) == 0 && (U32(header, 14) != item.crc || length != item.length || compressedLength != item.compressed_length)) throw new InvalidDataException("local CRC or lengths differ from central metadata");
        }

        private static long Extra64(byte[] bytes, ref int cursor, int limit)
        {
            if (cursor > limit - 8) throw new InvalidDataException("ZIP64 extra field missing");
            long result = U64(bytes, cursor);
            cursor += 8;
            return result;
        }

        private static byte[] ReadAt(FileStream file, long offset, int count)
        {
            if (offset < 0 || count < 0 || offset > file.Length - count) throw new InvalidDataException("ZIP read bounds invalid");
            byte[] bytes = new byte[count];
            file.Position = offset;
            int used = 0;
            while (used < count)
            {
                int read = file.Read(bytes, used, count - used);
                if (read == 0) throw new EndOfStreamException();
                used += read;
            }
            return bytes;
        }

        private static ushort U16(byte[] bytes, int offset) { return (ushort)(bytes[offset] | (bytes[offset + 1] << 8)); }
        private static uint U32(byte[] bytes, int offset) { return (uint)(bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)); }
        private static long U64(byte[] bytes, int offset)
        {
            ulong value = (ulong)U32(bytes, offset) | ((ulong)U32(bytes, offset + 4) << 32);
            if (value > Int64.MaxValue) throw new InvalidDataException("ZIP64 value outside Int64");
            return (long)value;
        }

        private static string Row(long epoch) { return Count(epoch) + ",2,3,1,2,0,0"; }

        private static Q1ArchiveSummary Fixture(string path, string[] names, byte[][] contents)
        {
            using (FileStream file = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            using (ZipArchive archive = new ZipArchive(file, ZipArchiveMode.Create, false, StrictUtf8))
                for (int index = 0; index < names.Length; index++)
                    using (Stream stream = archive.CreateEntry(names[index], CompressionLevel.Optimal).Open())
                        stream.Write(contents[index], 0, contents[index].Length);
            return Scan(path);
        }

        private static void Check(bool condition, string name, List<string> passed)
        {
            if (!condition) throw new InvalidOperationException("ArchiveProbe SelfTest failed: " + name);
            passed.Add(name);
        }

        public static string[] SelfTest()
        {
            List<string> passed = new List<string>();
            string directory = Path.Combine(Path.GetTempPath(), "cfa-q1-archive-" + Guid.NewGuid().ToString("N") + "-é-'quoted");
            Directory.CreateDirectory(directory);
            try
            {
                byte[] valid = StrictUtf8.GetBytes(Row(StartEpoch) + "\r\n" + Row(EndEpoch - 60));
                byte[] other = new byte[] { 0, 255, 128, 42 };
                Q1ArchiveSummary result = Fixture(Path.Combine(directory, "valid.zip"), new string[] { "données/", "données/XBTUSD_1.csv", "XBTUSD_60.csv", "metadata.bin" }, new byte[][] { new byte[0], valid, other, other });
                Check(result.status == "PASS" && result.members.Length == 4 && result.one_minute_member_count == 1 && result.rows == 2 && result.source_stable, "valid_crlf_unterminated_unicode_quoted_path", passed);
                using (SHA256 sha = SHA256.Create())
                {
                    Check(result.members[1].sha256 == Hex(sha.ComputeHash(valid)) && result.members[1].length_bytes == valid.Length && result.members[2].sha256 == Hex(sha.ComputeHash(other)) && result.members[3].sha256 == result.members[2].sha256, "exact_bytes_all_members_and_other_intervals", passed);
                }
                Check(result.members[1].min_epoch == StartEpoch && result.members[1].max_epoch == EndEpoch - 60 && result.members[1].days.Length == 2 && result.members[1].days[0].day_utc == "2026-01-01" && result.members[1].days[1].day_utc == "2026-03-31", "q1_inclusive_start_exclusive_end_and_days", passed);
                result = Fixture(Path.Combine(directory, "boundaries.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { StrictUtf8.GetBytes(Row(StartEpoch - 60) + "\n" + Row(StartEpoch) + "\n" + Row(StartEpoch + 1) + "\n" + Row(EndEpoch) + "\n") });
                Check(result.status == "FAIL" && result.rows == 4 && result.members[0].out_of_q1_rows == 2 && result.members[0].off_minute_rows == 1 && result.members[0].invalid_rows == 0, "outside_q1_and_off_minute_counters", passed);
                result = Fixture(Path.Combine(directory, "ordering.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { StrictUtf8.GetBytes(Row(StartEpoch + 60) + "\n" + Row(StartEpoch + 60) + "\n" + Row(StartEpoch)) });
                Check(result.status == "FAIL" && result.members[0].duplicate_or_decreasing_rows == 2, "duplicate_and_decreasing_epochs", passed);
                byte[] malformed = new byte[valid.Length + 2];
                Array.Copy(valid, malformed, valid.Length);
                malformed[valid.Length] = 0xc3; malformed[valid.Length + 1] = 0x28;
                result = Fixture(Path.Combine(directory, "utf8.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { malformed });
                Check(result.status == "FAIL" && result.members[0].invalid_rows == 1 && result.members[0].read_complete && result.members[0].sha256 != null, "malformed_utf8_still_hashes_complete_member", passed);
                string invalid = "epoch,open,high,low,close,volume,trades\n" + Row(StartEpoch) + ",8\n" + "\"" + Row(StartEpoch) + "\"\n" + Count(StartEpoch) + ",NaN,3,1,2,0,0\n" + Count(StartEpoch) + ",2,1,3,2,0,0\n" + Count(StartEpoch) + ",2,3,1,2,-1,0\n" + Count(StartEpoch) + ",2,3,1,2,0,2147483648\n" + Count(StartEpoch) + ",0,3,1,2,0,0\n" + Count(StartEpoch) + ",2,3,1,2,Infinity,0\n" + "9223372036854775808,2,3,1,2,0,0\n";
                result = Fixture(Path.Combine(directory, "invalid.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { StrictUtf8.GetBytes(invalid) });
                Check(result.status == "FAIL" && result.rows == 10 && result.members[0].invalid_rows == 10, "headers_csv_quotes_nonfinite_ohlc_volume_trades_integer_overflow", passed);
                result = Fixture(Path.Combine(directory, "numeric-grammar.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { StrictUtf8.GetBytes(Count(StartEpoch) + ",2,3,1,2,-1e-9999,0\n" + Count(StartEpoch + 60) + ",2,3,1,2,0,0\0\n" + Count(StartEpoch + 120) + ",2\0,3,1,2,0,0\n") });
                Check(result.status == "FAIL" && result.rows == 3 && result.members[0].invalid_rows == 3, "negative_volume_underflow_and_embedded_nul_rejected", passed);
                result = Fixture(Path.Combine(directory, "decimal-order.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { StrictUtf8.GetBytes(Count(StartEpoch) + ",2.0000000000000001,2,1,2,0,0\n" + Count(StartEpoch + 60) + ",2,3,2.0000000000000001,2,0,0\n" + Count(StartEpoch + 120) + ",+2.00,2e0,0.2e1,2.,-0e-10000,0\n") });
                Check(result.status == "FAIL" && result.rows == 3 && result.members[0].invalid_rows == 2, "exact_decimal_ohlc_order_and_equivalent_spelling", passed);
                result = Fixture(Path.Combine(directory, "lines.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { StrictUtf8.GetBytes(new string('9', MaximumLineBytes + 100000) + "\r\n\n" + Row(StartEpoch) + "\r" + Row(StartEpoch + 60) + "\n") });
                Check(result.status == "FAIL" && result.rows == 4 && result.members[0].invalid_rows == 2 && result.members[0].read_complete, "bounded_long_empty_lines_lf_crlf_cr", passed);
                result = Fixture(Path.Combine(directory, "duplicates.zip"), new string[] { "A/XBTUSD_1.csv", "a/xbtusd_1.csv", "B/XBTUSD_1.csv" }, new byte[][] { valid, valid, valid });
                Check(result.status == "FAIL" && Array.IndexOf(result.members[1].errors, "duplicate_normalized_member_path") >= 0 && Array.IndexOf(result.members[2].errors, "duplicate_one_minute_pair_code") >= 0, "duplicate_paths_case_and_pair_codes", passed);
                result = Fixture(Path.Combine(directory, "ancestor.zip"), new string[] { "folder", "folder/XBTUSD_1.csv" }, new byte[][] { other, valid });
                Check(result.status == "FAIL" && Array.IndexOf(result.members[1].errors, "regular_file_is_member_path_ancestor") >= 0, "regular_file_path_ancestor_conflict", passed);
                result = Fixture(Path.Combine(directory, "unsafe.zip"), new string[] { "../XBTUSD_1.csv", "_1.csv", "XBTUSD_01.csv", "data.csv", "XBTUSD_1.csv " }, new byte[][] { valid, valid, valid, valid, valid });
                Check(result.status == "FAIL" && result.one_minute_member_count == 4 && Array.IndexOf(result.members[0].errors, "unsafe_member_path") >= 0 && Array.IndexOf(result.members[1].errors, "malformed_ohlcvt_member_name") >= 0 && Array.IndexOf(result.members[4].errors, "malformed_ohlcvt_member_name") >= 0, "unsafe_and_malformed_one_minute_names_not_skipped", passed);
                result = Fixture(Path.Combine(directory, "empty.zip"), new string[0], new byte[0][]);
                Check(result.status == "FAIL" && result.members.Length == 0 && result.rows == 0, "empty_archive_array_shapes", passed);
                result = Fixture(Path.Combine(directory, "zero.zip"), new string[] { "XBTUSD_1.csv" }, new byte[][] { new byte[0] });
                Check(result.status == "FAIL" && result.members.Length == 1 && result.members[0].days.Length == 0 && result.members[0].min_epoch == null && result.members[0].sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "zero_one_minute_member_exact_empty_hash", passed);
                result = Fixture(Path.Combine(directory, "other-only.zip"), new string[] { "XBTUSD_60.csv" }, new byte[][] { other });
                Check(result.status == "FAIL" && result.one_minute_member_count == 0 && result.members[0].read_complete, "no_one_minute_members", passed);
                string corruptPath = Path.Combine(directory, "crc.zip");
                Fixture(corruptPath, new string[] { "XBTUSD_1.csv" }, new byte[][] { valid });
                byte[] corrupt = File.ReadAllBytes(corruptPath);
                for (int index = 0; index < corrupt.Length - 46; index++)
                    if (U32(corrupt, index) == 0x02014b50U) { corrupt[index + 16] ^= 1; break; }
                File.WriteAllBytes(corruptPath, corrupt);
                result = Scan(corruptPath);
                Check(result.status == "FAIL" && Array.IndexOf(result.members[0].errors, "crc32_mismatch") >= 0, "crc32_corruption_detected", passed);
                string localPath = Path.Combine(directory, "local-header.zip");
                Fixture(localPath, new string[] { "XBTUSD_1.csv" }, new byte[][] { valid });
                byte[] local = File.ReadAllBytes(localPath);
                local[30] = (byte)'/';
                File.WriteAllBytes(localPath, local);
                result = Scan(localPath);
                Check(result.status == "FAIL" && result.members[0].read_complete && Array.IndexOf(result.members[0].errors, "local_header_invalid:InvalidDataException") >= 0, "local_central_name_mismatch_still_hashes_member", passed);
                Check(Scan(Path.Combine(directory, "missing.zip")).status == "FAIL", "missing_archive", passed);
                return passed.ToArray();
            }
            finally { Directory.Delete(directory, true); }
        }
    }
}
