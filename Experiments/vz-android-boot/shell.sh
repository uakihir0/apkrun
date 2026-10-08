#!/bin/bash
# Usage: shell.sh <run dir> <command...>
# Sends one command to the Android serial shell (hvc1) and prints its output.
set -euo pipefail
run="$1"; shift
n="$RANDOM$RANDOM"
log="$run/hvc1.log"
before=$(wc -c < "$log")
printf '%s; echo __END_%s__ $?\n' "$*" "$n" > "$run/hvc1.in"
for _ in $(seq 1 ${SHELL_TIMEOUT:-60}); do
  if tail -c +$((before + 1)) "$log" | grep -a -q "^__END_${n}__"; then
    tail -c +$((before + 1)) "$log" | tr -d '\r' | sed -n "2,/^__END_${n}__/p"
    exit 0
  fi
  sleep 1
done
echo "shell.sh: no answer within ${SHELL_TIMEOUT:-60}s" >&2
exit 1
