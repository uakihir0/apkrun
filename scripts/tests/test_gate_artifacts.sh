#!/usr/bin/env bash
# Checks the gate's artifact verification (scripts/tools/verify-gate-artifacts.sh and
# verify-test-host-directory.sh) on fixture directories, and that run-gate.sh uses them in order (IR-376).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
verify_artifacts="$repo_root/scripts/tools/verify-gate-artifacts.sh"
verify_host="$repo_root/scripts/tools/verify-test-host-directory.sh"
verify_composed_bundle="$repo_root/scripts/tools/verify-composed-image-bundle.py"
gate_script="$repo_root/scripts/run-gate.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-gate-artifacts.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() {
    printf 'FAIL gate artifacts: %s\n' "$1" >&2
    exit 1
}

# A complete fixture: the artifacts as the builders write them.
directory="$work/linux"
mkdir -p "$directory/android-disks" "$directory/android-bundle" "$directory/virgl-runtime"
: > "$directory/Image"
: > "$directory/initramfs.cpio.gz"
: > "$directory/scanout-00-1024x768-60.edid"
for library in libvirglrenderer.1.dylib libepoxy.0.dylib libEGL.dylib libGLESv2.dylib; do
    : > "$directory/virgl-runtime/$library"
done
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
selected_bundle="$work/selected-bundle"
mkdir -p "$selected_bundle"
: > "$selected_bundle/manifest.json"
expect_pass "G2 accepts the selected external bundle in a clean artifact directory" \
    "$verify_artifacts" "$no_bundle" G2 --android-bundle "$selected_bundle"

no_runtime="$work/no-runtime"
cp -R "$directory" "$no_runtime"
rm "$no_runtime/virgl-runtime/libEGL.dylib"
expect_fail "a missing staged runtime library stops G1 and names it" "virgl-runtime/libEGL.dylib" \
    "$verify_artifacts" "$no_runtime" G1

no_edid="$work/no-edid"
cp -R "$directory" "$no_edid"
rm "$no_edid/scanout-00-1024x768-60.edid"
expect_fail "a missing golden EDID block stops G2 and names it" "scanout-00-1024x768-60.edid" \
    "$verify_artifacts" "$no_edid" G2

unreadable="$work/unreadable"
cp -R "$directory" "$unreadable"
printf '{not json' > "$unreadable/android-disks/disks.json"
expect_fail "an unreadable disks.json is reported, not skipped" "cannot be read" \
    "$verify_artifacts" "$unreadable" G1

host_app="$work/host.app"
mkdir -p "$host_app/Contents"
plutil -create xml1 "$host_app/Contents/Info.plist"
plutil -insert APKRUN_TEST_LINUX_DIR -string "$directory" "$host_app/Contents/Info.plist"
bundle="$directory/android-bundle"
plutil -insert APKRUN_TEST_ANDROID_BUNDLE -string "$bundle" "$host_app/Contents/Info.plist"
plutil -insert APKRUN_TEST_REQUIRE_COMPOSED -string 0 "$host_app/Contents/Info.plist"
plutil -insert APKRUN_G3_BUNDLE -string "$bundle" "$host_app/Contents/Info.plist"
plutil -insert APKRUN_G3_REQUIRE_COMPOSED -string 1 "$host_app/Contents/Info.plist"
expect_pass "a host that reads the gate's directory passes" "$verify_host" "$host_app" "$directory"
expect_fail "a host that reads another directory fails" "reads" \
    "$verify_host" "$host_app" "$work/other"
expect_pass "a host that reads the selected Android bundle passes" \
    "$verify_host" "$host_app" "$directory" --android-bundle "$bundle"
expect_fail "a host that reads another Android bundle fails" "reads bundle" \
    "$verify_host" "$host_app" "$directory" --android-bundle "$work/other-bundle"
expect_pass "a host that preserves the stock G2 baseline passes" \
    "$verify_host" "$host_app" "$directory" --android-bundle "$bundle" --require-composed 0
