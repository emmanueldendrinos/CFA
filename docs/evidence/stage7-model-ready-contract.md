# CFA Stage 7 model-ready dataset and validation-design contract — frozen — 2026-09-02

Status: **STAGE7_FROZEN / STAGE6_ENTRY_PASS / MODEL_ELIGIBILITY_PASS / MODEL_POPULATION_PASS / TIME_SPLIT_PASS / PREPROCESSING_PASS / BENCHMARK_PLAN_PASS / MODEL_READY_DATASET_PASS / CFA-S7-008_PASS**

## Authority and frozen entry

This contract is subordinate to the CFA Source of Truth and the frozen Stage 6 data-quality/leakage result. Stage 7 may not redefine upstream identities, news matching, responses, factors, timestamps, missingness reasons, or leakage policy.

Frozen upstream inputs:

- Stage 4 response SHA-256: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`;
- Stage 5 factor CSV SHA-256: `c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`;
- Stage 6 validation receipt SHA-256: `5c8fd64d367af847ea1efa25e34cddca05239186282c6d97a4ca70de104a3089`;
- Stage 6 reject CSV SHA-256: `501d085b1edc7d5c7eac425b190e5ee3a503ec66ee2e2876ad3b42c9e56fe07b`;
- Stage 6 descriptive diagnostics SHA-256: `f3c06e7414c80cf07f5d9186961019d737da6a2980b8e18ae0e535b1a978849e`;
- Stage 6 freeze candidate SHA-256: `cce6e7772beb385880390c943e04cc4e987bbaa12b87cdf049d81e9223aa83a2`;
- `CFA-S6-001` through `CFA-S6-009`: **PASS**.

Stage 8 may proceed only from the exact Stage 7 hashes frozen below. Any change to population, matrix, split, preprocessing, benchmark plan, or model-ready artifacts requires a new versioned Stage 7 design and independent revalidation.

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

`CFA-S7-002 = PASS`.

## `CFA-S7-003` model population and matrix — PASS

Direct construction evidence: `docs/evidence/stage7-model-ready-construction-local-20260902.md`.

Primary modeling eligibility requires complete numerical availability of all seven frozen predictors on the same frozen Stage 4 response key. Excluded values are upstream structural missingness already validated in Stages 5–6. No imputation, carry, interpolation, synthetic zero, cross-rate, or substitution is permitted.

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

Observed pre-embargo eligibility is **27,152 rows / 418 bases / 68 days**. The frozen non-embargo model-ready population is **26,337 rows**; the two temporal embargo days account for **815** separately preserved excluded rows.

`CFA-S7-003 = PASS`.

## `CFA-S7-004` chronological split and embargo — PASS

Random row splitting is prohibited; every row for a response day has one temporal role. Because response day `d` becomes available at `d+1 00:00 UTC`, one eligible response day is embargoed between fitting/tuning segments so the latest response used for fitting/tuning is available strictly before the next evaluated segment's first cutoff.

For the 68 eligible response days sorted ascending:

- indexes 1–40: `TRAIN`;
- index 41: `EMBARGO_TRAIN_VALIDATION`;
- indexes 42–54: `VALIDATION`;
- index 55: `EMBARGO_VALIDATION_TEST`;
- indexes 56–68: `TEST`.

Frozen split:

- `TRAIN`: **40 days / 15,648 rows / 410 bases**;
- first embargo: **2025-05-17 / 404 rows**;
- `VALIDATION`: **13 days / 5,323 rows / 414 bases**;
- second embargo: **2025-05-31 / 411 rows**;
- `TEST`: **13 days / 5,366 rows / 418 bases**.

Use rules:

- component/hyperparameter selection: fit `TRAIN`, evaluate `VALIDATION` only;
- `TEST` may not influence design or component choice;
- after validation-only selection, final test model may be refit on `TRAIN + VALIDATION`, excluding both embargo days, then evaluated once on `TEST`.

The independent validator confirmed the exact day-role assignments and response-availability separation across both embargoes.

`CFA-S7-004 = PASS`.

## `CFA-S7-005` preprocessing — PASS

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

Exactly **16** phase/variable preprocessing parameters were independently recomputed from the permitted fit roles and validated.

`CFA-S7-005 = PASS`.

## `CFA-S7-006` benchmark and evaluation plan — PASS

Benchmarks are frozen before any Stage 8 performance is observed:

1. `BENCH_ZERO_RETURN`: prediction `0`; no fit.
2. `BENCH_PRIOR_MARKET_RETURN`: prediction `MKT_RET_USD_UTC_DAY_OBS_L1`; no fit.
3. `BENCH_RESPONSE_MEAN`: validation prediction uses `TRAIN` response mean; test prediction uses `TRAIN + VALIDATION` response mean after validation-only model selection.

Metrics:

- primary: RMSE in original response log-return units;
- secondary: MAE;
- secondary predictive R²: `1 - SSE(model) / SSE(BENCH_RESPONSE_MEAN)` on the same evaluation segment.

If Stage 8 compares PLS component counts, select lowest `VALIDATION` RMSE; exact ties choose the smaller component count. Test metrics are forbidden from component selection.

The independent validator confirmed the exact benchmark-plan identity.

`CFA-S7-006 = PASS`.

## `CFA-S7-007` model-ready artifact — PASS

The exact model-ready artifact preserves:

- key, predictor cutoff, pair/source-member lineage;
- temporal role `TRAIN`, `VALIDATION`, or `TEST`;
- embargo rows separately with explicit exclusion reason;
- seven predictors in the frozen order;
- response ID/value;
- no missing model values;
- split assignment, preprocessing parameters, and benchmark-plan identity.

Frozen accounting:

- eligible rows: **27,152**;
- model rows: **26,337**;
- embargo rows: **815**;
- `26,337 + 815 = 27,152`.

`CFA-S7-007 = PASS`.

## `CFA-S7-008` independent validation and Stage 7 freeze — PASS

Direct independent evidence:

`docs/evidence/stage7-model-ready-independent-validation-freeze-20260902.md`.

The independent validator confirmed:

- exact upstream frozen Stage 4/5 source hashes and Stage 7 candidate lineage;
- complete accounting of all **27,152** eligibility keys across model + embargo outputs;
- exact **26,337** model-row key identity and frozen predictor/response values;
- exact chronological day roles and embargo dates;
- response-availability separation across TRAIN→VALIDATION and VALIDATION→TEST;
- direct recomputation of all **16** preprocessing parameters from allowed fit roles;
- benchmark-plan identity and component-selection rule;
- exact output hashes.

Frozen Stage 7 hashes:

- candidate receipt SHA-256: `9913ae948894c26ebdbf284e25b9268109c9c645eeceb33b1195de690ef04702`;
- model-ready CSV SHA-256: `fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024`;
- split assignment SHA-256: `4a0878a60ba16dfaddc10591931ec4c659efe7c04415338805f660a998625874`;
- embargo exclusions SHA-256: `d938a382a4a8bb654d07d678fcebfe887a32933b0c1c5195104f38e3017c4fdd`;
- preprocessing parameters SHA-256: `8a2a02676236b31d05dbdba6e11f8cd4f4086973448958337e0ee50c52329578`;
- benchmark plan SHA-256: `9b2fd8c9deae62b7c8bf1e04df6ec4d8926844fb8becd995e1efacb927399f9c`;
- independent validation checks SHA-256: `e591ca703ce68dd5b6d92c9dc770da57d042ec1a3462591473ec2737a98a6cef`;
- independent validation receipt SHA-256: `e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756`.

`CFA-S7-008 = PASS`.

## Frozen gate table

| ID | Requirement | Status |
|---|---|---|
| `CFA-S7-001` | Reconcile frozen Stage 6 entry | PASS |
| `CFA-S7-002` | Measure model eligibility and chronological support | PASS |
| `CFA-S7-003` | Freeze model population/predictor matrix/response set | PASS |
| `CFA-S7-004` | Freeze chronological split and embargo design | PASS |
| `CFA-S7-005` | Freeze preprocessing and missing-data policy | PASS |
| `CFA-S7-006` | Freeze benchmark plan and evaluation metrics | PASS |
| `CFA-S7-007` | Construct exact model-ready artifact | PASS |
| `CFA-S7-008` | Independently validate and freeze Stage 7 | PASS |

## Completion boundary

Stage 7 is **FROZEN**. The predictor matrix, response vector, retained population, chronological split and embargoes, preprocessing, leakage controls, benchmark plan, and exact model-ready artifacts are all fixed and independently validated.

Stage 8 PLS programming is now admissible, but only against this exact frozen Stage 7 handoff. No Stage 8 implementation may alter Stage 7 design choices or use TEST results for component selection.
