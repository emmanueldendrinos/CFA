# CFA Stage 4 V3 response code validation — 2026-08-30

Status: **V3_CODE_CI_PASS / LOCAL_V3_RESPONSE_UNVERIFIED**

V3 response ID: `RET_USD_UTC_DAY_OBS_LOG`.

Authorized constructor:

`scripts/windows/Build-CfaStage4ResponsesV3.ps1`

## Consolidated Stage 4 validation

GitHub Actions run `33334614915` completed **successfully** at tested head:

`9bde888de5c1e2747ba2b53c539d38bfc2bccd42`

V3 constructor file was introduced at executable commit:

`385e53308d0be76cc9e8fa360ffeb0db97b942d4`

The consolidated run passed:

- PowerShell 7 parsing for all current Stage 4 scripts;
- Windows PowerShell 5.1 parsing for all current Stage 4 scripts;
- source-inspector regression self-test;
- historical exact-23:59 constructor self-test;
- day-end diagnostic self-test;
- historical V2 last-observed constructor self-test;
- V3 cutoff-safe constructor self-test;
- current fail-closed Stage 4 contract and V2-review evidence checks.

## Preserved diagnostic validation

The auxiliary day-end diagnostic workflow was aligned with the current V3 contract without changing the diagnostic calculations.

GitHub Actions run `33334691112` completed **successfully** at:

`a9ef892c6f564f8ce90c5cf93fc5d1a63259e1ab`

It preserves the directly observed day-end diagnostic evidence while recognizing the V2 timing failure and V3 correction boundary.

## Validation boundary

CI proves implementation behavior only. It does not prove the exact local V3 response artifact.

Local V3 construction must still reproduce:

- direct-USD pairs: 434;
- direct-USD bases: 434;
- active USD pair-days / expected V3 response rows: 37,058;
- zero duplicate response keys;
- zero pre-cutoff response observations;
- zero observations at or after response availability;
- exact `ln(last_close / first_open)` reconciliation;
- complete first/last raw-record lineage.

`CFA-S4-013` remains `UNVERIFIED`, `CFA-S4-014` remains `BLOCKED`, and `CFA-S4-015` remains `BLOCKED` until exact local V3 construction and direct bounded review pass.
