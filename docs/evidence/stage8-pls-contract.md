# CFA Stage 8 PLS implementation contract — frozen — 2026-09-02

Status: **STAGE8_FROZEN / STAGE7_ENTRY_PASS / PLS_ALGORITHM_PASS / VALIDATION_SWEEP_PASS / COMPONENT_SELECTION_PASS / TEST_EVALUATION_PASS / BENCHMARK_EVALUATION_PASS / CFA-S8-007_PASS / CFA-S8-008_PASS**

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

Stage 8 may not change the frozen row population, response, predictor order, split roles, embargoes, preprocessing, benchmarks, metrics, or selection rule without a new versioned Stage 7/8 handoff as applicable.

## Runtime and numerical algorithm

No repository-declared Python/package dependency contract was present at Stage 8 entry. Stage 8 therefore uses a dependency-free Windows PowerShell 5.1-compatible implementation.

PLS is univariate-response PLS1 using a NIPALS-style deflation algorithm on the phase-preprocessed matrix.

For fit matrix `X` and centered response `y`, initialize `E=X`, `f=y`. For component `h`:

1. `c_h = E' f`;
2. `w_h = c_h / ||c_h||_2`;
3. `t_h = E w_h`;
4. `p_h = E' t_h / (t_h' t_h)`;
5. `q_h = f' t_h / (t_h' t_h)`;
6. `E <- E - t_h p_h'`;
7. `f <- f - t_h q_h`.

After `H` components, with `W=[w_1..w_H]`, `P=[p_1..p_H]`, and `q=[q_1..q_H]'`:

`beta_H = W (P'W)^(-1) q`.

Prediction in original response units:

`y_hat = response_center + X_preprocessed beta_H`.

Numerical singularity/degeneracy tolerance: `1e-12`.

Blocking failures include non-finite values, degenerate weight/score norms, singular `P'W`, or failed deterministic numerical fixtures.

`CFA-S8-002 = PASS`.

## Frozen matrix and preprocessing

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

- validation phase predictors: center/scale from TRAIN only;
- validation phase response: center from TRAIN only;
- test phase predictors: center/scale from TRAIN+VALIDATION only;
- test phase response: center from TRAIN+VALIDATION only;
- predictor scale: sample standard deviation;
- no imputation, clipping, winsorization, nonlinear transform, or feature selection.

`CFA-S8-001 = PASS` for exact frozen Stage 7 entry reconciliation.

## Validation component sweep and selection

Candidate component counts are exactly **1 through 7**.

For each component count:

- fit only TRAIN rows using `VALIDATION_FIT` preprocessing;
- predict only VALIDATION rows;
- calculate RMSE, MAE, SSE, and predictive R² versus `BENCH_RESPONSE_MEAN`;
- do not use TEST predictions or TEST metrics during the sweep.

Machine-readable selection criterion: `LOWEST_VALIDATION_RMSE`.

Exact RMSE ties select the smaller component count.

The independently reproduced selected component count is **3**.

Selected VALIDATION metrics:

- RMSE: `0.068614084978703485`;
- MAE: `0.043997861829303833`;
- predictive R² versus response-mean benchmark: `-0.00072357513200893564`.

`TEST used for component selection = False`.

`CFA-S8-003 = PASS` and `CFA-S8-004 = PASS`.

## Final refit and TEST evaluation

Only after the component count was fixed at 3:

- `TEST_REFIT` preprocessing was used;
- PLS1 was fit on TRAIN+VALIDATION rows;
- TEST rows were predicted once;
- the selected component count was not changed after TEST evaluation.

Selected TEST metrics:

- RMSE: `0.058926318333538494`;
- MAE: `0.040292869396394509`;
- predictive R² versus response-mean benchmark: `-0.012773367332183039`.

`CFA-S8-005 = PASS`.

## Frozen benchmarks

The Stage 7 benchmark plan remains unchanged:

- `BENCH_ZERO_RETURN`: prediction `0`;
- `BENCH_PRIOR_MARKET_RETURN`: prediction raw `MKT_RET_USD_UTC_DAY_OBS_L1`;
- `BENCH_RESPONSE_MEAN`: phase-specific response-center prediction.

