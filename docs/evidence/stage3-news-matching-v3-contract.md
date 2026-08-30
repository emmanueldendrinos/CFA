# CFA Stage 3 news matching corrective contract — 2026-08-30

Status: **FROZEN_V3_SEMANTIC_RULE / UTF8_EXCLUSION_POLICY_APPROVED / V4_CODE_CI_PASS / LOCAL_V4_EXECUTION_UNVERIFIED / STAGE3_FREEZE_BLOCKED**

## Authority and preserved upstream state

This contract is a narrow correction to the CFA Stage 3 V2 candidate. It does not replace or reinterpret the CFA Source of Truth, Stage 1 source reconciliation, Stage 2 identity/alias decisions, the 431-asset news population, the 470-row Stage 3 alias registry, the allowed GDELT surfaces, V2 title matching, the response-independent record grain, or the `(base_asset_id, record_id)` deduplication rule.

The V2 full source scan remains parent evidence only when its summary and output hashes verify exactly and it records:

- 7,163 source archives;
- 9,183,757 source rows;
- 5 malformed 27-field rows;
- 0 missing critical rows;
- 0 duplicate `(base_asset_id, record_id)` matches;
- alias-registry SHA-256 `11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9`.

The previously missing Stage 2 `archive-scan.csv` was regenerated from `D:\CFA-bulk\source\gdelt-gkg-q2-2025` and reproduced the frozen SHA-256 exactly: `1760a371e6ff43e5a1c3da0d2d72df99e8ca02efe1830e1dd2d5404e04e2d5ba`. The reproduced scan has 7,163 unique archives, 135 UTF-8-failure archives, 5 malformed rows, 0 entry failures, and 139 bounded issue archives.

## Blocking V2 semantic observation

The deterministic V2 bounded review failed because the default two-letter Kraken symbol `IP` matched the title `North Korean Hackers Use Russian IP Infrastructure`. In that observation, `IP` meant Internet Protocol, `title_crypto_anchor=False`, and `ECON_BITCOIN=True`; V2 therefore admitted an obvious false positive.

V2 remains historical parent evidence and must not be frozen as Stage 3.

## Frozen V3 short-symbol rule

For a **default Kraken symbol-only alias of length one or two characters**:

1. `ECON_BITCOIN` alone is insufficient to retain the asset/news record match.
2. The record is retained when `TITLE_CRYPTO` evidence is present.
3. The record is also retained when an independently approved non-default alias for the same asset matched the same GDELT record.
4. Otherwise the V2 asset/news record match is removed with reason `SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO`.

All aliases other than default one- or two-character Kraken symbol-only aliases are unchanged by this rule.

The short-symbol correction is lineage-preserving over a hash-verified V2 run. Parent V2 outputs are read-only and are never rewritten.

## Encoding hard-gate result

V2 reads GDELT fields 0, 1, 3, 4, 8, 12, 14, 23, and 26 with lenient UTF-8 decoding. The strict raw-byte audit of the exact 139-archive issue set completed locally against the reproduced Stage 2 scan and current D-drive corpus.

Observed audit result:

- issue archives scanned: **139**;
- strict UTF-8 invalid rows in issue set: **148**;
- rows with invalid UTF-8 in one or more Stage 3-used fields: **126**;
- all 126 Stage 3-critical occurrences are in field 26 zero-based / field 27 one-based (`extras`, the page-title source); 
- non-Stage-3 fields 19 and 21 zero-based also contain 7 and 15 invalid occurrences respectively;
- known malformed 27-field rows: **5**;
- evidence directory: `D:\CFA-bulk\analysis\stage3-news-matching\20260830-134344-v3-finalization-6c24b962\encoding\20260830-134417-9e880050`.

Therefore `CFA-S3F-008` is **FAIL**. This failed observation is preserved permanently in lineage and is not relabeled PASS.

## Approved UTF-8 eligibility policy

Project policy is now frozen as follows: **exclude every raw GDELT row with invalid UTF-8 in a Stage 3-used field from the Stage 3 news-matching eligible population. Do not spend further project effort re-encoding or semantically repairing those rows.**

The exclusion is deliberately small and lineage-preserving. It removes only the exact 126 raw rows identified by the strict audit, subject to exact local reconciliation of any overlap with the five already-excluded malformed rows. No whole archive and no wider corpus is re-encoded or discarded.

The exclusion identity is raw-lineage based, not text based:

- `archive_file`;
- `row_ordinal` within the archive entry;
- `raw_line_sha256`;
- exact invalid field indexes.

Because V2 match and context-reject outputs preserve `archive_file` and `row_ordinal`, the impact of the exclusion set can be reconciled exactly against the hash-verified parent outputs without rescanning all 9,183,757 rows.

## Corrected V4 pipeline

The corrected V4 candidate performs, in order:

