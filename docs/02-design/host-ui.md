# Host UI (APKRun.app and APKRunMenuBar)

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [runtime-daemon.md](runtime-daemon.md) §9 (provisioning), [package-store.md](package-store.md) §4.7, §8, §11, [update-system.md](update-system.md) §2.3, §9, [wrapper.md](wrapper.md) §6.6, §7.3, §9.1, [desktop-integration.md](desktop-integration.md) §2, [diagnostics.md](diagnostics.md), [cli.md](cli.md), [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.4 |
| Tasks | #066 onboarding (M4), #077 home and store UI, #078 add flow, #079 app settings (M7), #086 menu bar (M9), #092 localization (M12), and the UI parts of #037, #047, #057, #058, #059, #060, #076, #082, #083, #084, #085, #087, #089 |

APKRun.app is where users add Android apps, manage them, and fix problems. The apps themselves run in their own Mac apps (wrappers) and never inside APKRun.app. APKRunMenuBar is a small status item for the runtime, running apps, and updates.

---

## 1. Principles

1. **A client, not an owner.** APKRun.app and APKRunMenuBar own no runtime state. They use `RuntimeClient` only ([../01-architecture/modules.md](../01-architecture/modules.md) §2) and show what apkrund reports. Quitting them never stops Android or an app.
2. **Opening APKRun.app does not start Android.** Only an action that needs Android starts it: Open, Install, Update Now, Start Android. Observing connections are not runtime activity ([runtime-daemon.md](runtime-daemon.md) §5.1).
3. **Works while Android is stopped.** The package list, settings, update checks, and wrapper actions use the last known state. Actions that need Android say so ("Android will start to install ‹App›").
4. **Never shows Android UI.** Android app pixels appear only in wrapper windows.
5. **Every error has a next step.** Messages and remediations come from the error catalog ([../03-reference/error-catalog.md](../03-reference/error-catalog.md)). Each error view has **Copy Details** (the code and the operation ID, no personal data) and, where it helps, **Troubleshooting…**.
6. **One source of truth for text.** All strings are in String Catalogs (§13). The same catalog keys serve the GUI and the menu bar.

---

## 2. Structure

### 2.1 Targets and scenes

| Target | Bundle ID | Role |
|---|---|---|
| `Apps/APKRun` (SwiftUI app) | `io.apkrun.APKRun` | main window, Settings, onboarding, approvals, APKRun's own notifications |
| `Apps/APKRunMenuBar` (SwiftUI `MenuBarExtra`, `LSUIElement = true`) | `io.apkrun.APKRunMenuBar` | status item. Registered as a login item (`SMAppService.loginItem(identifier:)`) from `Contents/Library/LoginItems/` ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §4) |

APKRun.app scenes:

| Scene | Content |
|---|---|
| `Window("APKRun", id: "main")` | one main window: sidebar and detail (§5). Closing it keeps the app running while an operation is in progress, otherwise the app quits (`applicationShouldTerminateAfterLastWindowClosed` is true when no operation runs) |
| `Settings` | app-wide settings (§9) |
| sheets on the main window | onboarding (§4), add flow (§6), uninstall (§8), confirmations |
| `Window(id: "approval")` | wrapper approvals (§10.1). A separate small window, so it can appear on top without the main window |

APKRun.app keeps the standard SwiftUI menus and adds only these commands:

| Menu | Item | Action |
|---|---|---|
| APKRun | **Check for Updates…** | the same as **Check Now** in Settings → General → Updates (§9.1, [runtime-maintenance.md](runtime-maintenance.md) §3.2). #057 |
| File | **Add App…** (⌘O) | opens the file picker of the add flow (§6). #078 |
| Help | **Third-Party Notices** | opens `Contents/Resources/ThirdPartyNotices.html` with `NSWorkspace` in the default browser ([../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md) §6.4). #093 |

### 2.2 Models

`@Observable` models on the main actor, fed by `RuntimeClient` requests and event subscriptions ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.4). Views never call XPC directly.

| Model | Source | Used by |
|---|---|---|
| `RuntimeStatusModel` | `runtimeStatus`, topic `runtime` | home header, menu bar, onboarding |
| `PackageListModel` | `listPackages(.all)`, topic `packages` | home, sidebar badges |
| `PackageDetailModel` | `packageInfo`, `integrationStatus`, `listWrappers` (filtered), topics `packages`, `integrations`, `wrappers` | app page |
| `UpdatesModel` | UpdateCore operations and topic `updates` ([update-system.md](update-system.md) §11) | home rows, Updates list, menu bar |
| `SessionsModel` | topic `sessions` | "running" indicators, menu bar |
| `OperationCenter` | long-running operations ([runtime-daemon.md](runtime-daemon.md) §8.3) | the toolbar activity indicator and its popover, progress in sheets |
| `ApprovalCenter` | broker approval requests | §10.1 |
| `HostNotificationClient` | `HostNotifier` requests ([update-system.md](update-system.md) §9) | §11 |
| `SettingsModel` | the configuration operations ([../03-reference/configuration.md](../03-reference/configuration.md) §1.4) | Settings |
| `MaintenanceModel` | `selfUpdateStatus`, `imageUpdateStatus`, topic `maintenance`, plus Sparkle's results from `SelfUpdateController` ([runtime-maintenance.md](runtime-maintenance.md) §8) | Settings → General and Storage, home banners, menu bar |

On a reconnect to apkrund (after a crash or an update), every model reloads its data. While apkrund is unreachable, the main window shows a banner "APKRun's background service isn't running" with **Restart Service** (re-registers the agent, [runtime-daemon.md](runtime-daemon.md) §2.1) and **Troubleshooting…**.

### 2.3 Source layout

```text
Apps/
├── APKRun/
│   ├── APKRunApp.swift # scenes, URL and document handling (§3)
│   ├── Models/ # §2.2
│   ├── Features/
│   │   ├── Onboarding/ # §4
│   │   ├── Home/ # §5
│   │   ├── AddFlow/ # §6
│   │   ├── AppPage/ # §7 (one file per settings section)
│   │   ├── Uninstall/ # §8
│   │   ├── Settings/ # §9 (one file per pane)
│   │   ├── Approvals/ # §10
│   │   └── Troubleshooting/ # §9.8
│   ├── Components/ # shared views: AppIconView, StatusBadge, ErrorView, ProgressRow, DropZone
│   └── Resources/ # Localizable.xcstrings, Assets.xcassets, InfoPlist.xcstrings
└── APKRunMenuBar/ # menu bar UI, described in §12
```

