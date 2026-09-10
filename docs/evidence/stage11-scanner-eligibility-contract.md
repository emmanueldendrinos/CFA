# CFA Stage 11 scanner eligibility/calibration contract — candidate — 2026-09-10

Status: **STAGE11_ACTIVE / SOURCE_READINESS_VALIDATED / SCANNER_ELIGIBILITY_CANDIDATE / CFA-S11-007_BLOCKED / CFA-S11-008_BLOCKED**

## Purpose

This contract converts the independently validated Stage 11 source-readiness evidence into exact source-only eligibility rules for the historical scanner. It does not inspect forward returns, alert hit rates, or scanner profitability.

The scanner grain remains `(base_asset_id, scan_timestamp_utc)` on the 15-minute UTC scan clock.

## Frozen source entry

Stage 10 frozen symbol universe: **418** assets.

Stage 11 V2 source-readiness candidate receipt SHA-256 observed from direct local execution:

`8cc47c32ce258dd60716937dd765d5f10097745d559ddd1bd3fa348b07409217`.

Stage 11 V2R1 independent-validation receipt SHA-256 observed from direct local execution:

`21eb940accc1c50fda15f81ced19bf05bdac59b1d23e00243e9bb77f92d668ad`.

Validated source-readiness counts:

- candidate scans: **8,639**;
- complete 24h GDELT windows: **6,593**;
- complete 6h GDELT windows: **6,953**;
- complete both windows: **6,593**;
- market readiness summaries: **836** rows = 418 assets × 2 horizons;
- market breadth rows: **17,278** = 8,639 scans × 2 horizons;
- breadth timestamps canonical and unique: **true**;
- forward outcomes inspected: **false**.

## Source-only evidence used for threshold choice

The calibration-input summarizer reported, without forward outcomes:

### 60-minute market breadth

- minimum assets with any valid observation: **231**;
- p10: **284**;
- median: **320**;
- p90: **356**;
- maximum: **401**.

### 240-minute market breadth

- minimum: **318**;
- p10: **360**;
- median: **384**;
- p90: **400**;
- maximum: **415**.

Across assets, dense one-minute coverage is not generally available. For 60-minute windows, the across-asset median of the per-asset median observation count is **3**, and only **58 / 418** assets have a per-asset median observation count of at least 15. For 240-minute windows, the corresponding median is **11**, and only **57 / 418** assets have a per-asset median observation count of at least 60.

Therefore the scanner must not require dense one-minute coverage as if every symbol traded continuously. Eligibility is instead based on mathematical minimum observations plus endpoint freshness and minimum observed span.

## Exact current-market eligibility rules

For asset `a`, scan `s`, horizon `H`, define `E_H(a,s)` as all mechanically valid direct-USD one-minute rows in `[s-H,s)` under the frozen quality rule:

- `canonical_eligible=true`;
- `in_source_window=true`;
- `minute_aligned=true`;
- `cardinality(quality_flags)=0`;
- `duplicate_class IS NULL`.

Let:

- `N_H(a,s)=|E_H(a,s)|`;
- `F_H(a,s)` = earliest row by `candle_start_utc`, lowest `physical_record_number` tie-break;
- `L_H(a,s)` = latest row by `candle_start_utc`, highest `physical_record_number` tie-break;
- `START_GAP_H = F_H.candle_start_utc - (s-H)` in minutes;
- `END_GAP_H = s - L_H.candle_start_utc` in minutes;
- `SPAN_H = L_H.candle_start_utc - F_H.candle_start_utc` in minutes.

### 60-minute observed move eligibility

`MARKET60_ELIGIBLE(a,s)` iff all are true:

1. `N_60 >= 2`;
2. `START_GAP_60 <= 15` minutes;
3. `END_GAP_60 <= 15` minutes;
4. `SPAN_60 >= 30` minutes.

If eligible:

`RET60_OBS(a,s) = ln(L_60.close_price / F_60.open_price)`.

Reasoning: two observations are the mathematical minimum for an observed move; one scanner interval at each endpoint is the maximum tolerated staleness; at least half the nominal 60-minute window must be spanned.

### 240-minute observed context eligibility

`MARKET240_ELIGIBLE(a,s)` iff all are true:

1. `N_240 >= 2`;
2. `START_GAP_240 <= 30` minutes;
3. `END_GAP_240 <= 15` minutes;
4. `SPAN_240 >= 180` minutes.

If eligible:

`RET240_OBS(a,s) = ln(L_240.close_price / F_240.open_price)`.

Reasoning: the longer context window tolerates at most two scan intervals at the start, one at the current endpoint, and requires at least 75% of the nominal horizon to be spanned.

