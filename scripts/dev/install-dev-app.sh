#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

usage() {
    printf 'Usage: scripts/dev/install-dev-app.sh [Debug-APKRun.app]\n' >&2
    printf 'Default source: %s/build/Build/Products/Debug/APKRun.app\n' "$repo_root" >&2
    printf 'Override the build products directory with APKRUN_BUILD_PRODUCTS_DIR.\n' >&2
}

if (($# > 1)); then
    usage
    exit 64
fi

build_products_dir="${APKRUN_BUILD_PRODUCTS_DIR:-$repo_root/build/Build/Products/Debug}"
source_app="${1:-$build_products_dir/APKRun.app}"
while [[ "$source_app" != "/" && "$source_app" == */ ]]; do
    source_app="${source_app%/}"
done
source_parent="$(cd -P "$(dirname "$source_app")" 2>/dev/null && pwd -P)" || {
    printf 'Debug APKRun.app parent directory does not exist: %s\n' "$(dirname "$source_app")" >&2
    exit 1
}
source_app="$source_parent/$(basename "$source_app")"

if [[ -L "$source_app" ]]; then
    printf 'Refusing to install through a symlink: %s\n' "$source_app" >&2
    exit 1
fi
if [[ ! -d "$source_app" ]]; then
    printf 'Debug APKRun.app was not found: %s\n' "$source_app" >&2
    exit 1
fi

home_directory="${HOME:?HOME is required}"
home_directory="$(cd -P "$home_directory" 2>/dev/null && pwd -P)" || {
    printf 'Home directory does not exist: %s\n' "${HOME:-}" >&2
    exit 1
}
applications_directory="$home_directory/Applications"
if [[ -L "$applications_directory" ]]; then
    printf 'Refusing to install through a symlinked Applications directory: %s\n' "$applications_directory" >&2
    exit 1
fi
mkdir -p "$applications_directory"
if [[ ! -d "$applications_directory" ]]; then
    printf 'Applications path is not a directory: %s\n' "$applications_directory" >&2
    exit 1
fi

destination="$applications_directory/APKRun Dev.app"
local_directory="$home_directory/.local"
local_bin="$local_directory/bin"
cli_link="$local_bin/apkrun-dev"
if [[ -L "$local_directory" || -L "$local_bin" ]]; then
    printf 'Refusing to write through a symlinked local bin directory: %s\n' "$local_bin" >&2
    exit 1
fi
if [[ -e "$local_directory" && ! -d "$local_directory" ]]; then
    printf 'Local tools path is not a directory: %s\n' "$local_directory" >&2
    exit 1
fi
mkdir -p "$local_bin"
if [[ -e "$local_bin" && ! -d "$local_bin" ]]; then
    printf 'Local tools path is not a directory: %s\n' "$local_bin" >&2
    exit 1
fi

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

validate_debug_app() {
    local app="$1"
    local info_plist="$app/Contents/Info.plist"
    local bundle_identifier
    local build_identity
    local configuration
    local executable_name
    local launch_agent_name
    local launch_agent_plist
    local launch_agent_label
    local mach_service
    local associated_bundle_identifier
    local cli="$app/Contents/Resources/bin/apkrun"

    if [[ ! -f "$info_plist" ]]; then
        printf 'APKRun app is missing Contents/Info.plist: %s\n' "$app" >&2
        return 1
    fi
    bundle_identifier="$(plist_value "$info_plist" CFBundleIdentifier)" || return 1
    build_identity="$(plist_value "$info_plist" APKRunBuildIdentity)" || return 1
    configuration="$(plist_value "$info_plist" APKRunConfiguration)" || return 1
    executable_name="$(plist_value "$info_plist" CFBundleExecutable)" || return 1
    launch_agent_name="$(plist_value "$info_plist" APKRunLaunchAgentPlistName)" || return 1
    launch_agent_plist="$app/Contents/Library/LaunchAgents/$launch_agent_name"

    if [[ "$bundle_identifier" != "io.apkrun.APKRun.dev" ||
        "$build_identity" != "dev" ||
        "$configuration" != "Debug" ]]; then
        printf 'Refusing non-Debug APKRun.app (bundle=%s identity=%s configuration=%s): %s\n' \
            "$bundle_identifier" "$build_identity" "$configuration" "$app" >&2
        return 1
    fi
    if [[ "$executable_name" != "APKRun" ||
        "$launch_agent_name" != "io.apkrun.apkrund.dev.plist" ]]; then
        printf 'Debug APKRun.app has unexpected executable or LaunchAgent identity: %s\n' "$app" >&2
        return 1
    fi
    if [[ -L "$app/Contents/MacOS/$executable_name" ||
        ! -x "$app/Contents/MacOS/$executable_name" ]]; then
        printf 'APKRun app executable is missing or not executable: %s\n' \
            "$app/Contents/MacOS/$executable_name" >&2
        return 1
    fi
    if [[ -L "$cli" || ! -x "$cli" ]]; then
        printf 'Embedded Debug CLI is missing or not executable: %s\n' "$cli" >&2
        return 1
    fi
    if [[ -L "$launch_agent_plist" || ! -f "$launch_agent_plist" ]]; then
        printf 'Embedded Debug LaunchAgent plist is missing: %s\n' \
            "$launch_agent_plist" >&2
        return 1
    fi
    if ! plutil -lint "$launch_agent_plist" >/dev/null; then
        printf 'Embedded Debug LaunchAgent plist is invalid: %s\n' \
            "$launch_agent_plist" >&2
        return 1
    fi
    launch_agent_label="$(plist_value "$launch_agent_plist" Label)" || return 1
    mach_service="$(plist_value "$launch_agent_plist" 'MachServices:io.apkrun.apkrund.dev.xpc')" || return 1
    associated_bundle_identifier="$(plist_value "$launch_agent_plist" 'AssociatedBundleIdentifiers:0')" || return 1
    if [[ "$launch_agent_label" != "io.apkrun.apkrund.dev" ||
        "$mach_service" != "true" ||
        "$associated_bundle_identifier" != "io.apkrun.APKRun.dev" ]]; then
        printf 'Debug APKRun.app LaunchAgent has unexpected identity: %s\n' "$launch_agent_plist" >&2
        return 1
    fi
}

validate_debug_app "$source_app" || exit 1
if [[ -L "$destination" ]]; then
    printf 'Refusing to replace a symlink at the development app path: %s\n' "$destination" >&2
    exit 1
fi
if [[ -e "$destination" ]]; then
    if [[ ! -d "$destination" ]]; then
        printf 'Refusing to replace a non-directory at the development app path: %s\n' "$destination" >&2
        exit 1
    fi
    validate_debug_app "$destination" || {
        printf 'Existing path is not an APKRun development app; leaving it untouched: %s\n' "$destination" >&2
        exit 1
    }
fi
if [[ -e "$cli_link" || -L "$cli_link" ]]; then
    if [[ ! -L "$cli_link" || "$(readlink "$cli_link")" != "$destination/Contents/Resources/bin/apkrun" ]]; then
        printf 'Refusing to replace an unmanaged apkrun-dev path: %s\n' "$cli_link" >&2
        exit 1
    fi
fi

same_destination=false
if [[ "$source_app" == "$destination" ]]; then
    same_destination=true
fi

staging_root=""
backup_root=""
backup_app=""
new_app_installed=false
cli_link_created=false
cleanup() {
    local exit_status=$?
    if [[ "$exit_status" -ne 0 ]]; then
        if [[ "$new_app_installed" == true && ( -e "$destination" || -L "$destination" ) ]]; then
            rm -rf "$destination"
        fi
        if [[ -n "$backup_app" && -e "$backup_app" ]]; then
            if [[ ! -e "$destination" && ! -L "$destination" ]]; then
                mv "$backup_app" "$destination" || \
                    printf 'Could not restore the previous app; it remains at %s\n' "$backup_app" >&2
            else
                printf 'Could not restore the previous app; it remains at %s\n' "$backup_app" >&2
            fi
        fi
        if [[ "$cli_link_created" == true &&
            -L "$cli_link" &&
            "$(readlink "$cli_link")" == "$destination/Contents/Resources/bin/apkrun" ]]; then
            rm -f "$cli_link"
        fi
    fi
    if [[ -n "$staging_root" && -d "$staging_root" ]]; then
        rm -rf "$staging_root"
    fi
    if [[ -n "$backup_root" && -d "$backup_root" && ! -e "$backup_app" ]]; then
        rmdir "$backup_root" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ "$same_destination" != true ]]; then
    staging_root="$(mktemp -d "$applications_directory/.APKRun Dev.app.installing.XXXXXX")"
    staged_app="$staging_root/APKRun Dev.app"
    /usr/bin/ditto "$source_app" "$staged_app"
    validate_debug_app "$staged_app"

    if [[ -e "$destination" ]]; then
        backup_root="$(mktemp -d "$applications_directory/.APKRun Dev.app.backup.XXXXXX")"
        backup_app="$backup_root/Previous APKRun Dev.app"
        mv "$destination" "$backup_app"
    fi
    if ! mv "$staged_app" "$destination"; then
        printf 'Could not move the Debug app into place: %s\n' "$destination" >&2
        exit 1
    fi
    new_app_installed=true
fi

if [[ ! -e "$cli_link" && ! -L "$cli_link" ]]; then
    ln -s "$destination/Contents/Resources/bin/apkrun" "$cli_link"
    cli_link_created=true
fi

if "$destination/Contents/MacOS/APKRun" --register-runtime; then
    :
else
    registration_status=$?
    printf 'APKRun runtime registration failed with status %s\n' "$registration_status" >&2
    exit "$registration_status"
fi

if [[ -n "$backup_app" && -e "$backup_app" ]]; then
    rm -rf "$backup_app"
fi
if [[ -n "$backup_root" && -d "$backup_root" ]]; then
    rmdir "$backup_root" 2>/dev/null || true
fi
backup_app=""
backup_root=""
printf 'Installed Debug APKRun.app at %s\n' "$destination"
printf 'Registered the development LaunchAgent; CLI link: %s\n' "$cli_link"
