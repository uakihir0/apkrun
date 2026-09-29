# Architecture Overview

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [modules.md](modules.md), [process-model-and-ipc.md](process-model-and-ipc.md), [state-machines.md](state-machines.md), [security-model.md](security-model.md), [decisions/](decisions/) |

This page explains how APKRun fits together. Subsystem details live in [../02-design/](../02-design/).

---

## 1. The four layers

```text
┌──────────────────────────────────────────────────────────────────────┐
│ 1. App Wrapper layer                                                 │
│    Discord.app, Spotify.app …  (thin, immutable, APKRunLauncher)     │
│    APKRun.app (GUI) · APKRunMenuBar · apkrun CLI                     │
├──────────────────────────────────────────────────────────────────────┤
│ 2. Desktop Runtime layer  (apkrund, per-user LaunchAgent)            │
│    RuntimeCore · DisplayPool · GraphicsCore · InputRouter            │
│    IntegrationCore · VirtualMachineCore · ImageCore                  │
├──────────────────────────────────────────────────────────────────────┤
│ 3. Android Runtime layer  (inside the VM)                            │
│    APKRun AOSP product (Cuttlefish arm64 based)                      │
│    Android Framework / ART · SurfaceFlinger · Mesa VirGL             │
│    Guest Agent (apkrun_guestd) · Store Agent (io.apkrun.store)       │
├──────────────────────────────────────────────────────────────────────┤
│ 4. Store & Update layer  (apkrund + Store Agent)                     │
│    APKStoreCore · UpdateCore · UpdateProviders                       │
│    Package Store on disk · PackageInstaller in the guest             │
└──────────────────────────────────────────────────────────────────────┘
```

Layer 4 is split across processes. The decision logic runs on the host (`APKStoreCore`, `UpdateCore`). Execution runs in the guest (Store Agent → `PackageInstaller`).

---

## 2. Component diagram

```text
 Wrapper process (one per open app)          apkrund (one per user)                         Android VM
┌──────────────────────────────┐   XPC    ┌───────────────────────────────────────┐   ┌──────────────────────────────┐
│ APKRunLauncher               │◀────────▶│ RuntimeHost (composition root)        │   │ Linux kernel (GKI arm64)     │
│  WindowingCore  (NSWindow,   │ requests │  RuntimeCore                          │   │  virtio-gpu drm driver       │
│    IOSurface-backed layer)   │ events   │   ├ RuntimeState / readiness          │   │  virtio-blk / net / vsock    │
│  InputCore (NSEvent →        │ IOSurface│   ├ AppSession registry               │   │                              │
│    InputEvent, IME)          │ handles  │   ├ DisplayPool                       │   │ Android userspace            │
│  RuntimeClient               │          │   ├ InputRouter                       │   │  SurfaceFlinger + HWC (drm)  │
└──────────────────────────────┘          │   └ GuestAgentConnection / ADB        │   │  Mesa VirGL (GLES)           │
                                          │  GraphicsCore                         │   │  system_server / ART         │
 APKRun.app / MenuBar / CLI               │   ├ virtio-gpu device model  ◀────────┼──▶│                              │
┌──────────────────────────────┐   XPC    │   ├ virglrenderer + ANGLE (Metal)     │   │  apkrun_guestd  ◀── vsock ──▶│
│ RuntimeClient                │◀────────▶│   └ SurfacePool per scanout           │   │  io.apkrun.store ◀─ vsock ──▶│
└──────────────────────────────┘          │  VirtualMachineCore (VZVirtualMachine)│   │  adbd (dev)      ◀─ vsock ──▶│
                                          │  VirtioDeviceCore (custom virtio)     │   └──────────────────────────────┘
                                          │  ImageCore (runtime images, userdata) │
                                          │  APKStoreCore · UpdateCore            │
                                          │  WrapperCore · IntegrationCore        │
                                          │  DiagnosticsCore (logs, health, perf) │
                                          └───────────────────────────────────────┘
```

---

## 3. Key flows

### 3.1 Frame path (normal operation)

```text
App (GLES) → Mesa VirGL (guest) → virtio-gpu 3D commands (virtqueue)
   → GraphicsCore virtio-gpu device (apkrund) → virglrenderer → ANGLE → Metal
   → scanout texture → 1 GPU blit → IOSurface from the display's SurfacePool
   → XPC event "frame ready (surface index)" → wrapper sets layer.contents
```

