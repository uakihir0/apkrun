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

_capture_process_variable() {
  local role=$1 suffix=$2
  case "$role" in
    capture_child|adb_server) printf '%s_%s' "$role" "$suffix" ;;
    *)
      printf 'Unsupported pinned capture process role.\n' >&2
      return 2
      ;;
  esac
}

_capture_process_note_startup_signal() {
  local signal_name=$1 exit_status=$2
  [ -n "${capture_process_starting_role:-}" ] || return 1
  if [ -z "${capture_process_startup_signal_exit_status:-}" ]; then
    capture_process_startup_signal_name=$signal_name
    capture_process_startup_signal_exit_status=$exit_status
    interrupted=1
    trap '' HUP INT TERM
  fi
  return 0
}

_capture_process_complete_startup_signal() {
  local role=$1
  local exit_status=${capture_process_startup_signal_exit_status:-}
  local signal_name=${capture_process_startup_signal_name:-TERM}
  if [ "${capture_process_starting_released:-0}" -eq 1 ] \
    && [ "$role" = adb_server ]; then
    adb_server_started=1
  fi
  [ -n "$exit_status" ] || return 0
  if [ "${capture_process_starting_released:-0}" -eq 1 ]; then
    capture_process_starting_role=
    if declare -F handle_signal >/dev/null; then
      handle_signal "$signal_name" "$exit_status"
    elif [ "$role" = capture_child ]; then
      stop_pinned_capture_process "$role" "$signal_name" 145 3 || preserve_work
    else
      stop_pinned_capture_process "$role" TERM 10 5 || preserve_work
    fi
    exit "$exit_status"
  fi
  _capture_process_abort_start "$role" || preserve_work
  capture_process_starting_role=
  exit "$exit_status"
}

_capture_close_extra_descriptors() {
  local fd_path descriptor
  local open_descriptor
  [ -d /proc/self/fd ] || return 1
  for fd_path in /proc/self/fd/[0-9]*; do
    descriptor=${fd_path##*/}
    [[ "$descriptor" =~ ^[0-9]+$ ]] || continue
    if [ "$descriptor" -ge 3 ]; then
      open_descriptor=$descriptor
      exec {open_descriptor}>&-
    fi
  done
}

_capture_process_exit_state() {
  local role=$1 pid_var start_time_var exit_file_var
  local target_pid target_start_time exit_file exit_record
  pid_var=$(_capture_process_variable "$role" pid) || return
  start_time_var=$(_capture_process_variable "$role" start_time) || return
  exit_file_var=$(_capture_process_variable "$role" signal_broker_exit_file) || return
  target_pid=${!pid_var:-}
  target_start_time=${!start_time_var:-}
  exit_file=${!exit_file_var:-}
  [ -n "$target_pid" ] && [ -n "$target_start_time" ] || return 2
  if [ ! -e "$exit_file" ] && [ ! -L "$exit_file" ]; then
    return 1
  fi
  if [ -L "$exit_file" ] || [ ! -f "$exit_file" ] \
    || ! exit_record=$(< "$exit_file"); then
    return 2
  fi
  if [ "$exit_record" = "$target_pid $target_start_time" ]; then
    return 0
  fi
  return 2
}

_capture_process_wait_exit() {
  local role=$1 maximum_seconds=$2
  local exit_state
  for _ in $(seq 1 "$maximum_seconds"); do
    if _capture_process_exit_state "$role"; then
      return 0
    else
      exit_state=$?
    fi
    if [ "$exit_state" -eq 2 ]; then
      return 2
    fi
    sleep 1
  done
  _capture_process_exit_state "$role"
}

_capture_process_finish_broker() {
  local role=$1
  local pid_var start_time_var broker_pid_var control_fd_var
  local ready_file_var stopped_file_var exit_file_var start_fifo_var control_fifo_var
  local start_fd_var
  local target_pid target_start_time broker_pid control_fd start_fd
  local stopped_file stopped_record
  local broker_status fd_to_close
  pid_var=$(_capture_process_variable "$role" pid) || return
  start_time_var=$(_capture_process_variable "$role" start_time) || return
  broker_pid_var=$(_capture_process_variable "$role" signal_broker_pid) || return
  control_fd_var=$(_capture_process_variable "$role" control_fd) || return
  start_fd_var=$(_capture_process_variable "$role" start_fd) || return
  ready_file_var=$(_capture_process_variable "$role" signal_broker_ready_file) || return
  stopped_file_var=$(_capture_process_variable "$role" signal_broker_stopped_file) || return
  exit_file_var=$(_capture_process_variable "$role" signal_broker_exit_file) || return
  start_fifo_var=$(_capture_process_variable "$role" start_fifo) || return
  control_fifo_var=$(_capture_process_variable "$role" control_fifo) || return
  target_pid=${!pid_var:-}
  target_start_time=${!start_time_var:-}
  broker_pid=${!broker_pid_var:-}
  control_fd=${!control_fd_var:-}
  start_fd=${!start_fd_var:-}
  stopped_file=${!stopped_file_var:-}
  [ -n "$target_pid" ] && [ -n "$target_start_time" ] || return 2
  if [ -n "$broker_pid" ]; then
    if ! _capture_process_exit_state "$role"; then
      printf 'Pinned process did not publish its verified exit record.\n' >&2
      return 1
    fi
    for _ in $(seq 1 5); do
      if [ -f "$stopped_file" ] && [ ! -L "$stopped_file" ]; then
        stopped_record=$(< "$stopped_file")
        break
      fi
      sleep 1
    done
    if [ "${stopped_record:-}" != "$target_pid $target_start_time" ]; then
      printf 'Pinned process signal broker did not stop cleanly; preserving its workspace.\n' >&2
      return 1
    fi
    if _capture_process_reap_broker "$broker_pid"; then
      broker_status=0
    else
      broker_status=1
    fi
    printf -v "$broker_pid_var" '%s' ''
    if [ "$broker_status" -ne 0 ]; then
      printf 'Pinned process signal broker exited with status %s.\n' \
        "$broker_status" >&2
      return 1
    fi
  fi
  if [[ "$control_fd" =~ ^[0-9]+$ ]] && [ "$control_fd" -gt 9 ]; then
    fd_to_close=$control_fd
    exec {fd_to_close}>&-
  fi
  if [[ "$start_fd" =~ ^[0-9]+$ ]] && [ "$start_fd" -gt 2 ]; then
    fd_to_close=$start_fd
    exec {fd_to_close}>&-
  fi
  printf -v "$control_fd_var" '%s' ''
  printf -v "$start_fd_var" '%s' ''
  rm -f "${!start_fifo_var:-}" "${!control_fifo_var:-}" \
    "${!ready_file_var:-}" "${!exit_file_var:-}" "$stopped_file"
  printf -v "$pid_var" '%s' ''
  printf -v "$start_time_var" '%s' ''
  return 0
}

_capture_process_state() {
  local process_id=$1 stat_record stat_fields
  if ! IFS= read -r stat_record < "/proc/$process_id/stat"; then
    if [ -e "/proc/$process_id/stat" ]; then
      printf 'unknown'
    else
      printf 'missing'
    fi
    return 0
  fi
  stat_fields=${stat_record##*) }
  printf '%s' "${stat_fields%% *}"
}

_capture_process_wait_for_exit() {
  local process_id=$1 maximum_seconds=$2 process_state
  for _ in $(seq 1 "$((maximum_seconds * 10))"); do
    process_state=$(_capture_process_state "$process_id")
    case "$process_state" in
      Z|X|missing) return 0 ;;
    esac
    sleep 0.1
  done
  process_state=$(_capture_process_state "$process_id")
  case "$process_state" in
    Z|X|missing) return 0 ;;
  esac
  return 1
}

