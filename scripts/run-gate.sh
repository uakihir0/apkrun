#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: scripts/run-gate.sh G1|G2\n' >&2
    exit 64
fi

gate="$1"
if [[ "$gate" != G1 && "$gate" != G2 ]]; then
    printf 'run-gate: unsupported gate: %s\n' "$gate" >&2
    exit 64
fi

if [[ -z "${APKRUN_TEST_DEVELOPMENT_TEAM:-}" || -z "${APKRUN_TEST_CODE_SIGN_IDENTITY:-}" ]]; then
    printf 'run-gate: set APKRUN_TEST_DEVELOPMENT_TEAM and APKRUN_TEST_CODE_SIGN_IDENTITY for the lab Apple Development certificate\n' >&2
    exit 78
fi

signing_arguments=(
    "DEVELOPMENT_TEAM=$APKRUN_TEST_DEVELOPMENT_TEAM"
    "CODE_SIGN_STYLE=Manual"
    "CODE_SIGN_IDENTITY=$APKRUN_TEST_CODE_SIGN_IDENTITY"
)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

branch="$(git branch --show-current)"
if [[ "$branch" != main ]]; then
    printf 'run-gate: %s evidence must be recorded from a clean main checkout (found %s)\n' "$gate" "$branch" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    printf 'run-gate: the working tree must be clean before running %s\n' "$gate" >&2
    exit 1
fi

gate_dir="$repo_root/build/gates/$gate"
APKRUN_TEST_LINUX_DIR="${APKRUN_TEST_LINUX_DIR:-${TMPDIR:-/tmp}/apkrun-test-linux}"
APKRUN_TEST_LINUX_DIR="$(
    python3 "$script_dir/tools/validate-test-linux-dir.py" "$APKRUN_TEST_LINUX_DIR"
)"
export APKRUN_TEST_LINUX_DIR
mkdir -p "$gate_dir"
rm -rf "$gate_dir/DerivedData" "$gate_dir/LinuxGuest.xcresult" "$gate_dir/$gate.xcresult"
report="$gate_dir/report.txt"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
commit="$(git rev-parse HEAD)"
mac_model="$(sysctl -n hw.model)"
macos_build="$(sw_vers -buildVersion)"

{
    printf 'gate: %s\n' "$gate"
    printf 'commit: %s\n' "$commit"
    printf 'started: %s\n' "$started_at"
    printf 'mac_model: %s\n' "$mac_model"
    printf 'macos_build: %s\n' "$macos_build"
    printf 'status: running\n'
} > "$report"

finish_report() {
    local result=$?
    local finished_at
    finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ $result -eq 0 ]]; then
        status=passed
    else
        status=failed
    fi
    {
        printf 'finished: %s\n' "$finished_at"
        printf 'status: %s\n' "$status"
        printf 'exit_code: %s\n' "$result"
    } >> "$report"
}
trap finish_report EXIT

scripts/generate-project.sh
scripts/build-test-initramfs.sh
if [[ "$gate" == G2 ]]; then
    # G2 boots the stock image from an unsigned bundle outside ~/Documents (#014).
    scripts/build-test-android-bundle.sh
fi
xcodebuild test \
    -project APKRun.xcodeproj \
    -scheme IntegrationTests \
    -testPlan IntegrationTests \
    -configuration Debug \
    -only-test-configuration LinuxGuest \
    -jobs 1 \
    -derivedDataPath "$gate_dir/DerivedData" \
    -resultBundlePath "$gate_dir/LinuxGuest.xcresult" \
    "APKRUN_TEST_LINUX_DIR=$APKRUN_TEST_LINUX_DIR" \
    "APKRUN_CI=1" \
    "${signing_arguments[@]}"
xcodebuild test \
    -project APKRun.xcodeproj \
    -scheme AcceptanceTests \
    -testPlan AcceptanceTests \
    -configuration Debug \
    -only-test-configuration "$gate" \
    -jobs 1 \
    -derivedDataPath "$gate_dir/DerivedData" \
    -resultBundlePath "$gate_dir/$gate.xcresult" \
    "APKRUN_TEST_LINUX_DIR=$APKRUN_TEST_LINUX_DIR" \
    "APKRUN_CI=1" \
    "${signing_arguments[@]}"
