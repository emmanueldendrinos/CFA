# Q1 coverage evidence probe — frozen contract v1

Status: VALIDATION CANDIDATE until Q1-COV-001-LOCAL has direct evidence.
This is a read-only evidence collector supporting Q1-S1-001/002/003 review.
It does not approve any stage, source, mapping, DATA identifier, or news contract.
Existing frozen stage order remains in force; results are recorded separately.

## Frozen requirements

| ID | Requirement / exit evidence |
| --- | --- |
| Q1-COV-001-BIND | Validate the exact prior census receipt SHA-256 and every artifact hash/size, successful census status and shapes. Bind the exact runner/helper/query bytes, repository HEAD, unchanged bootstrap manifest/SoT and Q1 UTC interval. Rehash the selected archive against its census observation before inspecting content. Explicit expected-receipt overrides permit isolated synthetic tests, never a silent fallback. |
| Q1-COV-001-ARCHIVE | Read only the census-identified Kraken_OHLCVT_Q1_2026.zip. No extraction or writes to source roots. Inventory every ZIP member with exact uncompressed SHA-256 and bytes; reject unsafe/duplicate paths and malformed or unreadable members. Stream the one-minute *_1.csv members as strict UTF-8, seven-field headerless Kraken OHLCVT rows. Record exact rows, timestamp bounds, out-of-Q1/off-minute rows, malformed/nonfinite/invalid OHLCVT values, repeated or decreasing timestamps, and per-day counts. Other intervals are hashed but not treated as one-minute input. Zero one-minute rows cannot pass. Do not infer missing-minute failure: eligibility and no-trade semantics are not frozen. |
| Q1-COV-001-MARKET | Only after archive checks pass, read srp.srp.ohlcvt_1m_2026q1 and the observed source_archives/market_pairs/processing_runs lineage tables. Record catalog types/partition metadata, exact rows, pair/day counts, timestamps, nulls, duplicate pair-time keys, invalid/nonfinite OHLCVT, source/run links and archive registration matches. Compare selected member pair codes/counts/bounds with database summaries; differences are explicit. Aggregates and matching metadata only; no raw market-row export. Equality of counts/bounds is not proof of row-value equality or source approval. |
| Q1-COV-001-NEWS | Read cfa.source_news contract fields excluding URLs, plus exact Q1 slot aggregates by contract/status/day, distinct timestamp/key counts, bounds, hash/size metadata presence and contract interval overlap. Missing Q1 contracts/slots remain explicit. Do not invent the news population/cadence, trust a SUCCESS string as payload proof, read news payloads, or acquire anything. A diagnostic collection does not execute or approve Q1-S1-003/004. |
| Q1-COV-001-SAFETY | Fixed database/relation identities. SELECT only in verified READ ONLY REPEATABLE READ transactions with UTC, safe search_path, 5s connect/lock and bounded statement/process timeouts. One password prompt only when absent; no secrets in arguments/evidence/Git. Clear inherited libpq routing overrides and restore environment. Reject reparse ancestors and unsafe/overlapping output paths. Never change original census, source data, bootstrap, Q2 files, or database. No automatic public upload, downloads, imports, mapping, factors or PLS. |
| Q1-COV-001-RECEIPT | Unique directory under CFA-local/q1-coverage-probe/2026Q1. Produce archive-members.jsonl, archive-summary.json, market.json, news.json, reconciliation.json, errors.json, receipt.json, with exact artifact hashes/sizes, collection/check states and remaining limitations. Partial failures must leave evidence and nonzero exit. All collection fields preserve array shapes, including empty/singleton. Raw source rows/passwords are excluded. Archive failure blocks later probes; a market failure does not erase the independent news discovery diagnostic. Stage1 and DATA-001/002/003 remain BLOCKED/UNVERIFIED. |
| Q1-COV-001-TEST | Parse/compile and component tests, then exact full runner subprocess on Windows PowerShell 5.1 and PowerShell 7 with disposable real PostgreSQL. Cover empty/singleton, exact boundaries, malformed UTF-8/CSV/numbers, duplicate/order problems, quoting/Unicode paths, missing/tampered census/archive, offline/timeout, schema/lineage discrepancies, repeated execution and source/environment preservation. Every edit invalidates dependent test evidence. |
| Q1-COV-001-LOCAL | Execute the exact delivered revision on the user's Windows/archive/PostgreSQL targets and inspect all resulting evidence. CI fixture success is not target-source verification. Keep this ID UNVERIFIED until evidence returns. |

## States and delivery

Collection PASS means all authorized observations were produced; reconciliation
checks may still FAIL/UNVERIFIED, and Stage 1 stays BLOCKED. Archive/market checks
are separate from source approval. Missing authoritative member lineage or raw
record equivalence is explicitly UNVERIFIED, even when aggregate counts match.
Exit 0 means collection and implemented checks passed; exit 2 means collected
failure/discrepancy; exit 1 means preflight failed before evidence creation.

Delivery is a pinned repository branch/commit and one exact Windows PowerShell
command, following the demonstrated census workflow. No ZIP installer or UI is
needed. Return the generated metadata privately; no automatic public publication.
The original bootstrap and census contracts/receipts remain byte-identical.
