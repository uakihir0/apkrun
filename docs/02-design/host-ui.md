# Host UI (APKRun.app and APKRunMenuBar)

APKRun.app is where users add Android apps, manage them, and fix problems. Android apps run in their own Mac apps ([wrapper.md](wrapper.md)), never inside APKRun.app. APKRunMenuBar is a status item for the runtime, running apps, and updates. This document specifies their screens, states, and texts.

---

## 1. Principles

1. **A client, not an owner.** APKRun.app and APKRunMenuBar own no runtime state. They use `RuntimeClient` only ([modules.md](../01-architecture/modules.md) §2). Quitting them never stops Android or an app.
2. **Opening APKRun.app does not start Android.** Only Open, Install, Update Now, and Start Android start it ([runtime-daemon.md](runtime-daemon.md) §5.1).
3. **Works while Android is stopped.** Lists, settings, update checks, and wrapper actions use the last known state. An action that needs Android says so.
4. **Never shows Android UI.** Android app pixels appear only in wrapper windows.
5. **Every error has a next step.** Messages and remediations come from [error-catalog.md](../03-reference/error-catalog.md). Each error view has **Copy Details** (the code and the operation ID, no personal data) and, where it helps, **Troubleshooting…**.
6. **One source of text.** All strings are in String Catalogs (§13).

---

## 2. Structure

### 2.1 Targets, scenes, and commands

| Target | Bundle ID | Role |
|---|---|---|
| `Apps/APKRun` (SwiftUI app) | `io.apkrun.APKRun` | main window, Settings, onboarding, approvals, APKRun's own notifications |
| `Apps/APKRunMenuBar` (`MenuBarExtra`, `LSUIElement = true`) | `io.apkrun.APKRunMenuBar` | status item. Login item (`SMAppService.loginItem(identifier:)`) from `Contents/Library/LoginItems/` ([filesystem-layout.md](../01-architecture/filesystem-layout.md) §4) |

| Scene | Content |
|---|---|
| `Window("APKRun", id: "main")` | sidebar and detail (§5). Closing it quits the app unless an operation runs (`applicationShouldTerminateAfterLastWindowClosed`) |
| `Settings` | app-wide settings (§9) |
| sheets on the main window | onboarding (§4), add flow (§6), uninstall (§8), confirmations |
| `Window(id: "approval")` | wrapper approvals (§10.1). A small separate window |

| Menu | Item | Action |
|---|---|---|
| APKRun | **Check for Updates…** | the same as **Check Now** in Settings → General → Updates (§9.1) |
| File | **Add App…** (⌘O) | opens the add flow's file picker (§6) |
| Help | **Third-Party Notices** | opens `Contents/Resources/ThirdPartyNotices.html` with `NSWorkspace` in the default browser ([legal-and-licensing.md](../05-development/legal-and-licensing.md) §6.4) |

### 2.2 Models

`@Observable` models on the main actor, fed by `RuntimeClient` requests and event subscriptions ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.4). Views never call XPC directly.

| Model | Source | Used by |
|---|---|---|
| `RuntimeStatusModel` | `runtimeStatus`, topic `runtime` | home header, menu bar, onboarding |
| `PackageListModel` | `listPackages(.all)`, topic `packages` | home, sidebar badges |
| `PackageDetailModel` | `packageInfo`, `integrationStatus`, `listWrappers` (filtered); topics `packages`, `integrations`, `wrappers` | app page |
| `UpdatesModel` | UpdateCore operations, topic `updates` ([update-system.md](update-system.md) §11) | home rows, Updates list, menu bar |
| `SessionsModel` | topic `sessions` | "running" indicators, menu bar |
| `OperationCenter` | long-running operations ([runtime-daemon.md](runtime-daemon.md) §8.3) | toolbar indicator and popover, progress in sheets |
| `ApprovalCenter` | broker approval requests | §10.1 |
| `HostNotificationClient` | `HostNotifier` requests ([update-system.md](update-system.md) §9) | §11 |
| `SettingsModel` | configuration operations ([configuration.md](../03-reference/configuration.md) §1.4) | Settings |
| `MaintenanceModel` | `selfUpdateStatus`, `imageUpdateStatus`, topic `maintenance`, and Sparkle results from `SelfUpdateController` ([runtime-maintenance.md](runtime-maintenance.md) §8) | Settings → General and Storage, banners, menu bar |

On a reconnect, every model reloads. While apkrund is unreachable, the main window shows the banner "APKRun's background service isn't running" with **Restart Service** (re-registers the agent, [runtime-daemon.md](runtime-daemon.md) §2.1) and **Troubleshooting…**.

### 2.3 Source layout

```text
Apps/APKRun/
├── APKRunApp.swift            scenes, URL and document handling (§3)
├── Models/                    §2.2
├── Features/
│   ├── Onboarding/            §4
│   ├── Home/                  §5
│   ├── AddFlow/               §6
│   ├── AppPage/               §7 (one file per settings section)
│   ├── Uninstall/             §8
│   ├── Settings/              §9 (one file per pane)
│   ├── Approvals/             §10
│   └── Troubleshooting/       §9.8
├── Components/                shared views only (not a utilities folder)
└── Resources/                 Localizable.xcstrings, Assets.xcassets, InfoPlist.xcstrings
Apps/APKRunMenuBar/            §12
```

