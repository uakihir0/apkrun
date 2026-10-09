#!/usr/bin/env bash
# Checks that a built test host reads the artifact directory the gate passed to it.
#
#   scripts/tools/verify-test-host-directory.sh HOST_APP DIRECTORY
#
# The test harness reads APKRUN_TEST_LINUX_DIR from the process environment first, then from the host's
# Info.plist. The gate passes the directory as a build setting, which the host's Info.plist expands at build
# time, so the built plist shows what the tests will read (IR-376).
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: scripts/tools/verify-test-host-directory.sh HOST_APP DIRECTORY\n' >&2
    exit 64
fi
plist="$1/Contents/Info.plist"
directory="$2"
if [[ ! -f "$plist" ]]; then
    printf 'verify-test-host-directory: no test host at %s; build it first\n' "$1" >&2
    exit 1
fi
recorded="$(/usr/bin/plutil -extract APKRUN_TEST_LINUX_DIR raw -o - "$plist" 2>/dev/null || true)"
if [[ "$recorded" != "$directory" ]]; then
    printf 'verify-test-host-directory: %s reads "%s", not "%s"\n' "$plist" "$recorded" "$directory" >&2
    exit 1
fi
printf 'verify-test-host-directory: the test host reads %s\n' "$directory"
