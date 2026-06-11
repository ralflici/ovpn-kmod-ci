#!/bin/bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

max_attempts=3
retry_delay=5

usage()
{
	echo "Usage: $0 --repo <owner/repo> --sha <commit> --state <state> --context <context> --description <text> --target-url <url>" >&2
	exit 2
}

token_hash()
{
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "${GITHUB_STATUS_TOKEN}" | sha256sum | cut -c1-12
	else
		printf '%s' "${GITHUB_STATUS_TOKEN}" | shasum -a 256 | cut -c1-12
	fi
}

repo=""
sha=""
state=""
context=""
description=""
target_url=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--repo)
		[ "$#" -ge 2 ] || usage
		repo="$2"
		shift 2
		;;
	--sha)
		[ "$#" -ge 2 ] || usage
		sha="$2"
		shift 2
		;;
	--state)
		[ "$#" -ge 2 ] || usage
		state="$2"
		shift 2
		;;
	--context)
		[ "$#" -ge 2 ] || usage
		context="$2"
		shift 2
		;;
	--description)
		[ "$#" -ge 2 ] || usage
		description="$2"
		shift 2
		;;
	--target-url)
		[ "$#" -ge 2 ] || usage
		target_url="$2"
		shift 2
		;;
	*)
		usage
		;;
	esac
done

[ -n "${repo}" ] || usage
[ -n "${sha}" ] || usage
[ -n "${state}" ] || usage
[ -n "${context}" ] || usage
[ -n "${description}" ] || usage
[ -n "${target_url}" ] || usage

if [ -z "${GITHUB_STATUS_TOKEN:-}" ]; then
	echo "GITHUB_STATUS_TOKEN is not set; skipping source commit status"
	exit 0
fi

echo "posting GitHub status: repo=${repo} sha=${sha} state=${state} context=${context} token_len=${#GITHUB_STATUS_TOKEN} token_sha256_12=$(token_hash)"

request="$(
	jq -c -n \
		--arg state "${state}" \
		--arg context "${context}" \
		--arg description "${description}" \
		--arg target_url "${target_url}" \
		'{
			state: $state,
			context: $context,
			description: $description,
			target_url: $target_url
		}'
)"

body=$(mktemp)
trap 'rm -f "${body}"' EXIT

# Sometimes POSTing the status fails without a clear reason so retry a few
# times.
for attempt in $(seq 1 "${max_attempts}"); do
	if curl --fail-with-body --silent --show-error \
			--output "${body}" \
			-X POST "https://api.github.com/repos/${repo}/statuses/${sha}" \
			-H "Accept: application/vnd.github+json" \
			-H "Authorization: Bearer ${GITHUB_STATUS_TOKEN}" \
			-H "Content-Type: application/json" \
			-H "User-Agent: ovpn-kmod-ci" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			-d "${request}"; then
		echo "GitHub status posted"
		exit 0
	fi

	if [ -s "${body}" ]; then
		cat "${body}" >&2
	fi

	if [ "${attempt}" -eq "${max_attempts}" ]; then
		exit 1
	fi

	echo "retrying GitHub status post in ${retry_delay}s (${attempt}/${max_attempts})"
	sleep "${retry_delay}"
done
