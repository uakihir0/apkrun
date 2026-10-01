#!/usr/bin/env bash

set -euo pipefail
umask 077

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)

if [ "$(uname -s)" != Linux ]; then
  printf 'This diagnostic requires the Linux Cuttlefish reference host.\n' >&2
  exit 2
fi
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
  printf 'HOME must name the Linux reference user home directory.\n' >&2
  exit 2
fi
if [ -z "${CVD_HOST_DIR:-}" ] || [ ! -x "$CVD_HOST_DIR/bin/adb" ] \
  || [ ! -x "$CVD_HOST_DIR/bin/cvd" ] \
  || [ ! -x "$CVD_HOST_DIR/bin/launch_cvd" ]; then
  printf 'Set CVD_HOST_DIR to the pinned Cuttlefish host package.\n' >&2
  exit 2
fi
if [ -z "${ANDROID_PRODUCT_OUT:-}" ] || [ ! -d "$ANDROID_PRODUCT_OUT" ]; then
  printf 'Set ANDROID_PRODUCT_OUT to the pinned build 16373615 product directory.\n' >&2
  exit 2
fi
if ! python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 12))'; then
  printf 'This diagnostic requires Python 3.12 or later.\n' >&2
  exit 2
fi

instance_num=${APKRUN_CVD_INSTANCE_NUM:-1}
case "$instance_num" in
  ''|*[!0-9]*|0*)
    printf 'APKRUN_CVD_INSTANCE_NUM must be a positive integer.\n' >&2
    exit 2
    ;;
esac
if [ "$instance_num" -gt 59016 ]; then
  printf 'APKRUN_CVD_INSTANCE_NUM must not exceed 59016.\n' >&2
  exit 2
fi
if [ "$instance_num" -ne 1 ]; then
  printf 'The pinned #064 comparison requires Cuttlefish instance 1.\n' >&2
  exit 2
fi
adb_port=$((6520 + instance_num - 1))
serial="127.0.0.1:$adb_port"

if ps -ww -C crosvm -o pid= | awk 'NF { found=1 } END { exit !found }'; then
  printf 'A crosvm process is already running; use a dedicated reference VM.\n' >&2
  exit 2
fi

