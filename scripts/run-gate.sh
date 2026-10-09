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
# The default is the directory every producer script and the test harness use. $TMPDIR is a per-user directory
# on macOS: a gate that used it built its artifacts where the shared test directory was never read (IR-376).
APKRUN_TEST_LINUX_DIR="${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}"
APKRUN_TEST_LINUX_DIR="$(
    python3 "$script_dir/tools/validate-test-linux-dir.py" "$APKRUN_TEST_LINUX_DIR"
)"
export APKRUN_TEST_LINUX_DIR
mkdir -p "$gate_dir"
rm -rf "$gate_dir/DerivedData" "$gate_dir/LinuxGuest.xcresult" "$gate_dir/$gate.xcresult"
# The gate runs the spec's values. A dwell override in the environment would change the evidence, so both
# variables are removed before any test runs. G2 holds each boot for the default 600 s (gate G2, roadmap.md §2).
unset APKRUN_G2_DWELL_SECONDS TEST_RUNNER_APKRUN_G2_DWELL_SECONDS
gate_dwell_seconds=600
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
    printf 'artifact_directory: %s\n' "$APKRUN_TEST_LINUX_DIR"
    if [[ "$gate" == G2 ]]; then
        printf 'dwell_seconds: %s\n' "$gate_dwell_seconds"
    fi
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
    # G2 boots the stock image from a signed bundle outside ~/Documents (#014, #065).
    scripts/build-test-android-bundle.sh
fi
# Both gates run the LinuxGuest suite, whose layout test reads the Android disks. Every gate rebuilds them, so no
# run depends on disks left by an earlier build.
scripts/build-test-android-disks.sh
scripts/tools/verify-gate-artifacts.sh "$APKRUN_TEST_LINUX_DIR" "$gate"
# Build the test host before any test runs, then check the directory it will read (IR-376).
xcodebuild build-for-testing \
    -project APKRun.xcodeproj \
    -scheme IntegrationTests \
    -testPlan IntegrationTests \
    -configuration Debug \
    -jobs 1 \
    -derivedDataPath "$gate_dir/DerivedData" \
    "APKRUN_TEST_LINUX_DIR=$APKRUN_TEST_LINUX_DIR" \
    "APKRUN_CI=1" \
    "${signing_arguments[@]}"
scripts/tools/verify-test-host-directory.sh \
    "$gate_dir/DerivedData/Build/Products/Debug/APKRunTestHost.app" "$APKRUN_TEST_LINUX_DIR"
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
