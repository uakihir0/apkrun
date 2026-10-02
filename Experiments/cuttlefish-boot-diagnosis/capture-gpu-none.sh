#!/usr/bin/env bash

set -euo pipefail
umask 077

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/../.." && pwd)
source "$script_dir/capture-lifecycle.sh"

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

gpu_mode=${APKRUN_DIAGNOSTIC_GPU_MODE:-none}
case "$gpu_mode" in
  none) gpu_mode_slug=none ;;
  guest_swiftshader) gpu_mode_slug=guest-swiftshader ;;
  *)
    printf 'APKRUN_DIAGNOSTIC_GPU_MODE must be none or guest_swiftshader.\n' >&2
    exit 2
    ;;
esac

console_enabled=${APKRUN_DIAGNOSTIC_CONSOLE:-true}
case "$console_enabled" in
  true) console_mode_slug=on ;;
  false) console_mode_slug=off ;;
  *)
    printf 'APKRUN_DIAGNOSTIC_CONSOLE must be true or false.\n' >&2
    exit 2
    ;;
esac

pause_in_bootloader=${APKRUN_DIAGNOSTIC_PAUSE_IN_BOOTLOADER:-false}
case "$pause_in_bootloader" in
  true|false) ;;
  *)
    printf 'APKRUN_DIAGNOSTIC_PAUSE_IN_BOOTLOADER must be true or false.\n' >&2
    exit 2
    ;;
esac
if [ "$pause_in_bootloader" = true ] && [ "$console_enabled" = false ]; then
  printf 'Bootloader pause requires APKRUN_DIAGNOSTIC_CONSOLE=true.\n' >&2
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

if ! require_no_crosvm; then
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
requested_data_root=$data_root
if ! canonical_data_root=$(run_committed_experiment_support \
  prepare-data-root --print-canonical --data-root "$requested_data_root"); then
  printf 'Could not prepare a private diagnostic data root; check ownership and parent permissions: %s\n' \
    "$requested_data_root" >&2
  exit 2
fi
data_root=$canonical_data_root
work_parent="$data_root/work"
results_root="$data_root/results"
workspace_token=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
if [[ ! "$workspace_token" =~ ^[a-f0-9]{64}$ ]]; then
  printf 'Could not create a private diagnostic workspace token.\n' >&2
  exit 1
fi
work_root=
tmp_root=
cvd_uid=$(id -u)
cvd_state_dir="/var/tmp/cvd/$cvd_uid"
if [ ! -d /var/tmp/cvd ] && [ -d /tmp/cvd ]; then
  cvd_state_dir="/tmp/cvd/$cvd_uid"
fi
short_cvd_root=
short_cvd_home_tmpdir=
short_cvd_physical_tmp_root=
short_cvd_fleet_home=
adb_home=
adb_socket_dir=
adb_server_socket_path=
adb_server_socket=
adb_log_root=
done_marker=
fleet_report=
host_identity=
result_path=
capture_child_pid=
capture_supervisor_stderr_pid=
capture_supervisor_stderr_start_time=
capture_supervisor_stderr_broker_target_pid=
capture_supervisor_stderr_broker_target_start_time=
capture_supervisor_stderr_signal_broker_pid=
watcher_pid=
watcher_start_time=
watcher_signal_broker_pid=
watcher_control_fd=
watcher_start_fd=
watcher_start_fifo=
watcher_control_fifo=
watcher_signal_broker_ready_file=
watcher_signal_broker_exit_file=
watcher_signal_broker_stopped_file=
watcher_stop_failed=0
adb_server_pid=
adb_server_started=0
keep_work=0
interrupted=0
capture_status=0
watcher_status=0
capture_supervisor_stderr_status_code=0
capture_supervisor_stderr_fifo_guard_open=0
capture_supervisor_stderr_start_gate_open=0
capture_supervisor_stderr_control_open=0
capture_supervisor_stderr_signal_broker_ready=0
capture_supervisor_stderr_stop_failed=0
capture_supervisor_stderr_signal_broker_stop_failed=0
capture_process_starting_role=
capture_process_starting_released=0
capture_process_startup_signal_name=
capture_process_startup_signal_exit_status=

stop_capture_child() {
  local signal_name=$1
  [ -n "$capture_child_pid" ] || return 0
  if ! stop_pinned_capture_process capture_child "$signal_name" 145 3; then
    preserve_work
    return 1
  fi
}

stop_adb_server() {
  [ "$adb_server_started" -eq 1 ] || return 0
  if ! cvd_is_clean; then
    printf 'ADB server left running because Cuttlefish cleanup is not verified.\n' >&2
    return 1
  fi
  if ! stop_pinned_capture_process adb_server TERM 10 5; then
    return 1
  fi
  adb_server_started=0
}

