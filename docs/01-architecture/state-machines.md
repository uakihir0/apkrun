# State Machines

| Field | Value |
|---|---|
| Status | Baseline (normative) |
| Related | [overview.md](overview.md), [../02-design/vm.md](../02-design/vm.md), [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md), [../02-design/update-system.md](../02-design/update-system.md) |

Every stateful subsystem has an explicit state enum. It is owned by one actor and changed only through a `transition(to:)` method that validates the edge against the tables below. Invalid transitions are programming errors: `assertionFailure` in debug, logged as a `…Failure.invalidTransition` fault in release. Each transition is logged at `info` with the operation ID and published as an event (`RuntimeEvent.stateChanged`).

Unit tests for every machine assert that each allowed edge works and each forbidden edge is rejected (tier T0).

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
| starting | running | VZ `start` completion success |
| starting | failed | VZ `start` completion error, or configuration validation failure |
| running | paused | `pause()` (idle policy, sleep) |
| paused | running | `resume()` |
| running, paused | stopping | `stop()` / `requestGuestStop()` |
| stopping | stopped | `guestDidStop` or forced stop completed |
| stopping | failed | `virtualMachine(_:didStopWithError:)`, or the forced stop did not complete within 10 s (`.stopTimedOut`) |
| running, paused | failed | `virtualMachine(_:didStopWithError:)` |
| running, paused | stopped | `guestDidStop` (guest powered off by itself) |
| failed | stopped | `reset()` (clears error after diagnostics were captured) |

Notes:

- Android is not stopped with `requestGuestStop()`: VZ's `requestStop` is a power-button press, which Android treats as "screen off". RuntimeCore asks Android to shut down (Guest Agent `Shutdown`, or `adb shell reboot -p` in development), waits 20 s for `guestDidStop`, and then calls `stop()` ([../02-design/vm.md](../02-design/vm.md) §9.3). `requestGuestStop()` is for the test Linux guest.
- `VZVirtualMachine.state` is observed, never trusted as the only source of truth. VMController maps VZ callbacks to transitions.

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

`BootPhase` is a refinement for progress UI. It is detected from the console log (kernel, init) and from ADB/agent readiness signals (`sys.boot_completed`, agent `Hello`).

| From | To | Trigger |
|---|---|---|
| stopped | booting(.kernel) | first session request, `apkrun runtime start`, or preboot policy |
| booting(p) | booting(p′) | phase detected (monotonic: kernel → init → systemServer → bootCompleted → agentsConnecting; a phase whose signal is not observable may be skipped) |
| booting(.agentsConnecting) | ready | all *required* agents completed the handshake (dev: guestd; custom image: guestd + store) |
| booting(*) | failed | boot timeout (180 s default, configurable) or stall, VM failed, kernel panic or `VIRTUAL_DEVICE_BOOT_FAILED` in the console, agent protocol incompatible ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2) |
| ready | suspended | idle policy: no activity for N minutes (default 10; activity sources in [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5.1) → `VMController.pause()`; host sleep (§6 of the same document); critical host memory pressure without visible sessions |
| suspended | ready | session request, activity assertion, or host wake after a sleep-time pause → `resume()` → agents ping OK → clock resync |
| booting, ready, suspended | stopping | `apkrun runtime stop`, idle-stop policy (default 60 min without activity), "Quit APKRun and Stop Android", logout/`SIGTERM`, image migration, reset |
| stopping | stopped | Android powered off (`guestDidStop`), or the forced stop completed ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.5) |
| stopping | failed | the VM failed during the shutdown sequence |
| ready, suspended | failed | VM failed (including a pause/resume error), required agent unreachable > 30 s after reconnect attempts, hung-guest watchdog, renderer lost |
| failed | stopped | automatic after diagnostics capture, or `apkrun runtime reset` |

Invariants:

- `openSession` is accepted in every state except `failed`. In `stopped`, `booting`, `suspended` and `stopping` it is queued and completed when `ready` (the wrapper shows the placeholder). A session queued during `stopping` triggers a new boot after `stopped`.
- `failed` is transient: it lasts while the diagnostics snapshot is captured, then the supervisor resets to `stopped` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.6).
- There is exactly one RuntimeState per user (v1 has one VM instance).

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
| acquiringDisplay | ended(.error) | pool exhausted (`RuntimeFailure.displayPoolExhausted`) |
| launching | running | first frame on the display after `LaunchApplication` |
| launching | ended(.error) | launch timeout (15 s) or Guest Agent error |
| running | backgrounded | wrapper reported occlusion/minimize |
| backgrounded | running | wrapper visible again |
| running, backgrounded | closing | wrapper `closeSession` or window closed |
| running, backgrounded | ended(.appExited / .appCrashed) | Guest Agent reports the task removed or the process died |
| closing | ended(.userClosed) | the app's task finished on the display (or 5 s timeout → force-stop policy) |
| any | ended(.runtimeStopped) | RuntimeState → stopped |
| any | ended(.error(f)) | RuntimeState → failed(f) ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.6) |
| running, backgrounded | ended(.updating) | the user chose "Update Now" for this package ([../02-design/update-system.md](../02-design/update-system.md) §7.3). The wrapper closes its window, and APKRun reopens the app after the update |
| any except ended | ended(.runtimeUpdating) | an APKRun update or an Android system update is about to stop Android ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.5, §4.7). The wrapper shows screen U and opens a new session by itself ([../02-design/wrapper.md](../02-design/wrapper.md) §5.5). It is used instead of `.runtimeStopped` for these stops |
| any except ended | ended(.packageUninstalled) | the package is being uninstalled ([../02-design/package-store.md](../02-design/package-store.md) §8 step 2a). The wrapper closes its window and quits |

