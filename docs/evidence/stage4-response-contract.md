# CFA Stage 4 response contract — candidate — 2026-08-30

Status: **STAGE4_RESPONSE_CANDIDATE / SOURCE_SCHEMA_PASS / DIRECT_USD_POPULATION_PASS / EXACT_2359_CANDIDATE_FAILED / DAY_END_DIAGNOSTIC_REQUIRED / RESPONSE_FREEZE_BLOCKED**

## Authority and entry condition

This Stage 4 contract is subordinate to the CFA Source of Truth (SoT) and current CFA evidence. It introduces no factor, leakage, model-ready, or PLS decision.

The SoT does not define a response variable and explicitly states that the three handover CSVs contain no response variables. The response definition is therefore being derived afresh from the verified CFA market source. Stage 3 is frozen on `CANDIDATE_V6` with `CFA-S3-006 = PASS`.

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

## Exact local source inspection — PASS for schema/population entry facts

Read-only local inspection root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-response-source\20260830-191507-b76ab5a1b7e349548ae263a5251aa86a`

Observed:

- PostgreSQL 18.4 with `default_transaction_read_only=on`;
- market relation columns: **19**;
- required market fields include `open_price`, `high_price`, `low_price`, `close_price`, `base_volume`, and `trade_count`;
- research-eligible direct-USD pair rows: **434**;
- distinct direct-USD base assets: **434**;
- duplicate direct-USD base identities: **0**;
- direct-USD pairs with zero market rows: **0**;
- direct-USD market integrity failures: **0**.

The exact response constructor subsequently executed `Assert-MarketSchema`, the frozen market cardinality/integrity reconciliation, and the direct-USD OHLC integrity checks before reaching its day-boundary test. Therefore the directly executed candidate establishes:

- `CFA-S4-002 = PASS` for the exact required schema/type/integrity entry checks;
- `CFA-S4-003 = PASS` for the 434-pair / 434-base direct-USD population, uniqueness, and existence of market observations.

One of the 435 research-eligible base assets has no direct-USD pair: `ZUSD`. It has no response under a direct-USD-only design.

## Historical exact-23:59 response candidate — FAIL

The first operational response candidate was:

`RET_USD_1D_LOG_2359(a,d) = ln(C_23:59(a,d) / C_23:59(a,d-1))`

with one response per `(base_asset_id,response_day_utc)`, predictor cutoff `d 00:00 UTC`, response window `[d 00:00,d+1 00:00)`, and response availability `d+1 00:00 UTC`.

No fallback, imputation, stablecoin substitution, quote substitution, or cross-rate conversion was permitted.

Exact local construction root:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-responses\20260830-192822-74f6804e90d94fb1bac4990739b9d15f`

The constructor failed at the first blocking day-boundary condition:

`Direct-USD pair AEVOUSD has no 23:59 UTC close candle.`

The failure occurred only after schema, frozen market integrity, direct-USD population, and direct-USD OHLC validity checks had passed. The failed assumption is therefore the universal exact-`23:59` boundary, not source integrity.

The exact-`23:59` rule must not be silently relaxed. It is preserved as a failed candidate:

- `CFA-S4-004 = FAIL` — exact-23:59 response boundary is not supported for the full 434-base direct-USD population;
- `CFA-S4-005 = FAIL` — exact-23:59 response construction did not produce a valid candidate;
- historical `CFA-S4-006 = BLOCKED` — that candidate cannot freeze Stage 4.

## Required day-end diagnostic

Before defining a corrected response, Stage 4 must directly measure the actual end-of-day observation pattern across all 434 USD pairs.

Authorized diagnostic:

`scripts/windows/Diagnose-CfaStage4DayEndCoverage.ps1`

It is read-only and must report at minimum:

1. active UTC days per USD pair;
2. days with and without exact `23:59` candles;
3. last observed candle time for every active pair/day;
4. minutes between the last observed candle and midnight;
5. missing active days inside each pair's active span;
6. invalid last-close observations;
7. distribution of day-end lags;
8. pair count with no exact `23:59` observation ever;
9. consecutive-day candidate counts under exact-`23:59` versus last-observed-daily-close definitions;
10. bounded evidence for `AEVOUSD` and the largest day-end gaps.

No corrected formula is approved until this diagnostic is directly executed and reviewed.

## Response-design invariants that remain frozen

Any corrected Stage 4 response must continue to use:

- direct Kraken USD pairs only;
- one response per `(base_asset_id,response_day_utc)`;
- UTC calendar-day semantics;
- natural-log return if a price-return response remains selected;
- no imputation;
- no carry-forward or carry-backward across missing days;
- no interpolation;
- no USDT/USDC substitution;
- no cross-rate conversion;
- explicit predictor cutoff, response window, response availability, and raw-record lineage;
- fail-closed exclusion when the observations required by the final rule are absent or invalid.

## Stage 4 gates

| ID | Requirement | Status | Completion evidence |
|---|---|---|---|
| `CFA-S4-001` | Stage 3 entry gate is frozen and `CFA-S3-006=PASS` | PASS | Frozen Stage 3 `CANDIDATE_V6` contract. |
| `CFA-S4-002` | Exact market schema/types/time/price fields and source integrity | PASS | Local constructor passed `Assert-MarketSchema` and frozen market integrity checks before the boundary failure. |
| `CFA-S4-003` | Direct-USD population, uniqueness, and market-row existence | PASS | 434 eligible USD pairs / 434 bases, 0 duplicate bases, 0 pairs without market rows. |
| `CFA-S4-004` | Historical exact-23:59 response formula/boundary | FAIL | `AEVOUSD` has no exact 23:59 UTC candle. |
| `CFA-S4-005` | Historical exact-23:59 response construction | FAIL | Local construction stopped fail-closed on AEVOUSD. |
| `CFA-S4-006` | Historical exact-23:59 Stage 4 freeze | BLOCKED | Failed candidate cannot freeze. |
| `CFA-S4-007` | Measure full direct-USD day-end coverage and staleness distribution | UNVERIFIED | Requires exact local day-end diagnostic. |
| `CFA-S4-008` | Define and validate one corrected response boundary/formula from direct evidence | BLOCKED | Depends on `CFA-S4-007`. |
| `CFA-S4-009` | Construct corrected response artifact and validate formula, missingness, duplicates, timing, boundaries, and lineage | BLOCKED | Depends on `CFA-S4-008`. |
| `CFA-S4-010` | Freeze corrected Stage 4 responses | BLOCKED | All current Stage 4 correction gates must PASS. |

## Current completion boundary

Stage 4 is **not complete**. The only valid next operation is the read-only day-end coverage diagnostic. Stage 5 factor construction remains blocked until `CFA-S4-010 = PASS`.
