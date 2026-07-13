# GitHub label standards audit

Organization Settings are the source of truth for new repositories in both Pylesoft and FloorBox. Configure the four default repository labels there:

- `bug`
- `enhancement`
- `documentation`
- `docs-needed`

The same organization settings page defines `master` as the branch name for new repositories. Native issue types are managed under the organization's Planning settings.

## Authentication

Create a repository Actions secret named `GH_STANDARDS_TOKEN` in `pylesoft/.github`. Use an organization-owned fine-grained token or GitHub App token with read access to repositories, issues, pull requests, and labels in both organizations.

## Nightly audit

`GitHub label standards audit` runs every day and can also be started manually. It:

1. Verifies the four canonical labels and their metadata in every non-archived repository.
2. Reports missing, modified, or nonstandard labels as drift.
3. Reports live legacy resolution labels separately without failing the audit.
4. Uploads a 30-day evidence artifact and fails only for drift or read errors.

A failed audit never mutates GitHub. Organization defaults provision new repositories; the audit only detects later manual drift.
