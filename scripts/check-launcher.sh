#!/bin/bash

set -euo pipefail

usage() {
    printf 'Usage: %s <APKRunLauncher.app>\n' "${0##*/}" >&2
    exit 64
}

[[ $# -eq 1 ]] || usage

app_path="${1%/}"
info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || {
    printf 'Launcher bundle Info.plist not found: %s\n' "$info_plist" >&2
    exit 1
}

executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
executable="$app_path/Contents/MacOS/$executable_name"
[[ -f "$executable" ]] || {
    printf 'Launcher executable not found: %s\n' "$executable" >&2
    exit 1
}

architectures="$(/usr/bin/lipo -archs "$executable")"
[[ "$architectures" == "arm64" ]] || {
    printf 'Expected an arm64-only launcher; found: %s\n' "$architectures" >&2
    exit 1
}

minimum_os="$(/usr/bin/otool -l "$executable" | /usr/bin/awk '
    /cmd LC_BUILD_VERSION/ { in_build_version = 1; next }
    in_build_version && $1 == "minos" { print $2; exit }
')"
[[ "$minimum_os" == "27.0" ]] || {
    printf 'Expected launcher minimum macOS 27.0; found: %s\n' "${minimum_os:-unknown}" >&2
    exit 1
}

unexpected_dependencies="$(/usr/bin/otool -L "$executable" | /usr/bin/tail -n +2 | /usr/bin/awk '
    {
        path = $1
        if (path !~ /^\/System\/Library\// && path !~ /^\/usr\/lib\//) {
            print path
        }
    }
')"
[[ -z "$unexpected_dependencies" ]] || {
    printf 'Launcher links non-system libraries:\n%s\n' "$unexpected_dependencies" >&2
    exit 1
}

printf 'Launcher check passed: arm64, macOS %s minimum, system frameworks only.\n' "$minimum_os"
