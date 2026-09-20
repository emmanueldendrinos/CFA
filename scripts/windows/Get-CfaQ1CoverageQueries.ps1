# Frozen Q1 evidence queries. Dot-source this file; it performs no I/O.
# The caller supplies BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY, UTC,
# a pg_catalog-only search_path, lock/statement limits, and identity checks.
# Run the schema query before the corresponding data query. All relations must
# be ordinary tables with the observed built-in column types and without RLS.

function Get-Q1SchemaQuery {
    param([ValidateSet('market','news')][string]$Kind)
    if ($Kind -eq 'market') {
        $database = 'srp'
        $schema = 'srp'
        $definitions = @{
            ohlcvt_1m_2026q1 = 'pair_id|bigint;ts_utc|timestamp with time zone;open_price|double precision;high_price|double precision;low_price|double precision;close_price|double precision;vwap|double precision;volume|double precision;trade_count|integer;source_archive_id|bigint;processing_run_id|bigint'
            market_pairs = 'pair_id|bigint;exchange|text;pair_code|text;base_asset|text;quote_asset|text;market_type|text'
            source_archives = 'source_archive_id|bigint;exchange|text;dataset_type|text;archive_name|text;period_label|text;size_bytes|bigint;sha256|character(64);zip_entry_count|integer;one_minute_files|integer;pair_count|integer;status|text;registered_at_utc|timestamp with time zone;imported_at_utc|timestamp with time zone'
            processing_runs = 'processing_run_id|bigint;process_name|text;process_version|text;source_archive_id|bigint;config_sha256|character(64);started_at_utc|timestamp with time zone;completed_at_utc|timestamp with time zone;status|text;input_rows|bigint;output_rows|bigint'
        }
    } else {
        $database = 'cfa'
        $schema = 'source_news'
        $definitions = @{
            source_contracts = 'contract_sha256|text;source_product|text;interval_start_utc|timestamp with time zone;interval_end_exclusive_utc|timestamp with time zone;cadence_minutes|integer;nominal_slot_count|integer;created_at_utc|timestamp with time zone;created_by_git_commit|text'
            source_slots = 'contract_sha256|text;object_key|text;archive_timestamp_utc|timestamp with time zone;status|text;attempt_count|integer;http_status|integer;expected_content_length|bigint;observed_size_bytes|bigint;payload_sha256|text;provider_md5_base64|text;observed_md5_base64|text;provider_md5_status|text;zip_entry_count|integer;last_attempt_at_utc|timestamp with time zone'
        }
    }
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($relation in @($definitions.Keys | Sort-Object)) {
        foreach ($definition in $definitions[$relation].Split(';')) {
            $parts = $definition.Split('|')
            $values.Add("('$schema','$relation','$($parts[0])','$($parts[1])')")
        }
    }
    $expected = $values -join ",`n"
    return @"
WITH expected(schema_name,relation_name,column_name,data_type) AS (VALUES
$expected
), wanted AS (
 SELECT DISTINCT schema_name,relation_name FROM expected
), relations AS (
 SELECT w.schema_name,w.relation_name,c.oid,c.relkind::text AS relation_kind,
        c.relispartition AS is_partition,c.relrowsecurity AS row_security,
        c.relforcerowsecurity AS force_row_security,
        pg_catalog.pg_get_expr(c.relpartbound,c.oid) AS partition_bound,
        COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'schema_name',pn.nspname,'relation_name',pc.relname,'relation_kind',pc.relkind::text)
          ORDER BY pn.nspname,pc.relname)
          FROM pg_catalog.pg_inherits i
          JOIN pg_catalog.pg_class pc ON pc.oid=i.inhparent
          JOIN pg_catalog.pg_namespace pn ON pn.oid=pc.relnamespace
          WHERE i.inhrelid=c.oid),'[]'::jsonb) AS parents
 FROM wanted w
 LEFT JOIN pg_catalog.pg_namespace n ON n.nspname=w.schema_name
 LEFT JOIN pg_catalog.pg_class c ON c.relnamespace=n.oid AND c.relname=w.relation_name
), columns AS (
 SELECT r.schema_name,r.relation_name,a.attname AS column_name,a.attnum AS ordinal_position,
        pg_catalog.format_type(a.atttypid,a.atttypmod) AS data_type,a.attnotnull AS not_null,
        tn.nspname AS type_schema,t.typname AS type_name,t.typtype::text AS type_kind
 FROM relations r JOIN pg_catalog.pg_attribute a ON a.attrelid=r.oid
 JOIN pg_catalog.pg_type t ON t.oid=a.atttypid
 JOIN pg_catalog.pg_namespace tn ON tn.oid=t.typnamespace
 WHERE a.attnum>0 AND NOT a.attisdropped
), issues AS (
 SELECT schema_name,relation_name,NULL::text AS column_name,
        'ordinary_table_without_rls_required'::text AS issue
 FROM relations WHERE relation_kind IS DISTINCT FROM 'r' OR row_security IS DISTINCT FROM false
 UNION ALL
 SELECT e.schema_name,e.relation_name,e.column_name,'missing_or_different_builtin_type'
 FROM expected e LEFT JOIN columns c USING(schema_name,relation_name,column_name)
 WHERE c.data_type IS DISTINCT FROM e.data_type OR c.type_schema IS DISTINCT FROM 'pg_catalog'
)
SELECT pg_catalog.jsonb_build_object(
 'database_name',pg_catalog.current_database(),'expected_database_name','$database',
 'read_only',pg_catalog.current_setting('transaction_read_only'),
 'transaction_isolation',pg_catalog.current_setting('transaction_isolation'),
 'time_zone',pg_catalog.current_setting('TimeZone'),
 'server_version',pg_catalog.current_setting('server_version'),
 'schema_ok',NOT EXISTS(SELECT 1 FROM issues),
 'relations',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r)-'oid' ORDER BY schema_name,relation_name) FROM relations r),'[]'::jsonb),
 'columns',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(c) ORDER BY schema_name,relation_name,ordinal_position) FROM columns c),'[]'::jsonb),
 'schema_issues',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(i) ORDER BY schema_name,relation_name,column_name) FROM issues i),'[]'::jsonb)
);
"@
}

