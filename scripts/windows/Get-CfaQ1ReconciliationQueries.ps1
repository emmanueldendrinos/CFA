# Q1-MKT-001-SNAPSHOT. Dot-source only; no I/O is performed here.
# Fixed read-only PostgreSQL queries; the sole external SQL value is validated hex.

function Get-Q1ReconciliationMarketQuery {
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
  count(*) FILTER(WHERE m.vwap IS NOT NULL) AS nonnull_vwap_rows,
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
      (p.pair_code IS NULL OR p.pair_code COLLATE pg_catalog."C" !~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' OR p.exchange IS DISTINCT FROM 'Kraken'))) AS pair_metadata_missing_rows,
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
), duplicates AS (
 SELECT count(*) AS duplicate_pair_time_keys,COALESCE(sum(n-1),0)::bigint AS duplicate_extra_rows
 FROM (SELECT count(*) AS n FROM ONLY srp.ohlcvt_1m_2026q1 GROUP BY pair_id,ts_utc HAVING count(*)>1) k
), referenced_ids AS MATERIALIZED (
 SELECT DISTINCT source_archive_id,processing_run_id FROM ONLY srp.ohlcvt_1m_2026q1
), archives AS (
 SELECT a.source_archive_id,a.exchange,a.dataset_type,a.archive_name,a.period_label,a.size_bytes,
  a.sha256::text AS sha256,a.zip_entry_count,a.one_minute_files,a.pair_count,a.status,
  a.registered_at_utc,a.imported_at_utc,a.inventory_json_path,a.inventory_csv_path,
  pg_catalog.lower(a.sha256::text)='$archiveHash' AS matches_selected_archive_sha256,
  EXISTS(SELECT 1 FROM referenced_ids i WHERE i.source_archive_id=a.source_archive_id) AS referenced_by_observed_rows
 FROM ONLY srp.source_archives a WHERE pg_catalog.lower(a.sha256::text)='$archiveHash'
  OR EXISTS(SELECT 1 FROM referenced_ids i WHERE i.source_archive_id=a.source_archive_id)
), runs AS (
 SELECT r.processing_run_id,r.process_name,r.process_version,r.source_archive_id,r.config_sha256::text AS config_sha256,
  r.started_at_utc,r.completed_at_utc,r.status,r.input_rows,r.output_rows,
  pg_catalog.jsonb_typeof(r.config_json) AS config_json_type,
  COALESCE((SELECT pg_catalog.jsonb_agg(k.key ORDER BY k.key COLLATE pg_catalog."C")
    FROM pg_catalog.jsonb_object_keys(CASE WHEN pg_catalog.jsonb_typeof(r.config_json)='object'
      THEN r.config_json ELSE '{}'::jsonb END) AS k(key)),'[]'::jsonb) AS config_key_names,
  pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(r.config_json::text,'UTF8')),'hex') AS observed_config_json_text_sha256
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
  COALESCE(sum(nonnull_vwap_rows),0)::bigint AS nonnull_vwap_rows,
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
), validation_issues AS (
 SELECT 'empty_market_population' AS issue FROM summary WHERE total_rows=0
 UNION ALL
 SELECT 'market_row_invariants' FROM summary WHERE
  outside_q1_rows<>0 OR null_pair_id_rows<>0 OR null_timestamp_rows<>0 OR
  null_source_archive_id_rows<>0 OR null_processing_run_id_rows<>0 OR nonnull_vwap_rows<>0 OR
  nonfinite_timestamp_rows<>0 OR off_minute_rows<>0 OR nonfinite_ohlcvt_rows<>0 OR
  invalid_ohlcvt_rows<>0 OR unknown_pair_rows<>0 OR pair_metadata_missing_rows<>0 OR
  missing_source_archive_rows<>0 OR nonselected_source_archive_rows<>0 OR
  missing_processing_run_rows<>0 OR processing_run_archive_mismatch_rows<>0 OR
  EXISTS(SELECT 1 FROM pg_catalog.jsonb_each_text(nulls) n WHERE n.key<>'vwap' AND n.value::bigint<>0)
 UNION ALL
 SELECT 'duplicate_pair_time_keys' FROM duplicates WHERE duplicate_pair_time_keys<>0
 UNION ALL
 SELECT 'nonunique_pair_metadata' WHERE EXISTS(SELECT 1 FROM pair_metadata WHERE pair_metadata_match_count<>1)
 UNION ALL
 SELECT 'duplicate_pair_codes' WHERE EXISTS(SELECT pg_catalog.lower(pair_code COLLATE pg_catalog."C")
  FROM pair_metadata GROUP BY pg_catalog.lower(pair_code COLLATE pg_catalog."C") HAVING count(*)>1)
 UNION ALL
 SELECT 'nonunique_selected_archive' WHERE (SELECT count(*) FROM archives WHERE matches_selected_archive_sha256)<>1
 UNION ALL
 SELECT 'duplicate_archive_id' WHERE EXISTS(SELECT source_archive_id FROM archives GROUP BY source_archive_id HAVING count(*)>1)
 UNION ALL
 SELECT 'duplicate_run_id' WHERE EXISTS(SELECT processing_run_id FROM runs GROUP BY processing_run_id HAVING count(*)>1)
 UNION ALL
 SELECT 'archive_registration_metadata' WHERE EXISTS(SELECT 1 FROM archives WHERE
  exchange IS DISTINCT FROM 'Kraken' OR dataset_type IS DISTINCT FROM 'OHLCVT' OR
  archive_name IS DISTINCT FROM 'Kraken_OHLCVT_Q1_2026.zip' OR period_label IS DISTINCT FROM '2026-Q1' OR
  size_bytes IS NULL OR size_bytes<=0 OR zip_entry_count IS NULL OR zip_entry_count<=0 OR
  one_minute_files IS DISTINCT FROM (SELECT pair_count FROM summary) OR
  pair_count IS DISTINCT FROM (SELECT pair_count FROM summary) OR
  referenced_by_observed_rows IS DISTINCT FROM true OR matches_selected_archive_sha256 IS DISTINCT FROM true)
 UNION ALL
 SELECT 'run_archive_mismatch' WHERE EXISTS(SELECT 1 FROM runs r WHERE NOT EXISTS(
  SELECT 1 FROM archives a WHERE a.source_archive_id=r.source_archive_id AND a.matches_selected_archive_sha256))
 UNION ALL
 SELECT 'pair_day_population_bound' WHERE EXISTS(SELECT 1 FROM daily WHERE row_count>1440)
), metadata AS (
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
 'source_archives',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(a) ORDER BY source_archive_id) FROM archives a),'[]'::jsonb),
 'processing_runs',COALESCE((SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) ORDER BY processing_run_id) FROM runs r),'[]'::jsonb),
 'row_value_equivalence','UNVERIFIED','authoritative_member_lineage','UNVERIFIED','source_approval','UNVERIFIED',
 'prevalidation_ok',NOT EXISTS(SELECT 1 FROM validation_issues),
 'prevalidation_issues',COALESCE((SELECT pg_catalog.jsonb_agg(issue ORDER BY issue) FROM validation_issues),'[]'::jsonb)
) AS metadata
)
SELECT metadata AS json,NOT EXISTS(SELECT 1 FROM validation_issues) AS ok FROM metadata
"@
}

