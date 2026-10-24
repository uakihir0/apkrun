# Runtime Daemon (apkrund, RuntimeHost, RuntimeSupervisor)

This document covers `apkrund` and the RuntimeCore parts that keep Android running: the process lifecycle, startup and crash recovery, `RuntimeSupervisor` (boot, readiness, stop, failure), guest agent supervision, the idle policy, host sleep and wake, sessions, the XPC server, and first-run provisioning. The process table, launchd registration, and broker authentication are in [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md). The XPC types and operations are in [runtime-api.md](../03-reference/runtime-api.md).

---

## 1. Responsibilities

apkrund is only the composition root. The module in each row implements the item.

| Item | Implemented by | Design |
|---|---|---|
| VM lifecycle | `VMController` (VirtualMachineCore), driven by `RuntimeSupervisor` | §3, [vm.md](vm.md) |
| Android readiness | `RuntimeSupervisor`, `BootPhaseDetector` (RuntimeCore) | §3 |
| Application lifecycle | `SessionRegistry` (RuntimeCore) and the Guest Agent | §7 |
| Display allocation | `DisplayPool` (RuntimeCore) | [display-and-windowing.md](display-and-windowing.md) §3 |
| Window lifecycle | The wrapper owns its window (ADR-0006). apkrund sends `windowRequest` events | [display-and-windowing.md](display-and-windowing.md) §7 |
| Package install and update | APKStoreCore, UpdateCore | [package-store.md](package-store.md), [update-system.md](update-system.md) |
| Update scheduling | `UpdateScheduler` (UpdateCore) | [update-system.md](update-system.md) §3 |
| Guest communication | `GuestAgentSupervisor`, `StoreAgentSupervisor` (RuntimeCore) | §4, [guest-protocol.md](guest-protocol.md) §13 |
| macOS integration | IntegrationCore | [desktop-integration.md](desktop-integration.md) |
| Diagnostics | DiagnosticsCore | [diagnostics.md](diagnostics.md) |

apkrund has no `NSApplication`, and it accepts input only from XPC clients. It links AppKit only for `NSWorkspace`, through one adapter, `WorkspaceOpener`. `NSWorkspace.openApplication(at:configuration:)` opens a wrapper (§7.2). `NSWorkspace.open(_:)` opens a forwarded link ([desktop-integration.md](desktop-integration.md) §7.2).

---

## 2. Process lifecycle

### 2.1 What starts apkrund

The daemon source is `Daemon/apkrund`, a thin `main.swift` that builds `RuntimeHost`. It is embedded in `APKRun.app/Contents/Helpers/`.

| Trigger | Mechanism | After startup |
|---|---|---|
| A client connects to `io.apkrun.apkrund.xpc` | launchd on-demand launch (`MachServices`) | Serves the request |
| User login | `RunAtLoad` | Applies `runtime.startPolicy` (§5.4). With `onDemand` and nothing to do, it exits after the grace period (§2.4) |
| Periodic wake | `StartInterval` 3600 s | `UpdateScheduler` runs due checks ([update-system.md](update-system.md) §3), then exits after the grace period. It never boots the VM for a check. Only the opt-in `updates.startRuntimeToInstall` boots it ([update-system.md](update-system.md) §3.5) |
| Crash | `KeepAlive.SuccessfulExit = false` | Crash recovery (§2.5) |

Exit status 0 follows a startup failure that prevents the broker from being constructed. This stops a restart loop for a stable bundle or signing error. A later request or `StartInterval` retries startup. An unexpected crash exits non-zero, and launchd restarts the job.

Job keys in the plist ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.1):

| Key | Value | Effect |
|---|---|---|
| `RunAtLoad` | `true` | Preboot and recovery of interrupted package transactions run without a client |
| `StartInterval` | `3600` | Update checks run while no APKRun process runs (FR-UPD, NFR-PERF-07) |
| `ExitTimeOut` | `45` | launchd sends `SIGKILL` 45 s after `SIGTERM`. A graceful Android shutdown needs up to 40 s (§3.5) |

### 2.2 Startup sequence (`RuntimeHost.start()`)

Each step logs `host.startup.<step>` with its duration. The XPC listener resumes within 300 ms of process start when no recovery work is pending. The `DAEMON_READY` marker records the resume.

| # | Step | Module | On failure |
|---|---|---|---|
| 1 | Resolve `APKRunPaths`, bootstrap logging, install the `SIGTERM` handler (§2.4) | DiagnosticsCore | Exit 70 |
| 2 | Acquire the instance lock (§2.3) | RuntimeHost | Exit 0 if another apkrund owns it. Otherwise serve the broker with `RuntimeFailure.instanceLocked` |
| 3 | Read `Runtime/daemon.json`, detect an unclean previous exit (§2.5), write the `running` record | RuntimeHost | Continue |
| 4 | Load `settings.json` and `state.json`, migrating older schemas. A newer schema is a host startup failure. Then `MaintenanceService.start()` reads `Runtime/maintenance.json`, applies its startup rules (the host state may become `updating`), and starts `BundleWatcher` ([runtime-maintenance.md](runtime-maintenance.md) §3.6, §5) | DiagnosticsCore, RuntimeHost | Degraded |
| 5 | `ImageStore.open()`: delete `Images/.installing-*`, resolve `current` and `previous`, recover an interrupted migration ([android-image.md](android-image.md) §12.3) | ImageCore | Degraded |
| 6 | `PackageStore.open()`: replay `Packages/journal.jsonl`. Steps that need the guest become post-boot work (§3.4) ([package-store.md](package-store.md) §5) | APKStoreCore | Degraded |
| 7 | Load `Wrappers/registry.json` | WrapperCore | Degraded |
| 8 | Construct RuntimeCore: `RuntimeSupervisor` (state `stopped`), `DisplayPool`, `SessionRegistry`, `InputRouter`, agent supervisors | RuntimeCore | Fatal. A Guest Agent bundle load failure is degraded (below) |
| 9 | Construct `UpdateScheduler` (timers only), IntegrationCore, `ImageUpdateCoordinator` (reconciles its phase with `RuntimeImageState`), and `SelfUpdateProbe`. If `state.json.lastRuntimeBuild` is older than this build, queue the post-update tasks ([runtime-maintenance.md](runtime-maintenance.md) §3.8, §4.3) | UpdateCore, IntegrationCore, RuntimeHost | Degraded |
| 10 | Register the power observer (§6), the memory pressure source (§5.5), and `IdleController` (§5) | RuntimeCore | Continue |
| 11 | Resume the XPC listener (§8) | RuntimeHost | Fatal |
| 12 | Apply `runtime.startPolicy` (§5.4). Skipped unless the host state is `normal` | RuntimeCore | Continue |

