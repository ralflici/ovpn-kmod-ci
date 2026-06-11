#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

require_env()
{
	if [ -z "${!1:-}" ]; then
		echo "Missing required environment variable: $1" >&2
		exit 1
	fi
}

# refs/heads/foo/123-bar -> foo/123-bar
cache_ref_name()
{
	printf '%s' "${1#refs/heads/}" | sed -e 's/[^A-Za-z0-9_.-]/-/g'
}

tracked_ref()
{
	for ref in ${CCACHE_TRACKED_REFS}; do
		if [ "$1" = "${ref}" ]; then
			return 0
		fi
	done

	return 1
}

# Keep duplicate prefixes out of the multiline actions/cache restore list.
add_restore_key()
{
	if ! grep -Fxq -- "$1" "${restore_keys}"; then
		echo "$1" >> "${restore_keys}"
	fi
}

require_env CCACHE_KEY_VERSION
require_env CCACHE_TRACKED_REFS
require_env GITHUB_OUTPUT
require_env RUNNER_OS
require_env SOURCE_REF
require_env SOURCE_SHA

# The receiver may provide the nearest tracked ancestor so a topic branch can
# restore from the base branch cache it was forked from. Only tracked base refs
# save durable caches.
compiler=$(gcc -dumpfullversion -dumpversion)
prefix_base="ovpn-kselftest-ccache-${CCACHE_KEY_VERSION}"
prefix="${prefix_base}-${RUNNER_OS}-gcc-${compiler}"
source_ref_key=$(cache_ref_name "${SOURCE_REF}")
source_ref_prefix="${prefix}-ref-${source_ref_key}"
restore_key="${source_ref_prefix}-${SOURCE_SHA}"
save_cache=false

# If the push is on one of the tracked branches we update the cache.
if tracked_ref "${SOURCE_REF}"; then
	save_cache=true
fi

if tracked_ref "${CACHE_BASE_REF:-}" && [ -n "${CACHE_BASE_SHA:-}" ]; then
	cache_base_ref_key=$(cache_ref_name "${CACHE_BASE_REF}")
	cache_base_ref_prefix="${prefix}-ref-${cache_base_ref_key}"
	restore_key="${cache_base_ref_prefix}-${CACHE_BASE_SHA}"
fi

restore_keys=$(mktemp)
trap 'rm -f "${restore_keys}"' EXIT

if [ -n "${cache_base_ref_prefix:-}" ]; then
	add_restore_key "${cache_base_ref_prefix}-"
fi
if [ "${save_cache}" = "true" ]; then
	add_restore_key "${source_ref_prefix}-"
fi

# Export the extracted info as the step output.
{
	echo "restore-key=${restore_key}"
	echo "save-key=${source_ref_prefix}-${SOURCE_SHA}"
	echo "save=${save_cache}"
	echo "restore-keys<<EOF"
	cat "${restore_keys}"
	echo "EOF"
} >> "${GITHUB_OUTPUT}"
