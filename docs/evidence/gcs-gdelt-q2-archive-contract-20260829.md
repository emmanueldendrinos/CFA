# CFA GDELT Q2 cloud archival contract — 2026-08-29

Status: **VALIDATION CANDIDATE**.

Authority boundary: the verified Q2 GDELT native/base GKG source corpus remains the CFA news-source authority. Google Cloud Storage is only an alternate byte-preserving storage location for those already verified raw archives. BigQuery is not the raw ZIP authority.

Frozen archival gates:

- `CFA-GCS-001`: reconcile PostgreSQL source registry to local downloaded archive population before upload.
- `CFA-GCS-002`: verify local size and SHA-256 for every downloaded source archive before first upload.
- `CFA-GCS-003`: upload exactly the verified downloaded archive population to one bounded GCS raw prefix.
- `CFA-GCS-004`: reconcile cloud object name, size and MD5 to the frozen local manifest.
- `CFA-GCS-005`: prove no unexpected extra raw objects exist in the bounded raw prefix.
- `CFA-GCS-006`: authorize local source deletion only after direct review of an exact all-PASS cloud receipt.

Resume gates after completed local validation:

- `CFA-GCS-R01`: reuse only the exact completed 7,163-row local manifest and reconcile it back to PostgreSQL object key/path/size/SHA-256.
- `CFA-GCS-R02`: verify each local source file still exists and retains the same size recorded by the completed manifest.
- `CFA-GCS-R03`: create/reuse the bounded GCS bucket and upload/resume the corpus without altering local files.
- `CFA-GCS-R04`: require final exact cloud object count/name/size/MD5 reconciliation.
- `CFA-GCS-R05`: local deletion authorization remains **BLOCKED** pending direct review.

Observed target-host defects and corrections:

1. Windows selected `gcloud.ps1`, which was blocked by execution policy. Corrected by explicit `gcloud.cmd`/`gcloud.exe` resolution.
2. Windows PowerShell 5.1 produced null text for empty redirected native streams. Corrected by explicit string normalization.
3. The initial per-command project argument construction was malformed. Resume path uses process-scoped `CLOUDSDK_CORE_PROJECT` instead.
4. The completed local validation run `20260829-081354-ddb0416d678f418a8d418fbc86501f6d` produced 7,163 manifest rows with SHA-256 `d33f6d28b1f061de7c8ef34b6d7325329e2b85175679ac28f15b1a47b63e8418` and subsequently reconciled PASS back to PostgreSQL.
5. V4/V5 bucket probes returned the expected 404 for a missing bucket, but Windows PowerShell 5.1 promoted native stderr into a terminating error before wrapper exit-code handling because `$ErrorActionPreference='Stop'`. V6 temporarily uses `Continue` only for the native `gcloud` invocation, captures stderr itself, restores the caller setting, then enforces the exit code in the wrapper. Its regression emits native stderr and exits 7 under `$ErrorActionPreference='Stop'`.

Current resume artifact: `scripts/windows/Resume-CfaGdeltQ2ToGcsV6.ps1`.

V6 preserves the V5 resume design: it does not rehash the 36 GB corpus; it reuses and reconciles the completed manifest, creates the missing bucket when the probe returns 404, resumes with `gcloud storage rsync --recursive`, supports the current `gcloud storage ls --json` direct and metadata-wrapper object shapes, and performs exact final cloud reconciliation.

No archival script deletes the local GDELT source corpus.
