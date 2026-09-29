# Process Model and IPC

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [overview.md](overview.md), [security-model.md](security-model.md), [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md), [../02-design/guest-protocol.md](../02-design/guest-protocol.md), [../03-reference/runtime-api.md](../03-reference/runtime-api.md) |

---

## 1. Processes

| Process | Bundle / binary | Lifetime | Owns |
|---|---|---|---|
| `apkrund` | `APKRun.app/Contents/Helpers/apkrund`, registered as LaunchAgent `io.apkrun.apkrund` | Started by launchd when a client connects, at login, hourly for update checks, and after a crash. Stays alive while the VM runs or any client is connected. Exits 2 minutes after the runtime is stopped and no clients or activities remain ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2). | VM, graphics, DisplayPool, sessions, package store, updates, wrappers registry, integrations |
| Wrapper (`APKRunLauncher`) | `<Name>.app/Contents/MacOS/APKRunLauncher` | While the app is open. **Does not exit after launch.** It owns the window ([decisions/0006](decisions/0006-wrapper-owned-window-iosurface.md)). | One NSWindow, input capture, Dock/Cmd+Tab identity |
| `APKRun.app` | main GUI | User-controlled | UI only |
| `APKRunMenuBar` | `APKRun.app/Contents/Library/LoginItems/APKRunMenuBar.app` | Login item, on by default; Settings → General → "Show APKRun in the menu bar" turns it off ([../02-design/host-ui.md](../02-design/host-ui.md) §9.1) | UI only |
| `apkrun` CLI | `APKRun.app/Contents/Resources/bin/apkrun` (symlinked to `/usr/local/bin/apkrun` on request) | Per command | nothing (client), except `apkrun dev …` embedded mode |
| Android VM | inside `apkrund` (Virtualization.framework runs the VM in XPC helper processes owned by the framework) | While `RuntimeState ∈ {booting, ready, suspended}` | Android |

### 1.1 Registration of apkrund

- Embedded plist `APKRun.app/Contents/Library/LaunchAgents/io.apkrun.apkrund.plist`:

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

- `APKRun.app` calls `SMAppService.agent(plistName: "io.apkrun.apkrund.plist").register()` on first launch. If `status == .requiresApproval`, the app explains why and calls `SMAppService.openSystemSettingsLoginItems()`.
- `KeepAlive.SuccessfulExit = false` makes launchd restart apkrund after a crash (NFR-REL-02). A clean idle exit (status 0) is not restarted. The next client connection relaunches it on demand.
- `RunAtLoad`, `StartInterval`, and `ExitTimeOut` serve preboot and startup recovery, background update checks, and a graceful Android shutdown on logout. The reasons are in [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.1.
- Debug builds use the label `io.apkrun.apkrund.dev` and the Mach service `io.apkrun.apkrund.dev.xpc` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).
- Sparkle replaces the bundle but does not manage agents. Before it does, apkrund stops Android and exits through the install handshake ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.5). At the first launch of the new version, APKRun.app runs `unregister()` then `register()` only if the agent's status is not `.enabled`, or the SHA-256 of the embedded plist differs from the one it registered last. With an unchanged plist, launchd resolves `BundleProgram` at the next spawn, so the new apkrund runs without re-registration. This is verified in #057 (R-24); the fallback is re-registration on every build change ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.7).

### 1.2 Development (embedded) mode

Before #031 there is no daemon. `apkrun dev …` commands link `RuntimeHost`, `WindowingCore`, and `InputCore` (build flag `APKRUN_EMBEDDED_RUNTIME`). They run the VM and the window inside the CLI process (the CLI runs an `NSApplication` event loop with `.regular` activation policy for these commands). All code paths go through the same `RuntimeService` protocol (`EmbeddedRuntimeService`). Moving to XPC in #031/#032 therefore replaces transport, not logic.

`apkrun dev` stays available after M4 for debugging, e.g. booting a test image without touching the user's runtime. It refuses to run while apkrund owns the user's runtime instance.

---

## 2. Host IPC (XPC)

### 2.1 Transport

- `NSXPCConnection` / `NSXPCListener` with `@objc` protocols defined in `RuntimeAPI`.
- Payloads are `Codable` DTOs encoded as `Data` (JSON for v0.x, with a switch to property-list binary possible later). `NSSecureCoding` is used only for `IOSurface` and file handles. Keeping DTOs as Codable avoids a large `NSSecureCoding` surface and allows versioning via optional fields.
- Every request carries `APIRequestHeader { apiVersion, operationID, clientKind }`.
- API versioning: `RuntimeAPI.version = (major, minor)`. The server accepts the same major and any minor ≤ its own. Mismatched majors return `RuntimeFailure.apiVersionMismatch(client:server:)` ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §7) with remediation "Update APKRun" / "Update Mac App". One exception: the `.wrapper` endpoint also serves the previous major (N−1), so an APKRun update does not break existing wrappers at once. Control clients ship inside APKRun.app and match apkrund, except for the short time of an APKRun update, when an old apkrund can meet a new APKRun.app. For that, the `.maintenance` endpoint (§2.2) has a frozen, additive-only protocol without a major version ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.1). Wrappers compare `wrapper.json runtime.minimumVersion` with the runtime version they receive in `hello` ([../02-design/wrapper.md](../02-design/wrapper.md) §5.3).

