# CFA Stage 3 parallel context inventory runtime failure — 2026-08-29

Status: **FAIL** for the local full-Q2 validation candidate; downstream gates remain blocked.

## Direct local observation

The exact all-core context-inventory candidate at commit `350fb00b9a21cbe15f44d6ec3171bacc305b2920` was run locally against the verified Q2 GDELT GKG archive root. The parallel scanner sustained approximately 840–843 aggregate source rows/second through more than 3.5 million rows and approximately 2,800 completed archives. The last directly reported progress lines included:

- archives `2400/7163`, rows `3037233/9183757`, `842.6 rows/sec`;
- archives `2500/7163`, rows `3147248/9183757`, `842.5 rows/sec`;
- archives `2596/7163`, rows `3251238/9183757`, `841.9 rows/sec`;
- archives `2700/7163`, rows `3377947/9183757`, `841.6 rows/sec`;
- archives `2793/7163`, rows `3500875/9183757`, `840.2 rows/sec`;
- archives `2800/7163`, rows `3509305/9183757`, `840.2 rows/sec`.

The run then failed with exit code `1`. The PowerShell surface exposed only the outer `.NET AggregateException` message `One or more errors occurred.` from `ParallelScanner.Run`; the current artifact did not recursively print its inner exception(s), so the triggering archive, row, and root exception are **UNVERIFIED**.

The subsequent interactive `else` parse error is unrelated to the scanner. It occurred because the `if` block and `else` block from the calling shell snippet were entered as separate interactive commands after the child process had already failed.

## Interpretation

- Parallel execution is materially faster than the prior serial candidate (approximately 842 rows/sec versus approximately 185 rows/sec), so the parallel architecture is retained as a candidate.
- This run is **not** valid Stage 3 evidence because it did not complete source accounting or discovery selection.
- `S3-CTX-002 = UNVERIFIED` and `S3-CTX-003 = UNVERIFIED` remain unchanged.
- Partial outputs from this failed run must not be used for semantic adjudication or downstream analysis.
- The immediate correction boundary is failure observability and archive-level runtime robustness. No semantic, retrieval, sampling, identity, factor, response, or PLS definition changes are authorized by this failure.

## Required correction

Before another full local run is accepted, the parallel scan path must:

1. preserve the existing `CFA_STAGE3_SAMPLE_V2` and `CFA_STAGE3_CONTEXT_V1` semantics;
2. report nested/aggregate exceptions recursively;
3. identify the physical archive associated with any worker failure;
4. distinguish deterministic source/logic failures from transient I/O failures;
5. test the failure path under CI with an injected malformed/broken archive;
6. retain exact source accounting as a blocking gate.
