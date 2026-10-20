#!/usr/bin/env bash
# Builds the guest Mesa for Android ARM64 (EGL, GLES 2.0 and 1.1, gallium virgl) with the NDK r28c (ADR-0018, #99).
#
#   scripts/guest/build-mesa-android.sh                  build into ThirdParty/out/mesa-android
#   scripts/guest/build-mesa-android.sh --out DIR        build into DIR; the work area is DIR-work
#   scripts/guest/build-mesa-android.sh --ndk-archive F  also check the NDK archive F against the lock's SHA-256
#   scripts/guest/build-mesa-android.sh --check          check the NDK, the host tools, and the lock; build nothing
#
# Every source and tool is pinned in ThirdParty/ThirdParty.lock.json (group guest-mesa, and pyyaml in virgl-runtime).
# The Meson flags are the buildFlags of the mesa entry, and the output is checked by scripts/guest/mesa_android.py
# before it is published. The NDK comes from build/android-sdk, then $ANDROID_NDK_HOME, then ~/Library/Android/sdk
# (environment-setup §2.5). Nothing is installed outside the work area and the output directory.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
lock="$repo_root/ThirdParty/ThirdParty.lock.json"
helper="$script_dir/mesa_android.py"

ndk_api="35"

out_dir="$repo_root/ThirdParty/out/mesa-android"
work_dir=""
ndk_archive=""
check_only=0
jobs="$(sysctl -n hw.ncpu 2>/dev/null || printf '4')"

shipped_libraries=(libEGL_mesa.so libGLESv2_mesa.so libGLESv1_CM_mesa.so libgallium_dri.so)
ninja_targets=(src/egl/libEGL_mesa.so src/mesa/glapi/es2api/libGLESv2_mesa.so src/mesa/glapi/es1api/libGLESv1_CM_mesa.so
    src/gallium/targets/dri/libgallium_dri.so)

usage() {
    printf 'usage: scripts/guest/build-mesa-android.sh [--out DIR] [--work DIR] [--jobs N] [--ndk-archive FILE] [--check]\n' >&2
    exit 64
}

