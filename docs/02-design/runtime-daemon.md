# Runtime Daemon Design (apkrund, RuntimeHost, RuntimeSupervisor)

| Field | Value |
|---|---|
| Status | Baseline |
| Tasks | #031, #032, #066, #069. Hooks for #059 (health), #070 (perf markers), #085 (time sync) |
| Related | [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md), [../01-architecture/state-machines.md](../01-architecture/state-machines.md), [vm.md](vm.md), [android-image.md](android-image.md), [runtime-maintenance.md](runtime-maintenance.md), [guest-protocol.md](guest-protocol.md), [display-and-windowing.md](display-and-windowing.md), [diagnostics.md](diagnostics.md), [../03-reference/runtime-api.md](../03-reference/runtime-api.md), [../03-reference/configuration.md](../03-reference/configuration.md) |

This document covers the daemon process `apkrund` and the parts of RuntimeCore that keep Android alive: the process lifecycle, the startup and recovery order, `RuntimeSupervisor` (boot, readiness, stop, failure), guest agent supervision, the idle policy, host sleep and wake, `SessionRegistry`, the XPC server, and first-run provisioning. The process table, launchd registration, and the broker authentication scheme are defined in [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md). They are not repeated here.

---

## 1. Responsibilities

This section lists what apkrund coordinates. The table shows who implements each item. apkrund itself is only the composition root.

| Item | Implemented by | Design |
|---|---|---|
| VM lifecycle | `VMController` (VirtualMachineCore), driven by `RuntimeSupervisor` | [vm.md](vm.md), §3 |
| Android readiness | `RuntimeSupervisor`, `BootPhaseDetector` (RuntimeCore) | §3 |
| Application lifecycle | `SessionRegistry` (RuntimeCore) + Guest Agent | §7, [display-and-windowing.md](display-and-windowing.md) |
| Display allocation | `DisplayPool` (RuntimeCore) | [display-and-windowing.md](display-and-windowing.md) §3 |
| Window lifecycle | the wrapper owns the window (ADR-0006). apkrund sends `windowRequest` events | [display-and-windowing.md](display-and-windowing.md) §7 |
| Package install/update | APKStoreCore, UpdateCore | [package-store.md](package-store.md), [update-system.md](update-system.md) |
| Update scheduling | `UpdateScheduler` (UpdateCore) | [update-system.md](update-system.md) §3 |
| Guest communication | `GuestAgentSupervisor`, `StoreAgentSupervisor` (RuntimeCore) | §4, [guest-protocol.md](guest-protocol.md) §13 |
| macOS integration | IntegrationCore | [desktop-integration.md](desktop-integration.md) |
| Diagnostics | DiagnosticsCore | [diagnostics.md](diagnostics.md) |

apkrund does **not** render UI, own windows, or accept input from anything but XPC clients. It has no NSApplication. It links AppKit only for `NSWorkspace`, through one adapter in RuntimeHost (`WorkspaceOpener`): `NSWorkspace.openApplication(at:configuration:)` to open a wrapper (§7.2), and `NSWorkspace.open(_:)` to open a forwarded link in the default browser or mail app ([desktop-integration.md](desktop-integration.md) §7.2).

---

## 2. Process lifecycle

### 2.1 What starts apkrund

| Trigger | Mechanism | What apkrund does after startup (§2.2) |
|---|---|---|
| A client connects to `io.apkrun.apkrund.xpc` | launchd on-demand launch through `MachServices` | serve the request |
| User login | `RunAtLoad` | apply `runtime.startPolicy` (§5.4). With the default `onDemand` and nothing to do, it exits after the exit grace period (§2.4) |
| Periodic wake | `StartInterval` 3600 s (launchd starts the job if it is not running) | `UpdateScheduler` runs any check that is due ([update-system.md](update-system.md) §3), then the process exits after the grace period. It never boots the VM for a check. The only boot for updates is the opt-in `updates.startRuntimeToInstall` ([update-system.md](update-system.md) §3.5) |
| Crash | `KeepAlive.SuccessfulExit = false` | crash recovery (§2.5) |

