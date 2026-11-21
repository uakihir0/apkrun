#!/usr/bin/env bash
# Builds the fixture apps (build-system.md §8). Writes Tests/Fixtures/AndroidApps/out/<app>.apk (or
# HelloSplit.apks), which is git-ignored and signed with the test-only key
# Tests/Fixtures/signing/test-fixture-a.jks.
#
#   scripts/build-fixtures.sh                     build out/HelloText.apk and check its signer
#   scripts/build-fixtures.sh --app HelloGL       build out/HelloGL.apk instead (the G3 gate, #24)
#   scripts/build-fixtures.sh --app HelloCompose  build out/HelloCompose.apk instead (the list of #25, G5 of #31)
#   scripts/build-fixtures.sh --app HelloWebView  build out/HelloWebView.apk instead (#30)
#   scripts/build-fixtures.sh --app HelloUpdate  build V1+V2 into Tests/Fixtures/update-repos/local/… (#38)
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
    printf 'usage: scripts/build-fixtures.sh [--app HelloText|HelloUpdate|HelloGL|HelloCompose|HelloWebView|HelloSplit|OtherInstaller] [--check-reproducible]\n' >&2
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
    HelloText | HelloUpdate | HelloGL | HelloCompose | HelloWebView | HelloSplit | OtherInstaller) ;;
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
    strip_signing_stamp "$apk"
}

