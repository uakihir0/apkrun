# Test Strategy

This document defines the test tiers, the test infrastructure, the fixture apps, how gate checks run, the non-functional tests, the manual checks of each release, and the release tests. Each task lists its own tests in its milestone file ([issues/README.md](issues/README.md) §2). Design documents name the tier of each test they list. Where a design document disagrees with §2, §2 applies (§2.8).

---

## 1. Principles

| ID | Principle | Reference |
|---|---|---|
| P1 | Every module with logic has unit tests (T0). Pure logic is tested at T0, never only at T2. | |
| P2 | Integration tests use a real Android guest. A behavior that crosses the host/guest boundary is verified at T2 against a real image. Fakes alone never close such a task. | |
| P3 | Hardware acceptance runs on a real Apple silicon Mac. T2 and T3 run on bare-metal Apple silicon with macOS 27, never in a VM and never on Intel. | [../00-product/scope.md](../00-product/scope.md) §1 |
| P4 | Graphics is not complete on mocks. A graphics task is done only when its T2 test with a real guest and Metal passes. T1 replay tests do not replace it. | |
| P5 | Fixtures first. T2 and T3 behavior checks use the fixture apps (§4.2). A failing third-party APK is investigated only after the fixture for the same feature passes. | NFR-CMP-01 |
| P6 | Measure before optimizing. Performance work starts from a harness result (§7.1) and ends with a new one. | |
| P7 | Done means tested. A task is done when the tests of every tier in its Tests section pass, with logging, error handling, documentation, and the manual checks it lists. | [issues/README.md](issues/README.md) §4 |
| P8 | A skipped or quarantined test, or a test-only workaround, carries a TODO, a reason, and a tracking task. | NFR-DEV-04 |
| P9 | Only gate checks validate. The core architecture is not validated before G3 passes, and the product concept not before G9 passes. | [roadmap.md](roadmap.md) §2 |
| P10 | Lowest tier. A test lives in the lowest tier that can fail for the reason under test (§2.6). | |
| P11 | No sleeps for synchronization. Tests wait for markers (`APKRUN-TEST:` lines, boot and perf markers, `APKRUN-FIXTURE` events) with a timeout. | |
| P12 | Experiments are not tests. CI does not run `Experiments/`, and no test imports it. | NFR-DEV-05 |
| P13 | Security rules are tested negatively. Every policy has a test that tries the forbidden action and expects a refusal (§7.2). | |
| P14 | Tests use the product paths: `RuntimeService`, RuntimeCore, or the CLI. Not raw `adb shell` or `pm`, except the allowlist of §3.3. | #28 |
| P15 | Test hooks exist only in Debug builds (and in `ReleaseUpdateTest` where listed). A release check proves they are absent (§3.3). | [../02-design/diagnostics.md](../02-design/diagnostics.md) §12 |
| P16 | Scope discipline applies to tests. A task's tests do not depend on features of later tasks. | |

---

## 2. Tiers

### 2.1 Summary

| Tier | Name | Needs | Location ([../01-architecture/modules.md](../01-architecture/modules.md) §1) | Runner | Trigger | Budget | Required to merge |
|---|---|---|---|---|---|---|---|
| T0 | Unit and model | only the test process: no VM, GPU, network, other processes, or XPC | next to the code (§2.2) | `swift test`, Gradle JVM `test`, `cargo test`, `pytest` | every PR, every push to `main` | ≤ 10 min | yes |
| T1 | Component and host integration | real host resources, no VM | next to the code, `<Module>SystemTests` targets, UI test bundles (§2.3) | `swift test`, `xcodebuild test` (UI), Gradle, `fuzz-short` | trusted `main` runs; otherwise a real Apple silicon Mac before merge (§3.1) | ≤ 20 min | yes |
| T2 | VM integration | a real VM: the Linux test guest or an Android image | `Tests/IntegrationTests/` | `xcodebuild test -scheme IntegrationTests` on `apkrun-lab` | push to `main`; nightly; PRs on a disposable runner (§2.4) | per suite, ≤ 15–120 min | no; the PR that closes a task passes the suites the task lists |
| T3 | Acceptance | T2 plus the reference Mac, the network, credentials, long runs, or a person | `Tests/AcceptanceTests/`, `Tests/PerformanceTests/`, `Tests/Compatibility/`, §8 | `nightly.yml` jobs, gate scripts, people | nightly, gate closing, release candidates | nightly ≤ 8 h | no; gate checks close gates, release checks gate releases |

