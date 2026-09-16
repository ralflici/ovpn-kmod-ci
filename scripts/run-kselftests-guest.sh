#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
set -euo pipefail

echo "Guest kernel: $(uname -r)"
make headers
export OVPN_VERBOSE=1
export kselftest_override_timeout=300
log=$(mktemp)
trap 'rm -f "$log"' EXIT

set +e
make -C tools/testing/selftests TARGETS=net/ovpn FORCE_TARGETS=1 run_tests 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
set -e

# Some make/kselftest combinations do not propagate TAP failures.
if [ "$rc" -ne 0 ] || grep -Eq '^[[:space:]]*(# )?not ok[[:space:]][0-9]+' "$log"; then
    exit 1
fi
if ! grep -E '^[[:space:]]*ok[[:space:]][0-9]+' "$log" | grep -Eiv '#[[:space:]]*SKIP' >/dev/null; then
    echo "No passing TAP results found" >&2
    exit 1
fi
echo OVPN_CI_SELFTESTS_PASSED
