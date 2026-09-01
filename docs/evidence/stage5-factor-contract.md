# CFA Stage 5 candidate-factor contract — market definitions PASS / news availability UNVERIFIED — 2026-09-01

Status: **STAGE5_ACTIVE / FACTOR_SOURCE_RECONCILIATION_PASS / MARKET_FACTOR_DEFINITIONS_PASS / NEWS_SLOT_COVERAGE_PASS / NEWS_HISTORICAL_AVAILABILITY_UNVERIFIED / NEWS_FACTOR_DEFINITIONS_BLOCKED**

## Authority and entry condition

This contract is subordinate to the CFA Source of Truth and authorized CFA evidence. The SoT authorizes definition of candidate market/news factors from verified source data but supplies no factor formula. The reproducible SoT authority snapshot reports no `DATA-###` identifiers in the workbook; therefore no DATA-001/002/003 factor formula is imported or reconstructed.

Stage 4 is frozen on `RET_USD_UTC_DAY_OBS_LOG` with `CFA-S4-015 = PASS`.

`CFA-S5-001 = PASS` — Stage 5 entry gate.

## Frozen predictor/response timing boundary

For response day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00,d+1 00:00:00+00)`;
- response availability: `d+1 00:00:00+00`.

Every predictor must use only information established as available no later than the predictor cutoff. A source timestamp is not automatically an information-availability timestamp. Any unresolved availability assumption is a blocking leakage issue.

## Source-entry reconciliation — PASS

Exact source-entry correction evidence is recorded in:

`docs/evidence/stage5-source-entry-correction-20260901.md`

Directly reconciled facts:

- Stage 4 response/direct-USD bases: **434**;
- Stage 3 news-population assets: **431**;
- intersection: **431**;
- response-only outside Stage 3 news population: **`ZAUD`, `ZEUR`, `ZGBP`**;
- news-only without direct-USD response: **0**;
- frozen V6 retained asset/news rows: **22,060**;
- V6 matched assets: **282**;
- V6 distinct records: **18,503**;
- V6 retained timestamp range: `2025-04-01T00:00:00Z` through `2025-06-14T17:45:00Z`;
- response rows with active direct-USD market observations on the immediately preceding UTC calendar day: **36,505**;
- response rows without such a preceding active market day: **553**.

The historical source-inspection receipt that reported `V6 match rows: 1` remains preserved as a reporting defect caused by collision with PowerShell's automatic `$Matches` variable. The correction validator independently re-read the exact artifacts and restored the correct 22,060-row result.

Therefore:

- `CFA-S5-002 = PASS`;
- `CFA-S5-003 = PASS`;
- `CFA-S5-004 = PASS`;
- `CFA-S5-005 = PASS`.

## Market source

Frozen relation: `asrp.q2_market_1m_observations`.

Stage 5 directly re-verified factor-relevant identity, timestamp, OHLC, lineage, and eligibility fields. OHLC and `base_volume` are PostgreSQL `numeric`; `trade_count` is `bigint`. The inspected direct-USD population had zero null factor fields, zero nonpositive OHLC values, zero negative `base_volume`, zero negative `trade_count`, and retained the frozen market integrity conditions.

Field names alone do not establish economic units. The initial approved factor set therefore excludes `base_volume` and `trade_count` until their economic semantics/units are independently frozen.

## Exact initial market-factor definitions — PASS

### Shared market population, grain, window and missing policy

Population: the **434** frozen Stage 4 direct-USD response bases.

Grain: one candidate factor row per frozen response key `(base_asset_id,response_day_utc)`.

For response day `d`:

`W_MKT(d) = [d-1 00:00:00+00, d 00:00:00+00)`.

Let `E(a,d)` be all frozen-eligible one-minute rows from asset `a`'s unique direct-USD pair in `W_MKT(d)`.

If `E(a,d)` is empty, all four initial market factors are `NULL`. No earlier day, carry-forward, interpolation, cross-rate, or substitute quote is permitted.

If non-empty:

- `F(a,d)` = minimum `candle_start_utc`, tie-break lowest `physical_record_number`;
- `L(a,d)` = maximum `candle_start_utc`, tie-break highest `physical_record_number`.

All source rows lie strictly before the response window. Market factor availability is the predictor cutoff `d 00:00:00+00` after the preceding calendar day has closed.

Stage 5 intrinsic scaling: **none**.

### `MKT_RET_USD_UTC_DAY_OBS_L1`

`ln(L(a,d).close_price / F(a,d).open_price)`

Unit: dimensionless natural-log price ratio.

Semantics: observed first-open to last-close direct-USD return over the preceding UTC calendar day; not claimed to have a fixed 24-hour observed span.

Missing: `NULL` when `E(a,d)` is empty.

### `MKT_RANGE_LOG_UTC_DAY_L1`

`ln(max_{r in E(a,d)} r.high_price / min_{r in E(a,d)} r.low_price)`

Unit: dimensionless natural-log price ratio.

Semantics: observed high/low log range across available preceding-day candles.

Missing: `NULL` when `E(a,d)` is empty.

### `MKT_OBS_COUNT_UTC_DAY_L1`

`|E(a,d)|`

Unit: verified one-minute observation rows.

This is an observation-intensity factor, not trade count or volume.

Missing: `NULL` when `E(a,d)` is empty.

### `MKT_OBS_SPAN_MIN_UTC_DAY_L1`

`(max_{r in E(a,d)} candle_start_utc - min_{r in E(a,d)} candle_start_utc) / 1 minute`

Unit: minutes.

A one-row day has value `0`; an empty day is `NULL`.

### Market decision

The four factors above have source availability on **36,505** frozen response rows and structural market missingness on **553** rows.

`CFA-S5-006 = PASS` — exact initial market-factor definitions.

This PASS approves definitions only; the combined factor artifact is not yet constructed or frozen.

## News source and population boundary

Frozen Stage 3 V6 artifact: exact `stage3-news-matches.csv` / `CANDIDATE_V6`.

Each retained asset/news row carries `base_asset_id`, `record_id`, `gdelt_date_utc`, `source_common_name`, source-document lineage, archive filename/row ordinal, matched aliases/surfaces, and context reasons. Stage 3 guarantees zero duplicate `(base_asset_id,record_id)` retained matches.

Stage 1 freezes the replacement news source to GDELT 2.0 native/base GKG fifteen-minute update archives over:

`[2025-04-01 00:00:00+00, 2025-07-01 00:00:00+00)`

with:

- nominal slots: **8,736**;
- downloaded slots: **7,163**;
- explicit provider-missing HTTP-404 slots: **1,573**;
- unresolved slots: **0**.

The three response assets `ZAUD`, `ZEUR`, and `ZGBP` are outside the frozen 431-asset Stage 3 news population. Their news predictors are structural `NULL`, never zero.

Provider-missing source slots are also structural missingness and may never be converted to zero-news evidence.

## News source-window completeness — PASS

Exact local evidence:

`docs/evidence/stage5-news-window-coverage-20260901.md`

Direct successful diagnostic at executable commit:

`9357392866e0d99719153f83634d4546ad2d0095`

observed:

- source slots: **8,736**;
- downloaded/provider-missing: **7,163 / 1,573**;
- V6 matches mapping to downloaded source slots: **22,060 / 22,060**;
- blank `source_common_name` rows: **0**;
- distinct nonblank `source_common_name` values: **1,601**;
- complete 24-hour response days: **69 / 91**;
- 24-hour available / source-incomplete / outside-population response rows: **27,644 / 9,141 / 273**;
- complete 6-hour response days: **72 / 91**;
- 6-hour available / source-incomplete / outside-population response rows: **28,849 / 7,936 / 273**.

Both response-row accountings equal the frozen **37,058** response rows.

`CFA-S5-010 = PASS` — candidate news-lookback source-slot completeness is measured and reconciled.

## Candidate news-hype formulas — mathematically defined, availability UNVERIFIED

For response day `d`, candidate windows are half-open and exclude the cutoff itself:

- `W_NEWS_24(d) = [d-24h,d)`;
- `W_NEWS_6(d) = [d-6h,d)`.

For asset `a`, let `N(a,W)` be the frozen V6 retained `(a,record_id)` rows whose parsed `gdelt_date_utc` lies in window `W`.

A news factor is numerically eligible only when:

1. `a` is inside the frozen 431-asset Stage 3 news population; and
2. every nominal 15-minute source slot in the exact lookback is present and `downloaded` under the frozen source contract.

If either condition fails, the factor is `NULL` with an explicit missingness reason. If both conditions pass and `N(a,W)` is empty, count `0` is valid.

The following candidate formulas are frozen as **unapproved mathematical candidates** pending the historical availability gate:

### `NEWS_V6_MATCH_COUNT_24H`

`|N(a,W_NEWS_24(d))|`

Unit: retained V6 asset/news records.

Numerical availability from source coverage: **27,644** response rows; **9,141** in-population rows have incomplete source windows; **273** rows are outside news population.

### `NEWS_V6_MATCH_COUNT_6H`

`|N(a,W_NEWS_6(d))|`

Unit: retained V6 asset/news records.

Numerical availability from source coverage: **28,849** response rows; **7,936** in-population rows have incomplete source windows; **273** rows are outside news population.

### `NEWS_V6_SOURCE_COUNT_24H`

Number of distinct **exact stored `source_common_name` strings** among `N(a,W_NEWS_24(d))`.

No case folding, trimming, domain normalization, publisher consolidation, or inferred source identity is performed. The diagnostic observed zero blank `source_common_name` rows among all 22,060 retained V6 matches.

Unit: distinct exact recorded source-common-name strings.

Numerical source-window availability is the same **27,644 / 9,141 / 273** partition as the 24-hour match count.

Stage 5 intrinsic scaling for all news candidates: **none**.

## Historical GDELT information-availability gate — UNVERIFIED

The CFA acquisition schema directly stores:

- nominal `archive_timestamp_utc`;
- object key and URL;
- source status and HTTP status;
- payload/hash/local lineage;
- CFA's later `last_attempt_at_utc` acquisition timestamp.

It does **not** store the provider's historical first-publication/first-availability timestamp for each 2025 archive.

Therefore current authorized evidence does not prove that:

- `archive_timestamp_utc`, or
- a retained row's `gdelt_date_utc`

is exactly the time at which the information became observable to a historical predictor.

No fixed publication delay, one-slot delay, or other latency allowance is assumed without evidence. Source-window completeness and historical information availability are distinct gates.

`CFA-S5-011 = UNVERIFIED` — historical GDELT information-availability semantics.

Because leakage is a blocking failure:

`CFA-S5-007 = BLOCKED` pending `CFA-S5-011`.

The candidate news formulas above must not enter a predictor matrix while `CFA-S5-011` is unresolved.

## Next admissible evidence

The next Stage 5 task is to inspect direct provider-produced metadata capable of establishing a historical archive availability timestamp or a defensible upper bound on publication latency. Evidence may include provider object metadata retained or directly acquired under CFA controls. Archive nominal timestamps or CFA's 2026 download times alone are insufficient.

Any proposed availability rule must be source-supported, exact, reproducible, and fail closed. If direct evidence is insufficient, `CFA-S5-011` remains `UNVERIFIED` and news factors remain blocked.

## Stage 5 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S5-001` | Frozen Stage 4 entry | PASS |
| `CFA-S5-002` | Reconcile response/news populations | PASS |
| `CFA-S5-003` | Verify exact V6 artifact/schema/dedup/timestamps/source boundary | PASS |
| `CFA-S5-004` | Re-inspect market factor fields/types/value boundaries/direct-USD coverage | PASS |
| `CFA-S5-005` | Measure prior-market-day availability | PASS |
| `CFA-S5-006` | Define exact initial market factors | PASS |
| `CFA-S5-010` | Reconcile 24h/6h news lookbacks against exact provider-slot coverage | PASS |
| `CFA-S5-011` | Establish historical GDELT information-availability timestamp/latency rule | UNVERIFIED |
| `CFA-S5-007` | Approve exact initial news-hype factors and missingness policy | BLOCKED |
| `CFA-S5-008` | Construct candidate factor artifact | BLOCKED |
| `CFA-S5-009` | Freeze Stage 5 factor definitions/artifact | BLOCKED |

## Current completion boundary

Stage 5 source entry, market-factor definitions, and news source-window completeness are PASS. News-hype factor approval remains blocked by historical information-availability semantics.

Stage 6 data-quality/leakage testing, Stage 7 model-ready freezing, and PLS remain blocked.
