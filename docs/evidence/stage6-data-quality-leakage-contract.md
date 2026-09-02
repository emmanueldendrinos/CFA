# CFA Stage 6 data-quality and leakage contract — frozen — 2026-09-02

Status: **STAGE6_FROZEN / STAGE5_ENTRY_PASS / STRUCTURAL_DQ_PASS / MISSINGNESS_DQ_PASS / NUMERIC_DQ_PASS / LEAKAGE_PASS / CFA-S6-009_PASS**

## Authority and frozen entry

This contract is subordinate to the CFA Source of Truth and the frozen Stage 5 factor contract. Stage 6 does not redefine asset identities, news matching, responses, factor formulas, factor windows, or the information-availability policy.

Frozen Stage 4 response artifact:

- response ID: `RET_USD_UTC_DAY_OBS_LOG`;
- rows / bases / days: **37,058 / 434 / 91**;
- SHA-256: `8e0cc38607be227339c71cb5daecbbb48af1e05c064472a019f0ffe9be11a004`.

Frozen Stage 5 factor artifact:

- grain: `(base_asset_id,response_day_utc)`;
- rows / bases / days: **37,058 / 434 / 91**;
- factor CSV SHA-256: `c35bd125b7ce3036009a2e75f240bc2cd81168dcec3847dd1d0863cc00bc902b`;
- factors: exactly the seven identifiers frozen by Stage 5;
- `CFA-S5-008 = PASS`;
- `CFA-S5-014 = PASS`;
- `CFA-S5-009 = PASS`.

Stage 6 is valid only for these exact hashes. A hash mismatch is blocking.

## Scope

Stage 6 tests data quality and leakage. It does not choose model preprocessing, training/test splits, benchmarks, or PLS hyperparameters; those are downstream Stage 7/8 concerns.

Hard failures are limited to violated frozen contracts, malformed/non-finite data, invalid timing, duplicate/grain defects, impossible domains, inconsistent missingness, or unreconciled lineage. Descriptive extremeness alone is not a failure without an upstream contract boundary.

## Structural tests — PASS

`CFA-S6-001 = PASS` — frozen-entry reconciliation verified the exact Stage 4 response SHA-256, Stage 5 validation identity, frozen Stage 5 factor SHA-256, exact **37,058 / 434 / 91** cardinalities, and frozen seven-factor identity.

`CFA-S6-002 = PASS` — grain/schema/encoding/cardinality validation verified one response and one factor row per `(base_asset_id,response_day_utc)`, exact key-set equality, deterministic factor ordering, required material columns, valid day/cutoff serialization, valid material booleans/numerics, and no replacement-character corruption in material fields.

## Missingness tests — PASS

`CFA-S6-003 = PASS` — missingness semantics and exact frozen partitions reconcile.

Market policy:

- `market_missing_reason='NONE'` requires all four market factors and required witness fields non-null;
- `market_missing_reason='NO_PRIOR_ACTIVE_MARKET_DAY'` requires all four market factors and market witness/value fields null;
- no other market missingness reason is permitted.

News policy:

- `news_*_missing_reason='NONE'` requires numerical factor values and complete source windows;
- `SOURCE_WINDOW_INCOMPLETE` requires numerical news values null and completeness false;
- `OUTSIDE_NEWS_POPULATION` requires numerical news values null;
- complete in-population no-news rows remain valid zero, never null.

Frozen partitions:

- market: **36,505 available / 553 missing**;
- news 24h: **27,267 available / 9,518 source-incomplete / 273 outside-population**;
- news 6h: **28,849 available / 7,936 source-incomplete / 273 outside-population**.

## Numeric/domain tests — PASS

`CFA-S6-004 = PASS` — all defined responses/factors are finite and satisfy the frozen domains:

- market log range `>= 0`;
- market observation count integer `>= 1`;
- market observation span integer in `[0,1439]`;
- news counts integer `>= 0`;
- distinct 24h source count cannot exceed the 24h match count;
- when both are defined, the 6h match count cannot exceed the 24h match count.

