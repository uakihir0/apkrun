#!/usr/bin/env bash
# Builds the fixture apps (build-system.md §8). Writes Tests/Fixtures/AndroidApps/out/<app>.apk (or
# HelloSplit.apks), which is git-ignored and signed with the test-only key
# Tests/Fixtures/signing/test-fixture-a.jks.
#
#   scripts/build-fixtures.sh                     build out/HelloText.apk and check its signer
#   scripts/build-fixtures.sh --version-code 2    build and stage out/HelloText-v2.apk (#37)
#   scripts/build-fixtures.sh --app HelloProbe    build out/HelloProbe.apk (#36 SELinux isolation)
#   scripts/build-fixtures.sh --app HelloGL       build out/HelloGL.apk instead (the G3 gate, #24)
#   scripts/build-fixtures.sh --app HelloCompose  build out/HelloCompose.apk instead (the list of #25, G5 of #31)
#   scripts/build-fixtures.sh --app HelloWebView  build out/HelloWebView.apk instead (#30)
#   scripts/build-fixtures.sh --app HelloSplit   build the xhdpi/ja/arm64 split set as out/HelloSplit.apks
#   scripts/build-fixtures.sh --app SystemServicesTest --platform-test-key
#                                                 build the composed-image instrumentation fixture (#36)
#   scripts/build-fixtures.sh --check-reproducible
#                                                 build twice from clean, and compare the badging, the dex
#                                                 hashes, and the archive listing (build-system.md §14)
#
# Needs ANDROID_HOME with build-tools 37.0.0, and a JDK that Gradle can run (17 or newer).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixtures="$repo_root/Tests/Fixtures/AndroidApps"
app="HelloText"
build_tools_version="37.0.0"
bundletool_version="1.18.3"
bundletool_sha256="a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29"
bundletool_url="https://github.com/google/bundletool/releases/download/$bundletool_version/bundletool-all-$bundletool_version.jar"
# The SHA-256 of the test-only certificate of test-fixture-a.jks (IR-328). A signature from any other key fails.
expected_signer_sha256="a2f3893391ae70e6faee50a05c0d0c4b94505781f7af0d547c1625399e05f8b4"
expected_platform_signer_sha256="c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8"
platform_test_key="$repo_root/Tests/Fixtures/signing/aosp-test-platform.pk8"
platform_test_certificate="$repo_root/Tests/Fixtures/signing/aosp-test-platform.x509.pem"

usage() {
    printf 'usage: scripts/build-fixtures.sh [--app HelloText|HelloProbe|HelloGL|HelloCompose|HelloWebView|HelloSplit|SystemServicesTest] [--version-code N] [--platform-test-key] [--check-reproducible]\n' >&2
    exit 64
}

mode="build"
platform_test_key_enabled=0
version_code=1
version_code_set=0
while (($# > 0)); do
    case "$1" in
        --check-reproducible) mode="check" ;;
        --app)
            (($# >= 2)) || usage
            app="$2"
            shift
            ;;
        --platform-test-key)
            ((platform_test_key_enabled == 0)) || usage
            platform_test_key_enabled=1
            ;;
        --version-code)
            (($# >= 2)) && ((version_code_set == 0)) || usage
            version_code_set=1
            version_code="$2"
            shift
            ;;
        *) usage ;;
    esac
    shift
done
case "$app" in
    HelloText | HelloProbe | HelloGL | HelloCompose | HelloWebView | HelloSplit | SystemServicesTest) ;;
    *) usage ;;
