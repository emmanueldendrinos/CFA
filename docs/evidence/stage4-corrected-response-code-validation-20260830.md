# CFA Stage 4 corrected response constructor validation — 2026-08-30

Status: **CORRECTED_CONSTRUCTOR_CI_PASS / LOCAL_CORRECTED_RESPONSE_UNVERIFIED**

Corrected response ID: `RET_USD_1D_LOG_LAST_OBS`.

Authorized corrected constructor:

`scripts/windows/Build-CfaStage4ResponsesV2.ps1`

Initial constructor implementation passed GitHub Actions run `33331606912` at executable commit:

`6f63c0f195d9a34a7c9c03ff15e6f736bb9c142d`

The first exact local corrected-constructor execution then stopped before response construction on an implementation-only serialization mismatch:

`Malformed boolean for canonical_eligible: 't'`

PostgreSQL `COPY ... FORMAT CSV` emitted boolean values as `t` / `f`, while the helper accepted only `true` / `false`. This observation does not change the response rule, source population, formula, missing-data policy, timing, or Stage 4 gate evidence. `CFA-S4-009` remained `UNVERIFIED` because no corrected response candidate was produced.

The parser was corrected narrowly to accept both representations required by the exact inputs:

- AF-001 boolean strings: `True` / `False`;
- PostgreSQL COPY boolean strings: `t` / `f`.

Regression assertions explicitly test all four representations.

GitHub Actions run `33333436515` completed successfully at corrected executable commit:

`bd5129db10c8fe7d746a1e06df340da6a42b2823`

The corrected run passed:

- PowerShell 7 parsing for all current Stage 4 scripts;
- Windows PowerShell 5.1 parsing for all current Stage 4 scripts;
- Stage 4 source-inspector self-test;
- historical exact-23:59 constructor self-test;
- day-end diagnostic self-test;
- corrected last-observed-daily-close constructor self-test, including PostgreSQL `t` / `f` boolean parsing;
- current fail-closed Stage 4 contract enforcement.

The corrected constructor remains required to reproduce the diagnostic evidence exactly before emitting a candidate:

- direct-USD pairs: 434;
- active USD pair-days: 37,058;
- consecutive-calendar-day corrected responses: 36,505;
- no bridge across an inactive UTC day;
- full formula/timing/duplicate/lineage checks PASS.

This CI result validates only implementation. `CFA-S4-009` remains `UNVERIFIED` and `CFA-S4-010` remains `BLOCKED` until exact local construction and bounded artifact review.