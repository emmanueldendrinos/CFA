# CFA Local Validation Evidence Snapshot

Curated evidence receipt derived from direct CFA-local validation outputs. Raw market/news data, credentials, database backups, full generated outputs, and temporary files remain outside Git.

## Source runs

- Kraken reconciliation: 20260825-140324-a472cacf60444c0b88e398367b5fef0b
- News source coverage: 20260825-162516-5cbb56c5d92e481b807116b6789652b0
- News acquisition diagnosis: 20260825-162517-bc80b1b868854effacb38acbdc18f7dc

## Kraken reconciliation summary

- Manifest members: 1059
- PASS: 1059
- MISSING: 0
- HASH_MISMATCH: 0
- AMBIGUOUS: 0
- UNVERIFIED_CANDIDATE_SHAPE: 0
- Archive PASS: 1

### Archive reconciliation

```csv
"import_run_id","source_archive_relative_path","expected_source_archive_sha256","matching_local_file_count","matching_local_files","status"
"f86f3463-d76e-6c50-8457-74e015d2d316","source\development\research_2025q2\Kraken_OHLCVT_Q2_2025.zip","36a1aa3a04f4ac3d700e13788372fcc1dfb7c506a2e47b0b05e8250ccd1a8e3c","1","Kraken_OHLCVT_Q2_2025.zip","PASS"
```

## News source coverage summary

- PASS checks: 4
- FAIL checks: 5
- UNVERIFIED checks: 0

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
"PAYLOAD_HASH_NON_NULL_UNIQUENESS","PASS","366","366"
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
exact_object_rows,non_null_payload_sha256_rows,distinct_non_null_payload_sha256,null_payload_sha256_rows,min_archive_timestamp_utc,max_archive_timestamp_utc
368,366,366,2,2025-03-30 18:00:00+00,2025-06-12 13:15:00+00
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

## News acquisition diagnosis

### Diagnosis checks

```csv
"check_id","status","observed","expected"
"LATEST_EVENT_IS_OBJECT_COMPLETED","PASS","object_completed","object_completed"
"RECORDED_ERROR_EVENT_TYPES","FAIL","2","0"
"NON_NULL_PAYLOAD_HASH_DUPLICATE_GROUPS","PASS","0","0"
"NULL_PAYLOAD_HASH_ROWS","FAIL","2","0"
"STOP_CLASSIFICATION","UNVERIFIED","RECORDED_ERROR_EVENT_TYPE_PRESENT","direct cause requires process/source evidence"
```

### Event type summary

```csv
event_type,exact_events,first_event_at_utc,last_event_at_utc,min_object_key,max_object_key
calibration_passed,1,2026-08-19 20:28:51.020975+00,2026-08-19 20:28:51.020975+00,,
failed_integrity_or_parser,1,2026-08-19 20:30:51.9978+00,2026-08-19 20:30:51.9978+00,"",""
network_circuit_breaker_pause,1,2026-08-19 18:23:39.030493+00,2026-08-19 18:23:39.030493+00,20250531204500,20250531204500
network_failed,12,2026-08-19 18:22:30.561806+00,2026-08-20 08:14:59.16939+00,20250330180000,20250531204500
object_completed,366,2026-08-19 20:24:29.011744+00,2026-08-20 10:53:07.111753+00,20250330180000,20250612131500
run_started,1,2026-08-19 18:22:19.665083+00,2026-08-19 18:22:19.665083+00,,
v1_0_6_encoding_recovery,1,2026-08-20 04:03:28.253094+00,2026-08-20 04:03:28.253094+00,,
zero_coverage_parser_migration,1,2026-08-19 20:24:09.851742+00,2026-08-19 20:24:09.851742+00,,
```

### Object accounting

```csv
exact_object_rows,null_payload_hash_rows,distinct_non_null_payload_hashes,rows_at_or_before_last_progress_key,rows_after_last_progress_key,min_timestamp_after_last_progress_key,max_timestamp_after_last_progress_key
368,2,366,358,10,2025-04-07 11:30:00+00,2025-06-12 13:15:00+00
```

### Completed-event accounting

```csv
object_completed_events,distinct_completed_object_keys,min_completed_object_key,max_completed_object_key
366,366,20250330180000,20250612131500
```

### Duplicate non-null payload hashes

