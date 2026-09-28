# Security Model

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [process-model-and-ipc.md](process-model-and-ipc.md), [../02-design/update-system.md](../02-design/update-system.md), [../02-design/desktop-integration.md](../02-design/desktop-integration.md), [../02-design/wrapper.md](../02-design/wrapper.md) |

---

## 1. Assets

| Asset | Why it matters |
|---|---|
| Android user data (`userdata.img`) | Contains the user's accounts, messages, and tokens for every Android app |
| Host files | Must not be readable by Android apps unless shared by policy |
| Clipboard contents | Frequently contains secrets |
| Installed package integrity | A malicious "update" could replace a trusted app with attacker code that inherits its data |
| The apkrund control API | Controls installs, the VM, host integrations |
| Signing keys (APKRun Developer ID, Sparkle EdDSA key, runtime image signing key, platform key of the custom image) | Compromise means we can ship malicious updates |

## 2. Trust boundaries

```text
[ macOS user session ]
├── APKRun.app / MenuBar / CLI trusted (our signature)
├── Wrapper launchers trusted *per registered cdhash* (generated locally)
├── Other user processes untrusted → only the broker interface
└── apkrund trusted, holds `com.apple.security.virtualization`
    └── presents virtio devices and accepts vsock connections from the guest
[ Android VM ] untrusted as a whole (runs arbitrary APKs)
├── APKRun agents (platform-signed) semi-trusted: their messages are still validated
└── Third-party apps untrusted
[ Network ]
├── Update providers supply untrusted content, verified by signature or hash
└── Runtime image / Sparkle feeds trusted only after signature verification
```

**Principle: the host never trusts the guest.** Every GuestProtocol message is length-checked, schema-validated, and rate-limited. The virtio-gpu device model treats all guest-provided offsets, lengths, and resource IDs as hostile (bounds checks before every memory access, `VZVirtioQueueElement` TOCTOU guidance: copy descriptors into host memory before validating, then use only the copy).

## 3. Host-side controls

### 3.1 apkrund API access