data_root=${APKRUN_DIAGNOSTIC_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/apkrun/cuttlefish-boot-diagnosis}
case "$data_root" in
  /*) ;;
  *)
    printf 'APKRUN_DIAGNOSTIC_ROOT must be an absolute path.\n' >&2
    exit 2
    ;;
esac
work_parent="$data_root/work"
results_root="$data_root/results"
if [ -L "$data_root" ] || [ -L "$work_parent" ] || [ -L "$results_root" ]; then
  printf 'Diagnostic data directories must not be symbolic links.\n' >&2
  exit 2
fi
if ! mkdir -p "$work_parent" "$results_root"; then
  printf 'Could not create the private diagnostic data directory: %s\n' "$data_root" >&2
  exit 1
fi
chmod 700 "$work_parent" "$results_root"
if [ -L "$data_root" ] || [ -L "$work_parent" ] || [ -L "$results_root" ]; then
  printf 'Diagnostic data directories must not be symbolic links.\n' >&2
  exit 2
fi
work_root=$(mktemp -d "$work_parent/gpu-none.XXXXXX")
tmp_root="$work_root/tmp"
adb_home="$work_root/adb-home"
adb_socket_dir=
adb_server_socket_path=
adb_server_socket=
adb_log_root="$work_root/adb-live"
done_marker="$work_root/capture.done"
fleet_report="$work_root/cvd-fleet.json"
host_identity="$work_root/host-identity.json"
capture_child_pid=
watcher_pid=
adb_server_pid=
adb_server_started=0
keep_work=0
interrupted=0
capture_status=0
watcher_status=0

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_path="$results_root/gpu-none-$timestamp-$$"
if [ -e "$result_path" ]; then
  printf 'Refusing to overwrite diagnostic result: %s\n' "$result_path" >&2
  rm -rf "$work_root"
  exit 2
fi

adb_socket_dir=$(mktemp -d /tmp/apkrun-adb.XXXXXX)
adb_server_socket_path="$adb_socket_dir/server.sock"
adb_server_socket="localfilesystem:$adb_server_socket_path"

preserve_work() {
  if ! scrub_raw_logcat; then
    printf 'Raw logcat could not be scrubbed; refusing to publish or retain it.\n' >&2
    if cvd_is_clean; then
      rm -rf "$work_root" || true
      keep_work=0
      return 0
    fi
    printf 'Cuttlefish cleanup is incomplete; its private workspace must remain available.\n' >&2
  fi
  keep_work=1
  printf 'Private diagnostic workspace retained for cleanup: %s\n' "$work_root" >&2
}

capture_child_exited() {
  local process_state
  if ! kill -0 "$capture_child_pid" 2>/dev/null; then
    return 0
  fi
  process_state=$(ps -p "$capture_child_pid" -o stat= 2>/dev/null | tr -d ' ')
  [[ "$process_state" = Z* ]]
}

capture_child_identity_matches() {
  local arguments
  arguments=$(ps -ww -p "$capture_child_pid" -o args= 2>/dev/null || true)
  printf '%s\n' "$arguments" | grep -F "$experiment_tools/run_capture.py" >/dev/null
}

wait_for_capture_child() {
  local maximum_seconds=$1
  for _ in $(seq 1 "$maximum_seconds"); do
    if capture_child_exited; then
      return 0
    fi
    sleep 1
  done
  capture_child_exited
}

stop_capture_child() {
  local signal_name=$1
  [ -n "$capture_child_pid" ] || return 0
  if capture_child_exited; then
    wait "$capture_child_pid" 2>/dev/null || true
    capture_child_pid=
    return 0
  fi
  if ! capture_child_identity_matches; then
    printf 'Capture supervisor identity changed; refusing to signal an unrelated process.\n' >&2
    preserve_work
    return 1
  fi
  kill -s "$signal_name" "$capture_child_pid" 2>/dev/null || true
  if wait_for_capture_child 145; then
    wait "$capture_child_pid" 2>/dev/null || true
    capture_child_pid=
    return 0
  fi
  if capture_child_exited; then
    wait "$capture_child_pid" 2>/dev/null || true
    capture_child_pid=
    return 0
  fi
  if ! capture_child_identity_matches; then
    printf 'Capture supervisor identity changed before KILL; refusing to signal an unrelated process.\n' >&2
    preserve_work
    return 1
  fi
  kill -KILL "$capture_child_pid" 2>/dev/null || true
  if wait_for_capture_child 3; then
    wait "$capture_child_pid" 2>/dev/null || true
    capture_child_pid=
    return 0
  fi
  printf 'Capture supervisor did not exit after TERM and KILL.\n' >&2
  preserve_work
  return 1
}

cvd_is_clean() {
  local remaining_homes remaining_crosvm
  remaining_homes=$(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d \
    -name 'apkrun-cvd-home.default.*' -print -quit 2>/dev/null || true)
  remaining_crosvm=$(ps -ww -C crosvm -o pid= 2>/dev/null || true)
  [ -z "$remaining_homes" ] && ! printf '%s\n' "$remaining_crosvm" | awk 'NF { found=1 } END { exit !found }'
}

scrub_raw_logcat() {
  local remaining
  if [ -d "$adb_log_root" ]; then
    find "$adb_log_root" -maxdepth 1 -type f \
      \( -name 'logcat-*.txt' -o -name '.logcat-*.txt' \) -delete
  fi
  if [ -d "$work_root/Images/reference/16373615" ]; then
    find "$work_root/Images/reference/16373615" -type f -name 'logcat.txt.gz' -delete
    find "$work_root/Images/reference/16373615" -type f -name '.logcat.raw' -delete
  fi
  if [ -d "$adb_log_root" ]; then
    remaining=$(find "$adb_log_root" -maxdepth 1 -type f \
      \( -name 'logcat-*.txt' -o -name '.logcat-*.txt' \) -print -quit) || return 1
    [ -z "$remaining" ] || return 1
  fi
  if [ -d "$work_root/Images/reference/16373615" ]; then
    remaining=$(find "$work_root/Images/reference/16373615" -type f \
      \( -name 'logcat.txt.gz' -o -name '.logcat.raw' \) -print -quit) || return 1
    [ -z "$remaining" ] || return 1
  fi
}

stop_adb_server() {
  local server_arguments server_state
  [ "$adb_server_started" -eq 1 ] || return 0
  if ! cvd_is_clean; then
    printf 'ADB server left running because Cuttlefish cleanup is not verified.\n' >&2
    return 1
  fi
  if ! kill -0 "$adb_server_pid" 2>/dev/null; then
    wait "$adb_server_pid" 2>/dev/null || true
    adb_server_started=0
    return 0
  fi
  server_state=$(ps -p "$adb_server_pid" -o stat= 2>/dev/null | tr -d ' ')
  if [[ "$server_state" = Z* ]]; then
    wait "$adb_server_pid" 2>/dev/null || true
    adb_server_started=0
    return 0
  fi
  server_arguments=$(ps -ww -p "$adb_server_pid" -o args= 2>/dev/null || true)
  if ! printf '%s\n' "$server_arguments" | grep -F "$CVD_HOST_DIR/bin/adb" >/dev/null \
    || ! printf '%s\n' "$server_arguments" | grep -F -- "$adb_server_socket" >/dev/null \
    || ! printf '%s\n' "$server_arguments" | grep -F 'nodaemon server' >/dev/null; then
    printf 'Dedicated ADB server process identity could not be verified.\n' >&2
    return 1
  fi
  kill -TERM "$adb_server_pid" 2>/dev/null || true
  for _ in $(seq 1 10); do
    if ! kill -0 "$adb_server_pid" 2>/dev/null; then
      wait "$adb_server_pid" 2>/dev/null || true
      adb_server_started=0
      return 0
    fi
    server_state=$(ps -p "$adb_server_pid" -o stat= 2>/dev/null | tr -d ' ')
    if [[ "$server_state" = Z* ]]; then
      wait "$adb_server_pid" 2>/dev/null || true
      adb_server_started=0
      return 0
    fi
    sleep 1
  done
  server_arguments=$(ps -ww -p "$adb_server_pid" -o args= 2>/dev/null || true)
  if ! printf '%s\n' "$server_arguments" | grep -F "$CVD_HOST_DIR/bin/adb" >/dev/null \
    || ! printf '%s\n' "$server_arguments" | grep -F -- "$adb_server_socket" >/dev/null \
    || ! printf '%s\n' "$server_arguments" | grep -F 'nodaemon server' >/dev/null; then
    server_state=$(ps -p "$adb_server_pid" -o stat= 2>/dev/null | tr -d ' ')
    if [[ "$server_state" = Z* ]] || ! kill -0 "$adb_server_pid" 2>/dev/null; then
      wait "$adb_server_pid" 2>/dev/null || true
      adb_server_started=0
      return 0
    fi
    printf 'Dedicated ADB server identity changed before KILL; refusing to signal it.\n' >&2
    return 1
  fi
  kill -KILL "$adb_server_pid" 2>/dev/null || true
  for _ in $(seq 1 5); do
    if ! kill -0 "$adb_server_pid" 2>/dev/null; then
      wait "$adb_server_pid" 2>/dev/null || true
      adb_server_started=0
      return 0
    fi
    server_state=$(ps -p "$adb_server_pid" -o stat= 2>/dev/null | tr -d ' ')
    if [[ "$server_state" = Z* ]]; then
      wait "$adb_server_pid" 2>/dev/null || true
      adb_server_started=0
      return 0
    fi
    sleep 1
  done
  printf 'Dedicated ADB server resisted TERM and KILL (pid %s).\n' \
    "$adb_server_pid" >&2
  return 1
}

stop_watcher() {
  if [ -n "$watcher_pid" ]; then
    : > "$done_marker"
    wait "$watcher_pid" || true
    watcher_pid=
  fi
}

cleanup() {
  local original_status=$?
  trap - EXIT
  if [ -n "$capture_child_pid" ]; then
    stop_capture_child TERM || true
  fi
  stop_watcher
  if ! cvd_is_clean; then
    scrub_raw_logcat || true
    preserve_work
  elif [ "$adb_server_started" -eq 1 ]; then
    stop_adb_server || preserve_work
  fi
  if [ -n "$adb_socket_dir" ] && [ "$adb_server_started" -eq 0 ]; then
    if ! rm -rf "$adb_socket_dir"; then
      printf 'Could not remove private ADB socket directory: %s\n' \
        "$adb_socket_dir" >&2
      preserve_work
    fi
  fi
  if [ "$keep_work" -eq 0 ]; then
    rm -rf "$work_root" || preserve_work
  fi
  exit "$original_status"
}

handle_signal() {
  local signal_name=$1
  local exit_status=$2
  interrupted=1
  trap '' HUP INT TERM
  if [ -n "$capture_child_pid" ]; then
    stop_capture_child "$signal_name" || true
  fi
  stop_watcher
  scrub_raw_logcat || true
  if cvd_is_clean; then
    stop_adb_server || true
  else
    preserve_work
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

mkdir -p "$tmp_root" "$adb_home" "$adb_log_root"
chmod 700 "$work_root" "$tmp_root" "$adb_home" "$adb_log_root"
tool_destination="$work_root/Images/tools/reference"
manifest_destination="$work_root/Images/manifests/16373615"
experiment_tools="$work_root/experiment-tools"
capture_status_root="$work_root/capture-status"
capture_run_status="$work_root/capture-run-status.json"
mkdir -p "$tool_destination" "$manifest_destination" \
  "$experiment_tools" "$capture_status_root"
cp "$repo_root/Images/tools/reference/capture.sh" \
  "$repo_root/Images/tools/reference/capture_cvd_start.py" \
  "$repo_root/Images/tools/reference/compare_boot.py" \
  "$repo_root/Images/tools/reference/normalize.yaml" \
  "$repo_root/Images/tools/reference/guest-capture.txt" \
  "$tool_destination/"
cp "$script_dir/capture-gpu-none.sh" "$script_dir/capture_bounded.py" \
  "$script_dir/experiment_support.py" "$script_dir/run_capture.py" \
  "$script_dir/summarize_logcat.py" "$experiment_tools/"
cp "$experiment_tools/capture_bounded.py" "$tool_destination/"
cp "$repo_root/Images/manifests/16373615/android-image.json" "$manifest_destination/"
chmod 700 "$experiment_tools" "$capture_status_root"

capture_script="$tool_destination/capture.sh"
adb_shim_dir="$work_root/bin"
mkdir -p "$adb_shim_dir"
cat > "$adb_shim_dir/adb" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [ -z "${APKRUN_DIAGNOSTIC_ADB_SERVER_PID:-}" ] \
  || ! kill -0 "$APKRUN_DIAGNOSTIC_ADB_SERVER_PID" 2>/dev/null \
  || [ ! -S "${APKRUN_DIAGNOSTIC_ADB_SERVER_SOCKET_PATH:-}" ]; then
  printf 'The private diagnostic ADB server is not running.\n' >&2
  exit 1
fi
server_arguments=$(ps -ww -p "$APKRUN_DIAGNOSTIC_ADB_SERVER_PID" -o args= 2>/dev/null || true)
if ! printf '%s\n' "$server_arguments" | grep -F "$CVD_HOST_DIR/bin/adb" >/dev/null \
  || ! printf '%s\n' "$server_arguments" | grep -F -- "$APKRUN_DIAGNOSTIC_ADB_SERVER_SOCKET" >/dev/null \
  || ! printf '%s\n' "$server_arguments" | grep -F 'nodaemon server' >/dev/null; then
  printf 'The private diagnostic ADB server identity is not verified.\n' >&2
  exit 1
fi
exec "$CVD_HOST_DIR/bin/adb" -L "$APKRUN_DIAGNOSTIC_ADB_SERVER_SOCKET" "$@"
SHIM
chmod 700 "$adb_shim_dir/adb"

python3 "$experiment_tools/experiment_support.py" \
  patch-capture --path "$capture_script"
bash -n "$capture_script"

export APKRUN_DIAGNOSTIC_ADB_SHIM_DIR="$adb_shim_dir"
export APKRUN_DIAGNOSTIC_ADB_SERVER_PID=
export APKRUN_DIAGNOSTIC_ADB_SERVER_SOCKET="$adb_server_socket"
export APKRUN_DIAGNOSTIC_ADB_SERVER_SOCKET_PATH="$adb_server_socket_path"
export APKRUN_EXPERIMENT_STATUS_ROOT="$capture_status_root"
unset ADB_SERVER_SOCKET ADB_SERVER_PORT ANDROID_SERIAL

adb_cleanup_failure_marker="$adb_log_root/incomplete-process-cleanup"
check_bounded_cleanup() {
  local status_path=$1
  if [ ! -f "$status_path" ] || [ -L "$status_path" ] || \
    ! python3 - "$status_path" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
raise SystemExit(
    0
    if status.get("schemaVersion") == 1 and status.get("cleanupComplete") is True
    else 1
)
PY
  then
    : > "$adb_cleanup_failure_marker"
  fi
}

baseline_record="$repo_root/Images/reference/16373615/incomplete/default-20261001T120904-49816"
if [ -e "$baseline_record/host.json" ] && [ -e "$baseline_record/cuttlefish_config.json" ]; then
  :
else
  printf 'The pinned 2026-10-01 default baseline record is missing.\n' >&2
  exit 2
fi

if ! mkdir -p "$work_root/fleet-home"; then
  printf 'Could not create the isolated Cuttlefish identity home.\n' >&2
  exit 1
fi
chmod 700 "$work_root/fleet-home"
if ! python3 "$experiment_tools/capture_bounded.py" \
  --timeout-seconds 30 --max-bytes 1048576 \
  --fail-on-truncate --merge-stderr \
  --output "$fleet_report" --status "$work_root/fleet-status.json" -- \
  env "HOME=$work_root/fleet-home" "PATH=$CVD_HOST_DIR/bin:$PATH" \
  "$CVD_HOST_DIR/bin/cvd" fleet; then
  printf 'Cuttlefish fleet preflight failed; see the private diagnostic workspace.\n' >&2
  preserve_work
  exit 1
fi
check_bounded_cleanup "$work_root/fleet-status.json"
if [ -e "$adb_cleanup_failure_marker" ]; then
  printf 'Cuttlefish fleet process cleanup is incomplete; refusing to launch the guest.\n' >&2
  preserve_work
  exit 1
fi
if ! python3 "$experiment_tools/experiment_support.py" verify-host \
  --repo-root "$repo_root" \
  --baseline-record "$baseline_record" \
  --fleet-report "$fleet_report" \
  --experiment-root "$experiment_tools" \
  --patched-capture "$capture_script" \
  --output "$host_identity"; then
  preserve_work
  exit 1
fi

HOME="$adb_home" "$CVD_HOST_DIR/bin/adb" \
  -L "$adb_server_socket" nodaemon server \
  > /dev/null 2>&1 &
adb_server_pid=$!
adb_server_started=1
export APKRUN_DIAGNOSTIC_ADB_SERVER_PID="$adb_server_pid"
adb_ready=0
for _ in $(seq 1 20); do
  if ! kill -0 "$adb_server_pid" 2>/dev/null; then
    break
  fi
  if [ -S "$adb_server_socket_path" ]; then
    preflight_output="$work_root/adb-preflight.txt"
    preflight_status="$work_root/adb-preflight.json"
    preflight_exit=0
    python3 "$experiment_tools/capture_bounded.py" \
      --timeout-seconds 2 --max-bytes 4096 --fail-on-truncate \
      --output "$preflight_output" --status "$preflight_status" -- \
      env "HOME=$adb_home" "$CVD_HOST_DIR/bin/adb" \
        -L "$adb_server_socket" devices || preflight_exit=$?
    check_bounded_cleanup "$preflight_status"
    if [ "$preflight_exit" -eq 0 ] \
      && grep -q '^List of devices attached$' "$preflight_output"; then
      adb_ready=1
    fi
    rm -f "$preflight_output" "$preflight_status"
    if [ -e "$adb_cleanup_failure_marker" ]; then
      printf 'ADB preflight process cleanup is incomplete; refusing to launch the guest.\n' >&2
      preserve_work
      exit 1
    fi
    [ "$adb_ready" -eq 1 ] && break
  fi
  sleep 1
done
if [ "$adb_ready" -ne 1 ]; then
  printf 'Could not start the isolated ADB server; see the private diagnostic workspace.\n' >&2
  preserve_work
  exit 1
fi

: > "$adb_log_root/adb-state.txt"
rm -f "$done_marker"

capture_adb_control_output() {
  local cvd_home=$1 timeout_seconds=$2 maximum_bytes=$3
  local output_path=$4 status_path=$5
  local command_exit=0
  shift 5
  python3 "$tool_destination/capture_bounded.py" \
    --timeout-seconds "$timeout_seconds" \
    --max-bytes "$maximum_bytes" --fail-on-truncate \
    --output "$output_path" --status "$status_path" -- \
    env "HOME=$cvd_home" "$adb_shim_dir/adb" "$@" || command_exit=$?
  check_bounded_cleanup "$status_path"
  return "$command_exit"
}

watch_adb() {
  local sample_number=0
  local poll_number=0
  local total_logcat_bytes=0
  local max_logcat_bytes=41943040
  local per_sample_limit=1048576
  local cvd_home timestamp devices device_state boot_state system_server_count
  local sample_name sample_temporary sample_status sample_size remaining_limit
  local devices_temporary devices_status boot_temporary boot_status
  local server_count_temporary server_count_status
  local connect_temporary connect_status

  while [ ! -e "$done_marker" ] && [ "$sample_number" -lt 40 ]; do
    poll_number=$((poll_number + 1))
    cvd_home=$(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d \
      -name 'apkrun-cvd-home.default.*' -print -quit)
    if [ -z "$cvd_home" ]; then
      sleep 2
      continue
    fi

    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    connect_temporary="$adb_log_root/.connect-$poll_number"
    connect_status="$adb_log_root/.connect-$poll_number.json"
    capture_adb_control_output "$cvd_home" 4 4096 \
      "$connect_temporary" "$connect_status" connect "$serial" || true
    rm -f "$connect_temporary" "$connect_status"
    devices_temporary="$adb_log_root/.devices-$poll_number"
    devices_status="$adb_log_root/.devices-$poll_number.json"
    devices=
    if capture_adb_control_output "$cvd_home" 4 4096 \
      "$devices_temporary" "$devices_status" devices; then
      devices=$(< "$devices_temporary")
    fi
    rm -f "$devices_temporary" "$devices_status"
    device_state=$(printf '%s\n' "$devices" | awk -v serial="$serial" \
      '$1 == serial { print $2; exit }')
    case "$device_state" in
      device|offline|unauthorized|bootloader|recovery|sideload) ;;
      *) device_state=unknown ;;
    esac
    boot_state=unknown
    system_server_count=unknown

    if [ "$device_state" = device ]; then
      boot_temporary="$adb_log_root/.boot-state-$poll_number"
      boot_status="$adb_log_root/.boot-state-$poll_number.json"
      boot_state=
      if capture_adb_control_output "$cvd_home" 5 256 \
        "$boot_temporary" "$boot_status" \
        -s "$serial" shell getprop sys.boot_completed; then
        boot_state=$(tr -d '\r' < "$boot_temporary")
      fi
      rm -f "$boot_temporary" "$boot_status"
      if [[ ! "$boot_state" =~ ^[01]$ ]]; then
        boot_state=unknown
      fi
      server_count_temporary="$adb_log_root/.server-count-$poll_number"
      server_count_status="$adb_log_root/.server-count-$poll_number.json"
      system_server_count=
      if capture_adb_control_output "$cvd_home" 5 256 \
        "$server_count_temporary" "$server_count_status" \
        -s "$serial" shell getprop sys.system_server.start_count; then
        system_server_count=$(tr -d '\r' < "$server_count_temporary")
      fi
      rm -f "$server_count_temporary" "$server_count_status"
      if [[ ! "$system_server_count" =~ ^[0-9]{1,6}$ ]]; then
        system_server_count=unknown
      fi
      if [ "$sample_number" -lt 40 ] && [ "$total_logcat_bytes" -lt "$max_logcat_bytes" ]; then
        sample_number=$((sample_number + 1))
        sample_name=$(printf 'logcat-%03d.txt' "$sample_number")
        sample_temporary="$adb_log_root/.$sample_name"
        sample_status="$adb_log_root/.$sample_name.json"
        sample_status_retained="$adb_log_root/${sample_name%.txt}.json"
        remaining_limit=$((max_logcat_bytes - total_logcat_bytes))
        if [ "$remaining_limit" -gt "$per_sample_limit" ]; then
          remaining_limit=$per_sample_limit
        fi
        timeout --kill-after=2s 12s env HOME="$cvd_home" \
          python3 "$tool_destination/capture_bounded.py" \
          --timeout-seconds 8 --max-bytes "$remaining_limit" \
          --output "$sample_temporary" \
          --status "$sample_status" -- "$adb_shim_dir/adb" \
          -s "$serial" logcat -b all -d -v threadtime -t 3000 || true
        check_bounded_cleanup "$sample_status"
        if [ -f "$sample_status" ] && [ ! -L "$sample_status" ]; then
          mv "$sample_status" "$sample_status_retained"
          if [ -f "$sample_temporary" ] && [ ! -L "$sample_temporary" ]; then
            sample_size=$(wc -c < "$sample_temporary" | tr -d ' ')
            if [ "$sample_size" -gt 0 ]; then
              mv "$sample_temporary" "$adb_log_root/$sample_name"
              total_logcat_bytes=$((total_logcat_bytes + sample_size))
            else
              rm -f "$sample_temporary"
            fi
          fi
        else
          rm -f "$sample_temporary" "$sample_status"
          cat > "$sample_status_retained" <<'STATUS'
{"schemaVersion":1,"bytesWritten":0,"truncated":false,"timedOut":false,"cleanupComplete":false,"childExitCode":null,"signal":null}
STATUS
        fi
      fi
    fi

    printf '%s\tadb=%s\tboot_completed=%s\tsystem_server_start_count=%s\n' \
      "$timestamp" "${device_state:-unavailable}" "${boot_state:-empty}" \
      "${system_server_count:-empty}" >> "$adb_log_root/adb-state.txt"
    sleep 15
  done
}

watch_adb &
watcher_pid=$!
set +e
TMPDIR="$tmp_root" APKRUN_CVD_PACKAGE_VERSION=1.57.0 \
  APKRUN_BOOT_TIMEOUT_SECONDS=600 \
  python3 "$experiment_tools/run_capture.py" \
  --timeout-seconds 900 \
  --cleanup-grace-seconds 140 \
  --status "$capture_run_status" \
  -- "$capture_script" default >/dev/null 2>&1 &
capture_child_pid=$!
wait "$capture_child_pid"
capture_status=$?
capture_child_pid=
set -e
: > "$done_marker"
wait "$watcher_pid" || watcher_status=$?
watcher_pid=
if [ "$watcher_status" -ne 0 ]; then
  : > "$adb_cleanup_failure_marker"
fi

if [ "$interrupted" -eq 1 ]; then
  scrub_raw_logcat || true
  preserve_work
  exit 130
fi

if [ ! -f "$capture_run_status" ]; then
  printf 'Capture supervisor did not record a completed run.\n' >&2
  scrub_raw_logcat || true
  preserve_work
  exit 1
fi
capture_timed_out=$(python3 - "$capture_run_status" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print("true" if document.get("timedOut") is True else "false")
PY
)
if [ "$capture_timed_out" = true ]; then
  scrub_raw_logcat || true
  printf 'The capture exceeded its 900-second hard deadline; result will not be published.\n' >&2
  preserve_work
  exit 124
fi
capture_cleanup_complete=$(python3 - "$capture_run_status" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
complete = (
    document.get("cleanupComplete") is True
    and document.get("childExitCode") is not None
)
print("true" if complete else "false")
PY
)
if [ "$capture_cleanup_complete" != true ]; then
  printf 'Capture process cleanup is not verified; result will not be published.\n' >&2
  preserve_work
  exit 1
fi

capture_record_root="$work_root/Images/reference/16373615"
capture_record="$capture_record_root/default"
if [ ! -d "$capture_record" ]; then
  shopt -s nullglob
  incomplete_candidates=("$capture_record_root"/incomplete/*)
  shopt -u nullglob
  valid_incomplete=()
  for candidate in "${incomplete_candidates[@]}"; do
    if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
      valid_incomplete+=("$candidate")
    fi
  done
  if [ "${#valid_incomplete[@]}" -eq 1 ]; then
    capture_record=${valid_incomplete[0]}
  fi
fi
case "$capture_record" in
  "$capture_record_root"/*) ;;
  *)
    printf 'The capture script did not retain a record inside its private workspace.\n' >&2
    preserve_work
    exit 1
    ;;
esac
if [ ! -d "$capture_record" ] || [ -L "$capture_record" ]; then
  printf 'The capture script did not retain a regular normalized record.\n' >&2
  preserve_work
  exit 1
fi

if ! cvd_is_clean; then
  scrub_raw_logcat || true
  printf 'Cuttlefish cleanup is not verified; the result will not be published.\n' >&2
  preserve_work
  exit 1
fi
stop_adb_server || {
  scrub_raw_logcat || true
  preserve_work
  exit 1
}
if [ "$watcher_status" -ne 0 ] || [ -e "$adb_cleanup_failure_marker" ]; then
  scrub_raw_logcat || true
  printf 'ADB helper cleanup or logcat watcher status is incomplete; result will not be published.\n' >&2
  preserve_work || true
  exit 1
fi

adb_state="$adb_log_root/adb-state.txt"
cp "$adb_state" "$capture_record/adb-state.txt"
logcat_summary="$work_root/logcat-summary.json"
python3 "$experiment_tools/summarize_logcat.py" \
  --snapshots "$adb_log_root" \
  --capture-logcat "$capture_record/logcat.txt.gz" \
  --output "$logcat_summary"
cleanup_incomplete_samples=$(python3 - "$logcat_summary" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(summary.get("liveLogcatCleanupIncompleteSampleCount", -1))
PY
)
if [ "$cleanup_incomplete_samples" != 0 ]; then
  printf 'Live ADB logcat cleanup is incomplete; result will not be published.\n' >&2
  scrub_raw_logcat || true
  preserve_work || true
  exit 1
fi
python3 "$experiment_tools/experiment_support.py" record \
  --capture-record "$capture_record" \
  --host-identity "$host_identity" \
  --logcat-summary "$logcat_summary" \
  --adb-state "$capture_record/adb-state.txt" \
  --capture-exit-code "$capture_status" \
  --adb-endpoint "$serial" \
  --capture-status-root "$capture_status_root" \
  --capture-run-status "$capture_run_status" \
  --output "$capture_record/experiment.json"

scrub_raw_logcat
if find "$work_root/Images/reference/16373615" -type f \
  \( -name 'logcat.txt.gz' -o -name '.logcat.raw' \) -print -quit | grep -q .; then
  printf 'Raw capture logcat could not be removed; result will not be published.\n' >&2
  preserve_work
  exit 1
fi
if find "$adb_log_root" -maxdepth 1 -type f \
  \( -name 'logcat-*.txt' -o -name '.logcat-*.txt' \) -print -quit | grep -q .; then
  printf 'Raw live ADB logcat snapshots could not be removed; result will not be published.\n' >&2
  preserve_work
  exit 1
fi

python3 "$tool_destination/compare_boot.py" normalize "$capture_record"
python3 - "$capture_record" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
for path in root.rglob("*"):
    if path.is_symlink() or not path.is_file():
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        continue
    if re.search(
        r"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f])",
        text,
    ):
        raise SystemExit(f"unredacted MAC address remains in {path.name}")
    if re.search(r"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----", text):
        raise SystemExit(f"private-key marker remains in {path.name}")
    if re.search(r"/(?:home/lima|var/tmp/cvd|Users/)[^\s\"']*", text):
        raise SystemExit(f"private host path remains in {path.name}")
PY

if ! cvd_is_clean || [ "$adb_server_started" -ne 0 ]; then
  printf 'Cuttlefish or ADB cleanup changed before publication; refusing to publish.\n' >&2
  preserve_work
  exit 1
fi
if [ -e "$result_path" ]; then
  printf 'Refusing to overwrite diagnostic result: %s\n' "$result_path" >&2
  preserve_work
  exit 1
fi
mv "$capture_record" "$result_path"
printf 'Normalized diagnostic record: %s\n' "$result_path"
printf 'Cuttlefish capture exit status: %s\n' "$capture_status"