The listener is published after steps 1–3, so clients can read status during slower recovery. Step 11 records the actual resume time. Start and stop requests wait for initialization and then receive any recorded startup failure.

**Degraded** means apkrund keeps serving the broker. `runtimeStatus` returns `RuntimeFailure.hostStartupFailed(step:)`, and operations that need the failed component return the same error. Bad data on disk never causes a crash loop. A Guest Agent bundle load failure before step 8 is degraded; a failure to construct `RuntimeSupervisor` is fatal.

### 2.3 Instance lock

- `Runtime/instance.lock` is held with `flock(LOCK_EX | LOCK_NB)` for the process lifetime. It records the owner (`apkrund` or `apkrun-dev`), the PID, and the binary path, for error messages only.
- `apkrun dev` (§10) takes the same lock. This is how `apkrun dev` refuses to run while apkrund owns the user's runtime ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.2). With `APKRUN_HOME` set to another root, it uses a different lock, may run next to apkrund, and prints a memory warning.
- The kernel releases the lock when the process dies, so a crash never leaves a stale lock.

### 2.4 Exit rules

apkrund exits with status 0 when **all** of these hold for 2 minutes (the exit grace period):

- `RuntimeState == stopped`.
- No XPC connections (GUI, menu bar, CLI, wrappers).
- No `RuntimeActivityAssertion` (§5.1) and no operation in flight.
- No `UpdateScheduler` work due within the grace period, and no image feed check, self-update probe, or image download in flight or due ([runtime-maintenance.md](runtime-maintenance.md) §3.4, §4.2, §4.4).

Two maintenance exits skip the grace period ([runtime-maintenance.md](runtime-maintenance.md) §3.5, §3.6). After `prepareForHostUpdate` replies, apkrund exits 0 one second later. In `restartPending`, it stops Android and exits 0 once no session, background task, or operation is left. launchd does not restart after status 0.

On `SIGTERM` (logout, shutdown, `SMAppService.unregister()`, `launchctl bootout`):

1. Reject new XPC connections. Racing lifecycle operations fail with `runtime.hostShuttingDown`; status stays available and reports `shuttingDown`. Drain accepted package mutations and session operations, then stop the app-session service, remove the Guest Agent observers, and stop Android.
2. `RuntimeSupervisor.stop(reason: .hostShutdown)` with a 40 s deadline (§3.5). Sessions end with `.runtimeStopped`.
3. Flush logs, write `daemon.json` with `cleanExit = true`, close the connections, and exit 0.

At the deadline the VM is force-stopped (`VMController.stop()`). Userdata is written through the host page cache, so only unflushed data is lost.

### 2.5 Unclean exit and crash recovery

`Runtime/daemon.json` (NFR-REL-02):

| Key | Meaning |
|---|---|
| `schemaVersion` | `1` |
| `pid` | PID of the owning process. Do not use it to infer ownership |
| `startedAt`, `version` | Start time (ISO 8601) and APKRun build, for example `0.2.0 (200)` |
| `cleanExit` | `false` at start. A clean `SIGTERM` exit (§2.4) writes `true` |
| `recentUncleanExits` | Times of unclean exits, the last 10 |
| `bootHistory` | One entry per boot: `imageVersion`, `kind` (for example `cold`), and `phasesMs` with the keys `kernel`, `init`, `systemServer`, `bootCompleted`, and `agentsConnecting` |

After the new process acquires the instance lock, `cleanExit == false` means the previous apkrund crashed or was killed. Lock ownership shows that the prior daemon no longer owns the runtime. Do not infer this from the PID, which may be reused.

- Log `host.previousExitUnclean` at fault level. Append the time to `recentUncleanExits`.
- Record the newest `~/Library/Logs/DiagnosticReports/apkrund-*.ips` path in `$APKRUN_HOME/Diagnostics/index.json`, keeping the latest 20, so `apkrun diagnostics` can include it ([diagnostics.md](diagnostics.md) §8).
- The VM exits with the process, because the Virtualization.framework helpers exit with their owner. Android repairs userdata on the next boot, as after a power loss.
- Remove stale ADB forwards (`localabstract:apkrun-*`, [guest-protocol.md](guest-protocol.md) §13.2). In development builds, also run `adb disconnect 127.0.0.1:6520`.
- Steps 5 and 6 of §2.2 recover image migrations and package transactions.
- Three unclean exits within 10 minutes set health `apkrund.crashLoop = failing`. apkrund then refuses automatic boots (§3.6) until the user starts the runtime explicitly (GUI "Start Android" or `apkrun runtime start`).

Wrappers reconnect with backoff and cold-launch ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.5).

### 2.6 Development builds and debugging

- Debug builds use separate identities and never replace a release. Bundle IDs end in `.dev` (`io.apkrun.APKRun.dev`). The LaunchAgent label and Mach service are `io.apkrun.apkrund.dev` and `io.apkrun.apkrund.dev.xpc`. `APKRUN_HOME` defaults to `~/Library/Application Support/APKRun-Dev/`. RuntimeClient picks the service name from the build configuration ([build-system.md](../05-development/build-system.md)).
- `scripts/dev/install-dev-app.sh` copies the app to `~/Applications/APKRun Dev.app` and re-registers the agent (`APKRun --register-runtime`).
- Debug with the Xcode scheme "apkrund (attach)". `launchctl kickstart -k gui/$(id -u)/io.apkrun.apkrund.dev` restarts the daemon under the debugger. `launchctl print` shows the job state and PID.

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

- [state-machines.md](../01-architecture/state-machines.md) §2 defines `RuntimeState` and its transitions.
- `ensureReady` in `stopped` boots. In `booting` it waits. In `suspended` it resumes (§5.3). In `stopping` it waits for `stopped`, then boots. In `failed` (only while the diagnostics snapshot is captured, §3.6) it waits for `stopped`, then boots, subject to the boot-loop guard.
- Cancelling the waiting task does not cancel the boot. A boot that nobody waits for completes, and the idle policy takes over.
- `ensureReady(.session)` is refused while the boot-loop guard is set (§3.6). Explicit starts (`cli`, and `user` from APKRun.app or the menu bar) clear the guard.

### 3.2 Boot sequence (cold start)

