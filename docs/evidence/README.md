# CFA Evidence Receipts

This directory contains small curated documentation receipts derived from direct CFA-local validation evidence.

The authoritative observations remain the directly inspected source data and verified PostgreSQL state under the CFA Source of Truth. Raw market/news data, database backups, credentials, full generated outputs, logs, and temporary files remain outside Git.

`latest-local-validation.md` is produced by `scripts/windows/Publish-CfaLocalEvidence.ps1`. The publisher reads the latest approved validation summaries from `Documents\CFA-local`, records bounded CSV evidence needed for review, records SHA-256 hashes of every local evidence file used, excludes absolute local paths, and can commit and push only that receipt when the working tree is otherwise clean.

Use `-SelfTest` to validate the publisher without touching repository evidence. Use `-CommitAndPush` only after the relevant local validation runs have completed.
