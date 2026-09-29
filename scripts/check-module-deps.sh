#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/tool-versions.env"
xcodegen="$repo_root/build/tools/xcodegen-$XCODEGEN_VERSION/bin/xcodegen"
unset APKRUN_XCODEGEN
if [[ -x "$xcodegen" ]]; then
    export APKRUN_XCODEGEN="$xcodegen"
fi

exec swift "$repo_root/scripts/tools/check-module-deps.swift" --root "$repo_root" "$@"
