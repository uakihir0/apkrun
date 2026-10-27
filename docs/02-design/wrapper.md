# Mac App Wrappers

A **wrapper** is a small `.app` bundle that stands for one Android app on the Mac. Finder, the Dock, Spotlight, and the Apps view treat it like any other Mac app. It holds no APK and no runtime. It holds the shared launcher executable, the app's identity, an icon, and initial preferences. This document specifies the bundle, the launcher, generation, signing, the registry and approval, icons, the lifecycle, portable and distribution wrappers, and the runtime operations that create wrappers.

---

## 1. Responsibilities

Two rules from [ADR-0009](../01-architecture/decisions/0009-thin-immutable-wrappers.md) apply everywhere. After generation, APKRun never modifies a wrapper (FR-WRP-04). APK updates change only the package store, and a new name, icon, or launcher happens only on explicit user action that regenerates the bundle (§9.3). A wrapper is an identity, not an authority: apkrund decides which package a wrapper may open from its own registry (§7.2), never from files inside the bundle.

| Component | Module / process | Responsibility |
|---|---|---|
| `AppWrapperGenerator` (actor) | WrapperCore, apkrund | builds, signs, places, and registers a bundle from a `WrapperConfiguration` (§6) |
| `BundleIDMapper` | WrapperCore | package ID → bundle ID, and display name → file name (§4) |
| `IconComposer` | WrapperCore | Android icon layers → 1024 px master → `.icns` (§8) |
| `WrapperSigner` | WrapperCore | ad-hoc signing (§7.1) and Developer ID signing for distribution (§11) |
| `WrapperInstaller` | WrapperCore | staging, atomic placement, `Contents` swap on refresh, Trash, LaunchServices registration (§6.3, §9) |
| `WrapperRegistry` (actor) | WrapperCore | `Wrappers/registry.json`: the only record of which bundle ID may open which package, with its cdhash (§7.2) |
| `WrapperValidator` | WrapperCore | computes `WrapperStatus` for the UI and `doctor` (§9.1) |
| `WrapperApprovalService` | WrapperCore | approval of wrappers that are not in the registry (§7.3) |
| `APKRunLauncher` | executable (`Apps/APKRunLauncher`) | the wrapper process: identity, compatibility, session, window, menus (§5). Uses RuntimeClient, WindowingCore, InputCore, and DiagnosticsCore only ([modules.md](../01-architecture/modules.md) §3) |

WrapperCore runs inside apkrund. RuntimeHost builds the `WrapperConfiguration` from the package store, because WrapperCore does not read package state itself ([modules.md](../01-architecture/modules.md) §2). APKRun.app and the CLI request wrapper operations over XPC (§12).

---

## 2. Bundle anatomy

```text
Discord.app/
└── Contents/
    ├── Info.plist
    ├── PkgInfo                        # "APPL????"
    ├── MacOS/
    │   └── APKRunLauncher             # the shared launcher (arm64), re-signed for this wrapper
    ├── Resources/
    │   ├── AppIcon.icns
    │   ├── wrapper.json               # identity + initial preferences (§3)
    │   └── bootstrap/                 # portable and distribution wrappers only (§10)
    │       ├── bootstrap.json
    │       ├── base.apk
    │       └── split_*.apk
    └── _CodeSignature/
        └── CodeResources
```

There are no `.lproj` folders, frameworks, plug-ins, or helpers. Target size: 8 MiB or less without `bootstrap/` (launcher about 4–6 MiB, icon about 1–2 MiB).

### 2.1 Info.plist

| Key | Value | Notes |
|---|---|---|
| `CFBundleIdentifier` | `io.apkrun.android.<mapped package>` | §4 |
| `CFBundleName` | the sanitized display name (§4.3) | the application menu title |
| `CFBundleDisplayName` | the display name | Android label in the guest locale at generation time, or the user's custom name |
| `CFBundleExecutable` | `APKRunLauncher` | the same name in every wrapper (FR-WRP-06) |
| `CFBundlePackageType` | `APPL` | |
| `CFBundleIconFile` | `AppIcon` | no `CFBundleIconName` and no `Assets.car` (§8.4) |
| `CFBundleShortVersionString` | `1.0` | the **wrapper format** version, not the Android version. The Android version goes stale after the first update, so it is never in the bundle |
| `CFBundleVersion` | `1` | wrapper format build |
| `CFBundleInfoDictionaryVersion` | `6.0` | |
| `CFBundleDevelopmentRegion` | `en` | |
| `CFBundleLocalizations` | the launcher's supported languages | lets AppKit localize its own menu items without `.lproj` folders (§5.9) |
| `LSMinimumSystemVersion` | `27.0` | |
| `LSApplicationCategoryType` | mapped from Android `ApplicationInfo.category` | `game` → `public.app-category.games`, `audio` → `.music`, `video` → `.video`, `image` → `.photography`, `social` → `.social-networking`, `news` → `.news`, `maps` → `.navigation`, `productivity` → `.productivity`. Omitted when Android has no category |
| `LSMultipleInstancesProhibited` | `true` | one process per wrapper. One session per package ([state-machines.md](../01-architecture/state-machines.md) §3) |
| `NSHighResolutionCapable` | `true` | |
| `NSPrincipalClass` | `NSApplication` | |
| `NSSupportsAutomaticTermination`, `NSSupportsSuddenTermination` | `false` | the launcher sends `closeSession` before exit |
| `NSQuitAlwaysKeepsWindows` | `false` | no state restoration. The frame is kept with frame autosave ([display-and-windowing.md](display-and-windowing.md) §7.5) |
| `APKRunPackageID` | original Android package ID | the reverse mapping is never parsed from the bundle ID |
| `APKRunWrapperFormat` | `1` | |
| `APKRunWrapperKind` | `local`, `portable`, or `distribution` | |
| `APKRunLauncherVersion` | APKRun version that built the launcher, for example `1.4.0` | used for "Update Mac App" (§9.4) |
| `APKRunLauncherAPI` | RuntimeAPI version of the launcher, for example `1.3` | §5.3 |

Keys that are deliberately absent:

- `LSUIElement`: a wrapper is a regular app with a Dock tile and a Force Quit entry. Background work uses a launch mode instead (§5.8).
- `NSMicrophoneUsageDescription`, `NSCameraUsageDescription`: apkrund captures the microphone, so the prompt belongs to APKRun ([desktop-integration.md](desktop-integration.md) §8.2). Wrappers hold no TCC grants in v1, so regenerating one loses nothing (§9.3).
- `CFBundleURLTypes`, `CFBundleDocumentTypes`: v1 wrappers claim no URL schemes or file types. Claiming an Android app's scheme (for example `discord://`) would take it from the native Mac app of the same service. Post-v1, OQ-23.

---

## 3. wrapper.json

The field reference with the JSON schema is [wrapper-json.md](../03-reference/wrapper-json.md). Example:

```json
{
  "formatVersion": 1,
  "kind": "local",
  "application": {
    "packageId": "com.discord",
    "displayName": "Discord"
  },
  "runtime": {
    "minimumVersion": "1.4.0",
    "launcherAPI": "1.3"
  },
  "window": {
    "mode": "standard",
    "defaultWidth": 480,
    "defaultHeight": 850,
    "resizable": true
  },
  "updates": {
    "authority": "apkrun",
    "mode": "automatic",
    "provider": {
      "type": "direct",
      "configuration": { "url": "https://updates.example.com/discord/manifest.json" }
    }
  },
  "integration": {
    "clipboard": true,
    "notifications": true,
    "files": true
  }
}
```

Rules:

- **Nothing version-specific.** No versionCode, versionName, APK path, or digest (FR-WRP-03). The only exception is `bootstrap/bootstrap.json` in portable wrappers, which describes the embedded copy (§10).
- **Initial values only.** `window`, `updates`, and `integration` are copied into the package settings when the package gets its first record on this Mac (a bootstrap import, or an approval of a wrapper whose package already exists without settings). After that, the package settings in the store win ([package-store.md](package-store.md) §2.4). The `integration` values of a wrapper made on another Mac are capped by this Mac's `integrations.defaults.*`, so such a wrapper cannot turn on the microphone or shared folders by itself ([configuration.md](../03-reference/configuration.md) §3.3). Changing a setting never rewrites `wrapper.json`.
- `integration` uses the keys of [desktop-integration.md](desktop-integration.md) §2.1 without the `integrations.` prefix (`clipboard`, `notifications`, `links`, `files`, `sharedFolders`, `microphone`). Absent keys get the defaults of Settings → Privacy. Unknown keys are ignored.
- `window.mode`: `standard` maps to `secondaryDisplay`, and `compatibility` maps to `primaryDisplayCompatibility` ([display-and-windowing.md](display-and-windowing.md) §8).
- `runtime.minimumVersion` is the lowest APKRun version the launcher works with. It is the build constant `LauncherBuild.minimumRuntimeVersion`, not the version that generated the wrapper (FR-WRP-09).
- `application.packageId` must equal `APKRunPackageID` in Info.plist. The launcher refuses a wrapper where they differ (`wrapperDamaged`). apkrund ignores the file for authorization (§7.2). Editing `wrapper.json` breaks the resource seal, which `doctor --deep` reports (§9.1).
- Encoding: UTF-8 from `JSONEncoder` with `.sortedKeys`, `.prettyPrinted`, and `.withoutEscapingSlashes`, with a trailing newline. Generation is byte-for-byte deterministic (§6.5).

