# RiftVM GPU Prototype Analysis

This document records what APKRun takes from the RiftVM GPU prototype, what it rejects, and the license and reuse decision for each file. The pinned source is a reference only. It is not built, run, or distributed (lock entry `riftvm`, `ships: reference`; [graphics.md](graphics.md) §2.3). The APKRun design is in [graphics.md](graphics.md).

## 1. Source identity and limits

| Item | Pinned value |
|---|---|
| Repository | [`riftvm/riftvm`](https://github.com/riftvm/riftvm) |
| Tag | `riftvm-v0.6.1` |
| Commit | `51f19193b1d3326b2e164d37a2a59e9970375170` |
| Lock entry | `riftvm` in `ThirdParty/ThirdParty.lock.json`, `kind: source`, `ships: reference` |
| License | MIT, repository root; copy in `ThirdParty/licenses/riftvm/LICENSE` |

The planned RiftVM v1.0.4 is not in the upstream tag list, so the available v0.6.1 is the reference. The tag is unsigned and its release is mutable. The lock therefore identifies the commit. The pin fixes the analyzed content but does not authenticate the publisher.

The analyzed code is `Experiments/VZVirtioGPUPrototype`, the production caller `RiftVM/RiftVM/Core/VMKit/Graphics/VMCustomVirGLGraphics.swift`, the renderer build scripts (§4), and the upstream architecture notes at the pinned commit.

RiftVM is an Omarchy-oriented macOS VM product. Its maintained architecture also uses Custom VirGL for general Linux VMs. The prototype README calls its package a regression harness, but the pinned app links `RiftVMVirGLRuntime` into its normal VM path. Upstream end-to-end validation covers Omarchy/Hyprland only. None of it covers APKRun's Android/Cuttlefish guest, multi-scanout configuration, IOSurface/XPC handoff, or wrapper-owned windows. Upstream performance figures are not APKRun measurements.

### 1.1 Production ownership and shutdown order

- `VMCustomVirGLGraphicsBackend` validates the runtime libraries, constructs `RiftVMVirGLRuntime`, and creates the device configurations before any `VZVirtualMachine` exists. Initialization errors are therefore handled before the VM starts. The app binds the VM to the backend and only then starts it.
- Machine save/restore is disabled, because guest RAM alone cannot restore VirGL contexts, resources, fences, or command state.
- On teardown the backend is retained until Virtualization reports `stopped` or `error`. The runtime then shuts down the GPU device, which drains guest resources and delegate work, and then the renderer.
- `VirGLRenderer.shutdown()` does **not** tear down the process-global virglrenderer or ANGLE state. It cancels pending fences and releases the renderer lease. The renderer stays initialized for the next VM, and ANGLE is reclaimed at process exit. Per-VM device cleanup and process-wide renderer cleanup are separate lifecycle boundaries.

## 2. Device and command flow

### 2.1 Custom virtio device and queues

`VirtioGPUDevice.makeConfiguration()` creates device ID 16, PCI class `0x03` / subclass `0x80`, with a control queue and a cursor queue. It offers features 0 and 1 (`VIRTIO_GPU_F_VIRGL`, `VIRTIO_GPU_F_EDID`) and a 16-byte little-endian `virtio_gpu_config` with one scanout and one capset. It offers no resource blobs, no `CONTEXT_INIT`, and no shared-memory regions. It does not define `supportsSaveRestore`.

Lifecycle, as observed: the configuration provider supplies a serial `deviceQueue`. `didCreateDevice` stores the device and sets the delegate. `DidAcceptDriverOk` marks the point where the stock Linux driver has accepted the identity. Queue notifications drain `nextElement()` until it is empty. Synchronous requests write their response and return the element. Fenced requests keep the element until the renderer callback. Pause cancels pending presentation, and resume resubmits a still-valid scanout. Reset and stop release renderer objects, guest mappings, cursor state, and pending presentation.

Reused as a pattern: the drain loop, and the bounded copy of each readable buffer before any field is decoded (16 MiB maximum). The decoder maps unknown commands to `ERR_UNSPEC` and wrong-queue, undersized, or invalid requests to `ERR_INVALID_PARAMETER`. A request shorter than a header is logged and completed with no response. Rejected: its error and logging surface. APKRun uses typed errors, rate-limited diagnostics, and its own exactly-once element API ([graphics.md](graphics.md) §3.2).

### 2.2 Commands, resources, and backing

`VirtioGPUProtocol.swift` holds the little-endian decoding and the command and response enums. The device handles display info, EDID, VirGL capsets, 2D and 3D resource creation, attach, detach, and unref, contexts, 3D submission and transfers, scanout, flush, and cursor. It supports scanout 0 and capset index 0 only. Its single-scanout model is not APKRun's 16-scanout model.

`SET_SCANOUT` with resource 0 clears the active binding and cancels queued presentation. The host view keeps its last drawable until a replacement arrives. Unref of a borrowed scanout stops borrowing but keeps the last drawable. Reset or shutdown is the separate boundary that releases device state.

`RESOURCE_ATTACH_BACKING` maps each guest range with `guestMemoryMapping(atPhysicalAddress:length:)`. The resource keeps the mappings and an `iovec` array while it is attached. The implementation bounds the entry count and byte budgets before it hands backing to virglrenderer. Detach and reset release the mappings. APKRun keeps the lifetime rule and adds full guest-range, size, and state validation ([graphics.md](graphics.md) §4.4).

Rejected: RiftVM's limits (`VirtioGPUProtocol.Limits`: 16 MiB requests, 8 MiB `SUBMIT_3D`, 8192 px textures, 4096 resources, 256 contexts, 4096 backing entries per attach, 1 GiB per resource and 4 GiB total backing, 256 × 256 px cursors). Other 3D limits are depth and array size 2048, mip level 15, and sample count 16. For `PIPE_BUFFER` (target 0), width is a byte count. APKRun sets its own limits ([graphics.md](graphics.md) §5.4).

The 4 GiB budget is an estimate, not a hard allocation ceiling. It assumes 4 bytes per texel and doubles the estimate when a mip chain is present. Formats can use up to 16 bytes per texel, so the estimate can undercount. Do not use it as a worst-case bound.

Cursor: `UPDATE_CURSOR` copies pixels to host memory and creates a `CGImage`. Renderer-backed cursors use `transfer_read` first. Rejected: APKRun does not copy cursor pixels to host memory. Cursor handling stays outside the scanout path.

### 2.3 VirGL, fences, and scanout

`VirGLRenderer.swift` owns the renderer calls and capset 1. The C bridge loads virglrenderer and the ANGLE EGL and GLES entry points dynamically. `virgl_renderer_init` uses callback version 4 and **flags `0`**, with fence, GL-context create and destroy, make-current, and EGL-display callbacks. On macOS the Meson configuration sets `have_egl` whenever libepoxy reports EGL, and it does not build GBM or DRM renderers.

Reused: the initialization flags and callbacks (APKRun also passes flags `0`). Rejected: the 2-second fence failure timeout. APKRun polls every 1 ms while fences are outstanding and counts stalls at 100 ms instead ([graphics.md](graphics.md) §4.5, §6.2).

There is no `CONTEXT_INIT`, so the guest sees one fence timeline. virglrenderer may retire per-context fences out of order. The host therefore assigns nonzero fence IDs and an ordered queue delays completion of earlier submissions. APKRun uses the same ordering idea ([graphics.md](graphics.md) §4.5).

On `RESOURCE_FLUSH` the prototype borrows the scanout's GL texture. It queues server-side waits on producer syncs, wraps the destination `MTLTexture` in an `EGLImage` (`EGL_METAL_TEXTURE_ANGLE`), attaches both textures to framebuffers, and performs a GPU `glBlitFramebuffer`. The normal path copies no pixels through `Data` or `CGImage` and uses no IOSurface pool. The observed blit uses increasing Y coordinates with no explicit vertical reversal and no separate format conversion. APKRun verifies its own IOSurface orientation and format ([graphics.md](graphics.md) §5.2).

Rejected: with `RIFTVM_VIRGL_DIAGNOSTICS=1` the bridge samples `glReadPixels` for a content signature. The non-zero-copy fallback and the cursor path also read pixels on the CPU. None of these may run on APKRun's normal path.

## 3. ANGLE initialization and presentation

`CVirGLBridge.c` loads `libEGL.dylib` and `libGLESv2.dylib` beside virglrenderer. EGL setup: `eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, …)` with `EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE`; `eglInitialize` and `eglBindAPI(EGL_OPENGL_ES_API)`; one pbuffer config with GLES 2/3 renderability and 8-bit RGBA; a 1 × 1 pbuffer; and a root GLES context. VirGL contexts share with the root when the callback asks for it. APKRun reuses this sequence ([graphics.md](graphics.md) §5.2).

The prototype assigns `MTLCreateSystemDefaultDevice()` to its layer. That does not show that IOSurface textures use ANGLE's device. APKRun requires ANGLE's device ([graphics.md](graphics.md) §5.2).

`LatestFrameScheduler.swift` allows one presentation in flight and keeps only the newest pending frame. It counts submitted, delivered, and coalesced frames. Reused as a pattern: the latest-frame coalescing, connected to APKRun's `SurfacePool`, sequence numbers, and XPC acknowledgements ([graphics.md](graphics.md) §6.2).

Rejected: the production presentation in `VMCustomVirGLGraphics.swift`. It presents one scanout at a time into `CAMetalLayer` drawables and discards results whose token is stale, whose view is occluded, or whose activity generation changed. APKRun presents into IOSurfaces for a wrapper process ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)).

