# Product Vision

| Field | Value |
|---|---|
| Status | Baseline (based on design v2) |
| Related | [scope.md](scope.md), [requirements.md](requirements.md), [../01-architecture/overview.md](../01-architecture/overview.md) |

---

## 1. In one sentence

> **Turn Android apps into Mac apps.**
> Technically: *an Android ARM64 virtualized runtime for macOS.*

APKRun runs Android APKs at high speed on Apple Silicon Macs and lets users treat them as **ordinary, automatically updating Mac apps**.

APKRun is not an Android emulator UI. The Android OS is never shown to the user.

---

## 2. Target user experience

### 2.1 Adding an app

```text
Discord.apk
      ↓  drop onto APKRun (or double-click)
┌──────────────────────────────┐
│ Add Android Application      │
│ [icon]  Discord              │
│ Package   com.discord        │
│ Version   245.0              │
│ Create Mac Application  ✓    │
│ Install in  /Applications    │
│ Updates   ● Automatic        │
│           ○ Notify only      │
│           ○ Manual           │
│ Provider  Automatic Detection│
│              [ Install ]     │
└──────────────────────────────┘
      ↓
/Applications/Discord.app
```

The CLI does the same in one command:

```bash
apkrun wrap Discord.apk --install --updates auto --output /Applications
```

### 2.2 Using it

The generated `Discord.app` behaves like any other Mac app:

- Finder / Dock / Launchpad / Spotlight / Raycast / Alfred
- `open -a Discord`
- macOS Notification Center (clicking a notification returns to the app)
- Cmd+Tab (shows the Discord name and icon, not "APKRun")

### 2.3 It stays up to date

Weeks later, Discord for Android v246 is published. In the background:

```text
UpdateProvider detects new version
      ↓ download
      ↓ verify (package ID / signing lineage / versionCode / hash / split consistency)
      ↓ Discord is in use → wait
      ↓ Discord closed
      ↓ install through PackageInstaller (data preserved)
      ↓ health check (version / launch / first frame)
v246 installed
```

The next day the user launches `Discord.app`. It looks exactly the same, but the latest Android app runs inside. **`Discord.app` itself has not changed by a single byte** — no re-signing, no re-notarization.

```text
Discord.app  ──(unchanged)──▶  APKRun Runtime  ──▶  com.discord v246
```

This is the finished form of APKRun.

---

## 3. What happens inside (summary)

```text
Discord.app (thin wrapper / APKRunLauncher, owns the NSWindow)
      ↓ XPC
apkrund (per-user LaunchAgent, resident)
      ↓
Android VM (Virtualization.framework, kept warm)
      ↓
com.discord (runs on the real Android Framework / ART)
      ↓
Android display N (virtio-gpu scanout N)
      ↓ VirGL → virglrenderer → ANGLE → Metal → IOSurface
Presented in Discord.app's NSWindow
```

Details: [../01-architecture/overview.md](../01-architecture/overview.md).

---

## 4. Core design principles

| # | Principle | Why |
|---|---|---|
| P1 | **Do not port Android to macOS.** Run the real Android Framework inside a VM. | Compatibility. An API compatibility layer is never finished. |
| P2 | **Do not compile APKs into Mac apps.** "Convert" is UX language; the real thing is a thin wrapper. | Feasibility and compatibility. |
| P3 | **Separate the `.app` from the APK.** The `.app` is immutable; the APK is updated in the Package Store. | Never rewrite a signed bundle on every APK update. |
| P4 | **`apkrund` centrally manages updates for all wrappers.** | Ten apps still mean one updater, one VM, one runtime. |
| P5 | **Prefer existing standards** (virtio, PackageInstaller, multi-display, Mesa, VirGL, ANGLE). | APKRun is an integration project, not a collection of custom subsystems. |
| P6 | **Build bottom-up.** BOOT → ANDROID → GPU → … → WRAPPER. | A wrapper is worthless until what is behind it is stable. |
| P7 | **APKs are untrusted code.** Host integration always goes through a policy layer. | Security boundary. |
| P8 | **There are four kinds of updates; never mix them** (Android app / runtime / guest image / wrapper metadata). | Separation of responsibility and risk. |

Rationale is recorded as ADRs in [../01-architecture/decisions/](../01-architecture/decisions/).

---

## 5. Properties we want simultaneously

```text
Fast launch (minimize click → first frame in the warm state)
Android compatibility (real Android)
Native-like UX (1 Android app = 1 Mac app = 1 window)
Automatic APK updates
Mac code-signing stability (wrappers never change)
Runtime sharing (one VM shared by all apps)
```

---

## 6. Technology stack summary

```text
Thin Mac App Wrapper
       +
Shared Android Runtime (apkrund)
       +
ARM64 Virtualization (Virtualization.framework)
       +
Native Window Bridge (Android display ↔ NSWindow via IOSurface)
       +
Managed Android Package Store (Store Agent + PackageInstaller)
       +
Automatic Updates (UpdateCore + UpdateProvider)
```

| Area | Technology |
|---|---|
| Host | Apple Silicon / macOS 27+ / Swift 6 / SwiftUI / AppKit |
| VM | Virtualization.framework, including the macOS 27 custom virtio device API (API existence verified from the macOS 27 SDK and WWDC26 session 224; residual limits tracked as risk R-01 in [../04-plan/risks.md](../04-plan/risks.md)) |
| Guest | Android ARM64 / AOSP Cuttlefish based |
| Graphics | virtio-gpu / Mesa VirGL / virglrenderer / ANGLE / Metal |
| Guest components | Kotlin / Java (native C++ only where required) |
| Host ↔ guest | virtio-vsock + Protocol Buffers (ADB alongside during development) |
| Host IPC | XPC (`apkrund` LaunchAgent) |

---

## 7. Definition of success

- **Technical feasibility:** passing Gate G3 (SurfaceFlinger → virtio-gpu → Metal). Nobody may claim the core architecture is validated before G3.
- **Product concept:** passing Gate G9 (wrapper unchanged while the APK inside updates automatically). Nobody may claim the product concept is validated before G9.
- **First public demo:** v0.4 Definition of Done ([../04-plan/roadmap.md](../04-plan/roadmap.md)).

---

## 8. Positioning

| Compared with | Difference |
|---|---|
| Android Studio Emulator | A developer device emulator that shows the whole Android OS in one window. APKRun hides the OS and turns individual apps into Mac apps. |
| BlueStacks and similar | Game-oriented, runs apps inside its own launcher UI. APKRun blends into Finder / Dock / Spotlight. |
| iOS apps on Apple Silicon Macs | Native execution. APKRun virtualizes but aims for a comparable experience. |
| Waydroid (Linux) | Container-based. macOS has no Linux kernel, so a VM is required. |
