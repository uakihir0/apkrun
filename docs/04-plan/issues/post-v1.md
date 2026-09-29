# Post-v1 tracks

| Field | Value |
|---|---|
| Status | Baseline |
| Version | — |
| Related | [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../../AGENTS.md](../../../AGENTS.md) |

## Milestone goal

After v1.0, two optional tracks decide how APKRun grows beyond the v1 scope ([../roadmap.md](../roadmap.md) §5). #096 decides whether Android apps can get Vulkan through Venus or gfxstream on Metal. The roadmap calls this "Phase 21". #097 decides whether APKRun can live next to a Google Play that the user brings, without competing with it for update ownership. The roadmap calls this "Phase 22".

Both tracks work investigation first: spikes, then an ADR, then an implementation only if the ADR decides to implement. Neither track may change the v1 behavior of the GLES path or the update authorities `apkrun`, `manual`, and `external`. Neither may delay a v1.x release. Both follow the scope rules of [../../00-product/scope.md](../../00-product/scope.md):
- Vulkan is not a v1 blocker ([../../00-product/scope.md](../../00-product/scope.md) §1).
- Play Integrity circumvention is never implemented, and GMS is never bundled ([../../00-product/scope.md](../../00-product/scope.md) §3).
- A task touches one risk area only ([../../00-product/scope.md](../../00-product/scope.md) §5).

## Exit criteria

This file has no version. Each track is done on its own when its task meets its acceptance criteria.

