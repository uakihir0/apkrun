#!/usr/bin/env bash
# Copies the inputs that the hosted LinuxGuest tests read from the artifact directory, so that they never read the
# checkout under ~/Documents (IR-600):
#
#   scanout-00-1024x768-60.edid       the golden EDID block of the gpu check
#   virgl-runtime/<four libraries>    the host VirGL runtime that ThirdParty/out/virgl-runtime/current names
#
#   scripts/tools/stage-hosted-test-inputs.sh REPOSITORY_ROOT ARTIFACT_DIRECTORY
#
# Every input is checked before anything is written. The runtime is copied, not built: when it is missing, this script
# stops with the scripts/build-third-party.sh remediation.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: scripts/tools/stage-hosted-test-inputs.sh REPOSITORY_ROOT ARTIFACT_DIRECTORY\n' >&2
    exit 64
fi
repo_root="$1"
output_dir="$2"

edid_name="scanout-00-1024x768-60.edid"
edid_source="$repo_root/Tests/Fixtures/graphics/edid/$edid_name"
runtime_source="$repo_root/ThirdParty/out/virgl-runtime/current"
libraries=(
    libvirglrenderer.1.dylib
    libepoxy.0.dylib
    libEGL.dylib
    libGLESv2.dylib
)

if [[ ! -f "$edid_source" || -L "$edid_source" ]]; then
    printf 'stage-hosted-test-inputs: the golden EDID block is missing: %s\n' "$edid_source" >&2
    exit 1
fi
for library in "${libraries[@]}"; do
    if [[ ! -f "$runtime_source/$library" || -L "$runtime_source/$library" ]]; then
        printf 'stage-hosted-test-inputs: VirGL runtime library is missing: %s\n' "$runtime_source/$library" >&2
        printf 'stage-hosted-test-inputs: run scripts/build-third-party.sh virgl-runtime\n' >&2
        exit 1
    fi
done

temporary="$(mktemp -d "$output_dir/.hosted-inputs.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
cp "$edid_source" "$temporary/$edid_name"
mkdir "$temporary/virgl-runtime"
for library in "${libraries[@]}"; do
    cp "$runtime_source/$library" "$temporary/virgl-runtime/$library"
done
rm -rf "$output_dir/virgl-runtime"
mv -f "$temporary/virgl-runtime" "$output_dir/virgl-runtime"
mv -f "$temporary/$edid_name" "$output_dir/$edid_name"
