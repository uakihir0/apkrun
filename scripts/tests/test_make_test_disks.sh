#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

first_output="$temporary_root/first"
second_output="$temporary_root/second"
first_hash="$("$repo_root/Tests/Fixtures/linux/make-test-disks.sh" "$first_output")"
second_hash="$("$repo_root/Tests/Fixtures/linux/make-test-disks.sh" "$second_output")"

if [[ ! "$first_hash" =~ ^[0-9a-f]{64}$ || "$first_hash" != "$second_hash" ]]; then
    printf 'FAIL test disk generator: read-only image hash is not stable\n' >&2
    exit 1
fi

for image in "$first_output/ro.img" "$second_output/ro.img"; do
    size="$(stat -f '%z' "$image")"
    if [[ "$size" != 8388608 ]]; then
        printf 'FAIL test disk generator: %s has size %s\n' "$image" "$size" >&2
        exit 1
    fi
done

for image in "$first_output/rw.img" "$second_output/rw.img"; do
    size="$(stat -f '%z' "$image")"
    if [[ "$size" != 67108864 ]]; then
        printf 'FAIL test disk generator: %s has size %s\n' "$image" "$size" >&2
        exit 1
    fi
done

unsafe_output="$temporary_root/unsafe"
mkdir "$unsafe_output"
preserved_file="$temporary_root/preserved.txt"
printf 'preserve this file\n' > "$preserved_file"
ln -s "$preserved_file" "$unsafe_output/ro.img"
if "$repo_root/Tests/Fixtures/linux/make-test-disks.sh" "$unsafe_output" \
    >/dev/null 2>&1
then
    printf 'FAIL test disk generator: accepted an existing output directory\n' >&2
    exit 1
fi
if [[ "$(cat "$preserved_file")" != 'preserve this file' ]]; then
    printf 'FAIL test disk generator: followed an existing output symlink\n' >&2
    exit 1
fi

printf 'PASS test disk generator: SHA-256 %s\n' "$first_hash"
