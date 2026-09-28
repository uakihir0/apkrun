# 0002. Virtualization.framework on macOS 27+ with custom virtio devices

- Status: Accepted
- Date: 2026-09-28
- Related: R-01, R-07, #001–#007, #063, WWDC26 session 224

## Context

We need a hypervisor on Apple Silicon that can boot an arm64 Linux kernel and provide a 3D-capable GPU to the guest. Virtualization.framework (VZ) provides a high-level, supported VM API. Its built-in `VZVirtioGraphicsDevice` is 2D-only with a single scanout, which is not enough for Android multi-window GPU rendering. macOS 27 adds a public **custom virtio device API** (`VZCustomVirtioDeviceConfiguration`, `VZCustomVirtioDevice`, `VZVirtioQueue`, `VZVirtioSharedMemoryRegion`), which lets an app implement its own virtio device models.

Verified facts (research 2026-09-28):

- The configuration exposes device ID, PCI class/subclass, queue count, feature sets, device-specific configuration, shared-memory regions, and a delegate provider.
- Queues become available after DRIVER_OK. The delegate receives queue notifications and lifecycle callbacks (DRIVER_OK, stop, pause, resume, reset, save/restore).
- `updateDeviceSpecificConfiguration` works only with the same size. **There is no callback for guest writes to the device configuration space.**
- `VZVirtioSharedMemoryRegion` supports page-aligned mapping, which enables blob resources later.
- An open-source implementation exists: RiftVM (MIT, v1.0.4). It implements virtio-gpu (device 16) with virglrenderer + ANGLE on macOS 27 at about 60 fps.

## Decision

Use Virtualization.framework, requiring **macOS 27 or later on Apple Silicon**. Implement virtio-gpu as a custom virtio device in apkrund. Use VZ built-in devices for block, network (NAT), vsock, console, entropy, balloon, and sound.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Hypervisor.framework + our own VMM (or QEMU/crosvm/libkrun) | Far more code to own (device emulation, PCI, interrupt controllers). libkrun/krunkit is an option for Vulkan later, but not needed for v1 |
| VZ on macOS ≤ 26 with the 2D `VZVirtioGraphicsDevice` + guest software rendering | Performance is unacceptable for the product (CPU rendering, one scanout). It is kept only as a debugging fallback (`gpu_mode=guest_swiftshader`, see [../../02-design/graphics.md](../../02-design/graphics.md) §9) |
| QEMU with virglrenderer (UTM-style) | Works, but then we own a QEMU distribution, licensing (GPL), and its UI integration. The custom virtio API gives the same capability inside a supported framework |

## Consequences

- The minimum OS is macOS 27, which limits the audience initially.
- No config-space write callback means some virtio devices are impossible (virtio-input) and some need workarounds. For virtio-gpu, `events_clear` is not observable, so the device clears `events_read` when it processes `GET_DISPLAY_INFO` ([../../02-design/graphics.md](../../02-design/graphics.md) §4.3).
- VM save/restore cannot be used while the custom GPU device holds renderer state (`supportsSaveRestore` = NO; RiftVM disables it) → R-07.
- Only one vsock device per VM. Bridged networking is not available without a restricted entitlement.

## Verification

G1 (ARM64 Linux boots, #003), #063 (a custom virtio test device works end to end), G3 (SurfaceFlinger renders through virtio-gpu → Metal, #023).
