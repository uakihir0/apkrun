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
        CONFIGURATION="${configuration:-Debug}" \
        bash "$fixture_root/scripts/build/embed-guest.sh"
}

configuration=Debug
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

rm -f "$guest_destination"
resources_destination="$build_root/APKRun.app/Contents/Resources"
rm -rf "$resources_destination"
mkdir -p "$external_destination/guest"
printf 'preserve parent target\n' > "$external_destination/guest/marker"
ln -s "$external_destination" "$resources_destination"
configuration=Release
if output="$(run_embed 2>&1)"; then
    printf 'FAIL symlinked Guest Agent parent should fail\n' >&2
    exit 1
fi
[[ "$output" == *"Refusing symlinked Guest Agent destination"* ]]
[[ "$(cat "$external_destination/guest/marker")" == "preserve parent target" ]]
printf 'PASS symlinked Guest Agent parent protection\n'

rm -f "$resources_destination"
mkdir -p "$resources_destination"
rm -rf "$guest_destination"
mkdir -p "$guest_destination"
printf 'stale development APK\n' > "$guest_destination/apkrun-guest.apk"
run_embed
[[ ! -e "$guest_destination" ]]
printf 'PASS release build omits development Guest Agent bundle\n'

configuration=Profile
if output="$(run_embed 2>&1)"; then
    printf 'FAIL unsupported build configuration should fail\n' >&2
    exit 1
fi
[[ "$output" == *"Unsupported build configuration"* ]]
printf 'PASS unsupported build configuration diagnostic\n'