_capture_process_reap_broker() {
  local broker_pid=$1 broker_status
  if ! _capture_process_wait_for_exit "$broker_pid" 1; then
    printf 'Capture process broker did not exit after publishing its stopped record.\n' >&2
    # This unreaped PID is our direct child, so it cannot be reused.
    kill -TERM "$broker_pid" 2>/dev/null || true
    if ! _capture_process_wait_for_exit "$broker_pid" 1; then
      kill -KILL "$broker_pid" 2>/dev/null || true
    fi
    if ! _capture_process_wait_for_exit "$broker_pid" 2; then
      printf 'Capture process broker could not be stopped; preserving its workspace.\n' >&2
      return 1
    fi
    wait "$broker_pid" 2>/dev/null || true
    return 1
  fi
  if wait "$broker_pid"; then
    return 0
  else
    broker_status=$?
  fi
  printf 'Capture process broker exited with status %s.\n' "$broker_status" >&2
  return 1
}

_capture_process_stop_direct_child() {
  local child_pid=$1
  if ! [[ "$child_pid" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Could not verify the direct child process identity.\n' >&2
    return 1
  fi
  if ! _capture_process_wait_for_exit "$child_pid" 1; then
    # This unreaped PID is our direct child, so it cannot be reused.
    kill -TERM "$child_pid" 2>/dev/null || true
    if ! _capture_process_wait_for_exit "$child_pid" 1; then
      kill -KILL "$child_pid" 2>/dev/null || true
    fi
  fi
  if ! _capture_process_wait_for_exit "$child_pid" 2; then
    printf 'Direct child process could not be stopped; preserving its workspace.\n' >&2
    return 1
  fi
  wait "$child_pid" 2>/dev/null || true
}

_capture_process_abort_start() {
  local role=$1
  local pid_var broker_pid_var control_fd_var start_fifo_var control_fifo_var
  local ready_file_var exit_file_var stopped_file_var start_time_var start_fd_var
  local target_pid broker_pid control_fd start_fd fd_to_close broker_status
  local ready_file exit_file stopped_file target_start_time record_state
  local broker_ready=0 broker_present=0 stopped_record= broker_state
  pid_var=$(_capture_process_variable "$role" pid) || return
  broker_pid_var=$(_capture_process_variable "$role" signal_broker_pid) || return
  control_fd_var=$(_capture_process_variable "$role" control_fd) || return
  start_fd_var=$(_capture_process_variable "$role" start_fd) || return
  start_fifo_var=$(_capture_process_variable "$role" start_fifo) || return
  control_fifo_var=$(_capture_process_variable "$role" control_fifo) || return
  ready_file_var=$(_capture_process_variable "$role" signal_broker_ready_file) || return
  exit_file_var=$(_capture_process_variable "$role" signal_broker_exit_file) || return
  stopped_file_var=$(_capture_process_variable "$role" signal_broker_stopped_file) || return
  start_time_var=$(_capture_process_variable "$role" start_time) || return
  target_pid=${!pid_var:-}
  broker_pid=${!broker_pid_var:-}
  control_fd=${!control_fd_var:-}
  start_fd=${!start_fd_var:-}
  target_start_time=${!start_time_var:-}
  ready_file=${!ready_file_var:-}
  exit_file=${!exit_file_var:-}
  stopped_file=${!stopped_file_var:-}
  if [[ "$start_fd" =~ ^[0-9]+$ ]] && [ "$start_fd" -gt 2 ]; then
    printf 'abort\n' >&"$start_fd" 2>/dev/null || true
  fi
  if [[ "$start_fd" =~ ^[0-9]+$ ]] && [ "$start_fd" -gt 2 ]; then
    fd_to_close=$start_fd
    exec {fd_to_close}>&-
  fi
  broker_status=0
  if [ -n "$broker_pid" ]; then
    broker_present=1
    for _ in $(seq 1 50); do
      if [ -f "$ready_file" ] && [ ! -L "$ready_file" ]; then
        ready_record=$(< "$ready_file")
        if [ "$ready_record" = "$target_pid $target_start_time" ]; then
          broker_ready=1
          break
        fi
      fi
      if [ -f "$exit_file" ] && [ ! -L "$exit_file" ]; then
        if _capture_process_exit_state "$role"; then
          broker_ready=1
          break
        fi
      fi
      broker_state=$(_capture_process_state "$broker_pid")
      if [ "$broker_state" = Z ] || [ "$broker_state" = X ] \
        || [ "$broker_state" = missing ]; then
        if wait "$broker_pid"; then
          broker_status=0
        else
          broker_status=$?
        fi
        printf -v "$broker_pid_var" '%s' ''
        broker_pid=
        break
      fi
      sleep 0.1
    done
    if [ -n "$broker_pid" ] && [ "$broker_ready" -eq 0 ]; then
      printf 'Capture process broker did not become ready during startup abort.\n' >&2
      # This exact PID is our unreaped direct child, so it cannot be reused.
      kill -TERM "$broker_pid" 2>/dev/null || true
      if ! _capture_process_wait_for_exit "$broker_pid" 1; then
        kill -KILL "$broker_pid" 2>/dev/null || true
      fi
      if ! _capture_process_wait_for_exit "$broker_pid" 2; then
        printf 'Capture process broker could not be stopped; preserving its workspace.\n' >&2
        return 1
      fi
      if _capture_process_reap_broker "$broker_pid"; then
        broker_status=0
      else
        broker_status=1
      fi
      printf -v "$broker_pid_var" '%s' ''
      broker_pid=
    fi
    if [[ "$control_fd" =~ ^[0-9]+$ ]] && [ "$control_fd" -gt 2 ]; then
      fd_to_close=$control_fd
      exec {fd_to_close}>&-
      control_fd=
      printf -v "$control_fd_var" '%s' ''
    fi
    if [ -n "$broker_pid" ]; then
      for _ in $(seq 1 70); do
        if [ -f "$stopped_file" ] && [ ! -L "$stopped_file" ]; then
          stopped_record=$(< "$stopped_file")
          break
        fi
        broker_state=$(_capture_process_state "$broker_pid")
        if [ "$broker_state" = Z ] || [ "$broker_state" = X ] \
          || [ "$broker_state" = missing ]; then
          break
        fi
        sleep 0.1
      done
      if [ "${stopped_record:-}" != "$target_pid $target_start_time" ]; then
        broker_status=1
        broker_state=$(_capture_process_state "$broker_pid")
        if [ "$broker_state" != Z ] && [ "$broker_state" != X ] \
          && [ "$broker_state" != missing ]; then
          printf 'Capture process broker did not stop after startup abort; preserving its workspace.\n' >&2
          return 1
        fi
      fi
      if _capture_process_reap_broker "$broker_pid"; then
        broker_status=0
      else
        broker_status=1
      fi
      printf -v "$broker_pid_var" '%s' ''
      broker_pid=
    fi
  fi
  if [ "$broker_present" -eq 1 ] && [ "$broker_ready" -eq 0 ] \
    && [ "$broker_status" -eq 0 ]; then
    broker_status=1
  fi
  if [ -n "$target_pid" ]; then
    record_state=$(_capture_process_state "$target_pid")
    if [ "$record_state" = T ] || [ "$record_state" = t ]; then
      # The unreaped PID is this launch's direct child and remains reserved.
      kill -CONT "$target_pid" 2>/dev/null || true
    fi
    if ! _capture_process_wait_for_exit "$target_pid" 5; then
      printf 'Pinned capture process did not exit after startup abort; preserving its workspace.\n' >&2
      return 1
    fi
    wait "$target_pid" 2>/dev/null || true
  fi
  control_fd=${!control_fd_var:-}
  if [[ "$control_fd" =~ ^[0-9]+$ ]] && [ "$control_fd" -gt 2 ]; then
    fd_to_close=$control_fd
    exec {fd_to_close}>&-
  fi
  rm -f "${!start_fifo_var:-}" "${!control_fifo_var:-}" \
    "${!ready_file_var:-}" "${!exit_file_var:-}" "${!stopped_file_var:-}"
  printf -v "$pid_var" '%s' ''
  printf -v "$broker_pid_var" '%s' ''
  printf -v "$control_fd_var" '%s' ''
  printf -v "$start_fd_var" '%s' ''
  printf -v "$start_time_var" '%s' ''
  if [ "$broker_status" -ne 0 ]; then
    printf 'Capture process signal broker exited during startup (status %s).\n' \
      "$broker_status" >&2
    return 1
  fi
}

start_pinned_capture_process() {
  local role=$1 stdout_path=$2 stderr_path=$3
  local pid_var start_time_var broker_pid_var control_fd_var
  local start_fd_var start_fifo_var control_fifo_var ready_file_var exit_file_var
  local stopped_file_var
  local target_pid broker_pid control_fd start_fd start_fifo control_fifo
  local ready_file exit_file stopped_file start_time ready_record fd_to_close exit_state
  shift 3
  pid_var=$(_capture_process_variable "$role" pid) || return
  start_time_var=$(_capture_process_variable "$role" start_time) || return
  broker_pid_var=$(_capture_process_variable "$role" signal_broker_pid) || return
  control_fd_var=$(_capture_process_variable "$role" control_fd) || return
  start_fd_var=$(_capture_process_variable "$role" start_fd) || return
  start_fifo_var=$(_capture_process_variable "$role" start_fifo) || return
  control_fifo_var=$(_capture_process_variable "$role" control_fifo) || return
  ready_file_var=$(_capture_process_variable "$role" signal_broker_ready_file) || return
  exit_file_var=$(_capture_process_variable "$role" signal_broker_exit_file) || return
  stopped_file_var=$(_capture_process_variable "$role" signal_broker_stopped_file) || return
  if [ "$#" -eq 0 ] || [ -n "${!pid_var:-}" ]; then
    printf 'Pinned capture process launch has invalid state or no command.\n' >&2
    return 2
  fi
  start_fifo="$work_root/$role.start.fifo"
  control_fifo="$work_root/$role.control.fifo"
  ready_file="$work_root/$role.signal-broker.ready"
  exit_file="$work_root/$role.exited"
  stopped_file="$work_root/$role.signal-broker.stopped"
  if [ -e "$start_fifo" ] || [ -L "$start_fifo" ] \
    || [ -e "$control_fifo" ] || [ -L "$control_fifo" ] \
    || [ -e "$ready_file" ] || [ -L "$ready_file" ] \
    || [ -e "$exit_file" ] || [ -L "$exit_file" ] \
    || [ -e "$stopped_file" ] || [ -L "$stopped_file" ]; then
    printf 'Pinned capture process state files already exist.\n' >&2
    return 1
  fi
  if ! mkfifo "$start_fifo" "$control_fifo" || ! chmod 600 "$start_fifo" "$control_fifo"; then
    printf 'Could not prepare private pinned capture process FIFOs.\n' >&2
    return 1
  fi
  if ! exec {control_fd}<>"$control_fifo"; then
    rm -f "$start_fifo" "$control_fifo"
    return 1
  fi
  if ! exec {start_fd}<>"$start_fifo"; then
    fd_to_close=$control_fd
    exec {fd_to_close}>&-
    rm -f "$start_fifo" "$control_fifo"
    return 1
  fi
  printf -v "$control_fd_var" '%s' "$control_fd"
  printf -v "$start_fd_var" '%s' "$start_fd"
  printf -v "$start_fifo_var" '%s' "$start_fifo"
  printf -v "$control_fifo_var" '%s' "$control_fifo"
  printf -v "$ready_file_var" '%s' "$ready_file"
  printf -v "$exit_file_var" '%s' "$exit_file"
  printf -v "$stopped_file_var" '%s' "$stopped_file"
  capture_process_starting_role=$role
  capture_process_starting_released=0
  _capture_process_complete_startup_signal "$role"
  (
    _capture_close_extra_descriptors || exit 125
    local start_token
    IFS= read -r start_token < "$start_fifo" || exit 125
    [ "$start_token" = start ] || exit 125
    if [ "$stdout_path" != - ]; then
      exec > "$stdout_path"
    fi
    if [ "$stderr_path" != - ]; then
      exec 2> "$stderr_path"
    fi
    exec "$@"
  ) &
  target_pid=$!
  printf -v "$pid_var" '%s' "$target_pid"
  _capture_process_complete_startup_signal "$role"
  if ! start_time=$(python3 "$experiment_tools/experiment_support.py" \
    process-start-time --pid "$target_pid"); then
    printf 'Could not verify the pinned capture process identity.\n' >&2
    _capture_process_abort_start "$role" || return 1
    capture_process_starting_role=
    return 1
  fi
  _capture_process_complete_startup_signal "$role"
  printf -v "$start_time_var" '%s' "$start_time"
  _capture_process_complete_startup_signal "$role"
  (
    _capture_close_extra_descriptors || exit 125
    exec python3 "$experiment_tools/experiment_support.py" signal-process-broker \
      --pid "$target_pid" \
      --start-time "$start_time" \
      --ready-file "$ready_file" \
      --exited-file "$exit_file" \
      --stopped-file "$stopped_file" \
      < "$control_fifo" >/dev/null 2>&1
  ) &
  broker_pid=$!
  printf -v "$broker_pid_var" '%s' "$broker_pid"
  _capture_process_complete_startup_signal "$role"
  for _ in $(seq 1 50); do
    _capture_process_complete_startup_signal "$role"
    if _capture_process_exit_state "$role"; then
      printf 'Pinned capture process exited before its start gate opened.\n' >&2
      _capture_process_abort_start "$role" || return 1
      capture_process_starting_role=
      return 1
    else
      exit_state=$?
      if [ "$exit_state" -eq 2 ]; then
        printf 'Pinned capture process exit record is invalid during startup.\n' >&2
        _capture_process_abort_start "$role" || return 1
        capture_process_starting_role=
        return 1
      fi
    fi
    if [ -f "$ready_file" ] && [ ! -L "$ready_file" ]; then
      ready_record=$(< "$ready_file")
      if [ "$ready_record" = "$target_pid $start_time" ]; then
        break
      fi
    fi
    sleep 0.1
  done
  _capture_process_complete_startup_signal "$role"
  if [ "${ready_record:-}" != "$target_pid $start_time" ]; then
    printf 'Could not pin the capture process identity; refusing to start it.\n' >&2
    _capture_process_abort_start "$role" || return 1
    capture_process_starting_role=
    return 1
  fi
  if ! capture_process_starting_released=$(
    printf 'start\n' >&"$start_fd" || exit 1
    printf '1'
  ); then
    _capture_process_abort_start "$role" || return 1
    capture_process_starting_role=
    return 1
  fi
  _capture_process_complete_startup_signal "$role"
  fd_to_close=$start_fd
  exec {fd_to_close}>&-
  printf -v "$start_fd_var" '%s' ''
  rm -f "$start_fifo"
  capture_process_starting_role=
  _capture_process_complete_startup_signal "$role"
  capture_process_starting_released=0
  return 0
}

stop_pinned_capture_process() {
  local role=$1 initial_signal=$2 term_seconds=$3 kill_seconds=$4
  local pid_var start_time_var broker_pid_var control_fd_var
  local target_pid target_start_time control_fd exit_state wait_status
  shift 4
  pid_var=$(_capture_process_variable "$role" pid) || return
  start_time_var=$(_capture_process_variable "$role" start_time) || return
  broker_pid_var=$(_capture_process_variable "$role" signal_broker_pid) || return
  control_fd_var=$(_capture_process_variable "$role" control_fd) || return
  target_pid=${!pid_var:-}
  target_start_time=${!start_time_var:-}
  control_fd=${!control_fd_var:-}
  [ -n "$target_pid" ] || return 0
  if _capture_process_exit_state "$role"; then
    :
  else
    exit_state=$?
    if [ "$exit_state" -eq 2 ]; then
      printf 'Pinned process exit record is invalid; refusing to signal it.\n' >&2
      return 1
    fi
    if [[ ! "$control_fd" =~ ^[0-9]+$ ]] || [ "$control_fd" -le 9 ]; then
      printf 'Pinned process has no open pidfd broker control channel.\n' >&2
      return 1
    fi
    case "$initial_signal" in
      TERM|INT|HUP) ;;
      *)
        printf 'Unsupported signal for pinned capture process.\n' >&2
        return 2
        ;;
    esac
    printf '%s\n' "$initial_signal" >&"$control_fd" || return 1
    _capture_process_wait_exit "$role" "$term_seconds" || wait_status=$?
    wait_status=${wait_status:-0}
    if [ "$wait_status" -ne 0 ]; then
      if [ "$wait_status" -eq 2 ]; then
        printf 'Pinned process exit record is invalid after TERM.\n' >&2
        return 1
      fi
      printf 'KILL\n' >&"$control_fd" || return 1
      wait_status=0
      _capture_process_wait_exit "$role" "$kill_seconds" || wait_status=$?
      if [ "$wait_status" -ne 0 ]; then
        printf 'Pinned process did not stop after TERM and KILL (pid %s).\n' \
          "$target_pid" >&2
        return 1
      fi
    fi
  fi
  wait "$target_pid" 2>/dev/null || true
  if ! _capture_process_exit_state "$role"; then
    printf 'Pinned process exit was not verified before reaping (pid %s).\n' \
      "$target_pid" >&2
    return 1
  fi
  _capture_process_finish_broker "$role"
}

