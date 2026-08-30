# CFA Stage 4 V3 bounded response review — 2026-08-31

Status: **V3_DIRECT_REVIEW_PASS / FREEZE_FINALIZER_REQUIRED**

Reviewed candidate: `CANDIDATE_UTC_DAY_OBSERVED_V3` / `RET_USD_UTC_DAY_OBS_LOG`.

## Exact reviewed artifacts

- candidate receipt SHA-256: `d76659f58d2d0ca7bc8dba9af3bc7782968dfb36ba98c3f7ad2cbf5a0b7e1ad2`
- bounded review CSV SHA-256: `07458d4f73546e3e380b322c728623d8f72663f0909a4493d60ea23ca83a351c`
- receipt-declared review SHA-256: `07458d4f73546e3e380b322c728623d8f72663f0909a4493d60ea23ca83a351c`
- review rows: **49**
- candidate response rows: **37,058**
- distinct candidate response bases: **434**
- full response CSV SHA-256 declared by receipt: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`
- day-summary CSV SHA-256 declared by receipt: `7402e19fb05014de59e90b0a2c7173eab40615dca6d2a831b454850d964267a6`

The uploaded review CSV SHA-256 matched the uploaded candidate receipt exactly.

## Direct row-level review

All 49 deterministic review rows were directly inspected and independently checked for:

- response ID and duplicate `(base_asset_id,response_day_utc)` keys;
- predictor cutoff equal to the UTC start of `response_day_utc`;
- response window equal to `[d 00:00 UTC,d+1 00:00 UTC)`;
- response availability equal to `d+1 00:00 UTC`;
- first selected candle start at or after the predictor cutoff;
- last selected candle start at or after the first selected candle and before response availability;
- `first_minutes_after_midnight` reconciliation;
- `last_minutes_before_midnight` reconciliation;
- `observed_span_minutes_between_starts` reconciliation;
- finite, strictly positive first-open and last-close prices;
- independent `ln(last_close/first_open)` formula reconciliation within `1e-12`;
- physical-record lineage presence;
- 64-character lowercase hexadecimal raw-record SHA-256 lineage.

Observed mechanical failures: **0**.

No sampled response uses a market observation before its declared predictor cutoff.

## Stress coverage in the deterministic sample

The sample explicitly includes earliest and latest response dates, largest absolute returns, latest first observations, earliest last observations, and shortest observed spans.

Observed stress boundaries among the 49 rows:

- first observation minutes after midnight: **0 to 1,439**;
- last observation minutes before midnight: **0 to 1,436**;
- observed span between selected candle starts: **0 to 1,439 minutes**;
- zero-span sampled rows: **26**;
- sampled log-return range: approximately **-1.82087018 to +1.51035395**.

Zero-span rows are not a defect under the frozen V3 semantics. They represent an active UTC day for which the first and last selected market row are the same candle. The response is that candle's observed `open_price` to `close_price` log return. No value is carried from another day, interpolated, or synthesized.

A last observation early in the UTC day is also not interpreted as a midnight price. The V3 response is explicitly an **observed within-UTC-day return**, not a fixed-duration 24-hour return.

## First/last selection boundary

The local V3 constructor established full-source first/last selection fail-closed using `DISTINCT ON` ordered by exact `candle_start_utc` and `physical_record_number` for all 37,058 direct-USD active pair-days. The direct bounded review confirms that the emitted selected timestamps, timing fields, formula, cutoff placement, and lineage are internally consistent for all 49 stress rows.

The bounded review does not replace the constructor's full-source reconciliation; it is the required direct artifact-level semantic/timing review after that reconciliation.

## Decision

- `CFA-S4-014` direct bounded V3 review: **PASS**.
- No obvious formula, cutoff, timing, observed-span, price, duplicate-key, or lineage defect remains in the 49-row deterministic review.
- `CFA-S4-015` Stage 4 response freeze remains **BLOCKED** until the authorized finalizer verifies the exact local candidate receipt, review CSV, full response CSV, day-summary CSV, checked-in adjudication manifest, and all 37,058 response rows.

Checked-in row-level adjudication:

`docs/evidence/stage4-v3-review-adjudication-20260831.json`

Only the exact hash-verified V3 artifact may be frozen. Historical exact-23:59 and V2 last-observed-close failures remain preserved in lineage.
