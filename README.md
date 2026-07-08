# ovpn kernel module CI

Shared GitHub Actions CI for booting distro rootfs images with virtme-ng and
running an out-of-tree OpenVPN kernel module payload inside the guest.

The caller repository provides the guest script. This repository provides the
rootfs generation, virtme-ng boot logic, and scheduled-run cache gate.

## Caller workflow

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

The workflow defaults to `x86_64`. To test arm64, add a separate caller job
with `arch: arm64` and an explicit `distros` list, for example:

```yaml
    with:
      arch: arm64
      cache-prefix: ovpn-backports-arm64
      distros: '["debian-12","ubuntu-24.04"]'
      guest-script: ci/guest-run-selftests.sh
      prepare-command: ./backports-ctl.sh get-ovpn -t
```

## Guest scripts

The guest script path is relative to the caller repository and must be
executable. It runs as root inside the generated rootfs, with the caller
repository copied to `/repo`. The examples above use `ci/...` paths in the
caller repositories, not in this shared CI repository.

## RHEL credentials

RHEL targets require these caller repository Actions secrets:

- `RHEL_ORG_ID`
- `RHEL_ACTIVATION_KEY`

The reusable workflow consumes them through `secrets: inherit`.