## 4. Renderer sources, patches, and build flags

The source pins in RiftVM's `scripts/virgl-runtime-pins.sh` match the initial APKRun pins in [graphics.md](graphics.md) §5.1. RiftVM's recipes and flags are reference values.

| Input | Source | RiftVM recipe and archives |
|---|---|---|
| virglrenderer | `960bd6674a25a438da2aac8a0af8c6d6e2b3a77e`; archive SHA-256 `b7b9aaa05b10765c244790b2f2580e34e7cee383b4419ce5dd0c111d59e464a3` | recipe `20828ebf629191f4d48993ada3e631e6f92532c1`; recipe archive SHA-256 `afb58a118a11cabf381b1e53e155b0bb07d995ffb3cbfeb09decfb723cd41e1a` |
| libepoxy | `1b6d7db184bb1a0d9af0e200e06a0331028eaaae`; archive SHA-256 `15f769a8f24c361c8de28d72625daf07d0107b683fa0a5118d0aa8b0c5fc9eab` | recipe `eeb72845c15eeb9a57635fc54467234b2e38f51a`; recipe archive SHA-256 `2385e015283816237615c3933b58c174ca8fd55be351a56799cdfeb656b6f789` |
| ANGLE | `2d91f554ab55bd1bef6998ab4094f60ae3e7feb5`; archive SHA-256 `c24c4e7bc464a63069b67a9f663717b6e0f4a5ff4b6404215a7dc98ea83c6ba7` | recipe `b010ac372569747a4b265e75eaa72868c6849f62`; recipe archive SHA-256 `076df85af0f3bcd5d1232be7285bdb0bc305f28df155bc5ac6d19e83e27e3195` |
| ANGLE build helper | depot_tools `f70835271105ca56d2cd5382a0118152bc2bdeea` | ANGLE DEPS synchronized to the pinned ANGLE revision |

