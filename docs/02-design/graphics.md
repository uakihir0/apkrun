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

The normal path has no CPU copy of pixel data and no GPU→CPU readback (FR-GFX-05, NFR-PERF-05). RiftVM reports about 60 fps with 0.4–0.8 ms per present in a specific Omarchy/Hyprland run; that is upstream evidence, not an APKRun measurement or a universal target. RiftVM blits into a `CAMetalLayer` drawable in the same process, while APKRun blits into an IOSurface that another process presents ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md), [riftvm-analysis.md](riftvm-analysis.md) §7).

---

## 2. RiftVM as a technical reference (#018)

The planned RiftVM v1.0.4 source tag is not present in the upstream tag list checked for #018. The available reference is `riftvm-v0.6.1`, pinned to commit `51f19193b1d3326b2e164d37a2a59e9970375170` in `ThirdParty/ThirdParty.lock.json` (IR-188). The tag contains a Custom VirGL implementation used by RiftVM's normal VM graphics path; its maintained architecture covers general Linux VMs as well as its Omarchy integration. APKRun analyzes the low-level `Experiments/VZVirtioGPUPrototype` package, its production caller, and the pinned renderer build inputs. This source is not treated as equivalent to the unavailable v1.0.4 release or as APKRun's product architecture.

### 2.1 What RiftVM provides (research baseline)

| Area | RiftVM `riftvm-v0.6.1` prototype at `51f19193` |
|---|---|
| Device | device ID 16, PCI class `0x03` / subclass `0x80`, two queues (control and cursor); one scanout and one capset in the device config |
| Features | `VIRTIO_GPU_F_VIRGL` and `VIRTIO_GPU_F_EDID`; no resource blobs, `CONTEXT_INIT`, or shared-memory regions |
| Guest memory | `guestMemoryMapping(atPhysicalAddress:length:)` mappings are retained with each resource's backing and released on detach/reset/stop |
| Renderer | virglrenderer `960bd6674a25a438da2aac8a0af8c6d6e2b3a77e`, libepoxy `1b6d7db184bb1a0d9af0e200e06a0331028eaaae`, ANGLE `2d91f554ab55bd1bef6998ab4094f60ae3e7feb5` (Metal) |
| Threading | serial VZ device queue, one dedicated renderer thread for virglrenderer/ANGLE, and bounded main-thread presentation (`LatestFrameScheduler`: one in flight plus the newest pending frame) |
| Fences | `CONTEXT_INIT` is not offered; host completions are serialized into the guest's single timeline and time out after two seconds |
| Scanout | borrows the VirGL texture, wraps the destination `CAMetalDrawable` texture in an ANGLE `EGLImage`, then GPU-blits; same-process `CAMetalLayer`, no IOSurface pool |
| Patches | RiftVM's MSAA downgrade patch (`scripts/virgl-patches/`); the macOS and recipe patches are applied by RiftVM's `scripts/prepare-virgl-sources.sh`. APKRun's adopted set, its lineage, and its differences from RiftVM are in §5.1 and [riftvm-analysis.md](riftvm-analysis.md) §4 |
| Limits | 8192 px texture edge, 256 MiB buffer, 4096 resources, 256 contexts, 4 GiB renderer budget, 4 GiB total guest backing; the full set is in [riftvm-analysis.md](riftvm-analysis.md) §2.2, and the APKRun differences are in §7 |
| Save/restore | Disabled for VirGL (renderer state cannot be serialized) |
| Input | GPU prototype does not implement input. A separate experimental `virtio-input` probe is not a production backend; RiftVM uses USB and its Guest Agent/uinput path |
| Performance | Upstream reports ≈ 60 fps and 0.4–0.8 ms per present for a specific Omarchy/Hyprland run; not measured by APKRun |
| Source files | `VirtioGPUDevice.swift`, `VirtioGPUProtocol.swift`, `VirGLRenderer.swift`, `RiftVMVirGLRuntime.swift`, `CVirGLBridge.c`, `ActiveContextSet.h`, `RendererExecutor.swift`, `LatestFrameScheduler.swift`, and the production caller `VMCustomVirGLGraphics.swift`; the build scripts `scripts/virgl-runtime-pins.sh`, `prepare-virgl-sources.sh`, and `build-virgl-runtime-from-source.sh`; and the tests `Tests/CVirGLBridgeTests/` and `Tests/RiftVMCoreTests/VMVirGLPresentationTests.swift`. File-by-file reuse decisions are in [riftvm-analysis.md](riftvm-analysis.md) §5 |

### 2.2 #018 deliverable

#018 writes `docs/02-design/riftvm-analysis.md`. It analyzes the RiftVM source at the full commit recorded in `ThirdParty/ThirdParty.lock.json` as `riftvm` and covers, for each step of the flow:

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
- The #018 pin is `ships: reference`: the source is recorded for analysis only and is not built, imported, copied, or distributed. The MSAA code copied into the virglrenderer patch set is an exception, which IR-410 records. If a later task copies or adapts RiftVM code, it changes the lock entry to `ships: derived`, preserves the required notices, and still never imports the RiftVM package.

