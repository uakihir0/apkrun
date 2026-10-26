#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: scripts/run-gate.sh G1|G2|G3\n' >&2
    exit 64
fi

gate="$1"
if [[ "$gate" != G1 && "$gate" != G2 && "$gate" != G3 ]]; then
    printf 'run-gate: unsupported gate: %s\n' "$gate" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The gate body is a separate internal script so no inherited environment value can skip this lock acquisition.
exec lockf -k /tmp/apkrun-vm.lock /bin/bash "$script_dir/run-gate-body.sh" "$gate"