The APKRun patches map to the RiftVM inputs as follows. "Adopted" is APKRun's #21 working set.

| APKRun patch | RiftVM counterpart | Relation | Disposition |
|---|---|---|---|
| `virglrenderer/0001-add-macos-metal-support.patch` | `virglrenderer-macos-unified.patch` (recipe `20828ebf`, applied first) | A regenerated form of the recipe patch. With `0002`, it gives the same source tree as the recipe patch plus RiftVM's MSAA patch. It also contains Venus source changes | Adopted; `venus=false` |
| `virglrenderer/0002-downgrade-unsupported-msaa.patch` | `scripts/virgl-patches/virglrenderer-msaa-downgrade.patch` in RiftVM | Same added lines. The header credits RiftVM `f615e16` (MIT), so the code is RiftVM-authored | Adopted; ships in the runtime. Copied RiftVM code: the notice rule of §5 applies |
| `virglrenderer/0003-link-metal-runtime.patch` | none | APKRun addition, not submitted upstream | Adopted |
| `libepoxy/0001-improve-library-detection.patch` | `libepoxy-akihikodaki-egl15.patch`, patch 1 | Same, except the dylib names use `@rpath` | Adopted |
| `libepoxy/0002-disable-desktop-extensions-on-gles.patch` | patch 2 | Same added lines | Adopted |
| `libepoxy/0003-enable-egl-platform-display.patch` | patch 3 | Same added lines | Adopted |
| `angle/0001-fix-metal-boolean-mix.patch` | `angle-changes-main.patch` (recipe `b010ac37`) | Same, except the recipe's Vulkan hunk in `VertexArrayVk.cpp`, which the Metal-only build does not compile | Adopted |

