# CFA Stage 9 news-incremental analysis contract — FROZEN — 2026-09-10

Status: **STAGE9_FROZEN / STAGE8_ENTRY_PASS / NEWS_INCREMENTAL_ANALYSIS_PASS / FACTOR_LEVEL_NEWS_DIAGNOSTICS_PASS / INDEPENDENT_VALIDATION_PASS / CFA-S9-008_PASS**

## Authority and purpose

This contract is subordinate to the CFA Source of Truth and the exact frozen Stage 8 result at commit `acf252b8706d01d879ea05865c03b0d1bca4559a`.

Stage 9 answers the research question that Stage 8 did not isolate: **what predictive or descriptive information, if any, is contributed by the three frozen GDELT-derived news-intensity factors relative to the four frozen market factors?**

Stage 9 does not redefine source coverage, asset identity, news matching, response, factor values, availability timestamps, leakage policy, or the frozen Stage 7 model-ready rows.

## Frozen inputs

- model-ready CSV SHA-256: `fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024`;
- Stage 7 independent validation receipt SHA-256: `e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756`;
- Stage 8 independent validation receipt SHA-256: `950503a0400cd42be9c33b78fc9744c11cdf03b5c860c6f37c2abf9253c9ed33`;
- Stage 8 frozen selected model SHA-256: `8aaf69b56756dd45001514e4029065719bec9e1cde425830e2b7e4219f632250`.

Frozen response: `RET_USD_UTC_DAY_OBS_LOG` / `response_value_log_return`.

Market predictors:

1. `MKT_RET_USD_UTC_DAY_OBS_L1`;
2. `MKT_RANGE_LOG_UTC_DAY_L1`;
3. `MKT_OBS_COUNT_UTC_DAY_L1`;
4. `MKT_OBS_SPAN_MIN_UTC_DAY_L1`.

GDELT/news predictors:

1. `NEWS_V6_MATCH_COUNT_24H_LAG15`;
2. `NEWS_V6_MATCH_COUNT_6H_LAG15`;
3. `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

No imputation, clipping, winsorization, nonlinear transform, randomization, or feature selection is permitted.

## Interpretation boundary

Stage 8 had already exposed its VALIDATION and TEST performance before Stage 9 was designed. Stage 9 findings are therefore **POSTHOC / EXPLORATORY / LEAKAGE-CONTROLLED**, not a fresh confirmatory holdout test. A future confirmatory claim requires new, previously unseen source/market data and a newly frozen external holdout.

## Primary nested chronological comparison

Within the original Stage 7 TRAIN population, the 40 eligible response days were frozen before Stage 9 performance was observed as:

- days 1–17: `S9_DEV_TRAIN`;
- day 18: `S9_EMBARGO_DEV_SELECTION`;
- days 19–26: `S9_SELECTION_VALIDATION`;
- day 27: `S9_EMBARGO_SELECTION_EVALUATION`;
- days 28–40: `S9_INTERNAL_EVALUATION`.

Validated rows:

- DEV: **6,475**;
- selection validation: **3,140**;
- internal evaluation: **5,246**;
- embargo: **787**;
- embargo days: **2025-04-20** and **2025-05-01**.

The one-day embargo rule preserves response availability strictly before the next segment's predictor cutoff.

## Predeclared model families

Exactly three PLS1 families use the frozen Stage 8 PLS1/NIPALS algorithm:

- `S9_MARKET_ONLY`: four market factors; components 1–4;
- `S9_NEWS_ONLY`: three GDELT/news factors; components 1–3;
- `S9_FULL_7`: all seven factors; components 1–7.

For each family, preprocessing and PLS are fit only on the permitted fit rows, component count is selected by lowest selection-validation RMSE with smaller-component tie break, then the model is refit on DEV+selection rows and evaluated once on the internal evaluation rows.

Metrics: RMSE, MAE, SSE, and predictive R² versus the corresponding response-mean benchmark.

## Primary independently validated news-incremental result

Selected components, market/news/full: **2 / 1 / 3**.

On `S9_INTERNAL_EVALUATION`:

- `DELTA_RMSE_FULL_MINUS_MARKET = 2.9218036524114588E-06`;
- `INCREMENTAL_R2_NEWS_OVER_MARKET = -7.3767574650718259E-05`;
- `S9_NEWS_ONLY` predictive R² versus response mean = `8.2697538891007838E-05`.

Positive delta RMSE and negative incremental R² mean that adding the three GDELT factors made the market-only model microscopically worse on this primary exploratory surface. The news-only predictive R² is microscopically positive but effectively zero in magnitude.

## Secondary post-hoc original Stage 8 split

Selected components, market/news/full: **2 / 1 / 3**.

On the original Stage 8 TEST surface, explicitly labeled `POSTHOC_STAGE8_SPLIT`:

- `DELTA_RMSE_FULL_MINUS_MARKET = -3.6509444382992751E-07`;
- `INCREMENTAL_R2_NEWS_OVER_MARKET = 1.2391442775427919E-05`;
- `S9_NEWS_ONLY` predictive R² versus response mean = `-3.9589693545449833E-05`.

Here adding news microscopically improves RMSE, while news-only predictive R² is microscopically negative. The direction reverses relative to the primary nested surface, while magnitudes remain extremely close to zero.

## Frozen model-family research finding

The independently validated model-family evidence supports the following narrow conclusion:

> **The three tested GDELT news-intensity proxies — prior-24h matched-record count, prior-6h matched-record count, and prior-24h distinct-source count — show no stable or economically material incremental predictive value for next-day signed log return beyond the four tested market-history factors in this Q2 2025 exploratory design.**

This does **not** establish that GDELT, news content, sentiment, event type, or news generally is irrelevant to crypto markets. It concerns only these three frozen intensity/source-breadth proxies, the tested response horizon, population, and period.

## Factor-level diagnostic design

For each news factor, Stage 9 also reports on the nested internal evaluation and separately on original TEST:

- n, mean, sample SD, min, max, zero share;
- Pearson correlation with signed next-day log return;
- Pearson correlation with absolute next-day log return;
- ZERO / LOW_POSITIVE / HIGH_POSITIVE groups using positive-median cutpoints learned only from the permitted fit population;
- group n, mean signed response, and mean absolute response.

These diagnostics are independently validated and hash-pinned, but specific interpretation of whether aggregate near-zero signed prediction masks offsetting direction effects or absolute-movement association must be based on their exact values, not inferred from the aggregate PLS comparison alone.

## Exact frozen Stage 9 hashes

- run receipt: `f505f5a3210d543aaa71a5bf352cbb8849c8cb2237923aa7dc018f65cfe5abda`;
- nested day roles: `8b4b88debd58579c6c70342e6abf48c935d528d6a59e0abf1f89ba0b26bbd3b1`;
- component metrics: `a7efc10fb25fd92845b3abf9e41dbbe7e353faeff8cb9296e797076e44500607`;
- evaluation metrics: `d28b4688f55c2382655e584d4d29a5121b1547d44d9642c2fd515a7eb6f2a18e`;
- evaluation predictions: `a8d4797cab3fa500ea2d171cfb23f884156fddd2615667b0f8338e11fec3ebee`;
- incremental comparison: `ee42ac6926300e757a88eff6c0e26fc0d12e1bdb6631d91901853d5d7eee4b3e`;
- factor diagnostics: `14dd27caeff16a2b5a75fd2ad5fd49efaa7d6a8a1830499040ee2bd0788dd8c7`;
- intensity groups: `6380fef1863f0fc7580baa608b8bf86a8427074b330b09ca71c66790458cf3f3`;
- post-hoc metrics: `4409fbe93477eaf72fc02433d52181a0110f9a8d367bc5bd4ef8bb392b823f25`;
- independent validation checks: `2fd662d493daee12391a07cd4a969e83734b78cd2be3fa92be013b8587bdf2b7`;
- independent validation receipt: `fee93242132aa46dd11a6f969a49679d51559533a9870255cc928f4a875079bf`.

Repository freeze evidence: `docs/evidence/stage9-news-incremental-independent-validation-freeze-20260910.md`.

## Gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S9-001` | Reconcile exact frozen Stage 8 / Stage 7 entry | PASS |
| `CFA-S9-002` | Construct frozen nested TRAIN-only chronological roles and embargoes | PASS |
| `CFA-S9-003` | Run market-only, news-only, and full model-family selection/evaluation | PASS |
| `CFA-S9-004` | Compute primary news incremental estimands | PASS |
| `CFA-S9-005` | Compute factor-level news diagnostics | PASS |
| `CFA-S9-006` | Compute post-hoc original Stage 8 split comparison | PASS |
| `CFA-S9-007` | Independently validate exact Stage 9 outputs | PASS |
| `CFA-S9-008` | Freeze Stage 9 research findings | PASS |

## Completion boundary

**Stage 9 is frozen for the defined exploratory news-incremental analysis.** Any change to source data, mappings, response, factor formulas, row population, temporal design, PLS algorithm, model families, diagnostic definitions, or pinned artifacts requires a new versioned analysis and independent validation.