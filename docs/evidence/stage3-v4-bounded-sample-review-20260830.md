# CFA Stage 3 V4 bounded semantic review — 2026-08-30

Source review CSV SHA-256: `293e1c2a613d115736469a1746014d4bc9b8e5eed48dddec0f61c146c5950095`.
Review rows: 26. Direct review inspected every deterministic row.

Result: **FAIL**. Three blocking semantic errors were found; the other 23 rows had no obvious false positive/false negative.

| Row | Decision | Observation |
|---|---|---|
| `S3V4R-001` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-002` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-003` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-004` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-005` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-006` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-007` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-008` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-009` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-010` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-011` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-012` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-013` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-014` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-015` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-016` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-017` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-018` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-019` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-020` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-021` | PASS | No obvious false positive in reviewed title/context and matched surface evidence. |
| `S3V4R-022` | FAIL | Obvious false positive: OP matched inside Bitcoin technical token OP_RETURN; not Optimism. |
| `S3V4R-023` | PASS | No obvious false negative in reviewed title/context. |
| `S3V4R-024` | PASS | No obvious false negative in reviewed title/context. |
| `S3V4R-025` | FAIL | Obvious false negative: explicit asset/ticker headline "Arweave (AR)" was rejected. |
| `S3V4R-026` | FAIL | Obvious false negative: explicit asset/ticker price headline "Story (IP)" was rejected. |

## Blocking corrections

- `S3V4R-022`: `OP` was matched inside the Bitcoin technical token `OP_RETURN`. This is an obvious false positive for Optimism.
- `S3V4R-025`: `Arweave (AR)` was rejected despite explicit asset/ticker market-capitalization wording. This is an obvious false negative.
- `S3V4R-026`: `Story (IP)` was rejected despite explicit asset/ticker price wording. This is an obvious false negative.

Therefore `CFA-S3F-014 = FAIL`, `CFA-S3F-015 = BLOCKED`, `CFA-S3-005 = FAIL`, and `CFA-S3-006 = BLOCKED` for the V4 candidate.

The UTF-8 eligibility correction remains valid: the 126 excluded rows had zero overlap with V2 matches, context rejects, or samples, so this semantic failure is independent of the encoding correction.
