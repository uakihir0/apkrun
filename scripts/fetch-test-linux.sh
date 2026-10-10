#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
lock_file="$repo_root/ThirdParty/ThirdParty.lock.json"
output_dir="${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}"

output_dir="$(python3 "$script_dir/tools/validate-test-linux-dir.py" "$output_dir")"
mkdir -p "$output_dir"
if [[ "${APKRUN_TEST_LINUX_LOCK_HELD:-0}" != 1 ]]; then
    exec python3 "$script_dir/tools/with-file-lock.py" \
        "$output_dir/.artifacts.lock" "$0" "$@"
fi

downloads_dir="$output_dir/downloads"
mkdir -p "$downloads_dir"

for tool in curl gzip jq python3 shasum tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'fetch-test-linux: required tool not found: %s\n' "$tool" >&2
        exit 1
    fi
done

lock_value() {
    local component="$1"
    local field="$2"
    jq -er \
        --arg component "$component" \
        --arg field "$field" \
        '.components[] | select(.name == $component) | .[$field]' \
        "$lock_file"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$file" | awk '{ print $1 }')"
    if [[ "$actual" != "$expected" ]]; then
        printf 'fetch-test-linux: SHA-256 mismatch for %s\n' "$file" >&2
        printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
        return 1
    fi
}

fetch_component() {
    local component="$1"
    local url
    local expected
    local filename
    local destination
    local temporary

    url="$(lock_value "$component" url)"
    expected="$(lock_value "$component" sha256)"
    filename="${url##*/}"
    destination="$downloads_dir/$filename"
    temporary="$downloads_dir/.$filename.partial.$$"

    if [[ -f "$destination" ]] && verify_sha256 "$destination" "$expected"; then
        printf 'fetch-test-linux: verified %s\n' "$filename"
        return
    fi

    rm -f "$temporary"
    printf 'fetch-test-linux: downloading %s\n' "$filename"
    if ! curl --fail --location --retry 3 --output "$temporary" "$url" \
        || ! verify_sha256 "$temporary" "$expected"; then
        rm -f "$temporary"
        return 1
    fi
    mv -f "$temporary" "$destination"
}

for component in \
    alpine-linux-virt \
    alpine-minirootfs \
    alpine-e2fsprogs \
    alpine-e2fsprogs-libs \
    alpine-libblkid \
    alpine-libcom-err \
    alpine-libeconf \
    alpine-libuuid \
    alpine-socat \
    alpine-ssl-client \
    alpine-libcrypto3 \
    alpine-libgpiod \
    alpine-libssl3 \
    alpine-readline \
    alpine-libncursesw \
    alpine-ncurses-terminfo-base
do
    fetch_component "$component"
done

virgl_packages="$repo_root/Tests/Fixtures/linux/virgl-packages.list"
while IFS= read -r component || [[ -n "$component" ]]; do
    case "$component" in
        ""|\#*) continue ;;
    esac
    fetch_component "$component"
done < "$virgl_packages"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-test-linux.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

kernel_package="$downloads_dir/$(basename "$(lock_value alpine-linux-virt url)")"
tar -xzf "$kernel_package" -C "$temporary_dir" \
    boot/vmlinuz-virt \
    lib/modules \
    usr/share/kernel/virt/kernel.release

kernel_source="$temporary_dir/boot/vmlinuz-virt"
module_release="$(<"$temporary_dir/usr/share/kernel/virt/kernel.release")"
module_source="$temporary_dir/lib/modules/$module_release"
if [[ ! -s "$kernel_source" || ! -f "$module_source/modules.dep" ]]; then
    printf 'fetch-test-linux: the pinned kernel package has an incomplete module set\n' >&2
    exit 1
fi

payload_file="$temporary_dir/kernel-payload.gz"
image_file="$temporary_dir/Image"
kernel_kind="$(
    python3 - "$kernel_source" "$payload_file" "$image_file" <<'PY'
import os
import shutil
import struct
import sys

source_path, payload_path, image_path = sys.argv[1:]
with open(source_path, "rb") as source:
    header = source.read(64)
    if len(header) < 64:
        raise SystemExit("kernel file is shorter than the ARM64 Image header")

    if header[0x38:0x3C] == b"ARM\x64":
        source.seek(0)
        with open(image_path, "wb") as image:
            shutil.copyfileobj(source, image)
        print("image")
    elif header[:2] == b"\x1f\x8b":
        source.seek(0)
        with open(payload_path, "wb") as payload:
            shutil.copyfileobj(source, payload)
        print("gzip")
    elif header[:2] == b"MZ" and header[4:8] == b"zimg":
        payload_offset, payload_size = struct.unpack_from("<II", header, 8)
        compression = header[24:40].split(b"\0", 1)[0].decode("ascii")
        file_size = os.fstat(source.fileno()).st_size
        if compression != "gzip":
            raise SystemExit(
                f"unsupported EFI zboot compression: {compression or '<empty>'}"
            )
        if (
            payload_offset < 16
            or payload_size == 0
            or payload_offset + payload_size > file_size
        ):
            raise SystemExit("EFI zboot payload range is outside the kernel file")

        source.seek(payload_offset)
        remaining = payload_size
        with open(payload_path, "wb") as payload:
            while remaining:
                chunk = source.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise SystemExit("EFI zboot payload ended before its declared size")
                payload.write(chunk)
                remaining -= len(chunk)
        print("gzip")
    else:
        raise SystemExit("kernel is not a raw ARM64 Image, gzip image, or EFI zboot")
PY
)"

if [[ "$kernel_kind" == "gzip" ]]; then
    gzip -dc "$payload_file" > "$image_file"
fi

python3 - "$image_file" <<'PY'
import sys

with open(sys.argv[1], "rb") as image:
    image.seek(0x38)
    if image.read(4) != b"ARM\x64":
        raise SystemExit("decompressed kernel does not have the ARM64 Image magic")
PY

modules_dir="$output_dir/modules"
mkdir -p "$modules_dir"
rm -rf "$modules_dir/$module_release"
cp -R "$module_source" "$modules_dir/$module_release"
mv -f "$image_file" "$output_dir/Image"
printf '%s\n' "$module_release" > "$output_dir/kernel.release"

printf 'fetch-test-linux: kernel and modules ready in %s\n' "$output_dir"
