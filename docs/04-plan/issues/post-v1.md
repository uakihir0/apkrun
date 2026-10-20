# Post-v1 tracks

After v1.0, two optional tracks decide how APKRun grows beyond the v1 scope ([roadmap.md](../roadmap.md) §5). #97 decides whether Android apps can get Vulkan, through Venus on virglrenderer with MoltenVK or through gfxstream. #98 decides whether APKRun can live next to a Google Play that the user brings, without competing with it for update ownership. Both tracks start with spikes, then an ADR, and implement only if the ADR decides to implement. Each track is done when its task meets its acceptance criteria. Neither track changes the GLES path or the update authorities `apkrun`, `manual`, and `external`, and neither delays a v1.x release. The tracks are independent of each other and of the core. Scope rules: Vulkan is not a v1 blocker, Play Integrity circumvention is never implemented, GMS is never bundled ([scope.md](../../00-product/scope.md) §1, §3), and a task touches one risk area only ([scope.md](../../00-product/scope.md) §5).

---

## #97 Vulkan track

| Field | Value |
|---|---|
| Milestone | Post-v1 |
| Depends on | #24, #36 |
| Design | [graphics.md](../../02-design/graphics.md) §4.1, §5.4, §9, §10, §11; [ADR-0004](../../01-architecture/decisions/0004-virgl-first-graphics.md); [android-image.md](../../02-design/android-image.md) §6.2, §9 |
| Code | `Experiments/vulkan/` (spikes), `docs/01-architecture/decisions/` (ADR). If implemented: `Packages/GraphicsCore/`, `Packages/VirtioDeviceCore/`, `ThirdParty/` (pinned MoltenVK or gfxstream), `Packages/ImageCore/` (`BootOptions.gpuProfile`), `Guest/product/`, `Tests/IntegrationTests/GraphicsTests/` |

**Goal.** An ADR decides, from measured spike results, whether APKRun offers Vulkan to Android apps, and by which path. If it implements Vulkan, Android on the Vulkan profile reports a Vulkan device, and a Vulkan fixture renders in a Mac window. The GLES path and G3 stay unchanged.

**Out of scope.**
- Changing the GLES path. VirGL with ANGLE stays the default ([ADR-0004](../../01-architecture/decisions/0004-virgl-first-graphics.md)).
- Vulkan on the stock image, and automatic fallback between profiles (there is none, [graphics.md](../../02-design/graphics.md) §9).
- Moving the renderer into its own process ([graphics.md](../../02-design/graphics.md) §11), and VM save and restore (R-07).

**Steps.**
1. **Shared memory spike.** In `Experiments/vulkan/shared-memory/`, add a `VZVirtioSharedMemoryRegionConfiguration` with region ID 1 to the custom virtio-gpu device. Read `maximumAllowedSharedMemoryRegionCount`, which must be at least 1. Map anonymous, IOSurface-backed, and Metal-heap-backed memory with `VZVirtioSharedMemoryRegion.mapMemory(_:atOffset:size:)`, and have a guest module write and read it. Record the count, the mappable backing types, and the time per map in [graphics.md](../../02-design/graphics.md) §10. **Check:** if the count is 0, or no GPU-usable memory maps, the ADR records "not feasible" and steps 2, 3, and 5–7 are skipped.
2. **Host renderer spike.** In `Experiments/vulkan/host-renderer/`, build virglrenderer's venus backend against MoltenVK from pinned revisions ([build-system.md](../../05-development/build-system.md) §6). Assess what porting gfxstream's host renderer to this device model needs. For each option record whether it builds reproducibly, its license and size, its Vulkan version and extensions, and whether a sample workload runs with the step 1 memory. **Check:** the comparison is recorded in [graphics.md](../../02-design/graphics.md) §10.
3. **Guest spike.** Build a Venus-capable Mesa into a test variant of the custom image, selected by the bootconfig keys of [android-image.md](../../02-design/android-image.md) §6.2. The test variant is never a release image. **Check:** `cmd gpu vkjson` lists the Venus device in the guest, SurfaceFlinger still composes through GLES, and the changed bootconfig keys are recorded in [graphics.md](../../02-design/graphics.md) §10.
4. **ADR.** Write the ADR with the next free number (the next free number). Its Context holds the spike numbers, its Decision is Venus on MoltenVK, gfxstream, or "not now", and its Consequences cover new dependencies, image changes, attack surface ([graphics.md](../../02-design/graphics.md) §11), memory (R-08), R-07, and the compatibility levels ([scope.md](../../00-product/scope.md) §4). Link it from [graphics.md](../../02-design/graphics.md) §10 and ADR-0004, and update R-01, R-03, and R-08 in [risks.md](../risks.md). **Check:** the ADR is Accepted. A "not now" decision ends the task, and steps 5–7 move to a new task.
5. **Device and renderer (only if implemented).** Add the Vulkan GPU profile to the table of [graphics.md](../../02-design/graphics.md) §9. Only this profile offers `VIRTIO_GPU_F_RESOURCE_BLOB`, `VIRTIO_GPU_F_CONTEXT_INIT`, and the shared memory region. The `drmVirgl` features stay as in [graphics.md](../../02-design/graphics.md) §4.1. GraphicsCore adds blob resources in `ResourceTable` with the limits of [graphics.md](../../02-design/graphics.md) §5.4, `CONTEXT_INIT` context types, and per-context fence timelines by `ring_idx`. The chosen backend goes into `GraphicsBridge`, pinned in `ThirdParty/`. **Check:** T0 tests of the blob and fence state machines pass, and G3 passes unchanged on `drmVirgl`.
6. **Image and profile selection (only if implemented).** Add the Venus-capable Mesa to `Guest/product/`, and the new profile's bootconfig keys to `AndroidBootPlanner`. `BootOptions.gpuProfile` selects the profile per boot. Until the ADR verification passes, select it only with `apkrun dev boot --gpu <profile>`. **Check:** the image boots with each profile, and on `drmVirgl` the `ro.cpuvulkan.version` and the GLES renderer string are unchanged.
7. **Tests, fuzzing, acceptance (only if implemented).** Write the test plan for the track, with the tiers of [test-strategy.md](../test-strategy.md) §2. Add a Vulkan fixture to `Tests/Fixtures/AndroidApps/`. Add fuzz targets for the blob and context commands to #92. Measure the fixture's frame rate with the perf harness (#71). Update the compatibility levels in [scope.md](../../00-product/scope.md) §4 and the database (#91). **Check:** the acceptance criteria pass.

