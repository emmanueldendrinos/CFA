# CFA Stage 4 response contract — V3 candidate — 2026-08-30

Status: **STAGE4_RESPONSE_CANDIDATE / SOURCE_SCHEMA_PASS / DIRECT_USD_POPULATION_PASS / EXACT_2359_FAILED / LAST_OBSERVED_V2_REVIEW_FAILED / UTC_DAY_OBS_RULE_FROZEN_FOR_VALIDATION / RESPONSE_FREEZE_BLOCKED**

## Authority and frozen source facts

This contract is subordinate to the CFA Source of Truth and authorized CFA evidence. The SoT defines no response variable, so Stage 4 derives responses afresh from verified source data.

Upstream Stage 3 is frozen on `CANDIDATE_V6` with `CFA-S3-006 = PASS`.

Verified market source:

- relation: `asrp.q2_market_1m_observations`;
- exact rows: **14,055,089**;
- interval: `2025-04-01 00:00:00+00` through `2025-06-30 23:59:00+00`;
- data-bearing pairs: **1,058**;
- zero source-window, minute-alignment, quality-flag, or duplicate-class failures;
- raw-to-typed reconciliation: PASS;
- Kraken archive SHA-256: `36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c`.

AF-001 SHA-256: `569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f`.

Direct Stage 4 inspection established:

- market relation columns: **19**;
- required OHLC fields include `open_price`, `high_price`, `low_price`, `close_price`;
- research-eligible direct-USD pairs: **434**;
- distinct direct-USD bases: **434**;
- duplicate direct-USD base identities: **0**;
- direct-USD pairs with zero market rows: **0**;
- direct-USD OHLC/integrity failures: **0**;
- eligible base without direct USD: `ZUSD`.

Therefore `CFA-S4-002 = PASS` and `CFA-S4-003 = PASS`.

## Historical exact-23:59 candidate — FAIL

`RET_USD_1D_LOG_2359(a,d) = ln(C_23:59(a,d) / C_23:59(a,d-1))` failed because exact `23:59 UTC` candles do not exist universally; the first blocking pair was `AEVOUSD`.

Historical statuses remain:

- `CFA-S4-004 = FAIL`;
- `CFA-S4-005 = FAIL`;
- `CFA-S4-006 = BLOCKED`.

## Day-end diagnostic — PASS

Exact local diagnostic root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-day-end-diagnostic\20260830-193709-3c9fb15b85db4dec94e8306e79f54b9e`

Observed across the 434 direct-USD pairs:

- active USD pair-days: **37,058**;
- pair-days with exact 23:59: **5,134**;
- pair-days without exact 23:59: **31,924**;
- pairs with no exact 23:59 ever: **46**;
- maximum last-candle lag before midnight: **1,436 minutes**;
- invalid last-close pair-days: **0**;
- consecutive-day last-observed-close candidates: **36,505**;
- exact-23:59 consecutive-day candidates: **2,309**.

`CFA-S4-007 = PASS`.

## Historical last-observed close-to-close V2 — FAIL after direct review

V2 candidate:

`RET_USD_1D_LOG_LAST_OBS(a,d) = ln(L(a,d) / L(a,d-1))`

where `L(a,d)` was the last observed valid direct-USD close during UTC day `d`.

Exact V2 candidate receipt reported 36,505 rows across 433 bases. The 40-row deterministic review CSV SHA-256 was:

`bf2036849db80f55f52e9c25bc99fe5fbd98b8829902fa385bf9c75c998a6e48`.

The review found zero arithmetic, serialization, key, price, hash-format, or lineage errors, but found a blocking forward-boundary defect:

- **37 / 40** sampled prior closes occurred before the declared `d 00:00 UTC` predictor cutoff;
- **37 / 40** sampled close-to-close intervals were not 1,440 minutes;
- sampled intervals ranged from **89 to 2,779 minutes**.

Example: `SDN`, response day `2025-05-03`, used a prior close at `2025-05-02T19:56:00Z` and current close at `2025-05-03T00:03:00Z`, so the response included substantial pre-cutoff price movement.

This violates the required predictor/response information boundary. V2 cannot freeze.

- `CFA-S4-008 = FAIL` — V2 rule fails direct forward-boundary review;
- `CFA-S4-009 = FAIL` — V2 constructed artifact fails timing/leakage suitability;
- `CFA-S4-010 = BLOCKED` — V2 freeze blocked;
- `CFA-S4-011 = FAIL` — direct deterministic V2 bounded review.

Detailed evidence: `docs/evidence/stage4-v2-bounded-response-review-20260830.md`.

## V3 cutoff-safe response rule — frozen for validation

Response ID: **`RET_USD_UTC_DAY_OBS_LOG`**.

### Population

Use only the same 434 research-eligible Kraken pairs whose AF-001 `quote_exchange_symbol` is exactly `USD`.

No USDT/USDC, other quote, stablecoin substitution, or cross-rate conversion is permitted.

### Grain

One response per `(base_asset_id, response_day_utc)` for each active UTC pair-day having at least one valid direct-USD observation.

### Predictor cutoff and response window

For UTC day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00, d+1 00:00:00+00)`;
- response availability: `d+1 00:00:00+00`.

