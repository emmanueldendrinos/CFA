# CFA Local Validation Evidence Snapshot

This is a curated validation receipt. Raw market/news data, full generated outputs, credentials, database backups, and temporary files remain outside Git. The source evidence files remain under `Documents\CFA-local`; this receipt records bounded summaries plus SHA-256 lineage so the evidence can be reviewed through the CFA repository.

## Source runs

- Kraken reconciliation run: 20260825-140324-a472cacf60444c0b88e398367b5fef0b.
- News source coverage run: 20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b.

## Kraken reconciliation summary

- Manifest member rows: 1059.
- PASS: 1059.
- MISSING: 0.
- HASH_MISMATCH: 0.
- AMBIGUOUS: 0.
- UNVERIFIED_CANDIDATE_SHAPE: 0.
- Archive PASS: 1.

### Archive reconciliation

```csv
"import_run_id","source_archive_relative_path","expected_source_archive_sha256","matching_local_file_count","matching_local_files","status"
"f86f3463-d76e-6c50-8457-74e015d2d316","source\development\research_2025q2\Kraken_OHLCVT_Q2_2025.zip","36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c","1","Kraken_OHLCVT_Q2_2025.zip","PASS"
```

## News source coverage summary

- Coverage checks PASS: 3.
- Coverage checks FAIL: 6.
- Coverage checks UNVERIFIED: 0.

### Coverage checks

```csv
"check_id","status","observed","expected"
"ACQUISITION_RUN_CARDINALITY","PASS","1","1"
"PROTOCOL_CONTRACT_CARDINALITY","PASS","1","1"
"RUN_STATUS_COMPLETE","FAIL","running","completed"
"RUN_COMPLETED_TIMESTAMP","FAIL","","non-null"
"SELECTED_VS_EXPECTED_OBJECTS","PASS","7283","7283"
"ACQUIRED_VS_SELECTED_OBJECTS","FAIL","368","7283"
"PAYLOAD_HASH_NULLS","FAIL","2","0"
"PAYLOAD_HASH_UNIQUENESS","FAIL","366","368"
"ARCHIVE_TIMESTAMP_REACHES_INTERVAL_END","FAIL","2025-06-12T13:15:00.0000000+00:00",">= 2025-06-14T17:45:00.0000000+00:00"
```

### Acquisition run

```csv
protocol_id,run_id,status,package_version,expected_object_count,expected_compressed_bytes,calibration_status,calibration_object_count,started_at_utc,updated_at_utc,completed_at_utc,last_object_key
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,running,1.0.9,7283,38419076974,passed,12,2026-08-19 18:22:19.662738+00,2026-08-20 10:53:07.111393+00,,20250403111500
```

### Protocol contract

```csv
protocol_id,source_id,analysis_run_id,import_run_id,source_product,interval_start_utc,interval_end_exclusive_utc,expected_slots,known_missing_slots,selected_object_count,selected_compressed_bytes,contract_sha256,limits_sha256,factor_protocol_sha256,ddl_sha256,parser_sha256,selection_sha256,installed_at_utc
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,59e65438-8486-4614-b62f-31cefa87a16a,033f7fed-5b14-b75e-ad88-037eab7efb4c,f86f3463-d76e-6c50-8457-74e015d2d316,GDELT 2.0 native/base GKG fifteen-minute update archives,2025-03-30 18:00:00+00,2025-06-14 18:00:00+00,7296,13,7283,38419076974,fa5611df101cf2e53881d5499268001745f1c1902d8a9e1349d9ab3e587d72f7,633fe9a57ccee2e1d5f430f6c31daed527eec4f9aa15a9190e7af318d25ed403,d0d92e0c5e18346ac22dd1ec9efae3b41ad9962cd7f0dafd09b30c125314c443,94d2f7980dfde55a8abef86823adea12eda1b398023f6b55117b6193eabfc2c8,bda7f98f80577071294515d9649a0698c0b0104828125efc11bb82d56dca5134,7d3d11d435bdd5c030bc3001072ac0c3313b3f2e57d6c151d5f7ecc7117b74e2,2026-08-19 18:22:19.127427+00
```

### Acquisition object summary

```csv
exact_object_rows,distinct_payload_sha256,null_payload_sha256_rows,min_archive_timestamp_utc,max_archive_timestamp_utc
368,366,2,2025-03-30 18:00:00+00,2025-06-12 13:15:00+00
```

### Hype table counts

```csv
relation_name,exact_rows
asset_slot_factors,12254
asset_source_slot_factors,30689
market_slot_factors,366
source_registry,4869
subject_terms,708
subjects,435
```

### Latest bounded run events