**Tests.**
- T0 (`Packages/GraphicsCore/Tests/GraphicsCoreTests/`, `Packages/ImageCore/Tests/ImageCoreTests/`), only if implemented: the blob and fence-timeline state machines, the new limits, and the profile-to-feature and bootconfig mapping. The spikes have no CI tests.
- T1 (`Packages/GraphicsCore/Tests/GraphicsCoreSystemTests/`), only if implemented: fuzz targets for the blob and context commands, with reproducer replay.
- T2 (`Tests/IntegrationTests/GraphicsTests/`, custom image): if implemented, the Vulkan fixture renders in a window on the Vulkan profile with no host readback. Always, the GLES suites on `drmVirgl` pass unchanged.
- T3: G3 unchanged on the reference Mac. `fuzz-long` for the new targets. If implemented, the fixture's frame rate.

**Done when.**
- The spike results (shared memory count, mappable backing types, the host renderer comparison, and the guest Vulkan device) are recorded in [graphics.md](../../02-design/graphics.md) §10.
- An ADR with status Accepted decides the Vulkan path or "not now", with the spike numbers.
- If implemented: Android on the Vulkan profile lists a Vulkan device, the fixture renders in a Mac window with no CPU readback, and guest-controlled blob and context commands are bounded by limits and fuzzed.
- The `drmVirgl` profile offers the same features as in v1, and the GLES suites and G3 pass unchanged.
- No v1.x release waited for this track.

**Pitfalls.**
- A feature bit offered to the guest changes what Mesa virgl negotiates. Offer the new bits only on the new profile.
- Spike 1 decides the track. Do not go deep into spike 2 before the shared memory result is known.

---

## #98 Google Play authority

| Field | Value |
|---|---|
| Milestone | Post-v1 |
| Depends on | #40, #50 |
| Design | [update-system.md](../../02-design/update-system.md) §2.1, §2.3; [package-store.md](../../02-design/package-store.md) §6.3, §9.3; [guest-protocol.md](../../02-design/guest-protocol.md) §11.4; [ADR-0010](../../01-architecture/decisions/0010-update-authority-provider-split.md) |
| Code | `Experiments/google-play/` (spikes), `docs/01-architecture/decisions/` (ADR). If implemented: `Packages/APKStoreCore/` (reconciliation, adoption), `Packages/UpdateCore/` (authority rules), `Packages/RuntimeAPI/`, `Apps/APKRun/Features/Home/`, `Apps/APKRun/Features/AppPage/`, `CLI/apkrun/Commands/`, `Tests/Fixtures/AndroidApps/` (stand-in installer) |

**Goal.** An ADR decides, with legal and technical evidence, whether APKRun supports packages that a user-provided Google Play installs and updates. APKRun never distributes GMS and never circumvents Play Integrity. If it implements support, such packages get the authority `googlePlay`. APKRun then checks no provider for them, installs no update for them, claims no update ownership, and shows "Managed by Google Play".

**Out of scope.**
- Bundling, downloading, or installing GMS or Google Play. A `googlePlay` update provider, or fetching APKs from Play.
- Play Integrity circumvention, certification spoofing, or signature bypass of any kind (NFR-SEC-04). These are never implemented.
- Bridging Google sign-in or FCM push to the Mac. Any change to `apkrun`, `manual`, or `external` packages, or to images without Play.

