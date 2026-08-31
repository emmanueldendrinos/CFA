# CFA Stage 4 response contract — frozen V3 — 2026-08-31

Status: **STAGE4_FROZEN / V3_RESPONSE_APPROVED / CFA-S4-015_PASS**

## Authority and upstream entry

This contract is subordinate to the CFA Source of Truth and authorized CFA evidence. The SoT defines no response variable, so Stage 4 derived responses afresh from verified market source data.

Stage 3 is frozen on `CANDIDATE_V6` with `CFA-S3-006 = PASS`.

## Frozen market-source facts

Verified relation: `asrp.q2_market_1m_observations`.

Frozen Stage 1 / Stage 4 source facts:

- exact market rows: **14,055,089**;
- interval: `2025-04-01 00:00:00+00` through `2025-06-30 23:59:00+00`;
- data-bearing pairs: **1,058**;
- market relation columns: **19**;
- required OHLC fields: `open_price`, `high_price`, `low_price`, `close_price`;
- zero source-window, minute-alignment, quality-flag, duplicate-class, or direct-USD OHLC integrity failures;
- raw-to-typed reconciliation: PASS;
- Kraken archive SHA-256: `36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c`;
- AF-001 SHA-256: `569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f`;
- research-eligible direct-USD pairs: **434**;
- distinct direct-USD bases: **434**;
- duplicate direct-USD base identities: **0**;
- direct-USD pairs with zero market rows: **0**;
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

## Historical V2 last-observed close-to-close — FAIL

V2 candidate:

`RET_USD_1D_LOG_LAST_OBS(a,d) = ln(L(a,d) / L(a,d-1))`.

Its 40-row deterministic review found zero mechanical arithmetic/lineage defects but a blocking forward-boundary defect:

- prior close earlier than declared predictor cutoff: **37 / 40** rows;
- close-to-close interval not equal to 1,440 minutes: **37 / 40** rows;
- sampled elapsed interval range: **89 to 2,779 minutes**.

Example: `SDN`, response day `2025-05-03`, used prior close `2025-05-02T19:56:00Z` and current close `2025-05-03T00:03:00Z`, so the label included pre-cutoff movement.

Detailed evidence: `docs/evidence/stage4-v2-bounded-response-review-20260830.md`.

Historical V2 statuses:

- `CFA-S4-008 = FAIL`;
- `CFA-S4-009 = FAIL`;
- `CFA-S4-010 = BLOCKED`;
- `CFA-S4-011 = FAIL`.

## Frozen V3 response definition

Response ID: **`RET_USD_UTC_DAY_OBS_LOG`**.

Population: only the 434 research-eligible Kraken direct-USD pairs from AF-001. No stablecoin substitution, other quote, or cross-rate conversion is permitted.

Grain: one response per `(base_asset_id,response_day_utc)` for every active UTC pair-day with at least one valid direct-USD observation.

For UTC day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00,d+1 00:00:00+00)`;
- response availability: `d+1 00:00:00+00`.

Definitions:

- `O_first(a,d)` = `open_price` from the valid direct-USD row with minimum `candle_start_utc` in day `d`; timestamp ties use lowest `physical_record_number`;
- `C_last(a,d)` = `close_price` from the valid direct-USD row with maximum `candle_start_utc` in day `d`; timestamp ties use highest `physical_record_number`.

Formula:

`RET_USD_UTC_DAY_OBS_LOG(a,d) = ln(C_last(a,d) / O_first(a,d))`.

Semantics: **observed within-UTC-day natural-log return; not a fixed-duration 24-hour return**.

A one-candle active day is valid and uses that candle's own open-to-close return. If an asset has no valid direct-USD observation during day `d`, no response exists.

Missing policy: **no imputation**. No carry-forward, carry-backward, interpolation, quote substitution, stablecoin substitution, or cross-rate conversion is permitted.

Required lineage per response includes response ID, base/pair/member identity, day, cutoff, response availability, first/last candle timestamps, first/last day-position metrics, observed span, first open, last close, first/last physical-record numbers, first/last raw-record SHA-256, and response value.

`CFA-S4-012 = PASS`.

## Exact V3 construction — PASS

Exact local run root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-responses-v3\20260830-210449-42a1dd2ba1904e778c11deede2cfe314`