---

## 3. Entry points, URLs, and documents

### 3.1 `apkrun://` routes

APKRun.app declares the URL scheme `apkrun` (`CFBundleURLTypes`). URLs **only navigate**. They never perform an action, because any process can open a URL.

| URL | Opens |
|---|---|
| `apkrun://home` | the main window, Apps |
| `apkrun://package/<packageId>` | the app page |
| `apkrun://package/<packageId>/<section>` | the app page at a section: `general`, `window`, `input`, `integrations`, `updates`, `mac-app`, `storage` |
| `apkrun://updates` | the Updates list |
| `apkrun://settings/<pane>` | Settings at a pane: `general`, `runtime`, `updates`, `privacy`, `files`, `language`, `storage`, `troubleshooting`, `advanced` |
| `apkrun://setup` | onboarding if setup is not complete, otherwise home |
| `apkrun://report[?package=<packageId>]` | the diagnostics report sheet, package preselected ([diagnostics.md](diagnostics.md) §8.5). The report is created only after **Create Report…** |

`<packageId>` must match the Android package-name grammar. An unknown package shows the home screen with "‹id› isn't installed in APKRun." An unknown route opens the home screen.

### 3.2 Documents

| Type | UTI | Declaration | Role, rank |
|---|---|---|---|
| `.apk` | `com.android.package-archive` (conforms to `public.zip-archive`, `public.data`) | imported (`UTImportedTypeDeclarations`) | Viewer, `Default` |
| `.apks` | `io.apkrun.apks` | exported | Viewer, `Owner` |
| `.xapk` | `io.apkrun.xapk` | exported | Viewer, `Owner` |
| `.apkm` | `io.apkrun.apkm` | exported | Viewer, `Owner` |

Opening a file (double-click, **Open With**, a drop on the Dock icon, or `open -a APKRun file.apk`) starts the add flow (§6). Files that form one split set are one import. Other files each start their own add flow, in order ([package-store.md](package-store.md) §4.1).

### 3.3 Launch arguments

| Argument | Meaning |
|---|---|
| (none) | normal start. If setup is not complete, the onboarding sheet opens (§4) |
| `--notify` | started by apkrund to post notifications ([update-system.md](update-system.md) §9). No window, no Dock activation. Quits 30 s after the last notification is handled |
| `--approve` | started by apkrund for a wrapper approval (§10.1). Only the approval window is shown |
| `--register-runtime` | registers the apkrund LaunchAgent with `SMAppService`, then quits ([runtime-daemon.md](runtime-daemon.md) §2.6, [cli.md](cli.md) §4.1) |

---

## 4. Onboarding

A sheet on the first launch, and whenever setup is not `complete`. It drives the provisioning steps of [runtime-daemon.md](runtime-daemon.md) §9.2 and shows `ProvisioningState`.

```text
┌───────────────────────────────────────────────┐
│               Welcome to APKRun               │
│  Run Android apps as Mac apps.                │
│                                               │
│  ✓ Background service allowed                 │
│  ✓ This Mac can run APKRun                    │
│  ◐ Installing Android…            ▓▓▓▓▓░░ 62% │
│  ○ Starting Android for the first time        │
│  ○ Checking that everything works             │
│                                               │
│  This takes a few minutes. You can close this │
│  window. Setup continues when you come back.  │
│                                  [ Cancel ]   │
└───────────────────────────────────────────────┘
```

| Step | UI |
|---|---|
| 1. Background service | registers apkrund. `.requiresApproval`: "Allow APKRun in System Settings → General → Login Items & Extensions." with **Open System Settings**. Polls the status every 2 s |
| 2. Host check | each failed `HostRequirementsCheck` item with its remediation ([runtime-daemon.md](runtime-daemon.md) §9.1). A blocking failure ends onboarding with **Quit**. The memory warning allows **Continue** |
| 3. Android image | release builds: "Download Android (‹size›)" with a progress bar. Development builds: **Choose Image…** (an open panel for a bundle directory or `.aar`, [runtime-daemon.md](runtime-daemon.md) §9.3) |
| 4. First boot | the boot phase as text ("Starting Android… system services") and the estimated fraction |
| 5. Verify | "Checking that everything works" |
| Done | "You're ready." with "Drag an APK here to add your first app" and **Add App…** |

- A failed step turns red with the catalog message, **Try Again**, and **Report…** (§9.8). After 2 failed first boots, **Start Over** appears ([runtime-daemon.md](runtime-daemon.md) §9.2).
- **Cancel** stops the current step. Completed steps stay completed. The next launch continues at the first incomplete step.
- The CLI equivalent is `apkrun setup` ([cli.md](cli.md)).

---

## 5. Main window

