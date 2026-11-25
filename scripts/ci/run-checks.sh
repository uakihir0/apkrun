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
    "scripts/check-docs.sh"
    "scripts/check-compatibility-db.sh"
    "scripts/check-readback.sh"
    "scripts/check-sepolicy.sh"
    "scripts/check-raw-adb.sh"
    "scripts/check-strings.sh"
    "scripts/check-launcher.sh"
    "scripts/check-licenses.sh"
)
if [[ -f "$repo_root/scripts/check-fixtures.sh" ]]; then
    checks+=("scripts/check-fixtures.sh")
fi

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
    check_log="$(mktemp -t run-checks)"
    if "$repo_root/$check" 2>&1 | tee "$check_log"; then
        names+=("$check")
        statuses+=("passed")
    else
        status=${PIPESTATUS[0]}
        names+=("$check")
        statuses+=("failed ($status)")
        failures=$((failures + 1))
        # Surface the failure in the workflow annotations: job logs need a
        # signed-in viewer even for public repositories, annotations do not.
        printf '::error::%s failed with exit status %s\n' "$check" "$status"
        tail -n 15 "$check_log" | while IFS= read -r line; do
            line="${line//'%'/'%25'}"
            line="${line//$'\r'/}"
            printf '::error::%s\n' "$line"
        done
    fi
    rm -f "$check_log"
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
