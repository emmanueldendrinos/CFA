# CFA Stage 1 Validation Status

Date: 2026-08-25

Authority: CFA Source of Truth. This receipt records only CFA-era observations produced by read-only PostgreSQL inspection scripts and console output directly supplied from the local execution environment. It does not import prior ASRP conclusions as authority.

## Reproducible evidence

### PostgreSQL discovery

Script: `scripts/windows/Inspect-CfaExistingDatabases.ps1`

Observed PostgreSQL server: 18.4.

Accessible non-template databases inspected successfully: `asrp`, `cri_trading_terminal`, `pls_trading`, `pls_trading_pre_v130`, `postgres`, `srp`.

Relevant discovered relations included:

- `asrp.asrp.q2_market_1m_observations`
- `asrp.asrp.q2_raw_records`
- `asrp.asrp.q2_import_stage`
- `asrp.asrp_hype.*`
- `srp.srp.ohlcvt_1m_2025q2`
- `srp.srp.pair_identity_map`
- `srp.srp.q2_spike_hype_handoff`
- `srp.srp.q2_spike_hype_samples`

Discovery relation row values were PostgreSQL estimates only and were not treated as exact evidence.

### Controlled exact-count revalidation

Script: `scripts/windows/Inspect-CfaLegacyMarketHype.ps1`

Execution controls: PostgreSQL `default_transaction_read_only=on`; statement timeout 90 seconds.

All 18 controlled exact-count queries returned PASS. Key exact counts:

| Relation | Exact rows |
|---|---:|
| `asrp.q2_import_stage` | 470 |
| `asrp.q2_market_1m_observations` | 14,055,089 |
| `asrp.q2_raw_records` | 14,055,089 |
| `asrp_hype.acquisition_objects` | 368 |
| `asrp_hype.acquisition_runs` | 1 |
| `asrp_hype.asset_slot_factors` | 12,254 |
| `asrp_hype.asset_source_slot_factors` | 30,689 |
| `asrp_hype.market_slot_factors` | 366 |
| `asrp_hype.protocol_contracts` | 1 |
| `asrp_hype.run_events` | 384 |
| `asrp_hype.source_registry` | 4,869 |
| `asrp_hype.subject_terms` | 708 |
| `asrp_hype.subjects` | 435 |
| `srp.ohlcvt_1m_2025q2` | 14,055,089 |
| `srp.market_pairs` | 1,539 |
| `srp.pair_identity_map` | 1,539 |
| `srp.q2_spike_hype_handoff` | 9,048 |
| `srp.q2_spike_hype_samples` | 1,037 |

The earlier PostgreSQL estimate of 14,055,090 for `srp.ohlcvt_1m_2025q2` is superseded for CFA purposes by the direct exact count of 14,055,089.

### Structural and lineage inspection

Script: `scripts/windows/Inspect-CfaLegacyLineage.ps1`

All requested small lineage/reference exports returned PASS:

- `asrp.q2_import_stage`: 470 rows
- `asrp_hype.acquisition_runs`: 1 row
- `asrp_hype.acquisition_objects`: 368 rows
- `asrp_hype.protocol_contracts`: 1 row
- `asrp_hype.run_events`: 384 rows
- `asrp_hype.source_registry`: 4,869 rows
- `asrp_hype.subjects`: 435 rows
- `asrp_hype.subject_terms`: 708 rows
- `srp.pair_identity_map`: 1,539 rows
- `srp.q2_spike_hype_handoff`: 9,048 rows
- `srp.q2_spike_hype_samples`: 1,037 rows

Directly observed core market structures:

`asrp.q2_market_1m_observations` has 19 columns and preserves raw lineage fields including `import_run_id`, `source_member_ordinal`, `member_path_raw`, `pair_token_opaque`, `physical_record_number`, and `raw_record_sha256`, together with `source_epoch_seconds`, `candle_start_utc`, OHLC, base volume, trade count, source-window/minute-alignment/canonical-eligibility flags, quality flags, and duplicate classification.

`asrp.q2_raw_records` has 18 columns and preserves raw record text, raw SHA-256, source tokens, observed field count, record class, quarantine reason, and import timestamp keyed by the same import/member/path/pair/physical-record lineage fields.

`srp.ohlcvt_1m_2025q2` has 11 columns: `pair_id`, `ts_utc`, OHLC, `vwap`, `volume`, `trade_count`, `source_archive_id`, and `processing_run_id`.

## Stage 1 hard-gate status

| Gate | Status | Evidence / blocker |
|---|---|---|
| CFA-S1-001 Authority/source boundary | PASS | CFA SoT remains authority. |
| CFA-S1-002 Authorized repository reference files | PASS | Previously verified repository contents. |
| CFA-S1-003 Reference row-count revalidation | UNVERIFIED | DATA-003 directly revalidated; DATA-001/DATA-002 exact byte-local revalidation remains outstanding. |
| CFA-S1-004 Reference byte-size reconciliation | FAIL | DATA-001/DATA-002 repository sizes differ from SoT-recorded sizes; cause remains unverified. |
| CFA-S1-005 Reference SHA-256 reconciliation | UNVERIFIED | DATA-003 SHA-256 revalidated; DATA-001/DATA-002 byte-preserved hashes remain outstanding. |
| CFA-S1-006 Original Kraken quarters | UNVERIFIED | Local availability reported at `Documents\Kraken`; source files have not yet been directly reconciled to PostgreSQL lineage. |
| CFA-S1-007 PostgreSQL market/news availability | PASS | PostgreSQL 18.4 read-only discovery and direct table inspection succeeded. This PASS is availability only, not semantic approval of derived tables. |
| CFA-S1-008 Direct market coverage | UNVERIFIED | Exact Q2 row counts reconcile at 14,055,089 across ASRP raw/typed and SRP Q2 stores, but pair coverage, timestamp boundaries, duplicate/null/quality checks, raw→typed equivalence, and source-file reconciliation remain required. |
| CFA-S1-009 Advance to identity approval | BLOCKED | CFA-S1-003/004/005/006/008 unresolved. |

## Current decision

A full Kraken reload is **not authorized or required at this point**. Existing PostgreSQL Q2 stores are candidates for CFA reuse because their exact row counts reconcile and ASRP preserves row-level raw lineage. Reuse remains **UNVERIFIED** until content/coverage and source-file lineage reconciliation pass.

## Next reproducible calculation

Run `scripts/windows/Verify-CfaStage1Coverage.ps1` read-only. It is designed to calculate pair/time coverage, quality/null summaries, bounded duplicate tests, raw→typed lineage checks, and discover source/archive/hash metadata needed for reconciliation against `Documents\Kraken`.
