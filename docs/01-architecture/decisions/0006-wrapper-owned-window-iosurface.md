# 0006. Wrapper owns the window; apkrund renders into shared IOSurfaces

- Status: Accepted
- Date: 2026-09-28
- Related: #026, #068, #031, #032, #044, [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md)

## Context

  described the launcher as a short-lived process that asks the runtime to open a window. For macOS identity (Dock icon, Cmd+Tab, the app menu, per-app notifications, "Quit Discord"), the window must belong to the wrapper's process. The VM and renderer must live in apkrund, because one VM is shared by all apps.

Research: IOSurfaces can be shared across processes via XPC (`IOSurfaceCreateXPCObject` / `IOSurfaceLookupFromXPCObject`, and `IOSurface` supports `NSSecureCoding` for NSXPC). UTM presents cross-process via IOSurfaces. RiftVM presents in-process into a `CAMetalLayer` from a Metal texture borrowed from virglrenderer (`virgl_renderer_borrow_texture_for_scanout` → `EGL_METAL_TEXTURE_ANGLE`) with one GPU blit.

## Decision

- apkrund allocates a **triple-buffered IOSurface pool per display**. Each frame it blits the scanout texture into the next free IOSurface (at most one GPU blit) and notifies the wrapper over XPC with the buffer index.
- **The wrapper process (APKRunLauncher) owns the NSWindow**, presents the IOSurface as layer contents, captures input, and stays alive for the whole session.
- APKRun.app never shows app windows.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| apkrund opens all windows | All apps would appear as one process (a single Dock icon), the per-app menu bar would be wrong, and "Quit" semantics break |
| Short-lived launcher + apkrund windows with `NSRunningApplication` tricks | Not supported by AppKit. Fragile |
| Send encoded video to wrappers | Latency, CPU/GPU cost, quality loss |

## Consequences

- There is one extra process per open app (small: AppKit plus RuntimeClient).
- Frame pacing needs cross-process buffer management (a buffer is not reused until the wrapper reports it displayed, or it is dropped). See [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5.
- Resize reallocates the pool and sends new IOSurfaces.

## Verification

G4/G5 plus a perf check: no readback, present cost < 2 ms p95 (#070).