# AGP signs Gradle outputs with an extra signing-block pair (ID 0x504b4453,
# the "stamp") that embeds the signing time, so committed fixtures would never
# byte-match a rebuild (test-strategy.md §4.5). The pair is not part of the
# v2/v3 signature — dropping it leaves verification intact.
strip_signing_stamp() {
    python3 - "$1" <<'PY'
import struct
import sys

path = sys.argv[1]
data = bytearray(open(path, "rb").read())
eocd = data.rfind(b"PK\x05\x06")
cd_offset = struct.unpack_from("<I", data, eocd + 16)[0]
magic = data.find(b"APK Sig Block 42")
if magic == -1:
    sys.exit(0)
block_start = cd_offset - 8 - struct.unpack_from("<Q", data, magic - 8)[0]
pos = block_start + 8
pairs = bytearray()
removed = False
while pos < magic - 8:
    pair_length = struct.unpack_from("<Q", data, pos)[0]
    if struct.unpack_from("<I", data, pos + 8)[0] == 0x504B4453:
        removed = True
    else:
        pairs += data[pos : pos + 8 + pair_length]
    pos += 8 + pair_length
if not removed:
    sys.exit(0)
size = len(pairs) + 24
block = (
    struct.pack("<Q", size) + bytes(pairs) + struct.pack("<Q", size) + b"APK Sig Block 42"
)
data = data[:block_start] + block + data[cd_offset:]
eocd = data.rfind(b"PK\x05\x06")
struct.pack_into("<I", data, eocd + 16, block_start + len(block))
open(path, "wb").write(data)
PY
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

build_hello_update() {
    # The local update repo of #38: <root>/<packageId>/<versionCode>/app.apk,
    # committed so the T0/T1 checks and the T2 image tests share the same sets.
    local repo="${APKRUN_FIXTURE_REPO:-$repo_root/Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate}"
    local hello_apk="$fixtures/HelloUpdate/build/outputs/apk/release/HelloUpdate-release.apk"
    local version
    for version in 1 2; do
        gradle_build ":HelloUpdate:assembleRelease" -Papkrun.versionCode="$version"
        verify_signer "$hello_apk"
        mkdir -p "$repo/$version"
        cp "$hello_apk" "$repo/$version/app.apk"
        printf 'build-fixtures: wrote %s\n' "$repo/$version/app.apk"
    done
    build_derived_helloupdate "$repo"
}

# The derived packages of test-strategy.md §4.3 (#42): the committed APKs the
# T0 validation matrix reads under Tests/Fixtures/apks/ (NFR-DEV-02), signed
# with pinned `apksigner rotate`/`sign --lineage` invocations.
build_derived_helloupdate() {
    local repo="$1"
    local out_dir="${APKRUN_DERIVED_DIR:-$repo_root/Tests/Fixtures/apks}"
    local key_a="$repo_root/Tests/Fixtures/signing/test-fixture-a.jks"
    local key_b="$repo_root/Tests/Fixtures/signing/test-fixture-b.jks"
    local pass="pass:apkrun-test-fixture"
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-derived.XXXXXX")"
    mkdir -p "$out_dir"

    cp "$repo/1/app.apk" "$out_dir/HelloUpdate-v1.apk"
    cp "$repo/2/app.apk" "$out_dir/HelloUpdate-v2.apk"

    # V2 signed by key B only: the "other signer" and signerMismatch input.
    "$apksigner" sign --ks "$key_b" --ks-key-alias fixture-b \
        --ks-pass "$pass" --key-pass "$pass" \
        --v4-signing-enabled false \
        --out "$out_dir/HelloUpdate-v2-other-signer.apk" "$repo/2/app.apk"

    # Lineage A → B variants. The flags land on node A and say what the
    # rotated-away certificate may still do (update-system.md §6 V3).
    local rotate_args=(
        --old-signer --ks "$key_a" --ks-key-alias fixture-a
        --ks-pass "$pass" --key-pass "$pass"
    )
    "$apksigner" rotate "${rotate_args[@]}" --set-installed-data true \
        --set-rollback false \
        --new-signer --ks "$key_b" --ks-key-alias fixture-b \
        --ks-pass "$pass" --key-pass "$pass" \
        --out "$work/lineage-a-b-installed-data.bin"
    "$apksigner" rotate "${rotate_args[@]}" --set-installed-data false \
        --set-rollback false \
        --new-signer --ks "$key_b" --ks-key-alias fixture-b \
        --ks-pass "$pass" --key-pass "$pass" \
        --out "$work/lineage-a-b-plain.bin"
    "$apksigner" rotate "${rotate_args[@]}" --set-installed-data true \
        --set-rollback true \
        --new-signer --ks "$key_b" --ks-key-alias fixture-b \
        --ks-pass "$pass" --key-pass "$pass" \
        --out "$work/lineage-a-b-rollback.bin"
    "$apksigner" rotate \
        --old-signer --ks "$key_b" --ks-key-alias fixture-b \
        --ks-pass "$pass" --key-pass "$pass" \
        --new-signer --ks "$key_a" --ks-key-alias fixture-a \
        --ks-pass "$pass" --key-pass "$pass" \
        --out "$work/lineage-b-a.bin"

    # v3-only: the v1 and v2 schemes would require the oldest lineage signer;
    # the proof-of-rotation attribute lives in the v3 signer block, which is
    # what the host verifier reads.
    local scheme_args=(
        --v1-signing-enabled false --v2-signing-enabled false
        --v4-signing-enabled false
        --rotation-min-sdk-version 29
    )
    local signed_by_b=(
        --ks "$key_b" --ks-key-alias fixture-b
        --ks-pass "$pass" --key-pass "$pass"
        "${scheme_args[@]}"
    )
    "$apksigner" sign "${signed_by_b[@]}" \
        --lineage "$work/lineage-a-b-installed-data.bin" \
        --out "$out_dir/HelloUpdate-v2-rotate-installed-data.apk" "$repo/2/app.apk"
    "$apksigner" sign "${signed_by_b[@]}" \
        --lineage "$work/lineage-a-b-plain.bin" \
        --out "$out_dir/HelloUpdate-v2-rotate-no-installed-data.apk" "$repo/2/app.apk"
    "$apksigner" sign "${signed_by_b[@]}" \
        --lineage "$work/lineage-a-b-rollback.bin" \
        --out "$out_dir/HelloUpdate-v2-rotate-rollback.apk" "$repo/2/app.apk"
    "$apksigner" sign --ks "$key_a" --ks-key-alias fixture-a \
        --ks-pass "$pass" --key-pass "$pass" \
        "${scheme_args[@]}" \
        --lineage "$work/lineage-b-a.bin" \
        --out "$out_dir/HelloUpdate-v2-rotate-back.apk" "$repo/2/app.apk"

    # One flipped byte inside classes.dex → the v2 content digest fails. The
    # flip happens in place: the archive and the signing block stay intact, so
    # the failure is a digest mismatch, not a truncated container.
    python3 - "$repo/2/app.apk" "$out_dir/HelloUpdate-v2-corrupted.apk" <<'PY'
import shutil
import struct
import sys

source, target = sys.argv[1], sys.argv[2]
shutil.copyfile(source, target)
with open(target, "r+b") as fh:
    data = fh.read()

# classes.dex's byte range comes from its central-directory record, so the
# flip always lands inside the signed content.
eocd = data.rfind(b"PK\x05\x06")
if eocd < 0:
    sys.exit("check-fixtures: no EOCD record")
cd = struct.unpack_from("<I", data, eocd + 16)[0]
while data[cd : cd + 4] == b"PK\x01\x02":
    compressed = struct.unpack_from("<I", data, cd + 20)[0]
    name_length, extra_length, comment_length = struct.unpack_from("<HHH", data, cd + 28)
    local_offset = struct.unpack_from("<I", data, cd + 42)[0]
    name = data[cd + 46 : cd + 46 + name_length]
    if name == b"classes.dex":
        local_name, local_extra = struct.unpack_from("<HH", data, local_offset + 26)
        start = local_offset + 30 + local_name + local_extra
        middle = start + compressed // 2
        break
    cd += 46 + name_length + extra_length + comment_length
else:
    sys.exit("check-fixtures: classes.dex not found")
with open(target, "r+b") as out:
    out.seek(middle)
    out.write(bytes([data[middle] ^ 0xFF]))
PY

    rm -rf "$work"
    printf 'build-fixtures: wrote the derived set to %s\n' "$out_dir"
}

if [[ "$mode" == "build" ]]; then
    if [[ "$app" == "HelloUpdate" ]]; then
        build_hello_update
        exit 0
    fi
    if [[ "$app" == "OtherInstaller" ]]; then
        # Its assets are the committed HelloUpdate V2 of the local update repo.
        build_hello_update
        gradle_build ":OtherInstaller:assembleRelease"
        verify_signer "$gradle_apk"
        mkdir -p "$(dirname "$output_apk")"
        cp "$gradle_apk" "$output_apk"
        printf 'build-fixtures: wrote %s\n' "$output_apk"
        exit 0
    fi
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
