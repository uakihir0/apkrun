# Environment Setup

This guide lists the machines and tools needed to build and test APKRun, and how to check that a machine is ready. The versions here are the pins. When a pin moves, change it here and in the file that enforces it (§2.9) in the same pull request. Items the repository does not have yet are marked *(planned, #NNN)*.

---

## 1. Machines and roles

| Machine | Needed for | Minimum | Section |
|---|---|---|---|
| Developer Mac | host code, Guest Gradle and Rust builds, image tooling, T0–T2 tests | Apple silicon (M1 or later), macOS 27, 16 GB RAM, 150 GiB free | §2 |
| Developer Mac, M3 or later | the Cuttlefish reference host as a nested-virtualization VM (#65) | M3 or later, 24 GB RAM recommended | §3.3 |
| Linux x86_64 AOSP builder | the release image (#120); CI runner `apkrun-aosp` | ≥ 64 GB RAM, ≥ 400 GB disk | §5 |
| Image build machine | `user` release images, signed with the offline AOSP release keys; never a CI runner | as the AOSP builder | §5.6 |
| GitHub-hosted `xcode-27` | static checks, builds, and Swift T0 tests for pull requests and `main` pushes | Apple silicon, 3 cores, 7 GB RAM, 14 GB SSD; one fresh VM per job | §6.1 |
| `apkrun-ci` | self-hosted runner for trusted default-branch jobs | bare-metal Apple silicon, macOS 27 | §6 |
| `apkrun-lab` | self-hosted runner for T2 suites, nightly T3, performance, nightly notarization | bare-metal Apple silicon, macOS 27; at least one with M3 or later | §6 |
| `apkrun-reference` | the lab Mac whose numbers count: gates, NFR numbers, release smoke, manual checklists | the reference Mac of OQ-02 (M1, 16 GB), public macOS releases only | §6 |
| `apkrun-seed` | installs each macOS 27.x build; runs the full T2 set and gates (R-16) | as a lab Mac | §6 |

macOS cannot build AOSP ([0003-cuttlefish-base-image.md](../01-architecture/decisions/0003-cuttlefish-base-image.md)). Intel Macs are not supported: arm64 guests need Virtualization.framework on Apple silicon.

---

## 2. Developer Mac

### 2.1 Hardware and OS

- Apple silicon, macOS 27.0 or later ([build-system.md](build-system.md) §2).
- 150 GiB free is a working minimum. The large items are the ANGLE checkout and build (about 11 GB; [graphics.md](../02-design/graphics.md) §5), Cuttlefish downloads and bundles under `Images/work/` (about 10 GB per build ID), the runtime image under `APKRUN_HOME`, and DerivedData.

### 2.2 Xcode and command line tools

| Tool | Pin | Install |
|---|---|---|
| Xcode | 27.0, in `.xcode-version` | Mac App Store or developer.apple.com |
| Command line tools | those inside the pinned Xcode | `sudo xcode-select -s /Applications/Xcode.app` |
| Metal toolchain | the component of the pinned Xcode | `xcodebuild -downloadComponent MetalToolchain` |

```bash
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
xcodebuild -downloadComponent MetalToolchain
xcrun swift --version        # Swift 6.2 or later
```

### 2.3 Homebrew

Run `brew bundle --file scripts/Brewfile` after installing Homebrew. The Brewfile lists `meson`, `ninja`, `pkg-config`, `python@3.12`, and `ripgrep`.

Homebrew versions float, so tools whose output is committed (protoc, protoc-gen-swift, buf, XcodeGen) come from `scripts/bootstrap` at their pins (§2.7). Do not use Homebrew `protobuf` for code generation. ANGLE uses its own pinned `depot_tools` ([build-system.md](build-system.md) §6.3).

### 2.4 Python 3.12

The image tooling `apkrun_image` in `Images/tools/` needs Python 3.12 (`requires-python` `>=3.12,<3.13`). Its pins in `Images/tools/pyproject.toml` ([android-image.md](../02-design/android-image.md) §1.2): `cryptography==50.0.1`, `jsonschema==4.26.0`, `lz4==4.4.5`, and the `test` extra with `pytest==9.1.1` and `ruff==0.16.6`.

```bash
python3.12 -m venv Images/tools/.venv
source Images/tools/.venv/bin/activate
pip install -e 'Images/tools[test]'
python3 -m apkrun_image --help
pytest Images/tools/tests
```

`Images/tools/.venv/` is git-ignored and created by `scripts/bootstrap`. Other Python scripts (`scripts/release/*.py`, `scripts/dev/update-server.py`) use the same venv.

### 2.5 JDK, Gradle, and the Android SDK

| Tool | Pin | Notes |
|---|---|---|
| JDK | Temurin 17: `export JAVA_HOME="$(/usr/libexec/java_home -v 17)"` | Kotlin targets JVM 17 ([guest-components.md](../02-design/guest-components.md) §2). `scripts/bootstrap` does not install it yet (planned, #16) |
| Gradle | 9.6.1, the wrapper in `gradle/wrapper/` (`distributionSha256Sum`), run as `./gradlew -p Guest`. Never install Gradle globally | `Tests/Fixtures/AndroidApps/` has its own wrapper of the same version |
| AGP, Kotlin, coroutines, protobuf, ktfmt | `Guest/gradle/libs.versions.toml`: AGP 9.4.1, coroutines 1.11.0, protobuf 4.31.1, ktfmt 0.64 | [coding-conventions.md](coding-conventions.md) §2 |
| Android platform, build tools, platform tools | `platforms;android-37.0`, `build-tools;37.0.0` (`apksigner`, the reference of `scripts/dev/verify-corpus.sh`), `platform-tools` (`adb`) | compileSdk and targetSdk 37 |
| NDK | `ndk;28.2.13676358` (r28c): the first NDK that links 16 KB-aligned ELF by default | `apkrun_vsockd` and native fixtures (§2.6) |

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager --sdk_root="$ANDROID_HOME" --install \
  "platform-tools" "platforms;android-37.0" "build-tools;37.0.0" "ndk;28.2.13676358"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
```

`Guest/local.properties` and `Tests/Fixtures/AndroidApps/local.properties` (git-ignored) hold `sdk.dir=$ANDROID_HOME`. `scripts/bootstrap` writes them once the check is added (planned, #16).

### 2.6 Rust and cargo-ndk

| Tool | Pin | Where |
|---|---|---|
| Rust | 1.88.0, with `rustfmt`, `clippy`, target `aarch64-linux-android` | `Guest/vsockd/rust-toolchain.toml` |
| cargo-ndk | 3.5.4 | `CARGO_NDK_VERSION` in `scripts/tool-versions.env` |

```bash
source scripts/tool-versions.env
cargo install --locked --version "$CARGO_NDK_VERSION" cargo-ndk
cd Guest/vsockd
rustup show                     # installs the pinned toolchain and Android target
cargo ndk -t arm64-v8a build --release
```

The product build uses the Rust prebuilt of the pinned AOSP tree (`prebuilts/rust/`; [build-system.md](build-system.md) §9). The host Rust pin must not be newer than that prebuilt, so code that builds with cargo also builds with Soong. #35 records the prebuilt version and sets the pin to match.

### 2.7 Code generation tools

| Tool | Pin | Source |
|---|---|---|
| protoc | 31.1 | `scripts/tool-versions.env`: `PROTOC_VERSION`, `PROTOC_SHA256` |
| protoc-gen-swift | the swift-protobuf version in `Package.resolved` (1.38.1) | built by `scripts/bootstrap` |
| buf | 1.55.1 | `scripts/tool-versions.env`: `BUF_VERSION`, `BUF_SHA256` |
| XcodeGen | 2.44.1 | `scripts/tool-versions.env`: `XCODEGEN_VERSION`, `XCODEGEN_SHA256` |

`scripts/bootstrap` downloads the protoc, buf, and XcodeGen archives into `build/tools/<name>-<version>/`, checks each SHA-256 before extraction, and builds `protoc-gen-swift` into `build/tools/protoc-gen-swift/`. `scripts/generate-protos.sh` and `scripts/generate-project.sh` use only these copies, never a tool on `PATH`.

### 2.8 Shell environment

| Variable | Value | Used by |
|---|---|---|
| `JAVA_HOME` | JDK 17 (§2.5) | Gradle |
| `ANDROID_HOME`, `ANDROID_NDK_HOME` | §2.5 | Gradle, cargo-ndk, `adb` |
| `APKRUN_ANDROID_BUILD_API_KEY` | the Android Build API key (§3.1) | `apkrun_image fetch` |
| `APKRUN_HOME` | unset; Debug defaults to `~/Library/Application Support/APKRun-Dev/` ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6) | host tools, tests |
| `APKRUN_TEST_LINUX_DIR` | unset; default `/tmp/apkrun-test-linux/`. Absolute, outside `~/Documents` ([build-system.md](build-system.md) §12.4) | T2 Linux guest tests, Debug CLI |
| `APKRUN_ANDROID_HOME` | SDK root outside `~/Documents` holding `platform-tools` (§4) | T2 Android suites |
| `APKRUN_TEST_DEVELOPMENT_TEAM` | Apple Development team ID of the lab test host | signed T2 and G1 tests |
| `APKRUN_TEST_CODE_SIGN_IDENTITY` | SHA-1 fingerprint of that team's Apple Development certificate | signed T2 and G1 tests |
| `APKRUN_AOSP_BUILDER` | `user@host` of the Linux builder (planned, #120) | `scripts/aosp/remote-build.sh` (§5.5) |
| `APKRUN_CI` | `1` on CI runners only; turns "skip with a message" into a failure | all tests and scripts |

Put the exports in `~/.zprofile`. Nothing in this table is committed.

### 2.9 Where the pins live

| Pin | File |
|---|---|
| Xcode | `.xcode-version` |
| Swift packages | `Package.swift` (exact) and `Package.resolved`; Sparkle (planned) in `project.yml` |
| protoc, buf, XcodeGen, and hashes; cargo-ndk | `scripts/tool-versions.env` |
| Gradle | `gradle/wrapper/gradle-wrapper.properties` |
| AGP, Kotlin, Android libraries | `Guest/gradle/libs.versions.toml` |
| Android SDK, build tools, NDK | §2.5 and `scripts/bootstrap` |
| Rust | `Guest/vsockd/rust-toolchain.toml`, `Guest/vsockd/Cargo.lock` |
| Python packages | `Images/tools/pyproject.toml` |
| Third-party native code, test Linux kernel and rootfs, vendored mkbootimg and avbtool | `ThirdParty/ThirdParty.lock.json` ([build-system.md](build-system.md) §6) |
| Cuttlefish build | `Images/manifests/<buildId>/android-image.json` |
| AOSP source | `Guest/product/manifest/pinned.xml` (planned, #120) |

---

## 3. Android artifacts

### 3.1 Android Build API key

`apkrun_image fetch` uses the Android Build API v4 ([android-image.md](../02-design/android-image.md) §2.2). The key is the public key embedded in the open-source `cvd` tool, and it is not committed. Find it in a clone of `https://github.com/google/android-cuttlefish` with `git ls-files | grep android_build_api_key.cc`. Store it in the login Keychain and export it:

```bash
security add-generic-password -a "$USER" -s apkrun-android-build-api-key -w '<key>'
# in ~/.zprofile
export APKRUN_ANDROID_BUILD_API_KEY="$(security find-generic-password -a "$USER" -s apkrun-android-build-api-key -w)"
```

On CI the repository secret `APKRUN_ANDROID_BUILD_API_KEY` holds the same value. Do not paste the key into issues, pull requests, or logs.

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

- Downloads resume. `fetch.json` records the build ID, target, branch, and each artifact's name, size, and SHA-256. Inventory verifies the archives and carries that provenance into `inventory.json`.
- Without a key, download `aosp_cf_arm64_only_phone-img-16373615.zip` from ci.android.com into the same directory and run the same commands; `fetch` then only verifies ([android-image.md](../02-design/android-image.md) §2.2).
- The prebuilt image is for development only (M1–M4). Do not publish it or bundles made from it ([legal-and-licensing.md](legal-and-licensing.md) §2).

### 3.3 Cuttlefish reference host

The reference boot capture ([android-image.md](../02-design/android-image.md) §8) needs a Linux machine with real Cuttlefish. Preferred: an arm64 Linux VM with nested virtualization on an M3 or later Mac. Otherwise an arm64 Linux machine (bare metal or cloud). As a last resort, x86_64 Linux with QEMU TCG.

| Step | Detail |
|---|---|
| VM | arm64 Debian 12 or Ubuntu 24.04, in a VZ-based tool that sets `VZGenericPlatformConfiguration.isNestedVirtualizationEnabled` (check `isNestedVirtualizationSupported` first); 8 vCPUs, 16 GB RAM, 120 GB disk |
| KVM | `/dev/kvm` present; the user in the `kvm`, `cvdnetwork`, and `render` groups |
| Host tools | `cuttlefish-base` and `cuttlefish-user` (arm64 packages), then reboot; GNU `timeout` on `PATH` |
| Graphics libraries | without `/dev/dri`: `libgles2-mesa-dev` and `libvirglrenderer1` |
| Artifacts | the same build as §3.2, plus `cvd-host_package.tar.gz` of that build |
| Output | `Images/reference/<buildId>/<profile>/` on the Mac, committed |

Commands (profiles `default`, `target`, `swiftshader`; [android-image.md](../02-design/android-image.md) §8.2):

```bash
mkdir -p "$HOME/cuttlefish/16373615/host" "$HOME/cuttlefish/16373615/product"
export CVD_HOST_DIR="$HOME/cuttlefish/16373615/host"
cvd fetch --target_directory="$CVD_HOST_DIR" \
  --host_package_build=16373615/aosp_cf_arm64_only_phone-userdebug \
  --keep_downloaded_archives
unzip /path/to/aosp_cf_arm64_only_phone-img-16373615.zip -d "$HOME/cuttlefish/16373615/product"
source Images/tools/.venv/bin/activate
export PATH="$CVD_HOST_DIR/bin:$PATH"
export ANDROID_PRODUCT_OUT="$HOME/cuttlefish/16373615/product"
export APKRUN_CVD_PACKAGE_VERSION='<matching host package version>'
export ANDROID_ADB_SERVER_PORT=5038
Images/tools/reference/capture.sh default
Images/tools/reference/capture.sh target
Images/tools/reference/capture.sh swiftshader
```

Rules:

- The host package must match the guest image build. Use its `bin/` (`launch_cvd`, `cvd`, `adb`), not the Debian commands. The pinned crosvm does not enable `virgl_renderer`, so a `drm_virgl` `target` capture needs a Cuttlefish host built from the pinned source with that feature. Captures from such a host are diagnostic-only and go to `incomplete/`.
- Stop running Cuttlefish guests first. Use an unused `ANDROID_ADB_SERVER_PORT` with no connected devices. Afterwards stop only that server with `ANDROID_ADB_SERVER_PORT=5038 adb kill-server`.
- `target` checks the expected crosvm ELF before it starts Cuttlefish. `APKRUN_CROSVM_BINARY` overrides the binary for `cvd create` and `cvd start`; `APKRUN_CROSVM_OBSERVER_EXECUTABLE` names the ELF that runs after a launcher's `exec` (default: `APKRUN_CROSVM_BINARY`). The ELF is hashed again before `cvd create` and `cvd start`. A capture using the override is kept under `incomplete/` with a diagnostic-only reason.
- `APKRUN_CAPTURE_BOOT_OBSERVER` is `0` or `1`. The `target` profile uses `APKRUN_TARGET_GPU_MODE` (default `drm_virgl`): it sets `EGL_PLATFORM=surfaceless` for both CVD commands and records it in `host.json`, and clears an inherited `EGL_PLATFORM` otherwise. The `guest_swiftshader` fallback needs `APKRUN_DRM_VIRGL_SOURCE_REVISION` and `APKRUN_DRM_VIRGL_PROPS_FILE`.
- `capture.sh` disables the arm64 vhost-user GPU backend for each profile and verifies the selected configuration.
- Each run uses a private `HOME` under `TMPDIR` (default `/tmp`), instance 1 unless `APKRUN_CVD_INSTANCE_NUM` is set, and a uniquely named group, which is the only group it removes. Shutdown is bounded by `APKRUN_CVD_STOP_TIMEOUT_SECONDS` (default 120, then a 10-second forced-stop grace period). The private `HOME` is removed after a successful removal, or its path is printed. The script never overwrites an existing profile.
- Product images are copied into the private `HOME` and verified against the manifest hash before and after the copy. Symbolic links in the product tree are rejected.
- A host-wide lock, `/tmp/apkrun-cvd-capture.lock`, allows one capture at a time. After a forced kill, remove it only when no capture or Cuttlefish process runs.
- Gzip inputs and decompressed outputs over 64 MiB are rejected. A failed or partial collection goes to `Images/reference/16373615/incomplete/` with a reason per item in `MISSING.txt` and a nonzero exit. Raw logcat is never published.
- Raw crosvm core dumps stay on the reference host, because they can contain guest RAM. Only a sanitized backtrace summary belongs in the repository. Preserve an old crash report outside `/var/crash` before a retry; never copy raw reports into the repository.

The diagnostic crosvm rebuild and its static launcher are described in the [Experiments README](../../Experiments/cuttlefish-boot-diagnosis/README.md). Start a capture from a shell without inherited `LD_*` or `GLIBC_TUNABLES` variables.

---

## 4. Test Linux guest

M0 boots a small Linux guest before Android ([vm.md](../02-design/vm.md) §12).

```bash
export APKRUN_TEST_LINUX_DIR="${TMPDIR:-/tmp}/apkrun-test-linux"
scripts/fetch-test-linux.sh          # Alpine linux-virt kernel, hash from ThirdParty.lock.json, decompressed
scripts/build-test-initramfs.sh      # minirootfs, modules, socat, Alpine v3.23 virgl packages, Tests/Fixtures/linux/init; writes initramfs.manifest.json
xcodebuild test -scheme IntegrationTests \
  -only-test-configuration LinuxGuest \
  APKRUN_TEST_LINUX_DIR="$APKRUN_TEST_LINUX_DIR" \
  DEVELOPMENT_TEAM="$APKRUN_TEST_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$APKRUN_TEST_CODE_SIGN_IDENTITY"
```

- Both scripts default to `/tmp/apkrun-test-linux/`. An override must be absolute and outside `~/Documents`. Pass it as a build setting, because the hosted test reads it from `APKRunTestHost.app/Contents/Info.plist`.
- The initramfs build needs only the base-system `cpio` and `gzip`; no Linux machine.
- The tests look for `APKRUN-TEST: boot ok`, one `APKRUN-TEST: <name> ok` per check (`apkrun.test=blk,net,vsock,ports,rng,gpu,virgl`), and `APKRUN-TEST: done` (`apkrun.test.poweroff=1`).
- `scripts/tools/stage-hosted-test-inputs.sh` stages `scanout-00-1024x768-60.edid` (the golden EDID of the `gpu` check) and `virgl-runtime/`, a copy of the four VirGL libraries that `ThirdParty/out/virgl-runtime/current` names. The `gpu` and `virgl` checks read the copies, so the hosted process does not read `~/Documents`. The `virgl` test sets `APKRUN_VIRGL_RUNTIME_PATH` to the copy. The stager does not build the runtime: run `scripts/build-third-party.sh virgl-runtime` first.
- With artifacts missing, the tests skip with a message that names the scripts. With `APKRUN_CI=1` as a build setting, they fail.
- To keep the renderer operations for the replay test, add `TEST_RUNNER_APKRUN_TEST_VIRGL_RECORDING=/tmp/<name>.json` to the `xcodebuild test` line. Then `APKRUN_TEST_KMSCUBE_RECORDING=/tmp/<name>.json swift test --traits TestReadback --filter theKmscubeSessionReplaysOnTheDeviceWithoutHostReadbacks` replays it. The path must be under `/tmp`.
- VM tests need `com.apple.security.virtualization`, so they run in the signed `APKRunTestHost` ([build-system.md](build-system.md) §12.4).
- For the Android suites, pass `-derivedDataPath "${TMPDIR:-/tmp}/apkrun-dd"` and an `APKRUN_ANDROID_HOME` outside `~/Documents` that holds `platform-tools`: `mkdir -p "${TMPDIR:-/tmp}/apkrun-test-sdk" && cp -R "$ANDROID_HOME/platform-tools" "${TMPDIR:-/tmp}/apkrun-test-sdk/"`. The copy is the same `adb` binary.
- The Guest Agent, package, and input suites read `APKRUN_GUEST_DIR` (`scripts/build-guest.sh --out /tmp/apkrun-test-guest`) and `APKRUN_FIXTURE_APK` (HelloText). The AndroidPackage suite uses RuntimeAPI for import, install, list, details, and uninstall; its headless activity and force-stop checks still use ADB.
- `AndroidInputTests` also reads `APKRUN_FIXTURE_COMPOSE_APK` (`scripts/build-fixtures.sh --app HelloCompose`, copied to `/tmp`). It needs the debug HelloText, whose `TEXT` and `DETAILS` broadcasts exist only in the debug manifest: `Tests/Fixtures/AndroidApps/gradlew -p Tests/Fixtures/AndroidApps :HelloText:assembleDebug`, then copy `HelloText/build/outputs/apk/debug/HelloText-debug.apk` to `APKRUN_FIXTURE_APK`. The input configuration also reads the staged `virgl-runtime/`, because a host built outside the checkout cannot find the VirGL libraries from its executable.

---

## 5. Linux x86_64 AOSP builder (planned)

Release images are built on a Linux x86_64 machine, because macOS cannot build AOSP. Development images are composed on the Mac and need no builder ([android-image.md](../02-design/android-image.md) §11.5). Set the builder up before #120 starts (R-14). This section describes the AOSP product build route; #120 may choose to re-sign the CI target files instead.

### 5.1 Hardware

| Item | Requirement |
|---|---|
| CPU | x86_64, ≥ 32 cores recommended |
| RAM | ≥ 64 GB |
| Disk | ≥ 400 GB free on local SSD or NVMe (source about 150 GB with partial clone, `out/` about 200 GB) |
| Network | enough for the first sync (about 100 GB) |

A cloud VM is fine for development builds. Release builds need the AOSP release keys (§5.6), so they run on a machine that holds those keys.

### 5.2 OS and container

- The host can be any 64-bit Linux that runs Docker or Podman. The build runs in a container.
- `scripts/aosp/builder.Dockerfile` (planned, #120) is based on `ubuntu:22.04`. It includes the AOSP packages (`git-core gnupg flex bison build-essential zip curl zlib1g-dev libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig python3`), the `repo` launcher, JDK 17, and the Android SDK packages of §2.5.
- Build the image once per Dockerfile change, and reference it by digest in the bundle `provenance` ([android-image.md](../02-design/android-image.md) §11.6).

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

- `Guest/product/manifest/pinned.xml` is the `repo manifest -r` snapshot of the release tree. A pin move is a pull request of its own: sync the branch head, run `repo manifest -r -o Guest/product/manifest/pinned.xml`, build, boot, and record the reason.
- The APKRun sources enter the tree through `.repo/local_manifests/apkrun.xml`, which `scripts/aosp/build-product.sh` writes ([build-system.md](build-system.md) §9).
- A new AOSP drop is a pin move, never a silent `repo sync` (R-14).

### 5.4 Build

`scripts/aosp/build-product.sh --revision <apkrun commit> --variant userdebug|user` runs these steps in the container:

```bash
source build/envsetup.sh
lunch apkrun_arm64-trunk_staging-userdebug      # or apkrun_arm64-trunk_staging-user for release
export BUILD_NUMBER=ar000123                    # from the builder's counter (§5.7)
m
m dist DIST_DIR=out/dist
ls out/dist/apkrun_arm64-img-ar000123.zip
```

The zip goes through the same pipeline as the stock image, starting with inventory ([android-image.md](../02-design/android-image.md) §3–§10).

### 5.5 Remote workflow from a Mac

```bash
export APKRUN_AOSP_BUILDER=builder@aosp-builder.example
git push origin task/120-release-apkrun-image      # the builder fetches this commit
scripts/aosp/remote-build.sh --revision "$(git rev-parse HEAD)" --variant userdebug
```

`scripts/aosp/remote-build.sh` (planned, #120): checks that the revision exists on `origin` (the builder never receives uncommitted work); runs `build-product.sh` inside the container; copies `out/dist/apkrun_arm64-img-<n>.zip` and `build-info.json` to `Images/work/ar<n>/download/`; and prints the next commands (`scripts/inventory-cuttlefish.py`, `apkrun_image bundle`). The log stays on the builder under `~/aosp/logs/<BUILD_NUMBER>.log`.

### 5.6 Keys on the builder

- `userdebug` builds use the AOSP test keys of the tree. They are for development and CI only.
- `user` builds use the APKRun platform and release keys. The keys are offline and live only on the image build machine ([security-model.md](../01-architecture/security-model.md) §7). They are permanent: changing them breaks updates of the platform-signed agents.
- The release signing flow is fixed by #120 (OQ-36; [android-image.md](../02-design/android-image.md) §11.4).

### 5.7 Build numbers and provenance

`BUILD_NUMBER` is `ar` plus a six-digit counter kept at `~/aosp/build-counter`. It is the base of the image version, for example `2026.10.0-ar000123-arm64`. Each build records the pinned manifest, the container digest, and the APKRun revision, which `apkrun_image bundle` copies into `provenance`.

---

## 6. Lab Mac and self-hosted runners

### 6.1 Runners

| Label | Machine | Jobs |
|---|---|---|
| `xcode-27` | GitHub-hosted Apple silicon macOS 27 VM (3 cores, 7 GB RAM, 14 GB SSD); a fresh VM per job | pull request and `main` jobs of `ci.yml` ([build-system.md](build-system.md) §15); no host-dependent T1 tests |
| `apkrun-ci` | bare-metal Apple silicon, macOS 27, §2 toolchain, logged-in CI user, APFS scratch volume | trusted default-branch jobs and controlled workflows; never a `pull_request` runner |
| `apkrun-lab` | each lab Mac, set up as in [test-strategy.md](../04-plan/test-strategy.md) §3.6 | trusted `main` T2 suites, nightly T3, performance, nightly notarization |
| `apkrun-reference` | the reference Mac (OQ-02); also carries `apkrun-lab` | gate checks G1–G9, NFR numbers, release smoke matrix |
| `apkrun-seed` | the seed lab Mac | full T2 set and closed gate checks on each macOS build (`macos-seed.yml`) |
| `apkrun-aosp` | the AOSP builder of §5 (not the image build machine) | nightly `userdebug` product builds |

GitHub-hosted `ubuntu-latest` runners take the Linux-only jobs (`cargo test`, the `vsock_loopback` T1 test when the runner kernel supports it, `ruff`, JSON Schema checks, the F-Droid test repository, the upstream security check, weekly feed re-signing). The `test-vsockd` job compiles the feature test on every run; if the loopback kernel module is unavailable it emits a notice, and T1 must be run locally on Linux with that module before claiming it passed. `user` release images are built on the image build machine (§5.6), never on a runner. A lab Mac has one runner slot, so it runs one job, and one VM, at a time.

`ci.yml` uses the unprivileged `pull_request` event. Each job runs on a fresh GitHub-hosted macOS 27 or Ubuntu VM, checks out the exact PR head SHA with persisted credentials disabled, has `contents: read` only, and references no secrets and no self-hosted runners. Never switch these jobs to `pull_request_target`.

`ci-policy.yml` is the only workflow with `pull_request_target`, for pull requests to `main`. It checks out only `refs/heads/main`, reads PR metadata, changed paths, and reviews through the read-only API, and never executes pull request code. A change to a protected path passes only after a non-author human approves the current head and that reviewer applies `ci-policy-approved`. Protected paths: workflows; Xcode build-phase scripts; the Gradle wrapper; build scripts and `buildSrc` or `build-logic`; code generation and test scripts; dependency and tool pins; formatter configurations; every `Package.swift` and `project.yml`; every `Tests/` and `UITests/` tree; and the module graph. The policy compares the event's head and base with the current PR, reads the revision again after fetching, and fails closed on any change. A new commit, reopen, label event, or PR edit resets the check; removing the label revokes it. Branch protection separately requires an active PR approval and the `workflow-policy` job. Public repositories must allow the `pull_request_target` event in Actions policy first.

### 6.2 Runner setup

- Create a macOS user `apkrun-ci` with automatic login. The runner runs as a LaunchAgent in its GUI session, because T1–T3 checks need Metal, windows, `SMAppService`, and a user launchd domain.
- Before registering any persistent runner, verify that the account supports runner-group access pinned to the default-branch ref. Allow only a separate trusted workflow such as `<owner>/<repo>/.github/workflows/ci-trusted.yml@refs/heads/main`, and exclude `ci.yml`, `ci-policy.yml`, and every pull-request workflow. A pull request can change its own workflow file, so the checked-in YAML is not the boundary. If the account cannot enforce this, keep the runner disconnected.
- Install the §2 toolchain for that user, and run `scripts/bootstrap --check` (§7).
- `sudo pmset -a sleep 0 displaysleep 0 disksleep 0`. Sleep and wake are tested with simulated power events and manual T3 checks.
- Keep at least 200 GB free for the third-party cache, image bundles, and the APK corpus.
- Before each T2 and T3 job, the workflow resets `APKRUN_HOME` to a fresh directory and unregisters old development agents (`launchctl bootout gui/$(id -u)/io.apkrun.apkrund.dev`).
- Lab Macs also follow [test-strategy.md](../04-plan/test-strategy.md) §3.6: AC power, Low Power Mode off, a second local test account, the one-time permissions (Accessibility, Screen Recording, notifications, Microphone for apkrund), each lab Mac's own development image key (`python3 -m apkrun_image keygen`), and a runner cache with pinned SHA-256 values.

### 6.3 Accessibility permission for the perf harness (planned)

The `apkrun-perf` input scenario posts events with `CGEvent.postToPid`, which needs the Accessibility permission ([diagnostics.md](../02-design/diagnostics.md) §9):

1. Sign `apkrun-perf` on the lab Mac with a stable identity: the lab's Apple Development certificate, named in `APKRUN_LAB_SIGN_IDENTITY`. An ad-hoc signature changes with every build, and macOS forgets the grant.
2. Run the harness once from the runner user's session, so it appears under System Settings → Privacy & Security → Accessibility.
3. Turn it on, and check again after every macOS update.

The harness checks `AXIsProcessTrusted()` at start and fails with a message that names this section when the permission is missing.

### 6.4 Secrets and credentials

| Secret | Where | Used by |
|---|---|---|
| `APKRUN_ANDROID_BUILD_API_KEY` | repository secret | fetch jobs |
| notarytool API key (`.p8`, key ID, issuer) | environments `signing` and `release`; on the lab Mac, keychain profile `apkrun-notary` (`xcrun notarytool store-credentials`) | nightly notarization, release job |
| Developer ID Application certificate | environments `signing` and `release`; imported into a temporary keychain per job and deleted afterwards | nightly notarization, Maintenance T2 suite (`ReleaseUpdateTest` bundles; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2), release job ([workflow.md](workflow.md) §9) |
| Sparkle EdDSA private key | environment `release` | release job only |
| Image Ed25519 signing key | environment `release` | image release and feed re-signing jobs only ([workflow.md](workflow.md) §10) |

- Environment `release` accepts only tags `v*` and `image-*` and the `main` branch, and every job waits for the environment's required approval.
- Environment `signing` accepts only trusted `main` and release workflows. Pull request jobs never receive signing credentials. Maintenance tests that need Developer ID signing run on a reviewed commit on a lab Mac, or in a separately reviewed disposable signing environment.
- Pull request jobs never see release secrets. A test that needs a missing secret skips with a message, except where `APKRUN_CI=1` makes the job fail.

---

## 7. Verification checklist

`scripts/bootstrap` installs what it can (pinned tools, the Python venv, Homebrew packages) and then checks the environment. `scripts/bootstrap --check` only checks. Checks for tools that a later task adds print `skip` until it lands (JDK and Android SDK: #16; Android Build API key: #9). A machine is ready when every applicable check reports `ok` and none reports `FAIL`. Warnings are informational.

| Check | Command it runs | Expected |
|---|---|---|
| Apple silicon, macOS 27+ | `uname -m`, `sw_vers -productVersion` | `arm64`, `27.x` |
| Xcode | `xcodebuild -version` | matches `.xcode-version` |
| Metal toolchain | `xcrun -f metal` | found |
| Swift | `swift --version` | 6.2 or later |
| Homebrew packages | `brew bundle check --file scripts/Brewfile` | satisfied |
| Python venv | `Images/tools/.venv/bin/python -m apkrun_image --help` | exit 0 |
| JDK | `java -version` | 17 (planned, #16) |
| Android SDK | `sdkmanager --list_installed` | platform 37, build-tools 37.0.0, NDK 28.2.13676358, platform-tools (planned, #16) |
| Rust, cargo-ndk | `rustup target list --installed` in `Guest/vsockd`; `cargo ndk --version` | `aarch64-linux-android`; 3.5.4 |
| protoc, buf, XcodeGen | `build/tools/*/bin/* --version` | versions of `scripts/tool-versions.env` |
| protoc-gen-swift | `build/tools/protoc-gen-swift/bin/protoc-gen-swift --version` | the swift-protobuf version in `Package.resolved` |
| API key | `APKRUN_ANDROID_BUILD_API_KEY` set | set (warning only) |
| Nested virtualization | `VZGenericPlatformConfiguration.isNestedVirtualizationSupported` | reported (informational) |
| Free disk | free space at the checkout | ≥ 150 GB (warning only) |

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
| `VZErrorDomain` or an entitlement error in tests | a VM test ran outside the signed test host | run T2 with `xcodebuild test -scheme IntegrationTests` ([build-system.md](build-system.md) §12.4), not `swift test` |
| `xcrun: error: unable to find utility "metal"` | Metal toolchain missing | `xcodebuild -downloadComponent MetalToolchain` |
| ANGLE build stops with "no space left" | ANGLE needs about 11 GB | free disk; the cache is keyed by the lock hash ([build-system.md](build-system.md) §6) |
| `generate-protos.sh` diff on a clean checkout | a protoc or protoc-gen-swift that is not the pinned one | `scripts/bootstrap`; never Homebrew `protobuf` |
| `apkrun_image fetch` returns HTTP 403 | missing or wrong API key | §3.1, or the manual download |
| T2 host logs `ADB did not reach 127.0.0.1:<port>` after the boot completed, or goes silent after `Stopped the loopback forwarder` | the host or its `adb` is under `~/Documents`, and the Documents decision for `APKRunTestHost` is missing or stale | move `-derivedDataPath` and `APKRUN_ANDROID_HOME` outside `~/Documents` (§4); check the unified log for `kTCCServiceSystemPolicyDocumentsFolder` |
| `adb: device offline`, or no device at `127.0.0.1:6520` | runtime not up, or another SDK's adb server runs | `adb kill-server`; use only `$ANDROID_HOME/platform-tools/adb` |
| `apkrun dev adb` fails with `runtime.adbExecutableMissing` | no `adb` in `$ANDROID_HOME/platform-tools` or `PATH` | §2.5 |
| Developer boot logs `vm.loopbackPortInUse` (port 6520) and runs without ADB | another program listens on port 6520 | quit it (`lsof -nP -iTCP:6520 -sTCP:LISTEN`), then boot again |
| `apkrun dev adb` reports `device '127.0.0.1:6520' not found` | the developer boot is not running | start `apkrun dev boot`; `apkrun dev adb` connects the endpoint itself |
| Gradle: "SDK location not found" | `local.properties` missing | `scripts/bootstrap` (planned, #16) |
| `cargo ndk`: "Could not find any NDK" | `ANDROID_NDK_HOME` unset or another version | §2.5 |
| Soong rejects Rust that builds with cargo | host Rust pin newer than `prebuilts/rust` | §2.6 |
| Development agent does not start after a rebuild | the registered path points into deleted DerivedData | `scripts/dev/install-dev-app.sh` ([build-system.md](build-system.md) §13) |
| `apkrun-perf` input scenario fails with "not trusted" | Accessibility permission lost (new signature or macOS update) | §6.3 |
| `/dev/kvm` missing in the reference VM | Mac older than M3, or nested virtualization not enabled | §3.3 |
| `repo sync` fails on a partial clone | old `repo` launcher | update `repo` in the container image, rebuild it, and record the new digest |
