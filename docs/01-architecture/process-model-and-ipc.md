# Process Model and IPC

This page defines the processes of APKRun, how clients reach apkrund over XPC, and how apkrund talks to the Android guest. Message signatures are in [runtime-api.md](../03-reference/runtime-api.md). The guest protocol is in [guest-protocol.md](../02-design/guest-protocol.md).

---

## 1. Processes

| Process | Binary | Lifetime | Owns |
|---|---|---|---|
| `apkrund` | `APKRun.app/Contents/Helpers/apkrund`, LaunchAgent `io.apkrun.apkrund` | Started by launchd on client connect, at login, hourly (update checks), and after a crash. Exits 2 minutes after the runtime stops, when no client or activity remains ([runtime-daemon.md](../02-design/runtime-daemon.md) §2). | VM, graphics, DisplayPool, sessions, package store, updates, wrapper registry, integrations |
| Wrapper (`APKRunLauncher`) | `<Name>.app/Contents/MacOS/APKRunLauncher` | While the app is open. It does not exit after launch, because it owns the window ([0006](decisions/0006-wrapper-owned-window-iosurface.md)). | One NSWindow, input capture, Dock and Cmd+Tab identity |
| `APKRun.app` | Main GUI | User-controlled | UI only |
| `APKRunMenuBar` | `APKRun.app/Contents/Library/LoginItems/APKRunMenuBar.app` | Login item, on by default. "Show APKRun in the menu bar" in Settings turns it off ([host-ui.md](../02-design/host-ui.md) §9.1). | UI only |
| `apkrun` CLI | `APKRun.app/Contents/Resources/bin/apkrun` (symlinked to `/usr/local/bin/apkrun` on request) | Per command | Nothing, except `apkrun dev` in embedded mode |
| Android VM | Inside apkrund, in XPC helper processes that Virtualization.framework owns | While `RuntimeState` is `booting`, `ready`, or `suspended` | Android |

### 1.1 Registration of apkrund

The embedded plist `APKRun.app/Contents/Library/LaunchAgents/io.apkrun.apkrund.plist` is:

```xml
<dict>
  <key>Label</key>            <string>io.apkrun.apkrund</string>
  <key>BundleProgram</key>    <string>Contents/Helpers/apkrund</string>
  <key>MachServices</key>     <dict><key>io.apkrun.apkrund.xpc</key><true/></dict>
  <key>ProcessType</key>      <string>Interactive</string>
  <key>KeepAlive</key>        <dict><key>SuccessfulExit</key><false/></dict>
  <key>RunAtLoad</key>        <true/>
  <key>StartInterval</key>    <integer>3600</integer>
  <key>ExitTimeOut</key>      <integer>45</integer>
  <key>AssociatedBundleIdentifiers</key> <array><string>io.apkrun.APKRun</string></array>
</dict>
```

- `APKRun.app` calls `SMAppService.agent(plistName: "io.apkrun.apkrund.plist").register()` on launch when the service is absent or its embedded plist changed. `--register-runtime` does the same for the installer and setup flow. If `status == .requiresApproval`, a new registration opens Login Items. Later launches only show an approval prompt.
- `KeepAlive.SuccessfulExit = false` makes launchd restart apkrund after a crash (NFR-REL-02). A clean exit (status 0) is not restarted. The next client connection starts it.
- `RunAtLoad`, `StartInterval`, and `ExitTimeOut` serve preboot and startup recovery, background update checks, and a graceful Android shutdown on logout ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.1).
- Debug builds use label `io.apkrun.apkrund.dev` and Mach service `io.apkrun.apkrund.dev.xpc` ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).
- Sparkle replaces the bundle, not the agent. Before it does, apkrund stops Android and exits through the install handshake ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.5). The first launch of the new version runs `unregister()` then `register()` only if the agent status is not `.enabled` or the plist SHA-256 changed. Otherwise launchd resolves `BundleProgram` at the next spawn. The fallback is re-registration on every build change ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.7).

### 1.2 Development (embedded) mode

`apkrun dev …` links `RuntimeHost`, `WindowingCore`, and `InputCore` (build flag `APKRUN_EMBEDDED_RUNTIME`). It runs the VM and the window in the CLI process, with an `NSApplication` event loop and `.regular` activation policy. It uses the same `RuntimeService` protocol as apkrund (`EmbeddedRuntimeService`). It is for debugging, for example booting a test image without touching the user's runtime. It refuses to run while apkrund owns the user's runtime instance.

---

## 2. Host IPC (XPC)

### 2.1 Transport

