# CFA Stage 5 candidate-factor construction evidence — 2026-09-01

Status: **CFA-S5-008_PASS / CFA-S5-009_BLOCKED**

## Source

Direct local execution output supplied after running the Stage 5 V2 construction launcher against the frozen Stage 3 V6 match artifact, frozen Stage 4 response artifact, validated lag-15 batch-timing receipt, and read-only PostgreSQL market relation.

Local candidate receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-factor-artifact\20260901-192149-edd4117ac94342de956c28f81a066c86\stage5-candidate-factor-receipt.json`

Local review CSV:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-factor-artifact\20260901-192149-edd4117ac94342de956c28f81a066c86\stage5-candidate-factor-review-sample.csv`

The exact candidate CSV path and hashes are intentionally not reconstructed here; they must be read from and validated against the local candidate receipt by the independent artifact validator.

## Observed construction result

The local run reported:

- PostgreSQL version: **18.4**;
- session mode: **`default_transaction_read_only=on`**;
- factor rows: **37,058**;
- distinct bases: **434**;
- market available / missing: **36,505 / 553**;
- news 24h available / source-incomplete / outside-population: **27,267 / 9,518 / 273**;
- news 6h available / source-incomplete / outside-population: **28,849 / 7,936 / 273**;
- review rows: **46**;
- `CFA-S5-006`: **PASS**;
- `CFA-S5-007`: **PASS**;
- `CFA-S5-008`: **PASS**;
- `CFA-S5-009`: **BLOCKED**.

These counts exactly reconcile the frozen Stage 5 factor contract partitions.

## Gate decision

`CFA-S5-008 = PASS` — the exact seven-factor candidate artifact was constructed with one row per frozen Stage 4 response key and the expected market/news missingness partitions.

`CFA-S5-009 = BLOCKED` — construction output is not yet frozen. Independent validation must inspect the candidate receipt and its referenced outputs, verify hashes, exact Stage 4 key identity, seven factor columns, formulas, missingness semantics, timing/window boundaries, V6/news-source recomputation, and preserved lineage before Stage 5 freeze.
