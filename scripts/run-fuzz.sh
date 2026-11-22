#!/usr/bin/env bash
# run-fuzz.sh <target>|--changed|--all [--seconds <n>]
#
# Runs one libFuzzer target, every target, or only the targets whose
# source paths changed (build-system.md §15.2). Each run is
# `-timeout=10 -rss_limit_mb=2048 -artifact_prefix=build/fuzz/<target>/`
# with the seed corpus of Tests/Fixtures/fuzz/<target>/.
#
# The fuzzer runtime is not in Xcode's toolchain: the script resolves
# the swift.org toolchain pinned as SWIFT_FUZZ_TOOLCHAIN in
# scripts/tool-versions.env from the standard toolchain directories
# (~/Library/Developer/Toolchains, /Library/Developer/Toolchains), or
# from SWIFT_FUZZ_TOOLCHAIN_HOME when the variable names a directory.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source scripts/tool-versions.env

seconds=60
selection=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds) seconds="$2"; shift 2 ;;
        --changed|--all) selection="$1"; shift ;;
        -*) printf 'run-fuzz: unknown flag %s\n' "$1" >&2; exit 64 ;;
        *) selection="$1"; shift ;;
    esac
done
[[ -n "$selection" ]] || { printf 'usage: run-fuzz.sh <target>|--changed|--all [--seconds <n>]\n' >&2; exit 64; }

# target -> (module product, fuzz target id, watched path prefixes)
targets=(
    "virtio-gpu-request|GraphicsCoreFuzz|Packages/GraphicsCore"
    "resource-table|GraphicsCoreFuzz|Packages/GraphicsCore"
    "guest-frame-swift|GuestProtocolFuzz|Packages/GuestProtocol"
    "container-reader|APKStoreCoreFuzz|Packages/APKStoreCore"
    "apk-signing-block|APKStoreCoreFuzz|Packages/APKStoreCore"
    "aapt2-badging|APKStoreCoreFuzz|Packages/APKStoreCore"
    "direct-manifest|UpdateCoreFuzz|Packages/UpdateCore"
    "fdroid-index|UpdateCoreFuzz|Packages/UpdateCore"
    "github-releases|UpdateCoreFuzz|Packages/UpdateCore"
)

# Resolve the pinned swift.org toolchain.
resolve_toolchain() {
    if [[ -d "${SWIFT_FUZZ_TOOLCHAIN:-}" ]]; then
        printf '%s' "$SWIFT_FUZZ_TOOLCHAIN"
        return
    fi
    local dir candidate
    for dir in "$HOME/Library/Developer/Toolchains" "/Library/Developer/Toolchains"; do
        [[ -d "$dir" ]] || continue
        candidate="$(find "$dir" -maxdepth 1 -name "${SWIFT_FUZZ_TOOLCHAIN}*.xctoolchain" -type d | sort | tail -1)"
        if [[ -n "$candidate" ]]; then
            basename "$candidate" .xctoolchain
            return
        fi
        # Newest installed swift.org toolchain as a fallback.
        candidate="$(find "$dir" -maxdepth 1 -name "org.swift.*.xctoolchain" -type d | sort | tail -1)"
        [[ -n "$candidate" ]] || candidate="$(find "$dir" -maxdepth 1 -name "swift-*.xctoolchain" -type d | sort | tail -1)"
        if [[ -n "$candidate" ]]; then
            basename "$candidate" .xctoolchain
            return
        fi
    done
    printf 'run-fuzz: no swift.org toolchain found; install the %s toolchain from swift.org\n' "$SWIFT_FUZZ_TOOLCHAIN" >&2
    return 78
}

toolchain="$(resolve_toolchain)" || exit $?

run_one() {
    local product="$1" name="$2"
    local corpus="Tests/Fixtures/fuzz/$name"
    local artifacts="build/fuzz/$name"
    mkdir -p "$artifacts" "$corpus"
    printf '==> fuzz %s (%ss)\n' "$name" "$seconds"
    APKRUN_FUZZ=1 TOOLCHAINS="$toolchain" swift build -c debug \
        --product "$product" \
        --sanitize=fuzzer --sanitize=address --sanitize=undefined
    local bin=".build/debug/$product"
    APKRUN_FUZZ_TARGET="$name" "$bin" \
        -max_total_time="$seconds" -timeout=10 -rss_limit_mb=2048 \
        -artifact_prefix="$artifacts/" "$corpus"
}

selected=()
case "$selection" in
    --all)
        selected=("${targets[@]}") ;;
    --changed)
        base="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main)"
        changed="$(git diff --name-only "$base" HEAD; git diff --name-only)"
        for row in "${targets[@]}"; do
            prefix="${row##*|}"
            if grep -q "^${prefix}" <<< "$changed"; then
                selected+=("$row")
            fi
        done
        [[ ${#selected[@]} -gt 0 ]] || { echo 'run-fuzz: no fuzz target covers the changed paths'; exit 0; } ;;
    *)
        for row in "${targets[@]}"; do
            [[ "${row%%|*}" == "$selection" ]] && selected+=("$row")
        done
        [[ ${#selected[@]} -gt 0 ]] || { printf 'run-fuzz: unknown target %s\n' "$selection" >&2; exit 64; } ;;
esac

for row in "${selected[@]}"; do
    IFS='|' read -r name product _prefix <<< "$row"
    run_one "$product" "$name"
done