**Steps.**
1. **Legal investigation.** List the lawful ways a user could have Google Play in the VM without APKRun distributing it, including not supporting it, with the source of each finding ([ADR-0001](../../01-architecture/decisions/0001-real-android-in-vm.md), [legal-and-licensing.md](../../05-development/legal-and-licensing.md)). The owner of the #94 checklist reviews the findings. **Check:** the findings are in the ADR draft. If no lawful way exists, go to step 3 with "not now".
2. **Technical spike.** In `Experiments/google-play/`, use a stand-in installer on the custom image. It has the package name `com.android.vending`, installs a fixture package, and claims update ownership as Play would. The image has no Play, so the name is free. If step 1 found a lawful test environment with Play, repeat the checks there. Record `installer_of_record` and `update_owner` of the installed package, whether the stand-in can update a package that `io.apkrun.store` owns, what `RelinquishUpdateOwnership` (op 109) does when an APKRun package changes to `googlePlay`, and whether the stand-in then takes over updates. **Check:** the results are recorded in [update-system.md](../../02-design/update-system.md) §2.1 and [package-store.md](../../02-design/package-store.md) §6.3.
3. **ADR.** Write the ADR with the next free number. Its Context holds the findings of steps 1 and 2. Its Decision is "support Play-managed packages" or "not now". Its Consequences name the isolation rules: only the authority value and the detection change, no GMS code or data in APKRun, and no new provider. Relate it to ADR-0001 and ADR-0010, and settle R-09 and R-10 in [risks.md](../risks.md). **Check:** the ADR is Accepted. A "not now" decision ends the task.
4. **Detection and adoption (only if implemented).** Reconciliation marks an unmanaged package as managed by Google Play when its `installer_of_record` or `update_owner` is `com.android.vending`. Home → Other Android apps shows "Managed by Google Play" ([package-store.md](../../02-design/package-store.md) §9.1–§9.3). Adoption creates the record with `updateAuthority: googlePlay`, not `external`. Like `external`, such a package has no artifact and cannot be restored after Reset Android, and the adopt sheet says so. **Check:** T0 reconciliation and adoption tests pass with recorded `StorePackageInfo` values.
5. **Authority rules and UI (only if implemented).** Changing an `apkrun` or `manual` package to `googlePlay` calls op 109 and keeps the record. UpdateCore never checks providers and never installs for a `googlePlay` package. A user-supplied file for a `googlePlay` package asks to switch to `manual` first, as for `external`. The app page shows a read-only "Managed by Google Play" state with no update choices, and `apkrun info <package>` shows the authority ([update-system.md](../../02-design/update-system.md) §2.3). **Check:** T0 rule and UI mapping tests pass, and a T1 test with a counting fake provider shows zero checks.
6. **Tests and acceptance.** Write the test plan for the track, with the tiers of [test-strategy.md](../test-strategy.md) §2. Add the stand-in installer to `Tests/Fixtures/AndroidApps/` as a test-only fixture. Run the #40 ownership tests and G9. **Check:** the acceptance criteria pass.

**Tests.**
- T0 (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Packages/UpdateCore/Tests/UpdateCoreTests/`, `Apps/APKRun/Tests/`, `CLI/apkrun/Tests/`), only if implemented: detection from `installer_of_record` and `update_owner`, adoption with `googlePlay`, the authority rules, the UI mapping, and CLI golden files.
- T1 (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`), only if implemented: a counting fake provider shows zero checks for `googlePlay` packages.
- T2 (`Tests/IntegrationTests/StoreTests/`, `Tests/IntegrationTests/UpdateTests/`, custom image): if implemented, a package that the stand-in installed is detected, nothing is installed for it after adoption, and a change to `googlePlay` relinquishes ownership (op 109). Always, the #40 ownership tests pass unchanged.
- T3: G9 unchanged on the reference Mac, and a manual check in a lawful Google Play environment if step 1 found one.

**Done when.**
- The legal findings and the spike results are recorded. The spike covers `installer_of_record`, `update_owner`, ownership enforcement, and op 109.
- An ADR with status Accepted decides "support" or "not now", and relates to ADR-0001 and ADR-0010.
- If implemented: a package that Google Play or the stand-in installed shows "Managed by Google Play", and adopting it gives `updateAuthority: googlePlay`. APKRun never checks providers, installs updates, or claims ownership for it. A change to `googlePlay` calls `RelinquishUpdateOwnership`. The app page is read-only.
- APKRun contains no GMS component, and nothing bypasses Play Integrity or signature checks (NFR-SEC-04).
- The #40 ownership tests and G9 pass unchanged.

**Pitfalls.**
- The stand-in installer is test-only, and it is never part of a release image.
- Two automatic updaters must never manage the same package ([update-system.md](../../02-design/update-system.md) §2.1). If Google Play can update an APKRun-owned package, file a finding against #40 before any implementation.
