# CFA Stage 3 source-accounting correction — 2026-08-28

Status: **UNVERIFIED** for the corrected exact-Q2 matcher run.

## Defect

The Stage 3 precision-validation candidate at commit `b48b9d0ca514ca369b5800b3f47a0d425f31c0d3` hard-coded `ExpectedRows=9091236`.

That count came from the earlier strict UTF-8 Stage 2 scan, which recorded 135 archives with UTF-8 decoding failures and stopped reading the affected archive after a decoder exception. It is therefore not the recovered full-Q2 row population.

The later authorized Stage 2 recovery evidence (`docs/evidence/stage2-alias-recovery.md`) establishes the recovered source accounting used by Stage 3:

- archives: `7163`
- rows scanned: `9183757`
- quarantined non-27-field rows: `5`
- entry-count failures: `0`
- recovery policy: `QUARANTINE_NON_27_FIELD_ROWS;UTF8_REPLACEMENT_NONCRITICAL_ONLY;CRITICAL_AND_ALLNAMES_STRICT_VALIDATED_BY_DIAGNOSTIC`

The Stage 3 matcher already uses lenient UTF-8 decoding, so its source-accounting expectation must use the recovered row population rather than the earlier partial strict-decoder count.

## Direct local observation

Operator console output for Stage 3 run `20260827-205053-19e637bce3854d6a9bea134c0b62dec3` reported:

- rows scanned: `9183757`
- unique asset/record matches: `27185`
- matched assets: `295` of `431`
- context rejects: `213413`
- `CFA-S3-004`: `FAIL`
- matcher exit code: `2`

The observed row count exactly equals the authorized recovered Stage 2 population. The run nevertheless failed because the candidate compared it with the stale `9091236` constant. This run does not satisfy Stage 3 completion and its match hashes, samples, and downstream conclusions are invalidated by the correction.

## Correction boundary

This correction is within frozen task `S3-PREC-005` (preserve source accounting). It changes only the expected recovered-Q2 row count and adds a component self-test for the frozen source-accounting constants.

It does **not** change:

- the 431-asset news population;
- alias identities or overrides;
- `DIRECT_NAME`, `CONTEXT_NAME`, `TITLE_CRYPTO_NAME`, or `STRICT_SYMBOL_TITLE` semantics;
- GKG field positions;
- output grain `(base_asset_id, record_id)`;
- deduplication semantics;
- the malformed-row expectation of `5`.

## Gate consequences

| Gate / task | Status after correction commit, before corrected local rerun | Reason |
|---|---|---|
| `S3-PREC-005` | **UNVERIFIED** | Repository implementation changed and must pass exact-head parse/self-tests/CI. |
| `S3-PREC-007` | **UNVERIFIED** | The prior local full-Q2 run used the defective gate and is invalidated; exact corrected-head rerun is required. |
| `CFA-S3-002` | **UNVERIFIED** | Must be recomputed by the corrected exact-Q2 run. |
| `CFA-S3-004` | **UNVERIFIED** | Must be recomputed by the corrected exact-Q2 run, including duplicate-output accounting. |
| `CFA-S3-005` | **BLOCKED** | Do not review corrected accepted/rejected samples until the corrected full-Q2 run passes its source/accounting gate. |
| `CFA-S3-006` | **BLOCKED** | News matching cannot be frozen while upstream Stage 3 gates remain unresolved. |

Any further matcher correction invalidates the dependent Q2 outputs and requires the exact local run and bounded accepted/rejected review to be repeated.
