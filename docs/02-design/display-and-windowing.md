# Display and Windowing Design (DisplayPool + WindowingCore)

| Field | Value |
|---|---|
| Status | Design baseline |
| Related | [graphics.md](graphics.md), [input.md](input.md), [guest-components.md](guest-components.md), [guest-protocol.md](guest-protocol.md), [wrapper.md](wrapper.md), [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3–§4, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3, ADR [0005](../01-architecture/decisions/0005-multi-display-window-model.md), [0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md) |
| Tasks | #026, #028, #029, #030, #067, #068, #079 (window-mode setting), #070 (launch latency budget) |

---

## 1. Responsibilities

| Component | Process | Owns |
|---|---|---|
| `GraphicsCore` `ScanoutController` | apkrund | Scanout modes, display change events, `SurfacePool`s, blits ([graphics.md](graphics.md) §6) |
| `RuntimeCore` `DisplayPool` | apkrund | Which scanout belongs to which session; attaching and releasing Android displays; mapping scanout ↔ Android display ID; display geometry (pixel size, density); reuse without stale content |
| `RuntimeCore` `SessionRegistry` | apkrund | `AppSessionState` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3); forwards frames and geometry between the session channel and `DisplayPool` |
| Guest Agent (`apkrun_guestd`) | guest | Reports Android display add/change/remove; sets per-display density and IME policy; launches the app on a display; reports tasks on each display ([guest-components.md](guest-components.md)) |
| `RuntimeClient` session object | wrapper | Receives `SessionDescriptor` and frame events and sends input, all as RuntimeAPI wire types. The launcher's `XPCFrameSource` and `XPCInputSink` adapt it to WindowingCore's `FrameSource` and `InputSink` ([../01-architecture/modules.md](../01-architecture/modules.md) §2) |
| `WindowingCore` | wrapper (and the CLI in embedded dev mode) | `NSWindow`, the IOSurface layer, geometry and backing scale reporting, live resize, fullscreen, placeholder and error UI, window restoration, close policy |
| `InputCore` | wrapper | `NSEvent` → `InputEvent` in display pixel coordinates using the mapping from §6.1 ([input.md](input.md)) |

Invariants:

1. One live session per package, one display per session, one window per session ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3, FR-DSP-01).
2. A scanout is presented only to the session that holds its lease. A released scanout's frames never reach another session (#028 "no stale scanouts").
3. Pixels reach the window only through the IOSurface pool (no copies, no readbacks; FR-GFX-05, FR-DSP-07).
4. The wrapper never talks to the guest. apkrund never creates windows (ADR-0006).

```text
Wrapper process (Discord.app)               apkrund                                         guest
┌───────────────────────────────┐   XPC   ┌──────────────────────────────────────┐  vsock ┌─────────────────────┐
│ SessionWindowController       │◀───────▶│ SessionRegistry ── session S1         │◀──────▶│ Guest Agent         │
│  IOSurfaceLayerView (layer)   │ frames  │   │                                   │        │  DisplayListener    │
│  InputCore → InputSink        │ input   │ DisplayPool: S1 → lease(scanout 3,     │        │  launch on display  │
│  FrameSource ← RuntimeClient  │         │            androidDisplay 7, pool gen) │        │  set density / IME  │
└───────────────────────────────┘         │   │                                   │        └─────────────────────┘
                                          │ ScanoutController (GraphicsCore)      │  virtio-gpu scanout 3
                                          │   SurfacePool[3] ◀── blit ◀── VirGL   │◀──────── SurfaceFlinger
                                          └──────────────────────────────────────┘          (Android display 7)
```

---

## 2. Display model

- **Scanouts 1…15** form the pool. Each app session in `secondaryDisplay` mode gets one ([ADR-0005](../01-architecture/decisions/0005-multi-display-window-model.md)).
- **Scanout 0** is Android's primary display (`Display.DEFAULT_DISPLAY`). It runs the launcher and system UI and is never shown in `secondaryDisplay` mode (no pool attached, so no host blits; [graphics.md](graphics.md) §6.1). It is shown only in `primaryDisplayCompatibility` mode (§8).
- Pool displays are **physical displays to Android** (DRM connectors reported by the ranchu HWC with `display_finder_mode=drm`). They are not `VirtualDisplay`s. Android treats them as external displays: public, `FLAG_PRESENTATION`, and no system decorations unless configured.
- Capacity: 15 hardware slots. The soft limit is `display.maxSessions` (default 8, range 1–15, [../03-reference/configuration.md](../03-reference/configuration.md)). It bounds guest and host graphics memory (R-08). Exhaustion returns `RuntimeFailure.displayPoolExhausted` with the remediation "Close another Android app window". System uses (`SessionID.system`, §3.1) do not count toward the soft limit, only toward the 15 hardware slots, and hold a display for at most 90 s.

Why real displays instead of `VirtualDisplay`: frames of a guest `VirtualDisplay` end up in a guest `Surface`. Getting them to the host would need encoding or readback, which breaks the zero-readback requirement (ADR-0005).

---

## 3. DisplayPool (#028)

### 3.1 API

