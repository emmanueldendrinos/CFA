# CFA Stage 3 Simple Kraken / GDELT News Matching Contract

Status: FROZEN_DEFINITION / EXECUTION_UNVERIFIED

CoinGecko is not part of the active CFA news-analysis path. Historical provider artifacts remain only for audit lineage.

## Active inputs

1. `candidate-analysis/ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv` — Kraken Q2 market identities.
2. `candidate-analysis/ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv` — 45 approved seed aliases.
3. `candidate-analysis/CFA-Stage2-Alias-Semantic-Decisions.csv` — all 45 seed aliases must be `APPROVED_ALIAS_IDENTITY`.
4. Directly inspected Q2 GDELT GKG source archives verified under Stage 1.

No CoinGecko file, ID, API, contract bridge, or mapping decision participates in Stage 3.

## S3-ID-01 — deterministic news alias universe

The Kraken market universe contains 435 eligible base assets. Exactly four fiat bases with exchange symbols `AUD`, `EUR`, `GBP`, and `USD` are excluded from crypto-news matching. The active news population is therefore 431 Kraken crypto assets.

Every active Kraken asset receives its exact `base_exchange_symbol` as a default news alias with `requires_crypto_context=True`.

The 45 approved AF-003 aliases supplement these defaults. When an AF-003 alias is the same case-insensitive text as the Kraken symbol for the same asset, the AF-003 alias type and context flag override the default.

After case-insensitive normalization, one alias may map to only one Kraken asset. Any cross-asset alias collision is a blocking failure; the matcher never guesses.

The generated registry is `candidate-analysis/CFA-Stage3-News-Aliases.csv` and is reproducibly rebuilt from AF-001, AF-003, and the frozen semantic decisions before matching.

## Frozen Stage 3 gates

| Gate | Requirement | Current status |
|---|---|---|
| S3-ID-01 | 435 Kraken assets -> exactly four fiat exclusions -> 431 news assets; all 45 AF-003 seeds included; every news asset has an alias; zero cross-asset alias collisions | UNVERIFIED until exact builder run on final tree |
| CFA-S3-002 | GKG record shape is exactly 27 tab-separated fields; malformed rows are rejected and counted | UNVERIFIED until exact Q2 matcher run |
| CFA-S3-003 | Matching is deterministic under the rules below; no fuzzy/entity-provider/LLM matching | FROZEN |
| CFA-S3-004 | Full Q2 GKG scan completes with exact archive/row/reject/match accounting and no duplicate `(base_asset_id, record_id)` output | UNVERIFIED until exact Q2 matcher run |
| CFA-S3-005 | Bounded accepted/rejected samples are directly reviewed for obvious false positives and false negatives | UNVERIFIED until exact Q2 matcher run |
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

## Simple matching rule

Alias comparison is case-insensitive.

Structured surfaces (`AllNames`, `V2Persons`, `V2Organizations`) require exact alias equality after parsing GDELT `name,offset` blocks.

Page-title matching requires an alias as a whole phrase using Unicode letter/number boundaries. Longer aliases are tested before shorter aliases.

For `requires_crypto_context=False`, `MATCH` if the alias appears on at least one allowed surface.

For `requires_crypto_context=True`, `MATCH` only if the alias appears on at least one allowed surface and at least one of these is true:

1. V2Themes contains exact theme `ECON_BITCOIN`; or
2. page title contains a whole-word crypto anchor from this fixed list: `crypto`, `cryptocurrency`, `cryptocurrencies`, `blockchain`, `token`, `tokens`, `coin`, `coins`, `web3`, `defi`, `nft`, `nfts`, `staking`, `wallet`, `wallets`, `digital asset`, `digital assets`.

Otherwise the candidate is `REJECT_CONTEXT`.

No other context inference is allowed.

## Record grain and deduplication

The output grain is one row per `(base_asset_id, GKG record_id)`.

A GKG record may match multiple different Kraken assets. Multiple aliases or surfaces for the same asset and record collapse into one output row while preserving matched aliases and surfaces.

Duplicate `(base_asset_id, record_id)` output is a blocking failure.

## Missing and malformed data

- GKG rows with field count other than 27: reject and count; do not repair.
- Malformed structured `name,offset` blocks: count the malformed block and continue with other parseable blocks.
- Empty title or V2Themes is permitted but supplies no title/context evidence.
- Empty/invalid record ID, date, or document identifier: reject and count; any such critical-row failure blocks CFA-S3-002.
- Invalid alias flags, missing aliases, fiat-count mismatch, uncovered crypto assets, or cross-asset alias collisions: blocking failure before the source scan.

## Exact Q2 outputs

The local run writes:

- `stage3-news-matches.csv`
- `stage3-context-rejects.csv`
- `stage3-match-samples.csv`
- `stage3-match-summary.json`
- `stage3-match-summary.md`

Matches and rejects are streamed to disk. Bounded samples are retained for direct review.

## Explicit exclusions

The matcher does not use CoinGecko, fuzzy matching, LLM classification, price movement, future market responses, sentiment scores, or model outputs.

This stage defines only which GDELT records correspond to which Kraken assets. News-factor formulas are a later stage.
