# Roadmap

The order of work, the gates that prove each technical step, and what each version contains. There are no calendar dates: progress is measured by gates and by closed tasks.

---

## 1. Development order

### 1.1 Principles

- **Prove the hardest thing first.** Android on Virtualization.framework (G2) and GPU rendering to Metal (G3) were the largest risks. Both passed.
- **No wrapper before the runtime works.** Wrappers start after the resident runtime (G6).
- **One risk per task.** A task about Android boot does not also touch the wrapper UI, the updater, Google Play, or Vulkan ([../00-product/scope.md](../00-product/scope.md) §5).
- **Integrate before inventing.** Prefer existing Android behavior, then documented virtio behavior, then Cuttlefish behavior, then RiftVM behavior, then minimal adapter code. A new mechanism is the last resort.

### 1.2 Milestones and versions

| Milestone | Name | Version | Tasks | Gates |
|---|---|---|---|---|
| M0 | Repository and VM foundation | v0.1 | #2–#8, #62–#64 | G1 |
| M1 | Android bring-up | v0.1 | #9–#18, #65, #66, #96 | G2 |
| M2 | Graphics | v0.1 | #19–#24, #99, #105 | G3 |
| M3 | Input and basic runtime | v0.1, v0.2 | #25–#31, #34, #68, #73, #100, #101–#103 | G4, G5 |
| M4 | Daemon and guest protocol | v0.2 | #32, #33, #35, #54, #67, #69–#72 | G6 |
| M5 | Custom Android runtime image | v0.3 | #36, #37 | |
| M6 | Update system | v0.3 | #38–#44, #51, #74, #75 | G7 |
| M7 | Mac app wrappers | v0.4 | #45–#50, #56, #57, #76–#80, #90 | G8, G9 |
| M8 | Real update sources | v0.5 | #52, #53 | |
| M9 | macOS integration | v0.5 | #55, #81–#83, #86, #87 | |
| M10 | Runtime maintenance | v0.5 | #58, #59, #88 | |
| M11 | Diagnostics | v0.5 | #60, #61 | |
| M12 | v1.0 release | v1.0 | #84, #85, #89, #91–#95 | |
| — | Post-v1 tracks | — | #97 (Vulkan), #98 (Google Play authority) | |

A milestone groups tasks by subject. The order of work is §1.3, not the milestone number.

### 1.3 Working order

Work in this order. Inside each step, the task index ([issues/README.md](issues/README.md) §3) lists the tasks in order, with their dependencies. `scripts/dev/next-task.py` prints the tasks that can start now.

1. **Verify M3 on a real Mac.** #27 (G4), #28, #68, #29, #30, #31 (G5) are implemented and wait for their T2 and gate runs. The follow-ups #101, #102, #103, #105, and #100 can run alongside.
2. **Resident runtime.** #32 (verify), #33, #69 (G6).
3. **First Mac app (G8).** #45, #46, #47, #48. They need neither the custom image nor the update system, so they come before M5 and M6. G8 is the first time an Android app runs as a Mac app.
4. **Rest of M4.** #35, #67, #70, #71, #54, #72.
5. **Custom image (M5).** #36, #37. #36 composes the custom image on the Mac from the stock build ([ADR-0019](../01-architecture/decisions/0019-composed-development-image.md)). Only the release image (#120, M12) needs the Linux builder ([../05-development/environment-setup.md](../05-development/environment-setup.md) §5; R-14).
6. **Updates (M6).** #74, #38, #39, #40, #41 (G7), #42, #43, #44, #51, #75.
7. **Rest of M7.** #56, #57, #49, #50 (G9), #76, #77, #78, #79, #80, #90.
8. **M8 to M11**, then **M12**.

### 1.4 Parallel work

Tasks whose dependencies are met can be worked on at the same time, by different people or agents. A dependency is met when its issue is closed or labeled `needs-verification` ([../05-development/workflow.md](../05-development/workflow.md) §2.2). Two parallel tasks must not edit the same files; [../05-development/workflow.md](../05-development/workflow.md) §11 has the rules.

