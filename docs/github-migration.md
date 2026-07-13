# GitHub migration runbook

The migration has two intentionally separate commands:

- `New-GitHubMigrationDryRun.ps1` reads GitHub and writes an immutable proposal ledger.
- `Invoke-GitHubMigration.ps1` applies one reviewed ledger in small, resumable batches.

The apply command never deletes repository label definitions. Definition cleanup happens only after all item migrations have been reconciled and a new audit reports zero remaining uses.

## 1. Generate a fresh plan

Generate one organization at a time so each approval and evidence set remains small:

```powershell
./scripts/New-GitHubMigrationDryRun.ps1 `
    -Organizations pylesoft `
    -OutputDirectory ./artifacts/pylesoft-dry-run
```

Review the generated Markdown summary, repository CSV, item CSV, errors CSV, and full JSON ledger. Apply is blocked when the plan contains repository read errors. Rows marked `manual_review` are retained in the evidence but skipped without mutation.

Schema 2 plans capture the source issue update time and current Priority. The apply command rejects older plan schemas and plans older than 24 hours by default.

## 2. Pin the reviewed plan

Calculate the exact SHA-256 after review:

```powershell
$plan = './artifacts/pylesoft-dry-run/github-migration-dry-run-YYYYMMDDTHHMMSSZ.json'
$sha256 = (Get-FileHash -Algorithm SHA256 $plan).Hash
```

Any change to the JSON after approval changes the hash and blocks apply.

## 3. Run a canary

Select one low-risk repository and a small batch:

```powershell
./scripts/Invoke-GitHubMigration.ps1 `
    -PlanPath $plan `
    -PlanSha256 $sha256 `
    -Apply `
    -Organizations pylesoft `
    -Repositories example-repository `
    -BatchSize 5
```

The command checks for post-plan drift before the first mutation. For each item it:

- Saves the before state and ensures canonical replacement label definitions exist.
- Applies native type and the complete final label set atomically through one issue update.
- Applies Priority separately when required by GitHub's organization issue-field API.
- Reads the final state once, saves the after state, and records verification evidence for every migrated field and removed legacy label.

The run directory contains the immutable run manifest, event checkpoint ledger, before/after item snapshots, label-definition backups, and the latest summary.

## 4. Resume reviewed batches

After reviewing the canary evidence, repeat the exact command with `-Resume`. Each invocation processes at most `BatchSize` pending items:

```powershell
./scripts/Invoke-GitHubMigration.ps1 `
    -PlanPath $plan `
    -PlanSha256 $sha256 `
    -Apply `
    -Organizations pylesoft `
    -Repositories example-repository `
    -BatchSize 25 `
    -Resume
```

A failed item stops the batch by default. Correct the permission, API, or data issue and use `-Resume`; verified items are not repeated, while partially completed items converge idempotently from their recorded state. Organization and repository filters cannot change within a run.

For large plans, independent workers may use `-ShardCount` with a unique zero-based `-ShardIndex` and `-RunId`. Sharding deterministically assigns each organization/repository/number key to exactly one worker while preserving the same plan hash, drift checks, locks, checkpoints, and final verification. Shard settings cannot change when a run is resumed. Keep concurrency within the GitHub token's API limits.

## Deferred rows

The automatic apply path intentionally skips:

- unknown or conflicting legacy classifications;
- `to review`, because Project Status requires selecting the correct Project item and field;
- closed-issue resolution changes, because GitHub applies `state_reason` only during a state transition;
- any other proposal marked `manual_review`.

Their old labels remain attached until we explicitly resolve and verify those rows together. The migration ledger preserves their historical meaning.

## Final reconciliation

After all approved batches:

1. Generate another read-only dry run.
2. Confirm that no automatically migratable item remains.
3. Resolve the manual-review ledger.
4. Count every obsolete label across open and closed issues and pull requests.
5. Delete an obsolete repository label definition only when its count is zero.
6. Run the nightly standards audit and retain the final evidence directory.

## Repository label catalog cleanup

After item migration reports zero remaining automatic changes, generate a separate usage-aware label catalog plan:

```powershell
./scripts/New-GitHubLabelCatalogDryRun.ps1 `
    -Organizations pylesoft `
    -OutputDirectory ./artifacts/pylesoft-label-catalog
```

This plan creates missing canonical definitions, normalizes their colors and descriptions, and proposes obsolete definitions for deletion only when they have zero issue or pull-request associations.

Apply the reviewed plan by its exact SHA-256:

```powershell
$plan = './artifacts/pylesoft-label-catalog/github-label-catalog-dry-run-YYYYMMDDTHHMMSSZ.json'
$sha256 = (Get-FileHash -Algorithm SHA256 $plan).Hash

./scripts/Invoke-GitHubLabelCatalog.ps1 `
    -PlanPath $plan `
    -PlanSha256 $sha256 `
    -Apply `
    -Organizations pylesoft `
    -BatchSize 100
```

The apply command rechecks live usage immediately before every deletion. Any new association, metadata drift, read error, or blocked action stops the batch. Use `-Resume` with the exact same plan and filters after reviewing the event ledger.
