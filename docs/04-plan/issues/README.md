# Implementation Issues

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../../AGENTS.md](../../../AGENTS.md) |

Every unit of implementation work is one numbered task. Each task becomes one GitHub issue with the same number and title. The files in this directory are the source of truth for the issue text. If an issue and this directory disagree, fix this directory first, then the issue.

---

## 1. Files

| File | Milestone | Version | Tasks |
|---|---|---|---|
| [M00-repository-and-vm-foundation.md](M00-repository-and-vm-foundation.md) | M0 Repository and VM foundation | v0.1 | #001–#007, #061, #062, #063 |
| [M01-android-bring-up.md](M01-android-bring-up.md) | M1 Android bring-up | v0.1 | #008–#017, #064, #065, #095 |
| [M02-graphics.md](M02-graphics.md) | M2 Graphics | v0.1 | #018–#023, #099 |
| [M03-input-and-basic-runtime.md](M03-input-and-basic-runtime.md) | M3 Input and basic runtime | v0.1 / v0.2 | #033, #072, #024–#030, #067 |
| [M04-daemon-and-guest-protocol.md](M04-daemon-and-guest-protocol.md) | M4 Daemon and guest protocol | v0.2 | #031, #032, #066, #068, #034, #053, #069, #070, #071 |
| [M05-custom-android-image.md](M05-custom-android-image.md) | M5 Custom Android runtime image | v0.3 | #035, #036 |
| [M06-update-system.md](M06-update-system.md) | M6 Update system | v0.3 | #073, #037–#043, #050, #074 |
| [M07-mac-app-wrappers.md](M07-mac-app-wrappers.md) | M7 Mac app wrappers | v0.4 | #044–#049, #055, #056, #075–#079, #089 |
| [M08-real-update-sources.md](M08-real-update-sources.md) | M8 Real update sources | v0.5 | #051, #052 |
| [M09-macos-integration.md](M09-macos-integration.md) | M9 macOS integration | v0.5 | #054, #080–#082, #085, #086 |
| [M10-runtime-maintenance.md](M10-runtime-maintenance.md) | M10 Runtime maintenance | v0.5 | #057, #058, #087 |
| [M11-diagnostics.md](M11-diagnostics.md) | M11 Diagnostics | v0.5 | #059, #060 |
| [M12-v1-release.md](M12-v1-release.md) | M12 v1.0 release | v1.0 | #083, #084, #088, #090–#094 |
| [post-v1.md](post-v1.md) | Post-v1 tracks | — | #096, #097 |

Inside each file, tasks appear in the order they should be worked on. That order respects the dependencies in §3.

---

## 2. Task entry format

Every task in the milestone files uses this layout. Keep the headings, even when a section only says "None".

```markdown
## #NNN Title

| Field | Value |
|---|---|
| Milestone | M<n> (v<x.y>) |
| Depends on | #…, #… (or "None") |
| Gate | G<n> (only if this task closes a gate) |
| Requirements | FR-…, NFR-… |
| Design | links to the design sections that specify the behavior |
| Modules / paths | the modules, targets, and repository paths the task changes |
| Risks / questions | R-…, OQ-… (or "None") |

### Goal
One or two sentences: the observable result.

### Scope
In scope, as a bullet list. Then "Out of scope" with explicit exclusions (scope discipline, scope.md §5).

### Deliverables
Files, targets, tools, fixtures, and docs that exist when the task is done.

### Implementation steps
Numbered steps in execution order. Each step is small enough for one pull request, names the types and
files it touches, and ends in something that can be checked. The design documents hold the full
specification; steps link to the exact section instead of repeating it.

### Tests
By tier (T0–T3, [../test-strategy.md](../test-strategy.md)): what is tested and where the test lives.

### Acceptance criteria
- [ ] Checkable statements. Every acceptance criterion appears here, reworded only where the design changed it.

### Notes
Verification results to record, follow-ups to file, and pitfalls.
```

Section references in a task entry: a bare `§N` refers to the first document in the entry's Design row. Every other document is named with a link before its `§N`.

---

## 3. Task index

"Design" names the main design document. Dependencies are hard: a task may start only when every task it depends on meets its acceptance criteria. Work on independent tasks can run in parallel.

