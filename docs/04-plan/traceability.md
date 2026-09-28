# Traceability

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [roadmap.md](roadmap.md), [issues/README.md](issues/README.md), [test-strategy.md](test-strategy.md), [risks.md](risks.md), [open-questions.md](open-questions.md) |

This document connects each requirement to its implementation tasks, design sections, and verification. It also summarizes tasks #061–#097.

## 1. Maintenance rules

- A pull request that adds, removes, or renames a requirement, a task, or a design section updates this file in the same pull request.
- Keep design clarifications in their canonical product, architecture, or design documents. If a clarification changes an architectural decision, add an ADR ([../01-architecture/decisions/README.md](../01-architecture/decisions/README.md)).
- The Tasks column lists the tasks that deliver the requirement by its target version. These are the tasks whose entries name the requirement in their Requirements row, before any `Constraints:` part. A task that only keeps a requirement names it under `Constraints:` and is not listed here.
- Tasks after `later:` extend or re-verify a requirement after its target version: hardening, polish, and post-v1 tracks. They do not gate that version ([roadmap.md](roadmap.md) §3).
- “Verified by” names the test tiers in [test-strategy.md](test-strategy.md) and the task whose acceptance tests cover the requirement. Individual tests are listed in the milestone files ([issues/README.md](issues/README.md)).
- [roadmap.md](roadmap.md) §3 uses §2 as the release checklist: every `Must` requirement for a version needs its tasks done and its tests passing.

## 2. Requirements → tasks → design → verification

The requirement text, priority, and target version are in [../00-product/requirements.md](../00-product/requirements.md). Paths below are relative to `docs/`.

### 2.1 VM (FR-VM)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-VM-01 | #002, #003 | [vm.md](../02-design/vm.md) §2–§4, §12; ADR-0002 | T0 validator; T2 test Linux guest; G1 |
| FR-VM-02 | #004 | [vm.md](../02-design/vm.md) §6 | T0 `ConsoleLogWriter` rotation and fsync policy; T1 `ConsoleChannel` and `ConsoleLogWriter` on disk; T2 port numbering |
| FR-VM-03 | #005, #011 | [vm.md](../02-design/vm.md) §4; [android-image.md](../02-design/android-image.md) §4.2 | T2 test guest disk checks |
| FR-VM-04 | #006, #095 | [vm.md](../02-design/vm.md) §7; [android-image.md](../02-design/android-image.md) §7.4 | T2 test guest `net` check; T2 Android network check |
| FR-VM-05 | #007 | [vm.md](../02-design/vm.md) §8 | T2 test guest `vsock` check |
| FR-VM-06 | #063, #019 | [graphics.md](../02-design/graphics.md) §3–§4 | T0 `VirtioDeviceCore`; T2 test device `rng`, `gpu` |
| FR-VM-07 | #002, #003 | [vm.md](../02-design/vm.md) §9; [state-machines.md](../01-architecture/state-machines.md) §1 | T0 state machine; T2; G1 |
| FR-VM-08 | #012, #013, #095, #014 | [android-image.md](../02-design/android-image.md) §6–§8; ADR-0015 | T2 stock image boot; G2 |
| FR-VM-09 | #031 | [runtime-daemon.md](../02-design/runtime-daemon.md) §2, §10; ADR-0007 | T2 daemon tests; G6 |
| FR-VM-10 | #069 | [runtime-daemon.md](../02-design/runtime-daemon.md) §5 | T0 idle policy; T2 pause/resume |
| FR-VM-11 | #069, #085 | [runtime-daemon.md](../02-design/runtime-daemon.md) §6; [desktop-integration.md](../02-design/desktop-integration.md) §9 | T1 simulated power events; T3 manual sleep/wake |