expect_fail "a host with the wrong G2 image requirement fails" "requires composed image" \
    "$verify_host" "$host_app" "$directory" --android-bundle "$bundle" --require-composed 1
expect_pass "a host that reads the selected G3 bundle passes" \
    "$verify_host" "$host_app" "$directory" --g3-bundle "$bundle" --g3-require-composed 1
plutil -replace APKRUN_G3_REQUIRE_COMPOSED -string 0 "$host_app/Contents/Info.plist"
expect_pass "a host that preserves the G3 stock baseline passes" \
    "$verify_host" "$host_app" "$directory" --g3-bundle "$bundle" --g3-require-composed 0
plutil -replace APKRUN_G3_REQUIRE_COMPOSED -string 1 "$host_app/Contents/Info.plist"
expect_fail "a host with the wrong G3 image requirement fails" "requires composed G3 image" \
    "$verify_host" "$host_app" "$directory" --g3-bundle "$bundle" --g3-require-composed 0
expect_fail "a missing host fails" "build it first" "$verify_host" "$work/missing.app" "$directory"

composed_bundle="$work/composed-bundle"
mkdir -p "$composed_bundle"
cp "$repo_root/Images/tools/tests/fixtures/runtime-manifests/valid/apkrun-composed-cf16373615.json" \
    "$composed_bundle/manifest.json"
expect_pass "a composed APKRun bundle passes G2/G3 selection" \
    python3 -I "$verify_composed_bundle" "$composed_bundle"
python3 - "$composed_bundle/manifest.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["provenance"].pop("composition")
path.write_text(json.dumps(manifest))
PY
expect_fail "an APKRun bundle without composition provenance is rejected" \
    "expected kind=apkrun with composition provenance" \
    python3 -I "$verify_composed_bundle" "$composed_bundle"
printf '{"kind":"stock"}\n' > "$composed_bundle/manifest.json"
expect_fail "a stock image is not accepted for the default G2/G3 image selection" \
    "expected kind=apkrun with composition provenance" \
    python3 -I "$verify_composed_bundle" "$composed_bundle"
expect_pass "a stock image remains available for an explicit baseline run" \
    python3 -I "$verify_composed_bundle" --allow-stock "$composed_bundle"

default_line='APKRUN_TEST_LINUX_DIR="${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}"'
if ! grep -qxF "$default_line" "$gate_script"; then
    fail "run-gate.sh does not default to the directory the producers and the harness use"
fi
printf 'PASS run-gate.sh uses the shared test directory by default\n'
if ! grep -qxF 'unset APKRUN_TEST_ANDROID_BUNDLE APKRUN_G3_BUNDLE APKRUN_G3_REQUIRE_COMPOSED' "$gate_script"; then
    fail "run-gate.sh does not clear inherited bundle overrides before building test hosts"
fi
printf 'PASS run-gate.sh clears inherited bundle overrides before building test hosts\n'

line_of() {
    grep -n "$1" "$gate_script" | head -1 | cut -d: -f1
}
disks_line="$(line_of '^scripts/build-test-android-disks.sh$')"
verify_line="$(line_of '^scripts/tools/verify-gate-artifacts.sh ')"
host_build_line="$(line_of '^xcodebuild build-for-testing')"
host_check_line="$(line_of '^[[:space:]]*scripts/tools/verify-test-host-directory.sh')"
first_test_line="$(line_of '^xcodebuild test')"
for entry in "$disks_line" "$verify_line" "$host_build_line" "$host_check_line" "$first_test_line"; do
    [[ -n "$entry" ]] || fail "run-gate.sh lacks one of the artifact steps"
done
if (( disks_line >= verify_line || verify_line >= host_build_line \
    || host_build_line >= host_check_line || host_check_line >= first_test_line )); then
    fail "run-gate.sh runs the artifact steps out of order"
fi
printf 'PASS run-gate.sh builds the disks, verifies the artifacts and the host, then runs the tests\n'
