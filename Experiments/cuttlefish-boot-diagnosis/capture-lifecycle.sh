#!/usr/bin/env bash

query_crosvm_processes() {
  local process_ids ps_status self_pid
  if process_ids=$(ps -ww -C crosvm -o pid= 2>/dev/null); then
    :
  else
    ps_status=$?
    if [ "$ps_status" -ne 1 ] || [ -n "$process_ids" ] \
      || ! self_pid=$(ps -ww -p "$$" -o pid= 2>/dev/null) \
      || [ -z "${self_pid//[[:space:]]/}" ]; then
      printf 'Could not verify whether a Cuttlefish crosvm process is running.\n' >&2
      return 1
    fi
  fi
  printf '%s' "$process_ids"
}

require_no_crosvm() {
  local process_ids
  if ! process_ids=$(query_crosvm_processes); then
    printf 'Could not verify whether a Cuttlefish crosvm process is running.\n' >&2
    return 1
  fi
  process_ids=${process_ids//[[:space:]]/}
  if [ -n "$process_ids" ]; then
    printf 'A crosvm process is already running; use a dedicated reference VM.\n' >&2
    return 1
  fi
}

cvd_is_clean() {
  local remaining_homes remaining_crosvm
  if ! remaining_homes=$(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d \
    -name 'apkrun-cvd-home.default.*' -print -quit 2>/dev/null); then
    return 1
  fi
  if ! remaining_crosvm=$(query_crosvm_processes); then
    return 1
  fi
  remaining_crosvm=${remaining_crosvm//[[:space:]]/}
  [ -z "$remaining_homes" ] && [ -z "$remaining_crosvm" ]
}

scrub_raw_logcat() {
  python3 "$script_dir/experiment_support.py" scrub-logcat \
    --work-root "$work_root" --adb-log-root "$adb_log_root" \
    --data-root "$data_root" --ownership-token "$workspace_token"
}

discard_workspace_safely() {
  if python3 "$script_dir/experiment_support.py" discard-workspace \
    --work-root "$work_root" --data-root "$data_root" \
    --ownership-token "$workspace_token"; then
    keep_work=0
    return 0
  fi
  if python3 "$script_dir/experiment_support.py" discard-workspace \
    --work-root "$work_root" --data-root "$data_root" \
    --ownership-token "$workspace_token"; then
    keep_work=0
    return 0
  fi
  printf 'Workspace deletion failed; private workspace retained for manual cleanup: %s\n' \
    "$work_root" >&2
  keep_work=1
  return 1
}

cleanup_generated_workspace() {
  if [ "$keep_work" -eq 0 ]; then
    discard_workspace_safely || true
  fi
}

preserve_work() {
  if ! scrub_raw_logcat; then
    printf 'Raw logcat could not be scrubbed; refusing to publish it.\n' >&2
    if cvd_is_clean; then
      discard_workspace_safely
      return $?
    fi
    printf 'Cuttlefish cleanup is incomplete; removing capture outputs and retaining its runtime state.\n' >&2
    if ! python3 "$script_dir/experiment_support.py" discard-logcat-trees \
      --work-root "$work_root" --adb-log-root "$adb_log_root" \
      --data-root "$data_root" --ownership-token "$workspace_token" \
      || ! scrub_raw_logcat; then
      if ! python3 "$script_dir/experiment_support.py" discard-logcat-trees \
        --work-root "$work_root" --adb-log-root "$adb_log_root" \
        --data-root "$data_root" --ownership-token "$workspace_token" \
        || ! scrub_raw_logcat; then
        printf 'Raw logcat could not be removed while Cuttlefish is active; preserving its runtime and requesting manual cleanup.\n' >&2
        keep_work=1
        return 1
      fi
    fi
  fi
  keep_work=1
  printf 'Private diagnostic workspace retained for cleanup: %s\n' "$work_root" >&2
}

preserve_failed_record() {
  printf 'The normalized capture failed experiment validation; raw logcat will be scrubbed and the private workspace retained.\n' >&2
  preserve_work
}

record_or_preserve() {
  if "$@"; then
    return 0
  fi
  preserve_failed_record
  return 1
}

normalize_and_scrub_for_publication() {
  local capture_record=$1 normalize_tool=$2
  if ! scrub_raw_logcat; then
    return 1
  fi
  if ! python3 "$normalize_tool" normalize "$capture_record"; then
    return 1
  fi
  if ! python3 - "$capture_record" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
for path in root.rglob("*"):
    if path.is_symlink():
        raise SystemExit(f"symlink remains in normalized capture: {path.name}")
    if not path.is_file():
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
  then
    return 1
  fi
  if ! scrub_raw_logcat; then
    return 1
  fi
}

publish_capture_record() {
  local capture_record=$1 normalize_tool=$2 result_path=$3
  if ! normalize_and_scrub_for_publication "$capture_record" "$normalize_tool"; then
    printf 'Capture normalization or final raw-log cleanup failed; refusing publication.\n' >&2
    return 1
  fi
  if ! cvd_is_clean || [ "${adb_server_started:-0}" -ne 0 ]; then
    printf 'Cuttlefish or ADB cleanup is not verified; refusing publication.\n' >&2
    return 1
  fi
  if [ -e "$result_path" ] || [ -L "$result_path" ]; then
    printf 'Refusing to overwrite diagnostic result: %s\n' "$result_path" >&2
    return 1
  fi
  if ! python3 "$script_dir/experiment_support.py" publish-record \
    --capture-record "$capture_record" --work-root "$work_root" \
    --data-root "$data_root" --result-path "$result_path" \
    --ownership-token "$workspace_token"; then
    printf 'Could not safely publish the normalized record.\n' >&2
    return 1
  fi
}
