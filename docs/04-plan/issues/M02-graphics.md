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

- [ ] All 6 tasks below meet every acceptance criterion.
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
4. #022 Android VirGL. It needs #021 and #020.
5. #023 Render SurfaceFlinger to Metal. This task closes G3.

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
- **Refusal check:** `AndroidGraphicsRefusalTests` starts no VM. It checks that a `drmVirgl` boot ends with `gpuProfileUnavailable` and that no file under the home directory changes (IR-380).
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
4. Boot the corrected image in the test guest and run `apkrun.test=egl`.

### Tests

- T0: manifest validation of the corrected identity.
- T2: the guest EGL check on the corrected image, and the unchanged reference
  check on build `16373615`.

### Acceptance criteria

- [ ] The corrected image has its own build identity, manifest, and hashes, and
      build `16373615` is unchanged.
- [ ] In the guest, `eglInitialize` succeeds on the VirGL display (`apkrun.test=egl`).
- [ ] Every new artifact has recorded provenance, and every third-party component is pinned in the lock.
- [x] #064 is unaffected: its acceptance uses build `16373615`. Checked on 2026-10-10: `git diff main...HEAD` changes no path under `Images/reference/16373615/`, `Images/manifests/16373615/`, or the M01 #064 entry.

### Notes

- Placement and the reasons for it are in IR-240. This task sits between #021 and
  #022, because #022 needs a working Mesa guest.
- The task cannot start until #021 is done, and #021 depends on #014, which waits
  for the Android boot in #064 (IR-298 to IR-302). It is recorded now so that the
  dependency is visible.
- Filed on 2026-10-09 as GitHub issue #99. A new task takes its GitHub issue number, so
  the task number and the issue number are both #099 (IR-293 covers the earlier offset).
- **Status (2026-10-11, step 2 offline: the vendor partition).** `python3 -m apkrun_image inject-vendor` rebuilds `vendor_a` from the stock `super.img` of build 16373615 with the four Mesa libraries in `/vendor/lib64/egl/` (IR-622). The stock partition reproduces exactly before anything is added (522 entries, IR-627). The injected rebuild differs from the stock only by the four files and by the size of their directory. The labels come from the image's own contexts (IR-623), and the verity tree and footer are made again with the vendored avbtool (IR-624). The output is `vendor_a.img` (291,229,696 bytes, the size of its super extent, IR-626) and `inject.json`. Both are written under `/tmp/apkrun-099-inject-out-final`, outside the repository.
  - The output is **not booted and not signed.** The top-level `vbmeta` still holds the stock vendor root digest, so the partition does not verify until `vbmeta` is signed again. The key is not in this repository, so this step does not sign it (IR-625).
  - Criterion 1 stays open. It needs the corrected image as a whole (the super with this partition, its manifest, and its identity), which depends on IR-625 and IR-626. Criterion 2 needs the VM.
  - The Mesa output was rebuilt for this step with `scripts/guest/build-mesa-android.sh --out /tmp/apkrun-099-inject-mesa/out`, because the output of the earlier build was not on this machine (IR-620). Its four SHA-256 values equal ADR-0018's.
  - Pins: erofs-utils 1.9.4 (the bottle of the receipt, relocated, IR-621), and the vendored avbtool (`aosp-avbtool`). The tools are fetched with `python3 -m apkrun_image erofs-tools --out DIR`, and the tests that need them run when `APKRUN_EROFS_UTILS` names that directory.
  - Host checks that ran: `Images/tools` pytest (the whole suite, with `PYTHONPATH` set to this worktree, IR-631), the Swift lock checker on a copy of the lock inputs, `scripts/tests/test_third_party_build.py`, `test_third_party_notices.py`, and `test_guest_mesa_build.py` (with `--out` on the rebuilt output: 28 tests). Nothing started a VM.
  - **The VM check must verify,** in this order: (a) `ls -Z` on `/vendor/lib64/egl/*` gives `same_process_hal_file` (IR-623); (b) the EGL namespace finds `libgallium_dri.so` in `/vendor/lib64/egl`, which the guest's linker config shows (`/linkerconfig/ld.config.txt`), and if it does not, the fallback is the decision of IR-622; (c) the vendor partition verifies after the vbmeta decision of IR-625, and `init` mounts it; (d) `libEGL_mesa.so`, `libGLESv2_mesa.so`, and `libGLESv1_CM_mesa.so` load, and their DT_NEEDED entries resolve (`libz.so` is still an open check, IR-487); (e) the 37 imports of the symbol contract resolve against the guest's libraries (IR-488); (f) `eglInitialize` succeeds on the VirGL display, which is `apkrun.test=egl`; (g) the properties `ro.hardware.egl=mesa` and the bootconfig keys of graphics.md §9 are in the image in use.
