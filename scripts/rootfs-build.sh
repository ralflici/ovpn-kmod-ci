#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=scripts/rootfs-common.sh
. "${script_dir}/rootfs-common.sh"

usage() {
	echo "Usage: $0 <target> <rootfs-dir>" >&2
	exit 1
}

if [ "$#" -ne 2 ]; then
	usage
fi

distro="$1"
rootfs="$2"
target_arch="${KMOD_CI_ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}"
rootfs_profile="${KMOD_CI_ROOTFS_PROFILE:-selftests}"
ubuntu_mirror="http://archive.ubuntu.com/ubuntu"
ubuntu_security_mirror="http://security.ubuntu.com/ubuntu"
rpm_arch="x86_64"
rhel_repo_arch="x86_64"

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
	target_arch=amd64
	rpm_arch=x86_64
	rhel_repo_arch=x86_64
	;;
aarch64|arm64)
	target_arch=arm64
	rpm_arch=aarch64
	rhel_repo_arch=aarch64
	ubuntu_mirror="http://ports.ubuntu.com/ubuntu-ports"
	ubuntu_security_mirror="${ubuntu_mirror}"
	;;
*)
	echo "Unsupported architecture: ${target_arch}" >&2
	exit 1
	;;
esac

if [ -e "${rootfs}" ]; then
	echo "Rootfs path already exists: ${rootfs}" >&2
	exit 1
fi

mkdir -p "$(dirname "${rootfs}")"

build_debian_10() {
	build_debian \
		buster \
		http://archive.debian.org/debian \
		http://archive.debian.org/debian-security \
		buster/updates
}

build_debian_11() {
	build_debian \
		bullseye \
		http://deb.debian.org/debian \
		http://security.debian.org/debian-security \
		bullseye-security
}

build_debian_12() {
	build_debian \
		bookworm \
		http://deb.debian.org/debian \
		http://security.debian.org/debian-security \
		bookworm-security
}

build_debian_13() {
	build_debian \
		trixie \
		http://deb.debian.org/debian \
		http://security.debian.org/debian-security \
		trixie-security
}

build_debian() {
	local codename="$1"
	local mirror="$2"
	local security_mirror="$3"
	local security_suite="$4"
	local debian_keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
	local include
	local mmdebstrap_options=()
	local packages=(
		bc
		binutils
		bison
		build-essential
		ca-certificates
		diffutils
		flex
		git
		iperf3
		iproute2
		iputils-ping
		jq
		kmod
		libelf-dev
		libmbedtls-dev
		libnl-3-dev
		libnl-genl-3-dev
		libssl-dev
		"linux-headers-${target_arch}"
		"linux-image-${target_arch}"
		make
		nftables
		pkg-config
		procps
		psmisc
		python3
		python3-jsonschema
		python3-yaml
		rsync
		systemd-sysv
		tcpdump
	)

	if [ "${codename}" = "buster" ]; then
		# Debian 10 is served from archive.debian.org, where old
		# Release files are intentionally expired.
		mmdebstrap_options+=('--aptopt=Acquire::Check-Valid-Until "false"')
	fi

	if [ ! -r "${debian_keyring}" ]; then
		echo "Missing Debian archive keyring: ${debian_keyring}" >&2
		echo "Install debian-archive-keyring on the host." >&2
		exit 1
	fi

	include=$(IFS=,; echo "${packages[*]}")

	# The GitHub runner is Ubuntu, so make the foreign archive trust root
	# explicit instead of depending on the host apt keyring setup.
	mmdebstrap \
		"${mmdebstrap_options[@]}" \
		--variant=minbase \
		--keyring="${debian_keyring}" \
		--include="${include}" \
		"${codename}" \
		"${rootfs}" \
		"deb ${mirror} ${codename} main" \
		"deb ${mirror} ${codename}-updates main" \
		"deb ${security_mirror} ${security_suite} main"
}

build_ubuntu_2004() {
	build_ubuntu focal python3.9
}

build_ubuntu_2204() {
	build_ubuntu jammy
}

build_ubuntu_2404() {
	build_ubuntu noble
}

build_ubuntu_2510() {
	build_ubuntu questing
}

build_ubuntu_2604() {
	build_ubuntu resolute
}