Exact candidate:

- response contract: `CANDIDATE_UTC_DAY_OBSERVED_V3`;
- response rows: **37,058**;
- distinct response bases: **434**;
- response days: `2025-04-01` through `2025-06-30`;
- review rows: **49**;
- response CSV SHA-256: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`;
- review CSV SHA-256: `07458d4f73546e3e380b322c728623d8f72663f0909a4493d60ea23ca83a351c`;
- day-summary SHA-256: `7402e19fb05014de59e90b0a2c7173eab40615dca6d2a831b454850d964267a6`;
- candidate receipt SHA-256: `d76659f58d2d0ca7bc8dba9af3bc7782968dfb36ba98c3f7ad2cbf5a0b7e1ad2`.

The constructor reconciled full population, unique keys, cutoff/window timing, first/last selected rows, positive finite prices, formula within `1e-12`, and raw-record lineage.

`CFA-S4-013 = PASS`.

## Direct deterministic V3 review — PASS

All **49** deterministic review rows were directly inspected. The uploaded review CSV SHA-256 matched the candidate receipt exactly.

Observed review result:

- mechanical failures: **0**;
- pre-cutoff selected observations: **0**;
- out-of-window selected observations: **0**;
- formula failures: **0**;
- timing-field reconciliation failures: **0**;
- duplicate response keys: **0**;
- invalid/non-positive sampled prices: **0**;
- malformed sampled raw-record SHA-256 lineage: **0**.

Stress coverage included earliest/latest dates, largest absolute returns, latest first observations, earliest last observations, and shortest observed spans. There were **26** zero-span sampled rows, all valid one-candle observed open-to-close responses under V3 semantics.

Detailed evidence:

- `docs/evidence/stage4-v3-bounded-response-review-20260831.md`;
- `docs/evidence/stage4-v3-review-adjudication-20260831.json`.

`CFA-S4-014 = PASS`.

## Final V3 freeze — PASS

Authorized finalizer:

`scripts/windows/Finalize-CfaStage4ResponsesV3.ps1`

The finalizer was CI-validated to fail closed unless it verified the exact candidate receipt, 49-row review CSV, checked-in all-PASS adjudication, full 37,058-row response CSV, day-summary CSV, exact artifact hashes, formula/timing/cutoff checks, unique keys, 434 response bases, and lineage fields.

Exact local finalizer output:

```text
CFA STAGE 4 V3 RESPONSE FREEZE: PASS
Response rows: 37058
Distinct response bases: 434
Review rows adjudicated PASS: 49
CFA-S4-014 direct V3 review: PASS
CFA-S4-015 freeze responses: PASS
Freeze receipt: C:\Users\Emmanuel\Documents\CFA-local\stage4-freeze-v3\20260830-212830-1e5803b0a2b448b390e5204e401d1b39\stage4-v3-freeze-receipt.json
```

Final freeze evidence: `docs/evidence/stage4-v3-response-freeze-20260831.md`.

`CFA-S4-015 = PASS`.

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
| `CFA-S4-013` | Construct and validate exact V3 response candidate | PASS |
| `CFA-S4-014` | Direct deterministic V3 bounded review | PASS |
| `CFA-S4-015` | Freeze Stage 4 responses | PASS |

Historical FAIL/BLOCKED statuses above are preserved failed candidate states and are not current blockers.

## Completion boundary

**Stage 4 is complete and frozen.**

The next authorized project sequence step is **Stage 5: define candidate factors**. No Stage 5 factor is approved or frozen by this contract.
