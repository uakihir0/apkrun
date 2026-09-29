# Modules, Ownership, and Dependencies

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [overview.md](overview.md), [process-model-and-ipc.md](process-model-and-ipc.md), [decisions/0012-module-set.md](decisions/0012-module-set.md) |

This document is normative. A change to a module's ownership or to the allowed dependency graph requires an ADR.

---

## 1. Repository layout

```text
apkrun/
├── AGENTS.md                 # rules for implementers (humans and AI agents)
├── CLAUDE.md                 # points to AGENTS.md
├── README.md
├── Package.swift             # single SwiftPM manifest for all Packages/* targets + CLI
├── project.yml               # XcodeGen spec for app/daemon/launcher targets (see build-system.md)
│
├── Apps/
│   ├── APKRun/               # main GUI app (SwiftUI)
│   ├── APKRunMenuBar/        # menu bar extra (login item)
│   └── APKRunLauncher/       # the wrapper executable (AppKit)
│
├── Daemon/
│   └── apkrund/              # LaunchAgent executable (thin main; logic in RuntimeHost)
│
├── CLI/
│   └── apkrun/               # swift-argument-parser CLI
│
├── Packages/                 # Swift library targets (one directory per module)
│   ├── DiagnosticsCore/
│   ├── VirtioDeviceCore/
│   ├── VirtualMachineCore/
│   ├── GraphicsCore/         # includes GraphicsBridge (C / Objective-C++ target)
│   ├── InputCore/
│   ├── WindowingCore/
│   ├── GuestProtocol/        # .proto sources + generated Swift + framing
│   ├── ImageCore/
│   ├── RuntimeAPI/
│   ├── RuntimeCore/
│   ├── RuntimeClient/
│   ├── RuntimeHost/
│   ├── APKStoreCore/
│   ├── UpdateCore/
│   ├── WrapperCore/
│   └── IntegrationCore/
│       # each module: Sources/<Module>/ and Tests/<Module>Tests/ (T0), Tests/<Module>SystemTests/ (T1),
│       # Tests/<Module>TestSupport/ (fakes), Tests/<Module>Fuzz/ (only with APKRUN_FUZZ=1); build-system.md §2.1
│
├── Guest/                    # everything that runs inside Android (one Gradle build for the Kotlin parts)
│   ├── protocol/             # Kotlin: generated protobuf lite + frame codec (from Packages/GuestProtocol/proto)
│   ├── agentruntime/         # Kotlin: shared runtime of both agents: system-service wrappers, socket server, peer checks, logging
│   ├── guestd/               # Guest Agent (Kotlin): package io.apkrun.guest, process apkrun_guestd
│   ├── APKRunStore/          # Store Agent (Kotlin): package io.apkrun.store
│   ├── vsockd/               # apkrun_vsockd (Rust): vsock ↔ agent local-socket bridge (custom image only)
│   └── product/              # AOSP product: device makefiles, init .rc, sepolicy, overlays, permissions
│
├── Images/
│   ├── manifests/            # committed per build: <buildId>/inventory.json and android-image.json
│   ├── reference/            # committed Cuttlefish reference captures (<buildId>/) and VZ topology (vz/)
│   └── tools/                # Python tooling: inventory, boot image extraction, bootconfig, disk assembly, bundling
│
├── ThirdParty/
│   ├── ThirdParty.lock.json  # pinned revisions, licenses, flags, patches
│   ├── patches/<name>/*.patch
│   └── build/                # build scripts for virglrenderer, ANGLE, …
│
├── Tests/
│   ├── IntegrationTests/     # Swift tests that need a real VM (tier T2), one <Area>Tests/ each, including SecurityTests/
│   ├── AcceptanceTests/      # scripted gate checks (tier T3)
│   ├── PerformanceTests/     # apkrun-perf harness and per-Mac baselines (diagnostics.md §9)
│   ├── Compatibility/        # compatibility runs, app list, and the compatibility database source (diagnostics.md §10)
│   └── Fixtures/
│       ├── AndroidApps/      # Gradle project: HelloText, HelloCompose, HelloGL, …
│       ├── fuzz/<target>/    # fuzz seed corpora and crash reproducers (test-strategy.md §7.2)
│       ├── signing/          # test-only keystores (never production keys)
│       └── update-repos/     # LocalProvider / Direct / F-Droid / GitHub fixtures
│
├── Experiments/              # spikes; never imported by production targets
├── scripts/                  # developer scripts (bootstrap, lint, fetch artifacts, run gates)
└── docs/                     # the specification (docs/README.md); docs/releases/ holds the release notes
```

