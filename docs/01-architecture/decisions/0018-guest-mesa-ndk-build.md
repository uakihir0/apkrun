# 0018. Guest Mesa (EGL, GLES, gallium virgl) built with the NDK as a standalone APKRun cross-build

- Status: Accepted
- Date: 2026-10-10
- Approval: the project owner approved this route in the session of 2026-10-10, instead of the AOSP Soong build (IR-442 and IR-443 on `task/099-mesa-virgl-guest-image`).
- Related: #099 (Mesa-enabled VirGL guest image), #022, #021, ADR-0003, ADR-0004, R-02; the feasibility record IR-440 to IR-451 and the receipt of build 16373615 on `task/099-mesa-virgl-guest-image`

## Context

The VirGL path of ADR-0004 needs a guest Mesa: the EGL and GLES libraries that Android loads with `ro.hardware.egl=mesa`, and the gallium `virgl` driver under them. The current guest image has no such userspace. Build 16373615 has `libEGL_emulation.so` and `libGLESv2_emulation.so` in `vendor_a`, ANGLE in `system_a`, and no Mesa EGL, GLES, gallium, or gbm library (the receipt `Images/reference/16373615/mesa-payload-receipt.txt` §3 and §6, on `task/099-mesa-virgl-guest-image`).

The pinned AOSP `external/mesa3d` tree has no module for EGL, GLES, or the virgl driver. Its 90 `Android.bp` files define the platform stubs, two Vulkan ICDs, and the gallium-free helpers only (IR-440 on `task/099-mesa-virgl-guest-image`). The AOSP build of that tree needs a Linux x86-64 builder with 400 GB of disk, and this Mac has neither (IR-442 on `task/099-mesa-virgl-guest-image`).

ADR-0004 says that Cuttlefish's `drm_virgl` mode "provides the matching guest side". The receipt shows that the kernel side is provided (the virtio-gpu DRM driver), and the userspace side is not. This ADR supplies the userspace side. ADR-0004 stays unchanged, because it is accepted.

The project owner approved the NDK route in this session. Mesa is built on this Mac with the Android NDK r28c as a standalone cross-build, outside the AOSP Soong tree.

## Decision

1. APKRun builds the guest Mesa itself. The source is Mesa **26.1.8** (`https://gitlab.freedesktop.org/mesa/mesa.git`, tag `mesa-26.1.8`, commit `0fadfea4f394211946f308458f614839ef253ee8`). The build is Meson and Ninja, with the Android NDK **r28c** (`ndk;28.2.13676358`) and its clang 19.0.1. The script is `scripts/guest/build-mesa-android.sh`, and the build output is git-ignored under `ThirdParty/out/mesa-android/`.
2. The target is Android ARM64 with bionic. The NDK r28c clang targets `aarch64-linux-android35`, the highest API level its sysroot provides. Mesa's `platform-sdk-version` is 37, the platform of the guest image (Android 17), so that Mesa's platform gates match the image. The symbols that the libraries import from the guest are listed in the test. Whether the guest provides them is not verified until the VM check.
3. **Shipped in the image** (`ships: image`, added by APKRun):
   - `libEGL_mesa.so` (EGL, the `android` and `surfaceless` platforms),
   - `libGLESv2_mesa.so` and `libGLESv1_CM_mesa.so` (the GLES 2.0 and 1.1 entry points),
   - `libgallium_dri.so` (the gallium frontend, the `virgl` driver, and the shared GLAPI, which Meson builds into this library).
   The shipped files are stripped with `meson install --strip` (IR-494). The unstripped build stays in the work area.
   The EGL and GLES names come from `-Degl-lib-suffix=_mesa` and `-Dgles-lib-suffix=_mesa`, because the Android loader opens `libEGL_<name>.so` and `libGLESv2_<name>.so`.
