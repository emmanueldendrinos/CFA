# CFA Stage 3 Context Adjudication Contract

Status: **UNVERIFIED**

This contract supersedes the failed fixed-rule semantic matcher as the forward Stage 3 design. The failed matcher and its evidence remain preserved for audit lineage. This contract does not reopen Stage 1 source coverage or the corrected full-Q2 source accounting.

The governing distinction is explicit: PostgreSQL and deterministic code may parse, retrieve candidates, sample, hash selected/model-facing contexts, store, and aggregate. They may not make the final semantic decision that a GDELT record is about a Kraken asset or that a specific event occurred. Those decisions require contextual adjudication from the available source context and must be stored as versioned, immutable derived evidence.

## Frozen task IDs

| Task ID | Requirement |
|---|---|
| `S3-CTX-001` | Define and implement a lossless mechanical context inventory over the verified Q2 GKG source. No asset or event conclusion may be emitted. |
| `S3-CTX-002` | Measure exact source accounting, context-field missingness, and provisional high-recall discovery-candidate coverage over all valid source rows. Global all-row context-key cardinality is **NOT_APPLICABLE** because no downstream conclusion requires it. |
| `S3-CTX-003` | Select exactly 40,000 deterministic source-row occurrences for discovery: 15,000 unbiased rows, 15,000 provisional-retrieval negatives, and 10,000 asset/edge-enriched rows. Preserve all 40,000 selections for statistical inference, then cryptographically hash/deduplicate only the selected model-reading workload while retaining occurrence counts and strata. |
| `S3-CTX-004` | Directly adjudicate the discovery reading population to design and freeze the semantic asset/event schema and a production high-recall retrieval rule. Fixed retrieval rules remain candidate generators only. |
| `S3-CTX-005` | Validate the frozen retrieval rule on a fresh 60,000-row holdout: 50,000 retrieval negatives plus 10,000 asset/context holdout rows. Require a lower 95% confidence bound of at least 99% for estimated retrieval recall before production adjudication. |
| `S3-CTX-006` | Contextually adjudicate 100% of the final retrieved context population; every decision records exact input hash, schema/spec version, model/version, structured output, evidence, status, and decision hash. |
| `S3-CTX-007` | Store frozen semantic decisions in PostgreSQL with lineage back to every source row and source-slot availability; preserve `UNVERIFIED` whenever context is insufficient. |
| `S3-CTX-008` | Define leakage-controlled news-event/hype factors only after semantic adjudication and event clustering are validated. Responses, model-ready data, and PLS remain blocked until then. |

## 2026-08-28 performance correction

The first local candidate run of the context inventory was stopped as a diagnostic failure before completion. At approximately local `2026-08-28 21:21:58`, process PID `13972` had accumulated about `8,677.4` CPU seconds and the run directory `20260828-155637-2186b79fb325486fbe34eb3314bd9ef8` contained 259 files / 92.6 MB, dominated by 256 per-prefix context-hash shards. The implementation was computing and writing a SHA-256 context key for every valid source row, enumerating all alias matches on every row, constructing rich PowerShell objects for every row, and computing additional SHA-256 sampling ranks.

That design performed expensive work unrelated to the statistical or semantic endpoint. Global exact-context cardinality across all 9.18M source rows is not required to estimate crypto-news prevalence, validate retrieval recall, adjudicate selected contexts, or build final factors. It is therefore **NOT_APPLICABLE**, not a hard gate.

The corrected extractor preserves the same source/accounting and discovery objectives while changing only mechanical execution:

1. every valid source row is still parsed and counted;
2. the provisional discovery cue is evaluated for every valid row using boolean/short-circuit tests only;
3. one deterministic sampling SHA-256 is computed per valid source row, with separate bytes used for the three discovery strata;
4. rich alias diagnostics, full context SHA-256, and PowerShell row objects are materialized only for deterministic oversample rows that can enter discovery selection;
5. cryptographic context deduplication occurs on the exact selected/model-facing population, where it affects reading efficiency without changing sampling weights.

Any output from the stopped first candidate run is invalidated and must not be used as Stage 3 evidence.

## Upstream evidence retained

The verified Q2 GDELT source contract is the full `GDELT 2.0 native/base GKG fifteen-minute update archives` stream, not a crypto-specific feed.

- Nominal Q2 source slots: 8,736.
- Downloaded archives: 7,163.
- Provider-missing HTTP-404 slots: 1,573.
- Unresolved slots: 0.
- Corrected recovered rows scanned across downloaded archives: 9,183,757.
- Non-27-field rows: 5; these remain quarantined.
- Valid rows available for context inventory: 9,183,752.

The 1,573 provider-missing source slots are source missingness. They must never be interpreted as zero news.

## Context packet

For each valid GKG source row the mechanical scan inspects only directly verified fields and derived mechanical metadata:

