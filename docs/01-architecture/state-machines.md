# State Machines

This page defines the state enums of APKRun's stateful subsystems and the edges between their states. One actor owns each subsystem's state. The owner changes state only through `transition(to:)`, which checks the edge against the tables below.

An invalid transition is a programming error: `assertionFailure` in debug, and a `…Failure.invalidTransition` fault in release. Each transition is logged at `info` with the operation ID and published as `RuntimeEvent.stateChanged`. Each machine has T0 tests for every allowed and every forbidden edge ([test-strategy.md](../04-plan/test-strategy.md) §2).

---

## 1. VMState (VirtualMachineCore, owner `VMController`)

```swift
enum VMState: Sendable, Equatable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case failed(VMFailure)
}
```

| From | To | Trigger |
|---|---|---|
| stopped | starting | `start()` |
| starting | running | VZ `start` completes successfully |
| starting | failed | VZ `start` fails, or configuration validation fails |
| running | paused | `pause()` (idle policy, sleep) |
| paused | running | `resume()` |
| running, paused | stopping | `stop()` or `requestGuestStop()` |
| stopping | stopped | `guestDidStop`, or the forced stop completed |
| stopping | failed | `virtualMachine(_:didStopWithError:)`, or the forced stop did not complete within 10 s (`.stopTimedOut`) |
| running, paused | failed | `virtualMachine(_:didStopWithError:)` |
| running, paused | stopped | `guestDidStop` (the guest powered off by itself) |
| failed | stopped | `reset()`, after diagnostics were captured |

- Do not stop Android with `requestGuestStop()`. VZ's `requestStop` is a power-button press, which Android treats as "screen off". RuntimeCore asks Android to shut down (Guest Agent `Shutdown`, or `adb shell reboot -p` in development), waits 20 s for `guestDidStop`, then calls `stop()` ([vm.md](../02-design/vm.md) §9.3). `requestGuestStop()` is for the test Linux guest.
- Observe `VZVirtualMachine.state`; never trust it as the only source of truth. VMController maps VZ callbacks to transitions.

## 2. RuntimeState (RuntimeCore, owner `RuntimeSupervisor`)

```swift
enum RuntimeState: Sendable, Equatable {
    case stopped
    case booting(BootPhase)      // .kernel, .init, .systemServer, .bootCompleted, .agentsConnecting
    case ready
    case suspended               // VM paused (idle policy / host sleep)
    case stopping(StopReason)    // Android shutting down (runtime-daemon.md §3.5)
    case failed(RuntimeFailure)
}
```

`BootPhase` refines the progress UI. It comes from the console log (kernel, init) and from ADB and agent readiness (`sys.boot_completed`, agent `Hello`).

| From | To | Trigger |
|---|---|---|
| stopped | booting(.kernel) | First session request, `apkrun runtime start`, or preboot policy |
| booting(p) | booting(p′) | Phase detected. Phases are monotonic: kernel → init → systemServer → bootCompleted → agentsConnecting. A phase with no observable signal may be skipped. |
| booting(.agentsConnecting) | ready | All *required* agents completed the handshake (development: guestd; custom image: guestd and store) |
| booting(*) | failed | Boot timeout (180 s default, configurable) or stall; VM failure; kernel panic or `VIRTUAL_DEVICE_BOOT_FAILED` in the console; agent protocol incompatible ([runtime-daemon.md](../02-design/runtime-daemon.md) §3.2) |
| ready | suspended | Idle policy: no activity for N minutes (default 10, sources in [runtime-daemon.md](../02-design/runtime-daemon.md) §5.1) → `VMController.pause()`; host sleep ([runtime-daemon.md](../02-design/runtime-daemon.md) §6); critical host memory pressure without visible sessions |
| suspended | ready | Session request, activity assertion, or host wake → `resume()` → agents ping OK → clock resync |
| booting, ready, suspended | stopping | `apkrun runtime stop`; idle-stop policy (default 60 min without activity); "Quit APKRun and Stop Android"; logout or `SIGTERM`; image migration; reset |
| stopping | stopped | Android powered off (`guestDidStop`), or the forced stop completed ([runtime-daemon.md](../02-design/runtime-daemon.md) §3.5) |
| stopping | failed | The VM failed during shutdown |
| ready, suspended | failed | VM failure (including a pause or resume error); required agent unreachable for more than 30 s after reconnect attempts; hung-guest watchdog; renderer lost |
| failed | stopped | Automatic after diagnostics capture, or `apkrun runtime reset` |

Invariants:

