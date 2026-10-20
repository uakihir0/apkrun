# M9 macOS integration

M9 makes Android apps behave like Mac apps at their edges: notifications, clipboard images and HTML, links, files, locale and time, and a menu bar item. Every integration goes Guest Agent → `IntegrationPolicy` → host and can be turned off per app and globally (NFR-SEC-03, [security-model.md](../../01-architecture/security-model.md) §6). Notifications, links, and files need the custom image ([desktop-integration.md](../../02-design/desktop-integration.md) §2.4). #55 runs its R-19 check first. #55, #81, #82, #83, and #86 share the guest manifest, `.proto` files, and RuntimeAPI DTOs, so merge them in small pull requests. M9 closes no gate.

---

## #55 Notifications

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #35, #36, #48 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §3.2, §5; [wrapper.md](../../02-design/wrapper.md) §5.2, §5.8; [guest-protocol.md](../../02-design/guest-protocol.md) §8.4; [host-ui.md](../../02-design/host-ui.md) §7.4 |
| Code | `Packages/IntegrationCore/Sources/IntegrationCore/Notifications/`, `Packages/RuntimeHost/` (`WorkspaceOpener`), `Apps/APKRunLauncher/Integration/` (`NotificationPoster`), `Guest/guestd/` (`notifications/`), `Packages/GuestProtocol/proto/`, `Tests/Fixtures/AndroidApps/hellonotification/` |

**Goal.** A managed app's Android notification appears as a macOS notification under the Mac app's name and icon. A click or action brings the app forward and delivers the Android intent. Dismissing on either side removes it on the other.

**Out of scope.** Mac replies, images, time-sensitive alerts, and media controls ([desktop-integration.md](../../02-design/desktop-integration.md) §16). Firebase push while the app is not running (R-09).

**Steps.**
1. **Verify R-19.** Build a launcher from the template that starts with `--apkrun-background notifications` and uses `.accessory` activation policy. Start it with `NSWorkspace.openApplication` and post one notification. Refresh the wrapper ([wrapper.md](../../02-design/wrapper.md) §9.3) and check that permission survives and the Dock does not flash. Otherwise use [wrapper.md](../../02-design/wrapper.md) §9.4. Update R-19 in [risks.md](../../04-plan/risks.md). **Check:** R-19 is settled.
2. **Guest listener.** `ApkRunNotificationListener` (`PRIVILEGED_APP` only) grants access with `setNotificationListenerAccessGranted`. On loss it sends `HealthWarning(NOTIFICATION_LISTENER_DISABLED)` and grants again. It forwards only `SetNotificationForwarding` packages and applies [desktop-integration.md](../../02-design/desktop-integration.md) §5.1. **Check:** Robolectric filter tests pass.
3. **Guest operations.** `SetNotificationForwarding` replaces the list and replays with `replay = true`. `ActivateNotification(key, action_index?, display_id)` sends the intent with launch display `display_id`; without a content intent it sends `LaunchApplication`; an unknown key answers `NOT_FOUND`. `DismissNotification` cancels, and removals send `NotificationRemoved`. **Check:** on the custom image the click opens on the requested display. Update the verify item in [guest-components.md](../../02-design/guest-components.md) §5.
4. **Host routing.** `NotificationCoordinator` calls `IntegrationPolicy.evaluate(.notifications, …)`, then uses the package's wrapper with status `valid`. A connected wrapper gets `relay.post`. A stopped one is started in background mode through the injected `WorkspaceOpener`. Its notifications queue for up to 10 s, at most 50 per package, then drop and count. Without a usable wrapper, APKRun.app posts (HostNotifier). After reconnect, replay rebuilds keys and badges without banners. Push `SetNotificationForwarding` as [desktop-integration.md](../../02-design/desktop-integration.md) §3.2 says. **Check:** T0 routing tests pass with a fake channel and wrapper registry.
5. **Relay and poster.** `notificationRelay()` on the `.wrapper` endpoint ([wrapper.md](../../02-design/wrapper.md) §12.1) carries `post`, `remove`, and `setBadge`, and receives `activated`, `dismissed`, and `authorizationChanged`. A wrapper gets only its own package. `NotificationPoster` maps payloads as [desktop-integration.md](../../02-design/desktop-integration.md) §5.2 says. Identifier: `<package>|<first 16 hex of SHA-256(key)>`. Up to 3 actions go into a category LRU of 32 that never evicts a category on screen. **Check:** T0 mapping, identifier, and LRU tests pass.
6. **Click, texts, logs.** A background click switches to `.regular`, follows [wrapper.md](../../02-design/wrapper.md) §5.2 step 3, and sends `activated` when the session is `running`. Background launchers quit 30 s after the last notification. The app page says "Notifications for ‹App› are turned off in System Settings" when denied, and "‹App› can only notify you while it is running." with `closeBehavior = stop` ([host-ui.md](../../02-design/host-ui.md) §7.4). Log under `io.apkrun.integration`/`notifications`, never with titles or text. Emit `NOTIFICATION_DELIVERED` and add `integrations.notificationListener`. **Check:** the T2 click cases pass.