private_cvd_processes_are_clean() {
  local home_root=$1 tmpdir_root=$2
  if [ -z "${CVD_HOST_DIR:-}" ] || [ ! -d "$CVD_HOST_DIR" ]; then
    printf 'Cuttlefish HOME cleanup cannot verify the pinned host package.\n' >&2
    return 1
  fi
  python3 "$script_dir/experiment_support.py" check-cvd-processes \
    --host-dir "$CVD_HOST_DIR" \
    --home-root "$home_root" \
    --tmpdir-root "$tmpdir_root" >/dev/null
}

cvd_is_clean() {
  local remaining_homes remaining_short_homes remaining_crosvm
  if [ -L "$tmp_root" ]; then
    return 1
  fi
  if [ -e "$tmp_root" ]; then
    if [ ! -d "$tmp_root" ] \
      || ! remaining_homes=$(find "$tmp_root" -mindepth 1 -maxdepth 1 \
        -print -quit 2>/dev/null); then
      return 1
    fi
  else
    remaining_homes=
  fi
  if [ -z "${short_cvd_home_tmpdir:-}" ]; then
    remaining_short_homes=
  elif [ -L "$short_cvd_home_tmpdir" ]; then
    return 1
  elif [ -e "$short_cvd_home_tmpdir" ]; then
    if [ ! -d "$short_cvd_home_tmpdir" ] \
      || ! remaining_short_homes=$(find "$short_cvd_home_tmpdir" \
        -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null); then
      return 1
    fi
  else
    remaining_short_homes=
  fi
  if ! remaining_crosvm=$(query_crosvm_processes); then
    return 1
  fi
  remaining_crosvm=${remaining_crosvm//[[:space:]]/}
  if [ -n "${short_cvd_home_tmpdir:-}" ] \
    && [ -d "$short_cvd_home_tmpdir" ] \
    && [ -n "${CVD_HOST_DIR:-}" ] \
    && ! private_cvd_processes_are_clean \
      "$short_cvd_home_tmpdir" "$short_cvd_home_tmpdir"; then
    return 1
  fi
  if [ -n "${short_cvd_fleet_home:-}" ] \
    && [ -d "$short_cvd_fleet_home" ] \
    && [ -n "${CVD_HOST_DIR:-}" ] \
    && ! private_cvd_processes_are_clean \
      "$short_cvd_fleet_home" "$short_cvd_fleet_home"; then
    return 1
  fi
  [ -z "$remaining_homes" ] && [ -z "$remaining_short_homes" ] \
    && [ -z "$remaining_crosvm" ]
}

rollback_short_cvd_home_root() {
  local root=${short_cvd_root:-} marker_path entry
  [ -n "$root" ] || return 0
  if [ -z "${short_cvd_physical_tmp_root:-}" ]; then
    printf 'Cannot roll back the short Cuttlefish HOME without its physical /tmp root.\n' >&2
    return 1
  fi
  case "$root" in
    "$short_cvd_physical_tmp_root"/x.??????) ;;
    *)
      printf 'Refusing to roll back a short Cuttlefish HOME outside physical /tmp.\n' >&2
      return 1
      ;;
  esac
  if [ -L "$root" ] || [ ! -d "$root" ] || [ ! -O "$root" ] \
    || [ "${short_cvd_home_tmpdir:-}" != "$root/t" ]; then
    printf 'Refusing to roll back an unsafe short Cuttlefish HOME root.\n' >&2
    return 1
  fi
  marker_path="$root/.apkrun-cvd-short-home"
  for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
      continue
    fi
    case "$entry" in
      "$root/t"|"$marker_path") ;;
      *)
        printf 'Short Cuttlefish HOME contains an unexpected entry; preserving it.\n' >&2
        return 1
        ;;
    esac
  done
  if [ -e "$root/t" ] || [ -L "$root/t" ]; then
    if [ -L "$root/t" ] || [ ! -d "$root/t" ] || [ ! -O "$root/t" ] \
      || ! (trap '' HUP INT TERM; rmdir -- "$root/t"); then
      printf 'Could not roll back the short Cuttlefish HOME temporary directory.\n' >&2
      return 1
    fi
  fi
  if [ -e "$marker_path" ] || [ -L "$marker_path" ]; then
    if [ -L "$marker_path" ] || [ ! -f "$marker_path" ] \
      || [ ! -O "$marker_path" ] \
      || ! (trap '' HUP INT TERM; rm -f -- "$marker_path"); then
      printf 'Could not roll back the short Cuttlefish HOME ownership marker.\n' >&2
      return 1
    fi
  fi
  if ! (trap '' HUP INT TERM; rmdir -- "$root"); then
    printf 'Could not remove the incomplete short Cuttlefish HOME root.\n' >&2
    return 1
  fi
  short_cvd_root=
  short_cvd_home_tmpdir=
}

