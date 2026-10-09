#!/usr/bin/env bash
# Builds the development Guest Agent APK (build-system.md §7.1, guest-components.md §2, #072).
#
#   scripts/build-guest.sh                       build Guest/build/out/apkrun-guest.apk and its version record
#   scripts/build-guest.sh --version-code N --out DIR
#                                                build with another versionCode into DIR (the reinstall test)
#
# The APK is signed with the test-only development key Tests/Fixtures/signing/test-guest-dev.jks, and the script
# fails unless the signer is that key. The versionCode is major * 1 000 000 + minor * 1 000 + patch of the
# MARKETING_VERSION in project.yml (build-system.md §7.1). The version record `apkrun-guest.json` next to the APK
# is what the host reads before it installs (guest-components.md §3.1). The host build copies both files into
# APKRun.app/Contents/Resources/guest/.
#
# Needs a JDK that Gradle can run (17 or newer), and ANDROID_HOME with build-tools 37.0.0 (environment-setup.md §2.5).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
guest_dir="$repo_root/Guest"
# Gradle signs with the key of Tests/Fixtures/signing/test-guest-dev.jks (Guest/guestd/build.gradle.kts).
build_tools_version="37.0.0"
# The SHA-256 of the DER certificate of test-guest-dev.jks. Any other signer fails the build.
expected_signer_sha256="c58db702f39e9b809ad166d173f165478b4c7cb718d4d0cc89ebe8956438c900"
package_name="io.apkrun.guest"

out_dir="$guest_dir/build/out"
version_code_override=""

usage() {
    printf 'usage: scripts/build-guest.sh [--version-code N] [--out DIR]\n' >&2
    exit 64
}

while (($# > 0)); do
    case "$1" in
        --version-code)
            (($# >= 2)) || usage
            version_code_override="$2"
            shift 2
            ;;
        --out)
            (($# >= 2)) || usage
            out_dir="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done

if [[ -n "$version_code_override" && ! "$version_code_override" =~ ^[0-9]+$ ]]; then
    printf 'build-guest: --version-code must be a whole number\n' >&2
    exit 64
fi

android_home="${ANDROID_HOME:-$repo_root/build/android-sdk}"
apksigner="$android_home/build-tools/$build_tools_version/apksigner"
if [[ ! -x "$apksigner" ]]; then
    printf 'build-guest: %s is missing (environment-setup.md §2.5)\n' "$apksigner" >&2
    exit 78
fi

marketing_version="$(sed -n 's/^ *MARKETING_VERSION: *"\([0-9][0-9.]*\)".*/\1/p' "$repo_root/project.yml" | head -1)"
if [[ ! "$marketing_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    printf 'build-guest: MARKETING_VERSION in project.yml is not major.minor.patch\n' >&2
    exit 1
fi
version_code=$((BASH_REMATCH[1] * 1000000 + BASH_REMATCH[2] * 1000 + BASH_REMATCH[3]))
if [[ -n "$version_code_override" ]]; then
    version_code="$version_code_override"
fi
git_revision="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
version_name="$marketing_version+$git_revision"

"$repo_root/gradlew" -p "$guest_dir" --console=plain \
    -PapkrunGuestVersionCode="$version_code" \
    -PapkrunGuestVersionName="$version_name" \
    :guestd:assembleRelease

shopt -s nullglob
built=("$guest_dir"/guestd/build/outputs/apk/release/*.apk)
shopt -u nullglob
if ((${#built[@]} != 1)); then
    printf 'build-guest: expected one release APK under guestd/build/outputs, found %s\n' "${#built[@]}" >&2
    exit 1
fi

signers="$("$apksigner" verify --print-certs "${built[0]}" | awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
if [[ -z "$signers" || "$signers" != "$expected_signer_sha256" ]]; then
    printf 'build-guest: %s is not signed by the test guest key (signer %s)\n' "${built[0]}" "$signers" >&2
    exit 1
fi

mkdir -p "$out_dir"
cp "${built[0]}" "$out_dir/apkrun-guest.apk"
printf '{\n  "packageName": "%s",\n  "versionCode": %s,\n  "versionName": "%s"\n}\n' \
    "$package_name" "$version_code" "$version_name" > "$out_dir/apkrun-guest.json"
printf 'build-guest: wrote %s (versionCode %s)\n' "$out_dir/apkrun-guest.apk" "$version_code"