Only one live session per package is allowed. A second `openSession` for the same package returns the existing session, and the wrapper just activates its window.

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
| free | attaching | `acquire()` enables the scanout with the requested mode (GraphicsCore) and signals display change |
| attaching | allocated | Guest Agent reports `DisplayAdded(displayId, …)` matching the scanout |
| attaching | faulted(.attachTimedOut) | no `DisplayAdded` within 5 s (the pool retries once on another slot; [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3.3) |
| allocated | releasing | `release()` |
| attaching | releasing | the session was cancelled or the Guest Agent disconnected during the attach |
| releasing | free | scanout disabled and Guest Agent reports `DisplayRemoved` (or 3 s timeout) |
| faulted | free | reset of that scanout succeeded |

Display 0 (primary) is not part of the pool in `secondaryDisplay` mode. In `primaryDisplayCompatibility` mode it is allocated like any other display, but only one session at a time can hold it.

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

The mechanics behind each edge (journal transactions, recovery after a crash) are in [../02-design/package-store.md](../02-design/package-store.md) §5 and §9.

| From | To | Trigger |
|---|---|---|
| (none) | importing | add/import of a new package. An import for an installed package goes to UpdateCore as a manual update (§6) |
| (none) | installed | adoption of an unmanaged Android package (`installer: external`, no artifact) |
| importing | inspecting | copy + SHA-256 done |
| inspecting | installing | checks passed and the user confirmed (or CLI `--yes`) |
| inspecting | (removed) | checks failed or the user cancelled. `incoming/<ticket>/` is deleted |
| installing | installed | Android reports success and the installed version matches |
| installing | (removed) / installed / needsReinstall | failure on first install → removed. Failure on a same-version reinstall or repair → back to the previous state. Failure of a reinstall from `needsReinstall` → `needsReinstall` again, retried on the next boot |
| installed | updating(...) | UpdateCore begins an update, or the user chooses "Roll back" (`updating(.rollingBack(.userRequested))`) |
| updating | installed | update finished (updated, rolled back, or kept after a failed health check) |
| installed | uninstalling | uninstall request |
| uninstalling | (removed) | Android uninstall confirmed. The package directory is moved to `Packages/.trash/` |
| uninstalling | uninstalledKeepingData | Android uninstall with "Keep app data" confirmed. The data stays in Android. APKRun keeps `metadata.json` and `settings.json` and deletes the artifact slots |
| uninstalling | installed | Android refused, or recovery found the package still installed |
| uninstalledKeepingData | installing | the user reinstalls with an APK from the same signer |
| uninstalledKeepingData | (removed) | "Delete data" (the leftover data is removed from Android) or "Remove from APKRun" |
| installed | needsReinstall | reconcile: Android does not have the package and the record's `userdataGeneration` differs from the instance's |
| needsReinstall | installing | automatically after `ready`, from `current/` |
| needsReinstall | broken(.reinstallFailed) | the reinstall failed on three consecutive boots |
| installed | broken | reconcile: removed inside Android in the same userdata generation, signer changed, or `current/` missing |
| broken | installing / installed / (removed) | Repair (reinstall `current/`, or a new import for `artifactMissing`), "Adopt Android's version" (`signerChanged`), or "Remove from APKRun" |
| any except updating | (removed) | "Remove from APKRun" (`forget`) when Android cannot be reached. The package may stay in Android as an unmanaged package |

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
| checking | available | a provider returned a newer versionCode |
| checking | completed(.skipped(.upToDate)) | nothing newer |
| checking | completed(.skipped(.checkFailed)) | provider error. The scheduler backs off ([../02-design/update-system.md](../02-design/update-system.md) §3.2) |
| available | downloading | mode `automatic`, or the user pressed "Update" |
| available | completed(.skipped(.userSkipped)) | the user chose "Skip This Version" |
| downloading | validating | download done |
| downloading | completed(.skipped(.downloadFailed)) | network error after retries. `incoming/` is deleted |
| (manual update from a file) | validating | the user imported a newer version of an installed package ([../02-design/package-store.md](../02-design/package-store.md) §4.7) |
| validating | staged | checks V0–V6 pass ([../02-design/update-system.md](../02-design/update-system.md) §6) |
| validating | completed(.skipped(.validationFailed)) | any check failed (an actionable notification is posted) |
| staged | installing | the gentle-update gate is open (conditions GU1–GU7: runtime ready, no session or keep-running task, 15 s grace, Android `checkInstallConstraints(GENTLE_UPDATE)` or no task on stock images, no other transaction, a display for the health check; [../02-design/update-system.md](../02-design/update-system.md) §7.1), or the user chose "Update Now" |
| staged | staged | a scheduled check found a newer candidate. It was downloaded and validated beside the staged set and replaced it |
| staged | completed(.skipped(.userSkipped / .authorityChanged)) | the user skipped the version, or the authority changed. The store runs `discardStaged` |
| installing | staged | the user opened the app before the Android commit was requested. The install is abandoned, and the session opens with the old version ([../02-design/update-system.md](../02-design/update-system.md) §7.2) |
| installing | healthChecking | Android reports success. The store has already promoted `staged/` → `current/` and `current/` → `previous/` |
| installing | completed(.skipped(.installFailed)) | Android refused the update. `PackageInstaller` commits are atomic, so the old version is still installed and nothing was promoted |
| healthChecking | completed(.updated) | version confirmed, launch OK, process alive, first frame (headless display) |
| healthChecking | rollingBack(.healthCheckFailed) | a health check failed and `update.autoRollback` is on (default) |
| healthChecking | completed(.keptAfterFailedHealthCheck) | a health check failed and `update.autoRollback` is off. The user is notified with "Roll Back" |
| completed | rollingBack(.userRequested) | the user chose "Roll Back to ‹previous version›" while `previous/` exists |
| completed | checking | the next scheduled or user-initiated check |
| rollingBack | completed(.rolledBack) | the previous version is installed again and verified. The rolled-back versionCode is added to the skipped versions |
| rollingBack | completed(.keptAfterFailedHealthCheck) | no rollback mechanism is available and the user has not confirmed the data-erasing fallback. The new version stays installed, and the user is notified |
| rollingBack | (PackageState.broken) | rollback failed |

Rollback uses Android's `RollbackManager` on custom images (the update was installed with rollback enabled) and a downgrade reinstall (`adb install-multiple -r -d`) on debuggable development images. Where neither is available, the previous version can only be restored by uninstalling first, which erases app data and needs the user's confirmation. App data is never reverted to its pre-update state ([../02-design/package-store.md](../02-design/package-store.md) §7.3, [../02-design/update-system.md](../02-design/update-system.md) §8).

## 7. RuntimeImageState (ImageCore, owner `ImageStore`)

| State | Meaning |
|---|---|
| `notInstalled` | no image in `Images/` |
| `installing(progress)` | download, verification, unpack of the **first** image (provisioning). Later images are downloaded and installed while the state stays `installed(A)` |
| `installed(version)` | `current` points at a verified image |
| `migrating(from, to)` | recovery point taken, first boot of the new image in progress |
| `migrationFailed(from, to, ImageFailure)` | health check failed. Transient: ImageCore restores the recovery point automatically ([../02-design/android-image.md](../02-design/android-image.md) §12.3 step 6b), then the state is `installed(from)` |

Edges: `notInstalled → installing → installed`. `installed → migrating → installed(new)` on success, or `migrating → migrationFailed → installed(old)` after restore.

Persistence: `installed(version)` is the `Images/current` symlink. `migrating(from, to)` is the `migration` field of `Runtime/instance/instance.json`, written before the pointers change and removed last ([../02-design/android-image.md](../02-design/android-image.md) §12.3). `migrationFailed` is never stored: at startup, a `migration` field means a failed migration.

Android system updates have their own phase machine on top of this one: `ImageUpdatePhase` (idle, checking, available, downloading, installing, ready, applying, failed), owned by `ImageUpdateCoordinator` in RuntimeHost ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.3). Its `applying(A, B)` corresponds to `migrating(A, B)` here. The APKRun host itself has a `HostState` (`normal`, `updating`, `restartPending`; [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6).

## 8. WrapperStatus (WrapperCore, derived, not stored)

Computed on demand by `WrapperValidator`, never persisted. A status is a state plus a set of refresh reasons:

- `WrapperState`: `valid`, `moved(newURL)` (reported once, the registry is updated), `missing` (including in the Trash), `inaccessible` (macOS privacy controls deny apkrund access), `signatureInvalid`, `unknownPackage`.
- `WrapperRefreshReason` (only with `valid`): `.launcher(version)`, `.icon`, `.displayName`.

Precedence, the checks, and the UI actions are in [../02-design/wrapper.md](../02-design/wrapper.md) §9.1. Used by the home screen and `apkrun doctor`.

The registry entry itself has a small persisted state (`pending` → `active`, `active` → `refreshing` → `active`) that journals generation and refresh for crash recovery ([../02-design/wrapper.md](../02-design/wrapper.md) §6.2 / [../02-design/wrapper.md](../02-design/wrapper.md) §9.3).
