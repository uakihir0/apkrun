# Requirements

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [scope.md](scope.md), [../04-plan/issues/](../04-plan/issues/), [../04-plan/roadmap.md](../04-plan/roadmap.md) |

Requirement IDs are `FR-<area>-<n>` (functional) and `NFR-<area>-<n>` (non-functional). Priority: **Must** (required by that version's DoD) / **Should** / **Could**. "Ver" is the first version that must satisfy it. "Task" names the tasks that deliver the requirement by that version ([../04-plan/issues/](../04-plan/issues/)). [../04-plan/traceability.md](../04-plan/traceability.md) §2 also lists the later tasks that extend it.

---

## 1. Functional requirements

### 1.1 VM / runtime (FR-VM)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-VM-01 | Boot ARM64 Linux with Virtualization.framework | Must | 0.1 | #002, #003 |
| FR-VM-02 | Show guest serial output live and persist it to disk with rotation | Must | 0.1 | #004 |
| FR-VM-03 | Attach read-only and read-write virtio-blk disks in a deterministic order | Must | 0.1 | #005, #011 |
| FR-VM-04 | Guest resolves DNS and reaches external hosts through NAT networking | Must | 0.1 | #006, #095 |
| FR-VM-05 | Host ↔ guest virtio-vsock communication with timeout and disconnect handling | Must | 0.1 | #007 |
| FR-VM-06 | Expose host-implemented custom virtio devices to the guest | Must | 0.1 | #063, #019 |
| FR-VM-07 | Explicit VM state (stopped / starting / running / paused / stopping / failed) | Must | 0.1 | #002, #003 |
| FR-VM-08 | Boot Android to `sys.boot_completed=1` and stay stable for several minutes | Must | 0.1 | #012–#014, #095 |
| FR-VM-09 | The VM lives in `apkrund` and survives GUI exit while apps are active | Must | 0.2 | #031 |
| FR-VM-10 | Pause the VM after all apps have been closed for a configurable time; resume on the next launch request | Should | 0.2 | #069 |
| FR-VM-11 | Handle host sleep / wake correctly for the VM and the guest clock | Should | 0.2 | #069, #085 |

### 1.2 Android image (FR-IMG)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-IMG-01 | Acquire Cuttlefish ARM64 artifacts and generate an inventory manifest without assuming file names | Must | 0.1 | #008 |
| FR-IMG-02 | Describe an image set with `AndroidImageManifest` (no hard-coded file names) | Must | 0.1 | #009 |
| FR-IMG-03 | Extract kernel and ramdisk from boot / init_boot / vendor_boot and assemble bootconfig, never modifying originals | Must | 0.1 | #010 |
| FR-IMG-04 | Map partitions to virtio-blk devices in a data-driven way | Must | 0.1 | #011 |
| FR-IMG-05 | Build our own APKRun AOSP product reproducibly on a Linux builder | Must | 0.3 | #035 |
| FR-IMG-06 | Version runtime images; migrate A → B keeping userdata; return to A on failure | Must | 0.5 | #058, #087 |

### 1.3 Graphics / display (FR-GFX, FR-DSP)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-GFX-01 | Implement a standard virtio-gpu device (device ID 16) as a custom virtio device | Must | 0.1 | #019, #021 |
| FR-GFX-02 | Build virglrenderer / ANGLE reproducibly from pinned revisions | Must | 0.1 | #020 |
| FR-GFX-03 | Android renders through VirGL (Mesa); software rendering is not the normal path | Must | 0.1 | #022 |
| FR-GFX-04 | SurfaceFlinger output appears in a macOS window through Metal | Must | 0.1 | #023 |
| FR-GFX-05 | No CPU readback or CPU texture copies on the normal frame path | Must | 0.1 | #023 |
| FR-DSP-01 | One Android display corresponds to one macOS window | Must | 0.2 | #028–#030 |
| FR-DSP-02 | `DisplayPool` centrally allocates, releases, and reuses displays (no hard-coded mappings) | Must | 0.2 | #028 |
| FR-DSP-03 | Two or more apps can be used at the same time in separate windows | Must | 0.2 | #030 |
| FR-DSP-04 | Map the Retina backing scale factor to Android density | Must | 0.1 | #067 |
| FR-DSP-05 | Define the resize policy (fixed / resizable); when resizable, propagate the size to the Android display | Should | 0.2 | #067 |
| FR-DSP-06 | Provide a `primaryDisplayCompatibility` mode for apps that misbehave on secondary displays | Should | 0.4 | #029, #079 |
| FR-DSP-07 | `apkrund` renders; the wrapper process owns the window (shared IOSurface) | Must | 0.2 | #068 |

### 1.4 Input (FR-IN)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-IN-01 | Translate mouseDown / Dragged / Up into touch DOWN / MOVE / UP | Must | 0.1 | #024 |
| FR-IN-02 | Translate scroll wheel / trackpad scrolling into scroll input | Must | 0.1 | #024 |
| FR-IN-03 | Send key down/up, modifiers, Backspace, Enter, arrows | Must | 0.1 | #025 |
| FR-IN-04 | Map Esc (and Cmd+[) to Android BACK | Must | 0.1 | #025 |
| FR-IN-05 | Route input only to the display that belongs to the active window | Must | 0.2 | #030 |
| FR-IN-06 | Never spawn a shell command per input event on the production path | Must | 0.1 | #072, #024 |
| FR-IN-07 | Text committed by the macOS IME (including Japanese) reaches Android text fields | Must | 0.2 | #071 |
| FR-IN-08 | Map Cmd+C / V / X / A / Z to the equivalent Android actions | Should | 0.2 | #025, #071 |
| FR-IN-09 | Trackpad gestures such as pinch | Could | 1.x | — |

### 1.5 Runtime API / daemon (FR-RT)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-RT-01 | Runtime API: `install / launch / terminate / uninstall / listInstalled / applicationInfo` | Must | 0.1 | #027 |
| FR-RT-02 | All clients (APKRun.app / launcher / CLI / menu bar) use `apkrund` over XPC | Must | 0.2 | #032 |
| FR-RT-03 | In the warm state, go from display allocation → Activity start → first frame without booting the VM | Must | 0.2 | #031, #070 |
| FR-RT-04 | Versioned handshake with guest agents; incompatible major versions are rejected explicitly | Must | 0.2 | #033, #034 |
| FR-RT-05 | ADB can be enabled in every development build: it is on in developer mode and off otherwise (the production control path is vsock, [../01-architecture/security-model.md](../01-architecture/security-model.md) §4) | Must | 0.1 | #015, #034 |

### 1.6 Package store (FR-PKG)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-PKG-01 | Never copy APKs into Android package directories; always use `PackageInstaller` | Must | 0.1 | #016, #036 |
| FR-PKG-02 | Android `PackageManager` is canonical for package metadata | Must | 0.3 | #036, #073 |
| FR-PKG-03 | The host can also parse APKs for previews (name, icon, version shown even when the VM is not running) | Should | 0.3 | #073 |
| FR-PKG-04 | Manage the Package Store under `~/Library/Application Support/APKRun/Packages/<id>/{current,previous,staged}/` | Must | 0.3 | #027, #037 |
| FR-PKG-05 | Install split APKs (base + several splits) in a single PackageInstaller session | Must | 0.3 | #042 |
| FR-PKG-06 | Import common split-set containers such as `.apks` / `.xapk` in addition to `.apk` | Should | 0.3 | #073 |
| FR-PKG-07 | Uninstall, with the choice of keeping or deleting data and deleting the wrapper | Must | 0.4 | #027, #076 |

### 1.7 Updates (FR-UPD)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-UPD-01 | Each package has exactly one update authority (apkrun / googlePlay / external / manual) | Must | 0.3 | #037, #039 |
| FR-UPD-02 | Separate the update source (`UpdateProvider`) from update ownership (authority) | Must | 0.3 | #037 |
| FR-UPD-03 | LocalProvider can test v1 → v2 detect / download / update without Internet | Must | 0.3 | #037 |
| FR-UPD-04 | Before install, verify package ID / increasing versionCode / signing lineage / ABI / SDK / split consistency / SHA-256. No signature-verification bypass. | Must | 0.3 | #041 |
| FR-UPD-05 | Always refuse downgrades. No setting, flag, or provider allows one. Only the binary rollback of FR-UPD-11 restores an older version | Must | 0.3 | #041 |
| FR-UPD-06 | Request update ownership at first install for APKRun-owned packages (API 34+) | Must | 0.3 | #039 |
| FR-UPD-07 | Never install while the app is in use; apply when idle / after exit (gentle update) | Must | 0.3 | #040 |
| FR-UPD-08 | Never make launch wait for an update check. Checks are asynchronous and periodic (default 6 h). | Must | 0.3 | #074 |
| FR-UPD-09 | Per-package update mode: Automatic / Notify only / Manual | Must | 0.4 | #074, #079 |
| FR-UPD-10 | Post-update health check (PackageManager version → launch → process exists → first frame) | Must | 0.3 | #043 |
| FR-UPD-11 | On health-check failure, restore the previous APK set (binary rollback): Android's RollbackManager on custom images, a downgrade reinstall on debuggable images. A restore that erases app data runs only after the user confirms it. App data is never rolled back | Must | 0.3 | #043 |
| FR-UPD-12 | DirectProvider (APKRun manifest published by the distributor) | Must | 0.3 | #050 |
| FR-UPD-13 | F-Droid provider / GitHub Releases provider | Must | 0.5 | #051, #052 |
| FR-UPD-14 | Final update decisions use packageName / versionCode / signature from inside the APK, not provider metadata | Must | 0.3 | #041, #052 |
| FR-UPD-15 | Install an update as an in-place upgrade of the installed package through a `PackageInstaller` session, keeping the app's data. A newer APK that the user supplies is a manual update through the same path | Must | 0.3 | #038 |

### 1.8 Wrappers (FR-WRP)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-WRP-01 | `apkrun wrap app.apk` generates a thin `.app` | Must | 0.4 | #045, #046, #075 |
| FR-WRP-02 | Options `--install` / `--updates` / `--update-provider` / `--update-url` / `--output` / `--portable` | Must (portable: Should) | 0.4 | #075, #089 |
| FR-WRP-03 | A wrapper holds only the package ID and initial preferences; never the APK version or path | Must | 0.4 | #045, #048 |
| FR-WRP-04 | APK updates never change anything inside the wrapper bundle (no re-signing needed) | Must | 0.4 | #049 |
| FR-WRP-05 | Bundle IDs are generated deterministically as `io.apkrun.android.<mapped package>` | Must | 0.4 | #045 |
| FR-WRP-06 | Every wrapper uses the same `APKRunLauncher` executable | Must | 0.4 | #044 |
| FR-WRP-07 | Convert Android icons (adaptive / legacy) to macOS icons | Must | 0.4 | #055 |
| FR-WRP-08 | Launchable from Finder / Dock / Spotlight / Launchpad | Must | 0.4 | #056 |
| FR-WRP-09 | Show an actionable error when the runtime is missing or incompatible (`runtime.minimumVersion`) | Must | 0.4 | #044 |
| FR-WRP-10 | Local wrappers use local / ad-hoc signing; distribution wrappers use Developer ID + Hardened Runtime + notarization | Must (distribution: Should) | 0.4 / 1.0 | #046, #088 |
| FR-WRP-11 | The wrapper keeps working after the original APK file is deleted | Must | 0.4 | #048 |
| FR-WRP-12 | Detect deleted / moved wrappers and show / clean up that state in APKRun.app | Should | 0.4 | #076 |
| FR-WRP-13 | Change display name and icon (wrapper metadata update) independently of APK updates | Should | 0.4 | #076 |

### 1.9 Desktop integration (FR-INT)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-INT-01 | Bidirectional plain-text clipboard sync with feedback-loop prevention | Must | 0.2 | #053 |
| FR-INT-02 | Image clipboard | Should | 0.5 | #080 |
| FR-INT-03 | Show Android notifications as macOS notifications; clicking brings the app forward or launches it | Must | 0.5 | #054 |
| FR-INT-04 | http(s) URLs opened by Android apps open in the default macOS browser, and `mailto` links in the default Mac mail app | Should | 0.5 | #081 |
| FR-INT-05 | Only the shared folder (`APKRun/Shared/`) and user-selected directories are exposed to the guest | Must | 0.5 | #082 |
| FR-INT-06 | File picking (choose Mac files from Android's SAF) and drag & drop | Should | 0.5 | #082 |
| FR-INT-07 | Audio output | Must | 1.0 | #083 |
| FR-INT-08 | Microphone input (user-permissioned) | Should | 1.0 | #084 |
| FR-INT-09 | Reflect host locale / time zone / clock in the guest | Should | 0.5 | #085 |
| FR-INT-10 | Camera | Could | 1.x | — |

### 1.10 UI / CLI (FR-UI, FR-CLI)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-UI-01 | APKRun.app home: APK drop area, installed apps (update mode, status), runtime status | Must | 0.4 | #077 |
| FR-UI-02 | Add flow: drop APK → analyze → show name / icon / version → update settings → Install | Must | 0.4 | #078 |
| FR-UI-03 | Per-app settings: name & icon / window (default size, resizable, always on top) / integration (clipboard, notifications, files, microphone, camera) / updates (mode, provider) | Must | 0.4 | #079 |
| FR-UI-04 | Store UI: Android version per app, update status, `Update Now` | Must | 0.4 | #077 |
| FR-UI-05 | Menu bar: runtime status, number of running apps, available updates, Open APKRun, Quit Runtime | Should | 0.5 | #086 |
| FR-UI-06 | Double-clicking an `.apk` opens APKRun's add flow | Should | 0.4 | #078 |
| FR-CLI-01 | `install / wrap / launch / stop / list / info / update / uninstall / doctor / diagnostics` | Must | 0.1–0.4 | [../02-design/cli.md](../02-design/cli.md) |
| FR-CLI-02 | CLI errors include actionable remediation | Must | 0.1 | #061 |

### 1.11 Operations / diagnostics (FR-OPS)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| FR-OPS-01 | `apkrun doctor` distinguishes runtime stopped / Android boot failure / graphics failure / guest agent unavailable / healthy | Must | 0.5 | #059 |
| FR-OPS-02 | `apkrun diagnostics` produces a secret-free ZIP plus a human-readable summary, even after a boot failure | Must | 0.5 | #060 |
| FR-OPS-03 | Signed updates for APKRun itself (the runtime) | Must | 0.5 | #057 |
| FR-OPS-04 | Distribute, verify, apply, and roll back runtime images | Must | 0.5 | #087 |
| FR-OPS-05 | Performance markers for the main lifecycle events ([../02-design/diagnostics.md](../02-design/diagnostics.md) §4) | Must | 0.1+ | #061, #070 |
| FR-OPS-06 | A compatibility database ships with APKRun: known per-app settings (for example the window mode) apply without user setup, match only the recorded signer and version range, and never override a user's explicit choice | Must | 1.0 | #090 |
| FR-OPS-07 | First-run setup and Reset Android: a new user gets a `ready` runtime from APKRun.app without a terminal (host requirements check, background service approval, image install, first boot, verification), an interrupted setup resumes at the step where it stopped, and **Reset Android** gives a fresh userdata and reinstalls every managed package ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9) | Must | 0.2 | #066 |

---

## 2. Non-functional requirements

### 2.1 Performance (NFR-PERF)

**Provisional targets.** Revise them from measurements when G3 / G6 pass, and record each revision as an ADR. The numeric targets are measured from v0.2 (#070) and must be met at v1.0 ([../04-plan/roadmap.md](../04-plan/roadmap.md) §3.6 criterion 2).

| ID | Metric | Provisional target | How measured | Pri | Ver | Task |
|---|---|---|---|---|---|---|
| NFR-PERF-01 | **Primary KPI:** warm state, Mac app click → first Android frame | p50 ≤ 1.5 s, p95 ≤ 3 s (HelloText) | #070 harness | Must | 1.0 | #031, #047, #070 |
| NFR-PERF-02 | Cold state (VM stopped), click → first frame | p50 ≤ 40 s initially; to be reduced later. VM state save/restore cannot be used while VirGL is active (R-07), so the reduction comes from boot-time trimming measured with the perf harness (#070) | same | Must | 1.0 | #047, #070 |
| NFR-PERF-03 | Input latency (NSEvent received → injected into guest) | p95 ≤ 16 ms | InputCore signposts | Must | 1.0 | #024, #070 |
| NFR-PERF-04 | HelloGL frame rate (one window, ≤ 1080×2400) | ≥ 55 fps average | GraphicsCore frame stats | Must | 1.0 | #023, #070 |
| NFR-PERF-05 | CPU readbacks on the normal frame path | **0** | readback counter | Must | 0.1 | #023 |
| NFR-PERF-06 | `apkrund` CPU while no app runs and the VM is paused | < 1 % | Activity Monitor / `top` | Must | 1.0 | #069, #070 |
| NFR-PERF-07 | Launch delay caused by update checks | 0 ms (no synchronous update check on the launch path) | code review + measurement | Must | 0.3 | #074 |

### 2.2 Resources (NFR-RES)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| NFR-RES-01 | VM defaults to 4 vCPUs / 4 GiB memory, configurable, capped at 50 % of physical memory | Must | 0.1 | #002, #066 |
| NFR-RES-02 | userdata is a sparse file on APFS; only the used size consumes disk | Must | 0.1 | #011, #066 |
| NFR-RES-03 | A local or distribution wrapper is at most 8 MiB (thin wrapper). A portable wrapper adds its `bootstrap/` APK set on top of that (#089) | Must | 0.4 | #046 |
| NFR-RES-04 | Measured: VM memory / system_server / SurfaceFlinger / zygote / each APK / host graphics memory / `apkrund` RSS | Must | 0.2 | #070 |

### 2.3 Security (NFR-SEC)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| NFR-SEC-01 | APK code is untrusted | Must | 0.1 | every task; reviewed by #091 |
| NFR-SEC-02 | Never automatically expose the whole home directory, `~/.ssh`, `~/Library`, or `~/Documents` to the guest | Must | 0.5 | #082 |
| NFR-SEC-03 | Host integrations (clipboard, notifications, files, URLs, microphone) always pass guest agent → policy → host and can be disabled per app | Must | 0.2 | #053, #054, #081, #082, #084 |
| NFR-SEC-04 | No signature-verification bypass, no Play Integrity circumvention | Must | 0.3 | #041 |
| NFR-SEC-05 | Logs never contain secrets, clipboard contents, or app private data | Must | 0.1 | #061, #060 |
| NFR-SEC-06 | ADB is never exposed beyond host loopback | Must | 0.1 | #015 |
| NFR-SEC-07 | XPC clients are validated; a wrapper cannot control packages other than its own | Must | 0.2 | #032, #047 |

Details: [../01-architecture/security-model.md](../01-architecture/security-model.md).

### 2.4 Reliability (NFR-REL)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| NFR-REL-01 | A crash in the middle of an update leaves Package Store and Android state recoverable (transactional state transitions, recovery at startup) | Must | 0.3 | #027, #038 |
| NFR-REL-02 | If `apkrund` crashes, launchd restarts it and clients reconnect | Must | 0.2 | #031 |
| NFR-REL-03 | If a guest agent dies, the host detects it (health) and reconnects | Must | 0.2 | #034 |
| NFR-REL-04 | Never silently continue on a host/guest protocol version mismatch | Must | 0.1 | #033, #034 |
| NFR-REL-05 | Serial logs survive a VM crash | Must | 0.1 | #004 |

### 2.5 Observability (NFR-OBS)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| NFR-OBS-01 | Structured logging (`io.apkrun.<subsystem>`); critical events carry operation ID / package ID / display ID / error domain / error code | Must | 0.1 | #061 |
| NFR-OBS-02 | Every subsystem exposes a health status | Must | 0.5 | #059 |
| NFR-OBS-03 | Users can tell VM / Android boot / graphics / guest agent / package / update failures apart without reading source code | Must | 0.5 | #059 |

### 2.6 Maintainability (NFR-DEV)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| NFR-DEV-01 | Third-party code is pinned by commit (`ThirdParty/ThirdParty.lock.json`); never build from a moving `main` | Must | 0.1 | #020, #062 |
| NFR-DEV-02 | A clean checkout builds and `swift test` passes | Must | 0.1 | #001, #062 |
| NFR-DEV-03 | Errors use typed domains (`enum XxxFailure: Error`) | Must | 0.1 | #061 |
| NFR-DEV-04 | Every temporary workaround carries a TODO, a reason, and a tracking issue | Must | 0.1 | every task |
| NFR-DEV-05 | Experiments live in `Experiments/` or `experiment/*` branches; production modules re-implement the minimum cleanly | Must | 0.1 | every task |

### 2.7 Compatibility (NFR-CMP)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| NFR-CMP-01 | Check with the controlled fixture apps (HelloText and friends) before blaming arbitrary third-party APKs | Must | 0.1 | #016 and the fixture apps |
| NFR-CMP-02 | Define wrapper `formatVersion` and the runtime's supported range; old wrappers keep working with newer runtimes (backward compatibility) | Must | 0.5 | #044, #057 |
| NFR-CMP-03 | Runtime image updates preserve existing userdata (installed apps and their data) | Must | 0.5 | #058 |

### 2.8 Localization / accessibility (NFR-L10N)

| ID | Requirement | Pri | Ver | Task |
|---|---|---|---|---|
| NFR-L10N-01 | APKRun.app and CLI messages support English and Japanese (String Catalogs) | Must | 1.0 | #092 |
| NFR-L10N-02 | APKRun.app UI is operable with VoiceOver (accessibility inside Android apps is out of scope) | Must | 1.0 | #092 |
