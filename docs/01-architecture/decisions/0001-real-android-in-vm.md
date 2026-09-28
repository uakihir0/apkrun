# 0001. Run real Android in a VM

- Status: Accepted
- Date: 2026-09-28
- Related: [../../00-product/vision.md](../../00-product/vision.md)

## Context

The product goal is to run unmodified Android applications on macOS so that they feel like Mac apps. There are two broad approaches: reimplement Android APIs on macOS (a compatibility layer, as Wine does for Windows), or run a real Android system in a virtual machine.

## Decision

Run a real, unmodified AOSP-based Android system inside a virtual machine. Integrate it with macOS through a host runtime (windows, input, clipboard, notifications, updates). **Android API compatibility layers are out of scope permanently.**

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| API translation layer (Wine-style) | Android's API surface (ART, Binder, SurfaceFlinger, HALs, Play Services expectations) is too large. Compatibility would be low and fragile. |
| Container on a Linux VM (Anbox/Waydroid-style) | It still needs a Linux VM on macOS, and adds a second isolation layer and kernel requirements (binder, ashmem) for no benefit over a full Android VM |
| Run the Android Emulator (QEMU/goldfish) | Heavyweight. Its window model is one device screen, it is difficult to embed per-app, and it depends on the emulator's own UI and graphics pipeline |

## Consequences

- Compatibility is bounded by what Android itself supports on arm64, plus our graphics and device support.
- Resource cost: one VM (memory, disk, boot time). Mitigated by one shared VM for all apps, idle pause, and a fast warm path.
- Google Play Services are not included (licensing). Apps that need GMS will not work fully; this is documented in the compatibility levels in [../../00-product/scope.md](../../00-product/scope.md).

## Verification

G2 (Android reaches `boot_completed`, #014) and G4 (Hello APK renders and accepts input in a native Mac window, #026).