```swift
public struct DisplayGeometry: Sendable, Equatable {
    public var pointSize: CGSize              // window content size in macOS points
    public var backingScale: Double           // NSWindow.backingScaleFactor (1.0 or 2.0 today)
    public var zoom: Double                   // per-package preference, 0.75...2.0, default 1.0
}

public struct DisplayConfiguration: Sendable, Equatable {
    public var geometry: DisplayGeometry
    public var mode: AndroidWindowMode        // .secondaryDisplay | .primaryDisplayCompatibility
}

public struct ResolvedDisplayMode: Sendable, Equatable {    // output of DisplayGeometryResolver (§6)
    public var pixelSize: PixelSize
    public var densityDpi: Int
    public var renderScale: Double            // ≤ backingScale
    public var refreshHz: Int                 // 60
}

/// Who holds a display. App sessions have windows. System uses have no window and no client.
public enum SessionID: Sendable, Hashable, Codable {
    case app(UUID)                                   // an AppSession (runtime-daemon.md §7)
    case system(SystemDisplayUse)
}

public enum SystemDisplayUse: Sendable, Hashable, Codable {
    case setupVerification                           // runtime-daemon.md §9.2
    case migrationCheck                              // android-image.md §12.3
    case updateHealthCheck(PackageID)                // update-system.md §8.2
}

public struct DisplayLease: Sendable, Equatable {
    public let leaseID: UUID
    public let session: SessionID
    public let scanout: ScanoutID
    public let androidDisplayID: Int32        // Android's logical display ID, reported by the Guest Agent
    public let mode: ResolvedDisplayMode
    public let pool: SurfacePoolHandle        // generation + surfaces, sent to the wrapper
}

public actor DisplayPool {
    public init(scanouts: ScanoutController, guest: any DisplayControlChannel, limits: DisplayPoolLimits)
    public func acquire(for session: SessionID, configuration: DisplayConfiguration) async throws(RuntimeFailure) -> DisplayLease
    public func reconfigure(_ lease: DisplayLease, geometry: DisplayGeometry) async throws(RuntimeFailure) -> DisplayLease
    public func release(_ lease: DisplayLease) async                  // never throws; faults are recorded
    public func snapshot() -> [DisplaySlotSnapshot]                   // diagnostics, `apkrun info --displays`
    public nonisolated var events: AsyncStream<DisplayPoolEvent> { get }   // slot state changes, faults
}

public protocol DisplayControlChannel: Sendable {                     // implemented over GuestProtocol (guest-protocol.md)
    var displayEvents: AsyncStream<GuestDisplayEvent> { get }          // added / changed / removed, tasks on display
    func setDisplayPolicy(_ displayID: Int32, density: Int, imePolicy: ImeDisplayPolicy) async throws(RuntimeFailure)
    func clearDisplay(_ displayID: Int32) async throws(RuntimeFailure) // remove or move away every task on it
}
```

`DisplayPool` is the only caller of `ScanoutController.configure`/`disable`/`attach`/`detachPool` in the product. Development commands before #028 call `ScanoutController` directly for scanout 0 only.

### 3.2 Slot states

The states are defined in [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §4 (`free`, `attaching`, `allocated(SessionID)`, `releasing`, `faulted`). The #028 names map to them as follows:

| #028 | This design | Meaning |
|---|---|---|
| available | `free` | scanout disabled; Android has no display for it |
| allocated | `attaching` | reserved for a session; scanout enabled; waiting for Android's `DisplayAdded` |
| attached | `allocated(SessionID)` | bound to an Android display ID and to a session's window |
| releasing | `releasing` | tasks being cleared, scanout being disabled |
| available | `free` | ready for reuse |
| — | `faulted(DisplayFault)` | attach or release failed (`.attachTimedOut`, `.releaseTimedOut`, `.graphics(GraphicsFailure)`); the slot is quarantined until reset |

Per slot the pool also keeps `reservedBy: SessionID?`, `androidDisplayID: Int32?`, `mode`, `generation` (incremented on every acquire), and timestamps for diagnostics.

### 3.3 Acquire sequence

Attaches are **serialized** (one `attaching` slot at a time). This makes the scanout ↔ Android display correlation unambiguous and keeps the display event logic in [graphics.md](graphics.md) §4.3 simple. Concurrent `acquire` calls queue in FIFO order.

1. Pick the lowest-numbered `free` slot (deterministic slot use helps diagnostics). If none is free, or the soft limit is reached, throw `.displayPoolExhausted`.
2. Resolve the mode from the geometry (§6). Mark the slot `attaching` and record `reservedBy`.
3. `ScanoutController.configure(scanout, mode)`. GraphicsCore writes the new EDID and raises the display event.
4. Wait for `GuestDisplayEvent.added(displayID, info)` where `info.productInfo` matches the scanout (EDID manufacturer `APK`, product code = scanout index; exposed to Android apps through `Display.getDeviceProductInfo()`, API 31). The timeout is 5 s ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §4). If the product info is missing, the pool falls back to "the only display added while this slot is attaching". It logs that fallback once per boot.
5. Check that `info.mode` equals the requested pixel size. A mismatch is logged, and the lease uses Android's actual size.
6. `setDisplayPolicy(displayID, density:, imePolicy: .local)` (§4).
7. Allocate a new `SurfacePool` at the pixel size (a new pool per lease, never reused across sessions) and `ScanoutController.attach(pool, to: scanout)`.
8. Mark the slot `allocated(session)` and return the lease. The wrapper receives the pool's surfaces in the `SessionDescriptor`.

Failure handling:

- A timeout in step 4 marks the slot `faulted(.attachTimedOut)`. The pool disables that scanout, retries the acquire **once** on the next free slot, and then fails with `RuntimeFailure.displayAttachFailed`. A faulted slot is reset in the background: disable, wait for `removed` or 3 s, then `free`. After three faults in a boot, the slot stays `faulted` until the next Android restart.
- If the Guest Agent disconnects during an acquire, the operation fails with `.guestAgentUnavailable`, and the slot is released.