stop_watcher() {
  [ -n "$watcher_pid" ] || return 0
  if ! printf 'done\n' > "$done_marker"; then
    printf 'Could not signal the logcat watcher through its stop marker.\n' >&2
    watcher_stop_failed=1
    if [ -n "$watcher_pid" ]; then
      if ! stop_pinned_capture_process watcher TERM 5 3; then
        preserve_work
        return 1
      fi
    fi
    preserve_work
    return 1
  fi
  if [ -n "$watcher_pid" ]; then
    for _ in $(seq 1 450); do
      if _capture_process_exit_state watcher; then
        break
      fi
      sleep 0.1
    done
    if ! stop_pinned_capture_process watcher TERM 5 3; then
      preserve_work
      return 1
    fi
  fi
}

capture_supervisor_stderr_exited() {
  local exit_record
  if [ ! -e "$capture_supervisor_stderr_exit_file" ] \
    && [ ! -L "$capture_supervisor_stderr_exit_file" ]; then
    return 1
  fi
  if [ -L "$capture_supervisor_stderr_exit_file" ] \
    || [ ! -f "$capture_supervisor_stderr_exit_file" ]; then
    return 2
  fi
  if ! exit_record=$(< "$capture_supervisor_stderr_exit_file"); then
    return 2
  fi
  if [ "$exit_record" != \
    "$capture_supervisor_stderr_pid $capture_supervisor_stderr_start_time" ]; then
    return 2
  fi
  if [ -n "$capture_supervisor_stderr_pid" ]; then
    if wait "$capture_supervisor_stderr_pid"; then
      :
    else
      capture_supervisor_stderr_status_code=$?
    fi
    capture_supervisor_stderr_pid=
    capture_supervisor_stderr_start_time=
  fi
  return 0
}

stop_capture_supervisor_stderr_reader() {
  local signal_name exited_status
  [ -n "$capture_supervisor_stderr_pid" ] || return 0
  [ "$capture_supervisor_stderr_stop_failed" -eq 0 ] || return 1
  for _ in $(seq 1 5); do
    if capture_supervisor_stderr_exited; then
      if [ -n "$capture_supervisor_stderr_pid" ]; then
        wait "$capture_supervisor_stderr_pid" 2>/dev/null || true
        capture_supervisor_stderr_pid=
        capture_supervisor_stderr_start_time=
      fi
      return 0
    else
      exited_status=$?
    fi
    if [ "$exited_status" -eq 2 ]; then
      capture_supervisor_stderr_stop_failed=1
      printf 'Capture supervisor stderr exit marker is invalid; no signal request was sent.\n' >&2
      return 1
    fi
    sleep 1
  done
  if [ "$capture_supervisor_stderr_signal_broker_ready" -ne 1 ] \
    || [ "$capture_supervisor_stderr_control_open" -ne 1 ]; then
    capture_supervisor_stderr_stop_failed=1
    printf 'Capture supervisor stderr reader has no pinned signal broker; preserving its workspace.\n' >&2
    return 1
  fi
  for signal_name in TERM KILL; do
    if ! printf '%s\n' "$signal_name" >&7; then
      capture_supervisor_stderr_stop_failed=1
      printf 'Capture supervisor stderr signal broker did not accept the request.\n' >&2
      return 1
    fi
    for _ in $(seq 1 3); do
      if capture_supervisor_stderr_exited; then
        if [ -n "$capture_supervisor_stderr_pid" ]; then
          wait "$capture_supervisor_stderr_pid" 2>/dev/null || true
          capture_supervisor_stderr_pid=
          capture_supervisor_stderr_start_time=
        fi
        printf 'Capture supervisor stderr reader required %s during cleanup.\n' \
          "$signal_name" >&2
        capture_supervisor_stderr_stop_failed=1
        return 1
      else
        exited_status=$?
      fi
      if [ "$exited_status" -eq 2 ]; then
        capture_supervisor_stderr_stop_failed=1
        printf 'Capture supervisor stderr exit marker is invalid; no further signal request was sent.\n' >&2
        return 1
      fi
      sleep 1
    done
  done
  printf 'Capture supervisor stderr reader did not stop; preserving its workspace.\n' >&2
  capture_supervisor_stderr_stop_failed=1
  return 1
}

