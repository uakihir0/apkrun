# 0004. VirGL (GLES) first via virglrenderer + ANGLE/Metal

- Status: Accepted
- Date: 2026-09-28
- Related: #018–#023, #026, #096 (Vulkan, post-v1), R-02, R-03, R-07

## Context

Android needs GPU acceleration for acceptable UI performance. The options for a virtio-gpu 3D backend on macOS are:

- **VirGL:** guest Mesa `virgl` Gallium driver → virglrenderer on the host → host GL. On macOS, host GL is provided by ANGLE on Metal.
- **Venus:** guest Vulkan → virglrenderer's venus → host Vulkan (MoltenVK). Needs blob resources and host-visible memory mapping.
- **gfxstream:** Google's emulator pipeline (GLES/Vulkan). It has to be ported to this VMM.

Research: RiftVM demonstrates VirGL on macOS 27's custom virtio API with virglrenderer 960bd667 + libepoxy 1b6d7db + ANGLE 2d91f554 (Metal backend). It runs at about 60 fps with 0.4–0.8 ms per present, using a single renderer thread, and needs a virglrenderer MSAA patch because ANGLE exposes GLES 3.0. RiftVM does not implement RESOURCE_BLOB, CONTEXT_INIT, or shared memory. Cuttlefish's `drm_virgl` mode provides the matching guest side (GLES 3.0, no Vulkan).

## Decision

Ship **VirGL** as the v1 graphics path. Base our virtio-gpu device on RiftVM's MIT-licensed implementation, adapted to our module boundaries: `VirtioDeviceCore` + `GraphicsCore` + the `GraphicsBridge` C target. Vulkan (Venus or gfxstream) is Phase 21 work (#096, post-v1) and needs blob resources via `VZVirtioSharedMemoryRegion`.

## Alternatives considered

| Alternative | Why not first |
|---|---|
| Venus + MoltenVK | Needs blob/host-visible memory (not demonstrated on the custom API yet), a newer guest Mesa, and Vulkan-to-GLES bridging for Android's GLES-heavy UI stack |
| gfxstream | Large porting effort (pipes/address space device); its host renderer has not been demonstrated on this API |
| Guest software rendering (SwiftShader/lavapipe) | Too slow for the product. Kept as a debug fallback only |

## Consequences

- Android sees GLES 3.0 (with ANGLE-imposed limits). Apps requiring GLES 3.1+/Vulkan fall into lower compatibility levels until the Vulkan track (#096) lands.
- There is one renderer thread and in-order fence processing. Performance is bounded by virglrenderer's serialization.
- VM save/restore is not possible while VirGL is active (R-07).
- We maintain pinned builds of virglrenderer/libepoxy/ANGLE plus patches ([../../05-development/build-system.md](../../05-development/build-system.md) §6). The ANGLE Metal build pulls about 11 GB of dependencies, so CI caches the artifacts.

## Verification

G3 (SurfaceFlinger renders through virtio-gpu → Metal with no readback on the normal path, #023), G4 (#026), and frame-time numbers from the perf harness (#070).