---

## 4. Bundle IDs and file names

### 4.1 Mapping (FR-WRP-05)

Bundle IDs allow only `A–Z a–z 0–9 - .` and are compared case-insensitively. Android package IDs are dot-separated segments of `[a-zA-Z][a-zA-Z0-9_]*` and never contain `-`.

```text
map(pkg):
  s = pkg with every "_" replaced by "-"          # reversible, because Android IDs never contain "-"
  if pkg contains any character A–Z:
      s = s + "-h" + lowercase hex of the first 4 bytes of SHA-256(UTF-8(pkg))
  return "io.apkrun.android." + s
```

| Package ID | Bundle ID |
|---|---|
| `com.discord` | `io.apkrun.android.com.discord` |
| `org.mozilla.fenix` | `io.apkrun.android.org.mozilla.fenix` |
| `com.example.my_app` | `io.apkrun.android.com.example.my-app` |
| `com.UCMobile.intl` | `io.apkrun.android.com.UCMobile.intl-h<8 hex>` |

- The result depends only on the package ID. The same app gets the same bundle ID on every Mac and in every generation, which keeps Dock positions, notification settings, and the window frame. IDs are never random and never depend on what else is installed.
- Two packages that differ only in case would map to bundle IDs that macOS treats as equal. The content-based suffix keeps every ID with an uppercase letter unique, independent of install order.
- The package store uses its own order-dependent `~<8 hex>` rule for directory names ([package-store.md](package-store.md) §3.2). `~` is not allowed in bundle IDs.
- The reverse direction always uses `APKRunPackageID` or the registry, never string parsing.

### 4.2 Other identifiers derived from the bundle ID

| Item | Value |
|---|---|
| Code-signing identifier | the bundle ID (§7.1) |
| Defaults domain | the bundle ID (`~/Library/Preferences/<bundleID>.plist`, frame autosave only) |
| Log subsystem | `io.apkrun.wrapper` for every wrapper. The package ID is a public log field, so there is no per-app subsystem |
| Notification identity | the wrapper's bundle ID, so macOS lists "Discord" in System Settings → Notifications ([desktop-integration.md](desktop-integration.md) §5.2) |

### 4.3 File name

The bundle file name is `<name>.app`, where `<name>` comes from the display name:

1. Unicode NFC. Remove control and format characters (Cc, Cf), except U+200D ZERO WIDTH JOINER and variation selectors, so emoji sequences survive.
2. Replace `/` and `:` with `-`. Collapse runs of whitespace to one space. Trim. Remove leading `.` characters.
3. Cut to 200 UTF-8 bytes at a grapheme-cluster boundary (APFS allows 255 bytes, and `.app` plus conflict suffixes need room).
4. If the result is empty, use the last segment of the package ID.

`CFBundleName` uses the sanitized name. `CFBundleDisplayName` uses the display name after step 1 only. Finder shows the file name for apps without localized names. A rename in Finder is followed through the bookmark (§9.2) and needs no regeneration.

---

## 5. The launcher (`APKRunLauncher`)

### 5.1 One executable, two installations

| Installation | Where | Identity | Endpoint |
|---|---|---|---|
| **Generic launcher** | `APKRun.app/Contents/Helpers/APKRunLauncher.app` | bundle ID `io.apkrun.APKRunLauncher`, signed with APKRun's identity | `.control`, started with `--package <id>` by `launch(packageID)` when a package has no usable wrapper ([runtime-daemon.md](runtime-daemon.md) §7.2) |
| **Wrapper copy** | `<Wrapper>.app/Contents/MacOS/APKRunLauncher` | the wrapper's bundle ID, ad-hoc signed per wrapper | `.wrapper(bundleID)` |

The wrapper copy is a byte copy of the generic launcher's executable (`APKRunLauncher.app/Contents/MacOS/APKRunLauncher`) with a new signature. The executable is the template. There is no separate template file. The code is identical in every wrapper, and only the code signature differs (FR-WRP-06).

- arm64 only. APKRun supports Apple silicon only ([scope.md](../00-product/scope.md)).
- Hardened Runtime. The launcher links only system frameworks (AppKit, QuartzCore, IOSurface, Security, UserNotifications). `scripts/check-launcher.sh` fails the build if `otool -L` lists anything outside `/System/Library` and `/usr/lib`, if `lipo -archs` is not `arm64`, or if the minimum OS is not 27.0.
- The generic launcher has `LSMultipleInstancesProhibited = false`. apkrund opens one instance per package (`createsNewApplicationInstance = true`). It sets the Dock icon from `packageIcon` at run time and uses the package display name as the window title.

### 5.2 Startup

```text
main()                                                      launchTiming.processStart = continuous-clock equivalent of kernel start time (WRAPPER_PROCESS_START)
 1. identity = WrapperIdentity.load(Bundle.main)
      Info.plist APKRunPackageID + APKRunWrapperFormat, Resources/wrapper.json (schema check),
      application.packageId == APKRunPackageID                 else → screen D (§5.4)
      generic launcher: identity from --package <id>
 2. bundle path contains "/AppTranslocation/"?               → screen T (§7.4)
 3. NSApplication: activation policy (.regular, or .accessory with --apkrun-background, §5.8),
    menus (§5.6), and one window, not yet ordered front
    frame = autosaved frame, else wrapper.json default size for now (320 × 400 pt minimum)
 4. RuntimeClient.connect(.wrapper(bundleID))
      broker hello → HelloReply(runtimeVersion, runtimeBuild, apiVersion, hostState)    compatibility (§5.3);
      hostState == updating → screen U (§5.4)
      requestEndpoint(.wrapper(bundleID, bundlePath))
         rejected (not in the registry, or cdhash differs)      → approval (§7.3)
      no autosaved frame → packageInfo(packageID): size the hidden window from the package settings
         window.defaultWidth/defaultHeight (wrapper.json stays the fallback when the package has no record yet)
 5. openSession(OpenSessionRequest{packageID, geometry, screenSize, launchTiming})    APP_LAUNCH_REQUEST
      packageNotInstalled → bootstrap present? import (§10) : screen N
 6. descriptor → surfaces attached ([display-and-windowing.md](display-and-windowing.md) §5)
      order the window front at the first frame, or after 400 ms with the placeholder,
      whichever comes first; booting(progress) shows the placeholder at once
 7. running … ended(reason) → §5.5
```

- The package settings win over `wrapper.json`, which holds only the initial values (§3). The extra `packageInfo` call happens only on a launch without an autosaved frame, normally the first one.
- Steps 1–5 have a budget of 150 ms p50 ([display-and-windowing.md](display-and-windowing.md) §9). The normal registered path does no network, disk scan, or signature check. API 1.16 sends the canonical bundle path; only when it differs from the registry location does the broker inspect the signature to distinguish a Finder copy with the registered cdhash from a modified or re-signed copy.
- `LaunchTiming.processStart` and `requestSent` are sleep-inclusive `mach_continuous_time` nanoseconds since this Mac boot. RuntimeHost uses them only to add host performance markers and discards missing, future, or older-than-10-minute values.
- The 400 ms rule: a warm launch shows no placeholder flash, and a slow launch still gives feedback at once.
- The launcher never starts the VM itself and never needs a terminal. The runtime runs as apkrund, a LaunchAgent.

### 5.3 Compatibility checks (FR-WRP-09)

The launcher is built against RuntimeAPI version `M.m`. apkrund serves `N.n`.