launchd job keys added to the plist in [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.1:

| Key | Value | Why |
|---|---|---|
| `RunAtLoad` | `true` | preboot at login and startup recovery of interrupted package transactions happen without a client |
| `StartInterval` | `3600` | update checks while no APKRun process runs (FR-UPD, NFR-PERF-07). The job exits again when there is nothing to do |
| `ExitTimeOut` | `45` | launchd waits this long after `SIGTERM` (logout, shutdown, `unregister()`) before `SIGKILL`. A graceful Android shutdown needs up to 40 s (§3.5) |

### 2.2 Startup sequence (`RuntimeHost.start()`)

The order is fixed. Each step logs `host.startup.<step>` with its duration. Target: the XPC listener is resumed within 300 ms of process start when no recovery work is pending (measured in #031, logged as `DAEMON_READY`).

| # | Step | Module | Fatal on failure? |
|---|---|---|---|
| 1 | Resolve `APKRunPaths`, bootstrap logging, install `SIGTERM` handler (§2.4) | DiagnosticsCore | yes (exit 70) |
| 2 | Acquire the instance lock (§2.3) | RuntimeHost | yes: another owner runs. Exit 0 if the owner is another apkrund, otherwise serve the broker with `RuntimeFailure.instanceLocked` |
| 3 | Read `Runtime/daemon.json`; detect an unclean previous exit (§2.5); write the new `running` record | RuntimeHost | no |
| 4 | Load `settings.json` and `state.json`, migrating older schemas forward. A newer schema than this binary understands → host startup failure. Then `MaintenanceService.start()`: read `Runtime/maintenance.json` and apply its startup rules (the host state may become `updating`), and start `BundleWatcher` ([runtime-maintenance.md](runtime-maintenance.md) §3.6, §5) | DiagnosticsCore, RuntimeHost | degraded (see below) |
| 5 | `ImageStore.open()`: delete `Images/.installing-*`, resolve `current`/`previous`, recover an interrupted migration ([android-image.md](android-image.md) §12.3) | ImageCore | degraded |
| 6 | `PackageStore.open()`: replay `Packages/journal.jsonl`. Steps that need the guest are queued as post-boot work (§3.4) ([package-store.md](package-store.md) §5) | APKStoreCore | degraded |
| 7 | Load `Wrappers/registry.json` | WrapperCore | degraded |
| 8 | Construct RuntimeCore: `RuntimeSupervisor` (state `stopped`), `DisplayPool`, `SessionRegistry`, `InputRouter`, agent supervisors | RuntimeCore | yes |
| 9 | Construct `UpdateScheduler` (timers only), IntegrationCore, `ImageUpdateCoordinator` (reconciles its phase with `RuntimeImageState`), and `SelfUpdateProbe`. When `state.json.lastRuntimeBuild` is lower than this build, queue the post-update tasks ([runtime-maintenance.md](runtime-maintenance.md) §3.8, §4.3) | UpdateCore, IntegrationCore, RuntimeHost | degraded |
| 10 | Register the power observer (§6), the memory pressure source (§5.5), and the `IdleController` (§5) | RuntimeCore | no |
| 11 | Resume the XPC listener (§8) | RuntimeHost | yes |
| 12 | Apply `runtime.startPolicy` (§5.4). Skipped while the host state is not `normal` | RuntimeCore | no |

"Degraded" means: apkrund keeps running and serves the broker, but `runtimeStatus` returns `RuntimeFailure.hostStartupFailed(step:)`, and operations that need the failed component return the same error. The GUI and `apkrun doctor` show it with the remediation from the error catalog. apkrund never crash-loops because of bad data on disk.

### 2.3 Instance lock

- `Runtime/instance.lock`, taken with `flock(LOCK_EX | LOCK_NB)` for the process lifetime. The file contains the owner (`apkrund` or `apkrun-dev`), PID, and binary path, for error messages only.
- The embedded mode (`apkrun dev …`, §10) takes the same lock. This is how "`apkrun dev` refuses to run while apkrund owns the user's runtime instance" ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.2) is enforced. `apkrun dev` with `APKRUN_HOME` pointing at another root uses a different lock and may run next to apkrund. It prints a memory warning.
- `flock` locks are released by the kernel when the process dies, so a crash never leaves a stale lock.

### 2.4 Exit rules

apkrund exits with status 0 when **all** of these hold for 2 minutes (the exit grace period):

- `RuntimeState == stopped`
- no XPC connections (GUI, menu bar, CLI, wrappers)
- no `RuntimeActivityAssertion` (§5.1) and no operation in flight
- `UpdateScheduler` has no work due within the grace period, and no image feed check, self-update probe, or image download is in flight or due ([runtime-maintenance.md](runtime-maintenance.md) §3.4, §4.2, §4.4)

Two maintenance exits skip the grace period ([runtime-maintenance.md](runtime-maintenance.md) §3.5, §3.6): after `prepareForHostUpdate` has replied, apkrund exits 0 one second later. In `restartPending`, apkrund stops Android and exits 0 as soon as no session, background task, or operation is left.

Exit status 0 is not restarted by launchd. The next client connection, the next login, or the next `StartInterval` starts apkrund again.

`SIGTERM` (logout, system shutdown, `SMAppService.unregister()`, `launchctl bootout`):

1. Stop accepting new XPC requests. Pending replies get `RuntimeFailure.hostShuttingDown`.
2. `RuntimeSupervisor.stop(reason: .hostShutdown)` with a 40 s deadline (§3.5). Sessions end with `.runtimeStopped`. Wrappers show nothing new: during logout they are quitting too.
3. Flush logs, write `daemon.json` with `cleanExit = true`, exit 0.

If the deadline passes, the VM is force-stopped (`VMController.stop()`), which is still better than launchd's `SIGKILL` at 45 s: userdata is written through the host page cache, so a forced VM stop loses only data Android had not yet flushed.

### 2.5 Unclean exit and crash recovery (NFR-REL-02)

`Runtime/daemon.json`:

```json
{
  "schemaVersion": 1,
  "pid": 4711,
  "startedAt": "2026-09-28T09:12:03Z",
  "version": "0.2.0 (200)",
  "cleanExit": false,
  "recentUncleanExits": ["2026-09-28T08:55:10Z"],
  "bootHistory": [ { "imageVersion": "2026.10.0-cf16373615-arm64", "kind": "cold", "phasesMs": { "kernel": 900, "init": 3100, "systemServer": 9800, "bootCompleted": 21500, "agentsConnecting": 23900 } } ]
}
```

On startup, `cleanExit == false` with a PID that is not running means the previous apkrund crashed or was killed:

- Log `host.previousExitUnclean` (fault level) and append the time to `recentUncleanExits` (last 10 kept).
- Record the newest `~/Library/Logs/DiagnosticReports/apkrund-*.ips` path in the diagnostics index, so `apkrun diagnostics` includes it ([diagnostics.md](diagnostics.md)).
- The VM died with the process (the Virtualization.framework helper processes exit with their owner). Nothing of the VM needs cleanup. Android repairs userdata on the next boot (f2fs checkpoint and fsck) like after a power loss.
- Remove stale ADB forwards (`localabstract:apkrun-*`, [guest-protocol.md](guest-protocol.md) §13.2) and run `adb disconnect 127.0.0.1:6520` in development builds.
- Steps 5 and 6 of §2.2 recover image migrations and package transactions.
- 3 unclean exits within 10 minutes: health `apkrund.crashLoop = failing`. apkrund keeps serving the broker but refuses automatic boots (§3.6) until the user starts the runtime explicitly (GUI "Start Android", `apkrun runtime start`). This stops a crash in, for example, the renderer from turning into a boot/crash loop driven by wrapper retries.

The client side of a crash is in [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.5: wrappers reconnect with backoff and go through a cold launch.

### 2.6 Development builds and debugging

- Debug builds use separate identities, so a development build never replaces an installed release: bundle IDs get the suffix `.dev` (`io.apkrun.APKRun.dev`), the LaunchAgent label and Mach service become `io.apkrun.apkrund.dev` and `io.apkrun.apkrund.dev.xpc`, and `APKRUN_HOME` defaults to `~/Library/Application Support/APKRun-Dev/`. RuntimeClient picks the service name from the build configuration ([../05-development/build-system.md](../05-development/build-system.md)).
- `scripts/dev/install-dev-app.sh` copies the built app to `~/Applications/APKRun Dev.app` and re-registers the agent (`APKRun --register-runtime`). Registering from DerivedData works too, but every clean build moves the path.
- Debugging the daemon: Xcode scheme "apkrund (attach)" uses "Wait for the executable to be launched". Then `launchctl kickstart -k gui/$(id -u)/io.apkrun.apkrund.dev` restarts it under the debugger.
- `launchctl print gui/$(id -u)/io.apkrun.apkrund.dev` shows the job state, last exit status, and PID. `apkrun doctor` reports the same data through `SMAppService.status` and `daemon.json`.

---

## 3. RuntimeSupervisor

### 3.1 API

```swift
public actor RuntimeSupervisor {
    public var state: RuntimeState { get }
    public nonisolated var events: AsyncStream<RuntimeEvent> { get }

    /// Starts the VM if stopped, resumes it if suspended, and waits until `ready`.
    /// Concurrent callers join the same boot (single flight).
    public func ensureReady(_ reason: StartReason, operation: OperationID) async throws -> ReadyRuntime

    public func stop(_ reason: StopReason, force: Bool, operation: OperationID) async throws
    public func restart(_ reason: StopReason, operation: OperationID) async throws
    public func reset(operation: OperationID) async throws            // failed → stopped (vm.md §9.6)

    /// Image migration A → B: stop, recovery point, boot B, health check, restore A on failure
    /// (android-image.md §12.3, orchestration in runtime-maintenance.md §4.7).
    public func migrateImage(to version: ImageVersion, operation: OperationID) async throws -> ImageMigrationResult

    public func beginActivity(_ kind: ActivityKind, owner: String) -> RuntimeActivityAssertion   // §5.1
}

public enum StartReason: Sendable { case session(PackageID), store, update, cli, user, preboot, diagnostics, migration, provisioning }   // user: APKRun.app or the menu bar
public enum StopReason: Sendable { case user, idle, hostShutdown, hostUpdate, migration, reset, failure }

/// Handed out only while `ready`. Every accessor throws `guestAgentUnavailable` during a reconnect (§4.3).
public struct ReadyRuntime: Sendable {
    public let displays: any DisplayControlChannel
    public let android: any AndroidControlChannel
    public let store: any StoreAgentChannel
    public let integration: any IntegrationChannel
}
```

`RuntimeState` and its transitions are normative in [state-machines.md](../01-architecture/state-machines.md) §2.

- `ensureReady` in `stopped` starts a boot. In `booting` it waits. In `suspended` it resumes (§5.3). In `stopping` it waits for `stopped`, then boots. `failed` lasts only while the diagnostics snapshot is captured (§3.6). A caller arriving then waits for `stopped` and boots, subject to the boot-loop guard.
- Cancelling the waiting task does not cancel the boot. A boot that nobody waits for completes, and the idle policy takes over.
- `ensureReady` with `StartReason.session` is refused while the boot-loop guard is active (§3.6). Explicit starts (`cli`, and `user` for a start from APKRun.app or the menu bar) clear the guard.

### 3.2 Boot sequence (cold start)

```text
ensureReady(reason)
  0. guard: provisioned (§9; skipped for reason .provisioning), not boot-loop-blocked (§3.6); take activity assertion .boot
  1. state: stopped → booting(.kernel)
  2. ImageCore: pre-boot checks and per-boot initrd (android-image.md §9.3)
  3. GraphicsCore: create the virtio-gpu device model and the renderer thread; apply graphics.safeMode (graphics.md §9)
  4. VirtualMachineCore: VMController.start(definition)           PerfMarker VM_START
  5. attach ConsoleLogWriter → BootPhaseDetector (§3.3)
  6. start the ADB bridge: guest vsock 5555 ↔ 127.0.0.1:6520 (#015; connects succeed once adbd listens)
  7. agents (§4): development → after .bootCompleted, GuestAgentProvisioner installs/starts guestd over ADB
                  custom image → connect attempts start at .systemServer (persistent apps start before boot completes)
  8. booting(.agentsConnecting) → all required agents accepted (guest-protocol.md §5)   PerfMarker AGENT_CONNECTED (per agent)
  9. post-boot setup (§3.4)
 10. state: → ready                                               PerfMarker RUNTIME_READY
     resume all ensureReady waiters; release assertion .boot; IdleController starts counting (§5)
```

Timeouts:

| Timeout | Default | Setting | Result |
|---|---|---|---|
| Whole boot, normal | 180 s | `runtime.bootTimeoutSeconds` | `failed(.bootTimedOut(phase))` |
| Whole boot, first boot of an instance or of a new image | 900 s | `runtime.firstBootTimeoutSeconds` | same. Android formats userdata and runs dexopt ([android-image.md](android-image.md) §5.2, §12.3) |
| No phase progress (stall) | 90 s (first boot: 600 s) | — | `failed(.bootStalled(phase))` |
| Required agent handshake after `.bootCompleted` | 30 s | — | `failed(.requiredAgentUnavailable(agent))` |

Immediate failures during boot: the console shows `Kernel panic - not syncing` (`failed(.kernelPanic)`), the console shows `VIRTUAL_DEVICE_BOOT_FAILED` (`failed(.androidBootFailed)`), `VMState → failed` (`failed(.vm(…))`), or GraphicsCore reports `rendererInitFailed` (`failed(.graphics(…))`).

### 3.3 BootPhaseDetector

`BootPhaseDetector` consumes console lines (from `ConsoleLogWriter`, which already splits lines) and readiness signals from ADB or the agents. It emits phase changes. Phases are monotonic: a phase may be skipped when its signal is not observable, but never re-entered.

| Phase entered | Signal (console, every image) | Signal (ADB, development) | Signal (agent) | Perf marker |
|---|---|---|---|---|
| `.kernel` | first console byte after `VM_START` (Linux prints `Booting Linux on physical CPU` first) | — | — | `KERNEL_START` |
| `.init` | `init: init first stage started!` (first-stage init) | — | — | `ANDROID_INIT` |
| `.systemServer` | `init: starting service 'zygote'` (visibility of init's kmsg lines depends on the console log level) | `getprop sys.system_server.start_count` non-empty (polled every 500 ms once `adb` connects) | — | `SYSTEM_SERVER_READY` |
| `.bootCompleted` | `VIRTUAL_DEVICE_BOOT_COMPLETED` | `getprop sys.boot_completed` = `1` | `Hello.android` / `SystemState.boot_completed` ([guest-protocol.md](guest-protocol.md) §7.2) | `BOOT_COMPLETED` |
| `.agentsConnecting` | — | — | entered right after `.bootCompleted` | — |

- The console strings are candidates. #064 records the exact strings and their timing from the reference boot ([android-image.md](android-image.md) §7.7, §8). The detector's patterns live in one table (`BootSignals.swift`), with golden tests over the captured console logs.
- The first signal that arrives wins. For example, on the custom image with `adbd` stopped, `.bootCompleted` comes from the console marker or from the Guest Agent.
- Progress for the placeholder window: `BootProgressEstimator` divides elapsed time by the median duration of each phase over the last 5 boots of the same kind (`daemon.json bootHistory`). Without history it uses fixed weights. Progress is never shown as a percentage above 95 % before `ready`.

### 3.4 Readiness and post-boot setup

`ready` means all of the following. Nothing else gates it.

1. `VMState == running`, and `.bootCompleted` was seen.
2. Every **required** agent completed the handshake with an accepted protocol version. Development (stock image): the Guest Agent. Custom image: the Guest Agent and the Store Agent. The development IME channel is not required: it connects when Android binds the IME ([input.md](input.md) §5.6).
3. `GetSnapshot` returned, and `DisplayPool` reconciled with it: every secondary display known to Android that has no lease is cleared and its scanout disabled ([display-and-windowing.md](display-and-windowing.md) §3).
4. Host-owned configuration was pushed (§4.2): display policies, developer mode, locale and time zone, time sync ([desktop-integration.md](desktop-integration.md) §9), integration settings.
5. Post-boot work queued at startup ran, or was re-queued with a reason. For example, a package transaction that needs the Store Agent to finish ([package-store.md](package-store.md) §5). Post-boot work never blocks `ready` for longer than 5 s. Longer work runs after `ready`, under an activity assertion.

### 3.5 Stop sequence

```text
stop(reason, force)
  0. refuse with RuntimeFailure.busy(activities) if assertions other than .backgroundTask are held
     and force == false (the GUI asks "Android is installing ‹App›. Stop anyway?")
  1. state: → stopping(reason); new ensureReady callers wait (§3.1)
  2. SessionRegistry.endAll(.runtimeStopped): wrappers receive stateChanged(.ended) and close
     (reasons .hostUpdate and .migration end them with .runtimeUpdating instead: the wrapper shows screen U
     and reopens, runtime-maintenance.md §3.5, §4.7)
  3. suspended? → VMController.resume() first (Android can only shut down while running)
  4. Guest Agent Shutdown (20 s, guest-protocol.md §7.1) → Android runs its shutdown sequence
  5. wait for guestDidStop (20 s total from step 4)
  6. fallback: VMController.requestStop() (power button, vm.md §9.3), then after 20 s VMController.stop()
  7. GraphicsCore WillStop; close agent connections; stop the ADB bridge
  8. state: → stopped
```

- With `reason == .hostShutdown` the whole sequence has a 40 s deadline (§2.4). Step 6 then goes straight to `stop()` when the deadline is near.
- Without a Guest Agent (it is unreachable), step 4 is skipped.
- Every stop logs the path it took (`graceful`, `powerButton`, `forced`) and its duration. `apkrun doctor` warns when the last 3 stops were forced.

### 3.6 Failure handling and automatic restart

When the supervisor enters `failed(f)`:

1. Capture a diagnostics snapshot into `~/Library/Logs/APKRun/crash/<timestamp>-runtime/`: the console tail (last 2 MiB), the last 200 `BootPhaseDetector` events, agent health, GraphicsCore statistics, and `logcat -d` if ADB is still reachable (5 s limit) ([diagnostics.md](diagnostics.md) §8).
2. `VMController.stop()` if the VM still runs, then `reset()`. The state becomes `stopped` (state-machines.md §2: "automatic after diagnostics capture").
3. Sessions have already ended with `.error(f)` or `.runtimeStopped`.

Automatic restart (`runtime.autoRestart`, default `true`): if at least one session was `running` when the failure happened, the supervisor performs **one** cold boot and the affected wrappers retry `openSession` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.5). A second failure within 10 minutes is not retried. The wrapper shows "Android stopped unexpectedly" with **Restart**, **Troubleshooting…**, and **Report…**.

Boot-loop guard: 3 runtime failures (or unclean apkrund exits, §2.5) within 10 minutes set `bootLoopBlocked`. While it is set, `ensureReady(.session)` throws `RuntimeFailure.bootLoop`, and the GUI offers Restart, graphics safe mode ([graphics.md](graphics.md) §9), and "Reset Android" (§9.5). An explicit start clears the guard.

`GraphicsFailure.rendererLost` while `ready` is handled as a failure with automatic restart ([graphics.md](graphics.md) §8).

---

## 4. Guest agent supervision

### 4.1 Connection state

Each agent supervisor ([guest-protocol.md](guest-protocol.md) §13.1) has its own state, reported as health and in `runtimeStatus`:

```swift
enum AgentConnectionState: Sendable, Equatable {
    case notStarted           // before the boot phase where the agent can exist
    case connecting(attempt: Int)
    case connected(GuestHello)
    case reconnecting(since: ContinuousClock.Instant, attempt: Int)
    case incompatible(ProtocolVersion)   // handshake rejected (major mismatch); no retries
    case paused               // VM suspended: no pings, no timeouts (§5.6)
}
```

- `connecting` and `reconnecting` retry with backoff from 100 ms doubling to 2 s ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).
- `incompatible` fails the boot with `RuntimeFailure.agentIncompatible` (NFR-REL-04). The remediation depends on the side: "Update APKRun" when the guest is newer, "Update Android" when the host is newer.
- In development mode the supervisor also restarts the agent process through `GuestAgentProvisioner` ([guest-components.md](guest-components.md) §3.3). On the custom image Android restarts the persistent app by itself.

### 4.2 Reconnect and reconciliation

Rule: **the host is the source of truth for configuration, the guest for Android state.** After every handshake (first connect and reconnect):

1. `GetSnapshot` ([guest-protocol.md](guest-protocol.md) §6). The supervisor replaces its view of displays, tasks, focus, and packages.
2. Push host-owned configuration again: `SetDisplayPolicy` for every leased display, `FocusDisplay` for the focused session, notification forwarding and URL redirect settings, `SetLocale`/`SetTimeZone`. A reconnect after an agent crash therefore restores the agent's settings without the sessions noticing.
3. Reconcile sessions (`SessionRegistry`):

| Snapshot shows | Session state before | Action |
|---|---|---|
| display present, the session's tasks present | running, backgrounded | continue |
| display present, no tasks of the package | running, backgrounded | end with `.appExited` (the app finished during the disconnect) |
| display present, no tasks | launching | send `LaunchApplication` again (it is idempotent: `BROUGHT_TO_FRONT` if it had started) |
| display missing | any | end with `.error(.displayLost)` and release the lease (the scanout is reset) |

4. Send `InputEvent.cancelAll` to every leased display, so no touch stays down across the gap ([input.md](input.md) §7).

### 4.3 Operations during a disconnect

- Frames keep flowing. The graphics path does not depend on the agent.
- Input is dropped and counted (`input.droppedWhileDisconnected`). Text events are dropped too. The wrapper shows no error for gaps shorter than 2 s.
- Requests that need the agent wait for the reconnect up to 5 s, then throw `RuntimeFailure.guestAgentUnavailable` ([display-and-windowing.md](display-and-windowing.md) §10).
- A required agent that stays unreachable for more than 30 s while `ready` moves the runtime to `failed(.requiredAgentUnavailable(agent))` (§3.6).
- Hung guest watchdog: the agent misses pings, ADB is unreachable, and the console is silent, all for 60 s while `ready` → `failed(.guestUnresponsive)`.

---

## 5. Idle policy (#069)

`IdleController` (RuntimeCore, actor) decides when to suspend (VM paused) and when to stop the runtime. It implements FR-VM-10 and is the only component that calls `VMController.pause()` outside host sleep (§6). [vm.md](vm.md) and [graphics.md](graphics.md) §8 reference this section.

### 5.1 Activity

The runtime is **active** while any of these exist. Idle time counts only while none exists.

| Source | How it is tracked |
|---|---|
| An app session in any state except `ended` (`backgrounded` counts) | `SessionRegistry` |
| A task kept alive by `window.closeBehavior = keepRunning` ([display-and-windowing.md](display-and-windowing.md) §7.6) | `ActivityKind.backgroundTask`, held until the task vanishes or the package is terminated |
| Store operations: install, uninstall, gentle update install, icon rendering, metadata refresh | `ActivityKind.storeOperation`, held by APKStoreCore for the operation |
| Diagnostics collection, image migration, first-run provisioning | `.diagnostics`, `.migration`, `.provisioning` |
| An ADB client connected through the bridge (developer mode) | `.adbClient`, held by the ADB bridge while a TCP connection to 127.0.0.1:6520 is open |
| `apkrun runtime start --hold` (keeps the runtime ready until the CLI exits or is interrupted) | `.cli` |

```swift
public struct ActivityKind: RawRepresentable, Sendable, Hashable {   // "storeOperation", "backgroundTask", …
    public let rawValue: String
}

/// Released by release() or on deinit. Holding one keeps the runtime `ready` (it resumes it if needed)
/// and resets the idle timers when released.
public final class RuntimeActivityAssertion: Sendable {
    public let kind: ActivityKind
    public func release()
}
```

Not activity: open GUI, menu bar, or CLI connections that only observe; update checks and downloads (UpdateCore works while the runtime is stopped; installs take a `storeOperation` assertion when they run).

Consequence: an Android app closed with `stop` receives no notifications while the runtime is suspended. Messaging and music apps need `keepRunning`. The Settings UI says so next to the option.

### 5.2 Timers and settings

| Setting | Default | Meaning |
|---|---|---|
| `runtime.idleSuspendMinutes` | 10 | idle time until `ready → suspended`. `0` = never suspend |
| `runtime.idleStopMinutes` | 60 | idle time (counted from when idleness began, including suspended time) until the runtime stops. `0` = never stop |
| `runtime.startPolicy` | `onDemand` | `onDemand` or `atLogin` (§5.4) |

- Idle time is measured with `SuspendingClock`, which does not advance while the Mac sleeps. A lid closed overnight does not count as 8 hours of idleness.
- `idleStopMinutes` below `idleSuspendMinutes` is treated as "stop without suspending first".
- Settings changes apply immediately: the controller recomputes its deadline.

### 5.3 Suspend and resume

```text
suspend (ready, idle ≥ idleSuspendMinutes)
  1. agent supervisors → paused (stop pings and request timeouts; §4.1)
  2. VMController.pause()          → GraphicsCore WillPause (graphics.md §8)     PerfMarker VM_PAUSED
  3. state: ready → suspended

resume (suspended, ensureReady or an activity assertion)
  1. VMController.resume()         → GraphicsCore WillResume                      PerfMarker VM_RESUMED
  2. agent supervisors: Ping each required agent (2 s); on failure → reconnect path (§4)
  3. time sync: SyncTime with the host wall clock (desktop-integration.md §9)
  4. state: suspended → ready
```

- Resume target: `VM_RESUMED` → `ready` p50 ≤ 500 ms, so a launch from `suspended` stays within NFR-PERF-01 plus 0.5 s. #070 measures it.
- A pause or resume error from VZ moves the runtime to `failed(.vm(.pauseFailed/.resumeFailed))` (§3.6).
- The memory balloon is not inflated before a pause in v1. Whether reclaiming guest free memory before suspending is worth the slower next launch (Android's lmkd kills cached processes) is measured in #069/#070 and recorded in [../04-plan/open-questions.md](../04-plan/open-questions.md).

### 5.4 Preboot (`runtime.startPolicy`)

- `onDemand` (default): the runtime boots on the first request that needs Android.
- `atLogin`: when apkrund starts at login (§2.1), it calls `ensureReady(.preboot)`, with a 60 s delay after login so that it does not compete with other login items. After `ready` the normal idle rules apply. The first app launch is then warm (runtime `ready`) or a resume (runtime `suspended`), instead of a cold boot.
- Preboot is skipped on battery power when the battery is below 30 % (`IOPSCopyPowerSourcesInfo`), and during `bootLoopBlocked`.

### 5.5 Host memory pressure

`DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`:

- `.critical` while the runtime is `ready` and no session is visible (every session `backgrounded`, or none) → suspend at once, without waiting for the idle timer. `backgroundTask` assertions prevent this, because suspending would stop the audio the user chose to keep.
- `.warning` → log and health `runtime.memoryPressure = warning`. No action.

### 5.6 CPU budget while suspended (NFR-PERF-06)

While `suspended`, apkrund must stay below 1 % CPU. Rules that make this true:

- No polling anywhere. Console reading blocks on the pipe. XPC, ADB bridge, and agent sockets are event driven.
- Agent pings and request timers stop (`paused`).
- GraphicsCore statistics timers stop (`WillPause`). No display link runs in apkrund.
- `IdleController` uses one one-shot timer for the next deadline. `UpdateScheduler` uses one one-shot timer with leeway ≥ 60 s.
- Acceptance (#069): `top -l 61 -s 1 -pid <apkrund>` with the runtime suspended and no clients connected. The average CPU of the last 60 samples is below 1 %.

---

## 6. Host sleep and wake (#069, FR-VM-11)

`PowerObserver` (RuntimeCore) registers with `IORegisterForSystemPower` and handles the messages on a dedicated serial queue. apkrund has no NSApplication, so it uses IOKit rather than `NSWorkspace` notifications ([vm.md](vm.md) §9.4).

| Message | Action |
|---|---|
| `kIOMessageCanSystemSleep` (idle sleep request) | `IOAllowPowerChange`. APKRun never vetoes sleep |
| `kIOMessageSystemWillSleep` | if the VM is running: record `resumeAfterWake = true`, suspend (§5.3 steps 1–2) without changing the idle timers, then `IOAllowPowerChange`. The pause must finish within 5 s. If it does not, acknowledge anyway and log `power.pauseLate`. macOS waits at most 30 s for the acknowledgement |
| `kIOMessageSystemWillNotSleep` | undo: resume if this handler paused the VM |
| `kIOMessageSystemHasPoweredOn` | if `resumeAfterWake`: resume (§5.3), including the time sync. The runtime state returns to what it was before sleep (`ready`) |

- A VM already `suspended` by the idle policy stays suspended across sleep and wake.
- Sleep while booting: the boot is paused with the VM. The boot timeouts use `SuspendingClock` too, so sleep does not cause `bootTimedOut`.
- Sessions stay open across sleep. The wrapper keeps showing the last frame ([graphics.md](graphics.md) §8).
- Dark wakes (Power Nap, maintenance) also deliver `kIOMessageSystemHasPoweredOn`. v1 resumes on every wake. If #069 measures pause/resume churn during dark wakes, the fallback is to resume lazily on the first request or `visibilityChanged(true)` ([../04-plan/open-questions.md](../04-plan/open-questions.md)).
- Time sync after wake is required, because Android's wall clock does not advance while the VM is paused. Acceptance (#069): after `pmset sleepnow` and a wake 2 minutes later, the guest wall clock is within 2 s of the host within 5 s of wake (checked with `adb shell date +%s` in development builds).

---

## 7. Sessions (`SessionRegistry`)

`SessionRegistry` (RuntimeCore, actor) owns `AppSessionState` ([state-machines.md](../01-architecture/state-machines.md) §3) and the mapping session ↔ package ↔ client connection ↔ display lease ↔ Android task IDs. Display and window details are in [display-and-windowing.md](display-and-windowing.md).

The registry grows over several tasks. #026 builds a minimal registry for embedded sessions on display 0, in the CLI process. #028 moves sessions to `DisplayPool` leases, and #030 runs two sessions at once. #032 adds what this section needs from apkrund: client connections, authorization, takeover, and orphaned sessions (§7.1–§7.3).

### 7.1 `openSession`

```text
openSession(request, client)                              PerfMarker APP_LAUNCH_REQUEST
  1. authorize: wrapper endpoint → only its own package (NFR-SEC-07); control endpoint → any package
  2. existing live session for the package?
       same client  → return its descriptor
       other client → the new client takes over (the old one receives windowRequest(.close)); used by the generic launcher
       orphaned (§7.3) → re-attach: new surfaces, same display and tasks
  3. package installed (PackageStore)? else RuntimeFailure.packageNotInstalled
  4. state requested → waitingForRuntime; runtime.ensureReady(.session(pkg))   (cold boot or resume if needed)
  5. acquiringDisplay: DisplayPool.acquire(geometry)                            PerfMarker DISPLAY_ATTACHED
  6. launching: AndroidControlChannel.launch(package, display)                  PerfMarker ACTIVITY_STARTED
  7. running: first frame                                                         PerfMarker FIRST_FRAME
  (async, after reply) UpdateCore.noteLaunched(package)                          never on this path (NFR-PERF-07)
```

- The descriptor is returned at step 5 (surfaces exist). The client learns the rest through the session event `stateChanged` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §6.3). The wrapper shows the placeholder window until the first frame ([display-and-windowing.md](display-and-windowing.md) §7.3).
- A cold boot shows `booting(progress)` from §3.3 in the placeholder.
- A pending package transaction for the same package (for example a gentle update that started just before the click) is awaited up to 30 s in the phase `waitingForPackage`, with the placeholder text "Updating ‹App›…". The gentle update rules make this rare ([update-system.md](update-system.md)).

### 7.2 `launch` and `terminate` for control clients

Wrappers open sessions. Control clients (GUI, menu bar, CLI) do not own windows, so they call:

- `launch(packageID)`: apkrund resolves the window owner and opens it with `NSWorkspace.openApplication(at:configuration:)`:
  1. the registered wrapper for the package (`Wrappers/registry.json`), if its bundle still exists and its cdhash matches;
  2. otherwise the generic launcher `APKRun.app/Contents/Helpers/APKRunLauncher.app` with the arguments `--package <id>` (#068). It is signed with APKRun's identity and uses the `.control` endpoint.
  The launched process calls `openSession`. `launch` returns when that session reaches `running` (or fails), so `apkrun launch` can print the result and the first-frame time.
- `terminate(packageID)`: ends the session (the wrapper receives `windowRequest(.close)`), stops keep-running tasks, and sends `StopApplication` (force-stop) to the Guest Agent. The session ends with `.userClosed`.

#032's acceptance, "CLI launches HelloText through XPC without direct VM ownership", is tested with `apkrun launch io.apkrun.fixture.hellotext` (§13).

### 7.3 Client disconnects

- A wrapper connection that is invalidated without `closeSession` (the wrapper crashed or was killed) makes the session **orphaned** for 3 s. If a wrapper for the same package calls `openSession` within that time, it re-attaches (§7.1 step 2). Otherwise the session is closed with the package's `window.closeBehavior`.
- A control client that disconnects while waiting for `launch` changes nothing. The launched wrapper keeps its session.
- Subscriptions (§8.4) end with their connection.

### 7.4 Runtime stop and failure

`RuntimeState → stopping/stopped/failed` ends every session (`.runtimeStopped` or `.error(f)`). Queued sessions (`waitingForRuntime`) stay queued across a `stopping` (they wait for the next boot) but end with `.error(f)` on `failed`. Automatic restart (§3.6) lets the wrappers retry.

---

## 8. XPC server (#032)

### 8.1 Components

| Component | Serves | Notes |
|---|---|---|
| `XPCBrokerListener` | Mach service `io.apkrun.apkrund.xpc` | `hello`, `requestEndpoint`, `requestApproval` only ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2) |
| `ControlEndpoint` | anonymous listener with the APKRun signing requirement | full `RuntimeService` |
| `WrapperEndpoint(bundleID)` | one anonymous listener per registered wrapper, created lazily, with `identifier` + `cdhash` requirement | session API for its own package, `runtimeStatus` |
| `EventHub` | all endpoints | fan-out of `RuntimeEvent` topics to subscribers (§8.4) |
| `XPCRuntimeExporter` | — | adapts the `RuntimeService` Swift protocol to the `@objc` protocols of RuntimeAPI. The same `EmbeddedRuntimeService` instance serves XPC and embedded mode |

Wrapper endpoints are created when a wrapper asks for one and dropped 10 minutes after their last connection closes. Re-registration (new cdhash after re-approval) replaces the listener.

### 8.2 Request rules

1. Decode `APIRequestHeader` first. Major version mismatch → `RuntimeFailure.apiVersionMismatch`. Undecodable payload → `RuntimeFailure.malformedRequest` (logged with the client kind, never with the payload).
2. Authorize by endpoint kind, not by claims in the payload. A wrapper request for another package → `RuntimeFailure.notAuthorized` and a security log entry.
3. Hop from the XPC queue to the owning actor immediately. No work runs on the XPC queue.
4. Every reply is sent exactly once. `ReplyGuard` wraps the reply block: a second call asserts in debug, and a guard released without a reply answers `RuntimeFailure.internal`.
5. The operation ID from the header is attached to every log line and perf marker caused by the request (NFR-OBS-01).
6. Per-request timeouts are defined by the operation ([../03-reference/runtime-api.md](../03-reference/runtime-api.md)). Operations that can take long return early (§8.3).
7. Limits: 64 requests in flight per connection, and 8 control connections at once. Above that → `RuntimeFailure.busy`.

### 8.3 Long-running operations

Long-running operations return an `OperationHandle { operationID }` right away. `OperationKind` lists them ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §4.7): the store operations (`install`, `uninstall`, `update`, …), `setup`, `resetAndroid`, `runtimeStop`, `runtimeRestart`, the image operations, the wrapper operations, and `diagnostics`. Progress and the result arrive on the `operations` event topic. `cancel(operationID)` is best effort: each operation documents its cancellation points (for example, an install can be cancelled until `CommitInstall`).

Operations survive the client that started them. `apkrun install foo.apk` followed by Ctrl-C cancels (the CLI sends `cancel` on `SIGINT`). A dropped connection does not.

### 8.4 Events

- `subscribe(topics)` registers the client's exported `RuntimeEventSink` for the nine topics of [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §16.1: `runtime` (state, boot progress), `sessions`, `packages`, `updates`, `operations`, `health`, `maintenance` (host state, APKRun update status, Android system update phase; [runtime-maintenance.md](runtime-maintenance.md) §8.3), `wrappers`, and `integrations`. Health results go only to `health`. `unsubscribe(topics)` removes topics. Both are idempotent.
- Stream operations (`guestLog`, `notificationRelay`, `hostNotifications`) deliver their items to the same sink under a stream ID. `closeStream(streamID)` ends a stream and is idempotent ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §16.4).
- Session events for a wrapper (`frameReady`, `surfacesReplaced`, `imeStateChanged`, …) go only to the session's own connection, never through topics.
- Coalescing: for `runtime` boot progress, `operations` progress, and `health`, only the latest value per key is delivered, at most 10 per second per subscriber. State changes and results are never coalesced.
- A subscriber whose connection is invalidated is removed at once.

