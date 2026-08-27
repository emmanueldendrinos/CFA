# CFA Stage 3 Kraken / GDELT News Matching Contract

Status: REVISION_FROZEN / EXACT_Q2_RERUN_UNVERIFIED

The 2026-08-27 accepted-match review of local run `20260827-141039-b007155a1589400889a8a669cecf9240` found obvious false positives. Under SoT correction and completion rules, that review invalidates the prior matching result for downstream use. This revision freezes a narrower deterministic matching rule; it does not freeze Stage 3 completion.

CoinGecko is not part of the active CFA news-analysis path. Historical provider artifacts remain only for audit lineage.

## Revision task IDs

| Task ID | Frozen requirement | Status |
|---|---|---|
| S3-PREC-001 | Preserve the 435 Kraken eligible assets, four fiat exclusions, 431 crypto-news assets, 45 approved AF-003 seed identities, and zero-collision Stage 3 alias universe | PRESERVED |
| S3-PREC-002 | Record the directly reviewed false-positive evidence and set `CFA-S3-005` to FAIL for the prior run | PASS |
| S3-PREC-003 | Separate manual-name and exchange-symbol matching semantics; no single case-insensitive matcher may govern both | IMPLEMENTATION_CANDIDATE |
| S3-PREC-004 | Tighten `XXRP|Ripple` and `SHIB|Shiba Inu` using evidence-driven match-policy overrides without changing their Stage 2 alias-identity decisions | IMPLEMENTATION_CANDIDATE |
| S3-PREC-005 | Preserve GKG parsing, source accounting, record grain, deduplication, and output lineage | IMPLEMENTATION_CANDIDATE |
| S3-PREC-006 | Parse and self-test the exact revised PowerShell artifact in Windows PowerShell 5.1 and PowerShell 7; validate full alias/override inputs | UNVERIFIED until CI passes |
| S3-PREC-007 | Rerun the exact full-Q2 matcher and repeat bounded accepted/rejected review | UNVERIFIED; local Q2 source required |
| S3-PREC-008 | Do not freeze news matching or proceed to response/factor design until revised `CFA-S3-005` passes | BLOCKED |

## Active inputs

1. `candidate-analysis/ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv` — Kraken Q2 market identities.
2. `candidate-analysis/ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv` — 45 approved seed aliases.
3. `candidate-analysis/CFA-Stage2-Alias-Semantic-Decisions.csv` — all 45 seed aliases must be `APPROVED_ALIAS_IDENTITY`; those decisions approve identity only, not Stage 3 matching semantics.
4. `candidate-analysis/CFA-Stage3-Alias-Match-Overrides.csv` — evidence-driven Stage 3 precision overrides. This file may tighten matching but may not create an alias identity.
5. Directly inspected Q2 GDELT GKG source archives verified under Stage 1.

No CoinGecko file, ID, API, contract bridge, or mapping decision participates in Stage 3.

## S3-ID-01 — deterministic news alias universe

The Kraken market universe contains 435 eligible base assets. Exactly four fiat bases with exchange symbols `AUD`, `EUR`, `GBP`, and `USD` are excluded from crypto-news matching. The active news population is therefore 431 Kraken crypto assets.

Every active Kraken asset receives its exact `base_exchange_symbol` as a default news alias with `requires_crypto_context=True`.

The 45 approved AF-003 aliases supplement these defaults. When an AF-003 alias is the same case-insensitive text as the Kraken symbol for the same asset, the AF-003 alias type and context flag override the default.

After case-insensitive normalization, one alias may map to only one Kraken asset. Any cross-asset alias collision is a blocking failure; the matcher never guesses.

The generated registry is `candidate-analysis/CFA-Stage3-News-Aliases.csv` and is reproducibly rebuilt from AF-001, AF-003, and the frozen semantic decisions before matching.

This identity universe is unchanged by the precision correction.

## Stage 3 gates after the 2026-08-27 review

| Gate | Requirement | Current status |
|---|---|---|
| S3-ID-01 | 435 Kraken assets -> exactly four fiat exclusions -> 431 news assets; all 45 AF-003 seeds included; every news asset has an alias; zero cross-asset alias collisions | PASS on current repository evidence; definition preserved |
| CFA-S3-002 | GKG record shape is exactly 27 tab-separated fields; malformed rows are rejected and counted | UNVERIFIED for revised exact-Q2 run |
| CFA-S3-003 | Matching is deterministic under the rules below; no fuzzy/entity-provider/LLM matching | REVISION_FROZEN |
| CFA-S3-004 | Full Q2 GKG scan completes with exact archive/row/reject/match accounting and no duplicate `(base_asset_id, record_id)` output | UNVERIFIED after correction; prior output invalidated |
| CFA-S3-005 | Bounded accepted/rejected samples are directly reviewed for obvious false positives and false negatives | FAIL for prior run; revised rerun review UNVERIFIED |
| CFA-S3-006 | News matching may be frozen for response/factor design only after the preceding Stage 3 gates pass | BLOCKED |

## GKG surfaces

Only these directly inspected fields are used:

- field 0: record ID
- field 1: GKG date/time value
- field 3: source common name
- field 4: document identifier
- field 8: V2Themes
- field 12: V2Persons
- field 14: V2Organizations
- field 23: AllNames
- field 26: Extras, only to read `<PAGE_TITLE>`

## Deterministic alias policies

Matching policy is derived from the already-approved alias type plus the explicit precision-override file. Overrides may only reference an alias already present in `CFA-Stage3-News-Aliases.csv`.

### `DIRECT_NAME`

Applies to approved manual name aliases with `requires_crypto_context=False`, except an explicit precision override.

