# CFA Q1 2026 Bootstrap Contract

This document freezes the Q1 2026 control entry point. It does not approve a Q1 source, mapping, alias, response, factor, dataset, validation design, or PLS handover.

## Authority

- Contract: `config/quarters/2026Q1.json`
- Runner: `scripts/windows/Invoke-CfaQuarterBootstrap.ps1`
- Repository base: `main@5f7d0bf2d20ce61830fe4c481767aa74887dbb58`
- CFA SoT SHA-256: `a7597f4a310985ef7083ce8621e1a326370729c9f9cab1a835e04aa1a8176785`
- Quarter interval: `[2026-01-01T00:00:00Z, 2026-04-01T00:00:00Z)`
- Time zone: UTC

`DATA-001`, `DATA-002`, and `DATA-003` remain **UNVERIFIED** because the directly inspected SoT snapshot contains no `DATA-###` identifiers. The contract does not equate them to `AF-001`, `AF-002`, or `AF-003`.

## Frozen bootstrap gates

| ID | Requirement | Pass evidence |
|---|---|---|
| `Q1-CTL-001-MANIFEST` | The machine-readable contract has the exact v1 schema and complete Q1 task sequence. | Exact manifest parses and validates. |
| `Q1-CTL-002-INTERVAL` | Q1 uses exact half-open UTC boundaries. | Start and end equal the calendar-derived Q1 bounds. |
| `Q1-CTL-003-AUTHORITY` | Repository base, SoT bytes, SoT snapshot, and automation plan reconcile. | Base commit is an ancestor; exact SoT SHA-256 and snapshot source hash match. |
| `Q1-CTL-004-DATA-IDS` | Missing `DATA-###` authority is not inferred. | All three IDs remain `UNVERIFIED` with explicit non-equivalence. |
| `Q1-CTL-005-NO-CARRY` | Q2 observations are not Q1 expectations. | No Q2 interval, table name, archive name, or cardinality is contracted. |
| `Q1-CTL-006-READ-ONLY` | Bootstrap validates only. | Acquisition, source mutation, PostgreSQL mutation, and Stage-1 advance flags are all false. |
| `Q1-CTL-007-SEQUENCE` | Upstream order cannot be bypassed. | `Q1-RES-001` is `UNVERIFIED`; every later task is `BLOCKED` in the frozen dependency chain. |

The runner emits a versioned JSON receipt. A runner PASS establishes only the bootstrap controls above. It deliberately leaves `Q1-RES-001` UNVERIFIED.

## Exact commands

Validate and print the receipt without writing local evidence:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-CfaQuarterBootstrap.ps1 -ManifestPath .\config\quarters\2026Q1.json -NoWrite
```

Validate and save a bounded receipt under `Documents\CFA-local\quarter-bootstrap\2026Q1`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Invoke-CfaQuarterBootstrap.ps1 -ManifestPath .\config\quarters\2026Q1.json
```

## Stage status after bootstrap

| Scope | Status | Reason |
|---|---|---|
| Q1 GitHub/SoT control surface | PASS when the exact runner receipt is PASS | Direct repository, commit, and SoT reconciliation is implemented. |
| `Q1-RES-001` local resource census | UNVERIFIED | Kraken files, CFA-local, and PostgreSQL have not been directly inventoried for Q1. |
| Q1 Stage 1 | BLOCKED | Depends on `Q1-RES-001`. |
| Q1 Stages 2–8 | BLOCKED | Each stage remains chained to the preceding hard gate. |

The next authorized operation is the read-only `Q1-RES-001` resource census. Existing Q2-specific runners are not invoked by this bootstrap.
