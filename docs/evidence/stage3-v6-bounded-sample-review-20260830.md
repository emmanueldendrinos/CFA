# CFA Stage 3 V6 bounded semantic review — 2026-08-30

Source review CSV SHA-256: `672700250f8848320b9aa201a45afb09e8396f305dc0c784b75d13c3cc28339a`.
Candidate matching contract: `CANDIDATE_V6`.
Candidate root: `D:\CFA-bulk\analysis\stage3-news-matching\20260830-151943-v6-finalization-894287a3`.
Review rows: **31**.

The uploaded V6 review CSV hash was verified byte-for-byte against `stage3-v6-finalization-candidate.json` before review. Every deterministic review row was directly inspected. Ambiguous non-short rows already subject to direct source inspection in the V5 review retained the same source identity and evidence; those prior source checks remain valid and are incorporated here by lineage.

Result: **PASS**. No obvious false positive or false negative remains in the deterministic V6 bounded review.

| Row | Decision | Observation |
|---|---|---|
| `S3V6R-001` | PASS | Optimism and ticker `(OP)` are explicit in a price headline; approved non-default same-record support is consistent. |
| `S3V6R-002` | PASS | Optimism and ticker `(OP)` are explicit in a trading-volume headline; approved non-default same-record support is consistent. |
| `S3V6R-003` | PASS | Binance Coin is a directly relevant altcoin observation. |
| `S3V6R-004` | PASS | Bitcoin Cash is directly represented in the reviewed altcoin context. |
| `S3V6R-005` | PASS | Internet Computer is explicit in the page title. |
| `S3V6R-006` | PASS | Internet Computer is explicit in the page title. |
| `S3V6R-007` | PASS | Render Network is explicit in the page title and structured matching surfaces. |
| `S3V6R-008` | PASS | Render Network is explicit in the page title and structured matching surfaces. |
| `S3V6R-009` | PASS | Shiba Inu is explicit in the page title. |
| `S3V6R-010` | PASS | Shiba Inu is explicit in the page title. |
| `S3V6R-011` | PASS | Render is explicit in a crypto-buying headline and structured evidence is consistent. |
| `S3V6R-012` | PASS | Artificial Superintelligence Alliance source-body evidence was directly verified in the prior V5 review and lineage is unchanged. |
| `S3V6R-013` | PASS | Shiba Inu source-body evidence was directly verified in the prior V5 review and lineage is unchanged. |
| `S3V6R-014` | PASS | K9 Finance source-body evidence was directly verified as part of the Shiba Inu/Shibarium ecosystem in the prior V5 review; lineage is unchanged. |
| `S3V6R-015` | PASS | Notcoin and ticker `(NOT)` are explicit in a price/exchange headline. |
| `S3V6R-016` | PASS | `FLR` is explicit in a crypto-gainers headline referring to Flare. |
| `S3V6R-017` | PASS | Render Token is directly identified in the source context. |
| `S3V6R-018` | PASS | Artificial Superintelligence Alliance source-body evidence was directly verified in the prior V5 review and lineage is unchanged. |
| `S3V6R-019` | PASS | Arweave and ticker `(AR)` are explicit in a price headline; parenthetical market-ticker retention is correct. |
| `S3V6R-020` | PASS | Gravity and ticker `(G)` are explicit in a trading-volume headline; parenthetical market-ticker retention is correct. |
| `S3V6R-021` | PASS | `OM` is an explicit standalone ticker in a crypto-market rally headline and satisfies V6 local market-action evidence. |
| `S3V6R-022` | PASS | `OM` is explicit in a Mantra price-crash headline and satisfies V6 local market-action evidence. |
| `S3V6R-023` | PASS | `RLC` is the Restaurant Leadership Conference acronym; rejection is correct. |
| `S3V6R-024` | PASS | `BLZ` occurs in a UNDP procurement identifier; rejection is correct. |
| `S3V6R-025` | PASS | `K` occurs in `J&K` police/cybercrime wording; rejection is correct. |
| `S3V6R-026` | PASS | `IP` means Internet Protocol/infrastructure; rejection is correct. |
| `S3V6R-027` | PASS | `IP Exchange` is the project `IP Exchange ($IPX)`, not Story ticker `IP`; V6 rejection corrects the sole V5 blocker. |
| `S3V6R-028` | PASS | `ME` occurs inside the unrelated platform name `X.ME`; rejection is correct for the Kraken `ME` asset. |
| `S3V6R-029` | PASS | `OP` occurs only inside Bitcoin technical token `OP_RETURN`; rejection remains correct. |
| `S3V6R-030` | PASS | Arweave `(AR)` is explicit in a market-cap headline; retention is correct. |
| `S3V6R-031` | PASS | Story `(IP)` is explicit in a price headline; retention is correct. |

## V6 candidate evidence

- V6 summary SHA-256: `c1741dc7ae8de4272fa3c55f59c9efb035e4e72b0c330939b1e12caa6742d20c`.
- Review summary SHA-256: `017751c3e416cd848f17b47ecd6f30dd69b825fa4aec83f1f3ed2fb7aedef7cf`.
- Review CSV SHA-256: `672700250f8848320b9aa201a45afb09e8396f305dc0c784b75d13c3cc28339a`.
- Per-asset count CSV SHA-256: `860e2d080e813677c07535ffb0b96ae069559ae722677cf2dd9129e0655d2eb3`.
- Asset/news pairs: **22,060**.
- Distinct GDELT records: **18,503**.
- Matched assets: **282**.

## Gate result

`CFA-S3F-023 = PASS` and `CFA-S3F-024 = PASS`.

The corrected V6 review resolves the current Stage 3 direct-review gate: `CFA-S3-005 = PASS`. Therefore `CFA-S3-006 = PASS` and Stage 3 news matching is frozen on the exact `CANDIDATE_V6` artifacts identified above.

Historical failures remain preserved in lineage: `CFA-S3F-008 = FAIL`, `CFA-S3F-014 = FAIL`, and `CFA-S3F-019 = FAIL`. They are not relabeled; each was resolved by an explicit downstream correction and new validation gate.
