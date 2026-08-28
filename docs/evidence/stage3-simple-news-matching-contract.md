# CFA Stage 3 Kraken / GDELT News Matching Contract

Status: **FAIL**

The 2026-08-27 accepted-match review of local run `20260827-141039-b007155a1589400889a8a669cecf9240` found obvious false positives and invalidated the original matching result. A narrower deterministic rule was implemented and the corrected full-Q2 run `20260828-125505-1d682a2599b245f7bdb06ce44a69764a` subsequently passed source/output accounting, but its directly inspected bounded accepted/rejected sample also contains obvious false positives and false negatives. Therefore `CFA-S3-005 = FAIL` and Stage 3 remains blocked.

CoinGecko is not part of the active CFA news-analysis path. Historical provider artifacts remain only for audit lineage.

## Frozen revision task IDs

| Task ID | Frozen requirement |
|---|---|
| S3-PREC-001 | Preserve the 435 Kraken eligible assets, four fiat exclusions, 431 crypto-news assets, 45 approved AF-003 seed identities, and zero-collision Stage 3 alias universe. |
| S3-PREC-002 | Record the directly reviewed false-positive evidence and set `CFA-S3-005` to FAIL for the prior run. |
| S3-PREC-003 | Separate manual-name and exchange-symbol matching semantics; no single case-insensitive matcher may govern both. |
| S3-PREC-004 | Tighten `XXRP|Ripple` and `SHIB|Shiba Inu` using evidence-driven match-policy overrides without changing their Stage 2 alias-identity decisions. |
| S3-PREC-005 | Preserve GKG parsing, source accounting, record grain, deduplication, and output lineage. |
| S3-PREC-006 | Parse and self-test the exact revised PowerShell artifact in Windows PowerShell 5.1 and PowerShell 7; validate full alias/override inputs. |
| S3-PREC-007 | Rerun the exact full-Q2 matcher and repeat bounded accepted/rejected review. |
| S3-PREC-008 | Do not freeze news matching or proceed to response/factor design until revised `CFA-S3-005` passes. |

Results are recorded separately in repository CI, run evidence, and the gate table below; task requirements are not rewritten to fit implementation results.

## Frozen second remediation task IDs

The 2026-08-28 bounded review establishes a defect class that cannot be repaired with additional row-specific or alias-specific blacklists.

| Task ID | Frozen requirement |
|---|---|
| S3-SEM2-001 | Preserve the corrected full-Q2 source/run accounting as PASS evidence while recording `CFA-S3-005 = FAIL` for the bounded review. |
| S3-SEM2-002 | Treat default Kraken exchange symbols as unverified standalone news identity; zero collision inside Kraken is not sufficient semantic approval for external news. |
| S3-SEM2-003 | Treat generic market/context vocabulary as insufficient standalone disambiguation for common-word or acronym aliases. |
| S3-SEM2-004 | Return to upstream alias-identity/corroboration design before modifying matching; do not repair the defect with row-specific or alias-specific blacklists. |
| S3-SEM2-005 | Before another full-Q2 scan, regression-test revised semantics against the observed false-positive and false-negative classes recorded in `stage3-sample-review-20260828.*`. |
| S3-SEM2-006 | Only after component/sample regressions pass may the exact full-Q2 matcher be rerun and `CFA-S3-005` reviewed again. |

## Active inputs

1. `candidate-analysis/ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv` — Kraken Q2 market identities.
2. `candidate-analysis/ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv` — 45 approved seed aliases.
3. `candidate-analysis/CFA-Stage2-Alias-Semantic-Decisions.csv` — all 45 seed aliases must be `APPROVED_ALIAS_IDENTITY`; those decisions approve identity only, not Stage 3 matching semantics.
4. `candidate-analysis/CFA-Stage3-Alias-Match-Overrides.csv` — evidence-driven Stage 3 precision overrides. This file may tighten matching but may not create an alias identity.
5. Directly inspected Q2 GDELT GKG source archives verified under Stage 1 and recovered under the Stage 2 byte-diagnostic policy.

No CoinGecko file, ID, API, contract bridge, or mapping decision participates in Stage 3.

## S3-ID-01 — deterministic news alias universe

The Kraken market universe contains 435 eligible base assets. Exactly four fiat bases with exchange symbols `AUD`, `EUR`, `GBP`, and `USD` are excluded from crypto-news matching. The active mechanical news population is therefore 431 Kraken crypto assets.

Every active Kraken asset currently receives its exact `base_exchange_symbol` as a default candidate news alias with `requires_crypto_context=True`.

The 45 approved AF-003 aliases supplement these defaults. When an AF-003 alias is the same case-insensitive text as the Kraken symbol for the same asset, the AF-003 alias type and context flag override the default.

After case-insensitive normalization, one alias may map to only one Kraken asset. Any cross-asset alias collision inside the Kraken universe is a blocking failure; the matcher never guesses between Kraken assets.

The generated registry is `candidate-analysis/CFA-Stage3-News-Aliases.csv` and is reproducibly rebuilt from AF-001, AF-003, and the frozen semantic decisions.

