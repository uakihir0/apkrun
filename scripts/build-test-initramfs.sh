#!/usr/bin/env bash
set -euo pipefail
umask 022

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
output_dir="${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}"

if [[ "$output_dir" != /* ]]; then
    printf 'build-test-initramfs: APKRUN_TEST_LINUX_DIR must be an absolute path: %s\n' "$output_dir" >&2
    exit 64
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
if [[ "${APKRUN_TEST_LINUX_LOCK_HELD:-0}" != 1 ]]; then
    exec python3 "$script_dir/tools/with-file-lock.py" \
        "$output_dir/.artifacts.lock" "$0" "$@"
fi

downloads_dir="$output_dir/downloads"
lock_file="$repo_root/ThirdParty/ThirdParty.lock.json"
modules_list="$repo_root/Tests/Fixtures/linux/modules.list"
init_script="$repo_root/Tests/Fixtures/linux/init"

for tool in awk cpio find gzip jq shasum sort tar touch; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'build-test-initramfs: required tool not found: %s\n' "$tool" >&2
        exit 1
    fi
done

APKRUN_TEST_LINUX_LOCK_HELD=1 "$script_dir/fetch-test-linux.sh"

lock_value() {
    local component="$1"
    local field="$2"
    jq -er \
        --arg component "$component" \
        --arg field "$field" \
        '.components[] | select(.name == $component) | .[$field]' \
        "$lock_file"
}

artifact_path() {
    local component="$1"
    printf '%s/%s\n' "$downloads_dir" "$(basename "$(lock_value "$component" url)")"
}

verify_artifact() {
    local component="$1"
    local file="$2"
    local expected
    local actual
    expected="$(lock_value "$component" sha256)"
    actual="$(shasum -a 256 "$file" | awk '{ print $1 }')"
    if [[ "$actual" != "$expected" ]]; then
        printf 'build-test-initramfs: SHA-256 mismatch for %s\n' "$file" >&2
        return 1
    fi
}

rootfs_archive="$(artifact_path alpine-minirootfs)"
verify_artifact alpine-minirootfs "$rootfs_archive"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-test-initramfs.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT

root="$temporary_dir/root"
mkdir -p "$root"
tar -xzf "$rootfs_archive" -C "$root"

for component in \
    alpine-socat \
    alpine-libcrypto3 \
    alpine-libgpiod \
    alpine-libssl3 \
    alpine-readline \
    alpine-libncursesw \
    alpine-ncurses-terminfo-base
do
    package="$(artifact_path "$component")"
    verify_artifact "$component" "$package"
    tar -xzf "$package" -C "$root"
done
rm -f "$root/.PKGINFO" "$root"/.SIGN.*

module_release="$(<"$output_dir/kernel.release")"
module_source="$output_dir/modules/$module_release"
module_dep="$module_source/modules.dep"
if [[ ! -f "$module_dep" ]]; then
    printf 'build-test-initramfs: missing pinned kernel modules; run scripts/fetch-test-linux.sh\n' >&2
    exit 1
fi

module_paths="$temporary_dir/module-paths"
awk -F: -v dep_file="$module_dep" '
    function module_name(path) {
        gsub(/^[ \t]+|[ \t]+$/, "", path)
        sub(/^.*\//, "", path)
        sub(/\.ko(\..*)?$/, "", path)
        gsub(/-/, "_", path)
        return path
    }

    FILENAME == dep_file {
        path = $1
        name = module_name(path)
        module_paths[name] = path
        module_dependencies[name] = $2
        next
    }

    {
        line = $0
        sub(/#.*/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line != "") {
            requested[module_name(line)] = 1
        }
    }

    END {
        failed = 0
        for (name in requested) {
            if (!(name in module_paths)) {
                printf "build-test-initramfs: module is absent from the pinned kernel: %s\n", name > "/dev/stderr"
                failed = 1
            }
        }
        if (failed) {
            exit 1
        }

        changed = 1
        while (changed) {
            changed = 0
            for (name in requested) {
                count = split(module_dependencies[name], dependencies, /[ \t]+/)
                for (dependency_index = 1; dependency_index <= count; dependency_index++) {
                    dependency = module_name(dependencies[dependency_index])
                    if (dependency == "") {
                        continue
                    }
                    if (!(dependency in module_paths)) {
                        printf "build-test-initramfs: module dependency is absent from the pinned kernel: %s\n", dependency > "/dev/stderr"
                        failed = 1
                        continue
                    }
                    if (!(dependency in requested)) {
                        requested[dependency] = 1
                        changed = 1
                    }
                }
            }
        }
        if (failed) {
            exit 1
        }

        for (name in requested) {
            print module_paths[name]
        }
    }
' "$module_dep" "$modules_list" | sort > "$module_paths"

module_root="$root/lib/modules/$module_release"
mkdir -p "$module_root"
: > "$module_root/modules.dep"
: > "$module_root/modules.alias"
: > "$module_root/modules.builtin"

