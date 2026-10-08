#!/usr/bin/env bash
# Checks that scripts/ci/run-checks.sh runs every scripts/check-*.sh script of
# build-system.md §3. A check that is missing from the runner would pass in
# lint without ever running, so each one must be registered there.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

# Checks that are not part of lint: check-compile-fail.sh is the manual T1
# compiler-failure check of build-system.md §12.
manual_checks=(check-compile-fail.sh)

# unregistered_checks <root>: prints each scripts/check-*.sh that the runner in
# <root> does not register and that is not a manual check.
unregistered_checks() {
    local root="$1"
    local path name
    shopt -s nullglob
    for path in "$root"/scripts/check-*.sh; do
        name="$(basename "$path")"
        local manual=0
        for entry in "${manual_checks[@]}"; do
            if [[ "$entry" == "$name" ]]; then
                manual=1
            fi
        done
        if ((manual == 0)) && ! grep -Fq -- "scripts/$name" "$root/scripts/ci/run-checks.sh"; then
            printf '%s\n' "$name"
        fi
    done
    shopt -u nullglob
}

missing="$(unregistered_checks "$repo_root")"
if [[ -n "$missing" ]]; then
    printf 'FAIL run-checks coverage: not registered in scripts/ci/run-checks.sh:\n%s\n' "$missing" >&2
    exit 1
fi
printf 'PASS run-checks coverage: every scripts/check-*.sh is registered\n'

fixture="$temporary_root/fixture"
mkdir -p "$fixture/scripts/ci"
printf '#!/usr/bin/env bash\n' >"$fixture/scripts/check-alpha.sh"
printf '#!/usr/bin/env bash\n' >"$fixture/scripts/check-beta.sh"
printf 'checks=(\n    "scripts/check-alpha.sh"\n)\n' >"$fixture/scripts/ci/run-checks.sh"
missing="$(unregistered_checks "$fixture")"
if [[ "$missing" != "check-beta.sh" ]]; then
    printf 'FAIL run-checks coverage fixture: expected only check-beta.sh, got %s\n' "$missing" >&2
    exit 1
fi
printf 'PASS run-checks coverage fixture rejects an unregistered check\n'

printf 'scripts/tests/test_run_checks_coverage.sh: passed\n'