```csv
payload_sha256,exact_rows,min_archive_timestamp_utc,max_archive_timestamp_utc
```

### NULL payload-hash rows

```csv
archive_timestamp_utc,row_json
2025-03-31 14:30:00+00,"{""run_id"": ""ec052d2a-1156-4562-8ae2-c0208051ae39"", ""status"": ""network_failed"", ""error_code"": ""network_exhausted_b17011a4e15b0c03"", ""object_key"": ""20250331143000"", ""secure_url"": ""https://storage.googleapis.com/data.gdeltproject.org/gdeltv2/20250331143000.gkg.csv.zip"", ""protocol_id"": ""5ba49c0d-b7c8-4d66-ad10-8579a5d34458"", ""observed_md5"": null, ""provider_md5"": ""5570910f51252ce69a657a789ee81f75"", ""parser_sha256"": ""bda7f98f80577071294515d9649a0698c0b0104828125efc11bb82d56dca5134"", ""payload_sha256"": null, ""total_row_count"": 0, ""committed_at_utc"": ""2026-08-20T08:14:40.528747+00:00"", ""retrieved_at_utc"": null, ""download_attempts"": 3, ""expected_size_bytes"": 7690628, ""observed_size_bytes"": null, ""record_time_max_utc"": null, ""record_time_min_utc"": null, ""asset_slot_row_count"": 0, ""archive_timestamp_utc"": ""2025-03-31T14:30:00+00:00"", ""factor_protocol_sha256"": ""d0d92e0c5e18346ac22dd1ec9efae3b41ad9962cd7f0dafd09b30c125314c443"", ""retained_archive_count"": 0, ""response_headers_sha256"": null, ""uncompressed_entry_bytes"": null, ""ambiguous_lexical_row_count"": 0, ""asset_source_slot_row_count"": 0, ""lexically_matched_row_count"": 0, ""retained_document_row_count"": 0, ""retained_valid_raw_row_count"": 0, ""retained_extracted_file_count"": 0, ""temporary_payload_deleted_at_utc"": null, ""effective_market_available_at_utc"": null}"
2025-03-31 14:45:00+00,"{""run_id"": ""ec052d2a-1156-4562-8ae2-c0208051ae39"", ""status"": ""network_failed"", ""error_code"": ""network_exhausted_b17011a4e15b0c03"", ""object_key"": ""20250331144500"", ""secure_url"": ""https://storage.googleapis.com/data.gdeltproject.org/gdeltv2/20250331144500.gkg.csv.zip"", ""protocol_id"": ""5ba49c0d-b7c8-4d66-ad10-8579a5d34458"", ""observed_md5"": null, ""provider_md5"": ""0e882f34047227014f606f3bd6411da8"", ""parser_sha256"": ""bda7f98f80577071294515d9649a0698c0b0104828125efc11bb82d56dca5134"", ""payload_sha256"": null, ""total_row_count"": 0, ""committed_at_utc"": ""2026-08-20T08:14:59.164706+00:00"", ""retrieved_at_utc"": null, ""download_attempts"": 3, ""expected_size_bytes"": 7986716, ""observed_size_bytes"": null, ""record_time_max_utc"": null, ""record_time_min_utc"": null, ""asset_slot_row_count"": 0, ""archive_timestamp_utc"": ""2025-03-31T14:45:00+00:00"", ""factor_protocol_sha256"": ""d0d92e0c5e18346ac22dd1ec9efae3b41ad9962cd7f0dafd09b30c125314c443"", ""retained_archive_count"": 0, ""response_headers_sha256"": null, ""uncompressed_entry_bytes"": null, ""ambiguous_lexical_row_count"": 0, ""asset_source_slot_row_count"": 0, ""lexically_matched_row_count"": 0, ""retained_document_row_count"": 0, ""retained_valid_raw_row_count"": 0, ""retained_extracted_file_count"": 0, ""temporary_payload_deleted_at_utc"": null, ""effective_market_available_at_utc"": null}"
```

### Completed-event gaps

```csv
previous_object_key,object_key,gap_minutes
20250331141500,20250331150000,45.0000000000000000
20250403111500,20250407113000,5775.0000000000000000
20250407113000,20250411123000,5820.0000000000000000
20250411123000,20250419001500,10785.000000000000
20250419001500,20250427083000,12015.000000000000
20250427083000,20250519201500,32385.000000000000
20250519201500,20250520063000,615.0000000000000000
20250520063000,20250523234500,5355.0000000000000000
20250523234500,20250531204500,11340.000000000000
20250531204500,20250610164500,14160.000000000000
20250610164500,20250612131500,2670.0000000000000000
```