---

## 2. Gates

A gate proves one technical step end to end. Each gate is closed by one task. It passes only when every condition holds on a real Apple silicon Mac with a clean build from `main`. Each condition is checked by an acceptance test in `Tests/AcceptanceTests/` ([test-strategy.md](test-strategy.md) §5) or, where noted, by a recorded manual check.

**Do not declare the core architecture validated before G3, or the product concept validated before G9.**

| Gate | Name | Closed by | Pass conditions | Result |
|---|---|---|---|---|
| G1 | ARM64 Linux boots | #4 | 1. The test Linux guest ([../02-design/vm.md](../02-design/vm.md) §12) reaches userspace through `VZLinuxBootLoader`. 2. The serial log on `hvc0` contains `APKRUN-TEST: boot ok`. 3. The VM state machine goes `stopped → starting → running → stopping → stopped`, and a failed start ends in `failed` with a typed error. 4. Ten boots in a row pass. | Passed 2026-10-08 (`bba2959`) |
| G2 | Android reaches boot_completed | #15 | 1. The stock Cuttlefish arm64 image boots on VZ with direct kernel boot and reaches `sys.boot_completed=1`. 2. `BOOT_COMPLETED` is logged as a boot phase marker. 3. Android stays up for 10 minutes with no `system_server` restart, no watchdog, and no HAL crash loop in logcat. 4. Five cold boots in a row pass. | Passed 2026-10-10 (`4961787`): five cold boots, 600 s each |
| G3 | SurfaceFlinger renders through virtio-gpu to Metal | #24 | 1. The Android display is visible in a macOS window. 2. Android uses VirGL (Mesa `virgl`), not a software renderer (`dumpsys SurfaceFlinger` shows the GLES renderer string). 3. The readback counters (`hostReadbacks`, `cpuPixelCopies`) stay at 0 during a 60 s HelloGL run (FR-GFX-05, NFR-PERF-05). 4. HelloGL averages at least 55 fps (NFR-PERF-04), and its alternating-color test shows no tearing ([../02-design/graphics.md](../02-design/graphics.md) §7). 5. HelloGL runs for 10 minutes without a renderer crash. 6. The resize behavior (fixed size at this stage) is documented in the design. | Passed 2026-10-16 (`7241003`): 59.99 fps, both counters 0 |
| G4 | Hello APK renders and accepts input in a native Mac window | #27 | 1. `apkrun dev launch` with HelloText ([../02-design/cli.md](../02-design/cli.md) §5) opens a normal Mac window showing HelloText. 2. Clicks on the HelloText button are registered (HelloText logs `APKRUN-FIXTURE: click <n>`), and typed text reaches its text field exactly. 3. Esc goes back. 4. Input goes through the Guest Agent, not a shell command per event (FR-IN-06). | |
| G5 | Two APKs run in two Mac windows | #31 | 1. HelloText and HelloCompose run at the same time in two independent windows, each on its own Android display ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3). 2. Input in one window reaches only its app. 3. Closing one window leaves the other app running and interactive. | |
| G6 | Runtime remains warm under apkrund | #32, completed by #33 and #69 | 1. The VM runs in `apkrund`, started by launchd. 2. Quitting APKRun.app while an app window is open does not stop the runtime or the app. 3. A warm launch does not boot the VM (the boot phase markers do not appear). 4. Killing `apkrund` gets it restarted by launchd, and clients reconnect (NFR-REL-02). | |
| G7 | APK v1 automatically upgrades to v2 | #41 | 1. On the custom image, with HelloUpdate V1 installed and the LocalProvider serving HelloUpdate V2, APKRun detects and stages V2 in the background. 2. While V1 is in use (its window is open, or it runs with `keepRunning`), V2 is not installed. 3. After the app is closed, V2 is installed without user action, and its data is kept (V2 logs `data HELLO`). 4. The update history records each step. | |
| G8 | APK can be wrapped as .app | #48 | 1. `apkrun wrap` with HelloText produces `HelloText.app` with the bundle ID `io.apkrun.android.io.apkrun.fixture.hellotext`, ad-hoc signed, which passes `codesign --verify --strict`. 2. Double-clicking it in Finder shows an interactive HelloText window. 3. No terminal interaction is needed, and launching from the Dock works with the runtime stopped and with it warm. | |
| G9 | Wrapper unchanged while the APK updates automatically | #50 | 1. `HelloUpdate.app` runs HelloUpdate V1. 2. V2 is detected in the background, installed after `HelloUpdate.app` quits, and `HelloUpdate.app` then runs V2. 3. App data is kept. 4. The wrapper bundle is byte-for-byte unchanged (same file hashes and the same cdhash), and it was not re-signed. | |