1. `Diagnose-CfaStage3CriticalUtf8Impact.ps1`: enumerate the exact critical-UTF8 exclusion manifest and reconcile it against the hash-verified V2 outputs.
2. `Apply-CfaStage3NewsMatchingV3.ps1`: apply the frozen short-default-symbol semantic correction to the verified V2 parent.
3. `Apply-CfaStage3NewsMatchingV4.ps1`: exclude every manifest row from V3 matches, V3 short-symbol rejects, V2 context rejects, and sample lineage, and freeze the corrected eligible-row count from the exact manifest/malformed-row overlap.
4. `Prepare-CfaStage3V4SampleReview.ps1`: produce a new deterministic bounded semantic-review set from the corrected candidate.
5. `Summarize-CfaStage3NewsByAsset.ps1`: produce per-asset counts from the corrected candidate.

`Run-CfaStage3V4Finalization.ps1` orchestrates the complete pipeline and emits `stage3-v4-finalization-candidate.json`.

The complete V4 implementation, including PowerShell 7 parsing, Windows PowerShell 5.1 parsing, the critical-UTF8 impact diagnostic, V4 eligibility correction, V4 bounded-review helper, V4 controller, all preserved V1/V2/V3 regressions, and fail-closed contract checks, passed GitHub Actions run `33315496183` at executable commit `7fea6d5cc6c35e6674e26be39ef75a74d27ccc4a`.

## Frozen task/gate IDs and current evidence status

| ID | Requirement | Status | Evidence boundary |
|---|---|---|---|
| `CFA-S3F-001` | Re-establish SoT authority and Stage 2 entry gate | PASS | Repository authority and Stage 2 evidence re-established. |
| `CFA-S3F-002` | Preserve Stage 2 population/identity/alias decisions and V2 parent lineage | PASS | Correction remains non-destructive and response-independent. |
| `CFA-S3F-003` | Preserve corrected 7,163 / 9,183,757 source shape and source reconciliation | PASS | Reproduced Stage 2 archive scan matches the frozen SHA-256 exactly. |
| `CFA-S3F-004` | Implement the exact V3 short-default-symbol corrective rule | PASS | Windows PowerShell 5.1 regression passed; semantic rule frozen. |
| `CFA-S3F-005` | Verify exact local parent V2 hashes and emit non-destructive V3 outputs/reject lineage | UNVERIFIED | Will be resolved by exact local V4 controller execution. |
| `CFA-S3F-006` | Regression-test IP rejection, OM retention, approved non-default bypass, and unchanged 3+ character symbols | PASS | V3 post-filter regression passed in CI. |
| `CFA-S3F-007` | Validate deterministic V3 review selection and automatic rule consistency | PASS | V3 bounded-review helper self-test passed in CI. |
| `CFA-S3F-008` | Strict UTF-8 audit of every Stage 3-used field on the bounded raw issue set | FAIL | Direct local audit found 126 rows with invalid UTF-8 in matcher-used field 26. |
| `CFA-S3F-009` | Parse and self-test implementation on Windows PowerShell 5.1 and PowerShell 7 | PASS | V4 workflow run `33315496183` passed at executable commit `7fea6d5cc6c35e6674e26be39ef75a74d27ccc4a`. |
| `CFA-S3F-010` | Historical V3 freeze gate | BLOCKED | Invalidated by `CFA-S3F-008=FAIL`; V3 cannot freeze. |
| `CFA-S3F-011` | Enumerate exact Stage 3-critical UTF-8 exclusion manifest at `(archive_file,row_ordinal,raw_line_sha256)` grain | UNVERIFIED | Code CI PASS; requires exact local execution. |
| `CFA-S3F-012` | Reconcile exclusion manifest against exact hash-verified V2 match/reject outputs | UNVERIFIED | Code CI PASS; requires exact local execution. |
| `CFA-S3F-013` | Apply corrected candidate: exclude all manifest rows and preserve frozen V3 short-symbol rule | UNVERIFIED | Code CI PASS; requires exact local execution. |
| `CFA-S3F-014` | Produce and directly inspect deterministic bounded review for corrected candidate | BLOCKED | Review preparation requires exact local V4 candidate; direct inspection follows. |
| `CFA-S3F-015` | Freeze corrected Stage 3 news matching | BLOCKED | Depends on all corrected-candidate gates and direct semantic review passing. |
| `CFA-S3-005` | Direct bounded accepted/rejected semantic review | BLOCKED | Must be regenerated and directly reviewed on corrected V4 candidate. |
| `CFA-S3-006` | Freeze news matching | BLOCKED | Stage 3 cannot freeze while any required corrected-candidate gate is unresolved. |

## Required V4 outputs

A valid local corrected candidate must contain:

- `stage3-v4-finalization-candidate.json`;
- critical-UTF8 impact summary and exact exclusion manifest with hashes;
- hash-verified `CANDIDATE_V3` semantic-correction outputs;
- `CANDIDATE_V4` `stage3-match-summary.json`;
- corrected V4 match, reject, sample, and UTF-8 exclusion lineage with SHA-256 values;
- deterministic V4 bounded-review CSV and SHA-256;
- per-asset V4 news counts and SHA-256.

## Current completion boundary

Stage 3 is **not complete**. The next valid operation is the exact local V4 finalization controller. If its mechanical gates pass, the only remaining Stage 3 operation is direct inspection of every deterministic V4 bounded-review row. No response definition, candidate factor, leakage test, model-ready freeze, or PLS work may begin while `CFA-S3-006` remains BLOCKED.