- `NSXPCConnection` and `NSXPCListener` with `@objc` protocols defined in `RuntimeAPI`.
- Payloads are `Codable` DTOs encoded as `Data` (JSON in v0.x). `NSSecureCoding` is used only for `IOSurface` and file handles. New DTO fields are optional.
- Every request carries `APIRequestHeader { apiVersion, operationID, clientKind }`.
- `RuntimeAPI.version = (major, minor)`. The server accepts the same major and any minor up to its own. A major mismatch returns `RuntimeFailure.apiVersionMismatch(client:server:)` ([error-catalog.md](../03-reference/error-catalog.md) §7), with the remediation "Update APKRun" or "Update Mac App".
- The `.wrapper` endpoint also serves major N−1, so an APKRun update does not break existing wrappers at once.
- During an APKRun update, an old apkrund can meet a new APKRun.app. The `.maintenance` endpoint (§2.2) therefore has a frozen, additive-only protocol without a major version ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.1).
- A wrapper compares `runtime.minimumVersion` in `wrapper.json` with the runtime version in the `hello` reply ([wrapper.md](../02-design/wrapper.md) §5.3).

### 2.2 Broker and endpoints

The main Mach service is reachable by every process of the logged-in user, so it exposes only a **broker**. For a control request, the broker creates a one-use **anonymous listener endpoint** protected by the client's code-signing requirement (`NSXPCListener.setConnectionCodeSigningRequirement`, macOS 13+, public API). The broker connection and the endpoint share one short-lived reservation, so a delayed connection cannot use another client's grant.

```text
client ──(1) connect io.apkrun.apkrund.xpc──▶ BrokerService
        hello(clientKind, claimedIdentity, apiVersion) → HelloReply(runtimeVersion, runtimeBuild, apiVersion, hostState)
        requestEndpoint(kind) → one-use NSXPCListenerEndpoint
              kind = .control    → requirement: APKRun's own signing identity
              kind = .maintenance → same requirement as .control; version-stable (runtime-maintenance.md §8.1)
              kind = .wrapper(bundleID) → requirement: identifier "<bundleID>" and cdhash H"<registered cdhash>"
client ──(2) connect to endpoint──▶ (system enforces the requirement; mismatch ⇒ invalidated)
```

| Client | Endpoint | Requirement (release) | Requirement (dev, ad-hoc) | Capabilities |
|---|---|---|---|---|
| APKRun.app, APKRunMenuBar, `apkrun` CLI | `.control` | `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "io.apkrun.*"` (one per identifier) | `cdhash H"…"` of the binaries in the same APKRun.app, computed at apkrund start | Full `RuntimeService` |
| Same clients | `.maintenance` | As `.control` | As `.control` | Host update coordination only: status, prepare, abort, complete, restart. Served in every host state ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.1). |
| Wrapper | `.wrapper(bundleID)` | `identifier` and `cdhash` from the wrapper registry | Same | Sessions; `packageInfo` and `packageIcon` for its own package only; `importBootstrap` (portable wrappers); notification relay; `runtimeStatus` ([wrapper.md](../02-design/wrapper.md) §12.1) |
| Unknown wrapper (not in the registry) | None | — | — | `requestApproval` on the broker only. Approval registers the current cdhash ([wrapper.md](../02-design/wrapper.md) §7.3). |

- Each wrapper launcher is re-signed ad hoc with the wrapper's bundle ID as identifier, so each wrapper has its own cdhash. WrapperCore records it in `Wrappers/registry.json` ([wrapper.md](../02-design/wrapper.md) §7).
- Do not authorize with the private `auditToken` of `NSXPCConnection`, or with `processIdentifier`. PIDs can be reused in a race.
- The client verifies apkrund too, with `NSXPCConnection.setCodeSigningRequirement(_:)` before `resume()`.

### 2.3 Session channel

A wrapper opens a session with `openSession`. The reply carries the surfaces. Signatures are in [runtime-api.md](../03-reference/runtime-api.md) §6, §7, and §11.

```text
openSession(OpenSessionRequest{ packageID, geometry: DisplayGeometry{ pointSize, backingScale, zoom }, screenSize,
                                 launchTiming: LaunchTiming{ processStart, requestSent } })
  → SessionDescriptor{ sessionID, displayID, windowPrefs, state,
                       surfaces: SurfaceSet{ generation, [IOSurface] (3), pixelSize, densityDpi } }
```

`launchTiming` carries the launch markers of [diagnostics.md](../02-design/diagnostics.md) §4.2.