`S3-ID-01 = PASS` proves only deterministic Kraken-internal construction and collision freedom. The 2026-08-28 review proves that this does **not** establish external-news semantic uniqueness: Kraken symbols collide with equities, ETFs, government acronyms, ordinary abbreviations, and unrelated crypto projects. Default exchange symbols therefore remain unverified as standalone news identity under `S3-SEM2-002`.

## Stage 3 gates after the 2026-08-28 review

| Gate | Requirement | Current status |
|---|---|---|
| S3-ID-01 | 435 Kraken assets -> exactly four fiat exclusions -> 431 mechanically covered news assets; all 45 AF-003 seeds included; every asset has a candidate alias; zero cross-asset collisions inside Kraken | **PASS** for deterministic construction only; not semantic news-alias approval |
| CFA-S3-002 | GKG record shape is exactly 27 tab-separated fields; malformed rows are rejected and counted | **PASS** — corrected run: 7,163 archives, 9,183,757 rows, 5 malformed field-count rows, 0 missing-critical rows |
| CFA-S3-003 | Matching is deterministic under the frozen implemented rules; no fuzzy/entity-provider/LLM matching | **PASS** for implementation determinism and self-tests; semantic quality separately fails `CFA-S3-005` |
| CFA-S3-004 | Full Q2 GKG scan completes with exact archive/row/reject/match accounting and no duplicate `(base_asset_id, record_id)` output | **PASS** — corrected run completed with 0 duplicate asset/record matches |
| CFA-S3-005 | Bounded accepted/rejected samples are directly reviewed for obvious false positives and false negatives | **FAIL** — corrected-run review found multiple blocking false-positive and false-negative classes |
| CFA-S3-006 | News matching may be frozen for response/factor design only after the preceding Stage 3 gates pass | **BLOCKED** |

The detailed corrected-run review is frozen in `docs/evidence/stage3-sample-review-20260828.md` and `.json`.

## 2026-08-28 defect boundary

The corrected-run sample demonstrates both overmatching and undermatching.

- Default exchange-symbol matches can collide with non-crypto equity/ETF tickers, government acronyms, ordinary abbreviations, and unrelated crypto projects. Examples include `KEY`, `W`, `ZETA`, `XRT`, `DOGE`, `UST`, and one-letter `S`.
- Generic market syntax such as `price`, `trading`, `gains`, `fall`, `support`, or `investor` does not establish crypto-asset identity. `DOGE` government headlines and ordinary `Optimism`/`Stellar` uses are accepted under the current rule.
- Generic organizational words such as `chain` are also not sufficient identity evidence; the sample accepts `EoS Fitness` because its title contains `chain` elsewhere.
- Conversely, legitimate corroborated crypto references can be rejected when no frozen local market word is close enough. The sample rejects titles containing `Avalanche (AVAX)` alongside Bitcoin/Ethereum and `Cosmos ... (ATOM)`.

This is a semantic identity/corroboration defect, not a finite blacklist defect. Matching changes are blocked until upstream alias/corroboration semantics are revised under the frozen `S3-SEM2-*` tasks.

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

## Deterministic alias policies — failed validation candidate

The policies below describe the exact implementation that produced corrected run `20260828-125505-1d682a2599b245f7bdb06ce44a69764a`. They remain frozen for audit reproducibility but are **not approved for downstream use** because `CFA-S3-005 = FAIL`.

Matching policy is derived from the already-approved alias type plus the explicit precision-override file. Overrides may only reference an alias already present in `CFA-Stage3-News-Aliases.csv`.

### `DIRECT_NAME`

Applies to approved manual name aliases with `requires_crypto_context=False`, except an explicit precision override.

The name comparison is case-insensitive. Structured surfaces require exact parsed-name equality after case folding. Page-title matching requires the whole alias phrase using Unicode letter/number boundaries.

A `DIRECT_NAME` hit is accepted without an additional context rule. The bounded review remains responsible for detecting any remaining ambiguous names.

### `CONTEXT_NAME`

Applies to approved manual name aliases with `requires_crypto_context=True`.

The alias must appear on an allowed surface and the page title must also contain asset-specific context within 24 characters of the alias. The frozen local context vocabulary is:

`token`, `tokens`, `coin`, `coins`, `stablecoin`, `stablecoins`, `price`, `prices`, `network`, `blockchain`, `protocol`, `chain`, `ecosystem`, `layer`, `mainnet`, `staking`, `trading`, `volume`, `futures`, `etf`, `exchange`, `foundation`, `labs`, `dao`, `hub`, `wallet`, `treasury`, `holder`, `holders`, `investor`, `investors`, `ceo`.

Global `ECON_BITCOIN`, a generic crypto anchor elsewhere in the title, or generic market language is not sufficient by itself. The 2026-08-28 review nevertheless proves that several words in the local vocabulary are not asset-specific and create false positives.

### `TITLE_CRYPTO_NAME`

This is an explicit evidence-driven tightening policy for a context-free approved manual name. The alias must appear on an allowed surface and the page title must contain at least one frozen crypto anchor.

The initial overrides are:

