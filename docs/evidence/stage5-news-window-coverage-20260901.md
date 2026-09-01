# CFA Stage 5 news-window source coverage evidence — 2026-09-01

Status: **CFA-S5-010_PASS / NEWS_FACTOR_AVAILABILITY_SEMANTICS_UNVERIFIED**

## Authority and purpose

This evidence is subordinate to the CFA Source of Truth, frozen Stage 1 source contract, frozen Stage 3 V6 news matching, frozen Stage 4 response contract, and current Stage 5 factor contract.

It records the direct local execution of `scripts/windows/Diagnose-CfaStage5NewsWindowCoverage.ps1` after the Windows PowerShell 5.1 timestamp-serialization defect was corrected by replacing quoted `to_char` contract-boundary serialization with quote-safe Unix epoch checks.

The successful local run used repository commit:

`9357392866e0d99719153f83634d4546ad2d0095`

Local evidence directory:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-news-window-coverage\20260901-181131-76831627e2864f80b23d02a36003aa81`

Diagnostic receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-news-window-coverage\20260901-181131-76831627e2864f80b23d02a36003aa81\stage5-news-window-coverage.json`

## Direct observations

The successful diagnostic reported:

- PostgreSQL: **18.4**;
- session mode: `default_transaction_read_only=on`;
- frozen source slots: **8,736**;
- downloaded slots: **7,163**;
- provider-missing slots: **1,573**;
- V6 matches mapped to downloaded source slots: **22,060**;
- blank `source_common_name` rows: **0**;
- distinct nonblank `source_common_name` values: **1,601**;
- complete 24-hour response days: **69 / 91**;
- 24-hour available / source-incomplete / outside-news-population response rows: **27,644 / 9,141 / 273**;
- complete 6-hour response days: **72 / 91**;
- 6-hour available / source-incomplete / outside-news-population response rows: **28,849 / 7,936 / 273**.

The response-row accounting reconciles exactly:

- 24-hour: `27,644 + 9,141 + 273 = 37,058`;
- 6-hour: `28,849 + 7,936 + 273 = 37,058`.

The **273 outside-news-population rows** are the response rows belonging to the three frozen response-only assets `ZAUD`, `ZEUR`, and `ZGBP`. They are structural outside-population observations, not zero-news observations.

Provider-missing slots are structural source missingness. A news-count value of zero is therefore valid only for a response row whose asset is inside the frozen 431-asset Stage 3 news population and whose entire candidate lookback window is composed of downloaded source slots.

## Coverage decision

`CFA-S5-010 = PASS` — the exact 24-hour and 6-hour source-window completeness accounting is now measured and reconciled.

This PASS is a **source coverage** decision only. It does not by itself prove historical predictor availability.

## Historical availability boundary

The authorized CFA source schema records, for each source slot:

- `archive_timestamp_utc` — the nominal GDELT archive/update timestamp;
- source status and HTTP status;
- payload hash and local lineage;
- `last_attempt_at_utc` — CFA's own later acquisition attempt timestamp.

It does **not** record a provider historical publication/first-availability timestamp for the 2025 archive.

Therefore the current evidence does not establish that `archive_timestamp_utc`, or a retained row's `gdelt_date_utc`, is exactly the time at which that information became historically observable to a predictor.

No finite publication lag is assumed or invented here.

The candidate 24-hour and 6-hour news formulas can be stated mathematically, but their historical information-availability rule remains **UNVERIFIED** until direct provider/source evidence establishes an admissible availability timestamp or lag policy.

Accordingly:

- `CFA-S5-010 = PASS`;
- `CFA-S5-011 = UNVERIFIED` — historical GDELT information-availability semantics;
- `CFA-S5-007 = BLOCKED` pending `CFA-S5-011`.

Stage 6 leakage testing, Stage 7 model-ready freezing, and PLS remain blocked.
