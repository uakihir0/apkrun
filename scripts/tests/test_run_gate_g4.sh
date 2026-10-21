#!/usr/bin/env bash
# Checks the G4 gate wiring without running the bundle, Gradle, Xcode, or a VM.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
gate="$repo_root/scripts/run-gate.sh"
fixture="$repo_root/scripts/build-fixtures.sh"
plan="$repo_root/Tests/AcceptanceTests/AcceptanceTests.xctestplan"
host_plist="$repo_root/Tests/IntegrationTests/Host/Info.plist"
acceptance_test="$repo_root/Tests/AcceptanceTests/G4NativeWindow/G4NativeWindowTests.swift"

fail() {
    printf 'FAIL run-gate G4: %s\n' "$1" >&2
    exit 1
}

for expected in \
    'G1|G2|G3|G4' \
    'scripts/build-test-android-bundle.sh' \
    'scripts/build-guest.sh' \
    'scripts/build-fixtures.sh --app HelloText --variant debug' \
    'APKRUN_CLI_TRAITS=EmbeddedRuntime' \
    'APKRUN_G4_CLI=' \
    'APKRUN_G4_BUNDLE=' \
    'APKRUN_G4_APK=' \
    'APKRUN_G4_GUEST_DIR=' \
    'APKRUN_G4_VIRGL_RUNTIME=' \
    'APKRUN_G4_ANDROID_HOME=' \
    'APKRUN_G4_ARTIFACTS=' \
    '-only-test-configuration G4' \
    '-only-testing:AcceptanceTests/G4NativeWindowTests' \
    'lockf -k /tmp/apkrun-vm.lock xcodebuild test' \
    'check-g4-evidence.py'
do
    if ! grep -Fq -- "$expected" "$gate"; then
        fail "run-gate.sh is missing $expected"
    fi
done
if ! grep -Fq '"name" : "G4"' "$plan" || ! grep -Fq '"APKRUN_G4_REQUIRED"' "$plan"; then
    fail "the G4 test-plan configuration does not require the acceptance test to run"
fi
for key in APKRUN_G4_CLI APKRUN_G4_BUNDLE APKRUN_G4_APK APKRUN_G4_GUEST_DIR \
    APKRUN_G4_VIRGL_RUNTIME APKRUN_G4_ANDROID_HOME APKRUN_G4_ARTIFACTS
do
    if ! grep -Fq "<key>$key</key>" "$host_plist"; then
        fail "the test host plist is missing $key"
    fi
done

bundle_build="$(grep -n 'scripts/build-test-android-bundle.sh' "$gate" | head -1 | cut -d: -f1)"
disk_build="$(grep -n 'scripts/build-test-android-disks.sh' "$gate" | head -1 | cut -d: -f1)"
artifact_check="$(grep -n 'scripts/tools/verify-gate-artifacts.sh' "$gate" | head -1 | cut -d: -f1)"
host_build="$(grep -n '^xcodebuild build-for-testing' "$gate" | head -1 | cut -d: -f1)"
gate_test="$(grep -n 'lockf -k /tmp/apkrun-vm.lock xcodebuild test' "$gate" | tail -1 | cut -d: -f1)"
evidence_check="$(grep -n 'check-g4-evidence.py' "$gate" | tail -1 | cut -d: -f1)"
if (( bundle_build >= disk_build || disk_build >= artifact_check || artifact_check >= host_build \
    || host_build >= gate_test || gate_test >= evidence_check )); then
    fail "G4 builds and verifies its inputs, builds the host, runs the gate, and checks evidence in the wrong order"
fi
printf 'PASS G4 builds and verifies staged inputs before its serialized acceptance run\n'

capture_window="$(grep -n 'try await session.captureVisibleHelloTextWindow' "$acceptance_test" | cut -d: -f1)"
start_recording="$(grep -n 'try await session.startScreenRecording()' "$acceptance_test" | cut -d: -f1)"
first_interaction="$(grep -n 'try await session.clickButtonOneHundredTimes' "$acceptance_test" | cut -d: -f1)"
if (( capture_window >= start_recording || start_recording >= first_interaction )); then
    fail "the test must verify and capture visible HelloText before recording and host input"
fi
if ! grep -Fq 'VNRecognizeTextRequest()' "$acceptance_test" \
    || ! grep -Fq 'localizedCaseInsensitiveContains("Increment")' "$acceptance_test"
then
    fail "the HelloText screenshot must pass a visible-content OCR check"
fi
if ! grep -Fq 'screenRecordingDurationSeconds = 120' "$acceptance_test" \
    || ! grep -Fq 'screenRecordingFinishTimeout: Duration = .seconds(135)' "$acceptance_test" \
    || ! grep -Fq 'process.arguments = ["-v", "-V", "\(Self.screenRecordingDurationSeconds)", screenRecordingURL.path]' \
        "$acceptance_test" \
    || ! grep -Fq 'try await Task.sleep(for: .seconds(1))' "$acceptance_test"
then
    fail "the test must keep screencapture alive through slow input and wait for it to attach"
fi
if [[ "$(grep -Fc 'try noteHostInputEventRecorded()' "$acceptance_test")" -ne 3 ]]; then
    fail "mouse and keyboard event paths must check that screencapture is running after each event"
fi
g4_branch_start="$(grep -n '^    g4_status=0$' "$gate" | cut -d: -f1)"
g4_branch_end="$(grep -n '^    exit "\$gate_status"$' "$gate" | tail -1 | cut -d: -f1)"
if sed -n "${g4_branch_start},${g4_branch_end}p" "$gate" | grep -Fq 'screencapture -v -V'; then
    fail "G4 recording must be synchronized inside the acceptance test, not started before xcodebuild or the VM lock"
fi
printf 'PASS G4 verifies visible HelloText before recording and checks the live recorder around every host event\n'

if "$fixture" --app HelloGL --variant debug > /dev/null 2>&1; then
    fail "debug variant unexpectedly accepts HelloGL"
fi
if "$fixture" --app HelloText --variant unsupported > /dev/null 2>&1; then
    fail "unsupported fixture variant unexpectedly passed validation"
fi
for expected in '[--variant release|debug]' 'out/$app-debug.apk' 'assemble$variant_title'; do
    if ! grep -Fq -- "$expected" "$fixture"; then
        fail "the fixture builder is missing $expected"
    fi
done
printf 'PASS only HelloText accepts the debug fixture variant\n'