stop_capture_supervisor_stderr_signal_broker() {
  local broker_status stopped_record
  if [ "$capture_supervisor_stderr_control_open" -eq 1 ]; then
    exec 7>&-
    capture_supervisor_stderr_control_open=0
  fi
  [ -n "$capture_supervisor_stderr_signal_broker_pid" ] || return 0
  [ "$capture_supervisor_stderr_signal_broker_stop_failed" -eq 0 ] || return 1
  for _ in $(seq 1 5); do
    if [ -f "$capture_supervisor_stderr_signal_broker_stopped_file" ] \
      && [ ! -L "$capture_supervisor_stderr_signal_broker_stopped_file" ]; then
      stopped_record=$(< "$capture_supervisor_stderr_signal_broker_stopped_file")
      if [ "$stopped_record" != \
        "$capture_supervisor_stderr_broker_target_pid $capture_supervisor_stderr_broker_target_start_time" ]; then
        capture_supervisor_stderr_signal_broker_stop_failed=1
        printf 'Capture supervisor stderr broker stop record is invalid.\n' >&2
        return 1
      fi
      if wait "$capture_supervisor_stderr_signal_broker_pid"; then
        broker_status=0
      else
        broker_status=$?
      fi
      capture_supervisor_stderr_signal_broker_pid=
      capture_supervisor_stderr_signal_broker_ready=0
      capture_supervisor_stderr_broker_target_pid=
      capture_supervisor_stderr_broker_target_start_time=
      if [ "$broker_status" -ne 0 ]; then
        capture_supervisor_stderr_signal_broker_stop_failed=1
        printf 'Capture supervisor stderr signal broker exited with status %s.\n' \
          "$broker_status" >&2
        return 1
      fi
      return 0
    fi
    sleep 1
  done
  capture_supervisor_stderr_signal_broker_stop_failed=1
  printf 'Capture supervisor stderr signal broker did not stop; preserving its workspace.\n' >&2
  return 1
}

release_capture_supervisor_stderr_start_gate() {
  if [ "$capture_supervisor_stderr_start_gate_open" -eq 1 ]; then
    printf 'start\n' >&8 || true
    exec 8>&-
    capture_supervisor_stderr_start_gate_open=0
  fi
}

cleanup() {
  local original_status=$?
  trap - EXIT
  if [ -n "$capture_child_pid" ]; then
    stop_capture_child TERM || true
  fi
  release_capture_supervisor_stderr_start_gate
  if [ "$capture_supervisor_stderr_fifo_guard_open" -eq 1 ]; then
    exec 9>&-
    capture_supervisor_stderr_fifo_guard_open=0
  fi
  if [ -n "$capture_supervisor_stderr_pid" ]; then
    stop_capture_supervisor_stderr_reader || preserve_work
  fi
  stop_capture_supervisor_stderr_signal_broker || preserve_work
  stop_watcher || preserve_work
  if [ -n "${short_cvd_fleet_home:-}" ] \
    && ! remove_short_cvd_fleet_home; then
    preserve_work
  fi
  if [ -n "${short_cvd_root:-}" ] && ! remove_short_cvd_root; then
    preserve_work
  fi
  if [ "$watcher_stop_failed" -eq 1 ] || ! cvd_is_clean; then
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
  cleanup_generated_workspace
  exit "$original_status"
}

handle_signal() {
  local signal_name=$1
  local exit_status=$2
  if _capture_process_note_startup_signal "$signal_name" "$exit_status"; then
    return 0
  fi
  interrupted=1
  trap '' HUP INT TERM
  trap - EXIT
  if [ -n "$capture_child_pid" ]; then
    stop_capture_child "$signal_name" || true
  fi
  release_capture_supervisor_stderr_start_gate
  if [ "$capture_supervisor_stderr_fifo_guard_open" -eq 1 ]; then
    exec 9>&-
    capture_supervisor_stderr_fifo_guard_open=0
  fi
  if [ -n "$capture_supervisor_stderr_pid" ]; then
    stop_capture_supervisor_stderr_reader || preserve_work
  fi
  stop_capture_supervisor_stderr_signal_broker || preserve_work
  stop_watcher || preserve_work
  scrub_raw_logcat || true
  if [ -n "${short_cvd_fleet_home:-}" ] \
    && ! remove_short_cvd_fleet_home; then
    preserve_work
  fi
  if [ -n "${short_cvd_root:-}" ] && ! remove_short_cvd_root; then
    preserve_work
  fi
  if [ "$watcher_stop_failed" -eq 0 ] && cvd_is_clean; then
    stop_adb_server || true
  else
    preserve_work
  fi
  if [ -n "$adb_socket_dir" ] && [ "$adb_server_started" -eq 0 ]; then
    if ! rm -rf "$adb_socket_dir"; then
      printf 'Could not remove private ADB socket directory: %s\n' \
        "$adb_socket_dir" >&2
      preserve_work
    fi
  fi
  exit "$exit_status"
}

trap cleanup EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

capture_process_starting_role=workspace
capture_process_starting_released=1
_capture_process_complete_startup_signal workspace
work_root=$(trap '' HUP INT TERM; mktemp -d \
  "$work_parent/gpu-$gpu_mode_slug-console-$console_mode_slug.XXXXXX")
if ! printf 'APKRun Cuttlefish boot diagnosis v1\n%s\n%s\n' \
  "$workspace_token" "$work_root" \
  > "$work_root/.apkrun-cuttlefish-workspace"; then
  printf 'Could not mark the private diagnostic workspace; manual cleanup may be needed at %s.\n' \
    "$work_root" >&2
  rm -f -- "$work_root/.apkrun-cuttlefish-workspace"
  rmdir -- "$work_root" 2>/dev/null || true
  capture_process_starting_role=
  _capture_process_complete_startup_signal workspace
  capture_process_starting_released=0
  exit 1
