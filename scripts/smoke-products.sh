#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: scripts/smoke-products.sh <build-products-directory>\n' >&2
    exit 64
fi

products_dir="$1"
app="$products_dir/APKRun.app"
cli="$app/Contents/Resources/bin/apkrun"
daemon="$products_dir/apkrund"
menu_bar="$app/Contents/Library/LoginItems/APKRunMenuBar.app"
launcher="$app/Contents/Helpers/APKRunLauncher.app"

for path in "$app" "$cli" "$daemon" "$menu_bar" "$launcher"; do
    if [[ ! -e "$path" ]]; then
        printf 'Missing expected build product: %s\n' "$path" >&2
        exit 1
    fi
done

menu_bar_agent="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$menu_bar/Contents/Info.plist")"
if [[ "$menu_bar_agent" != "true" ]]; then
    printf 'APKRunMenuBar must be configured as an LSUIElement agent\n' >&2
    exit 1
fi

cli_signature="$(/usr/bin/codesign --display --verbose=4 "$cli" 2>&1)"
if [[ "$cli_signature" != *"Identifier=io.apkrun.cli.dev"* ]]; then
    printf 'Debug CLI has an unexpected code-signing identifier\n' >&2
    exit 1
fi
cli_entitlements="$(/usr/bin/codesign --display --entitlements :- "$cli" 2>/dev/null)"
if [[ "$cli_entitlements" != *"<key>com.apple.security.virtualization</key>"* ]]; then
    printf 'Debug CLI is missing the virtualization entitlement\n' >&2
    exit 1
fi
printf 'ok Debug CLI identifier and virtualization entitlement\n'

version_output="$("$cli" version)"
if [[ "$version_output" != "apkrun 0.1.0 (1)" ]]; then
    printf 'Unexpected apkrun version output: %s\n' "$version_output" >&2
    exit 1
fi

json_output="$("$cli" version --json)"
if [[ "$json_output" != '{"schemaVersion":1,"result":{"cli":{"version":"0.1.0","build":"1"}}}' ]]; then
    printf 'Unexpected apkrun JSON output: %s\n' "$json_output" >&2
    exit 1
fi

if [[ "$("$cli" --version)" != "0.1.0" ]]; then
    printf 'apkrun --version returned an unexpected value\n' >&2
    exit 1
fi

if ! "$cli" --help | grep -Fq 'version'; then
    printf 'apkrun --help did not list the version command\n' >&2
    exit 1
fi
printf 'ok apkrun version, JSON, --version, and --help\n'

launch_and_quit() {
    local application="$1"
    local process_name="$2"
    local expected_bundle_id="$3"
    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$application/Contents/Info.plist")"
    if [[ "$bundle_id" != "$expected_bundle_id" ]]; then
        printf 'Unexpected bundle identifier for %s: %s\n' "$application" "$bundle_id" >&2
        return 1
    fi

    open -n "$application"
    local app_started=0
    for _ in $(seq 1 100); do
        if pgrep -x "$process_name" >/dev/null 2>&1; then
            app_started=1
            break
        fi
        sleep 0.1
    done
    if [[ "$app_started" -ne 1 ]]; then
        printf '%s did not launch within 10 seconds\n' "$process_name" >&2
        return 1
    fi

    osascript -e "tell application id \"$bundle_id\" to quit"
    local app_stopped=0
    for _ in $(seq 1 100); do
        if ! pgrep -x "$process_name" >/dev/null 2>&1; then
            app_stopped=1
            break
        fi
        sleep 0.1
    done
    if [[ "$app_stopped" -ne 1 ]]; then
        printf '%s did not quit within 10 seconds\n' "$process_name" >&2
        return 1
    fi
    printf 'ok %s launch and quit\n' "$process_name"
}

launch_and_quit "$app" APKRun io.apkrun.APKRun.dev
launch_and_quit "$menu_bar" APKRunMenuBar io.apkrun.APKRunMenuBar.dev
launch_and_quit "$launcher" APKRunLauncher io.apkrun.APKRunLauncher.dev

if [[ "$("$daemon" --version)" != "apkrund 0.1.0 (1)" ]]; then
    printf 'apkrund --version returned an unexpected value\n' >&2
    exit 1
fi
"$daemon" &
daemon_pid=$!
sleep 1
kill -TERM "$daemon_pid"
(
    sleep 10
    kill -KILL "$daemon_pid" 2>/dev/null || true
) &
watchdog_pid=$!
if wait "$daemon_pid"; then
    daemon_status=0
else
    daemon_status=$?
fi
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
if [[ "$daemon_status" -ne 0 ]]; then
    printf 'apkrund did not exit cleanly after SIGTERM (status %s)\n' "$daemon_status" >&2
    exit 1
fi
printf 'ok apkrund clean SIGTERM exit\n'
