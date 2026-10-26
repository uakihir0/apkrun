#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
    printf 'usage: scripts/check-raw-adb.sh [--root REPOSITORY]\n' >&2
}

if [[ $# -eq 2 && "$1" == "--root" ]]; then
    if [[ ! -d "$2" ]]; then
        printf 'check-raw-adb: repository root is not a directory: %s\n' "$2" >&2
        exit 2
    fi
    repo_root="$(cd "$2" && pwd)"
elif [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
    exit 0
elif [[ $# -ne 0 ]]; then
    usage
    exit 2
fi

# Match the ADB shell subcommand, including the common selected-device form,
# and Package Manager commands. Keep the expressions line-based so this
# remains a fast source lint rather than a shell or Swift parser.
raw_command_pattern='(^|[^[:alnum:]_])adb([[:space:]]+-[[:alpha:]][[:space:]]+[^[:space:];|&]+)*[[:space:]]+shell([[:space:]]|$)|(^|[^[:alnum:]_])pm[[:space:]]'

is_exempt() {
    # Product code owns the rule; integration tests and experiments intentionally exercise raw ADB,
    # while generated protobuf comments are not executable source.
    case "$1" in
        Packages/RuntimeCore/Sources/RuntimeCore/Android/AdbClient.swift|\
        Packages/GuestProtocol/Sources/GuestProtocol/Generated/*|\
        scripts/dev/*|\
        Tests/*|\
        */Tests/*|\
        Experiments/*|\
        Tests/Compatibility/*|\
        Images/tools/reference/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_source_or_script() {
    case "$1" in
        *.swift|*.sh|*.bash|*.zsh|*.py|*.rb|*.pl|*.fish|*.csh|*.command)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

violation_count=0
while IFS= read -r -d '' path; do
    relative_path="${path#"$repo_root"/}"
    if is_exempt "$relative_path" || ! is_source_or_script "$relative_path"; then
        continue
    fi

    if matches="$(grep -nE "$raw_command_pattern" "$path" | grep -vE '^[0-9]+:[[:space:]]*(#|//|/\*|\*)')"; then
        while IFS= read -r match; do
            printf 'raw-ADB use outside the documented allowlist: %s:%s\n' "$relative_path" "$match" >&2
            violation_count=$((violation_count + 1))
        done <<<"$matches"
    else
        grep_status=$?
        if [[ $grep_status -gt 1 ]]; then
            printf 'check-raw-adb: could not read %s\n' "$relative_path" >&2
            exit "$grep_status"
        fi
    fi
done < <(
    find "$repo_root" \
        \( -type d \( -name .git -o -name .build -o -name build -o -name DerivedData \
            -o -name node_modules -o -name .venv -o -name .gradle -o -name target -o -name ThirdParty \) -prune \) -o \
        \( -type f -print0 \)
)

if [[ $violation_count -gt 0 ]]; then
    printf 'check-raw-adb: found %d forbidden occurrence(s)\n' "$violation_count" >&2
    exit 1
fi

printf 'check-raw-adb: passed\n'
