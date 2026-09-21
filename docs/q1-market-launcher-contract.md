# Q1 market reconciliation launcher — frozen correction v1

Task: Q1-MKT-002. This additive correction addresses the reported failure to
start Q1-MKT-001 under a Restricted PowerShell execution policy. It preserves
the original Q1-MKT-001 requirements and all source, database, prior evidence,
bootstrap, manifest and SoT bytes. The reconciliation runtime is unchanged.

| ID | Frozen requirement / exit evidence |
| --- | --- |
| Q1-MKT-002-LAUNCH | Start the pinned, hash-checked runner in a fresh instance of the current PowerShell executable using `-NoProfile -ExecutionPolicy RemoteSigned -File`, with the same bound evidence paths. This setting is process-scoped only. Do not change registry policies, unblock files, or circumvent MachinePolicy/UserPolicy. |
| Q1-MKT-002-TEST | On Windows PowerShell 5.1 and PowerShell 7, reproduce the original script rejection under Restricted in an isolated parent process. From that same restricted parent, verify that the corrected invocation completes the full reconciliation against the disposable PostgreSQL fixture, including the bootstrap child. Assert no evidence was created by the rejected launch, validate the successful receipt and all artifact hashes, and compare persistent policy scopes before and after. Rerun all existing exact-candidate tests. |
| Q1-MKT-002-PRESERVE | Preserve runtime hashes, bound inputs, previous evidence and user/machine execution-policy settings. Group Policy remains authoritative; an enforced incompatible policy remains a reported block. |
| Q1-MKT-002-LOCAL | The corrected invocation remains a VALIDATION CANDIDATE until the intended Windows machine completes it and its evidence is reviewed. Q1-MKT-001-LOCAL remains UNVERIFIED and Stage 1 BLOCKED meanwhile. |

Microsoft documents the process-only effect and Group Policy precedence in
[about_PowerShell_exe](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe?view=powershell-5.1)
and [about_Execution_Policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1).
