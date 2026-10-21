#!/usr/bin/env bash
# Checks that scripts/run-gate.sh removes the dwell overrides before the first test, records the G2 dwell, and
# holds the VM lock for the full gate. Static: a gate needs main, a clean tree, and the lab's signing identity.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
gate_script="$repo_root/scripts/run-gate.sh"

unset_line="$(grep -n '^unset APKRUN_G2_DWELL_SECONDS TEST_RUNNER_APKRUN_G2_DWELL_SECONDS$' "$gate_script" | head -1 | cut -d: -f1 || true)"
test_line="$(grep -n '^xcodebuild test ' "$gate_script" | head -1 | cut -d: -f1 || true)"
if [[ -z "$unset_line" || -z "$test_line" || "$unset_line" -ge "$test_line" ]]; then
    printf 'FAIL run-gate dwell: the dwell overrides are not removed before the first xcodebuild test\n' >&2
    exit 1
fi
if ! grep -qx 'gate_dwell_seconds=600' "$gate_script"; then
    printf 'FAIL run-gate dwell: the gate does not set the default dwell of 600 seconds\n' >&2
    exit 1
fi
if ! grep -qF "printf 'dwell_seconds: %s\\n' \"\$gate_dwell_seconds\"" "$gate_script"; then
    printf 'FAIL run-gate dwell: the G2 report does not record the dwell\n' >&2
    exit 1
fi
printf 'PASS run-gate dwell: overrides removed before the run, dwell recorded in the G2 report\n'

lock_condition_line="$(grep -nF 'if [[ "${APKRUN_INTERNAL_RUN_GATE_LOCK_HELD:-}" != "$gate" ]]; then' "$gate_script" | head -1 | cut -d: -f1 || true)"
lock_exec_line="$(grep -nF 'exec lockf -k /tmp/apkrun-vm.lock env APKRUN_INTERNAL_RUN_GATE_LOCK_HELD="$gate" "$0" "$gate"' "$gate_script" | head -1 | cut -d: -f1 || true)"
producer_line="$(grep -n '^scripts/generate-project.sh$' "$gate_script" | head -1 | cut -d: -f1 || true)"
if [[ -z "$lock_condition_line" || -z "$lock_exec_line" || -z "$producer_line" \
    || "$lock_condition_line" -ge "$producer_line" || "$lock_exec_line" -ge "$producer_line" ]]; then
    printf 'FAIL run-gate lock: every gate must acquire the VM lock before changing artifacts\n' >&2
    exit 1
fi
if grep -qF 'lockf -k /tmp/apkrun-vm.lock xcodebuild test' "$gate_script"; then
    printf 'FAIL run-gate lock: G3 must use the gate-wide lock without acquiring it recursively\n' >&2
    exit 1
fi
printf 'PASS run-gate lock: G1, G2, and G3 hold the VM lock through artifact production and testing\n'
