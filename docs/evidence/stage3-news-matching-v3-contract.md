# CFA Stage 3 news matching V3 corrective contract — 2026-08-30

Status: **FROZEN_V3_SEMANTIC_RULE / LOCAL_ENCODING_GATE_FAIL / UTF8_ELIGIBILITY_CORRECTION_REQUIRED / STAGE3_FREEZE_BLOCKED**

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
- known malformed 27-field rows: **5**;
- evidence directory: `D:\CFA-bulk\analysis\stage3-news-matching\20260830-134344-v3-finalization-6c24b962\encoding\20260830-134417-9e880050`.

Therefore `CFA-S3F-008` is **FAIL**. This is a source-eligibility failure, not a controller failure. The V2/V3 outputs were produced with lenient decoding and cannot be frozen while those 126 raw rows remain eligible without an explicit, reproducible policy.

The five malformed rows remain excluded under the already frozen source-shape rule. They are not reinterpreted.

## Required UTF-8 eligibility correction

The corrective direction is fail-closed: **do not reinterpret malformed UTF-8 bytes**. Every raw GDELT row with invalid UTF-8 in any Stage 3-used field must be excluded from the Stage 3 news-matching eligible population.

The exclusion identity is raw-lineage based, not text based:

- `archive_file`;
- `row_ordinal` within the archive entry;
- `raw_line_sha256`;
- exact invalid field indexes.

Because V2 match and context-reject outputs preserve `archive_file` and `row_ordinal`, the impact of the 126-row exclusion set can be reconciled exactly against the hash-verified parent outputs without rescanning all 9,183,757 rows.

`scripts/windows/Diagnose-CfaStage3CriticalUtf8Impact.ps1` is the candidate diagnostic for this correction. It is designed to:

1. require the exact reproduced Stage 2 archive-scan SHA-256;
2. scan only the frozen 139 issue archives;
3. require exactly 126 Stage 3-critical UTF-8-invalid rows and exactly 5 malformed rows;
4. emit the complete 126-row exclusion manifest with raw-line hashes;
5. reconcile exact overlap with V2 matches and context rejects using `(archive_file, row_ordinal)`;
6. record any V2 bounded-sample overlap separately;
7. leave the matching/freeze gates blocked until a corrected candidate excludes the manifest rows before applying the frozen V3 short-symbol rule.

No Stage 3 final candidate may silently replace `CFA-S3F-008=FAIL` with PASS. A later corrected-candidate gate must explicitly preserve this failed observation and prove that the failed rows are excluded from eligibility.

## Controller correction discovered during local validation

An earlier local V3 finalization attempt exposed a controller-only argument-forwarding defect: `Run-CfaStage3V3Finalization.ps1` built arrays containing textual parameter names and splatted those arrays into child PowerShell scripts. PowerShell array splatting is positional, so the Stage 2 archive-scan path was bound to the integer `MaxDetailRowsPerArchive` parameter in `Diagnose-CfaStage3FieldEncoding.ps1` before the encoding audit could run.

The controller was corrected at executable commit `01ab8970a9cb74d9d62aded6ebc8d51aa94a724f` to use named-parameter hashtable splatting for every child script. Its self-test now creates a mandatory named-parameter probe script and verifies forwarding directly. GitHub Actions run `33314524596` completed successfully against that commit.

This controller correction did not alter the V3 semantic matching rule, V2 parent outputs, alias registry, source shape, encoding gate definition, or bounded-review definition.

## Frozen task/gate IDs and current evidence status

| ID | Requirement | Status | Evidence boundary |
|---|---|---|---|
| `CFA-S3F-001` | Re-establish SoT authority and Stage 2 entry gate | PASS | Repository authority and Stage 2 evidence re-established. |
| `CFA-S3F-002` | Preserve Stage 2 population/identity/alias decisions and V2 parent lineage | PASS | Correction remains non-destructive and response-independent. |
| `CFA-S3F-003` | Preserve corrected 7,163 / 9,183,757 source shape and source reconciliation | PASS | Reproduced Stage 2 archive scan matches the frozen SHA-256 exactly. |
| `CFA-S3F-004` | Implement the exact V3 short-default-symbol corrective rule | PASS | Windows PowerShell 5.1 regression passed; semantic code unchanged. |
| `CFA-S3F-005` | Verify exact local parent V2 hashes and emit non-destructive V3 outputs/reject lineage | UNVERIFIED | Local finalization stopped at the encoding gate before the V3 post-filter ran. |
| `CFA-S3F-006` | Regression-test IP rejection, OM retention, approved non-default bypass, and unchanged 3+ character symbols | PASS | V3 post-filter regression passed in CI. |
| `CFA-S3F-007` | Validate deterministic V3 review selection and automatic rule consistency | PASS | V3 bounded-review helper self-test passed in CI. |
| `CFA-S3F-008` | Strict UTF-8 audit of every Stage 3-used field on the bounded raw issue set | FAIL | Direct local audit found 126 rows with invalid UTF-8 in matcher-used fields. |
| `CFA-S3F-009` | Parse and self-test V3 implementation on Windows PowerShell 5.1 and PowerShell 7 | PASS | GitHub Actions run `33314524596` passed at executable commit `01ab8970a9cb74d9d62aded6ebc8d51aa94a724f`. |
| `CFA-S3F-010` | Historical V3 freeze gate | BLOCKED | Invalidated by `CFA-S3F-008=FAIL`; V3 cannot freeze. |
| `CFA-S3F-011` | Enumerate the exact Stage 3-critical UTF-8 exclusion manifest at `(archive_file,row_ordinal,raw_line_sha256)` grain | UNVERIFIED | Candidate diagnostic implemented; requires exact local execution. |
| `CFA-S3F-012` | Reconcile the exclusion manifest against exact hash-verified V2 match/reject outputs | UNVERIFIED | Requires exact local execution of the impact diagnostic. |
| `CFA-S3F-013` | Define and apply corrected candidate: exclude all manifest rows before the frozen V3 short-symbol rule | BLOCKED | Depends on `CFA-S3F-011` and `CFA-S3F-012`. |
| `CFA-S3F-014` | Produce and directly inspect deterministic bounded review for corrected candidate | BLOCKED | Depends on `CFA-S3F-013`. |
| `CFA-S3F-015` | Freeze corrected Stage 3 news matching | BLOCKED | Depends on all corrected-candidate gates passing. |
| `CFA-S3-005` | Direct bounded accepted/rejected semantic review | BLOCKED | V3 review is invalid downstream of the encoding failure; must be regenerated for the corrected candidate. |
| `CFA-S3-006` | Freeze news matching | BLOCKED | Stage 3 cannot freeze while any required corrected-candidate gate is unresolved. |

## Current completion boundary

Stage 3 is **not complete**. The only valid next operation is the exact local critical-UTF8 impact diagnostic. No response definition, candidate factor, leakage test, model-ready freeze, or PLS work may begin while `CFA-S3-006` remains BLOCKED.