fi
tmp_root="$work_root/tmp"
adb_home="$work_root/adb-home"
adb_log_root="$work_root/adb-live"
done_marker="$work_root/capture.done"
fleet_report="$work_root/cvd-fleet.json"
host_identity="$work_root/host-identity.json"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_path="$results_root/gpu-$gpu_mode_slug-console-$console_mode_slug-$timestamp-$$"
tool_destination="$work_root/Images/tools/reference"
manifest_destination="$work_root/Images/manifests/16373615"
canonical_capture_copy="$work_root/capture.sh.unpatched"
experiment_tools="$work_root/experiment-tools"
capture_status_root="$work_root/capture-status"
capture_run_status="$work_root/capture-run-status.json"
capture_run_interrupted="$capture_run_status.interrupted"
capture_output_log="$work_root/capture-process-output.log"
capture_output_status="$work_root/capture-process-output.json"
fleet_socket_metrics="$work_root/fleet-socket-paths.json"
capture_socket_metrics="$work_root/capture-socket-paths.json"
bootloader_console_summary="$work_root/bootloader-console-summary.json"
capture_supervisor_stderr_fifo="$work_root/capture-supervisor-stderr.fifo"
capture_supervisor_stderr_log="$work_root/capture-supervisor-stderr.log"
capture_supervisor_stderr_status="$work_root/capture-supervisor-stderr.json"
capture_supervisor_stderr_start_fifo="$work_root/capture-supervisor-stderr-start.fifo"
capture_supervisor_stderr_control_fifo="$work_root/capture-supervisor-stderr-control.fifo"
capture_supervisor_stderr_signal_broker_ready_file="$work_root/capture-supervisor-stderr-signal-broker.ready"
capture_supervisor_stderr_exit_file="$work_root/capture-supervisor-stderr-exited"
capture_supervisor_stderr_signal_broker_stopped_file="$work_root/capture-supervisor-stderr-signal-broker.stopped"

adb_socket_dir=$(trap '' HUP INT TERM; mktemp -d /tmp/apkrun-adb.XXXXXX)
adb_server_socket_path="$adb_socket_dir/server.sock"
adb_server_socket="localfilesystem:$adb_server_socket_path"

mkdir -p "$tmp_root" "$adb_home" "$adb_log_root"
chmod 700 "$work_root" "$tmp_root" "$adb_home" "$adb_log_root"
short_cvd_root_status=0
if create_short_cvd_home_root; then
  :
else
  short_cvd_root_status=$?
fi
capture_process_starting_role=
_capture_process_complete_startup_signal workspace
capture_process_starting_released=0
if [ "$short_cvd_root_status" -ne 0 ]; then
  exit 1
fi
if [ -e "$result_path" ] || [ -L "$result_path" ]; then
  printf 'Refusing to overwrite diagnostic result: %s\n' "$result_path" >&2
  discard_workspace_safely || true
  exit 2
fi

mkdir -p "$tool_destination" "$manifest_destination" \
  "$experiment_tools" "$capture_status_root"
cp "$repo_root/Images/tools/reference/capture.sh" \
  "$repo_root/Images/tools/reference/capture_cvd_start.py" \
  "$repo_root/Images/tools/reference/compare_boot.py" \
  "$repo_root/Images/tools/reference/normalize.yaml" \
  "$repo_root/Images/tools/reference/guest-capture.txt" \
  "$tool_destination/"
cp "$tool_destination/capture.sh" "$canonical_capture_copy"
cp "$script_dir/capture-gpu-none.sh" "$script_dir/capture-lifecycle.sh" \
  "$script_dir/capture_bounded.py" \
  "$script_dir/capture_processes.py" \
  "$script_dir/experiment_support.py" "$script_dir/run_capture.py" \
  "$script_dir/summarize_logcat.py" \
  "$script_dir/drive_cuttlefish_console.py" \
  "$script_dir/run_cvd_with_console.py" "$experiment_tools/"
cp "$experiment_tools/capture_bounded.py" \
  "$experiment_tools/capture_processes.py" "$tool_destination/"
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

run_committed_experiment_support \
  patch-capture --path "$capture_script" \
  --gpu-mode "$gpu_mode" --console-enabled "$console_enabled" \
  --pause-in-bootloader "$pause_in_bootloader"
bash -n "$capture_script"

