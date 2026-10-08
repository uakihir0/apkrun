#!/usr/bin/env bash
# Bounded host-side launch variant of the pinned `default` Cuttlefish profile.
#
# Status: EXPERIMENT (#064, #014). Not a supported capture path; it does not
# publish profiles. Its receipts are in Images/reference/16373615/incomplete/.
#
# This is an experiment for #064 and #014. It runs inside the Linux reference
# guest (limactl shell apkrun-cuttlefish) with CVD_HOST_DIR and
# ANDROID_PRODUCT_OUT set as in Images/tools/reference/capture.sh. The launch
# flags are the `default` profile flags of android-image.md §8.2 (--cpus 4
# --memory_mb 4096, --gpu_vhost_user_mode=off, no --gpu_mode). The requested CPU
# count and memory size are passed to both `cvd create` and `cvd start`, because
# `cvd start` restores its own defaults when a value is omitted (IR-138).
#
# Usage:
#   boot_variant.sh <slug> <deadline_seconds> <cpus> <memory_mb>
#
# Environment:
#   APKRUN_VARIANT_MANIFEST  Images/manifests/16373615/android-image.json (required)
#   APKRUN_VARIANT_EXTRA     extra cvd flags for create and start, split on spaces
#   APKRUN_VARIANT_INSTANCE  instance number (default 2; instance 1 has a stale group)
#   APKRUN_VARIANT_OUT       receipt directory (default /tmp/apkrun-064/out)
#   APKRUN_VARIANT_DWELL     seconds to keep polling after sys.boot_completed=1 (default 120)
#
# The product directory is copied into a private work directory and verified
# against the checked-in manifest before launch, so the pinned files are never
# written. Raw logs stay in the work directory, which is removed on exit unless
# a crosvm process still references it. The receipt holds counts, timings, and
# selected configuration values only.
set -u

die() {
  printf '%s\n' "$*" >&2
  exit 2
}

[ "$#" -eq 4 ] || die "usage: boot_variant.sh <slug> <deadline_seconds> <cpus> <memory_mb>"
slug=$1
deadline=$2
cpus=$3
memory=$4
case $slug in
  ''|*[!a-z0-9-]*) die "slug must match [a-z0-9-]+" ;;
esac
case $deadline in
  ''|*[!0-9]*) die "deadline_seconds must be an integer" ;;
esac
[ "$deadline" -ge 60 ] && [ "$deadline" -le 3600 ] || die "deadline_seconds must be 60 to 3600"
case $cpus in
  ''|*[!0-9]*) die "cpus must be an integer" ;;
esac
[ "$cpus" -ge 1 ] && [ "$cpus" -le 8 ] || die "cpus must be 1 to 8 (the Lima guest has 8 vCPUs)"
case $memory in
  ''|*[!0-9]*) die "memory_mb must be an integer" ;;
esac
[ "$memory" -ge 2048 ] && [ "$memory" -le 10240 ] || die "memory_mb must be 2048 to 10240"
: "${CVD_HOST_DIR:?CVD_HOST_DIR must name the extracted Cuttlefish host package}"
: "${ANDROID_PRODUCT_OUT:?ANDROID_PRODUCT_OUT must name the pinned build 16373615 directory}"
manifest=${APKRUN_VARIANT_MANIFEST:?APKRUN_VARIANT_MANIFEST must name the checked-in manifest}
instance=${APKRUN_VARIANT_INSTANCE:-2}
case $instance in
  ''|*[!0-9]*) die "APKRUN_VARIANT_INSTANCE must be an integer" ;;
esac
adb_port=$((6519 + instance))
out_dir=${APKRUN_VARIANT_OUT:-/tmp/apkrun-064/out}
dwell=${APKRUN_VARIANT_DWELL:-120}
extra_text=${APKRUN_VARIANT_EXTRA:-}
read -r -a extra <<< "$extra_text"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
name="variant-$slug-$stamp"
lock=/tmp/apkrun-cvd-capture.lock
if ! mkdir "$lock" 2>/dev/null; then
  die "another reference capture is active; lock exists: $lock"
fi
if pgrep -x crosvm >/dev/null 2>&1; then
  rmdir "$lock"
  die "crosvm is already running; refuse to start a variant"
