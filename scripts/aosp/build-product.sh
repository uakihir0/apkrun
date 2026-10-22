#!/usr/bin/env bash
# Build the pinned APKRun AOSP product on the Linux x86_64 builder (#36).
set -euo pipefail

usage() {
    cat <<'USAGE'
usage: scripts/aosp/build-product.sh --revision <full-commit-sha> --variant userdebug|user

Run inside scripts/aosp/builder.Dockerfile. APKRUN_SOURCE_DIR identifies the
clean APKRun checkout at --revision; APKRUN_AOSP_ROOT defaults to ~/aosp.
USAGE
}

fail() {
    printf 'build-product: %s\n' "$1" >&2
    exit "${2:-1}"
}

revision=""
variant=""
while (($# > 0)); do
    case "$1" in
        --revision)
            (($# >= 2)) || { usage >&2; exit 64; }
            revision="$2"
            shift 2
            ;;
        --variant)
            (($# >= 2)) || { usage >&2; exit 64; }
            variant="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "--revision must be a full lowercase 40-character Git commit SHA" 64
[[ "$variant" == "userdebug" || "$variant" == "user" ]] || fail "--variant must be userdebug or user" 64
[[ "$variant" != "user" ]] \
    || fail "user builds are disabled until OQ-36 defines the release signing flow; use --variant userdebug" 78

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
source_root="${APKRUN_SOURCE_DIR:-$repo_root}"
aosp_root="${APKRUN_AOSP_ROOT:-$HOME/aosp}"
manifest_source="$source_root/Guest/product/manifest/pinned.xml"
build_image_digest="${APKRUN_BUILDER_IMAGE_DIGEST:-}"

[[ "$source_root" == /* && ! -L "$source_root" ]] \
    || fail "APKRUN_SOURCE_DIR must be an absolute, non-symlink checkout path"
[[ "$aosp_root" == /* ]] || fail "APKRUN_AOSP_ROOT must be absolute"
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] \
    || fail "AOSP builds require the Linux x86_64 builder container (environment-setup.md §5)"
[[ "$EUID" -ne 0 ]] || fail "run as an unprivileged builder user; AOSP rejects root builds"
[[ "$build_image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || fail "APKRUN_BUILDER_IMAGE_DIGEST must contain the inspected builder image digest"

actual_revision="$(git -C "$source_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || fail "APKRUN_SOURCE_DIR is not a Git checkout"
[[ "$actual_revision" == "$revision" ]] \
    || fail "APKRUN_SOURCE_DIR HEAD ($actual_revision) does not match --revision"
if [[ -n "$(git -C "$source_root" status --porcelain --untracked-files=all)" ]]; then
    fail "APKRUN_SOURCE_DIR has tracked changes or untracked files; build only a clean committed revision"
fi
git -C "$source_root" cat-file -e "${revision}^{commit}" 2>/dev/null \
    || fail "revision $revision is not present in APKRUN_SOURCE_DIR"

[[ -f "$manifest_source" && ! -L "$manifest_source" ]] \
    || fail "$manifest_source is missing; add the pinned repo manifest before building"
[[ -d "$source_root/Guest/product" ]] \
    || fail "$source_root/Guest/product is missing"
command -v repo >/dev/null 2>&1 || fail "the pinned repo launcher is not installed in the builder image"
command -v xmllint >/dev/null 2>&1 || fail "xmllint is missing; rebuild scripts/aosp/builder.Dockerfile"
command -v flock >/dev/null 2>&1 || fail "flock is missing; rebuild scripts/aosp/builder.Dockerfile"

manifest_sha256="$(python3 "$script_dir/validate-manifest.py" "$manifest_source")" \
    || fail "pinned manifest must be valid, self-contained XML with full commit SHA pins"
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "could not hash the pinned manifest"

origin_url="$(git -C "$source_root" config --get remote.origin.url 2>/dev/null)" \
    || fail "APKRUN_SOURCE_DIR has no origin remote"
read -r android_remote_fetch android_project_name < <(
    python3 - "$origin_url" <<'PY'
import re
import sys

url = sys.argv[1]
patterns = (
    (r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?", "https://github.com"),
    (r"git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?", "git@github.com:"),
)
for pattern, fetch in patterns:
    match = re.fullmatch(pattern, url)
    if match:
        print(fetch, "/".join(match.groups()))
        break
else:
    raise SystemExit("origin must be a credential-free GitHub HTTPS or SSH URL")
PY
) || fail "origin must be a credential-free GitHub HTTPS or SSH URL"

mkdir -p "$aosp_root"
[[ ! -L "$aosp_root" ]] || fail "APKRUN_AOSP_ROOT must not be a symlink"
cd "$aosp_root"
exec 9>"$aosp_root/.apkrun-build.lock"
flock -x 9

manifest_repo_url="https://android.googlesource.com/platform/manifest"
repo_client_url="https://gerrit.googlesource.com/git-repo"
repo_client_revision="${APKRUN_REPO_CLIENT_REVISION:-}"
[[ "$repo_client_revision" =~ ^[0-9a-f]{40}$ ]] \
    || fail "APKRUN_REPO_CLIENT_REVISION must be pinned in the builder image"
if [[ ! -d "$aosp_root/.repo" ]]; then
    repo init \
        -u "$manifest_repo_url" \
        -b aosp-android-latest-release \
        --partial-clone \
        --clone-filter=blob:limit=10M \
        --repo-url="$repo_client_url" \
        --repo-rev="$repo_client_revision"
fi

[[ -d "$aosp_root/.repo/manifests" ]] || fail "repo init did not create .repo/manifests"
install -m 0644 "$manifest_source" "$aosp_root/.repo/manifests/apkrun-pinned.xml"
repo init \
    -u "$manifest_repo_url" \
    -b aosp-android-latest-release \
    -m apkrun-pinned.xml \
    --partial-clone \
    --clone-filter=blob:limit=10M \
    --repo-url="$repo_client_url" \
    --repo-rev="$repo_client_revision"

local_manifest_dir="$aosp_root/.repo/local_manifests"
mkdir -p "$local_manifest_dir"
local_manifest_tmp="$(mktemp "$local_manifest_dir/.apkrun.XXXXXX")"
trap 'rm -f "$local_manifest_tmp"' EXIT
cat >"$local_manifest_tmp" <<MANIFEST
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="apkrun" fetch="$android_remote_fetch" />
  <project name="$android_project_name" path="external/apkrun-source" remote="apkrun" revision="$revision" />
</manifest>
MANIFEST
xmllint --noout "$local_manifest_tmp" || fail "generated APKRun local manifest is invalid XML"
install -m 0644 "$local_manifest_tmp" "$local_manifest_dir/apkrun.xml"
rm -f "$local_manifest_tmp"
trap - EXIT

jobs="${APKRUN_AOSP_JOBS:-$(nproc)}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "APKRUN_AOSP_JOBS must be a positive integer" 64
repo sync -c -j"$jobs" --no-tags

source_project="$aosp_root/external/apkrun-source"
synced_revision="$(git -C "$source_project" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || fail "repo sync did not create external/apkrun-source"
[[ "$synced_revision" == "$revision" ]] \
    || fail "repo sync checked out $synced_revision instead of requested $revision"

product_source="$source_project/Guest/product"
vsockd_source="$source_project/Guest/vsockd"
[[ -d "$product_source" && -d "$vsockd_source" ]] \
    || fail "revision $revision must contain Guest/product and Guest/vsockd"

guest_apk_source=""
if grep -R -q 'ApkRunGuest' "$product_source" --include='*.bp' --include='*.mk'; then
    "$source_root/scripts/build-guest.sh" --for-aosp
    guest_apk_source="$source_root/Guest/product/prebuilt/ApkRunGuest.apk"
    [[ -s "$guest_apk_source" && ! -L "$guest_apk_source" ]] \
        || fail "scripts/build-guest.sh --for-aosp did not produce Guest/product/prebuilt/ApkRunGuest.apk"
fi

product_parent="$aosp_root/device/apkrun"
product_dest="$product_parent/apkrun_arm64"
mkdir -p "$product_parent"
if [[ -e "$product_dest" ]]; then
    [[ ! -L "$product_dest" ]] || fail "$product_dest must not be a symlink"
    [[ -f "$product_dest/.apkrun-source-revision" ]] \
        || fail "$product_dest exists but is not managed by build-product.sh"
    recorded_revision="$(cat "$product_dest/.apkrun-source-revision")"
    [[ "$recorded_revision" =~ ^[0-9a-f]{40}$ ]] \
        || fail "$product_dest has an invalid APKRun source marker"
fi
product_stage="$(mktemp -d "$product_parent/.apkrun-arm64.XXXXXX")"
cleanup() {
    [[ -z "$product_stage" ]] || rm -rf "$product_stage"
    if [[ -n "${source_project:-}" && ( -e "$source_project/.git" || -L "$source_project/.git" ) ]]; then
        current_root="$(git -C "$source_project" rev-parse --show-toplevel 2>/dev/null || true)"
        [[ "$current_root" == "$source_project" && "$(git -C "$source_project" rev-parse HEAD 2>/dev/null || true)" == "$revision" ]] \
            && rm -rf "$source_project"
    fi
}
trap cleanup EXIT
cp -a "$product_source/." "$product_stage/"
mkdir -p "$product_stage/vsockd"
cp -a "$vsockd_source/." "$product_stage/vsockd/"
printf '%s\n' "$revision" >"$product_stage/.apkrun-source-revision"
if [[ -e "$product_dest" ]]; then
    rm -rf "$product_dest"
fi
mv "$product_stage" "$product_dest"
product_stage=""

guest_apk_sha256=""
if [[ -n "$guest_apk_source" ]]; then
    install -d -m 0755 "$product_dest/prebuilt"
    install -m 0644 "$guest_apk_source" "$product_dest/prebuilt/ApkRunGuest.apk"
    install -m 0644 "$source_root/Guest/product/prebuilt/ApkRunGuest.json" "$product_dest/prebuilt/ApkRunGuest.json"
    guest_apk_sha256="$(sha256sum "$product_dest/prebuilt/ApkRunGuest.apk" | awk '{print $1}')"
fi

# shellcheck disable=SC1091
source "$aosp_root/build/envsetup.sh"
lunch "apkrun_arm64-trunk_staging-$variant"

exec 8>"$aosp_root/.apkrun-build-counter.lock"
flock -x 8
counter_file="$aosp_root/build-counter"
counter=0
if [[ -f "$counter_file" ]]; then
    IFS= read -r counter <"$counter_file" || true
    [[ "$counter" =~ ^[0-9]+$ ]] || fail "$counter_file must contain a decimal counter"
fi
((counter < 999999)) || fail "build counter exhausted the six-digit arNNNNNN namespace"
counter=$((counter + 1))
build_number="$(printf 'ar%06d' "$counter")"
counter_tmp="$(mktemp "$aosp_root/.build-counter.XXXXXX")"
printf '%s\n' "$counter" >"$counter_tmp"
mv "$counter_tmp" "$counter_file"
flock -u 8

printf 'APKRUN_BUILD_NUMBER=%s\n' "$build_number"
export BUILD_NUMBER="$build_number"
m
"$source_root/scripts/check-sepolicy.sh" \
    "$variant" \
    "$aosp_root/out/target/product/apkrun_arm64/root/sepolicy" \
    "$aosp_root/out/host/linux-x86/bin/sepolicy-analyze"
m dist "DIST_DIR=$aosp_root/out/dist"

dist_archive="$aosp_root/out/dist/apkrun_arm64-img-$build_number.zip"
[[ -s "$dist_archive" && ! -L "$dist_archive" ]] \
    || fail "expected non-empty dist artifact $dist_archive"

output_dir="$source_root/Images/work/$build_number/download"
mkdir -p "$output_dir"
install -m 0644 "$dist_archive" "$output_dir/apkrun_arm64-img-$build_number.zip"
build_info="$output_dir/build-info.json"
cat >"$build_info" <<INFO
{
  "schemaVersion": 1,
  "buildNumber": "$build_number",
  "revision": "$revision",
  "variant": "$variant",
  "pinnedManifestSha256": "$manifest_sha256",
  "builderImageDigest": "$build_image_digest",
  "apkSha256": {
    "guest": "${guest_apk_sha256:-}"
  }
}
INFO
chmod 0644 "$build_info"
python3 -m json.tool "$build_info" >/dev/null || fail "generated build-info.json is invalid"
printf 'build-product: wrote %s\n' "$output_dir/apkrun_arm64-img-$build_number.zip"
printf 'build-product: wrote %s\n' "$build_info"