---

## 3. VirtioDeviceCore (#063, #019)

### 3.1 Platform API recap (macOS 27)

- `VZVirtualMachineConfiguration.customVirtioDevices: [VZCustomVirtioDeviceConfiguration]`.
- The configuration takes `deviceID` (UInt16), `PCIClassID`/`PCISubclassID` (UInt8), `virtioQueueCount`, `mandatoryFeatures`/`optionalFeatures` (`VZVirtioFeatureSet`, two 32-bit subsets; `VIRTIO_F_VERSION_1` is always set), `deviceSpecificConfiguration` (initial config bytes), `sharedMemoryRegions`, `provider`, and `supportsSaveRestore` (default `NO`; setting it without implementing the save/restore delegate methods raises an exception).
- The provider is `VZCustomVirtioDeviceDelegateProvider(deviceQueue:delegate:)`. The delegate receives `didCreateDevice`, and the device delegate receives `didReceiveNotificationForQueue`, `DidAcceptDriverOk`, `WillStop`, `WillPause`, `WillResume`, `WillReset`, and the save/restore methods. Everything runs on `deviceQueue`, in the process that owns the `VZVirtualMachine` (apkrund).
- `VZCustomVirtioDevice.queueAtIndex:` and `negotiatedFeatures` are valid only after DRIVER_OK. `guestMemoryMappingAtPhysicalAddress:length:` mappings become invalid after reset, reboot, or stop. `requestDeviceReset` sets DEVICE_NEEDS_RESET. `updateDeviceSpecificConfiguration:completionHandler:` replaces the config bytes with data of the **same size**.
- `VZVirtioQueue.nextElement` disables notifications until the queue is drained, so callers must loop until it returns `nil`. Element `readBuffers` are zero-copy views of guest memory. `returnToQueue` must be called exactly once. Apple warns about time-of-check/time-of-use (the guest can change memory after we read it).
- The configuration delegate's `didCreateDevice` callback runs on the VM's serial queue and must set `device.delegate` before returning. The configured device queue serializes all later device and device-delegate operations.
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
    func deviceDidStart(context: VirtioDeviceContext, negotiatedFeatures: UInt64)
    func queueNotified(index: Int, context: VirtioDeviceContext)
    func deviceWillPause()
    func deviceWillResume()
    func deviceWillReset()
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
```

`VirtioDeviceModel` lifecycle methods default to no-ops. Implementations run on
the per-device queue. A context is not `Sendable`, so synchronous queue,
feature, and guest-memory operations cannot be moved into an asynchronous task.
When asynchronous work needs to update configuration, obtain
`configurationUpdater` on the device queue before creating the task. Configuration
updates are serialized per device and tied to the current reset generation;
reset or release completes outstanding requests with `.notReady`. Each model
callback receives a context bound to that generation. Its `configurationUpdater`
carries the captured generation across an actor hop, so a delayed update from a
previous generation fails with `.notReady` even after the device reaches
`DRIVER_OK` again. Synchronous queue access, feature inspection, and guest-memory
mapping also carry that generation: an old context fails with `.notReady` after
reset even if the device is ready again. A stale `requestReset` is ignored.

`VirtioElement` is non-copyable and device-queue confined. `PendingElement` is
also non-copyable, but is `Sendable` so a renderer fence may carry it to another
queue; its completion is always returned to the device queue. For an API that
requires a copyable escaping closure, `PendingElement` can transfer its storage
to a package-scoped, lock-protected one-shot completion token. The token keeps
the abandonment diagnostic and schedules late completion through the same
device-queue path.

Design rules:

- **One device queue per device** (a serial `DispatchQueue` with `.userInteractive` QoS). VZ objects (`VZCustomVirtioDevice`, queues, elements) are touched only on it.
- **Keep the VZ callback objects alive.** The configuration provider's delegate and `VZCustomVirtioDevice.delegate` are weak references. The VM driver retains the adapter and model through VM release. `didCreateDevice` is the one callback on the VM queue; it only stores the device and sets its delegate before returning. Before releasing the machine, the driver drains each device queue, stops the model, invalidates guest-backed state, and clears the weak delegate.
- **Copy, then validate.** Request bytes are copied out of guest memory exactly once (`copyReadable`) before any field is validated. Validated values are never re-read from guest memory. This is the TOCTOU rule from Apple's documentation.
- **Drain without throwing.** `VZVirtioQueue` suppresses notifications until `nextElement()` returns `nil`. The `drain` body therefore cannot throw out of the loop; it handles each element's failure locally and completes the element before the next iteration.
- **Exactly-once completion.** `VirtioElement` and `PendingElement` are non-copyable, so the type system prevents completing either handle twice. A copyable `PendingElementCompletionToken` supports escaping callbacks; its lock-backed one-shot gate traps at runtime if `complete()` is called a second time (covered by a T0 process-exit test). A double `returnToQueue` raises an exception in VZ. In debug builds, dropping a live handle without completing it schedules/returns the VZ element to keep the guest queue usable, then raises an assertion. Reset or stop invalidates pending elements first, so dropping a handle that the adapter has already invalidated is a no-op and does not assert.
- **Guest memory mappings** are cached per device and invalidated on reset/stop before the model lifecycle callback. A `GuestMemory` value checks bounds on every access, and every length is checked for overflow (`gpa + len` must not wrap).
- **Features** are expressed as a `UInt64` and split into `subset0` (bits 0–31) and `subset1` (bits 32–63) only in the VZ adapter.
- A `FakeVirtioQueue` and `FakeGuestMemory` live in the `VirtioDeviceCoreTestSupport` target so device models can be unit-tested (T0) without a VM.

### 3.3 Test entropy device (#063)

Following the WWDC26 sample, VirtioDeviceCore ships `EntropyTestDevice`: deviceID 4 (virtio-rng), PCI class 0x10, one queue, no features. It fills each writable buffer from a deterministic generator seeded by the test (so the guest can check the bytes). It is used only in T2 tests.

Acceptance (#063): the Linux test guest ([vm.md](vm.md) §12), with the built-in VZ entropy device disabled, lists `virtio_rng.0` in `/sys/class/misc/hw_random/rng_available`. It reads 64 KiB from `/dev/hwrng` that match the seeded sequence. After a device reset (driver unbind and bind), a second read works. A context retained from the prior generation rejects queue access, feature inspection, and guest-memory mapping after the device is ready again; a reset request through that stale context does not disrupt the current generation. A real guest-memory mapping retained by the test model rejects access as invalidated during both the reset and stop callbacks. On the tested shutdown path VZ sends `WillReset` before `WillStop`, so the mapping observed during `WillStop` was already invalidated by the preceding reset; the adapter also runs its invalidation barrier on `WillStop`. The host log shows `DRIVER_OK`, notifications, and reset in order.

The separate forced-stop probe retains a live mapping and a deferred VZ queue
element until VM stop. The adapter invalidates both before the model's stop
callback; a callback timeline records `DRIVER_OK`, mapping creation, and
`WillStop` with no intervening `WillReset`. The probe then attempts completion
through the old handle after stop. This covers the stop invalidation path
without an earlier guest reset.

On arm64 macOS 27.0 build 26A428, the Linux test guest's `reboot -f` produced a
guest console sequence of the first boot, reboot marker, and second boot. In the
same run, the serialized VZ callback stream contained `WillReset` between the
device's first and second `DRIVER_OK`; the VM did not report `guestDidStop`. The
integration harness then forced the VM to stop after observing the second boot.
These are per-stream observations on that OS build, not a cross-version
guarantee.

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

In #019, the device answers `GET_DISPLAY_INFO` and `GET_EDID` only. Every other command gets an error response, cursor commands included (IR-249). The v1 handling in the table above applies from #022 and #023.

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

**Built in #022.** `RESOURCE_ATTACH_BACKING` maps every entry and keeps the views on the device queue. It does not call `virgl_renderer_resource_attach_iov`: transfers hand the renderer a buffer that the device queue gathered from the guest, so the renderer never holds a pointer into guest memory. The copy is counted as `guestUploadBytes`. A zero-copy path needs a pointer API in VirtioDeviceCore, which is a follow-up ([implementation-review.md](../04-plan/implementation-review.md) IR-465). Buffers (`target` 0) are sized in bytes, so the 8192 limit applies to textures only, and the byte estimate is the level-0 size times depth and layers, without mip levels (IR-468).

### 4.5 Contexts, submissions, and fences

- Without `CONTEXT_INIT`, all fences are on one global timeline and complete in order. The device keeps a FIFO of deferred elements `(fenceID, PendingElement)`.
- For a fenced command, the render thread calls `virgl_renderer_create_fence(fenceID, ctxID)` after executing it. virglrenderer's `write_fence(fenceID)` callback (on the render thread) reports the highest completed fence. The device then completes every deferred element with `fenceID ≤ completed`, in order.
- Fence progress requires `virgl_renderer_poll()`. On macOS, virglrenderer's thread-sync mode depends on Linux eventfd and is not available. The render thread therefore polls after every batch and every 1 ms while fences are outstanding (a `DispatchSourceTimer` on the render thread's run loop, stopped when the FIFO is empty).
- Unfenced commands are completed as soon as they execute. The controlq is processed strictly in order, so a response never overtakes an earlier fenced command in a way the guest could observe.

### 4.6 Cursor queue

The Android `drm_virgl` configuration composes in client mode (`hwcomposer.mode=client`) and does not use a hardware cursor plane. The host shows the macOS cursor, and pointer input is injected by the Guest Agent ([input.md](input.md)). `UPDATE_CURSOR` and `MOVE_CURSOR` are acknowledged immediately, and the last values are kept for diagnostics. In #019 the device answers cursor commands with an error response until the cursor path of #023 exists (IR-249).

### 4.7 Threading

| Thread | Does | Never does |
|---|---|---|
| device queue (serial `DispatchQueue`) | VZ callbacks; drains queues; copies and validates requests; batches them into `RenderCommand`s; writes responses and completes elements | call virglrenderer, EGL, or Metal |
| render thread (one dedicated `Thread`, QoS `.userInteractive`, own run loop) | owns the EGL display, all EGL contexts, virglrenderer; executes commands in order; polls fences; performs present blits; creates the GPU-completion fences | touch VZ objects |
| completion waiter (one `Thread`) | waits on EGL sync objects for present blits, then emits `frameReady` | GL calls other than `eglClientWaitSync` |

Commands flow device queue → render thread in batches (one batch per queue drain). Completions flow back in batches through a lock-free single-producer/single-consumer ring and a `DispatchQueue.async` on the device queue. virglrenderer is not thread-safe, and all of its callbacks arrive on the render thread.

**Built in #022.** The waiting controlq elements sit in one ordered queue that the render thread completes. Each completion calls `PendingElementCompletionToken.complete()`, and VirtioDeviceCore moves the return to the device queue, so the SPSC ring above is not built (IR-466). The completion waiter belongs to #023, because it waits for present blits (IR-467). `TRANSFER_FROM_HOST_3D` runs on the device queue and waits for the render thread, because only the device queue may write guest memory (IR-464). The render thread is a `Thread` that waits on an `NSCondition`, and it polls fences every millisecond only while one is outstanding (IR-470).

---

## 5. Renderer (GraphicsBridge + VirGLRuntime) (#020, #022)

### 5.1 Libraries

| Library | Revision (initial pin) | License | Role |
|---|---|---|---|
| virglrenderer | 960bd667 + APKRun patches | MIT | decodes VirGL command streams; manages GL objects |
| libepoxy | 1b6d7db | MIT | GL/EGL function dispatch for virglrenderer |
| ANGLE | 2d91f554, Metal backend only | BSD-3-Clause | EGL + GLES 3.0 on Metal |
| ANGLE DEPS | astc-encoder 2319d9c4, vulkan-headers c0fe12c8, zlib e00f7038 | Apache-2.0, Apache-2.0, Zlib | listed in the lock for their notices; equal to ANGLE's `DEPS` revisions at the pinned commit; `gclient sync` still runs in the work area (IR-190) |
| depot_tools | f7083527 | BSD-3-Clause | build helper, run only from its own work area (IR-190) |
| PyYAML | 49790e73 (`6.0.3`) | MIT | pinned pure-Python build tooling used by virglrenderer’s Meson configuration |

- Pins, build flags, and patch lists live in `ThirdParty/ThirdParty.lock.json`. The build scripts are `ThirdParty/build/build-angle.sh`, `build-libepoxy.sh`, and `build-virglrenderer.sh`, driven by `scripts/build-third-party.sh virgl-runtime` ([../05-development/build-system.md](../05-development/build-system.md) §6).
- The virglrenderer build imports PyYAML only from the exact locked source checkout. It does not depend on a developer’s user-site packages or Homebrew Python modules.
- Outputs are dylibs with `@rpath` install names, placed in `ThirdParty/out/virgl-runtime/<lock hash>-<environment hash>/`. They are embedded into `APKRun.app/Contents/Frameworks/VirGLRuntime/` and signed inside-out with the app.
- The ANGLE Metal build needs about 11 GB of dependencies. CI caches the outputs by the lock hash and the detected Xcode, SDK, Metal, compiler, Python, pinned PyYAML, Meson, Ninja, pkg-config, and Git identities. A change to the locked inputs or the build environment selects a different cache directory.
- RiftVM's reference build flags, recipe archive identities, and patch-by-patch lineage are recorded in [riftvm-analysis.md](riftvm-analysis.md) §4. Its virglrenderer, libepoxy, and ANGLE source commits match the initial pins above. The listed patches are the adopted #020 inputs; their application, clean build, cache reuse, and tests passed as recorded in §16 / IR-191. #018 did not repeat that build.
- Adopted initial patches:
  1. `virglrenderer/0001-add-macos-metal-support.patch` carries the macOS Metal path from the pinned recipe (including broader Venus source changes, while APKRun sets `venus=false`). `0002-downgrade-unsupported-msaa.patch` keeps rendering available by reducing unsupported multisample resources to single-sample storage, losing antialiasing. `0003-link-metal-runtime.patch` is an APKRun downstream addition that links CoreFoundation and the Objective-C runtime.
  2. `libepoxy/0001-improve-library-detection.patch` resolves the bundled ANGLE EGL/GLES dylibs and enables EGL on Apple platforms; `0002-disable-desktop-extensions-on-gles.patch` fixes GLES entry-point selection; `0003-enable-egl-platform-display.patch` enables EGL 1.5 client-version lookup for `eglGetPlatformDisplay`.
  3. `angle/0001-fix-metal-boolean-mix.patch` emits Metal `select` for boolean-selector `mix` and raises the Metal shader UBO limit from 12 to 16.
- The RiftVM MIT notice covers RiftVM-authored source only. Renderer component licenses and recipe-patch provenance/notices remain tracked separately for the #093 legal review.
- Differences found by #018 in the adopted inputs. The side-by-side flags and the patch crosswalk are in [riftvm-analysis.md](riftvm-analysis.md) §4.
  - Build flags. #020 passes the lock's `buildFlags` unchanged. Against RiftVM it adds virglrenderer `-Dplatforms=egl`, libepoxy `-Dglx=no`, and ANGLE `mac_deployment_target="27.0"`, which are open for review in IR-413. It also lists ANGLE's DEPS components in the lock for their notices, while `gclient sync` still runs in the work area (IR-190). It gives ANGLE to virglrenderer through generated pkg-config files.
  - Patch lineage. `virglrenderer/0001` is one regenerated diff of the recipe patch; with `0002` applied, it gives the same source tree as the recipe patch plus RiftVM's MSAA patch. `virglrenderer/0002` is RiftVM MIT code carried from RiftVM `f615e16`, not from the pinned commit, and it ships in the runtime; that is copied RiftVM code under [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.1 (IR-410). `angle/0001` omits the recipe's Vulkan-backend hunk, which the Metal-only build does not compile (IR-411). `libepoxy/0001` names the bundled dylibs with `@rpath`, as IR-190 requires.
  - Patch headers. None of the carried patches (`virglrenderer/0001`, `virglrenderer/0002`, `angle/0001`, `libepoxy/0001`–`0003`) records whether it was sent upstream, which [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.2 requires (IR-412).
- APKRun sets virglrenderer `venus=false`. The host Venus/Vulkan backend is outside v1; the guest uses the documented GLES/VirGL path. This differs from the RiftVM recipe and is recorded for maintainer review in [implementation-review.md](../04-plan/implementation-review.md) IR-190.
- `scripts/build-third-party.sh virgl-runtime` validates the lock before looking up the cache, rejects patch paths that escape the patch tree, fetches clean pinned sources, applies the listed patches, then builds in separate work directories. Its manifest verifies artifact hashes, the arm64-only architecture, the macOS 27.0 minimum, `@rpath` install names, `@loader_path` runpaths, and every bundled dependency target. A cache hit is reused only when both lock and environment identities match and every output verifies.
- #020 acceptance: a fresh checkout produces the libraries with `scripts/build-third-party.sh virgl-runtime` and no manual file editing. This is checked in CI.

### 5.2 GraphicsBridge

A C target (`Packages/GraphicsCore/Sources/GraphicsBridge`, with Objective-C for Metal interop). Swift talks only to this interface, never to virglrenderer or EGL headers directly:

```c
typedef struct gb_renderer gb_renderer;

