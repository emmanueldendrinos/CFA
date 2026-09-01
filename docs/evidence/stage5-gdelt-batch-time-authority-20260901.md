# CFA Stage 5 GDELT timing authority — 2026-09-01

Status: **DIRECT_FIRST_PARTY_EVIDENCE_INSPECTED / BATCH_TIME_POLICY_CANDIDATE / LOCAL_V6_RECONCILIATION_UNVERIFIED**

## Purpose

Resolve the Stage 5 leakage question without relying on later cloud-object metadata or CFA's 2026 acquisition time.

## Directly inspected first-party GDELT evidence

1. **GDELT GKG 2.1 codebook** — official GDELT documentation states that `GKGRECORDID` has form `YYYYMMDDHHMMSS-X` or `YYYYMMDDHHMMSS-TX` and that the first portion is the full date/time of the **15-minute update batch in which the record was created**. It gives an explicit example of a record belonging to an update batch generated at 03:30 UTC-equivalent time.
   - Source: https://data.gdeltproject.org/documentation/GDELT-Global_Knowledge_Graph_Codebook-V2.1.pdf

2. **Official GDELT GKG API documentation** — GDELT states that its 15-minute-resolution article timestamp records when an article was **seen and processed by GDELT**, and that GDELT processes worldwide monitored news every 15 minutes.
   - Source: https://blog.gdeltproject.org/announcing-our-first-api-gkg-geojson/

3. **Official GDELT timestamping methodology** — for open-web content GDELT states that retrieval completion is its public-facing authoritative timestamp rather than the page's claimed publication timestamp.
   - Source: https://blog.gdeltproject.org/a-behind-the-scenes-look-at-how-we-think-about-master-file-formats-and-timestamping/

4. **GDELT 2.0 release contract** — the Event and GKG streams update every 15 minutes.
   - Source: https://blog.gdeltproject.org/gdelt-2-0-our-global-world-in-realtime/

## CFA repository mapping

The frozen Stage 3 matcher explicitly maps raw GKG field index 0 to `record_id` and raw field index 1 to the output column `gdelt_date_utc`:

- `RecordIdIndex=0`
- `DateIndex=1`

Therefore the frozen V6 artifact already preserves both values needed to separate processing-batch timing from the article-date field.

## Timing decision candidate

For retained V6 record `r`:

- `B(r)` = UTC timestamp parsed from the first 14 digits of `record_id`;
- `B(r)` is treated as the GDELT 15-minute **processing-batch timestamp** because that is the exact semantics assigned by the first-party GKG codebook;
- `gdelt_date_utc` remains publication/article-date lineage and is **not** used as the predictor information-availability timestamp.

Because `B(r)` has 15-minute batch resolution rather than second-level completion precision, CFA proposes a conservative one-heartbeat safety lag:

`A_NEWS(r) = B(r) + 15 minutes`.

This is a CFA leakage-control policy, not a claim that the public archive file was posted exactly 15 minutes after `B(r)`. It intentionally delays every record by a complete GDELT heartbeat so same-batch records cannot enter a predictor at the batch boundary.

For predictor cutoff `d 00:00:00Z`, a retained record is timing-eligible only if:

`A_NEWS(r) < d 00:00:00Z`.

Equivalent batch condition:

`B(r) < d 00:00:00Z - 15 minutes`.

To preserve exact H-hour lookback duration in **availability-time space**, candidate H-hour windows use:

`A_NEWS(r) in [d-H, d)`

which is equivalent to:

`B(r) in [d-H-15m, d-15m)`.

## Required local validation before PASS

The policy cannot be promoted until the exact frozen V6 artifact is checked for all retained rows:

1. every `record_id` parses as a GKG 2.1 batch identifier;
2. every parsed batch timestamp is 15-minute aligned;
3. every parsed batch timestamp equals the timestamp encoded in the retained `archive_file` name;
4. every retained batch maps to a frozen Stage 1 source slot with `status='downloaded'`;
5. the shifted 24-hour and 6-hour source-slot windows are re-reconciled against the frozen 8,736-slot manifest;
6. response-row accounting remains exact, separating in-population complete windows, in-population incomplete windows, and the three response-only assets `ZAUD`, `ZEUR`, `ZGBP`;
7. `gdelt_date_utc` versus `B(r)` differences are measured for lineage but do not control availability.

Pending that direct local validation:

- `CFA-S5-013 = UNVERIFIED` — V6 batch-timestamp/source-slot reconciliation under the one-heartbeat safety rule;
- `CFA-S5-011 = UNVERIFIED` — historical information-availability policy not yet promoted;
- `CFA-S5-007 = BLOCKED` — news-factor approval remains blocked.

## Superseded provider-metadata exploration

The later cloud-object metadata attempts are retained as implementation lineage only. They are no longer the required route to resolve Stage 5 timing because the frozen V6 artifact already preserves GDELT's own record-creation batch timestamp.
