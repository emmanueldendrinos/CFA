# Q1 market snapshot diagnostics — frozen correction v1

Task: Q1-MKT-003. The returned Q1-MKT-001 run reached archive PASS and
collection FAIL, but its generic PostgreSQL issue erased the failing step.
This correction makes that failure observable. It does not claim the unknown
local cause is fixed or change any Q1-MKT-001 acceptance criterion. The
Q1-MKT-002 launcher and process-scoped RemoteSigned behavior are preserved.

| ID | Frozen requirement / exit evidence |
| --- | --- |
| Q1-MKT-003-EVIDENCE | Verify the returned receipt and all supplied artifact hashes and sizes; reconcile complete source member and pair/day evidence. Preserve all uploaded and previous local evidence. Report absent files and distinguish receipt declarations from inspected bytes. Never publish user evidence to Git or CI. |
| Q1-MKT-003-DIAGNOSTICS | Add bounded structured diagnostics to PostgreSQL collection failures: a fixed runner phase, last recognized SQL phase, process exit code when available, elapsed time/output byte counts, and a safe failure classification. Request SQLSTATE-only server errors from psql and retain only a recognized SQLSTATE or fixed classification. Distinguish connection/authentication, SQL cancellation/lock/access/resource errors, process/transport errors and protocol/JSON parsing failures when direct evidence supports them; otherwise report UNKNOWN. Phase markers are literal psql output, not additional database reads. Markers must remain available for diagnostic classification when the process exits nonzero. |
| Q1-MKT-003-SAFETY | Never export raw stderr, exception messages/stacks, SQL text, credentials, config values or source rows. Export only fixed enums, allowlisted SQLSTATE codes and bounded numeric metadata; unrecognized error content must not be copied into evidence or console. Continue to drain and discard stderr and remove partial transport files. All original read-only transaction, catalog gates, credentials handling, endpoint binding and timeouts remain enforced. |
| Q1-MKT-003-PRESERVE | Preserve canonicalization, C# archive/digest helper, database SELECT statements and comparison rules; change only diagnostic transport/protocol handling, associated tests and this additive contract. Keep the existing ten-file run inventory and all status/exit-code semantics. Preserve census/coverage/bootstrap/SoT/manifest/Q2 files, old frozen contracts and prior results. A diagnostic failure is never a content match or stage approval. |
| Q1-MKT-003-TEST | Parse and run component tests before publishing a pinned candidate. Test diagnostics with real PostgreSQL connection rejection, authentication rejection, SQL lock/cancellation and successful execution; exercise protocol/JSON and unknown/malformed/empty error boundaries, Unicode/secret sentinels, and production-scale metadata parsing. Rerun the full exact-runner suite on Windows PowerShell 5.1 and PowerShell 7, including the Restricted-parent launcher regression, receipt inventories/hashes, failure states and preservation checks. Use only synthetic data on a proven disposable endpoint. Inspect final CI artifacts against exact code hashes. |
| Q1-MKT-003-LOCAL | Deliver one exact pinned clone/hash/run command using the established evidence directories and RemoteSigned child process. This remains a VALIDATION CANDIDATE until the actual Windows/PostgreSQL run returns diagnostic evidence for review. Q1-MKT-001-LOCAL and current content remain UNVERIFIED; historical provenance remains UNVERIFIED and Stage 1 BLOCKED. |

The existing empty market/comparison TSV declarations are not substitutes for
received bytes. They do not block diagnosis of the reported collection failure.
This correction must not silently extend timeouts, skip fresh archive checks,
reuse a failed database snapshot, or infer a database defect from placeholders.