- The normal path has no CPU readback (NFR-PERF-05). At most one GPU blit per frame. RiftVM measures the same approach at 0.4–0.8 ms per present.
- IOSurfaces are allocated once per display, triple buffered, and sent to the wrapper once as XPC objects. After that only the surface index is sent per frame ([decisions/0006-wrapper-owned-window-iosurface.md](decisions/0006-wrapper-owned-window-iosurface.md)).
- Details: [../02-design/graphics.md](../02-design/graphics.md), [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md).

### 3.2 Input path

```text
NSEvent (wrapper process) → InputCore → InputEvent (display pixel coordinates)
   → XPC session.sendInput → apkrund InputRouter (checks: session owns display)
   → GuestProtocol InputFrame on the input stream (vsock)
   → apkrun_guestd → InputManager.injectInputEvent(displayId = N)
IME: NSTextInputClient → committed / marked text → GuestProtocol ImeText
   → APKRun IME service (InputMethodService) → InputConnection.commitText / setComposingText
```

- A host-implemented virtio-input device is not possible (research, [decisions/0013-input-via-guest-injection.md](decisions/0013-input-via-guest-injection.md)). Cuttlefish itself uses vhost-user virtio-input, which VZ cannot provide.
- In production the vsock connection ends at `apkrun_vsockd`, which splices it to the Guest Agent's local socket. Android SELinux forbids app domains from using vsock ([process-model-and-ipc.md](process-model-and-ipc.md) §3.1).
- Before the Guest Agent runs as a system component (M5), it runs as an `app_process` program started over ADB. Its stream is carried over an ADB-forwarded socket ([../02-design/input.md](../02-design/input.md)).

### 3.3 Warm launch (VM running, Android ready)

```text
user opens Discord.app
 → APKRunLauncher reads wrapper.json, connects to io.apkrun.apkrund.xpc
 → openSession(packageId)            (auth: bundle ID ↔ packageId, see security-model.md)
 → RuntimeCore: package installed? RuntimeState == ready?
 → DisplayPool.acquire(config from window prefs & screen scale)
 → surfaces shared with the wrapper; the wrapper's window (created hidden at startup) is attached
 → Guest Agent: LaunchApplication(package, displayId)
 → first frame on scanout → FIRST_FRAME marker → window ordered front
   (if no frame arrives within 400 ms, the window is shown earlier with the placeholder)
 (async, never on this path) UpdateCore.noteLaunched(package)
```

KPI: click → first frame, p50 ≤ 1.5 s (NFR-PERF-01, provisional).

### 3.4 Cold launch (VM stopped)

```text
 … openSession(packageId)
 → RuntimeState stopped → start VM (VMController.start)
 → wait: kernel → init → system_server → boot_completed → guest agents connected
 → continue as warm launch
```

The wrapper shows a native "Starting Android runtime…" placeholder window during boot. It never shows Android UI. VM save/restore for fast cold launch is **not** available while VirGL is used (host renderer state cannot be serialized; R-07).

### 3.5 Install (first time)

```text
APK/APKS/XAPK dropped on APKRun.app  (or `apkrun install`, `apkrun wrap --install`)
 → APKStoreCore: import to Packages/<id>/incoming/, host preview (APKInspector)
 → Store Agent: analyze archive (canonical metadata), validate
 → Store Agent: PackageInstaller session (setRequestUpdateOwnership if authority == apkrun)
 → commit Packages/<id>/current/, write metadata.json
 → (optional) WrapperCore generates <Name>.app with icon rendered by the Store Agent
```

### 3.6 Automatic update

```text
UpdateScheduler (every 6 h ± jitter, never on the launch path)
 → provider.check → UpdateCandidate → download → validation pipeline (package, versionCode,
   signer lineage, ABI, SDK, split set, SHA-256) → Packages/<id>/staged/
 → gentle: wait until the runtime is running anyway, the app has no session or keep-running task,
   and Android InstallConstraints GENTLE_UPDATE agrees (never closes an app by itself)
 → Store Agent install with rollback enabled (same session rules)
 → promote: current → previous, staged → current (the directories always mirror Android)
 → health check (version, launch, process, first frame)
 → failure: roll back to previous (Android RollbackManager; app data is not reverted)
```

Store mechanics (journal, promotion, rollback per image kind) are in [../02-design/package-store.md](../02-design/package-store.md) §5–§7. Policy (schedule, gentle window, health check) is in [../02-design/update-system.md](../02-design/update-system.md).

