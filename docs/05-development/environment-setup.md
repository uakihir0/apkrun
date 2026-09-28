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
| Developer Mac | all host code, Guest Gradle and Rust builds, image tooling, T0–T2 tests | Apple Silicon (M1 or later), macOS 27, 16 GB RAM, 150 GB free disk | §2 |
| Developer Mac, M3 or later | the Cuttlefish reference host as a nested-virtualization Linux VM (#064) | M3 or later, 24 GB RAM recommended | §3.3 |
| Linux x86_64 AOSP builder | building the APKRun AOSP product (#035); as CI runner `apkrun-aosp`: nightly `userdebug` builds | ≥ 64 GB RAM, ≥ 400 GB disk | §5, §6.1 |
| Image build machine | `user` release images, signed with the offline AOSP release keys; a maintainer-controlled AOSP builder that is never a CI runner | as the AOSP builder | §5.6 |
| CI Macs (`apkrun-ci`) | self-hosted runners for T0/T1 and static checks on pull requests | bare-metal Apple Silicon, macOS 27 | §6 |
| Lab Macs (`apkrun-lab`) | self-hosted runners for T2 suites, nightly T3, performance for information, nightly notarization | bare-metal Apple Silicon (M1 or later), macOS 27; at least one with M3 or later | §6 |
| Reference Mac (`apkrun-reference`) | the lab Mac whose numbers count: gate checks, NFR numbers, the release smoke matrix, manual checklists | the reference Mac of OQ-02 (M1, 16 GB), public macOS release only | §6 |
| Seed lab Mac (`apkrun-seed`) | a lab Mac that installs every macOS 27.x beta and release and runs the full T2 set and gate checks (R-16) | as a lab Mac | §6 |

macOS cannot build AOSP ([../01-architecture/decisions/0003-cuttlefish-base-image.md](../01-architecture/decisions/0003-cuttlefish-base-image.md)). Intel Macs are not supported at all (Virtualization.framework arm64 guests need Apple Silicon).

---

## 2. Developer Mac

### 2.1 Hardware and OS

- Apple Silicon, macOS 27.0 or later. The deployment target of every host target is macOS 27.0 ([build-system.md](build-system.md) §2).
- 150 GB free disk is a working minimum. The large items are the ANGLE checkout and build (about 11 GB, [../02-design/graphics.md](../02-design/graphics.md) §5), Cuttlefish downloads and bundles under `Images/work/` (about 10 GB per build ID), the runtime image and userdata under `APKRUN_HOME`, and Xcode DerivedData.
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
xcrun swift --version # Swift 6.2 or later
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
| `rustup` | Rust toolchain manager (§2.6) |
| `meson`, `ninja`, `pkg-config` | virglrenderer and libepoxy builds ([build-system.md](build-system.md) §6) |
| `jq` | scripts that read `ThirdParty.lock.json` and `components.json` |
| `fdroidserver` | the F-Droid test repository (`fdroid update`, [../02-design/update-system.md](../02-design/update-system.md) §4.5); needed only for #051 work and on CI runners |
| cask `temurin@17` | JDK 17 (§2.5) |
| cask `android-commandlinetools` | `sdkmanager` (§2.5) |

Homebrew versions float. Tools whose output is committed (protoc, protoc-gen-swift, buf, XcodeGen) are therefore not taken from Homebrew but pinned and installed by `scripts/bootstrap` (§2.7). ANGLE uses its own pinned `depot_tools`, fetched by `ThirdParty/build/build-angle.sh`.

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
| Gradle | the wrapper in `Guest/gradle/wrapper/` (with `distributionSha256Sum`) | Never install Gradle globally. `Tests/Fixtures/AndroidApps/` has its own wrapper with the same version. |
| AGP, Kotlin, coroutines, protobuf-javalite, the ktfmt Gradle plugin | `Guest/gradle/libs.versions.toml` | chosen in #033 ([coding-conventions.md](coding-conventions.md) §2) |
| Android SDK platform | `platforms;android-37` | compileSdk and targetSdk 37 |
| Build tools | `build-tools;37.0.0` | `apksigner`, `zipalign`; `apksigner` is also the reference for `scripts/dev/verify-corpus.sh` |
| Platform tools | `platform-tools` (latest) | `adb`, used by `ADBForwardGuestTransport` ([../02-design/guest-protocol.md](../02-design/guest-protocol.md) §13.2) and by the M1–M4 ADB control channel |
| NDK | `ndk;28.2.13676358` (r28c) | the NDK pin for `apkrun_vsockd` and native fixtures (§2.6). r28 is the first NDK that links 16 KB-aligned ELF by default, which the 16K-page product needs. |

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
sdkmanager --sdk_root="$ANDROID_HOME" --install \
  "platform-tools" "platforms;android-37" "build-tools;37.0.0" "ndk;28.2.13676358"
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
rustup show # inside Guest/vsockd, installs the pinned toolchain and target
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
| `APKRUN_TEST_LINUX_DIR` | unset (default `build/test-linux/`) | T2 Linux guest tests (§4) |
| `APKRUN_AOSP_BUILDER` | `user@host` of the Linux builder | `scripts/aosp/remote-build.sh` (§5.5) |
| `APKRUN_CI` | `1` on CI runners only | turns "skip with a message" into a failure (§6.4) |

Put the exports in `~/.zprofile`. Nothing in this table is committed to the repository.

### 2.9 Where the pins live

| Pin | File |
|---|---|
| Xcode | `.xcode-version` |
| Swift packages | swift-protobuf and swift-argument-parser: exact versions in `Package.swift`, resolved in `Package.resolved`. Sparkle: exact version in `project.yml` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2) |
| protoc, buf, XcodeGen, cargo-ndk, and their hashes | `scripts/tool-versions.env` |
| Gradle, AGP, Kotlin, Android libraries | `Guest/gradle/wrapper/gradle-wrapper.properties`, `Guest/gradle/libs.versions.toml` |
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

- Downloads resume. `fetch.json` records name, size, and SHA-256. A second run downloads nothing and re-verifies.
- Fallback without a key: download `aosp_cf_arm64_only_phone-img-16373615.zip` from the ci.android.com web UI into the same directory, then run the same command. `fetch` then only verifies ([../02-design/android-image.md](../02-design/android-image.md) §2.2).
- The prebuilt image is for development only (M1–M4). Do not publish it or bundles made from it ([legal-and-licensing.md](legal-and-licensing.md) §2).
- Build a development bundle and install it with the commands in [build-system.md](build-system.md) §10.

### 3.3 Cuttlefish reference host (#064)

The reference boot capture ([../02-design/android-image.md](../02-design/android-image.md) §8) needs a Linux machine that runs real Cuttlefish. Preferred: an arm64 Linux VM with nested virtualization on an M3 or later Mac.

| Step | Detail |
|---|---|
| VM | arm64 Debian 12 or Ubuntu 24.04 in any VZ-based VM tool that sets `VZGenericPlatformConfiguration.isNestedVirtualizationEnabled` (check `VZGenericPlatformConfiguration.isNestedVirtualizationSupported` first). 8 vCPUs, 16 GB RAM, 120 GB disk. |
| KVM | `ls -l /dev/kvm` must exist inside the VM. Add the user to the `kvm` group. |
| Host tools | install `cuttlefish-base` and `cuttlefish-user` from the android-cuttlefish arm64 packages, then reboot the VM |
| Artifacts | the same build as §3.2, plus `cvd-host_package.tar.gz` of that build |
| Capture | `Images/tools/reference/capture.sh <profile>` for `default`, `target`, `swiftshader` ([../02-design/android-image.md](../02-design/android-image.md) §8.2) |
| Output | copy the capture to `Images/reference/<buildId>/<profile>/` on the Mac and commit it |

Without an M3 Mac, use an arm64 Linux machine (bare metal or cloud), or as a last resort an x86_64 Linux host with QEMU TCG.

---

## 4. Test Linux guest

M0 (#003–#007, then #063 and #019) boots a small Linux guest before Android ([../02-design/vm.md](../02-design/vm.md) §12).

```bash
scripts/fetch-test-linux.sh # Alpine linux-virt kernel, hash from ThirdParty.lock.json, decompressed
scripts/build-test-initramfs.sh # pinned minirootfs + modules + socat + Tests/Fixtures/linux/init
xcodebuild test -scheme IntegrationTests \
  -only-testing:IntegrationTests/LinuxGuestTests # T2, 60 s timeout per boot
```

- Both scripts write to `build/test-linux/` (override with `APKRUN_TEST_LINUX_DIR`). The initramfs build runs on macOS with `cpio` and `gzip` from the base system and needs no Linux machine.
- The tests look for `APKRUN-TEST: boot ok`, one `APKRUN-TEST: <name> ok` per requested check (`apkrun.test=blk,net,vsock,ports,rng,gpu,virgl`), and `APKRUN-TEST: done`, with `apkrun.test.poweroff=1`.
- When the artifacts are missing, the tests skip with a message that names the two scripts. With `APKRUN_CI=1` a missing artifact is a failure.
- VM tests need `com.apple.security.virtualization`. They therefore run inside the signed test host `APKRunTestHost`, not under `swift test` ([build-system.md](build-system.md) §12.4).

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
docker image inspect --format '{{.Id}}' apkrun-aosp-builder # record this digest
```

### 5.3 Source checkout

```bash
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://android.googlesource.com/platform/manifest \
  -b aosp-android-latest-release --partial-clone --clone-filter=blob:limit=10M
cp <apkrun checkout>/Guest/product/manifest/pinned.xml.repo/manifests/apkrun-pinned.xml
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
lunch apkrun_arm64-trunk_staging-userdebug # or apkrun_arm64-trunk_staging-user for release
export BUILD_NUMBER=ar000123 # from the builder's counter, §5.7
m
m dist DIST_DIR=out/dist
ls out/dist/apkrun_arm64-img-ar000123.zip
```

The `*-img-*.zip` then goes through the same pipeline as the stock image, starting with inventory ([../02-design/android-image.md](../02-design/android-image.md) §3–§10).

### 5.5 Remote workflow from a Mac

Developers work on the Mac and drive the builder over SSH.

```bash
export APKRUN_AOSP_BUILDER=builder@aosp-builder.example
git push origin task/035-apkrun-aosp-product # the builder fetches this commit
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
| `apkrun-ci` | a bare-metal Apple Silicon Mac on macOS 27 with the §2 toolchain, a logged-in CI user, and an APFS scratch volume | T0 and T1 on every pull request, static checks, short fuzz runs ([build-system.md](build-system.md) §15) |
| `apkrun-lab` | every lab Mac, set up as in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.6 | T2 suites on `main` and on labelled pull requests, nightly T3, performance for information, nightly notarization |
| `apkrun-reference` | the reference Mac (OQ-02); it also carries `apkrun-lab` | gate checks G1–G9, NFR numbers, the release smoke matrix |
| `apkrun-seed` | the seed lab Mac | the full T2 set and the closed gate checks on each new macOS build (`macos-seed.yml`) |
| `apkrun-aosp` | the AOSP builder of §5 (the development builder, not the image build machine) | nightly `userdebug` product builds |

GitHub-hosted `ubuntu-latest` runners take the Linux-only jobs: `cargo test` with the T1 `vsock_loopback` test, `ruff`, JSON schema checks, the F-Droid test repository build, the upstream security check, and the weekly feed re-signing. Hosted macOS runners are VMs, so they may run static checks only ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.1). `user` release images are built by a maintainer on the image build machine (§5.6), never by a runner.

A lab Mac has one runner slot, so it runs one job, and therefore one VM, at a time.

### 6.2 Runner setup

- Create a dedicated macOS user `apkrun-ci` with automatic login. The runner runs as a LaunchAgent in that user's GUI session, because T1/T2/T3 need Metal, windows, `SMAppService` registration, and a user launchd domain.
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

The harness checks `AXIsProcessTrusted` at start and fails with a message that names this section if the permission is missing.

### 6.4 Secrets and credentials

| Secret | Where | Used by |
|---|---|---|
| `APKRUN_ANDROID_BUILD_API_KEY` | repository secret | fetch jobs |
| notarytool API key (`.p8`, key ID, issuer) | environments `signing` and `release`; on the lab Mac also a keychain profile `apkrun-notary` (`xcrun notarytool store-credentials`) | nightly notarization, release job |
| Developer ID Application certificate | environments `signing` and `release`, imported into a temporary keychain per job and deleted after it | nightly notarization, the Maintenance T2 suite (`ReleaseUpdateTest` bundles are Developer ID signed, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2), release job ([workflow.md](workflow.md) §9) |
| Sparkle EdDSA private key | environment `release` | release job only |
| Image Ed25519 signing key | environment `release` | image release and feed re-signing jobs only ([workflow.md](workflow.md) §10) |

- The environment `release` accepts only tags `v*` and `image-*` and the `main` branch, and every job waits for a maintainer's approval.
- The environment `signing` accepts `main` and pull requests with the label `t2-maintenance` or `run-t2`. A pull request job waits for a maintainer's approval before it gets the certificate.
- Pull request jobs never see release secrets. Tests that need a secret skip with a message when it is absent, except on runners with `APKRUN_CI=1`, where the job fails instead.

---

## 7. Verification checklist

`scripts/bootstrap` installs what it can (pinned tools, venv, `local.properties`) and then checks everything. `scripts/bootstrap --check` only checks. A fresh machine is ready when every line reports `ok`.

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
| Free disk | `df -g.` | ≥ 150 GB (warning only) |

Then run the first build ([build-system.md](build-system.md) §1):

```bash
scripts/generate-project.sh
swift build && swift test # a clean checkout builds and passes (NFR-DEV-02)
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
