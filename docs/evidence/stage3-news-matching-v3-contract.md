# CFA Stage 3 news matching corrective contract — 2026-08-30

Status: **UTF8_EXCLUSION_FROZEN / V4_REVIEW_FAIL / V5_REVIEW_FAIL / V6_CODE_CI_PASS / LOCAL_V6_EXECUTION_UNVERIFIED / STAGE3_FREEZE_BLOCKED**

## Authority and preserved upstream state

This contract is subordinate to the CFA Source of Truth and preserves the approved upstream source reconciliation, Stage 2 identities/aliases, the 431-asset news population, the 470-row Stage 3 alias registry, response-independent record grain, and `(base_asset_id, record_id)` deduplication.

The exact V2 parent remains:

`D:\CFA-bulk\analysis\stage3-news-matching\20260830-062457-parallel-v2`

It is valid only when its hashes verify and it records 7,163 raw archives, 9,183,757 raw rows, 5 malformed 27-field rows, 0 missing critical rows, 0 duplicate asset/record matches, and alias-registry SHA-256 `11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9`.

The regenerated Stage 2 `archive-scan.csv` reproduced the frozen SHA-256 exactly:

`1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba`.

## Historical V3 short-symbol correction

V2 admitted a false positive for default two-letter symbol `IP` in `North Korean Hackers Use Russian IP Infrastructure` because `ECON_BITCOIN=True` was sufficient despite non-crypto title meaning.

V3 therefore required a default Kraken symbol-only alias of length one or two characters to have `TITLE_CRYPTO` or independently approved non-default same-record support; otherwise the match is rejected with `SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO`.

## Frozen UTF-8 eligibility policy

The strict raw-byte audit of the exact 139 issue archives found 148 rows with any strict UTF-8 failure, including 126 rows with invalid UTF-8 in a Stage 3-used field. All 126 Stage 3-critical occurrences were field 26 zero-based / field 27 one-based (`extras`, page-title source). Five malformed 27-field rows were also observed.

`CFA-S3F-008` remains permanently **FAIL** as the historical observation. Project policy is frozen to exclude the exact 126 affected raw rows, keyed by `archive_file`, `row_ordinal`, `raw_line_sha256`, and invalid field indexes. No corpus-wide re-encoding or semantic repair is performed.

The exact local impact diagnostic proved zero overlap of those 126 rows with V2 matches, V2 context rejects, V2 bounded samples, or ambiguous sample identities. The corrected eligible source population is therefore **9,183,626 rows**.

## V4 execution and semantic review

Exact local V4 finalization root:

`D:\CFA-bulk\analysis\stage3-news-matching\20260830-140246-v4-finalization-5f46d2db`

V4 mechanical results:

- `CFA-S3F-011`: PASS — exact 126-row exclusion manifest;
- `CFA-S3F-012`: PASS — exact V2 impact reconciliation, zero overlap;
- `CFA-S3F-013`: PASS — corrected eligibility candidate;
- retained matches: 22,563;
- matched assets: 283;
- deterministic review rows: 26;
- review CSV SHA-256: `293e1c2a613d115736469a1746014d4bc9b8e5eed48dddec0f61c146c5950095`.

Direct review of all 26 rows failed on three observations, recorded in `docs/evidence/stage3-v4-bounded-sample-review-20260830.md`:

1. `OP` falsely matched inside Bitcoin token `OP_RETURN`.
2. explicit `Arweave (AR)` market headline was falsely rejected.
3. explicit `Story (IP)` price headline was falsely rejected.

Therefore `CFA-S3F-014=FAIL` and historical V4 freeze `CFA-S3F-015=BLOCKED`.

## V5 rule and local execution

V5 froze two narrow corrections:

1. underscore is part of a title token, so `OP` cannot match inside `OP_RETURN`;
2. exact parenthetical ticker `(SYMBOL)` plus market/asset wording is high-specificity evidence, restoring cases such as `Arweave (AR)` and `Story (IP)`.