- **Status (2026-10-10, host work only, no VM started).** The route is ADR-0018 (NDK, Mesa 26.1.8), accepted with the project owner's approval.
  - Step 1 (the comparison and the receipt, IR-440 to IR-451) is on `task/099-mesa-virgl-guest-image`. It is not on this branch, and ADR-0018 cites it.
  - Step 2 is partly done. The Mesa libraries from locked sources are built, and the lock pins them: `scripts/guest/build-mesa-android.sh` builds the four shipped libraries (`libEGL_mesa.so`, `libGLESv2_mesa.so`, `libGLESv1_CM_mesa.so`, `libgallium_dri.so`) from the pinned sources, and `ThirdParty/ThirdParty.lock.json` pins Mesa 26.1.8 and its build tools (group `guest-mesa`). The product fragment in `Guest/product/` is not done, so step 2 stays open.
  - Step 3, the corrected image with its own identity, is not done. No image is built. The build writes `manifest.json` next to the libraries, and it is the only provenance record so far.
  - Step 4, the boot and `apkrun.test=egl`, is not done. It needs the VM and the image.
  - Acceptance criterion 4 is checked (see above). Criteria 1 to 3 stay open. Criterion 1 needs the image, criterion 2 needs the VM, and criterion 3 needs the `flex` and `m4` pins (IR-485) and a maintainer decision on the app list (IR-483) and on the NDK licence (IR-486).
  - Host checks that ran: `scripts/tests/test_guest_mesa_build.py` (28 tests, 6 of them on the built output), the lock checker on a copy of the lock inputs (XcodeGen is not installed, see the commit message), the existing third-party tests, and `shellcheck`.
  - The output of the final build, with the NDK r28c, has the SHA-256 values `libEGL_mesa.so` `73cb1755…`, `libGLESv2_mesa.so` `7da942f6…`, `libGLESv1_CM_mesa.so` `2a082937…`, and `libgallium_dri.so` `a261e62b…`. Two builds with the same flags gave the same values. The output is outside the repository (IR-495).
  - Open for the VM and the image (IR-487 to IR-489): the symbol contract of 37 imports from the stub libraries and libdrm (`GUEST_SYMBOL_CONTRACT`), the `libz.so` entry, and the placement of the libraries in `vendor/lib64/egl/`.

---

## #022 Android VirGL

| Field | Value |
|---|---|
| Milestone | M2 (v0.1) |
| Depends on | #021, #020 |
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
- The recorded `kmscube` stream in `Tests/Fixtures/graphics/`. Until a Linux run records it, the replay uses the synthetic fixture `synthetic-virgl-session.json` (IR-514).
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
   - Record the command stream with the recorder, and commit it.
   - Check: T2 `virgl` passes with `hostReadbacks = 0`.
3. **Replay test.**
   - The T1 test replays the recorded stream and compares the hash of the scanout resource, within tolerance. It reads the resource in the test-only readback mode, which exists only in builds with `APKRUN_TEST_READBACK` and does not touch `hostReadbacks`.
   - Check: T1 passes on a Mac runner.
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