**Staged G6.** #32 checks conditions 1, 2 (HelloText on display 0, no window), and 4. #33 adds condition 3. "While an app window is open" needs the launcher window of #69, so G6 passes when the full check passes in #69. Tasks that depend on G6 wait for #69.

The result column records the commit of the passing run. Evidence (logs, recordings) goes into the pull request or commit message of the closing task, not into this repository.

When a gate does not pass:

1. Do not start new tasks that depend on the gate. Tasks in other tracks may continue.
2. Update the matching risk in [risks.md](risks.md) (status `realized` if a fallback is taken).
3. If the fix changes the design, write an ADR first, then update the design documents and the task entries.

---

## 3. Versions

A version is done when every task listed for it is closed, its Definition of Done holds, and every `Must` requirement for that version in [../00-product/requirements.md](../00-product/requirements.md) has passing tests. A task labeled `needs-verification` does not count as done for a version.

### 3.1 v0.1: Android app in a Mac window

| Definition of Done item | Delivered by |
|---|---|
| Android ARM64 boot | #13–#15 (G2) |
| VirGL accelerated rendering | #20–#24 (G3) |
| Hello APK visible, mouse, keyboard | #25, #26, #27 (G4) |
| Native Mac window with Retina and density | #27, #68 |
| CLI launch | #18, #27, #28 |