### 2.2 Android image (FR-IMG)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-IMG-01 | #008 | [android-image.md](../02-design/android-image.md) §2–§3.1 | T0 inventory classifier (pytest); T1 on a real artifact set |
| FR-IMG-02 | #009 | [android-image.md](../02-design/android-image.md) §3.2–§3.3; [android-image-manifest.md](../03-reference/android-image-manifest.md) | T0 schema and validation |
| FR-IMG-03 | #010 | [android-image.md](../02-design/android-image.md) §4.1, §6 | T0 bootconfig merge; T1 extraction with hash checks of the originals |
| FR-IMG-04 | #011 | [android-image.md](../02-design/android-image.md) §4.2–§4.5, §5 | T0 GPT writer; T2 `boot_devices` on VZ |
| FR-IMG-05 | #035 | [android-image.md](../02-design/android-image.md) §11; [guest-components.md](../02-design/guest-components.md) §4, §10 | Linux builder CI; T2 custom image boot |
| FR-IMG-06 | #058, #087 | [android-image.md](../02-design/android-image.md) §12; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4 | T2 migration A → B and failure return; T3 release smoke |

### 2.3 Graphics and display (FR-GFX, FR-DSP)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-GFX-01 | #019, #021; later: #096 (post-v1) | [graphics.md](../02-design/graphics.md) §4 | T0 command decoding; T2 Linux DRM probe; T2 Android detection |
| FR-GFX-02 | #020 | [graphics.md](../02-design/graphics.md) §5.1; [build-system.md](../05-development/build-system.md) | CI build from `ThirdParty.lock.json`; T1 renderer smoke |
| FR-GFX-03 | #022 | [graphics.md](../02-design/graphics.md) §5.3 | T2 renderer string check |
| FR-GFX-04 | #023 | [graphics.md](../02-design/graphics.md) §6 | T2; G3 |
| FR-GFX-05 | #023; later: #096 (post-v1) | [graphics.md](../02-design/graphics.md) §6.2, §7 | readback counter = 0 in T2 and the perf harness; G3 |
| FR-DSP-01 | #028, #029, #030 | [display-and-windowing.md](../02-design/display-and-windowing.md) §2; ADR-0005 | T2; G5 |
| FR-DSP-02 | #028 | [display-and-windowing.md](../02-design/display-and-windowing.md) §3; [state-machines.md](../01-architecture/state-machines.md) §4 | T0 `DisplayPool` model tests; T2 acquire/release/reuse |
| FR-DSP-03 | #030 | [display-and-windowing.md](../02-design/display-and-windowing.md) §3–§4; [input.md](../02-design/input.md) §7 | T2; G5 |
| FR-DSP-04 | #067 | [display-and-windowing.md](../02-design/display-and-windowing.md) §6 | T0 geometry; T2 density on Retina and non-Retina screens |
| FR-DSP-05 | #067 | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.1 | T2 resize; the chosen behavior recorded under R-04 |
| FR-DSP-06 | #029, #079 | [display-and-windowing.md](../02-design/display-and-windowing.md) §8 | T2 compatibility mode |
| FR-DSP-07 | #068 | [display-and-windowing.md](../02-design/display-and-windowing.md) §5; ADR-0006 | T1 buffer state machine; T2 wrapper window |

### 2.4 Input (FR-IN)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-IN-01 | #024 | [input.md](../02-design/input.md) §3–§4 | T0 `EventTranslator`; T2 HelloText clicks |
| FR-IN-02 | #024 | [input.md](../02-design/input.md) §4.4 | T0 scroll conversion; T2 HelloCompose scroll |
| FR-IN-03 | #025 | [input.md](../02-design/input.md) §5.2 | T0 key map; T2 typing |
| FR-IN-04 | #025 | [input.md](../02-design/input.md) §6 | T2 back navigation |
| FR-IN-05 | #030 | [input.md](../02-design/input.md) §7 | T2 two-window routing; G5 |
| FR-IN-06 | #072, #024 | [input.md](../02-design/input.md) §1, §8; ADR-0013 | code review; T2 no `input` shell processes during a run; G4 |
| FR-IN-07 | #071 | [input.md](../02-design/input.md) §5.3, §5.6; [guest-components.md](../02-design/guest-components.md) §7 | T2 Japanese composition in HelloText and HelloCompose |
| FR-IN-08 | #025, #071 | [input.md](../02-design/input.md) §5.4, §6 | T2 shortcuts |
| FR-IN-09 | — (v1.x) | [input.md](../02-design/input.md) §10 | — |

