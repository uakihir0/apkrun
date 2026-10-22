#!/usr/bin/env bash
# Builds the fixture apps (build-system.md §8). Writes Tests/Fixtures/AndroidApps/out/<app>.apk (or
# HelloSplit.apks), which is git-ignored and signed with the test-only key
# Tests/Fixtures/signing/test-fixture-a.jks.
#
#   scripts/build-fixtures.sh                     build out/HelloText.apk and check its signer
#   scripts/build-fixtures.sh --app HelloGL       build out/HelloGL.apk instead (the G3 gate, #24)
#   scripts/build-fixtures.sh --app HelloProbe    build out/HelloProbe.apk (#36 SELinux T2)
#   scripts/build-fixtures.sh --app HelloCompose  build out/HelloCompose.apk instead (the list of #25, G5 of #31)
#   scripts/build-fixtures.sh --app HelloWebView  build out/HelloWebView.apk instead (#30)
#   scripts/build-fixtures.sh --app HelloSplit   build the xhdpi/ja/arm64 split set as out/HelloSplit.apks
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

usage() {
    printf 'usage: scripts/build-fixtures.sh [--app HelloText|HelloGL|HelloCompose|HelloWebView|HelloSplit|HelloProbe] [--check-reproducible]\n' >&2
    exit 64
}

mode="build"
while (($# > 0)); do
    case "$1" in
        --check-reproducible) mode="check" ;;
        --app)
            (($# >= 2)) || usage
            app="$2"
            shift
            ;;
        *) usage ;;
    esac
    shift
done
case "$app" in
    HelloText | HelloGL | HelloCompose | HelloWebView | HelloSplit | HelloProbe) ;;
    *) usage ;;
esac
output_apk="$fixtures/out/$app.apk"
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
    verify_signer "$gradle_apk"
    mkdir -p "$(dirname "$output_apk")"
    cp "$gradle_apk" "$output_apk"
    printf 'build-fixtures: wrote %s\n' "$output_apk"
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
            shasum -a 256 ./*.apk | sort
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
