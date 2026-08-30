# CFA Stage 3 V5 bounded semantic review — 2026-08-30

Source review CSV SHA-256: `b9a46da36fa567d20caba9bf4a6eb25a0cd2d285c51d42e5d967caf82c74c5a1`.

Candidate receipt matching contract: `CANDIDATE_V5`.

Review rows: **31**. Every deterministic row was directly inspected. The uploaded review CSV hash was verified byte-for-byte against the candidate receipt before review.

Result: **FAIL**. One blocking false positive was found; the other 30 rows had no obvious blocking false positive or false negative.

| Row | Decision | Observation |
|---|---|---|
| `S3V5R-001` | PASS | Binance Coin is a directly relevant altcoin example in the reviewed source context. |
| `S3V5R-002` | PASS | Bitcoin Cash is directly represented in the reviewed altcoin source context. |
| `S3V5R-003` | PASS | Internet Computer is explicit in the page title. |
| `S3V5R-004` | PASS | Internet Computer is explicit in the page title. |
| `S3V5R-005` | PASS | Render Network is explicit in the page title. |
| `S3V5R-006` | PASS | Render Network is explicit in the page title. |
| `S3V5R-007` | PASS | Shiba Inu is explicit in the page title. |
| `S3V5R-008` | PASS | Shiba Inu is explicit in the page title. |
| `S3V5R-009` | PASS | Render is explicit in a crypto-buying headline and the structured alias evidence is consistent. |
| `S3V5R-010` | PASS | The source body explicitly discusses Artificial Superintelligence Alliance (FET). |
| `S3V5R-011` | PASS | The source body explicitly reports Shiba Inu among major altcoins. |
| `S3V5R-012` | PASS | The source identifies K9 Finance as a Shibarium validator and part of the Shiba Inu ecosystem. |
| `S3V5R-013` | PASS | Aptos is explicit in the page title. |
| `S3V5R-014` | PASS | Arbitrum is explicit in the page title. |
| `S3V5R-015` | PASS | Render Token is explicit in the page title. |
| `S3V5R-016` | PASS | The source body explicitly discusses Artificial Superintelligence Alliance in the AI-token rally. |
| `S3V5R-017` | PASS | Optimism and ticker `(OP)` are explicit in a price headline. |
| `S3V5R-018` | PASS | Optimism and ticker `(OP)` are explicit in a trading-volume headline. |
| `S3V5R-019` | PASS | Notcoin and ticker `(NOT)` are explicit in a price/exchange headline. |
| `S3V5R-020` | PASS | FLR is explicit in a crypto-gainers headline referring to Flare. |
| `S3V5R-021` | PASS | Arweave and ticker `(AR)` are explicit in a price headline. |
| `S3V5R-022` | PASS | Gravity and ticker `(G)` are explicit in a trading-volume headline. |
| `S3V5R-023` | PASS | `OM` is an explicit standalone ticker in a crypto-market rally headline. |
| `S3V5R-024` | **FAIL** | `IP` was matched in the title phrase `IP Exchange`, but direct inspection of the source identifies the project as **IP Exchange ($IPX)**. The article says IPX is built on the Story blockchain; it is not a Story `(IP)` asset headline. This is an obvious false positive for base asset `IP`. Source: `https://insidebitcoins.com/sponsored/new-cryptocurrency-releases-listings-presales-today-grade-ip-exchange-amalas`. |
| `S3V5R-025` | PASS | `RLC` is the Restaurant Leadership Conference acronym; rejection is correct. |
| `S3V5R-026` | PASS | `BLZ` occurs in a UNDP procurement identifier; rejection is correct. |
| `S3V5R-027` | PASS | `K` occurs in `J&K` police/cybercrime wording; rejection is correct. |
| `S3V5R-028` | PASS | `IP` means Internet Protocol/infrastructure; rejection is correct. |
| `S3V5R-029` | PASS | `OP` occurs only inside Bitcoin technical token `OP_RETURN`; rejection is correct. |
| `S3V5R-030` | PASS | Arweave `(AR)` is explicit in a market-cap headline; retention is correct. |
| `S3V5R-031` | PASS | Story `(IP)` is explicit in a price headline; retention is correct. |

## Direct-source checks used for ambiguous reviewed rows

The direct source checks confirm that the apparent title/body mismatches in rows 010, 011, 012, and 016 are legitimate asset mentions. In particular, the K9 Finance source identifies K9 as a leading liquid-staking platform and validator on Shibarium and explicitly places it in the Shiba Inu ecosystem. The blocking row 024 is different: its source labels the discussed project `IP Exchange ($IPX)` and describes it as built on Story Protocol.

## Gate result

`CFA-S3F-019 = FAIL` and `CFA-S3F-020 = BLOCKED` for V5. `CFA-S3-005 = FAIL` and `CFA-S3-006 = BLOCKED` remain unresolved.

The previously frozen UTF-8 exclusion and V5 fixes for `OP_RETURN`, `Arweave (AR)`, and `Story (IP)` remain valid. The required next correction must address only the residual short-symbol `TITLE_CRYPTO` path that admitted `IP Exchange` as Story ticker `IP`.