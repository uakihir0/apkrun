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
| [M02-graphics.md](M02-graphics.md) | M2 Graphics | v0.1 | #018–#023 |
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
| #010 | Extract Android kernel and ramdisk | M1 | #008, #009, #064 | | [android-image.md](../../02-design/android-image.md) §4.1, §6 |
| #011 | GPT disks and partition mapping | M1 | #005, #009, #010, #064 | | [android-image.md](../../02-design/android-image.md) §4.2, §5 |
| #012 | Boot the Android kernel | M1 | #010, #011 | | [android-image.md](../../02-design/android-image.md) §6 |
| #013 | Reach Android init | M1 | #012, #064 | | [android-image.md](../../02-design/android-image.md) §6 |
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
| #022 | Android VirGL | M2 | #021, #020 | | [graphics.md](../../02-design/graphics.md) §5 |
| #023 | Render SurfaceFlinger to Metal | M2 | #020, #022 | G3 | [graphics.md](../../02-design/graphics.md) §6 |
| #033 | Define GuestProtocol | M3 | #007 | | [guest-protocol.md](../../02-design/guest-protocol.md) |
| #072 | Guest Agent bootstrap | M3 | #033, #015 | | [guest-protocol.md](../../02-design/guest-protocol.md), [guest-components.md](../../02-design/guest-components.md) |
| #024 | Pointer input | M3 | #023, #072 | | [input.md](../../02-design/input.md) |
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

**Updated:** 2026-10-08 UTC
**Working branch:** `codex`

Task entries remain the source of truth for scope and acceptance. This snapshot
summarizes active work and review dependencies; acceptance checkboxes and
verification records remain in each task entry.
Every task with implementation, verification, or review work in progress must
appear here. Update its row when a meaningful test, hostile review, blocker, or
acceptance criterion changes, and keep implementation status separate from
task completion.

**Project position:** M0 #003 / G1 is still the formal gate-closing track. The
current parallel implementation focus is #061 Diagnostics foundation; its
`APKRunError` step must reach `main` before #002 can be formally completed.
Roadmap §1.4 also permits M1 #064 to proceed once #008 is done, and M2 #018
depends only on #001. These parallel tracks can advance while #003's clean
`main` gate run and task-closing reviews remain open. #010 still depends on
#064; #019 and #020 depend on #018.

| Task | Status | Verified | Remaining |
|---|---|---|---|
| #001 Bootstrap Xcode workspace | Implementation and recorded acceptance criteria complete | Full `swift test` suites passed with and without `--traits EmbeddedRuntime`, including the appropriate CLI root-help golden in each build; the original clean-checkout, Xcode build, and product smoke verification is recorded in M00 | No known implementation or acceptance gap |
| #002 VMDefinition and VM validation | Implementation and opt-in entitlement probe recorded in commit `de7c678`; acceptance tests now cover the memory minimum; IR-242 review is open | Full `swift test` passed with 111 `VirtualMachineCoreTests` and 25 default `VirtualMachineCoreSystemTests`; focused below-minimum test passed; 2 opt-in T1 tests and the no-artifact skip behavior are recorded | Maintainer review of IR-242; #061 step 4 must reach `main` before formal task completion |
| #003 Boot minimal ARM64 Linux | Active (implementation commits `44a1a7d`, `d31e7e3`) | 111 `VirtualMachineCoreTests` and 25 default `VirtualMachineCoreSystemTests` passed. T0 exercises the production VZ delegate's buffer/stream routing and controller mapping separately. Signed `LinuxGuest` T2 passed 33/33 on commit `d31e7e3` (MacBook Pro arm64, macOS 27.0.1 build 26A434); signed failure/reset and positive-control/kernel-removal probes passed 2/2; start returned `VZErrorDomain/2`, no delegate callback was observed for 2 s, and cleanup confirmed VM states `stopped` and `error`. All six `scripts/ci/run-checks.sh` checks passed. On `c497480`, the signed G1 test plan passed 4 tests with 1 configuration-scoped skip and 0 failures; the G1 ten-boot and failed-start/reset cases both passed. The skipped case was `testGuestResolvesDNSAndReachesExternalHTTPSProbe`, assigned to the Network configuration. Detailed result: [vm.md](../../02-design/vm.md) §17 | Remaining: complete the #002 hard dependency (including IR-242 review); resolve IR-243 and the paired license-policy review IR-044/IR-241; link a maintainer-run LinuxGuest T2 result for the reviewed commit before the closing PR merges; and pass `scripts/run-gate.sh G1` from a clean `main` checkout with evidence attached to the G1 gate issue |
| #061 Diagnostics foundation | Active on `codex`; current implementation and hostile-review findings addressed; acceptance remains open | Latest serial full `swift test` passed 321 tests across 11 suites. A preceding run hit a VMController driver invariant assertion; the serial rerun passed without VMController changes. All six checks in `scripts/ci/run-checks.sh` passed when run alone; `scripts/check-compile-fail.sh`, generated Swift/Markdown checks, and `git diff --check` passed. Regressions cover redacted source URLs, repeated list codes with distinct per-item values, legacy generic fallback, transparent cause inheritance, and retired catalog entries. Live `apkrun version`, `apkrun logs`, and invalid-argument exit 64 were verified earlier. Detailed scope and acceptance: [M00 #061](M00-repository-and-vm-foundation.md#061-diagnostics-foundation) | OQ-04 still needs the non-admin `log show` observation and a recorded disposition. Maintainer review of IR-246/247 remains open. RuntimeAPI wire conversion and N−1 compatibility tests are assigned to #032. Keep #061 acceptance open until all criteria and maintainer review are complete. |
| #019 virtio-gpu device layer | Active on `codex`. Protocol codecs, scanout table, EDID generator, resource table, device model, RuntimeCore attachment, and the `gpu` and `gpu-hotplug` checks are committed (4781b50, 25d1da7, 893a367, fde4b4c, 392d889). On macOS 27.0.1 (26A434): GraphicsCore T0 67 tests, protocol fuzz smoke T1 2 tests, RuntimeCore T0 3 tests pass. The golden request and response vectors are layout-derived (IR-250). | T2 is not run: the test guest cannot be built from the current lock (IR-251), so the detection, EDID, and R-01 acceptance boxes stay open. Driver-captured golden vectors are missing. Maintainer review of IR-248 to IR-257. |

