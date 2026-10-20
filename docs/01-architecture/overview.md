# Architecture Overview

This page shows how the parts of APKRun fit together: the layers, the processes, the main flows, and where state lives. Module owners and dependency rules are in [modules.md](modules.md). Subsystem details are in [../02-design/](../02-design/).

---

## 1. The four layers

```text
┌──────────────────────────────────────────────────────────────────────┐
│ 1. App wrapper layer                                                 │
│    Discord.app, Spotify.app … (thin, immutable, APKRunLauncher)      │
│    APKRun.app (GUI) · APKRunMenuBar · apkrun CLI                     │
├──────────────────────────────────────────────────────────────────────┤
│ 2. Desktop runtime layer  (apkrund, per-user LaunchAgent)            │
│    RuntimeCore · DisplayPool · GraphicsCore · InputRouter            │
│    IntegrationCore · VirtualMachineCore · ImageCore                  │
├──────────────────────────────────────────────────────────────────────┤
│ 3. Android runtime layer  (inside the VM)                            │
│    APKRun AOSP product (Cuttlefish arm64 based)                      │
│    Android framework / ART · SurfaceFlinger · Mesa VirGL             │
│    Guest Agent (apkrun_guestd) · Store Agent (io.apkrun.store)       │
├──────────────────────────────────────────────────────────────────────┤
│ 4. Store and update layer  (apkrund + Store Agent)                   │
│    APKStoreCore · UpdateCore (providers)                             │
│    Package store on disk · PackageInstaller in the guest             │
└──────────────────────────────────────────────────────────────────────┘
```

Layer 4 is split across processes. The decisions run on the host (`APKStoreCore`, `UpdateCore`). Execution runs in the guest (Store Agent → `PackageInstaller`).

---

## 2. Processes

| Process | Modules inside |
|---|---|
| Wrapper (`APKRunLauncher`), one per open app | WindowingCore, InputCore, RuntimeClient |
| `apkrund` (LaunchAgent, one per user) | RuntimeHost (composition root), RuntimeCore, GraphicsCore, VirtualMachineCore, VirtioDeviceCore, ImageCore, APKStoreCore, UpdateCore, WrapperCore, IntegrationCore, DiagnosticsCore |
| APKRun.app, APKRunMenuBar, `apkrun` CLI | RuntimeClient, RuntimeAPI |
| Android VM (run by apkrund) | Linux kernel, Android userspace, `apkrun_guestd`, `io.apkrun.store`, `apkrun_vsockd`, `adbd` (development) |

Clients reach apkrund over XPC. apkrund reaches the guest over vsock and virtio. Process and channel details are in [process-model-and-ipc.md](process-model-and-ipc.md) §1 to §3.

---

## 3. Key flows

### 3.1 Frame path

```text
App (GLES) → Mesa VirGL (guest) → virtio-gpu 3D commands (virtqueue)
   → GraphicsCore virtio-gpu device (apkrund) → virglrenderer → ANGLE → Metal
   → scanout texture → 1 GPU blit → IOSurface from the display's SurfacePool
   → XPC event "frame ready (surface index)" → wrapper sets layer.contents
```

- The normal path has no CPU readback (NFR-PERF-05). It makes at most one GPU blit per frame.
- IOSurfaces are allocated once per display, triple buffered, and sent to the wrapper once. Each frame then sends only the surface index ([decisions/0006-wrapper-owned-window-iosurface.md](decisions/0006-wrapper-owned-window-iosurface.md)).
- Details: [graphics.md](../02-design/graphics.md) §6 and [display-and-windowing.md](../02-design/display-and-windowing.md) §5.

### 3.2 Input path

```text
NSEvent (wrapper process) → InputCore → InputEvent (display pixel coordinates)
   → XPC session.sendInput → apkrund InputRouter (checks: session owns display)
   → GuestProtocol InputFrame on the input stream (vsock)
   → apkrun_guestd → InputManager.injectInputEvent(displayId = N)
IME: NSTextInputClient → committed / marked text → GuestProtocol ImeText
   → APKRun IME service (InputMethodService) → InputConnection.commitText / setComposingText
```

