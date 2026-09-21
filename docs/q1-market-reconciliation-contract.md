# Q1 market reconciliation — frozen contract v1

Task: Q1-MKT-001. Status: VALIDATION CANDIDATE until Q1-MKT-001-LOCAL has
direct evidence from the intended Windows/archive/PostgreSQL environment.
This read-only task supplies evidence for Q1-S1-001/002. It does not advance
either stage, approve historical import provenance, define news inputs, acquire
data, modify source data, or alter any existing frozen contract or receipt.

## Requirements

| ID | Frozen requirement / exit evidence |
| --- | --- |
| Q1-MKT-001-BIND | Validate the exact preceding coverage receipt SHA-256 and all six artifact hashes/sizes/shapes; require collection PASS, empty errors, passing archive/market checks, allowing the documented missing-news check to FAIL. Bind its original census and three artifact hashes, bootstrap manifest, SoT, selected archive hash/size, interval, endpoint, and unchanged coverage code. Bind the new exact code bytes and Git revision. Reject missing, ambiguous, malformed, unsafe, or tampered bindings before source reads. |
| Q1-MKT-001-CANON | Version cfa.ohlcvt.binary52/v1: each row is big-endian int64 UTC epoch seconds, five IEEE-754 binary64 values in open/high/low/close/volume order, and signed int32 trades (52 bytes). Convert strict decimal source tokens by exact rational arithmetic with round-to-nearest, ties-to-even, independently of host floating parsers. Normalize both signs of zero to positive zero; reject nonfinite/overflow and nonzero underflow to zero. No tolerance, text-format comparison, imputation, or VWAP synthesis. SHA-256 hashes concatenate these fixed-width rows in strictly increasing timestamp order within each exact member/pair/UTC day. Compare exact key sets, counts, minimum/maximum epochs, and hashes. |
| Q1-MKT-001-ARCHIVE | Reopen only the census-bound Q1 archive with a read-only sharing lock and recheck its exact whole-file SHA-256/size before and after inspection. Match the complete member inventory and names against the bound coverage observation; its byte-identical ZIP preserves prior CRC/structural validation. Rehash every one-minute member and stream strict seven-field UTF-8 CSV with bounded lines, valid OHLCVT, minute-aligned increasing Q1 timestamps and int32 trades. Reject empty selected populations and mismatches. No extraction or raw source-row export. |
| Q1-MKT-001-SNAPSHOT | One srp READ ONLY REPEATABLE READ UTC transaction with pg_catalog search_path. Catalog-gate exact builtin types and ordinary relations without RLS before relation access; retain read locks and recheck. Recheck all observed row/key/null/finite/time/grain/source/run invariants and exact pair mapping, selected archive registration, byte length and run links. Reject invalid population before digest aggregation so at most 1,440 rows contribute to a pair/day digest. PostgreSQL uses ordered bytea string_agg, sha256, int8send/float8send/int4send; no extension or database objects are installed. |
| Q1-MKT-001-VALUES | Reconcile every selected archive row to the current table through complete ordered pair/day fingerprints, not samples or aggregate counts alone. Missing/extra keys, value changes, timestamp changes, source/run mismatch, duplicates or malformed/truncated digest evidence fail. Retain bounded member and pair/day metadata only. VWAP must remain NULL because it is not a source field. Current content correspondence does not prove that the historical importer read these members. |
| Q1-MKT-001-LINEAGE | Record current source/archive/run/pair links and inspect selected archive inventory path references and importer config key names/hash metadata, excluding config values and credentials. Never execute referenced paths. Hash referenced inventories only when uniquely bound by the preceding census inside confirmed roots, with safe paths and matching prior bytes; otherwise record unavailable/out-of-scope explicitly. Historical import-member attribution remains UNVERIFIED pending direct authoritative evidence, even if all content fingerprints match. Mutable staging tables and prior-quarter records are not authority. |
| Q1-MKT-001-SAFETY | Fixed database/relations and validated hash parameters only. No source/database/SoT/bootstrap/Q2 changes, acquisition, news reads, mapping, factors, or PLS. One password prompt with process-environment handling only; no credentials in arguments/evidence/Git. Bound connection/lock/statement/process timeouts; drain stderr without exporting it; kill timed-out children and restore libpq environment. Reject reparse ancestors and overlapping source/input/output paths. Preserve original evidence and create a unique CFA-local/q1-market-reconciliation/2026Q1 run directory. No automatic publication of returned evidence. |
| Q1-MKT-001-RECEIPT | Export typed JSON metadata and UTF-8 TSV digest files with exact SHA-256/size inventories, canonicalization version, code bindings, counts, comparison results and explicit limitations. Preserve empty/singleton array shapes. Partial collection leaves failed evidence and nonzero exit. Separate collection/check/local/current-content/historical-provenance states. Stage 1 remains BLOCKED; DATA-001/002/003 remain UNVERIFIED. |
| Q1-MKT-001-TEST | Parse and compile, canonicalization/component tests, then exact final runner subprocess under Windows PowerShell 5.1 and PowerShell 7 with isolated real PostgreSQL. Test count-preserving value mutations, key/time changes, malformed/null/overflow inputs, signed zero and decimal rounding boundaries, schema/view/RLS drift, binding tampering, quoting/Unicode/reparse paths, offline/timeout/partial output, repeat preservation, secrets and environment restoration. Test fixtures may write only after proving the dedicated disposable server identity. Every correction invalidates affected downstream evidence. |
| Q1-MKT-001-LOCAL | Run the exact delivered revision and command against the user's Windows/Q1 archive/PostgreSQL endpoint and inspect all returned evidence. CI fixtures do not prove source equivalence. Keep this ID UNVERIFIED until that evidence returns. |

## Delivery and interpretation

Deliver a pinned Git revision and one Windows PowerShell command using the
demonstrated clone-to-temporary-directory workflow. This is a validation
candidate while the local gate remains UNVERIFIED. Existing files are preserved.

The digest TSV format has a header and six columns: pair_id, day_utc, rows,
min_epoch, max_epoch, sha256; rows are sorted by numeric pair_id then UTC day.
No raw OHLCVT values appear in evidence. Missing days are not synthesized and
no missing-minute or market-eligibility policy is inferred.

Exit 0 means authorized collection and implemented comparison checks passed;
exit 2 means collected failure/discrepancy; exit 1 means preflight failure.
Historical provenance, source authority, DATA identifiers, news coverage and
stage approval remain separate gates, irrespective of exit code.

PostgreSQL primitives are documented in its official
[binary string functions](https://www.postgresql.org/docs/18/functions-binarystring.html)
and [aggregate functions](https://www.postgresql.org/docs/18/functions-aggregate.html).
