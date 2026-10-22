#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'usage: scripts/check-sepolicy.sh <user|userdebug> <compiled-policy> <sepolicy-analyze>\n' >&2
}

fail() {
    printf 'check-sepolicy: %s\n' "$1" >&2
    exit "${2:-1}"
}

[[ $# -eq 3 ]] || {
    usage
    exit 64
}

variant="$1"
policy="$2"
analyzer="$3"
[[ "$variant" == "user" || "$variant" == "userdebug" ]] || fail "unsupported build variant: $variant" 64
[[ -s "$policy" && ! -L "$policy" ]] || fail "compiled policy is missing or empty: $policy"
[[ -x "$analyzer" && ! -L "$analyzer" ]] || fail "sepolicy-analyze is missing or not executable: $analyzer"

permissive_domains="$("$analyzer" "$policy" permissive)" \
    || fail "sepolicy-analyze could not inspect $policy"

if [[ "$variant" == "user" ]]; then
    [[ -z "$permissive_domains" ]] \
        || fail "user image contains permissive domains: $permissive_domains"
    printf 'check-sepolicy: user image has no permissive domains\n'
    exit 0
fi

for domain in apkrun_guest_app apkrun_vsockd; do
    if ! grep -Fxq "$domain" <<<"$permissive_domains"; then
        fail "userdebug policy is missing expected permissive domain $domain"
    fi
done

printf 'check-sepolicy: userdebug agent domains are permissive\n'