### 2.2 Connection establishment and authentication (broker pattern)

The main Mach service is reachable by any process of the logged-in user. Therefore it exposes only a **broker** interface. Real capabilities are handed out as **anonymous listener endpoints**, each protected by a code-signing requirement (`NSXPCListener.setConnectionCodeSigningRequirement`, macOS 13+, public API).

```text
client ──(1) connect io.apkrun.apkrund.xpc──▶ BrokerService
        hello(clientKind, claimedIdentity, apiVersion) → HelloReply(runtimeVersion, runtimeBuild, apiVersion, hostState)
        requestEndpoint(kind) → NSXPCListenerEndpoint
              kind = .control    → requirement: APKRun's own signing identity
              kind = .maintenance → same requirement as .control; version-stable (runtime-maintenance.md §8.1)
              kind = .wrapper(bundleID) → requirement: identifier "<bundleID>" and cdhash H"<registered cdhash>"
client ──(2) connect to endpoint──▶ (system enforces the requirement; mismatch ⇒ invalidated)
```

| Client | Endpoint | Requirement (release) | Requirement (dev, ad-hoc) | Capabilities |
|---|---|---|---|---|
| APKRun.app, APKRunMenuBar, `apkrun` CLI | `.control` | `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "io.apkrun.*"` (one requirement per identifier) | `cdhash H"…"` of the binaries in the same APKRun.app (computed at apkrund start) | Full `RuntimeService` |
| APKRun.app, APKRunMenuBar, `apkrun` CLI | `.maintenance` | same as `.control` | same as `.control` | host update coordination only: status, prepare, abort, complete, restart for update. Served in every host state ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.1) |
| Wrapper | `.wrapper(bundleID)` | from wrapper registry: `identifier` + `cdhash` recorded at generation/registration | same | Session API, `packageInfo` and `packageIcon` **for its own package only**, `importBootstrap` (portable wrappers), the notification relay, `runtimeStatus` ([../02-design/wrapper.md](../02-design/wrapper.md) §12.1) |
| Unknown wrapper (not in the registry: copied from another Mac, or a distribution wrapper) | none at first | — | — | `requestApproval` on the broker only. APKRun.app shows "Allow “Foo” to open com.foo in APKRun?". On approval the wrapper is registered with its current cdhash ([../02-design/wrapper.md](../02-design/wrapper.md) §7.3). |

Notes:

- Wrapper launchers are re-signed per wrapper (ad-hoc, identifier = wrapper bundle ID), so each wrapper has its own cdhash. WrapperCore records it in `Wrappers/registry.json` at generation time ([../02-design/wrapper.md](../02-design/wrapper.md) §7).
- Using the private `auditToken` of `NSXPCConnection` is forbidden. Using `processIdentifier` for authorization is forbidden (PID reuse races).
- The client side verifies apkrund too: `NSXPCConnection.setCodeSigningRequirement(_:)` with APKRun's identity before `resume()`.

### 2.3 Session channel (wrapper ↔ apkrund)

