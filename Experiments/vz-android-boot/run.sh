#!/bin/bash
# Usage: run.sh <boot dir from make_initrd.py> <run name> [harness options...]
# Clones the pristine spike disks (APFS clonefile) into a fresh run directory and boots.
# With KEEP_DISKS=1 an existing run directory keeps its writable disks (warm boot).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
spike="$repo/Images/work/16373615/vz-spike"
boot="$1"; name="$2"; shift 2
run="$spike/runs/$name"
mkdir -p "$run"
for disk in persistent userdata; do
  if [[ "${KEEP_DISKS:-0}" == 1 && -f "$run/$disk.img" ]]; then continue; fi
  rm -f "$run/$disk.img"
  cp -c "$spike/disks/$disk.img" "$run/$disk.img"
done
exec "$repo/Images/work/vz-android-boot/vz-android-boot" \
  --kernel "$repo/Images/work/16373615/boot/kernel" \
  --initrd "$boot/initrd.img" \
  --cmdline-file "$boot/cmdline.txt" \
  --disk "$spike/disks/os.img:ro" \
  --disk "$run/persistent.img:rw" \
  --disk "$run/userdata.img:rw" \
  --log-dir "$run" \
  "$@"