The recipe archives contain more patches (`venus-*`, `bgra-*`, `angle-egl-include.patch`, `virglrenderer-borrow.patch`, `vrend-error-reporting.patch`, `libepoxy-changes-main.patch`). RiftVM's script does not apply them, and APKRun does not apply them either. RiftVM's script applies only the virglrenderer recipe patch, then `scripts/virgl-patches/virglrenderer-*.patch`, then the ANGLE and libepoxy recipe patches, in that order.

RiftVM's reference arguments come from `scripts/build-virgl-runtime-from-source.sh`. ANGLE is built Metal-only (`angle_enable_metal=true`; GL, Vulkan, SwiftShader, WGPU, and Null off), release, with `use_system_xcode=true`, and it produces `libEGL` and `libGLESv2`. libepoxy uses `-Degl=yes -Dx11=false -Dtests=false`. virglrenderer uses `-Ddrm-renderers=[] -Dvenus=true -Dtests=false -Dvideo=false -Dtracing=none`, with ANGLE and libepoxy found through `PKG_CONFIG_PATH`.

APKRun's #21 flags come from the lock's `buildFlags`. ANGLE adds `mac_deployment_target="27.0"`. libepoxy adds `-Dglx=no`. virglrenderer uses `-Dplatforms=egl -Ddrm-renderers=[] -Dvenus=false -Dtests=false -Dvideo=false -Dtracing=none`, and receives ANGLE and libepoxy through generated pkg-config files. Its Meson process sees only the locked PyYAML 6.0.3 as Python. `-Dvenus=true` in RiftVM is not guest Vulkan support. The prototype advertises only VIRGL and EDID.

Licenses of the renderer inputs, as the APKRun lock records them:

| Component | License | `ships` |
|---|---|---|
| virglrenderer, libepoxy | MIT | app |
| ANGLE | BSD-3-Clause | app |
| ANGLE DEPS: astc-encoder, vulkan-headers | Apache-2.0 | app. No top-level `NOTICE` for astc-encoder. The Vulkan-headers `NOTICE` status is not verified |
| ANGLE DEPS: zlib | Zlib | app |
| PyYAML 6.0.3 | MIT | tooling |
| depot_tools | BSD-3-Clause | tooling |
| RiftVM | MIT | reference |

The RiftVM MIT notice covers RiftVM-authored source only. Renderer libraries, recipe archives, and patches have their own licenses and provenance, and they are not collapsed into the `riftvm` entry. Upstream release documents disagree about which runtime libraries ship. This analysis does not claim which binaries shipped in a RiftVM release.

## 5. File-by-file license and reuse decisions