### 5.1 Layout

```text
┌──────────────┬──────────────────────────────────────────────────────────┐
│ APKRun       │  Android  ● Ready        2 apps running     [Stop Android] │
│              ├──────────────────────────────────────────────────────────┤
│ ▸ Apps     4 │ ┌──────────────────────────────────────────────────────┐ │
│ ▸ Updates  1 │ │        Drag APK, APKS, or XAPK files here to add      │ │
│ ▸ Other      │ └──────────────────────────────────────────────────────┘ │
│   Android    │  [icon] Discord            ● running                     │
│   Apps       │         Android version 245.0 · Updates: Automatic       │
│              │         Up to date                    [Open] [Settings]  │
│              │  [icon] Spotify                                          │
│              │         Android version 8.10.2 · Updates: Automatic      │
│              │         Update available 8.10.3   [Update Now] [Open]    │
│              │  [icon] F-Droid Client                                   │
│              │         Android version 1.21 · Updates: Notify only      │
│              │         ⚠ Mac app not found     [Create Mac App] [Open]  │
└──────────────┴──────────────────────────────────────────────────────────┘
```

- `NavigationSplitView`. Sidebar sections: **Apps** (packages managed by APKRun), **Updates** (available, waiting, or failed; badge = count), and **Other Android Apps** (§5.4).
- Toolbar: **Add App…** (⌘O), a search field (name or package ID), a sort menu (Name, Recently Used, Recently Updated), and the `OperationCenter` indicator.

### 5.2 Runtime header

| `RuntimeState` ([state-machines.md](../01-architecture/state-machines.md) §2) | Shown | Button |
|---|---|---|
| `stopped` | ○ Stopped | **Start Android** |
| `booting(phase)` | ◐ Starting… (phase text) | — |
| `ready` | ● Ready | **Stop Android** (asks when sessions run: "Stop Android and close 2 apps?") |
| `suspended` | ● Sleeping (resumes when you open an app) | **Stop Android** |
| `stopping` | ◐ Stopping… | — |
| `failed(f)` | ⚠ Android stopped unexpectedly | **Restart**, **Troubleshooting…** |
| boot-loop guard active | ⚠ Android failed to start several times | **Restart**, **Start in Graphics Safe Mode**, **Reset Android…** ([runtime-daemon.md](runtime-daemon.md) §3.6) |
| not provisioned | Setup isn't finished | **Continue Setup** |
| `booting(phase)`, `bootPurpose = .imageUpdate(A, B)` | ◐ Updating Android… (phase text) | — ([runtime-maintenance.md](runtime-maintenance.md) §4.7) |
| host state `restartPending` | banner: "APKRun was updated. Restart Android to finish. ‹N› apps will close." | **Restart Now** ([runtime-maintenance.md](runtime-maintenance.md) §3.6, §7.3) |
| image too old (`incompatibleProtocol / hostNewer`) | banner: "Android needs an update to work with this version of APKRun." with download and progress | — ([runtime-maintenance.md](runtime-maintenance.md) §4.10) |
| image needs a newer APKRun (`incompatibleProtocol / guestNewer`, `incompatibleRuntime`) | banner with the entry's own text | **Check for Updates** (`updateAPKRun`, [runtime-maintenance.md](runtime-maintenance.md) §4.10) |

- The running count comes from `SessionsModel` (sessions in `running` or `backgrounded`).
- While a live health check is in `warning` or `failure` ([diagnostics.md](diagnostics.md) §7.1), the header adds "⚠ Needs attention" with **Troubleshooting…**.

### 5.3 App rows

Each row shows the icon (`packageIcon` at 64 px, or the host preview), the display name, "Android version ‹versionName›" (FR-UI-04), the update mode, a status line, and up to two buttons. The status line is the first matching row:

| Priority | Condition | Status line | Buttons |
|---|---|---|---|
| 1 | package `broken(reason)` | "Needs attention: ‹reason›" | **Repair…** |
| 2 | `installing`, `updating(phase)`, `uninstalling`, `needsReinstall` | "Installing…", "Updating…", "Removing…", "Reinstalling after Android reset…" with progress | — |
| 3 | update failed or rolled back ([update-system.md](update-system.md) §8.3) | "Update failed" / "Rolled back to ‹version›" | **Details** |
| 4 | update waiting ([update-system.md](update-system.md) §7.4) | "Will update when ‹App› quits" | **Update Now** |
| 5 | update available (notify-only or manual check) | "Update available ‹version›" | **Update Now** |
| 6 | wrapper state not `valid` ([wrapper.md](wrapper.md) §9.1) | "Mac app not found" / "APKRun can't check this location" / "This Mac app was modified" | the state's action ([wrapper.md](wrapper.md) §9.1) |
| 7 | wrapper refresh reasons | "Mac app can be updated" | **Update Mac App** |
| 8 | otherwise | "Up to date", or "Updates: Manual" | **Open**, **Settings** |

