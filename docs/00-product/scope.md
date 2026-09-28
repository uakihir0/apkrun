# Scope and Non-Goals

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [requirements.md](requirements.md), [../04-plan/roadmap.md](../04-plan/roadmap.md) |

---

## 1. Target platforms

| Area | Target | Notes |
|---|---|---|
| Host CPU | Apple Silicon only | M1 and later. Development aids that need nested virtualization require M3 or later. |
| Host OS | macOS 27 or later | Required by the custom virtio device API (verified to exist; residual limits in risk R-01). |
| Guest | Android ARM64 (AOSP Cuttlefish based) | Prefer the newest obtainable release line. **Minimum API 34** (required for update ownership and InstallConstraints). |
| Guest ABI | `arm64-v8a` | `armeabi-v7a` may work incidentally if the guest image ships 32-bit support, but it is not guaranteed. |
| Graphics API | OpenGL ES (through VirGL) | Vulkan is not a v1 blocker. |
| AOSP build host | 64-bit Linux (x86_64) | AOSP is never built on macOS. |

---

## 2. In scope for v1

| Area | Provided in v1 |
|---|---|
| Execution | Resident Android VM, cold/warm launch, several apps at once (1 app = 1 window) |
| Display | GPU acceleration (GLES), Retina support, one Android display per window |
| Input | Mouse → touch, scrolling, keyboard, shortcuts, IME text input including Japanese (committed text from the host IME) |
| Packages | APK / split APK install, update, and uninstall; signature verification; binary rollback |
| Updates | Automatic / notify-only / manual; gentle updates; Local / Direct / F-Droid / GitHub providers |
| Wrappers | `.app` generation, icon conversion, Dock / Spotlight / Launchpad integration, local signing |
| Integration | Clipboard (text, then image), notifications, URLs (Android → Mac browser), files (shared folder / file picker), audio output, microphone |
| Operations | `apkrun doctor`, diagnostics bundle, runtime updates, guest image updates |
| UI | APKRun.app (home / add / settings), menu bar extra |

---

## 3. Not guaranteed in v1 (initial non-goals)

Merged from and. **Do not add support for any of these unless an issue explicitly asks for it.**

| Non-goal | Reason |
|---|---|
| Intel Macs | Virtualization.framework ARM64 guests only |
| x86 / x86_64-only APKs | No ARM translation, and we will not bring one in |
| ARM translation (houdini, ndk_translation, …) | Out of scope; licensing is also complicated |
| Windows / Linux hosts | macOS-only product |
| Apps that depend on Google Play Integrity | No GMS. Integrity bypass will **never** be implemented. |
| Google Play certification / bundled GMS | Only considered as an optional, isolated Phase 22 |
| Banking apps and similar strong tamper detection | Root/emulator detection and Integrity dependence |
| Strong DRM (for example Widevine L1) | Hardware DRM cannot be provided |
| Competitive anti-cheat | Emulator detection |
| Vulkan-only games | VirGL has no Vulkan. Evaluated in Phase 21. |
| Hardware-specific APIs (NFC, UWB, fingerprint, most sensors, telephony) | Not present in a virtual machine |
| Android Automotive / TV / Wear-only apps | Phone form factor only |
| Camera | Not in the v1.0 candidate list; v1.x or later |
| Full application data rollback | Only APK binary rollback is guaranteed; DB migrations cannot be reversed |
| Standalone Mode (runtime embedded in the `.app`) | Size, duplication, image updates, and notarization get complicated. Not implemented in v1. |
| Trackpad gestures (pinch, rotate, …) | Deferred (v1.x) |

---

## 4. Compatibility levels

Internally there are four levels (for a future per-app compatibility database). Users see a simplified three-level version.

| Internal level | Meaning | User-facing label |
|---|---|---|
| `nativeLike` | Fully works on a secondary display; integrations (notifications, clipboard, …) work | **Works** |
| `compatible` | Works, but some integrations do not | **Works with limitations** |
| `compatibilityMode` | Works only in `primaryDisplayCompatibility` window mode | **Works with limitations** |
| `unsupported` | Does not start, or has unsupported requirements (Integrity, x86-only, …) | **Unsupported** |

The compatibility database itself is a v1.0 candidate (#090).

---

## 5. Scope discipline (applies to every issue)

- An Android boot issue must not **also** add wrapper UI, the automatic updater, Google Play, or Vulkan.
- Keep technical risks isolated per issue.
- If finishing an issue needs a major scope expansion, **stop and create a follow-up issue**.
- Do not skip the development order because a later task looks easier or more interesting ([../04-plan/roadmap.md](../04-plan/roadmap.md) §1).
