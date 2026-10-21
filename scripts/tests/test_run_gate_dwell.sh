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

lock_condition_line="$(grep -nF 'if [[ "${APKRUN_INTERNAL_RUN_GATE_LOCK_HELD:-}" != "$gate:$$" ]]; then' "$gate_script" | head -1 | cut -d: -f1 || true)"
lock_exec_line="$(grep -nF 'exec lockf -k /tmp/apkrun-vm.lock /bin/bash -c' "$gate_script" | head -1 | cut -d: -f1 || true)"
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
lock_stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/apkrun-lock-test.XXXXXX")"
trap 'rm -rf "$lock_stub_dir"' EXIT
lock_stub_marker="$lock_stub_dir/lockf-called"
cat > "$lock_stub_dir/lockf" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$APKRUN_TEST_LOCKF_MARKER" ]]; then
    exit 42
fi
if [[ "$1" != "-k" || "$2" != "/tmp/apkrun-vm.lock" ]]; then
    exit 43
fi
: > "$APKRUN_TEST_LOCKF_MARKER"
shift 2
exec "$@"
EOF
chmod +x "$lock_stub_dir/lockf"

assert_lock_handoff_with_marker() {
    local marker_value="$1"
    local marker_label="$2"
    rm -f "$lock_stub_marker"
    set +e
    PATH="$lock_stub_dir:$PATH" \
        APKRUN_TEST_LOCKF_MARKER="$lock_stub_marker" \
        APKRUN_INTERNAL_RUN_GATE_LOCK_HELD="$marker_value" \
        "$gate_script" G2 >/dev/null 2>&1
    local lock_status=$?
    set -e
    if [[ "$lock_status" -ne 78 || ! -f "$lock_stub_marker" ]]; then
        printf 'FAIL run-gate lock: %s did not acquire and hand off the lock exactly once\n' \
            "$marker_label" >&2
        exit 1
    fi
}

assert_lock_handoff_with_marker G2 "an inherited marker"
assert_lock_handoff_with_marker "G2:$$" "a stale process-bound marker"
printf 'PASS run-gate lock: G1, G2, and G3 hold the VM lock through artifact production and testing\n'