A running app has a green dot and the text "running". The context menu has **Open**, **Show Mac App in Finder**, **Check for Updates**, **Settings…**, and **Uninstall…**. **Open** calls `launch(packageID)` ([runtime-daemon.md](runtime-daemon.md) §7.2): the registered, valid wrapper if there is one, else the generic launcher.

### 5.4 Other Android Apps

Packages that Android has but APKRun does not manage (preinstalled apps, apps installed with `adb`). Each row has **Open** and **Manage with APKRun** (`adoptPackage`, [package-store.md](package-store.md) §9.3). System packages without a launcher activity are not listed.

### 5.5 Empty state and drops

- No apps: a large drop zone with "Add your first Android app", **Add App…**, and "Where do I get APK files?" linking to the user guide.
- A drop on the drop zone, the list, or the Dock icon starts the add flow. Unsupported files are refused with "APKRun can add .apk, .apks, .xapk, and .apkm files."

---

## 6. Add flow

A sheet with four stages. The GUI passes open file handles, never paths ([package-store.md](package-store.md) §4.1).

```text
 1 Reading            2 Review                               3 Installing          4 Done
 ─────────            ──────────────────────────────         ────────────          ──────────────
 Copying… ▓▓▓░        [icon]  Discord                         Starting Android…     ✓ Discord is ready
 Checking… ▓▓▓▓       com.discord · version 245.0 (245000)    Installing… ▓▓▓░      [Open Discord]
                      Signed by: ‹developer digest›  ⓘ        Creating Mac app…     [Show in Finder]
 [Cancel]             Size 142 MB · Needs Android 8.0+                              [Done]
                      ────────────────────────────
                      Updates   ○ Automatic  ○ Notify only  ● Manual
                                Update source: none  [Choose…]
                      ☑ Create Mac app  "Discord"
                         Location: Applications (for me) ▾
                      ▸ Details (files, splits, permissions)
                                     [Cancel] [Install]
```

### 6.1 Review stage

Content comes from `ImportPreview` ([package-store.md](package-store.md) §4.7).

| Element | Rule |
|---|---|
| Name, icon | the host label and icon preview. The Mac app name field starts with the same name |
| Package and version | package ID, `versionName (versionCode)` |
| Signer | short certificate digest with an ⓘ popover: full SHA-256 digests, scheme, lineage length, verification level |
| Compatibility | the entry of the compatibility database, if any ([diagnostics.md](diagnostics.md) §10): **Works**, **Works with limitations**, or **Unsupported** with known issues. `unsupported` changes the button to **Install Anyway**. `warnings` show as yellow rows ([package-store.md](package-store.md) §4.6). A blocking problem replaces the Install button with the reason |
| Updates | **Automatic**, **Notify only**, or **Manual**. Without an update source only **Manual** is enabled, with "Choose an update source to turn on automatic updates" and **Choose…** ([update-system.md](update-system.md) §4). A detected provider is offered as a suggestion that is off until turned on ([update-system.md](update-system.md) §4.7) |
| Create Mac app | toggle (default on), name field, location: **Applications (for me)** (`~/Applications`), **Applications (all users)** (admin users only), **Other…** ([wrapper.md](wrapper.md) §6.3) |
| Details | file list with sizes, excluded splits, requested permissions. Permissions are informational: Android asks for runtime permissions in the app's window |

| `ImportRelation` | Sheet |
|---|---|
| `newPackage` | as above, button **Install** |
| `sameAsInstalled` | "‹App› ‹version› is already installed." **Open**, **Done** |
| `reinstallSameVersion` | "Reinstall ‹App› ‹version›?" button **Reinstall** |
| `update(from:)` | "Update ‹App› from ‹old› to ‹new›?" button **Update**. When the app is open: "‹App› will update when you quit it" with **Quit and Update** ([update-system.md](update-system.md) §7.3) |
| `downgrade(from:)` | refused with the message of [package-store.md](package-store.md) §4.7. Only **Done** |
| `otherSigner` | refused with the message of [package-store.md](package-store.md) §4.7. Only **Done** |
| `uninstalledWithData(version)` | "Reinstall ‹App› and restore its data?" button **Reinstall** |

### 6.2 Installing and done

- **Install** calls `installImported(ticket, options)` and shows its progress: "Starting Android…" (when the runtime was stopped), "Installing in Android…", "Creating Mac app…".
- An install failure shows the catalog message, and the package is not added. **Try Again** keeps the ticket.
- A wrapper failure after a successful install shows "Discord was installed, but the Mac app couldn't be created: ‹reason›" with **Try Again**. The package stays ([wrapper.md](wrapper.md) §6.6). `destinationNotAccessible` offers **Choose Another Location…**, then `placeStagedWrapper`.
- **Done** closes the sheet. **Open ‹App›** launches it. The sheet can be closed during Installing. The work continues in `OperationCenter`.

---

## 7. App page and per-app settings

The app page is the detail view of a package. Its header shows the icon, name, version, running state, **Open**, **Update Now** (when available), and a **…** menu (Show Mac App in Finder, Check for Updates, Repair…, Uninstall…).

