#!/usr/bin/env bash
# Builds and signs the development bundle of build 16373615 for the T2 Android tests and G2.
#
# The bundle goes to $APKRUN_TEST_LINUX_DIR/android-bundle (default
# /tmp/apkrun-test-linux/android-bundle), outside ~/Documents so the signed test
# host can read it without a file-access prompt. It is signed with the developer
# image key, which a Debug build trusts (runtime-image-manifest.md §6.1). Create the
# key once with `python3 -m apkrun_image keygen --out ~/.config/apkrun/dev-image-key`,
# or point APKRUN_DEV_IMAGE_KEY at another key. Needs the pinned archive under
# Images/work/16373615/download and the image-tools virtualenv.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_dir="${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}/android-bundle"
python="$repo_root/Images/tools/.venv/bin/python"
sign_key="${APKRUN_DEV_IMAGE_KEY:-$HOME/.config/apkrun/dev-image-key}"

if [[ ! -x "$python" ]]; then
    printf 'build-test-android-bundle: create Images/tools/.venv first (environment-setup.md)\n' >&2
    exit 1
fi
if [[ ! -f "$sign_key" ]]; then
    printf 'build-test-android-bundle: no signing key at %s; run: python3 -m apkrun_image keygen --out %s\n' "$sign_key" "$sign_key" >&2
    exit 1
fi
cd "$repo_root"
PYTHONPATH="$repo_root/Images/tools" "$python" -m apkrun_image bundle \
    --manifest Images/manifests/16373615/android-image.json \
    --reference Images/reference/16373615/incomplete/default-20261001T120904-49816 \
    --image-version 2026.10.0 \
    --sign-key "$sign_key" \
    --out "$output_dir"
printf 'build-test-android-bundle: built %s\n' "$output_dir"
