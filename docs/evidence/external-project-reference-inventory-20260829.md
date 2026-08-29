# CFA external-project candidate reference inventory — 2026-08-29

Status: **UNVERIFIED** external-reference inventory. This document does not import any prior SRP, ASRP, or PLS implementation, conclusion, factor, response, model, validation receipt, or PASS state into CFA authority.

Authority boundary: the CFA Source of Truth remains authoritative. External-project material may be retained only as candidate source evidence or methodology reference and must be independently redefined/revalidated against CFA-authorized source data before use.

## Frozen inventory tasks

| Task ID | Requirement | Status |
|---|---|---|
| `CFA-EXT-001` | Inventory connected external GitHub repositories and identify potentially reusable source/definition artifacts without importing prior conclusions. | **PASS** for currently connected GitHub scope |
| `CFA-EXT-002` | Identify candidate market-geometry definitions that can later be independently reconstructed/tested from CFA Kraken observations. | **PASS** candidate references identified; formulas remain **UNVERIFIED** for CFA |
| `CFA-EXT-003` | Identify candidate news-hype factor families/schema references while excluding prior lexical/matching decisions as semantic authority. | **PASS** candidate references identified; factor definitions remain **UNVERIFIED** for CFA |
| `CFA-EXT-004` | Inventory SRP/ASRP PostgreSQL schemas/tables/views/functions and locate raw/derived market-geometry objects using read-only inspection. | **UNVERIFIED**; no local PostgreSQL connector is currently available to this chat runtime |
| `CFA-EXT-005` | Decide item-by-item whether external evidence is KEEP-AS-SOURCE-CANDIDATE, KEEP-AS-METHODOLOGY-REFERENCE, DUPLICATE, REJECT, or UNVERIFIED before any copy/import/deletion decision. | **BLOCKED** on `CFA-EXT-004` for database-side material |

## Connected GitHub repository inventory

The connected GitHub account currently exposes these repositories relevant to the search boundary:

- `emmanueldendrinos/CFA`
- `emmanueldendrinos/ASRP`
- `emmanueldendrinos/PLS.TradingTerminal`
- `emmanueldendrinos/PLS.TradingTerminal-v3.1.0`
- `emmanueldendrinos/Flow`

No connected repository literally named `SRP` was found. This does not prove that SRP material is absent; CFA Stage 1 direct database evidence already established an `srp` PostgreSQL schema, so SRP may principally exist in PostgreSQL or under a differently named repository. GitHub-side SRP status is therefore **UNVERIFIED**, not absent.

## Candidate market-geometry references

### PLS opportunity-map terminology manifest

Repository/ref: `emmanueldendrinos/PLS.TradingTerminal@master`

File: `assets/opportunity-terms.json`

Git blob SHA: `ce950506ed6fb73828df099ff3497ee02a9527e2`

Classification: **KEEP-AS-METHODOLOGY-REFERENCE**.

Why useful: this manifest explicitly defines a prior market-state / opportunity-map representation, including current Spike Impulse, historical favorable movement, historical adverse movement, Tail Downside, Historical R:R, BTC/ETH context, Direction, Momentum, Volatility, Participation, Liquidity, Confidence, regime and leverage-suitability concepts. It also states completed-candle and stale-evidence boundaries.

CFA restriction: none of these formulas, weights, thresholds, horizons, sampling fractions, market sets, or scaling choices are approved for CFA. Each must be independently defined from CFA objectives, reconstructed from verified Q2 Kraken fields, tested for missingness/cardinality/time semantics, and leakage-validated before it can become a candidate factor.

### PLS scanner calculator implementation

Repository/ref: `emmanueldendrinos/PLS.TradingTerminal@master`

File: `src/PLS.Domain/Scanner/OpportunityModel.cs`

Git blob SHA: `6825e77ba8b696336738ac05a30ededb3fe89992`

Classification: **KEEP-AS-METHODOLOGY-REFERENCE**.

Why useful: implementation detail can help reveal exact prior meanings hidden behind labels such as favorable/adverse excursion, tail downside, current invalidation, RMS move, directional persistence and market context.

CFA restriction: code is not transferable implementation and cannot establish correctness. Only separately redefined formulas supported by CFA data and tests may be implemented later.

### PLS market-environment implementation

Repository/ref: `emmanueldendrinos/PLS.TradingTerminal@master`

File: `src/PLS.Desktop/ViewModels/MainViewModel.Environment.cs`

Git blob SHA: `8a086590e90768b7f587138cf8a02197d4801ab3`

Classification: **KEEP-AS-METHODOLOGY-REFERENCE**.

