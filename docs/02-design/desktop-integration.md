# Desktop Integration

Desktop integration connects Android apps to the Mac: the clipboard, notifications, files, links, sound, the microphone, and the system language and clock. Each integration is a narrow, policy-checked path. Android apps are untrusted code (NFR-SEC-01), so each path moves only what the user asked for, only for the package it belongs to, and never logs content.

---

## 1. Responsibilities

| Component | Module / process | Responsibility |
|---|---|---|
| `IntegrationPolicy` | IntegrationCore, apkrund | decides every integration request from the package settings, the global switches, and the session state (§2.3) |
| `ClipboardCoordinator` | IntegrationCore | loop prevention, size rules, which window may exchange (§4) |
| `NotificationCoordinator` | IntegrationCore | forwarding allowlist, routing to the wrapper or APKRun, activation, badges (§5) |
| `FileTransferService` | IntegrationCore | drag and drop into Android, "Save to Mac" out of Android (§6.2, §6.3) |
| `SharedFolderService` | IntegrationCore | serves the Mac folder roots to the Android document provider (§6.4) |
| `LinkForwarder` | IntegrationCore | Android links → default Mac browser or mail app (§7) |
| `AudioPolicy` | IntegrationCore and RuntimeCore | sound device configuration, microphone gating (§8) |
| `LocaleTimeSync` | IntegrationCore | language list, time zone, 12/24-hour format, wall clock (§9) |
| `IntegrationChannel` | protocol in IntegrationCore, implemented by RuntimeCore | the Guest Agent operations and events of [guest-protocol.md](guest-protocol.md) §7–§8 (capabilities `clipboard.*`, `notifications.v1`, `url.v1`, `files.v1`, `locale.v1`) |
| Window-side adapters | `APKRunLauncher` (wrapper process) | `PasteboardAdapter` (NSPasteboard), `NotificationPoster` (UserNotifications), `DropTarget`, save panels, link prompts. They do AppKit I/O and carry no policy |

Decisions live in IntegrationCore in apkrund. AppKit work runs in the process that owns the app's window: the wrapper, or the generic launcher. The window process does AppKit work for three reasons:

1. macOS attributes notifications to the posting process. Only the wrapper can post as "Discord" (§5).
2. macOS can ask the user before a background process reads the pasteboard. A read that the frontmost app does for the user's ⌘V is not asked about (R-21).
3. The window process uses the file access the user gives with drag and drop or a Save panel. apkrund, a LaunchAgent, may be denied access to protected folders by TCC and never needs it.

---

## 2. Policy and settings

### 2.1 Per-package settings (`integrations.*`)

Stored in the package settings ([package-store.md](package-store.md) §2.4). The JSON schema is in [package-metadata-json.md](../03-reference/package-metadata-json.md) §3.

| Key | Values | Default | Meaning |
|---|---|---|---|
| `integrations.clipboard` | `true`, `false` | `true` | text (and, when supported, images and HTML) between the Mac pasteboard and Android, only while the app's window is key (§4) |
| `integrations.notifications` | `true`, `false` | `true` | Android notifications of this package appear as Mac notifications (§5) |
| `integrations.links` | `ask`, `mac`, `android` | `ask` | where `http`, `https`, and `mailto` links opened by the app go (§7) |
| `integrations.files` | `true`, `false` | `true` | drag and drop into the app and "Save to Mac" from the app. Always one user action per transfer (§6.2, §6.3) |
| `integrations.sharedFolders` | `off`, `readOnly`, `readWrite` | `off` | the app may open files in the Mac folders of §6.4 through the Android file picker |
| `integrations.microphone` | `true`, `false` | `false` | the app may record from the Mac microphone (§8.2) |

The `integration` object in `wrapper.json` carries the same initial values without the `integrations.` prefix ([wrapper.md](wrapper.md) §3). Its `"files": true` value maps to `integrations.files`.

### 2.2 Global settings

Set in APKRun Settings → Privacy ([host-ui.md](host-ui.md) §9.4). Stored in the app configuration ([configuration.md](../03-reference/configuration.md)).

| Key | Default | Meaning |
|---|---|---|
| `integrations.enabled.<name>` for `clipboard`, `notifications`, `links`, `files`, `sharedFolders`, `microphone` | `true` | a global switch. `false` turns the integration off for every package without changing their settings |
| `integrations.defaults.<key>` | the defaults of §2.1 | the settings a newly recorded package gets. A `wrapper.json` value wins for a package installed from a portable wrapper, but a wrapper made on another Mac can only lower a value ([configuration.md](../03-reference/configuration.md) §3.3). A value equal to the built-in default is not written to the package, so a compatibility recommendation can still apply ([diagnostics.md](diagnostics.md) §10.3) |
| `audio.output` | `true` | attach the sound output device (§8.1) |
| `sharedFolders.roots` | the APKRun Shared folder only | the list of Mac folders of §6.4 |
| `system.syncLocale`, `system.syncTimeZone`, `system.syncClockFormat` | `true` | §9 |

### 2.3 Evaluation

```swift
public enum IntegrationKind: String, Codable, Sendable { case clipboard, notifications, links, files, sharedFolders, microphone }

public enum IntegrationDecision: Sendable, Equatable {
    case allow
    case ask                          // links only (§7)
    case deny(IntegrationDenial)      // .globallyOff, .packageOff, .notFocused, .noSession, .notSupported(capability), .rateLimited
}

public actor IntegrationPolicy {
    public func evaluate(_ kind: IntegrationKind, package: PackageID, context: IntegrationContext) async -> IntegrationDecision
}
```

- `IntegrationContext` holds what the rule needs: whether a session of the package exists, whether its window is key (`focusChanged` on the session channel), and the time since the last user input in that window.
- Settings are read through `PackageStore.settings(for:)` on every evaluation. No cache outlives a `settingsChanged` event ([package-store.md](package-store.md) §2.4).
- A denial is counted per kind and reason (`integration.denied{kind, reason}`) and logged at debug level with the package ID only.
- Packages that APKRun does not manage (for example preinstalled system apps) use the defaults of §2.1, except `notifications`, which is off for them. Their notifications are never forwarded.