| Condition | Result |
|---|---|
| `HelloReply.runtimeVersion` < `runtime.minimumVersion` | screen V: "‹App› needs APKRun ‹minimum› or later." with **Check for Updates** (opens `apkrun://settings/general`, [runtime-maintenance.md](runtime-maintenance.md) §7.1, §7.5) |
| `M == N`, `m ≤ n` | OK |
| `M == N`, `m > n` | screen V (the runtime is older than the launcher's API) |
| `M == N − 1` | OK. The wrapper endpoint also serves the previous major, so an APKRun update never breaks existing wrappers at once. apkrund reports the wrapper as needing a launcher refresh (§9.4) |
| `M < N − 1` | screen L: "This Mac app was made by an older APKRun and needs to be updated." with **Update Mac App** (opens APKRun.app on the app's page, which offers the refresh) |
| `M > N` | screen V (the runtime is older than the launcher's API) |

The N−1 rule applies only to the `.wrapper` endpoint, whose surface is small. Control clients ship inside APKRun.app and match apkrund. Only the version-stable `.maintenance` endpoint bridges the moment of an APKRun update ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.1).

### 5.4 Launcher screens

The launcher shows its screens in the session window. Each screen has a message, a primary action, and **Quit**. The text keys are in [error-catalog.md](../03-reference/error-catalog.md).

| Screen | Cause | Primary action |
|---|---|---|
| R: "APKRun is required to open ‹App›." | no application with bundle ID `io.apkrun.APKRun` (`NSWorkspace.urlForApplication(withBundleIdentifier:)` is nil) and the Mach service does not answer | **Get APKRun** opens `LauncherBuild.downloadURL` in the browser. It is the APKRun downloads page, the same URL as APKRun.app's `APKRunDownloadsURL` ([configuration.md](../03-reference/configuration.md) §7.1), compiled into the launcher because APKRun.app is missing |
| S: "APKRun needs to finish setup." | APKRun.app exists but apkrund is not registered, the Mach service does not answer, or the runtime is not provisioned (`RuntimeFailure.notProvisioned`). Screen R applies only when APKRun.app is missing | **Open APKRun** (`--register-runtime` or the first-run flow, [runtime-daemon.md](runtime-daemon.md) §9). The launcher retries the connection every 2 s for 60 s |
| V | §5.3 | **Check for Updates** |
| L | §5.3 | **Update Mac App** |
| A: "Waiting for approval in APKRun…" | §7.3 | **Open APKRun**. Denied or timed out: "APKRun did not allow ‹App› to open." |
| N: "‹App› isn't installed in APKRun." | `packageNotInstalled`, or the registry has no package for this bundle ID any more | **Open APKRun**. Portable wrappers show **Install from This App** instead (§10) |
| D: "‹App› is damaged. Create it again in APKRun." | step 1 failed (unreadable or mismatched `wrapper.json`, unknown format version) | **Open APKRun** |
| T: "Move ‹App› to your Applications folder, then open it again." | App Translocation (§7.4) | **Quit** only |
| E: runtime error | `ended(.error(f))` with the catalog message and remediation | **Try Again**, **Open APKRun** ([display-and-windowing.md](display-and-windowing.md) §7.3) |
| U: "APKRun is updating. ‹App› opens again when the update is finished." | `ended(.runtimeUpdating)`, `HelloReply.hostState == updating`, or `openSession` failed with `RuntimeFailure.hostUpdating` ([runtime-maintenance.md](runtime-maintenance.md) §7.5) | **Quit** only. The launcher reconnects and calls `openSession` every 2 s for up to 10 minutes, then shows screen E with **Try Again**. During an Android system update `openSession` is accepted at once, and the placeholder shows "Updating Android…" until the session goes ahead |

"Open APKRun" opens an `apkrun://` URL (for example `apkrun://package/com.discord`), which APKRun.app routes to the right page ([host-ui.md](host-ui.md) §3.1). The URLs only navigate. They never perform actions.

### 5.5 Session end and quit

| Event | Launcher |
|---|---|
| ⌘W, ⌘Q, red close button, Dock "Quit" | `closeSession(nil)` (graceful stop by default), then quits after the reply or 5 s ([display-and-windowing.md](display-and-windowing.md) §7.6) |
| `ended(.userClosed)`, `ended(.appExited)` | quits |
| `ended(.updating)` | closes the window and quits. APKRun reopens the app after the update ([update-system.md](update-system.md) §7.3) |
| `ended(.runtimeStopped)` | quits. The user stopped Android, and the menu bar already confirmed that apps will close |
| `ended(.runtimeUpdating)` | screen U, then reopens by itself ([runtime-maintenance.md](runtime-maintenance.md) §3.5, §4.7). The window keeps its frame for the new session |
| `ended(.appCrashed)` | "‹App› stopped unexpectedly" with **Reopen** |
| `ended(.error(f))` | screen E |
| connection invalidated (apkrund crashed, or exited for an update without `ended(.runtimeUpdating)` reaching the launcher) | "APKRun restarted — reopening…" and `openSession` again with backoff 1, 2, 4 s ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.5) |
| `windowRequest(.close)` | as ⌘W |
| `windowRequest(.activate)` | `NSApp.activate()` and order the window front |
| `applicationShouldTerminate` from logout or shutdown | `closeSession(.stop)`, then `.terminateNow` after at most 2 s |

The launcher process lives exactly as long as its window. It keeps running without a window only in background mode (§5.8).

### 5.6 Menus

Built in code by `LauncherMenus`. The shortcuts come from [input.md](input.md) §6. Items that act on Android go through the session view's responder chain, so they work only while the session is `running`.

| Menu | Items |
|---|---|
| ‹App› | About ‹App› · Settings… (⌘,) opens APKRun on the app's settings page · Services · Hide ‹App› (⌘H) · Hide Others (⌥⌘H) · Show All · Quit ‹App› (⌘Q) |
| File | Close Window (⌘W) |
| Edit | Undo (⌘Z) · Redo (⇧⌘Z) · Cut (⌘X) · Copy (⌘C) · Paste (⌘V) · Select All (⌘A). AppKit adds Emoji & Symbols and Dictation. The actions follow input.md §6 (editor mode or key mode) |
| View | Actual Size (⌘0) · Zoom In (⌘=) · Zoom Out (⌘−) · Enter Full Screen (⌃⌘F) · Show Frame Statistics (developer mode only) |
| Android | Back (⌘[, Esc per `input.escapeKey`) · Restart ‹App› (finish its tasks, then launch again on the same display: the session channel request `restartApp`, [runtime-daemon.md](runtime-daemon.md) §8.6) · Show in APKRun |
| Window | Minimize (⌘M) · Zoom · Bring All to Front · the window list. ⌘` is handled by AppKit |
| Help | APKRun Help · Report a Problem… (opens `apkrun://report?package=<id>`, [diagnostics.md](diagnostics.md) §8.5) |

- **About ‹App›** is a custom panel: icon, display name, Android `versionName (versionCode)` from `packageInfo`, package ID, "Runs with APKRun ‹version›", and the launcher version.
- **Show Frame Statistics** asks apkrund for the session's statistics once per second with `frameStatistics` ([display-and-windowing.md](display-and-windowing.md) §7.7).
- The Dock menu uses the system items (window list, Options, Show in Finder, Quit) and adds **Show in APKRun**.
- No shortcut is added that input.md §6 does not list. Every other key combination goes to Android.

### 5.7 Window

Window behavior is WindowingCore's `SessionWindowController`, shared with the generic launcher and embedded mode. Placeholder, resize, fullscreen, focus, frame autosave, and close policy are in [display-and-windowing.md](display-and-windowing.md) §7. The launcher adds only its screens (§5.4) and its menus.

### 5.8 Background mode (notification relay)

macOS shows a notification under the name and icon of the process that posts it. So the wrapper posts its Android notifications. The wrapper is not running while its window is closed, so apkrund starts it in background mode when a notification arrives for a package with a registered wrapper:

```text
NSWorkspace.openApplication(at: wrapperURL, configuration:
    activates = false, hides = true, addsToRecentItems = false,
    arguments = ["--apkrun-background", "notifications"])
```

- The launcher sets `NSApp.setActivationPolicy(.accessory)` in `applicationWillFinishLaunching`, before a Dock tile appears. It creates no window, connects to its wrapper endpoint, and subscribes to the notification relay ([desktop-integration.md](desktop-integration.md) §5.3).
- It quits 30 s after the last delivered notification.
- A click on a notification, or a notification action that opens the app, switches the policy to `.regular` and continues at §5.2 step 3.
- If the wrapper is already running with a window, apkrund uses its existing connection and launches nothing.
- The Dock tile must not flash. If it does, the fallback is `LSUIElement = true` in Info.plist, with the launcher switching to `.regular` at every foreground start. That fallback changes the bundle, so it ships as a launcher refresh (§9.4). Tracked in R-19.

### 5.9 Localization

Wrappers have no `.lproj` folders, and the launcher must show screen R when APKRun is missing. So the launcher's strings are compiled into the executable. A build step generates `LauncherStrings.generated.swift` from `Apps/APKRunLauncher/Localizable.xcstrings` for the languages in `CFBundleLocalizations`. The language follows `Locale.preferredLanguages`.

### 5.10 What the launcher never does

- Never reads or writes anything under `~/Library/Application Support/APKRun/`. Everything goes through XPC.
- Never writes inside its own bundle.
- Never renders Android content itself. It only presents the IOSurfaces it receives ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)).
- Never logs input, clipboard, or notification content ([security-model.md](../01-architecture/security-model.md) §6).

---

## 6. Generation

### 6.1 Types

```swift
public actor AppWrapperGenerator {
    public func generate(_ request: WrapperGenerationRequest) async throws(WrapperFailure) -> GeneratedWrapper
    public func refresh(_ packageID: PackageID, _ change: WrapperRefresh) async throws(WrapperFailure) -> GeneratedWrapper   // §9.3
}

public struct WrapperConfiguration: Codable, Sendable, Equatable {
    public var packageID: PackageID
    public var displayName: String
    public var icon: WrapperIconSource          // .rendered(IconSet) | .preview(PNG data) | .custom(URL) | .placeholder
    public var category: AndroidAppCategory?
    public var window: WindowDefaults           // mode, defaultSize, resizable
    public var updates: WrapperUpdateDefaults   // authority, mode, provider: initial values (§3)
    public var integrations: IntegrationDefaults
    public var kind: WrapperKind                // .local | .portable(BootstrapSet) | .distribution(BootstrapSet, DistributionSigning)
}

public struct WrapperGenerationRequest: Sendable {
    public var configuration: WrapperConfiguration
    public var destination: WrapperDestination  // .userApplications (default) | .applications | .directory(URL)
    public var fileName: String?                // override of §4.3
    public var replace: ReplacePolicy           // .never | .sameWrapper
}

public struct GeneratedWrapper: Codable, Sendable {
    public var bundleURL: URL
    public var bundleID: String
    public var cdhash: String                   // 40 hex characters
    public var launcherVersion: String
}
```

