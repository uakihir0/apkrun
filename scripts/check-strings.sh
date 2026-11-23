#!/bin/sh
# Localization lint (host-ui.md §13):
#   - every catalog key must be referenced by a literal in its target's
#     sources (no stale keys)
#   - every catalog key and errors.json message/remediation needs ja
#   - Release builds fail on any finding; Debug builds only warn.
set -eu
cd "$(dirname "$0")/.."

mode="${1:-debug}"
out="$(python3 scripts/l10n/gen-strings.py --check)"
if [ -z "$out" ]; then
    echo "check-strings: clean"
    exit 0
fi
echo "$out" | head -50
count="$(echo "$out" | wc -l | tr -d ' ')"
if [ "$mode" = "release" ]; then
    echo "check-strings: FAIL ($count untranslated/stale entries) — add ja to scripts/l10n/ja.json and rerun gen-strings.py" >&2
    exit 1
fi
echo "check-strings: $count untranslated/stale entries (debug: warning only)"
exit 0