### 2.4 Support per image

| Integration | Stock image (development) | Custom image |
|---|---|---|
| Clipboard | text. The background read as the shell uid must be verified (§16) | yes |
| Notifications | no (the listener is not granted) | yes |
| Links | no (no browser role) | yes |
| Files: drag and drop, Save to Mac | no | yes |
| Shared folders (document provider) | no | yes |
| Locale, time zone, clock format | yes | yes |
| Wall clock | ADB fallback on userdebug images (§9), otherwise Android's network time | yes (`SyncTime`) |
| Sound, microphone | if the stock kernel has `virtio_snd` ([android-image.md](android-image.md) §7.5) | yes |

The Guest Agent reports what it supports in `Hello` capabilities. The settings UI greys out an integration that the running image lacks and says why.

---

## 3. Channels and lifecycle

### 3.1 Guest side

The Guest Agent components are `ClipboardBridge`, `NotificationBridge`, `UrlRedirect`, `FilesBridge` with `MacFilesProvider`, and `LocaleTimeService` ([guest-components.md](guest-components.md) §6.1). Their operations and events are in [guest-protocol.md](guest-protocol.md) §7.1, §7.5, §8.1, and §8.4. Large payloads (images, files) use the bulk stream (6102, [guest-protocol.md](guest-protocol.md) §10).

### 3.2 Configuration push

RuntimeCore pushes the host-owned configuration after every handshake with the Guest Agent ([runtime-daemon.md](runtime-daemon.md) §3.4, §4.2), and again when a relevant setting changes:

| Operation | Content | Changed by |
|---|---|---|
| `SetNotificationForwarding(packages)` | packages with `integrations.notifications` in effect (§5.1) | settings, install, uninstall |
| `SetUrlRedirect(enabled, excluded_packages)` | `enabled` = global `links` switch; `excluded_packages` = packages with `links = android` or `links` off (§7.1) | settings |
| `SetSharedFolderAccess(entries)` | per package: `off`, `readOnly`, `readWrite`; and the roots (§6.4) | settings, root list |
| `SetMicrophoneAccess(packages)` | packages with `integrations.microphone` in effect (§8.2) | settings, install, uninstall |
| `SetLocale`, `SetTimeZone`, `SetClockFormat`, `SyncTime` | §9 | host notifications |

### 3.3 Session channel additions

The window process and apkrund exchange these messages on the session channel ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3):

```text
client → server
  pushClipboard(ClipItem) → ClipAck                 §4.2 (⌘V and focus)
  clipboardWritten(changeCount, digest)             §4.3 (after writing a guest clip to NSPasteboard)
  importFiles([FileHandle], [ImportFileInfo], ImportTarget) → ImportResult     §6.2
  acceptExport(offerID, FileHandle?)                §6.3 (nil = cancelled)
  resolveLinkPrompt(promptID, LinkChoice)           §7.2
server → client (events)
  clipboardFromGuest(ClipItem)                      §4.3 (only to the key window's session)
  exportOffered(ExportOffer)                        §6.3
  linkPrompt(LinkPrompt)                            §7.2
```

`ClipItem`, `ImportFileInfo`, `ExportOffer`, and `LinkPrompt` are RuntimeAPI DTOs ([runtime-api.md](../03-reference/runtime-api.md) §6.3, §11.2). File handles cross XPC as `NSFileHandle`. A `ClipItem` image is PNG bytes as `Data`, at most 16 MiB, so a clip fits the 32 MiB XPC message limit ([runtime-api.md](../03-reference/runtime-api.md) §4.10). Only the host ↔ guest hop uses a bulk transfer (§4.4).

---

## 4. Clipboard

### 4.1 Model

The clipboard path is `NSPasteboard ↔ apkrund ↔ Guest Agent ↔ ClipboardManager`.

- **No background sync.** The Mac pasteboard and the Android clipboard are exchanged only while a window of a package with `integrations.clipboard` is key ([security-model.md](../01-architecture/security-model.md) §6). Android has one clipboard for all apps, so an exchange made for one app is visible to every Android app that reads the clipboard afterwards. The settings UI says so.
- **Mac → Android** happens at a paste (⌘V or Edit → Paste) and when the window becomes key (§4.2).
- **Android → Mac** happens when an Android app copies while its window is key (§4.3).
- Content is never logged, never stored on disk by APKRun (except as a bulk-transfer temp file for images, deleted after use), and never included in diagnostics (NFR-SEC-05).

### 4.2 Mac → Android

```text
trigger (in the window process):
  a) ⌘V / Edit → Paste in editor mode (input.md §6)
  b) window becomes key, and NSPasteboard.general.changeCount ≠ the last count this adapter pushed or wrote,
     and reading does not require a user prompt (R-21)
PasteboardAdapter reads, in order: public.utf8-plain-text, public.html, public.png / public.tiff
  flags: org.nspasteboard.ConcealedType → sensitive; org.nspasteboard.TransientType → only for a paste, never on focus
  skip when the pasteboard carries io.apkrun.clip-origin (it came from Android, §4.3) and its digest equals the guest's
  current clip (the digest is kept by ClipboardCoordinator)
pushClipboard(ClipItem{text?, html?, image?, sensitive, digest}) → apkrund
  IntegrationPolicy.evaluate(.clipboard, package, context) — must be the key window's session
  ClipboardCoordinator: size rules (§4.4); record lastHostDigest
  Guest Agent SetClipboard(ClipData{origin HOST, seq, text, html, image(transfer_id), sensitive})
  reply → ClipAck{seq}
paste (case a): the window sends the paste to Android after the ack (input.md §6), or after 500 ms without an ack
                as a plain-text commit
```

