#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
script="$repo_root/scripts/dev/make-wrapper.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf -- "$temporary_root"' EXIT

fixture_home="$temporary_root/home"
launcher_app="$temporary_root/APKRunLauncher.app"
launcher_executable="$launcher_app/Contents/MacOS/APKRunLauncher"
fixture_bin="$temporary_root/bin"
mkdir -p "$fixture_home" "$launcher_app/Contents/MacOS" "$fixture_bin"

cat >"$launcher_executable" <<'LAUNCHER'
#!/bin/sh
exit 0
LAUNCHER
chmod 0755 "$launcher_executable"

python3 - "$launcher_app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as output:
    plistlib.dump(
        {
            "CFBundleShortVersionString": "0.1.0",
            "APKRunLauncherAPI": "1.15",
            "APKRunMinimumRuntimeVersion": "0.1.0",
        },
        output,
        fmt=plistlib.FMT_XML,
        sort_keys=True,
    )
PY

cat >"$fixture_bin/lipo" <<'SH'
#!/bin/sh
if [ "$1" != "-archs" ] || [ "$#" -ne 2 ]; then
    exit 64
fi
printf '%s\n' "${APKRUN_FIXTURE_ARCHS:-arm64}"
SH
cat >"$fixture_bin/codesign" <<'SH'
#!/bin/sh
case "$1" in
    --force)
        printf 'sign|%s\n' "$*" >>"$APKRUN_CODESIGN_LOG"
        ;;
    --verify)
        printf 'verify|%s\n' "$*" >>"$APKRUN_CODESIGN_LOG"
        ;;
    *)
        exit 64
        ;;
esac
if [ "${APKRUN_FIXTURE_CODESIGN_FAIL:-0}" = 1 ]; then
    printf 'simulated codesign failure\n' >&2
    exit 23
fi
SH
cat >"$fixture_bin/apkrun" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$APKRUN_CLI_LOG"
SH
chmod 0755 "$fixture_bin/lipo" "$fixture_bin/codesign" "$fixture_bin/apkrun"

cli_log="$temporary_root/path-cli.log"
codesign_log="$temporary_root/codesign.log"
wrapper_output="$temporary_root/wrappers"
mkdir -p "$wrapper_output"
printf 'preserve\n' >"$wrapper_output/user-data.txt"

run_with_path_cli() {
    env \
        HOME="$fixture_home" \
        PATH="$fixture_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        APKRUN_LAUNCHER_APP="$launcher_app" \
        APKRUN_LIPO="$fixture_bin/lipo" \
        APKRUN_CODESIGN="$fixture_bin/codesign" \
        APKRUN_CODESIGN_LOG="$codesign_log" \
        APKRUN_CLI_LOG="$cli_log" \
        "$@"
}

run_with_path_cli "$script" io.apkrun.fixture.hellotext "$wrapper_output"
wrapper="$wrapper_output/HelloText.app"
[[ -d "$wrapper" ]]
[[ "$(cat "$wrapper/Contents/PkgInfo")" == 'APPL????' ]]
[[ "$(cat "$wrapper/Contents/MacOS/APKRunLauncher")" == "$(cat "$launcher_executable")" ]]
[[ "$(cat "$wrapper_output/user-data.txt")" == preserve ]]
[[ "$(cat "$cli_log")" == $'wrapper\napprove\n--yes\n'"$wrapper" ]]

python3 - "$wrapper" <<'PY'
import json
import pathlib
import plistlib
import sys

