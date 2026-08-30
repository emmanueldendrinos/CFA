# CFA Stage 3 news matching V3 corrective contract — 2026-08-30

Status: **FROZEN_CORRECTIVE_CONTRACT / CODE_CI_PASS / LOCAL_EXECUTION_UNVERIFIED / STAGE3_FREEZE_BLOCKED**

## Authority and preserved upstream state

This contract is a narrow correction to the current CFA Stage 3 V2 candidate. It does not replace or reinterpret the CFA Source of Truth, Stage 1 source reconciliation, Stage 2 identity/alias decisions, the 431-asset news population, the 470-row Stage 3 alias registry, the allowed GDELT surfaces, V2 title matching, the response-independent record grain, or the `(base_asset_id, record_id)` deduplication rule.

The V2 full source scan remains the parent evidence only when its summary and output hashes verify exactly and it records:

- 7,163 source archives;
- 9,183,757 source rows;
- 5 malformed 27-field rows;
- 0 missing critical rows;
- 0 duplicate `(base_asset_id, record_id)` matches;
- alias-registry SHA-256 `11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9`.

## Blocking V2 observation

The deterministic V2 bounded review failed because the default two-letter Kraken symbol `IP` matched the title `North Korean Hackers Use Russian IP Infrastructure`. In that observation, `IP` meant Internet Protocol, `title_crypto_anchor=False`, and `ECON_BITCOIN=True`; V2 therefore admitted an obvious false positive.

V2 remains historical parent evidence and must not be frozen as Stage 3.

## Frozen V3 rule

For a **default Kraken symbol-only alias of length one or two characters**:

1. `ECON_BITCOIN` alone is insufficient to retain the asset/news record match.
2. The record is retained when `TITLE_CRYPTO` evidence is present.
3. The record is also retained when an independently approved non-default alias for the same asset matched the same GDELT record.
4. Otherwise the V2 asset/news record match is removed with reason `SHORT_DEFAULT_REQUIRES_TITLE_CRYPTO`.

All aliases other than default one- or two-character Kraken symbol-only aliases are unchanged by V3.

The correction is implemented as a lineage-preserving post-filter over a hash-verified V2 run. Parent V2 outputs are read-only and are never rewritten.

## Encoding hard gate

V2 reads GDELT fields 0, 1, 3, 4, 8, 12, 14, 23, and 26. Because the parent matcher uses lenient UTF-8 decoding, Stage 3 cannot be frozen until the previously identified raw encoding issue archives are re-audited with strict UTF-8 at all nine Stage 3-used field indexes.

`CFA-S3F-008` passes only when:

- the prior archive-scan evidence contains exactly 7,163 unique archive filenames;
- those filenames are present in the reconciled current Stage 3 source corpus;
- any available prior archive hashes for the issue set still match the current source files;
- exactly the known five malformed 27-field rows are observed in the bounded issue set; and
- strict UTF-8 invalid rows affecting Stage 3-used fields 0, 1, 3, 4, 8, 12, 14, 23, or 26 equal zero.

The five known malformed rows remain excluded under the already frozen source-shape rule; V3 does not reinterpret them.

## Controller correction discovered during local validation

The first exact local V3 finalization attempt exposed a controller-only argument-forwarding defect: `Run-CfaStage3V3Finalization.ps1` built arrays containing textual parameter names and splatted those arrays into child PowerShell scripts. PowerShell array splatting is positional, so the Stage 2 archive-scan path was bound to the integer `MaxDetailRowsPerArchive` parameter in `Diagnose-CfaStage3FieldEncoding.ps1` before the encoding audit could run.

The controller was corrected at executable commit `01ab8970a9cb74d9d62aded6ebc8d51aa94a724f` to use named-parameter hashtable splatting for every child script. Its self-test now creates a mandatory named-parameter probe script and verifies forwarding directly. GitHub Actions run `33314524596` completed successfully against that commit, including PowerShell 7 parsing, Windows PowerShell 5.1 parsing, all pre-existing Stage 3 component regressions, the Stage 3 encoding scanner self-test, the strengthened V3 finalization controller self-test, and fail-closed contract checks.