```text
ensureReady(reason)
  0. guard: provisioned (§9; skipped for reason .provisioning), not boot-loop-blocked (§3.6); take activity assertion .boot
  1. state: stopped → booting(.kernel)
  2. ImageCore: pre-boot checks and per-boot initrd (android-image.md §9.3)
  3. GraphicsCore: create the virtio-gpu device model and the renderer thread; apply graphics.safeMode (graphics.md §9)
  4. VirtualMachineCore: VMController.start(definition)           PerfMarker VM_START
  5. attach ConsoleLogWriter → BootPhaseDetector (§3.3)
  6. start the ADB bridge: guest vsock 5555 ↔ 127.0.0.1:6520 (connects succeed once adbd listens)
  7. agents (§4): development → after .bootCompleted, GuestAgentProvisioner installs/starts guestd over ADB
                  custom image → connect attempts start at .systemServer (persistent apps start before boot completes)
  8. booting(.agentsConnecting) → all required agents accepted (guest-protocol.md §5)   PerfMarker AGENT_CONNECTED (per agent)
  9. post-boot setup (§3.4)
 10. state: → ready                                               PerfMarker RUNTIME_READY
     resume all ensureReady waiters; release assertion .boot; IdleController starts counting (§5)
```

| Timeout | Default | Setting | Result |
|---|---|---|---|
| Whole boot, normal | 180 s | `runtime.bootTimeoutSeconds` | `failed(.bootTimedOut(phase))` |
| Whole boot, first boot of an instance or of a new image | 900 s | `runtime.firstBootTimeoutSeconds` | Same. Android formats userdata and runs dexopt ([android-image.md](android-image.md) §5.2, §12.3) |
| No phase progress (stall) | 90 s (first boot: 600 s) | — | `failed(.bootStalled(phase))` |
| Required agent readiness after `.bootCompleted` (boot confirmation, first-boot settings, ADB, development provisioning, handshake, initial snapshot) | 30 s | — | `failed(.requiredAgentUnavailable(agent))` |

An immediate failure ends the boot. `Kernel panic - not syncing` on the console gives `failed(.kernelPanic)`. `VIRTUAL_DEVICE_BOOT_FAILED` gives `failed(.androidBootFailed)`. `VMState → failed` gives `failed(.vm(…))`. GraphicsCore's `rendererInitFailed` gives `failed(.graphics(…))`.

### 3.3 BootPhaseDetector

`BootPhaseDetector` reads console lines from `ConsoleLogWriter`, which already splits them, and readiness signals from ADB or the agents. It emits phase changes. Phases are monotonic: a phase may be skipped when its signal is not observable, but it is never re-entered.

| Phase entered | Console signal (every image) | ADB signal (development) | Agent signal | Perf marker |
|---|---|---|---|---|
| `.kernel` | First console byte after `VM_START`. On VZ, `hvc0` appears late in first-stage init, so earlier kernel lines are not seen. On crosvm, U-Boot's banner comes first | — | — | `KERNEL_START` |
| `.init` | First line from init (`init: ` after the kmsg prefix). `init: init first stage started!` precedes `hvc0` on VZ, so it is not used | — | — | `ANDROID_INIT` |
| `.systemServer` | `init: starting service 'zygote'`. No console line marks SystemServer's start | `getprop sys.system_server.start_count` is non-empty (polled every 500 ms) | — | `SYSTEM_SERVER_READY` |
| `.bootCompleted` | `VIRTUAL_DEVICE_BOOT_COMPLETED`, written by the guest's `GceEventReporter` | `getprop sys.boot_completed` = `1` | `Hello.android` / `SystemState.boot_completed` ([guest-protocol.md](guest-protocol.md) §7.2) | `BOOT_COMPLETED` |
| `.agentsConnecting` | — | — | Right after `.bootCompleted` | — |

- The console strings and their VZ behavior are in [android-image.md](android-image.md) §7.7. The patterns live in one table (`BootSignals.swift`), with golden tests over captured VZ console logs.
- The first signal that arrives wins. With `adbd` stopped on a custom image, `.bootCompleted` comes from the console marker or from the Guest Agent.
- `BootProgressEstimator` divides elapsed time by the median duration of each phase over the last 5 boots of the same kind (`bootHistory`, §2.5). Without history it uses fixed weights. Before `ready`, progress never shows above 95 %.

### 3.4 Readiness and post-boot setup

`ready` requires all of the following. Nothing else gates it.

1. `VMState == running`, and `.bootCompleted` was seen.
2. Every **required** agent completed the handshake with an accepted protocol version. Development (stock image): the Guest Agent. Custom image: the Guest Agent and the Store Agent. The development IME channel is not required: it connects when Android binds the IME ([input.md](input.md) §5.6).
3. `GetSnapshot` returned, and `DisplayPool` reconciled with it. Every secondary display that Android knows and that has no lease is cleared, and its scanout is disabled ([display-and-windowing.md](display-and-windowing.md) §3).
4. Host-owned configuration was pushed (§4.2): display policies, developer mode, locale and time zone, time sync ([desktop-integration.md](desktop-integration.md) §9), and integration settings.
5. Post-boot work queued at startup ran, or was re-queued with a reason ([package-store.md](package-store.md) §5). Post-boot work never blocks `ready` for more than 5 s. Longer work runs after `ready`, under an activity assertion.

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
- Without a Guest Agent, step 4 is skipped.
- Every stop logs the path it took (`graceful`, `powerButton`, `forced`) and its duration. `apkrun doctor` warns when the last 3 stops were forced.
- While a package install is active, RuntimeHost rejects user stop, restart, and reset with `runtime.invalidTransition`. Daemon shutdown drains the install before it stops Android. This reservation lasts until the tracked install reaches a terminal result.

### 3.6 Failure handling and automatic restart

When the supervisor enters `failed(f)`:

1. Capture a diagnostics snapshot in `~/Library/Logs/APKRun/crash/<timestamp>-runtime/`: the console tail (last 2 MiB), the last 200 `BootPhaseDetector` events, agent health, GraphicsCore statistics, and `logcat -d` (5 s limit) ([diagnostics.md](diagnostics.md) §8).
2. `VMController.stop()` if the VM still runs, then `reset()`. The state becomes `stopped` ([state-machines.md](../01-architecture/state-machines.md) §2).
3. Sessions have already ended with `.error(f)` or `.runtimeStopped`.

Automatic restart (`runtime.autoRestart`, default `true`): if a session was `running`, the supervisor performs **one** cold boot, and the affected wrappers retry `openSession` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.5). A second failure within 10 minutes is not retried. The wrapper shows "Android stopped unexpectedly" with **Restart**, **Troubleshooting…**, and **Report…**.

