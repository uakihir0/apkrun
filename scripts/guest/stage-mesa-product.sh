#!/usr/bin/env bash
# Verify the pinned NDK Mesa output and stage its four libraries for the AOSP
# product fragment under Guest/product/mesa (ADR-0018, #099).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
helper="$script_dir/mesa_android.py"
lock="$repo_root/ThirdParty/ThirdParty.lock.json"
out_dir="$repo_root/ThirdParty/out/mesa-android"
product_dir="$repo_root/Guest/product/mesa"
ndk_revision="28.2.13676358"
ndk="${ANDROID_NDK_HOME:-}"

usage() {
    printf 'usage: scripts/guest/stage-mesa-product.sh [--out DIR]\n' >&2
    exit 64
}

while (($# > 0)); do
    case "$1" in
        --out)
            (($# >= 2)) || usage
            out_dir="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "$ndk" ]]; then
    sdk_root="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    ndk="$sdk_root/ndk/$ndk_revision"
fi
ndk_bin="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin"
for tool in llvm-readelf llvm-nm; do
    [[ -x "$ndk_bin/$tool" ]] || {
        printf 'stage-mesa-product: pinned NDK tool is missing: %s\n' "$ndk_bin/$tool" >&2
        exit 1
    }
done
if ! grep -qxF "Pkg.Revision = $ndk_revision" "$ndk/source.properties"; then
    printf 'stage-mesa-product: expected NDK %s at %s\n' "$ndk_revision" "$ndk" >&2
    exit 1
fi

python_bin="$(command -v python3 || true)"
[[ -n "$python_bin" ]] || {
    printf 'stage-mesa-product: python3 is not on PATH\n' >&2
    exit 1
}
"$python_bin" "$helper" verify "$out_dir" --lock "$lock" \
    --readelf "$ndk_bin/llvm-readelf" --nm "$ndk_bin/llvm-nm"

mkdir -p "$product_dir"
staging_dir="$(mktemp -d "$product_dir/.prebuilt.XXXXXX")"
backup_dir="$product_dir/.prebuilt-old.$$"
cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

mkdir -p "$staging_dir/vendor/lib64"
for library in libEGL_mesa.so libGLESv2_mesa.so libGLESv1_CM_mesa.so libgallium_dri.so; do
    cp "$out_dir/vendor/lib64/$library" "$staging_dir/vendor/lib64/$library"
done
cp "$out_dir/manifest.json" "$staging_dir/manifest.json"
"$python_bin" "$helper" verify "$staging_dir" --lock "$lock" \
    --readelf "$ndk_bin/llvm-readelf" --nm "$ndk_bin/llvm-nm"

if [[ -e "$product_dir/prebuilt" ]]; then
    [[ ! -e "$backup_dir" ]] || {
        printf 'stage-mesa-product: refusing to replace existing backup %s\n' "$backup_dir" >&2
        exit 1
    }
    mv "$product_dir/prebuilt" "$backup_dir"
fi
if ! mv "$staging_dir" "$product_dir/prebuilt"; then
    [[ ! -e "$backup_dir" ]] || mv "$backup_dir" "$product_dir/prebuilt"
    exit 1
fi
staging_dir="$product_dir/.prebuilt.unused"
rm -rf "$backup_dir"
trap - EXIT
printf 'stage-mesa-product: staged four verified Mesa libraries in %s\n' "$product_dir/prebuilt"
