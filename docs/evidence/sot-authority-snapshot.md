# CFA Source of Truth â€” Text Authority Snapshot

Generated reproducibly from CFA-SoT.xlsx without Excel automation. The workbook remains the authority; this snapshot is a review surface only.

- Workbook size bytes: 15982
- Workbook SHA-256: a7597f4a310985ef7083ce8621e1a326370729c9f9cab1a835e04aa1a8176785
- Worksheet count: 3

## Authority-ID hits

No DATA-### identifiers were found.

## Sheet: Mission

XLSX entry: xl/worksheets/sheet1.xml

| Row | A | B | C | D | E | F | G | H |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | CFA — Source of Truth |  |  |  |  |  |  |  |
| 2 | Authoritative handover for a new candidate-factor analysis project |  |  |  |  |  |  |  |
| 4 | Authority | This workbook is the sole project-control authority at handover. |  |  |  |  |  |  |
| 5 | Scope | Candidate-universe evidence and candidate-identity scan conclusions only. |  |  |  |  |  |  |
| 6 | Authoritative inputs | The three exact CSV files listed on the Analyzed Files sheet. |  |  |  |  |  |  |
| 7 | Transferred implementation | None. Code, SQL, models, tests, packages, and prior project context are excluded. |  |  |  |  |  |  |
| 8 | Start condition | The new project starts from this workbook and those three source files only. |  |  |  |  |  |  |
| 10 | 1. Mission |  |  |  |  |  |  |  |
| 11 | Analyze the retained candidate universe to determine which market and news-hype factors can be defined, supported, and tested from verified source data. The immediate objective is to establish reliable candidate identities and evidence requirements. Only after those definitions are validated will the project derive code and prepare a predictor/response design suitable for programming a Partial Least Squares (PLS) model. |  |  |  |  |  |  |  |
| 12 |  |  |  |  |  |  |  |  |
| 13 |  |  |  |  |  |  |  |  |
| 14 |  |  |  |  |  |  |  |  |
| 16 | In scope |  |  |  | Out of scope at handover |  |  |  |
| 17 | • Validate the 435-asset candidate universe. |  |  |  | • Importing prior ASRP code, SQL, tests, packages, or conclusions. |  |  |  |
| 18 | • Resolve or reject CoinGecko identity candidates. |  |  |  | • Treating any CoinGecko candidate as an approved mapping. |  |  |  |
| 19 | • Review manual alias coverage before news matching. |  |  |  | • Treating manual aliases as complete news-hype terminology. |  |  |  |
| 20 | • Define candidate factors from verified market/news sources. |  |  |  | • Computing market or news factors from these three files alone. |  |  |  |
| 21 | • Derive code only after definitions and evidence are explicit. |  |  |  | • Programming or fitting PLS before factor design is validated. |  |  |  |
| 23 | Handover boundary |  |  |  |  |  |  |  |
| 24 | No prior conversation, memory, implementation, validation record, or inferred conclusion is transferred. Old filenames are retained only to preserve source provenance. A fact becomes authoritative in CFA only when it is stated in this workbook and supported by one of the exact source files listed here, or by new evidence added later through an explicit SoT revision. |  |  |  |  |  |  |  |
| 25 |  |  |  |  |  |  |  |  |
| 26 |  |  |  |  |  |  |  |  |
| 27 |  |  |  |  |  |  |  |  |

## Sheet: Rules

XLSX entry: xl/worksheets/sheet2.xml

