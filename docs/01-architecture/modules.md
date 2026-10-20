# Modules, Ownership, and Dependencies

This page defines the repository layout, the owner of each module, the allowed dependency graph, the guest components, and the naming rules. A change to a module's ownership or to the allowed graph needs an ADR ([decisions/README.md](decisions/README.md)).

---

## 1. Repository layout

```text
apkrun/
├── AGENTS.md                 # rules for implementers
├── CLAUDE.md                 # points to AGENTS.md
├── README.md
├── Package.swift             # one SwiftPM manifest for all Packages/* targets and the CLI
├── project.yml               # XcodeGen spec for the app, daemon, and launcher targets (build-system.md)
├── Apps/
│   ├── APKRun/               # main GUI app (SwiftUI)
│   ├── APKRunMenuBar/        # menu bar extra (login item)
│   └── APKRunLauncher/       # the wrapper executable (AppKit)
├── Daemon/apkrund/           # LaunchAgent executable (thin main; logic in RuntimeHost)
├── CLI/apkrun/               # swift-argument-parser CLI
├── Packages/                 # Swift library targets, one directory per module
│   ├── DiagnosticsCore/  VirtioDeviceCore/  VirtualMachineCore/  GraphicsCore/ (with GraphicsBridge, C / Objective-C++)
│   ├── InputCore/  WindowingCore/  ImageCore/  GuestProtocol/ (.proto sources, generated Swift, framing)
│   ├── RuntimeAPI/  RuntimeCore/  RuntimeClient/  RuntimeHost/
│   └── APKStoreCore/  UpdateCore/  WrapperCore/  IntegrationCore/
│       # each module: Sources/<Module>/ and Tests/<Module>Tests/ (T0), Tests/<Module>SystemTests/ (T1),
│       # Tests/<Module>TestSupport/ (fakes), Tests/<Module>Fuzz/ (only with APKRUN_FUZZ=1); build-system.md §2.1
├── Guest/                    # everything that runs inside Android (one Gradle build for the Kotlin parts)
│   ├── protocol/             # Kotlin: generated protobuf lite and frame codec (from Packages/GuestProtocol/proto)
│   ├── agentruntime/         # Kotlin: shared runtime of both agents
│   ├── guestd/               # Guest Agent (Kotlin): package io.apkrun.guest, process apkrun_guestd
│   ├── APKRunStore/          # Store Agent (Kotlin): package io.apkrun.store
│   ├── vsockd/               # apkrun_vsockd (Rust): vsock ↔ agent local-socket bridge (custom image only)
│   └── product/              # AOSP product: device makefiles, init .rc, sepolicy, overlays, permissions
├── Images/
│   ├── manifests/            # committed per build: <buildId>/inventory.json and android-image.json
│   ├── reference/            # committed Cuttlefish reference captures (<buildId>/) and VZ topology (vz/)
│   └── tools/                # Python tooling: inventory, boot image extraction, bootconfig, disk assembly, bundling
├── ThirdParty/
│   ├── ThirdParty.lock.json  # pinned revisions, licenses, flags, patches
│   ├── patches/<name>/*.patch
│   └── build/                # build scripts for virglrenderer, ANGLE, …
├── Tests/
│   ├── IntegrationTests/     # Swift tests that need a real VM (tier T2), one <Area>Tests/ each, including SecurityTests/
│   ├── AcceptanceTests/      # scripted gate checks (tier T3)
│   ├── PerformanceTests/     # apkrun-perf harness and per-Mac baselines (diagnostics.md §9)
│   ├── Compatibility/        # compatibility runs and the compatibility database source (diagnostics.md §10)
│   └── Fixtures/
│       ├── AndroidApps/      # Gradle project: HelloText, HelloCompose, HelloGL, …
│       ├── fuzz/<target>/    # fuzz seed corpora and crash reproducers (test-strategy.md §7.2)
│       ├── signing/          # test-only keystores (never production keys)
│       └── update-repos/     # LocalProvider / Direct / F-Droid / GitHub fixtures
├── Experiments/              # spikes; never imported by production targets
├── scripts/                  # developer scripts (bootstrap, lint, fetch artifacts, run gates)
└── docs/                     # the specification (docs/README.md)
```

