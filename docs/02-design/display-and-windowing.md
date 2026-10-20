# Display and Windowing (DisplayPool and WindowingCore)

DisplayPool leases Android displays to app sessions, and WindowingCore shows each session in one Mac window. This document covers the display model, DisplayPool, the Android display settings, the frame protocol between apkrund and the wrapper, geometry and density, windows, window modes, and the launch latency budget.

---

## 1. Responsibilities

| Component | Process | Owns |
|---|---|---|
| `GraphicsCore` `ScanoutController` | apkrund | Scanout modes, display events, `SurfacePool`s, blits ([graphics.md](graphics.md) §6) |
| `RuntimeCore` `DisplayPool` | apkrund | Scanout ↔ session ↔ Android display ID; attach and release; geometry; reuse without stale content |
| `RuntimeCore` `SessionRegistry` | apkrund | `AppSessionState` ([state-machines.md](../01-architecture/state-machines.md) §3); forwards frames and geometry to `DisplayPool` |
| Guest Agent (`apkrun_guestd`) | guest | Display add, change, and remove events; density and IME policy; launch on a display; tasks per display ([guest-components.md](guest-components.md)) |
| `RuntimeClient` session object | wrapper | Frame events and input, as RuntimeAPI wire types. The launcher adapts them to WindowingCore's `FrameSource` and `InputSink` ([modules.md](../01-architecture/modules.md) §2) |
| `WindowingCore` | wrapper, and the CLI in embedded development mode | `NSWindow`, the IOSurface layer, geometry and backing scale, live resize, fullscreen, placeholder and error UI, restoration, close policy |
| `InputCore` | wrapper | `NSEvent` → `InputEvent` in display pixels, using §6.1 ([input.md](input.md)) |

Invariants:

1. One live session per package, one display per session, one window per session ([state-machines.md](../01-architecture/state-machines.md) §3, FR-DSP-01).
2. A scanout is presented only to the session that holds its lease. A released scanout's frames never reach another session.
3. Pixels reach the window only through the IOSurface pool, with no copies and no readbacks (FR-GFX-05, FR-DSP-07).
4. The wrapper never talks to the guest, and apkrund never creates windows ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)).

```text
wrapper (SessionWindowController) ◀── frames, input (XPC) ──▶ apkrund: SessionRegistry ─▶ DisplayPool
                                                                                          │ lease: scanout N, Android display ID, pool generation
guest (Guest Agent) ◀── display policy, launch (vsock) ──▶ apkrund: ScanoutController ─▶ SurfacePool[N] ◀── blit ◀── VirGL
                                                          SurfaceFlinger ──▶ scanout N (Android display ID)
```

---

## 2. Display model

- **Scanouts 1…15** form the pool. Each app session in `secondaryDisplay` mode gets one ([ADR-0005](../01-architecture/decisions/0005-multi-display-window-model.md)).
- **Scanout 0** is Android's primary display (`Display.DEFAULT_DISPLAY`). It runs the launcher and system UI. It is never shown in `secondaryDisplay` mode, because no pool is attached and there are no host blits ([graphics.md](graphics.md) §6.1). It is shown only in `primaryDisplayCompatibility` mode (§8).
- Pool displays are physical displays to Android: DRM connectors reported by the ranchu HWC with `display_finder_mode=drm`. They are not `VirtualDisplay`s, whose frames would need encoding or readback to reach the host (ADR-0005). Android treats them as external displays: public, `FLAG_PRESENTATION`, and without system decorations unless configured.
- Capacity: 15 hardware slots. The soft limit `display.maxSessions` (default 8, range 1–15, [configuration.md](../03-reference/configuration.md)) bounds graphics memory (R-08). Exhaustion returns `RuntimeFailure.displayPoolExhausted`. System uses (`SessionID.system`, §3.1) count only toward the 15 slots and hold a display for at most 90 s.

---

## 3. DisplayPool

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

public struct ResolvedDisplayMode: Sendable, Equatable {    // output of DisplayGeometryResolver (§6.1)
    public var pixelSize: PixelSize
    public var densityDpi: Int
    public var renderScale: Double            // ≤ backingScale
    public var zoom: Double                   // effective, within the stored preference range
    public var refreshHz: Int                 // 60
}

public struct DisplayPoolLimits: Sendable, Equatable {
    public var attachTimeout: Duration         // default 5 s
    public var clearTimeout: Duration          // default 5 s
    public var removalTimeout: Duration        // default 3 s
    public var reconfigureTimeout: Duration    // default 3 s
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
    public func release(_ lease: DisplayLease) async -> DisplayReleaseResult // never throws; faults are recorded
    public func snapshot() -> [DisplaySlotSnapshot]                   // diagnostics, `apkrun info --displays`
    public nonisolated var events: AsyncStream<DisplayPoolEvent> { get }   // slot state changes, faults
}

