# CFA Stage 3 Simple Kraken / GDELT News Matching Contract

Status: FROZEN_DEFINITION / EXECUTION_UNVERIFIED

Scope change authorized by current user directive on 2026-08-27: CoinGecko is removed from the active CFA news-analysis path. Historical CoinGecko artifacts remain only for audit lineage and are not inputs to Stage 3.

## Active inputs

1. `candidate-analysis/ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv` — Kraken Q2 market identities.
2. `candidate-analysis/ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv` — 45 news aliases across 43 Kraken base assets.
3. `candidate-analysis/CFA-Stage2-Alias-Semantic-Decisions.csv` — every active alias must be `APPROVED_ALIAS_IDENTITY`.
4. Directly inspected Q2 GDELT GKG source archives already verified under Stage 1.

No CoinGecko file, ID, API, contract bridge, or mapping decision participates in this matching rule.

## Frozen Stage 3 gates

| Gate | Requirement | Current status |
|---|---|---|
| CFA-S3-001 | Active alias population is exactly 45 rows / 43 Kraken assets and every alias identity is approved | PASS by current repository evidence; rechecked by matcher |
| CFA-S3-002 | GKG record shape is exactly 27 tab-separated fields; malformed rows are rejected and counted | UNVERIFIED until exact Q2 matcher run |
| CFA-S3-003 | Matching is deterministic under the rules below; no fuzzy/entity-provider/LLM matching | FROZEN |
| CFA-S3-004 | Full Q2 GKG scan completes with exact archive/row/reject/match accounting and no duplicate `(base_asset_id, record_id)` output | UNVERIFIED until exact Q2 matcher run |
| CFA-S3-005 | Bounded accepted/rejected samples are directly reviewed for obvious false positives and false negatives | UNVERIFIED until exact Q2 matcher run |
| CFA-S3-006 | News matching may be frozen for response/factor design only after CFA-S3-001..005 pass | BLOCKED |

## GKG surfaces

The matcher uses only these directly inspected GKG fields:

- field 0: record ID
- field 1: GKG date/time value as supplied by GDELT
- field 3: source common name
- field 4: document identifier
- field 8: V2Themes
- field 12: V2Persons
- field 14: V2Organizations
- field 23: AllNames
- field 26: Extras, only to read `<PAGE_TITLE>`

## Simple matching rule

Alias comparison is case-insensitive.

Structured surfaces (`AllNames`, `V2Persons`, `V2Organizations`) require exact alias equality after parsing the GDELT `name,offset` blocks.

Page-title matching requires the alias as a whole phrase with Unicode letter/number boundaries. Longer aliases are tested before shorter aliases, so `Bitcoin Cash` is not reduced to `Bitcoin` at the same title position.

For `requires_crypto_context=False`:

`MATCH` if the alias appears on at least one allowed surface.

For `requires_crypto_context=True`:

`MATCH` only if the alias appears on at least one allowed surface AND at least one of the following is true:

1. V2Themes contains exact theme `ECON_BITCOIN`; or
2. page title contains a whole-word crypto anchor from this fixed list: `crypto`, `cryptocurrency`, `cryptocurrencies`, `blockchain`, `token`, `tokens`, `coin`, `coins`, `web3`, `defi`, `nft`, `nfts`, `staking`, `wallet`, `wallets`, `digital asset`, `digital assets`.

Otherwise the candidate is `REJECT_CONTEXT`.

No other context inference is permitted.

## Record grain and deduplication

The matched-news grain is one row per `(base_asset_id, GKG record_id)`.

A GKG record may match multiple different Kraken assets when the article genuinely mentions multiple approved aliases.

Multiple aliases or multiple surfaces for the same asset and record are collapsed into one match row while preserving the matched aliases and surfaces as `|`-separated lineage fields.

Duplicate `(base_asset_id, record_id)` output is a blocking failure.

## Missing and malformed data

- GKG rows with field count other than 27: reject and count; do not infer or repair.
- Malformed structured `name,offset` blocks: count the malformed block and continue with other parseable blocks in that row.
- Empty title: permitted; it simply cannot supply title matching or lexical crypto context.
- Empty V2Themes: permitted; it simply cannot supply `ECON_BITCOIN` context.
- Missing/invalid alias flags or unapproved alias identities: blocking failure before scanning source data.

## Outputs from the exact Q2 run

The matcher writes a local evidence directory containing:

- `stage3-news-matches.csv`
- `stage3-context-rejects.csv`
- `stage3-match-samples.csv`
- `stage3-match-summary.json`
- `stage3-match-summary.md`

The full matches/rejects remain local source-derived evidence. Only bounded summary/sample evidence should be published to the repository after direct review.

## Explicit exclusions

The Stage 3 matcher does not use CoinGecko, price movements, future market responses, model outputs, sentiment scores, or any information after the GKG record being classified.

This stage defines only which GDELT records correspond to which Kraken news assets. News-factor formulas are a later stage and remain undefined here.
