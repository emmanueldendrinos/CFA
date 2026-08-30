# CFA Stage 3 Kraken / GDELT News Matching Contract V2

Status: **CANDIDATE_V2 / EXECUTION_UNVERIFIED**

This candidate supersedes the page-title/context details of the prior Stage 3 definition because direct bounded review on 2026-08-30 found obvious false positives. It does not change source population, asset identities, output grain, or allowed GKG fields.

## Evidence requiring revision

The bounded review `docs/evidence/stage3-bounded-sample-review-20260830.md` records CFA-S3-005 = FAIL. Directly observed false positives included:

- `NEAR` from ordinary `Near-Term`;
- `TERM` from ordinary `Short-Term`;
- `SKY` from ordinary `Sky-High`;
- `GRASS` from a gardening title where ordinary `coin` incorrectly supplied crypto context.

Therefore the prior matching output is not eligible for CFA-S3-006 freeze.

## Unchanged inputs and population

- 435 eligible Kraken market assets from AF-001.
- Exactly `AUD`, `EUR`, `GBP`, and `USD` fiat bases excluded.
- 431 crypto news assets.
- Deterministically generated `candidate-analysis/CFA-Stage3-News-Aliases.csv` with 470 rows and zero cross-asset alias collisions.
- Directly reconciled Q2 GDELT GKG corpus: 7,163 archives, 9,183,757 rows, five malformed 27-field rows, zero missing critical rows.

## Alias classes

### Approved aliases

Any alias whose registry row is not exactly:

- `alias_type = kraken_base_symbol`, and
- `alias_source = AF001_KRAKEN_SYMBOL`

is treated as an approved/non-default alias. These retain case-insensitive exact matching.

### Default symbol-only aliases

Rows with exactly:

- `alias_type = kraken_base_symbol`, and
- `alias_source = AF001_KRAKEN_SYMBOL`

are treated as default symbol-only aliases.

For these aliases, both structured-surface equality and page-title phrase matching require **case-sensitive exact symbol text**. This means `BAL` may match `BAL`, but `NEAR` does not match ordinary `Near`, `TERM` does not match `Term`, `SKY` does not match `Sky`, and `GRASS` does not match `grass`.

No fuzzy, stemming, substring, case-folded fallback, entity provider, or LLM inference is allowed for default symbol-only aliases.

## Allowed GKG surfaces

Unchanged:

- field 0: record ID
- field 1: GKG date/time
- field 3: source common name
- field 4: document identifier
- field 8: V2Themes
- field 12: V2Persons
- field 14: V2Organizations
- field 23: AllNames
- field 26: Extras, only `<PAGE_TITLE>`

## Structured-surface matching

For `AllNames`, `V2Persons`, and `V2Organizations`:

- approved aliases: exact alias equality, case-insensitive;
- default symbol-only aliases: exact alias equality, case-sensitive.

Malformed `name,offset` blocks are counted and ignored individually.

## Page-title matching

Whole-phrase Unicode letter/number boundaries remain required.

- approved aliases: case-insensitive whole-phrase match;
- default symbol-only aliases: case-sensitive whole-phrase match.

Longer aliases are still evaluated before shorter aliases within each class.

## Crypto-context rule

For `requires_crypto_context=False`, an allowed alias hit is sufficient.

For `requires_crypto_context=True`, an allowed alias hit must additionally have at least one of:

1. exact GKG theme `ECON_BITCOIN`; or
2. a page-title whole-phrase match to the fixed strong crypto vocabulary below.

Strong page-title crypto vocabulary:

- `crypto`
- `cryptocurrency`
- `cryptocurrencies`
- `blockchain`
- `web3`
- `defi`
- `nft`
- `nfts`
- `digital asset`
- `digital assets`
- `stablecoin`
- `stablecoins`
- `altcoin`
- `altcoins`
- `meme coin`
- `meme coins`

Generic words including standalone `coin`, `coins`, `token`, `tokens`, `wallet`, `wallets`, and `staking` are **not** sufficient page-title context under V2.

## Grain and deduplication

Unchanged: exactly one output row per `(base_asset_id, record_id)`. Multiple accepted aliases/surfaces for the same asset and record collapse into that row. Any duplicate output key is blocking.

## Source-shape gate

The directly reconciled source expectation is:

- archives: 7,163
- rows scanned: 9,183,757
- malformed 27-field rows: 5
- missing critical rows: 0

The superseded 9,091,236 row literal is invalid.

## Required execution sequence

1. Run `Run-CfaStage3NewsMatchingParallelV2.ps1` over the full byte-reconciled Q2 corpus.
2. Require CFA-S3-002 and CFA-S3-004 PASS with zero duplicate output keys.
3. Generate a fresh deterministic bounded sample review from the V2 output.
4. Directly review accepted and rejected samples.
5. Only if CFA-S3-005 PASS may CFA-S3-006 be set to PASS and the V2 matching definition frozen.

Until those steps complete, response and factor design remain BLOCKED.