### 8.5 The CLI as a client

The CLI uses RuntimeClient like every other client. Its only special behavior: commands that need apkrund and find it unregistered (`SMAppService.status != .enabled`) print `APKRun's background service is not set up. Open APKRun once, or run: apkrun setup` and exit with status 69 (EX_UNAVAILABLE). The full command set is in [cli.md](cli.md).

### 8.6 Runtime, session, and stream operations

The request and reply types are in [../03-reference/runtime-api.md](../03-reference/runtime-api.md). These operations of the control and wrapper endpoints have no other design section:

| Operation | Behavior | Task |
|---|---|---|
| `startRuntime`, `stopRuntime`, `restartRuntime`, `resetRuntime` | the wire names of `ensureReady`, `stop`, `restart`, and `reset` (§3.1). `startRuntime` uses `.cli` for the CLI and `.user` for APKRun.app and the menu bar. `resetRuntime` clears `failed` and the boot-loop guard and deletes nothing (runtime-api.md §5.2) | #031 (`startRuntime`, `stopRuntime`), #032 (the others) |
| `runtimeInfo` | `apkrun info` without a package: versions, state, resource use, and the display pool size ([cli.md](cli.md) §4.1) | #032, #028 |
| `listSessions` | the open sessions (§7) with package, display, phase, and point size. Used by `apkrun status`, the menu bar, and **Use Current Size** | #032 |
| `restartApp` | a session channel request for Android → Restart ‹App› ([wrapper.md](wrapper.md) §5.6): `StopApplication`, then `LaunchApplication` on the same display. The session stays open | #044 |
| `listOperations` | the running operations and the last 50 finished ones (§8.3). Used by `apkrun operations list` | #032 |
| `unsubscribe`, `closeStream` | the counterparts of `subscribe` and of the stream operations (§8.4) | #032 |