Descriptive min/max/unique-count diagnostics were emitted separately and are not treated as arbitrary hard thresholds.

## Timing and leakage tests — PASS

`CFA-S6-005 = PASS` — response/cutoff ordering verified predictor cutoff exactly at `response_day_utc 00:00:00Z`, response-window start at cutoff, and response availability after the response window under the frozen Stage 4 contract.

`CFA-S6-006 = PASS` — market leakage validation verified exact prior-day windows `[d-1 day,d)`, first/last/high/low witnesses strictly before cutoff and within the lookback, first `<=` last, frozen formulas reconcile to preserved witnesses, and structurally missing rows contain no substituted prior-day witness.

`CFA-S6-007 = PASS` — news leakage validation verified the frozen 15-minute availability lag, exact 24h/6h availability windows, equivalent batch windows ending at `d-15m`, and null enforcement for source-incomplete/outside-population rows. No same-batch or post-cutoff news use was observed.

## Cross-field and failure-path tests — PASS

`CFA-S6-008 = PASS` — pair/source-member lineage reconciles between responses and factors; material witness SHA-256 strings are valid when present; physical record numbers are positive integers when present; and fail-closed self-tests cover altered hashes, duplicate keys, invalid missingness, non-finite numerics, and cutoff violations.

## Exact frozen Stage 6 artifacts

Direct local validation root:

`C:\Users\Emmanuel\Documents\CFA-local\stage6-data-quality\20260902-080054-d46d9306cf4240ecb9a07f5f0a1d15eb`

Validation receipt:

- file: `stage6-dq-leakage-validation.json`;
- SHA-256: `5c8fd64d367af847ea1efa25e34cddca05239186282c6d97a4ca70de104a3089`.

Reject artifact:

- file: `stage6-dq-leakage-rejects.csv`;
- SHA-256: `501d085b1edc7d5c7eac425b190e5ee3a503ec66ee2e2876ad3b42c9e56fe07b`;
- verified header-only, consistent with **0 blocking violations**.

Descriptive diagnostics:

- file: `stage6-dq-descriptive-diagnostics.csv`;
- SHA-256: `f3c06e7414c80cf07f5d9186961019d737da6a2980b8e18ae0e535b1a978849e`;
- verified expected response plus seven-factor diagnostic variable set.

Freeze candidate:

- file: `stage6-freeze-candidate.json`;
- SHA-256: `cce6e7772beb385880390c943e04cc4e987bbaa12b87cdf049d81e9223aa83a2`.

Full local evidence is recorded in:

`docs/evidence/stage6-data-quality-leakage-local-20260902.md`

Final freeze evidence is recorded in:

`docs/evidence/stage6-data-quality-leakage-freeze-20260902.md`

## Stage 6 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S6-001` | Reconcile exact frozen Stage 4/5 entry hashes and cardinalities | PASS |
| `CFA-S6-002` | Verify grain/schema/encoding/key cardinality | PASS |
| `CFA-S6-003` | Verify missingness semantics and partitions | PASS |
| `CFA-S6-004` | Verify finite values and numeric domains; emit descriptive diagnostics | PASS |
| `CFA-S6-005` | Verify response/cutoff ordering | PASS |
| `CFA-S6-006` | Verify market timing/formulas/no leakage | PASS |
| `CFA-S6-007` | Verify news timing/null rules/no leakage | PASS |
| `CFA-S6-008` | Verify cross-field lineage and failure paths | PASS |
| `CFA-S6-009` | Freeze Stage 6 DQ/leakage validation result | PASS |

## Completion boundary

**Stage 6 is complete and frozen on the exact artifacts and hashes above.**

The required sequence may now advance to Stage 7: freeze the model-ready dataset and validation design. Stage 7 must explicitly freeze the retained predictor/response population, time split, preprocessing, leakage controls, and benchmark plan before Stage 8 PLS programming may begin.