`Components/` is a named owner of shared views inside the app target, not a general utilities folder ([../01-architecture/modules.md](../01-architecture/modules.md) §1).

---

## 3. Entry points, URLs, and documents

### 3.1 `apkrun://` routes

APKRun.app declares the URL scheme `apkrun` (`CFBundleURLTypes`). URLs **only navigate**. They never perform an action, because any process can open a URL ([wrapper.md](wrapper.md) §5.4).

| URL | Opens |
|---|---|
| `apkrun://home` | the main window, Apps |
| `apkrun://package/<packageId>` | the app page |
| `apkrun://package/<packageId>/<section>` | the app page at a section: `general`, `window`, `input`, `integrations`, `updates`, `mac-app`, `storage` |
| `apkrun://updates` | the Updates list |
| `apkrun://settings/<pane>` | Settings at a pane: `general`, `runtime`, `updates`, `privacy`, `files`, `language`, `storage`, `troubleshooting`, `advanced` |
| `apkrun://setup` | onboarding, if setup is not complete; otherwise home |
| `apkrun://report[?package=<packageId>]` | the diagnostics report sheet, with the package preselected as the focus ([diagnostics.md](diagnostics.md) §8.5). The report is created only after the user clicks **Create Report…** |

- `<packageId>` must match the Android package-name grammar. Unknown packages show the home screen with "‹id› isn't installed in APKRun." Unknown routes open the home screen.
- Wrappers open these URLs for **Open APKRun** ([wrapper.md](wrapper.md) §5.4). Notifications from APKRun use them as their target (§11).

### 3.2 Documents (FR-UI-06)

| Type | UTI | Declaration | Role, rank |
|---|---|---|---|
| `.apk` | `com.android.package-archive` (conforms to `public.zip-archive`, `public.data`) | imported (`UTImportedTypeDeclarations`), because the type belongs to Android | Viewer, `Default` |
| `.apks` | `io.apkrun.apks` | exported | Viewer, `Owner` |
| `.xapk` | `io.apkrun.xapk` | exported | Viewer, `Owner` |
| `.apkm` | `io.apkrun.apkm` | exported | Viewer, `Owner` |

Opening a file (double-click, **Open With**, a drop on the Dock icon, or `open -a APKRun file.apk`) starts the add flow (§6) with that file. Several files at once are one import when they form a split set, otherwise one add flow each, in order ([package-store.md](package-store.md) §4.1).

### 3.3 Launch arguments

| Argument | Meaning |
|---|---|
| (none) | normal start. If setup is not complete, the onboarding sheet opens (§4) |
| `--notify` | started by apkrund to post notifications ([update-system.md](update-system.md) §9). No window, no Dock activation. Quits 30 s after the last notification is handled |
| `--approve` | started by apkrund for a wrapper approval (§10.1). Only the approval window is shown |
| `--register-runtime` | registers the apkrund LaunchAgent with `SMAppService`, then quits. Used by RuntimeClient, `apkrun setup`, and the development install script when apkrund is not registered ([runtime-daemon.md](runtime-daemon.md) §2.6, [cli.md](cli.md) §4.1) |

---

## 4. Onboarding (#066)

Shown as a sheet on the first launch, and whenever setup is not `complete`. It drives the provisioning steps of [runtime-daemon.md](runtime-daemon.md) §9.2 and shows `ProvisioningState`.

```text
┌────────────────────────────────────────────────┐
│ Welcome to APKRun                              │
│ Run Android apps as Mac apps.                  │
│ ────────────────────────────────────────────   │
│ ✓ Background service allowed                   │
│ ✓ This Mac can run APKRun                      │
│ ◐ Installing Android… ▓▓▓▓▓░░ 62%              │
│ ○ Starting Android for the first time          │
│ ○ Checking that everything works               │
│ ────────────────────────────────────────────   │
│ This takes a few minutes. You can close this   │
│ window. Setup continues when you come back.    │
│ [ Cancel ]                                     │
└────────────────────────────────────────────────┘
```

| Step | UI |
|---|---|
| 1. Background service | registers apkrund. `.requiresApproval`: "Allow APKRun in System Settings → General → Login Items & Extensions." with **Open System Settings**. The sheet polls the status every 2 s |
| 2. Host check | every failed requirement from `HostRequirementsCheck` with its remediation ([runtime-daemon.md](runtime-daemon.md) §9.1). A blocking failure ends onboarding here with **Quit**. The memory warning allows **Continue** |
| 3. Android image | release builds from #087: "Download Android (‹size›)" with the channel's image and a progress bar. Development builds: **Choose Image…** (an open panel for a bundle directory or `.aar`, [runtime-daemon.md](runtime-daemon.md) §9.3) |
| 4. First boot | the boot phase as text ("Starting Android… system services") and the estimated fraction |
| 5. Verify | "Checking that everything works" |
| Done | "You're ready." with a drop zone: "Drag an APK here to add your first app" and **Add App…** |

- Failure: the failed step turns red with the catalog message, **Try Again**, and **Report…** (a diagnostics report, §9.8). After 2 failed first boots, **Start Over** (recreate the instance) appears ([runtime-daemon.md](runtime-daemon.md) §9.2).
- **Cancel** stops the current step. Completed steps stay completed. The next launch continues at the first incomplete step.
- The CLI equivalent is `apkrun setup` ([cli.md](cli.md)).

---

## 5. Main window (#077, FR-UI-01, FR-UI-04)

### 5.1 Layout