Metrics are RMSE, MAE, SSE, and predictive R² versus `BENCH_RESPONSE_MEAN` on the same segment.

Independent validation recomputed the benchmark prediction/metric surfaces on VALIDATION and TEST.

`CFA-S8-006 = PASS`.

## Exact frozen Stage 8 artifacts

Direct run/independent-validation evidence:

`docs/evidence/stage8-pls-independent-validation-freeze-20260902.md`

Exact frozen hashes:

- run receipt SHA-256: `ea48186f90f78b50e8ad4874e94601099eef3102bdf222af5ba757c018c041d8`;
- validation component metrics SHA-256: `44cbd19d9e081d5ba7944271bcc0ec7112befadd9df41b02cc866be9d9c77d09`;
- validation selected predictions SHA-256: `3fc83b0760ad534fe9408fc2578ad7b82f76fb4c56fefb95e8f94751abdf2a64`;
- TEST selected predictions SHA-256: `9e6c952ca53e7b9098250a7ff23988edf509e3077166bac4e32bd7eb2d63fd53`;
- benchmark metrics SHA-256: `4362437c7501fcb728ac77afcdb721df1b9ab84fe2159cb03ec4b61e2149dd1c`;
- selected coefficients SHA-256: `538037de7cc16feddb38b136930e2cf09562b2a32f4517d79aa6fbddb45c0d3c`;
- selected model SHA-256: `8aaf69b56756dd45001514e4029065719bec9e1cde425830e2b7e4219f632250`;
- independent validation checks SHA-256: `ae90c737d4a9a60160f5a0f753007397118228618deb00c8812e8d99de1cc6eb`;
- independent validation receipt SHA-256: `950503a0400cd42be9c33b78fc9744c11cdf03b5c860c6f37c2abf9253c9ed33`.

Local run directory:

`C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10`

## Independent validation — PASS

The independent validator used separate numerical/preprocessing implementations and independently recomputed or reconciled:

- frozen Stage 7 hashes and cardinalities;
- phase-specific preprocessing;
- PLS coefficient path for components 1–7;
- all seven VALIDATION metric rows;
- selected component count = 3;
- selected VALIDATION predictions/metrics;
- TRAIN+VALIDATION refit coefficients;
- TEST predictions/metrics;
- all frozen benchmark predictions/metrics;
- selected coefficient rows;
- candidate prediction key/order/value identity;
- every Stage 8 output hash and run-receipt lineage;
- `TEST used for component selection = False`.

Repository CI for the independent validator passed under PowerShell 7 and Windows PowerShell 5.1 and forbids reuse of the production Stage 8 PLS core/data helpers.

`CFA-S8-007 = PASS`.

## Stage 8 freeze — PASS

The exact run and independent-validation hashes are pinned above and in the freeze evidence file. No required Stage 8 gate remains unresolved.

`CFA-S8-008 = PASS`.

## Gate table

| ID | Requirement | Status |
|---|---|---|
| `CFA-S8-001` | Reconcile exact frozen Stage 7 handoff | PASS |
| `CFA-S8-002` | Validate deterministic PLS1/NIPALS implementation | PASS |
| `CFA-S8-003` | Run TRAIN→VALIDATION component sweep 1–7 | PASS |
| `CFA-S8-004` | Select components by validation-only frozen rule | PASS |
| `CFA-S8-005` | Refit TRAIN+VALIDATION and evaluate TEST once | PASS |
| `CFA-S8-006` | Evaluate frozen benchmark plan | PASS |
| `CFA-S8-007` | Independently validate exact Stage 8 outputs/hashes | PASS |
| `CFA-S8-008` | Freeze Stage 8 PLS result | PASS |

## Completion boundary

Stage 8 is complete and frozen. Any change to the frozen Stage 7 handoff, PLS algorithm, component grid, selection rule, preprocessing, benchmark plan, selected component count, predictions, coefficients, metrics, or pinned hashes requires a new versioned run and independent validation.

**The required CFA sequence through PLS programming and validation is complete with no unresolved hard gate.**