while IFS= read -r module_path; do
    source_file="$module_source/$module_path"
    destination_file="$module_root/${module_path%.gz}"
    if [[ ! -f "$source_file" ]]; then
        printf 'build-test-initramfs: missing module file %s\n' "$source_file" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$destination_file")"
    if [[ "$module_path" == *.gz ]]; then
        gzip -dc "$source_file" > "$destination_file"
    else
        cp -p "$source_file" "$destination_file"
    fi

    source_line="$(
        awk -F: -v path="$module_path" '$1 == path { print; exit }' "$module_dep"
    )"
    if [[ -z "$source_line" ]]; then
        printf 'build-test-initramfs: missing dependency entry for %s\n' "$module_path" >&2
        exit 1
    fi
    dependencies="${source_line#*:}"
    formatted_dependencies=
    for dependency in $dependencies; do
        formatted_dependencies+=" ${dependency%.gz}"
    done
    printf '%s:%s\n' "${module_path%.gz}" "$formatted_dependencies" \
        >> "$module_root/modules.dep"
done < "$module_paths"

mkdir -p "$root/etc/apkrun"
cp "$modules_list" "$root/etc/apkrun/modules.list"
cp "$init_script" "$root/init"
chmod 755 "$root/init"

find "$root" -exec touch -h -t 200001010000 {} +

temporary_initrd="$output_dir/initramfs.cpio.gz.partial.$$"
(
    cd "$root"
    find . -print | LC_ALL=C sort | cpio -o --format newc
) > "$temporary_dir/initramfs.cpio"
python3 - \
    "$temporary_dir/initramfs.cpio" \
    "$temporary_dir/initramfs.normalized.cpio" <<'PY'
import sys

source_path, destination_path = sys.argv[1:]
header_size = 110
fields = (
    "ino",
    "mode",
    "uid",
    "gid",
    "nlink",
    "mtime",
    "filesize",
    "devmajor",
    "devminor",
    "rdevmajor",
    "rdevminor",
    "namesize",
    "check",
)
offsets = {name: 6 + index * 8 for index, name in enumerate(fields)}
inode_numbers = {}
next_inode_number = 1

def aligned(value):
    return (value + 3) & ~3

with open(source_path, "rb") as source:
    archive = source.read()

output = bytearray()
offset = 0
found_trailer = False
while offset + header_size <= len(archive):
    header = archive[offset : offset + header_size]
    if header[:6] != b"070701":
        raise SystemExit(f"invalid newc header at byte {offset}")

    values = {
        name: int(header[field_offset : field_offset + 8], 16)
        for name, field_offset in offsets.items()
    }
    name_start = offset + header_size
    name_end = name_start + values["namesize"]
    if values["namesize"] == 0 or name_end > len(archive):
        raise SystemExit("invalid newc pathname length")
    pathname = archive[name_start:name_end]
    data_start = aligned(name_end)
    data_end = data_start + values["filesize"]
    if data_end > len(archive):
        raise SystemExit("newc file data ends outside the archive")
    data = archive[data_start:data_end]

    if pathname.rstrip(b"\0") == b"TRAILER!!!":
        values["ino"] = 0
        values["uid"] = 0
        values["gid"] = 0
        values["mtime"] = 0
        values["devmajor"] = 0
        values["devminor"] = 0
        values["rdevmajor"] = 0
        values["rdevminor"] = 0
        found_trailer = True
    else:
        inode_key = (
            values["devmajor"],
            values["devminor"],
            values["ino"],
        )
        if inode_key not in inode_numbers:
            inode_numbers[inode_key] = next_inode_number
            next_inode_number += 1
        values["ino"] = inode_numbers[inode_key]
        values["uid"] = 0
        values["gid"] = 0
        values["mtime"] = 0
        values["devmajor"] = 0
        values["devminor"] = 0
        values["rdevmajor"] = 0
        values["rdevminor"] = 0

    normalized_header = bytearray(header)
    for field_name, field_offset in offsets.items():
        normalized_header[field_offset : field_offset + 8] = (
            f"{values[field_name]:08x}".encode("ascii")
        )
    output.extend(normalized_header)
    output.extend(pathname)
    output.extend(b"\0" * (aligned(len(output)) - len(output)))
    output.extend(data)
    output.extend(b"\0" * (aligned(len(output)) - len(output)))

    offset = aligned(data_end)
    if found_trailer:
        break

if not found_trailer:
    raise SystemExit("newc archive has no TRAILER!!! entry")

with open(destination_path, "wb") as destination:
    destination.write(output)
PY
gzip -n -9 < "$temporary_dir/initramfs.normalized.cpio" > "$temporary_initrd"
mv -f "$temporary_initrd" "$output_dir/initramfs.cpio.gz"

printf 'build-test-initramfs: built %s/initramfs.cpio.gz\n' "$output_dir"
shasum -a 256 "$output_dir/initramfs.cpio.gz"
