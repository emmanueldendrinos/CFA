# CFA Stage 3 news matching frozen contract — 2026-08-30

Status: **STAGE3_FROZEN / CANDIDATE_V6_APPROVED / CFA-S3-006_PASS**

## Authority

This contract is subordinate to the CFA Source of Truth. It preserves the approved Stage 1 source reconciliation, Stage 2 asset identities and aliases, the 431-asset Stage 3 news population, the 470-row Stage 3 alias registry, response-independent record grain, and `(base_asset_id, record_id)` deduplication.

No response, factor, leakage, model-ready, or PLS decision is introduced here.

## Frozen source and lineage

Exact V2 parent:

`D:\CFA-bulk\analysis\stage3-news-matching\20260830-062457-parallel-v2`

Frozen raw source shape:

- archives: **7,163**;
- raw rows: **9,183,757**;
- malformed 27-field rows: **5**;
- missing critical rows: **0**;
- duplicate `(base_asset_id, record_id)` matches: **0**;
- alias-registry SHA-256: `11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9`.

Regenerated Stage 2 archive scan SHA-256:

`1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba`

## Frozen UTF-8 eligibility policy

The strict raw-byte audit found 126 rows with invalid UTF-8 in a Stage 3-used field. All 126 Stage 3-critical occurrences were in field 26 zero-based / field 27 one-based (`extras`, page-title source).

`CFA-S3F-008` remains historical **FAIL**. Project policy is frozen to exclude the exact 126 affected raw rows by `archive_file`, `row_ordinal`, `raw_line_sha256`, and invalid field indexes. No corpus-wide re-encoding or semantic repair is performed.

The exact impact diagnostic proved zero overlap of the exclusion set with V2 matches, context rejects, bounded samples, or ambiguous sample identities. Corrected eligible raw rows: **9,183,626**.

## Historical semantic corrections

### V3

V2 admitted `IP` in `North Korean Hackers Use Russian IP Infrastructure`. V3 therefore required stronger evidence for default Kraken symbol-only aliases of length one or two characters.

### V4

Exact local V4 candidate retained 22,563 asset/news pairs. Direct review failed on three rows:

- `OP` inside `OP_RETURN` was a false positive;
- explicit `Arweave (AR)` market headline was falsely rejected;
- explicit `Story (IP)` price headline was falsely rejected.

`CFA-S3F-014 = FAIL`; historical V4 freeze remains `BLOCKED`.

### V5

V5 made underscore part of a title token and added exact parenthetical ticker + market wording as high-specificity evidence. Exact local V5 candidate contained 22,585 pairs across 284 matched assets.

Direct review of 31 rows found one remaining false positive: `IP Exchange` was retained as Story ticker `IP`, while direct source inspection identified the project as `IP Exchange ($IPX)` built on Story.

`CFA-S3F-019 = FAIL`; historical V5 freeze remains `BLOCKED`.

## Frozen V6 matching rule

V6 is a lineage-preserving post-filter over the exact hash-verified V5 output. It does not change upstream aliases, identities, UTF-8 exclusions, non-short-symbol matches, or the V5 parenthetical-ticker rule.

For a V5-retained default Kraken symbol-only alias of length one or two characters, V6 retains the asset/news match only when at least one of these conditions holds:

1. independently approved non-default same-record alias support;
2. exact short-symbol occurrence in `ALLNAMES`, `V2PERSONS`, or `V2ORGANIZATIONS`;
3. exact parenthetical `(SYMBOL)` plus the frozen market/asset anchor rule;
4. standalone title symbol with bounded local strong market-action evidence such as price, rally, surge, gain, rise, jump, drop, fall, up/down, volume, market cap/capitalization, trading, or trade.

Generic `crypto`, `cryptocurrency`, `coin`, `token`, `exchange`, `listing`, or `release` wording alone does not satisfy V6 local-market evidence.

If none applies, reject with `SHORT_DEFAULT_REQUIRES_LOCAL_MARKET_OR_HIGH_SPECIFICITY`.

This rejects `IP Exchange` while retaining `OM rally`, explicit `Arweave (AR)`, and explicit `Story (IP)` market headlines.

## V6 implementation validation

Dedicated GitHub Actions run `33318090018` completed **successfully** at executable commit:

`422e2674dcc0dc2c174dc5a8ce852d2845f3bdb3`

It passed:

- PowerShell 7 parsing;
- Windows PowerShell 5.1 parsing;
- preserved V5 regression;
- V6 `IP Exchange` rejection / `OM rally` retention self-test;
- V6 review-helper self-test;
- V6 controller named-argument self-test;
- fail-closed V6 contract checks.

