#!/usr/bin/env bash
# annotate-errors.sh <log> — echo compiler/test failures of a captured step
# log into workflow error annotations. Job logs need a signed-in viewer even
# for public repositories; annotations are public.
set -uo pipefail

log="${1:-}"
[[ -f "$log" ]] || exit 0
grep -E "error:|✘|FAILED|fatal" "$log" | head -40 | while IFS= read -r line; do
    line="${line//'%'/'%25'}"
    line="${line//$'\r'/}"
    printf '::error::%s\n' "$line"
done
