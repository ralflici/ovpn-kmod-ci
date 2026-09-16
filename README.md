# ovpn kernel module CI

In-tree submissions are handled by the [Patchwork CI](docs/patchwork-ci.md): a
[Cloudflare Worker](listener/README.md) dispatches completed ovpn submissions,
and Actions runs NIPA checks and parallel per-patch kernel builds/selftests.

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

The default matrix uses real RHEL targets instead of AlmaLinux, plus CentOS
Stream 10 as the public early signal for upcoming Enterprise Linux kernel ABI
changes. AlmaLinux targets are still supported by the scripts and can be
enabled by overriding the `distros` input.

Void targets are included to cover maintained 6.6 and 6.18 kernel series from
a single rolling distro.

openSUSE Leap 16 is also supported by the scripts, but is not part of the
default matrix while its repository metadata is too unstable for scheduled CI.

The workflow defaults to `x86_64`. To test arm64, add a separate caller job
with `arch: arm64` and an explicit `distros` list, for example:

```yaml
    with:
      arch: arm64
      cache-prefix: ovpn-backports-arm64
      distros: '["debian-12","ubuntu-24.04"]'
      guest-script: ci/run-build.sh
      prepare-command: ./backports-ctl.sh get-ovpn -t
```

GitHub-hosted arm64 runners do not currently expose nested KVM, so arm64
guests run under QEMU emulation. Keep arm64 jobs build-only unless the caller is
prepared for much longer runtime.

## Guest scripts

The guest script path is relative to the caller repository and must be
executable. It runs as root inside the generated rootfs, with the caller
repository copied to `/repo`. The examples above use `ci/...` paths in the
caller repositories, not in this shared CI repository.

## RHEL credentials

RHEL targets require these caller repository Actions secrets:

- `RHEL_ORG_ID`
- `RHEL_ACTIVATION_KEY`
- `RHEL_10_BETA_X86_64_PRODUCT_CERT` for the `rhel-10-beta` target

The reusable workflow consumes them through `secrets: inherit`.
