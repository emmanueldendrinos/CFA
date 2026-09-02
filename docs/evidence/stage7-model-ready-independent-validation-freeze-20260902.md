# CFA Stage 7 independent model-ready validation and freeze evidence — 2026-09-02

Status: **CFA-S7-001_PASS / CFA-S7-002_PASS / CFA-S7-003_PASS / CFA-S7-004_PASS / CFA-S7-005_PASS / CFA-S7-006_PASS / CFA-S7-007_PASS / CFA-S7-008_PASS / STAGE7_FROZEN**

## Source

Direct local execution output supplied after running the Stage 7 independent model-ready validator against the exact Stage 7 candidate receipt and its referenced frozen Stage 4/5 inputs, eligibility artifacts, split assignment, embargo exclusions, preprocessing parameters, and benchmark plan.

Local validation checks:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-ready\20260902-134023-04e30bf2c0ee4dfdb42cf88a0db2b259\stage7-model-ready-independent-validation-checks.csv`

Local independent validation receipt:

`C:\Users\Emmanuel\Documents\CFA-local\stage7-model-ready\20260902-134023-04e30bf2c0ee4dfdb42cf88a0db2b259\stage7-model-ready-independent-validation.json`

## Direct observed result

The independent run reported:

- eligible / model / embargo rows: **27,152 / 26,337 / 815**;
- TRAIN / VALIDATION / TEST rows: **15,648 / 5,323 / 5,366**;
- embargo days: **2025-05-17 / 2025-05-31**;
- preprocessing parameters independently validated: **16**;
- benchmark plan independently validated: **PASS**;
- `CFA-S7-003` through `CFA-S7-007`: **PASS**.

The model + embargo partition reconciles exactly to the frozen all-seven-eligible population:

`26,337 + 815 = 27,152`.

## Exact validated hashes

- candidate receipt SHA-256: `9913ae948894c26ebdbf284e25b9268109c9c645eeceb33b1195de690ef04702`;
- model-ready CSV SHA-256: `fc0498881957688acffd6fe3805ac96037ca884304bff9964e1e248b4ec0e024`;
- split assignment SHA-256: `4a0878a60ba16dfaddc10591931ec4c659efe7c04415338805f660a998625874`;
- embargo exclusions SHA-256: `d938a382a4a8bb654d07d678fcebfe887a32933b0c1c5195104f38e3017c4fdd`;
- preprocessing parameters SHA-256: `8a2a02676236b31d05dbdba6e11f8cd4f4086973448958337e0ee50c52329578`;
- benchmark plan SHA-256: `9b2fd8c9deae62b7c8bf1e04df6ec4d8926844fb8becd995e1efacb927399f9c`;
- independent validation checks SHA-256: `e591ca703ce68dd5b6d92c9dc770da57d042ec1a3462591473ec2737a98a6cef`;
- independent validation receipt SHA-256: `e3e9088e511b74e875e1bccc3e8d292acc9c49209c93943117195f8ace5b3756`.

## Independent checks established

The independent validator directly rechecked the exact candidate rather than relying on constructor PASS flags. Its scope included:

- exact upstream frozen Stage 4/5 source hashes and Stage 7 candidate lineage;
- complete accounting of all **27,152** eligible keys across model and embargo outputs;
- exact **26,337** model-row key identity and preserved frozen predictor/response values;
- exact chronological role assignment and embargo dates;
- response-availability separation across TRAIN→VALIDATION and VALIDATION→TEST;
- direct recomputation of all **16** phase/variable preprocessing parameters from permitted fit roles;
- fixed benchmark-plan identity and component-selection policy;
- exact hashes of all model-ready design artifacts.

No Stage 8 PLS result or held-out test performance was used to define or validate this design.

## Gate adjudication

`CFA-S7-008 = PASS` — the exact model-ready dataset, split/embargo design, preprocessing parameters, benchmark plan, and lineage are independently validated and hash-pinned.

Therefore Stage 7 is **FROZEN** on the exact hashes above. The predictor matrix, response vector, retained population, chronological validation/test design, preprocessing, leakage controls, and benchmark plan are now fixed.

Stage 8 PLS programming is admissible only from this exact frozen handoff. Any change to the Stage 7 population, matrix, split, preprocessing, benchmark plan, or hashes requires a new versioned Stage 7 design and revalidation.