None of these files has a copyright or license header at the pinned commit, so each falls under the repository-root MIT license. These decisions authorize no copy. A copied or adapted file keeps the MIT notice and the marker `Derived from RiftVM 51f19193b1d3326b2e164d37a2a59e9970375170 (MIT)` ([graphics.md](graphics.md) §2.3).

| Pinned file | APKRun decision |
|---|---|
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/VirtioGPUDevice.swift` | Rewrite in `VirtioDeviceCore` and `GraphicsCore`. Use the command and lifecycle inventory. Do not copy the monolithic class, the single-scanout assumptions, or its error boundary |
| `…/VZVirtioGPUPrototype/VirtioGPUProtocol.swift` | Rewrite the types from the virtio specification with APKRun's checked decoding. Use the command coverage and edge cases as a checklist |
| `…/VZVirtioGPUPrototype/VirGLRenderer.swift` | Adapt the thread-affinity and fence-retirement behavior behind the `GraphicsBridge` C API. Do not import the singleton or its process-global ownership |
| `…/CVirGLBridge/CVirGLBridge.c` | Rewrite against the opaque-handle `gb_*` API. Keep the initialization and synchronization requirements. Validate IOSurface import, Y orientation, and format separately |
| `…/CVirGLBridge/include/CVirGLBridge.h` | Rewrite to the `gb_*` surface. Do not expose RiftVM's ABI |
| `…/CVirGLBridge/ActiveContextSet.h` | Not copied. Reimplement as a tested structure only if the bridge needs it |
| `…/VZVirtioGPUPrototype/RendererExecutor.swift` | Adapt the single-thread EGL ownership rule. Shutdown, cancellation, and polling belong to APKRun's lifecycle |
| `…/VZVirtioGPUPrototype/LatestFrameScheduler.swift` | Adapt the latest-frame coalescing. Test it with the IOSurface pool and the XPC buffer acknowledgement |
| `…/VZVirtioGPUPrototype/RiftVMVirGLRuntime.swift` | Trace the ownership, callback, and shutdown behavior. Reimplement across APKRun's daemon, client, renderer, and wrapper boundaries. Do not copy the process-global ownership or the public API |
| `RiftVM/RiftVM/Core/VMKit/Graphics/VMCustomVirGLGraphics.swift` | Trace the production lifecycle and its recoverable initialization. Reimplement across APKRun's modules. Do not import the app backend |
| `…/VZVirtioGPUPrototype/PrototypeApplication.swift` | Ignore. It is a standalone window that presents in the same process |
| `…/VZVirtioGPUPrototype/VirGLRuntimeDependencies.swift` | Ignore its environment-based discovery. APKRun resolves libraries through its manifest and signed layout |
| `…/VZVirtioGPUPrototype/VirtioInputProbeDevice.swift` | Ignore. Upstream reports that the stock guest does not reach DRIVER_OK with it. APKRun input uses USB and the Guest Agent ([ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md)) |
| `…/VZVirtioGPUPrototypeTests/VirtioGPUProtocolTests.swift` | Use only as a list of test cases. Write APKRun tests with malformed-input and fuzz cases |
| `…/Package.swift`, `…/VZVirtioGPUPrototypeRunner/main.swift` | Ignore. APKRun does not import or build the RiftVM package |
| `scripts/virgl-runtime-pins.sh` | Cross-check of the §4 pins only. Do not source it. APKRun's pins are in the lock, and APKRun does not use RiftVM's prebuilt bottles |
| `scripts/prepare-virgl-sources.sh` | Reference for the patch order (§4). APKRun applies patches through `scripts/tools/build_third_party.py` |
| `scripts/build-virgl-runtime-from-source.sh` | Reference for the §4 flags. APKRun builds from the lock's `buildFlags` |
| `scripts/virgl-patches/virglrenderer-msaa-downgrade.patch` | Copied RiftVM code, shipped as APKRun's `virglrenderer/0002`. The notice rule above applies |
| `Tests/CVirGLBridgeTests/ActiveContextSetTests.c`, `ContextSyncLifecycleTests.c` | Test ideas for APKRun's bridge tests only. Do not copy. The lifecycle test compiles RiftVM's bridge source |
| `Tests/RiftVMCoreTests/VMVirGLPresentationTests.swift` | Test ideas for the presentation tests: late fence invalidation, failure recovery, late completion after stop. Do not copy |
| `RUNTIME_DEPENDENCIES.md`, `ThirdPartyLicenses/virglrenderer.txt` | Sources for the §4 license table only. Not copied. APKRun keeps its own license copies under `ThirdParty/licenses/` |

## 6. Known limitations and TODOs

The inspected sources contain no explicit `TODO` or `FIXME`. The source and its architecture notes document these limitations:

- The static `virtio-input` probe is default-off and is not a working input backend. The guest needs dynamic configuration reads, and the API has no guest config-write callback.
- virglrenderer and ANGLE are process-global in this stack. A `cleanup` followed by initialization in the same process is reported to fail. RiftVM therefore keeps the renderer initialized and reuses it across sequential VMs. APKRun must define and test its own daemon and renderer lifecycle before it adopts this behavior.
- The ANGLE/Metal producer-to-root handoff depends on EGL syncs and an explicit `glFlush`. Server-side `eglWaitSync` does not flush the producer context, so every producer submission ends with `glFlush`. The external winsys does not reliably retire the legacy ctx0 `GLsync`, so ctx0 work is finished explicitly. APKRun's tests must keep these ordering requirements visible.
- The `glReadPixels` diagnostic and the cursor pixel copies must not run on APKRun's normal path.
- Upstream release documents disagree about which runtime libraries ship. Do not use the README or release notes as evidence of artifact provenance.

## 7. Differences APKRun must preserve

| Concern | RiftVM v0.6.1 prototype | APKRun requirement |
|---|---|---|
| Guest workload | Custom VirGL for general Linux VMs and Omarchy; detailed validation is Omarchy/Hyprland | Android ARM64, AOSP Cuttlefish, Mesa VirGL, and SurfaceFlinger. Guest packaging and boot are verified independently |
| Scanouts and capsets | One scanout; one VirGL capset | 16 scanout slots; VirGL and VIRGL2 capsets |
| Display changes | One fixed scanout (ID 0); size and mode changes reported; no connector hotplug | 16 scanout slots; `ScanoutTable` reports enable and mode changes as display events ([graphics.md](graphics.md) §4.3) |
| GPU profiles | One configuration advertises VIRGL and EDID and handles 2D and 3D resource commands | `drmVirgl` advertises VIRGL and EDID. `guestSwiftshader` advertises EDID only and uses a separate 2D backing-copy renderer |
| Presentation ownership | `CAMetalLayer` drawable in the RiftVM process | IOSurface pool owned by apkrund and presented by the wrapper process |
| Device model | One large Swift class owns GPU and presentation state | `VirtioDeviceCore`, `GraphicsCore`, `GraphicsBridge`, RuntimeCore, and WindowingCore boundaries |
| Display model | Scanout 0 only | `DisplayPool` assigns displays dynamically; no fixed app-to-scanout mapping |
| Input | Not implemented by the GPU prototype; the static probe is experimental | USB and VZ input with the Guest Agent ([ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md)); no shell process per event |
| Guest trust | Bounds and logs in a product-specific handler | Every guest value is validated; allocations are bounded; errors are typed; decoders are fuzzed |
| Renderer build | Pinned RiftVM sources and recipe archives; release documents disagree | APKRun's lock, build scripts, reproducibility checks, and notices |
| Save/restore | Disabled for custom VirGL | Disabled while the device is attached (R-07) |
| Resource formats | The device forwards the guest's `format` without an allowlist; the renderer decides | Formats are limited to the renderer's supported set ([graphics.md](graphics.md) §5.4) |
| Renderer inputs | RiftVM's recipe archives and patches, applied by its own scripts, with reference flags | APKRun's lock-listed patch series and `buildFlags` (§4) |
