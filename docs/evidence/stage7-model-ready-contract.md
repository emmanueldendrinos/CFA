# CFA Stage 7 model-ready dataset and validation-design contract — entry defined — 2026-09-02

Status: **STAGE7_ACTIVE / STAGE6_ENTRY_PASS / MODEL_ELIGIBILITY_UNVERIFIED / MODEL_POPULATION_UNVERIFIED / TIME_SPLIT_UNVERIFIED / PREPROCESSING_UNVERIFIED / BENCHMARK_PLAN_UNVERIFIED / MODEL_READY_DATASET_UNVERIFIED / STAGE7_FREEZE_BLOCKED**

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

Stage 7 may proceed only from these exact frozen artifacts. No Stage 7 operation may redefine upstream factors, responses, timestamps, missingness reasons, or leakage policy.

## Stage 7 purpose

Stage 7 must freeze the exact dataset and validation design that Stage 8 PLS will receive. It must explicitly define and validate:

1. the retained row population;
2. the exact predictor matrix and response vector;
3. the chronological training/validation/test design;
4. the preprocessing fitted from training data only;
5. the benchmark plan;
6. the exact model-ready artifact and hashes.

No PLS fitting or hyperparameter selection may begin before Stage 7 is frozen.

## Gate sequence

`CFA-S7-001` — frozen Stage 6 entry reconciliation.

Must verify the exact Stage 6 validation receipt hash and its frozen Stage 4/5 source hashes, PASS status, **37,058 / 434 / 91** cardinalities, and zero blocking violations.

`CFA-S7-002` — model-eligibility and time-support diagnostic.

Before choosing any model population, split, or preprocessing policy, measure from the exact frozen factor/response artifacts:

- row counts for every material predictor-availability pattern;
- exact rows/bases/days with all seven predictors numerically available;
- first/last all-seven-eligible response day;
- per-day response rows, market-available rows, news-24h-available rows, news-6h-available rows, and all-seven-eligible rows;
- per-asset response-day count and all-seven-eligible-day count;
- complete-case variable count/min/max/unique-count and unscaled sample mean/standard deviation for the response plus seven predictors;
- chronological cutoff diagnostics for every possible eligible response-day boundary, including train/test day counts, row counts, and distinct asset counts.

This diagnostic is observational only. It must not choose a cutoff, impute, scale, winsorize, transform, select predictors, use response performance, or fit a model.

`CFA-S7-003` — freeze model population and matrix.

After `CFA-S7-002 = PASS`, explicitly freeze:

- whether the primary matrix requires all seven predictors complete or uses another approved missing-data design;
- exact included/excluded row rule and exclusion reasons;
- exact predictor order;
- response ID and response column;
- model row grain;
- exact retained rows/bases/days.

No imputation or missingness treatment may be introduced without an explicit formula, fitting population, timing rule, and leakage review.

`CFA-S7-004` — freeze chronological validation design.

Must define an outer temporal holdout and any inner validation folds using response-day boundaries only. Random row splitting is prohibited. Every preprocessing statistic and model fit for a fold must use only that fold's training period. Split selection must be based on calendar/coverage/design criteria, never test-response performance.

`CFA-S7-005` — freeze preprocessing.

Must explicitly define, for every predictor and response:

- centering policy;
- scaling policy;
- fitting population;
- zero-variance failure policy;
- treatment of missing values;
- application to validation/test rows;
- storage of fitted preprocessing parameters.

Preprocessing parameters for any validation/test row must be estimated exclusively from earlier training rows.

`CFA-S7-006` — freeze benchmark plan.

Must define comparison models/naive baselines, their predictor subsets, preprocessing, fitting windows, and evaluation metrics before Stage 8 programming. Benchmark choices must not be changed after observing held-out performance without creating a new versioned Stage 7 design.

`CFA-S7-007` — construct model-ready artifact.

Must construct a reproducible, lineage-preserving artifact containing the exact frozen keys, predictor columns, response, split/fold labels, and any approved preprocessing metadata required by Stage 8. Construction must be idempotent and hash-pinned.

`CFA-S7-008` — independent validation and Stage 7 freeze.

Must independently verify the exact model-ready artifact, row/key identity, split ordering, predictor/response order, missingness rule, preprocessing leakage controls, benchmark-design identity, and hashes. Stage 7 freezes only when every required gate is PASS.

## Current gate table

| ID | Requirement | Status |
|---|---|---|
| `CFA-S7-001` | Reconcile frozen Stage 6 entry | PASS |
| `CFA-S7-002` | Measure model eligibility and chronological support | UNVERIFIED |
| `CFA-S7-003` | Freeze model population/predictor matrix/response set | BLOCKED |
| `CFA-S7-004` | Freeze chronological split and validation folds | BLOCKED |
| `CFA-S7-005` | Freeze preprocessing and missing-data policy | BLOCKED |
| `CFA-S7-006` | Freeze benchmark plan and evaluation metrics | BLOCKED |
| `CFA-S7-007` | Construct exact model-ready artifact | BLOCKED |
| `CFA-S7-008` | Independently validate and freeze Stage 7 | BLOCKED |

## Completion boundary

Stage 7 is complete only when the predictor matrix, response vector, retained population, time split, preprocessing, leakage controls, benchmark plan, and exact model-ready artifact are all frozen and independently validated.

**Stage 8 PLS programming remains BLOCKED until `CFA-S7-008 = PASS`.**
