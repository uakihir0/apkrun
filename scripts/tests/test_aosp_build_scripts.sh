#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
aosp_dir="$repo_root/scripts/aosp"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

revision="$(git -C "$repo_root" rev-parse HEAD)"

expect_status() {
    local expected="$1"
    local name="$2"
    shift 2
    local output="$temporary_root/$name.log"
    local actual=0
    "$@" >"$output" 2>&1 || actual=$?
    if [[ "$actual" -ne "$expected" ]]; then
        cat "$output" >&2
        printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi
}

"$aosp_dir/build-product.sh" --help >/dev/null
"$aosp_dir/remote-build.sh" --help >/dev/null
expect_status 64 "build-rejects-short-revision" \
    "$aosp_dir/build-product.sh" --revision deadbeef --variant userdebug
expect_status 64 "build-rejects-invalid-variant" \
    "$aosp_dir/build-product.sh" --revision "$revision" --variant release
expect_status 78 "build-blocks-unresolved-user-signing" \
    "$aosp_dir/build-product.sh" --revision "$revision" --variant user
expect_status 64 "remote-rejects-short-revision" \
    "$aosp_dir/remote-build.sh" --revision deadbeef --variant userdebug
expect_status 64 "remote-rejects-invalid-variant" \
    "$aosp_dir/remote-build.sh" --revision "$revision" --variant release
expect_status 78 "remote-blocks-unresolved-user-signing" \
    "$aosp_dir/remote-build.sh" --revision "$revision" --variant user
expect_status 78 "remote-requires-configured-builder" \
    env APKRUN_AOSP_BUILDER= "$aosp_dir/remote-build.sh" --revision "$revision" --variant userdebug
expect_status 78 "remote-rejects-builder-shell-syntax" \
    env 'APKRUN_AOSP_BUILDER=user@builder;touch /tmp/apkrun-aosp-injection' \
    "$aosp_dir/remote-build.sh" --revision "$revision" --variant userdebug
[[ ! -e /tmp/apkrun-aosp-injection ]] || {
    printf 'FAIL remote-rejects-builder-shell-syntax: ran injected command\n' >&2
    exit 1
}

grep -q 'ubuntu:22.04@sha256:' "$aosp_dir/builder.Dockerfile"
grep -q 'ARG UBUNTU_SNAPSHOT=20261020T000000Z' "$aosp_dir/builder.Dockerfile"
grep -q 'https://snapshot.ubuntu.com/ubuntu/' "$aosp_dir/builder.Dockerfile"
grep -q 'Acquire::Check-Valid-Until=false update' "$aosp_dir/builder.Dockerfile"
grep -q 'CMDLINE_TOOLS_SHA256=' "$aosp_dir/builder.Dockerfile"
grep -q 'REPO_LAUNCHER_SHA256=' "$aosp_dir/builder.Dockerfile"
grep -q 'libc6-dev-i386' "$aosp_dir/builder.Dockerfile"
grep -q 'repo sync -c -j' "$aosp_dir/build-product.sh"
grep -q 'for-each-ref --contains' "$aosp_dir/remote-build.sh"
grep -q 'verify-build-info.py' "$aosp_dir/remote-build.sh"
literal_dollar='$'
grep -Fq "rm -- ${literal_dollar}remote_archive_path ${literal_dollar}remote_info_path" \
    "$aosp_dir/remote-build.sh"
grep -q -- '--build-info %s/build-info.json' "$aosp_dir/remote-build.sh"
grep -q -- '--source %s --out' "$aosp_dir/remote-build.sh"
grep -q 'published_archive=.*archive_name' "$aosp_dir/remote-build.sh"
grep -q 'could not publish build-info.json' "$aosp_dir/remote-build.sh"
grep -q 'could not remove partial archive' "$aosp_dir/remote-build.sh"
grep -q 'APKRUN_BUILDER_IMAGE_DIGEST' "$aosp_dir/build-product.sh"
grep -q 'status --porcelain --untracked-files=all' "$aosp_dir/build-product.sh"
grep -q 'APKRUN_BUILD_NUMBER=%s' "$aosp_dir/build-product.sh"
grep -q 'scripts/build-guest.sh" --for-aosp' "$aosp_dir/build-product.sh"
grep -q 'Guest/product/prebuilt/ApkRunGuest.apk' "$aosp_dir/build-product.sh"
grep -q 'check-sepolicy.sh' "$aosp_dir/build-product.sh"
grep -q 'write-build-info.py' "$aosp_dir/build-product.sh"
grep -q -- '-PapkrunPersistentAgent=true' "$repo_root/scripts/build-guest.sh"
grep -q 'apk_name="ApkRunGuest.apk"' "$repo_root/scripts/build-guest.sh"
expect_status 64 "build-guest-rejects-aosp-output-override" \
    "$repo_root/scripts/build-guest.sh" --for-aosp --out "$temporary_root/custom"

archive="$temporary_root/apkrun_arm64-img-ar000123.zip"
printf 'fixture AOSP archive\n' >"$archive"
guest_metadata="$temporary_root/ApkRunGuest.json"
cat >"$guest_metadata" <<'JSON'
{
  "packageName": "io.apkrun.guest",
  "versionCode": 1000,
  "versionName": "0.3.0+fixture"
}
JSON
build_info="$temporary_root/build-info.json"
python3 "$aosp_dir/write-build-info.py" \
    --archive "$archive" \
    --guest-metadata "$guest_metadata" \
    --out "$build_info" \
    --revision "$revision" \
    --variant userdebug \
    --build-number ar000123 \
    --pinned-manifest-sha256 "$(printf 'a%.0s' {1..64})" \
    --builder-image-digest "sha256:$(printf 'b%.0s' {1..64})" \
    --guest-apk-sha256 "$(printf 'c%.0s' {1..64})"