public protocol DisplayControlChannel: Sendable {                     // implemented over GuestProtocol (guest-protocol.md)
    var displayEvents: AsyncStream<GuestDisplayEvent> { get }          // added / changed / removed, tasks on display
    func setDisplayPolicy(_ displayID: Int32, density: Int, imePolicy: ImeDisplayPolicy) async throws(RuntimeFailure)
    func clearDisplay(_ displayID: Int32) async throws(RuntimeFailure) // remove or move away every task on it
}
```

`DisplayPool` is the only caller of `ScanoutController.configure`, `disable`, `attach`, and `detachPool` in the product.

### 3.2 Slot states

The states are defined in [state-machines.md](../01-architecture/state-machines.md) §4.

| State | Meaning |
|---|---|
| `free` | Scanout disabled. Android has no display for it |
| `attaching` | Reserved for a session. Scanout enabled. Waiting for `DisplayAdded` |
| `allocated(SessionID)` | Bound to an Android display ID and a session's window |
| `releasing` | Tasks being cleared, scanout being disabled |
| `faulted(DisplayFault)` | Attach, release, or resize rollback failed: `.attachTimedOut`, `.releaseTimedOut`, `.graphics(GraphicsFailure)`, `.reconfigurationUncertain`. Uncertain resize state stays quarantined until Android restarts |

Each slot also keeps `reservedBy: SessionID?`, `androidDisplayID: Int32?`, `mode`, `generation` (incremented on every acquire), and timestamps.

### 3.3 Acquire

Attaches are **serialized**: one slot is `attaching` at a time. This keeps the scanout ↔ Android display correlation unambiguous ([graphics.md](graphics.md) §4.3). Concurrent `acquire` calls queue in FIFO order.

1. Pick the lowest-numbered `free` slot. If none is free, or the soft limit is reached, throw `.displayPoolExhausted`.
2. Resolve the mode from the geometry (§6.1). Mark the slot `attaching` and record `reservedBy`.
3. `ScanoutController.configure(scanout, mode)`. GraphicsCore writes the EDID and raises the display event.
4. Wait for `GuestDisplayEvent.added(displayID, info)` where `info.productInfo` matches the scanout: EDID manufacturer `APK`, product code = scanout index. Apps read it through `Display.getDeviceProductInfo()` (API 31). The timeout is 5 s ([state-machines.md](../01-architecture/state-machines.md) §4). Without product info, the pool accepts only one display added during this attach window, and logs that fallback once per boot. Several product-less displays are ambiguous and fail the attach.
5. If `info.mode` differs from the requested pixel size, log it and use Android's actual size.
6. `setDisplayPolicy(displayID, density:, imePolicy: .local)` (§4).
7. Allocate a new `SurfacePool` at the pixel size, never reused across sessions. Then `ScanoutController.attach(pool, to: scanout)`.
8. Mark the slot `allocated(session)` and return the lease. The wrapper receives the pool's surfaces in the `SessionDescriptor`.

Failure handling:

- A timeout in step 4 marks the slot `faulted(.attachTimedOut)`. The pool disables the scanout, retries the acquire **once** on the next free slot, and then fails with `RuntimeFailure.displayAttachFailed`. A faulted slot is reset in the background: disable, wait for `removed` or 3 s, then `free`. After three faults in a boot, the slot stays `faulted` until Android restarts.
- If the Guest Agent disconnects during an acquire, the operation fails with `.guestAgentUnavailable`, and the slot is released.
- If a release times out waiting for `DisplayRemoved`, the slot keeps its display ID. It may be freed only after that ID is confirmed removed. If the event stays missing, the slot is quarantined until Android restarts.

An uncertain resize keeps its session and lease counted against the session limit until the owner releases them. Across Guest Agent reconnects, the supervisor compares Android's monotonic uptime in consecutive snapshots. A decrease means Android restarted, and `RuntimeSupervisor` then resets boot-local fault quarantines once the agent has resynchronized.

### 3.4 Release

1. Mark the slot `releasing`. `ScanoutController.detachPool(from:)` runs **first**, so no frame of this scanout reaches the wrapper afterward (invariant 2).
2. `clearDisplay(displayID)`. The Guest Agent finishes or moves every task by the close policy (§7.6), then reports `tasksCleared`. If this times out (5 s), the scanout is disabled anyway. Android moves the remaining tasks to the default display.
3. `ScanoutController.disable(scanout)`. Android removes the display.
4. Wait for `GuestDisplayEvent.removed(displayID)` (3 s). On confirmation the slot becomes `free` and release returns `.released`. On timeout the slot stays quarantined with its display ID, and release returns `.quarantined(displayID)`. The old pool is released when the wrapper's session connection closes, or 1 s after detach at the latest.

### 3.5 Reuse without stale content

- Each lease gets a fresh `SurfacePool`. The wrapper never sees surfaces from an earlier session.
- The pool attaches only after `DisplayAdded`. `AppSessionState` moves `launching → running` on the first frame after `LaunchApplication` ([state-machines.md](../01-architecture/state-machines.md) §3). Until then the wrapper shows the placeholder (§7.3).
- SurfaceFlinger allocates a re-enabled display's framebuffer after `DisplayAdded`, so no guest content survives.
- T0 tests model the pool with fake channels and scanouts, and assert invariant 2 across random acquire, release, and fault sequences.

### 3.6 Display 0

Scanout 0 is always enabled, and `DisplayPool` never leases it in `secondaryDisplay` mode. In `primaryDisplayCompatibility` mode it reserves display 0 for one session at a time (§8). A runtime change of the primary mode uses the resize and rollback sequence of §7.1.

In the embedded development path, the primary presenter is attached before boot. `dev launch --display 0` resolves the geometry before boot. `DisplayPool` verifies Android's mode, applies the compatibility density, and grants an exclusive lease over the existing presenter. Releasing restores the previous density and leaves scanout 0 enabled. A secondary-display lease owns a fresh pool, and its window relays that pool's frames and acknowledgements.

---

## 4. Android-side display configuration

The Guest Agent applies these settings. Their messages are in [guest-protocol.md](guest-protocol.md), and their privileges are in [guest-components.md](guest-components.md).

| Setting | How | When | Why |
|---|---|---|---|
| Per-display density | `IWindowManager.setForcedDisplayDensityForUser(displayID, dpi, USER_CURRENT)`, the call behind `wm density <dpi> -d <id>` | After `DisplayAdded`, and on reconfigure | SurfaceFlinger gives external displays a fallback density of 213 (`ACONFIGURATION_DENSITY_TV`). The design uses `densityDpi` (§6.1) |
| IME placement | `IWindowManager.setDisplayImePolicy(displayID, DISPLAY_IME_POLICY_LOCAL)` | After `DisplayAdded` | Editors on the app's display get the APKRun IME, not the one on hidden display 0 ([input.md](input.md) §5.6) |
| No system decorations | Defaults. The custom image keeps `force_desktop_mode_on_external_displays=0` | Image default | No launcher, status bar, or navigation bar in app windows |
| Stay awake, no keyguard | `svc power stayon true`, `locksettings set-disabled true`, maximum screen-off timeout. The custom image sets them as defaults | Guest Agent start | External displays follow the default display's power state, and a keyguard would cover app displays |
| Launch on a display | `ActivityOptions.makeBasic().setLaunchDisplayId(id)` and `setLaunchWindowingMode(WINDOWING_MODE_FULLSCREEN)`, with `FLAG_ACTIVITY_NEW_TASK` | `LaunchApplication` | A fullscreen task on the session's display. The shell uid and the privileged agent (`INTERNAL_SYSTEM_WINDOW`) may launch there |
| Task tracking | `ITaskStackListener` and `TaskInfo.displayId` | Always | Reports `taskAppeared`, `taskVanished`, and `displayEmpty` per display (§7.6) |

Activities that the app starts, such as permission dialogs, the DocumentsUI picker, and share targets, launch on the caller's display and appear inside the app's window. URL intents can go to the Mac instead ([desktop-integration.md](desktop-integration.md)).

---

## 5. Frame delivery and buffer release

This section defines the protocol between GraphicsCore's `SurfacePool` ([graphics.md](graphics.md) §6.3) and the wrapper's layer.

### 5.1 Messages (session channel)

The complete list is in [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3. The frame messages are:

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

apkrund owns the state of each buffer. The wrapper influences it only through `frameDisplayed`.

```text
          acquireForRender            blit GPU-complete            wrapper frameDisplayed(seq)
  free ───────────────────▶ rendering ─────────────────▶ offered(seq) ───────────────────────▶ displayed(seq)
   ▲                                                         │                                    │
   │         superseded: frameDisplayed(seq' > seq) received │                                    │ frameDisplayed(seq' > seq)
   └───────────────── (and IOSurfaceIsInUse == false) ◀──────┴────────────────────────────────────┘