### 2.5 Runtime (FR-RT)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-RT-01 | #027 | [package-store.md](../02-design/package-store.md) §11; [runtime-api.md](../03-reference/runtime-api.md) | T0 store model; T2 CLI install and launch |
| FR-RT-02 | #032 | [runtime-daemon.md](../02-design/runtime-daemon.md) §8; [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2 | T1 XPC contract tests; module dependency check (#062) |
| FR-RT-03 | #031, #070 | [runtime-daemon.md](../02-design/runtime-daemon.md) §7; [display-and-windowing.md](../02-design/display-and-windowing.md) §9 | perf harness (NFR-PERF-01); G6 |
| FR-RT-04 | #033, #034 | [guest-protocol.md](../02-design/guest-protocol.md) §5 | T0 handshake and version rules; T2 mismatched agent |
| FR-RT-05 | #015, #034 | [guest-protocol.md](../02-design/guest-protocol.md) §13.2–§13.3; [security-model.md](../01-architecture/security-model.md) §4 | T2 ADB with developer mode on and off |

### 2.6 Packages (FR-PKG)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-PKG-01 | #016, #036 | [package-store.md](../02-design/package-store.md) §6 | code review; T2 installs through `PackageInstaller` sessions |
| FR-PKG-02 | #036, #073 | [package-store.md](../02-design/package-store.md) §9 | T1 reconcile rules with a fake channel; T2 |
| FR-PKG-03 | #073 | [package-store.md](../02-design/package-store.md) §4.3, §10.1 | T0 `APKInspector` on fixture APKs |
| FR-PKG-04 | #027, #037 | [package-store.md](../02-design/package-store.md) §3, §5; [filesystem-layout.md](../01-architecture/filesystem-layout.md) §1 | T1 journal and crash recovery |
| FR-PKG-05 | #042 | [package-store.md](../02-design/package-store.md) §4.4, §6 | T2 HelloSplit |
| FR-PKG-06 | #073 | [package-store.md](../02-design/package-store.md) §4.2 | T0 container parsing |
| FR-PKG-07 | #027, #076 | [package-store.md](../02-design/package-store.md) §8; [wrapper.md](../02-design/wrapper.md) §9.5; [host-ui.md](../02-design/host-ui.md) §8 | T2 uninstall with and without data |

### 2.7 Updates (FR-UPD)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-UPD-01 | #037, #039 | [update-system.md](../02-design/update-system.md) §2.1; ADR-0010 | T0 authority rules |
| FR-UPD-02 | #037 | [update-system.md](../02-design/update-system.md) §4.1 | T0 provider protocol |
| FR-UPD-03 | #037 | [update-system.md](../02-design/update-system.md) §4.3 | T1 coordinator with fakes; T2 LocalProvider V1 → V2 without network |
| FR-UPD-04 | #041 | [update-system.md](../02-design/update-system.md) §6; [package-store.md](../02-design/package-store.md) §4.5–§4.6 | T0 verifier with the fixture corpus; fuzzing (#091) |
| FR-UPD-05 | #041 | [update-system.md](../02-design/update-system.md) §6 | T0 |
| FR-UPD-06 | #039 | [update-system.md](../02-design/update-system.md) §2; [package-store.md](../02-design/package-store.md) §6.3 | T0 authority mapping; T2 ownership after install (OQ-12) |
| FR-UPD-07 | #040 | [update-system.md](../02-design/update-system.md) §7 | T1 gate conditions and races; T2; G7 |
| FR-UPD-08 | #074 | [update-system.md](../02-design/update-system.md) §3 | T1 scheduler with a fake clock; T2 slow provider; code review of the launch path (NFR-PERF-07) |
| FR-UPD-09 | #074, #079 | [update-system.md](../02-design/update-system.md) §2.2; [host-ui.md](../02-design/host-ui.md) §7.5 | T0; T3 UI check |
| FR-UPD-10 | #043 | [update-system.md](../02-design/update-system.md) §8.1–§8.2 | T2 health check with HelloUpdate |
| FR-UPD-11 | #043 | [update-system.md](../02-design/update-system.md) §8.3; [package-store.md](../02-design/package-store.md) §7.3 | T2 forced failure → rollback (OQ-11) |
| FR-UPD-12 | #050 | [update-system.md](../02-design/update-system.md) §4.4; [direct-provider-manifest.md](../03-reference/direct-provider-manifest.md) | T0 manifest schema cases; T1 and T2 against the local HTTP test service on loopback (`update-server.py`) |
| FR-UPD-13 | #051, #052 | [update-system.md](../02-design/update-system.md) §4.5–§4.6 | T1 recorded responses; T3 network tests |
| FR-UPD-14 | #041, #052 | [update-system.md](../02-design/update-system.md) §6 | T0 provider metadata that disagrees with the APK |
| FR-UPD-15 | #038 | [update-system.md](../02-design/update-system.md) §5; [package-store.md](../02-design/package-store.md) §7.1–§7.2 | T1 crash injection at every `update` host step; T2 V2 through `installStaged` with data kept |

