#!/usr/bin/env bash
# Build the test-only policy editor of #23 from the pinned libsepol 3.11 release tarball.
#
# The tarball is the GitHub release asset libsepol-3.11.tar.gz of SELinuxProject/selinux, tag 3.11.
# Its sha256 is pinned in ThirdParty/ThirdParty.lock.json (component libsepol). The script refuses
# any other file. It builds in a new directory under /tmp and writes nothing in the repository.
set -euo pipefail

readonly PINNED_SHA256="79f3d2c88f44b7eb5cf54d9792e03232297e17f97a179163f2750099a00f164d"
readonly VERSION="3.11"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only the input tarball can be chosen; the build directories are fixed, because the script deletes them.
tarball="${APKRUN_SEPOL_TARBALL:-/tmp/apkrun-022-sepol-dl/libsepol-$VERSION.tar.gz}"
work=/tmp/apkrun-022-sepol-src
out=/tmp/apkrun-022-sepol-bin

if [[ ! -f "$tarball" ]]; then
    echo "build-libsepol: $tarball is missing; download the release asset from GitHub first" >&2
    exit 1
fi
actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
if [[ "$actual" != "$PINNED_SHA256" ]]; then
    echo "build-libsepol: sha256 of $tarball is $actual, not the pinned $PINNED_SHA256" >&2
    exit 1
fi

rm -rf "$work" "$out"
mkdir -p "$work" "$out"
tar -xzf "$tarball" -C "$work"
src="$work/libsepol-$VERSION"
(
    cd "$src/src"
    make libsepol.a DISABLE_CIL=y -j8 CFLAGS="-O2"
)
clang -O2 -Wall -Wextra -Wno-unused-parameter -I "$src/include" \
    -o "$out/policy-edit" "$script_dir/policy_edit.c" "$src/src/libsepol.a"
cp "$src/LICENSE" "$out/LICENSE.libsepol"
shasum -a 256 "$out/policy-edit"
echo "built $out/policy-edit from libsepol $VERSION ($PINNED_SHA256)"
