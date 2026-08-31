# CFA Stage 5 candidate-factor contract — source-entry candidate — 2026-08-31

Status: **STAGE5_ACTIVE / STAGE4_ENTRY_PASS / FACTOR_SOURCE_RECONCILIATION_UNVERIFIED / FACTOR_DEFINITIONS_BLOCKED**

## Authority and entry condition

This contract is subordinate to the CFA Source of Truth and authorized CFA evidence. The SoT authorizes definition of candidate market/news factors from verified source data but supplies no factor formula. The reproducible SoT authority snapshot reports that no `DATA-###` identifiers exist in the workbook; therefore no DATA-001/002/003 factor formula is imported or reconstructed.

Stage 4 is frozen on `RET_USD_UTC_DAY_OBS_LOG` with `CFA-S4-015 = PASS`.

`CFA-S5-001 = PASS` — Stage 5 entry gate.

## Frozen predictor/response timing boundary

For response day `d`:

- predictor cutoff: `d 00:00:00+00`;
- response window: `[d 00:00:00+00,d+1 00:00:00+00)`;
- response availability: `d+1 00:00:00+00`.

Every Stage 5 predictor must use only information available strictly before or at the predictor cutoff according to its exact source semantics. Any factor whose source window overlaps the response window is a blocking leakage failure.

## Authorized factor sources

### Market source

Frozen relation: `asrp.q2_market_1m_observations`.

Known required fields from Stage 4 include:

- `source_member_ordinal`;
- `pair_token_opaque`;
- `candle_start_utc`;
- `open_price`;
- `high_price`;
- `low_price`;
- `close_price`;
- `base_volume`;
- `trade_count`;
- source-integrity/lineage fields.

Stage 5 must re-inspect the actual field types and factor-relevant null/value boundaries before any factor formula is frozen.

### News source

Frozen Stage 3 V6 output: `stage3-news-matches.csv` from exact `CANDIDATE_V6`.

Frozen columns produced by the V6 matcher:

- `base_asset_id`;
- `record_id`;
- `gdelt_date_utc`;
- `source_common_name`;
- `document_identifier`;
- `archive_file`;
- `row_ordinal`;
- `matched_aliases`;
- `matched_surfaces`;
- `context_reasons`.

Stage 3 guarantees zero duplicate `(base_asset_id,record_id)` retained matches. The raw GDELT date field was required by the matcher to match exactly 14 decimal digits before any record was eligible.

## Blocking population question

Frozen Stage 4 response population: **434 direct-USD bases**.

Frozen Stage 3 news-matching population: **431 assets**.

It is not yet established which assets are in the set differences. A response asset outside the Stage 3 news-matching population must **not** silently receive a news factor value of zero; outside-population and zero-retained-news are different states.

The first Stage 5 local inspection must therefore produce exact sets for:

- response/direct-USD bases;
- Stage 3 news-population assets;
- intersection;
- response bases outside Stage 3 news population;
- Stage 3 news assets outside the response/direct-USD population.

## Candidate-factor definition boundary

No factor is approved yet.

After source/population reconciliation passes, Stage 5 may define a bounded initial candidate set from source-supported quantities. Candidate definitions must state, for every factor:

- exact factor ID and formula;
- exact source fields/artifacts;
- grain;
- source window/lookback;
- lag relative to predictor cutoff;
- information-availability rule;
- missing-data policy;
- population policy;
- units;
- any intrinsic transform such as natural log or `log1p`;
- model scaling policy (normally none at Stage 5; later preprocessing is separate);
- validation result.

Potential factor families are **not approved definitions** until the source-entry gate passes. They include prior-window market return/range/activity and prior-window retained-news counts/source breadth. No formula is frozen by this paragraph.

## Stage 5 gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S5-001` | Frozen Stage 4 entry (`CFA-S4-015=PASS`) | PASS |
| `CFA-S5-002` | Reconcile 434 response bases with 431 Stage 3 news-population assets | UNVERIFIED |
| `CFA-S5-003` | Verify exact V6 news-match artifact, schema, deduplication, timestamps, and Q2 boundaries | UNVERIFIED |
| `CFA-S5-004` | Re-inspect market factor fields/types/value boundaries and direct-USD coverage | UNVERIFIED |
| `CFA-S5-005` | Measure prior-window availability at frozen predictor cutoffs | BLOCKED |
| `CFA-S5-006` | Define exact initial market factors | BLOCKED |
| `CFA-S5-007` | Define exact initial news-hype factors and outside-population policy | BLOCKED |
| `CFA-S5-008` | Construct candidate factor artifact | BLOCKED |
| `CFA-S5-009` | Freeze Stage 5 candidate-factor definitions | BLOCKED |

## Current completion boundary

Stage 5 is active but factor definitions remain **BLOCKED** pending `CFA-S5-002` through `CFA-S5-005`. Stage 6 data-quality/leakage testing must not begin until exact factor definitions exist.
