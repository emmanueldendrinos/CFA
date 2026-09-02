# CFA Stage 8 PLS independent validation and freeze evidence — 2026-09-02

Status: **INDEPENDENT_PLS_VALIDATION_PASS / CFA-S8-007_PASS / CFA-S8-008_PASS / STAGE8_FROZEN**

## Authority and scope

This evidence records the direct local independent validation of the exact Stage 8 PLS1/NIPALS run constructed from the frozen Stage 7 model-ready handoff. It does not redefine the Stage 7 population, predictor order, response, split, embargoes, preprocessing, benchmark plan, metrics, or component-selection rule.

The independent validator uses separate Stage 8 numerical/preprocessing implementations and does not reuse the production Stage 8 PLS core/data helpers.

## Direct local independent-validation result

Command output reported:

```text
CFA STAGE 8 INDEPENDENT PLS VALIDATION: PASS
TRAIN / VALIDATION / TEST rows: 15648 / 5323 / 5366
Component grid independently recomputed: 1..7
Selected components independently reproduced: 3
VALIDATION RMSE / MAE / predictive R2: 0.068614084978703485 / 0.043997861829303833 / -0.00072357513200893564
TEST RMSE / MAE / predictive R2: 0.058926318333538494 / 0.040292869396394509 / -0.012773367332183039
TEST used for component selection: False
CFA-S8-007 independent validation: PASS
CFA-S8-008 Stage 8 freeze: UNVERIFIED
```

The local validator deliberately emitted `CFA-S8-008 = UNVERIFIED` because repository evidence had not yet pinned the exact validated hashes. This repository evidence performs that final freeze adjudication without changing any model artifact or numerical result.

## Exact validated Stage 8 hashes

- Stage 8 run receipt SHA-256: `ea48186f90f78b50e8ad4874e94601099eef3102bdf222af5ba757c018c041d8`;
- validation component metrics SHA-256: `44cbd19d9e081d5ba7944271bcc0ec7112befadd9df41b02cc866be9d9c77d09`;
- validation selected predictions SHA-256: `3fc83b0760ad534fe9408fc2578ad7b82f76fb4c56fefb95e8f94751abdf2a64`;
- TEST selected predictions SHA-256: `9e6c952ca53e7b9098250a7ff23988edf509e3077166bac4e32bd7eb2d63fd53`;
- benchmark metrics SHA-256: `4362437c7501fcb728ac77afcdb721df1b9ab84fe2159cb03ec4b61e2149dd1c`;
- selected coefficients SHA-256: `538037de7cc16feddb38b136930e2cf09562b2a32f4517d79aa6fbddb45c0d3c`;
- selected model SHA-256: `8aaf69b56756dd45001514e4029065719bec9e1cde425830e2b7e4219f632250`;
- independent validation checks SHA-256: `ae90c737d4a9a60160f5a0f753007397118228618deb00c8812e8d99de1cc6eb`;
- independent validation receipt SHA-256: `950503a0400cd42be9c33b78fc9744c11cdf03b5c860c6f37c2abf9253c9ed33`.

## Exact local artifact locations

Run directory:

`C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10`

Independent validation checks:

`C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10\stage8-pls-independent-validation-checks.csv`

Independent validation receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10\stage8-pls-independent-validation.json`

## Independently reproduced model result

Frozen design:

- TRAIN rows: **15,648**;
- VALIDATION rows: **5,323**;
- TEST rows: **5,366**;
- component grid: **1 through 7**;
- component-selection criterion: `LOWEST_VALIDATION_RMSE`, exact ties to smaller component count;
- selected components: **3**;
- TEST used for component selection: **False**.

Selected VALIDATION metrics:

- RMSE: `0.068614084978703485`;
- MAE: `0.043997861829303833`;
- predictive R² versus `BENCH_RESPONSE_MEAN`: `-0.00072357513200893564`.

Selected TEST metrics:

- RMSE: `0.058926318333538494`;
- MAE: `0.040292869396394509`;
- predictive R² versus `BENCH_RESPONSE_MEAN`: `-0.012773367332183039`.

## Independent checks completed

The direct validator independently reconciled or recomputed:

1. exact frozen Stage 7 source hashes and role cardinalities;
2. phase-specific preprocessing from the frozen Stage 7 parameter artifact;
3. a separate PLS1/NIPALS coefficient path for components 1 through 7;
4. all seven VALIDATION component metrics;
5. selection of 3 components under the frozen validation-only rule;
6. selected VALIDATION predictions and metrics;
7. final TRAIN+VALIDATION refit at 3 components;
8. TEST predictions and metrics;
9. all three frozen benchmark prediction/metric surfaces on VALIDATION and TEST;
10. both selected coefficient sets;
11. candidate prediction key/order/value identity;
12. every Stage 8 output hash and run-receipt lineage;
13. the `TEST used for component selection = False` boundary.

Repository CI for the independent validator also passed under PowerShell 7 and Windows PowerShell 5.1, including independent numerical/data self-tests and a guard prohibiting reuse of `CfaStage8PlsCore.ps1` or `CfaStage8PlsData.ps1`.

## Gate adjudication

- `CFA-S8-001 = PASS` — exact frozen Stage 7 handoff reconciled;
- `CFA-S8-002 = PASS` — deterministic PLS1/NIPALS implementation executed and independently reproduced;
- `CFA-S8-003 = PASS` — exact 1–7 TRAIN→VALIDATION sweep independently reproduced;
- `CFA-S8-004 = PASS` — 3-component selection independently reproduced under the frozen validation-only rule;
- `CFA-S8-005 = PASS` — final TRAIN+VALIDATION refit and one-time TEST evaluation independently reproduced;
- `CFA-S8-006 = PASS` — frozen benchmarks independently validated;
- `CFA-S8-007 = PASS` — exact Stage 8 outputs and hashes independently validated;
- `CFA-S8-008 = PASS` — exact result hashes are now pinned in repository evidence and Stage 8 is frozen.

## Freeze boundary

The frozen Stage 8 result is the exact hash set above. Any change to the Stage 7 handoff, PLS algorithm, component grid, selection rule, preprocessing, benchmark plan, selected component count, predictions, coefficients, metrics, or any pinned artifact requires a new versioned model run and independent validation.

**Stage 8 is frozen. No gate remains unresolved in the required CFA sequence through PLS programming and validation.**
