# CFA Stage 1 Validation Status

Date: 2026-08-25

Authority: CFA Source of Truth. This receipt records only CFA-era observations produced by read-only PostgreSQL inspection scripts and console output directly supplied from the local execution environment. It does not import prior ASRP conclusions as authority.

## Reproducible evidence

### PostgreSQL discovery

Script: `scripts/windows/Inspect-CfaExistingDatabases.ps1`

Observed PostgreSQL server: 18.4.

Accessible non-template databases inspected successfully: `asrp`, `cri_trading_terminal`, `pls_trading`, `pls_trading_pre_v130`, `postgres`, `srp`.

Relevant discovered relations included `asrp.q2_market_1m_observations`, `asrp.q2_raw_records`, `asrp.q2_import_stage`, the `asrp_hype` schema, `srp.ohlcvt_1m_2025q2`, `srp.pair_identity_map`, `srp.q2_spike_hype_handoff`, and `srp.q2_spike_hype_samples`.

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

All requested small lineage/reference exports returned PASS.

Directly observed core market structures:

`asrp.q2_market_1m_observations` has 19 columns and preserves raw lineage fields including `import_run_id`, `source_member_ordinal`, `member_path_raw`, `pair_token_opaque`, `physical_record_number`, and `raw_record_sha256`, together with `source_epoch_seconds`, `candle_start_utc`, OHLC, base volume, trade count, source-window/minute-alignment/canonical-eligibility flags, quality flags, and duplicate classification.

`asrp.q2_raw_records` has 18 columns and preserves raw record text, raw SHA-256, source tokens, observed field count, record class, quarantine reason, and import timestamp keyed by the same import/member/path/pair/physical-record lineage fields.

`srp.ohlcvt_1m_2025q2` has 11 columns: `pair_id`, `ts_utc`, OHLC, `vwap`, `volume`, `trade_count`, `source_archive_id`, and `processing_run_id`.

### Direct market coverage verification

Script: `scripts/windows/Verify-CfaStage1Coverage.ps1`

Execution controls: PostgreSQL `default_transaction_read_only=on`; statement timeout 120 seconds.

#### ASRP typed market

- Exact rows: 14,055,089.
- Import runs represented: 1.
- Distinct source member ordinals: 1,058.
- Distinct member paths: 1,058.
- Distinct opaque pair tokens: 1,058.
- Minimum timestamp: 2025-04-01 00:00:00+00.
- Maximum timestamp: 2025-06-30 23:59:00+00.
- Rows outside source window: 0.
- Non-minute-aligned rows: 0.
- Canonical eligible rows: 14,055,089.
- Canonical ineligible rows: 0.
- Rows with quality flags: 0.
- Rows with duplicate classification: 0.

#### ASRP raw records

- Exact rows: 14,055,089.
- Import runs represented: 1.
- Distinct source member ordinals: 1,058.
- Distinct member paths: 1,058.
- Distinct opaque pair tokens: 1,058.
- Observed field count minimum/maximum: 7/7.
- Quarantined rows: 0.
- Record class `accepted`: 14,055,089.

#### SRP Q2 market

- Exact rows: 14,055,089.
- Distinct pair IDs: 1,058.
- Distinct source archives: 1.
- Minimum timestamp: 2025-04-01 00:00:00+00.
- Maximum timestamp: 2025-06-30 23:59:00+00.
- Null VWAP rows: 14,055,089.
- Null trade-count rows: 0.
- Null processing-run rows: 0.

#### Bounded integrity checks

All five checks returned PASS:

- ASRP typed natural-key duplicates.
- ASRP raw physical-key duplicates.
- SRP Q2 natural-key duplicates.
- ASRP raw rows without typed match.
- ASRP typed rows without raw match.

This establishes direct Q2 market coverage and raw-to-typed internal reconciliation for the inspected PostgreSQL stores. It does not by itself prove that the local `Documents\Kraken` files are byte-identical to the imported source archive/members.

### News/hype acquisition state discovered during coverage verification

The directly inspected `asrp_hype.acquisition_runs` row reports:

- `status = running`.
- `expected_object_count = 7,283`.
- `calibration_status = passed`.
- `completed_at_utc = NULL`.
- `last_object_key = 20250403111500`.

The directly inspected `asrp_hype.protocol_contracts` row reports:

- source product: `GDELT 2.0 native/base GKG fifteen-minute update archives`.
- protocol interval start: 2025-03-30 18:00:00+00.
- protocol interval end exclusive: 2025-06-14 18:00:00+00.
- expected slots: 7,296.
- known missing slots: 13.
- selected objects: 7,283.

The exact-count verification found only 368 rows in `asrp_hype.acquisition_objects`.

Therefore the currently present hype acquisition cannot be treated as complete: its own run metadata is not complete and its acquired-object row count does not reconcile to the selected/expected object count. This is a blocking source-verification failure until independently resolved or a different verified news source is provided.

## Stage 1 hard-gate status

| Gate | Status | Evidence / blocker |
|---|---|---|
| CFA-S1-001 Authority/source boundary | PASS | CFA SoT remains authority. |
| CFA-S1-002 Authorized repository reference files | PASS | Previously verified repository contents. |
| CFA-S1-003 Reference row-count revalidation | UNVERIFIED | DATA-003 directly revalidated; DATA-001/DATA-002 exact byte-local revalidation remains outstanding. |
| CFA-S1-004 Reference byte-size reconciliation | FAIL | DATA-001/DATA-002 repository sizes differ from SoT-recorded sizes; cause remains unverified. |
| CFA-S1-005 Reference SHA-256 reconciliation | UNVERIFIED | DATA-003 SHA-256 revalidated; DATA-001/DATA-002 byte-preserved hashes remain outstanding. |
| CFA-S1-006 Original Kraken quarters | UNVERIFIED | Local availability reported at `Documents\Kraken`; source archive/member hashes have not yet been directly reconciled to PostgreSQL import lineage. |
| CFA-S1-007 PostgreSQL market/news availability | PASS | PostgreSQL 18.4 read-only discovery and direct table inspection succeeded. Availability does not imply source completeness. |
| CFA-S1-008 Direct market coverage | PASS | 14,055,089 exact Q2 rows; 1,058 member paths/pair tokens; exact Q2 UTC boundaries; zero window/alignment/quality/duplicate failures; raw↔typed bounded reconciliation PASS; SRP exact row/time/pair coverage reconciles. |
| CFA-S1-009 Advance to identity approval | BLOCKED | CFA-S1-003/004/005/006 and CFA-S1-010 remain unresolved. |
| CFA-S1-010 News source acquisition completeness | FAIL | Hype run remains `running`, completion timestamp is null, exact acquisition-object rows are 368 versus 7,283 selected/expected objects. |

## Current decision

A full Kraken reload is **not authorized or required at this point**. The existing PostgreSQL Q2 market stores have passed direct market coverage and internal raw-to-typed integrity checks. Reuse of those stores still requires byte/source reconciliation against `Documents\Kraken` under CFA-S1-006.

The existing hype/news stage must **not** be treated as complete or model-ready. Its acquisition completeness gate is FAIL and downstream news matching/factor work remains blocked.

## Next reproducible calculations

1. Run `scripts/windows/Reconcile-CfaKrakenSources.ps1` read-only to compare local Kraken files/archive members against `asrp.q2_import_runs` and `asrp.q2_import_members` hashes without extraction or reload.
2. Run `scripts/windows/Verify-CfaNewsSourceCoverage.ps1` read-only to produce explicit news acquisition completeness checks and timestamp coverage evidence.