```text
openSession(OpenSessionRequest{ packageID, geometry: DisplayGeometry{ pointSize, backingScale, zoom }, screenSize,
                                 launchTiming: LaunchTiming{ processStart, requestSent } })   (diagnostics.md §4.2)
  → SessionDescriptor{ sessionID, displayID, windowPrefs, state,
                       surfaces: SurfaceSet{ generation, [IOSurface] (3), pixelSize, densityDpi } }
events (server → client, via exported object on the same connection; stateChanged, imeStateChanged, windowRequest,
        windowPrefsChanged, and the integration events are cases of SessionEvent, runtime-api.md §6.3):
  stateChanged(phase)                    SessionPhase (runtime-api.md §6.2): starting | booting(progress) | waitingForPackage | launching | running | ended(reason)
  frameReady(generation, surfaceIndex, frameSeq, presentationTime)
  surfacesReplaced(SurfaceSet)           after resize / backing-scale change
  imeStateChanged(EditorState)           Android editor focus, input type, selection, cursor rect (input.md §5.1)
  windowRequest(.activate | .close | .setTitle)  e.g. notification click, app finished
  windowPrefsChanged(WindowPrefs)        package settings changed: resizable, alwaysOnTop, zoom (host-ui.md §7.2)
client → server:
  frameDisplayed(generation, frameSeq)   releases older buffers (see display-and-windowing.md §5)
  visibilityChanged(Bool)                minimized / occluded / hidden → presents stop
  sendInput([InputEvent])                batched per runloop turn (input.md §8)
  sendText(ImeTextEvent)                 unbatched, ordered (input.md §5)
  resize(DisplayGeometry)                after live resize ends, on backing-scale or zoom change
  focusChanged(Bool)
  closeSession(policy)                   .stop | .keepRunning (display-and-windowing.md §7.6)
  restartApp()                           Android → Restart ‹App›: force-stop, then a new launch on the same display (wrapper.md §5.6)
  frameStatistics() → SessionGraphicsStatistics    developer mode only: View → Show Frame Statistics (display-and-windowing.md §7.7)
integration (desktop-integration.md §3.3):
  pushClipboard(ClipItem) → ClipAck      ⌘V and window-key pushes (§4.2 there)
  clipboardWritten(changeCount, digest)  after the window wrote a guest clip to NSPasteboard
  importFiles([FileHandle], [ImportFileInfo], ImportTarget) → ImportResult    drag and drop
  acceptExport(offerID, FileHandle?)     Save panel result for "Save to Mac"
  resolveLinkPrompt(promptID, LinkChoice)
  events: clipboardFromGuest(ClipItem), exportOffered(ExportOffer), linkPrompt(LinkPrompt)
```

- `IOSurface` objects pass over NSXPC directly (the class adopts `NSSecureCoding`). Surfaces are sent only on open and resize, never per frame. File handles for drag and drop and Save to Mac pass the same way (`NSFileHandle`), so apkrund never opens user-chosen paths itself.
- The window process does the AppKit side of desktop integration (pasteboard, notifications, drop target, save panel, link prompt). apkrund makes every decision ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §1).
- The per-frame event is small (≈ 40 bytes). If XPC event latency is ever measured as a bottleneck (#070), there is a planned optimization: a shared-memory ring plus a Mach semaphore. It is not implemented up front.

### 2.4 Event subscription (GUI, menu bar, CLI)

`subscribe(topics) → stream of RuntimeEvent` (runtime state, package changes, update progress, session list, health). The GUI and menu bar render from this stream. They do not poll.

### 2.5 Failure handling

| Failure | Client behavior |
|---|---|
| apkrund not registered | RuntimeClient opens APKRun.app (`NSWorkspace.open(bundleID)`) with `--register-runtime`. The wrapper shows "APKRun needs to finish setup". |
| apkrund crashed mid-session | Connection invalidated. The wrapper shows "APKRun restarted — reopening…" and retries `openSession` with backoff (1 s, 2 s, 4 s; max 3). The VM is gone, so it goes through a cold launch. |
| API major mismatch | Actionable error dialog. The wrapper never tries to continue. |
| APKRun or Android is updating (`HelloReply.hostState == updating`, `RuntimeFailure.hostUpdating`, or `ended(.runtimeUpdating)`) | The wrapper shows screen U "APKRun is updating" and retries `openSession` every 2 s for up to 10 minutes ([../02-design/wrapper.md](../02-design/wrapper.md) §5.4). The menu bar relaunches itself when `hello` reports another build ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.7) |
| Endpoint rejected (requirement mismatch) | The wrapper calls `requestApproval`. The user sees the approval prompt in APKRun.app. |

---

## 3. Host ↔ guest channels

### 3.1 Transports

**The host always initiates.** Every channel is opened by apkrund with `VZVirtioSocketDevice.connect(toPort:)` (guest CID 3). Development mode instead goes through an ADB forward to a local abstract socket. Using one direction on both transports keeps `GuestAgentConnection` a single connector with a pluggable transport. It also matches how ADB works.

| Channel | Production transport (custom image, M5+) | Development transport (stock image, M1–M4) | Guest endpoint |
|---|---|---|---|
| ADB | guest vsock **5555** (`adbd` listens on `vsock:5555` when `persist.adb.tcp.port=5555`, verified in adbd source). apkrund bridges it to `127.0.0.1:6520` (the Cuttlefish convention) for the `adb` CLI. | same | `adbd` |
| Guest Agent control | vsock 6100 → `apkrun_vsockd` → `@apkrun-guestd-control` | `adb forward tcp:0 localabstract:apkrun-guestd-control` | abstract Unix socket owned by `apkrun_guestd` |
| Guest Agent input stream | vsock 6101 → `@apkrun-guestd-input` | ADB forward, same name pattern | same |
| Guest Agent bulk data | vsock 6102 → `@apkrun-guestd-bulk` | ADB forward, same name pattern | same |
| APKRun IME (development only) | — (in the custom image the IME runs inside the Guest Agent process and uses the input stream) | `adb forward tcp:0 localabstract:apkrun-guest-ime` | abstract Unix socket owned by the IME service process ([../02-design/input.md](../02-design/input.md) §5.6) |
| Store Agent control | vsock 6110 → `@apkrun-store-control` | — (the Store Agent exists only on custom images) | abstract Unix socket owned by `io.apkrun.store` |
| Store Agent artifact stream | vsock 6111 → `@apkrun-store-artifacts` | — | same |
| Serial console | virtio-console port 0 (`hvc0`, `console=hvc0` on the cmdline) → `~/Library/Logs/APKRun/vm/console.log` | same | kernel |
| Reserved | vsock 6120–6199 for host-side service substitutes the Cuttlefish guest may need ([../02-design/android-image.md](../02-design/android-image.md) §7) | | |

