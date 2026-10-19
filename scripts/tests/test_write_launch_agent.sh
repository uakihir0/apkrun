#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
writer="$repo_root/scripts/build/write-launch-agent.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

assert_plist_value() {
    local plist="$1"
    local key_path="$2"
    local expected="$3"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key_path" "$plist")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Expected %s in %s to be %s, got %s\n' "$key_path" "$plist" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_launch_agent() {
    local configuration="$1"
    local label="$2"
    local mach_service="$3"
    local app_bundle_identifier="$4"
    local output_root="$temporary_root/$configuration"
    local plist="$output_root/APKRun.app/Contents/Library/LaunchAgents/$label.plist"

    SRCROOT="$repo_root" \
        CONFIGURATION="$configuration" \
        TARGET_BUILD_DIR="$output_root" \
        WRAPPER_NAME=APKRun.app \
        "$writer"

    if [[ ! -f "$plist" ]]; then
        printf 'LaunchAgent writer did not create %s\n' "$plist" >&2
        exit 1
    fi
    plutil -lint "$plist" >/dev/null
    assert_plist_value "$plist" Label "$label"
    assert_plist_value "$plist" BundleProgram Contents/Helpers/apkrund
    assert_plist_value "$plist" "MachServices:$mach_service" true
    assert_plist_value "$plist" ProcessType Interactive
    assert_plist_value "$plist" KeepAlive:SuccessfulExit false
    assert_plist_value "$plist" RunAtLoad true
    assert_plist_value "$plist" StartInterval 3600
    assert_plist_value "$plist" ExitTimeOut 45
    assert_plist_value "$plist" "AssociatedBundleIdentifiers:0" "$app_bundle_identifier"
}

assert_launch_agent Debug io.apkrun.apkrund.dev io.apkrun.apkrund.dev.xpc io.apkrun.APKRun.dev
assert_launch_agent Release io.apkrun.apkrund io.apkrun.apkrund.xpc io.apkrun.APKRun
printf 'scripts/tests/test_write_launch_agent.sh: passed\n'