RuntimeHost fills `WrapperConfiguration` from the package record (`displayName`, category), the settings (window, updates, integrations), and the store's icon files (`icon/`, [package-store.md](package-store.md) §10). For a portable wrapper it adds the `current/` artifact set as `BootstrapSet`.

### 6.2 Sequence

```text
generate(request)                                                   WRAPPER_GENERATE_START
  1. validate: package ID syntax, a non-empty name after §4.3, icon source readable,
     the launcher template signature valid (strict) and arm64
  2. bundleID = BundleIDMapper.map(packageID); an existing registry entry for bundleID?
        valid wrapper and replace == .never → wrapperExists(path)
  3. resolve the destination directory (§6.3); probe that it is writable; conflicts (§6.4)
  4. staging = Wrappers/staging/<uuid>/<name>.app
  5. write Contents/Info.plist (XML, sorted keys), Contents/PkgInfo, Contents/Resources/wrapper.json
  6. icon (§8) → Contents/Resources/AppIcon.icns
  7. clonefile(template) → Contents/MacOS/APKRunLauncher
  8. portable/distribution: copy the bootstrap set and write bootstrap.json (§10)
  9. sign (§7.1 or §11); verify strictly; read the cdhash
 10. registry: add or update the entry with state "pending" {bundleID, packageID, cdhash, final path, staging path}
 11. place: rename(staging → final). Another volume: copy to "<dest>/.<name>.app.apkrun-<uuid>", then rename
 12. bookmark data for the final URL; registry entry → "active"
 13. LSRegisterURL(final, true); NSWorkspace.shared.noteFileSystemChanged(final path)
                                                                    WRAPPER_GENERATE_END {durationMs, kind}
```

- Budget: 2 s p50 or less, without the bootstrap copy.
- **Crash safety.** The registry's `pending` state is the journal. At apkrund start, `WrapperRegistry.recover()` activates a pending entry if the final bundle exists and has the recorded cdhash. Otherwise it deletes the staging directory, removes leftover `.apkrun-<uuid>` items in the destination, and drops the entry (or restores the previous entry after a failed refresh).
- `LSRegisterURL` is the documented registration for apps outside the folders LaunchServices scans at login. If it returns an error, generation still succeeds, and the result carries a warning. `apkrun doctor --fix` calls `LSRegisterURL` again for the check `wrappers.registration` ([diagnostics.md](diagnostics.md) §7.5). APKRun never runs the `lsregister` tool.
- Spotlight indexes the bundle by itself. APKRun never runs `mdimport` or another indexing tool.

### 6.3 Destinations

| Destination | Default | Notes |
|---|---|---|
| `~/Applications` | **yes** | created if missing. The Apps view and Spotlight list it |
| `/Applications` | option ("for all users of this Mac") | needs a user in the `admin` group. Otherwise `destinationNotWritable`. Other users of the Mac see the wrapper but must approve it, and it works only if they have the package installed (§7.3) |
| any other directory | GUI "Other…", CLI `--output <dir>` | works in Finder, the Dock, and Spotlight search. Whether the Apps view lists apps outside the Applications folders is open (OQ-22) |

apkrund is a LaunchAgent, and macOS privacy controls (TCC) may deny it access to folders such as Desktop, Documents, Downloads, iCloud Drive, network volumes, or removable volumes. When the probe in step 3 gets `EPERM`, generation still builds and signs the bundle in staging. It then returns `destinationNotAccessible(stagingToken)`. The client, which the user already allowed to access that folder, moves the bundle and calls `placeStagedWrapper(token, finalURL, bookmark)`. apkrund then runs steps 12 and 13. The CLI does this automatically. The GUI does it after the Save panel.

### 6.4 Conflicts at the destination

| Existing item at `<dest>/<name>.app` | Behavior |
|---|---|
| nothing | place |
| the registered wrapper of the same package | `replace == .sameWrapper`: a refresh at that location (§9.3). Otherwise `wrapperExists` |
| a wrapper of another package (another `APKRunPackageID`) | never replaced. The CLI fails with `nameConflict`, and the GUI proposes "‹name› 2.app" |
| anything else (a native Mac app of the same name, a folder, a file) | never replaced. Same as above. A native Discord.app is never overwritten by an Android Discord wrapper |

There is one registered wrapper per package (one bundle ID). Copies that the user makes in Finder have the same cdhash, so they work, but the registry tracks only one location.

### 6.5 Determinism

For the same `WrapperConfiguration`, launcher build, and icon input, generation produces byte-identical files. That includes `_CodeSignature/CodeResources` and the executable's signature, because ad-hoc signatures carry no timestamp or certificate.

- Plists: XML with sorted keys. JSON: §3. PNGs from ImageIO without metadata chunks. `.icns` from `iconutil`. File modes 0644 and 0755.
- The T1 determinism test generates twice into different directories and compares the SHA-256 of every file. If `codesign` or `iconutil` output turns out not to be deterministic, the test excludes the affected files. For `iconutil`, the fix is the built-in `ICNSWriter` (§8.4).

### 6.6 Entry points

| Entry point | Flow |
|---|---|
| Add sheet | the "Create Mac app" toggle (default on), name field, location pop-up (Applications for me / for all users / Other…), icon preview. Generation runs after the install commits. A failure is shown in the sheet with **Try Again**, and the installed package stays ([host-ui.md](host-ui.md) §6) |
| App page | the `MacAppSection` view ([host-ui.md](host-ui.md) §7.6): status, name, icon (Android icon or Choose…), location with **Show in Finder**, **Update Mac App**, **Create Mac App** when there is none, **Remove Mac App…** |
| CLI | `apkrun wrap`, `apkrun install --wrap` (§12.2) |
| Portable bootstrap on another Mac | the approval of the portable wrapper registers it. Nothing is generated (§10) |

---

## 7. Signing, registry, approval

### 7.1 Local signing

```text
/usr/bin/codesign --force --sign - --identifier <bundleID> --options runtime --timestamp=none <staging>/<name>.app
```

- The bundle has no nested code, so one call signs the main executable and seals `Contents/`. Never use `--deep`.
- Signing is the last write to the bundle. Anything written later breaks the seal.
- Verification after signing: `SecStaticCodeCheckValidity` with `kSecCSStrictValidate | kSecCSCheckAllArchitectures` and the requirement `identifier "<bundleID>"`.
- cdhash: `SecCodeCopySigningInformation` → `kSecCodeInfoUnique` (the 20-byte SHA-256 code directory hash), as 40 hex characters.
- Local wrappers are created by apkrund. They carry `com.apple.provenance` and no `com.apple.quarantine`, so Gatekeeper does not assess them. APKRun never removes quarantine from anything it did not create ([security-model.md](../01-architecture/security-model.md) §3.3). Tracked in R-17.

### 7.2 Registry (`Wrappers/registry.json`)

Written only by `WrapperRegistry` in apkrund, with atomic replace (write, `fsync`, rename).

```json
{
  "schemaVersion": 1,
  "wrappers": [
    {
      "bundleId": "io.apkrun.android.com.discord",
      "packageId": "com.discord",
      "kind": "local",
      "state": "active",
      "path": "/Users/me/Applications/Discord.app",
      "bookmark": "<base64 bookmark data>",
      "cdhash": "3f1c…40 hex…",
      "launcherVersion": "1.4.0",
      "launcherAPI": "1.3",
      "formatVersion": 1,
      "fileName": "Discord",
      "displayName": "Discord",
      "customization": { "displayName": null, "iconFile": null },
      "iconDigest": "sha256:…",
      "approval": "generated",
      "createdAt": "2026-10-01T09:12:00Z",
      "refreshedAt": null,
      "lastValidatedAt": "2026-10-02T08:00:00Z"
    }
  ],
  "denied": [
    { "bundleId": "io.apkrun.android.com.example", "cdhash": "…", "until": "2026-10-03T08:00:00Z" }
  ]
}
```

| Field | Meaning |
|---|---|
| `state` | `active`, `pending` (§6.2), or `refreshing` (§9.3, with `pendingCdhash`) |
| `stagingPath` | only while `pending` or `refreshing`: the staged bundle (`Wrappers/staging/<uuid>/` for `pending`, `<parent>/.apkrun-<uuid>/` for `refreshing`). Recovery deletes it (§6.2) |
| `pendingCdhash` | only while `refreshing`: the new bundle's cdhash. apkrund accepts both cdhashes until the refresh ends (§9.3) |
| `cdhash` | what apkrund puts into the `.wrapper(bundleID)` endpoint requirement: `identifier "<bundleId>" and cdhash H"<cdhash>"` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2) |
| `approval` | `generated` (apkrund built it) or `user` (approved in §7.3) |
| `customization` | a user-chosen name and icon. A custom icon source is copied to `Wrappers/icons/<bundleId>.png`, so a refresh can reuse it |
| `iconDigest` | SHA-256 of the 1024 px master used in the bundle, compared with the current Android icon (§8.5) |

