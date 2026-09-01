# CFA Stage 5 candidate-factor contract — market definitions PASS / GDELT batch timing candidate — 2026-09-01

Status: **STAGE5_ACTIVE / FACTOR_SOURCE_RECONCILIATION_PASS / MARKET_FACTOR_DEFINITIONS_PASS / NEWS_SLOT_COVERAGE_PASS / NEWS_HISTORICAL_AVAILABILITY_UNVERIFIED / NEWS_FACTOR_DEFINITIONS_BLOCKED**

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

`[2025-04-01 00:00:00+00, 2025-07-01 00:00:00+00)`

Source accounting:

- nominal slots: **8,736**;
- downloaded: **7,163**;
- explicit provider-missing HTTP-404: **1,573**;
- unresolved: **0**.

`ZAUD`, `ZEUR`, and `ZGBP` are outside the frozen 431-asset news population. Their news factors are structural `NULL`, never zero. Provider-missing source windows are also structural `NULL`, never zero.

## News source-window completeness — PASS

The direct local diagnostic established, using the original unlagged candidate windows:

- all **22,060** retained V6 rows mapped to downloaded source slots;
- blank `source_common_name`: **0**;
- distinct nonblank `source_common_name`: **1,601**;
- original 24h availability partition: **27,644 available / 9,141 source-incomplete / 273 outside-population**;
- original 6h availability partition: **28,849 / 7,936 / 273**.

`CFA-S5-010 = PASS` for source-slot accounting methodology and the original windows.

These counts are **not** frozen as the final news-factor availability counts because the historical timing rule is being corrected below and shifted windows must be remeasured.

## Direct first-party GDELT timing evidence

Evidence record:

`docs/evidence/stage5-gdelt-batch-time-authority-20260901.md`

Directly inspected GDELT documentation establishes:

1. `GKGRECORDID` begins with the full date/time of the **15-minute update batch in which the record was created**.
2. GDELT processes monitored worldwide news on a **15-minute** heartbeat.
3. GDELT separately distinguishes article/publication time from its own monitoring/processing time; for open-web material GDELT treats its retrieval timing as authoritative rather than trusting page-claimed publication time.

The frozen Stage 3 matcher preserves:

- raw GKG field 0 as `record_id`;
- raw GKG field 1 as `gdelt_date_utc`.

Therefore `gdelt_date_utc` must not be used as the historical predictor-availability timestamp merely because it is a date field.

## Conservative GDELT availability policy candidate

For retained record `r`:

`B(r) = UTC timestamp parsed from the first 14 digits of record_id`.

`B(r)` is the GDELT processing-batch timestamp supplied by the GKG record identifier.

Because that timestamp has 15-minute batch resolution, CFA applies a conservative one-heartbeat safety lag:

`A_NEWS(r) = B(r) + 15 minutes`.

This is a CFA leakage-control policy. It is **not** a claim that the downloadable archive became public exactly 15 minutes later. It intentionally prevents any record from being used at the boundary of the same batch in which it was created.

A record is predictor-eligible only through `A_NEWS(r)`, never through `gdelt_date_utc`.

## Revised candidate news windows

For H-hour lookback at predictor cutoff `d`:

`W_NEWS_H(d) = { r : A_NEWS(r) in [d-H,d) }`.

Equivalent batch-time window:

`B(r) in [d-H-15m, d-15m)`.

Candidate IDs are therefore revised to make the safety lag explicit:

- `NEWS_V6_MATCH_COUNT_24H_LAG15`;
- `NEWS_V6_MATCH_COUNT_6H_LAG15`;
- `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

The first two count retained V6 `(base_asset_id,record_id)` rows in the corresponding availability-time window. The third counts distinct exact stored `source_common_name` strings in the 24h window, with no normalization or publisher consolidation.

Zero is valid only when the asset is inside the frozen 431-asset population **and** every nominal source slot required by the shifted batch-time window is downloaded. Otherwise the value is `NULL` with explicit missingness reason.

Stage 5 intrinsic scaling: none.

These are still **unapproved candidate definitions** until the exact V6 artifact and shifted source windows are locally reconciled.

## Required local batch-timing validation

The next validation must use only already-frozen local artifacts. No provider API, cloud metadata, or new acquisition is required.

It must verify all **22,060** retained V6 rows for:

1. valid `record_id` batch prefix;
2. 15-minute alignment;
3. exact equality between parsed batch timestamp and retained `archive_file` timestamp;
4. mapping to a frozen source slot with `status='downloaded'`;
5. exact shifted 24h/6h source-window completeness under `A_NEWS = B + 15m`;
6. exact response-row accounting across complete in-population, incomplete in-population, and outside-population rows;
7. measured `gdelt_date_utc - B(r)` differences for lineage only.

`CFA-S5-013 = UNVERIFIED` — V6 batch-timestamp and shifted-window reconciliation.

`CFA-S5-011 = UNVERIFIED` pending `CFA-S5-013` — the source-supported one-heartbeat availability policy has been defined but not yet validated against every frozen V6 row and source slot.

`CFA-S5-007 = BLOCKED` pending `CFA-S5-011`.

## Superseded provider-metadata exploration

The bucket-list and exact-object GCS metadata attempts are retained as historical implementation lineage only. They are no longer the required path for Stage 5 because the frozen GKG record itself preserves the source-processing batch timestamp needed for a leakage-controlled rule.

No further provider-metadata debugging is required for this gate.

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
| `CFA-S5-013` | Reconcile V6 record batch timestamps and shifted lag-15 source windows | UNVERIFIED |
| `CFA-S5-011` | Validate historical GDELT availability policy `A_NEWS=B+15m` | UNVERIFIED |
| `CFA-S5-007` | Approve exact initial news-hype factors and missingness policy | BLOCKED |
| `CFA-S5-008` | Construct candidate factor artifact | BLOCKED |
| `CFA-S5-009` | Freeze Stage 5 factor definitions/artifact | BLOCKED |

## Current completion boundary

Stage 5 source entry, market-factor definitions, and provider-slot accounting are PASS. The remaining news timing work is one deterministic local reconciliation of the already-frozen V6 `record_id` batch timestamps and shifted windows.

Stage 6, Stage 7, and PLS remain blocked.
