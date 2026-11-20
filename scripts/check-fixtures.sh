#!/usr/bin/env bash
# Rebuilds the HelloUpdate fixtures into a scratch directory and fails when any
# committed byte differs (test-strategy.md §4.5, "a CI check fails when a copy
# is older than its sources"). Covers the local update repo and the derived
# set of Tests/Fixtures/apks/ (#42).
#
#   scripts/check-fixtures.sh
#
# Needs ANDROID_HOME with build-tools 37.0.0, and a JDK that Gradle can run.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

committed_repo="$repo_root/Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate"
committed_derived="$repo_root/Tests/Fixtures/apks"

work="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-check-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT

APKRUN_FIXTURE_REPO="$work/repo" APKRUN_DERIVED_DIR="$work/apks" \
    "$script_dir/build-fixtures.sh" --app HelloUpdate

compare_tree() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    local status=0
    local file
    while IFS= read -r -d '' file; do
        local relative="${file#"$expected"/}"
        if [[ ! -f "$actual/$relative" ]]; then
            printf 'check-fixtures: %s: %s is missing from the rebuild\n' "$label" "$relative" >&2
            status=1
            continue
        fi
        if ! cmp -s "$file" "$actual/$relative"; then
            printf 'check-fixtures: %s: %s differs from the rebuilt bytes\n' "$label" "$relative" >&2
            status=1
        fi
    done < <(find "$expected" -type f -print0)
    return "$status"
}

status=0
compare_tree "$committed_repo" "$work/repo" "update repo" || status=1
compare_tree "$committed_derived" "$work/apks" "derived APKs" || status=1
if ((status == 0)); then
    printf 'check-fixtures: committed fixtures match the rebuilt bytes\n'
fi
exit "$status"