## Exact local V6 candidate

Finalization root:

`D:\CFA-bulk\analysis\stage3-news-matching\20260830-151943-v6-finalization-894287a3`

Results:

- parent V5 matches: **22,585**;
- V6 newly rejected short-symbol matches: **525**;
- V6 retained asset/news pairs: **22,060**;
- distinct GDELT records: **18,503**;
- matched assets: **282 of 431**;
- V6 summary SHA-256: `c1741dc7ae8de4272fa3c55f59c9efb035e4e72b0c330939b1e12caa6742d20c`;
- V6 review summary SHA-256: `017751c3e416cd848f17b47ecd6f30dd69b825fa4aec83f1f3ed2fb7aedef7cf`;
- V6 review CSV SHA-256: `672700250f8848320b9aa201a45afb09e8396f305dc0c784b75d13c3cc28339a`;
- V6 per-asset count CSV SHA-256: `860e2d080e813677c07535ffb0b96ae069559ae722677cf2dd9129e0655d2eb3`.

## Direct V6 semantic review — PASS

All **31** deterministic V6 review rows were directly inspected after verifying the uploaded review CSV hash against the candidate receipt.

Result: **PASS**. No obvious false positive or false negative remains.

Mandatory correction/regression cases all pass:

- `IP Exchange`: rejected;
- `OM rally`: retained;
- `OP_RETURN`: rejected;
- Internet Protocol/infrastructure `IP`: rejected;
- `Arweave (AR)`: retained;
- `Story (IP)`: retained.

Full row-level evidence is recorded in:

`docs/evidence/stage3-v6-bounded-sample-review-20260830.md`

## Final gate table

| ID | Requirement | Status |
|---|---|---|
| `CFA-S3F-001` | Re-establish SoT authority and Stage 2 entry gate | PASS |
| `CFA-S3F-002` | Preserve Stage 2 population/identity/alias decisions and V2 lineage | PASS |
| `CFA-S3F-003` | Preserve 7,163 / 9,183,757 raw source shape | PASS |
| `CFA-S3F-004` | Historical V3 short-default rule implementation | PASS |
| `CFA-S3F-005` | Verify exact local parent V2 hashes and lineage | PASS |
| `CFA-S3F-006` | Historical V3 IP/OM/non-default regressions | PASS |
| `CFA-S3F-007` | Historical V3 deterministic review helper | PASS |
| `CFA-S3F-008` | Historical strict UTF-8 hard gate observation | FAIL |
| `CFA-S3F-009` | Windows PowerShell 5.1 / PowerShell 7 code validation | PASS |
| `CFA-S3F-010` | Historical V3 freeze | BLOCKED |
| `CFA-S3F-011` | Enumerate exact UTF-8 exclusion manifest | PASS |
| `CFA-S3F-012` | Reconcile UTF-8 exclusions against V2 | PASS |
| `CFA-S3F-013` | Apply corrected V4 UTF-8 eligibility | PASS |
| `CFA-S3F-014` | Historical V4 direct semantic review | FAIL |
| `CFA-S3F-015` | Historical V4 freeze | BLOCKED |
| `CFA-S3F-016` | Tight underscore-aware title boundary | PASS |
| `CFA-S3F-017` | Parenthetical market-ticker retention | PASS |
| `CFA-S3F-018` | Exact local V5 candidate | PASS |
| `CFA-S3F-019` | Historical V5 direct semantic review | FAIL |
| `CFA-S3F-020` | Historical V5 freeze | BLOCKED |
| `CFA-S3F-021` | Implement V6 local-market/high-specificity rule | PASS |
| `CFA-S3F-022` | Exact local V6 candidate | PASS |
| `CFA-S3F-023` | Direct deterministic V6 semantic review | PASS |
| `CFA-S3F-024` | Freeze corrected Stage 3 news matching | PASS |
| `CFA-S3-005` | Current Stage 3 direct bounded semantic review | PASS |
| `CFA-S3-006` | Freeze news matching | PASS |

Historical FAIL/BLOCKED statuses are preserved as observations of superseded candidate versions; they are not relabeled. Each is resolved by an explicit downstream corrective rule and new validation gate.

## Stage completion boundary

**Stage 3 is complete and frozen on the exact `CANDIDATE_V6` artifacts above.**

The required project sequence may now advance to Stage 4: define and freeze responses. No Stage 4 response definition has yet been approved by this Stage 3 contract.
