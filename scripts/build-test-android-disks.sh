#!/usr/bin/env bash
# Builds the Android disks of android-image.md §4.2 for the T2 LinuxGuest disk-layout test.
#
# The disks go to $APKRUN_TEST_LINUX_DIR/android-disks (default
# /tmp/apkrun-test-linux/android-disks), outside ~/Documents so the signed test
# host can read them without a file-access prompt. Needs the pinned
# 16373615 archive under Images/work/16373615/download (python3 -m
# apkrun_image fetch) and the image-tools virtualenv.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_dir="${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}/android-disks"
python="$repo_root/Images/tools/.venv/bin/python"

if [[ ! -x "$python" ]]; then
    printf 'build-test-android-disks: create Images/tools/.venv first (environment-setup.md)\n' >&2
    exit 1
fi
cd "$repo_root"
PYTHONPATH="$repo_root/Images/tools" "$python" -m apkrun_image disks \
    --manifest Images/manifests/16373615/android-image.json \
    --out "$output_dir"
printf 'build-test-android-disks: built %s\n' "$output_dir"
