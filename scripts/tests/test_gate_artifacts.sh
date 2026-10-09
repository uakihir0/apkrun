#!/usr/bin/env bash
# Checks the gate's artifact verification (scripts/tools/verify-gate-artifacts.sh and
# verify-test-host-directory.sh) on fixture directories, and that run-gate.sh uses them in order (IR-376).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
verify_artifacts="$repo_root/scripts/tools/verify-gate-artifacts.sh"
verify_host="$repo_root/scripts/tools/verify-test-host-directory.sh"
gate_script="$repo_root/scripts/run-gate.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-gate-artifacts.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() {
    printf 'FAIL gate artifacts: %s\n' "$1" >&2
    exit 1
}

# A complete fixture: the artifacts as the builders write them.
directory="$work/linux"
mkdir -p "$directory/android-disks" "$directory/android-bundle"
: > "$directory/Image"
: > "$directory/initramfs.cpio.gz"
: > "$directory/android-bundle/manifest.json"
: > "$directory/android-disks/os.img"
: > "$directory/android-disks/userdata.img"
printf '{"disks":[{"file":"os.img"},{"file":"userdata.img"}]}\n' > "$directory/android-disks/disks.json"

expect_pass() {
    local name="$1"
    shift
    if ! output="$("$@" 2>&1)"; then
        fail "$name: expected pass: $output"
    fi
    printf 'PASS %s\n' "$name"
}

expect_fail() {
    local name="$1"
    local expected="$2"
    shift 2
    if output="$("$@" 2>&1)"; then
        fail "$name: expected failure"
    fi
    if [[ "$output" != *"$expected"* ]]; then
        fail "$name: message lacks '$expected': $output"
    fi
    printf 'PASS %s\n' "$name"
}

expect_pass "a complete directory passes G1" "$verify_artifacts" "$directory" G1
expect_pass "a complete directory passes G2" "$verify_artifacts" "$directory" G2

missing_disk="$work/no-disk"
cp -R "$directory" "$missing_disk"
rm "$missing_disk/android-disks/os.img"
expect_fail "a missing disk file stops G1 and names it" "android-disks/os.img" \
    "$verify_artifacts" "$missing_disk" G1

missing_metadata="$work/no-metadata"
cp -R "$directory" "$missing_metadata"
rm "$missing_metadata/android-disks/disks.json"
expect_fail "a missing disks.json stops G1 and names it" "android-disks/disks.json" \
    "$verify_artifacts" "$missing_metadata" G1

no_bundle="$work/no-bundle"
cp -R "$directory" "$no_bundle"
rm -r "$no_bundle/android-bundle"
expect_pass "G1 does not need the Android bundle" "$verify_artifacts" "$no_bundle" G1
expect_fail "G2 needs the Android bundle" "android-bundle/manifest.json" \
    "$verify_artifacts" "$no_bundle" G2

unreadable="$work/unreadable"
cp -R "$directory" "$unreadable"
printf '{not json' > "$unreadable/android-disks/disks.json"
expect_fail "an unreadable disks.json is reported, not skipped" "cannot be read" \
    "$verify_artifacts" "$unreadable" G1

host_app="$work/host.app"
mkdir -p "$host_app/Contents"
plutil -create xml1 "$host_app/Contents/Info.plist"
plutil -insert APKRUN_TEST_LINUX_DIR -string "$directory" "$host_app/Contents/Info.plist"
expect_pass "a host that reads the gate's directory passes" "$verify_host" "$host_app" "$directory"
expect_fail "a host that reads another directory fails" "reads" \
    "$verify_host" "$host_app" "$work/other"
expect_fail "a missing host fails" "build it first" "$verify_host" "$work/missing.app" "$directory"

default_line='APKRUN_TEST_LINUX_DIR="${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}"'
if ! grep -qxF "$default_line" "$gate_script"; then
    fail "run-gate.sh does not default to the directory the producers and the harness use"
fi
printf 'PASS run-gate.sh uses the shared test directory by default\n'

line_of() {
    grep -n "$1" "$gate_script" | head -1 | cut -d: -f1
}
disks_line="$(line_of '^scripts/build-test-android-disks.sh$')"
verify_line="$(line_of '^scripts/tools/verify-gate-artifacts.sh ')"
host_build_line="$(line_of '^xcodebuild build-for-testing')"
host_check_line="$(line_of '^scripts/tools/verify-test-host-directory.sh')"
first_test_line="$(line_of '^xcodebuild test')"
for entry in "$disks_line" "$verify_line" "$host_build_line" "$host_check_line" "$first_test_line"; do
    [[ -n "$entry" ]] || fail "run-gate.sh lacks one of the artifact steps"
done
if (( disks_line >= verify_line || verify_line >= host_build_line \
    || host_build_line >= host_check_line || host_check_line >= first_test_line )); then
    fail "run-gate.sh runs the artifact steps out of order"
fi
printf 'PASS run-gate.sh builds the disks, verifies the artifacts and the host, then runs the tests\n'
