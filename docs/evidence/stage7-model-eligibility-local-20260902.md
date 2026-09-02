# CFA Stage 7 model-eligibility local diagnostic — 2026-09-02

Status: **CFA-S7-001_PASS / CFA-S7-002_PASS / CFA-S7-003_UNVERIFIED**

## Authority and purpose

This evidence records the direct local execution output supplied for the Stage 7 offline model-eligibility/time-support diagnostic against the exact frozen Stage 6 validation receipt and its frozen Stage 4/5 artifacts.

The Stage 7 contract is:

`docs/evidence/stage7-model-ready-contract.md`

No model fitting, hyperparameter selection, imputation, scaling, benchmark evaluation, PostgreSQL access, or external network access is part of this diagnostic.

## Local diagnostic artifacts

Availability patterns CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-eligibility\20260902-133114-c5a76153e1e84f5891a501b40e6b937b\stage7-availability-patterns.csv`

Eligibility by day CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-eligibility\20260902-133114-c5a76153e1e84f5891a501b40e6b937b\stage7-eligibility-by-day.csv`

Eligibility by asset CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-eligibility\20260902-133114-c5a76153e1e84f5891a501b40e6b937b\stage7-eligibility-by-asset.csv`

All-seven eligible keys CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-eligibility\20260902-133114-c5a76153e1e84f5891a501b40e6b937b\stage7-all-seven-eligible-keys.csv`

Variable diagnostics CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-eligibility\20260902-133114-c5a76153e1e84f5891a501b40e6b937b\stage7-complete-case-variable-diagnostics.csv`

Chronological split candidates CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-eligibility\20260902-133114-c5a76153e1e84f5891a501b40e6b937b\stage7-chronological-split-candidates.csv`

Diagnostic receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-eligibility\20260902-133114-c5a76153e1e84f5891a501b40e6b937b\stage7-model-eligibility.json`

Exact hashes of these outputs remain to be read directly from the diagnostic receipt/local files before downstream Stage 7 artifacts are frozen.

## Direct observed result

```text
CFA STAGE 7 MODEL ELIGIBILITY DIAGNOSTIC: PASS
Frozen rows / bases / days: 37058 / 434 / 91
All-seven eligible rows / bases / days: 27152 / 418 / 68
All-seven eligible first / last day: 2025-04-03 / 2025-06-14
Availability patterns: 8
Chronological split candidates: 67
CFA-S7-001 frozen Stage 6 entry: PASS
CFA-S7-002 model eligibility/time support: PASS
CFA-S7-003 model population/matrix: UNVERIFIED
```

## Gate decision

`CFA-S7-001 = PASS` — the Stage 7 diagnostic entered from the exact frozen Stage 6 receipt/source hashes and reconciled **37,058 / 434 / 91** frozen rows/bases/days.

`CFA-S7-002 = PASS` — exact predictor-availability/time support was measured without fitting or evaluating any model. The all-seven-predictor eligibility surface contains **27,152 rows across 418 assets and 68 eligible response days**, from **2025-04-03** through **2025-06-14**, with **8** material availability patterns and **67** chronological boundary candidates.

`CFA-S7-003` remains **UNVERIFIED** until the model population, embargoed chronological train/validation/test design, preprocessing parameters, and benchmark plan are explicitly frozen and reconciled to exact local hashes/counts.
