#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

usage() {
	echo "Usage: $0 <arch> <kernel-image> <kernel-release> <output-dir>" >&2
	exit 1
}

if [ "$#" -ne 4 ]; then
	usage
fi

arch="$1"
image="$2"
kernel_release="$3"
outdir="$4"

if [ ! -f "${image}" ]; then
	echo "Missing kernel image: ${image}" >&2
	exit 1
fi

if [ "${arch}" != "arm64" ]; then
	printf '%s\n' "${image}"
	exit 0
fi

if ! command -v zstd >/dev/null 2>&1; then
	echo "arm64 kernel image preparation requires zstd" >&2
	exit 1
fi

if ! command -v aarch64-linux-gnu-objcopy >/dev/null 2>&1; then
	echo "arm64 kernel image preparation requires aarch64-linux-gnu-objcopy" >&2
	exit 1
fi

mkdir -p "${outdir}"

base=$(basename -- "${image}")
work="${outdir}/${base}.work"
section="${outdir}/${base}.linux"
payload="${outdir}/${base}.payload"
plain="${outdir}/vmlinuz-${kernel_release}"
objcopy_out="${outdir}/${base}.objcopy"

rm -f "${work}" "${section}" "${payload}" "${plain}" "${objcopy_out}"

# Older Ubuntu arm64 vmlinuz files are gzip-wrapped and already boot through
# QEMU directly. Still unwrap a temporary copy so the same zboot detection also
# works if a future distro ships gzip-wrapped EFI zboot.
if gzip -t "${image}" 2>/dev/null; then
	gzip -dc "${image}" > "${work}"
else
	cp "${image}" "${work}"
fi

# Signed Ubuntu images can be an outer PE/COFF EFI binary whose .linux section
# contains the real EFI zboot image. If .linux does not exist, objcopy fails
# and we keep inspecting the original buffer.
if aarch64-linux-gnu-objcopy --dump-section .linux="${section}" \
	"${work}" "${objcopy_out}" 2>/dev/null &&
	[ -s "${section}" ]; then
	cp "${section}" "${work}"
fi

# EFI zboot starts with:
#   bytes 0..1:   MZ
#   bytes 4..7:   zimg
#   bytes 8..11:  payload offset, little endian u32
#   bytes 12..15: payload size, little endian u32
#   bytes 24..55: compression type string
#
# If this is not zboot, keep the original image path so working non-zboot
# targets keep using the exact same input they used before this workaround.
magic=$(od -An -tx1 -j 4 -N4 "${work}" | tr -d ' \n')
if [ "${magic}" != "7a696d67" ]; then
	printf '%s\n' "${image}"
	exit 0
fi

off=$(od -An -t u4 -j 8 -N4 "${work}" | tr -d ' ')
size=$(od -An -t u4 -j 12 -N4 "${work}" | tr -d ' ')
ctype=$(
	dd if="${work}" bs=1 skip=24 count=32 2>/dev/null |
		tr -d '\000'
)

dd if="${work}" of="${payload}" bs=1 skip="${off}" count="${size}" status=none

case "${ctype}" in
zstd)
	zstd -q -f -d "${payload}" -o "${plain}"
	;;
gzip)
	gzip -dc "${payload}" > "${plain}"
	;;
*)
	echo "unsupported arm64 EFI zboot compression: ${ctype}" >&2
	exit 1
	;;
esac

printf '%s\n' "${plain}"