V5 code passed the complete Stage 3 validation workflow in GitHub Actions run `33316432364`.

Exact local V5 finalization root:

`D:\CFA-bulk\analysis\stage3-news-matching\20260830-142808-v5-finalization-693f81e6`

Local V5 results:

- `CFA-S3F-016`: PASS — underscore-aware short-symbol boundary;
- `CFA-S3F-017`: PASS — parenthetical market-ticker retention;
- `CFA-S3F-018`: PASS — exact local `CANDIDATE_V5`;
- asset/news pairs: **22,585**;
- distinct GDELT records: **18,948**;
- matched assets: **284**;
- V5 summary SHA-256: `4d3749f1bc082a1e9eb5df97eadbdb3c766c3a67d5a0bade702db0665767178c`;
- V5 review CSV SHA-256: `b9a46da36fa567d20caba9bf4a6eb25a0cd2d285c51d42e5d967caf82c74c5a1`;
- per-asset count CSV SHA-256: `69b12c1d4c6926535c498a20b91aa554a562bf74e3c1dddd85264b8efbe70348`.

## V5 direct semantic review — FAIL

All **31** deterministic V5 review rows were directly inspected. Evidence is recorded in `docs/evidence/stage3-v5-bounded-sample-review-20260830.md`.

Thirty rows had no obvious blocking semantic error. One row failed:

- `S3V5R-024`: base asset `IP` was retained from title phrase `IP Exchange`. Direct source inspection showed the article identifies the project as **IP Exchange ($IPX)** and says it is built on the Story blockchain. `IP` in the title was therefore not Story's ticker `IP`; this is an obvious false positive.

The earlier V5 fixes remain valid: `OP_RETURN` is rejected and explicit `Arweave (AR)` / `Story (IP)` market headlines are retained.

Therefore `CFA-S3F-019=FAIL`, historical V5 freeze `CFA-S3F-020=BLOCKED`, `CFA-S3-005=FAIL`, and `CFA-S3-006=BLOCKED`.

## Frozen V6 local-market refinement

V6 is a lineage-preserving post-filter over the exact hash-verified V5 output. It does not change upstream aliases, asset identities, UTF-8 exclusions, non-short-symbol matches, or the V5 parenthetical-ticker rule.

For a V5-retained default Kraken symbol-only alias of length one or two characters, V6 retains the asset/news match only when at least one of these high-specificity conditions holds:

1. an independently approved non-default alias for the same asset matched the same record;
2. the exact short symbol occurs in a structured Stage 3 matching field (`ALLNAMES`, `V2PERSONS`, or `V2ORGANIZATIONS`);
3. the title contains exact parenthetical `(SYMBOL)` plus the frozen market/asset anchor rule;
4. the title contains the standalone short symbol and, within a bounded local title window, a strong market-action signal such as price, rally, surge, gain, rise, jump, drop, fall, up/down, volume, market cap/capitalization, or trading/trade.

Generic words such as `crypto`, `cryptocurrency`, `coin`, `token`, `exchange`, `listing`, or `release` do **not** by themselves satisfy V6 local-market evidence. Thus `IP Exchange` is rejected, while `OM rally` remains retained.

If none of the V6 conditions holds, the match is rejected with `SHORT_DEFAULT_REQUIRES_LOCAL_MARKET_OR_HIGH_SPECIFICITY`.

V6 re-reads only the raw rows supporting V5-retained short-symbol matches using preserved `(archive_file,row_ordinal)` lineage. A full 9.18-million-row rematch is not required.

The V6 implementation consists of:

- `scripts/windows/Apply-CfaStage3NewsMatchingV6.ps1`;
- `scripts/windows/Prepare-CfaStage3V6SampleReview.ps1`;
- `scripts/windows/Run-CfaStage3V6Finalization.ps1`.

Dedicated GitHub Actions run `33318090018` completed **successfully** at executable commit `422e2674dcc0dc2c174dc5a8ce852d2845f3bdb3`. It passed PowerShell 7 parsing, Windows PowerShell 5.1 parsing, preserved V5 regression, the V6 `IP Exchange`/`OM rally` correction self-test, V6 review-helper self-test, V6 controller named-argument test, and fail-closed contract checks.