### 2.8 Wrappers (FR-WRP)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-WRP-01 | #045, #046, #075 | [wrapper.md](../02-design/wrapper.md) §6, §12 | T1 generation; G8 |
| FR-WRP-02 | #075, #089 | [wrapper.md](../02-design/wrapper.md) §12.2; [cli.md](../02-design/cli.md) §4.4 | T0 argument parsing (with alternate flag spellings) |
| FR-WRP-03 | #045, #048 | [wrapper.md](../02-design/wrapper.md) §3; [wrapper-json.md](../03-reference/wrapper-json.md) | T0 schema: no version-specific keys |
| FR-WRP-04 | #049 | [wrapper.md](../02-design/wrapper.md) §9; ADR-0009 | T2 hashes and cdhash before and after an update; G9 |
| FR-WRP-05 | #045 | [wrapper.md](../02-design/wrapper.md) §4.1 | T0 `BundleIDMapper` |
| FR-WRP-06 | #044; later: #088 | [wrapper.md](../02-design/wrapper.md) §5.1 | T1 every wrapper's executable has the launcher's cdhash |
| FR-WRP-07 | #055 | [wrapper.md](../02-design/wrapper.md) §8 | T1 icon pipeline golden images |
| FR-WRP-08 | #056 | [wrapper.md](../02-design/wrapper.md) §6.3 | T3 Finder, Dock, Spotlight, Apps view (OQ-22) |
| FR-WRP-09 | #044 | [wrapper.md](../02-design/wrapper.md) §5.3–§5.4 | T1 launcher screens with a fake runtime |
| FR-WRP-10 | #046, #088 | [wrapper.md](../02-design/wrapper.md) §7.1, §11; [security-model.md](../01-architecture/security-model.md) §3.3 | T1 `codesign --verify`; T3 notarization (#088) |
| FR-WRP-11 | #048 | [wrapper.md](../02-design/wrapper.md) §3; [package-store.md](../02-design/package-store.md) §3 | T2 launch after deleting the source APK |
| FR-WRP-12 | #076 | [wrapper.md](../02-design/wrapper.md) §9.1–§9.2 | T1 `WrapperValidator` with fixture bundles |
| FR-WRP-13 | #076 | [wrapper.md](../02-design/wrapper.md) §9.3 | T1 refresh keeps the bundle ID; R-20 check |

### 2.9 Desktop integration (FR-INT)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-INT-01 | #053 | [desktop-integration.md](../02-design/desktop-integration.md) §4 | T0 loop prevention; T2 HelloClipboard |
| FR-INT-02 | #080 | [desktop-integration.md](../02-design/desktop-integration.md) §4.4 | T2 |
| FR-INT-03 | #054 | [desktop-integration.md](../02-design/desktop-integration.md) §5 (FCM limit) | T2 HelloNotification |
| FR-INT-04 | #081 | [desktop-integration.md](../02-design/desktop-integration.md) §7 | T2 HelloLinks |
| FR-INT-05 | #082 | [desktop-integration.md](../02-design/desktop-integration.md) §6.1, §6.4; [security-model.md](../01-architecture/security-model.md) §6 | T1 path confinement; fuzzing (#091) |
| FR-INT-06 | #082 | [desktop-integration.md](../02-design/desktop-integration.md) §6.2–§6.4 | T2 HelloFiles |
| FR-INT-07 | #083 | [desktop-integration.md](../02-design/desktop-integration.md) §8.1; [vm.md](../02-design/vm.md) §11 | T2 HelloAudio; T3 listening check |
| FR-INT-08 | #084 | [desktop-integration.md](../02-design/desktop-integration.md) §8.2 | T3 manual permission check (OQ-29) |
| FR-INT-09 | #085 | [desktop-integration.md](../02-design/desktop-integration.md) §9 | T2 locale and time zone change |
| FR-INT-10 | — (v1.x) | [../00-product/scope.md](../00-product/scope.md) §3 | — |

