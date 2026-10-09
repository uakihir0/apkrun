# RiftVM GPU Prototype Analysis

| Field | Value |
|---|---|
| Status | Source analysis complete; maintainer review pending |
| Related | [graphics.md](graphics.md) §2, §5.1–§5.2, §12; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.1; [build-system.md](../05-development/build-system.md) §6; [M02 graphics](../04-plan/issues/M02-graphics.md) #018 |
| Task | #018 |

This is a source review of the `Experiments/VZVirtioGPUPrototype` package, its
production-facing application integration, and the renderer build inputs at
the exact RiftVM commit recorded below. Although the package is under
`Experiments/`, the pinned application links `RiftVMVirGLRuntime` into its
normal Linux VM graphics path. This review therefore covers both the low-level
device/renderer implementation and the production caller's ownership and
lifecycle. It identifies technical patterns that may inform APKRun and records
where APKRun must use its own implementation. No RiftVM code or renderer binary
is copied by #018.

## 1. Source identity and limits of this review

| Item | Pinned value |
|---|---|
| Repository | [`riftvm/riftvm`](https://github.com/riftvm/riftvm) |
| Tag | `riftvm-v0.6.1` |
| Commit | `51f19193b1d3326b2e164d37a2a59e9970375170` |
| Commit date | 2026-09-29 |
| Lock entry | `riftvm` in `ThirdParty/ThirdParty.lock.json`, `kind: source`, `ships: reference`; RiftVM is not built, run as test software, or distributed. Code copied from it is recorded separately (the MSAA patch, IR-410). CI validates the lock metadata and license-file presence; this review manually compared the committed license copy with the pinned source. |
| License | Repository-root MIT license, copied to `ThirdParty/licenses/riftvm/LICENSE` |

The upstream tag list checked on 2026-10-05 contains no `v1.0.4` or
`riftvm-v1.0.4` ref. The selected tag peels to the full commit above. The tag
has no cryptographic signature, and GitHub reports its release as mutable.
The lock therefore identifies the commit directly. This pins the reviewed
content; it does not independently authenticate who published it. The choice
to substitute the available v0.6.1 source for the planned v1.0.4 remains in
[IR-188](../04-plan/implementation-review.md).

RiftVM is an Omarchy-oriented macOS VM product whose maintained architecture
also uses Custom VirGL for general Linux VMs. The prototype README calls its
package an isolated regression harness, but the pinned Xcode project links its
`RiftVMVirGLRuntime` product into the main app and
`VMCustomVirGLGraphicsBackend` constructs and owns that runtime in the normal
VM path. The review covers
[`Experiments/VZVirtioGPUPrototype`](https://github.com/riftvm/riftvm/tree/51f19193b1d3326b2e164d37a2a59e9970375170/Experiments/VZVirtioGPUPrototype),
the production caller
`RiftVM/RiftVM/Core/VMKit/Graphics/VMCustomVirGLGraphics.swift`, the renderer
source/build scripts listed in §4, and the pinned commit's
`docs/CUSTOM_VIRGL_ARCHITECTURE.md` and `docs/VIRGL_PERFORMANCE.md`. Upstream
README and validation statements are attributed to upstream; this task did
not rebuild RiftVM or reproduce those results.

The prototype README reports that its first three gates (device, 2D, and VirGL)
and the stage 4 zero-copy gate passed on macOS 27 beta with Linux/Hyprland
workloads. It describes the stage 6 lifecycle handling without a pass claim. The maintained
architecture and app integration show that the runtime is used by the normal
RiftVM VM path, including general Linux VMs; the detailed end-to-end validation
reported at this commit is specifically for Omarchy/Hyprland. Neither validates
APKRun's Android/Cuttlefish guest, multi-scanout configuration, IOSurface/XPC
handoff, or wrapper-owned windows. The performance report's 60 fps and
0.4–0.8 ms presentation figures are likewise specific upstream observations,
not APKRun measurements.

### 1.1 Production ownership and shutdown order

`VMCustomVirGLGraphicsBackend` validates the runtime libraries, constructs
`RiftVMVirGLRuntime`, and creates the custom-device configurations during
backend initialization. The app then constructs `VZVirtualMachine`, binds it
to the backend, and only then asks the coordinator to start it. If setup throws
before the VM starts, the caller shuts down and discards the backend inside
that recoverable initialization path. Machine save/restore is disabled because
guest RAM alone cannot restore VirGL contexts, resources, fences, or command
state.

On ordinary teardown after the VM has started, the coordinator retains the
backend and its run lease until Virtualization reports a terminal machine state
(`stopped` or `error`). It then shuts down the backend and releases the lease.
The backend stops presentation and clears VM/input callbacks before asking the
runtime to shut down. The runtime first detaches and shuts down the GPU device
so guest resources and delegate work are drained, then calls the renderer's
shutdown method.

That renderer call does **not** tear down the process-global virglrenderer or
ANGLE state. Despite the runtime comment describing cleanup, the pinned
`VirGLRenderer.shutdown()` only cancels pending fences and releases the
renderer lease; the global renderer stays initialized for another VM session,
and ANGLE resources are reclaimed when the app process exits. Treat per-VM GPU
device cleanup and process-wide renderer cleanup as separate lifecycle
boundaries.

## 2. Device and command flow

### 2.1 Custom virtio device and queues

`VirtioGPUDevice.makeConfiguration()` creates virtio device ID 16, PCI class
`0x03` / subclass `0x80`, with a control queue and a cursor queue. It advertises
feature bits 0 and 1 (`VIRTIO_GPU_F_VIRGL` and `VIRTIO_GPU_F_EDID`). Its
16-byte little-endian `virtio_gpu_config` reports one scanout and one capset.
It does not advertise resource blobs or `VIRTIO_GPU_F_CONTEXT_INIT`, and it
does not configure shared-memory regions. The device does not define
`supportsSaveRestore`; the backend reports `supportsMachineSaveRestore = false`
(`VMCustomVirGLGraphics.swift`).

The configuration provider supplies a serial `deviceQueue` to the VZ delegate
provider. `didCreateDevice` stores the device and installs the delegate.
`DidAcceptDriverOk` is used as the point to observe that the stock Linux driver
accepted the standard virtio-gpu identity. Queue notifications drain
`nextElement()` until the queue is empty. Synchronous requests write their
response and return their element; fenced requests retain the element and
return it after the renderer callback. Pause cancels pending presentation
dispatch, resume resubmits a still-valid scanout, and reset/stop release
renderer objects, guest mappings, cursor state, and pending presentation.

The request decoder copies readable descriptor buffers into a bounded `Data`
value (16 MiB maximum) before decoding fields. Unknown commands receive
`ERR_UNSPEC`; invalid queue placement, undersized requests, and invalid
parameters receive an error response. A request that is too short to contain
a header is logged and completed without a response payload. A response write
failure is logged. APKRun still needs its own typed error surface, rate-limited
diagnostics, and exactly-once element ownership API.

The pinned handler's command-level response mapping includes these cases. This
is observed behavior, not an APKRun error-policy recommendation:

| Command path | Observed validation and failure responses |
|---|---|
| Common dispatch | Unknown command: `ERR_UNSPEC`. Wrong queue, undersized request, or invalid parameter: `ERR_INVALID_PARAMETER`. A request shorter than the header is logged and completed without a response payload. |
| 2D/3D resource creation | Invalid dimensions, zero/duplicate resource ID, or resource-count limit: `ERR_INVALID_PARAMETER`. Renderer-budget rejection or renderer create refusal: `ERR_OUT_OF_MEMORY`. |
| `RESOURCE_ATTACH_BACKING` | A short request returns `ERR_INVALID_PARAMETER`; a missing resource returns `ERR_INVALID_RESOURCE_ID`. Existing backing, invalid entry count/length, an undersized entry list, or an unmapped guest range returns `ERR_INVALID_PARAMETER`; budget exhaustion returns `ERR_OUT_OF_MEMORY`; renderer refusal returns `ERR_UNSPEC`. |
| Context creation and resource attachment | `CTX_CREATE` returns `ERR_INVALID_PARAMETER` for a short request, zero/duplicate ID, or capacity exhaustion; renderer refusal returns `ERR_UNSPEC`. For `CTX_ATTACH_RESOURCE`, a short request or unknown context returns `ERR_INVALID_PARAMETER`, and a missing/non-renderer resource returns `ERR_INVALID_RESOURCE_ID`. A valid attach returns `OK_NODATA`; the renderer attach method has no failure result. |
| Context resource detach | `CTX_DETACH_RESOURCE` returns `ERR_INVALID_PARAMETER` for a short request, unknown context, or resource not attached to that context; a missing/non-renderer resource returns `ERR_INVALID_RESOURCE_ID`. A valid detach returns `OK_NODATA`. |
| `SET_SCANOUT` | Nonzero scanout ID: `ERR_INVALID_SCANOUT_ID`; unknown resource: `ERR_INVALID_RESOURCE_ID`; a rectangle outside the resource: `ERR_INVALID_PARAMETER`. Resource ID zero clears the active binding and returns success. |
| `RESOURCE_FLUSH` | An invalid rectangle returns `ERR_INVALID_PARAMETER`. A flush with no matching active scanout, or before the renderer texture exists, returns success without presenting; a later flush retries the texture borrow. |

The attach and context mappings above are from the pinned
[`VirtioGPUDevice.swift`](https://github.com/riftvm/riftvm/blob/51f19193b1d3326b2e164d37a2a59e9970375170/Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/VirtioGPUDevice.swift#L864-L981).

### 2.2 Commands, resources, and backing

`VirtioGPUProtocol.swift` contains little-endian wire decoding and the
command/response enums. The device handles display info, EDID, VirGL capset
queries, 2D and 3D resource creation, resource attach/detach/unref, contexts,
3D submission and transfers, scanout, flush, and cursor update/move. The
implementation supports only scanout 0 and capset index 0. In particular, its
single-scanout implementation is not the 16-scanout device specified by
APKRun's §4.1.

On a guest mode switch, `SET_SCANOUT` with resource ID zero clears the active
resource/rectangle and cancels queued presentation. The host view keeps its
last successfully published drawable visible until a later flush supplies a
replacement; unref of a borrowed scanout likewise stops borrowing the released
resource while retaining the last drawable. Device reset or shutdown is the
separate boundary that releases device state. The pinned device tracks display
events for its one scanout, but has no multi-scanout topology to reconcile.

`RESOURCE_ATTACH_BACKING` maps each guest physical range with
`guestMemoryMapping(atPhysicalAddress:length:)`. The resource retains the
`VZGuestMemoryMapping` objects and an `iovec` array while attached. The
implementation bounds the entry count and byte budgets before handing backing
to virglrenderer; detach and device reset release those mappings. APKRun must
keep the mapping lifetime and checked-arithmetic rules in
[graphics.md](graphics.md) §3.2 and §4.4, and add the project-required full
guest-range, resource-size, and state validation.

The pinned limits in `VirtioGPUProtocol.Limits` are:

| Limit | RiftVM v0.6.1 prototype |
|---|---:|
| Request size | 16 MiB |
| `SUBMIT_3D` payload | 8 MiB |
| Texture width or height | 8192 px |
| 3D resource texels | 256 Mi |
| `PIPE_BUFFER` width | 256 MiB |
| Renderer-resource admission budget | 4 GiB total |
| Resource count | 4096 |
| Context count | 256 |
| 2D resource pixel storage | 256 MiB each; 512 MiB total |
| Backing entries | 4096 per attach |
| Guest backing bytes | 1 GiB per resource; 4 GiB total |
| Cursor dimensions | 256 × 256 px |

Other 3D constraints include depth and array size at most 2048, mip level at
most 15, and sample count at most 16. For `PIPE_BUFFER` target 0, width is
treated as a byte count rather than a texture edge. These are observations of
this tag, not proposed replacements for APKRun's independently specified
limits in [graphics.md](graphics.md) §5.4.

The 4 GiB renderer-resource budget is applied to an estimate, not enforced by
the renderer as a hard allocation ceiling. `estimatedRendererResourceBytes`
uses 4 bytes per texel for the expected R8G8B8A8/B8G8R8A8 workload, multiplies
by at least one and otherwise the declared sample count, and doubles the
estimate when a mip chain is present; `PIPE_BUFFER` uses its byte width
directly. The source notes that
texture formats can use up to 16 bytes per texel, so the 4-byte estimate can
undercount other accepted formats. Do not treat this upstream workload
heuristic as a conservative worst-case memory bound or as an APKRun limit.

`UPDATE_CURSOR` snapshots pixels into host memory and creates a `CGImage`.
Renderer-backed cursor resources use `transfer_read` before that copy. The
cursor is therefore outside the zero-readback normal scanout path. The
prototype caps cursor images at 256 × 256 and accepts cursor operations only
for scanout 0.

### 2.3 VirGL, fences, and scanout

`VirGLRenderer.swift` owns the renderer calls and obtains capset 1. The C
bridge dynamically loads virglrenderer, ANGLE EGL, and GLES entry points.
`virgl_renderer_init` uses callback version 4 and **flags `0`**, with fence,
GL-context create/destroy, make-current, and EGL-display callbacks. Although
the bridge defines EGL/GLES-related flag constants, the observed initialization
does not pass them. On macOS the pinned Meson logic (`with_host_darwin`) sets `have_egl`
whenever libepoxy reports EGL and does not set `ENABLE_GBM`. The GBM, Linux
parts of the EGL winsys are therefore compiled out, and `-Ddrm-renderers=[]`
excludes the DRM path. The renderer uses the supplied ANGLE context callbacks.
This was read from the Meson files; the build was not run.

There is no `CONTEXT_INIT`, so the guest exposes a single fence timeline.
virglrenderer may retire per-context fences out of order; the host assigns
nonzero host fence IDs and `VirtioGPUOrderedCompletions` delays queue-element
completion until earlier guest submissions are ready. The renderer executor
polls while fences are pending, backing off from 1 ms to 4 ms. A fence that
does not complete within 2 seconds fails.

On `RESOURCE_FLUSH`, the prototype borrows the renderer's scanout GL texture.
Before presenting from its shared root context, it queues EGL server-side waits
on producer-context syncs. It wraps the destination `MTLTexture` in an
`EGLImage` using `EGL_METAL_TEXTURE_ANGLE`, attaches source and destination
textures to framebuffers, and performs a GPU `glBlitFramebuffer`. The normal
scanout path does not copy pixels through Swift `Data` or `CGImage` and does
not use an IOSurface pool.

The observed blit passes increasing source and destination Y coordinates; the
call does not express an explicit vertical reversal. It also uses the source
VirGL texture and ANGLE's Metal-texture import without a separate pixel
conversion step. APKRun's planned IOSurface blit still needs to verify its Y
orientation and channel layout with the #023 fixture tests; the RiftVM result
does not settle those details.

When `RIFTVM_VIRGL_DIAGNOSTICS=1`, the C bridge performs a small synchronous
`glReadPixels` sample periodically to produce a scanout signature. The
non-zero-copy fallback and cursor path also use CPU-side pixel data. These
paths are not evidence that APKRun may read back during normal presentation;
APKRun's normal-path readback counter must remain zero.

### 2.4 Flow-step crosswalk

[graphics.md](graphics.md) §2.2 lists the flow steps that this analysis must
answer. The table maps each step to the section that answers it and to the
pinned files that implement it. Names are the identifiers used in the pinned
source.

| Flow step | Answered in | Pinned files |
|---|---|---|
| `VZCustomVirtioDevice` | §2.1: `VZCustomVirtioDeviceConfiguration` fields (device ID, PCI class, two queues, features `subset0 = 3`, device-specific config), the delegate callbacks `didCreateDevice`, `customVirtioDeviceDidAcceptDriverOk`, pause and resume, reset and stop, and the serial `deviceQueue` | `VirtioGPUDevice.swift`; `RiftVMVirGLRuntime.swift` (`makeDeviceConfigurations`) |
| virtqueue handling | §2.1: the drain loop on `nextElement()`, synchronous and fenced `returnToQueue`, the 16 MiB request bound, and error logging | `VirtioGPUDevice.swift` |
| virtio-gpu commands | §2.2: command coverage, error responses for unknown, short, and invalid requests, and the response table | `VirtioGPUProtocol.swift` (command and response enums, length checks); `VirtioGPUDevice.swift` (dispatch) |
| resource creation | §2.2: 2D and 3D creation paths, limits, and budget refusal. The device forwards the guest's `format` to the renderer without its own allowlist, so formats are checked only by the renderer (§7) | `VirtioGPUDevice.swift`; `VirtioGPUProtocol.swift` (`Limits`) |
| resource backing | §2.1: `guestMemoryMapping` lifetime and release on detach, reset, and stop; §2.2: `RESOURCE_ATTACH_BACKING` checks and limits | `VirtioGPUDevice.swift` |
| VirGL | §2.3: `virgl_renderer_init` with callback version 4 and flags `0`, capset 1, fence polling from 1 ms to 4 ms, and the 2-second timeout; §1.1 and §5: renderer lifecycle | `VirGLRenderer.swift`; `RendererExecutor.swift`; `CVirGLBridge.c` |
| scanout | §2.2: `SET_SCANOUT` clear and error paths; §2.3: `RESOURCE_FLUSH`, texture borrowing, the blit, and its Y orientation | `VirtioGPUDevice.swift`; `CVirGLBridge.c` |
| ANGLE | §3: Metal EGL platform, root context, and context sharing; §2.3: `EGL_METAL_TEXTURE_ANGLE` import and the producer sync. The prototype's `MTLCreateSystemDefaultDevice()` assignment is not shown to be ANGLE's device (§3) | `CVirGLBridge.c`; `PrototypeApplication.swift` |
| Metal | §2.3 and §3: GPU ordering with an explicit `glFlush` and `LatestFrameScheduler` pacing; §3.1: production drawable acquisition, presentation into `drawable.texture`, occlusion, and the stale-completion rules | `CVirGLBridge.c`; `LatestFrameScheduler.swift`; `VMCustomVirGLGraphics.swift` |
| cursor | §2.2: `UPDATE_CURSOR` and `MOVE_CURSOR`, the 256 × 256 px cap, scanout 0 only, and the host-memory copy that stays outside the scanout path | `VirtioGPUDevice.swift`; `VirtioGPUProtocol.swift` (`Limits.maxCursorDimension`) |

## 3. ANGLE initialization and presentation

`CVirGLBridge.c` loads `libEGL.dylib` and `libGLESv2.dylib` beside the
virglrenderer library. EGL initialization uses:

1. `eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, …)`
   with `EGL_PLATFORM_ANGLE_TYPE_ANGLE = EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE`;
2. `eglInitialize` and `eglBindAPI(EGL_OPENGL_ES_API)`;
3. one config with a pbuffer surface, GLES 2/3 renderability, and 8-bit
   RGBA channels;
4. a 1 × 1 pbuffer and a root GLES context. VirGL contexts share with the
   root context when the callback requests sharing.

`PrototypeApplication.swift` assigns `MTLCreateSystemDefaultDevice()` to its
`CAMetalLayer`. The examined prototype does not establish APKRun's designed
contract that IOSurface textures use the exact `MTLDevice` reported by ANGLE.
APKRun keeps that contract in [graphics.md](graphics.md) §5.2 and verifies it
on its own renderer path.

`LatestFrameScheduler.swift` allows one presentation callback in flight and
retains only the newest pending frame while delivery is outstanding. It
counts submitted, delivered, and coalesced frames. The callback returns to the
device queue before the next frame is dispatched. This is a useful bounded
queue policy; APKRun must connect it to its `SurfacePool`, sequence numbers,
XPC frame ownership, and wrapper acknowledgement rules.

### 3.1 Production drawable presentation

`VMCustomVirGLGraphics.swift`, the production caller, presents each scanout
under a single-flight rule:

- A presentation starts only when demand is pending and none is in flight.
  Damage received while a presentation is busy stays pending, and completion
  drains it, so a guest that stops submitting frames still gets its last
  update.
- The drawable is acquired on `drawableAcquirer`, which calls
  `CAMetalLayer.nextDrawable()` and records the wait. A nil drawable counts as
  a miss, schedules a retry, and presents nothing.
- The scanout is blitted with `runtime.presentAsync(...)` into
  `drawable.texture`. Completion returns to the main queue. The result is
  discarded if the presentation token is stale, if the view is occluded
  (`canPresentFrames`), or if the display activity generation changed. In the
  last case the drawable is dropped and the latest scanout is presented again.
  `drawable.present()` is called only after a successful blit.
- While the window is occluded, the live scanout is kept, but no drawables are
  acquired and the presentation timer is not woken (`refreshPresentationActivity`).
  Restoration presents the newest scanout even without a new `RESOURCE_FLUSH`.
- Success and failure feed a presentation health window
  (`recordPresentationResult`). Frame durations, drawable waits, and drawable
  misses are counted per window. These are the kinds of markers that APKRun
  must record ([diagnostics.md](diagnostics.md) §4.2).

## 4. Renderer sources, patches, and build flags

The source pins in RiftVM's `scripts/virgl-runtime-pins.sh` match the initial
virglrenderer, libepoxy, and ANGLE source revisions already named in
[graphics.md](graphics.md) §5.1. The build recipes and flags are RiftVM's
reference values, not automatic changes to APKRun's own build commands.

| Input | Source identity | Recipe identity and patch input |
|---|---|---|
| virglrenderer | `960bd6674a25a438da2aac8a0af8c6d6e2b3a77e`; source archive SHA-256 `b7b9aaa05b10765c244790b2f2580e34e7cee383b4419ce5dd0c111d59e464a3` | RiftVM recipe `20828ebf629191f4d48993ada3e631e6f92532c1`; recipe archive SHA-256 `afb58a118a11cabf381b1e53e155b0bb07d995ffb3cbfeb09decfb723cd41e1a`; applies `virglrenderer-macos-unified.patch` and RiftVM's `virglrenderer-msaa-downgrade.patch` |
| libepoxy | `1b6d7db184bb1a0d9af0e200e06a0331028eaaae`; source archive SHA-256 `15f769a8f24c361c8de28d72625daf07d0107b683fa0a5118d0aa8b0c5fc9eab` | RiftVM recipe `eeb72845c15eeb9a57635fc54467234b2e38f51a`; recipe archive SHA-256 `2385e015283816237615c3933b58c174ca8fd55be351a56799cdfeb656b6f789`; applies `libepoxy-akihikodaki-egl15.patch` |
| ANGLE | `2d91f554ab55bd1bef6998ab4094f60ae3e7feb5`; source archive SHA-256 `c24c4e7bc464a63069b67a9f663717b6e0f4a5ff4b6404215a7dc98ea83c6ba7` | RiftVM recipe `b010ac372569747a4b265e75eaa72868c6849f62`; recipe archive SHA-256 `076df85af0f3bcd5d1232be7285bdb0bc305f28df155bc5ac6d19e83e27e3195`; applies `angle-changes-main.patch` |
| ANGLE build helper | depot_tools `f70835271105ca56d2cd5382a0118152bc2bdeea` | Checked out at that commit; ANGLE DEPS synchronized with that pinned ANGLE revision |

The current APKRun patches reconcile with those recipe inputs as follows.
“Adopted” describes the #020 working patch set. Their application, clean
renderer build, cache reuse, and tests are recorded in
[graphics.md](graphics.md) §16 and IR-191; #018 itself did not repeat the build.
On 2026-10-10 #018 checked each row against the pinned upstream files. The
virglrenderer and ANGLE rows were checked by applying the patch sequences to the
pinned source files; the libepoxy rows by comparing their added lines. The
“Verified relation” column records the result.

| APKRun patch | RiftVM counterpart (pinned) | Verified relation to the counterpart (#018, 2026-10-10) | Purpose and #020 disposition |
|---|---|---|---|
| `virglrenderer/0001-add-macos-metal-support.patch` | `virglrenderer-macos-unified.patch` (recipe `20828ebf`, applied first by `scripts/prepare-virgl-sources.sh`) | Not byte-identical. The recipe file has two diffs for `src/vrend/vrend_renderer.h`; APKRun's file has one, so it is a regenerated form of the recipe patch (IR-190). Applying the recipe patch and RiftVM's MSAA patch to the pinned source, and APKRun `0001` and `0002` to a second copy, gives identical source trees. The only other difference is three `.orig` backups left by the recipe run. | Adopted. Carries the macOS Metal and Objective-C build and renderer path. The patch also contains broader Venus-related source changes; APKRun configures `venus=false` and does not expose the Vulkan guest feature. |
| `virglrenderer/0002-downgrade-unsupported-msaa.patch` | `scripts/virgl-patches/virglrenderer-msaa-downgrade.patch` in RiftVM `51f19193`, applied after the recipe patch. This file is in the RiftVM repository, not in the recipe archive | The added lines equal the pinned file's, apart from blank-line placement. The header says it was carried from RiftVM `f615e16` (MIT), an earlier commit whose author matches the patch's `From:` line. The pinned commit is therefore not the recorded origin, and the code is RiftVM-authored (IR-410). | Adopted. Falls back to single-sample storage when the GLES host cannot multisample a format; rendering can continue with antialiasing lost. |
| `virglrenderer/0003-link-metal-runtime.patch` | None | Not a counterpart. An APKRun downstream addition; its header states that it is not submitted upstream. | Adopted as an APKRun downstream addition. Links CoreFoundation and the Objective-C runtime for the non-Venus Metal build. |
| `libepoxy/0001-improve-library-detection.patch` | `libepoxy-akihikodaki-egl15.patch` (recipe `eeb72845`), first of its three patches | Same as the counterpart, except that the dylib names are `@rpath/libEGL.dylib` and `@rpath/libGLESv2.dylib`, where the recipe uses bare names. This is the `@rpath` install-name rule of IR-190. | Adopted. Resolves bundled ANGLE EGL/GLES dylibs and enables EGL on Apple platforms. |
| `libepoxy/0002-disable-desktop-extensions-on-gles.patch` | `libepoxy-akihikodaki-egl15.patch`, second patch | Same added lines as the counterpart. | Adopted. Keeps desktop GL extension providers from selecting the wrong unsuffixed entry point for GLES. |
| `libepoxy/0003-enable-egl-platform-display.patch` | `libepoxy-akihikodaki-egl15.patch`, third patch | Same added lines as the counterpart. | Adopted. Checks the EGL client version so `eglGetPlatformDisplay` can be resolved before a display exists. |
| `angle/0001-fix-metal-boolean-mix.patch` | `angle-changes-main.patch` (recipe `b010ac37`) | Same as the counterpart, except for one omitted hunk. The recipe also changes `src/libANGLE/renderer/vulkan/VertexArrayVk.cpp` (the argument of `padVertexAttribBufferSizeIfNeeded`). The Vulkan backend is excluded when `angle_enable_vulkan=false`, whose `renderer/vulkan/BUILD.gn` asserts that flag. Applied to the pinned source files they touch, the two sequences differ only at that line (IR-411). | Adopted. Emits Metal `select` for boolean-selector `mix` operations and raises the Metal shader UBO limit from 12 to 16. |

The recipe archives contain further patches that RiftVM's
`scripts/prepare-virgl-sources.sh` does not apply, and APKRun does not apply
either. Examples are `venus-*`, `bgra-*`, `angle-egl-include.patch`,
`virglrenderer-borrow.patch`, `vrend-error-reporting.patch`, and
`libepoxy-changes-main.patch`. The script applies only the inputs named in the
table, in this order: the virglrenderer recipe patch, every
`scripts/virgl-patches/virglrenderer-*.patch`, the ANGLE recipe patch, and the
libepoxy recipe patch.

RiftVM's reference configure/build arguments, from
`scripts/build-virgl-runtime-from-source.sh` at the pinned commit, are:

| Component | Observed arguments |
|---|---|
| ANGLE | GN: `target_cpu="arm64"`, `angle_build_all=false`, `is_debug=false`, `symbol_level=0`, `angle_has_frame_capture=false`, `angle_enable_gl=false`, `angle_enable_vulkan=false`, `angle_enable_swiftshader=false`, `angle_enable_wgpu=false`, `angle_enable_metal=true`, `angle_enable_null=false`, `angle_enable_abseil=false`, `use_siso=false`, `use_system_xcode=true`, `use_custom_libcxx=false`, `use_lld=false`, `is_component_build=false`, `treat_warnings_as_errors=false`, `fatal_linker_warnings=false`; builds `libEGL` and `libGLESv2` |
| libepoxy | Meson: `-Degl=yes -Dx11=false -Dtests=false`; `PKG_CONFIG_PATH` points at the pinned ANGLE EGL/GLES metadata |
| virglrenderer | Meson: `-Ddrm-renderers=[] -Dvenus=true -Dtests=false -Dvideo=false -Dtracing=none`; adds the ANGLE include directory and a native Python path; `PKG_CONFIG_PATH` includes ANGLE and libepoxy |

The arguments that #020 actually passes are the `buildFlags` of the lock
entries, which `scripts/tools/build_third_party.py` passes verbatim to GN and
Meson, plus the builder's own `--prefix`, `--libdir=lib`, and `--native-file`
options. The differences from RiftVM are:

| Component | APKRun #020 arguments (lock `buildFlags`) | Difference from RiftVM |
|---|---|---|
| ANGLE | GN: the nineteen RiftVM arguments above, plus `mac_deployment_target="27.0"` | Adds `mac_deployment_target="27.0"` (IR-413). The three ANGLE DEPS components of the Metal graph are listed in the lock (`angle-astc-encoder` `2319d9c4`, `angle-vulkan-headers` `c0fe12c8`, `angle-zlib` `e00f7038`). They equal ANGLE's `DEPS` revisions at the pinned commit (checked on 2026-10-10). The builder still runs `gclient sync` in its work area and checks only the ANGLE root commit, and it checks the GN graph against the locked notice entries (IR-190, IR-191) |
| libepoxy | Meson: `-Degl=yes -Dglx=no -Dx11=false -Dtests=false` | Adds `-Dglx=no` (IR-413) |
| virglrenderer | Meson: `-Dplatforms=egl -Ddrm-renderers=[] -Dvenus=false -Dtests=false -Dvideo=false -Dtracing=none` | Adds `-Dplatforms=egl` (IR-413). On macOS RiftVM's default `platforms=auto` also selects EGL when libepoxy reports it, so the flag changes the failure mode (missing EGL becomes a build error), not the compiled winsys (read from `meson.build`; not built). `venus=false` (IR-190). RiftVM passes an ANGLE include path through `-Dc_args` and `-Dcpp_args`; APKRun gives ANGLE and libepoxy to Meson through generated pkg-config files (`PKG_CONFIG_PATH`). Python is the locked PyYAML 6.0.3, visible only to this Meson process (IR-190), not RiftVM's Python native file |

The `-Dvenus=true` renderer build option is not guest Vulkan support. The
prototype still advertises only VIRGL and EDID and does not advertise resource
blobs; APKRun's Vulkan track remains #096.

The recipe patch archives are checksum-pinned. The crosswalk above records
their correspondence to the patch files already listed as adopted in
[graphics.md](graphics.md) §5.1. The #020 verification is evidence that the
current patch series builds against the pinned sources; this analysis did not
rebuild the libraries.

RiftVM lists virglrenderer and libepoxy as MIT and ANGLE as BSD-3-Clause in
its runtime dependency documentation. Those components are not covered by the
single RiftVM MIT lock entry: APKRun must keep their own source pins, recipe
patch provenance, and license notices when #020 implements the runtime build.
The renderer components and their licenses, as the APKRun lock records them
(`scripts/check-lock.sh` passed on 2026-10-10), are:

| Component | License (lock) | `ships` | Legal list ([legal-and-licensing.md](../05-development/legal-and-licensing.md) §4) |
|---|---|---|---|
| virglrenderer | MIT (`COPYING`) | `app` | app list (§4.2) |
| libepoxy | MIT (`COPYING`) | `app` | app list (§4.2) |
| ANGLE | BSD-3-Clause (`LICENSE`) | `app` | app list (§4.2) |
| ANGLE DEPS: `angle-astc-encoder`, `angle-vulkan-headers` | Apache-2.0 (`LICENSE.txt`; `vulkan-headers/LICENSE.txt`) | `app` | app list. Neither lock entry lists a `NOTICE` file. The astc-encoder commit has none at the top level (checked on GitHub). The Vulkan-headers commit is in Chromium's `vulkan-deps` repository, which #018 could not reach, so its `NOTICE` status is not verified |
| ANGLE DEPS: `angle-zlib` | Zlib (`LICENSE`) | `app` | app list (§4.2) |
| PyYAML 6.0.3 | MIT (`LICENSE`) | `tooling` | tooling list (§4.4) |
| depot_tools | BSD-3-Clause (`LICENSE`) | `tooling` | tooling list (§4.4) |
| RiftVM | MIT (`LICENSE`) | `reference` | none shipped. The carried MSAA patch is an exception; see the §4 patch table and IR-410 |

Patches are under the license of the component they change
([legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.2).

The RiftVM MIT notice applies to RiftVM-authored source, not automatically to
the renderer sources or recipe patches. The carried MSAA patch is the one
exception: its code is RiftVM-authored and is shipped in APKRun's virglrenderer
(IR-410). Keep the patch-origin records and
component license notices separate; the repository's legal review still
covers the complete third-party package before release.

The upstream `THIRD_PARTY_NOTICES.md` says the release packager still consumes
bootstrap binaries while source-built libraries are being qualified. In the
same pinned commit, `Experiments/VZVirtioGPUPrototype/RUNTIME_DEPENDENCIES.md`
describes a source-qualified release path and `scripts/build-release.sh`
builds the source runtime when no explicit source directory is supplied.
Because these statements differ, this analysis reports source and recipe
identities from the pinned scripts but does not claim which binaries shipped
in a public RiftVM release.

## 5. File-by-file license and reuse decisions

The files listed below (source, tests, and build scripts) have no individual
copyright or license header at the pinned commit. #018 checked each one on
2026-10-10. Their license is the repository-root MIT license. The
license text is preserved in `ThirdParty/licenses/riftvm/LICENSE`. These
decisions authorize no code copy by #018; any later copied or adapted file
must keep the required MIT notice and the full
`Derived from RiftVM 51f19193b1d3326b2e164d37a2a59e9970375170 (MIT)` marker
([graphics.md](graphics.md) §2.3).

| Pinned file | Flow step | License observed | APKRun decision |
|---|---|---|---|
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/VirtioGPUDevice.swift` | Device callbacks, queues, command dispatch, resources, backing, scanout, cursor, reset | No file header; repository MIT | Rewrite within `VirtioDeviceCore` and `GraphicsCore`. Use the command/lifecycle inventory, but do not copy the monolithic AppKit-facing class, single-scanout assumptions, or its error/API boundary. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/VirtioGPUProtocol.swift` | Wire values, command IDs, length checks, limits, EDID and response encoding | No file header; repository MIT | Rewrite protocol types from the virtio specification and APKRun's checked-decoding rules. Use the observed command coverage and edge cases as review input. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/VirGLRenderer.swift` | Library calls, capset 1, resources, contexts, transfers, scanout texture, fences | No file header; repository MIT | Adapt thread-affinity and fence-retirement behavior behind APKRun's narrow `GraphicsBridge` C API. Do not import the singleton class or its process-global ownership into `GraphicsCore`. |
| `Experiments/VZVirtioGPUPrototype/Sources/CVirGLBridge/CVirGLBridge.c` | Renderer ABI, ANGLE/EGL initialization, callbacks, GL sync and scanout blit | No file header; repository MIT | Rewrite against the project's opaque-handle C boundary. Preserve the verified initialization and synchronization requirements; separately validate IOSurface import, Y orientation, and format. |
| `Experiments/VZVirtioGPUPrototype/Sources/CVirGLBridge/include/CVirGLBridge.h` | C ABI exposed to Swift | No file header; repository MIT | Rewrite to APKRun's documented `gb_*` surface and opaque renderer handle; do not expose RiftVM's ABI. |
| `Experiments/VZVirtioGPUPrototype/Sources/CVirGLBridge/ActiveContextSet.h` | Tracks GL contexts with pending producer syncs | No file header; repository MIT | Reimplement or replace with a tested data structure if the APKRun bridge needs this optimization. It is not required as a copied file. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/RendererExecutor.swift` | Dedicated renderer thread and serialized calls | No file header; repository MIT | Adapt the single-thread EGL ownership rule to `GraphicsCore`; own shutdown, cancellation, and polling in APKRun's lifecycle. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/LatestFrameScheduler.swift` | Bounded presentation dispatch | No file header; repository MIT | Adapt latest-frame coalescing, then test it with APKRun's IOSurface pool and XPC buffer-acknowledgement state machine. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/RiftVMVirGLRuntime.swift` | Production-facing owner of the GPU device, renderer, and ANGLE/Metal callbacks; also exposes the runtime API used by RiftVM's app backend | No file header; repository MIT | Trace its runtime ownership, callback surface, and shutdown behavior. Reimplement them across APKRun's `apkrund`, `RuntimeClient`, `GraphicsCore`, and wrapper boundaries; do not copy RiftVM's process-global ownership model or public API. |
| `RiftVM/RiftVM/Core/VMKit/Graphics/VMCustomVirGLGraphics.swift` | Production app integration: constructs the renderer before VM creation, supplies custom device configurations, binds the VM view, owns presentation/input callbacks, disables machine save/restore, and shuts down the runtime | No file header; repository MIT | Trace this production lifecycle and its recoverable initialization boundary. Reimplement the integration across APKRun's `RuntimeCore`, `GraphicsCore`, `RuntimeHost`, and wrapper boundaries; do not import the app-specific backend. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/PrototypeApplication.swift` | Standalone AppKit window and `CAMetalLayer` | No file header; repository MIT | Ignore. It presents in the same app process and does not implement APKRun's wrapper-owned window or IOSurface/XPC path. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/VirGLRuntimeDependencies.swift` | Finds the external renderer dylibs for the experiment | No file header; repository MIT | Ignore its environment-based app-bundle discovery; APKRun resolves libraries through its package/build manifest and signed app layout. |
| `Experiments/VZVirtioGPUPrototype/Sources/VZVirtioGPUPrototype/VirtioInputProbeDevice.swift` | Default-off static virtio-input experiment | No file header; repository MIT | Ignore for #018. Upstream documents that the stock guest does not reach `DRIVER_OK`; APKRun input remains the USB/Guest Agent path in ADR-0013. |
| `Experiments/VZVirtioGPUPrototype/Tests/VZVirtioGPUPrototypeTests/VirtioGPUProtocolTests.swift` | Upstream protocol and helper tests | No file header; repository MIT | Use test cases as review prompts only; rewrite tests under APKRun modules and add the project's malformed-input and fuzz cases. |
| `Experiments/VZVirtioGPUPrototype/Package.swift` and `Sources/VZVirtioGPUPrototypeRunner/main.swift` | Experiment package and runner | No file header; repository MIT | Ignore package and runner structure; APKRun does not import or build the RiftVM package. |
| `scripts/virgl-runtime-pins.sh` | Source and recipe pins: commits, archive SHA-256 values, and the bottle identities of prebuilt binaries | No file header (a comment only); repository MIT | Use as a cross-check of the §4 pins. Do not source it: APKRun's pins are in `ThirdParty.lock.json`. APKRun does not use the prebuilt bottles (virglrenderer 1.0.33, ANGLE 1.0.15, libepoxy 1.0.4). |
| `scripts/prepare-virgl-sources.sh` | Patch order: the virglrenderer recipe patch, then `scripts/virgl-patches/virglrenderer-*.patch`, then the ANGLE and libepoxy recipe patches | No file header; repository MIT | Reference for the patch order in §4. Ignore the script; APKRun applies patches through `scripts/tools/build_third_party.py`. |
| `scripts/build-virgl-runtime-from-source.sh` | ANGLE GN arguments, Meson arguments, `gclient sync`, install names, and link order | No file header; repository MIT | Reference for the flags in §4. Ignore the script; APKRun builds from the lock's `buildFlags`. |
| `scripts/virgl-patches/virglrenderer-msaa-downgrade.patch` | The MSAA downgrade code, which APKRun ships as `virglrenderer/0002` | No file header; the added code is RiftVM-authored (its comments say "RiftVM:") | Copied RiftVM code in APKRun's patch set. See IR-410 for the notice and classification. |
| `Tests/CVirGLBridgeTests/ActiveContextSetTests.c`; `Tests/CVirGLBridgeTests/ContextSyncLifecycleTests.c` | Unit tests of `ActiveContextSet.h`; renderer lifecycle tests with deterministic EGL and renderer callbacks. The second file includes `CVirGLBridge.c` directly | No file header; repository MIT | Review prompts for the #020 and #022 bridge tests. Do not copy: the lifecycle test compiles RiftVM's bridge source. |
| `Tests/RiftVMCoreTests/VMVirGLPresentationTests.swift` | Presentation and lifecycle tests of the custom VirGL path: late fence invalidation, failure recovery, late completion after stop, and backend selection | No file header; repository MIT | Review prompts for the #023 presentation tests. Do not copy. |
| `Experiments/VZVirtioGPUPrototype/RUNTIME_DEPENDENCIES.md`; `ThirdPartyLicenses/virglrenderer.txt` | Upstream statements of the runtime licenses (MIT for virglrenderer and libepoxy, BSD-3-Clause for ANGLE) and the upstream virglrenderer license text | Documentation and license text; repository MIT | Evidence for the §4 license table only. Not copied. APKRun keeps its own license copies under `ThirdParty/licenses/`. |

### Production VM and renderer lifetime

`VMCustomVirGLGraphicsBackend.init` creates `RiftVMVirGLRuntime` and its
Virtualization device configurations before a `VZVirtualMachine` exists, so
initialization errors can still be handled by the backend factory. The app's
`OmarchyVirtualMachineRepresentable.makeNSView` then creates the VM, binds it
to the backend, and only afterward asks the coordinator to start it. During
teardown, `OmarchyMachineCoordinator.stopImmediately` retains the backend while
Virtualization stops the VM; it calls `backend.shutdown()` only after the VM
reaches `.stopped` or `.error`. If no VM was created, it shuts down the backend
directly.

`RiftVMVirGLRuntime.shutdown()` first shuts down the GPU device and then the
renderer. The renderer's shutdown cancels pending fences and releases its
process-global renderer lease, but deliberately leaves the shared
virglrenderer/ANGLE instance initialized: the pinned stack does not support
teardown followed by reinitialization in the same process. The runtime source's
shutdown comment says ANGLE/VirGL is cleaned up, but `VirGLRenderer.shutdown()`
documents the narrower behavior; the OS reclaims that process-global state when
RiftVM exits. Thus per-VM guest resources are retired after Virtualization
stops, while the renderer itself is retained for reuse until process exit.

The MIT license above applies to RiftVM-authored source only. The renderer
libraries, Homebrew build recipes, and their patches have their own licenses
and provenance. APKRun must not attribute them to RiftVM's MIT license or
collapse them into this lock entry.

## 6. Known limitations and TODOs

No explicit `TODO` or `FIXME` marker was found in the inspected prototype
sources. The source and its maintained architecture notes do document these
limitations:

- The static `virtio-input` probe is default-off and is not a working input
  backend. The guest driver needs dynamic configuration reads, but the macOS
  27 beta API has no guest config-write callback; upstream reports that the
  stock Omarchy guest does not reach `DRIVER_OK`. APKRun ignores this probe.
- virglrenderer and ANGLE are process-global in this pinned stack. A
  `cleanup` followed by a second initialization in the same process is
  reported to fail; RiftVM keeps the renderer initialized and reuses it for
  sequential VM sessions. The app waits for the VM to reach a terminal state
  before releasing its per-VM backend, but that backend shutdown releases only
  the singleton renderer lease; it does not uninitialize VirGL or ANGLE.
  APKRun must define and test its own daemon and renderer lifecycle before
  adopting that behavior.
- The ANGLE/Metal producer-to-root-context handoff depends on EGL syncs and
  an explicit `glFlush`. The C bridge says that the presenter's server-side
  `eglWaitSync` never flushes the producer context, so every producer
  submission ends with `glFlush`. It also says that the external ANGLE/Metal
  winsys does not reliably retire the legacy ctx0 `GLsync`, so ctx0 work is
  finished explicitly. Keep the producer fence and ordering requirements
  visible in the #020/#023 tests.
- The optional content-signature diagnostic uses synchronous `glReadPixels`,
  and cursor updates copy pixels to host memory. Neither belongs in APKRun's
  normal scanout path.
- The upstream release-notice file and source-build/release documents disagree
  about which runtime libraries are packaged. Do not use the README or
  release notes alone as evidence of artifact provenance.

## 7. Differences APKRun must preserve

| Concern | RiftVM v0.6.1 prototype | APKRun requirement |
|---|---|---|
| Guest workload | Custom VirGL is used by general Linux VMs and Omarchy; the detailed end-to-end validation is Omarchy/Hyprland | Android ARM64, AOSP Cuttlefish, Mesa VirGL and SurfaceFlinger; guest packaging and boot must be independently verified |
| Scanouts and capsets | One scanout and one VirGL capset | 16 scanout slots and the project-defined VirGL/VIRGL2 behavior |
| Display changes | One fixed scanout (ID 0); host-requested size/mode changes are reported for it, with no connector-topology hotplug | 16 fixed scanout slots; `ScanoutTable` reports enable/mode changes through display events, with config-interrupt behavior still under R-01/#028 verification |
| GPU profiles | One device configuration advertises VIRGL and EDID and handles both 2D and 3D resource commands | `drmVirgl` advertises VIRGL + EDID; `guestSwiftshader` advertises EDID only and uses a separate host 2D backing-copy renderer. The software profile is not merely 2D command handling on the VirGL device. |
| Presentation ownership | `CAMetalLayer` drawable in the RiftVM process | IOSurface pool owned by apkrund and presented by a wrapper process |
| Device model | One large Swift class owns GPU and presentation state | `VirtioDeviceCore`, `GraphicsCore`, `GraphicsBridge`, RuntimeCore, and WindowingCore boundaries |
| Display model | Scanout 0 only | `DisplayPool` assigns displays dynamically; no fixed app-to-scanout mapping |
| Input | Not implemented by the GPU prototype; separate static probe is experimental | USB/VZ input and Guest Agent path from ADR-0013; no shell process per event |
| Guest trust | Upstream bounds and logs in a product-specific handler | APKRun validates every guest-controlled value, tracks bounded allocations, uses typed errors, and fuzzes decoders |
| Renderer build | Pinned RiftVM source and recipe archives; upstream notice docs disagree about release packaging | APKRun's own lock, build scripts, reproducibility checks, and third-party notices |
| Save/restore | Disabled for custom VirGL | Disabled while this device is attached, per R-07 |
| Resource formats | The device forwards the guest's `format` to virglrenderer without a device-side allowlist; the renderer decides, and its refusal maps to an error response | Formats are limited to the renderer's supported set ([graphics.md](graphics.md) §4.4) |
| Renderer inputs | RiftVM's pinned recipe archives and repository patches, applied by its own scripts, with reference flags | APKRun's lock-listed patch series and `buildFlags`, with the choices recorded in §4 and IR-190, IR-410 to IR-413 |

The source findings update [graphics.md](graphics.md) §2.1 and inform the
independent APKRun build plan in §5.1–§5.2. No core graphics gate is passed by
this source review.

## 8. Verification record

The reviewed remote tag ref `riftvm-v0.6.1` peels to commit
`51f19193b1d3326b2e164d37a2a59e9970375170`; the local read-only checkout was
at that commit. `git verify-tag` reports that the tag has no signature. The
upstream release API reports `immutable: false`. The MIT license copy matches
the pinned repository's root `LICENSE`.

`scripts/check-lock.sh` accepted the source-only entry and its required license
file. The lock group is `graphics-reference`; renderer build-group processing
and `check-lock.sh --apply` exclude it. The current
`generate-notices.py --check` validates shipped app/derived copies and excludes
`ships: reference` entries. This review manually compared the committed MIT
copy with the pinned repository's root `LICENSE`; the full reference-source
license check remains part of #093. `git diff --check` passed. The #018 test
strategy defines no executable test suite: this task is an analysis document
accepted by review. #018 did not build RiftVM, run a VM boot, or perform an
Android/Metal presentation test; the separately scoped #020 renderer build and
tests are recorded in [graphics.md](graphics.md) §16 / IR-191. Maintainer
review of the source-version substitution and this analysis is still required.

On 2026-10-10 #018 checked the analysis again against the pinned commit. No
local checkout is present in the task worktree, so the files were read through
the GitHub API at `51f19193`. The annotated tag `riftvm-v0.6.1` (object
`e757cdec`) peels to that commit. The checks covered the device and protocol
paths and their line references, the error-code names in the attach and scanout
paths, the `flags 0` initialization and callback version 4, the limits, the
fence timeout and poll backoff, the scheduler counters, the production shutdown
order, and the absence of license headers in every row of §5. The recipe
archives and the virglrenderer, ANGLE, and libepoxy source archives were
downloaded, and their SHA-256 values matched the pins in
`scripts/virgl-runtime-pins.sh`. The patch comparisons applied the sequences to
copies of the pinned sources (virglrenderer in full; ANGLE for the files the
patches touch) or compared added lines (libepoxy). `scripts/check-lock.sh`
passed in the worktree after the pinned XcodeGen was installed from its
checksummed release archive. `build_third_party.py cache-key graphics-reference`
refuses the group as having no buildable component, and the `virgl-runtime`
selection does not include `riftvm`. The three ANGLE DEPS commits in the lock
equal ANGLE's `DEPS` revisions at `2d91f554`, read from the downloaded archive.

Not checked: no build, no VM, no Metal presentation, and no Vulkan build. The
prebuilt bottle binaries named in `virgl-runtime-pins.sh` were not examined.
The NOTICE status of the Vulkan headers is not verified (§4).
