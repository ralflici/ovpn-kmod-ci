#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0

set -euo pipefail

default_dispatch_event_types="ovpn-patch-check ovpn-selftest"

dispatch_event_types=()
cache_base_refs=(
	refs/heads/main
	refs/heads/development
	refs/heads/net
	refs/heads/development-net
)

# Most helpers below operate on the dispatcher state populated from CLI
# arguments near the end of the script.
require_env()
{
	local name="$1"

	if [ -z "${!name:-}" ]; then
		echo "${name} must be set" >&2
		exit 1
	fi
}

usage()
{
	echo "usage: $0 --repo <owner/repo> --ref <git-ref> --sha <commit> [--event <type> ...]" >&2
	exit 2
}

git_remote_ref()
{
	local git_ref="$1"

	case "${git_ref}" in
	refs/heads/*)
		printf 'refs/remotes/origin/%s\n' "${git_ref#refs/heads/}"
		;;
	*)
		return 1
		;;
	esac
}

run_git()
{
	git -C "${GIT_MIRROR_DIR}" "$@"
}

validate_git_mirror()
{
	if [ ! -d "${GIT_MIRROR_DIR}" ]; then
		echo "GIT_MIRROR_DIR must point to an existing bare repo" >&2
		exit 1
	fi

	if [ "$(run_git rev-parse --is-bare-repository 2>/dev/null)" != "true" ]; then
		echo "GIT_MIRROR_DIR must point to a bare git repo" >&2
		exit 1
	fi

	if ! run_git remote get-url origin >/dev/null 2>&1; then
		echo "GIT_MIRROR_DIR must have an origin remote" >&2
		exit 1
	fi
}

git_commit_exists()
{
	local commit_sha="$1"

	# Does commit_sha exist as a commit object?
	run_git cat-file -e "${commit_sha}^{commit}" >/dev/null 2>&1
}

fetch_git_ref()
{
	local git_ref="$1"
	local remote_ref

	if ! remote_ref="$(git_remote_ref "${git_ref}")"; then
		return 1
	fi

	# Avoid downloading file contents; cache-base detection only needs
	# history.
	if ! run_git fetch --quiet --filter=blob:none origin "+${git_ref}:${remote_ref}"; then
		echo "Failed to fetch ${git_ref} for cache-base detection" >&2
		return 1
	fi
}

fetch_git_commit()
{
	local commit_sha="$1"

	if git_commit_exists "${commit_sha}"; then
		return
	fi

	if ! run_git fetch --quiet --filter=blob:none origin "${commit_sha}"; then
		echo "Failed to fetch ${commit_sha} for cache-base detection" >&2
	fi
}

normalize_commit_sha()
{
	local resolved_sha

	if ! resolved_sha="$(run_git rev-parse --verify "${commit_sha}^{commit}" 2>/dev/null)"; then
		echo "Failed to resolve ${commit_sha} as a commit" >&2
		exit 1
	fi

	commit_sha="${resolved_sha}"
}

fill_commit_message()
{
	if [ -n "${commit_message}" ]; then
		return
	fi

	if ! commit_message="$(run_git log -1 --format=%s "${commit_sha}" 2>/dev/null)"; then
		commit_message="manual dispatch"
	fi
}

# Read the pushed commit message and extract the hash from the "Fixes:" tag.
commit_fixes_targets()
{
	# Match lines like:
	# Fixes: abc123...
	# Fixes: commit abc123...
	# fixes: ABC123...
	# Capture only the hash part, lowercase it and remove duplicates.
	run_git log -1 --format=%B "${commit_sha}" |
		sed -nE 's/^[[:space:]]*[Ff]ixes:[[:space:]]*([Cc]ommit[[:space:]]+)?([0-9a-fA-F]{5,40}).*/\2/p' |
		tr '[:upper:]' '[:lower:]' |
		awk '!seen[$0]++'
}

resolve_fixes_target()
{
	local target="$1"

	# If it's already 40-char long, let the workflow fetch validate it.
	if [ "${#target}" -eq 40 ]; then
		printf '%s\n' "${target}"
		return
	fi

	# Otherwise use the local mirror to expand abbreviated Fixes tags.
	if git_commit_exists "${target}"; then
		run_git rev-parse --verify "${target}^{commit}"
		return
	fi

	echo "Failed to resolve Fixes target ${target}" >&2
	exit 1
}

resolve_fixes_targets()
{
	local resolved target
	local targets=()

	while read -r target; do
		resolved="$(resolve_fixes_target "${target}")"
		targets+=("${resolved}")
	done < <(commit_fixes_targets)

	if [ "${#targets[@]}" -eq 0 ]; then
		fixes_targets_json="[]"
		return
	fi

	# Store the resolved full SHAs as a JSON array for repository_dispatch.
	fixes_targets_json="$(printf '%s\n' "${targets[@]}" | jq -R -s -c 'split("\n")[:-1]')"
}