- `sensitive` becomes `ClipDescription.EXTRA_IS_SENSITIVE` in Android, so Android does not show the content in its clipboard preview.
- Case b makes Android's own Paste command (long press → Paste) work after copying on the Mac. If macOS would ask for the read (R-21), case b is skipped. Then only ⌘V brings Mac content into Android.

### 4.3 Android → Mac

```text
Guest Agent: ClipboardManager.OnPrimaryClipChangedListener
  (priv-app: the APKRun IME is the default IME and runs in the agent's uid, so background reads are allowed)
  ignore the change if it is the clip this agent just set (same seq / same content hash)
  ClipboardChanged(ClipData{origin GUEST, seq, text, html, image, source_package, sensitive})
apkrund ClipboardCoordinator:
  accept only if a window is key, its package has integrations.clipboard, and source_package (when known) is that package
  or a package that also has integrations.clipboard (for example a system dialog inside the app's window)
  ignore if digest == lastHostDigest (our own push, echoed)
  event clipboardFromGuest(ClipItem) → the key window's process
PasteboardAdapter: clearContents, write the types, plus io.apkrun.clip-origin = {package, seq, digest};
  sensitive → also org.nspasteboard.ConcealedType (clipboard managers skip it)
  clipboardWritten(changeCount, digest) → apkrund (so the next focus does not push it back)
```

Changes that happen while no window is key are dropped. They are not queued.

### 4.4 Types and limits

| Type | Mac | Android | Limit |
|---|---|---|---|
| Plain text | `public.utf8-plain-text` | `ClipData.newPlainText` | 1 MiB UTF-8. Longer text is truncated at a character boundary, and the window shows "Only the first 1 MB was copied." |
| HTML | `public.html` | `ClipData.newHtmlText` (with the plain text) | 1 MiB |
| Image | `public.png`; `public.tiff` converted to PNG | a `content://` URI from the agent's `FileProvider` with a PNG, `ClipDescription` MIME `image/png` | 16 MiB encoded, 8192 px per side. Over the bulk stream |
| Files, URLs as files, rich text (RTF) | — | — | Not exchanged in v1. RTF falls back to plain text |

Loop prevention uses three independent signals: the `origin` and `seq` of `ClipData`, the content digest (SHA-256 over the normalized text or image bytes) on the host, and the `io.apkrun.clip-origin` marker on the Mac pasteboard. Two windows of different Android apps never bounce a clip between them.

### 4.5 Acceptance

- Text copied on the Mac with ⌘C reaches the Android field with ⌘V, and text copied in Android reaches the Mac with ⌘V, including `héllo 😀`.
- With `integrations.clipboard = false`, neither direction works, and the policy counter shows the denial.
- A 5-minute loop between two fixture windows, copying alternately, adds no pasteboard changes beyond the user's copies.
- ⌘V latency (key down → text visible in Android) p95 ≤ 150 ms for 64 KiB of text.
- R-21 is settled: whether reading on focus prompts on macOS 27, and which API tells the adapter in advance.

---

## 5. Notifications

### 5.1 Guest side

- `ApkRunNotificationListener`, a `NotificationListenerService` in the Guest Agent. The agent grants itself listener access at start (`setNotificationListenerAccessGranted`, [guest-components.md](guest-components.md) §5). If access is lost, it sends `HealthWarning(NOTIFICATION_LISTENER_DISABLED)`.
- Only packages in the forwarding allowlist (`SetNotificationForwarding`) are forwarded. Everything else never leaves the guest.
- Filters run in the agent, before anything is sent:

| Android notification | Forwarded |
|---|---|
| `FLAG_GROUP_SUMMARY` | no. The Mac groups by thread (§5.2) |
| ongoing (`FLAG_ONGOING_EVENT`), foreground-service, or `CATEGORY_TRANSPORT` (media controls) | no in v1 (§10) |
| importance `IMPORTANCE_MIN` or `IMPORTANCE_NONE`, or its channel is blocked | no |
| an update of a posted notification with `FLAG_ONLY_ALERT_ONCE` | yes, with `alert = false` |
| anything else | yes |

- Payload: `Notification` ([guest-protocol.md](guest-protocol.md) §8.4): key, package, title (≤ 256 characters), text (≤ 2048 characters: the last `MessagingStyle` message when present, else `EXTRA_BIG_TEXT`, else `EXTRA_TEXT`), group key, alert, and action titles. No images and no remote input in v1.

### 5.2 Mapping to the Mac

| Android | `UNMutableNotificationContent` |
|---|---|
| title | `title` |
| text | `body` |
| — | `subtitle` is empty for wrapper notifications. For notifications posted by APKRun (no wrapper, §5.3) it is the app's display name |
| group key, else channel ID | `threadIdentifier = "<package>/<group or channel>"` |
| importance `LOW` or `alert = false` | no sound, `interruptionLevel = .passive` |
| importance `DEFAULT` or `HIGH` | `sound = .default`, `.active` |
| actions (up to 3) | a `UNNotificationCategory` with actions `a0`–`a2` and the action titles. Categories are keyed by a hash of the titles and kept in an LRU of 32 per wrapper, because the category set is registered per process |
| key | `identifier = "<package>|<first 16 hex of SHA-256(key)>"`. Posting again with the same identifier replaces the Mac notification, as an Android update replaces its notification |
| — | `userInfo = {package, keyDigest}`. The Android key itself stays in apkrund |

- The icon is the wrapper's icon, because the wrapper posts it. APKRun never draws the Android small icon.
- `time-sensitive` and critical alerts need entitlements that ad-hoc wrappers cannot have. They are not used.
- While the app's window is key, `userNotificationCenter(_:willPresent:)` returns `[.list, .sound]` for `DEFAULT` and `[.banner, .list, .sound]` for `HIGH`.
- Focus modes and notification settings are macOS's. Each wrapper appears separately in System Settings → Notifications ([wrapper.md](wrapper.md) §4.2).

