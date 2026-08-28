# CFA Stage 3 context inventory disk-exhaustion correction — 2026-08-29

Status: **FAIL diagnostic evidence** for the superseded disk-heavy parallel implementation; replacement V3 remains **UNVERIFIED** pending exact local full-Q2 validation.

## Direct local observations

The all-core parallel context inventory sustained approximately 840–843 source rows/second and reached approximately 3.50 million of 9,183,757 Q2 GKG rows before failing with only the outer `.NET AggregateException` visible from the original runner.

A targeted diagnostic was then run on archive slice 2600..3099. Before scanning it reported:

- workers: 8;
- logical processors: 8;
- output free space: **0 GB**.

The diagnostic then failed while writing evidence with:

`System.IO.IOException: There is not enough space on the disk.`

Therefore the directly established root cause of the failed full parallel run is **disk exhaustion**, not a verified bad GDELT archive or semantic-data defect.

The subsequent PowerShell `else` parsing error in the interactive shell was unrelated to the scanner and has no project significance.

## Defect boundary

The superseded parallel implementation wrote full context payloads for deterministic oversample rows during the 9.18M-row pass. The asset/edge oversample can be materially larger than the final 10,000-row enriched discovery stratum, and raw GKG context fields can be large. That design allowed temporary evidence to grow until the output drive was exhausted.

This is an implementation/storage defect. It does not require changing the frozen discovery population sizes or the semantic architecture.

## Bounded V3 correction

`Build-CfaStage3ContextInventoryV3.ps1` preserves the existing source population, `CFA_STAGE3_SAMPLE_V2` lineage hashing, retrieval cue, stratum ordering, and final targets of 15,000 unbiased + 15,000 retrieval-negative + 10,000 asset/edge rows.

It changes execution only:

1. pass 1 scans all source rows in compiled parallel C#;
2. pass 1 keeps only small deterministic lineage/rank keys for threshold-selected sampling candidates in memory;
3. no full GKG context payload is written during the 9.18M-row pass;
4. the exact 40,000 source-row selection is frozen after pass 1;
5. pass 2 re-reads only what is necessary to materialize full context for those 40,000 selected rows;
6. context hashing, selected-context deduplication, reading batches, hashes, and manifests occur only after selection;
7. a hard free-space preflight requires at least 15 GB on the selected output drive before a full run begins.

The V3 validation suite requires PowerShell 7 and Windows PowerShell 5.1 parsing/self-tests, exact equality between serial and parallel source counters, exact serial-versus-parallel selected lineage/rank sets, deterministic materialized selection bytes, exact candidate inputs, and enforcement that disk-heavy full-context oversample worker files are absent.

## Gate state

- `S3-CTX-001`: **PASS** for V3 component/CI validation only.
- `S3-CTX-002`: **UNVERIFIED** pending exact V3 full-Q2 local run.
- `S3-CTX-003`: **UNVERIFIED** pending exact V3 40,000-row selection and reading-population reconciliation.
- `S3-CTX-004..008`: **BLOCKED**.

No failed or partial run output may be used as semantic, factor, response, model-ready, or PLS evidence.