export APKRUN_DIAGNOSTIC_ADB_SHIM_DIR="$adb_shim_dir"
export APKRUN_DIAGNOSTIC_ADB_SERVER_PID=
export APKRUN_DIAGNOSTIC_ADB_SERVER_SOCKET="$adb_server_socket"
export APKRUN_DIAGNOSTIC_ADB_SERVER_SOCKET_PATH="$adb_server_socket_path"
export APKRUN_EXPERIMENT_STATUS_ROOT="$capture_status_root"
export APKRUN_EXPERIMENT_TOOLS="$experiment_tools"
export APKRUN_EXPERIMENT_BOOTLOADER_SUMMARY="$bootloader_console_summary"
export APKRUN_EXPERIMENT_BOOTLOADER_SUMMARY_ROOT="$work_root"
export APKRUN_CVD_HOME_TMPDIR="$short_cvd_home_tmpdir"
export APKRUN_CVD_STATE_DIR="$cvd_state_dir"
export APKRUN_EXPERIMENT_SOCKET_METRICS="$capture_socket_metrics"
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

capture_process_starting_role=fleet_home
capture_process_starting_released=1
capture_fleet_home_setup_status=0
if create_short_cvd_fleet_home; then
  :
else
  capture_fleet_home_setup_status=$?
fi
capture_process_starting_role=
_capture_process_complete_startup_signal fleet_home
capture_process_starting_released=0
if [ "$capture_fleet_home_setup_status" -ne 0 ]; then
  printf 'Could not create the short private Cuttlefish fleet HOME.\n' >&2
  preserve_work
  exit 1
fi
if ! run_committed_capture_bounded \
  --timeout-seconds 30 --max-bytes 1048576 \
  --fail-on-truncate --merge-stderr \
  --output "$fleet_report" --status "$work_root/fleet-status.json" -- \
  env "HOME=$short_cvd_fleet_home" "TMPDIR=$short_cvd_fleet_home" \
  "PATH=$CVD_HOST_DIR/bin:$PATH" \
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
if ! run_committed_experiment_support audit-unix-sockets \
  --root "$short_cvd_home_tmpdir" --root "$cvd_state_dir" \
  --output "$fleet_socket_metrics"; then
  printf 'Cuttlefish fleet socket paths could not be verified; preserving private state.\n' >&2
  preserve_work
  exit 1
fi
if ! remove_short_cvd_fleet_home; then
  printf 'Cuttlefish fleet HOME cleanup failed; refusing to launch the guest.\n' >&2
  preserve_work
  exit 1
fi
if ! run_committed_experiment_support verify-host \
  --repo-root "$repo_root" \
  --baseline-record "$baseline_record" \
  --fleet-report "$fleet_report" \
  --experiment-root "$experiment_tools" \
  --patched-capture "$capture_script" \
  --gpu-mode "$gpu_mode" \
  --console-enabled "$console_enabled" \
  --pause-in-bootloader "$pause_in_bootloader" \
  --output "$host_identity"; then
  preserve_work
  exit 1
fi
if ! run_verified_experiment_support verify-tool-copy \
  --repo-root "$repo_root" \
  --baseline-record "$baseline_record" \
  --host-identity "$host_identity" \
  --tool-copy-root "$tool_destination" \
  --canonical-capture-copy "$canonical_capture_copy" \
  --manifest-copy-root "$manifest_destination" \
  --experiment-root "$experiment_tools" \
  --patched-capture "$capture_script"; then
  printf 'Private canonical tools do not match their recorded revision; refusing to launch the guest.\n' >&2
  preserve_work
  exit 1
fi

if ! start_pinned_capture_process adb_server /dev/null /dev/null \
  env "HOME=$adb_home" "$CVD_HOST_DIR/bin/adb" \
  -L "$adb_server_socket" nodaemon server; then
  printf 'Could not safely start the isolated ADB server.\n' >&2
  preserve_work
  exit 1
fi
adb_server_started=1
export APKRUN_DIAGNOSTIC_ADB_SERVER_PID="$adb_server_pid"
adb_ready=0
for _ in $(seq 1 20); do
  if _capture_process_exit_state adb_server; then
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
    cvd_home=$(find "$short_cvd_home_tmpdir" -mindepth 1 -maxdepth 1 -type d \
      -name 'h.*' -print -quit)
    if [ -z "$cvd_home" ]; then
      sleep 2
      continue
    fi
    if [ ! -d "$cvd_home" ] || [ -L "$cvd_home" ]; then
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

export adb_cleanup_failure_marker
export done_marker short_cvd_home_tmpdir serial adb_log_root
export tool_destination adb_shim_dir
watcher_script="$(declare -f \
  check_bounded_cleanup capture_adb_control_output watch_adb; printf 'watch_adb\n')"
start_pinned_capture_process watcher - - bash -c "$watcher_script"
mkfifo "$capture_supervisor_stderr_fifo" \
  "$capture_supervisor_stderr_start_fifo" \
  "$capture_supervisor_stderr_control_fifo"
chmod 600 "$capture_supervisor_stderr_fifo" \
  "$capture_supervisor_stderr_start_fifo" \
  "$capture_supervisor_stderr_control_fifo"
