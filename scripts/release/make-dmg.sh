#!/usr/bin/env bash
# make-dmg.sh — builds APKRun-<version>.dmg from the signed bundle, signs
# the DMG with the same Developer ID, and when credentials are given,
# notarizes and staples it (build-system.md §12.6).
#
# Usage:
#   scripts/release/make-dmg.sh <APKRun.app> --version <v> \
#       --identity "Developer ID Application: …" [--out <dir>] \
#       [--notarize <notarize.sh credential args>]
set -euo pipefail

app="${1:?usage: make-dmg.sh <APKRun.app> --version <v> --identity <id> [--out <dir>] [--notarize ...]}"
shift

version=""
identity=""
out_dir="build/release"
notarize_args=()

while (($#)); do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --identity) identity="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --notarize)
            shift
            notarize_args=("$@")
            break
            ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

if [[ -z "$version" || -z "$identity" || ! -d "$app" ]]; then
    echo "usage: make-dmg.sh <APKRun.app> --version <v> --identity <id> [--out <dir>] [--notarize ...]" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$out_dir"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# A plain folder with the app and an /Applications link, like every Mac
# installer DMG.
staging="$work_dir/dmg-root"
mkdir -p "$staging"
cp -R "$app" "$staging/APKRun.app"
ln -s /Applications "$staging/Applications"

dmg="$out_dir/APKRun-$version.dmg"
rm -f "$dmg"
hdiutil create -format UDZO -volname "APKRun $version" \
    -srcfolder "$staging" -ov "$dmg"

# Developer ID DMG signature (not the bundle signature).
codesign --force --sign "$identity" --timestamp "$dmg"

if ((${#notarize_args[@]})); then
    "$script_dir/notarize.sh" "$dmg" "${notarize_args[@]}"
fi

echo "$dmg"