---

## 9. First-run provisioning (#066)

### 9.1 Host requirements

`HostRequirementsCheck` (RuntimeHost) returns every failed requirement at once. It runs DiagnosticsCore's host checks (`host.appleSilicon`, `host.macOSVersion`, `host.hypervisor`, `host.dataVolume`, `host.memory`, [diagnostics.md](diagnostics.md) §7.3), which `apkrun doctor` also runs without apkrund, and adds the checks that need Virtualization.framework or the image size:

| Requirement | Check | Failure message (remediation) |
|---|---|---|
| Apple silicon | `sysctl hw.optional.arm64 == 1` and no Rosetta translation (`sysctl.proc_translated == 0`) | "APKRun needs a Mac with Apple silicon" |
| macOS 27 or later | `ProcessInfo.operatingSystemVersion` | "Update macOS" |
| Virtualization available | `VZVirtualMachine.isSupported` (false inside most VMs) | "Virtualization is not available on this Mac (APKRun can't run inside a virtual machine)" |
| APFS volume for the data root | `URLResourceValues.volumeSupportsFileCloning` on `APKRunPaths.root` | "Move APKRun's data to an APFS volume" ([android-image.md](android-image.md) §5.1) |
| Free disk | expanded image size + 4 GiB (initial userdata) + 10 GiB margin | "Free up ‹n› GB" |
| Memory | physical memory ≥ 8 GiB; the VM default is lowered to fit 50 % ([vm.md](vm.md) §10) | warning only |

