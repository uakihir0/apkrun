#!/bin/bash
# Verifies the APKRunLauncher localization plumbing (host-ui.md §15):
#  - the launcher catalog and generated table exist and are current
#  - no user-facing literal in the launcher bypasses LauncherStrings
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
for f in Apps/APKRunLauncher/Localizable.xcstrings \
         Apps/APKRunLauncher/LauncherStrings.generated.swift; do
    if [[ ! -f "$f" ]]; then
        echo "check-launcher: missing $f" >&2
        fail=1
    fi
done
[[ "$fail" == 0 ]] || exit 1

# Every Text/Label/alert literal in the launcher must go through
# LauncherStrings.text; a bare literal means it never reaches the catalog.
violations=$(grep -rnoE '(Text|Label|Button|\.messageText|\.informativeText)\s*=\s*"[^"]+"' \
    Apps/APKRunLauncher/*.swift \
    | grep -v 'LauncherStrings' | grep -v 'LauncherStrings.generated.swift' || true)
if [[ -n "$violations" ]]; then
    echo "check-launcher: unlocalized launcher literals:" >&2
    echo "$violations" >&2
    exit 1
fi

# The catalog and generated table must match the sources and ja.json.
python3 scripts/l10n/gen-strings.py --check >/dev/null 2>&1 || {
    echo "check-launcher: catalogs are stale; run scripts/l10n/gen-strings.py" >&2
    exit 1
}
echo "check-launcher: clean"
