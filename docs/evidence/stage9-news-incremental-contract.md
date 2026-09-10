# CFA Stage 9 news-incremental analysis contract — active — 2026-09-10

Status: **STAGE9_ACTIVE / STAGE8_ENTRY_PASS / NEWS_INCREMENTAL_ANALYSIS_UNVERIFIED / FACTOR_LEVEL_NEWS_DIAGNOSTICS_UNVERIFIED / STAGE9_FREEZE_BLOCKED**

## Authority and purpose

This contract is subordinate to the CFA Source of Truth and the exact frozen Stage 8 result at commit `acf252b8706d01d879ea05865c03b0d1bca4559a`.

Stage 9 answers the research question that Stage 8 did not isolate: **what predictive or descriptive information, if any, is contributed by the three frozen GDELT-derived news-intensity factors relative to the four frozen market factors?**

Stage 9 may not redefine source coverage, asset identity, news matching, response, factor values, availability timestamps, leakage policy, or the frozen Stage 7 model-ready rows.

## Frozen inputs

Use the exact Stage 7 model-ready dataset and Stage 8 freeze lineage:

- model-ready CSV SHA-256: `fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024`;
- Stage 7 independent validation receipt SHA-256: `e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756`;
- Stage 8 independent validation receipt SHA-256: `950503a0400cd42be9c33b78fc9744c11cdf03b5c860c6f37c2abf9253c9ed33`;
- Stage 8 frozen selected model SHA-256: `8aaf69b56756dd45001514e4029065719bec9e1cde425830e2b7e4219f632250`.

Frozen response:

- `RET_USD_UTC_DAY_OBS_LOG` / `response_value_log_return`.

Frozen market predictors, in order:

1. `MKT_RET_USD_UTC_DAY_OBS_L1`;
2. `MKT_RANGE_LOG_UTC_DAY_L1`;
3. `MKT_OBS_COUNT_UTC_DAY_L1`;
4. `MKT_OBS_SPAN_MIN_UTC_DAY_L1`.

Frozen GDELT/news predictors, in order:

1. `NEWS_V6_MATCH_COUNT_24H_LAG15`;
2. `NEWS_V6_MATCH_COUNT_6H_LAG15`;
3. `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

No missing values are introduced or imputed. Stage 9 uses only the exact 26,337 non-embargo Stage 7 model-ready rows unless a diagnostic explicitly restricts to a frozen temporal role.

## Interpretation boundary

Stage 8 already exposed VALIDATION and TEST performance for the full seven-factor model. Therefore **no Stage 9 comparison may describe the original Stage 8 VALIDATION or TEST periods as a fresh confirmatory holdout**.

Stage 9 conclusions are **post-hoc/exploratory but leakage-controlled**. Any future confirmatory claim requires new, previously unseen source/market data and a newly frozen external holdout.

## Primary nested chronological comparison inside original TRAIN

Use only rows whose frozen Stage 7 role is `TRAIN` (40 distinct eligible response days; 15,648 rows).

Sort the 40 distinct TRAIN response days ascending and assign by ordinal:

- days 1–17: `S9_DEV_TRAIN`;
- day 18: `S9_EMBARGO_DEV_SELECTION`;
- days 19–26: `S9_SELECTION_VALIDATION`;
- day 27: `S9_EMBARGO_SELECTION_EVALUATION`;
- days 28–40: `S9_INTERNAL_EVALUATION`.

All rows on a response day inherit that role. Embargo rows are excluded from fitting and evaluation. The one-day embargo rule preserves response availability strictly before the next segment's first predictor cutoff.

This nested split is frozen before any Stage 9 performance result is observed.

## Predeclared model families

Exactly three PLS1 families are compared, using the already validated Stage 8 PLS1/NIPALS algorithm:

### `S9_MARKET_ONLY`

Predictors: the four frozen market factors.
Component grid: 1 through 4.

### `S9_NEWS_ONLY`

Predictors: the three frozen GDELT/news factors.
Component grid: 1 through 3.

### `S9_FULL_7`

Predictors: all four market factors followed by all three news factors.
Component grid: 1 through 7.

For each family:

1. fit centering/scaling and PLS only on `S9_DEV_TRAIN`;
2. select the component count by lowest RMSE on `S9_SELECTION_VALIDATION`; exact ties select the smaller component count;
3. after component count is fixed, refit predictor preprocessing and response centering on `S9_DEV_TRAIN + S9_SELECTION_VALIDATION` only;
4. refit PLS at the selected component count on those same rows;
5. evaluate once on `S9_INTERNAL_EVALUATION`.

Predictors are centered and divided by sample standard deviation fit only on the permitted fit rows. Response is centered only. No imputation, clipping, winsorization, nonlinear transform, randomization, or feature selection is permitted.

Metrics: RMSE, MAE, SSE, and predictive R² versus the corresponding response-mean benchmark.

## Primary news-incremental estimands

On `S9_INTERNAL_EVALUATION`, compute:

- `DELTA_RMSE_FULL_MINUS_MARKET = RMSE(S9_FULL_7) - RMSE(S9_MARKET_ONLY)`;
- `DELTA_MAE_FULL_MINUS_MARKET = MAE(S9_FULL_7) - MAE(S9_MARKET_ONLY)`;
- `INCREMENTAL_R2_NEWS_OVER_MARKET = 1 - SSE(S9_FULL_7) / SSE(S9_MARKET_ONLY)`.

Interpretation:

- negative delta RMSE/MAE or positive incremental R² means adding the three GDELT factors improved that metric relative to market-only;
- positive delta RMSE/MAE or negative incremental R² means adding the GDELT factors worsened that metric;
- these are exploratory/post-hoc estimates, not fresh confirmatory evidence.

Also report `S9_NEWS_ONLY` performance versus the response-mean benchmark to measure stand-alone directional predictive information in the three news factors.

## Secondary original-Stage-8-split comparison

For descriptive replication only, run the same three model families on the original frozen Stage 7 roles:

- fit TRAIN, select components on VALIDATION;
- refit TRAIN+VALIDATION, evaluate TEST once.

Label every such output `POSTHOC_STAGE8_SPLIT`. Because Stage 8 full-model VALIDATION/TEST results were already observed, this surface is explicitly **post-hoc descriptive** and must not be presented as a fresh holdout test.

## Factor-level GDELT diagnostics

For each of the three frozen news factors, report on `S9_INTERNAL_EVALUATION` and separately on original `TEST` as post-hoc descriptive:

1. row count, mean, sample SD, minimum, maximum, and zero share;
2. Pearson correlation with signed `response_value_log_return`;
3. Pearson correlation with `ABS_RESPONSE_DIAGNOSTIC = abs(response_value_log_return)`.

`ABS_RESPONSE_DIAGNOSTIC` is an explicitly post-hoc descriptive diagnostic outcome only. It is not a replacement frozen response and is not used for component selection.

For each news factor, construct intensity groups using cutpoints learned only from the corresponding permitted fit population:

- `ZERO`: factor = 0;
- among positive factor values, calculate the median positive value on fit rows;
- `LOW_POSITIVE`: factor > 0 and <= fitted positive median;
- `HIGH_POSITIVE`: factor > fitted positive median.

For each group on the evaluation segment report n, mean signed response, and mean absolute response. Group cutpoints must never be fitted on the evaluation segment.

These diagnostics describe association only; they do not establish causality.

## Required outputs

The Stage 9 constructor must emit at minimum:

- nested day-role assignment CSV;
- model-family component-selection metrics CSV;
- model-family evaluation metrics CSV;
- model-family evaluation predictions CSV;
- news incremental comparison CSV;
- news factor diagnostics CSV;
- news intensity-group diagnostics CSV;
- post-hoc original Stage 8 split model-family metrics CSV;
- Stage 9 run receipt with exact source/output hashes and gate statuses.

All row-level outputs must preserve `(base_asset_id,response_day_utc)` and deterministic chronological ordering.

## Gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S9-001` | Reconcile exact frozen Stage 8 / Stage 7 entry | PASS |
| `CFA-S9-002` | Construct frozen nested TRAIN-only chronological roles and embargoes | UNVERIFIED |
| `CFA-S9-003` | Run market-only, news-only, and full model-family selection/evaluation | BLOCKED |
| `CFA-S9-004` | Compute primary news incremental estimands | BLOCKED |
| `CFA-S9-005` | Compute factor-level news diagnostics | BLOCKED |
| `CFA-S9-006` | Compute post-hoc original Stage 8 split comparison | BLOCKED |
| `CFA-S9-007` | Independently validate exact Stage 9 outputs | BLOCKED |
| `CFA-S9-008` | Freeze Stage 9 research findings | BLOCKED |

No substantive conclusion about GDELT/news relevance may be frozen before `CFA-S9-007 = PASS`.