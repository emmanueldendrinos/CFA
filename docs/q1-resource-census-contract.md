# Q1 resource census — frozen contract v1

Status: VALIDATION CANDIDATE until Q1-RES-001-LOCAL has direct evidence.
This contract implements only resource discovery under the CFA SoT and current
automation plan. It does not verify market coverage or advance Stage 1.

## Frozen requirements (results are recorded separately)

| ID | Requirement / exit evidence |
| --- | --- |
| Q1-RES-001-CONTRACT | Bind every receipt to the bootstrap manifest, SoT, repository HEAD and exact census code SHA-256. Preserve bootstrap and all Q2 scripts/evidence unchanged. |
| Q1-RES-001-FILES | Recursively inventory the confirmed Documents/Projects/Kraken and Documents/CFA-local roots, all filenames regardless of quarter label; exact bytes, SHA-256 and UTC modification timestamps. Do not extract archives or read market/news rows. Missing roots, access errors, changed-during-hash files and skipped reparse points remain explicit and prevent collection PASS. |
| Q1-RES-001-DB | Confirmed endpoint localhost:5432, user postgres; maintenance database postgres is an explicit connection target, not an observed source. Enumerate every non-template database, including cfa and databases that disallow connections. Capture non-system schemas (including empty schemas), relations and columns, actual types and catalog row estimates explicitly labelled estimates. Never infer quarter coverage from names. |
| Q1-RES-001-SAFETY | PostgreSQL catalog SELECT only inside verified READ ONLY transactions, bounded connection/statement/lock timeouts, no DDL/DML/row scans. Prompt for a password once only if PGPASSWORD is absent; no secrets in output, command arguments or Git. Restore changed process environment in finally. No automatic downloads, source writes, database writes, source repair or public evidence upload. |
| Q1-RES-001-RECEIPT | Unique run directory under CFA-local/resource-census/2026Q1; streaming UTF-8 JSONL file inventory, UTF-8 JSON catalog inventory, errors and receipt, SHA-256 artifact inventory. Exclude the census-output subtree from input traversal and name it explicitly. No silent truncation; no same-name database output collisions. Repeated runs never overwrite prior runs. |
| Q1-RES-001-TEST | Parse/self-tests and exact full census subprocess tests on Windows PowerShell 5.1 and PowerShell 7, with real PostgreSQL on CI. Test spaces/Unicode/quotes, empty/missing roots, malformed manifest, missing executable, offline server, unusual database names, partial discovery failure, exact evidence hashes, repeated execution and source preservation. CI fixtures do not establish local resource availability. |
| Q1-RES-001-LOCAL | Execute the delivered revision on the user's Windows/source/PostgreSQL targets and inspect its receipt plus metadata inventories. Until then the research census is UNVERIFIED and Stage 1 remains BLOCKED. |

## Scope and policies

The user confirmed both roots and endpoint. The runner resolves Documents via the
Windows known-folder API; overrides are explicit parameters. Output is outside the
repository and is never part of the Kraken root. Root-volume and overlapping input
roots are rejected. Reparse points are not followed. A file hash identifies only
bytes inspected at census time; no source approval follows from its filename/hash.

Files may be large: hashing all inputs can take time. The runner reports progress.
Temporary files and the named census-output subtree are the only output writes.
Zero exit means collection succeeded, not analytical approval. Exit 2 means a
collection failure/blocked target; exit 1 means invalid invocation or bootstrap
preflight failure. No row counts derived from pg_class.reltuples are exact counts.

The frozen bootstrap stays unchanged. New evidence is separate, never written back
to its initial UNVERIFIED resource entries. DATA-001/002/003 equivalence remains
UNVERIFIED. Acquisition, mapping, factor calculation and PLS are excluded.

## Delivery

Repository PR/commit is the code artifact (no separate ZIP installer). Deliver a
VALIDATION CANDIDATE with one exact PowerShell command and identify
Q1-RES-001-LOCAL as UNVERIFIED. The runner prints its evidence directory. Return
receipt.json, catalogs.json, errors.json and files.jsonl for private review;
inventories contain metadata/hashes only, not source records or passwords.
