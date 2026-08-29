# CFA external PostgreSQL inventory review — 2026-08-29

Status: **PASS** for direct inspection of the uploaded read-only inventory package; predecessor formulas, derived values, factor definitions, and conclusions remain **UNVERIFIED** for CFA until independently reconstructed/revalidated.

Authority boundary: this review uses the CFA SoT plus the directly inspected inventory package. SRP/ASRP/PLS objects remain external candidate evidence. No predecessor conclusion or model result is imported as CFA truth.

## Package evidence

Local run ID: `20260829-065450-2e86a9154d9846ae8b5ac5ce3c695272`

Uploaded ZIP SHA-256: `e829005b03fc30a317dd6bcd5b08fa42c41ba9ffcc0be928acf9ffc2263a5423`

Uploaded ZIP bytes: `50,998`

The package manifest contains 43 files. Every manifest-listed file was recomputed directly from the uploaded ZIP; **0 SHA-256 mismatches** were observed.

The inventory itself reports PostgreSQL 18.4, `default_transaction_read_only=on`, a 300-second statement timeout, and PASS for all inventoried databases.

## Scope correction

In-scope predecessor/current systems for CFA preservation review:

- `srp`: **PRESERVE** — market source, market environment and geometry predecessor.
- `asrp`: **PRESERVE** — spike/news-hype/source and derived market-analysis predecessor.
- `pls_trading`: **PRESERVE** — active PLS compatibility/history evidence.
- `cfa`: current project source database.

Explicitly not used for this CFA review:

- `cri_trading_terminal`: **NOT_APPLICABLE**.
- `pls_trading_pre_v130`: **NOT_APPLICABLE**.

## Database footprint

Relation bytes observed from the inventory:

| Database | Relation bytes | Approx. GiB | Decision |
|---|---:|---:|---|
| `srp` | 16,884,703,232 | 15.725 | **PRESERVE / selectively archive later** |
| `asrp` | 31,852,158,976 | 29.665 | **PRESERVE / selectively archive later** |
| `pls_trading` | 1,474,560 | 0.0014 | **PRESERVE COMPLETELY** |
| `cfa` | 9,175,040 | 0.0085 | **PRESERVE** |

## SRP — high-value market geometry

SRP contains a large and explicit Q2 market-geometry corpus. It is not merely raw OHLCV storage.

### `srp.q2_prospective_scanner_snapshots`

Approximate rows: `3,631,767`; bytes: `2,813,976,576` (~2.62 GiB).

**Classification: KEEP — CRITICAL GEOMETRY CANDIDATE.**

Its schema contains decision-time candidate/environment fields including:

- decision timestamp/price and price age;
- 5m/15m/1h/4h/24h returns;
- realized log volatility at 1h/4h/24h;
- 1h/4h/24h ranges;
- positive-bar share and wick measures;
- trade-count and quote-notional activity;
- trade/notional acceleration;
- cross-quote breadth/confirmation;
- market breadth and market median returns;
- BTC and ETH 1h returns;
- a `prospective_environment` label.

The same table then stores **future** 1h/3h/6h/12h/24h high/low returns, threshold-hit labels and future bucket counts.

**Leakage boundary:** columns containing future returns/hits are response/outcome evidence and may never enter a predictor row at the earlier decision cutoff. The table must be split conceptually into predictor-side and response-side fields before any CFA use.

### `srp.q2_candidate_path_signals`

**Classification: KEEP — GEOMETRY/RESPONSE CANDIDATE.**

Contains decision-side ranges/returns/activity acceleration followed by future TP/SL timestamps, 24h high/low/final returns and path-outcome fields. The same leakage separation is mandatory.

### SRP spike/event geometry families

**Classification: KEEP — EVENT/PATH GEOMETRY CANDIDATES.**

Preserve the following families:

- `base_spike_events`, `base_spike_event_members`;
- `spike_episodes`, `spike_episode_metrics`;
- `q2_spike_magnitude_events`;
- `q2_spike_magnitude_observations` (~366 MB);
- `q2_spike_magnitude_recipe_metrics`;
- `q2_spike_wave_*` and `q2_spike_waves`.

These schemas retain threshold times, peak/favorable/adverse paths, wave membership/stage, market breadth, BTC/ETH context, volatility/range expansion, activity acceleration, control matching, censoring/boundary flags and recipe-condition metrics.

### SRP factor candidates

Preserve:

- `q2_institutional_factor_taxonomy`;
- `q2_institutional_factor_values`;
- `q2_institutional_factor_audit_subjects`;
- `q2_institutional_factor_interactions`.

**Classification: KEEP AS FACTOR/METHODOLOGY CANDIDATE ONLY.** Exact factor definitions and values are not CFA-approved.

### SRP raw market history

Large partitions include Q2 2025 through Q1 2026.

- `ohlcvt_1m_2025q2`: ~2.49 GiB and is a duplicate/regenerable Q2 market copy from CFA's perspective because CFA already independently verified the exact Kraken Q2 source and 14,055,089-row Q2 market population.
- Q3 2025, Q4 2025 and Q1 2026 partitions are outside the current CFA Q2 source contract but may be valuable later for lookback/out-of-period validation. **Preserve them until their source-archive lineage is independently inventoried.**

Do not delete SRP raw partitions yet.

### SRP news/identity handoff objects

`q2_spike_hype_handoff`, `q2_spike_hype_samples`, and `q2_spike_external_identity_candidates` are **AUDIT ONLY**. Preserve bounded lineage if desired, but their semantic identity/news conclusions are rejected as CFA authority because CFA Stage 3 already demonstrated that predecessor lexical/ticker matching is not reliable enough.

## ASRP — derived predictor/response geometry

