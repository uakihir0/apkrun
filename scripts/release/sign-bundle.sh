#!/bin/bash

# sign-bundle.sh <APKRun.app> <identity>
#
# Signs APKRun.app inside out (build-system.md §12.3): every nested
# binary first, the outer bundle last, never with --deep. Fails if any
# Mach-O file in the bundle is left unsigned.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <APKRun.app> <signing identity>" >&2
    exit 64
fi

app="${1%/}"
identity="$2"
contents="$app/Contents"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -d "$app" ]]; then
    echo "not an app bundle: $app" >&2
    exit 66
fi

opts=(--force --sign "$identity" --options runtime --timestamp)

sign() {
    local target="$1"
    shift
    if [[ ! -e "$target" ]]; then
        echo "expected component is missing: $target" >&2
        exit 66
    fi
    echo "signing $target"
    codesign "${opts[@]}" "$@" "$target"
}

# --- Nested code, deepest first ---

sparkle="$contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
    # Sparkle 2.10 nested code, in the order Sparkle documents. The
    # Downloader XPC keeps its own entitlements.
    sparkle_b="$sparkle/Versions/B"
    [[ -d "$sparkle_b/XPCServices/Installer.xpc" ]] && \
        sign "$sparkle_b/XPCServices/Installer.xpc"
    [[ -d "$sparkle_b/XPCServices/Downloader.xpc" ]] && \
        sign "$sparkle_b/XPCServices/Downloader.xpc" \
            --preserve-metadata=entitlements
    [[ -f "$sparkle_b/Autoupdate" ]] && sign "$sparkle_b/Autoupdate"
    [[ -d "$sparkle_b/Updater.app" ]] && sign "$sparkle_b/Updater.app"
    sign "$sparkle"
fi

if [[ -d "$contents/Frameworks/VirGLRuntime" ]]; then
    while IFS= read -r -d '' dylib; do
        sign "$dylib" --identifier "io.apkrun.virgl.$(basename "$dylib")"
    done < <(find "$contents/Frameworks/VirGLRuntime" -name '*.dylib' -print0)
fi

[[ -f "$contents/Resources/tools/aapt2" ]] && \
    sign "$contents/Resources/tools/aapt2" --identifier io.apkrun.aapt2
[[ -f "$contents/Resources/bin/apkrun" ]] && \
    sign "$contents/Resources/bin/apkrun" --identifier io.apkrun.cli
[[ -f "$contents/Helpers/apkrund" ]] && \
    sign "$contents/Helpers/apkrund" --identifier io.apkrun.apkrund \
        --entitlements "$repo_root/Daemon/apkrund/apkrund.entitlements"
[[ -d "$contents/Helpers/APKRunLauncher.app" ]] && \
    sign "$contents/Helpers/APKRunLauncher.app"
[[ -d "$contents/Library/LoginItems/APKRunMenuBar.app" ]] && \
    sign "$contents/Library/LoginItems/APKRunMenuBar.app"

# --- Outer bundle last ---

sign "$app" --entitlements "$repo_root/Apps/APKRun/APKRun.entitlements"

# --- Verify: every Mach-O file must carry a signature ---

unsigned=0
while IFS= read -r -d '' mach_o; do
    if ! codesign --verify "$mach_o" 2>/dev/null; then
        echo "unsigned Mach-O: $mach_o" >&2
        unsigned=1
    fi
done < <(find "$app" -type f -exec file {} + \
    | awk -F: '$2 ~ /Mach-O/ { print $1 }' | tr '\n' '\0')

if [[ $unsigned -ne 0 ]]; then
    exit 65
fi

codesign --verify --strict --deep --verbose=2 "$app"
echo "signed and verified: $app"
