# M0 Repository and VM foundation

M0 proves that Virtualization.framework works for APKRun before Android is involved. It delivers the repository and build baseline, DiagnosticsCore, and a Linux test guest that exercises the serial console, virtio-blk, NAT networking, virtio-vsock, and a host-implemented virtio device. It closes gate G1 ([roadmap.md](../roadmap.md) §2). It delivers no v0.1 feature directly; #012–#014 (G2) and #019 (virtio-gpu) build on it.

---

## #001 Bootstrap Xcode workspace

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | None |
| Design | [modules.md](../../01-architecture/modules.md) §1, §3; [build-system.md](../../05-development/build-system.md) §2; [cli.md](../../02-design/cli.md) §3.2 |
| Code | `Package.swift`, `project.yml`, `Packages/*/`, `CLI/apkrun/`, `Daemon/apkrund/`, `Apps/`, `scripts/bootstrap`, `scripts/generate-project.sh`, `scripts/smoke-products.sh` |

**Goal.** A clean checkout on an Apple silicon Mac with macOS 27 builds all five products and passes `swift test`. `apkrun` prints its version and help, and APKRun.app and apkrund start and exit cleanly.

**Result.** `Package.swift` declares the 16 library modules, the `apkrun` executable, and the `EmbeddedRuntime` trait, with one placeholder T0 test per module. `project.yml` generates the ignored `APKRun.xcodeproj` with the pinned XcodeGen. The CLI has `version`, the JSON envelope, and exit codes; without an embedded Info.plist its version is `0.0.0-dev`. Golden tests are in `CLI/apkrun/Tests/`; the T1 products smoke test is `scripts/smoke-products.sh`.

---

## #061 Diagnostics foundation

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #001 |
| Design | [diagnostics.md](../../02-design/diagnostics.md) §2–§4; [error-catalog.md](../../03-reference/error-catalog.md) §5, §16; [cli.md](../../02-design/cli.md) §3.2 |
| Code | `Packages/DiagnosticsCore/` (`ErrorCatalog/errors.json`, `Sources/`), `scripts/errorgen.swift`, `scripts/check-logging.sh`, `scripts/check-compile-fail.sh`, `scripts/build/stamp-commit.sh`, `CLI/apkrun/Commands/Logs.swift` |

**Goal.** Every process logs through `APKLogger` with privacy and operation IDs, throws typed `APKRunError`s whose texts come from `errors.json`, records performance markers, and reports health. The CLI prints errors in the three-line format. `apkrun logs` falls back to the file mirrors when `log` fails or returns nothing within 30 s.

**Result.** `DiagnosticsCore` provides `APKLogger`, `OperationContext`, the generated `ErrorCatalog.generated.swift`, `PerfTimeline`, the health types, and `DiagnosticsCoreTestSupport`. Log entries made inside an operation carry `op=` with the first 8 hex digits. Interpolating a `Sensitive` value, or an interpolation without privacy, does not compile. Tests: T0 in `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`, T1 in `DiagnosticsCoreSystemTests/`, compile-fail fixtures in `Tests/Fixtures/compile-fail/`. Known limit: `log show` as a standard (non-admin) user is unverified; OQ-04 tracks it.

---

## #062 CI and module dependency checks

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #001 |
| Design | [build-system.md](../../05-development/build-system.md) §3, §4; [modules.md](../../01-architecture/modules.md) §3 |
| Code | `.github/workflows/ci.yml`, `.github/workflows/ci-policy.yml`, `scripts/ci/run-checks.sh`, `scripts/check-module-deps.sh`, `scripts/check-lock.sh`, `scripts/check-todos.sh`, `scripts/check-format.sh`, `ThirdParty/ThirdParty.lock.json`, `.swift-format`, `scripts/tests/` |

**Goal.** Every pull request gets static checks, builds, and T0 tests on fresh GitHub-hosted runners. A forbidden import, an unpinned dependency, a `TODO` without a task number, a format error, stale generated code, a failing build, or a failing required test blocks the merge.

**Result.** `ci.yml` runs the `lint`, `codegen`, `build`, and `test-swift` jobs. A change to protected CI control files needs an approval from a non-author reviewer of the current head and the `ci-policy-approved` label, or `workflow-policy` fails. The allowed module graph is read from [modules.md](../../01-architecture/modules.md) §3. Fixtures for the checks are in `scripts/tests/`, run by `lint`.

