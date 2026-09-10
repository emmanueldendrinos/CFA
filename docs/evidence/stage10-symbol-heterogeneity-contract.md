# CFA Stage 10 per-symbol heterogeneity and scanner-prerequisite contract — active — 2026-09-10

Status: **STAGE10_ACTIVE / STAGE9_ENTRY_PASS / PER_SYMBOL_EFFECTS_UNVERIFIED / EVENT_ATTRIBUTION_UNVERIFIED / SCANNER_DESIGN_BLOCKED**

## Purpose

Stage 10 corrects the pooled-analysis limitation of Stage 9. The analytical grain is now the individual base asset. No pooled average may be used to characterize every symbol.

Stage 10 answers, for each symbol with sufficient support:

1. how often the symbol receives matched GDELT news;
2. whether news intensity is associated with subsequent signed return for that symbol;
3. whether news intensity is associated with subsequent absolute return for that symbol;
4. whether the symbol behaves differently on zero-news versus positive-news days;
5. whether news sensitivity is stable across time segments;
6. whether large realized moves are more consistent with broad-market co-movement, symbol-specific abnormal movement associated with news, or a mixed case.

All conclusions remain exploratory/post-hoc because Stage 8 and Stage 9 results have already been observed. A future production scanner requires new unseen data for confirmatory calibration.

## Frozen entry

Stage 9 frozen commit: `67001683d86338388e1535084335f739363c2159`.

Use the exact frozen Stage 7 model-ready dataset and the three frozen Stage 5 GDELT predictors:

- `NEWS_V6_MATCH_COUNT_24H_LAG15`;
- `NEWS_V6_MATCH_COUNT_6H_LAG15`;
- `NEWS_V6_SOURCE_COUNT_24H_LAG15`.

Response remains `response_value_log_return` at `(base_asset_id,response_day_utc)`.

No factor values, source mappings, news matches, timestamps, missingness decisions, split roles, or Stage 9 results may be redefined.

## Per-symbol descriptive metrics

For each `base_asset_id`, calculate over all available frozen model-ready rows and separately by original Stage 7 role (`TRAIN`, `VALIDATION`, `TEST`):

- total eligible rows;
- positive-news row count and zero-news row count for each news factor;
- news coverage rate;
- mean, sample SD, minimum and maximum news intensity;
- Pearson correlation of each news factor with signed next-day return;
- Pearson correlation of each news factor with absolute next-day return;
- mean signed return on zero-news rows;
- mean signed return on positive-news rows;
- difference `mean_return_positive_news - mean_return_zero_news`;
- mean absolute return on zero-news rows;
- mean absolute return on positive-news rows;
- difference `mean_abs_return_positive_news - mean_abs_return_zero_news`.

These are symbol-specific statistics. They must never be replaced by pooled values.

## Support classification

For each symbol/factor metric, report support explicitly rather than discarding unsupported symbols.

- `SUFFICIENT_FOR_DIRECTIONAL_DIAGNOSTIC`: at least 20 total rows, at least 5 zero-news rows, and at least 5 positive-news rows.
- `SUFFICIENT_FOR_MAGNITUDE_DIAGNOSTIC`: same threshold.
- otherwise `INSUFFICIENT_SUPPORT`.

The thresholds are predeclared for stability of simple exploratory summaries; they are not claims of statistical power.

No unsupported symbol receives a substantive news-sensitivity label.

## Temporal stability

For every symbol/factor with sufficient support in both an earlier and later segment, compare the sign of:

- Pearson signed-return correlation;
- positive-vs-zero signed-return difference;
- Pearson absolute-return correlation;
- positive-vs-zero absolute-return difference.

Report `SAME_SIGN`, `SIGN_REVERSAL`, or `UNRESOLVED_SUPPORT` for each statistic. This directly tests whether pooled near-zero effects can result from time-varying direction.

## Cross-sectional symbol profiles

Do not force hard causal categories. Produce continuous symbol-level scores first:

- `NEWS_COVERAGE_RATE_24H`;
- `NEWS_DIRECTION_EFFECT_24H = mean_return_positive_news - mean_return_zero_news`;
- `NEWS_MAGNITUDE_EFFECT_24H = mean_abs_return_positive_news - mean_abs_return_zero_news`;
- analogous 6h and source-count effects;
- corresponding correlations;
- temporal-stability flags.

A symbol can therefore be described as relatively news-sensitive, magnitude-sensitive, directionally unstable, or weakly covered without pretending that these are causal classes.

## Broad-market reference for realized-event attribution

The existing four market predictors are lagged symbol-specific predictors and are not a contemporaneous broad-market attribution measure. Stage 10 therefore defines a new **diagnostic-only realized market reference** from the already frozen response rows.

