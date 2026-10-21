# M1 Android bring-up

M1 brings the stock Cuttlefish arm64 userdebug build 16373615 (Android 17, API 37) up on Virtualization.framework with direct kernel boot, and it closes gate G2: the guest reaches `sys.boot_completed=1`, the host detects it, and Android stays stable. A developer reaches the guest with ADB over vsock on host loopback only, and installs, launches, stops, and uninstalls HelloText without a display. The Python tools in `Images/tools/` turn the downloaded artifacts into a signed runtime image bundle, which ImageCore installs. The reference build is 16373615 ([ADR-0003](../../01-architecture/decisions/0003-cuttlefish-base-image.md)). M1 delivers the Android ARM64 boot item of v0.1 ([roadmap.md](../roadmap.md) §3.1); #18 delivers the ADB half of CLI launch, which #28 completes.

---

## #9 Acquire and inventory ARM64 Cuttlefish artifacts

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #2 |
| Design | [android-image.md](../../02-design/android-image.md) §2, §3.1; [android-image-manifest.md](../../03-reference/android-image-manifest.md) §2–§4; [environment-setup.md](../../05-development/environment-setup.md) §3.1–§3.2 |
| Code | `Images/tools/apkrun_image/` (`fetch.py`, `inventory.py`, `sparse.py`, `lp.py`), `scripts/inventory-cuttlefish.py`, `Images/manifests/16373615/inventory.json`, `ThirdParty/ThirdParty.lock.json` |

**Goal.** A developer fetches pinned build 16373615. The committed, reproducible `inventory.json` classifies every file by its content, not by its name.

**Result.** `fetch` resumes interrupted downloads, writes `fetch.json`, and downloads nothing on a second run. It opens the originals read-only. `inventory` lists unknown files, detects renamed files, and produces byte-identical output on each run. The API key is never committed, printed, or logged. The prebuilt image is for development only (M1–M4). Tests: T0 in `Images/tools/tests/` (`test_inventory.py`, `test_sparse.py`, `test_lp.py`); T1 in `test_fetch.py` and `test_inventory_real.py`.

---

## #10 AndroidImageManifest

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #9 |
| Design | [android-image.md](../../02-design/android-image.md) §3.2–§3.3; [android-image-manifest.md](../../03-reference/android-image-manifest.md) §7 |
| Code | `Images/tools/apkrun_image/manifest.py`, `Images/tools/schemas/android-image-manifest.schema.json`, `Images/manifests/16373615/android-image.json`, `Packages/ImageCore/Sources/ImageCore/Manifest/` |

**Goal.** One schema-validated `android-image.json` describes build 16373615. Every later tool takes file names and roles from it.

**Result.** The manifest records the build ID, Android version, architecture, boot and vendor boot images, the `super` logical partitions (`system`, `vendor`, `product`), `userdata`, `vbmeta`, and `metadata` as a blank partition. `AndroidImageManifest` and `AndroidImageManifestValidator` in ImageCore decode and validate it. Invalid manifests fail with a message that names the file or field, the expected value, the value found, and the fix. No code opens an image by a literal file name. The `fetch.json` sidecar is unsigned and is not proof of source origin. Tests: T0 in `Images/tools/tests/test_manifest.py` and `Packages/ImageCore/Tests/ImageCoreTests/AndroidImageManifestTests.swift`; T1 `manifest --check` on the real archive.

---

