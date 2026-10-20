# Scope and Non-Goals

This document lists the target platforms, what v1 includes and excludes, the compatibility levels, and the rules for changing scope. Requirements are in [requirements.md](requirements.md).

---

## 1. Target platforms

| Area | Target | Notes |
|---|---|---|
| Host CPU | Apple silicon only | M1 and later. Development aids that need nested virtualization require M3 or later. |
| Host OS | macOS 27 or later | Required by the custom virtio device API. Residual limits: R-01 in [risks.md](../04-plan/risks.md). |
| Guest | Android ARM64, AOSP Cuttlefish based | Prefer the newest obtainable release line. **Minimum API 34** (update ownership and InstallConstraints). |
| Guest ABI | `arm64-v8a` | `armeabi-v7a` may work by chance if the guest image ships 32-bit support. It is not guaranteed. |
| Graphics API | OpenGL ES through VirGL | Vulkan is not a v1 blocker. |
| AOSP build host | 64-bit Linux (x86_64) | AOSP is never built on macOS. |

---

## 2. In scope for v1

| Area | Provided in v1 |
|---|---|
| Execution | Resident Android VM, cold and warm launch, several apps at once (1 app = 1 window) |
| Display | GPU acceleration (GLES), Retina support, one Android display per window |
| Input | Mouse as touch, scrolling, keyboard, shortcuts, IME text input including Japanese (committed text from the host IME) |
| Packages | APK and split APK install, update, and uninstall; signature verification; binary rollback |
| Updates | Automatic, notify-only, and manual; gentle updates; Local, Direct, F-Droid, and GitHub providers |
| Wrappers | `.app` generation, icon conversion, Dock, Spotlight, and Launchpad integration, local signing |
| Integration | Clipboard (text, then image), notifications, URLs (Android to Mac browser), files (shared folder and file picker), audio output, microphone |
| Operations | `apkrun doctor`, diagnostics bundle, runtime updates, guest image updates |
| UI | APKRun.app (home, add, settings), menu bar extra |

---

## 3. Not guaranteed in v1

The following are outside the v1 scope. **Do not add support for any of them unless an issue explicitly asks for it.**

| Non-goal | Reason |
|---|---|
| Intel Macs | Virtualization.framework ARM64 guests only |
| x86 and x86_64-only APKs | No ARM translation, and none will be added |
| ARM translation (houdini, ndk_translation) | Out of scope; licensing is complicated |
| Windows and Linux hosts | macOS-only product |
| Apps that depend on Google Play Integrity | No GMS. Integrity bypass is **never** implemented. |
| Google Play certification and bundled GMS | Only an optional, isolated post-v1 track (#98) |
| Banking apps and similar strong tamper detection | Root and emulator detection, Integrity dependence |
| Strong DRM (for example Widevine L1) | Hardware DRM cannot be provided |
| Competitive anti-cheat | Emulator detection |
| Vulkan-only games | VirGL has no Vulkan. Evaluated in the post-v1 track #97. |
| Hardware-specific APIs (NFC, UWB, fingerprint, most sensors, telephony) | Not present in a virtual machine |
| Android Automotive, TV, and Wear-only apps | Phone form factor only |
| Camera | Not in the v1.0 candidate list; v1.x or later |
| Full application data rollback | Only APK binary rollback is guaranteed. DB migrations cannot be reversed. |
| Standalone mode (runtime embedded in the `.app`) | Size, duplication, image updates, and notarization get complicated. Not implemented in v1. |
| Trackpad gestures (pinch, rotate) | Deferred to v1.x |

---

## 4. Compatibility levels

Internally there are four levels, for a future per-app compatibility database. Users see three labels.

| Internal level | Meaning | User-facing label |
|---|---|---|
| `nativeLike` | Fully works on a secondary display. Integrations (notifications, clipboard, and others) work. | **Works** |
| `compatible` | Works, but some integrations do not. | **Works with limitations** |
| `compatibilityMode` | Works only in the `primaryDisplayCompatibility` window mode. | **Works with limitations** |
| `unsupported` | Does not start, or has unsupported requirements (Integrity, x86-only, and others). | **Unsupported** |

The compatibility database is a v1.0 candidate (#91).

---

## 5. Scope discipline

These rules apply to every task.

- An Android boot task must not **also** add wrapper UI, the automatic updater, Google Play, or Vulkan.
- Keep technical risks isolated per task.
- If finishing a task needs a major scope expansion, **stop and file a follow-up task**.
- Do not skip the development order because a later task looks easier or more interesting ([roadmap.md](../04-plan/roadmap.md) §1).
