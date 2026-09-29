# Open Questions

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [risks.md](risks.md), [roadmap.md](roadmap.md), [issues/README.md](issues/README.md), [traceability.md](traceability.md) |

This file lists everything that is not decided yet. Each question has a working default, so implementation never waits for an answer: build to the default, and change it only when the question is settled.

A question that could make a design fail is a risk, not a question. It is in [risks.md](risks.md), and this file links to it instead of repeating it.

---

## 1. Kinds and rules

| Kind | Meaning | Who settles it |
|---|---|---|
| **Decision** | A choice for the project owner. No test can answer it. | The project owner, before the deadline task starts |
| **Verification** | A fact about macOS, Android, or a library that a task finds out. The design already covers both outcomes. | The task named in "Settled by" |
| **Deferred** | A feature idea or improvement kept out of v1 on purpose. It is recorded so it is not lost, and it is not planned. | Reopened after v1.0 (or in v1.x) through a new task |

Rules:

- IDs are permanent. New questions take the next free number (OQ-42 and up).
- **Status:** `open`, `settled` (the answer and the date are recorded in the entry, and the design documents are updated in the same pull request), `deferred`.
- When a question is settled, the design documents that name the default are updated in the same pull request. The entry keeps the question, the answer, and the task or date.
- A Decision that is still open when its deadline task starts blocks that task. Raise it at the milestone review ([roadmap.md](roadmap.md) §4).
- Verification results also go into the verification log of the design document that asked the question.

---

## 2. Summary

