# CFA Stage 3 Accepted-Match Review — 2026-08-27

Status: **FAIL**

Evidence run: `20260827-141039-b007155a1589400889a8a669cecf9240`

This review uses the directly inspected accepted rows from `stage3-news-matches.csv` supplied from the local Stage 3 run. The prior Q2 matching output is invalidated for downstream use because the accepted set contains obvious asset-identity false positives.

## Gate result

- `CFA-S3-005`: **FAIL** — obvious false positives are present in accepted matches.
- `CFA-S3-004`: **UNVERIFIED after correction** — the previous full-Q2 run completed mechanically, but its output is stale once matching semantics are corrected.
- `CFA-S3-006`: **BLOCKED** — news matching cannot be frozen for response/factor design.

## Observed false-positive classes

| Class | Accepted example | Why it is false | Required correction |
|---|---|---|---|
| Context-free ambiguous manual name | `XXRP`, record `20250513144500-438`, Financial Express Tesla headline using ordinary “ripple” | `Ripple` is valid XRP ecosystem terminology but is also an ordinary English word | Tighten the Stage 3 policy for `XXRP|Ripple` to require a crypto title anchor |
| Context-free ambiguous manual name | `SHIB`, record `20250509230000-224`, Times of India dog-breed article | `Shiba Inu` is the dog breed as well as the token name | Tighten the Stage 3 policy for `SHIB|Shiba Inu` to require a crypto title anchor |
| Default symbol treated as case-insensitive word | `TERM`, records `20250430041500-904` and `20250430043000-853`, “prison term” headlines | The exchange symbol `TERM` matched ordinary `term` | Default exchange symbols must be case-sensitive in titles and must have nearby asset-specific market syntax |
| Default symbol treated as case-insensitive word | `KEY`, record `20250508200000-1642`, “key Senate vote” | The exchange symbol `KEY` matched ordinary `key` | Same strict-symbol rule |
| Context-required common name accepted on global context | `OP`, records `20250522131500-1092` and `20250522191500-266`, “optimism” | `Optimism` can be generic market/regulatory language; global crypto context does not identify the OP asset | Require nearby asset-specific syntax for context-required manual names; symbol `OP` separately uses the strict-symbol rule |
| One-letter symbol boundary failure | `S` appears in many accepted rows, including possessives and `M&S` / `U.S.`-style text | Unicode word boundaries do not make one-letter exchange symbols semantically unique | One-letter symbols require explicit local symbol syntax such as `$S` or `S token/coin/price/...` |
| Acronym collision | `XXDG|DOGE`, record `20250512073000-186`, government DOGE article | Government DOGE is not Dogecoin | `DOGE` must be exact-case and supported by nearby asset-specific title syntax; `ECON_BITCOIN` alone is insufficient for symbols |
| Crypto-jargon collision | `ATH`, record `20250605024500-883`, NewsBTC “Bitcoin ATH Fails Hype...” | `ATH` can mean “all-time high” rather than the Kraken asset `ATH` | Strict symbol title rule; the symbol itself is not enough |
| Generic crypto vocabulary as asset symbol | `TOKEN`, multiple Sleep Token music articles | `TOKEN` is both an exchange symbol and generic/non-crypto vocabulary | Strict symbol title rule, case-sensitive and title-context constrained |
| Generic cloud vocabulary as asset symbol | `CLOUD`, multiple cloud-mining headlines | `CLOUD` is generic infrastructure language | Strict symbol title rule, case-sensitive and title-context constrained |
| Person-name collision | `TRUMP`, ordinary political Trump headlines accepted through `ECON_BITCOIN` | The person name is not automatically the `TRUMP` asset | Exact-case strict symbol evidence; `ECON_BITCOIN` alone is not sufficient |

The defect is therefore not a handful of bad records. It is a rule-class problem caused by applying one case-insensitive phrase matcher and one global context rule to both names and exchange symbols.

## Frozen correction candidate

1. Preserve the 431-asset Stage 3 alias universe and the 45 approved AF-003 alias identities unchanged.
2. Derive matching policy from alias type:
   - `DIRECT_NAME`: context-free approved manual name.
   - `CONTEXT_NAME`: approved context-required manual name with local asset-name evidence in the page title (for example `Optimism network`, `Tether CEO`, `Dai stablecoin`, `Polygon token`). Global `ECON_BITCOIN` or a generic crypto title is not sufficient by itself.
   - `STRICT_SYMBOL_TITLE`: all Kraken/default and manual symbol aliases; exact case in the title plus nearby asset-specific syntax (or a cashtag). `ECON_BITCOIN` alone is not sufficient. The same rule covers one-letter symbols and longer symbols.
3. Add two evidence-driven tightening overrides:
   - `SHIB|Shiba Inu` -> `TITLE_CRYPTO_NAME`.
   - `XXRP|Ripple` -> `TITLE_CRYPTO_NAME`.
4. Keep deterministic parsing, exact structured-name parsing, record grain, deduplication, row accounting, and all Stage 1 source expectations unchanged.
5. Rerun the exact full-Q2 matcher and repeat bounded accepted/rejected review before `CFA-S3-005` can pass.

No response, factor, model-ready dataset, or PLS work is authorized while this gate is unresolved.