| Task | Title | Milestone | Depends on | Gate | Main design |
|---|---|---|---|---|---|
| #001 | Bootstrap Xcode workspace | M0 | None | | [modules.md](../../01-architecture/modules.md), [build-system.md](../../05-development/build-system.md) |
| #002 | VMDefinition and VM validation | M0 | #001 (done only after #061 step 4) | | [vm.md](../../02-design/vm.md) §2–§3 |
| #003 | Boot minimal ARM64 Linux | M0 | #002 | G1 | [vm.md](../../02-design/vm.md) §4, §9, §12 |
| #004 | Serial console logging | M0 | #003 | | [vm.md](../../02-design/vm.md) §6 |
| #005 | virtio-blk storage | M0 | #003 | | [vm.md](../../02-design/vm.md) §2, §4, §5 |
| #006 | Guest networking | M0 | #003 | | [vm.md](../../02-design/vm.md) §7 |
| #007 | virtio-vsock | M0 | #003 | | [vm.md](../../02-design/vm.md) §8 |
| #061 | Diagnostics foundation | M0 | #001 | | [diagnostics.md](../../02-design/diagnostics.md) §2–§4 |
| #062 | CI and module dependency checks | M0 | #001 | | [build-system.md](../../05-development/build-system.md), [modules.md](../../01-architecture/modules.md) §3 |
| #063 | VirtioDeviceCore and test virtio device | M0 | #003 | | [graphics.md](../../02-design/graphics.md) §3 |
| #008 | Acquire and inventory ARM64 Cuttlefish artifacts | M1 | #001 | | [android-image.md](../../02-design/android-image.md) §2–§3.1 |
| #064 | Reference boot capture | M1 | #008 | | [android-image.md](../../02-design/android-image.md) §8 |
| #009 | AndroidImageManifest | M1 | #008 | | [android-image.md](../../02-design/android-image.md) §3.2 |
| #010 | Extract Android kernel and ramdisk | M1 | #008, #009 | | [android-image.md](../../02-design/android-image.md) §4.1, §6 |
| #011 | GPT disks and partition mapping | M1 | #005, #009, #010 | | [android-image.md](../../02-design/android-image.md) §4.2, §5 |
| #012 | Boot the Android kernel | M1 | #010, #011 | | [android-image.md](../../02-design/android-image.md) §6 |
| #013 | Reach Android init | M1 | #012 | | [android-image.md](../../02-design/android-image.md) §6 |
| #095 | Cuttlefish host-service substitution | M1 | #013 | | [android-image.md](../../02-design/android-image.md) §7 |
| #014 | Reach system_server and boot_completed | M1 | #013, #095 | G2 | [android-image.md](../../02-design/android-image.md) §6–§8 |
| #015 | ADB debugging over vsock | M1 | #014, #007 | | [android-image.md](../../02-design/android-image.md) §7, [runtime-daemon.md](../../02-design/runtime-daemon.md) |
| #016 | Install HelloText APK | M1 | #015 | | [package-store.md](../../02-design/package-store.md), [cli.md](../../02-design/cli.md) §5 |
| #017 | Launch HelloText APK | M1 | #016 | | [cli.md](../../02-design/cli.md) §5 |
| #065 | Runtime image bundle | M1 | #014 | | [android-image.md](../../02-design/android-image.md) §10 |
| #018 | Analyze the RiftVM GPU prototype | M2 | #001 | | [graphics.md](../../02-design/graphics.md) §2 |
| #019 | virtio-gpu device layer | M2 | #018, #003, #063 | | [graphics.md](../../02-design/graphics.md) §4 |
| #020 | Build graphics dependencies | M2 | #018 | | [graphics.md](../../02-design/graphics.md) §5 |
| #021 | Android detects virtio-gpu | M2 | #019, #014 | | [graphics.md](../../02-design/graphics.md) §4 |
| #099 | Mesa-enabled VirGL guest image | M2 | #020, #021 | | [graphics.md](../../02-design/graphics.md) §5 |
| #022 | Android VirGL | M2 | #021, #020 | | [graphics.md](../../02-design/graphics.md) §5 |
| #023 | Render SurfaceFlinger to Metal | M2 | #020, #022 | G3 | [graphics.md](../../02-design/graphics.md) §6 |
| #033 | Define GuestProtocol | M3 | #007 | | [guest-protocol.md](../../02-design/guest-protocol.md) |
| #072 | Guest Agent bootstrap | M3 | #033, #015 | | [guest-protocol.md](../../02-design/guest-protocol.md), [guest-components.md](../../02-design/guest-components.md) |
| #024 | Pointer input | M3 | #023, #072 | | [input.md](../../02-design/input.md) |
| #101 | Input route rebinds after the guest agent is lost (follow-up of #024) | M3 | #024 | | [input.md](../../02-design/input.md) §3, [guest-components.md](../../02-design/guest-components.md) §3.3 |
| #025 | Keyboard input | M3 | #024 | | [input.md](../../02-design/input.md) |
| #026 | HelloText in a native Mac window | M3 | #023, #024, #025 | G4 | [display-and-windowing.md](../../02-design/display-and-windowing.md) §7 |
| #027 | RuntimeCore package operations | M3 | #026 | | [package-store.md](../../02-design/package-store.md) |
| #067 | Retina, density, and resize | M3 | #026 | | [display-and-windowing.md](../../02-design/display-and-windowing.md) §6 |
| #028 | DisplayPool | M3 | #027, #067 | | [display-and-windowing.md](../../02-design/display-and-windowing.md) §3 |
| #029 | App on a secondary Android display | M3 | #028 | | [display-and-windowing.md](../../02-design/display-and-windowing.md) §4, §8 |
| #030 | Two APKs in two native windows | M3 | #029 | G5 | [display-and-windowing.md](../../02-design/display-and-windowing.md), [input.md](../../02-design/input.md) §7 |
| #031 | Introduce apkrund | M4 | #030 | G6 (headless form) | [runtime-daemon.md](../../02-design/runtime-daemon.md) |
| #032 | XPC runtime API | M4 | #031 | | [runtime-daemon.md](../../02-design/runtime-daemon.md) §8, [runtime-api.md](../../03-reference/runtime-api.md) |
| #066 | First-run provisioning | M4 | #032, #065, #068 | | [runtime-daemon.md](../../02-design/runtime-daemon.md) §9, [host-ui.md](../../02-design/host-ui.md) §4 |
| #068 | Session client and IOSurface window over XPC | M4 | #032 | G6 (full form) | [display-and-windowing.md](../../02-design/display-and-windowing.md) §5 |
| #034 | Full Guest Agent protocol and vsock transport | M4 | #033, #027 | | [guest-protocol.md](../../02-design/guest-protocol.md), [guest-components.md](../../02-design/guest-components.md) |
| #053 | Clipboard, plain text | M4 | #034, #068 | | [desktop-integration.md](../../02-design/desktop-integration.md) §4 |
| #069 | Idle policy and host sleep/wake | M4 | #031 | | [runtime-daemon.md](../../02-design/runtime-daemon.md) §5–§6 |
| #070 | Performance harness | M4 | #031, #068 | | [diagnostics.md](../../02-design/diagnostics.md) §9 |
| #071 | APKRun IME | M4 | #034, #068 | | [input.md](../../02-design/input.md) §5, [guest-components.md](../../02-design/guest-components.md) §7 |
| #035 | APKRun AOSP product | M5 | #034 | | [android-image.md](../../02-design/android-image.md) §11, [guest-components.md](../../02-design/guest-components.md) §10 |
| #036 | Store Agent | M5 | #035 | | [guest-components.md](../../02-design/guest-components.md) §8, [package-store.md](../../02-design/package-store.md) |
| #073 | Host inspection and import formats | M6 | #036 | | [package-store.md](../../02-design/package-store.md) |
| #037 | LocalUpdateProvider | M6 | #036 | | [update-system.md](../../02-design/update-system.md) §4.3 |
| #038 | PackageInstaller updates | M6 | #037, #073 | | [update-system.md](../../02-design/update-system.md), [package-store.md](../../02-design/package-store.md) |
| #039 | Update ownership | M6 | #038 | | [update-system.md](../../02-design/update-system.md) |
| #040 | Gentle updates | M6 | #039 | G7 | [update-system.md](../../02-design/update-system.md) §7 |
| #041 | Package and signature verification | M6 | #038, #073 | | [update-system.md](../../02-design/update-system.md) §6, [package-store.md](../../02-design/package-store.md) |
| #042 | Split APK installation | M6 | #041, #073 | | [package-store.md](../../02-design/package-store.md) |
| #043 | Update rollback | M6 | #041, #042 | | [update-system.md](../../02-design/update-system.md) §8 |
| #050 | DirectProvider | M6 | #037, #041 | | [update-system.md](../../02-design/update-system.md) §4.4, [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) |
| #074 | Update scheduler | M6 | #037, #040, #050 | | [update-system.md](../../02-design/update-system.md) §3 |
| #044 | Launcher as a wrapper (APKRunLauncher) | M7 | #032, #068 | | [wrapper.md](../../02-design/wrapper.md) §5 |
| #045 | WrapperCore generator | M7 | #044 | | [wrapper.md](../../02-design/wrapper.md) §6 |
| #046 | Generate Hello.app | M7 | #045 | | [wrapper.md](../../02-design/wrapper.md) §4, §7 |
| #047 | Launch Hello.app end to end | M7 | #046, #031 | G8 | [wrapper.md](../../02-design/wrapper.md) §5 |
| #055 | Android icon to macOS icon pipeline | M7 | #045, #036 | | [wrapper.md](../../02-design/wrapper.md) §8 |
| #056 | Finder, Dock, and Spotlight integration | M7 | #055 | | [wrapper.md](../../02-design/wrapper.md) |
| #048 | Wrapper independent of the APK file | M7 | #047, #037 | | [wrapper.md](../../02-design/wrapper.md), [package-store.md](../../02-design/package-store.md) |
| #049 | Automatic update behind an unchanged wrapper | M7 | #043, #048 | G9 | [wrapper.md](../../02-design/wrapper.md), [update-system.md](../../02-design/update-system.md) |
| #075 | `apkrun wrap` CLI | M7 | #046, #048 | | [wrapper.md](../../02-design/wrapper.md) §12, [cli.md](../../02-design/cli.md) |
| #076 | Wrapper lifecycle and uninstall choices | M7 | #048 | | [wrapper.md](../../02-design/wrapper.md) §9, [host-ui.md](../../02-design/host-ui.md) §8 |
| #077 | Home and store UI | M7 | #048 | | [host-ui.md](../../02-design/host-ui.md) §5 |
| #078 | Add flow | M7 | #077, #073 | | [host-ui.md](../../02-design/host-ui.md) §6 |
| #079 | Per-app settings | M7 | #077, #039, #074 | | [host-ui.md](../../02-design/host-ui.md) §7 |
| #089 | Portable wrappers | M7 | #075 | | [wrapper.md](../../02-design/wrapper.md) §10 |
| #051 | F-Droid provider | M8 | #050 | | [update-system.md](../../02-design/update-system.md) §4.5 |
| #052 | GitHub provider | M8 | #050 | | [update-system.md](../../02-design/update-system.md) §4.6 |
| #054 | Notifications | M9 | #034, #035, #047 | | [desktop-integration.md](../../02-design/desktop-integration.md) §5 |
| #080 | Image and HTML clipboard | M9 | #053 | | [desktop-integration.md](../../02-design/desktop-integration.md) §4 |
| #081 | Links | M9 | #034, #035, #047 | | [desktop-integration.md](../../02-design/desktop-integration.md) §7 |
| #082 | Files | M9 | #034, #035 | | [desktop-integration.md](../../02-design/desktop-integration.md) §6 |
| #085 | Locale, time zone, clock format, and time | M9 | #034, #035, #069 | | [desktop-integration.md](../../02-design/desktop-integration.md) §9 |
| #086 | Menu bar | M9 | #032 | | [host-ui.md](../../02-design/host-ui.md) §12 |
| #057 | APKRun runtime updater | M10 | #031, #049 | | [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3 |
| #058 | Guest image versioning and migration | M10 | #035, #057 | | [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4, [android-image.md](../../02-design/android-image.md) §12 |
| #087 | Runtime image distribution | M10 | #058, #065 | | [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4, [android-image.md](../../02-design/android-image.md) §10.4 |
| #059 | `apkrun doctor` | M11 | #031, #034, #036 | | [diagnostics.md](../../02-design/diagnostics.md) §7 |
| #060 | Diagnostics bundle | M11 | #004, #059 | | [diagnostics.md](../../02-design/diagnostics.md) §8 |
| #083 | Audio output | M12 | #035 | | [desktop-integration.md](../../02-design/desktop-integration.md) §8.1, [vm.md](../../02-design/vm.md) §11 |
| #084 | Microphone | M12 | #083 | | [desktop-integration.md](../../02-design/desktop-integration.md) §8.2 |
| #088 | Developer ID signing, notarization, and distribution wrappers | M12 | #062, #046 | | [wrapper.md](../../02-design/wrapper.md) §11, [build-system.md](../../05-development/build-system.md) |
| #090 | Compatibility database | M12 | #059 | | [diagnostics.md](../../02-design/diagnostics.md) §10 |
| #091 | Security hardening and fuzzing | M12 | #031, #034 | | [security-model.md](../../01-architecture/security-model.md) |
| #092 | Localization and accessibility | M12 | #077 | | [host-ui.md](../../02-design/host-ui.md) §13 |
| #093 | Legal and licensing compliance | M12 | #020, #035 | | [legal-and-licensing.md](../../05-development/legal-and-licensing.md) |
| #094 | v1.0 release readiness | M12 | every other v1.0 task | | [../roadmap.md](../roadmap.md) §3 |
| #096 | Vulkan track | Post-v1 | #023, #035 | | [graphics.md](../../02-design/graphics.md) §10 |
| #097 | Google Play authority | Post-v1 | #039, #049 | | [update-system.md](../../02-design/update-system.md), [package-store.md](../../02-design/package-store.md) |