- `adb shell input` is for early validation only. The production path never runs a shell command per event (FR-IN-06).
- There is no host-side virtio-input device. The macOS 27 virtio API cannot provide one ([decisions/0013-input-via-guest-injection.md](decisions/0013-input-via-guest-injection.md)).
- In production, the vsock connection ends at `apkrun_vsockd`. Stock development images use an ADB forward instead ([process-model-and-ipc.md](process-model-and-ipc.md) §3.1).

### 3.3 Warm launch (VM running, Android ready)

```text
user opens Discord.app
 → APKRunLauncher reads wrapper.json, connects to io.apkrun.apkrund.xpc
 → openSession(packageId)            (auth: bundle ID ↔ packageId, security-model.md §3.1)
 → RuntimeCore: package installed? RuntimeState == ready?
 → DisplayPool.acquire(config from window prefs & screen scale)
 → surfaces shared with the wrapper; the wrapper's window (created hidden at startup) is attached
 → Guest Agent: LaunchApplication(package, displayId)
 → first frame on scanout → FIRST_FRAME marker → window ordered front
   (no frame within 400 ms: the window is shown earlier with the placeholder)
 (async, off this path) UpdateCore.noteLaunched(package)
```

KPI: click to first frame, p50 ≤ 1.5 s (NFR-PERF-01, provisional).

### 3.4 Cold launch (VM stopped)

The warm launch starts after the VM boots. The wrapper shows a native "Starting Android runtime…" placeholder during boot and never shows Android UI.

```text
 … openSession(packageId) → RuntimeState stopped → VMController.start
 → kernel → init → system_server → boot_completed → guest agents connected
 → continue as warm launch
```

VM save and restore for fast cold launch is not available while VirGL is used, because the host renderer state cannot be serialized (R-07).

### 3.5 Install (first time)

```text
APK/APKS/XAPK dropped on APKRun.app  (or `apkrun install`, or `apkrun wrap app.apk --install`)
 → APKStoreCore: import to Packages/<id>/incoming/, host preview (APKInspector)
 → Store Agent: analyze archive (canonical metadata), validate
 → Store Agent: PackageInstaller session (setRequestUpdateOwnership if authority == apkrun)
 → commit Packages/<id>/current/, write metadata.json
 → (optional) WrapperCore generates <Name>.app with icon rendered by the Store Agent
```

### 3.6 Automatic update

```text
UpdateScheduler (every 6 h ± jitter, never on the launch path)
 → provider.check → UpdateCandidate → download → validation pipeline (package ID, versionCode, signer lineage, ABI, SDK, split set, SHA-256)
   → Packages/<id>/staged/
 → gentle: runtime running, no session or keep-running task, and Android
   InstallConstraints GENTLE_UPDATE agrees (never closes an app by itself)
 → Store Agent install with rollback enabled
 → promote: current → previous, staged → current
 → health check (version, launch, process, first frame)
 → failure: roll back to previous (Android `RollbackManager`; app data is not reverted)
```

Store mechanics are in [package-store.md](../02-design/package-store.md) §5–§7. Policy (schedule, gentle window, health check) is in [update-system.md](../02-design/update-system.md) §3, §6, and §7. The wrapper is never touched ([decisions/0009-thin-immutable-wrappers.md](decisions/0009-thin-immutable-wrappers.md)).

---

## 4. Where state lives

