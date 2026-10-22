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
grep -q 'CMDLINE_TOOLS_SHA256=' "$aosp_dir/builder.Dockerfile"
grep -q 'REPO_LAUNCHER_SHA256=' "$aosp_dir/builder.Dockerfile"
grep -q 'libc6-dev-i386' "$aosp_dir/builder.Dockerfile"
grep -q 'repo sync -c -j' "$aosp_dir/build-product.sh"
grep -q 'for-each-ref --contains' "$aosp_dir/remote-build.sh"
grep -q 'APKRUN_BUILDER_IMAGE_DIGEST' "$aosp_dir/build-product.sh"
grep -q 'status --porcelain --untracked-files=all' "$aosp_dir/build-product.sh"
grep -q 'APKRUN_BUILD_NUMBER=%s' "$aosp_dir/build-product.sh"
grep -q 'scripts/build-guest.sh" --for-aosp' "$aosp_dir/build-product.sh"
grep -q 'Guest/product/prebuilt/ApkRunGuest.apk' "$aosp_dir/build-product.sh"
grep -q 'check-sepolicy.sh' "$aosp_dir/build-product.sh"
grep -q -- '-PapkrunPersistentAgent=true' "$repo_root/scripts/build-guest.sh"
grep -q 'apk_name="ApkRunGuest.apk"' "$repo_root/scripts/build-guest.sh"
expect_status 64 "build-guest-rejects-aosp-output-override" \
    "$repo_root/scripts/build-guest.sh" --for-aosp --out "$temporary_root/custom"

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
