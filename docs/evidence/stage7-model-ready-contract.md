# CFA Stage 7 model-ready dataset and validation-design contract — eligibility PASS / design candidate — 2026-09-02

Status: **STAGE7_ACTIVE / STAGE6_ENTRY_PASS / MODEL_ELIGIBILITY_PASS / MODEL_POPULATION_CANDIDATE / TIME_SPLIT_CANDIDATE / PREPROCESSING_CANDIDATE / BENCHMARK_PLAN_CANDIDATE / MODEL_READY_DATASET_UNVERIFIED / STAGE7_FREEZE_BLOCKED**

## Authority and frozen entry

This contract is subordinate to the CFA Source of Truth and the frozen Stage 6 data-quality/leakage result. Stage 7 may not redefine upstream identities, news matching, responses, factors, timestamps, missingness reasons, or leakage policy.

Frozen inputs:

- Stage 4 response SHA-256: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`;
- Stage 5 factor CSV SHA-256: `c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`;
- Stage 6 validation receipt SHA-256: `5c8fd64d367af847ea1efa25e34cddca05239186282c6d97a4ca70de104a3089`;
- Stage 6 reject CSV SHA-256: `501d085b1edc7d5c7eac425b190e5ee3a503ec66ee2e2876ad3b42c9e56fe07b`;
- Stage 6 descriptive diagnostics SHA-256: `f3c06e7414c80cf07f5d9186961019d737da6a2980b8e18ae0e535b1a978849e`;
- Stage 6 freeze candidate SHA-256: `cce6e7772beb385880390c943e04cc4e987bbaa12b87cdf049d81e9223aa83a2`;
- `CFA-S6-001` through `CFA-S6-009`: **PASS**.

No PLS fitting or hyperparameter selection may begin before Stage 7 is frozen.

## `CFA-S7-001` frozen Stage 6 entry — PASS

The Stage 7 eligibility diagnostic reconciled the exact frozen Stage 6 receipt/source hashes, **37,058 rows / 434 bases / 91 days**, and zero Stage 6 blocking violations.

`CFA-S7-001 = PASS`.

## `CFA-S7-002` model eligibility and time support — PASS

Direct local evidence: `docs/evidence/stage7-model-eligibility-local-20260902.md`.

Observed without fitting or evaluating any model:

- all-seven eligible rows / bases / days: **27,152 / 418 / 68**;
- first / last all-seven eligible response day: **2025-04-03 / 2025-06-14**;
- material availability patterns: **8**;
- chronological one-boundary candidates: **67**.

The diagnostic emitted exact per-pattern, per-day, per-asset, eligible-key, variable-diagnostic, and chronological-boundary artifacts whose hashes must reconcile during design construction.

`CFA-S7-002 = PASS`.

## `CFA-S7-003` model population and matrix — candidate rule

Primary eligibility requires complete numerical availability of all seven frozen predictors on the same frozen Stage 4 response key. Excluded values are upstream structural missingness already validated in Stages 5–6; no imputation, carry, interpolation, synthetic zero, cross-rate, or substitution is permitted.

Response:

- ID: `RET_USD_UTC_DAY_OBS_LOG`;
- column: `response_value_log_return`;
- grain: `(base_asset_id,response_day_utc)`.

Predictor order is exactly:

1. `MKT_RET_USD_UTC_DAY_OBS_L1`;
2. `MKT_RANGE_LOG_UTC_DAY_L1`;
3. `MKT_OBS_COUNT_UTC_DAY_L1`;
4. `MKT_OBS_SPAN_MIN_UTC_DAY_L1`;
5. `NEWS_V6_MATCH_COUNT_24H_LAG15`;
6. `NEWS_V6_MATCH_COUNT_6H_LAG15`;
7. `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

Observed pre-embargo eligibility is **27,152 rows / 418 bases / 68 days**. Exact final modeling rows remain `UNVERIFIED` until split construction.

`CFA-S7-003 = UNVERIFIED`.

## `CFA-S7-004` chronological split and embargo — candidate rule

Random row splitting is prohibited; every row for a response day has one temporal role. Because response day `d` becomes available at `d+1 00:00 UTC`, one eligible response day is embargoed between fitting/tuning segments so the latest response used for fitting/tuning is available strictly before the next evaluated segment's first cutoff.

For the 68 eligible response days sorted ascending:

- indexes 1–40: `TRAIN`;
- index 41: `EMBARGO_TRAIN_VALIDATION`;
- indexes 42–54: `VALIDATION` (13 days);
- index 55: `EMBARGO_VALIDATION_TEST`;
- indexes 56–68: `TEST` (13 days).

