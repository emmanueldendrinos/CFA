# CFA Stage 3 Source Observation Reconciliation — 2026-08-30

Status: SOURCE_PASS / RUN_ADJUDICATION_PENDING_LOCAL / SAMPLE_REVIEW_UNVERIFIED

## Directly inspected execution evidence

The D-drive Stage 3 scan completed against:

`D:\CFA-bulk\source\gdelt-gkg-q2-2025`

Run directory:

`D:\CFA-bulk\analysis\stage3-news-matching\20260829-200729-D-drive-revalidation`

The generated `stage3-match-summary.json` records:

- archive files: 7,163
- rows scanned: 9,183,757
- malformed 27-field rows: 5
- missing critical rows: 0
- malformed entity blocks: 0
- news assets: 431
- alias rows: 470
- alias candidates: 3,353,454
- accepted alias hits: 53,124
- rejected context alias hits: 3,300,330
- unique `(base_asset_id, record_id)` matches: 50,802
- matched assets: 333
- duplicate `(base_asset_id, record_id)` matches: 0
- matches SHA-256: `e617c7a057d3e6a5ec1682b8afc387ee8daa3c35cc4222da79661c964902eb98`
- rejects SHA-256: `39c8fd60e26b9d516d6d75de9da7bd59b195f82ef2772a8e0f8523fda5e9a41a`
- samples SHA-256: `749ba7e458f6500ea85536fa57ced80d4b01505876ac79e52af0f7aed3e3f581`
- alias-registry SHA-256: `11eef6de5bc64a19d8392ad20dc99836789e3aaec4cfe836410bbcb79cebf0d9`

The legacy matcher marked the run `FAIL` only because it contained a hard-coded expected row count of 9,091,236.

## Source-manifest reconciliation

The migration receipt manifest was reconciled to PostgreSQL relation `source_news.source_slots` with `Reconcile-CfaStage3SourceManifest.ps1`.

Evidence directory:

`D:\CFA-recovery\stage3-source-reconciliation\20260830-030042-74ff52b9`

Observed result:

- reconciliation status: PASS
- migration-manifest archives: 7,163
- database downloaded archives: 7,163
- size/SHA-256 mismatches: 0

Therefore the D-drive corpus used by the direct Stage 3 scan is byte-for-byte the Stage 1 downloaded source corpus registered in PostgreSQL.

## Adjudication

For this verified source corpus, 9,183,757 is the directly observed full-scan row count. The prior literal 9,091,236 is not supported by the reconciled source bytes and is superseded for Stage 3 execution validation.

This correction does not change the frozen matching definition, alias registry, allowed GKG surfaces, context rules, record grain, or deduplication rule.

`Adjudicate-CfaStage3ExistingRun.ps1` is the bounded reproducible gate that verifies the local summary, source-reconciliation receipt, output hashes, corrected source shape, and duplicate count without rescanning the 37.8 GB GDELT corpus.

## Remaining blocking gate

`CFA-S3-005` remains UNVERIFIED until deterministic bounded accepted/rejected samples are directly reviewed for obvious semantic false positives and false negatives.

`CFA-S3-006` therefore remains BLOCKED. No response, news factor, model-ready dataset, or PLS step is authorized by this evidence alone.