build_ubuntu() {
	local codename="$1"
	local extra_python="${2:-}"
	local include
	local ubuntu_keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
	local packages=(
		bc
		binutils
		bison
		build-essential
		busybox-static
		ca-certificates
		diffutils
		flex
		git
		iperf3
		iproute2
		iputils-ping
		jq
		kmod
		libelf-dev
		libmbedtls-dev
		libnl-3-dev
		libnl-genl-3-dev
		libssl-dev
		linux-headers-generic
		linux-image-generic
		make
		nftables
		pkg-config
		procps
		psmisc
		python3
		python3-jsonschema
		python3-yaml
		rsync
		systemd-sysv
		tcpdump
		udev
	)

	if [ -n "${extra_python}" ]; then
		packages+=("${extra_python}")
	fi

	if [ ! -r "${ubuntu_keyring}" ]; then
		echo "Missing Ubuntu archive keyring: ${ubuntu_keyring}" >&2
		echo "Install ubuntu-keyring on the host." >&2
		exit 1
	fi

	include=$(IFS=,; echo "${packages[*]}")

	# Keep the bootstrap trust root explicit so runner image apt changes do
	# not affect rootfs generation.
	mmdebstrap \
		--variant=minbase \
		--keyring="${ubuntu_keyring}" \
		--include="${include}" \
		"${codename}" \
		"${rootfs}" \
		"deb ${ubuntu_mirror} ${codename} main universe" \
		"deb ${ubuntu_mirror} ${codename}-updates main universe" \
		"deb ${ubuntu_security_mirror} ${codename}-security main universe"
}

mount_dnf_rootfs() {
	mkdir -p \
		"${rootfs}/dev" \
		"${rootfs}/proc" \
		"${rootfs}/sys" \
		"${rootfs}/run"

	# /dev is recursive because package scriptlets may need devices under
	# submounts such as /dev/pts.
	mount --rbind /dev "${rootfs}/dev"
	mount --make-rslave "${rootfs}/dev"
	# procfs and sysfs let kernel package scriptlets query the running host.
	mount -t proc proc "${rootfs}/proc"
	mount -t sysfs sysfs "${rootfs}/sys"
	# Some package scriptlets expect a writable runtime directory.
	mount -t tmpfs tmpfs "${rootfs}/run"
}

umount_dnf_rootfs() {
	umount -R "${rootfs}/run" 2>/dev/null || true
	umount -R "${rootfs}/sys" 2>/dev/null || true
	umount -R "${rootfs}/proc" 2>/dev/null || true
	umount -R "${rootfs}/dev" 2>/dev/null || true
}

build_dnf() {
	local repo_dir="$1"
	local releasever="$2"
	local allow_install_failure="$3"
	local rc clean_rc
	local dnf_options=()
	shift 3

	# RHEL builds set this because the subscription-manager dnf plugin looks
	# for RHSM identity inside the installroot and prints noisy warnings.
	# The rootfs build already uses a repo file generated by
	# subscription-manager.
	if [ "${DNF_DISABLE_SUBSCRIPTION_PLUGIN:-0}" -eq 1 ]; then
		dnf_options+=(--disableplugin=subscription-manager)
	fi

	# RPM kernel package scriptlets run inside the installroot and expect
	# procfs, sysfs, devtmpfs, and /run to exist.
	mount_dnf_rootfs

	set +e
	dnf -y \
		--installroot="${rootfs}" \
		--releasever="${releasever}" \
		--forcearch="${rpm_arch}" \
		--setopt="reposdir=${repo_dir}" \
		--setopt=install_weak_deps=False \
		--setopt=tsflags=nodocs \
		"${dnf_options[@]}" \
		install "$@"
	rc=$?
	dnf -y \
		--installroot="${rootfs}" \
		--releasever="${releasever}" \
		--forcearch="${rpm_arch}" \
		--setopt="reposdir=${repo_dir}" \
		"${dnf_options[@]}" \
		clean all
	clean_rc=$?
	set -e

	umount_dnf_rootfs

	if [ "${rc}" -ne 0 ]; then
		if [ "${allow_install_failure}" = 1 ]; then
			if [ -z "$(rootfs_find_kernel_image "${rootfs}")" ]; then
				return "${rc}"
			fi

			# Some kernel post-install scripts still fail in a
			# minimal chroot after installing the files we need.
			# The rootfs validation below decides whether the
			# result is usable.
			echo "dnf install returned ${rc}; continuing with rootfs validation" >&2
		else
			return "${rc}"
		fi
	fi

	if [ "${clean_rc}" -ne 0 ]; then
		return "${clean_rc}"
	fi
}

build_fedora_44() {
	local repo_dir="${script_dir}/../repos/fedora"
	local packages=(
		bc
		binutils
		bison
		ca-certificates
		diffutils
		elfutils-libelf-devel
		flex
		gawk
		gcc
		git
		glibc-devel
		iperf3
		iproute
		iputils
		jq
		kernel
		kernel-devel
		kernel-headers
		kmod
		libnl3-devel
		make
		mbedtls-devel
		nftables
		openssl-devel
		pkgconf-pkg-config
		procps-ng
		psmisc
		python3
		python3-jsonschema
		python3-pyyaml
		rsync
		systemd
		systemd-udev
		tcpdump
	)

	build_dnf "${repo_dir}" 44 0 "${packages[@]}"
}