### 9.2 Flow

The GUI's onboarding (host-ui.md) and `apkrun setup` drive the same steps. Registration must run in APKRun.app (SMAppService registers the calling app's agent). Everything after it runs in apkrund, as the long-running operation `setup` (§8.3).

```text
APKRun.app first launch
  1. SMAppService.agent(plistName:).register()
       .requiresApproval → explain, openSystemSettingsLoginItems(), poll status every 2 s while the sheet is open
  2. connect to apkrund (broker → control endpoint)
  3. setup(imageSource)  → ProvisioningState events
       checkingHost        HostRequirementsCheck (§9.1)
       installingImage     ImageStore.install(source) (android-image.md §10.3, §10.4)
       creatingInstance    InstanceStore.provision() (android-image.md §5.1)
       firstBoot(phase)    ensureReady(.provisioning) with the first-boot timeouts (§3.2)
       installingAgents    development: GuestAgentProvisioner installs the agent and the IME (guest-components.md §3.1)
       verifying           DisplayPool acquire + LaunchApplication of HealthCheckActivity (guest-components.md §4.1) + first frame, then release
       complete            state.json: provisioned = true
```

```swift
public enum ProvisioningState: Sendable, Equatable, Codable {
    case notStarted
    case checkingHost
    case installingImage(fraction: Double)
    case creatingInstance
    case firstBoot(BootPhase, fraction: Double)
    case installingAgents
    case verifying
    case complete
    case failed(step: ProvisioningStep, error: WireError)
}
```

