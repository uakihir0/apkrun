#!/usr/bin/env bash
# The final status of a gate report, written once whichever way the gate ends (#023 review of run 3).
#
# scripts/run-gate.sh sources this file and calls gate_report_install REPORT after it has written the report's first
# block, which holds `status: running`. The EXIT trap then replaces that line with one final status and appends
# `finished:` and `exit_code:`:
#   status: passed       for exit 0
#   status: failed       for any other exit
#   status: interrupted  when INT, TERM, or HUP arrived, with exit 130, 143, or 129
# Each signal sets the status and exits, so the EXIT trap is the only writer. A shell that is killed without a trap
# leaves `status: running` in the report, which says that the gate did not finish.
#
# GATE_FINISH_HOOK, when set, names a function that runs before the status is written (run-gate.sh stops its recorder).

gate_report_path=""
gate_report_interrupted=""
gate_report_finished=0

gate_report_finish() {
    local result=$?
    if (( gate_report_finished )); then
        return
    fi
    gate_report_finished=1
    if [[ -n "${GATE_FINISH_HOOK:-}" ]]; then
        "$GATE_FINISH_HOOK" || true
    fi
    local status
    if [[ -n "$gate_report_interrupted" ]]; then
        status=interrupted
    elif [[ $result -eq 0 ]]; then
        status=passed
    else
        status=failed
    fi
    local temporary="$gate_report_path.status.$$"
    awk -v status="$status" '
        $0 == "status: running" && !done { print "status: " status; done = 1; next }
        { print }
        END { if (!done) print "status: " status }
    ' "$gate_report_path" > "$temporary" && mv "$temporary" "$gate_report_path"
    {
        printf 'finished: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'exit_code: %s\n' "$result"
    } >> "$gate_report_path"
}

gate_report_interrupt() {
    gate_report_interrupted="$1"
    exit "$2"
}

gate_report_install() {
    gate_report_path="$1"
    trap gate_report_finish EXIT
    trap 'gate_report_interrupt INT 130' INT
    trap 'gate_report_interrupt TERM 143' TERM
    trap 'gate_report_interrupt HUP 129' HUP
}
