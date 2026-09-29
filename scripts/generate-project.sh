#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tool-versions.env"

xcodegen="$repo_root/build/tools/xcodegen-$XCODEGEN_VERSION/bin/xcodegen"
if [[ ! -x "$xcodegen" ]]; then
    printf 'Pinned XcodeGen %s is missing. Run scripts/bootstrap first.\n' "$XCODEGEN_VERSION" >&2
    exit 1
fi

cd "$repo_root"
"$xcodegen" generate --spec "$repo_root/project.yml" --project "$repo_root"
