#!/usr/bin/env bash
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
guest_source="$repo_root/Guest/build/out"
wrapper_directory="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
guest_destination="$wrapper_directory/Contents/Resources/guest"
configuration="${CONFIGURATION:-Debug}"
artifacts=(apkrun-guest.apk apkrun-guest.json)

for destination_component in \
    "$wrapper_directory" \
    "$wrapper_directory/Contents" \
    "$wrapper_directory/Contents/Resources" \
    "$guest_destination"
do
    if [[ -L "$destination_component" ]]; then
        printf 'Refusing symlinked Guest Agent destination: %s\n' "$destination_component" >&2
        exit 1
    fi
done

case "$configuration" in
    Debug)
        ;;
    Release)
        rm -rf "$guest_destination"
        exit 0
        ;;
    *)
        printf 'Unsupported build configuration for Guest Agent bundle: %s\n' "$configuration" >&2
        exit 1
        ;;
esac

for artifact in "${artifacts[@]}"; do
    source_file="$guest_source/$artifact"
    if [[ ! -f "$source_file" || -L "$source_file" ]]; then
        printf 'Verified Guest Agent artifact is missing %s; run scripts/build-guest.sh.\n' \
            "$source_file" >&2
        exit 1
    fi
done

rm -rf "$guest_destination"
mkdir -p "$guest_destination"
for artifact in "${artifacts[@]}"; do
    cp -p "$guest_source/$artifact" "$guest_destination/$artifact"
done
