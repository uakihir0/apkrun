# M2 Graphics

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.1 |
| Related | [README.md](README.md), [../roadmap.md](../roadmap.md) §2, [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../traceability.md](../traceability.md), [../../02-design/graphics.md](../../02-design/graphics.md), [../../05-development/workflow.md](../../05-development/workflow.md) |

## Milestone goal

APKRun has its own virtio-gpu device. It is built in GraphicsCore on VirtioDeviceCore and attached through the macOS 27 custom virtio device API ([../../01-architecture/decisions/0002-virtualization-framework-macos27.md](../../01-architecture/decisions/0002-virtualization-framework-macos27.md)). The test Linux guest and Android both detect it.

virglrenderer, libepoxy, and ANGLE are pinned and built from the lock file. Android's SurfaceFlinger renders with Mesa virgl in the guest. The host runs the command stream through virglrenderer and ANGLE on Metal ([../../01-architecture/decisions/0004-virgl-first-graphics.md](../../01-architecture/decisions/0004-virgl-first-graphics.md)).

Frames reach a macOS window through the IOSurface pool, with no CPU framebuffer copy and no readback (gate G3). The window shows the IOSurface as `CALayer` contents, not a `CAMetalLayer`, because the same pool is later shared with the wrapper ([../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)).

M2 delivers the "VirGL accelerated rendering" item of the v0.1 Definition of Done ([../roadmap.md](../roadmap.md) §3.1). G3 is the first gate that validates the core architecture ([AGENTS.md](../../../AGENTS.md) §5).

## Exit criteria

- [ ] All 7 tasks below meet every acceptance criterion.
- [ ] Gate G3 passes on the reference Mac with a clean build from `main`, meeting all six conditions of [../roadmap.md](../roadmap.md) §2.
- [ ] These files are committed:
  - `docs/02-design/riftvm-analysis.md`.
  - The `riftvm`, `angle`, `libepoxy`, and `virglrenderer` entries in `ThirdParty/ThirdParty.lock.json`, and every patch under `ThirdParty/patches/`.
  - The golden virtio-gpu vectors, the golden EDIDs with their `edid-decode` output, and the recorded `kmscube` command stream in `Tests/Fixtures/graphics/`.
  - The HelloGL fixture in `Tests/Fixtures/AndroidApps/`.
