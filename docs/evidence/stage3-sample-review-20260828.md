# CFA Stage 3 corrected-run bounded sample review — 2026-08-28

Status: **FAIL**

Run: `20260828-125505-1d682a2599b245f7bdb06ce44a69764a`

The corrected full-Q2 matcher run passed source and output accounting, but the directly inspected bounded accepted/rejected sample contains obvious false positives and false negatives. Therefore `CFA-S3-005 = FAIL` and `CFA-S3-006 = BLOCKED`. The run is not usable for downstream news factors.

## Directly inspected artifacts

- `stage3-match-summary.json` SHA-256: `6a74d87afd5a747e27e6533da7948386e250a15d8e1ec433462929afae661bab`
- `stage3-match-samples.csv` SHA-256: `965e102586c6c6a6c510dae40238e8840b0ded97de2c5fa3313e22bdb9abc1f8`
- Sample rows: 4,521
- Accepted sample rows: 1,685
- Context-rejected sample rows: 2,836
- Assets represented: 378
- Asset/alias pairs represented: 415

The sample SHA-256 exactly matches the hash recorded by the corrected run summary.

## Gate result

| Gate | Result |
|---|---|
| S3-ID-01 | PASS — deterministic Kraken-internal alias-universe construction only |
| CFA-S3-002 | PASS |
| CFA-S3-003 | PASS — deterministic implementation, not semantic quality |
| CFA-S3-004 | PASS |
| CFA-S3-005 | **FAIL** |
| CFA-S3-006 | **BLOCKED** |

## Representative false positives

| Asset / alias | Record | Accepted title | Defect |
|---|---|---|---|
| `S / S` | `20250401000000-565` | `Dow Climbs 418, Nasdaq Falls 24, S&P 500 Adds 31` | One-letter symbol collides with S&P notation; generic market syntax is not identity evidence. |
| `KEY / KEY` | `20250404084500-376` | `KeyCorp (NYSE:KEY) Price Target Cut to $16.50 by Analysts at JPMorgan Chase & Co.` | Kraken symbol collides with an equity ticker. |
| `XXDG / DOGE` | `20250401073000-602` | `Elon Musk-led DOGE finally gains access to highly sensitive Federal Personnel, Payroll System` | Government DOGE acronym is accepted because ordinary-language `gains` is in the market vocabulary. |
| `UST / UST` | `20250416211500-852` | `Munis firmer as UST yields fall` | Treasury-market acronym collides with Kraken symbol. |
| `W / W` | `20250408194500-1344` | `Wayfair (NYSE:W) Stock Price Down 8% – Here's Why` | Kraken symbol collides with an equity ticker. |
| `ZETA / ZETA` | `20250402180000-2234` | `Zeta Global (NYSE:ZETA) Stock Price Up 2.5% – Should You Buy?` | Kraken symbol collides with an equity ticker. |
| `XRT / XRT` | `20250419083000-634` | `Renaissance Technologies LLC Lowers Stock Holdings in SPDR S&P Retail ETF (NYSEARCA:XRT)` | Kraken symbol collides with an ETF ticker. |
| `XRT / XRT` | `20250408121500-315` | `XRPTurbo Launches $XRT Token On Bitmart, Set To Release` | Kraken symbol collides with an unrelated crypto token; crypto syntax alone cannot prove asset identity. |
| `OP / Optimism` | `20250408131500-562` | `Investor Optimism Defies Volatility` | Common-word name is accepted because `investor` is not asset-specific context. |
| `XXLM / Stellar` | `20250409191500-826` | `Stellar 10Y Auction Prices At 2nd Highest Stop Through On Record Despite Plunge In Directs` | Common adjective is accepted because `prices` is not asset-specific context. |
| `EOS / EOS` | `20250416171500-1887` | `Gym chain EoS Fitness explores $1 billion sale, sources say` | Ambiguous acronym/name is accepted because `chain` is not asset-specific context. |
| `POL / Polygon` | `20250427123000-665` | `Polygon Live 2025 - Ticket Prices & Festival Line Up` | Common-word name is accepted because `prices` is not asset-specific context. |

## Representative false negatives

| Asset / alias | Record | Rejected title | Defect |
|---|---|---|---|
| `AVAX / AVAX` | `20250402171500-331` | `Avalanche (AVAX) To Outpace Both Bitcoin and Ethereum By End of 2029, Standard Chartered Predicts After Initiating Coverage` | Canonical same-asset name plus symbol and explicit crypto assets are rejected because no frozen local market word appears close enough. |
| `ATOM / ATOM` | `20250415164500-1558` | `Cosmos Hits Market Capitalization of $1.59 Billion (ATOM)` | Canonical same-asset name plus symbol is rejected because the local context vocabulary is incomplete. |

## Defect boundary

This is not a finite blacklist problem.

1. A Kraken exchange symbol is verified as a Kraken market identifier, but it is not globally unique news identity. The sample proves collisions with equities, ETFs, government acronyms, ordinary abbreviations, and unrelated crypto projects.
2. Zero cross-asset collision inside the 431-asset Kraken universe does not establish semantic uniqueness in external news.
3. Generic words such as `price`, `trading`, `gains`, `fall`, `support`, `investor`, and `chain` cannot independently disambiguate common-word names or symbols.
4. The present rule is both too permissive and too restrictive. Alias-specific blacklists would leave the underlying identity defect unresolved.

## Frozen remediation tasks

| Task ID | Requirement |
|---|---|
| `S3-SEM2-001` | Preserve corrected full-Q2 source/run accounting as PASS evidence while recording `CFA-S3-005 = FAIL`. |
| `S3-SEM2-002` | Treat default Kraken exchange symbols as unverified standalone news identity; Kraken-internal collision freedom is insufficient semantic approval. |
| `S3-SEM2-003` | Treat generic market/context vocabulary as insufficient standalone disambiguation for common-word or acronym aliases. |
| `S3-SEM2-004` | Return to upstream alias-identity/corroboration design before modifying matching; do not repair with row-specific or alias-specific blacklists. |
| `S3-SEM2-005` | Before another full-Q2 scan, regression-test revised semantics against the false-positive and false-negative classes in this review. |
| `S3-SEM2-006` | Only after those component/sample regressions pass may the exact full-Q2 matcher be rerun and `CFA-S3-005` reviewed again. |

Downstream response definitions, factor definitions, model-ready data, and PLS remain blocked.