Boot-loop guard: 3 runtime failures (or unclean apkrund exits, §2.5) within 10 minutes set `bootLoopBlocked`. While it is set, `ensureReady(.session)` throws `RuntimeFailure.bootLoop`. The GUI offers Restart, graphics safe mode ([graphics.md](graphics.md) §9), and "Reset Android" (§9.5). An explicit start clears the guard.

`GraphicsFailure.rendererLost` while `ready` is a failure that triggers automatic restart ([graphics.md](graphics.md) §8).

---

## 4. Guest agent supervision

### 4.1 Connection state

Each agent supervisor ([guest-protocol.md](guest-protocol.md) §13.1) has its own state. The state appears in health and in `runtimeStatus`.

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

- `connecting` and `reconnecting` retry with backoff from 100 ms, doubling up to 2 s ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).
- `incompatible` fails the boot with `RuntimeFailure.agentIncompatible` (NFR-REL-04). The remedy is "Update APKRun" when the guest is newer and "Update Android" when the host is newer.
- In development mode the supervisor restarts the agent through `GuestAgentProvisioner` ([guest-components.md](guest-components.md) §3.3). On the custom image, Android restarts the persistent app itself.

### 4.2 Reconnect and reconciliation

Rule: **the host is the source of truth for configuration, and the guest is the source of truth for Android state.** After every handshake (first connect and reconnect):

1. `GetSnapshot` ([guest-protocol.md](guest-protocol.md) §6). The supervisor replaces its view of displays, tasks, focus, and packages.
2. Push host-owned configuration again: `SetDisplayPolicy` for every leased display, `FocusDisplay` for the focused session, notification forwarding and URL redirect settings, and `SetLocale` and `SetTimeZone`.
3. Reconcile sessions (`SessionRegistry`):

| Snapshot shows | Session state before | Action |
|---|---|---|
| Display present, the session's tasks present | running, backgrounded | Continue |
| Display present, no tasks of the package | running, backgrounded | End with `.appExited` (the app finished during the disconnect) |
| Display present, no tasks | launching | Send `LaunchApplication` again (idempotent: `BROUGHT_TO_FRONT` if it had started) |
| Display missing | any | End with `.error(.displayLost)` and release the lease (the scanout is reset) |

4. Send `InputEvent.cancelAll` to every leased display, so no touch stays down across the gap ([input.md](input.md) §7).

The agent stays non-ready while snapshot handlers reconcile host state. Events received during a handler update the candidate snapshot, and the handlers run again. Buffered events publish in order once the snapshot is current, and guest operations such as a retried `LaunchApplication` run after this barrier. A handler must not wait for input-router cleanup that sends guest requests: it detaches the local route in the callback and completes `sessionEnded` after readiness resumes.

### 4.3 Operations during a disconnect

- Frames keep flowing. The graphics path does not depend on the agent.
- Input is dropped and counted (`input.droppedWhileDisconnected`). Text events are dropped too. The wrapper shows no error for gaps shorter than 2 s.
- A request that needs the agent waits up to 5 s for an in-progress reconnect, then throws `RuntimeFailure.guestAgentUnavailable` ([display-and-windowing.md](display-and-windowing.md) §10). A waiting request is unsent. A submitted request is never replayed, because the guest may have performed it. Stop or cancellation wakes a queued request at once with `GuestProtocolFailure.agentUnavailable`.
- A required agent unreachable for more than 30 s while `ready` moves the runtime to `failed(.requiredAgentUnavailable(agent))` (§3.6). The deadline spans reconnect attempts and is cancelled by a completed handshake and `GetSnapshot`. The failure is published before teardown, and the runtime returns to `stopped`, so a later `ensureReady` can retry.
- Hung guest watchdog: if the agent misses pings, ADB is unreachable, and the console is silent, all for 60 s while `ready`, the runtime moves to `failed(.guestUnresponsive)`.

---

## 5. Idle policy

`IdleController` (RuntimeCore, actor) decides when to suspend (pause the VM) and when to stop the runtime. It implements FR-VM-10. It is the only component that calls `VMController.pause()` outside host sleep (§6).

### 5.1 Activity

The runtime is **active** while any source below exists. Idle time counts only while none exists.

| Source | How it is tracked |
|---|---|
| An app session in any state except `ended` (`backgrounded` counts) | `SessionRegistry` |
| A task kept alive by `window.closeBehavior = keepRunning` ([display-and-windowing.md](display-and-windowing.md) §7.6) | `ActivityKind.backgroundTask`, until the task vanishes or the package is terminated |
| Install, uninstall, gentle update install, icon rendering, metadata refresh | `ActivityKind.storeOperation`, held by APKStoreCore for the operation |
| Diagnostics collection, image migration, first-run provisioning | `.diagnostics`, `.migration`, `.provisioning` |
| An ADB client connected through the bridge (developer mode) | `.adbClient`, while a TCP connection to 127.0.0.1:6520 is open |
| `apkrun runtime start --hold` (until the CLI exits or is interrupted) | `.cli` |

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

`IdleController.assertActivity(_:)` emits an `activityBegan` action before it returns the assertion, so the lifecycle owner makes the runtime ready. Lifecycle actions run serially, and pending idle actions are discarded when activity begins. Action handlers never acquire assertions, directly or in child tasks. Owners acquire assertions before they request lifecycle work.

Not activity: GUI, menu bar, or CLI connections that only observe, and update checks and downloads (UpdateCore works while the runtime is stopped).

An app closed with `stop` receives no notifications while the runtime is suspended. Messaging and music apps need `keepRunning`. The Settings UI says so.

### 5.2 Timers and settings

| Setting | Default | Meaning |
|---|---|---|
| `runtime.idleSuspendMinutes` | 10 | Idle time until `ready → suspended`. `0` = never suspend |
| `runtime.idleStopMinutes` | 60 | Idle time, counted from when idleness began and including suspended time, until the runtime stops. `0` = never stop |
| `runtime.startPolicy` | `onDemand` | `onDemand` or `atLogin` (§5.4) |

- Idle time uses `SuspendingClock`, which does not advance while the Mac sleeps. A lid closed overnight does not count as idle time.
- `idleStopMinutes` below `idleSuspendMinutes` means "stop without suspending first". If both deadlines are equal, the suspend action is delivered before the stop action.
- A settings change applies at once: the controller recomputes its deadline.
- `IdleController` keeps one one-shot clock sleep for the next enabled deadline. It emits `suspend` and `stop` actions to the lifecycle owner rather than polling. A settings update replaces that sleep and keeps the idle start instant.

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