fi
work=$(mktemp -d /tmp/a064.XXXXXX) || { rmdir "$lock"; die "cannot create work directory"; }
chmod 700 "$work"
home=$work/h
runtime=$work/rt
prod=$work/p
group=apkrun064_${slug//-/_}_$$
start_pid=
group_created=0
receipt_written=0
create_rc=not-run
start_rc=not-run
boot_at=
boot_signal=
t0=
elapsed_end=0

# Cuttlefish writes the group under /var/tmp/cvd/<uid>/<run>/home/cuttlefish/
# instances/cvd-<n>/ (not under --base_directory). Only files newer than the
# start marker of this run are considered, so the stale instance-1 group is
# never read.
instance_logs() {
  find "/var/tmp/cvd/$(id -u)" -type f -path "*/instances/cvd-$instance/*" \
    \( -name "$1" $(for n in "${@:2}"; do printf -- '-o -name %s ' "$n"; done) \) \
    -newer "$work/started" 2>/dev/null
}

# Summaries run before cleanup, while the instance logs still exist. They keep
# only counts and uptimes, never raw lines.
summarize_tokens() {
  for token in \
    'init: init first stage started!' \
    'Booting Linux on physical CPU' \
    "starting service 'zygote'" \
    'boot_progress_preload_start' \
    'boot_progress_pms_ready' \
    'WATCHDOG KILLING SYSTEM PROCESS' \
    'VIRTUAL_DEVICE_BOOT_COMPLETED' \
    'VIRTUAL_DEVICE_BOOT_FAILED' \
    'VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED' \
    'Out of memory' \
    'lowmemorykiller'; do
    total=0
    first=none
    while IFS= read -r file; do
      n=$(grep -a -c -F -- "$token" "$file" 2>/dev/null || true)
      total=$((total + ${n:-0}))
      if [ "$first" = none ]; then
        line=$(grep -a -m1 -F -- "$token" "$file" 2>/dev/null || true)
        if [ -n "$line" ]; then
          first=$(printf '%s\n' "$line" | sed -n 's/^\[ *\([0-9][0-9.]*\)\].*/\1/p')
          [ -n "$first" ] || first=present
        fi
      fi
    done < <(instance_logs kernel.log launcher.log)
    printf '%s\tcount=%s\tfirst_uptime_s=%s\n' "$token" "$total" "$first"
  done
}

summarize_config() {
  cfg=$(instance_logs cuttlefish_config.json | head -n 1)
  if [ -z "$cfg" ]; then
    printf 'saved configuration: absent\n'
    return
  fi
  python3 -I - "$cfg" <<'PY'
import json
import sys

want = {"cpus", "memory_mb", "ddr_mem_mb", "gpu_mode", "enable_gpu_vhost_user"}
found = {}

def walk(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in want and key not in found and not isinstance(value, (dict, list)):
                found[key] = value
            walk(value)
    elif isinstance(node, list):
        for item in node:
            walk(item)

with open(sys.argv[1], encoding="utf-8") as stream:
    walk(json.load(stream))
for key in sorted(want):
    print(f"saved {key}={found.get(key, 'absent')}")
PY
}

write_receipt() {
  [ "$receipt_written" -eq 0 ] || return 0
  receipt_written=1
  mkdir -p "$out_dir" || return 0
  {
    printf '# Variant %s (%s)\n\n' "$slug" "$stamp"
    printf 'Profile: `default` flags of android-image.md §8.2 plus the variant flags below. Build 16373615. Instance %s, ADB port %s.\n\n' "$instance" "$adb_port"
    printf 'Command (paths replaced by placeholders):\n\n'
    printf '    cvd create --host_path=<CVD_HOST_DIR> --product_path=<private product copy> --base_directory=<private runtime> --group_name=<group> --base_instance_num=%s --num_instances=1 --gpu_vhost_user_mode=off --nostart --cpus=%s --memory_mb=%s %s\n' "$instance" "$cpus" "$memory" "$extra_text"
    printf '    cvd --group_name=<group> start --boot_timeout_secs=%s --cpus=%s --memory_mb=%s --gpu_vhost_user_mode=off %s\n\n' "$deadline" "$cpus" "$memory" "$extra_text"
    printf 'Deadline: %s s. Dwell after sys.boot_completed=1: %s s. Elapsed at poll end: %s s.\n' "$deadline" "$dwell" "$elapsed_end"
    printf 'Product verification: %s\n' "$(cat "$work/verify.txt" 2>/dev/null || echo not-run)"
    printf 'cvd create exit: %s. cvd start exit: %s.\n' "$create_rc" "$start_rc"
    if [ -n "$boot_at" ]; then
      printf 'boot completion first seen %s s after the start command (signal: %s).\n' "$boot_at" "${boot_signal:-unknown}"
    else
      printf 'sys.boot_completed=1 not seen.\n'
    fi
    printf '\n## Saved configuration\n\n'
    cat "$work/config.txt" 2>/dev/null || printf 'saved configuration: not captured\n'
    printf '\n## Launcher and guest markers (count; first guest uptime in seconds)\n\n'
    cat "$work/tokens.txt" 2>/dev/null || printf 'markers: not captured\n'
    printf '\n## Logcat at the end (adb state device only; counts and first stamps)\n\n'
    cat "$work/logcat-tokens.txt" 2>/dev/null || printf 'logcat: not captured\n'
    printf '\n## Poll (elapsed s; get-state; sys.boot_completed; start state; crosvm count; crosvm RSS KiB)\n\n'
    cat "$work/poll.txt" 2>/dev/null
    printf '\n## Cleanup\n\n'
    cat "$work/cleanup.txt" 2>/dev/null || printf 'not recorded\n'
  } > "$out_dir/$name.txt.tmp" && mv "$out_dir/$name.txt.tmp" "$out_dir/$name.txt"
  printf '%s\n' "$out_dir/$name.txt"
}

snapshot_summaries() {
  [ -f "$work/tokens.txt" ] && return 0
  summarize_tokens > "$work/tokens.txt" 2>/dev/null
  summarize_config > "$work/config.txt" 2>/dev/null
  snapshot_logcat
}

# A bounded logcat dump, taken only while adb answers. Only counts and the first
# wall-clock stamp per token are kept; the raw dump stays in the work directory.
snapshot_logcat() {
  [ -f "$work/logcat-tokens.txt" ] && return 0
  if [ "${last_state:-}" != device ]; then
    printf 'logcat: not captured (adb was not in state device at the last poll)\n' > "$work/logcat-tokens.txt"
    return 0
  fi
  timeout 90 adb -s "127.0.0.1:$adb_port" shell logcat -d -b all > "$work/logcat.txt" 2>/dev/null
  for token in 'WATCHDOG KILLING' 'Watchdog' 'boot_progress_preload_start' \
    'boot_progress_pms_ready' 'boot_progress_ams_ready' 'SystemServerTiming' \
    'sys.boot_completed' 'BOOT_COMPLETED' 'system_server'; do
    n=$(grep -a -c -F -- "$token" "$work/logcat.txt" 2>/dev/null || true)
    first=$(grep -a -m1 -F -- "$token" "$work/logcat.txt" 2>/dev/null | cut -c1-18)
    printf 'logcat\t%s\tcount=%s\tfirst_stamp=%s\n' "$token" "${n:-0}" "${first:-none}"
  done > "$work/logcat-tokens.txt"
  rm -f "$work/logcat.txt"
}

cleanup() {
  rc=$?
  set +e
  trap - EXIT
  if [ "$elapsed_end" -eq 0 ] && [ -n "$t0" ]; then
    elapsed_end=$(( $(date +%s) - t0 ))
  fi
  snapshot_summaries
  if [ -n "$start_pid" ] && kill -0 "$start_pid" 2>/dev/null; then
    kill "$start_pid" 2>/dev/null
  fi
  adb disconnect "127.0.0.1:$adb_port" >/dev/null 2>&1
  if [ "$group_created" -eq 1 ]; then
    HOME=$home TMPDIR=$work/t timeout 180 cvd "--group_name=$group" remove > "$work/remove.log" 2>&1
    printf 'cvd remove exit=%s\n' "$?" >> "$work/cleanup.txt"
  fi
  pkill -TERM -f -- "$work" 2>/dev/null
  sleep 5
  pkill -KILL -f -- "$work" 2>/dev/null
  sleep 1
  left=$(pgrep -f -- "$work" 2>/dev/null | wc -l | tr -d ' ')
  printf 'processes referencing the private work directory after cleanup=%s\n' "$left" >> "$work/cleanup.txt"
  crosvm_left=$(pgrep -x crosvm 2>/dev/null | wc -l | tr -d ' ')
  printf 'crosvm processes on the host after cleanup=%s\n' "$crosvm_left" >> "$work/cleanup.txt"
  write_receipt >/dev/null
  if [ "$left" -eq 0 ]; then
    rm -rf -- "$work"
  else
    printf 'work directory kept for diagnosis: a process still references it\n' >&2
  fi
  rmdir "$lock" 2>/dev/null
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$home" "$runtime" "$work/t" || die "cannot create work directories"
export TMPDIR=$work/t
export PATH="$CVD_HOST_DIR/bin:$PATH"

# Private copy of the pinned product directory, verified against the manifest.
mkdir -p "$prod" && cp -a "$ANDROID_PRODUCT_OUT/." "$prod/" && chmod -R u+rwX "$prod" \
  || die "cannot create the private product copy"
if [ -n "$(find "$prod" -type l -print -quit)" ]; then
  die "private product copy contains a symbolic link"
fi
python3 -I - "$manifest" "$prod" > "$work/verify.txt" 2>&1 <<'PY'
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath

manifest_path, product_out = Path(sys.argv[1]), Path(sys.argv[2])
document = json.loads(manifest_path.read_text(encoding="utf-8"))
source = document.get("source", {})
if (
    source.get("buildId") != "16373615"
    or source.get("target") != "aosp_cf_arm64_only_phone-userdebug"
    or document.get("architecture") != "arm64"
):
    raise SystemExit("checked-in manifest does not identify the pinned ARM64 Cuttlefish build")
root = product_out.resolve()
count = 0
for artifact in document["artifacts"]:
    relative = PurePosixPath(artifact["file"])
    resolved = root.joinpath(*relative.parts).resolve(strict=True)
    if root not in resolved.parents or not resolved.is_file():
        raise SystemExit("artifact resolves outside the product output directory")
    if resolved.stat().st_size != artifact["size"]:
        raise SystemExit("size mismatch for an artifact")
    digest = hashlib.sha256()
    with resolved.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    if digest.hexdigest() != artifact["sha256"]:
        raise SystemExit("SHA-256 mismatch for an artifact")
    count += 1
print(f"verified {count} artifacts against build 16373615")
PY
[ $? -eq 0 ] || die "private product copy does not match the pinned manifest"

touch "$work/started"
group_created=1
timeout 900 cvd create \
  --host_path="$CVD_HOST_DIR" \
  --product_path="$prod" \
  --base_directory="$runtime" \
  --group_name="$group" \
  --base_instance_num="$instance" \
  --num_instances=1 \
  --gpu_vhost_user_mode=off \
  --nostart \
  --cpus="$cpus" \
  --memory_mb="$memory" \
  "${extra[@]}" > "$work/create.log" 2>&1
create_rc=$?
[ "$create_rc" -eq 0 ] || die "cvd create failed with exit $create_rc"

t0=$(date +%s)
end=$((t0 + deadline))
HOME=$home TMPDIR=$work/t timeout --kill-after=30 $((deadline + 120)) cvd \
  "--group_name=$group" start \
  --boot_timeout_secs="$deadline" \
  --cpus="$cpus" \
  --memory_mb="$memory" \
  --gpu_vhost_user_mode=off \
  "${extra[@]}" > "$work/start.log" 2>&1 &
start_pid=$!

: > "$work/poll.txt"
start_done_at=
while :; do
  now=$(date +%s)
  el=$((now - t0))
  if [ "$start_rc" = not-run ] || [ "$start_rc" = running ]; then
    if kill -0 "$start_pid" 2>/dev/null; then
      start_rc=running
    else
      wait "$start_pid"
      start_rc=$?
      start_done_at=$el
    fi
  fi
  adb connect "127.0.0.1:$adb_port" >/dev/null 2>&1
  state=$(timeout 15 adb -s "127.0.0.1:$adb_port" get-state 2>/dev/null | tr -d '\r')
  last_state=$state
  value=
  if [ "$state" = device ]; then
    value=$(timeout 25 adb -s "127.0.0.1:$adb_port" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [ -n "$value" ] || value=unset
  fi
  rss_pids=$(pgrep -d, -f -- "$work" 2>/dev/null)
  crosvm_count=0
  crosvm_rss=0
  if [ -n "$rss_pids" ]; then
    read -r crosvm_count crosvm_rss < <(ps -o pid=,rss=,comm= -p "$rss_pids" 2>/dev/null \
      | awk '$3 ~ /crosvm/ {n++; s+=$2} END {print n+0, s+0}')
  fi
  kmsg_marker=0
  kmsg_file=$(instance_logs kernel.log | head -n 1)
  if [ -n "$kmsg_file" ]; then
    kmsg_marker=$(grep -a -c -F -- VIRTUAL_DEVICE_BOOT_COMPLETED "$kmsg_file" 2>/dev/null || true)
  fi
  printf '%s\tstate=%s\tboot_completed=%s\tkmsg_boot_marker=%s\tstart=%s\tcrosvm=%s\trss_kib=%s\n' \
    "$el" "${state:-none}" "${value:-none}" "${kmsg_marker:-0}" "$start_rc" "$crosvm_count" "$crosvm_rss" >> "$work/poll.txt"
  if [ "$value" = 1 ] && [ -z "$boot_at" ]; then
    boot_at=$el
    boot_signal=adb-getprop
  fi
  if [ "${kmsg_marker:-0}" -gt 0 ] 2>/dev/null && [ -z "$boot_at" ]; then
    boot_at=$el
    boot_signal=kernel-log-VIRTUAL_DEVICE_BOOT_COMPLETED
  fi
  if [ -n "$boot_at" ] && [ $((el - boot_at)) -ge "$dwell" ]; then
    break
  fi
  if [ -n "$start_done_at" ] && [ -z "$boot_at" ] && [ $((el - start_done_at)) -ge 300 ]; then
    break
  fi
  if [ "$now" -ge "$end" ]; then
    break
  fi
  sleep 15
done
elapsed_end=$(( $(date +%s) - t0 ))
if [ "$start_rc" = running ]; then
  start_rc="killed-at-${elapsed_end}s"
fi
if [ -n "$start_pid" ] && kill -0 "$start_pid" 2>/dev/null; then
  kill "$start_pid" 2>/dev/null
  wait "$start_pid" 2>/dev/null
fi

