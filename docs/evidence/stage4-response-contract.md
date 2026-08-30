# CFA Stage 4 response contract — candidate — 2026-08-30

Status: **STAGE4_RESPONSE_CANDIDATE / SOURCE_SCHEMA_UNVERIFIED / RESPONSE_FREEZE_BLOCKED**

## Authority and entry condition

This Stage 4 contract is subordinate to the CFA Source of Truth (SoT) and current CFA evidence. It introduces no factor, leakage, model-ready, or PLS decision.

The SoT does not define a response variable and explicitly states that the three handover CSVs contain no response variables. Therefore the response definition must be derived afresh from the verified CFA market source and must be directly validated before freeze.

Stage 3 is the required upstream gate. The approved Stage 3 contract is frozen on `CANDIDATE_V6` with `CFA-S3-006 = PASS`.

## Verified market-source boundary inherited from Stage 1

Stage 1 directly verified the Q2 market source:

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

AF-001 remains the approved pair identity/count index. Its exact file is `candidate-analysis/ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv`, SHA-256 `569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f`.

The current Stage 4 implementation must not assume the market relation's price-column names, data types, units, close semantics, or null policy. Those are direct-inspection requirements.

## Primary response candidate

Response ID: **`RET_USD_1D_LOG`**

This definition is a **candidate design**, not yet frozen.

### Population

Candidate observations are limited to base assets having a research-eligible Kraken pair whose `quote_exchange_symbol` in AF-001 is exactly `USD`.

No `USDT`, `USDC`, EUR, GBP, BTC/XBT, ETH, or other quote is substituted for USD. No cross-rate conversion is allowed at this stage. If a base asset has zero eligible direct-USD pairs, it has no response under this candidate. If a base asset has more than one eligible direct-USD pair, that ambiguity is blocking until directly resolved.

### Grain

One response observation per:

`(base_asset_id, response_day_utc)`

where `response_day_utc` is a UTC calendar day.

### Candidate cutoff and response window

For response day `d`:

- predictor cutoff candidate: `d 00:00:00+00`;
- response window: `[d 00:00:00+00, d+1 00:00:00+00)`;
- response availability time: `d+1 00:00:00+00` or later, after the response window has completed.

This timing is intentionally explicit so later leakage checks can require every predictor to use only information available before the response cutoff.

### Candidate formula

After direct inspection identifies and validates the exact canonical close-price field and day-boundary observation semantics, the intended response is a one-day close-to-close natural-log return:

`RET_USD_1D_LOG(a,d) = ln(C(a,d) / C(a,d-1))`

where `C(a,d)` is the validated direct-USD daily closing price for base asset `a` on UTC day `d`.

The exact operational definition of `C(a,d)` is **UNVERIFIED** until the source schema and minute/day-boundary behavior are inspected. In particular, Stage 4 must determine whether a valid close requires an exact `23:59 UTC` candle or another directly justified rule. No fallback rule is approved by this contract.

### Unit and transformation

- unit: dimensionless natural-log return;
- transformation: natural logarithm;
- scaling/standardization: none in Stage 4. Any later predictor/response preprocessing belongs to the frozen model-ready design, not to the raw response definition.

### Missing-data policy

No imputation is permitted.

A response is missing/excluded when any required market observation is absent, the validated close price is NULL/non-finite/non-positive, the direct-USD pair identity is ambiguous, or any required source/eligibility condition fails.

No carry-forward, carry-backward, interpolation, stablecoin substitution, or cross-rate conversion is permitted.

Because the verified source starts at `2025-04-01 00:00:00+00`, the first Q2 day cannot have a prior-Q2 close under a Q2-only response design unless separately extended source evidence is approved. Therefore the earliest possible candidate response day is `2025-04-02`.

## Required direct observations before response freeze

Stage 4 must directly establish all of the following from the exact local market source and AF-001 before `RET_USD_1D_LOG` can be frozen:

1. exact `asrp.q2_market_1m_observations` schema, column names, data types, nullability, and bounded row samples;
2. exact price field used for the response and its semantics;
3. direct-USD pair population, base-asset cardinality, and any duplicate/ambiguous direct-USD identity;
4. per-pair Q2 time coverage and UTC day-boundary coverage;
5. valid-price constraints and observed null/non-positive/non-finite counts;
6. response-day construction coverage, duplicate response keys, and boundary-day behavior;
7. formula, cutoff, window, unit, grain, missing policy, and information-availability timing reconciled to direct observations.

## Frozen Stage 4 gate IDs

| ID | Requirement | Status | Completion evidence |
|---|---|---|---|
| `CFA-S4-001` | Stage 3 entry gate is frozen and `CFA-S3-006=PASS` | PASS | Frozen Stage 3 `CANDIDATE_V6` contract. |
| `CFA-S4-002` | Directly inspect exact market relation schema, types, time fields, price fields, and bounded samples | UNVERIFIED | Requires exact local read-only Stage 4 source inspection. |
| `CFA-S4-003` | Determine direct-USD response population and prove pair/base uniqueness and coverage | UNVERIFIED | Requires AF-001 plus exact local market reconciliation. |
| `CFA-S4-004` | Validate exact response formula, daily-close definition, cutoff, response window, unit, grain, missing policy, and availability timing | UNVERIFIED | Depends on `CFA-S4-002` and `CFA-S4-003`. |
| `CFA-S4-005` | Construct candidate responses and validate nulls, invalid prices, duplicates, boundaries, time ordering, cardinality, and reconciliation | BLOCKED | Depends on `CFA-S4-002` through `CFA-S4-004`. |
| `CFA-S4-006` | Freeze Stage 4 responses | BLOCKED | All Stage 4 hard gates must PASS. |

## Current completion boundary

Stage 4 is **not complete**. The next authorized operation is read-only direct inspection of the exact market-source schema and direct-USD population. No response values are frozen or approved yet, and Stage 5 candidate-factor construction remains blocked until `CFA-S4-006 = PASS`.