The CI jobs that run each tier are in [../05-development/build-system.md](../05-development/build-system.md) §15. A pull request merges only when every required CI check passes. `ci.yml` runs static checks, builds, and T0 tests on fresh GitHub-hosted VMs, and it does not run T1. T1 suites that need real host resources pass on a developer or reference Mac before merge, and the pull request links the result. Three checks run in the `lint` job of [build-system.md](../05-development/build-system.md) §3: the raw-ADB lint (§3.3), the compatibility database schema check (#91), and the release checks of §3.3 (in the `build` job for Release).

### 2.2 T0: unit and model tests

- **Definition.** Code runs in the test process. Allowed: fakes (§3.2), injected clocks, golden files, and a per-test temporary directory for plain reads and writes.
- **Not allowed.** Network (including loopback), subprocesses, XPC, Metal, `codesign`, the Keychain, real user defaults, sleeping, wall-clock time, and file system features beyond plain files (APFS clones, holes, modes, extended attributes). Those are T1.
- **Location.** Swift: `Packages/<Module>/Tests/<Module>Tests/`, `CLI/apkrun/Tests/`, and `Apps/<App>/Tests/`. Kotlin: `src/test/` of pure modules without Android APIs (`Guest/protocol`). Rust: `cargo test` in `Guest/vsockd`. Python: `Images/tools/tests/`.
- **Runner.** Swift (`test-swift`), Kotlin (`test-guest`), and Python (`test-images`) T0 may run on fresh GitHub-hosted macOS VMs. Rust (`test-linux`) runs on `ubuntu-latest`. `swift test` passes on a clean checkout without Gradle, AOSP, or network (NFR-DEV-02). T0 tests that read APKs use the committed copies of §4.1.
- **Budget.** The whole T0 set finishes in 10 minutes. One test takes at most 1 s.
- **Flakiness.** None tolerated. No retry (§2.7).

### 2.3 T1: component and host integration tests

- **Definition.** Real host resources, no VM. Examples:
  - processes: crash injection with `APKRUN_STORE_FAULT`, the instance lock between two processes, `aapt2` golden outputs, compile-fail tests;
  - file system: `clonefile`, hole punching, and recovery points on a temporary APFS volume, file modes, atomic registry writes;
  - XPC: an in-process `NSXPCListener.anonymous()` with authorization per endpoint;
  - Metal and windows: GraphicsBridge, the virgl replay (on the synthetic fixture `synthetic-virgl-session.json` (§4.6) until a Linux run records the `kmscube` capture), `IOSurfaceLayerView` screenshots;
  - `codesign`: wrapper generation, validation, and approval;
  - local HTTP servers on `127.0.0.1`: the image downloader, a local feed, the GitHub REST mock;
  - UI: XCUITest against the embedded runtime fake;
  - JVM: agent code that uses Android APIs, against fakes, Robolectric, or a scripted host over real sockets;
  - Linux: the `vsock_loopback` test of `apkrun_vsockd`;
  - short fuzz runs (§7.2).
- **Location.** Swift: `Packages/<Module>/Tests/<Module>SystemTests/`, and UI tests in `Apps/<App>/UITests/` ([../05-development/build-system.md](../05-development/build-system.md) §2.1). Kotlin: `src/test/` of `Guest/agentruntime`, `Guest/guestd`, and `Guest/APKRunStore`. Fuzz: `Packages/<Module>/Tests/<Module>Fuzz/`, corpora in `Tests/Fixtures/fuzz/<target>/`.
- **Runner.** The bare-metal `apkrun-ci` Mac with a GUI session (§3.1), or the developer's Apple silicon Mac before merge. `vsock_loopback` runs in `test-linux`. A T1 test whose resource is missing (Metal device, GUI session, APFS scratch volume) skips with a message that names the resource. On its required runner, a skip for a missing resource fails the job.
- **Budget.** 20 minutes for the PR set. Fuzz targets run 60 s each in `fuzz-short`.
- **Flakiness.** No retry (§2.7).

### 2.4 T2: VM integration tests

- **Definition.** A real VM through Virtualization.framework: the Linux test guest (§3.4), the stock Cuttlefish image, the custom image, or a test bundle (§3.5).
- **Location.** `Tests/IntegrationTests/<Area>Tests/`, for example `LinuxGuestTests` ([../02-design/vm.md](../02-design/vm.md) §12), `AndroidBootTests`, `GraphicsTests`, `InputTests`, `WindowingTests`, `GuestAgentTests`, `StoreTests`, `UpdateTests`, `WrapperTests`, `HostUITests`, `DesktopIntegrationTests`, `DiagnosticsTests`, `DaemonTests`, `MaintenanceTests`, `CLITests`.
- **Runner.** `xcodebuild test -scheme IntegrationTests` on `apkrun-lab`. The test bundle is hosted by `APKRunTestHost`, which carries `com.apple.security.virtualization` ([../05-development/build-system.md](../05-development/build-system.md) §12.4). Tests that go through apkrund use the Debug identities (`io.apkrun.apkrund.dev`).
- **Suites.** Groups inside `Tests/IntegrationTests`, so a pull request runs only what it needs.

| Suite | Contents | CI job | Budget |
|---|---|---|---|
| LinuxGuest | Linux test guest: devices, disks, bootconfig, `net`, `rng`, `gpu`, `virgl` | `linux-guest` | ≤ 15 min |
| AndroidStock | stock Cuttlefish image: boot, ADB, install and launch, graphics, input, windows, development-mode agent | `android-stock` | ≤ 60 min |
| AndroidCustom | custom `userdebug` image (#36): Store Agent, updates, rollback, wrappers, desktop integration, diagnostics, SELinux, image migration | `android-custom` | ≤ 90 min |
| Maintenance | APKRun N → N+1 and its variants (`ReleaseUpdateTest`), feed-driven image update | `maintenance` | ≤ 120 min |

- **Triggers.** The jobs are in `integration.yml` ([../05-development/build-system.md](../05-development/build-system.md) §15.1). `linux-guest` runs only on manual dispatch from `main` until an `apkrun-lab` runner exists. Pull-request T2 runs are off until a disposable runner exists. Until then, the reviewed commit runs on the reference Mac, and the result is linked before the task-closing pull request merges. A label never authorizes unreviewed code on a persistent self-hosted runner. The nightly `t2-all` job runs all four suites on `main`.
- **Before a task closes.** The pull request that closes a task runs every suite the task lists.
- **New macOS builds.** The full T2 set runs on every new macOS build on the seed lab Mac (R-16, §9.4).
- **Flakiness.** One automatic retry per test. The report marks every "passed on retry" (§2.7).

### 2.5 T3: acceptance tests

- **Definition.** End-to-end checks that need the reference Mac, the network, credentials, long run times, or a person.

| Kind | Location | Runs | Retry |
|---|---|---|---|
| Gate checks (§5) | `Tests/AcceptanceTests/G<n>…`, run by `scripts/run-gate.sh G<n>` | when a gate task closes, then nightly | none |
| Release smoke matrix (§9.2) | `Tests/AcceptanceTests/ReleaseSmoke` | every release candidate, weekly on `main` | none |
| Performance (§7.1) | `Tests/PerformanceTests/` (`apkrun-perf`) | nightly (`perf`) | none; the regression rule of §7.1 applies |
| Compatibility (§7.4) | `Tests/Compatibility/` | corpus nightly; full list before each release | none |
| Network checks (§3.4) | `Tests/AcceptanceTests/Network` | nightly | one retry, classified as in §2.7 |
| Long fuzzing (`fuzz-long`), soak, notarization (`notarize`) | §7.2, §7.3, #89 | nightly | none |
| Manual checklists (§8) | the release issue | every release candidate | not applicable |

- **Gate checks.** A gate may run a lower-tier VM test as a building block, but its check lives in `AcceptanceTests`. G3 follows this rule: `scripts/run-gate.sh G3` first runs the `LinuxGuest` IntegrationTests configuration, then the gate check in `Tests/AcceptanceTests/G3GraphicsTests/` with the `G3` AcceptanceTests configuration.
- **Current state.** Until the lab runners exist, the nightly schedule is off. Run gate checks locally with `scripts/run-gate.sh G<n>`.
- **Budget.** The nightly T3 run finishes in 8 hours per machine.
- **Required.** T3 does not gate pull requests. A gate check closes its gate. Release checks gate the release (§9).

### 2.6 Choosing a tier

1. Can the behavior be reached with an injected fake and in-process code? Then T0.
2. Does it need a real host resource from §2.3, but no guest? Then T1.
3. Does it need a guest kernel or Android? Then T2. Use the Linux test guest when Android is not needed.
4. Does it need the reference Mac's numbers, the Internet, credentials, a second Mac user session, or a person? Then T3 or a manual check (§8).

Every behavior has its lowest-tier test. Crossing the VM boundary has a T2 test (P2).

### 2.7 Flakiness and quarantine

- **Flaky** means that a test both passes and fails on the same commit and machine.
- **T0 and T1.** No retry. The owner fixes the test the same working day or quarantines it.
- **T2.** One automatic retry, recorded. A test that passes only on retry three times in 7 days is quarantined.
- **T3.** Gate checks and the release smoke matrix are never retried and never quarantined. Network checks retry as §3.4 describes. A repeated identical classified failure kind to a third-party host is `external`, not `fail`. Three `external` results in a row open an issue. Other failures are not retried.
- **Quarantine.** A quarantined test carries a TODO, a reason, and its tracking task (NFR-DEV-04). It still runs nightly, but its result does not fail the job. After 14 days it is fixed or deleted. Deleting it needs replacement coverage in another tier, named in the task. Security negative tests (§7.2) cannot be quarantined. A task cannot close while one of its listed tests is quarantined.
- **Red `main`.** A T2 failure on `main` blocks merges until the change is fixed or reverted. A T3 failure opens an issue labeled `nightly-failure` ([../05-development/build-system.md](../05-development/build-system.md) §15). The owner fixes or reverts within one working day.

### 2.8 Tier labels in the design documents

When a design document's test tier differs from this section, this section applies, and the design document is fixed in the same pull request.

- The test IDs of [../02-design/diagnostics.md](../02-design/diagnostics.md) §12 (`T1-1` … `T3-2`) are stable names. Their tier is the Tier column of that table, not the prefix.
- Gate checks are T3 (§5). The T2 rows marked as a gate's "building block" pass before the gate check runs.
- Kotlin: pure Kotlin modules without Android APIs are T0. Code that uses Android APIs, tested against fakes, Robolectric, or a scripted host, is T1.

---

## 3. Test infrastructure

### 3.1 Machines and runners

Runner labels and setup: [../05-development/environment-setup.md](../05-development/environment-setup.md) §6.

| Machine | Runs |
|---|---|
| `ubuntu-latest` | `test-linux`: `cargo test`, the T1 `vsock_loopback` test; the F-Droid test repository build (`fdroid update`) |
| `xcode-27` (fresh GitHub-hosted macOS 27 VM) | `ci.yml`: static checks, builds, T0 Swift tests |
| `apkrun-ci` (self-hosted Apple Silicon, macOS 27, user `apkrun-ci` with automatic login, GUI session, APFS scratch volume) | trusted default-branch and manual T1 Swift, Kotlin, and Python checks, XCUITest, `fuzz-short`; nightly `fuzz-long` |
| `apkrun-lab`, the reference Mac (OQ-02: M1, 16 GB, bare metal, §3.6) | trusted `main` and nightly runs, gate checks, NFR numbers and baselines, release smoke matrix, notarization, manual checklists |
| Seed lab Mac (every macOS 27.x beta and release) | the full T2 set and the gate checks on each new build (R-16, §9.4) |
| Information Mac (optional, M3 or later) | the nightly T2 set; performance numbers for information only |
| AOSP builder (x86-64 Linux, [environment-setup.md](../05-development/environment-setup.md) §5) | custom image builds and test image bundles (§3.5) |

T2 and T3 never run inside a VM (P3). Hosted macOS VMs may run T0 tests that need only the process and ordinary temporary files. T1 requires its declared host resources. A pull-request T1, T2, or T3 job uses a disposable runner. Until one exists, run the reviewed commit on the required Mac and attach the result.

### 3.2 Fakes

| Fake | Replaces | Contract and use |
|---|---|---|
| fake `RuntimeService` | apkrund over XPC | CLI golden tests ([../02-design/cli.md](../02-design/cli.md) §6.3), host UI model tests ([../02-design/host-ui.md](../02-design/host-ui.md) §15) |
| embedded runtime fake | apkrund for UI tests | XCUITest for onboarding, add flow, uninstall choices, approval |
| in-memory fake agent | the Guest Agent peer of `GuestConnection` | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §16 T0 |
| scripted host | the host peer of the Kotlin agent server | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §16 T1 |
| fakes of Android services, fake `InputConnection` | Android framework services | [../02-design/guest-components.md](../02-design/guest-components.md) §12, [../02-design/input.md](../02-design/input.md) §13, [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §15 |
| fake `StoreAgentChannel` with scripted Android state | the Store Agent and the ADB channel | [../02-design/package-store.md](../02-design/package-store.md) §16 |
| fake store, runtime, `SessionRegistry`, counting fake provider, fake network path | package store, runtime, providers | [../02-design/update-system.md](../02-design/update-system.md) §16 |
| fake supervisor, fake store | RuntimeHost parts | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| VirtioDeviceCore fakes | the VZ custom virtio device API | [../02-design/graphics.md](../02-design/graphics.md) §14 |
| synthetic `FrameSource`, scripted wrapper | GraphicsCore frames, wrapper acknowledgements | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §5.5, §13 |
| simulated pasteboard and agent | `NSPasteboard` and the agent | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §15 |
| fake UI client | the approval UI | [../02-design/wrapper.md](../02-design/wrapper.md) §16 |
| manual clock | the wall clock | IdleController, scheduler, marker rules |
| test Keychain | the login Keychain | provider tokens in the secret test ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-6) |

- A fake lives in the `<Module>TestSupport` target of the module that owns the protocol. Other modules import that target and do not write their own fake of the same protocol.
- A fake of guest behavior has a T2 contract test against the real guest. When the two disagree, the fake is fixed.

### 3.3 Test hooks, test builds, and the raw-ADB allowlist

All hooks are compiled into Debug builds only, unless the Builds column says otherwise. No hook, in any build, turns off a package validation rule ([../../AGENTS.md](../../AGENTS.md) §4, invariant 10). Tests that need Android's own refusal install through `AdbClient` (#39). Variables: [../03-reference/configuration.md](../03-reference/configuration.md) §5.1.

| Hook | Effect | Builds | Used by |
|---|---|---|---|
| `APKRUN_STORE_FAULT=<kind>:<step>` | injects a store fault at a host step | Debug | [../02-design/package-store.md](../02-design/package-store.md) §16 T1, #39 |
| `APKRUN_GRAPHICS_FAULT=rendererInit` | renderer initialization fails | Debug | [../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-4 (c) |
| `APKRUN_RUNTIME_FAULT=rejectAgent:guest` | apkrund rejects the Guest Agent handshake | Debug | [../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-4 (d) |
| `APKRUN_LAUNCHER_TEST_NO_RUNTIME=1` | the launcher runs without a runtime (screen R) | Debug | #45 |
| `APKRUN_TEST_HEADLESS_LAUNCH=1` | `launch` opens a session owned by apkrund that discards its frames. #69 removes it. | Debug | #33, the G6 stages |
| `APKRUN_TEST_MARKER_TIMEOUT=<n>s` | shortens the maintenance marker timeout | Debug, `ReleaseUpdateTest` | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 variant (c) |
| `APKRUN_HOME` | relocates the data root. CLI commands other than `apkrun dev` ignore it ([../02-design/cli.md](../02-design/cli.md) §3.6), so their tests run in a separate macOS test user account ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-1). | Debug (`apkrun dev`, debug apkrund, test hosts) | isolation (§3.9) |
| `apkrun dev power sleep\|wake` | injects host sleep and wake messages | Debug | #70 |
| `APKRUN_TEST_READBACK` compile flag | the test-only readback mode: reads the scanout resource for the #23 replay test, and samples pool buffers for the #24 tearing test. Excluded from the readback counter. | test builds only | #23, #24 |
| `APKRUN_TEST_IMAGE_FEED_URL=<url>` | points `ImageFeedClient` at a local feed server, which may be `http://127.0.0.1`. The Direct and F-Droid loopback URLs of Debug builds point at the local update server ([../02-design/update-system.md](../02-design/update-system.md) §12). | Debug | #88 |
| `APKRUN_TEST_IDLE_SECONDS=<n>` | replaces the `HIDIdleTime` value of the apply gate | Debug | #88 |
| `APKRUN_TEST_POWER=ac\|battery:<percent>` | replaces the power source of the apply gate | Debug | #88 |
| `ReleaseUpdateTest` configuration | Release code; builds 9000 and 9001 (9001 adds `Resources/test-build-marker`); local appcast; test Sparkle key | `ReleaseUpdateTest` only | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| Sparkle test user driver | accepts every prompt. `APKRUN_TEST_INSTALL_CHOICE=closeApps\|whenClosed` answers the install dialog; the launch argument `--test-check-for-updates` starts a user-initiated check | `ReleaseUpdateTest` only | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| settings as switches | `runtime.idleSuspendMinutes = 1`, `runtime.idleStopMinutes = 2` | all (ordinary settings) | #70, #71 |
| hand-built wrapper with `runtime.minimumVersion = 99.0` | `scripts/dev/make-wrapper.sh --minimum-version 99.0`. The value is normally the launcher's build constant ([../03-reference/configuration.md](../03-reference/configuration.md) §4). | Debug (the script) | wrapper screen V, #45 |
| `androidboot.apkrun.test.*` | `marker=<value>`, `fail_health=1`, `fail_boot=1` | test image bundles only ([../02-design/android-image.md](../02-design/android-image.md) §6.2) | §3.5 |
| `androidboot.apkrun.devmode=1` | adbd on vsock 5555 on the custom image | custom image, user-controlled | §3.5, #36 |

Release checks (`scripts/release/check-release-build.sh`, run by the `build` job on every Release build and again in the release jobs, [../05-development/build-system.md](../05-development/build-system.md) §3.1):

- The Release binaries contain no `APKRUN_*_FAULT` string, no `APKRUN_TEST_*` string (such as `APKRUN_TEST_HEADLESS_LAUNCH`), no `APKRUN_LAUNCHER_TEST_NO_RUNTIME`, no test key or test key ID from `Tests/Fixtures/signing/`, and no `ReleaseUpdateTest` setting.
- A release image manifest contains no `androidboot.apkrun.test.*` key ([../02-design/android-image.md](../02-design/android-image.md) §6.2).
- `ImageTrustStore` in a Release build contains only release key IDs ([../02-design/android-image.md](../02-design/android-image.md) §10.1).

Raw-ADB allowlist. The raw-ADB lint of #28 rejects `adb shell` and `pm ` strings outside `ADBStoreAgentChannel` and `AdbClient`. These paths are exempt because they use ADB directly: `scripts/dev/` (#25), `Tests/Compatibility/` (the `monkey` run, [../02-design/diagnostics.md](../02-design/diagnostics.md) §10.4), and `Images/tools/reference/` (the reference capture). T2 tests that need a shell command go through `AdbClient`.

### 3.4 Linux test guest

Defined in [../02-design/vm.md](../02-design/vm.md) §12.

- Kernel: pinned Alpine `linux-virt`, fetched and hash-checked by `scripts/fetch-test-linux.sh` (hash in `ThirdParty/ThirdParty.lock.json`), kept in the runner cache.
- initramfs: `scripts/build-test-initramfs.sh` with `/init` and `/etc/udhcpc/apkrun.script` from `Tests/Fixtures/linux/`. The DHCP script delegates lease configuration to Alpine's default script and records the lease details atomically. The pinned `ssl_client` and OpenSSL libraries support the external HTTPS probe.
- Command line: `apkrun.test=blk,net,vsock,ports,rng,gpu,virgl` selects checks; `apkrun.test.poweroff=1` powers off at the end.
- Output on `hvc0`: `APKRUN-TEST: boot ok`, then `APKRUN-TEST: <name> ok|fail <detail>` per check, then `APKRUN-TEST: done`.
- Network check: `net` requires a DHCP lease and an HTTP 204 from the host's ephemeral-port server. T3 also checks public DNS and HTTPS. External output is capped at 4 KiB, and truncation fails closed. After one retry, the same DNS failure, recognized BusyBox `wget` socket-connect error, or exact `wget: download timed out` error, with no HTTP response or TLS/client diagnostics on both attempts, is recorded as skipped `external`. Socket errors and download timeouts keep different details. Other TLS/client errors, an unexpected HTTP status, and all other failures fail the test.
- Disks: raw test disks with known content, created at test time by the scripts in `Tests/Fixtures/linux/`.
- Harness: `Tests/IntegrationTests/LinuxGuestTests`, VirtualMachineCore only, timeout 60 s. The harness fails a run when a check prints `fail`, when a requested check prints nothing, or when `done` does not appear in time. The console log is an artifact of every run (§3.7).

### 3.5 Android images and test bundles

| Image | Source | Used by |
|---|---|---|
| Stock Cuttlefish `aosp_cf_arm64_only_phone-userdebug`, build 16373615, Android 17 (API 37) | Android CI, fetched by the #9 tool, pinned in the image manifest | AndroidStock suite, tasks of M1–M4, development mode |
| Custom `apkrun_arm64-trunk_staging-userdebug` | AOSP builder ([../02-design/android-image.md](../02-design/android-image.md) §11.5) | AndroidCustom suite (#36), test bundles |
| Custom `-user` | image build machine, release signing | image release candidates, release smoke matrix, performance |
| Current and previous stable images | the published image feed | release smoke matrix (§9.2) |
| Reference captures (`default`, `target`, `swiftshader`) | `Images/tools/reference/capture.sh` → `Images/reference/<buildId>/` | the G2 reference diff ([../02-design/android-image.md](../02-design/android-image.md) §8.4), `BootPhaseDetector` golden tests |

Test bundles are built from the custom `userdebug` image, because the handlers of the `androidboot.apkrun.test.*` keys, the Guest Agent health report that `fail_health` changes, and the script of bundle S are in the custom product (#36). Bundle P is the exception: it only changes the kernel command line, so it may be built from the stock image. Test bundles are never published. An Android T2 suite skips when `Images/work/16373615/` holds no test bundle. Under `APKRUN_CI=1` it fails instead of skipping.

| Bundle | Difference from its base | Used by |
|---|---|---|
| A | none | migration ([../02-design/android-image.md](../02-design/android-image.md) §12.4) |
| B | A with `androidboot.apkrun.test.marker=B` (read as `ro.boot.apkrun.test.marker`) and a higher version | migration A → B |
| B′ | B with `androidboot.apkrun.test.fail_health=1` | failed migration B → B′, automatic restore to B |
| F | `androidboot.apkrun.test.fail_boot=1` | `bootFailure` verdict ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-4 b) |
| P | a kernel command line that names a missing init (`init=/apkrun-test-missing`), so the kernel panics | boot-loop guard ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §14) |
| S | a test-only init script that writes a fixture secret to `/dev/kmsg` and sets `persist.apkrun.test.secret` | secret fixture test ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-6) |

Signing: each `apkrun-lab` machine creates its own development key with `python3 -m apkrun_image keygen` ([../02-design/android-image.md](../02-design/android-image.md) §10.1). The runner signs test bundles with it, and Debug builds trust it. The committed key `test-image-ed25519` (§4.4) serves only T0 and T1 signature vectors, with an injected trust store.

### 3.6 Lab Macs and the reference Mac

Setup: [../05-development/environment-setup.md](../05-development/environment-setup.md) §6.2–§6.3. Every lab Mac (`apkrun-lab`, the seed Mac, the information Mac):

- runs on AC power with Low Power Mode off, runs `caffeinate -d` during a run, and runs no other VM ([../02-design/diagnostics.md](../02-design/diagnostics.md) §9.2);
- runs the runner in the GUI session of the `apkrun-ci` user with automatic login, and has a second local test account (portable wrappers #90, host-only doctor, fresh-account checks);
- has the permissions that macOS asks for once: Accessibility for the harness (`input-latency`), Screen Recording for window captures, notifications for the fixture wrappers, and Microphone for apkrund (#85, [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §8.2). A test that finds a permission missing fails with `runnerMissingPermission`. It never clicks a prompt;
- allows incoming connections for the signed `APKRunTestHost` in the macOS Application Firewall, so the #7 guest can reach the host-local HTTP probe;
- has a virtual loopback audio device as default output and input for the audio and microphone T3 jobs (#84, #85). Without it, these jobs skip, and checklist §8.7 covers them by hand;
- runs one VM at a time (§3.10), and serializes suites per machine;
- keeps a runner cache (§4.1) with pinned SHA-256 values. No test downloads a large artifact during a run.

The reference Mac also follows "clean build from `main`" for gate checks ([roadmap.md](roadmap.md) §2), and it runs the public macOS release that users have, never a seed.

### 3.7 Artifacts on failure

| Tier | Collected |
|---|---|
| T0, T1 | xcresult and JUnit reports; fuzz reproducers; golden diffs (actual, expected, diff image or text); crash reports of test processes |
| T2 | T0/T1 items, plus: every `hvc` console log; `boots.jsonl` and `launches.jsonl`; the apkrund mirror log and `log show` output for the `io.apkrun` subsystems; logcat; a diagnostics bundle with `--include-logcat` (or a host-only bundle when apkrund is down); screenshots of every open window; a listing of the data root; the store journal; the image `state.json`; crash reports of apkrund, the launcher, and the app |
| T3 | T2 items, plus perf `results.json` and `summary.md`, gate evidence (§5), and screen recordings |

Retention: pull request runs 14 days, nightly runs 30 days, gate evidence and release candidate artifacts permanently. Artifacts hold fixture data only. The diagnostics redactor still runs on bundles, and the secret test (§7.2) checks it.

### 3.8 Performance baselines

- The harness is `swift run apkrun-perf <scenario> [--runs] [--warmup] [--output] [--baseline]` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §9).
- Baselines: `Tests/PerformanceTests/baselines/<model identifier>.json`. Only a reviewed pull request that says why may change one. The first report of every scenario becomes the initial baseline (#71).
- Runs use a Release build, the release candidate's `-user` image when one exists, and fixtures wrapped with `apkrun wrap --output`.

### 3.9 Isolation

- T2 uses Debug builds with their `.dev` identities, so a test never touches an installed release ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).
- Each T2 suite starts from an empty data root. The harness unregisters the Debug agent and deletes the `APKRun-Dev` root, or gives test hosts and `apkrun dev` a fresh `APKRUN_HOME`.
- Each Android suite uses a temporary `APKRUN_HOME` on the same volume as the test bundle.
- Wrappers go into a per-suite folder (`apkrun wrap --output`). Tests of `~/Applications` behavior (#57, #79) remove their wrappers in teardown.
- Update sources are local, on `127.0.0.1`: `scripts/dev/update-server.py`, the local appcast, the local image feed, the GitHub mock, and the served F-Droid test repository. T2 has no Internet access. The #7 network test fetches from a server on the host. Its Internet half is a T3 check ([../02-design/vm.md](../02-design/vm.md) §7).
- A failed teardown marks the machine dirty. The next suite starts with Reset Android ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9.5) and a new data root.

### 3.10 Parallel VM runs

Until #100 is done, one VM runs at a time, and gate runs take the lock `lockf -k /tmp/apkrun-vm.lock`. Two VM runs on one Mac otherwise share the developer ADB port `127.0.0.1:6520`, the artifact directory `/tmp/apkrun-test-linux` (`APKRUN_TEST_LINUX_DIR`), and the default home. After #100, these rules hold:

- Each VM test run has its own APKRun home, `/tmp/apkrun-vm-<UUID>`, created by `VMRunResources`. The instance, logs, image store, and console sockets live under it. The G2 reference capture sits beside it (`/tmp/apkrun-vm-<UUID>-capture`), because it is gate evidence. Teardown removes the home.
- The ADB host port of a run comes from `APKRUN_TEST_ADB_PORT` (set through `TEST_RUNNER_APKRUN_TEST_ADB_PORT`). When unset, it is `0`, and the kernel picks a free loopback port, which the supervisor reports as `developmentADBHostPort`. The product default stays `6520` (`BootOptions.adbHostPort`).
- Console socket names stay `hvc0.sock` and `hvc1.sock`, because the CLI uses them. Their directory is per run. Every socket path stays under the 103-byte limit.
- Every `xcodebuild` run has its own `-derivedDataPath` and `-resultBundlePath`.
- No producer rewrites the artifact directory while a parallel run is active: `scripts/run-gate.sh`, `build-test-initramfs.sh`, `fetch-test-linux.sh`, `build-test-android-bundle.sh`, `build-test-android-disks.sh`.
- Gates G1 and G2 run alone, under the lock.
- No two runs start apkrund at the same time.
- Check host memory before a second Android VM starts (`InstanceSizing.default`; the lab Mac has 16 GB).

---

## 4. Fixtures

### 4.1 Rules

- **Fixture apps** are one Gradle project in `Tests/Fixtures/AndroidApps/`, built by `scripts/build-fixtures.sh` into `Tests/Fixtures/AndroidApps/out/` ([../05-development/build-system.md](../05-development/build-system.md) §8). Each app has a CamelCase project name and the package in §4.2 (`io.apkrun.fixture.<name>`, [../01-architecture/modules.md](../01-architecture/modules.md) §5). Variants of one app share its package. Debug-only hooks (receivers, traces) live in the `src/debug` source set and are absent from release builds.
- **Committed copies.** T0 tests read committed prebuilt APKs from `Tests/Fixtures/apks/`, so `swift test` needs no Gradle (NFR-DEV-02). `scripts/build-fixtures.sh` refreshes them. A CI check fails when a copy is older than its sources.
- **Size.** A committed fixture file is at most 10 MiB. Larger inputs are generated at test time from a seed (for example the 1.5 GiB file of #83) or kept in the runner cache with a pinned SHA-256.
- **Event log.** Fixture apps log to logcat with the tag `APKRUN-FIXTURE` and the message `<event> <detail>`, for example `I/APKRUN-FIXTURE: click 3`. Tests read them through `AdbClient` with a `FixtureLog` helper that starts the stream before the action. Fixtures never log secrets, except where a test plants a fixture secret on purpose (§7.2).
- **Determinism.** Fixtures have no network access, except HelloLinks, which only asks the host to open links. No ads, no analytics, no random behavior unless a seed is passed.
- **Signing.** Fixture apps are signed with test keys (§4.4). Nothing built with a test key ships.

### 4.2 Fixture apps

This table is the only specification of the fixture apps. Each row gives the package, what the app does, the events it logs, and the tasks that use it. Details that do not fit a row follow the table. Fixture apps are signed with `test-fixture-a` (§4.4) unless a row says otherwise.

| App | Package | What it does | Events | Used by |
|---|---|---|---|---|
| HelloText | `io.apkrun.fixture.hellotext` | Counter button with a persistent counter, text field, password field, context menu, Details screen (for Back), time label, adaptive vector icon. See the details below. | `click <n>`, `screen <name>`, `contextmenu`; `text <JSON string>` only in the debug build, on the `TEXT` broadcast; not emitted yet: `start counter=<n>`, `config locale=<tag> tz=<id> 24h=<bool>` (the first task that reads one adds it) | G4–G9 building blocks, #17, #18, #25–#27, #72, #86, #103, migration, perf |
| HelloCompose | `io.apkrun.fixture.hellocompose` | Compose `LazyColumn`, `TextField`, and a password field. | `scroll first=<index>`, `text length=<n>` when the `TextField` changes. The typed text is never logged ([../../AGENTS.md](../../AGENTS.md) §8); a test that needs the exact text reads the field from a `uiautomator dump` (`AndroidInputRun.waitForText`). | #25, #30, #31 (G5), #72; installed with `adb install` as the unmanaged package of #78 |
| HelloGL | `io.apkrun.fixture.hellogl` | A GLES 3.0 animation. An intent extra selects the alternating-color mode, and another sets the run length. | `renderer <GL_RENDERER>`, `fps <average>` every 10 s | #23, #24 (G3), #30, #69, `hellogl-fps` (§7.1) |
| HelloWebView | `io.apkrun.fixture.hellowebview` | A WebView showing a bundled local page. No network. | `loaded` | #30, compatibility |
| HelloNotification | `io.apkrun.fixture.hellonotification` | Posts, on buttons and on a timer, the notification set of [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §5.5: plain, two-action, an update of the first, `LOW`, ongoing, and a grouped series. Its launch activity logs which intent opened it. | `posted <id>`, `intent <action>` | #55, secret test (§7.2) |
| HelloClipboard | `io.apkrun.fixture.helloclipboard` | A text field, a Copy button that sets a known string, an image view and a rich-text field (#81), and a view of the current primary clip ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §4.5). | `clip <text>` (logs its clipboard text on purpose) | #54, #81, secret test (§7.2) |
| HelloLinks | `io.apkrun.fixture.hellolinks` | Opens an `https` link, a `mailto` link, a Custom Tab, a `javascript:` URL, an `intent:` URL, and a link in the background (from a timer after its window loses focus) ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §7.3). | `open <scheme>` | #82 |
| HelloFiles | `io.apkrun.fixture.hellofiles` | Accepts shares (text, images, any file), opens the system picker (open, open tree, create), shows names, sizes, and SHA-256, and shares a generated file ("Save to Mac") ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6.5). | `file <name> <size> <sha256>` | #83 |
| HelloFilesPeer | `io.apkrun.fixture.hellofilespeer` | A second package with the HelloFiles picker and no shared-folder access. It cannot open a URI that was granted to HelloFiles. | as HelloFiles | #83 |
| HelloAudio | `io.apkrun.fixture.helloaudio` | Buttons play a 1 kHz tone, a sweep, and a click track (one click per second). Records 5 s and shows the level ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §8.3). | `play <name>` when playback starts, `recorded <frames> <peak>` after a recording | #84, #85, checklist C10-5 (§8.7) |
| HelloUpdate | `io.apkrun.fixture.helloupdate` | Versions and variants in §4.3. | `version <code>`, `data <value>`, `fgs started` (V1 with the `fgs` extra) | #67 (adds V1), #38–#44 (other variants), #51–#53, #50 (G9), G7 |
| HelloSplit | `io.apkrun.fixture.hellosplit` | Base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, and an install-time feature split. A native library and a Japanese string. See the details below. | `native ok`, `string <locale>` | #28 (creates it), #43, #74, #79 |
| HelloNative | `io.apkrun.fixture.hellonative` | An arm64-v8a variant and an armeabi-v7a-only variant. | `native ok` | ABI check ([../02-design/package-store.md](../02-design/package-store.md) §4.6) |
| HelloLegacySig | `io.apkrun.fixture.hellolegacysig` | v1 signature only, `targetSdk` 29. | none | signature floor tests |
| OtherInstaller | `io.apkrun.fixture.otherinstaller` | Declares `REQUEST_INSTALL_PACKAGES` and tries to update another fixture. See the details below. | `session <status>` | #40 |
| IconLegacy | `io.apkrun.fixture.iconlegacy` | A legacy PNG launcher icon with transparency. | none | #56 |
| OddName | `io.apkrun.fixture.odd_name` | A label with `/`, `:`, and an emoji ZWJ sequence. | none | #46 name sanitizing and the `_` → `-` mapping ([../02-design/wrapper.md](../02-design/wrapper.md) §4), #79 |
| HelloProbe | `io.apkrun.fixture.helloprobe` | An ordinary `untrusted_app` that tries to connect to the agents' abstract sockets and to open `AF_VSOCK`. | `probe <target> <result>` | #36 SELinux negative test ([../02-design/guest-components.md](../02-design/guest-components.md) §12) |

Post-v1 tracks add a Vulkan fixture (#97) and a stand-in installer (#98) to `Tests/Fixtures/AndroidApps/`, signed like the others.

Details that the table does not hold:

- **HelloText.** `minSdk` 29, `targetSdk` 37, `versionCode` 1, `versionName` "1.0". One exported launcher Activity, `MainActivity`, with a `TextView` that shows the counter and a `Button` that increments it. Each click logs `APKRUN-FIXTURE: click <n>`. The counter persists in `SharedPreferences`. A new store over the same preferences reads the same count.
  - Debug source set only: `DebugCounterReceiver` handles the broadcasts `io.apkrun.fixture.hellotext.debug.INCREMENT` (increments and logs `debug increment <n>`), `io.apkrun.fixture.hellotext.debug.READ` (logs `debug read <n>`), `io.apkrun.fixture.hellotext.debug.DETAILS` (opens the Details screen), and `io.apkrun.fixture.hellotext.debug.TEXT` (logs `text <JSON string>` with the field's text). It uses the same store as the Button. Release builds have no receiver.
  - Debug trace (#103): `TouchTrace` records DOWN, MOVE, UP, and CANCEL dispatch, pressed-state changes, and click callbacks with their timing. The `DebugTouchTraceActions` start and stop-and-drain broadcasts control it, and a drain logs `touch-trace <record>` lines. The trace is off unless a test starts it. The release source set has a plain button and no trace.
- **HelloSplit.** Built as an App Bundle and converted to `.apks` with the pinned bundletool ([../05-development/build-system.md](../05-development/build-system.md) §8.1). The native library lives in `config.arm64_v8a` and logs `native ok` when loaded. The activity logs `string <locale>` from a string that `config.ja` translates.
- **HelloAudio.** The `play click` event marks the start of the click track for the latency measure (#84).
- **OtherInstaller.** Carries HelloUpdate V2 in its assets. On first launch it opens a `PackageInstaller` session for `io.apkrun.fixture.helloupdate` with `USER_ACTION_NOT_REQUIRED`, commits it, and logs `session <status>`.

Combinations used by name in the design documents:

- "Two fixture windows" in the clipboard loop test ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §4.5): HelloClipboard and HelloText.
- "The APKRun-managed fixture" of #40: HelloUpdate.
- "A fixture app in `untrusted_app`" ([../02-design/guest-components.md](../02-design/guest-components.md) §12): HelloProbe.

### 4.3 Derived packages

| Variant | Build | Purpose |
|---|---|---|
| HelloUpdate V1 | versionCode 1, key A | writes `HELLO` to `files/data.txt` on first launch. With the intent extra `fgs`, it starts a `mediaPlayback` foreground service and logs `fgs started` (#41) |
| HelloUpdate V2 | versionCode 2, key A | reads `files/data.txt` and logs `data HELLO`; writes `files/v2.txt` |
| HelloUpdate V2-other-signer | versionCode 2, key B | `signerMismatch` on the host, `CONFLICT` in Android (#39) |
| HelloUpdate V3-broken | versionCode 3, key A | crashes 2 s after launch (#44) |
| HelloUpdate V4 | versionCode 4, key A | the normal update after a skipped version (#44) |
| HelloUpdate rotation variants | V2 signed with lineage A → B, with and without `INSTALLED_DATA`; rotation back with and without `ROLLBACK` | T0 validation matrix (#42) |
| Corrupted HelloUpdate V2 | one flipped byte in `classes.dex` | `invalidSignature` (#42) |
| Container fixtures | from HelloSplit and HelloText: split files, `.apks` (bundletool), `.xapk` with and without OBB, `.apkm` plain and non-ZIP, `.aab`, a zip bomb, a `../` entry, a symlink entry, 600 entries, and a ZIP64 container generated at test time | [../02-design/package-store.md](../02-design/package-store.md) §16 T0 |
| Generated `.apks` | 3 ABIs, 6 densities, 10 languages, one feature split, `requiredSplitTypes` | split selection (#43, #74) |

"HelloUpdate V4" is the fixture. "Rule V4" is the validation rule of [../02-design/update-system.md](../02-design/update-system.md) §6. Tests and documents always write the prefix.

### 4.4 Signing keys

All test keys are in `Tests/Fixtures/signing/`, named `test-*` ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7). None ships.

| Key | Purpose |
|---|---|
| `test-fixture-a.jks` | default signer of all fixture apps |
| `test-fixture-b.jks` | the "other signer" and the rotation target |
| `test-fdroid-repo.jks` | signs the F-Droid test repository index (#52) |
| `test-sparkle-ed25519` and `.pub` | signs the local appcast for `ReleaseUpdateTest` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2) |
| `test-image-ed25519` and `.pub` | T0 and T1 signature vectors for image manifests and feeds, with an injected trust store |
| `test-guest-dev.jks` | development signing of the Guest Agent and Store Agent APKs on the stock image ([../02-design/guest-components.md](../02-design/guest-components.md) §2) |

Developer ID, notarization credentials, the release Sparkle key, and the release image key are CI secrets ([../05-development/workflow.md](../05-development/workflow.md) §9.2). Only the `signing` and `release` environments can read them. The Developer ID and the notarization credentials are read by the release job, the `maintenance` T2 job (which signs the `ReleaseUpdateTest` bundles, #58), and the nightly notarization check (#89). The release Sparkle key and the release image key are only in `release`.

### 4.5 Update repositories and servers

| Fixture | Location | Served by | Used by |
|---|---|---|---|
| Local provider repository | `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/` (#38) | read directly | #38, #39, G7 |
| Temporary repositories | copies of the local repository with V3-broken and V4 added | the test | #44 |
| Direct manifests | the local fixtures served as Direct manifests ([../05-development/build-system.md](../05-development/build-system.md) §8.1), plus `Tests/Fixtures/update-repos/direct/`: valid, versionCode mismatch, wrong `sha256`, missing `sha256`, HTTP URL, relative URL, oversized, wrong package | `scripts/dev/update-server.py` on `127.0.0.1` (Debug only), with `--delay <seconds>` | #51, `update-check-launch` (5 s delay), #75 (30 s delay) |
| F-Droid test repository | `Tests/Fixtures/update-repos/fdroid/`: two HelloUpdate versions; `fdroid update` in CI signs the index with `test-fdroid-repo.jks`; a tampered `entry.jar` is a negative case | a local static server | #52 |
| GitHub recorded responses and mock | `Tests/Fixtures/update-repos/github/recorded/`: releases for V1 and V2 (V2 tagged `v0.1`), a release with two matching assets and no ABI hint, a draft, a pre-release, an asset with `digest` and one without, and a rate-limit response with its headers | T0 reads them; the T1/T2 mock serves them (a GitHub mode of `update-server.py`) | #53 (misleading tag `v0.1`, `ambiguousAsset`) |
| GitHub fixture repository | `apkrun-fixtures/helloupdate-releases` | github.com | #53 T3 nightly |
| Local appcast | `Tests/Fixtures/runtime-updates/appcast/` | a local server | #58 (`ReleaseUpdateTest` 9000 → 9001) |
| Local image feed | `Tests/Fixtures/runtime-updates/image-feed/`: valid, tampered, replayed sequence, expired | a local server with `Range` support | #88 step 8a |

### 4.6 Schema and golden files

| Golden set | Location | Test |
|---|---|---|
| Schema migrations | `Tests/Fixtures/schemas/<file>/v<n>.json` → `v<n>.expected.json` | T0, every file and version ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5, release rule R5) |
| Guest protocol frames | `Packages/GuestProtocol/testdata/frames/*.bin` | T0 in Swift and Kotlin (#34) |
| Bootconfig vectors | `Images/tools/tests/fixtures/bootconfig/*.txt` → `*.bin` | T0 in Python and Swift; T2 in the Linux guest ([../02-design/android-image.md](../02-design/android-image.md) §6.3) |
| Boot console captures | `Images/reference/<buildId>/` (#65) | T0 `BootPhaseDetector` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.3) |
| virtio-gpu byte vectors | from Linux driver traces, in GraphicsCore test resources | T0 (#20) |
| EDIDs | golden EDIDs and committed `edid-decode` output, in GraphicsCore test resources | T0 |
| `kmscube` command stream | `Tests/Fixtures/graphics/`. Synthetic until a Linux run records it: `synthetic-virgl-session.json` | T1 replay ([../02-design/graphics.md](../02-design/graphics.md) §14) |
| CLI output | `CLI/apkrun/Tests/Golden/` | T0 human and JSON output per command ([../02-design/cli.md](../02-design/cli.md) §6.3) |
| `aapt2` output | APKStoreCore test resources, per pinned `aapt2` version | T1 |
| Icon masters | WrapperCore test resources | T1 perceptual compare ([../02-design/wrapper.md](../02-design/wrapper.md) §16) |
| Direct manifest schema | `docs/03-reference/schemas/direct-provider-manifest.schema.json` | T0 against the model's fixtures (#51) |
| Compatibility database | `Tests/Compatibility/database/compatibility.json` against `compatibility.schema.json` | static check ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10) |
| Compile-fail sources | `Tests/Fixtures/compile-fail/` | T1 ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12) |

Golden files change only in a pull request that says why. A normal test run never rewrites a golden file.

### 4.7 Image fixtures

- Synthetic images for the Python and Swift pipeline tests, built with the vendored `mkbootimg` ([../02-design/android-image.md](../02-design/android-image.md) §15).
- Sparse images with every chunk type, GPT images for round trips, and runtime image bundles in a directory and in an `.aar`, including one with a bad signature and one with an extra file.
- Crafted archives for extraction rules: `..`, absolute paths, symlinks, hard links, devices, extra files ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14).
- The test bundles of §3.5.

### 4.8 Other fixtures

- Linux test guest scripts and disks: `Tests/Fixtures/linux/` (§3.4). Fuzz corpora: `Tests/Fixtures/fuzz/<target>/` (§7.2).
- Fixture secrets: strings `APKRUN-FIXTURE-SECRET-<n>` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-6).
- Compatibility app list: `Tests/Compatibility/apps.json` (fixtures, the 50-APK F-Droid corpus, hand-installed popular apps).
- Stored wrappers: one `HelloText.app` generated by each stable release, kept in the runner cache for the wrapper compatibility check (§7.6).

### 4.9 Fixture naming

| Fixture | Canonical name | Use |
|---|---|---|
| HelloUpdate application | `HelloUpdate V1`, `HelloUpdate V2` | One fixture app with two versions |
| G8 wrapper | `HelloText.app` | The wrapper uses the HelloText fixture's Android label |
| G9 wrapper | `HelloUpdate.app` | The wrapper is unchanged while the fixture updates |

Two other names look like fixture or gate names and are not:

- Validation rules V0–V6 ([../02-design/update-system.md](../02-design/update-system.md) §6) are always written "rule V<n>". "HelloUpdate V4" is the fixture.
- Gentle-update conditions are GU1–GU7 ([../02-design/update-system.md](../02-design/update-system.md) §7.1). G1–G9 are always gates.

---

## 5. Gates

The gates, their pass conditions, and their closing tasks are in [roadmap.md](roadmap.md) §2. This section says how each gate check runs. Every gate check is an acceptance test in `Tests/AcceptanceTests/`.

| Gate | Check | Fixtures and image |
|---|---|---|
| G1 ARM64 Linux boots | `Tests/AcceptanceTests/G1LinuxBoot` | Linux test guest |
| G2 boot_completed | `G2AndroidBoot` | stock image |
| G3 SurfaceFlinger → virtio-gpu → Metal | `G3Graphics` | stock image, HelloGL |
| G4 Hello APK in a native window | `G4NativeWindow` | stock image, HelloText debug APK |
| G5 Two APKs in two windows | `G5TwoWindows` | stock image, HelloText and HelloCompose (#31) |
| G6 Warm under apkrund | `G6WarmRuntime` | stock image (custom image after #36), HelloText |
| G7 v1 → v2 automatically | `G7GentleUpdate` | custom image, HelloUpdate V1 and V2, local provider |
| G8 APK wrapped as .app | `G8Wrapper` | custom image, HelloText |
| G9 Wrapper unchanged during updates | `G9WrapperIntegrity` | custom image, HelloUpdate V1 and V2 |

Rules:

- `scripts/run-gate.sh G<n>` runs the check on the reference Mac from a clean build of `main`. The T2 building blocks in `Tests/IntegrationTests/` pass first (§2.5).
- Keep the evidence permanently with the closing task: the script report, the xcresult, the artifacts of §3.7, and a screen recording for G3–G9.
- A gate check is never retried and never quarantined (§2.7).
- After a gate passes, its check runs nightly. From #36 on, the G2–G6 regressions run on the custom image. G2 also runs on the stock image while the stock image is used for development.
- A red gate regression opens an issue, blocks release candidates, and stops new tasks that depend on the gate ([roadmap.md](roadmap.md) §2).
- The checks that [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §14 adds to G6 (the warm-launch KPI, a real `pmset sleepnow`, onboarding on a fresh user account) join the nightly G6 run once #67, #70, and #71 are done. Until then they are on the v0.2 checklist (§8.3).

`G4NativeWindow` runs `apkrun dev launch` with the debug HelloText APK in a fresh development home. It sends 100 mouse clicks, Escape, and the exact ASCII string `Hello, APKRun 123!` as host keyboard events to the native window. The debug-only `TEXT` broadcast reports the field value; it is an observation hook and does not inject input. The test compares the Guest Agent's ADB shell invocation count before and after those host events. After HelloText's active native window is captured, the test starts `screencapture` before posting input and checks that it remains running for every posted mouse and keyboard event. The evidence checker requires a successful recording and verifies that the first and last input timestamps fall inside the recorder's lifetime. The screenshot, command log, summary, xcresult, and screen recording are kept under `build/gates/G4/`. The reference Mac must already grant the test host Screen Recording and event-posting permissions; the test reports a remediation and never opens a permission prompt.

G4 covers the automated input and native-window conditions. The v0.1 manual checks C01-1 through C01-5 in §8.2 remain separate: the gate does not evaluate Retina sharpness, scroll direction, context-menu placement, both keyboard layouts, or launch from a new Terminal window.

---

## 7. Non-functional testing

### 7.1 Performance

The harness and its preconditions are in [../02-design/diagnostics.md](../02-design/diagnostics.md) §9. It runs nightly in the `perf` job, never in pull requests. NFR numbers come from the reference Mac.

| Requirement | Scenario | Target |
|---|---|---|
| NFR-PERF-01 | `warm-launch` (3 warm-up runs, 30 measured, HelloText) | p50 ≤ 1.5 s, p95 ≤ 3 s |
| NFR-PERF-01 | `suspended-launch` | NFR-PERF-01 + 0.5 s; resume p50 ≤ 500 ms |
| NFR-PERF-02 | `cold-launch` (10 runs) | p50 ≤ 40 s |
| NFR-PERF-03 | `input-latency` (1,000 clicks and 1,000 keys at 20 Hz) | p95 ≤ 16 ms |
| NFR-PERF-04, NFR-PERF-05 | `hellogl-fps` (1080 × 2400, 60 s) | ≥ 55 fps average; readbacks = 0 |
| NFR-PERF-06 | `idle-cpu` (300 s while paused) | < 1 % |
| NFR-PERF-07 | `update-check-launch` (provider answers after 5 s, 10 packages) | p50 difference ≤ 50 ms |
| NFR-RES-04 | `memory` | recorded, no v1 target |
| input to NFR-PERF-02 | `boot-phases` (10 boots) | tracked against the baseline |

Other measured targets:

| Target | Source | Where measured |
|---|---|---|
| ⌘V p95 ≤ 150 ms for 64 KiB | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §4 | harness, nightly |
| file read through the provider ≥ 200 MB/s (provisional) | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6 | T2 #83, nightly |
| notification banner p50 ≤ 1 s (wrapper running), ≤ 3 s (background start) | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §5 | T2 #55 |
| `readyToDisplayed` p95 < 1 refresh + 4 ms; present < 2 ms p95 | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §5.5 | T2 #69, nightly |
| `inspect` < 1 s per 50 MiB APK | [../02-design/package-store.md](../02-design/package-store.md) §4 | reference Mac, nightly |
| quick doctor ≤ 3 s; bundle ≤ 100 MiB and ≤ 60 s | [../02-design/diagnostics.md](../02-design/diagnostics.md) §7–§8 | reference Mac, nightly |
| apkrund restart ≤ 15 s after `kill -9` | #32 | T2 |
| `VM_RESUMED → RUNTIME_READY` p50 ≤ 500 ms over 20 runs | #70 | T2 |

Rules:

- A nightly run fails when an NFR target is missed, or when a p50 is more than 15 % worse than the baseline (10 % for `hellogl-fps`). The failure names the segment that grew most ([../02-design/diagnostics.md](../02-design/diagnostics.md) §9.4).
- T2 tests with timing targets assert them only on the reference Mac. On other lab Macs they record the value and warn.
- Each milestone review records the numbers and explains regressions ([roadmap.md](roadmap.md) §4).

### 7.2 Security and fuzzing

| Requirement | Tests |
|---|---|
| NFR-SEC-01 APK code is untrusted | HelloProbe SELinux test (#36); malicious-agent fuzzing (#83, #92); virtio-gpu fuzzing |
| NFR-SEC-02 no automatic exposure of the home folder, `~/.ssh`, `~/Library`, `~/Documents` | T0: `VMDefinition` has no directory-sharing device; `SharedFolderService` refuses paths outside a share. T2: without opt-in, HelloFiles' picker shows no Mac folder. |
| NFR-SEC-03 integrations go through the policy and can be turned off | T0 `IntegrationPolicy` table; T2 each integration with its setting off ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §4.5, §5.5, §6.5, §7.3) |
| NFR-SEC-04 no signature bypass | T0 validation rules; T2 other signer refused by the host, and by Android through `AdbClient`; no hook in any build disables a rule (§3.3) |
| NFR-SEC-05 no secrets in logs | logging lint and compile-fail tests; T0 `Redactor`; T2 secret test (below) |
| NFR-SEC-06 ADB only on host loopback | T2: the ADB forward listens on `127.0.0.1` only (`lsof -nP -iTCP -sTCP:LISTEN`); with developer mode off, nothing listens on vsock 5555 |
| NFR-SEC-07 XPC clients validated | T1 authorization per endpoint; T2 another signing identity refused, a wrapper for another package gets `notAuthorized`, a modified or re-signed wrapper is refused |

Secret test ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T2-6): fixture secrets `APKRUN-FIXTURE-SECRET-<n>` are planted in a provider token (test Keychain), a URL query, a `.private` log argument, the console (bundle S), app logcat (HelloClipboard), the clipboard and a notification (HelloClipboard or HelloNotification), a shared-folder file name, a wrapper path, the Mac user name (the test account's name), and `persist.apkrun.test.secret`. The unzipped bundle is searched in raw, URL-encoded, base64, and UTF-16 forms, with and without `--include-logcat`. It must contain none of them.

Fuzz targets (#92):

| Target | Code | Source |
|---|---|---|
| virtio-gpu command decoder | GraphicsCore (`VirtioGPUProtocol`) | [../02-design/graphics.md](../02-design/graphics.md) §14, [../01-architecture/security-model.md](../01-architecture/security-model.md) §8 |
| resource table (resource IDs, backing, limits) | GraphicsCore (`ResourceTable`) | [../02-design/graphics.md](../02-design/graphics.md) §5.4, §11 |
| virgl command stream, against the renderer in a separate test process | GraphicsBridge, virglrenderer | [../02-design/graphics.md](../02-design/graphics.md) §11 |
| guest protocol frame decoder, Swift and Kotlin | GuestProtocol; `Guest/protocol` | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §16 |
| `InputBatch` decoder and injector batch validator of the agent | `Guest/guestd` | [../02-design/input.md](../02-design/input.md) §13, [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §16 |
| container reader (ZIP, `.apks`, `.xapk`, `.apkm`) | APKStoreCore (`ContainerReader`, ADR-0017) | [../02-design/package-store.md](../02-design/package-store.md) §4.2 |
| APK Signing Block parser | APKStoreCore (`APKSignatureVerifier`) | [../02-design/package-store.md](../02-design/package-store.md) §4.5 |
| aapt2 output parser, seeded with recorded outputs | APKStoreCore (`APKInspector`) | [../02-design/package-store.md](../02-design/package-store.md) §14 |
| Direct manifest parser (1 MiB) | UpdateCore | [../02-design/update-system.md](../02-design/update-system.md) §12, [../03-reference/direct-provider-manifest.md](../03-reference/direct-provider-manifest.md) |
| F-Droid `entry.jar` and index decoder (64 MiB) | UpdateCore (`FDroidIndexVerifier`, `FDroidIndexReader`) | [../02-design/update-system.md](../02-design/update-system.md) §4.5, §12 |
| GitHub release decoder (4 MiB) | UpdateCore (`GitHubProvider`) | [../02-design/update-system.md](../02-design/update-system.md) §12 |
| host operations from a malicious agent build | IntegrationCore, RuntimeCore (T2) | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §15 |

- Engines: libFuzzer for Swift and C targets (with the swift.org toolchain that #92 pins) and Jazzer for Kotlin targets ([../05-development/build-system.md](../05-development/build-system.md) §15). GraphicsBridge T1 tests and all Swift and C fuzz targets also run with Address Sanitizer and Undefined Behavior Sanitizer.
- Runs: 60 s per target in `fuzz-short` (T1) on every pull request; 1 h per target in nightly `fuzz-long` (T3).
- A crash opens an issue, and its reproducer goes into `Tests/Fixtures/fuzz/<target>/` as a permanent T1 regression input. A release needs no open fuzz crash ([roadmap.md](roadmap.md) §3.6).

### 7.3 Reliability

| Requirement | Tests |
|---|---|
| NFR-REL-01 recoverable after a crash during an update | T0 recovery table; T1 `APKRUN_STORE_FAULT` at every host step; T2 kill during `CommitInstall`; wrapper `pending` and `refreshing` recovery; maintenance variant (c) |
| NFR-REL-02 launchd restarts apkrund and clients reconnect | T2 `kill -9` recovery; G6 |
| NFR-REL-03 a dead agent is detected and reconnected | T2 agent kill with session continuity (#35, #73) |
| NFR-REL-04 no silent version mismatch | T0 handshake matrix; T1 XPC version mismatch; release smoke matrix with the previous stable image |
| NFR-REL-05 serial logs survive a VM crash | T2 forced stop during output (#5) |

Soak run: nightly, 60 minutes on one lab Mac with the custom image. It cycles launches and closes of HelloText, HelloGL, and HelloCompose, with suspend and resume every 10 minutes. It passes with no crash of apkrund, the launcher, or an agent, and with apkrund RSS growth below 10 % after the first 10 minutes.

### 7.4 Compatibility

| Requirement | Tests |
|---|---|
| NFR-CMP-01 fixtures first | P5; every T2 suite uses the fixtures of §4 |
| NFR-CMP-02 old wrappers keep working | T0 compatibility matrix ([../02-design/wrapper.md](../02-design/wrapper.md) §5.3) and unknown `formatVersion`; the release smoke matrix launches the stored wrapper of the oldest supported release (§4.8) |
| NFR-CMP-03 image updates keep userdata | T2 migration A → B (§3.5); image release candidate matrix (§9.3) |

- **App compatibility** ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10): `Tests/Compatibility/apps.json`. The F-Droid corpus runs nightly, the full list before each release. Each app gets a non-blank first frame within 20 s, then a 60 s `monkey` run with a fixed seed, then the same in compatibility mode if needed. Results go to `Tests/Compatibility/database/compatibility.json`, which CI validates against the schema.
- **macOS builds** (R-16): §9.4.
- **Hardware.** The reference Mac (M1, 16 GB) is the floor. Performance is compared only between runs on the same model identifier.

### 7.5 Localization and accessibility

| Requirement | Tests |
|---|---|
| NFR-L10N-01 English and Japanese | T0: every error code and human CLI message of the golden tests has `ja` text (#93, [../02-design/diagnostics.md](../02-design/diagnostics.md) §12); T2: pseudo-language run of APKRun.app ([../02-design/host-ui.md](../02-design/host-ui.md) §15); manual Japanese UI review (§8.7) |
| NFR-L10N-02 VoiceOver | T2 accessibility audit ([../02-design/host-ui.md](../02-design/host-ui.md) §15); manual VoiceOver walkthrough (§8.7) |

Android-side language behavior uses the fixtures: HelloSplit's Japanese resource (#43), Japanese IME input (#72), and locale sync (#86).

### 7.6 Upgrades

| Path | Test |
|---|---|
| APKRun N → N+1 | T2 Maintenance suite: 9000 → 9001 and variants (a)–(d) ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14) |
| current stable → release candidate | §9.1 step 4 |
| schema migrations | T0 goldens for every file and version shipped in a stable release in the last 24 months (release rule R5) |
| newer data read by an older build | T0: journal with a newer `v` is read-only; `dataCreatedByNewerVersion` writes nothing |
| image A → B, failure restore | T2 (§3.5); image release candidate matrix (§9.3) |
| old wrappers with a newer runtime | NFR-CMP-02 (§7.4) |
| RuntimeAPI and guest protocol majors | T0 handshake matrix; release smoke with the previous stable image (release rule R4) |

---

## 8. Manual checklists by release

### 8.1 Rules

- Check IDs are `C<version>-<n>`, where `<version>` is the release without the dot (`C04-2` is check 2 of v0.4). They are not milestone numbers.
- Manual checks run on the reference Mac with the release candidate build and, from v0.3 on, the custom image.
- Record each result in the release issue: the milestone review issue for v0.1–v0.5, and #95 for v1.0. A record holds pass or fail, the macOS build, the APKRun build, the image version, notes, and a screenshot where useful.
- A failed check blocks the release. Only a non-security check with a filed follow-up issue that the release notes name may be waived. Security and privacy checks cannot be waived.
- Every later release repeats the checks of earlier releases whose feature still exists. v1.0 runs all of them.
- A check that becomes automatable moves to T2 or T3 and leaves the list.

### 8.2 v0.1

| ID | Check | Task |
|---|---|---|
| C01-1 | HelloText text is sharp on a Retina display, and on a non-Retina external display if one is available | #68 |
| C01-2 | Trackpad and wheel scrolling follow the macOS natural-scrolling setting | #25 |
| C01-3 | Right-click opens HelloText's context menu at the pointer | #25 |
| C01-4 | With the US and the JIS keyboard layouts, `Hello, APKRun 123!` arrives exactly | #26 |
| C01-5 | `apkrun dev launch` from a new Terminal window shows HelloText without emulator chrome | #18, #27 |
| C01-6 | The G3 screen recording shows no visible tearing or stutter in HelloGL | #24 |

### 8.3 v0.2

| ID | Check | Task |
|---|---|---|
| C02-1 | Clicking back and forth between the HelloText and HelloCompose windows moves keyboard focus correctly | #31 |
| C02-2 | The Japanese IME candidate window appears next to the Android cursor in both fixtures | #72 |
| C02-3 | Copy and paste between TextEdit and HelloClipboard work both ways; the pasteboard prompt behavior of R-21 is recorded | #54 |
| C02-4 | Real sleep (`pmset sleepnow`) with HelloText open, wake after 2 minutes: HelloText responds and the guest clock is right | #70 |
| C02-5 | Logout with a running session: the stop log says `graceful` | #32 |
| C02-6 | The G6 extras of [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §14 until they are automated (§5) | #32 |

### 8.4 v0.3

| ID | Check | Task |
|---|---|---|
| C03-1 | The rollback notification and UI say that app data is not rolled back | #44 |
| C03-2 | The update notifications (including the 7-day notification) read correctly | #41 |

### 8.5 v0.4 (first public demo)

| ID | Check | Task |
|---|---|---|
| C04-1 | HelloText and IconLegacy icons have no gray system plate in Finder, the Dock, Spotlight, and the Apps view | #56 |
| C04-2 | Keep `HelloText.app` in the Dock, log out and in, launch it from the Dock | #57 |
| C04-3 | Launch `HelloText.app` from Spotlight by its label | #57 |
| C04-4 | Whether the Apps view lists the Desktop copy is recorded (OQ-22) | #57 |
| C04-5 | The Dock pin survives a wrapper refresh (R-20) | #77 |
| C04-6 | Launcher screens R, S, V, L, D show the right text and layout | #45 |
| C04-7 | The approval prompt for a copied wrapper is clear, and Return does not allow | #45, #90 |
| C04-8 | The uninstall choices sheet matches [../02-design/host-ui.md](../02-design/host-ui.md) §8 | #77 |
| C04-9 | The demo of [roadmap.md](roadmap.md) §3.4 runs on a clean Mac with the #36 image bundle picked in onboarding, and no Terminal | #50 |

### 8.6 v0.5

| ID | Check | Task |
|---|---|---|
| C05-1 | The notification permission prompt names the wrapper; notifications look right; R-19 behavior recorded | #55 |
| C05-2 | Sharing a folder inside `~/Documents`: the privacy prompt and its attribution are recorded (R-22) | #83 |
| C05-3 | Save to Mac: the Save panel flow works, and the file carries a quarantine attribute | #83 |
| C05-4 | Image and HTML copied in HelloClipboard paste correctly into Preview and TextEdit, and back | #81 |
| C05-5 | The Sparkle update UI and launcher screen U during a `ReleaseUpdateTest` update | #58 |
| C05-6 | The Android system update UI: ask-mode reminder, install, restart text | #88 |
| C05-7 | Troubleshooting pane and Report a Problem from a wrapper produce a bundle ([../02-design/diagnostics.md](../02-design/diagnostics.md) §12 T3-2) | #60, #61 |
| C05-8 | The F-Droid signer-mismatch text in Settings is clear | #52 |
| C05-9 | With macOS set to Japanese, HelloSplit shows its Japanese string (needs the locale sync of #86) | #43, #86 |

### 8.7 v1.0

| ID | Check | Task |
|---|---|---|
| C10-1 | VoiceOver walkthrough of onboarding, home, add flow, per-app settings, Settings, and uninstall | #93 |
| C10-2 | Japanese UI: complete, no truncation; pseudo-language screenshots reviewed | #93 |
| C10-3 | Onboarding on a fresh macOS user account | #67 |
| C10-4 | Microphone permission prompt timing recorded (OQ-29) | #85 |
| C10-5 | HelloAudio's tone, sweep, and click track are heard on the Mac, in sync | #84 |
| C10-6 | A distribution wrapper downloaded with Safari on a clean account opens after Gatekeeper approval; `spctl --assess` accepts it | #89 |
| C10-7 | APKRun.app passes `spctl --assess --type execute` and `stapler validate` | #89, #95 |
| C10-8 | License notices are visible in APKRun.app and in the image | #94 |
| C10-9 | Lid-close sleep with a running app, then wake | #70 |
| C10-10 | The v0.4 demo, repeated on the v1.0 candidate, with the image installed from the stable feed during onboarding | #95 |

---

## 9. Release testing

### 9.1 APKRun release candidate

1. Build the candidate from a tagged commit on `main`: Release configuration, Developer ID signed, and, from #89 on, notarized and stapled. The build number is higher than every published one (release rule R1).
2. On the candidate commit: T0, T1, and the release checks of §3.3 pass.
3. On the reference Mac with the candidate: every T2 suite, every closed gate check, the performance scenarios (no NFR miss, or an ADR with the measured numbers, [roadmap.md](roadmap.md) §3.6), the full compatibility list, the network checks, and, from #89 on, nightly notarization pass. No fuzz crash is open.
4. Publish the candidate on the beta channel first. Before #89 nothing is published ([../05-development/workflow.md](../05-development/workflow.md) §9.7), and this step runs against the local test appcast of the `maintenance` job instead. On the reference Mac, an install of the current stable release, switched to beta (`maintenance.channel`), updates to the candidate through the real appcast. The data checks of the N → N+1 test ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14) are repeated.
5. The release smoke matrix (§9.2) passes.
6. The manual checklist of the version (§8) is complete.
7. Promotion from beta to stable follows [../05-development/workflow.md](../05-development/workflow.md).

### 9.2 Release smoke matrix

T3, on the reference Mac. Each row runs with the current stable image and with the previous stable image (release rule R2).

| Check | Pass condition |
|---|---|
| boot | cold boot to `ready` |
| install and launch | HelloText installs and shows its first frame |
| update | HelloUpdate V1 → V2 automatically, `data HELLO` kept |
| rollback | HelloUpdate V3-broken is rolled back to V2 |
| wrapper generation | `HelloText.app` is generated and launches from Finder |
| old wrapper | the stored wrapper of the oldest supported release launches (NFR-CMP-02) |
| APKRun update | the current stable release updates to the candidate (§9.1 step 4) |
| image migration | A → B with userdata kept (NFR-CMP-03); a failed B′ restores B |

The matrix covers [roadmap.md](roadmap.md) §3.6 item 3. A failed cell blocks the release.

### 9.3 Image release candidate

1. Build the custom `-user` image on the image build machine ([../05-development/environment-setup.md](../05-development/environment-setup.md) §1) and sign the bundle with the release image key.
2. G2 with the reference diff: `expected-differences.yaml` exists for the new build ID and explains every difference.
3. The AndroidCustom suite passes with the candidate image, with no SELinux denial for the agents.
4. Migration from the current and the previous stable image to the candidate keeps userdata. HelloText's counter and HelloUpdate's data survive.
5. The candidate works with the current stable APKRun and with the oldest APKRun named in `minimumRuntimeVersion` (release rule R3).
6. The F-Droid corpus runs on the candidate. `boot-phases` and `cold-launch` are compared with the previous image.
7. A stable image ships at least once a quarter, plus extra releases for critical security fixes and urgent time zone changes (release rule R7).

### 9.4 New macOS builds

- The seed lab Mac runs the full T2 set and every closed gate check on each new macOS 27.x build (R-16).
- A failure opens an issue labeled `macos-regression` and updates R-16 in [risks.md](risks.md).
- Before an APKRun release, the reference Mac runs the current public macOS release.

### 9.5 Release rules and their checks

| Rule | Check |
|---|---|
| R1 build number | release job (§9.1 step 1) |
| R2 smoke tests with the current and the previous stable image | §9.2 |
| R3 `minimumRuntimeVersion` | §9.3 step 5 |
| R4 dropping a RuntimeAPI or guest protocol major | T0 handshake matrix; §9.2 with the previous stable image |
| R5 migration chain | T0 schema goldens (§4.6) |
| R6 Sparkle key and Developer ID not changed together | release job check of the key IDs and the certificate |
| R7 quarterly image | release calendar in [../05-development/workflow.md](../05-development/workflow.md); §9.3 |

---

## 10. How to add a test

1. **Pick the tier** with §2.6. Use the lowest tier that can fail for the reason under test.
2. **Put it in the right place.** T0 and T1 go next to the code (§2.2, §2.3). T2 goes in `Tests/IntegrationTests/<Area>Tests/`. A gate check goes in `Tests/AcceptanceTests/G<n>…`. A performance scenario goes in `Tests/PerformanceTests/`.
3. **Name it for the behavior**, not the method. For example `testUpdateWaitsWhileWindowIsOpen`.
4. **Use the fixtures of §4.** If no fixture covers the behavior, extend a fixture app or add one to §4.2 in the same pull request. Give it the package `io.apkrun.fixture.<name>` and `APKRUN-FIXTURE` events.
5. **Use existing fakes** (§3.2). A new fake goes into the owning module's `<Module>TestSupport` target and gets a T2 contract test.
6. **Wait for markers**, never sleep (P11). Give every wait a timeout and a failure message that names the missing marker.
7. **Add hooks only in Debug builds**, and add them to §3.3 and to [../03-reference/configuration.md](../03-reference/configuration.md) §5.1. The release check must cover them.
8. **Keep it isolated** (§3.9) and fast enough for its tier budget (§2.1).
9. **Update the task's Tests section** in its milestone file.
10. **Performance:** add a harness scenario and a baseline in a reviewed pull request (§3.8).
11. **Parsers of untrusted input:** add a fuzz target and a seed corpus (§7.2).
12. **Human judgment:** add a manual check to the version's list in §8 with an ID and the task.
13. **Gates:** a gate check changes only with a change to the gate's pass conditions in [roadmap.md](roadmap.md) §2.
