# CFA Stage 7 model-ready dataset and validation-design contract — eligibility PASS / design candidate — 2026-09-02

Status: **STAGE7_ACTIVE / STAGE6_ENTRY_PASS / MODEL_ELIGIBILITY_PASS / MODEL_POPULATION_CANDIDATE / TIME_SPLIT_CANDIDATE / PREPROCESSING_CANDIDATE / BENCHMARK_PLAN_CANDIDATE / MODEL_READY_DATASET_UNVERIFIED / STAGE7_FREEZE_BLOCKED**

## Authority and entry condition

This contract is subordinate to the CFA Source of Truth and the frozen Stage 6 data-quality/leakage result.

Frozen Stage 6 evidence:

- Stage 4 response SHA-256: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`;
- Stage 5 factor CSV SHA-256: `c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`;
- Stage 6 validation receipt SHA-256: `5c8fd64d367af847ea1efa25e34cddca05239186282c6d97a4ca70de104a3089`;
- Stage 6 reject CSV SHA-256: `501d085b1edc7d5c7eac425b190e5ee3a503ec66ee2e2876ad3b42c9e56fe07b`;
- Stage 6 descriptive diagnostics SHA-256: `f3c06e7414c80cf07f5d9186961019d737da6a2980b8e18ae0e535b1a978849e`;
- Stage 6 freeze candidate SHA-256: `cce6e7772beb385880390c943e04cc4e987bbaa12b87cdf049d81e9223aa83a2`;
- `CFA-S6-001` through `CFA-S6-009`: **PASS**.

No Stage 7 operation may redefine upstream factors, responses, timestamps, missingness reasons, or leakage policy.

## Stage 7 purpose

Stage 7 must freeze the exact dataset and validation design that Stage 8 PLS will receive: retained row population, predictor matrix and response vector, chronological training/validation/test design, preprocessing, benchmark plan, and exact model-ready artifact. No PLS fitting or hyperparameter selection may begin before Stage 7 is frozen.

## `CFA-S7-001` frozen Stage 6 entry — PASS

The Stage 7 eligibility diagnostic entered from the exact frozen Stage 6 receipt and reconciled **37,058 rows / 434 bases / 91 days** with zero Stage 6 blocking violations and the exact frozen Stage 4/5 source hashes.

`CFA-S7-001 = PASS`.

## `CFA-S7-002` model eligibility and time support — PASS

Direct local evidence:

`docs/evidence/stage7-model-eligibility-local-20260902.md`.

Observed without fitting or evaluating any model:

- frozen rows / bases / days: **37,058 / 434 / 91**;
- all-seven eligible rows / bases / days: **27,152 / 418 / 68**;
- first / last all-seven eligible response day: **2025-04-03 / 2025-06-14**;
- material availability patterns: **8**;
- chronological one-boundary candidates: **67**.

The diagnostic also emitted exact per-pattern, per-day, per-asset, all-seven-key, variable-diagnostic, and chronological-boundary artifacts. Their hashes must be read from the local diagnostic receipt during design construction.

`CFA-S7-002 = PASS`.

## `CFA-S7-003` model population and matrix — candidate rule

Candidate primary modeling eligibility is **complete availability of all seven frozen predictors on the same frozen Stage 4 response key**. This is not statistical complete-case filtering of arbitrary missing values: the excluded values are upstream structural missingness (`NO_PRIOR_ACTIVE_MARKET_DAY`, `SOURCE_WINDOW_INCOMPLETE`, or `OUTSIDE_NEWS_POPULATION`) already validated in Stages 5–6.

Candidate policy:

- no imputation, carry, interpolation, synthetic zero, cross-rate, or other substitution;
- response ID: `RET_USD_UTC_DAY_OBS_LOG`;
- response column: `response_value_log_return`;
- row grain: `(base_asset_id,response_day_utc)`;
- predictor order is exactly:
  1. `MKT_RET_USD_UTC_DAY_OBS_L1`;
  2. `MKT_RANGE_LOG_UTC_DAY_L1`;
  3. `MKT_OBS_COUNT_UTC_DAY_L1`;
  4. `MKT_OBS_SPAN_MIN_UTC_DAY_L1`;
  5. `NEWS_V6_MATCH_COUNT_24H_LAG15`;
  6. `NEWS_V6_MATCH_COUNT_6H_LAG15`;
  7. `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

The observed eligibility surface is **27,152 rows / 418 bases / 68 days** before temporal embargo exclusions. Exact final modeling rows remain `UNVERIFIED` until split assignment is constructed.

`CFA-S7-003 = UNVERIFIED` pending exact design construction and hashes.

## `CFA-S7-004` chronological validation design — candidate rule

Random row splitting is prohibited. All rows from the same response day must have one temporal role.