### 5.3 Routing

```text
NotificationPosted(n) → NotificationCoordinator
  policy: .notifications for n.package (global switch, package setting)
  wrapper = registry entry for n.package with status valid (wrapper.md §9.1)
  ├─ wrapper process connected (window open or background mode) → relay.post(payload)
  ├─ wrapper registered, not running → start it in background mode (wrapper.md §5.8), queue the payload
  │     queue ≤ 50 per package, 10 s timeout; on timeout the queue is dropped and counted
  └─ no usable wrapper → APKRun posts it (HostNotifier, update-system.md §9), subtitle = display name
NotificationRemoved(key) → relay.remove(identifier), or HostNotifier removal
```

The notification relay runs on the `.wrapper` endpoint ([wrapper.md](wrapper.md) §12.1). Its DTOs `RelayMessage`, `NotificationPayload`, and `RelayResponse` are in [runtime-api.md](../03-reference/runtime-api.md) §11.3:

```text
notificationRelay(background) → stream of
  post(NotificationPayload{identifier, threadID, title, body, sound, interruption, actions, badge})
  remove([identifier])
  setBadge(Int?)
client → server (notificationRelayResponse, one-way)
  activated(identifier, actionIndex?)
  dismissed(identifier)
  authorizationChanged(MacPermissionState)       the wire form of UNAuthorizationStatus
```

- **Reconnect.** After a reconnect, `SetNotificationForwarding` makes the agent re-send every active forwarded notification with `replay = true` ([guest-protocol.md](guest-protocol.md) §8.4). The coordinator rebuilds its key map and badge counts from them without new banners, and removes Mac notifications whose Android notification is gone.
- **Badge.** The Dock badge is the number of forwarded notifications still active in Android for the package (`NSApp.dockTile.badgeLabel` while running, `content.badge` when posting). It is cleared at 0.
- **Authorization.** The launcher asks for notification permission (`.alert`, `.sound`, `.badge`) at the first foreground session start of a package with `integrations.notifications`, not at install. If a background start finds the status `notDetermined`, it asks then. `denied` is reported to apkrund. The app page then says "Notifications for ‹App› are turned off in System Settings" with a button that opens the Notifications pane. The error is `integration.notificationPermissionDenied`, whose remediation action is `openNotificationSettings` ([diagnostics.md](diagnostics.md) §2.3).
- **Runtime state.** Android posts only while the runtime runs. A package closed with `window.closeBehavior = stop` posts nothing afterwards, and a suspended VM posts nothing until it resumes ([runtime-daemon.md](runtime-daemon.md) §5.1). The notifications setting shows this next to the switch, with a link to "Keep running in the background".
- **Push services.** The runtime has no Google Play services (scope.md §3). Apps that rely only on Firebase Cloud Messaging get no push messages while they are not running. Apps with their own connection (or UnifiedPush) work while kept running.

### 5.4 Click and actions

```text
Mac: user clicks the notification (or an action button)
wrapper process (UNUserNotificationCenterDelegate.didReceive):
  default action / action a<i>:
    background mode → activation policy .regular, continue at wrapper.md §5.2 step 3 (window, openSession)
    NSApp.activate(); order the window front
    relay.activated(identifier, actionIndex) after the session is `running`
  dismiss (category option .customDismissAction) → relay.dismissed(identifier)
apkrund:
  activated → Guest Agent ActivateNotification(key, action_index, display_id = the session's display)
  dismissed → DismissNotification(key)   (as a swipe-away on Android)
Guest Agent: PendingIntent.send with ActivityOptions launch display = display_id
  (and the background-activity-start mode that lets the agent's privilege apply, API 34+; to be verified)
  no content intent → LaunchApplication(package, display_id) instead
```

- A click on a Mac notification whose Android notification no longer exists (the runtime restarted, or the app removed it) opens the app normally.
- For notifications posted by APKRun (no wrapper), a click runs `launch(packageID)` with the generic launcher ([runtime-daemon.md](runtime-daemon.md) §7.2), then the same `ActivateNotification`.

### 5.5 Targets

- Each forwarded notification appears as a notification of its wrapper with the wrapper icon. The ongoing notification and the group summary do not appear. A `LOW` notification is silent.
- With `integrations.notifications = false`, nothing leaves the guest.
- Latency from Android `notify()` to the Mac banner: p50 ≤ 1 s with the wrapper running, ≤ 3 s with a background start.
- No Dock tile flash in background mode, and the notification permission survives a wrapper refresh (R-19, [wrapper.md](wrapper.md) §5.8).

---

## 6. Files

### 6.1 Principles

- Android never sees the home folder. It sees only (a) single files that the user drops or saves, and (b) the folders of §6.4, only for packages with `integrations.sharedFolders`, only through Android's file picker, and read-only by default (NFR-SEC-02).
- The VM has no directory-sharing device (virtio-fs). A mounted share would be visible to every Android app with storage access and could not follow per-package settings ([vm.md](vm.md) §4). All file access goes through the Guest Agent, which knows the calling package.
- Files that come out of Android are untrusted. APKRun sets `com.apple.quarantine` on every file it writes to the Mac, with the agent name "‹App› (APKRun)", so Gatekeeper checks anything executable before it runs.

### 6.2 Mac → Android: drag and drop

```text
wrapper window (DropTarget on the session view): accepts file URLs; no folders, no promised files in v1
  limits: ≤ 20 files, each ≤ 2 GiB, total ≤ 4 GiB; otherwise the drop is refused with a message
  opens each file for reading → importFiles([FileHandle], [ImportFileInfo{name, size, uti}], .shareToApp)
apkrund: policy .files for the package (the session's package; there must be a user drop, which only the window can report)
  bulk transfers (host → guest) of the file handles; ImportFiles(target SHARE_TO_PACKAGE, package, display_id, files)
Guest Agent FilesBridge:
  stores the files in its private cache, exposes them through its FileProvider (authority io.apkrun.guest.files)
  ACTION_SEND / ACTION_SEND_MULTIPLE with the content URIs, FLAG_GRANT_READ_URI_PERMISSION, to the package, on display_id
  the package has no send target → MediaStore.Downloads insert instead, and a toast "Saved to Downloads"
  ImportResult{repeated content_uri, disposition: SHARED | SAVED_TO_DOWNLOADS}
```

