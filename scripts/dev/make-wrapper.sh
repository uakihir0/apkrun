#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"

usage() {
    cat >&2 <<'EOF'
Usage: scripts/dev/make-wrapper.sh <package> <out-dir> [--minimum-version <v>] [--package-id <id>]

Builds a local, ad-hoc-signed wrapper from APKRunLauncher.app. The optional
--package-id changes only Info.plist APKRunPackageID and intentionally creates
a damaged-wrapper fixture when it differs from <package>.

Set APKRUN_LAUNCHER_APP to the generic launcher app or its executable, or
APKRUN_BUILD_PRODUCTS_DIR to the Xcode build products directory. For an
executable outside an app bundle, set APKRUN_LAUNCHER_INFO_PLIST as well.
EOF
}

fail() {
    printf 'make-wrapper: %s\n' "$*" >&2
    exit 1
}

if (($# < 2)); then
    usage
    exit 64
fi

package_id="$1"
output_directory="$2"
shift 2
[[ -n "$output_directory" ]] || fail 'output directory must not be empty'

minimum_version_override=""
package_id_override=""
has_minimum_version_override=false
has_package_id_override=false
while (($#)); do
    case "$1" in
        --minimum-version)
            (($# >= 2)) || {
                usage
                exit 64
            }
            [[ "$has_minimum_version_override" != true ]] || fail '--minimum-version may be specified once'
            minimum_version_override="$2"
            has_minimum_version_override=true
            shift 2
            ;;
        --package-id)
            (($# >= 2)) || {
                usage
                exit 64
            }
            [[ "$has_package_id_override" != true ]] || fail '--package-id may be specified once'
            package_id_override="$2"
            has_package_id_override=true
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

valid_package_id() {
    local value="$1"
    ((${#value} <= 255)) &&
        [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]
}

valid_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$ ]] &&
        ((${#1} <= 32))
}

normalize_version() {
    if [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        printf '%s.%s.0\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf '%s\n' "$1"
    fi
}

valid_package_id "$package_id" || fail "invalid Android package ID: $package_id"
if [[ "$has_package_id_override" == true ]]; then
    valid_package_id "$package_id_override" || fail "invalid --package-id value: $package_id_override"
fi
if [[ "$has_minimum_version_override" == true ]]; then
    valid_version "$minimum_version_override" ||
        fail "invalid --minimum-version value: $minimum_version_override (expected MAJOR.MINOR or MAJOR.MINOR.PATCH)"
fi

resolve_launcher_executable() {
    local candidate
    local -a candidates=()

    if [[ -n "${APKRUN_LAUNCHER_APP:-}" ]]; then
        candidate="$APKRUN_LAUNCHER_APP"
        if [[ -d "$candidate" ]]; then
            [[ ! -L "$candidate" ]] || fail "launcher app is symlinked: $candidate"
            candidates+=("$candidate/Contents/MacOS/APKRunLauncher")
        else
            candidates+=("$candidate")
        fi
    fi

    if [[ -n "${APKRUN_BUILD_PRODUCTS_DIR:-}" ]]; then
        candidates+=("$APKRUN_BUILD_PRODUCTS_DIR/APKRunLauncher.app/Contents/MacOS/APKRunLauncher")
    fi
    if [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
        candidates+=("$BUILT_PRODUCTS_DIR/APKRunLauncher.app/Contents/MacOS/APKRunLauncher")
    fi

    candidates+=(
        "$repo_root/build/Build/Products/Debug/APKRunLauncher.app/Contents/MacOS/APKRunLauncher"
        "$repo_root/build/Build/Products/Release/APKRunLauncher.app/Contents/MacOS/APKRunLauncher"
        "$HOME/Applications/APKRun.app/Contents/Helpers/APKRunLauncher.app/Contents/MacOS/APKRunLauncher"
        "/Applications/APKRun.app/Contents/Helpers/APKRunLauncher.app/Contents/MacOS/APKRunLauncher"
        "$HOME/Applications/APKRun Dev.app/Contents/Helpers/APKRunLauncher.app/Contents/MacOS/APKRunLauncher"
        "/Applications/APKRun Dev.app/Contents/Helpers/APKRunLauncher.app/Contents/MacOS/APKRunLauncher"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" && ! -L "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf 'make-wrapper: generic APKRunLauncher executable not found.\n' >&2
    printf 'Set APKRUN_LAUNCHER_APP or APKRUN_BUILD_PRODUCTS_DIR.\n' >&2
    return 1
}

launcher_executable="$(resolve_launcher_executable)" ||
    fail 'build APKRunLauncher.app before creating a wrapper'

if [[ -L "$launcher_executable" || ! -f "$launcher_executable" ]]; then
    fail "launcher executable is missing or symlinked: $launcher_executable"
fi
launcher_architectures="$("${APKRUN_LIPO:-/usr/bin/lipo}" -archs "$launcher_executable")" ||
    fail "could not inspect launcher architectures: $launcher_executable"
[[ "$launcher_architectures" == arm64 ]] ||
    fail "launcher must contain only the arm64 architecture: $launcher_executable (found: $launcher_architectures)"

launcher_app=""
launcher_contents=""
launcher_parent="$(dirname "$launcher_executable")"
if [[ "$(basename "$launcher_parent")" == MacOS ]]; then
    launcher_contents="$(dirname "$launcher_parent")"
    launcher_app="$(dirname "$launcher_contents")"
    [[ ! -L "$launcher_app" ]] || fail "launcher app is symlinked: $launcher_app"
fi
launcher_info="${APKRUN_LAUNCHER_INFO_PLIST:-$launcher_contents/Info.plist}"
[[ -n "$launcher_info" && -f "$launcher_info" && ! -L "$launcher_info" ]] ||
    fail "launcher template is missing its app Info.plist: $launcher_executable"

launcher_version="${APKRUN_LAUNCHER_VERSION:-}"
launcher_api="${APKRUN_LAUNCHER_API:-}"
template_minimum_version="${APKRUN_LAUNCHER_MINIMUM_VERSION:-}"
if [[ -z "$launcher_version" ]]; then
    launcher_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$launcher_info" 2>/dev/null || true)"
fi
if [[ -z "$launcher_api" ]]; then
    launcher_api="$(/usr/libexec/PlistBuddy -c 'Print :APKRunLauncherAPI' "$launcher_info" 2>/dev/null || true)"
fi
if [[ -z "$template_minimum_version" ]]; then
    template_minimum_version="$(/usr/libexec/PlistBuddy -c 'Print :APKRunMinimumRuntimeVersion' "$launcher_info" 2>/dev/null || true)"
fi
if [[ -z "$launcher_api" ]]; then
    # The hand-built development fixture can derive the API version from this checkout.
    launcher_api="$(sed -nE 's/.*public static let current = APIVersion\(major: ([0-9]+), minor: ([0-9]+)\).*/\1.\2/p' \
        "$repo_root/Packages/RuntimeAPI/Sources/RuntimeAPI/RuntimeAPI.swift" | head -n 1)"
fi
[[ -n "$launcher_version" ]] || fail "launcher template does not contain CFBundleShortVersionString"
valid_version "$launcher_version" || fail "invalid launcher version in template: $launcher_version"
[[ -n "$launcher_api" ]] || fail "could not determine the launcher RuntimeAPI version"
[[ "$launcher_api" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail "invalid launcher API version in template: $launcher_api"
((${#launcher_api} <= 16)) || fail "launcher API version is too long: $launcher_api"

minimum_version="$minimum_version_override"
if [[ -z "$minimum_version" ]]; then
    minimum_version="${template_minimum_version:-$launcher_version}"
fi
valid_version "$minimum_version" || fail "invalid launcher minimum runtime version: $minimum_version"
minimum_version="$(normalize_version "$minimum_version")"
valid_version "$minimum_version" ||
    fail "invalid normalized launcher minimum runtime version: $minimum_version"

apkrun_command=""
if [[ -n "${APKRUN_CLI:-}" ]]; then
    [[ -x "$APKRUN_CLI" && ! -d "$APKRUN_CLI" ]] ||
        fail "APKRUN_CLI is not an executable file: $APKRUN_CLI"
    apkrun_command="$APKRUN_CLI"
elif command -v apkrun >/dev/null 2>&1; then
    apkrun_command="$(command -v apkrun)"
elif [[ -x "$HOME/Applications/APKRun.app/Contents/Resources/bin/apkrun" ]]; then
    apkrun_command="$HOME/Applications/APKRun.app/Contents/Resources/bin/apkrun"
elif [[ -x "/Applications/APKRun.app/Contents/Resources/bin/apkrun" ]]; then
    apkrun_command="/Applications/APKRun.app/Contents/Resources/bin/apkrun"
elif [[ -x "$HOME/Applications/APKRun Dev.app/Contents/Resources/bin/apkrun" ]]; then
    apkrun_command="$HOME/Applications/APKRun Dev.app/Contents/Resources/bin/apkrun"
elif [[ -x "/Applications/APKRun Dev.app/Contents/Resources/bin/apkrun" ]]; then
    apkrun_command="/Applications/APKRun Dev.app/Contents/Resources/bin/apkrun"
fi
if [[ "$has_package_id_override" != true || "$package_id_override" == "$package_id" ]]; then
    [[ -n "$apkrun_command" ]] ||
        fail "apkrun is required to approve the wrapper; expected: apkrun wrapper approve --yes <wrapper.app> (add apkrun to PATH or install APKRun.app)"
fi

if [[ -L "$output_directory" ]]; then
    fail "refusing to write through a symlinked output directory: $output_directory"
fi
if [[ -e "$output_directory" && ! -d "$output_directory" ]]; then
    fail "output path is not a directory: $output_directory"
fi
mkdir -p "$output_directory"
output_directory="$(cd -P "$output_directory" && pwd -P)"

package_name="${package_id##*.}"
package_name_lower="$(printf '%s' "$package_name" | tr '[:upper:]' '[:lower:]')"
if [[ "$package_name_lower" == hellotext ]]; then
    display_name="HelloText"
else
    display_name="${package_name//_/ }"
    display_name="${display_name//-/ }"
    display_name="$(python3 -c 'import sys; print(sys.argv[1].title())' "$display_name")"
fi

file_name="$display_name"
file_name="${file_name//\//-}"
file_name="${file_name//:/-}"
file_name="$(printf '%s' "$file_name" | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//g; s/^\.+//')"
[[ -n "$file_name" ]] || file_name="$package_name"
file_name="$(python3 -c '
import sys
import unicodedata
value = unicodedata.normalize("NFC", sys.argv[1])
result = []
size = 0
for char in value:
    encoded = char.encode("utf-8")
    if size + len(encoded) > 200:
        break
    result.append(char)
    size += len(encoded)
print("".join(result))
' "$file_name")"
[[ -n "$file_name" ]] || fail "could not derive a wrapper file name from $package_id"

bundle_id="$(python3 - "$package_id" <<'PY'
import hashlib
import re
import sys

package_id = sys.argv[1]
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+", package_id):
    raise SystemExit("invalid package ID")
mapped = package_id.replace("_", "-")
if any("A" <= character <= "Z" for character in package_id):
    mapped += "-h" + hashlib.sha256(package_id.encode("utf-8")).hexdigest()[:8]
bundle_id = "io.apkrun.android." + mapped
if len(bundle_id.encode("utf-8")) > 255:
    raise SystemExit("mapped bundle identifier exceeds 255 bytes")
print(bundle_id)
PY
)" || fail 'could not map the Android package ID to a bundle identifier'

wrapper_package_id="$package_id"
info_package_id="${package_id_override:-$package_id}"
bundle_path="$output_directory/$file_name.app"
if [[ -e "$bundle_path" || -L "$bundle_path" ]]; then
    fail "refusing to replace existing output: $bundle_path"
fi

staging_directory="$(mktemp -d "$output_directory/.apkrun-wrapper.XXXXXX")" ||
    fail "could not create a staging directory in $output_directory"
staging_bundle="$staging_directory/$file_name.app"

cleanup() {
    local status=$?
    if [[ -n "${staging_directory:-}" && -d "$staging_directory" &&
        "$staging_directory" == "$output_directory"/.apkrun-wrapper.* ]]; then
        rm -rf -- "$staging_directory"
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

contents="$staging_bundle/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$launcher_executable" "$contents/MacOS/APKRunLauncher"
chmod 0755 "$contents/MacOS/APKRunLauncher"
cmp -s "$launcher_executable" "$contents/MacOS/APKRunLauncher" ||
    fail 'the launcher executable copy does not match its template'

python3 - "$contents/Info.plist" "$contents/Resources/wrapper.json" \
    "$bundle_id" "$info_package_id" "$wrapper_package_id" "$display_name" "$file_name" \
    "$launcher_version" "$launcher_api" "$minimum_version" "$package_id" <<'PY'
import json
import plistlib
import re
import sys

(
    info_path,
    wrapper_path,
    bundle_id,
    info_package_id,
    wrapper_package_id,
    display_name,
    file_name,
    launcher_version,
    launcher_api,
    minimum_version,
    package_id,
) = sys.argv[1:]

info = {
    "APKRunLauncherAPI": launcher_api,
    "APKRunLauncherVersion": launcher_version,
    "APKRunPackageID": info_package_id,
    "APKRunWrapperFormat": 1,
    "APKRunWrapperKind": "local",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": display_name,
    "CFBundleExecutable": "APKRunLauncher",
    "CFBundleIdentifier": bundle_id,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleLocalizations": ["en", "ja"],
    "CFBundleName": file_name,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "27.0",
    "LSMultipleInstancesProhibited": True,
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSQuitAlwaysKeepsWindows": False,
    "NSSupportsAutomaticTermination": False,
    "NSSupportsSuddenTermination": False,
}
with open(info_path, "wb") as output:
    plistlib.dump(info, output, fmt=plistlib.FMT_XML, sort_keys=True)

document = {
    "formatVersion": 1,
    "kind": "local",
    "application": {
        "packageId": wrapper_package_id,
        "displayName": display_name,
    },
    "runtime": {
        "minimumVersion": minimum_version,
        "launcherAPI": launcher_api,
    },
    "window": {
        "mode": "standard",
        "defaultWidth": 480,
        "defaultHeight": 850,
        "resizable": True,
    },
    "integration": {},
}
with open(wrapper_path, "w", encoding="utf-8", newline="\n") as output:
    json.dump(document, output, ensure_ascii=False, indent=2, sort_keys=True)
    output.write("\n")
PY

printf 'APPL????' >"$contents/PkgInfo"
chmod 0755 "$staging_bundle" "$contents" "$contents/MacOS" "$contents/Resources"
chmod 0644 "$contents/Info.plist" "$contents/PkgInfo" "$contents/Resources/wrapper.json"

"${APKRUN_CODESIGN:-/usr/bin/codesign}" \
    --force --sign - --identifier "$bundle_id" --options runtime --timestamp=none "$staging_bundle"
"${APKRUN_CODESIGN:-/usr/bin/codesign}" \
    --verify --strict --all-architectures "$staging_bundle"

mv -n "$staging_bundle" "$bundle_path"
[[ ! -e "$staging_bundle" && -d "$bundle_path" && ! -L "$bundle_path" ]] ||
    fail "output appeared during generation; preserved existing path: $bundle_path"

if [[ "$has_package_id_override" == true && "$package_id_override" != "$package_id" ]]; then
    printf 'Created damaged-wrapper fixture without approval: %s\n' "$bundle_path"
    printf 'Info.plist APKRunPackageID is %s; wrapper.json packageId is %s.\n' \
        "$package_id_override" "$package_id"
    exit 0
fi

"$apkrun_command" wrapper approve --yes "$bundle_path"
printf 'Created and approved wrapper: %s\n' "$bundle_path"
