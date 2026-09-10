# CFA Stage 9 news-incremental independent validation and research freeze — 2026-09-10

Status: **INDEPENDENT_NEWS_INCREMENTAL_VALIDATION_PASS / CFA-S9-007_PASS / CFA-S9-008_PASS / STAGE9_FROZEN**

## Scope

This evidence freezes the exact independently validated Stage 9 exploratory/news-incremental analysis constructed from the frozen Stage 7 model-ready dataset and frozen Stage 8 PLS implementation/result lineage. Stage 9 does not redefine the response, market factors, GDELT/news factors, source timing, asset/news mappings, missingness policy, or Stage 7 row population.

Because the original Stage 8 VALIDATION and TEST results had already been observed before Stage 9 was designed, Stage 9 findings are explicitly **POSTHOC / EXPLORATORY / LEAKAGE-CONTROLLED**, not fresh confirmatory holdout evidence.

## Direct independent-validation result

The independent validator reported:

```text
CFA STAGE 9 INDEPENDENT NEWS-INCREMENTAL VALIDATION: PASS
Nested rows dev / selection / eval / embargo: 6475 / 3140 / 5246 / 787
Nested selected components market / news / full: 2 / 1 / 3
Nested delta RMSE full-minus-market: 2.9218036524114588E-06
Nested incremental R2 news-over-market: -7.3767574650718259E-05
Nested news-only predictive R2 vs response mean: 8.2697538891007838E-05
Posthoc selected components market / news / full: 2 / 1 / 3
Posthoc delta RMSE full-minus-market: -3.6509444382992751E-07
Posthoc incremental R2 news-over-market: 1.2391442775427919E-05
Posthoc news-only predictive R2 vs response mean: -3.9589693545449833E-05
Interpretation status: POSTHOC / EXPLORATORY / LEAKAGE-CONTROLLED
CFA-S9-007 independent validation: PASS
CFA-S9-008 research findings freeze: UNVERIFIED
```

The local validator deliberately left `CFA-S9-008` unverified because repository evidence had not yet pinned the independently validated hash set. This file performs that repository adjudication without altering any Stage 9 analytical output.

## Exact independently validated hashes

- Stage 9 run receipt SHA-256: `f505f5a3210d543aaa71a5bf352cbb8849c8cb2237923aa7dc018f65cfe5abda`;
- nested day roles SHA-256: `8b4b88debd58579c6c70342e6abf48c935d528d6a59e0abf1f89ba0b26bbd3b1`;
- component metrics SHA-256: `a7efc10fb25fd92845b3abf9e41dbbe7e353faeff8cb9296e797076e44500607`;
- evaluation metrics SHA-256: `d28b4688f55c2382655e584d4d29a5121b1547d44d9642c2fd515a7eb6f2a18e`;
- evaluation predictions SHA-256: `a8d4797cab3fa500ea2d171cfb23f884156fddd2615667b0f8338e11fec3ebee`;
- incremental comparison SHA-256: `ee42ac6926300e757a88eff6c0e26fc0d12e1bdb6631d91901853d5d7eee4b3e`;
- factor diagnostics SHA-256: `14dd27caeff16a2b5a75fd2ad5fd49efaa7d6a8a1830499040ee2bd0788dd8c7`;
- intensity groups SHA-256: `6380fef1863f0fc7580baa608b8bf86a8427074b330b09ca71c66790458cf3f3`;
- post-hoc metrics SHA-256: `4409fbe93477eaf72fc02433d52181a0110f9a8d367bc5bd4ef8bb392b823f25`;
- independent validation checks SHA-256: `2fd662d493daee12391a07cd4a969e83734b78cd2be3fa92be013b8587bdf2b7`;
- independent validation receipt SHA-256: `fee93242132aa46dd11a6f969a49679d51559533a9870255cc928f4a875079bf`.

## Frozen model-family findings

Primary nested original-TRAIN analysis:

- rows: DEV `6,475`, component-selection validation `3,140`, internal evaluation `5,246`, embargo `787`;
- embargo days: `2025-04-20` and `2025-05-01`;
- selected components market/news/full: `2 / 1 / 3`;
- `DELTA_RMSE_FULL_MINUS_MARKET = 2.9218036524114588E-06`;
- `INCREMENTAL_R2_NEWS_OVER_MARKET = -7.3767574650718259E-05`;
- news-only predictive R² versus response mean = `8.2697538891007838E-05`.

Secondary original Stage 8 split, explicitly post-hoc:

- selected components market/news/full: `2 / 1 / 3`;
- `DELTA_RMSE_FULL_MINUS_MARKET = -3.6509444382992751E-07`;
- `INCREMENTAL_R2_NEWS_OVER_MARKET = 1.2391442775427919E-05`;
- news-only predictive R² versus response mean = `-3.9589693545449833E-05`.

The incremental effects are extremely close to zero and change sign between the two temporal surfaces. The frozen research conclusion from these model-family comparisons is therefore:

> **The three tested GDELT news-intensity proxies — prior-24h matched-record count, prior-6h matched-record count, and prior-24h distinct-source count — show no stable or economically material incremental predictive value for next-day signed log return beyond the four tested market-history factors in this Q2 2025 exploratory design.**

This conclusion is deliberately narrow. It does **not** establish that GDELT, news content, sentiment, event type, or news generally is irrelevant to crypto markets. It concerns only the three frozen intensity/source-breadth proxies, response horizon, population, and period tested here.

## Remaining interpretation boundary

The independently validated factor-diagnostic and intensity-group artifacts may support more specific descriptive statements about whether near-zero signed-return prediction masks associations with absolute movement or offsetting positive/negative responses. Those statements must be based on the exact diagnostic values in the hash-pinned artifacts above; they must not be inferred solely from the aggregate model-family result.

## Gate adjudication

- `CFA-S9-001 = PASS` — frozen Stage 7/8 entry reconciled;
- `CFA-S9-002 = PASS` — nested chronological roles/embargoes validated;
- `CFA-S9-003 = PASS` — market-only, news-only, and full model families independently reproduced;
- `CFA-S9-004 = PASS` — news incremental estimands independently reproduced;
- `CFA-S9-005 = PASS` — factor-level news diagnostic artifacts independently validated;
- `CFA-S9-006 = PASS` — post-hoc original Stage 8 comparison independently reproduced;
- `CFA-S9-007 = PASS` — exact Stage 9 outputs/hashes independently validated;
- `CFA-S9-008 = PASS` — exact validated result hashes and narrow research finding are pinned in repository evidence.

## Freeze boundary

Any change to source data, mappings, response, factor formulas, row population, temporal design, PLS algorithm, model families, diagnostic definitions, or pinned artifacts requires a new versioned analysis and independent validation.

**Stage 9 is frozen for the defined exploratory news-incremental analysis.**