- `openSession` is accepted in every state except `failed`. In `stopped`, `booting`, `suspended`, and `stopping` it is queued and completes at `ready`; the wrapper shows the placeholder. A session queued during `stopping` starts a new boot after `stopped`.
- `failed` is transient. It lasts while the diagnostics snapshot is captured, then the supervisor resets to `stopped` ([runtime-daemon.md](../02-design/runtime-daemon.md) §3.6).
- There is exactly one RuntimeState per user. v1 has one VM instance.

## 3. AppSessionState (RuntimeCore, owner `SessionRegistry`)

```swift
enum AppSessionState: Sendable, Equatable {
    case requested
    case waitingForRuntime
    case acquiringDisplay
    case launching
    case running
    case backgrounded            // wrapper hidden/minimized: frames throttled
    case closing
    case ended(SessionEndReason) // .userClosed, .appExited, .appCrashed, .runtimeStopped, .updating, .runtimeUpdating, .packageUninstalled, .error(RuntimeFailure)
}
```

| From | To | Trigger |
|---|---|---|
| requested | waitingForRuntime | RuntimeState ≠ ready |
| requested, waitingForRuntime | acquiringDisplay | RuntimeState == ready |
| acquiringDisplay | launching | `DisplayPool.acquire` returned a display |
| acquiringDisplay | ended(.error) | Pool exhausted (`RuntimeFailure.displayPoolExhausted`) |
| launching | running | First committed frame after `LaunchApplication`; embedded development waits for the Guest Agent to report the task visible before capturing the frame watermark |
| launching | ended(.error) | Launch timeout (15 s) or Guest Agent error |
| launching | ended(.appExited) | The task returned by `LaunchApplication` exited before its first frame, and no other package task remains |
| running | backgrounded | Wrapper reported occlusion or minimize |
| backgrounded | running | Wrapper visible again |
| running, backgrounded | closing | Wrapper `closeSession`, or the window closed |
| running, backgrounded | ended(.appExited / .appCrashed) | Guest Agent reports the task removed or the process died |
| closing | ended(.userClosed) | The app's task finished on the display (or a 5 s timeout runs the force-stop policy) |
| any | ended(.runtimeStopped) | RuntimeState → stopped |
| any | ended(.error(f)) | RuntimeState → failed(f) ([runtime-daemon.md](../02-design/runtime-daemon.md) §3.6) |
| running, backgrounded | ended(.updating) | The user chose "Update Now" for this package ([update-system.md](../02-design/update-system.md) §7.3). The window closes, and APKRun reopens the app after the update. |
| any except ended | ended(.runtimeUpdating) | An APKRun or Android system update is about to stop Android ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.5, §4.7). The wrapper shows screen U and opens a new session itself ([wrapper.md](../02-design/wrapper.md) §5.5). Used instead of `.runtimeStopped` for these stops. |
| any except ended | ended(.packageUninstalled) | The package is being uninstalled ([package-store.md](../02-design/package-store.md) §8, step 2a). The wrapper closes and quits. |

- Only one live session per package is allowed. A second `openSession` for the same package returns the existing session, and the wrapper activates its window.
- While `LaunchApplication` is in flight, the registry keeps task events by task ID and waits for the reply. It reconciles the returned task ID with those events, including vanish events that predate the subscription. A different task for the same package cannot end the new launch.

## 4. DisplayState (RuntimeCore, owner `DisplayPool`)

```swift
enum DisplayState: Sendable, Equatable {
    case free                    // scanout disabled, not visible to Android
    case attaching               // hotplug requested; waiting for Android to report the display
    case allocated(SessionID)
    case releasing               // task moved/finished, scanout being disabled
    case faulted(DisplayFault)   // .attachTimedOut, .releaseTimedOut, .graphics(GraphicsFailure)
}
```

| From | To | Trigger |
|---|---|---|
| free | attaching | `acquire()` enables the scanout with the requested mode (GraphicsCore) and signals a display change |
| attaching | allocated | Guest Agent reports `DisplayAdded(displayId, …)` matching the scanout |
| attaching | faulted(.attachTimedOut) | No `DisplayAdded` within 5 s. The pool retries once on another slot ([display-and-windowing.md](../02-design/display-and-windowing.md) §3.3). |
| allocated | releasing | `release()` |
| attaching | releasing | Session cancelled, or Guest Agent disconnected during the attach |
| releasing | free | Scanout disabled and Guest Agent reports `DisplayRemoved` (or a 3 s timeout) |
| faulted | free | Reset of that scanout succeeded |

Display 0 (primary) is not in the pool in `secondaryDisplay` mode. In `primaryDisplayCompatibility` mode it is allocated like any other display, but only one session at a time can hold it.

## 5. PackageState (APKStoreCore, owner `PackageStore`)