Every setting is written at once with `updatePackageSettings(id, patch)`. There is no Save button. A setting that applies at the next app start says "Applies the next time ‹App› opens."

A value from the compatibility database shows "Recommended for this app" ([diagnostics.md](diagnostics.md) §10.3). **Reset** removes the stored value and returns to the recommendation, or to the built-in default ([configuration.md](../03-reference/configuration.md) §3.2). `integrations.defaults.*` apply only when a package is first recorded, so Reset never returns to them.

### 7.1 General

| Item | Setting or source |
|---|---|
| Name | the Mac app name ([wrapper.md](wrapper.md) §6.1). A change offers **Update Mac App** |
| Icon | **Android Icon** or **Choose…** (an image file). A change offers **Update Mac App** |
| Package, version, installed from, installed on, last updated | the package record |
| Signer | digest with the ⓘ popover of §6.1 |
| Compatibility | label and known issues for the installed version ([diagnostics.md](diagnostics.md) §10). Nothing for apps without an entry |
| Size | artifacts on the Mac and app data in Android (from `packageInfo`) |

### 7.2 Window

| Control | Key | Values |
|---|---|---|
| Default size | `window.defaultWidth`, `window.defaultHeight` | points. **Use Current Size** takes the size of the open window |
| Resizable | `window.resizable` | on / off |
| Always on top | `window.alwaysOnTop` | off (default) / on: `NSWindow.level = .floating` ([display-and-windowing.md](display-and-windowing.md) §7.7). No effect in full screen (OQ-09) |
| Zoom | `window.zoom` | 75 %–200 % ([display-and-windowing.md](display-and-windowing.md) §6.1) |
| When I close the window | `window.closeBehavior` | **Quit the app** (`stop`) / **Keep it running in the background** (`keepRunning`) ([desktop-integration.md](desktop-integration.md) §5.3) |
| Window mode | `window.mode` | **Standard** (`secondaryDisplay`) / **Compatibility** (`primaryDisplayCompatibility`) ([display-and-windowing.md](display-and-windowing.md) §8) |

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

Keys and defaults: [desktop-integration.md](desktop-integration.md) §2.1. Each row also shows what `integrationStatus` reports: "Not available with this Android image", "Turned off for all apps in Settings → Privacy", or the macOS permission state.

| Control | Key | Values and extra UI |
|---|---|---|
| Clipboard | `integrations.clipboard` | on / off. Footnote: "Android shares one clipboard among its apps." |
| Notifications | `integrations.notifications` | on / off. macOS permission for the Mac app (**Open Notification Settings** when denied). With `window.closeBehavior = stop`: "‹App› can only notify you while it is running." |
| Links | `integrations.links` | **Ask** / **Open in Mac browser** / **Open in Android** |
| Files | `integrations.files` | on / off: "Drag files into ‹App›, and save files from ‹App› to your Mac." |
| Shared folders | `integrations.sharedFolders` | **Off** / **Read only** / **Read and write**, with the folder list from Settings → Files and **Edit Folders…** |
| Microphone | `integrations.microphone` | on / off. The first microphone app shows "Android needs to restart to use the microphone."; the last one shows "Android needs to restart to turn off the microphone." Each has **Restart Android Now** / **Later** ([vm.md](vm.md) §11). Shows the macOS permission state for APKRun |
| Camera | — | "Not supported yet" (FR-INT-10) |

### 7.5 Updates

The content is listed in [update-system.md](update-system.md) §9: mode (with the authority rules of [update-system.md](update-system.md) §2.3), update source and its configuration, **Check Now**, last check time and result, history, **Roll Back to ‹version›…**, "Undo updates that fail to start" (`update.autoRollback`), and "Open the app briefly after updating to check it" (`update.healthCheckLaunch`).

**Updated by** sets the update authority with `setUpdateAuthority` ([update-system.md](update-system.md) §2.1):

| Choice | Authority | Notes |
|---|---|---|
| **APKRun** | `apkrun` when the record keeps a provider, else `manual` | the mode choices above apply |
| **Another app store in Android** | `external` | asks first: "APKRun will stop updating ‹App›. An app store inside Android can update it instead." The mode choices are replaced by "Managed by another installer" |
| "Google Play" (read-only) | `googlePlay` | shown only for such packages. No change is possible |

### 7.6 Mac App

The `MacAppSection` view: status, name, icon, location with **Show in Finder**, **Update Mac App** (with the refresh reasons), **Create Mac App** when none exists, **Make Local Mac App** for portable wrappers ([wrapper.md](wrapper.md) §10.2), and **Remove Mac App…** ([wrapper.md](wrapper.md) §9.5).

### 7.7 Storage

Sizes and **Uninstall…** (§8). For a `broken` package, **Repair…** explains the reason and offers the repair or **Remove from APKRun** ([package-store.md](package-store.md) §11.1 `repairPackage`).

---

## 8. Uninstall dialog

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

Tabs of the `Settings` scene. Keys are in [configuration.md](../03-reference/configuration.md).

