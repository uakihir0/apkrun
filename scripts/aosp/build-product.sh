#!/bin/bash
# Builds the APKRun AOSP product image on the Linux builder
# (build-system.md §9, android-image.md §11, ADR-0020). Runs inside the
# builder container (environment-setup.md §5) with `repo`, `lunch`,
# `m`, and `sign_target_files_apks` on PATH and an AOSP checkout in
# $AOSP_ROOT.
#
#   build-product.sh --revision <commit> --variant userdebug|user \
#       [--aosp-root <tree>] [--keys-dir <dir>] [--out <dir>]
#       [--update-manifest] [--pin-manifest] [--skip-sync]
#
# Steps (build-system.md §9):
#   1. Syncs the tree to Guest/product/manifest/pinned.xml.
#   2. Writes .repo/local_manifests/apkrun.xml mapping this repository's
#      Guest/product/ to device/apkrun/apkrun_arm64/ and Guest/vsockd/
#      alongside it (Soong rejects `..` in srcs).
#   3. Runs scripts/build-guest.sh and copies the agent APKs to
#      Guest/product/prebuilt/ (git-ignored).
#   4. For `user` builds, runs scripts/check-sepolicy.sh first; then
#      lunches apkrun_arm64-trunk_staging-<variant>, `m`, and `m dist`
#      with BUILD_NUMBER=ar<counter>.
#   5. For `user` builds, signs the target files with the release keys
#      in --keys-dir and rebuilds the image zip.
#   6. Writes build-info.json next to the image zip.
#
# --pin-manifest writes Guest/product/manifest/pinned.xml from the
# current tree and stops; --update-manifest syncs to the tree's current
# revisions and rewrites pinned.xml instead of syncing to it.

set -euo pipefail

revision=""
variant=""
aosp_root="${AOSP_ROOT:-}"
keys_dir="${SIGNING_KEYS_DIR:-}"
out_dir=""
update_manifest=0
pin_manifest=0
skip_sync=0

usage() {
    cat >&2 <<'EOF'
usage: build-product.sh --revision <commit> --variant userdebug|user
    [--aosp-root <tree>] [--keys-dir <dir>] [--out <dir>]
    [--update-manifest] [--pin-manifest] [--skip-sync]
EOF
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --revision) revision="${2:-}"; shift 2 ;;
        --variant) variant="${2:-}"; shift 2 ;;
        --aosp-root) aosp_root="${2:-}"; shift 2 ;;
        --keys-dir) keys_dir="${2:-}"; shift 2 ;;
        --out) out_dir="${2:-}"; shift 2 ;;
        --update-manifest) update_manifest=1; shift ;;
        --pin-manifest) pin_manifest=1; shift ;;
        --skip-sync) skip_sync=1; shift ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

case "$variant" in
    userdebug|user) ;;
    *) printf 'build-product: --variant userdebug|user is required\n' >&2; usage ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
product_dir="$repo_root/Guest/product"
manifest="$product_dir/manifest/pinned.xml"

[[ -n "$aosp_root" && -d "$aosp_root/.repo" ]] || {
    printf 'build-product: an AOSP checkout is required (--aosp-root or AOSP_ROOT)\n' >&2
    exit 2
}

if [[ "$variant" == "user" && "$pin_manifest" -eq 0 ]]; then
    [[ -n "$keys_dir" && -d "$keys_dir" ]] || {
        printf 'build-product: a user build needs release keys (--keys-dir or SIGNING_KEYS_DIR)\n' >&2
        exit 2
    }
fi

log() { printf 'build-product: %s\n' "$*"; }

if [[ "$pin_manifest" -eq 1 ]]; then
    (cd "$aosp_root" && repo manifest -r -o "$manifest")
    log "wrote $manifest"
    exit 0
fi

if [[ "$update_manifest" -eq 0 && "$skip_sync" -eq 0 ]]; then
    [[ -f "$manifest" ]] || {
        printf 'build-product: %s is missing; run --pin-manifest on the builder (Guest/product/manifest/README.md)\n' "$manifest" >&2
        exit 2
    }
fi

# Step 1: sync the tree to the pinned manifest.
if [[ "$skip_sync" -eq 0 ]]; then
    if [[ "$update_manifest" -eq 1 ]]; then
        log "syncing to the tree's current revisions"
        (cd "$aosp_root" && repo sync)
        (cd "$aosp_root" && repo manifest -r -o "$manifest")
        log "wrote $manifest"
    else
        log "syncing to $(basename "$manifest")"
        (cd "$aosp_root" && repo sync)
        cp "$manifest" "$aosp_root/.repo/manifests/pinned.xml"
        (cd "$aosp_root" && repo init -m pinned.xml && repo sync)
    fi
fi

# Step 2: map this repository's product files into the tree.
[[ -n "$revision" ]] || { printf 'build-product: --revision <commit> is required\n' >&2; usage; }
if [[ ! -f "$repo_root/Guest/vsockd/Android.bp" ]]; then
    printf 'build-product: Guest/vsockd is missing; the product needs #36 (apkrun_vsockd)\n' >&2
    exit 2
fi
mkdir -p "$aosp_root/.repo/local_manifests"
cat > "$aosp_root/.repo/local_manifests/apkrun.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="apkrun-local" fetch="$(dirname "$repo_root")" />
  <project name="$(basename "$repo_root")"
           path="vendor/apkrun/src"
           revision="$revision"
           remote="apkrun-local">
    <linkfile src="Guest/product" dest="device/apkrun/apkrun_arm64" />
    <linkfile src="Guest/vsockd" dest="device/apkrun/apkrun_arm64/vsockd" />
  </project>
