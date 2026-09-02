# CFA Stage 6 data-quality and leakage local validation — 2026-09-02

Status: **CFA-S6-001_PASS / CFA-S6-002_PASS / CFA-S6-003_PASS / CFA-S6-004_PASS / CFA-S6-005_PASS / CFA-S6-006_PASS / CFA-S6-007_PASS / CFA-S6-008_PASS / CFA-S6-009_BLOCKED**

## Authority and purpose

This evidence records the direct local execution output supplied for the Stage 6 offline data-quality and leakage validator against the exact frozen Stage 4 response artifact and frozen Stage 5 factor artifact.

The Stage 6 validation contract is:

`docs/evidence/stage6-data-quality-leakage-contract.md`

No PostgreSQL access, external network access, source reconstruction, model preprocessing, or PLS programming is part of this validation.

## Local validation artifacts

Reject CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb\stage6-dq-leakage-rejects.csv`

Descriptive diagnostics CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb\stage6-dq-descriptive-diagnostics.csv`

Validation receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb\stage6-dq-leakage-validation.json`

Exact hashes of these three local Stage 6 outputs are not reconstructed from terminal output and remain to be directly read from the local files before `CFA-S6-009` may be frozen.

## Direct observed result

```text
CFA STAGE 6 DATA QUALITY AND LEAKAGE VALIDATION: PASS
Rows / bases / days: 37058 / 434 / 91
Market available / missing: 36505 / 553
News24 available / incomplete / outside: 27267 / 9518 / 273
News6 available / incomplete / outside: 28849 / 7936 / 273
Blocking violations: 0
CFA-S6-001: PASS
CFA-S6-002: PASS
CFA-S6-003: PASS
CFA-S6-004: PASS
CFA-S6-005: PASS
CFA-S6-006: PASS
CFA-S6-007: PASS
CFA-S6-008: PASS
CFA-S6-009 Stage 6 freeze: BLOCKED
```

## Reconciliation decision

The direct run supports:

- exact factor cardinality **37,058 rows / 434 bases / 91 days**;
- market partition **36,505 available / 553 structurally missing**;
- 24-hour news partition **27,267 available / 9,518 source-incomplete / 273 outside-population**;
- 6-hour news partition **28,849 available / 7,936 source-incomplete / 273 outside-population**;
- **0 blocking violations** across the Stage 6 structural, missingness, numeric/domain, response timing, market leakage, news leakage, lineage, and failure-path gates.

Therefore `CFA-S6-001` through `CFA-S6-008` are **PASS** on this exact local run.

`CFA-S6-009` remains **BLOCKED** until the exact validation-receipt SHA-256, reject-CSV SHA-256, and descriptive-diagnostics SHA-256 are directly inspected and recorded in repository evidence. No Stage 7 model-ready dataset or validation design may be frozen before that step.
