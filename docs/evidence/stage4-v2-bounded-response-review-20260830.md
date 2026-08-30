# CFA Stage 4 V2 bounded response review — 2026-08-30

Status: **V2_DIRECT_REVIEW_FAIL / FORWARD_BOUNDARY_DEFECT**

Reviewed candidate: `CANDIDATE_LAST_OBSERVED_V2` / `RET_USD_1D_LOG_LAST_OBS`.

## Exact reviewed artifacts

- candidate receipt SHA-256: `aa434e550329b899d3942825119656eaf9edfe227256ac0d3cc3d442036b9c70`
- bounded review CSV SHA-256: `bf2036849db80f55f52e9c25bc99fe5fbd98b8829902fa385bf9c75c998a6e48`
- receipt-declared review SHA-256: `bf2036849db80f55f52e9c25bc99fe5fbd98b8829902fa385bf9c75c998a6e48`
- review rows: **40**
- candidate response rows: **36,505**
- distinct candidate response bases: **433**

The uploaded review CSV hash matched the uploaded receipt exactly.

## Mechanical row-level review

All 40 review rows were independently recomputed and checked for:

- `ln(current/prior)` formula;
- predictor-cutoff timestamp;
- response-availability timestamp;
- prior/current calendar-day labels;
- minutes-before-midnight fields;
- elapsed close-start minutes;
- positive finite prices;
- duplicate `(base_asset_id,response_day_utc)` keys;
- raw-record SHA-256 format;
- physical-record lineage presence.

Mechanical failures: **0**.

## Blocking response-boundary finding

The candidate is mechanically self-consistent but is not a leakage-safe forward response for the declared predictor cutoff `d 00:00 UTC`.

The denominator is the last observed close on day `d-1`. When that close occurs before `d 00:00`, the response `ln(L(d)/L(d-1))` includes price movement that occurred before the predictor cutoff. A predictor allowed to use information through the cutoff can therefore overlap the target interval.

Observed in the 40-row bounded review:

- prior close earlier than cutoff: **37 / 40** rows;
- prior close exactly at the day boundary: **3 / 40** rows;
- elapsed close-to-close interval not equal to 1,440 minutes: **37 / 40** rows;
- elapsed interval range: **89 to 2,779 minutes**;
- elapsed intervals shorter than 1,440 minutes: **15**;
- elapsed intervals longer than 1,440 minutes: **22**.

Example blocking row:

- asset: `SDN`
- response day: `2025-05-03`
- predictor cutoff: `2025-05-03T00:00:00Z`
- prior close start: `2025-05-02T19:56:00Z`
- current close start: `2025-05-03T00:03:00Z`
- elapsed close-start interval: **247 minutes**

This label includes approximately four hours of pre-cutoff price movement and only three minutes of post-cutoff movement. It therefore cannot be treated as a forward response beginning at the declared cutoff.

## Decision

- `CFA-S4-011` direct bounded review of V2: **FAIL**.
- Historical/provisional V2 response-rule status is superseded to **FAIL** for forward-boundary suitability.
- V2 construction arithmetic remains useful lineage evidence but does not establish a valid frozen response.
- Stage 4 freeze remains **BLOCKED**.

The correction must use only price observations whose information interval begins at or after the predictor cutoff. No cutoff relaxation or silent target overlap is permitted.
