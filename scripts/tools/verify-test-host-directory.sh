#!/usr/bin/env bash
# Checks that a built test host reads the artifact directory the gate passed to it.
#
#   scripts/tools/verify-test-host-directory.sh HOST_APP DIRECTORY [--android-bundle BUNDLE]
#       [--require-composed 0|1] [--g3-bundle BUNDLE] [--g3-require-composed 0|1]
#
# The acceptance harness reads the gate-selected values from the test host's Info.plist. The gate clears inherited
# bundle overrides before building, then verifies that the built plist contains the selected paths and requirement.
set -euo pipefail

if [[ $# -lt 2 ]]; then
    printf 'usage: scripts/tools/verify-test-host-directory.sh HOST_APP DIRECTORY [--android-bundle BUNDLE]\n' >&2
    exit 64
fi
host_app="$1"
directory="$2"
shift 2
android_bundle=""
require_composed=""
g3_bundle=""
g3_require_composed=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    --android-bundle)
        [[ $# -ge 2 && -z "$android_bundle" ]] || exit 64
        android_bundle="$2"
        shift 2
        ;;
    --require-composed)
        [[ $# -ge 2 && -z "$require_composed" && "$2" =~ ^[01]$ ]] || exit 64
        require_composed="$2"
        shift 2
        ;;
    --g3-bundle)
        [[ $# -ge 2 && -z "$g3_bundle" ]] || exit 64
        g3_bundle="$2"
        shift 2
        ;;
    --g3-require-composed)
        [[ $# -ge 2 && -z "$g3_require_composed" && "$2" =~ ^[01]$ ]] || exit 64
        g3_require_composed="$2"
        shift 2
        ;;
    *)
        printf 'verify-test-host-directory: unknown argument %s\n' "$1" >&2
        exit 64
        ;;
    esac
done
plist="$host_app/Contents/Info.plist"
if [[ ! -f "$plist" ]]; then
    printf 'verify-test-host-directory: no test host at %s; build it first\n' "$host_app" >&2
    exit 1
fi
recorded="$(/usr/bin/plutil -extract APKRUN_TEST_LINUX_DIR raw -o - "$plist" 2>/dev/null || true)"
if [[ "$recorded" != "$directory" ]]; then
    printf 'verify-test-host-directory: %s reads "%s", not "%s"\n' "$plist" "$recorded" "$directory" >&2
    exit 1
fi
printf 'verify-test-host-directory: the test host reads %s\n' "$directory"
if [[ -n "$android_bundle" ]]; then
    recorded_bundle="$(/usr/bin/plutil -extract APKRUN_TEST_ANDROID_BUNDLE raw -o - "$plist" 2>/dev/null || true)"
    if [[ "$recorded_bundle" != "$android_bundle" ]]; then
        printf 'verify-test-host-directory: %s reads bundle "%s", not "%s"\n' "$plist" "$recorded_bundle" "$android_bundle" >&2
        exit 1
    fi
    printf 'verify-test-host-directory: the test host reads Android bundle %s\n' "$android_bundle"
fi
if [[ -n "$require_composed" ]]; then
    recorded_requirement="$(/usr/bin/plutil -extract APKRUN_TEST_REQUIRE_COMPOSED raw -o - "$plist" 2>/dev/null || true)"
    if [[ "$recorded_requirement" != "$require_composed" ]]; then
        printf 'verify-test-host-directory: %s requires composed image "%s", not "%s"\n' \
            "$plist" "$recorded_requirement" "$require_composed" >&2
        exit 1
    fi
    printf 'verify-test-host-directory: the test host composed-image requirement is %s\n' "$require_composed"
fi
if [[ -n "$g3_bundle" ]]; then
    recorded_bundle="$(/usr/bin/plutil -extract APKRUN_G3_BUNDLE raw -o - "$plist" 2>/dev/null || true)"
    if [[ "$recorded_bundle" != "$g3_bundle" ]]; then
        printf 'verify-test-host-directory: %s reads G3 bundle "%s", not "%s"\n' \
            "$plist" "$recorded_bundle" "$g3_bundle" >&2
        exit 1
    fi
    recorded_requirement="$(/usr/bin/plutil -extract APKRUN_G3_REQUIRE_COMPOSED raw -o - "$plist" 2>/dev/null || true)"
    if [[ "$recorded_requirement" != "$g3_require_composed" ]]; then
        printf 'verify-test-host-directory: %s requires composed G3 image "%s", not "%s"\n' \
            "$plist" "$recorded_requirement" "$g3_require_composed" >&2
        exit 1
    fi
    printf 'verify-test-host-directory: the test host G3 image and requirement match the gate\n'
fi
