#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=scripts/rootfs-common.sh
. "${script_dir}/rootfs-common.sh"

usage() {
	echo "Usage: $0 <target> <rootfs-dir> <repo-sha>" >&2
	exit 1
}

if [ "$#" -ne 3 ]; then
	usage
fi

target="$1"
rootfs="$2"
repo_sha="$3"
target_arch="${KMOD_CI_ARCH:-$(uname -m)}"
rootfs_profile="${KMOD_CI_ROOTFS_PROFILE:-selftests}"

case "${rootfs_profile}" in
selftests|build)
	;;
*)
	echo "Unsupported rootfs profile: ${rootfs_profile}" >&2
	exit 1
	;;
esac

case "${target_arch}" in
x86_64|amd64)
	target_arch=x86_64
	;;
aarch64|arm64)
	target_arch=arm64
	;;
*)
	echo "Unsupported architecture: ${target_arch}" >&2
	exit 1
	;;
esac

kernel=$(rootfs_find_kernel_image "${rootfs}")
if [ -z "${kernel}" ]; then
	echo "No kernel image found in ${rootfs}" >&2
	exit 1
fi

kernel_release=$(rootfs_kernel_release "${kernel}")

# The fingerprint accounts for the target name, ovpn-backports HEAD commit,
# the rootfs package profile, and the kernel release selected from the target
# rootfs.
fingerprint_metadata=$(cat <<-EOF
target=${target}
arch=${target_arch}
profile=${rootfs_profile}
repo=${repo_sha}
kernel=${kernel_release}
EOF
)

# Print the human readable metadata into the logs.
printf '%s\n' "${fingerprint_metadata}" >&2
# Let the workflow capture the hash.
printf '%s\n' "${fingerprint_metadata}" | sha256sum | awk '{ print $1 }'
