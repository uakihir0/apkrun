#!/usr/bin/env bash
# Atomically publish an already-verified AOSP archive and its build-info sidecar.
set -euo pipefail

if (($# != 4)); then
    printf 'usage: publish-build-transfer.sh <archive-temp> <build-info-temp> <output-dir> <archive-name>\n' >&2
    exit 64
fi

archive_temporary="$1"
info_temporary="$2"
local_output_dir="$3"
archive_name="$4"
published_archive=""

cleanup_transfer() {
    rm -f -- "$archive_temporary" "$info_temporary"
    if [[ -n "$published_archive" ]]; then
        rm -f -- "$published_archive" \
            || printf 'publish-build-transfer: warning: could not remove partial archive %s\n' \
                "$published_archive" >&2
    fi
}
trap cleanup_transfer EXIT

mv "$archive_temporary" "$local_output_dir/$archive_name"
published_archive="$local_output_dir/$archive_name"
if ! mv "$info_temporary" "$local_output_dir/build-info.json"; then
    printf 'publish-build-transfer: could not publish build-info.json; removed the partial archive\n' >&2
    exit 1
fi

published_archive=""
trap - EXIT