Every price observation used by the response must have its candle start inside this response window. No price observation from before the predictor cutoff is permitted.

### First-open and last-close definitions

For asset `a` and active UTC day `d`:

- `O_first(a,d)` = `open_price` from the valid direct-USD row with minimum `candle_start_utc` in day `d`; if timestamps tie, choose the lowest `physical_record_number`;
- `C_last(a,d)` = `close_price` from the valid direct-USD row with maximum `candle_start_utc` in day `d`; if timestamps tie, choose the highest `physical_record_number`.

Both selected rows must be canonical-eligible, in-source-window, minute-aligned, quality-flag-free, duplicate-class-free, finite, non-NULL, and strictly positive.

### Formula

`RET_USD_UTC_DAY_OBS_LOG(a,d) = ln(C_last(a,d) / O_first(a,d))`.

This is an **observed within-UTC-day log return**, not a fixed-duration 24-hour return. For sparse pairs the first and last observations may cover materially less than a full day. The exact observed span must remain explicit in lineage.

A one-candle active day is permitted: the response is that candle's own open-to-close log return.

### Missing-data policy

If an asset has no valid direct-USD observation during UTC day `d`, no response row exists for that asset/day.

No imputation, carry-forward, carry-backward, interpolation, quote substitution, or cross-rate conversion is permitted.

### Required lineage

Each response row must retain at minimum:

- response ID;
- base asset, pair token, source member ordinal;
- response day;
- predictor cutoff and response availability;
- first and last candle start timestamps;
- first minutes after midnight;
- last minutes before midnight;
- observed span minutes between first and last candle starts;
- first `open_price` and last `close_price`;
- first and last physical record numbers;
- first and last raw-record SHA-256 values;
- natural-log return.

### V3 hard requirements

The V3 constructor must fail closed unless:

1. AF-001 and the 434-pair / 434-base direct-USD population reconcile exactly;
2. frozen market cardinality/schema/integrity checks remain PASS;
3. direct-USD OHLC validity remains PASS;
4. the daily first/last selection produces exactly **37,058** active pair-day rows, reconciling to the direct day-end diagnostic;
5. all response keys are unique;
6. first and last selected timestamps lie within their exact UTC response day and `first <= last`;
7. every response uses only observations at or after its predictor cutoff and before response availability;
8. every response independently recomputes as `ln(last_close/first_open)` within `1e-12`;
9. no invalid price or lineage value is accepted;
10. a bounded deterministic review sample and machine-readable receipt are emitted.

`CFA-S4-012 = PASS` — V3 response definition is frozen for exact validation.

## Stage 4 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S4-001` | Stage 3 entry gate | PASS |
| `CFA-S4-002` | Exact market schema/types/source integrity | PASS |
| `CFA-S4-003` | Direct-USD population/uniqueness/coverage | PASS |
| `CFA-S4-004` | Historical exact-23:59 rule | FAIL |
| `CFA-S4-005` | Historical exact-23:59 construction | FAIL |
| `CFA-S4-006` | Historical exact-23:59 freeze | BLOCKED |
| `CFA-S4-007` | Day-end coverage diagnostic | PASS |
| `CFA-S4-008` | Historical V2 last-observed close-to-close rule | FAIL |
| `CFA-S4-009` | Historical V2 constructed response artifact | FAIL |
| `CFA-S4-010` | Historical V2 freeze | BLOCKED |
| `CFA-S4-011` | Direct V2 bounded timing/leakage review | FAIL |
| `CFA-S4-012` | Define cutoff-safe V3 within-day observed return | PASS |
| `CFA-S4-013` | Construct and validate V3 response candidate | UNVERIFIED |
| `CFA-S4-014` | Direct deterministic V3 bounded review | BLOCKED |
| `CFA-S4-015` | Freeze Stage 4 responses | BLOCKED |

## Current completion boundary

Stage 4 remains **not complete**. The next authorized operation is exact local construction of `RET_USD_UTC_DAY_OBS_LOG`. Stage 5 factor definition remains blocked until `CFA-S4-015 = PASS`.