```swift
enum PackageState: Sendable, Equatable {
    case importing                        // artifact being copied into incoming/<ticket>/
    case inspecting                       // host inspection and intrinsic checks (package-store.md §4)
    case installing                       // first install, same-version reinstall, repair
    case installed
    case updating(UpdatePhase)            // see §6
    case uninstalling
    case uninstalledKeepingData           // removed from Android with DELETE_KEEP_DATA; record and settings kept
    case needsReinstall(ReinstallReason)  // Android lost the package (Reset Android, recovery point restore)
    case broken(BrokenReason)             // host record and Android disagree in a way that needs the user
}

enum ReinstallReason: Sendable, Equatable { case userdataReset, userdataRestored }

enum BrokenReason: Sendable, Equatable {
    case removedInAndroid                 // absent from Android in the same userdata generation
    case signerChanged                    // Android has the package with a different signer set
    case artifactMissing                  // current/ missing or not matching artifact.json
    case reinstallFailed(StoreFailure)    // needsReinstall failed on three consecutive boots
}
```

Each edge's journal transactions and crash recovery are in [package-store.md](../02-design/package-store.md) §5 and §9.

| From | To | Trigger |
|---|---|---|
| (none) | importing | Add or import of a new package. An import for an installed package goes to UpdateCore as a manual update (§6). |
| (none) | installed | Adoption of an unmanaged Android package (`installer: external`, no artifact) |
| importing | inspecting | Copy and SHA-256 done |
| inspecting | installing | Checks passed, and the user confirmed (or CLI `--yes`) |
| inspecting | (removed) | Checks failed, or the user cancelled. `incoming/<ticket>/` is deleted. |
| installing | installed | Android reports success and the installed version matches |
| installing | (removed) / installed / needsReinstall | First install failed → removed. Same-version reinstall or repair failed → previous state. Reinstall from `needsReinstall` failed → `needsReinstall`, retried on the next boot. |
| installed | updating(...) | UpdateCore begins an update, or the user chooses "Roll back" (`updating(.rollingBack(.userRequested))`) |
| updating | installed | Update finished: updated, rolled back, or kept after a failed health check |
| installed | uninstalling | Uninstall request |
| uninstalling | (removed) | Android uninstall confirmed. The package directory moves to `Packages/.trash/`. |
| uninstalling | uninstalledKeepingData | Android uninstall with "Keep app data" confirmed. APKRun keeps `metadata.json` and `settings.json` and deletes the artifact slots. |
| uninstalling | installed | Android refused, or recovery found the package still installed |
| uninstalledKeepingData | installing | The user reinstalls with an APK from the same signer |
| uninstalledKeepingData | (removed) | "Delete data" (leftover data removed from Android), or "Remove from APKRun" |
| installed | needsReinstall | Reconcile: Android lacks the package, and the record's `userdataGeneration` differs from the instance's |
| needsReinstall | installing | Automatic after `ready`, from `current/` |
| needsReinstall | broken(.reinstallFailed) | The reinstall failed on three consecutive boots |
| installed | broken | Reconcile: removed inside Android in the same userdata generation, signer changed, or `current/` missing |
| broken | installing / installed / (removed) | Repair (reinstall `current/`, or a new import for `artifactMissing`), "Adopt Android's version" (`signerChanged`), or "Remove from APKRun" |
| any except updating | (removed) | "Remove from APKRun" (`forget`) when Android cannot be reached. The package may stay in Android as an unmanaged package. |

## 6. UpdatePhase (UpdateCore, owner `UpdateCoordinator`)

```swift
enum UpdatePhase: Sendable, Equatable {
    case checking
    case available(UpdateCandidate)       // notifyOnly stops here
    case downloading(progress: Double)
    case validating
    case staged                           // waiting for a gentle-install window
    case installing
    case healthChecking
    case rollingBack(RollbackReason)      // .healthCheckFailed(UpdateFailure), .userRequested
    case completed(UpdateOutcome)         // .updated(from:to:), .rolledBack(reason), .keptAfterFailedHealthCheck(reason), .skipped(reason)
}
```

