# CFA Stage 2 Alias Recovery Evidence

Recovered alias-observation audit using the byte-diagnostic contract. Non-27-field rows are quarantined and do not contribute to matching. UTF-8 replacement is permitted only in noncritical fields after the prior diagnostic established zero invalid bytes in ALLNAMES and all critical identity/time/source fields.

- Recovery run: 20260826-050242-44a0b06c31d24b308058ee817f9107e3
- Source diagnostic run: 20260826-023156-55c366f5740e439a8510e01a1ea390d9
- Archives scanned: 7163
- Rows scanned: 9183757
- Quarantined rows: 5
- Observed aliases: 44 / 45
- Matching surfaces: ALLNAMES|V2PERSONS|V2ORGANIZATIONS|PAGE_TITLE

## Recovery summary

```csv
"run_id","source_diagnostic_run","archive_files","rows_scanned","quarantined_rows","expected_quarantined_rows","entry_count_failures","malformed_entity_blocks","alias_rows","observed_aliases","not_observed_aliases","context_required_aliases","context_required_observed_aliases","recovery_policy","matching_surfaces"
"20260826-050242-44a0b06c31d24b308058ee817f9107e3","20260826-023156-55c366f5740e439a8510e01a1ea390d9","7163","9183757","5","5","0","0","45","44","1","14","14","QUARANTINE_NON_27_FIELD_ROWS;UTF8_REPLACEMENT_NONCRITICAL_ONLY;CRITICAL_AND_ALLNAMES_STRICT_VALIDATED_BY_DIAGNOSTIC","ALLNAMES|V2PERSONS|V2ORGANIZATIONS|PAGE_TITLE"
```

The normalized 45-row audit, bounded samples, and the complete bounded quarantine list are published separately. The full per-archive scan remains local; its SHA-256 is recorded below. Observations remain evidence for alias review and do not themselves approve context-sensitive aliases.

- recovery-summary.csv SHA-256: dbbaf284ce4a849e96625a5145ecbf9da9c902f413e8e31f377ea0ad2f43948e
- alias-recovery.csv SHA-256: 006b558cb19d4596594aa32307dab4dfa4617a5402e062d591b126e28e75ac93
- alias-recovery-samples.csv SHA-256: e4f4ea884666c4067331ac16d7afb5888638cc6b62eee4f4641e9d130cb34124
- quarantine-rows.csv SHA-256: 97526bf6b26046f68766f543317807e01ecbec25b86efbc743614e15d1d99c63
- archive-scan.csv SHA-256: dbff4ff13100898d0ce3f32ff482ba6f5ce24a410fbbfe942a9ebcf54f35ee34
