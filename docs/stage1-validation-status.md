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

This establishes direct Q2 market coverage and raw-to-typed internal reconciliation for the inspected PostgreSQL stores.

### Direct Kraken source reconciliation

Script: `scripts/windows/Reconcile-CfaKrakenSources.ps1`

Execution controls: Windows PowerShell 5.1; PostgreSQL `default_transaction_read_only=on`; no archive extraction; no Kraken file modification; no PostgreSQL object or row modification.

Validated local run: `20260825-140324-a472cacf60444c0b88e398367b5fef0b`.

The script inspected the exact locally present archive named by PostgreSQL lineage, `Kraken_OHLCVT_Q2_2025.zip`.

#### Member reconciliation

- Database manifest members: 1,059.
- Candidate member objects: 1,059.
- PASS: 1,059.
- MISSING: 0.
- HASH_MISMATCH: 0.
- AMBIGUOUS: 0.
- UNVERIFIED_CANDIDATE_SHAPE: 0.

#### Archive reconciliation

- Import run: `f86f3463-d76e-6c50-8457-74e015d2d316`.
- PostgreSQL-recorded source path: `source\development\research_2025q2\Kraken_OHLCVT_Q2_2025.zip`.
- Expected SHA-256: `36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c`.
- Matching local files: 1.
- Matching local file: `Kraken_OHLCVT_Q2_2025.zip`.
- Archive status: PASS.

This directly reconciles the locally present Q2 Kraken archive and all 1,059 PostgreSQL manifest members to recorded import lineage. CFA-S1-006 is therefore PASS. This does not alter the separate observation that the typed/raw market relations contain 1,058 distinct data-bearing source member ordinals/pair tokens.

### Direct news source coverage verification

Script: `scripts/windows/Verify-CfaNewsSourceCoverage.ps1`

Execution controls: Windows PowerShell 5.1; PostgreSQL `default_transaction_read_only=on`; statement timeout 60 seconds; no PostgreSQL object or row modification.

Validated local run: `20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b`.

#### Acquisition run and protocol

The directly inspected acquisition run reports:

- protocol ID: `5ba49c0d-b7c8-4d66-ad10-8579a5d34458`.
- run ID: `ec052d2a-1156-4562-8ae2-c0208051ae39`.
- package version: `1.0.9`.
- status: `running`.
- expected object count: 7,283.
- expected compressed bytes: 38,419,076,974.
- calibration status: `passed` across 12 calibration objects.
- started at: 2026-08-19 18:22:19.662738+00.
- last updated at: 2026-08-20 10:53:07.111393+00.
- completed timestamp: NULL.
- last object key: `20250403111500`.

The directly inspected protocol contract reports:

- source product: `GDELT 2.0 native/base GKG fifteen-minute update archives`.
- protocol interval start: 2025-03-30 18:00:00+00.
- protocol interval end exclusive: 2025-06-14 18:00:00+00.
- expected slots: 7,296.
- known missing slots: 13.
- selected objects: 7,283.
- selected compressed bytes: 38,419,076,974.

#### Acquisition object coverage

- Exact acquisition-object rows: 368.
- Distinct payload SHA-256 values: 366.
- Rows with NULL payload SHA-256: 2.
- Minimum archive timestamp: 2025-03-30 18:00:00+00.
- Maximum archive timestamp: 2025-06-12 13:15:00+00.
- Required final selected slot timestamp for interval-end coverage: at least 2025-06-14 17:45:00+00.

#### Explicit coverage checks