Forbidden: generic dumping grounds such as `Common/`, `Utils/`, `Helpers/`, and `Misc/`. A shared abstraction needs a named owner module.

---

## 2. Module catalogue

Each module has one owner boundary. The "must not" rules are enforced in code review and by the dependency graph (§3).

### DiagnosticsCore
- **Owns:** the `os.Logger` facade with the fixed subsystems; `OperationID`; the `APKRunError` protocol (domain, code, remediation); `PerfMarker` signposts; `HealthReport` and `HealthCheck`; the doctor check framework; the diagnostics bundle writer and redaction.
- **Must not:** depend on any other APKRun module.

### VirtioDeviceCore
- **Owns:** the adapter over the custom virtio device API: feature negotiation, config space, virtqueue descriptor-chain parsing and completion, shared-memory mapping, and the `VirtioDeviceModel` protocol.
- **Must not:** know about GPUs, input, Android, or packages. It is device-agnostic plumbing.

### VirtualMachineCore
- **Owns:** `VZVirtualMachine`, `VZVirtualMachineConfiguration`, and their configuration (CPU, memory, boot loader, block devices, network, vsock, serial and console ports, balloon, entropy, sound attachment); `VMController`, `VMState`, `VMDefinition`, and its validation.
- **Consumes:** `VirtioDeviceModel` instances handed in through `VMDefinition`. It attaches them and never implements them.
- **Must not:** know about APKs, Android package names, or Android image file names.

### GraphicsCore
- **Owns:** the virtio-gpu device model and its command handling; resources, backing, scanouts, and cursor; the VirGL, virglrenderer, and ANGLE bridge (the `GraphicsBridge` C target); Metal presentation into IOSurface pools; frame statistics; readback counters.
- **Must not:** know about Android package names or windows. Scanouts are exposed as `ScanoutID` → `SurfacePool`.

### InputCore
- **Owns:** `InputEvent`; translation from `NSEvent` (pointer, scroll, key, modifiers, text); coordinate mapping (window points → display pixels); gesture state (touch slop, scroll accumulation); shortcut mapping (Esc → BACK, Cmd+C → copy); the IME text model (committed and marked text).
- **Must not:** know about packages, transports, or the guest. It knows displays only by `DisplayID`. Delivery goes through RuntimeCore's `InputRouter`, then GuestProtocol, then the Guest Agent ([0013](decisions/0013-input-via-guest-injection.md)). A host-side virtio-input device is impossible with the macOS 27 virtio API, which has no config-space write callback.

### WindowingCore
- **Owns:** the `NSWindow` lifecycle for app sessions; the `CALayer` that presents an IOSurface pool ([display-and-windowing.md](../02-design/display-and-windowing.md) §5.3); geometry, Retina scale, fullscreen, resize, focus; first-responder handling and `NSTextInputClient` (IME).
- **Must not:** own the VM or talk to the guest. Frames arrive through a `FrameSource` protocol, and input leaves through an `InputSink` protocol.

### GuestProtocol
- **Owns:** the `.proto` definitions, the generated Swift code, the framing codec, the protocol version constants, and the compatibility rules.
- **Must not:** contain business logic, networking, or state.

### ImageCore
- **Owns:** `AndroidImageManifest` and `RuntimeImageManifest`; the installed image store (A/B pointers); integrity verification; userdata creation; APFS clone-based recovery points; translation of an image and instance into the Android parts of a `VMDefinition` (kernel, initrd, cmdline, disk list). For Android system updates it also owns `ImageFeedClient`, the resumable `ImageDownloader`, and safe archive extraction ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1–§4.5).
- **Must not:** start VMs, or decide when an update is applied (`ImageUpdateCoordinator` in RuntimeHost). Build-time tooling is Python under `Images/tools/`; ImageCore consumes only the finished runtime image bundle ([0011](decisions/0011-runtime-image-bundle.md)).

