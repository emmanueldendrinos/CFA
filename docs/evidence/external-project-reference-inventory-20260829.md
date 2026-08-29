# CFA external-project candidate reference inventory — 2026-08-29

Status: **UNVERIFIED** external-reference inventory. This document does not import any prior SRP, ASRP, or PLS implementation, conclusion, factor, response, model, validation receipt, or PASS state into CFA authority.

Authority boundary: the CFA Source of Truth remains authoritative. External-project material may be retained only as candidate source evidence or methodology reference and must be independently redefined/revalidated against CFA-authorized source data before use.

## Frozen inventory tasks

| Task ID | Requirement | Status |
|---|---|---|
| `CFA-EXT-001` | Inventory connected external GitHub repositories and identify potentially reusable source/definition artifacts without importing prior conclusions. | **PASS** for currently connected GitHub scope |
| `CFA-EXT-002` | Identify candidate market-geometry definitions that can later be independently reconstructed/tested from CFA Kraken observations. | **PASS** candidate references identified; formulas remain **UNVERIFIED** for CFA |
| `CFA-EXT-003` | Identify candidate news-hype factor families/schema references while excluding prior lexical/matching decisions as semantic authority. | **PASS** candidate references identified; factor definitions remain **UNVERIFIED** for CFA |
| `CFA-EXT-004` | Inventory SRP, ASRP, and active PLS PostgreSQL schemas/tables/views/functions and locate raw/derived market-environment or market-geometry objects using read-only inspection. | **UNVERIFIED** pending direct inspection of the exact successful local inventory package |
| `CFA-EXT-005` | Decide item-by-item whether external evidence is KEEP-AS-SOURCE-CANDIDATE, KEEP-AS-METHODOLOGY-REFERENCE, DUPLICATE, REJECT, or UNVERIFIED before any copy/import/deletion decision. | **BLOCKED** on direct package inspection for database-side material |

## Scope correction — active PLS

User scope clarification on 2026-08-29 establishes the following predecessor boundary for this inventory:

- **SRP** — in scope as a CFA predecessor for market source/environment/geometry evidence.
- **ASRP** — in scope as a CFA predecessor for spike/news-hype/source methodology evidence.
- **PLS Trading** — **active and required**. The current `emmanueldendrinos/PLS.TradingTerminal` repository and its active runtime/data contracts must be preserved as a compatibility boundary.
- `cri_trading_terminal` PostgreSQL — **NOT_APPLICABLE** to CFA predecessor mining under the current scope.
- `pls_trading_pre_v130` PostgreSQL — **NOT_APPLICABLE** under the current scope.
- `postgres` maintenance database — **NOT_APPLICABLE** except as a connection/maintenance endpoint.
- `cfa` PostgreSQL — current CFA data and therefore preserved, but not an external predecessor source.

The read-only inventory runner may enumerate out-of-scope databases for completeness. Their enumeration does not make them CFA inputs.

## Connected GitHub repository inventory

The connected GitHub account currently exposes these repositories relevant to the search boundary:

- `emmanueldendrinos/CFA`
- `emmanueldendrinos/ASRP`
- `emmanueldendrinos/PLS.TradingTerminal`
- `emmanueldendrinos/PLS.TradingTerminal-v3.1.0`
- `emmanueldendrinos/Flow`

No connected repository literally named `SRP` was found. This does not prove that SRP material is absent; CFA Stage 1 direct database evidence already established an `srp` PostgreSQL schema, so SRP may principally exist in PostgreSQL or under a differently named repository. GitHub-side SRP status is therefore **UNVERIFIED**, not absent.

`emmanueldendrinos/PLS.TradingTerminal` is the active PLS repository. Its README identifies version `7.8.1` and states that the sole active PLS specification is `docs/SOT/PLS-SOT-v7.8.1.xlsx`.

Active PLS SOT candidate identity:

- path: `docs/SOT/PLS-SOT-v7.8.1.xlsx`
- Git blob SHA: `d8d2d572e57457e12e008c55061e210ff4f22600`
- size: 66,168 bytes
- classification: **PRESERVE-ACTIVE-COMPATIBILITY-BOUNDARY**

CFA restriction: the PLS SOT governs PLS, not CFA. It is retained so CFA does not accidentally redefine market/news outputs in a way that is incompatible with an active consumer. Any CFA factor remains subject to CFA evidence and leakage rules.

PLS persistence note: current PLS documentation states that authoritative PLS application facts are stored in an embedded SQLite database. Therefore the PostgreSQL database named `pls_trading` must be preserved and inspected, but its role in the current active terminal is **UNVERIFIED** until its objects are reviewed; it must not be assumed to be the active PLS application ledger.

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

Observed candidate definitions include a 512-observation bounded horizon, minimum 20 observations, strongest-20%-mean favorable/adverse excursion summaries, a strongest-5% adverse-tail summary, a six-candle current invalidation window, RMS move, directional persistence, horizon trend and BTC/ETH directional context. These remain candidate prior definitions only.

CFA restriction: code is not transferable implementation and cannot establish correctness. Only separately redefined formulas supported by CFA data and tests may be implemented later.

### PLS market-environment implementation

Repository/ref: `emmanueldendrinos/PLS.TradingTerminal@master`

File: `src/PLS.Desktop/ViewModels/MainViewModel.Environment.cs`