- `ACQUISITION_RUN_CARDINALITY`: PASS, observed 1 / expected 1.
- `PROTOCOL_CONTRACT_CARDINALITY`: PASS, observed 1 / expected 1.
- `RUN_STATUS_COMPLETE`: FAIL, observed `running` / expected `completed`.
- `RUN_COMPLETED_TIMESTAMP`: FAIL, observed NULL / expected non-null.
- `SELECTED_VS_EXPECTED_OBJECTS`: PASS, observed 7,283 / expected 7,283.
- `ACQUIRED_VS_SELECTED_OBJECTS`: FAIL, observed 368 / expected 7,283.
- `PAYLOAD_HASH_NULLS`: FAIL, observed 2 / expected 0.
- `PAYLOAD_HASH_UNIQUENESS`: FAIL, observed 366 / expected 368.
- `ARCHIVE_TIMESTAMP_REACHES_INTERVAL_END`: FAIL, observed 2025-06-12 13:15:00+00 / expected at least 2025-06-14 17:45:00+00.

Total coverage-check failures: 6. Total UNVERIFIED checks: 0.

The existing hype/news acquisition is therefore directly demonstrated to be incomplete and internally unreconciled. CFA-S1-010 remains FAIL. The existing factor tables derived from this acquisition must not be treated as complete source evidence or model-ready inputs.

## Stage 1 hard-gate status

| Gate | Status | Evidence / blocker |
|---|---|---|
| CFA-S1-001 Authority/source boundary | PASS | CFA SoT remains authority. |
| CFA-S1-002 Authorized repository reference files | PASS | Previously verified repository contents. |
| CFA-S1-003 Reference row-count revalidation | UNVERIFIED | DATA-003 directly revalidated; DATA-001/DATA-002 exact byte-local revalidation remains outstanding. |
| CFA-S1-004 Reference byte-size reconciliation | FAIL | DATA-001/DATA-002 repository sizes differ from SoT-recorded sizes; cause remains unverified. |
| CFA-S1-005 Reference SHA-256 reconciliation | UNVERIFIED | DATA-003 SHA-256 revalidated; DATA-001/DATA-002 byte-preserved hashes remain outstanding. |
| CFA-S1-006 Original Kraken quarters | PASS | Exact local Q2 archive SHA-256 matches PostgreSQL import lineage; all 1,059 manifest members reconcile PASS with zero missing, mismatched, ambiguous, or unverified-shape members. |
| CFA-S1-007 PostgreSQL market/news availability | PASS | PostgreSQL 18.4 read-only discovery and direct table inspection succeeded. Availability does not imply source completeness. |
| CFA-S1-008 Direct market coverage | PASS | 14,055,089 exact Q2 rows; 1,058 member paths/pair tokens; exact Q2 UTC boundaries; zero window/alignment/quality/duplicate failures; raw↔typed bounded reconciliation PASS; SRP exact row/time/pair coverage reconciles. |
| CFA-S1-009 Advance to identity approval | BLOCKED | CFA-S1-003/004/005 and CFA-S1-010 remain unresolved. |
| CFA-S1-010 News source acquisition completeness | FAIL | Direct coverage verification produced 6 FAIL and 0 UNVERIFIED checks: run incomplete, completion timestamp null, 368/7,283 acquired objects, 2 null payload hashes, only 366 distinct payload hashes across 368 rows, and timestamp coverage stops before the protocol interval end. |

## Current decision

A full Kraken reload is **not authorized or required**. The existing PostgreSQL Q2 market stores have passed direct market coverage, internal raw-to-typed integrity checks, and direct byte/source reconciliation against the locally present Q2 Kraken archive and all PostgreSQL manifest members.

The project must still **not** advance to identity approval. DATA-001/DATA-002 reference reconciliation remains unresolved under CFA-S1-003/004/005, and the existing hype/news acquisition fails source-completeness validation under CFA-S1-010.

The existing hype/news factor tables must **not** be treated as complete or model-ready. Downstream news matching, candidate-factor definition, leakage testing, model-ready dataset freezing, and PLS remain blocked by the upstream source gate.

## Next reproducible calculations

1. Inspect the recorded news run events and acquisition-object failure evidence to determine why acquisition stopped and whether a CFA-authorized, reproducible completion or replacement path exists. Do not resume or reuse a legacy acquisition implementation merely because it exists.
2. Resolve DATA-001/DATA-002 exact row-count, byte-size, and SHA-256 reconciliation against the CFA SoT before identity approval.
