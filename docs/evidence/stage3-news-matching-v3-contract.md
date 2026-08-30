# CFA Stage 3 news matching corrective contract — 2026-08-30

Status: **UTF8_EXCLUSION_FROZEN / V4_SEMANTIC_REVIEW_FAIL / V5_SHORT_SYMBOL_REFINEMENT_FROZEN / STAGE3_FREEZE_BLOCKED**

## Authority and preserved upstream state

This contract remains subordinate to the CFA Source of Truth and preserves Stage 1 source reconciliation, Stage 2 identity/alias decisions, the 431-asset news population, the 470-row Stage 3 alias registry, response-independent record grain, and `(base_asset_id, record_id)` deduplication.

The exact V2 parent is valid only when its hashes verify and it records 7,163 archives, 9,183,757 raw rows, 5 malformed 27-field rows, 0 missing critical rows, 0 duplicate asset/record matches, and alias-registry SHA-256 `11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9`.

The regenerated Stage 2 `archive-scan.csv` reproduced the frozen SHA-256 exactly: `1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba`.

## Historical V2/V3 semantic correction

V2 admitted an obvious false positive for default two-letter symbol `IP` in the title `North Korean Hackers Use Russian IP Infrastructure` because `ECON_BITCOIN=True` was sufficient even though the title was non-crypto.

V3 therefore froze this rule for default Kraken symbol-only aliases of length one or two characters:

1. `ECON_BITCOIN` alone is insufficient.
2. retain when `TITLE_CRYPTO` is present;
3. retain when an independently approved non-default alias for the same asset matched the same record;
4. otherwise reject with `SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO`.

All other aliases remain unchanged by that historical V3 rule.

## UTF-8 source-eligibility result and frozen policy

The strict raw-byte audit of the exact 139 issue archives found:

- 148 rows with any strict UTF-8 failure in the issue set;
- 126 rows with invalid UTF-8 in a Stage 3-used field;
- all 126 Stage 3-critical occurrences in field 26 zero-based / field 27 one-based (`extras`, page-title source);
- 5 malformed 27-field rows.

`CFA-S3F-008` is therefore permanently **FAIL** as an observed historical gate.

Project policy is frozen to **exclude the exact 126 affected raw rows from Stage 3 eligibility**, keyed by `archive_file`, `row_ordinal`, `raw_line_sha256`, and invalid field indexes. No corpus-wide re-encoding or semantic repair is performed.

The exact V4 local impact diagnostic proved that those 126 rows have:

- V2 match overlap: **0**;
- V2 context-reject overlap: **0**;
- V2 bounded-sample overlap: **0**;
- ambiguous sample-identity overlap: **0**.

The corrected eligible source population is therefore **9,183,626 rows**. The UTF-8 exclusion does not change the V2/V3 match population because none of the excluded rows entered matches or rejects.

## V4 local execution result

Exact local V4 finalization completed as a validation candidate under:

`D:\CFA-bulk\analysis\stage3-news-matching\20260830-140246-v4-finalization-5f46d2db`

Mechanical results:

- `CFA-S3F-011`: PASS — exact 126-row exclusion manifest produced;
- `CFA-S3F-012`: PASS — exact V2 impact reconciliation produced zero overlap;
- `CFA-S3F-013`: PASS — corrected V4 eligibility candidate produced;
- V3 retained matches: 22,563;
- V4 retained matches: 22,563;
- matched assets: 283 of 431;
- deterministic V4 review rows: 26;
- review CSV SHA-256: `293e1c2a613d115736469a1746014d4bc9b8e5eed48dddec0f61c146c5950095`.

The uploaded review CSV hash was independently verified against the candidate receipt before direct review.

## V4 direct semantic review — FAIL

All 26 deterministic V4 review rows were directly inspected. Evidence is recorded in `docs/evidence/stage3-v4-bounded-sample-review-20260830.md`.

Three blocking errors were found:

1. `S3V4R-022` — **false positive**: default symbol `OP` matched inside Bitcoin technical token `OP_RETURN`. `TITLE_CRYPTO` was present, so the V3 rule incorrectly retained it as Optimism.
2. `S3V4R-025` — **false negative**: explicit market headline `Arweave (AR) ... Market Capitalization ...` was rejected because the title lacked the generic V3 `TITLE_CRYPTO` vocabulary.
3. `S3V4R-026` — **false negative**: explicit price headline `Story (IP) Price Down ...` was rejected for the same reason.

The other 23 review rows had no obvious blocking false positive or false negative.

Therefore the V4 semantic gate fails and V4 cannot freeze Stage 3.

## Frozen V5 short-symbol refinement

The V5 correction is intentionally narrow and leaves all upstream identities, aliases, non-short aliases, UTF-8 eligibility, and V2 lineage unchanged.

For each default Kraken symbol-only alias of length one or two characters:

### 1. Tight title-token boundary

A page-title symbol occurrence is valid only when the symbol is not adjacent to a Unicode letter, digit, or underscore. Underscore is treated as part of the surrounding token.

