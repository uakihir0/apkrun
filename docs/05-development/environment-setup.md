# Environment Setup

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [build-system.md](build-system.md), [workflow.md](workflow.md), [coding-conventions.md](coding-conventions.md), [../01-architecture/modules.md](../01-architecture/modules.md), [../04-plan/test-strategy.md](../04-plan/test-strategy.md), [../04-plan/risks.md](../04-plan/risks.md) R-14 |
| Tasks | #001 (bootstrap), #008 (fetch), #035 (AOSP builder), #062 (CI), #064 (reference host), #070 (perf harness) |

This guide lists every machine and tool needed to build and test APKRun, and how to check that a machine is ready. Versions named here are the pins. When a pin moves, change it here and in the file that enforces it (§2.9) in the same pull request.

---

## 1. Machines and roles

| Machine | Needed for | Minimum | Section |
|---|---|---|---|
| Developer Mac | all host code, Guest Gradle and Rust builds, image tooling, T0–T2 tests | Apple Silicon (M1 or later), macOS 27, 16 GB RAM, 150 GiB free disk | §2 |
| Developer Mac, M3 or later | the Cuttlefish reference host as a nested-virtualization Linux VM (#064) | M3 or later, 24 GB RAM recommended | §3.3 |
| Linux x86_64 AOSP builder | building the APKRun AOSP product (#035); as CI runner `apkrun-aosp`: nightly `userdebug` builds | ≥ 64 GB RAM, ≥ 400 GB disk | §5, §6.1 |
| Image build machine | `user` release images, signed with the offline AOSP release keys; a maintainer-controlled AOSP builder that is never a CI runner | as the AOSP builder | §5.6 |
| GitHub-hosted macOS runner (`xcode-27`) | repository static checks, builds, and Swift T0 tests on pull requests and pushes to `main`; one fresh VM per job | Apple Silicon M1, 3 cores, 7 GB RAM, 14 GB SSD; Public Preview since 10 September 2026 | §6 |
| CI Macs (`apkrun-ci`) | self-hosted runners for trusted default-branch jobs and hardware-specific checks | bare-metal Apple Silicon, macOS 27 | §6 |
| Lab Macs (`apkrun-lab`) | self-hosted runners for T2 suites, nightly T3, performance for information, nightly notarization | bare-metal Apple Silicon (M1 or later), macOS 27; at least one with M3 or later | §6 |
| Reference Mac (`apkrun-reference`) | the lab Mac whose numbers count: gate checks, NFR numbers, the release smoke matrix, manual checklists | the reference Mac of OQ-02 (M1, 16 GB), public macOS release only | §6 |
| Seed lab Mac (`apkrun-seed`) | a lab Mac that installs every macOS 27.x beta and release and runs the full T2 set and gate checks (R-16) | as a lab Mac | §6 |

macOS cannot build AOSP ([../01-architecture/decisions/0003-cuttlefish-base-image.md](../01-architecture/decisions/0003-cuttlefish-base-image.md)). Intel Macs are not supported at all (Virtualization.framework arm64 guests need Apple Silicon).

---

## 2. Developer Mac

### 2.1 Hardware and OS

- Apple Silicon, macOS 27.0 or later. The deployment target of every host target is macOS 27.0 ([build-system.md](build-system.md) §2).
- 150 GiB free disk is a working minimum. The large items are the ANGLE checkout and build (about 11 GB, [../02-design/graphics.md](../02-design/graphics.md) §5), Cuttlefish downloads and bundles under `Images/work/` (about 10 GB per build ID), the runtime image and userdata under `APKRUN_HOME`, and Xcode DerivedData.
- An M3 or later Mac is needed only for the nested-virtualization reference host (§3.3). Everything else works on M1.

### 2.2 Xcode and command line tools

| Tool | Pin | Install |
|---|---|---|
| Xcode | 27.0, recorded in `.xcode-version` at the repository root | Mac App Store or developer.apple.com |
| Command line tools | the ones inside the pinned Xcode | `sudo xcode-select -s /Applications/Xcode.app` |
| Metal toolchain | the component for the pinned Xcode | `xcodebuild -downloadComponent MetalToolchain` |

```bash
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
xcrun swift --version        # Swift 6.2 or later
```

The Metal toolchain is needed to compile the GraphicsCore shaders and the ANGLE Metal backend. Distribution wrappers (#088) also need the command line tools on the creator's Mac ([../02-design/wrapper.md](../02-design/wrapper.md) §11), but that is a user requirement, not a developer one.

### 2.3 Homebrew

Install Homebrew from brew.sh, then install the packages in `scripts/Brewfile`:

```bash
brew bundle --file scripts/Brewfile
```

| Package | Why |
|---|---|
| `python@3.12` | image tooling (§2.4), release scripts, `compare_boot.py` |
| `meson`, `ninja`, `pkg-config` | virglrenderer and libepoxy builds ([build-system.md](build-system.md) §6) |

Homebrew versions float. Tools whose output is committed (protoc, protoc-gen-swift, buf, XcodeGen) are therefore not taken from Homebrew but pinned and installed by `scripts/bootstrap` (§2.7). ANGLE uses its own pinned `depot_tools`, fetched by `ThirdParty/build/build-angle.sh`.
The graphics build also uses PyYAML 6.0.3 from its pinned source entry in `ThirdParty/ThirdParty.lock.json`; it does not require a separate Python package installation.

### 2.4 Python 3.12

The image tooling in `Images/tools/` is a Python 3.12 package (`apkrun_image`). Its dependencies (lz4, cryptography, jsonschema, and the `test` extra with pytest and ruff) are pinned in `Images/tools/pyproject.toml` ([../02-design/android-image.md](../02-design/android-image.md) §1.2).

```bash
python3.12 -m venv Images/tools/.venv
source Images/tools/.venv/bin/activate
pip install -e 'Images/tools[test]'
python3 -m apkrun_image --help
pytest Images/tools/tests
```

- `Images/tools/.venv/` is git-ignored. `scripts/bootstrap` creates it if it is missing.
- Every other Python script in the repository (`scripts/release/*.py`, `scripts/dev/update-server.py`) runs in the same venv and uses only the standard library plus the packages above.

### 2.5 JDK, Gradle, and the Android SDK

| Tool | Pin | Notes |
|---|---|---|
| JDK | Temurin 17 | `export JAVA_HOME="$(/usr/libexec/java_home -v 17)"`. Kotlin compiles to JVM target 17 ([../02-design/guest-components.md](../02-design/guest-components.md) §2). |
| Gradle | the wrapper at the repository root, `gradle/wrapper/` (with `distributionSha256Sum`), invoked as `./gradlew -p Guest` | Never install Gradle globally. `Tests/Fixtures/AndroidApps/` has its own wrapper with the same version. |
| AGP, Kotlin, coroutines, protobuf-javalite, the ktfmt Gradle plugin | `Guest/gradle/libs.versions.toml` | chosen in #033 ([coding-conventions.md](coding-conventions.md) §2) |
| Android SDK platform | `platforms;android-37.0` (the SDK publishes API 37 under this name) | compileSdk and targetSdk 37 |
| Build tools | `build-tools;37.0.0` | `apksigner`, `zipalign`; `apksigner` is also the reference for `scripts/dev/verify-corpus.sh` |
| Platform tools | `platform-tools` (latest) | `adb`, used by `ADBForwardGuestTransport` ([../02-design/guest-protocol.md](../02-design/guest-protocol.md) §13.2) and by the M1–M4 ADB control channel |
| NDK | `ndk;28.2.13676358` (r28c) | the NDK pin for `apkrun_vsockd` and native fixtures (§2.6). r28 is the first NDK that links 16 KB-aligned ELF by default, which the 16K-page product needs. |

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager --sdk_root="$ANDROID_HOME" --install \
  "platform-tools" "platforms;android-37.0" "build-tools;37.0.0" "ndk;28.2.13676358"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
```

`Guest/local.properties` and `Tests/Fixtures/AndroidApps/local.properties` (git-ignored) are written by `scripts/bootstrap` with `sdk.dir=$ANDROID_HOME`.

### 2.6 Rust and cargo-ndk

| Tool | Pin | Where |
|---|---|---|
| Rust | 1.88.0, with `rustfmt` and `clippy`, target `aarch64-linux-android` | `Guest/vsockd/rust-toolchain.toml` |
| cargo-ndk | 3.5.4 | `scripts/tool-versions.env` (`CARGO_NDK_VERSION`) |

```bash
rustup show                     # inside Guest/vsockd, installs the pinned toolchain and target
cargo install cargo-ndk --version 3.5.4 --locked
cd Guest/vsockd && cargo ndk -t arm64-v8a build --release
```

The product build compiles the same crate with the Rust prebuilt of the pinned AOSP tree (`prebuilts/rust/`, [build-system.md](build-system.md) §9). The host pin must not be newer than that prebuilt, so code that builds with cargo also builds with Soong. #035 records the AOSP prebuilt version and moves the host pin to match it.

### 2.7 Code generation tools

| Tool | Pin | Source |
|---|---|---|
| protoc | 31.1 | `scripts/tool-versions.env` (`PROTOC_VERSION`); the Gradle protobuf plugin uses `com.google.protobuf:protoc` of the same release |
| protoc-gen-swift | the swift-protobuf version in `Package.resolved` | built from the resolved dependency: `swift build -c release --product protoc-gen-swift` |
| buf | 1.55.1 | `scripts/tool-versions.env` (`BUF_VERSION`) |
| XcodeGen | 2.44.1 | `scripts/tool-versions.env` (`XCODEGEN_VERSION`) |

`scripts/bootstrap` downloads protoc, buf, and XcodeGen release archives of exactly these versions into `build/tools/<name>-<version>/`, checks their SHA-256 against `scripts/tool-versions.env`, and builds protoc-gen-swift. `scripts/generate-protos.sh` and `scripts/generate-project.sh` use only those copies, never whatever is on `PATH`. The protobuf-javalite version in `libs.versions.toml` uses the same protobuf release as protoc (4.31.1 for protoc 31.1).

### 2.8 Shell environment

| Variable | Value | Used by |
|---|---|---|
| `JAVA_HOME` | JDK 17 (§2.5) | Gradle |
| `ANDROID_HOME`, `ANDROID_NDK_HOME` | §2.5 | Gradle, cargo-ndk, `adb` |
| `APKRUN_ANDROID_BUILD_API_KEY` | §3.1 | `apkrun_image fetch` |
| `APKRUN_HOME` | unset (Debug builds default to `~/Library/Application Support/APKRun-Dev/`, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6) | host tools, tests |
| `APKRUN_TEST_LINUX_DIR` | unset (default `/tmp/apkrun-test-linux/`) | Debug CLI, T2 Linux guest tests (§4), and the opt-in VM configuration T1 probe |
| `APKRUN_TEST_DEVELOPMENT_TEAM` | Apple Development team ID for the lab test host | signed T2 and G1 VM tests |
| `APKRUN_TEST_CODE_SIGN_IDENTITY` | SHA-1 fingerprint of that team's Apple Development certificate | signed T2 and G1 VM tests |
| `APKRUN_AOSP_BUILDER` | `user@host` of the Linux builder | `scripts/aosp/remote-build.sh` (§5.5) |
| `APKRUN_CI` | `1` on CI runners only | turns "skip with a message" into a failure (§6.4) |

Put the exports in `~/.zprofile`. Nothing in this table is committed to the repository.

### 2.9 Where the pins live

| Pin | File |
|---|---|
| Xcode | `.xcode-version` |
| Swift packages | swift-protobuf and swift-argument-parser: exact versions in `Package.swift`, resolved in `Package.resolved`. Sparkle: exact version in `project.yml` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2) |
| protoc, buf, XcodeGen, cargo-ndk, and their hashes | `scripts/tool-versions.env` |
| Gradle, AGP, Kotlin, Android libraries | `gradle/wrapper/gradle-wrapper.properties` (repository root), `Guest/gradle/libs.versions.toml` |
| Android SDK, build tools, NDK | this document and `scripts/bootstrap` |
| Rust | `Guest/vsockd/rust-toolchain.toml`, `Guest/vsockd/Cargo.lock` |
| Python packages | `Images/tools/pyproject.toml` |
| Third-party native code, the test Linux kernel and rootfs, vendored mkbootimg and avbtool | `ThirdParty/ThirdParty.lock.json` ([build-system.md](build-system.md) §6) |
| Cuttlefish build | `Images/manifests/<buildId>/android-image.json` |
| AOSP source | `Guest/product/manifest/pinned.xml` |

---

## 3. Android artifacts

### 3.1 Android Build API key

`apkrun_image fetch` uses the Android Build API v4 ([../02-design/android-image.md](../02-design/android-image.md) §2.2). The API key is the public key that is embedded in the open-source `cvd` tool. It is not committed.

1. Clone `https://github.com/google/android-cuttlefish`.
2. Find the key file: `git ls-files | grep android_build_api_key.cc`.
3. Copy the key string from that file.
4. Store it in the login Keychain and export it from the Keychain:

```bash
security add-generic-password -a "$USER" -s apkrun-android-build-api-key -w '<key>'
# in ~/.zprofile
export APKRUN_ANDROID_BUILD_API_KEY="$(security find-generic-password -a "$USER" -s apkrun-android-build-api-key -w)"
```

On CI the same value is the repository secret `APKRUN_ANDROID_BUILD_API_KEY`. Do not paste the key into issues, pull requests, or logs.

### 3.2 Fetching the pinned Cuttlefish build

```bash
source Images/tools/.venv/bin/activate
python3 -m apkrun_image fetch \
  --branch aosp-android-latest-release \
  --target aosp_cf_arm64_only_phone-userdebug \
  --build 16373615 \
  --artifact 'aosp_cf_arm64_only_phone-img-*.zip' \
  --out Images/work/16373615/download/
python3 scripts/inventory-cuttlefish.py Images/work/16373615/download/
```

- Downloads resume. `fetch.json` records the build ID, target, caller-asserted branch, and each artifact's name, size, and SHA-256. Inventorying the download directory verifies and scans the archive listed there, then carries that provenance into `inventory.json`. Existing unverified files are preserved; move one aside or run `fetch` without an API key to record it as a manual download.
- Fallback without a key: download `aosp_cf_arm64_only_phone-img-16373615.zip` from the ci.android.com web UI into the same directory, then run the same command. `fetch` then only verifies ([../02-design/android-image.md](../02-design/android-image.md) §2.2).
- The prebuilt image is for development only (M1–M4). Do not publish it or bundles made from it ([legal-and-licensing.md](legal-and-licensing.md) §2).
- Build a development bundle and install it with the commands in [build-system.md](build-system.md) §10.

### 3.3 Cuttlefish reference host (#064)

The reference boot capture ([../02-design/android-image.md](../02-design/android-image.md) §8) needs a Linux machine that runs real Cuttlefish. Preferred: an arm64 Linux VM with nested virtualization on an M3 or later Mac.

| Step | Detail |
|---|---|
| VM | arm64 Debian 12 or Ubuntu 24.04 in any VZ-based VM tool that sets `VZGenericPlatformConfiguration.isNestedVirtualizationEnabled` (check `VZGenericPlatformConfiguration.isNestedVirtualizationSupported` first). 8 vCPUs, 16 GB RAM, 120 GB disk. |
| KVM | `ls -l /dev/kvm` must exist inside the VM. Add the user to the `kvm`, `cvdnetwork`, and `render` groups. |
| Host tools | install `cuttlefish-base` and `cuttlefish-user` from the android-cuttlefish arm64 packages, then reboot the VM; `timeout` from GNU coreutils must be on `PATH` |
| Artifacts | the same build as §3.2, plus `cvd-host_package.tar.gz` of that build |
| Capture | `Images/tools/reference/capture.sh <profile>` for `default`, `target`, `swiftshader` ([../02-design/android-image.md](../02-design/android-image.md) §8.2) |
| Output | copy the capture to `Images/reference/<buildId>/<profile>/` on the Mac and commit it |

On the tested Ubuntu 24.04.4 arm64 Lima VM, the host has no `/dev/dri`.
Install `libgles2-mesa-dev` and `libvirglrenderer1`. For the `target`
`drm_virgl` profile, `capture.sh` sets `EGL_PLATFORM=surfaceless` for both CVD
commands and records it in `host.json`; it clears inherited `EGL_PLATFORM`
for all other profile and GPU-mode combinations. With these
packages installed and the capture script selecting that variable,
Cuttlefish 1.57.0 initialized Mesa's off-screen EGL; `ldconfig` reported
`libEGL.so`, `libGLESv2.so`, and
`libvirglrenderer.so.1` visible. Cuttlefish passed its host GLES prerequisite
check with Mesa llvmpipe. `launcher.log` records the requested virglrenderer
backend. A later capture recorded
`Failed to create virtio gpu worker thread: invalid rutabaga build parameters`
before guest kernel output. The pinned Cuttlefish crosvm build disables
`default_features` and does not enable its `virgl_renderer` feature, so the
host library and EGL/GLES prerequisite checks alone cannot make this package
run `drm_virgl`. Use a Cuttlefish host package built from the pinned source
with `virgl_renderer` enabled before expecting a target-profile boot; see
[M01](../04-plan/issues/M01-android-bring-up.md) #064 and
[IR-171](../04-plan/implementation-review.md#ir-171-diagnose-crosvm-panic-output).
`capture.sh target` checks the expected crosvm ELF before starting
Cuttlefish. The launch command can be a wrapper; for a launcher that executes a
different ELF, set `APKRUN_CROSVM_OBSERVER_EXECUTABLE` to the absolute path of
the executable used after the launcher's `exec`. For a direct crosvm override,
`APKRUN_CROSVM_OBSERVER_EXECUTABLE` defaults to `APKRUN_CROSVM_BINARY`. The
exact Build ID identified in IR-171 is refused. Other identified builds are
allowed for diagnosis, but their Build ID and hash are recorded as uncertified
in `host.json`, `MISSING.txt` marks the capture diagnostic-only, and the capture
cannot become a comparable profile. The expected ELF is hashed again before
both CVD create and start, and each matching running crosvm process is checked
against that hash before its identity is recorded.
`capture.sh` disables the arm64 vhost-user GPU backend for each profile and
verifies the selected config.

The feature-enabled diagnostic crosvm gets past the missing-build-feature
panic, but this alone does not establish guest rendering. In the
1200-second `drm_virgl` target capture recorded in
[IR-172](../04-plan/implementation-review.md#ir-172-diagnose-guest-egl-selection),
the guest kernel initialized `virtio_gpu` with
`+virgl`, and Android started init and requested zygote. The guest selected
`ro.hardware.egl=mesa`. The pinned Cuttlefish revision sets
`androidboot.hardware.egl=mesa` in
`CrosvmManager::ConfigureGraphics()` for `GpuMode::DrmVirgl`, and the
captured internal bootconfig matches that source. The inspected
`/vendor/lib64/egl` directory contained only emulator EGL/GLES libraries,
and `/system/lib64/egl` was absent.
`libEGL` reported that it could not load the Mesa driver and could not find an
OpenGL ES implementation. SurfaceFlinger repeatedly aborted during EGL/Skia
GL renderer creation. The sampled `sys.boot_completed` query returned an
empty value, and no `sys.boot_completed=1` value was observed or accepted.
Keep the capture incomplete and diagnostic-only. The documented
`guest_swiftshader` target fallback was run while guest image-source
investigation remained open; it also timed out before Android boot completed.
Its `drm_virgl` properties file is provenance only, while the guest bootconfig
records the selected SwiftShader mode's own graphics properties. Check the
guest driver packaging and property source against build 16373615 before
changing image properties. These observations do not prove that either GPU
path rendered frames. See
[IR-173](../04-plan/implementation-review.md#ir-173-swiftshader-target-fallback).
A later 600-second observer-enabled SwiftShader profile run recorded 119
identified crosvm memory samples, with `VmRSS` rising from 25,884 KiB to
3,073,168 KiB. It did not observe Cuttlefish start event 5 or a Linux kernel
version marker, so it does not establish guest boot or the reason startup
timed out. See
[IR-181](../04-plan/implementation-review.md#ir-181-preserve-the-short-swiftshader-pre-kernel-capture).
The [AOSP GLES/EGL driver-loading guidance](https://source.android.com/docs/core/graphics/implement-opengl-es)
states that the system image supplies the drivers, which are discovered using
`ro.hardware.egl` or `ro.board.platform` and are preferably installed under
`/vendor/lib64/egl` on 64-bit devices. For `mesa`, the documented module
names include `libGLES_mesa.so`, or the set `libEGL_mesa.so`,
`libGLESv1_CM_mesa.so`, and `libGLESv2_mesa.so`. The current guest inventory
found none of those names in its inspected vendor EGL directory. This
reinforces checking guest image packaging before changing image properties.
A second, read-only inventory of the manifest-pinned `super.img`
(SHA-256
`54052b9f2d0f463e995c90b9eecc4b3a8aad29d110044aac9c2170108feb5a05`)
confirmed the driver paths in the image itself. Using the repository's
`apkrun_image.lp` and `apkrun_image.sparse` readers and `dump.erofs` from
`erofs-utils` 1.7.1, `vendor_a:/lib64/egl` contains only
`libEGL_emulation.so`, `libGLESv1_CM_emulation.so`, and
`libGLESv2_emulation.so`. In `system_a`, both `/lib64/egl` and
`/system/lib64/egl` are absent, covering the guest path whether that
partition is mounted at `/system` or at `/`. Its `/system/lib64` contains
the platform EGL/GLES and ANGLE libraries but no Mesa-named driver. The
live guest inventory independently reports the same three emulator modules
at `/vendor/lib64/egl` and no `/system/lib64/egl`. This confirms that the
pinned image lacks Mesa drivers in the preferred vendor directory and the
corresponding system EGL directory, consistent with the selected `mesa`
property's load failure. Keep this capture incomplete. Any run using a
corrected guest image is separate scope with independently recorded source
provenance and tracked packaging work; do not alter the pinned image or its
graphics properties as a reference-capture workaround. See
[IR-185](../04-plan/implementation-review.md#ir-185-verify-mesa-driver-payload-in-the-pinned-cuttlefish-image).

The rebuild notes below document the feature-enabled Virgl diagnostic host
used in IR-171 and IR-172. They do not make a reproducible host-package build
a prerequisite for #064. The 1200-second observer-enabled
`guest_swiftshader` target capture in [IR-175](../04-plan/implementation-review.md#ir-175-observe-the-swiftshader-target-fallback) did not obtain usable shell or boot-property results after ADB reported `device`. The already-running 2400-second follow-up completed as [IR-176](../04-plan/implementation-review.md#ir-176-complete-the-in-progress-swiftshader-target-observation). It recorded first-stage init, `virtio_gpu`, zygote service activity, two display power-mode markers, and continued `aidl/activity` interface-not-found requests through guest uptime 2048.362 seconds. ADB reported `device` on 99 of 102 polls, but 21 of 23 property queries timed out (20 captured zero bytes and one 46 bytes); the remaining two exited successfully with 90 bytes each, but no property was parsed. The shell-readiness and final logcat probes also timed out. These observations neither establish boot completion nor identify the cause of the AIDL failures; the crosvm binary identity was not retained. Do not repeat this SwiftShader configuration without a material host or guest code/configuration change. The next useful investigation is identifying the provider and readiness conditions for `aidl/activity` in build 16373615. See [M01](../04-plan/issues/M01-android-bring-up.md) for the diagnostic history.
If reproducible host-build work is still needed, file a separate task before
expanding #064.

For a diagnostic rebuild, use the pinned Cuttlefish build setup rather than
an unmodified distro `cargo build`. Its Bazel crate specification applies
Cuttlefish-specific annotations and patches, and manages Rust host tools;
the pinned crosvm source declares Rust 1.88.0. The Cuttlefish container recipe
uses Debian 13 and installs Bazel, but runs `apt upgrade` without package
version pins, so a rebuild is not guaranteed to reproduce the installed
binary's Build ID. Build from the pinned Cuttlefish and crosvm revisions with
`virgl_renderer` enabled, and keep captures from that modified host runtime
diagnostic-only. See the pinned
[Cuttlefish crosvm specification](https://github.com/google/android-cuttlefish/blob/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/build_external/crosvm/crosvm.MODULE.bazel),
[container recipe](https://github.com/google/android-cuttlefish/blob/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/tools/buildutils/cw/Containerfile),
and [crosvm toolchain pin](https://github.com/google/crosvm/blob/fd4df63707aee57092a28db63bc1ff8945c76058/rust-toolchain).

Extract the guest image archive and matching host package into separate
directories. Activate the tools' Python environment and put the host package's
`bin/` directory on `PATH`. Stop any running Cuttlefish guests on the reference
VM. Set `ANDROID_ADB_SERVER_PORT` to a dedicated, unused port so capture
preflight cannot contact an existing default-port ADB server. Ensure this
dedicated server has no connected devices before capturing:

```bash
mkdir -p "$HOME/cuttlefish/16373615/host" "$HOME/cuttlefish/16373615/product"
export CVD_HOST_DIR="$HOME/cuttlefish/16373615/host"
cvd fetch --target_directory="$CVD_HOST_DIR" \
  --host_package_build=16373615/aosp_cf_arm64_only_phone-userdebug \
  --keep_downloaded_archives
unzip /path/to/aosp_cf_arm64_only_phone-img-16373615.zip \
  -d "$HOME/cuttlefish/16373615/product"
source Images/tools/.venv/bin/activate
export PATH="$CVD_HOST_DIR/bin:$PATH"
export ANDROID_PRODUCT_OUT="$HOME/cuttlefish/16373615/product"
export APKRUN_CVD_PACKAGE_VERSION='<matching host package version>'
export ANDROID_ADB_SERVER_PORT=5038
Images/tools/reference/capture.sh default
Images/tools/reference/capture.sh target
Images/tools/reference/capture.sh swiftshader
```

The capture preflight uses the selected ADB port, while the boot observer uses
its own private Unix socket. After capture, verify the listener on the
dedicated port and stop only that server with
`ANDROID_ADB_SERVER_PORT=5038 adb kill-server`; leave any default-port ADB
server untouched. If the guest mounts the workspace read-only, keep that
setting: copy `Images/tools/reference/` and the pinned image manifest into a
writable guest-side scratch tree, run the capture from that copy, and use
`limactl copy` to retrieve the normalized record. Preserve the copied
directory layout and verify the capture-source hashes before importing the
record into the working tree.

Use `cvd-host_package.tar.gz` from the same build as the guest image archive.
`cvd fetch` retrieves and extracts it into `CVD_HOST_DIR`. It provides the
matching `launch_cvd`, `cvd`, and `adb` commands under `bin/`. The Debian
Cuttlefish packages install host dependencies and configure the Linux VM;
their `cvd` command is not a replacement for the build-matched host tools in
the reference capture. `capture.sh` passes both `CVD_HOST_DIR` and
`ANDROID_PRODUCT_OUT` to the host package's `cvd create` command, along with a
private base directory and unique group name for each run. It creates the
group with `--nostart`, then starts it by its unique group name because this
Cuttlefish version's `launch_cvd` wrapper does not expose
`--base_directory`. It copies the verified product images into that private
`HOME` before launch because Cuttlefish may resize images in place. It rejects
symbolic links in the product tree and verifies every manifest-pinned image
hash both before and after copying, so a file change during the copy prevents
Cuttlefish from starting. The capture connects ADB to the selected
`127.0.0.1` instance port while waiting for boot and disconnects that serial
before removing its Cuttlefish group. The disconnect is bounded to 10 seconds
with a 2-second forced-stop grace period, so a stuck ADB command cannot block
group cleanup. The downloaded product files remain unchanged.

`gdb` is optional for diagnosing a crashed Cuttlefish host process. Analyze a
core dump with the exact executable and matching debug symbols; similarly
named files from another host package may have different build IDs. Keep raw
core dumps on the reference host because they can contain guest RAM. Only a
sanitized backtrace summary belongs in an incomplete repository capture.

For the 2026-10-04 crosvm crash, the pinned Cuttlefish 1.57.0 panic hook
temporarily redirects stderr to a pipe, sets `RUST_BACKTRACE=1`, and calls
Rust's default panic hook before logging the captured text. The installed
crosvm and gfxstream Build IDs match the crash record. A runtime loader trace
with `LD_BIND_NOW=1 LD_DEBUG=bindings` confirmed that, without preload,
crosvm's `_Unwind_GetIP` resolves to `libgfxstream_backend.so` while
`_Unwind_Backtrace` resolves to `libgcc_s.so.1`. A second trace with the same
settings and `LD_PRELOAD=/lib/aarch64-linux-gnu/libgcc_s.so.1` showed that
`_Unwind_GetIP` references from both libraries resolve to libgcc_s. The IR-171
diagnostic capture already used this
preload and recovered the original panic, `Failed to create virtio gpu worker
thread: invalid rutabaga build parameters`, before crosvm exited with
`SIGABRT`. Together with the earlier crash's unwinder stack frames, this is
consistent with a secondary fault during panic backtrace collection, but does
not establish where the earlier SIGSEGV occurred. The loader-only check does
not reproduce that fault, and the evidence does not show that gfxstream itself
caused the original panic. See
[IR-171](../04-plan/implementation-review.md#ir-171-diagnose-crosvm-panic-output)
and [IR-187](../04-plan/implementation-review.md#ir-187-verify-runtime-crosvm-unwinder-symbol-binding)
for the capture and binding details.

When the crosvm report is absent on a retry, check `/var/log/apport.log`.
Apport can suppress a new report while the matching report in `/var/crash`
still exists unseen. Preserve the old report in a private archive outside
`/var/crash` before retrying; do not delete the raw report or copy it into the
repository.

The crosvm panic-output experiment is opt-in and diagnostic-only. Follow the
build and staging steps in the
[experiment README](../../Experiments/cuttlefish-boot-diagnosis/README.md#pinned-virgl-crosvm-diagnostic-rebuild)
to place the static launcher beside the diagnostic `crosvm` and
`libgfxstream_backend.so` in a user-owned directory. Start the capture from a
shell without inherited `LD_*` or `GLIBC_TUNABLES` variables, then set
`APKRUN_CROSVM_BINARY` for one target capture:

```bash
APKRUN_CAPTURE_BOOT_OBSERVER=1 \
APKRUN_CROSVM_BINARY="$HOME/.local/share/apkrun/diagnostics/crosvm-virgl/crosvm-built-virgl-launcher" \
APKRUN_CROSVM_OBSERVER_EXECUTABLE="$HOME/.local/share/apkrun/diagnostics/crosvm-virgl/crosvm" \
  Images/tools/reference/capture.sh target
```

The static launcher clears inherited loader variables before it executes the
diagnostic crosvm and preloads the host's `libgcc_s.so.1`. The pinned
`cvd create` and `cvd start` accept `--crosvm_binary`; `capture.sh` passes the
override to both commands only when this environment variable is set. A
launcher that executes a different binary must set
`APKRUN_CROSVM_OBSERVER_EXECUTABLE` to the executable used after the launcher's
`exec`; preflight and runtime checks compare that expected ELF with the process
that Cuttlefish starts. For a direct crosvm override, leave this variable unset
so it defaults to `APKRUN_CROSVM_BINARY`. A
normalized run using the override is retained under `incomplete/` with a
diagnostic-only reason, even if Android boots, because the host runtime has
changed. The reason is written when staging begins, so interrupted runs
retain it when normalization succeeds. The standard capture path discards
staging data if normalization fails. Do not compare these runs with canonical
profiles.

`APKRUN_CVD_PACKAGE_VERSION` is optional when `dpkg-query` can report the
installed `cuttlefish-base` version. The script checks every guest artifact
against the checked-in build 16373615 manifest before launch. Each run creates
a private temporary Cuttlefish `HOME` under `TMPDIR` (default `/tmp`), uses
instance 1 by default, and removes only its uniquely named Cuttlefish group.
Set `APKRUN_CVD_INSTANCE_NUM` to use another provisioned number. Guest
commands use only the `localhost` or `127.0.0.1` ADB serial matching that
instance's port. A host-wide lock under `/tmp` allows only one reference capture across
checkouts and users at a time. A forced kill can leave that lock; after
confirming that no capture or Cuttlefish process is running, the lock owner
or an administrator can remove `/tmp/apkrun-cvd-capture.lock`. Shutdown is
bounded by
`APKRUN_CVD_STOP_TIMEOUT_SECONDS` (120 seconds by default, followed by a
10-second forced-stop grace period). The private `HOME` is removed after a
successful group removal and retained with its path printed if removal fails.
Even after a failed launch, the script attempts removal by the unique group
name, without targeting other Cuttlefish guests. It refuses to overwrite an
existing profile.
Gzip inputs or decompressed outputs larger than 64 MiB are rejected. A failed
or partial collection is retained under
`Images/reference/16373615/incomplete/` with a per-item reason in `MISSING.txt`
and a nonzero exit status. The script never publishes raw logcat. If both raw
file removal and stage deletion fail, it prints the unpublished staging path;
remove that directory manually before reviewing or committing captures. The
script discards staging data and publishes nothing when normalization fails;
if filesystem permissions prevent deletion, it prints the path for manual
cleanup. Select the `target` fallback explicitly by setting
`APKRUN_TARGET_GPU_MODE=guest_swiftshader`,
`APKRUN_DRM_VIRGL_SOURCE_REVISION=<revision>`, and
`APKRUN_DRM_VIRGL_PROPS_FILE=<path to source-derived properties>`.

Without an M3 Mac, use an arm64 Linux machine (bare metal or cloud), or as a last resort an x86_64 Linux host with QEMU TCG.

**Read-only crosvm package check (2026-10-06; see [IR-231](../04-plan/implementation-review.md#ir-231-check-installed-crosvm-unwinder-symbols)).** On the arm64 Lima host, `readelf` reported Build IDs `d724bf54f045b0ec7dbe14049b0fed9a16e52a23` for `/usr/lib/cuttlefish-common/bin/crosvm` and `6b8f3105442da5c66988881a1fa76e812b13c3e8` for its adjacent `libgfxstream_backend.so`. The backend exports `unw_get_reg` and `_Unwind_GetIP`; crosvm depends on both that backend and `libgcc_s.so.1`. Saved Apport retry metadata identifies the same executable path and package `cuttlefish-base 1.57.0 [origin: android-cuttlefish]`. This confirms the package path and symbol availability for those retries, not the exact binding or cause of PID 1573779's earlier SIGSEGV.

---

## 4. Test Linux guest

M0 (#003–#007, then #063 and #019) boots a small Linux guest before Android ([../02-design/vm.md](../02-design/vm.md) §12).

```bash
export APKRUN_TEST_LINUX_DIR="${TMPDIR:-/tmp}/apkrun-test-linux"
scripts/fetch-test-linux.sh          # Alpine linux-virt kernel, hash from ThirdParty.lock.json, decompressed
scripts/build-test-initramfs.sh      # pinned minirootfs + modules + socat + Tests/Fixtures/linux/init
xcodebuild test -scheme IntegrationTests \
  -only-test-configuration LinuxGuest \
  APKRUN_TEST_LINUX_DIR="$APKRUN_TEST_LINUX_DIR" \
  DEVELOPMENT_TEAM="$APKRUN_TEST_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$APKRUN_TEST_CODE_SIGN_IDENTITY"
```

- Both scripts default to `/tmp/apkrun-test-linux/`. An `APKRUN_TEST_LINUX_DIR` override must be absolute and outside the current account's `~/Documents`, even when the shell overrides `HOME`. The scripts and hosted test reject direct paths and symlink aliases before looking up anything inside Documents or creating guest artifacts. The hosted test reads this path from `APKRunTestHost.app/Contents/Info.plist`; pass it as an `xcodebuild` build setting as shown, because Xcode does not forward the invoking shell's custom environment to the hosted test process. Keeping guest artifacts outside protected Documents prevents macOS file-access approval prompts for checkouts under `~/Documents`. The initramfs build runs on macOS with `cpio` and `gzip` from the base system and needs no Linux machine.
- The tests look for `APKRUN-TEST: boot ok`, one `APKRUN-TEST: <name> ok` per requested check (`apkrun.test=blk,net,vsock,ports,rng,gpu,virgl`), and `APKRUN-TEST: done`, with `apkrun.test.poweroff=1`.
- When the artifacts are missing, the tests skip with a message that names the two scripts. Pass `APKRUN_CI=1` as an `xcodebuild` build setting to make missing artifacts fail.
- VM tests need `com.apple.security.virtualization`. They therefore run inside the signed test host `APKRunTestHost`, not under `swift test` ([build-system.md](build-system.md) §12.4). Set the two signing variables above to a matching lab development certificate and team.

---

## 5. Linux x86_64 AOSP builder

The APKRun AOSP product (#035) and every release image are built on a Linux x86_64 machine. macOS cannot build AOSP. Set the builder up during M3 so that #035 can start as soon as #034 is done ([../04-plan/roadmap.md](../04-plan/roadmap.md) §1.3, R-14).

### 5.1 Hardware

| Item | Requirement |
|---|---|
| CPU | x86_64, ≥ 32 cores recommended (a full build then takes about 2 hours; incremental builds are minutes) |
| RAM | ≥ 64 GB |
| Disk | ≥ 400 GB free on local SSD or NVMe (source about 150 GB with partial clone, `out/` about 200 GB) |
| Network | enough for the first sync (about 100 GB) |
| Access | SSH with a key; the maintainers who build images have accounts |

A cloud VM is fine for development builds. Release builds need the AOSP release keys (§5.6), so they run on a machine the maintainers control.

### 5.2 OS and container

- Host OS: any 64-bit Linux that runs Docker or Podman. The build itself runs in a container, so the host distribution does not matter.
- Container: `scripts/aosp/builder.Dockerfile`, based on `ubuntu:22.04`, with the standard AOSP packages (`git-core gnupg flex bison build-essential zip curl zlib1g-dev libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig python3`), the `repo` launcher, JDK 17, and the Android SDK packages of §2.5 (for the Gradle build of the agent APKs, [build-system.md](build-system.md) §9).
- The container image is built once per change of the Dockerfile and referenced by digest. The digest goes into the bundle `provenance` ([../02-design/android-image.md](../02-design/android-image.md) §11.5).

```bash
docker build -t apkrun-aosp-builder -f scripts/aosp/builder.Dockerfile scripts/aosp
docker image inspect --format '{{.Id}}' apkrun-aosp-builder   # record this digest
```

### 5.3 Source checkout

```bash
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://android.googlesource.com/platform/manifest \
  -b aosp-android-latest-release --partial-clone --clone-filter=blob:limit=10M
cp <apkrun checkout>/Guest/product/manifest/pinned.xml .repo/manifests/apkrun-pinned.xml
repo init -m apkrun-pinned.xml
repo sync -c -j"$(nproc)" --no-tags
```

- `Guest/product/manifest/pinned.xml` is the `repo manifest -r` snapshot of the tree used for release builds. Moving the pin is a pull request of its own: sync the branch head, run `repo manifest -r -o Guest/product/manifest/pinned.xml`, build, boot, and record the reason.
- The APKRun sources enter the tree through `.repo/local_manifests/apkrun.xml`, which `scripts/aosp/build-product.sh` writes for the requested APKRun revision ([build-system.md](build-system.md) §9).
- Public AOSP arrives as release drops, and the Cuttlefish device tree can change between drops (R-14). A new drop is a pin move, not a silent `repo sync`.

### 5.4 Build

`scripts/aosp/build-product.sh --revision <apkrun commit> --variant userdebug|user` runs these steps in the container:

```bash
source build/envsetup.sh
lunch apkrun_arm64-trunk_staging-userdebug      # or apkrun_arm64-trunk_staging-user for release
export BUILD_NUMBER=ar000123                    # from the builder's counter, §5.7
m
m dist DIST_DIR=out/dist
ls out/dist/apkrun_arm64-img-ar000123.zip
```

The `*-img-*.zip` then goes through the same pipeline as the stock image, starting with inventory ([../02-design/android-image.md](../02-design/android-image.md) §3–§10).

### 5.5 Remote workflow from a Mac

Developers work on the Mac and drive the builder over SSH.

```bash
export APKRUN_AOSP_BUILDER=builder@aosp-builder.example
git push origin task/035-apkrun-aosp-product      # the builder fetches this commit
scripts/aosp/remote-build.sh --revision "$(git rev-parse HEAD)" --variant userdebug
```

`remote-build.sh`:

1. Checks that the revision exists on `origin` (the builder never receives uncommitted work).
2. Runs `scripts/aosp/build-product.sh` on the builder inside the container.
3. Copies `out/dist/apkrun_arm64-img-<n>.zip` and `build-info.json` (pinned manifest hash, container digest, APKRun revision, `BUILD_NUMBER`) back to `Images/work/ar<n>/download/`.
4. Prints the next commands: `scripts/inventory-cuttlefish.py` and `apkrun_image bundle` ([build-system.md](build-system.md) §9–§10).

A build log stays on the builder under `~/aosp/logs/<BUILD_NUMBER>.log`, and its path is printed.

### 5.6 Keys on the builder

- `userdebug` builds use the AOSP test keys of the tree. They are for development and CI only.
- `user` builds are signed with the APKRun platform and release keys. The keys are offline and live on the image build machine only ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7). Treat them as permanent: changing them breaks updates of the platform-signed agents.
- The release signing flow is fixed in #035 (OQ-36, [../02-design/android-image.md](../02-design/android-image.md) §11.4).

### 5.7 Build numbers and provenance

- `BUILD_NUMBER` is `ar` plus a six-digit counter kept on the builder (`~/aosp/build-counter`). It becomes the base part of the image version, for example `2026.10.0-ar000123-arm64`.
- Every build records the pinned manifest, the container image digest, and the APKRun revision. `apkrun_image bundle` copies them into `provenance`.

---

## 6. Lab Mac and self-hosted runners

### 6.1 Runners

| Label | Machine | Jobs |
|---|---|---|
| `xcode-27` | GitHub-hosted Apple Silicon macOS 27 VM; fresh instance per job | pull request and `main` jobs in `ci.yml`, including static checks, builds, and T0 Swift tests ([build-system.md](build-system.md) §15); no host-dependent T1 tests |
| `apkrun-ci` | a bare-metal Apple Silicon Mac on macOS 27 with the §2 toolchain, a logged-in CI user, and an APFS scratch volume | trusted default-branch jobs and controlled workflows only; never a `pull_request` runner |
| `apkrun-lab` | every lab Mac, set up as in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.6 | trusted `main` T2 suites, nightly T3, performance for information, nightly notarization |
| `apkrun-reference` | the reference Mac (OQ-02); it also carries `apkrun-lab` | gate checks G1–G9, NFR numbers, the release smoke matrix |
| `apkrun-seed` | the seed lab Mac | the full T2 set and the closed gate checks on each new macOS build (`macos-seed.yml`) |
| `apkrun-aosp` | the AOSP builder of §5 (the development builder, not the image build machine) | nightly `userdebug` product builds |

GitHub-hosted `ubuntu-latest` runners take the Linux-only jobs: `cargo test` with the T1 `vsock_loopback` test, `ruff`, JSON schema checks, the F-Droid test repository build, the upstream security check, and the weekly feed re-signing. The `xcode-27` runner is a fresh macOS 27 VM for each job and runs repository builds and Swift T0 tests. GitHub's standard macOS 27 runner entered Public Preview on 10 September 2026. Its standard image is a 3-core M1 VM with 7 GB RAM and 14 GB SSD; this resource limit is a risk for later, larger suites. Public repositories have unlimited standard-runner minutes; private repositories consume their plan's hosted-runner minutes. `user` release images are built by a maintainer on the image build machine (§5.6), never by a runner.

A lab Mac has one runner slot, so it runs one job, and therefore one VM, at a time.

`ci.yml` uses the unprivileged `pull_request` event. Every job runs on a fresh GitHub-hosted macOS 27 VM, checks out the exact PR head SHA with persisted Git credentials disabled, and has only `contents: read`. It does not reference repository secrets or self-hosted runners. Do not switch these jobs to `pull_request_target`: that event has elevated trust and must not check out and execute PR code.

`ci-policy.yml` is the narrow exception that uses `pull_request_target` for pull requests to `main`. It checks out only `refs/heads/main`, reads pull request metadata, changed paths, and reviews through the read-only API, and never checks out or executes pull request code. Changes to CI control files pass only after a non-author human approves the current head and that same reviewer applies `ci-policy-approved` to it. The policy protects workflows, Xcode build-phase scripts, the Gradle wrapper, build scripts and `buildSrc`/`build-logic` conventions, code-generation and test scripts, dependency pins, tool-version and Xcode pins, formatter configurations, every `Package.swift` and `project.yml`, every `Tests/` and `UITests/` tree, and the module dependency graph. It compares the event's head and base with the current pull request and reads the revision again after fetching paths and reviews; any revision change during verification fails closed. Any new commit, reopening, later label event, or PR edit resets the check for control-file changes; the reviewer removes and reapplies the policy label last. Removing the approval label revokes the check. A reviewer who withdraws the policy approval must remove that label; branch protection separately requires an active PR approval. The policy does not subscribe to `pull_request_review`, whose workflow definition comes from the PR merge commit; review-event evaluation therefore cannot remain within the trusted-main workflow boundary. Require its `workflow-policy` job in branch protection. Public repository administrators must permit the `pull_request_target` workflow event under repository Actions policy before enabling this check.

### 6.2 Runner setup

- Create a dedicated macOS user `apkrun-ci` with automatic login. The runner runs as a LaunchAgent in that user's GUI session, because some future T1/T2/T3 checks need Metal, windows, `SMAppService` registration, and a user launchd domain.
- Before registering any persistent runner with GitHub, verify the account supports runner-group workflow access pinned to the exact default-branch ref. Allow only a separate trusted workflow, for example `<owner>/<repo>/.github/workflows/ci-trusted.yml@refs/heads/main`, and exclude `ci.yml`, `ci-policy.yml`, and every pull-request workflow. GitHub documents this workflow pinning in its [runner-group access guide](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/managing-access-to-self-hosted-runners-using-groups). A pull request can change its workflow file and request `self-hosted`, so the checked-in YAML is not the security boundary. If the account cannot enforce default-branch-only workflow access, keep the runner disconnected and run host-dependent checks manually or provision disposable hardware.
- Install the §2 toolchain for that user and run `scripts/bootstrap --check` (§7).
- Disable sleep and screen lock (`sudo pmset -a sleep 0 displaysleep 0 disksleep 0`). Sleep and wake behavior is tested with simulated power events (T1) and manual T3 checks, not by sleeping the runner.
- Free disk: ≥ 200 GB. The third-party cache (`ThirdParty/out/`), image bundles, and the APK corpus stay between runs.
- Before each T2/T3 job the workflow resets `APKRUN_HOME` to a fresh directory and unregisters old development agents (`launchctl bootout gui/$(id -u)/io.apkrun.apkrund.dev`).
- Lab Macs also meet [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.6: AC power, Low Power Mode off, a second local test account, the one-time permissions (Accessibility, Screen Recording, notifications, and Microphone for apkrund), each lab Mac's own development image key (`python3 -m apkrun_image keygen`), and a runner cache with pinned SHA-256 values.

### 6.3 Accessibility permission for the perf harness

The `apkrun-perf` input scenario synthesizes events with `CGEvent.postToPid`, which needs the Accessibility permission ([../02-design/diagnostics.md](../02-design/diagnostics.md) §9).

1. Sign `apkrun-perf` on the lab Mac with a stable identity (the lab's Apple Development certificate, name in `APKRUN_LAB_SIGN_IDENTITY`). An ad-hoc signature changes with every build, and macOS then forgets the grant.
2. Run the harness once from the runner user's session. macOS lists it under System Settings → Privacy & Security → Accessibility.
3. Turn it on. Re-check after every macOS update.

The harness checks `AXIsProcessTrusted()` at start and fails with a message that names this section if the permission is missing.

### 6.4 Secrets and credentials

| Secret | Where | Used by |
|---|---|---|
| `APKRUN_ANDROID_BUILD_API_KEY` | repository secret | fetch jobs |
| notarytool API key (`.p8`, key ID, issuer) | environments `signing` and `release`; on the lab Mac also a keychain profile `apkrun-notary` (`xcrun notarytool store-credentials`) | nightly notarization, release job |
| Developer ID Application certificate | environments `signing` and `release`, imported into a temporary keychain per job and deleted after it | nightly notarization, the Maintenance T2 suite (`ReleaseUpdateTest` bundles are Developer ID signed, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2), release job ([workflow.md](workflow.md) §9) |
| Sparkle EdDSA private key | environment `release` | release job only |
| Image Ed25519 signing key | environment `release` | image release and feed re-signing jobs only ([workflow.md](workflow.md) §10) |

- The environment `release` accepts only tags `v*` and `image-*` and the `main` branch, and every job waits for a maintainer's approval.
- The environment `signing` accepts only trusted `main` and release workflows. Pull-request jobs never receive signing credentials; maintenance tests that need Developer ID signing run manually on a reviewed commit or wait for a separately reviewed disposable signing environment.
- Pull request jobs never see release secrets. Tests that need a secret skip with a message when it is absent, except on runners with `APKRUN_CI=1`, where the job fails instead.

---

## 7. Verification checklist

`scripts/bootstrap` installs what it can (pinned tools, venv, `local.properties`) and then checks the environment. `scripts/bootstrap --check` only checks. Each task adds checks for the tools it introduces; checks for later tasks print `skip` until those tools are added. A machine is ready for the current task when every applicable check reports `ok` and no check reports `FAIL`. A full development environment reports `ok` for every row, with only the documented informational warnings.

| Check | Command it runs | Expected |
|---|---|---|
| Apple Silicon, macOS 27+ | `uname -m`, `sw_vers -productVersion` | `arm64`, `27.x` |
| Xcode | `xcodebuild -version` | matches `.xcode-version` |
| Metal toolchain | `xcrun -f metal` | found |
| Swift | `swift --version` | 6.2 or later |
| Homebrew packages | `brew bundle check --file scripts/Brewfile` | satisfied |
| Python venv | `Images/tools/.venv/bin/python -m apkrun_image --help` | exit 0 |
| JDK | `java -version` | 17 |
| Android SDK | `sdkmanager --list_installed` | platform 37, build-tools 37.0.0, NDK 28.2.13676358, platform-tools |
| Rust | `rustup target list --installed` (in `Guest/vsockd`) | `aarch64-linux-android` |
| cargo-ndk | `cargo ndk --version` | 3.5.4 |
| protoc, buf, XcodeGen | `build/tools/*/bin/* --version` | versions in `scripts/tool-versions.env` |
| protoc-gen-swift | `--version` | the swift-protobuf version in `Package.resolved` |
| API key | `APKRUN_ANDROID_BUILD_API_KEY` is set | set (warning only) |
| Nested virtualization | `VZGenericPlatformConfiguration.isNestedVirtualizationSupported` | reported (informational) |
| Free disk | `df -g .` | ≥ 150 GiB (150 1-GiB blocks; warning only) |

Then run the first build ([build-system.md](build-system.md) §1):

```bash
scripts/generate-project.sh
swift build && swift test       # a clean checkout builds and passes (NFR-DEV-02)
scripts/check-module-deps.sh
```

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `VZErrorDomain` "virtualization not available" or entitlement error in tests | a VM test ran outside the signed test host | run T2 tests with `xcodebuild test -scheme IntegrationTests` ([build-system.md](build-system.md) §12.4), not with `swift test` |
| `xcrun: error: unable to find utility "metal"` | Metal toolchain component missing | `xcodebuild -downloadComponent MetalToolchain` |
| ANGLE build stops with "no space left" | ANGLE needs about 11 GB | free disk; the CI cache is keyed by the lock hash ([build-system.md](build-system.md) §6) |
| `generate-protos.sh` produces a diff on a clean checkout | a protoc or protoc-gen-swift that is not the pinned one | run `scripts/bootstrap`; never use Homebrew `protobuf` for codegen |
| `apkrun_image fetch` returns HTTP 403 | missing or wrong API key | §3.1; or use the manual download fallback |
| `adb: device offline` or no device at `127.0.0.1:6520` | the runtime is not up, or a second adb server of another SDK is running | `adb kill-server`, use only `$ANDROID_HOME/platform-tools/adb` |
| Gradle: "SDK location not found" | `local.properties` missing | `scripts/bootstrap` |
| `cargo ndk`: "Could not find any NDK" | `ANDROID_NDK_HOME` unset or another version | §2.5 |
| Soong rejects Rust code that builds with cargo | the host Rust pin is newer than `prebuilts/rust` | §2.6 |
| The development agent does not start after a rebuild | the registered path points into a deleted DerivedData | `scripts/dev/install-dev-app.sh` ([build-system.md](build-system.md) §13) |
| `apkrun-perf` input scenario fails with "not trusted" | Accessibility permission lost (new signature or macOS update) | §6.3 |
| `/dev/kvm` missing in the reference VM | Mac older than M3, or nested virtualization not enabled in the VM tool | §3.3 |
| `repo sync` fails on a partial clone | old `repo` launcher | update `repo` in the container image, rebuild the image, record the new digest |