Git blob SHA: `8a086590e90768b7f587138cf8a02197d4801ab3`

Classification: **KEEP-AS-METHODOLOGY-REFERENCE**.

Why useful: exposes prior aggregation of direction, momentum, volatility, participation, liquidity, confidence, market completeness, BTC/ETH anchors and regime/posture calculations.

The active generated PLS terminology defines the candidate environment vector as Direction, Momentum, Volatility, Participation, Liquidity and Confidence; it also defines regime and leverage-suitability/posture derivatives. This is the clearest currently connected GitHub representation of the market-environment/geometry vocabulary CFA should investigate before designing new market factors.

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

## Local PostgreSQL inventory execution candidate

The exact read-only inventory runner was executed locally on 2026-08-29 against PostgreSQL 18 using the `postgres` maintenance database. User-provided console evidence reports run status `PASS` and evidence directory:

`C:\Users\Emmanuel\Documents\CFA-local\external-postgres-inventory\20260829-065450-2e86a9154d9846ae8b5ac5ce3c695272`

Reported inventory summary:

| Database | Schemas | Relations | Routines | Candidate objects | Current CFA predecessor scope |
|---|---:|---:|---:|---:|---|
| `srp` | 2 | 52 | 2 | 54 | **IN_SCOPE / PRESERVE** |
| `asrp` | 5 | 36 | 41 | 40 | **IN_SCOPE / PRESERVE** |
| `pls_trading` | 2 | 34 | 1 | 3 | **IN_SCOPE / ACTIVE-PLS / PRESERVE** |
| `cfa` | 2 | 4 | 0 | 4 | current CFA / preserve |
| `cri_trading_terminal` | 2 | 81 | 37 | 10 | **NOT_APPLICABLE** |
| `pls_trading_pre_v130` | 2 | 25 | 1 | 2 | **NOT_APPLICABLE** |
| `postgres` | 1 | 0 | 0 | 0 | maintenance only |

The execution itself is a successful target-environment validation candidate. `CFA-EXT-004` nevertheless remains **UNVERIFIED** because the generated package has not yet been directly inspected in this workstream. Summary counts cannot establish which relations/routines contain reusable source data or geometry.

Existing review package:

`C:\Users\Emmanuel\Documents\CFA-local\external-postgres-inventory\20260829-065450-2e86a9154d9846ae8b5ac5ce3c695272.zip`

No rerun is required before direct package inspection.

## External material explicitly not imported as CFA authority

The following remain excluded by default:

- prior ASRP packages, launchers, SQL, scanner implementations and tests;
- prior BigQuery execution/equivalence receipts and PASS claims;
- prior mapping approvals or matching conclusions;
- prior PLS/TradingTerminal readiness/trading-policy decisions;
- prior model outputs, forecasts, candidate scores, QL/QT scores or benchmarks;
- generated release archives, base64 package fragments, caches and validation bundles unless a specific source-lineage need is later demonstrated.

Out-of-scope CRI and pre-v1.3.0 PLS PostgreSQL material is not to be mined or imported unless a later explicit dependency is demonstrated.

## Database-side inventory requirement

CFA Stage 1 already directly verified PostgreSQL market objects including `srp.ohlcvt_1m_2025q2`, `asrp.q2_market_1m_observations`, and `asrp.q2_raw_records`, each with 14,055,089 Q2 rows. That proves useful SRP/ASRP database material exists, but it does not identify any additional market-geometry tables/views/functions.

Direct inspection of the generated package must classify the in-scope database objects by exact schema/name/columns/types/routine definitions, with emphasis on names matching `geometry`, `proximity`, `spike`, `opportunity`, `factor`, `feature`, `response`, `ql`, `qt`, `hype`, `news`, `kraken`, `ohlc`, `market`, `candidate`, `event`, `regime`, `tail`, `adverse`, `favorable`, `environment`, `direction`, `momentum`, `volatility`, `participation`, `liquidity`, and `confidence`.

`CFA-EXT-004` remains **UNVERIFIED** until that exact package is directly inspected.

## Preserve/delete rule pending database object classification

**Preserve now:**

- CFA repository and PostgreSQL database;
- verified Kraken Q2 archive/source material and immutable source hashes/manifests;
- GDELT Q2 archives and source-slot lineage;
- `srp` PostgreSQL database/backups;
- `asrp` PostgreSQL database/backups;
- active `pls_trading` PostgreSQL database/backups pending role classification;
- active PLS Trading repository, active `PLS-SOT-v7.8.1.xlsx`, and current geometry/environment formula sources;
- active PLS embedded SQLite store/backups and configuration/evidence needed to preserve current terminal state;
- ASRP Git repository and unique source/protocol definitions;
- any local source manifests or immutable raw-source hashes.

**Do not rely on as CFA truth:** prior formulas, factor values, event labels, mappings, scores, model outputs, tests or completion receipts.

**NOT_APPLICABLE under current predecessor scope:** `cri_trading_terminal`, `pls_trading_pre_v130`, and unrelated predecessor/runtime material unless a direct dependency is later shown.

**Potential deletion candidates only after inventory:** generated package fragments, old release bundles, caches, temp/output folders and duplicate validation artifacts that contain no unique source evidence, definition, schema, provenance, active PLS state, or hash needed for independent reconstruction.