- `record_id` — GKG field 0.
- `gdelt_date_utc` — GKG field 1 as source text.
- `source_common_name` — field 3.
- `document_identifier` — field 4.
- `themes_raw` — field 8.
- `persons_raw` — field 12.
- `organizations_raw` — field 14.
- `all_names_raw` — field 23.
- `extras_raw` — field 26.
- `page_title` — mechanically extracted from `<PAGE_TITLE>...</PAGE_TITLE>` in field 26 and HTML-decoded.
- `archive_file`, `archive_timestamp_utc`, and `row_ordinal` — physical source lineage.
- `context_replacement_present` — whether a decoded selected context field contains U+FFFD; this is evidence only and does not silently repair content.

The archive timestamp is the conservative source-availability timestamp for later leakage controls. A predictor may not use a decision before the archive timestamp of the source row supporting it.

## Canonical semantic-context key

Rows that enter a model-facing discovery, holdout, or production-adjudication population receive `context_sha256`, computed from versioned length-prefixed UTF-8 bytes of these exact fields in this order:

1. `source_common_name`
2. `document_identifier`
3. `page_title`
4. `themes_raw`
5. `persons_raw`
6. `organizations_raw`
7. `all_names_raw`
8. `extras_raw`

`record_id`, GDELT date, archive name, and row ordinal are lineage, not semantic content, and are excluded from this context key. Repeated selected source rows with the same context key may be adjudicated once while retaining every selected occurrence and its source lineage.

Global all-row context-key cardinality is deliberately not computed. This does not prevent later production retrieval from hashing and deduplicating 100% of the final retrieved population before contextual adjudication.

## Provisional discovery retrieval

`S3-CTX-003` uses a deliberately over-inclusive **discovery cue**, not a semantic matcher. A row is a provisional candidate when any of the following mechanical signals appears in the inspected context:

1. a case-insensitive whole-boundary occurrence of any active Kraken candidate alias from `candidate-analysis/CFA-Stage3-News-Aliases.csv` in title, URL, AllNames, V2Persons, or V2Organizations; or
2. a broad crypto lexical anchor in title, URL, themes, AllNames, persons, or organizations; or
3. a theme/text fragment containing an explicit Bitcoin/crypto/blockchain/digital-currency anchor.

The initial broad lexical anchors are retrieval aids only:

`bitcoin`, `ethereum`, `crypto`, `cryptocurrency`, `cryptocurrencies`, `blockchain`, `token`, `tokens`, `stablecoin`, `stablecoins`, `defi`, `decentralized finance`, `web3`, `nft`, `nfts`, `digital asset`, `digital assets`, `digital currency`, `digital currencies`, `staking`, `airdrop`, `airdrops`, `wallet`, `wallets`, `altcoin`, `altcoins`, `memecoin`, `memecoins`, `crypto market`, `cryptocurrency market`.

No candidate cue is an asset-identity or event conclusion. False positives are acceptable at retrieval; false negatives are the quantity later measured and minimized.

## Discovery sampling design

The first discovery **selection** is fixed at exactly 40,000 source-row occurrences before semantic schema design.

### Stratum A — unbiased corpus discovery: 15,000

A deterministic pseudo-random source-row sample from all valid Q2 rows, independent of retrieval cues. This is the only development stratum that can directly estimate overall source-row prevalence without retrieval conditioning.

### Stratum B — provisional-retrieval negatives: 15,000

A deterministic pseudo-random sample from source rows for which the provisional discovery cue is false. This is specifically for discovering missed terminology, sources, entity patterns, and event forms.

### Stratum C — asset/edge enriched: 10,000

A deterministic sample enriched for provisional candidate rows, including candidate-alias occurrences, ambiguous/common symbols, multi-asset contexts, and broad crypto cues. Candidate asset IDs are retrieval provenance only; they are not semantic labels.

Sampling is reproducible from physical source lineage under `CFA_STAGE3_SAMPLE_V2`. One SHA-256 is computed from version, archive filename, row ordinal, and record ID. Independent bytes of that digest determine oversample membership for the three strata. The full digest, rotated per stratum, supplies deterministic selection ordering. Source lineages already selected by an earlier stratum are skipped so the selection table contains 40,000 distinct source rows. If any stratum cannot supply its frozen target, `S3-CTX-003 = FAIL`.

### Statistical selection versus reading population

`context-discovery-selection.csv` preserves all 40,000 selected source-row occurrences. This table governs sampling proportions and later prevalence/recall calculations.

`context-discovery-reading.csv` deduplicates those 40,000 selections by `context_sha256` **only for adjudication efficiency**. Each reading row records:

- `selection_occurrence_count` — how many selected source rows have that context key;
- `selection_strata` — every discovery stratum in which that context occurred;
- one representative selected lineage row plus the complete model-facing context.

