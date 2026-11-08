#!/bin/sh
# Shared output and failure helpers for repository shell scripts.

: "${REPO_ROOT:?the caller must set REPO_ROOT before sourcing tools/common.sh}"

step() {
	printf '\n==> %s\n' "$*"
}

say() {
	printf '  %s\n' "$*"
}

die() {
	message=$1
	shift
	printf 'error: %s\n' "$message" >&2
	for detail do
		printf '  %s\n' "$detail" >&2
	done
	exit 1
}

skip() {
	message=$1
	if [ "${NEXIS_REQUIRE_SMOKE:-0}" = "1" ]; then
		die "$message" "The smoke test is required in this environment."
	fi
	say "$message - skipping"
	exit 0
}