- Android has no API to inject a drag from outside Android, so a drop does not arrive as a `DragEvent` at the drop position. It arrives as a share to the app, which is how most apps accept files ([input.md](input.md) §10).
- Imported files in the agent's cache are deleted 24 h after the share, or when the package is uninstalled. Files saved to Downloads stay.

### 6.3 Android → Mac: "Save to Mac"

```text
Android app shares (ACTION_SEND / SEND_MULTIPLE) → chooser → "Save to Mac" (Guest Agent activity SaveToMacActivity)
   or the app creates a document in the Mac provider (ACTION_CREATE_DOCUMENT, §6.4, readWrite roots only)
SaveToMacActivity: reads name, MIME type, size from the content URIs (at most 20 items)
  ExportFileOffered(offer_id, name, mime_type, size, source_package, display_id)
apkrund: policy .files for source_package; the offer goes to the window of the session on display_id
  (no such window → ResolveExport(offer_id, DECLINE))
  event exportOffered(ExportOffer{offerID, name, size, type})
wrapper window: NSSavePanel as a sheet (default folder ~/Downloads, the name from Android, sanitized)
  save → acceptExport(offerID, FileHandle opened for writing); cancel → acceptExport(offerID, nil)
apkrund: ResolveExport(offer_id, ACCEPT) → the agent sends the bytes on the bulk stream
  apkrund writes them to the handle, checks size and SHA-256 from BulkEnd
wrapper: sets com.apple.quarantine on the saved file; on failure deletes the partial file
```

- Name sanitizing is the same as for wrapper file names ([wrapper.md](wrapper.md) §4.3), plus an extension from the MIME type when the name has none.
- Each item opens its own panel. A folder chooser for many items is post-v1.

### 6.4 Shared folders: the Mac document provider

**Roots.** `~/Library/Application Support/APKRun/Shared/` (created at first run, [filesystem-layout.md](../01-architecture/filesystem-layout.md) §1) and any folders the user adds in Settings → Files. Each root has its own maximum access (`readOnly` or `readWrite`). The effective access for a package is the lower of the root's access and `integrations.sharedFolders`.

**Refused roots.** `addSharedFolder` refuses, with `folderRefused` (§12):

- a volume root (`/`, `/Volumes/<name>`);
- the home folder itself;
- `~/Library` and any folder inside it. The Shared folder is built in and is not added;
- a hidden folder or any folder inside one (such as `~/.ssh`);
- a 33rd added folder. At most 32 folders can be added.

A subfolder of the home folder, such as `~/Documents` or `~/Downloads`, can be added, because the user picks it. Nothing is shared without that choice (NFR-SEC-02).

**Guest side.** `MacFilesProvider`, a `DocumentsProvider` in the Guest Agent (authority `io.apkrun.guest.macfiles`), shows one root per Mac folder in the Android file picker. Android apps reach files only through the picker (`ACTION_OPEN_DOCUMENT`, `ACTION_OPEN_DOCUMENT_TREE`, `ACTION_CREATE_DOCUMENT`) and the URI permissions that the picker grants.

- `openDocument` and every write check `getCallingPackage()` against the access list from `SetSharedFolderAccess`. A package without access gets `SecurityException("Blocked by APKRun settings")`. Browsing in the picker (caller `com.android.documentsui`) lists names only.
- File contents are served with `StorageManager.openProxyFileDescriptor`, so Android apps get a seekable file descriptor whose reads and writes become host requests. Nothing is copied into the guest.

**Host side.** The agent calls the host operations of [guest-protocol.md](guest-protocol.md) §7.5 (`HostListRoots`, `HostQueryChildren`, `HostStat`, `HostOpenFile`, `HostReadRange`, `HostWriteRange`, `HostCloseFile`, `HostCreateDocument`, `HostDeleteDocument`, `HostRenameDocument`). Every request carries the calling package. `SharedFolderService` checks each request:

1. the package's effective access for the root (`readWrite` for writes);
2. the path: relative to the root, no `..` component, no absolute path. It is resolved with `openat` from the root's directory descriptor, with `O_NOFOLLOW` on each component, so symlinks cannot leave the root;
3. only regular files and directories. Hidden files (a leading `.`) and packages (`.app`, `.photoslibrary`) are not listed and cannot be opened;
4. limits: 4096 entries per listing page, 1 MiB per read or write, 64 open handles per package, and handles closed when the runtime stops.

- Files created or written by Android get `com.apple.quarantine` (§6.1).
- Folders inside Desktop, Documents, Downloads, iCloud Drive, or on network or removable volumes are protected by macOS privacy controls. apkrund asks for access on first use, and macOS attributes the prompt to APKRun. If access is denied, the root is shown as unavailable in the picker and in Settings, with the steps to allow it. R-22.
- The root list and each root's access are stored in the app configuration with bookmarks (`sharedFolders.roots`), so renamed or moved folders are followed.

### 6.5 Acceptance

- Three dropped files (one of 1.5 GiB) arrive with the right hashes. With `integrations.files = false`, the drop is refused.
- "Save to Mac" writes the file where the Save panel said, with the right hash and a quarantine attribute.
- With `sharedFolders = readOnly`, an app can pick and read files in the Shared folder but cannot create or modify them, and a symlink that points outside the root cannot be opened. With `off`, opening a previously granted URI fails.
- A second package without access cannot open a URI that was granted to another package and passed to it.
- Reading a 1 GiB file through the provider runs at ≥ 200 MB/s (provisional).

