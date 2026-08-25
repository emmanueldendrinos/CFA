# CFA Stage 2 Identity / Mapping / Alias Structural Review

Derived only from current SoT-registered AF-001/AF-002/AF-003. This review does not approve CoinGecko mappings or alias semantics.

Eligible Kraken pair rows: 1058; eligible base assets: 435; candidate rows: 435; candidate records: 1005.
Single candidate: 233; ambiguous: 182; none: 20; source-approved mappings: 0; aliases: 45 across 43 assets.

| Gate | Status | Observed |
|---|---|---|
| CFA-S2-001 Eligible Kraken base-asset universe reconciliation | PASS | eligible_pairs=1058; market_assets=435; candidate_assets=435 |
| CFA-S2-002 CoinGecko candidate-file structural integrity | PASS | rows=435; candidates=1005; parse_fail=0; shape_fail=0; hash_fail=0; count_fail=0; id_fail=0; pair_fail=0; obs_fail=0; symbol_fail=0 |
| CFA-S2-003 CoinGecko mapping decisions | UNVERIFIED | source_approved=0; single=233; ambiguous=182; none=20 |
| CFA-S2-004 Alias seed structural linkage | PASS | rows=45; assets=43; missing=0; duplicates=0; bad_context=0 |
| CFA-S2-005 Alias semantic validation | UNVERIFIED | manual seed references only |
| CFA-S2-006 Advance to news matching definition | BLOCKED | CFA-S2-003 and CFA-S2-005 unresolved |

CFA-S2-001/002/004 are structural gates. CFA-S2-003 requires independent CoinGecko mapping evidence and explicit decisions. CFA-S2-005 requires raw-news alias validation. CFA-S2-006 remains BLOCKED until those are resolved.
