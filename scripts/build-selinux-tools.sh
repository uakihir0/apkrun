#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python_bin="$(command -v python3.12 || true)"
if [[ -z "$python_bin" ]]; then
    printf 'build-selinux-tools: python3.12 is not on PATH (environment-setup §2.4)\n' >&2
    exit 1
fi

exec "$python_bin" "$script_dir/tools/build_selinux_tools.py" "$@"
