# CFA Stage 1 Final Validation Status

Date: 2026-08-25

Authority: CFA Source of Truth (SoT), the three SoT-registered source CSVs, current CFA repository files authorized by the SoT, and source data directly inspected under CFA controls.

This receipt closes Stage 1 only. It does not approve CoinGecko mappings, news aliases, factors, responses, model-ready data, or PLS readiness.

## 1. Authority and registered reference sources

The SoT registers these exact source files:

- `ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv`
- `ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv`
- `ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv`

`docs/evidence/reference-source-reconciliation.md` reconciles current repository bytes and parsed shape against the SoT registry.

| Source | Data rows | Columns | Bytes | SHA-256 | Status |
|---|---:|---:|---:|---|---|
| AF-001 | 1,059 | 16 | 355,619 | `569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f` | PASS |
| AF-002 | 435 | 11 | 308,626 | `ff7e1283b0f543213d9946bbb0828f2b20283e232db00bc379dad4fe9bc2f2c7` | PASS |
| AF-003 | 45 | 6 | 4,621 | `8c75e334be54e888b17a70d7945dc43ff2f2d789126eefaee11b4a6d078f7fc4` | PASS |

## 2. Market source and coverage

Direct PostgreSQL verification established PostgreSQL 18.4 and exact Q2 market coverage.

Key observations:

- `asrp.q2_market_1m_observations`: 14,055,089 exact rows.
- `asrp.q2_raw_records`: 14,055,089 exact rows.
- `srp.ohlcvt_1m_2025q2`: 14,055,089 exact rows.
- verified market interval: 2025-04-01 00:00:00+00 through 2025-06-30 23:59:00+00.
- 1,058 distinct data-bearing member paths / opaque pair tokens.
- zero rows outside the source window.
- zero non-minute-aligned rows.
- zero quality-flagged rows.
- zero duplicate-classification rows.
- bounded raw-to-typed reconciliation PASS.

Direct Kraken reconciliation run `20260825-140324-a472cacf60444c0b88e398367b5fef0b` established:

- 1,059 / 1,059 manifest members PASS.
- zero missing, hash-mismatched, ambiguous, or unverified-shape members.
- local `Kraken_OHLCVT_Q2_2025.zip` exactly matches PostgreSQL-recorded SHA-256 `36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c`.

A Kraken reload is not required.

## 3. Legacy news source rejection

The legacy `asrp_hype` acquisition remains rejected as a CFA Stage 1 source.

Direct corrected evidence established:

- run status `running`, completion timestamp NULL.
- only 368 acquisition-object rows under a 7,283-object legacy selection.
- 366 non-NULL payload hashes across 366 non-NULL rows; non-NULL uniqueness PASS.
- 2 unretrieved network-failed rows with NULL payload SHA-256.
- 12 `network_failed` events.
- one historical parser/encoding failure followed by a recorded parser recovery.
- zero duplicate non-NULL payload-hash groups.
- legacy protocol ends 2025-06-14 18:00:00+00, before verified market coverage ends.

The legacy failure is retained as lineage only and does not govern the replacement source gate.

## 4. CFA-owned GDELT Q2 replacement source

CFA replacement source product:

`GDELT 2.0 native/base GKG fifteen-minute update archives`

CFA source contract:

- contract SHA-256: `11f3d81f61533efd0b1984c8f84da3e68128c05142923f4e7a62a76c8de9002e`.
- interval start: 2025-04-01 00:00:00+00.
- interval end exclusive: 2025-07-01 00:00:00+00.
- cadence: 15 minutes.
- nominal slots: 8,736.
- URL template: `https://storage.googleapis.com/data.gdeltproject.org/gdeltv2/{object_key}.gkg.csv.zip`.
- PostgreSQL database/schema: `cfa.source_news`.
- raw archives remain under `Documents\CFA-local` outside Git.

Acquisition completed with zero unresolved slots. The final CFA source verification run is:

`20260825-204214-6505a68d858b452299abd2423ac1a2be`

The published evidence is in `docs/evidence/latest-local-validation.md`.

### Final source accounting

| Measure | Observed | Status |
|---|---:|---|
| Total source slots | 8,736 | PASS |
| Downloaded slots | 7,163 | PASS |
| Provider-missing slots | 1,573 | PASS |
| Unresolved slots | 0 | PASS |
| Downloaded slots with NULL SHA-256 | 0 | PASS |
| Provider-missing slots not represented by HTTP 404 | 0 | PASS |
| Missing local downloaded files | 0 | PASS |
| Local file size mismatches | 0 | PASS |
| Local file SHA-256 mismatches | 0 | PASS |
| Accounting total | 8,736 / 8,736 | PASS |

The verifier produced **15 PASS, 0 FAIL, 0 UNVERIFIED** checks.

The 1,573 provider-missing slots are explicit provider-source missingness. They are not silently imputed and are preserved at source-slot grain for later missing-data policy decisions.

## 5. Stage 1 hard gates

| Gate | Status | Evidence / decision |
|---|---|---|
| CFA-S1-001 Authority/source boundary | PASS | SoT and authorized/direct evidence only. |
| CFA-S1-002 Authorized repository reference files | PASS | All three SoT-registered CSVs present and exactly reconciled. |
| CFA-S1-003 Reference row-count revalidation | PASS | AF-001 1,059; AF-002 435; AF-003 45. |
| CFA-S1-004 Reference byte-size reconciliation | PASS | Exact bytes match the SoT registry. |
| CFA-S1-005 Reference SHA-256 reconciliation | PASS | Exact hashes match the SoT registry. |
| CFA-S1-006 Original Kraken quarters | PASS | Exact archive hash and all 1,059 manifest members reconcile. |
| CFA-S1-007 PostgreSQL market/news availability | PASS | Direct PostgreSQL inspection and CFA source database execution succeeded. |
| CFA-S1-008 Direct market coverage | PASS | Exact Q2 row/time coverage and bounded integrity checks PASS. |
| CFA-S1-010 News source acquisition completeness | PASS | CFA-owned 8,736-slot Q2 source: 7,163 downloaded, 1,573 provider-missing, 0 unresolved; all local file/hash verification checks PASS. |
| CFA-S1-009 Advance to identity approval | PASS | All required upstream Stage 1 hard gates are PASS. |

## 6. Stage 1 decision

**CFA Stage 1: PASS.**

The project may now proceed to the next required sequence step: asset identity, mapping, and alias review.

This PASS does not approve any CoinGecko candidate mapping or news alias. AF-002 remains candidate data only; AF-003 remains manual seed-reference data only. Identity decisions must be independently reviewed and recorded before news matching is defined.

A later factor that requires a pre-Q2 lookback is not covered by this Q2-only news contract. Such a factor must remain BLOCKED until its required source interval is explicitly extended and revalidated.
