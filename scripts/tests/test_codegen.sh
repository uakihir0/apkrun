#!/usr/bin/env bash
# Checks that scripts/ci/codegen.sh fails on stale and uncommitted generated
# code. Each case runs the real codegen script in a disposable git repository
# that holds only the error-catalog generator and its inputs.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

generated_swift="Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/ErrorCatalog.generated.swift"
generated_markdown="docs/03-reference/error-catalog.md"

# make_fixture <name> <include-generated-swift: yes|no> <corrupt-generated-swift: yes|no>
make_fixture() {
    local name="$1"
    local include_swift="$2"
    local corrupt_swift="$3"
    local root="$temporary_root/$name"

    mkdir -p "$root/scripts/ci" "$root/Packages/DiagnosticsCore/ErrorCatalog" \
        "$root/$(dirname "$generated_swift")" "$root/docs/03-reference"
    cp -p "$repo_root/scripts/ci/codegen.sh" "$root/scripts/ci/codegen.sh"
    cp -p "$repo_root/scripts/errorgen.swift" "$root/scripts/errorgen.swift"
    cp -p "$repo_root/Packages/DiagnosticsCore/ErrorCatalog/errors.json" \
        "$root/Packages/DiagnosticsCore/ErrorCatalog/errors.json"
    cp -p "$repo_root/$generated_markdown" "$root/$generated_markdown"
    if [[ "$include_swift" == yes ]]; then
        cp -p "$repo_root/$generated_swift" "$root/$generated_swift"
        if [[ "$corrupt_swift" == yes ]]; then
            printf '// hand edit that no generator produced\n' >>"$root/$generated_swift"
        fi
    fi

    git -C "$root" init --quiet
    git -C "$root" add -A
    git -C "$root" -c user.name=codegen-fixture -c user.email=codegen-fixture@example.invalid \
        -c commit.gpgsign=false commit --quiet -m "fixture"
    printf '%s\n' "$root"
}

# run_codegen <root> <expected: pass|fail> <case-name> [<diagnostic>]
run_codegen() {
    local root="$1"
    local expected="$2"
    local name="$3"
    local diagnostic="${4:-}"
    local output="$temporary_root/$name.log"
    local status=0

    (cd "$root" && scripts/ci/codegen.sh) >"$output" 2>&1 || status=$?
    if [[ "$expected" == pass ]]; then
        if ((status != 0)); then
            cat "$output" >&2
            printf 'FAIL codegen %s: expected pass, exit %s\n' "$name" "$status" >&2
            exit 1
        fi
    else
        if ((status == 0)); then
            cat "$output" >&2
            printf 'FAIL codegen %s: expected failure, exit 0\n' "$name" >&2
            exit 1
        fi
        if [[ -n "$diagnostic" ]] && ! grep -Fq -- "$diagnostic" "$output"; then
            cat "$output" >&2
            printf 'FAIL codegen %s: expected diagnostic %s\n' "$name" "$diagnostic" >&2
            exit 1
        fi
    fi
    printf 'PASS codegen %s\n' "$name"
}

run_codegen "$(make_fixture committed yes no)" pass "committed outputs are up to date"
run_codegen "$(make_fixture stale yes yes)" fail "committed stale output" "$generated_swift"
run_codegen "$(make_fixture uncommitted no no)" fail "generated output never committed" "$generated_swift"

printf 'scripts/tests/test_codegen.sh: passed\n'
