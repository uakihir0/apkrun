#!/usr/bin/env bash
# Builds the development Guest Agent APK (build-system.md §7.1, guest-components.md §2, #73).
#
#   scripts/build-guest.sh                       build Guest/build/out/apkrun-guest.apk and its version record
#   scripts/build-guest.sh --for-aosp            build Guest/product/prebuilt/ApkRunGuest.apk
#   scripts/build-guest.sh --platform-test-key    build persistent, platform-signed prebuilt APK
#   scripts/build-guest.sh --version-code N --out DIR
#                                                build with another versionCode into DIR (the reinstall test)
#
# The APK is signed with the test-only development key Tests/Fixtures/signing/test-guest-dev.jks, and the script
# fails unless the build signer is that key. `--platform-test-key` re-signs the persistent AOSP prebuilt with
# the public AOSP test platform key. The versionCode is major * 1 000 000 + minor * 1 000 + patch of the
# MARKETING_VERSION in project.yml (build-system.md §7.1). The version record next to the APK is what the host
# reads before it installs (guest-components.md §3.1). The host build copies the development APK into
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
expected_platform_signer_sha256="c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8"
package_name="io.apkrun.guest"
platform_test_key="$repo_root/Tests/Fixtures/signing/aosp-test-platform.pk8"
platform_test_certificate="$repo_root/Tests/Fixtures/signing/aosp-test-platform.x509.pem"

out_dir="$guest_dir/build/out"
version_code_override=""
for_aosp=0
platform_test_key_enabled=0
out_dir_explicit=0

usage() {
    printf 'usage: scripts/build-guest.sh [--version-code N] [--out DIR] [--for-aosp] [--platform-test-key]\n' >&2
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
            out_dir_explicit=1
            shift 2
            ;;
        --for-aosp)
            ((for_aosp == 0)) || usage
            for_aosp=1
            shift
            ;;
        --platform-test-key)
            ((platform_test_key_enabled == 0)) || usage
            platform_test_key_enabled=1
            for_aosp=1
            shift
            ;;
        *) usage ;;
    esac
done

if ((for_aosp)); then
    ((out_dir_explicit == 0)) || {
        printf 'build-guest: --for-aosp chooses Guest/product/prebuilt as its output directory\n' >&2
        exit 64
    }
    [[ ! -L "$repo_root/Guest/product" && ! -L "$repo_root/Guest/product/prebuilt" ]] || {
        printf 'build-guest: Guest/product and its prebuilt directory must not be symlinks\n' >&2
        exit 78
    }
    out_dir="$repo_root/Guest/product/prebuilt"
fi
if ((platform_test_key_enabled)); then
    [[ -f "$platform_test_key" && ! -L "$platform_test_key" ]] || {
        printf 'build-guest: the AOSP platform test key is missing or symlinked: %s\n' \
            "$platform_test_key" >&2
        exit 78
    }
    [[ -f "$platform_test_certificate" && ! -L "$platform_test_certificate" ]] || {
        printf 'build-guest: the AOSP platform test certificate is missing or symlinked: %s\n' \
            "$platform_test_certificate" >&2
        exit 78
    }
fi

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

gradle_args=(
    -p "$guest_dir"
    --console=plain
    "-PapkrunGuestVersionCode=$version_code"
    "-PapkrunGuestVersionName=$version_name"
)
if ((for_aosp)); then
    gradle_args+=("-PapkrunPersistentAgent=true")
fi
"$repo_root/gradlew" "${gradle_args[@]}" :guestd:assembleRelease

shopt -s nullglob
built=("$guest_dir"/guestd/build/outputs/apk/release/*.apk)
shopt -u nullglob
if ((${#built[@]} != 1)); then
    printf 'build-guest: expected one release APK under guestd/build/outputs, found %s\n' "${#built[@]}" >&2
    exit 1
fi

signers="$("$apksigner" verify --print-certs "${built[0]}" | awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
if [[ -z "$signers" || "$signers" != "$expected_signer_sha256" ]]; then
    printf 'build-guest: %s is not signed by the test guest development key (signer %s)\n' \
        "${built[0]}" "$signers" >&2
    exit 1
fi

mkdir -p "$out_dir"
if ((for_aosp)); then
    [[ ! -L "$out_dir" && -d "$out_dir" ]] || {
        printf 'build-guest: Guest/product/prebuilt must be a real directory\n' >&2
        exit 78
    }
fi
apk_name="apkrun-guest.apk"
metadata_name="apkrun-guest.json"
if ((for_aosp)); then
    apk_name="ApkRunGuest.apk"
    metadata_name="ApkRunGuest.json"
fi
[[ ! -L "$out_dir/$apk_name" && ! -L "$out_dir/$metadata_name" ]] || {
    printf 'build-guest: output files must not be symlinks\n' >&2
    exit 78
}
apk_temporary="$(mktemp "$out_dir/.guest-apk.XXXXXX")"
metadata_temporary="$(mktemp "$out_dir/.guest-metadata.XXXXXX")"
platform_temporary=""
cleanup_temporary_files() {
    rm -f -- "$apk_temporary" "$metadata_temporary"
    if [[ -n "$platform_temporary" ]]; then
        rm -f -- "$platform_temporary" "$platform_temporary.idsig"
    fi
}
trap cleanup_temporary_files EXIT
apk_to_copy="${built[0]}"
if ((platform_test_key_enabled)); then
    platform_temporary="$(mktemp "$out_dir/.guest-platform-signed.XXXXXX")"
    "$apksigner" sign \
        --key "$platform_test_key" \
        --cert "$platform_test_certificate" \
        --out "$platform_temporary" \
        "${built[0]}"
    platform_signers="$("$apksigner" verify --print-certs "$platform_temporary" |
        awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
    if [[ -z "$platform_signers" || "$platform_signers" != "$expected_platform_signer_sha256" ]]; then
        printf 'build-guest: %s is not signed by the pinned AOSP test platform key (signer %s)\n' \
            "$platform_temporary" "$platform_signers" >&2
        exit 1
    fi
    apk_to_copy="$platform_temporary"
fi
install -m 0644 "$apk_to_copy" "$apk_temporary"
printf '{\n  "packageName": "%s",\n  "versionCode": %s,\n  "versionName": "%s"\n}\n' \
    "$package_name" "$version_code" "$version_name" > "$metadata_temporary"
chmod 0644 "$metadata_temporary"
mv -f "$apk_temporary" "$out_dir/$apk_name"
mv -f "$metadata_temporary" "$out_dir/$metadata_name"
trap - EXIT
if [[ -n "$platform_temporary" ]]; then
    rm -f -- "$platform_temporary" "$platform_temporary.idsig"
fi
printf 'build-guest: wrote %s (versionCode %s)\n' "$out_dir/$apk_name" "$version_code"