The example shows an `active` entry. Every field, its type and limits, and the fields each state requires are in [wrapper-json.md](../03-reference/wrapper-json.md) §4.

Authorization uses the registry only. A wrapper connection may open sessions for `packageId` and nothing else (NFR-SEC-07). A missing or unreadable registry means that no wrapper is authorized. The home screen then offers **Re-register Mac Apps**, which scans `~/Applications` and `/Applications` for bundles with `APKRunPackageID`, validates each one statically, and re-registers those with `approval: generated` after one confirmation. A corrupt file is kept as `registry.json.corrupt-<timestamp>` for diagnostics.

### 7.3 Approval of unknown wrappers

A wrapper is unknown when its bundle ID is not in the registry or its cdhash differs. Examples: a wrapper copied from another Mac, a portable or distribution wrapper, or a wrapper that was modified.

```text
launcher: requestEndpoint(.wrapper(bundleID)) → .unknownClient
launcher: requestApprovalEndpoint({bundlePath, bundleID, packageID})                (broker)
apkrund: read-only inspection of bundlePath:
     strict signature checks and a valid signer summary (ad-hoc, or team-signed with a valid
  10-character Team ID; the certificate class and notarization are unknown unless an OS assessment
  establishes them);
  verify signed/plist bundle IDs, APKRun package ID,
  mapped bundle ID, wrapper.json, format/launcher version, and cdhash
  invalid bundle → RuntimeEndpointReply.rejected(.unknownClient)
apkrund: grant one-use anonymous endpoint requiring identifier + validated cdhash
  reservation expires after 5 s; it does not create a prompt or look up the Android package
launcher: connect to endpoint; submitApproval()
apkrund WrapperApprovalService:
  1. revalidate the bundle and require the same path, IDs, and cdhash as the endpoint grant
  2. join an identical pending request or apply limits: one pending identity per bundle ID,
     5 new approvals per minute; a denial for the same cdhash within 24 h rejects at once
  3. obtain installed state and Android version from the package store (a lookup failure is
     currently shown as not installed), then prepare or reuse
     the prompt with location, signer, installed version (when available), integrations
     (wrapper.json values capped by this Mac's defaults, configuration.md §3.3), and any
     wrapper it would replace; the optional bundledVersion field is currently not populated
  4. publish approvalRequested to the wrappers topic and open APKRun.app with activates = true
  5. Allow → registry entry {approval: user, cdhash} → reply .approved; launcher repeats requestEndpoint
     Don't Allow → "denied" entry for 24 h (Settings → Privacy can clear it) → reply .denied
     no answer in 10 min → .timedOut
```

- The dialog layout and buttons are in [host-ui.md](host-ui.md) §10.1.
- The endpoint requirement contains the bundle ID and cdhash computed from the bundle on disk. A process that only claims to be that bundle cannot pass it, because the system checks the connecting code. apkrund does not authorize the caller by PID or audit token.
- Endpoint inspection is read-only. Quota admission, package lookup, challenge creation, event publication, and UI launch occur only after the matching wrapper code connects and calls `submitApproval`.
- Before creating a challenge, `submitApproval` checks whether the validated bundle ID, package ID, and cdhash are already active (or are either accepted hash during refresh). It returns `.approved` without a prompt for that exact authorization, so a transient XPC transport failure cannot create a duplicate approval prompt.
- Coalesced callers share one challenge and outcome. Closing a wrapper connection cancels its wait; the challenge is removed when no wrapper connection remains unless the CLI prepared it for independent confirmation. A retained challenge resolves on a user decision or the 10-minute deadline.
- Approving a wrapper whose bundle ID already has an active entry replaces that entry. The dialog then says so and names the location of the current one.
- `apkrun wrapper approve <path>` uses the authenticated `.control` endpoint to prepare or retrieve the same validated challenge, displays its facts, asks for terminal confirmation, and submits the decision. This direct CLI preparation returns the prompt to the CLI and does not publish a GUI event or open APKRun.app. An interactive wrapper that joins the CLI-prepared challenge publishes the deduplicated `approvalRequested` event and opens the GUI.
- A modified local wrapper (`signatureInvalid`, §9.1) is not approvable. The static check in step 1 fails, and the user is offered regeneration instead.

### 7.4 App Translocation

A quarantined app that is opened from where it was downloaded (for example `~/Downloads`) runs from a random read-only path under `/private/var/folders/…/AppTranslocation/`. The bookmark and path of such a location are useless. The launcher detects the `/AppTranslocation/` path component and shows screen T before asking for approval. This affects distribution wrappers (§11) and portable wrappers that were copied through a quarantining app.

---

## 8. Icons

### 8.1 Input

The store provides the rendered icon from the Store Agent ([package-store.md](package-store.md) §10.2, `RenderIcon`, [guest-protocol.md](guest-protocol.md) §11.1):

| Kind | Content |
|---|---|
| adaptive | background and foreground layers (and monochrome, when present), each 1536 × 1536 px for the full 108 dp canvas, without a mask |
| legacy | one bitmap at 1536 × 1536 px, drawn from the app's highest-density icon |
| host preview (no render yet) | a PNG or WebP bitmap decoded on the host, or nothing for vector icons ([package-store.md](package-store.md) §10.1) |

The layer size is 1536 px because the visible part of an adaptive icon is the inner 72 dp of 108 dp. 72/108 of 1536 px is exactly the 1024 px macOS master, so no upscaling is needed.

### 8.2 Master composition (1024 × 1024, sRGB, opaque)

```text
adaptive:
  draw background, then foreground, on a 1536 px canvas (white under a background with alpha)
  crop the centered 1024 px square (the inner 72 dp)
legacy / host preview bitmap:
  trim the transparent border (alpha < 8)
  if the result is square (aspect 0.97–1.03) and opaque in all four corners (alpha ≥ 250 at 2 % insets):
       scale to 1024 px, full bleed
  else:
       white 1024 px square, image fitted into the centered 820 px box
custom (user file):
  used as provided: PNG, JPEG, or HEIC ≥ 512 px and square; or an .icns, which is copied as is
placeholder (no icon yet):
  the first grapheme of the display name, white, centered on a color chosen by SHA-256(packageID)
```

- The composition always produces an opaque square, and macOS applies the icon shape. A transparent irregular icon would get the system background plate. The host does not draw its own squircle.
- Custom icons are not reshaped. A user who picks a transparent image gets what macOS does with it.
- The monochrome layer is stored but not used. macOS tinted and clear icon styles need an `Assets.car` (§8.4).

### 8.3 `.icns`

1. Downscale the master with Core Graphics (`interpolationQuality = .high`, sRGB, 8 bits per channel) to the iconset sizes: 16, 32, 64, 128, 256, 512, and 1024 px, named `icon_16x16.png`, `icon_16x16@2x.png`, … `icon_512x512@2x.png`.
2. `/usr/bin/iconutil -c icns -o AppIcon.icns AppIcon.iconset`.
3. Delete the iconset.

### 8.4 What is not used

`actool` and `ictool` ship only with Xcode, so APKRun cannot compile Icon Composer `.icon` files or `Assets.car` on users' Macs. Wrappers therefore have no Liquid Glass layers and use `CFBundleIconFile`. If `iconutil` misbehaves (for example non-deterministic output, §6.5), `ICNSWriter` writes the container directly (the `ic04`–`ic14` PNG entries). Liquid Glass icons are post-v1 (OQ-24).

### 8.5 Icon changes after an update

- After an update or rollback, the store renders the icon again and emits `PackageChange.iconChanged` when the composed result differs ([package-store.md](package-store.md) §10.2).
- WrapperCore composes the new master and compares its digest with `iconDigest`. If it differs and the wrapper has no custom icon, the wrapper gets the refresh reason `.icon` (§9.1). The app page shows "New icon available" with **Update Mac App**.
- The wrapper is **not** refreshed automatically (FR-WRP-04, ADR-0009). The same applies to `.displayName` when the Android label changes (a new version or a new macOS language).
- LaunchServices and the Dock cache icons. After a refresh WrapperCore touches the bundle, calls `LSRegisterURL`, and calls `noteFileSystemChanged`. If the Dock still shows the old icon, Settings → Troubleshooting offers **Refresh Dock Icons** ([host-ui.md](host-ui.md) §9.8). It restarts the Dock after a confirmation and is never done automatically.

---

## 9. Lifecycle

### 9.1 Status

`WrapperValidator` computes a `WrapperStatus` on demand. It is never stored ([state-machines.md](../01-architecture/state-machines.md) §8).

```swift
public struct WrapperStatus: Codable, Sendable, Equatable {
    public var state: WrapperState
    public var refreshReasons: Set<WrapperRefreshReason>   // .launcher(version), .icon, .displayName
}

public enum WrapperState: Codable, Sendable, Equatable {
    case valid
    case moved(URL)          // found at a new location; the registry is updated, so this is shown once
    case missing             // no bundle at the bookmark or path, or it is in the Trash
    case inaccessible        // macOS privacy controls deny apkrund access to the location (§6.3)
    case signatureInvalid    // the bundle was modified after signing, or its cdhash differs
    case unknownPackage      // the registry's package has no record in the store any more
}
```