select_cache_base()
{
	local commit_sha="$1"
	local payload_ref="$2"
	local best_distance=""
	local best_ref=""
	local best_sha=""
	local git_ref remote_ref base_sha distance

	if ! git_commit_exists "${commit_sha}"; then
		return
	fi

	# Search the nearest branch from cache_base_refs to the pushed commit.
	for git_ref in "${cache_base_refs[@]}"; do
		# Retrieve the cache-producing branch tip.
		if ! remote_ref="$(git_remote_ref "${git_ref}")"; then
			continue
		fi
		if ! git_commit_exists "${remote_ref}"; then
			continue
		fi
		# Find the common ancestor between the pushed commit and this
		# cache-producing branch.
		if ! base_sha="$(run_git merge-base "${commit_sha}" "${remote_ref}")"; then
			continue
		fi
		# Count how many commits separate the pushed commit from this
		# ancestor.
		if ! distance="$(run_git rev-list --count "${base_sha}..${commit_sha}")"; then
			continue
		fi

		# If two cache-producing branches are equally near, prefer the
		# branch that received the push. This only matters when the
		# pushed ref is itself one of cache_base_refs; topic branches
		# usually do not hit this tie-breaker.
		if [ -z "${best_distance}" ] ||
			[ "${distance}" -lt "${best_distance}" ] ||
			{ [ "${distance}" -eq "${best_distance}" ] && [ "${git_ref}" = "${payload_ref}" ]; }; then
			best_distance="${distance}"
			best_ref="${git_ref}"
			best_sha="${base_sha}"
		fi
	done

	# Output the ancestor as a JSON object.
	if [ -n "${best_ref}" ]; then
		jq -c -n \
			--arg ref "${best_ref}" \
			--arg sha "${best_sha}" \
			--argjson distance "${best_distance}" \
			'{distance: $distance, ref: $ref, sha: $sha}'
	fi
}

compute_cache_base()
{
	local computed_cache_base_json

	# Fetches mutate the local mirror and webhook/manual dispatches may run
	# concurrently.
	exec 9>"${GIT_MIRROR_DIR}/ovpn-kmod-ci.lock"
	flock 9

	validate_git_mirror

	# Fetch the pushed branch tip into the local mirror as
	# refs/remotes/origin/...
	fetch_git_ref "${source_ref}" || true
	# Resolve abbreviated manual input before publishing the payload.
	fetch_git_commit "${commit_sha}"
	normalize_commit_sha
	# Fetch the branches on which caches are generated/maintained.
	for git_ref in "${cache_base_refs[@]}"; do
		fetch_git_ref "${git_ref}" || true
	done

	# Compute the ancestor of the pushed commit.
	computed_cache_base_json="$(select_cache_base "${commit_sha}" "${source_ref}" || true)"

	flock -u 9

	cache_base_json="${computed_cache_base_json}"
}

build_client_payload()
{
	local commit_short_sha="${commit_sha:0:12}"

	jq -c -n \
		--arg delivery "${delivery}" \
		--arg source_clone_url "${clone_url}" \
		--arg source_ref "${source_ref}" \
		--arg source_repo "${source_repo}" \
		--arg source_repo_url "${repo_url}" \
		--arg push_after "${push_after}" \
		--arg push_before "${push_before}" \
		--arg push_compare_url "${compare_url}" \
		--argjson push_forced "${push_forced}" \
		--arg push_pusher "${pusher}" \
		--argjson commit_distinct "${commit_distinct}" \
		--arg commit_message "${commit_message}" \
		--arg commit_short_sha "${commit_short_sha}" \
		--arg commit_sha "${commit_sha}" \
		--arg commit_url "${commit_url}" \
		--argjson fixes_targets "${fixes_targets_json}" \
		'
		{
			delivery: $delivery,
			source: {
				clone_url: $source_clone_url,
				git_ref: $source_ref,
				repo: $source_repo,
				repo_url: $source_repo_url
			},
			push: {
				after: $push_after,
				before: $push_before,
				compare_url: $push_compare_url,
				forced: $push_forced,
				pusher: $push_pusher
			},
			commit: {
				distinct: $commit_distinct,
				message: $commit_message,
				short_sha: $commit_short_sha,
				sha: $commit_sha,
				url: $commit_url,
				fixes_targets: $fixes_targets
			}
		}
		'
}