Canonical shorthand: **40 TRAIN / 13 validation / 13 test**, plus two one-day embargoes. The 66 non-embargo model/evaluation days therefore approximate a 60/20/20 allocation. Exact calendar boundaries, rows, and bases must be constructed and hash-pinned.

Use rules:

- component/hyperparameter selection: fit `TRAIN`, evaluate `VALIDATION` only;
- `TEST` may not influence design or component choice;
- after validation-only selection, final test model may be refit on `TRAIN + VALIDATION`, excluding both embargo days, then evaluated once on `TEST`.

`CFA-S7-004 = UNVERIFIED`.

## `CFA-S7-005` preprocessing — candidate rule

No imputation, clipping, winsorization, nonlinear transform, or feature selection is permitted.

Predictors:

- validation phase: center by `TRAIN` mean and divide by `TRAIN` **sample standard deviation**;
- test refit: center by `TRAIN + VALIDATION` mean and divide by that population's sample standard deviation;
- non-finite or non-positive fitted SD is a blocking failure;
- fitted parameters are applied unchanged to the corresponding evaluation rows.

Response:

- center only; do not scale;
- validation phase center = `TRAIN` response mean;
- test refit center = `TRAIN + VALIDATION` response mean;
- predictions are returned to original log-return units by adding the fitted mean.

All preprocessing parameters must be materialized and hash-pinned. Validation/test responses may not enter predictor preprocessing statistics.

`CFA-S7-005 = UNVERIFIED`.

## `CFA-S7-006` benchmark and evaluation plan — candidate rule

Benchmarks are fixed before Stage 8 performance is observed:

1. `BENCH_ZERO_RETURN`: prediction `0`; no fit.
2. `BENCH_PRIOR_MARKET_RETURN`: prediction `MKT_RET_USD_UTC_DAY_OBS_L1`; no fit.
3. `BENCH_RESPONSE_MEAN`: validation prediction uses `TRAIN` response mean; test prediction uses `TRAIN + VALIDATION` response mean after validation-only model selection.

Metrics:

- primary: RMSE in original response log-return units;
- secondary: MAE;
- secondary predictive R²: `1 - SSE(model) / SSE(BENCH_RESPONSE_MEAN)` on the same evaluation segment.

If Stage 8 compares PLS component counts, select lowest `VALIDATION` RMSE; exact ties choose the smaller component count. Test metrics are forbidden from component selection.

`CFA-S7-006 = UNVERIFIED`.

## `CFA-S7-007` model-ready artifact — requirements

Construct reproducibly from the exact frozen response/factor artifacts and exact Stage 7 eligibility receipt. Preserve:

- key, predictor cutoff, pair/source-member lineage;
- temporal role `TRAIN`, `VALIDATION`, or `TEST`;
- embargo rows separately with explicit exclusion reason;
- seven predictors in frozen order;
- response ID/value;
- no missing model values;
- exact source/design hashes;
- split assignment, preprocessing parameters, and benchmark-plan identity.

`CFA-S7-007 = BLOCKED` pending construction.

## `CFA-S7-008` independent validation and freeze

Independently verify exact model-ready row/key identity, chronological/embargo ordering, predictor/response order, complete-availability rule, preprocessing statistics/leakage boundaries, benchmark identity, and all hashes.

`CFA-S7-008 = BLOCKED` until an exact candidate exists.

## Current gate table

| ID | Requirement | Status |
|---|---|---|
| `CFA-S7-001` | Reconcile frozen Stage 6 entry | PASS |
| `CFA-S7-002` | Measure model eligibility and chronological support | PASS |
| `CFA-S7-003` | Freeze model population/predictor matrix/response set | UNVERIFIED |
| `CFA-S7-004` | Freeze chronological split and embargo design | UNVERIFIED |
| `CFA-S7-005` | Freeze preprocessing and missing-data policy | UNVERIFIED |
| `CFA-S7-006` | Freeze benchmark plan and evaluation metrics | UNVERIFIED |
| `CFA-S7-007` | Construct exact model-ready artifact | BLOCKED |
| `CFA-S7-008` | Independently validate and freeze Stage 7 | BLOCKED |

## Completion boundary

Stage 7 is complete only when predictor matrix, response vector, retained population, split/embargoes, preprocessing, leakage controls, benchmark plan, and exact model-ready artifact are frozen and independently validated.

**Stage 8 PLS programming remains BLOCKED until `CFA-S7-008 = PASS`.**
