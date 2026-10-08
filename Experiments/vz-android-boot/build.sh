#!/bin/bash
# Builds and ad-hoc signs the spike harness into <repo>/Images/work/vz-android-boot/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/Images/work/vz-android-boot"
mkdir -p "$out"
swiftc -O -o "$out/vz-android-boot" "$here/VZAndroidBoot.swift"
codesign --force --sign - --entitlements "$here/vz-android-boot.entitlements" "$out/vz-android-boot"
echo "$out/vz-android-boot"
