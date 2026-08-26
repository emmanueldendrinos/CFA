# CFA Stage 2 Alias Semantic Decisions

- Decision rows: 45
- APPROVED_ALIAS_IDENTITY: 45
- UNVERIFIED: 0
- CFA-S2-005 Alias semantic validation: PASS
- CFA-S2-006 Advance to news matching definition: BLOCKED

Scope: these decisions validate the relationship between each AF-003 seed and its asset. They do **not** approve exact-string matching, the diagnostic strict/broad context rules, or any news-factor formula. Collision handling is a Stage 3 design requirement.

Evidence policy: 38 aliases have at least one bounded GDELT sample satisfying the conservative high-confidence context diagnostic. Six collision-heavy observed aliases and the unobserved MakerDAO seed are independently corroborated by official project sources reviewed on 2026-08-26.

Decision table: `candidate-analysis/CFA-Stage2-Alias-Semantic-Decisions.csv`.
