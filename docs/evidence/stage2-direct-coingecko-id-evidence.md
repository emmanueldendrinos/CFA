# CFA Stage 2 Direct CoinGecko ID Evidence

- Seed rows: 10
- HTTP 200 + returned-id PASS: 9
- HTTP 404: 1
- HTTP 200 parse/nonmatching failures: 0
- Other HTTP failures: 0

Each seed is verified directly against the keyless CoinGecko `/coins/{id}` endpoint. UNVERIFIED mapping bases may be probed for new evidence; APPROVED bases must retain exactly matching direct-adjudication evidence seeds and must refresh as HTTP 200 with a matching returned ID before evidence is replaced. Response bytes are not committed; SHA-256 and bounded identity fields are published. 404s, parse anomalies, and other source failures on exploratory seeds remain explicit UNVERIFIED evidence and are not converted into mapping decisions.

Evidence table: `candidate-analysis/CFA-Stage2-Direct-CoinGecko-ID-Evidence.csv`.
