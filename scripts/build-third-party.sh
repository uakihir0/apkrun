#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ "${1:-}" == "--print-cache-key" ]]; then
    shift
    if [[ $# -ne 1 ]]; then
        printf 'usage: %s --print-cache-key <build-group>\n' "$0" >&2
        exit 2
    fi
    exec python3 "$script_dir/tools/build_third_party.py" cache-key "$1"
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf 'usage: %s <build-group> [--force]\n' "$0" >&2
    exit 2
fi

exec python3 "$script_dir/tools/build_third_party.py" build "$@"
