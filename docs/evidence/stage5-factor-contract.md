# CFA Stage 5 candidate-factor contract — definitions PASS / construction PASS / independent validation UNVERIFIED — 2026-09-02

Status: **STAGE5_ACTIVE / FACTOR_SOURCE_RECONCILIATION_PASS / MARKET_FACTOR_DEFINITIONS_PASS / NEWS_FACTOR_DEFINITIONS_PASS / FACTOR_ARTIFACT_CONSTRUCTION_PASS / FACTOR_ARTIFACT_VALIDATION_UNVERIFIED / STAGE5_FREEZE_BLOCKED**

## Authority and entry condition

This contract is subordinate to the CFA Source of Truth and authorized CFA evidence. No factor formula is imported from prior work. Stage 4 is frozen on `RET_USD_UTC_DAY_OBS_LOG` with `CFA-S4-015 = PASS`.

For response day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00,d+1 00:00:00+00)`;
- response availability: `d+1 00:00:00+00`.

Any predictor must use only information established as available before the response window. Leakage is blocking.

## Source-entry reconciliation — PASS

Direct Stage 5 source-entry evidence established:

- Stage 4 response/direct-USD bases: **434**;
- Stage 3 news-population assets: **431**;
- intersection: **431**;
- response-only outside Stage 3 news population: **`ZAUD`, `ZEUR`, `ZGBP`**;
- news-only without direct-USD response: **0**;
- frozen V6 retained asset/news rows: **22,060**;
- V6 matched assets: **282**;
- V6 distinct records: **18,503**;
- response rows with immediately preceding active direct-USD market day: **36,505**;
- response rows without it: **553**.

Therefore:

- `CFA-S5-002 = PASS`;
- `CFA-S5-003 = PASS`;
- `CFA-S5-004 = PASS`;
- `CFA-S5-005 = PASS`.

## Exact initial market-factor definitions — PASS

Population: all **434** frozen Stage 4 direct-USD response bases.

Grain: `(base_asset_id,response_day_utc)`.

For response day `d`, market lookback:

`W_MKT(d) = [d-1 00:00:00+00, d 00:00:00+00)`.

Let `E(a,d)` be frozen-eligible one-minute rows from asset `a`'s unique direct-USD pair in that window. If empty, all market factors are `NULL`; no substitution, imputation, interpolation, carry, or cross-rate is permitted.

If non-empty, `F(a,d)` is the earliest row by `candle_start_utc` with lowest `physical_record_number` tie-break, and `L(a,d)` is the latest row with highest `physical_record_number` tie-break.

Approved definitions:

### `MKT_RET_USD_UTC_DAY_OBS_L1`

`ln(L(a,d).close_price / F(a,d).open_price)`

Unit: dimensionless natural-log price ratio.

### `MKT_RANGE_LOG_UTC_DAY_L1`

`ln(max(high_price in E(a,d)) / min(low_price in E(a,d)))`

Unit: dimensionless natural-log price ratio.

### `MKT_OBS_COUNT_UTC_DAY_L1`

`|E(a,d)|`

Unit: verified one-minute observation rows.

### `MKT_OBS_SPAN_MIN_UTC_DAY_L1`

`(max(candle_start_utc in E(a,d)) - min(candle_start_utc in E(a,d))) / 1 minute`

Unit: minutes; one-row day = `0`.

Stage 5 intrinsic scaling: none.

Observed market availability: **36,505** response rows defined, **553** structurally missing.

`CFA-S5-006 = PASS`.

## News source and population boundary

Frozen source: exact Stage 3 `CANDIDATE_V6` retained-match artifact and Stage 1 GDELT 2.0 native/base GKG source manifest.

Stage 1 source interval:

`[2025-04-01 00:00:00+00, 2025-07-01 00:00:00+00)`.

Source accounting:

- nominal slots: **8,736**;
- downloaded: **7,163**;
- explicit provider-missing HTTP-404: **1,573**;
- unresolved: **0**.

`ZAUD`, `ZEUR`, and `ZGBP` are outside the frozen 431-asset news population. Their news factors are structural `NULL`, never zero. Provider-missing source windows are also structural `NULL`, never zero.

## News source-window completeness methodology — PASS

The first local diagnostic established:

- all **22,060** retained V6 rows mapped to downloaded source slots;
- blank `source_common_name`: **0**;
- distinct nonblank `source_common_name`: **1,601**;
- original unlagged 24h partition: **27,644 available / 9,141 source-incomplete / 273 outside-population**;
- original unlagged 6h partition: **28,849 / 7,936 / 273**.

`CFA-S5-010 = PASS` for exact source-slot accounting and completeness methodology. The unlagged partitions are historical diagnostic results only; the approved factors use the shifted availability rule below.

## Direct first-party GDELT timing evidence

Authority evidence:

`docs/evidence/stage5-gdelt-batch-time-authority-20260901.md`.

Directly inspected first-party GDELT documentation establishes that:

1. `GKGRECORDID` begins with the full date/time of the **15-minute update batch in which the record was created**;
2. GDELT processes monitored worldwide news on a **15-minute** heartbeat;
3. article/publication timing and GDELT processing timing are distinct concepts.

The frozen Stage 3 matcher preserves raw GKG field 0 as `record_id` and raw field 1 as `gdelt_date_utc`.

## Approved conservative GDELT information-availability policy — PASS

For retained record `r`:

`B(r) = UTC timestamp parsed from the first 14 digits of record_id`.

`B(r)` is the source-supported GDELT processing-batch timestamp.

CFA applies a conservative one-heartbeat leakage-control lag:

`A_NEWS(r) = B(r) + 15 minutes`.

This is a CFA predictor-availability policy, not a claim that the downloadable archive became public exactly 15 minutes after `B(r)`. It prevents same-batch information from entering at the batch boundary.

A record may enter a predictor only through `A_NEWS(r)`, never through `gdelt_date_utc`.

Direct offline validation evidence:

`docs/evidence/stage5-gdelt-batch-timing-local-20260901.md`.

The exact local validation observed:

- V6 rows / matched assets / distinct records: **22,060 / 282 / 18,503**;
- record/archive timestamp mismatches: **0**;
- misaligned batch timestamps: **0**;
- batch timestamps not on downloaded source slots: **0**;
- `gdelt_date_utc` equals / differs from batch: **22,060 / 0**;
- `gdelt_date_utc - B(r)` seconds min / max: **0 / 0**.

The observed equality of `gdelt_date_utc` and `B(r)` is lineage evidence only; the approved availability clock remains `B(r)` from the source-defined record identifier plus the explicit 15-minute safety lag.

Therefore:

- `CFA-S5-013 = PASS` — V6 record-batch timestamps, archive lineage, alignment, downloaded-slot lineage, and shifted windows reconcile;
- `CFA-S5-011 = PASS` — historical information-availability policy `A_NEWS=B+15m` is validated for the frozen V6 artifact.

## Exact initial news-hype factor definitions — PASS

For H-hour lookback at predictor cutoff `d`:

`W_NEWS_H(d) = { r : A_NEWS(r) in [d-H,d) }`.

Equivalent batch-time window:

`B(r) in [d-H-15m, d-15m)`.

For asset `a`, only retained Stage 3 V6 `(a,record_id)` rows may contribute. A numerical news value is permitted only when:

1. `a` is in the frozen 431-asset Stage 3 news population; and
2. every nominal 15-minute source slot required by the exact shifted batch-time window is present in the frozen source manifest and has `status='downloaded'`.

If condition 1 fails, the news factors are `NULL` with missingness reason `OUTSIDE_NEWS_POPULATION`.

If condition 2 fails, the news factors are `NULL` with missingness reason `SOURCE_WINDOW_INCOMPLETE`.

If both conditions pass and no retained V6 rows fall inside the relevant window, count `0` is valid.

### `NEWS_V6_MATCH_COUNT_24H_LAG15`

`|{ r : r.base_asset_id=a and A_NEWS(r) in [d-24h,d) }|`.

Unit: retained V6 asset/news records.

Final shifted availability partition: **27,267 available / 9,518 source-incomplete / 273 outside-population** response rows; **68 / 91** response days have a complete 24-hour source window.

### `NEWS_V6_MATCH_COUNT_6H_LAG15`

`|{ r : r.base_asset_id=a and A_NEWS(r) in [d-6h,d) }|`.

Unit: retained V6 asset/news records.

Final shifted availability partition: **28,849 available / 7,936 source-incomplete / 273 outside-population** response rows; **72 / 91** response days have a complete 6-hour source window.

### `NEWS_V6_SOURCE_COUNT_24H_LAG15`

Number of distinct exact stored `source_common_name` strings among retained V6 rows for asset `a` with `A_NEWS(r) in [d-24h,d)`.

No case folding, trimming, domain normalization, publisher consolidation, or inferred source identity is permitted. The frozen V6 artifact contains zero blank `source_common_name` rows.

Unit: distinct exact recorded source-common-name strings.

Availability/missingness partition is the same **27,267 / 9,518 / 273** partition as the 24-hour match-count factor.

Stage 5 intrinsic scaling for all news factors: none.

`CFA-S5-007 = PASS` — exact initial news-hype factor definitions and missingness policy.

## Candidate factor artifact contract and construction — PASS

The Stage 5 candidate artifact must contain exactly one row for every frozen Stage 4 response key: **37,058 rows** at grain `(base_asset_id,response_day_utc)`.

It must contain the seven approved factors:

- `MKT_RET_USD_UTC_DAY_OBS_L1`;
- `MKT_RANGE_LOG_UTC_DAY_L1`;
- `MKT_OBS_COUNT_UTC_DAY_L1`;
- `MKT_OBS_SPAN_MIN_UTC_DAY_L1`;
- `NEWS_V6_MATCH_COUNT_24H_LAG15`;
- `NEWS_V6_MATCH_COUNT_6H_LAG15`;
- `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

