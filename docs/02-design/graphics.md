# Graphics Design

This document specifies the virtio-gpu device (`VirtioDeviceCore` and `GraphicsCore`), the VirGL renderer and its C bridge (`GraphicsBridge`), and the presentation of scanouts into IOSurfaces. It covers the frame path, the virtio-gpu protocol, renderer limits, scanouts, GPU profiles, metrics, lifecycle, errors, and tests. Display mapping and windows are in [display-and-windowing.md](display-and-windowing.md).

---

## 1. Responsibilities

| Component | Module | Owns | Must not |
|---|---|---|---|
| Custom virtio adapter | `VirtioDeviceCore` | Wrapping `VZCustomVirtioDevice*`: descriptors, feature negotiation, config space updates, queue draining, element completion, guest memory mapping, shared memory regions, the test entropy device | know about GPUs |
| virtio-gpu device model | `GraphicsCore` | Command decoding and validation, resources and backing, contexts, fences, scanouts, EDID, cursor queue | know about windows, sessions, or Android packages |
| Renderer | `GraphicsCore` + `GraphicsBridge` | The render thread, virglrenderer, EGL/ANGLE on Metal, the 2D renderer for the `guestSwiftshader` profile | be called from any thread other than the render thread |
| Presentation | `GraphicsCore` | `SurfacePool` (three IOSurfaces per scanout), the per-frame GPU blit, frame scheduling, statistics, readback counters | own `NSWindow`s (WindowingCore) or decide which scanout belongs to which app (RuntimeCore `DisplayPool`) |
| Renderer libraries | `ThirdParty/` → `Contents/Frameworks/VirGLRuntime/` | Pinned builds of virglrenderer, libepoxy, and ANGLE, with patches | — |

Out of scope:

- Mapping displays to sessions and windows, density, and resize policy: [display-and-windowing.md](display-and-windowing.md).
- Buffer handoff to the wrapper and the `frameDisplayed` release protocol: [display-and-windowing.md](display-and-windowing.md) §5.
- Vulkan: §10.

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
ScanoutFrame.frameReady(generation, i, seq) ─▶ RuntimeCore ─▶ XPC frameReady ─▶ wrapper layer.contents
```

The normal path has no CPU copy of pixel data and no GPU→CPU readback (FR-GFX-05, NFR-PERF-05). The blit writes an IOSurface that the wrapper process presents. RiftVM blits into a `CAMetalLayer` drawable of its own process; APKRun does not ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md), [riftvm-analysis.md](riftvm-analysis.md) §3).

---

## 2. RiftVM as a technical reference

### 2.1 What APKRun takes from RiftVM

APKRun uses the pinned RiftVM source (`riftvm-v0.6.1`, lock entry `riftvm`) as a reference only. [riftvm-analysis.md](riftvm-analysis.md) records the source identity and the reuse decision for each file.

- **Reused as patterns:** the custom virtio device on Virtualization.framework; the features `VIRTIO_GPU_F_VIRGL` and `VIRTIO_GPU_F_EDID`; the renderer pins and patches (§5.1); the EGL/ANGLE initialization sequence (§5.2); the dedicated render thread with fence polling (§4.7); and latest-frame coalescing (§6.2).
- **Rejected:** one scanout (§4.1 needs 16); `CAMetalLayer` presentation (the wrapper is another process, [ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)); RiftVM's resource limits (§5.4 sets its own); its 2-second fence timeout (APKRun counts stalls, §6.2); its `glReadPixels` diagnostic sampling (it breaks the zero-readback rule, §7); and its virtio-input probe (input uses USB and the Guest Agent, [ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md)).

### 2.2 Analysis scope

[riftvm-analysis.md](riftvm-analysis.md) covers each step of the flow: the custom virtio device, virtqueues, virtio-gpu commands, resource creation and backing, VirGL, scanout, ANGLE, Metal, and cursor.

### 2.3 Reuse rules

- Copied or adapted RiftVM files keep the MIT notice at the top and the line `Derived from RiftVM <commit> (MIT)`. The notice is also in `ThirdPartyNotices.html` ([legal-and-licensing.md](../05-development/legal-and-licensing.md)).
- Code follows APKRun's module boundaries. Device-agnostic parts go to `VirtioDeviceCore`, and virtio-gpu parts go to `GraphicsCore`. RiftVM's app structure is not kept.
- The RiftVM lock entry is `ships: reference`: the source is not built, imported, copied, or distributed. The exception is the MSAA patch `virglrenderer/0002` (§5.1), which ships. A later task that copies or adapts RiftVM code changes the entry to `ships: derived`, keeps the notices, and never imports the RiftVM package.

---

## 3. VirtioDeviceCore

### 3.1 Platform API (macOS 27)

- `VZVirtualMachineConfiguration.customVirtioDevices` takes `VZCustomVirtioDeviceConfiguration`: device ID, PCI class and subclass, `virtioQueueCount`, `mandatoryFeatures`/`optionalFeatures` (`VZVirtioFeatureSet`; `VIRTIO_F_VERSION_1` is always set), `deviceSpecificConfiguration`, `sharedMemoryRegions`, `provider`, and `supportsSaveRestore` (default `NO`; setting it without the save/restore delegate methods raises an exception).
- All device callbacks run on the provider's `deviceQueue`, in apkrund, which owns the `VZVirtualMachine`. `didCreateDevice` runs on the VM's serial queue and must set `device.delegate` before it returns.
- `queueAtIndex:` and `negotiatedFeatures` are valid only after DRIVER_OK. Guest memory mappings become invalid after reset, reboot, or stop. `requestDeviceReset` sets DEVICE_NEEDS_RESET. `updateDeviceSpecificConfiguration` replaces the config bytes with data of the **same size**.
- `VZVirtioQueue.nextElement` suppresses notifications until the queue is empty, so callers loop until it returns `nil`. Element buffers are zero-copy views of guest memory, and `returnToQueue` is called exactly once. The guest can change memory after it is read.
- Not available: a raise-interrupt call (completion and config updates are the only signals) and any callback for guest writes to config space. `maximumAllowedSharedMemoryRegionCount` is not documented.

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
    func deviceDidStart(context: VirtioDeviceContext, negotiatedFeatures: UInt64)
    func queueNotified(index: Int, context: VirtioDeviceContext)
    func deviceWillPause()
    func deviceWillResume()
    func deviceWillReset()
    func deviceWillInvalidateGuestMemory()          // before reset or stop drops the mappings
    func deviceWillStop()
}

public final class VirtioDeviceContext {            // not Sendable; synchronous access is device-queue confined
    public func queue(_ index: Int) throws(VirtioFailure) -> any VirtioQueue
    public var negotiatedFeatures: UInt64 { get throws(VirtioFailure) }
    public func mapGuestMemory(_ range: GuestPhysicalRange) throws(VirtioFailure) -> GuestMemory
    public var configurationUpdater: VirtioDeviceConfigurationUpdater { get }
    public func updateConfigurationSpace(_ bytes: Data) async throws(VirtioFailure)
    public func requestReset(reason: String)
}

public struct VirtioDeviceConfigurationUpdater: Sendable {
    public func updateConfigurationSpace(_ bytes: Data) async throws(VirtioFailure)
}

public protocol VirtioQueue {                       // VZ-backed and fake implementations
    /// Calls `body` for every available element until the queue is empty.
    /// Handle errors inside the body so the queue can always be drained.
    func drain(_ body: (consuming VirtioElement) -> Void)
}

public struct VirtioElement: ~Copyable {
    public var readableByteCount: Int { get }
    public var writableByteCount: Int { get }
    public func copyReadable(maxBytes: Int) throws(VirtioFailure) -> [UInt8]   // one snapshot of guest data
    public func write(_ bytes: UnsafeRawBufferPointer) throws(VirtioFailure)
    public consuming func complete()                                           // returnToQueue, exactly once
    public consuming func deferCompletion() -> PendingElement                  // completion later (fenced commands)
}

public struct PendingElement: ~Copyable, Sendable {
    public consuming func complete()
}

public struct GuestMemory {
    public var byteCount: Int { get }
    public func copyBytes(at offset: Int, count: Int) throws(VirtioFailure) -> [UInt8]
    public func writeBytes(_ bytes: [UInt8], at offset: Int) throws(VirtioFailure)
    public func hostMemory() throws(VirtioFailure) -> UnsafeMutableRawBufferPointer   // for the renderer
}
```