exec 7<>"$capture_supervisor_stderr_control_fifo"
capture_supervisor_stderr_control_open=1
exec 9<>"$capture_supervisor_stderr_fifo"
capture_supervisor_stderr_fifo_guard_open=1
exec 8<>"$capture_supervisor_stderr_start_fifo"
capture_supervisor_stderr_start_gate_open=1
(
  _capture_close_extra_descriptors || exit 125
  IFS= read -r _ < "$capture_supervisor_stderr_start_fifo"
  exec python3 "$experiment_tools/capture_bounded.py" \
    --stdin --drain-after-limit --max-bytes 65536 \
    --output "$capture_supervisor_stderr_log" \
    --status "$capture_supervisor_stderr_status" \
    < "$capture_supervisor_stderr_fifo" 9>&-
) &
capture_supervisor_stderr_pid=$!
if ! capture_supervisor_stderr_start_time=$(
  python3 "$experiment_tools/experiment_support.py" process-start-time \
    --pid "$capture_supervisor_stderr_pid"
); then
  printf 'Could not verify the capture supervisor stderr reader identity.\n' >&2
  release_capture_supervisor_stderr_start_gate
  exec 9>&-
  capture_supervisor_stderr_fifo_guard_open=0
  for _ in $(seq 1 5); do
    if ! kill -0 "$capture_supervisor_stderr_pid" 2>/dev/null; then
      wait "$capture_supervisor_stderr_pid" 2>/dev/null || true
      capture_supervisor_stderr_pid=
      break
    fi
    sleep 1
  done
  if [ -n "$capture_supervisor_stderr_pid" ]; then
    printf 'Capture supervisor stderr reader did not exit after gate release; its identity is unknown.\n' >&2
  fi
  stop_capture_supervisor_stderr_signal_broker || preserve_work
  preserve_work
  exit 1
fi
capture_supervisor_stderr_broker_target_pid=$capture_supervisor_stderr_pid
capture_supervisor_stderr_broker_target_start_time=$capture_supervisor_stderr_start_time
(
  _capture_close_extra_descriptors || exit 125
  exec python3 "$experiment_tools/experiment_support.py" signal-process-broker \
    --pid "$capture_supervisor_stderr_pid" \
    --start-time "$capture_supervisor_stderr_start_time" \
    --ready-file "$capture_supervisor_stderr_signal_broker_ready_file" \
    --exited-file "$capture_supervisor_stderr_exit_file" \
    --stopped-file "$capture_supervisor_stderr_signal_broker_stopped_file" \
    < "$capture_supervisor_stderr_control_fifo"
) >/dev/null 2>&1 &
capture_supervisor_stderr_signal_broker_pid=$!
for _ in $(seq 1 5); do
  if [ -f "$capture_supervisor_stderr_signal_broker_ready_file" ] \
    && [ ! -L "$capture_supervisor_stderr_signal_broker_ready_file" ]; then
    signal_broker_ready_content=$(< "$capture_supervisor_stderr_signal_broker_ready_file")
    if [ "$signal_broker_ready_content" = \
      "$capture_supervisor_stderr_pid $capture_supervisor_stderr_start_time" ]; then
      capture_supervisor_stderr_signal_broker_ready=1
      break
    fi
  fi
  if ! kill -0 "$capture_supervisor_stderr_signal_broker_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [ "$capture_supervisor_stderr_signal_broker_ready" -ne 1 ]; then
  printf 'Could not pin the capture supervisor stderr reader identity.\n' >&2
  release_capture_supervisor_stderr_start_gate
  exec 9>&-
  capture_supervisor_stderr_fifo_guard_open=0
  for _ in $(seq 1 5); do
    if ! kill -0 "$capture_supervisor_stderr_pid" 2>/dev/null; then
      wait "$capture_supervisor_stderr_pid" 2>/dev/null || true
      capture_supervisor_stderr_pid=
      capture_supervisor_stderr_start_time=
      break
    fi
    sleep 1
  done
  if [ -n "$capture_supervisor_stderr_pid" ]; then
    printf 'Capture supervisor stderr reader did not exit after gate release; preserving its workspace.\n' >&2
  fi
  stop_capture_supervisor_stderr_signal_broker || preserve_work
  preserve_work
  exit 1
fi
release_capture_supervisor_stderr_start_gate
rm -f "$capture_supervisor_stderr_start_fifo"
# The supervisor owns a separate guest session and must complete its cleanup.
if ! start_pinned_capture_process capture_child /dev/null \
  "$capture_supervisor_stderr_fifo" \
  env "HOME=$short_cvd_home_tmpdir" "TMPDIR=$short_cvd_home_tmpdir" \
  "APKRUN_CAPTURE_SCRIPT_DIR=$tool_destination" \
  "APKRUN_CVD_HOME_TMPDIR=$short_cvd_home_tmpdir" \
  "APKRUN_CVD_PACKAGE_VERSION=1.57.0" \
  "APKRUN_BOOT_TIMEOUT_SECONDS=600" \
  timeout --signal=TERM 900 \
  python3 -c '
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
import types
from pathlib import Path