- Broker plus per-capability anonymous endpoints with code-signing requirements ([process-model-and-ipc.md](process-model-and-ipc.md) §2.2).
- A wrapper can only open sessions for the package recorded for its bundle ID in the wrapper registry. It cannot install, uninstall, or change settings.
- A wrapper that is not in the registry (copied from another Mac, or a downloaded distribution wrapper) must be approved once in APKRun.app. Approval records its cdhash.
- The CLI has full control capabilities (it is part of APKRun.app's signature). Destructive CLI operations (`uninstall`, `runtime reset`, `image rollback`) ask for confirmation unless `--yes` is given.

### 3.2 Entitlements and signing

| Binary | Entitlements | Signing |
|---|---|---|
| APKRun.app | App Sandbox **off** (it needs `~/Applications`, LaunchServices registration, and arbitrary file import). Hardened Runtime on. | Developer ID (release), ad-hoc/development (dev) |
| apkrund | `com.apple.security.virtualization`; `com.apple.security.device.audio-input` from #084 (the Hardened Runtime needs it for the microphone). Hardened Runtime on. No `disable-library-validation`: VirGL/ANGLE dylibs are signed with the same team ID. | same |
| APKRunLauncher.app (generic launcher; its executable is the wrapper template) | none. Hardened Runtime on. arm64 only, system frameworks only | same as APKRun. The copy in each local wrapper is re-signed ad-hoc |
| APKRunMenuBar.app | none. Hardened Runtime on. | same as APKRun |
| `apkrun` CLI, Release | none. It is a client only. | same as APKRun |
| `apkrun` CLI, Debug (`io.apkrun.cli.dev`, built with `APKRUN_EMBEDDED_RUNTIME`) | `com.apple.security.virtualization`, for the embedded runtime of `apkrun dev` | development signing only; never shipped |
| APKRunTestHost (`io.apkrun.testhost`, Debug only) | `com.apple.security.virtualization`, so T2 tests can start a VM | development signing only; never shipped |
| Distribution wrappers | none | Developer ID + notarized (#088) |

Bridged networking (`com.apple.vm.networking`) is a restricted entitlement and is not used. Only NAT networking is used. The entitlement files are listed in [../05-development/build-system.md](../05-development/build-system.md) §12.2; adding an entitlement changes this table in the same pull request.

### 3.3 Local wrapper signing

- The launcher is copied, then the bundle is signed with `codesign --force --sign - --identifier <wrapperBundleID> --options runtime --timestamp=none` (no `--deep`; the bundle has no nested code). Signing is the last write to the bundle ([../02-design/wrapper.md](../02-design/wrapper.md) §7.1).
- Local wrappers created by APKRun do not get `com.apple.quarantine` (they were never downloaded), so Gatekeeper does not block them. APKRun never removes quarantine from files it did not create.
- The wrapper registry records the cdhash. If a wrapper's cdhash changes, apkrund refuses its session endpoint (NFR-SEC-07). A bundle with a valid signature (for example a wrapper from another Mac) can be approved by the user. A bundle whose seal is broken (edited after signing) cannot be approved and must be created again ([../02-design/wrapper.md](../02-design/wrapper.md) §7.3).
- Authorization always uses the registry's package ID for the bundle ID. `wrapper.json` and Info.plist are never trusted for it, so editing them cannot give a wrapper access to another package.

## 4. Guest-side controls

| Control | Detail |
|---|---|
| Agent identities | `io.apkrun.guest` and `io.apkrun.store` are platform-signed on the custom image. Their SELinux domains are `apkrun_guest_app` and `apkrun_store_app`, assigned via `seapp_contexts` by package name *and* signing seinfo (`platform`). |
| vsock | Only `apkrun_vsockd` (and adbd when developer mode is on) may use vsock. Third-party apps cannot reach the host at all except through normal NAT networking. |
| Agent sockets | Abstract Unix sockets. Only `apkrun_vsockd` may `connectto` (SELinux), plus a `SO_PEERCRED` uid check. |
| Privileged operations | For example: input injection (`INJECT_EVENTS`), launching on any display (`INTERNAL_SYSTEM_WINDOW`), install without user action (`INSTALL_PACKAGES`), update ownership (`ENFORCE_UPDATE_OWNERSHIP`), per-package microphone gating (`MANAGE_APP_OPS_MODES`), and the package names of active recordings (`MODIFY_AUDIO_ROUTING`). They are granted through `privapp-permissions-apkrun.xml` only to the agents that need them. The full list, with the API each permission is for, is [../02-design/guest-components.md](../02-design/guest-components.md) §5. |
| Developer mode | ADB (`adbd` on vsock 5555) is off by default on production images. Turning it on requires user action in APKRun settings and is shown in the menu bar. |
| Development images | Stock Cuttlefish `userdebug` images have ADB on and are unlocked (`verifiedbootstate=orange`). They are for development only. `apkrun doctor` warns if one is used as the user's runtime. |

## 5. Package integrity (updates)

The validation pipeline is mandatory before staging. The design lives in [../02-design/update-system.md](../02-design/update-system.md) §6. Rules 3–6 (the checks that depend only on the artifact) also run on every first install as the intrinsic checks I1–I12 of [../02-design/package-store.md](../02-design/package-store.md) §4.6. The host verifier is an early check, not the final one: Android verifies every install, and the Store Agent re-checks package, version, and signer before commit ([../02-design/package-store.md](../02-design/package-store.md) §4.5):

1. **Package ID** equals the installed package.
2. **versionCode** is greater than installed (`longVersionCode` compare). Downgrades only happen through rollback, which uses Android's `RollbackManager` (custom images) or a debuggable build's downgrade reinstall (development images), never `INSTALL_ALLOW_DOWNGRADE` on user builds.
3. **Signer continuity.** The host verifies the APK signature (v2/v3/v3.1, lineage). It accepts only if the new signer equals the current signer, or the lineage proves rotation from the current signer with the `INSTALLED_DATA` capability, or the installed package's lineage contains the new signer with the `ROLLBACK` capability (a rotation being undone). Android's PackageManager enforces the same thing again at install. The host check exists so we never stage something Android would reject, and so we can say why.
4. **Split set** is complete and consistent (same package, versionCode, and signer for every split; exactly one base; unique split names).
5. **ABI** includes `arm64-v8a` or has no native code.
6. **SDK:** `minSdkVersion ≤ guest SDK`, and `targetSdkVersion ≥` the guest floor (Android 15+ blocks targetSdk < 24).
7. **Hash:** SHA-256 equals the provider-declared hash when there is one (Direct, F-Droid, GitHub assets with checksums).
8. **Provider trust:**
   - F-Droid: the index is verified via `entry.jar` (one signer, SHA-256 cert fingerprint pinned per repo).
   - Direct: HTTPS plus the manifest hash. Manifests are not signed in v1. Signed manifests are planned for v1.x (OQ-19, [../04-plan/open-questions.md](../04-plan/open-questions.md)). The APK signer check protects updates either way.
   - GitHub: HTTPS plus the asset digest when published.

## 6. Desktop integration policy

Every integration is limited by default: to the package's own focused window, to an explicit user action, or off. Each one can be turned off per package and globally (FR-INT-*). The full design, including the settings keys, is [../02-design/desktop-integration.md](../02-design/desktop-integration.md).

| Integration | Default | Notes |
|---|---|---|
| Clipboard host → guest | on | The window pushes the pasteboard to the guest only when the user pastes, or when the window becomes key and macOS allows the read without a prompt. There is no background sync. Text in v0.2, images and HTML in v0.5. |
| Clipboard guest → host | on for text | Only while the app's window is focused. The contents are never logged. |
| Notifications | on | Shown as notifications of the wrapper. Content is not logged. |
| Links (guest opens http/https/mailto) | ask, with "Remember" per package | Only `http`, `https`, `mailto`, only from the focused window (or within 5 s of user input), at most 3 per 10 s. Anything else is dropped. The prompt shows the host only. |
| File import (drag & drop into the window) and Save to Mac | on (one user action per transfer) | Dropped files are shared to the app, or saved to Android Downloads when the app accepts no shares. Files leaving Android go only where the user's Save panel says, with a quarantine attribute. |
| Shared folders | off | Opt-in per package, read-only unless the user picks read-write. Only through the Android file picker, served by the host with per-request checks of package and path. No virtio-fs share exists. |
| Microphone | off | The input stream is attached only while some package has it on. Other packages record silence (Android app ops). macOS asks for microphone permission for apkrund. |
| Camera | not supported in v1 | |

Contents of the clipboard, notifications, and files never appear in logs or diagnostics bundles (NFR-SEC-05). The diagnostics redactor also strips account names and anything matching token patterns.

## 7. Secrets and keys

| Key | Storage | Rotation |
|---|---|---|
| Developer ID certificate | Maintainer Keychain / CI secret (notarytool API key) | Apple-driven |
| Sparkle EdDSA private key | Offline + CI secret | Signs APKRun update archives and the appcast. Never rotate together with the Developer ID certificate in the same release (release rule R6). A new key ships in a release signed with the old one ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §10) |
| Runtime image signing key (Ed25519, for image manifests and the image feed) | Offline + CI secret | Key ID in the manifest and in `feed.json.sig`. The app trusts a list of key IDs (`ImageTrustStore`). A compromised key ID is removed in an APKRun release |
| AOSP platform/release keys for the custom image | Offline, the image build machine only | Changing them breaks platform-signed agent updates. Treat as permanent. |
| Test keys | `Tests/Fixtures/signing/` (clearly named `test-*`) | Never used for anything shipped |

## 8. Threats and mitigations (summary)

| Threat | Mitigation |
|---|---|
| A local process drives apkrund to install malware or read data | Broker + code-signing requirements. The broker exposes no capabilities. |
| A malicious guest exploits the host virtio-gpu parser | Bounds checks, fuzzing of the command parser (#091), a separate renderer thread, no guest-controlled sizes without limits (RiftVM limits: 8192 px, 256 MiB buffers, 256 contexts). |
| A malicious update replaces a trusted app | Signer continuity check plus update ownership in Android |
| Two updaters fight | One `UpdateAuthority` per package, plus Android update ownership |
| A forged or replayed APKRun update or Android image | Sparkle EdDSA + Developer ID check; image feed signature with sequence and expiry, archive SHA-256, manifest signature, safe extraction ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §10) |
| A guest app exfiltrates the clipboard | Focus-only clipboard sync, per-package policy |
| A tampered wrapper opens another package's data | Session limited to the registry mapping plus a cdhash check |
| Tampered runtime image | Manifest signature plus `SHA256SUMS` verification on install and deep doctor |
| Image or runtime downgrade attack | Monotonic image versions. Rollback is only via local recovery points or the previous image already on disk. |

## 9. Review items (#091)

#091 reviews every trust boundary before v1.0 and records the result here. Each item names its evidence (a test, a fuzz target, or a review note) and has a status: `open`, `closed`, or `follow-up #NNN`. v1.0 ships only when every item is `closed` or has a follow-up task that is not High impact ([../04-plan/roadmap.md](../04-plan/roadmap.md) §3.6 item 5).

| Item | Boundary | Evidence | Status |
|---|---|---|---|
| SR-01 | The XPC broker and endpoints (§3.1) | filled in by #091 | open |
| SR-02 | Guest → host parsers: virtio-gpu, guest protocol, input | filled in by #091 | open |
| SR-03 | Agent host operations: clipboard, notifications, links, files, microphone (§6) | filled in by #091 | open |
| SR-04 | APK and container parsing, including aapt2 | filled in by #091 | open |
| SR-05 | Provider parsing and the update validation pipeline (§5) | filled in by #091 | open |
| SR-06 | APKRun and image updates ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §10) | filled in by #091 | open |
| SR-07 | Signing, entitlements, and the release checks (§3.2) | filled in by #091 | open |
| SR-08 | The custom image's SELinux, vsock, and privileged permissions (§4) | filled in by #091 | open |
| SR-09 | ADB exposure (§4, NFR-SEC-06) | filled in by #091 | open |
| SR-10 | Secrets in logs and diagnostics bundles (NFR-SEC-05) | filled in by #091 | open |
| SR-11 | Storage of keys and secrets (§7) | filled in by #091 | open |