function Get-Q1ReconciliationSchemaQuery {
    $database = 'srp'
    $schema = 'srp'
    $definitions = @{
        ohlcvt_1m_2026q1 = 'pair_id|bigint;ts_utc|timestamp with time zone;open_price|double precision;high_price|double precision;low_price|double precision;close_price|double precision;vwap|double precision;volume|double precision;trade_count|integer;source_archive_id|bigint;processing_run_id|bigint'
        market_pairs = 'pair_id|bigint;exchange|text;pair_code|text;base_asset|text;quote_asset|text;market_type|text'
        source_archives = 'source_archive_id|bigint;exchange|text;dataset_type|text;archive_name|text;period_label|text;size_bytes|bigint;sha256|character(64);zip_entry_count|integer;one_minute_files|integer;pair_count|integer;status|text;registered_at_utc|timestamp with time zone;imported_at_utc|timestamp with time zone;inventory_json_path|text;inventory_csv_path|text'
        processing_runs = 'processing_run_id|bigint;process_name|text;process_version|text;source_archive_id|bigint;config_sha256|character(64);started_at_utc|timestamp with time zone;completed_at_utc|timestamp with time zone;status|text;input_rows|bigint;output_rows|bigint;config_json|jsonb'
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
 FROM relations WHERE relation_kind IS DISTINCT FROM 'r' OR row_security IS DISTINCT FROM false OR force_row_security IS DISTINCT FROM false
 UNION ALL
 SELECT e.schema_name,e.relation_name,e.column_name,'missing_or_different_builtin_type'
 FROM expected e LEFT JOIN columns c USING(schema_name,relation_name,column_name)
 WHERE c.data_type IS DISTINCT FROM e.data_type OR c.type_schema IS DISTINCT FROM 'pg_catalog'
 UNION ALL
 SELECT schema_name,relation_name,NULL::text,'q1_partition_identity_or_bounds' FROM relations
 WHERE relation_name='ohlcvt_1m_2026q1' AND (
  is_partition IS DISTINCT FROM true OR
  partition_bound IS DISTINCT FROM 'FOR VALUES FROM (''2026-01-01 00:00:00+00'') TO (''2026-04-01 00:00:00+00'')' OR
  parents IS DISTINCT FROM '[{"schema_name":"srp","relation_name":"ohlcvt_1m","relation_kind":"p"}]'::jsonb)
 UNION ALL
 SELECT schema_name,relation_name,NULL::text,'lineage_relation_inheritance' FROM relations
 WHERE relation_name<>'ohlcvt_1m_2026q1' AND (is_partition IS DISTINCT FROM false OR parents<>'[]'::jsonb)
 UNION ALL
 SELECT 'srp',NULL::text,NULL::text,'session_identity_or_safety' WHERE
  pg_catalog.current_database()<>'srp' OR
  pg_catalog.current_setting('transaction_read_only')<>'on' OR
  pg_catalog.current_setting('transaction_isolation')<>'repeatable read' OR
  pg_catalog.current_setting('TimeZone')<>'UTC' OR
  pg_catalog.current_setting('search_path')<>'pg_catalog' OR
  pg_catalog.current_setting('row_security')<>'off'
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
) AS json,NOT EXISTS(SELECT 1 FROM issues) AS ok
"@
}