```

Rules:

1. **Offered buffers are never overwritten.** After `frameReady(i, seq)` is sent, buffer *i* may be on screen at any moment. It is not reused until a newer frame is displayed.
2. A buffer becomes `free` when both hold: (a) the wrapper reported `frameDisplayed` for a newer sequence, and (b) `IOSurfaceIsInUse(surface) == false`. WindowServer holds the use count while it composites. Condition (b) is checked at acquire time. A buffer still in use is skipped for this frame.
3. With three buffers, the steady state is one `displayed`, at most one `offered`, and one `rendering`. If a flush arrives with no free buffer, GraphicsCore keeps only the **latest** pending present and performs it when a buffer frees. The skipped frame counts as `droppedFrames` ([graphics.md](graphics.md) §6.2).
4. **Back-pressure.** If no `frameDisplayed` arrives for 1 s while frames are offered, the session is treated as not visible, and presents stop until the wrapper displays a frame or becomes visible. This protects apkrund from a hung wrapper.
5. **Visibility.** On `visibilityChanged(false)` (minimized, fully occluded, on another Space, or hidden), GraphicsCore stops blitting that scanout, and the session enters `backgrounded`. Guest flushes still complete. On `visibilityChanged(true)`, `ScanoutController.requestPresent(scanout)` ([graphics.md](graphics.md) §6.1) re-blits the bound resource at once.
6. **Generations.** After `surfacesReplaced(generation g+1)`, messages with generation g are ignored on both sides. The old pool is released after the first `frameDisplayed` of g+1, or after 1 s.

### 5.3 Wrapper presentation algorithm

`IOSurfaceLayerView` (WindowingCore) runs this on the main thread:

```text
on frameReady(gen, i, seq, t):
    if gen != currentGeneration or seq <= lastShownSeq: return          // stale or reordered
    CATransaction.begin(); CATransaction.setDisableActions(true)
    contentLayer.contents = surfaces[i]                                 // IOSurface as layer contents: zero-copy
    CATransaction.setCompletionBlock { session.frameDisplayed(gen, seq) }
    CATransaction.commit()
    lastShownSeq = seq