```csv
protocol_id,run_id,event_id,event_at_utc,event_type,object_key,details_json
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,386,2026-08-20 10:53:07.111753+00,object_completed,20250403111500,"{""rows"": 1645, ""asset_rows"": 51, ""source_rows"": 118, ""matched_rows"": 98, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,385,2026-08-20 10:52:32.123071+00,object_completed,20250403110000,"{""rows"": 1435, ""asset_rows"": 39, ""source_rows"": 81, ""matched_rows"": 88, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,384,2026-08-20 10:51:59.823591+00,object_completed,20250403104500,"{""rows"": 1602, ""asset_rows"": 44, ""source_rows"": 103, ""matched_rows"": 101, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,383,2026-08-20 10:51:24.46541+00,object_completed,20250403103000,"{""rows"": 1515, ""asset_rows"": 41, ""source_rows"": 95, ""matched_rows"": 82, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,382,2026-08-20 10:50:53.804742+00,object_completed,20250403101500,"{""rows"": 1274, ""asset_rows"": 47, ""source_rows"": 112, ""matched_rows"": 77, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,381,2026-08-20 10:50:26.989577+00,object_completed,20250403100000,"{""rows"": 1335, ""asset_rows"": 44, ""source_rows"": 94, ""matched_rows"": 75, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,380,2026-08-20 10:49:56.679566+00,object_completed,20250403094500,"{""rows"": 1482, ""asset_rows"": 44, ""source_rows"": 92, ""matched_rows"": 72, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,379,2026-08-20 10:49:26.725595+00,object_completed,20250403093000,"{""rows"": 1292, ""asset_rows"": 45, ""source_rows"": 100, ""matched_rows"": 83, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,378,2026-08-20 10:48:57.654109+00,object_completed,20250403091500,"{""rows"": 1198, ""asset_rows"": 36, ""source_rows"": 72, ""matched_rows"": 68, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,377,2026-08-20 10:48:32.38185+00,object_completed,20250403090000,"{""rows"": 1245, ""asset_rows"": 38, ""source_rows"": 84, ""matched_rows"": 72, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,376,2026-08-20 10:48:06.53496+00,object_completed,20250403084500,"{""rows"": 1177, ""asset_rows"": 33, ""source_rows"": 66, ""matched_rows"": 49, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,375,2026-08-20 10:47:39.569072+00,object_completed,20250403083000,"{""rows"": 1155, ""asset_rows"": 38, ""source_rows"": 76, ""matched_rows"": 57, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,374,2026-08-20 10:47:14.664876+00,object_completed,20250403081500,"{""rows"": 1412, ""asset_rows"": 31, ""source_rows"": 69, ""matched_rows"": 58, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,373,2026-08-20 10:46:45.338648+00,object_completed,20250403080000,"{""rows"": 1205, ""asset_rows"": 24, ""source_rows"": 56, ""matched_rows"": 48, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,372,2026-08-20 10:46:17.562122+00,object_completed,20250403074500,"{""rows"": 1052, ""asset_rows"": 26, ""source_rows"": 63, ""matched_rows"": 47, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,371,2026-08-20 10:45:53.119361+00,object_completed,20250403073000,"{""rows"": 1213, ""asset_rows"": 29, ""source_rows"": 70, ""matched_rows"": 57, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,370,2026-08-20 10:45:26.534711+00,object_completed,20250403071500,"{""rows"": 1174, ""asset_rows"": 30, ""source_rows"": 65, ""matched_rows"": 48, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,369,2026-08-20 10:44:59.89083+00,object_completed,20250403070000,"{""rows"": 1058, ""asset_rows"": 21, ""source_rows"": 40, ""matched_rows"": 37, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,368,2026-08-20 10:44:37.029138+00,object_completed,20250403064500,"{""rows"": 1196, ""asset_rows"": 29, ""source_rows"": 72, ""matched_rows"": 62, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,367,2026-08-20 10:44:12.377509+00,object_completed,20250403063000,"{""rows"": 1183, ""asset_rows"": 29, ""source_rows"": 57, ""matched_rows"": 39, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,366,2026-08-20 10:43:46.631334+00,object_completed,20250403061500,"{""rows"": 1053, ""asset_rows"": 31, ""source_rows"": 67, ""matched_rows"": 48, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,365,2026-08-20 10:43:22.973725+00,object_completed,20250403060000,"{""rows"": 1262, ""asset_rows"": 31, ""source_rows"": 56, ""matched_rows"": 49, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,364,2026-08-20 10:42:56.790515+00,object_completed,20250403054500,"{""rows"": 1050, ""asset_rows"": 26, ""source_rows"": 60, ""matched_rows"": 54, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,363,2026-08-20 10:42:34.601437+00,object_completed,20250403053000,"{""rows"": 865, ""asset_rows"": 24, ""source_rows"": 49, ""matched_rows"": 38, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,362,2026-08-20 10:42:14.139677+00,object_completed,20250403051500,"{""rows"": 1208, ""asset_rows"": 32, ""source_rows"": 54, ""matched_rows"": 44, ""decoder_replacement_row_count"": 0, ""decoder_replacement_field_mask"": 0, ""decoder_replacement_sequence_count"": 0}"
```

## Source evidence SHA-256

| Category | Run ID | File | SHA-256 |
|---|---|---|---|
| kraken | 20260825-140324-a472cacf60444c0b88e398367b5fef0b | archive-reconciliation.csv | b85fa4e498947ad98723d0c9989389677c8012192362c6d9da51e57264ae4b98 |
| kraken | 20260825-140324-a472cacf60444c0b88e398367b5fef0b | member-reconciliation.csv | e5299b21d09579df98edaad0282925e5f10c242b67b7b475f11628bb92369826 |
| news | 20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b | coverage-checks.csv | 8230d3dc13921139a260400ef536ca2e6d9da5ead61a88879cba84706f6ade7d |
| news | 20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b | acquisition-runs.csv | eba5136decaf5455f165ecea471a8c88373001d7f8e04fee07d774fc10a8156f |
| news | 20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b | protocol-contracts.csv | e8b262dfd2fb1fc81f472811348c8a88ae453138e5d791a229754d3d4e8de774 |
| news | 20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b | acquisition-object-summary.csv | 0c0c9f8f66e37eecf071f3a57648bfc6258998976086f065ffcc440d24c95019 |
| news | 20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b | factor-table-counts.csv | 3e17e269c620cc0dce914bfc14a41573bc410098c86b3e190a057f76e28b5854 |
| news | 20260825-152746-3093dc71d1e84d2a8affe4b1d57b440b | latest-run-events.csv | 4502e546078f32ec18bc610590d1d47c324d7f2bba02434d91545f9a52aadc5a |

