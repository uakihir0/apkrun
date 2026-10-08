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

# git diff cannot see an output that no commit tracks, so a generator output
# that was never committed would pass. Fail on any untracked output instead.
generated_outputs=(
    "Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/ErrorCatalog.generated.swift"
    "docs/03-reference/error-catalog.md"
    "Packages/GuestProtocol/Sources/GuestProtocol/Generated"
)
uncommitted_outputs="$(git ls-files --others --exclude-standard -- "${generated_outputs[@]}")"
if [[ -n "$uncommitted_outputs" ]]; then
    printf 'codegen: generated files are not committed; commit these outputs:\n%s\n' \
        "$uncommitted_outputs" >&2
    exit 1
fi
printf 'codegen: generated files are up to date\n'