| State | Owner | Location |
|---|---|---|
| VM instance, disks, userdata | ImageCore / VirtualMachineCore | `~/Library/Application Support/APKRun/Runtime/` |
| Runtime images | ImageCore | `~/Library/Application Support/APKRun/Images/` |
| Package artifacts and metadata | APKStoreCore | `~/Library/Application Support/APKRun/Packages/<id>/` |
| User settings per package | APKStoreCore | `…/Packages/<id>/settings.json` |
| Wrapper registry | WrapperCore | `…/APKRun/Wrappers/registry.json` |
| Update schedule, cursors, history | UpdateCore | `…/APKRun/Updates/` |
| Logs | DiagnosticsCore | `~/Library/Logs/APKRun/` |
| Wrapper bundle | Immutable after generation | Where the user chose (`/Applications`, `~/Applications`) |
| Canonical package metadata | Android PackageManager | Guest `/data` |

Full layout: [filesystem-layout.md](filesystem-layout.md).

---

## 5. Technology choices

Each significant decision is an ADR. The index is in [decisions/README.md](decisions/README.md). The decisions are:

| Decision | ADR |
|---|---|
| Decision | ADR |
|---|---|
| Real Android in a VM, never an API compatibility layer | [0001](decisions/0001-real-android-in-vm.md) |
| Virtualization.framework on macOS 27+ with custom virtio devices | [0002](decisions/0002-virtualization-framework-macos27.md) |
| AOSP Cuttlefish arm64 as the guest base | [0003](decisions/0003-cuttlefish-base-image.md) |
| VirGL (GLES) first, Vulkan later | [0004](decisions/0004-virgl-first-graphics.md) |
| One Android display per macOS window | [0005](decisions/0005-multi-display-window-model.md) |
| The wrapper owns the window; apkrund renders into shared IOSurfaces | [0006](decisions/0006-wrapper-owned-window-iosurface.md) |
| apkrund is a per-user LaunchAgent with an XPC API | [0007](decisions/0007-apkrund-launchagent-xpc.md) |
| Two Kotlin guest agents plus a native vsock bridge | [0008](decisions/0008-guest-agents.md) |
| Thin, immutable wrappers | [0009](decisions/0009-thin-immutable-wrappers.md) |
| Update authority separated from update provider | [0010](decisions/0010-update-authority-provider-split.md) |
| Prebuilt runtime image bundle | [0011](decisions/0011-runtime-image-bundle.md) |
| Module set and dependency rules | [0012](decisions/0012-module-set.md) |
| Input by guest-side injection | [0013](decisions/0013-input-via-guest-injection.md) |
| Protobuf guest protocol over host-initiated vsock | [0014](decisions/0014-protobuf-guest-protocol.md) |
| Direct kernel boot with VZLinuxBootLoader (no U-Boot) | [0015](decisions/0015-direct-kernel-boot.md) |

---

## 6. Cross-cutting rules

1. **Explicit state machines.** VM, runtime, sessions, displays, packages, and updates each have an explicit state enum ([state-machines.md](state-machines.md)). Never infer state from `nil` checks.
2. **Swift concurrency.** Stateful services are `actor`s. DTOs are `Sendable` value types. Swift 6 language mode with strict concurrency checking is on for every target.
3. **Typed errors per domain.** `VMFailure`, `GraphicsFailure`, `RuntimeFailure`, `StoreFailure`, `UpdateFailure`, `WrapperFailure`, `GuestProtocolFailure`, `ImageFailure`, `IntegrationFailure`, `MaintenanceFailure`, `DiagnosticsFailure`, and `CLIFailure` ([diagnostics.md](../02-design/diagnostics.md) §2). Each has a stable code and a remediation ([error-catalog.md](../03-reference/error-catalog.md)).
4. **Operation IDs.** Every user-visible operation has an operation ID. It flows across XPC and into the guest ([diagnostics.md](../02-design/diagnostics.md) §2.4).
5. **Health everywhere.** Each subsystem exposes a `HealthCheck`. `apkrun doctor` aggregates them ([diagnostics.md](../02-design/diagnostics.md) §7).
6. **The launch path does no unneeded work.** No update checks, no network, and no wrapper validation beyond reading `wrapper.json`.
7. **Security by policy.** Every host capability exposed to the guest goes through the policy check in IntegrationCore ([security-model.md](security-model.md) §6).