</manifest>
EOF
log "linked Guest/product to device/apkrun/apkrun_arm64 and Guest/vsockd at $revision"
(cd "$aosp_root" && repo sync vendor/apkrun/src)

product_tree="$aosp_root/vendor/apkrun/src/Guest/product"

# Step 3: build the agent APKs and copy them to prebuilt/.
mkdir -p "$product_tree/prebuilt"
"$repo_root/scripts/build-guest.sh"
cp "$repo_root/Guest/build/out/apkrun-guest.apk" "$product_tree/prebuilt/ApkRunGuest.apk"
(cd "$repo_root" && ./gradlew -p Guest :APKRunStore:assembleRelease -q)
store_apks=("$repo_root"/Guest/APKRunStore/build/outputs/apk/release/*.apk)
[[ "${#store_apks[@]}" -eq 1 ]] || {
    printf 'build-product: expected one APKRunStore release APK, found %s\n' "${#store_apks[@]}" >&2
    exit 2
}
cp "${store_apks[0]}" "$product_tree/prebuilt/ApkRunStore.apk"
log "staged ApkRunGuest.apk and ApkRunStore.apk in prebuilt/"

# R-13: a user build's SELinux inputs must be enforcing-only.
if [[ "$variant" == "user" ]]; then
    "$repo_root/scripts/check-sepolicy.sh" --variant user --root "$product_tree"
    [[ -f "$keys_dir/avb.pem" ]] || {
        printf 'build-product: %s/avb.pem is missing; a user image signs vbmeta with the AOSP test key otherwise\n' "$keys_dir" >&2
        exit 2
    }
fi

# Step 4: lunch, m, m dist.
build_number="ar${APKRUN_BUILD_COUNTER:-$(date +%Y%m%d)}"
log "lunch apkrun_arm64-trunk_staging-$variant (BUILD_NUMBER=$build_number)"
(
    cd "$aosp_root"
    # shellcheck disable=SC1091
    source build/envsetup.sh
    lunch "apkrun_arm64-trunk_staging-$variant"
    export BUILD_NUMBER="$build_number"
    if [[ "$variant" == "user" ]]; then
        # vbmeta is signed by avbtool during `m` with BOARD_AVB_KEY_PATH.
        export APKRUN_AVB_KEY_DIR="$keys_dir"
    fi
    m
    m dist
)

dist_dir="$aosp_root/out/dist"
target_files=("$dist_dir"/apkrun_arm64-target_files-"$build_number".zip)
[[ -f "${target_files[0]}" ]] || {
    printf 'build-product: target files %s missing after m dist\n' "${target_files[0]}" >&2
    exit 2
}

# Step 5: sign the target files with the release keys (user builds).
image_zip="$dist_dir/apkrun_arm64-img-$build_number.zip"
if [[ "$variant" == "user" ]]; then
    signed_tf="$dist_dir/apkrun_arm64-signed-target_files-$build_number.zip"
    (cd "$aosp_root" && sign_target_files_apks -d "$keys_dir" \
        "${target_files[0]}" "$signed_tf")
    (cd "$aosp_root" && img_from_target_files "$signed_tf" "$image_zip")
    # Fail closed: vbmeta must be signed by the release AVB key.
    work_avb="$(mktemp -d)"
    unzip -p "$image_zip" vbmeta.img > "$work_avb/vbmeta.img"
    avbtool="$aosp_root/external/avb/avbtool"
    [[ -f "$avbtool" ]] || avbtool="$aosp_root/external/avb/avbtool.py"
    python3 "$avbtool" extract_public_key --key "$keys_dir/avb.pem" \
        --output "$work_avb/avb_pub.bin"
    python3 "$avbtool" verify_image --image "$work_avb/vbmeta.img" \
        --expected_public_key "$work_avb/avb_pub.bin" || {
        printf 'build-product: vbmeta is not signed by %s/avb.pem\n' "$keys_dir" >&2
        exit 2
    }
    rm -rf "$work_avb"
    log "signed image zip: $image_zip"
else
    (cd "$aosp_root" && img_from_target_files "${target_files[0]}" "$image_zip")
fi

# Step 6: provenance.
[[ -n "$out_dir" ]] || out_dir="$dist_dir"
manifest_sha="$(shasum -a 256 "$manifest" | awk '{ print $1 }')"
guest_sha="$(shasum -a 256 "$product_tree/prebuilt/ApkRunGuest.apk" | awk '{ print $1 }')"
store_sha="$(shasum -a 256 "$product_tree/prebuilt/ApkRunStore.apk" | awk '{ print $1 }')"
container_digest="${APKRUN_CONTAINER_DIGEST:-unknown}"
cat > "$out_dir/build-info.json" <<EOF
{
  "buildNumber": "$build_number",
  "variant": "$variant",
  "apkrunRevision": "$revision",
  "manifestSha256": "$manifest_sha",
  "containerDigest": "$container_digest",
  "prebuiltApks": {
    "ApkRunGuest.apk": "$guest_sha",
    "ApkRunStore.apk": "$store_sha"
  }
}
EOF
log "wrote $out_dir/build-info.json; image: $image_zip"
