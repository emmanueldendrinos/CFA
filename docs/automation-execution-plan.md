# CFA Automation Execution Plan

Status: implementation plan only. The CFA Source of Truth remains authoritative. This document does not approve mappings, sources, factors, responses, datasets, validation designs, or PLS readiness.

## Frozen automation tasks

| Task | Purpose | Hard completion condition |
|---|---|---|
| CFA-AUTO-001 | Export the current CFA SoT into reviewable text/JSON evidence without Excel automation. | Export self-test PASS; snapshot source SHA-256 equals current workbook SHA-256. |
| CFA-AUTO-002 | Reconcile AF-001/AF-002/AF-003 exact filenames, parsed shape, bytes, and SHA-256 to the SoT registry. | All three sources PASS exact row count, columns, bytes, and SHA-256. Any repair is permitted only when a deterministic encoding/line-ending candidate exactly reproduces the SoT bytes and SHA-256. |
| CFA-AUTO-003 | Diagnose the incomplete PostgreSQL news acquisition without modifying PostgreSQL. | Direct event/object/hash/gap/schema evidence is published; stop cause is PASS only if directly established, otherwise UNVERIFIED. |
| CFA-AUTO-004 | Run the remaining Stage 1 local checks with one PostgreSQL credential prompt and publish evidence automatically. | Exact Windows/PowerShell/PostgreSQL execution succeeds and publishes remote evidence. Project Stage 1 may still be BLOCKED. |
| CFA-AUTO-005 | Implement a CFA-authorized reproducible news-source completion or replacement path. | Complete selected source population, hashes, timestamps, rejects, counts, lineage, and required interval all reconcile PASS. |
| CFA-AUTO-006 | Automate identity/mapping review only after Stage 1 source gates PASS. | Every approved identity has independent review evidence; unresolved/ambiguous candidates remain explicit and cannot be auto-approved. |
| CFA-AUTO-007 | Define and validate news matching from approved identities plus tested aliases. | Matching population, alias/context rules, timestamp semantics, false-positive/false-negative review, and lineage are frozen. |
| CFA-AUTO-008 | Define and freeze response variables. | Exact response formulas, cutoffs, windows, units, grain, missing policy, and availability timing are PASS. |
| CFA-AUTO-009 | Define candidate market/news factors. | Each factor has exact formula, source fields, grain, lookback, lag, missing policy, scaling, and validation result. |
| CFA-AUTO-010 | Run data-quality and leakage gates. | Required null/duplicate/cardinality/boundary/encoding/time-order/leakage/failure-path tests PASS; any predictor using post-cutoff information is blocking FAIL. |
| CFA-AUTO-011 | Freeze the model-ready dataset and validation design. | Predictor matrix, responses, time split, preprocessing, leakage controls, benchmark plan, hashes, and lineage are frozen and PASS. |
| CFA-AUTO-012 | Program and validate PLS. | PLS begins only after CFA-AUTO-011 PASS; implementation and benchmark validation use the exact frozen dataset/design. |

## Automated stage flow

### Stage 1 — sources and coverage

Repository CI:
1. Parse all PowerShell under PowerShell 7 and Windows PowerShell 5.1.
2. Run component self-tests.
3. Export `CFA-SoT.xlsx` to `docs/evidence/sot-authority-snapshot.md/json`.
4. Reconcile AF-001/AF-002/AF-003 against the SoT registry.
5. Guarded repair is limited to candidates whose exact reconstructed bytes and SHA-256 equal the SoT registry.
6. Commit only allowed evidence/source paths.
7. Fail the hard gate if exact reconciliation remains unresolved.

Local Stage 1 runner:
1. Reuse frozen Kraken PASS evidence unless a dependency invalidates it.
2. Prompt once for PostgreSQL credentials and keep the password only in process memory/environment.
3. Run corrected read-only news-source coverage verification.
4. Run deeper read-only news-acquisition diagnosis.
5. Publish the latest bounded evidence through the repository sync wrapper.
6. Evaluate Stage 1 hard gates.
7. Stop automatically if any upstream source gate is FAIL, UNVERIFIED, or BLOCKED.

### Stage 1 news recovery

After CFA-AUTO-003 evidence is published:
1. Determine from direct evidence whether the existing acquisition stopped because of a recorded source/parser failure, external interruption, or an unresolved cause.
2. Do not resume a legacy implementation merely because it exists.
3. Define the CFA news source population and required interval from the SoT plus directly inspected source evidence.
4. Implement idempotent acquisition with source URL/key, source timestamp, payload hash, compressed bytes, load/run ID, status, rejects, retries/resume, and reconciliation.
5. Re-run completeness, hash, timestamp, duplicate, malformed-input, retry/resume, and failure-path checks.
6. Set CFA-S1-010 PASS only when the full selected source population reconciles.

### Stage 2 — identities and aliases

Unlocked only after all Stage 1 hard gates PASS.

Automation may prepare review queues, candidate evidence, collision reports, and consistency checks. It must not convert a CoinGecko candidate into an approved mapping without independent review evidence. Zero-candidate and ambiguous-candidate assets remain unresolved until evidence supports a decision. Manual news aliases remain seed references until raw-news validation passes.

### Stages 3–7 — matching, responses, factors, quality/leakage, freeze

Each stage writes a versioned machine-readable contract and validation receipt. Corrections invalidate all downstream contracts, datasets, hashes, and tests. No downstream stage runs when its predecessor has unresolved hard gates.

### Stage 8 — PLS

PLS is mechanically disabled until the frozen model-ready receipt proves that predictor matrix, responses, temporal split, preprocessing, leakage controls, and benchmark plan are all PASS.

## Human-input minimization

The intended human interaction is limited to capabilities unavailable to the repository/CI environment, primarily local PostgreSQL/source access and any external credentials that cannot be stored in Git. Local runners prompt once per execution, generate evidence under `Documents\CFA-local`, and publish bounded receipts automatically. ChatGPT can then inspect those receipts from GitHub, correct scripts, rerun CI, and continue the next authorized stage without pasted console output.

## Safety and evidence boundary

Raw market/news data, credentials, database backups, full generated outputs, logs, and temporary files remain outside Git. Repository evidence is bounded, lineage-preserving, and contains hashes sufficient to tie receipts back to local evidence. A technically successful runner may report the project as BLOCKED; automation success is never equivalent to a hard-gate PASS.
