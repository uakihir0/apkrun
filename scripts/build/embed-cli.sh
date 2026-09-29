#!/bin/bash

set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
configuration="${CONFIGURATION:-Debug}"
marketing_version="${MARKETING_VERSION:-0.1.0}"
build_number="${CURRENT_PROJECT_VERSION:-1}"
build_identity="${APKRUN_BUILD_IDENTITY:-dev}"
build_stamp="$repo_root/build/generated/BuildStamp.h"

if [[ ! -f "$build_stamp" ]]; then
    printf 'Build stamp is missing: %s\n' "$build_stamp" >&2
    exit 1
fi
git_commit="$(sed -nE 's/^#define APKRUN_GIT_COMMIT ([[:xdigit:]]{7}(-dirty)?)$/\1/p' "$build_stamp")"
if [[ -z "$git_commit" ]]; then
    printf 'Build stamp does not contain a valid commit revision.\n' >&2
    exit 1
fi

case "$configuration" in
    Debug)
        swift_configuration=debug
        bundle_identifier=io.apkrun.cli.dev
        ;;
    Release)
        swift_configuration=release
        bundle_identifier=io.apkrun.cli
        ;;
    *)
        printf 'Unsupported CLI build configuration: %s\n' "$configuration" >&2
        exit 1
        ;;
esac

resource_directory="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/bin"
destination="$resource_directory/apkrun"
plist="${DERIVED_FILE_DIR:?}/apkrun-cli-Info.plist"
mkdir -p "$resource_directory" "$(dirname "$plist")"

plutil -create xml1 "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_identifier" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $marketing_version" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$plist"
/usr/libexec/PlistBuddy -c "Add :APKRunBuildIdentity string $build_identity" "$plist"
/usr/libexec/PlistBuddy -c "Add :APKRunGitCommit string $git_commit" "$plist"
/usr/libexec/PlistBuddy -c "Add :APKRunConfiguration string $configuration" "$plist"

embedded_runtime=false
if [[ "$configuration" == "Debug" ]]; then
    embedded_runtime=true
fi
/usr/libexec/PlistBuddy -c "Add :APKRunEmbeddedRuntime bool $embedded_runtime" "$plist"

linker_arguments=(
    -Xlinker -sectcreate
    -Xlinker __TEXT
    -Xlinker __info_plist
    -Xlinker "$plist"
)
if [[ "$configuration" == "Debug" ]]; then
    swift build --package-path "$repo_root" \
        --configuration "$swift_configuration" \
        --product apkrun \
        --traits EmbeddedRuntime \
        "${linker_arguments[@]}"
else
    swift build --package-path "$repo_root" \
        --configuration "$swift_configuration" \
        --product apkrun \
        "${linker_arguments[@]}"
fi
binary_directory="$(swift build --package-path "$repo_root" \
    --configuration "$swift_configuration" \
    --show-bin-path)"
cp "$binary_directory/apkrun" "$destination"
chmod 0755 "$destination"

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
    signing_arguments=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --identifier "$bundle_identifier")
    if [[ "$configuration" == "Debug" ]]; then
        signing_arguments+=(--entitlements "$repo_root/CLI/apkrun/apkrun-dev.entitlements")
    fi
    /usr/bin/codesign "${signing_arguments[@]}" "$destination"
fi