Gates G1–G9 are the project checkpoints. Their pass conditions are in [../roadmap.md](../roadmap.md) §2. The post-v1 tracks are numbered "Phase 21" (Vulkan) and "Phase 22" (Google Play).

---

## 4. Rules for working an issue

- In a new repository, a maintainer first creates the GitHub issues of #001–#097 from the milestone files, in number order, with the task template, before any other issue or pull request is opened. GitHub numbers issues and pull requests in one sequence, so this keeps each task's number equal to its issue number ([../../05-development/workflow.md](../../05-development/workflow.md) §2.4).
- Take the lowest-numbered task in the current milestone whose dependencies are done, unless the roadmap says otherwise ([../roadmap.md](../roadmap.md) §1).
- One task per branch. The branch and pull request name the task (`task/024-pointer-input`, "#024 Pointer input"). [../../05-development/workflow.md](../../05-development/workflow.md) has the branch, review, and merge rules.
- Follow the steps in order. If a step is wrong or impossible, change the design document and this file in the same pull request, and say why in the pull request.
- Keep the scope. If finishing a task needs something outside its scope, stop and file a follow-up task ([../../00-product/scope.md](../../00-product/scope.md) §5). New tasks get their number from GitHub when their issue is opened (#098 and up, not contiguous) and go into the milestone file and §3 ([../../05-development/workflow.md](../../05-development/workflow.md) §2.4).
- Record verification results where the task's Notes section says (design document verification logs, [../risks.md](../risks.md), ADRs).
- A task is done when all acceptance criteria are checked, the tests of every tier the task lists pass, and the documents the task changes are updated.

## 5. Current progress

**Updated:** 2026-10-11 UTC (state of `main` at `213984d`)
**Working branch:** `main`

Task entries remain the source of truth for scope and acceptance. This section
summarizes the work in progress on `main`. Its facts come from three sources:
the acceptance checkboxes in each milestone file (counted per task by script),
the IR entries that record open decisions, and the git log of `main`. The table
lists every task in progress (some boxes ticked, some open), and #035 and #098,
which have open decisions on `main` but no ticked box. The other 64 tasks with
no ticked box are not listed. Tasks whose boxes are all ticked are listed in one
line below the table.

**Counts on `main`:** 96 tasks have a milestone entry (#001 to #095 and #099; #096 and
#097 are post-v1 tracks). 22 have every box ticked, 9 are in progress
(some boxes ticked and some open), and 65 have no ticked box. The IR log has 648
entries: 635 are marked exactly "Needs maintainer review", 6 add a qualifier to that status, and 7
carry another status. Two entries carry the number IR-901 (see the note below the table).

**Project position:** The task issues #001 to #097 are mirrored as issues #2 to #98 (IR-293).
Branch protection on `main` requires the eight CI checks (IR-294). IR-297 records the decision to
close #002 and #003 as implemented, with maintainer review open. On GitHub at 2026-10-11, issue #3
(#002) is closed and issue #4 (#003) is open. #014 (8 of 8) and #015 (6 of 6) are ticked on `main`;
the clean-`main` G2 pass for #014 is recorded in `f064070`, and the final-`main` pass in `37a81b5`.
The stock Android image boots directly on Virtualization.framework (IR-306).

| Task | Boxes ticked on `main` | Open on `main` | IR records |
|---|---|---|---|
| [#003 Boot minimal ARM64 Linux](M00-repository-and-vm-foundation.md#003-boot-minimal-arm64-linux) | 11 of 12 | The `linux-guest` T2 box stays open. The criterion needs a maintainer-run T2 result for the reviewed commit until lab capacity allows PR runs, and no lab runner exists (IR-295). | IR-295, IR-313, IR-314, IR-297 |
| [#010 Extract Android kernel and ramdisk](M01-android-bring-up.md#010-extract-android-kernel-and-ramdisk) | 6 of 7 | Each `(reference)` value must trace to a capture or a VZ observation. The `drm_virgl` values stay unconfirmed until #022 confirms them; the maintainer chooses between accepting the source-derived set and emptying it. | IR-400, IR-401, IR-404 |
| [#016 Install HelloText APK](M01-android-bring-up.md#016-install-hellotext-apk) | 4 of 5 | The device check of the counter across a restart waits for rendering and input (#026). The click cannot be driven yet: the headless profile draws no window. | IR-333 (the persistence contract is a JVM test). No IR entry records the window problem; the criterion text is the record. |
| [#022 Android VirGL](M02-graphics.md#022-android-virgl) | 2 of 6 | `dumpsys SurfaceFlinger` naming the virgl renderer, with no SwiftShader or ANGLE library; the §9 documentation and reproducibility; and `sys.boot_completed=1` with `drmVirgl` (`guestSwiftshader` reached it, IR-801). The `drmVirgl` boot waits for the #035 sepolicy route. kmscube on the VM is ticked (IR-860). IR-849 lists three VM checks (pointer bytes, reset and stop ordering, resource 4 entries) that IR-860 does not record as run. | IR-800, IR-801, IR-849, IR-850, IR-905 |
| [#061 Diagnostics foundation](M00-repository-and-vm-foundation.md#061-diagnostics-foundation) | 9 of 10 | OQ-04 (`log show` as a standard user) stays open. This host has no non-admin account. The limit is recorded in the [#061 Notes](M00-repository-and-vm-foundation.md#061-diagnostics-foundation) and in [open-questions.md](../open-questions.md). | No IR entry records OQ-04. IR-246 and IR-247 (maintainer review pending) are the open review. |
| [#064 Reference boot capture](M01-android-bring-up.md#064-reference-boot-capture) | 2 of 6 | Re-scoped (IR-305). Open: the `default`, `target`, and `swiftshader` profiles with every §8.3 item (deferred); normalized captures with no serial numbers, MAC addresses, host paths, or keys; the serial-shell run of `guest-capture.txt` (part of #014 step 5); and a schema-version-3 `host.json` with path-free host-tool identities (deferred). | IR-305, IR-306, IR-269, IR-271, IR-184 |
| [#072 Guest Agent bootstrap](M03-input-and-basic-runtime.md#072-guest-agent-bootstrap) | 7 of 7 | The T2 suite `GuestAgentTests` passed 8 of 8 in the Xcode test host on 2026-10-13 (IR-438). The CLI does not print `runtime.requiredAgentUnavailable`, and whether it should is open; the code is asserted at T0 (IR-1229). Closure is for the maintainer (IR-1259). The device checks of 2026-10-12 are in the Notes. | IR-1226 to IR-1231, IR-435, IR-438, IR-1253 to IR-1255, IR-425, IR-431 (method variants) |
| [#024 Pointer input](M03-input-and-basic-runtime.md#024-pointer-input) | 6 of 8 | Open: the 100-of-100 box, because 10 of 74 batches without a sweep logged 95 to 99 with no explanation (IR-1247, IR-1250); and the trackpad and wheel check (box 4), which is the manual check C01-2 (T3) and needs a person. Box 7 is flagged, not re-decided (IR-1250). The route does not rebind after an agent loss; the follow-up is #101. The T2 suite `AndroidInputTests` runs in the Xcode test host and fails there at guest app rendering on the odm4 bundle (IR-1257). | IR-1233 to IR-1257 |
| [#025 Keyboard input](M03-input-and-basic-runtime.md#025-keyboard-input) | 4 of 6 | Open: box 3, because ⌘[ did not navigate back on the device in two attempts (T0 maps it to BACK). Box 4, because ⌘C, ⌘V, and ⌘Z were not confirmed in a clean run (IR-1268, IR-1269). The repository has no T2 keyboard case (IR-1271), and a pointer tap does not reliably focus the field (IR-1270). | IR-1263 to IR-1272 |
| [#095 Cuttlefish host-service substitution](M01-android-bring-up.md#095-cuttlefish-host-service-substitution) | 6 of 7 | Criterion 1 (all 20 console ports attached and numbered by `APKRUN-PORT` markers) stays open. The pinned test kernel exposes 8 `hvc` nodes (IR-372), and the 2026-10-11 boot received markers on `hvc0` and `hvc1` only (IR-877). IR-901 (second entry) records 13 ports that receive their full marker in two boots, and four ports (`hvc5`, `hvc8`, `hvc9`, `hvc12`) that product HALs read. The criterion text does not yet reflect IR-901. | IR-372, IR-873, IR-877, IR-901 (second entry) |
| [#099 Mesa-enabled VirGL guest image](M02-graphics.md#099-mesa-enabled-virgl-guest-image) | 1 of 4 | Open: the corrected image's own build identity, manifest, and hashes; `eglInitialize` on the VirGL display (`apkrun.test=egl`); and provenance and lock pins for every new artifact. dm-verity passes with the resealed descriptor, and the boot stops in SurfaceFlinger (IR-751). The top-level vbmeta stays unsigned. | IR-650, IR-727, IR-751, IR-800, IR-837 |
| [#035 APKRun AOSP product](M05-custom-android-image.md#035-apkrun-aosp-product) | 0 of 10 | All 10 boxes are open. They cover the custom image's boot, the product contents, the remote build with provenance, the priv-app domains, the Hello capability list, the `untrusted_app` socket test, the sepolicy and `avc` checks, ADB in both developer modes, the reference diff, and the release AVB state (OQ-36). IR-900 to IR-906 record only the sepolicy route for the SurfaceFlinger sysfs label, which #022 criterion 4 needs. | IR-900, IR-903, IR-905, IR-906 |
| #098 Parallel VM runs (follow-up, GitHub issue #100) | not in §3 or a milestone file | The T2 behavior is unverified (IR-539). The one-VM rule (test-strategy §3.6) needs a maintainer decision (IR-525). | IR-525, IR-528, IR-539 |

Complete on the boxes: #001, #002, #004, #005, #006, #007, #008, #009, #011, #012, #013, #014, #015, #017, #018, #019, #020, #021, #033, #062, #063, #065. Their boxes are all ticked, and
the IR entries that record their decisions are still open for maintainer review.

**Recent work on `main`** (git log, 2026-10-09 to 2026-10-11): #022 kmscube on the VM and the
drain before invalidation (`537731c`, `efc4fef`); the #099 offline Mesa injection and the verity
steps (`10f921e` to `ce7a21e`); the #095 port and marker results (`bfd0860`, `c217fc8`,
`4c6b7c0`); and the #016 PackageInstaller tick (`3d0031e`).

**Note on IR-901.** The number IR-901 is used by the SELinux compiler entry only. The HAL-port entry was renumbered to IR-907 to remove the duplicate.
offline", is the entry that IR-904 cites. The second, "Four of the marked ports are read by product
HALs", was added by `213984d`; its Affected documents cite IR-899, which does not exist. Both are
kept as they are until a maintainer decides the numbering.

**Process gap.** #098 is not yet in §3 or in a milestone file, as AGENTS.md §11 requires for a
follow-up task.