function Get-Q1MarketSchemaQuery { return Get-Q1SchemaQuery -Kind market }
function Get-Q1NewsSchemaQuery { return Get-Q1SchemaQuery -Kind news }

function Get-Q1MarketQuery {
    param([Parameter(Mandatory=$true)][string]$ArchiveSha256)
    if ($ArchiveSha256 -cnotmatch '^[0-9a-fA-F]{64}$') { throw 'ArchiveSha256 must be exactly 64 hexadecimal characters.' }
    $archiveHash = $ArchiveSha256.ToLowerInvariant()
    # Daily aggregates are small; the 18-million-row source is never materialized.
    # The separate duplicate-key scan is required even where a catalog constraint
    # suggests uniqueness. EXISTS checks cannot multiply market rows.
    return @"
WITH daily AS MATERIALIZED (
 SELECT m.pair_id,(m.ts_utc AT TIME ZONE 'UTC')::date AS day_utc,
  count(*) AS row_count,
  count(*) FILTER(WHERE m.ts_utc>='2026-01-01T00:00:00Z'::timestamptz AND m.ts_utc<'2026-04-01T00:00:00Z'::timestamptz) AS q1_rows,
  min(m.ts_utc) AS first_timestamp_utc,max(m.ts_utc) AS last_timestamp_utc,
  min(extract(epoch FROM m.ts_utc)) FILTER(WHERE pg_catalog.isfinite(m.ts_utc))::bigint AS min_epoch,
  max(extract(epoch FROM m.ts_utc)) FILTER(WHERE pg_catalog.isfinite(m.ts_utc))::bigint AS max_epoch,
  count(*) FILTER(WHERE m.pair_id IS NULL) AS null_pair_id_rows,
  count(*) FILTER(WHERE m.ts_utc IS NULL) AS null_timestamp_rows,
  count(*) FILTER(WHERE m.open_price IS NULL) AS null_open_price_rows,
  count(*) FILTER(WHERE m.high_price IS NULL) AS null_high_price_rows,
  count(*) FILTER(WHERE m.low_price IS NULL) AS null_low_price_rows,
  count(*) FILTER(WHERE m.close_price IS NULL) AS null_close_price_rows,
  count(*) FILTER(WHERE m.vwap IS NULL) AS null_vwap_rows,
  count(*) FILTER(WHERE m.volume IS NULL) AS null_volume_rows,
  count(*) FILTER(WHERE m.trade_count IS NULL) AS null_trade_count_rows,
  count(*) FILTER(WHERE m.source_archive_id IS NULL) AS null_source_archive_id_rows,
  count(*) FILTER(WHERE m.processing_run_id IS NULL) AS null_processing_run_id_rows,
  count(*) FILTER(WHERE NOT pg_catalog.isfinite(m.ts_utc)) AS nonfinite_timestamp_rows,
  count(*) FILTER(WHERE pg_catalog.isfinite(m.ts_utc) AND m.ts_utc<>pg_catalog.date_trunc('minute',m.ts_utc)) AS off_minute_rows,
  count(*) FILTER(WHERE
    m.open_price IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8) OR
    m.high_price IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8) OR
    m.low_price IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8) OR
    m.close_price IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8) OR
    m.vwap IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8) OR
    m.volume IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8)) AS nonfinite_ohlcvt_rows,
  count(*) FILTER(WHERE
    m.open_price<=0 OR m.high_price<=0 OR m.low_price<=0 OR m.close_price<=0 OR
    m.high_price<m.low_price OR m.open_price<m.low_price OR m.open_price>m.high_price OR
    m.close_price<m.low_price OR m.close_price>m.high_price OR
    m.volume<0 OR m.trade_count<0 OR (m.vwap IS NOT NULL AND m.vwap<=0)) AS invalid_ohlcvt_rows,
  count(*) FILTER(WHERE m.pair_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM ONLY srp.market_pairs p WHERE p.pair_id=m.pair_id)) AS unknown_pair_rows,
  count(*) FILTER(WHERE m.pair_id IS NOT NULL AND EXISTS(
    SELECT 1 FROM ONLY srp.market_pairs p WHERE p.pair_id=m.pair_id AND
      (p.pair_code IS NULL OR pg_catalog.btrim(p.pair_code)='' OR p.exchange IS NULL OR pg_catalog.btrim(p.exchange)=''))) AS pair_metadata_missing_rows,
  count(*) FILTER(WHERE m.source_archive_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM ONLY srp.source_archives a WHERE a.source_archive_id=m.source_archive_id)) AS missing_source_archive_rows,
  count(*) FILTER(WHERE m.source_archive_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM ONLY srp.source_archives a WHERE a.source_archive_id=m.source_archive_id AND pg_catalog.lower(a.sha256::text)='$archiveHash')) AS nonselected_source_archive_rows,
  count(*) FILTER(WHERE m.processing_run_id IS NOT NULL AND NOT EXISTS(
    SELECT 1 FROM ONLY srp.processing_runs r WHERE r.processing_run_id=m.processing_run_id)) AS missing_processing_run_rows,
  count(*) FILTER(WHERE m.processing_run_id IS NOT NULL AND EXISTS(
    SELECT 1 FROM ONLY srp.processing_runs r WHERE r.processing_run_id=m.processing_run_id AND
      r.source_archive_id IS DISTINCT FROM m.source_archive_id)) AS processing_run_archive_mismatch_rows
 FROM ONLY srp.ohlcvt_1m_2026q1 m GROUP BY m.pair_id,(m.ts_utc AT TIME ZONE 'UTC')::date
), pair_metadata AS (
 SELECT p.pair_id,count(*) AS pair_metadata_match_count,
  CASE WHEN count(*)=1 THEN min(p.pair_code) END AS pair_code,
  CASE WHEN count(*)=1 THEN min(p.exchange) END AS exchange
 FROM ONLY srp.market_pairs p WHERE EXISTS(SELECT 1 FROM daily d WHERE d.pair_id=p.pair_id) GROUP BY p.pair_id
), per_pair AS (
 SELECT d.pair_id,p.pair_code,p.exchange,COALESCE(p.pair_metadata_match_count,0) AS pair_metadata_match_count,
  sum(d.row_count)::bigint AS row_count,sum(d.row_count)::bigint AS rows,sum(d.q1_rows)::bigint AS q1_rows,
  min(d.first_timestamp_utc) AS first_timestamp_utc,max(d.last_timestamp_utc) AS last_timestamp_utc,
  min(d.min_epoch) AS min_epoch,max(d.max_epoch) AS max_epoch
 FROM daily d LEFT JOIN pair_metadata p ON p.pair_id=d.pair_id
 GROUP BY d.pair_id,p.pair_code,p.exchange,p.pair_metadata_match_count
), per_day AS (
 SELECT day_utc,sum(row_count)::bigint AS row_count,sum(row_count)::bigint AS rows,sum(q1_rows)::bigint AS q1_rows
 FROM daily GROUP BY day_utc
), duplicates AS (
 SELECT count(*) AS duplicate_pair_time_keys,COALESCE(sum(n-1),0)::bigint AS duplicate_extra_rows
 FROM (SELECT count(*) AS n FROM ONLY srp.ohlcvt_1m_2026q1 GROUP BY pair_id,ts_utc HAVING count(*)>1) k
), referenced_ids AS MATERIALIZED (
 SELECT DISTINCT source_archive_id,processing_run_id FROM ONLY srp.ohlcvt_1m_2026q1
), archives AS (
 SELECT a.source_archive_id,a.exchange,a.dataset_type,a.archive_name,a.period_label,a.size_bytes,
  a.sha256::text AS sha256,a.zip_entry_count,a.one_minute_files,a.pair_count,a.status,
  a.registered_at_utc,a.imported_at_utc,
  pg_catalog.lower(a.sha256::text)='$archiveHash' AS matches_selected_archive_sha256,
  EXISTS(SELECT 1 FROM referenced_ids i WHERE i.source_archive_id=a.source_archive_id) AS referenced_by_observed_rows
 FROM ONLY srp.source_archives a WHERE pg_catalog.lower(a.sha256::text)='$archiveHash'
  OR EXISTS(SELECT 1 FROM referenced_ids i WHERE i.source_archive_id=a.source_archive_id)
), runs AS (
 SELECT r.processing_run_id,r.process_name,r.process_version,r.source_archive_id,r.config_sha256::text AS config_sha256,
  r.started_at_utc,r.completed_at_utc,r.status,r.input_rows,r.output_rows
 FROM ONLY srp.processing_runs r WHERE EXISTS(SELECT 1 FROM referenced_ids i WHERE i.processing_run_id=r.processing_run_id)
), summary AS (
 SELECT COALESCE(sum(row_count),0)::bigint AS total_rows,COALESCE(sum(q1_rows),0)::bigint AS q1_rows,
  COALESCE(sum(row_count-q1_rows-null_timestamp_rows),0)::bigint AS outside_q1_rows,
  min(first_timestamp_utc) AS first_timestamp_utc,max(last_timestamp_utc) AS last_timestamp_utc,
  min(min_epoch) AS min_epoch,max(max_epoch) AS max_epoch,
  count(DISTINCT pair_id) AS pair_count,count(DISTINCT day_utc) AS day_count,
  COALESCE(sum(null_pair_id_rows),0)::bigint AS null_pair_id_rows,
  COALESCE(sum(null_timestamp_rows),0)::bigint AS null_timestamp_rows,
  COALESCE(sum(null_source_archive_id_rows),0)::bigint AS null_source_archive_id_rows,
  COALESCE(sum(null_processing_run_id_rows),0)::bigint AS null_processing_run_id_rows,
  COALESCE(sum(nonfinite_timestamp_rows),0)::bigint AS nonfinite_timestamp_rows,
  COALESCE(sum(off_minute_rows),0)::bigint AS off_minute_rows,
  COALESCE(sum(nonfinite_ohlcvt_rows),0)::bigint AS nonfinite_ohlcvt_rows,
  COALESCE(sum(invalid_ohlcvt_rows),0)::bigint AS invalid_ohlcvt_rows,
  COALESCE(sum(unknown_pair_rows),0)::bigint AS unknown_pair_rows,
  COALESCE(sum(pair_metadata_missing_rows),0)::bigint AS pair_metadata_missing_rows,
  COALESCE(sum(missing_source_archive_rows),0)::bigint AS missing_source_archive_rows,
  COALESCE(sum(nonselected_source_archive_rows),0)::bigint AS nonselected_source_archive_rows,
  COALESCE(sum(missing_processing_run_rows),0)::bigint AS missing_processing_run_rows,
  COALESCE(sum(processing_run_archive_mismatch_rows),0)::bigint AS processing_run_archive_mismatch_rows,
  pg_catalog.jsonb_build_object(
   'pair_id',COALESCE(sum(null_pair_id_rows),0),'ts_utc',COALESCE(sum(null_timestamp_rows),0),
   'open_price',COALESCE(sum(null_open_price_rows),0),'high_price',COALESCE(sum(null_high_price_rows),0),
   'low_price',COALESCE(sum(null_low_price_rows),0),'close_price',COALESCE(sum(null_close_price_rows),0),
   'vwap',COALESCE(sum(null_vwap_rows),0),'volume',COALESCE(sum(null_volume_rows),0),
   'trade_count',COALESCE(sum(null_trade_count_rows),0),'source_archive_id',COALESCE(sum(null_source_archive_id_rows),0),
   'processing_run_id',COALESCE(sum(null_processing_run_id_rows),0)) AS nulls
 FROM daily
)
SELECT pg_catalog.jsonb_build_object(
 'database_name',pg_catalog.current_database(),'read_only',pg_catalog.current_setting('transaction_read_only'),
 'transaction_isolation',pg_catalog.current_setting('transaction_isolation'),'time_zone',pg_catalog.current_setting('TimeZone'),
 'server_version',pg_catalog.current_setting('server_version'),
 'interval_start_utc','2026-01-01T00:00:00Z','interval_end_exclusive_utc','2026-04-01T00:00:00Z',
 'relation','srp.ohlcvt_1m_2026q1','selected_archive_sha256','$archiveHash',
 'summary',(SELECT pg_catalog.to_jsonb(s) FROM summary s) || (SELECT pg_catalog.to_jsonb(d) FROM duplicates d) ||
   pg_catalog.jsonb_build_object('selected_archive_registration_count',(SELECT count(*) FROM archives WHERE matches_selected_archive_sha256),
    'duplicate_pair_metadata_ids',(SELECT count(*) FROM pair_metadata WHERE pair_metadata_match_count<>1),
    'duplicate_source_archive_ids',(SELECT count(*) FROM (SELECT source_archive_id FROM archives GROUP BY source_archive_id HAVING count(*)>1) x),
    'duplicate_processing_run_ids',(SELECT count(*) FROM (SELECT processing_run_id FROM runs GROUP BY processing_run_id HAVING count(*)>1) x)),
 'per_pair',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(p) ORDER BY pair_id) FROM per_pair p),'[]'::jsonb),
 'per_day',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(d) ORDER BY day_utc) FROM per_day d),'[]'::jsonb),
 'per_pair_day',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('pair_id',pair_id,'day_utc',day_utc,'row_count',row_count,'q1_rows',q1_rows) ORDER BY pair_id,day_utc) FROM daily),'[]'::jsonb),
 'source_archives',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(a) ORDER BY source_archive_id) FROM archives a),'[]'::jsonb),
 'processing_runs',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) ORDER BY processing_run_id) FROM runs r),'[]'::jsonb),
 'row_value_equivalence','UNVERIFIED','authoritative_member_lineage','UNVERIFIED','source_approval','UNVERIFIED'
);
"@
}

