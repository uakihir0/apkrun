#!/bin/bash

set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
output="$repo_root/build/generated/BuildStamp.h"

commit="$(git -C "$repo_root" rev-parse --short=7 HEAD)"
if [[ ! "$commit" =~ ^[0-9a-f]{7}$ ]]; then
    printf 'Could not determine a seven-character Git revision.\n' >&2
    exit 1
fi

if ! git -C "$repo_root" diff-index --quiet HEAD -- \
    || [[ -n "$(git -C "$repo_root" ls-files --others --exclude-standard)" ]]; then
    commit="${commit}-dirty"
fi

mkdir -p "$(dirname "$output")"
temporary="$output.tmp.$$"
trap 'rm -f "$temporary"' EXIT
printf '#define APKRUN_GIT_COMMIT %s\n' "$commit" > "$temporary"

if ! cmp -s "$temporary" "$output"; then
    mv "$temporary" "$output"
fi
