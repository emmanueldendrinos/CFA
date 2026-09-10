# CFA Stage 11 live-scanner source-readiness contract — active — 2026-09-10

Status: **STAGE11_ACTIVE / STAGE10_ENTRY_PASS / LIVE_SOURCE_READINESS_UNVERIFIED / SCANNER_CALIBRATION_BLOCKED / SCANNER_IMPLEMENTATION_BLOCKED**

## Purpose

Stage 11 begins the live-scanner work from frozen Stage 10. It does not reuse pooled Stage 9 averages as scanner coefficients.

The scanner target grain is **`(base_asset_id, scan_timestamp_utc)`**. The scanner is intended to distinguish, at a current timestamp, symbol-relative news attention, broad-market movement, and symbol-specific abnormal movement using only information available by that timestamp.

Before any scanner score or alert threshold is defined, Stage 11 must verify that the exact frozen market and news sources can support a live-time reconstruction at the required grain.

No forward return, future market movement, Stage 10 realized-event label, or later scan may be used to choose the source-readiness rules in this contract.

## Frozen entry

Stage 10 frozen commit: `d3710cdbaaf4ec559065b6e6dd61e22d92cff219`.

Exact Stage 10 independent-validation receipt SHA-256:

`5f65a24eebbe386dfed2ac840ff0cd730b3b8eb0b17b2ff05e34e70a4a050c85`.

Exact Stage 10 run receipt SHA-256:

`5736a74a5d20021b88589e066ad0a98b3ea7efc5d346c3413e2298b7c007bf34`.

Exact Stage 10 symbol-profile SHA-256:

`2d625ed8a79f17cf2a6ac21e22fea62fa3a1a04f9cfa51d9b0ec7ef861e304fd`.

Stage 10 established 418 model-ready base assets. Stage 11 may not silently replace the symbol-specific profile with a pooled estimate.

## Frozen market source

Market relation: `asrp.q2_market_1m_observations`.

Frozen cardinality:

- rows: **14,055,089**;
- distinct data-bearing pair tokens: **1,058**.

AF-001: `candidate-analysis/ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv`, SHA-256 `569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f`.

The direct-USD population contains exactly 434 unique base/pair mappings where `research_eligible=true` and `quote_exchange_symbol='USD'`.

The scanner market source may use only the frozen one-minute row fields directly verified upstream, including:

- `source_member_ordinal`;
- `pair_token_opaque`;
- `physical_record_number`;
- `raw_record_sha256`;
- `candle_start_utc`;
- `open_price`;
- `high_price`;
- `low_price`;
- `close_price`;
- `canonical_eligible`;
- `in_source_window`;
- `minute_aligned`;
- `quality_flags`;
- `duplicate_class`.

`candle_start_utc` must remain `timestamp with time zone`; OHLC fields must remain numeric.

Stage 11 source readiness must re-inspect the live relation and confirm its hashes/cardinality/field semantics through frozen lineage before any scanner calculation.

## Frozen news source

The historical news source is the exact frozen Stage 3 `CANDIDATE_V6` retained-match CSV referenced by the independently validated Stage 5 candidate-factor receipt.

Stage 11 must resolve the following paths from that receipt rather than reconstructing them manually:

- `sources.stage3_matches_path`;
- `sources.batch_timing_receipt_path`;
- `sources.source_slots_path`.

The Stage 5 candidate factor output referenced by that receipt must hash to the frozen factor artifact SHA-256:

`c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`.

The V6 match file must reconcile to:

- **22,060** retained asset/news rows;
- **282** matched assets;
- **18,503** distinct `record_id` values;
- required fields `base_asset_id`, `record_id`, `gdelt_date_utc`, `source_common_name`, `document_identifier`, `archive_file`, `row_ordinal`, `matched_aliases`, `matched_surfaces`, `context_reasons`.

The news-population boundary remains the frozen 431 Stage 3 alias-registry assets. `ZAUD`, `ZEUR`, and `ZGBP` remain outside that population.

## Historical information-availability clock

For retained GDELT record `r`:

`B(r) = UTC timestamp parsed from the first 14 digits of record_id`.

Historical scanner availability remains the frozen conservative policy:

`A_NEWS(r) = B(r) + 15 minutes`.

A historical scan at timestamp `s` may use a record only when:

`A_NEWS(r) < s`.

The strict inequality preserves the frozen boundary rule: a record becoming conservatively available exactly at the scan timestamp does not enter until the next scan.

`gdelt_date_utc` is lineage only and is not the historical availability clock.

## Candidate scan clock for readiness testing