Forbidden: generic dumping grounds such as `Common/`, `Utils/`, `Helpers/`, `Misc/`. A shared abstraction needs a named owner module.

---

## 2. Module catalogue

Each module has one owner boundary. "Must not" rules are enforced in code review and by the dependency graph (§3).

### DiagnosticsCore
- **Owns:** logging facade over `os.Logger` with the fixed subsystems, `OperationID`, the `APKRunError` protocol (domain, code, remediation), signpost-based metrics (`PerfMarker`), the health model (`HealthReport`, `HealthCheck`), doctor check framework, diagnostics bundle writer and redaction.
- **Must not:** depend on any other APKRun module.

### VirtioDeviceCore
- **Owns:** the adapter over Virtualization.framework's custom virtio device API; feature negotiation; config space; virtqueue descriptor-chain parsing and completion; shared-memory region mapping; a `VirtioDeviceModel` protocol that concrete devices implement.
- **Must not:** know about GPUs, input, Android, or packages. It is device-agnostic plumbing.

### VirtualMachineCore
- **Owns:** `VZVirtualMachine`, `VZVirtualMachineConfiguration`, CPU, memory, boot loader, block devices, network, vsock, serial/console ports, memory balloon, entropy, sound device attachment, VM lifecycle (`VMController`), `VMState`, `VMDefinition` and its validation.
- **Consumes:** `VirtioDeviceModel` instances handed in through `VMDefinition` (it attaches them, it does not implement them).
- **Must not:** know about APKs, Android package names, or Android image file names.

### GraphicsCore
- **Owns:** the virtio-gpu device model (a `VirtioDeviceModel`), virtio-gpu command handling, resources and backing, scanouts, cursor, the VirGL/virglrenderer/ANGLE bridge (through the `GraphicsBridge` C target), Metal presentation into IOSurface pools, frame statistics, readback counters.
- **Must not:** know about Android package names or windows. It exposes scanouts as `ScanoutID` → `SurfacePool`.

### InputCore
- **Owns:** the host input event model (`InputEvent`), translation from `NSEvent` (pointer, scroll, key, modifiers, text), coordinate mapping (window points → display pixels), gesture state (touch slop, scroll accumulation), shortcut mapping (Esc → BACK, Cmd+C → copy …), and the IME text model (committed / marked text).
- **Must not:** know about packages, transports, or the guest. It knows displays only by `DisplayID`. Delivery to Android is RuntimeCore's `InputRouter` → GuestProtocol → Guest Agent ([decisions/0013-input-via-guest-injection.md](decisions/0013-input-via-guest-injection.md)). A host-side virtio-input device is not possible with the macOS 27 custom virtio API (no config-space write callback).