| Row | A | B | C | D | E |
| ---: | --- | --- | --- | --- | --- |
| 1 | 2. Rules |  |  |  |  |
| 2 | Clarity, consistency, logical flow, evidence discipline, and prevention of avoidable errors |  |  |  |  |
| 4 | Rule ID | Principle | Rule | Required evidence | Failure state |
| 5 | R-001 | Clarity | Use one defined term for one concept. Distinguish source observation, candidate, reference, decision, and derived result. | Definitions and status are explicit in the SoT. | Ambiguous |
| 6 | R-002 | Clarity | State unknown, missing, null, unresolved, and unverified values directly. Do not replace them with guesses. | The unresolved state remains visible. | Blocked |
| 7 | R-003 | Clarity | Identify every source by exact filename and SHA-256 before relying on it. | Hash matches the Analyzed Files registry. | Rejected source |
| 8 | R-004 | Consistency | This workbook controls mission, rules, accepted conclusions, and scope. Source files control their recorded observations. | No conflicting authority is used. | Conflict |
| 9 | R-005 | Consistency | Do not import prior code, methods, conclusions, task registries, or conversation context. | New work cites only CFA SoT and CFA source files. | Context leak |
| 10 | R-006 | Consistency | Code, SQL, schemas, and models must be derived from current SoT decisions, never the reverse. | Implementation traces to an approved rule or decision. | Unauthorized |
| 11 | R-007 | Logical flow | Proceed in order: inspect source → validate structure → measure facts → state conclusion → design method → implement → test. | Each stage has direct evidence. | Premature step |
| 12 | R-008 | Logical flow | Do not program PLS until candidate factors, response variables, timing, leakage controls, and validation design are explicit. | PLS readiness is separately approved later. | Not ready |
| 13 | R-009 | Evidence | Candidate identity is not approval. A single candidate still requires review; multiple candidates require disambiguation; zero candidates remain unresolved. | An explicit approved mapping decision exists. | Unapproved |
| 14 | R-010 | Evidence | Manual aliases are seed references only. Their coverage and context requirements must be tested against raw news data. | Alias validation evidence exists. | Reference only |
| 15 | R-011 | Error prevention | Inspect actual types, nulls, arrays, cardinality, encoding, quoting, and boundaries. Do not infer behavior from names or documentation alone. | Direct parse and boundary tests pass. | Unverified |
| 16 | R-012 | Error prevention | Prefer parsed structures and exact comparisons over fragile text or regex proxies. | Parser/object-model evidence exists. | Invalid test |
| 17 | R-013 | Error prevention | Test the exact final artifact in the intended runtime and workflow. Source-only or earlier-build tests do not prove it. | Exact-artifact test passes. | Validation candidate |
| 18 | R-014 | Error prevention | Any correction invalidates dependent tests, packages, hashes, receipts, and conclusions; rerun affected stages. | Downstream evidence is regenerated. | Stale evidence |
| 19 | R-015 | Completion | Claim PASS only when every required gate has direct evidence. Otherwise use FAIL, UNVERIFIED, BLOCKED, or NOT_APPLICABLE. | All gates reconciled. | Incomplete |

## Sheet: Analyzed Files

XLSX entry: xl/worksheets/sheet3.xml