Checks in order (the first failure decides):

| # | Check | Failure |
|---|---|---|
| 1 | resolve the bookmark (`.withoutUI`, `.withoutMounting`). Stale or failed: `NSWorkspace.urlsForApplications(withBundleIdentifier:)`, keeping the candidate with the registered cdhash | `missing` (also when the resolved URL is inside a `.Trash` folder) |
| 2 | read access to the bundle | `inaccessible` |
| 3 | Info.plist `CFBundleIdentifier` and the executable's cdhash equal the registry (cdhash cached by inode, size, and mtime of the executable) | `signatureInvalid` |
| 4 | **deep only:** `SecStaticCodeCheckValidity` (strict, all architectures), which covers the resource seal | `signatureInvalid` |
| 5 | the store has a record for `packageId` | `unknownPackage` |
| 6 | refresh reasons: `APKRunLauncherVersion` < the current template's version, icon digest (§8.5), display name | adds reasons, the state stays `valid` |

A path change found in step 1 updates the registry path and bookmark. The state is `moved(newURL)` for that one report. A user rename in Finder is handled the same way.

When validation runs:

| Trigger | Depth |
|---|---|
| apkrund start + 60 s (all entries, low priority) | quick |
| `listWrappers` (home screen, [host-ui.md](host-ui.md) §5); results are cached for 60 s | quick |
| `launch(packageID)` for that entry ([runtime-daemon.md](runtime-daemon.md) §7.2) | steps 1–3 |
| `apkrun doctor` / `apkrun doctor --deep`; `apkrun wrapper verify --deep` | quick / deep |
| G9 check (#50) | deep plus the file hash list |

The launch path of the wrapper itself runs none of these checks ([overview.md](../01-architecture/overview.md) §6). The system's code-signing requirement on the endpoint is the check.

What the UI offers for each state:

| State | Home screen and app page |
|---|---|
| `missing` | "Mac app not found" · **Create Mac App** · **Remove from List** |
| `inaccessible` | "APKRun can't check this location" (information only; the wrapper still works) |
| `signatureInvalid` | "This Mac app was modified" · **Create It Again** (the modified bundle goes to the Trash) |
| `unknownPackage` | "‹App› isn't installed" · **Move Mac App to Trash** · for portable wrappers also **Install from This App** |
| refresh reasons | badge "Update available" · **Update Mac App** (one wrapper) and **Update All Mac Apps** |

### 9.2 Moved and deleted wrappers

- Moving within a volume, or renaming, is followed by the bookmark. Moving to another volume is found through LaunchServices, which registers apps that Finder sees.
- Deleting a wrapper in Finder (to the Trash) gives `missing`. Nothing in the store changes. The package can still be launched from APKRun.app with the generic launcher. Putting the wrapper back makes it `valid` again.
- A package without a wrapper is a normal state.

### 9.3 Refresh (regeneration)

A refresh changes the name, the icon, or the launcher. It is always an explicit user action: a button on the app page, **Update All Mac Apps**, or `apkrun wrapper refresh`.

```text
refresh(packageID, change{displayName?, icon?, launcher})
  1. the wrapper must not be running (NSRunningApplication for the bundle ID, SessionRegistry)
       running → wrapperRunning; the UI asks "Quit ‹App› to update its Mac app?" and on OK
       repeats the refresh with closeRunningApp; apkrund sends windowRequest(.close),
       waits for the session to end, and continues
  2. the entry must be valid or have refresh reasons (missing → generate instead, §6)
  3. build the new Contents in "<parent>/.apkrun-<uuid>/<name>.app/Contents" (same volume), sign, verify
  4. registry: state "refreshing", pendingCdhash (both cdhashes are accepted until step 7)
  5. renamex_np(new Contents, <bundle>/Contents, RENAME_SWAP)       (atomic)
  6. name changed → rename <bundle> to "<new name>.app" (conflict rules of §6.4)
  7. registry: cdhash = pendingCdhash, state "active", refreshedAt, bookmark
  8. delete the old Contents and the temporary directory; touch the bundle;
     LSRegisterURL; noteFileSystemChanged
```

- **Swapping `Contents` instead of the whole bundle** keeps the bundle directory's file identity. The Dock's pinned item and Finder aliases resolve by file identity, so they keep working after a rename. Tracked in R-20.
- **macOS App Management.** macOS can block one app from modifying another app's bundle. If it blocks apkrund from replacing the `Contents` of an ad-hoc wrapper it created (R-20), APKRun.app runs steps 5 and 6 instead. APKRun.app is the user-facing process, which the user can allow under System Settings → Privacy & Security → App Management. apkrund runs steps 1–4 with the new `Contents` in `Wrappers/staging/<stagingToken>/` and fails with `refreshBlocked(path, stagingToken:)`. APKRun.app then calls `placeStagedWrapper` with the bundle's final URL, and apkrund runs steps 7 and 8 ([runtime-api.md](../03-reference/runtime-api.md) §10.5). The CLI shows the error.
- If the swap loses the Dock pin (R-20), replace the whole bundle instead. A Dock pin may then need to be recreated.
- A refresh changes the cdhash, and apkrund updates the registry in the same operation, so no approval is needed. The bundle ID stays the same, so Dock position, notification settings, and the window frame stay.
- Crash recovery follows §6.2: `refreshing` with a leftover temporary directory is completed if step 5 happened (the bundle's cdhash equals `pendingCdhash`), or rolled back otherwise.

### 9.4 Launcher refresh after an APKRun update

A wrapper holds a copy of the launcher from the APKRun version that generated it. After an APKRun update ([runtime-maintenance.md](runtime-maintenance.md)):

- Wrappers with the same RuntimeAPI major, or with the previous major (§5.3), keep working. They get the refresh reason `.launcher(version)`, and the home screen shows **Update All Mac Apps**. Nothing is changed automatically.
- If the new APKRun drops a major that some wrappers still use (they are two majors behind), those wrappers show screen L when opened. APKRun.app also asks after its update: "N Mac apps need to be updated to work with this version of APKRun." with **Update Now**. That is the explicit action. Running wrappers are skipped and listed.
- A release can set `LauncherBuild.recommendsRefresh` for an important launcher fix. APKRun.app then shows the same prompt after the update, even though the old launchers still work.

### 9.5 Removal

| Action | Effect |
|---|---|
| Uninstall with "Also move the Mac app to the Trash" (default on when a wrapper exists) | after the store transaction commits: `FileManager.trashItem`, then the registry entry is removed ([package-store.md](package-store.md) §8) |
| Uninstall without it | the wrapper stays and becomes `unknownPackage` |
| **Remove Mac App…** / `apkrun wrapper remove <pkg> --trash` | Trash plus registry removal. The package stays |
| **Remove from List** / `apkrun wrapper remove <pkg>` | registry removal only. The bundle, if it still exists somewhere, becomes an unknown wrapper that needs approval |

Wrappers are always moved to the Trash, never deleted, so the user can undo.

---

## 10. Portable wrappers

A portable wrapper also carries the APK set, so it can install the app on another Mac that has APKRun but not the package (ADR-0009).

### 10.1 Contents

`Contents/Resources/bootstrap/` holds the files of the package's `current/` artifact set (base and splits, as installed) and `bootstrap.json`:

```json
{
  "formatVersion": 1,
  "packageId": "com.discord",
  "versionCode": 126012,
  "versionName": "126.12",
  "setDigest": "sha256:…",
  "signers": ["sha256:…"],
  "files": [
    { "name": "base.apk", "size": 98123456, "sha256": "sha256:…" },
    { "name": "split_config.arm64_v8a.apk", "size": 23456789, "sha256": "sha256:…" }
  ]
}
```

- The split set is the one selected for this Mac ([package-store.md](package-store.md) §4.4). Density and ABI splits fit every APKRun runtime (always arm64, same default density). All language splits are included.
- The bundle signature seals these files like any other resource.
- The files can be large. The GUI shows the size before generation, and `apkrun wrap --portable` prints it.
- Every digest carries the `sha256:` prefix. The fields and checks are in [wrapper-json.md](../03-reference/wrapper-json.md) §3.
- A portable wrapper contains the app. The GUI and `apkrun wrap --portable` show the portable note of [legal-and-licensing.md](../05-development/legal-and-licensing.md) §9 next to the size. It is a note, not a question. The confirmation is asked when a wrapper is signed for other people (§11).
- `--portable` without an installed package (`apkrun wrap app.apk --portable`, no `--install`) is allowed. It uses the import ticket's set and the host preview icon, or the placeholder (§8.2). The CLI warns about the icon.

### 10.2 First run on another Mac

```text
1. launcher → unknown wrapper → approval (§7.3); the dialog shows "Includes Discord 126.12"
2. openSession → packageNotInstalled
3. screen N with "Install from This App": "Install Discord 126.12 from this Mac app?"
   (on the first run the approval already asked, so this step is skipped)
4. importBootstrap(bootstrap.json, [FileHandle]) on the wrapper endpoint
     apkrund: allowed only if the wrapper is approved, bootstrap.json packageId == registry packageId,
              and the package is not installed (or is uninstalledKeepingData)
     store: copy, SHA-256 against bootstrap.json, all intrinsic checks and the preview
            ([package-store.md](package-store.md) §4.1, §4.6); source = wrapperBootstrap
     preview warnings (for example a low targetSdk): APKRun.app shows the install sheet to confirm
5. install with wrapper.json "updates" as the initial authority, mode, and provider
   ([update-system.md](update-system.md) §2); "window" and "integration" become the package settings
6. the launcher repeats openSession → normal launch
```

- The bootstrap is used **only when the package is not installed** on this Mac. It never updates or downgrades an installed package. If Android kept data from an earlier uninstall and that version is newer, the install fails with the store's downgrade error.
- If the user later uninstalls the package and opens the portable wrapper again, **Install from This App** asks again every time.
- The bundle is never changed. After the first install, `bootstrap/` is dead weight. Regenerating the wrapper as a local wrapper (**Make Local Mac App** on the app page, [host-ui.md](host-ui.md) §7.6) removes it.

---

## 11. Distribution wrappers

A distribution wrapper is a portable wrapper signed with a Developer ID and notarized, so it can be given to other people (FR-WRP-10).

```text
apkrun wrap <package> --distribution --identity "Developer ID Application: Name (TEAMID)"
            [--notarize --keychain-profile <profile>] [--output <dir>]

1. generate as portable in staging, APKRunWrapperKind = distribution (not placed, not registered)
2. codesign --force --sign "<identity>" --identifier <bundleID> --options runtime --timestamp <bundle>
3. verify: codesign --verify --strict; SecStaticCodeCheckValidity
4. --notarize:
     ditto -c -k --keepParent <bundle> <name>.zip
     xcrun notarytool submit <name>.zip --keychain-profile <profile> --wait --output-format json
     Accepted → xcrun stapler staple <bundle>; zip again → <name>.zip
     Invalid  → notarizationFailed(submissionID, log summary from `notarytool log`)
5. spctl --assess --type execute -vv <bundle> → "source=Notarized Developer ID" (only with --notarize)
6. output: <dir>/<name>.app and <dir>/<name>.zip
```

- Without `--output`, the files are written to the current directory.
- Needs the Xcode Command Line Tools on the creator's Mac (`notarytool`, `stapler`). Without them the command fails with `distributionToolMissing`. End users never need them.
- The identity comes from the creator's keychain. The notary credentials are a `notarytool store-credentials` profile. APKRun never stores Apple ID passwords.
- The launcher executable is the same (FR-WRP-06). It has no third-party libraries, so Hardened Runtime with Developer ID needs no extra entitlements.
- **Legal.** The creator must have the right to redistribute the APK. The CLI requires a confirmation (`--yes` skips it) that states this ([legal-and-licensing.md](../05-development/legal-and-licensing.md)).
- On the recipient's Mac, the download is quarantined, and Gatekeeper accepts it because it is notarized. The launcher asks the user to move it to Applications if it is translocated (§7.4), requests approval (the dialog shows the Developer ID team), and installs from the bootstrap (§10.2). Without APKRun, screen R appears.
- Trust is per cdhash in v1. Trust by Developer ID team is post-v1 (OQ-25).

---

## 12. Runtime API surface and CLI

### 12.1 Operations

The DTOs are in [runtime-api.md](../03-reference/runtime-api.md): `WrapperSummary` and `WrapperInfo` in [runtime-api.md](../03-reference/runtime-api.md) §10.4; `RuntimeWrapperApprovalPrompt` (built in API 1.14; signer facts extended in 1.15) and target `ApprovalPrompt` in [runtime-api.md](../03-reference/runtime-api.md) §10.6.

| Endpoint | Operation | Behavior | Long |
|---|---|---|---|
| `.control` | `createWrapper(WrapperRequest{packageID, destination, fileName?, displayName?, icon?, portable, replace})` | RuntimeHost builds the configuration, §6. A custom icon is a file handle (`icon = .custom(fileIndex:)`), never a path | yes |
| `.control` | `placeStagedWrapper(stagingToken, finalURL, bookmark)` | finishes a client-placed generation (§6.3), or a refresh that APKRun.app swapped (§9.3) | no |
| `.control` | `listWrappers()` → `[WrapperSummary]` | registry entries with `WrapperStatus` (§9.1) | no |
| `.control` | `wrapperInfo(packageID)` → `WrapperInfo` | one summary plus paths and signer | no |
| `.control` | `refreshWrapper(packageID, WrapperRefresh)` | §9.3 | yes |
| `.control` | `refreshAllWrappers(scope, launcherOnly)` | **Update All Mac Apps** and `apkrun wrapper refresh --all`: every wrapper with a refresh reason, or all. Running wrappers are skipped and listed (§9.4) | yes |
| `.control` | `removeWrapper(packageID, RemoveWrapperOptions{trash})` | §9.5 | no |
| `.control` | `rescanWrappers(register)` | **Re-register Mac Apps** (§7.2): finds bundles with `APKRunPackageID` in `~/Applications` and `/Applications` and validates them. With `register`, registers them after the client's one confirmation | no |
| `.control` | `verifyWrapper(url, deep)` | §9.1 checks for any bundle, registered or not | no |
| `.control` | `decideApproval(approvalID, allow)` (built, API 1.14) | APKRun.app or the CLI commits the user's decision for §7.3 | no |
| `.control` | `pendingApprovals()` → `[ApprovalPrompt]` | target: prompts requested before APKRun.app connected (§7.3 step 4) | no |
| `.control` | `deniedWrappers()`, `clearWrapperDenial(bundleID)` | Settings → Privacy → **Mac apps you didn't allow** and its **Remove** (§7.3 step 5, [host-ui.md](host-ui.md) §9.4) | no |
| `.control` | `approveWrapper(bundlePath)` (built, API 1.14) | prepares or retrieves the validated prompt for the caller; the CLI displays it, confirms, and calls `decideApproval` | no |
| `.control` | `buildDistributionWrapper(DistributionWrapperRequest)` | §11. Not placed and not registered; the client places the files when apkrund may not write to the output folder ([runtime-api.md](../03-reference/runtime-api.md) §10.8) | yes |
| broker | `requestApprovalEndpoint(bundlePath, bundleID, packageID)` → one-use endpoint; endpoint `submitApproval()` | §7.3 | waits |
| `.wrapper` | `openSession` and the session channel | [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3 | — |
| `.wrapper` | `packageInfo`, `packageIcon` (own package) | [package-store.md](package-store.md) §11.2 | no |
| `.wrapper` | `importBootstrap(bootstrapJSON, [FileHandle])` | §10.2 | yes |
| `.wrapper` | `notificationRelay(background)`, `notificationRelayResponse` | the notification relay of a window process or of background mode (§5.8, [desktop-integration.md](desktop-integration.md) §5.3, §11) | stream, one-way |

Events on topic `wrappers`:

```swift
public enum WrapperChange: Codable, Sendable {
    case approvalRequested(RuntimeWrapperApprovalPrompt) // built: wrapper endpoint opens APKRun.app
    case approvalResolved(ApprovalID)                    // built: decision or timeout
    case created(WrapperSummary)
    case refreshed(WrapperSummary)
    case removed(PackageID)
    case statusChanged(PackageID, WrapperStatus)
}
```

The CLI's direct `approveWrapper` control call returns the prompt to the CLI and does not publish `approvalRequested`. A wrapper that connects to the one-use approval endpoint publishes the challenge for APKRun.app; the event hub de-duplicates and replays pending prompts.

### 12.2 CLI

The full syntax, exit codes, and JSON output are in [cli.md](cli.md).

```text
apkrun wrap <file.apk…|package> [--install] [--output <dir>] [--name <text>] [--icon <file>]
            [--updates automatic|notify|manual] [--provider <spec>]
            [--update-provider <type> --update-url <url>]
            [--window-size <w>x<h>] [--resizable | --no-resizable]
            [--portable] [--replace] [--open] [--yes] [--json]
apkrun wrap <package> --distribution --identity <name> [--notarize --keychain-profile <p>]
apkrun wrapper list [--json]
apkrun wrapper info <package> [--json]
apkrun wrapper refresh (<package>… | --all) [--name <text>] [--icon <file> | --android-icon] [--launcher-only]
apkrun wrapper remove <package> [--trash] [--yes]
apkrun wrapper verify <path> [--deep] [--json]
apkrun wrapper approve <path> [--yes]
```

- Alternate flag spellings are accepted: `--update auto` and `--updates auto` = `--updates automatic`, and `--update-provider direct --update-url <url>` = `--provider direct:<url>` ([update-system.md](update-system.md) §11.3). `--updates` and `--provider` apply only when this command installs the package, or as the initial values in `wrapper.json`. For an installed package they are rejected with a hint to use `apkrun update policy`.
- `--window-size` and `--resizable` set `wrapper.json` defaults and, when this command installs the package, the initial package settings.
- `--output` defaults to `~/Applications`. A directory that apkrund may not access is handled by the CLI as in §6.3.
- `--open` opens the wrapper after it is created.

`apkrun wrap <file>` combines import, install, and wrap:

| Package on this Mac | `--install` | Result |
|---|---|---|
| not installed | no | prints the import preview and asks "Install and create the Mac app?". Non-interactive without `--yes`: fails with `packageNotInstalled` and the hint `--install` |
| not installed | yes | installs (as `apkrun install --yes`), then wraps |
| installed, same version in the file | either | wraps. The file is not installed again |
| installed, newer version in the file | no | wraps the installed version and says that the file is newer (use `--install` to update first) |
| installed, newer version in the file | yes | installs the update (manual update through UpdateCore), then wraps |
| installed, older version in the file | either | wraps the installed version and says that the older file was ignored |
| not installed, `--portable` | no | portable wrapper from the file without installing (§10.1) |

`apkrun wrap <package>` wraps an installed package. Without an existing wrapper and without `--replace`, it never touches existing files (§6.4).

---

## 13. Errors

```swift
public enum WrapperFailure: APKRunError {
    // generation and lifecycle (apkrund)
    case packageNotInstalled(PackageID)
    case invalidName(String)
    case customIconInvalid(IconInputProblem)          // unreadable, not square, smaller than 512 px
    case iconConversionFailed(String)                 // iconutil status and message
    case launcherTemplateInvalid(String)              // missing, wrong architecture, signature invalid
    case destinationNotWritable(URL)
    case destinationNotAccessible(URL, stagingToken: String)
    case nameConflict(URL, existing: ExistingItemKind) // .otherWrapper(PackageID), .otherApp, .file
    case wrapperExists(PackageID, URL)
    case wrapperRunning(PackageID)
    case wrapperNotFound(PackageID)
    case signingFailed(status: Int32, message: String)
    case verificationFailed(String)
    case registrationFailed(OSStatus)                 // LSRegisterURL, reported as a warning
    case registryUnavailable                          // unreadable registry.json (kept as .corrupt-<time>)
    case refreshBlocked(String, stagingToken: String?) // App Management denial; the token of the staged Contents for APKRun.app (§9.3)
    case stagingExpired                               // placeStagedWrapper: unknown token, older than 60 min, or from before an apkrund restart (§6.3, §9.3)
    // approval and bootstrap
    case bundleInvalid(URL, reason: BundleProblem)
    case approvalDenied
    case approvalTimedOut
    case approvalNotFound                             // decideApproval for an unknown, answered, or expired prompt (§7.3 step 5)
    case translocated
    case bootstrapInvalid(BootstrapProblem)           // hash mismatch, package mismatch, bad JSON
    case bootstrapNotAllowed(BootstrapRefusal)        // already installed, not approved
    // launcher (shown as screens, §5.4)
    case runtimeMissing
    case runtimeNotReady
    case runtimeTooOld(required: String, found: String)
    case launcherTooOld(launcherAPI: String, runtimeAPI: String)
    case wrapperDamaged(String)
    // distribution
    case distributionToolMissing(String)
    case identityNotFound(String)
    case notarizationFailed(submissionID: String, summary: String)
}

public enum IconInputProblem: String, Sendable, Codable {
    case unreadable, notSquare, tooSmall              // tooSmall: smaller than 512 px
}

public enum BundleProblem: String, Sendable, Codable {    // the static checks of §7.3 step 1
    case signatureInvalid, identifierMismatch, bundleIDMismatch, wrapperJSONInvalid, packageMismatch
}

public enum BootstrapProblem: String, Sendable, Codable {
    case hashMismatch, packageMismatch, malformed     // malformed: bad JSON
}

public enum BootstrapRefusal: String, Sendable, Codable {
    case alreadyInstalled, notApproved
}
```

Each case has a stable code, a message, and a remediation in [error-catalog.md](../03-reference/error-catalog.md). Store and runtime errors that pass through (for example from `importBootstrap`) keep their own types.

---

## 14. Logging, markers, health

- Subsystem `io.apkrun.wrapper`. Categories: `generate`, `sign`, `icon`, `registry`, `approval`, `lifecycle` (apkrund); `launcher`, `window` (wrapper process). Package ID, bundle ID, and cdhash are `privacy: .public`. Paths inside the user's home are `.private` ([diagnostics.md](diagnostics.md) §6).
- Markers ([diagnostics.md](diagnostics.md) §4): `WRAPPER_PROCESS_START` (launcher `main`, part of the launch budget), `WRAPPER_GENERATE_START` / `WRAPPER_GENERATE_END`, `WRAPPER_REFRESH_END`, `WRAPPER_APPROVAL_END {result}`.
- Health checks for `apkrun doctor` ([diagnostics.md](diagnostics.md) §7):

| Check | Warning when |
|---|---|
| `wrappers.template` | the generic launcher is missing, its signature is invalid, or it is not arm64 |
| `wrappers.registry` | `registry.json` is unreadable, or pending entries remain after recovery |
| `wrappers.status` | any entry is `missing`, `signatureInvalid`, or `unknownPackage` (listed with the action from §9.1) |
| `wrappers.launcher` | wrappers that are one major behind (information) or two majors behind (warning) |
| `wrappers.registration` | a registered wrapper that LaunchServices does not know. `doctor --fix` re-registers it |

The diagnostics bundle includes `registry.json` with paths reduced to their last component and bookmarks removed.

---

## 16. Tests

| Tier | What | Where |
|---|---|---|
| T0 | `BundleIDMapper`: the table of §4.1, `_` mapping, uppercase suffix, 1 000 random valid IDs (valid and unique ignoring case). File names (§4.3) with `/`, `:`, emoji ZWJ sequences, 300-byte names, empty names | `Packages/WrapperCore/Tests/WrapperCoreTests/` |
| T0 | `wrapper.json` and `bootstrap.json`: sorted keys, schema validation, unknown `formatVersion` rejected | `Packages/WrapperCore/Tests/WrapperCoreTests/` |
| T0 | Compatibility matrix of §5.3 (versions and API majors) | launcher unit tests |
| T0 | Icon rules of §8.2: adaptive crop, opaque-corner detection, legacy fit, placeholder color stability | `Packages/WrapperCore/Tests/WrapperCoreTests/` |
| T1 | Generation into a temporary directory: determinism (§6.5), conflicts (§6.4), `pending` recovery after a crash at each step of §6.2, `refreshing` recovery at each step of §9.3 | `Packages/WrapperCore/Tests/WrapperCoreTests/` |
| T1 | Registry: atomic writes, corrupt-file handling, one entry per bundle ID, denied entries and expiry | same |
| T1 | `WrapperValidator` states and precedence with fixture bundles: moved, renamed, trashed, modified resource, modified Info.plist, unknown package, older launcher | same |
| T1 | Approval service with a fake UI client: approve, deny, timeout, rate limits, replacement of an existing entry | same |
| T1 | Icon master golden images for the fixture icons, within a perceptual threshold | same |
| T2 | Launcher screens R, S, V, L, D with a real apkrund and test switches (`APKRUN_LAUNCHER_TEST_NO_RUNTIME=1` for screen R, debug builds only) | `Tests/IntegrationTests/` |
| T2 | Endpoint security: a copy of a wrapper with a changed resource, and a binary re-signed with the same identifier, are both refused and require approval (NFR-SEC-07) | `Tests/IntegrationTests/` |
| T2 | Double-click `HelloText.app` in Finder: `NSWorkspace.open`, plus an XCUITest-driven click where available | `Tests/IntegrationTests/` |
| T2 | Spotlight (`mdfind` finds both destinations within 60 s), launch from the Dock, and App Translocation with a quarantined copy (screen T) | `Tests/IntegrationTests/` |
| T2 | Portable first run in a second user account | `Tests/IntegrationTests/` |
| T2 | Structural checks for the G9 check: file-hash list and deep validation (§9.1) | `Tests/IntegrationTests/` |
| T3 | Gate checks G8 (`G8Wrapper`) and G9 (`G9WrapperIntegrity`) on the reference Mac | `Tests/AcceptanceTests/` |
| T3 | Manual: keep `HelloText.app` in the Dock, log out and in, launch it from the Dock and from Spotlight by its label ([test-strategy.md](../04-plan/test-strategy.md) §8.5). Not automated | manual checklist |
| T3 | Distribution wrapper notarization (nightly, needs credentials) | nightly CI |

The development script `scripts/dev/make-wrapper.sh <package> <out-dir> [--minimum-version <v>] [--package-id <id>]` builds a wrapper by hand: it copies the launcher, writes Info.plist and `wrapper.json`, signs as in §7.1, and registers the result with `apkrun wrapper approve`.

---

## 17. Open items

- R-17: Gatekeeper and App Management policy for generated wrappers (§7.1, §11).
- R-19: background mode without a Dock tile flash, and notification permission across wrapper refreshes (§5.8, §9.3).
- R-20: Dock pins and App Management with the `Contents` swap (§9.3).
- OQ-22: whether the macOS Apps view lists wrappers outside the Applications folders (§6.3).
- OQ-23: URL schemes and App Links for Android apps (post-v1, §2.1).
- OQ-24: Liquid Glass icons (`Assets.car`) without Xcode (post-v1, §8.4).
- OQ-25: self-updating distribution wrappers, or registry trust by Developer ID team (post-v1, §7.2, §11).
