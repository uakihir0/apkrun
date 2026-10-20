# M4 Daemon and guest protocol

The runtime moves out of the CLI into apkrund, a per-user LaunchAgent that launchd starts on demand. apkrund alone owns the VM and the package state. APKRun.app, APKRunLauncher, and the CLI are XPC clients, so quitting APKRun.app leaves Android and running apps alive. Apps show in their own launcher windows, fed by IOSurfaces over XPC. The Guest Agent speaks the full guest protocol, and on the custom image it uses vsock instead of ADB. The stock image (`aosp_cf_arm64_only_phone-userdebug`, build 16373615) is the test image of this milestone. The milestone closes G6, staged over #031, #032, and #068 ([roadmap.md](../roadmap.md) §2).

---
## #031 Introduce apkrund

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #030 |
| Gate | G6 (headless form; passes in #068) |
| Design | [runtime-daemon.md](../../02-design/runtime-daemon.md) §2–§4, §10 |
| Code | `Daemon/apkrund/`; `scripts/build/write-launch-agent.sh`; `scripts/dev/install-dev-app.sh`; `Packages/RuntimeHost/`; `Packages/RuntimeCore/` |

**Goal.** apkrund runs as a per-user LaunchAgent that launchd starts on demand (only `onDemand` ships), and it alone owns the VM and package state, so quitting APKRun.app keeps running apps alive. This task builds G6's headless form (conditions 1, 2, and 4 of [roadmap.md](../roadmap.md) §2); G6 passes only in #068.

**Out of scope.** The XPC API beyond `runtime status|start|stop` (#032). Windows (#068). Idle and sleep (#069). Onboarding (#066).

**Steps.**
1. **Target and plist.** `Daemon/apkrund/main.swift` builds `RuntimeHost` and runs `RunLoop.main`. `write-launch-agent.sh` writes the Release and Debug plists (`io.apkrun.apkrund`, `io.apkrun.apkrund.dev`) with the keys of [runtime-daemon.md](../../02-design/runtime-daemon.md) §2.1. **Check:** a build test asserts those keys and the Mach service name.
2. **Startup, lock, exit.** `RuntimeHost.start()` runs the steps of [runtime-daemon.md](../../02-design/runtime-daemon.md) §2.2. The listener resumes by step 11 and logs `DAEMON_READY` within 300 ms. `flock` on `Runtime/instance.lock` makes a second apkrund exit 0 ([runtime-daemon.md](../../02-design/runtime-daemon.md) §2.3). `SIGTERM` runs `stop(.hostShutdown)` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §2.4). **Check:** T0 exit rules; T1 startup order and lock.
3. **VM and agents.** Move the VM lifecycle into `RuntimeSupervisor` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2–§3.6) and build agent supervision on #072's `GuestAgentSupervisor` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §4). Resume the broker `io.apkrun.apkrund.xpc` with `runtimeStatus`, `startRuntime`, and `stopRuntime`. `apkrun dev` exits 75 while apkrund holds the lock ([cli.md](../../02-design/cli.md) §5). **Check:** T2 `DaemonLifecycleTests`: cold boot to `ready` with the three markers, and each stop path.
4. **Registration.** Launch calls `SMAppService.agent(plistName:).register()` when the service is absent or the plist SHA-256 differs from `registeredAgentPlistSHA256`. A pending `.requiresApproval` stays. `install-dev-app.sh` registers `io.apkrun.apkrund.dev` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §2.6). **Check:** `launchctl print` shows the service; a second run does not re-register.
5. **Recovery and headless G6.** T2 `DaemonRecoveryTests`: `kill -9` while `ready` restarts within 15 s, with a cold boot. T2 `BootLoopGuardTests` (test bundle P): three kernel panics block a fourth automatic boot. Add `Tests/AcceptanceTests/G6WarmRuntime` and `scripts/run-gate.sh G6`: HelloText on display 0; "interactive" means an injected tap gets a `click <n>` line within 5 minutes. **Check:** the T2 tests pass, then `scripts/run-gate.sh G6` passes.

**Tests.**
- T0: `Packages/RuntimeHost/Tests/RuntimeHostTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`.
- T1: `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`.
- T2: `Tests/IntegrationTests/DaemonTests/` (AndroidStock suite).
- T3: headless G6; checklists C02-5 and C02-6 of [test-strategy.md](../test-strategy.md) §8.3.

**Done when.**
- Only `apkrun dev` with its own `APKRUN_HOME` starts a VM (FR-VM-09).
- launchd starts apkrund, and the listener resumes within 300 ms (FR-RT-03).
- Quitting APKRun.app leaves HelloText interactive for 5 minutes (FR-RT-03).
- After `kill -9`, apkrund restarts within 15 s, and HelloText returns by cold launch (NFR-REL-02).
- Three failed boots in 10 minutes block automatic boots until `startRuntime` or a reset.
- `scripts/run-gate.sh G6` passes in headless form.