| ID | Question | Area | Kind | Settled by / deadline | Working default | Status |
|---|---|---|---|---|---|---|
| OQ-01 | Do we own the `apkrun.io` domain, and where are the appcast, image feed, archives, and downloads page hosted? | Project | Decision | before #045 (namespace), before #057 and #087 (hosting) | keep the `io.apkrun` namespace; `<updates host>` placeholder | open |
| OQ-02 | Which Mac is the reference for the NFR numbers? | Performance | Decision | before #070 | the lowest-tier lab Mac (M1, 16 GB) | open |
| OQ-03 | Should diagnostics bundles include package IDs? | Diagnostics | Decision | revisit on user feedback | included, and the sheet says so | open |
| OQ-04 | How does `log show` behave for standard (non-admin) users on macOS 27? | Diagnostics | Verification | #061 | file mirrors cover the gap either way | open |
| OQ-05 | Does `logcat -v uid` print the UID on the Android 17 image? | Diagnostics | Verification | #060 | fall back to a PID → UID map | open |
| OQ-06 | Can we identify the Virtualization.framework XPC process that hosts our VM? | Diagnostics | Verification | #070 | report the VM footprint as unavailable | open |
| OQ-07 | Is `gpuUtilization` from IOKit accelerator statistics usable? | Diagnostics | Verification | #070 | best effort, unavailable when missing | open |
| OQ-08 | Should APKRun.app offer an Android app catalog in v1? | Host UI | Decision | before #077 | no | open |
| OQ-09 | Should "Always on top" also apply in full screen? | Host UI | Decision | before #079 | no effect in full screen | open |
| OQ-10 | Should the menu bar list apps kept running without a window? | Host UI | Decision | before #086 | sessions only | open |
| OQ-11 | Does RollbackManager work with `TEST_MANAGE_ROLLBACKS` on `user` builds? | Package store | Verification | #043 (R-18) | confirmed data-loss rollback path | open |
| OQ-12 | Does Android grant update ownership when an owner-less package is updated with `setRequestUpdateOwnership(true)`? | Package store | Verification | #039 (R-18) | host-side ownership, with a `store.ownership` health warning | open |
| OQ-13 | Should `.xapk` OBB expansion files be supported? | Package store | Deferred | v1.x | refused with `expansionFilesNotSupported` | deferred |
| OQ-14 | Which density split should be chosen from an `.apks` set? | Package store | Verification | #042 | the baseline rule ([package-store.md](../02-design/package-store.md) §4.4) | open |
| OQ-15 | How often does the host verifier reject what Android would accept? | Package store | Verification | field data after v0.4 (`verifier.disagreement`) | host verifier stays strict | open |
| OQ-16 | Should rollback restore app data (`ROLLBACK_DATA_POLICY_RESTORE`)? | Package store | Deferred | post-v1 | code-only rollback | deferred |
| OQ-17 | How does `GENTLE_UPDATE` behave while the app runs a foreground service? | Update system | Verification | #040 | trust `GENTLE_UPDATE` with `setAppNotForegroundRequired()` | open |
| OQ-18 | F-Droid index details and main repository fingerprint; GitHub asset `digest` availability | Update system | Verification | #051, #052 | as specified ([update-system.md](../02-design/update-system.md) §4.5–§4.6) | open |
| OQ-19 | Should Direct manifests be signed? | Update system | Deferred | v1.x | unsigned manifest, APK signer check protects updates | deferred |
| OQ-20 | Do health-check launches cause visible side effects for real apps? | Update system | Verification | #090 | the default health-check level | open |
| OQ-21 | Should partial downloads resume? | Update system | Deferred | v1.x | restart the download | deferred |
| OQ-22 | Does the macOS Apps view list wrappers outside the Applications folders? | Wrappers | Verification | #056 | only `/Applications` and `~/Applications` are promised | open |
| OQ-23 | Should macOS URLs and App Links open in Android apps? | Wrappers | Deferred | post-v1 | wrappers claim no URL schemes or file types | deferred |
| OQ-24 | Liquid Glass icons (`Assets.car`) without Xcode on users' Macs | Wrappers | Deferred | post-v1 | `.icns` only | deferred |
| OQ-25 | Self-updating distribution wrappers, or registry trust by Developer ID team | Wrappers | Deferred | post-v1 | trust by cdhash | deferred |
| OQ-26 | Default of `maintenance.installAPKRunAutomatically` | Maintenance | Decision | review after v1.0 | off | open |
| OQ-27 | Delta image updates | Maintenance | Deferred | post-v1 | full archives | deferred |
| OQ-28 | Automatic rollback of APKRun itself | Maintenance | Deferred | post-v1 | install an older release by hand | deferred |
| OQ-29 | Does the microphone permission prompt appear at VM start or at first capture? | Desktop integration | Verification | #084 | attach the microphone only when enabled | open |
| OQ-30 | Post-v1 integration candidates | Desktop integration | Deferred | post-v1 | not in v1 | deferred |
| OQ-31 | Does Android draw its own mouse pointer for injected `SOURCE_MOUSE` events? | Input | Verification | #024 (display 0), #029 (pool displays) | hide it with pointer icon `TYPE_NULL` | open |
| OQ-32 | Should the memory balloon be inflated before a pause? | Runtime daemon | Verification | #069, #070 | no balloon | open |
| OQ-33 | Do dark wakes cause pause/resume churn? | Runtime daemon | Verification | #069 | resume on every wake | open |
| OQ-34 | Is the persistent Store Agent's memory use acceptable? | Guest components | Verification | after #036, with the `memory` scenario of #070 (NFR-RES-04) | persistent | open |
| OQ-35 | Should display 0 hide the status bar in compatibility mode? | Display | Decision | #079 | status bar visible | open |
| OQ-36 | Release image variant: signing and the AVB state passed | Android image | Decision | #035 | the proposal ([android-image.md](../02-design/android-image.md) §11.4) | open |
| OQ-37 | Which network setup does the stock image need on VZ? | Android image | Verification | #095 | single NIC as `virt_wifi` | open |
| OQ-38 | Does the Cuttlefish arm64 kernel carry `virtio_snd`? | Android image | Verification | #083 | add the module in the custom image if missing | open |
| OQ-39 | How does the EDID physical size affect the density of secondary displays? | Graphics | Verification | #067 (display 0), #028 (pool displays) | density set by `setDisplayPolicy` | open |
| OQ-40 | Which license does APKRun's own code use? | Project | Decision | before #089, and in any case before the v0.4 public demo | no license header; nothing is published | open |
| OQ-41 | Can the user restore the recovery point that Reset Android creates? | Runtime daemon | Decision | before #058 | no restore in v1; the point can be listed and deleted | open |

The scanout hotplug interrupt, the display ID after a mode change, and the other ways a design can fail are risks: R-01 and R-04 in [risks.md](risks.md).

---

## 3. Decisions

### OQ-01 Domain and hosting

