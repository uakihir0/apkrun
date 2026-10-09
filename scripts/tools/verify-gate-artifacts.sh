#!/usr/bin/env bash
# Checks that the test artifact directory holds what the gate's test plans read: the Linux kernel and
# initramfs, the Android disks of the layout test, and for G2 the Android bundle.
#
#   scripts/tools/verify-gate-artifacts.sh DIRECTORY G1|G2
#
# run-gate.sh runs this after it builds the artifacts and before it runs any test, so a missing file stops the
# gate with the file's name instead of as a failed test (IR-376).
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: scripts/tools/verify-gate-artifacts.sh DIRECTORY G1|G2\n' >&2
    exit 64
fi
directory="$1"
gate="$2"
if [[ "$gate" != G1 && "$gate" != G2 ]]; then
    printf 'verify-gate-artifacts: unsupported gate: %s\n' "$gate" >&2
    exit 64
fi

missing=()
require() {
    if [[ ! -f "$directory/$1" ]]; then
        missing+=("$1")
    fi
}

require Image
require initramfs.cpio.gz
require android-disks/disks.json
if [[ -f "$directory/android-disks/disks.json" ]]; then
    disk_files=$(python3 -I -c '
import json, sys
for disk in json.load(open(sys.argv[1], encoding="utf-8"))["disks"]:
    print(disk["file"])
' "$directory/android-disks/disks.json") || {
        printf 'verify-gate-artifacts: %s/android-disks/disks.json cannot be read\n' "$directory" >&2
        exit 1
    }
    while IFS= read -r name; do
        require "android-disks/$name"
    done <<< "$disk_files"
fi
if [[ "$gate" == G2 ]]; then
    require android-bundle/manifest.json
fi

if (( ${#missing[@]} > 0 )); then
    printf 'verify-gate-artifacts: %s is missing for %s: %s\n' "$directory" "$gate" "${missing[*]}" >&2
    printf 'verify-gate-artifacts: scripts/run-gate.sh builds these before the tests run; see IR-376\n' >&2
    exit 1
fi
printf 'verify-gate-artifacts: %s holds the %s artifacts\n' "$directory" "$gate"