```text
┌───────────────┬──────────────────────────────────────────────────────────────────┐
│ APKRun        │ Android ● Ready · 2 apps running [Stop Android]                  │
│ ▸ Apps 4      │ Drag APK, APKS, or XAPK files here to add                        │
│ ▸ Updates 1   │ [icon] Discord ● running                                         │
│ ▸ Other       │ Android version 245.0 · Updates: Automatic                       │
│ Android Apps  │ Up to date [Open] [Settings]                                     │
│               │ [icon] Spotify                                                   │
│               │ Android version 8.10.2 · Updates: Automatic                      │
│               │ Update available 8.10.3 [Update Now] [Open]                      │
│               │ [icon] F-Droid Client                                            │
│               │ Android version 1.21 · Updates: Notify only                      │
│               │ ⚠ Mac app not found [Create Mac App] [Open]                      │
└───────────────┴──────────────────────────────────────────────────────────────────┘
```

- `NavigationSplitView` with the sidebar sections **Apps** (packages managed by APKRun), **Updates** (packages with an update available, waiting, or failed; badge = count), and **Other Android Apps** (launchable packages that APKRun does not manage, [package-store.md](package-store.md) §9.3).
- The toolbar has **Add App…** (⌘O), a search field (name or package ID), the sort menu (Name, Recently Used, Recently Updated), and the `OperationCenter` activity indicator.

### 5.2 Runtime header

| `RuntimeState` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §2) | Shown | Button |
|---|---|---|
| `stopped` | ○ Stopped | **Start Android** |
| `booting(phase)` | ◐ Starting… (phase text) | — |
| `ready` | ● Ready | **Stop Android** (asks when sessions run: "Stop Android and close 2 apps?") |
| `suspended` | ● Sleeping (resumes when you open an app) | **Stop Android** |
| `stopping` | ◐ Stopping… | — |
| `failed(f)` | ⚠ Android stopped unexpectedly | **Restart**, **Troubleshooting…** |
| boot-loop guard active | ⚠ Android failed to start several times | **Restart**, **Start in Graphics Safe Mode**, **Reset Android…** ([runtime-daemon.md](runtime-daemon.md) §3.6) |
| not provisioned | Setup isn't finished | **Continue Setup** |
| `booting(phase)` with `bootPurpose =.imageUpdate(A, B)` | ◐ Updating Android… (phase text) | — ([runtime-maintenance.md](runtime-maintenance.md) §4.7) |
| host state `restartPending` | banner: "APKRun was updated. Restart Android to finish. ‹N› apps will close." | **Restart Now** ([runtime-maintenance.md](runtime-maintenance.md) §3.6, §7.3) |
| current image too old for this APKRun (`incompatibleProtocol / hostNewer`) | banner: "Android needs an update to work with this version of APKRun." with the download and update progress | — ([runtime-maintenance.md](runtime-maintenance.md) §4.10) |
| current image needs a newer APKRun (`incompatibleProtocol / guestNewer`, `incompatibleRuntime`) | banner with the entry's own text | **Check for Updates** (`updateAPKRun`, [runtime-maintenance.md](runtime-maintenance.md) §4.10) |

The running-app count comes from `SessionsModel` (sessions in `running` or `backgrounded`).

While a live health check is in `warning` or `failure` ([diagnostics.md](diagnostics.md) §7.1), the header adds "⚠ Needs attention" with **Troubleshooting…**, next to the runtime state.

### 5.3 App rows

Each row shows the icon (`packageIcon` at 64 px, or the host preview), the display name, "Android version ‹versionName›" (FR-UI-04), the update mode, a status line, and up to two buttons. The status line shows the most important of these, in order:

| Priority | Condition | Status line | Buttons |
|---|---|---|---|
| 1 | package `broken(reason)` | "Needs attention: ‹reason›" | **Repair…** |
| 2 | package `installing`, `updating(phase)`, `uninstalling`, `needsReinstall` | "Installing…", "Updating…", "Removing…", "Reinstalling after Android reset…" with progress | — |
| 3 | update failed or rolled back ([update-system.md](update-system.md) §8.3) | "Update failed" / "Rolled back to ‹version›" | **Details** |
| 4 | update waiting ([update-system.md](update-system.md) §7.4) | "Will update when ‹App› quits" | **Update Now** |
| 5 | update available (notify-only or manual check) | "Update available ‹version›" | **Update Now** |
| 6 | wrapper state not `valid` ([wrapper.md](wrapper.md) §9.1) | "Mac app not found" / "APKRun can't check this location" / "This Mac app was modified" | the state's action from wrapper.md §9.1 |
| 7 | wrapper refresh reasons | "Mac app can be updated" | **Update Mac App** |
| 8 | otherwise | "Up to date", or "Updates: Manual" for manual packages | **Open**, **Settings** |

A running app has a green dot and "running". The context menu has **Open**, **Show Mac App in Finder**, **Check for Updates**, **Settings…**, **Uninstall…**.

**Open** calls `launch(packageID)` ([runtime-daemon.md](runtime-daemon.md) §7.2). It opens the wrapper when one is registered and valid, otherwise the generic launcher.

### 5.4 Other Android Apps

Packages installed in Android that APKRun does not manage (preinstalled apps, apps installed with `adb`). Each row has **Open** and **Manage with APKRun** (`adoptPackage`, [package-store.md](package-store.md) §9.3). System packages without a launcher activity are not listed.

### 5.5 Empty state and drops

- No apps: a large drop zone with "Add your first Android app", **Add App…**, and a link "Where do I get APK files?" to the user guide.
- Drops on the drop zone, anywhere in the list, or on the Dock icon start the add flow (§6). Unsupported files are refused with "APKRun can add .apk, .apks, .xapk, and .apkm files."

---

## 6. Add flow (#078, FR-UI-02, FR-UI-06)

A sheet with four stages. The GUI passes open file handles; it never passes paths ([package-store.md](package-store.md) §4.1).

```text
1 Reading 2 Review 3 Installing 4 Done
───────── ────────────────────────────── ──────────── ──────────────
Copying… ▓▓▓░ [icon] Discord Starting Android… ✓ Discord is ready
Checking… ▓▓▓▓ com.discord · version 245.0 (245000) Installing… ▓▓▓░ [Open Discord]
Signed by: ‹developer digest› ⓘ Creating Mac app… [Show in Finder]
[Cancel] Size 142 MB · Needs Android 8.0+ [Done]
────────────────────────────
Updates ○ Automatic ○ Notify only ● Manual
Update source: none [Choose…]
☑ Create Mac app "Discord"
Location: Applications (for me) ▾
▸ Details (files, splits, permissions)
[Cancel] [Install]
```

