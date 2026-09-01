# CFA Stage 5 source-entry correction — 2026-09-01

Status: **SOURCE_ENTRY_PASS / REPORTING_DEFECT_PRESERVED / NEWS_SLOT_COVERAGE_REQUIRED**

## Authority and lineage

This evidence is subordinate to the CFA Source of Truth, frozen Stage 1/3/4 evidence, and direct local Stage 5 executions.

Historical Stage 5 source-inspection receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-factor-sources\20260831-044223-9014b54f57564e09818fe6991e762fb0\stage5-factor-source-inspection.json`

The local inspection completed its source checks and printed PASS for `CFA-S5-002` through `CFA-S5-005`, but its final console/JSON field `V6 match rows` was corrupted to `1` by a PowerShell reporting-variable collision. PowerShell variable names are case-insensitive and `$Matches` is an automatic variable populated by `-match`; the script's `$matches` data variable was therefore overwritten after the exact 22,060-row V6 validation had already executed.

The historical receipt is preserved as a reporting-defective artifact and is not silently rewritten.

## Corrected local validation

Authorized correction validator:

`scripts/windows/Validate-CfaStage5FactorSourceReceipt.ps1`

Exact local corrected receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-factor-source-correction\20260901-175820-8f4a6a64f46248c780c4335c14b07985\stage5-factor-source-corrected-receipt.json`

Observed local result:

- correction status: **PASS**;
- legacy reported V6 match rows: **1**;
- corrected V6 match rows: **22,060**;
- V6 matched assets: **282**;
- V6 distinct records: **18,503**;
- response/direct-USD bases: **434**;
- Stage 3 news-population assets: **431**;
- response/news intersection: **431**;
- response-only assets outside the news population: **3 — `ZAUD`, `ZEUR`, `ZGBP`**;
- news-only assets without a direct-USD response: **0**;
- response rows with prior active market day: **36,505**;
- response rows without prior active market day: **553**.

The correction validator independently re-read the exact frozen Stage 3 V6 match CSV and Stage 4 response CSV before emitting PASS. It fails closed unless the exact V6 count/deduplication/population and frozen Stage 4 response identity/hash reconcile.

CI run `33358211026` completed successfully for the correction path, including PowerShell 7 parsing, Windows PowerShell 5.1 parsing, inspector self-test, correction-validator self-test, and fail-closed contract checks.

## Source facts carried forward

The successful Stage 5 source inspection established:

- GDELT retained-match timestamp range: `2025-04-01T00:00:00Z` through `2025-06-14T17:45:00Z`;
- downloaded archive timestamp range observed by the inspection: `2025-04-01T00:00:00Z` through `2025-06-14T17:45:00Z`;
- market factor field types: `open_price`, `high_price`, `low_price`, `close_price`, `base_volume` = PostgreSQL `numeric`; `trade_count` = `bigint`;
- direct-USD factor-source integrity checks passed with no null factor fields, nonpositive OHLC prices, negative base volume, or negative trade count in the inspected population.

Stage 1 independently freezes the replacement GDELT source contract to the full Q2 interval `[2025-04-01 00:00 UTC, 2025-07-01 00:00 UTC)` with 8,736 nominal 15-minute slots: 7,163 downloaded, 1,573 explicit provider-missing, and 0 unresolved. Provider-missing slots are source missingness and must not be interpreted as zero news.

## Decision

- `CFA-S5-002` population reconciliation: **PASS**.
- `CFA-S5-003` exact V6 artifact/schema/deduplication/timestamp verification: **PASS**.
- `CFA-S5-004` market factor-source field/type/value-boundary verification: **PASS**.
- `CFA-S5-005` prior-calendar-day market availability measurement: **PASS**.

These PASS results do not authorize news counts over incomplete provider-slot windows. A separate source-slot completeness gate is required before news-hype factor definitions can pass.