No interpolation, carry-forward, synthetic candles, cross-rate substitution, or future price is permitted.

## Market-reference breadth rule

The scanner market reference for a horizon may use only assets meeting that horizon's exact market eligibility rule at the same scan.

The minimum required breadth is not hard-coded from the earlier `any observation` breadth distribution. It is derived from the stricter source-only eligible-return breadth surface as follows:

`MIN_BREADTH_H = nearest-rank p10 of eligible asset count across the 8,639 historical candidate scans for horizon H`.

This p10 rule is frozen before forward outcomes are inspected. The exact integer thresholds remain **UNVERIFIED** until the source-only eligibility runner computes them.

For an eligible asset `a`, the market reference is the leave-one-symbol-out median of contemporaneous eligible observed returns:

`MARKET_MEDIAN_EX_A_H(a,s) = median({RET_H(b,s): b != a and MARKET_H_ELIGIBLE(b,s)})`.

No full-period return statistic may enter this calculation.

## News eligibility

A scan is numerically news-eligible only when both the frozen 24h and 6h source windows are complete under `A_NEWS=B(record_id)+15m`.

Thus:

`NEWS_ELIGIBLE(s) = NEWS24_COMPLETE(s) AND NEWS6_COMPLETE(s)`.

For the validated Q2 source this occurs at **6,593 / 8,639** candidate scans.

An incomplete news window is structural missingness, never zero.

## Past-only per-symbol calibration support

The historical scanner must not use the full-period Stage 10 profile as a predictor.

At scan `s`, prior daily calibration rows for asset `a` may include only frozen model-ready daily rows whose response is already available by `s`. Operationally, because the frozen response for UTC day `d` becomes available at `d+1 00:00Z`, a scan on UTC date `D` may use only response days `< D`.

`HISTORY_SUPPORTED(a,s)` iff the available prior daily rows satisfy all of:

1. at least **20** prior model-ready rows;
2. at least **5** prior rows with `NEWS_V6_MATCH_COUNT_24H_LAG15 = 0`;
3. at least **5** prior rows with `NEWS_V6_MATCH_COUNT_24H_LAG15 > 0`.

This reuses the frozen Stage 10 minimum support concept but applies it strictly as-of-scan. Once true for an asset it remains true as additional prior rows accumulate.

The Stage 10 full-period field `train_test_direction_reversal_indicators=0` is **not** a stability gate: zero can include unresolved TRAIN/TEST support. Full-period Stage 10 profile values remain descriptive context only.

## Technical scanner eligibility

A symbol-scan is technically eligible for the first scanner evaluation only if:

1. `NEWS_ELIGIBLE(s)`;
2. `MARKET60_ELIGIBLE(a,s)`;
3. 60-minute eligible market breadth at `s` is at least the frozen `MIN_BREADTH_60` derived above;
4. `HISTORY_SUPPORTED(a,s)`.

`MARKET240_ELIGIBLE` is retained as context availability and will be reported separately; it is not required for the initial 60-minute event detector unless later frozen before outcomes.

## What remains forbidden before this contract is frozen

The eligibility runner and its independent validator must not compute or inspect:

- forward 60m or 240m return;
- forward abnormal return;
- alert success/failure;
- continuation/reversal labels;
- hit rate, precision, recall, PnL, Sharpe, or profit;
- threshold optimization against outcomes;
- scanner score weights.

## Required source-only eligibility outputs

The eligibility runner must emit at minimum:

- per-scan eligible market breadth for 60m and 240m;
- derived nearest-rank p10 breadth threshold for each horizon;
- per-asset first timestamp/date at which `HISTORY_SUPPORTED` becomes true;
- per-scan count of history-supported assets;
- per-scan count of technically eligible symbol-scans after news, market, breadth, and history gates;
- source/output hashes and a receipt explicitly stating `forward_outcomes_inspected=false`.

Independent validation must recompute the market eligibility boundaries, breadth thresholds, history-support activation, and final eligibility counts through a separate implementation.

## Gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S11-006` | Independently validate corrected source readiness | PASS |
| `CFA-S11-007A` | Define source-only scanner eligibility rules before outcomes | PASS |
| `CFA-S11-007B` | Construct source-only eligibility surface and derive p10 breadth thresholds | BLOCKED |
| `CFA-S11-007C` | Independently validate exact eligibility surface | BLOCKED |
| `CFA-S11-007` | Freeze scanner calibration/eligibility contract | BLOCKED |
| `CFA-S11-008` | Program and evaluate scanner | BLOCKED |

No forward-outcome evaluation may begin until `CFA-S11-007 = PASS`.