The wrapper is never touched ([decisions/0009-thin-immutable-wrappers.md](decisions/0009-thin-immutable-wrappers.md)).

---

## 4. Where state lives

| State | Owner | Location |
|---|---|---|
| VM instance, disks, userdata | ImageCore / VirtualMachineCore | `~/Library/Application Support/APKRun/Runtime/` |
| Runtime images | ImageCore | `~/Library/Application Support/APKRun/Images/` |
| Package artifacts + metadata | APKStoreCore | `~/Library/Application Support/APKRun/Packages/<id>/` |
| User settings per package | APKStoreCore (settings store) | `…/Packages/<id>/settings.json` |
| Wrapper registry | WrapperCore | `…/APKRun/Wrappers/registry.json` |
| Update schedule, cursors, history | UpdateCore | `…/APKRun/Updates/` |
| Logs | DiagnosticsCore | `~/Library/Logs/APKRun/` |
| Wrapper bundle | Immutable after generation | wherever the user chose (`/Applications`, `~/Applications`) |
| Canonical package metadata | Android PackageManager | guest `/data` |

Full layout: [filesystem-layout.md](filesystem-layout.md).

---

## 5. Technology choices and their records

| Decision | ADR |
|---|---|
| Real Android in a VM, never an API compatibility layer | [0001](decisions/0001-real-android-in-vm.md) |
| Virtualization.framework on macOS 27+ (custom virtio) | [0002](decisions/0002-virtualization-framework-macos27.md) |
| Cuttlefish arm64 as the guest base | [0003](decisions/0003-cuttlefish-base-image.md) |
| VirGL (GLES) first, Vulkan later | [0004](decisions/0004-virgl-first-graphics.md) |
| One Android display ↔ one NSWindow via multi-display | [0005](decisions/0005-multi-display-window-model.md) |
| apkrund renders; wrapper owns the window via IOSurface | [0006](decisions/0006-wrapper-owned-window-iosurface.md) |
| apkrund as per-user LaunchAgent, XPC API | [0007](decisions/0007-apkrund-launchagent-xpc.md) |
| Two Kotlin guest agents | [0008](decisions/0008-guest-agents.md) |
| Thin immutable wrappers | [0009](decisions/0009-thin-immutable-wrappers.md) |
| Update authority separated from update provider | [0010](decisions/0010-update-authority-provider-split.md) |
| Prebuilt runtime image bundle consumed by the Mac runtime | [0011](decisions/0011-runtime-image-bundle.md) |
| Module set and dependency rules | [0012](decisions/0012-module-set.md) |
| Input via guest-side injection | [0013](decisions/0013-input-via-guest-injection.md) |
| Protocol Buffers guest protocol, host-initiated vsock via a native bridge | [0014](decisions/0014-protobuf-guest-protocol.md) |
| Direct kernel boot with VZLinuxBootLoader (no U-Boot); APKRun assembles cmdline, bootconfig and GPT disks | [0015](decisions/0015-direct-kernel-boot.md) |

---

## 6. Cross-cutting rules

1. **Explicit state machines** for VM, runtime, sessions, displays, packages, and updates ([state-machines.md](state-machines.md)). Never infer state from `nil` checks.
2. **Swift concurrency.** Stateful services are `actor`s. DTOs are `Sendable` value types. Swift 6 language mode with strict concurrency checking is on for every target.
3. **Typed errors** per domain (`VMFailure`, `GraphicsFailure`, `RuntimeFailure`, `StoreFailure`, `UpdateFailure`, `WrapperFailure`, `GuestProtocolFailure`, `ImageFailure`, `IntegrationFailure`, `MaintenanceFailure`, `DiagnosticsFailure`, `CLIFailure`; [../02-design/diagnostics.md](../02-design/diagnostics.md) §2). Each has a stable code and a remediation ([../03-reference/error-catalog.md](../03-reference/error-catalog.md)).
4. **Operation IDs** flow through every user-visible operation, across XPC and into the guest ([../02-design/diagnostics.md](../02-design/diagnostics.md)).
5. **Health everywhere.** Each subsystem exposes a `HealthCheck`. `apkrun doctor` aggregates them.
6. **The launch path does no work that isn't needed**: no update checks, no network, no wrapper validation beyond reading `wrapper.json`.
7. **Security by policy.** Every host capability exposed to the guest goes through IntegrationCore's policy check ([security-model.md](security-model.md)).
