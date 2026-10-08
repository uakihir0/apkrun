#!/usr/bin/env bash
# Lints the guest protocol schema with the pinned buf (guest-protocol.md §2,
# coding-conventions.md §2). The buf binary comes only from build/tools.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tool-versions.env"

buf="$repo_root/build/tools/buf-$BUF_VERSION/bin/buf"
if [[ ! -x "$buf" ]]; then
    printf 'check-protos: missing %s; run scripts/bootstrap\n' "$buf" >&2
    exit 1
fi

cd "$repo_root/Packages/GuestProtocol"
"$buf" lint .
printf 'check-protos: buf lint passed for Packages/GuestProtocol\n'