typedef struct {
    void (*write_fence)(void *user, uint32_t fence_id);     // render thread
    void (*log)(void *user, int level, const char *message);
} gb_callbacks;

int  gb_renderer_create(const gb_callbacks *cb, void *user, gb_renderer **out);   // EGL (ANGLE Metal) + virgl_renderer_init
int  gb_renderer_destroy(gb_renderer *r);
int  gb_renderer_reset(gb_renderer *r);
int  gb_renderer_metal_device(gb_renderer *r, void **out);  // id<MTLDevice> ANGLE uses (EGL_ANGLE_device_metal)

int  gb_capset_info(gb_renderer *r, uint32_t capset_id, uint32_t *max_version, uint32_t *max_size);
int  gb_capset_fill(gb_renderer *r, uint32_t capset_id, uint32_t version, void *out, size_t out_size_bytes);

int  gb_ctx_create(gb_renderer *r, uint32_t ctx_id, const char *name);
int  gb_ctx_destroy(gb_renderer *r, uint32_t ctx_id);
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

- EGL display: `eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, …, EGL_PLATFORM_ANGLE_TYPE_ANGLE = EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE)`. The pinned RiftVM prototype then calls `eglInitialize`, binds `EGL_OPENGL_ES_API`, and creates a 1 × 1 pbuffer config with GLES 2/3 support and 8-bit RGBA channels. Its `virgl_renderer_init` uses callback version 4 and **flags `0`**, with GL context create/destroy, make-current, fence, and EGL-display callbacks. It does not pass `VIRGL_RENDERER_USE_EGL` or `VIRGL_RENDERER_USE_SURFACELESS`; details are in [riftvm-analysis.md](riftvm-analysis.md) §2–§4.
- `GraphicsBridge` loads the four app-bundled dylibs from `Contents/Frameworks/VirGLRuntime` only after finding an `.app` with one of the exact `CFBundleIdentifier`/`APKRunBuildIdentity` pairs: `io.apkrun.APKRun`/`release`, `io.apkrun.APKRun.updatetest`/`updatetest`, or (in Debug) `io.apkrun.APKRun.dev`/`dev`. ReleaseUpdateTest shares the Release package configuration, so its identity must be selected from the app's Info.plist at runtime. The resolver rejects a runtime directory or library symlink that resolves outside the bundle. Debug builds can override this with `APKRUN_VIRGL_RUNTIME_PATH` and otherwise search the repository's verified `ThirdParty/out/virgl-runtime/current` cache. The T1 renderer test sets that debug override from its source location because SwiftPM's test runner executable lives under `.build/`; a separate resolver test exercises valid bundle identities and rejects identity mismatches and symlink escapes.
- virglrenderer has one process-wide renderer state. `GraphicsBridge` holds a process mutex while admitting one renderer, copies the public callback table into its opaque renderer, and keeps virglrenderer’s callback table alive until cleanup. Creation records the owner thread; every public renderer operation checks that thread and returns a typed status without changing state on mismatch. Callers serialize access and finish all in-flight calls, including rejected off-thread calls, before destroying the renderer; a handle is invalid after successful destruction. Callbacks run on the renderer thread. Callbacks and the ANGLE `MTLDevice` remain valid through renderer destruction. `gb_renderer_reset` invalidates guest-derived IDs; callers discard them before submitting more work.
- `gb_capset_fill` requires the caller's output-buffer length. The bridge re-queries the maximum capset size and rejects an undersized buffer before calling virglrenderer.
- The IOSurface-backed Metal textures must be created on **ANGLE's `MTLDevice`**, queried with `EGL_ANGLE_device_metal` (`eglQueryDisplayAttribEXT(EGL_DEVICE_EXT)` → `eglQueryDeviceAttribEXT(EGL_METAL_DEVICE_ANGLE)`). On multi-GPU Macs this avoids cross-device copies.
- `gb_present_blit`: `virgl_renderer_borrow_texture_for_scanout` gives the GL texture of the resource. The destination `MTLTexture` is imported once per pool buffer as an `EGLImage` (`EGL_METAL_TEXTURE_ANGLE`) and attached to an FBO. `glBlitFramebuffer` performs the copy with Y-flip and format conversion. Then an EGL fence sync is created and `glFlush` is called.
- RiftVM's prototype instead blits to a same-process `CAMetalLayer` drawable. Its inspected `glBlitFramebuffer` call uses increasing Y coordinates and has no explicit vertical reversal or separate format-conversion step. This does not change APKRun's intended blit; #023 verifies the wrapper-facing IOSurface orientation and pixel layout.

