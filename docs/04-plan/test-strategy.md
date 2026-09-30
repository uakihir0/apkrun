# Test Strategy

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [roadmap.md](roadmap.md), [risks.md](risks.md), [open-questions.md](open-questions.md), [traceability.md](traceability.md), [issues/README.md](issues/README.md), [../05-development/build-system.md](../05-development/build-system.md), [../05-development/workflow.md](../05-development/workflow.md), [../05-development/environment-setup.md](../05-development/environment-setup.md), [../01-architecture/modules.md](../01-architecture/modules.md) |

This is the one test strategy for APKRun. The design documents list what each module tests. This document defines the tiers, the infrastructure, the fixtures, the gate checks, and the per-task test matrix that the milestone files ([issues/README.md](issues/README.md) §2) must follow. Where a design document labels a test with a tier that does not match §2, §2 applies (§2.8).

---

## 1. Principles

| ID | Principle | Reference |
|---|---|---|
| P1 | Every module with logic has unit tests (T0). Pure logic is tested at T0, never only at T2. | |
| P2 | Integration tests use a real Android guest. A behavior that crosses the host/guest boundary is verified at T2 against a real image. Tests with fakes alone never close such a task. | |
| P3 | Hardware acceptance runs on a real Apple Silicon Mac. T2 and T3 run on bare-metal Apple Silicon Macs with macOS 27, never in a VM and never on Intel. | [../00-product/scope.md](../00-product/scope.md) §1 |
| P4 | Graphics is not complete on mocks. A graphics task is done only when its T2 test with a real guest and Metal passes. T1 replay tests do not replace it. | |
| P5 | Fixtures first. T2 and T3 behavior checks use the controlled fixture apps (§4). A failing third-party APK is investigated only after the fixture that covers the same feature passes. | NFR-CMP-01 |
| P6 | Measure before optimizing. Performance work starts from a harness result (§7.1) and ends with a new one. | |
| P7 | Done means tested. A task is done when the tests of every tier in its Tests section pass, with logging, error handling, documentation, and the manual checks it lists. | [issues/README.md](issues/README.md) §4 |
| P8 | A skipped or quarantined test, or a test-only workaround, carries a TODO, a reason, and a tracking issue. | NFR-DEV-04 |
| P9 | Only gate checks validate. Nobody declares the core architecture validated before G3 passes, or the product concept validated before G9 passes. | |
| P10 | Lowest tier. A test lives in the lowest tier that can fail for the reason under test (§2.6). | this plan |
| P11 | No sleeps for synchronization. Tests wait for markers (`APKRUN-TEST:` lines, boot and perf markers, `APKRUN-FIXTURE` events) with a timeout. | this plan |
| P12 | Experiments are not tests. CI does not run `Experiments/`, and no test imports it. | NFR-DEV-05 |
| P13 | Security rules are tested negatively. Every policy has a test that tries the forbidden action and expects a refusal (§7.2). | |
| P14 | Tests use the product paths. They drive `RuntimeService`, RuntimeCore, or the CLI, not raw `adb shell` or `pm` commands, except for the allowlist in §3.3. | [../02-design/package-store.md](../02-design/package-store.md) §15 #027 |
| P15 | Test hooks exist only in Debug builds (and in `ReleaseUpdateTest` where listed). A release check proves they are absent (§3.3). | [../02-design/diagnostics.md](../02-design/diagnostics.md) §12 |
| P16 | Scope discipline applies to tests. A task's tests do not depend on features of later tasks. | |

---

## 2. Tiers

### 2.1 Summary

| Tier | Name | Needs | Location ([../01-architecture/modules.md](../01-architecture/modules.md) §1) | Runner | Trigger | Budget | Required to merge |
|---|---|---|---|---|---|---|---|
| T0 | Unit and model | only the test process: no VM, GPU, network, other processes, or XPC | next to the code (§2.2) | `swift test`, Gradle JVM `test`, `cargo test`, `pytest` | every PR, every push to `main` | ≤ 10 min | yes |
| T1 | Component and host integration | real host resources, no VM | next to the code, `<Module>SystemTests` targets and UI test bundles (§2.3) | `swift test`, `xcodebuild test` (UI), Gradle, `fuzz-short` | trusted `main` runs when provisioned; otherwise run on a real Apple Silicon Mac before merge; PR automation needs disposable capacity | ≤ 20 min | yes |
| T2 | VM integration | a real VM: the Linux test guest or an Android image | `Tests/IntegrationTests/` | `xcodebuild test -scheme IntegrationTests` on `apkrun-lab` | push to `main`; nightly; PRs only on disposable lab capacity (§2.4) | per suite, ≤ 15–120 min | not a merge check; the PR that closes a task must pass the suites the task lists |
| T3 | Acceptance | T2 plus the reference Mac, the network, credentials, long runs, or a person | `Tests/AcceptanceTests/`, `Tests/PerformanceTests/`, `Tests/Compatibility/`, checklists in §8 | `nightly.yml` jobs, gate scripts, people | nightly, gate closing, release candidates | nightly ≤ 8 h | no; gate checks close gates, release checks gate releases |

