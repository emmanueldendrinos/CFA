# CFA Stage 8 PLS implementation contract — entry frozen — 2026-09-02

Status: **STAGE8_ACTIVE / STAGE7_ENTRY_PASS / PLS_ALGORITHM_UNVERIFIED / VALIDATION_SWEEP_BLOCKED / COMPONENT_SELECTION_BLOCKED / TEST_EVALUATION_BLOCKED / STAGE8_FREEZE_BLOCKED**

## Authority and frozen entry

This contract is subordinate to the CFA Source of Truth and the frozen Stage 7 model-ready handoff.

Frozen Stage 7 artifacts:

- candidate receipt SHA-256: `9913ae948894c26ebdbf284e25b9268109c9c645eeceb33b1195de690ef04702`;
- model-ready CSV SHA-256: `fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024`;
- split assignment SHA-256: `4a0878a60ba16dfaddc10591931ec4c659efe7c04415338805f660a998625874`;
- embargo exclusions SHA-256: `d938a382a4a8bb654d07d678fcebfe887a32933b0c1c5195104f38e3017c4fdd`;
- preprocessing parameters SHA-256: `8a2a02676236b31d05dbdba6e11f8cd4f4086973448958337e0ee50c52329578`;
- benchmark plan SHA-256: `9b2fd8c9deae62b7c8bf1e04df6ec4d8926844fb8becd995e1efacb927399f9c`;
- independent validation checks SHA-256: `e591ca703ce68dd5b6d92c9dc770da57d042ec1a3462591473ec2737a98a6cef`;
- independent validation receipt SHA-256: `e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756`;
- `CFA-S7-001` through `CFA-S7-008`: **PASS**.

Stage 8 may not change the frozen row population, response, predictor order, split roles, embargoes, preprocessing, benchmarks, metrics, or selection rule.

## Runtime decision

No repository-declared Python/package dependency contract was present at Stage 8 entry. Stage 8 therefore uses a dependency-free Windows PowerShell 5.1 implementation rather than assuming `numpy`, `scikit-learn`, or another external package.

## Frozen matrix and design

Response:

- ID: `RET_USD_UTC_DAY_OBS_LOG`;
- column: `response_value_log_return`;
- response preprocessing: center only.

Predictor order:

1. `MKT_RET_USD_UTC_DAY_OBS_L1`;
2. `MKT_RANGE_LOG_UTC_DAY_L1`;
3. `MKT_OBS_COUNT_UTC_DAY_L1`;
4. `MKT_OBS_SPAN_MIN_UTC_DAY_L1`;
5. `NEWS_V6_MATCH_COUNT_24H_LAG15`;
6. `NEWS_V6_MATCH_COUNT_6H_LAG15`;
7. `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

Frozen rows:

- TRAIN: **15,648**;
- VALIDATION: **5,323**;
- TEST: **5,366**;
- model rows: **26,337**;
- embargo rows excluded from modeling: **815**.

Preprocessing:

- validation phase: predictor centering/scaling from TRAIN only, response centering from TRAIN only;
- test phase: predictor centering/scaling from TRAIN+VALIDATION only, response centering from TRAIN+VALIDATION only;
- predictor scale is sample standard deviation;
- no imputation, clipping, winsorization, nonlinear transform, or feature selection.

## `CFA-S8-001` frozen Stage 7 entry

Must verify the exact independent Stage 7 validation receipt SHA and every frozen Stage 7 output SHA above before any PLS calculation.

## `CFA-S8-002` PLS1/NIPALS numerical algorithm

PLS is univariate-response PLS1 using a NIPALS-style deflation algorithm on the already phase-preprocessed matrix.

For a fit matrix `X` and centered response `y`, initialize residuals `E=X`, `f=y`. For component `h`:

1. `c_h = E' f`;
2. `w_h = c_h / ||c_h||_2`;
3. `t_h = E w_h`;
4. `p_h = E' t_h / (t_h' t_h)`;
5. `q_h = f' t_h / (t_h' t_h)`;
6. `E <- E - t_h p_h'`;
7. `f <- f - t_h q_h`.