---

## 7. Links

### 7.1 Guest side

- `UrlRedirectActivity` in the Guest Agent holds the browser role (`RoleManager` `ROLE_BROWSER`, [guest-components.md](guest-components.md) §5). It handles `ACTION_VIEW` for `http` and `https`, and `ACTION_SENDTO` / `ACTION_VIEW` for `mailto`.
- Android's own resolution runs first. A link with a verified Android App Link for an installed app opens that app, inside Android. Only links that would go to a browser reach the redirect activity.
- Custom Tabs (`CustomTabsIntent`) are `ACTION_VIEW` intents with extras and are handled the same way.
- The activity sends `OpenUrlOnHost(request_id, url, source_package, display_id)` and keeps the original intent for 60 s. For packages in `excluded_packages`, it passes the intent to the in-Android browser directly and sends nothing.
- The in-Android browser is AOSP `Browser2` (a WebView browser). If the image lacks it, the product adds one ([android-image.md](android-image.md) §11.2). Without an in-Android browser, "Keep in Android" is not offered.

### 7.2 Host side

```text
OpenUrlOnHost → LinkForwarder
  validate: URLComponents parse; scheme http | https | mailto; length ≤ 8 KiB; http(s) needs a host
    anything else → ResolveUrl(request_id, DROP), counted
  policy: the app's window must be key, or have had user input in the last 5 s (links opened by background work are dropped)
  rate: ≤ 3 per 10 s per package; beyond that DROP
  integrations.links:
    mac     → WorkspaceOpener.open(url) (default browser or mail app); ResolveUrl(OPENED_ON_HOST)
    android → (normally excluded in the agent) ResolveUrl(OPEN_IN_GUEST)
    ask     → linkPrompt(LinkPrompt{promptID, host or address, scheme}) to the window
              sheet: "‹App› wants to open ‹example.com›." [Open in Browser] [Keep in Android] [Cancel], ☐ Remember for ‹App›
              resolveLinkPrompt → as above; "Remember" writes integrations.links = mac | android
              no answer in 60 s → Cancel
Guest Agent ResolveUrl: OPEN_IN_GUEST → start the kept intent in the in-Android browser on the same display
```

- `WorkspaceOpener` is a protocol of IntegrationCore. Its only implementation is the `NSWorkspace` adapter in RuntimeHost, which also opens wrappers for `launch` and background starts ([runtime-daemon.md](runtime-daemon.md) §1). IntegrationCore itself does not use AppKit ([modules.md](../01-architecture/modules.md) §2).
- The prompt shows the host in Unicode, with the registrable domain in bold. It never shows the path or query, which can contain tokens.
- **Sign-in flows.** A Mac browser cannot deliver a custom-scheme redirect (`myapp://callback`) to Android. "Keep in Android" exists for these apps. The link prompt shows "Signing in? Keep links from ‹App› in Android" when the URL path contains `oauth`, `authorize`, or `login`.
- Mac → Android links are post-v1 (OQ-23).

### 7.3 Acceptance

- With `ask`, the first link shows the prompt. "Open in Browser" with Remember opens it in the default browser, and later links open without a prompt. "Keep in Android" opens the in-Android browser on the app's display.
- `mailto` opens the default Mac mail app. `javascript:` and `intent:` URLs are dropped. A link sent from background work is dropped.
- With the global links switch off, all links stay in Android.

---

## 8. Audio and microphone

### 8.1 Output

- One virtio-snd device (`VZVirtioSoundDeviceConfiguration`) with one output stream to `VZHostAudioOutputStreamSink` ([vm.md](vm.md) §11). The guest uses the goldfish audio HAL on the virtio-snd card ([android-image.md](android-image.md) §7.5). macOS plays it on the current default output device and follows device changes.
- Android mixes all Android apps into this one stream. Per-app volume is Android's. The host has one volume: the macOS output volume. A per-app mute is post-v1.
- `audio.output = false` leaves the device out of the VM (`VMDefinition` `soundOutput`). It takes effect at the next runtime start, and Settings offers **Restart Android Now**.
- macOS shows apkrund as the process that plays audio. Now Playing and media keys are post-v1 (§10).
- Target output latency ≤ 120 ms (provisional), with no underrun in a 10-minute playback while the VM is otherwise idle.

### 8.2 Microphone

- The input stream (`VZHostAudioInputStreamSource`) is attached only while at least one package has the microphone integration in effect. The VM configuration is fixed at start, so turning the microphone on for the first package, or off for the last one, needs a runtime restart ([vm.md](vm.md) §11). The settings UI says so.
- **macOS permission.** apkrund is the process that captures. It embeds an Info.plist (`__TEXT,__info_plist`) with `NSMicrophoneUsageDescription`, and macOS asks once, for APKRun ([vm.md](vm.md) §3). Wrappers have no usage description ([wrapper.md](wrapper.md) §2.1). Whether the prompt appears at VM start or at the first capture is open (OQ-29).
- **Per-package gating inside Android.** The host cannot tell which Android app reads the virtio-snd input. The Guest Agent enforces the setting with app ops: `OP_RECORD_AUDIO` is `MODE_IGNORED` for every package that is not in `SetMicrophoneAccess`, and `MODE_ALLOWED` or the default for listed ones. Such apps record silence, the documented app-ops behavior. Android's own runtime permission dialog for `RECORD_AUDIO` still appears in the app's window.
- The Guest Agent reports active recordings (`AudioManager.getActiveRecordingConfigurations`) as events. The menu bar shows "‹App› is using the microphone" ([host-ui.md](host-ui.md) §12). macOS shows its own microphone indicator for apkrund.

### 8.3 Acceptance

- Output: a 1 kHz tone and a sweep are heard on the Mac. The negotiated rate and format are logged, and the output latency target of §8.1 is measured.
- Microphone: with the setting on and macOS permission granted, a recording follows a test signal. With the setting off for the package (and on for another), the recording is silent. With macOS permission denied, the app page shows how to allow it.