### RuntimeAPI
- **Owns:** the XPC contract between clients and apkrund: request, response, and event DTOs (`Codable`, `Sendable`); the `@objc` XPC protocols; API version constants; the `RuntimeService` Swift protocol.
- **Must not:** contain logic. Foundation and IOSurface only.

### RuntimeCore
- **Owns:** `RuntimeState` and readiness monitoring; app sessions (launch, stop, lifecycle); `DisplayPool`; `InputRouter` (per-session input, with display ownership checks); `AndroidControlChannel` (ADB and GuestProtocol implementations); `AdbClient` (the development `adb` wrapper); guest connection management and handshake; the vsock port plan.
- **Must not:** implement install or update policy (APKStoreCore and UpdateCore), generate wrappers, or render.

### RuntimeClient
- **Owns:** the XPC client (`XPCRuntimeService: RuntimeService`); reconnection; launching APKRun.app when the agent is not registered; client-side session objects that carry frames and input as RuntimeAPI wire types.
- **Must not import** WindowingCore or InputCore. The launcher's `XPCFrameSource` and `XPCInputSink` adapt sessions to `FrameSource` and `InputSink` ([display-and-windowing.md](../02-design/display-and-windowing.md) §1).
- **Used by:** APKRunLauncher, APKRun.app, APKRunMenuBar, and the apkrun CLI.

### RuntimeHost
- **Owns:** the composition root (wiring, startup and recovery order, `EmbeddedRuntimeService`, the XPC export in apkrund). Runtime maintenance: `MaintenanceService` (host state, host-update marker, `.maintenance` endpoint), `SelfUpdateProbe`, `BundleWatcher`, and `ImageUpdateCoordinator` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §1).
- **Used by:** apkrund (always), and the apkrun CLI in embedded mode (`apkrun dev`).

### APKStoreCore
- **Owns:** `metadata.json` and `settings.json` per package; `PackageArtifact`; the package directories (`current/`, `previous/`, `staged/`, `incoming/`, `failed/`); host APK inspection (`APKInspector`, `APKSignatureVerifier`, intrinsic checks); import formats (`.apk`, split sets, `.apks`, `.xapk`, `.apkm`); signing metadata; the transaction journal and its recovery; reconciliation with Android; `StoreAgentChannel` and `StoreRuntimeAccess`. Design: [package-store.md](../02-design/package-store.md).
- **Must not:** decide *when* to update (UpdateCore), or talk to Android except through `StoreAgentChannel`.

### UpdateCore
- **Owns:** `UpdateProvider` and the Local, Direct, F-Droid, and GitHub providers; `UpdateCandidate`; checks and downloads; the validation pipeline; scheduling (interval, backoff, notify-only); gentle-update coordination; health-check orchestration; rollback policy; `UpdateAuthority` rules. The `UpdateAuthority` type lives in APKStoreCore, because the package record stores it. Design: [update-system.md](../02-design/update-system.md).
- **Must not:** touch wrapper bundles.

### WrapperCore
- **Owns:** `.app` generation; `Info.plist`; `wrapper.json`; icon conversion to `.icns`; bundle ID mapping; launcher installation into bundles; local code signing; the wrapper registry (known locations and integrity hashes); wrapper refresh.
- **Must not:** read or write APKs or package state, except through its input `WrapperConfiguration`.

