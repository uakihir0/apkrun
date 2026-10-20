# M2 Graphics

M2 gives APKRun its own virtio-gpu device in GraphicsCore and a pinned virglrenderer and ANGLE renderer on Metal. Android renders through Mesa virgl, and display 0 shows in a macOS window through an IOSurface pool with no CPU copy on the normal path. M2 closes gate G3 ([roadmap.md](../roadmap.md) §2).

---

## #018 Analyze the RiftVM GPU prototype

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #001 |
| Design | [graphics.md](../../02-design/graphics.md) §2; [riftvm-analysis.md](../../02-design/riftvm-analysis.md) |
| Code | `ThirdParty/ThirdParty.lock.json` (`riftvm` entry, source only) |

**Goal.** The team knows which RiftVM components APKRun reuses, rewrites, or ignores, with their licenses and renderer build flags.

**Result.** [riftvm-analysis.md](../../02-design/riftvm-analysis.md) classifies each file. RiftVM is pinned as source only and is never built or linked. The reuse and notice rules are in [graphics.md](../../02-design/graphics.md) §2.3.

---

## #019 virtio-gpu device layer

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #018, #003, #063 |
| Design | [graphics.md](../../02-design/graphics.md) §3, §4.1–§4.3 |
| Code | `Packages/GraphicsCore/Sources/GraphicsCore/VirtioGPU/`, `Packages/GraphicsCore/Sources/GraphicsCore/Display/`, `Packages/GraphicsCore/Tests/GraphicsCoreTests/`, `Tests/IntegrationTests/LinuxGuestTests/` (`gpu` check) |

**Goal.** APKRun owns a virtio-gpu device layer in GraphicsCore, with no Linux or Android code, and a Linux guest detects it. There is no rendering yet.

**Result.** `VirtioGPUDevice`, `VirtioGPUProtocol`, `ScanoutTable`, `ResourceTable`, and `EDIDGenerator` are in GraphicsCore. The Linux test guest finds PCI 1af4:1050 with 16 scanouts and reads the generated EDID. Tests are T0 in `GraphicsCoreTests`, a fuzz smoke test in `Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`, and the T2 `gpu` check. Known limits: the Android part of R-01 stays open until #028. Full fuzzing (libFuzzer) is #091.

---

## #020 Build graphics dependencies

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #018 |
| Design | [graphics.md](../../02-design/graphics.md) §5.1, §5.2; [build-system.md](../../05-development/build-system.md) §6 |
| Code | `ThirdParty/ThirdParty.lock.json`, `ThirdParty/patches/`, `ThirdParty/build/`, `scripts/build-third-party.sh`, `Packages/GraphicsCore/Sources/GraphicsBridge/`, `Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/` |

**Goal.** A fresh checkout builds the pinned virglrenderer, libepoxy, and ANGLE libraries with no manual file edit, and a host test creates a renderer on Metal.

**Result.** `scripts/build-third-party.sh virgl-runtime` writes the four libraries with a verified manifest. `GraphicsBridge` exposes opaque handles only. The T1 test in `GraphicsCoreSystemTests` creates a renderer, reads the `VIRGL2` capset, and destroys it. CI caches the output by lock and environment hashes.

---