Because a response for day `d` becomes available at `d+1 00:00 UTC`, a one-eligible-day embargo is inserted between fitting/tuning segments so the latest response used for fitting or tuning is available **strictly before** the next evaluated segment's first predictor cutoff.

For the observed **68** all-seven-eligible response days, sorted ascending:

- eligible-day indexes **1–40**: `TRAIN`;
- eligible-day index **41**: `EMBARGO_TRAIN_VALIDATION`;
- eligible-day indexes **42–54**: `VALIDATION` (**13 days**);
- eligible-day index **55**: `EMBARGO_VALIDATION_TEST`;
- eligible-day indexes **56–68**: `TEST` (**13 days**).

Thus 66 eligible days are model/evaluation days with an approximately 60/20/20 chronological allocation (**40/13/13**) plus two explicit embargo days. Exact calendar boundaries, rows, and distinct bases in each role must be computed from the frozen eligible-key artifact and hash-pinned.

Validation use:

- candidate PLS component/hyperparameter selection may use `TRAIN` fit and `VALIDATION` performance only;
- `TEST` performance is unavailable for any design or hyperparameter choice;
- after a choice is made using validation only, the final test model may be refit on `TRAIN + VALIDATION`, excluding both embargo days, before one test evaluation.

`CFA-S7-004 = UNVERIFIED` pending exact split construction.

## `CFA-S7-005` preprocessing — candidate rule

No imputation, clipping, winsorization, nonlinear transform, or feature selection is permitted in the primary Stage 8 handoff.

For each of the seven predictors:

- validation-phase preprocessing: subtract the `TRAIN` mean and divide by the `TRAIN` **sample standard deviation**;
- final-test refit preprocessing: subtract the `TRAIN + VALIDATION` mean and divide by the `TRAIN + VALIDATION` sample standard deviation;
- a non-finite or non-positive fitted standard deviation is a blocking failure;
- the same fitted parameters are applied unchanged to the corresponding validation/test rows.

For the response:

- center only; do **not** scale;
- validation phase: subtract the `TRAIN` response mean;
- final-test refit phase: subtract the `TRAIN + VALIDATION` response mean;
- predictions are transformed back to original log-return units by adding the corresponding fitted mean.

All preprocessing parameters must be materialized and hash-pinned. Validation/test response values may not enter predictor preprocessing statistics.

`CFA-S7-005 = UNVERIFIED` pending exact parameter construction and validation.

## `CFA-S7-006` benchmark and evaluation plan — candidate rule

Benchmarks are frozen before any Stage 8 performance is observed:

1. `BENCH_ZERO_RETURN`: predict response log-return `0` for every evaluated row; no fit.
2. `BENCH_PRIOR_MARKET_RETURN`: predict `MKT_RET_USD_UTC_DAY_OBS_L1` directly; no fit and no additional preprocessing.
3. `BENCH_RESPONSE_MEAN`: validation prediction is the `TRAIN` response mean; test prediction is the `TRAIN + VALIDATION` response mean after model selection is complete.

Evaluation metrics:

- **primary:** RMSE in original response log-return units;
- **secondary:** MAE in original response units;
- **secondary predictive R²:** `1 - SSE(model) / SSE(BENCH_RESPONSE_MEAN)` for the same evaluation segment.

If Stage 8 compares PLS component counts, the component count is chosen by lowest `VALIDATION` RMSE; exact ties select the smaller component count. Test metrics may not influence this choice.

`CFA-S7-006 = UNVERIFIED` pending construction of a hash-pinned benchmark/design artifact.

## `CFA-S7-007` model-ready artifact — requirements

The model-ready artifact must be constructed reproducibly from the exact frozen response/factor artifacts and the exact Stage 7 eligibility receipt. It must preserve at minimum:

- `base_asset_id`, `response_day_utc`, pair/source-member lineage;
- temporal role (`TRAIN`, `VALIDATION`, `TEST`); embargo rows must be separately preserved as excluded design rows;
- the seven predictors in the exact frozen order;
- `response_value_log_return`;
- no missing model values;
- exact source/design hashes.

It must also emit exact split assignments, excluded embargo keys, preprocessing parameters, and benchmark-plan identity.

`CFA-S7-007 = BLOCKED` pending `CFA-S7-003` through `CFA-S7-006` validation.

## `CFA-S7-008` independent validation and freeze

Must independently verify exact model-ready row/key identity, chronological/embargo ordering, predictor/response order, complete-availability rule, preprocessing statistics and leakage boundaries, benchmark-design identity, and all hashes.

`CFA-S7-008 = BLOCKED` until the exact candidate is constructed.

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

Stage 7 is complete only when predictor matrix, response vector, retained population, chronological split/embargoes, preprocessing, leakage controls, benchmark plan, and exact model-ready artifact are all frozen and independently validated.

**Stage 8 PLS programming remains BLOCKED until `CFA-S7-008 = PASS`.**