For reproducibility and later leakage/data-quality testing it must also preserve, per row:

- `base_asset_id`;
- `response_day_utc`;
- `predictor_cutoff_utc`;
- market missingness reason;
- 24h news missingness reason;
- 6h news missingness reason;
- market lookback start/end;
- news availability-window start/end;
- equivalent news batch-window start/end;
- factor-source lineage sufficient to reproduce the values.

No imputation, scaling, winsorization, clipping, standardization, centering, or model preprocessing is permitted in Stage 5 construction.

Direct construction evidence:

`docs/evidence/stage5-factor-artifact-construction-local-20260901.md`.

The exact local construction reported:

- factor rows: **37,058**;
- distinct bases: **434**;
- market available / missing: **36,505 / 553**;
- news 24h available / source-incomplete / outside-population: **27,267 / 9,518 / 273**;
- news 6h available / source-incomplete / outside-population: **28,849 / 7,936 / 273**;
- review rows: **46**;
- PostgreSQL session: `default_transaction_read_only=on`.

`CFA-S5-008 = PASS` — the exact seven-factor validation candidate was constructed with the required cardinality and expected source/missingness partitions.

`CFA-S5-014 = UNVERIFIED` — independent artifact validation has not yet passed against the exact candidate receipt and referenced outputs.