create_short_cvd_home_root() {
  local physical_tmp_root root_template physical_short_root short_cvd_marker
  if ! physical_tmp_root=$(python3 -c \
    'import os; print(os.path.realpath("/tmp"))'); then
    printf 'Could not resolve the physical /tmp directory for Cuttlefish.\n' >&2
    return 1
  fi
  if [ -z "$physical_tmp_root" ] || [ ! -d "$physical_tmp_root" ] \
    || [ -L "$physical_tmp_root" ]; then
    printf 'The physical /tmp directory is unavailable or unsafe.\n' >&2
    return 1
  fi
  short_cvd_physical_tmp_root=$physical_tmp_root
  root_template="$physical_tmp_root/x.XXXXXX"
  short_cvd_root=$(trap '' HUP INT TERM; mktemp -d "$root_template") || return 1
  short_cvd_home_tmpdir="$short_cvd_root/t"
  if ! physical_short_root=$(trap '' HUP INT TERM; python3 - "$short_cvd_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  ); then
    printf 'Could not verify the physical short Cuttlefish HOME root.\n' >&2
    rollback_short_cvd_home_root || true
    return 1
  fi
  if [ "$physical_short_root" != "$short_cvd_root" ]; then
    printf 'The short Cuttlefish HOME root is not physically canonical.\n' >&2
    rollback_short_cvd_home_root || true
    return 1
  fi
  if ! (trap '' HUP INT TERM; chmod 700 "$short_cvd_root"); then
    printf 'Could not set private permissions on the short Cuttlefish HOME root.\n' >&2
    rollback_short_cvd_home_root || true
    return 1
  fi
  short_cvd_marker="$short_cvd_root/.apkrun-cvd-short-home"
  if ! printf 'APKRun Cuttlefish short HOME v1\n%s\n%s\n%s\n' \
    "$workspace_token" "$work_root" "$short_cvd_root" > "$short_cvd_marker"; then
    printf 'Could not mark the private short Cuttlefish HOME root.\n' >&2
    rollback_short_cvd_home_root || true
    return 1
  fi
  if ! (trap '' HUP INT TERM; chmod 600 "$short_cvd_marker"); then
    printf 'Could not set private permissions on the short Cuttlefish HOME marker.\n' >&2
    rollback_short_cvd_home_root || true
    return 1
  fi
  if ! (trap '' HUP INT TERM; mkdir -m 700 "$short_cvd_home_tmpdir"); then
    printf 'Could not create the private short Cuttlefish HOME directory.\n' >&2
    rollback_short_cvd_home_root || true
    return 1
  fi
  if ! (trap '' HUP INT TERM; chmod 700 "$short_cvd_home_tmpdir"); then
    printf 'Could not set private permissions on the short Cuttlefish HOME directory.\n' >&2
    rollback_short_cvd_home_root || true
    return 1
  fi
}

rollback_short_cvd_fleet_home() {
  local home=${short_cvd_fleet_home:-} marker_path entry
  [ -n "$home" ] || return 0
  case "$home" in
    "${short_cvd_home_tmpdir:-}"/p.??????) ;;
    *)
      printf 'Refusing to roll back a Cuttlefish fleet HOME outside its private root.\n' >&2
      return 1
      ;;
  esac
  if [ -L "$home" ] || [ ! -d "$home" ] || [ ! -O "$home" ]; then
    printf 'Refusing to roll back an unsafe Cuttlefish fleet HOME.\n' >&2
    return 1
  fi
  marker_path="$home/.apkrun-cvd-fleet-home"
  for entry in "$home"/* "$home"/.[!.]* "$home"/..?*; do
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
      continue
    fi
    case "$entry" in
      "$marker_path") ;;
      *)
        printf 'Cuttlefish fleet HOME contains an unexpected entry; preserving it.\n' >&2
        return 1
        ;;
    esac
  done
  if [ -e "$marker_path" ] || [ -L "$marker_path" ]; then
    if [ -L "$marker_path" ] || [ ! -f "$marker_path" ] \
      || [ ! -O "$marker_path" ] \
      || ! (trap '' HUP INT TERM; rm -f -- "$marker_path"); then
      printf 'Could not roll back the Cuttlefish fleet HOME ownership marker.\n' >&2
      return 1
    fi
  fi
  if ! (trap '' HUP INT TERM; rmdir -- "$home"); then
    printf 'Could not remove the incomplete Cuttlefish fleet HOME.\n' >&2
    return 1
  fi
  short_cvd_fleet_home=
}

create_short_cvd_fleet_home() {
  local physical_fleet_home fleet_marker
  if [ -z "${short_cvd_home_tmpdir:-}" ] \
    || [ -L "$short_cvd_home_tmpdir" ] || [ ! -d "$short_cvd_home_tmpdir" ]; then
    printf 'Short Cuttlefish HOME temporary directory is unavailable.\n' >&2
    return 1
  fi
  short_cvd_fleet_home=$(trap '' HUP INT TERM; mktemp -d "$short_cvd_home_tmpdir/p.XXXXXX") || return 1
  if ! (trap '' HUP INT TERM; chmod 700 "$short_cvd_fleet_home"); then
    printf 'Could not set private permissions on the Cuttlefish fleet HOME.\n' >&2
    rollback_short_cvd_fleet_home || true
    return 1
  fi
  if ! physical_fleet_home=$(trap '' HUP INT TERM; python3 - "$short_cvd_fleet_home" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  ); then
    printf 'Could not verify the physical Cuttlefish fleet HOME.\n' >&2
    rollback_short_cvd_fleet_home || true
    return 1
  fi
  if [ "$physical_fleet_home" != "$short_cvd_fleet_home" ]; then
    printf 'The Cuttlefish fleet HOME is not physically canonical.\n' >&2
    rollback_short_cvd_fleet_home || true
    return 1
  fi
  fleet_marker="$short_cvd_fleet_home/.apkrun-cvd-fleet-home"
  if ! printf 'APKRun Cuttlefish fleet HOME v1\n%s\n%s\n%s\n' \
    "$workspace_token" "$work_root" "$short_cvd_fleet_home" > "$fleet_marker"; then
    printf 'Could not mark the private Cuttlefish fleet HOME.\n' >&2
    rollback_short_cvd_fleet_home || true
    return 1
  fi
  if ! (trap '' HUP INT TERM; chmod 600 "$fleet_marker"); then
    printf 'Could not set private permissions on the Cuttlefish fleet HOME marker.\n' >&2
    rollback_short_cvd_fleet_home || true
    return 1
  fi
}

remove_short_cvd_fleet_home() {
  local home_mode marker_path marker_mode marker expected_marker physical_home
  local process_ids defer_cleanup_signal=0 removal_status=0
  if [ -z "${short_cvd_fleet_home:-}" ]; then
    return 0
  fi
  case "$short_cvd_fleet_home" in
    "$short_cvd_home_tmpdir"/p.??????) ;;
    *)
      printf 'Cuttlefish fleet HOME is outside its private temporary directory.\n' >&2
      return 1
      ;;
  esac
  if [ -L "$short_cvd_fleet_home" ] || [ ! -d "$short_cvd_fleet_home" ] \
    || [ ! -O "$short_cvd_fleet_home" ]; then
    printf 'Cuttlefish fleet HOME is missing or unsafe.\n' >&2
    return 1
  fi
  home_mode=$(python3 -c \
    'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' \
    "$short_cvd_fleet_home") || return 1
  if [ "$home_mode" != 700 ]; then
    printf 'Cuttlefish fleet HOME is not private.\n' >&2
    return 1
  fi
  if ! physical_home=$(python3 - "$short_cvd_fleet_home" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
  ); then
    printf 'Could not verify the physical Cuttlefish fleet HOME.\n' >&2
    return 1
  fi
  if [ "$physical_home" != "$short_cvd_fleet_home" ]; then
    printf 'Cuttlefish fleet HOME is not physically canonical.\n' >&2
    return 1
  fi
  marker_path="$short_cvd_fleet_home/.apkrun-cvd-fleet-home"
  if [ -L "$marker_path" ] || [ ! -f "$marker_path" ] || [ ! -O "$marker_path" ]; then
    printf 'Cuttlefish fleet HOME ownership marker is missing or unsafe.\n' >&2
    return 1
  fi
  marker_mode=$(python3 -c \
    'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' \
    "$marker_path") || return 1
  if [ "$marker_mode" != 600 ]; then
    printf 'Cuttlefish fleet HOME ownership marker is not private.\n' >&2
    return 1
  fi
  expected_marker=$(printf 'APKRun Cuttlefish fleet HOME v1\n%s\n%s\n%s' \
    "$workspace_token" "$work_root" "$short_cvd_fleet_home")
  marker=$(< "$marker_path")
  if [ "$marker" != "$expected_marker" ]; then
    printf 'Cuttlefish fleet HOME ownership marker does not match this workspace.\n' >&2
    return 1
  fi
  if ! private_cvd_processes_are_clean \
    "$short_cvd_fleet_home" "$short_cvd_fleet_home"; then
    printf 'A Cuttlefish host process still references the fleet HOME; preserving it.\n' >&2
    return 1
  fi
  if ! process_ids=$(query_crosvm_processes); then
    printf 'Could not verify that Cuttlefish is stopped before fleet HOME cleanup.\n' >&2
    return 1
  fi
  process_ids=${process_ids//[[:space:]]/}
  if [ -n "$process_ids" ]; then
    printf 'A Cuttlefish crosvm process is active; preserving fleet HOME.\n' >&2
    return 1
  fi
  if [ "${interrupted:-0}" -eq 0 ]; then
    capture_process_starting_role=fleet_home_cleanup
    capture_process_starting_released=1
    defer_cleanup_signal=1
  fi
  if ! (trap '' HUP INT TERM; rm -rf -- "$short_cvd_fleet_home"); then
    printf 'Could not remove the private Cuttlefish fleet HOME.\n' >&2
    removal_status=1
  elif [ -e "$short_cvd_fleet_home" ] || [ -L "$short_cvd_fleet_home" ]; then
    printf 'Cuttlefish fleet HOME remains after cleanup.\n' >&2
    removal_status=1
  else
    short_cvd_fleet_home=
  fi
  if [ "$defer_cleanup_signal" -eq 1 ]; then
    capture_process_starting_role=
    _capture_process_complete_startup_signal fleet_home_cleanup
    capture_process_starting_released=0
  fi
  if [ "$removal_status" -ne 0 ]; then
    return 1
  fi
}

scrub_raw_logcat() {
  python3 "$script_dir/experiment_support.py" scrub-logcat \
    --work-root "$work_root" --adb-log-root "$adb_log_root" \
    --data-root "$data_root" --ownership-token "$workspace_token"
}

remove_short_cvd_root() {
  local root_mode tmp_mode marker_path marker_mode marker expected_marker
  local socket_metrics_path state_root defer_cleanup_signal=0 removal_status=0
  if [ -z "${short_cvd_root:-}" ]; then
    return 0
  fi
  if [ -n "${short_cvd_fleet_home:-}" ]; then
    if [ -e "$short_cvd_fleet_home" ] || [ -L "$short_cvd_fleet_home" ]; then
      printf 'Private Cuttlefish fleet HOME still needs cleanup.\n' >&2
      return 1
    fi
    short_cvd_fleet_home=
  fi
  if [ ! -e "$short_cvd_root" ] && [ ! -L "$short_cvd_root" ]; then
    short_cvd_root=
    short_cvd_home_tmpdir=
    return 0
  fi
  if [ -L "$short_cvd_root" ] || [ ! -d "$short_cvd_root" ] \
    || [ ! -O "$short_cvd_root" ]; then
    printf 'Short Cuttlefish HOME root is not a current-user directory.\n' >&2
    return 1
  fi
  root_mode=$(python3 -c \
    'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' \
    "$short_cvd_root") || return 1
  if [ "$root_mode" != 700 ]; then
    printf 'Short Cuttlefish HOME root is not private.\n' >&2
    return 1
  fi
  if [ "$short_cvd_home_tmpdir" != "$short_cvd_root/t" ]; then
    printf 'Short Cuttlefish HOME path does not match its private root.\n' >&2
    return 1
  fi
  marker_path="$short_cvd_root/.apkrun-cvd-short-home"
  if [ -L "$marker_path" ] || [ ! -f "$marker_path" ] || [ ! -O "$marker_path" ]; then
    printf 'Short Cuttlefish HOME ownership marker is missing or unsafe.\n' >&2
    return 1
  fi
  marker_mode=$(python3 -c \
    'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' \
    "$marker_path") || return 1
  if [ "$marker_mode" != 600 ]; then
    printf 'Short Cuttlefish HOME ownership marker is not private.\n' >&2
    return 1
  fi
  expected_marker=$(printf 'APKRun Cuttlefish short HOME v1\n%s\n%s\n%s' \
    "$workspace_token" "$work_root" "$short_cvd_root")
  marker=$(< "$marker_path")
  if [ "$marker" != "$expected_marker" ]; then
    printf 'Short Cuttlefish HOME ownership marker does not match this workspace.\n' >&2
    return 1
  fi
  if [ -L "$short_cvd_home_tmpdir" ] || [ ! -d "$short_cvd_home_tmpdir" ] \
    || [ ! -O "$short_cvd_home_tmpdir" ]; then
    printf 'Short Cuttlefish HOME temporary directory is missing or unsafe.\n' >&2
    return 1
  fi
  tmp_mode=$(python3 -c \
    'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' \
    "$short_cvd_home_tmpdir") || return 1
  if [ "$tmp_mode" != 700 ]; then
    printf 'Short Cuttlefish HOME temporary directory is not private.\n' >&2
    return 1
  fi
  if [ -n "${CVD_HOST_DIR:-}" ]; then
    if ! require_no_crosvm \
      || ! private_cvd_processes_are_clean \
        "$short_cvd_home_tmpdir" "$short_cvd_home_tmpdir"; then
      printf 'Cuttlefish temporary files remain in use; preserving the private root.\n' >&2
      return 1
    fi
  fi
  socket_metrics_path=${capture_socket_metrics:-${fleet_socket_metrics:-$work_root/capture-socket-paths.json}}
  state_root=${cvd_state_dir:-${APKRUN_CVD_STATE_DIR:-}}
  if [ -z "${CVD_HOST_DIR:-}" ] || [ -z "$state_root" ]; then
    printf 'Cuttlefish HOME cleanup lacks verified process and state paths.\n' >&2
    return 1
  fi
  if ! python3 "$script_dir/experiment_support.py" audit-unix-sockets \
    --root "$short_cvd_home_tmpdir" --root "$state_root" \
    --output "$socket_metrics_path"; then
    printf 'Cuttlefish socket paths could not be re-audited before cleanup.\n' >&2
    return 1
  fi
  if [ "${interrupted:-0}" -eq 0 ]; then
    capture_process_starting_role=short_home_cleanup
    capture_process_starting_released=1
    defer_cleanup_signal=1
  fi
  if ! (trap '' HUP INT TERM; python3 "$script_dir/experiment_support.py" discard-short-cvd-root \
    --root "$short_cvd_root" \
    --work-root "$work_root" \
    --data-root "$data_root" \
    --ownership-token "$workspace_token" \
    --host-dir "$CVD_HOST_DIR" \
    --state-root "$state_root" \
    --socket-metrics "$socket_metrics_path"); then
    printf 'Cuttlefish temporary files could not be safely removed.\n' >&2
    removal_status=1
  else
    short_cvd_root=
    short_cvd_home_tmpdir=
  fi
  if [ "$defer_cleanup_signal" -eq 1 ]; then
    capture_process_starting_role=
    _capture_process_complete_startup_signal short_home_cleanup
    capture_process_starting_released=0
  fi
  if [ "$removal_status" -ne 0 ]; then
    return 1
  fi
  return 0
}

report_capture_output_status() {
  local status_path=$1 truncated
  if [ ! -e "$status_path" ] && [ ! -L "$status_path" ]; then
    printf 'Capture output status is missing.\n' >&2
    return 1
  fi
  if [ -L "$status_path" ] || [ ! -f "$status_path" ]; then
    printf 'Capture output status is not a regular file.\n' >&2
    return 1
  fi
  if ! truncated=$(python3 - "$status_path" <<'PY'
import json
import sys
from pathlib import Path

try:
    status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if (
    not isinstance(status, dict)
    or type(status.get("schemaVersion")) is not int
    or status["schemaVersion"] != 1
    or type(status.get("bytesWritten")) is not int
    or not 0 <= status["bytesWritten"] <= 1_048_576
    or type(status.get("truncated")) is not bool
    or type(status.get("timedOut")) is not bool
    or "childExitCode" not in status
    or (
        status.get("childExitCode") is not None
        and type(status.get("childExitCode")) is not int
    )
    or "signal" not in status
    or (status.get("signal") is not None and type(status.get("signal")) is not int)
    or type(status.get("cleanupComplete")) is not bool
    or status["cleanupComplete"] is not True
):
    raise SystemExit(1)
print("true" if status["truncated"] else "false")
PY
  ); then
    printf 'Capture output status is invalid; its private log may be incomplete.\n' >&2
    return 1
  fi
  if [ "$truncated" = true ]; then
    printf 'Capture output reached its 1 MiB limit; later output may be missing from the private log.\n' >&2
    return 1
  fi
}

discard_workspace_safely() {
  if [ -z "${work_root:-}" ]; then
    keep_work=0
    return 0
  fi
  if ! cvd_is_clean; then
    printf 'Cuttlefish is not verified clean; preserving its workspace.\n' >&2
    printf 'Private diagnostic workspace: %s\n' "$work_root" >&2
    if [ -n "${short_cvd_root:-}" ]; then
      printf 'Short Cuttlefish HOME root: %s\n' "$short_cvd_root" >&2
    fi
    keep_work=1
    return 1
  fi
  if ! remove_short_cvd_root; then
    printf 'Private workspace retained because Cuttlefish HOME cleanup failed.\n' >&2
    printf 'Private diagnostic workspace: %s\n' "$work_root" >&2
    if [ -n "${short_cvd_root:-}" ]; then
      printf 'Short Cuttlefish HOME root: %s\n' "$short_cvd_root" >&2
    fi
    keep_work=1
    return 1
  fi
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
  if [ "$keep_work" -eq 0 ] && [ -n "${work_root:-}" ]; then
    discard_workspace_safely || true
  fi
}

retain_workspace_safely() {
  if cvd_is_clean; then
    if ! remove_short_cvd_root; then
      printf 'Private workspace retained; verify both paths before cleanup.\n' >&2
      printf 'Private diagnostic workspace: %s\n' "$work_root" >&2
      printf 'Short Cuttlefish HOME root: %s\n' "${short_cvd_root:-unknown}" >&2
    fi
  elif [ -n "${short_cvd_root:-}" ]; then
    printf 'Cuttlefish is not verified clean; preserve both paths for cleanup.\n' >&2
    printf 'Private diagnostic workspace: %s\n' "$work_root" >&2
    printf 'Short Cuttlefish HOME root: %s\n' "$short_cvd_root" >&2
  fi
  keep_work=1
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
        retain_workspace_safely
        return 1
      fi
    fi
  fi
  retain_workspace_safely
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

run_committed_capture_bounded() {
  local tool_root=${experiment_tools:-$script_dir}
  python3 - "$repo_root" "$tool_root" "$@" <<'PY'
import subprocess
import sys
import types
from pathlib import Path

repo_root = Path(sys.argv[1])
tool_root = Path(sys.argv[2])
arguments = sys.argv[3:]
relative_root = "Experiments/cuttlefish-boot-diagnosis"
tool_names = ("capture_bounded.py", "capture_processes.py")
try:
    commit = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=repo_root,
        check=True,
        capture_output=True,
    ).stdout.strip().decode("ascii")
    sources = {}
    for name in tool_names:
        relative_path = f"{relative_root}/{name}"
        status = subprocess.run(
            ["git", "status", "--porcelain", "--", relative_path],
            cwd=repo_root,
            check=True,
            capture_output=True,
        ).stdout
        if status:
            raise SystemExit(f"{name} has uncommitted changes")
        source = subprocess.run(
            ["git", "show", f"{commit}:{relative_path}"],
            cwd=repo_root,
            check=True,
            capture_output=True,
        ).stdout
        copied_path = tool_root / name
        if copied_path.is_symlink() or not copied_path.is_file():
            raise SystemExit(f"private {name} copy is missing or unsafe")
        if copied_path.read_bytes() != source:
            raise SystemExit(f"private {name} copy differs from committed HEAD")
        sources[name] = source
except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as error:
    raise SystemExit("cannot load committed bounded-capture tools") from error

dependency = types.ModuleType("capture_processes")
dependency.__file__ = str(tool_root / "capture_processes.py")
exec(
    compile(sources["capture_processes.py"], dependency.__file__, "exec"),
    dependency.__dict__,
)
sys.modules["capture_processes"] = dependency
script_path = tool_root / "capture_bounded.py"
sys.argv = [str(script_path), *arguments]
exec(
    compile(sources["capture_bounded.py"], str(script_path), "exec"),
    {"__name__": "__main__", "__file__": str(script_path)},
)
PY
}

run_committed_experiment_support() {
  local support_root=${experiment_tools:-$script_dir}
  python3 - "$repo_root" "$support_root/experiment_support.py" "$@" <<'PY'
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
script_path = Path(sys.argv[2])
arguments = sys.argv[3:]
relative_path = "Experiments/cuttlefish-boot-diagnosis/experiment_support.py"
if script_path.is_symlink() or not script_path.is_file():
    raise SystemExit("committed experiment-support source is missing or unsafe")
try:
    commit = subprocess.run(
        ["git", "rev-parse", "--verify", "HEAD"],
        cwd=repo_root,
        check=True,
        capture_output=True,
    ).stdout.strip().decode("ascii")
    status = subprocess.run(
        ["git", "status", "--porcelain", "--", relative_path],
        cwd=repo_root,
        check=True,
        capture_output=True,
    ).stdout
    if status:
        raise SystemExit("experiment-support source has uncommitted changes")
    source = subprocess.run(
        ["git", "show", f"{commit}:{relative_path}"],
        cwd=repo_root,
        check=True,
        capture_output=True,
    ).stdout
except (OSError, subprocess.CalledProcessError, UnicodeDecodeError) as error:
    raise SystemExit("cannot load committed experiment-support source") from error
if script_path.read_bytes() != source:
    raise SystemExit("private experiment-support copy differs from committed HEAD")
sys.argv = [str(script_path), *arguments]
exec(
    compile(source, str(script_path), "exec"),
    {"__name__": "__main__", "__file__": str(script_path)},
)
PY
}

run_verified_experiment_support() {
  python3 - "$experiment_tools/experiment_support.py" "$host_identity" "$@" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

script_path = Path(sys.argv[1])
identity_path = Path(sys.argv[2])
arguments = sys.argv[3:]
if script_path.is_symlink() or not script_path.is_file():
    raise SystemExit("verified experiment-support copy is missing or unsafe")
try:
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("verified experiment-support identity is unavailable") from error
expected = identity.get("experimentSources", {}).get("experiment_support.py")
source = script_path.read_bytes()
if not isinstance(expected, str) or hashlib.sha256(source).hexdigest() != expected:
    raise SystemExit("experiment-support copy differs from verified source")
sys.argv = [str(script_path), *arguments]
exec(
    compile(source, str(script_path), "exec"),
    {"__name__": "__main__", "__file__": str(script_path)},
)
PY
}

run_verified_compare_boot() {
  local normalize_tool=$1 capture_record=$2
  python3 - \
    "$normalize_tool" "$(dirname "$normalize_tool")/normalize.yaml" \
    "$host_identity" "$capture_record" <<'PY'
import fcntl
import hashlib
import json
import os
import sys
from pathlib import Path

compare_path = Path(sys.argv[1])
rules_path = Path(sys.argv[2])
identity_path = Path(sys.argv[3])
capture_record = sys.argv[4]
if (
    compare_path.is_symlink()
    or not compare_path.is_file()
    or rules_path.is_symlink()
    or not rules_path.is_file()
):
    raise SystemExit("verified normalization inputs are missing or unsafe")
try:
    identity = json.loads(identity_path.read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit("verified normalization identity is unavailable") from error
tool_blobs = identity.get("observedToolBlobs")
if not isinstance(tool_blobs, dict):
    raise SystemExit("verified canonical tool map is unavailable")
compare_source = compare_path.read_bytes()
rules_source = rules_path.read_bytes()


def git_blob_id(source: bytes) -> str:
    return hashlib.sha1(f"blob {len(source)}\0".encode("ascii") + source).hexdigest()


if (
    git_blob_id(compare_source)
    != tool_blobs.get("Images/tools/reference/compare_boot.py")
    or git_blob_id(rules_source)
    != tool_blobs.get("Images/tools/reference/normalize.yaml")
):
    raise SystemExit("normalization inputs differ from the verified Git revision")
if not hasattr(os, "memfd_create") or not hasattr(fcntl, "F_ADD_SEALS"):
    raise SystemExit("sealed normalization rules are unavailable on this Linux host")
rules_fd = os.memfd_create("apkrun-normalize.yaml", os.MFD_ALLOW_SEALING)
pending = memoryview(rules_source)
while pending:
    pending = pending[os.write(rules_fd, pending) :]
fcntl.fcntl(
    rules_fd,
    fcntl.F_ADD_SEALS,
    fcntl.F_SEAL_SEAL
    | fcntl.F_SEAL_SHRINK
    | fcntl.F_SEAL_GROW
    | fcntl.F_SEAL_WRITE,
)
os.lseek(rules_fd, 0, os.SEEK_SET)
sys.argv = [
    str(compare_path),
    "normalize",
    capture_record,
    "--rules",
    f"/proc/self/fd/{rules_fd}",
]
exec(
    compile(compare_source, str(compare_path), "exec"),
    {"__name__": "__main__", "__file__": str(compare_path)},
)
PY
}

normalize_and_scrub_for_publication() {
  local capture_record=$1 normalize_tool=$2
  if ! scrub_raw_logcat; then
    return 1
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
    return 1
  fi
  if ! run_verified_compare_boot "$normalize_tool" "$capture_record"; then
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
  if ! remove_short_cvd_root; then
    printf 'Could not remove the private Cuttlefish HOME root; refusing to publish.\n' >&2
    return 1
  fi
  if [ -e "$result_path" ] || [ -L "$result_path" ]; then
    printf 'Refusing to overwrite diagnostic result: %s\n' "$result_path" >&2
    return 1
  fi
  if ! run_verified_experiment_support publish-record \
    --capture-record "$capture_record" --work-root "$work_root" \
    --data-root "$data_root" --result-path "$result_path" \
    --ownership-token "$workspace_token"; then
    printf 'Could not safely publish the normalized record.\n' >&2
    return 1
  fi
}
