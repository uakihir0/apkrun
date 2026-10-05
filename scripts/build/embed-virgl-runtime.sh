#!/usr/bin/env bash
set -euo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

"$repo_root/scripts/build-third-party.sh" virgl-runtime
cache_key="$("$repo_root/scripts/build-third-party.sh" --print-cache-key virgl-runtime)"
runtime_source="$repo_root/ThirdParty/out/virgl-runtime/$cache_key"
runtime_destination="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}/Contents/Frameworks/VirGLRuntime"
libraries=(
    libvirglrenderer.1.dylib
    libepoxy.0.dylib
    libEGL.dylib
    libGLESv2.dylib
)

for library in "${libraries[@]}"; do
    if [[ ! -f "$runtime_source/$library" || -L "$runtime_source/$library" ]]; then
        printf 'Verified VirGL runtime is missing %s; run scripts/build-third-party.sh virgl-runtime.\n' \
            "$runtime_source/$library" >&2
        exit 1
    fi
done

if [[ -L "$runtime_destination" ]]; then
    printf 'Refusing symlinked VirGL runtime destination: %s\n' "$runtime_destination" >&2
    exit 1
fi
rm -rf "$runtime_destination"
mkdir -p "$runtime_destination"
for library in "${libraries[@]}"; do
    /usr/bin/ditto "$runtime_source/$library" "$runtime_destination/$library"
done

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
    for library in "${libraries[@]}"; do
        /usr/bin/codesign \
            --force \
            --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            --identifier "io.apkrun.virglruntime.$library" \
            "$runtime_destination/$library"
    done
fi
