#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: make-test-disks.sh <out-dir>\n' >&2
    exit 64
fi

output_dir="$1"
for tool in awk mkfile python3 shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'make-test-disks: required tool not found: %s\n' "$tool" >&2
        exit 1
    fi
done

if [[ "$output_dir" != /* ]]; then
    output_dir="$PWD/$output_dir"
fi
mkdir -p "$(dirname "$output_dir")"
if ! mkdir -m 700 "$output_dir"; then
    printf 'make-test-disks: output directory must not already exist: %s\n' \
        "$output_dir" >&2
    exit 73
fi
read_only_disk="$output_dir/ro.img"
read_write_disk="$output_dir/rw.img"

python3 - "$read_only_disk" <<'PY'
import hashlib
import sys

destination = sys.argv[1]
seed = b"APKRun Linux test read-only disk v1"
target_size = 8 * 1024 * 1024

with open(destination, "wb") as disk:
    block_index = 0
    remaining = target_size
    while remaining:
        block = hashlib.sha256(seed + block_index.to_bytes(8, "big")).digest()
        chunk = block[:remaining]
        disk.write(chunk)
        remaining -= len(chunk)
        block_index += 1
PY

mkfile -n 64m "$read_write_disk"
printf '%s\n' "$(shasum -a 256 "$read_only_disk" | awk '{ print $1 }')"
