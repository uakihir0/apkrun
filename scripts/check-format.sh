#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fix=false

if [[ "${1:-}" == "--fix" ]]; then
    fix=true
    shift
fi
if (($# > 0)); then
    printf 'usage: scripts/check-format.sh [--fix]\n' >&2
    exit 2
fi

cd "$repo_root"
production_swift=()
test_swift=()
while IFS= read -r -d '' path; do
    case "$path" in
        */Generated/* | */ErrorCatalog.generated.swift | */fixtures/* | Tests/Fixtures/*)
            continue
            ;;
        */Tests/* | */UITests/* | Tests/*)
            test_swift+=("$path")
            ;;
        *)
            production_swift+=("$path")
            ;;
    esac
done < <(find Apps Daemon CLI Packages Tests scripts -type f -name '*.swift' -print0)

if [[ "$fix" == true ]]; then
    if ((${#production_swift[@]} > 0)); then
        xcrun swift-format format --in-place --configuration .swift-format "${production_swift[@]}"
    fi
    if ((${#test_swift[@]} > 0)); then
        xcrun swift-format format --in-place --configuration .swift-format-tests "${test_swift[@]}"
    fi
else
    if ((${#production_swift[@]} > 0)); then
        xcrun swift-format lint --strict --configuration .swift-format "${production_swift[@]}"
    fi
    if ((${#test_swift[@]} > 0)); then
        xcrun swift-format lint --strict --configuration .swift-format-tests "${test_swift[@]}"
    fi
fi

if [[ -n "$(find Guest -type f \( -name '*.kt' -o -name '*.kts' \) -print -quit)" ]]; then
    if [[ "$fix" == true ]]; then
        if [[ -x "$repo_root/gradlew" ]]; then
            "$repo_root/gradlew" -p Guest ktfmtFormat
        else
            printf 'check-format: Guest exists but gradlew is missing\n' >&2
            exit 1
        fi
    elif [[ -x "$repo_root/gradlew" ]]; then
        "$repo_root/gradlew" -p Guest ktfmtCheck
    else
        printf 'check-format: Guest exists but gradlew is missing\n' >&2
        exit 1
    fi
else
    printf 'check-format: skip (Guest Kotlin sources not present)\n'
fi

if [[ -n "$(find Guest/vsockd -type f -name '*.rs' -print -quit 2>/dev/null || true)" ]]; then
    if [[ "$fix" == true ]]; then
        cargo fmt --manifest-path Guest/vsockd/Cargo.toml
    else
        cargo fmt --manifest-path Guest/vsockd/Cargo.toml --check
    fi
else
    printf 'check-format: skip (Guest/vsockd Rust sources not present)\n'
fi

if [[ -n "$(find Images/tools -type f -name '*.py' -print -quit 2>/dev/null || true)" ]]; then
    if [[ "$fix" == true ]]; then
        ruff format Images/tools
    else
        ruff format --check Images/tools
    fi
else
    printf 'check-format: skip (Images/tools Python sources not present)\n'
fi

printf 'check-format: passed\n'