deadline = time.monotonic() + 900
repo_root = Path(sys.argv[1])
tool_root = Path(sys.argv[2])
identity_path = Path(sys.argv[3])
arguments = sys.argv[4:]

def read_regular_file(path, maximum_bytes, description):
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise SystemExit(f"{description} is not a regular file")
        content = bytearray()
        while chunk := os.read(
            descriptor,
            min(65536, maximum_bytes + 1 - len(content)),
        ):
            content.extend(chunk)
            if len(content) > maximum_bytes:
                raise SystemExit(f"{description} exceeds the size limit")
        return bytes(content)
    finally:
        os.close(descriptor)

try:
    identity = json.loads(read_regular_file(identity_path, 1048576, "identity"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("capture supervisor identity is unreadable") from error
if not isinstance(identity, dict):
    raise SystemExit("capture supervisor identity is not a JSON object")
experiment_sources = identity.get("experimentSources")
observed_commit = identity.get("observedToolCommit")
if (
    not isinstance(experiment_sources, dict)
    or not isinstance(observed_commit, str)
    or not re.fullmatch(r"[0-9a-f]{40}", observed_commit)
):
    raise SystemExit("capture supervisor source map is missing")
try:
    current_commit = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=repo_root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
except (OSError, subprocess.CalledProcessError) as error:
    raise SystemExit("capture supervisor revision cannot be verified") from error
if current_commit != observed_commit:
    raise SystemExit("capture supervisor revision differs from host identity")
sources = {}
for name in ("capture_processes.py", "run_capture.py"):
    path = tool_root / name
    expected = experiment_sources.get(name)
    source = read_regular_file(path, 8388608, f"capture supervisor source: {name}")
    relative_path = f"Experiments/cuttlefish-boot-diagnosis/{name}"
    try:
        committed_source = subprocess.run(
            ["git", "show", f"{observed_commit}:{relative_path}"],
            cwd=repo_root,
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"committed capture supervisor source is missing: {name}") from error
    if (
        not isinstance(expected, str)
        or hashlib.sha256(committed_source).hexdigest() != expected
        or source != committed_source
    ):
        raise SystemExit(f"capture supervisor source digest differs: {name}")
    sources[name] = source

remaining_seconds = deadline - time.monotonic()
if remaining_seconds <= 0:
    raise SystemExit("capture deadline expired during source verification")
for index, argument in enumerate(arguments[:-1]):
    if argument == "--timeout-seconds":
        arguments[index + 1] = str(remaining_seconds)
        break
else:
    raise SystemExit("capture supervisor timeout argument is missing")

dependency_path = tool_root / "capture_processes.py"
dependency = types.ModuleType("capture_processes")
dependency.__file__ = str(dependency_path)
exec(compile(sources["capture_processes.py"], str(dependency_path), "exec"),
     dependency.__dict__)
sys.modules["capture_processes"] = dependency
runner_path = tool_root / "run_capture.py"
sys.argv = [str(runner_path), *arguments]
exec(
    compile(sources["run_capture.py"], str(runner_path), "exec"),
    {"__name__": "__main__", "__file__": str(runner_path)},
)
' "$repo_root" "$experiment_tools" "$host_identity" \
  --timeout-seconds 900 \
  --cleanup-grace-seconds 140 \
  --status "$capture_run_status" \
  --output-log "$capture_output_log" \
  --output-status "$capture_output_status" \
  --max-output-bytes 1048576 \
  --verified-script "$capture_script" \
  --host-identity "$host_identity" \
  --script-argument default; then
  printf 'Could not safely start the Cuttlefish capture supervisor.\n' >&2
  preserve_work
  exit 1
fi
exec 9>&-
capture_supervisor_stderr_fifo_guard_open=0
set +e
wait "$capture_child_pid"
capture_status=$?
if ! stop_pinned_capture_process capture_child TERM 145 3; then
  capture_status=1
  preserve_work
fi
if ! stop_capture_supervisor_stderr_reader; then
  capture_supervisor_stderr_status_code=1
  preserve_work
fi
if ! stop_capture_supervisor_stderr_signal_broker; then
  capture_supervisor_stderr_status_code=1
  preserve_work
fi
set -e
: > "$done_marker"
wait "$watcher_pid" || watcher_status=$?
if ! stop_pinned_capture_process watcher TERM 5 3; then
  watcher_status=1
  preserve_work
else
  watcher_pid=
fi
rm -f "$capture_supervisor_stderr_fifo"
rm -f "$capture_supervisor_stderr_control_fifo"
if [ "$watcher_status" -ne 0 ]; then
  : > "$adb_cleanup_failure_marker"
fi

if [ -e "$capture_run_interrupted" ] || [ -L "$capture_run_interrupted" ]; then
  printf 'Capture supervisor was interrupted while finalizing its status; refusing publication.\n' >&2
  preserve_work
  exit 1
fi

if [ "$interrupted" -eq 1 ]; then
  scrub_raw_logcat || true
  preserve_work
  exit 130
fi

if ! report_capture_output_status "$capture_output_status"; then
  preserve_work
  exit 1
fi

if [ ! -f "$capture_supervisor_stderr_status" ] \
  || [ -L "$capture_supervisor_stderr_status" ] \
  || [ ! -f "$capture_supervisor_stderr_log" ] \
  || [ -L "$capture_supervisor_stderr_log" ]; then
  printf 'Capture supervisor stderr was not retained; inspect the private workspace.\n' >&2
  preserve_work
  exit 1
fi
capture_supervisor_stderr_truncated=$(python3 - "$capture_supervisor_stderr_status" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if document.get("schemaVersion") != 1 or document.get("cleanupComplete") is not True:
    raise SystemExit(1)
print("true" if document.get("truncated") is True else "false")
PY
) || {
  printf 'Capture supervisor stderr cleanup is not verified; preserving private output.\n' >&2
  preserve_work
  exit 1
}
if [ "$capture_supervisor_stderr_status_code" -ne 0 ] \
  || [ "$capture_supervisor_stderr_truncated" = true ]; then
  printf 'Capture supervisor stderr exceeded its verified limit; inspect %s\n' \
    "$capture_supervisor_stderr_log" >&2
  preserve_work
  exit 1
fi

if [ ! -f "$capture_run_status" ]; then
  printf 'Capture supervisor did not record a completed run; see %s\n' \
    "$capture_supervisor_stderr_log" >&2
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
if [ "$capture_status" -ne 0 ]; then
  printf 'Capture supervisor exited with status %s; refusing publication.\n' \
    "$capture_status" >&2
  preserve_work
  exit 1
fi
capture_supervisor_signal=$(python3 - "$capture_run_status" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
signal_number = document.get("signal")
if signal_number is None:
    print("none")
elif type(signal_number) is int:
    print(signal_number)
else:
    raise SystemExit(1)
PY
) || {
  printf 'Capture supervisor signal status is invalid; refusing publication.\n' >&2
  preserve_work
  exit 1
}
if [ "$capture_supervisor_signal" != none ]; then
  printf 'Capture supervisor recorded signal %s; refusing publication.\n' \
    "$capture_supervisor_signal" >&2
  preserve_work
  exit 1
fi
capture_child_exit_code=$(python3 - "$capture_run_status" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
child_exit_code = document.get("childExitCode")
if type(child_exit_code) is not int:
    raise SystemExit(1)
print(child_exit_code)
PY
) || {
  printf 'Capture child exit status is invalid; refusing publication.\n' >&2
  preserve_work
  exit 1
}

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
  printf 'The capture script did not retain a regular normalized record; inspect the private bounded capture-process-output.log.\n' >&2
  preserve_work
  exit 1
fi

if [ -n "$short_cvd_root" ]; then
  if ! remove_short_cvd_root; then
    printf 'Cuttlefish temporary runtime cleanup is not verified; preserving private state.\n' >&2
    preserve_work
    exit 1
  fi
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
if ! record_or_preserve run_verified_experiment_support record \
  --capture-record "$capture_record" \
  --repo-root "$repo_root" \
  --baseline-record "$baseline_record" \
  --tool-copy-root "$tool_destination" \
  --canonical-capture-copy "$canonical_capture_copy" \
  --manifest-copy-root "$manifest_destination" \
  --experiment-root "$experiment_tools" \
  --patched-capture "$capture_script" \
  --host-identity "$host_identity" \
  --logcat-summary "$logcat_summary" \
  --adb-state "$capture_record/adb-state.txt" \
  --capture-exit-code "$capture_child_exit_code" \
  --adb-endpoint "$serial" \
  --capture-status-root "$capture_status_root" \
  --capture-run-status "$capture_run_status" \
  --socket-metrics "$capture_socket_metrics" \
  --fleet-socket-metrics "$fleet_socket_metrics" \
  --gpu-mode "$gpu_mode" \
  --console-enabled "$console_enabled" \
  --pause-in-bootloader "$pause_in_bootloader" \
  --bootloader-console-summary "$bootloader_console_summary" \
  --output "$capture_record/experiment.json"; then
  exit 1
fi

if ! publish_capture_record \
  "$capture_record" "$tool_destination/compare_boot.py" "$result_path"; then
  preserve_work || true
  exit 1
fi
if [ "$capture_child_exit_code" -ne 0 ]; then
  keep_work=1
  printf 'Nonzero capture exit; private bounded host output retained in workspace: %s\n' \
    "$work_root" >&2
fi
printf 'Normalized diagnostic record: %s\n' "$result_path"
printf 'Cuttlefish capture exit status: %s\n' "$capture_child_exit_code"