### Latest non-completion events

```csv
protocol_id,run_id,event_id,event_at_utc,event_type,object_key,details_json
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,113,2026-08-20 08:14:59.16939+00,network_failed,20250331144500,"{""attempts"": 3, ""error_code"": ""network_exhausted_b17011a4e15b0c03""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,112,2026-08-20 08:14:40.53435+00,network_failed,20250331143000,"{""attempts"": 3, ""error_code"": ""network_exhausted_b17011a4e15b0c03""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,37,2026-08-20 04:03:28.253094+00,v1_0_6_encoding_recovery,,"{""to_package_version"": ""1.0.9"", ""from_package_version"": ""1.0.6"", ""current_parser_sha256"": ""bda7f98f80577071294515d9649a0698c0b0104828125efc11bb82d56dca5134"", ""previous_parser_sha256"": ""e198fc3486ffe76d660be0129332c3223d2b219e287e23263dc0b7f424442497"", ""current_contract_sha256"": ""fa5611df101cf2e53881d5499268001745f1c1902d8a9e1349d9ab3e587d72f7"", ""previous_contract_sha256"": ""3686d79188c28de1cdad813a5dd78216b625a53121fdb4c88980607b02ab1d8d"", ""recovery_decision_sha256"": ""e7f19c47438f2b03fbb4301e449f3577d2897f352f40d6e2ff3786ea290dbed4"", ""completed_objects_retained"": 19, ""first_incomplete_object_key"": ""20250330200000"", ""completed_compressed_bytes_retained"": 95208644}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,35,2026-08-19 20:30:51.9978+00,failed_integrity_or_parser,"","{""error"": ""Exception calling \""ReadLine\"" with \""0\"" argument(s): \""Unable to translate bytes [E6] at index 3310 from specified code page to Unicode.\"""", ""execution_timestamp"": ""20260819-202352-673""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,27,2026-08-19 20:28:51.020975+00,calibration_passed,,"{""schema_after_bytes"": 1761280, ""calibration_compressed_bytes"": 67689820, ""projected_final_schema_bytes"": 854916962}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,14,2026-08-19 20:24:09.851742+00,zero_coverage_parser_migration,,"{""completed_objects"": 0, ""to_package_version"": ""1.0.6"", ""from_package_version"": ""1.0.4"", ""current_parser_sha256"": ""e198fc3486ffe76d660be0129332c3223d2b219e287e23263dc0b7f424442497"", ""previous_parser_sha256"": ""c114cdc4652d6bb323410917c8bdc1754c9c33bdb6df744d385eee74620c4116"", ""network_failure_receipts"": 10}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,12,2026-08-19 18:23:39.030493+00,network_circuit_breaker_pause,20250531204500,"{""reason"": ""Paused after 10 consecutive objects exhausted bounded network retries."", ""last_object"": ""20250531204500"", ""consecutive_failures"": 10}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,11,2026-08-19 18:23:38.939541+00,network_failed,20250531204500,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,10,2026-08-19 18:23:31.151037+00,network_failed,20250523234500,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,9,2026-08-19 18:23:23.60137+00,network_failed,20250520063000,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,8,2026-08-19 18:23:16.057292+00,network_failed,20250519201500,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,7,2026-08-19 18:23:08.320677+00,network_failed,20250427083000,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,6,2026-08-19 18:23:00.727779+00,network_failed,20250419001500,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,5,2026-08-19 18:22:53.050371+00,network_failed,20250411123000,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,4,2026-08-19 18:22:45.408457+00,network_failed,20250407113000,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,3,2026-08-19 18:22:38.302393+00,network_failed,20250401041500,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,2,2026-08-19 18:22:30.561806+00,network_failed,20250330180000,"{""attempts"": 3, ""error_code"": ""network_exhausted_9941904fa3cb5bd5""}"
5ba49c0d-b7c8-4d66-ad10-8579a5d34458,ec052d2a-1156-4562-8ae2-c0208051ae39,1,2026-08-19 18:22:19.665083+00,run_started,,{}
```

### ASRP hype tables