The only candidate scan cadence tested by this source-readiness stage is **15 minutes**, aligned to UTC quarter hours (`minute in {00,15,30,45}`, second = 0).

Reason: the frozen GDELT source is a native 15-minute update source. Stage 11 will not fabricate a finer news-information clock.

This source-readiness test does not yet establish a production alert frequency. It establishes whether a 15-minute historical reconstruction is source-supported.

## Candidate news windows for readiness testing

Stage 11 source readiness measures availability for the already frozen news windows only:

- 6 hours;
- 24 hours.

At scan `s`, the H-hour historical source window is:

`A_NEWS(r) in [s-H, s)`.

Equivalent batch-time interval:

`B(r) in [s-H-15m, s-15m)`.

A numerical news value is source-supported only when every required nominal 15-minute GDELT source slot is present in the frozen source registry with `status='downloaded'`. An incomplete window is **NULL / SOURCE_WINDOW_INCOMPLETE**, never zero.

A complete window with no retained V6 matches is a valid zero.

Stage 11 must enumerate all aligned candidate scan timestamps in the Q2 source interval for which the 6h and 24h windows are inside the source interval, and report complete/incomplete counts and first/last complete timestamps. No return data may enter this calculation.

## Candidate market horizons for readiness testing

Before a live scanner horizon is frozen, Stage 11 tests source feasibility for two candidate trailing windows only:

- **60 minutes**;
- **240 minutes**.

These are readiness probes, not yet approved scanner factors.

For a direct-USD asset and aligned scan timestamp `s`, the probe window is `[s-H,s)`. Stage 11 does not yet calculate scanner scores or forward outcomes. It measures whether the frozen one-minute source contains enough valid observations to construct an observed-window price move and reports the raw support distribution by asset and scan timestamp.

A market row is mechanically valid for the readiness audit only when all frozen row-quality fields are valid:

- `canonical_eligible=true`;
- `in_source_window=true`;
- `minute_aligned=true`;
- `cardinality(quality_flags)=0`;
- `duplicate_class IS NULL`.

For each `(asset,s,H)`, report without filtering by a new arbitrary completeness threshold:

- observation count;
- first `candle_start_utc`;
- last `candle_start_utc`;
- observed span in minutes;
- minutes from window start to first observation;
- minutes from last observation to scan timestamp.

Source readiness summarizes these distributions. A later scanner-calibration contract will freeze any minimum market-support threshold **before** performance is evaluated.

## Market breadth readiness

At each aligned scan and each candidate market horizon, Stage 11 reports how many of the 418 frozen Stage 10 scanner-profile assets have at least one mechanically valid direct-USD market observation in the candidate trailing window.

This is a source-coverage diagnostic only. No market-median formula or minimum breadth threshold is frozen in this source-readiness phase.

## Explicitly forbidden in source readiness

The source-readiness stage must not compute or inspect:

- forward 60m or 240m returns;
- state-conditioned future performance;
- alert precision/recall/hit rate;
- future abnormal returns;
- optimized thresholds or weights;
- scanner ranking scores;
- PLS/model performance;
- any choice made after viewing scanner outcome performance.

## Required outputs

The Stage 11 source-readiness runner must emit at minimum:

- `stage11-source-entry-reconciliation.json`;
- `stage11-news-scan-window-readiness.csv` at scan-timestamp grain;
- `stage11-news-readiness-summary.csv`;
- `stage11-market-readiness-summary.csv` by asset and horizon;
- `stage11-market-breadth-readiness.csv` by scan timestamp and horizon;
- `stage11-source-readiness-run-receipt.json` containing exact input/output hashes, row counts, source paths, database version/session mode, and gate statuses.

The runner may use read-only PostgreSQL queries and local frozen CSV/JSON inputs. It must not mutate the frozen source relation.

## Gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S11-001` | Reconcile exact frozen Stage 10 entry | PASS |
| `CFA-S11-002` | Reconcile exact Stage 5/V6/news-slot local lineage | BLOCKED |
| `CFA-S11-003` | Re-inspect exact 1m market relation/schema/direct-USD mapping | BLOCKED |
| `CFA-S11-004` | Enumerate 15m historical GDELT window completeness | BLOCKED |
| `CFA-S11-005` | Measure 60m/240m market observation support and scan-time breadth | BLOCKED |
| `CFA-S11-006` | Independently validate source-readiness outputs | BLOCKED |
| `CFA-S11-007` | Freeze live scanner calibration contract | BLOCKED |
| `CFA-S11-008` | Program/evaluate scanner | BLOCKED |

No scanner score, alert threshold, forward-outcome evaluation, or production implementation may begin while `CFA-S11-007` remains blocked.