dispatch_event()
{
	local event_type="$1"
	local client_payload="$2"
	local cache_base_json="$3"
	local request

	# The request contains the event type to dispatch and the client
	# payload describing the commit to test, plus the cache base when one
	# was found.
	request="$(
		jq -n \
			--arg event_type "${event_type}" \
			--argjson client_payload "${client_payload}" \
			--argjson cache_base "${cache_base_json:-null}" \
			'
			{
				event_type: $event_type,
				client_payload: $client_payload
			}
			| if $cache_base == null then . else .client_payload.cache_base = $cache_base end
			'
	)"

	if [ "${DISPATCH_DRY_RUN:-0}" = "1" ]; then
		echo "Would dispatch ${event_type} for ${commit_sha}"
		return
	fi

	# Send repository_dispatch to the CI repository.
	curl --fail-with-body -sS \
		-X POST "https://api.github.com/repos/${DISPATCH_REPOSITORY}/dispatches" \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: Bearer ${GITHUB_TOKEN}" \
		-H "Content-Type: application/json" \
		-H "User-Agent: ovpn-kmod-ci-receiver" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		-d "${request}" \
		-o /dev/null

	echo "Dispatched ${event_type} for ${commit_sha}"
}

# Manual usage:
#   receiver/dispatch-commit.sh --repo ralflici/ovpn-net-next \
#     --ref refs/heads/main --sha <commit> --event ovpn-selftest
#
# If no --event is provided, the normal webhook events are dispatched.
source_repo=""
source_ref=""
commit_sha=""
clone_url=""
repo_url=""
commit_url=""
commit_message=""
delivery="manual"
pusher="manual"
push_after=""
push_before=""
compare_url=""
push_forced="false"
commit_distinct="true"
cache_base_json=""
fixes_targets_json="[]"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--repo)
		[ "$#" -ge 2 ] || usage
		source_repo="$2"
		shift 2
		;;
	--ref)
		[ "$#" -ge 2 ] || usage
		source_ref="$2"
		shift 2
		;;
	--sha)
		[ "$#" -ge 2 ] || usage
		commit_sha="$2"
		shift 2
		;;
	--event)
		[ "$#" -ge 2 ] || usage
		dispatch_event_types+=("$2")
		shift 2
		;;
	--message)
		[ "$#" -ge 2 ] || usage
		commit_message="$2"
		shift 2
		;;
	--commit-url)
		[ "$#" -ge 2 ] || usage
		commit_url="$2"
		shift 2
		;;
	--delivery)
		[ "$#" -ge 2 ] || usage
		delivery="$2"
		shift 2
		;;
	--pusher)
		[ "$#" -ge 2 ] || usage
		pusher="$2"
		shift 2
		;;
	--before)
		[ "$#" -ge 2 ] || usage
		push_before="$2"
		shift 2
		;;
	--after)
		[ "$#" -ge 2 ] || usage
		push_after="$2"
		shift 2
		;;
	--compare-url)
		[ "$#" -ge 2 ] || usage
		compare_url="$2"
		shift 2
		;;
	--forced)
		[ "$#" -ge 2 ] || usage
		push_forced="$2"
		shift 2
		;;
	--distinct)
		[ "$#" -ge 2 ] || usage
		commit_distinct="$2"
		shift 2
		;;
	--clone-url)
		[ "$#" -ge 2 ] || usage
		clone_url="$2"
		shift 2
		;;
	--repo-url)
		[ "$#" -ge 2 ] || usage
		repo_url="$2"
		shift 2
		;;
	*)
		usage
		;;
	esac
done

[ -n "${source_repo}" ] || usage
[ -n "${source_ref}" ] || usage
[ -n "${commit_sha}" ] || usage

require_env DISPATCH_REPOSITORY
require_env GITHUB_TOKEN
require_env GIT_MIRROR_DIR

# If no explicit events were requested, use the normal webhook behavior.
if [ "${#dispatch_event_types[@]}" -eq 0 ]; then
	read -r -a dispatch_event_types <<< "${DISPATCH_EVENT_TYPES:-${default_dispatch_event_types}}"
fi

# To speed up compilation the selftest workflow stores ccache from branches
# specified in cache_base_refs as GHA caches. Try to compute the best ancestor
# from these branches for the current commit, so the workflow can hit the cache.
compute_cache_base

clone_url="${clone_url:-https://github.com/${source_repo}.git}"
repo_url="${repo_url:-https://github.com/${source_repo}}"
commit_url="${commit_url:-${repo_url}/commit/${commit_sha}}"
push_after="${push_after:-${commit_sha}}"
push_before="${push_before:-${commit_sha}}"
compare_url="${compare_url:-${commit_url}}"
fill_commit_message
resolve_fixes_targets

client_payload="$(build_client_payload)"

if [ "${DISPATCH_DRY_RUN:-0}" = "1" ] && [ -n "${cache_base_json}" ]; then
	jq -r '"Dry-run cache base: \(.ref) \(.sha) distance=\(.distance)"' \
		<<< "${cache_base_json}"
fi

# Dispatch the requested events.
for event_type in "${dispatch_event_types[@]}"; do
	dispatch_event "${event_type}" "${client_payload}" "${cache_base_json}"
done