## #65 Reference boot capture

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #9 |
| Design | [android-image.md](../../02-design/android-image.md) §7.7, §8; [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3 |
| Code | `Images/tools/reference/` (`capture.sh`, `compare_boot.py`, `guest-capture.txt`), `Images/tools/tests/test_compare_boot.py`, `Images/tools/tests/test_reference_capture.py` |

**Goal.** Tools record a Cuttlefish boot of build 16373615 and diff any later capture against that record.

**Result.** `compare_boot.py` reports differences in ten categories and fails on any unexplained difference. `guest-capture.txt` runs unchanged over `adb exec-out`. The `VIRTUAL_DEVICE_*` boot strings and their timing are in [android-image.md](../../02-design/android-image.md) §7.7. Not done: the `default`, `target`, and `swiftshader` profiles, normalized captures, schema-version-3 `host.json`, and a serial-shell run of `guest-capture.txt`; dropped.

---

## #11 Extract Android kernel and ramdisk

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #9, #10 |
| Design | [android-image.md](../../02-design/android-image.md) §4.1, §6.1; [0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Code | `Images/tools/apkrun_image/` (`bootimg.py`, `kernel.py`, `bootconfig.py`, `avb.py`), `Images/tools/layouts/cuttlefish-phone-arm64.json`, `Images/tools/tests/` |

**Goal.** `extract` derives the kernel, combined ramdisk, vendor bootconfig, kernel command line, and extraction metadata from the manifest. It leaves the original images unchanged.

**Result.** Outputs go to `Images/work/<buildId>/boot/`, which is not committed. The kernel is an uncompressed arm64 `Image` that passes the VM validation rules ([vm.md](../../02-design/vm.md) §3). The layout's image layer (layer 2) and `cmdline.additions` hold the reference values; the command line adds only `console=hvc0`. Tests: T0 `Images/tools/tests/test_bootimg.py`, `test_kernel.py`, `test_bootconfig.py`, `test_avb.py`; T1 `test_extract.py`, which checks that original hashes do not change and that outputs are deterministic.

---

## #12 GPT disks and partition mapping

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #6, #10, #11 |
| Design | [android-image.md](../../02-design/android-image.md) §4.2, §5.3; [vm.md](../../02-design/vm.md) §4 |
| Code | `Images/tools/apkrun_image/{sparse,gpt,layout}.py`, `Packages/ImageCore/Sources/ImageCore/Disks/GPTDisk.swift`, `Packages/ImageCore/Sources/ImageCore/Disks/InstanceDiskProvisioner.swift`, `Images/reference/vz/26A434/topology.txt`, `Tests/IntegrationTests/LinuxGuestTests/` |

**Goal.** Two raw GPT disks are built from the manifest and the layout. They attach to a VZ guest in a fixed order, and the guest sees the expected partition names and sizes.

**Result.** `os.img` is read-only and `userdata.img` is read-write. The instance disk is an APFS clone that grows sparse. `InstanceDiskProvisioner` refuses a non-APFS volume with `cloneUnsupported`, so `APKRUN_HOME` must be on the bundle's volume. The disk mapping is data-driven: no partition or file name appears in Python or Swift code. The `boot_devices` value is recorded in `topology.txt` and in [android-image.md](../../02-design/android-image.md) §5.3. Tests: T0 `test_gpt.py`, `test_sparse.py`, `test_layout.py`, and `GPTDiskTests.swift`; T1 APFS clone tests; T2 `LinuxGuestAndroidDiskLayoutTests`.

---

## #13 Boot the Android kernel

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #11, #12 |
| Design | [android-image.md](../../02-design/android-image.md) §5.1, §9.1; [vm.md](../../02-design/vm.md) §2–§4; [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.1–§3.3 |
| Code | `Images/tools/apkrun_image/bundle.py`, `Packages/ImageCore/Sources/ImageCore/Boot/`, `Packages/ImageCore/Sources/ImageCore/Instance/`, `Packages/RuntimeCore/Sources/RuntimeCore/Supervisor/`, `CLI/apkrun/Dev/`, `Tests/IntegrationTests/AndroidBootTests/` |

**Goal.** `apkrun dev boot` starts a VM from the Android kernel, the per-boot initrd, the command line, and two disks. The serial log shows the kernel passing early init and detecting the virtio devices.

**Result.** `AndroidBootPlanner` builds an Android `VMDefinition` that `VMDefinitionValidator` accepts. The bootconfig is the initrd trailer, and `/proc/bootconfig` equals the merged block; `/proc/cmdline` ends with the image's command line. A bootconfig over 16 KiB fails the build, and conflicting keys fail with `bootconfigConflict`. A kernel panic ends the boot at once with `.kernelPanic`. Each boot logs the image version, bootconfig hash, and disk IDs (`io.apkrun.image`, category `boot`). Tests: T0 in `Packages/ImageCore/Tests/ImageCoreTests/` and `Packages/RuntimeCore/Tests/RuntimeCoreTests/`; T2 `AndroidBootTests.testKernelBoot` and `testTruncatedRamdiskStallsBoot`.

---

## #14 Reach Android init

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #13 |
| Design | [android-image.md](../../02-design/android-image.md) §6.1, §13; [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.3 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Boot/BootSignals.swift`, `Images/tools/layouts/cuttlefish-phone-arm64.json`, `Tests/IntegrationTests/Support/AndroidShellConsole.swift`, `Tests/IntegrationTests/AndroidBootTests/`, `Images/reference/16373615/expected-differences.yaml` |

**Goal.** First-stage init finds the boot devices, maps the dynamic partitions, and switches to second-stage init, which starts services. The Android serial shell answers commands.

**Result.** The console log shows `init: init first stage started!`, `init: init second stage started!`, and at least one `init: starting service` line. `BootSignals` emits the `.init` signal and the `ANDROID_INIT` marker. Over the serial shell, SELinux is `Enforcing` with no AVC denial and no permissive workaround. Each deviation from Cuttlefish is a row CF-16 to CF-19 in [android-image.md](../../02-design/android-image.md) §13 and an entry with a reason in `expected-differences.yaml`. Tests: T0 `.init` golden test over captured VZ console logs; T2 `AndroidBootTests.testReachesInit`.

---

## #96 Cuttlefish host-service substitution

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #14 |
| Design | [android-image.md](../../02-design/android-image.md) §7.1–§7.4; [vm.md](../../02-design/vm.md) §6.2, §8 |
| Code | `Images/tools/layouts/cuttlefish-phone-arm64.json` (`consolePorts`, `bootconfig.image`), `Packages/RuntimeCore/Sources/RuntimeCore/Boot/ConsolePortPlan.swift`, `Tests/Fixtures/linux/init`, `Tests/IntegrationTests/AndroidBootTests/`, `Tests/IntegrationTests/LinuxGuestTests/` |

**Goal.** Every Cuttlefish host dependency has a verified substitute. Android userspace does not block or crash-loop on a missing host service, and the guest network works.

**Result.** The layout's `consolePorts` give each port a role. Ports 10–19 share one multiport device, and `RuntimeSupervisor` runs the sensors responder on `hvc18`. KeyMint and Gatekeeper are in-guest, selected by `androidboot.vendor.apex.*` keys. The `APKRUN-PORT` marker check passes for the eight `hvc` ports of the pinned test kernel, so the 20-port check skips; the Android kernel creates `hvc0`–`hvc19`. The `testNetwork` DNS stage runs as root; #36 tracks shell access. Services stay unless they break boot, stability, or resource use. Tests: T0 `ConsolePortPlan` in RuntimeCore tests; T2 `LinuxGuestTests.testTwentyConsolePorts`, `AndroidBootTests.testHostServiceSubstitutes`.

---

## #15 Reach system_server and boot_completed

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #14, #96 |
| Gate | G2 |
| Design | [android-image.md](../../02-design/android-image.md) §7.7, §8; [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2–§3.3; [cli.md](../../02-design/cli.md) §5 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Boot/`, `Packages/RuntimeCore/Sources/RuntimeCore/Supervisor/RuntimeSupervisor.swift`, `Images/tools/reference/compare_boot.py`, `Tests/AcceptanceTests/G2/`, `Tests/IntegrationTests/AndroidBootTests/`, `scripts/run-gate.sh` |

**Goal.** The stock image reaches `sys.boot_completed=1`, the host detects it, and Android stays up for 10 minutes. The VZ boot differs from the reference only in explained ways.

**Result.** `BootPhaseDetector` emits `.kernel`, `.init`, `.systemServer`, and `.bootCompleted` with their PerfMarkers. It fails a boot with a typed error on panic, boot failure, timeout, or stall. Each boot writes a `perf/boots.jsonl` record. `apkrun dev console [--android-shell]` serves the console through a socket with mode 0600 in a 0700 directory, removed at stop. Gate G2 runs as five cold boots through `scripts/run-gate.sh G2`, with the conditions of [roadmap.md](../roadmap.md) §2. Tests: T0 `BootWatch` and `BootPhaseDetectorTests`; T1 `DevConsoleSocketTests`; T2 `AndroidBootTests.testBootCompleted`, `testPhasesInOrder`, and `testDevConsoleShell`.

---

## #107 Update Android boot tests for runtime state snapshots

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #15 |
| Design | [state-machines.md](../../01-architecture/state-machines.md) §1; [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2–§3.3 |
| Code | `Tests/IntegrationTests/AndroidBootTests/AndroidBootTests.swift` |

**Goal.** Keep the Android boot integration test target buildable after `RuntimeSupervisor` events began carrying `RuntimeStateSnapshot` values.

**Steps.**
1. **Collect snapshot states.** Update the boot phase test to pass `snapshot.state` to its `RuntimeState` collector. **Check:** the `IntegrationTests` target builds for testing.
2. **Verify the boot phase test.** Run `AndroidBootTests.testPhasesInOrder` against the test Android VM. **Check:** the ordered boot phases still match the expected sequence.

**Tests.**
- T2: `AndroidBootTests.testPhasesInOrder`.

**Done when.**
- The IntegrationTests target builds for testing.
- `AndroidBootTests.testPhasesInOrder` passes on the real VM.

---

## #16 ADB debugging over vsock

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #15, #8 |
| Design | [android-image.md](../../02-design/android-image.md) §7.3; [vm.md](../../02-design/vm.md) §9.3; [runtime-daemon.md](../../02-design/runtime-daemon.md) §3.5 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Android/AdbClient.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Supervisor/RuntimeSupervisor.swift`, `CLI/apkrun/Dev/`, `Tests/IntegrationTests/AndroidADBTests/` |

**Goal.** In developer mode, `adb -s 127.0.0.1:6520` reaches the guest's `adbd` through vsock port 5555, from host loopback only, and the standard ADB commands work.

**Result.** ADB listens on `127.0.0.1` only, and connections to other addresses are refused. With developer mode off, nothing listens on port 6520. `apkrun dev adb [<args>…]` runs ADB commands, and the ADB readiness signals feed `BootPhaseDetector`. Ctrl-C stops Android with `reboot -p` and forces a stop after 20 s. The one-VM rule of [test-strategy.md](../test-strategy.md) §3.6 applies until #100 decides on parallel VM runs. Tests: T0 `AdbClientTests`, `BootPhaseDetectorTests`, and `DevAdbTests`; T1 `VsockLoopbackForwarderSystemTests`; T2 `AndroidADBTests`.

---

## #66 Runtime image bundle

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #15 |
| Design | [android-image.md](../../02-design/android-image.md) §10.1–§10.3; [runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §5; [0011-runtime-image-bundle.md](../../01-architecture/decisions/0011-runtime-image-bundle.md) |
| Code | `Images/tools/apkrun_image/{bundle,sign}.py`, `Images/tools/schemas/runtime-image-manifest.schema.json`, `Packages/ImageCore/Sources/ImageCore/{Store,Bundle}/`, `CLI/apkrun/Dev/`, `scripts/release/check-release-build.sh` |

**Goal.** One signed, deterministic bundle built from the stock build installs with `apkrun dev image install` into `Images/<imageVersion>/`, and it boots to `boot_completed`.

**Result.** Two builds from the same inputs give identical `SHA256SUMS`, `manifest.json`, and `manifest.sig`. `ImageStore` installs atomically and rejects an untrusted or bad signature, an extra file, and a hash mismatch. Release builds refuse image test and developer keys; the test key `Tests/Fixtures/signing/test-image-ed25519` is for tests only. Not done: compatibility checks (`incompatibleRuntime`, `incompatibleProtocol`) at install and boot (#67, #59); archive install (#59); Release builds refuse every bundle until release image keys exist (#94). Tests: T0 in `Images/tools/tests/` and `Packages/ImageCore/Tests/ImageCoreTests/`; T1 `ImageStore` tests; T2 boot from the installed bundle.

---

## #17 Install HelloText APK

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #16 |
| Design | [package-store.md](../../02-design/package-store.md) §6.1; [cli.md](../../02-design/cli.md) §5 |
| Code | `Tests/Fixtures/AndroidApps/` (module `HelloText`), `Tests/Fixtures/signing/test-fixture-a.jks`, `scripts/build-fixtures.sh`, `Packages/RuntimeCore/Sources/RuntimeCore/Android/AdbClient.swift`, `Tests/IntegrationTests/AndroidPackageTests/` |

**Goal.** HelloText builds reproducibly. `adb install` installs it through a PackageInstaller session, PackageManager reports its metadata, and it can be uninstalled.

**Result.** The HelloText fixture is specified in [test-strategy.md](../test-strategy.md) §4.2. `scripts/build-fixtures.sh` writes `Tests/Fixtures/AndroidApps/out/HelloText.apk` (git-ignored), signed with the test-only key `test-fixture-a.jks`. Its `--check-reproducible` mode compares badging, dex hashes, and archive listing. The counter persists across a force-stop, and a debug-only ADB receiver, which release builds omit, reads it. A second uninstall is refused, and a reinstall succeeds. The `input tap` check passes only on an ODM-overlay variant; tapping on the product image waits for #27. Tests: T0 JVM `CounterStoreTest` and `DebugCounterCommandsTest`, and the `AdbClient` parser tests; T1 the reproducibility check; T2 `AndroidPackageTests.testInstallHelloText` and `testUninstallHelloText`.

---

## #18 Launch HelloText APK

| Field | Value |
|---|---|
| Milestone | M1 (v0.1) |
| Depends on | #17 |
| Design | [cli.md](../../02-design/cli.md) §5; [roadmap.md](../roadmap.md) §3.1 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Android/AdbClient.swift`, `Tests/IntegrationTests/AndroidPackageTests/` |

**Goal.** HelloText's `MainActivity` starts explicitly over ADB, and the process and ActivityManager state show it running. It can then be stopped. No rendering is required.

**Result.** `AdbClient` starts the Activity by component name (`am start -W`), reads `pidof` and `dumpsys activity activities`, and force-stops the app. The tests pass with `--gpu none`. The `apkrun` launch command belongs to #28. Tests: T0 `AdbLaunchParserTests` and the `AdbClient` launch cases; T2 `AndroidPackageTests.testLaunchHelloText` and `testInstallLaunchStopUninstall`.
