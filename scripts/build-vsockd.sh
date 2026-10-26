#!/usr/bin/env bash
# Build apkrun_vsockd with the crate's pinned Rust toolchain, cargo-ndk, and NDK,
# then atomically stage it for the composed Android product (#36).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
crate_dir="$repo_root/Guest/vsockd"
lock="$repo_root/ThirdParty/ThirdParty.lock.json"
lock_helper="$repo_root/scripts/guest/mesa_android.py"
tool_versions="$repo_root/scripts/tool-versions.env"
toolchain_file="$crate_dir/rust-toolchain.toml"
prebuilt_dir="$repo_root/Guest/product/prebuilt"
binary="$crate_dir/target/aarch64-linux-android/release/apkrun_vsockd"
check_only=0

usage() {
    printf 'usage: scripts/build-vsockd.sh [--check]\n' >&2
    exit 64
}

die() {
    printf 'build-vsockd: %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --check)
            ((check_only == 0)) || usage
            check_only=1
            shift
            ;;
        *)
            usage
            ;;
    esac
done

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
    || die "the pinned macOS NDK build runs on Apple silicon macOS only"

python_bin="$(command -v python3.12 || command -v python3 || true)"
[[ -n "$python_bin" ]] || die "python3 is required to read the checked-in tool pins"
for path in "$lock" "$lock_helper" "$tool_versions" "$toolchain_file" \
    "$crate_dir/Cargo.toml" "$crate_dir/Cargo.lock"; do
    [[ -f "$path" && ! -L "$path" ]] || die "required checked-in input is missing or symlinked: $path"
done
[[ -d "$repo_root/Guest" && ! -L "$repo_root/Guest" ]] || die "Guest must be a real directory"
[[ -d "$repo_root/Guest/product" && ! -L "$repo_root/Guest/product" ]] \
    || die "Guest/product must be a real directory"
if [[ -e "$prebuilt_dir" || -L "$prebuilt_dir" ]]; then
    [[ -d "$prebuilt_dir" && ! -L "$prebuilt_dir" ]] \
        || die "Guest/product/prebuilt must be a real directory"
fi
destination="$prebuilt_dir/apkrun_vsockd"
if [[ -L "$destination" ]]; then
    die "refusing to replace a symlink at $destination"
elif [[ -e "$destination" && ! -f "$destination" ]]; then
    die "refusing to replace a non-file at $destination"
fi
[[ ! -L "$crate_dir/target" ]] || die "refusing to build through a symlink at $crate_dir/target"

source "$tool_versions"
[[ "${CARGO_NDK_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "CARGO_NDK_VERSION must be a pinned semantic version in scripts/tool-versions.env"

lock_field() {
    "$python_bin" "$lock_helper" lock-field "$lock" "$1" "$2"
}

ndk_kind="$(lock_field ndk kind)"
ndk_group="$(lock_field ndk group)"
ndk_version="$(lock_field ndk version)"
ndk_url="$(lock_field ndk url)"
ndk_sha256="$(lock_field ndk sha256)"
ndk_ships="$(lock_field ndk ships)"
ndk_revision="${ndk_version%% *}"
[[ "$ndk_kind" == "prebuilt" && "$ndk_group" == "guest-mesa" && "$ndk_ships" == "tooling" ]] \
    || die "the locked NDK must remain a pinned guest-mesa tooling prebuilt"
[[ "$ndk_revision" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$ndk_url" == https://* ]] \
    || die "the ThirdParty lock does not contain a valid pinned NDK version and URL"
[[ "$ndk_sha256" =~ ^[0-9a-f]{64}$ ]] || die "the locked NDK archive SHA-256 is invalid"

rust_values="$("$python_bin" - "$toolchain_file" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as toolchain_file:
    toolchain = tomllib.load(toolchain_file)["toolchain"]

print(toolchain["channel"])
for target in toolchain.get("targets", []):
    print(target)
PY
)" || die "cannot read Guest/vsockd/rust-toolchain.toml"
rust_channel="${rust_values%%$'\n'*}"
rust_targets="${rust_values#*$'\n'}"
[[ "$rust_channel" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Guest/vsockd/rust-toolchain.toml must pin a stable Rust release"
printf '%s\n' "$rust_targets" | grep -qxF "aarch64-linux-android" \
    || die "Guest/vsockd/rust-toolchain.toml must include aarch64-linux-android"
if [[ -n "${RUSTUP_TOOLCHAIN:-}" && "$RUSTUP_TOOLCHAIN" != "$rust_channel" \
    && "$RUSTUP_TOOLCHAIN" != "$rust_channel-"* ]]; then
    die "RUSTUP_TOOLCHAIN overrides the crate pin ($RUSTUP_TOOLCHAIN)"
fi
export RUSTUP_TOOLCHAIN="$rust_channel"

ndk=""
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME:-}/Library/Android/sdk}}"
for candidate in "$repo_root/build/android-sdk/ndk/$ndk_revision" \
    "${ANDROID_NDK_HOME:-}" "$sdk_root/ndk/$ndk_revision"; do
    [[ -n "$candidate" && -f "$candidate/source.properties" ]] || continue
    if grep -qxF "Pkg.Revision = $ndk_revision" "$candidate/source.properties"; then
        ndk="$candidate"
        break
    fi
done
[[ -n "$ndk" ]] || die "NDK $ndk_revision not found; install the pinned SDK package from environment-setup.md §2.5"
export ANDROID_NDK_HOME="$ndk"

cargo_bin="$(command -v cargo || true)"
rustc_bin="$(command -v rustc || true)"
[[ -n "$cargo_bin" && -n "$rustc_bin" ]] || die "cargo and rustc from the pinned Rust toolchain are required"

if ! rustc_version="$("$rustc_bin" --version 2>/dev/null)"; then
    die "could not run rustc from the pinned toolchain"
fi
[[ "$rustc_version" == "rustc $rust_channel "* ]] \
    || die "expected Rust $rust_channel from rust-toolchain.toml, got: $rustc_version"
if ! cargo_version="$("$cargo_bin" --version 2>/dev/null)"; then
    die "could not run cargo from the pinned toolchain"
fi
[[ "$cargo_version" == "cargo $rust_channel "* ]] \
    || die "expected Cargo $rust_channel from rust-toolchain.toml, got: $cargo_version"
if ! cargo_ndk_version="$("$cargo_bin" ndk --version 2>/dev/null)"; then
    die "cargo-ndk is not installed; install version $CARGO_NDK_VERSION from environment-setup.md §2.6"
fi
[[ "$cargo_ndk_version" == "cargo-ndk $CARGO_NDK_VERSION" ]] \
    || die "expected cargo-ndk $CARGO_NDK_VERSION, got: $cargo_ndk_version"

if ((check_only)); then
    printf 'check: Rust %s, cargo-ndk %s, NDK %s at %s\n' \
        "$rust_channel" "$CARGO_NDK_VERSION" "$ndk_revision" "$ndk"
    exit 0
fi

export CARGO_TARGET_DIR="$crate_dir/target"
(
    cd "$crate_dir"
    "$cargo_bin" ndk -t arm64-v8a build --locked --release
)
[[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] \
    || die "cargo-ndk did not produce a regular executable at $binary"

"$python_bin" "$script_dir/guest/stage_vsockd.py" "$repo_root" "$binary"
printf 'build-vsockd: staged pinned apkrun_vsockd in %s\n' "$destination"
