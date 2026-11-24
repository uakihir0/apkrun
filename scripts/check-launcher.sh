#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'usage: scripts/check-launcher.sh <APKRunLauncher.app|executable>\n' >&2
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

launcher="$1"
if [[ -d "$launcher" ]]; then
    binary="$launcher/Contents/MacOS/APKRunLauncher"
else
    binary="$launcher"
fi

if [[ ! -f "$binary" ]]; then
    printf 'check-launcher: launcher executable does not exist: %s\n' "$binary" >&2
    exit 1
fi

for tool in lipo otool vtool; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'check-launcher: required Xcode tool is unavailable: %s\n' "$tool" >&2
        exit 1
    fi
done

if ! architectures="$(lipo -archs "$binary" 2>&1)"; then
    printf 'check-launcher: lipo could not inspect %s:\n%s\n' "$binary" "$architectures" >&2
    exit 1
fi
if [[ "$architectures" != "arm64" ]]; then
    printf 'check-launcher: expected arm64 only, found: %s\n' "$architectures" >&2
    exit 1
fi
printf 'ok APKRunLauncher contains arm64 only\n'

if ! dependencies="$(otool -L "$binary" 2>&1)"; then
    printf 'check-launcher: otool could not inspect %s:\n%s\n' "$binary" "$dependencies" >&2
    exit 1
fi
if ! python3 - "$dependencies" <<'PY'
import sys

lines = sys.argv[1].splitlines()
if not lines or not lines[0].endswith(":"):
    raise SystemExit("check-launcher: otool returned malformed dependency output")

unexpected = []
for line in lines[1:]:
    dependency = line.strip().split(maxsplit=1)
    if not dependency:
        continue
    path = dependency[0]
    if not path.startswith(("/System/Library/", "/usr/lib/")):
        unexpected.append(path)

if unexpected:
    for path in unexpected:
        print(
            f"check-launcher: unexpected non-system dependency: {path}",
            file=sys.stderr,
        )
    raise SystemExit(1)
PY
then
    exit 1
fi
printf 'ok APKRunLauncher links only system libraries\n'

if ! build_info="$(vtool -show-build "$binary" 2>&1)"; then
    printf 'check-launcher: vtool could not inspect %s:\n%s\n' "$binary" "$build_info" >&2
    exit 1
fi
if ! python3 - "$build_info" <<'PY'
import re
import sys

minimums = re.findall(
    r"^\s*minos\s+([0-9]+(?:\.[0-9]+)*)\s*$",
    sys.argv[1],
    re.MULTILINE,
)
if not minimums:
    raise SystemExit("check-launcher: vtool did not report a minimum OS")

for minimum in minimums:
    parts = tuple(int(part) for part in minimum.split("."))
    normalized = (parts + (0, 0))[:2]
    if normalized < (27, 0):
        raise SystemExit(
            f"check-launcher: minimum macOS must be 27.0 or later, found {minimum}"
        )
PY
then
    exit 1
fi
printf 'ok APKRunLauncher minimum macOS version is 27.0 or later\n'