This makes `OP` in `OP_RETURN` **not** a valid Optimism title occurrence.

### 2. Existing high-context retention

A short symbol remains eligible when an independently approved non-default alias for the same asset matched the same record.

A short symbol also remains eligible under `TITLE_CRYPTO` only when the short symbol itself has a valid tightened title occurrence or an exact structured occurrence in `ALLNAMES`, `V2PERSONS`, or `V2ORGANIZATIONS`.

### 3. Parenthetical market-ticker retention

A short symbol may be retained without generic `TITLE_CRYPTO` when the page title contains the exact parenthetical ticker form `(SYMBOL)` and the title contains a market/asset anchor such as price, market cap/capitalization, volume, trading/trade, exchange, token, coin, crypto, or cryptocurrency.

This is designed to retain high-specificity observations such as `Arweave (AR) ... Market Capitalization ...` and `Story (IP) Price Down ...` while not reopening generic short-symbol matching.

### 4. Otherwise reject

If none of the conditions above is satisfied, reject the short-symbol-supported asset/news match.

V5 must inspect the exact raw page title and structured fields for every affected V2 short-symbol record using preserved `(archive_file,row_ordinal)` lineage. It may scan only those targeted rows/archives; a full 9.18M-row rematch is not required.

## Frozen task/gate IDs and current status

| ID | Requirement | Status | Evidence boundary |
|---|---|---|---|
| `CFA-S3F-001` | Re-establish SoT authority and Stage 2 entry gate | PASS | Repository authority and Stage 2 evidence re-established. |
| `CFA-S3F-002` | Preserve Stage 2 population/identity/alias decisions and V2 lineage | PASS | All corrections remain lineage-preserving. |
| `CFA-S3F-003` | Preserve corrected 7,163 / 9,183,757 raw source shape | PASS | Reproduced Stage 2 scan matched frozen hash exactly. |
| `CFA-S3F-004` | Historical V3 short-default-symbol rule | PASS | Implemented and regression-tested; later semantic review showed it is insufficient, not incorrectly implemented. |
| `CFA-S3F-005` | Verify exact local parent V2 hashes and V3 lineage | PASS | Exact local V4 controller successfully executed the hash-verified V3 post-filter. |
| `CFA-S3F-006` | V3 IP/OM/non-default regression tests | PASS | CI regression evidence preserved. |
| `CFA-S3F-007` | V3 deterministic review helper | PASS | CI evidence preserved. |
| `CFA-S3F-008` | Historical strict UTF-8 hard gate | FAIL | 126 Stage 3-used-field failures observed. |
| `CFA-S3F-009` | PowerShell 5.1 / 7 implementation validation | PASS | V4 workflow run `33315496183` passed. |
| `CFA-S3F-010` | Historical V3 freeze gate | BLOCKED | Superseded by downstream corrections. |
| `CFA-S3F-011` | Enumerate exact UTF-8 exclusion manifest | PASS | Exact local V4 run produced 126-row manifest. |
| `CFA-S3F-012` | Reconcile exclusion set against exact V2 outputs | PASS | Zero match/reject/sample overlap. |
| `CFA-S3F-013` | Apply UTF-8 corrected V4 eligibility candidate | PASS | Local V4 candidate produced 9,183,626 eligible rows and 22,563 matches. |
| `CFA-S3F-014` | Direct deterministic V4 semantic review | FAIL | 3 blocking rows among 26 reviewed. |
| `CFA-S3F-015` | Historical V4 freeze gate | BLOCKED | V4 semantic review failed. |
| `CFA-S3F-016` | Implement tightened short-symbol title token boundary including underscore | UNVERIFIED | V5 implementation required. |
| `CFA-S3F-017` | Implement parenthetical market-ticker retention and exact short-symbol evidence rule | UNVERIFIED | V5 implementation required. |
| `CFA-S3F-018` | Produce exact local V5 candidate from V2 lineage plus frozen UTF-8 exclusions | BLOCKED | Depends on `CFA-S3F-016` and `CFA-S3F-017`. |
| `CFA-S3F-019` | Direct deterministic V5 bounded semantic review | BLOCKED | Depends on exact local V5 candidate. |
| `CFA-S3F-020` | Freeze corrected Stage 3 news matching | BLOCKED | Depends on all V5 gates passing. |
| `CFA-S3-005` | Stage 3 direct bounded semantic review | FAIL | Latest completed candidate review (V4) failed; may be resolved only by a corrected V5 review. |
| `CFA-S3-006` | Freeze news matching | BLOCKED | Stage 3 cannot freeze while V5 requirements remain unresolved. |

## Completion boundary

Stage 3 remains **BLOCKED**. The next valid operation is implementation and exact local execution of the frozen V5 short-symbol refinement. Response definition, factor construction, leakage testing, model-ready freeze, and PLS remain downstream and must not begin until `CFA-S3-006` passes.
