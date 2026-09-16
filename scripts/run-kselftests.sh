#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <kernel-source-dir> <results-dir>" >&2
    exit 2
fi

source_dir=$(realpath "$1")
results_dir=$(realpath -m "$2")
guest_script=$(realpath "$(dirname "$0")/run-kselftests-guest.sh")
mkdir -p "$results_dir"
cd "$source_dir"

git log -1 --format=fuller | tee "$results_dir/commit.txt"
git rev-parse 'HEAD^{tree}' | tee "$results_dir/tree.txt"

vng --build --verbose --config tools/testing/selftests/net/ovpn/config \
    --configitem CONFIG_IPV6=y --configitem CONFIG_VETH=m \
    2>&1 | tee "$results_dir/build.log"
cp .config "$results_dir/kernel.config"

args=(--run . --user root --cwd "$source_dir" --rw
      --cpus "${VNG_CPUS:-4}" --memory "${VNG_MEMORY:-4096M}" --verbose)
if [ ! -e /dev/kvm ]; then
    args+=(--disable-kvm)
fi

# The guest has the host filesystem available; keep the trusted test launcher
# outside the patch-controlled source tree. Logs survive VM/build failures.
printf -v guest_command 'bash %q' "$guest_script"
sudo env "PATH=$PATH" "$(command -v vng)" "${args[@]}" --exec "$guest_command" \
    2>&1 | tee "$results_dir/selftests.log"

# Require a completion marker as well as the VM exit status.
grep -qx 'OVPN_CI_SELFTESTS_PASSED' "$results_dir/selftests.log"