### 2.10 UI and CLI (FR-UI, FR-CLI)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-UI-01 | #077 | [host-ui.md](../02-design/host-ui.md) §5 | T1 view models with a fake client; T3 UI check |
| FR-UI-02 | #078; later: #090 | [host-ui.md](../02-design/host-ui.md) §6 | T1; T3 |
| FR-UI-03 | #079; later: #090 | [host-ui.md](../02-design/host-ui.md) §7 | T1; T3 |
| FR-UI-04 | #077 | [host-ui.md](../02-design/host-ui.md) §5.3 | T1; T3 |
| FR-UI-05 | #086 | [host-ui.md](../02-design/host-ui.md) §12 | T1; T3 |
| FR-UI-06 | #078 | [host-ui.md](../02-design/host-ui.md) §3.2 | T3 double-click an `.apk` |
| FR-CLI-01 | #017, #027, #032, #053, #075, #059, #060; later: #090 | [cli.md](../02-design/cli.md) §4 | T0 parsing; T2 command runs |
| FR-CLI-02 | #061; later: #059, #092 | [diagnostics.md](../02-design/diagnostics.md) §2.3; [error-catalog.md](../03-reference/error-catalog.md) | T0 every error has a remediation |

### 2.11 Operations (FR-OPS)

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| FR-OPS-01 | #059 | [diagnostics.md](../02-design/diagnostics.md) §7 | T2 fault injection per failure class |
| FR-OPS-02 | #060 | [diagnostics.md](../02-design/diagnostics.md) §6, §8 | T0 redaction corpus ([diagnostics.md](../02-design/diagnostics.md) §12 T1-7); T2 bundles, including after a forced boot failure (T2-5), and the secret fixture test (T2-6) |
| FR-OPS-03 | #057 | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3; ADR-0016 | T2 APKRun N → N+1 (R-23, R-24) |
| FR-OPS-04 | #087 | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) | T1 feed signature and replay; T2 install and rollback |
| FR-OPS-05 | #061, #070 | [diagnostics.md](../02-design/diagnostics.md) §4 | T0 marker catalogue; perf harness |
| FR-OPS-06 | #090 | [diagnostics.md](../02-design/diagnostics.md) §10 | T0 matching and settings resolution ([diagnostics.md](../02-design/diagnostics.md) §12 T1-10); CI schema validation of the shipped file; T2 an entry applies the window mode, and a different signer does not |
| FR-OPS-07 | #066 | [runtime-daemon.md](../02-design/runtime-daemon.md) §9; [host-ui.md](../02-design/host-ui.md) §4; [package-store.md](../02-design/package-store.md) §9 | T1 provisioning resume after a kill and XCUITest onboarding resume; T2 setup on an empty data root and Reset Android; T3 checklist C10-3 |

### 2.12 Non-functional requirements