---

## #002 VMDefinition and VM validation

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #001, #061 |
| Design | [vm.md](../../02-design/vm.md) §2–§4; [state-machines.md](../../01-architecture/state-machines.md) §1; [error-catalog.md](../../03-reference/error-catalog.md) §5.2 |
| Code | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/` (`Definition/`, `Validation/`, `Framework/`, `State/`), `Packages/VirtioDeviceCore/Sources/VirtioDeviceCore/` (descriptor and protocol only) |

**Goal.** A `VMDefinition` value describes a VM without Android concepts. `VMDefinitionValidator` accepts only definitions that Virtualization.framework can boot, and it reports every broken rule as a typed error. No `VZVirtualMachine` is created.

**Result.** `VMDefinitionValidator` is the only way to create a `ValidatedVMDefinition`. Several broken rules yield one `.configurationInvalid` with every failure. The `VMState` transition table allows exactly the edges of [state-machines.md](../../01-architecture/state-machines.md) §1. A `VZVirtualMachine` is created only from a configuration that passed `validate()`. Kernels that are not uncompressed arm64 `Image` files (gzip, lz4, zboot) are rejected. Summaries and errors contain no paths. Tests: T0 in `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`.

---

## #003 Boot minimal ARM64 Linux

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #002 |
| Gate | G1 |
| Design | [vm.md](../../02-design/vm.md) §4, §9, §12; [state-machines.md](../../01-architecture/state-machines.md) §1; [decisions/0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md) |
| Code | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/`, `Packages/RuntimeHost/Sources/RuntimeHost/Dev/`, `CLI/apkrun/Dev/DevLinux.swift`, `scripts/fetch-test-linux.sh`, `scripts/build-test-initramfs.sh`, `scripts/run-gate.sh`, `Tests/Fixtures/linux/`, `Tests/IntegrationTests/LinuxGuestTests/`, `Tests/AcceptanceTests/G1LinuxBoot/` |

**Goal.** A pinned ARM64 Linux kernel and initramfs boot through `VZLinuxBootLoader` under `VMController`, and the guest prints `APKRUN-TEST: boot ok` on `hvc0`. Ten boots in a row pass on the reference Mac, which closes G1.

**Result.** `VMController` moves the VM through `stopped → starting → running → stopping → stopped`. A failed start ends in `failed` with a `VMFailure`, and `reset()` returns to `stopped`. VZ objects are used only on `io.apkrun.vm.queue`. `apkrun-dev dev linux` exits 0 only when every check prints `ok`, and it exits 75 while the instance lock is held. Tests: T0 `VirtualMachineCoreTests`; T2 `Tests/IntegrationTests/LinuxGuestTests/` (suite `LinuxGuest`); T3 `Tests/AcceptanceTests/G1LinuxBoot/` via `scripts/run-gate.sh G1`.

---

## #004 Serial console logging

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Design | [vm.md](../../02-design/vm.md) §6; [diagnostics.md](../../02-design/diagnostics.md) §3.3; [filesystem-layout.md](../../01-architecture/filesystem-layout.md) §2 |
| Code | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Console/`, `CLI/apkrun/Dev/DevConsole.swift`, `Tests/IntegrationTests/LinuxGuestTests/ConsoleTests.swift` |

**Goal.** Guest serial output appears live and persists in `vm/console.log` under the logs root. The log survives a forced stop, a guest panic, and a host crash up to 250 ms before the crash.

**Result.** `ConsoleLogWriter` rotates the log at 20 MiB with five generations, keeps the last five per-boot copies, and calls `fsync` every 250 ms or every 64 KiB. Each line has wall-clock and monotonic prefixes; the bytes are otherwise unchanged and unredacted. The host never writes to `.log` or `.silent` ports, and it writes to `.systemConsole` only in `apkrun dev console`. Write errors appear in the `vm.consoleWriter` health check. Tests: T0 in `VirtualMachineCoreTests`, T2 in `ConsoleTests.swift`.

---

## #005 virtio-blk storage

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Design | [vm.md](../../02-design/vm.md) §2–§5 |
| Code | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Validation/`, `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Framework/VZConfigurationBuilder.swift`, `Tests/Fixtures/linux/make-test-disks.sh`, `Tests/IntegrationTests/LinuxGuestTests/BlockTests.swift` |

