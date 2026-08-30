# CFA Stage 3 Simple Kraken / GDELT News Matching Contract V1

Status: **SUPERSEDED_AFTER_CFA-S3-005_FAIL**

This file records the status of the original Stage 3 matching definition. The original detailed V1 definition remains available in Git history through commit `5f7d0bf2d20ce61830fe4c481767aa74887dbb58` and its descendants before the 2026-08-30 review adjudication.

## Why V1 was superseded

The full Q2 V1 execution was mechanically adjudicated PASS for source shape and deterministic output accounting after the byte-for-byte source reconciliation established the corrected 9,183,757-row corpus. However, direct bounded semantic review on 2026-08-30 found obvious false positives.

The review evidence is:

- `docs/evidence/stage3-bounded-sample-review-20260830.md`
- reviewed sample SHA-256: `6f1e9e25c768475191b4d2624bb6898e6d52680ad17c82c1dc08165a04ea6615`

Blocking examples included default Kraken symbol aliases matched case-insensitively inside ordinary page-title language (`Near-Term`, `Short-Term`, `Sky-High`, and `grass`) and generic standalone `coin` supplying false crypto context.

Therefore:

- `CFA-S3-005`: **FAIL** for V1
- `CFA-S3-006`: **BLOCKED** for V1
- V1 match outputs must not be used for response or factor design.

## Active successor

The active matching definition is now the execution-unverified candidate:

- `docs/evidence/stage3-news-matching-v2-contract.md`
- implementation: `scripts/windows/Run-CfaStage3NewsMatchingParallelV2.ps1`

V2 requires case-sensitive evidence for default Kraken symbol-only aliases and uses a narrower crypto-specific page-title context vocabulary. V2 must complete a fresh full-Q2 run and bounded semantic review before any news-matching freeze is permitted.