`VirtioDeviceModel` lifecycle methods default to no-ops. Callbacks run on the per-device queue. `VirtioDeviceContext` is not `Sendable`, so queue, feature, and guest-memory calls cannot move into an asynchronous task. To update configuration from async work, obtain `configurationUpdater` on the device queue first. Updates are serialized per device and tied to the reset generation. A reset or release completes outstanding requests with `.notReady`. A context from an earlier generation fails with `.notReady` for queue, feature, guest-memory, and configuration calls, even after the device reaches DRIVER_OK again. A stale `requestReset` is ignored.

`PendingElement` is `Sendable`, so a renderer fence can carry it to another queue. Its completion always returns to the device queue. For an API that needs a copyable escaping closure, `PendingElement` moves its storage into a package-scoped, lock-protected one-shot `PendingElementCompletionToken`.

Design rules:

- **One serial device queue per device** (`.userInteractive`). VZ objects are touched only on it.
- **Keep VZ callback objects alive.** The VZ delegate references are weak, so the VM driver retains the adapter and model until release. Before release, the driver drains each device queue, stops the model, invalidates guest-backed state, and clears the weak delegate.
- **Copy, then validate.** Request bytes are copied once (`copyReadable`) before any field is validated. Validated values are never re-read from guest memory.
- **Drain without throwing.** The `drain` body handles each element's failure locally and completes it before the next iteration.
- **Exactly-once completion.** The non-copyable handles prevent a second completion at compile time. The token traps at runtime when completed twice. Dropping a live handle in a debug build returns the VZ element and then asserts. Reset or stop invalidates pending elements first, so dropping an invalidated handle does nothing.
- **Guest memory** mappings are cached per device and invalidated on reset or stop before the model's lifecycle callback. `GuestMemory` checks bounds on every access, and every length is checked for overflow (`gpa + len` must not wrap).
- **Features** are a `UInt64`. Only the VZ adapter splits them into `subset0` (bits 0–31) and `subset1` (bits 32–63).
- `FakeVirtioQueue` and `FakeGuestMemory` (`VirtioDeviceCoreTestSupport`) let device models run T0 tests without a VM.

### 3.3 Test entropy device

`EntropyTestDevice` (device ID 4, virtio-rng; PCI class `0x10`; one queue; no features) fills each writable buffer from a deterministic generator seeded by the test. It is used only in T2 tests.

On macOS 27.0, VZ reports a guest reboot as `WillReset` between the first and second `DRIVER_OK`, without `guestDidStop`. On the shutdown path, `WillReset` may precede `WillStop`. The adapter invalidates mappings before `WillStop` in any case. This is one OS build's behavior, not a guarantee.

## 4. virtio-gpu device

### 4.1 Identity and features

| Item | Value |
|---|---|
| Device ID | 16 |
| PCI class / subclass | 0x03 / 0x80 (as RiftVM; Linux binds on the virtio device ID, not the class) |
| Queues | 0 = controlq, 1 = cursorq |
| Offered features (profile `drmVirgl`) | `VIRTIO_GPU_F_VIRGL` (bit 0), `VIRTIO_GPU_F_EDID` (bit 1) |
| Offered features (profile `guestSwiftshader`, §9) | `VIRTIO_GPU_F_EDID` only |
| Not offered in v1 | `VIRTIO_GPU_F_RESOURCE_UUID` (2), `VIRTIO_GPU_F_RESOURCE_BLOB` (3), `VIRTIO_GPU_F_CONTEXT_INIT` (4). Vulkan track only (§10) |
| Config space (16 bytes, little-endian) | `events_read`, `events_clear`, `num_scanouts` = 16, `num_capsets` (2 with VirGL: `VIRGL`, `VIRGL2`; 0 otherwise) |
| Save/restore | `supportsSaveRestore = false` ([vm.md](vm.md) §9.5, R-07) |

`num_scanouts` is fixed at 16 (the virtio-gpu maximum), because the guest reads the config size once at probe. Unused scanouts report `enabled = 0`, and Linux shows their connectors as disconnected.

### 4.2 Commands

Wire structures and constants come from Linux `include/uapi/linux/virtio_gpu.h` (virtio 1.2, section 5.7). `VirtioGPUProtocol` defines them as fixed-layout Swift structs with explicit little-endian decoding. It never casts guest memory to struct pointers.

Every request starts with `virtio_gpu_ctrl_hdr` (24 bytes: `type`, `flags`, `fence_id`, `ctx_id`, `ring_idx`, padding). If `flags & VIRTIO_GPU_FLAG_FENCE` is set, the response is not returned before the fence completes, and it echoes the flag and `fence_id`.

| Command | Code | Handling |
|---|---|---|
| `GET_DISPLAY_INFO` | 0x0100 | 16 `pmodes` (rect, enabled, flags) from `ScanoutTable`; clears `events_read` (§4.3) |
| `RESOURCE_CREATE_2D` | 0x0101 | VirGL: `virgl_renderer_resource_create` (2D target). 2D profile: host-memory resource (§9) |
| `RESOURCE_UNREF` | 0x0102 | detach from scanouts, release backing, unref in the renderer |
| `SET_SCANOUT` | 0x0103 | bind resource and rect to a scanout; `resource_id = 0` disables it |
| `RESOURCE_FLUSH` | 0x0104 | present the flushed rect of every scanout bound to the resource (§6.2) |
| `TRANSFER_TO_HOST_2D` | 0x0105 | VirGL: `virgl_renderer_transfer_write_iov`. 2D profile: counted copy (§7) |
| `RESOURCE_ATTACH_BACKING` | 0x0106 | validate (≤ 16384 entries, each inside guest RAM), map, `virgl_renderer_resource_attach_iov` |
| `RESOURCE_DETACH_BACKING` | 0x0107 | detach iov, drop mappings |
| `GET_CAPSET_INFO` | 0x0108 | `virgl_renderer_get_cap_set` for `VIRGL` (1) and `VIRGL2` (2) |
| `GET_CAPSET` | 0x0109 | `virgl_renderer_fill_caps`. Versions 0 to the cached maximum get the cached capset; higher versions get `ERR_INVALID_PARAMETER` |
| `GET_EDID` | 0x010a | generated EDID for the scanout (§6.4) |
| `RESOURCE_ASSIGN_UUID`, `RESOURCE_CREATE_BLOB`, `SET_SCANOUT_BLOB` | 0x010b–0x010d | `ERR_UNSPEC` (features not offered) |
| `CTX_CREATE` / `CTX_DESTROY` | 0x0200 / 0x0201 | `virgl_renderer_context_create` / `_destroy` (≤ 256 contexts) |
| `CTX_ATTACH_RESOURCE` / `CTX_DETACH_RESOURCE` | 0x0202 / 0x0203 | renderer calls |
| `RESOURCE_CREATE_3D` | 0x0204 | `virgl_renderer_resource_create` with the requested target, format, bind, and size (§5.4) |
| `TRANSFER_TO_HOST_3D` / `TRANSFER_FROM_HOST_3D` | 0x0205 / 0x0206 | renderer transfers; `FROM_HOST` is a counted readback (§7) |
| `SUBMIT_3D` | 0x0207 | command stream copied (≤ 4 MiB), then `virgl_renderer_submit_cmd` |
| `RESOURCE_MAP_BLOB` / `RESOURCE_UNMAP_BLOB` | 0x0208 / 0x0209 | `ERR_UNSPEC` |
| `UPDATE_CURSOR` / `MOVE_CURSOR` (cursorq) | 0x0300 / 0x0301 | acknowledged; last values kept for diagnostics (§4.6) |