| ID | Tasks | Design | Verified by |
|---|---|---|---|
| NFR-PERF-01 | #031, #047, #070 | [display-and-windowing.md](../02-design/display-and-windowing.md) §9; [diagnostics.md](../02-design/diagnostics.md) §9 | perf harness on the reference Mac (OQ-02) |
| NFR-PERF-02 | #047, #070 | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 | perf harness (R-07) |
| NFR-PERF-03 | #024, #070 | [input.md](../02-design/input.md) §8 | signposts in the perf harness |
| NFR-PERF-04 | #023, #070; later: #096 (post-v1) | [graphics.md](../02-design/graphics.md) §7 | perf harness with HelloGL (R-03) |
| NFR-PERF-05 | #023; later: #070 | [graphics.md](../02-design/graphics.md) §7 | readback counter in T2 and the perf harness |
| NFR-PERF-06 | #069, #070 | [runtime-daemon.md](../02-design/runtime-daemon.md) §5.6 | perf harness idle scenario |
| NFR-PERF-07 | #074 | [update-system.md](../02-design/update-system.md) §3.1 | code review; perf harness with a slow provider |
| NFR-RES-01 | #002, #066 | [vm.md](../02-design/vm.md) §10 | T0 validator limits |
| NFR-RES-02 | #011, #066 | [android-image.md](../02-design/android-image.md) §5.2 | T1 allocated size vs. logical size |
| NFR-RES-03 | #046 | [wrapper.md](../02-design/wrapper.md) §2 | T1 bundle size limit |
| NFR-RES-04 | #070 | [diagnostics.md](../02-design/diagnostics.md) §5 | perf harness memory report (OQ-06; OQ-34 after #036) |
| NFR-SEC-01 | #091 | [security-model.md](../01-architecture/security-model.md) §2 | security review (#091) |
| NFR-SEC-02 | #082; later: #091 | [desktop-integration.md](../02-design/desktop-integration.md) §6.1, §6.4 (refused roots: volume roots, the home folder, `~/Library`, hidden folders); [security-model.md](../01-architecture/security-model.md) §6 | T1 refused roots (`integration.folderRefused`) |
| NFR-SEC-03 | #053, #054, #081, #082, #084; later: #091 | [desktop-integration.md](../02-design/desktop-integration.md) §2 | T0 policy evaluation |
| NFR-SEC-04 | #041 | [security-model.md](../01-architecture/security-model.md) §5; [update-system.md](../02-design/update-system.md) §6 | T0 verifier corpus; code review |
| NFR-SEC-05 | #061, #060; later: #084, #091 | [diagnostics.md](../02-design/diagnostics.md) §3.2, §6 | T0 redaction corpus ([diagnostics.md](../02-design/diagnostics.md) §12 T1-7); T1 log mirror has no private values (T1-3); T2 secret fixture test (T2-6) |
| NFR-SEC-06 | #015; later: #091 | [security-model.md](../01-architecture/security-model.md) §4 | T2 ADB listens on loopback only |
| NFR-SEC-07 | #032, #047; later: #044, #088, #091 | [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2; [security-model.md](../01-architecture/security-model.md) §3.1; [wrapper.md](../02-design/wrapper.md) §7.2 | T1 authorization tests; #091 |
| NFR-REL-01 | #027, #038 | [package-store.md](../02-design/package-store.md) §5 | T1 crash injection at every journal step |
| NFR-REL-02 | #031 | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.5 | T2 kill apkrund; G6 |
| NFR-REL-03 | #034 | [runtime-daemon.md](../02-design/runtime-daemon.md) §4 | T2 kill the agent |
| NFR-REL-04 | #033, #034 | [guest-protocol.md](../02-design/guest-protocol.md) §5.2 | T0 version rules |
| NFR-REL-05 | #004 | [vm.md](../02-design/vm.md) §6.4 | T2 log after a forced VM crash |
| NFR-OBS-01 | #061; later: #060 | [diagnostics.md](../02-design/diagnostics.md) §3 | T0 facade; code review |
| NFR-OBS-02 | #059 | [diagnostics.md](../02-design/diagnostics.md) §7 | T0 health verdict table ([diagnostics.md](../02-design/diagnostics.md) §12 T1-6); each owner module's T0 tests of its checks; T2 fault injection (T2-4) |
| NFR-OBS-03 | #059 | [diagnostics.md](../02-design/diagnostics.md) §7.2 | T2 fault injection |
| NFR-DEV-01 | #020, #062; later: #093 | [build-system.md](../05-development/build-system.md) | CI lock check |
| NFR-DEV-02 | #001, #062 | [build-system.md](../05-development/build-system.md) | CI clean build |
| NFR-DEV-03 | #061 | [diagnostics.md](../02-design/diagnostics.md) §2; [coding-conventions.md](../05-development/coding-conventions.md) | code review |
| NFR-DEV-04 | every task | [coding-conventions.md](../05-development/coding-conventions.md) | CI lint for `TODO` without an issue number |
| NFR-DEV-05 | every task | [workflow.md](../05-development/workflow.md) | code review |
| NFR-CMP-01 | #016 and the fixture apps; later: #083, #090 | [test-strategy.md](test-strategy.md) | fixture-first rule in every T2 suite |
| NFR-CMP-02 | #044, #057 | [wrapper.md](../02-design/wrapper.md) §5.3; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.2 | T2 old wrapper on a new runtime |
| NFR-CMP-03 | #058 | [android-image.md](../02-design/android-image.md) §12.3 | T2 migration keeps apps and data |
| NFR-L10N-01 | #092 | [host-ui.md](../02-design/host-ui.md) §13 | T0 error catalog and CLI golden files in Japanese; the `lint` catalog check (`scripts/check-strings.sh`); T2 pseudo-language run |
| NFR-L10N-02 | #092 | [host-ui.md](../02-design/host-ui.md) §13 | T3 VoiceOver check |

