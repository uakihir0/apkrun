#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

generators=0
if [[ -f scripts/errorgen.swift ]]; then
    swift scripts/errorgen.swift
    swift scripts/errorgen.swift --markdown
    generators=$((generators + 1))
fi
if [[ -x scripts/generate-protos.sh ]]; then
    scripts/generate-protos.sh
    generators=$((generators + 1))
fi
if [[ -x scripts/generate-project.sh ]]; then
    scripts/generate-project.sh
    generators=$((generators + 1))
fi
if ((generators == 0)); then
    printf 'codegen: no generators from build-system.md §4 are present\n' >&2
    exit 1
fi

git diff --exit-code
git diff --cached --exit-code
printf 'codegen: generated files are up to date\n'
