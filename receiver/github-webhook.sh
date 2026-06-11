#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

# Files and directories containing ovpn-related changes. Use this to determine
# if a commit should dispatch a workflow.
path_filters_json='[
	"drivers/net/ovpn/",
	"Documentation/netlink/specs/ovpn.yaml",
	"include/uapi/linux/ovpn.h",
	"tools/testing/selftests/net/ovpn/"
]'

require_env()
{
	local name="$1"

	if [ -z "${!name:-}" ]; then
		echo "${name} must be set" >&2
		exit 1
	fi
}

dispatch_commit()
{
	local commit_json="$1"
	local commit_distinct commit_message commit_sha commit_url

	commit_distinct="$(jq -r '.distinct' <<< "${commit_json}")"
	commit_message="$(jq -r '.message | split("\n")[0] // ""' <<< "${commit_json}")"
	commit_sha="$(jq -r '.id' <<< "${commit_json}")"
	commit_url="$(jq -r '.url' <<< "${commit_json}")"

	# Use the same explicit interface as manual dispatches, with webhook
	# metadata filled in from the push payload.
	receiver/dispatch-commit.sh \
		--repo "${source_repo}" \
		--ref "${payload_ref}" \
		--sha "${commit_sha}" \
		--message "${commit_message}" \
		--commit-url "${commit_url}" \
		--delivery "${GITHUB_DELIVERY:-}" \
		--pusher "${push_pusher}" \
		--before "${push_before}" \
		--after "${push_after}" \
		--compare-url "${push_compare_url}" \
		--forced "${push_forced}" \
		--distinct "${commit_distinct}" \
		--clone-url "${source_clone_url}" \
		--repo-url "${source_repo_url}"
}

require_env GITHUB_PAYLOAD
require_env GITHUB_EVENT

case "${GITHUB_EVENT}" in
ping)
	echo "Received GitHub ping delivery ${GITHUB_DELIVERY:-unknown}"
	exit 0
	;;
push)
	;;
*)
	echo "Ignoring GitHub ${GITHUB_EVENT} delivery ${GITHUB_DELIVERY:-unknown}"
	exit 0
	;;
esac

jq -e . "${GITHUB_PAYLOAD}" >/dev/null

# Extract the relevant info from the incoming payload.
payload_ref="$(jq -r '.ref' "${GITHUB_PAYLOAD}")"
source_clone_url="$(jq -r '.repository.clone_url' "${GITHUB_PAYLOAD}")"
source_repo="$(jq -r '.repository.full_name' "${GITHUB_PAYLOAD}")"
source_repo_url="$(jq -r '.repository.html_url' "${GITHUB_PAYLOAD}")"
push_after="$(jq -r '.after' "${GITHUB_PAYLOAD}")"
push_before="$(jq -r '.before' "${GITHUB_PAYLOAD}")"
push_compare_url="$(jq -r '.compare' "${GITHUB_PAYLOAD}")"
push_forced="$(jq -r '.forced' "${GITHUB_PAYLOAD}")"
push_pusher="$(jq -r '.pusher.name' "${GITHUB_PAYLOAD}")"

if [ "$(jq -r '.deleted' "${GITHUB_PAYLOAD}")" = "true" ]; then
	echo "Ignoring deletion of ${payload_ref}"
	exit 0
fi

# The "push" event payload contains a commits array with optional "added",
# "modified" and "removed" fields. Build an array containing the commits whose
# fields list ovpn files (defined in path_filters_json).
# TODO: Stream matching commits directly instead of storing JSON objects in a
# bash array if this grows more complex.
mapfile -t matching_commits < <(
	jq -c --argjson filters "${path_filters_json}" '
		def path_matches_filter($path; $filter):
			if ($filter | endswith("/")) then
				($path | startswith($filter))
			else
				$path == $filter
			end;
		def commit_matches_filters:
			((.added // []) + (.modified // []) + (.removed // []))
			| [.[] as $path | $filters[] as $filter | path_matches_filter($path; $filter)]
			| any;
		.commits[] | select(commit_matches_filters)
	' "${GITHUB_PAYLOAD}"
)

if [ "${#matching_commits[@]}" -eq 0 ]; then
	echo "No commits matched path filters for ${payload_ref}"
	exit 0
fi

# Ask the dispatcher to emit the workflow event(s) for each matching commit.
for commit_json in "${matching_commits[@]}"; do
	dispatch_commit "${commit_json}"
done