```

- The content layer is a plain `CALayer` whose `contents` is the `IOSurface`. There is no `CAMetalLayer` and no second blit. A buffer is never offered twice in a row, so Core Animation always sees the change.
- `contentsGravity` is `.resize` in steady state, when the pool size equals the view's backing size. It is `.resizeAspect` during live resize (§7.1). `contentsScale` is `renderScale` (§6.1).
- Frame events reach the main queue through `DispatchQueue.main.async`. If the main thread is busy, only the newest pending `frameReady` is applied.
- `frameDisplayed` is sent from the transaction completion block, which runs after Core Animation commits the contents. With rule 2(b), reuse is safe without knowing WindowServer's timing.
- The embedded development path feeds the same view through `SurfacePoolFrameSource` in `CLI/apkrun/Dev/`. The presenter attaches to the boot's drmVirgl device before the guest starts (`DevelopmentDisplay` in RuntimeCore, `DeveloperDisplay` in RuntimeHost). The CLI never imports GraphicsCore, and neither does WindowingCore. The adapter reports `frameDisplayed` in process instead of over XPC ([runtime-api.md](../03-reference/runtime-api.md) §15).
- The AppKit loop runs on the main thread, started from the entry point before its first suspension. A loop run inside a main-actor job or a main-queue block stops the runtime's queue.

**Development window (#24), fixed-size:** display 0 keeps the image's default mode, and the window scales the layer with aspect fit when it is resized ([graphics.md](graphics.md) §6).

The embedded development path now resolves a 480 × 850 pt initial mode before boot (§6.3). It stays fixed-size until live resize is built (§7.1).

### 5.4 Color and format

- Pool surfaces are `BGRA8` with `kIOSurfaceColorSpace` set to sRGB. WindowServer color-matches the layer on P3 and XDR displays. Android renders sRGB. Wide color and HDR are post-v1.
- The layer is opaque (`isOpaque = true`). The blit forces alpha to 1 ([graphics.md](graphics.md) §6.2).

### 5.5 Verification

- T0: the buffer state machine with a scripted wrapper that displays some frames, delays others, stops acknowledging, and flips visibility. It asserts rules 1–6, and that no offered buffer is rendered into.
- T2: HelloGL in a wrapper window for 60 s at 60 fps. Acceptance: no tearing, checked with the alternating-colour census (`FrameColourCensus`); `readyToDisplayed` p95 < 1 refresh interval + 4 ms; present cost p95 < 2 ms ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)); `hostReadbacks = 0`.

---

## 6. Geometry, density, and scale

### 6.1 From window to Android display

`DisplayGeometryResolver` (RuntimeCore) is a pure function that maps a `DisplayGeometry` to a `ResolvedDisplayMode`:

```text
renderScale = min(backingScale, 4095 / pointWidth, 4095 / pointHeight)        // also lowered until the 60 Hz EDID timing is expressible
pixelSize   = (round(pointWidth × renderScale), round(pointHeight × renderScale)) rounded down to even numbers
preferenceZoom = clamp(requestedZoom, 0.75...2.0)
effectiveZoom  = preferenceZoom adjusted only as needed for 120...640 dpi
densityDpi  = round(160 × renderScale × effectiveZoom)
refreshHz   = 60
```

Consequences:

- At `zoom = 1.0`, **one Android dp is one macOS point**. A 480 × 850 pt window on a Retina Mac is a 960 × 1700 px display at 320 dpi (`xhdpi`), and the app sees a 480 × 850 dp screen.
- `zoom > 1` enlarges the Android UI, and `zoom < 1` shows more content. View menu: Zoom In (⌘=), Zoom Out (⌘−), Actual Size (⌘0). The requested value is stored per package as `window.zoom` in `settings.json` ([package-metadata-json.md](../03-reference/package-metadata-json.md)). The resolved value is returned with the mode. The `resize` that carries the new zoom writes it, and apkrund posts `packages.settingsChanged` ([runtime-api.md](../03-reference/runtime-api.md) §14.3).
- Above 4095 px (for example a fullscreen window on a 5K or 6K display), `renderScale` drops below `backingScale`. Android renders fewer pixels, the layer upscales them (`contentsScale = renderScale`), and the dp size stays the same. Larger modes are post-v1 ([graphics.md](graphics.md) §6.4).
- The CVT reduced-blanking timing must fit the EDID pixel-clock and horizontal-frequency fields. The resolver may lower `renderScale` further to keep 60 Hz expressible.
- The EDID physical size derives from `densityDpi`, so the DPI Android reports matches the forced density.
- If zoom and capped render scale would give a density outside 120–640 dpi, the resolver adjusts the effective zoom within 0.75–2.0, and returns a typed failure when that is not enough. It never silently changes the requested geometry.

### 6.2 Limits

| Item | Value | Reason |
|---|---|---|
| Minimum content size | 320 × 400 dp (points = dp × effective zoom). Smaller windows are rejected | Android phone UI assumptions (smallest width ≥ 320 dp) |
| Maximum content size | The screen's visible frame, with the pixel size capped by §6.1 | EDID limit |
| Density range | 120–640 dpi | Zoom is adjusted within 0.75–2.0 (§6.1). Impossible geometry fails |
| Default window size | `window.defaultWidth` and `window.defaultHeight` from package settings, initially copied from `wrapper.json` ([wrapper.md](wrapper.md) §3). Points; 480 × 850 portrait by default, 850 × 480 if the launcher activity requests landscape. Clamped to 90 % of the visible frame | Initial preference of the generated app |

### 6.3 Display 0 geometry

Product display 0 boots with the image's default mode and `androidboot.lcd_density` = 160 × the main screen's backing scale at boot ([android-image.md](android-image.md) §6.2).

The embedded development window resolves the initial 480 × 850 pt geometry, clamped to 90 % of the main screen's visible frame. It uses that density in `androidboot.lcd_density` and configures scanout 0 before the guest starts. After the Guest Agent handshake, `SetDisplayPolicy` applies the resolved density to Android display 0 before the runtime becomes ready. At zoom 1 this is 160 × backing scale. In `primaryDisplayCompatibility` mode, display 0 is reconfigured to the window geometry through the path used for pool displays (§7.1), including forced density.

---

## 7. Windows (WindowingCore)

### 7.1 Resize

Windows are resizable when `window.resizable` is true. The default is true, or false when fallback B below is chosen.

```text
wrapper                                  apkrund                                    guest
windowWillStartLiveResize: gravity=.resizeAspect (last frame scaled, letterboxed black)
... user drags ...
windowDidResize (+150 ms quiet)
resize(DisplayGeometry) ─────────────▶ embedded RuntimeCore (display 0)
                                        advertise mode + new EDID; raise display event
                                                              ──────────────────────────────▶ HWC / SurfaceFlinger
                                        ◀─────────── display 0 reports new size (≤ 3 s)
                                        setDisplayPolicy(display 0, density) ───────────────▶ app gets config change
                                        create pool g+1; drain old present fence; swap scanout
