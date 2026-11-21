#!/usr/bin/env bash
set -euo pipefail

# CI builds the Guest Agent with the development key only. The Release check refuses test
# signing material in the bundle, so CI's Release build sets APKRUN_GUEST_EMBED=off and the
# phase is skipped. A real release signs the agent with the release key and never sets this.
if [[ "${APKRUN_GUEST_EMBED:-on}" == "off" ]]; then
    printf 'Guest Agent embed skipped (APKRUN_GUEST_EMBED=off).\n'
    exit 0
fi

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
guest_source="$repo_root/Guest/build/out"
guest_destination="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}/Contents/Resources/guest"
artifacts=(apkrun-guest.apk apkrun-guest.json)

for artifact in "${artifacts[@]}"; do
    source_file="$guest_source/$artifact"
    if [[ ! -f "$source_file" || -L "$source_file" ]]; then
        printf 'Verified Guest Agent artifact is missing %s; run scripts/build-guest.sh.\n' \
            "$source_file" >&2
        exit 1
    fi
done

if [[ -L "$guest_destination" ]]; then
    printf 'Refusing symlinked Guest Agent destination: %s\n' "$guest_destination" >&2
    exit 1
fi

rm -rf "$guest_destination"
mkdir -p "$guest_destination"
for artifact in "${artifacts[@]}"; do
    cp -p "$guest_source/$artifact" "$guest_destination/$artifact"
done
