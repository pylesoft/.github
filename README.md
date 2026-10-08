# Pylesoft GitHub standards

This repository is the organization-wide home for shared GitHub templates and standards.

The canonical label, issue type, and new-repository branch configuration is documented in [`standards/github-standards.json`](standards/github-standards.json). Organization Settings in Pylesoft and FloorBox are the source of truth for applying those defaults to new repositories.

The shared `pylesoft/.github/actions/setup-php@master` action enables cached PHP
builds by default on supported runners, including experimental support for
Blacksmith and Depot. Callers inherit this behavior without workflow changes.
To disable caching for a job, pass `use-builds-cache: 'false'` under `with`.
