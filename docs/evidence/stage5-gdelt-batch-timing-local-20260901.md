# CFA Stage 5 GDELT batch-timing local validation — 2026-09-01

Status: **BATCH_TIMING_LOCAL_PASS / CFA-S5-013_PASS / CFA-S5-011_PASS / NEWS_DEFINITION_PROMOTION_PENDING**

## Authority and purpose

This evidence records the direct local execution of the offline Stage 5 batch-timing validator against the exact frozen Stage 3 V6 match artifact, frozen Stage 4 response artifact, and the source-slot artifact produced by the successful Stage 5 news-window coverage diagnostic.

The timing semantics and one-heartbeat safety policy are defined in:

- `docs/evidence/stage5-gdelt-batch-time-authority-20260901.md`;
- `docs/evidence/stage5-factor-contract.md`.

No provider API, cloud metadata, PostgreSQL query, new source acquisition, interpolation, or reconstructed external implementation is used by this validation.

## Executable

`Validate-CfaStage5GdeltBatchTiming.ps1`

Validated executable branch head before local execution:

`c5530a940ce106180baf55efdc6f734074de8144`

The executable passed PowerShell 7 parsing, Windows PowerShell 5.1 parsing, shifted-window self-tests, and an offline/fail-closed CI guard.

## Local inputs

Stage 3 V6 matches:

`D:\CFA-bulk\analysis\stage3-news-matching\20260830-151943-v6-finalization-894287a3\v6\stage3-news-matches.csv`

Stage 4 frozen responses:

`C:\Users\Emmanuel\Documents\CFA-local\stage4-responses-v3\20260830-210449-42a1dd2ba1904e778c11deede2cfe314\stage4-responses-v3.csv`

Stage 5 news-window coverage receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-news-window-coverage\20260901-181131-76831627e2864f80b23d02a36003aa81\stage5-news-window-coverage.json`

Local validation receipt emitted:

`C:\Users\Emmanuel\Documents\CFA-local\stage5-gdelt-batch-timing\20260901-184012-c255c00ff2404935b01068736c8e5625\stage5-gdelt-batch-timing.json`

## Direct observed results

```text
CFA STAGE 5 GDELT BATCH TIMING VALIDATION: PASS
V6 rows / matched assets / distinct records: 22060 / 282 / 18503
Record/archive mismatches: 0
Misaligned batch timestamps: 0
Batch timestamps not on downloaded slots: 0
gdelt_date_utc equals / differs from batch: 22060 / 0
gdelt_date_utc - batch seconds min / max: 0 / 0
24h lag15 complete response days: 68 / 91
24h lag15 available / source-incomplete / outside-population response rows: 27267 / 9518 / 273
6h lag15 complete response days: 72 / 91
6h lag15 available / source-incomplete / outside-population response rows: 28849 / 7936 / 273
CFA-S5-013 V6 batch-timestamp reconciliation: PASS
CFA-S5-011 historical information-availability policy: PASS
CFA-S5-007 news factor definitions: UNVERIFIED
```

## Reconciliation decision

All **22,060** retained V6 rows satisfy the required batch/source-lineage checks:

- zero record-ID/archive timestamp mismatches;
- zero non-15-minute-aligned batch timestamps;
- zero retained batch timestamps outside downloaded frozen source slots;
- exact V6 cardinalities remain 22,060 retained asset/news rows, 282 matched assets, and 18,503 distinct records.

The local run also observed `gdelt_date_utc == B(r)` for all 22,060 retained rows. This equality is recorded as an observation only; the leakage-control contract continues to use the source-supported record-ID batch timestamp `B(r)`, not the field name `gdelt_date_utc`, as the availability clock.

Under the conservative policy:

`A_NEWS(r) = B(r) + 15 minutes`

the shifted source-window accounting is:

- 24-hour: **27,267 available / 9,518 source-incomplete / 273 outside-population** response rows, with **68 / 91** complete response days;
- 6-hour: **28,849 available / 7,936 source-incomplete / 273 outside-population** response rows, with **72 / 91** complete response days.

Each partition reconciles to the frozen **37,058** Stage 4 response rows.

## Gate adjudication

`CFA-S5-013 = PASS` — exact V6 record-batch timestamps, archive lineage, downloaded source-slot lineage, alignment, and shifted lag-15 windows reconcile.

`CFA-S5-011 = PASS` — the historical information-availability policy `A_NEWS(r)=B(r)+15 minutes` is validated against every retained V6 row and the frozen source-slot manifest.

`CFA-S5-007` remains `UNVERIFIED` in this receipt only because definition promotion is a separate contract action. The source/timing evidence required for that promotion is now PASS.
