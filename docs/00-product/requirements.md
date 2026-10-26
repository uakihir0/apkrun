# Requirements

This document lists every functional (`FR-*`) and non-functional (`NFR-*`) requirement, with its priority, the first version that must satisfy it, and the tasks that deliver it. Each requirement ID appears once.

- **Pri:** **Must** (required by that version's Definition of Done), **Should**, or **Could**.
- **Ver:** the first version that must satisfy the requirement.
- **Tasks:** the tasks that deliver it by that version ([../04-plan/issues/README.md](../04-plan/issues/README.md) §3).

---

## 1. Functional requirements

### 1.1 VM / runtime (FR-VM)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-VM-01 | Boot ARM64 Linux with Virtualization.framework | Must | 0.1 | #3, #4 |
| FR-VM-02 | Show guest serial output live and persist it to disk with rotation | Must | 0.1 | #5 |
| FR-VM-03 | Attach read-only and read-write virtio-blk disks in a deterministic order | Must | 0.1 | #6, #12 |
| FR-VM-04 | Guest resolves DNS and reaches external hosts through NAT networking | Must | 0.1 | #7, #96 |
| FR-VM-05 | Host ↔ guest virtio-vsock communication with timeout and disconnect handling | Must | 0.1 | #8 |
| FR-VM-06 | Expose host-implemented custom virtio devices to the guest | Must | 0.1 | #64, #20 |
| FR-VM-07 | Explicit VM state (stopped / starting / running / paused / stopping / failed) | Must | 0.1 | #3, #4 |
| FR-VM-08 | Boot Android to `sys.boot_completed=1` and stay stable for several minutes | Must | 0.1 | #13–#15, #96 |
| FR-VM-09 | The VM lives in `apkrund` and survives GUI exit while apps are active | Must | 0.2 | #32 |
| FR-VM-10 | Pause the VM after all apps are closed for a configurable time; resume on the next launch request | Should | 0.2 | #70 |
| FR-VM-11 | Handle host sleep and wake correctly for the VM and the guest clock | Should | 0.2 | #70, #86 |

### 1.2 Android image (FR-IMG)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-IMG-01 | Acquire Cuttlefish ARM64 artifacts and generate an inventory manifest without assuming file names | Must | 0.1 | #9 |
| FR-IMG-02 | Describe an image set with `AndroidImageManifest` (no hard-coded file names) | Must | 0.1 | #10 |
| FR-IMG-03 | Extract kernel and ramdisk from boot / init_boot / vendor_boot and assemble bootconfig, never modifying originals | Must | 0.1 | #11 |
| FR-IMG-04 | Map partitions to virtio-blk devices in a data-driven way | Must | 0.1 | #12 |
| FR-IMG-05 | Build the release APKRun image reproducibly from source, signed with APKRun's keys | Must | 1.0 | #120 |
| FR-IMG-06 | Version runtime images; migrate A → B keeping userdata; return to A on failure | Must | 0.5 | #59, #88 |

### 1.3 Graphics and display (FR-GFX, FR-DSP)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-GFX-01 | Implement a standard virtio-gpu device (device ID 16) as a custom virtio device | Must | 0.1 | #20, #22 |
| FR-GFX-02 | Build virglrenderer and ANGLE reproducibly from pinned revisions | Must | 0.1 | #21 |
| FR-GFX-03 | Android renders through VirGL (Mesa); software rendering is not the normal path | Must | 0.1 | #23 |
| FR-GFX-04 | SurfaceFlinger output appears in a macOS window through Metal | Must | 0.1 | #24 |
| FR-GFX-05 | No CPU readback or CPU texture copies on the normal frame path | Must | 0.1 | #24 |
| FR-DSP-01 | One Android display corresponds to one macOS window | Must | 0.2 | #29–#31 |
| FR-DSP-02 | `DisplayPool` allocates, releases, and reuses displays centrally (no hard-coded mappings) | Must | 0.2 | #29 |
| FR-DSP-03 | Two or more apps can be used at the same time in separate windows | Must | 0.2 | #31 |
| FR-DSP-04 | Map the Retina backing scale factor to Android density | Must | 0.1 | #68 |
| FR-DSP-05 | Define the resize policy (fixed or resizable); when resizable, propagate the size to the Android display | Should | 0.2 | #68 |
| FR-DSP-06 | Provide a `primaryDisplayCompatibility` mode for apps that misbehave on secondary displays | Should | 0.4 | #30, #80 |
| FR-DSP-07 | `apkrund` renders; the wrapper process owns the window (shared IOSurface) | Must | 0.2 | #69 |

### 1.4 Input (FR-IN)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-IN-01 | Translate mouseDown, mouseDragged, and mouseUp into touch DOWN, MOVE, and UP | Must | 0.1 | #25 |
| FR-IN-02 | Translate scroll wheel and trackpad scrolling into scroll input | Must | 0.1 | #25 |
| FR-IN-03 | Send key down and up, modifiers, Backspace, Enter, and arrows | Must | 0.1 | #26 |
| FR-IN-04 | Map Esc (and Cmd+[) to Android BACK | Must | 0.1 | #26 |
| FR-IN-05 | Route input only to the display that belongs to the active window | Must | 0.2 | #31 |
| FR-IN-06 | Never spawn a shell command per input event on the production path | Must | 0.1 | #73, #25 |
| FR-IN-07 | Text committed by the macOS IME (including Japanese) reaches Android text fields | Must | 0.2 | #72 |
| FR-IN-08 | Map Cmd+C, V, X, A, and Z to the equivalent Android actions | Should | 0.2 | #26, #72 |
| FR-IN-09 | Trackpad gestures such as pinch | Could | 1.x | — |

### 1.5 Runtime API and daemon (FR-RT)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-RT-01 | Runtime API: `install`, `launch`, `terminate`, `uninstall`, `listInstalled`, `applicationInfo` | Must | 0.1 | #28 |
| FR-RT-02 | All clients (APKRun.app, launcher, CLI, menu bar) use `apkrund` over XPC | Must | 0.2 | #33 |
| FR-RT-03 | In the warm state, go from display allocation to Activity start to first frame without booting the VM | Must | 0.2 | #32, #71 |
| FR-RT-04 | Versioned handshake with guest agents; incompatible major versions are rejected explicitly | Must | 0.2 | #34, #35 |
| FR-RT-05 | ADB is enabled in every development build (on in developer mode, off otherwise). The production control path is vsock ([security-model.md](../01-architecture/security-model.md) §4). | Must | 0.1 | #16, #35 |

### 1.6 Package store (FR-PKG)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-PKG-01 | Never copy APKs into Android package directories; always use `PackageInstaller` | Must | 0.1 | #17, #37 |
| FR-PKG-02 | Android `PackageManager` is canonical for package metadata | Must | 0.3 | #37, #74 |
| FR-PKG-03 | The host can also parse APKs for previews (name, icon, and version shown while the VM is not running) | Should | 0.3 | #74 |
| FR-PKG-04 | Manage the Package Store under `~/Library/Application Support/APKRun/Packages/<id>/{current,previous,staged}/` | Must | 0.3 | #28, #38 |
| FR-PKG-05 | Install split APKs (base plus splits) in a single PackageInstaller session | Must | 0.3 | #43 |
| FR-PKG-06 | Import common split-set containers such as `.apks` and `.xapk` in addition to `.apk` | Should | 0.3 | #74 |
| FR-PKG-07 | Uninstall, with the choice of keeping or deleting data, and delete the wrapper | Must | 0.4 | #28, #77 |

### 1.7 Updates (FR-UPD)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-UPD-01 | Each package has exactly one update authority (apkrun / googlePlay / external / manual) | Must | 0.3 | #38, #40 |
| FR-UPD-02 | Separate the update source (`UpdateProvider`) from update ownership (authority) | Must | 0.3 | #38 |
| FR-UPD-03 | LocalProvider can test v1 → v2 detect, download, and update without Internet | Must | 0.3 | #38 |
| FR-UPD-04 | Before install, verify package ID, increasing versionCode, signing lineage, ABI, SDK, split consistency, and SHA-256. No signature-verification bypass. | Must | 0.3 | #42 |
| FR-UPD-05 | Always refuse downgrades. No setting, flag, or provider allows one. Only the binary rollback of FR-UPD-11 restores an older version. | Must | 0.3 | #42 |
| FR-UPD-06 | Request update ownership at first install for APKRun-owned packages (API 34+) | Must | 0.3 | #40 |
| FR-UPD-07 | Never install while the app is in use; apply when idle or after exit (gentle update) | Must | 0.3 | #41 |
| FR-UPD-08 | Never make launch wait for an update check. Checks are asynchronous and periodic (default 6 h). | Must | 0.3 | #75 |
| FR-UPD-09 | Per-package update mode: Automatic, Notify only, or Manual | Must | 0.4 | #75, #80 |
| FR-UPD-10 | Post-update health check: PackageManager version, launch, process exists, first frame | Must | 0.3 | #44 |
| FR-UPD-11 | On health-check failure, restore the previous APK set (binary rollback): RollbackManager on custom images, a downgrade reinstall on debuggable images. A restore that erases app data runs only after the user confirms it. App data is never rolled back. | Must | 0.3 | #44 |
| FR-UPD-12 | DirectProvider: the APKRun manifest published by the distributor | Must | 0.3 | #51 |
| FR-UPD-13 | F-Droid provider and GitHub Releases provider | Must | 0.5 | #52, #53 |
| FR-UPD-14 | Final update decisions use packageName, versionCode, and signature from inside the APK, not provider metadata | Must | 0.3 | #42, #53 |
| FR-UPD-15 | Install an update as an in-place upgrade through a `PackageInstaller` session, keeping the app's data. A newer APK that the user supplies is a manual update through the same path. | Must | 0.3 | #39 |

### 1.8 Wrappers (FR-WRP)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-WRP-01 | `apkrun wrap app.apk` generates a thin `.app` | Must | 0.4 | #46, #47, #76 |
| FR-WRP-02 | Options `--install`, `--updates`, `--update-provider`, `--update-url`, `--output`, `--portable` | Must (portable: Should) | 0.4 | #76, #90 |
| FR-WRP-03 | A wrapper holds only the package ID and initial preferences; never the APK version or path | Must | 0.4 | #46, #49 |
| FR-WRP-04 | APK updates never change anything inside the wrapper bundle (no re-signing needed) | Must | 0.4 | #50 |
| FR-WRP-05 | Bundle IDs are generated deterministically as `io.apkrun.android.<mapped package>` | Must | 0.4 | #46 |
| FR-WRP-06 | Every wrapper uses the same `APKRunLauncher` executable | Must | 0.4 | #45 |
| FR-WRP-07 | Convert Android icons (adaptive and legacy) to macOS icons | Must | 0.4 | #56 |
| FR-WRP-08 | Launchable from Finder, Dock, Spotlight, and Launchpad | Must | 0.4 | #57 |
| FR-WRP-09 | Show an actionable error when the runtime is missing or incompatible (`runtime.minimumVersion`) | Must | 0.4 | #45 |
| FR-WRP-10 | Local wrappers use local or ad-hoc signing; distribution wrappers use Developer ID, Hardened Runtime, and notarization | Must (distribution: Should) | 0.4 / 1.0 | #47, #89 |
| FR-WRP-11 | The wrapper keeps working after the original APK file is deleted | Must | 0.4 | #49 |
| FR-WRP-12 | Detect deleted or moved wrappers and show and clean up that state in APKRun.app | Should | 0.4 | #77 |
| FR-WRP-13 | Change display name and icon (wrapper metadata update) independently of APK updates | Should | 0.4 | #77 |

### 1.9 Desktop integration (FR-INT)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-INT-01 | Bidirectional plain-text clipboard sync with feedback-loop prevention | Must | 0.2 | #54 |
| FR-INT-02 | Image clipboard | Should | 0.5 | #81 |
| FR-INT-03 | Show Android notifications as macOS notifications; clicking brings the app forward or launches it. Apps that rely only on Firebase Cloud Messaging get no push messages while they are not running ([desktop-integration.md](../02-design/desktop-integration.md) §5.3). | Must | 0.5 | #55 |
| FR-INT-04 | http(s) URLs opened by Android apps open in the default macOS browser, and `mailto` links in the default Mac mail app | Should | 0.5 | #82 |
| FR-INT-05 | Only the shared folder (`APKRun/Shared/`) and user-selected directories are exposed to the guest | Must | 0.5 | #83 |
| FR-INT-06 | File picking (choose Mac files from Android's SAF) and drag and drop | Should | 0.5 | #83 |
| FR-INT-07 | Audio output | Must | 1.0 | #84 |
| FR-INT-08 | Microphone input (user-permissioned) | Should | 1.0 | #85 |
| FR-INT-09 | Reflect host locale, time zone, and clock in the guest | Should | 0.5 | #86 |
| FR-INT-10 | Camera | Could | 1.x | — |

### 1.10 UI and CLI (FR-UI, FR-CLI)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-UI-01 | APKRun.app home: APK drop area, installed apps (update mode, status), runtime status | Must | 0.4 | #78 |
| FR-UI-02 | Add flow: drop APK, analyze, show name, icon, and version, choose update settings, Install | Must | 0.4 | #79 |
| FR-UI-03 | Per-app settings: name and icon; window (default size, resizable, always on top); integration (clipboard, notifications, files, microphone, camera); updates (mode, provider) | Must | 0.4 | #80 |
| FR-UI-04 | Store UI: Android version per app, update status, `Update Now` | Must | 0.4 | #78 |
| FR-UI-05 | Menu bar: runtime status, number of running apps, available updates, Open APKRun, Quit Runtime | Should | 0.5 | #87 |
| FR-UI-06 | Double-clicking an `.apk` opens APKRun's add flow | Should | 0.4 | #79 |
| FR-CLI-01 | `install`, `wrap`, `launch`, `stop`, `list`, `info`, `update`, `uninstall`, `doctor`, `diagnostics` | Must | 0.1–0.4 | [cli.md](../02-design/cli.md) |
| FR-CLI-02 | CLI errors include actionable remediation | Must | 0.1 | #62 |

### 1.11 Operations and diagnostics (FR-OPS)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| FR-OPS-01 | `apkrun doctor` distinguishes runtime stopped, Android boot failure, graphics failure, guest agent unavailable, and healthy | Must | 0.5 | #60 |
| FR-OPS-02 | `apkrun diagnostics` produces a secret-free ZIP and a human-readable summary, even after a boot failure | Must | 0.5 | #61 |
| FR-OPS-03 | Signed updates for APKRun itself (the runtime) | Must | 0.5 | #58 |
| FR-OPS-04 | Distribute, verify, apply, and roll back runtime images | Must | 0.5 | #88 |
| FR-OPS-05 | Performance markers for the main lifecycle events ([diagnostics.md](../02-design/diagnostics.md) §4) | Must | 0.1+ | #62, #71 |
| FR-OPS-06 | A compatibility database ships with APKRun. Known per-app settings (for example the window mode) apply without user setup, match only the recorded signer and version range, and never override a user's explicit choice. | Must | 1.0 | #91 |
| FR-OPS-07 | First-run setup and Reset Android. A new user gets a `ready` runtime from APKRun.app without a terminal: host requirements check, background service approval, image install, first boot, verification. An interrupted setup resumes at the step where it stopped. **Reset Android** gives a fresh userdata and reinstalls every managed package ([runtime-daemon.md](../02-design/runtime-daemon.md) §9). | Must | 0.2 | #67 |

---

## 2. Non-functional requirements

### 2.1 Performance (NFR-PERF)

**Provisional targets.** Revise them from measurements when G3 and G6 pass, and record each revision as an ADR. The numeric targets are measured from v0.2 (#71) and must be met at v1.0 ([roadmap.md](../04-plan/roadmap.md) §3.6, criterion 2).

| ID | Metric | Provisional target | How measured | Pri | Ver | Tasks |
|---|---|---|---|---|---|---|
| NFR-PERF-01 | **Primary KPI:** warm state, Mac app click to first Android frame | p50 ≤ 1.5 s, p95 ≤ 3 s (HelloText) | #71 harness | Must | 1.0 | #32, #48, #71 |
| NFR-PERF-02 | Cold state (VM stopped), click to first frame | p50 ≤ 40 s initially. Reduced later by boot-time trimming, measured with #71. VM save and restore cannot be used while VirGL is active (R-07). | same | Must | 1.0 | #48, #71 |
| NFR-PERF-03 | Input latency (NSEvent received to injected into guest) | p95 ≤ 16 ms | InputCore signposts | Must | 1.0 | #25, #71 |
| NFR-PERF-04 | HelloGL frame rate (one window, ≤ 1080×2400) | ≥ 55 fps average | GraphicsCore frame stats | Must | 1.0 | #24, #71 |
| NFR-PERF-05 | CPU readbacks on the normal frame path | **0** | readback counter | Must | 0.1 | #24 |
| NFR-PERF-06 | `apkrund` CPU while no app runs and the VM is paused | < 1 % | Activity Monitor or `top` | Must | 1.0 | #70, #71 |
| NFR-PERF-07 | Launch delay caused by update checks | 0 ms (no synchronous update check on the launch path) | code review and measurement | Must | 0.3 | #75 |

### 2.2 Resources (NFR-RES)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| NFR-RES-01 | VM defaults to 4 vCPUs and 4 GiB memory, configurable, capped at 50 % of physical memory | Must | 0.1 | #3, #67 |
| NFR-RES-02 | userdata is a sparse file on APFS; only the used size consumes disk | Must | 0.1 | #12, #67 |
| NFR-RES-03 | A local or distribution wrapper is at most 8 MiB. A portable wrapper adds its `bootstrap/` APK set on top of that (#90). | Must | 0.4 | #47 |
| NFR-RES-04 | Measured: VM memory, system_server, SurfaceFlinger, zygote, each APK, host graphics memory, `apkrund` RSS | Must | 0.2 | #71 |

### 2.3 Security (NFR-SEC)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| NFR-SEC-01 | APK code is untrusted | Must | 0.1 | every task; reviewed by #92 |
| NFR-SEC-02 | Never automatically expose the whole home directory, `~/.ssh`, `~/Library`, or `~/Documents` to the guest | Must | 0.5 | #83 |
| NFR-SEC-03 | Host integrations (clipboard, notifications, files, URLs, microphone) always pass guest agent → policy → host and can be disabled per app | Must | 0.2 | #54, #55, #82, #83, #85 |
| NFR-SEC-04 | No signature-verification bypass and no Play Integrity circumvention | Must | 0.3 | #42 |
| NFR-SEC-05 | Logs never contain secrets, clipboard contents, or app private data | Must | 0.1 | #62, #61 |
| NFR-SEC-06 | ADB is never exposed beyond host loopback | Must | 0.1 | #16 |
| NFR-SEC-07 | XPC clients are validated; a wrapper cannot control packages other than its own | Must | 0.2 | #33, #48 |

Details: [security-model.md](../01-architecture/security-model.md).

### 2.4 Reliability (NFR-REL)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| NFR-REL-01 | A crash in the middle of an update leaves Package Store and Android state recoverable (transactional state transitions, recovery at startup) | Must | 0.3 | #28, #39 |
| NFR-REL-02 | If `apkrund` crashes, launchd restarts it and clients reconnect | Must | 0.2 | #32 |
| NFR-REL-03 | If a guest agent dies, the host detects it (health) and reconnects | Must | 0.2 | #35 |
| NFR-REL-04 | Never silently continue on a host/guest protocol version mismatch | Must | 0.1 | #34, #35 |
| NFR-REL-05 | Serial logs survive a VM crash | Must | 0.1 | #5 |

### 2.5 Observability (NFR-OBS)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| NFR-OBS-01 | Structured logging (`io.apkrun.<subsystem>`). Critical events carry operation ID, package ID, display ID, error domain, and error code. | Must | 0.1 | #62 |
| NFR-OBS-02 | Every subsystem exposes a health status | Must | 0.5 | #60 |
| NFR-OBS-03 | Users can tell VM, Android boot, graphics, guest agent, package, and update failures apart without reading source code | Must | 0.5 | #60 |

### 2.6 Maintainability (NFR-DEV)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| NFR-DEV-01 | Third-party code is pinned by commit (`ThirdParty/ThirdParty.lock.json`); never build from a moving `main` | Must | 0.1 | #21, #63 |
| NFR-DEV-02 | A clean checkout builds and `swift test` passes | Must | 0.1 | #2, #63 |
| NFR-DEV-03 | Errors use typed domains (`enum XxxFailure: Error`) | Must | 0.1 | #62 |
| NFR-DEV-04 | Every temporary workaround carries a TODO, a reason, and a tracking issue | Must | 0.1 | every task |
| NFR-DEV-05 | Experiments live in `Experiments/` or `experiment/*` branches; production modules re-implement the minimum cleanly | Must | 0.1 | every task |

### 2.7 Compatibility (NFR-CMP)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| NFR-CMP-01 | Check with the controlled fixture apps (HelloText and friends) before blaming arbitrary third-party APKs | Must | 0.1 | #17 and the fixture apps |
| NFR-CMP-02 | Define wrapper `formatVersion` and the runtime's supported range; old wrappers keep working with newer runtimes | Must | 0.5 | #45, #58 |
| NFR-CMP-03 | Runtime image updates preserve existing userdata (installed apps and their data) | Must | 0.5 | #59 |

### 2.8 Localization and accessibility (NFR-L10N)

| ID | Requirement | Pri | Ver | Tasks |
|---|---|---|---|---|
| NFR-L10N-01 | APKRun.app and CLI messages support English and Japanese (String Catalogs) | Must | 1.0 | #93 |
| NFR-L10N-02 | APKRun.app UI is operable with VoiceOver (accessibility inside Android apps is out of scope) | Must | 1.0 | #93 |
