# CFA Stage 2 Kraken / GDELT Alias Readiness

Active news identity path: Kraken market asset -> approved AF-003 alias -> raw GDELT record. CoinGecko is NOT_APPLICABLE for news matching and is retained only as historical lineage.

Eligible Kraken pair rows: 1058; eligible base assets: 435; aliases: 45 across 43 assets; approved alias identities: 45.

| Gate | Status | Observed |
|---|---|---|
| CFA-S2-001 Eligible Kraken base-asset universe reconciliation | PASS | eligible_pairs=1058; market_assets=435 |
| CFA-S2-002 CoinGecko candidate-file structural integrity | NOT_APPLICABLE | Removed from active CFA news workflow by user directive 2026-08-27; historical evidence retained only for lineage. |
| CFA-S2-003 CoinGecko mapping decisions | NOT_APPLICABLE | Removed from active CFA news workflow by user directive 2026-08-27; no CoinGecko identity is required for GDELT matching. |
| CFA-S2-004 Kraken-to-news alias structural linkage | PASS | rows=45; assets=43; missing=0; duplicates=0; bad_context=0 |
| CFA-S2-005 Alias semantic validation | PASS | decision_rows=45; approved=45; missing=0; duplicate=0; mismatch=0; unapproved=0 |
| CFA-S2-006 Advance to news matching definition | PASS | Kraken coverage and all 45 news aliases are validated; CoinGecko is not part of the active news path. |

Historical CoinGecko evidence and scripts are not inputs to this active gate and are not required to proceed to Stage 3.
