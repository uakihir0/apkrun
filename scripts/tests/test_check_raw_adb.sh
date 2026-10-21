#!/usr/bin/env bash
# Checks that the raw-ADB lint catches commands in Swift and scripts while
# allowing only the paths documented by the package-store design.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

fixture="$temporary_root/tree"
checker="$repo_root/scripts/check-raw-adb.sh"
space=' '
adb_shell="adb${space}shell pidof io.apkrun"
pm_install="pm${space}install package.apk"
selected_device_shell="adb${space}-s${space}127.0.0.1:6520${space}shell${space}pm${space}list packages"
mkdir -p \
    "$fixture/Packages/RuntimeCore/Sources/RuntimeCore/Android" \
    "$fixture/Packages/RuntimeHost/Sources/RuntimeHost" \
    "$fixture/Packages/Fixture/Sources/Fixture" \
    "$fixture/Tests/IntegrationTests" \
    "$fixture/Experiments/adb-probe" \
    "$fixture/scripts/dev" \
    "$fixture/scripts/tools"

run_check() {
    local label="$1"
    local expected="$2"
    local diagnostic="${3:-}"
    local output="$temporary_root/$label.log"
    local status=0

    "$checker" --root "$fixture" >"$output" 2>&1 || status=$?
    if [[ "$expected" == pass ]]; then
        if [[ $status -ne 0 ]]; then
            cat "$output" >&2
            printf 'FAIL raw-ADB lint: %s should pass\n' "$label" >&2
            exit 1
        fi
    else
        if [[ $status -eq 0 ]]; then
            cat "$output" >&2
            printf 'FAIL raw-ADB lint: %s should fail\n' "$label" >&2
            exit 1
        fi
        if [[ -n "$diagnostic" ]] && ! grep -Fq -- "$diagnostic" "$output"; then
            cat "$output" >&2
            printf 'FAIL raw-ADB lint: %s did not report %s\n' "$label" "$diagnostic" >&2
            exit 1
        fi
    fi
    printf 'PASS raw-ADB lint: %s\n' "$label"
}

printf '%s\n' 'let package = "io.apkrun.fixture"' >"$fixture/Packages/Fixture/Sources/Fixture/Clean.swift"
printf '%s\n' "let invocation = \"${adb_shell}\"" \
    >"$fixture/Packages/Fixture/Sources/Fixture/RawADB.swift"
run_check "rejects raw ADB shell syntax in Swift" fail "RawADB.swift:1:"

rm "$fixture/Packages/Fixture/Sources/Fixture/RawADB.swift"
printf '%s\n' "let invocation = \"${pm_install}\"" \
    >"$fixture/Packages/Fixture/Sources/Fixture/RawPM.swift"
run_check "rejects package-manager invocation in Swift" fail "RawPM.swift:1:"

rm "$fixture/Packages/Fixture/Sources/Fixture/RawPM.swift"
printf '%s\n' "let invocation = \"${selected_device_shell}\"" \
    >"$fixture/Packages/Fixture/Sources/Fixture/SelectedDevice.swift"
run_check "rejects selected-device ADB shell syntax in Swift" fail "SelectedDevice.swift:1:"

rm "$fixture/Packages/Fixture/Sources/Fixture/SelectedDevice.swift"
printf '%s\n' "// ${adb_shell}" >"$fixture/Packages/Fixture/Sources/Fixture/CommandExample.swift"
run_check "ignores command examples in comments" pass

rm "$fixture/Packages/Fixture/Sources/Fixture/CommandExample.swift"
printf '%s\n' "let invocation = \"${adb_shell}\"" >"$fixture/Tests/IntegrationTests/RawADB.swift"
printf '%s\n' "adb${space}shell logcat -d" >"$fixture/Experiments/adb-probe/probe.sh"
run_check "allows raw ADB in test and experiment harnesses" pass

rm "$fixture/Tests/IntegrationTests/RawADB.swift" "$fixture/Experiments/adb-probe/probe.sh"
printf '%s\n' "let invocation = \"${adb_shell}\"" \
    >"$fixture/Packages/RuntimeCore/Sources/RuntimeCore/Android/AdbClient.swift"
printf '%s\n' "let invocation = \"${pm_install}\"" \
    >"$fixture/Packages/RuntimeHost/Sources/RuntimeHost/ADBStoreAgentChannel.swift"
printf '%s\n' "adb${space}shell input tap 10 10" >"$fixture/scripts/dev/device-check.sh"
run_check "rejects raw shell in the stock package channel" fail "ADBStoreAgentChannel.swift:1:"

rm "$fixture/Packages/RuntimeHost/Sources/RuntimeHost/ADBStoreAgentChannel.swift"
run_check "allows the ADB command owner and development tools" pass

printf '%s\n' 'scripts/tests/test_check_raw_adb.sh: passed'
