#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
checker="$repo_root/scripts/check-sepolicy.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

policy="$temporary_root/sepolicy"
analyzer="$temporary_root/sepolicy-analyze"
report="$temporary_root/permissive-domains"
printf 'compiled policy fixture\n' >"$policy"
cat >"$analyzer" <<'ANALYZER'
#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 && "$2" == "permissive" ]]
cat "$SEPOLICY_REPORT"
ANALYZER
chmod 0755 "$analyzer"

expect_pass() {
    local name="$1"
    shift
    if ! "$@" >"$temporary_root/$name.log" 2>&1; then
        cat "$temporary_root/$name.log" >&2
        printf 'FAIL %s: expected pass\n' "$name" >&2
        exit 1
    fi
}

expect_fail() {
    local name="$1"
    local expected="$2"
    shift 2
    if "$@" >"$temporary_root/$name.log" 2>&1; then
        printf 'FAIL %s: expected failure\n' "$name" >&2
        exit 1
    fi
    if ! grep -Fq -- "$expected" "$temporary_root/$name.log"; then
        cat "$temporary_root/$name.log" >&2
        printf 'FAIL %s: missing diagnostic %s\n' "$name" "$expected" >&2
        exit 1
    fi
}

printf 'apkrun_guest_app\napkrun_vsockd\n' >"$report"
expect_pass userdebug-requires-agent-domains \
    env SEPOLICY_REPORT="$report" "$checker" userdebug "$policy" "$analyzer"

: >"$report"
expect_pass user-rejects-no-domains \
    env SEPOLICY_REPORT="$report" "$checker" user "$policy" "$analyzer"

printf 'apkrun_guest_app\n' >"$report"
expect_fail user-rejects-permissive-domains 'user image contains permissive domains' \
    env SEPOLICY_REPORT="$report" "$checker" user "$policy" "$analyzer"

: >"$report"
expect_fail userdebug-requires-both-agent-domains 'missing expected permissive domain apkrun_guest_app' \
    env SEPOLICY_REPORT="$report" "$checker" userdebug "$policy" "$analyzer"

printf 'scripts/tests/test_check_sepolicy.sh: passed\n'
