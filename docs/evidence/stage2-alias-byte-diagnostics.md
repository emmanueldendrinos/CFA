# CFA Stage 2 Alias Byte Diagnostics

Targeted byte-level diagnosis of only the archives flagged by the full GKG alias scan. No article text is published. Raw-row traceability uses SHA-256 and field indexes only.

- Diagnostic run: 20260826-023156-55c366f5740e439a8510e01a1ea390d9
- Source alias validation run: 20260826-021434-c46d54ae63424236b67c5a76f1d9fe60
- Issue archives: 139

## Diagnostic summary

```csv
"run_id","source_alias_validation_run","issue_archives","diagnostic_rows_scanned","raw_malformed_field_count_rows","strict_utf8_invalid_rows","strict_utf8_invalid_fields","allnames_utf8_invalid_rows","critical_field_utf8_invalid_rows","noncritical_only_utf8_invalid_rows","fieldwise_recovery_candidate"
"20260826-023156-55c366f5740e439a8510e01a1ea390d9","20260826-021434-c46d54ae63424236b67c5a76f1d9fe60","139","198881","5","148","148","0","0","148","BLOCKED_BY_CRITICAL_OR_STRUCTURAL_FAILURES"
```

## Invalid UTF-8 sequence summary

```csv
"invalid_sequence_hex","occurrence_count"
"F1","35"
"E9","16"
"E1","15"
"AD","14"
"BB","12"
"FC","10"
"F3","8"
"ED","5"
"E4","4"
"E8","4"
"A9","2"
"AE","2"
"B7","2"
"BD","2"
"C2","2"
"D7","2"
"F6","2"
"F8","2"
"A0","1"
"A3","1"
"AC","1"
"E0","1"
"E3","1"
"EA","1"
"EB","1"
"EC","1"
"EF","1"
```

The bounded per-archive diagnostic table is published separately as docs/evidence/stage2-alias-archive-diagnostics.csv. Full row-level diagnostics remain local.

- diagnostic-summary.csv SHA-256: 2c38517ac21aaa0bd320500abc0021f5e0de9614017662a74c1df2865224c312
- archive-diagnostics.csv SHA-256: d21485a0132492e3e7801b9dea838f11e199121005c3623c9fe001f88ca1f4e8
- row-diagnostics.csv SHA-256: 1c72ad5324d5b91e8950bbd14dc7f5a7fc547443f029b4298a06caa13fa09df5
- invalid-sequence-summary.csv SHA-256: 0fc04dd8f591b7eb0e982ed5693416f8e680241ac312889812d5506da1c345dd