build_alma() {
	local releasever="$1"
	local repo_dir="${script_dir}/../repos/alma"
	local packages=(
		bc
		binutils
		bison
		ca-certificates
		diffutils
		elfutils-libelf-devel
		findutils
		flex
		gawk
		gcc
		git
		glibc-devel
		grep
		iperf3
		iproute
		iputils
		jq
		kernel
		kernel-devel
		kernel-headers
		kmod
		libnl3-devel
		make
		mbedtls-devel
		nftables
		openssl-devel
		pkgconf-pkg-config
		procps-ng
		psmisc
		python3
		python3-jsonschema
		python3-pyyaml
		rsync
		sed
		systemd
		systemd-udev
		tcpdump
	)

	if [ "${releasever}" = 8 ]; then
		repo_dir="${script_dir}/../repos/alma8"
	fi

	build_dnf "${repo_dir}" "${releasever}" 1 "${packages[@]}"
}

require_rhel_secret() {
	local name="$1"

	if [ -z "${!name:-}" ]; then
		echo "Missing ${name}; configure it as a GitHub Actions secret." >&2
		exit 1
	fi
}

# Run the RHEL bootstrap inside Red Hat's Universal Base Image, which contains
# the RHSM tooling needed to authenticate against Red Hat CDN.
run_rhel_builder_container() {
	local releasever="$1"
	local image="registry.access.redhat.com/ubi${releasever}/ubi:latest"
	local repo_root
	local rootfs_parent

	repo_root=$(dirname "${script_dir}")
	rootfs_parent=$(dirname "${rootfs}")

	# GitHub's Ubuntu runners already provide Docker. Installing docker.io
	# via apt can conflict with the runner image's containerd.io package.
	if ! command -v docker >/dev/null 2>&1; then
		echo "RHEL rootfs generation requires docker on the runner." >&2
		exit 1
	fi

	docker run --rm --privileged \
		-e KMOD_CI_ARCH \
		-e KMOD_CI_ROOTFS_PROFILE \
		-e RHEL_ACTIVATION_KEY \
		-e RHEL_BUILDER_CONTAINER=1 \
		-e RHEL_ORG_ID \
		-v "${repo_root}:${repo_root}" \
		-v "${rootfs_parent}:${rootfs_parent}" \
		"${image}" \
		/bin/bash "${script_dir}/rootfs-build.sh" "${distro}" "${rootfs}"
}

cleanup_rhel_registration() {
	local rc=0

	umount_dnf_rootfs

	if [ "${rhel_registered:-0}" -eq 1 ]; then
		# Remove the registered system from subscription management.
		subscription-manager unregister || rc=$?
		# Remove local subscription and identity data from the builder.
		subscription-manager clean || rc=$?
	fi

	# Defensively scrub RHSM state from the generated rootfs too.
	rm -rf \
		"${rootfs}/etc/pki/entitlement" \
		"${rootfs}/etc/rhsm" \
		"${rootfs}/etc/yum.repos.d/redhat.repo" \
		"${rootfs}/var/lib/rhsm"

	return "${rc}"
}

build_rhel() {
	local releasever="$1"
	local repo_dir
	local register_output
	local packages=(
		bc
		binutils
		bison
		ca-certificates
		diffutils
		elfutils-libelf-devel
		findutils
		flex
		gawk
		gcc
		git
		glibc-devel
		grep
		iperf3
		iproute
		iputils
		jq
		kernel
		kernel-devel
		kernel-headers
		kmod
		libnl3-devel
		make
		mbedtls-devel
		nftables
		openssl-devel
		pkgconf-pkg-config
		procps-ng
		psmisc
		python3
		python3-jsonschema
		python3-pyyaml
		rsync
		sed
		systemd
		systemd-udev
		tcpdump
	)

	# Public distro targets can use repo files directly from the Ubuntu
	# runner. RHEL first needs RHSM registration, so the runner re-executes
	# this script inside UBI where subscription-manager is available.
	if [ "${RHEL_BUILDER_CONTAINER:-0}" -ne 1 ]; then
		run_rhel_builder_container "${releasever}"
		exit 0
	fi

	# Check if the key is available to subscription-manager in the
	# container.
	require_rhel_secret RHEL_ORG_ID
	require_rhel_secret RHEL_ACTIVATION_KEY

	rhel_registered=0
	# Make sure registration state is removed even if the package install
	# fails.
	trap cleanup_rhel_registration EXIT

	# Successful registration prints the RHSM consumer ID and container
	# hostname. They're not credentials but keep them out of public CI logs.
	if ! register_output=$(subscription-manager register \
		--activationkey="${RHEL_ACTIVATION_KEY}" \
		--org="${RHEL_ORG_ID}" 2>&1); then
		printf '%s\n' "${register_output}" >&2
		exit 1
	fi
	rhel_registered=1

	# Enable the RHEL repos needed for the kernel, headers, and build deps.
	subscription-manager repos \
		--enable="rhel-${releasever}-for-${rhel_repo_arch}-baseos-rpms" \
		--enable="rhel-${releasever}-for-${rhel_repo_arch}-appstream-rpms" \
		--enable="codeready-builder-for-rhel-${releasever}-${rhel_repo_arch}-rpms"

	repo_dir=$(mktemp -d)
	# redhat.repo is generated by subscription-manager; epel.repo is static.
	cp /etc/yum.repos.d/redhat.repo "${repo_dir}/redhat.repo"
	cp "${script_dir}/../repos/epel/epel.repo" "${repo_dir}/epel.repo"

	DNF_DISABLE_SUBSCRIPTION_PLUGIN=1 \
		build_dnf "${repo_dir}" "${releasever}" 1 "${packages[@]}"

	trap - EXIT
	cleanup_rhel_registration
}