---

## 9. Locale, time zone, and time

| Item | Host source | Guest operation | When |
|---|---|---|---|
| Languages | `Locale.preferredLanguages` (BCP 47), with the region from `Locale.current.region` added to the first language when it has none | `SetLocale(bcp47 list, up to 8)` | post-boot setup, reconnect, `NSLocale.currentLocaleDidChangeNotification` |
| Time zone | `TimeZone.current.identifier` (IANA) | `SetTimeZone(tz_id)` | post-boot, reconnect, `NSSystemTimeZoneDidChange` |
| 12/24-hour clock | `DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)` contains `a` → 12-hour | `SetClockFormat(TWELVE / TWENTY_FOUR)` (`Settings.System.TIME_12_24`) | post-boot, reconnect, `NSLocale.currentLocaleDidChangeNotification` |
| Wall clock | host `Date()` | `SyncTime(unix_time_ms)` | post-boot, after resume and wake ([runtime-daemon.md](runtime-daemon.md) §5.3, §6), every 30 min while `ready`, and after `NSSystemClockDidChange` |

- Only changes are pushed. The agent compares with the current Android value and does nothing when they are equal, because a locale change restarts activities that do not handle configuration changes. A locale push never happens on the launch path.
- **Locale mapping.** macOS and Android both use BCP 47 tags, so tags are passed through. Script subtags (`zh-Hans`, `zh-Hant`, `sr-Latn`) are kept. Android app labels follow the new locale. That can change display names ([package-store.md](package-store.md) §10.3) and gives wrappers a `.displayName` refresh reason ([wrapper.md](wrapper.md) §9.1).
- **Time zone.** If Android's tzdata does not know the ID (a zone newer than the image), the agent answers `NOT_FOUND`. The host then sends the fixed offset as `Etc/GMT∓h` (note the inverted sign in `Etc/` zones) and logs a health warning. Image updates bring new tzdata ([runtime-maintenance.md](runtime-maintenance.md)).
- **Clock.** On the custom image the product sets `Settings.Global.AUTO_TIME = 0` and `AUTO_TIME_ZONE = 0`, so the host is the only time source ([android-image.md](android-image.md) §11.2). The agent applies `SyncTime` when the difference is more than 500 ms, adding half of the last `Ping` round-trip time. Target: the guest wall clock within 1 s of the host, and within 2 s after wake ([runtime-daemon.md](runtime-daemon.md) §6). On the stock image `SyncTime` answers `UNSUPPORTED`, because the shell uid cannot set the time. Development builds then set the clock over ADB on the userdebug image (`adb root`, then `adb shell date -u @<seconds>`). Release builds never use ADB for this ([runtime-daemon.md](runtime-daemon.md) §6). Whether `cmd time_detector` works as the shell uid without root is not yet verified (§16).

Acceptance: change the macOS language order, region, time zone, and 24-hour setting while a fixture app runs. Android's settings follow within 2 s, and the app shows the new time format ([guest-protocol.md](guest-protocol.md) §7.2 for `GetSnapshot`). After 2 minutes of sleep and wake, the guest clock is within 2 s of the host.

---

## 10. Not supported in v1

| Item | Status |
|---|---|
| Camera (FR-INT-10) | Could, 1.x. VZ has no camera device. It would need a host capture path and a guest camera HAL. Not designed (OQ-30) |
| File clipboard, folder drops, promised files | post-v1 |
| Media controls, Now Playing, media keys | post-v1 (OQ-30) |
| Mac → Android links, custom URL schemes on the Mac | post-v1 (OQ-23) |
| Notification replies (remote input), images in notifications | post-v1 (OQ-30) |
| Location, sensors, Bluetooth, USB, printing | not planned for v1. Android sees no location provider and no sensors |
| Contacts, calendar, photos library integration | not planned |

---

## 11. Runtime API surface and CLI

Control-endpoint operations. The DTOs are in [runtime-api.md](../03-reference/runtime-api.md) §11.1:

| Operation | Behavior |
|---|---|
| `integrationStatus(packageID)` → `IntegrationStatus` | per integration: setting, effective decision, support on the running image, macOS permission (notifications of the wrapper, microphone of APKRun) |
| `sharedFolders()`, `addSharedFolder(bookmark, access)`, `removeSharedFolder(id)`, `setSharedFolderAccess(id, access)` | §6.4 roots. The GUI gets the bookmark from an open panel |
| `activeRecordings()` | §8.2, for the menu bar |

Notification operations ([runtime-api.md](../03-reference/runtime-api.md) §11.3):

| Endpoint | Operation | Behavior |
|---|---|---|
| `.wrapper` | `notificationRelay(background)` → stream | the relay of §5.3 |
| `.wrapper` | `notificationRelayResponse(RelayResponse)`, one-way | clicks, dismissals, and authorization changes (§5.3, §5.4) |
| `.control`, APKRun.app only | `hostNotifications(background)` → stream, `hostNotificationResponse`, one-way | `HostNotifier` asks APKRun.app to post (§5.3, [update-system.md](update-system.md) §9, [host-ui.md](host-ui.md) §11) |

Package settings are changed with the store's settings operations ([package-store.md](package-store.md) §11.1). Events on topic `integrations` (`IntegrationChange`, [runtime-api.md](../03-reference/runtime-api.md) §16.2): `statusChanged(PackageID)`, after which the client calls `integrationStatus`; `recordingChanged([PackageID])`; and `sharedFoldersChanged`.

CLI ([cli.md](cli.md)):

```text
apkrun settings <package> set integrations.<key> <value>     # the generic settings command
apkrun integrations status <package> [--json]
apkrun shared-folders list [--json] | add <path> [--read-write] | remove <path|id>
```

---

## 12. Errors

