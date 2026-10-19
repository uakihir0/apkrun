#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

fixture_root="$temporary_root/repository"
build_root="$temporary_root/DerivedData"
guest_source="$fixture_root/Guest/build/out"
guest_destination="$build_root/APKRun.app/Contents/Resources/guest"
mkdir -p "$fixture_root/scripts/build" "$guest_source"
cp "$repo_root/scripts/build/embed-guest.sh" "$fixture_root/scripts/build/"
chmod +x "$fixture_root/scripts/build/embed-guest.sh"
printf 'fixture apk\n' > "$guest_source/apkrun-guest.apk"
printf '{"packageName":"io.apkrun.guest"}\n' > "$guest_source/apkrun-guest.json"

run_embed() {
    SRCROOT="$fixture_root" \
        TARGET_BUILD_DIR="$build_root" \
        WRAPPER_NAME="APKRun.app" \
        bash "$fixture_root/scripts/build/embed-guest.sh"
}

mkdir -p "$guest_destination"
printf 'stale\n' > "$guest_destination/stale.apk"
run_embed
[[ ! -e "$guest_destination/stale.apk" ]]
cmp "$guest_source/apkrun-guest.apk" "$guest_destination/apkrun-guest.apk"
cmp "$guest_source/apkrun-guest.json" "$guest_destination/apkrun-guest.json"
printf 'PASS Guest Agent bundle copy\n'

rm "$guest_source/apkrun-guest.json"
if output="$(run_embed 2>&1)"; then
    printf 'FAIL missing Guest Agent metadata should fail\n' >&2
    exit 1
fi
[[ "$output" == *"run scripts/build-guest.sh"* ]]
[[ -f "$guest_destination/apkrun-guest.apk" ]]
printf 'PASS missing Guest Agent artifact diagnostic\n'

external_destination="$temporary_root/external"
mkdir -p "$external_destination"
printf 'preserve\n' > "$external_destination/marker"
rm -rf "$guest_destination"
ln -s "$external_destination" "$guest_destination"
if output="$(run_embed 2>&1)"; then
    printf 'FAIL symlinked Guest Agent destination should fail\n' >&2
    exit 1
fi
[[ "$output" == *"Refusing symlinked Guest Agent destination"* ]]
[[ "$(cat "$external_destination/marker")" == "preserve" ]]
printf 'PASS symlinked Guest Agent destination protection\n'
