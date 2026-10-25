#!/usr/bin/env bash
# Builds the development Guest Agent and Store Agent APKs (guest-components.md §2, #37, #73).
#
#   scripts/build-guest.sh                       build Guest/build/out/{apkrun-guest,apkrun-store}.{apk,json}
#   scripts/build-guest.sh --for-aosp --platform-test-key
#                                                build platform-signed prebuilt APKs
#   scripts/build-guest.sh --platform-test-key    build platform-signed prebuilt APKs
#   scripts/build-guest.sh --platform-test-key --test-image-hooks
#                                                opt in to AndroidCustom's health-failure fixture
#   scripts/build-guest.sh --version-code N --out DIR
#                                                build with another versionCode into DIR (the reinstall test)
#
# Both APKs use the test-only development key Tests/Fixtures/signing/test-guest-dev.jks, and the script fails
# unless each build signer is that key. `--platform-test-key` re-signs both persistent AOSP prebuilt APKs with
# the public AOSP test platform key. Both versionCodes use major * 1 000 000 + minor * 1 000 + patch of the
# MARKETING_VERSION in project.yml (build-system.md §7.1). Each agent has a version record next to its APK;
# the host reads the Guest Agent record before install (guest-components.md §3.1). The host build copies the
# development Guest APK into APKRun.app/Contents/Resources/guest/.
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
store_package_name="io.apkrun.store"
platform_test_key="$repo_root/Tests/Fixtures/signing/aosp-test-platform.pk8"
platform_test_certificate="$repo_root/Tests/Fixtures/signing/aosp-test-platform.x509.pem"

out_dir="$guest_dir/build/out"
version_code_override=""
for_aosp=0
platform_test_key_enabled=0
test_image_hooks_enabled=0
out_dir_explicit=0

usage() {
    printf 'usage: scripts/build-guest.sh [--version-code N] [--out DIR] [--for-aosp --platform-test-key [--test-image-hooks]]\n' >&2
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
        --test-image-hooks)
            ((test_image_hooks_enabled == 0)) || usage
            test_image_hooks_enabled=1
            shift
            ;;
        *) usage ;;
    esac
done

if ((for_aosp && !platform_test_key_enabled)); then
    printf 'build-guest: --for-aosp requires --platform-test-key; persistent agents must use the AOSP test platform signature\n' >&2
    exit 64
fi

if ((test_image_hooks_enabled && !platform_test_key_enabled)); then
    printf 'build-guest: --test-image-hooks requires --platform-test-key\n' >&2
    exit 64
fi

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
    "-PapkrunStoreVersionCode=$version_code"
    "-PapkrunStoreVersionName=$version_name"
)
if ((for_aosp)); then
    gradle_args+=("-PapkrunPersistentAgent=true")
fi
if ((test_image_hooks_enabled)); then
    gradle_args+=("-PapkrunTestHealthFailureProperty=ro.boot.apkrun.test.fail_health")
fi
"$repo_root/gradlew" "${gradle_args[@]}" :guestd:assembleRelease :APKRunStore:assembleRelease

