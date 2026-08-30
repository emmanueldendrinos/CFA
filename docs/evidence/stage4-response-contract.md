# CFA Stage 4 response contract — corrected candidate — 2026-08-30

Status: **STAGE4_RESPONSE_CANDIDATE / SOURCE_SCHEMA_PASS / DIRECT_USD_POPULATION_PASS / EXACT_2359_CANDIDATE_FAILED / DAY_END_DIAGNOSTIC_PASS / LAST_OBSERVED_RULE_FROZEN_FOR_VALIDATION / RESPONSE_FREEZE_BLOCKED**

## Authority and entry condition

This Stage 4 contract is subordinate to the CFA Source of Truth (SoT) and current CFA evidence. It introduces no factor, leakage, model-ready, or PLS decision.

The SoT does not define a response variable and explicitly states that the three handover CSVs contain no response variables. The response definition is therefore derived afresh from the verified CFA market source. Stage 3 is frozen on `CANDIDATE_V6` with `CFA-S3-006 = PASS`.

## Verified market-source boundary inherited from Stage 1

Stage 1 directly verified:

- PostgreSQL relation: `asrp.q2_market_1m_observations`;
- exact rows: **14,055,089**;
- verified interval: `2025-04-01 00:00:00+00` through `2025-06-30 23:59:00+00`;
- distinct data-bearing pair/member population: **1,058**;
- rows outside source window: **0**;
- non-minute-aligned rows: **0**;
- rows with quality flags: **0**;
- rows with duplicate classification: **0**;
- raw-to-typed reconciliation: PASS;
- source archive: `Kraken_OHLCVT_Q2_2025.zip`;
- source archive SHA-256: `36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c`.

AF-001 is `candidate-analysis/ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv`, SHA-256 `569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f`.

## Exact local source inspection — PASS

Read-only source inspection root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-response-source\20260830-191507-b76ab5a1b7e349548ae263a5251aa86a`

Observed and subsequently revalidated by the first constructor before its day-boundary failure:

- PostgreSQL 18.4 with `default_transaction_read_only=on`;
- market relation columns: **19**;
- required market fields include `open_price`, `high_price`, `low_price`, `close_price`, `base_volume`, and `trade_count`;
- research-eligible direct-USD pair rows: **434**;
- distinct direct-USD base assets: **434**;
- duplicate direct-USD base identities: **0**;
- direct-USD pairs with zero market rows: **0**;
- direct-USD market integrity failures: **0**.

One of the 435 research-eligible base assets has no direct-USD pair: `ZUSD`. It has no response under the direct-USD-only response design.

Therefore:

- `CFA-S4-002 = PASS` — exact required market schema/type/integrity entry checks;
- `CFA-S4-003 = PASS` — direct-USD population, uniqueness, and market-row existence.

## Historical exact-23:59 response candidate — FAIL

The first operational response candidate was:

`RET_USD_1D_LOG_2359(a,d) = ln(C_23:59(a,d) / C_23:59(a,d-1))`

with exact `23:59 UTC` one-minute close candles required for both calendar days and no fallback.

Exact local construction root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-responses\20260830-192822-74f6804e90d94fb1bac4990739b9d15f`

The constructor failed closed at:

`Direct-USD pair AEVOUSD has no 23:59 UTC close candle.`

This occurred only after schema, frozen market integrity, direct-USD population, and direct-USD OHLC validity checks passed. The failed assumption was universal exact-`23:59` availability, not source integrity.

Historical statuses are preserved:

- `CFA-S4-004 = FAIL` — exact-23:59 response boundary unsupported for the full direct-USD population;
- `CFA-S4-005 = FAIL` — exact-23:59 response construction failed;
- `CFA-S4-006 = BLOCKED` — that candidate cannot freeze Stage 4.

## Exact day-end diagnostic — PASS

Authorized read-only diagnostic:

`scripts/windows/Diagnose-CfaStage4DayEndCoverage.ps1`