**Pitfalls.**
- Quitting the GUI never stops the VM; only exit rules and `SIGTERM` do.
- Read `cleanExit` only under the lock; a reused PID proves nothing.

---
## #032 XPC runtime API

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #031 |
| Design | [runtime-daemon.md](../../02-design/runtime-daemon.md) §7, §8; [runtime-api.md](../../03-reference/runtime-api.md) |
| Code | `Packages/RuntimeAPI/`; `Packages/RuntimeHost/`; `Packages/RuntimeClient/`; `CLI/apkrun/` |

**Goal.** APKRun.app, APKRunLauncher, and the CLI use one versioned XPC API to reach apkrund, and the CLI owns no VM: `apkrun launch io.apkrun.fixture.hellotext` starts HelloText through XPC. This task adds G6 condition 3 (a warm launch writes no boot markers).

**Out of scope.** The launcher window (#068). `WrapperIdentity` (#044; use `WrapperAuthorizer` until then). `setup`, `runtime reset --erase` (#066). `inspect`, `adopt` (#073). `update` (#037). `doctor` (#059).

**Steps.**
1. **DTOs.** In `Packages/RuntimeAPI`, `Codable` and `NSSecureCoding`-safe DTOs and `@objc` protocols for `runtimeStatus`, `install`, `launch`, `terminate`, `uninstall`, `list`, `packageInfo`, `subscribe`, `unsubscribe`, `cancel`, `startRuntime`, `stopRuntime`, `restartRuntime`, `resetRuntime`, `runtimeInfo`, `listSessions`, `listOperations`, and the session channel. Add optional `WireError.listItems`. **Check:** T0 round trip per DTO; a removed field without a version bump fails.
2. **Broker and rules.** `XPCBrokerListener` (`io.apkrun.apkrund.xpc`), `ControlEndpoint` (one use, 5 s expiry), `WrapperEndpoint(bundleID)`, and `XPCRuntimeExporter`. Authorize by endpoint kind and apply the request rules of [runtime-daemon.md](../../02-design/runtime-daemon.md) §8.2. `ReplyGuard` replies once. `WrapperAuthorizer` is a Debug fixture: test bundle to one package. **Check:** T1 over `NSXPCListener.anonymous()`: version mismatch, authorization, and the 65th request rejected.
3. **Operations, events, sessions.** `OperationHandle`; a repeated start with the same ID and payload joins. An install or uninstall of a package with an open window fails with `store.packageInUse`. `EventHub` serves the topics of [runtime-daemon.md](../../02-design/runtime-daemon.md) §8.4. Implement `launch`, `terminate` (`StopApplication(FORCE_STOP)`), and `SessionRegistry` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §7). Until #068, `launch` runs without frames when `APKRUN_TEST_HEADLESS_LAUNCH=1` (Debug only). **Check:** T1 with a fake runtime: queued sessions, orphans, takeover, cancel.
4. **RuntimeClient.** `XPCRuntimeService` reconnects with backoff ([process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.5) and replays subscriptions. **Check:** T1: after the listener is invalidated, the client reconnects and replays.
5. **CLI switch.** Every non-`dev` command uses `XPCRuntimeService`. Add `status`, `runtime`, `launch`, `stop`, `config`, `operations`. `runtime status --json` reports `owner` (`apkrund` or `apkrun-dev`). `stop` sends `FORCE_STOP`; closing a window sends `FINISH_TASKS`. **Check:** T0 golden output and exit codes.

**Tests.**
- T0: `Packages/RuntimeAPI/Tests/RuntimeAPITests/`, the `CLI/apkrun` test target.
- T1: `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`, `Packages/RuntimeClient/Tests/RuntimeClientSystemTests/`.
- T2 (AndroidStock): `Tests/IntegrationTests/CLITests/XPCLaunchTests`, `Tests/IntegrationTests/SecurityTests/XPCAuthorizationTests`.
- T3: the G6 warm-launch condition.

**Done when.**
- `apkrun launch io.apkrun.fixture.hellotext` returns at `running`; the CLI exits; HelloText keeps running; `runtime status --json` reports `owner: apkrund` (FR-RT-02, FR-CLI-01).
- `runtimeStatus`, `install`, `launch`, `terminate`, `uninstall`, `list`, and `packageInfo` work from all three clients, and are in [runtime-api.md](../../03-reference/runtime-api.md) (FR-RT-02).
- A binary signed with another identity is rejected; a wrapper for another package gets `notAuthorized` (NFR-SEC-07, ADR-0007).
- A warm launch after `ready` writes no boot markers.
- Unregistered, every non-`dev` command exits 69 (FR-CLI-01).

**Pitfalls.**
- Reply exactly once. A dropped reply becomes `RuntimeFailure.internal`.

---
## #068 Session client and IOSurface window over XPC

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #032 |
| Gate | G6 (full form; this task completes it) |
| Design | [display-and-windowing.md](../../02-design/display-and-windowing.md) §5; [graphics.md](../../02-design/graphics.md) §6.2, §6.3 |
| Code | `Packages/RuntimeAPI/`; `Packages/RuntimeClient/`; `Packages/GraphicsCore/` (`SurfacePool`); `Packages/WindowingCore/` (`IOSurfaceLayerView`); `Apps/APKRunLauncher/` (`XPCFrameSource`); `scripts/check-launcher.sh`; `Tests/IntegrationTests/WindowingTests/` |

**Goal.** apkrund renders and APKRunLauncher owns the window, showing the session's IOSurfaces with no copy and no host readback; apkrund never creates windows. `apkrun launch` opens HelloText in its own launcher window, which completes G6.

**Out of scope.** Wrapper generation and the `.wrapper` endpoint (#044 to #049). Launch screens and the warm spare display (#070). Wide color and HDR (post-v1).

**Steps.**
1. **Messages.** Add `SessionDescriptor` with `SurfaceSet{generation, 3 × IOSurface, pixelSize, densityDpi}`, `frameReady`, `surfacesReplaced`, and the wrapper messages `frameDisplayed` and `visibilityChanged` ([display-and-windowing.md](../../02-design/display-and-windowing.md) §5.1). `XPCFrameSource` delivers `frameReady` on the main queue and coalesces while busy. **Check:** T0 round trips; T1 coalescing.
2. **Buffer states.** `SurfacePool` implements `free`, `rendering`, `offered(seq)`, and `displayed(seq)` with rules 1 to 6 ([display-and-windowing.md](../../02-design/display-and-windowing.md) §5.2). After 1 s without `frameDisplayed`, the session counts as hidden. `ScanoutController.requestPresent` runs on `visibilityChanged(true)`. **Check:** T0 `BufferStateMachineTests` with a scripted wrapper: no offered buffer is rendered into.
3. **Window and launcher.** `IOSurfaceLayerView` sets `CALayer.contents` to the IOSurface with actions disabled, and sends `frameDisplayed` from the transaction completion block ([display-and-windowing.md](../../02-design/display-and-windowing.md) §5.3, §5.4). `Apps/APKRunLauncher` (`io.apkrun.APKRunLauncher`) takes `--package <id>`; `launch` opens it for packages without a Mac app. **Check:** T0 `PresentationAlgorithmTests`; T1 `IOSurfaceLayerViewSystemTests`; `scripts/check-launcher.sh` passes in CI.
4. **Remove the hook and accept.** Delete `APKRUN_TEST_HEADLESS_LAUNCH` and its entries in [configuration.md](../../03-reference/configuration.md) §5.1 and [test-strategy.md](../test-strategy.md) §3.3. Run `WrapperPresentationTests` with HelloGL, then the full G6 check. **Check:** the #032 acceptance check passes with the window, and the Done-when items hold.

**Tests.**
- T0: `Packages/GraphicsCore/Tests/`, `Packages/WindowingCore/Tests/`; T1: `Packages/WindowingCore/Tests/WindowingCoreSystemTests/`.
- T2 (`Tests/IntegrationTests/WindowingTests/`, AndroidStock): `WrapperPresentationTests` (HelloGL, [test-strategy.md](../test-strategy.md) §4.2): 60 s with no tearing, `readyToDisplayed` p95 below one refresh interval plus 4 ms, present cost below 2 ms p95, and `hostReadbacks = 0`.
- T3: the full G6 check (`Tests/AcceptanceTests/G6WarmRuntime`).

**Done when.**
- HelloText opened by `apkrun launch` shows in a launcher window fed by IOSurfaces (FR-DSP-07, ADR-0006).
- HelloGL holds 60 fps for 60 s, within the T2 limits (FR-DSP-07).
- No offered buffer is rendered into, and a hidden window shows the current frame when it becomes visible again.
- The full G6 check passes on the reference Mac: quitting APKRun.app leaves HelloText interactive for 5 minutes, a warm launch shows no boot markers, and `kill -9` recovers within 15 s with the window back.

**Pitfalls.**
- If `IOSurfaceIsInUse` does not reflect WindowServer's use of layer contents, rule 2(b) needs a replacement (fallback: R-03).
- Never read frames back to the CPU. `hostReadbacks` stays 0 ([graphics.md](../../02-design/graphics.md) §6).

---

## #034 Full Guest Agent protocol and vsock transport

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #033, #027 |
| Design | [guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §13.3; [guest-components.md](../../02-design/guest-components.md) §6, §10 |
| Code | `Packages/GuestProtocol/`; `Packages/RuntimeCore/` (`VsockGuestTransport`, `AndroidControlChannel`, `AdbClient`); `Guest/guestd/` (`HealthService`); `Guest/vsockd/`; `Tests/IntegrationTests/GuestAgentTests/` |

**Goal.** The Guest Agent implements every control operation the runtime needs. RuntimeCore uses GuestProtocol, not `adb shell`, on all production control paths. HelloText launches with no `adb shell` call, and ADB stays available for debugging.

**Out of scope.** `AuthorizeAdbKey` (72; #035, until then `UNSUPPORTED`). Operation 71 stays reserved. Image bridge and custom-image vsock (#035). Store operations (#036). Clipboard, `SyncTime`, `CollectDiagnostics`, M9 (#053, #069, #070).

**Steps.**
1. **Operations and events.** Implement 16 `MoveTaskToDisplay`, 17 `ListTasks`, 21 `GetHealth`, and 70 `Shutdown` (20 s) on the host and in `Guest/guestd/`, and the events up to number 22 ([guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §8.1). Each checks its capability. Operations 13, 15, 19, and 20 exist already. **Check:** T0 `GuestConnectionTests` with a fake agent (pipelining, out-of-order replies, timeouts, cancel, keepalive loss, resync); T1 Kotlin server tests.
2. **Health and reconnect.** `HealthService` reports `AppProcessEvent` and memory. The host pings every 5 s and treats three missed pings as dead, then reconnects and resyncs ([runtime-daemon.md](../../02-design/runtime-daemon.md) §4.2). **Check:** T2 `AgentReconnectTests`: after an agent kill, the open session continues.
3. **vsock transport.** `VsockGuestTransport` in RuntimeCore. Build `apkrun_vsockd` with `cargo ndk -t arm64-v8a build --release`, push it to `/data/local/tmp`, and run it as root. If the stock policy blocks vsock for `su`, record the denial and defer the validation to #035. `apkrun dev boot --guest-transport vsock|adb` selects the transport. **Check:** `VsockTransportTests` pass, or the denial and deferral are in the pull request.
4. **Control path switch.** Every production control path uses `AndroidControlChannel`. `AdbClient` keeps stock installs, debugging, and fallbacks, and counts `adb shell` calls. Remove control paths from the raw-ADB allowlist ([test-strategy.md](../test-strategy.md) §3.3). **Check:** the raw-ADB lint passes.
5. **Acceptance.** Run `GuestProtocolLaunchTests`: the `adb shell` counter does not change between `ready` and the first frame. **Check:** the Done-when items.

**Tests.**
- T0: `Packages/GuestProtocol/Tests/GuestProtocolTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`.
- T1: `Guest/guestd` JVM tests against a scripted host.
- T2 (`Tests/IntegrationTests/GuestAgentTests/`, AndroidStock): `GuestProtocolLaunchTests`, `AgentReconnectTests`, and `VsockTransportTests` if the stock image allows it.
- T3: none.

**Done when.**
- HelloText launches through GuestProtocol, and the `adb shell` counter is unchanged between `ready` and the first frame (FR-RT-04).
- `adb -s 127.0.0.1:6520 shell` works in developer mode (FR-RT-05).
- Operations 13, 15–17, 19–21, and 70 and the events up to number 22 work on stock, behind their capabilities (FR-RT-04).
- A killed Guest Agent is reconnected, and the open session continues (NFR-REL-03).
- A different major version fails with `incompatibleVersion`; the runtime never continues silently (NFR-REL-04).
- The vsock transport is validated on the stock image, or its deferral is recorded.

**Pitfalls.**
- Operation 71 is reserved. Developer mode is the boot parameter `androidboot.apkrun.devmode`, set by the host.
- Never resend a request after its connection dropped; the guest may have run it ([runtime-daemon.md](../../02-design/runtime-daemon.md) §4.3).

---
## #066 First-run provisioning

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #032, #065, #068 |
| Design | [runtime-daemon.md](../../02-design/runtime-daemon.md) §9; [host-ui.md](../../02-design/host-ui.md) §4; [package-store.md](../../02-design/package-store.md) §9 |
| Code | `Packages/RuntimeHost/` (`HostRequirementsCheck`, `setup`, `ProvisioningState`, Reset Android); `Packages/APKStoreCore/`; `Apps/APKRun/` (`RuntimeStatusModel`, `Features/Onboarding/`); `CLI/apkrun/Commands/Setup.swift`; `Tests/IntegrationTests/DaemonTests/` |

**Goal.** A new user approves the background service in APKRun.app and gets a `ready` runtime without a terminal; setup survives a quit in the middle. **Reset Android** gives a fresh Android with every managed app reinstalled.

**Out of scope.** Recovery-point listing and restore (#058; OQ-41, working default: not restorable in v1). The **Add App…** preview (#078). Image updates (#058, #087). Doctor (#059).

**Steps.**
1. **Host requirements.** `HostRequirementsCheck` returns every failed row of [runtime-daemon.md](../../02-design/runtime-daemon.md) §9.1 at once, each with its remediation. **Check:** T0 with a fake host, one case per row.
2. **`setup`.** Run `setup` as a long operation with `ProvisioningState` (`checkingHost`, `installingImage(fraction:)`, `creatingInstance`, `firstBoot(BootPhase, fraction:)`, `installingAgents`, `verifying`, `complete`, `failed(step:error:)`). Each step is idempotent and recorded in `state.json`; a restart resumes at the first incomplete step. `creatingInstance` uses 4 vCPUs and 4 GiB, capped at 50 % of memory (NFR-RES-01), with a sparse `userdata` (NFR-RES-02). Before `complete`, Android operations return `RuntimeFailure.notProvisioned`. **Check:** T0 transitions and resume points; T1 `ProvisioningSystemTests`: killed and resumed at each step.
3. **Onboarding and CLI.** The sheet of [host-ui.md](../../02-design/host-ui.md) §4 polls the approval every 2 s. Failures offer **Try Again** and **Report…**; after 2 failed first boots, **Start Over** (`setup` with `recreateInstance = true`). The drop zone and **Add App…** call `importPackage` and `installImported` (#027). Add `apkrun setup [--image <path>] [--yes]`. **Check:** T1 `OnboardingUITests` resumes at the right step after relaunch; T0 golden output.
4. **Reset Android.** `apkrun runtime reset --erase [--no-backup] [--yes]` requires typing `Reset`. It runs `stop(.reset, force: true)`, creates a recovery point (`InstanceStore.createRecoveryPoint`, kept 7 days), deletes `userdata.img`, provisions again, and writes a new `userdataGeneration`. After `ready`, managed packages are reinstalled from `current/` ([package-store.md](../../02-design/package-store.md) §9.2). **Check:** T2 `ResetAndroidTests`: HelloText and HelloUpdate V1 return with settings kept, and each shows its first frame.
5. **Acceptance.** Run the Done-when items on a fresh macOS account. **Check:** all pass.

**Tests.**
- T0: `Packages/RuntimeHost/Tests/RuntimeHostTests/`; the `CLI/apkrun` test target.
- T1: `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`; `Apps/APKRun` UI tests (`OnboardingUITests`).
- T2 (`Tests/IntegrationTests/DaemonTests/`, AndroidStock): `ProvisioningTests`, `ResetAndroidTests` (HelloUpdate V1 fixture: [test-strategy.md](../test-strategy.md) §4.2).
- T3: checklist C10-3 of [test-strategy.md](../test-strategy.md) §8.

**Done when.**
- On a fresh macOS account, onboarding completes without a terminal, and `ProvisioningState` is `complete`.
- `apkrun runtime status` reports `ready`; dropping HelloText on the drop zone shows its first frame.
- Quitting during `firstBoot` and reopening resumes setup at that step.
- `userdata` is a sparse file on APFS: its allocated size is far below its logical size (NFR-RES-02).
- With HelloText and HelloUpdate V1 installed, Reset Android reinstalls both with settings kept, and `apkrun launch` shows each first frame.

**Pitfalls.**
- Registration and Login Items approval are per macOS account. A fresh `APKRUN_HOME` is not a fresh account.

---
## #069 Idle policy and host sleep/wake

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #031 |
| Design | [runtime-daemon.md](../../02-design/runtime-daemon.md) §5, §6; [desktop-integration.md](../../02-design/desktop-integration.md) §9 |
| Code | `Packages/RuntimeCore/` (`IdleController`, `RuntimeActivityAssertion`); `Packages/RuntimeHost/` (`PowerObserver`, preboot, memory pressure); `Guest/guestd/` (`SyncTime`); `CLI/apkrun/Commands/Dev/Power.swift`; `Tests/IntegrationTests/DaemonTests/` |

**Goal.** After no app has been open for a while, the runtime suspends and then stops, and apkrund uses almost no CPU while suspended; the next launch resumes quickly. Host sleep and wake pause and resume the VM, and the guest clock is correct afterwards.

**Out of scope.** Locale, time zone, and clock format (#085). The timer settings UI (#079). A memory balloon before a pause (OQ-32; default: none in v1). VM save and restore (R-07, accepted).

**Steps.**
1. **IdleController.** `IdleController` (RuntimeCore actor) tracks the activity sources of [runtime-daemon.md](../../02-design/runtime-daemon.md) §5.1, each held through `RuntimeActivityAssertion`. `runtime.idleSuspendMinutes` (default 10) and `runtime.idleStopMinutes` (default 60) use `SuspendingClock`; `0` means never. **Check:** T0 `IdleControllerTests` with a manual clock: each source holds the runtime, both timers fire, and sleep is not counted.
2. **Suspend, resume, preboot.** Suspend pauses the agents, calls `VMController.pause()` (`VM_PAUSED`), and sets `suspended`. Resume calls `resume()` (`VM_RESUMED`), pings each required agent within 2 s, runs `SyncTime`, and sets `ready` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §5.3). A launch while suspended resumes first. `atLogin` preboot waits 60 s after login, and is skipped on battery below 30 % and while the boot-loop guard blocks boots. `.critical` memory pressure with no visible session suspends at once. **Check:** T2 `IdleSuspendTests` with `idleSuspendMinutes = 1` and `idleStopMinutes = 2`.
3. **Sleep and wake.** `PowerObserver` registers with `IORegisterForSystemPower` on a serial queue. On `kIOMessageSystemWillSleep`, pause within 5 s, then allow the sleep. On `kIOMessageSystemHasPoweredOn`, resume on every wake. `apkrun dev power sleep|wake` sends the same messages over `control.sock` to the running `apkrun dev boot`. **Check:** T2 `SleepWakeTests`: the VM pauses before the acknowledgment and resumes after wake.
4. **Time sync.** `SyncTime` (operation 48) applies host time when it differs by over 500 ms, corrected by half the `Ping` round trip. The shell-mode agent answers `UNSUPPORTED`. Only Debug builds on stock userdebug may fall back to `adb root` and `adb shell date -u @<seconds>`. **Check:** T2 `SleepWakeTests`: within 5 s of wake, the guest clock is within 2 s of the host.

**Tests.**
- T0: `Packages/RuntimeCore/Tests/RuntimeCoreTests/` (`IdleControllerTests`).
- T2 (`Tests/IntegrationTests/DaemonTests/`, AndroidStock): `IdleSuspendTests`, `SleepWakeTests`.
- T3: nightly `pmset sleepnow`; the `idle-cpu` scenario of #070; checklists C02-4 and C10-9 of [test-strategy.md](../test-strategy.md) §8.

**Done when.**
- With `idleSuspendMinutes = 1` and no sessions, the runtime is `suspended` after 1 minute, with apkrund under 1 % CPU (FR-VM-10, NFR-PERF-06).
- Opening HelloText from `suspended` shows its first frame; `VM_RESUMED` to `RUNTIME_READY` is p50 of at most 500 ms over 20 runs (FR-VM-10).
- With `idleStopMinutes = 2`, the runtime stops gracefully when no client is connected (FR-VM-10).
- A `keepRunning` task, a connected `adb shell`, and a running install each prevent suspend.
- On host sleep the VM pauses within 5 s; within 5 s of wake the guest clock is within 2 s of the host (FR-VM-11).

**Pitfalls.**
- Use `SuspendingClock`. A closed lid must not count as idle time.
- While suspended, nothing polls ([runtime-daemon.md](../../02-design/runtime-daemon.md) §5.6).
- Never skip the time sync after a resume: Android's wall clock stops while paused.

---
## #070 Performance harness

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #031, #068 |
| Design | [diagnostics.md](../../02-design/diagnostics.md) §4.3, §9; [guest-protocol.md](../../02-design/guest-protocol.md) §7.1 (operation 73) |
| Code | `Packages/RuntimeHost/` (`PerfRecordWriter`, `perfStatistics`, `MetricsSampler`); `Packages/RuntimeAPI/`; `Apps/APKRunLauncher/`; `Packages/GuestProtocol/`; `Packages/RuntimeCore/`; `Guest/guestd/` (`DiagnosticsService`); `Tests/PerformanceTests/`; `Tests/IntegrationTests/DiagnosticsTests/` |

**Goal.** `swift run apkrun-perf <scenario>` measures every NFR-PERF target repeatably on the reference Mac (M1, 16 GB, by default; OQ-02). It splits each launch and boot into marker segments, and the nightly job fails on regressions.

**Out of scope.** Other `CollectDiagnostics` items, doctor, and the bundle (#059, #060). Fixes for a missed target.

**Steps.**
1. **Records.** `PerfRecordWriter` in apkrund writes `perf/launches.jsonl` and `perf/boots.jsonl`, keeping the newest 2,000 and 200 records ([diagnostics.md](../../02-design/diagnostics.md) §4.3). Add `OpenSessionRequest.launchTiming`; the launcher writes `FIRST_FRAME_DISPLAYED`. **Check:** T0 record format, `launchState`, and rotation.
2. **Statistics.** `perfStatistics(PerfStatisticsRequest{reset})` returns `WirePerfStatistics` and clears it on `reset: true`. The session request `frameStatistics` never starts Android. Both fail with `runtime.developerModeRequired` while `developer.enabled` is off. **Check:** T1 over an anonymous listener: `reset` clears; `frameStatistics` fails with developer mode off.
3. **MetricsSampler.** `MetricsSampler` in RuntimeHost reads the figures of [diagnostics.md](../../02-design/diagnostics.md) §5. Find the Virtualization.framework XPC service by name, user, and start time after `VM_START`, and verify it (OQ-06). `gpuUtilization` is best effort (OQ-07). **Check:** on a lab Mac, the sampler reports the VM process and apkrund RSS.
4. **CollectDiagnostics and apkrun-perf.** Operation 73 (capability `diagnostics.v1`) runs `dumpsys meminfo -c` for `DUMPSYS_MEMINFO`, sends the output on bulk port 6102, and truncates at `max_bytes`. Each item returns `OK`, `UNSUPPORTED`, `TOO_LARGE`, or `FAILED`, and never fails the request. Caps: 16 MiB per item, 60 s per call. Add `apkrun-perf` with the scenarios of [diagnostics.md](../../02-design/diagnostics.md) §9.3. **Check:** T1 `DiagnosticsService` (known, unknown, truncated items); T2 `CollectDiagnosticsTests`.
5. **Results and regressions.** Commit one baseline per lab Mac under `Tests/PerformanceTests/baselines/` by reviewed pull request. The nightly job fails on a missed NFR target or a p50 more than 15 % worse than baseline (10 % for `hellogl-fps`), and names the segment that grew most. **Check:** a nightly run compares with the baseline.

**Tests.**
- T0: `Packages/RuntimeHost/Tests/RuntimeHostTests/`, `Packages/GuestProtocol/Tests/GuestProtocolTests/`.
- T1: `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`; `Guest/guestd` JVM tests.
- T2 (`Tests/IntegrationTests/DiagnosticsTests/`, AndroidStock): `CollectDiagnosticsTests`.
- T3 (`Tests/PerformanceTests/`, nightly): every scenario of [diagnostics.md](../../02-design/diagnostics.md) §9.3.

**Done when.**
- `apkrun-perf` runs every scenario and writes `results.json` and `summary.md` (FR-OPS-05). Two `warm-launch` runs agree within 10 % at p50, and segments add to the total within 5 ms.
- NFR-PERF-01 to NFR-PERF-06 are measured on the reference Mac, with warm launch p50 and p95 (NFR-PERF-01).
- `update-check-launch` is `skipped`, with its reason, until #037 and #074 exist (NFR-PERF-07).
- `memory` reports VM memory, `system_server`, SurfaceFlinger, zygote, each APK, host graphics, and apkrund RSS (NFR-RES-04).
- `DUMPSYS_MEMINFO` returns within the caps; an unknown item is `unsupported` without failing the request (FR-OPS-05).
- In developer mode, View → Show Frame Statistics shows fps, dropped frames, and readback counters, once per second; otherwise hidden.

---

## #053 Clipboard, plain text

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #034, #068 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §2, §4; [guest-protocol.md](../../02-design/guest-protocol.md) §8.4; [input.md](../../02-design/input.md) §6 |
| Code | `Packages/IntegrationCore/` (`IntegrationPolicy`, `IntegrationChannel`, `ClipboardCoordinator`); `Packages/RuntimeAPI/`; `Apps/APKRunLauncher/` (`PasteboardAdapter`); `Guest/guestd/` (`ClipboardBridge`); `CLI/apkrun/Commands/Integrations.swift`; `Tests/IntegrationTests/DesktopIntegrationTests/` |

**Goal.** Plain text copied on the Mac pastes into the focused Android app, and plain text copied in Android lands on the Mac pasteboard. There is no feedback loop, and each app has its own switch.

**Out of scope.** Images, files, and rich text (#080, #082). Notifications, URLs, and shared folders (#054, #081, #082). The per-app settings UI (#079).

**Steps.**
1. **IntegrationCore skeleton.** `IntegrationPolicy` evaluates the per-app `integrations.clipboard` switch and the global switch ([desktop-integration.md](../../02-design/desktop-integration.md) §2). Every integration passes guest agent, then policy, then host. **Check:** T0 `IntegrationPolicyTests` for both switches.
2. **Coordinator and adapter.** `ClipboardCoordinator` in apkrund handles `pushClipboard`, `clipboardFromGuest`, and `clipboardWritten`. `PasteboardAdapter` reads the Mac clipboard at ⌘V and when the window becomes key, but skips reads that would prompt. If a read prompts on macOS 27, push on paste only (R-21). Sensitive clips get `org.nspasteboard.ConcealedType`; `org.nspasteboard.TransientType` applies only to a paste. Android-to-Mac writes add `io.apkrun.clip-origin`. Text over 1 MiB is truncated at a character boundary, with the message "Only the first 1 MB was copied." **Check:** T0 `ClipboardLoopTests`: the three loop signals stop echoes both ways.
3. **Guest bridge.** `ClipboardBridge` in `Guest/guestd/` implements operation 40 `SetClipboard(ClipData)` (answers `ClipAck{seq}`) and sends `ClipboardChanged` for changes it did not make. Verify that the shell-mode agent can read and listen in the background on stock; if not, move the listener into the IME process (#071). **Check:** T1 `ClipboardBridgeTests`: echo suppression against a scripted host.
4. **⌘V with acknowledgment.** In editor mode, ⌘V pushes the Mac clipboard and waits for `ClipAck`, then pastes. After 500 ms without an ack, it commits plain text ([input.md](../../02-design/input.md) §6). **Check:** T2: ⌘V in HelloText pastes the Mac text.
5. **Acceptance.** Run `ClipboardTests` and checklist C02-3. **Check:** the Done-when items.

**Tests.**
- T0: `Packages/IntegrationCore/Tests/IntegrationCoreTests/`.
- T1: `Guest/guestd` JVM tests; `Packages/IntegrationCore/Tests/IntegrationCoreSystemTests/`.
- T2 (`Tests/IntegrationTests/DesktopIntegrationTests/`, AndroidStock; again in AndroidCustom after #035; fixture: [test-strategy.md](../test-strategy.md) §4.2): HelloClipboard both ways with "héllo 😀"; nothing crosses with the setting off; a 5-minute loop check; the 1 MiB limit.
- T3: ⌘V p95 at most 150 ms for 64 KiB (#070); checklist C02-3.

**Done when.**
- Text copied in TextEdit pastes into HelloClipboard, and the reverse, including "héllo 😀" (FR-INT-01).
- In a 5-minute check, `changeCount` changes only for user copies (FR-INT-01).
- With the integration off for an app, nothing crosses either way (NFR-SEC-03).
- Clips cross only while a window of the package is key, and only that window's package writes the Mac pasteboard.
- `apkrun integrations status <package>` shows the clipboard state (FR-CLI-01).

**Pitfalls.**
- Android has one clipboard for all apps, so an exchange is visible to every app afterwards.
- Never log or store clipboard contents (NFR-SEC-05).

---

## #071 APKRun IME

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #034, #068 |
| Design | [input.md](../../02-design/input.md) §5, §6; [guest-components.md](../../02-design/guest-components.md) §7 |
| Code | `Guest/guestd/` (`io.apkrun.guest/.ime.ApkRunInputMethodService`, `res/xml/method.xml`); `Packages/InputCore/` (`TextInputModel`, editor commands, secure-input counter); `Packages/WindowingCore/` (`NSTextInputClient`); `Packages/GuestProtocol/` (`ImeState`); `Tests/Fixtures/AndroidApps/` (HelloCompose); `Tests/IntegrationTests/InputTests/` |

**Goal.** Text committed by the macOS input method, including Japanese conversion, reaches the Android fields of the focused app window. The candidate window sits next to the Android cursor, the edit shortcuts work, and password fields turn on secure input.

**Out of scope.** An on-screen keyboard and IME languages inside Android. Game controllers and other input devices (post-v1).

**Steps.**
1. **Guest IME.** `ApkRunInputMethodService` uses `res/xml/method.xml` with one ASCII subtype and no locale, and an empty zero-height input view. It reports `ImeState{editor_focused}` on `onStartInput` and `onFinishInput`, and cursor rectangles as `cursor_rect_px` in display coordinates. The agent selects it as default IME, and the `LOCAL` policy applies on pool displays. The development channel `@apkrun-guest-ime` uses an ADB forward with a `SO_PEERCRED` check for the shell uid ([input.md](../../02-design/input.md) §5.6). **Check:** T1 JVM tests with a fake `InputConnection`: each command maps correctly, and `ImeState` follows focus.
2. **Host text input.** `NSTextInputClient` in `IOSurfaceLayerView` keeps a `TextInputModel` (marked text, selection, last cursor rect). Map AppKit calls as in [input.md](../../02-design/input.md) §5.3 and §5.4. Log `input.ime.unmappedCommand` for unmapped selectors. **Check:** T0 `TextInputModelTests` and `EditorCommandTests`.
3. **Paste and secure input.** ⌘V follows [input.md](../../02-design/input.md) §6. For password fields, call `EnableSecureEventInput()` with Roman input sources only. Balance each call with `DisableSecureEventInput()` through a counter. **Check:** T0: the counter balances after focus changes, window close, and session end.
4. **Acceptance.** Run `IMETests` and checklist C02-2. **Check:** the Done-when items.

**Tests.**
- T0: `Packages/InputCore/Tests/InputCoreTests/`, `Packages/WindowingCore/Tests/WindowingCoreTests/`.
- T1: `Guest/guestd` JVM tests.
- T2 (`Tests/IntegrationTests/InputTests/`, AndroidStock; HelloCompose fixture: [test-strategy.md](../test-strategy.md) §4.2): "にほんご" converts to "日本語" in HelloText and HelloCompose; emoji; ⌘V; secure input (`IsSecureEventInputEnabled()`); two apps on two displays.
- T3: checklist C02-2 of [test-strategy.md](../test-strategy.md) §8.3. Dictation is checked too; a failure becomes a follow-up and does not block.

**Done when.**
- "にほんご" converts to "日本語" in HelloText's field and in a HelloCompose `TextField` (FR-IN-07).
- The candidate window sits next to the Android cursor, and emoji from the character viewer are inserted (FR-IN-07).
- ⌘V pastes Mac text, and ⌘C, ⌘X, ⌘A, and ⌘Z do the Android equivalents (FR-IN-08).
- In a password field, secure input is on and the input source is Roman, and secure input is off after focus leaves (FR-IN-07).
- With two apps on two displays, typing and conversion go only to the key window's app (R-05).

**Pitfalls.**
- Backspace sends a `DEL` key event, never `deleteSurroundingText`. OTP boxes watch for `DEL`.
- On stock, the IME channel and the input stream are separate ADB forwards, so their order is not guaranteed. This is accepted for M4 ([input.md](../../02-design/input.md) §5.6).
- Every `EnableSecureEventInput()` needs its `DisableSecureEventInput()`, also when the window closes or the session ends.
