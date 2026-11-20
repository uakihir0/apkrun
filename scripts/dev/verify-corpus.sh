#!/usr/bin/env bash
# Verifies every APK in the F-Droid corpus (package-store.md §10.2, T3 of #74).
#
#   scripts/dev/verify-corpus.sh [manifest] [--apkrun <bin>]
#
# For each entry of `Tests/Compatibility/apps.json` the script runs `apkrun inspect --json`
# and compares the reported signer SHA-256 digests to `apksigner verify --print-certs`. The
# host verifier may refuse an APK Android accepts (OQ-15); when it accepts, its signer
# digests must equal apksigner's exactly — never worse than Android's own verifier.
#
# The manifest is JSON:
#   {"version": 1, "apps": [{"name": "...", "url": "https://f-droid.org/repo/x.apk"}]}
# An entry may give "path" instead of "url" for a file already on disk. Downloaded APKs land
# in build/corpus/ and are reused on repeat runs.
#
# Needs: `apksigner` under $ANDROID_HOME/build-tools/<latest>/ (environment-setup.md §2.5),
# `jq`, `curl`, a running apkrund for `apkrun inspect` (host-side only — no VM starts), and a
# built CLI (swift build --product apkrun, or --apkrun <path>).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
manifest="$repo_root/Tests/Compatibility/apps.json"
apkrun_bin="${APKRUN_BIN:-}"

usage() {
    printf 'usage: scripts/dev/verify-corpus.sh [manifest] [--apkrun <bin>]\n' >&2
    exit 64
}

while (($# > 0)); do
    case "$1" in
        --apkrun)
            (($# >= 2)) || usage
            apkrun_bin="$2"
            shift
            ;;
        -*) usage ;;
        *) manifest="$1" ;;
    esac
    shift
done

if [[ ! -f "$manifest" ]]; then
    printf 'verify-corpus: %s not found\n' "$manifest" >&2
    exit 78
fi

android_home="${ANDROID_HOME:-$repo_root/build/android-sdk}"
build_tools="$android_home/build-tools"
apksigner=""
if [[ -d "$build_tools" ]]; then
    for candidate in "$build_tools"/*/apksigner; do
        [[ -x "$candidate" ]] && apksigner="$candidate"
    done
fi
if [[ -z "$apksigner" ]]; then
    printf 'verify-corpus: apksigner is missing under %s (environment-setup.md §2.5)\n' "$build_tools" >&2
    exit 78
fi
command -v jq >/dev/null || { printf 'verify-corpus: jq is missing\n' >&2; exit 78; }
command -v curl >/dev/null || { printf 'verify-corpus: curl is missing\n' >&2; exit 78; }

if [[ -z "$apkrun_bin" ]]; then
    (cd "$repo_root" && swift build --product apkrun >/dev/null)
    apkrun_bin="$repo_root/.build/debug/apkrun"
fi
if [[ ! -x "$apkrun_bin" ]]; then
    printf 'verify-corpus: %s is not an executable CLI\n' "$apkrun_bin" >&2
    exit 78
fi

corpus_dir="$repo_root/build/corpus"
mkdir -p "$corpus_dir"

count="$(jq '.apps | length' "$manifest")"
if [[ "$count" == "0" ]]; then
    printf 'verify-corpus: %s lists no apps — the corpus must not be empty\n' "$manifest" >&2
    exit 78
fi

failures=0
checked=0
for index in $(seq 0 $((count - 1))); do
    name="$(jq -r ".apps[$index].name" "$manifest")"
    url="$(jq -r ".apps[$index].url // empty" "$manifest")"
    path="$(jq -r ".apps[$index].path // empty" "$manifest")"

    apk=""
    if [[ -n "$path" ]]; then
        apk="${path/#\~/$HOME}"
    elif [[ -n "$url" ]]; then
        apk="$corpus_dir/${name//[^A-Za-z0-9._-]/_}.apk"
        if [[ ! -f "$apk" ]]; then
            if ! curl -fsSL --retry 3 -o "$apk" "$url"; then
                printf 'FAIL  %s — download failed (%s)\n' "$name" "$url"
                failures=$((failures + 1))
                continue
            fi
        fi
    else
        printf 'FAIL  %s — entry has neither url nor path\n' "$name"
        failures=$((failures + 1))
        continue
    fi

    apksigner_digests="$("$apksigner" verify --print-certs "$apk" 2>/dev/null \
        | awk '/certificate SHA-256 digest/ { print $NF }' | sort -u)"
    if [[ -z "$apksigner_digests" ]]; then
        printf 'FAIL  %s — apksigner could not verify the APK at all\n' "$name"
        failures=$((failures + 1))
        continue
    fi

    if ! preview="$("$apkrun_bin" inspect --json "$apk" 2>/dev/null)"; then
        printf 'SKIP  %s — apkrun inspect refused the APK (allowed by OQ-15, review if unexpected)\n' "$name"
        continue
    fi
    apkrun_digests="$(printf '%s' "$preview" | jq -r '.signerDigests[]' | sed 's/^sha256://' | sort -u)"
    if [[ "$apkrun_digests" != "$apksigner_digests" ]]; then
        printf 'FAIL  %s — signer digests differ:\n' "$name"
        printf '      apksigner: %s\n      apkrun:    %s\n' \
            "$(printf '%s' "$apksigner_digests" | tr '\n' ' ')" \
            "$(printf '%s' "$apkrun_digests" | tr '\n' ' ')"
        failures=$((failures + 1))
        continue
    fi

    printf 'OK    %s — %s signer(s) match apksigner\n' "$name" "$(printf '%s\n' "$apkrun_digests" | wc -l | tr -d ' ')"
    checked=$((checked + 1))
done

printf 'verify-corpus: %d of %s APKs verified, %d mismatches\n' "$checked" "$count" "$failures"
((failures == 0))