### 9.1 General

- **Show APKRun in the menu bar** registers or unregisters the APKRunMenuBar login item, default on. It has no settings key ([configuration.md](../03-reference/configuration.md) §2.10).
- **Default location for new Mac apps**: Applications for me / for all users / Ask each time (`wrappers.defaultLocation`).
- **Updates** for APKRun and Android system updates ([runtime-maintenance.md](runtime-maintenance.md) §7.1): the versions of APKRun and Android with the security patch level; "Check for updates automatically" (`maintenance.checkAutomatically`); "Install APKRun updates automatically" (`maintenance.installAPKRunAutomatically`); Android system updates **Install automatically when the Mac is idle** / **Ask before installing** (`maintenance.installImages`); "Download Android system updates in the background" (`maintenance.downloadImagesAutomatically`); "Notify me when Android was updated" (`maintenance.notifyImageInstalled`); the channel (`maintenance.channel`); **Check Now** with the last check time; one status line with its action (**Install Update…**, **Install and Relaunch Now**, **Update Android Now…**, **Cancel**, **Try Again**). Opening this pane refreshes Sparkle's information at most every 5 minutes. These updates are separate from the Android app updates of §9.3.

### 9.2 Runtime

| Control | Key |
|---|---|
| Start Android: **When an app opens** (`onDemand`, default) / **When I log in** (`atLogin`) | `runtime.startPolicy` ([runtime-daemon.md](runtime-daemon.md) §5.4) |
| Put Android to sleep after ‹n› minutes without apps | `runtime.idleSuspendMinutes` |
| Stop Android after ‹n› minutes without apps (counted from when Android became idle, including the time asleep) | `runtime.idleStopMinutes` |
| Restart Android automatically after a crash | `runtime.autoRestart` |
| Memory, processors (apply at the next start) | `runtime.memoryGiB`, `runtime.cpuCount` |
| Android storage: fixed when Android is set up; a change applies only after **Reset Android…** (§9.8) | `runtime.userdataGiB` ([android-image.md](android-image.md) §5.2) |
| Maximum open apps | `display.maxSessions` |
| Sound output (applies at the next start, **Restart Android Now**) | `audio.output` |

### 9.3 Updates

Global settings for Android app updates ([update-system.md](update-system.md) §3): check interval (`updates.checkIntervalHours`), "Download on expensive networks" (`updates.downloadOnExpensiveNetwork`), "Start Android to install updates" (`updates.startRuntimeToInstall`), "Notify me after automatic updates" (`updates.notifyInstalled`), and the list of update sources.

### 9.4 Privacy

- The global switches `integrations.enabled.*` and the defaults `integrations.defaults.*` ([desktop-integration.md](desktop-integration.md) §2.2).
- **Mac apps you didn't allow**: the denied wrapper list with **Remove** ([wrapper.md](wrapper.md) §7.3).
- macOS permission states for APKRun (microphone) with **Open System Settings**.

### 9.5 Files

The shared folder list ([desktop-integration.md](desktop-integration.md) §6.4). The APKRun Shared folder comes first, with **Show in Finder**. User-added folders show their maximum access (Read only / Read and write) and availability. An unavailable folder says "Can't access. Allow APKRun in System Settings → Privacy & Security → Files and Folders." Buttons: **Add Folder…** (an open panel; the result goes to `addSharedFolder` as a bookmark) and **Remove**.

### 9.6 Language & Region

"Use the Mac's language in Android" (`system.syncLocale`), "Use the Mac's time zone" (`system.syncTimeZone`), "Use the Mac's 12/24-hour setting" (`system.syncClockFormat`). All default on ([desktop-integration.md](desktop-integration.md) §9).

### 9.7 Storage

Disk use of images, the Android instance, packages, and caches.

- **Apps with kept data**: **Reinstall…** and **Delete Data** ([package-store.md](package-store.md) §8).
- **Android system**: the current and previous version with sizes, an update that is ready, and the recovery point with its date and **Delete…**. **Go Back to Android ‹A›…** while a rollback is possible ([runtime-maintenance.md](runtime-maintenance.md) §4.8). **Install from File…** for a signed image archive ([runtime-maintenance.md](runtime-maintenance.md) §4.5, §7.2).
- A hint to delete the recovery point appears when free space is below 10 GiB ([android-image.md](android-image.md) §12.2).

### 9.8 Troubleshooting

