#!/usr/bin/env bash
# Checks scripts/check-format.sh itself on a disposable tree. A badly formatted
# production source and a badly formatted test source must fail, the same
# sources formatted must pass, and a generated source must be skipped.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

root="$temporary_root/tree"
mkdir -p "$root/scripts" "$root/Apps" "$root/Daemon" "$root/CLI" "$root/Tests" \
    "$root/Packages/Fixture/Sources/Fixture/Generated" "$root/Packages/Fixture/Tests/FixtureTests"
cp -p "$repo_root/scripts/check-format.sh" "$root/scripts/check-format.sh"
cp -p "$repo_root/.swift-format" "$root/.swift-format"
cp -p "$repo_root/.swift-format-tests" "$root/.swift-format-tests"

production="$root/Packages/Fixture/Sources/Fixture/Fixture.swift"
test_source="$root/Packages/Fixture/Tests/FixtureTests/FixtureTests.swift"
generated="$root/Packages/Fixture/Sources/Fixture/Generated/Generated.swift"

# run_check <name> <expected: pass|fail> [<diagnostic>]
run_check() {
    local name="$1"
    local expected="$2"
    local diagnostic="${3:-}"
    local output="$temporary_root/$name.log"
    local status=0

    "$root/scripts/check-format.sh" >"$output" 2>&1 || status=$?
    if [[ "$expected" == pass ]]; then
        if ((status != 0)); then
            cat "$output" >&2
            printf 'FAIL check-format %s: expected pass, exit %s\n' "$name" "$status" >&2
            exit 1
        fi
    else
        if ((status == 0)); then
            cat "$output" >&2
            printf 'FAIL check-format %s: expected failure, exit 0\n' "$name" >&2
            exit 1
        fi
        if [[ -n "$diagnostic" ]] && ! grep -Fq -- "$diagnostic" "$output"; then
            cat "$output" >&2
            printf 'FAIL check-format %s: expected diagnostic %s\n' "$name" "$diagnostic" >&2
            exit 1
        fi
    fi
    printf 'PASS check-format %s\n' "$name"
}

printf 'let value=1\n' >"$production"
printf 'let value=2\n' >"$test_source"
printf 'let value=3\n' >"$generated"
run_check "rejects a badly formatted production source" fail "Fixture.swift"

printf 'let value = 1\n' >"$production"
run_check "rejects a badly formatted test source" fail "FixtureTests.swift"

printf 'let value = 2\n' >"$test_source"
run_check "skips generated sources" pass
printf 'let value = 1\n' >"$production"

printf 'scripts/tests/test_check_format.sh: passed\n'