### 6.1 Review stage

Content from `ImportPreview` ([package-store.md](package-store.md) §4.7):

| Element | Rule |
|---|---|
| Name, icon | the host label and icon preview. The Mac app name field starts with the same name |
| Package and version | package ID, `versionName (versionCode)` |
| Signer | the certificate digest (short form) with an ⓘ popover: full SHA-256 digests, scheme, lineage length, verification level |
| Compatibility | the compatibility database entry, if the app has one (#090, [diagnostics.md](diagnostics.md) §10): the label **Works**, **Works with limitations**, or **Unsupported**, with the known issues and their workarounds. `unsupported` changes the button to **Install Anyway**. Below that, `warnings` as yellow rows: no arm64 code, 32-bit only native code, SDK outside the runtime's range, excluded splits ([package-store.md](package-store.md) §4.6). Blocking problems replace the Install button with the reason |
| Updates | **Automatic**, **Notify only**, or **Manual**. Without an update source, only **Manual** is enabled, with "Choose an update source to turn on automatic updates" and **Choose…** (provider picker, [update-system.md](update-system.md) §4). A detected provider is offered as a suggestion that is off until the user turns it on ([update-system.md](update-system.md) §4.7) |
| Create Mac app | toggle (default on), name field, location pop-up: **Applications (for me)** (`~/Applications`), **Applications (all users)** (only for admin users), **Other…** ([wrapper.md](wrapper.md) §6.3, §6.6) |
| Details | file list with sizes, excluded splits, requested permissions. Permissions are informational: Android asks for runtime permissions in the app's window |

Relation handling:

| `ImportRelation` | Sheet |
|---|---|
| `newPackage` | as above, button **Install** |
| `sameAsInstalled` | "‹App› ‹version› is already installed." **Open**, **Done** |
| `reinstallSameVersion` | "Reinstall ‹App› ‹version›?" button **Reinstall** |
| `update(from:)` | "Update ‹App› from ‹old› to ‹new›?" button **Update**. The update is gentle: when the app is open, "‹App› will update when you quit it" with **Quit and Update** ([update-system.md](update-system.md) §7.3) |
| `downgrade(from:)` | refused with the message of [package-store.md](package-store.md) §4.7. Only **Done** |
| `otherSigner` | refused with the message of [package-store.md](package-store.md) §4.7. Only **Done** |
| `uninstalledWithData(version)` | "Reinstall ‹App› and restore its data?" button **Reinstall** |

### 6.2 Installing and done

- **Install** calls `installImported(ticket, options)` and shows the operation's progress: "Starting Android…" (when the runtime was stopped), "Installing in Android…", "Creating Mac app…".
- An install failure shows the catalog message. The package is not added. **Try Again** keeps the ticket.
- A wrapper failure after a successful install shows "Discord was installed, but the Mac app couldn't be created: ‹reason›" with **Try Again** (the package stays, [wrapper.md](wrapper.md) §6.6). `destinationNotAccessible` offers **Choose Another Location…** and then `placeStagedWrapper`.
- **Done** closes the sheet. **Open ‹App›** launches it. The sheet can be closed during Installing. The work continues and appears in `OperationCenter`.

---

## 7. App page and per-app settings (#079, FR-UI-03)

The app page is the detail view of a package. Its header shows the icon, the name, the version, the running state, and **Open**, **Update Now** (when available), and a **…** menu (Show Mac App in Finder, Check for Updates, Repair…, Uninstall…).

Every setting is written with `updatePackageSettings(id, patch)` at once (no Save button). Settings that apply at the next start of the app say "Applies the next time ‹App› opens."

A value that comes from the compatibility database, not from the user, shows "Recommended for this app" ([diagnostics.md](diagnostics.md) §10.3). **Reset** removes the package's stored value and returns to the recommendation, or to the built-in default when there is none ([../03-reference/configuration.md](../03-reference/configuration.md) §3.2). `integrations.defaults.*` apply only when a package is first recorded, so Reset never returns to them.

### 7.1 General

| Item | Setting or source |
|---|---|
| Name | the Mac app name (wrapper customization, [wrapper.md](wrapper.md) §6.1). Changing it offers **Update Mac App** |
| Icon | **Android Icon** or **Choose…** (an image file). Changing it offers **Update Mac App** |
| Package, version, installed from, installed on, last updated | the package record |
| Signer | digest with the ⓘ popover of §6.1 |
| Compatibility | the compatibility database label and known issues for the installed version (#090, [diagnostics.md](diagnostics.md) §10). Nothing is shown for apps without an entry |
| Size | artifacts on the Mac and app data in Android (from `packageInfo`) |

### 7.2 Window

| Control | Key | Values |
|---|---|---|
| Default size | `window.defaultWidth`, `window.defaultHeight` | points; **Use Current Size** takes the size of the open window |
| Resizable | `window.resizable` | on / off |
| Always on top | `window.alwaysOnTop` | off (default) / on: the window floats above other windows (`NSWindow.level =.floating`, [display-and-windowing.md](display-and-windowing.md) §7.7) |
| Zoom | `window.zoom` | 75 %–200 % ([display-and-windowing.md](display-and-windowing.md) §6.1) |
| When I close the window | `window.closeBehavior` | **Quit the app** (`stop`) / **Keep it running in the background** (`keepRunning`). The second is needed for notifications and music while the window is closed ([desktop-integration.md](desktop-integration.md) §5.3) |
| Window mode | `window.mode` | **Standard** (`secondaryDisplay`) / **Compatibility** (`primaryDisplayCompatibility`) with the explanation of [display-and-windowing.md](display-and-windowing.md) §8 |

### 7.3 Input

| Control | Key | Values |
|---|---|---|
| Esc key | `input.escapeKey` | **Back** (`back`, default) / **Escape** (`escape`) |
| Right click | `input.secondaryClick` | **Mouse right click** (`mouseSecondary`, default) / **Long press** (`longPress`) |
| Scrolling | `input.scrollMode` | **Scroll** (`scroll`, default) / **Touch drag** (`touchDrag`) |
| Mouse hover | `input.hover` | on (default) / off |
| Send the Command key to the app | `input.sendCommandKey` | off (default) / on |

The semantics are in [input.md](input.md) §4–§5.

### 7.4 Integrations

The keys and defaults are those of [desktop-integration.md](desktop-integration.md) §2.1. Each row also shows what `integrationStatus` reports: "Not available with this Android image", "Turned off for all apps in Settings → Privacy", or the macOS permission state.

| Control | Key | Values and extra UI |
|---|---|---|
| Clipboard | `integrations.clipboard` | on / off. Footnote: "Android shares one clipboard among its apps." |
| Notifications | `integrations.notifications` | on / off. macOS permission for the Mac app (**Open Notification Settings** when denied). A hint when `window.closeBehavior = stop`: "‹App› can only notify you while it is running." |
| Links | `integrations.links` | **Ask** / **Open in Mac browser** / **Open in Android** |
| Files | `integrations.files` | on / off: "Drag files into ‹App›, and save files from ‹App› to your Mac." |
| Shared folders | `integrations.sharedFolders` | **Off** / **Read only** / **Read and write**, with the list of folders from Settings → Files and **Edit Folders…** |
| Microphone | `integrations.microphone` | on / off. Turning on the first microphone app shows "Android needs to restart to use the microphone.", and turning off the last one shows "Android needs to restart to turn off the microphone.", each with **Restart Android Now** / **Later** (the input stream is attached only while a package uses it, [vm.md](vm.md) §11). macOS permission state for APKRun |
| Camera | — | "Not supported yet" (FR-INT-10) |

### 7.5 Updates

The content listed in [update-system.md](update-system.md) §9: mode (Automatic / Notify only / Manual, with the authority rules of §2.3 there), update source picker and configuration, **Check Now**, last check time and result, history, **Roll Back to ‹version›…**, "Undo updates that fail to start" (`update.autoRollback`), and "Open the app briefly after updating to check it" (`update.healthCheckLaunch`).

**Updated by** sets the update authority with `setUpdateAuthority` ([update-system.md](update-system.md) §2.1). #079 builds it.

| Choice | Authority | Notes |
|---|---|---|
| **APKRun** | `apkrun` when the record keeps a provider, else `manual` | the mode choices above apply |
| **Another app store in Android** | `external` | asks first: "APKRun will stop updating ‹App›. An app store inside Android can update it instead." The mode choices are replaced by "Managed by another installer" (update-system §2.3) |
| "Google Play" (read-only) | `googlePlay` | shown only for such packages (#097). No change is possible |

### 7.6 Mac App

The section of [wrapper.md](wrapper.md) §6.6: status, name, icon, location with **Show in Finder**, **Update Mac App** (with the refresh reasons), **Create Mac App** when none exists, **Make Local Mac App** for portable wrappers ([wrapper.md](wrapper.md) §10.2), **Remove Mac App…**.

### 7.7 Storage

Sizes, **Uninstall…** (§8). For packages in `broken` state, **Repair…** explains the reason and offers the repair or **Remove from APKRun** ([package-store.md](package-store.md) §11.1 `repairPackage`).

---

## 8. Uninstall dialog (#076)

```text
Uninstall “Discord”?
Discord and its data will be removed from Android.
☐ Keep app data (reinstalling Discord later restores it)
☑ Also move the Mac app to the Trash
[Cancel] [Uninstall]
```

- The choices and defaults are those of [package-store.md](package-store.md) §8. "Also move the Mac app to the Trash" is shown only when a wrapper exists.
- If Android cannot start, the dialog says so and offers **Remove from APKRun** (`forget`).
- An open app is closed first. The dialog says "Discord is open and will be closed."

---

## 9. Settings window

Tabs in a `Settings` scene. Keys refer to the app configuration ([../03-reference/configuration.md](../03-reference/configuration.md)).

### 9.1 General

- **Show APKRun in the menu bar** (registers or unregisters the APKRunMenuBar login item, default on). It has no settings key: the toggle shows the login item registration ([../03-reference/configuration.md](../03-reference/configuration.md) §2.10).
- **Default location for new Mac apps** (Applications for me / for all users / Ask each time; `wrappers.defaultLocation`).
- **Updates** (from #057 and #087): the versions of APKRun and Android (with the security patch level), "Check for updates automatically" (`maintenance.checkAutomatically`), "Install APKRun updates automatically" (`maintenance.installAPKRunAutomatically`), Android system updates **Install automatically when the Mac is idle** / **Ask before installing** (`maintenance.installImages`), "Download Android system updates in the background" (`maintenance.downloadImagesAutomatically`), "Notify me when Android was updated" (`maintenance.notifyImageInstalled`), the channel (`maintenance.channel`), **Check Now** with the last check time, and one status line with its action (**Install Update…**, **Install and Relaunch Now**, **Update Android Now…**, **Cancel**, **Try Again**). The layout and status lines are in [runtime-maintenance.md](runtime-maintenance.md) §7.1. Opening this pane refreshes Sparkle's information at most every 5 minutes. These APKRun and Android system updates are separate from the Android app updates of §9.3.

### 9.2 Runtime

| Control | Key |
|---|---|
| Start Android: **When an app opens** (`onDemand`, default) / **When I log in** (`atLogin`) | `runtime.startPolicy` ([runtime-daemon.md](runtime-daemon.md) §5.4) |
| Put Android to sleep after ‹n› minutes without apps | `runtime.idleSuspendMinutes` |
| Stop Android after ‹n› minutes without apps (counted from when Android became idle, including the time asleep) | `runtime.idleStopMinutes` |
| Restart Android automatically after a crash | `runtime.autoRestart` |
| Memory, processors | `runtime.memoryGiB`, `runtime.cpuCount` (applies at the next start) |
| Android storage | `runtime.userdataGiB`. Fixed when Android is set up. A change applies only after **Reset Android…** (§9.8), and the control says so ([android-image.md](android-image.md) §5.2) |
| Maximum open apps | `display.maxSessions` |
| Sound output | `audio.output` (applies at the next start, **Restart Android Now**) |

### 9.3 Updates

Global update settings ([update-system.md](update-system.md) §3): check interval (`updates.checkIntervalHours`), "Download on expensive networks" (`updates.downloadOnExpensiveNetwork`), "Start Android to install updates" (`updates.startRuntimeToInstall`), "Notify me after automatic updates" (`updates.notifyInstalled`), and the list of configured update sources.

### 9.4 Privacy

- The global switches `integrations.enabled.*` and the defaults for new apps `integrations.defaults.*` ([desktop-integration.md](desktop-integration.md) §2.2).
- **Mac apps you didn't allow**: the denied wrapper list with **Remove** ([wrapper.md](wrapper.md) §7.3).
- macOS permission states for APKRun (microphone) with **Open System Settings**.

### 9.5 Files (#082)

The shared folder list ([desktop-integration.md](desktop-integration.md) §6.4): the APKRun Shared folder (always first, **Show in Finder**), user-added folders with their maximum access (Read only / Read and write), their availability ("Can't access. Allow APKRun in System Settings → Privacy & Security → Files and Folders."), **Add Folder…** (an open panel, the result goes to `addSharedFolder` as a bookmark) and **Remove**.

### 9.6 Language & Region

"Use the Mac's language in Android" (`system.syncLocale`), "Use the Mac's time zone" (`system.syncTimeZone`), "Use the Mac's 12/24-hour setting" (`system.syncClockFormat`). Defaults on ([desktop-integration.md](desktop-integration.md) §9).

### 9.7 Storage

Disk use of images, the Android instance, packages, and caches. **Apps with kept data** with **Reinstall…** and **Delete Data** ([package-store.md](package-store.md) §8). **Android system**: the current version with its size, the previous version, an update that is ready, and the recovery point with its date and **Delete…**. **Go Back to Android ‹A›…** while a rollback is possible, with the confirmation of [runtime-maintenance.md](runtime-maintenance.md) §4.8. **Install from File…** for a signed image archive ([runtime-maintenance.md](runtime-maintenance.md) §4.5, §7.2). A hint to delete the recovery point appears when free space is below 10 GiB ([android-image.md](android-image.md) §12.2).

### 9.8 Troubleshooting (#059, #060)

- The health report from `apkrun doctor` as a list, grouped as in [diagnostics.md](diagnostics.md) §7.4: each check with its state (✓ / ℹ / ⚠ / ✕ / – not checked), message, and remediation. Groups where every check passes collapse to one line. **Run Again** (the whole report, or one row), **Deep Check** (the `--deep` checks), and **Fix** on rows with a safe fix ([diagnostics.md](diagnostics.md) §7.5). Opening this pane does not start Android: checks that need it show "–" with the last known result.
- **Create Diagnostics Report…**: opens the report sheet of [diagnostics.md](diagnostics.md) §8.5: what is included and what is never collected (§6 there), **Include Android app logs**, the focus app, then a Save panel, progress with **Cancel**, **Show in Finder**, and **Copy Summary**. Nothing is uploaded.
- **Restart Android**, **Start in Graphics Safe Mode** (`graphics.safeMode`, [graphics.md](graphics.md) §9; while safe mode is on the button is **Turn Off Graphics Safe Mode**, which resets the key and restarts Android), **Reset Android…** (type "Reset" to confirm, [runtime-daemon.md](runtime-daemon.md) §9.5).

### 9.9 Advanced

- **Developer mode** (ADB on host loopback, frame statistics, [android-image.md](android-image.md) §11.3). Turning it on explains the risk (any local process can then reach Android over ADB at `127.0.0.1:6520`) and asks for confirmation. It applies at the next Android start ([android-image.md](android-image.md) §11.3). While it is on, the main window header and the menu bar show "Developer mode" ([../01-architecture/security-model.md](../01-architecture/security-model.md)).
- **Install Command-Line Tool…** ([cli.md](cli.md)).
- **Reveal Logs in Finder**.

---

## 10. Prompts started by other processes

### 10.1 Wrapper approval (#047, #089)

apkrund's `WrapperApprovalService` asks through `ApprovalCenter` ([wrapper.md](wrapper.md) §7.3). If APKRun.app is not running, apkrund opens it with `--approve` and `activates = true`.

```text
┌──────────────────────────────────────────────────┐
│ [wrapper icon]                                   │
│ Allow “Discord” to open com.discord in APKRun?   │
│ ──────────────────────────────────────────────   │
│ Location ~/Downloads/Discord.app                 │
│ Signed by Developer ID: Example Inc. ✓           │
│ (or: “Not signed by a developer”)                │
│ Android app installed, version 245.0             │
│ (or: “not installed. This Mac app                │
│ contains version 245.0.”                         │
│ ──────────────────────────────────────────────   │
│ Only allow Mac apps you trust.                   │
│ [Don't Allow] [Allow]                            │
└──────────────────────────────────────────────────┘
```

- **Allow** is not the default button (Return does not press it), because the prompt comes from a file the user may not have chosen.
- Requests queue in arrival order. Only one prompt is shown at a time.
- A request that times out (10 minutes) closes its prompt.

### 10.2 Prompts shown by wrappers

These are drawn by the wrapper, not by APKRun.app, but they follow the same text and button rules: the link prompt ([desktop-integration.md](desktop-integration.md) §7.2), the Save panel for "Save to Mac" ([desktop-integration.md](desktop-integration.md) §6.3), and the launcher screens ([wrapper.md](wrapper.md) §5.4).

---

## 11. Notifications from APKRun

APKRun.app posts, through `HostNotificationClient`:

| Notification | Actions | Target URL |
|---|---|---|
| the update notifications of [update-system.md](update-system.md) §9 | **Update Now** (for available updates), **Open** | `apkrun://package/<id>/updates` |
| notifications of Android apps without a usable Mac app ([desktop-integration.md](desktop-integration.md) §5.3), with the app name as subtitle | the Android actions | opens the app with the generic launcher |
| "Android stopped unexpectedly" while no window is open | **Restart** | `apkrun://settings/troubleshooting` |
| "APKRun needs your attention" for an approval while the approval window cannot be shown | — | brings the approval window forward |
| "APKRun ‹version› is available" (from apkrund's probe while APKRun.app isn't running; once per version) | **Update…** (opens General and starts a Sparkle check) | `apkrun://settings/general` |
| "Android system update ready" (ask mode, or after 7 days of waiting) | **Update Now**, **Later** | `apkrun://settings/general` |
| "Android was updated to ‹B›" (only with `maintenance.notifyImageInstalled`) | — | `apkrun://settings/general` |
| "Android couldn't be updated to ‹B›. Your apps and data are unchanged." | **Report a Problem…** | `apkrun://report` |
| "Android needs an update to work with this version of APKRun" while no window is open | **Open APKRun** | `apkrun://settings/general` |

The rules for the last five rows (the APKRun and Android system update notifications) are in [runtime-maintenance.md](runtime-maintenance.md) §7.4. **Update Now** and **Update…** are notification actions handled inside APKRun.app, not URLs, so they may act.

`HostNotificationClient` opens the `hostNotifications` stream and sends each action back with `hostNotificationResponse` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §11.3). #037 builds both, with the update notifications. The other rows come with the tasks of their features.

Notification permission is requested for APKRun.app at the end of onboarding, not at first launch.

---

## 12. Menu bar (#086, FR-UI-05)

```text
┌──────────────────────────────────┐
│ Android ● Ready                  │
│ (Developer mode on)              │
│ ──────────────────────────────   │
│ Apps: 2 running                  │
│ [icon] Discord                   │
│ [icon] Spotify 🎙                 │
│ ──────────────────────────────   │
│ Updates: 2 available             │
│ Spotify 8.10.3 Update            │
│ F-Droid 1.22 Update              │
│ Update All                       │
│ ──────────────────────────────   │
│ APKRun 1.3.0 is available        │
│ Update…                          │
│ Android system update ready      │
│ Update Now                       │
│ ──────────────────────────────   │
│ Open APKRun…                     │
│ Stop Android                     │
│ ──────────────────────────────   │
│ Quit Menu Bar Item               │
└──────────────────────────────────┘
```

- The status item is a template image. It is filled while Android runs, outlined while it is stopped or asleep, and has a dot when updates are available, the runtime failed, or a live health check needs attention ([diagnostics.md](diagnostics.md) §7.1). In the last case the menu shows "⚠ Needs attention" under the runtime line, which opens Troubleshooting.
- **Apps** lists running sessions. Clicking one brings its window to the front (`launch(packageID)`, which activates the running wrapper). A microphone symbol marks apps that are recording ([desktop-integration.md](desktop-integration.md) §8.2).
- **Updates** lists available updates with **Update** (manual update, gentle rules apply).
- The maintenance rows appear only when they apply ([runtime-maintenance.md](runtime-maintenance.md) §7.3): "APKRun ‹version› is available" with **Update…** (opens Settings → General and starts the Sparkle check), "Android system update ready" with **Update Now**, "Finish updating APKRun…" in `restartPending`, and "◐ Updating Android…" in the runtime line during a migration. APKRunMenuBar relaunches itself when apkrund reports a newer build ([runtime-maintenance.md](runtime-maintenance.md) §3.7).
- **Stop Android** asks for confirmation when apps are open. When Android is stopped, the item is **Start Android**.
- **Quit Menu Bar Item** quits APKRunMenuBar only. It stays off until the next login or until the user opens APKRun.app with the setting still on.
- "Developer mode on" appears under the runtime line while developer mode is enabled (security-model.md).
- APKRunMenuBar observes only. It never keeps Android running ([runtime-daemon.md](runtime-daemon.md) §5.1).
- The CLI shows the same information with `apkrun status` ([cli.md](cli.md)).

---

## 13. Localization and accessibility (#092, NFR-L10N-01, NFR-L10N-02)

- **Languages:** English (development language) and Japanese. All user-facing strings of APKRun.app and APKRunMenuBar are in String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`).
- **Executables without resources.** The launcher and the CLI have no resource bundle, so they compile their strings into the executable. A generator reads `Apps/APKRunLauncher/Localizable.xcstrings` and `CLI/apkrun/Localizable.xcstrings` and writes `LauncherStrings.generated.swift` and `CLIStrings.generated.swift` with every language as literals ([wrapper.md](wrapper.md) §5.9, [cli.md](cli.md) §6.1). The same approach serves the error catalog (`ErrorCatalog.generated.swift`, [../03-reference/error-catalog.md](../03-reference/error-catalog.md)). The CLI picks the language from the user's preferred languages. `--json` output is never localized.
- **apkrund** has no UI of its own. Every text it produces for users is an error catalog code or a health check result, which the client localizes. Its embedded Info.plist (`NSMicrophoneUsageDescription`, [vm.md](vm.md) §3) has no localizations. #084 records which text macOS shows in the microphone prompt.
- Error messages and remediations come from the error catalog keys, so the GUI, the menu bar, and the CLI say the same thing.
- Plurals use the catalog's plural variants ("1 app running" / "2 apps running"). Sizes use `ByteCountFormatter`, dates `Date.FormatStyle`.
- CI fails when a catalog has untranslated or stale entries in a release build (#092). A pseudo-language run (`-AppleLanguages "(en-XA)"`, double-length strings) is part of the UI test suite to catch truncation.
- **Accessibility:** every control has an accessibility label. Icon-only buttons have text labels. Status is never shown by color alone (each colored dot has text). The main window, sheets, and Settings are fully keyboard operable. Each release runs XCUITest's `performAccessibilityAudit` over the main screens. Android apps' own accessibility is out of scope ([display-and-windowing.md](display-and-windowing.md) §7.7).

### 13.1 Terms

| Use | Do not use |
|---|---|
| Mac app (for a wrapper) | wrapper, bundle |
| Android (for the runtime), "Start Android", "Stop Android" | VM, guest, runtime (except in Troubleshooting and the CLI) |
| app (for an Android package) | package, APK (except where the file is meant) |
| update source | provider, authority |

The glossary is [../00-product/glossary.md](../00-product/glossary.md).

---

## 14. Implementation steps

### #066 Onboarding (M4)

1. `APKRunApp` skeleton with the main window, `RuntimeStatusModel`, and the apkrund registration (SMAppService) with the approval polling.
2. The onboarding sheet (§4) over the `setup` long operation, with resume and failure handling.
3. Acceptance: [runtime-daemon.md](runtime-daemon.md) §9.4.

### #077 Home and store UI (M7)

1. Models of §2.2 with event subscriptions and reconnection. `OperationCenter`.
2. The main window (§5): sidebar, runtime header, app rows with the status priority table, Other Android Apps, empty state, search and sort.
3. `apkrun://` routing (§3.1).
4. Acceptance: with HelloText, HelloGL, and an unmanaged package (HelloCompose installed with `adb install`) installed, the rows show the right versions and states. A staged update of HelloUpdate shows "Update available" and **Update Now** installs it (FR-UI-04). Moving a wrapper to the Trash changes its row to "Mac app not found" within 60 s. The window works with Android stopped.

### #078 Add flow (M7)

1. Document types (§3.2), drops, and **Add App…**. The add sheet (§6) for every `ImportRelation`.
2. Provider picker and suggestion ([update-system.md](update-system.md) §4.7), the Create Mac App options ([wrapper.md](wrapper.md) §6.6).
3. Acceptance: dragging `HelloText.apk` onto APKRun shows its name, package, icon, and update options, and **Install** with "Create Mac app" produces `~/Applications/HelloText.app`, which opens the app. Double-clicking an `.apk` in Finder opens the same sheet (FR-UI-06). An `.xapk` and an `.apks` fixture install as split sets. HelloUpdate V1 dropped while V2 is installed shows the `downgrade(from:)` refusal, and HelloUpdate V2-other-signer dropped while V1 is installed shows the `otherSigner` refusal. The OddName fixture (a label with `/`, `:`, and an emoji ZWJ sequence) gets a sanitized Mac app name ([wrapper.md](wrapper.md) §4.3). The fixtures are listed in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4.

### #079 Per-app settings (M7)

1. The app page (§7) with all sections and immediate writes, including **Updated by** (§7.5).
2. The `window.alwaysOnTop` setting in the launcher (WindowingCore).
3. The panes of the `Settings` scene (§2.1), which #047 created, and their tab order (§9): the General pane's **Default location for new Mac apps** (§9.1; the add flow of #078 reads the key), the Updates pane (§9.3), the Runtime pane (§9.2), the global switches and defaults of the Privacy pane (§9.4), the disk-use summary of the Storage pane (§9.7), and the Advanced pane (§9.9). The other panes and rows come with the tasks of §9 and the table below; a pane with no content yet is not shown.
4. Acceptance: each setting of §7.2–§7.4 changes `settings.json` and takes effect where stated (a T2 test per section with HelloText). The Updates section shows history and rolls back HelloUpdate. **Updated by** → **Another app store in Android** makes HelloUpdate `external`, and **APKRun** makes it `apkrun` again with its kept provider. Each control of the Updates pane writes its key, and the default location decides where the next Mac app is created.

### #086 Menu bar (M9)

1. `APKRunMenuBar` target, login item registration from Settings → General, the menu of §12.
2. Acceptance (FR-UI-05): with 2 apps running and 2 updates available, the menu shows both counts. **Stop Android** stops the runtime after confirmation. Quitting APKRun.app leaves the menu bar item and the apps running.

### #092 Localization (M12)

1. Japanese translations for all catalogs, the launcher's compiled strings, and the CLI.
2. The catalog CI check and the pseudo-language UI run.
3. Acceptance: with the Mac set to Japanese, every screen of §4–§12 and every CLI message of the #075 and #059 tests is Japanese, with no truncation in the pseudo-language run. The accessibility audit passes.

### UI parts of other tasks

| Task | UI |
|---|---|
| #057 | Settings → General updates section for APKRun (§9.1), the install dialog, the `restartPending` banner (§5.2), the "Update Mac apps" prompt after an update, the APKRun maintenance rows in the menu bar (§12) ([runtime-maintenance.md](runtime-maintenance.md) §3.5, §3.7, §7) |
| #058 | Storage → Android system rows, **Go Back…**, **Install from File…** (§9.7), "Updating Android…" (§5.2), the failure notification (§11) |
| #087 | Android system update status lines and settings (§9.1), notifications (§11), menu bar row (§12), onboarding download (§4) |
| #059 | Troubleshooting health list (§9.8) |
| #060 | Create Diagnostics Report (§9.8) |
| #076 | Uninstall dialog (§8), the full wrapper states in rows (#077 ships a quick version first), the `MacAppSection` view that #079 places, **Refresh Dock Icons** in Troubleshooting (§9.8) |
| #082 | Settings → Files (§9.5), shared-folder row on the app page |
| #047, #089 | approval window (§10.1), and **Mac apps you didn't allow** in Settings → Privacy (§9.4). #047 is the first task with a settings pane, so it creates the `Settings` scene; #079 adds the app-wide panes |
| #083 | **Sound output** with **Restart Android Now** in Settings → Runtime (§9.2) |
| #084 | the microphone permission row with **Open System Settings** in Settings → Privacy (§9.4) |
| #085 | Settings → Language & Region (§9.6) |
| #037 | `HostNotificationClient` and the `--notify` background start (§3.3) for the update notifications of [update-system.md](update-system.md) §9 (§11). `HostNotifier` in RuntimeHost comes with it |

---

## 15. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | Model tests with a fake `RuntimeService`: status priority table (§5.3), relation handling (§6.1), reconnection reload, URL routing and package-ID validation | #077, #078 |
| T0 | Settings patches: each control writes the documented key and value | #079 |
| T1 | XCUITest with the embedded runtime fake: onboarding resume, add flow for each relation, uninstall choices, approval prompt (Return does not allow) | #066, #078, #076, #047 |
| T2 | Real runtime: §14 acceptance checks | each task |
| T2 | Accessibility audit and pseudo-language run | #092 |

---

## 16. Open items

- Whether APKRun.app should offer an Android app catalog (browse F-Droid repositories) in v1. Not planned: the add flow and update sources cover v1 ([../04-plan/open-questions.md](../04-plan/open-questions.md)).
- Whether **Always on top** should also apply in full screen. v1: no effect in full screen.
- Menu bar: whether to list apps that are kept running without a window (`keepRunning`) under Apps. v1 lists sessions only.

---

## 17. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| Which text does macOS show in the microphone prompt for apkrund, whose embedded Info.plist has no localizations? | #084, #092 | pending (§13) |
