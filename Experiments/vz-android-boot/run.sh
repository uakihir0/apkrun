#!/bin/bash
# Usage: run.sh <boot dir from make_initrd.py> <run name> [harness options...]
# Clones the pristine spike disks (APFS clonefile) into a fresh run directory and boots.
# With KEEP_DISKS=1 an existing run directory keeps its writable disks (warm boot).
# DISK_SET=disks2 selects the two-disk layout (os.img + instance.img) of
# build_disks.py --two-disks; the default is the three-disk layout of §4.2.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
spike="$repo/Images/work/16373615/vz-spike"
boot="$1"; name="$2"; shift 2
run="$spike/runs/$name"
set_dir="$spike/${DISK_SET:-disks}"
if [[ "${DISK_SET:-disks}" == disks2 ]]; then writable=(instance); else writable=(persistent userdata); fi
mkdir -p "$run"
disk_args=(--disk "$set_dir/os.img:ro")
for disk in "${writable[@]}"; do
  if [[ "${KEEP_DISKS:-0}" != 1 || ! -f "$run/$disk.img" ]]; then
    rm -f "$run/$disk.img"
    cp -c "$set_dir/$disk.img" "$run/$disk.img"
  fi
  disk_args+=(--disk "$run/$disk.img:rw")
done
exec "$repo/Images/work/vz-android-boot/vz-android-boot" \
  --kernel "$repo/Images/work/16373615/boot/kernel" \
  --initrd "$boot/initrd.img" \
  --cmdline-file "$boot/cmdline.txt" \
  "${disk_args[@]}" \
  --log-dir "$run" \
  "$@"
