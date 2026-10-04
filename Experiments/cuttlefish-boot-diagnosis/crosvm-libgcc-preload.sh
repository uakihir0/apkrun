#!/bin/sh
# Diagnostic-only wrapper for recovering crosvm panic output on the ARM64 Lima host.

set -eu

export LD_PRELOAD=/lib/aarch64-linux-gnu/libgcc_s.so.1
exec /usr/lib/cuttlefish-common/bin/crosvm "$@"