- **Question.** APKRun uses the reverse-DNS root `io.apkrun` for bundle IDs (`io.apkrun.APKRun`, `io.apkrun.android.<pkg>` for wrappers), XPC service names, the launchd label, `os_log` subsystems, and Android package names (`io.apkrun.guest`, `io.apkrun.store`) ([modules.md](../01-architecture/modules.md) §5). The root implies ownership of `apkrun.io`. The updates host is also undecided: the Sparkle appcast, the image feed, the archives, and the downloads page (`APKRunDownloadsURL`, `LauncherBuild.downloadURL`) are written as `https://<updates host>/apkrun/...` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.3, §4.1, [../03-reference/configuration.md](../03-reference/configuration.md) §7.1).
- **Why it matters.** Wrapper bundle IDs are derived from the root ([../02-design/wrapper.md](../02-design/wrapper.md) §4.1). Changing the root after users have wrappers breaks Dock pins, notification settings, and window positions. The feed URL is compiled into shipped builds.
- **Deadline.** The namespace before #045 (WrapperCore generator) and in any case before the v0.4 public demo. The host before #057 and #087.
- **Working default.** Keep `io.apkrun`. Use a placeholder host in development and a local HTTP server in tests.
- **If the answer is no.** Choose another root that the project owns, and change it in one pull request before #045. The places that use it are listed in [../01-architecture/modules.md](../01-architecture/modules.md) and [../03-reference/configuration.md](../03-reference/configuration.md).

### OQ-02 Reference Mac

- **Question.** The NFR numbers ([../00-product/requirements.md](../00-product/requirements.md) §2) are measured on one reference Mac. The proposal is the lowest-tier Mac in the lab (M1 with 16 GB, [../02-design/diagnostics.md](../02-design/diagnostics.md) §9.4). Other lab Macs report for information.
- **Deadline.** Before #070, which records the first baselines.

### OQ-03 Package IDs in diagnostics bundles

- **Question.** Package IDs show which apps a user has. #060 includes them because support needs them. The bundle sheet says so ([../02-design/diagnostics.md](../02-design/diagnostics.md) §8).
- **Working default.** Included. Revisit if users ask for an option to leave them out.

### OQ-08 Android app catalog in v1

- **Question.** Should APKRun.app let users browse F-Droid repositories? v1 has the add flow (file, URL, provider) and update sources instead ([../02-design/host-ui.md](../02-design/host-ui.md) §6).
- **Working default.** No catalog in v1. A catalog would be a new task after v1.0.

### OQ-09 Always on top in full screen

- **Working default.** The per-app "Always on top" setting has no effect in full screen ([../02-design/host-ui.md](../02-design/host-ui.md) §7).

### OQ-10 Menu bar and background apps

- **Working default.** The menu bar lists sessions only. Apps kept running without a window (`keepRunning`) are not listed ([../02-design/host-ui.md](../02-design/host-ui.md) §12).

### OQ-26 Automatic installation of APKRun updates

- **Working default.** `maintenance.installAPKRunAutomatically` is off in v1. Sparkle downloads and the user confirms the install ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.5, §6). Review after v1.0 with crash and update data.

### OQ-35 Status bar on display 0

- **Question.** In `primaryDisplayCompatibility` mode, apps run on display 0, which shows Android's status bar. The custom image hides the navigation bar. Should it also hide the status bar there ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §8)?
- **Working default.** The status bar stays visible in v1.

### OQ-36 Release image variant

- **Question.** Shipped images are `apkrun_arm64-trunk_staging-user` signed with APKRun release keys. Which AVB state does the bootconfig pass, and does dm-verity stay on ([../02-design/android-image.md](../02-design/android-image.md) §11.4)?
- **Proposal.** Pass `orange`/`unlocked` and keep dm-verity on through the vbmeta hashtree descriptors. The integrity chain is on the host: signed feed → manifest → file hashes → the attached `os.img`.
- **Deadline.** #035. The answer affects R-13 (SELinux on `user` builds) and OQ-11.

### OQ-40 APKRun's own license

