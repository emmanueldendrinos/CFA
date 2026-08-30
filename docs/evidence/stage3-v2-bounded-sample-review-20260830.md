# CFA Stage 3 V2 bounded semantic sample review — 2026-08-30

Status: **FAIL**

## Reviewed evidence

- Source bounded review CSV SHA-256: `d7a0ac5d2ccd39b6a0269a791de999f1e217db730e5ad10b6c3c169964de89c9`
- Source Stage 3 V2 sample SHA-256: `25750b08979065762f73234fd251c176d4c057df7bfa471fadaf9c442a2973b3`
- Source sample rows: 4,350
- Source sample decisions: 1,750 `MATCH`; 2,600 `REJECT_CONTEXT`
- Deterministic bounded review rows: 24
- Review decisions represented: 22 `MATCH`; 2 `REJECT_CONTEXT`
- Automatic rule-consistency validation: PASS before direct semantic review

The review evaluates only the supplied 24 deterministic stratified rows and does not infer unobserved article text.

## Blocking finding

| Review row | Current result | Finding | Decision |
|---|---|---|---|
| S3R-018 | MATCH `IP` | Page title: `North Korean Hackers Use Russian IP Infrastructure`. The uppercase token `IP` clearly denotes Internet Protocol / infrastructure in the title, not the Kraken `IP` asset. The candidate is admitted because `ECON_BITCOIN=True` even though `title_crypto_anchor=False`. | FALSE_POSITIVE |

Any clear false positive is sufficient for CFA-S3-005 to fail.

## Other reviewed rows

The remaining 23 rows show no obvious blocking semantic error from the supplied evidence. In particular:

- `NOT` is explicitly identified by a Notcoin price headline containing `(NOT)`.
- `POL`, `LINK`, `FLR`, and `OM` occur in clearly crypto-specific page titles.
- Approved long-form aliases including `Binance Coin`, `Bitcoin Cash`, `Internet Computer`, `Render Network`, `Shiba Inu`, `Aptos`, `Arbitrum`, and `Artificial Superintelligence Alliance` show no obvious false positive in the bounded evidence.
- The two reviewed context rejects (`RLC`, `BLZ`) are correctly rejected in non-crypto title contexts.

## Failure mechanism

V2 fixed the V1 ordinary-word case-insensitivity problem, but uppercase evidence alone is still insufficient for very short symbol aliases that are common acronyms. In S3R-018, the two-letter default symbol `IP` is ordinary technical prose. `ECON_BITCOIN` alone then admits the candidate despite the absence of crypto-specific title evidence.

## Gate decision

- `CFA-S3-005`: **FAIL**
- `CFA-S3-006`: **BLOCKED**

Stage 3 must not be frozen from V2 output.

## Candidate V3 corrective direction

Apply one additional deterministic rule to default Kraken symbol-only aliases of length one or two characters:

- they may not be accepted on `ECON_BITCOIN` alone;
- they require `TITLE_CRYPTO` evidence unless an independently approved non-default alias for the same asset also matched the record.

This directly rejects the observed `IP` false positive while retaining reviewed `OM`, whose title contains explicit crypto context. The rule can be applied as a lineage-preserving post-filter to the completed V2 output, avoiding another 9.18-million-row source rescan. V3 remains UNVERIFIED until the post-filter is executed and a new bounded semantic review passes.