### WindowingCore
- **Owns:** `NSWindow` lifecycle for app sessions, the layer that presents an IOSurface pool (a plain `CALayer` whose `contents` is the IOSurface, [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §5.3), window geometry, Retina scale reporting, fullscreen, resize, focus, first-responder handling for input and `NSTextInputClient` (IME).
- **Must not:** own the VM or talk to the guest. It receives frames through a `FrameSource` protocol and emits input through an `InputSink` protocol.

### GuestProtocol
- **Owns:** `.proto` definitions for host ↔ guest messages, generated Swift code, framing codec (length-prefixed frames), protocol version constants, compatibility rules.
- **Must not:** contain business logic, networking, or state.

### ImageCore
- **Owns:** runtime image manifests (`AndroidImageManifest`, `RuntimeImageManifest`), the installed image store (A/B pointers), integrity verification, userdata creation, APFS clone-based recovery points, and translating an image + instance into the Android-specific parts of a `VMDefinition` (kernel, initrd, cmdline, disk list). For Android system updates it also owns the image feed client (`ImageFeedClient`), resumable archive downloads (`ImageDownloader`), and safe archive extraction ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1–§4.5).
- **Must not:** start VMs. It produces data that `VirtualMachineCore` consumes. It does not decide when an update is applied: that is `ImageUpdateCoordinator` in RuntimeHost.
- Build-time image tooling is Python under `Images/tools/`; `ImageCore` only consumes the finished runtime image bundle ([decisions/0011-runtime-image-bundle.md](decisions/0011-runtime-image-bundle.md)).

### RuntimeAPI
- **Owns:** the XPC contract between clients and `apkrund`: request/response/event DTOs (`Codable`, `Sendable`), the `@objc` XPC protocols, API version constants, the `RuntimeService` Swift protocol that both the XPC client and the embedded host implement.
- **Must not:** contain logic. Foundation + IOSurface only.

### RuntimeCore
- **Owns:** Android runtime state (`RuntimeState`), readiness monitoring, app sessions (launch / stop / session lifecycle), `DisplayPool`, `InputRouter` (per-session input → guest, with display ownership checks), the Android control channel abstraction (`AndroidControlChannel` with ADB and GuestProtocol implementations), `AdbClient` (the development `adb` wrapper, #015), guest agent connection management and handshake, vsock port plan.
- **Must not:** implement install/update policy (that is APKStoreCore / UpdateCore), generate wrappers, or render.

### RuntimeClient
- **Owns:** the XPC client (`XPCRuntimeService: RuntimeService`), reconnection, launching APKRun.app when the agent is not registered, client-side session objects that deliver frames and accept input as RuntimeAPI wire types. It imports neither WindowingCore nor InputCore: the launcher's `XPCFrameSource` and `XPCInputSink` adapt a session object to WindowingCore's `FrameSource` and `InputSink` and convert InputCore values to wire values ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §1).
- **Used by:** APKRunLauncher, APKRun.app, APKRunMenuBar, apkrun CLI.

