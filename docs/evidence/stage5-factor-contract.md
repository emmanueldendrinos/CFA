# CFA Stage 5 candidate-factor contract — source entry PASS / market definitions approved — 2026-09-01

Status: **STAGE5_ACTIVE / STAGE4_ENTRY_PASS / FACTOR_SOURCE_RECONCILIATION_PASS / MARKET_FACTOR_DEFINITIONS_PASS / NEWS_SLOT_COVERAGE_UNVERIFIED / NEWS_FACTOR_DEFINITIONS_BLOCKED**

## Authority and entry condition

This contract is subordinate to the CFA Source of Truth and authorized CFA evidence. The SoT authorizes definition of candidate market/news factors from verified source data but supplies no factor formula. The reproducible SoT authority snapshot reports that no `DATA-###` identifiers exist in the workbook; therefore no DATA-001/002/003 factor formula is imported or reconstructed.

Stage 4 is frozen on `RET_USD_UTC_DAY_OBS_LOG` with `CFA-S4-015 = PASS`.

`CFA-S5-001 = PASS` — Stage 5 entry gate.

## Frozen predictor/response timing boundary

For response day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00,d+1 00:00:00+00)`;
- response availability: `d+1 00:00:00+00`.

Every Stage 5 predictor must use only information available no later than the predictor cutoff according to its exact source semantics. Any factor whose source window overlaps the response window is a blocking leakage failure.

No Stage 5 factor uses any row from UTC day `d` or later.

## Source-entry reconciliation — PASS

Exact direct local correction evidence is recorded in:

`docs/evidence/stage5-source-entry-correction-20260901.md`

Observed and independently corrected source-entry facts:

- frozen Stage 4 response/direct-USD bases: **434**;
- frozen Stage 3 news-population assets: **431**;
- intersection: **431**;
- response-only outside Stage 3 news population: **3 — `ZAUD`, `ZEUR`, `ZGBP`**;
- news-only without direct-USD response: **0**;
- frozen V6 retained asset/news rows: **22,060**;
- V6 matched assets: **282**;
- V6 distinct records: **18,503**;
- V6 retained-match timestamp range: `2025-04-01T00:00:00Z` through `2025-06-14T17:45:00Z`;
- market field types: OHLC and `base_volume` = PostgreSQL `numeric`; `trade_count` = `bigint`;
- response rows with active direct-USD market observations on the immediately preceding UTC calendar day: **36,505**;
- response rows without such a preceding active market day: **553**.

The historical source-inspection receipt that reported `V6 match rows: 1` remains preserved as a reporting defect caused by collision with PowerShell's automatic `$Matches` variable. The authorized correction validator independently re-read the exact V6 and Stage 4 artifacts and restored the correct 22,060-row observation before these gates were promoted.

Therefore:

- `CFA-S5-002 = PASS`;
- `CFA-S5-003 = PASS`;
- `CFA-S5-004 = PASS`;
- `CFA-S5-005 = PASS`.

## Market source

Frozen relation: `asrp.q2_market_1m_observations`.

Stage 5 directly re-verified these factor-relevant columns and types:

- `source_member_ordinal`;
- `pair_token_opaque`;
- `physical_record_number`;
- `raw_record_sha256`;
- `candle_start_utc` (`timestamp with time zone`);
- `open_price` (`numeric`);
- `high_price` (`numeric`);
- `low_price` (`numeric`);
- `close_price` (`numeric`);
- `base_volume` (`numeric`);
- `trade_count` (`bigint`);
- `canonical_eligible`;
- `in_source_window`;
- `minute_aligned`;
- `quality_flags`;
- `duplicate_class`.

The direct-USD inspected population had zero null factor fields, zero nonpositive OHLC values, zero negative `base_volume`, zero negative `trade_count`, and retained the frozen market integrity conditions.

Field names alone do not establish economic units. Therefore the initial approved market factor set deliberately excludes `base_volume` and `trade_count` until their source semantics/units are independently frozen. Observation-row counts and timestamp spans are used instead because their units are directly defined by the verified relation grain and timestamp field.

## Exact initial market-factor definitions — PASS

### Shared population, grain, window, eligibility, timing and missing policy

Population: the **434** frozen Stage 4 direct-USD response bases.

Factor grain: one candidate factor row per frozen response key `(base_asset_id,response_day_utc)`.

For response day `d`, market lookback window:

`W_MKT(d) = [d-1 00:00:00+00, d 00:00:00+00)`.

This is the immediately preceding UTC calendar day and is fully before the Stage 4 response window.

For asset `a`, let `E(a,d)` be all rows from its unique frozen AF-001 direct-USD pair whose `candle_start_utc` lies in `W_MKT(d)` and satisfies the frozen canonical/source-window/minute-alignment/quality/duplicate eligibility policy.

If `E(a,d)` is empty, **all four initial market factors are missing (`NULL`)** for `(a,d)`. No earlier day is substituted; no carry-forward, carry-backward, interpolation, cross-rate, or stablecoin substitution is permitted.

If non-empty:

- `F(a,d)` is the row with minimum `candle_start_utc`; timestamp ties use lowest `physical_record_number`;
- `L(a,d)` is the row with maximum `candle_start_utc`; timestamp ties use highest `physical_record_number`.

Information availability: the factors become available at predictor cutoff `d 00:00:00+00`, after `W_MKT(d)` has closed. No row with `candle_start_utc >= d 00:00:00+00` may enter any market factor.

Stage 5 intrinsic scaling: **none**. Model-standardization/centering is a later preprocessing decision and must not be embedded here.

### `MKT_RET_USD_UTC_DAY_OBS_L1`

Formula:

`ln(L(a,d).close_price / F(a,d).open_price)`.

Semantics: observed direct-USD log return across the first observed open to the last observed close of the **preceding** UTC calendar day. It is not claimed to be a fixed-duration 24-hour return when the market observations are sparse.

Source fields: `candle_start_utc`, `physical_record_number`, `open_price`, `close_price`, direct-USD identity/eligibility lineage.

Unit: dimensionless natural-log price ratio.

Lookback/lag: immediately preceding UTC calendar day; one calendar-day lag relative to the response day.

Missing policy: `NULL` if `E(a,d)` is empty.

### `MKT_RANGE_LOG_UTC_DAY_L1`

Formula:

`ln(max_{r in E(a,d)} r.high_price / min_{r in E(a,d)} r.low_price)`.

Semantics: observed high/low log range across the available direct-USD candles in the preceding UTC calendar day; not a claim of continuous full-day coverage.

Source fields: `candle_start_utc`, `high_price`, `low_price`, direct-USD identity/eligibility lineage.

Unit: dimensionless natural-log price ratio.

Lookback/lag: immediately preceding UTC calendar day.

Missing policy: `NULL` if `E(a,d)` is empty.

### `MKT_OBS_COUNT_UTC_DAY_L1`

Formula:

`|E(a,d)|`.

Semantics: count of verified direct-USD one-minute observation rows in the preceding UTC calendar day. It is an observation-intensity measure and is **not** relabeled as trade count or volume.

Source fields: row grain, `candle_start_utc`, direct-USD identity/eligibility lineage.

Unit: observation rows (count).

Lookback/lag: immediately preceding UTC calendar day.

Missing policy: `NULL`, not zero, if `E(a,d)` is empty. A zero cannot occur for a non-empty set.

### `MKT_OBS_SPAN_MIN_UTC_DAY_L1`

Formula:

`(max_{r in E(a,d)} candle_start_utc - min_{r in E(a,d)} candle_start_utc) / 1 minute`.

Semantics: elapsed minutes between the first and last observed direct-USD candle starts in the preceding UTC calendar day. A one-row day has value `0`.

Source fields: `candle_start_utc`, direct-USD identity/eligibility lineage.

Unit: minutes.

Lookback/lag: immediately preceding UTC calendar day.

Missing policy: `NULL` if `E(a,d)` is empty.

### Market-definition decision

The source-entry run measured **36,505** frozen response rows with an immediately preceding active market day and **553** without one. Therefore the four factors above have a defined source window on 36,505 rows and structural market missingness on 553 rows before any later model-completeness filter.

`CFA-S5-006 = PASS` — exact initial market-factor definitions.

This PASS approves definitions only; it does not claim the factor artifact has been constructed or validated.

## News source and provider-slot boundary

Frozen Stage 3 V6 output: exact `stage3-news-matches.csv` / `CANDIDATE_V6`.

Frozen retained-match columns include:

- `base_asset_id`;
- `record_id`;
- `gdelt_date_utc`;
- `source_common_name`;
- `document_identifier`;
- `archive_file`;
- `row_ordinal`;
- `matched_aliases`;
- `matched_surfaces`;
- `context_reasons`.

Stage 3 guarantees zero duplicate `(base_asset_id,record_id)` retained matches.

Stage 1 freezes the replacement GDELT source contract to:

- source product: `GDELT 2.0 native/base GKG fifteen-minute update archives`;
- interval: `[2025-04-01 00:00:00+00, 2025-07-01 00:00:00+00)`;
- cadence: **15 minutes**;
- nominal source slots: **8,736**;
- downloaded slots: **7,163**;
- explicit provider-missing HTTP-404 slots: **1,573**;
- unresolved slots: **0**.

Provider-missing slots are missing source observations. They must never be interpreted as evidence that no news occurred.

The observed final downloaded/V6 timestamp of `2025-06-14T17:45:00Z` therefore does not authorize zero-valued news factors for later dates.

The three response assets `ZAUD`, `ZEUR`, and `ZGBP` are outside the frozen 431-asset Stage 3 news-matching population. Their news factors must be structural `NULL`/outside-population, never zero.

## News source-window completeness gate — UNVERIFIED

Before any news-hype factor formula can pass, Stage 5 must reconcile each intended lookback window against the exact 8,736-slot Stage 1 source manifest.

A candidate news window is **complete** only if:

1. every nominal 15-minute source slot in the exact lookback lies inside the frozen Q2 source contract;
2. every such slot is present in `source_news.source_slots` under the exact frozen contract;
3. every such slot has `status='downloaded'`;
4. no slot in the window is provider-missing or unresolved;
5. every retained V6 match timestamp maps to a downloaded source slot;
6. the population distinction between the 431 Stage 3 news assets and the three response-only assets remains explicit.

The diagnostic must measure at least the candidate 24-hour and 6-hour lookbacks, using half-open windows ending at the predictor cutoff and excluding records timestamped exactly at the cutoff.

It must also measure blank/null `source_common_name` values before any distinct-source breadth factor is approved.

`CFA-S5-010 = UNVERIFIED` — news source-slot lookback coverage.

## Candidate news factors — BLOCKED

No news-hype factor is approved yet.

Subject to `CFA-S5-010 = PASS`, the bounded candidates to adjudicate are:

- retained V6 asset/news match count in `[d-24h,d)`;
- retained V6 asset/news match count in `[d-6h,d)`;
- distinct retained `source_common_name` count in `[d-24h,d)` if source-name completeness is directly verified.

For any eventual count factor, zero will be valid **only** when the asset belongs to the frozen 431-asset Stage 3 news population and every nominal source slot in the lookback is downloaded. Outside-population or incomplete-source windows must be `NULL` with an explicit missingness reason.

`CFA-S5-007 = BLOCKED` pending `CFA-S5-010`.

## Stage 5 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S5-001` | Frozen Stage 4 entry (`CFA-S4-015=PASS`) | PASS |
| `CFA-S5-002` | Reconcile 434 response bases with 431 Stage 3 news-population assets | PASS |
| `CFA-S5-003` | Verify exact V6 news-match artifact, schema, deduplication, timestamps, and source boundary | PASS |
| `CFA-S5-004` | Re-inspect market factor fields/types/value boundaries and direct-USD coverage | PASS |
| `CFA-S5-005` | Measure immediately preceding active-market-day availability at frozen predictor cutoffs | PASS |
| `CFA-S5-006` | Define exact initial market factors | PASS |
| `CFA-S5-007` | Define exact initial news-hype factors and outside-population policy | BLOCKED |
| `CFA-S5-008` | Construct candidate factor artifact | BLOCKED |
| `CFA-S5-009` | Freeze Stage 5 candidate-factor definitions/artifact | BLOCKED |
| `CFA-S5-010` | Reconcile candidate news lookbacks against exact provider-slot availability | UNVERIFIED |

## Current completion boundary

Stage 5 source entry and initial market-factor definitions are approved. News-hype definitions remain blocked until exact provider-slot lookback completeness is measured.

Stage 6 data-quality/leakage testing and Stage 7 model-ready freezing remain blocked. PLS remains blocked.