python3 - "$archive" "$build_info" <<'PY'
import hashlib
import json
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
info = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert info["schemaVersion"] == 1
assert info["buildNumber"] == "ar000123"
assert info["branch"] == "aosp-android-latest-release"
assert info["target"] == "apkrun_arm64-trunk_staging-userdebug"
assert info["agents"]["guest"]["versionCode"] == 1000
assert info["archive"] == {
    "name": archive.name,
    "size": archive.stat().st_size,
    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
}
PY
transfer_archive="$temporary_root/.apkrun-image.transfer"
cp "$archive" "$transfer_archive"
python3 "$aosp_dir/verify-build-info.py" \
    --archive "$transfer_archive" \
    --build-info "$build_info" \
    --revision "$revision" \
    --variant userdebug \
    --build-number ar000123
invalid_build_info="$temporary_root/invalid-build-info.json"
python3 - "$build_info" "$invalid_build_info" <<'PY'
import json
import pathlib
import sys

info = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
info["archive"]["sha256"] = "0" * 64
pathlib.Path(sys.argv[2]).write_text(json.dumps(info), encoding="utf-8")
PY
expect_status 1 "build-info-verifier-rejects-archive-mismatch" \
    python3 "$aosp_dir/verify-build-info.py" \
    --archive "$archive" \
    --build-info "$invalid_build_info" \
    --revision "$revision" \
    --variant userdebug \
    --build-number ar000123
unknown_build_info="$temporary_root/unknown-build-info.json"
python3 - "$build_info" "$unknown_build_info" <<'PY'
import json
import pathlib
import sys

info = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
info["agents"]["guest"]["unexpected"] = True
pathlib.Path(sys.argv[2]).write_text(json.dumps(info), encoding="utf-8")
PY
expect_status 1 "build-info-verifier-rejects-unknown-fields" \
    python3 "$aosp_dir/verify-build-info.py" \
    --archive "$transfer_archive" \
    --build-info "$unknown_build_info" \
    --revision "$revision" \
    --variant userdebug \
    --build-number ar000123
duplicate_build_info="$temporary_root/duplicate-build-info.json"
python3 - "$build_info" "$duplicate_build_info" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
needle = '  "schemaVersion": 1,'
assert source.count(needle) == 1
pathlib.Path(sys.argv[2]).write_text(
    source.replace(needle, needle + '\n  "schemaVersion": 1,', 1),
    encoding="utf-8",
)
PY
expect_status 1 "build-info-verifier-rejects-duplicate-keys" \
    python3 "$aosp_dir/verify-build-info.py" \
    --archive "$transfer_archive" \
    --build-info "$duplicate_build_info" \
    --revision "$revision" \
    --variant userdebug \
    --build-number ar000123
expect_status 1 "build-info-rejects-archive-build-number-mismatch" \
    python3 "$aosp_dir/write-build-info.py" \
    --archive "$archive" \
    --guest-metadata "$guest_metadata" \
    --out "$temporary_root/invalid-build-info.json" \
    --revision "$revision" \
    --variant userdebug \
    --build-number ar000124 \
    --pinned-manifest-sha256 "$(printf 'a%.0s' {1..64})" \
    --builder-image-digest "sha256:$(printf 'b%.0s' {1..64})" \
    --guest-apk-sha256 "$(printf 'c%.0s' {1..64})"
invalid_guest_metadata="$temporary_root/invalid-guest-metadata.json"
printf '{"packageName":"io.apkrun.guest","versionCode":0}\n' >"$invalid_guest_metadata"
expect_status 1 "build-info-rejects-invalid-guest-version-code" \
    python3 "$aosp_dir/write-build-info.py" \
    --archive "$archive" \
    --guest-metadata "$invalid_guest_metadata" \
    --out "$temporary_root/invalid-guest-build-info.json" \
    --revision "$revision" \
    --variant userdebug \
    --build-number ar000123 \
    --pinned-manifest-sha256 "$(printf 'a%.0s' {1..64})" \
    --builder-image-digest "sha256:$(printf 'b%.0s' {1..64})" \
    --guest-apk-sha256 "$(printf 'c%.0s' {1..64})"

cat >"$temporary_root/pinned.xml" <<'XML'
<manifest>
  <default revision="refs/heads/moving-default"/>
  <project name="platform/build" revision="0123456789abcdef0123456789abcdef01234567"/>
</manifest>
XML
manifest_digest="$(python3 "$aosp_dir/validate-manifest.py" "$temporary_root/pinned.xml")"
[[ "$manifest_digest" =~ ^[0-9a-f]{64}$ ]] || {
    printf 'FAIL validate-manifest: expected a SHA-256 digest\n' >&2
    exit 1
}
cat >"$temporary_root/unpinned.xml" <<'XML'
<manifest>
  <default revision="refs/heads/moving-default"/>
  <project name="platform/build"/>
</manifest>
XML
expect_status 1 "manifest-rejects-moving-project-revision" \
    python3 "$aosp_dir/validate-manifest.py" "$temporary_root/unpinned.xml"

printf 'scripts/tests/test_aosp_build_scripts.sh: passed\n'