```csv
table_name
acquisition_objects
acquisition_runs
asset_slot_factors
asset_source_slot_factors
market_slot_factors
protocol_contracts
run_events
source_registry
subject_terms
subjects
```

### Core table columns

```csv
table_name,ordinal_position,column_name,data_type,is_nullable
acquisition_objects,1,protocol_id,uuid,NO
acquisition_objects,2,run_id,uuid,NO
acquisition_objects,3,object_key,text,NO
acquisition_objects,4,archive_timestamp_utc,timestamp with time zone,NO
acquisition_objects,5,effective_market_available_at_utc,timestamp with time zone,YES
acquisition_objects,6,secure_url,text,NO
acquisition_objects,7,expected_size_bytes,bigint,NO
acquisition_objects,8,provider_md5,text,NO
acquisition_objects,9,observed_size_bytes,bigint,YES
acquisition_objects,10,uncompressed_entry_bytes,bigint,YES
acquisition_objects,11,observed_md5,text,YES
acquisition_objects,12,payload_sha256,text,YES
acquisition_objects,13,response_headers_sha256,text,YES
acquisition_objects,14,status,text,NO
acquisition_objects,15,download_attempts,integer,NO
acquisition_objects,16,total_row_count,bigint,NO
acquisition_objects,17,lexically_matched_row_count,bigint,NO
acquisition_objects,18,ambiguous_lexical_row_count,bigint,NO
acquisition_objects,19,asset_slot_row_count,integer,NO
acquisition_objects,20,asset_source_slot_row_count,integer,NO
acquisition_objects,21,retrieved_at_utc,timestamp with time zone,YES
acquisition_objects,22,temporary_payload_deleted_at_utc,timestamp with time zone,YES
acquisition_objects,23,record_time_min_utc,timestamp with time zone,YES
acquisition_objects,24,record_time_max_utc,timestamp with time zone,YES
acquisition_objects,25,committed_at_utc,timestamp with time zone,NO
acquisition_objects,26,parser_sha256,text,NO
acquisition_objects,27,factor_protocol_sha256,text,NO
acquisition_objects,28,retained_archive_count,integer,NO
acquisition_objects,29,retained_extracted_file_count,integer,NO
acquisition_objects,30,retained_valid_raw_row_count,bigint,NO
acquisition_objects,31,retained_document_row_count,bigint,NO
acquisition_objects,32,error_code,text,YES
acquisition_runs,1,protocol_id,uuid,NO
acquisition_runs,2,run_id,uuid,NO
acquisition_runs,3,status,text,NO
acquisition_runs,4,package_version,text,NO
acquisition_runs,5,package_sha256,text,NO
acquisition_runs,6,runner_sha256,text,NO
acquisition_runs,7,expected_object_count,integer,NO
acquisition_runs,8,expected_compressed_bytes,bigint,NO
acquisition_runs,9,calibration_status,text,NO
acquisition_runs,10,calibration_object_count,integer,NO
acquisition_runs,11,calibration_compressed_bytes,bigint,NO
acquisition_runs,12,schema_baseline_bytes,bigint,NO
acquisition_runs,13,schema_after_calibration_bytes,bigint,YES
acquisition_runs,14,projected_final_schema_bytes,bigint,YES
acquisition_runs,15,free_bytes_at_start,bigint,NO
acquisition_runs,16,started_at_utc,timestamp with time zone,NO
acquisition_runs,17,updated_at_utc,timestamp with time zone,NO
acquisition_runs,18,completed_at_utc,timestamp with time zone,YES
acquisition_runs,19,last_object_key,text,YES
protocol_contracts,1,protocol_id,uuid,NO
protocol_contracts,2,source_id,uuid,NO
protocol_contracts,3,contract_sha256,text,NO
protocol_contracts,4,limits_sha256,text,NO
protocol_contracts,5,factor_protocol_sha256,text,NO
protocol_contracts,6,ddl_sha256,text,NO
protocol_contracts,7,parser_sha256,text,NO
protocol_contracts,8,selection_sha256,text,NO
protocol_contracts,9,analysis_run_id,uuid,NO
protocol_contracts,10,import_run_id,uuid,NO
protocol_contracts,11,source_product,text,NO
protocol_contracts,12,interval_start_utc,timestamp with time zone,NO
protocol_contracts,13,interval_end_exclusive_utc,timestamp with time zone,NO
protocol_contracts,14,expected_slots,integer,NO
protocol_contracts,15,known_missing_slots,integer,NO
protocol_contracts,16,selected_object_count,integer,NO
protocol_contracts,17,selected_compressed_bytes,bigint,NO
protocol_contracts,18,raw_archive_retention_allowed,boolean,NO
protocol_contracts,19,raw_row_retention_allowed,boolean,NO
protocol_contracts,20,document_row_retention_allowed,boolean,NO
protocol_contracts,21,installed_at_utc,timestamp with time zone,NO
run_events,1,protocol_id,uuid,NO
run_events,2,run_id,uuid,NO
run_events,3,event_id,bigint,NO
run_events,4,event_at_utc,timestamp with time zone,NO
run_events,5,event_type,text,NO
run_events,6,object_key,text,YES
run_events,7,details_json,jsonb,NO
```