wrapper = pathlib.Path(sys.argv[1])
with (wrapper / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
document_path = wrapper / "Contents/Resources/wrapper.json"
document_bytes = document_path.read_bytes()
document = json.loads(document_bytes)
assert info["CFBundleIdentifier"] == "io.apkrun.android.io.apkrun.fixture.hellotext"
assert info["CFBundleName"] == "HelloText"
assert info["CFBundleDisplayName"] == "HelloText"
assert info["CFBundleExecutable"] == "APKRunLauncher"
assert info["APKRunPackageID"] == "io.apkrun.fixture.hellotext"
assert info["APKRunLauncherVersion"] == "0.1.0"
assert info["APKRunLauncherAPI"] == "1.15"
assert (wrapper / "Contents/MacOS/APKRunLauncher").stat().st_mode & 0o777 == 0o755
assert (wrapper / "Contents/Info.plist").stat().st_mode & 0o777 == 0o644
assert (wrapper / "Contents/Resources/wrapper.json").stat().st_mode & 0o777 == 0o644
assert document == {
    "application": {
        "displayName": "HelloText",
        "packageId": "io.apkrun.fixture.hellotext",
    },
    "formatVersion": 1,
    "integration": {},
    "kind": "local",
    "runtime": {"launcherAPI": "1.15", "minimumVersion": "0.1.0"},
    "window": {
        "defaultHeight": 850,
        "defaultWidth": 480,
        "mode": "standard",
        "resizable": True,
    },
}
assert document_bytes.endswith(b"\n")
assert b"versionCode" not in document_bytes
assert b"versionName" not in document_bytes
assert b"apkPath" not in document_bytes
assert b"digest" not in document_bytes
PY

grep -Fq -- 'sign|--force --sign - --identifier io.apkrun.android.io.apkrun.fixture.hellotext --options runtime --timestamp=none ' "$codesign_log"
grep -Fq -- 'verify|--verify --strict --all-architectures ' "$codesign_log"

second_output="$temporary_root/second"
mkdir -p "$second_output"
run_with_path_cli "$script" io.apkrun.fixture.hellotext "$second_output"
cmp "$wrapper/Contents/Info.plist" "$second_output/HelloText.app/Contents/Info.plist"
cmp "$wrapper/Contents/Resources/wrapper.json" \
    "$second_output/HelloText.app/Contents/Resources/wrapper.json"

minimum_output="$temporary_root/minimum"
mkdir -p "$minimum_output"
run_with_path_cli "$script" io.apkrun.fixture.hellotext "$minimum_output" \
    --minimum-version 99.0
python3 - "$minimum_output/HelloText.app/Contents/Resources/wrapper.json" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert document["runtime"]["minimumVersion"] == "99.0.0"
PY

mapped_output="$temporary_root/mapped"
mkdir -p "$mapped_output"
run_with_path_cli "$script" io.example.Foo "$mapped_output"
python3 - "$mapped_output/Foo.app/Contents/Info.plist" io.example.Foo <<'PY'
import hashlib
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
suffix = hashlib.sha256(sys.argv[2].encode()).hexdigest()[:8]
assert info["CFBundleIdentifier"] == f"io.apkrun.android.io.example.Foo-h{suffix}"
PY

mismatch_output="$temporary_root/mismatch"
mkdir -p "$mismatch_output"
run_with_path_cli "$script" io.apkrun.fixture.hellotext "$mismatch_output" \
    --package-id io.apkrun.fixture.wrongpackage
python3 - "$mismatch_output/HelloText.app" <<'PY'
import json
import pathlib
import plistlib
import sys

wrapper = pathlib.Path(sys.argv[1])
with (wrapper / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
document = json.loads((wrapper / "Contents/Resources/wrapper.json").read_text())
assert info["APKRunPackageID"] == "io.apkrun.fixture.wrongpackage"
assert document["application"]["packageId"] == "io.apkrun.fixture.hellotext"
PY

expect_failure() {
    local expected="$1"
    local output="$2"
    shift 2
    if run_with_path_cli "$@" >"$output" 2>&1; then
        cat "$output" >&2
        printf 'Expected command to fail: %s\n' "$*" >&2
        exit 1
    fi
    grep -Fq -- "$expected" "$output" || {
        cat "$output" >&2
        printf 'Expected failure to contain: %s\n' "$expected" >&2
        exit 1
    }
}

sign_failure_output="$temporary_root/sign-failure"
mkdir -p "$sign_failure_output"
printf 'keep\n' >"$sign_failure_output/user-data.txt"
expect_failure \
    'codesign' \
    "$temporary_root/sign-failure.log" \
    env APKRUN_FIXTURE_CODESIGN_FAIL=1 \
    "$script" io.apkrun.fixture.signfailure "$sign_failure_output"
[[ "$(cat "$sign_failure_output/user-data.txt")" == keep ]]
[[ -z "$(find "$sign_failure_output" -maxdepth 1 -name '.apkrun-wrapper.*' -print)" ]]

expect_failure \
    'invalid Android package ID' \
    "$temporary_root/invalid-package.log" \
    "$script" 'io.apkrun.fixture.bad-package' "$temporary_root/invalid-package"
[[ ! -e "$temporary_root/invalid-package" ]]

expect_failure \
    'invalid --minimum-version value' \
    "$temporary_root/invalid-version.log" \
    "$script" io.apkrun.fixture.hellotext "$temporary_root/invalid-version" \
    --minimum-version 01.2
[[ ! -e "$temporary_root/invalid-version" ]]

expect_failure \
    'invalid --package-id value' \
    "$temporary_root/empty-package.log" \
    "$script" io.apkrun.fixture.hellotext "$temporary_root/empty-package" \
    --package-id ''
[[ ! -e "$temporary_root/empty-package" ]]

expect_failure \
    'must contain only the arm64 architecture' \
    "$temporary_root/wrong-arch.log" \
    env APKRUN_FIXTURE_ARCHS='arm64 x86_64' \
    "$script" io.apkrun.fixture.hellotext "$temporary_root/wrong-arch"
[[ ! -e "$temporary_root/wrong-arch" ]]

expect_failure \
    'refusing to replace existing output' \
    "$temporary_root/existing.log" \
    "$script" io.apkrun.fixture.hellotext "$wrapper_output"
[[ "$(cat "$wrapper_output/user-data.txt")" == preserve ]]

symlink_target="$temporary_root/protected"
mkdir -p "$symlink_target"
printf 'safe\n' >"$symlink_target/marker"
ln -s "$symlink_target" "$temporary_root/output-symlink"
expect_failure \
    'refusing to write through a symlinked output directory' \
    "$temporary_root/symlink.log" \
    "$script" io.apkrun.fixture.hellotext "$temporary_root/output-symlink"
[[ "$(cat "$symlink_target/marker")" == safe ]]

missing_cli_output="$temporary_root/missing-cli"
if env \
    HOME="$fixture_home" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    APKRUN_LAUNCHER_APP="$launcher_app" \
    APKRUN_LIPO="$fixture_bin/lipo" \
    APKRUN_CODESIGN="$fixture_bin/codesign" \
    APKRUN_CODESIGN_LOG="$codesign_log" \
    "$script" io.apkrun.fixture.hellotext "$missing_cli_output" \
    >"$temporary_root/missing-cli.log" 2>&1; then
    cat "$temporary_root/missing-cli.log" >&2
    printf 'Expected wrapper generation without apkrun to fail\n' >&2
    exit 1
fi
grep -Fq -- 'apkrun wrapper approve --yes <wrapper.app>' "$temporary_root/missing-cli.log"
[[ ! -e "$missing_cli_output" ]]

embedded_home="$temporary_root/embedded-home"
embedded_cli="$embedded_home/Applications/APKRun Dev.app/Contents/Resources/bin/apkrun"
mkdir -p "$(dirname "$embedded_cli")" "$temporary_root/embedded-output"
cat >"$embedded_cli" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$APKRUN_CLI_LOG"
SH
chmod 0755 "$embedded_cli"
embedded_cli_log="$temporary_root/embedded-cli.log"
env \
    HOME="$embedded_home" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    APKRUN_LAUNCHER_APP="$launcher_app" \
    APKRUN_LIPO="$fixture_bin/lipo" \
    APKRUN_CODESIGN="$fixture_bin/codesign" \
    APKRUN_CODESIGN_LOG="$codesign_log" \
    APKRUN_CLI_LOG="$embedded_cli_log" \
    "$script" io.apkrun.fixture.hellotext "$temporary_root/embedded-output"
[[ "$(cat "$embedded_cli_log")" == $'wrapper\napprove\n--yes\n'"$temporary_root/embedded-output/HelloText.app" ]]

codesign_tool="$(command -v codesign || true)"
lipo_tool="$(command -v lipo || true)"
clang_tool="$(command -v clang || true)"
if [[ "$(uname -s)" == Darwin && -n "$codesign_tool" && -n "$lipo_tool" && -n "$clang_tool" ]]; then
    real_launcher_app="$temporary_root/RealAPKRunLauncher.app"
    real_launcher_executable="$real_launcher_app/Contents/MacOS/APKRunLauncher"
    real_wrapper_output="$temporary_root/real-signed-wrapper"
    real_cli_log="$temporary_root/real-signed-cli.log"
    real_signing_details="$temporary_root/real-signing-details.log"
    mkdir -p "$(dirname "$real_launcher_executable")" "$real_wrapper_output"
    cat >"$temporary_root/minimal-launcher.c" <<'C'
int main(void) {
    return 0;
}
C
    "$clang_tool" -arch arm64 -o "$real_launcher_executable" "$temporary_root/minimal-launcher.c"
    chmod 0755 "$real_launcher_executable"
    python3 - "$real_launcher_app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as output:
    plistlib.dump(
        {
            "APKRunLauncherAPI": "1.15",
            "APKRunLauncherVersion": "0.1.0",
            "APKRunMinimumRuntimeVersion": "0.1.0",
            "CFBundleExecutable": "APKRunLauncher",
            "CFBundleIdentifier": "io.apkrun.APKRunLauncher.test",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
        },
        output,
        fmt=plistlib.FMT_XML,
        sort_keys=True,
    )
PY
    env \
        HOME="$fixture_home" \
        PATH="$fixture_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        APKRUN_LAUNCHER_APP="$real_launcher_app" \
        APKRUN_LIPO="$lipo_tool" \
        APKRUN_CODESIGN="$codesign_tool" \
        APKRUN_CLI_LOG="$real_cli_log" \
        "$script" io.apkrun.fixture.realsignature "$real_wrapper_output"
    real_wrapper="$real_wrapper_output/Realsignature.app"
    [[ "$(cat "$real_cli_log")" == $'wrapper\napprove\n--yes\n'"$real_wrapper" ]]
    "$codesign_tool" --verify --strict --all-architectures "$real_wrapper"
    "$codesign_tool" -dvv "$real_wrapper" 2>"$real_signing_details"
    grep -Fq -- "Identifier=io.apkrun.android.io.apkrun.fixture.realsignature" \
        "$real_signing_details"
    grep -Fq -- 'Signature=adhoc' "$real_signing_details"
else
    printf 'scripts/tests/test_make_wrapper.sh: skipped real codesign subcase (Darwin arm64 tools unavailable)\n'
fi

printf 'scripts/tests/test_make_wrapper.sh: passed\n'