- **Question.** Which license covers APKRun's code, including `APKRunLauncher`, which portable and distribution wrappers carry to other Macs? The requirements for the choice are in [../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md) §1.2.
- **Deadline.** Before #089 (portable wrappers), the first task that gives the launcher binary to other people, and in any case before the v0.4 public demo ([roadmap.md](roadmap.md) §3.4). The answer is recorded in an ADR, and the README, the notices, and the portable note name it ([../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md) §1.1, §9).
- **Working default.** Until then, source files carry no license header and nothing is published.

### OQ-41 Restoring the Reset Android recovery point

- **Question.** Reset Android keeps a recovery point for 7 days ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9.5). No operation restores it. `rollbackImage` restores only the recovery point of the last image migration ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §12.3). Should v1 offer a restore, for example `restoreRecoveryPoint` with **Restore…** in Settings → Storage, allowed only while the point's image version is `current`?
- **Deadline.** Before #058, which builds the recovery point operations. [issues/M04-daemon-and-guest-protocol.md](issues/M04-daemon-and-guest-protocol.md) #066 leaves the restore to #058.
- **Working default.** No restore in v1. `recoveryPoints` lists the point, `deleteRecoveryPoint` deletes it, and apkrund prunes it after 7 days. If the answer is yes, #058 adds the operation, the CLI command, and the Storage button, and the design documents in the same pull request.

---

## 4. Verifications

Each entry names the task that finds the answer and what changes for each result.