**Goal.** The Linux test guest sees read-only and read-write virtio-blk disks in `VMDefinition.disks` order, each identified by its serial. It formats, writes, reboots, and recovers an ext4 file system on the read-write disk. It cannot write to the read-only disk.

**Result.** Disk validation rejects missing, non-regular, dangling, duplicate, unreadable, unwritable, and badly identified disks. APKRun code never relies on `vdX` letters or PCI slot numbers ([vm.md](../../02-design/vm.md) §5). `DiskSync.none` is refused outside tests. Disk logs show the role and file name, never the full path. Tests: T0 in `VirtualMachineCoreTests`, T1 in `VirtualMachineCoreSystemTests`, T2 in `BlockTests.swift`.

---

## #006 Guest networking

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Design | [vm.md](../../02-design/vm.md) §4, §7, §9.2 |
| Code | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Framework/VZConfigurationBuilder.swift`, `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/VMController.swift`, `Tests/Fixtures/linux/` (`init`, `udhcpc.script`, `network-errors.sh`), `Tests/IntegrationTests/LinuxGuestTests/NetworkTests.swift`, `Tests/AcceptanceTests/Network/` |

**Goal.** The Linux test guest gets an IP address from the VZ NAT DHCP server and fetches `generate_204` from an HTTP server on the host. The nightly check also resolves and reaches `connectivitycheck.gstatic.com`. A disconnected network attachment is reported without stopping the VM.

**Result.** Networking uses only a Virtualization.framework NAT attachment: no bridged mode and no `com.apple.vm.networking` entitlement. The MAC is logged at configuration time, and the IP address, gateway, and DNS server come from the guest's report. A disconnect keeps the VM `running` and sets `vm.network` to `degraded`; the next start resets it. The external check proves reachability only, because BusyBox `wget` does not verify TLS. Tests: T0 in `VirtualMachineCoreTests`, T2 in `NetworkTests.swift`, T3 nightly in `Tests/AcceptanceTests/Network/`.

---

## #007 virtio-vsock

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Design | [vm.md](../../02-design/vm.md) §4, §8; [process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §3.1; [error-catalog.md](../../03-reference/error-catalog.md) §5.1 |
| Code | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Vsock/VsockConnection.swift`, `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/VMController.swift`, `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift` |

**Goal.** The host opens a vsock connection to a port in the Linux test guest, sends 1 MiB, and receives the same bytes back. A connection to an unused port fails with a typed error within its timeout, and the host detects a guest close.

**Result.** `VMController.connect(vsockPort:timeout:)` returns a `VsockConnection` with `read(upTo:)`, `write(_:)`, `close()`, and `closed`. The guest CID is 3 and the host CID is 2. Connections are host-to-guest only; no guest-to-host listener is registered. Failures are `.vsockConnectTimedOut`, `.vsockPortNotListening` (callers treat it as "not ready yet"), or `.vsockConnectFailed`. Over-limit unread input closes the connection with `bufferedInputLimitExceeded` after the buffered bytes drain. Tests: T0 in `VirtualMachineCoreTests`, T1 in `VirtualMachineCoreSystemTests`, T2 in `VsockTests.swift`.

---

## #063 VirtioDeviceCore and test virtio device

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Design | [graphics.md](../../02-design/graphics.md) §3, §8; [vm.md](../../02-design/vm.md) §3, §4, §9.5 |
| Code | `Packages/VirtioDeviceCore/Sources/VirtioDeviceCore/` (`API/`, `VZAdapter/`, `TestDevices/EntropyTestDevice.swift`), `Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTests/`, `Tests/IntegrationTests/LinuxGuestTests/EntropyDeviceTests.swift` |

**Goal.** A host-implemented virtio-rng device, built on the macOS 27 custom virtio device API, replaces the built-in entropy device. The Linux test guest reads 64 KiB of the device's seeded sequence from `/dev/hwrng`, and it reads again after a driver reset.

**Result.** `VirtioDeviceCore` provides the descriptor, queue, element, and guest-memory API and a VZ adapter. VZ objects are touched only on the device queue. Each element completes exactly once. A context from an old generation cannot reach the restarted device. `supportsSaveRestore` stays off (R-07). R-01 stays open until #019 and #028 settle it. Tests: T0 in `Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTests/`, T2 in `EntropyDeviceTests.swift`.
