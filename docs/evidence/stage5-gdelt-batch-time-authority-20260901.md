# CFA Stage 5 GDELT timing authority — 2026-09-01

Status: **DIRECT_FIRST_PARTY_EVIDENCE_INSPECTED / BATCH_TIME_POLICY_PASS / LOCAL_V6_RECONCILIATION_PASS**

## Purpose

Resolve the Stage 5 leakage question without relying on later cloud-object metadata or CFA's 2026 acquisition time.

## Directly inspected first-party GDELT evidence

1. **GDELT GKG 2.1 codebook** — official GDELT documentation states that `GKGRECORDID` has form `YYYYMMDDHHMMSS-X` or `YYYYMMDDHHMMSS-TX` and that the first portion is the full date/time of the **15-minute update batch in which the record was created**.
   - Source: https://data.gdeltproject.org/documentation/GDELT-Global_Knowledge_Graph_Codebook-V2.1.pdf

2. **Official GDELT GKG API documentation** — GDELT states that its 15-minute-resolution monitored-news timing records when an article was **seen and processed by GDELT**, and that GDELT processes monitored worldwide news every 15 minutes.
   - Source: https://blog.gdeltproject.org/announcing-our-first-api-gkg-geojson/

3. **Official GDELT timestamping methodology** — for open-web content GDELT distinguishes its retrieval/processing timing from page-claimed publication timestamps.
   - Source: https://blog.gdeltproject.org/a-behind-the-scenes-look-at-how-we-think-about-master-file-formats-and-timestamping/

4. **GDELT 2.0 release contract** — the Event and GKG streams update every 15 minutes.
   - Source: https://blog.gdeltproject.org/gdelt-2-0-our-global-world-in-realtime/

## CFA repository mapping

The frozen Stage 3 matcher explicitly maps raw GKG field index 0 to `record_id` and raw field index 1 to output `gdelt_date_utc`:

- `RecordIdIndex=0`;
- `DateIndex=1`.

Therefore the frozen V6 artifact preserves both the GKG record identifier and the separate date field.

## Approved timing decision

For retained V6 record `r`:

- `B(r)` = UTC timestamp parsed from the first 14 digits of `record_id`;
- `B(r)` is the GDELT 15-minute processing-batch timestamp according to the first-party GKG codebook;
- `gdelt_date_utc` is retained as separate source lineage and is not used merely by field name as the predictor availability clock.

Because `B(r)` has 15-minute batch resolution rather than second-level completion precision, CFA applies a conservative one-heartbeat safety lag:

`A_NEWS(r) = B(r) + 15 minutes`.

This is a CFA leakage-control policy, not a claim that the public archive file was posted exactly 15 minutes after `B(r)`. It deliberately excludes same-batch information from the batch boundary.

For predictor cutoff `d`, a retained record is timing-eligible only through `A_NEWS(r)`.

For an H-hour availability-time lookback:

`A_NEWS(r) in [d-H,d)`

which is equivalent to:

`B(r) in [d-H-15m,d-15m)`.

## Direct local reconciliation — PASS

Exact local evidence:

`docs/evidence/stage5-gdelt-batch-timing-local-20260901.md`.

The offline validator inspected the frozen V6 artifact, Stage 4 response keys, and frozen source-slot output and observed:

- **22,060 / 282 / 18,503** V6 rows / matched assets / distinct records;
- record/archive timestamp mismatches: **0**;
- non-15-minute-aligned batch timestamps: **0**;
- batch timestamps not on downloaded source slots: **0**;
- `gdelt_date_utc` equal / different from `B(r)`: **22,060 / 0**;
- `gdelt_date_utc - B(r)` seconds min/max: **0 / 0**;
- lag-15 24h partition: **27,267 available / 9,518 source-incomplete / 273 outside-population**, with **68 / 91** complete response days;
- lag-15 6h partition: **28,849 / 7,936 / 273**, with **72 / 91** complete response days.

Both partitions reconcile exactly to **37,058** frozen Stage 4 response rows.

The observed equality of `gdelt_date_utc` and the record batch timestamp is recorded as source-specific lineage. The approved rule remains based on the source-defined `record_id` batch prefix and explicit 15-minute safety lag.

## Gate decision

- `CFA-S5-013 = PASS` — V6 batch timestamps, archive identity, cadence alignment, downloaded-slot lineage, and shifted windows reconcile.
- `CFA-S5-011 = PASS` — `A_NEWS(r)=B(r)+15 minutes` is the approved historical information-availability policy for the frozen Stage 3 V6 artifact.
- The timing evidence required for `CFA-S5-007` is satisfied.

## Superseded provider-metadata exploration

The bucket-list and exact-object cloud-metadata attempts are retained as implementation lineage only. They are not part of the approved Stage 5 timing path and require no further debugging.
