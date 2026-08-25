# CFA Stage 1 Validation Status

Date: 2026-08-25

Authority: CFA Source of Truth. This receipt records CFA-era observations from the SoT, exact repository-source reconciliation, direct read-only PostgreSQL inspection, direct Kraken byte reconciliation, and bounded local evidence published through the CFA repository. Prior ASRP implementation or analytical conclusions are not imported as authority.

## Authority and registered reference sources

The current SoT text snapshot is generated reproducibly from `CFA-SoT.xlsx` and is a review surface only; the workbook remains authoritative.

The SoT registers three exact source CSVs:

- `ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv`
- `ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv`
- `ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv`

`docs/evidence/reference-source-reconciliation.md` directly reconciles all three current repository files against the SoT registry. For every file, parsed data rows, parsed columns, exact bytes, and SHA-256 are PASS. The current registered results are:

| Source | Data rows | Columns | Bytes | SHA-256 | Overall |
|---|---:|---:|---:|---|---|
| AF-001 | 1,059 | 16 | 355,619 | `569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f` | PASS |
| AF-002 | 435 | 11 | 308,626 | `ff7e1283b0f543213d9946bbb0828f2b20283e232db00bc379dad4fe9bc2f2c7` | PASS |
| AF-003 | 45 | 6 | 4,621 | `8c75e334be54e888b17a70d7945dc43ff2f2d789126eefaee11b4a6d078f7fc4` | PASS |

This supersedes the earlier CFA-S1-003/004/005 unresolved reference-byte state.

## PostgreSQL and market-source evidence

Direct PostgreSQL inspection established PostgreSQL 18.4 and the relevant `asrp`, `asrp_hype`, and `srp` relations.

Controlled exact-count revalidation established, among other relations:

- `asrp.q2_market_1m_observations`: 14,055,089 rows.
- `asrp.q2_raw_records`: 14,055,089 rows.
- `srp.ohlcvt_1m_2025q2`: 14,055,089 rows.

Direct market coverage verification established:

- Q2 timestamp coverage from 2025-04-01 00:00:00+00 through 2025-06-30 23:59:00+00.
- 1,058 distinct data-bearing member paths / opaque pair tokens.
- zero rows outside the source window.
- zero non-minute-aligned rows.
- zero quality-flagged rows.
- zero duplicate-classification rows.
- raw↔typed bounded reconciliation PASS.
- SRP exact row/time/pair coverage reconciles to the ASRP typed store.

Direct Kraken source reconciliation run `20260825-140324-a472cacf60444c0b88e398367b5fef0b` established:

- 1,059 / 1,059 manifest members PASS.
- zero missing, hash-mismatched, ambiguous, or unverified-shape members.
- local `Kraken_OHLCVT_Q2_2025.zip` exactly matches PostgreSQL-recorded SHA-256 `36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c`.
- no archive extraction, Kraken modification, or PostgreSQL modification occurred during reconciliation.

A Kraken reload is not required.

## Legacy news acquisition: direct rejection evidence

The latest corrected read-only coverage verification is published in `docs/evidence/latest-local-validation.md` from local run `20260825-162516-5cbb56c5d92e481b807116b6789652b0`.

The legacy `asrp_hype` acquisition reports:

- run status `running`, not `completed`.
- NULL completion timestamp.
- 7,283 selected objects under its own protocol.
- only 368 acquisition-object rows.
- 366 non-NULL payload hashes across 366 non-NULL rows: non-NULL payload uniqueness PASS.
- 2 rows with NULL payload hashes: FAIL.
- maximum acquired archive timestamp 2025-06-12 13:15:00+00.
- legacy protocol interval end exclusive 2025-06-14 18:00:00+00.

The corrected coverage gate therefore has 4 PASS, 5 FAIL, and 0 UNVERIFIED checks. The earlier statement that distinct-hash count 366/368 proved duplicate payloads is superseded: direct diagnosis found zero duplicate non-NULL payload-hash groups. The two missing hashes belong to unretrieved network-failed objects.

The deeper read-only diagnosis run `20260825-162517-bc80b1b868854effacb38acbdc18f7dc` established:

- latest recorded event is `object_completed`.
- 366 `object_completed` events with 366 distinct completed object keys.
- 12 `network_failed` events.
- one `network_circuit_breaker_pause` after ten consecutive bounded network failures.
- one historical `failed_integrity_or_parser` event caused by an encoding translation failure.
- a later recorded parser recovery from package version 1.0.6 to 1.0.9 retained 19 completed objects and identified a first incomplete object key.
- two current `network_failed` acquisition-object rows at `20250331143000` and `20250331144500`, each with NULL payload SHA-256 and three exhausted download attempts.
- zero duplicate non-NULL payload-hash groups.
- the direct stop-cause classification remains UNVERIFIED because no terminal failure event explains why processing stopped after the final successful object.

