#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: scripts/run-gate.sh G1|G2|G3\n' >&2
    exit 64
fi

gate="$1"
if [[ "$gate" != G1 && "$gate" != G2 && "$gate" != G3 ]]; then
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
# The G3 inputs, set once the G3 artifacts are staged. Empty for G1 and G2.
g3_build_settings=()
g2_build_settings=()

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
    # G3 accepts a composed image by default. Set APKRUN_G3_REQUIRE_COMPOSED=0 to run the stock-image baseline.
    # The selected bundle is external to the production tree (IR-1112); ImageStore verifies its signature and files.
    g3_bundle="${APKRUN_G3_ANDROID_BUNDLE:-}"
    g3_require_composed="${APKRUN_G3_REQUIRE_COMPOSED:-1}"
    if [[ "$g3_require_composed" != 0 && "$g3_require_composed" != 1 ]]; then
        printf 'run-gate: APKRUN_G3_REQUIRE_COMPOSED must be 0 or 1\n' >&2
        exit 64
    fi
    if [[ "$g3_bundle" != /* || ! -f "$g3_bundle/manifest.json" || ! -f "$g3_bundle/SHA256SUMS" ]]; then
        printf 'run-gate: G3 needs APKRUN_G3_ANDROID_BUNDLE, the absolute path of an Android bundle\n' >&2
        exit 78
    fi
    if ! (cd "$g3_bundle" && shasum -a 256 -c SHA256SUMS > /dev/null); then
        printf 'run-gate: the checksums of %s do not match SHA256SUMS\n' "$g3_bundle" >&2
        exit 1
    fi
    bundle_options=()
    if [[ "$g3_require_composed" == 0 ]]; then
        bundle_options=(--allow-stock)
    fi
    if ! python3 -I "$script_dir/tools/verify-composed-image-bundle.py" \
        "${bundle_options[@]}" "$g3_bundle"; then
        printf 'run-gate: the selected G3 image bundle does not meet its image requirement\n' >&2
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
if [[ "$gate" == G2 ]]; then
    g2_bundle="${APKRUN_G2_ANDROID_BUNDLE:-}"
    if [[ -z "$g2_bundle" ]]; then
        # The default G2 run remains the stock-image check.
        scripts/build-test-android-bundle.sh
        g2_bundle="$APKRUN_TEST_LINUX_DIR/android-bundle"
        g2_require_composed=0
    else
        if [[ "$g2_bundle" != /* || ! -f "$g2_bundle/manifest.json" || ! -f "$g2_bundle/SHA256SUMS" ]]; then
            printf 'run-gate: APKRUN_G2_ANDROID_BUNDLE must name an absolute, complete image bundle\n' >&2
            exit 78
        fi
        if ! (cd "$g2_bundle" && shasum -a 256 -c SHA256SUMS > /dev/null); then
            printf 'run-gate: the checksums of %s do not match SHA256SUMS\n' "$g2_bundle" >&2
            exit 1
        fi
        if ! python3 -I "$script_dir/tools/verify-composed-image-bundle.py" "$g2_bundle"; then
            printf 'run-gate: the G2 override must be a composed APKRun image bundle\n' >&2
            exit 1
        fi
        g2_require_composed=1
    fi
    g2_build_settings=(
        "APKRUN_TEST_ANDROID_BUNDLE=$g2_bundle"
        "APKRUN_TEST_REQUIRE_COMPOSED=$g2_require_composed"
    )
fi

mkdir -p "$gate_dir"
rm -rf "$gate_dir/DerivedData" "$gate_dir/LinuxGuest.xcresult" "$gate_dir/$gate.xcresult"
# The gate runs the spec's values. A dwell override in the environment would change the evidence, so both
# variables are removed before any test runs. G2 holds each boot for the default 600 s (gate G2, roadmap.md §2).
unset APKRUN_G2_DWELL_SECONDS TEST_RUNNER_APKRUN_G2_DWELL_SECONDS
# The test harness reads bundle paths from the built Info.plist. An inherited process variable must not
# override the bundle whose path and hashes this gate records.
unset APKRUN_TEST_ANDROID_BUNDLE APKRUN_G3_BUNDLE APKRUN_G3_REQUIRE_COMPOSED
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
        printf 'bundle: %s\n' "$g2_bundle"
        printf 'bundle_manifest_sha256: %s\n' "$(shasum -a 256 "$g2_bundle/manifest.json" | awk '{ print $1 }')"
        printf 'bundle_sha256sums_sha256: %s\n' "$(shasum -a 256 "$g2_bundle/SHA256SUMS" | awk '{ print $1 }')"
    fi
    if [[ "$gate" == G3 ]]; then
        printf 'bundle: %s\n' "$g3_bundle"
        printf 'bundle_manifest_sha256: %s\n' "$(shasum -a 256 "$g3_bundle/manifest.json" | awk '{ print $1 }')"
        printf 'bundle_sha256sums_sha256: %s\n' "$(shasum -a 256 "$g3_bundle/SHA256SUMS" | awk '{ print $1 }')"
        printf 'bundle_validation: SHA256SUMS and selected image requirement verified; ImageStore verifies signature and files on install\n'
        printf 'requires_composed_image: %s\n' "$g3_require_composed"
        printf 'bundle_image_version: %s (manifest.json)\n' \
            "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["imageVersion"])' "$g3_bundle/manifest.json")"
        printf 'cli_traits: EmbeddedRuntime,TestReadback\n'
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
# Both gates run the LinuxGuest suite, whose layout test reads the Android disks. Every gate rebuilds them, so no
# run depends on disks left by an earlier build.
scripts/build-test-android-disks.sh
if [[ "$gate" == G3 ]]; then
    # HelloGL and the Debug CLI with the TestReadback trait (graphics.md §7).
    # The composed image owns its persistent Guest Agent; G3 boots without staging or installing a second agent.
    # The files the test host reads are copied under the shared test directory, outside ~/Documents, so the test host
    # can read them without a file-access prompt (as G2 does for its bundle).
    export ANDROID_HOME="$g3_android_home"
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
    mkdir -p "$staging/cli" "$staging/android-sdk"
    cp "$gate_dir/products/Resources/bin/apkrun" "$staging/cli/apkrun"
    cp -RL "$g3_virgl" "$staging/virgl-runtime"
    cp -R "$g3_android_home/platform-tools" "$staging/android-sdk/platform-tools"
    cp Tests/Fixtures/AndroidApps/out/HelloGL.apk "$staging/HelloGL.apk"
    # The test host reads these from its Info.plist, where the build settings land (IntegrationTests/Host/Info.plist).
    g3_build_settings=(
        "APKRUN_G3_CLI=$staging/cli/apkrun"
        "APKRUN_G3_BUNDLE=$g3_bundle"
        "APKRUN_G3_REQUIRE_COMPOSED=$g3_require_composed"
        "APKRUN_G3_APK=$staging/HelloGL.apk"
        "APKRUN_G3_VIRGL_RUNTIME=$staging/virgl-runtime"
        "APKRUN_G3_ANDROID_HOME=$staging/android-sdk"
        "APKRUN_G3_ARTIFACTS=$APKRUN_TEST_LINUX_DIR/g3-artifacts"
    )
    {
        printf 'cli_sha256: %s\n' "$(shasum -a 256 "$staging/cli/apkrun" | awk '{ print $1 }')"
        printf 'cli_commit: %s\n' "$(sed -n 's/^#define APKRUN_GIT_COMMIT \(.*\)$/\1/p' "$repo_root/build/generated/BuildStamp.h")"
        printf 'hellogl_apk_sha256: %s\n' "$(shasum -a 256 "$staging/HelloGL.apk" | awk '{ print $1 }')"
        printf 'guest_agent: image-managed; CLI provisioning disabled\n'
        printf 'virgl_runtime: %s\n' "$g3_virgl"
        printf 'android_sdk: %s\n' "$g3_android_home"
    } >> "$report"
fi
artifact_options=()
if [[ "$gate" == G2 ]]; then
    artifact_options=(--android-bundle "$g2_bundle")
fi
scripts/tools/verify-gate-artifacts.sh "$APKRUN_TEST_LINUX_DIR" "$gate" "${artifact_options[@]}"
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
    ${g2_build_settings[@]+"${g2_build_settings[@]}"} \
    ${g3_build_settings[@]+"${g3_build_settings[@]}"}
if [[ "$gate" == G2 ]]; then
    scripts/tools/verify-test-host-directory.sh \
        "$gate_dir/DerivedData/Build/Products/Debug/APKRunTestHost.app" \
        "$APKRUN_TEST_LINUX_DIR" \
        --android-bundle "$g2_bundle" \
        --require-composed "$g2_require_composed"
elif [[ "$gate" == G3 ]]; then
    scripts/tools/verify-test-host-directory.sh \
        "$gate_dir/DerivedData/Build/Products/Debug/APKRunTestHost.app" \
        "$APKRUN_TEST_LINUX_DIR" \
        --g3-bundle "$g3_bundle" \
        --g3-require-composed "$g3_require_composed"
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
    "${signing_arguments[@]}" \
    ${g2_build_settings[@]+"${g2_build_settings[@]}"}
if [[ "$gate" == G3 ]]; then
    # The G3 check runs one boot in the G3 configuration (graphics.md §14). It is serialised with the other VM runs
    # by lockf (test-strategy §3.6). The artifacts stay outside ~/Documents until the run ends, and the gate copies them.
    artifacts="$APKRUN_TEST_LINUX_DIR/g3-artifacts"
    rm -rf "$artifacts"
    xcodebuild build-for-testing \
        -project APKRun.xcodeproj \
        -scheme AcceptanceTests \
        -testPlan AcceptanceTests \
        -configuration Debug \
        -jobs 1 \
        -derivedDataPath "$gate_dir/DerivedData" \
        "APKRUN_TEST_LINUX_DIR=$APKRUN_TEST_LINUX_DIR" \
        "APKRUN_CI=1" \
        "${signing_arguments[@]}" \
        ${g3_build_settings[@]+"${g3_build_settings[@]}"}
    scripts/tools/verify-test-host-directory.sh \
        "$gate_dir/DerivedData/Build/Products/Debug/APKRunTestHost.app" \
        "$APKRUN_TEST_LINUX_DIR" \
        --g3-bundle "$g3_bundle" \
        --g3-require-composed "$g3_require_composed"
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
    "${signing_arguments[@]}" \
    ${g2_build_settings[@]+"${g2_build_settings[@]}"}