| Row | A | B | C | D | E | F | G | H | I |
| ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 3. Analyzed Files and Supported Conclusions |  |  |  |  |  |  |  |  |
| 2 | Only facts measured directly from the three registered CSVs are authoritative on this sheet. |  |  |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |  |  |  |
| 4 | Authoritative source registry |  |  |  |  |  |  |  |  |
| 5 | Source ID | Exact file name | SHA-256 | Bytes | Data rows | Columns | Role | Authority | Boundary |
| 6 | AF-001 | ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv | 569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f | 355619 | 1059 | 16 | Market-pair identity and observation-count index | Analyzed source file | Contains pair identities and counts; it does not contain raw market observation rows. |
| 7 | AF-002 | ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv | ff7e1283b0f543213d9946bbb0828f2b20283e232db00bc379dad4fe9bc2f2c7 | 308626 | 435 | 11 | CoinGecko identity-candidate scan | Candidate data only | All mappings remain unapproved; candidate records are not final asset identities. |
| 8 | AF-003 | ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv | 8c75e334be54e888b17a70d7945dc43ff2f2d789126eefaee11b4a6d078f7fc4 | 4621 | 45 | 6 | Manual alias seeds for later news matching | Manual reference only | Partial manual coverage; not a complete or validated news-hype vocabulary. |
| 9 |  |  |  |  |  |  |  |  |  |
| 10 | Pair identity facts |  |  | CoinGecko candidate facts |  |  | Alias facts |  |  |
| 11 | Source members | 1059 |  | Base assets scanned | 435 |  | Alias rows | 45 | Eligibility % |
| 12 | Research eligible | 1058 |  | Current candidate records | 1005 |  | Assets covered | 43 | =B12/B11 => 0.9990557129367328 |
| 13 | Eligible base assets | 435 |  | Single candidate | 233 |  | Manual names | 43 | Alias coverage % |
| 14 | Official pair keys | 927 |  | Ambiguous candidates | 182 |  | Manual symbols | 2 | =H12/E11 => 0.09885057471264368 |
| 15 | Typed observations | 14055089 |  | No current candidate | 20 |  | Crypto context required | 14 | Context-required % |
| 16 | Valid evidence JSON rows | 1059 |  | Approved mappings | 0 |  | Assets without alias | 392 | =H15/H11 => 0.3111111111111111 |
| 17 |  |  |  |  |  |  |  |  |  |
| 18 | CoinGecko mapping status |  |  |  |  | Cross-file consistency checks |  |  |  |
| 19 | Status | Assets | % of 435 | Interpretation |  | Check | Observed A | Observed B | Result |
| 20 | Single current candidate — review required | 233 | =B20/$E$11 => 0.535632183908046 | One candidate is not approval. |  | Eligible base-asset universe | 435 | 435 | MATCH |
| 21 | Ambiguous current candidates | 182 | =B21/$E$11 => 0.41839080459770117 | Identity must be disambiguated. |  | Eligible pair-member total | 1058 | 1058 | MATCH |
| 22 | No current candidate | 20 | =B22/$E$11 => 0.04597701149425287 | Identity remains unresolved. |  | Typed observation total | 14055089 | 14055089 | MATCH |
| 23 | Approved mapping | 0 | =B23/$E$11 => 0 | No asset is approved in this file. |  | Candidate JSON rows parsed | 435 | 435 | MATCH |
| 24 |  |  |  |  |  | Candidate JSON hashes verified | 435 | 435 | MATCH |
| 25 |  |  |  |  |  |  |  |  |  |
| 26 | Supported conclusions |  |  |  |  |  |  |  |  |
| 27 | Conclusion ID | Conclusion |  |  |  | Direct evidence |  |  | Authority status |
| 28 | C-001 | The research-eligible candidate universe contains 435 base assets. |  |  |  | AF-001 has 1,058 eligible pair members across 435 unique base assets; AF-002 contains the same 435 assets. |  |  | SUPPORTED |
| 29 | C-002 | No CoinGecko mapping is approved. |  |  |  | AF-002 has 435 rows and every mapping_approved value is False. |  |  | SUPPORTED |
| 30 | C-003 | The candidate scan found 1,005 current CoinGecko candidate records: 233 assets have one candidate, 182 have multiple candidates, and 20 have none. |  |  |  | Counts measured directly from AF-002. |  |  | SUPPORTED |
| 31 | C-004 | AF-001 indexes 14,055,089 typed market observations but does not contain the raw observation rows required to compute factors. |  |  |  | AF-001 row counts and schema contain identities/counts, not market-value columns. |  |  | SUPPORTED |
| 32 | C-005 | Manual aliases cover 43 of 435 assets (45 aliases total); 392 assets have no alias entry in AF-003. |  |  |  | AF-003 unique base-asset and alias counts compared with AF-002. |  |  | SUPPORTED |
| 33 | C-006 | The alias file is a seed reference, not a validated or complete news-hype vocabulary. |  |  |  | AF-003 is manual, partial, and includes context requirements. |  |  | SUPPORTED |
| 34 | C-007 | These files do not contain news-hype factor values, market factor values, response variables, or a PLS-ready matrix. |  |  |  | Schemas of AF-001, AF-002, and AF-003. |  |  | SUPPORTED |
| 35 | C-008 | The new CFA project must derive methods and code afresh; the three files may be used only for candidate scoping and identity review. |  |  |  | Mission and Rules sheets plus file boundaries. |  |  | AUTHORITATIVE RULE |
| 36 |  |  |  |  |  |  |  |  |  |
| 37 | Highest candidate-count examples (not approved mappings) |  |  |  |  |  |  |  |  |
| 38 | Asset | Exchange symbol | Candidate count | Q2 pair count | Typed observations |  |  |  |  |
| 39 | USDC | USDC | 60 | 7 | 400719 |  |  |  |  |
| 40 | USDT | USDT | 48 | 7 | 426863 |  |  |  |  |
| 41 | WBTC | WBTC | 36 | 3 | 15628 |  |  |  |  |
| 42 | DAI | DAI | 28 | 3 | 22057 |  |  |  |  |
| 43 | PEPE | PEPE | 21 | 5 | 154492 |  |  |  |  |
| 44 | MOON | MOON | 15 | 2 | 4753 |  |  |  |  |
| 45 | CAT | CAT | 15 | 2 | 1896 |  |  |  |  |
| 46 | XETH | ETH | 14 | 12 | 551236 |  |  |  |  |
| 47 | SOL | SOL | 11 | 9 | 523568 |  |  |  |  |
| 48 | DOG | DOG | 11 | 2 | 3688 |  |  |  |  |
| 49 |  |  |  |  |  |  |  |  |  |
| 50 |  |  |  |  |  |  |  |  |  |

