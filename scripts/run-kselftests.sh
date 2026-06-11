#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

usage() {
	echo "Usage: $0 <kernel-source-dir>" >&2
	exit 1
}

if [ "$#" -ne 1 ]; then
	usage
fi

source_dir=$(realpath "$1")
vng_cmd="${VNG:-vng}"
config="tools/testing/selftests/net/ovpn/config"
guest_script="${source_dir}/.ovpn-ci-run-selftests.sh"

if [ ! -f "${source_dir}/${config}" ]; then
	echo "Missing selftest config: ${source_dir}/${config}" >&2
	exit 1
fi

if [ ! -x "${vng_cmd}" ] && ! command -v "${vng_cmd}" >/dev/null 2>&1; then
	echo "Missing vng command: ${vng_cmd}" >&2
	exit 1
fi

if ! command -v ccache >/dev/null 2>&1; then
	echo "Missing ccache command" >&2
	exit 1
fi

printf -v ovpn_verbose '%q' "${OVPN_VERBOSE:-1}"
printf -v ksft_timeout '%q' "${KSFT_TIMEOUT:-300}"

trap 'rm -f "${guest_script}"' EXIT

cat > "${guest_script}" <<EOF
#!/bin/bash

set -euo pipefail

cd "\$(dirname "\$0")"

selftests_log=\$(mktemp)
trap 'rm -f "\${selftests_log}"' EXIT

echo "Guest kernel:"
uname -a

echo "Preparing generated UAPI headers"
make headers

export OVPN_VERBOSE=${ovpn_verbose}
export kselftest_override_timeout=${ksft_timeout}

echo "Running kselftests"
set +e
make -C tools/testing/selftests \
	TARGETS=net/ovpn \
	FORCE_TARGETS=1 \
	run_tests 2>&1 | tee "\${selftests_log}"
rc=\${PIPESTATUS[0]}
set -e

# Some kselftest paths do not reliably bubble failures up through make.
if grep -E '^(# )?not ok[[:space:]][0-9]+' "\${selftests_log}"; then
	echo "Detected failing kselftest result" >&2
	exit 1
fi

exit "\${rc}"
EOF
chmod +x "${guest_script}"

cd "${source_dir}"

build_args=(
	--build
	--config "${config}"
	--configitem CONFIG_IPV6=y
	--configitem CONFIG_VETH=m
	"CC=${KERNEL_CC:-ccache gcc}"
)

if [ -n "${CCACHE_DIR:-}" ]; then
	mkdir -p "${CCACHE_DIR}"
fi
ccache -M "${CCACHE_MAXSIZE:-1G}"
ccache -z
echo "ccache before build:"
ccache -s

echo "Building selftest kernel"
"${vng_cmd}" "${build_args[@]}"

echo "ccache after build:"
ccache -s

vng_args=(
	--run .
	--user root
	--cwd "${source_dir}"
	--cpus "${VNG_CPUS:-4}"
	--memory "${VNG_MEMORY:-4096M}"
)

if [ -e /dev/kvm ]; then
	echo "Using KVM acceleration"
else
	echo "KVM unavailable, falling back to slow QEMU emulation"
	vng_args+=(--disable-kvm)
fi

if [ "${VNG_VERBOSE:-1}" = "1" ]; then
	vng_args+=(--verbose)
fi

vng_run_cmd=("${vng_cmd}")
if [ "${VNG_RUN_AS_ROOT:-1}" = "1" ] && [ "$(id -u)" -ne 0 ]; then
	# Use sudo only for the VM run. The kernel build itself should stay
	# owned by the checkout user to avoid Git safe-directory surprises.
	vng_run_cmd=(sudo "${vng_cmd}")
fi

echo "Booting selftest kernel"
"${vng_run_cmd[@]}" "${vng_args[@]}" --exec "./$(basename "${guest_script}")"
