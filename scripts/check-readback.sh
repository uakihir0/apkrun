#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

exec python3 -I "$repo_root/scripts/tools/check_readback.py" --root "$repo_root" "$@"