shopt -s nullglob
guest_built=("$guest_dir"/guestd/build/outputs/apk/release/*.apk)
store_built=("$guest_dir"/APKRunStore/build/outputs/apk/release/*.apk)
shopt -u nullglob
if ((${#guest_built[@]} != 1)); then
    printf 'build-guest: expected one Guest Agent release APK, found %s\n' "${#guest_built[@]}" >&2
    exit 1
fi
if ((${#store_built[@]} != 1)); then
    printf 'build-guest: expected one Store Agent release APK, found %s\n' "${#store_built[@]}" >&2
    exit 1
fi

for built_apk in "${guest_built[0]}" "${store_built[0]}"; do
    signers="$("$apksigner" verify --print-certs "$built_apk" |
        awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
    if [[ -z "$signers" || "$signers" != "$expected_signer_sha256" ]]; then
        printf 'build-guest: %s is not signed by the test guest development key (signer %s)\n' \
            "$built_apk" "$signers" >&2
        exit 1
    fi
done

mkdir -p "$out_dir"
if ((for_aosp)); then
    [[ ! -L "$out_dir" && -d "$out_dir" ]] || {
        printf 'build-guest: Guest/product/prebuilt must be a real directory\n' >&2
        exit 78
    }
fi
apk_name="apkrun-guest.apk"
store_apk_name="apkrun-store.apk"
metadata_name="apkrun-guest.json"
store_metadata_name="apkrun-store.json"
if ((for_aosp)); then
    apk_name="ApkRunGuest.apk"
    store_apk_name="ApkRunStore.apk"
    metadata_name="ApkRunGuest.json"
    store_metadata_name="ApkRunStore.json"
fi
[[ ! -L "$out_dir/$apk_name" && ! -L "$out_dir/$store_apk_name" &&
    ! -L "$out_dir/$metadata_name" && ! -L "$out_dir/$store_metadata_name" ]] || {
    printf 'build-guest: output files must not be symlinks\n' >&2
    exit 78
}
apk_temporary="$(mktemp "$out_dir/.guest-apk.XXXXXX")"
store_apk_temporary="$(mktemp "$out_dir/.store-apk.XXXXXX")"
metadata_temporary="$(mktemp "$out_dir/.guest-metadata.XXXXXX")"
store_metadata_temporary="$(mktemp "$out_dir/.store-metadata.XXXXXX")"
platform_guest_temporary=""
platform_store_temporary=""
cleanup_temporary_files() {
    rm -f -- "$apk_temporary" "$store_apk_temporary" "$metadata_temporary" \
        "$store_metadata_temporary"
    if [[ -n "$platform_guest_temporary" ]]; then
        rm -f -- "$platform_guest_temporary" "$platform_guest_temporary.idsig"
    fi
    if [[ -n "$platform_store_temporary" ]]; then
        rm -f -- "$platform_store_temporary" "$platform_store_temporary.idsig"
    fi
}
trap cleanup_temporary_files EXIT
guest_apk_to_copy="${guest_built[0]}"
store_apk_to_copy="${store_built[0]}"
if ((platform_test_key_enabled)); then
    platform_guest_temporary="$(mktemp "$out_dir/.guest-platform-signed.XXXXXX")"
    "$apksigner" sign \
        --key "$platform_test_key" \
        --cert "$platform_test_certificate" \
        --out "$platform_guest_temporary" \
        "$guest_apk_to_copy"
    platform_guest_signers="$("$apksigner" verify --print-certs "$platform_guest_temporary" |
        awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
    if [[ -z "$platform_guest_signers" || "$platform_guest_signers" != "$expected_platform_signer_sha256" ]]; then
        printf 'build-guest: %s is not signed by the pinned AOSP test platform key (signer %s)\n' \
            "$platform_guest_temporary" "$platform_guest_signers" >&2
        exit 1
    fi
    platform_store_temporary="$(mktemp "$out_dir/.store-platform-signed.XXXXXX")"
    "$apksigner" sign \
        --key "$platform_test_key" \
        --cert "$platform_test_certificate" \
        --out "$platform_store_temporary" \
        "$store_apk_to_copy"
    platform_store_signers="$("$apksigner" verify --print-certs "$platform_store_temporary" |
        awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
    if [[ -z "$platform_store_signers" || "$platform_store_signers" != "$expected_platform_signer_sha256" ]]; then
        printf 'build-guest: %s is not signed by the pinned AOSP test platform key (signer %s)\n' \
            "$platform_store_temporary" "$platform_store_signers" >&2
        exit 1
    fi
    guest_apk_to_copy="$platform_guest_temporary"
    store_apk_to_copy="$platform_store_temporary"
fi
install -m 0644 "$guest_apk_to_copy" "$apk_temporary"
install -m 0644 "$store_apk_to_copy" "$store_apk_temporary"
printf '{\n  "packageName": "%s",\n  "versionCode": %s,\n  "versionName": "%s"\n}\n' \
    "$package_name" "$version_code" "$version_name" > "$metadata_temporary"
printf '{\n  "packageName": "%s",\n  "versionCode": %s,\n  "versionName": "%s"\n}\n' \
    "$store_package_name" "$version_code" "$version_name" > "$store_metadata_temporary"
chmod 0644 "$metadata_temporary"
chmod 0644 "$store_metadata_temporary"
mv -f "$apk_temporary" "$out_dir/$apk_name"
mv -f "$store_apk_temporary" "$out_dir/$store_apk_name"
mv -f "$metadata_temporary" "$out_dir/$metadata_name"
mv -f "$store_metadata_temporary" "$out_dir/$store_metadata_name"
trap - EXIT
if [[ -n "$platform_guest_temporary" ]]; then
    rm -f -- "$platform_guest_temporary" "$platform_guest_temporary.idsig"
fi
if [[ -n "$platform_store_temporary" ]]; then
    rm -f -- "$platform_store_temporary" "$platform_store_temporary.idsig"
fi
printf 'build-guest: wrote %s, %s, %s, and %s (versionCode %s)\n' \
    "$out_dir/$apk_name" "$out_dir/$store_apk_name" "$out_dir/$metadata_name" \
    "$out_dir/$store_metadata_name" "$version_code"