A contextual decision for one reading row is projected back to all corresponding selection occurrences for statistical analysis. Deduplication therefore does not change source-row sampling weights.

The 40,000-row discovery selection is development evidence and may be used to improve retrieval and the semantic schema. It is not a validation holdout.

## Holdout design after discovery

The future 60,000-row holdout is not generated until the production retrieval specification is frozen, to prevent contamination.

- 50,000 fresh retrieval-negative source rows for recall estimation.
- 10,000 fresh asset/context-enriched source rows for semantic identity/event validation.

Holdout source lineages must exclude every discovery selection lineage. Model reading may again deduplicate identical contexts while retaining every holdout selection occurrence and sampling weight. If retrieval is revised after seeing holdout errors, that holdout becomes development evidence and a new independent holdout is required.

## Semantic adjudication requirements

The contextual adjudicator receives the complete context packet plus the independently reviewed Kraken asset catalogue and emits structured decisions. At minimum the eventual frozen schema must distinguish:

- crypto relevance: `RELEVANT`, `NOT_RELEVANT`, `UNVERIFIED`;
- document scope: `ASSET_SPECIFIC`, `MULTI_ASSET`, `MARKET_WIDE`, `NON_CRYPTO`, `UNVERIFIED`;
- asset relation: `PRIMARY_SUBJECT`, `MATERIAL_MENTION`, `INCIDENTAL_MENTION`, `NOT_THE_ASSET`, `AMBIGUOUS`;
- context sufficiency: `TRUE` / `FALSE`;
- event type/status/direction/materiality fields to be frozen only after discovery evidence supports the taxonomy;
- concise source-grounded evidence for every resolved semantic assertion.

Model memory alone is never sufficient evidence for a new project identity mapping. Corpus-discovered names/relationships remain candidates until independently reviewed under the identity sequence.

## Context sufficiency and article-body gate

The current GKG contract does not establish full article-body availability. GKG context may be sufficient for many records, but this must be measured rather than assumed.

After discovery adjudication, full-article acquisition becomes a blocking prerequisite if either condition holds:

- fewer than 95% of genuinely relevant discovery records are resolvable from inspected GKG context overall; or
- fewer than 90% are resolvable in any material asset/event stratum needed for factor design.

If triggered, article bodies must be acquired reproducibly, hashed, timestamped, and separately validated before they can enter semantic adjudication.

## Event versus hype

A document mention and a real-world event are separate grains.

- `document` grain measures coverage/amplification.
- `event` grain represents the underlying occurrence.
- multiple documents may map to one event.
- event clustering must run forward in `available_at_utc`; future documents may join an earlier event but may not retroactively alter predictor inputs already frozen at an earlier response cutoff.

This distinction is required so media amplification is not mistaken for event frequency.

## Expected first-run outputs

`Build-CfaStage3ContextInventory.ps1` writes a new evidence directory containing:

- `context-inventory-summary.json`
- `context-inventory-summary.md`
- `context-discovery-selection.csv` — exactly 40,000 source-row selections when `S3-CTX-003 = PASS`;
- `context-discovery-reading.csv` — context-deduplicated model-reading population with occurrence counts/strata;
- `context-discovery-batch-manifest.csv`;
- `context-discovery-batch-####.csv` — deterministic partitions of the reading population for upload/review.

The batch files partition the reading population, not the statistical selection table. The manifest records batch rows, bytes, SHA-256, and represented discovery strata. Temporary oversample files are deleted after successful selection.

## First-run hard gates

| Gate | Requirement | Initial status |
|---|---|---|
| `S3-CTX-001` | Exact optimized extractor artifact parses/self-tests, its fast and detailed discovery paths agree on regression cases, and it emits no semantic asset/event conclusion | **UNVERIFIED** until exact artifact validation |
| `S3-CTX-002` | 7,163 archives; 9,183,757 rows; 5 quarantined malformed rows; 9,183,752 valid rows; 0 missing-critical failures; source/context-field accounting reconciles | **UNVERIFIED** until corrected local full scan |
| `S3-CTX-003` | Exactly 15k/15k/10k source-row selections with unique physical lineage plus a context-deduplicated reading population retaining occurrence counts/strata | **UNVERIFIED** until corrected local full scan |
| `S3-CTX-004` | Discovery contextual adjudication and semantic/retrieval design | **BLOCKED** until `S3-CTX-001..003` PASS |
| `S3-CTX-005` | Fresh 60k holdout validation | **BLOCKED** |
| `S3-CTX-006` | Production contextual adjudication | **BLOCKED** |
| `S3-CTX-007` | PostgreSQL semantic load/freeze | **BLOCKED** |
| `S3-CTX-008` | News-factor definitions | **BLOCKED** |

The failed `CFA-S3-005` fixed-rule matcher remains historical FAIL evidence. It is not reinterpreted as part of this new pipeline.
