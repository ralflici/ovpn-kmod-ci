# In-tree ovpn CI

The listener submits Patchwork identities. One Actions workflow prepares the
submission, runs NIPA, and starts an independent build/selftest job for every
patch. Patch N is tested on the base plus patches 1 through N. Build jobs use
`fail-fast: false`; failures do not cancel other patches or NIPA checks.

The out-of-tree distro matrix remains a separate workflow.

## Preparation

`scripts/patchwork_ci.py prepare` downloads the original emails and cover letter,
sorts patches by their posted X/N numbering, and writes `submission/manifest.json`
plus a directory of emails. The manifest records Patchwork IDs, source URL,
logical target, base SHA, and pinned NIPA revision.

Base selection:

1. Use `base-commit:` from the cover letter or patch body when present.
2. Otherwise, use `OpenVPN/ovpn-net-next:net` for an explicit `net` subject-prefix
   token, and `OpenVPN/ovpn-net-next:main` for `net-next` or an unspecified target.
3. Resolve the selected branch once, before starting the test jobs.

Conflicting targets, malformed/conflicting bases, incomplete series and ambiguous
patch ordering fail preparation. An unavailable declared base fails checkout.
There is no automatic target inference from Fixes tags, dependency resolution,
or fallback to another tree after an application failure. RFCs are tested too.

Each job fetches the base with commit history for Fixes validation and blob
filtering, then checks out a private working tree. No temporary remote branches
or kernel build caches are used. Matrix jobs apply their prefix of the series;
the NIPA runner manages application itself from the same base.

## NIPA checks

NIPA is pinned in `scripts/patchwork_ci.py`. Its `ingest_mdir.py` entry point runs
the selected patch checks at every cumulative revision and series checks once
on the complete series. Standalone patches use only patch checks.

Patch checks: `check_selftest`, `checkpatch`, `deprecated_api`, `header_inline`,
`kdoc`, `pylint`, `ruff`, `shellcheck`, `source_inline`, `verify_fixes`,
`verify_signedoff`, `yamllint`.

Series checks: `series_format`, `fixes_present`, `maintainers`, `ynl`.

The allowlist is explicit. NIPA's additional kernel-build configurations and
checks requiring other services are not enabled. The separate virtme-ng jobs
build an ovpn-selftest kernel at every patch instead.

NIPA's CLI exit status does not summarize check failures. The wrapper reads every
expected result: 0 is success, 250 is warning, other values or missing results are
failure. Its JSON results map NIPA's local sequential patch numbers back to
Patchwork IDs and are suitable for a future reporting job. Warnings remain
visible without failing the job. Original NIPA logs/results are uploaded too.

## Build and runtime tests

Each matrix entry builds an x86_64 kernel with
`tools/testing/selftests/net/ovpn/config`, boots it with virtme-ng, and runs the
ovpn kselftests. Build logs, kernel config, commit/tree identity, and guest output
are uploaded per patch. A missing completion marker, failing TAP result, or
absence of any non-skipped passing TAP test fails the job.

The initial workflow uses Ubuntu 24.04 and virtme-ng 1.41, matching NIPA's
`docker/selftests/Dockerfile`. There is no cache or
architecture/distro matrix for in-tree submissions. Runtime jobs are independent
and run in parallel up to the repository's available runner concurrency.

Build/check jobs have read-only GitHub permissions, no persisted checkout
credentials, and no Patchwork or listener token. Patches execute on disposable
GitHub-hosted runners. Results are currently in Actions only; neither the Worker
nor the workflow posts to Patchwork or sends email.

## Development and manual runs

Run local validation from the repository root:

```sh
python3 -m unittest discover -s tests -v
shellcheck scripts/run-kselftests.sh scripts/run-kselftests-guest.sh
actionlint .github/workflows/patchwork.yml .github/workflows/validate-patchwork.yml
cd listener
npm ci
npm test
npx wrangler deploy --dry-run
```

Read-only preparation against the reference series (choose a new output path):

```sh
python3 scripts/patchwork_ci.py prepare \
  --kind series --id 4064 --event-id 23472 --output /tmp/ovpn-submission
```

For a local kernel checkout at patch 3:

```sh
python3 scripts/patchwork_ci.py checkout \
  --submission /tmp/ovpn-submission --source /tmp/ovpn-kernel --through 3
```

The checkout destination must be new. To run NIPA, make a separate base checkout
without `--through`, clone NIPA at the revision in the manifest, install the
workflow's check dependencies, then run:

```sh
python3 scripts/patchwork_ci.py nipa --submission /tmp/ovpn-submission \
  --source /tmp/ovpn-kernel-base --nipa /path/to/nipa --results /tmp/ovpn-nipa-results
```

Once the workflow is on the GitHub default branch, its **Run workflow** form
accepts `kind` (`series` or `patch`) and a Patchwork object ID. This is also how
to rerun an old submission. A new run resolves branch fallbacks again; rerunning
only failed jobs uses the prepared artifact from the original run.

See [listener setup](../listener/README.md) for Cloudflare deployment. Deploy the
listener only after the receiving workflow exists on GitHub's default branch.