- apkrund → wrapper, as `SessionEvent` cases ([runtime-api.md](../03-reference/runtime-api.md) §6.3) on the same connection: `stateChanged(phase)` (`SessionPhase`, [runtime-api.md](../03-reference/runtime-api.md) §6.2: `starting`, `booting(progress)`, `waitingForPackage`, `launching`, `running`, `ended(reason)`), `frameReady(generation, surfaceIndex, frameSeq, presentationTime)`, `surfacesReplaced(SurfaceSet)`, `imeStateChanged(EditorState)` ([input.md](../02-design/input.md) §5.1), `windowRequest(.activate | .close | .setTitle)`, and `windowPrefsChanged(WindowPrefs)` (resizable, alwaysOnTop, zoom; [host-ui.md](../02-design/host-ui.md) §7.2).
- Wrapper → apkrund: `frameDisplayed(generation, frameSeq)` (releases older buffers, [display-and-windowing.md](../02-design/display-and-windowing.md) §5), `visibilityChanged(Bool)`, `sendInput([InputEvent])`, `sendText(ImeTextEvent)`, `resize(DisplayGeometry)`, `focusChanged(Bool)`, `closeSession(policy)`, `restartApp()`, and `frameStatistics() → SessionGraphicsStatistics`.
- Integration: `pushClipboard(ClipItem) → ClipAck`, `clipboardWritten(changeCount, digest)`, `importFiles([FileHandle], [ImportFileInfo], ImportTarget) → ImportResult`, `acceptExport(offerID, FileHandle?)`, `resolveLinkPrompt(promptID, LinkChoice)`. Events: `clipboardFromGuest(ClipItem)`, `exportOffered(ExportOffer)`, `linkPrompt(LinkPrompt)` ([desktop-integration.md](../02-design/desktop-integration.md) §3.3).
- Surfaces are sent only on open and resize, never per frame. `IOSurface` objects and `NSFileHandle`s (drag and drop, Save to Mac) pass over NSXPC directly. apkrund never opens user-chosen paths itself.
- `sendInput` is batched per run-loop turn. `sendText` is unbatched and ordered ([input.md](../02-design/input.md) §8).
- `closeSession(policy)` takes `.stop` or `.keepRunning` ([display-and-windowing.md](../02-design/display-and-windowing.md) §7.6). `restartApp()` force-stops the app and launches it again on the same display ([wrapper.md](../02-design/wrapper.md) §5.6). `frameStatistics()` works in developer mode only ([display-and-windowing.md](../02-design/display-and-windowing.md) §7.7).
- Minimized, occluded, or hidden windows stop presents (`visibilityChanged(false)`).
- The window process does the AppKit side of desktop integration: pasteboard, notifications, drop target, save panel, and link prompt. apkrund makes every decision ([desktop-integration.md](../02-design/desktop-integration.md) §1).
- The per-frame event is about 40 bytes. A shared-memory ring with a Mach semaphore is a possible optimization if XPC latency is measured as a bottleneck (#71). It is not implemented.

### 2.4 Event subscription

`subscribe(topics) → stream of RuntimeEvent` (runtime state, package changes, update progress, sessions, health; [runtime-api.md](../03-reference/runtime-api.md) §16). The GUI and the menu bar render from this stream and do not poll.

### 2.5 Failure handling

| Failure | Client behavior |
|---|---|
| apkrund not registered | RuntimeClient opens APKRun.app (`NSWorkspace.open(bundleID)`) with `--register-runtime`. The wrapper shows "APKRun needs to finish setup". |
| apkrund crashed mid-session | The connection is invalidated. The wrapper shows "APKRun restarted — reopening…" and retries `openSession` with backoff (1 s, 2 s, 4 s, then every 5 s). After 15 s it shows a reconnecting error while retries continue until the window closes or the session recovers. The VM is gone, so the launch is cold. |
| Control listener at its eight-connection limit | RuntimeClient probes each new endpoint with the idempotent `runtimeStatus`, and retries rejected connections with bounded backoff before a side-effecting request. |
| API major mismatch | Actionable error dialog. The wrapper never continues. |
| APKRun or Android updating (`HelloReply.hostState == updating`, `RuntimeFailure.hostUpdating`, or `ended(.runtimeUpdating)`) | The wrapper shows screen U and retries `openSession` every 2 s for up to 10 minutes ([wrapper.md](../02-design/wrapper.md) §5.4). The menu bar relaunches when `hello` reports another build ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.7). |
| Endpoint rejected (requirement mismatch) | The wrapper calls `requestApproval`. The user approves in APKRun.app. |

---

## 3. Host ↔ guest channels

### 3.1 Transports

The host always initiates. apkrund opens every channel with `VZVirtioSocketDevice.connect(toPort:)` (guest CID 3). Development mode uses an ADB forward to a local abstract socket instead. One direction on both transports keeps `GuestAgentConnection` a single connector with a pluggable transport.