- The `apkrun doctor` report, grouped as in [diagnostics.md](diagnostics.md) §7.4. Each check shows its state (✓ / ℹ / ⚠ / ✕ / – not checked), message, and remediation. A group where every check passes collapses to one line. **Run Again** (all, or one row), **Deep Check** (`apkrun doctor --deep`), and **Fix** on rows with a safe fix ([diagnostics.md](diagnostics.md) §7.5). Opening this pane does not start Android: checks that need it show "–" with the last known result.
- **Create Diagnostics Report…**: the sheet of [diagnostics.md](diagnostics.md) §8.5, with what is included and never collected (§6 there), **Include Android app logs**, and the focus app. Then a Save panel, progress with **Cancel**, **Show in Finder**, and **Copy Summary**. Nothing is uploaded.
- **Refresh Dock Icons** restarts the Dock after a confirmation ([wrapper.md](wrapper.md) §8.5).
- **Restart Android**, **Start in Graphics Safe Mode** (`graphics.safeMode`, [graphics.md](graphics.md) §9), and **Reset Android…** (type "Reset" to confirm, [runtime-daemon.md](runtime-daemon.md) §9.5). While safe mode is on, the button is **Turn Off Graphics Safe Mode**, which resets the key and restarts Android.

### 9.9 Advanced

- **Developer mode** (ADB on host loopback, frame statistics, [android-image.md](android-image.md) §11.3). Turning it on states the risk: any local process can then reach Android over ADB at `127.0.0.1:6520`. It asks for confirmation and applies at the next Android start. While it is on, the main window header and the menu bar show "Developer mode" ([security-model.md](../01-architecture/security-model.md)).
- **Install Command-Line Tool…** ([cli.md](cli.md)). **Reveal Logs in Finder**.

---

## 10. Prompts started by other processes

### 10.1 Wrapper approval

apkrund's `WrapperApprovalService` asks through `ApprovalCenter` ([wrapper.md](wrapper.md) §7.3). If APKRun.app is not running, apkrund opens it with `--approve` and `activates = true`.

```text
┌───────────────────────────────────────────────┐
│ [wrapper icon]                                │
│ Allow “Discord” to open com.discord in APKRun?│
│                                               │
│ Location   ~/Downloads/Discord.app            │
│ Signed by  team ABCDE12345                    │
│            Notarization: unknown               │
│            (or: “Not signed by a developer”)  │
│ Android app  installed, version 245.0         │
│            (or: “not installed. This Mac app  │
│             contains version 245.0.”)         │
│                                               │
│ Only allow Mac apps you trust.                │
│                   [Don't Allow]   [Allow]     │
└───────────────────────────────────────────────┘
```

- **Allow** is not the default button. Return does not press it, because the prompt comes from a file the user may not have chosen.
- Show only the signing team when the certificate class is unknown. Show notarization as unknown unless this Mac's OS assessment verified it.
- Requests queue in arrival order. One prompt is shown at a time. A request that times out (10 minutes) closes its prompt.

### 10.2 Prompts shown by wrappers

Wrappers draw these, but they follow the same text and button rules: the link prompt ([desktop-integration.md](desktop-integration.md) §7.2), the "Save to Mac" Save panel ([desktop-integration.md](desktop-integration.md) §6.3), and the launcher screens ([wrapper.md](wrapper.md) §5.4).

---

## 11. Notifications from APKRun

APKRun.app posts these through `HostNotificationClient`:

| Notification | Actions | Target URL |
|---|---|---|
| the update notifications of [update-system.md](update-system.md) §9 | **Update Now** (available updates), **Open** | `apkrun://package/<id>/updates` |
| notifications of Android apps without a usable Mac app ([desktop-integration.md](desktop-integration.md) §5.3), with the app name as subtitle | the Android actions | opens the app with the generic launcher |
| "Android stopped unexpectedly" while no window is open | **Restart** | `apkrun://settings/troubleshooting` |
| "APKRun needs your attention" for an approval while the approval window cannot be shown | — | brings the approval window forward |
| "APKRun ‹version› is available" (from apkrund's probe while APKRun.app isn't running; once per version) | **Update…** (opens General and starts a Sparkle check) | `apkrun://settings/general` |
| "Android system update ready" (ask mode, or after 7 days of waiting) | **Update Now**, **Later** | `apkrun://settings/general` |
| "Android was updated to ‹B›" (only with `maintenance.notifyImageInstalled`) | — | `apkrun://settings/general` |
| "Android couldn't be updated to ‹B›. Your apps and data are unchanged." | **Report a Problem…** | `apkrun://report` |
| "Android needs an update to work with this version of APKRun" while no window is open | **Open APKRun** | `apkrun://settings/general` |

The rules for the last five rows are in [runtime-maintenance.md](runtime-maintenance.md) §7.4. **Update Now** and **Update…** are notification actions handled inside APKRun.app, so they may act.

`HostNotificationClient` opens the `hostNotifications` stream and sends each action back with `hostNotificationResponse` ([runtime-api.md](../03-reference/runtime-api.md) §11.3). Notification permission is requested for APKRun.app at the end of onboarding.

---

## 12. Menu bar

```text
┌─────────────────────────────────┐
│ Android            ● Ready      │
│   (Developer mode on)           │
│─────────────────────────────────│
│ Apps: 2 running                 │
│   [icon] Discord                │
│   [icon] Spotify   🎙           │
│─────────────────────────────────│
│ Updates: 2 available            │
│   Spotify 8.10.3       Update   │
│   F-Droid 1.22         Update   │
│   Update All                    │
│─────────────────────────────────│
│ APKRun 1.3.0 is available       │
│   Update…                       │
│ Android system update ready     │
│   Update Now                    │
│─────────────────────────────────│
│ Open APKRun…                    │
│ Stop Android                    │
│─────────────────────────────────│
│ Quit Menu Bar Item              │
└─────────────────────────────────┘
```