| ID | What the task checks | If yes | If no |
|---|---|---|---|
| OQ-04 | `log show --predicate 'subsystem BEGINSWITH "io.apkrun"'` as a standard user on macOS 27 (#061) | `apkrun logs` reads the unified log | `apkrun logs` reads the file mirrors ([../02-design/diagnostics.md](../02-design/diagnostics.md) §3.3). **Observed 2026-09-29:** an unprivileged command in an `admin`-group account returned an APKRun entry; `sudo -n` required a password, and no non-admin account was available. OQ-04 remains open pending a true non-admin run. |
| OQ-05 | `logcat -v uid` shows the UID on the stock Android 17 image (#060) | filter by UID | collect `ps -A -o PID,UID` at the same time and filter by PID |
| OQ-06 | The VZ XPC service process can be matched by name, user, and start time right after `VM_START` (#070) | report the host-side VM footprint | report it as unavailable ([../02-design/diagnostics.md](../02-design/diagnostics.md) §5) |
| OQ-07 | The IOKit accelerator statistics contain a GPU utilization key on the reference Mac (#070) | report it | report unavailable |
| OQ-11 | `RollbackManager` accepts staged rollbacks from the Store Agent on a `user` build (#043) | rollback without data loss on custom images | the confirmed data-loss path, and a note on FR-UPD-11 ([../02-design/package-store.md](../02-design/package-store.md) §7.3) |
| OQ-12 | Update ownership is granted to the Store Agent for an owner-less package, and enforcement is active on the image (#039) | FR-UPD-06 enforced by Android | APKRun keeps ownership on the host only, and health reports `store.ownership` as a warning ([../02-design/package-store.md](../02-design/package-store.md) §6.3, [../02-design/guest-components.md](../02-design/guest-components.md) §8.2) |
| OQ-14 | The density split chosen by the baseline rule gives sharp resources on a Retina window (#042) | keep the rule | change the rule in [../02-design/package-store.md](../02-design/package-store.md) §4.4 |
| OQ-15 | The share of `verifier.disagreement` events in the field (after v0.4) | — | if the host rejects valid APKs, fix the verifier. The host verifier never becomes less strict than Android |
| OQ-17 | With `GENTLE_UPDATE`, an app that runs a foreground service is reported as busy (#040) | as designed | GU5 on custom images adds the `ListTasks` rule and a process-importance query ([../02-design/update-system.md](../02-design/update-system.md) §7.1) |
| OQ-18 | The F-Droid v2 index (`entry.jar`, `index-v2.json`) matches [../02-design/update-system.md](../02-design/update-system.md) §4.5, and the main repository fingerprint (#051). GitHub release assets carry a `digest` (#052) | as designed | #051: follow the real format and update the doc. #052: without `digest`, the APK signer check (V3) is the only protection, and the release shows no hash |
| OQ-20 | Health-check launches do visible work (sounds, network, notifications) for the compatibility corpus apps (#090) | change the default level to `processOnly` without visible work, or to `versionOnly` | keep the default |
| OQ-22 | The macOS Apps view lists wrappers saved outside `/Applications` and `~/Applications` (#056) | say so in the destination picker | the destination picker says that such wrappers do not appear in the Apps view ([../02-design/wrapper.md](../02-design/wrapper.md) §6.3) |
| OQ-29 | macOS shows the microphone prompt at VM start or at first capture (#084) | either way, the microphone is attached only when enabled ([../02-design/vm.md](../02-design/vm.md) §11) | — |
| OQ-31 | Android draws a mouse pointer for injected `SOURCE_MOUSE` events (#024 on display 0, #029 on a pool display) | hide it with pointer icon `TYPE_NULL`; if that API is refused, set `input.hover = false` by default (R-18) | nothing to do ([../02-design/input.md](../02-design/input.md) §4) |
| OQ-32 | Inflating the balloon before a pause frees enough host memory to be worth a slower next launch (#069, #070) | add a balloon step before pause | no balloon ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5.3) |
| OQ-33 | Dark wakes (Power Nap, maintenance) cause measurable pause/resume churn (#069) | resume lazily on the first request or `visibilityChanged(true)` | resume on every wake ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §6) |
| OQ-34 | The persistent Store Agent's steady memory use fits NFR-RES-04 (measured after #036 with the `memory` scenario of #070) | keep it persistent | start it on demand from the Guest Agent ([../02-design/guest-components.md](../02-design/guest-components.md) §8.1) |
| OQ-37 | The stock image gets a validated network on VZ's single NIC (#095) | option 1 in [../02-design/android-image.md](../02-design/android-image.md) §7.4 | options 2 and 3 of the same section |
| OQ-38 | `virtio_snd` is built in or loaded on the stock kernel (#083) | as designed | add it in the custom image ([../02-design/android-image.md](../02-design/android-image.md) §7.5) |
| OQ-39 | The EDID physical size gives secondary displays the expected density (#067 on display 0, #028 on pool displays) | as designed | set the density with `setDisplayPolicy` only, and record it in [../02-design/graphics.md](../02-design/graphics.md) §6.4 |

---

## 5. Deferred

These are out of v1 on purpose ([../00-product/scope.md](../00-product/scope.md) §3, §5). A deferred item becomes work only through a new task (#098 and up) after the v1.0 release, or in v1.x where the table says so.

| ID | Item | Target | Notes |
|---|---|---|---|
| OQ-13 | OBB expansion files for `.xapk` | v1.x | push through the Store Agent into `Android/obb/<pkg>/` ([../02-design/package-store.md](../02-design/package-store.md) §4.2) |
| OQ-16 | Data rollback | post-v1 | `ROLLBACK_DATA_POLICY_RESTORE` on custom images ([../02-design/package-store.md](../02-design/package-store.md) §7.3) |
| OQ-19 | Signed Direct manifests | v1.x | a detached signature with a key pinned when the provider is attached ([../02-design/update-system.md](../02-design/update-system.md) §4.4) |
| OQ-21 | Resuming partial downloads | v1.x | v1 restarts an interrupted download from the beginning |
| OQ-23 | macOS URL schemes and App Links into Android apps | post-v1 | claiming a scheme takes it from the native Mac app of the same service ([../02-design/wrapper.md](../02-design/wrapper.md) §2.1) |
| OQ-24 | Liquid Glass icons (`Assets.car`) | post-v1 | needs `actool`, which is not on users' Macs ([../02-design/wrapper.md](../02-design/wrapper.md) §8.4) |
| OQ-25 | Self-updating distribution wrappers; registry trust by Developer ID team | post-v1 | v1 trusts wrappers by cdhash ([../02-design/wrapper.md](../02-design/wrapper.md) §7.2, §11) |
| OQ-27 | Delta image updates | post-v1 | v1 downloads full archives ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.4) |
| OQ-28 | Automatic rollback of APKRun | post-v1 | v1: install an older release by hand ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.9) |
| OQ-30 | Integration candidates: media controls and Now Playing from `MediaSession`; notification replies; Mac → Android links; per-app languages; dark mode sync; per-app mute; camera | post-v1 | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §10 |

Post-v1 tracks that already have task numbers: #096 Vulkan and #097 Google Play authority ([issues/post-v1.md](issues/post-v1.md)).