### IntegrationCore
- **Owns:** host-side desktop integrations and `IntegrationPolicy`: clipboard coordination (loop prevention), notification routing, link forwarding, file transfers and the shared-folder service, audio and microphone policy, locale and time sync; the `IntegrationChannel` protocol that RuntimeCore implements. Every integration checks the per-package policy before it acts. Design: [desktop-integration.md](../02-design/desktop-integration.md).
- **Must not:** bypass the policy check; log clipboard, notification, file, or URL contents; or use AppKit. The AppKit adapters (NSPasteboard, UserNotifications, drop target, save panel) live in the `APKRunLauncher` target and carry no policy. The `NSWorkspace` adapter `WorkspaceOpener` lives in RuntimeHost and is injected.

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
- APKStoreCore and IntegrationCore keep guest-facing channel protocols beside their policy modules. RuntimeHost supplies the adapters and injects them, using RuntimeCore's guest and ADB primitives. This avoids direct `APKStoreCore → RuntimeCore` and `IntegrationCore → RuntimeCore` dependency edges.
- The dependency rules are checked by `scripts/check-module-deps.sh` in CI (#63). It reads the allowed graph from the two code blocks of this section, then checks the target dependencies from `swift package dump-package`, the Xcode targets from `xcodegen dump`, and the `import` lines of every production source file (SwiftPM lets a target import anything in its dependency closure).
- Third-party code is allowed only where the graph names it: SwiftProtobuf in GuestProtocol, virglrenderer, libepoxy, and ANGLE behind GraphicsBridge, ZIPFoundation in APKStoreCore and UpdateCore (reading only, ADR-0017), ArgumentParser in the CLI, and Sparkle in APKRun.app. Adding another one needs an ADR ([decisions/README.md](decisions/README.md)).

---

## 4. Guest components

| Component | Language | Android identity | Runs as | Owns |
|---|---|---|---|---|
| Guest Agent | Kotlin | Package `io.apkrun.guest`; process `apkrun_guestd` (the `app_process` nice name in development), or `io.apkrun.guest` (the app process on the custom image) | Development (stock image): `app_process` under the shell uid, started over ADB and reached through an ADB forward. Custom image: platform-signed persistent privileged app in SELinux domain `apkrun_guest_app`. | Control channel; launch and stop on a display; package queries; **input injection (the production input path)**; IME service; clipboard; notification listener; display lifecycle; health; URL forwarding |
| Store Agent | Kotlin | Package `io.apkrun.store` | Privileged system app (`/system_ext/priv-app`), domain `apkrun_store_app` | PackageInstaller sessions; update ownership; install constraints; archive analysis; icon rendering; package events |
| vsock bridge | Rust | Binary `apkrun_vsockd` | Native init service (`/system_ext/bin`), domain `apkrun_vsockd` (`unconstrained_vsock_violators`) | Listens on vsock ports 6100–6111 and splices each connection to the agents' abstract sockets. No protocol logic. |
| APKRun product | Soong (`Android.bp`), product makefiles, sepolicy | `device/apkrun/apkrun_arm64` | Build time | Inherits `device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk`; adds the agents, the bridge, properties, and display and IME settings |

Why two agents, and why Kotlin: [0008](decisions/0008-guest-agents.md).

---

## 5. Naming

| Thing | Name |
|---|---|
| Host bundle IDs | `io.apkrun.APKRun`, `io.apkrun.APKRunMenuBar`, `io.apkrun.APKRunLauncher` (the generic launcher), `io.apkrun.apkrund`, `io.apkrun.cli`; `io.apkrun.testhost` (`APKRunTestHost`, Debug only; [build-system.md](../05-development/build-system.md) §2) |
| LaunchAgent label, Mach service | `io.apkrun.apkrund`, `io.apkrun.apkrund.xpc` |
| Wrapper bundle IDs | `io.apkrun.android.<mapped package>` ([wrapper.md](../02-design/wrapper.md) §4) |
| Log subsystems | `io.apkrun.runtime`, `.vm`, `.graphics`, `.input`, `.image`, `.store`, `.update`, `.wrapper`, `.integration`, `.maintenance`, `.ui`, `.menubar`, `.cli`, `.diagnostics`. The closed list with categories is in [diagnostics.md](../02-design/diagnostics.md) §3.1. |
| Guest packages | `io.apkrun.guest`, `io.apkrun.store` |
| Fixture packages | `io.apkrun.fixture.<name>` (for example `io.apkrun.fixture.hellotext`) |
| System properties | `ro.apkrun.*` (build time), `ro.boot.apkrun.*` (from bootconfig `androidboot.apkrun.*`), `persist.apkrun.*` |

The `io.apkrun` namespace gives host and guest components one reverse-DNS root. Whether APKRun owns the domain is open question OQ-01 in [open-questions.md](../04-plan/open-questions.md).
