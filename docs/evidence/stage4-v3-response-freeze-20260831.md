# CFA Stage 4 V3 response freeze — 2026-08-31

Status: **STAGE4_FROZEN / CFA-S4-015_PASS**

## Authority and exact finalizer execution

Authorized finalizer:

`scripts/windows/Finalize-CfaStage4ResponsesV3.ps1`

The exact local V3 candidate had already passed construction (`CFA-S4-013 = PASS`) and direct deterministic review (`CFA-S4-014 = PASS`). The finalizer was designed to fail closed unless the exact candidate receipt, review CSV, checked-in all-PASS adjudication, full response CSV, day-summary CSV, response formula/timing/cutoff checks, unique keys, 434 response bases, and lineage fields all reconciled.

The user executed the authorized finalizer against the exact reviewed candidate and reported the following terminal result verbatim:

```text
CFA STAGE 4 V3 RESPONSE FREEZE: PASS
Response rows: 37058
Distinct response bases: 434
Review rows adjudicated PASS: 49
CFA-S4-014 direct V3 review: PASS
CFA-S4-015 freeze responses: PASS
Freeze receipt: C:\Users\Emmanuel\Documents\CFA-local\stage4-freeze-v3\20260830-212830-1e5803b0a2b448b390e5204e401d1b39\stage4-v3-freeze-receipt.json
```

This output is the final Stage 4 hard-gate evidence.

## Frozen response definition

Response ID: **`RET_USD_UTC_DAY_OBS_LOG`**.

For asset `a` and UTC day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00,d+1 00:00:00+00)`;
- `O_first(a,d)` = open price from the valid direct-USD row with minimum candle timestamp in day `d`, timestamp ties broken by lowest physical-record number;
- `C_last(a,d)` = close price from the valid direct-USD row with maximum candle timestamp in day `d`, timestamp ties broken by highest physical-record number;
- response: `ln(C_last(a,d) / O_first(a,d))`;
- response availability: `d+1 00:00:00+00`.

Semantics: observed within-UTC-day natural-log return; not a fixed-duration 24-hour return.

Missing policy: no response row when the UTC day has no valid direct-USD observation; no imputation, carry-forward/backward, interpolation, quote substitution, stablecoin substitution, or cross-rate conversion.

Frozen exact population:

- response rows: **37,058**;
- distinct response bases: **434**;
- response days: **2025-04-01 through 2025-06-30**;
- directly adjudicated deterministic review rows: **49 / 49 PASS**.

Frozen artifact hashes from the exact reviewed candidate:

- full response CSV SHA-256: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`;
- review CSV SHA-256: `07458d4f73546e3e380b322c728623d8f72663f0909a4493d60ea23ca83a351c`;
- day-summary CSV SHA-256: `7402e19fb05014de59e90b0a2c7173eab40615dca6d2a831b454850d964267a6`;
- candidate receipt SHA-256: `d76659f58d2d0ca7bc8dba9af3bc7782968dfb36ba98c3f7ad2cbf5a0b7e1ad2`.

## Gate decision

- `CFA-S4-012 = PASS` — cutoff-safe V3 response definition.
- `CFA-S4-013 = PASS` — exact V3 construction and full-source validation.
- `CFA-S4-014 = PASS` — direct 49-row deterministic review.
- `CFA-S4-015 = PASS` — final exact hash-verified Stage 4 freeze.

Historical exact-23:59 and V2 failures remain preserved as historical failed candidate states and are not relabeled.

## Completion boundary

**Stage 4 is complete and frozen.**

The next authorized project sequence step is **Stage 5: define candidate factors**. No Stage 5 factor is approved or frozen by this evidence file.
