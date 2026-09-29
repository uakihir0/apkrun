# Desktop Integration

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../01-architecture/security-model.md](../01-architecture/security-model.md) §6, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3, [guest-protocol.md](guest-protocol.md) §7–§10, [guest-components.md](guest-components.md) §5, §11, [input.md](input.md) §6, [wrapper.md](wrapper.md) §5.8, [vm.md](vm.md) §11, [runtime-daemon.md](runtime-daemon.md) §4.2, §5, §6, [package-store.md](package-store.md) §2.4 |
| Tasks | #053 (M4), #054, #080, #081, #082, #085 (M9), #083, #084 (M12) |

Desktop integration connects Android apps to the Mac: the clipboard, notifications, files, links, sound, the microphone, and the system language and clock. Every integration is a narrow, policy-checked path. Android apps are untrusted code (NFR-SEC-01), so each path moves only what the user asked for, only for the package it belongs to, and never logs content.

---

## 1. Responsibilities

| Component | Module / process | Responsibility |
|---|---|---|
| `IntegrationPolicy` | IntegrationCore, apkrund | decides every integration request from the package settings, the global switches, and the session state (§2.3) |
| `ClipboardCoordinator` | IntegrationCore | loop prevention, size rules, which window is allowed to exchange (§4) |
| `NotificationCoordinator` | IntegrationCore | forwarding allowlist, routing to the wrapper or APKRun, activation, badges (§5) |
| `FileTransferService` | IntegrationCore | drag and drop into Android, "Save to Mac" out of Android (§6.2, §6.3) |
| `SharedFolderService` | IntegrationCore | serves the Mac folder roots to the Android document provider (§6.4) |
| `LinkForwarder` | IntegrationCore | Android links → default Mac browser or mail app (§7) |
| `AudioPolicy` | IntegrationCore + RuntimeCore | sound device configuration, microphone gating (§8) |
| `LocaleTimeSync` | IntegrationCore | language list, time zone, 12/24-hour format, wall clock (§9) |
| `IntegrationChannel` | protocol in IntegrationCore, implemented by RuntimeCore | the Guest Agent operations and events of [guest-protocol.md](guest-protocol.md) §7–§8 (capabilities `clipboard.*`, `notifications.v1`, `url.v1`, `files.v1`, `locale.v1`) |
| Window-side adapters | `APKRunLauncher` target (wrapper process) | `PasteboardAdapter` (NSPasteboard), `NotificationPoster` (UserNotifications), `DropTarget` and save panels, link prompts. They do I/O with AppKit and carry no policy |

**Split between apkrund and the window process.** Decisions live in IntegrationCore in apkrund. AppKit-facing work runs in the process that owns the app's window: the wrapper, or the generic launcher (#068). There are three reasons:

1. macOS attributes notifications to the posting process. Only the wrapper can post as "Discord" (§5).
2. macOS 26 and later can ask the user before a process reads the pasteboard without a paste command ("Paste from Other Apps" in Privacy & Security). A read that the frontmost app does for the user's ⌘V is not asked about. A background LaunchAgent that reads the pasteboard would be. The exact rules on macOS 27 are verified in #053 (R-21).
3. The window process can use the file access the user gives it with drag and drop or a Save panel. apkrund, a LaunchAgent, may be denied access to protected folders by macOS privacy controls (TCC) and never needs it: the window process sends open file handles (§6).

---

## 2. Policy and settings

### 2.1 Per-package settings (`integrations.*`)