This controller correction does not alter the V3 semantic matching rule, V2 parent outputs, alias registry, source shape, encoding gate definition, or bounded-review definition. It invalidated the earlier controller test evidence only; run `33314524596` supersedes that evidence.

## Frozen task/gate IDs and current evidence status

| ID | Requirement | Status | Evidence boundary |
|---|---|---|---|
| `CFA-S3F-001` | Re-establish SoT authority and Stage 2 entry gate | PASS | Repository authority and Stage 2 evidence re-established. |
| `CFA-S3F-002` | Preserve Stage 2 population/identity/alias decisions and V2 parent lineage | PASS | V3 contract and implementation are explicitly non-destructive. |
| `CFA-S3F-003` | Preserve corrected 7,163 / 9,183,757 source shape and source reconciliation | PASS | Frozen corrected Stage 3 source reconciliation preserved in implementation constants. |
| `CFA-S3F-004` | Implement the exact V3 short-default-symbol corrective rule | PASS | Windows PowerShell 5.1 component regression self-test passed in GitHub Actions run 33306784526 at code commit `2def7a6693e4c6a51241dbf84e5b30c67749bde9`; unchanged semantic implementation was re-tested successfully in run 33314524596. |
| `CFA-S3F-005` | Verify exact local parent V2 hashes and emit non-destructive V3 outputs/reject lineage | UNVERIFIED | Requires execution against the exact local V2 evidence artifacts. |
| `CFA-S3F-006` | Regression-test IP rejection, OM retention, approved non-default bypass, and unchanged 3+ character symbols | PASS | V3 post-filter regression passed in GitHub Actions runs 33306784526 and 33314524596. |
| `CFA-S3F-007` | Validate deterministic V3 review selection and automatic rule consistency | PASS | V3 bounded-review helper self-test passed in GitHub Actions runs 33306784526 and 33314524596. |
| `CFA-S3F-008` | Strict UTF-8 audit of every Stage 3-used field on the bounded raw issue set | UNVERIFIED | Scanner self-test passed, but exact local raw issue archives have not yet produced a completed V3 encoding audit receipt. |
| `CFA-S3F-009` | Parse and self-test V3 implementation on Windows PowerShell 5.1 and PowerShell 7 | PASS | GitHub Actions run 33314524596 completed successfully at executable commit `01ab8970a9cb74d9d62aded6ebc8d51aa94a724f`; all parse, component, regression, encoding-scanner, strengthened controller, and fail-closed contract checks passed. |
| `CFA-S3F-010` | Freeze Stage 3 only after local V3 execution, encoding PASS, and direct semantic review PASS | BLOCKED | Depends on `CFA-S3F-005`, `CFA-S3F-008`, and `CFA-S3-005`. |
| `CFA-S3-005` | Direct bounded accepted/rejected semantic review | UNVERIFIED | Requires direct inspection of the deterministic V3 review CSV produced from the exact local corpus. |
| `CFA-S3-006` | Freeze news matching | BLOCKED | Stage 3 cannot freeze until all upstream Stage 3 hard gates pass. |

The evidence-only status reconciliation above does not alter executable code. The exact controller executable validated in GitHub Actions run 33314524596 is commit `01ab8970a9cb74d9d62aded6ebc8d51aa94a724f`.

## Required outputs

A valid local V3 finalization candidate must contain:

- `stage3-v3-finalization-candidate.json`;
- a Stage 3 strict UTF-8 audit summary and per-archive/field evidence;
- a `CANDIDATE_V3` `stage3-match-summary.json`;
- V3 `stage3-news-matches.csv` and SHA-256;
- V3 short-symbol reject lineage and SHA-256;
- the preserved parent V2 context-reject hash;
- V3 sample evidence and SHA-256;
- deterministic V3 bounded-review CSV and SHA-256;
- per-asset V3 news counts and SHA-256.

## Freeze condition

`CFA-S3-006` may become PASS only when all mechanical/encoding gates pass on the exact local corpus and every deterministic bounded V3 review row has been directly inspected with no obvious false positive or false negative. Until then the output is a **VALIDATION CANDIDATE**, not a final Stage 3 dataset.