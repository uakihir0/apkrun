#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
installer="$repo_root/scripts/dev/install-dev-app.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

make_debug_app() {
    local app="$1"
    local marker="${2:-fixture}"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" \
        "$app/Contents/Library/LaunchAgents"
    cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>io.apkrun.APKRun.dev</string>
	<key>CFBundleExecutable</key>
	<string>APKRun</string>
	<key>APKRunBuildIdentity</key>
	<string>dev</string>
	<key>APKRunConfiguration</key>
	<string>Debug</string>
	<key>APKRunLaunchAgentPlistName</key>
	<string>io.apkrun.apkrund.dev.plist</string>
</dict>
</plist>
PLIST
cat >"$app/Contents/Library/LaunchAgents/io.apkrun.apkrund.dev.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>io.apkrun.apkrund.dev</string>
	<key>MachServices</key>
	<dict><key>io.apkrun.apkrund.dev.xpc</key><true/></dict>
	<key>AssociatedBundleIdentifiers</key>
	<array><string>io.apkrun.APKRun.dev</string></array>
</dict>
</plist>
PLIST
    cat >"$app/Contents/MacOS/APKRun" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$APKRUN_REGISTRATION_LOG"
exit "${APKRUN_REGISTER_EXIT:-0}"
SH
    chmod +x "$app/Contents/MacOS/APKRun"
    printf '%s\n' "$marker" >"$app/Contents/Resources/marker"
    cat >"$app/Contents/Resources/bin/apkrun" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$app/Contents/Resources/bin/apkrun"
}

expect_failure() {
    local output="$1"
    shift
    if "$@" >"$output" 2>&1; then
        cat "$output" >&2
        printf 'Expected command to fail: %s\n' "$*" >&2
        exit 1
    fi
}

test_root="$temporary_root/normal"
build_products_dir="$test_root/build/Build/Products/Debug"
mkdir -p "$test_root/home" "$build_products_dir"
source_app="$build_products_dir/APKRun.app"
make_debug_app "$source_app" first
registration_log="$test_root/registration.log"

HOME="$test_root/home" \
    APKRUN_BUILD_PRODUCTS_DIR="$build_products_dir" \
    APKRUN_REGISTRATION_LOG="$registration_log" \
    "$installer"

installed_app="$test_root/home/Applications/APKRun Dev.app"
[[ -d "$installed_app" && ! -L "$installed_app" ]]
[[ "$(cat "$installed_app/Contents/Resources/marker")" == first ]]
[[ "$(cat "$registration_log")" == --register-runtime ]]
[[ "$(readlink "$test_root/home/.local/bin/apkrun-dev")" == \
    "$installed_app/Contents/Resources/bin/apkrun" ]]

symlink_source="$test_root/source/Symlink APKRun.app"
mkdir -p "$test_root/source"
ln -s "$source_app" "$symlink_source"
expect_failure "$test_root/source-symlink.log" \
    env HOME="$test_root/home" APKRUN_REGISTRATION_LOG="$registration_log" \
    "$installer" "$symlink_source"
[[ "$(cat "$installed_app/Contents/Resources/marker")" == first ]]

release_root="$temporary_root/release-protection"
mkdir -p "$release_root/home/Applications" "$release_root/source"
release_app="$release_root/home/Applications/APKRun Dev.app"
make_debug_app "$release_root/source/APKRun Debug.app" candidate
make_debug_app "$release_app" protected
sed -i '' 's/io.apkrun.APKRun.dev/io.apkrun.APKRun/' "$release_app/Contents/Info.plist"
expect_failure "$release_root/release.log" \
    env HOME="$release_root/home" APKRUN_REGISTRATION_LOG="$registration_log" \
    "$installer" "$release_root/source/APKRun Debug.app"
[[ "$(cat "$release_app/Contents/Resources/marker")" == protected ]]

rollback_root="$temporary_root/rollback"
mkdir -p "$rollback_root/home/Applications" "$rollback_root/source"
rollback_source="$rollback_root/source/APKRun Debug.app"
rollback_destination="$rollback_root/home/Applications/APKRun Dev.app"
make_debug_app "$rollback_source" replacement
make_debug_app "$rollback_destination" original
expect_failure "$rollback_root/failure.log" \
    env HOME="$rollback_root/home" \
    APKRUN_REGISTRATION_LOG="$rollback_root/register-arguments.txt" \
    APKRUN_REGISTER_EXIT=23 \
    "$installer" "$rollback_source"
[[ "$(cat "$rollback_destination/Contents/Resources/marker")" == original ]]
[[ ! -e "$rollback_root/home/.local/bin/apkrun-dev" ]]

symlink_destination_root="$temporary_root/destination-symlink"
mkdir -p "$symlink_destination_root/home/Applications" "$symlink_destination_root/source"
make_debug_app "$symlink_destination_root/source/APKRun Debug.app"
protected_path="$symlink_destination_root/protected"
mkdir -p "$protected_path"
printf 'keep\n' >"$protected_path/marker"
ln -s "$protected_path" "$symlink_destination_root/home/Applications/APKRun Dev.app"
expect_failure "$symlink_destination_root/symlink.log" \
    env HOME="$symlink_destination_root/home" \
    APKRUN_REGISTRATION_LOG="$registration_log" \
    "$installer" "$symlink_destination_root/source/APKRun Debug.app"
[[ "$(cat "$protected_path/marker")" == keep ]]

printf 'scripts/tests/test_install_dev_app.sh: passed\n'
