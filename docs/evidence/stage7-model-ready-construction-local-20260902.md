# CFA Stage 7 model-ready design construction evidence — 2026-09-02

Status: **CFA-S7-003_PASS / CFA-S7-004_PASS / CFA-S7-005_PASS / CFA-S7-006_PASS / CFA-S7-007_PASS / CFA-S7-008_BLOCKED**

## Source

Direct local execution output supplied after running the Stage 7 model-ready candidate constructor against the exact PASS Stage 7 eligibility receipt and frozen Stage 4/5/6 lineage.

Local candidate outputs:

- model-ready candidate: `C:\Users\Emmanuel\Documents\CFA-local\stage7-model-ready\20260902-134023-04e30bf2c0ee4dfdb42cf88a0db2b259\stage7-model-ready-candidate.csv`;
- preprocessing parameters: `C:\Users\Emmanuel\Documents\CFA-local\stage7-model-ready\20260902-134023-04e30bf2c0ee4dfdb42cf88a0db2b259\stage7-preprocessing-parameters.csv`;
- benchmark plan: `C:\Users\Emmanuel\Documents\CFA-local\stage7-model-ready\20260902-134023-04e30bf2c0ee4dfdb42cf88a0db2b259\stage7-benchmark-plan.json`;
- candidate receipt: `C:\Users\Emmanuel\Documents\CFA-local\stage7-model-ready\20260902-134023-04e30bf2c0ee4dfdb42cf88a0db2b259\stage7-model-ready-candidate-receipt.json`.

The exact split-assignment and embargo-exclusion paths and all output hashes must be read from the candidate receipt by the independent Stage 7 validator. They are not reconstructed from terminal output.

## Direct observed construction result

```text
CFA STAGE 7 MODEL-READY DESIGN CONSTRUCTION: VALIDATION CANDIDATE
Eligible rows / bases / days: 27152 / 418 / 68
TRAIN days / rows / bases: 40 / 15648 / 410
Embargo 1 day / rows: 2025-05-17 / 404
VALIDATION days / rows / bases: 13 / 5323 / 414
Embargo 2 day / rows: 2025-05-31 / 411
TEST days / rows / bases: 13 / 5366 / 418
Model rows / embargo rows: 26337 / 815
CFA-S7-003: PASS
CFA-S7-004: PASS
CFA-S7-005: PASS
CFA-S7-006: PASS
CFA-S7-007: PASS
CFA-S7-008 independent validation/freeze: BLOCKED
```

## Reconciliation

The observed role accounting reconciles exactly:

- eligible rows: **27,152**;
- model rows: **26,337**;
- embargo rows: **815**;
- `26,337 + 815 = 27,152`;
- model/evaluation days: **40 TRAIN + 13 VALIDATION + 13 TEST = 66**;
- embargo days: **2**;
- total eligible days: **68**.

Observed role detail:

- `TRAIN`: **40 days / 15,648 rows / 410 bases**;
- `EMBARGO_TRAIN_VALIDATION`: **2025-05-17 / 404 rows**;
- `VALIDATION`: **13 days / 5,323 rows / 414 bases**;
- `EMBARGO_VALIDATION_TEST`: **2025-05-31 / 411 rows**;
- `TEST`: **13 days / 5,366 rows / 418 bases**.

## Gate decision

`CFA-S7-003 = PASS` — the complete-seven-predictor population/matrix rule was constructed over the exact eligible surface without imputation.

`CFA-S7-004 = PASS` — the chronological 40/1/13/1/13 role assignment was constructed with two explicit embargo days.

`CFA-S7-005 = PASS` — phase-specific preprocessing parameter artifacts were constructed under the candidate training-only / train-plus-validation rules.

`CFA-S7-006 = PASS` — the predeclared benchmark/evaluation-plan artifact was constructed before any Stage 8 performance evaluation.

`CFA-S7-007 = PASS` — the exact raw model-ready candidate and supporting design artifacts were constructed.

`CFA-S7-008 = BLOCKED` — Stage 7 is not frozen until an independent validator recomputes exact key/role identity, chronological and embargo boundaries, preprocessing parameters, benchmark-plan identity, and all hashes from the candidate receipt and referenced artifacts.