function Get-Q1ReconciliationSql {
    param([Parameter(Mandatory=$true)][string]$ArchiveSha256)
    if ($ArchiveSha256 -cnotmatch '^[0-9a-fA-F]{64}$') { throw 'ArchiveSha256 must be exactly 64 hexadecimal characters.' }
    $schemaQuery = Get-Q1ReconciliationSchemaQuery
    $marketQuery = Get-Q1ReconciliationMarketQuery -ArchiveSha256 $ArchiveSha256
    # psql conditionals prevent parsing/planning source statements until the
    # catalog checks pass. Zero-row SELECTs retain relation read locks, then the
    # same catalog checks run again. No function, table or temp object is created.
    # Statement/connect/process limits are supplied by the bound runner.
    return @"
\set ON_ERROR_STOP on
\set QUIET on
\echo Q1_PHASE_SESSION_SETUP
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL TimeZone = 'UTC';
SET LOCAL DateStyle = 'ISO, YMD';
SET LOCAL search_path = pg_catalog;
SET LOCAL row_security = off;
SET LOCAL lock_timeout = '5s';
SET LOCAL standard_conforming_strings = on;
\echo Q1_PHASE_SCHEMA_INITIAL
$schemaQuery
\gset q1_schema_
\if :q1_schema_ok
\echo Q1_PHASE_LOCK_PAIRS
SELECT 1 FROM ONLY srp.market_pairs WHERE false;
\echo Q1_PHASE_LOCK_ARCHIVES
SELECT 1 FROM ONLY srp.source_archives WHERE false;
\echo Q1_PHASE_LOCK_RUNS
SELECT 1 FROM ONLY srp.processing_runs WHERE false;
\echo Q1_PHASE_LOCK_MARKET
SELECT 1 FROM ONLY srp.ohlcvt_1m_2026q1 WHERE false;
\echo Q1_PHASE_SCHEMA_RECHECK
$schemaQuery
\gset q1_schema_
\endif
\echo Q1_PHASE_SCHEMA_TRANSPORT
SELECT E'SCHEMA\t' || :'q1_schema_json';
\if :q1_schema_ok
\echo Q1_PHASE_MARKET_PREVALIDATION
$marketQuery
\gset q1_market_
\echo Q1_PHASE_MARKET_TRANSPORT
SELECT E'MARKET\t' || :'q1_market_json';
\if :q1_market_ok
\echo Q1_PHASE_DIGESTS
\echo DIGESTS
SELECT E'pair_id\tday_utc\trows\tmin_epoch\tmax_epoch\tsha256';
WITH row_bytes AS (
 SELECT m.pair_id,m.ts_utc,(m.ts_utc AT TIME ZONE 'UTC')::date AS day_utc,
  extract(epoch FROM m.ts_utc)::bigint AS epoch_seconds,
  pg_catalog.int8send(extract(epoch FROM m.ts_utc)::bigint) ||
  pg_catalog.float8send(CASE WHEN m.open_price=0 THEN 0::float8 ELSE m.open_price END) ||
  pg_catalog.float8send(CASE WHEN m.high_price=0 THEN 0::float8 ELSE m.high_price END) ||
  pg_catalog.float8send(CASE WHEN m.low_price=0 THEN 0::float8 ELSE m.low_price END) ||
  pg_catalog.float8send(CASE WHEN m.close_price=0 THEN 0::float8 ELSE m.close_price END) ||
  pg_catalog.float8send(CASE WHEN m.volume=0 THEN 0::float8 ELSE m.volume END) ||
  pg_catalog.int4send(m.trade_count) AS record_bytes
 FROM ONLY srp.ohlcvt_1m_2026q1 m
), digests AS (
 SELECT pair_id,day_utc,count(*) AS rows,min(epoch_seconds) AS min_epoch,max(epoch_seconds) AS max_epoch,
  pg_catalog.encode(pg_catalog.sha256(pg_catalog.string_agg(record_bytes,''::bytea ORDER BY ts_utc)),'hex') AS sha256
 FROM row_bytes GROUP BY pair_id,day_utc
)
SELECT pair_id::text || E'\t' || day_utc::text || E'\t' || rows::text || E'\t' ||
 min_epoch::text || E'\t' || max_epoch::text || E'\t' || sha256
FROM digests ORDER BY pair_id,day_utc;
\else
\echo BLOCKED
\endif
\else
\echo BLOCKED
\endif
\echo Q1_PHASE_COMMIT
COMMIT;
\echo END
"@
}
