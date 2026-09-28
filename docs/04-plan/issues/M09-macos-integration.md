# M9 macOS integration

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.5 |
| Related | [../traceability.md](../traceability.md), [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../../AGENTS.md](../../../AGENTS.md) |

## Milestone goal

Android apps behave like Mac apps at the edges. Their notifications appear in Notification Center under the Mac app's name, and a click brings the app back. Images and formatted text move through the clipboard. Links open in the Mac browser. Files can be dropped into an app and saved from it to the Mac, and Android apps can open files in folders the user shared. Android follows the Mac's language, region, time zone, and clock. A menu bar item shows the runtime, the running apps, and pending updates.

Every integration goes Guest Agent → `IntegrationPolicy` → host, and each one can be turned off per app and globally (NFR-SEC-03, [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §6). Content never appears in logs (NFR-SEC-05). Notifications, links, and files need the custom image ([desktop-integration.md](../../02-design/desktop-integration.md) §2.4).

## Exit criteria

- [ ] #054, #080, #081, #082, #085, and #086 meet all their acceptance criteria, or a task is moved to a later milestone with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4).
- [ ] FR-INT-02, FR-INT-03, FR-INT-04, FR-INT-05, FR-INT-06, FR-INT-09, FR-VM-11 (the #085 part), FR-UI-05, NFR-SEC-02, and the #054, #081, and #082 parts of NFR-SEC-03 are covered by passing tests ([../traceability.md](../traceability.md) §2).
- [ ] The T0 and T1 suites pass on `main`. The T2 verifications of [desktop-integration.md](../../02-design/desktop-integration.md) §5.5, §6.5, §7.3, and §9 pass with the fixtures on a custom image that contains this milestone's Guest Agent.
- [ ] R-19 (the #054 part) and R-22 are not `open` in [../risks.md](../risks.md). #080 follows the R-21 result recorded by #053.
- [ ] The *verify* items of [guest-components.md](../../02-design/guest-components.md) §5 for this milestone are recorded in that table: the notification click on the requested display (#054) and `SET_TIME_ZONE` as shell (#085). The `Browser2` check (#081) and the shared-folder throughput (#082) are recorded in [desktop-integration.md](../../02-design/desktop-integration.md) §7.1 and §6.5.
- [ ] The FR-INT-03 row in [../traceability.md](../traceability.md) records the Firebase Cloud Messaging limit, and the app settings text of [desktop-integration.md](../../02-design/desktop-integration.md) §5.3 ("Runtime state") ships.
- [ ] The perf harness numbers are recorded for the milestone, including the notification latency and the provider throughput. No integration adds work to the launch path (NFR-PERF-01), and any regression is explained ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §9.4).
- [ ] [desktop-integration.md](../../02-design/desktop-integration.md) and [host-ui.md](../../02-design/host-ui.md) describe what was built. The v0.5 items "Notifications", "Clipboard", and "File integration" are marked delivered in [../roadmap.md](../roadmap.md) §3.5. v0.5 is checked and tagged after M11.

## Task order

1. #054 Notifications. **Start first.** Its R-19 check can change the launcher template.
2. #082 Files. **Parallel with #054.** Start early. It is the largest task.
3. #081 Links. **Parallel.**
4. #080 Image and HTML clipboard. **Parallel.**
5. #085 Locale, time zone, clock format, and time. **Parallel.**
6. #086 Menu bar. **Parallel.** It has no guest part.

All six tasks can run at the same time. #054, #080, #081, #082, and #085 all touch the same shared files: the Guest Agent manifest, `Guest/product/permissions/privapp-permissions-apkrun.xml`, the `.proto` files in `Packages/GuestProtocol/proto/`, the session channel DTOs in RuntimeAPI, the `IntegrationChannel` implementation in RuntimeCore, and the configuration push of [desktop-integration.md](../../02-design/desktop-integration.md) §3.2. Merge these changes in small pull requests. The platform-signed Guest Agent is updated only with the image ([guest-components.md](../../02-design/guest-components.md) §2), so each T2 run needs a custom image rebuilt with the current agent. #086 touches only `Apps/APKRunMenuBar/` and Settings → General.

---

## #054 Notifications

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #034, #035 (the Guest Agent in `PRIVILEGED_APP` mode), #047 |
| Requirements | FR-INT-03, NFR-SEC-03. Constraints: NFR-SEC-01 (notification content is untrusted input), NFR-SEC-05 (no titles or text in logs), NFR-SEC-07 (only the package's own wrapper gets the relay), NFR-OBS-01 (markers) |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §1, §2, §3.2, §5, §11–§15 (#054); [wrapper.md](../../02-design/wrapper.md) §4.2, §5.2, §5.8, §9.3, §9.4, §12.1; [guest-protocol.md](../../02-design/guest-protocol.md) §5.3, §7.1 (ops 41–43), §8.1, §8.4; [guest-components.md](../../02-design/guest-components.md) §4, §5, §6.1; [host-ui.md](../../02-design/host-ui.md) §7.2, §7.4; [runtime-daemon.md](../../02-design/runtime-daemon.md) §5.1, §7.2 |
| Modules / paths | `Packages/IntegrationCore/Sources/IntegrationCore/Notifications/` (`NotificationCoordinator`), `Packages/RuntimeHost/` (background start through `NSWorkspace`), `Packages/RuntimeAPI/` (relay DTOs), `Packages/RuntimeCore/` (`IntegrationChannel`), `Packages/GuestProtocol/proto/`, `Apps/APKRunLauncher/Integration/` (`NotificationPoster`), `Apps/APKRun/` (HostNotifier path, app page text), `Guest/guestd/` (`notifications/`), `Guest/product/permissions/`, `Tests/Fixtures/AndroidApps/hellonotification/`, `Tests/IntegrationTests/` |
| Risks / questions | R-19 (settled here with #076), R-18 (new privileged calls), R-09 (accepted: no Google push services). Open items: [desktop-integration.md](../../02-design/desktop-integration.md) §16, [../open-questions.md](../open-questions.md) |

### Goal

An Android notification from a managed app appears as a macOS notification of that app's Mac app, with the Mac app's name and icon. A click on it, or on one of its actions, brings the app to the front, or launches it, and delivers the Android intent. Dismissing on one side removes the notification on the other side.

### Scope

- Guest: `ApkRunNotificationListener` with the listener grant, the filters and the payload of §5.1, `SetNotificationForwarding`, `ActivateNotification` with the launch display, `DismissNotification`, the `Notification` fields 1–14, the replay after reconnect, and `HealthWarning(NOTIFICATION_LISTENER_DISABLED)`.
- Host: `NotificationCoordinator` routing (§5.3), the background start of a registered wrapper with its queue, the notification relay on the `.wrapper` endpoint, and the HostNotifier path for packages without a usable wrapper.
- Launcher: `NotificationPoster` with the mapping of §5.2, categories, the badge, authorization, `willPresent`, and the click handling of §5.4. Background mode ([wrapper.md](../../02-design/wrapper.md) §5.8).
- The app page text for denied authorization and for `closeBehavior = stop` ([host-ui.md](../../02-design/host-ui.md) §7.4).
- The R-19 check, before the rest of the host work.

Out of scope:

- Replies from the Mac (remote input), images in notifications, time-sensitive and critical alerts, and media controls (post-v1, [desktop-integration.md](../../02-design/desktop-integration.md) §16).
- Google Play services are not included. Apps that rely only on Firebase Cloud Messaging do not receive pushes while they are not running (R-09).
- The development-mode (stock image) agent. The listener stays disabled there ([guest-components.md](../../02-design/guest-components.md) §4.1).
- The wrapper refresh itself (#076). This task only checks that authorization survives it.

### Deliverables

- `Guest/guestd/` `notifications/` package: `ApkRunNotificationListener` and `NotificationBridge`, with Robolectric tests in `Guest/guestd/src/test/`.
- The privapp permission entries the listener grant and the background click need, in `Guest/product/permissions/privapp-permissions-apkrun.xml`.
- The `Notification` message fields, `NotificationPosted`, `NotificationRemoved`, and ops 41–43 in `Packages/GuestProtocol/proto/`.
- `NotificationCoordinator` in `Packages/IntegrationCore/Sources/IntegrationCore/Notifications/`, and the background-start adapter in RuntimeHost.
- The relay DTOs (`NotificationPayload`, `activated`, `dismissed`, `authorizationChanged`, `setBadge`) in RuntimeAPI ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md)).
- `NotificationPoster` and the background-mode entry in `Apps/APKRunLauncher/Integration/`.
- The HostNotifier path in APKRun.app, and the app page texts.
- The `hellonotification` fixture in `Tests/Fixtures/AndroidApps/` ([../../05-development/build-system.md](../../05-development/build-system.md) §8.1).
- T0, T1, and T2 tests. The R-19 result in [../risks.md](../risks.md) and [wrapper.md](../../02-design/wrapper.md) §5.8.

### Implementation steps

The design steps are [desktop-integration.md](../../02-design/desktop-integration.md) §14 #054, steps 1–4. Step 3 comes first here (step 1), because its result can change the launcher. Design step 1 is steps 2–3 here, step 2 is steps 4–7, and step 4 is step 8.

1. **Verify R-19 first (design step 3).** Build a launcher from the template that starts with `--apkrun-background notifications`, sets `NSApp.setActivationPolicy(.accessory)` in `applicationWillFinishLaunching`, and posts one test notification. Start it with `NSWorkspace.openApplication` and the configuration of [wrapper.md](../../02-design/wrapper.md) §5.8. Record screen video of the Dock on macOS 27. Then grant notification permission, refresh the wrapper (the `Contents` swap of [wrapper.md](../../02-design/wrapper.md) §9.3, or its prototype if #076 is not merged), and check that the permission is still granted. If the Dock tile flashes, use the fallback: `LSUIElement = true` in the template, and the launcher switches to `.regular` at every foreground start, shipped as a launcher refresh ([wrapper.md](../../02-design/wrapper.md) §9.4). Check: the result is written in R-19 and in [wrapper.md](../../02-design/wrapper.md) §5.8.
2. **Guest listener and filters (design step 1).** Add `ApkRunNotificationListener` (enabled only in `PRIVILEGED_APP` mode). At agent start, grant listener access with `setNotificationListenerAccessGranted`. If access is lost, send `HealthWarning(NOTIFICATION_LISTENER_DISABLED)` and grant again. Forward only packages in the `SetNotificationForwarding` list. Apply the §5.1 filter table: no group summaries; no ongoing, foreground-service, or `CATEGORY_TRANSPORT` notifications; no `MIN`, `NONE`, or blocked channels; updates with `FLAG_ONLY_ALERT_ONCE` go with `alert = false`. Build the payload: title up to 256 characters, text up to 2048 (the last `MessagingStyle` message, else `EXTRA_BIG_TEXT`, else `EXTRA_TEXT`), no images, no remote input. Check: the Robolectric filter tests pass.
3. **Guest operations (design step 1).** `SetNotificationForwarding` replaces the list and then replays every active forwarded notification with `replay = true`. `ActivateNotification(key, action_index?, display_id)` calls `PendingIntent.send` with `ActivityOptions` launch display = `display_id` and `setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)`. With no content intent, it sends `LaunchApplication(package, display_id)`. An unknown key answers `NOT_FOUND`. `DismissNotification(key)` calls `cancelNotification`. Removals send `NotificationRemoved(key, reason)`. Check: on the custom image, the activity started by a click appears on the requested display. Record this *verify* item in [guest-components.md](../../02-design/guest-components.md) §5.
4. **Host routing (design step 2).** `NotificationCoordinator` handles `NotificationPosted`. It asks `IntegrationPolicy.evaluate(.notifications, …)`, then looks up the package's wrapper with status `valid`. A connected wrapper gets `relay.post`. A registered wrapper that is not running is started in background mode through the RuntimeHost `NSWorkspace` adapter. Its notifications wait in a queue of at most 50 per package for up to 10 s, and after that they are dropped and counted. With no usable wrapper, APKRun.app posts it (HostNotifier). `NotificationRemoved` becomes `relay.remove`. After a reconnect, the replay rebuilds the key map and badge counts without new banners and removes Mac notifications whose Android notification is gone. Push `SetNotificationForwarding` after every handshake and on settings, install, and uninstall changes (§3.2). Unmanaged packages have notifications off. Check: the T0 routing tests pass with a fake channel and a fake wrapper registry.
5. **Relay (design step 2).** Add the `notificationRelay` stream on the `.wrapper` endpoint ([wrapper.md](../../02-design/wrapper.md) §12.1). Server → client: `post(NotificationPayload{identifier, threadID, title, body, sound, interruption, actions, badge})`, `remove([identifier])`, `setBadge(Int?)`. Client → server: `activated(identifier, actionIndex?)`, `dismissed(identifier)`, `authorizationChanged(UNAuthorizationStatus)`. A wrapper endpoint gets only its own package's notifications. Check: a T1 test with two wrapper endpoints shows that neither gets the other's notifications.
6. **`NotificationPoster` (design step 2).** In the launcher, map a payload as in §5.2. `identifier` is `"<package>|<first 16 hex of SHA-256(key)>"`. `threadIdentifier` is `"<package>/<group or channel>"`. The subtitle is empty for wrappers. `LOW` or `alert = false` is passive with no sound; `DEFAULT` and `HIGH` are active with the default sound. Up to 3 actions (`a0`–`a2`) go into a `UNNotificationCategory` keyed by a hash of the action titles, kept in an LRU of 32 per wrapper, with `.customDismissAction`. `userInfo` is `{package, keyDigest}`. `willPresent` while the window is key returns `[.list,.sound]` for `DEFAULT` and `[.banner,.list,.sound]` for `HIGH`. The badge is the active count (`NSApp.dockTile.badgeLabel` while running, `content.badge` when posting), cleared at 0. Ask for `.alert`, `.sound`, and `.badge` at the first foreground session of a package with notifications on, or when a background start finds `notDetermined`. Report the status with `authorizationChanged`. Check: T0 mapping, identifier stability, and category LRU tests pass.
7. **Click, HostNotifier, and texts (design step 2).** A click in background mode switches to `.regular`, continues at [wrapper.md](../../02-design/wrapper.md) §5.2 step 3, activates, and sends `activated` once the session is `running`. apkrund then sends `ActivateNotification` with the session's display. A dismiss sends `dismissed`, and apkrund sends `DismissNotification`. A background-mode launcher quits 30 s after the last delivered notification. For HostNotifier notifications, the subtitle is the app's display name, and a click runs `launch(packageID)` and then `ActivateNotification`. When authorization is `denied`, the app page says "Notifications for ‹App› are turned off in System Settings" with a button that opens the Notifications pane. With `closeBehavior = stop`, it says "‹App› can only notify you while it is running." Check: the T2 click cases of step 8 pass.
8. **Acceptance (design step 4).** Run the §5.5 verification with `HelloNotification`. Log with subsystem `io.apkrun.integration`, category `notifications` (the launcher uses `io.apkrun.wrapper`, category `integration`), never with titles or text. Emit `NOTIFICATION_DELIVERED`, and add the `integrations.notificationListener` health check ([desktop-integration.md](../../02-design/desktop-integration.md) §13). Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`, `Apps/APKRunLauncher` unit tests): the §5.1 filters and the §5.2 mapping, identifier stability, the category LRU, routing (connected, background start, queue overflow, 10 s timeout, HostNotifier), replay without banners, and the policy table for `.notifications`.
- **T1**: Kotlin Robolectric tests of the notification filter and the payload builder. XPC tests of the relay: only the own package, reconnect replay, and a denied-authorization report.
- **T2** (`Tests/IntegrationTests/`, custom image): the §5.5 verification with `io.apkrun.fixture.hellonotification`: plain, two-action, update, `LOW`, ongoing, and grouped notifications; click with the app closed (`keepRunning`) and with the window open; action buttons; dismiss in both directions; the switch off; the latency; and the R-19 checks.
- **T3**: none beyond the nightly run of T2.

### Acceptance criteria

- [ ] `HelloNotification` produces a native Mac notification, and a click on it returns the user to the Android app: the window opens, or comes to the front, and shows the notification's content intent.
- [ ] The posted Mac notification carries the package identity and an action token (`userInfo` `{package, keyDigest}`), and a click on a Mac notification whose Android notification is gone opens the app normally.
- [ ] Each notification appears under `HelloNotification.app` with the wrapper icon. The ongoing notification and the group summary do not appear. The `LOW` one is silent.
- [ ] Action buttons deliver the matching Android action intent.
- [ ] Dismissing on the Mac removes the notification in Android, and removing it in Android removes it on the Mac. The Dock badge shows the active count.
- [ ] With `integrations.notifications = false`, nothing leaves the guest (the agent's forwarded counter stays 0).
- [ ] Latency from `notify` to the Mac banner is p50 ≤ 1 s with the wrapper running and ≤ 3 s with a background start.
- [ ] No Dock tile flashes in background mode, and the permission survives a wrapper refresh. R-19 is recorded.
- [ ] A package without a usable wrapper gets its notifications through APKRun.app, and a click launches it with the generic launcher.
- [ ] No log line contains a notification title or text (NFR-SEC-05).

### Notes

- **Record:** the R-19 result in [../risks.md](../risks.md) and [wrapper.md](../../02-design/wrapper.md) §5.8. The background activity start result in [guest-components.md](../../02-design/guest-components.md) §5.
- **Pitfall:** the listener runs in the agent process. A crash in a notification from a hostile app must not stop the agent. Treat every field as untrusted, apply the length limits before building the message, and catch parsing errors per notification.
- **Pitfall:** the category LRU must never evict a category that a notification still on screen uses. Otherwise its buttons disappear.
- **Pitfall:** the badge and the replay must not post banners after a runtime restart. Test this with a restart while three notifications are active.
- The background start and `launch(packageID)` use one `NSWorkspace` adapter in RuntimeHost, `WorkspaceOpener`, injected into `NotificationCoordinator`, because IntegrationCore must not use AppKit ([../../01-architecture/modules.md](../../01-architecture/modules.md) §2). #081 injects the same adapter into `LinkForwarder` ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §7.2).

---

## #080 Image and HTML clipboard

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #053 |
| Requirements | FR-INT-02. Constraints: NFR-SEC-01 (image data from Android is untrusted), NFR-SEC-03 (same policy as text), NFR-SEC-05 (no clipboard content in logs) |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §3.3, §4, §13, §14 (#080), §15; [guest-protocol.md](../../02-design/guest-protocol.md) §5.3 (`clipboard.image.v1`, `bulk.v1`), §7.1 (op 40), §8.4 (`ClipData`), §10; [input.md](../../02-design/input.md) §6; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §4.9, §4.10 |
| Modules / paths | `Packages/IntegrationCore/Sources/IntegrationCore/Clipboard/` (`ClipboardCoordinator`), `Packages/RuntimeAPI/` (`ClipItem`), `Packages/GuestProtocol/proto/`, `Apps/APKRunLauncher/Integration/` (`PasteboardAdapter`), `Guest/guestd/` (`clipboard/`, the agent `FileProvider`), `Tests/Fixtures/AndroidApps/helloclipboard/`, `Tests/IntegrationTests/` |
| Risks / questions | R-21 (settled by #053; the focus push of images follows its result). Open items: [desktop-integration.md](../../02-design/desktop-integration.md) §16 |

### Goal

The clipboard carries HTML and PNG images in both directions, with the same focus rules and loop prevention as plain text. A Mac screenshot pastes into an Android image view. An image copied in Android pastes into a Mac app. HTML keeps its formatting in a rich-text field and falls back to plain text elsewhere.

### Scope

- `public.html` ↔ `ClipData.newHtmlText` with its plain text, up to 1 MiB.
- `public.png`, and `public.tiff` converted to PNG on the host ↔ a `content://` URI from the agent's `FileProvider` with a PNG and MIME `image/png`. Up to 16 MiB encoded and 8192 px per side. Images travel over the bulk stream.
- The `ClipData` image field (`ClipImage{mime_type, width, height, transfer_id}`) and the `clipboard.image.v1` capability.
- The digest over the image bytes for loop prevention, and the `io.apkrun.clip-origin` marker on written images.

Out of scope:

- Files, URLs as files, and RTF. RTF falls back to its plain text ([desktop-integration.md](../../02-design/desktop-integration.md) §4.4).
- Plain text, the policy, the ⌘V ack, and the text loop tests (#053, M4).
- Animated images. Only the first frame is kept when a GIF or HEIC is re-encoded to PNG.

### Deliverables

- The HTML and image fields of `ClipItem` in RuntimeAPI, and of `ClipData` in `Packages/GuestProtocol/proto/`.
- `ClipboardCoordinator` size rules and the bulk transfer of images, in `Packages/IntegrationCore/Sources/IntegrationCore/Clipboard/`.
- `PasteboardAdapter` reading and writing `public.html`, `public.png`, and `public.tiff`, in `Apps/APKRunLauncher/Integration/`.
- In `Guest/guestd/`: `ClipboardBridge` image and HTML support, and the agent `FileProvider` (authority `io.apkrun.guest.files`) that serves image clips.
- An image view and a rich-text field in the `helloclipboard` fixture.
- T0, T1, and T2 tests.

### Implementation steps

The design steps are [desktop-integration.md](../../02-design/desktop-integration.md) §14 #080, steps 1–2. Step 1 is split into steps 1–4 here, and step 2 is step 5.

1. **Messages and DTOs (design step 1).** Add `html` and `image` to `ClipData` and `ClipItem`. The image in `ClipItem` is the PNG bytes as `Data`, at most 16 MiB, so a clip fits the 32 MiB XPC message limit ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §4.10). Advertise `clipboard.image.v1`. The agent answers image operations without it with `UNSUPPORTED`. Check: T0 codec round trips pass, and a guest without the capability gets text only.
2. **Mac → Android (design step 1).** `PasteboardAdapter` reads, in order, `public.utf8-plain-text`, `public.html`, then `public.png` or `public.tiff`. It converts TIFF to PNG with ImageIO. If HTML has no plain text next to it, it derives the plain text from the HTML. It checks the limits before sending. An image over 16 MiB or 8192 px per side is left out, the text and HTML still go, and `ClipAck` carries `clipboardTooLarge(bytes:limit:)` so the window shows the catalog message ([../../03-reference/error-catalog.md](../../03-reference/error-catalog.md)). apkrund sends the image as a host bulk transfer, then `SetClipboard` with `image.transfer_id`. The agent stores it in its cache, serves it through the `FileProvider`, and sets `ClipDescription` MIME `image/png`. The digest covers the image bytes. Check: T0 limit tests pass, and a TIFF screenshot arrives as a PNG.
3. **Android → Mac (design step 1).** When the primary clip has an image URI, `ClipboardBridge` opens it and checks the bounds first (`BitmapFactory.Options.inJustDecodeBounds`). A PNG within the limits is sent as is. Other formats are decoded and re-encoded to PNG. The agent sends it as an agent bulk transfer and then `ClipboardChanged` with `image.transfer_id`. apkrund receives it into `~/Library/Caches/io.apkrun.APKRun/transfers/`, checks it, reads it into the `ClipItem`, and deletes the temp file. `PasteboardAdapter` writes `public.png` plus the text and HTML types and the `io.apkrun.clip-origin` marker. Check: T1 shows the temp file is gone after the event.
4. **Loop prevention and rules (design step 1).** The three signals of §4.4 apply to images and HTML: `origin` and `seq`, the SHA-256 digest (over normalized text, or over the image bytes), and the marker. `TransientType` items go only on a paste. `ConcealedType` sets `sensitive`. With R-21 realized, only ⌘V pushes images. Check: the T0 loop test with an image passes (no extra `changeCount` changes).
5. **Acceptance (design step 2).** Run the T2 test below. Log only sizes, types, and truncated digests (§13). Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): size and pixel limits, image digest and loop prevention with a simulated pasteboard and agent, HTML without plain text, and the ⌘V fallback when the image is too large.
- **T1**: Kotlin Robolectric tests of `ClipboardBridge` with images (bounds check, re-encode, echo suppression). A host test of the bulk temp file cleanup.
- **T2** (`Tests/IntegrationTests/`, custom image): the acceptance checks below with `io.apkrun.fixture.helloclipboard`.

### Acceptance criteria

- [ ] A screenshot copied on the Mac with ⌘⌃⇧4 pastes into HelloClipboard's image view.
- [ ] An image copied in the fixture pastes into Preview with File → New from Clipboard.
- [ ] HTML copied in Safari pastes as formatted text into an Android rich-text field and as its plain text into a plain field.
- [ ] An image over 16 MiB or over 8192 px per side is not sent. The text still goes, and the window shows the limit message.
- [ ] Images and HTML do not bounce between two windows (the #053 loop test with image copies passes).
- [ ] With `integrations.clipboard = false`, no image or HTML moves in either direction.
- [ ] No image bytes or HTML content appear in logs or diagnostics, and no image temp file remains after a transfer.

### Notes

- **Pitfall:** decode Android images only after the bounds check. A small file can declare a huge bitmap.
- **Pitfall:** a Mac pasteboard item often has both TIFF and PNG. Prefer PNG so nothing is re-encoded.
- Carrying the image as `Data` inside `ClipItem` is a choice of this plan. [desktop-integration.md](../../02-design/desktop-integration.md) §3.3 does not say how an image crosses XPC, and [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §4.9 allows `FileHandle` only from client to apkrund, so the event direction cannot use a handle.

---

## #081 Links

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #034, #035 (the Guest Agent in `PRIVILEGED_APP` mode), #047 |
| Requirements | FR-INT-04, NFR-SEC-03. Constraints: NFR-SEC-01 (URLs from Android are untrusted), NFR-SEC-05 (no full URLs in logs), NFR-SEC-07 (prompts only to the package's own window) |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §2, §3.2, §3.3, §7, §11–§15 (#081); [guest-protocol.md](../../02-design/guest-protocol.md) §5.3 (`url.v1`), §7.1 (ops 44, 50), §8.1 (event 43); [guest-components.md](../../02-design/guest-components.md) §4.1, §5; [android-image.md](../../02-design/android-image.md) §11.2; [host-ui.md](../../02-design/host-ui.md) §7.4 |
| Modules / paths | `Packages/IntegrationCore/Sources/IntegrationCore/Links/` (`LinkForwarder`), `Packages/RuntimeHost/` (URL opener), `Packages/RuntimeAPI/` (`LinkPrompt`, `LinkChoice`), `Packages/GuestProtocol/proto/`, `Apps/APKRunLauncher/Integration/` (link prompt sheet), `Guest/guestd/` (`url/`), `Guest/product/`, `Tests/Fixtures/AndroidApps/hellolinks/`, `Tests/IntegrationTests/` |
| Risks / questions | R-18 (browser role on the image). Open items: [desktop-integration.md](../../02-design/desktop-integration.md) §16 (Mac → Android links, post-v1), [../open-questions.md](../open-questions.md) |

### Goal

A link that an Android app opens goes to the Mac's default browser or mail app, after the user agrees once per app. Links that would harm the user or that come from background work are dropped. Apps that need their browser inside Android, for example for sign-in, can keep their links there.

### Scope

- Guest: `UrlRedirectActivity` with the browser role, for `ACTION_VIEW` `http` and `https`, and `ACTION_SENDTO` and `ACTION_VIEW` `mailto`. Custom Tabs. `OpenUrlOnHost`, the kept intent for 60 s, `SetUrlRedirect`, and `ResolveUrl`. `HealthWarning(BROWSER_ROLE_LOST)`.
- The `Browser2` check in the image, and adding it to the product if missing ([android-image.md](../../02-design/android-image.md) §11.2).
- Host: `LinkForwarder` with validation, the focus rule, the rate limit, the `links` setting, and the link prompt on the session channel.
- The app page control **Ask** / **Open in Mac browser** / **Open in Android** ([host-ui.md](../../02-design/host-ui.md) §7.4) writes `integrations.links`.

Out of scope:

- Mac → Android links, and Mac-side handling of custom schemes such as `myapp://callback` (post-v1, [wrapper.md](../../02-design/wrapper.md) §2.1).
- Android App Links. Android resolves them first, inside Android.
- The development-mode agent. The URL handler stays disabled on the stock image.

### Deliverables

- In `Guest/guestd/`: the `url/` package with `UrlRedirectActivity` and `UrlRedirect`, and the manifest filter with `mailto`.
- The privapp permission entry for `MANAGE_ROLE_HOLDERS`, and `Browser2` in the product if the check needs it.
- Ops 44 and 50 and event 43 in `Packages/GuestProtocol/proto/`.
- `LinkForwarder` in `Packages/IntegrationCore/Sources/IntegrationCore/Links/`, with an injected URL opener implemented in RuntimeHost.
- `LinkPrompt`, `LinkChoice`, `linkPrompt`, and `resolveLinkPrompt` in RuntimeAPI.
- The link prompt sheet in `Apps/APKRunLauncher/Integration/`.
- The `hellolinks` fixture, and T0 and T2 tests.

### Implementation steps

The design steps are [desktop-integration.md](../../02-design/desktop-integration.md) §14 #081, steps 1–3. Step 1 is split into steps 1–3 here, step 2 is steps 4–5, and step 3 is step 6.

1. **Browser2 check (design step 1).** Check whether the product image includes AOSP `Browser2`. If it does not, add it ([android-image.md](../../02-design/android-image.md) §11.2). Check: the result is recorded in [desktop-integration.md](../../02-design/desktop-integration.md) §7.1, and `cmd package resolve-activity` for an `https` `VIEW` intent lists `Browser2` when the redirect is off.
2. **Redirect activity (design step 1).** Add `UrlRedirectActivity` (enabled only in `PRIVILEGED_APP` mode) with the `http`, `https`, and `mailto` filters. At agent start, take `ROLE_BROWSER` with `RoleManager.addRoleHolderAsUser`. If the role is lost, send `HealthWarning(BROWSER_ROLE_LOST)` and take it again. The activity sends `OpenUrlOnHost(request_id, url, source_package, display_id)` and keeps the intent for 60 s. For packages in `excluded_packages`, it passes the intent to the in-Android browser directly and sends nothing. With `SetUrlRedirect(enabled = false)`, all links stay in Android. Check: a verified App Link for an installed app still opens that app in Android.
3. **`ResolveUrl` (design step 1).** `OPEN_IN_GUEST` starts the kept intent in the in-Android browser on the same display. `OPENED_ON_HOST` and `DROP` finish it. An expired request answers `NOT_FOUND`. Without an in-Android browser, the host does not offer "Keep in Android". Check: T2 "Keep in Android" opens `Browser2` on the app's display.
4. **`LinkForwarder` (design step 2).** Validate with `URLComponents`: the scheme is `http`, `https`, or `mailto`; the length is at most 8 KiB; `http` and `https` need a host. Anything else is `ResolveUrl(DROP)` and counted. The app's window must be key, or have had user input in the last 5 s. At most 3 links per 10 s per package. `links = mac` opens the URL with the injected `WorkspaceOpener` (default browser or mail app) and answers `OPENED_ON_HOST`. `links = android` answers `OPEN_IN_GUEST`. Push `SetUrlRedirect(enabled = global links switch, excluded_packages = packages with links = android or links off)` after every handshake and on settings changes (§3.2). Check: the T0 validation and rate tests pass, including IDN hosts, `javascript:`, `intent:`, and URLs over 8 KiB.
5. **Link prompt (design step 2).** For `links = ask`, send `linkPrompt(LinkPrompt{promptID, host or address, scheme})` to the window. The sheet says "‹App› wants to open ‹example.com›." with **Open in Browser**, **Keep in Android**, **Cancel**, and "Remember for ‹App›". It shows the host in Unicode with the registrable domain in bold, and never the path or query. When the path contains `oauth`, `authorize`, or `login`, it shows the hint "Signing in? Keep links from ‹App› in Android". Remember writes `integrations.links = mac` or `android`. No answer in 60 s counts as Cancel. Check: a UI test of the sheet with an IDN host passes.
6. **Acceptance (design step 3).** Run the §7.3 verification. Log only the scheme and the registrable domain, at debug level (§13). Add the `integrations.browserRole` health check. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): URL validation and rate limits (§7.2), including IDN hosts, `javascript:`, `intent:`, and over-long URLs. The focus and 5 s input rule. The prompt text: Unicode host, bold registrable domain, no path or query, the sign-in hint. The `SetUrlRedirect` list.
- **T1**: an XPC test of `linkPrompt` and `resolveLinkPrompt`, including the 60 s timeout with a shortened test clock.
- **T2** (`Tests/IntegrationTests/`, custom image): the §7.3 verification with `io.apkrun.fixture.hellolinks`: `https`, `mailto`, a Custom Tab, `javascript:`, `intent:`, and a background link.

### Acceptance criteria

- [ ] With `ask`, the first link shows the prompt. **Open in Browser** with Remember opens it in the default browser, and later links open without a prompt.
- [ ] **Keep in Android** opens the in-Android browser on the app's display.
- [ ] `mailto` opens the default Mac mail app.
- [ ] `javascript:` and `intent:` URLs are dropped. A link opened from a timer after the window lost focus is dropped.
- [ ] With the global links switch off, all links stay in Android.
- [ ] A fourth link within 10 s from the same app is dropped.
- [ ] The prompt never shows a URL path or query, and logs never contain a full URL (NFR-SEC-05).
- [ ] The `Browser2` result is recorded in [desktop-integration.md](../../02-design/desktop-integration.md) §7.1.

### Notes

- **Pitfall:** a URL can look safe in one parser and not in another. Validate and open the same `URL` value. Never re-parse the original string after validation.
- **Pitfall:** the browser role is a single-holder role. If `Browser2` also claims it, the agent must keep the role, or links bypass the host.
- The bold registrable domain needs a Public Suffix List. Use the same helper as the log redactor ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §6), or add a pinned snapshot of the list to `ThirdParty/ThirdParty.lock.json`. The design does not say where the list comes from.
- The sign-in keyword match is case-insensitive.
- With the redirect on and no in-Android browser, a link from an app with `links = android` has nowhere to go. It is dropped and counted.

---

## #082 Files

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #034, #035 (the Guest Agent in `PRIVILEGED_APP` mode) |
| Requirements | FR-INT-05, FR-INT-06, NFR-SEC-02, NFR-SEC-03. Constraints: NFR-SEC-01 (every agent request is hostile until checked; fuzzing in #091), NFR-SEC-05 (no file names or contents in logs), NFR-SEC-07 (offers go only to the package's own window) |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §2, §3, §6, §11–§15 (#082); [guest-protocol.md](../../02-design/guest-protocol.md) §5.3 (`files.v1`, `files.shared.v1`), §7.1 (ops 45, 51, 52), §7.5, §8.1 (event 44), §10, §14; [guest-components.md](../../02-design/guest-components.md) §4, §5, §6.1; [host-ui.md](../../02-design/host-ui.md) §7.4, §9.5; [wrapper.md](../../02-design/wrapper.md) §4.3; [../../03-reference/configuration.md](../../03-reference/configuration.md) §1.4, §2.8; [cli.md](../../02-design/cli.md) §4.5; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §6 |
| Modules / paths | `Packages/IntegrationCore/Sources/IntegrationCore/Files/` (`FileTransferService`, `SharedFolderService`), `Packages/RuntimeAPI/`, `Packages/RuntimeCore/`, `Packages/GuestProtocol/proto/`, `Apps/APKRunLauncher/Integration/` (`DropTarget`, save panel), `Apps/APKRun/` (Settings → Files), `CLI/apkrun/` (`shared-folders`), `Guest/guestd/` (`files/`), `Guest/product/permissions/`, `Tests/Fixtures/AndroidApps/hellofiles/`, `Tests/IntegrationTests/` |
| Risks / questions | R-22 (settled here), R-18. Open items: [desktop-integration.md](../../02-design/desktop-integration.md) §16, [../open-questions.md](../open-questions.md) |

### Goal

The user can drop files on an app's window, and the app receives them as a share. An Android app can save a file to the Mac through a Save panel. Android apps with the setting on can open files in the APKRun Shared folder and in folders the user added, through Android's file picker, with read-only access unless the user chose read and write. Android never sees the home folder, and every file that leaves Android is quarantined.

### Scope

- Drag and drop (§6.2): `DropTarget`, `importFiles`, bulk transfers, `ImportFiles(SHARE_TO_PACKAGE, package, display_id)`, the share or the Downloads fallback, and the 24 h cache cleanup.
- Save to Mac (§6.3): `SaveToMacActivity`, `ExportFileOffered`, `exportOffered`, the Save panel sheet, `acceptExport`, `ResolveExport`, size and SHA-256 checks, quarantine, and partial-file cleanup.
- Shared folders (§6.4): `SharedFolderService`, the host operations 60–69, `MacFilesProvider` with proxy file descriptors, `SetSharedFolderAccess`, the roots with bookmarks, Settings → Files, the app page row, the API of §11, and `apkrun shared-folders`.
- The R-22 check of privacy prompts for user-added folders.

Out of scope:

- A directory share (virtio-fs). It is not used ([desktop-integration.md](../../02-design/desktop-integration.md) §6.1).
- Drops of folders or promised files, drops at a position (`DragEvent`), and a folder chooser for many saved items are post-v1. A drop arrives as a share.
- Fuzzing the host operations (#091). This task provides the malicious-agent test build that #091 extends.

### Deliverables

- `FileTransferService` and `SharedFolderService` in `Packages/IntegrationCore/Sources/IntegrationCore/Files/`.
- `ImportFileInfo`, `ImportTarget`, `ImportResult`, `ExportOffer`, the session channel calls, and the §11 operations (`sharedFolders`, `addSharedFolder`, `removeSharedFolder`, `setSharedFolderAccess`, topic `integrations` event `sharedFoldersChanged`) in RuntimeAPI.
- Ops 45, 51, 52, 60–69 and event 44 in `Packages/GuestProtocol/proto/`.
- `DropTarget`, the Save panel sheet, and quarantine in `Apps/APKRunLauncher/Integration/`.
- In `Guest/guestd/` `files/`: `FilesBridge`, the agent `FileProvider` (authority `io.apkrun.guest.files`), `SaveToMacActivity`, and `MacFilesProvider` (authority `io.apkrun.guest.macfiles`).
- Settings → Files and the shared-folder row on the app page in `Apps/APKRun/` ([host-ui.md](../../02-design/host-ui.md) §9.5, §7.4).
- `apkrun shared-folders list|add|remove` and `apkrun integrations status` in `CLI/apkrun/` ([cli.md](../../02-design/cli.md) §4.5).
- The `hellofiles` fixture, a second fixture package for the URI test, and a malicious-agent test build.
- T0, T1, and T2 tests. The R-22 result.

### Implementation steps

The design steps are [desktop-integration.md](../../02-design/desktop-integration.md) §14 #082, steps 1–4. Step 1 is step 1 here, step 2 is step 2, step 3 is steps 3–7, and step 4 is step 8.

1. **Drag and drop (design step 1).** `DropTarget` on the session view accepts file URLs only: no folders and no promised files. It refuses more than 20 files, a file over 2 GiB, or more than 4 GiB in total, with a message. The window opens each file for reading and calls `importFiles([FileHandle], [ImportFileInfo{name, size, uti}],.shareToApp)`. apkrund checks `.files` for the session's package, sends the files as host bulk transfers (never reading a whole file into memory), then `ImportFiles(SHARE_TO_PACKAGE, package, display_id, files)`. `FilesBridge` stores them in its cache, serves them through its `FileProvider`, and sends `ACTION_SEND` or `ACTION_SEND_MULTIPLE` with `FLAG_GRANT_READ_URI_PERMISSION` to the package on `display_id`. If the package has no share target, it inserts them into `MediaStore.Downloads` and shows "Saved to Downloads". Cached files are deleted after 24 h or at uninstall. Check: T2 drops three files, one of 1.5 GiB, with the right hashes.
2. **Save to Mac (design step 2).** `SaveToMacActivity` is a chooser target for `ACTION_SEND` and `SEND_MULTIPLE`, with at most 20 items. It reads the name, MIME type, and size, and sends `ExportFileOffered(offer_id, name, mime_type, size, source_package, display_id)`. apkrund checks `.files` for `source_package` and sends `exportOffered` to the window of the session on `display_id`. With no such window it answers `ResolveExport(DECLINE)`. The window shows an `NSSavePanel` sheet, default folder `~/Downloads`, with the name sanitized as in [wrapper.md](../../02-design/wrapper.md) §4.3 plus an extension from the MIME type when the name has none. One panel per item. Save calls `acceptExport(offerID, FileHandle)` with an empty file opened for writing; Cancel calls `acceptExport(offerID, nil)`. apkrund answers `ResolveExport(ACCEPT)`, writes the bulk stream to the handle, and checks size and SHA-256. The window sets `com.apple.quarantine` with the agent name "‹App› (APKRun)" and deletes the file if the transfer failed. Check: the T2 Save to Mac case passes with the right hash and a quarantine attribute.
3. **Roots and settings (design step 3).** The roots are `~/Library/Application Support/APKRun/Shared/` and the folders the user adds. `sharedFolders.roots` stores `{id, bookmark, access}` for at most 32 roots, and only the shared-folder operations change it ([../../03-reference/configuration.md](../../03-reference/configuration.md) §1.4, §2.8). `addSharedFolder` refuses the volume root, the home folder itself, `~/Library` and any folder inside it, hidden folders or any folder inside one (such as `~/.ssh`), and a 33rd folder, with `IntegrationFailure.folderRefused` (the refused roots of [desktop-integration.md](../../02-design/desktop-integration.md) §6.4). Settings → Files shows the Shared folder first with **Show in Finder**, the user folders with their maximum access and availability, **Add Folder…** (an open panel whose result goes to `addSharedFolder` as a bookmark), and **Remove**. The CLI `shared-folders add <path> [--read-write]` creates the bookmark itself, and `remove` takes a path or an ID. The effective access for a package is the lower of the root's and `integrations.sharedFolders`. Push `SetSharedFolderAccess` after every handshake and on every change. Check: the T1 refused-roots test passes.
4. **`SharedFolderService` (design step 3).** For every host operation, check in order: the calling package's effective access for the root (`readWrite` for writes); the path is relative, has no `..` component, and is resolved with `openat` from the root's directory descriptor with `O_NOFOLLOW` on each component; only regular files and directories, with hidden files and packages (`.app`, `.photoslibrary`) neither listed nor opened; the limits of 4096 entries per page, 1 MiB per read or write, 64 open handles per package (`RESOURCE_EXHAUSTED`), and 16 requests in flight. Close all handles when the runtime stops. Files written by Android get `com.apple.quarantine`. Check: the T0 decision tests and the T1 confinement tests on a real temporary tree pass (`..`, absolute paths, symlink escapes, hidden files, packages, read-only writes).
5. **`MacFilesProvider` (design step 3).** A `DocumentsProvider` (enabled only in `PRIVILEGED_APP` mode) with one root per Mac folder. `openDocument` and every write check `getCallingPackage` against the `SetSharedFolderAccess` list. A package without access gets `SecurityException("Blocked by APKRun settings")`. Browsing from `com.android.documentsui` lists names only. File contents are served with `StorageManager.openProxyFileDescriptor`, so reads and writes become `HostReadRange` and `HostWriteRange`. `ACTION_CREATE_DOCUMENT` works only in `readWrite` roots. Document IDs are `<root_id>:<relative path>`. Check: the Robolectric access tests pass with a fake host.
6. **Privacy prompts, R-22 (design step 3).** Add a folder inside Desktop, Documents, Downloads, iCloud Drive, and on a removable volume. Check whether apkrund's first read shows a macOS prompt for APKRun, and what a denial looks like. A denied root shows as unavailable in the picker and in Settings with "Can't access. Allow APKRun in System Settings → Privacy & Security → Files and Folders." If the prompt is missing or attributed to the wrong app, use the R-22 fallback: security-scoped bookmarks created by APKRun.app through the open panel, and Settings → Files explains how to allow access. Check: the result is written in R-22.
7. **API, CLI, and health (design step 3).** Implement `integrationStatus(packageID)` and the shared-folder operations of §11, the `integrations.sharedFolders` health check, and the `FILE_TRANSFER` marker. Errors are `IntegrationFailure` cases of §12: `tooManyFiles`, `fileTooLarge`, `transferFailed`, `folderUnavailable(.missing/.privacyDenied/.offline)`, `pathRejected(.outsideRoot/.hidden/.notRegularFile)`, and `readOnly`. Check: `apkrun shared-folders add` of a refused root fails with a clear message, and `apkrun integrations status <package>` shows the effective access.
8. **Acceptance (design step 4).** Run the §6.5 verification and the malicious-agent test. Measure the provider throughput. Check: every acceptance criterion is checked, and the throughput is recorded in [desktop-integration.md](../../02-design/desktop-integration.md) §6.5.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): `SharedFolderService` decisions: `..`, absolute paths, hidden files, packages, read-only writes, effective access, handle limits. Drop limits. Name sanitizing with MIME extensions.
- **T1**: path confinement on a real temporary tree, with symlinks inside and outside the root. Refused roots for `addSharedFolder`. Quarantine on written files. Kotlin Robolectric tests of `MacFilesProvider` access checks with a fake host.
- **T2** (`Tests/IntegrationTests/`, custom image): the §6.5 verification with `io.apkrun.fixture.hellofiles`, and a malicious-agent build that sends out-of-root paths, too many handles, and oversized ranges (extended into fuzzing by #091).
- **T3** (`Tests/AcceptanceTests/`, reference Mac): the R-22 privacy prompt check with a user folder in Documents.

### Acceptance criteria

- [ ] Three files dropped on the window, one of them 1.5 GiB, arrive in the fixture with the right SHA-256. With `integrations.files = false`, the drop is refused.
- [ ] A drop on an app without a share target saves the files to Android Downloads and shows "Saved to Downloads".
- [ ] "Save to Mac" from the fixture writes the file where the Save panel said, with the right hash and a quarantine attribute. A failed transfer leaves no partial file.
- [ ] With `sharedFolders = readOnly`, the fixture can pick and read files in the Shared folder, cannot create or change them, and cannot open a symlink in the folder that points outside the root.
- [ ] With `sharedFolders = off`, opening a previously granted URI fails.
- [ ] A second fixture package without access cannot open a URI that was granted to the first one and then passed to it.
- [ ] Android never sees the home folder. `addSharedFolder` refuses the home folder, `~/Library`, and hidden folders such as `~/.ssh`, and no root other than the Shared folder exists until the user adds one (NFR-SEC-02).
- [ ] Reading a 1 GiB file through the provider reaches at least 200 MB/s, or the measured value replaces the provisional target in §6.5 with the reason.
- [ ] R-22 is recorded, and the fallback is in place if it was needed.
- [ ] No file names or contents appear in logs (NFR-SEC-05).

### Notes

- **Record:** the R-22 result in [../risks.md](../risks.md) and [desktop-integration.md](../../02-design/desktop-integration.md) §6.4. The throughput in §6.5.
- **Pitfall:** check every host request again in apkrund. The agent's checks are a convenience; a compromised agent can send anything (NFR-SEC-01).
- **Pitfall:** a security-scoped bookmark gives its scope only to the app that created it. Before choosing the R-22 fallback, check whether apkrund can use a bookmark that APKRun.app created.
- **Pitfall:** `openProxyFileDescriptor` runs its callbacks on a handler thread. A slow host read blocks the Android app's read, so keep up to 4 reads of 1 MiB ahead per handle for sequential reads.
- The refused roots of step 3 are a choice of this plan. NFR-SEC-02 forbids exposing these folders automatically, and the design does not list the roots that `addSharedFolder` refuses. A refused root is reported as a new reason `pathRejected(.protectedLocation)`.

---

## #085 Locale, time zone, clock format, and time

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #034, #035 (the Guest Agent in `PRIVILEGED_APP` mode), #069 |
| Requirements | FR-INT-09, FR-VM-11. Constraints: NFR-PERF-01 (no locale push on the launch path), NFR-OBS-02 (health warnings) |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §2.2, §2.4, §3.2, §9, §13, §14 (#085), §15; [guest-protocol.md](../../02-design/guest-protocol.md) §5.3 (`locale.v1`), §7.1 (ops 46–49), §7.2; [guest-components.md](../../02-design/guest-components.md) §5, §6.1; [runtime-daemon.md](../../02-design/runtime-daemon.md) §5.3, §6; [android-image.md](../../02-design/android-image.md) §11.2; [host-ui.md](../../02-design/host-ui.md) §9.6; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.9 |
| Modules / paths | `Packages/IntegrationCore/Sources/IntegrationCore/Locale/` (`LocaleTimeSync`), `Packages/RuntimeCore/`, `Packages/GuestProtocol/proto/`, `Apps/APKRun/` (Settings → Language & Region), `Guest/guestd/` (`locale/`, `LocaleTimeService`), `Tests/IntegrationTests/`, `Tests/AcceptanceTests/` |
| Risks / questions | R-18 (the privileged setters). Open items: [desktop-integration.md](../../02-design/desktop-integration.md) §16 (per-app languages and dark mode, post-v1), [../open-questions.md](../open-questions.md) |

### Goal

Android uses the Mac's languages, region, time zone, and 12/24-hour setting, and follows changes while it runs. The guest clock stays within 1 s of the Mac, and within 2 s after the Mac wakes.

### Scope

- `LocaleTimeSync`: the host sources of §9, the change notifications, the triggers, and change-only pushes of `SetLocale`, `SetTimeZone`, and `SetClockFormat`.
- The time zone fallback to `Etc/GMT∓h` with a health warning.
- `SyncTime` triggers that #069 did not add: post-boot, every 30 min while `ready`, and after `NSSystemClockDidChange`.
- The `system.syncLocale`, `system.syncTimeZone`, and `system.syncClockFormat` switches, and Settings → Language & Region ([host-ui.md](../../02-design/host-ui.md) §9.6).
- The `integrations.time` health check.

Out of scope:

- `SyncTime` after resume and wake, and the ADB fallback on the stock image (#069, M4).
- Per-app languages and dark mode sync (post-v1).
- New tzdata. It comes with image updates (#087).

### Deliverables

- `LocaleTimeSync` in `Packages/IntegrationCore/Sources/IntegrationCore/Locale/`.
- Ops 46, 47, and 49 in `Packages/GuestProtocol/proto/`, and their handlers in `LocaleTimeService` in `Guest/guestd/`.
- The privapp permission entries for `CHANGE_CONFIGURATION`, `SET_TIME_ZONE`, and `SET_TIME` if they are not present.
- Settings → Language & Region in `Apps/APKRun/`, if the Settings window does not have it yet.
- T0, T2, and T3 tests. The `SET_TIME_ZONE` shell result in [guest-components.md](../../02-design/guest-components.md) §5.

### Implementation steps

The design steps are [desktop-integration.md](../../02-design/desktop-integration.md) §14 #085, steps 1–2. Step 1 is split into steps 1–4 here, and step 2 is step 5.

1. **Host sources (design step 1).** Languages: `Locale.preferredLanguages`, with the region of `Locale.current` added to the first tag when it has none, at most 8 tags, passed through as BCP 47 with script subtags kept (`zh-Hans`, `sr-Latn`). Time zone: `TimeZone.current.identifier`. 12/24-hour: the `DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale:.current)` result contains `a` → `TWELVE`, otherwise `TWENTY_FOUR`. Use `Locale.autoupdatingCurrent`, and call `TimeZone.resetSystemTimeZone` before reading the time zone after a change. Check: T0 tag mapping tests pass, including a first tag without a region and script subtags.
2. **Triggers and pushes (design step 1).** Push after post-boot setup and after every reconnect, and on `NSLocale.currentLocaleDidChangeNotification` and `NSSystemTimeZoneDidChange`. Each item is pushed only when its `system.sync*` switch is on. The agent compares with the current Android value and does nothing when they are equal, because a locale change restarts activities. A locale push never runs on the launch path: a change that arrives during a launch waits until the session is `running`. Label changes from the new locale give wrappers a `.displayName` refresh reason ([wrapper.md](../../02-design/wrapper.md) §9.1). Check: T0 shows that an unchanged value sends nothing and that no push happens between `openSession` and `running`.
3. **Guest setters and time zone fallback (design step 1).** `SetLocale` uses `updatePersistentConfigurationWithAttribution`. `SetTimeZone` uses `AlarmManager.setTimeZone`. `SetClockFormat` writes `Settings.System.TIME_12_24`. If Android's tzdata does not know the ID, the agent answers `NOT_FOUND`. For a whole-hour offset, the host then sends `Etc/GMT∓h` (inverted sign), logs a health warning, and sets `integrations.time` to warning. For an offset that is not a whole hour, it keeps the current Android zone and warns. Check `SetTimeZone` as the shell uid on the stock image. Check: the T0 `Etc/GMT` sign tests pass, and the shell result is in [guest-components.md](../../02-design/guest-components.md) §5.
4. **Clock (design step 1).** Add the `SyncTime` triggers that #069 does not cover: post-boot, every 30 min while `ready`, and after `NSSystemClockDidChange`. The agent applies a difference of more than 500 ms, plus half of the last `Ping` round-trip time. On the custom image, the product has `AUTO_TIME = 0` and `AUTO_TIME_ZONE = 0` ([android-image.md](../../02-design/android-image.md) §11.2). A failed `SyncTime` sets `integrations.time` to warning. Check: a T2 test with a changed guest clock shows it corrected within 30 min, using a shortened interval in the test.
5. **Acceptance (design step 2).** Run the §9 verification. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`): locale tag mapping, the 12/24 detection for several locales, the `Etc/GMT` sign and the non-whole-hour case, change-only pushes, and no push on the launch path.
- **T1**: simulated power events for the `SyncTime` triggers with a fake channel (FR-VM-11, with #069).
- **T2** (`Tests/IntegrationTests/`, custom image): while HelloText runs, the test changes the language order, the region, and the 24-hour setting with `defaults write -g` and then posts the matching distributed notification from a test helper, and changes the time zone with `systemsetup -settimezone`. `GetSnapshot` locale and time fields follow within 2 s, and HelloText shows the new time format. The test restores the Mac settings afterwards.
- **T3** (`Tests/AcceptanceTests/`, reference Mac): sleep for 2 min (`pmset sleepnow` with a scheduled wake) and wake. The guest clock is within 2 s of the host. The same changes as T2, made in System Settings. The v0.5 checklist item C05-9 ([../test-strategy.md](../test-strategy.md) §8.6): with macOS set to Japanese, HelloSplit (#042) shows its Japanese string.

### Acceptance criteria

- [ ] Changing the macOS language order, the region, the time zone, and the 24-hour setting while HelloText runs changes Android's settings within 2 s (`GetSnapshot`), and HelloText shows the new time format.
- [ ] After 2 min of Mac sleep and a wake, the guest clock is within 2 s of the host.
- [ ] With macOS set to Japanese, HelloSplit shows its Japanese string (C05-9).
- [ ] An unchanged value is not pushed, and no locale push happens on the launch path.
- [ ] A time zone unknown to the image falls back to `Etc/GMT∓h` with the correct sign and a health warning.
- [ ] With a `system.sync*` switch off, that item is not changed in Android.
- [ ] The `SET_TIME_ZONE` shell result is recorded.

### Notes

- **Record:** the `SET_TIME_ZONE` shell result in [guest-components.md](../../02-design/guest-components.md) §5.
- **Pitfall:** apkrund is a LaunchAgent without a window. Check that it receives the locale and time zone notifications. If it does not, it re-reads the host values at `ready`, at resume, and at the 30 min timer.
- **Pitfall:** a locale change restarts Android activities that do not handle configuration changes. That is why pushes are change-only and never on the launch path.
- The T2 method (`defaults write -g` plus a posted notification) is a choice of this plan. Changing these settings in System Settings is manual, so that path is T3.

---

## #086 Menu bar

| Field | Value |
|---|---|
| Milestone | M9 (v0.5) |
| Depends on | #032 |
| Requirements | FR-UI-05. Constraints: NFR-PERF-06 (an observing client is not activity), NFR-REL-02 (reconnect), NFR-L10N-01 (String Catalogs) |
| Design | [host-ui.md](../../02-design/host-ui.md) §1, §2.1, §2.2, §9.1, §12, §13, §14 (#086), §15; [runtime-daemon.md](../../02-design/runtime-daemon.md) §2, §5.1, §7.2; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §1, §2; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.10; [cli.md](../../02-design/cli.md) §4.1; [../../05-development/build-system.md](../../05-development/build-system.md) |
| Modules / paths | `Apps/APKRunMenuBar/`, `Apps/APKRun/` (Settings → General toggle, relaunch at open), `project.yml` (target and Login Items embed), `Tests/` (model tests), `Tests/IntegrationTests/`, `Tests/AcceptanceTests/` |
| Risks / questions | None in [../risks.md](../risks.md). Open items: [host-ui.md](../../02-design/host-ui.md) §16 (whether Apps lists `keepRunning` apps without a window; v1 lists sessions only) |

### Goal

A menu bar item shows whether Android runs, which apps are running, and which updates are available. From it the user can bring an app to the front, update apps, open APKRun, and stop Android. It keeps running when APKRun.app quits and never keeps Android running.

### Scope

- The `APKRunMenuBar` target (SwiftUI `MenuBarExtra`, `LSUIElement = true`, bundle ID `io.apkrun.APKRunMenuBar`), embedded in `APKRun.app/Contents/Library/LoginItems/`.
- Login item registration with `SMAppService.loginItem(identifier:)` from Settings → General ("Show APKRun in the menu bar", default on, registered at the first launch of APKRun.app, no settings key).
- The menu of [host-ui.md](../../02-design/host-ui.md) §12: the status item image, the runtime line, "Developer mode on", "⚠ Needs attention", Apps, Updates with **Update** and **Update All**, **Open APKRun…**, **Stop Android** / **Start Android**, and **Quit Menu Bar Item**.
- Its own models over `RuntimeClient` with the `runtime`, `sessions`, `updates`, and `health` topics, and reload after reconnect.

Out of scope:

- The maintenance rows ("APKRun ‹version› is available", "Android system update ready", "Finish updating APKRun…", "◐ Updating Android…") and the relaunch after a newer build (#057, #087, [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.7, §7.3). This task leaves a place for them in the menu.
- The microphone symbol for recording apps (#084, M12).
- Japanese strings (#092). This task puts all strings in String Catalogs.

### Deliverables

- `Apps/APKRunMenuBar/` with the app, `MenuBarModel`, and the menu views.
- The target in `project.yml`, the Embed Login Items phase, and its signing ([../../05-development/build-system.md](../../05-development/build-system.md)).
- The Settings → General toggle, and the login item registration at the first launch of APKRun.app.
- Model tests with a fake `RuntimeService`, and T2 and T3 tests.

### Implementation steps

The design steps are [host-ui.md](../../02-design/host-ui.md) §14 #086, steps 1–2. Step 1 is split into steps 1–4 here, and step 2 is step 5.

1. **Target and connection (design step 1).** Add the `APKRunMenuBar` target, which depends only on RuntimeClient and DiagnosticsCore ([../../01-architecture/modules.md](../../01-architecture/modules.md) §3). It connects to the `.control` endpoint like APKRun.app ([../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2), subscribes to its topics, and reloads its snapshots after every reconnect. While apkrund is unreachable, the runtime line says so and offers **Open APKRun…**. The connection keeps apkrund alive but is not activity, so Android still goes idle and stops ([runtime-daemon.md](../../02-design/runtime-daemon.md) §5.1). Check: `scripts/check-module-deps.sh` passes, and a T1 test shows that Android reaches its idle stop with the menu bar connected.
2. **Login item (design step 1).** Settings → General "Show APKRun in the menu bar" shows and changes the `SMAppService` registration. APKRun.app registers it at its first launch. If the user removes the login item in System Settings, the toggle shows off. When APKRun.app opens with the setting on and the menu bar item is not running, it opens it. Check: turning the toggle off quits the item and removes the login item.
3. **Menu (design step 1).** Build the menu of §12. The status item is a template image: filled while Android runs, outlined while it is stopped or asleep, with a dot when updates are available, the runtime failed, or a live health check needs attention. In the last case the menu shows "⚠ Needs attention", which opens Troubleshooting in APKRun.app. **Apps** lists running sessions; a click runs `launch(packageID)`, which activates the running wrapper. **Updates** lists available updates with **Update** (a manual update with the gentle rules) and **Update All**. **Open APKRun…** opens the enclosing APKRun.app. "Developer mode on" appears under the runtime line while developer mode is on. Check: model tests over a fake `RuntimeService` cover each row and the dot rules.
4. **Stop and start (design step 1).** **Stop Android** asks for confirmation when apps are open, then stops the runtime. When Android is stopped, the item is **Start Android**, which starts the runtime without a hold. **Quit Menu Bar Item** quits only APKRunMenuBar. Check: a T2 test stops and starts Android from the model.
5. **Acceptance (design step 2).** Run the T2 and T3 checks. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Tests/`, model tests with a fake `RuntimeService`): runtime line states, the dot rules, the app and update counts, reload after reconnect, and the Stop Android confirmation.
- **T1**: XPC tests against a real apkrund with the embedded runtime fake: the menu bar connection does not count as activity, and reconnect reloads the snapshots.
- **T2** (`Tests/IntegrationTests/`): with two apps running and two updates available, the counts and rows are right; **Stop Android** stops the runtime after the confirmation.
- **T3** (`Tests/AcceptanceTests/`, reference Mac): the login item after a logout and login, and quitting APKRun.app with the menu bar item and apps running.

### Acceptance criteria

- [ ] With two apps running and two updates available, the menu shows both counts and lists the apps and updates.
- [ ] **Stop Android** stops the runtime after confirmation, and the item then reads **Start Android**.
- [ ] Quitting APKRun.app leaves the menu bar item and the apps running.
- [ ] Clicking an app in the menu brings its window to the front.
- [ ] The menu bar item never keeps Android running: with it connected and no apps open, Android goes idle and stops as configured.
- [ ] **Quit Menu Bar Item** quits only the menu bar item. It comes back at the next login, or when APKRun.app opens with the setting on.
- [ ] After apkrund restarts, the menu reconnects and shows current data.

### Notes

- **Pitfall:** the menu bar item and APKRun.app are separate processes. Do not share models across the app targets; use `RuntimeClient` in both.
- **Pitfall:** `SMAppService.loginItem` needs the helper inside `Contents/Library/LoginItems/` of a signed app. A Debug build run from Xcode's build folder can behave differently from an installed build.
- The confirmation text, **Start Android** without a hold, and `MenuBarModel` as the menu bar's own model are choices of this plan. The design does not state them.