4. **Not shipped:**
   - `libdrm.so`, which the guest's vendor partition already provides (the receipt, §5). The build links against libdrm 2.4.123 from Mesa's wrap, and the SONAME is `libdrm.so`, so the NEEDED entries match the guest. The other libdrm driver libraries (amdgpu, radeon, nouveau, and the rest) are not shipped.
   - The stub libraries `libcutils.so`, `libhardware.so`, `liblog.so`, `libnativewindow.so`, and `libsync.so`, which `-Dandroid-stub=true` builds for linking only. At run time the guest's libraries of the same SONAMEs are meant to be loaded instead (not verified until the VM check, IR-488).
   - Headers and pkg-config files, which Meson installs by default.
   - Everything not selected by the flags below: Vulkan (`-Dvulkan-drivers=`), GLX, GBM and gralloc (the image's minigbm does that), llvmpipe and LLVM, zstd, xmlconfig and expat, Perfetto, the video APIs, and the other gallium drivers.
5. **Build flags** (exact values are in the manifest): `--buildtype=release --wrap-mode=nodownload --prefix=/vendor --libdir=lib64 -Dplatforms=android -Dplatform-sdk-version=37 -Dandroid-stub=true -Dandroid-libbacktrace=disabled -Degl=enabled -Degl-lib-suffix=_mesa -Dgles-lib-suffix=_mesa -Dglvnd=disabled -Dglx=disabled -Dgbm=disabled -Dopengl=true -Dgles1=enabled -Dgles2=enabled -Dgallium-drivers=virgl -Dvulkan-drivers= -Dzstd=disabled -Dxmlconfig=disabled -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dgallium-va=disabled -Dperfetto=false -Dbuild-tests=false -Ddri-drivers-path=/vendor/lib64/egl -Dallow-fallback-for=libdrm`. The first flags follow the Mesa Android documentation (`docs/android.rst`): the `android` platform, the platform SDK version, the android stub, and EGL. The C++ runtime is linked statically (`-static-libstdc++` in the cross file), because the guest has `libc++.so` but not `libc++_shared.so`.
6. **Pinned build tools** (all in `ThirdParty/ThirdParty.lock.json`, group `guest-mesa`):
   - NDK r28c, `ndk;28.2.13676358`, installed at `~/Library/Android/sdk/ndk/28.2.13676358` (outside the repository and outside `build/android-sdk`), checked by `source.properties`.
   - Ninja 1.13.2 from the upstream source (`3441b633…`), built with its bootstrap script.
   - GNU Bison 3.8.2 from the GNU tarball (SHA-256 `9bba0214…`), signature checked against the GNU keyring. Mesa's GLSL front end needs Bison newer than 2.3, and the Bison that macOS ships is 2.3.
   - Meson 1.12.1, mako 1.4.3, MarkupSafe 3.0.4 (CPython 3.12 macOS arm64 wheel), packaging 26.3, and PyYAML 6.0.3 (the existing `pyyaml` entry, reused by the same commit). The Python packages come from pinned PyPI wheels, checked with `pip --require-hashes`, and run under Python 3.12 (environment-setup §2.4).
   - libdrm 2.4.123 (the tarball named in Mesa's `subprojects/libdrm.wrap`, SHA-256 `a2b98567…`).
   - Flex 2.6.4 and GNU m4 1.4.6 from macOS, recorded in the manifest but not pinned (IR-485).
7. **Licences and the app list.** The Mesa components have `ships: image` and were added by APKRun, so the app list applies (legal-and-licensing §4.1). The licence identities of the sources compiled into the four libraries (859 files, found by walking the Ninja link graph) are:
   - MIT, the Mesa default for files without a header, and the SPDX `MIT` tag, in the great majority of files;
   - BSD-2-Clause (`src/gallium/auxiliary/postprocess/pp_mlaa.c`) and BSD-3-Clause (`src/util/softfloat.c`);
   - BSL-1.0 (`src/c11/impl/time.c`);
   - HPND, the "sell this software" notice (`src/loader/loader_dri_helper.c`). **HPND is not on the app list.**
   - CC0-1.0 OR Apache-2.0 (BLAKE3 1.8.2, `src/util/blake3/`, whose tree has no licence file; the identity comes from the upstream project);
   - GPL-3.0-or-later with the Bison skeleton exception, in the three Bison-generated parsers (`glsl_parser.cpp`, `glcpp-parse.c`, `program_parse.tab.c`). **Neither the exception nor the generated-code notice is on the app list.**
   - Apache-2.0 WITH LLVM-exception: the NDK's libc++abi and libunwind code, which `-static-libstdc++` links into `libgallium_dri.so` (IR-493).
   The lock entry records the expression, `MIT AND BSD-2-Clause AND BSD-3-Clause AND BSL-1.0 AND HPND AND (CC0-1.0 OR Apache-2.0) AND GPL-3.0-or-later WITH Bison-exception-2.2 AND Apache-2.0 WITH LLVM-exception`. The policy result is a failure, and the image must not ship until the maintainer decides (IR-483). The Mesa licence texts are copied under `ThirdParty/licenses/mesa/`.
   The tools (NDK, Ninja, Bison, Meson, mako, MarkupSafe, packaging, PyYAML, libdrm) are `ships: tooling`. They are not in the image, and their licences are on the tooling list (§4.4), except the NDK, whose licence is the Android SDK licence (IR-486).
8. **Provenance.** Every build writes `ThirdParty/out/mesa-android/manifest.json`. It records the Mesa commit and version, the lock entries used, the NDK revision and clang version, the Meson, Ninja, and Bison versions, the host Python and tool versions, the full flag list, and for each shipped file its size, SHA-256, `e_machine`, `DT_NEEDED`, `DT_SONAME`, and load alignment. `scripts/tests/test_guest_mesa_build.py` checks the manifest and the ELF properties of the output.
9. **Image layout.** The Android loader takes `libEGL_mesa.so` and `libGLESv2_mesa.so` from `vendor/lib64/egl/`. `libgallium_dri.so` is a `DT_NEEDED` of the EGL and GLES libraries, so the linker must find it from the vendor namespace. The placement is decided in the image integration step, and the VM check verifies it. This ADR does not decide it (IR-489).

## Alternatives considered

| Alternative | Why not |
|---|---|
| AOSP Soong build of `external/mesa3d` | The pinned tree has no EGL, GLES, or virgl module (IR-440), and the build needs a Linux x86-64 builder with 400 GB of disk. Not possible on this host (IR-442). Both are on `task/099-mesa-virgl-guest-image`. |
| Mesa 26.2.4, the newest release | The AOSP android-17 snapshot is the 26.1 series (`26.1.0-devel`). The 26.1 point release keeps the Android platform code the same as the AOSP tree. The newer series can follow in a later pin. IR-480. |
| Mesa's llvmpipe or lavapipe (software GL) | The product path is VirGL (ADR-0004). Software rendering stays a debug fallback (`guestSwiftshader`). |
| Using the image's ANGLE (`libEGL_angle.so`) in the guest | `ro.hardware.egl=mesa` does not select the system ANGLE libraries, and ADR-0004 chose VirGL as the guest path (`graphics.md` §5.3). |
| Installing the NDK with `sdkmanager` | No JDK is installed on this host, and `sdkmanager` needs one. The archive was downloaded from the URL that the SDK manifest lists, and its SHA-1 was checked against that manifest (IR-481). |

## Consequences

- The guest gets Mesa's EGL and GLES 2.0 and 1.1 entry points and the `virgl` driver, so `eglInitialize` can run on the VirGL display. Acceptance of #099 needs the VM check, which is not part of this ADR.
- The guest must provide the libraries that the shipped Mesa imports. These are `libcutils.so`, `libhardware.so`, `liblog.so`, `libnativewindow.so`, `libsync.so`, `libdrm.so`, `libz.so`, `libm.so`, `libdl.so`, and `libc.so`, and 37 Mesa-used symbols of the stub libraries and libdrm (the symbol list is in `scripts/tests/test_guest_mesa_build.py`). `libz.so` is not in the receipt's inventory, so it is an open check (IR-487).
- Mesa is a third-party component with runtime impact, so it is in the lock with `ships: image`, its licence texts, and this ADR. Security updates come from the upstream check (build-system §6.7), and a Mesa bump is a new pin with a new receipt.
- The app list is not met for HPND and for the Bison-generated code (IR-483). The image release is blocked until the maintainer decides.
- ADR-0004's Context sentence about Cuttlefish's `drm_virgl` mode is correct for the kernel side only. The userspace side is this ADR's.
- The build is reproducible from the lock. The script fetches the sources by commit or checks them by SHA-256 before the build. Meson runs with `--wrap-mode=nodownload`, so it does not fetch anything during the build. Neither the AOSP tree nor the Soong toolchain is needed.

## Verification

- Host build on this Mac with NDK r28c and the pins above. The four libraries are AArch64 ELF64 with 16 KB load alignment. Their `DT_NEEDED` entries and exports are checked by `scripts/tests/test_guest_mesa_build.py`.
- `eglInitialize` on the VirGL display, the GLES renderer string, and the symbol contract all need the guest. They are recorded as open in #099 and are not claimed by this ADR.