For response day `d` and target symbol `a`:

`MARKET_MEDIAN_EX_A(d) = median(response_value_log_return of all other eligible symbols on day d)`.

This field uses realized same-day responses and is therefore **diagnostic only**. It is forbidden as a predictor for a scanner before the corresponding day has elapsed.

For each symbol with at least 20 prior overlapping days, estimate a rolling trailing relationship using only days strictly before `d`:

`r_a,t = alpha_a,d + beta_a,d * MARKET_MEDIAN_EX_A(t) + error_a,t`

using at most the previous 20 available overlapping symbol-days and requiring at least 15.

Then on day `d`:

- `MARKET_COMPONENT(a,d) = alpha_a,d + beta_a,d * MARKET_MEDIAN_EX_A(d)`;
- `ABNORMAL_RETURN(a,d) = r_a,d - MARKET_COMPONENT(a,d)`.

The contemporaneous market median may be used only for retrospective event attribution, never as future information.

## News-burst indicator for attribution

For each symbol and news factor, using only prior rows strictly before day `d`, calculate a trailing 20-row empirical baseline when at least 10 historical rows exist.

For `NEWS_V6_MATCH_COUNT_24H_LAG15`, define:

- `NEWS_BURST_24H(a,d)=true` if current count is greater than the trailing 90th percentile of the symbol's prior 20 counts, with current count > 0;
- otherwise false.

Analogous indicators are calculated for 6h match count and 24h source count.

This is a symbol-relative burst definition; a count that is unusual for one coin need not be unusual for another.

## Realized-event attribution labels

Labels are descriptive diagnostics, not causal proof.

For rows with an available rolling market relationship:

- `MARKET_DOMINANT`: `abs(MARKET_COMPONENT) >= abs(ABNORMAL_RETURN)` and no news-burst indicator is true;
- `NEWS_ASSOCIATED_ABNORMAL`: at least one news-burst indicator is true and `abs(ABNORMAL_RETURN) > abs(MARKET_COMPONENT)`;
- `MIXED`: at least one news-burst indicator is true and `abs(MARKET_COMPONENT) >= abs(ABNORMAL_RETURN)`;
- `SYMBOL_SPECIFIC_NO_NEWS`: no news-burst indicator is true and `abs(ABNORMAL_RETURN) > abs(MARKET_COMPONENT)`;
- `UNVERIFIED`: insufficient trailing support.

These labels distinguish broad co-movement from news-associated abnormal movement without claiming causality.

## Scanner implication boundary

Stage 10 is not the live scanner itself. It produces the per-symbol calibration tables required to design one.

A future scanner must operate at current-time grain and may use only information available by the scan timestamp. It must not use next-day returns, full-day market medians, or any retrospective attribution field as live predictors.

The intended scanner architecture is:

1. maintain symbol-specific rolling news baselines;
2. detect symbol-relative news bursts;
3. maintain real-time symbol price movement relative to a contemporaneous broad-market reference available up to the same timestamp;
4. combine the symbol's frozen historical sensitivity profile with the current news burst and current abnormal price move;
5. emit an alert score and attribution state such as market-wide, news-associated abnormal, mixed, or unsupported;
6. recalibrate only from past data and preserve timestamp lineage.

Intraday scanner horizons, broad-market construction, alert thresholds and calibration must be frozen and validated in a later stage before implementation.

## Required Stage 10 outputs

- `stage10-symbol-news-sensitivity.csv`;
- `stage10-symbol-temporal-stability.csv`;
- `stage10-symbol-profile-summary.csv`;
- `stage10-market-reference-by-day.csv`;
- `stage10-symbol-event-attribution.csv`;
- `stage10-event-attribution-summary-by-symbol.csv`;
- Stage 10 run receipt with exact source/output hashes and gate statuses.

## Gates

| ID | Requirement | Status |
|---|---|---|
| `CFA-S10-001` | Reconcile frozen Stage 9 / Stage 7 entry | PASS |
| `CFA-S10-002` | Compute per-symbol news sensitivity/support diagnostics | BLOCKED |
| `CFA-S10-003` | Compute per-symbol temporal stability | BLOCKED |
| `CFA-S10-004` | Construct diagnostic broad-market reference | BLOCKED |
| `CFA-S10-005` | Construct rolling symbol-relative news-burst measures | BLOCKED |
| `CFA-S10-006` | Produce realized event-attribution labels | BLOCKED |
| `CFA-S10-007` | Independently validate exact Stage 10 outputs | BLOCKED |
| `CFA-S10-008` | Freeze per-symbol findings / scanner prerequisites | BLOCKED |

No scanner implementation may be treated as validated until these per-symbol prerequisites are resolved and a separate live-time scanner contract is frozen.