Also: diagnostics foundation (#62), CI (#63), runtime image bundle (#66), Guest Agent bootstrap (#34, #73).

### 3.2 v0.2: several apps and a resident runtime

| Definition of Done item | Delivered by |
|---|---|
| Multiple APKs in multiple windows | #29–#31 (G5), #69 |
| apkrund and warm launch | #32, #33, #69 (G6), measured by #71 against NFR-PERF-01 |
| Guest Agent | #35 |
| Plain-text clipboard | #54 |

Also: first-run provisioning (#67), idle pause and host sleep/wake (#70), performance harness (#71), APKRun IME for Japanese text (#72).

### 3.3 v0.3: the store and automatic updates

| Definition of Done item | Delivered by |
|---|---|
| APK store | #28, #37, #74 |
| Local and Direct providers | #38, #51 |
| Automatic updates, update ownership | #39, #40, #75 |
| Gentle updates | #41 (G7) |
| Signature verification, split APKs, rollback | #42, #43, #44 |

From v0.3 on, the composed custom image (#36) is the image the product is tested on. From v1.0, the release image (#120) is too.

### 3.4 v0.4: Android app as a Mac app, first public demo

| Definition of Done item | Delivered by |
|---|---|
| APK → Mac app | #45–#48 (G8), #76 |
| Dock and Spotlight launch, icons | #56, #57 |
| Wrapper unchanged during APK updates | #49, #50 (G9) |
| Update settings per wrapper | #80 |

Also: wrapper lifecycle and uninstall choices (#77), home and store UI (#78), add flow (#79), portable wrappers (#90).

**First public demo.** On a clean Mac, with the image bundle of #36 picked as a local bundle in onboarding ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9): install APKRun, add HelloUpdate V1 from a file, generate `HelloUpdate.app`, launch it from the Dock and from Spotlight, publish V2 on a Local or Direct provider, quit the app, and show that the next launch runs V2 from the same, unchanged wrapper. Nothing in the demo needs a terminal.

### 3.5 v0.5: real sources, desktop integration, maintenance

| Definition of Done item | Delivered by |
|---|---|
| F-Droid and GitHub providers | #52, #53 |
| Notifications, rich clipboard, files | #55, #81, #83 |
| Runtime updater, image updater | #58, #59, #88 |

Also: links (#82), locale and time (#86), menu bar (#87), `apkrun doctor` (#60), diagnostics bundle (#61).

### 3.6 v1.0: release

| Definition of Done item | Delivered by |
|---|---|
| Stable wrappers | M7, hardened by #89 and #92 |
| Stable automatic updates and reliable rollback | M6, M8, #44 |
| Runtime and image updates | #58, #59, #88 |
| Notifications, clipboard, files | #54, #55, #81, #83 |
| Audio and microphone | #84, #85 |
| Compatibility database | #91 |
| Installer UI | #67, #78, #79 |

**v1.0 release criteria.** #95 checks each one.

1. **Requirements.** Every `Must` requirement for v1.0 or earlier has its tasks closed and its tests passing. Unfinished `Should` requirements are listed in the release notes.
2. **Performance.** The NFR targets ([../00-product/requirements.md](../00-product/requirements.md) §2) are met on the reference Mac by the harness (#71), or revised by an ADR with measured numbers.
3. **Reliability.** The T3 release smoke matrix passes ([test-strategy.md](test-strategy.md) §9.2): install, launch, update, rollback, wrapper generation, APKRun update N → N+1, and image update A → B with userdata kept (NFR-CMP-03). Wrappers of the oldest supported format still launch (NFR-CMP-02).
4. **Compatibility.** Every fixture app ([test-strategy.md](test-strategy.md) §4.2) is `nativeLike`, and the corpus results are in the compatibility database (#91).
5. **Security.** #92 is done: XPC client validation and per-wrapper authorization tests pass (NFR-SEC-07), fuzzing found no open crash, and every review item of [../01-architecture/security-model.md](../01-architecture/security-model.md) §9 is closed or has a follow-up task that is not High impact.
6. **Distribution.** APKRun.app is Developer ID signed, notarized, and stapled. The Sparkle appcast and the image feed are signed and served from the production host (OQ-01). Distribution wrappers work (#89).
7. **Legal.** The #94 checklist is complete ([../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md)).
8. **Localization and accessibility.** English and Japanese are complete, and APKRun.app passes the VoiceOver checks (#93, NFR-L10N-01, NFR-L10N-02).
9. **Diagnostics.** `apkrun doctor` tells apart every failure class of FR-OPS-01, and a diagnostics bundle from a boot failure is secret-free (FR-OPS-02).
10. **Risks and questions.** No open High-impact risk remains without an accepted fallback ([risks.md](risks.md)), and no Decision question with a deadline at or before v1.0 is open ([open-questions.md](open-questions.md)).

---

## 4. Milestone reviews

When the last task of a milestone closes:

1. Its gates pass (§2), and their results are in the table.
2. The T0 and T1 suites pass on `main`, and the T2 suites of the milestone pass on a real Mac.
3. The manual checklist of the version passes, if the milestone completes a version ([test-strategy.md](test-strategy.md) §8).
4. Risks settled by the milestone's tasks have their outcome in [risks.md](risks.md), and Decision questions due in the next milestone are settled or carried over ([open-questions.md](open-questions.md)).
5. The design documents describe what was built.

---

## 5. After v1.0

- **Vulkan (#97).** Evaluate Venus or gfxstream on Metal through MoltenVK or a native path ([../02-design/graphics.md](../02-design/graphics.md) §10). It is independent of the GLES path and may not delay any v1.x release.
- **Google Play authority (#98).** An optional, isolated track for users who bring their own Google Play. Never Play Integrity circumvention ([../00-product/scope.md](../00-product/scope.md) §3).
- **Deferred items** in [open-questions.md](open-questions.md) become tasks only after a review.
- Standalone mode (the runtime inside the `.app`) stays a non-goal until an ADR says otherwise.