| From | To | Trigger |
|---|---|---|
| checking | available | A provider returned a newer versionCode |
| checking | completed(.skipped(.upToDate)) | Nothing newer |
| checking | completed(.skipped(.checkFailed)) | Provider error. The scheduler backs off ([update-system.md](../02-design/update-system.md) §3.2). |
| available | downloading | Mode `automatic`, or the user pressed "Update" |
| available | completed(.skipped(.userSkipped)) | The user chose "Skip This Version" |
| downloading | validating | Download done |
| downloading | completed(.skipped(.downloadFailed)) | Network error after retries. `incoming/` is deleted. |
| (manual update from a file) | validating | The user imported a newer version of an installed package ([package-store.md](../02-design/package-store.md) §4.7) |
| validating | staged | Checks V0–V6 pass ([update-system.md](../02-design/update-system.md) §6) |
| validating | completed(.skipped(.validationFailed)) | Any check failed. An actionable notification is posted. |
| staged | installing | The gentle-update gate is open, or the user chose "Update Now". The gate needs: runtime ready; no session or keep-running task; a 15 s grace period; `checkInstallConstraints(GENTLE_UPDATE)` passing (or no task on stock images); no other transaction; a display for the health check ([update-system.md](../02-design/update-system.md) §7.1). |
| staged | staged | A scheduled check found a newer candidate. It was downloaded and validated beside the staged set, and replaces it. |
| staged | completed(.skipped(.userSkipped / .authorityChanged)) | The user skipped the version, or the authority changed. The store runs `discardStaged`. |
| installing | staged | The user opened the app before the Android commit was requested. The install is abandoned, and the session opens with the old version ([update-system.md](../02-design/update-system.md) §7.2). |
| installing | healthChecking | Android reports success. The store has already promoted `staged/` → `current/` and `current/` → `previous/`. |
| installing | completed(.skipped(.installFailed)) | Android refused. `PackageInstaller` commits are atomic: the old version is still installed, and nothing was promoted. |
| healthChecking | completed(.updated) | Version confirmed, launch OK, process alive, first frame (headless display) |
| healthChecking | rollingBack(.healthCheckFailed) | A health check failed and `update.autoRollback` is on (default) |
| healthChecking | completed(.keptAfterFailedHealthCheck) | A health check failed and `update.autoRollback` is off. The user is notified with "Roll Back". |
| completed | rollingBack(.userRequested) | The user chose "Roll Back to ‹previous version›" while `previous/` exists |
| completed | checking | The next scheduled or user-initiated check |
| rollingBack | completed(.rolledBack) | The previous version is installed again and verified. Its versionCode is added to the skipped versions. |
| rollingBack | completed(.keptAfterFailedHealthCheck) | No rollback mechanism is available, and the user did not confirm the data-erasing fallback. The new version stays, and the user is notified. |
| rollingBack | (PackageState.broken) | Rollback failed |

Rollback uses Android's `RollbackManager` on custom images, where the update was installed with rollback enabled. On debuggable development images it uses a downgrade reinstall (`adb install-multiple -r -d`). Where neither exists, the previous version can only be restored by uninstalling first, which erases app data and needs the user's confirmation. App data is never reverted to its pre-update state ([package-store.md](../02-design/package-store.md) §7.3, [update-system.md](../02-design/update-system.md) §8).

## 7. RuntimeImageState (ImageCore, owner `ImageStore`)

| State | Meaning |
|---|---|
| `notInstalled` | No image in `Images/` |
| `installing(progress)` | Download, verification, and unpacking of the **first** image (provisioning). Later images install while the state stays `installed(A)`. |
| `installed(version)` | `current` points at a verified image |
| `migrating(from, to)` | Recovery point taken; first boot of the new image in progress |
| `migrationFailed(from, to, ImageFailure)` | Health check failed. Transient: ImageCore restores the recovery point ([android-image.md](../02-design/android-image.md) §12.3, step 6b), then the state is `installed(from)`. |

Edges: `notInstalled → installing → installed`; `installed → migrating → installed(new)` on success; `migrating → migrationFailed → installed(old)` after restore.

Persistence: `installed(version)` is the `Images/current` symlink. `migrating(from, to)` is the `migration` field of `Runtime/instance/instance.json`. It is written before the pointers change and removed last ([android-image.md](../02-design/android-image.md) §12.3). `migrationFailed` is never stored: at startup, a `migration` field means a failed migration.

Android system updates have their own phase machine on top of this one, `ImageUpdatePhase` (idle, checking, available, downloading, installing, ready, applying, failed), owned by `ImageUpdateCoordinator` in RuntimeHost ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.3). Its `applying(A, B)` corresponds to `migrating(A, B)`. The APKRun host has its own `HostState` (`normal`, `updating`, `restartPending`; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6).

## 8. WrapperStatus (WrapperCore, derived, not stored)

`WrapperValidator` computes the status on demand. A status is a state plus a set of refresh reasons.

- `WrapperState`: `valid`; `moved(newURL)` (reported once; the registry is updated); `missing` (including in the Trash); `inaccessible` (macOS privacy controls deny apkrund access); `signatureInvalid`; `unknownPackage`.
- `WrapperRefreshReason` (only with `valid`): `.launcher(version)`, `.icon`, `.displayName`.

Precedence, checks, and UI actions are in [wrapper.md](../02-design/wrapper.md) §9.1. The home screen and `apkrun doctor` use the status.

The registry entry has its own persisted state: `pending` → `active`, and `active` → `refreshing` → `active`. It journals generation and refresh for crash recovery ([wrapper.md](../02-design/wrapper.md) §6.2, §9.3).
