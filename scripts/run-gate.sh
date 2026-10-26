#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: scripts/run-gate.sh G1|G2|G3|G4\n' >&2
    exit 64
fi

gate="$1"
if [[ "$gate" != G1 && "$gate" != G2 && "$gate" != G3 && "$gate" != G4 ]]; then
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
# The gate inputs, set once its artifacts are staged.
g3_build_settings=()
g4_build_settings=()

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

if [[ "$gate" == G3 ]]; then
    # G3 is meant to run on build 16373615 with the ODM overlay, because the stock image without the overlay fails the
    # EGL DRM check (IR-760 to IR-764, IR-940 to IR-961). The overlay bundle is built outside the production tree
    # (IR-1112), so the gate takes it by path (IR-1209). The gate checks SHA256SUMS against the bundle's files and
    # records the manifest's imageVersion. It does not verify manifest.sig or the overlay itself.
    g3_bundle="${APKRUN_G3_ANDROID_BUNDLE:-}"
    if [[ "$g3_bundle" != /* || ! -f "$g3_bundle/manifest.json" || ! -f "$g3_bundle/SHA256SUMS" ]]; then
        printf 'run-gate: G3 needs APKRUN_G3_ANDROID_BUNDLE, the absolute path of the Android bundle with the ODM overlay (IR-1209)\n' >&2
        exit 78
    fi
    if ! (cd "$g3_bundle" && shasum -a 256 -c SHA256SUMS > /dev/null); then
        printf 'run-gate: the checksums of %s do not match SHA256SUMS\n' "$g3_bundle" >&2
        exit 1
    fi
    g3_android_home="${ANDROID_HOME:-$repo_root/build/android-sdk}"
    if [[ ! -x "$g3_android_home/platform-tools/adb" ]]; then
        printf 'run-gate: G3 needs adb at %s/platform-tools/adb (environment-setup.md §2.5)\n' "$g3_android_home" >&2
        exit 78
    fi
    g3_virgl="$repo_root/ThirdParty/out/virgl-runtime/current"
    if [[ ! -f "$g3_virgl/libvirglrenderer.1.dylib" ]]; then
        printf 'run-gate: G3 needs the virgl runtime at %s (ThirdParty, #21)\n' "$g3_virgl" >&2
        exit 78
    fi
    rm -rf "$gate_dir/artifacts" "$gate_dir/products" "$gate_dir/screen-recording.mov" "$gate_dir/screen-recording.mp4"
fi
if [[ "$gate" == G4 ]]; then
    g4_android_home="${ANDROID_HOME:-$repo_root/build/android-sdk}"
    if [[ ! -x "$g4_android_home/platform-tools/adb" ]]; then
        printf 'run-gate: G4 needs adb at %s/platform-tools/adb (environment-setup.md §2.5)\n' "$g4_android_home" >&2
        exit 78
    fi
    g4_virgl="$repo_root/ThirdParty/out/virgl-runtime/current"
    if [[ ! -f "$g4_virgl/libvirglrenderer.1.dylib" ]]; then
        printf 'run-gate: G4 needs the virgl runtime at %s (ThirdParty, #21)\n' "$g4_virgl" >&2
        exit 78
    fi
    rm -rf "$gate_dir/artifacts" "$gate_dir/products" "$gate_dir/screen-recording.mov" "$gate_dir/screen-recording.mp4"
fi

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
    if [[ "$gate" == G3 ]]; then
        printf 'bundle: %s\n' "$g3_bundle"
        printf 'bundle_manifest_sha256: %s\n' "$(shasum -a 256 "$g3_bundle/manifest.json" | awk '{ print $1 }')"
        printf 'bundle_sha256sums_sha256: %s\n' "$(shasum -a 256 "$g3_bundle/SHA256SUMS" | awk '{ print $1 }')"
        printf 'bundle_checksums: SHA256SUMS matches the bundle files; manifest.sig is not checked by this gate\n'
        printf 'bundle_image_version: %s (manifest.json; the overlay itself is not checked by this gate)\n' \
            "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["imageVersion"])' "$g3_bundle/manifest.json")"
        printf 'cli_traits: EmbeddedRuntime,TestReadback\n'
    fi
    if [[ "$gate" == G4 ]]; then
        printf 'cli_traits: EmbeddedRuntime\n'
        printf 'android_sdk: %s\n' "$g4_android_home"
        printf 'virgl_runtime: %s\n' "$g4_virgl"
        printf 'manual_checks: C01-1 through C01-5 are recorded separately in test-strategy.md §8.2\n'
    fi
    printf 'status: running\n'
} > "$report"

# The report's final status is written once, by one trap, whichever way the gate ends (scripts/tools/gate-status.sh).
# A signal that ends the gate also stops the G3 recorder, which would otherwise keep running after the gate.
stop_recorder() {
    if [[ -n "${recording_pid:-}" ]] && kill -0 "$recording_pid" 2>/dev/null; then
        kill "$recording_pid" 2>/dev/null || true
    fi
}
source "$script_dir/tools/gate-status.sh"
GATE_FINISH_HOOK=stop_recorder
gate_report_install "$report"

scripts/generate-project.sh
scripts/build-test-initramfs.sh
if [[ "$gate" == G2 || "$gate" == G4 ]]; then
    # G2 boots the stock image, and G4 installs it before `apkrun dev launch`; both use a signed bundle outside
    # ~/Documents (#15, #66).
    scripts/build-test-android-bundle.sh
fi
# Both gates run the LinuxGuest suite, whose layout test reads the Android disks. Every gate rebuilds them, so no
# run depends on disks left by an earlier build.
scripts/build-test-android-disks.sh
if [[ "$gate" == G3 ]]; then
    # The Guest Agent bundle, HelloGL, and the Debug CLI with the TestReadback trait (graphics.md §7).
    # Each is built from this clean checkout. The files the test host reads are copied under the shared test directory,
    # outside ~/Documents, so the test host can read them without a file-access prompt (as G2 does for its bundle).
    export ANDROID_HOME="$g3_android_home"
    scripts/build-guest.sh
    scripts/build-fixtures.sh --app HelloGL
    SRCROOT="$repo_root" scripts/build/stamp-commit.sh
    SRCROOT="$repo_root" \
        CONFIGURATION=Debug \
        TARGET_BUILD_DIR="$gate_dir/products" \
        UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources \
        DERIVED_FILE_DIR="$gate_dir/derived" \
        APKRUN_CLI_TRAITS=EmbeddedRuntime,TestReadback \
        EXPANDED_CODE_SIGN_IDENTITY="$APKRUN_TEST_CODE_SIGN_IDENTITY" \
        scripts/build/embed-cli.sh
    staging="$APKRUN_TEST_LINUX_DIR/g3-staging"
    rm -rf "$staging"
    mkdir -p "$staging/cli" "$staging/guest" "$staging/android-sdk"
    cp "$gate_dir/products/Resources/bin/apkrun" "$staging/cli/apkrun"
    cp Guest/build/out/apkrun-guest.apk Guest/build/out/apkrun-guest.json "$staging/guest/"
    cp -RL "$g3_virgl" "$staging/virgl-runtime"
    cp -R "$g3_android_home/platform-tools" "$staging/android-sdk/platform-tools"
    cp Tests/Fixtures/AndroidApps/out/HelloGL.apk "$staging/HelloGL.apk"
    # The test host reads these from its Info.plist, where the build settings land (IntegrationTests/Host/Info.plist).
    g3_build_settings=(
        "APKRUN_G3_CLI=$staging/cli/apkrun"
        "APKRUN_G3_BUNDLE=$g3_bundle"
        "APKRUN_G3_APK=$staging/HelloGL.apk"
        "APKRUN_G3_GUEST_DIR=$staging/guest"
        "APKRUN_G3_VIRGL_RUNTIME=$staging/virgl-runtime"
        "APKRUN_G3_ANDROID_HOME=$staging/android-sdk"
        "APKRUN_G3_ARTIFACTS=$APKRUN_TEST_LINUX_DIR/g3-artifacts"
    )
    {
        printf 'cli_sha256: %s\n' "$(shasum -a 256 "$staging/cli/apkrun" | awk '{ print $1 }')"
        printf 'cli_commit: %s\n' "$(sed -n 's/^#define APKRUN_GIT_COMMIT \(.*\)$/\1/p' "$repo_root/build/generated/BuildStamp.h")"
        printf 'hellogl_apk_sha256: %s\n' "$(shasum -a 256 "$staging/HelloGL.apk" | awk '{ print $1 }')"
        printf 'guest_apk_sha256: %s\n' "$(shasum -a 256 "$staging/guest/apkrun-guest.apk" | awk '{ print $1 }')"
        printf 'virgl_runtime: %s\n' "$g3_virgl"
        printf 'android_sdk: %s\n' "$g3_android_home"
    } >> "$report"
fi
if [[ "$gate" == G4 ]]; then
    # G4 runs `apkrun dev launch` against the stock image with the debug HelloText APK. The debug receiver exposes an
    # exact text-field oracle; mouse and keyboard input still enters through the native window's host event path.
    export ANDROID_HOME="$g4_android_home"
    scripts/build-guest.sh
    scripts/build-fixtures.sh --app HelloText --variant debug
    SRCROOT="$repo_root" scripts/build/stamp-commit.sh
    SRCROOT="$repo_root" \
        CONFIGURATION=Debug \
        TARGET_BUILD_DIR="$gate_dir/products" \
        UNLOCALIZED_RESOURCES_FOLDER_PATH=Resources \
        DERIVED_FILE_DIR="$gate_dir/derived" \
        APKRUN_CLI_TRAITS=EmbeddedRuntime \
        EXPANDED_CODE_SIGN_IDENTITY="$APKRUN_TEST_CODE_SIGN_IDENTITY" \
        scripts/build/embed-cli.sh
    staging="$APKRUN_TEST_LINUX_DIR/g4-staging"
    rm -rf "$staging" "$APKRUN_TEST_LINUX_DIR/g4-artifacts"
    mkdir -p "$staging/cli" "$staging/guest" "$staging/android-sdk"
    cp "$gate_dir/products/Resources/bin/apkrun" "$staging/cli/apkrun"
    cp Guest/build/out/apkrun-guest.apk Guest/build/out/apkrun-guest.json "$staging/guest/"
    cp -RL "$g4_virgl" "$staging/virgl-runtime"
    cp -R "$g4_android_home/platform-tools" "$staging/android-sdk/platform-tools"
    cp Tests/Fixtures/AndroidApps/out/HelloText-debug.apk "$staging/HelloText-debug.apk"
    g4_build_settings=(
        "APKRUN_G4_CLI=$staging/cli/apkrun"
        "APKRUN_G4_BUNDLE=$APKRUN_TEST_LINUX_DIR/android-bundle"
        "APKRUN_G4_APK=$staging/HelloText-debug.apk"
        "APKRUN_G4_GUEST_DIR=$staging/guest"
        "APKRUN_G4_VIRGL_RUNTIME=$staging/virgl-runtime"
        "APKRUN_G4_ANDROID_HOME=$staging/android-sdk"
        "APKRUN_G4_ARTIFACTS=$APKRUN_TEST_LINUX_DIR/g4-artifacts"
    )
    {
        printf 'bundle: %s\n' "$APKRUN_TEST_LINUX_DIR/android-bundle"
        printf 'bundle_manifest_sha256: %s\n' \
            "$(shasum -a 256 "$APKRUN_TEST_LINUX_DIR/android-bundle/manifest.json" | awk '{ print $1 }')"
        printf 'bundle_sha256sums_sha256: %s\n' \
            "$(shasum -a 256 "$APKRUN_TEST_LINUX_DIR/android-bundle/SHA256SUMS" | awk '{ print $1 }')"
        printf 'hellotext_debug_apk_sha256: %s\n' \
            "$(shasum -a 256 "$staging/HelloText-debug.apk" | awk '{ print $1 }')"
        printf 'guest_apk_sha256: %s\n' \
            "$(shasum -a 256 "$staging/guest/apkrun-guest.apk" | awk '{ print $1 }')"
    } >> "$report"
fi
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
    "${signing_arguments[@]}" \
    ${g3_build_settings[@]+"${g3_build_settings[@]}"} \
    ${g4_build_settings[@]+"${g4_build_settings[@]}"}
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
if [[ "$gate" == G3 ]]; then
    # The G3 check runs one boot in the G3 configuration (graphics.md §14). It is serialised with the other VM runs
    # by lockf (test-strategy §3.6). The artifacts stay outside ~/Documents until the run ends, and the gate copies them.
    artifacts="$APKRUN_TEST_LINUX_DIR/g3-artifacts"
    rm -rf "$artifacts"
    recording="$gate_dir/screen-recording.mov"
    # screencapture writes its file only when its own -V timer ends. A background job of this non-interactive shell
    # ignores SIGINT, and a signal that does reach it ends it without the file. So the recording runs for 30 minutes,
    # which bounds the run, and the gate waits for it to end (IR-1212).
    screencapture -v -V 1800 "$recording" &
    recording_pid=$!
    g3_status=0
    lockf -k /tmp/apkrun-vm.lock xcodebuild test \
        -project APKRun.xcodeproj \
        -scheme AcceptanceTests \
        -testPlan AcceptanceTests \
        -configuration Debug \
        -only-test-configuration G3 \
        -only-testing:AcceptanceTests/G3GraphicsTests \
        -test-timeouts-enabled NO \
        -jobs 1 \
        -derivedDataPath "$gate_dir/DerivedData" \
        -resultBundlePath "$gate_dir/$gate.xcresult" \
        "APKRUN_TEST_LINUX_DIR=$APKRUN_TEST_LINUX_DIR" \
        "APKRUN_CI=1" \
        "${signing_arguments[@]}" \
        ${g3_build_settings[@]+"${g3_build_settings[@]}"} || g3_status=$?
    recorder_status=0
    wait "$recording_pid" || recorder_status=$?
    if [[ -d "$artifacts" ]]; then
        rm -rf "$gate_dir/artifacts"
        cp -R "$artifacts" "$gate_dir/artifacts"
    fi
    if [[ -f "$recording" ]]; then
        if avconvert --preset PresetMediumQuality --source "$recording" --output "$gate_dir/screen-recording.mp4"; then
            rm -f "$recording"
        else
            recorder_status=1
        fi
    fi
    # The recording is evidence (test-strategy §5), so a missing or empty MP4 fails the gate.
    if [[ ! -s "$gate_dir/screen-recording.mp4" ]]; then
        recorder_status=1
    fi
    # xcodebuild's status is not the verdict: the test's summary and the xcresult must show that the check ran and passed.
    check_status=0
    python3 -I "$repo_root/scripts/tools/check-g3-evidence.py" \
        "$gate_dir/artifacts" "$gate_dir/$gate.xcresult" "$repo_root" > "$gate_dir/evidence-check.txt" 2>&1 \
        || check_status=$?
    {
        printf 'artifacts: %s\n' "$gate_dir/artifacts"
        printf 'screen_recording: %s\n' "$gate_dir/screen-recording.mp4"
        printf 'recorder_exit: %s\n' "$recorder_status"
        printf 'test_exit: %s\n' "$g3_status"
        printf 'evidence_check_exit: %s\n' "$check_status"
        sed 's/^/evidence: /' "$gate_dir/evidence-check.txt"
    } >> "$report"
    gate_status=$g3_status
    if [[ $gate_status -eq 0 ]]; then gate_status=$check_status; fi
    if [[ $gate_status -eq 0 ]]; then gate_status=$recorder_status; fi
    exit "$gate_status"
fi
if [[ "$gate" == G4 ]]; then
    artifacts="$APKRUN_TEST_LINUX_DIR/g4-artifacts"
    g4_status=0
    lockf -k /tmp/apkrun-vm.lock xcodebuild test \
        -project APKRun.xcodeproj \
        -scheme AcceptanceTests \
        -testPlan AcceptanceTests \
        -configuration Debug \
        -only-test-configuration G4 \
        -only-testing:AcceptanceTests/G4NativeWindowTests \
        -test-timeouts-enabled NO \
        -jobs 1 \
        -derivedDataPath "$gate_dir/DerivedData" \
        -resultBundlePath "$gate_dir/$gate.xcresult" \
        "APKRUN_TEST_LINUX_DIR=$APKRUN_TEST_LINUX_DIR" \
        "APKRUN_CI=1" \
        "${signing_arguments[@]}" \
        ${g4_build_settings[@]+"${g4_build_settings[@]}"} || g4_status=$?
    if [[ -d "$artifacts" ]]; then
        rm -rf "$gate_dir/artifacts"
        mkdir -p "$gate_dir/artifacts"
        rsync -a --exclude='/screen-recording.mov' "$artifacts/" "$gate_dir/artifacts/"
        if [[ -f "$artifacts/screen-recording.mov" ]]; then
            mv "$artifacts/screen-recording.mov" "$gate_dir/artifacts/screen-recording.mov"
        fi
    fi
    recording_status=1
    if [[ -f "$gate_dir/artifacts/screen-recording.mov" ]]; then
        if avconvert \
            --preset PresetMediumQuality \
            --source "$gate_dir/artifacts/screen-recording.mov" \
            --output "$gate_dir/screen-recording.mp4"
        then
            recording_status=0
        else
            recording_status=1
        fi
    fi
    if [[ ! -s "$gate_dir/screen-recording.mp4" ]]; then
        recording_status=1
    fi
    check_status=0
    python3 -I "$repo_root/scripts/tools/check-g4-evidence.py" \
        "$gate_dir/artifacts" "$gate_dir/$gate.xcresult" > "$gate_dir/evidence-check.txt" 2>&1 \
        || check_status=$?
    {
        printf 'artifacts: %s\n' "$gate_dir/artifacts"
        printf 'screen_recording: %s\n' "$gate_dir/screen-recording.mp4"
        printf 'recording_conversion_exit: %s\n' "$recording_status"
        printf 'test_exit: %s\n' "$g4_status"
        printf 'evidence_check_exit: %s\n' "$check_status"
        sed 's/^/evidence: /' "$gate_dir/evidence-check.txt"
    } >> "$report"
    # Keep one compact recording after evidence validation and avoid retaining a duplicate raw movie under /tmp.
    if [[ $check_status -eq 0 && $recording_status -eq 0 ]]; then
        rm -f "$gate_dir/artifacts/screen-recording.mov"
    fi
    gate_status=$g4_status
    if [[ $gate_status -eq 0 ]]; then gate_status=$check_status; fi
    if [[ $gate_status -eq 0 ]]; then gate_status=$recording_status; fi
    exit "$gate_status"
fi
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
