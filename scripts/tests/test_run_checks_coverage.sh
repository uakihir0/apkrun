#!/usr/bin/env bash
# Checks that scripts/ci/run-checks.sh runs every general lint check and that
# product-build checks with required artifact inputs are called by their build.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

# Checks that need an artifact or a specific test stage, rather than running in
# generic lint. check-sepolicy.sh requires compiled AOSP policy and is invoked
# by scripts/aosp/build-product.sh. check-compile-fail.sh is the manual T1
# compiler-failure check of build-system.md §12. check-launcher.sh requires the
# APKRun product and runs in the build job.
manual_checks=(check-compile-fail.sh check-sepolicy.sh check-launcher.sh)

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

if ! grep -Fq -- "scripts/check-launcher.sh" "$repo_root/.github/workflows/ci.yml"; then
    printf 'FAIL launcher check coverage: check-launcher.sh is not called in CI\n' >&2
    exit 1
fi
printf 'PASS launcher check coverage: check-launcher.sh runs in CI\n'

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