- **Why a native bridge:** Android's platform sepolicy has a `neverallow` that forbids `vsock_socket {create bind accept connect}` for every domain except a short list (`adbd`, virtualization domains, …) and domains tagged `unconstrained_vsock_violators`. Untrusted apps may only `getattr getopt read write` inherited vsock fds. So neither `shell` (development `app_process`) nor an app domain can listen on vsock. `apkrun_vsockd` is a small native daemon (Rust, `Guest/vsockd/`) running in its own domain `apkrun_vsockd` with `typeattribute apkrun_vsockd unconstrained_vsock_violators`, the pattern Cuttlefish HALs use. It listens on the ports above and splices each accepted connection to the matching abstract socket. Its policy allows `connectto` only on the agents' domains (`apkrun_guest_app`, `apkrun_store_app`, assigned via `seapp_contexts`), so other Android apps cannot connect to the agents.
- **Authentication inside the guest:** besides SELinux, each agent checks `SO_PEERCRED` on accepted local connections. It only accepts uid `system`/`root` (the bridge) in production, or `shell` (the ADB forward) when developer mode is on.
- **One vsock device per VM** (framework limit). There is no guest-initiated channel in v1. If one is needed later, the host would use `setSocketListener(_:forPort:)`.
- **Reconnection:** if an agent restarts, the bridge still accepts vsock but the upstream connect fails, so it closes immediately. apkrund retries with backoff (100 ms doubling to 2 s) while `RuntimeState` is `booting` or `ready`, and reports `agent.disconnected` in health.
- ADB is bridged to host loopback only (NFR-SEC-06). Production runtime images keep `adbd` stopped unless the user enables "Developer mode" in APKRun settings. The host then sets the boot parameter `androidboot.apkrun.devmode=1` at the next Android start ([../02-design/android-image.md](../02-design/android-image.md) §11.3).
- The GuestProtocol handshake (§3.3) is identical on both transports.

### 3.2 Framing

Every stream carries length-prefixed frames: `uint32 big-endian length` + `Envelope` (Protocol Buffers). The maximum frame is 4 MiB. Bulk data larger than that (APKs, images) is chunked on the bulk or artifact streams. Details: [../02-design/guest-protocol.md](../02-design/guest-protocol.md).

### 3.3 Handshake (first frame on every connection)

```text
guest → host: Hello{ protocol_version{major,minor}, agent{kind, version, build}, runtime_image_version,
                     android{sdk_int, release, build_fingerprint}, capabilities[] }
host  → guest: HelloAck{ accepted | rejected(reason), host_protocol_version, session_token, enabled_capabilities[] }
```

A major-version mismatch results in `rejected`. The host marks the agent `incompatible` in health and surfaces a `GuestProtocolFailure.incompatibleVersion` error with remediation. The connection is closed (NFR-REL-04). Minor versions negotiate capabilities.

---

## 4. Threading and concurrency inside apkrund

| Component | Execution context |
|---|---|
| `VMController` | `actor`. VZ calls are made on the VM's dedicated serial `DispatchQueue` (VZ requirement) and bridged with `withCheckedThrowingContinuation`. |
| virtio-gpu device | The custom device's `deviceQueue` (serial) handles queue notifications. The renderer thread is a single dedicated thread for all virglrenderer/ANGLE calls (virglrenderer is not thread-safe; RiftVM does the same). |
| DisplayPool, SessionRegistry, InputRouter | `actor`s |
| Guest connections | One `actor` per connection over a `NWConnection`/file-descriptor based reader using `DispatchIO`. |
| XPC | NSXPC delivers calls on its own queue. Handlers immediately hop to the owning actor. |
| Update scheduling | `actor UpdateScheduler` with `Task`s. Downloads use `URLSession` with background-friendly configuration. |

Rule: no blocking calls on actor executors. Blocking C APIs (virglrenderer) run only on the renderer thread.
