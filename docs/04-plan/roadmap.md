# Roadmap

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [issues/README.md](issues/README.md), [risks.md](risks.md), [open-questions.md](open-questions.md), [test-strategy.md](test-strategy.md), [traceability.md](traceability.md), [../00-product/requirements.md](../00-product/requirements.md) |

This roadmap sets the order of work, the gates that prove each technical step, and what each version must contain. It has no calendar dates. Progress is measured by gates and Definitions of Done, not by time.

---

## 1. Development order

### 1.1 Principles

- **Prove the hardest thing first.** Android on Virtualization.framework (G2) and GPU rendering to Metal (G3) are the largest technical risks. Nothing that depends on them (daemon, store, wrappers) is started before they pass.
- **No wrapper before the runtime works.** Wrappers come in M7, after multi-window (G5), the daemon (G6), and updates (G7).
- **One risk per task.** A task about Android boot does not also touch the wrapper UI, the updater, Google Play, or Vulkan ([../00-product/scope.md](../00-product/scope.md) §5).
- **Integrate before inventing.** Prefer, in order: existing Android behavior, documented virtio behavior, Cuttlefish behavior, RiftVM behavior, minimal adapter code, and a new mechanism only as the last resort.

### 1.2 Milestones and versions

| Milestone | Name | Version | Tasks | Gates |
|---|---|---|---|---|
| M0 | Repository and VM foundation | v0.1 | #001–#007, #061–#063 | G1 |
| M1 | Android bring-up | v0.1 | #008–#017, #064, #065, #095 | G2 |
| M2 | Graphics | v0.1 | #018–#023 | G3 |
| M3 | Input and basic runtime | v0.1 (#033, #072, #024–#027, #067), v0.2 (#028–#030) | #024–#030, #033, #067, #072 | G4, G5 |
| M4 | Daemon and guest protocol | v0.2 | #031, #032, #034, #053, #066, #068–#071 | G6 |
| M5 | Custom Android runtime image | v0.3 | #035, #036 | |
| M6 | Update system | v0.3 | #037–#043, #050, #073, #074 | G7 |
| M7 | Mac app wrappers | v0.4 | #044–#049, #055, #056, #075–#079, #089 | G8, G9 |
| M8 | Real update sources | v0.5 | #051, #052 | |
| M9 | macOS integration | v0.5 | #054, #080–#082, #085, #086 | |
| M10 | Runtime maintenance | v0.5 | #057, #058, #087 | |
| M11 | Diagnostics | v0.5 | #059, #060 | |
| M12 | v1.0 release | v1.0 | #083, #084, #088, #090–#094 | |
| — | Post-v1 tracks | — | #096 (Vulkan, Phase 21), #097 (Google Play authority, Phase 22) | |

The full dependency list is in [issues/README.md](issues/README.md) §3. The tasks inside each milestone file are in working order.

### 1.3 Critical path

The longest dependency chain runs through Android bring-up, graphics, multi-window, the daemon, and then two branches that meet at G9:

```text
#001 → #002 → #003 (G1) → #005 ─────────────────────┐
#001 → #008 → #009 → #010 ──────────────────────────┴→ #011 → #012 → #013 → #095 → #014 (G2)
#014 + #019 → #021 → #022 → #023 (G3) (#019 needs #018, #003, #063; #022 needs #020)
#023 + #072 → #024 → #025 → #026 (G4) → #027 → #028 → #029 → #030 (G5) → #031 (G6)

wrapper branch: #031 → #032 → #068 → #044 → #045 → #046 → #047 (G8) → #048 ─┐
update branch: #027 + #033 → #034 → #035 → #036 → #037 → #038 → #039 → #040 (G7)
#038 → #041 → #042 → #043 ──┴→ #049 (G9)
```

- The update branch contains the AOSP product build (#035), which needs a Linux builder and long builds (R-14). Start the builder setup ([../05-development/environment-setup.md](../05-development/environment-setup.md) §5) during M3 so that #035 can start as soon as #034 is done.
- #048 also needs #037, so the wrapper branch waits for the start of the update branch.

### 1.4 Parallel tracks

Tasks that do not depend on each other can be worked on at the same time, by different people or agents. The useful parallel starts are:

| As soon as | These can start |
|---|---|
| #001 is done | #002, #008, #018, #061, #062 |
| #003 is done (G1) | #004, #005, #006, #007, #063 |
| #007 is done | #033 |
| #008 is done | #009, #064 |
| #018 is done | #020 (and #019 once #003 and #063 are done) |
| #014 is done (G2) | #015, #021, #065 |
| #015 and #033 are done | #072 |
| #026 is done (G4) | #027, #067 |
| #031 is done (G6 headless form) | #032, #069; then #068 and #070 |
| #034 is done | #035, #053, #071 (with #068) |
| #035 is done | #036, #082 (and #054 and #081 once #047 is done, #085 once #069 is done) |
| #036 is done | #037, #073 |
| #045 is done | #046, #055 (with #036) |
| #048 is done | #075 (with #046), #076, #077 |

#002 can start with #061, but it is done only after #061 step 4 (`APKRunError`) is merged, because its error types conform to it ([issues/M00-repository-and-vm-foundation.md](issues/M00-repository-and-vm-foundation.md), task order).

Within M9–M12, most tasks are independent once their dependencies from earlier milestones are done. Rules for splitting work between agents are in [../05-development/workflow.md](../05-development/workflow.md).

---

## 2. Gates

A gate is a checkpoint that proves one technical step end to end. Each gate is closed by one task, and it passes only when every condition below holds on the reference Mac ([open-questions.md](open-questions.md) OQ-02) with a clean build from `main`. Each condition is checked by an acceptance test in `Tests/AcceptanceTests/` ([test-strategy.md](test-strategy.md)) or, where noted, by a recorded manual check. The core architecture is not validated before G3, and the product concept is not validated before G9.

| Gate | Name | Closed by | Pass conditions |
|---|---|---|---|
| G1 | ARM64 Linux boots | #003 | 1. The test Linux guest ([../02-design/vm.md](../02-design/vm.md) §12) reaches userspace through `VZLinuxBootLoader`. 2. The serial log on `hvc0` contains the boot marker `APKRUN-TEST: boot ok`. 3. The VM state machine goes `stopped → starting → running → stopping → stopped`, and a failed start ends in `failed` with a typed error. 4. Ten boots in a row pass. |
| G2 | Android reaches boot_completed | #014 | 1. The stock Cuttlefish arm64 image boots on VZ with direct kernel boot and reaches `sys.boot_completed=1`. 2. `BOOT_COMPLETED` is logged as a boot phase marker. 3. Android stays up for 10 minutes with no `system_server` restart, no watchdog, and no HAL crash loop in logcat. 4. Five cold boots in a row pass. |
| G3 | SurfaceFlinger renders through virtio-gpu to Metal | #023 | 1. The Android display is visible in a macOS window. 2. Android uses VirGL (Mesa `virgl`), not a software renderer (`dumpsys SurfaceFlinger` shows the GLES renderer string). 3. The readback counters (`hostReadbacks`, `cpuPixelCopies`) stay at 0 during a 60 s HelloGL run (FR-GFX-05, NFR-PERF-05). 4. HelloGL averages at least 55 fps (NFR-PERF-04), and its alternating-color test shows no tearing ([../02-design/graphics.md](../02-design/graphics.md) §12). 5. HelloGL runs for 10 minutes without a renderer crash. 6. The resize behavior (fixed size at this stage) is documented in the design. |
| G4 | Hello APK renders and accepts input in a native Mac window | #026 | 1. `apkrun dev launch` with HelloText (the embedded runtime of a development build, [../02-design/cli.md](../02-design/cli.md) §5) opens a normal Mac window showing HelloText. 2. Clicks on the HelloText button are registered (HelloText logs `APKRUN-FIXTURE: click <n>`), and typed text reaches its text field exactly. 3. Esc goes back. 4. Input goes through the Guest Agent, not a shell command per event (FR-IN-06). |
| G5 | Two APKs run in two Mac windows | #030 | 1. HelloText and HelloCompose run at the same time in two independent windows, each on its own Android display ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §12). 2. Input in one window reaches only its app. 3. Closing one window leaves the other app running and interactive. |
| G6 | Runtime remains warm under apkrund | #031, completed by #032 and #068 (staged, see below) | 1. The VM runs in `apkrund`, started by launchd. 2. Quitting APKRun.app while an app window is open does not stop the runtime or the app. 3. A warm launch does not boot the VM (the boot phase markers do not appear). 4. Killing `apkrund` gets it restarted by launchd, and clients reconnect (NFR-REL-02). |
| G7 | APK v1 automatically upgrades to v2 | #040 | 1. On the custom image, with HelloUpdate V1 installed and the LocalProvider serving HelloUpdate V2, APKRun detects and stages V2 in the background. 2. While V1 is in use (its window is open, or it runs with `keepRunning`), V2 is not installed. 3. After the app is closed, V2 is installed without user action, and its data is kept (V2 logs `data HELLO`). 4. The update history records each step. |
| G8 | APK can be wrapped as.app | #047 | 1. `apkrun wrap` with HelloText produces `HelloText.app` with the bundle ID `io.apkrun.android.io.apkrun.fixture.hellotext`, ad-hoc signed, which passes `codesign --verify --strict`. 2. Double-clicking it in Finder shows an interactive HelloText window. 3. No terminal interaction is needed, and launching from the Dock works with the runtime stopped and with it warm. |
| G9 | Wrapper unchanged while the APK updates automatically | #049 | 1. `HelloUpdate.app` runs HelloUpdate V1. 2. V2 is detected in the background, installed after `HelloUpdate.app` quits, and `HelloUpdate.app` then runs V2. 3. App data is kept. 4. The wrapper bundle is byte-for-byte unchanged (same file hashes and the same cdhash), and it was not re-signed. |

**Staged G6.** Two G6 conditions need tasks after #031: a warm launch needs `launch` over XPC (#032), and "while an app window is open" needs the launcher window (#068). #031 builds the check with conditions 1, 2 (with HelloText on display 0 and no window), and 4. #032 adds condition 3. G6 passes when the full check passes in #068 ([issues/M04-daemon-and-guest-protocol.md](issues/M04-daemon-and-guest-protocol.md) #031 Notes). Tasks that depend on G6 wait for #068.

When a gate does not pass:

1. Stop starting new tasks that depend on the gate. Tasks in parallel tracks may continue.
2. Record the failure in the design document's verification log and in the matching risk in [risks.md](risks.md) (status `realized` if a fallback is taken).
3. If the fix changes the design, write an ADR ([../01-architecture/decisions/README.md](../01-architecture/decisions/README.md)) and update the design documents and the issue files in the same pull request.

---

## 3. Versions, Definitions of Done, and v1.0 release criteria

A version is done when every item of its Definition of Done holds, every task listed for it is done, and every `Must` requirement assigned to it in [../00-product/requirements.md](../00-product/requirements.md) is covered by passing tests ([traceability.md](traceability.md) §2). The Definition of Done states the release outcomes; the tasks show where each one is delivered.

### 3.1 v0.1: Android app in a Mac window (M0–M2, part of M3)

| item | Delivered by |
|---|---|
| Android ARM64 boot | #012–#014 (G2) |
| VirGL accelerated rendering | #019–#023 (G3) |
| Hello APK visible | #026 (G4) |
| Mouse | #024 |
| Keyboard | #025 |
| Native Mac window | #026, #067 (Retina and density) |
| CLI launch | #017, #026, #027 (embedded runtime: `apkrun install` and `apkrun dev launch` through RuntimeCore; `apkrun launch` over XPC comes with #032) |

Also required by this plan: the diagnostics foundation and error catalog (#061), CI with module checks (#062), the reference boot capture (#064), the runtime image bundle (#065), and the Guest Agent bootstrap (#033, #072).

### 3.2 v0.2: several apps and a resident runtime (rest of M3, M4)

| item | Delivered by |
|---|---|
| Multiple APKs | #028–#030 (G5) |
| Multiple native windows | #029, #030, #068 (wrapper-owned windows over XPC) |
| apkrund | #031, #032, #068 (G6) |
| Warm launch | #031, measured by #070 against NFR-PERF-01 |
| Guest Agent | #034 |
| Basic macOS clipboard | #053 (plain text) |

Also: first-run provisioning (#066), idle pause and host sleep/wake (#069), the performance harness (#070), and the APKRun IME for Japanese text (#071).

### 3.3 v0.3: the store and automatic updates (M5, M6)

| item | Delivered by |
|---|---|
| APK Store | #027, #036, #073 |
| LocalProvider | #037 |
| DirectProvider | #050 |
| Automatic updates | #038, #074 |
| Update ownership | #039 |
| Gentle updates | #040 (G7) |
| Signature verification | #041 |
| Split APK support | #042 |
| Rollback | #043 |

Also: the APKRun AOSP product (#035), which from here on is the image the product is tested on.

### 3.4 v0.4: Android app as a Mac app, first public demo (M7)

| item | Delivered by |
|---|---|
| APK → Mac app | #044–#047 (G8) |
| `.app` generated | #046, #075 |
| Dock launch, Spotlight launch | #056 |
| Icon extraction | #055 |
| Wrapper unchanged during APK updates | #048, #049 (G9) |
| Automatic APK update | #049 |
| Update settings per wrapper | #079 |

Also: wrapper lifecycle and uninstall choices (#076), the home and store UI (#077), the add flow (#078), and portable wrappers (#089).

**First public demo.** v0.4 is the first version shown outside the project. The demo is the flow on a clean Mac with the APKRun image bundle of #035, picked as a local bundle directory in the onboarding sheet ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9.3): install APKRun, add HelloUpdate V1 from a file, generate `HelloUpdate.app`, launch it from the Dock and from Spotlight, publish HelloUpdate V2 on a Direct or Local provider, quit `HelloUpdate.app`, and show that the next launch runs V2 from the same, unchanged wrapper. Nothing in the demo may need a terminal. The image feed arrives only with #087 (M10), so the demo does not download an image; C10-10 repeats the demo with the feed on the v1.0 candidate.

### 3.5 v0.5: real sources, desktop integration, maintenance (M8–M11)

| item | Delivered by |
|---|---|
| GitHubProvider | #052 |
| F-DroidProvider | #051 |
| Notifications | #054 |
| Clipboard | #080 (images and HTML, on top of #053) |
| File integration | #082 |
| Runtime updater | #057 |
| Guest image updater | #058, #087 |

Also: links (#081), locale and time (#085), the menu bar (#086), `apkrun doctor` (#059), and the diagnostics bundle (#060).

### 3.6 v1.0: release (M12)

  lists the v1.0 candidates. They are all in the plan:

| item | Delivered by |
|---|---|
| Stable Mac app wrappers | M7, hardened by #088 and #091 |
| Stable application auto update | M6, M8 |
| Reliable rollback | #043, verified by the T3 update corpus |
| Runtime update | #057 |
| Android image update | #058, #087 |
| Notification bridge | #054 |
| Clipboard | #053, #080 |
| File picker | #082 |
| Audio | #083 |
| Microphone | #084 |
| Compatibility database | #090 |
| Installer UI | #066, #077, #078 |

**v1.0 release criteria.** #094 checks each one and records the evidence in its pull request.

1. **Requirements.** Every `Must` requirement for v1.0 or earlier has its tasks done and its tests passing ([traceability.md](traceability.md) §2). `Should` requirements that are not done are listed in the release notes.
2. **Performance.** The NFR targets ([../00-product/requirements.md](../00-product/requirements.md) §2) are met on the reference Mac by the perf harness (#070), or revised by an ADR with the measured numbers.
3. **Reliability.** The T3 release smoke matrix passes ([test-strategy.md](test-strategy.md)): install, launch, update, rollback, wrapper generation, APKRun update N → N+1, and image update A → B with userdata kept (NFR-CMP-03). Wrappers made by the oldest supported wrapper format still launch (NFR-CMP-02).
4. **Compatibility.** Every fixture app in `Tests/Fixtures/` (HelloText, HelloGL, HelloCompose, HelloWebView, HelloSplit, HelloUpdate, HelloAudio, HelloClipboard, HelloNotification, HelloLinks, HelloFiles, and the rest listed in [test-strategy.md](test-strategy.md)) is `nativeLike`. The corpus results are in the compatibility database (#090), and the level definitions of [../00-product/scope.md](../00-product/scope.md) §4 are shown to users.
5. **Security.** #091 is done: XPC client validation and per-wrapper authorization tests pass (NFR-SEC-07), fuzzing of the guest protocol and the parsers ran with no open crash, and every review item of [../01-architecture/security-model.md](../01-architecture/security-model.md) §9 is closed or has a follow-up task that is not High impact.
6. **Distribution.** APKRun.app is Developer ID signed, notarized, and stapled; the Sparkle appcast and the image feed are signed and served from the production host (OQ-01); distribution wrappers work (#088).
7. **Legal.** The #093 checklist is complete: notices for the app and the image, source offers for GPL/LGPL components, and no component with an unresolved license ([../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md)).
8. **Localization and accessibility.** English and Japanese are complete, and APKRun.app passes the VoiceOver checks (#092, NFR-L10N-01, NFR-L10N-02).
9. **Diagnostics.** `apkrun doctor` tells apart every failure class of FR-OPS-01, and a diagnostics bundle from a boot failure is secret-free (FR-OPS-02).
10. **Risks and questions.** No `open` High-impact risk remains without an accepted fallback ([risks.md](risks.md)), and no Decision question with a deadline at or before v1.0 is open ([open-questions.md](open-questions.md)).

---

## 4. Milestone reviews

At the end of every milestone, before work on the next milestone's dependent tasks starts:

1. **Tasks.** Every task of the milestone meets its acceptance criteria, or has been moved to a later milestone with the reason recorded in the milestone file.
2. **Gates.** The milestone's gates pass (§2).
3. **Tests.** The T0 and T1 suites pass on `main`; the T2 suite passes on the reference Mac; new acceptance tests are in the nightly T3 run ([test-strategy.md](test-strategy.md)).
4. **Performance.** From M4 on, the perf harness numbers are recorded for the milestone, and regressions against the previous milestone are explained ([../02-design/diagnostics.md](../02-design/diagnostics.md) §9.4).
5. **Risks.** Every risk whose settling task is in the milestone has a result, and its status is updated ([risks.md](risks.md) §1).
6. **Questions.** Every Decision with a deadline in the next milestone is settled or explicitly carried over ([open-questions.md](open-questions.md) §1).
7. **Documents.** The design documents describe what was built. Differences found during the milestone are fixed in the documents, and verification logs are filled in.
8. **Version.** When the milestone completes a version, its Definition of Done (§3) is checked and the version is tagged.

---

## 5. After v1.0

- **Vulkan (#096, Phase 21).** Evaluate Venus or gfxstream on Metal through MoltenVK or a native path ([../02-design/graphics.md](../02-design/graphics.md) §10). It is independent of the GLES path and may not delay any v1.x release.
- **Google Play authority (#097, Phase 22).** An optional, isolated track for users who bring their own Google Play. Never Play Integrity circumvention ([../00-product/scope.md](../00-product/scope.md) §3).
- **Deferred items** in [open-questions.md](open-questions.md) §5 become tasks (#098 and up) only after a review.
- Standalone Mode (the runtime inside the `.app`) stays a non-goal until a new ADR says otherwise.