| Channel | Production (custom image, M5+) | Development (stock image, M1–M4) |
|---|---|---|
| ADB | vsock **5555** (`adbd` listens on `vsock:5555` when `persist.adb.tcp.port=5555`). apkrund bridges it to `127.0.0.1:6520` for the `adb` CLI. | Same |
| Guest Agent control | vsock 6100 → `apkrun_vsockd` → `@apkrun-guestd-control` | `adb forward tcp:0 localabstract:apkrun-guestd-control` |
| Guest Agent input stream | vsock 6101 → `@apkrun-guestd-input` | ADB forward, same name pattern |
| Guest Agent bulk data | vsock 6102 → `@apkrun-guestd-bulk` | ADB forward, same name pattern |
| APKRun IME | None. On the custom image the IME runs in the Guest Agent process on the input stream. | `adb forward tcp:0 localabstract:apkrun-guest-ime` ([input.md](../02-design/input.md) §5.6) |
| Store Agent control | vsock 6110 → `@apkrun-store-control` | None (custom images only) |
| Store Agent artifact stream | vsock 6111 → `@apkrun-store-artifacts` | None |
| Serial console | virtio-console port 0 (`hvc0`, `console=hvc0`) → `~/Library/Logs/APKRun/vm/console.log` | Same |
| Reserved | vsock 6120–6199 for host-side service substitutes ([android-image.md](../02-design/android-image.md) §7) | |

The guest endpoints are abstract Unix sockets: `apkrun_guestd` owns the Guest Agent ones, and `io.apkrun.store` owns the Store Agent ones. The IME service process owns the IME socket.

- **Why a native bridge.** Android's platform sepolicy has a `neverallow` that forbids `vsock_socket {create bind accept connect}` for every domain except a short list (`adbd`, virtualization domains) and domains tagged `unconstrained_vsock_violators`. Untrusted apps may only `getattr`, `getopt`, `read`, and `write` inherited vsock file descriptors. So neither `shell` (development `app_process`) nor an app domain can listen on vsock. `apkrun_vsockd` is a small Rust daemon (`Guest/vsockd/`) in domain `apkrun_vsockd`, with `typeattribute apkrun_vsockd unconstrained_vsock_violators`, as Cuttlefish HALs do. It listens on the ports above and splices each connection to the matching abstract socket. Its policy allows `connectto` only for the agents' domains `apkrun_guest_app` and `apkrun_store_app` (assigned via `seapp_contexts`).
- **Authentication in the guest.** Besides SELinux, each agent checks `SO_PEERCRED`. In production it accepts uid `system` or `root` (the bridge). With developer mode on, it also accepts `shell` (the ADB forward).
- **One vsock device per VM** (framework limit). v1 has no guest-initiated channel. If one is needed, the host uses `setSocketListener(_:forPort:)`.
- **Reconnection.** If an agent restarts, the bridge closes at once, because its upstream connect fails. apkrund retries with backoff (100 ms, doubling to 2 s) while `RuntimeState` is `booting` or `ready`, and reports `agent.disconnected` in health.
- **ADB** is bridged to host loopback only (NFR-SEC-06). Production images keep `adbd` stopped unless the user enables "Developer mode". The host then sets `androidboot.apkrun.devmode=1` at the next start ([android-image.md](../02-design/android-image.md) §11.3).
- The GuestProtocol handshake (§3.3) is identical on both transports.

### 3.2 Framing

Every stream carries length-prefixed frames: a `uint32` big-endian length, then an `Envelope` (Protocol Buffers). The maximum frame is 4 MiB. Larger bulk data, such as APKs and images, is chunked on the bulk and artifact streams ([guest-protocol.md](../02-design/guest-protocol.md) §4 and §10).

### 3.3 Handshake

The first frame on every connection is `Hello`. The host answers with `HelloAck`:

```text
guest → host: Hello{ protocol_version{major,minor}, agent{kind, version, build}, runtime_image_version,
                     android{sdk_int, release, build_fingerprint}, capabilities[] }
host  → guest: HelloAck{ accepted | rejected(reason), host_protocol_version, session_token, enabled_capabilities[] }
```

A major-version mismatch is `rejected`. The host marks the agent `incompatible` in health, raises `GuestProtocolFailure.incompatibleVersion` with a remediation, and closes the connection (NFR-REL-04). Minor versions negotiate capabilities.

---

## 4. Threading and concurrency inside apkrund

| Component | Execution context |
|---|---|
| `VMController` | `actor`. VZ calls run on the VM's serial `DispatchQueue` and are bridged with `withCheckedThrowingContinuation`. |
| virtio-gpu device | The `deviceQueue` (serial) handles queue notifications. All virglrenderer and ANGLE calls run on one dedicated renderer thread, because virglrenderer is not thread-safe. |
| DisplayPool, SessionRegistry, InputRouter | `actor`s |
| Guest connections | One `actor` per connection, reading from `NWConnection` or a file descriptor with `DispatchIO`. |
| XPC | NSXPC delivers calls on its own queue. Handlers hop to the owning actor at once. |
| Update scheduling | `actor UpdateScheduler` with `Task`s. Downloads use a background-friendly `URLSession`. |

Rule: no blocking calls on actor executors. Blocking C APIs (virglrenderer) run only on the renderer thread.