---


## 3. Tasks #061–#097

The task entries and milestone files define the scope, dependencies, acceptance criteria, and milestone assignments for tasks #061–#097.

| Task | Capability | Drivers |
|---|---|---|
| #061 | Diagnostics foundation | Typed errors, structured logging, health types, and performance markers |
| #062 | CI and module dependency checks | NFR-DEV-01, NFR-DEV-02 |
| #063 | VirtioDeviceCore and a test device | Validate the custom virtio API before virtio-gpu work; R-01 |
| #064 | Reference boot capture | Compare Virtualization.framework boot behavior with a known-good Cuttlefish boot; R-06, R-11 |
| #065 | Runtime image bundle | Package a reproducible installable runtime image; ADR-0011 |
| #066 | First-run provisioning | FR-OPS-07; NFR-RES-01, NFR-RES-02 |
| #067 | Retina density and resize | FR-DSP-04, FR-DSP-05 |
| #068 | Session client and IOSurface window | FR-DSP-07; ADR-0006 |
| #069 | Idle policy and host sleep/wake | FR-VM-10, FR-VM-11, NFR-PERF-06 |
| #070 | Performance harness | NFR-PERF-*, NFR-RES-04 |
| #071 | APKRun IME | FR-IN-07, FR-IN-08 |
| #072 | Guest Agent bootstrap | FR-IN-06; ADR-0013 |
| #073 | Host inspection and import formats | FR-PKG-02, FR-PKG-03, FR-PKG-06 |
| #074 | Update scheduler | FR-UPD-08, FR-UPD-09, NFR-PERF-07 |
| #075 | `apkrun wrap` CLI | FR-WRP-01, FR-WRP-02 |
| #076 | Wrapper lifecycle and uninstall choices | FR-WRP-12, FR-WRP-13, FR-PKG-07 |
| #077 | Home and store UI | FR-UI-01, FR-UI-04 |
| #078 | Add flow | FR-UI-02, FR-UI-06 |
| #079 | Per-app settings | FR-UI-03, FR-UPD-09, FR-DSP-06 |
| #080 | Image and HTML clipboard | FR-INT-02 |
| #081 | Links | FR-INT-04 |
| #082 | Files and shared-folder policy | FR-INT-05, FR-INT-06, NFR-SEC-02 |
| #083 | Audio output | FR-INT-07 |
| #084 | Microphone | FR-INT-08 |
| #085 | Locale, time zone, clock format, and time | FR-INT-09, FR-VM-11 |
| #086 | Menu bar | FR-UI-05 |
| #087 | Runtime image distribution | FR-OPS-04, FR-IMG-06 |
| #088 | Developer ID signing and notarization | Distribution half of FR-WRP-10 |
| #089 | Portable apps | FR-WRP-02 |
| #090 | Compatibility database | FR-OPS-06 |
| #091 | Security hardening and fuzzing | NFR-SEC-* |
| #092 | Localization and accessibility | NFR-L10N-01, NFR-L10N-02 |
| #093 | Legal and licensing compliance | R-10 |
| #094 | v1.0 release readiness | [roadmap.md](roadmap.md) §3.6 |
| #095 | Cuttlefish host-service substitution | FR-VM-04, FR-VM-08; R-12 |
| #096 | Vulkan track | Post-v1 evaluation |
| #097 | Google Play update authority | Post-v1 evaluation |

The task index and milestone files are authoritative for sequencing and final milestone assignments.
