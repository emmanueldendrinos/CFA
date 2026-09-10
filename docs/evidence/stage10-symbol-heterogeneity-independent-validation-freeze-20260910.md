# CFA Stage 10 per-symbol heterogeneity independent-validation freeze — 2026-09-10

Status: **INDEPENDENT_SYMBOL_HETEROGENEITY_VALIDATION_PASS / CFA-S10-007_PASS / CFA-S10-008_PASS / STAGE10_FROZEN**

## Frozen entry

Stage 10 is subordinate to the CFA Source of Truth and enters from frozen Stage 9 commit `67001683d86338388e1535084335f739363c2159`.

Frozen upstream model-ready CSV SHA-256: `fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024`.

Frozen Stage 9 independent-validation receipt SHA-256: `fee93242132aa46dd11a6f969a49679d51559533a9870255cc928f4a875079bf`.

## Independently validated Stage 10 run

Run receipt SHA-256: `5736a74a5d20021b88589e066ad0a98b3ea7efc5d346c3413e2298b7c007bf34`.

Independent-validation receipt SHA-256: `5f65a24eebbe386dfed2ac840ff0cd730b3b8eb0b17b2ff05e34e70a4a050c85`.

Independent-validation checks SHA-256: `8cac50bef8f498f5090a13304cb611987ee02a52c611648194ee58a69e7c88df`.

The independent validator reproduced the Stage 10 per-symbol sensitivity calculations, temporal-stability calculations, daily market reference, rolling symbol-relative event thresholds, rolling symbol-specific market fits, news-burst indicators, row-level event attribution labels, summary counts, and candidate output hashes without importing the Stage 10 production calculation script.

## Frozen output hashes

- symbol news sensitivity: `94887a0473f909302c8154e362602776625f0d326c406e72c3cb97dc92e18df1`;
- temporal stability: `5a48c47af45cfa25a45af391b7f4d04b3685c34db3043fa58b257e8641571cee`;
- symbol profile summary: `2d625ed8a79f17cf2a6ac21e22fea62fa3a1a04f9cfa51d9b0ec7ef861e304fd`;
- market reference: `9954083409423fb58f1dedc761bac1fe570dcf89b88f4a4bb92cf0891704d86e`;
- event attribution: `37f3a22060337be4a5ecb972589b341005b65c6edcb775659e817307315ef6b6`;
- event attribution summary by symbol: `6a138a99f262f7ca7a6591bcc659a91a66880a55be7293c26e6f35c6b0310050`.

## Frozen population summary

- model-ready rows: **26,337**;
- base assets: **418**;
- response days represented in the non-embargo model-ready rows: **66**;
- symbols with sufficient ALL-period 24h news support under the predeclared Stage 10 rule: **83**;
- symbols with at least one `NEWS_ASSOCIATED_ABNORMAL` large-move event: **32**;
- symbols with at least one `MARKET_DOMINANT` large-move event: **330**.

These counts are descriptive of the frozen Q2 2025 analysis population. They are not production alert thresholds.

## Interpretation boundary

Stage 10 establishes that per-symbol heterogeneity is material and must be preserved. It does not authorize replacing unsupported symbols with pooled estimates, does not establish causality between news and returns, and does not validate a live scanner.

`NEWS_ASSOCIATED_ABNORMAL` means that, for a retrospectively identified large move, at least one symbol-relative news-burst indicator was true and the absolute abnormal-return component exceeded the absolute estimated market component. It is an association/attribution diagnostic, not proof that news caused the move.

The live scanner remains **BLOCKED** until a separate contract defines scan timestamp grain, current-time market reference, symbol-relative news-surprise construction, historical-profile use, support/confidence handling, alert score, thresholds, state machine, leakage controls, and validation plan.

## Gates

| ID | Requirement | Frozen status |
|---|---|---|
| `CFA-S10-001` | Reconcile frozen Stage 9 / Stage 7 entry | PASS |
| `CFA-S10-002` | Compute per-symbol news sensitivity/support diagnostics | PASS |
| `CFA-S10-003` | Compute per-symbol temporal stability | PASS |
| `CFA-S10-004` | Construct diagnostic broad-market reference | PASS |
| `CFA-S10-005` | Construct rolling symbol-relative news-burst measures | PASS |
| `CFA-S10-006` | Produce large-move realized event-attribution labels | PASS |
| `CFA-S10-007` | Independently validate exact Stage 10 outputs | PASS |
| `CFA-S10-008` | Freeze per-symbol findings / scanner prerequisites | PASS |

Stage 10 is frozen. Subsequent scanner work must start from these exact frozen outputs and must not mutate Stage 10.