Why useful: exposes prior aggregation of direction, momentum, volatility, participation, liquidity, confidence, market completeness, BTC/ETH anchors and regime/posture calculations.

CFA restriction: UI/trading-policy thresholds, live quote assumptions, included-market selection and leverage/trade posture are outside current CFA factor authority unless independently justified later.

## Candidate news-hype references

### ASRP compact factor protocol

Repository/ref: `emmanueldendrinos/ASRP@infra/native-ps51-bigquery-wif`

File: `packages/candidate-v1.0.3/config/ASRP-Q2-GDELT-GKG-Compact-Factor-Protocol-v1.0.0.json`

Git blob SHA: `62b1568d798e8cd3863144d5d9471163b9ed4e68`

Classification: **KEEP-AS-METHODOLOGY-REFERENCE**.

Potentially useful candidate families:

- mention quantity and acceleration;
- distinct-source breadth and propagation;
- tone balance and dispersion;
- source diversity / concentration;
- risk, regulation and security context;
- adoption, listing, partnership and funding context;
- media/entity density and promotional concentration;
- explicit source/object provenance and missing-object treatment.

Important CFA rejection boundary: the old protocol also contains lexical context patterns and operational mapping assumptions. Those must not be imported as the final semantic judge. CFA Stage 3 has already established that fixed lexical/ticker rules cannot reliably determine asset identity/event meaning. The candidate factor families may be reconsidered only after contextual adjudication is frozen.

### ASRP GKG column-binding reference

Repository/ref: `emmanueldendrinos/ASRP@infra/native-ps51-bigquery-wif`

File: `packages/candidate-v1.0.3/config/ASRP-Q2-GDELT-GKG-BigQuery-Factor-Column-Binding-v1.0.0.json`

Git blob SHA: `5f39e2b5e43ba2d4478ffd736e163531de1d4540`

Classification: **KEEP-AS-METHODOLOGY-REFERENCE / SCHEMA-CROSS-CHECK ONLY**.

Why useful: records prior intended use of GKG identity/time, tone, entity-density, quotation, amount, GCAM, image/social and translation fields.

CFA restriction: CFA must continue to use directly inspected native GKG source fields and its own verified parser/schema. BigQuery schema or ordinal labels in this file cannot override directly inspected CFA source data.

## External material explicitly not imported as CFA authority

The following remain excluded by default:

- prior ASRP packages, launchers, SQL, scanner implementations and tests;
- prior BigQuery execution/equivalence receipts and PASS claims;
- prior mapping approvals or matching conclusions;
- prior PLS/TradingTerminal readiness/trading-policy decisions;
- prior model outputs, forecasts, candidate scores, QL/QT scores or benchmarks;
- generated release archives, base64 package fragments, caches and validation bundles unless a specific source-lineage need is later demonstrated.

## Database-side inventory requirement

CFA Stage 1 already directly verified PostgreSQL market objects including `srp.ohlcvt_1m_2025q2`, `asrp.q2_market_1m_observations`, and `asrp.q2_raw_records`, each with 14,055,089 Q2 rows. That proves useful SRP/ASRP database material exists, but it does not identify any additional market-geometry tables/views/functions.

Before deleting an SRP/ASRP PostgreSQL database, schema, backup, local project folder, or generated dataset, perform a read-only inventory that records at minimum:

- database name and PostgreSQL version;
- schemas;
- ordinary/partitioned/foreign tables, views and materialized views;
- approximate/actual row counts where safe;
- columns and data types for candidate market/news/geometry objects;
- functions/procedures with definitions/hashes where relevant;
- indexes/constraints needed to understand source grain;
- object sizes;
- comments/descriptions;
- source/load/provenance tables and hashes;
- names matching `srp`, `asrp`, `geometry`, `proximity`, `spike`, `opportunity`, `factor`, `feature`, `response`, `ql`, `qt`, `hype`, `news`, `kraken`, `ohlc`, `market`, `candidate`, `event`, `regime`, `tail`, `adverse`, `favorable`.

`CFA-EXT-004` remains **UNVERIFIED** until that read-only database inventory is directly inspected.

## Preserve/delete rule pending database inventory

**Preserve now:** CFA repository; verified Kraken Q2 archive/source material; GDELT Q2 archives; PostgreSQL databases/backups containing `srp`, `asrp`, or CFA source data; PLS/ASRP Git repositories; any local source manifests or immutable raw-source hashes.

**Do not rely on as CFA truth:** prior formulas, factor values, event labels, mappings, scores, model outputs, tests or completion receipts.

**Potential deletion candidates only after inventory:** generated package fragments, old release bundles, caches, temp/output folders and duplicate validation artifacts that contain no unique source evidence, definition, schema, provenance, or hash needed for independent reconstruction.