## Frozen task/gate IDs and current status

| ID | Requirement | Status | Evidence boundary |
|---|---|---|---|
| `CFA-S3F-001` | Re-establish SoT authority and Stage 2 entry gate | PASS | Repository authority and Stage 2 evidence re-established. |
| `CFA-S3F-002` | Preserve Stage 2 population/identity/alias decisions and V2 lineage | PASS | All corrections remain lineage-preserving. |
| `CFA-S3F-003` | Preserve 7,163 / 9,183,757 raw source shape | PASS | Regenerated archive scan matched frozen hash exactly. |
| `CFA-S3F-004` | Historical V3 short-default rule | PASS | Implemented and regression-tested. |
| `CFA-S3F-005` | Verify exact local parent V2 hashes and V3 lineage | PASS | Exact V4/V5 local executions verified parent lineage. |
| `CFA-S3F-006` | Historical V3 IP/OM/non-default regressions | PASS | CI evidence preserved. |
| `CFA-S3F-007` | Historical V3 deterministic review helper | PASS | CI evidence preserved. |
| `CFA-S3F-008` | Historical strict UTF-8 hard gate | FAIL | 126 Stage 3-used-field failures observed. |
| `CFA-S3F-009` | Windows PowerShell 5.1 / PowerShell 7 code validation | PASS | V5 and V6 validation workflows passed. |
| `CFA-S3F-010` | Historical V3 freeze | BLOCKED | Superseded by later corrections. |
| `CFA-S3F-011` | Enumerate exact UTF-8 exclusion manifest | PASS | 126-row manifest produced locally. |
| `CFA-S3F-012` | Reconcile exclusion set against V2 outputs | PASS | Zero match/reject/sample overlap. |
| `CFA-S3F-013` | Apply UTF-8 corrected V4 eligibility | PASS | 9,183,626 eligible rows. |
| `CFA-S3F-014` | Direct V4 semantic review | FAIL | 3 blocking rows among 26. |
| `CFA-S3F-015` | Historical V4 freeze | BLOCKED | V4 review failed. |
| `CFA-S3F-016` | Tight underscore-aware title boundary | PASS | Exact local V5 execution. |
| `CFA-S3F-017` | Parenthetical market-ticker retention | PASS | Exact local V5 execution. |
| `CFA-S3F-018` | Exact local V5 candidate | PASS | 22,585 pairs / 284 assets. |
| `CFA-S3F-019` | Direct V5 semantic review | FAIL | 1 blocking false positive among 31 rows. |
| `CFA-S3F-020` | Historical V5 freeze | BLOCKED | V5 review failed. |
| `CFA-S3F-021` | Implement V6 local-market/high-specificity short-symbol rule | PASS | GitHub Actions run `33318090018`. |
| `CFA-S3F-022` | Produce exact local V6 candidate from hash-verified V5 lineage | UNVERIFIED | Requires local V6 controller execution against exact V5 root. |
| `CFA-S3F-023` | Direct deterministic V6 bounded semantic review | BLOCKED | Depends on exact local V6 candidate. |
| `CFA-S3F-024` | Freeze corrected Stage 3 news matching | BLOCKED | Depends on V6 local candidate and semantic review PASS. |
| `CFA-S3-005` | Stage 3 direct bounded semantic review | FAIL | Latest completed candidate review (V5) failed. |
| `CFA-S3-006` | Freeze news matching | BLOCKED | Stage 3 cannot freeze until V6 hard gates pass. |

## Completion boundary

Stage 3 is **not complete**. The only valid next operation is exact local execution of `Run-CfaStage3V6Finalization.ps1` against the frozen V5 run, followed by direct inspection of every generated V6 review row. Response definition, factor construction, leakage testing, model-ready freeze, and PLS remain downstream until `CFA-S3-006=PASS`.
