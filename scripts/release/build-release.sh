#!/usr/bin/env bash
# build-release.sh — builds, signs, and packages one APKRun release, then
# writes the signed archive and the signed appcast under build/release/
# (workflow.md §9.4). In dry-run mode it publishes nothing (§9.7, v0.5).
#
# Usage:
#   scripts/release/build-release.sh \
#       --version 1.2.0 --build 1200 [--channel beta] \
#       [--feed-base-url https://<updates host>/] [--dry-run] \
#       [--developer-id "Developer ID Application: …"]
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cd "$repo_root"

version=""
build=""
channel="stable"
feed_base_url="https://updates.invalid/apkrun/"
developer_id=""
dry_run=0
out_dir="build/release"

while (($#)); do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --build) build="$2"; shift 2 ;;
        --channel) channel="$2"; shift 2 ;;
        --feed-base-url) feed_base_url="$2"; shift 2 ;;
        --developer-id) developer_id="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --out) out_dir="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

if [[ -z "$version" || -z "$build" ]]; then
    echo "usage: build-release.sh --version <v> --build <n> [options]" >&2
    exit 64
fi

mkdir -p "$out_dir"

# §9.3: MARKETING_VERSION in project.yml equals the release version.
marketing="$(grep -E '^ *MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*: *"?([^" ]+)"?.*/\1/')"
if [[ "$marketing" != "$version" ]]; then
    echo "build-release: project.yml MARKETING_VERSION ($marketing) != $version" >&2
    exit 65
fi

# The Release product verifies feeds against a baked-in public key
# (project.yml `APKRUN_RELEASE_PUBLIC_ED_KEY`). When the pipeline only
# supplied the private key, derive the public half — a missing key would
# build a product whose signed-update checks always fail.
if [[ -z "${APKRUN_RELEASE_PUBLIC_ED_KEY:-}" && -n "${APKRUN_SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    APKRUN_RELEASE_PUBLIC_ED_KEY="$(xcrun swift scripts/release/sign-update.swift --public-key)"
    export APKRUN_RELEASE_PUBLIC_ED_KEY
fi

# Build the Release products; the guest agent is embedded by the standard
# build phase when its artifacts exist.
scripts/generate-project.sh
xcodebuild -project APKRun.xcodeproj -scheme APKRun \
    -configuration Release -jobs 2 \
    -derivedDataPath build/ReleaseDerivedData \
    -resultBundlePath "$out_dir/APKRun-Release.xcresult" \
    CURRENT_PROJECT_VERSION="$build" \
    ${developer_id:+CODE_SIGN_IDENTITY=-} \
    ${developer_id:-CODE_SIGNING_ALLOWED=NO} \
    APKRUN_CHANNEL="$channel" \
    build

app="build/ReleaseDerivedData/Build/Products/Release/APKRun.app"
if [[ ! -d "$app" ]]; then
    echo "build-release: APKRun.app missing at $app" >&2
    exit 66
fi

if [[ -n "$developer_id" ]]; then
    scripts/release/sign-bundle.sh "$app" "$developer_id"
fi

# R1/R5/R6 checks (workflow.md §9.1).
scripts/release/check-release-build.sh "$app"

# The Sparkle archive (§3.3): a plain zip next to the bundle.
archive="$out_dir/APKRun-$version.zip"
ditto -c -k --keepParent "$app" "$archive"

# Sign the archive with the Sparkle EdDSA key.
signature="$(xcrun swift scripts/release/sign-update.swift "$archive")"

# The appcast item (§3.3) plus the signed feed (`appcast.xml.sig`).
python3 scripts/release/appcast.py add \
    --version "$version" --build "$build" \
    --archive "$archive" --signature "$signature" \
    --feed-base-url "$feed_base_url" \
    --channel "$channel" \
    --out "$out_dir"

shasum -a 256 "$archive" > "$out_dir/SHA256SUMS"

if ((dry_run)); then
    echo "dry run: artifacts under $out_dir; nothing was published"
fi