- Each step is idempotent and records completion in `state.json`. `setup` after an interruption (quit, crash, sleep) continues at the first incomplete step.
- On failure the GUI shows the step, the error, and **Try Again** / **Report…**. A failed first boot keeps the instance, so "Try Again" boots again without re-cloning. After 2 failed first boots the GUI offers **Start Over**, which sends `setup` with `recreateInstance = true` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §5.4).
- `RuntimeService` operations that need Android return `RuntimeFailure.notProvisioned` until `complete`. Wrappers show "APKRun needs to finish setup" with an **Open APKRun** button.

### 9.3 Image sources

| Source | When | How |
|---|---|---|
| Local bundle directory; a local `.aar` from #058 (M10) | development and M4–M9 builds, and later for manual installs | chosen in the onboarding sheet, `apkrun setup --image <path>`, or `apkrun dev image install <dir>`. `.aar` files need the archive install of #058 ([runtime-maintenance.md](runtime-maintenance.md) §4.5) |
| Release feed | from #087 (M10) | `ImageFeedClient` selects the newest compatible image of the channel and `ImageDownloader` downloads it ([runtime-maintenance.md](runtime-maintenance.md) §4.1–§4.5, [android-image.md](android-image.md) §10.4). The onboarding shows the size and a progress bar. First-run downloads ignore the rollout percentage and the expensive-network rule, but ask first on an expensive network |

The image is not bundled inside APKRun.app. Its size would make every APKRun update a multi-GB download.

### 9.4 Acceptance of #066

On a fresh macOS user account (registration, the Login Items approval, and the data root are per user, so a fresh `APKRUN_HOME` is not enough) and a newly registered agent, with a local image bundle. This is checklist C10-3 ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §8):