## #021 Android detects virtio-gpu

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #019, #014 |
| Design | [graphics.md](../../02-design/graphics.md) §4.1, §9; [android-image.md](../../02-design/android-image.md) §7 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Android/`, `CLI/apkrun/Dev/` (`dev boot --gpu`), `Tests/IntegrationTests/AndroidGraphicsTests/` |

**Goal.** The Android kernel binds the expected DRM and virtio GPU driver to APKRun's device.

**Result.** With `apkrun dev boot --gpu swiftshader`, `virtio_gpu` binds, `card0` has 16 `Virtual-N` connectors, and only `Virtual-1` (scanout 0) is connected. `AndroidGraphicsTests.testVirtioGPUBinds` checks this. Known limit: the Android part of R-01 stays open until #028.

---

## #099 Mesa-enabled VirGL guest image

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #020, #021 |
| Design | [graphics.md](../../02-design/graphics.md) §5, §9; [android-image.md](../../02-design/android-image.md) §3, §8, §11 |
| Code | `Guest/product/mesa/`, `scripts/guest/`, `Images/reference/`, `ThirdParty/ThirdParty.lock.json` |

**Goal.** A corrected guest image has Mesa EGL and VirGL libraries that load in the guest, with its own build identity. Reference build `16373615` does not change.

**Result.** The corrected image has its own identity, manifest, hashes, and provenance. In the guest, `eglInitialize` succeeds on the VirGL display (`apkrun.test=egl`) only under a test-only diagnostic ODM policy. That diagnostic bundle must never ship. Known limit: the image without a diagnostic profile does not initialize EGL under the enforcing policy. #035 step 8 confirms graphics on the custom image under the product policy.

---

## #022 Android VirGL

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #021, #020, #099 |
| Design | [graphics.md](../../02-design/graphics.md) §4.2, §4.4, §4.5, §5.2–§5.4, §9 |
| Code | `Packages/GraphicsCore/Sources/GraphicsCore/Renderer/`, `Packages/GraphicsCore/Sources/GraphicsBridge/`, `Tests/Fixtures/graphics/`, `Tests/IntegrationTests/LinuxGuestTests/` (`virgl` check), `Tests/IntegrationTests/AndroidGraphicsTests/` |

**Goal.** Android's graphics stack initializes on the `drmVirgl` path with Mesa virgl, minigbm gralloc, and the ranchu HWC. Software rendering is not the normal path.

**Result.** `apkrun dev boot --gpu virgl` (the `drmVirgl` profile) reaches `sys.boot_completed=1`, and SurfaceFlinger uses the virgl GLES renderer. The `guestSwiftshader` profile also reaches boot completion. The Linux test guest `virgl` check reports `renderer=virgl` with no renderer failures. The `kmscube` replay checks that operations succeed, not pixels. Known limits:
- Production SELinux policy for graphics: #035 step 8 (see #099).
- VirGL submit errors during app runs: #105 (R-02).

---

## #023 Render SurfaceFlinger to Metal

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #020, #022 |
| Gate | G3 |
| Design | [graphics.md](../../02-design/graphics.md) §6, §7; [display-and-windowing.md](../../02-design/display-and-windowing.md) §5.3 |
| Code | `Packages/GraphicsCore/Sources/GraphicsCore/Display/`, `Packages/WindowingCore/`, `CLI/apkrun/Dev/SurfacePoolFrameSource.swift`, `Tests/AcceptanceTests/G3GraphicsTests/` |

**Goal.** Android's display 0 shows in a macOS window, with GPU rendering and no CPU framebuffer copy on the normal presentation path.

**Result.** The development window shows the IOSurface pool as `CALayer` contents. It is fixed-size: display 0 keeps the image's default mode, and the window scales the layer with aspect fit. The `G3` acceptance test passed; the gate result is in [roadmap.md](../roadmap.md) §2. Known limit: runtime resize is #067.

---

## #105 VirGL submit errors during app runs

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #023 |
| Design | [graphics.md](../../02-design/graphics.md) §4.4, §4.5, §4.7, §5.2, §13.1, §13.2 |
| Code | `Packages/GraphicsCore/Sources/GraphicsCore/Renderer/`, `Packages/GraphicsCore/Sources/GraphicsBridge/`, `Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`, `Tests/IntegrationTests/AndroidInputTests/` |

**Goal.** The renderer logs no VirGL submit error during app runs. Find the cause and fix it, or show that the errors are harmless and stop logging them as errors.

**Out of scope.**
- The production SELinux policy for graphics (#035).

**Steps.**
1. **Reproduce.** Run `AndroidInputTests` (direct-view input with HelloText and HelloCompose) and a 10-minute HelloGL run on `drmVirgl`, with the `renderer` category of `io.apkrun.graphics` logged. Known symptoms: six failed submits (`operation=submit`), each near a `COPY_TRANSFER3D: 22` callback on a render thread, with `Illegal resource` and `Illegal command buffer` messages. One `RESOURCE_ATTACH_BACKING` rejection on another thread has no resource ID. **Check:** each failure has a timestamp, a thread, and a VirGL context ID in the log.
2. **Correlate.** For each failed submit, find the resource ID, the failing API operation, and the guest command that came before it on the device queue. Mark a failure with no resource ID as unattributed. **Check:** the PR lists every failure with its resource ID or as unattributed.
3. **Answer the ordering questions.** Are guest writes to a backing always transferred before the renderer reads the resource? How do `DETACH_BACKING`, `UNREF`, pause, and reset order against queued and in-flight renderer work ([graphics.md](../../02-design/graphics.md) §4.4, §4.7)? **Check:** the answers cover every failure from step 2.
4. **Fix or reclassify.** Fix the operation or the ordering that fails. If a failure is harmless, stop logging it as an error, and record the reason in [graphics.md](../../02-design/graphics.md) §13.2. Real failures stay `rendererOperationFailed` ([graphics.md](../../02-design/graphics.md) §13.1). **Check:** the 10-minute HelloGL run and `AndroidInputTests` log no VirGL submit error.
5. **Replay test.** Add a T1 test in `Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/` that replays the failing command sequence through the renderer. **Check:** the test fails without the step 4 change and passes with it.

**Tests.**
- T0: the logging change of step 4, in `Packages/GraphicsCore/Tests/GraphicsCoreTests/`.
- T1: the replay of the failing sequence, in `Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`. Needs Metal.
- T2: `Tests/IntegrationTests/AndroidInputTests/` and a 10-minute HelloGL run on `drmVirgl` (`apkrun dev boot --gpu virgl --window`). Neither logs a VirGL submit error.
- T3: none.

**Done when.**
- A 10-minute HelloGL run on `drmVirgl` logs no VirGL submit error.
- `AndroidInputTests` logs no VirGL submit error.
- A T1 test replays the failing sequence and passes.
- Either the cause is fixed, or [graphics.md](../../02-design/graphics.md) §13.2 says these errors are harmless and not logged as errors.

**Pitfalls.**
- A `submit` label names the failed host API call. It does not name the guest command or resource that caused it.
- The rejection with no resource ID stays unattributed. Do not guess a resource ID for it.
- Do not hide the errors by lowering the log level of the whole `renderer` category.