**Built in #022.** Every call of this section except the present functions (#023) is declared in `GraphicsBridge.h`. `gb_create_gl_context` gives every context the root context's objects, because virglrenderer creates context 0 unshared and its transfers would otherwise miss the textures of the root (IR-463).

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

**Built in #022.** The table takes the limits above, plus the ones that the spec does not set: `lastLevel` at most 13, a sample count at most 16, a transfer extent of at most one resource's 256 MiB, and at most 4 Mi row runs per transfer (IR-468). A nonzero stride must hold one row (IR-473). The formats are an allow-list of the virgl formats whose size is known, with uncompressed and 4 × 4 block-compressed layouts. Any other format gets `ERR_INVALID_PARAMETER` (IR-469).

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
| `headless` (development only) | no GraphicsCore device. VZ's own 2D `VZVirtioGraphicsDeviceConfiguration` (one 720×1280 scanout, no view) provides the DRM device | the `guest_swiftshader` set of the launcher capture (`egl=angle`, `gralloc=minigbm`, `hwcomposer=ranchu`, `display_finder_mode=drm`, `vulkan=pastel`, the ANGLE feature overrides, `opengles.version=196609`) ([android-image.md](android-image.md) §9.1) | none: nothing on the Mac shows the scanout | M1 bring-up before the virtio-gpu device renders (#012–#017, `apkrun dev boot --gpu none`). Never in a release bundle |