### RuntimeHost
- **Owns:** the composition root: constructs and wires all daemon-side modules, owns startup/recovery ordering, implements `RuntimeService` for in-process use (`EmbeddedRuntimeService`), and exports it over XPC in `apkrund`. It also owns runtime maintenance: `MaintenanceService` (host state, the host-update marker, the `.maintenance` endpoint), `SelfUpdateProbe`, `BundleWatcher`, and `ImageUpdateCoordinator` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §1).
- **Used by:** `apkrund` (always) and the `apkrun` CLI in embedded/development mode (before #031 and for debugging afterwards).

### APKStoreCore
- **Owns:** installed package records (`metadata.json`) and per-package settings (`settings.json`), `PackageArtifact`, the on-disk package directories (`current/`, `previous/`, `staged/`, `incoming/`, `failed/`), host-side APK inspection (`APKInspector`, `APKSignatureVerifier`, the intrinsic checks), import formats (`.apk`, split sets, `.apks`, `.xapk`, `.apkm`), signing metadata, the transaction journal and its recovery, reconciliation with Android, coordination with the Store Agent (`StoreAgentChannel`, `StoreRuntimeAccess`). Design: [../02-design/package-store.md](../02-design/package-store.md).
- **Must not:** decide *when* to update (UpdateCore) or talk to Android except through `StoreAgentChannel`.

### UpdateCore
- **Owns:** `UpdateProvider` and all providers (Local, Direct, F-Droid, GitHub), `UpdateCandidate`, update checks, downloads, validation pipeline, scheduling policy (interval, backoff, notify-only), gentle-update coordination, health-check orchestration, rollback policy, `UpdateAuthority` rules (the `UpdateAuthority` type itself lives in APKStoreCore, because the package record stores it). Design: [../02-design/update-system.md](../02-design/update-system.md).
- **Must not:** touch wrapper bundles.

### WrapperCore
- **Owns:** `.app` generation, `Info.plist`, `wrapper.json`, icon conversion to `.icns`, bundle ID mapping, launcher installation into bundles, local code signing, wrapper registry (known wrapper locations and integrity hashes), wrapper refresh.
- **Must not:** read or write APKs or package state other than through its input `WrapperConfiguration`.

### IntegrationCore
- **Owns:** host-side desktop integrations and their policy: `IntegrationPolicy`, clipboard coordination (loop prevention), notification routing, link forwarding, file transfers and the shared-folder service, audio/microphone policy, locale/time sync, and the `IntegrationChannel` protocol that RuntimeCore implements. Every integration checks the per-package policy before acting. Design: [../02-design/desktop-integration.md](../02-design/desktop-integration.md).
- **Must not:** bypass the policy check, log clipboard, notification, file, or URL contents, or use AppKit. The AppKit adapters (NSPasteboard, UserNotifications, drop target, save panel) live in the `APKRunLauncher` target and carry no policy. The one `NSWorkspace` adapter apkrund needs (`WorkspaceOpener`: opening wrappers and forwarded links) lives in RuntimeHost and is injected.

---

## 3. Dependency graph

Arrows mean "may import". Anything not listed is forbidden.

```text
DiagnosticsCore          (leaf)
GuestProtocol            → SwiftProtobuf
RuntimeAPI               → (Foundation, IOSurface)
VirtioDeviceCore         → DiagnosticsCore
VirtualMachineCore       → VirtioDeviceCore, DiagnosticsCore
GraphicsCore             → VirtioDeviceCore, DiagnosticsCore, GraphicsBridge(C)
InputCore                → DiagnosticsCore
WindowingCore            → InputCore, DiagnosticsCore
ImageCore                → VirtualMachineCore (VMDefinition types), DiagnosticsCore
RuntimeCore              → VirtualMachineCore, GraphicsCore, InputCore, GuestProtocol,
                           ImageCore, RuntimeAPI, DiagnosticsCore
APKStoreCore             → GuestProtocol, RuntimeAPI, DiagnosticsCore, ZIPFoundation
UpdateCore               → APKStoreCore, RuntimeAPI, DiagnosticsCore, ZIPFoundation
WrapperCore              → RuntimeAPI, DiagnosticsCore
IntegrationCore          → GuestProtocol, RuntimeAPI, DiagnosticsCore
RuntimeClient            → RuntimeAPI, DiagnosticsCore
RuntimeHost              → RuntimeCore, APKStoreCore, UpdateCore, WrapperCore,
                           IntegrationCore, ImageCore, InputCore, RuntimeAPI, DiagnosticsCore
```

Executables:

```text
apkrund          → RuntimeHost
APKRunLauncher   → RuntimeClient, RuntimeAPI, WindowingCore, InputCore, DiagnosticsCore
APKRun.app       → RuntimeClient, RuntimeAPI, DiagnosticsCore, Sparkle (third party; APKRun updates, ADR-0016)
APKRunMenuBar    → RuntimeClient, RuntimeAPI, DiagnosticsCore
apkrun (CLI)     → RuntimeClient, RuntimeAPI, DiagnosticsCore, ArgumentParser (third party, swift-argument-parser)
                   + RuntimeHost, WindowingCore, InputCore only when built with APKRUN_EMBEDDED_RUNTIME (SwiftPM trait EmbeddedRuntime)
```

Notes:

- An earlier sketch had `APKRun.app → RuntimeCore`. That would let the GUI own the VM, which contradicts ADR-0007. The GUI uses `RuntimeClient` only.
- Clients import RuntimeAPI directly for the DTOs (for example `WrapperDocument` in the launcher). RuntimeClient does not re-export it.
- APKStoreCore and IntegrationCore reach the guest through small channel protocols (`StoreAgentChannel`, `IntegrationChannel`) that RuntimeCore implements and RuntimeHost injects. This avoids an `APKStoreCore → RuntimeCore` edge.
- The dependency rules are checked by `scripts/check-module-deps.sh` in CI (#062). It reads the allowed graph from the two code blocks of this section, then checks the target dependencies from `swift package dump-package`, the Xcode targets from `xcodegen dump`, and the `import` lines of every production source file (SwiftPM lets a target import anything in its dependency closure).
- Third-party code is allowed only where the graph names it: SwiftProtobuf in GuestProtocol, virglrenderer, libepoxy, and ANGLE behind GraphicsBridge, ZIPFoundation in APKStoreCore and UpdateCore (reading only, ADR-0017), ArgumentParser in the CLI, and Sparkle in APKRun.app. Adding another one needs an ADR ([decisions/README.md](decisions/README.md)).

---

## 4. Guest components

| Component | Language | Android identity | Runs as | Owns |
|---|---|---|---|---|
| Guest Agent | Kotlin | package `io.apkrun.guest`; process `apkrun_guestd` (the `app_process` nice name in development) or `io.apkrun.guest` (the app process on the custom image) | Dev (stock image): `app_process` under the shell uid, started over ADB (scrcpy-style), reached through an ADB forward. Custom image: platform-signed persistent privileged app in SELinux domain `apkrun_guest_app`. | Control channel, launch/stop on a display, package queries, **input injection (the production input path)**, IME service, clipboard, notification listener, display lifecycle, health, URL forwarding |
| Store Agent | Kotlin | package `io.apkrun.store` | Privileged system app (`/system_ext/priv-app`), domain `apkrun_store_app` | PackageInstaller sessions, update ownership, install constraints, archive analysis, icon rendering, package events |
| vsock bridge | Rust | binary `apkrun_vsockd` | Native init service (`/system_ext/bin`), domain `apkrun_vsockd` (`unconstrained_vsock_violators`) | Listening on vsock ports 6100–6111 and splicing each connection to the agents' abstract sockets. No protocol logic. |
| APKRun product | Soong (`Android.bp`) / product makefiles / sepolicy | `device/apkrun/apkrun_arm64` | Build time | Inherits `device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk`, adds the agents, the bridge, properties, display/IME settings |

Why two agents and why Kotlin: [decisions/0008-guest-agents.md](decisions/0008-guest-agents.md).

---

## 5. Naming

| Thing | Name |
|---|---|
| Host bundle IDs | `io.apkrun.APKRun`, `io.apkrun.APKRunMenuBar`, `io.apkrun.APKRunLauncher` (the generic launcher), `io.apkrun.apkrund`, `io.apkrun.cli`; `io.apkrun.testhost` (`APKRunTestHost`, Debug only, [../05-development/build-system.md](../05-development/build-system.md) §2) |
| LaunchAgent label / Mach service | `io.apkrun.apkrund` / `io.apkrun.apkrund.xpc` |
| Wrapper bundle IDs | `io.apkrun.android.<mapped package>` ([../02-design/wrapper.md](../02-design/wrapper.md) §4) |
| Log subsystems | `io.apkrun.runtime`, `.vm`, `.graphics`, `.input`, `.image`, `.store`, `.update`, `.wrapper`, `.integration`, `.maintenance`, `.ui`, `.menubar`, `.cli`, `.diagnostics`. The closed list with categories is [../02-design/diagnostics.md](../02-design/diagnostics.md) §3.1 |
| Guest packages | `io.apkrun.guest`, `io.apkrun.store` |
| Fixture packages | `io.apkrun.fixture.<name>` (e.g. `io.apkrun.fixture.hellotext`) |
| System properties | `ro.apkrun.*` (build time), `ro.boot.apkrun.*` (from bootconfig `androidboot.apkrun.*`), `persist.apkrun.*` |

The `io.apkrun` namespace gives host and guest components one reverse-DNS root. Whether we own the domain is open question OQ-01 in [../04-plan/open-questions.md](../04-plan/open-questions.md).
