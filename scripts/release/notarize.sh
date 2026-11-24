#!/usr/bin/env bash
# notarize.sh — submits a bundle or DMG to Apple notarization, staples the
# ticket, and verifies the result (build-system.md §12.6).
#
# Usage:
#   scripts/release/notarize.sh <APKRun.app|APKRun.dmg> \
#       (--keychain-profile <profile> |
#        --key <p8 path> --key-id <id> --issuer <uuid>)
set -euo pipefail

target=""
keychain_profile=""
key=""
key_id=""
issuer=""

while (($#)); do
    case "$1" in
        --keychain-profile) keychain_profile="$2"; shift 2 ;;
        --key) key="$2"; shift 2 ;;
        --key-id) key_id="$2"; shift 2 ;;
        --issuer) issuer="$2"; shift 2 ;;
        -*) echo "unknown argument: $1" >&2; exit 64 ;;
        *)
            if [[ -z "$target" ]]; then
                target="$1"; shift
            else
                echo "unexpected argument: $1" >&2; exit 64
            fi
            ;;
    esac
done

if [[ -z "$target" || ! -e "$target" ]]; then
    echo "usage: notarize.sh <path> (--keychain-profile <p> | --key <p8> --key-id <id> --issuer <uuid>)" >&2
    exit 64
fi

credentials=()
if [[ -n "$keychain_profile" ]]; then
    credentials=(--keychain-profile "$keychain_profile")
elif [[ -n "$key" && -n "$key_id" && -n "$issuer" ]]; then
    credentials=(--key "$key" --key-id "$key_id" --issuer "$issuer")
else
    echo "notarize: pass --keychain-profile or all of --key/--key-id/--issuer" >&2
    exit 64
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

archive="$work_dir/submit.zip"
if [[ "$target" == *.dmg ]]; then
    # DMGs submit directly.
    archive="$target"
else
    ditto -c -k --keepParent "$target" "$archive"
fi

echo "notarize: submitting $archive"
response="$work_dir/response.json"
if ! xcrun notarytool submit "$archive" "${credentials[@]}" --wait \
    --output-format json >"$response"; then
    echo "notarize: submission failed" >&2
    cat "$response" >&2 || true
    exit 65
fi

submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$response")"
status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$response")"
echo "notarize: submission $submission_id -> $status"

if [[ "$status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log "$submission_id" "${credentials[@]}" >&2 || true
    fi
    exit 65
fi

xcrun stapler staple "$target"

# §12.6: an app bundle must assess as Notarized Developer ID.
if [[ "$target" == *.app ]]; then
    assessment="$(spctl --assess --type execute -vv "$target" 2>&1 || true)"
    echo "$assessment"
    if [[ "$assessment" != *"source=Notarized Developer ID"* ]]; then
        echo "notarize: spctl rejected $target" >&2
        exit 65
    fi
fi

echo "notarized and stapled: $target"
