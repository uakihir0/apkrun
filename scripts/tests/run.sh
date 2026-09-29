#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
fixture_root="$script_dir/fixtures/lock/base"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

checker="$repo_root/scripts/check-lock.sh"

expect_pass() {
    local name="$1"
    local root="$2"
    if ! "$checker" --root "$root"; then
        printf 'FAIL lock fixture %s: expected pass\n' "$name" >&2
        exit 1
    fi
    printf 'PASS lock fixture %s\n' "$name"
}

expect_fail() {
    local name="$1"
    local expected="$2"
    local root="$3"
    local output="$temporary_root/$name.log"
    if "$checker" --root "$root" >"$output" 2>&1; then
        printf 'FAIL lock fixture %s: expected failure\n' "$name" >&2
        exit 1
    fi
    if ! rg -q "$expected" "$output"; then
        cat "$output" >&2
        printf 'FAIL lock fixture %s: expected diagnostic matching %s\n' "$name" "$expected" >&2
        exit 1
    fi
    printf 'PASS lock fixture %s\n' "$name"
}

new_fixture() {
    local name="$1"
    local destination="$temporary_root/$name"
    mkdir -p "$destination"
    cp -R "$fixture_root/." "$destination/"
    printf '%s\n' "$destination"
}

mutate_lock() {
    local root="$1"
    local mode="$2"
    python3 - "$root" "$mode" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
lock_path = root / "ThirdParty/ThirdParty.lock.json"
lock = json.loads(lock_path.read_text())
component = lock["components"][0]

if mode == "branch":
    component["commit"] = "main"
elif mode == "short-commit":
    component["commit"] = "6a52f32"
elif mode == "missing-patch":
    component["patches"] = ["swift-argument-parser/0001-missing.patch"]
elif mode == "pin-mismatch":
    component["commit"] = "0000000000000000000000000000000000000000"
elif mode == "unlisted-pin":
    resolved_path = root / "Package.resolved"
    resolved = json.loads(resolved_path.read_text())
    resolved["pins"].append(
        {
            "identity": "unlisted-package",
            "kind": "remoteSourceControl",
            "location": "https://example.com/unlisted-package.git",
            "state": {
                "revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "version": "1.0.0",
            },
        }
    )
    resolved_path.write_text(json.dumps(resolved, indent=2) + "\n")
else:
    raise SystemExit(f"unknown mutation: {mode}")

lock_path.write_text(json.dumps(lock, indent=2) + "\n")
PY
}

expect_pass "valid lock" "$fixture_root"
expect_pass "repository lock" "$repo_root"

branch_root="$(new_fixture branch-name)"
mutate_lock "$branch_root" branch
expect_fail "branch commit" "commit must be 40 lowercase hexadecimal" "$branch_root"

short_root="$(new_fixture short-commit)"
mutate_lock "$short_root" short-commit
expect_fail "short commit" "commit must be 40 lowercase hexadecimal" "$short_root"

patch_root="$(new_fixture missing-patch)"
mutate_lock "$patch_root" missing-patch
expect_fail "missing patch" "patch is missing" "$patch_root"

mismatch_root="$(new_fixture pin-mismatch)"
mutate_lock "$mismatch_root" pin-mismatch
expect_fail "pin mismatch" "revision .* does not match lock commit" "$mismatch_root"

unlisted_root="$(new_fixture unlisted-pin)"
mutate_lock "$unlisted_root" unlisted-pin
expect_fail "unlisted Swift package pin" "has no ThirdParty lock entry" "$unlisted_root"

printf 'scripts/tests: passed\n'