### 3.4 Release sequence

1. Mark the slot `releasing`. `ScanoutController.detachPool(from:)` runs **first**, so no frame of this scanout reaches the wrapper from this point (invariant 2).
2. `clearDisplay(displayID)`. The Guest Agent finishes or moves every task on the display according to the close policy (§7.6), then reports `tasksCleared`.
3. `ScanoutController.disable(scanout)`. Android removes the display.
4. Wait for `GuestDisplayEvent.removed(displayID)` (timeout 3 s). The slot becomes `free`. The old pool is released when the wrapper's session connection closes, or at the latest 1 s after detach.

If step 2 times out (5 s), the scanout is disabled anyway. Android moves the remaining tasks to the default display when a display is removed, which is acceptable for a closing session.

### 3.5 Reuse without stale content

- Each lease gets a **fresh `SurfacePool`**. The wrapper never sees surfaces from a previous session.
- The pool is attached only after `DisplayAdded`, and `AppSessionState` moves `launching → running` on the first frame **after** `LaunchApplication` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3). Until then the wrapper shows the placeholder (§7.3), so it never shows a previous app's last frame or an empty black display.
- The guest's framebuffer for a re-enabled display is newly allocated by SurfaceFlinger after `DisplayAdded`, so no guest-side content can survive either.
- T0 tests model the whole pool with fake channels and fake scanouts and assert invariant 2 across random acquire/release/fault sequences.

### 3.6 Display 0

Scanout 0 is always enabled. `DisplayPool` does not lease it in `secondaryDisplay` mode. In `primaryDisplayCompatibility` mode it is leased like a pool slot, but only one session at a time can hold it (§8). Its lease skips steps 3–4 of §3.3: the display already exists, so the pool reconfigures its mode instead, as in §6.3.

---

## 4. Android-side display configuration

The Guest Agent applies these settings. Their messages are in [guest-protocol.md](guest-protocol.md), and the privileges each one needs (shell uid in development, `apkrun_guest_app` in the custom image) are in [guest-components.md](guest-components.md).