`CFA-S5-009 = BLOCKED` pending `CFA-S5-014 = PASS` and explicit recording of the exact candidate/output hashes before freeze.

## Superseded provider-metadata exploration

The bucket-list and exact-object GCS metadata attempts are retained as historical implementation lineage only. They are not part of the approved timing path. No further provider-metadata debugging is required.

## Stage 5 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S5-001` | Frozen Stage 4 entry | PASS |
| `CFA-S5-002` | Reconcile response/news populations | PASS |
| `CFA-S5-003` | Verify exact V6 artifact/schema/dedup/source boundary | PASS |
| `CFA-S5-004` | Re-inspect market factor fields/types/direct-USD coverage | PASS |
| `CFA-S5-005` | Measure prior-market-day availability | PASS |
| `CFA-S5-006` | Define exact initial market factors | PASS |
| `CFA-S5-010` | Verify news source-slot accounting/completeness methodology | PASS |
| `CFA-S5-013` | Reconcile V6 record batch timestamps and shifted lag-15 source windows | PASS |
| `CFA-S5-011` | Validate historical GDELT availability policy `A_NEWS=B+15m` | PASS |
| `CFA-S5-007` | Approve exact initial news-hype factors and missingness policy | PASS |
| `CFA-S5-008` | Construct candidate factor artifact | PASS |
| `CFA-S5-014` | Independently validate exact factor artifact/receipt/lineage | UNVERIFIED |
| `CFA-S5-009` | Freeze Stage 5 factor definitions/artifact | BLOCKED |

## Current completion boundary

All Stage 5 factor definitions, source populations, source completeness rules, timing/leakage availability rules, and candidate construction are PASS. The remaining Stage 5 work is independent validation of the exact candidate artifact and then explicit freeze on validated hashes.

Stage 6 data-quality/leakage testing must not begin until `CFA-S5-014 = PASS` and `CFA-S5-009 = PASS`. Stage 7 and PLS remain blocked.