- Target: `VM_RESUMED` → `ready` p50 ≤ 500 ms, so a launch from `suspended` stays within NFR-PERF-01 plus 0.5 s. #71 measures it.
- A VZ pause error gives `failed(.vm(.pauseFailed))`, and a resume error gives `failed(.vm(.resumeFailed))` (§3.6).
- The memory balloon is not inflated before a pause in v1 (OQ-32).

### 5.4 Preboot (`runtime.startPolicy`)

- `onDemand` (default): the runtime boots on the first request that needs Android.
- `atLogin`: 60 s after login, when apkrund starts at login (§2.1), it calls `ensureReady(.preboot)`. The delay keeps it from competing with other login items. After `ready`, the normal idle rules apply. The first app launch is then warm or a resume, not a cold boot.
- Preboot is skipped on battery power below 30 % (`IOPSCopyPowerSourcesInfo`) and during `bootLoopBlocked`.

### 5.5 Host memory pressure

`DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`:

- `.critical` while the runtime is `ready` and no session is visible (every session `backgrounded`, or none) → suspend at once, without waiting for the idle timer. `backgroundTask` assertions prevent this, because suspending would stop the audio the user chose to keep.
- `.warning` → log, and set health `runtime.memoryPressure = warning`. No other action.

### 5.6 CPU budget while suspended

While `suspended`, apkrund stays below 1 % CPU (NFR-PERF-06). These rules make that true:

- No polling: console reading blocks on the pipe, and XPC, the ADB bridge, and agent sockets are event driven.
- Agent pings and request timers stop (`paused`). GraphicsCore statistics timers stop. No display link runs.
- `IdleController` and `UpdateScheduler` each use one one-shot timer. The scheduler's leeway is at least 60 s.

---

## 6. Host sleep and wake

`PowerObserver` (RuntimeCore) registers with `IORegisterForSystemPower` (FR-VM-11) and handles messages on a dedicated serial queue. apkrund has no NSApplication, so it uses IOKit rather than `NSWorkspace` notifications ([vm.md](vm.md) §9.4).

| Message | Action |
|---|---|
| `kIOMessageCanSystemSleep` (idle sleep request) | `IOAllowPowerChange`. APKRun never vetoes sleep |
| `kIOMessageSystemWillSleep` | If the VM is running: record `resumeAfterWake = true`, suspend (§5.3 steps 1–2) without changing the idle timers, then `IOAllowPowerChange`. The pause must finish within 5 s. If it does not, acknowledge anyway and log `power.pauseLate`. macOS waits at most 30 s for the acknowledgement |
| `kIOMessageSystemWillNotSleep` | Undo: resume if this handler paused the VM |
| `kIOMessageSystemHasPoweredOn` | If `resumeAfterWake`: resume (§5.3), including the time sync. The runtime state returns to `ready` |

- A VM that the idle policy suspended stays suspended across sleep and wake.
- A boot in progress pauses with the VM. Boot timeouts use `SuspendingClock`, so sleep never causes `bootTimedOut`.
- Sessions stay open, and the wrapper keeps showing the last frame ([graphics.md](graphics.md) §8).
- Dark wakes also deliver `kIOMessageSystemHasPoweredOn`. v1 resumes on every wake (OQ-33).
- Time sync after wake is required, because the guest clock does not advance while paused (§14).

---

## 7. Sessions

`SessionRegistry` (RuntimeCore, actor) owns `AppSessionState` ([state-machines.md](../01-architecture/state-machines.md) §3). It maps session ↔ package ↔ client connection ↔ display lease ↔ Android task IDs. Display details are in [display-and-windowing.md](display-and-windowing.md).

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

- The descriptor is returned at step 5, when surfaces exist. Later state arrives as the session event `stateChanged` ([runtime-api.md](../03-reference/runtime-api.md) §6.3). The wrapper shows its placeholder until the first frame ([display-and-windowing.md](display-and-windowing.md) §7.3); a cold boot shows `booting(progress)` there (§3.3).
- A pending package transaction for the same package is awaited up to 30 s in phase `waitingForPackage`, with the placeholder text "Updating ‹App›…" ([update-system.md](update-system.md)).

### 7.2 `launch` and `terminate` for control clients

Control clients (GUI, menu bar, CLI) do not own windows, so they call:

- `launch(packageID)`: apkrund opens the window owner with `NSWorkspace.openApplication(at:configuration:)`. The owner is the registered wrapper for the package (`Wrappers/registry.json`) if its bundle exists and its cdhash matches. Otherwise it is the generic launcher `APKRun.app/Contents/Helpers/APKRunLauncher.app --package <id>`, signed with APKRun's identity, using the `.control` endpoint. The launched process calls `openSession`. `launch` returns when the session is `running` or has failed.
- `terminate(packageID)`: ends the session (the wrapper receives `windowRequest(.close)`), stops keep-running tasks, and sends `StopApplication(FORCE_STOP)` to the Guest Agent. The session ends with `.userClosed`. Without a session, it sends `StopApplication(FORCE_STOP)` only when Android is already ready, and it never starts Android. Closing a window uses `StopApplication(FINISH_TASKS)`.

### 7.3 Client disconnects

- A wrapper connection invalidated without `closeSession` makes the session **orphaned** for 3 s. A wrapper for the same package that calls `openSession` in that time re-attaches (§7.1 step 2). Otherwise the session closes with the package's `window.closeBehavior`.
- A control client that disconnects while waiting for `launch` changes nothing. Subscriptions (§8.4) end with their connection.

### 7.4 Runtime stop and failure

`stopping` and `stopped` end every session with `.runtimeStopped`. `failed` ends every session with `.error(f)`. Queued sessions (`waitingForRuntime`) stay queued across `stopping` and wait for the next boot. On `failed` they end with `.error(f)`. Automatic restart (§3.6) lets the wrappers retry.

---

## 8. XPC server

### 8.1 Components

| Component | Serves | Notes |
|---|---|---|
| `XPCBrokerListener` | Mach service `io.apkrun.apkrund.xpc` | `hello`, `requestEndpoint`, `requestApproval` only ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2) |
| `ControlEndpoint` | One-use anonymous listener per grant, with the signing requirement of the selected APKRun client | Full `RuntimeService` |
| `WrapperEndpoint(bundleID)` | One anonymous listener per registered wrapper, created lazily, with `identifier` and `cdhash` requirements | Session API for its own package, and `runtimeStatus` |
| `EventHub` | All endpoints | Fan-out of `RuntimeEvent` topics to subscribers (§8.4) |
| `XPCRuntimeExporter` | — | Adapts the `RuntimeService` Swift protocol to the `@objc` protocols of RuntimeAPI. The same `EmbeddedRuntimeService` instance serves XPC and embedded mode |