ASRP contains a distinct derived market-analysis layer in schema `asrp_analysis`.

### `asrp_analysis.q2_feature_snapshots`

Approximate rows: `5,198,149`; bytes: `2,225,864,704` (~2.07 GiB).

**Classification: KEEP — CRITICAL PREDICTOR-SIDE GEOMETRY CANDIDATE.**

Fields include:

- feature window and observation coverage;
- window return;
- realized and downside volatility;
- quote volume and quote-volume z-score;
- trade count and trade-count z-score;
- absolute return per quote volume;
- directional efficiency;
- positive-return share;
- up-wick share;
- cadence-gap count;
- BTC/ETH beta;
- BTC/ETH-adjusted returns;
- mean USD-pair breadth, return and contemporaneous pair count.

This is the cleanest predecessor candidate for CFA market-factor reconstruction, but exact formulas/windows remain **UNVERIFIED** until the stored analysis contract is exported and checked.

### `asrp_analysis.q2_execution_geometry`

Approximate rows: `516,539`; bytes: `557,613,056` (~0.52 GiB).

**Classification: KEEP — CRITICAL RESPONSE-SIDE GEOMETRY CANDIDATE.**

Contains next-candle entry gap, post-detection MFE/MAE, target times, downside times, and `target_before_downside` structures.

These are post-anchor outcomes and must never be available to predictor computation before their response cutoff.

### `asrp_analysis.q2_anchor_outcomes`

Approximate rows: `5,941,067`; bytes: ~1.74 GiB.

**Classification: KEEP — RESPONSE CANDIDATE.**

Stores horizon-specific future observation counts, future max/min prices and MFE/MAE.

### Event/anchor binding objects

Preserve:

- `q2_analysis_anchors`;
- `q2_anchor_episode_map`;
- `q2_event_candidates`;
- `q2_event_episodes`.

They provide the anchor/event grain needed to join predictor-side features to response-side geometry. Their `detection_definition`, baseline windows, cooldowns and event semantics must be extracted before reuse.

### `asrp_analysis.q2_minute_prefix`

Bytes: `10,611,490,816` (~9.88 GiB), the largest derived ASRP table.

**Classification: PRESERVE FOR NOW; LIKELY REGENERABLE INTERMEDIATE AFTER CONTRACT EXPORT.**

Its schema stores cumulative statistics used to derive returns, volatility, downside volatility, volume/trade z-scores, positive-return/wick measures, BTC/ETH covariance terms and USD-market breadth. This is probably an acceleration/intermediate table rather than a final research conclusion, but deleting it is not authorized until `q2_analysis_contracts` and necessary validation evidence are exported and the derivation is shown reproducible.

### ASRP duplicate Q2 market copies

- `asrp.q2_market_1m_observations`: ~6.67 GiB.
- `asrp.q2_raw_records`: ~4.81 GiB.

**Classification: DUPLICATE/REGENERABLE CANDIDATES FOR CFA, NOT DELETE-NOW.** CFA already has independently verified Q2 Kraken source/market coverage. Before any cleanup, export ASRP's source/import/analysis contracts and verify that no unique raw-field or provenance requirement would be lost.

### Legacy `asrp_hype`

The three factor-value tables (`asset_slot_factors`, `asset_source_slot_factors`, `market_slot_factors`) are **REJECT AS CFA FACTOR VALUES; KEEP SCHEMA/METHODOLOGY REFERENCE ONLY**. They descend from the legacy incomplete acquisition/lexical semantic design rejected in CFA Stage 1/Stage 3.

The remaining `asrp_hype` acquisition/protocol/subject/term/source tables are audit/reference only. They are small and may be retained until a bounded contract export is captured; their semantic decisions do not govern CFA.

## Active PLS PostgreSQL

The complete `pls_trading` relation footprint is only ~1.4 MB.

**Classification: PRESERVE COMPLETELY.**

High-value compatibility objects include:

- `scanner_setup`, `scanner_setup_version`;
- `scanner_run`, `scanner_candidate` (`snapshot_json`, scoring version, horizon, side, market source);
- AI research/source/score tables;
- automation decision lineage.

Current PLS repository documentation states that the active application uses embedded SQLite as its authoritative persistence. Therefore this PostgreSQL database's exact current runtime role remains **UNVERIFIED**, but there is no storage justification for deleting it and it may contain historical scanner/AI compatibility evidence.

## Cleanup boundary

**Safe to preserve now:** all SRP/ASRP geometry/event/factor-contract objects and the entire active `pls_trading` database.

**Potential large cleanup candidates, but NOT delete-now:**

1. ASRP Q2 typed/raw market duplicates (~11.48 GiB combined).
2. ASRP `q2_minute_prefix` (~9.88 GiB) after exact analysis-contract export and reproducibility proof.
3. SRP Q2 raw market partition (~2.49 GiB) after SRP source-archive lineage is independently verified.
4. Legacy ASRP hype factor-value tables after their schemas/contracts are captured; these are small relative to the market tables.

No destructive PostgreSQL action is authorized by this review.

## Gates and next preservation task

- `CFA-EXT-004` — direct external PostgreSQL inventory inspection: **PASS**.
- `CFA-EXT-005` — useful-object preservation classification: **PASS for the high-value and cleanup-relevant object families above; exact predecessor formulas/contract rows remain UNVERIFIED**.
- `CFA-EXT-006` — export exact small definition/contract/provenance rows needed to reconstruct SRP/ASRP geometry before any database cleanup: **UNVERIFIED**.

`CFA-EXT-006` must capture, at minimum, SRP definitions/factor taxonomy/threshold metadata/source-archive lineage and ASRP analysis/import contracts/run receipts/source-file lineage. It should be read-only and bounded; no bulk geometry table export is required for this metadata step.