Responses: `OK_NODATA` (0x1100), `OK_DISPLAY_INFO` (0x1101), `OK_CAPSET_INFO` (0x1102), `OK_CAPSET` (0x1103), `OK_EDID` (0x1104). Errors: `ERR_UNSPEC` (0x1200), `ERR_OUT_OF_MEMORY` (0x1201), `ERR_INVALID_SCANOUT_ID` (0x1202), `ERR_INVALID_RESOURCE_ID` (0x1203), `ERR_INVALID_CONTEXT_ID` (0x1204), `ERR_INVALID_PARAMETER` (0x1205).

Guest errors never crash apkrund. A malformed request gets an error response and a rate-limited log line (`io.apkrun.graphics`, category `device`, at most 10 per second, with a counter for the rest). An element whose writable part is too small for a response header is completed with zero bytes written.

### 4.3 Display change events

The Linux driver learns of display changes this way: the device sets `VIRTIO_GPU_EVENT_DISPLAY` in `events_read` and raises a config-change interrupt. The driver reads `events_read`, sends `GET_EDID` and `GET_DISPLAY_INFO`, triggers a DRM hotplug event, and writes the handled bits to `events_clear`, which clears `events_read`.

VZ has no callback for config-space writes, so the device cannot see `events_clear`. The workaround ([ADR-0002](../01-architecture/decisions/0002-virtualization-framework-macos27.md)):

1. When RuntimeCore enables, disables, or changes a scanout's mode (§6.1), `ScanoutTable` increments `displayGeneration`, and GraphicsCore calls `updateConfigurationSpace` with `events_read = VIRTIO_GPU_EVENT_DISPLAY`.
2. When the device processes `GET_DISPLAY_INFO`, it records `reportedGeneration = displayGeneration`. If no newer change is pending, it writes `events_read = 0`.
3. If a change arrives after the response was built (`displayGeneration > reportedGeneration`), `events_read` is set again, and the guest does another round.

Open point R-01: whether `updateDeviceSpecificConfiguration` raises a config-change interrupt in the Android guest. The Linux test guest reacts to it. If Android does not, the fallbacks in order are:

- **A.** The Guest Agent forces a re-probe by writing `detect` to the connector's DRM sysfs `status` attribute, after asking the host which scanouts changed. This needs a privileged domain on the custom image, and the driver must re-read the display info.
- **B.** All pool scanouts are enabled at boot with a small placeholder mode, and the Guest Agent hides unused ones from app placement. This costs guest memory and composition work.
- **C.** A fixed display count (display 0 plus N configured at boot), chosen per boot. This is a product regression ([risks.md](../04-plan/risks.md) R-04).

### 4.4 Resources and backing

`ResourceTable` (device-queue confined) holds one `GPUResource` per guest resource ID:

```swift
struct GPUResource {
    let id: UInt32
    let kind: GPUResourceKind         // .virgl(target, format, bind, w, h, depth, arraySize, lastLevel, nrSamples, flags) | .host2D(format, w, h)
    var backing: [GuestMemory]        // from ATTACH_BACKING; empty until attached
    var scanouts: Set<ScanoutID>      // bound by SET_SCANOUT
    var byteEstimate: UInt64          // for the global memory limit
}
```

- Resource IDs are guest-chosen, non-zero, and unused. Reuse of a live ID returns `ERR_INVALID_RESOURCE_ID`.
- Sizes use checked arithmetic (`width × height × bpp` in `UInt64`) and stay within §5.4. Formats are limited to the virgl formats the renderer supports.
- `ATTACH_BACKING` maps every non-empty entry and keeps no partial state on failure. `.host2D` resources require backing for their full byte estimate. VirGL resources may attach fewer bytes because Mesa can use guest backing as transfer storage rather than a complete image; the renderer checks each submitted iovec access against the attached ranges. The byte estimate still enforces resource-count and host-memory limits.
- On `deviceWillReset` the table is cleared, mappings are dropped, the renderer is reset (all contexts destroyed), and scanout bindings are cleared. Pools and host scanout configuration (§6.1) survive, because they are host decisions.

On the VirGL path, `RESOURCE_ATTACH_BACKING` passes each range's host memory (`GuestMemory.hostMemory()`) to `gb_resource_attach_backing`, which calls `virgl_renderer_resource_attach_iov`. virglrenderer reads and writes the guest pages in place, and the bridge copies only the range array. The pages stay attached until `RESOURCE_DETACH_BACKING` or `RESOURCE_UNREF`, and they must stay mapped until then. Reset and stop do not detach. Before a reset or stop invalidates the mappings, `deviceWillInvalidateGuestMemory` drains the render thread. The renderer then drops its resources, and the bridge frees the range arrays without touching guest memory.

The 2D (`guestSwiftshader`) path keeps a host shadow buffer per 2D resource. `TRANSFER_TO_HOST_2D` copies into it and counts a CPU pixel copy. Explicit `TRANSFER_TO_HOST` counts its gathered bytes as `guestUploadBytes`. Buffers (`target` 0) are sized in bytes, so the 8192 limit applies to textures only. The byte estimate is the level-0 size times depth and layers, without mip levels.

### 4.5 Contexts, submissions, and fences

- Without `CONTEXT_INIT`, all fences are on one global timeline. Elements that wait for a fence are kept in one ordered queue (`ControlCompletionQueue`). Only the head completes, so no response overtakes an earlier fenced command.
- For a fenced command, the render thread calls `virgl_renderer_create_fence(fenceID, ctxID)` after it executes the command. The `write_fence` callback reports the highest completed fence. Every element with `fenceID ≤ completed` then completes in order.
- Fence progress needs `virgl_renderer_poll()`. On macOS, virglrenderer's thread-sync mode depends on Linux eventfd and is not available. The render thread polls after every batch and every 1 ms while fences are outstanding.
- Unfenced commands complete as soon as they execute.

### 4.6 Cursor queue

Android composes in client mode (`hwcomposer.mode=client`) and uses no hardware cursor plane. The host shows the macOS cursor, and pointer input is injected by the Guest Agent ([input.md](input.md)). `UPDATE_CURSOR` and `MOVE_CURSOR` get an OK response, and their last values are kept for diagnostics.

### 4.7 Threading

| Thread | Does | Never does |
|---|---|---|
| device queue (serial `DispatchQueue`) | VZ callbacks; drains queues; copies and validates requests; batches them into renderer commands; writes responses; completes elements | call virglrenderer, EGL, or Metal |
| render thread (one dedicated `Thread`, QoS `.userInteractive`) | owns the EGL display, all EGL contexts, and virglrenderer; executes commands in order; polls fences; performs present blits; creates GPU-completion fences | touch VZ objects |
| present waiter (serial queue `io.apkrun.graphics.present-waiter`) | waits for present blits and emits `frameReady`. Each fence poll runs on the render thread | make GL or EGL calls itself |

Commands flow from the device queue to the render thread in batches, one per queue drain. Each completed element calls `PendingElementCompletionToken.complete()`, and the return to the guest queue runs on the device queue. virglrenderer is not thread-safe, so renderer operations and its `write_fence` callback run on the render thread. Its log callback may arrive on another thread; only owner-thread callbacks are correlated with an active command, while off-thread errors and warnings are explicitly unattributed (§13.2). `TRANSFER_FROM_HOST_3D` runs on the device queue and waits for the render thread, because only the device queue writes guest memory. The render thread waits on an `NSCondition`, and it polls fences every millisecond only while one is outstanding.

---

## 5. Renderer (GraphicsBridge + VirGLRuntime)

### 5.1 Libraries

| Library | Revision (pin) | License | Role |
|---|---|---|---|
| virglrenderer | `960bd667` + APKRun patches | MIT | decodes VirGL command streams; manages GL objects |
| libepoxy | `1b6d7db` | MIT | GL/EGL function dispatch for virglrenderer |
| ANGLE | `2d91f554`, Metal backend only | BSD-3-Clause | EGL and GLES 3.0 on Metal |
| ANGLE DEPS | astc-encoder `2319d9c4`, vulkan-headers `c0fe12c8`, zlib `e00f7038` | Apache-2.0, Apache-2.0, Zlib | in the lock for their notices; equal to ANGLE's `DEPS` at the pinned commit |
| depot_tools | `f7083527` | BSD-3-Clause | build helper, run only in its own work area |
| PyYAML | `49790e73` (`6.0.3`) | MIT | locked tool for virglrenderer's Meson configuration |

