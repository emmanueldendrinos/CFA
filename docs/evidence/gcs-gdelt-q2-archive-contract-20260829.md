# CFA GDELT Q2 Cloud Storage archival contract — 2026-08-29

Status: **VALIDATION CANDIDATE / UNVERIFIED** until the exact local upload and post-upload reconciliation pass.

Authority boundary: CFA SoT and CFA Stage 1 verified source evidence remain authoritative. This work changes source storage location only. It does not redefine the GDELT source population, news semantics, factors, responses, or any downstream analytical conclusion.

## Purpose

Relocate the verified CFA Q2 GDELT native/base GKG archive corpus from local disk to Google Cloud Storage (GCS) without losing byte identity, source-slot lineage, or reproducibility. BigQuery is not the raw ZIP authority; GCS holds the exact archive bytes and BigQuery/PostgreSQL may hold structured analytical data derived later.

## Frozen tasks

| Task | Requirement | Initial state |
|---|---|---|
| `CFA-GCS-001` | Reconcile the exact PostgreSQL source contract and all 7,163 downloaded source rows against local file size and SHA-256 before upload. | **UNVERIFIED** |
| `CFA-GCS-002` | Resolve one explicit GCS project/bucket/prefix; create the bucket only if absent, using uniform bucket-level access and public-access prevention. | **UNVERIFIED** |
| `CFA-GCS-003` | Upload exactly the 7,163 verified downloaded archives to the frozen raw-object prefix. Do not upload provider-missing slots as empty objects. | **UNVERIFIED** |
| `CFA-GCS-004` | Post-upload reconcile cloud object count, object name, byte size and MD5 against a local one-pass SHA-256+MD5 manifest. Parallel composite uploads are disabled so uploaded objects retain MD5 metadata. | **UNVERIFIED** |
| `CFA-GCS-005` | Upload the bounded source manifest, cloud reconciliation and summary under a separate manifest prefix. | **UNVERIFIED** |
| `CFA-GCS-006` | Local deletion authorization. Local source deletion is permitted only after direct review of an exact all-PASS `CFA-GCS-001..005` receipt. The uploader never deletes local source files. | **BLOCKED** |

## Frozen CFA source identity

- product: `GDELT 2.0 native/base GKG fifteen-minute update archives`
- interval: 2025-04-01 00:00:00 UTC through 2025-07-01 00:00:00 UTC exclusive
- nominal slots: 8,736
- downloaded slots: 7,163
- provider-missing slots: 1,573
- unresolved slots: 0
- source contract SHA-256: `11f3d81f61533efd0b1984c8f84da3e68128c05142923f4e7a62a76c8de9002e`

Provider-missing slots remain represented in PostgreSQL source-slot lineage and are not materialized as fake zero-byte cloud objects.

## Cloud layout

The uploader uses one dedicated raw prefix, default:

`gs://<bucket>/raw/gdelt-gkg-q2-2025/`

Each raw object name is the unique GDELT archive filename from the PostgreSQL `object_key`. Bounded manifests/receipts are stored separately under:

`gs://<bucket>/manifests/gdelt-gkg-q2-2025/<run_id>/`

The raw prefix must contain exactly 7,163 live archive objects after reconciliation.

## Integrity design

1. PostgreSQL remains the source registry for expected `object_key`, local relative path, byte size and SHA-256.
2. Before upload, every local archive is opened once and both SHA-256 and MD5 are computed in the same streaming pass.
3. Local SHA-256 and size must match PostgreSQL exactly before any upload starts.
4. GCS parallel composite uploads are disabled via process-scoped Cloud SDK environment properties. This preserves per-object MD5 metadata.
5. `gcloud storage cp` performs its own transfer checksum validation.
6. After upload, an exhaustive GCS object metadata listing is compared against the local manifest for exact object count/name/size/MD5.
7. The local manifest retains the authoritative PostgreSQL SHA-256 and the independently observed MD5. Cloud MD5 is an additional transport/storage identity check, not a replacement for CFA SHA-256 lineage.

## Safety

- no local source deletion;
- no PostgreSQL writes;
- no BigQuery writes;
- no overwriting cloud objects (`--no-clobber`);
- no parallel composite objects;
- no fake objects for provider-missing slots;
- failures remain explicit and block `CFA-GCS-006`;
- credentials are handled only by existing local `gcloud` authentication and PostgreSQL password process state; no secret is written to evidence.