◀────────────── surfacesReplaced(SurfaceSet g+1)
first frame of g+1 commits to Core Animation; then switch geometry and input mapper
```

- The embedded path advertises the new mode and waits up to 3 s for Android display 0 to report that size. Then it applies the density policy and publishes a replacement pool. If confirmation or the policy fails, it restores the prior mode and density where possible, and keeps the old pool.
- For pool displays, a resize event is confirmed against the latest Guest Agent snapshot before the presenter pool is replaced. A queued event for a mode Android has already left cannot confirm the resize.
- During a resize request, input is disabled. The old IOSurface stays letterboxed at its aspect ratio until the first frame of the new generation commits. At that commit, the view updates the layer geometry and `CoordinateMapper` together, then resumes input ([input.md](input.md) §3).
- The old presenter is quiesced before its replacement accepts guest flushes. It drains queued renderer work and waits up to 3 s for its fence. A timeout aborts the swap, so there is one in-flight blit per scanout.
- Old surface sets stay until the first new-generation frame commits, with a 1 s cleanup deadline if none arrives. The embedded CLI reconciles the current pool after each successful resize, and it can recover a pool from a later frame event.
- A resize makes Android deliver `screenSize`, `smallestScreenSize`, and `orientation` changes, and with zoom also `density`. Apps that do not handle them are recreated.
- Resize requests coalesce. While a reconfigure is in flight, only the latest geometry is kept and applied next.

**Open point (R-04):** does a mode change keep the same Android display ID? The ranchu HWC may report a mode change as disconnect plus connect. SurfaceFlinger derives the physical ID from the EDID, so it should stay stable, but DisplayManager could allocate a new logical display. Fallbacks, in order:

- **A.** Re-home the task. Acquire a new slot at the new size, move the task with `IActivityTaskManager.moveRootTaskToDisplay(taskId, newDisplayID)`, and release the old slot. The app keeps running with a configuration change, and the window gets new surfaces as in a resize.
- **B.** Fixed-size windows. `window.resizable` defaults to false. Only zoom and backing-scale changes remain, applied at the next session start.

The chosen fallback is recorded in R-04.

### 7.2 Backing scale and screen changes

- `NSWindow.didChangeBackingPropertiesNotification` triggers a `resize` with the new `backingScale`, handled as in §7.1. Moving between screens with the same scale needs no action.
- v1 uses 60 Hz modes only. 120 Hz needs a HWC mode with a matching vsync period, and is post-v1.

### 7.3 Window contents and placeholder

`SessionWindowController` (WindowingCore) shows one of these, driven by the session event `stateChanged` ([runtime-api.md](../03-reference/runtime-api.md) §6.3):

| Session state | Window shows |
|---|---|
| `starting`, `booting(progress)` (the `SessionPhase`s `requested`, `acquiringDisplay`, `waitingForRuntime`, [runtime-api.md](../03-reference/runtime-api.md) §6.2) | App icon, app name, "Starting Android…", and the boot phase text from `RuntimeState` |
| `waitingForPackage` (a store transaction runs, [runtime-daemon.md](runtime-daemon.md) §7.1) | App icon and "Updating ‹App›…" |
| launching (no frame yet) | App icon with an indeterminate progress indicator |
| `running` | The IOSurface content layer only |
| `ended(.error(...))` | Error panel: message, remediation, "Try Again", "Open APKRun" ([error-catalog.md](../03-reference/error-catalog.md)) |
| `ended(.appCrashed)` | "‹App› stopped unexpectedly" and "Reopen" |

On the embedded path, `launching → running` follows the window's Core Animation transaction completion (`frameDisplayed`). The GPU `framesPresented` counter counts completed blits, which does not prove the window committed the frame.

`apkrun dev launch` updates its placeholder as Android boots, the APK installs, and the app starts. The window title is the package's Android label. On failure, the window stays open with the catalog message, remediation, and a **Close** button, and the CLI prints the full error. Rerunning the command retries. The development command offers neither **Try Again** nor **Open APKRun**. A failure before the Android display attaches shows the same message in a failure-only window.

A failed window keeps input disabled and rejects new resize requests, including callbacks already in flight. The pre-parser decides from the `dev boot` or `dev launch` command path, so option values such as `--guest-dir launch` do not select app-launch close handling.

The window is a standard titled window: title = app display name, black background, `collectionBehavior = [.fullScreenPrimary]`, and `tabbingMode = .disallowed` (one window per app). There is no emulator frame, toolbar, or navigation button. Android navigation uses keyboard mappings (Esc → Back, [input.md](input.md) §6).

### 7.4 Fullscreen

Entering fullscreen is a resize to the screen size (§7.1), subject to the 4095 px cap (§6.1). The standard fullscreen behavior applies.

### 7.5 Focus, visibility, and restoration

- Key window changes send `focusChanged(Bool)`. The Guest Agent moves Android focus to the session's display ([input.md](input.md) §7.2).
- `NSWindow.occlusionState`, minimize, and `NSApplication` hide and unhide send `visibilityChanged` (§5.2 rule 5).
- Restoration uses `setFrameAutosaveName("APKRunSessionWindow")` in the wrapper's own defaults domain, so each app remembers its own frame. A saved frame wins over `window.defaultWidth` and `window.defaultHeight`, which apply only when no frame is saved (first launch, or **Reset** of the window settings). A saved frame is clamped to the screen (§6.2).

### 7.6 Close policy

A wrapper has one window. **Closing the window ends the session and quits the wrapper.** ⌘W, ⌘Q, the red close button, and "Quit" in the Dock menu all do this.

`closeSession(policy)` uses `window.closeBehavior`:

| Policy | Default | Android effect |
|---|---|---|
| `stop` | yes | The Guest Agent removes the session's tasks (`IActivityTaskManager.removeTask`). Android may keep the process cached, which speeds up the next launch |
| `keepRunning` | no (per app; useful for music or messaging apps) | The Guest Agent moves the root task to display 0 behind the launcher (`moveRootTaskToDisplay(taskId, 0)`, then to back). Audio and notifications continue. The next launch moves the task to a new display |

Embedded development mode differs. `apkrun dev launch` owns the VM and its display-0 window in one process. Closing the window sends `StopApplication(FINISH_TASKS)`. The Guest Agent removes the package's tasks and publishes `TaskVanished` before it replies. The host waits for the task snapshot to clear, stops the runtime, and exits. If the active task exits on its own, the CLI closes the window and stops the runtime. Task removal is bounded to 4 s within a 5 s deadline. On failure or timeout the CLI prints a warning and still shuts down. `FORCE_STOP` is not used. Closing during boot stops it without installing or launching the APK. Closing during installation waits for PackageInstaller, skips `LaunchApplication`, and stops Android. Once launch begins, the Guest Agent stays available until package tasks finish. Ctrl-C stops the runtime without stopping the app. `--no-window` keeps its one-shot behavior.

The display is then released (§3.4). The session ends with `.userClosed` when the Guest Agent reports `tasksCleared`, or after 5 s ([state-machines.md](../01-architecture/state-machines.md) §3).

When the app leaves its display (Back from the root activity, or the task finishing), the Guest Agent reports `displayEmpty`. The session ends with `.appExited`, and the wrapper closes and quits.

### 7.7 Other window behavior

| Topic | v1 behavior |
|---|---|
| Cursor | macOS arrow. Android pointer icons are post-v1 |
| Windows per app | One. All tasks of the session share its display |
| Always on top | `window.alwaysOnTop` (default off, FR-UI-03) uses `NSWindow.Level.floating`. No effect in full screen. Changes apply at once (`windowPrefsChanged`, [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3; [host-ui.md](host-ui.md) §7.2) |
| Accessibility | Window title and role only. Android's accessibility tree is not bridged in v1 ([scope.md](../00-product/scope.md)) |
| Frame statistics | Developer mode only: View → Show Frame Statistics ([graphics.md](graphics.md) §7). While shown, the launcher sends `frameStatistics` once per second, and apkrund answers with `SessionGraphicsStatistics` ([runtime-api.md](../03-reference/runtime-api.md) §6.3) |
| Screenshots | macOS window screenshots work, because the layer holds real pixels |
| Orientation | Android owns orientation and letterboxing. The window never rotates, and the host does not swap width and height |

---

## 8. Window modes

| Mode | Display | Limit | Use |
|---|---|---|---|
| `secondaryDisplay` (default) | Own pool display (scanouts 1–15) | `display.maxSessions` | Every app unless it misbehaves |
| `primaryDisplayCompatibility` | Display 0 | One session at a time | Apps that assume the default display, such as those that use `getDefaultDisplay()` metrics or render blank on a secondary display |

- `window.mode` is a per-package setting. Its default comes from the compatibility database (#91) or from the user (Settings → App → Window mode). It changes at the next session start.
- A second compatibility session while display 0 is taken fails with `RuntimeFailure.primaryDisplayBusy` and the remediation "Close ‹other app› or switch one of them to the standard window mode".
- While display 0 is leased, the launcher is behind the app. In the embedded path, the primary scanout stays enabled with its presenter in the development window. Ending the session restores the prior density before the VM stops.
- In compatibility mode, display 0 shows the status bar and navigation bar. The custom image hides the navigation bar (`config_showNavigationBar = false` overlay). The status bar stays visible in v1 (OQ-35).

---

## 9. Launch sequence and latency budget

Warm state (VM running, Android `ready`, app not running), HelloText. Target NFR-PERF-01: click → first frame p50 ≤ 1.5 s, from the click to `FIRST_FRAME_DISPLAYED` ([diagnostics.md](diagnostics.md) §9.3).

| Step | Perf marker ([diagnostics.md](diagnostics.md) §4) | Budget (p50) |
|---|---|---|
| Wrapper process start → `openSession` sent | `APP_LAUNCH_REQUEST` | 150 ms |
| `DisplayPool.acquire`: configure → `DisplayAdded` → policy → pool | `DISPLAY_ATTACHED` | 300 ms |
| `LaunchApplication` → activity resumed | `ACTIVITY_STARTED` | 800 ms |
| First guest flush → `frameReady` → shown | `FIRST_FRAME`, then `FIRST_FRAME_DISPLAYED` | 100 ms |
| Margin | | 150 ms |

If `DISPLAY_ATTACHED` exceeds its budget, the planned fallback is a **warm spare**: one enabled, empty, unleased display, as a slot state `spare` between `free` and `allocated` (§14).

---

## 10. Errors and logging

| Error (`RuntimeFailure`) | Cause | Remediation |
|---|---|---|
| `displayPoolExhausted` | No free slot, or the soft limit reached | Close another Android app window; raise `display.maxSessions` |
| `displayAttachFailed(scanout, reason)` | No `DisplayAdded` after retry | Restart Android (Settings → Troubleshooting); attach diagnostics |
| `displayReconfigureFailed(reason)` | Mode change not confirmed within 3 s | The window keeps the old size; try again |
| `primaryDisplayBusy(packageID)` | A second compatibility session | See §8 |
| `guestAgentUnavailable` | The agent disconnected during an operation | Automatic reconnect ([runtime-daemon.md](runtime-daemon.md)) |

Logging: `io.apkrun.runtime`, category `display` (slot transitions, correlation, timings), and `io.apkrun.wrapper`, category `window` (geometry, visibility, presentation stalls). Every slot transition is logged at info level with slot, lease, session, and Android display ID.

`apkrun info --displays` prints the pool snapshot: slot, state, session, package, Android display ID, pixel size, density, generation, and fps.

---

## 13. Tests

- **T0**, `Packages/RuntimeCore/Tests/RuntimeCoreTests/DisplayGeometryResolverTests.swift`: resolver table cases (Retina, non-Retina, 4095 cap, zoom clamp, minimum size).
- **T0**, `Packages/RuntimeCore/Tests/RuntimeCoreTests/DisplayPoolTests.swift`: the `DisplayPool` state machine with fakes; the invariant 2 property test; serialized attach; fault retry.
- **T0**, `Packages/GraphicsCore/Tests/GraphicsCoreTests/` (`PresentStateTests.swift`, `ScanoutPresenterTests.swift`): the buffer state machine (§5.2), with stale-generation, reordering, and coalescing cases.
- **T1**, `Packages/WindowingCore/Tests/WindowingCoreTests/IOSurfaceLayerViewTests.swift`: `IOSurfaceLayerView` with a synthetic `FrameSource` in a real window, compared by screenshot.
- **T2**, `Tests/IntegrationTests/`: pool acquire and release cycles on Android, with no stale frames, no duplicate display IDs, and every slot free at the end; secondary-display launch; two sessions; resize and backing-scale change.
- **T3**: gate G4 (HelloText renders in a native Mac window) and gate G5 (two apps in two windows, each with independent input) ([roadmap.md](../04-plan/roadmap.md) §2).

---

## 14. Open items

- Does a config-space update raise a display event on Android (R-01)? Fallbacks A, B, and C are in [graphics.md](graphics.md) §4.3.
- Does `Display.getDeviceProductInfo()` expose the EDID product code on pool displays (§3.3 step 4)? The fallback is the only display added while the slot attaches. Attaches are serialized, so the match stays unambiguous.
- Does a mode change keep the Android display ID (§7.1, R-04)? Fallback A re-homes the task. Fallback B uses fixed-size windows (`window.resizable` false). Until the test runs on the Android guest, `window.resizable = true` assumes display 0 keeps its ID.
- Does the forced density replace the fallback density 213 on pool displays without side effects (§4, OQ-39)? Working default: set the density with `setDisplayPolicy` only, and record it in [graphics.md](graphics.md) §6.4.
- IME policy `LOCAL` on pool displays works with the APKRun IME (§4, R-05). Fallbacks: the `FALLBACK_DISPLAY` IME policy, and `primaryDisplayCompatibility` for affected apps.
- Which fixture and popular apps run on secondary displays (§8, R-04). Apps that fail use `primaryDisplayCompatibility`.
- Status bar on display 0 in compatibility mode (§8, OQ-35). Working default: the status bar stays visible in v1.
- Does `IOSurfaceIsInUse` reflect WindowServer use of layer contents (§5.2)?
- `DISPLAY_ATTACHED` within its budget (§9). If not, add the warm spare (§9).
- Memory of many pool displays (§2, R-08). Fallback: lower defaults and smaller pools.
