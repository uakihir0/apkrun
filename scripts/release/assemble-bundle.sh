#!/usr/bin/env bash
# assemble-bundle.sh — builds the Release APKRun.app and, when a Developer
# ID is given, signs it inside out with sign-bundle.sh (build-system.md
# §11–§12.3). Prints the bundle path as the last line.
#
# Usage:
#   scripts/release/assemble-bundle.sh --build <n> [--channel beta] \
#       [--developer-id "Developer ID Application: …"] \
#       [--derived-data <dir>] [--result-bundle <path>]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

build=""
channel="stable"
developer_id=""
derived_data="build/ReleaseDerivedData"
result_bundle=""

while (($#)); do
    case "$1" in
        --build) build="$2"; shift 2 ;;
        --channel) channel="$2"; shift 2 ;;
        --developer-id) developer_id="$2"; shift 2 ;;
        --derived-data) derived_data="$2"; shift 2 ;;
        --result-bundle) result_bundle="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

if [[ -z "$build" ]]; then
    echo "usage: assemble-bundle.sh --build <n> [options]" >&2
    exit 64
fi

scripts/generate-project.sh

xcode_args=(
    -project APKRun.xcodeproj -scheme APKRun
    -configuration Release -jobs 2
    -derivedDataPath "$derived_data"
    CURRENT_PROJECT_VERSION="$build"
    APKRUN_CHANNEL="$channel"
    build
)
if [[ -n "$result_bundle" ]]; then
    xcode_args=(-resultBundlePath "$result_bundle" "${xcode_args[@]}")
fi

# CODE_SIGNING_ALLOWED=NO builds unsigned; a Developer ID runs the same
# inside-out signing the release uses, so signing problems surface here.
if [[ -n "$developer_id" ]]; then
    xcodebuild "${xcode_args[@]}" CODE_SIGN_IDENTITY=-
else
    xcodebuild "${xcode_args[@]}" CODE_SIGNING_ALLOWED=NO
fi

app="$derived_data/Build/Products/Release/APKRun.app"
if [[ ! -d "$app" ]]; then
    echo "assemble-bundle: APKRun.app missing at $app" >&2
    exit 66
fi

if [[ -n "$developer_id" ]]; then
    scripts/release/sign-bundle.sh "$app" "$developer_id"
fi

echo "$app"