function Get-Q1NewsQuery {
    return @'
WITH contracts AS MATERIALIZED (
 SELECT c.contract_sha256,c.source_product,c.interval_start_utc,c.interval_end_exclusive_utc,
  c.cadence_minutes,c.nominal_slot_count,c.created_at_utc,c.created_by_git_commit,
  (c.interval_start_utc<c.interval_end_exclusive_utc AND
   c.interval_start_utc<'2026-04-01T00:00:00Z'::timestamptz AND
   c.interval_end_exclusive_utc>'2026-01-01T00:00:00Z'::timestamptz) AS overlaps_q1,
  CASE WHEN c.interval_start_utc<c.interval_end_exclusive_utc AND
   c.interval_start_utc<'2026-04-01T00:00:00Z'::timestamptz AND c.interval_end_exclusive_utc>'2026-01-01T00:00:00Z'::timestamptz
   THEN greatest(c.interval_start_utc,'2026-01-01T00:00:00Z'::timestamptz) END AS q1_overlap_start_utc,
  CASE WHEN c.interval_start_utc<c.interval_end_exclusive_utc AND
   c.interval_start_utc<'2026-04-01T00:00:00Z'::timestamptz AND c.interval_end_exclusive_utc>'2026-01-01T00:00:00Z'::timestamptz
   THEN least(c.interval_end_exclusive_utc,'2026-04-01T00:00:00Z'::timestamptz) END AS q1_overlap_end_exclusive_utc
 FROM ONLY source_news.source_contracts c
), q1 AS NOT MATERIALIZED (
 SELECT s.contract_sha256,s.object_key,s.archive_timestamp_utc,s.status,
  s.expected_content_length,s.observed_size_bytes,s.payload_sha256,
  s.provider_md5_base64,s.observed_md5_base64,s.provider_md5_status
 FROM ONLY source_news.source_slots s
 WHERE s.archive_timestamp_utc>='2026-01-01T00:00:00Z'::timestamptz AND s.archive_timestamp_utc<'2026-04-01T00:00:00Z'::timestamptz
), per_contract AS (
 SELECT s.contract_sha256,count(*) AS slot_rows,count(DISTINCT s.archive_timestamp_utc) AS distinct_timestamp_count,
  count(DISTINCT s.object_key) AS distinct_object_key_count,
  min(s.archive_timestamp_utc) AS first_timestamp_utc,max(s.archive_timestamp_utc) AS last_timestamp_utc,
  count(*) FILTER(WHERE s.payload_sha256 IS NULL OR pg_catalog.btrim(s.payload_sha256)='') AS missing_payload_sha256_rows,
  count(*) FILTER(WHERE s.payload_sha256 IS NOT NULL AND s.payload_sha256!~'^[0-9a-fA-F]{64}$') AS malformed_payload_sha256_rows,
  count(*) FILTER(WHERE s.observed_size_bytes IS NULL) AS missing_observed_size_rows,
  count(*) FILTER(WHERE s.expected_content_length IS NULL) AS missing_expected_size_rows,
  count(*) FILTER(WHERE s.observed_size_bytes<0 OR s.expected_content_length<0) AS invalid_size_rows,
  count(*) FILTER(WHERE s.observed_size_bytes IS NOT NULL AND s.expected_content_length IS NOT NULL AND s.observed_size_bytes<>s.expected_content_length) AS size_metadata_mismatch_rows,
  count(*) FILTER(WHERE s.provider_md5_status IS DISTINCT FROM 'PASS' OR
   s.provider_md5_base64 IS NULL OR pg_catalog.btrim(s.provider_md5_base64)='' OR
   s.observed_md5_base64 IS NULL OR pg_catalog.btrim(s.observed_md5_base64)='' OR
   s.provider_md5_base64 IS DISTINCT FROM s.observed_md5_base64) AS provider_md5_metadata_unverified_rows,
  count(*) FILTER(WHERE NOT EXISTS(SELECT 1 FROM contracts c WHERE c.contract_sha256=s.contract_sha256)) AS missing_contract_link_rows,
  count(*) FILTER(WHERE EXISTS(SELECT 1 FROM contracts c WHERE c.contract_sha256=s.contract_sha256 AND
   (s.archive_timestamp_utc<c.interval_start_utc OR s.archive_timestamp_utc>=c.interval_end_exclusive_utc))) AS outside_contract_window_rows
 FROM q1 s GROUP BY s.contract_sha256
), by_status_day AS (
 SELECT contract_sha256,status,(archive_timestamp_utc AT TIME ZONE 'UTC')::date AS day_utc,
  count(*) AS slot_rows,count(DISTINCT archive_timestamp_utc) AS distinct_timestamp_count,
  count(DISTINCT object_key) AS distinct_object_key_count,
  min(archive_timestamp_utc) AS first_timestamp_utc,max(archive_timestamp_utc) AS last_timestamp_utc
 FROM q1 GROUP BY contract_sha256,status,(archive_timestamp_utc AT TIME ZONE 'UTC')::date
), by_md5_status AS (
 SELECT contract_sha256,provider_md5_status,count(*) AS slot_rows FROM q1 GROUP BY contract_sha256,provider_md5_status
), all_slots AS (
 SELECT count(*) AS total_slot_rows,
  count(*) FILTER(WHERE s.archive_timestamp_utc IS NULL) AS null_timestamp_rows,
  count(*) FILTER(WHERE s.archive_timestamp_utc<'2026-01-01T00:00:00Z'::timestamptz OR s.archive_timestamp_utc>='2026-04-01T00:00:00Z'::timestamptz) AS outside_q1_slot_rows,
  count(*) FILTER(WHERE NOT EXISTS(SELECT 1 FROM contracts c WHERE c.contract_sha256=s.contract_sha256)) AS all_missing_contract_link_rows,
  count(*) FILTER(WHERE EXISTS(SELECT 1 FROM contracts c WHERE c.contract_sha256=s.contract_sha256 AND
   (s.archive_timestamp_utc<c.interval_start_utc OR s.archive_timestamp_utc>=c.interval_end_exclusive_utc))) AS all_outside_contract_window_rows
 FROM ONLY source_news.source_slots s
), q1_summary AS (
 SELECT count(*) AS q1_slot_rows,count(DISTINCT s.archive_timestamp_utc) AS distinct_timestamp_count,
  count(DISTINCT s.object_key) AS distinct_object_key_count,count(DISTINCT s.contract_sha256) AS distinct_contract_count,
  min(s.archive_timestamp_utc) AS first_timestamp_utc,max(s.archive_timestamp_utc) AS last_timestamp_utc,
  count(*) FILTER(WHERE s.object_key IS NULL OR pg_catalog.btrim(s.object_key)='') AS missing_object_key_rows,
  count(*) FILTER(WHERE s.contract_sha256 IS NULL OR pg_catalog.btrim(s.contract_sha256)='') AS missing_contract_sha256_rows,
  count(*) FILTER(WHERE s.status IS NULL OR pg_catalog.btrim(s.status)='') AS missing_status_rows
 FROM q1 s
)
SELECT pg_catalog.jsonb_build_object(
 'database_name',pg_catalog.current_database(),'read_only',pg_catalog.current_setting('transaction_read_only'),
 'transaction_isolation',pg_catalog.current_setting('transaction_isolation'),'time_zone',pg_catalog.current_setting('TimeZone'),
 'server_version',pg_catalog.current_setting('server_version'),
 'interval_start_utc','2026-01-01T00:00:00Z','interval_end_exclusive_utc','2026-04-01T00:00:00Z',
 'summary',(SELECT pg_catalog.to_jsonb(a) FROM all_slots a) || (SELECT pg_catalog.to_jsonb(q) FROM q1_summary q) ||
  pg_catalog.jsonb_build_object('contract_count',(SELECT count(*) FROM contracts),
   'q1_contract_count',(SELECT count(*) FROM contracts WHERE overlaps_q1),
   'q1_contracts_missing',NOT EXISTS(SELECT 1 FROM contracts WHERE overlaps_q1),
   'q1_slots_missing',NOT EXISTS(SELECT 1 FROM q1),
   'invalid_contract_window_count',(SELECT count(*) FROM contracts WHERE interval_start_utc IS NULL OR interval_end_exclusive_utc IS NULL OR interval_start_utc>=interval_end_exclusive_utc),
   'duplicate_contract_sha256_count',(SELECT count(*) FROM (SELECT contract_sha256 FROM contracts GROUP BY contract_sha256 HAVING count(*)>1) x)),
 'contracts',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(c) ||
   pg_catalog.jsonb_build_object('q1_slot_rows',COALESCE((SELECT p.slot_rows FROM per_contract p WHERE p.contract_sha256=c.contract_sha256),0))
   ORDER BY c.contract_sha256) FROM contracts c),'[]'::jsonb),
 'per_contract',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(c) ORDER BY contract_sha256) FROM per_contract c),'[]'::jsonb),
 'per_contract_status_day',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(d) ORDER BY contract_sha256,status,day_utc) FROM by_status_day d),'[]'::jsonb),
 'per_contract_md5_status',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(m) ORDER BY contract_sha256,provider_md5_status) FROM by_md5_status m),'[]'::jsonb),
 'payload_verification','UNVERIFIED','population_and_cadence_approval','UNVERIFIED',
 'metadata_only',true,'stage1_status','BLOCKED'
);
'@
}