**Independent progress (roadmap §1.4):**

| Task | Current evidence | Still open |
|---|---|---|
| #008 Acquire and inventory ARM64 Cuttlefish artifacts; #009 AndroidImageManifest | Acceptance criteria are marked 7/7 and 6/6 on `codex`; the pinned build 16373615 manifest and inventory are present. | Workflow completion still requires reviewed integration to `main` and issue closure. |
| #064 Reference boot capture | Active; 1/6 acceptance criteria marked. The 2026-10-07 UTC diagnostic capture verified one live crosvm ELF identity and reproduced the guest Mesa EGL load failure. Record: [#064 notes](M01-android-bring-up.md#064-reference-boot-capture), [IR-244](../implementation-review.md#ir-244-verify-live-crosvm-identity-and-repeat-mesa-egl-diagnosis), [hash/privacy/cleanup receipt](../../../Images/reference/16373615/incomplete/target-20261008T030306-2167.verification.txt). | The three comparable profiles, normalization/privacy acceptance across those profiles, guest-command equivalence, exact boot-signal timings, and per-profile metadata remain incomplete. The latest run also lacks `crosvm-command-line.txt`; it did not reach boot completion or prove rendering. |
| #010 Extract Android kernel and ramdisk | 6/7 acceptance criteria are marked; implementation and tests are recorded. | The final reference-derived values still depend on #064. |
| #018 Analyze the RiftVM GPU prototype | The analysis now records command responses, the renderer-budget estimate limits, scanout behavior, profile/topology differences, and the current patch crosswalk. Final hostile review passed on 2026-10-07. | Maintainer review of the v0.6.1 source substitution remains open under IR-188; the #019/#020 dependency is not formally closed. |

The #064 run is diagnostic evidence only: the crosvm build is uncertified for
Virgl and the capture is retained under `Images/reference/16373615/incomplete/`.
It does not change the pinned Android image or close #064. The guest Mesa
payload correction is explicitly outside #064; the proposed reusable-image
follow-up is documented in IR-240, but cannot enter the numbered task index
until GitHub initializes the required #001–#097 task sequence.

The unentitled validation result and host details are in [vm.md](../../02-design/vm.md)
§3 and §17. The implementation judgment for the opt-in T1 probe is in
[implementation-review.md](../implementation-review.md) IR-242. #003's design
and recorded gate evidence are in [M00](M00-repository-and-vm-foundation.md)
and [vm.md](../../02-design/vm.md) §§9, 17.

**Latest broad SwiftPM checks:** complete default and `--traits EmbeddedRuntime`
test suites passed after fixing the root-help golden mismatch. Default and
embedded-runtime help outputs now have separate golden coverage.