The CI workflows and jobs that run each tier are in [../05-development/build-system.md](../05-development/build-system.md) §15. A pull request merges only when every required CI check passes. The initial `ci.yml` workflow runs static checks, builds, and T0 tests on fresh GitHub-hosted VMs; it does not claim to run T1. T1 suites that need real host resources pass on a developer or reference Mac before merge, with the result linked to the pull request. PR automation for T1 requires disposable capacity. The static checks of [build-system.md](../05-development/build-system.md) §3 run in its `lint` job. This plan adds three checks to that job: the raw-ADB lint (§3.3), the compatibility database schema check (#090), and the release checks of §3.3 (in the `build` job for the Release configuration).

### 2.2 T0: unit and model tests

- **Definition.** Code under test runs in the test process. Allowed: fakes (§3.2), injected clocks, golden files, and a per-test temporary directory for ordinary reads and writes.
- **Not allowed.** Network (including loopback), subprocesses, XPC, Metal, `codesign`, the Keychain, real user defaults, sleeping, wall-clock time, and file system features beyond plain files (APFS clones, holes, modes, extended attributes). Tests that need any of these are T1.
- **Location.**
  - Swift: `Packages/<Module>/Tests/<Module>Tests/` (SwiftPM target `<Module>Tests`), `CLI/apkrun/Tests/`, and `Apps/<App>/Tests/` (XcodeGen unit test bundles for app models).
  - Kotlin: pure Kotlin modules that use no Android API (`Guest/protocol`), in `src/test/`.
  - Rust: `cargo test` in `Guest/vsockd`.
  - Python: `Images/tools/tests/` (pytest).
- **Runner.** Swift T0 (`test-swift`), Kotlin T0 (`test-guest`), and Python T0 (`test-images`) may run on fresh GitHub-hosted macOS VMs. Rust (`test-linux`) runs on `ubuntu-latest` (§3.1). `swift test` passes on a clean checkout without Gradle, AOSP, or network (NFR-DEV-02). T0 tests that read APKs use the committed copies of §4.1.
- **Budget.** The whole T0 set finishes in 10 minutes. A single test takes at most 1 s. A slower test moves to T1 or gets faster.
- **Flakiness.** None tolerated. No automatic retry. A flaky T0 test is a bug (§2.7).
- **Required to merge.** Yes.

### 2.3 T1: component and host integration tests

- **Definition.** Real host resources, no VM. Examples from the design documents:
  - processes: crash injection with `APKRUN_STORE_FAULT`, the instance lock between two processes, `aapt2` golden outputs, compile-fail tests;
  - the file system: `clonefile`, hole punching, and recovery points on a temporary APFS volume, file modes, registry atomic writes;
  - XPC: an in-process `NSXPCListener.anonymous()` with authorization per endpoint;
  - Metal and windows: GraphicsBridge, the recorded `kmscube` replay, `IOSurfaceLayerView` screenshots;
  - `codesign`: wrapper generation, validation, and approval;
  - local HTTP servers on `127.0.0.1`: the image downloader, a local feed, the GitHub REST mock;
  - UI: XCUITest against the embedded runtime fake;
  - JVM: agent code that uses Android APIs, tested against fakes of the Android services or Robolectric, or against a scripted host over real sockets;
  - Linux: the `vsock_loopback` test of `apkrun_vsockd`;
  - short fuzz runs (§7.2).
- **Location.** Swift: SwiftPM targets `Packages/<Module>/Tests/<Module>SystemTests/` next to `<Module>Tests` ([../05-development/build-system.md](../05-development/build-system.md) §2.1). UI tests: `Apps/<App>/UITests/`. Kotlin: `src/test/` of `Guest/agentruntime`, `Guest/guestd`, and `Guest/APKRunStore`. Fuzz targets: `Packages/<Module>/Tests/<Module>Fuzz/`, with corpora in `Tests/Fixtures/fuzz/<target>/`.
- **Runner.** A bare-metal `apkrun-ci` Mac with a logged-in GUI session (§3.1), or the developer's Apple Silicon Mac before merge. The `vsock_loopback` test runs in `test-linux` on `ubuntu-latest`. A T1 test whose resource is missing (Metal device, GUI session, APFS scratch volume) skips with a message that names the resource, so that `swift test` still works on any Mac ([build-system.md](../05-development/build-system.md) §15). A skip for a missing resource fails the job when the test is run on its required runner.
- **Budget.** 20 minutes for the PR set. Fuzz targets run 60 s each in the `fuzz-short` job. Long fuzz runs are T3 (§2.5).
- **Flakiness.** No automatic retry (§2.7).
- **Required to merge.** Yes.

### 2.4 T2: VM integration tests

- **Definition.** A real VM through Virtualization.framework: the Linux test guest (§3.4), the stock Cuttlefish image, the custom image, or a test bundle (§3.5).
- **Location.** `Tests/IntegrationTests/<Area>Tests/`, for example `LinuxGuestTests` ([../02-design/vm.md](../02-design/vm.md) §12), `AndroidBootTests`, `GraphicsTests`, `InputTests`, `WindowingTests`, `GuestAgentTests`, `StoreTests`, `UpdateTests`, `WrapperTests`, `HostUITests`, `DesktopIntegrationTests`, `DiagnosticsTests`, `DaemonTests`, `MaintenanceTests`, `CLITests`.
- **Runner.** `xcodebuild test -scheme IntegrationTests` on `apkrun-lab`. The test bundle is hosted by `APKRunTestHost`, which carries `com.apple.security.virtualization` ([../05-development/build-system.md](../05-development/build-system.md) §12.4). Tests that go through apkrund use the Debug identities (`io.apkrun.apkrund.dev`).
- **Suites.** The suites are groups inside `Tests/IntegrationTests`. They let a pull request run only what it needs.

| Suite | Contents | CI job | Budget |
|---|---|---|---|
| LinuxGuest | Linux test guest: devices, disks, bootconfig, `rng`, `gpu`, `virgl` | `linux-guest` | ≤ 15 min |
| AndroidStock | stock Cuttlefish image: boot, ADB, install and launch, graphics, input, windows, development-mode agent | `android-stock` | ≤ 60 min |
| AndroidCustom | custom `userdebug` image (from #035): Store Agent, updates, rollback, wrappers, desktop integration, diagnostics, SELinux, image migration | `android-custom` | ≤ 90 min |
| Maintenance | APKRun N → N+1 and its variants (`ReleaseUpdateTest`), feed-driven image update | `maintenance` | ≤ 120 min |

- **Triggers.** The jobs are in `integration.yml` ([build-system.md](../05-development/build-system.md) §15.1). `linux-guest` currently runs on matching pushes to `main` and manual dispatches from `main`. Pull-request T2 runs are disabled until disposable lab capacity is provisioned; labels request those runs only after that. Until then, a maintainer runs the reviewed commit on the reference Mac and links the result before the task-closing PR merges. The nightly `t2-all` job runs all four suites on `main`.
- **Before a task closes.** The pull request that closes a task runs every suite the task lists on disposable lab capacity, or a maintainer runs the reviewed commit on the reference Mac and links the result. A label alone never authorizes unreviewed code on a persistent self-hosted runner.
- **New macOS builds.** The full T2 set runs on every new macOS build on the seed lab Mac (R-16, §9.4).
- **Flakiness.** One automatic retry per test. The report marks every "passed on retry" (§2.7).

### 2.5 T3: acceptance tests

- **Definition.** End-to-end checks that need the reference Mac, the network, credentials, long run times, or a person.
- **Kinds.**

| Kind | Location | Runs | Retry |
|---|---|---|---|
| Gate checks G1–G9 (§5) | `Tests/AcceptanceTests/G<n>…`, run by `scripts/run-gate.sh G<n>` | when a gate task closes, then nightly as a regression | none |
| Release smoke matrix (§9.2) | `Tests/AcceptanceTests/ReleaseSmoke` | every release candidate, weekly on `main` | none |
| Performance (§7.1) | `Tests/PerformanceTests/` (`apkrun-perf`) | nightly (`perf`); NFR numbers from the reference Mac | none; the regression rule of §7.1 applies |
| Compatibility (§7.4) | `Tests/Compatibility/` | corpus nightly; full list before each release | none |
| Network checks | `Tests/AcceptanceTests/Network` | nightly | one; then classified `external` (§2.7) |
| Long fuzzing (`fuzz-long`), soak, notarization (`notarize`: the Release app and a distribution wrapper) | §7.2, §7.3, #088 | nightly | none |
| Manual checklists (§8) | the release issue | every release candidate | not applicable |

- **Budget.** The nightly T3 run finishes in 8 hours per machine.
- **Required.** T3 does not gate pull requests. A gate check closes its gate. Release checks gate the release (§9).

### 2.6 Choosing a tier

1. Can the behavior be reached with an injected fake and in-process code? Then T0.
2. Does it need a real host resource from §2.3, but no guest? Then T1.
3. Does it need a guest kernel or Android? Then T2. Use the Linux test guest when Android is not needed.
4. Does it need the reference Mac's numbers, the Internet, credentials, a second Mac user session, or a person? Then T3 or a manual check (§8).

A behavior may have tests in several tiers. The rule is that every behavior has its lowest-tier test, and that crossing the VM boundary has a T2 test (P2).

### 2.7 Flakiness and quarantine

- **Flaky** means that a test both passes and fails on the same commit and machine.
- **T0 and T1.** No retry. The owner fixes the test the same working day or quarantines it.
- **T2.** One automatic retry, recorded. A test that passes only on retry three times in 7 days is quarantined.
- **T3.** Gate checks and the release smoke matrix are never retried and never quarantined. Network checks get one retry. When the failure is a connection or DNS error to a third-party host, the result is `external`, not `fail`. Three `external` results in a row open an issue.
- **Quarantine.** A quarantined test carries a tag with its issue link (TODO, reason, tracking issue, NFR-DEV-04). It still runs nightly, but its result does not fail the job. After 14 days it is fixed or deleted. Deleting it needs replacement coverage in another tier, recorded in the task. Security negative tests (§7.2) cannot be quarantined. A task cannot close while one of its listed tests is quarantined.
- **Red `main`.** A T2 failure on `main` blocks further merges until the change is fixed or reverted. A T3 failure opens an issue with the label `nightly-failure` ([build-system.md](../05-development/build-system.md) §15). The owner fixes or reverts the breaking change within one working day.

### 2.8 Tier labels in the design documents

The Tests sections of the design documents use the tiers of this section. When a design document and this section disagree, this section applies, and the design document is fixed in the same pull request.

- The test IDs of [../02-design/diagnostics.md](../02-design/diagnostics.md) §12 (`T1-1` … `T3-2`) are stable names used by the task entries. Their tier is the Tier column of that table, not the prefix. For example, T1-1 is a T0 test and T2-1 is a T1 test.
- Gate checks are T3 (§5). The T2 rows that the design documents mark as a gate's "building block" must pass before the gate check runs.
- Kotlin tests follow one rule. Pure Kotlin modules without Android APIs are T0. Code that uses Android APIs, tested against fakes, Robolectric, or a scripted host, is T1. With this rule the JVM rows of guest-protocol.md, guest-components.md, input.md, and desktop-integration.md are T1 as written.

---

## 3. Test infrastructure

### 3.1 Machines and runners

Runner labels and setup are in [../05-development/environment-setup.md](../05-development/environment-setup.md) §6.

| Machine | Description | Runs |
|---|---|---|
| `ubuntu-latest` | a hosted Linux runner | `test-linux`: `cargo test`, the T1 `vsock_loopback` test; the F-Droid test repository build (`fdroid update`) |
| `xcode-27` | a fresh GitHub-hosted macOS 27 VM | `ci.yml`: static checks, builds, and T0 Swift tests |
| `apkrun-ci` | a self-hosted Apple Silicon Mac, macOS 27, the toolchain of [environment-setup.md](../05-development/environment-setup.md) §2, a dedicated user `apkrun-ci` with automatic login and a GUI session, an APFS scratch volume | trusted default-branch/manual T1 Swift, Kotlin, and Python checks, XCUITest, `fuzz-short`; nightly `fuzz-long` |
| `apkrun-lab`, the reference Mac | the reference Mac of OQ-02 in [open-questions.md](open-questions.md) (M1, 16 GB), bare metal, set up as in §3.6 | trusted `main`/nightly runs, gate checks, NFR numbers and baselines, release smoke matrix, notarization, manual checklists |
| Seed lab Mac | an extra bare-metal Apple Silicon Mac that installs every macOS 27.x beta and release | the full T2 set and the gate checks on each new build (R-16, §9.4) |
| Information Mac (optional) | an extra lab Mac with an M3 or later chip | the nightly T2 set; its performance numbers are for information only |
| AOSP builder | the x86-64 Linux builder of [environment-setup.md](../05-development/environment-setup.md) §5 ([../00-product/scope.md](../00-product/scope.md) §1) | custom image builds and test image bundles (§3.5) |

T2 and T3 never run inside a VM (P3). Hosted macOS VMs may run T0 tests that need only the process and ordinary temporary files. T1 requires its declared host resources, and T2/T3 require bare-metal Apple Silicon. A pull-request T1/T2/T3 job must use a disposable runner; until one is provisioned, run the reviewed commit manually on the required Mac and attach the result.

### 3.2 Fakes

| Fake | Replaces | Used by |
|---|---|---|
| fake `RuntimeService` | apkrund over XPC | CLI golden tests ([../02-design/cli.md](../02-design/cli.md) §6.3), host UI model tests ([../02-design/host-ui.md](../02-design/host-ui.md) §15) |
| embedded runtime fake | apkrund for UI tests | XCUITest for onboarding, the add flow, uninstall choices, and approval ([host-ui.md](../02-design/host-ui.md) §15) |
| in-memory fake agent | the Guest Agent peer of `GuestConnection` | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §16 T0 |
| scripted host | the host peer of the Kotlin agent server | [guest-protocol.md](../02-design/guest-protocol.md) §16 T1 |
| fakes of Android services, fake `InputConnection` | Android framework services | [guest-components.md](../02-design/guest-components.md) §12, [input.md](../02-design/input.md) §13, [desktop-integration.md](../02-design/desktop-integration.md) §15 (Robolectric allowed there) |
| fake `StoreAgentChannel` with scripted Android state | the Store Agent and the ADB channel | [package-store.md](../02-design/package-store.md) §16 |
| fake store, fake runtime, fake `SessionRegistry`, scripted runtime, counting fake provider, fake network path | package store, runtime, and providers | [update-system.md](../02-design/update-system.md) §16 |
| fake supervisor, fake store | RuntimeHost parts | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| fake modules | RuntimeHost dependencies | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §14 |
| VirtioDeviceCore fakes | the VZ custom virtio device API | [../02-design/graphics.md](../02-design/graphics.md) §14 |
| synthetic `FrameSource`, scripted wrapper | GraphicsCore frames, wrapper acknowledgements | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §5.5, §13 |
| simulated pasteboard and agent | `NSPasteboard` and the agent | [desktop-integration.md](../02-design/desktop-integration.md) §15 |
| fake UI client | the approval UI | [wrapper.md](../02-design/wrapper.md) §16 |
| manual clock | the wall clock | IdleController, scheduler, marker rules |
| test Keychain | the login Keychain | provider tokens in the secret test ([diagnostics.md](../02-design/diagnostics.md) §12 T2-6) |

Rules:

- A fake lives in a test-support target (`<Module>TestSupport`) of the module that owns the protocol it implements. Tests in other modules import that target and do not write their own fake of the same protocol.
- A fake of guest behavior has a contract test: a T2 test that checks the same behavior against the real guest. When the two disagree, the fake is fixed.

### 3.3 Test hooks, test builds, and the raw-ADB allowlist

All hooks below are compiled into Debug builds only, unless the Builds column says otherwise. No hook, in any build, turns off a package validation rule ([../../AGENTS.md](../../AGENTS.md) §4, invariant 10). Tests that need Android's own refusal install directly through `AdbClient` ([package-store.md](../02-design/package-store.md) §15 #038). The environment variables are listed in [../03-reference/configuration.md](../03-reference/configuration.md) §5.1.

| Hook | Effect | Builds | Used by |
|---|---|---|---|
| `APKRUN_STORE_FAULT=<kind>:<step>` | injects a store fault at a host step | Debug | [package-store.md](../02-design/package-store.md) §16 T1, #038 |
| `APKRUN_GRAPHICS_FAULT=rendererInit` | renderer initialization fails | Debug | [diagnostics.md](../02-design/diagnostics.md) §12 T2-4 (c) |
| `APKRUN_RUNTIME_FAULT=rejectAgent:guest` | apkrund rejects the Guest Agent handshake | Debug | [diagnostics.md](../02-design/diagnostics.md) §12 T2-4 (d) |
| `APKRUN_LAUNCHER_TEST_NO_RUNTIME=1` | the launcher runs without a runtime (screen R) | Debug | [wrapper.md](../02-design/wrapper.md) §15 #044 |
| `APKRUN_TEST_HEADLESS_LAUNCH=1` | `launch` opens a session owned by apkrund that discards its frames; from #032 until #068 removes it | Debug | [runtime-daemon.md](../02-design/runtime-daemon.md) §13 #032, the G6 stages |
| `APKRUN_TEST_MARKER_TIMEOUT=<n>s` | shortens the maintenance marker timeout | Debug, `ReleaseUpdateTest` | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 variant (c) |
| `APKRUN_HOME` | relocates the data root | Debug (`apkrun dev`, debug apkrund, test hosts). CLI commands other than `apkrun dev` ignore it ([cli.md](../02-design/cli.md) §3.6), so tests of those commands against an unregistered apkrund run in a separate macOS test user account ([diagnostics.md](../02-design/diagnostics.md) §12 T2-1) | isolation (§3.9) |
| `apkrun dev power sleep\|wake` | injects host sleep and wake messages | Debug | [runtime-daemon.md](../02-design/runtime-daemon.md) §13 #069 |
| test-only readback mode | reads the scanout resource for the #022 replay test and samples pool buffers for the #023 tearing test, excluded from the readback counter | test builds with the `APKRUN_TEST_READBACK` compile flag | [graphics.md](../02-design/graphics.md) §12 #022, #023 |
| `APKRUN_TEST_IMAGE_FEED_URL=<url>` | points `ImageFeedClient` at a local feed server, which may be `http://127.0.0.1`. The other loopback URLs of Debug builds are the Direct and F-Droid provider URLs of the local update server ([update-system.md](../02-design/update-system.md) §12) | Debug | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §13 #087 step 8 |
| `APKRUN_TEST_IDLE_SECONDS=<n>` | replaces the `HIDIdleTime` value of the apply gate | Debug | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §13 #087 step 8 |
| `APKRUN_TEST_POWER=ac\|battery:<percent>` | replaces the power source of the apply gate | Debug | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §13 #087 step 8 |
| `ReleaseUpdateTest` configuration | Release code; builds 9000 and 9001 (9001 adds `Resources/test-build-marker`); local appcast; test Sparkle key | `ReleaseUpdateTest` only | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| Sparkle test user driver | accepts every prompt. `APKRUN_TEST_INSTALL_CHOICE=closeApps\|whenClosed` answers APKRun's install dialog, and the launch argument `--test-check-for-updates` starts a user-initiated check | `ReleaseUpdateTest` only | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| settings used as switches | `runtime.idleSuspendMinutes = 1`, `runtime.idleStopMinutes = 2` | all (they are ordinary settings) | #069, #070 |
| hand-built wrapper with `runtime.minimumVersion = 99.0` in `wrapper.json` | `scripts/dev/make-wrapper.sh --minimum-version 99.0`; the value is normally the launcher's build constant, not a setting ([../03-reference/configuration.md](../03-reference/configuration.md) §4) | Debug (the script) | wrapper screen V, #044 |
| `androidboot.apkrun.test.*` | `marker=<value>`, `fail_health=1`, `fail_boot=1` | test image bundles only ([../02-design/android-image.md](../02-design/android-image.md) §6.2) | §3.5 |
| `androidboot.apkrun.devmode=1` | adbd on vsock 5555 on the custom image | custom image, user-controlled | §3.5, #035 |

Release checks (`scripts/release/check-release-build.sh`, run by the `build` job on every Release build and again in the release jobs, [../05-development/build-system.md](../05-development/build-system.md) §3.1):

- The Release binaries contain no `APKRUN_*_FAULT` string, no `APKRUN_TEST_*` string (such as `APKRUN_TEST_HEADLESS_LAUNCH`), no `APKRUN_LAUNCHER_TEST_NO_RUNTIME`, no test key or test key ID from `Tests/Fixtures/signing/`, and no `ReleaseUpdateTest` setting.
- A release image manifest contains no `androidboot.apkrun.test.*` key ([android-image.md](../02-design/android-image.md) §6.2).
- `ImageTrustStore` in a Release build contains only release key IDs ([android-image.md](../02-design/android-image.md) §10.1).

Raw-ADB allowlist. The lint of [package-store.md](../02-design/package-store.md) §15 #027 rejects `adb shell` and `pm ` strings outside `ADBStoreAgentChannel` and `AdbClient`. These paths are exempt because their design says they use ADB directly: `scripts/dev/` (for example `validate-input-coordinates.sh`, [input.md](../02-design/input.md) §12 #024), `Tests/Compatibility/` (the `monkey` run, [diagnostics.md](../02-design/diagnostics.md) §10.4), and `Images/tools/reference/` (the reference capture). T2 tests that need a shell command go through `AdbClient`.

### 3.4 Linux test guest

Defined in [../02-design/vm.md](../02-design/vm.md) §12:

- Kernel: pinned Alpine `linux-virt`, fetched and hash-checked by `scripts/fetch-test-linux.sh` (hash in `ThirdParty/ThirdParty.lock.json`), kept in the runner cache.
- initramfs: built by `scripts/build-test-initramfs.sh` with `/init` from `Tests/Fixtures/linux/init`.
- Command line: `apkrun.test=blk,net,vsock,ports,rng,gpu,virgl` selects checks; `apkrun.test.poweroff=1` powers off at the end.
- Output on `hvc0`: `APKRUN-TEST: boot ok`, then `APKRUN-TEST: <name> ok|fail <detail>` per check, then `APKRUN-TEST: done`.
- Disks: raw test disks with known content, created at test time by the scripts in `Tests/Fixtures/linux/`.
- Harness: `Tests/IntegrationTests/LinuxGuestTests`, VirtualMachineCore only, timeout 60 s.

The harness fails a run when any check prints `fail`, when a requested check prints nothing, or when `done` does not appear within the timeout. The console log is an artifact of every run (§3.7).

### 3.5 Android images and test bundles

| Image | Source | Used by |
|---|---|---|
| Stock Cuttlefish `aosp_cf_arm64_only_phone-userdebug`, build 16373615, Android 17 (API 37) | Android CI, fetched by the #008 tool, pinned in the image manifest | AndroidStock suite, M1–M4 tasks, development mode |
| Custom `apkrun_arm64-trunk_staging-userdebug` | AOSP builder ([android-image.md](../02-design/android-image.md) §11.5) | AndroidCustom suite from #035, test bundles |
| Custom `-user` | the image build machine, release signing | image release candidates, release smoke matrix, performance |
| Current and previous stable images | the published image feed | release smoke matrix (§9.2) |
| Reference captures (`default`, `target`, `swiftshader`) | `Images/tools/reference/capture.sh` → `Images/reference/<buildId>/` | the G2 reference diff ([android-image.md](../02-design/android-image.md) §8.4), `BootPhaseDetector` golden tests |

Test bundles are built from the custom `userdebug` image, because the handlers of the `androidboot.apkrun.test.*` keys, the Guest Agent health report that `fail_health` changes, and the script of bundle S are in the custom product ([issues/M05-custom-android-image.md](issues/M05-custom-android-image.md) #035). Bundle P is the exception: it only changes the kernel command line, so #031 builds it from the stock image, and it is rebuilt from the custom image in #035. Test bundles are never published.

| Bundle | Difference from its base | Used by |
|---|---|---|
| A | none | migration ([android-image.md](../02-design/android-image.md) §12.4) |
| B | A with `androidboot.apkrun.test.marker=B` (read as `ro.boot.apkrun.test.marker`) and a higher version | migration A → B |
| B′ | B with `androidboot.apkrun.test.fail_health=1` | failed migration B → B′, automatic restore to B |
| F | `androidboot.apkrun.test.fail_boot=1` | `bootFailure` verdict ([diagnostics.md](../02-design/diagnostics.md) §12 T2-4 b), bundles after a boot failure |
| P | a kernel command line that names a missing init (`init=/apkrun-test-missing`), so the kernel panics | boot-loop guard ([runtime-daemon.md](../02-design/runtime-daemon.md) §14) |
| S | a test-only init script that writes a fixture secret to `/dev/kmsg` and sets `persist.apkrun.test.secret` | secret fixture test ([diagnostics.md](../02-design/diagnostics.md) §12 T2-6) |

Signing: each `apkrun-lab` machine creates its own development key with `python3 -m apkrun_image keygen`, like a developer ([android-image.md](../02-design/android-image.md) §10.1). The runner signs test bundles with it, and Debug builds trust it. The committed key `test-image-ed25519` (§4.4) is used only for T0 and T1 signature vectors with an injected trust store.

### 3.6 Lab Macs and the reference Mac

The runner setup is in [../05-development/environment-setup.md](../05-development/environment-setup.md) §6.2–§6.3. In addition, every lab Mac (`apkrun-lab`, the seed Mac, the information Mac):

- runs on AC power with Low Power Mode off, runs `caffeinate -d` during a run, and has no other VMs running ([diagnostics.md](../02-design/diagnostics.md) §9.2);
- runs the runner in the GUI session of the `apkrun-ci` user with automatic login, and has a second local test account (portable wrappers #089, host-only doctor, fresh-account checks);
- has the permissions that macOS asks for once: Accessibility for the harness (`input-latency`, [environment-setup.md](../05-development/environment-setup.md) §6.3), Screen Recording for window captures, notifications for the fixture wrappers, and Microphone for apkrund (#084, [desktop-integration.md](../02-design/desktop-integration.md) §8.2). A test that finds a permission missing fails with `runnerMissingPermission`. It never clicks a prompt;
- the lab Mac that runs the audio and microphone T3 jobs (#083, #084) has a virtual loopback audio device as its default output and input. #083 picks the device and documents its setup ([environment-setup.md](../05-development/environment-setup.md) §6.2). A lab Mac without one skips these jobs, and the v1.0 checklist covers them by hand (§8.7);
- runs one VM at a time. Suites are serialized per machine;
- keeps a runner cache (§4.1) with pinned SHA-256 values. No test downloads a large artifact during the run.

The reference Mac also follows the rule "clean build from `main`" for gate checks ([roadmap.md](roadmap.md) §2) and runs the public macOS release that users have, never a seed.

### 3.7 Artifacts on failure

| Tier | Collected |
|---|---|
| T0, T1 | xcresult and JUnit reports; fuzz reproducers; golden diffs (actual, expected, and a diff image or text); crash reports of test processes |
| T2 | T0/T1 items, plus: every `hvc` console log; `boots.jsonl` and `launches.jsonl`; the apkrund mirror log and `log show` output for the `io.apkrun` subsystems; logcat; a diagnostics bundle with `--include-logcat` (or a host-only bundle when apkrund is down); screenshots of every open window; a listing of the data root; the store journal; the image `state.json`; crash reports of apkrund, the launcher, and the app |
| T3 | T2 items, plus perf `results.json` and `summary.md`, gate evidence (§5), and screen recordings |

Retention: pull request runs 14 days, nightly runs 30 days, gate evidence and release candidate artifacts permanently.

Artifacts come from test machines with fixture data only, but the diagnostics redactor still runs on bundles, and the secret test (§7.2) makes sure it works.

### 3.8 Performance baselines

- The harness is `swift run apkrun-perf <scenario> [--runs] [--warmup] [--output] [--baseline]` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §9).
- Baselines: `Tests/PerformanceTests/baselines/<model identifier>.json`. Only a reviewed pull request that says why may change one.
- The first report of every scenario is attached to the #070 issue and becomes the initial baseline.
- Runs use a Release build, the release candidate's `-user` image when one exists, and fixtures wrapped with `apkrun wrap --output`.
- The regression rule is in §7.1.

### 3.9 Isolation

- T2 uses Debug builds with their `.dev` identities, so a test never touches an installed release ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).
- Each T2 suite starts from an empty data root: the harness unregisters the Debug agent and deletes the `APKRun-Dev` root, or gives test hosts and `apkrun dev` a fresh `APKRUN_HOME`.
- Wrappers go into a per-suite folder (`apkrun wrap --output`). Tests of `~/Applications` behavior (#056, #078) remove their wrappers in teardown.
- Update sources are local: `scripts/dev/update-server.py`, the local appcast, the local image feed, the GitHub mock, and the served F-Droid test repository, all on `127.0.0.1`. T2 has no Internet access. The #006 network test fetches from a server on the host, and its Internet half is a T3 network check ([../02-design/vm.md](../02-design/vm.md) §7).
- A teardown that fails marks the machine dirty. The next suite starts with Reset Android ([runtime-daemon.md](../02-design/runtime-daemon.md) §9.5) and a new data root.

---

## 4. Fixtures

### 4.1 Rules

- **Fixture apps** are one Gradle project in `Tests/Fixtures/AndroidApps/`, built by `scripts/build-fixtures.sh` into `Tests/Fixtures/AndroidApps/out/` ([../05-development/build-system.md](../05-development/build-system.md) §8). Each app has a CamelCase project name and the package `io.apkrun.fixture.<lowercase name>` ([modules.md](../01-architecture/modules.md) §5). Variants of one app share its package.
- **Committed copies.** T0 tests read committed prebuilt APKs from `Tests/Fixtures/apks/`, so `swift test` needs no Gradle (NFR-DEV-02). `scripts/build-fixtures.sh` refreshes them. A CI check fails when a copy is older than its sources.
- **Size.** A committed fixture file is at most 10 MiB. Larger inputs are generated at test time from a seed (for example the 1.5 GiB file of #082) or kept in the runner cache with a pinned SHA-256 (Cuttlefish artifacts, AOSP builds, the F-Droid corpus, stable images).
- **Event log.** Fixture apps report what they observe to logcat with the tag `APKRUN-FIXTURE` and a message `<event> <detail>`, so `logcat -v tag` shows lines like `I/APKRUN-FIXTURE: click 3`. Tests read them through `AdbClient` with a `FixtureLog` helper that starts the stream before the action. On the custom image, tests use developer mode for this. Fixtures never log secrets except where a test plants a fixture secret on purpose (§7.2).
- **Determinism.** Fixtures have no network access except HelloLinks (which only asks the host to open links), no ads, no analytics, and no random behavior unless a seed is passed.
- **Signing.** Fixture apps are signed with test keys (§4.4). Nothing built with a test key ships.

### 4.2 Fixture apps

| App | Package | What it does | Events | Used by |
|---|---|---|---|---|
| HelloText | `io.apkrun.fixture.hellotext` | a Count button with a persistent counter, a text field, a password field, a context menu, a Details screen (for Back), a time label, an adaptive vector icon | `start counter=<n>`, `click <n>`, `text <JSON string>`, `screen <name>`, `contextmenu`, `config locale=<tag> tz=<id> 24h=<bool>` | G4–G9 building blocks, #016, #017, #024–#026, #071, #085, migration, perf |
| HelloCompose | `io.apkrun.fixture.hellocompose` | a Compose `LazyColumn`, a `TextField` | `scroll first=<index>`, `text <JSON string>` | #024, #029, #030 (G5), #071; installed with `adb install` as the unmanaged package of #077 |
| HelloGL | `io.apkrun.fixture.hellogl` | a GLES animation, and an alternating-color mode selected by an intent extra | `renderer <GL_RENDERER>`, `fps <average>` every 10 s | #022, #023 (G3), #029, #068, `hellogl-fps` |
| HelloWebView | `io.apkrun.fixture.hellowebview` | a WebView showing a bundled local page | `loaded` | #029, compatibility |
| HelloNotification | `io.apkrun.fixture.hellonotification` | the notification set of [desktop-integration.md](../02-design/desktop-integration.md) §5.5 | `posted <id>`, `intent <action>` | #054, secret test |
| HelloClipboard | `io.apkrun.fixture.helloclipboard` | a text field, a Copy button with a known string, a view of the current clip | `clip <text>` (logs its clipboard text on purpose) | #053, #080, secret test |
| HelloLinks | `io.apkrun.fixture.hellolinks` | the link set of [desktop-integration.md](../02-design/desktop-integration.md) §7.3 | `open <scheme>` | #081 |
| HelloFiles | `io.apkrun.fixture.hellofiles` | accepts shares, opens the picker, shows names, sizes, and SHA-256 | `file <name> <size> <sha256>` | #082 |
| HelloFilesPeer | `io.apkrun.fixture.hellofilespeer` | a second package with the HelloFiles picker, without shared-folder access | as HelloFiles | #082 ("second fixture package without access") |
| HelloAudio | `io.apkrun.fixture.helloaudio` | a 1 kHz tone, a sweep, a click track; records 5 s | `play <name>`, `recorded <frames> <peak>` | #083, #084 |
| HelloUpdate | `io.apkrun.fixture.helloupdate` | versions of §4.3 | `version <code>`, `data <value>` | #066 (V1 only, the first user, which adds it), #037–#043 (the other variants), #050–#052, #049 (G9), G7 |
| HelloSplit | `io.apkrun.fixture.hellosplit` | base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, an install-time feature split; a native library; a Japanese string | `native ok`, `string <locale>` | #027 (the first user, which adds it), #042, #073, #078 |
| HelloNative | `io.apkrun.fixture.hellonative` | an arm64-v8a variant and an armeabi-v7a-only variant | `native ok` | ABI check ([package-store.md](../02-design/package-store.md) §4.6) |
| HelloLegacySig | `io.apkrun.fixture.hellolegacysig` | v1 signature only, targetSdk 29 | none | signature floor tests |
| OtherInstaller | `io.apkrun.fixture.otherinstaller` | declares `REQUEST_INSTALL_PACKAGES` and tries to update another fixture | `session <status>` | #039 |
| IconLegacy | `io.apkrun.fixture.iconlegacy` | a legacy PNG launcher icon with transparency | none | #055 |
| OddName | `io.apkrun.fixture.odd_name` | a label with `/`, `:`, and an emoji ZWJ sequence | none | #045 name sanitizing, `_` → `-` mapping ([wrapper.md](../02-design/wrapper.md) §4), #078 |
| HelloProbe | `io.apkrun.fixture.helloprobe` | an ordinary `untrusted_app` that tries to connect to the agents' abstract sockets and to open `AF_VSOCK` | `probe <target> <result>` | #035 SELinux negative test |

Combinations used by name in the design documents:

- "Two fixture windows" in the clipboard loop test ([desktop-integration.md](../02-design/desktop-integration.md) §4.5): HelloClipboard and HelloText.
- "The APKRun-managed fixture" of #039: HelloUpdate.
- "A fixture app in `untrusted_app`" ([guest-components.md](../02-design/guest-components.md) §12): HelloProbe.

### 4.3 Derived packages

| Variant | Build | Purpose |
|---|---|---|
| HelloUpdate V1 | versionCode 1, key A | writes `HELLO` to `files/data.txt` on first launch. With the intent extra `fgs`, it starts a `mediaPlayback` foreground service and logs `fgs started` (#040) |
| HelloUpdate V2 | versionCode 2, key A | reads `files/data.txt` and logs `data HELLO`; writes `files/v2.txt` |
| HelloUpdate V2-other-signer | versionCode 2, key B | `signerMismatch` on the host, `CONFLICT` in Android (#038) |
| HelloUpdate V3-broken | versionCode 3, key A | crashes 2 s after launch (#043) |
| HelloUpdate V4 | versionCode 4, key A | the normal update after a skipped version ([update-system.md](../02-design/update-system.md) §15 #043) |
| HelloUpdate rotation variants | V2 signed with lineage A → B, with and without `INSTALLED_DATA`; rotation back with and without `ROLLBACK` | T0 validation matrix (#041) |
| Corrupted HelloUpdate V2 | one flipped byte in `classes.dex` | `invalidSignature` (#041) |
| Container fixtures | from HelloSplit and HelloText: split files, `.apks` (bundletool), `.xapk` with and without OBB, `.apkm` plain and non-ZIP, `.aab`, a zip bomb, a `../` entry, a symlink entry, 600 entries, and a ZIP64 container generated at test time | [package-store.md](../02-design/package-store.md) §16 T0 |
| Generated `.apks` | 3 ABIs, 6 densities, 10 languages, one feature split, `requiredSplitTypes` | split selection (#042, #073) |

"HelloUpdate V4" is the fixture. "Rule V4" is the validation rule of [update-system.md](../02-design/update-system.md) §6. Tests and documents always write the prefix.

### 4.4 Signing keys

All test keys are in `Tests/Fixtures/signing/`, named `test-*` ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7), and never used for anything shipped.

| Key | Purpose |
|---|---|
| `test-fixture-a.jks` | default signer of all fixture apps |
| `test-fixture-b.jks` | the "other signer" and the rotation target |
| `test-fdroid-repo.jks` | signs the F-Droid test repository index (#051) |
| `test-sparkle-ed25519` and `.pub` | signs the local appcast for `ReleaseUpdateTest` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2) |
| `test-image-ed25519` and `.pub` | T0 and T1 signature vectors for image manifests and feeds, with an injected trust store |
| `test-guest-dev.jks` | development signing of the Guest Agent and Store Agent APKs on the stock image ([guest-components.md](../02-design/guest-components.md) §2) |

Developer ID, notarization credentials, the release Sparkle key, and the release image key are CI secrets ([../05-development/workflow.md](../05-development/workflow.md) §9.2). Only jobs in the environments `signing` and `release` can read them. The Developer ID and the notarization credentials are in both: the release job, the `maintenance` T2 job (which Developer ID signs the `ReleaseUpdateTest` bundles, #057), and the nightly notarization check (#088) read them. The release Sparkle key and the release image key are only in `release`.

### 4.5 Update repositories and servers

| Fixture | Location | Served by | Used by |
|---|---|---|---|
| Local provider repository | `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/` ([update-system.md](../02-design/update-system.md) §15 #037) | read directly | #037, #038, G7 |
| Temporary repositories | copies of the local repository with V3-broken and V4 added | the test | #043 |
| Direct manifests | the Local fixtures served as Direct manifests ([../05-development/build-system.md](../05-development/build-system.md) §8.1), plus variants in `Tests/Fixtures/update-repos/direct/`: valid, versionCode mismatch, wrong `sha256`, missing `sha256`, HTTP URL, relative URL, oversized, wrong package | `scripts/dev/update-server.py` on `127.0.0.1` (Debug only), with `--delay <seconds>` | #050, `update-check-launch` (with a 5 s delay), #074 (30 s delay) |
| F-Droid test repository | sources in `Tests/Fixtures/update-repos/fdroid/`; the repository is built in CI with `fdroid update` and `test-fdroid-repo.jks` | a local static server | #051 (two HelloUpdate versions, a tampered `entry.jar`) |
| GitHub recorded responses and mock | `Tests/Fixtures/update-repos/github/recorded/` | T0 reads them; the T1/T2 mock serves them | #052 (misleading tag `v0.1`, `ambiguousAsset`) |
| GitHub fixture repository | `apkrun-fixtures/helloupdate-releases` | github.com | #052 T3 nightly |
| Local appcast | `Tests/Fixtures/runtime-updates/appcast/` | a local server | #057 (`ReleaseUpdateTest` 9000 → 9001) |
| Local image feed | `Tests/Fixtures/runtime-updates/image-feed/` (valid, tampered, replayed sequence, expired) | a local server with `Range` support | #087 step 8a |

### 4.6 Schema and golden files

| Golden set | Location | Test |
|---|---|---|
| Schema migrations | `Tests/Fixtures/schemas/<file>/v<n>.json` → `v<n>.expected.json` | T0, every file and version ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §5, release rule R5) |
| Guest protocol frames | `Packages/GuestProtocol/testdata/frames/*.bin` | T0 in Swift and Kotlin ([guest-protocol.md](../02-design/guest-protocol.md) §15 #033) |
| Bootconfig vectors | `Images/tools/tests/fixtures/bootconfig/*.txt` → `*.bin` | T0 in Python and Swift; T2 in the Linux guest ([android-image.md](../02-design/android-image.md) §6.3) |
| Boot console captures | `Images/reference/<buildId>/` from #064 | T0 `BootPhaseDetector` ([runtime-daemon.md](../02-design/runtime-daemon.md) §3.3) |
| virtio-gpu byte vectors | from Linux driver traces, in GraphicsCore test resources | T0 ([graphics.md](../02-design/graphics.md) §12 #019) |
| EDIDs | golden EDIDs and committed `edid-decode` output, in GraphicsCore test resources | T0 |
| `kmscube` command stream | `Tests/Fixtures/graphics/` | T1 replay ([graphics.md](../02-design/graphics.md) §14) |
| CLI output | `CLI/apkrun/Tests/Golden/` | T0 human and JSON output per command ([cli.md](../02-design/cli.md) §6.3) |
| `aapt2` output | APKStoreCore test resources, per pinned `aapt2` version | T1 |
| Icon masters | WrapperCore test resources | T1 perceptual compare ([wrapper.md](../02-design/wrapper.md) §16) |
| Direct manifest schema | `docs/03-reference/schemas/direct-provider-manifest.schema.json` | T0 against the model's fixtures ([update-system.md](../02-design/update-system.md) §15 #050) |
| Compatibility database | `Tests/Compatibility/database/compatibility.json` against `compatibility.schema.json` | static check ([diagnostics.md](../02-design/diagnostics.md) §10) |
| Compile-fail sources | `Tests/Fixtures/compile-fail/` | T1 ([diagnostics.md](../02-design/diagnostics.md) §12) |

Golden files change only in a pull request that says why. A normal test run never rewrites a golden file.

### 4.7 Image fixtures

- Synthetic images for the Python and Swift pipeline tests, built with the vendored `mkbootimg` ([android-image.md](../02-design/android-image.md) §15).
- Sparse images with every chunk type, GPT images for round trips, and runtime image bundles in a directory and in an `.aar` for ImageCore install tests, including one with a bad signature and one with an extra file.
- Crafted archives for extraction rules: `..`, absolute paths, symlinks, hard links, devices, extra files ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §14).
- The test bundles of §3.5.

### 4.8 Other fixtures

- Linux test guest scripts and disks: `Tests/Fixtures/linux/` (§3.4).
- Fuzz corpora: `Tests/Fixtures/fuzz/<target>/` (§7.2).
- Fixture secrets: strings `APKRUN-FIXTURE-SECRET-<n>` ([diagnostics.md](../02-design/diagnostics.md) §12 T2-6).
- Compatibility app list: `Tests/Compatibility/apps.json` (fixtures, the 50-APK F-Droid corpus, hand-installed popular apps).
- Stored wrappers: one `HelloText.app` generated by each stable release, kept in the runner cache for the wrapper compatibility check (§7.6).

### 4.9 Fixture naming

Use these names consistently across the tasks and acceptance checks.

| Fixture | Canonical name | Use |
|---|---|---|
| HelloUpdate application | `HelloUpdate V1`, `HelloUpdate V2` | One fixture app with two versions |
| G8 wrapper | `HelloText.app` | The wrapper uses the HelloText fixture's Android label |
| G9 wrapper | `HelloUpdate.app` | The wrapper is unchanged while the fixture updates |

Two other names look like fixture or gate names and are not:

- Validation rules V0–V6 ([update-system.md](../02-design/update-system.md) §6) are always written "rule V<n>". "HelloUpdate V4" is the fixture.
- Gentle-update conditions are GU1–GU7 ([update-system.md](../02-design/update-system.md) §7.1). G1–G9 are always gates.

---

## 5. Gates

The gates and their pass conditions are listed in [roadmap.md](roadmap.md) §2. This section explains how each gate is checked.

| Gate | Task | Check | Fixtures and image | What the check asserts |
|---|---|---|---|---|
| G1 ARM64 Linux boots | #003 | `Tests/AcceptanceTests/G1LinuxBoot` | Linux test guest | `APKRUN-TEST: boot ok` on `hvc0`; the state machine `stopped → starting → running → stopping → stopped`; a failed start ends in `failed` with a typed error; 10 boots in a row |
| G2 boot_completed | #014 | `G2AndroidBoot` | stock image | `sys.boot_completed=1`; the `BOOT_COMPLETED` marker; 10 minutes with no `system_server` restart, watchdog, or HAL crash loop; 5 cold boots in a row; the reference diff has no unexplained difference ([android-image.md](../02-design/android-image.md) §8.4) |
| G3 SurfaceFlinger → virtio-gpu → Metal | #023 | `G3Graphics` | stock image, HelloGL | the display is in a macOS window; the GLES renderer string is VirGL; `hostReadbacks = 0` and `cpuPixelCopies = 0` over 60 s; ≥ 55 fps average; no tearing in the alternating-color test; 10 minutes without a renderer crash ([graphics.md](../02-design/graphics.md) §12 #023) |
| G4 Hello APK in a native window | #026 | `G4NativeWindow` | stock image, HelloText | a normal Mac window without emulator chrome; 100 of 100 clicks logged as `click <n>`; `Hello, APKRun 123!` arrives exactly; Esc goes back (`screen main`); the `adb shell` counter of `AdbClient` (#015) does not change during the input sequence, so input goes through the Guest Agent (FR-IN-06) |
| G5 Two APKs in two windows | #030 | `G5TwoWindows` | stock image, HelloText and HelloCompose ([display-and-windowing.md](../02-design/display-and-windowing.md) §12 #030) | two windows, each on its own Android display; input reaches only the focused window's app; closing one leaves the other running and interactive |
| G6 Warm under apkrund | #031, #032, #068 (staged, [roadmap.md](roadmap.md) §2) | `G6WarmRuntime` | stock image (custom image after #035), HelloText | the VM runs in apkrund started by launchd; quitting APKRun.app leaves HelloText interactive for 5 minutes; a warm launch shows no boot markers; after `kill -9`, launchd restarts apkrund within 15 s and the client reconnects |
| G7 v1 → v2 automatically | #040 | `G7GentleUpdate` | custom image, HelloUpdate V1 and V2, local provider | V2 is found and staged in the background; no install for 10 minutes while V1's window is open, nor while it runs with `keepRunning`; V2 is installed within 30 s after quit; the next launch shows V2 with `data HELLO`; the update history records each step |
| G8 APK wrapped as .app | #047 | `G8Wrapper` | custom image, HelloText | `HelloText.app` has bundle ID `io.apkrun.android.io.apkrun.fixture.hellotext`, `Signature=adhoc`, and passes `codesign --verify --strict`; opening it in Finder shows an interactive window; no Terminal and no other process starts; the Dock launch works for a cold and a warm runtime |
| G9 Wrapper unchanged during updates | #049 | `G9WrapperIntegrity` | custom image, HelloUpdate V1 and V2 | the SHA-256 of every file of `HelloUpdate.app` (`APKRunLauncher`, `Info.plist`, `wrapper.json`, `AppIcon.icns`, `_CodeSignature/`) and the cdhash in `Wrappers/registry.json` are unchanged after V2 is installed; the same wrapper runs V2 and V1's data is kept; no re-signing happened |

Rules:

- `scripts/run-gate.sh G<n>` runs the check on the reference Mac with a clean build from `main`. The T2 building blocks in `Tests/IntegrationTests/` must pass first.
- Evidence: the script report, the xcresult, the artifacts of §3.7, and a screen recording for G3–G9. They are attached to the gate issue and kept permanently.
- A gate check is never retried and never quarantined (§2.7).
- After a gate passes, its check runs nightly. From #035 on, the G2–G6 regressions run on the custom image. G2 also keeps running on the stock image while the stock image is used for development.
- A red gate regression opens an issue, blocks release candidates, and stops new tasks that depend on the gate ([roadmap.md](roadmap.md) §2).
- Checks that [runtime-daemon.md](../02-design/runtime-daemon.md) §14 adds to G6 (the warm-launch KPI, a real `pmset sleepnow`, onboarding on a fresh user account) become part of the nightly G6 run once #066, #069, and #070 are done. Until then they are on the v0.2 checklist (§8.3).

---

## 6. Test matrix by milestone and task

Each task's Tests section in its milestone file contains at least the cells below. "—" means that tier has no test for the task. The design document of each task has the full detail. The T3 column also names manual checks (§8).

### 6.1 M0 Repository and VM foundation

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #001 | one test target per module; `swift test` passes on a clean checkout (NFR-DEV-02) | `scripts/smoke-products.sh`: the products build, launch, and exit | — | — |
| #002 | validator rules, state machine edges, MAC and identifier persistence ([vm.md](../02-design/vm.md) §15) | — | covered by #003 | — |
| #003 | `VMController` edges with a fake driver | `InstanceLock` contention | LinuxGuest: boot and console marker | G1 check |
| #004 | `ConsoleLogWriter` rotation and fsync policy with an injected clock and file system | `ConsoleChannel` with real pipes; `ConsoleLogWriter` on disk | console marker; console port numbering; a forced VM stop mid-output keeps the log intact up to the last line (NFR-REL-05) | — |
| #005 | storage mapping (order, identifiers, flags) | the disk rules with real files and permissions | read-only and read-write disks with known content | — |
| #006 | — | — | DHCP lease, `generate_204` from a server on the host, disconnect callback logged | network check: public name resolution and `https://connectivitycheck.gstatic.com/generate_204` (nightly) |
| #007 | `connect` timeout and state checks with a fake driver | `VsockConnection` over a `socketpair` | vsock echo of 1 MiB, timeout, disconnect | — |
| #061 | `LogMessage` privacy rendering, error catalog checks, `ErrorPresenter`, health verdict table ([diagnostics.md](../02-design/diagnostics.md) §12 T1-1, T1-4, T1-5, T1-6); logging lint | compile-fail tests; `LogMirrorWriter`; `apkrun logs` with and without `log show` access | — | — |
| #062 | `check-module-deps.sh` rejects a fixture manifest with a forbidden edge | — | — | — |
| #063 | VirtioDeviceCore fakes: drain, completion, bounds, features | — | LinuxGuest `rng` | — |

### 6.2 M1 Android bring-up

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #008 | inventory classification of synthetic files | fetch tool against a local mock of the build API | — | nightly network check: the pinned build is still downloadable |
| #064 | `compare_boot.py` normalization and categories over fixture captures | — | — | reference diff in the G2 check |
| #009 | manifest schema and semantic checks (Python); manifest decoding over the shared fixtures (Swift) | — | — | — |
| #010 | kernel decompression and header checks; boot image extraction | — | — | — |
| #011 | sparse decoder, GPT writer and reader round trip, backup relocation | — | Linux guest sees three disks with the right names and sizes | — |
| #012 | bootconfig serialize, merge, and trailer vectors (Python and Swift); `VMDefinition` mapping | — | `/proc/bootconfig` equals the golden trailer; `boot_devices` discovered; stock kernel boots | — |
| #013 | — | — | stock image reaches init | — |
| #095 | — | — | 20 console ports; each `hvc` role behaves as planned | — |
| #014 | — | — | `sys.boot_completed=1`, stable for 10 minutes | G2 check |
| #015 | — | — | ADB commands over vsock; the host ADB forward listens on `127.0.0.1` only (NFR-SEC-06) | — |
| #016 | — | — | HelloText installs through RuntimeCore and the CLI | — |
| #017 | — | — | HelloText launches; `ACTIVITY_STARTED` recorded | v0.1 checklist: CLI launch |
| #065 | manifest decoding, `ImageVersion` ordering | pipeline twice with identical `SHA256SUMS`; ImageCore install from a directory, hole punching, signature and extra-file rejection, interrupted install cleanup | — | — |

### 6.3 M2 Graphics

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #018 | — (an analysis document, accepted by review) | — | — | — |
| #019 | `VirtioGPUProtocol` for every command with golden vectors; `ResourceTable`; display events; EDID | fuzz target (§7.2) | LinuxGuest `gpu`: probe, EDID, hotplug | — |
| #020 | — | GraphicsBridge create, destroy, capsets (Metal) | — | — |
| #021 | — | — | Android binds `virtio_gpu` | — |
| #022 | `ResourceTable` limits | `kmscube` replay → scanout resource hash within tolerance | LinuxGuest `virgl` (`kmscube` headless); VirGL SurfaceFlinger; `boot_completed` with `drmVirgl` and with `guestSwiftshader` | — |
| #023 | frame scheduler, `SurfacePool` state machine | — | HelloGL in a window, counters; `kmscube` in a window | G3 check; v0.1 checklist |

### 6.4 M3 Input and basic runtime

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #033 | golden frames (Swift and Kotlin), codec limits, handshake matrix, numbering rule | — | — | — |
| #072 | `GuestConnection` with the fake agent | Kotlin agent server against the scripted host; dispatcher and session binding | ADB-forward transport; development mode install, start, kill, restart, reinstall; `SystemServicesTest` with `am instrument`; reconnect after agent kill | — |
| #024 | `CoordinateMapper`, `EventTranslator`, `InputRouter` | injector `MotionEvent` construction | 100 of 100 HelloText clicks; HelloCompose drag and scroll; right-click opens the context menu | v0.1 checklist: scroll direction, context menu |
| #025 | `KeyCodeMap`, key mode, repeat | injector `KeyEvent` construction | `Hello, APKRun 123!` exact; Backspace, Enter, arrows; Esc goes back | v0.1 checklist: US and JIS layouts |
| #026 | — | `IOSurfaceLayerView` screenshot with a synthetic `FrameSource` | HelloText in a normal window, click and type | G4 check |
| #027 | `PackageID`, `VersionCode`, journal, recovery table (every kind × step) | `PackageStore` with a fake channel; crash injection; raw-ADB lint | stock image: install, split install, uninstall, reinstall, downgrade reinstall | — |
| #067 | `DisplayGeometryResolver`, mapper generation change, EDID size | — | resize and backing-scale change | v0.1 checklist: Retina sharpness |
| #028 | `DisplayPool` state machine and invariant property test | — | 50 acquire and release cycles without stale frames or duplicate display IDs | — |
| #029 | — | — | HelloText on a secondary display; HelloCompose, HelloGL, and HelloWebView results recorded | — |
| #030 | `InputRouter` ownership | — | two sessions; routing to the focused window | G5 check; v0.2 checklist |

### 6.5 M4 Daemon and guest protocol

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #031 | `RuntimeState` edges, `BootPhaseDetector` golden tests, exit rules | RuntimeHost startup order with fakes; instance lock between two processes | cold boot to `ready` with markers; stop paths; `kill -9` recovery within 15 s; boot-loop guard with bundle P | G6 check; v0.2 checklist: logout |
| #032 | CLI golden output and exit codes ([cli.md](../02-design/cli.md) §6.3) | XPC in-process: version mismatch, authorization per endpoint, 65th request rejected, cancel | `apkrun launch io.apkrun.fixture.hellotext` through XPC with `owner: apkrund`; another signing identity is rejected; a wrapper asking for another package gets `notAuthorized` | — |
| #066 | `ProvisioningState` | provisioning and `clonefile` on an APFS volume; XCUITest onboarding resume | setup on an empty data root; Reset Android reinstalls all packages | v1.0 checklist: fresh user account |
| #068 | buffer state machine, presentation algorithm | `IOSurfaceLayerView` with a scripted wrapper | HelloGL in a wrapper window 60 s: no tearing, `readyToDisplayed` p95 < 1 refresh + 4 ms, present < 2 ms p95, no readbacks | — |
| #034 | pipelining, timeouts, cancel, resync | Kotlin server over the vsock framing | vsock transport; reconnect with session continuity; the ADB shell counter does not change between `ready` and the first frame | — |
| #053 | `IntegrationPolicy` table, loop prevention | `ClipboardBridge` echo suppression | [desktop-integration.md](../02-design/desktop-integration.md) §4.5: `héllo 😀` both ways, setting off, 5-minute loop with HelloClipboard and HelloText | ⌘V p95 ≤ 150 ms for 64 KiB (§7.1); v0.2 checklist: TextEdit, R-21 |
| #069 | `IdleController` with a manual clock | — | suspended after 1 minute; resume p50 ≤ 500 ms over 20 runs; idle stop; `keepRunning`, `adb shell`, and installs prevent suspend; injected sleep and wake with time sync; Linux guest pause and resume | nightly `pmset sleepnow` with a scheduled wake; `idle-cpu` (§7.1); v1.0 checklist: lid close |
| #070 | `PerfRecordWriter` and `launchState` classification ([diagnostics.md](../02-design/diagnostics.md) §12 T1-9) | — | `CollectDiagnostics` returns `DUMPSYS_MEMINFO`, and an item the agent does not know is answered `unsupported` | all harness scenarios; two `warm-launch` runs agree within 10 %; segments add up within 5 ms |
| #071 | `TextInputModel`, editor commands, secure input balance | IME command mapping with a fake `InputConnection` | にほんご → 日本語 in HelloText and HelloCompose; emoji; ⌘V; password field has secure input (`IsSecureEventInputEnabled()`) and a Roman source | v0.2 checklist: candidate window position |

### 6.6 M5 Custom Android image

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #035 | vsockd port table and connection limits (`cargo test`) | vsockd with `vsock_loopback` (`test-linux`) | persistent agent restart after `kill`; HelloProbe cannot reach the agent sockets or vsock; no agent denials in enforcing mode during the suite; `SystemServicesTest`; adbd on vsock 5555 only with developer mode | G2–G6 regressions move to the custom image |
| #036 | Store Agent argument rules | `Guest/APKRunStore` JVM tests: every store operation against a scripted host | install without ADB; update; hash and signer mismatch; uninstall; metadata | — |

### 6.7 M6 Update system

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #073 | container fixtures, split selection, apksig vectors, intrinsic checks I1–I12 | `aapt2` golden outputs; fuzz targets for the container reader and the signing block parser | — | 50-APK F-Droid corpus nightly; `inspect` < 1 s per 50 MiB APK (§7.1) |
| #037 | — | coordinator end to end with fakes | local provider V1 → V2 with data kept, on the stock and the custom image | — |
| #038 | relation classification | crash injection at every `update` host step | V2 through `installStaged`; V2-other-signer refused by the host, and by Android when installed directly through `AdbClient`; kill during `CommitInstall` for both outcomes | — |
| #039 | authority mapping | Manual authority stops provider checks (counting fake provider) | `updateOwner == io.apkrun.store`; OtherInstaller gets `STATUS_PENDING_USER_ACTION`; `external` clears the owner | — |
| #040 | — | gentle-update conditions GU1–GU7 and races ([update-system.md](../02-design/update-system.md) §7.2) | the #040 acceptance; `CheckInstallConstraints` false with a visible task, true after | G7 check; v0.3 checklist |
| #041 | validation rules V0–V6 with the fixtures of §4.3, including rotation, the corrupted APK, and provider hash and metadata mismatches | — | — | — |
| #042 | split selection | — | HelloSplit from `.apks` installs and launches; native library loads; the Japanese string shows with the guest locale set to `ja-JP` | — (macOS in Japanese is C05-9, with #085) |
| #043 | — | health checker levels and timeouts | HelloUpdate V3-broken rolled back to V2 on both image kinds; V3 in `skippedVersions`; a file written by V2 is kept; HelloUpdate V4 installs; `RollbackPackage` without a rollback → `NOT_AVAILABLE`; the data-loss fallback | v0.3 checklist: rollback texts |
| #050 | Direct manifest schema cases | `DirectProvider` against `update-server.py` on `127.0.0.1`: `304`, redirects, the body cap, `429`, the cursor; a wrong `sha256` → `update.hashMismatch` after one retry | V1 → V2 through `update-server.py`; a versionCode mismatch is refused (rule V5); a wrong `sha256` is refused while downloading (`update.hashMismatch`, [update-system.md](../02-design/update-system.md) §5) | — |
| #074 | — | scheduler with a fake clock: intervals, jitter, backoff, exclusions, replacement | a 30 s slow provider does not delay `FIRST_FRAME`; apkrund with nothing due exits after the grace period | `update-check-launch` (NFR-PERF-07) |

### 6.8 M7 Mac app wrappers

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #044 | `wrapper.json` and `bootstrap.json` encoding; compatibility matrix | approval service with a fake UI client | screens R, S, V, L, D; a modified copy and a re-signed binary are refused (NFR-SEC-07) | v0.4 checklist: screens |
| #045 | `BundleIDMapper` (1,000 random IDs), file name sanitizing with OddName-style labels | generation determinism, conflicts, `pending` recovery at each step; registry | — | — |
| #046 | — | two generations give byte-identical trees | opens from Finder (`NSWorkspace.open`); `mdls` content type; `Signature=adhoc` | — |
| #047 | — | — | `NSWorkspace.open` plus an XCUITest click; Dock launch cold and warm | G8 check |
| #055 | icon rules | icon master golden images for HelloText and IconLegacy | icon rendering through the Store Agent | v0.4 checklist: no gray plate |
| #056 | — | — | `plutil -lint`; `mdfind` finds both locations within 60 s; App Translocation with a quarantined copy | v0.4 checklist: Keep in Dock, logout and login, Spotlight, Apps view (OQ-22) |
| #048 | — | the source is deleted after `beginImport` | the APK is deleted and the wrapper still launches; `grep` finds no APK name in the bundle | — |
| #049 | — | — | the #049 acceptance as a building block | G9 check |
| #075 | `wrap` golden output | — | `apkrun wrap --output` and `--install` | — |
| #076 | — | `refreshing` recovery; `WrapperValidator` states | keep-data uninstall and reinstall restores data; full uninstall removes `Packages/<id>/` and trashes the wrapper | v0.4 checklist: Dock pin after refresh (R-20) |
| #077 | status priority, URL routing | — | home rows for HelloText, HelloGL, and the unmanaged HelloCompose; a trashed wrapper shows "Mac app not found" within 60 s | — |
| #078 | relation handling | XCUITest add flow per relation | `HelloText.apk` drop → install and Create Mac app; `.xapk` and `.apks` split sets; refusals for downgrade (HelloUpdate V1 over V2) and other signer (V2-other-signer); OddName's name | — |
| #079 | settings patches per control | — | one test per settings section with HelloText | — |
| #089 | unknown `formatVersion` rejected | approval for a portable wrapper | first run in the second user account | — |

### 6.9 M8 Real update sources

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #051 | `entry.jar` verification (valid, tampered, wrong fingerprint, unsigned); version selection | — | CI-built test repository: HelloUpdate V1 → V2; a tampered `entry.jar` is refused | nightly: a known package is found in the main repository; v0.5 checklist: signer-mismatch text |
| #052 | asset choice and cursors from recorded responses | the REST mock: listing, rate limits, token | the mock: misleading tag `v0.1`, decision by versionCode, `ambiguousAsset` | nightly: the real `apkrun-fixtures/helloupdate-releases` |

### 6.10 M9 macOS integration

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #054 | notification filters and mapping, identifier stability | Kotlin notification filter | [desktop-integration.md](../02-design/desktop-integration.md) §5.5 with HelloNotification; banner latency p50 ≤ 1 s (wrapper running) | v0.5 checklist: permission prompt, R-19 |
| #080 | — | — | image and HTML clipboard ([desktop-integration.md](../02-design/desktop-integration.md) §4.5) | v0.5 checklist: paste into Mac apps |
| #081 | URL validation and rate limits | — | [desktop-integration.md](../02-design/desktop-integration.md) §7.3 with HelloLinks | — |
| #082 | `SharedFolderService` path resolution | `MacFilesProvider` access checks | [desktop-integration.md](../02-design/desktop-integration.md) §6.5 with HelloFiles and HelloFilesPeer; malicious-agent fuzzing of host operations | read ≥ 200 MB/s (§7.1); v0.5 checklist: R-22, Save to Mac |
| #085 | locale tag and time zone mapping | — | language, region, time zone, and 24-hour changes reach Android within 2 s; HelloText shows the new format; after 2 minutes of sleep the guest clock is within 2 s | v0.5 checklist C05-9: HelloSplit's Japanese string with macOS in Japanese |
| #086 | menu bar model | — | menu bar counts match the sessions | — |

### 6.11 M10 Runtime maintenance

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #057 | `components.json`, appcast parsing, marker rules, schema migration goldens | `MaintenanceService`; `BundleWatcher` | Maintenance: N → N+1 (9000 → 9001) and variants (a)–(d) ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §14) | release smoke matrix; v0.5 checklist: Sparkle UI and screen U |
| #058 | archive extraction rules with crafted archives, version ordering, compatibility table | `ImageUpdateCoordinator` with fakes; ImageCore install from an `.aar` signed with the test image key | migration A → B with the counter kept; B → B′ restores B ([android-image.md](../02-design/android-image.md) §12.4); a session during a migration | image release candidate matrix (§9.3) |
| #087 | feed validation, candidate selection C1–C7 with the rollout bucket, the feed checks of the archive install | downloader with `Range`; local feed (step 8a) | feed-driven update on a lab Mac (step 8b) | v0.5 checklist: Android system update UI |

### 6.12 M11 Diagnostics

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #059 | health verdict table of #061 against the full check registry ([diagnostics.md](../02-design/diagnostics.md) §12 T1-6); `DoctorFormatter` and CLI goldens | host-only doctor with apkrund unregistered | verdicts `stopped`, `bootFailure` (bundle F), `graphicsFailure`, `agentUnavailable`, `healthy`; `--fix` | quick doctor ≤ 3 s on the reference Mac |
| #060 | `Redactor`, logcat filter (T1-7, T1-8) | host-only bundle | bundles while healthy, after a boot failure, with the Guest Agent unavailable (`APKRUN_RUNTIME_FAULT=rejectAgent:guest`), and without apkrund; the secret test with bundle S; `OperationID` in the CLI, apkrund, and Store Agent logs | bundle ≤ 100 MiB and ≤ 60 s; v0.5 checklist: Troubleshooting pane and Report a Problem |

### 6.13 M12 v1.0 release

| Task | T0 | T1 | T2 | T3 and manual |
|---|---|---|---|---|
| #083 | — | — | HelloAudio opens an output stream through `virtio_snd` | loopback capture where the lab Mac has a virtual audio device; v1.0 checklist: tone heard |
| #084 | — | — | 5 s recording with the microphone on; other packages record silence | virtual audio device; v1.0 checklist: TCC prompt timing (OQ-29) |
| #088 | — | — | App Translocation (with #056) | nightly notarization; v1.0 checklist: download with Safari on a clean account, `spctl --assess` |
| #090 | `CompatibilityDatabase` matching (T1-10); schema check | — | — | corpus nightly, full list before each release |
| #091 | limits of RiftVM (8192 px, 256 MiB, 256 contexts) in `ResourceTable` | all fuzz targets (§7.2) | malicious agent; XPC client validation | long fuzzing nightly; security review items closed |
| #092 | every human CLI message in Japanese; error catalog `en` and `ja` | — | accessibility audit; pseudo-language run | v1.0 checklist: VoiceOver, Japanese UI |
| #093 | license inventory of `ThirdParty/ThirdParty.lock.json` (every component has a license, no unresolved one) | — | — | v1.0 checklist: notices in the app and the image |
| #094 | — | — | — | release testing (§9) |

### 6.14 Post-v1

| Task | Rule |
|---|---|
| #096 Vulkan | The test plan is written when the track starts. The GLES suites and G3 keep passing unchanged. |
| #097 Google Play | The test plan is written when the track starts. The update ownership tests of #039 and G9 keep passing. |

---

## 7. Non-functional testing

### 7.1 Performance

The harness and its preconditions are in [../02-design/diagnostics.md](../02-design/diagnostics.md) §9. It runs nightly in the `perf` job, not in pull requests. The NFR numbers come from the reference Mac.

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
| ⌘V p95 ≤ 150 ms for 64 KiB | [desktop-integration.md](../02-design/desktop-integration.md) §4 | harness, nightly |
| file read through the provider ≥ 200 MB/s (provisional) | [desktop-integration.md](../02-design/desktop-integration.md) §6 | T2 #082, recorded nightly |
| notification banner p50 ≤ 1 s (wrapper running), ≤ 3 s (background start) | [desktop-integration.md](../02-design/desktop-integration.md) §5 | T2 #054 |
| `readyToDisplayed` p95 < 1 refresh + 4 ms; present < 2 ms p95 | [display-and-windowing.md](../02-design/display-and-windowing.md) §5.5 | T2 #068, nightly |
| `inspect` < 1 s per 50 MiB APK | package-store.md | reference Mac, nightly |
| quick doctor ≤ 3 s; bundle ≤ 100 MiB and ≤ 60 s | [diagnostics.md](../02-design/diagnostics.md) §7–§8 | reference Mac, nightly |
| apkrund restart ≤ 15 s after `kill -9` | [runtime-daemon.md](../02-design/runtime-daemon.md) §13 #031 | T2 |
| `VM_RESUMED → RUNTIME_READY` p50 ≤ 500 ms over 20 runs | [runtime-daemon.md](../02-design/runtime-daemon.md) §13 #069 | T2 |

Rules:

- A nightly run fails when an NFR target is missed, or when a p50 is more than 15 % worse than the baseline (10 % for `hellogl-fps`). The failure names the segment that grew most ([diagnostics.md](../02-design/diagnostics.md) §9.4).
- T2 tests with timing targets assert them only on the reference Mac. On other lab Macs they record the value and warn.
- From M4 on, each milestone review records the numbers and explains regressions ([roadmap.md](roadmap.md) §4).

### 7.2 Security and fuzzing

| Requirement | Tests |
|---|---|
| NFR-SEC-01 APK code is untrusted | HelloProbe SELinux test (#035); malicious-agent fuzzing (#082, #091); virtio-gpu fuzzing |
| NFR-SEC-02 no automatic exposure of the home folder, `~/.ssh`, `~/Library`, `~/Documents` | T0: `VMDefinition` has no directory-sharing device; `SharedFolderService` refuses paths outside a share; T2: without opt-in, HelloFiles' picker shows no Mac folder |
| NFR-SEC-03 integrations go through the policy and can be turned off | T0 `IntegrationPolicy` table; T2 each integration with its setting off ([desktop-integration.md](../02-design/desktop-integration.md) §4.5, §5.5, §6.5, §7.3) |
| NFR-SEC-04 no signature bypass | T0 validation rules; T2 other signer refused by the host, and by Android through `AdbClient`; no hook in any build disables a rule (§3.3) |
| NFR-SEC-05 no secrets in logs | logging lint and compile-fail tests; T0 `Redactor`; T2 secret test (below) |
| NFR-SEC-06 ADB only on host loopback | T2: the ADB forward listens on `127.0.0.1` only (`lsof -nP -iTCP -sTCP:LISTEN`); with developer mode off, nothing listens on vsock 5555 |
| NFR-SEC-07 XPC clients validated | T1 authorization per endpoint; T2 another signing identity refused, a wrapper for another package gets `notAuthorized`, a modified or re-signed wrapper is refused |

Secret test ([diagnostics.md](../02-design/diagnostics.md) §12 T2-6): fixture secrets `APKRUN-FIXTURE-SECRET-<n>` are planted in a provider token (test Keychain), a URL query, a `.private` log argument, the console (bundle S), app logcat (HelloClipboard), the clipboard and a notification, a shared-folder file name, a wrapper path, the Mac user name (the test account's name), and `persist.apkrun.test.secret`. The unzipped bundle is searched in raw, URL-encoded, base64, and UTF-16 forms, with and without `--include-logcat`. It must contain none of them.

Fuzz targets (#091):

| Target | Code | Source |
|---|---|---|
| virtio-gpu command decoder | GraphicsCore (`VirtioGPUProtocol`) | [graphics.md](../02-design/graphics.md) §14, [security-model.md](../01-architecture/security-model.md) §8 |
| resource table (resource IDs, backing, limits) | GraphicsCore (`ResourceTable`) | [graphics.md](../02-design/graphics.md) §5.4, §11 |
| virgl command stream, against the renderer in a separate test process | GraphicsBridge, virglrenderer | [graphics.md](../02-design/graphics.md) §11 |
| guest protocol frame decoder, Swift | GuestProtocol | [guest-protocol.md](../02-design/guest-protocol.md) §16 |
| guest protocol frame decoder, Kotlin | `Guest/protocol` | [guest-protocol.md](../02-design/guest-protocol.md) §16 |
| `InputBatch` decoder of the agent | `Guest/guestd` | [input.md](../02-design/input.md) §13 |
| injector batch validator, Kotlin | `Guest/guestd` | [guest-protocol.md](../02-design/guest-protocol.md) §16 |
| container reader (ZIP, `.apks`, `.xapk`, `.apkm`) | APKStoreCore (`ContainerReader`, ADR-0017) | [package-store.md](../02-design/package-store.md) §4.2 |
| APK Signing Block parser | APKStoreCore (`APKSignatureVerifier`) | [package-store.md](../02-design/package-store.md) §4.5 |
| aapt2 output parser, seeded with recorded outputs | APKStoreCore (`APKInspector`) | [package-store.md](../02-design/package-store.md) §14 |
| Direct manifest parser (1 MiB) | UpdateCore | [update-system.md](../02-design/update-system.md) §12, [direct-provider-manifest.md](../03-reference/direct-provider-manifest.md) |
| F-Droid `entry.jar` and index decoder (64 MiB) | UpdateCore (`FDroidIndexVerifier`, `FDroidIndexReader`) | [update-system.md](../02-design/update-system.md) §4.5, §12 |
| GitHub release decoder (4 MiB) | UpdateCore (`GitHubProvider`) | [update-system.md](../02-design/update-system.md) §12 |
| host operations from a malicious agent build | IntegrationCore, RuntimeCore (T2) | [desktop-integration.md](../02-design/desktop-integration.md) §15 |

- Engines: libFuzzer for Swift and C targets (with the swift.org toolchain that #091 pins) and Jazzer for Kotlin targets ([../05-development/build-system.md](../05-development/build-system.md) §15). GraphicsBridge T1 tests and all Swift and C fuzz targets also run with Address Sanitizer and Undefined Behavior Sanitizer.
- Runs: 60 s per target in the `fuzz-short` job (T1) of every pull request, 1 h per target in the nightly `fuzz-long` job (T3).
- A crash opens an issue and adds the reproducer to `Tests/Fixtures/fuzz/<target>/` as a permanent T1 regression input. A release needs no open fuzz crash ([roadmap.md](roadmap.md) §3.6).

### 7.3 Reliability

| Requirement | Tests |
|---|---|
| NFR-REL-01 recoverable after a crash during an update | T0 recovery table; T1 `APKRUN_STORE_FAULT` at every host step; T2 kill during `CommitInstall`; wrapper `pending` and `refreshing` recovery; maintenance variant (c) |
| NFR-REL-02 launchd restarts apkrund and clients reconnect | T2 `kill -9` recovery; G6 |
| NFR-REL-03 a dead agent is detected and reconnected | T2 agent kill with session continuity (#034, #072) |
| NFR-REL-04 no silent version mismatch | T0 handshake matrix; T1 XPC version mismatch; the release smoke matrix with the previous stable image |
| NFR-REL-05 serial logs survive a VM crash | T2 forced stop during output (#004) |

Soak run: nightly, 60 minutes on one lab Mac with the custom image. It cycles launches and closes of HelloText, HelloGL, and HelloCompose, with suspend and resume every 10 minutes. It passes with no crash of apkrund, the launcher, or an agent, and with apkrund RSS growth below 10 % after the first 10 minutes.

### 7.4 Compatibility

| Requirement | Tests |
|---|---|
| NFR-CMP-01 fixtures first | P5; every T2 suite uses the fixtures of §4 |
| NFR-CMP-02 old wrappers keep working | T0 compatibility matrix ([wrapper.md](../02-design/wrapper.md) §5.3) and unknown `formatVersion`; the release smoke matrix launches the stored wrapper of the oldest supported release (§4.8) |
| NFR-CMP-03 image updates keep userdata | T2 migration A → B (§3.5); the image release candidate matrix (§9.3) |

- **App compatibility** ([diagnostics.md](../02-design/diagnostics.md) §10): `Tests/Compatibility/apps.json`. The F-Droid corpus runs nightly, the full list before each release. Each app gets a non-blank first frame within 20 s, then a 60 s `monkey` run with a fixed seed, then the same in compatibility mode if needed. Results go to `Tests/Compatibility/database/compatibility.json`, which CI validates against the schema.
- **macOS builds** (R-16): §9.4.
- **Hardware:** the reference Mac (M1, 16 GB) is the floor. The optional information Mac (§3.1) runs the nightly T2 set for information. Performance is compared only between runs on the same model identifier.

### 7.5 Localization and accessibility

| Requirement | Tests |
|---|---|
| NFR-L10N-01 English and Japanese | T0: every error code and every human CLI message of the golden tests has `ja` text (#092, [diagnostics.md](../02-design/diagnostics.md) §12); T2: pseudo-language run of APKRun.app ([host-ui.md](../02-design/host-ui.md) §15); manual Japanese UI review (§8.7) |
| NFR-L10N-02 VoiceOver | T2 accessibility audit ([host-ui.md](../02-design/host-ui.md) §15); manual VoiceOver walkthrough (§8.7) |

Android-side language behavior is tested with the fixtures: HelloSplit's Japanese resource (#042), Japanese IME input (#071), and locale sync (#085).

### 7.6 Upgrades

| Path | Test |
|---|---|
| APKRun N → N+1 | T2 Maintenance suite: 9000 → 9001 and variants (a)–(d) ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §14) |
| current stable → release candidate | §9.1 step 4 |
| schema migrations | T0 goldens for every file and version shipped in a stable release in the last 24 months (release rule R5) |
| newer data read by an older build | T0: journal with a newer `v` is read-only; `dataCreatedByNewerVersion` writes nothing |
| image A → B, failure restore | T2 (§3.5); image release candidate matrix (§9.3) |
| old wrappers with a newer runtime | §7.4 NFR-CMP-02 |
| RuntimeAPI and guest protocol majors | T0 handshake matrix; release smoke with the previous stable image (release rule R4) |

---

## 8. Manual checklists by release

### 8.1 Rules

- Check IDs are `C<version>-<n>`, where `<version>` is the release without the dot (`C04-2` is check 2 of v0.4, `C10-1` check 1 of v1.0). They are not milestone numbers.
- Manual checks run on the reference Mac with the release candidate build and, from v0.3 on, the custom image.
- Each result (pass or fail, macOS build, APKRun build, image version, notes, screenshot where useful) is recorded in the release issue. For v0.1–v0.5 that is the milestone review issue, for v1.0 #094.
- A failed check blocks the release. The only exception is a non-security check with a filed follow-up issue that the release notes name. Security and privacy checks cannot be waived.
- Every later release repeats the checks of earlier releases whose feature still exists. v1.0 runs all of them.
- A check that becomes automatable moves to T2 or T3 and leaves the list.

### 8.2 v0.1

| ID | Check | Task |
|---|---|---|
| C01-1 | HelloText text is sharp on a Retina display, and on a non-Retina external display if one is available | #067 |
| C01-2 | Trackpad and wheel scrolling follow the macOS natural-scrolling setting | #024 |
| C01-3 | Right-click opens HelloText's context menu at the pointer | #024 |
| C01-4 | With the US and the JIS keyboard layouts, `Hello, APKRun 123!` arrives exactly | #025 |
| C01-5 | `apkrun dev launch` from a new Terminal window shows HelloText without emulator chrome | #017, #026 |
| C01-6 | The G3 screen recording shows no visible tearing or stutter in HelloGL | #023 |

### 8.3 v0.2

| ID | Check | Task |
|---|---|---|
| C02-1 | Clicking back and forth between the HelloText and HelloCompose windows moves keyboard focus correctly | #030 |
| C02-2 | The Japanese IME candidate window appears next to the Android cursor in both fixtures | #071 |
| C02-3 | Copy and paste between TextEdit and HelloClipboard work both ways; the pasteboard prompt behavior of R-21 is recorded | #053 |
| C02-4 | Real sleep (`pmset sleepnow`) with HelloText open, wake after 2 minutes: HelloText responds and the guest clock is right | #069 |
| C02-5 | Logout with a running session: the stop log says `graceful` | #031 |
| C02-6 | The G6 extras of [runtime-daemon.md](../02-design/runtime-daemon.md) §14 until they are automated (§5) | #031 |

### 8.4 v0.3

| ID | Check | Task |
|---|---|---|
| C03-1 | The rollback notification and UI say that app data is not rolled back | #043 |
| C03-2 | The update notifications (including the 7-day notification) read correctly | #040 |

### 8.5 v0.4 (first public demo)

| ID | Check | Task |
|---|---|---|
| C04-1 | HelloText and IconLegacy icons have no gray system plate in Finder, the Dock, Spotlight, and the Apps view | #055 |
| C04-2 | Keep `HelloText.app` in the Dock, log out and in, launch it from the Dock | #056 |
| C04-3 | Launch `HelloText.app` from Spotlight by its label | #056 |
| C04-4 | Whether the Apps view lists the Desktop copy is recorded (OQ-22) | #056 |
| C04-5 | The Dock pin survives a wrapper refresh (R-20) | #076 |
| C04-6 | Launcher screens R, S, V, L, D show the right text and layout | #044 |
| C04-7 | The approval prompt for a copied wrapper is clear, and Return does not allow | #044, #089 |
| C04-8 | The uninstall choices sheet matches [host-ui.md](../02-design/host-ui.md) §8 | #076 |
| C04-9 | The demo of [roadmap.md](roadmap.md) §3.4 runs on a clean Mac with the #035 image bundle picked in onboarding, and no Terminal | #049 |

### 8.6 v0.5

| ID | Check | Task |
|---|---|---|
| C05-1 | The notification permission prompt names the wrapper; notifications look right; R-19 behavior recorded | #054 |
| C05-2 | Sharing a folder inside `~/Documents`: the privacy prompt and its attribution are recorded (R-22) | #082 |
| C05-3 | Save to Mac: the Save panel flow works, and the file carries a quarantine attribute | #082 |
| C05-4 | Image and HTML copied in HelloClipboard paste correctly into Preview and TextEdit, and back | #080 |
| C05-5 | The Sparkle update UI and launcher screen U during a `ReleaseUpdateTest` update | #057 |
| C05-6 | The Android system update UI: ask-mode reminder, install, restart text | #087 |
| C05-7 | Troubleshooting pane and Report a Problem from a wrapper produce a bundle ([diagnostics.md](../02-design/diagnostics.md) §12 T3-2) | #059, #060 |
| C05-8 | The F-Droid signer-mismatch text in Settings is clear | #051 |
| C05-9 | With macOS set to Japanese, HelloSplit shows its Japanese string (needs the locale sync of #085) | #042, #085 |

### 8.7 v1.0

| ID | Check | Task |
|---|---|---|
| C10-1 | VoiceOver walkthrough of onboarding, home, add flow, per-app settings, Settings, and uninstall | #092 |
| C10-2 | Japanese UI: complete, no truncation; pseudo-language screenshots reviewed | #092 |
| C10-3 | Onboarding on a fresh macOS user account | #066 |
| C10-4 | Microphone permission prompt timing recorded (OQ-29) | #084 |
| C10-5 | HelloAudio's tone, sweep, and click track are heard on the Mac, in sync | #083 |
| C10-6 | A distribution wrapper downloaded with Safari on a clean account opens after Gatekeeper approval; `spctl --assess` accepts it | #088 |
| C10-7 | APKRun.app passes `spctl --assess --type execute` and `stapler validate` | #088, #094 |
| C10-8 | License notices are visible in APKRun.app and in the image | #093 |
| C10-9 | Lid-close sleep with a running app, then wake | #069 |
| C10-10 | The v0.4 demo, repeated on the v1.0 candidate, with the image installed from the stable feed during onboarding | #094 |

---

## 9. Release testing

### 9.1 APKRun release candidate

1. Build the candidate from a tagged commit on `main`: Release configuration, Developer ID signed, and, from #088 on, notarized and stapled. The build number is higher than every published one (release rule R1).
2. On the candidate commit: T0, T1, and the release checks of §3.3 pass.
3. On the reference Mac with the candidate: every T2 suite, every closed gate check, the performance scenarios (no NFR miss, or an ADR with the measured numbers, [roadmap.md](roadmap.md) §3.6), the full compatibility list, the network checks, and, from #088 on, nightly notarization pass. No fuzz crash is open.
4. Publish the candidate on the beta channel first. Before #088 nothing is published ([../05-development/workflow.md](../05-development/workflow.md) §9.7), and this step runs against the local test appcast of the `maintenance` job instead. On the reference Mac, an install of the current stable release, switched to beta (`maintenance.channel`), updates to the candidate through the real appcast. The data checks of the N → N+1 test ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §14) are repeated.
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
4. Migration from the current stable image and from the previous stable image to the candidate keeps userdata. HelloText's counter and HelloUpdate's data survive.
5. The candidate works with the current stable APKRun and with the oldest APKRun named in `minimumRuntimeVersion` (release rule R3).
6. The F-Droid corpus runs on the candidate. `boot-phases` and `cold-launch` are compared with the previous image.
7. A stable image ships at least once a quarter, plus extra releases for critical security fixes and urgent time zone changes (release rule R7).

### 9.4 New macOS builds

- The seed lab Mac installs every macOS 27.x beta and release. On each new build it runs the full T2 set and every closed gate check (R-16).
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
9. **Update the task's Tests section** in its milestone file, and the matrix of §6 if the task gets a new tier.
10. **Performance:** add a harness scenario and a baseline in a reviewed pull request (§3.8).
11. **Parsers of untrusted input:** add a fuzz target and a seed corpus (§7.2).
12. **Human judgment:** add a manual check to the version's list in §8 with an ID and the task.
13. **Gates:** a gate check changes only with a change to the gate's pass conditions in [roadmap.md](roadmap.md) §2.