- **T0** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`): `ResourceTable` limits, overflow, backing validation, and reset clearing.
- **T1** (`Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`): the `kmscube` replay → a pool buffer hash within tolerance. It needs Metal. Until the `kmscube` capture exists, the replay runs on the synthetic fixture and compares the scanout resource exactly (IR-514, IR-516).
- **T2:**
  - `LinuxGuestTests`, check `virgl`: `kmscube` with the `virgl` renderer and `hostReadbacks = 0`.
  - `AndroidGraphicsTests`: VirGL SurfaceFlinger, and `boot_completed` with `drmVirgl` and with `guestSwiftshader`.

### Acceptance criteria

- [ ] The guest graphics stack initializes, and software rendering is not the normal path: `dumpsys SurfaceFlinger` names the virgl GLES renderer.
- [ ] Mesa, VirGL, gralloc, the HWC, and the DRM path are documented in §9 and reproducible from the committed bootconfig.
- [ ] SurfaceFlinger loads no SwiftShader or in-guest ANGLE library.
- [ ] Android reaches `sys.boot_completed=1` with `drmVirgl` and with `guestSwiftshader`.
- [x] `kmscube` runs on the Linux test guest through virgl with `hostReadbacks = 0`.
- [x] Guest-controlled sizes and IDs are checked against the limits of §5.4.

### Notes

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
| Modules / paths | GraphicsCore `ScanoutController`, `SurfacePool`, the present path, the completion waiter, and the statistics; WindowingCore `IOSurfaceLayerView`, `FrameSource`; RuntimeHost `EmbeddedRuntimeService` (`DeveloperService`); `CLI/apkrun/Dev/SurfacePoolFrameSource.swift`; `Tests/IntegrationTests/AndroidGraphicsTests/`; `Tests/AcceptanceTests/` |
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
- The G3 check in `Tests/AcceptanceTests/`, run by `scripts/run-gate.sh G3`.
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

- **T0** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`): the frame scheduler and the `SurfacePool` state machine.
- **T2** (`AndroidGraphicsTests`): HelloGL in a window. The counters stay 0 over 60 s.
- **T3:** the G3 check ([../test-strategy.md](../test-strategy.md) §5, `G3Graphics`), and the v0.1 manual check C01-6: a screen recording of G3 with no tearing or stutter.

### Acceptance criteria

- [ ] The Android display is visible in a macOS window.
- [ ] Rendering is GPU accelerated: the `drmVirgl` profile, and HelloGL's `renderer` event contains `virgl`.
- [ ] Normal frame presentation does not rely on CPU framebuffer copies: `hostReadbacks = 0` and `cpuPixelCopies = 0` over a 60 s HelloGL run (FR-GFX-05, NFR-PERF-05).
- [ ] The resize or fixed-size behavior is explicitly documented: the window is fixed-size with aspect fit.
- [ ] Copies and readbacks are instrumented, and the counters are in the statistics.
- [ ] HelloGL averages ≥ 55 fps (NFR-PERF-04), with no tearing in the alternating-color test.
- [ ] The renderer runs 10 minutes without a crash.
- [ ] Gate G3 passes, with the evidence of [../test-strategy.md](../test-strategy.md) §5 committed.

### Notes

- **Record:** the G3 result in the #023 row of [../../02-design/graphics.md](../../02-design/graphics.md) §16, the one-display measurement in R-03, and the R-02 status in [../risks.md](../risks.md). Also record whether ANGLE's single command queue per display gives tear-free ordering (§15).
- **Pitfall:** the present path depends on ANGLE's Metal backend using one command queue per display (§6.2). If the tearing check fails, look at that first.
- The renderer presents through a `CAMetalLayer`. APKRun uses an IOSurface pool shown as `CALayer` contents (ADR-0006), because apkrund renders and the wrapper displays. Rendering still uses Metal through ANGLE.
- The buffer state names are those of [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §5.2 (`offered`, `displayed`), which §6.3 uses too. Before #068 the consumer is the development window, which reports `frameDisplayed` through `DeveloperService`.
- Before #031 and #032, the window runs in the CLI process ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §10).