esac
if [[ ! "$version_code" =~ ^[1-9][0-9]*$ ]] || ((${#version_code} > 10)); then
    printf 'build-fixtures: version code must be between 1 and 2147483647\n' >&2
    exit 64
fi
if ((${#version_code} == 10)) && ((10#$version_code > 2147483647)); then
    printf 'build-fixtures: version code must be between 1 and 2147483647\n' >&2
    exit 64
fi
if [[ "$app" != "HelloText" && "$version_code" != "1" ]]; then
    printf 'build-fixtures: --version-code is only supported for HelloText\n' >&2
    exit 64
fi
if ((platform_test_key_enabled)) && [[ "$app" != "SystemServicesTest" ]]; then
    printf 'build-fixtures: --platform-test-key is reserved for the composed-image SystemServicesTest fixture\n' >&2
    exit 64
fi
if [[ "$mode" == "build" && "$app" == "SystemServicesTest" ]] && ((platform_test_key_enabled == 0)); then
    printf 'build-fixtures: SystemServicesTest must be signed for the composed image; pass --platform-test-key\n' >&2
    exit 64
fi
if [[ "$mode" == "check" ]] && ((platform_test_key_enabled)); then
    printf 'build-fixtures: --platform-test-key cannot be used with --check-reproducible\n' >&2
    exit 64
fi
if ((platform_test_key_enabled)); then
    [[ -f "$platform_test_key" && ! -L "$platform_test_key" ]] || {
        printf 'build-fixtures: the AOSP platform test key is missing or symlinked: %s\n' \
            "$platform_test_key" >&2
        exit 78
    }
    [[ -f "$platform_test_certificate" && ! -L "$platform_test_certificate" ]] || {
        printf 'build-fixtures: the AOSP platform test certificate is missing or symlinked: %s\n' \
            "$platform_test_certificate" >&2
        exit 78
    }
fi
output_name="$app"
if [[ "$app" == "HelloText" && "$version_code" != "1" ]]; then
    output_name="HelloText-v$version_code"
fi
output_apk="$fixtures/out/$output_name.apk"
gradle_apk="$fixtures/$app/build/outputs/apk/release/$app-release.apk"
gradle_bundle="$fixtures/$app/build/outputs/bundle/release/$app-release.aab"

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
    "$fixtures/gradlew" -p "$fixtures" --console=plain "$@" "-PapkrunFixtureVersionCode=$version_code"
}

# Fails unless the APK is signed only by the pinned test certificate.
verify_signer() {
    local apk="$1"
    local expected="${2:-$expected_signer_sha256}"
    local signers
    signers="$("$apksigner" verify --print-certs "$apk" | awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
    if [[ -z "$signers" || "$signers" != "$expected" ]]; then
        printf 'build-fixtures: %s is not signed by the test fixture key (signer %s)\n' "$apk" "$signers" >&2
        exit 1
    fi
}

ensure_bundletool() {
    local tool_dir="$repo_root/build/fixture-tools"
    local jar="$tool_dir/bundletool-all-$bundletool_version.jar"
    local actual_sha256

    mkdir -p "$tool_dir"
    if [[ ! -f "$jar" ]]; then
        curl -fL --retry 0 --max-time 60 "$bundletool_url" -o "$jar"
    fi
    actual_sha256="$(shasum -a 256 "$jar" | awk '{ print $1 }')"
    if [[ "$actual_sha256" != "$bundletool_sha256" ]]; then
        rm -f "$jar"
        printf 'build-fixtures: bundletool %s failed its pinned SHA-256 check\n' "$bundletool_version" >&2
        exit 1
    fi
    printf '%s\n' "$jar"
}

build_hello_split() {
    local output="$1"
    local bundletool_jar="$2"
    mkdir -p "$(dirname "$output")"
    gradle_build ":HelloSplit:bundleRelease"
    java -jar "$bundletool_jar" build-apks \
        --bundle="$gradle_bundle" \
        --output="$output" \
        --device-spec="$fixtures/HelloSplit/device-spec.json" \
        --ks="$repo_root/Tests/Fixtures/signing/test-fixture-a.jks" \
        --ks-key-alias=fixture-a \
        --ks-pass=pass:apkrun-test-fixture \
        --key-pass=pass:apkrun-test-fixture \
        --overwrite
}

verify_hello_split() {
    local archive="$1"
    local listing_file="$2"
    local extracted_dir="$3"
    local bundletool_jar="$4"
    local entry
    local name
    local listing

    unzip -Z1 "$archive" | grep -E '^splits/[^/]+[.]apk$' > "$listing_file"
    listing="$(cat "$listing_file")"
    for expected in \
        base-master.apk \
        base-arm64_v8a.apk \
        base-xhdpi.apk \
        base-ja.apk \
        feature-master.apk
    do
        if ! printf '%s\n' "$listing" | awk -v wanted="$expected" '$0 ~ ("(^|/)" wanted "$") { found = 1 } END { exit !found }'; then
            printf 'build-fixtures: %s is missing the required %s split\n' "$archive" "$expected" >&2
            exit 1
        fi
    done

    mkdir -p "$extracted_dir"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name="${entry##*/}"
        unzip -p "$archive" "$entry" > "$extracted_dir/$name"
        verify_signer "$extracted_dir/$name"
    done < "$listing_file"
    java -jar "$bundletool_jar" validate --bundle="$gradle_bundle"
}

if [[ "$mode" == "build" ]]; then
    if [[ "$app" == "HelloSplit" ]]; then
        bundletool_jar="$(ensure_bundletool)"
        output_apks="$fixtures/out/HelloSplit.apks"
        build_hello_split "$output_apks" "$bundletool_jar"
        verify_hello_split \
            "$output_apks" \
            "$fixtures/out/HelloSplit.splits" \
            "$fixtures/out/HelloSplit-extracted" \
            "$bundletool_jar"
        rm -rf "$fixtures/out/HelloSplit-extracted" "$fixtures/out/HelloSplit.splits"
        printf 'build-fixtures: wrote %s\n' "$output_apks"
        exit 0
    fi
    gradle_build ":$app:assembleRelease"
    mkdir -p "$(dirname "$output_apk")"
    if ((platform_test_key_enabled)); then
        rm -f "$output_apk"
        "$apksigner" sign \
            --key "$platform_test_key" \
            --cert "$platform_test_certificate" \
            --out "$output_apk" \
            "$gradle_apk"
        verify_signer "$output_apk" "$expected_platform_signer_sha256"
    else
        verify_signer "$gradle_apk"
        cp "$gradle_apk" "$output_apk"
    fi
    printf 'build-fixtures: wrote %s\n' "$output_apk"
    if [[ "$app" == "HelloProbe" ]]; then
        fixture_directory="${APKRUN_TEST_FIXTURES_DIR:-/tmp/apkrun-test-fixtures}"
        mkdir -p "$fixture_directory"
        cp "$output_apk" "$fixture_directory/HelloProbe.apk"
        printf 'build-fixtures: staged %s\n' "$fixture_directory/HelloProbe.apk"
    fi
    if [[ "$app" == "HelloText" ]]; then
        fixture_directory="${APKRUN_TEST_FIXTURES_DIR:-/tmp/apkrun-test-fixtures}"
        mkdir -p "$fixture_directory"
        cp "$output_apk" "$fixture_directory/$output_name.apk"
        printf 'build-fixtures: staged %s\n' "$fixture_directory/$output_name.apk"
    fi
    if [[ "$app" == "SystemServicesTest" ]]; then
        fixture_directory="${APKRUN_TEST_FIXTURES_DIR:-/tmp/apkrun-test-fixtures}"
        mkdir -p "$fixture_directory"
        cp "$output_apk" "$fixture_directory/SystemServicesTest.apk"
        printf 'build-fixtures: staged %s\n' "$fixture_directory/SystemServicesTest.apk"
    fi
    exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [[ "$app" == "HelloSplit" ]]; then
    bundletool_jar="$(ensure_bundletool)"
    for run in 1 2; do
        gradle_build ":HelloSplit:clean" ":feature:clean" ":HelloSplit:bundleRelease"
        build_hello_split "$work/run$run.apks" "$bundletool_jar"
        verify_hello_split \
            "$work/run$run.apks" \
            "$work/run$run.splits" \
            "$work/run$run-extracted" \
            "$bundletool_jar"
        (
            cd "$work/run$run-extracted"
            shasum -a 256 *.apk | sort
        ) > "$work/run$run.apk-hashes"
    done
    if cmp -s "$work/run1.apk-hashes" "$work/run2.apk-hashes"; then
        printf 'build-fixtures: HelloSplit reproducible (all split APK hashes match)\n'
        exit 0
    fi
    printf 'build-fixtures: the two HelloSplit builds differ in split APK hashes\n' >&2
    exit 1
fi
for run in 1 2; do
    gradle_build ":$app:clean" ":$app:assembleRelease"
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
