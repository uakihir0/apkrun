#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

python3 "$repo_root/scripts/build/generate-launcher-strings.py" --check
printf 'check-launcher-strings: generated launcher strings are current\n'