The name comparison is case-insensitive. Structured surfaces require exact parsed-name equality after case folding. Page-title matching requires the whole alias phrase using Unicode letter/number boundaries.

A `DIRECT_NAME` hit is accepted without an additional context rule. The bounded review remains responsible for detecting any remaining ambiguous names.

### `CONTEXT_NAME`

Applies to approved manual name aliases with `requires_crypto_context=True`.

The alias must appear on an allowed surface and the page title must also contain asset-specific context within 24 characters of the alias. The frozen local context vocabulary is:

`token`, `tokens`, `coin`, `coins`, `stablecoin`, `stablecoins`, `price`, `prices`, `network`, `blockchain`, `protocol`, `chain`, `ecosystem`, `layer`, `mainnet`, `staking`, `trading`, `volume`, `futures`, `etf`, `exchange`, `foundation`, `labs`, `dao`, `hub`, `wallet`, `treasury`, `holder`, `holders`, `investor`, `investors`, `ceo`.

Global `ECON_BITCOIN`, a generic crypto anchor elsewhere in the title, or generic market language is not sufficient by itself. This prevents cases such as ordinary-language “optimism” in a market headline from being treated as the OP asset.

### `TITLE_CRYPTO_NAME`

This is an explicit evidence-driven tightening policy for a context-free approved manual name. The alias must appear on an allowed surface and the page title must contain at least one frozen crypto anchor.

The only initial overrides are:

- `XXRP|Ripple` — prior accepted evidence contained ordinary-language “ripple” in a Tesla article.
- `SHIB|Shiba Inu` — prior accepted evidence contained ordinary dog-breed articles.

These overrides do not alter the Stage 2 alias-identity approvals.

### `STRICT_SYMBOL_TITLE`

Applies to every `kraken_base_symbol` and `manual_core_symbol` alias.

Symbol matching is case-sensitive. A symbol candidate is accepted only when the exact-case symbol appears in the page title and has local asset/market syntax within 16 characters, or appears as a cashtag (`$SYMBOL`). The frozen local symbol-context vocabulary is:

`token`, `tokens`, `coin`, `coins`, `price`, `prices`, `trading`, `volume`, `volumes`, `rally`, `rallies`, `surge`, `surges`, `soar`, `soars`, `jump`, `jumps`, `gain`, `gains`, `drop`, `drops`, `dip`, `dips`, `fall`, `falls`, `slide`, `slides`, `bull`, `bullish`, `bear`, `bearish`, `support`, `resistance`, `futures`, `etf`, `etfs`, `staking`, `airdrop`, `airdrops`, `mainnet`, `holder`, `holders`, `investor`, `investors`.

`ECON_BITCOIN` alone is not sufficient. A case-insensitive structured-field symbol hit alone is not sufficient. This policy is intentionally conservative because the reviewed output showed collisions including one-letter symbols, generic English words, `DOGE` as a government acronym, and `ATH` as “all-time high.”

## Frozen crypto-title anchors

`TITLE_CRYPTO_NAME` uses this fixed case-insensitive title list:

`crypto`, `cryptocurrency`, `cryptocurrencies`, `blockchain`, `token`, `tokens`, `coin`, `coins`, `web3`, `defi`, `nft`, `nfts`, `staking`, `wallet`, `wallets`, `digital asset`, `digital assets`.

No other context inference is allowed.

## Record grain and deduplication

The output grain remains one row per `(base_asset_id, GKG record_id)`.

A GKG record may match multiple different Kraken assets. Multiple accepted aliases or surfaces for the same asset and record collapse into one output row while preserving matched aliases, surfaces, and context reasons.

Duplicate `(base_asset_id, record_id)` output is a blocking failure.

## Missing and malformed data

- GKG rows with field count other than 27: reject and count; do not repair.
- Malformed structured `name,offset` blocks: count the malformed block and continue with other parseable blocks.
- Empty title or V2Themes is permitted but supplies no title/context evidence.
- Empty/invalid record ID, date, or document identifier: reject and count; any such critical-row failure blocks CFA-S3-002.
- Invalid alias flags, invalid match policies, override rows that do not reference an active alias, missing aliases, fiat-count mismatch, uncovered crypto assets, or cross-asset alias collisions: blocking failure before the source scan.

## Exact Q2 outputs

The local run writes:

- `stage3-news-matches.csv`
- `stage3-context-rejects.csv`
- `stage3-match-samples.csv`
- `stage3-match-summary.json`
- `stage3-match-summary.md`

Matches and rejects are streamed to disk. Bounded samples are retained for direct review. Reject/sample evidence records the applied match policy and local evidence diagnostics. Output hashes and the alias/override input hashes are recorded in the summary.

## Validation requirement

Repository CI may prove parsing, self-tests, source/input validation, alias-universe invariants, and override integrity. It cannot prove the exact full-Q2 run because raw Q2 GDELT archives remain outside Git.

The revised matcher is therefore only a validation candidate until the exact local Q2 run passes `CFA-S3-002` and `CFA-S3-004`, and the resulting bounded accepted/rejected samples pass `CFA-S3-005`.

Any further matching correction invalidates the dependent Q2 outputs, hashes, summaries, and sample-review conclusion and requires those stages to be rerun.

## Explicit exclusions

The matcher does not use CoinGecko, fuzzy matching, LLM classification, price movement, future market responses, sentiment scores, or model outputs.

This stage defines only which GDELT records correspond to which Kraken assets. News-factor formulas, responses, leakage tests, model-ready data, and PLS remain downstream and blocked while Stage 3 is unresolved.