- `XXRP|Ripple` — prior accepted evidence contained ordinary-language “ripple” in a Tesla article.
- `SHIB|Shiba Inu` — prior accepted evidence contained ordinary dog-breed articles.

These overrides do not alter the Stage 2 alias-identity approvals.

### `STRICT_SYMBOL_TITLE`

Applies to every `kraken_base_symbol` and `manual_core_symbol` alias in the failed validation candidate.

Symbol matching is case-sensitive. A symbol candidate is accepted only when the exact-case symbol appears in the page title and has local asset/market syntax within 16 characters, or appears as a cashtag (`$SYMBOL`). The frozen local symbol-context vocabulary is:

`token`, `tokens`, `coin`, `coins`, `price`, `prices`, `trading`, `volume`, `volumes`, `rally`, `rallies`, `surge`, `surges`, `soar`, `soars`, `jump`, `jumps`, `gain`, `gains`, `drop`, `drops`, `dip`, `dips`, `fall`, `falls`, `slide`, `slides`, `bull`, `bullish`, `bear`, `bearish`, `support`, `resistance`, `futures`, `etf`, `etfs`, `staking`, `airdrop`, `airdrops`, `mainnet`, `holder`, `holders`, `investor`, `investors`.

`ECON_BITCOIN` alone is not sufficient. A case-insensitive structured-field symbol hit alone is not sufficient. The 2026-08-28 review proves this policy still fails because the symbol text itself is not globally unique and the surrounding market vocabulary is not identity evidence.

## Frozen crypto-title anchors

`TITLE_CRYPTO_NAME` uses this fixed case-insensitive title list:

`crypto`, `cryptocurrency`, `cryptocurrencies`, `blockchain`, `token`, `tokens`, `coin`, `coins`, `web3`, `defi`, `nft`, `nfts`, `staking`, `wallet`, `wallets`, `digital asset`, `digital assets`.

No other context inference is allowed in the failed validation candidate.

## Record grain and deduplication

The output grain remains one row per `(base_asset_id, GKG record_id)`.

A GKG record may match multiple different Kraken assets. Multiple accepted aliases or surfaces for the same asset and record collapse into one output row while preserving matched aliases, surfaces, and context reasons.

Duplicate `(base_asset_id, record_id)` output is a blocking failure.

## Missing and malformed data

- GKG rows with field count other than 27: reject and count; do not repair.
- Malformed structured `name,offset` blocks: count the malformed block and continue with other parseable blocks.
- Empty title or V2Themes is permitted but supplies no title/context evidence.
- Empty/invalid record ID, date, or document identifier: reject and count; any such critical-row failure blocks CFA-S3-002.
- Invalid alias flags, invalid match policies, override rows that do not reference an active alias, missing aliases, fiat-count mismatch, uncovered crypto assets, or cross-asset alias collisions inside Kraken: blocking failure before the source scan.

## Exact Q2 outputs

The local run writes:

- `stage3-news-matches.csv`
- `stage3-context-rejects.csv`
- `stage3-match-samples.csv`
- `stage3-match-summary.json`
- `stage3-match-summary.md`

Matches and rejects are streamed to disk. Bounded samples are retained for direct review. Reject/sample evidence records the applied match policy and local evidence diagnostics. Output hashes and the alias/override input hashes are recorded in the summary.

For corrected run `20260828-125505-1d682a2599b245f7bdb06ce44a69764a`:

- `stage3-match-summary.json` directly inspected SHA-256: `6a74d87afd5a747e27e6533da7948386e250a15d8e1ec433462929afae661bab`
- `stage3-match-samples.csv` SHA-256: `965e102586c6c6a6c510dae40238e8840b0ded97de2c5fa3313e22bdb9abc1f8`
- 7,163 archives
- 9,183,757 rows scanned
- 5 malformed field-count rows
- 0 missing-critical rows
- 27,185 unique asset/record matches
- 295 matched assets of 431
- 213,413 context rejects
- 0 duplicate asset/record matches

Those counts establish run accounting only. They do not establish match quality because `CFA-S3-005 = FAIL`.

## Validation requirement

Repository CI may prove parsing, self-tests, source/input validation, alias-universe invariants, and override integrity. It cannot prove the exact full-Q2 run because raw Q2 GDELT archives remain outside Git.

The corrected full-Q2 run now proves `CFA-S3-002 = PASS` and `CFA-S3-004 = PASS`, but its directly reviewed bounded sample proves `CFA-S3-005 = FAIL`. Therefore the matcher is not a validation candidate for freezing and `CFA-S3-006 = BLOCKED`.

Any future matching correction invalidates the dependent match outputs, hashes, summaries, and sample-review conclusion and requires a new exact full-Q2 run only after the `S3-SEM2-005` component/sample regressions pass.

## Explicit exclusions

The matcher does not use CoinGecko, fuzzy matching, LLM classification, price movement, future market responses, sentiment scores, or model outputs.

This stage defines only which GDELT records correspond to which Kraken assets. News-factor formulas, responses, leakage tests, model-ready data, and PLS remain downstream and blocked while Stage 3 is unresolved.