The legacy acquisition is not an acceptable CFA Stage 1 source because it is incomplete, internally contains unresolved network-failed source slots, and its own protocol stops on 2025-06-14 while verified market coverage continues through 2025-06-30.

## CFA-owned replacement news-source contract

The replacement path is derived afresh from current CFA evidence rather than from the legacy factor implementation.

Source product: `GDELT 2.0 native/base GKG fifteen-minute update archives`.

Observed object URL pattern from directly inspected legacy source rows:

`https://storage.googleapis.com/data.gdeltproject.org/gdeltv2/{object_key}.gkg.csv.zip`

CFA Stage 1 Q2 source-verification interval:

- start: 2025-04-01 00:00:00+00.
- end exclusive: 2025-07-01 00:00:00+00.
- grain: 15 minutes.
- nominal slots: 8,736.

This interval deliberately matches the verified Q2 market interval. It does not assume a pre-Q2 factor lookback. If a later approved factor requires pre-Q2 information, the news-source interval must be extended and revalidated before that factor may PASS.

Implementation boundary:

- PostgreSQL database: `cfa`.
- CFA-owned schema: `source_news`.
- raw compressed archives remain under `Documents\CFA-local` and outside Git.
- source contract, slot status, attempts, payload hashes, provider hash evidence when available, run IDs, and run events are stored in PostgreSQL.
- acquisition is resumable and idempotent at the source-slot grain.
- a provider 404 is recorded explicitly as provider-source missingness rather than silently imputed.
- downloaded archives require nonzero payload, recorded SHA-256, structural ZIP validation, Content-Length agreement when provided, and provider MD5 agreement when the provider supplies MD5 metadata.
- final source verification rechecks local existence, size, and SHA-256 for every downloaded archive.

Scripts:

- `scripts/windows/Acquire-CfaGdeltQ2Source.ps1`
- `scripts/windows/Verify-CfaGdeltQ2Source.ps1`
- `scripts/windows/Run-CfaStage1.ps1 -RecoverNewsSource`

The implementation and its self-tests are CI-validated, but the exact local full acquisition/verification is not yet complete. Therefore the replacement source remains a validation candidate and does not yet change CFA-S1-010.

## Stage 1 hard-gate status

| Gate | Status | Evidence / blocker |
|---|---|---|
| CFA-S1-001 Authority/source boundary | PASS | CFA SoT remains authority; derived text snapshot is review-only. |
| CFA-S1-002 Authorized repository reference files | PASS | The three SoT-registered source CSVs are present and exactly reconciled. |
| CFA-S1-003 Reference row-count revalidation | PASS | AF-001 1,059; AF-002 435; AF-003 45, matching SoT. |
| CFA-S1-004 Reference byte-size reconciliation | PASS | AF-001 355,619; AF-002 308,626; AF-003 4,621 bytes, matching SoT. |
| CFA-S1-005 Reference SHA-256 reconciliation | PASS | All three exact current repository hashes match the SoT registry. |
| CFA-S1-006 Original Kraken quarters | PASS | Exact archive hash and all 1,059 manifest members reconcile. |
| CFA-S1-007 PostgreSQL market/news availability | PASS | Direct PostgreSQL discovery/inspection succeeded; availability is distinct from source completeness. |
| CFA-S1-008 Direct market coverage | PASS | 14,055,089 exact Q2 rows with bounded integrity and raw↔typed reconciliation PASS. |
| CFA-S1-009 Advance to identity approval | BLOCKED | CFA-S1-010 remains unresolved. |
| CFA-S1-010 News source acquisition completeness | FAIL | Legacy source is rejected; CFA-owned 8,736-slot Q2 replacement has not yet passed exact local acquisition and file/hash verification. |

## Current decision

All Stage 1 blockers except news-source completeness are resolved.

Do not advance to asset identity approval, news matching, response definition, factor design, leakage testing, model-ready freezing, or PLS until CFA-S1-010 is PASS.

The next authorized execution is the CFA-owned resumable GDELT Q2 acquisition plus exact verification through `Run-CfaStage1.ps1 -RecoverNewsSource`. If that source verification is PASS, CFA-S1-010 and consequently CFA-S1-009 may advance to PASS; otherwise the runner must remain BLOCKED with explicit unresolved source slots or integrity failures.