- [ ] A fresh checkout builds the runtime libraries with `scripts/build-third-party.sh virgl-runtime` and no manual file editing.
- [ ] The verified results are recorded:
  - [../../02-design/graphics.md](../../02-design/graphics.md) §16, every row of #018–#023.
  - [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §11 row 1, the Linux part.
- [ ] R-01 (Linux part), R-02, and R-03 (one display) in [../risks.md](../risks.md) each have a result and an updated status.
- [ ] Tests pass:
  - T0 and T1 on `main`. The T1 tests that need Metal run on the Mac runners.
  - T2 on the reference Mac: `LinuxGuestTests` (the `gpu` and `virgl` checks) and `AndroidGraphicsTests`.
  - The G3 check is in the nightly T3 run.
- [ ] The milestone review of [../roadmap.md](../roadmap.md) §4 is done.

## Task order

1. #018 Analyze the RiftVM GPU prototype. It needs only #001, so it can run during M0 and M1.
2. In parallel: #019 virtio-gpu device layer (also needs #003 and #063 from M0) and #020 Build graphics dependencies.
3. #021 Android detects virtio-gpu. It needs #019 and #014 from M1, and can run in parallel with #020.
4. #099 Mesa-enabled VirGL guest image. It needs #021 and #020.
5. #022 Android VirGL. It needs #021, #020, and the diagnostic Mesa guest from #099.
6. #023 Render SurfaceFlinger to Metal. This task closes G3.

Outside M2: #033 of M3 needs only #007, so it can start during M2 ([../roadmap.md](../roadmap.md) §1.4).

The ANGLE build needs about 11 GB of disk and a long first build ([../../02-design/graphics.md](../../02-design/graphics.md) §5.1). #020 adds the CI cache keyed by the lock hash and detected build environment. Developer Macs reuse a verified cache when those identities match.

Conventions used by every task in this file:

- Dev commands. The `apkrun dev` commands of [../../02-design/cli.md](../../02-design/cli.md) §5 are run through the Debug CLI `apkrun-dev` ([../../05-development/build-system.md](../../05-development/build-system.md) §13). For example: `apkrun-dev dev boot --gpu virgl --window`.
- Home directory. Debug builds use `APKRUN_HOME` = `~/Library/Application Support/APKRun-Dev/`, and logs go to `~/Library/Logs/APKRun-Dev/`.
- Where tests live.

  | Tier | Location |
  |---|---|
  | T0 Swift | `Packages/<Module>/Tests/<Module>Tests/` |
  | T1 Swift | `Packages/<Module>/Tests/<Module>SystemTests/` |
  | T2 | `Tests/IntegrationTests/` |
  | T3 | `Tests/AcceptanceTests/` |

- Running T2 tests. T2 tests run with `xcodebuild test -project APKRun.xcodeproj -scheme IntegrationTests -only-testing:IntegrationTests/<Suite>` inside the signed test host ([../../05-development/build-system.md](../../05-development/build-system.md) §12.4).
  - Android T2 suites skip with a message when `Images/work/16373615/` holds no bundle. With `APKRUN_CI=1`, a missing bundle fails the run.
  - Each suite uses a temporary `APKRUN_HOME` on the same APFS volume as the bundle.
- Reference build. Build ID `16373615` is the pinned M1–M4 build ([../../01-architecture/decisions/0003-cuttlefish-base-image.md](../../01-architecture/decisions/0003-cuttlefish-base-image.md)).
- Frame path rule. The normal frame path never uses `glReadPixels`, a CPU framebuffer readback, or a CPU texture copy ([AGENTS.md](../../../AGENTS.md) §6.4). The only readback is the test-only mode of #022 and #023, behind the `APKRUN_TEST_READBACK` build flag.

---

## #018 Analyze the RiftVM GPU prototype

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #001 |
| Requirements | None named in requirements.md. Constraints: [AGENTS.md](../../../AGENTS.md) §6.4 (study RiftVM before writing new virtual GPU code), NFR-DEV-01 |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §2, §5.1, §5.2, §12 (#018), §15; [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) §3.1; [../../05-development/build-system.md](../../05-development/build-system.md) §6 |
| Modules / paths | `docs/02-design/riftvm-analysis.md`, `ThirdParty/ThirdParty.lock.json` |
| Risks / questions | R-02 |

### Goal

The team knows exactly which RiftVM components APKRun reuses, rewrites, or ignores, under which license, and with which renderer patches and build flags. The document names the exact source components APKRun needs.

### Scope

- Pinning the available RiftVM `riftvm-v0.6.1` source as a source-only lock entry. This replaces the unavailable v1.0.4 tag and is recorded for maintainer review in [implementation-review.md](../implementation-review.md) IR-188.
- Reading the files of §2.1, the RiftVM architecture document, and the production application's Custom VirGL integration and lifecycle.
- The file-by-file table of §2.2, covering the flow the task lists: `VZCustomVirtioDevice`, virtqueue handling, virtio-gpu commands, resource creation, resource backing, VirGL, scanout, ANGLE, Metal, and the cursor.
- The patches and exact build flags that RiftVM uses for virglrenderer, libepoxy, and ANGLE, and its EGL init flags.
- License review of every reusable file.
- Out of scope:
  - Copying any code in #018. Any later task that copies or adapts RiftVM code follows the rules of §2.3 and updates the lock classification; #020 does not copy RiftVM Swift code.
  - Building RiftVM or depending on it. RiftVM is never a build dependency (§2.3).

### Deliverables

- `docs/02-design/riftvm-analysis.md` with the §2.2 table filled in, file by file.
- The `riftvm` entry in `ThirdParty/ThirdParty.lock.json`: repository `github.com/riftvm/riftvm`, commit `51f19193b1d3326b2e164d37a2a59e9970375170`, license MIT, source only and not built.
- The patch and build-flag list that seeds #020.
- The updates to §2.1 and §5.1 of [../../02-design/graphics.md](../../02-design/graphics.md) where the analysis differs.

### Implementation steps

1. **Pin RiftVM.**
   - Add the `riftvm` lock entry at the `riftvm-v0.6.1` commit, marked source only ([../../05-development/build-system.md](../../05-development/build-system.md) §6). The planned v1.0.4 tag is unavailable; see IR-188.
   - Check: the lock-file schema check in CI accepts the entry, and no build script reads it.
2. **Read and classify.**
   - Read every file in §2.1 and the architecture document.
   - Trace the production-facing runtime caller, its initialization boundary, VM binding, snapshot policy, and shutdown lifecycle.
   - For each file, record in the §2.2 table: what it does, the flow step it covers, and the decision (reuse with changes, rewrite, or ignore) with the reason.
   - Check: every flow step and the production integration have at least one row, and every §2.1 file has a decision.
3. **Renderer patches and flags.**
   - List RiftVM's patches, configure flags, and build flags for virglrenderer, libepoxy, and ANGLE, and its EGL init flags.
   - Compare them with the pins of §2.1 (virglrenderer 960bd667, libepoxy 1b6d7db, ANGLE 2d91f554) and the initial patch set of §5.1.
   - Check: the list names, for each patch, its purpose and whether #020 takes it.
4. **Licenses.**
   - Confirm the MIT license of each reusable file, and the licenses of the renderer components, against [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) §3.1.
   - Record the notice rule of §2.3: a copied file keeps the MIT notice and adds "Derived from RiftVM <commit> (MIT)", and the notice goes into `ThirdPartyNotices.html`.
   - Check: the analysis has a license column with no empty cell.
5. **Update the design.**
   - Update §2.1 and §5.1 where the analysis finds differences, and fill the #018 row of §16.
   - Check: review.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.3.

- None. The analysis is accepted by review.

### Acceptance criteria

- [x] `docs/02-design/riftvm-analysis.md` identifies the exact source components required for APKRun.
- [x] It covers every flow step the task lists: `VZCustomVirtioDevice`, virtqueue handling, virtio-gpu commands, resource creation, resource backing, VirGL, scanout, ANGLE, Metal, and the cursor.
- [x] It identifies the reusable code and the licenses of each part.
- [x] It lists the renderer patches and build flags that #020 uses.
- [x] RiftVM is pinned in the lock file as source only, and no build step depends on it.
- [x] §2.1, §5.1, and the #018 row of §16 are updated.

### Notes

- **Record:** the findings in the #018 row of [../../02-design/graphics.md](../../02-design/graphics.md) §16. The design changes go into §2.1 and §5.1, not into the analysis only.
- Until this task is done, the initial patch set of §5.1 is the working default (§15).
- The analysis document is a design document. It follows [../../README.md](../../README.md) §3 and is listed in [../traceability.md](../traceability.md).

---

## #019 virtio-gpu device layer

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #018, #003, #063 |
| Requirements | FR-VM-06, FR-GFX-01 ([../traceability.md](../traceability.md) §2.1, §2.3). Constraints: NFR-SEC-01 (APK code, and so every guest request, is untrusted) |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §2.3, §3, §4.1–§4.3, §6.4, §12 (#019), §13, §16; [../../02-design/vm.md](../../02-design/vm.md) §2 (`customDevices`), §3, §4, §12; [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §11 |
| Modules / paths | GraphicsCore `VirtioGPUDevice`, `VirtioGPUProtocol`, `ScanoutTable`, `ResourceTable`, `EDIDGenerator`; `Packages/GraphicsCore/Tests/GraphicsCoreTests/`; `Tests/Fixtures/graphics/`; the Linux test guest `/init` |
| Risks / questions | R-01 |

### Goal

An APKRun-owned virtio-gpu device layer exists in GraphicsCore. It does not depend on Linux or Android. A Linux guest detects the virtio GPU device. There is no rendering yet.

### Scope

- `VirtioGPUProtocol`: structs, decoding, and encoding for every command of §4.2.
- `VirtioGPUDevice` on VirtioDeviceCore: device ID 16, PCI class 0x03 subclass 0x80, the queues `controlq` and `cursorq`, feature negotiation, and the 16-byte config space (§4.1).
- `GET_DISPLAY_INFO` and `GET_EDID`, with the EDID generator of §6.4.
- An error response for every other command.
- `ScanoutTable` with 16 scanouts, scanout 0 enabled at a fixed test mode.
- The 2D and validation part of `ResourceTable`: IDs, the limits of §5.4, and backing validation.
- The display event logic of §4.3: `displayGeneration`, `reportedGeneration`, and `updateConfigurationSpace`.
- The R-01 spike: a scanout enabled at runtime.
- Attaching the device through `VMDefinition.customDevices` ([../../02-design/vm.md](../../02-design/vm.md) §2).
- Out of scope:
  - The renderer, 3D commands, and fences (#020, #022).
  - SurfacePool and present (#023).
  - Android (#021).
  - The full fuzzing campaign (#091).

### Deliverables

- The GraphicsCore device files listed in Modules / paths.
- The golden request and response vectors, taken from Linux driver traces, in `Tests/Fixtures/graphics/`.
- The golden EDIDs and their committed `edid-decode` output.
- The `gpu` check in the Linux test guest `/init` (`apkrun.test=gpu`).
- With `apkrun dev linux --tests gpu`, RuntimeCore's `LinuxTestGuestRunner` adds the device (the path of #004: CLI → RuntimeHost → RuntimeCore).
- A time-boxed fuzz smoke target over `VirtioGPUProtocol` decoding ([../test-strategy.md](../test-strategy.md) §7.2).
- The R-01 result.

### Implementation steps

1. **Protocol.**
   - Write the `VirtioGPUProtocol` structs, decoding, and encoding for every command in §4.2. Decoding validates every length and field against the limits of §5.4.
   - Capture request and response bytes from the Linux driver in the Linux test guest, and commit them as golden vectors.
   - Check: T0 decodes and re-encodes every golden vector byte for byte, and rejects truncated and oversized inputs.
2. **Device.**
   - Build `VirtioGPUDevice` with feature negotiation and the config space of §4.1. With no renderer, it offers `VIRTIO_GPU_F_EDID` only, and `num_capsets` is 0.
   - Handle `GET_DISPLAY_INFO` and `GET_EDID`. Every other command gets an error response.
   - `supportsSaveRestore` is false.
   - Guest errors are logged under `io.apkrun.graphics`, category `device`, at most 10 per second (§13.2).
   - Check: T0 with the VirtioDeviceCore fakes of #063 covers the feature bits, the config space bytes, and the error responses.
3. **Scanouts and EDID.**
   - `ScanoutTable` holds 16 scanouts. Scanout 0 is enabled at a fixed test mode.
   - `EDIDGenerator` writes the EDID of §6.4: manufacturer `APK`, product code and serial = the scanout index, name `APKRun <index>`, one CVT-RB detailed timing, sizes up to 4095.
   - Check: T0 compares the output with the golden EDIDs and decodes it with a decoder.
4. **Attach and detect.**
   - For `apkrun dev linux --tests gpu`, `LinuxTestGuestRunner` adds the device to `VMDefinition.customDevices`. A bad descriptor fails with `.customDeviceInvalid(name, reason)` ([../../02-design/vm.md](../../02-design/vm.md) §3).
   - The `gpu` check in `/init` reads `lspci` or sysfs, `dmesg`, and `/sys/class/drm`.
   - Check: T2 shows vendor 1af4 device 1050, `virtio_gpu` initialized with 16 scanouts, `/sys/class/drm/card0-Virtual-1/status` = `connected`, and `/sys/class/drm/card0-Virtual-1/edid` equal to the generated EDID.
5. **Display event spike (R-01).**
   - Enable scanout 1 at runtime: bump `displayGeneration` and call `updateConfigurationSpace` (§4.3).
   - Check whether the Linux guest re-reads the display info, and whether `card0-Virtual-2/status` becomes `connected`.
   - Check: the result is recorded. If there is no event, the fallback order of §4.3 (A, then B, then C) stays the plan for #028.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.3.

- **T0** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`):
  - `VirtioGPUProtocol` golden vectors, truncated inputs, and oversized inputs.
  - `ResourceTable` IDs, limits, and backing validation.
  - The display event logic: the generation counter, clearing on `GET_DISPLAY_INFO`, and a change during an in-flight query.
  - The EDID generator against the golden files.
- **T1:** the fuzz smoke target over protocol decoding, time-boxed in CI ([../test-strategy.md](../test-strategy.md) §7.2).
- **T2** (`LinuxGuestTests`, check `gpu`): probe, EDID, and the hotplug spike.

### Acceptance criteria

- [x] A Linux guest detects a virtio GPU device. There is no rendering requirement yet.
- [x] The device layer lives in GraphicsCore, is owned by APKRun, and has no Linux- or Android-specific code.
- [x] Device initialization and feature negotiation work: vendor 1af4 device 1050, 16 scanouts, and `Virtual-1` connected.
- [x] The EDID the guest reads equals the generated EDID.
- [x] Every command outside `GET_DISPLAY_INFO` and `GET_EDID` gets an error response, and no guest input crashes the device.
- [x] Every file derived from RiftVM carries the notice of §2.3.
- [x] The R-01 spike result is recorded.

### Notes

- **Record:** the detection result and the display event spike in the two #019 rows of [../../02-design/graphics.md](../../02-design/graphics.md) §16, the Linux part of [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §11 row 1, and R-01 in [../risks.md](../risks.md). The §4.3 text changes only if the spike changes the design.
- **Pitfall:** the Linux fbdev emulation sends 2D commands (`RESOURCE_CREATE_2D`, `SET_SCANOUT`, `RESOURCE_FLUSH`). In this task they get error responses. The kernel logs errors, but the probe and the EDID read still pass. Do not implement 2D rendering here.
- The device offers EDID only in this task. `VIRTIO_GPU_F_VIRGL` and `num_capsets` = 2 come with the renderer in #022.
- **Status (2026-10-08):** The device layer, protocol codecs, scanout table, EDID generator, resource table, the RuntimeCore attachment, the `gpu` and `gpu-hotplug` checks, and the R-01 spike option are committed on `codex` (4781b50, 25d1da7, 893a367, fde4b4c, 392d889). On macOS 27.0.1 build 26A434 (arm64), `swift test --filter 'GraphicsCoreTests|GraphicsCoreSystemTests|RuntimeCoreTests'` passed: GraphicsCoreTests 67 tests, GraphicsCoreSystemTests 4 tests (2 protocol fuzz smoke, 2 renderer), RuntimeCoreTests 3 tests.
- **Ticked with evidence:**
  - GraphicsCore ownership: `rg -i 'linux|android|cuttlefish'` over `VirtioGPU/`, `Display/`, and `Resources/` finds only the `virtio_gpu.h` citation.
  - Error responses and crash safety: T0 `everyOtherControlCommandGetsAnErrorResponse` (22 control commands), the cursor-queue, oversized-request, short-request, and response-size tests, and the T1 fuzz smoke run (mutated golden requests and responses for up to 5 s).
  - RiftVM notice: no #019 file copies or adapts RiftVM code. RiftVM was read as a reference only (riftvm-analysis.md, IR-249).
- **T2 evidence (2026-10-08, arm64, macOS 27.0.1 build 26A434, signed `IntegrationTests` host):** the libcrypto3 and libssl3 pins are bumped (`ce8a51b`, IR-258), so `scripts/fetch-test-linux.sh` and `scripts/build-test-initramfs.sh` now succeed. `xcodebuild test -scheme IntegrationTests -only-test-configuration LinuxGuest` passed 29 of 29 tests on the final tree (`.build/task019/t2-final2.log`, result bundle `.build/task019/t2-final2.xcresult`, both gitignored). The `gpu` check passed: the guest found PCI 1af4:1050, reported 16 scanouts and 16 connectors, and `card0-Virtual-1` was connected. Its EDID SHA-256 equals `scanout-00-1024x768-60.edid`, checked by `GPUDeviceTests`.
- **R-01 result (Linux part): positive.** The host enabled scanout 1 3.0 s after DRIVER_OK (device log: `R-01 spike enabled scanout 1 after 3.0 seconds`). The guest's `gpu-hotplug` check reported `scanout1=connected` after about 4 s in one run and 5 s in the final run. The driver re-reads display info only on a probe or a config-change event, so this shows that `updateDeviceSpecificConfiguration` raised the guest's event. The device log does not record each query, so the trigger is an inference from driver behaviour. §4.3 stays as written. Fallbacks A to C stay for Android (#028), and R-01 remains open for Android.
- **Failed attempts, for the record:** the first T2 run failed the hotplug check in 0.6 s. The guest's `sleep 0.1` loop and `seq` do not work in the test busybox (`seq` is not an applet), so the 30-second wait returned at once. `fd8af1e` replaces both with whole-second waits, and the rerun passed.
- **Golden driver trace:** the `gpu` check's exchanges were captured with the device's `traceObserver` (`GPUDeviceTests` writes `gpu-driver-trace.json` next to the guest artifacts). They hold 28 exchanges: one `GET_DISPLAY_INFO`, 16 `GET_EDID`, `RESOURCE_CREATE_2D`, `ATTACH_BACKING` with 184 entries, 3 `SET_SCANOUT`, 3 `RESOURCE_FLUSH`, and 3 `TRANSFER_TO_HOST_2D`. They are committed as `Tests/Fixtures/graphics/virtio-gpu-linux-trace.json` (`376bf4e`), and every exchange decodes and re-encodes exactly. The display and EDID answers match what the driver received. The layout vectors stay for the commands that this guest does not send (IR-250).
- **Golden vectors:** the request and response vectors are written from the layouts, not captured (IR-250). Replace them with driver traces once the guest runs. The `traceObserver` of `VirtioGPUDevice` is the capture hook.
- **Judgment calls:** IR-248 (start with #003's gate open), IR-249 (error policy; differs from the §4.6 acknowledgement), IR-252 (test mode, EDID, and CVT constants), IR-253 (display-event rules), IR-254 (ResourceTable not wired until #022), IR-255 (fuzz smoke as a Swift test), IR-256 (R-01 spike option), and IR-257 (edid-decode provenance).
- **Follow-ups, not #019:** (a) connect `ResourceTable` and the renderer in #022; (b) cursor acknowledgement in #023; (c) the libFuzzer target in #091; (d) capture the Android driver's exchanges with #021.

---

## #020 Build graphics dependencies

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #018 |
| Requirements | FR-GFX-02, NFR-DEV-01 ([../traceability.md](../traceability.md) §2.3, §2.12) |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §5.1, §5.2, §8, §12 (#020), §13.1; [../../05-development/build-system.md](../../05-development/build-system.md) §6, §15; [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) §3.1 |
| Modules / paths | `ThirdParty/ThirdParty.lock.json`, `ThirdParty/patches/{angle,libepoxy,virglrenderer}/`, `ThirdParty/build/build-{angle,libepoxy,virglrenderer}.sh`, `scripts/build-third-party.sh`; `Packages/GraphicsCore/Sources/GraphicsBridge/`; `Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`; the CI third-party job |
| Risks / questions | R-02 |

### Goal

A fresh checkout produces the pinned virglrenderer, libepoxy, and ANGLE libraries and the EGL and GLES components they need, with no manual file editing. A host-only test creates a renderer on Metal.

### Scope

- Lock entries with repository, commit, license, build flags, and local patches.
- A `depot_tools` source pin in the `virgl-runtime` group, so the ANGLE build helper revision participates in the cache identity.
- A PyYAML source pin in the same group, so virglrenderer’s Meson configuration uses a reproducible Python module without relying on user-site packages.
- Build scripts for ANGLE (Metal backend only), libepoxy, and virglrenderer.
- The reviewed macOS, EGL/GLES, Metal shader, and MSAA patches from #018 (§5.1).
- The `GraphicsBridge` skeleton: `gb_renderer_create`, `gb_renderer_destroy`, `gb_renderer_metal_device`, `gb_capset_info`, `gb_capset_fill`, and the minimal context lifecycle needed by the T1 test. Capset writes include an explicit output-buffer length.
- The CI job with caching by lock hash.
- Embedding the output into `APKRun.app/Contents/Frameworks/VirGLRuntime/`.
- Out of scope:
  - The 3D command set, fences, and the Linux `virgl` run (#022).
  - Present (#023).
  - Vulkan (#096).

### Deliverables

- The `angle`, `libepoxy`, and `virglrenderer` lock entries and their patches.
- The pinned `depot_tools` build helper in the same lock group.
- The pinned PyYAML 6.0.3 source used by virglrenderer’s Meson configuration.
- `ThirdParty/build/build-{angle,libepoxy,virglrenderer}.sh`, driven by `scripts/build-third-party.sh virgl-runtime`. The output goes to `ThirdParty/out/virgl-runtime/<lock hash>-<environment hash>/` with a verified manifest.
- The `GraphicsBridge` C target with the skeleton functions of §5.2 and opaque handles only ([AGENTS.md](../../../AGENTS.md) §6.5).
- The T1 renderer test.
- The CI third-party job, with a cache keyed by lock and environment hashes, Swift T0 and graphics T1 jobs that restore and verify that cache, and a weekly clean build.
- The notices of the three components in `ThirdPartyNotices.html`.

### Implementation steps

1. **Lock entries and patches.**
   - Add the three entries with the pins of §2.1, adjusted by #018.
   - Pin `depot_tools` at `f70835271105ca56d2cd5382a0118152bc2bdeea` in the `virgl-runtime` group, with its BSD-3-Clause license and `ships: tooling`, so tool updates invalidate the same cache.
   - Pin PyYAML 6.0.3 by source commit, with its MIT license and `ships: tooling`; make the virglrenderer build use only that source checkout.
   - Add each patch as `ThirdParty/patches/<name>/NNNN-short-description.patch`, made with `git format-patch` against the pinned commit ([../../05-development/build-system.md](../../05-development/build-system.md) §6).
   - Add `--apply` to `scripts/check-lock.sh`: after the build-group sources are checked out at their pinned commits, it applies every listed patch with `git am` to a root-level staging checkout and atomically publishes the verified result under `ThirdParty/out/patched-src/<name>/<commit>/<patch-set SHA-256>/`. It skips `ships: reference` entries such as RiftVM. The command serializes its own runs, validates each full series before publishing any patched checkout, and leaves pinned source checkouts unchanged ([../../05-development/build-system.md](../../05-development/build-system.md) §3, §6).
   - Check: the lock-file schema check passes; `scripts/check-lock.sh --apply` creates clean patched checkouts from exact pinned sources, leaves source checkouts unchanged on both success and failure, rejects redirected or modified inputs, and safely reuses an already-published patched checkout. If an unexpected staging failure occurs, it preserves the generated staging checkout and reports its last-known path; concurrent same-user moves can make that path stale.
2. **Build scripts.**
   - Write the three scripts and the `virgl-runtime` target of `scripts/build-third-party.sh`. ANGLE builds with the Metal backend only.
   - The scripts read every pin and flag from the lock file. They never build from a moving branch.
   - Check: `scripts/build-third-party.sh virgl-runtime` on a fresh checkout writes the four libraries to `ThirdParty/out/virgl-runtime/<lock hash>-<environment hash>/`; an unchanged second run on the same toolchain verifies the manifest and does no build work.
3. **GraphicsBridge skeleton.**
   - Create the C API of §5.2 for renderer creation, destruction, the Metal device, and the capsets.
   - Resolve bundled libraries only from an ancestor app bundle with a matching bundle identifier and `APKRunBuildIdentity`: the production Release pair, the `ReleaseUpdateTest` pair, or the Debug pair. ReleaseUpdateTest uses Release-built package code, so the identity is checked at runtime; unrelated or mismatched bundle identities remain rejected.
   - Reject a runtime directory or any runtime library symlink that resolves outside the matched app bundle. Keep the resolver probe available only in Debug for filesystem-fixture tests.
   - EGL uses `EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE`. The Metal device comes from ANGLE through `EGL_ANGLE_device_metal`.
   - Enforce virglrenderer’s process-wide singleton and keep callback state alive through teardown. Enforce same-thread renderer ownership for every operation, including destroy. Require callers to finish and synchronize all in-flight calls before destroy, and prohibit use of a handle after successful destroy. Reject capset writes whose output buffer is smaller than the reported capset size.
   - Initialization failures map to `GraphicsFailure.rendererInitFailed` with the stage `egl`, `metal`, or `virgl`; missing libraries map to `libraryMissing`; runtime operation failures map to `rendererOperationFailed` (§13.1).
   - Check: T1 passes.
4. **Host-only renderer test.**
   - The T1 test creates the renderer, queries and fills the `VIRGL2` capset, rejects undersized output, creates/destroys/recreates a context ID, and verifies wrong-thread Metal-device, capset, context, reset, and destroy operations are rejected. It joins the worker before owner-thread teardown to satisfy the renderer lifetime contract, then verifies renderer recreation.
   - A bundle-resolver test accepts the exact Release and ReleaseUpdateTest identity pairs, rejects mismatched or unknown identities, and rejects runtime-directory and library symlink escapes.
   - It needs a Metal device. Without one it skips with a clear message.
   - It also runs under Address Sanitizer and Undefined Behavior Sanitizer. CI first checks that its Mac runner has a Metal device, so missing Metal fails CI rather than silently skipping.
   - Check: T1 passes on a Mac runner, and both sanitizer runs report no issue.
5. **CI and embedding.**
   - The CI `third-party` job runs `scripts/build-third-party.sh virgl-runtime`, which fetches locked sources before it calls `scripts/check-lock.sh --apply`, and caches the verified libraries by the composite key. A weekly job builds them clean.
   - Swift T0 and Graphics T1 jobs restore and validate that same composite cache because compiling GraphicsBridge requires the pinned public headers.
   - The app build embeds the output in `APKRun.app/Contents/Frameworks/VirGLRuntime/`.
   - Check: the clean CI job passes, T1 and sanitizer runs pass, and a Debug CLI build resolves the libraries.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.3.

- **T1** (`Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`): `GraphicsBridge` renderer create and destroy, and the capsets. It needs Metal.
- **CI:** the clean build from the lock file; host T1 with Metal; Address Sanitizer and Undefined Behavior Sanitizer runs.

### Acceptance criteria

- [x] virglrenderer, ANGLE, and the required EGL and GLES components are pinned, with revisions and patches recorded in `ThirdParty/ThirdParty.lock.json`.
- [x] A build script exists.
- [x] A fresh checkout produces the required libraries without manual file editing.
- [x] The T1 test creates a renderer on Metal, reads the `VIRGL2` capset, and destroys it cleanly.
- [x] Swift sees only opaque handles from `GraphicsBridge`.
- [x] The licenses are recorded and the notices are in `ThirdPartyNotices.html`.

### Notes

- **Record:** the clean-build, verified cache-hit, renderer-create, capset, context, and sanitizer results in the #020 row of [../../02-design/graphics.md](../../02-design/graphics.md) §16 and IR-192; list the final patches in §5.1.
- **Pitfall:** the ANGLE build needs about 11 GB of disk (§5.1). Use the CI cache on developer Macs.
- The Linux `virgl` run with `kmscube` needs the device of #019 and the 3D commands. #020 does not depend on #019, so the headless run is done in #022 and the windowed run in #023. Both fill the `kmscube` row of §16.

---

## #021 Android detects virtio-gpu

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #019, #014 |
| Requirements | FR-GFX-01 (the Android side: the guest kernel binds the device, [../traceability.md](../traceability.md) §2.3) |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §4.1, §9, §12 (#021), §16; [../../02-design/android-image.md](../../02-design/android-image.md) §7; [../../02-design/vm.md](../../02-design/vm.md) §2 |
| Modules / paths | RuntimeCore (the GPU device in the Android boot plan's `VMDefinition`), `Android/AdbClient.swift`; `CLI/apkrun/Dev/` (`dev boot --gpu`); `Tests/IntegrationTests/AndroidGraphicsTests/` |
| Risks / questions | R-01 |

### Goal

The Android kernel binds the expected DRM and virtio GPU driver to APKRun's device.

### Scope

- Attaching `VirtioGPUDevice` to the Android `VMDefinition`. RuntimeCore appends it for the requested GPU profile ([../../02-design/android-image.md](../../02-design/android-image.md) §9.1), and the CLI only passes `--gpu`.
- Booting with the `guestSwiftshader` profile, which needs no host renderer (§9).
- Inspecting `dmesg`, `/sys/class/drm`, and `/sys/bus/virtio/devices`.
- Out of scope:
  - VirGL and `boot_completed` with the GPU (#022).
  - A window (#023).

### Deliverables

- `apkrun dev boot --gpu swiftshader` boots with the device and the `guestSwiftshader` profile.
- `AndroidGraphicsTests.testVirtioGPUBinds`.

### Implementation steps

1. **Attach.**
   - For `apkrun dev boot --gpu swiftshader`, RuntimeCore adds `VirtioGPUDevice` to `VMDefinition.customDevices`. The `guestSwiftshader` profile offers EDID only (§4.1) and uses its bootconfig of §9.
   - Check: the VM starts and the device is realized.
2. **Capture.**
   - Read `dmesg`, `/sys/class/drm`, and `/sys/bus/virtio/devices/*/device` through `AdbClient`. When ADB is not up, use the kernel console (hvc0).
   - Check: the capture is saved as a T2 artifact.
3. **Binding.**
   - Check that `virtio_gpu` binds, `card0` exists with 16 `Virtual-N` connectors, and only `Virtual-1` (scanout 0) is `connected`.
   - Check: T2 passes.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.3.

- **T2** (`AndroidGraphicsTests`): Android binds `virtio_gpu` with 16 connectors, and only `Virtual-1` is connected.

### Acceptance criteria

- [x] The Android kernel binds the expected DRM and virtio GPU driver.
- [x] `dmesg`, `/sys/class/drm`, and `/sys/bus/virtio/devices` are inspected and saved.
- [x] `card0` has 16 `Virtual-N` connectors, and only `Virtual-1` is connected.

### Notes

- **Record:** the binding result in the #021 row of [../../02-design/graphics.md](../../02-design/graphics.md) §16. `AndroidGraphicsTests.testVirtioGPUBinds` passed on 2026-10-10 with the `AndroidGraphics` configuration.
- **Decisions:** IR-380 to IR-390 in [../implementation-review.md](../implementation-review.md). The main ones: the refusal of a profile the device does not offer (IR-380), the sysfs reads as root through `adb root` (IR-384), and scanout 0 keeping the test mode until #023 (IR-383).
- **Running the check:** the `AndroidGraphics` run needs adb outside `~/Documents`. A child of the test host blocks in dyld on a file under `~/Documents`, so `APKRUN_ANDROID_HOME` points to a copy of `build/android-sdk/platform-tools` under `/tmp` (IR-388).
- `boot_completed` is not required here. The 2D commands that SwiftShader's composition path sends get error responses until #022 adds the 2D renderer. A CLI boot with this profile on this host reached `sys.boot_completed=1` at kernel time 8.5 s (IR-390). The T2 capture came earlier, in `booting(systemServer)`.
- **Refusal check:** `AndroidGraphicsRefusalTests` starts no VM. It checks that a `drmVirgl` boot ends with `gpuProfileUnavailable` and that no file under the home directory changes (IR-380). #022 removed the test, because drmVirgl is attached now (IR-583).
- `--gpu swiftshader` is in [../../02-design/cli.md](../../02-design/cli.md) §5 and `DevGPUProfile` ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §15). `--gpu virgl` waits for #022.
- **Follow-ups, not built here:** (a) `virgl` in `--gpu` and the `drmVirgl` boot, with the removal of the refusal of IR-380 (#022); (b) the image's default display mode on scanout 0 (#023, IR-383); (c) the DRM connector state through a guest-protocol query instead of `adb root` (IR-384).

---

## #099 Mesa-enabled VirGL guest image

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #020, #021 |
| Requirements | As for #022, which this task unblocks |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §5; [../../02-design/android-image.md](../../02-design/android-image.md) §3, §8, §11 |
| Modules / paths | `ThirdParty/ThirdParty.lock.json`, `scripts/guest/` (the Mesa build, IR-497), `scripts/tests/`, `Images/tools/`, `Images/reference/`, `Packages/ImageCore/`, `Guest/` (product fragment) |
| Risks / questions | The guest Mesa EGL load failure recorded in IR-240 and IR-244 |

### Goal

A corrected guest image whose Mesa EGL and VirGL libraries load inside the
guest, with its own build identity, manifest, hashes, and provenance. The
reference build `16373615` does not change, so #064 is unaffected.

### Scope

In scope:

- A minimal product fragment that ships Mesa's VirGL EGL and GLES libraries and
  their loader dependencies in the image.
- Manifest entries, hashes, and provenance for the new artifacts.
- A guest check that EGL initializes the VirGL display.

Out of scope:

- Changing the reference build or its pin (IR-240).
- The production SELinux policy for end-user graphics access, which belongs
  to #035. This task verifies Mesa's EGL and GLES stack with a test-only
  diagnostic ODM policy; it does not validate or ship that policy.
- The Guest Agent and the other product services, which belong to #035.
- Performance work, which belongs to #022 and #023.

### Deliverables

- The product fragment under `Guest/product/`, and the Mesa build script under `scripts/guest/` (IR-497; the entry first named `Images/tools/`).
- A corrected image build with its own identity, recorded under `Images/reference/`.
- The guest check `apkrun.test=egl`, which prints `APKRUN-TEST: egl ok` only
  when `eglInitialize` succeeds on the VirGL display.

### Implementation steps

1. Compare the pinned Mesa sources with the Mesa libraries of build `16373615`.
   Record the missing loader paths, ABI, and dependencies in a receipt.
2. Build the minimal product fragment from the locked sources. Add every new
   component to `ThirdParty/ThirdParty.lock.json` with its revision and hashes.
3. Build the corrected image under its own identity. Record its manifest and
   hashes.
4. Boot the signed `2026.10.3` `full-control` diagnostic bundle derived from
   the corrected Mesa payload, then run `apkrun.test=egl` and HelloGL. Do not
   treat this test-only ODM policy as the product policy.

### Tests

- T0: manifest validation of the corrected identity.
- T2: `apkrun.test=egl` and HelloGL on the signed `2026.10.3` `full-control`
  diagnostic bundle derived from the corrected Mesa payload; the unchanged
  reference check on build `16373615`.

### Acceptance criteria

- [x] The corrected image has its own build identity, manifest, and hashes, and
      build `16373615` is unchanged (IR-1323).
- [x] In the guest, `eglInitialize` succeeds on the VirGL display (`apkrun.test=egl`) when the corrected Mesa payload is booted with the test-only `full-control` ODM diagnostic policy. The exact 2026.10.3 image passed the probe and rendered HelloGL in `untrusted_app` through VirGL (IR-1329, IR-1331, IR-1332). This verifies the Mesa runtime path, not production SELinux policy. The corrected 2026.10.2 image without a diagnostic overlay still fails EGL initialization; #035 step 8 must confirm graphics on the custom image under its enforcing product policy, without a diagnostic profile.
- [x] Every new artifact has recorded provenance, and every third-party component is pinned in the lock (IR-1326, IR-1327, IR-1328).
- [x] #064 is unaffected: its acceptance uses build `16373615`. Checked on 2026-10-10: `git diff main...HEAD` changes no path under `Images/reference/16373615/`, `Images/manifests/16373615/`, or the M01 #064 entry.

### Notes

- **Status (2026-10-16, corrected development variant built and booted to the graphics failure).**
  The source-to-image comparison receipt that ADR-0018 cites is now recorded at
  `Images/reference/variants/2026.10.1-cf16373615-arm64/mesa-payload-receipt.txt`,
  outside the protected `16373615` source-build paths. The Mesa-only Soong
  fragment is in `Guest/product/mesa/`; its staging script verifies the pinned
  Mesa manifest before copying the four libraries and manifest into the ignored
  prebuilt directory. The host T0 suite passes 32 tests. The product fragment
  has not been compiled by Soong because this host is macOS. The variant tool's
  focused T0 suite passes 50 tests; independent bundle validation confirms its
  manifest, signature, file hashes, and recorded input hashes.

  A signed stock-derived development bundle and a variant with
  `imageVersion` `2026.10.1-cf16373615-arm64` were rebuilt from the pinned
  source archive and current layout. The incomplete reference captures were
  omitted rather than attributed as a complete reference; IR-1323 records this
  choice. The variant manifest, build, inject, and reseal records are retained
  under `Images/reference/variants/2026.10.1-cf16373615-arm64/`. The image
  partition bytes are not committed. `boot-evidence.md` records the exact
  T2 result and the hashes of its local logs.

  The exact variant boot reached `virtio-gpu` and mounted `/vendor` after AVB
  resealing. SurfaceFlinger then failed `eglInitialize` with
  `EGL_NOT_INITIALIZED`; SELinux denied SurfaceFlinger's read of a sysfs
  `uevent` file while it had the generic `sysfs` label. `sys.boot_completed` was not
  reached, and `apkrun.test=egl` was not run on this boot. The prior EGL
  success in IR-997 remains evidence for the separate ODM-overlay variant; it
  does not establish success for this no-overlay boot. The product-policy
  route and its compiled guest check remain open. Flex and m4 now have
  source-release pins and license texts (IR-1326); the provenance-and-lock
  criterion is checked. Release-license reviews in IR-483 and IR-486 remain
  open.

- **Status (2026-10-16, pinned Mesa rebuild and 2026.10.2 VirGL boot: the EGL failure repeats).**
  The full Mesa build now uses pinned Flex 2.6.4 and GNU m4 1.4.20, and its
  manifest records both tools. The Flex cache stamp also includes the exact
  m4 executable hash. The four built libraries passed the output verifier;
  T0 passed 29 host checks and 35 checks including the built output. The
  staging verifier passed before and after copying the libraries into the
  Mesa product prebuilt directory.

  The rebuilt `libgallium_dri.so` has SHA-256
  `185a00dc816e33a366f758c0a3b6caf28fc3b226f3393e5656328506e4f671bc`;
  the previous 2026.10.1 record names a different library hash. To keep each
  boot result attached to the exact bytes tested, the 2026.10.1 bundle was
  rebuilt with the current variant tool and its disk and manifest hashes were
  confirmed unchanged before updating only its schema-3 builder record. The
  new Mesa output is recorded as variant
  `2026.10.2-cf16373615-arm64` under
  `Images/reference/variants/2026.10.2-cf16373615-arm64/`; its disk hash is
  `2b0fe6ddbe6031eeb60f309f0a4998db38d634d869d18b6715b63282333e3d3a`,
  and its manifest hash is
  `c61d182eb93dc980ceb4dae2cd4d8b840aea060835b45507197b0fccbe507978`.

  Its T2 run loaded `virtio_gpu` and mounted `/vendor`. SurfaceFlinger
  repeatedly received the sysfs `uevent` denial, failed to open a DRM device,
  and aborted after `eglInitialize` returned `EGL_NOT_INITIALIZED`. A second
  no-overlay run confirmed `ro.hardware.egl=mesa`, all four vendor-file labels,
  and that `card0` and `renderD128` existed with mode `0666`. Both runs
  remained without `sys.boot_completed` at 150 seconds; `apkrun.test=egl` did
  not run. The earlier controlled results in IR-1277 and IR-1279 link the same
  SurfaceFlinger `uevent` denial to a failed DRM probe and show the experimental
  overlay passing on the earlier #099 payload. That makes the policy gap the
  leading explanation. At the time this result was recorded, the exact
  2026.10.2 image had not yet had the overlay control; the later control run
  is recorded below and in IR-1329. Initial and repeat log hashes, excerpts,
  and command output are recorded in the variant's `boot-evidence.md`;
  IR-1328 records the artifact-identity choice and results.

- **Status (2026-10-16, exact-image ODM overlay control; diagnostic only).** A
  test-only control was built from the pinned `2026.10.2-cf16373615-arm64`
  bundle (manifest SHA-256
  `c61d182eb93dc980ceb4dae2cd4d8b840aea060835b45507197b0fccbe507978`,
  disk SHA-256
  `2b0fe6ddbe6031eeb60f309f0a4998db38d634d869d18b6715b63282333e3d3a`).
  `Experiments/sepolicy-022/odm_variant.py` completed its `prepare`, `build`,
  and `check` stages. The resulting
  `2026.10.3-cf16373615-arm64` control has manifest SHA-256
  `e7adceaecc799c3dbbfccd30b5cdf4eafa36908cb3973e8e99dc8fb8aac580ed`,
  disk SHA-256
  `2a408ef1e74de3c37bf7ec6372b04ae0843877529884abceb810b4b68f520217`,
  and test-only precompiled policy SHA-256
  `55748a7a098f628f2e56031da6d8ab4ea3c3c4abeaac047b64b0ffbd7be2d515`.
  The control adds 18 type-wide SELinux allow rules, the EGL probe binary, and
  its init service. This is broad: `untrusted_app` gets `open`, `read`, `write`,
  `ioctl`, and `map` on every `graphics_device`; five domains receive generic
  `sysfs` access; and the service starts automatically after
  `sys.boot_completed` with no opt-in gate. This control must not ship as a
  product image. The final builder receipt is
  `/tmp/apkrun-022-odm-2026102-control-final2/bundle/android-bundle.odm-control.json`
  (SHA-256
  `6cdc2758eb28129c95d140152fbef979b3fc1a62d70c9b1419726e8885c77660`).

  T2 installed and booted the control with:

  ```sh
  rtk env APKRUN_HOME=/tmp/apkrun-099-home-2026102-overlay-control-20261016 \
    .build/debug/apkrun dev image install \
    /tmp/apkrun-022-odm-2026102-control/bundle/android-bundle
  rtk lockf -k /tmp/apkrun-vm.lock env \
    APKRUN_HOME=/tmp/apkrun-099-home-2026102-overlay-control-20261016 \
    APKRUN_GUEST_DIR=/tmp/apkrun-099-guest \
    .build/debug/apkrun dev boot --gpu virgl --console
  ```

  The final build under `...control-final2` has the same manifest and disk
  hashes, as noted below. The guest reached `sys.boot_completed=1`;
  `ro.hardware.egl`
  was `mesa`; SELinux was `Enforcing`; and SurfaceFlinger reported
  `GLES: Mesa, virgl, OpenGL ES 3.0 Mesa 26.1.8`. The init-run probe printed
  `APKRUN-TEST: egl ok: eglInitialize 1.5, EGL_VENDOR Android, EGL_VERSION 1.5
  Android META-EGL`. The performance record reports `outcome=ready` for
  operation `1CF7B3B5-66A8-4259-A171-9494FB7F4D12`. The guest log is 9,006,320
  bytes (SHA-256
  `43cb412d7d3e284149db9e220532193562d02a9abdd3dc4ff701b7ffb13e97ec`); the VM
  log is 755,568 bytes (SHA-256
  `b7db85a3f9d32d65dbab3aa91989532d0df53f9aa6f28e15abd9c0fd663c2b40`).
  To reduce scratch-disk use, the exact guest log is gzip-retained at
  `/tmp/apkrun-099-20261016-broad-control-evidence/logcat-20261016T040950Z.log.gz`;
  decompressing it reproduces the recorded digest. The VM log and performance
  record are retained beside it.
  After the final builder-source edits, the bundle was rebuilt and `check`
  passed again. Its manifest and disk hashes are identical to the image used
  for this T2 run, so the boot evidence remains bound to the final checked
  artifact identity.

  This control changes the ODM policy and adds a diagnostic guest binary, so
  it does not establish which individual rule is necessary or that the
  production policy is correct. The probe calls `eglGetDisplay` and
  `eglInitialize` only; it does not create a GL context or render. Its reported
  `EGL_VENDOR=Android` and `EGL_VERSION=Android META-EGL` are distinct from
  SurfaceFlinger's Mesa/virgl renderer log. Some denials remained in this
  successful boot: SurfaceFlinger and the probe were denied generic `sysfs`
  `getattr`, and the probe was denied reading the `/odm/bin` parent directory.
  Thus success does not mean every denial was removed. The exact 2026.10.2
  no-overlay image still fails EGL initialization. The later 2026.10.4
  two-rule control below also passes only the diagnostic probe. Therefore
  acceptance criterion 2 remains unchecked; IR-1330 records this choice for
  maintainer review.

- **Status (2026-10-16, exact-image two-rule SurfaceFlinger control; diagnostic only).**
  The profile `surfaceflinger-egl` in
  `Experiments/sepolicy-022/odm_variant.py` adds exactly two precompiled-policy
  rules to the pinned 2026.10.2 image:
  `surfaceflinger sysfs:file open` and `surfaceflinger sysfs:file read`.
  Unlike `full-control`, it adds no `platform_app`, `untrusted_app`,
  `priv_app`, or `system_app` rules. `prepare`, `build`, and `check` passed
  with this profile. The image `2026.10.4-cf16373615-arm64` has manifest
  SHA-256
  `74af335c9db649715d705a85f497d8c00c1096d03e7f515b39de4817fe1bb5fb`,
  disk SHA-256
  `93457778bcfedc000dc4da2d56d0d2a69e962d65897bdf683356bb5d0d0af5b1`,
  and precompiled-policy SHA-256
  `cbcad7113c3acf70d5993f962d6c680fc5a7ca62faaae3753ab63f6922054b43`.
  The final-source control receipt is
  `/tmp/apkrun-022-odm-2026102-sf-control-final2/bundle/android-bundle.odm-control.json`
  (SHA-256
  `e8b28716cc73e758b5364feea224d00aec3b8e477c4c6961bf6c7e6693e44967`).

  T2 installed the corresponding bundle, whose manifest and disk hashes match
  the final-source bundle retained at
  `/tmp/apkrun-022-odm-2026102-sf-control-final2/bundle/android-bundle`, then
  booted with `--gpu virgl --console` in scratch home
  `/tmp/apkrun-099-home-2026102-sf-control-final-20261016`. The guest reached
  `sys.boot_completed=1`, reported `ro.hardware.egl=mesa` and SELinux
  `Enforcing`, and SurfaceFlinger logged Mesa, renderer `virgl`, and
  `OpenGL ES 3.0 Mesa 26.1.8`. The init-run test service logged
  `APKRUN-TEST: egl ok: eglInitialize 1.5, EGL_VENDOR Android, EGL_VERSION
  1.5 Android META-EGL`. Its `outcome=ready` performance record has operation
  `2466E74E-3C19-4D7E-9C69-E56F6EF18A5A`.
  The final-source rebuild under `...sf-control-final2` passed `check` with
  the same manifest and disk hashes as the tested bundle, so the T2 result is
  bound to those exact image bytes.

  The narrowed result still does not demonstrate app rendering. SurfaceFlinger
  continued to receive `sysfs` `getattr` denials. A `platform_app`
  `RenderThread` for `com.android.provision` was denied `read` on the generic
  `sysfs` `uevent` file; the same process then logged `EGL_NOT_INITIALIZED`
  and failed to create an HWUI context. The temporal association does not
  establish that this AVC caused the EGL failure. No `untrusted_app` Hello APK
  or successful application render was tested in this run. The later
  application-domain comparison is recorded below and in IR-1331. The probe remains an injected,
  automatically started test service in the `surfaceflinger` domain; it only
  calls `eglGetDisplay` and `eglInitialize`, and it does not create a context
  or render. At this point in the investigation, criterion 2 remained open.
  IR-1332 later scopes it to diagnostic verification of the Mesa runtime path;
  the broader control passes that check, while production policy remains for
  #035. Do not ship this diagnostic bundle.

  Evidence was retained outside the repository. The compressed guest log at
  `/tmp/apkrun-099-20261016-sf-control-evidence/logcat-20261016T042958Z.log.gz`
  decompresses to 51,220,816 bytes with SHA-256
  `483fe39923d79a6b58bc58a71561d9f911e17538964fa6655499f512e8bcad25`;
  the gzip file SHA-256 is
  `13f3a33b57940e7c1ba6818c066cd86efd139fbc0f387d4b2c3f61ee73af12a0`.
  The 1,152,096-byte VM log has SHA-256
  `666ab4bfdeb162078ed71be5d1a1120bf7e998659fe5ffb45eaa55fdeaa9c391`;
  the performance record has SHA-256
  `651bb10ec20903f31265af2e0bfdb07955740207d18b36bf12ec948f40054368`.

- **Status (2026-10-16, HelloGL application-domain control; diagnostic smoke only).**
  The fixture builder produced `HelloGL.apk` from the committed source and
  verified its pinned fixture signer; the APK SHA-256 is
  `0e5a451e3c3979a8e341baf893e9b8a2c4b50e395710a31dd7b182b1773cfea`.
  The exact `2026.10.3-cf16373615-arm64` `full-control` bundle retained from
  the earlier run was used without rebuild: its manifest and disk hashes are
  `e7adceaecc799c3dbbfccd30b5cdf4eafa36908cb3973e8e99dc8fb8aac580ed` and
  `2a408ef1e74de3c37bf7ec6372b04ae0843877529884abceb810b4b68f520217`.
  After dismissing the keyguard and starting HelloGL, the guest reached
  `sys.boot_completed=1`, `ro.hardware.egl=mesa`, and SELinux `Enforcing`.
  SurfaceFlinger reported `Mesa, virgl, OpenGL ES 3.0 Mesa 26.1.8`; HelloGL
  ran in `u:r:untrusted_app`, logged renderer `virgl`, and reported 59.7 and
  60.0 FPS. The host window showed the GLES surface with 62 fps, 7 dropped
  frames, 0 stalls, and 0 host readbacks. The boot performance record reports
  `outcome=ready`, operation `7E77DD5F-C93D-4520-AFEF-780D16A95B7F`.

  The same fixture was then installed on the exact
  `2026.10.4-cf16373615-arm64` `surfaceflinger-egl` control. That two-rule
  bundle has manifest and disk hashes
  `74af335c9db649715d705a85f497d8c00c1096d03e7f515b39de4817fe1bb5fb` and
  `93457778bcfedc000dc4da2d56d0d2a69e962d65897bdf683356bb5d0d0af5b1`.
  The guest reached `sys.boot_completed=1`; the injected SurfaceFlinger probe
  passed. HelloGL started in `u:r:untrusted_app` but aborted with
  `Failed to create context, error = EGL_NOT_INITIALIZED`; its tombstone
  traces the abort through `libhwui` `EglManager::createContext`. The retained
  guest log has three HelloGL crash records and 5,202 `EGL_NOT_INITIALIZED`
  entries, including repeated system-app failures. It records SurfaceFlinger
  `getattr` denials on generic sysfs entries and `platform_app` `read` denials
  on the generic `sysfs` `uevent` file for `com.android.provision` and
  SystemUI. No `untrusted_app` AVC appears in the retained log; audit events
  were dropped, so its absence does not establish that none occurred. The
  timing does not prove that any one denial caused HelloGL's abort.

  Both runs were short T2 smoke checks and are not the 60-second or 10-minute
  #023 checks, nor a G3 run. The broad control demonstrates an application
  render under its test-only 18-rule policy; the two-rule control demonstrates
  only the injected SurfaceFlinger probe. Neither validates product policy or
  identifies the permission needed by the failed HelloGL run. The original
  guest and VM logs are gzip-retained, with decompressed and retained hashes,
  boot records, app log, and screenshot under
  `/tmp/apkrun-099-20261016-hello-domain-evidence/`; its `SHA256SUMS`,
  `SOURCE-SHA256SUMS`, and `hello-gl-application-domain-results.md` record the
  evidence and limits. IR-1331 originally left acceptance criterion 2 open;
  IR-1332 supersedes that task-scope decision while preserving these results.

- Placement and the reasons for it are in IR-240. This task sits between #021 and
  #022, because #022 needs a working Mesa guest.
- The task cannot start until #021 is done, and #021 depends on #014, which waits
  for the Android boot in #064 (IR-298 to IR-302). It is recorded now so that the
  dependency is visible.
- Filed on 2026-10-09 as GitHub issue #99. A new task takes its GitHub issue number, so
  the task number and the issue number are both #099 (IR-293 covers the earlier offset).
- **Status (2026-10-12, the eglInitialize check on the ODM-overlay variant (IR-960), three locked boots: met on the third boot).** Boot 3 ran the binary directly as a service in the surfaceflinger domain, with no shell and no command-line gate (IR-992, IR-993). The guest's logcat capture holds `I APKRUN-TEST: egl ok: eglInitialize 1.5, EGL_VENDOR Android, EGL_VERSION 1.5 Android META-EGL` (pid 3301), so criterion 2 was ticked at that time (IR-997). The test prints no GL renderer. The VirGL display is inferred from the same boot's `GLES: Mesa, virgl`. The later no-overlay failure and the current acceptance status are recorded above. Boots 1 and 2 stopped at init (IR-994, IR-995). The open items are in IR-999.
- **Status (2026-10-11, the no-verity experiment: `disabled` is refused by the guest, and `logging` lets `/system`, `/odm`, `/product`, and `/system_ext` mount, but the injected `/vendor` never mounts and `ready` is not reached).** Judgments IR-728 (the experiment-only verity change) and IR-729 (how the stuck boots were stopped). Two VM boots were used, the last two allowed for this run, so the task has three boots in total.
  - Stock control. `/tmp/apkrun-test-linux/android-bundle` was not changed. The `shasum -a 256` values of its `manifest.json`, `SHA256SUMS`, `boot/cmdline.txt`, and `boot/bootconfig.txt` are the same before and after the experiment (`/tmp/apkrun-099-stock-control-before.txt` and `-after.txt`). Its `cmdline.txt` has no `veritymode` key, and its dm-verity tables in the #022 control log use `restart_on_corruption`.
  - Experiment bundle. `/tmp/apkrun-099-bundle-mesa-noverity` is the Mesa variant with one parameter appended to `boot/cmdline.txt`. The directory name follows the coordinator's plan, but the mode in it is `logging` (see boot B). `/tmp/apkrun-099-noverity-tool/make_noverity.py` builds it with the bundle module's own functions (`_file_entry`, `_checksums`, `render_signature`, `_load_signing_key` with `~/.config/apkrun/dev-image-key`), run by `Images/tools/.venv/bin/python`. The manifest differs from the base only in the two `boot/cmdline.txt` entries. `shasum -a 256 -c SHA256SUMS` gives OK for all six files, `validate` reports no violation, and OpenSSL verifies `manifest.sig`.
  - Boot A, `androidboot.veritymode=disabled`. The install into `/tmp/apkrun-099-home-noverity` printed `installed image 2026.10.0-cf16373615-arm64 from /tmp/apkrun-099-bundle-mesa-noverity` and `provisioned a new Android instance`, EXIT=0. The console shows `init: [libfs_avb] Unknown androidboot.veritymode: disabled`, `init: [libfs_avb] Failed to construct verity table.`, `init: Failed to mount /system: No such file or directory`, `init: InitFatalReboot: signal 6`, and then `reboot: Restarting system with command 'bootloader'`, which repeated 595 times. The first-stage `system/lib64/libfs_mgr.so` in the ramdisk names the modes `enforcing` and `logging`, and the guest refuses `disabled`. The boot was stopped as in IR-729, and its log ends with `EXIT=70`.
  - Boot B, `androidboot.veritymode=logging`, the closest mode that the guest accepts. The install into a fresh `/tmp/apkrun-099-home-logging` printed the same two lines, EXIT=0. The boot was `lockf -k /tmp/apkrun-vm.lock env APKRUN_HOME=/tmp/apkrun-099-home-logging APKRUN_GUEST_DIR=/tmp/apkrun-099-guest ./.build/debug/apkrun dev boot --gpu virgl`, and it printed `image 2026.10.0-cf16373615-arm64 (current)`, `state: booting(kernel)`, and `state: booting(init)`. It did not print `ready` or a `failed(...)` state. The console shows five verity tables with `ignore_corruption` and no restart. `/system`, `/odm`, `/product`, and `/system_ext` mount with `=0: Success`. The `/vendor` device, dm-6 on `254:6`, logs `device-mapper: verity: 254:6: metadata block 69747 is corrupted` and then `device-mapper: verity-fec: 254:6: FEC 1011712: failed to correct: -74`. There are 1,180 FEC failure lines. The last init line is the table build for dm-6, at guest +0.646 s, and init makes no progress after it. The guest clock reached about +586 s (about 9.8 minutes) with `booting(init)`. The adb endpoint stayed `127.0.0.1:6520 offline` (`adb devices`). The boot was stopped as in IR-729 and ends with `EXIT=70`.
  - Requested reads, not observed. `ready`: not reached. `sys.boot_completed`: `adb -s 127.0.0.1:6520 shell getprop sys.boot_completed` printed `adb: device offline`. `dumpsys SurfaceFlinger`: no GLES line, because adb could not reach the device.
  - Reading. The `logging` mode lets the other partitions mount, so the vbmeta mismatch of IR-625 is not the only obstacle. The injected `/vendor` still fails on FEC reads, which suggests that its FEC data was not regenerated either (`use_fec_from_device`, `fec_roots 2`). This is an inference from the log. The regenerated vendor hash tree (and FEC) is the product path, which is a separate follow-up.
  - Nothing is ticked. Criteria 1 and 2 need `ready` and `apkrun.test=egl`, which were not reached.
- **Status (2026-10-11, the Mesa variant installed into a scratch home and booted once with drmVirgl: dm-verity stops the boot before `/vendor`, and `ready` is not reached).** Judgments IR-726 (the scratch install, which supersedes IR-720 and IR-721) and IR-727 (the verity result, with no signing choice). This was the only VM boot of the run.
  - Install (task step 2). `APKRUN_HOME=/tmp/apkrun-099-home ./.build/debug/apkrun dev image install /tmp/apkrun-099-bundle-mesa/android-bundle` printed `installed image 2026.10.0-cf16373615-arm64 from /tmp/apkrun-099-bundle-mesa/android-bundle` and `provisioned a new Android instance`, EXIT=0. The install did not refuse the name or the signature. The default `~/Library/Application Support/APKRun-Dev` tree has the same stat hash before and after (`0621ef5f…`), and `~/Library/Application Support/APKRun` is absent before and after.
  - Guest Agent (task step 3). `scripts/build-guest.sh --out /tmp/apkrun-099-guest` ended with `build-guest: wrote /tmp/apkrun-099-guest/apkrun-guest.apk (versionCode 1000)`, EXIT=0. The boot needs it: `DevGuestAgentLocation` always returns a directory, and the bundle load fails without one.
  - adb (task step 5 prerequisite). The SDK copy is `/opt/homebrew/Caskroom/android-platform-tools/37.0.1/platform-tools`, copied to `/tmp/apkrun-099-platform-tools`, and it prints `Android Debug Bridge version 1.0.41`. No adb under `~/Documents` was used.
  - Boot (task step 4). `lockf -k /tmp/apkrun-vm.lock env APKRUN_HOME=/tmp/apkrun-099-home APKRUN_GUEST_DIR=/tmp/apkrun-099-guest ./.build/debug/apkrun dev boot --gpu virgl` (the flags were checked with `dev boot --help`) printed `image 2026.10.0-cf16373615-arm64 (current)`, `state: booting(kernel)`, `state: booting(init)`, `state: failed(runtime.vm)`, `error: Android stopped unexpectedly.`, `hint: Restart Android.`, `code: runtime.vm`, and `EXIT=1`. The state `ready` was not reached. The process exited about 431 s of wall time after the start, and the guest clock reached about 380 s in its reboot loop. `Logs/perf/boots.jsonl` records `"outcome":"failed:runtime.vm"`.
  - Guest console (`Logs/vm/console.log`; the key lines are copied to `/tmp/apkrun-099-verity-lines.txt`, outside the repository):
    - `device-mapper: verity-fec: 254:6: FEC: recursion too deep`
    - `device-mapper: verity: 254:6: metadata block 69747 is corrupted`
    - `reboot: Restarting system with command 'dm-verity device corrupted'`
    The guest rebooted 646 times in that run. The table for device 254:6 is `1 /dev/block/dm-6 /dev/block/dm-6 4096 4096 69747 69747 sha256 d8895f6a3dc07758a60bddc6de96b416d02a3e93da4e2a8cf63d0ea6bd783a5a`. The stock control (`/tmp/apkrun-022-check-boot.log`) has the same table and root digest, and there `/vendor` mounts from `dm-13`, as the other tables show (`dm-1` is the data device of `/system`, mounted from `dm-9`). So dm-6 is most likely the data device of `/vendor`, which is the injected `vendor_a`. This is an inference from the mount numbering; the variant's `/system`, `/odm`, `/product`, and `/system_ext` do mount. The root digest is the stock vendor root that the top-level vbmeta still holds (IR-625), and the injected tree has a different root, which is consistent with the failure.
    The line `Found unknown public key used to sign /system`, followed by `VerificationError`, also appears in the stock control, so it is not the cause.
  - **Answer to the first part of IR-650:** dm-verity blocks the injected `vendor_a` on the first boot. The choice of signing stays open (IR-727).
  - adb and SurfaceFlinger (task step 5). Not reached. `adb devices` showed `127.0.0.1:6520	offline` while the boot was in `booting(init)`. After the exit, `adb -s 127.0.0.1:6520 shell getprop sys.boot_completed` printed `adb: device '127.0.0.1:6520' not found`, and `dumpsys SurfaceFlinger` printed no GLES line. No `sys.boot_completed` value and no renderer string was observed.
  - Stop (task step 6). No SIGINT was sent, because the boot had exited at `failed(runtime.vm)`. `pgrep` found no `apkrun dev boot` or Virtualization process. A Gradle Kotlin daemon from the guest build (`KotlinCompileDaemon`, idle shutdown after 7200 s) is still running. It is not a VM. The scratch home was removed. Its installed image files are read-only, so `chmod -R u+w` was needed before `rm -rf`.
  - Nothing is ticked. Criteria 1 and 2 need the Android boot and `apkrun.test=egl`, which were not reached. The control of task step 7 (guestSwiftshader) was not run.
- **Status (2026-10-11, the first attempt, before the install was allowed: not run, no VM started, nothing installed; superseded by the install and boot above).** The variant is `/tmp/apkrun-099-bundle-mesa/android-bundle`, and the boot named in the task, `apkrun dev boot --bundle <dir> --gpu virgl`, does not exist in this CLI. `--bundle` was removed in #065 ([android-image.md](../../02-design/android-image.md) §10.2), and `dev boot` boots only `current`. The no-install decision of this experiment rules out the only other way to set `current`, so no boot ran. Judgments IR-720 to IR-725.
  - Build and sign (the task's steps 1 and 2). `swift build --traits EmbeddedRuntime --product apkrun` ended with `Build complete! (13.38秒)`, `EXIT=0` (log `/tmp/apkrun-099-vm-build.log`). Its two distinct warnings, each printed twice, come from the ZIPFoundation package, not from this repository. `codesign --force --sign - --entitlements CLI/apkrun/apkrun-dev.entitlements .build/debug/apkrun` replaced the signature.
  - Bundle check, before the boot. `shasum -a 256 -c SHA256SUMS` printed `OK` for all six files (`boot/bootconfig.txt`, `boot/cmdline.txt`, `boot/kernel`, `boot/ramdisk.img`, `disks/os.img`, `templates/userdata.img`). OpenSSL checked the Ed25519 signature over `manifest.json` with the developer key. The raw key was wrapped as a SPKI DER (prefix `302a300506032b6570032100`) and written as PEM, and the base64 `signature:` line of `manifest.sig` was decoded to bytes. `openssl pkeyutl -verify -pubin -inkey pub.pem -rawin -in manifest.json -sigfile sig.bin` printed `Signature Verified Successfully`, for the variant and for the stock test bundle. The key-id `55ab0dd032d0ce0e` is the first 8 bytes of SHA-256 of the developer key. The variant's manifest still says `imageVersion` `2026.10.0-cf16373615-arm64`, the stock name (IR-700 on main).
  - The task's step 3 (the guest build) was not run. The image check (`images.current()`, `DevBoot.swift` line 120) comes before the Guest Agent load (line 144), so the boot never asked for it (IR-723).
  - The task's step 4 (the boot). `lockf -k /tmp/apkrun-vm.lock env APKRUN_HOME=/tmp/apkrun-099-home ./.build/debug/apkrun dev boot --bundle /tmp/apkrun-099-bundle-mesa/android-bundle --gpu virgl` printed `error: The command arguments aren't valid.`, `hint: Run the command with --help to see the allowed values.`, `code: cli.invalidArguments`, `EXIT=64`. The first failing line is `error: The command arguments aren't valid.` The same command without `--bundle` printed `error: Android システムはまだインストールされていません。`, `hint: 設定 → ストレージから Android システムをインストールしてください。開発者は apkrun dev image install <bundle> を実行してください。`, `code: image.noCurrentImage`, `EXIT=1`. Neither run reached the VM, so there is no `ready` result, no `sys.boot_completed`, and no `dumpsys SurfaceFlinger` output.
  - The task's steps 5 and 6. No VM was started, so no SIGINT was sent. `pgrep` found no VM process. Two `gpg-agent` and `scdaemon` processes of another tool, under `/tmp/apkrun-099/`, are not VMs and were left alone. The scratch `APKRUN_HOME` was removed. The failure is not a verity result, so IR-650 stays open (IR-724).
  - The task's step 7 (the guestSwiftshader control) was not run. It needs `current` too (IR-723).
  - No acceptance criterion is ticked by this run.
- **Status (2026-10-11, step 2 offline: the vendor partition).** `python3 -m apkrun_image inject-vendor` rebuilds `vendor_a` from the stock `super.img` of build 16373615 with the four Mesa libraries in `/vendor/lib64/egl/` (IR-622). The stock partition reproduces exactly before anything is added (522 entries, IR-627). The injected rebuild differs from the stock only by the four files and by the size of their directory. The labels come from the image's own contexts (IR-623), and the verity tree and footer are made again with the vendored avbtool (IR-624). The output is `vendor_a.img` (291,229,696 bytes, the size of its super extent, IR-626) and `inject.json`. Both are written under `/tmp/apkrun-099-inject-out-final3`, outside the repository.
  - The output is **not booted and not signed.** The top-level `vbmeta` still holds the stock vendor root digest, so the partition does not verify until `vbmeta` is signed again. The key is not in this repository, so this step does not sign it (IR-625).
  - Criterion 1 stays open. It needs the corrected image as a whole (the super with this partition, its manifest, and its identity), which depends on IR-625 and IR-626. Criterion 2 needs the VM.
  - The Mesa output was rebuilt for this step with `scripts/guest/build-mesa-android.sh --out /tmp/apkrun-099-inject-mesa/out`, because the output of the earlier build was not on this machine (IR-620). Its four SHA-256 values equal ADR-0018's.
  - Pins: erofs-utils 1.9.4 (the bottle of the receipt, relocated, IR-621), and the vendored avbtool (`aosp-avbtool`). The tools are fetched with `python3 -m apkrun_image erofs-tools --out DIR`, and the tests that need them run when `APKRUN_EROFS_UTILS` names that directory.
  - Host checks that ran: `Images/tools` pytest (the whole suite, with `PYTHONPATH` set to this worktree, IR-631), the Swift lock checker on a copy of the lock inputs, `scripts/tests/test_third_party_build.py`, `test_third_party_notices.py`, and `test_guest_mesa_build.py` (with `--out` on the rebuilt output: 28 tests). Nothing started a VM.
  - **The VM check must verify,** in this order: (a) `ls -Z` on `/vendor/lib64/egl/*` gives `same_process_hal_file` (IR-623); (b) the EGL namespace finds `libgallium_dri.so` in `/vendor/lib64/egl`, which the guest's linker config shows (`/linkerconfig/ld.config.txt`), and if it does not, the fallback is the decision of IR-622; (c) the vendor partition verifies after the vbmeta decision of IR-625, and `init` mounts it; (d) `libEGL_mesa.so`, `libGLESv2_mesa.so`, and `libGLESv1_CM_mesa.so` load, and their DT_NEEDED entries resolve (`libz.so` is still an open check, IR-487); (e) the 37 imports of the symbol contract resolve against the guest's libraries (IR-488); (f) `eglInitialize` succeeds on the VirGL display, which is `apkrun.test=egl`; (g) the properties `ro.hardware.egl=mesa` and the bootconfig keys of graphics.md §9 are in the image in use.
- **Status (2026-10-11, step 3 offline: the bundle variant).** `python3 -m apkrun_image bundle-variant` builds a development bundle from the stock bundle `/tmp/apkrun-test-linux/android-bundle`, with the injected `vendor_a` in its `super` (IR-700 to IR-708). The stock bundle has no `super.img` of its own. Its super is the GPT partition `super` of `disks/os.img` (first LBA 288,768, 8,589,934,592 bytes, SHA-256 `7dd80d27…`), and the archive's sparse super is expanded into that partition.
  - Output: `/tmp/apkrun-099-bundle-mesa/android-bundle`, with the record `/tmp/apkrun-099-bundle-mesa/android-bundle.variant.json`. `disks/os.img` has SHA-256 `6232d85e…`, the super partition `66fb79ee…`, and `manifest.json` `84d08673…` (the stock manifest is `91131e5e…`). The two manifests differ only in the super hash and the `disks/os.img` entry. `imageVersion` and `kind` stay the stock's (IR-700). `manifest.sig` is made with the developer key (key ID `55ab0dd032d0ce0e`), and the top-level vbmeta is not signed again (IR-650). The writer reported one physical range, 350 output chunks, 8 metadata copies, and 8 partitions compared, as IR-666 predicted.
  - Checks that ran: the tool checks the stock bundle first, the stock super expansion, every byte outside the `vendor_a` extent (1,615,855,616 bytes into `os.img`, 291,229,696 bytes long), and the read-back of `vendor_a` as the injected image (`2cc0857c…`) followed by zeros. A separate script outside the repository repeated those checks on the output, and it also checked the file hashes, `SHA256SUMS`, `manifest.sig`, and the plain files, and found no problems. `Images/tools/tests/test_bundle_variant.py` has 18 tests, which use a synthetic super (IR-706).
  - **Not done:** no VM ran, and the variant is not booted. Criterion 1 stays open, because the variant has the stock identity (IR-700).
  - **Blocked for the VM step:** `apkrun dev image install <dir>` renames an install to `Images/<imageVersion>/` and sets `current` (android-image.md §10.3), and `apkrun dev boot` boots `current`. Installing the variant that way would take the stock's name. A decision on the variant's identity, or on a separate image root, is needed before the VM step can boot it.
  - **The VM check must verify,** in addition to (a) to (g) above: (h) the host reads the variant's `manifest.json` (`84d08673…`), and its `manifest.sig` passes the Debug trust store with key ID `55ab0dd032d0ce0e`; (i) in the guest, the logical partition `vendor_a` is 291,229,696 bytes, and its first 291,229,696 bytes hash to `2cc0857c…`, so the guest runs the injected partition (the node name, for example `/dev/block/mapper/vendor_a`, is to be confirmed in the guest); (j) the `vendor` mount and any dm-verity message are recorded, because the replaced partition does not match the stock vbmeta (IR-650: a blocked boot is the first result, and the key choice follows it); (k) the bootconfig keeps the stock vbmeta digest, which is right because `vbmeta_a` is unchanged, and the boot log shows no other digest mismatch.
- **Status (2026-10-11, the verity step: the vendor descriptor is refreshed, one drmVirgl boot).** The stock `vendor_a` (from the stock bundle's `super`, SHA-256 `a3ff3fb1…`) has a footer with algorithm `NONE`, 4 KiB blocks, `sha256`, the salt `16b6a5f2…162e`, and root digest `d8895f6a…83a5a`, and it keeps FEC with two roots. The stock `vbmeta_a` is `SHA256_RSA4096` with the AOSP test key (SHA-1 `2597c218…`), and its vendor descriptor is the stock one (IR-741).
  - The injected footer was already fresh (root `a373fc52…`, 185,974,784 bytes, no FEC, and `verify_image` passes). The fault was the vendor descriptor in `vbmeta_a`, which still described the stock layout: its tree at 285,683,712 bytes is block 69,747, which the `metadata block 69747` message names (IR-741). Verity is still on.
  - `vendor-reseal` reseals the injected image with a fresh footer and no FEC (IR-740). Its result is byte-identical to the injected `vendor_a` (`2cc0857c…`), because the footer was fresh. The vendor descriptor of the stock `vbmeta_a` is replaced with `avbtool update_partition_descriptor`, with the stock rollback index 1,780,617,600 and `NONE` (IR-743, IR-744). The new blob is 7,936 bytes, padded to 12,288, with SHA-256 `64c4ea5c…`.
  - `bundle-variant --reseal-output` writes the refreshed `vbmeta_a` into its GPT range, updates the manifest hash, and recomputes the bootconfig values with `calculate_vbmeta_bootconfig`: digest `b04a3b99…` and size 21,312, where the stock values are `0db35717…` and 22,912 (IR-746 to IR-748). The variant's disk differs from the stock only in the `vbmeta_a` range and inside `vendor_a`. Its manifest and `manifest.sig` are signed with the developer key `55ab0dd0…` (`~/.config/apkrun/dev-image-key`), which signed the stock bundle. An independent script outside the repository checked the signature, the file hashes, the vbmeta bytes, the descriptor, and the bootconfig digest.
  - One drmVirgl boot of the scratch instance (IR-750 to IR-753). Verity held: the vendor table is `'1 /dev/block/dm-6 … 45404 45404 sha256 a373fc52… restart_on_corruption'`, and `__mount(source=/dev/block/dm-13,target=/vendor,type=erofs)=0: Success` follows it. There are no corruption or FEC messages. The guest's `init` logged `OK_NOT_SIGNED` and continued, so the unlocked guest accepts `NONE`.
  - **Not reached:** `ready` and `sys.boot_completed`. The first failing line is logcat `F DEBUG : Abort message: 'no suitable EGLConfig found, giving up (format: 1, vendor: Android, version: 1.4 Android META-EGL …'` at 08:17:17.347, after `W EGL-MAIN : Failed to open any DRM device` at 08:17:17.286. SurfaceFlinger had started on `Threaded RenderEngine with SkiaGL Backend (Ganesh)`. Zygote then restarted 67 times, and `getprop sys.boot_completed` was polled 999 times without a `1`. SIGINT did not stop the boot in about three and a half minutes, so SIGKILL ended it (IR-752). No VM process is left, and the scratch home was removed.
  - **Open:** the guest's EGL cannot open a DRM device, although the kernel reports `virtio-gpu-pci` with `+virgl`. That is a graphics question for this task's criteria 1 to 3, and it is not solved here. The acceptance criteria stay unticked, because no `ready` or `sys.boot_completed` was seen. The key choice of IR-650 is open, because the guest accepted `NONE`.
- **Status (2026-10-10, host work only, no VM started).** The route is ADR-0018 (NDK, Mesa 26.1.8), accepted with the project owner's approval.
  - Step 1 (the comparison and the receipt, IR-440 to IR-451) is on `task/099-mesa-virgl-guest-image`. It is not on this branch, and ADR-0018 cites it.
  - Step 2 is partly done. The Mesa libraries from locked sources are built, and the lock pins them: `scripts/guest/build-mesa-android.sh` builds the four shipped libraries (`libEGL_mesa.so`, `libGLESv2_mesa.so`, `libGLESv1_CM_mesa.so`, `libgallium_dri.so`) from the pinned sources, and `ThirdParty/ThirdParty.lock.json` pins Mesa 26.1.8 and its build tools (group `guest-mesa`). The product fragment in `Guest/product/` is not done, so step 2 stays open.
  - Step 3, the corrected image with its own identity, is not done. No image is built. The build writes `manifest.json` next to the libraries, and it is the only provenance record so far.
  - Step 4, the boot and `apkrun.test=egl`, is not done. It needs the VM and the image.
  - Acceptance criterion 4 is checked (see above). Criteria 1 to 3 stay open. Criterion 1 needs the image, criterion 2 needs the VM, and criterion 3 needs the `flex` and `m4` pins (IR-485) and a maintainer decision on the app list (IR-483) and on the NDK licence (IR-486).
  - Host checks that ran: `scripts/tests/test_guest_mesa_build.py` (28 tests, 6 of them on the built output), the lock checker on a copy of the lock inputs (XcodeGen is not installed, see the commit message), the existing third-party tests, and `shellcheck`.
  - The output of the final build, with the NDK r28c, has the SHA-256 values `libEGL_mesa.so` `73cb1755…`, `libGLESv2_mesa.so` `7da942f6…`, `libGLESv1_CM_mesa.so` `2a082937…`, and `libgallium_dri.so` `a261e62b…`. Two builds with the same flags gave the same values. The output is outside the repository (IR-495).
  - Open for the VM and the image (IR-487 to IR-489): the symbol contract of 37 imports from the stub libraries and libdrm (`GUEST_SYMBOL_CONTRACT`), the `libz.so` entry, and the placement of the libraries in `vendor/lib64/egl/`.

- **Status (2026-10-16, offline AVB signing implementation; no VM boot).** The `vendor-reseal` path verifies the stock vbmeta authentication block, refreshes the vendor descriptor, signs with the pinned AOSP development test key that matches the stock AVB public key, and preserves the stock header, release string, descriptors, and public-key metadata. Before embedding, `bundle-variant` independently verifies the stock and refreshed signatures, compares the exact captured stock range and raw descriptor bytes, verifies the staged vendor and inject hashtrees, and binds their original data and footer descriptors to the checked inject output. The builder also checks the candidate key, vbmeta padding, descriptor position, the embedded vendor hash, and the stock disk hashes over the exact bytes consumed by the splice. IR-1321 records the key choice and these verification requirements for maintainer review. Focused T0 coverage passes (62 tests across `test_vendor_reseal.py`, `test_bundle_variant_refresh.py`, and `test_bundle_variant.py`), including malformed AVB headers, re-signed large-property changes, vendor descriptor version/flags changes, release-string changes, metadata changes, corrupted payloads, mismatched injected data, wrong keys, and nonzero padding. This is host-side verification only: no variant was built from the live stock bundle or booted, and #099's image identity and guest acceptance criteria remain open.
- **Status (2026-10-16, variant identity T0; no live bundle build or VM boot).** `bundle-variant` now requires `--image-version` in `YYYY.MM.N` form and `build_variant` requires the corresponding API argument. The chosen monthly sequence is combined with the original source build ID, leaving `kind: stock` and the complete Android source provenance unchanged. The manifest is validated, its file entries and `SHA256SUMS` are regenerated, and `manifest.sig` is re-signed. IR-1322 records this decision as needing maintainer review. Four focused T0 cases pass: manifest identity/provenance and signature regeneration, rejection of the stock version, rejection of a full or malformed argument, and CLI enforcement of the required option. The real corrected-image acceptance and guest boot remain open.
- **Status (2026-10-16, release fixture scan).** The release checker now recognizes the committed AOSP AVB RSA key in PKCS#1 PEM form and rejects its private material when it appears in the app bundle as PKCS#1 or unencrypted PKCS#8 PEM/DER, or as unmarked Base64. It also refuses encrypted private-key PEM blocks and recognized PKCS#5 `EncryptedPrivateKeyInfo` values in raw DER, hexadecimal, standard Base64, or URL-safe Base64, including unpadded and wrapped input. Base64 scanning first checks for a plausible DER sequence prefix, resynchronizes after incomplete Base64-looking fragments, and both Base64 and hex scans iterate matches without retaining per-fragment lists, avoiding allocation spikes on ordinary binary files. It validates DER structure and RSA component relationships; isolated encryption OIDs and public-key-only content remain accepted. IR-1337 records this checker behavior for maintainer review. These are host-side scanner tests and do not change #099's live image build or boot acceptance.

---

## #022 Android VirGL

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #021, #020, #099 |
| Requirements | FR-GFX-03 ([../traceability.md](../traceability.md) §2.3) |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §4.2, §4.4, §4.5, §4.7, §5.2–§5.4, §9, §12 (#022 and "Renderer integration"), §14, §16 |
| Modules / paths | GraphicsCore `VirtioGPUDevice` (3D path), `VirGLRenderer`, `Packages/GraphicsCore/Sources/GraphicsBridge/`; the Linux test initramfs; `Tests/Fixtures/graphics/`; `Tests/Fixtures/AndroidApps/HelloGL/`; `Tests/IntegrationTests/AndroidGraphicsTests/` |
| Risks / questions | R-02 |

### Goal

Android's graphics stack initializes with Mesa virgl, minigbm gralloc, and the ranchu HWC on the DRM path. Software rendering is not the normal path. The setup is documented and reproducible.

### Scope

- The 3D command set of §4.2: contexts, 3D resources, submit, transfers, fences, and polling (§4.4, §4.5).
- The device threads and fence polling (§4.7).
- The remaining `GraphicsBridge` functions of §5.2 except present.
- `VIRTIO_GPU_F_VIRGL` and `num_capsets` = 2 for `drmVirgl`.
- The headless Linux `virgl` run with `kmscube` (the renderer integration steps 1–2 of [../../02-design/graphics.md](../../02-design/graphics.md) §12). Step 3, in a window, is #023.
- The `drmVirgl` bootconfig of §9.
- The 2D renderer of the `guestSwiftshader` profile, so both profiles reach `boot_completed`.
- A command-stream recorder for the T1 replay test.
- The test-only readback mode behind the `APKRUN_TEST_READBACK` build flag, which reads a resource for the replay test ([../../05-development/coding-conventions.md](../../05-development/coding-conventions.md)). #023 extends it to pool buffers.
- The HelloGL fixture.
- Out of scope:
  - SurfacePool, present, and a window (#023).
  - Blob resources: they get `ERR_UNSPEC` (§4.2).

### Deliverables

- The 3D device path and `VirGLRenderer.swift`.
- The `virgl` check in the Linux test guest, with Mesa's virgl Gallium driver and `kmscube` from pinned Alpine packages.
- The recorded `kmscube` stream for optional local replay. Its historical 24.6 MiB capture was kept outside Git under `/tmp` with a pinned hash (IR-812); it is not currently present at that path, so regenerate it before rerunning the replay test. The repository keeps the synthetic fixture `synthetic-virgl-session.json` (IR-514).
- The test-only readback mode (`APKRUN_TEST_READBACK`).
- The `drmVirgl` profile in `apkrun dev boot --gpu virgl`.
- The HelloGL fixture: GLES 3.0 rendering, the `renderer <GL_RENDERER>` event, an `fps <average>` event every 10 s, and the alternating-color mode ([../test-strategy.md](../test-strategy.md) §4.2).
- `AndroidGraphicsTests` for VirGL SurfaceFlinger and for `boot_completed` with both profiles.

### Implementation steps

1. **3D commands.**
   - Complete the §4.2 command set over `GraphicsBridge`: `gb_ctx_*`, `gb_submit`, `gb_resource_*`, `gb_transfer_write`, `gb_transfer_read`, `gb_create_fence`, and `gb_poll`.
   - Run the device queue, the render thread (`.userInteractive`), and the completion waiter (§4.7). Poll fences every 1 ms.
   - Enforce the limits of §5.4.
   - Check: T0 covers the `ResourceTable` limits, overflow, and reset clearing.
2. **Linux VirGL.**
   - Add Mesa's virgl driver and `kmscube` to the Linux test initramfs.
   - `apkrun dev linux --tests virgl` runs `kmscube` headless on scanout 0. The check reads the `virgl` renderer name from its output.
   - Record the command stream with the recorder. Keep the 24.6 MiB capture outside Git and record its path and hash; regenerate it when unavailable (IR-812, IR-1343).
   - Check: T2 `virgl` reports `renderer=virgl` and `Rendered 59 frames` for 60 requested, and `rendererFailures = 0` after shutdown. A test recorder also samples at most 4096 bytes from resource 4's attached backing once before its first renderer submission; it retains counts only and requires at least 864 sampled bytes and one nonzero byte (IR-1334). This proves only that mapped guest memory was nonzero at sample time. It does not show that the submission consumed those bytes or compare pixels. The test also checks `hostReadbacks = 0`, but that counter has no increment path yet (IR-816).
   - An opt-in lifecycle-gate T2 starts long-running `kmscube`, confirms resource 4's backing is attached, pauses the guest process, and holds reset or forced stop at a guest handshake. `VMController.pause()` drains renderer work through the serialized device callback before the host snapshots the still-attached backing. The test uses an idle FIFO for `kmscube` stdin because `/dev/null` causes its `select()` loop to exit on EOF. This adds reset/stop lifecycle evidence but does not prove an operation was pending at invalidation (IR-1335).
3. **Replay tests.**
   - The synthetic fixture replays through the device and compares the scanout hash exactly. The test-only readback mode exists only in builds with `APKRUN_TEST_READBACK` and does not touch `hostReadbacks`.
   - When `APKRUN_TEST_KMSCUBE_RECORDING` is supplied, the T1 test replays every operation in the recorded Linux `kmscube` stream and requires no renderer failures or rejected submits. Replay supplies zero-filled guest backing and the renderer recording has no scanout identity or reference image, so this check does not claim `kmscube` pixel or scanout equivalence. The `hostReadbacks` and `guestReadbacks` zero assertions are guards only; these counters cannot move on this replay path (IR-816).
   - Check: the synthetic fixture's expected scanout hash matches exactly, and the optional `kmscube` recording replays all operations without renderer failures. Guest-written pointer contents and transfer correlation remain open under IR-849. A faithful `kmscube` pixel comparison would need a bounded guest workload, known backing contents, a scanout mapping, and an expected image; see IR-1343.
4. **drmVirgl boot.**
   - Boot Android with the `drmVirgl` bootconfig of §9: `egl=mesa`, `gralloc=minigbm`, `hwcomposer=ranchu`, `hwcomposer.mode=client`, `display_finder_mode=drm`, `cpuvulkan.version=0`, and `opengles.version=196608`.
   - Check: `sys.boot_completed=1`, `dumpsys SurfaceFlinger | grep -i GLES` names the virgl renderer, and SurfaceFlinger's `/proc/<pid>/maps` has no SwiftShader or in-guest ANGLE library.
5. **guestSwiftshader 2D path.**
   - Implement the 2D renderer of §9 for `guestSwiftshader`. It uses `replaceRegion` and counts `cpuPixelCopies`.
   - Check: T2 reaches `boot_completed` with `--gpu swiftshader`.
6. **HelloGL.**
   - Add the HelloGL fixture to the fixture project.
   - Check: on `drmVirgl`, HelloGL's `renderer` event contains `virgl`.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.3.

- **T0** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`): `ResourceTable` limits, overflow, backing validation, and reset clearing; the recorder's bounded resource sample, count-only result, and resampling after detach.
- **T1** (`Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`): the `kmscube` replay needs Metal. The synthetic fixture runs in the repository, reads the scanout through the test-only API, and compares its hash exactly (IR-514, IR-516). The optional `kmscube` recording runs when `APKRUN_TEST_KMSCUBE_RECORDING` names a locally regenerated capture; it checks operation traversal and renderer failures, performs no output readback, and does not compare pixels. Its zero-readback counter assertions are guards only (IR-812, IR-814, IR-816, IR-1343).
- **T2:**
  - `LinuxGuestTests`, check `virgl`: `kmscube` with the `virgl` renderer, `rendererFailures = 0`, the bounded resource 4 sample in step 2 (IR-1334), and the currently uninstrumented `hostReadbacks = 0` guard (IR-816).
  - `LinuxGuestTests`: `testGuestResetCompletesWithPausedKmscubeAndAttachedVirGLBacking` and `testForcedStopCompletesWithPausedKmscubeAndAttachedVirGLBacking` observe resource 4 backing across reset and forced stop while `kmscube` is paused (IR-1335).
  - `AndroidGraphicsTests`: VirGL SurfaceFlinger, and `boot_completed` with `drmVirgl` and with `guestSwiftshader`.

### Acceptance criteria

- [x] The guest graphics stack initializes, and software rendering is not the normal path: `dumpsys SurfaceFlinger` names the virgl GLES renderer. Observed on the ODM-overlay variant (IR-961).
- [x] Mesa, VirGL, gralloc, the HWC, and the DRM path are documented in §9 (§9.1 and §9.2) and reproducible from the committed bootconfig. The T0 golden and two offline stock builds give the same drmVirgl bootconfig (IR-980).
- [x] SurfaceFlinger loads no SwiftShader or in-guest ANGLE library.
- [x] Android reaches `sys.boot_completed=1` with `drmVirgl` and with `guestSwiftshader`. drmVirgl observed on the ODM-overlay variant, and guestSwiftshader on the stock image (IR-961).
- [x] The Linux test guest reports `renderer=virgl` and `Rendered 59 frames` for 60 requested, and `rendererFailures == 0` after shutdown. The focused signed `LinuxGuest` run on 2026-10-16 passed in 1.205 s with `VirglTests.testKmscubeHasNonzeroResource4BackingWithoutRendererFailures` (IR-1333, IR-1334). This criterion checks the guest report and recorded renderer errors; it does not compare pixels. The test also keeps the `hostReadbacks == 0` guard, but that counter has no increment path and is not evidence of readback behavior (IR-816). The replay of the recorded stream rejects 0 submits after the attach_iov change (IR-836). This narrowed criterion and its checked status need maintainer review (IR-1333).
- [x] Guest-controlled sizes and IDs are checked against the limits of §5.4.

### Notes

- **Status (2026-10-12, criterion 2: the drmVirgl components are documented in [graphics.md](../../02-design/graphics.md) §9.1 and §9.2, and the bootconfig is reproduced offline; no VM run; IR-970 to IR-981).** The T0 test `test_the_drm_virgl_bootconfig_follows_from_the_committed_layout` passes, and it failed when a drmVirgl value of the layout was changed for a check and then restored. Two offline builds of the pinned stock archive (SHA-256 `051caf80…`) give the same `boot/bootconfig.txt` (`35402a02…`), `manifest.json` (`e9656581…`), and merged drmVirgl text (`9fad6319…`, 40 keys). The DRM path is documented to `/dev/dri/card0`, and no capture, script, or source file in the repository records a render node. This status adds no VM result.
- **Historical status (2026-10-11, step 3 on the `kmscube` recording; IR-812 to IR-850).** One Linux run with the recorder attached passed, and its historical 25,763,085-byte recording had SHA-256 `0f7010c7bd0e10228900420859a1d8d035fe47be2733a40d656b71886c0df46a`. T1 replay initially rejected 61 `submit` calls; after the `attach_iov` correction, a later replay passed all recorded operations (IR-836). The live run's 122 failure lines are the same 61 rejected calls (IR-813). This established a renderer-replay defect and its correction, not pixel equivalence. The historical capture is no longer present at `/tmp/apkrun-022-kms/kmscube-recording.json`; regenerate it before rerunning the optional replay test (IR-1343). Criterion 5's narrowed guest-report and renderer-failure check is recorded in IR-1333; the original KMSCube pixel/hash expectation remains under review (IR-1343), and `hostReadbacks = 0` is not a measurement (IR-816).
- **Status (2026-10-11, criterion 3 ticked on the third boot, the ODM variant of IR-949 read as root).** One drmVirgl boot (`apkrun dev boot --gpu virgl --console`, under `lockf`, enforcing, no runtime policy load) reached `state: ready` in 12.2 s, with `sys.boot_completed` `1` and `getenforce` `Enforcing`. After `adb root`, `cat /proc/707/maps` (SurfaceFlinger, pid 707) gave 1,010 lines. `grep -ci 'swiftshader\|angle'` over that file gives **0**. The 27 mapped lines that match `egl`, `gles` or `gallium` name these eight libraries: `/system/lib64/libEGL.so`, `/system/lib64/libGLESv1_CM.so`, `/system/lib64/libGLESv2.so`, `/system/lib64/libegl_flags.so`, `/vendor/lib64/egl/libEGL_mesa.so`, `/vendor/lib64/egl/libGLESv1_CM_mesa.so`, `/vendor/lib64/egl/libGLESv2_mesa.so`, and `/vendor/lib64/egl/libgallium_dri.so`. The renderer line is `GLES: Mesa, virgl, OpenGL ES 3.0 Mesa 26.1.8`. SurfaceFlinger did not abort in this boot. Its IR number is not assigned: IR-940 to IR-959 are used and IR-960 is on `main`, so the maintainer should record this check. The other criteria are not changed. Criterion 1 may now be met by the same `dumpsys` line, which the maintainer should decide.
- **Status (2026-10-11, the boot-time ODM variant: one drmVirgl boot with the rule compiled into the image reached `ready` under enforcing, with no policy loaded at runtime, but apps abort on the same uevent read; no criterion is ticked; IR-949 to IR-959).** The variant puts the same two allow calls, `allow surfaceflinger sysfs:file { open }` and `{ read }`, into the ODM precompiled policy that `init` loads, and it reseals the `odm` descriptor of `vbmeta_a` (IR-949 to IR-951). The ODM root digest in `vbmeta_a` matches the repacked image before the boot (IR-951). The boot reached `state: ready` in 16.0 s, with `sys.boot_completed` 1, `getenforce` `Enforcing`, and `GLES: Mesa, virgl, OpenGL ES 3.0 Mesa 26.1.8` for SurfaceFlinger (IR-954). The `platform_app` and `system_app` processes read the same uevent node and abort in EGL context creation (609 aborts in the logcat), so the SurfaceFlinger rule alone does not give a working UI (IR-954, IR-958). The image is a test image with an ODM without FEC (IR-950).
- **Status (2026-10-11, the test-only sepolicy experiment: one rule of the running policy lets the drmVirgl boot reach `ready`; the image is not changed at boot, and no criterion is ticked; IR-940 to IR-948).** The guest loads `/odm/etc/selinux/precompiled_sepolicy` at boot, not the ramdisk `/sepolicy` (IR-943, which corrects IR-900 and IR-905 on that point). The denials on the virtio-gpu `uevent` need `allow surfaceflinger sysfs:file { open read }` (IR-942). The rule was loaded at runtime into the running policy, by a write to `/sys/fs/selinux/load` of the precompiled file plus the rule (IR-946). One boot with `apkrun dev boot --gpu virgl` under the lock, enforcing, then reached `state: ready` with `sys.boot_completed=1`, `dumpsys SurfaceFlinger` naming `GLES: Mesa, virgl, OpenGL ES 3.0 Mesa 26.1.8`, and `getenforce` `Enforcing` (IR-947). This is evidence for #035. It is not a criterion result: the boot used the unedited image, and a boot-time edit needs an ODM partition and a `vbmeta_a` descriptor change, which is a follow-up (IR-946). The stop was a SIGINT to the apkrun process, and its exit status was 1 (IR-948).
- **Status (2026-10-11, the no-verity experiment on the Mesa variant: no `ready`; `disabled` is refused, and `logging` lets the other partitions mount but the injected `/vendor` does not mount; step 4 stays open).** Two more VM boots of the variant, the last two of this run, in addition to the one below. `sys.boot_completed` and the SurfaceFlinger renderer were not observed, because adb reported the device offline throughout. The exact lines and the reasons are in the #099 entry (IR-728, IR-729).
- **Status (2026-10-11, the drmVirgl boot on the Mesa variant: dm-verity stops it before `/vendor`; step 4 stays open).** One VM boot of the variant of #099 (`/tmp/apkrun-099-bundle-mesa/android-bundle`, installed into a scratch `APKRUN_HOME`), with `apkrun dev boot --gpu virgl`. It printed `state: failed(runtime.vm)`, `code: runtime.vm`, and `EXIT=1`. The guest console shows `device-mapper: verity: 254:6: metadata block 69747 is corrupted` and `reboot: Restarting system with command 'dm-verity device corrupted'`, and the guest rebooted in a loop until the host stopped it. Android did not reach `ready`, so the Mesa libraries, `sys.boot_completed`, and the SurfaceFlinger renderer were not checked. Criterion 1 stays open. The commands, the exact lines, and the reasons are in the #099 entry (IR-726, IR-727).
- **Status (2026-10-11, the first attempt: not run; superseded by the boot above).** The variant of #099 (`/tmp/apkrun-099-bundle-mesa/android-bundle`) was not booted. `apkrun dev boot --bundle <dir> --gpu virgl` fails in argument parsing with `code: cli.invalidArguments` and `EXIT=64`, because `--bundle` was removed in #065. Without `--bundle`, `apkrun dev boot --gpu virgl` on an empty scratch `APKRUN_HOME` fails with `code: image.noCurrentImage` and `EXIT=1`, because nothing is installed and the no-install decision holds. Neither run started a VM. So there is no evidence on IR-650 (whether dm-verity blocks the injected image) and no evidence from the Mesa variant for criterion 1. The commands and lines are in the #099 entry (IR-720 to IR-725).
- **Status (2026-10-16, step 2: the Linux guest test passes with renderer failures asserted to zero).** `xcodebuild build-for-testing` and `lockf -k /tmp/apkrun-vm.lock xcodebuild test-without-building` used the signed `LinuxGuest` configuration, `/tmp/apkrun-test-linux`, and an isolated DerivedData directory. `VirglTests.testKmscubeRunsHeadlesslyThroughVirglWithoutRendererFailures` passed (1 test, 1.228 s); its guest-detail assertions confirmed `renderer=virgl` and `requested=60 reported=59`, and the post-shutdown assertion confirmed `rendererFailures == 0`. The result bundle is `/tmp/apkrun-022-renderer-zero-final-20261016.xcresult`. This does not close IR-849's guest-byte pointer, attached-backing reset/stop, or resource 4 checks, and it does not prove pixel output. `hostReadbacks == 0` remains an uninstrumented guard (IR-816).
- **Status (2026-10-16, step 2: the bounded resource 4 backing observation passes; partial evidence for IR-849).** Six focused T0 tests passed: both new observer tests plus the existing recorder and replay tests (`swift test --package-path Packages/GraphicsCore --filter 'aRecordedSessionReplaysToTheSameEngineCalls|aRecorderDoesNotChangeTheResponsesOrTheEngineCalls|aWrittenRecordingIsTheReplayFormat|aRecordingFromAnotherVersionIsRejected|recorderCountsNonzeroBytesWithoutRecordingGuestData|recorderBoundsSamplesAndReobservesAfterDetach'`). The signed `LinuxGuest` run built with `xcodebuild build-for-testing` and ran under `lockf -k /tmp/apkrun-vm.lock`; `VirglTests.testKmscubeHasNonzeroResource4BackingWithoutRendererFailures` passed in 1.205 s. It confirmed `renderer=virgl`, `requested=60 reported=59`, `rendererFailures == 0` after shutdown, and at least 864 sampled bytes plus one nonzero byte in resource 4's first 4096 backing bytes. Its result bundle is `/tmp/apkrun-022-backing-observer-20261016.xcresult`. The observer retains counts only and samples once per attachment, bounding its work. This proves that the attached host mapping exposed nonzero guest memory at sample time; it does not identify a known canary, tie the bytes to a specific transfer or submission, or prove pixel output. IR-849 remains open for stronger guest-byte correlation and reset/stop ordering. `hostReadbacks == 0` remains an uninstrumented guard (IR-816).
- **Status (2026-10-16, step 2: attached backing survives paused reset and stop; partial evidence for IR-849; pending review in IR-1335).** `xcodebuild build-for-testing` succeeded for the signed `LinuxGuest` host. The final focused test run under `lockf -k /tmp/apkrun-vm.lock` passed both `VirglTests.testForcedStopCompletesWithPausedKmscubeAndAttachedVirGLBacking` (1.081 s) and `VirglTests.testGuestResetCompletesWithPausedKmscubeAndAttachedVirGLBacking` (1.506 s), 2.587 s total. The guest pauses `kmscube`, the host observes `.paused` after the serialized `deviceWillPause()` renderer drain, confirms resource 4 is still attached, and releases the guest operation only after resuming. The reset case observes the guest reboot; the stop case observes the guest stop marker before the harness stops the VM. Result bundle: `/tmp/apkrun-022-lifecycle/VirGL-lifecycle-fifo-renamed-final.xcresult`. The rebuilt initramfs SHA-256 is `6e77e146b25bfed2d90fa5cd8ab0091c6a36721d6deb99cc7edda217e7fdd20f`. The check does not identify a known guest canary, prove a transfer consumed sampled bytes, compare pixels, or prove a renderer operation remained in flight at invalidation; IR-849 remains open. `hostReadbacks == 0` remains uninstrumented (IR-816).
- **Status (2026-10-11, step 4 on the VM: the drmVirgl boot does not reach `sys.boot_completed=1`; this is the evidence for criterion 1, which stays open).** `apkrun dev boot --gpu virgl` on the test bundle `/tmp/apkrun-test-linux/android-bundle` (image `2026.10.0-cf16373615-arm64`, the stock build) reaches `booting(systemServer)` and then ends with `failed(runtime.bootStalled)` after about 10 minutes. `sys.boot_completed` is never set. The cause is a mismatch: the drmVirgl plan names a Mesa EGL driver (`ro.hardware.egl=mesa`, [graphics.md](../../02-design/graphics.md) §9), and the test bundle, the stock build, has none. The host renderer is not the cause (IR-660). SurfaceFlinger's RenderEngine calls `eglGetDisplay`, libEGL cannot load the `mesa` driver that `ro.hardware.egl=mesa` names, and the process aborts. The guest logcat, pulled with `adb logcat -d -b all` from a copy of platform-tools under `/tmp` (IR-388), shows:
  - `D libEGL  : Failed to load drivers from property ro.hardware.egl with value mesa`
  - `F libEGL  : couldn't find an OpenGL ES implementation, make sure one of persist.graphics.egl, ro.hardware.egl and ro.board.platform is set`
  - `F libc    : Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 746 (surfaceflinger), pid 703 (surfaceflinger)`
  - the backtrace, top frames: `#00 abort+160` in `libc.so`, `#01 __android_log_default_aborter+12` and `#02 __android_log_assert+292` in `liblog.so`, `#03 android::Loader::open(android::egl_connection_t*)+2536` in `/system/lib64/libEGL.so`, `#04 android::egl_init_drivers()+80` and `#05 eglGetDisplay+24` in `libEGL.so`, and `#06 android::renderengine::skia::SkiaGLRenderEngine::create(...)+44` in `/system/bin/surfaceflinger`.
- The stock image has no Mesa EGL driver. In the guest, `/vendor/lib64/egl/` holds only `libEGL_emulation.so`, `libGLESv1_CM_emulation.so`, and `libGLESv2_emulation.so`. `libEGL_mesa.so`, `libGLESv2_mesa.so`, `libGLESv1_CM_mesa.so`, and `/vendor/lib64/dri/` do not exist, and `/vendor/lib64/hw` has `gralloc.default.so` and `mapper.minigbm.so` but no `gralloc.minigbm.so`. The drmVirgl bootconfig names `egl=mesa` and `gralloc=minigbm` ([graphics.md](../../02-design/graphics.md) §9). The four Mesa libraries that the #099 vendor injection adds (`inject.json`: `libEGL_mesa.so`, `libGLESv2_mesa.so`, `libGLESv1_CM_mesa.so`, `libgallium_dri.so`) are not in this bundle. The injected partition is not signed and is not in a bundle yet (IR-625, IR-661).
- Control (IR-664): the same bundle, host, and instance, with `--gpu swiftshader`, reaches `booting(bootCompleted)` and `ready` with `sys.boot_completed=1`. The CLI reports `Android is ready after 9.7 seconds`. The run has no SurfaceFlinger abort, and its GLES renderer is ANGLE on SwiftShader. The profile also drops the VirGL device (`features: -virgl`, no cap sets), so the control shows only that this bundle boots without the Mesa driver. It does not isolate the Mesa driver alone.
- The host renderer is not reached. The guest's virtio-gpu driver initializes with `+virgl` and cap sets 1 and 2, and the logcat has no virtio-gpu or DRM error. The abort happens before any GL call.
- The SurfaceFlinger abort repeats about every 5 s for the whole boot (120 aborts in the run). `zygote64` also aborts 3 times (pids 1385, 1503, and 1846) with the same libEGL error while it preloads the graphics driver. The init log then says `process with updatable components 'surfaceflinger' exited 4 times before boot completed`, but `runtime.bootStalled` names only the phase `systemServer` (IR-662). An earlier console log of the same profile (`/tmp/apkrun-022-check-boot.log`, line 2788) has the same SIGABRT, with 120 aborts.
- The allocator service (`android.hardware.graphics.allocator-service.minigbm`) logs 478 `Failed to convert descriptor. Unsupported format 0x3c` errors in this run, and 10 in the control. The first is at 02:55:22, after SurfaceFlinger's first abort. They are not examined here (IR-666).
- **Owner:** #099, the corrected image with signed Mesa libraries in its bundle. Not fixed here (IR-661).
- **Reproduction (IR-663, IR-388):** `apkrun dev boot` needs a Guest Agent bundle, so the run used `scripts/build-guest.sh --out /tmp/apkrun-022-sf-guest` and `APKRUN_GUEST_DIR`. The CLI is built from this branch with `--traits EmbeddedRuntime` and signed with `CLI/apkrun/apkrun-dev.entitlements`. The VM ran twice, each under `lockf -k /tmp/apkrun-vm.lock`, and the logs are in `/tmp/apkrun-022-sf-logs/` (not committed).
- **Status (2026-10-16, signed Mesa bundle under the diagnostic policy).** The
  corrected Mesa payload now boots with `--gpu virgl` and passes the guest EGL
  probe. The exact 2026.10.3 `full-control` diagnostic image also rendered
  HelloGL in `untrusted_app` (IR-1331, IR-1332). The no-overlay policy gap is
  deferred to #035; these diagnostic rules are not production policy. The
  `--gpu` default stays `none` (IR-584).
- **Status (2026-10-11, super writer, offline, no VM started).** `apkrun_image.lp_write.replace_partition` writes a copy of the stock `super.img` with the injected `vendor_a` (IR-680 to IR-689). An unchanged super round-trips to identical bytes, and the replacement reads back as the injected image, checked over all 8 GiB by a separate expander. The top-level vbmeta is not re-signed (IR-625), so this is not a boot result, and the first boot decides whether the mismatch blocks it (IR-650).
- **Status (2026-10-10, step 4 host side, no VM started).** RuntimeCore attaches the drmVirgl device, the VirGL device of `VirtioGPUDevice.virgl()`, so the refusal of IR-380 no longer applies to this profile (IR-580), and `apkrun dev boot --gpu virgl` is offered while the default stays `none` (IR-584). T0 checks the drmVirgl boot plan against graphics.md §9 (`ImageCoreTests`, `AndroidBootPlannerTests`), and the T1 suite `AndroidGraphicsDevicesRendererTests` checks the device with the real VirGL renderer. The boot on the VM did not run. Step 4 and criteria 1 to 4 stay open until the VM check. The integration test that refused drmVirgl, `AndroidGraphicsRefusalTests`, is removed (IR-583).
- **Status (2026-10-10, step 2 on the Linux test guest).** Step 2 is done. `kmscube` ran headless on the Linux test guest through the virgl renderer, the guest reported `renderer: "virgl"` on Mesa 25.2.7, and `VirglTests` (LinuxGuest, T2) passed with `hostReadbacks == 0` (graphics.md §16). The Mesa packages are pinned from Alpine v3.23, because v3.24 Mesa has no virgl driver (IR-500). The initramfs is built on the Mac, and the x86-64 builder of #099 is not needed (IR-503). Two judgment changes came with it: `GET_CAPSET` answers every version up to the maximum (IR-504), and the check counts the frames that kmscube reports (IR-506). Criteria 1 to 4 stay open: they need the `drmVirgl` boot (step 4) and the `guestSwiftshader` boot (step 5), which this step does not run. Step 3 was done later, with a synthetic fixture (the status below), and step 6 is open.
- **Status (2026-10-10, step 3 without a VM).** Step 3 is done with a synthetic fixture, not the `kmscube` stream. No Linux run recorded that stream: the virgl runs attached no recorder, and their artifacts hold only the console and the os_log output (IR-514). `Tests/Fixtures/graphics/synthetic-virgl-session.json` is six renderer calls that the existing helpers make, recorded by `RecordingVirGLEngine` around a real renderer (5,026 bytes). The T1 test `theSyntheticSessionReplaysOnTheDeviceAndItsScanoutMatches` replays it on a drmVirgl device through the test-only seams of `APKRUN_TEST_READBACK` (IR-515). It reads the 16 × 16 target and matches the image of the recorded transfers exactly (tolerance zero, IR-516). It also requires `hostReadbacks` and `guestReadbacks` to stay at 0. The check "T1 passes on a Mac runner" ran on this Mac, not on a CI runner. The `kmscube` recording and its replay stay open: they need one Linux run with a recorder attached (IR-519). Step 6 is open, and criteria 1 to 4 stay open as before.
- Earlier status (2026-10-10, host work only, no VM started). Criteria 1 to 5 were not met then, because each needed a VM run. Criterion 1 and criterion 3 need a `drmVirgl` boot, which RuntimeCore still refuses (IR-462). Criterion 2: [../../02-design/graphics.md](../../02-design/graphics.md) §9 documents the profile, and the committed image manifest carries the same seven keys, but the reproducible boot is not run. Criterion 4: the `drmVirgl` boot is refused, and the `guestSwiftshader` boot is not run here. Criterion 5 needed the Linux guest's `virgl` check (step 2). That check is now done (see the status above); the x86-64 builder of #099 was not needed (IR-503).
- **Steps not done in the host pass:** step 2 (the Linux `virgl` run and its initramfs, and the kmscube recording; done later, see the status above); step 4 (the `drmVirgl` boot and the removal of the refusal of IR-380); step 5 (the `guestSwiftshader` boot check); step 6 (the HelloGL check on `drmVirgl`, although the fixture builds offline, IR-477).
- **Met at T0 and T1 without a VM:** the 3D command set, contexts, resources, submit, transfers, fences, and polling (steps 1 and 3); the limits of §5.4 (criterion 6); the 2D path of `guestSwiftshader` as host memory (IR-474); the recorder and the replay (IR-475); and a round trip through the real renderer, which found the context-sharing defect now fixed in IR-463.
- **Judgment records:** IR-460 to IR-479 (the host work), IR-500 to IR-513 (the Linux test guest step), and IR-514 to IR-519 (the step 3 replay), the entries added for this task. The renderer-failure rule (IR-460) and the readback on the device queue (IR-464) are the two that change what a guest can observe.
- **Record:** the SurfaceFlinger result and the `kmscube` result in the #022 row and the `kmscube` row of [../../02-design/graphics.md](../../02-design/graphics.md) §16.
- **Pitfall:** `guestReadbacks` counts the `TRANSFER_FROM_HOST_3D` requests of the guest, which are the only readbacks of the normal path. `hostReadbacks` has no increment in any code path yet, so the replay test checks that it stays 0. The replay test uses the test-only readback mode, which exists only in builds with the `APKRUN_TEST_READBACK` flag and never touches either counter.
- The ≥ 55 fps condition of the Linux integration step needs a window. It is measured in #023.
- There is no automatic fallback from `drmVirgl` to `guestSwiftshader`. Graphics Safe Mode is the only switch (§9).

---

## #023 Render SurfaceFlinger to Metal

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #020, #022 |
| Gate | G3 |
| Requirements | FR-GFX-04, FR-GFX-05, NFR-PERF-04, NFR-PERF-05 ([../traceability.md](../traceability.md) §2.3, §2.12) |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §1.1, §6.1–§6.3, §7, §8, §12 (#023), §13, §16; [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5.3; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §3.8, §15; [../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md) |
| Modules / paths | GraphicsCore `ScanoutController`, `SurfacePool`, the present path, the completion waiter, and the statistics; WindowingCore `IOSurfaceLayerView`, `FrameSource`; RuntimeHost `EmbeddedRuntimeService` (`DeveloperService`); `CLI/apkrun/Dev/SurfacePoolFrameSource.swift`; `Tests/IntegrationTests/AndroidGraphicsTests/`; `Tests/AcceptanceTests/G3GraphicsTests/`; `Tests/IntegrationTests/G3GraphicsTests/G3Evidence.swift` and `G3EvidenceTests.swift`; `Tests/AcceptanceTests/AcceptanceTests.xctestplan`; `Tests/IntegrationTests/IntegrationTests.xctestplan`; `project.yml`; `scripts/run-gate.sh`; `scripts/tools/check-g3-evidence.py`; `scripts/tests/test_check_g3_evidence.py` |
| Risks / questions | R-02, R-03 |

### Goal

Android's display 0 is visible in a macOS window. Rendering is GPU accelerated. Normal frame presentation does not use CPU framebuffer copies. The window has a documented fixed size.

### Scope

- `ScanoutController` (§6.1): `configure`, `disable`, `attach`, `detachPool`, `events`, and `statistics`. Scanout 0 is configured at creation with the image's default mode.
- `SurfacePool` (§6.3): three IOSurface-backed buffers in BGRA8Unorm sRGB, and the buffer states `free`, `rendering`, `offered(seq)`, and `displayed(seq)` ([../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5.2).
- The present path (§6.2): `acquireForRender`, latest frame wins, a scaling blit when sizes differ, and the flush response after the blit completes.
- The completion waiter, with a 100 ms stall timeout.
- The statistics of §7, the `gpu.flush` and `gpu.present` signposts, and the `FIRST_FRAME` marker.
- A minimal WindowingCore `IOSurfaceLayerView` that shows the buffer as `CALayer` contents, and the `FrameSource` protocol.
- The embedded-only `DeveloperService`, which exposes display 0's `SurfaceSet` and frame events to the CLI ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §3.8, §15).
- `SurfacePoolFrameSource` in the CLI.
- `apkrun dev boot --gpu virgl --window --stats`.
- `apkrun dev linux --tests virgl --window` (the renderer integration steps 2–3).
- Instrumentation of every copy and readback.
- The G3 gate check.
- Out of scope:
  - Runtime resize (#067). The window is fixed-size.
  - Input (#024, #025) and the session window (#026).
  - Pools shared with the wrapper over XPC (#068).

### Deliverables

- The GraphicsCore scanout, present, waiter, and statistics files.
- `IOSurfaceLayerView` and `FrameSource` in WindowingCore.
- `DeveloperService` in `EmbeddedRuntimeService`, available only with `APKRUN_EMBEDDED_RUNTIME`.
- `CLI/apkrun/Dev/SurfacePoolFrameSource.swift`. It adapts the `DeveloperService` frame events to `FrameSource`. It lives in the embedded CLI because neither WindowingCore nor the CLI may import GraphicsCore ([../../01-architecture/modules.md](../../01-architecture/modules.md) §3).
- The `--window` and `--stats` options of `apkrun dev boot` and `apkrun dev linux`.
- Pool-buffer sampling in the test-only readback mode of #022 (`APKRUN_TEST_READBACK`), for the tearing check.
- The G3 gate check in `Tests/AcceptanceTests/G3GraphicsTests/`, with evidence
  collection by `scripts/run-gate.sh` and validation by
  `scripts/tools/check-g3-evidence.py`. Its pure evidence parser remains shared
  with the IntegrationTests unit tests. The validator's fixture tests live in
  `scripts/tests/test_check_g3_evidence.py`.
- The fixed-size behavior written into §12 (#023) and [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5.3.

### Implementation steps

1. **SurfacePool and present.**
   - Build `ScanoutController`, `SurfacePool`, the present path, the completion waiter, and the statistics.
   - A scanout with no pool completes flushes without a blit (§6.1).
   - The pool uses 3 × w × h × 4 bytes (§6.3).
   - Check: T0 covers the frame scheduler's drop policy, the `SurfacePool` state machine, and a generation change.
2. **Development window.**
   - `IOSurfaceLayerView` sets the ready buffer as the layer's contents. It never draws with the CPU.
   - `SurfacePoolFrameSource` in the CLI adapts `DeveloperService` frame events to `FrameSource`.
   - `apkrun dev boot --gpu virgl --window` opens a plain development `NSWindow` for display 0.
   - Check: Android's home screen is visible in the window.
3. **Fixed size.**
   - Display 0 keeps the image's default mode. The window scales the layer with aspect fit when it is resized.
   - Document this in §12 (#023) and [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5.3.
   - Check: resizing the window never reconfigures the scanout.
4. **Linux VirGL window.**
   - `apkrun dev linux --tests virgl --window` shows `kmscube` in the same window type.
   - Check: `kmscube` animates at ≥ 55 fps with `hostReadbacks = 0`.
5. **Instrumentation.**
   - Count `hostReadbacks`, `guestReadbacks`, and `cpuPixelCopies` at every copy and readback site. `--stats` shows fps and the counters in an overlay.
   - Log the counters every 60 s under `io.apkrun.graphics`, category `stats` (§13.2).
   - Check: the counters are 0 on `drmVirgl` and above 0 on `guestSwiftshader`.
6. **HelloGL and the gate.**
   - Start HelloGL with `AdbClient.startActivity`, with extras for the run length and the alternating-color mode.
   - The tearing check samples pool buffers in the test-only readback mode.
   - Check: `scripts/run-gate.sh G3` passes on the reference Mac.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.3.

- **T0** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`): the frame scheduler and the `SurfacePool` state machine. The G3 evidence-checker's fixture tests are in `scripts/tests/test_check_g3_evidence.py`.
- **T2** (`AndroidGraphicsTests`): HelloGL in a window. The counters stay 0 over 60 s.
- **T3:** `scripts/run-gate.sh G3` runs the G3 check in
  `Tests/AcceptanceTests/G3GraphicsTests/` ([../test-strategy.md](../test-strategy.md)
  §2.5, §5), and the v0.1 manual check C01-6 reviews a screen recording of G3
  for visible tearing or stutter.

### Acceptance criteria

- [x] The Android display is visible in a macOS window (IR-1113; the screenshot shows the Android lock screen in the window).
- [x] Rendering is GPU accelerated: the `drmVirgl` profile, and HelloGL's `renderer` event contains `virgl` (IR-1202).
- [x] Normal frame presentation does not rely on CPU framebuffer copies: `hostReadbacks = 0` and `cpuPixelCopies = 0` over a 60 s HelloGL run (FR-GFX-05, NFR-PERF-05) (IR-1203).
- [x] The resize or fixed-size behavior is explicitly documented: the window is fixed-size with aspect fit (graphics.md §12 #023 step 3, display-and-windowing.md §5.3, IR-1104).
- [x] Copies and readbacks are instrumented, and the counters are in the statistics. The window title shows `hostReadbacks` and `cpuPixelCopies` (screenshots `boot2-window-final.png`, IR-1108).
- [x] HelloGL averages ≥ 55 fps (NFR-PERF-04) (IR-1204).
- [x] HelloGL's alternating-color test shows no tearing, by the pool-buffer sampling of the test-only readback mode (graphics.md §12 #023 step 5): 320 frames in the alternating phase, 225 red, 38 blue, 0 mixed (IR-1210, IR-1222, IR-1225). The window captures of IR-1205 are not this check.
- [x] The renderer runs 10 minutes without a crash (IR-1206).
- [x] Gate G3 passes, with the evidence of [../test-strategy.md](../test-strategy.md) §5 committed in [../evidence/G3/](../evidence/G3/) (IR-1225, IR-1344). The rerun on 2026-10-16 passed from `7241003`; five privacy-safe, five-second APKRun-window samples from the source recording are committed as [apkrun-window-samples.mp4](../evidence/G3/apkrun-window-samples.mp4), with source recording metadata and sample provenance in [recording.txt](../evidence/G3/recording.txt). The full-screen source remains local because intervals without the APKRun window include unrelated desktop content. The bounded C01-6 review is recorded in IR-1344.

### Notes

- **Record:** the G3 result in the #023 row of [../../02-design/graphics.md](../../02-design/graphics.md) §16, the one-display measurement in R-03, and the R-02 status in [../risks.md](../risks.md). Also record whether ANGLE's single command queue per display gives tear-free ordering (§15).
- **Pitfall:** the present path depends on ANGLE's Metal backend using one command queue per display (§6.2). If the tearing check fails, look at that first.
- The renderer presents through a `CAMetalLayer`. APKRun uses an IOSurface pool shown as `CALayer` contents (ADR-0006), because apkrund renders and the wrapper displays. Rendering still uses Metal through ANGLE.
- The buffer state names are those of [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5.2 (`offered`, `displayed`), which §6.3 uses too. Before #068 the consumer is the development window, which reports `frameDisplayed` through `DeveloperService`.
- Before #031 and #032, the window runs in the CLI process ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §10).
- **Status, 2026-10-12 (IR-1100 to IR-1109).** Built: the IOSurface pool, the GPU blit, the completion poll, the counters, the window, and `apkrun dev boot --window --stats`. T0 and T1 pass (IR-1100, IR-1101). The first boot stalled because the loop ran in a main-actor job (IR-1103). The second boot reached the window, but SurfaceFlinger aborted in the guest before any flush, so no criterion 1 to 3 is ticked. The stop signal does not end a boot that is still starting (IR-1105). A third boot without `--window` reproduced the same `no suitable EGLConfig found (format: 1)` abort, so the window is not its trigger. The reference bundle boots this build without the abort (IR-1112), so the cause is the other bundle (IR-1111). The windowed boot on the reference bundle shows the Android display in the window, and criterion 1 is ticked (IR-1113).
- **Status, 2026-10-12 (IR-1200 to IR-1208).** HelloGL on the odm4 bundle, one `drmVirgl` boot with `--window`: the renderer event is `virgl`, the 60 s and 10-minute runs show every counter at 0, HelloGL averages 59.96 fps over 10 minutes, and HelloGL's process ran the 10 minutes without a fault. Criteria 2, 3, the fps half of 6, and the 10-minute criterion are ticked. The tearing half of 6 stays open: 40 alternating-colour window captures show no mixed frame, but the pool-buffer check was not run (IR-1205). Gate G3 stays open. The launcher and Settings processes abort in HWUI on this bundle (IR-1208); that is not the renderer.
- **Status, 2026-10-12 (IR-1225): Gate G3 passed.** `scripts/run-gate.sh G3` on main at `7dfa317` (report and evidence in [../evidence/G3/](../evidence/G3/)): the window is found, the renderer event is `virgl`, `hostReadbacks` and `cpuPixelCopies` stay at 0 over the 60 s run, HelloGL averages 59.98 fps over 61 events in the 10-minute run, the pid stays 7171 at every minute, there are no renderer crash lines, and the alternating phase has 0 mixed frames in 320 sampled. The 432 launcher and Settings crash lines are recorded and not counted (IR-1213). The stock image is the odm4 overlay bundle (IR-1209). Still open: the C01-6 manual check of the screen recording (test-strategy §8).
- **C01-6 pre-screen (2026-10-16, IR-1341; superseded by IR-1344).** The earlier local recording was only 1293.15 seconds and its sampled frame did not show the APKRun display window. This finding remains as the reason for rerunning the gate, not as the status of the new recording.
- **G3 test target alignment (2026-10-16, IR-1211, IR-1342).** The G3 gate test is in `Tests/AcceptanceTests/G3GraphicsTests/` and runs with the `G3` AcceptanceTests configuration. The lower-tier Linux guest precheck remains in IntegrationTests. The pure evidence parser and its unit tests remain in `Tests/IntegrationTests/G3GraphicsTests/`. The aligned gate passed in the subsequent full run recorded below.
- **Status (2026-10-16, G3 rerun and C01-6 review; IR-1344).** `scripts/run-gate.sh G3` passed from clean `main` at `7241003` on an Apple M5 Pro, arm64, macOS 27.0.1 / Xcode 27.0. The `G3` AcceptanceTests configuration ran one test and passed; the evidence checker exited 0. The guest reported Mesa/VirGL GLES, `sys.boot_completed=1`, and HelloGL's renderer event was `virgl`. Over 685 statistics lines, `hostReadbacks` and `cpuPixelCopies` remained 0. HelloGL averaged 59.99 fps across 61 events in the ten-minute run, the same PID was observed at start and each minute, the alternating phase sampled 408 frames with 0 mixed frames, and no renderer crash lines were found. The full-screen source recording is 480×312 and 1797.512 seconds; it remains local at `build/gates/G3/screen-recording.mp4` because intervals without the APKRun window include unrelated desktop content. Five 138×118 window-only samples from 2, 5, 7, 10, and 11 minutes are committed as [../evidence/G3/apkrun-window-samples.mp4](../evidence/G3/apkrun-window-samples.mp4); metadata and provenance are in [../evidence/G3/recording.txt](../evidence/G3/recording.txt). The samples total 25.069 seconds and show the APKRun window. Five five-second active-window samples had median frame intervals of 60 fps and no gap over 50 ms; a 30 fps sample showed the full-window color changing without a visible tear or stutter. C01-6 is checked on this bounded sampled review. The low recording resolution limits this check to visible full-window presentation defects. The result bundle and text evidence are retained in `build/gates/G3/` and [../evidence/G3/](../evidence/G3/).