build_opensuse_leap() {
	local releasever="$1"
	local repo_dir

	# leap 15 has "update-oss" repo but leap 16 doesn't so we have to use
	# different files to avoid 404
	case "${releasever}" in
	15.*)
		repo_dir="${script_dir}/../repos/opensuse-leap15"
		;;
	16.*)
		repo_dir="${script_dir}/../repos/opensuse-leap16"
		;;
	*)
		echo "Unsupported openSUSE Leap release: ${releasever}" >&2
		exit 1
		;;
	esac

	build_opensuse "${repo_dir}" "${releasever}"
}

build_opensuse_tumbleweed() {
	local repo_dir="${script_dir}/../repos/opensuse-tumbleweed"

	if [ "${rpm_arch}" = aarch64 ]; then
		repo_dir="${script_dir}/../repos/opensuse-tumbleweed-arm64"
	fi

	build_opensuse "${repo_dir}" tumbleweed
}

build_opensuse() {
	local repo_dir="$1"
	local releasever="$2"
	local packages=(
		bc
		binutils
		bison
		ca-certificates
		diffutils
		findutils
		flex
		gawk
		gcc
		git
		glibc-devel
		grep
		kernel-default
		kernel-default-devel
		kernel-devel
		kmod
		make
		openssl-devel
		sed
		systemd
		udev
	)

	if [ "${rootfs_profile}" = selftests ]; then
		packages+=(
			iperf
			iproute2
			iputils
			jq
			libnl3-devel
			mbedtls-devel
			nftables
			pkg-config
			procps
			psmisc
			python3
			python3-jsonschema
			python3-PyYAML
			rsync
			tcpdump
		)
	fi

	build_dnf "${repo_dir}" "${releasever}" 1 "${packages[@]}"

	# leap marks non-SUSE modules unsupported unless this policy knob is set
	mkdir -p "${rootfs}/etc/modprobe.d"
	echo "allow_unsupported_modules 1" \
		> "${rootfs}/etc/modprobe.d/10-unsupported-modules.conf"
}

case "${distro}" in
debian-10)
	build_debian_10
	;;
debian-11)
	build_debian_11
	;;
debian-12)
	build_debian_12
	;;
debian-13)
	build_debian_13
	;;
ubuntu-20.04)
	build_ubuntu_2004
	;;
ubuntu-22.04)
	build_ubuntu_2204
	;;
ubuntu-24.04)
	build_ubuntu_2404
	;;
ubuntu-25.10)
	build_ubuntu_2510
	;;
ubuntu-26.04)
	build_ubuntu_2604
	;;
fedora-44)
	build_fedora_44
	;;
alma-8)
	build_alma 8
	;;
alma-9)
	build_alma 9
	;;
alma-10)
	build_alma 10
	;;
rhel-8)
	build_rhel 8
	;;
rhel-9)
	build_rhel 9
	;;
rhel-10)
	build_rhel 10
	;;
opensuse-leap-15.6)
	build_opensuse_leap 15.6
	;;
opensuse-leap-16.0)
	build_opensuse_leap 16.0
	;;
opensuse-tumbleweed)
	build_opensuse_tumbleweed
	;;
*)
	echo "Unsupported target: ${distro}" >&2
	usage
	;;
esac

kernel=$(rootfs_find_kernel_image "${rootfs}")

if [ -z "${kernel}" ]; then
	echo "No kernel image found in ${rootfs}" >&2
	exit 1
fi

kernel_release=$(rootfs_kernel_release "${kernel}")

if ! rootfs_has_kernel_headers "${rootfs}" "${kernel_release}"; then
	echo "Missing headers for ${kernel_release}" >&2
	exit 1
fi

echo "Built ${distro} rootfs at ${rootfs}"
echo "Kernel: ${kernel_release}"
