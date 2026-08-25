# CFA Reference Source Reconciliation

Exact current repository bytes and parsed CSV shape compared against AF-001/AF-002/AF-003 in the current CFA SoT authority snapshot.

| Source | Rows | Columns | Bytes | SHA-256 | Repair | Overall |
|---|---|---|---|---|---|---|
| AF-001 | PASS 1059/1059 | PASS 16/16 | PASS 355619/355619 | PASS | NOT_APPLICABLE  | PASS |
| AF-002 | PASS 435/435 | PASS 11/11 | PASS 308626/308626 | PASS | NOT_APPLICABLE  | PASS |
| AF-003 | PASS 45/45 | PASS 6/6 | PASS 4621/4621 | PASS | REPAIRED_AND_VERIFIED UTF8_LF_NO_BOM | PASS |

## AF-001 â€” ASRP-Q2-Pair-Identity-Frozen-v1.0.0.csv

- Expected SHA-256: 569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f
- Observed SHA-256: 569522ec450ab1870ffa1386f4e356e4047cf6ef017c77a98a3bedcf331f416f
- Line endings: CRLF=1060, LF-only=0, CR-only=0
- UTF-8 BOM: True
- Authority: Analyzed source file
- Boundary: Contains pair identities and counts; it does not contain raw market observation rows.

## AF-002 â€” ASRP-Q2-News-Hype-CoinGecko-Mapping-Candidates-20260818-120451-583-f5fd1391.csv

- Expected SHA-256: ff7e1283b0f543213d9946bbb0828f2b20283e232db00bc379dad4fe9bc2f2c7
- Observed SHA-256: ff7e1283b0f543213d9946bbb0828f2b20283e232db00bc379dad4fe9bc2f2c7
- Line endings: CRLF=436, LF-only=0, CR-only=0
- UTF-8 BOM: True
- Authority: Candidate data only
- Boundary: All mappings remain unapproved; candidate records are not final asset identities.

## AF-003 â€” ASRP-Q2-GDELT-GKG-Operational-Aliases-v1.0.0.csv

- Expected SHA-256: 8c75e334be54e888b17a70d7945dc43ff2f2d789126eefaee11b4a6d078f7fc4
- Observed SHA-256: 8c75e334be54e888b17a70d7945dc43ff2f2d789126eefaee11b4a6d078f7fc4
- Line endings: CRLF=0, LF-only=46, CR-only=0
- UTF-8 BOM: False
- Authority: Manual reference only
- Boundary: Partial manual coverage; not a complete or validated news-hype vocabulary.