die() {
    printf 'build-mesa-android: %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --out)
            (($# >= 2)) || usage
            out_dir="$2"
            shift 2
            ;;
        --work)
            (($# >= 2)) || usage
            work_dir="$2"
            shift 2
            ;;
        --jobs)
            (($# >= 2)) || usage
            jobs="$2"
            shift 2
            ;;
        --ndk-archive)
            (($# >= 2)) || usage
            ndk_archive="$2"
            shift 2
            ;;
        --check)
            check_only=1
            shift
            ;;
        *)
            usage
            ;;
    esac
done
[[ -n "$work_dir" ]] || work_dir="$out_dir-work"

lock_field() {
    "$python_bin" "$helper" lock-field "$1" "$2" "$3"
}

# The host: Apple silicon, Xcode tools, and the Python that ADR-0018 names (environment-setup §2.4).
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || die "the build runs on Apple silicon macOS only"
python_bin="$(command -v python3.12 || true)"
[[ -n "$python_bin" ]] || die "python3.12 is not on PATH (environment-setup §2.4)"
for tool in curl shasum git tar make cc; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done
# The pins. Each value is read from the lock, so the lock is the single source.
[[ -f "$lock" ]] || die "missing $lock"
mesa_commit="$(lock_field "$lock" mesa commit)"
mesa_version="$(lock_field "$lock" mesa version)"
mesa_repository="$(lock_field "$lock" mesa repository)"
mesa_flags=()
while IFS= read -r flag; do
    mesa_flags+=("$flag")
done < <(lock_field "$lock" mesa buildFlags)
ninja_commit="$(lock_field "$lock" ninja commit)"
ninja_repository="$(lock_field "$lock" ninja repository)"
bison_url="$(lock_field "$lock" bison url)"
bison_sha256="$(lock_field "$lock" bison sha256)"
flex_url="$(lock_field "$lock" flex url)"
flex_sha256="$(lock_field "$lock" flex sha256)"
flex_version="$(lock_field "$lock" flex version)"
m4_url="$(lock_field "$lock" m4 url)"
m4_sha256="$(lock_field "$lock" m4 sha256)"
m4_version="$(lock_field "$lock" m4 version)"
libdrm_url="$(lock_field "$lock" libdrm url)"
libdrm_sha256="$(lock_field "$lock" libdrm sha256)"
pyyaml_repository="$(lock_field "$lock" pyyaml repository)"
pyyaml_commit="$(lock_field "$lock" pyyaml commit)"
[[ "${#mesa_flags[@]}" -gt 0 ]] || die "the lock has no buildFlags for mesa"
ndk_field="$(lock_field "$lock" ndk version)"
ndk_revision="${ndk_field%% *}"
ndk_name="$(printf '%s' "$ndk_field" | sed -E 's/^[^(]*\(([^)]*)\)$/\1/')"
ndk_sha256="$(lock_field "$lock" ndk sha256)"
ninja_version="$(lock_field "$lock" ninja version)"
bison_version="$(lock_field "$lock" bison version)"
meson_version="$(lock_field "$lock" meson version)"
platform_sdk="$(printf '%s\n' "${mesa_flags[@]}" | sed -n 's/^-Dplatform-sdk-version=//p')"
[[ -n "$ndk_revision" && -n "$ndk_name" && -n "$platform_sdk" ]] || die "the lock does not give the NDK or the platform SDK"
if [[ -n "$ndk_archive" ]]; then
    [[ "$(shasum -a 256 "$ndk_archive" | awk '{print $1}')" == "$ndk_sha256" ]] \
        || die "the NDK archive differs from the lock's SHA-256"
fi

# The NDK. Its source.properties must name the pinned revision.
ndk=""
for candidate in "$repo_root/build/android-sdk/ndk/$ndk_revision" "${ANDROID_NDK_HOME:-}" \
    "$HOME/Library/Android/sdk/ndk/$ndk_revision"; do
    [[ -n "$candidate" && -f "$candidate/source.properties" ]] || continue
    if grep -qxF "Pkg.Revision = $ndk_revision" "$candidate/source.properties"; then
        ndk="$candidate"
        break
    fi
done
[[ -n "$ndk" ]] || die "NDK $ndk_revision ($ndk_name) not found; install it as environment-setup §2.5 describes"
ndk_bin="$ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin"
for tool in "aarch64-linux-android$ndk_api-clang" "aarch64-linux-android$ndk_api-clang++" llvm-ar llvm-ranlib \
    llvm-strip llvm-nm llvm-readelf lld; do
    [[ -x "$ndk_bin/$tool" ]] || die "NDK tool $tool is missing"
done
ndk_clang="$("$ndk_bin/aarch64-linux-android$ndk_api-clang" --version | head -1)"


if ((check_only)); then
    printf 'check: NDK %s (%s) at %s\n' "$ndk_revision" "$ndk_name" "$ndk"
    printf 'check: %s\n' "$ndk_clang"
    printf 'check: python3.12 %s, pinned flex %s, pinned m4 %s\n' "$python_bin" "$flex_version" "$m4_version"
    printf 'check: mesa %s commit %s (%d Meson flags)\n' "$mesa_version" "$mesa_commit" "${#mesa_flags[@]}"
    printf 'check: ninja %s, bison %s, libdrm %s, pyyaml %s\n' "$ninja_version" "$bison_version" \
        "$(lock_field "$lock" libdrm version)" "$(lock_field "$lock" pyyaml version)"
    "$python_bin" "$helper" requirements "$lock" >/dev/null
    printf 'check: passed (no build; the output and work directories were not touched)\n'
    exit 0
fi

# Work area. Sources are fetched by commit or checked by SHA-256, and every step has its own log.
mkdir -p "$work_dir/downloads" "$work_dir/src" "$work_dir/logs" "$work_dir/tools" "$work_dir/build" "$work_dir/cross"
logs="$work_dir/logs"
retry() {
    local attempt=0
    until "$@"; do
        attempt=$((attempt + 1))
        ((attempt < 4)) || return 1
        sleep 5
    done
}

fetch_commit() {
    local name="$1" repository="$2" commit="$3" dest="$4"
    if [[ -d "$dest/.git" && "$(git -C "$dest" rev-parse -q --verify HEAD 2>/dev/null || true)" == "$commit" ]]; then
        return 0
    fi
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$repository"
    retry git -C "$dest" fetch -q --depth 1 origin "$commit" || die "$name: cannot fetch $commit from $repository"
    git -C "$dest" checkout -q --detach FETCH_HEAD
    [[ "$(git -C "$dest" rev-parse HEAD)" == "$commit" ]] || die "$name: the fetched commit differs from the lock"
}

fetch_tarball() {
    local url="$1" sha256="$2" dest="$3" actual=""
    if [[ -f "$dest" ]]; then
        actual="$(shasum -a 256 "$dest" | awk '{print $1}')"
    fi
    if [[ "$actual" != "$sha256" ]]; then
        rm -f "$dest"
        retry curl -fsSL -o "$dest.part" "$url" || die "cannot download $url"
        mv "$dest.part" "$dest"
        actual="$(shasum -a 256 "$dest" | awk '{print $1}')"
    fi
    [[ "$actual" == "$sha256" ]] || die "SHA-256 of $(basename "$dest") differs from the lock"
}

tool_cache_matches() {
    local binary="$1" stamp="$2" source_sha256="$3" expected_version="$4" dependency_sha256="$5"
    local version binary_sha256
    [[ -x "$binary" && -f "$stamp" ]] || return 1
    version="$("$binary" --version 2>/dev/null | head -n 1)" || return 1
    binary_sha256="$(shasum -a 256 "$binary" | awk '{print $1}')" || return 1
    [[ "$version" == "$expected_version" ]] || return 1
    [[ "$(sed -n '1p' "$stamp")" == "archive-sha256=$source_sha256" ]] || return 1
    [[ "$(sed -n '2p' "$stamp")" == "binary-sha256=$binary_sha256" ]] || return 1
    [[ "$(sed -n '3p' "$stamp")" == "version=$expected_version" ]] || return 1
    [[ "$(sed -n '4p' "$stamp")" == "dependency-sha256=$dependency_sha256" ]]
}

write_tool_cache_stamp() {
    local binary="$1" stamp="$2" source_sha256="$3" version="$4" dependency_sha256="$5"
    local binary_sha256 temporary_stamp
    binary_sha256="$(shasum -a 256 "$binary" | awk '{print $1}')"
    temporary_stamp="$stamp.tmp.$$"
    printf 'archive-sha256=%s\nbinary-sha256=%s\nversion=%s\ndependency-sha256=%s\n' \
        "$source_sha256" "$binary_sha256" "$version" "$dependency_sha256" >"$temporary_stamp"
    mv "$temporary_stamp" "$stamp"
}

# 1. Sources. Each pinned checkout stays clean; builds use archive copies.
fetch_commit mesa "$mesa_repository" "$mesa_commit" "$work_dir/src/mesa"
fetch_commit ninja "$ninja_repository" "$ninja_commit" "$work_dir/src/ninja"
fetch_commit pyyaml "$pyyaml_repository" "$pyyaml_commit" "$work_dir/src/pyyaml"
fetch_tarball "$bison_url" "$bison_sha256" "$work_dir/downloads/bison-$bison_version.tar.xz"
fetch_tarball "$flex_url" "$flex_sha256" "$work_dir/downloads/flex-$flex_version.tar.gz"
fetch_tarball "$m4_url" "$m4_sha256" "$work_dir/downloads/m4-$m4_version.tar.xz"
fetch_tarball "$libdrm_url" "$libdrm_sha256" "$work_dir/downloads/libdrm-$(lock_field "$lock" libdrm version).tar.xz"

# 2. GNU m4 and Flex, from the hash-checked release archives.
m4_prefix="$work_dir/tools/m4"
m4_binary="$m4_prefix/bin/m4"
m4_stamp="$m4_prefix/.apkrun-source-pin"
m4_expected_version="m4 (GNU M4) $m4_version"
if ! tool_cache_matches "$m4_binary" "$m4_stamp" "$m4_sha256" "$m4_expected_version" "none"; then
    rm -rf "$work_dir/build/m4-src" "$m4_prefix"
    mkdir -p "$work_dir/build/m4-src"
    tar -xJf "$work_dir/downloads/m4-$m4_version.tar.xz" -C "$work_dir/build/m4-src"
    (cd "$work_dir/build/m4-src/m4-$m4_version" && ./configure --prefix="$m4_prefix" \
        && make -j"$jobs" && make install) >"$logs/m4.log" 2>&1 || die "m4 build failed (see $logs/m4.log)"
    [[ "$("$m4_binary" --version | head -1)" == "$m4_expected_version" ]] || die "m4 version differs from the lock"
    write_tool_cache_stamp "$m4_binary" "$m4_stamp" "$m4_sha256" "$m4_expected_version" "none"
fi
tool_cache_matches "$m4_binary" "$m4_stamp" "$m4_sha256" "$m4_expected_version" "none" \
    || die "m4 cache does not match its locked source and executable hash"
m4_binary_sha256="$(shasum -a 256 "$m4_binary" | awk '{print $1}')" \
    || die "cannot hash the pinned m4 executable"

export M4="$m4_prefix/bin/m4"
flex_prefix="$work_dir/tools/flex"
flex_binary="$flex_prefix/bin/flex"
flex_stamp="$flex_prefix/.apkrun-source-pin"
flex_expected_version="flex $flex_version"
if ! tool_cache_matches "$flex_binary" "$flex_stamp" "$flex_sha256" "$flex_expected_version" "$m4_binary_sha256"; then
    rm -rf "$work_dir/build/flex-src" "$flex_prefix"
    mkdir -p "$work_dir/build/flex-src"
    tar -xzf "$work_dir/downloads/flex-$flex_version.tar.gz" -C "$work_dir/build/flex-src"
    (cd "$work_dir/build/flex-src/flex-$flex_version" \
        && export PATH="$m4_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        && ./configure --prefix="$flex_prefix" && make -j"$jobs" && make install) \
        >"$logs/flex.log" 2>&1 || die "flex build failed (see $logs/flex.log)"
    [[ "$("$flex_binary" --version)" == "$flex_expected_version" ]] || die "flex version differs from the lock"
    write_tool_cache_stamp "$flex_binary" "$flex_stamp" "$flex_sha256" "$flex_expected_version" "$m4_binary_sha256"
fi
tool_cache_matches "$flex_binary" "$flex_stamp" "$flex_sha256" "$flex_expected_version" "$m4_binary_sha256" \
    || die "flex cache does not match its locked source and executable hash"

# 3. Ninja, from the pinned source, bootstrapped by its own script.
ninja_bin="$work_dir/tools/ninja/bin/ninja"
if [[ ! -x "$ninja_bin" ]] || [[ "$("$ninja_bin" --version)" != "$ninja_version" ]]; then
    rm -rf "$work_dir/build/ninja-src" "$work_dir/tools/ninja"
    mkdir -p "$work_dir/build/ninja-src" "$work_dir/tools/ninja/bin"
    git -C "$work_dir/src/ninja" archive --format=tar HEAD | tar -x -C "$work_dir/build/ninja-src"
    (cd "$work_dir/build/ninja-src" && "$python_bin" configure.py --bootstrap) >"$logs/ninja.log" 2>&1 \
        || die "ninja bootstrap failed (see $logs/ninja.log)"
    cp "$work_dir/build/ninja-src/ninja" "$ninja_bin"
    [[ "$("$ninja_bin" --version)" == "$ninja_version" ]] || die "ninja version differs from the lock"
fi

# 4. Bison, from the pinned tarball. Mesa needs a Bison newer than 2.3 (meson.build).
bison_prefix="$work_dir/tools/bison"
if [[ ! -x "$bison_prefix/bin/bison" ]] || ! "$bison_prefix/bin/bison" --version | head -1 | grep -q "$bison_version"; then
    rm -rf "$work_dir/build/bison-src" "$bison_prefix"
    mkdir -p "$work_dir/build/bison-src"
    tar -xJf "$work_dir/downloads/bison-$bison_version.tar.xz" -C "$work_dir/build/bison-src"
    (cd "$work_dir/build/bison-src/bison-$bison_version" && ./configure --prefix="$bison_prefix" \
        && make -j"$jobs" && make install) >"$logs/bison.log" 2>&1 || die "bison build failed (see $logs/bison.log)"
fi

# 5. Python tools: meson, mako, MarkupSafe, and packaging, from hash-checked wheels (no dependency resolution).
venv="$work_dir/venv"
"$python_bin" "$helper" requirements "$lock" >"$work_dir/requirements.txt"
requirements_stamp="$(shasum -a 256 "$work_dir/requirements.txt" | awk '{print $1}')"
if [[ ! -x "$venv/bin/meson" || "$(cat "$venv/.requirements-sha256" 2>/dev/null || true)" != "$requirements_stamp" ]]; then
    rm -rf "$venv"
    "$python_bin" -m venv "$venv"
    "$venv/bin/python" -m pip install --quiet --no-deps --require-hashes -r "$work_dir/requirements.txt" \
        >"$logs/pip.log" 2>&1 || die "pip could not install the pinned wheels (see $logs/pip.log)"
    printf '%s\n' "$requirements_stamp" >"$venv/.requirements-sha256"
fi
[[ "$("$venv/bin/meson" --version)" == "$meson_version" ]] || die "meson version differs from the lock"

# 6. The Mesa tree: a clean archive of the pinned commit, with the pinned libdrm tarball in the wrap cache.
mesa_src="$work_dir/mesa-src"
rm -rf "$mesa_src"
mkdir -p "$mesa_src"
git -C "$work_dir/src/mesa" archive --format=tar HEAD | tar -x -C "$mesa_src"
mkdir -p "$mesa_src/subprojects/packagecache"
cp "$work_dir/downloads/libdrm-$(lock_field "$lock" libdrm version).tar.xz" "$mesa_src/subprojects/packagecache/libdrm-$(lock_field "$lock" libdrm version).tar.xz"

# 7. The cross file. Clang is the NDK's API $ndk_api clang; lld links; the C++ runtime is static.
cross="$work_dir/cross/android-aarch64.ini"
cat >"$cross" <<EOF
[constants]
ndk_bin = '$ndk_bin'

[binaries]
c = ndk_bin / 'aarch64-linux-android$ndk_api-clang'
cpp = [ndk_bin / 'aarch64-linux-android$ndk_api-clang++', '-static-libstdc++']
ar = ndk_bin / 'llvm-ar'
ranlib = ndk_bin / 'llvm-ranlib'
strip = ndk_bin / 'llvm-strip'
nm = ndk_bin / 'llvm-nm'
c_ld = 'lld'
cpp_ld = 'lld'
# No pkg-config for the target: dependencies are found by the NDK sysroot or by the wrap of libdrm.
pkg-config = 'pkg-config-disabled'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF

# The build PATH holds the pinned tools and the host's own Xcode tools, and nothing from Homebrew.
build_path="$flex_prefix/bin:$m4_prefix/bin:$work_dir/tools/ninja/bin:$venv/bin:$bison_prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
build_dir="$work_dir/build-mesa"
rm -rf "$build_dir"
env PATH="$build_path" PYTHONPATH="$work_dir/src/pyyaml/lib" \
    meson setup "$build_dir" "$mesa_src" --cross-file "$cross" "${mesa_flags[@]}" \
    >"$logs/meson-setup.log" 2>&1 || die "meson setup failed (see $logs/meson-setup.log)"

# 8. Build the four shipped libraries (and only what they need).
env PATH="$build_path" PYTHONPATH="$work_dir/src/pyyaml/lib" \
    ninja -C "$build_dir" -j "$jobs" "${ninja_targets[@]}" >"$logs/ninja-build.log" 2>&1 \
    || die "ninja failed (see $logs/ninja-build.log)"

# 9. Install into a stage dir. Meson removes the build-tree RUNPATH on install, and --skip-subprojects keeps the
#    libdrm libraries of the wrap out of the stage.
stage="$work_dir/stage"
rm -rf "$stage"
env PATH="$build_path" PYTHONPATH="$work_dir/src/pyyaml/lib" \
    meson install -C "$build_dir" --destdir "$stage" --skip-subprojects --no-rebuild --strip \
    >"$logs/meson-install.log" 2>&1 || die "meson install failed (see $logs/meson-install.log)"

# 10. The output: the four libraries and the manifest, verified before they replace the previous output.
tmp_out="$out_dir.tmp.$$"
rm -rf "$tmp_out"
mkdir -p "$tmp_out/vendor/lib64"
for library in "${shipped_libraries[@]}"; do
    cp "$stage/vendor/lib64/$library" "$tmp_out/vendor/lib64/$library"
done
libdrm_version="$(lock_field "$lock" libdrm version)"
pyyaml_version="$(lock_field "$lock" pyyaml version)"
"$python_bin" "$helper" manifest "$tmp_out" --lock "$lock" --readelf "$ndk_bin/llvm-readelf" --nm "$ndk_bin/llvm-nm" \
    --tool "ndk=$ndk_revision ($ndk_name)" \
    --tool "ndkClang=$ndk_clang" \
    --tool "ndkApi=$ndk_api" \
    --tool "platformSdkVersion=$platform_sdk" \
    --tool "ndkArchiveSha256=$ndk_sha256" \
    --tool "mako=$(lock_field "$lock" mako version)" \
    --tool "markupsafe=$(lock_field "$lock" markupsafe version)" \
    --tool "packaging=$(lock_field "$lock" packaging version)" \
    --tool "meson=$("$venv/bin/meson" --version)" \
    --tool "ninja=$("$ninja_bin" --version)" \
    --tool "bison=$bison_version" \
    --tool "flex=$("$flex_prefix/bin/flex" --version | awk '{print $2}')" \
    --tool "m4=$("$m4_prefix/bin/m4" --version | head -1)" \
    --tool "python=$("$python_bin" --version 2>&1 | awk '{print $2}')" \
    --tool "pyyaml=$pyyaml_version ($pyyaml_commit)" \
    --tool "libdrm=$libdrm_version" \
    --tool "host=$(uname -s) $(uname -m) $(sw_vers -productVersion 2>/dev/null || printf 'unknown')" \
    || die "cannot write the manifest"
"$python_bin" "$helper" verify "$tmp_out" --lock "$lock" --readelf "$ndk_bin/llvm-readelf" --nm "$ndk_bin/llvm-nm" \
    || die "the output failed verification; $tmp_out is kept for inspection"

rm -rf "$out_dir"
mkdir -p "$(dirname "$out_dir")"
mv "$tmp_out" "$out_dir"
printf 'build-mesa-android: wrote %s\n' "$out_dir"