## Source evidence SHA-256

| Category | Run | File | SHA-256 |
|---|---|---|---|
| kraken | 20260825-140324-a472cacf60444c0b88e398367b5fef0b | archive-reconciliation.csv | b85fa4e498947ad98723d0c9989389677c8012192362c6d9da51e57264ae4b98 |
| kraken | 20260825-140324-a472cacf60444c0b88e398367b5fef0b | member-reconciliation.csv | e5299b21d09579df98edaad0282925e5f10c242b67b7b475f11628bb92369826 |
| news-coverage | 20260825-162516-5cbb56c5d92e481b807116b6789652b0 | coverage-checks.csv | bae99cf8d9c93533abe3892422614555e235841e411d9454428412522c043559 |
| news-coverage | 20260825-162516-5cbb56c5d92e481b807116b6789652b0 | acquisition-runs.csv | eba5136decaf5455f165ecea471a8c88373001d7f8e04fee07d774fc10a8156f |
| news-coverage | 20260825-162516-5cbb56c5d92e481b807116b6789652b0 | protocol-contracts.csv | e8b262dfd2fb1fc81f472811348c8a88ae453138e5d791a229754d3d4e8de774 |
| news-coverage | 20260825-162516-5cbb56c5d92e481b807116b6789652b0 | acquisition-object-summary.csv | f353659d50a33feb124cef2b52687cd520327045642e1dd41a6bfec5e25ff014 |
| news-coverage | 20260825-162516-5cbb56c5d92e481b807116b6789652b0 | factor-table-counts.csv | 3e17e269c620cc0dce914bfc14a41573bc410098c86b3e190a057f76e28b5854 |
| news-coverage | 20260825-162516-5cbb56c5d92e481b807116b6789652b0 | latest-run-events.csv | 4502e546078f32ec18bc610590d1d47c324d7f2bba02434d91545f9a52aadc5a |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | diagnosis-checks.csv | 8d23a89b30373e1ba570adef082793500307db1721ad2ad4bc7316d3a905a23d |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | event-type-summary.csv | 5bcf1d80f1e664a561633bb96edf2e07e8d5d8ff2448576e228506b1366b25c9 |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | object-accounting.csv | c9ec753c73d5c30d50fd331efdef1ffde0a8995534e7b08a9895edf09ea7c321 |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | completed-event-accounting.csv | c031debd78db071afc735ddb853f21160c713044d568c16fbcc6566a2758ef0e |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | duplicate-non-null-payload-hashes.csv | 26a666d64b369354050e1a01e794b4e0b586a3dbde7fc848593d17e6bec78d6c |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | null-payload-hash-rows.csv | 987737c6848524757780c3c76558c1c5deaffa1a31f92eeb6bd85c67e0b0b069 |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | completed-event-gaps.csv | 484a77433a4f5e28c41e612d8a24ccb0ede42b1502f507a6f7e52ebc44b5ae85 |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | latest-100-non-completion-events.csv | f7106d62278c96436bf0bbce6ef82895e31a3c908ceba4263472121f0305fa57 |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | asrp-hype-tables.csv | 825c740ea0825250e71ccf090cc6ca82f3b97db8798661abf1c1d6f7eef35372 |
| news-diagnosis | 20260825-162517-bc80b1b868854effacb38acbdc18f7dc | core-table-columns.csv | 397483113e9974e854baa46fa220269f6fbedb88f454064e9b55a090541e04b8 |

