# CFA Stage 6 data-quality and leakage contract — entry defined — 2026-09-02

Status: **STAGE6_ACTIVE / STAGE5_ENTRY_PASS / STRUCTURAL_DQ_UNVERIFIED / MISSINGNESS_DQ_UNVERIFIED / NUMERIC_DQ_UNVERIFIED / LEAKAGE_UNVERIFIED / STAGE6_COMPLETION_BLOCKED**

## Authority and entry condition

This contract is subordinate to the CFA Source of Truth and the frozen Stage 5 factor contract.

Stage 6 may inspect only the exact frozen artifacts and authorized lineage already established upstream. It does not redefine asset identities, news matching, responses, factor formulas, factor windows, or information-availability policy.

Frozen Stage 4 response artifact:

- response ID: `RET_USD_UTC_DAY_OBS_LOG`;
- rows: **37,058**;
- bases: **434**;
- days: **91**;
- SHA-256: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`.

Frozen Stage 5 factor artifact:

- grain: `(base_asset_id,response_day_utc)`;
- rows / bases / days: **37,058 / 434 / 91**;
- factor CSV SHA-256: `c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`;
- factors: exactly the seven identifiers frozen by Stage 5;
- `CFA-S5-008 = PASS`;
- `CFA-S5-014 = PASS`;
- `CFA-S5-009 = PASS`.

Stage 6 begins only from these exact hashes. A hash mismatch is blocking.

## Scope

Stage 6 tests data quality and leakage. It does not choose model preprocessing, training/test splits, benchmarks, or PLS hyperparameters; those are Stage 7/8 concerns.

Hard failures must be based on violated frozen contracts, malformed/non-finite data, invalid timing, duplicate/grain defects, impossible domains, inconsistent missingness, or unreconciled lineage. Descriptive extremeness alone is not a failure without an upstream contract boundary.

## Required structural tests

`CFA-S6-001` — frozen-entry reconciliation.

Must verify:

- Stage 4 response SHA-256;
- Stage 5 validation receipt status and identity;
- frozen Stage 5 factor SHA-256;
- exact 37,058 / 434 / 91 cardinalities;
- exact seven-factor identifier set/order from the frozen Stage 5 contract.

`CFA-S6-002` — grain, schema, encoding, and cardinality.

Must verify:

- one and only one factor row per `(base_asset_id,response_day_utc)`;
- one and only one response row per same key;
- exact key-set equality between factors and responses;
- deterministic factor-row ordering;
- required factor, timing, missingness, and source-lineage columns present;
- no malformed response day or cutoff serialization;
- no malformed booleans/numerics in material columns;
- input CSVs are readable without replacement-character corruption in material fields.

## Missingness tests

`CFA-S6-003` — missingness semantics.

Market factors:

- `market_missing_reason='NONE'` requires all four market factors and required witness fields non-null;
- `market_missing_reason='NO_PRIOR_ACTIVE_MARKET_DAY'` requires all four market factors and market witness/value fields null;
- no other market missingness reason is permitted.

News factors:

- `news_*_missing_reason='NONE'` requires numerical factor values and `news_*_window_complete=True`;
- `SOURCE_WINDOW_INCOMPLETE` requires numerical news values null and completeness false;
- `OUTSIDE_NEWS_POPULATION` requires numerical news values null;
- no other news missingness reason is permitted;
- complete in-population zero-news rows remain valid zero, never null.

Expected frozen partitions:

- market: **36,505 available / 553 missing**;
- news 24h: **27,267 available / 9,518 source-incomplete / 273 outside-population**;
- news 6h: **28,849 available / 7,936 source-incomplete / 273 outside-population**.

## Numeric/domain tests

`CFA-S6-004` — finite values and impossible-domain checks.

For every defined value:

- response is finite;
- `MKT_RET_USD_UTC_DAY_OBS_L1` is finite;
- `MKT_RANGE_LOG_UTC_DAY_L1` is finite and `>= 0`;
- `MKT_OBS_COUNT_UTC_DAY_L1` is an integer `>= 1`;
- `MKT_OBS_SPAN_MIN_UTC_DAY_L1` is an integer in `[0,1439]`;
- `NEWS_V6_MATCH_COUNT_24H_LAG15` is an integer `>= 0`;
- `NEWS_V6_MATCH_COUNT_6H_LAG15` is an integer `>= 0`;
- `NEWS_V6_SOURCE_COUNT_24H_LAG15` is an integer `>= 0` and cannot exceed the 24h match count;
- when both 24h and 6h counts are defined, the 6h count cannot exceed the 24h count.

Stage 6 must emit descriptive min/max/unique-count diagnostics for each response/factor without treating statistical extremeness alone as a hard failure.

## Timing and leakage tests

`CFA-S6-005` — response/cutoff ordering.

For every key:

- predictor cutoff is exactly `response_day_utc 00:00:00Z`;
- Stage 4 response window starts at cutoff and is not used by any predictor;
- response availability is after the response window, consistent with the frozen Stage 4 contract.

`CFA-S6-006` — market leakage.

For every defined market row:

- market window is exactly `[d-1 day,d)`;
- first/last/high/low witness candle timestamps are all `< cutoff` and `>= d-1 day`;
- first timestamp `<=` last timestamp;
- market factor values reconcile with preserved witnesses under the frozen formulas.

For structurally missing market rows, no witness from another active day may be present.

`CFA-S6-007` — news leakage.

For every row:

- `news_availability_lag_minutes = 15`;
- 24h availability window is exactly `[d-24h,d)`;
- 6h availability window is exactly `[d-6h,d)`;
- equivalent batch windows end at `d-15m` and begin exactly 24h/6h earlier;
- no approved news value may use same-batch information at or after cutoff;
- source-incomplete/outside-population rows may not contain numerical news values.

Stage 6 relies on the already-PASS Stage 5 independent recomputation of V6 counts and source completeness; it must still recheck the frozen per-row timing/null invariants from the exact factor CSV.

## Cross-field and failure-path tests

`CFA-S6-008` — cross-field consistency and failure paths.

Must test at minimum:

- pair/source-member lineage agrees between frozen response and factor rows;
- all material SHA-256 witness strings are exactly 64 hexadecimal characters when present;
- physical record numbers are positive integers when present;
- malformed inputs and altered frozen hashes fail closed in executable self-tests;
- duplicate keys, invalid missingness labels, non-finite values, and predictor timestamps at/after cutoff are blocking failures.

## Stage 6 result artifact

The Stage 6 validator must emit a reproducible local receipt containing:

- input paths and SHA-256 hashes;
- row/base/day cardinalities;
- all gate statuses;
- exact missingness partitions;
- exact null/non-null counts by factor;
- finite/domain violation counts;
- timing/leakage violation counts;
- response/factor descriptive min/max/unique-count diagnostics;
- any rejects with key and reason;
- overall `PASS` only when all blocking violation counts are zero.

No PostgreSQL write and no external network access is permitted.

## Stage 6 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S6-001` | Reconcile exact frozen Stage 4/5 entry hashes and cardinalities | UNVERIFIED |
| `CFA-S6-002` | Verify grain/schema/encoding/key cardinality | UNVERIFIED |
| `CFA-S6-003` | Verify missingness semantics and partitions | UNVERIFIED |
| `CFA-S6-004` | Verify finite values and numeric domains; emit descriptive diagnostics | UNVERIFIED |
| `CFA-S6-005` | Verify response/cutoff ordering | UNVERIFIED |
| `CFA-S6-006` | Verify market timing/formulas/no leakage | UNVERIFIED |
| `CFA-S6-007` | Verify news timing/null rules/no leakage | UNVERIFIED |
| `CFA-S6-008` | Verify cross-field lineage and failure paths | UNVERIFIED |
| `CFA-S6-009` | Freeze Stage 6 DQ/leakage validation result | BLOCKED |

## Completion boundary

Stage 6 is complete only when `CFA-S6-001` through `CFA-S6-008` are PASS and the exact validation receipt/reject artifact is frozen under `CFA-S6-009 = PASS`.

Stage 7 model-ready dataset and validation design remain blocked until then. PLS remains blocked until Stage 7 freezes the predictor matrix, response set, time split, preprocessing, leakage controls, and benchmark plan.