Control listeners are created per grant, expire after 5 seconds if unused, and accept one connection. Wrapper endpoints are created when a wrapper asks for one, and they are dropped 10 minutes after their last connection closes. Re-registration (a new cdhash after re-approval) replaces the listener.

### 8.2 Request rules

1. Decode `APIRequestHeader` first. A major version mismatch gives `RuntimeFailure.apiVersionMismatch`. An undecodable payload gives `RuntimeFailure.malformedRequest`. Log the client kind, never the payload.
2. Authorize by endpoint kind, never by claims in the payload. A wrapper request for another package gives `RuntimeFailure.notAuthorized` and a security log entry.
3. Hop from the XPC queue to the owning actor immediately. No work runs on the XPC queue.
4. Every reply is sent exactly once. `ReplyGuard` asserts in debug builds on a second call, and it answers `RuntimeFailure.internal` when released without a reply.
5. The operation ID from the header is attached to every log line and perf marker that the request causes (NFR-OBS-01).
6. Per-request timeouts are defined by each operation ([runtime-api.md](../03-reference/runtime-api.md)). Long operations return early (§8.3).
7. Limits: 64 requests in flight per connection, and 8 control connections at once. Above either limit, the request fails with `RuntimeFailure.busy`.

### 8.3 Long-running operations

Long operations return an `OperationHandle { operationID }` at once. `OperationKind` lists them ([runtime-api.md](../03-reference/runtime-api.md) §4.7): store operations (`install`, `uninstall`, `update`, …), `setup`, `resetAndroid`, `runtimeStop`, `runtimeRestart`, image and wrapper operations, and `diagnostics`. Progress and results arrive on the `operations` topic. `cancel(operationID)` is best effort. Each operation documents its cancellation points. Operations outlive their client: a dropped connection does not cancel, but Ctrl-C in `apkrun install` does.

- **Tracked installs.** `beginInstallImported` returns its handle before runtime startup. The daemon holds running operations and the 50 most recent finished ones, with their results, in memory. A matching operation ID and request payload joins the existing operation, so a lost start reply never sends a second PackageInstaller request. Concurrent callers share one runtime-start attempt.
- **Install cancellation.** The Store Agent install is one transaction call with no `CommitInstall` callback. Cancellation is accepted until just before `StoreAgentChannel.install`. RuntimeHost reports `notCancellable` after channel setup, immediately before that call. An app with an open window makes the install fail with `store.packageInUse`; the user closes the window and retries. The guest request is journaled before channel setup. A cancellation or setup failure before the call aborts the entry and keeps the import ticket. After the call starts, PackageStore reconciles the guest result and commits or aborts the journal. This is more conservative than the `CommitInstall` cancellation point of [package-store.md](package-store.md) §5.
- **Forget.** `--forget` is cancellable until the host-only forget transaction is journaled. It never starts Android or closes a session.
- **Package reservation.** `EmbeddedPackageService` reserves the package before it awaits session state or the mutation-boundary callback. An admitted launch drains first. Later launches fail with `store.operationInProgress` until the package mutation returns.
- **Tracked uninstalls.** `beginUninstallPackage` ends the package's session with `.packageUninstalled` before the Store Agent uninstall, and publishes `packages.removed` only after the store transaction commits. The event records the retained-data policy. Operation snapshots carry a fingerprint of the canonical request, so a reconnect can verify the same package and data policy. Stop, restart, reset, and shutdown wait for the uninstall. A launch admitted before it drains before session closure; later launches are rejected until it reaches a terminal result. Before session closure starts, cancellation skips the close and the window stays open. Before `StoreAgentChannel.uninstall`, cancellation appends an abort, and Android is never called. A cancellation that races a close already running may close the window while the package stays installed. `EmbeddedPackageService` holds its package gate through this interval, so no launch can intervene between session closure and the store mutation.
- **Revisions and boot progress.** RuntimeHost reads `RuntimeSupervisor.events` in stream order. Each state carries a monotonic revision, and `runtimeStatus` reads the revisioned snapshot, so a delayed event never rolls status back. Stop transitions keep the `StopReason` in `RuntimeState.stopping(reason)` and in the wire event. While Android boots, RuntimeHost samples `BootProgressEstimator` every 100 ms and publishes `runtime.bootProgress`. Tracked installs publish `started`, install-boundary `progress`, and `finished`. The hub bounds queued events and emits `resyncRequired` when it discards data. RuntimeClient replays subscriptions after a reconnect and reports a resync marker when events may have been missed.

### 8.4 Events

- `subscribe(topics)` registers the client's exported `RuntimeEventSink` for the nine topics of [runtime-api.md](../03-reference/runtime-api.md) §16.1: `runtime`, `sessions`, `packages`, `updates`, `operations`, `health`, `maintenance` ([runtime-maintenance.md](runtime-maintenance.md) §8.3), `wrappers`, and `integrations`. Health results go only to `health`. `unsubscribe(topics)` removes topics. Both are idempotent. The control endpoint verifies the sink before subscribing.
- Stream operations (`guestLog`, `notificationRelay`, `hostNotifications`) deliver items to the same sink under a stream ID. `closeStream(streamID)` ends a stream ([runtime-api.md](../03-reference/runtime-api.md) §16.4).
- Session events (`frameReady`, `surfacesReplaced`, `imeStateChanged`, …) go only to the session's own connection.
- For `runtime` boot progress, `operations` progress, and `health`, only the latest value per key is delivered, at most 10 per second per subscriber. State changes and results are never coalesced. An invalidated subscriber is removed at once.
- A successful install publishes `packages.installed` or `packages.updated`. A successful tracked uninstall publishes `packages.removed`.

### 8.5 The CLI as a client

The CLI uses RuntimeClient like every other client. If apkrund is unregistered (`SMAppService.status != .enabled`), a command that needs it prints `APKRun's background service is not set up. Open APKRun once, or run: apkrun setup` and exits with status 69 (EX_UNAVAILABLE). The full command set is in [cli.md](cli.md).

### 8.6 Runtime, session, and stream operations

The request and reply types are in [runtime-api.md](../03-reference/runtime-api.md). These operations of the control and wrapper endpoints have no other design section:

| Operation | Behavior | Task |
|---|---|---|
| `startRuntime`, `stopRuntime`, `restartRuntime`, `resetRuntime` | The wire names of `ensureReady`, `stop`, `restart`, and `reset` (§3.1). `startRuntime` uses `.cli` for the CLI and `.user` for APKRun.app and the menu bar. `resetRuntime` clears `failed` and the boot-loop guard, and deletes nothing ([runtime-api.md](../03-reference/runtime-api.md) §5.2) | #32 (`startRuntime`, `stopRuntime`), #33 (the others) |
| `runtimeInfo` | `apkrun info` without a package: versions, state, resource use, and display pool size ([cli.md](cli.md) §4.1) | #33, #29 |
| `listSessions` | Open sessions (§7) with package, display, phase, and point size. Used by `apkrun status`, the menu bar, and **Use Current Size** | #33 |
| `restartApp` | Session channel request for Android → Restart ‹App› ([wrapper.md](wrapper.md) §5.6): `StopApplication`, then `LaunchApplication` on the same display. The session stays open | #45 |
| `listOperations` | Running operations and the last 50 finished ones (§8.3). Used by `apkrun operations list` | #33 |
| `unsubscribe`, `closeStream` | Counterparts of `subscribe` and of the stream operations (§8.4) | #33 |

---

## 9. First-run provisioning

### 9.1 Host requirements

`HostRequirementsCheck` (RuntimeHost) returns every failed requirement at once. It runs the DiagnosticsCore host checks (`host.appleSilicon`, `host.macOSVersion`, `host.hypervisor`, `host.dataVolume`, `host.memory`, [diagnostics.md](diagnostics.md) §7.3), which `apkrun doctor` also runs without apkrund. It adds the checks that need Virtualization.framework or the image size:

| Requirement | Check | Failure message (remediation) |
|---|---|---|
| Apple silicon | `sysctl hw.optional.arm64 == 1` and no Rosetta translation (`sysctl.proc_translated == 0`) | "APKRun needs a Mac with Apple silicon" |
| macOS 27 or later | `ProcessInfo.operatingSystemVersion` | "Update macOS" |
| Virtualization available | `VZVirtualMachine.isSupported` (false inside most VMs) | "Virtualization is not available on this Mac (APKRun can't run inside a virtual machine)" |
| APFS volume for the data root | `URLResourceValues.volumeSupportsFileCloning` on `APKRunPaths.root` | "Move APKRun's data to an APFS volume" ([android-image.md](android-image.md) §5.1) |
| Free disk | Expanded image size + 4 GiB (initial userdata) + 10 GiB margin | "Free up ‹n› GB" |
| Memory | Physical memory ≥ 8 GiB. The VM default is lowered to fit 50 % ([vm.md](vm.md) §10) | Warning only |

### 9.2 Flow

The onboarding in [host-ui.md](host-ui.md) and `apkrun setup` run the same steps. Registration must run in APKRun.app, because SMAppService registers the calling app's agent. Everything after it runs in apkrund, as the long-running operation `setup` (§8.3).

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
- On failure the GUI shows the step, the error, and **Try Again** / **Report…**. A failed first boot keeps the instance, so **Try Again** boots again without cloning. After 2 failed first boots, the GUI offers **Start Over**, which sends `setup` with `recreateInstance = true` ([runtime-api.md](../03-reference/runtime-api.md) §5.4).
- Operations that need Android return `RuntimeFailure.notProvisioned` until `complete`. Wrappers show "APKRun needs to finish setup" with an **Open APKRun** button.

### 9.3 Image sources

| Source | When | How |
|---|---|---|
| Local bundle directory, or a `.aar` | Development builds and manual installs | Chosen in the onboarding sheet, with `apkrun setup --image <path>`, or with `apkrun dev image install <dir>`. A `.aar` installs as an archive ([runtime-maintenance.md](runtime-maintenance.md) §4.5) |
| Release feed | Release builds | `ImageFeedClient` selects the newest compatible image of the channel, and `ImageDownloader` downloads it ([runtime-maintenance.md](runtime-maintenance.md) §4.1–§4.5, [android-image.md](android-image.md) §10.4). The onboarding shows the size and a progress bar. First-run downloads ignore the rollout percentage and the expensive-network rule, but ask first on an expensive network |

The image is not bundled inside APKRun.app. Its size would make every APKRun update a multi-GB download.

### 9.5 Reset Android

Settings → Troubleshooting → **Reset Android…**, and `apkrun runtime reset --erase`, delete all Android data. The user must type `Reset`.

1. `stop(.reset, force: true)`.
2. Create a recovery point kept for 7 days, unless the user unticks "Keep a backup for 7 days". No operation restores it in v1 (OQ-41). Settings → Storage and `apkrun image recovery-points` list and delete it.
3. Delete `userdata.img`, provision again ([android-image.md](android-image.md) §5.1), and run the first boot.
4. Provisioning writes a new `userdataGeneration`. After `ready`, APKStoreCore's reconciliation changes every package missing from the new generation from `installed` to `needsReinstall(.userdataReset)` and reinstalls it from `Packages/<id>/current/` under a `storeOperation` assertion ([package-store.md](package-store.md) §9.2). App data is lost. Settings and wrappers stay valid. Adopted packages without an artifact are listed as `broken(.removedInAndroid)` with the Remove action.

---

## 10. Embedded mode

`apkrun dev` runs the runtime in the CLI process. This works in development builds only (`APKRUN_EMBEDDED_RUNTIME`), with the same `RuntimeHost` and logs as apkrund. It does not replace apkrund for other commands: they ask apkrund over XPC (§8.5), and `apkrun launch` asks apkrund, which opens the wrapper or the generic launcher (§7.2). `apkrun dev` refuses to use the user's instance while apkrund holds the lock (§2.3). `apkrun dev power sleep|wake` sends the sleep and wake messages of §6 to a running `apkrun dev boot` ([cli.md](cli.md) §5).

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

Error domain `runtime`. Codes, user messages, and remediations are in [error-catalog.md](../03-reference/error-catalog.md). User-facing text never contains console excerpts. Those go to the diagnostics snapshot (§3.6).

---

## 12. Logging, metrics, health

