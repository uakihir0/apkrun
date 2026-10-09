#!/usr/bin/env bash
# Builds the fixture apps (build-system.md §8). Writes Tests/Fixtures/AndroidApps/out/HelloText.apk, which is
# git-ignored and signed with the test-only key Tests/Fixtures/signing/test-fixture-a.jks.
#
#   scripts/build-fixtures.sh                     build out/HelloText.apk and check its signer
#   scripts/build-fixtures.sh --check-reproducible
#                                                 build twice from clean, and compare the badging, the dex
#                                                 hashes, and the archive listing (build-system.md §14)
#
# Needs ANDROID_HOME with build-tools 37.0.0, and a JDK that Gradle can run (17 or newer).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixtures="$repo_root/Tests/Fixtures/AndroidApps"
output_apk="$fixtures/out/HelloText.apk"
gradle_apk="$fixtures/HelloText/build/outputs/apk/release/HelloText-release.apk"
build_tools_version="37.0.0"
# The SHA-256 of the test-only certificate of test-fixture-a.jks (IR-328). A signature from any other key fails.
expected_signer_sha256="a2f3893391ae70e6faee50a05c0d0c4b94505781f7af0d547c1625399e05f8b4"

usage() {
    printf 'usage: scripts/build-fixtures.sh [--check-reproducible]\n' >&2
    exit 64
}

mode="build"
case "${1:-}" in
    "") ;;
    --check-reproducible) mode="check" ;;
    *) usage ;;
esac
if (($# > 1)); then
    usage
fi

if [[ -z "${ANDROID_HOME:-}" ]]; then
    printf 'build-fixtures: set ANDROID_HOME to the Android SDK (environment-setup.md §2.5)\n' >&2
    exit 78
fi
build_tools="$ANDROID_HOME/build-tools/$build_tools_version"
apksigner="$build_tools/apksigner"
aapt2="$build_tools/aapt2"
for tool in "$apksigner" "$aapt2"; do
    if [[ ! -x "$tool" ]]; then
        printf 'build-fixtures: %s is missing (environment-setup.md §2.5)\n' "$tool" >&2
        exit 78
    fi
done

gradle_build() {
    "$fixtures/gradlew" -p "$fixtures" --console=plain "$@"
}

# Fails unless the APK is signed only by the pinned test certificate.
verify_signer() {
    local apk="$1"
    local signers
    signers="$("$apksigner" verify --print-certs "$apk" | awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
    if [[ -z "$signers" || "$signers" != "$expected_signer_sha256" ]]; then
        printf 'build-fixtures: %s is not signed by the test fixture key (signer %s)\n' "$apk" "$signers" >&2
        exit 1
    fi
}

if [[ "$mode" == "build" ]]; then
    gradle_build :HelloText:assembleRelease
    verify_signer "$gradle_apk"
    mkdir -p "$(dirname "$output_apk")"
    cp "$gradle_apk" "$output_apk"
    printf 'build-fixtures: wrote %s\n' "$output_apk"
    exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT
for run in 1 2; do
    gradle_build :HelloText:clean :HelloText:assembleRelease
    cp "$gradle_apk" "$work/run$run.apk"
    verify_signer "$work/run$run.apk"
    "$aapt2" dump badging "$work/run$run.apk" > "$work/run$run.badging"
    unzip -Z1 "$work/run$run.apk" > "$work/run$run.listing"
    unzip -p "$work/run$run.apk" 'classes*.dex' | shasum -a 256 > "$work/run$run.dex"
done

status=0
for artifact in badging listing dex; do
    if ! cmp -s "$work/run1.$artifact" "$work/run2.$artifact"; then
        printf 'build-fixtures: the two builds differ in %s\n' "$artifact" >&2
        status=1
    fi
done
if ((status == 0)); then
    printf 'build-fixtures: reproducible (badging, dex hashes, and archive listing match)\n'
fi
exit "$status"
