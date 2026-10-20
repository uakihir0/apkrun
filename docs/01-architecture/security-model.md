# Security Model

This page defines the trust boundaries of APKRun, the host and guest controls that enforce them, and the review items that must close before v1.0. Every APK is untrusted code. The host never trusts the guest.

---

## 1. Assets

| Asset | Why it matters |
|---|---|
| Android user data (`userdata.img`) | Holds the user's accounts, messages, and tokens for every Android app |
| Host files | Must not be readable by Android apps unless shared by policy |
| Clipboard contents | Frequently contain secrets |
| Installed package integrity | A malicious "update" could replace a trusted app with attacker code that inherits its data |
| The apkrund control API | Controls installs, the VM, and host integrations |
| Signing keys (APKRun Developer ID, Sparkle EdDSA key, runtime image signing key, platform key of the custom image) | Compromise means malicious updates can be shipped |

## 2. Trust boundaries

```text
[ macOS user session ]
   ├─ APKRun.app / MenuBar / CLI          trusted (our signature)
   ├─ Wrapper launchers                   trusted *per registered cdhash* (generated locally)
   ├─ other user processes                untrusted → only the broker interface
   └─ apkrund                             trusted, holds com.apple.security.virtualization
          │  virtio devices, vsock
[ Android VM ]                            untrusted as a whole (runs arbitrary APKs)
   ├─ APKRun agents (platform-signed)     semi-trusted: their messages are still validated
   └─ third-party apps                    untrusted
[ Network ]
   ├─ update providers                    untrusted content, verified by signature/hash
   └─ runtime image / Sparkle feeds       trusted only after signature verification
```

**The host never trusts the guest.** Every GuestProtocol message is length-checked, schema-validated, and rate-limited. The virtio-gpu device model treats every guest-provided offset, length, and resource ID as hostile. It checks bounds before every memory access, and it copies descriptors into host memory before validating them. It then uses only the copy (TOCTOU protection for `VZVirtioQueueElement`).

## 3. Host-side controls

### 3.1 apkrund API access

- The broker and per-capability anonymous endpoints, with code-signing requirements ([process-model-and-ipc.md](process-model-and-ipc.md) §2.2).
- A wrapper opens sessions only for the package its bundle ID maps to in the wrapper registry. It cannot install, uninstall, or change settings.
- A wrapper that is not in the registry (copied from another Mac, or a downloaded distribution wrapper) must be approved once in APKRun.app. Approval records its cdhash.
- The CLI has full control capabilities, because it is part of APKRun.app's signature. Destructive CLI operations (`uninstall`, `runtime reset`, `image rollback`) ask for confirmation unless `--yes` is given.

### 3.2 Entitlements and signing

