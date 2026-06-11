# ovpn kernel module CI

Shared GitHub Actions CI for OpenVPN kernel module testing.

This repository provides three CI paths:

- a reusable virtme-ng distro matrix for out-of-tree modules
- a webhook-driven patch-check workflow for in-tree `ovpn-net-next` development
- a webhook-driven virtme-ng selftest workflow for in-tree `ovpn-net-next`
  development

## Out-of-tree modules

The reusable matrix boots distro rootfs images with virtme-ng and runs a caller
repository payload inside the guest.

The caller repository provides the guest script. This repository provides the
rootfs generation, virtme-ng boot logic, and scheduled-run cache gate.

### Caller workflow

Example for `ovpn-backports`:

```yaml
---
name: virtme-ng selftests

"on":
  workflow_dispatch:
  schedule:
    - cron: "17 7 * * *"

permissions:
  contents: read

jobs:
  vng-selftests:
    uses: OpenVPN/ovpn-kmod-ci/.github/workflows/out-of-tree-vng.yml@main
    with:
      cache-prefix: ovpn-backports
      guest-script: ci/guest-run-selftests.sh
      prepare-command: ./backports-ctl.sh get-ovpn -t
    secrets: inherit
```

Example for `ovpn-dco`:

```yaml
---
name: virtme-ng build

"on":
  workflow_dispatch:
  schedule:
    - cron: "17 7 * * *"

permissions:
  contents: read

jobs:
  vng-build:
    uses: OpenVPN/ovpn-kmod-ci/.github/workflows/out-of-tree-vng.yml@main
    with:
      cache-prefix: ovpn-dco
      guest-script: ci/guest-run-build.sh
    secrets: inherit
```

The default matrix uses real RHEL targets instead of AlmaLinux. AlmaLinux
targets are still supported by the scripts and can be enabled by overriding the
`distros` input.

### Guest scripts

The guest script path is relative to the caller repository and must be
executable. It runs as root inside the generated rootfs, with the caller
repository copied to `/repo`. The examples above use `ci/...` paths in the
caller repositories, not in this shared CI repository.

### RHEL credentials

RHEL targets require these caller repository Actions secrets:

- `RHEL_ORG_ID`
- `RHEL_ACTIVATION_KEY`

The reusable workflow consumes them through `secrets: inherit`.

## In-tree kernel development

The webhook paths run checks on selected `ovpn-net-next` commits without storing
workflows in that source tree.

`receiver/` contains the webhook entry point. It validates GitHub push webhook
signatures, filters commits by ovpn-related paths, computes the nearest tracked
cache base, and emits `repository_dispatch` events for each relevant commit.

### Patch checks

The receiver emits one `ovpn-patch-check` event per relevant commit. The event
is consumed by `.github/workflows/in-tree-patch-checks.yml`, which checks out
the source commit, runs selected NIPA patch tests, and optionally posts the
`ovpn-ci/patch-checks` status back to the source repository when
`OVPN_NET_NEXT_STATUS_TOKEN` is configured.

### Selftests

The receiver also emits one `ovpn-selftest` event per relevant commit. The event
is consumed by `.github/workflows/in-tree-selftests.yml`, which builds the source
kernel with `tools/testing/selftests/net/ovpn/config`, boots it with virtme-ng,
runs the `net/ovpn` kselftests, and optionally posts the `ovpn-ci/selftests`
status back to the source repository when `OVPN_NET_NEXT_STATUS_TOKEN` is
configured.
