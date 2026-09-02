# CFA Stage 6 data-quality and leakage freeze — 2026-09-02

Status: **STAGE6_FROZEN / CFA-S6-001_PASS / CFA-S6-002_PASS / CFA-S6-003_PASS / CFA-S6-004_PASS / CFA-S6-005_PASS / CFA-S6-006_PASS / CFA-S6-007_PASS / CFA-S6-008_PASS / CFA-S6-009_PASS**

## Authority and source

This evidence records the direct local Stage 6 validation and freeze-candidate finalization over the exact frozen Stage 4 response artifact and frozen Stage 5 factor artifact.

Stage 4 response SHA-256:

`8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`

Stage 5 factor CSV SHA-256:

`c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`

## Exact Stage 6 local validation result

The local validator reported:

- rows / bases / days: **37,058 / 434 / 91**;
- market available / missing: **36,505 / 553**;
- news 24h available / source-incomplete / outside-population: **27,267 / 9,518 / 273**;
- news 6h available / source-incomplete / outside-population: **28,849 / 7,936 / 273**;
- blocking violations: **0**;
- `CFA-S6-001` through `CFA-S6-008`: **PASS**.

Local Stage 6 validation directory:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb`

Validation receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb\stage6-dq-leakage-validation.json`

Validation receipt SHA-256:

`5c8fd64d367af847ea1efa25e34cddca05239186282c6d97a4ca70de104a3089`

Reject CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb\stage6-dq-leakage-rejects.csv`

Reject CSV SHA-256:

`501d085b1edc7d5c7eac425b190e5ee3a503ec66ee2e2876ad3b42c9e56fe07b`

The finalizer verified that the reject artifact is header-only, consistent with zero blocking violations.

Descriptive diagnostics CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb\stage6-dq-descriptive-diagnostics.csv`

Descriptive diagnostics SHA-256:

`f3c06e7414c80cf07f5d9186961019d737da6a2980b8e18ae0e535b1a978849e`

The finalizer verified the expected response plus seven-factor diagnostic variable set.

Freeze candidate:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb\stage6-freeze-candidate.json`

Freeze candidate SHA-256:

`cce6e7772beb385880390c943e04cc4e987bbaa12b87cdf049d81e9223aa83a2`

## Gate decision

`CFA-S6-001 = PASS` — exact frozen Stage 4/5 entry hashes and cardinalities reconcile.

`CFA-S6-002 = PASS` — grain, schema, encoding, deterministic ordering, and key cardinality reconcile.

`CFA-S6-003 = PASS` — market/news missingness semantics and frozen partitions reconcile.

`CFA-S6-004 = PASS` — defined response/factor values are finite and satisfy the frozen numeric/domain constraints; descriptive diagnostics were emitted separately and are not used as arbitrary hard thresholds.

`CFA-S6-005 = PASS` — response/cutoff ordering is consistent with the frozen Stage 4 contract.

`CFA-S6-006 = PASS` — market witness windows/formulas are cutoff-safe and no market leakage violation was observed.

`CFA-S6-007 = PASS` — news lag/window/null rules are cutoff-safe and no news leakage violation was observed.

`CFA-S6-008 = PASS` — cross-field lineage, material witness hashes/record identifiers, and fail-closed conditions pass.

`CFA-S6-009 = PASS` — the Stage 6 validation result is frozen on the exact receipt/reject/diagnostic/freeze-candidate hashes recorded above.

## Completion boundary

**Stage 6 is complete and frozen.**

The required project sequence may now advance to Stage 7: freeze the model-ready dataset and validation design. Stage 7 must explicitly define the retained model population, predictor matrix, response set, time split, preprocessing, leakage controls, and benchmark plan before any PLS programming begins.