Exact local diagnostic root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-day-end-diagnostic\20260830-193709-3c9fb15b85db4dec94e8306e79f54b9e`

Direct observations across the 434 direct-USD pairs:

- pairs with no exact `23:59` observation ever: **46**;
- active USD pair-days: **37,058**;
- active pair-days with exact `23:59`: **5,134**;
- active pair-days without exact `23:59`: **31,924**;
- maximum last-observed-candle lag before midnight: **1,436 minutes**;
- invalid last-close pair-days: **0**;
- consecutive-calendar-day candidates using each active day's last observed close: **36,505**;
- consecutive-calendar-day candidates requiring exact `23:59` on both days: **2,309**.

`CFA-S4-007 = PASS`.

These observations show that an exact or arbitrarily near-midnight candle requirement would discard most otherwise valid active pair-days. Current evidence does not justify inventing a fixed staleness threshold. The corrected response therefore uses the actual last observed eligible market close within each active UTC day and does not interpret that value as an imputed midnight price.

## Corrected response rule — frozen for validation

Response ID: **`RET_USD_1D_LOG_LAST_OBS`**.

### Population

Only the 434 research-eligible Kraken pairs whose AF-001 `quote_exchange_symbol` is exactly `USD` are eligible.

No `USDT`, `USDC`, EUR, GBP, BTC/XBT, ETH, other quote, or cross-rate conversion is permitted.

### Grain

One response observation per:

`(base_asset_id, response_day_utc)`

where `response_day_utc = d` is a UTC calendar date.

### Daily close definition

For base asset `a` and UTC day `d`, define `L(a,d)` as `close_price` from the valid direct-USD market row with the maximum `candle_start_utc` inside:

`[d 00:00:00+00, d+1 00:00:00+00)`.

The selected row must remain canonical-eligible, in-source-window, minute-aligned, quality-flag-free, duplicate-class-free, finite, non-NULL, and strictly positive.

If the asset has no valid direct-USD observation during day `d`, `L(a,d)` is missing. No price from another day is carried into `d`.

The daily close may occur substantially before midnight. Its exact timestamp and minutes-before-midnight must be retained in lineage. It is an observed last close for that active UTC day, **not** a synthetic midnight close.

### Response formula

A response exists only when both `L(a,d-1)` and `L(a,d)` exist on consecutive UTC calendar days:

`RET_USD_1D_LOG_LAST_OBS(a,d) = ln(L(a,d) / L(a,d-1))`.

The earliest possible response day is `2025-04-02` because the verified source begins on `2025-04-01`.

No response bridges an inactive/missing UTC day.

### Predictor cutoff and response availability

For response day `d`:

- predictor cutoff: `d 00:00:00+00`;
- prior daily close `L(a,d-1)` is finalized by that cutoff because the prior UTC day has ended;
- response-label day: UTC day `d`;
- current daily close `L(a,d)` is finalized only after UTC day `d` ends;
- response availability time: `d+1 00:00:00+00`.

Even when the last observed candle occurs before midnight, the identity of that row as the day's final observed candle is not final until the UTC day closes. The response is therefore treated as unavailable before `d+1 00:00:00+00`.

### Unit and preprocessing

- unit: dimensionless natural-log return;
- Stage 4 scaling/standardization: none.

Any later centering/scaling belongs to the model-ready preprocessing design and must not alter the frozen raw response definition.

### Missing-data policy

**No imputation is permitted.**

Exclude a response when either consecutive calendar day has no valid direct-USD observation, when either selected last close is invalid, or when any source/identity/lineage condition fails.

No carry-forward, carry-backward, interpolation, stablecoin substitution, quote substitution, or cross-rate conversion is permitted.

### Required lineage per response row

The corrected response artifact must retain at minimum:

- response ID;
- `base_asset_id`;
- direct-USD `pair_token_opaque` and `source_member_ordinal`;
- `response_day_utc`;
- predictor cutoff UTC;
- response availability UTC;
- prior and current daily-close UTC timestamps;
- prior and current minutes-before-midnight;
- prior and current `close_price`;
- prior and current `physical_record_number`;
- prior and current `raw_record_sha256`;
- natural-log return value.

## Corrected constructor hard requirements

The corrected constructor must fail closed unless all of the following reconcile:

1. exact AF-001 SHA-256 and 434-pair / 434-base USD population;
2. exact market schema and frozen Stage 1 market cardinality/integrity;
3. zero invalid direct-USD OHLC observations;
4. exactly **37,058** valid active USD pair-days under the daily-last-row rule;
5. exactly **36,505** consecutive-calendar-day response candidates;
6. zero duplicate `(base_asset_id,response_day_utc)` keys;
7. no response crossing a missing UTC day;
8. every response independently recomputes as `ln(current_last_close/prior_last_close)` within `1e-12`;
9. every prior/current row is the maximum `candle_start_utc` observed for its exact pair/calendar day;
10. response availability is exactly the UTC midnight following `response_day_utc`;
11. raw-record SHA-256 and physical-record lineage are retained for both daily closes;
12. bounded review sample and machine-readable candidate receipt are emitted.

## Stage 4 gates

| ID | Requirement | Status | Completion evidence |
|---|---|---|---|
| `CFA-S4-001` | Stage 3 entry gate is frozen and `CFA-S3-006=PASS` | PASS | Frozen Stage 3 `CANDIDATE_V6` contract. |
| `CFA-S4-002` | Exact market schema/types/time/price fields and source integrity | PASS | Local source inspection plus first constructor entry checks. |
| `CFA-S4-003` | Direct-USD population, uniqueness, and market-row existence | PASS | 434 eligible USD pairs / 434 bases, 0 duplicate bases, 0 pairs without market rows. |
| `CFA-S4-004` | Historical exact-23:59 response formula/boundary | FAIL | `AEVOUSD` has no exact 23:59 UTC candle. |
| `CFA-S4-005` | Historical exact-23:59 response construction | FAIL | Local construction stopped fail-closed on AEVOUSD. |
| `CFA-S4-006` | Historical exact-23:59 Stage 4 freeze | BLOCKED | Failed candidate cannot freeze. |
| `CFA-S4-007` | Full direct-USD day-end coverage diagnostic | PASS | 37,058 active pair-days; only 5,134 exact-23:59; 36,505 last-observed consecutive-day candidates. |
| `CFA-S4-008` | Define corrected last-observed-daily-close response rule | PASS | Exact formula, population, grain, cutoff, availability, missing policy, and lineage frozen above for validation. |
| `CFA-S4-009` | Construct corrected response artifact and validate formula, missingness, duplicates, timing, boundaries, and lineage | UNVERIFIED | Requires exact local corrected-constructor execution. |
| `CFA-S4-010` | Freeze corrected Stage 4 responses | BLOCKED | Requires `CFA-S4-009=PASS` plus bounded artifact review. |

## Current completion boundary

Stage 4 is **not complete**. The next authorized operation is exact local execution of the corrected last-observed-daily-close response constructor. Stage 5 factor construction remains blocked until `CFA-S4-010 = PASS`.