After `H` components, with `W=[w_1..w_H]`, `P=[p_1..p_H]`, and `q=[q_1..q_H]'`, regression coefficients in preprocessed predictor space are:

`beta_H = W (P'W)^(-1) q`.

Prediction in original response units is:

`y_hat = response_center + X_preprocessed beta_H`.

Blocking failures:

- non-finite input/output;
- component weight norm or score norm at/below numerical tolerance;
- singular `P'W` solve;
- any mismatch with deterministic self-test fixtures.

Numerical tolerance for singularity/degeneracy checks: `1e-12` in the implementation's double-precision scale.

## `CFA-S8-003` validation component sweep

Candidate component counts are exactly **1 through 7**. Canonical implementation shorthand: **components 1 through 7**.

For each component count:

- use Stage 7 `VALIDATION_FIT` preprocessing;
- fit only TRAIN rows;
- predict only VALIDATION rows;
- report RMSE, MAE, SSE, and predictive R² versus the frozen `BENCH_RESPONSE_MEAN` denominator;
- do not calculate TEST PLS predictions during the sweep.

## `CFA-S8-004` component selection

Machine-readable selection criterion: **`LOWEST_VALIDATION_RMSE`**.

Select the component count with the lowest VALIDATION RMSE. Exact RMSE ties select the smaller component count.

No TEST metric or TEST prediction may influence selection. TEST metrics are forbidden from component selection.

## `CFA-S8-005` final refit and TEST evaluation

Only after the selected component count is fixed:

- use Stage 7 `TEST_REFIT` preprocessing;
- fit selected PLS1 on TRAIN+VALIDATION rows;
- predict TEST rows once;
- report TEST RMSE, MAE, SSE, and predictive R² versus `BENCH_RESPONSE_MEAN`.

The selected component count may not change after TEST evaluation.

## `CFA-S8-006` frozen benchmarks

Evaluate the Stage 7 frozen benchmarks on VALIDATION and TEST:

- `BENCH_ZERO_RETURN`: prediction `0`;
- `BENCH_PRIOR_MARKET_RETURN`: prediction raw `MKT_RET_USD_UTC_DAY_OBS_L1`;
- `BENCH_RESPONSE_MEAN`: phase-specific response-center prediction.

Metrics are RMSE, MAE, SSE, and predictive R² versus `BENCH_RESPONSE_MEAN` on the same segment. Predictive R² of `BENCH_RESPONSE_MEAN` is therefore exactly zero subject to floating-point formatting.

## Required Stage 8 outputs

The executable must emit at minimum:

- validation component sweep CSV (components 1–7 only);
- selected-model JSON with selection rule and selected component count;
- validation selected-model predictions CSV;
- TEST selected-model predictions CSV;
- benchmark metrics CSV for VALIDATION and TEST;
- selected-model coefficients CSV for validation fit and final test refit;
- Stage 8 run receipt with all source/output hashes and gate statuses.

Outputs must preserve key/role lineage and be deterministically ordered by `(response_day_utc,base_asset_id)`.

## Stage 8 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S8-001` | Reconcile exact frozen Stage 7 handoff | UNVERIFIED |
| `CFA-S8-002` | Validate deterministic PLS1/NIPALS implementation | UNVERIFIED |
| `CFA-S8-003` | Run TRAIN→VALIDATION component sweep 1–7 | BLOCKED |
| `CFA-S8-004` | Select components by validation-only frozen rule | BLOCKED |
| `CFA-S8-005` | Refit TRAIN+VALIDATION and evaluate TEST once | BLOCKED |
| `CFA-S8-006` | Evaluate frozen benchmark plan | BLOCKED |
| `CFA-S8-007` | Independently validate exact Stage 8 outputs/hashes | BLOCKED |
| `CFA-S8-008` | Freeze Stage 8 PLS result | BLOCKED |

## Completion boundary

Stage 8 is complete only after the PLS implementation and exact run outputs are independently validated and hash-pinned under `CFA-S8-007 = PASS` and `CFA-S8-008 = PASS`.