1. Open APKRun.app, go through onboarding, and pick the bundle. No terminal command is used.
2. Onboarding reaches `complete`. `apkrun runtime status` shows `ready`.
3. Install HelloText by drag and drop. Open it (through the generic launcher of #068, because wrappers come in M7). The first frame appears.
4. Quit APKRun.app during `firstBoot`, reopen it: setup continues at `firstBoot`.

The total time of steps 1–2 and the first-boot duration are recorded in the #066 report.

### 9.5 Reset Android

Settings → Troubleshooting → **Reset Android…** (and `apkrun runtime reset --erase`) deletes all Android data. It requires typing the confirmation "Reset".

1. `stop(.reset, force: true)`.
2. Create a recovery point (kept for 7 days) unless the user unticks "Keep a backup for 7 days". No operation restores this recovery point in v1 ([../04-plan/open-questions.md](../04-plan/open-questions.md) OQ-41). Settings → Storage and `apkrun image recovery-points` list and delete it.
3. Delete `persistent.img` and `userdata.img`, provision again ([android-image.md](android-image.md) §5.1), and run the first boot.
4. Provisioning writes a new `userdataGeneration`. After `ready`, APKStoreCore's reconciliation finds every package missing from the new generation, marks it `installed` → `needsReinstall(.userdataReset)`, and reinstalls it from `Packages/<id>/current/` under a `storeOperation` assertion ([package-store.md](package-store.md) §9.2). App data is lost. Settings and wrappers stay valid. Adopted packages without an artifact cannot be restored, and they are listed as `broken(.removedInAndroid)` with the Remove action.

---

## 10. Embedded mode and the move to apkrund (#031)

Before #031, `apkrun dev …` runs everything in the CLI process ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.2). The move keeps logic unchanged:

| Before #031 (M1–M3) | After #031/#032 (M4+) |
|---|---|
| `apkrun dev boot` constructs `RuntimeHost` in the CLI, takes the instance lock, and runs the VM | `apkrund` constructs the same `RuntimeHost`. `apkrun runtime start` asks it over XPC |
| `apkrun dev launch` opens a window in the CLI process (`WindowingCore` + `EmbeddedRuntimeService`) | `apkrun launch` asks apkrund, which opens the wrapper or the generic launcher (§7.2) |
| No idle policy, no sleep handling (the CLI process exits with the VM) | §5, §6 |
| Diagnostics in the terminal and in `~/Library/Logs/APKRun/` | same logs. `apkrun logs --follow` runs `log stream` on the host, without apkrund ([cli.md](cli.md) §4.8) |

`apkrun dev` keeps working after M4 for development: booting test images (`APKRUN_HOME` elsewhere), `--gpu`, `--window` console views, and running the Linux test guest. It refuses to touch the user's instance while apkrund holds the lock (§2.3).

---

## 11. Errors

```swift
public enum RuntimeFailure: APKRunError {
    // host process
    case hostStartupFailed(step: HostStartupStep, underlying: WireError)
    case hostShuttingDown
    case hostUpdating                     // an APKRun update is being installed or waits for a restart (runtime-maintenance.md §3.6)
    case instanceLocked(owner: InstanceLockOwner)
    case notProvisioned
    case hostRequirementsNotMet([HostRequirement])
    // runtime lifecycle
    case invalidTransition(from: RuntimeState, to: RuntimeState)
    case image(ImageFailure)
    case vm(VMFailure)
    case vmConfiguration(VMConfigurationFailure)   // VMDefinitionValidator rejects the definition (vm.md §3)
    case graphics(GraphicsFailure)
    case bootTimedOut(phase: BootPhase)
    case bootStalled(phase: BootPhase)
    case kernelPanic
    case androidBootFailed(detail: String)
    case agentIncompatible(agent: AgentKind, guest: ProtocolVersion, host: ProtocolRange)
    case requiredAgentUnavailable(agent: AgentKind)
    case guestUnresponsive
    case bootLoop(failures: Int)
    case stopTimedOut
    case busy(activities: [ActivityKind])
    // sessions and displays (display-and-windowing.md §10)
    case packageNotInstalled(PackageID)
    case launchTimedOut(PackageID)
    case launchFailed(PackageID, GuestError)
    case displayPoolExhausted, displayAttachFailed(scanout: ScanoutID, reason: String)
    case displayReconfigureFailed(reason: String), displayLost, primaryDisplayBusy(PackageID)
    case guestAgentUnavailable
    // API (process-model-and-ipc.md §2)
    case apiVersionMismatch(client: APIVersion, server: APIVersion)
    case notAuthorized(operation: String)
    case malformedRequest
    case cancelled
    case internal(String)
    case operationNotFound(OperationID)            // operationStatus, cancel, or apkrun operations wait for an unknown or expired ID
    case serviceUnavailable(ServiceUnavailableReason)   // RuntimeClient can't reach the broker or an endpoint (§8.5)
    case requestTimedOut(operation: String)        // RuntimeClient got no reply within the operation's deadline plus 5 s
    case developerModeRequired                     // guestLog or frameStatistics while developer.enabled is off (../03-reference/runtime-api.md §6.3, §13.1)
    // settings (configuration.md §8.1)
    case unknownSetting(key: String)               // a global settings key that does not exist
    case invalidSettingValue(key: String, allowed: String)   // a value of the wrong type or outside the allowed values. Fixed variant sharedFolders
    // health findings (§12), never thrown
    case slowBoot(duration: Duration)              // runtime.boot: the last boot took more than 2× the median
    case stopsForced                               // runtime.stop: the last 3 stops were forced (§3.5)
    case hostMemoryPressure                        // runtime.memoryPressure: warning or critical (§5.5)
    case inputDegraded                             // agent.input (diagnostics.md §7.4)
    case inputMethodNotSelected                    // agent.ime (diagnostics.md §7.4)
    case adbEnabledUnexpectedly                    // agent.developerMode: ADB is on while developer mode is off
}

public enum HostStartupStep: String, Sendable, Codable {
    case settings, maintenance, imageStore, packageStore, wrapperRegistry, services   // the degraded steps of §2.2
}

public enum InstanceLockOwner: String, Sendable, Codable {
    case apkrund, apkrunDev                        // the owner written in the lock file (§2.3)
}

public enum HostRequirement: Sendable, Codable, Equatable {
    case appleSilicon, macOSVersion, virtualization, apfsVolume
    case freeDiskSpace(needed: Int64)              // §9.1. Memory is a warning, not a requirement
}

public enum ServiceUnavailableReason: String, Sendable, Codable {
    case notRegistered                             // SMAppService.status is notRegistered or notFound
    case requiresApproval                          // SMAppService.status == .requiresApproval
    case notRunning                                // registered, but the broker doesn't answer
}
```

Error domain `runtime`. Codes, user messages, and remediations are in [../03-reference/error-catalog.md](../03-reference/error-catalog.md). User-facing text never contains console excerpts. They go to the diagnostics snapshot (§3.6).

---

## 12. Logging, metrics, health

- Subsystem `io.apkrun.runtime`, categories `host` (startup, exit, recovery), `supervisor` (states, boot phases), `agents`, `idle`, `power`, `sessions`, `display` ([display-and-windowing.md](display-and-windowing.md) §10), `xpc`.
- Perf markers set here (the full list is in [diagnostics.md](diagnostics.md) §4): `DAEMON_READY`, `KERNEL_START`, `ANDROID_INIT`, `SYSTEM_SERVER_READY`, `BOOT_COMPLETED`, `AGENT_CONNECTED`, `RUNTIME_READY`, `VM_PAUSED`, `VM_RESUMED`, `APP_LAUNCH_REQUEST`, `DISPLAY_ATTACHED`, `ACTIVITY_STARTED`, `FIRST_FRAME`. `VM_START` comes from VirtualMachineCore.
- Health checks (DiagnosticsCore `HealthCheck`, used by `apkrun doctor` in #059). The `apkrund.*` checks run in the client, because apkrund cannot report that it is unreachable. The exact conditions and remediations are in [diagnostics.md](diagnostics.md) §7.3:

| Check | Healthy | Degraded / failing |
|---|---|---|
| `apkrund.registration` | `SMAppService.status == .enabled` | `requiresApproval`, `notRegistered`, `notFound` |
| `apkrund.reachable` | the broker answers `hello` within 5 s with the same API major version | no answer, or an incompatible major version |
| `apkrund.version` | apkrund's build equals the client's build | a different build; `restartPending` while an APKRun update waits for Android to stop ([runtime-maintenance.md](runtime-maintenance.md) §3.6) |
| `apkrund.crashLoop` | < 3 unclean exits in 10 min | ≥ 3 (§2.5) |
| `runtime.state` | `ready` or `suspended` or `stopped` | `failed(f)` with the failure code |
| `runtime.boot` | last boot within the timeout | last boot failed (the failure's code), or took > 2× the median (`runtime.slowBoot`) |
| `runtime.stop` | last stop graceful | last 3 stops forced (§3.5): `runtime.stopsForced` |
| `agent.guest`, `agent.store` | `connected` | `reconnecting` > 5 s, stopped reconnecting after protocol violations ([guest-protocol.md](guest-protocol.md) §12.2), or restarted 3 times in a minute ([guest-components.md](guest-components.md) §3.3): `runtime.requiredAgentUnavailable`. `incompatible`: `runtime.agentIncompatible` |
| `runtime.memoryPressure` | normal | warning, critical (§5.5): `runtime.hostMemoryPressure` |
| `runtime.provisioning` | `complete` | incomplete step |

---

## 13. Implementation steps

### #031 Introduce apkrund (M4)

1. Add the `Daemon/apkrund` target: a thin `main.swift` that builds `RuntimeHost` and calls `RunLoop.main.run()`. Embed it in `APKRun.app/Contents/Helpers/` with the plist from [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.1 plus the launchd keys of §2.1.
2. Implement `RuntimeHost.start()` in the order of §2.2, the instance lock (§2.3), `daemon.json` and unclean-exit handling (§2.5), and the exit rules with `SIGTERM` handling (§2.4).
3. Move VM ownership from the CLI to apkrund: `RuntimeSupervisor` with the boot sequence (§3.2), `BootPhaseDetector` with golden tests over the #064 console captures (§3.3), readiness (§3.4), stop (§3.5), and failure handling (§3.6).
4. Agent supervision and reconciliation (§4) on top of #072's `GuestAgentSupervisor`. The broker listener with the version handshake and the first control operations `runtimeStatus`, `runtime start`, and `runtime stop` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md)). Startup step 11 needs the listener, and the T2 tests need a way to start and stop the runtime. #032 builds the rest of the API around these three without changing their shape.
5. Registration in APKRun.app (`SMAppService`; re-registration when the agent is not `.enabled` or the embedded plist hash changed, [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.1, [runtime-maintenance.md](runtime-maintenance.md) §3.7 step 2). #057 moves this check into `AgentRegistrar`.
6. Acceptance:
   - closing APKRun.app does not stop the runtime while an app is active (HelloText stays interactive for 5 minutes after the GUI quits). Before #068 there is no app window over XPC, so #031 starts HelloText on display 0 through the test's `AdbClient`, and "interactive" means an injected tap is answered by HelloText's `click <n>` line. This is the headless form of G6 ([../04-plan/roadmap.md](../04-plan/roadmap.md) §2); #032 adds the warm-launch condition and #068 runs the full check with the window.
   - `kill -9 $(pgrep apkrund)` during a session: launchd restarts apkrund within 15 s, the wrapper reconnects and gets HelloText back through a cold launch (NFR-REL-02), and `daemon.json` records the unclean exit.
   - Logout with a running session: Android shuts down gracefully (`graceful` in the stop log).

### #032 XPC runtime API (M4)

1. Define the DTOs and `@objc` protocols in RuntimeAPI ([../03-reference/runtime-api.md](../03-reference/runtime-api.md)): `runtimeStatus`, `install`, `launch`, `terminate`, `list`, `applicationInfo`, plus `subscribe`, `cancel`, `runtime start/stop`, the session channel, and the operations of §8.6 that name #032.
2. Implement the broker and the endpoints (§8.1), request rules (§8.2), long-running operations (§8.3), and `EventHub` (§8.4).
3. RuntimeClient: `XPCRuntimeService` with the reconnect behavior of process-model §2.5.
4. Switch the CLI's non-`dev` commands to RuntimeClient (§8.5).
5. `SessionRegistry`: client connections, the authorization of step 1 of §7.1, takeover, and orphaned sessions (§7.3), on top of the M3 registry (§7).
6. Acceptance:
   - `apkrun launch io.apkrun.fixture.hellotext` starts HelloText through XPC. The CLI process does not own a VM (it exits after `launch` returns and the app keeps running; `apkrun runtime status --json` reports `owner: apkrund`).
   - A test binary signed with another identity is rejected at the control endpoint (ADR-0007 verification).
   - A wrapper requesting a session for another package gets `notAuthorized`. Wrappers and their real identity check come with #044, so #032 puts the check behind a `WrapperAuthorizer` protocol, and the test uses a Debug fixture authorizer that maps a test bundle ID to one package. #044 replaces it.
   - G6 condition 3: a warm launch after the runtime is `ready` writes no boot markers.
   - Until #068 there is no launcher window. In Debug builds, `APKRUN_TEST_HEADLESS_LAUNCH=1` makes `launch` open a session owned by apkrund on a pool display that discards its frames. The hook is listed in [../03-reference/configuration.md](../03-reference/configuration.md) §5.1 and [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.3 while it exists, the Release string check fails a Release build that contains it, and #068 removes it.

### #066 First-run provisioning (M4)

1. `HostRequirementsCheck` (§9.1).
2. The `setup` operation and `ProvisioningState` (§9.2) with resumable steps, using ImageCore install and provisioning from #065.
3. The onboarding sheet in APKRun.app (host-ui.md) and `apkrun setup --image`.
4. Reset Android (§9.5).
5. Acceptance: §9.4.

### #069 Idle policy and sleep/wake (M4)

1. `IdleController` with activity sources, `RuntimeActivityAssertion`, timers, and settings (§5.1–§5.2). T0 tests with a manual clock.
2. Suspend and resume (§5.3), preboot (§5.4), memory pressure (§5.5).
3. `PowerObserver` (§6). `apkrun dev power sleep|wake` injects the same messages into the running `apkrun dev boot` for T2 tests ([cli.md](cli.md) §5).
4. Time sync after resume and wake: `SyncTime` through the Guest Agent, and in development builds on the stock userdebug image the ADB fallback ([desktop-integration.md](desktop-integration.md) §9; the full locale and time feature is #085).
5. Acceptance:
   - With `runtime.idleSuspendMinutes = 1` and no sessions, the runtime is `suspended` after 1 minute, and apkrund CPU is below 1 % (§5.6).
   - Opening HelloText from `suspended` shows the first frame. `VM_RESUMED → RUNTIME_READY` p50 ≤ 500 ms over 20 runs.
   - With `runtime.idleStopMinutes = 2`, the runtime stops gracefully and apkrund exits after the grace period when no client is connected.
   - A `keepRunning` task, a connected `adb shell`, and a running install each prevent the suspend.
   - The sleep and wake check in §6.

### Health hooks for #059

The checks in §12 are implemented with the components above. #059 adds them to `apkrun doctor` and the GUI's Troubleshooting pane.

---

## 14. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | `RuntimeState` edges (state-machines.md §2); `IdleController` with a manual clock (activity sources, both timers, settings change, `0` = never, sleep not counted); `BootPhaseDetector` golden tests over captured console logs; `BootProgressEstimator`; `ReplyGuard`; exit-rule evaluation | #031, #069 |
| T1 | `RuntimeHost` startup order with fake modules, including degraded steps; instance lock contention between two processes; XPC server with `NSXPCListener.anonymous()` in-process: version mismatch, authorization per endpoint kind, 65th in-flight request rejected, long-operation handle and cancel; `SessionRegistry` with a fake runtime: queued sessions, orphan re-attach, takeover, reconciliation table (§4.2) | #031, #032 |
| T2 | Real VM: cold boot to `ready` with markers; stop paths (graceful, power button, forced); agent kill and reconnect with session continuity; suspend/resume with time sync; injected sleep/wake; CPU budget while suspended; `kill -9 apkrund` recovery; boot-loop guard with test bundle P, whose kernel panics on a missing init ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.5) | #031, #032, #069 |
| T3 | Gate G6: runtime stays warm under apkrund with the GUI closed (staged over #031, #032, and #068); warm launch KPI (with #070); real `pmset sleepnow` sleep and wake; onboarding on a fresh macOS user account (#066) | #031, #032, #068, #066, #069, #070 |

---

## 15. Open items

| Item | Plan |
|---|---|
| The console strings of `BootPhaseDetector` are candidates (§3.3) | #064 records the exact strings and their timing from the reference boot ([android-image.md](android-image.md) §7.7, §8). Only the pattern table in `BootSignals.swift` and its golden tests change |
| Memory balloon before a pause (§5.3, OQ-32) | #069 and #070 measure whether reclaiming guest free memory is worth the slower next launch. Working default: no balloon in v1. A balloon before a pause is also a fallback of R-08 |
| Pause/resume churn during dark wakes (§6, OQ-33) | #069 measures it. Working default: resume on every wake. Fallback: resume lazily on the first request or on `visibilityChanged(true)` |
| Restoring the Reset Android recovery point (§9.5, OQ-41) | a Decision before #058. Working default: no restore in v1 |
| No VM save and restore while VirGL is active (R-07, accepted) | The runtime stays warm with pause and resume (§5), and the perf harness (#070) measures the cold start. Revisit if a later virglrenderer or the Venus track (#096) can rebuild the renderer state |

---

## 16. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| The XPC listener is resumed within 300 ms of process start (`DAEMON_READY`) | #031 | pending (§2.2) |
| Gate G6: the runtime stays warm under apkrund ([../04-plan/roadmap.md](../04-plan/roadmap.md) §2) | #031 (headless form), #068 (full form) | pending (§13 #031, [display-and-windowing.md](display-and-windowing.md) §12 #068) |
| After `kill -9` of apkrund, launchd restarts it within 15 s, and the wrapper gets HelloText back | #031 | pending (§2.5) |
| A binary signed with another identity is rejected at the control endpoint (ADR-0007) | #032 | pending (§13 #032) |
| The exact boot console strings and their timing | #064 | pending (§3.3) |
| Time of onboarding steps 1–2 and the first-boot duration | #066 | pending (§9.4) |
| apkrund CPU stays below 1 % while the runtime is suspended | #069 | pending (§5.6) |
| `VM_RESUMED` → `ready` p50 ≤ 500 ms over 20 runs | #069, #070 | pending (§5.3) |
| The guest wall clock is within 2 s of the host within 5 s of wake | #069 | pending (§6) |
| Memory balloon before a pause | #069, #070 | pending (OQ-32) |
| Pause/resume churn during dark wakes | #069 | pending (OQ-33) |
