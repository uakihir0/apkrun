#!/usr/bin/env bash
# Checks scripts/tools/gate-status.sh: each way a gate can end writes one status line and the real exit code (#24
# review of run 3). Each case runs a shell that sources the helper, installs it on a report, and ends in one way.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/../tools/gate-status.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-gate-status.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
    printf 'FAIL gate status: %s\n' "$1" >&2
    exit 1
}

# run_case NAME EXPECTED_STATUS EXPECTED_EXIT COMMAND: COMMAND runs in the shell after the helper is installed.
run_case() {
    local name="$1" expected_status="$2" expected_exit="$3" command="$4"
    local report="$work/$name.txt"
    printf 'gate: G3\nstatus: running\n' > "$report"
    local code=0
    bash -c 'source "$1"; gate_report_install "$2"; eval "$3"' _ "$helper" "$report" "$command" || code=$?
    if [[ "$code" -ne "$expected_exit" ]]; then
        fail "$name: the shell exited with $code, expected $expected_exit"
    fi
    local statuses
    statuses="$(grep -c '^status: ' "$report" || true)"
    if [[ "$statuses" -ne 1 ]]; then
        fail "$name: the report holds $statuses status lines"
    fi
    if ! grep -qx "status: $expected_status" "$report"; then
        fail "$name: the report does not hold status: $expected_status"
    fi
    if ! grep -qx "exit_code: $expected_exit" "$report"; then
        fail "$name: the report does not hold exit_code: $expected_exit"
    fi
    if grep -q 'status: running' "$report"; then
        fail "$name: the report still holds status: running"
    fi
    if [[ "$(grep -c '^finished: ' "$report")" -ne 1 ]]; then
        fail "$name: the report does not record the finish once"
    fi
    printf 'PASS gate status: %s\n' "$name"
}

run_case passed passed 0 'exit 0'
run_case failed failed 65 'exit 65'
run_case interrupted-by-int interrupted 130 'kill -INT $$; sleep 5'
run_case interrupted-by-term interrupted 143 'kill -TERM $$; sleep 5'
run_case interrupted-by-hup interrupted 129 'kill -HUP $$; sleep 5'

# A gate that waits on a child (the G3 recorder) and is interrupted from outside. The shell is started with the default
# dispositions, because a background job of a non-interactive shell inherits SIGINT as ignored.
waiting_report="$work/interrupted-while-waiting.txt"
printf 'gate: G3\nstatus: running\n' > "$waiting_report"
perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' bash -c 'source "$1"; gate_report_install "$2"; sleep 30 & wait $!' \
    _ "$helper" "$waiting_report" &
waiting_pid=$!
sleep 1
waiting_child="$(pgrep -P "$waiting_pid" || true)"
kill -INT "$waiting_pid"
waiting_code=0
wait "$waiting_pid" || waiting_code=$?
if [[ -n "$waiting_child" ]]; then
    kill "$waiting_child" 2>/dev/null || true
fi
if [[ "$waiting_code" -ne 130 ]] || ! grep -qx 'status: interrupted' "$waiting_report" \
    || ! grep -qx 'exit_code: 130' "$waiting_report"; then
    fail "interrupted while waiting: exit $waiting_code, report: $(cat "$waiting_report")"
fi
printf 'PASS gate status: interrupted while waiting on a child\n'

