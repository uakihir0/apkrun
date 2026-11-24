#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

mock_bin="$temporary_root/bin"
launcher="$temporary_root/APKRunLauncher.app"
binary="$launcher/Contents/MacOS/APKRunLauncher"
mkdir -p "$mock_bin" "$(dirname "$binary")"
: >"$binary"

cat >"$mock_bin/lipo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${CHECK_LAUNCHER_ARCHS:-arm64}"
SH
cat >"$mock_bin/otool" <<'SH'
#!/usr/bin/env bash
if [[ "$1" != "-L" ]]; then
    exit 64
fi
printf '%s:\n' "$2"
printf '\t%s (compatibility version 1.0.0, current version 1.0.0)\n' \
    "${CHECK_LAUNCHER_DEPENDENCY:-/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit}"
SH
cat >"$mock_bin/vtool" <<'SH'
#!/usr/bin/env bash
if [[ "$1" != "-show-build" ]]; then
    exit 64
fi
if [[ -n "${CHECK_LAUNCHER_BUILD_INFO:-}" ]]; then
    printf '%s\n' "$CHECK_LAUNCHER_BUILD_INFO"
else
    printf 'Load command 1\n      cmd LC_BUILD_VERSION\n platform MACOS\n    minos 27.0\n      sdk 27.0\n'
fi
SH
chmod +x "$mock_bin/lipo" "$mock_bin/otool" "$mock_bin/vtool"

check="$repo_root/scripts/check-launcher.sh"
output="$temporary_root/check.log"

if ! PATH="$mock_bin:$PATH" "$check" "$launcher" >"$output" 2>&1; then
    cat "$output" >&2
    printf 'FAIL check-launcher fixture: valid launcher should pass\n' >&2
    exit 1
fi
printf 'PASS check-launcher fixture accepts arm64 system-linked macOS 27 launcher\n'

expect_failure() {
    local name="$1"
    local expected="$2"
    shift 2

    if env PATH="$mock_bin:$PATH" "$@" "$check" "$launcher" >"$output" 2>&1; then
        printf 'FAIL check-launcher fixture %s: expected failure\n' "$name" >&2
        exit 1
    fi
    if ! grep -Fq -- "$expected" "$output"; then
        cat "$output" >&2
        printf 'FAIL check-launcher fixture %s: expected diagnostic %s\n' "$name" "$expected" >&2
        exit 1
    fi
    printf 'PASS check-launcher fixture rejects %s\n' "$name"
}

expect_failure "universal architecture" "expected arm64 only" \
    CHECK_LAUNCHER_ARCHS="arm64 x86_64"
expect_failure "non-system dependency" "unexpected non-system dependency" \
    CHECK_LAUNCHER_DEPENDENCY="/opt/homebrew/lib/libexample.dylib"
expect_failure "old deployment target" "minimum macOS must be 27.0 or later" \
    CHECK_LAUNCHER_BUILD_INFO="    minos 26.0"
expect_failure "missing minimum OS metadata" "vtool did not report a minimum OS" \
    CHECK_LAUNCHER_BUILD_INFO="platform MACOS sdk 27.0"

if PATH="$mock_bin:$PATH" "$check" "$temporary_root/missing.app" >"$output" 2>&1; then
    printf 'FAIL check-launcher fixture: missing executable should fail\n' >&2
    exit 1
fi
if ! grep -Fq -- "launcher executable does not exist" "$output"; then
    cat "$output" >&2
    printf 'FAIL check-launcher fixture: missing executable diagnostic was absent\n' >&2
    exit 1
fi
printf 'PASS check-launcher fixture rejects a missing executable\n'

printf 'scripts/tests/test_check_launcher.sh: passed\n'
