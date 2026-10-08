#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    printf 'check-compile-fail: run on an Apple silicon Mac\n' >&2
    exit 2
fi

cd "$repo_root"
swift build --configuration debug --target DiagnosticsCore
module_dir="$(swift build --configuration debug --show-bin-path)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

expect_compile_failure() {
    local fixture="$1"
    local diagnostic="$2"
    local output="$temporary_root/$(basename "$fixture").log"

    if swiftc -typecheck \
        -module-cache-path "$temporary_root/module-cache" \
        -I "$module_dir" \
        "$repo_root/$fixture" >"$output" 2>&1
    then
        printf 'FAIL %s: fixture unexpectedly compiled\n' "$fixture" >&2
        exit 1
    fi

    if ! grep -Fq -- "$diagnostic" "$output"; then
        cat "$output" >&2
        printf 'FAIL %s: expected diagnostic was not found\n' "$fixture" >&2
        exit 1
    fi
    printf 'PASS %s\n' "$fixture"
}

expect_compile_failure \
    "Tests/Fixtures/compile-fail/interpolation-without-privacy.swift" \
    "missing argument for parameter #2"
expect_compile_failure \
    "Tests/Fixtures/compile-fail/interpolated-sensitive-value.swift" \
    "Sensitive values must never be interpolated into log messages."
