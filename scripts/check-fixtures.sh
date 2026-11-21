#!/usr/bin/env bash
# Rebuilds the HelloUpdate fixtures into a scratch directory and fails when any
# committed byte differs (test-strategy.md §4.5, "a CI check fails when a copy
# is older than its sources"). Covers the local update repo, the derived
# set of Tests/Fixtures/apks/ (#42), and Tests/Fixtures/containers/HelloSplit.apks (#43).
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
        if ! compare_file "$file" "$actual/$relative"; then
            printf 'check-fixtures: %s: %s differs from the rebuild\n' "$label" "$relative" >&2
            status=1
        fi
    done < <(find "$expected" -type f -print0)
    return "$status"
}

# ZIP containers (APKs, .apks) are compared entry-by-entry on (name, CRC,
# size), skipping META-INF/: AGP emits metadata there (app-metadata,
# version-control-info) that is not byte-stable across build environments,
# and the stripped signing stamp already proved the signer is the pinned test
# key. Other files stay byte-exact.
compare_file() {
    local committed="$1"
    local rebuilt="$2"
    case "$committed" in
        *.apk|*.apks)
            python3 - "$committed" "$rebuilt" <<'PY'
import sys
import zipfile

def entries(path):
    with zipfile.ZipFile(path) as archive:
        return sorted(
            (i.filename, i.CRC, i.file_size)
            for i in archive.infolist()
            if not i.filename.startswith("META-INF/")
        )

sys.exit(0 if entries(sys.argv[1]) == entries(sys.argv[2]) else 1)
PY
            ;;
        *)
            cmp -s "$committed" "$rebuilt"
            ;;
    esac
}

status=0
compare_tree "$committed_repo" "$work/repo" "update repo" || status=1
compare_tree "$committed_derived" "$work/apks" "derived APKs" || status=1

# HelloSplit.apks builds through bundletool, not the derived-apks step, so it
# gets its own rebuild (#43 step 1).
"$script_dir/build-fixtures.sh" --app HelloSplit >/dev/null
if ! compare_file \
    "$repo_root/Tests/Fixtures/containers/HelloSplit.apks" \
    "$repo_root/Tests/Fixtures/AndroidApps/out/HelloSplit.apks"; then
    printf 'check-fixtures: HelloSplit.apks differs from the rebuilt entries\n' >&2
    status=1
fi
if ((status == 0)); then
    printf 'check-fixtures: committed fixtures match the rebuilt bytes\n'
fi
exit "$status"