| Setting | How | When | Why |
|---|---|---|---|
| Per-display density | `IWindowManager.setForcedDisplayDensityForUser(displayID, dpi, USER_CURRENT)` (the same call as `wm density <dpi> -d <id>`) | after `DisplayAdded`, and on reconfigure | SurfaceFlinger gives external displays a fallback density of 213 (`ACONFIGURATION_DENSITY_TV`); we need 160 × renderScale × zoom (§6) |
| IME placement | `IWindowManager.setDisplayImePolicy(displayID, DISPLAY_IME_POLICY_LOCAL)` | after `DisplayAdded` | Editors on the app's display get the APKRun IME there instead of on hidden display 0 ([input.md](input.md)) |
| No system decorations | defaults (external displays have none); the custom image keeps `force_desktop_mode_on_external_displays=0` | image default | No launcher, status bar, or navigation bar inside app windows (#026 "hide unnecessary emulator chrome") |
| Stay awake, no keyguard | `svc power stayon true`, `locksettings set-disabled true`, screen-off timeout max; the custom image sets them as defaults | Guest Agent start ([guest-components.md](guest-components.md)) | External displays follow the default display's power state, and a keyguard would cover app displays |
| Launch on a display | `ActivityOptions.makeBasic().setLaunchDisplayId(id)` + `setLaunchWindowingMode(WINDOWING_MODE_FULLSCREEN)`, started with `FLAG_ACTIVITY_NEW_TASK` | `LaunchApplication` | Fullscreen task on the session's display. Allowed for the shell uid and the privileged agent (`INTERNAL_SYSTEM_WINDOW`, `ActivityTaskSupervisor.isCallerAllowedToLaunchOnDisplay`) |
| Task tracking | `ITaskStackListener` / `TaskInfo.displayId` | always | Reports `taskAppeared`, `taskVanished`, and `displayEmpty` per display to the host (§7.6) |

Activities started by the app, including other packages' activities (permission dialogs, the DocumentsUI picker, share targets), launch on the caller's display. That is the display of the session, so they appear inside the app's window. URL intents can be redirected to the Mac instead ([desktop-integration.md](desktop-integration.md)).

---

## 5. Frame delivery and buffer release (#068)

This section defines the cross-process protocol between GraphicsCore's `SurfacePool` ([graphics.md](graphics.md) §6.3) and the wrapper's layer. It is the "frame pacing needs cross-process buffer management" consequence of ADR-0006.

### 5.1 Messages (session channel)

The complete list is in [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3. The frame-related messages are:

```text
server → wrapper
  SessionDescriptor{ …, surfaces: SurfaceSet{ generation, [IOSurface] (3), pixelSize, densityDpi } }
  frameReady(generation, surfaceIndex, frameSeq, presentationTime)
  surfacesReplaced(SurfaceSet)
wrapper → server
  frameDisplayed(generation, frameSeq)
  visibilityChanged(visible: Bool)
```

`frameSeq` is monotonic per session across generations. `presentationTime` is the host `mach_absolute_time` at GPU completion.

### 5.2 Buffer states

Each buffer of a pool is in exactly one state. apkrund owns the state. The wrapper influences it only through `frameDisplayed`.

```text
          acquireForRender            blit GPU-complete            wrapper frameDisplayed(seq)
  free ───────────────────▶ rendering ─────────────────▶ offered(seq) ───────────────────────▶ displayed(seq)
   ▲                                                         │                                    │
   │         superseded: frameDisplayed(seq' > seq) received │                                    │ frameDisplayed(seq' > seq)
   └───────────────── (and IOSurfaceIsInUse == false) ◀──────┴────────────────────────────────────┘
```

Rules:

1. **Offered buffers are never overwritten.** Once `frameReady(i, seq)` has been sent, buffer *i* may be on screen at any moment, so it is not reused until the wrapper reports a newer frame displayed.
2. A buffer becomes `free` when both hold: (a) the wrapper reported `frameDisplayed` for a newer sequence, and (b) `IOSurfaceIsInUse(surface) == false`. The use count is global, and WindowServer holds it while it composites the surface. (b) is checked at acquire time. A buffer that is still in use is skipped for this frame.
3. With three buffers the steady state is one `displayed`, at most one `offered`, and one `rendering`. If a flush arrives and no buffer is free, GraphicsCore keeps only the **latest** pending present and performs it when a buffer frees (latest frame wins; [graphics.md](graphics.md) §6.2). The skipped frame counts as `droppedFrames`.
4. **Back-pressure timeout.** If no `frameDisplayed` arrives for 1 s while frames are offered, the session is treated as not visible (as with `visibilityChanged(false)`), and presents stop until the wrapper reports a frame displayed or becomes visible. This protects apkrund from a hung wrapper.
5. **Visibility.** On `visibilityChanged(false)` (window minimized, fully occluded, on another Space, or the app hidden), GraphicsCore stops blitting that scanout. Guest flushes still complete. The session enters `backgrounded`. On `visibilityChanged(true)`, `ScanoutController.requestPresent(scanout)` ([graphics.md](graphics.md) §6.1) re-blits the currently bound resource immediately, without waiting for a guest flush, so the window is current at once.
6. **Generations.** After `surfacesReplaced(generation g+1)`, messages with generation g are ignored on both sides. The old pool is released after the first `frameDisplayed` of generation g+1, or after 1 s.

### 5.3 Wrapper presentation algorithm

Implemented by `IOSurfaceLayerView` (WindowingCore) on the main thread:

```text
on frameReady(gen, i, seq, t):
    if gen != currentGeneration or seq <= lastShownSeq: return          // stale or reordered
    CATransaction.begin(); CATransaction.setDisableActions(true)
    contentLayer.contents = surfaces[i]                                 // IOSurface as layer contents: zero-copy
    CATransaction.setCompletionBlock { session.frameDisplayed(gen, seq) }
    CATransaction.commit()
    lastShownSeq = seq
```

- The content layer is a plain `CALayer` with `contents` set to the `IOSurface`. There is no `CAMetalLayer` and no second blit in the wrapper. A buffer is never offered twice in a row, so each assignment is a new object and Core Animation always picks up the change.
- `contentsGravity` is `.resize` in steady state (the pool size equals the view's backing size) and `.resizeAspect` during live resize (§7.2). `contentsScale` = `renderScale` (§6.1).
- The frame event is delivered to the main queue with `DispatchQueue.main.async` from the XPC queue. If the main thread is busy, events coalesce: only the newest pending `frameReady` is applied.
- `frameDisplayed` is sent from the transaction completion block, which runs after Core Animation has committed the new contents. Combined with rule 2(b) this makes reuse safe without knowing WindowServer's timing.
- In embedded development mode (before #031/#032) the same view is fed by `SurfacePoolFrameSource` in `CLI/apkrun/Dev/` (#023). It adapts the `SurfaceSet` and frame events of the embedded-only `DeveloperService` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §15) to `FrameSource` and reports `frameDisplayed` back to it, in process instead of over XPC. Neither WindowingCore nor the CLI imports GraphicsCore.

### 5.4 Color and format

- Pool surfaces are `BGRA8` with the `kIOSurfaceColorSpace` property set to sRGB. The content layer is color-matched by WindowServer on P3 and XDR displays. Android renders sRGB. Wide color and HDR are post-v1.
- The layer is opaque (`isOpaque = true`). The blit already forces alpha to 1 ([graphics.md](graphics.md) §6.2).

### 5.5 Verification (#068)

- T0: a model test of the buffer state machine with a scripted wrapper (displays some frames, delays others, stops acknowledging, flips visibility) asserts rules 1–6 and that no offered buffer is ever rendered into.
- T2: HelloGL in a wrapper window for 60 s at 60 fps: zero tearing (the alternating-color test from [graphics.md](graphics.md) §12 #023), `readyToDisplayed` p95 < 1 refresh interval + 4 ms, present cost < 2 ms p95 (ADR-0006), and `hostReadbacks = 0`.

---

## 6. Geometry, density, and scale (#067)

### 6.1 From window to Android display

`DisplayGeometryResolver` (RuntimeCore, pure function, T0-tested) maps a `DisplayGeometry` to a `ResolvedDisplayMode`:

```text
renderScale = min(backingScale, 4095 / pointWidth, 4095 / pointHeight)        // EDID DTD limit, graphics.md §6.4
pixelSize   = (round(pointWidth × renderScale), round(pointHeight × renderScale)) rounded down to even numbers
densityDpi  = round(160 × renderScale × zoom)
refreshHz   = 60
```

Consequences:

- At `zoom = 1.0`, **one Android dp is one macOS point**. A 480 × 850 pt window on a Retina Mac is a 960 × 1700 px display at 320 dpi (`xhdpi`), and the app sees a 480 × 850 dp screen, the same as a mid-size phone.
- `zoom > 1` enlarges the Android UI (fewer dp in the same window). `zoom < 1` shows more content. View menu: Zoom In (⌘=), Zoom Out (⌘−), Actual Size (⌘0). The value is stored per package in `settings.json` (`window.zoom`, [../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md)). The write path is the `resize` that carries the new zoom: apkrund stores it and posts `packages.settingsChanged` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §14.3).
- If the backing pixel size would exceed 4095 px (for example a fullscreen window on a 5K or 6K display), `renderScale` drops below `backingScale`. Android renders fewer pixels, the layer upscales them (`contentsScale = renderScale`), and the dp size stays the same. A DisplayID extension for larger modes is post-v1 ([graphics.md](graphics.md) §6.4).
- The EDID physical size is derived from `densityDpi`, so the DPI reported to Android is consistent with the forced density. Android's `xdpi`/`ydpi` values follow the EDID. `densityDpi` follows the forced density (§4).

### 6.2 Limits

| Item | Value | Reason |
|---|---|---|
| Minimum content size | 320 × 400 dp → points = dp × zoom | Android phone UI assumptions (smallest width ≥ 320 dp) |
| Maximum content size | the screen's visible frame; pixel size capped by §6.1 | EDID limit |
| Density range | 120–640 dpi | outside this, `zoom` is clamped |
| Default window size | from the package settings `window.defaultWidth/defaultHeight` (initially copied from `wrapper.json`, [wrapper.md](wrapper.md) §3; points, default 480 × 850 portrait; 850 × 480 if the launcher activity requests landscape), clamped to 90 % of the screen's visible frame | Initial preference copied from the generated app |

### 6.3 Display 0 geometry

Display 0 boots with the image's default mode and `androidboot.lcd_density = 160 × backing scale of the main screen at boot` ([android-image.md](android-image.md) §6.2). In `primaryDisplayCompatibility` mode it is reconfigured to the window geometry with the same path as pool displays (§7.1), including forced density.

---

## 7. Windows (WindowingCore, #026, #067)

### 7.1 Resize

#023 used a fixed-size development window. From #067 windows are resizable when `window.resizable` is true (default true, or false if #067 has to take fallback B below).

```text
wrapper                                  apkrund                                    guest
windowWillStartLiveResize: gravity=.resizeAspect (last frame scaled, letterboxed black)
... user drags ...
windowDidEndLiveResize (+150 ms quiet)
resize(DisplayGeometry) ─────────────▶ SessionRegistry → DisplayPool.reconfigure(lease, geometry)
                                        resolve mode (§6.1); ScanoutController.configure(scanout, mode)
                                                              ─── new EDID + display event ───▶ HWC / SurfaceFlinger
                                        ◀─────────── GuestDisplayEvent.changed(displayID, newMode) (≤ 3 s)
                                        setDisplayPolicy(displayID, density) ─────────────────▶ app gets config change
                                        new SurfacePool (generation+1), attach to scanout
◀────────────── surfacesReplaced(SurfaceSet g+1)
gravity=.resize; frames of g+1 ...
```

- During live resize the input mapping uses the letterboxed content rect of the old frame ([input.md](input.md)).
- Between the mode change and the app's re-layout, the guest may still flush old-size frames. The blit scales them into the new pool ([graphics.md](graphics.md) §6.2), so the window never shows garbage.
- Resizing makes Android deliver `screenSize`/`smallestScreenSize`/`orientation` (and, with zoom, `density`) configuration changes. Apps that do not handle them are recreated. This is normal Android behavior (like freeform windows on tablets and ChromeOS).
- Resize requests are coalesced: while a reconfigure is in flight, only the latest geometry is kept and applied next.

**Open point for #067 (R-04):** does a mode change keep the same Android display ID? The ranchu HWC may report a mode change as disconnect + connect. SurfaceFlinger derives the physical display ID from the EDID (manufacturer, product, port), so it stays stable, but DisplayManager could still allocate a new logical display. #067 tests this first. Fallbacks, in order:

- **A.** Re-home the task: acquire a new slot at the new size, move the task with `IActivityTaskManager.moveRootTaskToDisplay(taskId, newDisplayID)`, and release the old slot. The app keeps running (with a configuration change), and the window gets new surfaces as in a resize.
- **B.** Fixed-size windows: `window.resizable` defaults to false. Only zoom and backing-scale changes remain, and they apply at the next session start.

The chosen behavior is recorded in §11 and in R-04.

### 7.2 Backing scale and screen changes

- `NSWindow.didChangeBackingPropertiesNotification` (the window moved to a screen with another scale) triggers a `resize` with the new `backingScale`, handled like §7.1.
- Moving between screens with the same scale needs no action.
- ProMotion and other refresh rates: v1 always uses 60 Hz modes. 120 Hz is post-v1 (it needs a HWC mode with a matching vsync period).

### 7.3 Window contents and placeholder

`SessionWindowController` (WindowingCore) shows one of these, driven by the session event `stateChanged` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §6.3):

| Session state | Window shows |
|---|---|
| `starting`, `booting(progress)` (the `SessionPhase` of the states `requested`, `acquiringDisplay`, and `waitingForRuntime`, [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §6.2) | app icon centered, the app name, and "Starting Android…" with boot phase text from `RuntimeState` |
| `waitingForPackage` (a store transaction of the package runs, [runtime-daemon.md](runtime-daemon.md) §7.1) | app icon and "Updating ‹App›…" |
| launching (no frame yet) | app icon with an indeterminate progress indicator |
| `running` | the IOSurface content layer only |
| `ended(.error(...))` | error panel: message, remediation, "Try Again", "Open APKRun" ([../03-reference/error-catalog.md](../03-reference/error-catalog.md)) |
| `ended(.appCrashed)` | "‹App› stopped unexpectedly" with "Reopen" |

The window is a standard titled window: title = app display name, a black background, `collectionBehavior = [.fullScreenPrimary]`, and `tabbingMode = .disallowed` (one window per app). There is no emulator frame, toolbar, or navigation buttons. Android navigation uses keyboard mappings (Esc → Back, [input.md](input.md)).

### 7.4 Fullscreen

Entering fullscreen is a resize to the screen size (§7.1), with the 4095 px cap (§6.1). The toolbar-less window uses the standard fullscreen behavior (menu bar and title bar reveal on hover).

### 7.5 Focus, visibility, and restoration

- Key window changes send `focusChanged(Bool)`. The Guest Agent moves Android focus to the session's display (per-display focus is disabled by default in AOSP, so keys go to the top-focused display). See [input.md](input.md).
- `NSWindow.occlusionState`, minimize, and `NSApplication` hide/unhide send `visibilityChanged` (§5.2 rule 5).
- Window frame restoration uses `setFrameAutosaveName("APKRunSessionWindow")` in the wrapper's own defaults domain. Each wrapper has its own bundle ID, so each app remembers its own frame. A saved frame wins over `window.defaultWidth`/`defaultHeight`. Those apply only when no frame is saved (the first launch, or after **Reset** of the window settings), and a saved frame is clamped to the screen like the default (§6.2).

### 7.6 Close policy (#026)

A wrapper has exactly one window. **Closing the window ends the session and quits the wrapper**, like single-window Mac apps. ⌘W, ⌘Q, the red close button, and "Quit" in the Dock menu all do this.

`closeSession(policy)` uses the package preference `window.closeBehavior`:

| Policy | Default | Android effect |
|---|---|---|
| `stop` | yes | The Guest Agent removes the session's tasks (`IActivityTaskManager.removeTask`, as when swiping an app away in Recents). The process may stay cached by Android, which speeds up the next launch |
| `keepRunning` | no (a per-app setting, useful for music or messaging apps) | The Guest Agent moves the root task to display 0 behind the launcher (`moveRootTaskToDisplay(taskId, 0)`, then to back). Audio and notifications continue. The next launch moves the task to a new display instead of starting a new one |

Then the display is released (§3.4). The session ends with `.userClosed` when the Guest Agent reports `tasksCleared`, or after 5 s ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3).

When the app itself leaves its display (Back from the root activity, or the app finishing its task), the Guest Agent reports `displayEmpty`. The session ends with `.appExited`, and the wrapper closes its window and quits, like returning to the home screen on a phone.

### 7.7 Other window behavior

| Topic | v1 behavior |
|---|---|
| Cursor | macOS arrow. Android pointer icons (I-beam, hand) are post-v1 |
| Multiple windows per app | not supported. All tasks of the package's session share its display |
| Always on top | `window.alwaysOnTop` (default off, FR-UI-03): the window uses `NSWindow.Level.floating`. It has no effect in full screen. A change applies at once to an open window (session event `windowPrefsChanged`, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3) ([host-ui.md](host-ui.md) §7.2) |
| Accessibility | window title and role only. Android's accessibility tree is not bridged in v1 ([../00-product/scope.md](../00-product/scope.md)) |
| Frame statistics overlay | developer mode only: View → Show Frame Statistics (fps, latency, drops, readbacks from [graphics.md](graphics.md) §7). While the overlay is shown, the launcher sends the session channel request `frameStatistics` once per second. apkrund answers with the session's `SessionGraphicsStatistics` from `ScanoutController.statistics` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §6.3). Built in #070 |
| Screenshots | macOS window screenshots work, because the layer holds real pixels |
| Orientation requests | Android letterboxes fixed-orientation apps that do not match the window aspect. The wrapper does not rotate the window in v1. Whether to swap width and height automatically is decided in #067 |

---

## 8. Window modes (#029, #079)

| Mode | Display | Limit | Use |
|---|---|---|---|
| `secondaryDisplay` (default) | own pool display (scanouts 1–15) | `display.maxSessions` | every app unless it misbehaves |
| `primaryDisplayCompatibility` | display 0 | one session at a time | apps that assume the default display (for example they use `getDefaultDisplay()` metrics, or crash or render blank on a secondary display) |

- The mode is a per-package setting (`window.mode`) with the default from the compatibility database (#090) or the user (Settings → App → Window mode, #079). It changes at the next session start.
- A second compatibility session while display 0 is taken fails with `RuntimeFailure.primaryDisplayBusy` and the remediation "Close ‹other app› or switch one of them to the standard window mode".
- While display 0 is leased, the launcher is behind the app. When the session ends, the Guest Agent brings the launcher to the front, and the pool detaches scanout 0 again.
- Display 0 shows Android's status bar and navigation bar in compatibility mode. The custom image (#035) hides the navigation bar (`config_showNavigationBar = false` overlay). The status bar stays visible in v1 ([../04-plan/open-questions.md](../04-plan/open-questions.md)).
- #029 establishes which of the fixture apps and the popular app sample run correctly on secondary displays. The results go to §11 and to the compatibility database seed (#090).

---

## 9. Launch sequence and latency budget (#070)

Warm state (VM running, Android `ready`, app not running), HelloText. Target NFR-PERF-01: click → first frame p50 ≤ 1.5 s, measured from the click to `FIRST_FRAME_DISPLAYED` ([diagnostics.md](diagnostics.md) §9.3).

| Step | Perf marker ([diagnostics.md](diagnostics.md) §4) | Budget (p50) |
|---|---|---|
| Wrapper process start → `openSession` sent | `APP_LAUNCH_REQUEST` | 150 ms |
| `DisplayPool.acquire`: configure → `DisplayAdded` → policy → pool | `DISPLAY_ATTACHED` | 300 ms |
| `LaunchApplication` → activity resumed | `ACTIVITY_STARTED` | 800 ms |
| first guest flush → `frameReady` → shown | `FIRST_FRAME`, then `FIRST_FRAME_DISPLAYED` (the wrapper's first `frameDisplayed`) | 100 ms |
| Margin | | 150 ms |

If #070 measures `DISPLAY_ATTACHED` above budget, the planned optimization is a **warm spare**: one enabled, empty, unleased display kept ready (a new slot state `spare` between `free` and `allocated`). It is not built up front because it costs guest memory and composition work.

---

## 10. Errors and logging

| Error (`RuntimeFailure`) | Cause | Remediation |
|---|---|---|
| `displayPoolExhausted` | no free slot or soft limit reached | close another Android app window; raise `display.maxSessions` |
| `displayAttachFailed(scanout, reason)` | no `DisplayAdded` after retry | restart Android (Settings → Troubleshooting); attach diagnostics |
| `displayReconfigureFailed(reason)` | mode change not confirmed within 3 s | the window keeps the old size; try again |
| `primaryDisplayBusy(packageID)` | a second compatibility session | see §8 |
| `guestAgentUnavailable` | the agent disconnected during an operation | automatic reconnect ([runtime-daemon.md](runtime-daemon.md)) |

Logging: `io.apkrun.runtime` category `display` (slot transitions, correlation, timings) and `io.apkrun.wrapper` category `window` (geometry, visibility, presentation stalls). Every slot transition is logged at info level with slot, lease, session, and Android display ID.

`apkrun info --displays` prints the pool snapshot: slot, state, session, package, Android display ID, pixel size, density, generation, fps.

---

## 11. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| Does a config-space update raise a display event in Linux and Android? | #019, #028 | pending: the #019 spike is implemented but has not run, see IR-251 and IR-256 ([graphics.md](graphics.md) §4.3) |
| Does `Display.getDeviceProductInfo()` expose the EDID product code on pool displays? | #028 | pending |
| Does a mode change keep the Android display ID? | #067 (display 0), #028 (pool displays) | pending (§7.1) |
| Density: does the forced density replace the default density (display 0) and the fallback 213 (pool displays) without side effects? | #067 (display 0), #028 (pool displays) | pending (§4, OQ-39) |
| IME policy `LOCAL` on pool displays works with the APKRun IME | #071 | pending |
| Fixture and sample apps on secondary displays | #029 | pending (§8) |
| `IOSurfaceIsInUse` reflects WindowServer use of layer contents | #068 | pending (§5.2) |
| Gate G4: HelloText renders and accepts input in a native Mac window ([../04-plan/roadmap.md](../04-plan/roadmap.md) §2) | #026 | pending (§12 #026) |
| Gate G5: HelloText and HelloCompose in two windows, each on its own Android display, input reaching only its app | #030 | pending (§12 #030) |
| HelloGL over XPC for 60 s at 60 fps: no tearing, `readyToDisplayed` p95 < 1 refresh interval + 4 ms, present cost < 2 ms p95, `hostReadbacks = 0` | #068 | pending (§5.5) |
| Warm launch of HelloText: click → first frame p50 ≤ 1.5 s, and each step within its budget | #070 | pending (§9) |

---

## 12. Implementation steps

### #026 HelloText in a native Mac window (M3, gate G4)

Embedded development mode, display 0, before DisplayPool.

1. WindowingCore: `SessionWindowController`, `IOSurfaceLayerView`, the `FrameSource`/`InputSink` protocols, placeholder states (§7.3). The window is fixed-size, with the display 0 mode from the image.
2. `SurfacePoolFrameSource` for embedded mode (through `DeveloperService`, §5.3).
3. `apkrun dev launch <apk|package>` ([cli.md](cli.md)): boots Android if needed (embedded runtime), installs the APK over ADB, launches it on display 0 through the Guest Agent (#072), and opens the window. Pointer and keyboard go through InputCore → Guest Agent (#024, #025).
4. The close policy (§7.6) is implemented with `stop` only. Closing the window stops the app. The CLI exits when the last window closes.
5. Acceptance: launching opens a normal Mac window containing HelloText. Clicking the button and typing into its text field work. There is no emulator chrome.

### #028 DisplayPool (M3)

1. `DisplayPool` actor with slot states, the serialized acquire (§3.3), release (§3.4), and fault handling, against `FakeScanoutController` and `FakeDisplayControlChannel`. Add the T0 property test for invariant 2 (§3.5). It uses `DisplayGeometryResolver` (§6.1), which #067 builds; #028 depends on #067.
2. The Guest Agent's display messages ([guest-protocol.md](guest-protocol.md)): `DisplayAdded/Changed/Removed`, `SetDisplayPolicy`, `ClearDisplay`, task events.
3. Integration: `ScanoutController` + Guest Agent on Android. `apkrun dev displays add|remove|list` exercises the pool without apps.
4. Acceptance: 50 cycles of acquire → release across slots with no stale frames (checked by the T2 test via the first-frame rule), no duplicate Android display IDs, and every slot `free` at the end. Record the hotplug findings in §11.

### #029 App on a secondary display (M3)

1. `LaunchApplication(package, displayID)` in the Guest Agent (§4 launch options).
2. `apkrun dev launch --display secondary <apk>` acquires a pool display and opens the window on its scanout.
3. Run HelloText, HelloCompose, HelloGL, and HelloWebView on a secondary display. Record per app whether rendering, input, IME, and dialogs work (§11, §8).
4. Acceptance: HelloText renders correctly on a non-primary display and accepts input.

### #030 Two APKs in two windows (M3, gate G5)

1. `apkrun dev launch <apk1> <apk2>` opens two sessions and two windows in the embedded runtime.
2. Input routing follows the key window (`focusChanged`, [input.md](input.md)).
3. Acceptance: HelloText and HelloCompose run at the same time in two windows. Typing and clicking go to the focused window's app only. Closing one window leaves the other running.

### #067 Retina, density, resize (M3)

1. `DisplayGeometryResolver` (§6.1) with T0 tests (Retina, non-Retina, 4095 cap, zoom clamp, minimum size). Density application (§4) and EDID physical size ([graphics.md](graphics.md) §6.4).
2. Live resize, `reconfigure`, `surfacesReplaced`, and coalescing (§7.1). The backing-scale change (§7.2), fullscreen (§7.4), and zoom commands.
3. Run the display-ID stability test (§7.1 open point). Implement fallback A or B if needed and record the result.
4. Acceptance: on a Retina Mac a 480 × 850 pt window shows a 960 × 1700 px display at 320 dpi. Text is sharp (no scaling at `zoom = 1`). Resizing re-lays out HelloCompose without restarting the app process (if the app handles configuration changes). Moving the window to a non-Retina screen switches to 160 dpi and 480 × 850 px.

### #068 Session client and IOSurface window over XPC (M4)

1. The session channel messages in §5.1 in RuntimeAPI and RuntimeClient; `XPCFrameSource` in APKRunLauncher.
2. The buffer state machine (§5.2) in GraphicsCore with the rules and timeouts. `requestPresent` for visibility.
3. APKRunLauncher uses WindowingCore with `XPCFrameSource`. Embedded mode keeps `SurfacePoolFrameSource`.
4. Remove the headless launch hook of #032 ([runtime-daemon.md](runtime-daemon.md) §13 #032), and run the #032 acceptance check again with the launcher window.
5. Acceptance: §5.5, and the full G6 check ([../04-plan/roadmap.md](../04-plan/roadmap.md) §2): quitting APKRun.app while HelloText's launcher window is open leaves HelloText interactive for 5 minutes.

---

## 13. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | `DisplayGeometryResolver` table tests | #067 |
| T0 | `DisplayPool` state machine with fakes; invariant 2 property test; serialized attach; fault retry | #028 |
| T0 | Buffer state machine and wrapper presentation algorithm (stale generation, reordering, coalescing) | #068 |
| T1 | `IOSurfaceLayerView` with a synthetic `FrameSource` in a real window (screenshot comparison, UI test host) | #026, #068 |
| T2 | Pool cycles on Android (§12 #028), secondary-display launch (#029), two sessions (#030), resize and backing-scale change (#067) | #028–#030, #067 |
| T3 | G4 (HelloText window) and G5 (two apps, independent input) | #026, #030 |

---

## 14. Open items

| Item | Plan |
|---|---|
| Does a config-space update raise a display event in Linux and Android (R-01)? | #019 tests it on the test Linux guest and #028 on Android. Fallbacks A, B, and C are in [graphics.md](graphics.md) §4.3. Fallback C (a fixed display count per boot) is also recorded under R-04. The result goes to §11 |
| Does `Display.getDeviceProductInfo()` expose the EDID product code on pool displays (§3.3 step 4)? | #028 checks it. Fallback: the pool takes "the only display added while this slot is attaching" and logs the fallback once per boot. Attaches are serialized, so this match stays unambiguous |
| Does a mode change keep the Android display ID (§7.1, R-04)? | #067 tests it on display 0, and #028 repeats it on pool displays. Fallback A: re-home the task with `moveRootTaskToDisplay`. Fallback B: fixed-size windows (`window.resizable` false). The result goes to §11 and R-04 |
| Density on pool displays (§4, OQ-39) | #067 checks the forced density and the EDID physical size on display 0. #028 checks that the forced density replaces the fallback 213 on pool displays without side effects. Working default: set the density with `setDisplayPolicy` only, and record it in [graphics.md](graphics.md) §6.4 |
| IME policy `LOCAL` on pool displays (§4, R-05) | #071 checks it with the APKRun IME. Fallbacks: the `FALLBACK_DISPLAY` IME policy, and `primaryDisplayCompatibility` for affected apps |
| Apps on secondary displays (§8, R-04) | #029 runs the fixture apps and the popular app sample. The results go to §11 and to the compatibility database seed (#090). Apps that fail use `primaryDisplayCompatibility` |
| Status bar on display 0 in compatibility mode (§8, OQ-35) | Decision in #079. Working default: the status bar stays visible in v1 |
| Does `IOSurfaceIsInUse` reflect WindowServer use of layer contents (§5.2)? | #068 checks it with the T2 test of §5.5. The result goes to §11 |
| Automatic width and height swap for orientation requests (§7.7) | Decided in #067. Until then, Android letterboxes fixed-orientation apps, and the wrapper does not rotate the window |
| `DISPLAY_ATTACHED` within its budget (§9) | #070 measures it. If it is above budget, add a warm spare display (a slot state `spare` between `free` and `allocated`) |
| Memory of many pool displays (§2, R-08) | `display.maxSessions` (default 8) bounds the pool. #028 and #070 measure the footprint. Fallback: lower defaults and smaller pools |
