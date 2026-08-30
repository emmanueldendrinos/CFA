# CFA Stage 4 response contract — candidate — 2026-08-30

Status: **STAGE4_RESPONSE_CANDIDATE / SOURCE_INSPECTION_CANDIDATE / CONSTRUCTOR_CI_PASS / RESPONSE_FREEZE_BLOCKED**

## Authority and entry condition

This Stage 4 contract is subordinate to the CFA Source of Truth (SoT) and current CFA evidence. It introduces no factor, leakage, model-ready, or PLS decision.

The SoT does not define a response variable and explicitly states that the three handover CSVs contain no response variables. Therefore the response definition is derived afresh from the verified CFA market source and must be directly validated before freeze.

Stage 3 is the required upstream gate. The approved Stage 3 contract is frozen on `CANDIDATE_V6` with `CFA-S3-006 = PASS`.

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

## First exact local Stage 4 source inspection

Read-only local inspection root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-response-source\20260830-191507-b76ab5a1b7e349548ae263a5251aa86a`

Observed:

- PostgreSQL 18.4 with `default_transaction_read_only=on`;
- market relation columns: **19**;
- observed price/market field names include `open_price`, `high_price`, `low_price`, `close_price`, `base_volume`, `trade_count`;
- research-eligible direct-USD pair rows: **434**;
- distinct direct-USD base assets: **434**;
- duplicate direct-USD base identities: **0**;
- direct-USD pairs with zero market rows: **0**;
- direct-USD market integrity failures: **0**.

This directly establishes the one-to-one direct-USD identity observation. Exact column types, close-price operational semantics, day-boundary response construction, and final response artifacts remain subject to the constructor gate below.

## Primary response candidate

Response ID: **`RET_USD_1D_LOG`**.

### Population

Use only a research-eligible Kraken pair whose AF-001 `quote_exchange_symbol` is exactly `USD`.

The directly observed candidate population is 434 direct-USD pairs mapping one-to-one to 434 base assets. One of the 435 research-eligible base assets has no direct-USD response under this design.

No `USDT`, `USDC`, EUR, GBP, BTC/XBT, ETH, or other quote is substituted for USD. **No cross-rate conversion** is allowed.

### Grain

One response observation per `(base_asset_id, response_day_utc)`.

### Cutoff and response window

For response day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00, d+1 00:00:00+00)`;
- response availability: `d+1 00:00:00+00`.

The prior close is the exact one-minute candle starting at `d-1 23:59:00+00`, which completes at the predictor cutoff. The current close is the exact one-minute candle starting at `d 23:59:00+00`, which completes at response availability.

### Candidate operational formula

Subject to exact local constructor validation:

`RET_USD_1D_LOG(a,d) = ln(C_23:59(a,d) / C_23:59(a,d-1))`

where `C_23:59(a,d)` is `close_price` from the exact direct-USD one-minute candle whose UTC start is `d 23:59:00`.

No fallback to another minute is permitted.

### Unit and scaling

- unit: dimensionless natural-log return;
- raw response scaling/standardization: none in Stage 4.

### Missing-data policy

**No imputation is permitted.**

Exclude a response when either consecutive UTC-day `23:59` close is absent or invalid, or when any source/eligibility/lineage condition fails. No carry-forward, carry-backward, interpolation, stablecoin substitution, quote substitution, or cross-rate conversion is permitted.

Because the verified source starts on 2025-04-01, the earliest possible response day is 2025-04-02.

## Authorized response constructor

`scripts/windows/Build-CfaStage4Responses.ps1` is the authorized candidate constructor.

It is read-only with respect to PostgreSQL and must fail closed unless all of the following hold:

1. exact market schema contains the required time, lineage, OHLC, and eligibility fields;
2. `candle_start_utc` is `timestamp with time zone` and OHLC price fields are numeric;
3. direct-USD population remains exactly 434 pairs / 434 bases with zero ambiguity;
4. all 434 direct-USD pairs have market observations;
5. direct-USD OHLC values have zero NULL, non-positive, non-finite, ordering, or eligibility failures;
6. daily closes use only exact `23:59 UTC` candles;
7. response keys are unique;
8. every response is recomputed independently in PowerShell as `ln(current/prior)` and reconciles within `1e-12`;
9. prior/current candle timing reconciles exactly to predictor cutoff and response availability;
10. raw-record SHA-256 and physical-record lineage are retained for both closes.

GitHub Actions run `33330816755` completed successfully for the constructor implementation. It passed PowerShell 7 parsing, Windows PowerShell 5.1 parsing, the source-inspector self-test, the response-constructor formula/timing self-test, and fail-closed contract checks.

## Stage 4 gates

| ID | Requirement | Status | Completion evidence |
|---|---|---|---|
| `CFA-S4-001` | Stage 3 entry gate is frozen and `CFA-S3-006=PASS` | PASS | Frozen Stage 3 `CANDIDATE_V6` contract. |
| `CFA-S4-002` | Exact market schema/types/time/price semantics and bounded source integrity | UNVERIFIED | First inspection observed 19 columns and required field names; constructor must validate exact types and close semantics. |
| `CFA-S4-003` | Direct-USD response population, uniqueness, and coverage | UNVERIFIED | 434/434/0-duplicate/0-zero-row observation recorded; constructor must reconcile exact boundary coverage. |
| `CFA-S4-004` | Exact formula, close definition, cutoff/window/unit/grain/missing/availability timing | UNVERIFIED | Candidate operational rule frozen for validation; constructor execution required. |
| `CFA-S4-005` | Construct responses and validate invalid prices, duplicates, boundaries, formula, timing, and lineage | BLOCKED | Requires exact local constructor execution. |
| `CFA-S4-006` | Freeze Stage 4 responses | BLOCKED | Requires exact candidate receipt plus bounded artifact review. |

## Current completion boundary

Stage 4 is **not complete**. The next authorized operation is exact local execution of `Build-CfaStage4Responses.ps1`. Stage 5 factor construction remains blocked until `CFA-S4-006 = PASS`.