- The profile is chosen per boot: `BootOptions.gpuProfile` ([android-image.md](android-image.md) §9.1). Changing it requires restarting Android, because the bootconfig changes.
- RuntimeCore attaches the `VirtioGPUDevice` for `guestSwiftshader` and no device for `headless` (#021). For the others, the device must offer every entry of the profile's `requiredHostCapabilities` in the bundle manifest ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.7). Until the renderer offers `virgl` (#022), `drmVirgl` is refused before the VM starts with `runtime.gpuProfileUnavailable` (IR-380), because the guest would stall without its VirGL features.
- The user-facing setting is `graphics.safeMode` (off by default, [../03-reference/configuration.md](../03-reference/configuration.md)). It appears in Settings → Troubleshooting and is suggested by `apkrun doctor` after repeated `rendererInitFailed` or `rendererLost`. The UI and diagnostics show clearly that it is a slow fallback.
- There is no automatic fallback in v1. Silent fallback would hide regressions and make performance reports meaningless.
- The 2D renderer uses a plain Metal path (`replaceRegion` into the pool texture from the mapped guest backing). It is the only place where `cpuPixelCopies` may be non-zero. #022 builds it, and `boot_completed` with `guestSwiftshader` is part of #022's T2 suite.
- `VZVirtioGraphicsDeviceConfiguration` (VZ's own 2D device, one scanout) is not used for `drmVirgl` or `guestSwiftshader`, because it cannot provide multiple scanouts ([ADR-0002](../01-architecture/decisions/0002-virtualization-framework-macos27.md)). It serves only the development `headless` profile, which ADR-0002 already allows as a debugging fallback. A profile with no DRM device at all cannot boot the stock image: zygote and SurfaceFlinger abort without an EGL implementation, and `init.cutf_cvm.rc` waits for `/dev/dri/card0` in `early-init` (2026-10-08, IR-307).

**Built in #022.** The `guestSwiftshader` device keeps each 2D resource in a host shadow buffer, and `TRANSFER_TO_HOST_2D` copies the rectangle into it as a counted CPU pixel copy. The flush completes without a blit, because the pool arrives in #023 (IR-474). `drmVirgl` stays refused by RuntimeCore until its boot is verified on the VM (IR-462).

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

1. Pin the available RiftVM reference tag `riftvm-v0.6.1` at its full commit in `ThirdParty.lock.json` (source only; not built; substitution recorded in IR-188).
2. Read the files in §2.1 and the architecture document. Write `docs/02-design/riftvm-analysis.md` with the table in §2.2 filled in, file by file.
3. List the patches and exact build flags for virglrenderer, libepoxy, and ANGLE used by RiftVM. They seed #020.
4. Update §2.1 and §5.1 of this document if the analysis finds differences.

### #063 VirtioDeviceCore + test device (M0)

1. `VirtioDeviceDescriptor`, `VirtioDeviceModel`, `VirtioDeviceContext`, `VirtioQueue`, `VirtioElement`, `GuestMemory` (§3.2), and the VZ adapter that builds `VZCustomVirtioDeviceConfiguration` from a descriptor.
2. Fakes (`FakeVirtioQueue`, `FakeGuestMemory`) and T0 tests: drain loop, compile-time exactly-once semantics for noncopyable handles, deferred completion from an async task or completion token, a process-exit test for duplicate token completion, debug exit tests for forgotten handles, bounds and overflow checks, feature splitting.
3. `EntropyTestDevice` (§3.3). Extend the Linux test guest's `/init` with the `rng` check.
4. T2: acceptance in §3.3, including live guest-memory and deferred-element invalidation during forced VM stop.

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
2. Boot Android and capture `dmesg`, `/sys/class/drm`, and `/sys/bus/virtio/devices/*/device`. The sysfs reads run as root on the development image, because SELinux denies the shell the connector status (IR-384). The kernel log falls back to the hvc0 console (IR-385).
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
| `rendererOperationFailed(operation, detail)` | capset, context, reset, or teardown failed, including a call from the wrong thread | restart Android; attach diagnostics if it continues |
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
| T0 | VirtioDeviceCore fakes: drain, compile-time exactly-once handles, deferred completion (including actor and completion-token hops), duplicate token completion trap, forgotten-handle exit checks, bounds, features | #063 |
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
| Which RiftVM recipe patches APKRun should carry or reimplement (§5.1) | #020 checks the pinned macOS and ANGLE/libepoxy recipe patches against APKRun's own pinned sources; adopt only the required, license-reviewed changes. The source flags and EGL init behavior are recorded in [riftvm-analysis.md](riftvm-analysis.md) |
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
| Custom virtio API with `EntropyTestDevice`: queue validity before DRIVER_OK, same-size config updates, reset and stop mapping invalidation, deferred completion, guest reboot | #063 | 2026-10-05, arm64 MacBook Pro, macOS 27.0 build 26A428 / Xcode 27.0 build 27A266a: VirtioDeviceCore and VirtualMachineCore T0 passed (26 and 71 tests); clean filtered-copy Xcode integration build passed; LinuxGuest T2 passed 10 XCTest cases and 6 observer tests. The forced-stop callback attachment records `DRIVER_OK → mapping creation → WillStop`; it contains no `WillReset` between mapping creation and stop. The live mapping is rejected and the old deferred-element completion is attempted after stop. Reboot evidence records the guest console order and VZ callback order independently. Full repository checks passed; the final hostile review's completion-token documentation finding was corrected and a regression test added. See IR-193. |
| RiftVM source analysis: `riftvm-v0.6.1` commit `51f19193b1d3326b2e164d37a2a59e9970375170`, source/build flags, license and APKRun differences | #018 | 2026-10-07: analysis updated after hostile review with command responses, resource-estimate limits, scanout/mode behavior, GPU-profile and display-topology differences, and a patch-by-patch #020 crosswalk. The source-only lock check passed and its MIT copy was manually compared with the pinned source. #020's separate clean build, cache reuse, and tests are recorded below / IR-191; #018 did not repeat them. No RiftVM VM/Android/Metal presentation test; maintainer review pending (IR-188). 2026-10-10 (re-check, no build and no VM): the upstream files at `51f19193` were re-read through the GitHub API and matched [riftvm-analysis.md](riftvm-analysis.md) §2–§5; the tag `riftvm-v0.6.1` peels to that commit. The analysis gained the flow-step crosswalk (§2.4), the #020 flags and patch deviations (§4), the renderer license table (§4), and the build and test inventory (§5). The recipe and source archives matched their pins; the virglrenderer patch sequences were applied to the pinned source. `scripts/check-lock.sh` passed with `riftvm` as a source-only reference, and `riftvm` is in no build group. New review items: IR-410 (copied RiftVM MSAA code and its notice rule), IR-411 (ANGLE Vulkan hunk), IR-412 (patch upstream status), IR-413 (flags beyond RiftVM's). |
| The Linux test guest detects the virtio GPU: vendor 1af4 device 1050, 16 scanouts, `Virtual-1` connected, EDID equal to the generated one | #019 | 2026-10-08, arm64 MacBook Pro, macOS 27.0.1 build 26A434, signed `IntegrationTests` host, `LinuxGuest` run: 29 of 29 passed. The `gpu` check passed, and its EDID SHA-256 equals `scanout-00-1024x768-60.edid` (`GPUDeviceTests`). The driver's 28 exchanges are committed as `virtio-gpu-linux-trace.json`. |
| Config-change interrupt from `updateDeviceSpecificConfiguration`: hotplug of scanout 1 on the Linux test guest | #019 | 2026-10-08, same run. The host enabled scanout 1 3.0 s after DRIVER_OK. The guest's `gpu-hotplug` check reported `scanout1=connected` after about 4 s and 5 s in two runs. Linux part positive. The driver re-reads display info on a config-change event, so the update raised one (inference). Android stays with #028 (IR-256). |
| Clean build of the runtime libraries from the lock file; renderer create, `VIRGL2` capset, context lifecycle, and recreation on the host | #020 | 2026-10-05, arm64 macOS 27.0 build 26A428 / Xcode 27.0 build 27A266a: clean native build and verified cache hit (IR-191); GraphicsBridge T0 (3 tests), host T1 (2 tests) normal/ASan/UBSan, Release bundle check, and full repository checks passed. Hostile review found no actionable P1/P2; callers must quiesce before destroy (IR-192). Maintainer review pending. |
| `kmscube` on the Linux test guest: `virgl` renderer and `hostReadbacks = 0` headless (#022), ≥ 55 fps in the development window (#023) | #022, #023 | pending (§12) |
| Android binds `virtio_gpu`: `card0` with 16 `Virtual-N` connectors, only `Virtual-1` connected | #021 | 2026-10-10, Mac17,9 (arm64), macOS 27.0.1 build 26A434 / Xcode 27.0 build 27A266a, image `2026.10.0-cf16373615-arm64` (build 16373615), `guestSwiftshader`: `AndroidGraphicsTests.testVirtioGPUBinds` passed in 13.7 s. Device ID 16 (`virtio18`) is bound to `virtio_gpu`: the kernel logs `[drm] number of scanouts: 16` and `Initialized virtio_gpu 0.1.0`, with `+edid -virgl`. `card0` has 16 connectors, and only `card0-Virtual-1` is `connected` (the others are `disconnected`). The captures (`kernel-log.txt`, `drm-connectors.txt`, `virtio-devices.txt`, `summary.txt`, `hvc0-console.log`) are in the bundle's `android-graphics` directory. The 2D commands return `VIRTIO_GPU_RESP_ERR_UNSPEC` until #022. The capture came while the boot was in `booting(systemServer)`. A CLI boot with this profile reached `sys.boot_completed=1` at kernel time 8.5 s (`cli-swiftshader-boot.log`, IR-390). The sysfs reads run as root (IR-384). `AndroidGraphicsRefusalTests` checks that `drmVirgl` is refused before any file changes (IR-380). |
| SurfaceFlinger uses GLES through virgl, no guest SwiftShader or ANGLE libraries, `sys.boot_completed=1` | #022 | pending (§5.3) |
| Host side of #022, without a VM: the 3D command set, transfers, fences, limits, the 2D path of `guestSwiftshader`, the recorder, and a texture round trip through the real renderer | #022 | 2026-10-10, Apple silicon Mac, macOS 27.0.1 build 26A434 / Xcode 27.0 build 27A266a, no VM started. GraphicsCore T0 passed (138 tests, `swift test --filter GraphicsCoreTests`). GraphicsCore T1 passed (7 tests; 8 with `--traits TestReadback`), including the upload and readback through context 0 (IR-463), the fence retirement above 2^31, and the replay of a recorded session on a fresh renderer. An adversarial review found seven defects, all fixed, each with a test; IR-460 to IR-479 record the decisions. RuntimeCore `AndroidGraphicsDevicesTests` passed (4 tests). The HelloGL fixture built offline, and its signer matches the fixture key. `hostReadbacks` stays 0 on every path, because nothing reads back on the host. This is not the guest result: the rows above stay pending until the VM runs. |
| Gate G3: HelloGL ≥ 55 fps average, `hostReadbacks = 0` and `cpuPixelCopies = 0` over 60 s, no tearing | #023 | pending (§6.2, §7) |
| Hotplug with Android, and whether fallback A makes the driver re-read the display info | #028 | pending (§4.3) |
| A runtime mode change keeps the display ID; density of secondary displays from the EDID (OQ-39) | #067 | pending (§6.4) |
| Two displays: fps, present time p95, and memory; `gpuUtilization` availability (OQ-07) | #030, #070 | pending (§7) |
| `maximumAllowedSharedMemoryRegionCount`, and mapping IOSurface- or Metal-heap-backed memory into a shared-memory region | #096 | pending (§10) |