- Subsystem `io.apkrun.runtime`. Categories: `host` (startup, exit, recovery), `supervisor` (states, boot phases), `agents`, `idle`, `power`, `sessions`, `display` ([display-and-windowing.md](display-and-windowing.md) §10), and `xpc`.
- Perf markers set here. The full list is in [diagnostics.md](diagnostics.md) §4: `DAEMON_READY`, `KERNEL_START`, `ANDROID_INIT`, `SYSTEM_SERVER_READY`, `BOOT_COMPLETED`, `AGENT_CONNECTED`, `RUNTIME_READY`, `VM_PAUSED`, `VM_RESUMED`, `APP_LAUNCH_REQUEST`, `DISPLAY_ATTACHED`, `ACTIVITY_STARTED`, `FIRST_FRAME`. `VM_START` comes from VirtualMachineCore.
- Health checks (DiagnosticsCore `HealthCheck`, used by `apkrun doctor`). The `apkrund.*` checks run in the client, because apkrund cannot report that it is unreachable. The conditions and remediations are in [diagnostics.md](diagnostics.md) §7.3:

| Check | Healthy | Degraded / failing |
|---|---|---|
| `apkrund.registration` | `SMAppService.status == .enabled` | `requiresApproval`, `notRegistered`, `notFound` |
| `apkrund.reachable` | The broker answers `hello` within 5 s with the same API major version | No answer, or an incompatible major version |
| `apkrund.version` | apkrund's build equals the client's build | A different build; `restartPending` while an APKRun update waits for Android to stop ([runtime-maintenance.md](runtime-maintenance.md) §3.6) |
| `apkrund.crashLoop` | Fewer than 3 unclean exits in 10 min | 3 or more (§2.5) |
| `runtime.state` | `ready`, `suspended`, or `stopped` | `failed(f)` with the failure code |
| `runtime.boot` | Last boot within the timeout | Last boot failed (the failure's code), or took more than 2× the median (`runtime.slowBoot`) |
| `runtime.stop` | Last stop graceful | Last 3 stops forced (§3.5): `runtime.stopsForced` |
| `agent.guest`, `agent.store` | `connected` | `reconnecting` for more than 5 s, stopped reconnecting after protocol violations ([guest-protocol.md](guest-protocol.md) §12.2), or restarted 3 times in a minute ([guest-components.md](guest-components.md) §3.3): `runtime.requiredAgentUnavailable`. `incompatible`: `runtime.agentIncompatible` |
| `runtime.memoryPressure` | `normal` | `warning`, `critical` (§5.5): `runtime.hostMemoryPressure` |
| `runtime.provisioning` | `complete` | Incomplete step |

---

## 14. Tests

| Tier | What is tested | Where |
|---|---|---|
| T0 | `RuntimeState` edges ([state-machines.md](../01-architecture/state-machines.md) §2). `IdleController` with a manual clock (activity sources, both timers, settings change, `0` = never, sleep not counted). `BootPhaseDetector` golden tests over captured console logs. `BootProgressEstimator`. `ReplyGuard`. Exit rules | `Packages/RuntimeCore/Tests/RuntimeCoreTests/`, `Packages/RuntimeHost/Tests/RuntimeHostTests/` |
| T1 | `RuntimeHost` startup order with fake modules, including degraded steps. Instance lock contention between two processes. XPC server over `NSXPCListener.anonymous()`: version mismatch, authorization per endpoint kind, the 65th in-flight request, long-operation cancel. `SessionRegistry` with a fake runtime: queued sessions, orphan re-attach, takeover, reconciliation (§4.2) | `Packages/RuntimeHost/Tests/` |
| T2 | Real VM: cold boot to `ready` with markers; stop paths (graceful, power button, forced); agent kill and reconnect with session continuity; suspend and resume with time sync; injected sleep and wake; `kill -9 apkrund` recovery; boot-loop guard with test bundle P, whose kernel panics on a missing init ([test-strategy.md](../04-plan/test-strategy.md) §3.5) | `Tests/IntegrationTests/` |
| T2 | Acceptance: `kill -9` of apkrund during a session restarts it within 15 s, the wrapper reconnects, and HelloText returns by cold launch (NFR-REL-02). Logout with a session stops Android gracefully. Idle: with `runtime.idleSuspendMinutes = 1` the runtime is `suspended` after 1 minute, and the average of 60 `top -l 61 -s 1 -pid <apkrund>` samples is below 1 %. With `runtime.idleStopMinutes = 2` the runtime stops gracefully. A `keepRunning` task, a connected `adb shell`, or a running install prevents suspend. Resume from `suspended` shows the first frame, and `VM_RESUMED → RUNTIME_READY` has p50 ≤ 500 ms over 20 runs. A warm launch writes no boot markers. `apkrun launch io.apkrun.fixture.hellotext` starts HelloText through XPC, the CLI owns no VM, and `apkrun runtime status --json` reports `owner: apkrund`. A binary signed with another identity is rejected at the control endpoint (ADR-0007). A wrapper requesting another package's session gets `notAuthorized` | `Tests/IntegrationTests/` |
| T2 | G6 launcher-window continuity: quit APKRun.app while HelloText is interactive in its APKRunLauncher window, keep it interactive for 5 minutes, and verify an injected tap is answered by its `click <n>` line ([roadmap.md](../04-plan/roadmap.md) §2) | `Tests/IntegrationTests/` |
| T3 | Gate G6 with APKRun.app quit while the launcher window remains open ([roadmap.md](../04-plan/roadmap.md) §2). Warm launch KPI. Real `pmset sleepnow` sleep and wake: the guest clock is within 2 s of the host within 5 s of wake (`adb shell date +%s`). Onboarding on a fresh macOS user account with a local image bundle reaches `complete` without a terminal command, and quitting during `firstBoot` resumes there (checklist C10-3, [test-strategy.md](../04-plan/test-strategy.md) §8) | Manual |

---

## 15. Open items

| Item | Working default |
|---|---|
| Console strings of `BootPhaseDetector` (§3.3) | The patterns in `BootSignals.swift` are the working default. Changing them touches only that table and its golden tests |
| Memory balloon before a pause (§5.3, [OQ-32](../04-plan/open-questions.md)) | No balloon in v1. A balloon is also a fallback of R-08 |
| Pause and resume churn during dark wakes (§6, [OQ-33](../04-plan/open-questions.md)) | Resume on every wake. Fallback: resume lazily on the first request or on `visibilityChanged(true)` |
| Restoring the Reset Android recovery point (§9.5, [OQ-41](../04-plan/open-questions.md)) | No restore in v1. The point can be listed and deleted |
| No VM save and restore while VirGL is active ([R-07](../04-plan/risks.md)) | Accepted. The runtime stays warm with pause and resume (§5). Revisit if a later virglrenderer, or the Venus track (#97), can rebuild the renderer state |