**Tests.**
- T0 (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`, launcher tests): filters, mapping, identifiers, LRU, routing (connected, background start, queue overflow, 10 s timeout, HostNotifier), replay without banners, policy table.
- T1: Robolectric filter and payload builder in `Guest/guestd/src/test/`. XPC relay: own package only, reconnect replay, denied authorization.
- T2 (`Tests/IntegrationTests/`, custom image, fixture `hellonotification` ([test-strategy.md](../test-strategy.md) §4.2)): plain, two-action, update, `LOW`, ongoing, and grouped posts; click with the app closed and with the window open; actions; dismiss both ways; switch off; latency; restart with 3 active posts sends no banners.
- T3: none.

**Done when.**
- A native Mac notification appears. A click returns the user to the Android app at the content intent.
- The Mac notification carries `{package, keyDigest}`. A click after the Android notification is gone opens the app.
- Notifications appear under the app's name with the wrapper icon. Ongoing ones and group summaries do not appear. `LOW` is silent.
- Action buttons deliver the matching Android intent. Dismissing either side removes it on the other. The Dock badge shows the active count.
- With `integrations.notifications = false`, nothing leaves the guest.
- Latency from `notify()` to the banner is p50 ≤ 1 s with the wrapper running, and ≤ 3 s with a background start.
- No Dock tile flashes in background mode, and permission survives a wrapper refresh.
- A package with no wrapper gets notifications through APKRun.app, and a click launches it.
- No log line contains a title or text (NFR-SEC-05).

**Pitfalls.**
- The listener runs in the agent process. Treat every field as untrusted, apply length limits first, and catch parse errors per notification.
- The category LRU must never evict a category that a notification on screen uses.

---

## #81 Image and HTML clipboard

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #54 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §3.3, §4; [guest-protocol.md](../../02-design/guest-protocol.md) §5.3, §8.4; [runtime-api.md](../../03-reference/runtime-api.md) §4.9, §4.10 |
| Code | `Packages/IntegrationCore/Sources/IntegrationCore/Clipboard/`, `Packages/RuntimeAPI/` (`ClipItem`), `Packages/GuestProtocol/proto/`, `Apps/APKRunLauncher/Integration/` (`PasteboardAdapter`), `Guest/guestd/` (`clipboard/`, `FileProvider`), `Tests/Fixtures/AndroidApps/helloclipboard/` |

**Goal.** HTML and PNG images move both ways on the clipboard, with the focus and loop rules of plain text. A Mac screenshot pastes into an Android image view. HTML keeps its formatting in rich-text fields and falls back to plain text elsewhere.

**Out of scope.** Files, URLs as files, and RTF (RTF falls back to plain text, [desktop-integration.md](../../02-design/desktop-integration.md) §4.4). Animated images keep only the first frame. Plain text and the ⌘V ack (#54).

**Steps.**
1. **Messages.** Add `html` and `image` to `ClipData` (`Packages/GuestProtocol/proto/`) and `ClipItem` (RuntimeAPI). The image is PNG `Data` of at most 16 MiB, so a clip fits the 32 MiB XPC limit ([runtime-api.md](../../03-reference/runtime-api.md) §4.10). Advertise `clipboard.image.v1`. Without it, image operations answer `UNSUPPORTED`. **Check:** T0 codec round trips pass.
2. **Mac to Android.** `PasteboardAdapter` reads `public.utf8-plain-text`, `public.html`, then `public.png` or `public.tiff`. It converts TIFF to PNG with ImageIO, and derives plain text from HTML when none is present. An image over 16 MiB or 8192 px per side is dropped, and `ClipAck` carries `clipboardTooLarge(bytes:limit:)`. Text and HTML still go. apkrund sends the image as a host bulk transfer, then `SetClipboard` with `image.transfer_id`. The agent serves it through its `FileProvider` (`io.apkrun.guest.files`) as `image/png`. **Check:** a TIFF screenshot arrives as PNG.
3. **Android to Mac.** `ClipboardBridge` checks bounds with `inJustDecodeBounds` before decoding. A PNG within the limits passes unchanged. Other formats are re-encoded to PNG. The agent sends a bulk transfer and then `ClipboardChanged` with `image.transfer_id`. apkrund stores it under `~/Library/Caches/io.apkrun.APKRun/transfers/`, reads it into `ClipItem`, and deletes the temp file. `PasteboardAdapter` writes `public.png`, the text and HTML types, and the `io.apkrun.clip-origin` marker. **Check:** a T1 test shows the temp file is gone after the event.
4. **Loop prevention.** Apply the signals of [desktop-integration.md](../../02-design/desktop-integration.md) §4.4 to images and HTML: origin, seq, digest of the image bytes, and marker. Images are pushed only on ⌘V (R-21, settled by #54). **Check:** the T0 loop test with an image adds no extra `changeCount` change.

**Tests.**
- T0 (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): size and pixel limits, digests and loop prevention with a simulated pasteboard and agent, HTML without plain text, and the ⌘V fallback when the image is too large.
- T1: Robolectric `ClipboardBridge` with images (bounds, re-encode, echo suppression). Host test of temp-file cleanup.
- T2 (`Tests/IntegrationTests/`, custom image, fixture `helloclipboard` ([test-strategy.md](../test-strategy.md) §4.2)): the Done-when checks.
- T3: none.

**Done when.**
- A ⌘⌃⇧4 screenshot pastes into HelloClipboard's image view, and an image copied in the fixture pastes into Preview.
- HTML from Safari pastes formatted into a rich-text field and as plain text into a plain field.
- An image over 16 MiB or 8192 px per side is not sent. The text still goes, and the window shows the limit message.
- Images and HTML do not bounce between two windows.
- With `integrations.clipboard = false`, nothing moves in either direction.
- No image bytes or HTML appear in logs, and no temp file remains after a transfer.

**Pitfalls.**
- Decode Android images only after the bounds check. A small file can declare a huge bitmap.
- Prefer PNG when the Mac pasteboard has both TIFF and PNG, so nothing is re-encoded.
- Images travel as `Data` inside `ClipItem`, because `FileHandle` is allowed only from client to apkrund ([runtime-api.md](../../03-reference/runtime-api.md) §4.9).

---

## #82 Links

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #35, #36, #48 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §3.2, §7; [guest-protocol.md](../../02-design/guest-protocol.md) §7.1; [android-image.md](../../02-design/android-image.md) §11.2; [host-ui.md](../../02-design/host-ui.md) §7.4; [diagnostics.md](../../02-design/diagnostics.md) §6 |
| Code | `Packages/IntegrationCore/Sources/IntegrationCore/Links/` (`LinkForwarder`), `Packages/RuntimeHost/` (`WorkspaceOpener`), `Packages/RuntimeAPI/` (`LinkPrompt`, `LinkChoice`), `Packages/GuestProtocol/proto/`, `Apps/APKRunLauncher/Integration/`, `Guest/guestd/` (`url/`), `Guest/product/`, `Tests/Fixtures/AndroidApps/hellolinks/` |

**Goal.** A link an Android app opens goes to the Mac's default browser or mail app, once the user agrees for that app (`ask`). Links from background work or with unsafe schemes are dropped. Apps that need their browser inside Android, for sign-in, keep their links there.

**Out of scope.** Mac-to-Android links and custom schemes such as `myapp://callback` ([wrapper.md](../../02-design/wrapper.md) §2.1). Android App Links, which Android resolves first. The stock-image agent, where the handler stays off.

**Steps.**
1. **Browser2.** Check whether the product image has AOSP `Browser2`, and add it if not ([android-image.md](../../02-design/android-image.md) §11.2). **Check:** with the redirect off, `cmd package resolve-activity` for an `https` VIEW intent lists `Browser2`. Record the result in [desktop-integration.md](../../02-design/desktop-integration.md) §7.1.
2. **Redirect activity.** `UrlRedirectActivity` (`PRIVILEGED_APP` only) filters `http`, `https`, and `mailto`. At agent start it takes `ROLE_BROWSER` with `RoleManager.addRoleHolderAsUser`. If the role is lost, it sends `HealthWarning(BROWSER_ROLE_LOST)` and takes it again. It sends `OpenUrlOnHost(request_id, url, source_package, display_id)` and keeps the intent for 60 s. Packages in `excluded_packages` go straight to the in-Android browser. `SetUrlRedirect(enabled = false)` keeps all links in Android. **Check:** a verified App Link still opens its app.
3. **`ResolveUrl`.** `OPEN_IN_GUEST` starts the kept intent in the in-Android browser on the same display. `OPENED_ON_HOST` and `DROP` finish it. An expired request answers `NOT_FOUND`. Without an in-Android browser, "Keep in Android" is not offered. **Check:** T2 "Keep in Android" opens `Browser2` on the app's display.
4. **`LinkForwarder`.** Validate with `URLComponents`: scheme `http`, `https`, or `mailto`; at most 8 KiB; `http` and `https` need a host. Anything else gets `ResolveUrl(DROP)` and is counted. The app's window must be key, or have had input in the last 5 s. At most 3 links per 10 s per package. `links = mac` opens the validated `URL` with the injected `WorkspaceOpener` and answers `OPENED_ON_HOST`. `links = android` answers `OPEN_IN_GUEST`. Push `SetUrlRedirect` as [desktop-integration.md](../../02-design/desktop-integration.md) §3.2 says. **Check:** T0 validation tests pass, including IDN hosts, `javascript:`, `intent:`, and URLs over 8 KiB.
5. **Link prompt.** For `links = ask`, send `linkPrompt(LinkPrompt{promptID, host, scheme})` to the window. The sheet in `Apps/APKRunLauncher/Integration/` says "‹App› wants to open ‹example.com›." with **Open in Browser**, **Keep in Android**, **Cancel**, and "Remember for ‹App›". It shows the Unicode host with the registrable domain in bold, never the path or query. A path containing `oauth`, `authorize`, or `login` (case-insensitive) adds "Signing in? Keep links from ‹App› in Android". No answer in 60 s counts as Cancel. Remember writes `integrations.links`. **Check:** a UI test with an IDN host passes.
6. **Logs and health.** Log the scheme and registrable domain only, at debug level. Add the `integrations.browserRole` health check. **Check:** the T2 cases pass.

**Tests.**
- T0 (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): validation and rate limits, the focus and 5 s rule, prompt text, and the `SetUrlRedirect` list.
- T1: XPC `linkPrompt` and `resolveLinkPrompt`, including the 60 s timeout with a shortened clock.
- T2 (`Tests/IntegrationTests/`, custom image, fixture `hellolinks` ([test-strategy.md](../test-strategy.md) §4.2)): `https`, `mailto`, a Custom Tab, `javascript:`, `intent:`, and a background link.
- T3: none.

**Done when.**
- With `ask`, the first link shows the prompt. **Open in Browser** with Remember opens the default browser, and later links need no prompt.
- **Keep in Android** opens the in-Android browser on the app's display.
- `mailto` opens the default Mac mail app.
- `javascript:` and `intent:` URLs are dropped, and so is a link opened after the window lost focus.
- With the global switch off, all links stay in Android.
- A fourth link within 10 s from one app is dropped.
- The prompt never shows a path or query, and logs never contain a full URL (NFR-SEC-05).

**Pitfalls.**
- Validate and open the same `URL` value. Never parse the original string again.
- The browser role has one holder. If `Browser2` also claims it, the agent must keep it, or links bypass the host.
- The bold registrable domain needs a Public Suffix List. Use the log redactor's helper ([diagnostics.md](../../02-design/diagnostics.md) §6), or pin a snapshot in `ThirdParty/ThirdParty.lock.json`.

---

## #83 Files

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #35, #36 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §6, §11; [guest-protocol.md](../../02-design/guest-protocol.md) §7.5; [wrapper.md](../../02-design/wrapper.md) §4.3; [host-ui.md](../../02-design/host-ui.md) §9.5; [configuration.md](../../03-reference/configuration.md) §1.4 |
| Code | `Packages/IntegrationCore/Sources/IntegrationCore/Files/` (`FileTransferService`, `SharedFolderService`), `Packages/RuntimeAPI/`, `Packages/GuestProtocol/proto/`, `Apps/APKRunLauncher/Integration/` (`DropTarget`, save panel), `Apps/APKRun/` (Settings → Files), `CLI/apkrun/` (`shared-folders`), `Guest/guestd/` (`files/`), `Tests/Fixtures/AndroidApps/hellofiles/` |

**Goal.** Users drop files on an app's window, and the app receives them as a share. An Android app can save a file to the Mac through a Save panel. Apps with the setting on read files in the Shared folder and in folders the user added, through Android's file picker, read-only unless the user chose read-write. Android never sees the home folder, and every file that leaves Android is quarantined.

**Out of scope.** A virtio-fs directory share. Drops of folders or promised files, positional drops, and a folder chooser for many saved items (post-v1; a drop arrives as a share, [desktop-integration.md](../../02-design/desktop-integration.md) §6.2). Fuzzing the host operations (#92): this task provides the malicious-agent build.

**Steps.**
1. **Drop.** `DropTarget` accepts file URLs only, and refuses more than 20 files, a file over 2 GiB, or more than 4 GiB in total. The window calls `importFiles([FileHandle], [ImportFileInfo{name, size, uti}], .shareToApp)`. apkrund checks `.files`, sends host bulk transfers, then `ImportFiles(SHARE_TO_PACKAGE, package, display_id, files)`. `FilesBridge` (`Guest/guestd/files/`) serves the files through its `FileProvider` and sends `ACTION_SEND` or `ACTION_SEND_MULTIPLE` with `FLAG_GRANT_READ_URI_PERMISSION`. With no share target, the files go to `MediaStore.Downloads` and the window says "Saved to Downloads". Cached files are deleted after 24 h or at uninstall. **Check:** T2 drops three files, one of 1.5 GiB, with the right hashes.
2. **Save to Mac.** `SaveToMacActivity` is a chooser target for at most 20 items. It sends `ExportFileOffered(offer_id, name, mime_type, size, source_package, display_id)`. apkrund checks `.files` and sends `exportOffered` to the session window. With no window it answers `ResolveExport(DECLINE)`. The window shows one `NSSavePanel` per item, default `~/Downloads`, with the name sanitized as [wrapper.md](../../02-design/wrapper.md) §4.3 says. Save calls `acceptExport(offerID, FileHandle)`, and Cancel calls `acceptExport(offerID, nil)`. apkrund writes the stream and checks size and SHA-256. The window sets `com.apple.quarantine` with the agent name "‹App› (APKRun)", and deletes a failed file. **Check:** T2 Save to Mac gives the right hash and a quarantine attribute.
3. **Roots and settings.** The roots are `~/Library/Application Support/APKRun/Shared/` and the user's folders. `sharedFolders.roots` stores `{id, bookmark, access}`, at most 32 ([configuration.md](../../03-reference/configuration.md) §1.4). `addSharedFolder` refuses the volume root, the home folder, `~/Library` and its contents, hidden folders and their contents, and a 33rd root with `IntegrationFailure.folderRefused`, reason `pathRejected(.protectedLocation)`. Settings → Files ([host-ui.md](../../02-design/host-ui.md) §9.5) lists the Shared folder first, then user folders with access and availability, with **Add Folder…** and **Remove**. `apkrun shared-folders add <path> [--read-write]` creates the bookmark. Effective access is the lower of the root's access and `integrations.sharedFolders`. Push `SetSharedFolderAccess` after each handshake and change. **Check:** the T1 refused-roots test passes.
4. **`SharedFolderService`.** In `Packages/IntegrationCore/Sources/IntegrationCore/Files/`. For each host request, check in order: effective access (`readWrite` for writes); a relative path with no `..`, opened with `openat` from the root's descriptor and `O_NOFOLLOW` on each component; only regular files and directories, with hidden files and packages (`.app`, `.photoslibrary`) neither listed nor opened; limits of 4096 entries per page, 1 MiB per read or write, 64 open handles per package (`RESOURCE_EXHAUSTED`), and 16 requests in flight. Close all handles when the runtime stops. Android-written files get `com.apple.quarantine`. **Check:** T0 decision tests and T1 confinement tests pass on a temporary tree.
5. **`MacFilesProvider`.** A `DocumentsProvider` (`io.apkrun.guest.macfiles`, `PRIVILEGED_APP` only) with one root per Mac folder. `openDocument` and every write check `getCallingPackage()` against the access list. A package without access gets `SecurityException("Blocked by APKRun settings")`. Browsing lists names only. Contents use `StorageManager.openProxyFileDescriptor`, so reads and writes become `HostReadRange` and `HostWriteRange`. `ACTION_CREATE_DOCUMENT` works only in `readWrite` roots. Document IDs are `<root_id>:<relative path>`. **Check:** Robolectric access tests pass with a fake host.
6. **R-22 and API.** Add a folder inside Desktop, Documents, Downloads, iCloud Drive, and a removable volume. Check whether apkrund's first read shows a macOS prompt, and what a denial looks like. A denied root shows "Can't access. Allow APKRun in System Settings → Privacy & Security → Files and Folders." If the prompt is missing or misattributed, use security-scoped bookmarks that APKRun.app creates through the open panel. Implement `integrationStatus(packageID)`, the operations of [desktop-integration.md](../../02-design/desktop-integration.md) §11, the `integrations.sharedFolders` health check, and the `FILE_TRANSFER` marker. Errors are `IntegrationFailure` cases `tooManyFiles`, `fileTooLarge`, `transferFailed`, `folderUnavailable(.missing/.privacyDenied/.offline)`, `pathRejected(.outsideRoot/.hidden/.notRegularFile)`, and `readOnly`. **Check:** R-22 is settled, and `apkrun integrations status <package>` shows the effective access.

**Tests.**
- T0 (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): `SharedFolderService` decisions (`..`, absolute paths, hidden files, packages, read-only writes, effective access, handle limits), drop limits, and name sanitizing.
- T1: confinement on a temporary tree with symlinks inside and outside the root, refused roots, quarantine, and Robolectric `MacFilesProvider` access checks with a fake host.
- T2 (`Tests/IntegrationTests/`, custom image, fixture `hellofiles` ([test-strategy.md](../test-strategy.md) §4.2)): drop, save, and share cases, and a malicious-agent build that sends out-of-root paths, too many handles, and oversized ranges.
- T3 (reference Mac, manual): the R-22 privacy prompt with a user folder in Documents.

**Done when.**
- Three dropped files, one of 1.5 GiB, arrive with the right SHA-256. With `integrations.files = false`, a drop is refused.
- A drop on an app without a share target saves to Android Downloads and says so.
- "Save to Mac" writes where the panel said, with the right hash and a quarantine attribute. A failed transfer leaves no partial file.
- With `sharedFolders = readOnly`, the fixture reads files in the Shared folder but cannot create or change them, and cannot open a symlink that points outside the root.
- With `sharedFolders = off`, a previously granted URI fails. A second package without access cannot open a URI granted to the first.
- `addSharedFolder` refuses the home folder, `~/Library`, and hidden folders such as `~/.ssh` (NFR-SEC-02).
- A 1 GiB read through the provider reaches 200 MB/s, or the measured value replaces the target in [desktop-integration.md](../../02-design/desktop-integration.md) §6 with its reason.
- No file names or contents appear in logs (NFR-SEC-05).

**Pitfalls.**
- Check every host request again in apkrund. The agent's checks are a convenience, and a compromised agent can send anything (NFR-SEC-01).
- `openProxyFileDescriptor` callbacks run on a handler thread, and a slow host read blocks the Android read. Keep up to 4 reads of 1 MiB ahead per handle.
- A security-scoped bookmark works only for the app that created it. Before using the R-22 fallback, check whether apkrund can use a bookmark that APKRun.app created.

---

## #86 Locale, time zone, clock format, and time

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #35, #36, #70 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §3.2, §9; [guest-protocol.md](../../02-design/guest-protocol.md) §7.1; [android-image.md](../../02-design/android-image.md) §11.2; [host-ui.md](../../02-design/host-ui.md) §9.6; [wrapper.md](../../02-design/wrapper.md) §9.1 |
| Code | `Packages/IntegrationCore/Sources/IntegrationCore/Locale/` (`LocaleTimeSync`), `Packages/RuntimeCore/`, `Packages/GuestProtocol/proto/`, `Apps/APKRun/` (Settings → Language & Region), `Guest/guestd/` (`locale/`, `LocaleTimeService`) |

**Goal.** Android uses the Mac's languages, region, time zone, and 12/24-hour setting, and follows changes while it runs. The guest clock stays within 1 s of the Mac, and within 2 s after the Mac wakes.

**Out of scope.** `SyncTime` after resume and wake, and the ADB fallback (#70). Per-app languages and dark mode (post-v1). New tzdata, which comes with image updates (#88).

**Steps.**
1. **Host sources.** `LocaleTimeSync` reads `Locale.preferredLanguages`, adds the region of `Locale.current` to the first tag when it has none, and sends at most 8 BCP 47 tags with script subtags kept (`zh-Hans`, `sr-Latn`). The zone is `TimeZone.current.identifier`, read after `TimeZone.resetSystemTimeZone()`. The 12/24 value is `TWELVE` if `DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)` contains `a`, else `TWENTY_FOUR`. Use `Locale.autoupdatingCurrent`. **Check:** T0 tag mapping passes, including a first tag without a region.
2. **Triggers and change-only pushes.** Push after post-boot setup, after each reconnect, on `NSLocale.currentLocaleDidChangeNotification`, and on `NSSystemTimeZoneDidChange`. Each item is pushed only when its `system.sync*` switch is on. The agent does nothing for an unchanged value. A push during a launch waits until the session is `running`. A label change gives wrappers a `.displayName` refresh reason ([wrapper.md](../../02-design/wrapper.md) §9.1). apkrund is a LaunchAgent without a window, so if it misses the notifications it re-reads the host values at `ready`, at resume, and every 30 min. **Check:** T0 shows that an unchanged value sends nothing and that no push happens between `openSession` and `running`.
3. **Guest setters.** `LocaleTimeService` in `Guest/guestd/locale/` handles ops 46, 47, and 49. `SetLocale` uses `updatePersistentConfigurationWithAttribution`, `SetTimeZone` uses `AlarmManager.setTimeZone`, and `SetClockFormat` writes `Settings.System.TIME_12_24`. An unknown zone answers `NOT_FOUND`. For a whole-hour offset the host sends `Etc/GMT∓h` (sign inverted), logs a health warning, and sets `integrations.time` to warning. For a non-whole-hour offset the guest keeps its zone and warns. Add the privapp permissions `CHANGE_CONFIGURATION`, `SET_TIME_ZONE`, and `SET_TIME` if missing. **Check:** T0 sign tests pass. Run `SetTimeZone` as the shell uid on the stock image, and record the result in [guest-components.md](../../02-design/guest-components.md) §5.
4. **Clock.** Add `SyncTime` triggers after boot, every 30 min while `ready`, and after `NSSystemClockDidChange`. The agent applies a difference over 500 ms, plus half of the last `Ping` round-trip time. The custom product sets `AUTO_TIME = 0` and `AUTO_TIME_ZONE = 0` ([android-image.md](../../02-design/android-image.md) §11.2). A failed `SyncTime` sets `integrations.time` to warning. **Check:** a T2 test with a changed guest clock shows correction within 30 min, using a shortened interval.

**Tests.**
- T0 (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): tag mapping, 12/24 detection for several locales, the `Etc/GMT` sign and the non-whole-hour case, change-only pushes, and no push on the launch path.
- T1: simulated power events for the `SyncTime` triggers with a fake channel (FR-VM-11).
- T2 (`Tests/IntegrationTests/`, custom image): with HelloText running, change the language order, region, and 24-hour setting with `defaults write -g` plus a distributed notification from a test helper, and change the zone with `systemsetup -settimezone`. `GetSnapshot` follows within 2 s, and HelloText shows the new time format. Restore the Mac settings afterwards.
- T3 (reference Mac, manual): sleep for 2 min with `pmset sleepnow` and a scheduled wake, then check the guest clock. Make the same changes in System Settings. Check C05-9 ([test-strategy.md](../test-strategy.md) §8.6): with macOS in Japanese, HelloSplit (#43) shows its Japanese string.

**Done when.**
- Changing the language order, region, zone, and 24-hour setting while HelloText runs updates Android within 2 s, and HelloText shows the new time format.
- After 2 min of Mac sleep and wake, the guest clock is within 2 s of the host.
- An unchanged value is not pushed, and no locale push happens on the launch path.
- A zone unknown to the image falls back to `Etc/GMT∓h` with the correct sign and a health warning.
- With a `system.sync*` switch off, that item stays unchanged in Android.
- The `SET_TIME_ZONE` shell result is recorded in [guest-components.md](../../02-design/guest-components.md) §5.

**Pitfalls.**
- A locale change restarts activities that do not handle configuration changes. Pushes are therefore change-only and never on the launch path.
- If apkrund does not receive the locale and zone notifications, use the re-read fallback of step 2.

---

## #87 Menu bar

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #33 |
| Design | [host-ui.md](../../02-design/host-ui.md) §12; [runtime-daemon.md](../../02-design/runtime-daemon.md) §5.1, §7.2; [process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2; [configuration.md](../../03-reference/configuration.md) §2.10 |
| Code | `Apps/APKRunMenuBar/`, `Apps/APKRun/` (Settings → General toggle), `project.yml` (target and Login Items embed), `Tests/` (model tests), `Tests/IntegrationTests/`, `Tests/AcceptanceTests/` |

**Goal.** A menu bar item shows whether Android runs, which apps run, and which updates are available. From it the user can bring an app forward, update apps, open APKRun, and stop Android. It keeps running when APKRun.app quits, and it never keeps Android running.

**Out of scope.** The maintenance rows (APKRun version, Android system update, "Finish updating APKRun…", "◐ Updating Android…"), which #58 and #88 add. The microphone symbol (#85). Japanese strings (#93): all strings go into String Catalogs now.

**Steps.**
1. **Target and connection.** Add the `APKRunMenuBar` target (`LSUIElement = true`, bundle ID `io.apkrun.APKRunMenuBar`), embedded in `APKRun.app/Contents/Library/LoginItems/` through `project.yml`. It depends only on RuntimeClient and DiagnosticsCore. It connects to `.control`, subscribes to the `runtime`, `sessions`, `updates`, and `health` topics, and reloads after each reconnect. While apkrund is unreachable, the runtime line says so and offers **Open APKRun…**. **Check:** `scripts/check-module-deps.sh` passes, and a T1 test shows Android still reaches its idle stop with the item connected.
2. **Login item.** Settings → General has "Show APKRun in the menu bar", on by default, with no settings key. It shows and changes the `SMAppService.loginItem(identifier:)` registration. APKRun.app registers the item at its first launch. If the user removed the login item in System Settings, the toggle shows off. If APKRun.app opens with the setting on and the item is not running, it starts the item. **Check:** turning the toggle off quits the item and removes the login item.
3. **Menu.** Build the menu of [host-ui.md](../../02-design/host-ui.md) §12. The status item is a template image: filled while Android runs, outlined while stopped or asleep, with a dot when updates are available, the runtime failed, or a live health check needs attention. In the last case the menu shows "⚠ Needs attention", which opens Troubleshooting in APKRun.app. **Apps** lists running sessions, and a click runs `launch(packageID)`. **Updates** lists updates with **Update** (manual, under the gentle rules) and **Update All**. **Open APKRun…** opens the enclosing app. "Developer mode on" shows under the runtime line while developer mode is on. `MenuBarModel` is the item's own model over `RuntimeClient`. **Check:** model tests over a fake `RuntimeService` cover each row and the dot rules.
4. **Stop and start.** **Stop Android** asks for confirmation when apps are open, then stops the runtime. When Android is stopped the item reads **Start Android**, which starts the runtime without a hold. **Quit Menu Bar Item** quits only the item. **Check:** a T2 test stops and starts Android from the model.

**Tests.**
- T0 (`Tests/`, model tests over a fake `RuntimeService`): runtime line states, dot rules, app and update counts, reload after reconnect, and the Stop Android confirmation.
- T1: XPC tests against apkrund with the embedded runtime fake. The menu connection is not activity, and reconnect reloads the snapshots.
- T2 (`Tests/IntegrationTests/`): with two apps running and two updates available, the counts and rows are right, and **Stop Android** stops the runtime after confirmation.
- T3 (reference Mac, manual): the login item after logout and login, and quitting APKRun.app with the item and apps running.

**Done when.**
- With two apps running and two updates available, the menu shows both counts and lists the apps and updates.
- **Stop Android** stops the runtime after confirmation, and the item then reads **Start Android**.
- Quitting APKRun.app leaves the menu bar item and the apps running.
- Clicking an app in the menu brings its window forward.
- With the item connected and no apps open, Android goes idle and stops as configured.
- **Quit Menu Bar Item** quits only the item. It returns at the next login, or when APKRun.app opens with the setting on.
- After apkrund restarts, the menu reconnects and shows current data.

**Pitfalls.**
- The menu bar item and APKRun.app are separate processes. Do not share models across app targets. Use `RuntimeClient` in both.
- `SMAppService.loginItem` needs the helper inside `Contents/Library/LoginItems/` of a signed app. A Debug build run from Xcode's build folder can behave differently.