- [ ] Every spike of the track has its results recorded in the design document that its Notes section names.
- [ ] The track's ADR is merged in [../../01-architecture/decisions/](../../01-architecture/decisions/) with status Accepted. Its Decision is either an implementation path or "not now", with the reasons and the measured evidence.
- [ ] If the ADR decides to implement, the implementation meets the task's acceptance criteria, and its test plan is part of [../test-strategy.md](../test-strategy.md) §6.14.
- [ ] #096: the GLES suites and G3 keep passing unchanged ([../test-strategy.md](../test-strategy.md) §6.14).
- [ ] #097: the update ownership tests of #039 and G9 keep passing ([../test-strategy.md](../test-strategy.md) §6.14).
- [ ] The design documents, [../risks.md](../risks.md), [../../00-product/scope.md](../../00-product/scope.md) §4 (if the compatibility levels change), and the compatibility database (#090) describe the result.

## Task order

1. #096 Vulkan track. **Parallel.**
2. #097 Google Play authority. **Parallel.**

Both tracks start after v1.0 is tagged (#094, [../roadmap.md](../roadmap.md) §5). Their dependencies (#023 and #035 for #096; #039 and #049 for #097) are done by then. The two tracks are independent and may run in parallel. Each track is isolated from the other and from the core architecture.

---

## #096 Vulkan track

| Field | Value |
|---|---|
| Milestone | Post-v1 (—) |
| Depends on | #023, #035 |
| Requirements | None of its own. FR-GFX-01 to FR-GFX-05 and NFR-PERF-04 must keep passing on the GLES path |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §4.1, §4.5, §5.4, §9, §10, §11; [../../01-architecture/decisions/0004-virgl-first-graphics.md](../../01-architecture/decisions/0004-virgl-first-graphics.md); [../../02-design/android-image.md](../../02-design/android-image.md) §6.2, §9, §11; [../../05-development/build-system.md](../../05-development/build-system.md) §6, §15.2; [../../00-product/scope.md](../../00-product/scope.md) §1, §3, §4; [../roadmap.md](../roadmap.md) §5; [../test-strategy.md](../test-strategy.md) §6.14 |
| Modules / paths | `Experiments/vulkan/` (spikes); `docs/01-architecture/decisions/` (new ADR). Only if the ADR decides to implement: VirtioDeviceCore (shared memory region); GraphicsCore (features, blob resources, context types, fence timelines, `ResourceTable`); `GraphicsBridge` and `VirGLRuntime` (the host Vulkan backend); `ThirdParty/` (pinned MoltenVK or gfxstream); ImageCore (`BootOptions.gpuProfile`); `Guest/product/` (Venus-capable Mesa, bootconfig); `Tests/Fixtures/AndroidApps/` (a Vulkan fixture); `Tests/IntegrationTests/GraphicsTests/` |
| Risks / questions | R-01, R-02, R-03, R-07, R-08. Open items: none in [../../02-design/graphics.md](../../02-design/graphics.md). The research notes are in §10 |

### Goal

An ADR decides, with measured spike results, whether APKRun offers Vulkan to Android apps, and by which path: Venus on virglrenderer with MoltenVK, or gfxstream. If the ADR decides to implement, Android on the Vulkan profile reports a Vulkan device and a Vulkan fixture renders in a Mac window. The GLES path and G3 stay unchanged.

### Scope

- Three spikes, each on the facts of [../../02-design/graphics.md](../../02-design/graphics.md) §10:
  - the shared memory region on Virtualization.framework;
  - the host renderer: the venus backend of virglrenderer on MoltenVK, compared with gfxstream;
  - the guest side: a Venus-capable Mesa in a test variant of the custom image, with the matching bootconfig.
- One ADR with the decision and the evidence.
- Only if the ADR decides to implement:
  - `VIRTIO_GPU_F_RESOURCE_BLOB` and `VIRTIO_GPU_F_CONTEXT_INIT` with a host-visible shared memory region;
  - blob resources with limits;
  - per-context fence timelines (`ring_idx`);
  - the host Vulkan backend;
  - the guest image changes;
  - a separate GPU profile in §9, so that the `drmVirgl` profile keeps its v1 features (§4.1).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Replacing or changing the GLES path. VirGL with ANGLE stays the default ([../../01-architecture/decisions/0004-virgl-first-graphics.md](../../01-architecture/decisions/0004-virgl-first-graphics.md)).
  - Vulkan on the stock image. The guest side needs the custom image (§10).
  - Automatic fallback between profiles. There is none (§9).
  - Moving the renderer into a separate process (§11), and VM save/restore (R-07).
  - Any change to other areas in the same task, such as wrappers, the updater, or Google Play ([../../00-product/scope.md](../../00-product/scope.md) §5).
  - Delaying a v1.x release ([../roadmap.md](../roadmap.md) §5).

### Deliverables

- The spike code in `Experiments/vulkan/shared-memory/`, `Experiments/vulkan/host-renderer/`, and `Experiments/vulkan/guest/`. Production targets never import it ([../../01-architecture/modules.md](../../01-architecture/modules.md) §1).
- The spike results in [../../02-design/graphics.md](../../02-design/graphics.md) §10.
- The ADR, with the next free number in [../../01-architecture/decisions/](../../01-architecture/decisions/) (0018 or higher), linked from [../../02-design/graphics.md](../../02-design/graphics.md) §10 and from ADR-0004.
- Only if the ADR decides to implement:
  - the device, renderer, and image changes;
  - the new GPU profile;
  - a Vulkan fixture app;
  - the fuzz targets;
  - the test plan in [../test-strategy.md](../test-strategy.md) §6.14.

### Implementation steps

1. **Shared memory spike** ([../../02-design/graphics.md](../../02-design/graphics.md) §10).
   - In `Experiments/vulkan/shared-memory/`, add a `VZVirtioSharedMemoryRegionConfiguration` with region ID 1 to the custom virtio-gpu device. Read `maximumAllowedSharedMemoryRegionCount`. At least 1 is required.
   - Map three kinds of page-aligned memory with `VZVirtioSharedMemoryRegion.mapMemory(_:atOffset:size:)`: an anonymous buffer, an IOSurface-backed buffer, and a Metal-heap-backed buffer. Completion arrives on the device queue.
   - A guest test module writes and reads the region.
   - Check: the count, the backing types that map, and the time per map are recorded in §10. If the count is 0, or no GPU-usable memory maps, go to step 4. The ADR then records that the track is not feasible on this macOS release, and steps 2, 3, and 5–7 are skipped.
2. **Host renderer spike** (§10; [../../01-architecture/decisions/0004-virgl-first-graphics.md](../../01-architecture/decisions/0004-virgl-first-graphics.md) Alternatives considered).
   - In `Experiments/vulkan/host-renderer/`, build the venus backend of virglrenderer against MoltenVK, from pinned revisions as in [../../05-development/build-system.md](../../05-development/build-system.md) §6.
   - Assess what porting gfxstream's host renderer to this device model needs.
   - For each option, record:
     - whether it builds reproducibly;
     - its license;
     - its size;
     - the Vulkan version and extensions it exposes;
     - whether it runs a sample Vulkan workload with blob memory from step 1.
   - Check: a comparison table for Venus on MoltenVK and for gfxstream is recorded in §10.
3. **Guest spike** (§10; [../../02-design/android-image.md](../../02-design/android-image.md) §6.2, §11).
   - Build a Venus-capable Mesa into a test variant of the custom image. Select it with the bootconfig keys of [../../02-design/android-image.md](../../02-design/android-image.md) §6.2, including the `vulkan` APEX selection. The test variant is never a release image.
   - Boot it against the spike host of step 2.
   - Check: in the guest, `cmd gpu vkjson` lists the Venus physical device. SurfaceFlinger still composes through GLES. The record of which bootconfig keys changed is in §10.
4. **ADR** ([../../01-architecture/decisions/README.md](../../01-architecture/decisions/README.md)).
   - Write the ADR with the next free number. It has the template sections Context, Decision, Alternatives considered, Consequences, and Verification. The Context has the spike numbers.
   - The Decision picks Venus on MoltenVK, gfxstream, or "not now". The Consequences cover:
     - the new dependencies;
     - the image changes;
     - the added attack surface (§11);
     - memory (R-08);
     - R-07;
     - the effect on the compatibility levels ([../../00-product/scope.md](../../00-product/scope.md) §4).
   - Check: the ADR is merged with status Accepted. If its Decision is "not now", the task ends here, and steps 5–7 are filed as a new task for when the ADR is superseded.
5. **Device and renderer** (§4.1, §4.5, §5.4, §10).
   - Add a GPU profile for Vulkan to the table of §9. Only this profile offers `VIRTIO_GPU_F_RESOURCE_BLOB` and `VIRTIO_GPU_F_CONTEXT_INIT` and attaches the shared memory region. The `drmVirgl` features stay as in §4.1.
   - GraphicsCore adds:
     - blob resources in `ResourceTable`, with size limits in §5.4;
     - `CONTEXT_INIT` context types;
     - per-context fence timelines by `ring_idx`, which remove the in-order fence limitation of §4.5.
   - The chosen backend goes into `GraphicsBridge` with pinned dependencies in `ThirdParty/`.
   - Check: T0 tests of the blob and fence-timeline state machines and of the new limits pass. G3 passes unchanged on `drmVirgl`.
6. **Guest image and profile selection** ([../../02-design/android-image.md](../../02-design/android-image.md) §6.2, §9, §11).
   - Add the Venus-capable Mesa to `Guest/product/`, and the bootconfig keys of the new profile to `AndroidBootPlanner`. `BootOptions.gpuProfile` selects the profile per boot.
   - Until the ADR's verification passes, the profile is selectable only through `apkrun dev boot --gpu <profile>`. The ADR decides whether users can select it later, and how.
   - Check: the custom image boots with each profile. On `drmVirgl`, `ro.cpuvulkan.version` and the GLES renderer string are unchanged.
7. **Tests, security, and acceptance** ([../test-strategy.md](../test-strategy.md) §6.14; [../../02-design/graphics.md](../../02-design/graphics.md) §11).
   - Write the test plan in [../test-strategy.md](../test-strategy.md) §6.14. Add a Vulkan fixture app to `Tests/Fixtures/AndroidApps/`, signed like the other fixtures.
   - Add fuzz targets for the blob and context commands to the #091 fuzzing infrastructure ([../../05-development/build-system.md](../../05-development/build-system.md) §15.2).
   - Measure the fixture's frame rate with the perf harness (#070).
   - Update the compatibility levels in [../../00-product/scope.md](../../00-product/scope.md) §4 and the compatibility database (#090) for Vulkan apps.
   - Check: the acceptance criteria below.

### Tests

- **T0** (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`, `Packages/ImageCore/Tests/ImageCoreTests/`), only if implemented:
  - the blob resource and fence-timeline state machines;
  - the new limits;
  - the profile → feature and bootconfig mapping.
  - The spikes in `Experiments/` have no CI tests.
- **T1** (`Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`, `fuzz-short`), only if implemented: fuzz targets for the blob and context commands, with reproducer replay.
- **T2** (`Tests/IntegrationTests/GraphicsTests/`, AndroidCustom suite):
  - only if implemented, the Vulkan fixture renders in a window on the Vulkan profile with no host readback;
  - always, the GLES suites on `drmVirgl` pass unchanged.
- **T3**:
  - G3 on the reference Mac, unchanged;
  - `fuzz-long` for the new targets;
  - only if implemented, the fixture's frame rate with the perf harness.

### Acceptance criteria

- [ ] The three spikes have their results recorded in [../../02-design/graphics.md](../../02-design/graphics.md) §10. This includes the shared memory region count, the backing types that map, the host renderer comparison, and the guest Vulkan device.
- [ ] An ADR with status Accepted decides the Vulkan path or "not now", with the spike numbers.
- [ ] If the ADR decides to implement:
  - [ ] Android on the Vulkan profile lists a Vulkan device.
  - [ ] The Vulkan fixture renders in a Mac window with no CPU readback.
  - [ ] Guest-controlled blob and context commands are bounded by limits and have fuzz targets.
- [ ] The `drmVirgl` profile offers the same features as in v1. The GLES suites and G3 pass unchanged.
- [ ] No v1.x release waited for this track.

### Notes

- Record the spike results in [../../02-design/graphics.md](../../02-design/graphics.md) §10, and update R-01, R-03, and R-08 in [../risks.md](../risks.md) with what the spikes found.
- Spike 1 decides the track. Do not start spike 2 in depth before the shared memory result is known.
- Pitfall: a feature bit offered to the guest changes what Mesa virgl negotiates. Offer the new bits only on the new profile.

---

## #097 Google Play authority

| Field | Value |
|---|---|
| Milestone | Post-v1 (—) |
| Depends on | #039, #049 |
| Requirements | FR-UPD-01, FR-UPD-02, FR-UPD-06, NFR-SEC-04 |
| Design | [../../02-design/update-system.md](../../02-design/update-system.md) §2.1, §2.3; [../../02-design/package-store.md](../../02-design/package-store.md) §2.3, §6.3, §9.3; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §11.1 (op 109), §11.4; [../../02-design/guest-components.md](../../02-design/guest-components.md) §8; [../../01-architecture/decisions/0010-update-authority-provider-split.md](../../01-architecture/decisions/0010-update-authority-provider-split.md); [../../01-architecture/decisions/0001-real-android-in-vm.md](../../01-architecture/decisions/0001-real-android-in-vm.md); [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md); [../../00-product/scope.md](../../00-product/scope.md) §3, §5; [../roadmap.md](../roadmap.md) §5; [../test-strategy.md](../test-strategy.md) §6.14 |
| Modules / paths | `Experiments/google-play/` (spikes); `docs/01-architecture/decisions/` (new ADR). Only if the ADR decides to implement: APKStoreCore (reconciliation, adoption with `googlePlay`); UpdateCore (authority rules); RuntimeAPI; `Apps/APKRun/Features/Home/`, `Apps/APKRun/Features/AppPage/`; `CLI/apkrun/Commands/`; `Tests/Fixtures/AndroidApps/` (a stand-in installer); `Tests/IntegrationTests/StoreTests/`, `Tests/IntegrationTests/UpdateTests/` |
| Risks / questions | R-09, R-10, R-18. OQ-12 (update ownership of owner-less packages, settled by #039). Open items: [../../02-design/package-store.md](../../02-design/package-store.md) §17 |

### Goal

An ADR decides, with legal and technical evidence, whether APKRun supports packages that a user-provided Google Play installs and updates. APKRun never distributes GMS and never circumvents Play Integrity. If the ADR decides to implement, such packages have the update authority `googlePlay`. APKRun then never checks providers for them, never installs updates for them, and never claims their update ownership, and the UI shows "Managed by Google Play".

### Scope

- A legal investigation. It asks how Google Play could be present in the VM when APKRun never bundles or downloads GMS ([../../01-architecture/decisions/0001-real-android-in-vm.md](../../01-architecture/decisions/0001-real-android-in-vm.md), R-09, R-10).
- A technical spike on the APKRun side:
  - how the Store Agent sees packages that Google Play installs (`installer_of_record` and `update_owner` in `StorePackageInfo`, [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §11.4);
  - whether update ownership keeps Play away from APKRun-owned packages (FR-UPD-06);
  - what `RelinquishUpdateOwnership` (op 109) does on a change to `googlePlay`.
- One ADR with the decision. It states how the track stays isolated from the core architecture.
- Only if the ADR decides to implement:
  - detection of Play-managed packages;
  - adoption with `updateAuthority: googlePlay` in the record shape of [../../02-design/package-store.md](../../02-design/package-store.md) §9.3;
  - the authority change with op 109;
  - the read-only UI state of [../../02-design/update-system.md](../../02-design/update-system.md) §2.3.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Bundling, downloading, or installing GMS or Google Play.
  - Play Integrity circumvention, certification spoofing, or signature bypass of any kind. These are never implemented ([../../00-product/scope.md](../../00-product/scope.md) §3, NFR-SEC-04).
  - A `googlePlay` update provider, or fetching APKs from Google Play. APKRun checks no providers for this authority ([../../02-design/update-system.md](../../02-design/update-system.md) §2.1).
  - Bridging Google sign-in or FCM push to the Mac.
  - Any change to the behavior of `apkrun`, `manual`, or `external` packages, or of images without Google Play.
  - Any change to other areas in the same task, such as graphics, wrappers, or the image pipeline ([../../00-product/scope.md](../../00-product/scope.md) §5).

### Deliverables

- The legal findings, and the technical spike code in `Experiments/google-play/`. Production targets never import it.
- The ADR, with the next free number in [../../01-architecture/decisions/](../../01-architecture/decisions/) (0018 or higher, after the #096 ADR if that one merges first), linked from [../../02-design/update-system.md](../../02-design/update-system.md) §2.1.
- The spike results in [../../02-design/update-system.md](../../02-design/update-system.md) §2.1 and [../../02-design/package-store.md](../../02-design/package-store.md) §6.3.
- Only if the ADR decides to implement:
  - the detection and adoption code;
  - the authority rules;
  - the UI and CLI changes;
  - a stand-in installer fixture;
  - the test plan in [../test-strategy.md](../test-strategy.md) §6.14.

### Implementation steps

1. **Legal investigation** ([../../01-architecture/decisions/0001-real-android-in-vm.md](../../01-architecture/decisions/0001-real-android-in-vm.md); [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md)).
   - Determine what the GMS and Google Play licensing allows for a product like APKRun. List the ways a user could lawfully have Google Play in the VM without APKRun distributing it. Include the option of not supporting it.
   - A maintainer who owns the #093 legal checklist reviews the findings.
   - Check: the findings are in the ADR draft, each with its source. If no lawful way exists, go to step 3 with the Decision "not now".
2. **Technical spike** ([../../02-design/update-system.md](../../02-design/update-system.md) §2.1; [../../02-design/package-store.md](../../02-design/package-store.md) §6.3, §9.3; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §11.4).
   - In `Experiments/google-play/`, use a stand-in installer app on the custom image. It has the package name `com.android.vending`, installs a fixture package, and claims its update ownership, as Google Play would. The image has no Google Play, so the name is free. If step 1 found a lawful test environment with Google Play, repeat the checks there.
   - Record four things:
     - `installer_of_record` and `update_owner` for a package that the stand-in installed;
     - whether the stand-in can update a package that `io.apkrun.store` owns;
     - what op 109 does when an APKRun-owned package changes to `googlePlay`;
     - whether the stand-in can then take over updates.
   - Check: the results are recorded in [../../02-design/update-system.md](../../02-design/update-system.md) §2.1 and [../../02-design/package-store.md](../../02-design/package-store.md) §6.3.
3. **ADR** ([../../01-architecture/decisions/README.md](../../01-architecture/decisions/README.md)).
   - Write the ADR with the next free number. Its Context holds the findings of steps 1–2. Its Decision is "support Play-managed packages" or "not now". Its Consequences name the isolation rules:
     - only the authority value and the detection change;
     - no GMS code or data in APKRun;
     - no new provider.
   - Relate it to ADR-0001 and ADR-0010.
   - Check: the ADR is merged with status Accepted. If its Decision is "not now", the task ends here.
4. **Detection and adoption** ([../../02-design/package-store.md](../../02-design/package-store.md) §9.1–§9.3).
   - Reconciliation marks an unmanaged package as managed by Google Play when its `installer_of_record` or `update_owner` is `com.android.vending`. Home → Other Android apps shows "Managed by Google Play" for it.
   - Adopting such a package creates the adoption record of [../../02-design/package-store.md](../../02-design/package-store.md) §9.3 with `updateAuthority: googlePlay` instead of `external`. Like `external`, the package has no artifact, cannot be restored after Reset Android, and the adopt sheet says so.
   - Check: T0 reconciliation and adoption tests with recorded `StorePackageInfo` values.
5. **Authority rules, UI, and CLI** ([../../02-design/update-system.md](../../02-design/update-system.md) §2.1, §2.3; [../../02-design/package-store.md](../../02-design/package-store.md) §6.3).
   - A change of an `apkrun` or `manual` package to `googlePlay` calls `RelinquishUpdateOwnership` (op 109). The package keeps its record.
   - UpdateCore never checks providers and never installs for `googlePlay` packages.
   - A user-supplied file for a `googlePlay` package asks to switch to `manual` first, as for `external`.
   - The app page shows the read-only "Managed by Google Play" state with no update choices. `apkrun info <package>` shows the authority.
   - Check: T0 tests of the rules and the UI mapping. T1 with a counting fake provider shows zero checks for a `googlePlay` package.
6. **Tests and acceptance** ([../test-strategy.md](../test-strategy.md) §6.14).
   - Write the test plan in [../test-strategy.md](../test-strategy.md) §6.14. Add the stand-in installer to `Tests/Fixtures/AndroidApps/` as a test-only fixture. Run the #039 ownership tests and G9.
   - Check: the acceptance criteria below.

### Tests

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Packages/UpdateCore/Tests/UpdateCoreTests/`, `Apps/APKRun/Tests/`, `CLI/apkrun/Tests/`), only if implemented:
  - the detection from `installer_of_record` and `update_owner`;
  - adoption with `googlePlay`;
  - the authority rules;
  - the UI mapping;
  - CLI golden files.
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`), only if implemented: a counting fake provider shows zero checks for `googlePlay` packages.
- **T2** (`Tests/IntegrationTests/StoreTests/`, `Tests/IntegrationTests/UpdateTests/`, AndroidCustom suite):
  - only if implemented:
    - a package that the stand-in installer installed is detected;
    - after adoption, APKRun installs nothing for it;
    - a change to `googlePlay` relinquishes ownership (op 109).
  - Always: the #039 ownership tests pass unchanged.
- **T3**:
  - G9 on the reference Mac, unchanged;
  - a manual check in the lawful Google Play environment, if step 1 found one.

### Acceptance criteria

- [ ] The legal findings and the spike results are recorded. The spike results cover `installer_of_record`, `update_owner`, ownership enforcement, and op 109.
- [ ] An ADR with status Accepted decides "support" or "not now", and is related to ADR-0001 and ADR-0010.
- [ ] If the ADR decides to implement:
  - [ ] A package that Google Play (or the stand-in) installed is shown as "Managed by Google Play". Adopting it gives `updateAuthority: googlePlay`.
  - [ ] APKRun never checks providers, installs updates, or claims update ownership for a `googlePlay` package. A change to `googlePlay` calls `RelinquishUpdateOwnership`.
  - [ ] The app page shows the read-only state with no update choices.
- [ ] APKRun contains no GMS component, and nothing bypasses Play Integrity or signature checks (NFR-SEC-04).
- [ ] The #039 ownership tests and G9 pass unchanged.

### Notes

- Record the legal result in R-09 and R-10 of [../risks.md](../risks.md). Record the ownership results in [../../02-design/update-system.md](../../02-design/update-system.md) §2.1 and [../../02-design/package-store.md](../../02-design/package-store.md) §6.3.
- Two automatic updaters never manage the same package ([../../02-design/update-system.md](../../02-design/update-system.md) §2.1). If the spike shows that Google Play can update an APKRun-owned package, record it as a finding against #039 before any implementation.
- Pitfall: the stand-in installer is test-only. It is never part of a release image.
