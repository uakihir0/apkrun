# M4 Daemon and guest protocol

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.2 |
| Related | [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../../AGENTS.md](../../../AGENTS.md) |

Each task below uses the entry format of [README.md](README.md) §2. Titles, dependencies, the milestone, and the gates follow the index in [README.md](README.md) §3.

## Milestone goal

The runtime moves out of the CLI into apkrund, a per-user LaunchAgent that launchd starts on demand. apkrund alone owns the VM, RuntimeCore, the DisplayPool, GraphicsCore, and the package state. APKRun.app, APKRunLauncher, and the CLI are clients of the XPC runtime API. Quitting APKRun.app does not stop Android or a running app, and a crashed apkrund is restarted by launchd. Apps show in their own launcher window through IOSurfaces sent over XPC. The Guest Agent speaks the full guest protocol, and on the custom image it can use vsock instead of ADB. Plain-text clipboard, the APKRun IME, the idle policy, and the performance harness complete v0.2 ([../roadmap.md](../roadmap.md) §3.2).

These design decisions hold for every task below:

- apkrund is the only process that owns a VM in a user installation ([../../01-architecture/decisions/0007-apkrund-launchagent-xpc.md](../../01-architecture/decisions/0007-apkrund-launchagent-xpc.md), [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §1). `apkrun dev …` keeps its own VM only with its own `APKRUN_HOME`, and refuses the user instance while apkrund holds the instance lock (exit 75, [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §10). The embedded mode (`APKRUN_EMBEDDED_RUNTIME`) stays for development only ([../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §1.2).
- The GUI and the launcher use RuntimeClient only ([modules.md](../../01-architecture/modules.md) §3). The launcher owns the app window ([ADR-0006](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)); apkrund never creates windows.
- The Guest Agent is the Kotlin agent bootstrapped by #072, with `apkrun_vsockd` on the custom image ([guest-components.md](../../02-design/guest-components.md) §10). Input goes through the agent. On the stock image the agents are reached through ADB forwards; the custom image gives them vsock ([guest-protocol.md](../../02-design/guest-protocol.md) §13). Host and guest identifiers use the `io.apkrun.*` namespace ([modules.md](../../01-architecture/modules.md) §5).
- The stock image (`aosp_cf_arm64_only_phone-userdebug`, build 16373615) is the test image of M4. Its T2 tests run in the `AndroidStock` suite ([../test-strategy.md](../test-strategy.md) §3.2). From #035 on, the custom image is the product image, and the M4 T2 tests that need privileged mode (time sync, `AuthorizeAdbKey`, vsock) run again in the `AndroidCustom` suite.
- Tests that go through apkrund use the Debug identities (`io.apkrun.apkrund.dev`, [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §2.6) installed by `scripts/dev/install-dev-app.sh`.

## Exit criteria

- [ ] All 9 tasks meet their acceptance criteria, or a task is moved to a later milestone with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4 item 1).
- [ ] **G6 passes** ([../roadmap.md](../roadmap.md) §2): the VM runs in apkrund, started by launchd. Quitting APKRun.app while HelloText's window is open stops neither the runtime nor the app, and HelloText stays interactive for 5 minutes. A warm launch shows no boot markers. After `kill -9` of apkrund, launchd restarts it within 15 s and the clients reconnect (NFR-REL-02). The check is `scripts/run-gate.sh G6` (`Tests/AcceptanceTests/G6WarmRuntime`) on the reference Mac with a clean build from `main` ([../test-strategy.md](../test-strategy.md) §5). #031 runs the headless form of the check and #032 adds the warm launch. G6 passes when the full check passes in #068 (see #031 Notes, [../roadmap.md](../roadmap.md) §2).
- [ ] The v0.2 Definition of Done holds ([../roadmap.md](../roadmap.md) §3.2): apkrund (#031), the XPC runtime API (#032), the full guest protocol (#034), app windows over XPC (#068), clipboard (#053), first-run provisioning (#066), the idle policy (#069), the performance harness (#070), and the APKRun IME (#071).
- [ ] Tests ([../roadmap.md](../roadmap.md) §4 item 3): T0 and T1 pass on `main`. T2 passes on the reference Mac in the `AndroidStock` suite (DaemonTests, CLITests, WindowingTests, GuestAgentTests, DesktopIntegrationTests, InputTests, DiagnosticsTests, HostUITests). The v0.2 manual checklist ([../test-strategy.md](../test-strategy.md) §8.3, C02-2 to C02-6) and the M4 items of the v1 checklist (C10-3, C10-9) are done and recorded.
- [ ] Performance ([../roadmap.md](../roadmap.md) §4 item 4): `apkrun-perf all` has run on the reference Mac, the first baseline is committed in `Tests/PerformanceTests/baselines/<model identifier>.json`, and the nightly job runs. The NFR-PERF-01 to NFR-PERF-07 numbers and NFR-RES-04 are recorded in [../traceability.md](../traceability.md) §2, with `update-check-launch` reported as skipped until #037 and #074.
- [ ] Risks ([../roadmap.md](../roadmap.md) §4 item 5, [../risks.md](../risks.md)):
  - R-03 has the #068 and #070 numbers (HelloGL fps, present time, host readbacks 0 through the XPC path).
  - R-05 has the #071 result: typing and IME conversion go to the focused secondary display.
  - R-07 stays accepted, with the cold-boot numbers of #070 recorded.
  - R-08 has the #070 memory numbers (`memory` scenario with `DUMPSYS_MEMINFO`).
  - R-18 has the #034 results for the hidden APIs the new operations use.
  - R-21 has the #053 result: which process reads the pasteboard, whether a read on focus prompts on macOS 27, and which API reports `changeCount`.
- [ ] Questions ([../roadmap.md](../roadmap.md) §4 item 6, [../open-questions.md](../open-questions.md)): OQ-02 (reference Mac) is answered before #070 starts. OQ-06 (VZ XPC process), OQ-07 (`gpuUtilization`), OQ-32 (balloon), and OQ-33 (resume on every wake) have their results recorded. OQ-34 (Store Agent memory) moves to M5, because the Store Agent exists only after #036.
- [ ] The verification log rows that name an M4 task are filled in: [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §16, [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §11, [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18, [../../02-design/guest-components.md](../../02-design/guest-components.md) §14, [../../02-design/input.md](../../02-design/input.md) §15, [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §17, and [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14.
- [ ] The design documents describe what was built, including [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) for every endpoint added in M4.
- [ ] When M0–M4 are complete, v0.2 is tagged.

## Task order

1. #031 Introduce apkrund (Gate G6).
2. #032 XPC runtime API (after #031).
3. #066 First-run provisioning (after #032, #065, and #068).
4. #068 Session client and IOSurface window over XPC (after #032).
5. #034 Full Guest Agent protocol and vsock transport (after #033 and #027).
6. #053 Clipboard, plain text (after #034 and #068).
7. #069 Idle policy and host sleep/wake (after #031).
8. #070 Performance harness (after #031 and #068).
9. #071 APKRun IME (after #034 and #068).

#031 and #034 have no dependency on each other and start in parallel when M3 is done. After #031: #032 and #069 in parallel. After #032: #068, then #066 (its acceptance check needs a window for the first frame). When #068 is done: #070. When #034 and #068 are done: #053 and #071 in parallel. #069 can run next to all of them. The Linux AOSP builder for #035 is set up during M3 and M4 ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §5), so M5 can start when #034 is done ([../roadmap.md](../roadmap.md) §1.4).

---

## #031 Introduce apkrund

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #030 |
| Gate | G6 (the full check completes with #032 and #068, see Notes) |
| Requirements | FR-VM-09, FR-RT-03, NFR-PERF-01, NFR-REL-02 |
| Design | [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §1–§4, §10, §12, §13 #031; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §1; [../../01-architecture/decisions/0007-apkrund-launchagent-xpc.md](../../01-architecture/decisions/0007-apkrund-launchagent-xpc.md); [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §2 |
| Modules / paths | `Daemon/apkrund/` (`main.swift`, `Info.plist`, `apkrund.entitlements`, `LaunchAgent.plist.in`); `scripts/build/write-launch-agent.sh`; RuntimeHost (`Packages/RuntimeHost/`: `RuntimeHost`, `RuntimeSupervisor`, the instance lock, `daemon.json`, the exit rules); RuntimeCore (`BootPhaseDetector`, `BootSignals.swift`, `BootProgressEstimator`, agent supervision); RuntimeAPI (the first control DTOs); `Apps/APKRun/` (`--register-runtime`); `scripts/dev/install-dev-app.sh`; `Tests/IntegrationTests/DaemonTests/`; `Tests/AcceptanceTests/G6WarmRuntime/`; `scripts/run-gate.sh` |
| Risks / questions | R-07 (accepted; the cold boot is measured by #070), R-24 (launchd registration across updates, settled by #057) |

### Goal

apkrund runs as a per-user LaunchAgent, started by launchd, and is the sole owner of the VM, RuntimeCore, the DisplayPool, GraphicsCore, and the package state. Closing APKRun.app does not stop the runtime while apps are active, and launchd restarts a crashed apkrund within 15 s.

### Scope

- The `Daemon/apkrund` target: a thin `main.swift` that builds `RuntimeHost` and runs the main run loop. It is embedded at `APKRun.app/Contents/Helpers/apkrund`, with the LaunchAgent plist at `Contents/Library/LaunchAgents/io.apkrun.apkrund.plist` written by `scripts/build/write-launch-agent.sh` from `LaunchAgent.plist.in` (§2.1, [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §1.1).
- The launchd keys of §2.1: `MachServices` (on demand), `RunAtLoad` (applies `startPolicy`), `StartInterval` 3600 for the update scheduler, `KeepAlive` with `SuccessfulExit = false`, `ExitTimeOut` 45, `ProcessType` Interactive, `AssociatedBundleIdentifiers`.
- `RuntimeHost.start` in the 12 steps of §2.2, with the fatal and degraded steps. The XPC listener is resumed within 300 ms of process start and logs `DAEMON_READY`. A failed degraded step sets `RuntimeFailure.hostStartupFailed(step:)`.
- The instance lock (§2.3), the exit rules and `SIGTERM` handling (§2.4), and `daemon.json` with unclean-exit handling and the crash-loop rule (§2.5).
- Moving VM ownership from the CLI to apkrund: `RuntimeSupervisor` with the boot sequence (§3.2), `BootPhaseDetector` (§3.3), readiness (§3.4), the stop sequence (§3.5), failure handling with one automatic restart and the boot-loop guard (§3.6).
- Agent supervision and reconciliation (§4) on top of #072's `GuestAgentSupervisor`, over the ADB-forward development transport.
- The XPC broker listener `io.apkrun.apkrund.xpc` with the version handshake and the first control operations `runtimeStatus`, `runtime start`, and `runtime stop` (see Notes). #032 adds everything else.
- Registration from APKRun.app: `APKRun.app --register-runtime` calls `SMAppService.agent(plistName:).register`, and re-registers only when the agent's status is not `.enabled`, or the SHA-256 of the embedded agent plist differs from the one registered last ([../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.7 step 2).
- The Debug identities and the development install (§2.6).
- `startPolicy = onDemand` only. The runtime boots on the first request, and apkrund exits after the grace period when nothing needs it.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - The full XPC runtime API, `EventHub`, and the CLI switch to RuntimeClient (#032).
  - Sessions and app windows over XPC (#068). The wrapper endpoint and `WrapperIdentity` (#044).
  - The idle timers, suspend and resume, `startPolicy = atLogin` preboot, memory pressure, and sleep and wake (#069).
  - The onboarding UI and the approval polling (#066).
  - Registration across self-updates (#057, R-24).
  - Health checks beyond the `apkrund.registration` check of #061 (#059).

### Deliverables

- `Daemon/apkrund/` (`main.swift`, `Info.plist`, `apkrund.entitlements`, `LaunchAgent.plist.in`) and `scripts/build/write-launch-agent.sh`, wired into the APKRun.app build so that `Contents/Helpers/apkrund` and the LaunchAgent plist are in the bundle.
- `RuntimeHost` with the startup sequence, the instance lock (`Runtime/instance.lock`), `daemon.json` (`schemaVersion`, `pid`, `startedAt`, `version`, `cleanExit`, `recentUncleanExits`, `bootHistory`), and the exit rules.
- `RuntimeSupervisor` (boot, readiness, stop, failure, boot-loop guard) in RuntimeHost, and `BootPhaseDetector`, `BootSignals.swift`, and `BootProgressEstimator` in RuntimeCore.
- The first control DTOs (`runtimeStatus`, `runtime start`, `runtime stop`) in RuntimeAPI, documented in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- `APKRun.app --register-runtime` and `scripts/dev/install-dev-app.sh` (installs `~/Applications/APKRun Dev.app` and registers `io.apkrun.apkrund.dev`).
- T2 tests in `Tests/IntegrationTests/DaemonTests/`: `DaemonLifecycleTests`, `DaemonRecoveryTests`, `BootLoopGuardTests`.
- The gate check `Tests/AcceptanceTests/G6WarmRuntime` and `scripts/run-gate.sh G6`.
- Test bundle P (`init=/apkrun-test-missing`) built from the stock image with `python3 -m apkrun_image bundle` and a lab key (`python3 -m apkrun_image keygen`).

### Implementation steps

1. **Daemon target and plist** (§2.1, §13 #031 step 1; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §1.1).
   - Add the `Daemon/apkrund` target. `main.swift` builds `RuntimeHost` and calls `RunLoop.main.run`. All logic lives in `Packages/RuntimeHost/`.
   - Add `LaunchAgent.plist.in` with the keys of §2.1 and `scripts/build/write-launch-agent.sh`, which writes the Release and Debug plists (`io.apkrun.apkrund`, `io.apkrun.apkrund.dev`).
   - Embed `apkrund` in `APKRun.app/Contents/Helpers/`.
   - Check: a build-time test reads the built plist and asserts every key of §2.1 and the Mach service name. `codesign --verify --strict` passes on the embedded helper.
2. **Startup, lock, state file, and exit** (§2.2–§2.5, §13 #031 step 2).
   - Implement `RuntimeHost.start` in the order of §2.2. Steps 1, 8, and 11 are fatal (exit 70). The others are degraded and record `hostStartupFailed(step:)`.
   - Implement the instance lock (`flock` on `Runtime/instance.lock`). A second apkrund for the same user exits 0. A lock held by a non-apkrund process makes apkrund serve the broker with `instanceLocked`.
   - Implement `daemon.json` and the unclean-exit path: log `host.previousExitUnclean`, record the crash report path, remove stale ADB forwards, and `adb disconnect`. Three unclean exits in 10 minutes set `apkrund.crashLoop` and block automatic boots.
   - Implement the exit rules: exit 0 after 2 minutes with the runtime stopped, no XPC connections, no activity assertions, and no work due. On `SIGTERM`: publish `hostShuttingDown`, `stop(.hostShutdown)` with a 40 s deadline, then write `cleanExit = true`.
   - Check: T0 tests for the exit-rule evaluation. T1 tests: the startup order with fake modules, including each degraded step, and lock contention between two processes.
3. **VM ownership in apkrund** (§3, §13 #031 step 3).
   - Move the VM lifecycle from the CLI's `EmbeddedRuntimeService` into `RuntimeSupervisor`. The boot sequence of §3.2 writes the markers `VM_START`, `AGENT_CONNECTED`, and `RUNTIME_READY`, with the boot timeout (180 s, 900 s on the first boot), the stall timeout (90 s, 600 s on the first boot), and the 30 s agent timeout. `kernelPanic`, `androidBootFailed`, VM, and graphics failures end the boot at once.
   - Add `BootPhaseDetector` with the pattern table in `BootSignals.swift` and `BootProgressEstimator` (§3.3). The golden tests use the #064 console captures.
   - Implement readiness (§3.4; the required agent on the stock image is the Guest Agent), the stop sequence (§3.5, logging `graceful`, `powerButton`, or `forced`), and failure handling (§3.6): a snapshot in `~/Library/Logs/APKRun/crash/`, one automatic restart, and the boot-loop guard (3 failed boots in 10 minutes).
   - Check: T0 tests for the `RuntimeState` edges of [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §2 and the `BootPhaseDetector` golden tests. T2 `DaemonLifecycleTests`: a cold boot to `ready` with the three markers, and the three stop paths.
4. **Agent supervision and the first control operations** (§4, §8.1, §13 #031 step 4).
   - Build agent supervision on #072's `GuestAgentSupervisor`: `AgentConnectionState`, the reconnect reconciliation table of §4.2, `cancelAll` on disconnect, and the disconnect rules (5 s wait, 30 s for a required agent, 60 s watchdog).
   - Resume the broker listener at step 11 with the version handshake and `runtimeStatus`, `runtime start`, and `runtime stop` on the control endpoint. Record them in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
   - Make `apkrun dev` refuse the user instance while apkrund holds the lock (exit 75, [../../02-design/cli.md](../../02-design/cli.md) §5).
   - Check: T2 `DaemonLifecycleTests`: after the agent process is killed, it reconnects and `runtimeStatus` reports it `connected` again. T1: a second process fails to take the lock.
5. **Registration** (§2.6, §13 #031 step 5; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §1.1).
   - `APKRun.app --register-runtime` registers the LaunchAgent with `SMAppService` and re-registers it only when the agent's status is not `.enabled`, or the SHA-256 of the embedded agent plist differs from the one registered last ([../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.7 step 2). It stores the hash in UserDefaults `registeredAgentPlistSHA256`. `.requiresApproval` opens the Login Items settings with `openSystemSettingsLoginItems`. The polling and the onboarding texts are #066.
   - `scripts/dev/install-dev-app.sh` installs `~/Applications/APKRun Dev.app` and runs `--register-runtime`. `launchctl kickstart -k gui/$(id -u)/io.apkrun.apkrund.dev` restarts the development daemon.
   - Check: on a lab Mac, `launchctl print gui/$(id -u)/io.apkrun.apkrund.dev` shows the service after the script, and a second run does not re-register.
6. **Recovery and the gate check** (§2.5, §3.6, §13 #031 step 6; [../roadmap.md](../roadmap.md) §2).
   - T2 `DaemonRecoveryTests`: `kill -9 $(pgrep apkrund)` while the runtime is `ready`. launchd restarts apkrund within 15 s, `daemon.json` records the unclean exit, and a client that reconnects gets a `ready` runtime through a cold boot.
   - T2 `BootLoopGuardTests` with bundle P: three kernel panics set the guard, and a fourth automatic boot is refused.
   - Add `Tests/AcceptanceTests/G6WarmRuntime` and `scripts/run-gate.sh G6` in the headless form of Notes.
   - Check: the T2 tests pass, then `scripts/run-gate.sh G6` passes in its headless form.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/RuntimeHost/Tests/RuntimeHostTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`): the `RuntimeState` edges, the `BootPhaseDetector` golden tests over the #064 captures, `BootProgressEstimator`, and the exit-rule evaluation.
- **T1** (`Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`): the startup order with fake modules, including degraded steps; the instance lock between two processes.
- **T2** (`Tests/IntegrationTests/DaemonTests/`, AndroidStock suite, stock image): a cold boot with markers; the stop paths (graceful, power button, forced); agent kill and reconnect; `kill -9` recovery within 15 s; the boot-loop guard with test bundle P.
- **T3**: the G6 check (`scripts/run-gate.sh G6`, staged, see Notes). Checklist C02-5 (logout with a running session gives `graceful`) and C02-6 (the G6 extras) of [../test-strategy.md](../test-strategy.md) §8.3.

### Acceptance criteria

- [ ] apkrund is the sole owner of the VM, RuntimeCore, the DisplayPool, GraphicsCore, and the package state. No CLI command outside `apkrun dev` with its own `APKRUN_HOME` starts a VM (#031, FR-VM-09).
- [ ] apkrund is started by launchd through its Mach service, and its XPC listener is resumed within 300 ms of process start (`DAEMON_READY`) (FR-RT-03).
- [ ] Closing APKRun.app does not destroy the runtime while an app remains active: with HelloText running, APKRun.app quits, and HelloText stays interactive for 5 minutes (#031, FR-RT-03). In #031 this is checked with HelloText on display 0 (see Notes); with the app window, #068 checks it again.
- [ ] After `kill -9` of apkrund, launchd restarts it within 15 s, `daemon.json` records the unclean exit, and a reconnecting client gets HelloText back through a cold launch (NFR-REL-02).
- [ ] Logging out with a running session shuts Android down gracefully (`graceful` in the stop log) (checklist C02-5).
- [ ] Three failed boots in 10 minutes block automatic boots until `runtime start` or `runtime reset` (boot-loop guard, §3.6).
- [ ] A cold boot reaches `ready` within the NFR-PERF-01 budget on the reference Mac, with `VM_START`, `AGENT_CONNECTED`, and `RUNTIME_READY` in the boot record (NFR-PERF-01).
- [ ] `scripts/run-gate.sh G6` passes in its headless form. G6 is recorded as passed when the full form passes in #068 (G6).

### Notes

- **Staged G6.** Two G6 conditions need later tasks: a warm launch needs `launch` (#032), and "while an app window is open" needs the launcher window (#068). #031 builds the gate check with three conditions: the VM runs in apkrund, quitting APKRun.app leaves the runtime and HelloText running, and `kill -9` recovery. HelloText is started on display 0 through the test observer's `AdbClient` (`am start`), and "interactive" means that an injected tap is answered by the `click <n>` logcat line during the 5 minutes after APKRun.app quits. #032 adds the warm-launch condition (no boot markers). #068 adds the window. The gate is recorded as passed when the full form passes.
- **First control operations.** Startup step 11 needs a listener, and the T2 tests need a way to start and stop the runtime. #031 therefore adds `runtimeStatus`, `runtime start`, and `runtime stop` to the control endpoint. #032 builds the rest of the API around them without changing their shape.
- **Test bundle P** works on the stock image, because it only changes the kernel command line. It is built from the stock image in M4 and rebuilt on the custom image in #035.
- Record the results in [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §16: the listener time (`DAEMON_READY`), G6 (headless form here, full form with #068), and the `kill -9` recovery time.
- The console strings of `BootPhaseDetector` come from #064. If a string changes, only `BootSignals.swift` and its golden tests change (§15).

---

## #032 XPC runtime API

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #031 |
| Requirements | FR-RT-02, FR-CLI-01, NFR-SEC-07 |
| Design | [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7, §8, §13 #032; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md); [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2; [../../01-architecture/decisions/0007-apkrund-launchagent-xpc.md](../../01-architecture/decisions/0007-apkrund-launchagent-xpc.md); [../../02-design/cli.md](../../02-design/cli.md) §3, §4.1, §4.2 |
| Modules / paths | RuntimeAPI (`Packages/RuntimeAPI/`: DTOs, `@objc` protocols); RuntimeHost (`XPCBrokerListener`, `ControlEndpoint`, `WrapperEndpoint`, `EventHub`, `XPCRuntimeExporter`, `ReplyGuard`, `SessionRegistry`); RuntimeClient (`Packages/RuntimeClient/`: `XPCRuntimeService`); `CLI/apkrun/`; `Tests/IntegrationTests/CLITests/`; `Tests/IntegrationTests/SecurityTests/` |
| Risks / questions | None |

### Goal

APKRun.app, APKRunLauncher, and the CLI reach apkrund through one versioned XPC API. `apkrun launch io.apkrun.fixture.hellotext` starts HelloText through XPC, and the CLI owns no VM.

### Scope

- The DTOs and `@objc` protocols in RuntimeAPI for `runtimeStatus`, `install`, `launch`, `terminate`, `list`, and `applicationInfo`, plus `subscribe`, `cancel`, `runtime start`, `runtime stop`, `runtime restart`, `runtime reset`, and the session channel (#032 step 1).
- The broker and the endpoints (§8.1): `XPCBrokerListener` (`io.apkrun.apkrund.xpc`), `ControlEndpoint`, `WrapperEndpoint(bundleID)`, `EventHub`, and `XPCRuntimeExporter`.
- The request rules (§8.2): `apiVersionMismatch`, `malformedRequest`, `notAuthorized`, `ReplyGuard`, at most 64 requests in flight per connection, at most 8 control connections. Code-signing requirements per endpoint kind (NFR-SEC-07, ADR-0007).
- Long-running operations with an `OperationHandle` (§8.3) and the event topics `runtime`, `sessions`, `packages`, `updates`, `operations`, `health`, and `maintenance` (§8.4).
- `launch`, `terminate`, and the session registry of §7 (queued sessions, orphaned sessions re-attached within 3 s).
- RuntimeClient `XPCRuntimeService` with the reconnect behavior of [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.5.
- The CLI switch (§8.5, [../../02-design/cli.md](../../02-design/cli.md) §7): every command outside `dev` uses `XPCRuntimeService`. New commands: `status`, `runtime status|start|stop|restart|reset`, `launch`, `stop`, `config …`, `operations …`. When apkrund is not registered, the CLI prints the registration message and exits 69.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - The launcher window and the frame messages of the session channel in APKRunLauncher (#068).
  - `WrapperIdentity` and the real wrapper authorization (#044). #032 uses the seam of Notes.
  - `setup` and `runtime reset --erase` (#066). `inspect`, `adopt` (#073). `update …` (#037). `doctor` (#059).

### Deliverables

- RuntimeAPI DTOs and protocols with round-trip tests, documented in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- RuntimeHost `XPCBrokerListener`, `ControlEndpoint`, `WrapperEndpoint`, `EventHub`, `XPCRuntimeExporter`, and `ReplyGuard`. RuntimeCore `SessionRegistry` with client connections, takeover, and orphaned sessions, on top of the M3 registry ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7).
- RuntimeClient `XPCRuntimeService`.
- The CLI commands of [../../02-design/cli.md](../../02-design/cli.md) §7 row #032 with golden files.
- T1 tests in `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/` over `NSXPCListener.anonymous`.
- T2 tests: `XPCLaunchTests` in `Tests/IntegrationTests/CLITests/`, and `XPCAuthorizationTests` in `Tests/IntegrationTests/SecurityTests/` with a test binary signed by another identity.
- The Debug-only test hook `APKRUN_TEST_HEADLESS_LAUNCH=1` (see Notes), as listed in [../../03-reference/configuration.md](../../03-reference/configuration.md) §5.1 and [../test-strategy.md](../test-strategy.md) §3.3.

### Implementation steps

1. **DTOs and protocols** (§13 #032 step 1; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md)).
   - Define the DTOs and `@objc` protocols in RuntimeAPI. Every DTO is `Codable` and `NSSecureCoding`-safe, with the API version in the handshake.
   - Keep the #031 operations unchanged.
   - Check: T0 round-trip tests for every DTO. A T0 test fails when a DTO field is removed without a version bump.
2. **Broker, endpoints, and request rules** (§8.1, §8.2).
   - Implement `XPCBrokerListener`, which checks the client's code signature and hands out a `ControlEndpoint` or a `WrapperEndpoint(bundleID)`.
   - Implement the rules of §8.2 and `ReplyGuard` (every reply is sent once, also on cancel and disconnect).
   - Check: T1 over `NSXPCListener.anonymous` in-process: a version mismatch gives `apiVersionMismatch`, authorization is checked per endpoint kind, the 65th in-flight request is rejected, and a malformed request gives `malformedRequest`.
3. **Long operations, events, and sessions** (§8.3, §8.4, §7).
   - Add `OperationHandle` with progress and `cancel`, and `EventHub` with the seven topics.
   - Implement `launch` (resolve the Mac app, or open the generic launcher, and return when the session is `running`), `terminate`, and `SessionRegistry` with orphaned sessions (§7).
   - Add the headless launch hook for Debug builds (see Notes).
   - Check: T1 with a fake runtime: queued sessions, orphan re-attach, takeover, the reconciliation table of §4.2, and a cancelled long operation.
4. **RuntimeClient** (§13 #032 step 3; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.5).
   - Implement `XPCRuntimeService` with reconnect, re-subscription, and the unavailable state.
   - Check: T1: the client reconnects after the in-process listener is invalidated and replays its subscriptions.
5. **CLI switch** (§8.5, §13 #032 step 4; [../../02-design/cli.md](../../02-design/cli.md) §3, §4.1, §4.2).
   - Switch every non-`dev` command to `XPCRuntimeService` and add the #032 commands.
   - `apkrun launch <package> [--json]` prints the first-frame time. `apkrun runtime status --json` reports `owner` (`apkrund` or `apkrun-dev`).
   - Check: T0 golden files for the human and JSON output and the exit codes, including exit 69 when apkrund is not registered.
6. **Acceptance** (§13 #032 step 6).
   - Run `XPCLaunchTests` and `XPCAuthorizationTests`, then the G6 check with the warm-launch condition.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/RuntimeAPI/Tests/RuntimeAPITests/`, `CLI/apkrun` test target): DTO round trips; CLI golden output and exit codes.
- **T1** (`Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`, `Packages/RuntimeClient/Tests/RuntimeClientSystemTests/`): anonymous XPC in-process: version mismatch, authorization per endpoint, 65th request rejected, cancel of a long operation; `SessionRegistry` with a fake runtime; client reconnect.
- **T2** (`Tests/IntegrationTests/CLITests/`, `Tests/IntegrationTests/SecurityTests/`, AndroidStock suite, stock image): `apkrun launch io.apkrun.fixture.hellotext` through XPC with `owner: apkrund`; a binary signed with another identity is rejected; a wrapper connection for another package gets `notAuthorized`.
- **T3**: the G6 check with the warm-launch condition (`scripts/run-gate.sh G6`).

### Acceptance criteria

- [ ] The CLI launches HelloText through XPC without owning a VM: `apkrun launch io.apkrun.fixture.hellotext` returns when the session is `running`, the CLI process exits, HelloText keeps running, and `apkrun runtime status --json` reports `owner: apkrund` (#032, FR-RT-02, FR-CLI-01).
- [ ] `runtimeStatus`, `install`, `launch`, `terminate`, `list`, and `applicationInfo` are available to APKRun.app, APKRunLauncher, and the CLI through RuntimeClient, and are documented in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) (#032, FR-RT-02).
- [ ] A test binary signed with another identity is rejected at the control endpoint (NFR-SEC-07, ADR-0007 verification).
- [ ] A wrapper connection that requests a session for another package gets `notAuthorized` (NFR-SEC-07).
- [ ] A warm launch after the runtime is `ready` writes no boot markers (G6 condition 3).
- [ ] When apkrund is not registered, every non-`dev` command prints the registration message and exits 69 (FR-CLI-01).

### Notes

- **Headless launch until #068.** Issue #032 requires `launch` to go through XPC before the launcher window exists, and a CLI never opens sessions itself ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §6.1). With `APKRUN_TEST_HEADLESS_LAUNCH=1` (Debug builds only), `launch` opens a session owned by apkrund on a pool display and discards the frames. #068 removes the hook and runs the acceptance check again with the launcher window. The release string check of #062 fails a Release build that contains the variable name.
- **Wrapper authorization seam.** The real wrapper identity check is #044. #032 adds a `WrapperAuthorizer` protocol with a Debug fixture authorizer that maps a test bundle ID to one package. The `notAuthorized` test uses it. #044 replaces the fixture authorizer.
- Record the ADR-0007 result (another identity rejected) in [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §16.

---

## #066 First-run provisioning

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #032, #065, #068 |
| Requirements | FR-OPS-07, NFR-RES-01, NFR-RES-02 |
| Design | [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §9, §13 #066; [../../02-design/host-ui.md](../../02-design/host-ui.md) §4, §14 #066; [../../02-design/android-image.md](../../02-design/android-image.md) §5, §10; [../../02-design/package-store.md](../../02-design/package-store.md) §9, §15 #066; [../../02-design/cli.md](../../02-design/cli.md) §3.6, §4.1 |
| Modules / paths | RuntimeHost (`HostRequirementsCheck`, the `setup` operation, `ProvisioningState`, Reset Android); ImageCore (install and instance provisioning from #065); APKStoreCore (`userdataGeneration`, the reinstall queue); RuntimeAPI (`setup`, `resetAndroid`, `provisioningState`); `Apps/APKRun/` (app skeleton, main window, `RuntimeStatusModel`, `Features/Onboarding/`); `CLI/apkrun/Commands/Setup.swift`; `Tests/IntegrationTests/DaemonTests/`; `Tests/IntegrationTests/HostUITests/`; `Tests/Fixtures/AndroidApps/` (HelloUpdate V1) |
| Risks / questions | None |

### Goal

A new user opens APKRun.app, approves the background service, and gets a runtime that is `ready`, without a terminal. The setup survives a quit in the middle, and **Reset Android** gives a fresh Android with every managed app reinstalled.

### Scope

- `HostRequirementsCheck` (§9.1): Apple Silicon, the macOS version, virtualization support, free disk space, and the other rows of the §9.1 table.
- The `setup` operation with `ProvisioningState` (§9.2) and resumable steps: `checkingHost`, `installingImage(fraction:)`, `creatingInstance`, `firstBoot(BootPhase, fraction:)`, `installingAgents`, `verifying`, `complete`, `failed(step:error:)`. The image install and the instance disks use ImageCore from #065 ([../../02-design/android-image.md](../../02-design/android-image.md) §5, §10).
- Registration with approval polling every 2 s (§9.2).
- The APKRun.app skeleton: the main window, `RuntimeStatusModel`, and the onboarding sheet with the texts of [../../02-design/host-ui.md](../../02-design/host-ui.md) §4.
- `apkrun setup [--image <path>] [--yes]` ([../../02-design/cli.md](../../02-design/cli.md) §4.1).
- Reset Android (§9.5) with `apkrun runtime reset --erase [--no-backup] [--yes]`: a new userdata, a 7-day recovery point unless `--no-backup`, and the reinstall of every managed package ([../../02-design/package-store.md](../../02-design/package-store.md) §9, §15 #066).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Listing, deleting, and restoring recovery points (#058). Whether the Reset Android recovery point can be restored is OQ-41; the working default is that it cannot in v1. The **Add App…** preview flow of the main window (#078).
  - Image updates and migration (#058, #087). Self-update (#057).
  - Troubleshooting and doctor (#059). Localization (#092).

### Deliverables

- `HostRequirementsCheck`, the `setup` operation, `ProvisioningState`, and Reset Android in RuntimeHost, with the RuntimeAPI DTOs in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- `userdataGeneration` and the reinstall queue in APKStoreCore.
- `Apps/APKRun/` with the app skeleton, the main window, `RuntimeStatusModel`, and `Features/Onboarding/`.
- `CLI/apkrun/Commands/Setup.swift` and `runtime reset --erase`.
- The HelloUpdate V1 fixture (`io.apkrun.fixture.helloupdate`, versionCode 1, key A, writes `HELLO`) in `Tests/Fixtures/AndroidApps/`, if it is not there yet.
- T1 tests `ProvisioningSystemTests` (RuntimeHost) and `OnboardingUITests` (XCUITest). T2 tests `ProvisioningTests` and `ResetAndroidTests` in `Tests/IntegrationTests/DaemonTests/`.

### Implementation steps

1. **Host requirements** (§9.1, §13 #066 step 1).
   - Implement `HostRequirementsCheck` with one result per row of the §9.1 table and a remediation for each failure.
   - Check: T0 tests with a fake host for every row.
2. **Setup and `ProvisioningState`** (§9.2, §13 #066 step 2; [../../02-design/android-image.md](../../02-design/android-image.md) §5, §10).
   - Implement the `setup` operation as a long operation with `ProvisioningState` progress. Each step is resumable: a restart continues at the first step that is not complete.
   - The image comes from the app bundle or from `--image <path>` (Debug builds and **Choose Image…**). ImageCore installs it and provisions the instance disks with `clonefile` on APFS.
   - `creatingInstance` writes the default VM size (4 vCPUs, 4 GiB, capped at 50 % of physical memory, NFR-RES-01) and creates userdata as a sparse file (NFR-RES-02).
   - `firstBoot` uses the first-boot timeouts of [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.2. `installingAgents` installs the development Guest Agent on the stock image. `verifying` waits for readiness (§3.4).
   - Check: T0 tests for the `ProvisioningState` transitions and resume points. T1 `ProvisioningSystemTests`: provisioning with a fake image on APFS, killed and resumed at each step.
3. **Onboarding and CLI** (§13 #066 step 3; [../../02-design/host-ui.md](../../02-design/host-ui.md) §4, §14 #066).
   - Build the APKRun.app skeleton, the main window, and `RuntimeStatusModel` over RuntimeClient.
   - Build the onboarding sheet with the texts of [../../02-design/host-ui.md](../../02-design/host-ui.md) §4: "Welcome to APKRun", the approval step ("Allow APKRun in System Settings → General → Login Items & Extensions." with **Open System Settings**), the progress steps, "Checking that everything works", and "You're ready." with the drop zone "Drag an APK here to add your first app" and **Add App…**. Failures show **Try Again**, **Report…**, and **Start Over**.
   - Registration polls the approval every 2 s (§9.2).
   - The drop zone and **Add App…** call `importPackage` and `installImported` of #027 directly.
   - Add `apkrun setup [--image <path>] [--yes]`. When apkrund is not registered, it opens `APKRun.app --register-runtime` and waits up to 5 minutes.
   - Check: T1 `OnboardingUITests` (XCUITest) with a fake runtime: the sheet resumes at the right step after a relaunch. T0 golden files for `apkrun setup`.
4. **Reset Android** (§9.5, §13 #066 step 4; [../../02-design/package-store.md](../../02-design/package-store.md) §9, §15 #066).
   - Implement Reset Android: stop the runtime, create a recovery point with `InstanceStore.createRecoveryPoint`, create a new userdata, and increase `userdataGeneration`. apkrund prunes recovery points older than 7 days at startup.
   - After the next `ready`, the reconciliation rule of [../../02-design/package-store.md](../../02-design/package-store.md) §9 queues a reinstall of every managed package in the background ("Restoring apps (3 of 12)…"). Package settings stay unchanged.
   - Add `apkrun runtime reset --erase [--no-backup] [--yes]`, which asks the user to type `Reset`.
   - Check: T2 `ResetAndroidTests`: HelloText and HelloUpdate V1 are installed, Reset Android runs, both are reinstalled, their settings are unchanged, and `apkrun launch` of each shows the first frame.
5. **Acceptance** (§9.4, §13 #066 step 5).
   - Run the acceptance check of §9.4 on a fresh macOS test user account, and record the times.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/RuntimeHost/Tests/RuntimeHostTests/`, `CLI/apkrun` test target): `HostRequirementsCheck` rows; `ProvisioningState` transitions and resume points; `apkrun setup` golden output.
- **T1** (`Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`, `Apps/APKRun` UI test target): provisioning with `clonefile` on APFS and resume after a kill; XCUITest onboarding resume.
- **T2** (`Tests/IntegrationTests/DaemonTests/`, AndroidStock suite, stock image): setup on an empty data root to `complete`; Reset Android reinstalls every managed package.
- **T3**: checklist C10-3 (onboarding on a fresh macOS user account) of [../test-strategy.md](../test-strategy.md) §8.

### Acceptance criteria

- [ ] On a fresh macOS user account, onboarding completes without a terminal: approval in System Settings, image install, first boot, and verification (§9.4).
- [ ] After onboarding, `ProvisioningState` is `complete` and `apkrun runtime status` reports `ready` (§9.4).
- [ ] Dragging HelloText onto the drop zone installs it, and opening it shows the first frame in its window (§9.4).
- [ ] Quitting APKRun.app during `firstBoot` and opening it again resumes the setup at the step where it stopped (§9.4).
- [ ] The provisioned instance uses the default VM size of 4 vCPUs and 4 GiB of memory, capped at 50 % of physical memory (NFR-RES-01).
- [ ] userdata is a sparse file on APFS: right after setup, its allocated size (`du`) is far below its logical size (NFR-RES-02).
- [ ] With HelloText and HelloUpdate V1 installed, **Reset Android** creates a recovery point, gives a fresh userdata, reinstalls both packages, and keeps their settings. Launching each one with `apkrun launch` shows the first frame ([../../02-design/package-store.md](../../02-design/package-store.md) §15 #066).
- [ ] The onboarding step times and the first-boot duration are recorded in [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §16.

### Notes

- **Order.** The acceptance check "opening it shows the first frame in its window" needs the launcher window of #068, which is why #068 is a dependency. Steps 1–4 can start as soon as #032 and #065 are done.
- **Fresh account.** Registration, the Login Items approval, and the data root are per user, so the §9.4 check runs on a fresh macOS test user account (checklist C10-3), not on a fresh `APKRUN_HOME`.
- Wrappers are M7, so the Reset Android check launches the reinstalled packages with `apkrun launch`, which opens the generic launcher ([../../02-design/package-store.md](../../02-design/package-store.md) §15 #066).
- #066 is the first user of HelloUpdate V1 and adds it with the V1 content of [../test-strategy.md](../test-strategy.md) §4.3. #037 adds the other variants.

---

## #068 Session client and IOSurface window over XPC

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #032 |
| Requirements | FR-DSP-07 |
| Design | [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5, §11, §12 #068, §13; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.3; [../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md); [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7; [../../02-design/graphics.md](../../02-design/graphics.md) §6.2, §6.3; [../../02-design/wrapper.md](../../02-design/wrapper.md) |
| Modules / paths | RuntimeAPI (session channel messages); RuntimeClient (the session client); APKRunLauncher (`XPCFrameSource`); RuntimeHost (session channel server); GraphicsCore (buffer state machine, `ScanoutController.requestPresent`); WindowingCore (`IOSurfaceLayerView`); `Apps/APKRunLauncher/` (`io.apkrun.APKRunLauncher`); `scripts/check-launcher.sh`; `Tests/IntegrationTests/WindowingTests/` |
| Risks / questions | R-03 |

### Goal

apkrund renders, and the launcher process owns the window: APKRunLauncher shows the app through the shared IOSurfaces of the session channel, with no copy in the launcher and no host readback. `apkrun launch` opens HelloText in its own launcher window.

### Scope

- The frame messages of the session channel (§5.1): `SessionDescriptor` with its `SurfaceSet` (generation, three IOSurfaces, pixel size, density), `frameReady`, `surfacesReplaced`, `frameDisplayed`, and `visibilityChanged`, in RuntimeAPI and RuntimeClient.
- `XPCFrameSource` in APKRunLauncher, on top of the RuntimeClient session client. Embedded development mode keeps `SurfacePoolFrameSource` (§5.3).
- The buffer state machine in GraphicsCore with rules 1–6 of §5.2: offered buffers are never overwritten, a buffer is freed only after a newer `frameDisplayed` and `IOSurfaceIsInUse == false`, latest frame wins, the 1 s back-pressure timeout, visibility with `requestPresent`, and generations.
- `IOSurfaceLayerView` in WindowingCore with the presentation algorithm of §5.3 and the color rules of §5.4 (BGRA8, sRGB, opaque layer).
- The generic launcher `Apps/APKRunLauncher` (`io.apkrun.APKRunLauncher`), embedded at `APKRun.app/Contents/Helpers/APKRunLauncher.app`. `launch` opens it with `--package <id>` when a package has no Mac app ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7). It connects through the control endpoint.
- `scripts/check-launcher.sh` in CI ([../../02-design/wrapper.md](../../02-design/wrapper.md)).
- Removing the headless launch hook of #032, and completing the G6 check with the window.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Wrapper generation, `WrapperIdentity`, the `.wrapper` endpoint, and per-app bundles (#044–#049).
  - Launch screens and the warm spare display (#070 measures the launch budget, [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §9).
  - Wide color and HDR (post-v1).

### Deliverables

- The session channel messages in RuntimeAPI with round-trip tests, documented in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- The session client in RuntimeClient, and `XPCFrameSource` in APKRunLauncher ([../../01-architecture/modules.md](../../01-architecture/modules.md) §2, RuntimeClient).
- The buffer state machine and `requestPresent` in GraphicsCore.
- `IOSurfaceLayerView` in WindowingCore.
- `Apps/APKRunLauncher/` and `scripts/check-launcher.sh`, run in CI.
- T0 `BufferStateMachineTests` and `PresentationAlgorithmTests`, T1 `IOSurfaceLayerViewSystemTests`, and T2 `WrapperPresentationTests` in `Tests/IntegrationTests/WindowingTests/`.
- The full G6 check in `Tests/AcceptanceTests/G6WarmRuntime`.

### Implementation steps

1. **Session messages and `XPCFrameSource`** (§5.1, §12 #068 step 1; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.3).
   - Add the frame messages to the session channel in RuntimeAPI and the server side in RuntimeHost. IOSurfaces cross XPC as `IOSurface` objects in the `SurfaceSet`.
   - Add `XPCFrameSource` to APKRunLauncher. It delivers `frameReady` to the main queue and coalesces events when the main thread is busy.
   - Check: T0 round trips for every message. T1: an in-process session delivers `frameReady` with the right generation and `frameSeq`, and coalesces when the receiver is blocked.
2. **Buffer state machine** (§5.2, §12 #068 step 2; [../../02-design/graphics.md](../../02-design/graphics.md) §6.2, §6.3).
   - Implement the buffer states `free`, `rendering`, `offered(seq)`, and `displayed(seq)` in GraphicsCore's `SurfacePool` with rules 1–6.
   - Add `ScanoutController.requestPresent(scanout)` for `visibilityChanged(true)`, so that a window that becomes visible shows the current frame without a guest flush.
   - Check: T0 `BufferStateMachineTests` with a scripted wrapper (some frames displayed, some delayed, acknowledgments stopped, visibility flipped) assert rules 1–6 and that no offered buffer is ever rendered into.
3. **Launcher and view** (§5.3, §5.4, §12 #068 step 3).
   - Add `IOSurfaceLayerView` to WindowingCore with the algorithm of §5.3: `CALayer` contents set to the IOSurface, actions disabled, `frameDisplayed` from the transaction completion block.
   - Add `Apps/APKRunLauncher` with `--package <id>`. It opens a session through RuntimeClient, shows the view, and reports visibility. Embedded mode keeps `SurfacePoolFrameSource`.
   - Make `launch` open the launcher for packages without a Mac app, and return when the session is `running`.
   - Remove `APKRUN_TEST_HEADLESS_LAUNCH` and its entries in [../../03-reference/configuration.md](../../03-reference/configuration.md) §5.1 and [../test-strategy.md](../test-strategy.md) §3.3.
   - Check: T0 `PresentationAlgorithmTests` (stale generation, reordering, coalescing). T1 `IOSurfaceLayerViewSystemTests` with a synthetic `FrameSource` in a real window (screenshot comparison). `scripts/check-launcher.sh` passes in CI.
4. **Acceptance** (§5.5, §12 #068 step 4).
   - Run `WrapperPresentationTests` with HelloGL, then the #032 acceptance check again with the window, then the full G6 check.
   - Record the `IOSurfaceIsInUse` result.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`, `Packages/WindowingCore/Tests/WindowingCoreTests/`): the buffer state machine with a scripted wrapper; the presentation algorithm (stale generation, reordering, coalescing).
- **T1** (`Packages/WindowingCore/Tests/WindowingCoreSystemTests/`): `IOSurfaceLayerView` with a scripted, synthetic `FrameSource` in a real window.
- **T2** (`Tests/IntegrationTests/WindowingTests/`, AndroidStock suite, stock image): HelloGL for 60 s in a launcher window: no tearing (the alternating-color test of [../../02-design/graphics.md](../../02-design/graphics.md) §12 #023), `readyToDisplayed` p95 below one refresh interval plus 4 ms, present cost below 2 ms p95, and `hostReadbacks = 0`.
- **T3**: the full G6 check (`scripts/run-gate.sh G6`).

### Acceptance criteria

- [ ] apkrund renders and APKRunLauncher owns the window: HelloText opened with `apkrun launch` shows in a launcher window fed by the IOSurfaces of the session channel (FR-DSP-07, ADR-0006).
- [ ] HelloGL runs for 60 s at 60 fps in a launcher window with no tearing, `readyToDisplayed` p95 below one refresh interval plus 4 ms, present cost below 2 ms p95, and `hostReadbacks = 0` (§5.5, FR-DSP-07).
- [ ] No offered buffer is ever rendered into, and a hidden window stops presents and shows the current frame at once when it becomes visible again (§5.2 rules 1, 5).
- [ ] The #032 acceptance check passes with the launcher window, and the headless launch hook is gone from the code and the Release build.
- [ ] The full G6 check passes on the reference Mac: quitting APKRun.app while HelloText's window is open leaves HelloText interactive for 5 minutes, a warm launch shows no boot markers, and `kill -9` of apkrund is recovered within 15 s with the window back (G6).

### Notes

- Record in [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §11 whether `IOSurfaceIsInUse` reflects WindowServer's use of layer contents. If it does not, rule 2(b) needs a replacement, and the fallback goes to §11 and R-03.
- Record G6 as passed in [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §16 and [../roadmap.md](../roadmap.md) §2.
- `WrapperIdentity` and the `.wrapper` endpoint come with #044. Until then every launcher connects to the control endpoint.

---

## #034 Full Guest Agent protocol and vsock transport

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #033, #027 |
| Requirements | FR-RT-04, FR-RT-05, NFR-REL-03, NFR-REL-04 |
| Design | [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3, §5–§8, §13, §15 #034, §16, §17; [../../02-design/guest-components.md](../../02-design/guest-components.md) §3–§6, §10, §11 #034; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §4 |
| Modules / paths | GuestProtocol (`Packages/GuestProtocol/`); RuntimeCore (`VsockGuestTransport`, `AndroidControlChannel`, `AdbClient`); `Guest/guestd/` (the remaining services, `HealthService`); `Guest/agentruntime/` (`SystemServices`); `Guest/vsockd/` (development build only); `Tests/IntegrationTests/GuestAgentTests/` |
| Risks / questions | R-18 |

### Goal

The Guest Agent implements every control operation that the runtime needs, and RuntimeCore uses GuestProtocol, not ADB shell commands, for all production control paths. HelloText launches through GuestProtocol with no `adb shell`, and ADB stays available for debugging.

### Scope

- The remaining control operations of [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1: 15 `StopApplication` with `FORCE_STOP`, 16 `MoveTaskToDisplay`, 17 `ListTasks`, 21 `GetHealth`, and 70 `Shutdown`, with the remaining events of §8.1 up to #22 and the timeouts of §6. Already done in M3: 15 with `FINISH_TASKS` (#026), 19 `QueryPackage` and 20 `ListPackages` (#027), and 13 `ClearDisplay` with `TasksCleared` (#028) ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §15 #034 step 1).
- The guest services behind them and `HealthService` with `AppProcessEvent` and memory figures ([../../02-design/guest-components.md](../../02-design/guest-components.md) §11 #034).
- `VsockGuestTransport`, validated on the stock image with `apkrun_vsockd` run as root if that image's policy lets the `su` domain use vsock ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §13.3, §15 #034 step 2).
- `AndroidControlChannel` over GuestProtocol for every production control path in RuntimeCore. `AdbClient` counts `adb shell` invocations for tests.
- Health detection and reconnect when an agent dies (NFR-REL-03), and explicit rejection of an incompatible major version (NFR-REL-04).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - `AuthorizeAdbKey` (72): it needs the privileged agent, so the development agent answers `UNSUPPORTED` until #035. Operation 71 is reserved: developer mode is only the boot parameter `androidboot.apkrun.devmode`, which the host sets before each Android start ([../../02-design/android-image.md](../../02-design/android-image.md) §11.3).
  - The bridge in the image, its sepolicy, and vsock as the production transport (#035). The Store Agent operations (#036).
  - Integration operations: clipboard (#053), `SyncTime` (#069), `CollectDiagnostics` (#070), and the M9 operations.

### Deliverables

- Guest services for operations 15 (`FORCE_STOP`), 16, 17, 21, and 70, and the remaining events up to #22, in `Guest/guestd/`, with the `SystemServices` wrappers they need in `Guest/agentruntime/`.
- Host handlers in RuntimeCore, `VsockGuestTransport`, and `AndroidControlChannel`.
- The `adb shell` counter in `AdbClient`, and the raw-ADB lint allowlist updated so that no production path calls `adb shell` ([../test-strategy.md](../test-strategy.md) §3.3).
- T0 `GuestConnectionTests`, T1 Kotlin server tests against a scripted host, and T2 `GuestProtocolLaunchTests` and `AgentReconnectTests` in `Tests/IntegrationTests/GuestAgentTests/` (plus `VsockTransportTests` when the stock image allows it).

### Implementation steps

1. **Remaining operations and events** ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §8.1, §15 #034 step 1; [../../02-design/guest-components.md](../../02-design/guest-components.md) §11 #034 step 1).
   - Implement 15 (`FORCE_STOP`), 16, 17, 21, and 70 on both sides. Each operation checks its capability and uses its timeout from §6 (`Shutdown` 20 s).
   - Emit the events of §8.1 up to #22 from the agent.
   - A hidden API that is missing fails only its capability ([../../02-design/guest-components.md](../../02-design/guest-components.md) §6.2).
   - Check: T0 `GuestConnectionTests` with an in-memory fake agent: pipelining, out-of-order responses, timeouts, cancel, keepalive loss, and resync ordering. T1: the Kotlin server against a scripted host for every new operation.
2. **Health** ([../../02-design/guest-components.md](../../02-design/guest-components.md) §11 #034 step 2; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §4).
   - Implement `HealthService` with `AppProcessEvent` and the memory figures, and `GetHealth` on the host.
   - Check: T2 `AgentReconnectTests`: after the agent process is killed, the host detects it within the keepalive rule (Ping 5 s, 3 missed), reconnects, resyncs, and the open session continues.
3. **vsock transport** ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §13.3, §15 #034 step 2; [../../02-design/guest-components.md](../../02-design/guest-components.md) §10, §11 #034 step 3).
   - Implement `VsockGuestTransport` in RuntimeCore.
   - Build `apkrun_vsockd` with `cargo ndk -t arm64-v8a build --release`, push it to `/data/local/tmp`, and start it as root (`adb root`). If the stock policy lets the `su` domain use vsock, run `VsockTransportTests`. If not, record the refusal, and move the vsock validation to #035.
   - `apkrun dev boot --guest-transport vsock|adb` selects the transport.
   - Check: `VsockTransportTests` pass, or the deferral and the denial message are recorded.
4. **Control path switch** ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §15 #034 step 3).
   - Switch every production control path in RuntimeCore from ADB to `AndroidControlChannel`. `AdbClient` stays for installs on the stock image, debugging, and the development fallbacks, and counts `adb shell` invocations.
   - Check: the raw-ADB lint passes with no production entry left in the allowlist for control paths.
5. **Acceptance** ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §15 #034 step 4).
   - Run `GuestProtocolLaunchTests`: launch HelloText, and assert that the `adb shell` counter does not change between runtime ready and the first frame.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/GuestProtocol/Tests/GuestProtocolTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`): `GuestConnection` pipelining, timeouts, cancel, and resync; the handshake matrix with a major-version mismatch.
- **T1** (`Guest/guestd` JVM tests): the Kotlin server against a scripted host.
- **T2** (`Tests/IntegrationTests/GuestAgentTests/`, AndroidStock suite, stock image): the vsock transport (or its recorded deferral); reconnect after an agent kill with session continuity; the `adb shell` counter unchanged between ready and the first frame.
- **T3**: none.

### Acceptance criteria

- [ ] HelloText can be launched through GuestProtocol without ADB shell commands: the `adb shell` counter does not change between runtime ready and HelloText's first frame (#034).
- [ ] ADB remains available for debugging: `adb -s 127.0.0.1:6520 shell` works in developer mode (#034, FR-RT-05).
- [ ] Operations 13, 15–17, 19–21, and 70 and the events up to #22 work on the stock image, each behind its capability, including the ones M3 brought (FR-RT-04).
- [ ] A killed Guest Agent is detected and reconnected, and an open session continues (NFR-REL-03).
- [ ] An agent with a different major version is rejected with `incompatibleVersion`, and the runtime does not continue silently (FR-RT-04, NFR-REL-04).
- [ ] The vsock transport is validated on the stock image, or its deferral to #035 is recorded with the reason.

### Notes

- Record in [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18 and [../../02-design/guest-components.md](../../02-design/guest-components.md) §14: the vsock result on the stock image (or the deferral), and the launch without `adb shell`. Record the hidden APIs the new operations use, with their results, under R-18.
- `AuthorizeAdbKey` (72) answers `UNSUPPORTED` from the shell-mode agent until #035 implements it in the privileged agent. Operation 71 is reserved and is not implemented.

---

## #053 Clipboard, plain text

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #034, #068 |
| Requirements | FR-INT-01, NFR-SEC-03, FR-CLI-01 |
| Design | [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §2, §4, §14 #053, §15; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §8.4; [../../02-design/guest-components.md](../../02-design/guest-components.md) §5, §11; [../../02-design/input.md](../../02-design/input.md) §6; [../../02-design/cli.md](../../02-design/cli.md) §4 |
| Modules / paths | IntegrationCore (`Packages/IntegrationCore/`: `IntegrationPolicy`, `IntegrationChannel`, `ClipboardCoordinator`); RuntimeAPI (session additions: `pushClipboard`, `clipboardFromGuest`, `clipboardWritten`); `Apps/APKRunLauncher/` (`PasteboardAdapter`); `Guest/guestd/` (`ClipboardBridge`, `SetClipboard` 40, `ClipboardChanged`); `CLI/apkrun/Commands/Integrations.swift`; `Tests/IntegrationTests/DesktopIntegrationTests/` |
| Risks / questions | R-21 |

### Goal

Plain text copied on the Mac pastes into the focused Android app, and plain text copied in Android lands on the Mac pasteboard, with no feedback loop and a per-app switch.

### Scope

- The IntegrationCore skeleton: `IntegrationPolicy` (per-app switch and global switch, NFR-SEC-03) and `IntegrationChannel` ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §14 #053 step 1).
- The clipboard model of §4.1–§4.4: no background sync, so content is exchanged only while a window of a package with `integrations.clipboard` is key. `PasteboardAdapter` in the launcher reads and writes the Mac pasteboard; `org.nspasteboard.ConcealedType` marks a clip sensitive; `org.nspasteboard.TransientType` is used only for a paste, never on focus; the marker `io.apkrun.clip-origin` marks APKRun's own writes. Content is never logged or stored.
- Mac → Android (§4.2), at a paste and when the window becomes key (skipped when the read would prompt, R-21): `pushClipboard(ClipItem)` through `IntegrationPolicy` to `SetClipboard` (op 40) and its `ClipAck`. ⌘V pastes after the acknowledgment, or after 500 ms as a plain-text commit ([../../02-design/input.md](../../02-design/input.md) §6).
- Android → Mac (§4.3): the guest listener in `ClipboardBridge` sends `ClipboardChanged`. apkrund accepts it only while a window is key and the source package is that window's package (or another package with `integrations.clipboard`), and sends `clipboardFromGuest` to the window's process, which writes the pasteboard and answers `clipboardWritten`. Changes while no window is key are dropped.
- The 1 MiB plain-text limit of §4.4: longer text is truncated at a character boundary, and the window shows "Only the first 1 MB was copied."
- The three loop-prevention signals of §4.4.
- `apkrun integrations status <package> [--json]`.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Images, files, and rich text on the clipboard (#080, #082).
  - Notifications, URLs, and shared folders (#054, #081, #082). The per-app settings UI (#079).

### Deliverables

- IntegrationCore with `IntegrationPolicy`, `IntegrationChannel`, and `ClipboardCoordinator`.
- The session additions in RuntimeAPI, documented in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- `PasteboardAdapter` in `Apps/APKRunLauncher/`.
- `ClipboardBridge`, `SetClipboard`, and `ClipboardChanged` in `Guest/guestd/`.
- `apkrun integrations status` with golden files.
- The fixture HelloClipboard (`io.apkrun.fixture.helloclipboard`: a text field, a Copy button with a known string, and a view of the current primary clip, §4.5), if it is not there yet.
- T0 `IntegrationPolicyTests` and `ClipboardLoopTests`, T1 `ClipboardBridgeTests`, and T2 `ClipboardTests` in `Tests/IntegrationTests/DesktopIntegrationTests/`.

### Implementation steps

1. **IntegrationCore skeleton** (§14 #053 step 1).
   - Add `IntegrationPolicy` and `IntegrationChannel`. Every host integration passes guest agent → policy → host (NFR-SEC-03).
   - Check: T0 `IntegrationPolicyTests` for the per-app and global switches.
2. **Coordinator and adapter** (§4.1–§4.3, §14 #053 step 2).
   - Add `ClipboardCoordinator` in apkrund and the session additions. Add `PasteboardAdapter` in the launcher target.
   - Check: T0 `ClipboardLoopTests`: the three loop-prevention signals of §4.4 (`origin` and `seq`, the host content digest, and the `io.apkrun.clip-origin` marker) stop an echo in both directions.
3. **Guest bridge** (§4.3, §14 #053 step 3; [../../02-design/guest-components.md](../../02-design/guest-components.md) §5).
   - Add `ClipboardBridge` with `SetClipboard` and the listener that sends `ClipboardChanged`.
   - Verify that the shell-mode agent can read, write, and listen to the clipboard in the background on the stock image. If a restriction applies, move the listener into the IME process (#071).
   - Check: T1 `ClipboardBridgeTests`: echo suppression against a scripted host.
4. **⌘V with acknowledgment** (§14 #053 step 4; [../../02-design/input.md](../../02-design/input.md) §6).
   - ⌘V pushes the Mac clipboard with an acknowledgment, then sends the paste. Before #053, ⌘V was a plain commit.
   - Check: T2: ⌘V in HelloText pastes the Mac text.
5. **Acceptance** (§4.5, §14 #053 step 5).
   - Run `ClipboardTests` and checklist C02-3. Measure the ⌘V latency with the #070 harness when it exists.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): `IntegrationPolicy`; loop prevention.
- **T1** (`Guest/guestd` JVM tests, `Packages/IntegrationCore/Tests/IntegrationCoreSystemTests/`): `ClipboardBridge` echo suppression.
- **T2** (`Tests/IntegrationTests/DesktopIntegrationTests/`, AndroidStock suite, stock image; again in the AndroidCustom suite after #035): the §4.5 checks: HelloClipboard both ways with "héllo 😀"; nothing crosses with the setting off; a 5-minute loop check with `changeCount` unchanged; the 1 MiB limit.
- **T3**: ⌘V p95 ≤ 150 ms for 64 KiB of text through #070; checklist C02-3 (TextEdit and HelloClipboard both ways, R-21 recorded).

### Acceptance criteria

- [ ] Copy and paste work in both directions for plain text: text copied in TextEdit pastes into HelloClipboard, and text copied in HelloClipboard pastes into TextEdit, including "héllo 😀" (#053, FR-INT-01).
- [ ] No feedback loop: during a 5-minute check, the Mac pasteboard's `changeCount` changes only for user copies (#053, FR-INT-01).
- [ ] With the clipboard integration off for the app, nothing crosses in either direction (NFR-SEC-03).
- [ ] Clips cross only while a window of the package is key, only the key window's package can write the Mac pasteboard, and text over 1 MiB is truncated with "Only the first 1 MB was copied." (§4.1, §4.3, §4.4).
- [ ] `apkrun integrations status <package>` shows the clipboard state (FR-CLI-01).
- [ ] ⌘V p95 ≤ 150 ms for 64 KiB of text on the reference Mac (§4.5).

### Notes

- **Order.** `PasteboardAdapter` lives in the launcher target (step 2), so #053 depends on #068.
- In M4 the T2 test runs on the stock image with the shell-mode agent, and it runs again in the AndroidCustom suite after #035 ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §15).
- Record in [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §17: R-21 (does a pasteboard read on focus prompt on macOS 27, which API reports `changeCount`), the background clipboard read as shell, and the ⌘V latency. Record the clipboard-as-shell result in [../../02-design/guest-components.md](../../02-design/guest-components.md) §14 too. If a read prompts, the fallback of R-21 applies: push on paste only.

---

## #069 Idle policy and host sleep/wake

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #031 |
| Requirements | FR-VM-10, FR-VM-11, NFR-PERF-06 |
| Design | [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §5, §6, §13 #069, §15; [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §9; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1 (op 48); [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §2; [../../03-reference/configuration.md](../../03-reference/configuration.md) |
| Modules / paths | RuntimeHost (`IdleController`, `RuntimeActivityAssertion`, `PowerObserver`, preboot, memory pressure); RuntimeCore (pause and resume, `SyncTime` client, the development ADB time fallback); `Guest/guestd/` (`SyncTime` handler); `CLI/apkrun/Commands/Dev/Power.swift`; `Tests/IntegrationTests/DaemonTests/` |
| Risks / questions | OQ-32, OQ-33 |

### Goal

When no app has been open for a while, the runtime suspends, and later stops, by itself, with apkrund using almost no CPU while suspended. The next launch resumes it quickly. Host sleep and wake pause and resume the VM, and the guest clock is correct afterwards.

### Scope

- `IdleController` with the activity sources of §5.1 (sessions, background tasks with `keepRunning`, store operations, diagnostics, migration and provisioning, ADB clients, and `apkrun runtime start --hold`) and `RuntimeActivityAssertion`.
- The timers and settings of §5.2: `runtime.idleSuspendMinutes` (default 10), `runtime.idleStopMinutes` (default 60), `0` meaning never, and `runtime.startPolicy`. The timers use a `SuspendingClock`, so host sleep does not count.
- Suspend and resume (§5.3): pause the agents, pause the VM (`VM_PAUSED`); resume the VM (`VM_RESUMED`), `Ping` within 2 s, `SyncTime`, then `ready`.
- Preboot (§5.4): `startPolicy = atLogin` boots 60 s after login, skipped on battery below 30 % and while the boot-loop guard blocks boots.
- Host memory pressure (§5.5): `.critical` with no visible session suspends the runtime.
- `PowerObserver` (§6) with `IORegisterForSystemPower`: pause within 5 s of `WillSleep` (`power.pauseLate` when later), resume on `HasPoweredOn`, resume on every wake (OQ-33).
- Time sync after resume and wake: `SyncTime` (op 48) when the difference is over 500 ms, corrected by half the `Ping` round trip ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §9).
- `apkrun dev power sleep|wake` for T2 tests.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Locale, time zone, and clock format (#085).
  - A memory balloon before a pause (OQ-32, working default: none in v1).
  - VM save and restore (R-07, accepted).
  - The Settings UI for the idle timers (#079 and host-ui).

### Deliverables

- `IdleController`, `RuntimeActivityAssertion`, `PowerObserver`, preboot, and the memory-pressure handler in RuntimeHost.
- Pause and resume, the `SyncTime` client, and the development ADB time fallback in RuntimeCore. The `SyncTime` handler in `Guest/guestd/`.
- `apkrun dev power sleep|wake`.
- The settings keys in [../../03-reference/configuration.md](../../03-reference/configuration.md), if they are not there yet.
- T0 `IdleControllerTests` with a manual clock, and T2 `IdleSuspendTests` and `SleepWakeTests` in `Tests/IntegrationTests/DaemonTests/`.

### Implementation steps

1. **IdleController** (§5.1, §5.2, §13 #069 step 1).
   - Implement `IdleController` with the activity sources and `RuntimeActivityAssertion`, both timers, and the settings. A settings change restarts the timers.
   - Check: T0 `IdleControllerTests` with a manual clock: every activity source holds the runtime, both timers fire, `0` means never, a settings change applies, and time asleep is not counted.
2. **Suspend, resume, preboot, and memory pressure** (§5.3–§5.5, §13 #069 step 2).
   - Implement suspend and resume in `RuntimeSupervisor` with the markers `VM_PAUSED` and `VM_RESUMED`. A launch request while `suspended` resumes first.
   - Implement preboot for `startPolicy = atLogin` and the memory-pressure rule.
   - Check: T2 `IdleSuspendTests` with `runtime.idleSuspendMinutes = 1` and `runtime.idleStopMinutes = 2`.
3. **Sleep and wake** (§6, §13 #069 step 3).
   - Implement `PowerObserver`. `apkrun dev power sleep|wake` injects the same messages into the running `apkrun dev boot` through its control socket (development builds only, see Notes).
   - Check: T2 `SleepWakeTests` with injected sleep and wake: the VM is paused before the sleep acknowledgment and resumed after wake.
4. **Time sync** (§13 #069 step 4; [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §9).
   - Implement `SyncTime` on the host and a guest handler. The shell-mode agent answers `UNSUPPORTED`. The privileged agent of #035 sets the time.
   - In Debug builds on the stock userdebug image, the host falls back to `adb root` and `adb shell date -u @<seconds>`. Release builds never use ADB for time. Try `cmd time_detector` as the shell uid, and record the result.
   - Check: T2 `SleepWakeTests`: within 5 s of wake, the guest clock (`adb shell date +%s`) is within 2 s of the host clock.
5. **Acceptance** (§5.6, §6, §13 #069 step 5).
   - Run the T2 tests and the T3 checks, and record the results.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/RuntimeHost/Tests/RuntimeHostTests/`): `IdleController` with a manual clock.
- **T1**: none.
- **T2** (`Tests/IntegrationTests/DaemonTests/`, AndroidStock suite, stock image): suspended after 1 minute; resume p50 ≤ 500 ms over 20 runs; the idle stop; `keepRunning`, a connected `adb shell`, and a running install each prevent the suspend; injected sleep and wake with time sync.
- **T3**: the nightly real sleep with `pmset sleepnow`; the `idle-cpu` scenario of #070; checklist C02-4 and C10-9 (lid close) of [../test-strategy.md](../test-strategy.md) §8.

### Acceptance criteria

- [ ] With `runtime.idleSuspendMinutes = 1` and no sessions, the runtime is `suspended` after 1 minute, and apkrund uses less than 1 % CPU while suspended (`top -l 61 -s 1 -pid <pid>`) (FR-VM-10, NFR-PERF-06).
- [ ] Opening HelloText from `suspended` shows its first frame, and `VM_RESUMED` → `RUNTIME_READY` has a p50 of at most 500 ms over 20 runs (FR-VM-10).
- [ ] With `runtime.idleStopMinutes = 2`, the runtime stops gracefully, and apkrund exits after the grace period when no client is connected (FR-VM-10).
- [ ] A `keepRunning` task, a connected `adb shell`, and a running install each prevent the suspend (§5.1).
- [ ] On host sleep the VM is paused within 5 s, and within 5 s of wake the guest clock is within 2 s of the host clock (FR-VM-11, §6).

### Notes

- `apkrun dev power sleep|wake` is a request to the running `apkrun dev boot`, sent on `$APKRUN_HOME/Runtime/dev-console/control.sock` (mode 0600, removed at stop, like the console sockets of #014). It does not take the instance lock, so the exit-75 rule for `dev` commands ([../../02-design/cli.md](../../02-design/cli.md) §5) does not apply to it. `PowerObserver` and `IdleController` are RuntimeHost code, so `SleepWakeTests` exercise the same code as apkrund. The real sleep in T3 (`pmset sleepnow`) runs against apkrund.
- On the stock image, `SyncTime` answers `UNSUPPORTED`, so the time check runs through the Debug ADB fallback in M4. It runs again with `SyncTime` in the AndroidCustom suite after #035.
- Record in [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §16: the CPU while suspended, the resume p50, the clock after wake, the balloon measurement (OQ-32, with #070), and the pause and resume churn during dark wakes (OQ-33). Record the `cmd time_detector` result in [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §17.

---

## #070 Performance harness

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #031, #068 |
| Requirements | FR-RT-03, FR-OPS-05, NFR-PERF-01, NFR-PERF-02, NFR-PERF-03, NFR-PERF-04, NFR-PERF-05, NFR-PERF-06, NFR-PERF-07, NFR-RES-04 |
| Design | [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §4, §5, §7.6, §9, §11 #070, §13; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3, §6, §7.1 (op 73), §10, §15; [../../02-design/guest-components.md](../../02-design/guest-components.md) §6.1, §11; [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7, §9; [../../02-design/input.md](../../02-design/input.md) §8; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §6.3, §13.1 |
| Modules / paths | RuntimeHost (`PerfRecordWriter`, `perfStatistics`, `MetricsSampler`); RuntimeAPI (`OpenSessionRequest.launchTiming`, `PerfStatisticsRequest`, `WirePerfStatistics`, the session channel request `frameStatistics`); `Apps/APKRunLauncher/` (`launchTiming`, `FIRST_FRAME_DISPLAYED`, View → Show Frame Statistics); GuestProtocol (`CollectDiagnostics`, op 73); RuntimeCore (the `CollectDiagnostics` client, the bulk stream); `Guest/guestd/` (`DiagnosticsService`); `Tests/PerformanceTests/` (`apkrun-perf`, `baselines/`); `Tests/IntegrationTests/DiagnosticsTests/` |
| Risks / questions | R-03, R-07, R-08, OQ-02, OQ-06, OQ-07, OQ-32 |

### Goal

`swift run apkrun-perf <scenario>` measures every NFR-PERF target on the reference Mac in a repeatable way, breaks each launch and boot into marker segments, and fails the nightly job on a regression. The `memory` scenario reads Android's memory figures through `CollectDiagnostics`.

### Scope

- `PerfRecordWriter` in apkrund with `launches.jsonl` and `boots.jsonl` (§4.3), `OpenSessionRequest.launchTiming` in RuntimeAPI and the launcher, and the marker `FIRST_FRAME_DISPLAYED`.
- `perfStatistics(PerfStatisticsRequest{reset})` on the control endpoint (§7.6): input histograms, graphics statistics per session, and marker aggregates.
- The frame statistics overlay ([../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7): the session channel request `frameStatistics` → `SessionGraphicsStatistics` from `ScanoutController.statistics` ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §6.3, §13.1), and View → Show Frame Statistics in APKRunLauncher. Developer mode only: with `developer.enabled` off the request fails with `runtime.developerModeRequired` and the menu item is hidden.
- `MetricsSampler` (§5), including the search for the Virtualization.framework XPC service process that hosts the VM (OQ-06) and `gpuUtilization` (OQ-07, best effort).
- Guest protocol operation 73 `CollectDiagnostics` with the capability `diagnostics.v1`, on the host (GuestProtocol and RuntimeCore) and in the Guest Agent's `DiagnosticsService` ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §15; [../../02-design/guest-components.md](../../02-design/guest-components.md) §6.1). The items travel as bulk transfers over the guest bulk stream (port 6102, [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3, §10), with a 16 MiB cap per item and the 60 s operation timeout. This task implements the one item `DUMPSYS_MEMINFO` (`dumpsys meminfo -c`). An agent that does not know a requested item answers that item with the status `unsupported`, and never fails the request.
- `apkrun-perf` in `Tests/PerformanceTests/` with the preconditions of §9.2 and the scenarios of §9.3: `warm-launch`, `suspended-launch`, `cold-launch`, `input-latency`, `hellogl-fps`, `idle-cpu`, `update-check-launch`, `boot-phases`, `memory`, and `all`.
- Results (`results.json`, `summary.md`), baselines per lab Mac, and the nightly job with the regression rule of §9.4.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - The other `CollectDiagnostics` items: `DUMPSYS_SURFACEFLINGER` (#059) and the rest (#060).
  - Doctor, the diagnostics bundle, and the Redactor (#059, #060).
  - Performance work to meet a missed target. A miss is filed as its own task against the module that owns the segment.

### Deliverables

- `PerfRecordWriter`, `perfStatistics`, and `MetricsSampler` in RuntimeHost, and the RuntimeAPI types in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- `launchTiming`, `FIRST_FRAME_DISPLAYED`, and the frame statistics overlay in APKRunLauncher. `frameStatistics` on the session channel in RuntimeAPI and RuntimeHost.
- Operation 73 `CollectDiagnostics` with the capability `diagnostics.v1` and the item `DUMPSYS_MEMINFO`: the message handling in GuestProtocol, the client and the bulk stream in RuntimeCore, and `DiagnosticsService` in `Guest/guestd/`.
- `apkrun-perf` in `Tests/PerformanceTests/`, the first baseline `Tests/PerformanceTests/baselines/<model identifier>.json`, and the nightly job.
- T0 tests for `PerfRecordWriter` and `launchState` (diagnostics T1-9, run as T0), T1 tests for the Kotlin `DiagnosticsService`, and the T2 test `CollectDiagnosticsTests` in `Tests/IntegrationTests/DiagnosticsTests/`.

### Implementation steps

1. **Launch and boot records** (§4.3, §11 #070 step 1).
   - Add `PerfRecordWriter` to apkrund with `launches.jsonl` and `boots.jsonl` and their `launchState`.
   - Add `OpenSessionRequest.launchTiming` to RuntimeAPI and fill it in the launcher. The launcher writes `FIRST_FRAME_DISPLAYED` from the first `frameDisplayed`.
   - Check: T0 tests for the record format, the `launchState` values, and file rotation.
2. **`perfStatistics`** (§7.6, §11 #070 step 2).
   - Add `perfStatistics(PerfStatisticsRequest{reset})` → `WirePerfStatistics` on the control endpoint.
   - Add the session channel request `frameStatistics` → `SessionGraphicsStatistics` for the session's display. It never starts Android, and it fails with `runtime.developerModeRequired` while `developer.enabled` is off.
   - Add View → Show Frame Statistics to APKRunLauncher, shown only in developer mode. While the overlay is shown, the launcher sends `frameStatistics` once per second and draws fps, dropped frames, the present GPU time, and the readback counters over the content.
   - Check: T0 round trips, and a T1 test over an anonymous listener that `reset: true` clears the aggregates and that `frameStatistics` fails with `runtime.developerModeRequired` while developer mode is off.
3. **`MetricsSampler`** (§5, §11 #070 step 3).
   - Implement `MetricsSampler` with the host figures of §5. Find the Virtualization.framework XPC service process by name, user, and start time right after `VM_START`, and verify the match.
   - Check: on a lab Mac the sampler reports the VM process and apkrund RSS. Record whether the VZ process match and `gpuUtilization` work.
4. **`CollectDiagnostics` and `apkrun-perf`** (§9.2, §9.3, §11 #070 step 4; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §10, §15).
   - Add operation 73 `CollectDiagnostics` on the host and in the Guest Agent's `DiagnosticsService`, behind `diagnostics.v1`. The request lists items and a `max_bytes` of at most 16 MiB. The agent runs `dumpsys meminfo -c` for `DUMPSYS_MEMINFO`, sends the output as a bulk transfer over the bulk stream (port 6102), and truncates at `max_bytes`. The result pairs each requested item with its status (`OK`, `UNSUPPORTED`, `TOO_LARGE`, or `FAILED`), its transfer ID, and a `truncated` flag. An unknown item gets `UNSUPPORTED`. The host enforces the 16 MiB cap and the 60 s timeout. On the stock image the bulk stream uses an ADB forward; on the custom image it uses vsock.
   - Add `apkrun-perf` with the preconditions and all scenarios. `memory` collects `MetricsSnapshot` with `DUMPSYS_MEMINFO` after `warm-launch`.
   - Check: T1 JVM tests for `DiagnosticsService` (the known item, an unknown item, truncation at `max_bytes`). T2 `CollectDiagnosticsTests`. `apkrun-perf memory` prints the values.
5. **Results, baselines, and the nightly job** (§9.4, §11 #070 step 5).
   - Write `results.json` and `summary.md`. Add the first baseline for each lab Mac through a reviewed pull request. Add the nightly job with the failure rule (a missed NFR target, or a p50 more than 15 % worse than the baseline, 10 % for `hellogl-fps`), naming the segment that grew most.
   - Check: a nightly run on the reference Mac produces both files and compares against the baseline.
6. **Acceptance** (§11 #070 step 6).
   - Run `apkrun-perf all` on the reference Mac. Attach the first report of every scenario to the #070 issue as the initial baseline.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/RuntimeHost/Tests/RuntimeHostTests/`, `Packages/GuestProtocol/Tests/GuestProtocolTests/`): `PerfRecordWriter` and `launchState` (diagnostics T1-9); `perfStatistics` and `frameStatistics` round trips; the `CollectDiagnostics` messages and the item status rules.
- **T1** (`Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`, over `NSXPCListener.anonymous`): `reset: true` clears the aggregates; `frameStatistics` fails with `runtime.developerModeRequired` while developer mode is off.
- **T1** (`Guest/guestd` JVM tests): `DiagnosticsService` with a fake `dumpsys`: the known item, an unknown item answered `UNSUPPORTED`, truncation at `max_bytes`.
- **T2** (`Tests/IntegrationTests/DiagnosticsTests/`, AndroidStock suite, stock image): `CollectDiagnosticsTests`: `CollectDiagnostics` returns `DUMPSYS_MEMINFO` over the bulk stream, and an item the agent does not know is answered `unsupported` while the request itself succeeds.
- **T3** (`Tests/PerformanceTests/`, nightly on the reference Mac): every scenario of §9.3; two consecutive `warm-launch` runs within 10 % at p50; the segments add up to the total within 5 ms.

### Acceptance criteria

- [ ] `apkrun-perf` runs every scenario of §9.3 on the reference Mac, checks the preconditions of §9.2, and writes `results.json` and `summary.md` (FR-OPS-05).
- [ ] Two consecutive `warm-launch` runs on the reference Mac agree within 10 % at p50, and the marker segments add up to the total within 5 ms (§11 #070).
- [ ] The first report of every scenario is attached to the #070 issue and committed as the initial baseline. The NFR-PERF-01 to NFR-PERF-06 results are recorded in [../traceability.md](../traceability.md) §2, including the warm launch p50 and p95 (NFR-PERF-01) (NFR-PERF-01 to NFR-PERF-06, FR-RT-03).
- [ ] `update-check-launch` is reported as skipped with its reason until #037 and #074 exist, and runs from then on (NFR-PERF-07).
- [ ] The `memory` scenario reports the values: VM memory, system_server, SurfaceFlinger, zygote, each APK, host graphics memory, and apkrund RSS (NFR-RES-04).
- [ ] `CollectDiagnostics` (operation 73, capability `diagnostics.v1`) returns `DUMPSYS_MEMINFO` over the bulk stream within the 16 MiB cap and the 60 s timeout, and an item the agent does not know is answered `unsupported` without failing the request (FR-OPS-05, NFR-RES-04).
- [ ] The nightly job fails on a missed NFR target or a p50 regression over the §9.4 threshold, and names the segment that grew most.
- [ ] In developer mode, View → Show Frame Statistics in the launcher shows the session's fps, dropped frames, and readback counters, refreshed once per second. With developer mode off, the item is hidden and `frameStatistics` fails with `runtime.developerModeRequired` ([../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7).

### Notes

- **Preconditions in M4.** §9.2 generates the Mac apps with `apkrun wrap` (#075, M7). Until then the harness opens the generic launcher (`APKRunLauncher.app --package <id>`) with `NSWorkspace`, and the results record the launch path. §9.2 also asks for a release build. The lab uses a Release configuration signed with the lab identity.
- OQ-02 (the reference Mac) is answered before this task starts. Working default: the lowest-tier Mac in the lab, M1 with 16 GB (§9.4).
- OQ-34 (Store Agent memory) cannot be measured here, because the Store Agent comes with #036. The `memory` scenario measures it when #036 is done, and the result is recorded then.
- Record in [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14: the VZ process match (OQ-06), `gpuUtilization` (OQ-07), the first report, and the warm-launch repeatability. Record the input latency in [../../02-design/input.md](../../02-design/input.md) §15, and the balloon measurement (OQ-32) and the resume p50 in [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §16.
- The per-item result is `CollectDiagnosticsResult{repeated DiagnosticsItemResult{item, status, transfer_id, truncated}}` ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1). The name avoids a clash with the RuntimeAPI type `DiagnosticsResult`.

---

## #071 APKRun IME

| Field | Value |
|---|---|
| Milestone | M4 (v0.2) |
| Depends on | #034, #068 |
| Requirements | FR-IN-07, FR-IN-08 |
| Design | [../../02-design/input.md](../../02-design/input.md) §5, §6, §7.2, §12 #071; [../../02-design/guest-components.md](../../02-design/guest-components.md) §7, §11; [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §4, §11; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3 |
| Modules / paths | `Guest/guestd/` (`io.apkrun.guest/.ime.ApkRunInputMethodService`, `res/xml/method.xml`); InputCore (`TextInputModel`, editor commands, the secure-input counter); WindowingCore (`NSTextInputClient` in `IOSurfaceLayerView`); GuestProtocol (`ImeState`, the IME messages of the input stream); `Tests/Fixtures/AndroidApps/` (HelloCompose); `Tests/IntegrationTests/InputTests/` |
| Risks / questions | R-05 |

### Goal

Text committed by the macOS input method, including Japanese conversion, reaches Android text fields in the focused app window. The candidate window sits next to the Android cursor, the edit shortcuts work, and password fields turn on secure input.

### Scope

- The guest IME `ApkRunInputMethodService` ([../../02-design/guest-components.md](../../02-design/guest-components.md) §7): `method.xml` with one ASCII-capable keyboard subtype and no locale, an empty zero-height input view, `ImeState{editor_focused}` from `onStartInput` and `onFinishInput`, and cursor updates turned into `cursor_rect_px` in display coordinates.
- Selecting it as the default IME with `WRITE_SECURE_SETTINGS`, and the display IME policy `LOCAL` on pool displays (§5.6).
- The development channel `@apkrun-guest-ime` over an ADB forward, with a `SO_PEERCRED` check that accepts only the shell uid (§5.6). On the custom image (M5) the IME shares the agent's process and the input stream (port 6101).
- `NSTextInputClient` in `IOSurfaceLayerView` with the table of §5.3, `TextInputModel`, and the switch between editor mode and key mode driven by `imeStateChanged(EditorState)` (§5.1).
- The editor commands of §5.4 (`deleteBackward:` → DEL, `insertNewline:` → the editor action or ENTER, `cancelOperation:` → BACK). An unmapped command logs `input.ime.unmappedCommand`.
- The paste policy of §6 (⌘V pushes with an acknowledgment when the clipboard integration is on, else it commits the text), and the shortcuts ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z (FR-IN-08).
- Secure input for password fields (§5.5): `EnableSecureEventInput` with a balanced counter, and `allowedInputSourceLocales` limited to Roman input sources.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - An on-screen keyboard in Android, and IME languages inside Android (the macOS input method does the language work).
  - Game controllers and other input devices (post-v1).

### Deliverables

- `ApkRunInputMethodService` and `res/xml/method.xml` in `Guest/guestd/`.
- `TextInputModel`, the editor commands, and the secure-input counter in InputCore. `NSTextInputClient` in WindowingCore's `IOSurfaceLayerView`.
- The IME messages in GuestProtocol, if #033 left any unimplemented.
- The fixture HelloCompose (`io.apkrun.fixture.hellocompose`) with a `TextField` and a password field, if it is not there yet.
- T0 `TextInputModelTests` and `EditorCommandTests`, T1 IME command mapping tests, and T2 `IMETests` in `Tests/IntegrationTests/InputTests/`.

### Implementation steps

1. **Guest IME** (§5.6, §12 #071 step 1; [../../02-design/guest-components.md](../../02-design/guest-components.md) §7).
   - Add `ApkRunInputMethodService` with `method.xml`, the empty view, `ImeState`, and the cursor rectangle. Take the editor's display from the IME window's display.
   - Select it as the default IME and set the `LOCAL` IME policy on pool displays.
   - Open the development channel `@apkrun-guest-ime` with the `SO_PEERCRED` check.
   - Check: T1 JVM tests with a fake `InputConnection`: every IME command maps to the right `InputConnection` call, and `ImeState` follows focus.
2. **Host text input** (§5.1, §5.3, §5.4, §12 #071 step 2).
   - Implement `NSTextInputClient` in `IOSurfaceLayerView` with `TextInputModel` for marked text, commits, and the selection.
   - Switch between editor mode and key mode on `imeStateChanged(EditorState)`, and map the editor commands of §5.4.
   - Check: T0 `TextInputModelTests` (marked text, replacement ranges, commit) and `EditorCommandTests` (every mapped command, and the log line for an unmapped one).
3. **Paste policy and secure input** (§5.5, §6, §12 #071 step 3).
   - Apply the paste policy of §6. Turn on secure input when a password field has focus, with the Roman input source limit and a balanced counter.
   - Check: a T0 test shows that the secure-input counter is balanced after focus changes, window closes, and session ends.
4. **Acceptance** (§12 #071 step 4).
   - Run `IMETests` and checklist C02-2.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.5):

- **T0** (`Packages/InputCore/Tests/InputCoreTests/`, `Packages/WindowingCore/Tests/WindowingCoreTests/`): `TextInputModel`; the editor commands; the secure-input balance.
- **T1** (`Guest/guestd` JVM tests): IME command mapping with a fake `InputConnection`.
- **T2** (`Tests/IntegrationTests/InputTests/`, AndroidStock suite, stock image): "にほんご" converts to "日本語" in HelloText and in a HelloCompose `TextField`; emoji; ⌘V; secure input in a password field (`IsSecureEventInputEnabled`) with a Roman input source; typing in the focused window when two apps are open on two displays.
- **T3**: checklist C02-2 of [../test-strategy.md](../test-strategy.md) §8.3.

### Acceptance criteria

- [ ] With the macOS Japanese input method, typing "にほんご" and converting gives "日本語" in HelloText's field and in a HelloCompose `TextField` (FR-IN-07).
- [ ] The candidate window is next to the Android cursor (FR-IN-07).
- [ ] Emoji from the character viewer are inserted (FR-IN-07).
- [ ] ⌘V pastes Mac text, and ⌘C, ⌘X, ⌘A, and ⌘Z do the equivalent Android actions (FR-IN-08).
- [ ] In a password field, secure input is on (checked with `IsSecureEventInputEnabled` in the UI test), the input source is Roman, and secure input is off again after the field loses focus (FR-IN-07, §5.5).
- [ ] With two apps on two displays, typing and conversion go only to the key window's app, and the IME binds to the editor on that display (R-05).

### Notes

- In development mode the IME channel and the input stream are separate ADB forwards, so their relative order is not guaranteed (§5.6). This is accepted for M4. On the custom image both share port 6101.
- Record in [../../02-design/input.md](../../02-design/input.md) §15: the IME result (conversion, candidate position, emoji, dictation, secure input) and the two-window routing (R-05). Record the `LOCAL` IME policy result in [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §11.
- Dictation is checked too and recorded (input §14). A failure is filed as a follow-up and does not block this task.
