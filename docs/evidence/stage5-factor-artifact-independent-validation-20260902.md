# CFA Stage 5 factor artifact independent validation — 2026-09-02

Status: **CFA-S5-008_PASS / CFA-S5-014_PASS / CFA-S5-009_PASS / STAGE5_FROZEN**

## Source

Direct local execution output supplied after running the offline independent Stage 5 factor-artifact validator against the exact candidate receipt and frozen Stage 4 response artifact.

Candidate receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-factor-artifact\20260901-192149-edd4117ac94342de956c28f81a066c86\stage5-candidate-factor-receipt.json`

Independent validation review CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-factor-artifact\20260901-192149-edd4117ac94342de956c28f81a066c86\stage5-factor-artifact-validation-review.csv`

Independent validation receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-factor-artifact\20260901-192149-edd4117ac94342de956c28f81a066c86\stage5-factor-artifact-validation.json`

Frozen candidate factor CSV SHA-256:

`c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`

## Direct observed result

```text
CFA STAGE 5 FACTOR ARTIFACT INDEPENDENT VALIDATION: PASS
Factor rows / bases / days: 37058 / 434 / 91
Market available / missing: 36505 / 553
News24 available / incomplete / outside: 27267 / 9518 / 273
News6 available / incomplete / outside: 28849 / 7936 / 273
Review rows independently validated: 46
CFA-S5-008 factor artifact construction: PASS
CFA-S5-014 independent factor artifact validation: PASS
CFA-S5-009 Stage 5 freeze: UNVERIFIED
Factor CSV SHA-256: c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b
```

The validator deliberately emitted `CFA-S5-009 = UNVERIFIED` because project freeze is a separate contract adjudication after successful independent validation.

## Independent validation scope

The validated artifact contains exactly **37,058** rows at grain `(base_asset_id,response_day_utc)` for **434** bases across **91** response days.

The independent validator checked the exact candidate receipt and its referenced outputs and independently reconciled:

- exact Stage 4 key identity and pair/source lineage;
- all seven approved factor columns;
- deterministic factor ordering;
- market formulas against preserved first/last/high/low witnesses;
- market witness timing inside the prior UTC-day lookback;
- market observation count and span domains;
- market missingness semantics;
- frozen Stage 3 V6 match lineage and hash semantics through the hash-pinned Stage 3 summary;
- frozen 8,736-slot GDELT source registry accounting;
- Stage 3 record-batch timestamps, archive lineage, and downloaded-slot lineage;
- independent recomputation of the 24-hour match count, 6-hour match count, and 24-hour exact-source count under `A_NEWS=B(record_id)+15m`;
- 24-hour and 6-hour source-window completeness and missingness reasons;
- all 91 day-summary rows;
- all **46** review rows against the exact factor artifact.

The validator is offline and does not query PostgreSQL or external network sources.

## Exact frozen factors

1. `MKT_RET_USD_UTC_DAY_OBS_L1`
2. `MKT_RANGE_LOG_UTC_DAY_L1`
3. `MKT_OBS_COUNT_UTC_DAY_L1`
4. `MKT_OBS_SPAN_MIN_UTC_DAY_L1`
5. `NEWS_V6_MATCH_COUNT_24H_LAG15`
6. `NEWS_V6_MATCH_COUNT_6H_LAG15`
7. `NEWS_V6_SOURCE_COUNT_24H_LAG15`

Stage 5 applies no scaling, winsorization, centering, standardization, clipping, imputation, interpolation, carry-forward, cross-rate substitution, or model preprocessing.

## Missingness partitions

- market available / structural missing: **36,505 / 553**;
- news 24h available / source-incomplete / outside-population: **27,267 / 9,518 / 273**;
- news 6h available / source-incomplete / outside-population: **28,849 / 7,936 / 273**.

Each partition reconciles to the frozen **37,058** Stage 4 response keys.

## Gate adjudication

`CFA-S5-008 = PASS` — the seven-factor candidate artifact was constructed at the required frozen Stage 4 grain.

`CFA-S5-014 = PASS` — the exact candidate artifact passed independent offline validation, including hashes, keys, formulas, timing, missingness, source completeness, news recomputation, and review-row reconciliation.

`CFA-S5-009 = PASS` — the Stage 5 factor definitions, timing/missingness rules, and exact factor artifact are frozen on the SHA-256 identified above.

## Completion boundary

**Stage 5 is complete and frozen.**

The required project sequence may now advance to Stage 6 data-quality and leakage testing. Stage 7 model-ready dataset/validation-design freeze and Stage 8 PLS remain blocked until Stage 6 hard gates pass.