Stored in the package settings ([package-store.md](package-store.md) §2.4). The reference with the JSON schema is [../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §3.

| Key | Values | Default | Meaning |
|---|---|---|---|
| `integrations.clipboard` | `true`, `false` | `true` | text (and, from #080, images and HTML) between the Mac pasteboard and Android, only while the app's window is key (§4) |
| `integrations.notifications` | `true`, `false` | `true` | Android notifications of this package appear as Mac notifications (§5) |
| `integrations.links` | `ask`, `mac`, `android` | `ask` | where `http`, `https`, and `mailto` links opened by the app go (§7) |
| `integrations.files` | `true`, `false` | `true` | drag and drop into the app and "Save to Mac" from the app. Always one user action per transfer (§6.2, §6.3) |
| `integrations.sharedFolders` | `off`, `readOnly`, `readWrite` | `off` | the app may open files in the Mac folders of §6.4 through the Android file picker |
| `integrations.microphone` | `true`, `false` | `false` | the app may record from the Mac microphone (§8.2) |

The `integration` object in `wrapper.json` carries the same initial values without the `integrations.` prefix ([wrapper.md](wrapper.md) §3). Its `"files": true` value maps to `integrations.files`.

### 2.2 Global settings

In APKRun Settings → Privacy ([host-ui.md](host-ui.md)), stored in the app configuration ([../03-reference/configuration.md](../03-reference/configuration.md)):

| Key | Default | Meaning |
|---|---|---|
| `integrations.enabled.<name>` for `clipboard`, `notifications`, `links`, `files`, `sharedFolders`, `microphone` | `true` | a global switch. `false` turns the integration off for every package without changing their settings |
| `integrations.defaults.<key>` | the defaults of §2.1 | the settings a newly installed package gets. `wrapper.json` values win for packages installed from a portable wrapper, but a wrapper made on another Mac can only lower them ([../03-reference/configuration.md](../03-reference/configuration.md) §3.3). A value equal to the built-in default is not written to the package, so a compatibility recommendation can still apply ([diagnostics.md](diagnostics.md) §10.3, [../03-reference/configuration.md](../03-reference/configuration.md) §3.3) |
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

- `IntegrationContext` carries what the rule needs: whether a session of the package exists, whether its window is key (`focusChanged` on the session channel), and the time since the last user input in that window.
- Settings are read through `PackageStore.settings(for:)` on every evaluation. There is no cache that outlives a `settingsChanged` event ([package-store.md](package-store.md) §2.4).
- A denial is counted per kind and reason (`integration.denied{kind, reason}`) and logged at debug level with the package ID only.
- Packages that are not managed by APKRun (for example preinstalled system apps) use the defaults of §2.1, except `notifications`, which is off for them. They have no settings UI, so their notifications are never forwarded.

### 2.4 Support per image

| Integration | Stock image (development, M3–M4) | Custom image (M5+) |
|---|---|---|
| Clipboard | text, *verify* background read as the shell uid in #053 ([guest-components.md](guest-components.md) §5) | yes |
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

The Guest Agent components are `ClipboardBridge`, `NotificationBridge`, `UrlRedirect`, `FilesBridge` with `MacFilesProvider`, and `LocaleTimeService` ([guest-components.md](guest-components.md) §6.1, §11). Their operations and events are in [guest-protocol.md](guest-protocol.md) §7.1, §7.5, §8.1, and §8.4. Large payloads (images, files) use the bulk stream (6102, [guest-protocol.md](guest-protocol.md) §10).

### 3.2 Configuration push

RuntimeCore pushes the host-owned configuration after every handshake with the Guest Agent (post-boot setup and reconnect, [runtime-daemon.md](runtime-daemon.md) §3.4, §4.2) and again when a relevant setting changes:

| Operation | Content | Changed by |
|---|---|---|
| `SetNotificationForwarding(packages)` | packages with `integrations.notifications` in effect (§5.1) | settings, install, uninstall |
| `SetUrlRedirect(enabled, excluded_packages)` | `enabled` = global `links` switch; `excluded_packages` = packages with `links = android` or `links` off (§7.1) | settings |
| `SetSharedFolderAccess(entries)` | per package: `off`, `readOnly`, `readWrite`; and the roots (§6.4) | settings, root list |
| `SetMicrophoneAccess(packages)` | packages with `integrations.microphone` in effect (§8.2) | settings, install, uninstall |
| `SetLocale`, `SetTimeZone`, `SetClockFormat`, `SyncTime` | §9 | host notifications |

### 3.3 Session channel additions

The window process and apkrund exchange integration messages on the session channel ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3). Background-mode wrappers use the notification relay of §5.3 on the same `.wrapper` endpoint.

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

`ClipItem`, `ImportFileInfo`, `ExportOffer`, and `LinkPrompt` are RuntimeAPI DTOs. Their fields, and the request and event forms of this list, are in [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §6.3 and §11.2. File handles cross XPC as `NSFileHandle` (secure coding), the same way IOSurfaces do. A `ClipItem` image is PNG bytes as `Data` inside the message, at most 16 MiB, so a clip fits the 32 MiB XPC message limit ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §4.10). Only the host ↔ guest hop uses a bulk transfer (§4.4).

---

## 4. Clipboard (#053 text, #080 images and HTML; FR-INT-01, FR-INT-02)

### 4.1 Model

The clipboard path is `NSPasteboard ↔ apkrund ↔ Guest Agent ↔ ClipboardManager`. The rules:

- **No background sync.** The Mac pasteboard and the Android clipboard are exchanged only while a window of a package with `integrations.clipboard` is key (security-model §6). Android has one clipboard for all apps, so an exchange made for one app is visible to every Android app that reads the clipboard afterwards. This is the same as on a phone, and the settings UI says so.
- **Mac → Android** happens at a paste (⌘V or Edit → Paste) and when the window becomes key (§4.2).
- **Android → Mac** happens when an Android app copies while its window is key (§4.3).
- Content is never logged, never stored on disk by APKRun (except as a bulk-transfer temp file for images, deleted after use), and never included in diagnostics (NFR-SEC-05).

### 4.2 Mac → Android

```text
trigger (in the window process):
  a) ⌘V / Edit → Paste in editor mode (input.md §6)
  b) window becomes key, and NSPasteboard.general.changeCount ≠ the last count this adapter pushed or wrote,
     and reading does not require a user prompt (R-21)
PasteboardAdapter reads, in order: public.utf8-plain-text, (#080) public.html, public.png / public.tiff
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
- A push on focus (case b) makes Android's own Paste command (long press → Paste) work after copying on the Mac. If macOS would ask the user for the read (R-21), case b is skipped. Then only ⌘V brings Mac content into Android, and Android's own Paste command pastes the last exchanged content.

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

| Type | Mac | Android | Limit | Task |
|---|---|---|---|---|
| Plain text | `public.utf8-plain-text` | `ClipData.newPlainText` | 1 MiB UTF-8. Longer text is truncated at a character boundary, and the `truncated` flag makes the window show "Only the first 1 MB was copied." | #053 |
| HTML | `public.html` | `ClipData.newHtmlText` (with the plain text) | 1 MiB | #080 |
| Image | `public.png`; `public.tiff` converted to PNG | a `content://` URI from the agent's `FileProvider` with a PNG, `ClipDescription` MIME `image/png` | 16 MiB encoded, 8192 px per side. Over the bulk stream | #080 |
| Files, URLs as files, rich text (RTF) | — | — | Not exchanged in v1. File picking and saving are separate features; RTF falls back to plain text. | — |

Loop prevention uses three independent signals: the `origin` and `seq` of `ClipData`, the content digest (SHA-256 over the normalized text or image bytes) on the host, and the `io.apkrun.clip-origin` marker on the Mac pasteboard. Two windows of different Android apps therefore never bounce a clip between them.

### 4.5 Verification (#053)

`HelloClipboard` (`io.apkrun.fixture.helloclipboard`) has a text field, a Copy button that sets a known string, and a view that shows the current primary clip.

- Copy "héllo 😀" in TextEdit, focus HelloClipboard, press ⌘V: the text appears in the field. Press the fixture's Copy, switch to TextEdit, ⌘V: the fixture's string appears.
- With `integrations.clipboard = false`, neither direction works, and the policy counter shows the denial.
- A 5-minute loop test with two fixture windows (HelloClipboard and HelloText) and a script that alternates copies produces no extra pasteboard changes (changeCount grows by exactly the number of user copies).
- ⌘V latency (key down → text visible in Android) p95 ≤ 150 ms for 64 KiB of text, measured with the #070 harness.
- R-21 is recorded: whether reading on focus prompts on macOS 27, and which API tells the adapter in advance.

---

## 5. Notifications (#054, FR-INT-03)

### 5.1 Guest side

- `ApkRunNotificationListener`, a `NotificationListenerService` in the Guest Agent. The agent grants itself listener access at start (`setNotificationListenerAccessGranted`, [guest-components.md](guest-components.md) §5). If access is lost, it sends `HealthWarning(NOTIFICATION_LISTENER_DISABLED)`.
- Only packages in the forwarding allowlist (`SetNotificationForwarding`) are forwarded. Everything else never leaves the guest.
- Filters in the agent, before anything is sent:

| Android notification | Forwarded |
|---|---|
| `FLAG_GROUP_SUMMARY` | no. The Mac groups by thread (§5.2) |
| ongoing (`FLAG_ONGOING_EVENT`), foreground-service, or `CATEGORY_TRANSPORT` (media controls) | no in v1. Media controls are post-v1 (§16) |
| importance `IMPORTANCE_MIN` or `IMPORTANCE_NONE`, or its channel is blocked | no |
| an update of a posted notification with `FLAG_ONLY_ALERT_ONCE` | yes, with `alert = false` |
| anything else | yes |

- Payload: `Notification` ([guest-protocol.md](guest-protocol.md) §8.4): key, package, title (≤ 256 characters), text (≤ 2048, the last `MessagingStyle` message when present, else `EXTRA_BIG_TEXT`, else `EXTRA_TEXT`), group key, alert, actions (titles only). No images, no remote input in v1.

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
- While the app's window is key, `userNotificationCenter(_:willPresent:)` returns `[.list, .sound]` for `DEFAULT` and `[.banner, .list, .sound]` for `HIGH`, which is close to Android's heads-up rule.
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

The notification relay on the `.wrapper` endpoint ([wrapper.md](wrapper.md) §12.1). The DTOs `RelayMessage`, `NotificationPayload`, and `RelayResponse` are in [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §11.3:

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

- **Reconnect.** After a reconnect, `SetNotificationForwarding` makes the agent re-send every active forwarded notification with `replay = true` ([guest-protocol.md](guest-protocol.md) §8.4). The coordinator rebuilds its key map and badge counts from them without new banners, and removes Mac notifications whose Android notification is gone (for example after a runtime restart).
- **Badge.** The Dock badge is the number of forwarded notifications that are still active in Android for the package (`NSApp.dockTile.badgeLabel` while running, `content.badge` when posting). It is cleared when the count reaches 0.
- **Authorization.** The launcher asks for notification permission (`.alert`, `.sound`, `.badge`) at the first foreground session start of a package with `integrations.notifications`, not at install. If a background start finds the status `notDetermined`, it asks then (macOS shows the request as a banner). `denied` is reported to apkrund. The app page then says "Notifications for ‹App› are turned off in System Settings" with a button that opens the Notifications pane. The error is `integration.notificationPermissionDenied`. Its remediation action is `openNotificationSettings` ([diagnostics.md](diagnostics.md) §2.3).
- **Runtime state.** Android can only post while the runtime runs. A package closed with `window.closeBehavior = stop` posts nothing afterwards, and a suspended VM posts nothing until it resumes ([runtime-daemon.md](runtime-daemon.md) §5.1). The notifications setting shows this next to the switch, with a link to "Keep running in the background".
- **Push services.** The runtime has no Google Play services (scope.md §3), so apps that rely only on Firebase Cloud Messaging get no push messages while they are not running. Apps with their own connection (or UnifiedPush) work while kept running. [../04-plan/traceability.md](../04-plan/traceability.md) records this limit next to FR-INT-03.

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
  (and the background-activity-start mode that lets the agent's privilege apply, API 34+; verify in #054)
  no content intent → LaunchApplication(package, display_id) instead
```

- A click on a Mac notification whose Android notification no longer exists (the runtime restarted, or the app removed it) opens the app normally.
- For notifications posted by APKRun (no wrapper), a click runs `launch(packageID)` with the generic launcher ([runtime-daemon.md](runtime-daemon.md) §7.2) and then the same `ActivateNotification`.

### 5.5 Verification (#054)

`HelloNotification` (`io.apkrun.fixture.hellonotification`) posts, on buttons and on a timer: a plain notification, one with two actions, an update of the first one, a `LOW` notification, an ongoing one, and a grouped series. Its launch activity shows which intent opened it.

- Each notification appears as a notification of `HelloNotification.app` with the wrapper icon. The ongoing one and the group summary do not appear. The `LOW` one is silent.
- A click with the app closed (runtime running, `keepRunning`) opens the window and shows the notification's content intent. A click with the window open brings it to the front. Action buttons arrive as the right action intent.
- Dismissing on the Mac removes the notification on Android (the fixture lists its active notifications). Removing it on Android removes it on the Mac.
- With `integrations.notifications = false`, nothing leaves the guest (the agent's forwarded counter stays 0).
- Latency from Android `notify()` to the Mac banner: p50 ≤ 1 s with the wrapper running, ≤ 3 s with a background start.
- R-19 ([wrapper.md](wrapper.md) §5.8): no Dock tile flash in background mode, and the permission survives a wrapper refresh.

---

## 6. Files (#082, FR-INT-05, FR-INT-06)

### 6.1 Principles

- Android never sees the home folder. It sees only (a) single files that the user drops or saves, and (b) the folders of §6.4, only for packages with `integrations.sharedFolders`, only through Android's file picker, read-only by default (NFR-SEC-02).
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

- Android has no API to inject a drag from outside Android, so a drop does not arrive as a `DragEvent` at the drop position. It arrives as a share to the app, which is how most apps accept files. Limitation recorded in [input.md](input.md) §10.
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
- Several items open one panel per item. A folder chooser for many items is post-v1.

### 6.4 Shared folders: the Mac document provider

**Roots.** `~/Library/Application Support/APKRun/Shared/` (created at first run, [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §1) and any folders the user adds in Settings → Files. Each root has its own maximum access (`readOnly` or `readWrite`). The effective access for a package is the lower of the root's and `integrations.sharedFolders`.

**Refused roots.** `addSharedFolder` refuses, with `folderRefused` (§12), a volume root (`/`, `/Volumes/<name>`), the home folder itself, `~/Library` and any folder inside it (the Shared folder is built in and is not added), a hidden folder or any folder inside one (such as `~/.ssh`), and a 33rd added folder (at most 32). A subfolder of the home folder, such as `~/Documents` or `~/Downloads`, can be added because the user picks it; nothing is shared without that choice (NFR-SEC-02).

**Guest side.** `MacFilesProvider`, a `DocumentsProvider` in the Guest Agent (authority `io.apkrun.guest.macfiles`), shows one root per Mac folder in the Android file picker. Android apps reach files only through the picker (`ACTION_OPEN_DOCUMENT`, `ACTION_OPEN_DOCUMENT_TREE`, `ACTION_CREATE_DOCUMENT`) and the URI permissions that the picker grants.

- `openDocument` and every write check `getCallingPackage()` against the access list from `SetSharedFolderAccess`. A package without access gets `SecurityException("Blocked by APKRun settings")`. Browsing in the picker (caller `com.android.documentsui`) lists names only.
- File contents are served with `StorageManager.openProxyFileDescriptor`, so Android apps get a seekable file descriptor whose reads and writes become host requests. Nothing is copied into the guest.

**Host side.** The agent calls the host operations of [guest-protocol.md](guest-protocol.md) §7.5 (`HostListRoots`, `HostQueryChildren`, `HostStat`, `HostOpenFile`, `HostReadRange`, `HostWriteRange`, `HostCloseFile`, `HostCreateDocument`, `HostDeleteDocument`, `HostRenameDocument`). Every request carries the calling package. `SharedFolderService` checks, for each request:

1. the package's effective access for the root (`readWrite` for writes);
2. the path: relative to the root, no `..` component, no absolute path. It is resolved with `openat` from the root's directory descriptor, with `O_NOFOLLOW` on each component, so symlinks cannot leave the root;
3. only regular files and directories. Hidden files (a leading `.`) and packages (`.app`, `.photoslibrary`) are not listed and cannot be opened;
4. limits: 4096 entries per listing page, 1 MiB per read or write, 64 open handles per package, handles closed when the runtime stops.

- Files created or written by Android get `com.apple.quarantine` (§6.1).
- Folders that the user adds inside Desktop, Documents, Downloads, iCloud Drive, or on network or removable volumes are protected by macOS privacy controls. apkrund asks for access on first use (macOS shows the prompt for APKRun). If access is denied, the root is shown as unavailable in the picker and in Settings with the steps to allow it. #082 verifies the prompt and its attribution (R-22).
- The root list and each root's access are stored in the app configuration with bookmarks (`sharedFolders.roots`), so renamed or moved folders are followed.

### 6.5 Verification (#082)

`HelloFiles` (`io.apkrun.fixture.hellofiles`) accepts shares (text, images, any file), opens the system picker (open, open tree, create), shows file names, sizes, and SHA-256, and can share a generated file.

- Drop three files (one 1.5 GiB) on the window: the fixture receives them with the right hashes. With `integrations.files = false`, the drop is refused.
- "Save to Mac" from the fixture writes the file where the Save panel said, with the right hash and a quarantine attribute.
- With `sharedFolders = readOnly`, the fixture can pick and read files in the Shared folder, cannot create or modify them, and a symlink in the folder that points outside the root cannot be opened. With `off`, opening a previously granted URI fails.
- A second fixture package without access (HelloFilesPeer) cannot open a URI that was granted to HelloFiles and then passed to it.
- Throughput: reading a 1 GiB file through the provider ≥ 200 MB/s (provisional, measured in #082).

---

## 7. Links (#081, FR-INT-04)

### 7.1 Guest side

- `UrlRedirectActivity` in the Guest Agent holds the browser role (`RoleManager` `ROLE_BROWSER`, [guest-components.md](guest-components.md) §5) and handles `ACTION_VIEW` for `http` and `https`, and `ACTION_SENDTO` / `ACTION_VIEW` for `mailto`.
- Android's own resolution runs first. A link with a verified Android App Link for an installed app opens that app, inside Android, as on a phone. Only links that would go to a browser reach the redirect activity.
- Custom Tabs (`CustomTabsIntent`) are `ACTION_VIEW` intents with extras and are handled the same way.
- The activity sends `OpenUrlOnHost(request_id, url, source_package, display_id)` and keeps the original intent for 60 s. For packages in `excluded_packages`, it passes the intent to the in-Android browser directly and sends nothing.
- The in-Android browser is AOSP `Browser2` (a WebView browser). Whether the product includes it is verified in #081. If it does not, the product adds it ([android-image.md](android-image.md) §11.2). Without one, "Keep in Android" is not offered.

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

- `WorkspaceOpener` is a protocol of IntegrationCore. Its only implementation is the `NSWorkspace` adapter in RuntimeHost, which also opens wrappers for `launch` and background starts ([runtime-daemon.md](runtime-daemon.md) §1). IntegrationCore itself does not use AppKit ([../01-architecture/modules.md](../01-architecture/modules.md) §2).

- The prompt shows the host in Unicode, with the registrable domain in bold. It never shows the path or query, which can contain tokens.
- **Sign-in flows.** Many apps open a browser for sign-in and expect a redirect back to a custom scheme (`myapp://callback`). A Mac browser cannot deliver that redirect to Android. "Keep in Android" exists for these apps. The link prompt has a "Signing in? Keep links from ‹App› in Android" hint when the URL path contains `oauth`, `authorize`, or `login`. Mac-side scheme handling is post-v1 ([wrapper.md](wrapper.md) §2.1).
- Mac → Android links (opening an `https` link on the Mac in an Android app) are post-v1.

### 7.3 Verification (#081)

`HelloLinks` (`io.apkrun.fixture.hellolinks`) opens an `https` link, a `mailto` link, a Custom Tab, a `javascript:` URL, an `intent:` URL, and a link while in the background (from a timer after its window lost focus).

- With `ask`, the first link shows the prompt. "Open in Browser" with Remember opens it in the default browser, and later links open without a prompt. "Keep in Android" opens the in-Android browser on the app's display.
- `mailto` opens the default Mac mail app. `javascript:` and `intent:` are dropped. The background link is dropped.
- With the global links switch off, all links stay in Android.

---

## 8. Audio and microphone (#083, #084, FR-INT-07, FR-INT-08)

### 8.1 Output (#083)

- One virtio-snd device (`VZVirtioSoundDeviceConfiguration`) with one output stream to `VZHostAudioOutputStreamSink` ([vm.md](vm.md) §11). The guest uses the goldfish audio HAL on the virtio-snd card ([android-image.md](android-image.md) §7.5). macOS plays it on the current default output device and follows device changes.
- All Android apps are mixed by Android into this one stream. Per-app volume is Android's (the app's media volume). The host has one volume: the macOS output volume. A mute toggle per app is post-v1.
- `audio.output = false` leaves the device out of the VM. It takes effect at the next runtime start, and Settings offers **Restart Android Now**.
- macOS shows apkrund as the process that plays audio. Now Playing and media keys are post-v1 (§16).
- Latency, underruns, and the negotiated format are measured in #083: target output latency ≤ 120 ms (provisional), no underrun in a 10-minute playback with the VM otherwise idle.

### 8.2 Microphone (#084)

- The input stream (`VZHostAudioInputStreamSource`) is attached only while at least one package has the microphone integration in effect. The VM configuration is fixed at start, so turning it on for the first package, or off for the last one, needs a runtime restart ([vm.md](vm.md) §11). The settings UI says so.
- **macOS permission.** apkrund is the process that captures. It embeds an Info.plist (`__TEXT,__info_plist`) with `NSMicrophoneUsageDescription`, and macOS asks once, for APKRun ([vm.md](vm.md) §3 rule). Wrappers have no usage description ([wrapper.md](wrapper.md) §2.1). Whether the prompt appears at VM start or at the first capture is verified in #084 (the open question of vm.md §11).
- **Per-package gating inside Android.** The host cannot tell which Android app reads the virtio-snd input. The Guest Agent enforces the setting with app ops: `OP_RECORD_AUDIO` is `MODE_IGNORED` for every package that is not in `SetMicrophoneAccess` (such apps record silence, the documented app-ops behavior), and `MODE_ALLOWED` or the default for listed ones. Android's own runtime permission dialog for `RECORD_AUDIO` still appears in the app's window.
- The Guest Agent reports active recordings (`AudioManager.getActiveRecordingConfigurations`) as events. The menu bar shows "‹App› is using the microphone" ([host-ui.md](host-ui.md)). macOS shows its own microphone indicator for apkrund.

### 8.3 Verification

- #083: `HelloAudio` (`io.apkrun.fixture.helloaudio`) plays a 1 kHz tone and a sweep. The tone is heard on the Mac (captured through a loopback device in CI where available, otherwise a manual check), the negotiated rate is logged, and the latency is measured with the fixture's click track.
- #084: `HelloAudio` records 5 s and shows the level. With the setting on and macOS permission granted, the level follows a test signal. With the setting off for the package (and on for another), the recording is silent. With macOS permission denied, the app page shows how to allow it.

---

## 9. Locale, time zone, and time (#085, FR-INT-09; time sync from #069)

| Item | Host source | Guest operation | When |
|---|---|---|---|
| Languages | `Locale.preferredLanguages` (BCP 47), with the region from `Locale.current.region` added to the first language when it has none | `SetLocale(bcp47 list, up to 8)` | post-boot setup, reconnect, `NSLocale.currentLocaleDidChangeNotification` |
| Time zone | `TimeZone.current.identifier` (IANA) | `SetTimeZone(tz_id)` | post-boot, reconnect, `NSSystemTimeZoneDidChange` |
| 12/24-hour clock | `DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)` contains `a` → 12-hour | `SetClockFormat(TWELVE / TWENTY_FOUR)` (`Settings.System.TIME_12_24`) | post-boot, reconnect, `NSLocale.currentLocaleDidChangeNotification` |
| Wall clock | host `Date()` | `SyncTime(unix_time_ms)` | post-boot, after resume and wake ([runtime-daemon.md](runtime-daemon.md) §5.3, §6), every 30 min while `ready`, and after `NSSystemClockDidChange` |

- Only changes are pushed. The agent compares with the current Android value and does nothing when they are equal, because a locale change restarts activities that do not handle configuration changes. A locale push never happens on the launch path.
- **Locale mapping.** macOS and Android both use BCP 47 tags, so tags are passed through. Script subtags (`zh-Hans`, `zh-Hant`, `sr-Latn`) are kept. Android matches unsupported regions to its nearest resources. Android app labels follow the new locale, which can change display names ([package-store.md](package-store.md) §10.3) and give wrappers a `.displayName` refresh reason ([wrapper.md](wrapper.md) §9.1).
- **Time zone.** If Android's tzdata does not know the ID (a zone newer than the image), the agent answers `NOT_FOUND`, and the host sends the fixed offset as `Etc/GMT∓h` (note the inverted sign in `Etc/` zones) and logs a health warning. Image updates bring new tzdata ([runtime-maintenance.md](runtime-maintenance.md)).
- **Clock.** On the custom image the product sets `Settings.Global.AUTO_TIME = 0` and `AUTO_TIME_ZONE = 0`, so the host is the only time source ([android-image.md](android-image.md) §11.2). The agent applies `SyncTime` when the difference is more than 500 ms, adding half of the last `Ping` round-trip time. Target: guest wall clock within 1 s of the host; acceptance within 2 s after wake ([runtime-daemon.md](runtime-daemon.md) §6). On the stock image `SyncTime` answers `UNSUPPORTED` (the shell uid cannot set the time). Development builds then set the clock over ADB on the userdebug image (`adb root`, then `adb shell date -u @<seconds>`), which is how #069 meets its acceptance in M4. Whether `cmd time_detector` works as the shell uid without root is *verify* in #069. Release builds never use ADB for this ([runtime-daemon.md](runtime-daemon.md) §6).
- Per-app languages (Android 13 `LocaleManager`) and Mac appearance (dark mode) sync are post-v1 candidates (§16).

**Verification (#085).** Change the macOS language order, the region, the time zone, and the 24-hour setting while HelloText runs: Android's settings (`GetSnapshot` locale and time fields, [guest-protocol.md](guest-protocol.md) §7.2) follow within 2 s, and HelloText shows the new time format. Sleep 2 minutes and wake: the guest clock is within 2 s of the host.

---

## 10. Not supported in v1

| Item | Status |
|---|---|
| Camera (FR-INT-10) | Could, 1.x. VZ has no camera device. It would need a host capture path and a guest camera HAL. Not designed |
| File clipboard, folder drops, promised files | post-v1 |
| Media controls, Now Playing, media keys | post-v1 (§16) |
| Mac → Android links, custom URL schemes on the Mac | post-v1 ([wrapper.md](wrapper.md) §2.1) |
| Notification replies (remote input), images in notifications | post-v1 |
| Location, sensors, Bluetooth, USB, printing | not planned for v1. Android sees no location provider and no sensors |
| Contacts, calendar, photos library integration | not planned |

---

## 11. Runtime API surface and CLI

Control-endpoint operations. The DTOs are in [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §11.1:

| Operation | Behavior |
|---|---|
| `integrationStatus(packageID)` → `IntegrationStatus` | per integration: setting, effective decision, support on the running image, macOS permission (notifications of the wrapper, microphone of APKRun) |
| `sharedFolders()`, `addSharedFolder(bookmark, access)`, `removeSharedFolder(id)`, `setSharedFolderAccess(id, access)` | §6.4 roots. The GUI gets the bookmark from an open panel |
| `activeRecordings()` | §8.2, for the menu bar |

Notification operations ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §11.3):

| Endpoint | Operation | Behavior | Task |
|---|---|---|---|
| `.wrapper` | `notificationRelay(background)` → stream | the relay of §5.3 | #054 |
| `.wrapper` | `notificationRelayResponse(RelayResponse)`, one-way | clicks, dismissals, and authorization changes (§5.3, §5.4) | #054 |
| `.control`, APKRun.app only | `hostNotifications(background)` → stream, `hostNotificationResponse`, one-way | `HostNotifier` asks APKRun.app to post (§5.3, [update-system.md](update-system.md) §9, [host-ui.md](host-ui.md) §11) | #037; Android app notifications #054 |

Package settings are changed with the store's settings operations ([package-store.md](package-store.md) §11.1). Events on topic `integrations` (`IntegrationChange`, [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §16.2): `statusChanged(PackageID)`, after which the client calls `integrationStatus`, `recordingChanged([PackageID])`, and `sharedFoldersChanged`.

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

Codes, messages, and remediations are in [../03-reference/error-catalog.md](../03-reference/error-catalog.md). Guest-side failures arrive as `GuestError` and are mapped at the channel ([guest-protocol.md](guest-protocol.md) §12.3).

---

## 13. Logging, metrics, health

- Subsystem `io.apkrun.integration`, categories `clipboard`, `notifications`, `links`, `files`, `audio`, `locale`. The window process logs its adapters under `io.apkrun.wrapper` category `integration`.
- Never logged at any level: clipboard content, notification title and text, file names and contents, full URLs (only the scheme and the registrable domain, at debug level). Package IDs, sizes, counts, digests (truncated to 8 hex), and decisions are logged. The redaction rules are in [diagnostics.md](diagnostics.md) §6.
- Metrics (DiagnosticsCore `PerfMarker`, [diagnostics.md](diagnostics.md) §4): `CLIPBOARD_PUSH` (⌘V to ack), `NOTIFICATION_DELIVERED` (guest post to Mac post), `FILE_TRANSFER` (bytes, duration).
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

## 14. Implementation steps

### #053 Clipboard, plain text (M4)

1. IntegrationCore skeleton: `IntegrationPolicy` (§2.3) with the settings of §2.1–§2.2, the `IntegrationChannel` protocol and its RuntimeCore implementation, the configuration push of §3.2 (the clipboard needs none).
2. `ClipboardCoordinator` (§4.2–§4.4, text only), the session channel additions `pushClipboard`, `clipboardWritten`, `clipboardFromGuest`, and `PasteboardAdapter` in the launcher target.
3. Guest: `ClipboardBridge` with loop prevention; the development-mode background-read *verify* item ([guest-components.md](guest-components.md) §5).
4. The ⌘V push-with-ack in InputCore/WindowingCore ([input.md](input.md) §6).
5. Acceptance: §4.5 (copy and paste work in both directions for plain text, no feedback loop).

### #054 Notifications (M9)

1. Guest: `ApkRunNotificationListener`, filters (§5.1), `SetNotificationForwarding`, `ActivateNotification` with the launch display, `DismissNotification`. The new `Notification` fields ([guest-protocol.md](guest-protocol.md) §8.4).
2. Host: `NotificationCoordinator` routing (§5.3) with the background start and queue, the notification relay on the `.wrapper` endpoint, `NotificationPoster` in the launcher (mapping §5.2, categories, badge, authorization), and the HostNotifier path for packages without a wrapper.
3. Verify R-19 first ([wrapper.md](wrapper.md) §5.8).
4. Acceptance: §5.5 (HelloNotification produces a native Mac notification whose click returns the user to the Android app).

### #080 Image and HTML clipboard (M9)

1. HTML and PNG types (§4.4) over the bulk stream, the agent's `FileProvider` for image clips, TIFF → PNG on the host.
2. Acceptance: copy a screenshot on the Mac (⌘⌃⇧4) and paste it into HelloClipboard's image view; copy an image in the fixture and paste it into Preview (File → New from Clipboard). HTML copied in Safari pastes as formatted text into an Android rich-text field and as its plain text into a plain field.

### #081 Links (M9)

1. Guest: `UrlRedirectActivity`, the browser role, the kept intent and `ResolveUrl`, `Browser2` check in the image.
2. Host: `LinkForwarder` (§7.2) with the prompt on the session channel.
3. Acceptance: §7.3.

### #082 Files (M9)

1. Drag and drop (§6.2) with `DropTarget`, `importFiles`, `ImportFiles` with `display_id`.
2. Save to Mac (§6.3) with `SaveToMacActivity`, `ExportFileOffered`, `ResolveExport`, save panel, quarantine.
3. Shared folders (§6.4): `SharedFolderService`, the host operations of [guest-protocol.md](guest-protocol.md) §7.5, `MacFilesProvider` with proxy file descriptors, Settings → Files, R-22.
4. Acceptance: §6.5.

### #085 Locale, time zone, clock format, time (M9)

1. `LocaleTimeSync` (§9) with the host change notifications, `SetClockFormat`, the time zone fallback. `SyncTime` after wake already exists from #069.
2. Acceptance: §9 verification.

### #083 Audio output (M12)

1. `audio.output`, the sound device in `VMDefinition` (android-image `soundOutput`), the kernel and HAL checks of [android-image.md](android-image.md) §7.5.
2. Acceptance: §8.3 (#083).

### #084 Microphone (M12)

1. The input stream rule, the embedded usage description, app-ops gating in the agent (`SetMicrophoneAccess`), active-recording events, the restart prompt.
2. Acceptance: §8.3 (#084).

---

## 15. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | `IntegrationPolicy` decision table (global × package × focus × image support) | #053 |
| T0 | Clipboard loop prevention with simulated pasteboard and agent (both markers, digests, two windows) | #053 |
| T0 | Notification filters and mapping (§5.1, §5.2), identifier stability, category LRU | #054 |
| T0 | URL validation and rate limits (§7.2), including IDN hosts, `javascript:`, `intent:`, over-long URLs | #081 |
| T0 | `SharedFolderService` path resolution: `..`, absolute paths, symlink escapes, hidden files, packages, read-only writes | #082 |
| T0 | Locale tag and time zone fallback mapping (`Etc/GMT` sign) | #085 |
| T1 | Kotlin: `ClipboardBridge` echo suppression, notification filter, `MacFilesProvider` access checks with a fake host (Robolectric) | #053, #054, #082 |
| T2 | §4.5, §5.5, §6.5, §7.3, §9 verification with the fixtures on the custom image. #053 (M4) and #069 (time sync) run first on the stock image with the shell-mode agent, and again in the AndroidCustom suite after #035 | each task |
| T2 | Protocol fuzzing of the host operations (§6.4) from a malicious agent build (#091) | #082, #091 |
| T3 | Audio loopback and microphone with a virtual audio device (nightly, where the runner has one; otherwise a manual check, [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §8.7) | #083, #084 |

Fixtures (built by [../05-development/build-system.md](../05-development/build-system.md), listed in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4.2): HelloClipboard, HelloNotification, HelloLinks, HelloFiles, HelloFilesPeer, and HelloAudio, with packages `io.apkrun.fixture.<lowercase name>`.

---

## 16. Open items

Recorded in [../04-plan/open-questions.md](../04-plan/open-questions.md) and [../04-plan/risks.md](../04-plan/risks.md):

- R-21: pasteboard read prompts on macOS 27 for the focus push (§4.2).
- R-22: macOS privacy prompts and their attribution for apkrund reading user-added folders (§6.4).
- R-19 (shared with [wrapper.md](wrapper.md)): background mode and notification permission across wrapper refreshes.
- Whether the microphone prompt appears at VM start or at first capture (#084).
- Post-v1 candidates: media controls and Now Playing from Android `MediaSession`; notification replies; Mac → Android links; per-app languages; dark mode sync; a per-app mute; a camera.

---

## 17. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| R-21: does reading the pasteboard on focus prompt on macOS 27, and which API tells the adapter in advance? | #053 | pending (§4.2) |
| Background clipboard read as the shell uid on the stock image | #053 | pending (§2.4) |
| ⌘V latency p95 ≤ 150 ms for 64 KiB of text | #053 | pending (§4.5) |
| The background-activity-start mode for notification clicks (API 34+) | #054 | pending (§5.4) |
| Notification latency: p50 ≤ 1 s with the wrapper running, ≤ 3 s with a background start | #054 | pending (§5.5) |
| R-19: no Dock tile flash in background mode, and the notification permission survives a wrapper refresh | #054, #076 | pending (§5.5) |
| Does the product image include `Browser2`? | #081 | pending (§7.1) |
| R-22: macOS privacy prompts and their attribution for user-added folders | #082 | pending (§6.4) |
| Provider throughput ≥ 200 MB/s for a 1 GiB file | #082 | pending (§6.5) |
| Output latency ≤ 120 ms, no underrun in 10 minutes, and the negotiated rate and format | #083 | pending (§8.1) |
| Does the microphone prompt appear at VM start or at the first capture? | #084 | pending (§8.2) |
| Does apkrund's microphone usage text appear in Japanese? | #092 | pending (§8.2) |
| Does `cmd time_detector` work as the shell uid without root? | #069 | pending (§9) |