- Pins, build flags, and patch lists live in `ThirdParty/ThirdParty.lock.json`. `scripts/build-third-party.sh virgl-runtime` builds the libraries from clean pinned sources with the listed patches ([build-system.md](../05-development/build-system.md) §6). It verifies every output: arm64 only, the macOS 27.0 minimum, `@rpath` install names, `@loader_path` runpaths, and bundled dependencies. A cache hit is reused only when the lock and environment identities match. A fresh checkout builds with no manual edits, and CI checks this.
- Outputs go to `ThirdParty/out/virgl-runtime/<lock hash>-<environment hash>/`, are embedded in `APKRun.app/Contents/Frameworks/VirGLRuntime/`, and are signed with the app. The ANGLE Metal build needs about 11 GB of dependencies.

Adopted patches (APKRun's initial set):

1. `virglrenderer/0001-add-macos-metal-support.patch`: the macOS Metal path of the pinned RiftVM recipe. It also contains Venus source changes, but APKRun sets `venus=false`. `0002-downgrade-unsupported-msaa.patch`: unsupported multisample resources fall back to single-sample storage, so rendering continues without antialiasing. Its code is RiftVM-authored (MIT) and ships in the runtime. `0003-link-metal-runtime.patch`: an APKRun addition that links CoreFoundation and the Objective-C runtime.
2. `libepoxy/0001-improve-library-detection.patch`: resolves the bundled ANGLE dylibs by `@rpath` and enables EGL on Apple platforms. `0002-disable-desktop-extensions-on-gles.patch`: GLES entry-point selection. `0003-enable-egl-platform-display.patch`: the EGL 1.5 client-version lookup for `eglGetPlatformDisplay`.
3. `angle/0001-fix-metal-boolean-mix.patch`: Metal `select` for boolean-selector `mix`, and the Metal shader UBO limit raised from 12 to 16. It omits the recipe's Vulkan hunk, which the Metal-only build does not compile.

Patches carry the license of the component they change ([legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.2). None of the carried patches records whether it was sent upstream, which that section requires. The RiftVM MIT notice covers RiftVM-authored source only.

Build flags. #21 passes the lock's `buildFlags` unchanged. They differ from RiftVM's reference flags in `mac_deployment_target`, `-Dglx=no`, `-Dplatforms=egl`, and `-Dvenus=false` (guest Vulkan is outside v1, §10). ANGLE and libepoxy reach Meson through generated pkg-config files. The full comparison is in [riftvm-analysis.md](riftvm-analysis.md) §4.

### 5.2 GraphicsBridge

`Packages/GraphicsCore/Sources/GraphicsBridge/` is a C target (with Objective-C for Metal). Swift calls only `include/GraphicsBridge.h`, never virglrenderer or EGL headers. The header is the source of the names below:

```c
typedef struct gb_renderer gb_renderer;
typedef struct { void (*write_fence)(void *user, uint32_t fence_id);
                 void (*log)(void *user, int level, const char *message); } gb_callbacks;

int  gb_renderer_create(const gb_callbacks *cb, void *user, gb_renderer **out);   // EGL (ANGLE Metal) + virgl_renderer_init
int  gb_renderer_destroy(gb_renderer *r);
int  gb_renderer_reset(gb_renderer *r);
int  gb_renderer_metal_device(gb_renderer *r, void **out);                       // ANGLE's MTLDevice
const char *gb_status_description(int status);

int  gb_capset_info(gb_renderer *r, uint32_t capset_id, uint32_t *max_version, uint32_t *max_size_bytes);
int  gb_capset_fill(gb_renderer *r, uint32_t capset_id, uint32_t version, void *out, size_t out_size_bytes);
int  gb_ctx_create(gb_renderer *r, uint32_t ctx_id, const char *name);
int  gb_ctx_destroy(gb_renderer *r, uint32_t ctx_id);
int  gb_ctx_attach_resource(gb_renderer *r, uint32_t ctx_id, uint32_t res_id);
void gb_ctx_detach_resource(gb_renderer *r, uint32_t ctx_id, uint32_t res_id);
int  gb_submit(gb_renderer *r, uint32_t ctx_id, const void *commands, size_t size_bytes);
int  gb_submit_with_result(gb_renderer *r, uint32_t ctx_id, const void *commands,
                           size_t size_bytes, int *virgl_result);                // test-only replay

int  gb_resource_create(gb_renderer *r, const gb_resource_args *args);
void gb_resource_unref(gb_renderer *r, uint32_t res_id);
int  gb_resource_attach_backing(gb_renderer *r, uint32_t res_id, const gb_backing_range *ranges, size_t count);
void gb_resource_detach_backing(gb_renderer *r, uint32_t res_id);
int  gb_transfer_write(gb_renderer *r, const gb_transfer_args *args, void *buffer, size_t buffer_bytes);  // TO_HOST
int  gb_transfer_read(gb_renderer *r, const gb_transfer_args *args, void *buffer, size_t buffer_bytes);   // FROM_HOST

int  gb_create_fence(gb_renderer *r, uint32_t fence_id, uint32_t ctx_id);
void gb_poll(gb_renderer *r);

int  gb_present_target_create(gb_renderer *r, void *iosurface, uint32_t width, uint32_t height, gb_present_target **out);
void gb_present_target_destroy(gb_renderer *r, gb_present_target *target);
int  gb_present_blit(gb_renderer *r, uint32_t res_id, uint32_t x, uint32_t y, uint32_t width, uint32_t height,
                     gb_present_target *target, void **out_sync);
int  gb_sync_wait(gb_renderer *r, void *sync, uint64_t timeout_ns);             // GB_OK, GB_SYNC_TIMEOUT, or error
void gb_sync_destroy(gb_renderer *r, void *sync);
```

Status values are `GB_OK = 0` and negative `GB_E_*` codes. `GB_E_WRONG_THREAD` is returned for a call from another thread. `GB_E_RENDERER_ALREADY_EXISTS` refuses a second renderer. `GB_E_BUFFER_TOO_SMALL` refuses an undersized capset buffer. `GB_SYNC_TIMEOUT` (1) means the fence has not signaled.

Implementation notes:

- **EGL.** `eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, …, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE)`, `eglInitialize`, `EGL_OPENGL_ES_API`, a 1 × 1 pbuffer config with GLES 2/3 and 8-bit RGBA, and a root GLES context. `virgl_renderer_init` uses callback version 4 and **flags `0`**, and passes neither `VIRGL_RENDERER_USE_EGL` nor `VIRGL_RENDERER_USE_SURFACELESS`.
- **Loading.** The four dylibs load from `Contents/Frameworks/VirGLRuntime` only for an app whose `CFBundleIdentifier` and `APKRunBuildIdentity` (Info.plist) match one of: `io.apkrun.APKRun`/`release`, `io.apkrun.APKRun.updatetest`/`updatetest`, or (Debug) `io.apkrun.APKRun.dev`/`dev`. A runtime directory or library symlink that resolves outside the bundle is rejected. Debug builds may override the directory with `APKRUN_VIRGL_RUNTIME_PATH`, and otherwise use `ThirdParty/out/virgl-runtime/current`.
- **One renderer per process.** Creation records the owner thread. A call from another thread returns `GB_E_WRONG_THREAD` without changing state. Callers finish all in-flight calls, including rejected ones, before `gb_renderer_destroy`. A handle is invalid after a successful destroy. Renderer operations and the `write_fence` callback run on the owner thread. The log callback may arrive on another thread; its error and warning records are explicitly unattributed (§13.2).
- **Reset.** `gb_renderer_reset` invalidates guest-derived IDs. Callers discard them.
- **Contexts.** Every context shares the root context's GL objects, because virglrenderer's context 0 is unshared.
- **Present targets.** Targets are BGRA8 textures on **ANGLE's `MTLDevice`** (queried with `EGL_ANGLE_device_metal`), backed by the IOSurface. This avoids cross-device copies on multi-GPU Macs. Each target is imported once into GL as a framebuffer's color attachment on the root context.
- **Blit.** `gb_present_blit` takes the scanout resource's GL texture (`virgl_renderer_borrow_texture_for_scanout`) and copies the rect with `glBlitFramebuffer` and `GL_NEAREST`, scaling to the target. The copy keeps the guest's row order: no vertical flip. It then calls `glFlush` and creates an EGL fence. No pixels are mapped into host memory.
- **Fence waits.** ANGLE rejects a wait with no current context, so `gb_sync_wait` makes the root context current, waits, and restores the caller's context.

### 5.3 What the guest gets

- GLES 3.0 through Mesa virgl (`ro.opengles.version=196608`). The guest has no Vulkan (`ro.cpuvulkan.version=0`). The bootconfig keys are in [android-image.md](android-image.md) §6.2.
- The guest userspace (EGL, GLES, and the `virgl` gallium driver) is Mesa 26.1.8, built with NDK r28c outside the AOSP tree by `scripts/guest/build-mesa-android.sh` ([ADR-0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md)). `python3 -m apkrun_image inject-vendor` adds the Mesa libraries to `vendor_a` offline ([android-image.md](android-image.md) §1.2). The inject step does not re-sign the top-level vbmeta that covers `vendor_a`.
- The GL renderer string seen by apps contains `virgl`.
- ANGLE-imposed limits show up as GLES 3.0 capability limits. Apps that require GLES 3.1 or Vulkan run at a lower compatibility level ([scope.md](../00-product/scope.md) §4).

### 5.4 Limits

`ResourceTable` enforces these before it calls the renderer. Values are configurable in development builds only (`graphics.limits.*`, [configuration.md](../03-reference/configuration.md)).

| Limit | Value | Error |
|---|---|---|
| Total resource memory (estimate) | 2 GiB | `ERR_OUT_OF_MEMORY` |
| Single resource or buffer | 256 MiB | `ERR_OUT_OF_MEMORY` |
| Width or height | ≤ 8192 px | `ERR_INVALID_PARAMETER` |
| Contexts | ≤ 256 | `ERR_UNSPEC` |
| Live resources | ≤ 65536 | `ERR_OUT_OF_MEMORY` |
| Backing entries per attach | ≤ 16384 | `ERR_INVALID_PARAMETER` |
| `SUBMIT_3D` size | ≤ 4 MiB | `ERR_INVALID_PARAMETER` |

Also enforced: `lastLevel` ≤ 13; sample count ≤ 16; a transfer extent of at most one resource's 256 MiB; at most 4 Mi row runs per transfer; a nonzero stride holds at least one row. Formats are an allow-list of virgl formats with a known size: uncompressed and 4 × 4 block-compressed. Any other format gets `ERR_INVALID_PARAMETER`.

Reaching a memory limit is logged with the current totals, and the `graphics.memory` health value turns yellow ([diagnostics.md](diagnostics.md)).

---

## 6. Scanouts and presentation

### 6.1 ScanoutTable and host control

The host decides which scanouts exist and what mode they offer. The guest decides what it shows on them.

```swift
public struct ScanoutID: Hashable, Sendable { public let rawValue: Int }   // 0...15

public struct DisplayMode: Equatable, Sendable {
    public var widthPixels: Int                    // ≤ 4095 while EDID uses a detailed timing descriptor (§6.4)
    public var heightPixels: Int
    public var refreshHz: Int                      // 60
    public var dotsPerInch: Int                    // encoded as physical size in the EDID
}

public protocol ScanoutController: Sendable {
    func configure(_ scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure)  // enable; display event (§4.3)
    func disable(_ scanout: ScanoutID)                                              // disable; display event
    func attach(_ scanout: ScanoutID, width: Int, height: Int) throws(GraphicsFailure) -> ScanoutPoolHandle
    func reconfigure(_ scanout: ScanoutID, mode: DisplayMode, width: Int, height: Int)
        throws(GraphicsFailure) -> ScanoutPoolHandle                                // new pool after a mode change
    func detachPool(_ scanout: ScanoutID, generation: UInt64?)                     // a generation mismatch leaves the newer pool
}

public struct ScanoutPoolHandle: Sendable {
    public let generation: UInt64
    public let surfaces: [IOSurface]               // in buffer order
    public let frames: AsyncStream<ScanoutFrame>
    public func frameDisplayed(sequence: UInt64)   // the consumer's acknowledgement (§6.3)
}

public enum ScanoutFrame: Equatable, Sendable {
    case frameReady(generation: UInt64, bufferIndex: Int, sequence: UInt64)
}
```

`ScanoutTable` holds 16 `ScanoutState` values (`isEnabled`, `mode`) and `displayGeneration`. `VirtioGPUScanoutController(device:)` is the production implementation.

- Scanout 0 is enabled when the device is created, with the image's default display mode, so Android has its primary display from the first boot. The mode comes from `lcd_density` and the reference capture ([android-image.md](android-image.md) §6.2).
- `DisplayPool` (RuntimeCore) calls `configure` and `disable` for scanouts 1…15. It maps scanouts to Android display IDs after the Guest Agent reports `DisplayAdded` ([display-and-windowing.md](display-and-windowing.md), [state-machines.md](../01-architecture/state-machines.md) §4).
- A scanout with no attached pool still accepts `SET_SCANOUT` and `RESOURCE_FLUSH`, and the flush completes without a blit. A hidden display 0 therefore costs nothing on the host in `secondaryDisplay` mode ([ADR-0005](../01-architecture/decisions/0005-multi-display-window-model.md)).

### 6.2 Present on `RESOURCE_FLUSH`

For each scanout bound to the flushed resource that has a pool attached:

1. **Pick a buffer.** `acquire()` returns a free buffer index. If none is free, the present waits as the scanout's single pending present, and runs when a buffer frees. A newer flush replaces a pending present, and the replaced frame counts as dropped (latest frame wins). An offered or displayed buffer is never overwritten ([display-and-windowing.md](display-and-windowing.md) §5.2 rule 1). At most one blit per scanout is in flight.
2. **Blit.** On the render thread, `gb_present_blit` copies the scanout rect from `SET_SCANOUT` into the target. If the resource size differs from the pool size during a resize, the blit scales to the pool size and logs once per mode change.
3. **Complete the guest's flush.** The flush response is sent after the blit is flushed to the GPU queue, not after execution or display. A replaced pending present completes its flush when it is replaced. A flush on a scanout that is not presenting completes at once. The guest HWC paces itself with its own vsync, so the host adds no back-pressure. The order of the blit against later guest rendering relies on ANGLE's Metal backend using one command queue per display.
4. **GPU completion.** The blit's fence is polled on the render thread, with the root context current, once per 1 ms. Each 100 ms without a signal is a stall: it is counted and logged, and the wait goes on. When the fence signals, the buffer is offered and `frameReady(generation, bufferIndex, sequence)` is emitted. The IOSurface content is complete before any consumer sees the index. A failed blit is counted (`failedBlits`), and its buffer is freed without an offer.

Guest scanout resources are 32-bit (`B8G8R8X8`, `B8G8R8A8`, or `R8G8B8A8`). Pool buffers are `BGRA8Unorm` in sRGB. The blit converts the format, and X formats are forced opaque.

### 6.3 SurfacePool

`SurfacePool` (internal to GraphicsCore, `Display/SurfacePool.swift`) holds three buffers (`bufferCount = 3`):

- IOSurfaces are `BGRA`, with bytes per row aligned to 64 (`IOSurfaceAlignProperty`), and are not global (`kIOSurfaceIsGlobal` is unset). A wrapper receives them only through an XPC handle.
- The Metal texture of each surface is created once on ANGLE's device and imported into EGL once.
- `generation` increases on every reallocation. A resize allocates a new pool. The old pool is released when the consumer acknowledges `surfacesReplaced`, or after 1 s.
- Buffer states (`PresentBufferState`): `free → rendering → offered(sequence) → displayed(sequence) → free`. `markReady` moves a buffer to `offered`, and `consumerDisplayed(upTo:)` moves it to `displayed`. The rules for when the wrapper may hold a buffer are in [display-and-windowing.md](display-and-windowing.md) §5.2. The wrapper only sends `frameDisplayed`.
- Memory: 3 × width × height × 4 bytes per displayed scanout (1440 × 3120 is about 54 MiB). It is reported in the frame statistics and in `apkrun info --runtime`.

### 6.4 EDID

`EDIDGenerator` produces a 128-byte EDID 1.4 base block per scanout:

- Manufacturer `APK`. The product code and serial are the scanout index. The name descriptor is `APKRun <index>`.
- One detailed timing descriptor for the preferred mode (CVT reduced blanking). Its active fields are 12 bits wide, so each dimension is at most 4095 px. [display-and-windowing.md](display-and-windowing.md) keeps modes within that limit by rendering at a lower scale. A DisplayID extension for larger modes is post-v1.
- Physical size in mm, from `dotsPerInch`. Android derives the per-display DPI from it through the HWC. The effect on secondary displays is OQ-39 (§15).
- A range-limits descriptor: 24–120 Hz vertical, 20–255 kHz horizontal, 660 MHz maximum pixel clock; then the checksum. The 20 kHz lower bound admits the 240 × 300 px mode, so short modes get extra vertical blanking. The timing generator still rejects 1024 × 768 at 24 Hz. This adjustment is APKRun's, on top of CVT reduced blanking. Unit tests compare golden EDIDs with a reference decoder.
- The geometry resolver checks the resulting timing against the pixel-clock and horizontal-frequency range. If 60 Hz does not fit, it lowers `renderScale` to the largest expressible mode.

### 6.5 Development window

The development window (`apkrun dev boot --gpu virgl --window`) shows display 0 in an `NSWindow`. It uses WindowingCore's IOSurface layer in-process, the same code the wrapper uses later.

The development window (#24) is **fixed-size**: display 0 keeps the image's default mode, and the window scales the layer with aspect fit. Runtime mode changes and pool reallocation belong to #68 (§6.1, §6.4).

---

## 7. Frame statistics and counters

Metrics are recorded per scanout and globally. They are exposed through the presenter and device statistics and through the diagnostics snapshot. The code names are `PresentStatistics` (per presenter: `framesPresented`, `droppedFrames`, `presentStalls`, `failedBlits`) and `GraphicsCounters` (per device: `hostReadbacks`, `guestReadbacks`, `guestReadbackBytes`, `guestUploadBytes`, `cpuPixelCopies`, `cpuPixelCopyBytes`, `rendererFailures`).

| Metric | Definition | Measured in |
|---|---|---|
| `fps` | `frameReady` events per second (1 s window, 10 s average) | present waiter |
| `guestFlushRate` | `RESOURCE_FLUSH` per second; above `fps` means frames were dropped or coalesced | device queue |
| `flushToReady` | host time from flush decode to `frameReady` (p50/p95) | device queue + waiter |
| `readyToDisplayed` | `frameReady` to the wrapper's `frameDisplayed` (p50/p95) | RuntimeCore → GraphicsCore |
| `presentGPUTime` | EGL sync wait duration (upper bound of the blit's GPU time) | present waiter |
| `droppedFrames` | frames replaced before display | scheduler |
| `hostReadbacks` | GPU→CPU pixel reads the host makes on its own initiative. **Must stay 0 on the normal path** (NFR-PERF-05) | device |
| `guestReadbacks` | `TRANSFER_FROM_HOST_3D` count and bytes (app-requested, for example `glReadPixels`) | device queue |
| `rendererFailures` | renderer work that failed after construction: commands, fences, reset, destroy | render thread |
| `cpuPixelCopies` | CPU copies of pixel data on the present path. Only the 2D profile may make them; it must be 0 in `drmVirgl` | 2D renderer |
| `resourceMemory`, `contexts`, `resources` | current totals and high-water marks | `ResourceTable` |
| `apkrundCPU` | process CPU time (`task_info`), sampled each second | DiagnosticsCore |
| `gpuUtilization` | best effort: IOKit accelerator "Device Utilization %" (OQ-07) | DiagnosticsCore |

The test-only readback, compiled only with `APKRUN_TEST_READBACK` (the `TestReadback` trait in tests), reads pixels for the replay and tearing tests. It is not counted, and it never runs on the normal path.

The product has no host readback code, so nothing increments `hostReadbacks` today, and a zero in a gate run proves nothing by itself. The guarantee is structural: `scripts/check-readback.sh` (lint) fails when product sources call a pixel or resource read (`gb_transfer_read`, `transferRead`, `IOSurfaceLock`, `glReadPixels`, `getBytes`, `CVPixelBufferLockBaseAddress`) outside an `#if APKRUN_TEST_READBACK` block, except on the guest `TRANSFER_FROM_HOST_3D` path that `guestReadbacks` counts. A host-side read needs a design change first; if it is accepted, it increments `hostReadbacks` and gets an entry with its reason in the check's allowlist.

Signposts (`io.apkrun.graphics`, category `present`): an interval `gpu.flush` (decode to completion) and an interval `gpu.present` (blit to `frameReady`). RuntimeCore emits the `FIRST_FRAME` perf marker on the first `frameReady` of a session's scanout ([diagnostics.md](diagnostics.md) §4).

---

## 8. Lifecycle

| Event | GraphicsCore action |
|---|---|
| VM configuration | `VirtioGPUDevice` is created with a profile (§9). The render thread starts, and `gb_renderer_create` runs **before the VM starts**. An EGL or ANGLE failure is reported as `GraphicsFailure.rendererInitFailed` before Android boots |
| DRIVER_OK (`deviceDidStart`) | queues become available. Config space already holds `num_scanouts` and `num_capsets` |
| `WillPause` | stop blits. Flushes still complete, but pools receive no new frames. In-flight blits finish. Statistics timers pause. The renderer and resources stay |
| `WillResume` | resume blits. The next guest flush produces a frame. If no flush arrives within 100 ms, the last presented buffer stays on screen |
| `WillReset` (guest reboot or reset) | complete or abandon deferred elements (VZ discards abandoned ones on reset), clear `ResourceTable`, drop mappings, `gb_renderer_reset`, clear scanout bindings, emit `.deviceReset`. Host scanout configuration and pools are kept |
| `WillStop` | as reset, then destroy the renderer, stop the render thread, and release pools |
| Save/restore | unsupported (`supportsSaveRestore = false`). VM save and restore are unavailable while this device is attached (R-07, [vm.md](vm.md) §9.5) |

Pause and resume follow RuntimeCore's idle policy ([runtime-daemon.md](runtime-daemon.md) §5). While paused, the wrapper keeps showing the last frame.

Failure policy:

- An EGL or GL error in a guest context is logged, and the command returns `ERR_UNSPEC`.
- `GraphicsFailure.rendererLost` (context loss, or the Metal device is removed) means all resources are gone. GraphicsCore emits it, and RuntimeCore restarts Android (VM stop and start) with a diagnostics snapshot. `requestReset` is not used for recovery, because the Linux `virtio_gpu` driver does not recover from DEVICE_NEEDS_RESET.
- virglrenderer runs inside apkrund, so a crash there takes down apkrund and the VM. launchd restarts apkrund (NFR-REL-02). The renderer cannot move out of process in v1, because guest memory mappings exist only in the process that owns the VM (§11).

## 9. GPU profiles and the software fallback

| Profile | Device features | Guest configuration | Host renderer | Use |
|---|---|---|---|---|
| `drmVirgl` (default) | VIRGL + EDID | the bootconfig of `gpuProfiles.drmVirgl` in the layout (§9.1, §9.2) | virglrenderer + ANGLE | product path |
| `guestSwiftshader` | EDID only | Cuttlefish's `guest_swiftshader` set ([android-image.md](android-image.md) §8.2) | 2D renderer: 2D resources are copied from guest backing into the pool buffer on flush (`cpuPixelCopies` > 0) | debugging, bring-up, Graphics Safe Mode |
| `headless` (development only) | no GraphicsCore device; VZ's own 2D device (one 720 × 1280 scanout) provides the DRM device | the launcher capture's `guest_swiftshader` set ([android-image.md](android-image.md) §9.1) | none | bring-up (`apkrun dev boot --gpu none`). Never in a release bundle |

- The profile is chosen per boot: `BootOptions.gpuProfile` (`GPUProfileID`; [android-image.md](android-image.md) §9.1). A change restarts Android, because the bootconfig changes.
- RuntimeCore attaches `VirtioGPUDevice` for `guestSwiftshader`, `VirtioGPUDevice.virgl()` for `drmVirgl`, and no device for `headless`. The device must offer every entry of the profile's `requiredHostCapabilities` ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.7). A profile the bundle does not list starts no renderer, and a device that lacks a required feature is refused. Both refusals happen before the VM starts, with `runtime.gpuProfileUnavailable`. A renderer that fails to start ends the boot as `runtime.graphics`, with the `GraphicsFailure` (§13.1) as its cause.
- `graphics.safeMode` is the user-facing fallback (off by default, [configuration.md](../03-reference/configuration.md)). It appears in Settings → Troubleshooting, and `apkrun doctor` suggests it after repeated `rendererInitFailed` or `rendererLost`. The UI says that it is a slow fallback.
- There is no automatic fallback in v1. A silent fallback would hide regressions.
- The 2D renderer uses a plain Metal path (`replaceRegion` into the pool texture from the mapped guest backing). It is the only place where `cpuPixelCopies` may be non-zero.
- `VZVirtioGraphicsDeviceConfiguration` (one scanout) is not used for `drmVirgl` or `guestSwiftshader`, because it cannot provide multiple scanouts ([ADR-0002](../01-architecture/decisions/0002-virtualization-framework-macos27.md)). It serves only `headless`. A profile with no DRM device cannot boot the stock image: zygote and SurfaceFlinger abort without an EGL implementation, and `init.cutf_cvm.rc` waits for `/dev/dri/card0` in `early-init`.

### 9.1 drmVirgl components

Each component names the file that decides it. A value not listed here is not claimed.

- **Mesa (guest EGL, GLES, gallium).** `androidboot.hardware.egl=mesa`. The source of truth is the `mesa` and `ndk` entries of group `guest-mesa` in [ThirdParty.lock.json](../../ThirdParty/ThirdParty.lock.json): Mesa 26.1.8 at commit `0fadfea4`, with that entry's flags (among them `-Dgallium-drivers=virgl`, `-Dplatforms=android`, `-Degl-lib-suffix=_mesa`, `-Dgles-lib-suffix=_mesa`), and NDK r28c (`28.2.13676358`). `scripts/guest/build-mesa-android.sh` ships `libEGL_mesa.so`, `libGLESv2_mesa.so`, `libGLESv1_CM_mesa.so`, and `libgallium_dri.so` (`SHIPPED` in `scripts/guest/mesa_android.py`). `python3 -m apkrun_image inject-vendor --mesa <dir>` installs them in `/vendor/lib64/egl/` of `vendor_a` (`MESA_LIBRARIES`, `MESA_TARGET_DIRECTORY` in `Images/tools/apkrun_image/vendor_inject.py`). The build stages them as `vendor/lib64/<name>`. The stock image has no Mesa library: its `/vendor/lib64/egl/` holds the `_emulation` libraries. The `alpine-mesa*` entries of group `test-linux` are the Linux test guest's Mesa.
- **VirGL.** The host renderer is `virglrenderer` (`960bd667`), `libepoxy` (`1b6d7db`), and `angle` (`2d91f554`, Metal) of group `virgl-runtime` (§5.1). The guest driver is Mesa's `virgl` gallium driver in `libgallium_dri.so`. The device offers `VIRTIO_GPU_F_VIRGL` and `VIRTIO_GPU_F_EDID` (§4.1).
- **gralloc.** `androidboot.hardware.gralloc=minigbm`. Mesa does not build GBM (`-Dgbm=disabled`, [ADR-0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md)). The image's minigbm comes from the APEX `com.google.cf.gralloc.apex` in `vendor_a`, and its allocator `android.hardware.graphics.allocator-service.minigbm` starts at boot.
- **HWC.** `androidboot.hardware.hwcomposer=ranchu`, `androidboot.hardware.hwcomposer.mode=client`, and the composer APEX key `com.android.hardware.graphics.composer.ranchu`. The stock image also has `com.android.hardware.graphics.composer.drm_hwcomposer.apex`. How init treats it is not verified.
- **DRM path.** `androidboot.hardware.hwcomposer.display_finder_mode=drm`. The device is virtio-gpu (device ID 16, §4.1), bound by `virtio_gpu`, with the primary node `/dev/dri/card0`, which init waits for.

### 9.2 Source of truth

`gpuProfiles.drmVirgl.bootconfig` in [cuttlefish-phone-arm64.json](../../Images/tools/layouts/cuttlefish-phone-arm64.json) is the source of the eight keys in §9.1. Seven of them come from Cuttlefish revision `9bb9c72` (`crosvm_manager.cpp`). The composer key comes from the stock launcher capture, which is not committed, so the repository cannot check that value. The layout's `gpuProfilesComment` explains the composer key and why `display_framebuffer_format` is omitted.

The boot bootconfig merges five layers: vendor, image, GPU profile, platform, and instance. The bundle writes the first two to `boot/bootconfig.txt` and the profile to `gpuProfiles` in `manifest.json` (`Images/tools/apkrun_image/bundle.py`). `AndroidBootPlanner.prepareBoot` (ImageCore) merges all five. `merge_bootconfig_layers` in `Images/tools/apkrun_image/bootconfig.py` applies the same rules in Python. The offline golden test covers the first three layers (§14).

The `drmVirgl` values differ from the `guestSwiftshader` set in `androidboot.cpuvulkan.version`, `androidboot.hardware.egl`, and `androidboot.opengles.version`.

---

## 10. Vulkan track (post-v1)

Vulkan is not a v1 blocker. Venus (Vulkan over virtio-gpu) and native contexts need `VIRTIO_GPU_F_RESOURCE_BLOB` and `VIRTIO_GPU_F_CONTEXT_INIT`, plus a host-visible shared memory region. On macOS 27 that is a `VZVirtioSharedMemoryRegionConfiguration` (region ID 1) and `VZVirtioSharedMemoryRegion.mapMemory(_:atOffset:size:)`, which is page-aligned and completes on the device queue.

- The host side would be virglrenderer's venus backend on MoltenVK, or gfxstream.
- The guest needs a Venus-capable Mesa build and the matching bootconfig (`vulkan` APEX selection, [android-image.md](android-image.md) §6.2). That means a custom image.
- `CONTEXT_INIT` also brings per-context fence timelines (`ring_idx`). They would lift the in-order fence limit of §4.5.
- Unknown: `maximumAllowedSharedMemoryRegionCount` (it must be ≥ 1), and whether IOSurface- or Metal-heap-backed memory can be mapped into the region. The first Vulkan spike checks both.

---

## 11. Security considerations

The guest is untrusted from the host's point of view ([security-model.md](../01-architecture/security-model.md)). The virtio-gpu device and virglrenderer parse guest-controlled data in apkrund, which holds the virtualization entitlement and the user's files.

- Every guest value is validated after it is copied (§3.2), with checked arithmetic. There are no struct casts over guest memory.
- The limits of §5.4 bound memory use.
- virglrenderer's command decoder is the largest attack surface. It is pinned, its patches are listed in the lock, and upstream security fixes are tracked ([build-system.md](../05-development/build-system.md) §6).
- Fuzzing (#92): a libFuzzer target over `VirtioGPUProtocol` decoding and `ResourceTable` (T1, in CI), and a virgl command-stream fuzzer that runs the renderer in a separate test process.
- A renderer crash takes down apkrund (§8). Moving the renderer to a separate process is post-v1 research. It would need guest memory sharing across processes, which VZ does not offer.

---

## 13. Errors and logging

### 13.1 `GraphicsFailure` (error domain `graphics`)

| Case | Meaning | Remediation shown |
|---|---|---|
| `rendererInitFailed(stage, detail)` | EGL, ANGLE, or virglrenderer initialization failed (`stage`: `egl`, `metal`, `virgl`) | update macOS or APKRun; try Graphics Safe Mode; attach diagnostics |
| `rendererOperationFailed(operation, detail)` | a renderer operation failed (capset, resource, context, submit, transfer, fence, presentation, reset, teardown), or a call came from the wrong thread | restart Android; attach diagnostics if it continues |
| `rendererLost(reason)` | context loss or GPU removal | Android restarts automatically |
| `libraryMissing(name)` | VirGLRuntime dylib missing or its signature invalid | reinstall APKRun |
| `scanoutInvalid(ScanoutID)` | host requested a scanout outside 0…15 | bug report |
| `modeUnsupported(DisplayMode)` | mode exceeds EDID or limit constraints | bug report (DisplayPool should have clamped) |
| `poolAllocationFailed(PixelSize)` | IOSurface or Metal texture creation failed | close other apps; attach diagnostics |
| `configUpdateFailed(detail)` | `updateConfigurationSpace` failed | Android display changes may not apply; restart Android |
| `deviceNotReady` | a host request arrived before DRIVER_OK | DisplayPool retries after the scanout is configured or the boot completes |
| `deviceSetupFailed` | health finding `graphics.device` (never thrown): device missing or feature negotiation failed | start in Graphics Safe Mode; attach diagnostics |
| `softwareRendering` | health finding `graphics.guestDriver` (never thrown): Android fell back to software rendering | restart Android; attach diagnostics |
| `presentationSlowPath` | health finding `graphics.present` (never thrown): a readback or CPU copy counter is non-zero (§7) | bug report |
| `memoryLimitReached` | health finding `graphics.memory` (never thrown): a memory limit was reached (§5.4) | close some Android app windows |
| `safeModeOn` | health finding `graphics.safeMode` (never thrown): the `guestSwiftshader` profile is in use (§9) | turn it off in Settings → Troubleshooting |

Guest-caused errors are virtio-gpu error responses, not `GraphicsFailure` values (§4.2). The catalog with codes is in [error-catalog.md](../03-reference/error-catalog.md).

### 13.2 Logging

Subsystem `io.apkrun.graphics`, with categories `device` (negotiation, commands, guest errors), `renderer` (virglrenderer and ANGLE log callback, context lifecycle), `present` (pools, frames, stalls), and `stats` (a summary every 60 s while any scanout presents). Each control-queue element receives a monotonically increasing `control_ordinal` for the lifetime of the device, including across guest resets. A decoded command's debug record includes the ordinal, command code, context ID, and any resource ID in the request. `SUBMIT_3D` carries a command stream rather than a resource ID, so its record uses `resource_id=unattributed`; do not infer a resource from command bytes. Renderer operation failures and rejected guest requests reuse those fields, so resource creation, backing, detach, context, and submit events can be read in device-queue order. A rejected `RESOURCE_ATTACH_BACKING` also includes a fixed `rejection_reason` label for the failed resource-table check or guest-memory mapping; it includes no guest address, length, or contents. Renderer callback errors and warnings raised synchronously on the renderer owner thread during that work emit a separate correlation record with the same identifiers and severity; that record does not include callback text. An error or warning callback delivered on another thread emits a correlation record whose command, context, and resource identifiers are all `unattributed`; it never inherits an active command scope. Correlation records include no guest memory addresses or command bytes. Per-command logging is at debug level only and is off in release builds.

---

## 14. Tests

- **T0, `VirtioDeviceCore`** (`Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTests/`): drain loop; deferred completion through async and token hops; duplicate token completion and forgotten handles (exit tests); bounds, overflow, and feature split.
- **T0, `GraphicsCore`** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`): `VirtioGPUProtocol` decode and encode for every command, including truncated and oversized input, with golden vectors from Linux traces (`Tests/Fixtures/graphics/virtio-gpu-vectors.json`); `ResourceTable` limits, overflow, full `.host2D` backing, smaller VirGL backing, and reset; display events (§4.3); EDID golden files; the latest-frame scheduler and `SurfacePool` state machine.
- **T1, GraphicsBridge** (`Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/GraphicsRendererSystemTests.swift`): renderer create and destroy, capsets, and contexts on a Metal device. **T1, present** (`ScanoutPresentRendererTests`): a flush of the real VirGL renderer presents the guest pixels in order, pixel-exact, with no readback.
- **T1, replay** (`VirGLRoundTripSystemTests.swift`): the synthetic fixture `Tests/Fixtures/graphics/synthetic-virgl-session.json` replays through the renderer, and its scanout hash must match exactly through the test-only readback. `undersizedVirGLBackingSupportsAnInBoundsCopyTransfer` exercises a synthetic bounded copy from a 4 KiB backing attached to a 64 × 64 texture through virtio-gpu device processing with a fake queue and the real renderer. The optional `kmscube` recording replays every operation with no renderer failure and no rejected submit. It makes no pixel claim. These tests need Metal.
- **T1, fuzzing:** protocol decoding and `ResourceTable`, time-boxed in CI (#92).
- **T2, Linux test guest** (`Tests/IntegrationTests/LinuxGuestTests/`): `EntropyDeviceTests` (`virtio_rng.0` listed in `/sys/class/misc/hw_random/rng_available`; 64 KiB from `/dev/hwrng` matches the seeded sequence; a second read works after reset; a live mapping and a stale context are rejected after reset and stop); `GPUDeviceTests` (probe, EDID, hotplug); `VirglTests` (`kmscube` headless with `rendererFailures = 0` after shutdown, then in a window).
- **T2, Android** (`Tests/IntegrationTests/AndroidGraphicsTests/`): `virtio_gpu` binding, VirGL SurfaceFlinger, and `boot_completed` with `drmVirgl` and with `guestSwiftshader`.
- **RuntimeCore:** `AndroidGraphicsDevicesTests` (T0) and `AndroidGraphicsDevicesRendererTests` (T1, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`): `drmVirgl` attaches one device with `edid` and `virgl`; an unlisted profile starts no renderer.
- **Offline bootconfig:** `test_the_drm_virgl_bootconfig_follows_from_the_committed_layout` in `Images/tools/tests/test_bundle.py` (`-k drm_virgl`).
- **T3, gate G3** (`Tests/AcceptanceTests/G3GraphicsTests/`, `scripts/run-gate.sh G3`): HelloGL visible, at least 55 fps, zero host readbacks, no tearing.

## 15. Open items

- R-01: the Android guest's reaction to a configuration update, which decides whether §4.3 fallback A, B, or C applies.
- R-04: multi-scanout with the ranchu HWC (runtime hotplug and mode changes that keep the display ID). Fallbacks: §4.3 C, and the resize fallbacks of [display-and-windowing.md](display-and-windowing.md) §7.1.
- R-04: no scanout event stream exists in the code yet. The design names `ScanoutEvent` (`guestBound`, `guestUnbound`, `frameDropped`, `deviceReset`), but RuntimeCore learns of frames only through `ScanoutPoolHandle.frames`.
- R-02: virglrenderer and ANGLE render common apps correctly. Fallback: the `guestSwiftshader` profile through Graphics Safe Mode (§9). There is no automatic fallback.
- R-03: one render thread serves several displays at 60 fps. Fallbacks: a lower frame rate for background windows, one renderer thread per display if virglrenderer allows it, or revised targets through an ADR.
- R-08: host memory of the renderer and of one pool per display (§5.4, §6.3). Fallback: lower defaults and smaller pools.
- R-07: no VM save and restore while this device is attached. Accepted; revisit if a later virglrenderer or the Vulkan track (§10) can rebuild the renderer state.
- OQ-39: how the EDID physical size affects the density of secondary displays (§6.4). Working default: set the density with `setDisplayPolicy` only.
- OQ-07: whether `gpuUtilization` from the IOKit accelerator statistics is usable (§7). Working default: best effort, reported as unavailable when the key is missing.
