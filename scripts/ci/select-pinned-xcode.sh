#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
expected_xcode="$(tr -d '[:space:]' < "$repo_root/.xcode-version")"

xcode_version() {
    local app_path="${1:-}"
    if [[ -n "$app_path" ]]; then
        DEVELOPER_DIR="$app_path/Contents/Developer" xcodebuild -version 2>/dev/null \
            | awk '/^Xcode / { print $2; exit }'
    else
        xcodebuild -version 2>/dev/null | awk '/^Xcode / { print $2; exit }'
    fi
}

selected_xcode="$(xcode_version || true)"
if [[ "$selected_xcode" == "$expected_xcode" ]]; then
    printf 'select-pinned-xcode: Xcode %s is already selected\n' "$selected_xcode"
    exit 0
fi

major_version="${expected_xcode%%.*}"
candidates=(
    "/Applications/Xcode_${expected_xcode}.app"
    "/Applications/Xcode_${expected_xcode}.0.app"
    "/Applications/Xcode_${major_version}.app"
)

for candidate in "${candidates[@]}"; do
    [[ -d "$candidate/Contents/Developer" ]] || continue
    candidate_xcode="$(xcode_version "$candidate" || true)"
    [[ "$candidate_xcode" == "$expected_xcode" ]] || continue

    sudo xcode-select --switch "$candidate/Contents/Developer"
    selected_xcode="$(xcode_version || true)"
    if [[ "$selected_xcode" == "$expected_xcode" ]]; then
        printf 'select-pinned-xcode: selected Xcode %s\n' "$selected_xcode"
        exit 0
    fi
done

printf 'select-pinned-xcode: required Xcode %s is unavailable (selected %s)\n' \
    "$expected_xcode" "${selected_xcode:-unknown}" >&2
exit 1