- The status item is a template image. It is filled while Android runs, outlined while it is stopped or asleep, and has a dot when updates are available, the runtime failed, or a live health check needs attention ([diagnostics.md](diagnostics.md) §7.1). In the last case the menu shows "⚠ Needs attention" under the runtime line, which opens Troubleshooting.
- **Apps** lists running sessions. Clicking one brings its window forward (`launch(packageID)`). A microphone symbol marks apps that are recording ([desktop-integration.md](desktop-integration.md) §8.2).
- **Updates** lists available updates with **Update** (manual update, gentle rules apply).
- The maintenance rows appear only when they apply ([runtime-maintenance.md](runtime-maintenance.md) §7.3): "APKRun ‹version› is available" with **Update…**, "Android system update ready" with **Update Now**, "Finish updating APKRun…" in `restartPending`, and "◐ Updating Android…" in the runtime line during a migration. APKRunMenuBar relaunches itself when apkrund reports a newer build ([runtime-maintenance.md](runtime-maintenance.md) §3.7).
- **Stop Android** asks for confirmation when apps are open. When Android is stopped, the item is **Start Android**.
- **Quit Menu Bar Item** quits APKRunMenuBar only. It stays off until the next login, or until the user opens APKRun.app with the setting still on.
- "Developer mode on" appears under the runtime line while developer mode is enabled.
- The menu lists sessions only, not apps kept running without a window (OQ-10).
- APKRunMenuBar observes only. It never keeps Android running ([runtime-daemon.md](runtime-daemon.md) §5.1). The CLI shows the same information with `apkrun status` ([cli.md](cli.md)).

---

## 13. Localization and accessibility

- **Languages:** English (development language) and Japanese. All user-facing strings of APKRun.app and APKRunMenuBar are in String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`).
- **Executables without resources.** The launcher and the CLI compile their strings into the executable. Generators write `LauncherStrings.generated.swift` and `CLIStrings.generated.swift` from `Apps/APKRunLauncher/Localizable.xcstrings` and `CLI/apkrun/Localizable.xcstrings` ([wrapper.md](wrapper.md) §5.9, [cli.md](cli.md) §6.1). The error catalog works the same way (`ErrorCatalog.generated.swift`, [error-catalog.md](../03-reference/error-catalog.md)). The CLI picks the language from the user's preferred languages. `--json` output is never localized.
- **apkrund** has no UI. Every text it produces for users is an error catalog code or a health check result, which the client localizes. Its embedded Info.plist (`NSMicrophoneUsageDescription`, [vm.md](vm.md) §3) has no localizations.
- Plurals use the catalog's plural variants. Sizes use `ByteCountFormatter`, dates `Date.FormatStyle`.
- CI fails when a release catalog has untranslated or stale entries. A pseudo-language run (`-AppleLanguages "(en-XA)"`, double-length strings) is part of the UI tests, to catch truncation.
- **Accessibility:** every control has an accessibility label, and icon-only buttons have text labels. Status is never shown by color alone. The main window, sheets, and Settings are fully keyboard operable. Each release runs `performAccessibilityAudit()` over the main screens. Android apps' own accessibility is out of scope ([display-and-windowing.md](display-and-windowing.md) §7.7).

### 13.1 Terms

| Use | Do not use |
|---|---|
| Mac app (for a wrapper) | wrapper, bundle |
| Android (for the runtime), "Start Android", "Stop Android" | VM, guest, runtime (except in Troubleshooting and the CLI) |
| app (for an Android package) | package, APK (except where the file is meant) |
| update source | provider, authority |

The glossary is [glossary.md](../00-product/glossary.md).

---

## 15. Tests

| Tier | What | Where |
|---|---|---|
| T0 | Models with a fake `RuntimeService`: status priority table (§5.3), relation handling (§6.1), reload after reconnect, URL routing, package ID validation. Settings patches: each control writes its key and value (§7, §9) | `Apps/APKRun/Tests/` |
| T1 | XCUITest with the embedded runtime fake: onboarding resume, the add flow for each relation, uninstall choices, the approval prompt (Return does not allow) | `Tests/IntegrationTests/HostUITests/` |
| T2 | The screens and flows of §4–§12 against a real runtime, with the fixtures | `Tests/IntegrationTests/HostUITests/` |
| T2 | Accessibility audit and the pseudo-language run (§13) | `Tests/IntegrationTests/HostUITests/` |

---

## 16. Open items

- OQ-08: whether APKRun.app offers an Android app catalog in v1. The add flow and update sources cover v1.
- OQ-09: whether "Always on top" applies in full screen (§7.2).
- OQ-10: whether the menu bar lists apps kept running without a window (§12).
