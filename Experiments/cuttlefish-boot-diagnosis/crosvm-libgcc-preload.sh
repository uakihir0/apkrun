#!/bin/sh
# Diagnostic-only wrapper for probing crosvm panic output on the ARM64 Lima host.

set -eu

printf '%s\n' 'APKRun diagnostic crosvm wrapper invoked' >&2
export LD_PRELOAD=/lib/aarch64-linux-gnu/libgcc_s.so.1
exec /usr/lib/cuttlefish-common/bin/crosvm "$@"
