# Graphics Design (VirtioDeviceCore + GraphicsCore)

| Field | Value |
|---|---|
| Status | Design baseline |
| Related | [display-and-windowing.md](display-and-windowing.md), [vm.md](vm.md), [android-image.md](android-image.md) §6.2, [../01-architecture/decisions/0002-virtualization-framework-macos27.md](../01-architecture/decisions/0002-virtualization-framework-macos27.md), [../01-architecture/decisions/0004-virgl-first-graphics.md](../01-architecture/decisions/0004-virgl-first-graphics.md), [../01-architecture/decisions/0005-multi-display-window-model.md](../01-architecture/decisions/0005-multi-display-window-model.md), [../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md) |
| Tasks | #018–#023, #063, #028 (scanout enable/disable), #067 (modes/EDID), #070 (frame statistics), #091 (fuzzing), #096 (Vulkan, post-v1) |

---

## 1. Responsibilities

| Component | Module | Owns | Must not |
|---|---|---|---|
| Custom virtio adapter | `VirtioDeviceCore` | Wrapping `VZCustomVirtioDevice*`: descriptors, feature negotiation, config space updates, queue draining, element completion, guest memory mapping, shared memory regions, a test entropy device (#063) | know about GPUs |
| virtio-gpu device model | `GraphicsCore` | virtio-gpu command decoding and validation, resources and backing, contexts, fences, scanouts, EDID, cursor queue | know about windows, sessions, or Android packages |
| Renderer | `GraphicsCore` + `GraphicsBridge` (C/Objective-C target) | The render thread, virglrenderer, EGL/ANGLE on Metal, the 2D renderer for non-VirGL profiles | be called from any thread other than the render thread |
| Presentation | `GraphicsCore` | `SurfacePool` (IOSurface triple buffers per scanout), the per-frame GPU blit, frame scheduling, frame statistics, readback counters | own `NSWindow`s (WindowingCore) or decide which scanout belongs to which app (RuntimeCore `DisplayPool`) |
| Renderer libraries | `ThirdParty/` → `Contents/Frameworks/VirGLRuntime/` | Pinned builds of virglrenderer, libepoxy, and ANGLE, plus patches (#020) | — |

Out of scope here:

- Mapping displays to sessions and windows, density, and resize policy: [display-and-windowing.md](display-and-windowing.md).
- Buffer handoff to the wrapper process and the `frameDisplayed` release protocol: [display-and-windowing.md](display-and-windowing.md) §5.
- Vulkan: §10 (post-v1, #096).

### 1.1 Frame path

```text
guest app (GLES) ─▶ Mesa virgl (Gallium) ─▶ virtio_gpu DRM driver
      │ controlq: CTX_CREATE, RESOURCE_CREATE_3D, SUBMIT_3D, TRANSFER_*, SET_SCANOUT, RESOURCE_FLUSH
      ▼
VZ custom virtio device (deviceQueue)                         VirtioDeviceCore
      │ decode + copy + validate (no guest memory re-reads)
      ▼
render thread ─▶ virglrenderer ─▶ ANGLE (GLES 3.0) ─▶ Metal    GraphicsCore + GraphicsBridge
      │ RESOURCE_FLUSH on a scanout with a consumer
      ▼
borrow scanout texture ─▶ 1 GPU blit ─▶ IOSurface[i] of SurfacePool(scanout)
      │ GPU completion
      ▼
ScanoutEvent.frameReady(scanout, i, seq) ─▶ RuntimeCore ─▶ XPC frameReady ─▶ wrapper layer.contents
```

The normal path has no CPU copy of pixel data and no GPU→CPU readback (FR-GFX-05, NFR-PERF-05). RiftVM measures the same path at about 60 fps with 0.4–0.8 ms per present. The only difference is that RiftVM blits into a `CAMetalLayer` drawable in the same process, while we blit into an IOSurface that another process presents ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)).

---

## 2. RiftVM as the reference implementation (#018)

RiftVM (MIT, `github.com/riftvm/riftvm`, v1.0.4) already implements a standard virtio-gpu device (device ID 16) on the macOS 27 custom virtio API. The guest side is the stock Linux `virtio_gpu` driver with Mesa VirGL, and the host side is virglrenderer → ANGLE → Metal. APKRun uses it as the starting point: we do not design GPU virtualization from scratch.

### 2.1 What RiftVM provides (research baseline)

| Area | RiftVM v1.0.4 |
|---|---|
| Device | deviceID 16, PCI class 0x03 (display) / subclass 0x80 (other), 2 queues (control, cursor) |
| Features | `VIRTIO_GPU_F_VIRGL`, `VIRTIO_GPU_F_EDID`. No `RESOURCE_BLOB`, no `CONTEXT_INIT`, no shared memory regions |
| Guest memory | backing pages reached through `guestMemoryMapping(atPhysicalAddress:length:)` |
| Renderer | virglrenderer 960bd667, libepoxy 1b6d7db, ANGLE 2d91f554 (Metal backend) |
| Threading | All VirGL/ANGLE work on one thread. At most one frame in flight plus one pending (`LatestFrameScheduler`) |
| Fences | Completed in order (no `CONTEXT_INIT`, so one global timeline) |
| Scanout | `virgl_renderer_borrow_texture_for_scanout` → texture → blit into the `CAMetalLayer` drawable's `MTLTexture`, wrapped with `eglCreateImage(…, EGL_METAL_TEXTURE_ANGLE, …)`. No IOSurface, no CPU copy |
| Patches | virglrenderer MSAA downgrade (ANGLE exposes GLES 3.0 limits) |
| Limits | 2 GiB total resource memory, 256 contexts, 8192 px maximum dimension, 256 MiB per buffer |
| Save/restore | Disabled for VirGL (renderer state cannot be serialized) |
| Input | Not virtio-input (impossible without a config-write callback). USB digitizer + vsock agent with uinput |
| Performance | ≈ 60 fps, 0.4–0.8 ms per present |
| Reusable files | `VirtioGPUDevice.swift`, `VirtioGPUProtocol.swift`, `CVirGLBridge.c`, `VirGLRenderer.swift`, `LatestFrameScheduler.swift` |

### 2.2 #018 deliverable

#018 asks for `docs/graphics/riftvm-analysis.md`. In this repository's docs tree it is **`docs/02-design/riftvm-analysis.md`** (the path change is recorded in [../04-plan/traceability.md](../04-plan/traceability.md)). It is written by reading the RiftVM source at a pinned commit (recorded in `ThirdParty/ThirdParty.lock.json` as `riftvm`) and must cover, for each step of the flow:

| Step | Questions the analysis answers |
|---|---|
| `VZCustomVirtioDevice` | configuration values, delegate methods used, which queue callbacks arrive on, DRIVER_OK handling, reset handling |
| virtqueue handling | draining loop, how descriptor chains are read and written, error paths, `returnToQueue` discipline |
| virtio-gpu commands | which commands are implemented, which return errors, how the control header and fences are handled |
| resource creation | 2D vs 3D paths, formats, limits enforcement |
| resource backing | how `ATTACH_BACKING` entries are mapped, mapping lifetime, invalidation on reset |
| VirGL | virglrenderer init flags and callbacks, context management, capsets, fence callback and polling |
| scanout | `SET_SCANOUT`/`RESOURCE_FLUSH` flow, texture borrowing, Y-flip and format handling |
| ANGLE | EGL display creation (Metal platform), context sharing, `EGL_METAL_TEXTURE_ANGLE` import, the Metal device used |
| Metal | presentation, synchronization with the GPU, frame pacing |
| cursor | cursor queue handling |

Plus: per file, its license header and whether we copy it (§2.3), adapt it, or rewrite it. The list of patches applied to the renderer libraries, and why. Known bugs and TODOs in the RiftVM code. Differences we must introduce (multi-scanout, IOSurface pools, hotplug, 2D profile, security validation).

Acceptance: the document identifies the exact source components required for APKRun.

### 2.3 Reuse rules

- Copied or adapted RiftVM files keep the MIT notice at the top plus the line `Derived from RiftVM <commit> (MIT)`. The notice is also included in `ThirdPartyNotices.html` ([../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md)).
- Code is adapted to our module boundaries: device-agnostic parts go to `VirtioDeviceCore`, and the virtio-gpu parts go to `GraphicsCore`. We do not keep RiftVM's app structure.
- RiftVM is not a build dependency. We never import its package; we own the copied code.

---

## 3. VirtioDeviceCore (#063, #019)

### 3.1 Platform API recap (macOS 27)

- `VZVirtualMachineConfiguration.customVirtioDevices: [VZCustomVirtioDeviceConfiguration]`.
- The configuration takes `deviceID` (UInt16), `PCIClassID`/`PCISubclassID` (UInt8), `virtioQueueCount`, `mandatoryFeatures`/`optionalFeatures` (`VZVirtioFeatureSet`, two 32-bit subsets; `VIRTIO_F_VERSION_1` is always set), `deviceSpecificConfiguration` (initial config bytes), `sharedMemoryRegions`, `provider`, and `supportsSaveRestore` (default `NO`; setting it without implementing the save/restore delegate methods raises an exception).
- The provider is `VZCustomVirtioDeviceDelegateProvider(deviceQueue:delegate:)`. The delegate receives `didCreateDevice`, and the device delegate receives `didReceiveNotificationForQueue`, `DidAcceptDriverOk`, `WillStop`, `WillPause`, `WillResume`, `WillReset`, and the save/restore methods. Everything runs on `deviceQueue`, in the process that owns the `VZVirtualMachine` (apkrund).
- `VZCustomVirtioDevice.queueAtIndex:` and `negotiatedFeatures` are valid only after DRIVER_OK. `guestMemoryMappingAtPhysicalAddress:length:` mappings become invalid after reset, reboot, or stop. `requestDeviceReset` sets DEVICE_NEEDS_RESET. `updateDeviceSpecificConfiguration:completionHandler:` replaces the config bytes with data of the **same size**.
- `VZVirtioQueue.nextElement` disables notifications until the queue is drained, so callers must loop until it returns `nil`. Element `readBuffers` are zero-copy views of guest memory. `returnToQueue` must be called exactly once. Apple warns about time-of-check/time-of-use (the guest can change memory after we read it).
- Not available: a "raise interrupt" call (completion and config updates are the only signals), and any callback for **guest writes to config space**. `maximumAllowedSharedMemoryRegionCount` is not documented.

### 3.2 API

```swift
public struct SharedMemoryRegionDescriptor: Sendable {
    public var regionID: UInt8
    public var sizeBytes: UInt64
}

public struct VirtioDeviceDescriptor: Sendable {
    public var name: String                         // logs, diagnostics ("virtio-gpu", "test-entropy")
    public var deviceID: UInt16                     // virtio device type (16 = GPU, 4 = entropy)
    public var pciClass: UInt8
    public var pciSubclass: UInt8
    public var queueCount: UInt16
    public var mandatoryFeatures: UInt64            // mapped to VZVirtioFeatureSet subset0/subset1
    public var optionalFeatures: UInt64
    public var configurationSpace: Data             // initial device-specific config; its size is fixed forever
    public var sharedMemoryRegions: [SharedMemoryRegionDescriptor]   // empty in v1
}

public protocol VirtioDeviceModel: AnyObject, Sendable {
    var descriptor: VirtioDeviceDescriptor { get }
    /// Called on the device queue. `context` stays valid until `deviceWillReset` / `deviceWillStop`.
    func deviceDidStart(context: VirtioDeviceContext, negotiatedFeatures: UInt64)
    func queueNotified(index: Int, context: VirtioDeviceContext)
    func deviceWillPause()
    func deviceWillResume()
    func deviceWillReset()                          // guest reset or reboot: drop all guest-derived state
    func deviceWillStop()                           // VM stopping: release host resources
}

public final class VirtioDeviceContext {            // confined to the device queue
    public func queue(_ index: Int) -> VirtioQueue
    public func mapGuestMemory(_ range: GuestPhysicalRange) throws(VirtioFailure) -> GuestMemory
    public func updateConfigurationSpace(_ bytes: Data) async throws(VirtioFailure)  // same size, else .configSizeMismatch
    public func requestReset(reason: String)
    public var negotiatedFeatures: UInt64 { get }
}

public protocol VirtioQueue {                       // VZ-backed and fake implementations
    /// Calls `body` for every available element until the queue is empty.
    func drain(_ body: (consuming VirtioElement) throws -> Void) rethrows
}

public struct VirtioElement: ~Copyable {
    public var readableByteCount: Int { get }
    public var writableByteCount: Int { get }
    public func copyReadable(maxBytes: Int) throws(VirtioFailure) -> [UInt8]   // one snapshot of guest data
    public mutating func write(_ bytes: UnsafeRawBufferPointer) throws(VirtioFailure)
    public consuming func complete()                                           // returnToQueue, exactly once
    public consuming func deferCompletion() -> PendingElement                  // completion later (fenced commands)
}
```

Design rules:

- **One device queue per device** (a serial `DispatchQueue` with `.userInteractive` QoS). VZ objects (`VZCustomVirtioDevice`, queues, elements) are touched only on it.
- **Copy, then validate.** Request bytes are copied out of guest memory exactly once (`copyReadable`) before any field is validated. Validated values are never re-read from guest memory. This is the TOCTOU rule from Apple's documentation.
- **Exactly-once completion.** `VirtioElement` is non-copyable. `complete()` and `deferCompletion()` consume it, and `PendingElement.complete()` consumes the pending handle. The type system prevents double returns (a double `returnToQueue` raises an exception in VZ). A `deinit` check in debug builds catches forgotten elements.
- **Guest memory mappings** are cached per device and dropped in `deviceWillReset`/`deviceWillStop`. A `GuestMemory` value checks bounds on every access, and every length is checked for overflow (`gpa + len` must not wrap).
- **Features** are expressed as a `UInt64` and split into `subset0` (bits 0–31) and `subset1` (bits 32–63) only in the VZ adapter.
- A `FakeVirtioQueue` and `FakeGuestMemory` live in the `VirtioDeviceCoreTestSupport` target so device models can be unit-tested (T0) without a VM.

### 3.3 Test entropy device (#063)

Following the WWDC26 sample, VirtioDeviceCore ships `EntropyTestDevice`: deviceID 4 (virtio-rng), PCI class 0x10, one queue, no features. It fills each writable buffer from a deterministic generator seeded by the test (so the guest can check the bytes). It is used only in T2 tests.

Acceptance (#063): the Linux test guest ([vm.md](vm.md) §12), with the built-in VZ entropy device disabled, lists `virtio_rng.0` in `/sys/class/misc/hw_random/rng_available`. It reads 64 KiB from `/dev/hwrng` that match the seeded sequence. After a device reset (driver unbind and bind), a second read works. The host log shows DRIVER_OK, notifications, and reset in order. What VZ does on a guest reboot (a device reset and a second boot, or `guestDidStop`) is not documented; #063 observes it and records the result here.

---

## 4. virtio-gpu device (#019, #021)

### 4.1 Identity and features

| Item | Value |
|---|---|
| Device ID | 16 |
| PCI class / subclass | 0x03 / 0x80 (as RiftVM; Linux binds on the virtio device ID, not the class) |
| Queues | 0 = controlq, 1 = cursorq |
| Offered features (profile `drmVirgl`) | `VIRTIO_GPU_F_VIRGL` (bit 0), `VIRTIO_GPU_F_EDID` (bit 1) |
| Offered features (profile `guestSwiftshader`, §9) | `VIRTIO_GPU_F_EDID` only |
| Not offered in v1 | `VIRTIO_GPU_F_RESOURCE_UUID` (2), `VIRTIO_GPU_F_RESOURCE_BLOB` (3), `VIRTIO_GPU_F_CONTEXT_INIT` (4); Vulkan track only (§10) |
| Config space (16 bytes, little-endian) | `events_read`, `events_clear`, `num_scanouts` = 16, `num_capsets` (2 with VirGL: `VIRGL`, `VIRGL2`; 0 otherwise) |
| Save/restore | `supportsSaveRestore = false` ([vm.md](vm.md) §9.5, R-07) |

`num_scanouts` is fixed at 16 (the virtio-gpu maximum) because the config size and contents cannot change in a way the guest would re-read at probe. Unused scanouts report `enabled = 0`, and Linux shows their connectors as disconnected.

### 4.2 Commands

Wire structures and constants come from Linux `include/uapi/linux/virtio_gpu.h` (the canonical source; section 5.7 of the virtio 1.2 spec describes them). `VirtioGPUProtocol.swift` defines them as fixed-layout Swift structs with explicit little-endian decoding. It never casts guest memory to struct pointers.

Every request starts with `virtio_gpu_ctrl_hdr` (24 bytes: `type`, `flags`, `fence_id`, `ctx_id`, `ring_idx`, padding). If `flags & VIRTIO_GPU_FLAG_FENCE`, the response must not be returned before the fence completes, and the response header echoes the flag and `fence_id`.

| Command | Code | v1 handling |
|---|---|---|
| `GET_DISPLAY_INFO` | 0x0100 | returns 16 `pmodes` (rect, enabled, flags) from `ScanoutTable`; **clears `events_read`** (§4.3) |
| `RESOURCE_CREATE_2D` | 0x0101 | VirGL profile: `virgl_renderer_resource_create` (2D target). 2D profile: host-memory resource (§9) |
| `RESOURCE_UNREF` | 0x0102 | detach from scanouts, release backing, unref in the renderer |
| `SET_SCANOUT` | 0x0103 | bind resource + rect to a scanout. `resource_id = 0` disables the scanout from the guest side |
| `RESOURCE_FLUSH` | 0x0104 | presents the flushed rect of every scanout bound to the resource (§6.2) |
| `TRANSFER_TO_HOST_2D` | 0x0105 | VirGL profile: `virgl_renderer_transfer_write_iov`. 2D profile: copy from backing (counted, §7) |
| `RESOURCE_ATTACH_BACKING` | 0x0106 | validate the entry list (≤ 16384 entries, each page range inside guest RAM), map, `virgl_renderer_resource_attach_iov` |
| `RESOURCE_DETACH_BACKING` | 0x0107 | detach iov, drop mappings |
| `GET_CAPSET_INFO` | 0x0108 | `virgl_renderer_get_cap_set` for `VIRGL` (1) and `VIRGL2` (2) |
| `GET_CAPSET` | 0x0109 | `virgl_renderer_fill_caps` |
| `GET_EDID` | 0x010a | generated EDID for the scanout (§6.4) |
| `RESOURCE_ASSIGN_UUID`, `RESOURCE_CREATE_BLOB`, `SET_SCANOUT_BLOB` | 0x010b–0x010d | `ERR_UNSPEC` (features not offered) |
| `CTX_CREATE` / `CTX_DESTROY` | 0x0200 / 0x0201 | `virgl_renderer_context_create` / `_destroy` (≤ 256 contexts) |
| `CTX_ATTACH_RESOURCE` / `CTX_DETACH_RESOURCE` | 0x0202 / 0x0203 | renderer calls |
| `RESOURCE_CREATE_3D` | 0x0204 | `virgl_renderer_resource_create` with the requested target, format, bind, and size (limits §5.4) |
| `TRANSFER_TO_HOST_3D` / `TRANSFER_FROM_HOST_3D` | 0x0205 / 0x0206 | renderer transfers. `FROM_HOST` is a guest-requested readback, counted separately (§7) |
| `SUBMIT_3D` | 0x0207 | command stream copied into a host buffer (≤ 4 MiB per submit), then `virgl_renderer_submit_cmd` |
| `RESOURCE_MAP_BLOB` / `RESOURCE_UNMAP_BLOB` | 0x0208 / 0x0209 | `ERR_UNSPEC` |
| `UPDATE_CURSOR` / `MOVE_CURSOR` (cursorq) | 0x0300 / 0x0301 | acknowledged and recorded for diagnostics only (§4.6) |

Responses: `OK_NODATA` (0x1100), `OK_DISPLAY_INFO` (0x1101), `OK_CAPSET_INFO` (0x1102), `OK_CAPSET` (0x1103), `OK_EDID` (0x1104). Errors: `ERR_UNSPEC` (0x1200), `ERR_OUT_OF_MEMORY` (0x1201), `ERR_INVALID_SCANOUT_ID` (0x1202), `ERR_INVALID_RESOURCE_ID` (0x1203), `ERR_INVALID_CONTEXT_ID` (0x1204), `ERR_INVALID_PARAMETER` (0x1205).

Guest errors never crash apkrund. A malformed request gets an error response and a rate-limited log line (`io.apkrun.graphics`, category `device`, at most 10 per second, with a counter for the rest). An element whose writable part is too small for a response header is completed with zero bytes written.

### 4.3 Display change events without a config-write callback

The Linux driver learns about display changes like this: the device sets `VIRTIO_GPU_EVENT_DISPLAY` in `events_read` and raises a config-change interrupt. The driver's config-changed work reads `events_read`, sends `GET_EDID` (if negotiated) and `GET_DISPLAY_INFO`, triggers a DRM hotplug event, and finally writes the handled bits to `events_clear`. The device is expected to clear `events_read` when it sees the `events_clear` write.

VZ provides no callback for config-space writes, so the device cannot see `events_clear`. The workaround ([ADR-0002](../01-architecture/decisions/0002-virtualization-framework-macos27.md)):

1. When RuntimeCore enables, disables, or changes the mode of a scanout (§6.1), `ScanoutTable` increments `displayGeneration` and GraphicsCore calls `updateConfigurationSpace` with `events_read = VIRTIO_GPU_EVENT_DISPLAY`.
2. When the device processes `GET_DISPLAY_INFO`, it answers with the current table and records `reportedGeneration = displayGeneration`. If no newer change is pending, it writes `events_read = 0` back with `updateConfigurationSpace`.
3. If a change arrives after the response was built (`displayGeneration > reportedGeneration`), `events_read` is set again, and the guest does another round.
4. The guest's later write to `events_clear` has no effect, which is harmless. `events_read` may already be 0 by then.

Open point, verified first in #019 and then with Android in #028: **does `updateDeviceSpecificConfiguration` raise a config-change interrupt in the guest?** (R-01). The spike boots the Linux test guest, flips a scanout from disabled to enabled, and checks for the `virtio_gpu` hotplug in `dmesg` and a new connector status in `/sys/class/drm/card0-*/status`. If no interrupt is raised, the fallbacks in order are:

- **A.** The Guest Agent forces a re-probe: it writes `detect` to the connector's DRM sysfs `status` attribute, after asking the host which scanouts changed. This needs a privileged domain (custom image, M5), plus a driver path that re-reads the display info. #028 must check the second part, because `virtio_gpu`'s connector detection reads cached info.
- **B.** All pool scanouts are enabled at boot with a small placeholder mode. The Guest Agent then hides unused ones from app placement. This costs guest memory and composition work.
- **C.** Fixed display count (display 0 plus N configured at boot), chosen per boot. This is a product regression and is recorded in R-04.

### 4.4 Resources and backing

`ResourceTable` (device-queue confined; the renderer owns the GPU side):

```swift
struct GPUResource {
    let id: UInt32
    let kind: Kind                    // .virgl(target, format, bind, w, h, depth, arraySize, lastLevel, nrSamples, flags) | .host2D(format, w, h)
    var backing: [GuestMemory]        // from ATTACH_BACKING; empty until attached
    var scanouts: Set<ScanoutID>      // bound by SET_SCANOUT
    var byteEstimate: UInt64          // for the global memory limit
}
```

Rules:

- Resource IDs are guest-chosen and must be non-zero and unused. Reuse of a live ID returns `ERR_INVALID_RESOURCE_ID`.
- Size checks use checked arithmetic (`width × height × bpp` in `UInt64`, and must be ≤ limits in §5.4). Formats are limited to the virgl/virtio-gpu formats the renderer supports.
- `ATTACH_BACKING` maps every entry. Entries that are not within guest RAM, or whose total length is shorter than the resource needs, fail with `ERR_INVALID_PARAMETER`, and no partial state is kept.
- On `deviceWillReset` the table is cleared, all mappings are dropped, the renderer is reset (all contexts destroyed, `virgl_renderer_reset`), and scanout bindings are cleared. Pools and host-side scanout configuration (§6.1) survive a reset, because they are host decisions.

### 4.5 Contexts, submissions, and fences

- Without `CONTEXT_INIT`, all fences are on one global timeline and complete in order. The device keeps a FIFO of deferred elements `(fenceID, PendingElement)`.
- For a fenced command, the render thread calls `virgl_renderer_create_fence(fenceID, ctxID)` after executing it. virglrenderer's `write_fence(fenceID)` callback (on the render thread) reports the highest completed fence. The device then completes every deferred element with `fenceID ≤ completed`, in order.
- Fence progress requires `virgl_renderer_poll()`. On macOS, virglrenderer's thread-sync mode depends on Linux eventfd and is not available. The render thread therefore polls after every batch and every 1 ms while fences are outstanding (a `DispatchSourceTimer` on the render thread's run loop, stopped when the FIFO is empty).
- Unfenced commands are completed as soon as they execute. The controlq is processed strictly in order, so a response never overtakes an earlier fenced command in a way the guest could observe.

### 4.6 Cursor queue

The Android `drm_virgl` configuration composes in client mode (`hwcomposer.mode=client`) and does not use a hardware cursor plane. The host shows the macOS cursor, and pointer input is injected by the Guest Agent ([input.md](input.md)). `UPDATE_CURSOR` and `MOVE_CURSOR` are acknowledged immediately, and the last values are kept for diagnostics.

### 4.7 Threading

| Thread | Does | Never does |
|---|---|---|
| device queue (serial `DispatchQueue`) | VZ callbacks; drains queues; copies and validates requests; batches them into `RenderCommand`s; writes responses and completes elements | call virglrenderer, EGL, or Metal |
| render thread (one dedicated `Thread`, QoS `.userInteractive`, own run loop) | owns the EGL display, all EGL contexts, virglrenderer; executes commands in order; polls fences; performs present blits; creates the GPU-completion fences | touch VZ objects |
| completion waiter (one `Thread`) | waits on EGL sync objects for present blits, then emits `frameReady` | GL calls other than `eglClientWaitSync` |

Commands flow device queue → render thread in batches (one batch per queue drain). Completions flow back in batches through a lock-free single-producer/single-consumer ring and a `DispatchQueue.async` on the device queue. virglrenderer is not thread-safe, and all of its callbacks arrive on the render thread.

---

## 5. Renderer (GraphicsBridge + VirGLRuntime) (#020, #022)

### 5.1 Libraries

| Library | Revision (initial pin) | License | Role |
|---|---|---|---|
| virglrenderer | 960bd667 + APKRun patches | MIT | decodes VirGL command streams; manages GL objects |
| libepoxy | 1b6d7db | MIT | GL/EGL function dispatch for virglrenderer |
| ANGLE | 2d91f554, Metal backend only | BSD-3-Clause | EGL + GLES 3.0 on Metal |

- Pins, build flags, and patch lists live in `ThirdParty/ThirdParty.lock.json`. The build scripts are `ThirdParty/build/build-angle.sh`, `build-libepoxy.sh`, and `build-virglrenderer.sh`, driven by `scripts/build-third-party.sh virgl-runtime` ([../05-development/build-system.md](../05-development/build-system.md) §6).
- Outputs are dylibs with `@rpath` install names, placed in `ThirdParty/out/virgl-runtime/<lock hash>/`. They are embedded into `APKRun.app/Contents/Frameworks/VirGLRuntime/` and signed inside-out with the app.
- The ANGLE Metal build needs about 11 GB of dependencies. CI caches the outputs keyed by the lock hash, so ANGLE is rebuilt only when its pin or patches change.
- Initial patch set (final list from #018):
  1. `virglrenderer/0001-msaa-downgrade.patch`: clamp requested MSAA sample counts to what ANGLE reports (from RiftVM).
  2. Any build fixes for macOS (no GBM, no eventfd, no DRM), carried from RiftVM or the startergo/homebrew taps it used.
- #020 acceptance: a fresh checkout produces the libraries with `scripts/build-third-party.sh virgl-runtime` and no manual file editing. This is checked in CI.

### 5.2 GraphicsBridge

A C target (`Packages/GraphicsCore/Sources/GraphicsBridge`, with a small Objective-C file for Metal/IOSurface interop). Swift talks only to this interface, never to virglrenderer or EGL headers directly:

```c
typedef struct gb_renderer gb_renderer;

typedef struct {
    void (*write_fence)(void *user, uint32_t fence_id);     // render thread
    void (*log)(void *user, int level, const char *message);
} gb_callbacks;

int  gb_renderer_create(const gb_callbacks *cb, void *user, gb_renderer **out);   // EGL (ANGLE Metal) + virgl_renderer_init
void gb_renderer_destroy(gb_renderer *r);
int  gb_renderer_reset(gb_renderer *r);
void *gb_renderer_metal_device(gb_renderer *r);             // id<MTLDevice> ANGLE uses (EGL_ANGLE_device_metal)

int  gb_capset_info(gb_renderer *r, uint32_t capset_id, uint32_t *max_version, uint32_t *max_size);
int  gb_capset_fill(gb_renderer *r, uint32_t capset_id, uint32_t version, void *out);

int  gb_ctx_create(gb_renderer *r, uint32_t ctx_id, const char *name);
void gb_ctx_destroy(gb_renderer *r, uint32_t ctx_id);
int  gb_ctx_attach_resource(gb_renderer *r, uint32_t ctx_id, uint32_t res_id);
void gb_ctx_detach_resource(gb_renderer *r, uint32_t ctx_id, uint32_t res_id);
int  gb_submit(gb_renderer *r, uint32_t ctx_id, const void *cmd, uint32_t size_bytes);

int  gb_resource_create(gb_renderer *r, const gb_resource_args *args);
void gb_resource_unref(gb_renderer *r, uint32_t res_id);
int  gb_resource_attach_iov(gb_renderer *r, uint32_t res_id, const gb_iovec *iov, uint32_t count);
void gb_resource_detach_iov(gb_renderer *r, uint32_t res_id);
int  gb_transfer_write(gb_renderer *r, const gb_transfer_args *args);   // TO_HOST
int  gb_transfer_read(gb_renderer *r, const gb_transfer_args *args);    // FROM_HOST

int  gb_create_fence(gb_renderer *r, uint32_t fence_id, uint32_t ctx_id);
void gb_poll(gb_renderer *r);

/// Blits the scanout rect of `res_id` into `dst` (an IOSurface-backed MTLTexture), flipping Y.
/// Returns an EGL sync handle to wait on (completion waiter thread).
int  gb_present_blit(gb_renderer *r, uint32_t res_id, gb_rect src, void *dst_mtl_texture, void **out_sync);
int  gb_wait_sync(gb_renderer *r, void *sync, uint64_t timeout_ns);
```

Implementation notes:

- EGL display: `eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, …, EGL_PLATFORM_ANGLE_TYPE_ANGLE = EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE)`. virglrenderer is initialized on its external-EGL path, with callbacks for GL context create, destroy, and make-current, and `get_egl_display` returning ANGLE's display. The exact flags follow RiftVM (#018).
- The IOSurface-backed Metal textures must be created on **ANGLE's `MTLDevice`**, queried with `EGL_ANGLE_device_metal` (`eglQueryDisplayAttribEXT(EGL_DEVICE_EXT)` → `eglQueryDeviceAttribEXT(EGL_METAL_DEVICE_ANGLE)`). On multi-GPU Macs this avoids cross-device copies.
- `gb_present_blit`: `virgl_renderer_borrow_texture_for_scanout` gives the GL texture of the resource. The destination `MTLTexture` is imported once per pool buffer as an `EGLImage` (`EGL_METAL_TEXTURE_ANGLE`) and attached to an FBO. `glBlitFramebuffer` performs the copy with Y-flip and format conversion. Then an EGL fence sync is created and `glFlush` is called.

### 5.3 What the guest gets

- GLES 3.0 through Mesa virgl (`ro.opengles.version=196608`). There is no Vulkan (`ro.cpuvulkan.version=0`, and the Cuttlefish source says "No hardware Vulkan support, yet" for virgl). The bootconfig keys are in [android-image.md](android-image.md) §6.2.
- The GL renderer string seen by apps contains `virgl`. #022 checks it with `dumpsys SurfaceFlinger | grep -i GLES` and HelloGL's reported renderer.
- ANGLE-imposed limits (for example on MSAA and some formats) show up as GLES 3.0 capability limits. Apps that require GLES 3.1+ or Vulkan land in a lower compatibility level ([../00-product/scope.md](../00-product/scope.md) §4).

### 5.4 Limits

Enforced by `ResourceTable` before calling the renderer. Values start as RiftVM's and are configurable in development builds only (`graphics.limits.*` in [../03-reference/configuration.md](../03-reference/configuration.md)).

| Limit | Value | Error |
|---|---|---|
| Total resource memory (estimate) | 2 GiB | `ERR_OUT_OF_MEMORY` |
| Single resource / buffer | 256 MiB | `ERR_OUT_OF_MEMORY` |
| Width or height | ≤ 8192 px | `ERR_INVALID_PARAMETER` |
| Contexts | ≤ 256 | `ERR_UNSPEC` |
| Live resources | ≤ 65536 | `ERR_OUT_OF_MEMORY` |
| Backing entries per attach | ≤ 16384 | `ERR_INVALID_PARAMETER` |
| `SUBMIT_3D` size | ≤ 4 MiB | `ERR_INVALID_PARAMETER` |

Reaching a memory limit is logged with the current totals, and the `graphics.memory` health value turns yellow ([diagnostics.md](diagnostics.md)).

---

## 6. Scanouts and presentation (#023, #028, #067)

### 6.1 ScanoutTable and host control

The host decides which scanouts exist and what mode they offer. The guest decides what it shows on them.

```swift
public struct ScanoutID: Hashable, Sendable { public let rawValue: Int }   // 0...15

public struct DisplayMode: Sendable, Equatable {
    public var widthPixels: Int                    // ≤ 4095 while EDID uses a detailed timing descriptor (§6.4)
    public var heightPixels: Int
    public var refreshHz: Int                      // 60
    public var dotsPerInch: Int                    // encoded as physical size in the EDID
}

public actor ScanoutController {
    public func configure(_ id: ScanoutID, mode: DisplayMode) async throws(GraphicsFailure)   // enabled = true, display event (§4.3)
    public func disable(_ id: ScanoutID) async throws(GraphicsFailure)                        // enabled = false, display event
    public func attach(_ pool: SurfacePool, to id: ScanoutID)       // start presenting this scanout
    public func detachPool(from id: ScanoutID) -> SurfacePool?      // stop presenting (flushes still complete)
    public func setPresenting(_ id: ScanoutID, _ presenting: Bool)  // false while the consumer is not visible (display-and-windowing.md §5.2 rules 4–5)
    public func requestPresent(_ id: ScanoutID)                     // re-blit the bound resource now, without a guest flush
    public nonisolated var events: AsyncStream<ScanoutEvent> { get }
    public func statistics(_ id: ScanoutID) -> FrameStatistics
}

public enum ScanoutEvent: Sendable {
    case guestBound(ScanoutID, resourceSize: PixelSize)   // SET_SCANOUT with a resource
    case guestUnbound(ScanoutID)                          // SET_SCANOUT with resource 0
    case frameReady(ScanoutID, bufferIndex: Int, sequence: UInt64, hostTime: UInt64)
    case frameDropped(ScanoutID, sequence: UInt64)
    case deviceReset
}
```

- Scanout 0 is configured at device creation with the image's default display mode, so Android has its primary display from the first boot. The mode comes from `lcd_density` and the reference capture ([android-image.md](android-image.md) §6.2).
- `DisplayPool` (RuntimeCore) calls `configure` and `disable` for scanouts 1…15. It maps scanouts to Android display IDs after the Guest Agent reports `DisplayAdded` ([display-and-windowing.md](display-and-windowing.md), [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §4).
- A scanout with no attached pool still accepts `SET_SCANOUT` and `RESOURCE_FLUSH`. The flush is completed without a blit. This is how the hidden display 0 costs nothing on the host in `secondaryDisplay` mode ([ADR-0005](../01-architecture/decisions/0005-multi-display-window-model.md)).

### 6.2 Present on `RESOURCE_FLUSH`

For each scanout bound to the flushed resource and with a pool attached:

1. **Pick a buffer.** `SurfacePool.acquireForRender()` returns a free buffer index. If none is free (the consumer still holds the others), the present waits as the scanout's single pending present, and it runs as soon as a buffer frees. A newer flush replaces a pending present, and the replaced frame counts as dropped (latest frame wins, like RiftVM's `LatestFrameScheduler`). An offered buffer is never overwritten ([display-and-windowing.md](display-and-windowing.md) §5.2 rule 1). At most one blit per scanout is in flight.
2. **Blit.** On the render thread, `gb_present_blit(resource, rect, pool.texture(i))`. The source rect is the scanout rect from `SET_SCANOUT`. If the resource size differs from the pool size (during a resize), the blit scales to the pool size and logs once per mode change.
3. **Complete the guest's flush.** The flush response is sent after the blit is flushed to the GPU queue, not after it has executed and not after display. The flush of a replaced pending present is completed when it is replaced, and a flush on a scanout that is not presenting is completed at once. The guest HWC paces itself with its own vsync timer, so the host does not add back-pressure. The ordering of the blit against later guest rendering relies on ANGLE's Metal backend using one command queue per display. #023 verifies there is no tearing with HelloGL's alternating-color test (§12).
4. **GPU completion.** The completion waiter waits on the blit's EGL sync (timeout 100 ms, which is logged as a stall) and then emits `frameReady(scanout, i, seq, hostTime)`. The IOSurface content is complete before any consumer sees the index.

Pixel formats: guest scanout resources are 32-bit (`B8G8R8X8`/`B8G8R8A8`/`R8G8B8A8` variants). Pool buffers are always `BGRA8Unorm` in sRGB. The blit converts, and alpha is forced opaque for X formats.

### 6.3 SurfacePool

```swift
public final class SurfacePool: Sendable {
    public init(pixelSize: PixelSize, bufferCount: Int = 3, device: any MTLDevice) throws(GraphicsFailure)
    public let generation: UInt64                  // increases on every reallocation
    public let pixelSize: PixelSize
    public var surfaces: [IOSurface] { get }       // sent to the wrapper once per generation
    func acquireForRender() -> Int?                // render thread
    func markReady(_ index: Int, sequence: UInt64)
    public func consumerDisplayed(upTo sequence: UInt64)   // from the wrapper's frameDisplayed (display-and-windowing.md §5)
}
```

- IOSurface properties: width and height in pixels, `BGRA`, bytes-per-row aligned to 64 (`IOSurfaceAlignProperty`), not global (`kIOSurfaceIsGlobal` is not set, so it is shared only by XPC handle). The Metal texture for each surface is created once (`makeTexture(descriptor:iosurface:plane:)` on ANGLE's device) and imported into EGL once.
- Buffer states: `free → rendering → offered(seq) → displayed(seq) → free`. `markReady` moves a buffer to `offered`, and `consumerDisplayed` moves it to `displayed`. The state machine and its rules for when the wrapper may hold a buffer are in [display-and-windowing.md](display-and-windowing.md) §5.2, and the code uses its state names. GraphicsCore implements them. The wrapper only sends `frameDisplayed`.
- A resize allocates a new pool (a new generation). The old pool is released when the consumer acknowledges `surfacesReplaced`, or after 1 s.
- Memory: 3 × width × height × 4 bytes per displayed scanout (for 1440×3120 that is about 54 MiB). This is reported in frame statistics and in `apkrun info --runtime`.

### 6.4 EDID

`EDIDGenerator` produces a 128-byte EDID 1.4 base block per scanout:

- Manufacturer `APK`, product code = scanout index, serial = scanout index. The name descriptor is `APKRun <index>`.
- One detailed timing descriptor with the preferred mode (`widthPixels × heightPixels` at `refreshHz`, CVT reduced-blanking timings). Detailed timings have 12-bit active fields, so the limit is 4095 pixels per dimension. [display-and-windowing.md](display-and-windowing.md) keeps display modes within that limit (it renders at a lower scale when a window's backing size is larger). A DisplayID extension block for larger modes is post-v1.
- Physical size in mm (the base block in cm, and the detailed timing in mm), computed from `dotsPerInch`. Android derives the per-display DPI from it through the HWC. The exact effect on the density of secondary displays is verified in #067.
- A range-limits descriptor and the checksum. Unit tests compare against golden EDIDs and decode them with a reference decoder (edid-decode output committed as test data).

---

## 7. Frame statistics and counters (#023, #070)

The graphics metrics are FPS, frame latency, dropped frames, CPU utilization, GPU utilization, resource copies, and CPU readbacks. GraphicsCore records the following per scanout and globally, and exposes them through `ScanoutController.statistics` and the diagnostics snapshot.

| Metric | Definition | Where it is measured |
|---|---|---|
| `fps` | `frameReady` events per second (1 s window, plus a 10 s average) | completion waiter |
| `guestFlushRate` | `RESOURCE_FLUSH` per second (higher than `fps` means frames are dropped or coalesced) | device queue |
| `flushToReady` | host time from flush decode to `frameReady` (p50/p95) | device queue + waiter |
| `readyToDisplayed` | `frameReady` to the wrapper's `frameDisplayed` (p50/p95) | RuntimeCore → GraphicsCore |
| `presentGPUTime` | EGL sync wait duration (upper bound for the blit's GPU time) | waiter |
| `droppedFrames` | frames replaced before display | scheduler |
| `hostReadbacks` | GPU→CPU reads of pixel data performed by the host on its own initiative. **Must be 0 on the normal path** (NFR-PERF-05) | every code path that could read back increments it |
| `guestReadbacks` | `TRANSFER_FROM_HOST_3D` count and bytes (app-requested, e.g. `glReadPixels`) | device queue |
| `cpuPixelCopies` | CPU copies of pixel data on the present path (2D profile only; must be 0 in `drmVirgl`) | 2D renderer |
| `resourceMemory`, `contexts`, `resources` | current totals and high-water marks | `ResourceTable` |
| `apkrundCPU` | process CPU time (`task_info`) sampled each second | DiagnosticsCore |
| `gpuUtilization` | best effort: IOKit accelerator `PerformanceStatistics` "Device Utilization %" | DiagnosticsCore |

Signposts (`io.apkrun.graphics`, category `present`): an interval `gpu.flush` (decode to completion) and an interval `gpu.present` (blit to `frameReady`). The `FIRST_FRAME` perf marker for a session is emitted by RuntimeCore on the first `frameReady` of the session's scanout ([diagnostics.md](diagnostics.md) §4).

---

## 8. Lifecycle

| Event | GraphicsCore action |
|---|---|
| VM configuration | `VirtioGPUDevice` created with a profile (§9). The render thread starts, and `gb_renderer_create` runs **before the VM starts**, so an EGL/ANGLE failure is reported as `GraphicsFailure.rendererInitFailed` before Android boots |
| DRIVER_OK (`deviceDidStart`) | queues become available; config space already holds `num_scanouts`/`num_capsets` |
| `WillPause` | stop blits: flushes still complete, pools receive no new frames. In-flight blits finish. Statistics timers pause. The renderer and resources stay |
| `WillResume` | resume blits. The next guest flush produces a frame. If no flush arrives within 100 ms, the last presented buffer stays on screen (nothing to redraw) |
| `WillReset` (guest reboot or reset) | complete or abandon deferred elements (abandoned elements are not returned; VZ discards them on reset), clear `ResourceTable`, drop mappings, `gb_renderer_reset`, clear scanout bindings, emit `.deviceReset`. Host scanout configuration and pools are kept |
| `WillStop` | as reset, then destroy the renderer, stop the render thread, and release pools |
| Save/restore | unsupported (`supportsSaveRestore = false`). VM save/restore is therefore unavailable while this device is attached (R-07, [vm.md](vm.md) §9.5) |

Pause and resume are driven by RuntimeCore's idle policy ([runtime-daemon.md](runtime-daemon.md) §5). While paused, the wrapper keeps showing the last frame.

Failure policy:

- An EGL/GL error inside a guest context is logged, and the command returns `ERR_UNSPEC`. The guest's Mesa usually recovers or kills the app.
- `GraphicsFailure.rendererLost` (ANGLE reports context loss, or a Metal device is removed): all resources are gone. GraphicsCore emits it, and RuntimeCore restarts Android (VM stop and start) with a diagnostics snapshot. The Linux `virtio_gpu` driver does not recover from DEVICE_NEEDS_RESET, so `requestReset` is not used for recovery.
- virglrenderer runs inside apkrund. A crash in it crashes apkrund, and the VM with it. launchd restarts apkrund (NFR-REL-02). The renderer cannot be moved out of process in v1, because guest memory mappings exist only in the process that owns the VM. This is recorded as a security consideration (§11).

---

## 9. GPU profiles and the software fallback

| Profile | Device features | Guest configuration (bootconfig, [android-image.md](android-image.md) §6.2) | Host renderer | Use |
|---|---|---|---|---|
| `drmVirgl` (default) | VIRGL + EDID | `egl=mesa`, `gralloc=minigbm`, `hwcomposer=ranchu`, `hwcomposer.mode=client`, `display_finder_mode=drm`, `cpuvulkan.version=0`, `opengles.version=196608` | virglrenderer + ANGLE | product path |
| `guestSwiftshader` | EDID only (no VIRGL) | Cuttlefish's `guest_swiftshader` set (ANGLE on SwiftShader in the guest, GLES 3.1, Vulkan via SwiftShader), keys copied from the reference capture of that profile ([android-image.md](android-image.md) §8.2) | 2D renderer: dumb/2D resources copied from guest backing into the pool buffer on flush (`cpuPixelCopies` > 0) | debugging, bring-up before #022, and the documented Graphics Safe Mode if VirGL breaks on a user's Mac |
| `headless` (development only) | no GPU device | Cuttlefish's no-GPU graphics set, copied in #014 from `bootconfig_args.cpp` ([android-image.md](android-image.md) §9.1) | none | M1 bring-up before the virtio-gpu device exists (#012–#017, `apkrun dev boot --gpu none`). Never in a release bundle |

- The profile is chosen per boot: `BootOptions.gpuProfile` ([android-image.md](android-image.md) §9.1). Changing it requires restarting Android, because the bootconfig changes.
- The user-facing setting is `graphics.safeMode` (off by default, [../03-reference/configuration.md](../03-reference/configuration.md)). It appears in Settings → Troubleshooting and is suggested by `apkrun doctor` after repeated `rendererInitFailed` or `rendererLost`. The UI and diagnostics show clearly that it is a slow fallback.
- There is no automatic fallback in v1. Silent fallback would hide regressions and make performance reports meaningless.
- The 2D renderer uses a plain Metal path (`replaceRegion` into the pool texture from the mapped guest backing). It is the only place where `cpuPixelCopies` may be non-zero. #022 builds it, and `boot_completed` with `guestSwiftshader` is part of #022's T2 suite.
- `VZVirtioGraphicsDeviceConfiguration` (VZ's own 2D device, one scanout) is not used for either profile, because it cannot provide multiple scanouts ([ADR-0002](../01-architecture/decisions/0002-virtualization-framework-macos27.md)).

---

## 10. Vulkan track (#096, post-v1)

Not a v1 blocker. The notes below record what the research found, so the post-v1 work starts from facts:

- Venus (Vulkan over virtio-gpu) and native contexts need `VIRTIO_GPU_F_RESOURCE_BLOB` and `VIRTIO_GPU_F_CONTEXT_INIT`, plus a host-visible shared memory region. On macOS 27 that is a `VZVirtioSharedMemoryRegionConfiguration` (region ID 1 for virtio-gpu host-visible memory) and `VZVirtioSharedMemoryRegion.mapMemory(_:atOffset:size:)` (page-aligned, completion on the device queue). libkrun maps blobs into its shared memory region the same way on Hypervisor.framework.
- The host side would be virglrenderer's venus backend on MoltenVK (as in UTM and krunkit), or gfxstream.
- The first spike checks `maximumAllowedSharedMemoryRegionCount` (≥ 1 required) and whether mapping IOSurface- or Metal-heap-backed memory into the region works.
- Guest side: Cuttlefish/Android would need a Venus-capable Mesa build and the matching bootconfig (`vulkan` APEX selection, [android-image.md](android-image.md) §6.2), which means a custom image.
- `CONTEXT_INIT` also brings per-context fence timelines (`ring_idx`), which would lift the in-order fence limitation of §4.5.

---

## 11. Security considerations

The guest is untrusted from the host's point of view ([../01-architecture/security-model.md](../01-architecture/security-model.md)). The virtio-gpu device and virglrenderer parse guest-controlled data in apkrund, which holds the virtualization entitlement and the user's files.

- Every guest value is validated after copying (§3.2), with checked arithmetic. There are no struct casts over guest memory.
- Limits (§5.4) bound memory use.
- virglrenderer's command decoder is the largest attack surface. It is pinned, its patches are reviewed, and upstream security fixes are tracked (Dependabot-like check in CI against the upstream repository; [../05-development/build-system.md](../05-development/build-system.md) §6).
- Fuzzing (#091): a libFuzzer target over `VirtioGPUProtocol` decoding and `ResourceTable` (runs in CI, T1), and a virgl command-stream fuzzer run against the renderer in a separate test process.
- A renderer crash takes down apkrund (§8). Moving the renderer to a separate process is post-v1 research. It would need guest-memory sharing across processes, which VZ does not offer.

---

## 12. Implementation steps

Each step lists what to build and how it is verified. Steps within a task are in order.

### #018 RiftVM analysis (M2)

1. Pin the RiftVM commit (v1.0.4) in `ThirdParty.lock.json` (source only; not built).
2. Read the files in §2.1 and the architecture document. Write `docs/02-design/riftvm-analysis.md` with the table in §2.2 filled in, file by file.
3. List the patches and exact build flags for virglrenderer, libepoxy, and ANGLE used by RiftVM. They seed #020.
4. Update §2.1 and §5.1 of this document if the analysis finds differences.

### #063 VirtioDeviceCore + test device (M0)

1. `VirtioDeviceDescriptor`, `VirtioDeviceModel`, `VirtioDeviceContext`, `VirtioQueue`, `VirtioElement`, `GuestMemory` (§3.2), and the VZ adapter that builds `VZCustomVirtioDeviceConfiguration` from a descriptor.
2. Fakes (`FakeVirtioQueue`, `FakeGuestMemory`) and T0 tests: drain loop, exactly-once completion, bounds and overflow checks, feature splitting.
3. `EntropyTestDevice` (§3.3). Extend the Linux test guest's `/init` with the `rng` check.
4. T2: acceptance in §3.3.

### #019 virtio-gpu device layer (M2)

1. `VirtioGPUProtocol` structs and decoding for every command in §4.2, with T0 tests from golden request/response byte vectors (taken from Linux driver traces in the Linux test guest).
2. `VirtioGPUDevice` with feature negotiation, config space, `GET_DISPLAY_INFO`, `GET_EDID` (EDID generator §6.4), and error responses for everything else. No renderer yet.
3. `ScanoutTable` with scanout 0 enabled at a fixed test mode.
4. T2 with the Linux test guest (`apkrun.test=gpu`): `lspci`/sysfs shows vendor 1af4 device 1050, `dmesg` shows `virtio_gpu` initialized with 16 scanouts, `/sys/class/drm/card0-Virtual-1/status` is `connected`, and the EDID read from `/sys/class/drm/card0-Virtual-1/edid` equals the generated one. This is the acceptance: a Linux guest detects a virtio GPU device.
5. Spike for §4.3: enable scanout 1 at runtime and check that the guest sees the hotplug. Record the result in R-01 and in §4.3.

### #020 Renderer libraries (M2)

1. Build scripts for ANGLE (Metal only), libepoxy, and virglrenderer with pins and patches from #018. Outputs go to `ThirdParty/out/virgl-runtime/<hash>/`.
2. `GraphicsBridge` skeleton: `gb_renderer_create`/`destroy` and capset queries.
3. T1: a host-only test creates the renderer, queries the `VIRGL2` capset, creates a context, and destroys everything (needs a Metal device; skipped with a clear message otherwise).
4. CI job: clean build of the runtime libraries from the lock file, with caching.

### Renderer integration with the Linux test guest (M2, #022 and #023)

Before Android, prove VirGL end to end with Linux:

1. (#022) Add Mesa's virgl Gallium driver and `kmscube` to the Linux test initramfs (pinned Alpine packages).
2. (#022) `apkrun dev linux --tests virgl` runs `kmscube` headless on scanout 0. The check reads the `virgl` renderer name from its output, and the recorded command stream is the input of the T1 replay test (§14).
3. (#023) `apkrun dev linux --tests virgl --window` shows `kmscube` in the development window of #023. Acceptance: the cube animates at ≥ 55 fps and `hostReadbacks = 0`.

### #021 Android detects virtio-gpu (M2)

1. Attach `VirtioGPUDevice` in the Android `VMDefinition`. RuntimeCore appends it to the boot plan's definition for the requested GPU profile ([android-image.md](android-image.md) §9.1), and `apkrun dev boot --gpu swiftshader` requests `guestSwiftshader`.
2. Boot Android and capture `dmesg`, `/sys/class/drm`, and `/sys/bus/virtio/devices/*/device`.
3. Acceptance: `virtio_gpu` binds, `card0` exists with 16 `Virtual-N` connectors, and `Virtual-1` (scanout 0) is `connected` while the others are `disconnected`.

### #022 Android VirGL (M2)

1. Complete the 3D command set (§4.2, §4.4, §4.5): contexts, 3D resources, submit, transfers, fences, and polling.
2. Boot with the `drmVirgl` profile bootconfig.
3. The 2D renderer of §9 for `guestSwiftshader`, so that profile reaches `boot_completed` too.
4. The Linux steps 1–2 above.
5. Acceptance: SurfaceFlinger starts with GLES through virgl (`dumpsys SurfaceFlinger` shows the virgl GLES renderer), no SwiftShader/ANGLE-in-guest libraries are loaded by SurfaceFlinger (`/proc/<pid>/maps`), and `sys.boot_completed=1`.

### #023 SurfaceFlinger to Metal (M2, gate G3)

1. `SurfacePool`, the present path (§6.2), the completion waiter, and statistics (§7).
2. `apkrun dev boot --gpu virgl --window` shows display 0 in a development `NSWindow`. It uses WindowingCore's IOSurface layer in-process, the same code the wrapper uses later.
3. The window is **fixed-size**: display 0 keeps the image's default mode, and the window scales the layer with aspect fit. This is the explicit resize behavior #023 asks for; runtime resize comes with #067.
4. HelloGL (Tests/Fixtures/AndroidApps) runs, and the frame-statistics overlay (`--stats`) shows fps and counters.
5. Acceptance: the Android display is visible in a macOS window, GPU-accelerated (`drmVirgl`), `hostReadbacks = 0` and `cpuPixelCopies = 0` over a 60 s HelloGL run, HelloGL ≥ 55 fps average (NFR-PERF-04), and no tearing in HelloGL's alternating-color test (a host-side check samples pool buffers in a **test-only** readback mode, which exists only in builds with the `APKRUN_TEST_READBACK` flag and is excluded from the counter).

### Later tasks that extend graphics

- #028: `ScanoutController.configure`/`disable` used by `DisplayPool`; the hotplug path with Android (§4.3 fallbacks if needed).
- #067: mode changes at runtime (new EDID and display event), pool reallocation, the DPI → EDID mapping.
- #068: pools shared with the wrapper over XPC ([display-and-windowing.md](display-and-windowing.md) §5).
- #070: the perf harness reads the statistics in §7.
- #091: fuzzing (§11).

---

## 13. Errors and logging

### 13.1 `GraphicsFailure` (error domain `graphics`)

| Case | Meaning | Remediation shown |
|---|---|---|
| `rendererInitFailed(stage, detail)` | EGL/ANGLE/virglrenderer initialization failed (stage: `egl`, `metal`, `virgl`) | update macOS / APKRun; try Graphics Safe Mode; attach diagnostics |
| `rendererLost(reason)` | context loss or GPU removal | Android restarts automatically |
| `libraryMissing(name)` | VirGLRuntime dylib missing or invalid signature | reinstall APKRun |
| `scanoutInvalid(ScanoutID)` | host requested a scanout outside 0…15 | bug report |
| `modeUnsupported(DisplayMode)` | mode exceeds EDID/limit constraints | bug report (DisplayPool should have clamped) |
| `poolAllocationFailed(PixelSize)` | IOSurface or Metal texture creation failed | close other apps; attach diagnostics |
| `configUpdateFailed(detail)` | `updateConfigurationSpace` failed | Android display changes may not apply; restart Android |
| `deviceNotReady` | a host request arrived before DRIVER_OK | retried by DisplayPool after `.guestBound` or boot completion |
| `deviceSetupFailed` | health finding of `graphics.device`, never thrown: the device is missing or feature negotiation failed | start in Graphics Safe Mode; attach diagnostics |
| `softwareRendering` | health finding of `graphics.guestDriver`, never thrown: Android fell back to software rendering | restart Android; attach diagnostics |
| `presentationSlowPath` | health finding of `graphics.present`, never thrown: a readback or CPU copy counter is non-zero (§7) | bug report |
| `memoryLimitReached` | health finding of `graphics.memory`, never thrown: a memory limit was reached (§5.4) | close some Android app windows |
| `safeModeOn` | health finding of `graphics.safeMode`, never thrown: the `guestSwiftshader` profile is in use (§9) | turn it off in Settings → Troubleshooting |

Guest-caused errors are virtio-gpu error responses, not `GraphicsFailure`s (§4.2). The catalogue with codes is in [../03-reference/error-catalog.md](../03-reference/error-catalog.md).

### 13.2 Logging

Subsystem `io.apkrun.graphics`, categories `device` (negotiation, commands, guest errors), `renderer` (virglrenderer/ANGLE log callback, context lifecycle), `present` (pools, frames, stalls), and `stats` (periodic summary every 60 s while any scanout is presenting). Per-command logging is available at debug level only, and is off in release builds.

---

## 14. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | VirtioDeviceCore fakes: drain, completion, bounds, features | #063 |
| T0 | `VirtioGPUProtocol` decode/encode for every command, including truncated and oversized inputs; golden vectors from Linux traces | #019 |
| T0 | `ResourceTable` limits and overflow, backing validation, reset clearing | #019, #022 |
| T0 | Display event logic (§4.3): generation counter, clearing on `GET_DISPLAY_INFO`, change during an in-flight query | #019, #028 |
| T0 | EDID generator against golden files and a decoder | #019, #067 |
| T0 | Frame scheduler and `SurfacePool` state machine (drop policy, generation change) | #023, #068 |
| T1 | GraphicsBridge renderer create/destroy, capsets (needs Metal) | #020 |
| T1 | Replay of a recorded virgl command stream (captured from the Linux guest's `kmscube` in the M2 integration step) → hash of the scanout resource within tolerance, read in the test-only readback mode (needs Metal) | #022 |
| T1 | Fuzz targets for protocol decoding (time-boxed in CI) | #091 |
| T2 | Linux test guest: `rng`, `gpu` (probe, EDID, hotplug spike), `virgl` (kmscube headless, then in a window) | #063, #019, #022, #023 |
| T2 | Android: `virtio_gpu` binding, VirGL SurfaceFlinger, boot_completed with `drmVirgl` and with `guestSwiftshader` | #021, #022, §9 |
| T3 | Gate G3: HelloGL visible, ≥ 55 fps, zero host readbacks, no tearing | #023 |

---

## 15. Open items

| Item | Plan |
|---|---|
| What VZ does on a guest reboot is not documented: a device reset and a second boot, or `guestDidStop` (§3.3) | #063 observes it with the Linux test guest and records it in §3.3 and R-01 |
| `maximumAllowedSharedMemoryRegionCount` is not documented (§3.1) | v1 offers no shared-memory region (§4.1). The first Vulkan spike in #096 checks that the count is ≥ 1 (§10) |
| Does `updateDeviceSpecificConfiguration` raise a config-change interrupt in the guest (§4.3, R-01) | #019 runs the spike with the Linux test guest, and #028 repeats it with Android. If not, fallback A (the Guest Agent forces a DRM connector re-probe on the custom image; #028 checks that the driver re-reads the display info), then B (all pool scanouts enabled at boot), then C (a fixed display count per boot, R-04) |
| The exact RiftVM patches, build flags, and EGL init flags (§5.1, §5.2) | #018 lists them in `riftvm-analysis.md` and updates §2.1 and §5.1. Until then, the initial patch set in §5.1 is the working default |
| The present ordering relies on ANGLE's Metal backend using one command queue per display (§6.2) | #023 checks that HelloGL's alternating-color test shows no tearing |
| How the EDID physical size affects the density of secondary displays (§6.4, OQ-39) | #067. Working default: the density is set with `setDisplayPolicy` only, and the result is recorded in §6.4 |
| Whether `gpuUtilization` from the IOKit accelerator statistics is usable (§7, OQ-07) | #070 checks it on the reference Mac. Working default: best effort, reported as unavailable when the key is missing |
| virglrenderer and ANGLE render common apps correctly (§5, R-02) | #020, #022, #023, then the compatibility runs of #090. Fallback: the `guestSwiftshader` profile through Graphics Safe Mode (§9). There is no automatic fallback |
| One render thread serves several displays at 60 fps within the present budget (§4.7, §7, R-03) | #023 measures one display and #030 two in the embedded runtime; #068 and #070 measure the XPC path in apkrund. Fallback: a lower frame rate for background windows, one renderer context thread per display if virglrenderer allows it, or revised targets through an ADR |
| Multi-scanout with the ranchu HWC: runtime hotplug, and mode changes that keep the display ID (§6.1, §6.4, R-04) | #028 (hotplug) and #067 (mode change). Fallback: a fixed pool size per boot (§4.3, fallback C) and the resize fallbacks of [display-and-windowing.md](display-and-windowing.md) §7.1 |
| Host memory of the renderer and of one pool per display (§5.4, §6.3, R-08) | #028 and #070 measure it. Fallback: lower defaults and smaller pools |
| No VM save/restore while this device is attached (§8, R-07, accepted) | revisited if a later virglrenderer or the Vulkan track (#096) can rebuild the renderer state |

---

## 16. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| Custom virtio API with `EntropyTestDevice`: queue validity before DRIVER_OK, same-size config updates, reset and mapping invalidation, guest reboot | #063 | pending (§3.1, §3.3) |
| RiftVM analysis: differences to §2.1 and §5.1, renderer patches, and build flags | #018 | pending (§2.1, §5.1) |
| The Linux test guest detects the virtio GPU: vendor 1af4 device 1050, 16 scanouts, `Virtual-1` connected, EDID equal to the generated one | #019 | pending (§12) |
| Config-change interrupt from `updateDeviceSpecificConfiguration`: hotplug of scanout 1 on the Linux test guest | #019 | pending (§4.3) |
| Clean build of the runtime libraries from the lock file; renderer create and the `VIRGL2` capset on the host | #020 | pending (§5.1) |
| `kmscube` on the Linux test guest: `virgl` renderer and `hostReadbacks = 0` headless (#022), ≥ 55 fps in the development window (#023) | #022, #023 | pending (§12) |
| Android binds `virtio_gpu`: `card0` with 16 `Virtual-N` connectors, only `Virtual-1` connected | #021 | pending (§12) |
| SurfaceFlinger uses GLES through virgl, no guest SwiftShader or ANGLE libraries, `sys.boot_completed=1` | #022 | pending (§5.3) |
| Gate G3: HelloGL ≥ 55 fps average, `hostReadbacks = 0` and `cpuPixelCopies = 0` over 60 s, no tearing | #023 | pending (§6.2, §7) |
| Hotplug with Android, and whether fallback A makes the driver re-read the display info | #028 | pending (§4.3) |
| A runtime mode change keeps the display ID; density of secondary displays from the EDID (OQ-39) | #067 | pending (§6.4) |
| Two displays: fps, present time p95, and memory; `gpuUtilization` availability (OQ-07) | #030, #070 | pending (§7) |
| `maximumAllowedSharedMemoryRegionCount`, and mapping IOSurface- or Metal-heap-backed memory into a shared-memory region | #096 | pending (§10) |
