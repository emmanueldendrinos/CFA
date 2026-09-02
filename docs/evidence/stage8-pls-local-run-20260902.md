# CFA Stage 8 PLS local run — validation candidate — 2026-09-02

Status: **PLS_LOCAL_RUN_PASS / CFA-S8-001_THROUGH_CFA-S8-006_PASS / CFA-S8-007_BLOCKED / CFA-S8-008_BLOCKED**

## Direct local evidence

Repository branch: `cfa/stage8-pls-20260902`.

Observed local repository HEAD before execution:

`d51239c23ae5388da13e040775b9954b78ec5f21`

Command used the frozen Stage 7 independent-validation receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-ready\20260902-134023-04e30bf2c0ee4dfdb42cf88a0db2b259\stage7-model-ready-independent-validation.json`

Direct console result:

```text
CFA STAGE 8 PLS1/NIPALS RUN: VALIDATION CANDIDATE
TRAIN / VALIDATION / TEST rows: 15648 / 5323 / 5366
Component grid: 1..7
Selected components by VALIDATION RMSE: 3
Selected VALIDATION RMSE / MAE / predictive R2: 0.068614084978703485 / 0.043997861829303833 / -0.00072357513200893564
Selected TEST RMSE / MAE / predictive R2: 0.058926318333538494 / 0.040292869396394509 / -0.012773367332183039
TEST used for component selection: False
CFA-S8-001 through CFA-S8-006: PASS
CFA-S8-007 independent validation: BLOCKED
CFA-S8-008 Stage 8 freeze: BLOCKED
Validation component metrics: C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10\stage8-validation-component-metrics.csv
Benchmark metrics: C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10\stage8-benchmark-metrics.csv
Selected model: C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10\stage8-selected-model.json
Run receipt: C:\Users\Emmanuel\Documents\CFA-local\stage8-pls\20260902-142832-b4589e2b996d4cbba48378f9ae83dd10\stage8-pls-run-receipt.json
```

## Adjudication

The run entered from the frozen Stage 7 handoff and completed the frozen Stage 8 workflow. The component grid was exactly 1 through 7. The selected component count was **3**, chosen by VALIDATION RMSE. The console explicitly reports that TEST was not used for component selection.

Accordingly:

- `CFA-S8-001 = PASS` — frozen Stage 7 entry accepted by the executable;
- `CFA-S8-002 = PASS` — PLS1/NIPALS numerical path executed after repository self-test validation;
- `CFA-S8-003 = PASS` — 1–7 validation component sweep completed;
- `CFA-S8-004 = PASS` — component count 3 selected by frozen validation rule;
- `CFA-S8-005 = PASS` — final TRAIN+VALIDATION refit and one TEST evaluation completed after selection;
- `CFA-S8-006 = PASS` — frozen benchmark workflow completed and benchmark artifact was emitted;
- `CFA-S8-007 = BLOCKED` — exact predictions, component metrics, coefficients, benchmarks, selection, and hashes require independent recomputation;
- `CFA-S8-008 = BLOCKED` — Stage 8 cannot freeze before independent validation PASS.

No model-performance conclusion is frozen from this construction run alone. The observed component count and metrics are validation candidates pending independent recomputation.
