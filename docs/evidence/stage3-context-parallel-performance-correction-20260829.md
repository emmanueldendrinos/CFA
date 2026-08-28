# CFA Stage 3 context inventory parallel performance correction — 2026-08-29

Status: **UNVERIFIED** pending exact local full-Q2 run.

## Trigger

The corrected serial hot-path candidate at commit `2fe854b6ec56f6e50ce249a229a8f794d6b775ad` was directly observed locally at approximately **185 source rows/second average**. At the verified Q2 population of 9,183,757 GKG rows, that rate projects to approximately 13.8 hours for a full scan. The run window closed before a usable Stage 3 evidence package was established, so its dependent output is not accepted as final evidence.

The measured rate establishes a performance defect in execution, not a semantic or sampling change request.

## Frozen correction boundary

The Stage 3 context-adjudication contract remains unchanged in semantic purpose and discovery design. This correction changes only execution mechanics:

1. source archives remain the same verified 7,163 Q2 GKG archives;
2. every row is still parsed and source-accounted;
3. the provisional discovery cue is unchanged in purpose and inputs;
4. sampling remains `CFA_STAGE3_SAMPLE_V2`, using the same source-lineage SHA-256 and the same byte thresholds for `UNBIASED`, `RETRIEVAL_NEGATIVE`, and `ASSET_EDGE` oversampling;
5. context SHA-256 remains `CFA_STAGE3_CONTEXT_V1` and is still computed only for oversample/model-facing rows;
6. the exact 15,000 / 15,000 / 10,000 final source-row selection targets remain unchanged;
7. context-deduplicated reading population and batch construction remain unchanged;
8. no asset identity, crypto relevance, event meaning, factor, response, or PLS conclusion is introduced.

## Parallel execution design

`Build-CfaStage3ContextInventory.ps1` now embeds a compiled C# scanner and partitions archives with `System.Threading.Tasks.Parallel.ForEach`.

- `-WorkerCount 0` is the default and resolves to `System.Environment.ProcessorCount`, i.e. all logical processors visible to the Windows process.
- `-WorkerCount N` permits an explicit bounded override for reproducible performance diagnosis.
- Each parallel worker owns separate SHA-256 instances, counters, and temporary candidate CSV writers; workers do not mutate shared candidate files.
- Shared progress counters use atomic operations only.
- After the parallel map stage finishes, PowerShell performs the deterministic global rank sort/selection, context deduplication, batch creation, hashes, and reconciliation over the much smaller oversample/40k population.

This map/reduce structure preserves deterministic outputs independent of archive scheduling order.

## Required validation

Before another full local scan is accepted:

- PowerShell 7 parse: required PASS.
- Windows PowerShell 5.1 parse: required PASS.
- serial-versus-parallel synthetic scanner counters: required exact equality.
- serial-versus-parallel synthetic oversample candidate set after deterministic rank sorting: required exact equality.
- post-scan selection/context-dedup/batch regression: required PASS.
- exact alias/input validation: required PASS.

The next local run must record `logical_processor_count`, `worker_count`, scan elapsed seconds, and aggregate rows/second in `context-inventory-summary.json`.

`S3-CTX-002` and `S3-CTX-003` remain **UNVERIFIED** until that exact full local run completes and reconciles. Downstream contextual adjudication remains **BLOCKED**.