```swift
public enum IntegrationFailure: APKRunError {
    case disabled(IntegrationKind, IntegrationDenial)
    case notSupportedOnImage(capability: String)
    case guestUnavailable                          // agent not connected; the operation is not queued
    case clipboardTooLarge(bytes: Int, limit: Int)
    case linkRejected(LinkRejection)               // .scheme, .tooLong, .notFocused, .rateLimited
    case tooManyFiles(count: Int, limit: Int)
    case fileTooLarge(name: String, bytes: Int64)
    case transferFailed(String)                    // bulk abort, hash mismatch
    case folderUnavailable(FolderProblem)          // .missing, .privacyDenied, .offline
    case pathRejected(PathProblem)                 // .outsideRoot, .hidden, .notRegularFile
    case folderRefused(FolderRefusal)              // addSharedFolder: .volumeRoot, .homeFolder, .insideLibrary, .hidden, .limitReached (§6.4)
    case readOnly
    case notificationPermissionDenied
    case microphonePermissionDenied
    case microphoneNeedsRestart
    case promptTimedOut
    // health findings (§13), never thrown
    case notificationAccessMissing                 // integrations.notificationListener: the listener grant is missing
    case browserRoleMissing                        // integrations.browserRole: the redirect activity does not hold the browser role
    case timeSyncFailed                            // integrations.time: the last SyncTime failed, or the time zone fell back to a fixed offset
}
```

Codes, messages, and remediations are in [error-catalog.md](../03-reference/error-catalog.md). Guest-side failures arrive as `GuestError` and are mapped at the channel ([guest-protocol.md](guest-protocol.md) §12.3).

---

## 13. Logging, metrics, health

- Subsystem `io.apkrun.integration`, categories `clipboard`, `notifications`, `links`, `files`, `audio`, `locale`. The window process logs its adapters under `io.apkrun.wrapper`, category `integration`.
- Never logged at any level: clipboard content, notification title and text, file names and contents, and full URLs (only the scheme and the registrable domain, at debug level). Package IDs, sizes, counts, digests (truncated to 8 hex), and decisions are logged. The redaction rules are in [diagnostics.md](diagnostics.md) §6.
- Metrics (`PerfMarker`, [diagnostics.md](diagnostics.md) §4): `CLIPBOARD_PUSH` (⌘V to ack), `NOTIFICATION_DELIVERED` (guest post to Mac post), `FILE_TRANSFER` (bytes, duration).
- Health checks ([diagnostics.md](diagnostics.md) §7):

| Check | Warning when |
|---|---|
| `integrations.capabilities` | an integration is on for some package but its capability is missing on the running image |
| `integrations.notificationListener` | the listener grant is missing (`HealthWarning` from the agent): `integration.notificationAccessMissing` |
| `integrations.browserRole` | the redirect activity does not hold the browser role: `integration.browserRoleMissing` |
| `integrations.sharedFolders` | a root is missing or its access is denied |
| `integrations.microphone` | a package has the microphone on, but macOS permission for APKRun is denied, or the input stream is not attached (restart pending) |
| `integrations.time` | the last `SyncTime` failed, or the time zone fell back to a fixed offset: `integration.timeSyncFailed` |

---

## 15. Tests

| Tier | What | Where |
|---|---|---|
| T0 | `IntegrationPolicy` decision table: global × package × focus × image support | `Packages/IntegrationCore/Tests/IntegrationCoreTests/` |
| T0 | Clipboard loop prevention with a simulated pasteboard and agent: both markers, digests, two windows | same |
| T0 | Notification filters and mapping (§5.1, §5.2), identifier stability, category LRU | same |
| T0 | URL validation and rate limits (§7.2): IDN hosts, `javascript:`, `intent:`, over-long URLs | same |
| T0 | `SharedFolderService` path resolution: `..`, absolute paths, symlink escapes, hidden files, packages, read-only writes | same |
| T0 | Locale tag and time zone fallback mapping (`Etc/GMT` sign) | same |
| T1 | Guest Agent Kotlin tests (Robolectric): clipboard echo suppression, notification filter, `MacFilesProvider` access checks with a fake host | Guest Agent test sources |
| T2 | Sections 4.5, 5.5, 6.5, 7.3, 8.3, and 9 against a real runtime, on the custom image. The clipboard and time sync checks run first on the stock image with the shell-mode agent | `Tests/IntegrationTests/DesktopIntegrationTests/` |
| T2 | Protocol fuzzing of the host operations (§6.4) from a malicious agent build | `Tests/IntegrationTests/` |
| T3 | Audio loopback and microphone with a virtual audio device (nightly where the runner has one; otherwise manual) | `Tests/AcceptanceTests/AudioLoopback/` |

Fixtures are `HelloClipboard`, `HelloNotification`, `HelloLinks`, `HelloFiles`, `HelloFilesPeer`, and `HelloAudio`. Their packages are `io.apkrun.fixture.<lowercase name>`. Their specification is in [test-strategy.md](../04-plan/test-strategy.md) §4.2.

---

## 16. Open items

- R-21: whether reading the pasteboard on focus prompts on macOS 27 (§4.2, §4.5).
- R-22: macOS privacy prompts and their attribution for apkrund reading user-added folders (§6.4).
- R-19: background mode and notification permission across wrapper refreshes ([wrapper.md](wrapper.md) §5.8).
- OQ-29: whether the microphone prompt appears at VM start or at first capture (§8.2).
- OQ-30: post-v1 candidates: media controls and Now Playing (`MediaSession`), notification replies, Mac → Android links, per-app languages (`LocaleManager`), dark mode sync, per-app mute, camera.
- To verify, with no OQ or R yet: the background clipboard read as the shell uid on the stock image (§2.4, §4.2); whether `cmd time_detector` works as the shell uid without root (§9); the background-activity-start mode for notification clicks, API 34+ (§5.4); whether the microphone usage text shows in Japanese (§8.2).
