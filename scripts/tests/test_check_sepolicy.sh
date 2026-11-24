#!/usr/bin/env bash
# Checks that check-sepolicy.sh rejects permissive domains in `user`
# build inputs and passes the enforcing-only tree plus userdebug.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

checker="$repo_root/scripts/check-sepolicy.sh"
product="$temporary_root/product"
mkdir -p "$product/sepolicy/userdebug"
printf '(type apkrun_guest_app)\n' > "$product/sepolicy/apkrun_guest.cil"
printf '(typepermissive apkrun_guest_app)\n' > "$product/sepolicy/userdebug/userdebug_permissive.cil"

run_check() {
    local label="$1" expected="$2"; shift 2
    local output="$temporary_root/$label.log" status=0
    "$checker" "$@" >"$output" 2>&1 || status=$?
    if [[ "$expected" == pass && $status -ne 0 ]]; then
        cat "$output" >&2
        printf 'FAIL check-sepolicy: %s should pass\n' "$label" >&2
        exit 1
    fi
    if [[ "$expected" == fail && $status -eq 0 ]]; then
        cat "$output" >&2
        printf 'FAIL check-sepolicy: %s should fail\n' "$label" >&2
        exit 1
    fi
}

# Enforcing-only inputs pass for user.
run_check "enforcing-user" pass --variant user --root "$product"

# The real product tree passes: its permissive rules live under
# sepolicy/userdebug/ only.
run_check "product-user" pass --variant user --root "$repo_root/Guest/product"

# userdebug always passes (its permissive rules are intentional).
printf '(typepermissive apkrun_vsockd)\n' > "$product/sepolicy/apkrun_vsockd.cil"
run_check "userdebug" pass --variant userdebug --root "$product"

# A permissive domain in user inputs fails.
run_check "permissive-user" fail --variant user --root "$product"
status=0
"$checker" --variant user --root "$product" >"$temporary_root/permissive.log" 2>&1 || status=$?
if ! grep -Fq 'typepermissive' "$temporary_root/permissive.log"; then
    cat "$temporary_root/permissive.log" >&2
    printf 'FAIL check-sepolicy: user rejection should name the permissive rule\n' >&2
    exit 1
fi

printf 'check-sepolicy tests passed\n'
