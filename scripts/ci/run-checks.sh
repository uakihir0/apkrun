#!/usr/bin/env bash
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

checks=(
    "scripts/tests/run.sh"
    "scripts/check-module-deps.sh"
)
if [[ -f "$repo_root/scripts/check-logging.sh" ]]; then
    checks+=("scripts/check-logging.sh")
fi
checks+=(
    "scripts/check-todos.sh"
    "scripts/check-format.sh"
    "scripts/check-lock.sh"
    "scripts/check-protos.sh"
)

names=()
statuses=()
failures=0
for check in "${checks[@]}"; do
    if [[ ! -x "$repo_root/$check" ]]; then
        printf 'run-checks: missing or non-executable check: %s\n' "$check" >&2
        names+=("$check")
        statuses+=("missing")
        failures=$((failures + 1))
        continue
    fi

    printf '\n==> %s\n' "$check"
    if "$repo_root/$check"; then
        names+=("$check")
        statuses+=("passed")
    else
        status=$?
        names+=("$check")
        statuses+=("failed ($status)")
        failures=$((failures + 1))
    fi
done

printf '\nCheck summary:\n'
for index in "${!names[@]}"; do
    printf '  %s: %s\n' "${names[$index]}" "${statuses[$index]}"
done

if ((failures > 0)); then
    printf 'run-checks: %d check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'run-checks: all checks passed\n'
