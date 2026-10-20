#!/usr/bin/env bash
# Build the eglInitialize test binary of #99 with the pinned NDK r28c.
#
# Usage: build-egl-test.sh <output file>
# The NDK is the one of ADR-0018 (revision 28.2.13676358, r28c), found under the Android SDK of the
# user (or $APKRUN_NDK). The script checks source.properties and writes only the output file.
set -euo pipefail

readonly NDK_REVISION="28.2.13676358"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ndk="${APKRUN_NDK:-$HOME/Library/Android/sdk/ndk/$NDK_REVISION}"
out="${1:?usage: build-egl-test.sh <output file>}"

grep -q "^Pkg.Revision = $NDK_REVISION\$" "$ndk/source.properties" \
    || { echo "build-egl-test: $ndk is not NDK $NDK_REVISION" >&2; exit 1; }
clang="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang"
[[ -x "$clang" ]] || { echo "build-egl-test: $clang is missing" >&2; exit 1; }

"$clang" -O2 -Wall -Wextra -fPIE -pie -o "$out" "$script_dir/apkrun_egl_test.c" -llog -lEGL
echo "built $out"
shasum -a 256 "$out"
