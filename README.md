# Pylesoft GitHub standards

This repository is the organization-wide home for shared GitHub templates and standards.

The canonical label, issue type, and new-repository branch configuration is documented in [`standards/github-standards.json`](standards/github-standards.json). Organization Settings in Pylesoft and FloorBox are the source of truth for applying those defaults to new repositories.

The shared `pylesoft/.github/actions/setup-php@master` action enables cached PHP
builds by default on supported runners, including experimental support for
Blacksmith and Depot. Callers inherit this behavior without workflow changes.
To disable caching for a job, pass `use-builds-cache: 'false'` under `with`.

On Ubuntu 24.04 x64 and ARM runners, enabled PHP SQLite extensions use SQLite
3.46 or newer so deeply nested queries work. When the installed library is older,
the action downloads a checksum-verified Ubuntu SQLite 3.46.1 package and extracts
its library into the runner's temporary directory. The runner's `patchelf` tool
binds only the enabled PHP extensions to that library. No compilation, system
package changes or loader environment variables are required; native SQLite and
Docker actions keep their original runtime. Newer libraries, disabled SQLite
extensions and other runner versions remain unchanged.
