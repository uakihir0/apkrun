#!/usr/bin/env bash

set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
configuration="${CONFIGURATION:-Debug}"
target_build_dir="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
wrapper_name="${WRAPPER_NAME:-APKRun.app}"
template="$repo_root/Daemon/apkrund/LaunchAgent.plist.in"

case "$configuration" in
    Debug)
        label="io.apkrun.apkrund.dev"
        mach_service="io.apkrun.apkrund.dev.xpc"
        app_bundle_identifier="io.apkrun.APKRun.dev"
        ;;
    Release)
        label="io.apkrun.apkrund"
        mach_service="io.apkrun.apkrund.xpc"
        app_bundle_identifier="io.apkrun.APKRun"
        ;;
    *)
        printf 'Unsupported LaunchAgent build configuration: %s\n' "$configuration" >&2
        exit 64
        ;;
esac

destination_directory="$target_build_dir/$wrapper_name/Contents/Library/LaunchAgents"
destination="$destination_directory/$label.plist"
temporary_file=""
trap 'if [[ -n "$temporary_file" ]]; then rm -f "$temporary_file"; fi' EXIT

if [[ ! -f "$template" ]]; then
    printf 'LaunchAgent template is missing: %s\n' "$template" >&2
    exit 1
fi

mkdir -p "$destination_directory"
temporary_file="$(mktemp "$destination_directory/.launch-agent.XXXXXX")"
sed \
    -e "s|@LAUNCH_AGENT_LABEL@|$label|g" \
    -e "s|@MACH_SERVICE_NAME@|$mach_service|g" \
    -e "s|@APP_BUNDLE_IDENTIFIER@|$app_bundle_identifier|g" \
    "$template" >"$temporary_file"

if rg -q '@[A-Z_]+@' "$temporary_file"; then
    printf 'LaunchAgent template contains an unresolved placeholder.\n' >&2
    exit 1
fi
if ! plutil -lint "$temporary_file" >/dev/null; then
    printf 'Generated LaunchAgent plist is invalid: %s\n' "$temporary_file" >&2
    exit 1
fi

chmod 0644 "$temporary_file"
mv -f "$temporary_file" "$destination"
temporary_file=""