| Binary | Entitlements | Signing |
|---|---|---|
| APKRun.app | App Sandbox **off** (it needs `~/Applications`, LaunchServices registration, and arbitrary file import). Hardened Runtime on. | Developer ID (release); ad-hoc or development (dev) |
| apkrund | `com.apple.security.virtualization`; `com.apple.security.device.audio-input` (microphone, #85). Hardened Runtime on. No `disable-library-validation`: VirGL and ANGLE dylibs are signed with the same team ID. | Same as APKRun.app |
| APKRunLauncher.app (generic launcher; its executable is the wrapper template) | None. Hardened Runtime on. arm64 only, system frameworks only. | Same as APKRun.app. Each local wrapper's copy is re-signed ad hoc. |
| APKRunMenuBar.app | None. Hardened Runtime on. | Same as APKRun.app |
| `apkrun` CLI, Release | None. It is a client only. | Same as APKRun.app |
| `apkrun` CLI, Debug (`io.apkrun.cli.dev`, built with `APKRUN_EMBEDDED_RUNTIME`) | `com.apple.security.virtualization`, for the embedded runtime of `apkrun dev` | Development signing only; never shipped |
| APKRunTestHost (`io.apkrun.testhost`, Debug only) | `com.apple.security.virtualization`, so T2 tests can start a VM | Development signing only; never shipped |
| Distribution wrappers | None | Developer ID and notarized (#89) |

Bridged networking (`com.apple.vm.networking`) is a restricted entitlement and is not used. Only NAT networking is used. The entitlement files are listed in [build-system.md](../05-development/build-system.md) §12.2. Adding an entitlement changes this table in the same pull request.

### 3.3 Local wrapper signing

- The launcher is copied, and then the bundle is signed with `codesign --force --sign - --identifier <wrapperBundleID> --options runtime --timestamp=none`. There is no `--deep`, because the bundle has no nested code. Signing is the last write to the bundle ([wrapper.md](../02-design/wrapper.md) §7.1).
- Local wrappers created by APKRun do not get `com.apple.quarantine`, so Gatekeeper does not block them. APKRun never removes quarantine from files it did not create.
- The registry records the cdhash. If a wrapper's cdhash changes, apkrund refuses its session endpoint (NFR-SEC-07). A bundle with a valid signature, such as a wrapper from another Mac, can be approved by the user. A bundle whose seal is broken cannot be approved and must be created again ([wrapper.md](../02-design/wrapper.md) §7.3).
- Authorization always uses the registry's package ID for the bundle ID. `wrapper.json` and Info.plist are never trusted for it.

## 4. Guest-side controls

| Control | Detail |
|---|---|
| Agent identities | `io.apkrun.guest` and `io.apkrun.store` are platform-signed on the custom image. Their SELinux domains are `apkrun_guest_app` and `apkrun_store_app`, assigned through `seapp_contexts` by package name and signing seinfo (`platform`). |
| vsock | Only `apkrun_vsockd` (and adbd when developer mode is on) may use vsock. Third-party apps cannot reach the host except through normal NAT networking. |
| Agent sockets | Abstract Unix sockets. Only `apkrun_vsockd` may `connectto` (SELinux), plus a `SO_PEERCRED` uid check. |
| Privileged operations | Input injection (`INJECT_EVENTS`), launching on any display (`INTERNAL_SYSTEM_WINDOW`), install without user action (`INSTALL_PACKAGES`), update ownership (`ENFORCE_UPDATE_OWNERSHIP`), per-package microphone gating (`MANAGE_APP_OPS_MODES`), and the package names of active recordings (`MODIFY_AUDIO_ROUTING`). They are granted through `privapp-permissions-apkrun.xml`, and only to the agents that need them. Full list: [guest-components.md](../02-design/guest-components.md) §5. |
| Developer mode | ADB (`adbd` on vsock 5555) is off by default on production images. Turning it on requires user action in APKRun settings, and the menu bar shows it. |
| Development images | Stock Cuttlefish `userdebug` images have ADB on and are unlocked (`verifiedbootstate=orange`). They are for development only. `apkrun doctor` warns if one is used as the user's runtime. |

## 5. Package integrity (updates)

Every update passes the validation pipeline before staging ([update-system.md](../02-design/update-system.md) §6). Checks 3 to 6, which depend only on the artifact, also run on every first install as the intrinsic checks I1–I12 ([package-store.md](../02-design/package-store.md) §4.6). The host verifier is an early check, not the final one. Android verifies every install, and the Store Agent re-checks package, version, and signer before commit ([package-store.md](../02-design/package-store.md) §4.5).

1. **Package ID** equals the installed package.
2. **versionCode** is greater than the installed one (`longVersionCode` compare). Downgrades happen only through rollback, which uses Android's `RollbackManager` on custom images or a downgrade reinstall on debuggable development images. Never use `INSTALL_ALLOW_DOWNGRADE` on user builds.
3. **Signer continuity.** The host verifies the APK signature (v2, v3, v3.1, and lineage). It accepts only if the new signer equals the current signer, or the lineage proves rotation from the current signer with the `INSTALLED_DATA` capability, or the installed package's lineage contains the new signer with the `ROLLBACK` capability (a rotation being undone). PackageManager enforces the same rule again at install. The host check exists so APKRun never stages what Android would reject, and so it can say why.
4. **Split set** is complete and consistent: same package, versionCode, and signer for every split; exactly one base; unique split names.
5. **ABI** includes `arm64-v8a`, or the package has no native code.
6. **SDK:** `minSdkVersion ≤ guest SDK`, and `targetSdkVersion ≥` the guest floor (Android 15 and later block targetSdk below 24).
7. **Hash:** SHA-256 equals the provider-declared hash when there is one (Direct, F-Droid, and GitHub assets with checksums).
8. **Provider trust:**
   - F-Droid: the index is verified through `entry.jar`, with one signer and an SHA-256 certificate fingerprint pinned per repo.
   - Direct: HTTPS plus the manifest hash. Direct manifests are unsigned in v1; signed manifests are planned for v1.x (OQ-19, [open-questions.md](../04-plan/open-questions.md)). The APK signer check protects updates either way.
   - GitHub: HTTPS plus the asset digest when one is published.

## 6. Desktop integration policy

Every integration is limited by default: to the package's own focused window, to an explicit user action, or off. Each one can be turned off per package and globally (FR-INT-*). The design and settings keys are in [desktop-integration.md](../02-design/desktop-integration.md).

| Integration | Default | Notes |
|---|---|---|
| Clipboard host → guest | on | The window pushes the pasteboard to the guest only when the user pastes, or when the window becomes key and macOS allows the read without a prompt. No background sync. Text in v0.2; images and HTML in v0.5. |
| Clipboard guest → host | on for text | Only while the app's window is focused. Contents are never logged. |
| Notifications | on | Shown as notifications of the wrapper. Content is not logged. |
| Links (guest opens http, https, or mailto) | ask, with "Remember" per package | Only `http`, `https`, and `mailto`; only from the focused window (or within 5 s of user input); at most 3 per 10 s. Anything else is dropped. The prompt shows the host only. |
| File import (drag and drop) and Save to Mac | on (one user action per transfer) | Dropped files go to the app, or to Android Downloads when the app accepts no shares. Files leaving Android go only where the user's Save panel says, with a quarantine attribute. |
| Shared folders | off | Opt-in per package. Read-only unless the user picks read-write. Served through the Android file picker, with per-request checks of package and path. No virtio-fs share exists. |
| Microphone | off | The input stream is attached only while some package has it on. Other packages record silence (Android app ops). macOS asks for microphone permission for apkrund. |
| Camera | not supported in v1 | |

Clipboard, notification, and file contents never appear in logs or diagnostics bundles (NFR-SEC-05). The diagnostics redactor also strips account names and anything that matches token patterns.

## 7. Secrets and keys

| Key | Storage | Rotation |
|---|---|---|
| Developer ID certificate | Keychain or CI secret (notarytool API key) | Apple-driven |
| Sparkle EdDSA private key | Offline and CI secret | Signs APKRun update archives and the appcast. Never rotate together with the Developer ID certificate in the same release (release rule R6). A new key ships in a release signed with the old key ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §10). |
| Runtime image signing key (Ed25519, for image manifests and the image feed) | Offline and CI secret | Key ID in the manifest and in `feed.json.sig`. The app trusts a list of key IDs (`ImageTrustStore`). A compromised key ID is removed in an APKRun release. |
| AOSP platform and release keys for the custom image | Offline, on the image build machine only | Changing them breaks platform-signed agent updates. Treat as permanent. |
| Test keys | `Tests/Fixtures/signing/` (named `test-*`) | Never used for anything shipped |

## 8. Threats and mitigations

| Threat | Mitigation |
|---|---|
| A local process drives apkrund to install malware or read data | Broker and code-signing requirements. The broker exposes no capabilities. |
| A malicious guest exploits the host virtio-gpu parser | Bounds checks; fuzzing of the command parser (#92); a separate renderer thread; limits on guest-controlled sizes: 8192 px, 256 MiB buffers, 256 contexts |
| A malicious update replaces a trusted app | Signer continuity check, plus update ownership in Android |
| Two updaters fight over one package | One `UpdateAuthority` per package, plus Android update ownership |
| A forged or replayed APKRun update or Android image | Sparkle EdDSA and Developer ID check. Image feed signature with sequence and expiry, archive SHA-256, manifest signature, and safe extraction ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §10) |
| A guest app exfiltrates the clipboard | Focus-only clipboard sync, per-package policy |
| A tampered wrapper opens another package's data | Session limited to the registry mapping, plus a cdhash check |
| A tampered runtime image | Manifest signature, plus `SHA256SUMS` verification on install and on deep doctor |
| Image or runtime downgrade | Monotonic image versions. Rollback only through local recovery points or the previous image already on disk. |

## 9. Review items

Task #92 reviews every trust boundary before v1.0. Each item names its evidence (a test, a fuzz target, or a review note) and has a status: `open`, `closed`, or `follow-up #NNN`. v1.0 ships only when every item is `closed`, or has a follow-up task that is not High impact ([roadmap.md](../04-plan/roadmap.md) §3.6, item 5).

| Item | Boundary | Status |
|---|---|---|
| SR-01 | The XPC broker and endpoints (§3.1) | open |
| SR-02 | Guest → host parsers: virtio-gpu, guest protocol, input | open |
| SR-03 | Agent host operations: clipboard, notifications, links, files, microphone (§6) | open |
| SR-04 | APK and container parsing, including aapt2 | open |
| SR-05 | Provider parsing and the update validation pipeline (§5) | open |
| SR-06 | APKRun and image updates ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §10) | open |
| SR-07 | Signing, entitlements, and the release checks (§3.2) | open |
| SR-08 | The custom image's SELinux, vsock, and privileged permissions (§4) | open |
| SR-09 | ADB exposure (§4, NFR-SEC-06) | open |
| SR-10 | Secrets in logs and diagnostics bundles (NFR-SEC-05) | open |
| SR-11 | Storage of keys and secrets (§7) | open |
