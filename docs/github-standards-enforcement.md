# GitHub standards enforcement

Pylesoft standards are enforced through two workflows in this repository.

## Authentication

Create a repository Actions secret named `GH_STANDARDS_TOKEN` in `pylesoft/.github`. Use an organization-owned fine-grained token or GitHub App token with:

- Read access to organization repositories and metadata.
- Read and write access to repository Issues and pull requests.
- Read and write access to repository labels.
- Read access to organization issue types and issue fields.

The existing organization secret named `GH_TOKEN` has `private` visibility. Because this `.github` repository is public, that secret is intentionally not reused or exposed here.

## Nightly audit

`GitHub standards audit` runs every day and can also be started manually. It:

1. Generates a read-only issue and pull-request migration plan.
2. Generates a read-only, usage-aware label catalog plan.
3. Uploads both plans and their ledgers as a 30-day artifact.
4. Fails when drift, manual-review work, blocked actions, or read errors exist.

A failed audit never mutates GitHub. Review its artifact before deciding whether the drift should be repaired or added as an explicit standards exception.

## Owner-approved label repair

`Apply GitHub label catalog` is manual-only. An owner must type `APPLY` exactly. The workflow regenerates a fresh plan immediately before execution and refuses to continue when the plan contains a read error or a label that still has live associations.

The optional repository input provides safe new-repository bootstrap. Leave it blank to reconcile the entire organization.

Issue and pull-request metadata migrations remain operator-run because native type and historical classification changes require review of the generated ledger. The nightly audit identifies this drift but does not apply it automatically.

## Immediate repository creation

GitHub does not run a workflow in this repository when another organization repository is created. The nightly audit detects a new repository within 24 hours, and the manual label workflow can bootstrap it immediately by repository name. Event-driven, immediate bootstrap would require an organization GitHub App that subscribes to repository creation events.
