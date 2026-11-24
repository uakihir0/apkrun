#!/bin/bash
# Rejects `permissive` domains in the SELinux inputs a `user` build would
# compile (R-13, ADR-0020). The userdebug-only permissive rules live in
# Guest/product/sepolicy/userdebug/ and are never part of a `user`
# build's BOARD_SEPOLICY_DIRS (Guest/product/apkrun_arm64.mk).
#
#   scripts/check-sepolicy.sh [--variant user|userdebug] [--root <product dir>]
#
# Exit 1 when a `user` build's policy inputs declare a permissive
# domain, exit 0 otherwise (userdebug always passes; its permissive
# rules are intentional), exit 2 on usage errors.

set -euo pipefail

variant="user"
product_root=""

usage() {
    printf 'usage: %s [--variant user|userdebug] [--root <product dir>]\n' "$0" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) variant="${2:-}"; shift 2 ;;
        --root) product_root="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

case "$variant" in
    user|userdebug) ;;
    *) printf 'check-sepolicy: unknown variant %s\n' "$variant" >&2; exit 2 ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
[[ -n "$product_root" ]] || product_root="$repo_root/Guest/product"
sepolicy_dir="$product_root/sepolicy"

if [[ ! -d "$sepolicy_dir" ]]; then
    printf 'check-sepolicy: %s is missing\n' "$sepolicy_dir" >&2
    exit 2
fi

# Only a `user` build is checked: userdebug ships the permissive rules
# in sepolicy/userdebug/ on purpose (ADR-0020).
if [[ "$variant" == "userdebug" ]]; then
    printf 'check-sepolicy: userdebug builds allow the userdebug/ permissive rules\n'
    exit 0
fi

# The inputs a `user` build compiles: every file directly under
# sepolicy/; sepolicy/userdebug/ is never in its BOARD_SEPOLICY_DIRS
# (apkrun_arm64.mk).
files=()
while IFS= read -r file; do
    files+=("$file")
done < <(find "$sepolicy_dir" -maxdepth 1 -type f | sort)

violations=0
for file in "${files[@]}"; do
    if grep -nE 'typepermissive|\bpermissive\b' "$file" >/dev/null 2>&1; then
        while IFS= read -r line; do
            printf 'check-sepolicy: %s: %s\n' "$file" "$line" >&2
        done < <(grep -nE 'typepermissive|\bpermissive\b' "$file")
        violations=$((violations + 1))
    fi
done

if [[ "$violations" -gt 0 ]]; then
    printf 'check-sepolicy: %d file(s) declare permissive domains; a %s build must ship enforcing policy (R-13)\n' \
        "$violations" "$variant" >&2
    exit 1
fi

printf 'check-sepolicy: %s build policy inputs are enforcing-only\n' "$variant"
