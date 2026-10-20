# Product Vision

This document says what APKRun is for, what the user sees, and which principles guide the design. The system layers are in [overview.md](../01-architecture/overview.md).

---

## 1. In one sentence

> **Turn Android apps into Mac apps.**
> Technically: an Android ARM64 virtualized runtime for macOS.

APKRun runs Android APKs on Apple silicon Macs. Each app is an ordinary Mac app that updates itself automatically. APKRun is not an emulator UI. The Android OS is never shown to the user.

---

## 2. Target user experience

### 2.1 Adding an app

The user drops an APK onto APKRun, or double-clicks it. The add flow shows the app name, icon, package, and version. The user chooses the install folder, the update mode (Automatic, Notify only, or Manual), and the update provider. **Install** creates a wrapper such as `/Applications/Discord.app`.

The CLI does the same in one command:

```bash
apkrun wrap Discord.apk --install --updates auto --output /Applications
```

### 2.2 Using it

The wrapper behaves like any Mac app:

- Finder, Dock, Launchpad, Spotlight, Raycast, and Alfred find it. `open -a Discord` works.
- Notifications appear in macOS Notification Center. Clicking one returns to the app.
- Cmd+Tab shows the app name and icon, not "APKRun".

### 2.3 It stays up to date

In the background, APKRun:

1. Detects a newer version and downloads it.
2. Verifies it: package ID, signing lineage, versionCode, hash, and split consistency.
3. Waits while the app is in use.
4. Installs it through `PackageInstaller`, keeping the app data.
5. Runs a health check: version, launch, first frame.

The wrapper does not change by a single byte. APKRun never re-signs or re-notarizes it.

```text
Discord.app  ──(unchanged)──▶  APKRun Runtime  ──▶  com.discord (latest version)
```

---

## 3. What happens inside

```text
Discord.app (thin wrapper, owns the NSWindow)
      ↓ XPC
apkrund (per-user LaunchAgent)
      ↓
Android VM (Virtualization.framework, kept warm)
      ↓
com.discord (real Android Framework and ART)
      ↓
Android display N (virtio-gpu scanout N)
      ↓ VirGL → virglrenderer → ANGLE → Metal → IOSurface
Presented in Discord.app's NSWindow
```

The layers are described in [overview.md](../01-architecture/overview.md).

---

## 4. Core design principles

| # | Principle | Why |
|---|---|---|
| P1 | Do not port Android to macOS. Run the real Android Framework inside a VM. | An API compatibility layer is never finished. |
| P2 | Do not compile APKs into Mac apps. A wrapper is a thin launcher. | Feasibility and compatibility. |
| P3 | Separate the `.app` from the APK. The `.app` is immutable. The APK is updated in the Package Store. | A signed bundle is never rewritten on an APK update. |
| P4 | `apkrund` manages updates for all wrappers centrally. | Ten apps still mean one updater, one VM, and one runtime. |
| P5 | Prefer existing standards: virtio, PackageInstaller, multi-display, Mesa, VirGL, ANGLE. | APKRun is an integration project. |
| P6 | Build bottom-up: BOOT → ANDROID → GPU → … → WRAPPER. | A wrapper is worthless until what is behind it is stable. |
| P7 | APKs are untrusted code. Host integration always goes through a policy layer. | Security boundary. |
| P8 | Never mix the four kinds of update: Android app, runtime, guest image, wrapper metadata. | Separation of responsibility and risk. |

The decisions behind these principles are in [decisions/](../01-architecture/decisions/README.md).

---

## 5. Properties we want at the same time

- Fast launch: click to first frame in the warm state.
- Real Android compatibility.
- Native-like UX: one Android app is one Mac app and one window.
- Automatic APK updates.
- Stable Mac code signing: wrappers never change.
- One shared runtime VM for all apps.

---

## 6. Technology stack

| Area | Technology |
|---|---|
| Host | Apple silicon, macOS 27+, Swift 6, SwiftUI, AppKit |
| VM | Virtualization.framework, including the macOS 27 custom virtio device API. Residual limits: R-01 in [risks.md](../04-plan/risks.md). |
| Guest | Android ARM64, AOSP Cuttlefish based |
| Graphics | virtio-gpu, Mesa VirGL, virglrenderer, ANGLE, Metal |
| Guest components | Kotlin and Java agents; Rust for `apkrun_vsockd`; native code only where required |
| Host ↔ guest | virtio-vsock with Protocol Buffers; ADB alongside during development |
| Packages and updates | Store Agent, PackageInstaller, UpdateCore, UpdateProvider |
| Host IPC | XPC to the `apkrund` LaunchAgent |

---

## 7. Definition of success

- **Technical feasibility:** Gate G3 passes (SurfaceFlinger renders through virtio-gpu to Metal). Nobody claims the core architecture is validated before G3.
- **Product concept:** Gate G9 passes (the wrapper stays unchanged while the APK inside updates automatically). Nobody claims the product concept is validated before G9.
- **First public demo:** the v0.4 Definition of Done in [roadmap.md](../04-plan/roadmap.md).

---

## 8. Positioning

| Compared with | Difference |
|---|---|
| Android Studio Emulator | Shows the whole Android OS in one window. APKRun hides the OS and makes each app a Mac app. |
| BlueStacks and similar | Game-oriented, and apps run inside their own launcher. APKRun fits into Finder, Dock, and Spotlight. |
| iOS apps on Apple silicon Macs | Native execution. APKRun virtualizes and aims for a comparable experience. |
| Waydroid (Linux) | Container-based. macOS has no Linux kernel, so a VM is required. |
