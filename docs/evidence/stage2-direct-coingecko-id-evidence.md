# CFA Stage 2 Direct CoinGecko ID Evidence

- Seed rows: 20
- HTTP 200 + returned-id PASS: 7
- HTTP 404: 10
- HTTP 200 parse/nonmatching failures: 1
- Other HTTP failures: 2

Each seed is verified directly against the keyless CoinGecko `/coins/{id}` endpoint. Response bytes are not committed; SHA-256 and bounded identity fields are published. 404s, parse anomalies, and other source failures remain explicit UNVERIFIED evidence and are not converted into mapping decisions.

Evidence table: `candidate-analysis/CFA-Stage2-Direct-CoinGecko-ID-Evidence.csv`.
