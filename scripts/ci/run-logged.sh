#!/usr/bin/env bash
# run-logged.sh <logfile> <command...> — run a CI step, tee its output, and on
# failure echo the error lines into public workflow annotations (job logs
# need a signed-in viewer even for public repositories).
set -uo pipefail

log="${1:?log path required}"
shift
mkdir -p "$(dirname "$log")"
set +e
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
if [[ $status -ne 0 ]]; then
    scripts/ci/annotate-errors.sh "$log"
    exit "$status"
fi
