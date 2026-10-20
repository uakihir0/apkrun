# Runtime Maintenance: APKRun Updates and Android System Updates

This document covers the two update systems that change the APKRun runtime: APKRun updates, which replace the APKRun.app bundle through Sparkle, and Android system updates, which replace the guest image. Android app updates are in [update-system.md](update-system.md). Wrapper metadata is in [wrapper.md](wrapper.md).

| Update | What changes | Where it is designed |
|---|---|---|
| Android application | an APK set inside Android | [update-system.md](update-system.md) |
| **APKRun runtime** ("APKRun update") | the APKRun.app bundle: APKRun.app, apkrund, APKRunMenuBar, the CLI, the launcher template, VirGLRuntime | this document, §3 |
| **Android guest image** ("Android system update" in the UI) | the runtime image bundle: AOSP, kernel, Mesa, guest agents | this document, §4, and [android-image.md](android-image.md) §10.4, §12 |
| Wrapper metadata | a wrapper's name, icon, URL handling, window preferences | [wrapper.md](wrapper.md) |

APKRun updates and Android system updates have separate code paths, state files, schedules, and UI rows. They meet only in the compatibility contract (§2.2) and the mutual-exclusion rule (§2.4).

- Only APKRun.app links Sparkle, and only Sparkle replaces the APKRun.app bundle. apkrund, the menu bar, and the CLI never download or install APKRun updates.
- Neither system writes under `Packages/` or inside a wrapper bundle. The one exception is a data schema migration shipped in a release (§5). It runs as a journaled store transaction and keeps the meaning of every field.
- APKRun updates never change the Android image. Android system updates never change the APKRun bundle.

---

## 1. Responsibilities and components

| Component | Module, process | Responsibility | Section |
|---|---|---|---|
| `SelfUpdateController` | APKRun.app (`Apps/APKRun/Maintenance/`) | owns Sparkle's `SPUStandardUpdaterController`, maps settings to Sparkle, implements `SPUUpdaterDelegate` | §3.2 |
| `UpdateInstallCoordinator` | APKRun.app | the safe-restart handshake with apkrund before Sparkle installs | §3.5 |
| `AgentRegistrar` | APKRun.app | registers apkrund (`SMAppService.agent`) and the menu bar login item; re-registers after an update when needed | §3.7 |
| `MaintenanceService` (actor) | RuntimeHost (apkrund) | host state (`normal`, `updating`, `restartPending`), host-update marker, post-update tasks, maintenance endpoint | §3.5–§3.8, §8.1 |
| `SelfUpdateProbe` | RuntimeHost | background appcast check for users who rarely open APKRun.app | §3.4 |
| `BundleWatcher` | RuntimeHost | detects that APKRun.app was replaced while apkrund runs | §3.6 |
| `ImageUpdateCoordinator` (actor) | RuntimeHost | owns `ImageUpdatePhase`: check → download → install → apply | §4 |
| `ImageFeedClient` | ImageCore | fetches and verifies the image feed | §4.1 |
| `ImageDownloader` | ImageCore | resumable, verified downloads into `Cache/images/`. First-run provisioning uses it too ([runtime-daemon.md](runtime-daemon.md) §9.3) | §4.4 |
| `ImageStore.install(from: .archive)` | ImageCore | safe extraction, verification, hole punching | §4.5, [android-image.md](android-image.md) §10.4 |
| `RuntimeSupervisor.migrateImage(to:operation:)` | RuntimeCore | migration A → B: boot, health check, restore on failure | §4.7, [android-image.md](android-image.md) §12.3 |
| `SchemaMigrator` | DiagnosticsCore (generic runner); each store supplies its steps | forward-only migrations of host data files | §5 |

---

## 2. Versions and compatibility

### 2.1 APKRun version and component list

- `CFBundleShortVersionString` is `MAJOR.MINOR.PATCH`, shown without a zero patch: "1.0" means 1.0.0. `CFBundleVersion` is the **build number**, a positive integer that increases with every published build on every channel. Sparkle compares `sparkle:version` with it. Every executable in the bundle has the same two values.
- The build writes `Contents/Resources/components.json` ([build-system.md](../05-development/build-system.md)). `BuildInfo` ([diagnostics.md](diagnostics.md) §1) reads it. `host.componentVersions`, `apkrun --version --verbose`, and the diagnostics bundle (`versions.json`) show it.

```json
{
  "version": "1.2.0",
  "build": 1200,
  "channel": "stable",
  "commit": "4f2c9e1",
  "runtimeAPI": { "current": "3.1", "wrapperMajors": [2, 3] },
  "guestProtocol": { "majors": [1] },
  "agentPlistSHA256": "9b1c…",
  "dataSchemas": { "state": 1, "settings": 2, "packageRecord": 1, "packageSettings": 1, "journal": 1,
                   "wrapperRegistry": 1, "updateState": 1, "imageUpdateState": 1, "instance": 1 },
  "components": { "virglrenderer": "1.1.1+apkrun.2", "angle": "chromium/7151", "aapt2": "8.9.1-12782657",
                  "devGuestAgentVersionCode": 1002000, "sparkle": "2.x.y" }
}
```

The values are an example of a later release. In v1.0 every data schema is at version 1. A build test checks that `runtimeAPI`, `guestProtocol`, and `dataSchemas` equal the constants in the code (`RuntimeAPI.version`, `ProtocolVersion.supportedMajors`, each store's `currentSchemaVersion`).

### 2.2 Compatibility contract

| Pair | Rule | Enforced by |
|---|---|---|
| APKRun ↔ Android image | the image's `requirements.minimumRuntimeVersion` ≤ the APKRun version, and its `requirements.guestProtocol` range intersects `guestProtocol.majors` | ImageCore: feed filtering (§4.2), activation, every boot ([android-image.md](android-image.md) §9.3, §12.1) |
| APKRun ↔ older images | every APKRun release boots the **current and the previous stable image**. A guest protocol major is dropped only after both of the last two stable images support the newer major | rules R2 and R4 (§2.3) |
| APKRun ↔ wrappers | the wrapper endpoint serves RuntimeAPI majors N and N−1. Wrappers two majors behind show screen L, and APKRun.app offers to refresh them | [wrapper.md](wrapper.md) §5.3, §9.4 |
| APKRun ↔ its data | every data file has a `schemaVersion`. A newer build migrates forward. An older build refuses data it doesn't understand, and the host starts degraded | §5 |
| APKRun ↔ its own parts | one bundle, one build. apkrund, the CLI, the menu bar, and the launcher template are never updated separately | `host.componentVersions`, `apkrund.version` ([diagnostics.md](diagnostics.md) §7.3) |
| APKRun ↔ guest agents | custom image: agents are part of the image and update with it. Stock image (development): the host installs the dev Guest Agent from `Resources/guest/` when its versionCode differs, so an APKRun update updates it at the next boot | [guest-protocol.md](guest-protocol.md) §5.2 |
| Android image ↔ userdata | the image's `userdata.upgradableFrom` must contain the instance's userdata schema | [android-image.md](android-image.md) §12.1 |
| APKRun maintenance ↔ any APKRun | the maintenance endpoint is version-stable, so an old apkrund and a new APKRun.app always coordinate | §8.1 |

### 2.3 Release rules

The release workflow (`scripts/release/`, [workflow.md](../05-development/workflow.md)) checks these before it publishes an appcast item or a feed entry.

| # | Rule |
|---|---|
| R1 | The build number is higher than every build published before, on every channel |
| R2 | The APKRun release passes the T3 release smoke matrix (boot, one app launch, migration A → B; §14, [test-strategy.md](../04-plan/test-strategy.md) §9.2) with the current stable image and with the previous stable image |
| R3 | An image entry's `minimumRuntimeVersion` is the oldest APKRun release it was tested with. An image that needs an unreleased APKRun is published only after that APKRun is on the same channel |
| R4 | A RuntimeAPI major or guest protocol major is dropped only as §2.2 allows |
| R5 | For every file, the migration chain exists from every schema version shipped in a stable release in the last 24 months, and each step has a T0 golden test (§5) |
| R6 | The Sparkle EdDSA key and the Developer ID certificate are never changed in the same release ([security-model.md](../01-architecture/security-model.md) §7) |
| R7 | A stable image is released at least once a quarter, for Android security patches and time zone data. An extra release is made for a critical security fix, and for a tzdata change that affects a zone within 60 days (§4.11) |

### 2.4 Mutual exclusion

| While | Refused or delayed | Error or behavior |
|---|---|---|
| An image migration runs (`RuntimeImageState.migrating`) | installing an APKRun update | `prepareForHostUpdate` returns `maintenance.hostUpdateBusy(.migration)`. APKRun.app shows "Waiting for the Android system update to finish…" and retries every 30 s |
| The host state is `updating` or `restartPending` (§3.6) | applying an Android system update | apply gate stays closed (A3, §4.6). Downloads continue |
| A package transaction or app update install runs | installing an APKRun update | `prepareForHostUpdate` waits up to 2 minutes, then returns `maintenance.hostUpdateBusy(.storeOperation)` |
| An image migration runs | package installs, app updates, `apkrun launch` | they wait in `ensureReady` for the migration's boot and health check ([runtime-daemon.md](runtime-daemon.md) §3.1). The CLI prints "Waiting for the Android system update to finish…" |

---

## 3. APKRun updates

### 3.1 What an APKRun update replaces

The runtime update is the APKRun.app bundle itself. It is Developer ID signed, notarized, stapled, versioned by §2.1, and published as a Sparkle archive (§3.3). There is no separate runtime package, because apkrund, the menu bar, and the CLI must always match APKRun.app (§2.2).

| Replaced by an APKRun update | Not touched |
|---|---|
| everything inside `APKRun.app/Contents/` ([filesystem-layout.md](../01-architecture/filesystem-layout.md) §4): APKRun.app, `Helpers/apkrund`, `Helpers/APKRunLauncher.app` (wrapper template), `Library/LaunchAgents/io.apkrun.apkrund.plist`, `Library/LoginItems/APKRunMenuBar.app`, `Frameworks/` (VirGLRuntime, Sparkle), `Resources/bin/apkrun` (the PATH symlink keeps pointing at it), `Resources/tools/aapt2`, `Resources/guest/`, `compatibility.json`, `components.json` | the Android image and instance (`Images/`, `Runtime/instance/`), `Packages/` (apps, records, settings, journal), `Wrappers/` and every wrapper bundle, `Updates/`, `Providers/`, `Shared/`, Keychain items. `state.json` and `settings.json` change only through schema migrations (§5) |

Wrappers keep their own copy of the launcher and keep working under the N−1 rule. §3.7 step 5 covers the refresh prompt.

### 3.2 Sparkle integration

- **Dependency:** Sparkle 2 (`https://github.com/sparkle-project/Sparkle`, MIT), through SwiftPM, pinned to an exact version in `project.yml`, linked into APKRun.app only. It goes into `Contents/Frameworks/Sparkle.framework` and is signed inside-out ([build-system.md](../05-development/build-system.md)). ADR-0016 records the choice.
- **User interface:** Sparkle's standard user driver (`SPUStandardUserDriver`): update alert with release notes, download progress, **Install and Relaunch**. APKRun adds its own dialog only for the handshake (§3.5).
- **Info.plist (release builds):**

| Key | Value | Reason |
|---|---|---|
| `SUFeedURL` | `https://<updates host>/apkrun/appcast.xml` (host is OQ-01) | one appcast; channels select beta items |
| `SUPublicEDKey` | the base64 Ed25519 public key | Sparkle refuses archives not signed with the matching private key |
| `SUEnableAutomaticChecks` | `YES` | no permission prompt at the second launch. The user's choice is `maintenance.checkAutomatically` (§6) |
| `SUScheduledCheckInterval` | `86400` | one check a day while APKRun.app runs |
| `SUAllowsAutomaticUpdates` | `YES` | allows the "Install APKRun updates automatically" option |
| `SUAutomaticallyUpdate` | `NO` | first-launch default. Overwritten from settings at every launch |
| `SUEnableSystemProfiling` | `NO` | no system profile is sent |
| `SUVerifyUpdateBeforeExtraction` | `YES` | archive signature is checked before extraction |
| `SURequireSignedFeed` | `YES` | the appcast carries an EdDSA signature |

If the pinned Sparkle lacks one of the two recent keys (`SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`), the other protections still hold (archive signature, Developer ID check), and the gap is R-23 ([risks.md](../04-plan/risks.md)).

- **Settings are the source of truth.** At launch and on every change, `SelfUpdateController` sets `updater.automaticallyChecksForUpdates = maintenance.checkAutomatically` and `updater.automaticallyDownloadsUpdates = maintenance.installAPKRunAutomatically`. Sparkle's own UserDefaults are never read back.
- **Delegate** (`SPUUpdaterDelegate`):

| Method | Use |
|---|---|
| `allowedChannels(for:)` | `["beta"]` when `maintenance.channel == beta`, otherwise empty (stable items only) |
| `updater(_:didFindValidUpdate:)`, `updaterDidNotFindUpdate(_:)` | send the result to apkrund (`noteSelfUpdateStatus`, §8.2) so the menu bar and CLI agree with Sparkle |
| `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` | returns `true`, runs the handshake of §3.5, then calls the block |
| `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` | an automatic update is installed when APKRun.app quits. Settings shows "APKRun ‹version› will be installed when you quit APKRun." with **Install and Relaunch Now** (calls the immediate block through the handshake). apkrund is told with `noteSelfUpdateStatus(pendingOnQuit:)` |
| `updater(_:didAbortWithError:)`, `updater(_:failedToDownloadUpdate:error:)` | logged as `maintenance.sparkle(code:)`. If a marker was written, `abortHostUpdate` is called |

- **Development builds** have no `SUFeedURL`, and `SelfUpdateController` does nothing. The `ReleaseUpdateTest` configuration points `SUFeedURL` at the local appcast server and uses the test key `Tests/Fixtures/signing/test-sparkle-ed25519.pub`. Its CI bundles are Developer ID signed but not notarized (§14).

### 3.3 Release artifacts and the appcast

- **Archive:** `APKRun-<version>.zip`, made with `ditto -c -k --sequesterRsrc --keepParent APKRun.app` from the notarized, stapled bundle. The website offers `APKRun-<version>.dmg` (notarized) for first installs.
- **Deltas:** `generate_appcast` makes deltas from the last three releases, which release storage keeps.
- **Signing:** the release job signs each archive with `sign_update` (EdDSA key in CI, [security-model.md](../01-architecture/security-model.md) §7) and signs the appcast. Sparkle also checks that the new bundle's Developer ID matches the installed one (R6).
- **Appcast item** fields: `title` ("APKRun 1.2.0"), `pubDate`, `sparkle:version` (build, `1200`), `sparkle:shortVersionString` (`1.2.0`), `sparkle:minimumSystemVersion` (`27.0`), `sparkle:releaseNotesLink`, `sparkle:phasedRolloutInterval` (`86400`), `sparkle:channel` (`beta` on beta items only), `sparkle:criticalUpdate sparkle:version="…"` (security fixes only), and `enclosure` with `url`, `length`, `type="application/octet-stream"`, and `sparkle:edSignature`.
- **Phased rollout:** stable items use `phasedRolloutInterval` 86400, which spreads them over about a week. Beta items and critical updates are not phased. User-initiated checks ignore phasing.
- **Hosting:** static HTTPS (OQ-01). The appcast is served with `Cache-Control: max-age=300`. Archives are immutable; their URL contains the version.

### 3.4 Background probe in apkrund (`SelfUpdateProbe`)

Sparkle checks only while APKRun.app runs. Many users only open their Mac apps, so the probe tells them about updates.

- **When:** once per 24 hours (± 1 hour jitter, `ContinuousClock`), at the hourly `StartInterval` wake or while apkrund runs, and only while `maintenance.checkAutomatically` is on. It also runs on request (`checkSelfUpdate(userInitiated: true)`) from the CLI and the menu bar.
- **What:** one conditional GET of the appcast (`If-None-Match`, `If-Modified-Since`), 30 s timeout, 2 MiB limit. It follows [update-system.md](update-system.md) §3.4 (HTTPS only, system proxy). `XMLParser` reads the items. The probe keeps items whose channel is allowed, whose `minimumSystemVersion` ≤ the running macOS, and whose `sparkle:version` is higher than its own build, and picks the highest. Items under phased rollout are ignored until `pubDate + 7 × phasedRolloutInterval`, except critical updates and user-initiated checks. The probe cannot see Sparkle's rollout group. When the feed is signed (`SURequireSignedFeed`), the probe checks it with `SUPublicEDKey` (CryptoKit `Curve25519.Signing`). A bad signature gives `unknown` and logs `maintenance.selfUpdateFeedInvalid`.
- **Informational only:** it never downloads or installs. An install always goes through Sparkle and its checks.
- **Result:** `SelfUpdateStatus { currentVersion, currentBuild, latest: AvailableRelease?, critical, lastCheckedAt, lastError, pendingOnQuit }`, published on the `maintenance` topic (§8.3). `AvailableRelease` is the chosen appcast item ([runtime-api.md](../03-reference/runtime-api.md) §12.2).
- **Notification:** once per version, through `HostNotifier` ([update-system.md](update-system.md) §9), and only when APKRun.app is not connected (Sparkle shows its own alert then). "APKRun ‹1.2.0› is available. Open APKRun to install it." with **Update…**, which opens Settings → General and starts a user-initiated Sparkle check (`checkForUpdates()`). A critical update is notified again after 3 days if still not installed.
- **Menu bar:** row "APKRun ‹1.2.0› is available" with **Update…** ([host-ui.md](host-ui.md) §12). **CLI:** `apkrun self-update check` (§7.6).

### 3.5 Install coordination

Sparkle replaces APKRun.app. apkrund, the menu bar, and the VM's GPU renderer run code from that bundle, and Sparkle does not know about them (ADR-0007). So Android stops and apkrund exits before Sparkle installs.

**The main path.** The user clicks **Install and Relaunch** in Sparkle's alert, or **Install and Relaunch Now** for an update pending on quit.

```text
APKRun.app                                        apkrund (MaintenanceService)
 1  Sparkle: shouldPostponeRelaunch → true
 2  maintenanceStatus() ───────────────────────▶  sessions, background tasks, migration, store operations
 3  apps open? → dialog (below)
      Cancel → nothing changes; the update stays downloaded
      Install When Apps Are Closed → §3.5.1
 4  prepareForHostUpdate(targetVersion,
       targetBuild, closeSessions) ───────────▶  a) refuse if an image migration runs (busy) or targetBuild ≤ own build
                                                  b) host state ← updating(targetBuild): new sessions, store operations,
                                                     and wrapper generation → RuntimeFailure.hostUpdating
                                                  c) wait ≤ 2 min for running store transactions and app update installs
                                                  d) write Runtime/maintenance.json (§3.6)
                                                  e) end sessions with ended(.runtimeUpdating)
                                                  f) stop Android: StopReason.hostUpdate, 40 s deadline, then forced
                                                  g) flush logs, daemon.json cleanExit = true
                                   ◀────────────  reply ok, then exit 0 after 1 s
 5  terminate APKRunMenuBar (NSRunningApplication.terminate)
 6  call Sparkle's block → Sparkle quits APKRun.app, replaces the bundle, and relaunches it
 7  new APKRun.app: first-launch tasks (§3.7)    new apkrund: marker handling (§3.6), post-update tasks (§3.8)
```

- With apps open (sessions and `keepRunning` background tasks, [runtime-daemon.md](runtime-daemon.md) §5.1), step 3 shows "Install APKRun ‹version›?" and names the apps that will close and reopen. Buttons: **Install When Apps Are Closed**, **Cancel**, **Close Apps and Install**.
- Step 4 has a 3-minute timeout on the APKRun.app side. On failure or timeout, APKRun.app calls `abortHostUpdate` (deletes the marker, host state back to `normal`) and shows the error with **Try Again**. Sparkle keeps the download.
- If apkrund is not running, the connection starts it (launchd starts it on demand for the Mach service).
- Open wrappers get `ended(.runtimeUpdating)`, show screen U, and reconnect by themselves (§7.5). That is why the dialog can promise that their windows reopen.

#### 3.5.1 Install When Apps Are Closed

APKRun.app keeps Sparkle's postponed block and subscribes to the `sessions` and `runtime` topics. When no session and no background task is left, it runs step 4 with `closeSessions = false`. Settings shows "APKRun 1.2.0 will be installed when your Android apps are closed." with **Install Now…**, which returns to the dialog.

If APKRun.app quits first, Sparkle installs the postponed update on quit. apkrund then finds its bundle replaced and completes the update itself (§3.6, `restartPending`).

### 3.6 Host state, the marker, and a replaced bundle

`HostState` belongs to RuntimeHost. It is published, with `runtimeBuild`, in the broker's `HelloReply` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2), in `runtimeStatus`, and on the `maintenance` topic.

| State | Meaning | apkrund behavior |
|---|---|---|
| `normal` | — | — |
| `updating(targetBuild)` | a coordinated update is being installed (§3.5 step 4 ran, or apkrund started and found the marker) | serves the broker and the maintenance endpoint (§8.1). Health and diagnostics work. Everything else returns `RuntimeFailure.hostUpdating`. Android is never started |
| `restartPending(bundleBuild)` | the bundle on disk has a different build than this process. Causes: Sparkle installed on quit, a new APKRun.app copied from the DMG, Homebrew, or MDM | running sessions and background tasks go on. Refused with `hostUpdating`: starting Android, wrapper generation and refresh, and anything else that reads bundle resources (dev Guest Agent, `compatibility.json`, launcher template). When no session, background task, or operation is left, apkrund stops Android if running and exits 0 at once, without the 2-minute grace period. The next client connection starts the new apkrund |

**`BundleWatcher`** reads `CFBundleVersion` from `Contents/Info.plist` on disk, not from cached `Bundle` values. It checks on every broker `hello`, every 60 s, and on a vnode event (`DispatchSource`: rename, delete) for the bundle directory. A different build means `restartPending(build)`. A missing bundle means `restartPending(nil)`. apkrund links all its bundle code at launch and never `dlopen`s code from the bundle later.

**The marker `Runtime/maintenance.json`** is written in §3.5 step 4d and read at every apkrund start (startup step 4, [runtime-daemon.md](runtime-daemon.md) §2.2):

```json
{
  "schemaVersion": 1,
  "fromVersion": "1.1.0", "fromBuild": 1100,
  "targetVersion": "1.2.0", "targetBuild": 1200,
  "createdAt": "2026-11-02T10:15:02Z",
  "operationID": "3f9a1c2e-5b7d-4e8f-9a01-2c3d4e5f6a7b"
}
```

| At apkrund start | Action |
|---|---|
| no marker | normal start |
| own build < `targetBuild`, marker younger than 10 min | `updating`: the old bundle is still in place, or the install is running. apkrund polls every 2 s and exits 0 when the marker disappears (aborted) or the bundle's build on disk changes (installed). When the marker is 10 minutes old, it deletes it, logs `maintenance.hostUpdateAbandoned`, and exits 0. The next start is normal |
| own build < `targetBuild`, marker 10 min or older | delete the marker, log `maintenance.hostUpdateAbandoned`, normal start |
| own build ≥ `targetBuild` | `updating` (finishing): wait for `completeHostUpdate` from the new APKRun.app (§3.7 step 4), or at most 60 s. Then delete the marker, run the post-update tasks (§3.8), and start normally |

The finishing wait prevents the new apkrund from booting Android before the agent re-registration of §3.7 step 2 stops it, which happens when a wrapper reconnects before Sparkle relaunches APKRun.app.

When APKRun.app starts and finds a marker whose `targetBuild` is higher than its own build, the update failed after step 4. It calls `abortHostUpdate` at once and shows "APKRun couldn't be updated." Sparkle shows the details.

### 3.7 First launch of the new APKRun.app

`SelfUpdateController.completeUpdateIfNeeded()` runs in `applicationDidFinishLaunching`, before any view uses the runtime:

1. Compare the own build with UserDefaults `lastLaunchedBuild`. If equal, stop.
2. **Agent registration (`AgentRegistrar`):** when `SMAppService.agent(plistName:).status == .requiresApproval`, keep the pending registration even if the embedded plist SHA-256 differs from UserDefaults `registeredAgentPlistSHA256`. Show the approval prompt; do not unregister or register. When approval makes the status `.enabled`, re-register if the stored plist hash is stale, and store the new hash. Otherwise register an absent or non-enabled service and store the current hash. So a changed plist can trigger another approval after the pending request is approved. Unregistering stops a running apkrund with `SIGTERM`. In the coordinated path apkrund is in `updating` and has no sessions. Outside it (install on quit, DMG copy), if apkrund has sessions, re-registration waits for the "Finish updating APKRun" banner (§7.3). If the plist is unchanged, no re-registration is needed: `BundleProgram` is resolved when launchd spawns the job, so the next spawn runs the new binary. If R-24 shows this does not hold, re-register on every build change, with the same coordination.
3. **Menu bar:** if "Show APKRun in the menu bar" is on and APKRunMenuBar is not running, or runs another build, terminate it and open the new one. At every connection the menu bar compares `HelloReply.runtimeBuild` with its own build; when apkrund is newer, it opens its own bundle URL again and exits. That covers updates made while APKRun.app is not opened.
4. `completeHostUpdate()` on the maintenance endpoint (§3.6).
5. **Launcher refresh prompt:** if some wrappers are two RuntimeAPI majors behind, or the new build sets `LauncherBuild.recommendsRefresh`, show "‹N› Mac apps need to be updated to work with this version of APKRun." with **Update Now** and **Later** ([wrapper.md](wrapper.md) §9.4).
6. Store `lastLaunchedBuild`.

There is no "What's New" window. Sparkle shows the release notes before the install.

### 3.8 Post-update tasks in apkrund

These run once, when `state.json.lastRuntimeBuild` is lower than the own build:

1. Data schema migrations, as each store loads its files (§5).
2. Record the `HOST_UPDATED { fromBuild, toBuild }` marker and a log line.
3. Check whether the current image can boot with this build. If not, §4.10.
4. Check the image feed now. A newer build may accept newer images.
5. Recompute wrapper refresh reasons (`WrapperValidator`, [wrapper.md](wrapper.md) §9.1), so Home shows **Update All Mac Apps**.
6. Write `state.json.lastRuntimeVersion` and `lastRuntimeBuild`.

If `lastRuntimeBuild` is **higher** than the own build, an older APKRun was installed by hand. Files with a newer schema make the host start degraded (§5). If no file is newer, apkrund runs normally and `maintenance.selfUpdate` warns "APKRun was downgraded from ‹version›".

### 3.9 Failure cases

| Case | Result |
|---|---|
| appcast unreachable or invalid | Sparkle shows its error for a user-initiated check. The probe records `lastError`. `maintenance.selfUpdate` warns after 7 days without a successful check |
| archive signature or Developer ID mismatch | Sparkle refuses the update. Nothing is installed |
| the user cancels the dialog | nothing changes. The update stays available |
| `prepareForHostUpdate` fails (busy, timeout, stop failed) | `abortHostUpdate`, the error with **Try Again**. Sparkle keeps the download |
| APKRun.app crashes after step 4, or Sparkle's installer fails | the marker remains. An old apkrund started by a client waits at most 10 minutes in `updating`, then clears the marker. The next APKRun.app launch aborts at once (§3.6) |
| power loss during the install | Sparkle swaps the bundle atomically, so the old or the new bundle is in place. The marker rules decide the rest |
| the new apkrund crash-loops | launchd restarts it (`KeepAlive`), and `apkrund.crashLoop` reports it. Sparkle never installs an older version. Recovery: install the previous release from the website. Data is safe because migrations keep backups (§5). APKRun has no automatic host rollback in v1 |
| a schema migration fails | the owning component starts degraded with `maintenance.schemaMigrationFailed`. The original file and its backup are unchanged |
| APKRun.app replaced outside Sparkle | `restartPending` (§3.6) |

---

## 4. Android system updates

### 4.1 The image feed

- **Location:** `https://<updates host>/apkrun/images/<channel>/feed.json` and `feed.json.sig`, where channel is `stable` or `beta` (OQ-01). The base URL is the Release Info.plist key `APKRunImageFeedBaseURL`. Debug builds have no feed URL; tests set `APKRUN_TEST_IMAGE_FEED_URL` ([configuration.md](../03-reference/configuration.md) §5.1, §7.1). The field format is in [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) ("Image feed").

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "sequence": 57,
  "generatedAt": "2026-10-02T09:00:00Z",
  "expiresAt": "2026-11-01T09:00:00Z",
  "images": [
    {
      "imageVersion": "2026.10.0-ar000123-arm64",
      "kind": "apkrun",
      "publishedAt": "2026-10-02T09:00:00Z",
      "archive": { "url": "https://<updates host>/apkrun/images/2026.10.0-ar000123-arm64.aar",
                   "size": 1932735283, "sha256": "…" },
      "expandedSize": 9663676416,
      "requirements": { "minimumRuntimeVersion": "1.1.0", "guestProtocol": { "min": 1, "max": 1 } },
      "userdata": { "schemaVersion": 3, "upgradableFrom": [2, 3] },
      "upgradeFrom": { "minimumImageVersion": "2026.04.0" },
      "securityPatchLevel": "2026-09-05",
      "tzdataVersion": "2026b",
      "critical": false,
      "rolloutPercent": 100,
      "releaseNotesURL": "https://<updates host>/apkrun/android/2026.10.0.html"
    }
  ]
}
```

- `scripts/release/image-feed.py` produces the feed, signs it, and publishes it (OQ-01 decides the host). Archives are made with `aa archive -a lzfse`.
- `feed.json.sig` uses the same signature format and trust store as `manifest.sig` (`ImageTrustStore`, [android-image.md](android-image.md) §10.1). It signs the exact bytes of `feed.json`.
- **Client rules (`ImageFeedClient`):**
  1. HTTPS only. `feed.json` at most 1 MiB, `feed.json.sig` at most 4 KiB. Conditional GET with the stored ETag.
  2. The signature is checked before parsing. An unknown key or bad signature gives `imageFeedSignatureInvalid`; the last accepted feed stays in effect.
  3. `channel` must equal the requested channel.
  4. **Replay and freeze protection:** `sequence` must be at least the highest sequence accepted for this channel (stored in `Images/update-state.json`). Equal sequence requires identical bytes. A lower sequence gives `imageFeedReplayed`. A feed past `expiresAt` gives `imageFeedExpired` and is not used. The release workflow re-signs the feed with a new sequence at least weekly, with `expiresAt = generatedAt + 30 days`.
  5. Unknown fields are ignored. An unknown `schemaVersion` means the feed is not used, and a health warning says "Update APKRun to receive Android system updates."
  6. The feed is only a pointer. The archive SHA-256 and the manifest signature are checked separately (§4.5). The manifest's `imageVersion`, `requirements`, and `userdata` must equal the feed entry (`imageFeedInvalid` otherwise).

### 4.2 Checks and candidate selection

| Trigger | Notes |
|---|---|
| every 24 hours (± 1 hour jitter), at the hourly wake or while apkrund runs | only while `maintenance.checkAutomatically` is on |
| APKRun.app opens | at most once every 6 hours |
| after an APKRun update (§3.8) or a channel change | immediately |
| Settings **Check Now**, `apkrun image check` | user-initiated: ignores interval, backoff, and rollout |

A failed check is retried after 1 hour, then 6 hours, then on the daily schedule. Checks never start Android and do not count as runtime activity.

The **candidate** is the highest `imageVersion` in the feed that meets all of these:

| # | Condition | When it fails |
|---|---|---|
| C1 | newer than `current` (never a downgrade) | — |
| C2 | `minimumRuntimeVersion` ≤ the APKRun version | remembered as `requiresNewerAPKRun(version)`. Settings: "A newer Android version is available after you update APKRun." |
| C3 | `guestProtocol` intersects the host's majors | skipped |
| C4 | `userdata.upgradableFrom` contains the instance's userdata schema, and `current` ≥ `upgradeFrom.minimumImageVersion` | skipped. A manual activation is refused with `image.userdataSchemaUnsupported` or `image.migrationSourceTooOld` |
| C5 | not rejected (§4.8) | skipped, except a user-initiated update that confirms the retry |
| C6 | rollout: `bucket < rolloutPercent`, where `bucket` = first two bytes of SHA-256(instance ID ‖ imageVersion) as an integer, modulo 100. The instance ID is in `state.json` and never leaves the Mac | skipped until the percentage grows. Ignored for user-initiated checks and `critical` entries |
| C7 | `kind == apkrun`, and the current image is also `apkrun` | a development instance on a `stock` image never gets feed updates. It moves to the product image only through Reset Android (platform keys differ, data cannot carry over) |

### 4.3 `ImageUpdatePhase`

```swift
public enum ImageUpdatePhase: Codable, Sendable, Equatable {
    case idle                                            // up to date, or nothing compatible
    case checking
    case available(ImageCandidate)                       // download not started (network rules, or automatic download off)
    case downloading(ImageCandidate, DownloadProgress)
    case installing(ImageCandidate, fraction: Double)    // extract, verify, punch holes (§4.5)
    case ready(ImageVersion)                             // in Images/, not current; waiting for the apply gate (§4.6)
    case applying(from: ImageVersion, to: ImageVersion)  // RuntimeImageState.migrating
    case failed(ImageCandidate?, MaintenanceFailure, retryAt: Date?)
}
```

`ImageCandidate` is one feed entry that passed C1–C7. On the wire: `WireImageUpdatePhase`, `WireImageCandidate`, and `WireError` ([runtime-api.md](../03-reference/runtime-api.md) §12.3).

| From | To | Trigger |
|---|---|---|
| `idle`, `available`, `ready`, `failed` | `checking` | a trigger of §4.2. In `ready`, a newer candidate replaces the ready image, which GC deletes |
| `checking` | `idle`, `available` | the check result |
| `available` | `downloading` | automatic download allowed (§4.4), or the user asked |
| `downloading` | `installing` | archive complete; size and SHA-256 match |
| `downloading` | `failed` | an error. Retries after 15 minutes, 1 hour, then 6 hours. The partial file is kept if the server supports ranges |
| `installing` | `ready` | `ImageStore.install` returned |
| `installing` | `failed` | verification error: the archive is deleted and downloaded once more. After a second failure, no retry until the feed changes |
| `ready` | `applying` | apply gate opened (automatic), or the user asked (§4.6) |
| `applying` | `idle` | migration succeeded (`current` = B), or failed and A was restored. `lastResult` records `installed(B)` or `rejected(B, failure)` |

**Relation to `RuntimeImageState`** ([state-machines.md](../01-architecture/state-machines.md) §7): while B downloads and installs, `RuntimeImageState` stays `installed(A)`. Its `installing(progress)` state is used only for the first image, at provisioning. `applying(A, B)` corresponds to `migrating(A, B)`.

**Persistence:** `Images/update-state.json` is written only by `ImageUpdateCoordinator`. It holds the channel, `lastCheckAt`, `nextCheckAt`, backoff, feed ETag, highest accepted sequence per channel, candidate, download state (partial file, bytes, server ETag), phase, rejected versions, `lastAutomaticApplyAt`, and the versions already notified. Transient phases (`checking`, `installing`) are stored as the phase before them, so a restart runs them again. At startup the coordinator reconciles `applying` with `RuntimeImageState`: `installed(A)` means the migration was rejected; `installed(B)` means it succeeded.

### 4.4 Download

- `ImageDownloader` downloads over HTTPS into `Cache/images/<imageVersion>.aar.partial`, hashing with SHA-256 as bytes arrive. To resume it sends `Range: bytes=<n>-` with `If-Range: <ETag>`. A `200` reply restarts from zero. Before resuming, it re-hashes the partial file. When size and hash match, it renames the file to `.aar`. If the server sends more than `size` bytes, it stops with `imageArchiveSizeMismatch`.
- **Space:** before downloading and before installing, free space must be at least archive size + `expandedSize` + 10 GiB; otherwise `insufficientSpace`, and the Storage pane explains what is needed. A manual install (§4.5) has no `expandedSize`: it needs file size + 10 GiB before it starts, and extraction stops with `insufficientSpace` when less than 10 GiB would remain ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.3).
- **Network:** background downloads use `networkServiceType = .background`, `waitsForConnectivity`, `allowsExpensiveNetworkAccess = false`, and `allowsConstrainedNetworkAccess = false`. They wait while Low Power Mode is on. A user-initiated download on an expensive or constrained network asks first: "This download is ‹1.8 GB›. You're on a network that may charge for data."
- Background downloads run only while `maintenance.downloadImagesAutomatically` is on (default). With it off, the phase stays `available` until the user clicks.
- A running download counts as an operation in flight, so apkrund does not exit ([runtime-daemon.md](runtime-daemon.md) §2.4). It never starts Android. After sleep, the download resumes 2 minutes after wake.
- **Cancel** (Settings, or Ctrl-C of `apkrun image install --latest`) keeps the partial file for a later resume. Partial files are deleted after 7 days or when a newer candidate replaces them.

### 4.5 Installing into `Images/`

`ImageStore.install(from: .archive(url))` ([android-image.md](android-image.md) §10.4) extracts with the AppleArchive framework under these rules:

- Every entry is a regular file or directory with a relative path inside the bundle root. Entries with `..`, absolute paths, symlinks, hard links, devices, or FIFOs are rejected. Permissions are reset (0644 files, 0755 directories); extended attributes and ACLs are dropped. A violation gives `imageArchiveUnsafeEntry(path)`: the install stops and `Images/.installing-*` is removed.
- Verification: signature → manifest schema → every file ([android-image.md](android-image.md) §10.1). The manifest must also agree with the feed entry (§4.1 rule 6).
- The archive is deleted after a successful install.
- An install changes neither `current` nor `previous`. It needs neither Android nor user confirmation.

`apkrun image install <file.aar>` and **Install from File…** in Settings → Storage use the same install. The file reaches apkrund as a file handle, as package imports do, so apkrund never opens a user-chosen path. Release builds accept only images signed with the release keys. Unpacked bundle directories are for development only (`apkrun dev image install`, [android-image.md](android-image.md) §10.3). The apply step that follows is user-initiated (§4.6).

### 4.6 When an update is applied

**Automatic apply gate** (`maintenance.installImages == automatic`, the default). All conditions must hold:

| # | Condition |
|---|---|
| A1 | phase is `ready`, B is not rejected, and `RuntimeImageState` is `installed(A)` |
| A2 | no session exists except `ended` ones. No activity assertion exists (background task, store operation, ADB client, `runtime start --hold`, diagnostics; [runtime-daemon.md](runtime-daemon.md) §5.1). No package transaction runs, and no app update is in `installing`, `healthChecking`, or `rollingBack` |
| A3 | host state is `normal` (§3.6) |
| A4 | user idle for at least 10 minutes (`HIDIdleTime`) |
| A5 | AC power, Low Power Mode off, `ProcessInfo.thermalState` is `nominal` or `fair` |
| A6 | at least 10 GiB free ([android-image.md](android-image.md) §12.3 precondition) |
| A7 | no automatic apply attempt in the last 24 hours |

The coordinator evaluates the gate every 5 minutes while an image is `ready` and apkrund runs, and on events that can open it: a session ended, the power source changed, an activity was released. apkrund does not stay alive only to wait for the gate. The hourly `StartInterval` wake evaluates it too.

**User-initiated apply:** Settings **Update Android Now…**, the notification's **Update Now**, or `apkrun image install --latest` (which also downloads and installs if needed). A1, A3, and A6 still apply. If sessions or background tasks exist, the user is asked first; the dialog names the apps that close and offers **Cancel** and **Close Apps and Update**. Store transactions are waited for (at most 2 minutes). A4, A5, and A7 are ignored. On battery below 20 %, the dialog adds a warning.

**Ask mode** (`maintenance.installImages == ask`): nothing is applied automatically. When an image becomes `ready`, APKRun posts "Android system update ready" once, with **Update Now** and **Later**, and shows it in Settings and the menu bar. It reminds once more after 7 days, or after 1 day for a `critical` image.

**A gate that never opens:** in automatic mode, if an image has been `ready` for 7 days (for example, the Mac is never idle on AC power), APKRun posts the same notification once. A `critical` image gets it after 1 day.

### 4.7 The migration

`ImageUpdateCoordinator.apply(B, userInitiated:)` calls `RuntimeSupervisor.migrateImage(to: B, operation:)`, which runs the steps of [android-image.md](android-image.md) §12.3 with these additions:

1. **Sessions** end with `ended(.runtimeUpdating)`, with the user's consent in the user-initiated case. A wrapper shows screen U and calls `openSession` again. apkrund accepts the new session and holds it in `waitingForRuntime` until the migration's health check has finished (§7.5).
2. **Activity and power:** the supervisor holds the `.migration` activity assertion, so the idle policy never suspends the first boot. It also holds an `IOPMAssertionTypePreventUserIdleSystemSleep` assertion named "Updating Android". The 15-minute first-boot timeout is measured with `SuspendingClock`, so time asleep does not count.
3. **Progress:** `RuntimeState` goes through `booting(BootPhase)` as usual. `RuntimeStatus` and the `runtime` topic also carry `bootPurpose = .imageUpdate(from: A, to: B)` (default `.normal`), so the runtime header shows "◐ Updating Android… (‹phase›)" instead of "Starting Android…", and so do the menu bar and waiting wrappers.
4. **Afterwards:** Android returns to its earlier state. Waiting sessions go ahead. If Android was stopped before an automatic apply, it is stopped right after the health check. If it was running without sessions, it stays `ready` and the idle policy takes over.
5. **On failure** (step 6b, A restored): Android boots A only if a session is waiting. APKRun always posts "Android couldn't be updated to ‹B›. Your apps and data are unchanged." with **Report a Problem…** (`apkrun://report`, [diagnostics.md](diagnostics.md) §8.5). B is rejected (§4.8).
6. **Crash safety:** [android-image.md](android-image.md) §12.3 (a `migration` field in `instance.json`, found at startup, is treated as failed). The coordinator's own phase is reconciled as in §4.3.

After a restore, APKStoreCore reconciles packages with the restored userdata ([package-store.md](package-store.md) §9): the generation changed, so packages are reinstalled or updated from their stored artifact sets, as the reconciliation rules say.

### 4.8 Rejected versions and rollback

- A failed migration rejects B: `rejected[B] = { at, reason }` in `Images/update-state.json`. Automatic updates skip B; a newer version is offered normally. The user can retry B from Settings ("The last attempt to update to ‹B› failed. Try Again?") or with `apkrun image install --latest`, which asks, or proceeds with `--yes`.
- B's installed directory is kept for 7 days, for diagnostics and a retry without downloading. Then GC deletes it.
- **Going back** ("Go Back to Android ‹A›…" in Settings → Storage, `apkrun image rollback`) is possible while recovery point R from the last migration and the `previous` image A exist, which is until the next migration. It restores R ([android-image.md](android-image.md) §12.3) after a confirmation. The dialog names the target version and says that Android changes since the recovery point, including app data, are lost, and that apps added since are reinstalled without data. Buttons: **Cancel**, **Go Back**.

The rolled-back version is then rejected with reason `userRolledBack`, so it is not applied again automatically.

### 4.9 Garbage collection and disk use

- `ImageStore.garbageCollect()` runs after every migration, rejection, and install, and once a day. It keeps `current`, `previous`, a `ready` image, and a rejected image younger than 7 days. It deletes everything else under `Images/`.
- Recovery points follow [android-image.md](android-image.md) §12.2: after a successful migration only the newest is kept. APKRun never deletes it automatically, because that removes the way back. The Storage pane and `image.freeSpace` suggest deleting it when free space is below 10 GiB.
- `Cache/images/`: partial downloads older than 7 days, and archives of images already installed, are deleted.
- The Storage pane ([host-ui.md](host-ui.md) §9.7) shows "Android system": the current version with its size, the previous version, a ready update, and the recovery point with its date.

### 4.10 An image this APKRun can't boot

Rules R2–R4 should prevent this. It can still happen after a long time without image updates (updates failing, or automatic checks off), combined with an APKRun update that dropped an old guest protocol major.

- **Detection:** the post-update tasks (§3.8) and every boot preparation ([android-image.md](android-image.md) §9.3 step 3) report `ImageFailure.incompatibleProtocol` or `incompatibleRuntime`.
- **Behavior:** Android stays `stopped`. `ensureReady` fails with `RuntimeFailure.image(…)`. Its action is `updateAndroid` for `incompatibleProtocol / hostNewer` ([diagnostics.md](diagnostics.md) §2.3), and `updateAPKRun` for `incompatibleProtocol / guestNewer` and `incompatibleRuntime` ([error-catalog.md](../03-reference/error-catalog.md) §9).
- **`incompatibleProtocol / hostNewer`** (the image is too old for this APKRun): only a newer image helps. The coordinator checks the feed at once and downloads without waiting for the network rules. Nothing can run meanwhile, so it applies the image as soon as it is `ready`, ignoring A4, A5, and A7. Home and the wrappers show "Android needs an update to work with this version of APKRun." with progress.
- **`incompatibleProtocol / guestNewer` and `incompatibleRuntime`** (the image needs a newer APKRun): a newer image does not help, so nothing is checked or downloaded. Home and the wrappers show the entry's text with **Check for Updates** (`updateAPKRun`).
- If the feed has no image this APKRun can boot, the result is `noCompatibleImage`. That is a release defect. The remediation is to install the previous APKRun from the website. The action is `openDownloadsPage` ([diagnostics.md](diagnostics.md) §2.3), which opens the Info.plist URL `APKRunDownloadsURL` ([configuration.md](../03-reference/configuration.md) §7.1). `LauncherBuild.downloadURL` ([wrapper.md](wrapper.md) §5.4) is the same URL.

The opposite case, an image that needs a newer APKRun, can come only from a manual install. It is refused at activation (`incompatibleRuntime`, "Update APKRun").

### 4.11 Security patches and time zone data

- The Android security patch level and the time zone database change only with image updates. If Android does not know a Mac time zone, [desktop-integration.md](desktop-integration.md) §9 falls back to `Etc/GMT∓h`. Rule R7 sets the cadence.
- A `critical` feed entry skips the rollout (C6) and gets the shorter reminders of §4.6.
- Settings → General and `image.current` show the security patch level of the current image.

---

## 5. Host data schema migrations

| File | Owner |
|---|---|
| `state.json`, `settings.json`, `Runtime/daemon.json`, `Runtime/maintenance.json` | RuntimeHost (paths from DiagnosticsCore) |
| `Packages/<id>/metadata.json`, `Packages/<id>/settings.json`, `Packages/journal.jsonl` | APKStoreCore |
| `Wrappers/registry.json` | WrapperCore |
| `Updates/state.json`, `Updates/history.jsonl` | UpdateCore |
| `Images/update-state.json`, `Runtime/instance/instance.json` | ImageCore |

- Every JSON file has an integer `schemaVersion`. Every line of a JSONL file has it (`"v"`).
- A build knows its current schema for each file (`components.json dataSchemas`, §2.1). It has a migration step `n → n+1` for every older schema in the R5 window.
- **On load:** read the file. Keep the original bytes as `<name>.v<old>.json` next to it (one backup per old version, deleted 90 days after the migration). Migrate in memory, validate, and write atomically (`FileManager.replaceItemAt`). `Packages/` records are migrated in one journaled store transaction (`schemaMigration`), so a crash mid-way resumes at the next start ([package-store.md](package-store.md) §5).
- **A newer schema than the build understands:** the owning component starts degraded ([runtime-daemon.md](runtime-daemon.md) §2.2 step 4) with `maintenance.dataCreatedByNewerVersion(file, schema, supported)`: "This data was created by a newer version of APKRun. Install the latest version of APKRun." The file is never written. The package store limits this to one package: a newer `metadata.json` or `settings.json` makes that package read-only with `store.metadataUnreadable`, and a newer journal makes the store degraded ([package-store.md](package-store.md) §5.4).
- Additive changes also raise the schema version. `Codable` drops unknown keys, so an older build that wrote the file would lose the new fields.
- Migrations never change what a value means. The acceptance test of #057 compares decoded `PackageRecord`s field by field before and after an update.
- The journal is normally clean at an update, because §3.5 step 4c waits for transactions. A newer build still replays older journal entries, because each entry has its version.
- T0 golden fixtures: `Tests/Fixtures/schemas/<file>/v<n>.json`, each migrated to the current schema and compared with `v<n>.expected.json`.

---

## 6. Settings

The keys are also listed in [configuration.md](../03-reference/configuration.md).

| Key | Values | Default | Meaning |
|---|---|---|---|
| `maintenance.checkAutomatically` | bool | `true` | daily checks for APKRun updates (Sparkle and the probe) and Android system updates |
| `maintenance.channel` | `stable`, `beta` | `stable` | channel for both. Switching from beta to stable never downgrades: APKRun and the image stay on their builds until stable passes them |
| `maintenance.installAPKRunAutomatically` | bool | `false` | Sparkle downloads updates in the background and installs them when APKRun.app quits (§3.5.1, §3.6) |
| `maintenance.downloadImagesAutomatically` | bool | `true` | download Android system updates in the background (§4.4) |
| `maintenance.installImages` | `automatic`, `ask` | `automatic` | apply at idle (§4.6), or wait for the user |
| `maintenance.notifyImageInstalled` | bool | `false` | notify after a successful automatic Android system update |

---

## 7. User-facing surfaces

### 7.1 Settings → General ([host-ui.md](host-ui.md) §9.1)

The Updates section shows the versions (`APKRun 1.2.0 (1200) · Android 2026.10.0 (security patch 5 September 2026)`), the checkboxes and radio buttons of §6, **Check Now** with "Last checked …", and one status line:

- `APKRun 1.3.0 is available.` with **Install Update…**
- `APKRun 1.3.0 will be installed when you quit APKRun.` with **Install and Relaunch Now**
- `Android 2026.11.0 is ready to install.` with **Update Android Now…**
- `Downloading Android 2026.11.0… 45 % of 1.8 GB` with **Cancel**
- `A newer Android version needs APKRun 1.3 or later.` with **Install Update…**
- `The last Android update failed. Android 2026.10.0 is still in use.` with **Try Again** and **Report a Problem…**

**Install Update…** starts a user-initiated Sparkle check with its UI. When this pane opens, it also runs Sparkle's `checkForUpdateInformation()` (no UI), at most once every 5 minutes, so the status line is current. Wrapper screen V opens this pane (§7.5).

### 7.2 Settings → Storage ([host-ui.md](host-ui.md) §9.7)

The "Android system" rows of §4.9, **Go Back to Android ‹A›…** while a rollback is possible (§4.8), **Install from File…** (§4.5), and the recovery point with **Delete…**.

### 7.3 Home and menu bar

| Situation | Home runtime header ([host-ui.md](host-ui.md) §5.2) | Menu bar ([host-ui.md](host-ui.md) §12) |
|---|---|---|
| migration running | "◐ Updating Android… (‹phase›)" | the same text in the runtime line |
| `restartPending` (§3.6) | banner "APKRun was updated. Restart Android to finish. ‹N› apps will close." with **Restart Now** (`restartForUpdate(closeSessions: true)`) | "Finish updating APKRun…" |
| incompatible image, `incompatibleProtocol / hostNewer` (§4.10) | banner "Android needs an update to work with this version of APKRun." with the progress | the same text |
| incompatible image, `guestNewer` or `incompatibleRuntime` (§4.10) | the entry's text with **Check for Updates** | the same text |
| APKRun update available | — (Sparkle shows its alert) | "APKRun ‹version› is available" with **Update…** |
| Android system update ready (ask mode, or waiting 7 days) | — | "Android system update ready" with **Update Now** |

### 7.4 Notifications

APKRun.app posts them through `HostNotificationClient` ([host-ui.md](host-ui.md) §11).

| Notification | When | Actions |
|---|---|---|
| "APKRun ‹version› is available" | from the probe, while APKRun.app is not running. Once per version; a critical update again after 3 days | **Update…** |
| "Android system update ready" | ask mode, or automatic mode after 7 days of waiting (§4.6) | **Update Now**, **Later** |
| "Android was updated to ‹B›" | after a successful automatic update, only with `maintenance.notifyImageInstalled` | — |
| "Android couldn't be updated to ‹B›. Your apps and data are unchanged." | every failed migration | **Report a Problem…** |
| "Android needs an update to work with this version of APKRun" | §4.10 `incompatibleProtocol / hostNewer`, while no APKRun window is open | **Open APKRun** |

### 7.5 Wrappers

Launcher screen **U** ([wrapper.md](wrapper.md) §5.4): "APKRun is updating. ‹App› opens again when the update is finished." It has only **Quit**. It appears:

- on `ended(.runtimeUpdating)`, for an APKRun update and for an Android system update;
- when `HelloReply.hostState` is `updating`, or `openSession` fails with `RuntimeFailure.hostUpdating`.

While U is shown, the launcher tries to connect and call `openSession` every 2 s for up to 10 minutes. During an Android system update, `openSession` is accepted at once and the placeholder shows "Updating Android…" until the session goes ahead (§4.7). After 10 minutes the launcher shows screen E with `hostUpdating` and **Try Again**. If the new APKRun no longer serves the wrapper's API major, the next `hello` leads to screen L.

Screen V ("‹App› needs APKRun ‹minimum› or later.") opens `apkrun://settings/general` for **Check for Updates** (§7.1). URLs only navigate; the pane runs the harmless information check.

### 7.6 CLI ([cli.md](cli.md) §4.7)

| Command | Behavior |
|---|---|
| `apkrun self-update check [--json]` | runs the probe through apkrund as a user-initiated check (phasing ignored). Prints "APKRun 1.3.0 is available (you have 1.2.0). Open APKRun to install it." or "APKRun is up to date." Exit 0 either way; `--json` has `available`. If apkrund is unreachable: exit 69, "Open APKRun to check for updates." |
| `apkrun self-update install` | opens `apkrun://settings/general`, where the update is installed. The CLI does not wait |
| `apkrun self-update finish [--yes]` | in `restartPending`: restarts the runtime on the new build. Asks first when apps are open ("2 apps will close"). Without a pending restart: "Nothing to finish." |
| `apkrun image list`, `check`, `install (<file.aar> \| --latest) [--yes]`, `rollback [--yes]`, `recovery-points list \| delete <id>` | as listed in [cli.md](cli.md) §4.7. `image install --latest` downloads, installs, and applies, whichever steps are still needed (§4.6). `image check` exits 0 and prints the phase, the candidate, and any `requiresNewerAPKRun` |

---

## 8. Runtime API surface

The DTOs are in [runtime-api.md](../03-reference/runtime-api.md).

### 8.1 Maintenance endpoint (version-stable)

The endpoint kind is `.maintenance`, with the same code-signing requirement as `.control` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2). Its protocol `MaintenanceControl` is **frozen**: no major version; changes are additive only (new optional fields, new operations). It must work between an old apkrund and a new APKRun.app (§3.6, §3.7), and between an old APKRun.app and an old apkrund in `updating`, even when the RuntimeAPI major changes. The endpoint is available in every host state.

| Operation | Behavior |
|---|---|
| `maintenanceStatus()` | `MaintenanceStatus { version, build, hostState, sessions: [PackageID], backgroundTasks: [PackageID], activities: [ActivityKind], imageMigrating, marker? }` |
| `prepareForHostUpdate(HostUpdateRequest{ targetVersion, targetBuild, closeSessions })` | §3.5 step 4. Errors: `hostUpdateBusy(ActivityKind)`, `hostUpdateSessionsOpen([PackageID])` (when `closeSessions` is false), `selfUpdateNotNewer` |
| `abortHostUpdate()` | deletes the marker; host state becomes `normal`. Idempotent |
| `completeHostUpdate()` | ends the finishing wait (§3.6). Idempotent |
| `restartForUpdate(closeSessions)` | in `restartPending`: ends sessions with `.runtimeUpdating`, stops Android, exits. Returns `hostUpdateSessionsOpen` if sessions exist and `closeSessions` is false |

### 8.2 Control endpoint

| Operation | Behavior | Long operation |
|---|---|---|
| `selfUpdateStatus()` | `SelfUpdateStatus` (§3.4) | no |
| `checkSelfUpdate(userInitiated)` | runs the probe | no (30 s timeout) |
| `noteSelfUpdateStatus(SelfUpdateNote{ found: AvailableRelease?, pendingOnQuit, checkedAt })` | APKRun.app reports Sparkle's results ([runtime-api.md](../03-reference/runtime-api.md) §12.2) | no |
| `imageUpdateStatus()` | phase, candidate and sizes, `requiresNewerAPKRun`, rejected versions, last result, and the gate conditions that are false | no |
| `checkImageUpdate()` | user-initiated check | yes |
| `downloadImageUpdate()`, `cancelImageDownload()` | §4.4 | yes / no |
| `applyImageUpdate(ApplyImageUpdateRequest{ version, closeSessions, retryRejected })` | user-initiated apply (§4.6) | yes |
| `installImage(ImageInstallRequest{ source: .file(fileIndex:) \| .latest, apply })` | §4.5, then apply if `apply`. This is the `imageInstall` long operation of [runtime-daemon.md](runtime-daemon.md) §8.3 | yes |
| `rollbackImage(RollbackImageRequest{ confirmed })` | §4.8 | yes |
| `listImages()`, `recoveryPoints()`, `deleteRecoveryPoint(id)` | [android-image.md](android-image.md) §12.2 | no |

A file source passes as a file handle, named by its index in the request ([runtime-api.md](../03-reference/runtime-api.md) §4.9). Wrappers get only `hostState` in `HelloReply` and the `hostUpdating` error. They have no maintenance operations.

### 8.3 Events

Topic `maintenance` ([runtime-daemon.md](runtime-daemon.md) §8.4):

```swift
public enum MaintenanceEvent: Codable, Sendable {
    case hostStateChanged(HostState)
    case selfUpdateStatusChanged(SelfUpdateStatus)
    case imageUpdatePhaseChanged(ImageUpdatePhase)
    case imageUpdateProgress(OperationID, fraction: Double, bytes: Int64?)   // coalesced to 10 Hz
    case imageUpdateFinished(ImageUpdateOutcome)   // .installed(ImageVersion), .rejected(ImageVersion, MaintenanceFailure), .rolledBack(to: ImageVersion)
}
```

---

## 9. Persistence

| Data | Location | Writer |
|---|---|---|
| host-update marker | `Runtime/maintenance.json` (§3.6) | apkrund |
| image update state | `Images/update-state.json` (§4.3) | apkrund (`ImageUpdateCoordinator`) |
| downloads | `Cache/images/` (§4.4). Safe to delete | apkrund (`ImageDownloader`) |
| last runtime version | `state.json`: `lastRuntimeVersion`, `lastRuntimeBuild` | apkrund |
| self-update probe | `state.json`: `selfUpdate { lastCheckedAt, etag, lastModified, notifiedVersions, criticalNotifiedAt }` (§3.4). Losing it gives at most one extra check and one repeated notification | apkrund (`SelfUpdateProbe`) |
| data backups | `<name>.v<old>.json` next to each migrated file (§5) | the owning store |
| APKRun.app bookkeeping | UserDefaults of `io.apkrun.APKRun`: `lastLaunchedBuild`, `registeredAgentPlistSHA256`. Sparkle's own keys are not authoritative (§3.2) | APKRun.app |

---

## 10. Security

| Threat | Mitigation |
|---|---|
| a forged APKRun update | Sparkle's EdDSA signature over the archive, the Developer ID check against the installed bundle, HTTPS, and a signed appcast (§3.2, §3.3) |
| a tampered appcast used to show fake notifications | the probe checks the signed appcast, and it only informs (§3.4) |
| a downgrade to a vulnerable APKRun | Sparkle installs only a higher `sparkle:version`; `criticalUpdate` marks security fixes |
| a forged Android image | feed signature, archive SHA-256, and manifest signature, all against `ImageTrustStore` (§4.1, §4.5) |
| replay of an old feed (freeze or rollback attack) | `sequence` and `expiresAt` (§4.1 rule 4). Images are never downgraded automatically |
| path tricks in an archive | the extraction rules of §4.5 |
| another local process forcing updates or restarts | the maintenance and control endpoints require APKRun's signing identity. `apkrun://` URLs only navigate |
| a compromised signing key | Sparkle: a new EdDSA key is shipped in a release signed with the old key (Sparkle's key rotation), never together with a Developer ID change (R6). Images: the key ID is removed from `ImageTrustStore` in an APKRun release, and feed and manifests are signed with a new key |

Privacy: the probe and the feed client send no identifiers. There is no system profile. The rollout bucket (C6) is computed on the Mac. The `User-Agent` is `APKRun/<version> (macOS <version>)`.

---

## 11. Errors

`MaintenanceFailure` is the error domain `maintenance` ([diagnostics.md](diagnostics.md) §2.1). Codes, messages, and remediations are in [error-catalog.md](../03-reference/error-catalog.md).

```swift
public enum MaintenanceFailure: APKRunError {
    // APKRun updates
    case selfUpdateFeedUnreachable(detail: String)
    case selfUpdateFeedInvalid(detail: String)
    case selfUpdateNotNewer(current: Int, target: Int)
    case sparkle(code: Int, detail: String)                 // SUError code from Sparkle
    case hostUpdateBusy(ActivityKind)                       // "migration", "storeOperation"
    case hostUpdateSessionsOpen([PackageID])
    case hostUpdateStopFailed(RuntimeFailure)
    case hostUpdateAbandoned(targetBuild: Int)
    case agentRegistrationFailed(status: String)
    case dataCreatedByNewerVersion(file: String, schema: Int, supported: Int)
    case schemaMigrationFailed(file: String, from: Int, to: Int, detail: String)
    // Android system updates
    case imageFeedUnreachable(detail: String)
    case imageFeedHTTPStatus(Int)
    case imageFeedSignatureInvalid(keyID: String?)
    case imageFeedInvalid(detail: String)
    case imageFeedReplayed(sequence: Int, highest: Int)
    case imageFeedExpired(Date)
    case noCompatibleImage(NoImageReason)                   // .requiresNewerAPKRun(String), .protocol, .userdataSchema, .none
    case imageDownloadFailed(detail: String)
    case imageArchiveSizeMismatch(expected: Int64, actual: Int64)
    case imageArchiveHashMismatch
    case imageArchiveUnsafeEntry(path: String)
    case imageInstallFailed(ImageFailure)
    case insufficientSpace(required: Int64, available: Int64)
    case imageUpdateNotReady                                 // apply requested without a ready image
    case imageUpdateRejected(ImageVersion)                   // apply of a rejected version without retryRejected
    case imageMigrationFailed(ImageFailure)
    case rollbackUnavailable
    case cancelled
    // health findings (§12), never thrown
    case criticalUpdateWaiting(version: String)              // maintenance.selfUpdate: critical update available for more than 3 days
    case selfUpdateCheckOverdue                              // maintenance.selfUpdate: no successful check for 7 days while automatic checks are on
    case hostDowngraded(version: String)                     // maintenance.selfUpdate: APKRun was downgraded from version
    case imageUpdateWaiting(version: ImageVersion)           // maintenance.imageUpdate: ready for more than 14 days
    case imageCheckOverdue                                   // maintenance.imageUpdate: no successful feed check for 7 days
}
```

Other domains gain these cases:

- `RuntimeFailure.hostUpdating`: remediation "APKRun is updating. Try again in a minute." ([runtime-daemon.md](runtime-daemon.md) §11).
- `SessionEndReason.runtimeUpdating` ([state-machines.md](../01-architecture/state-machines.md) §3).
- `StopReason.hostUpdate` ([runtime-daemon.md](runtime-daemon.md) §3.1).
- `RemediationAction.updateAndroid` ([diagnostics.md](diagnostics.md) §2.3): opens Settings → General and starts the Android system update.

---

## 12. Logging, markers, health

- `os_log` subsystem `io.apkrun.maintenance` ([diagnostics.md](diagnostics.md) §3.1): category `selfUpdate` (APKRun.app and apkrund) and `imageUpdate` (apkrund). Logged: check results (versions, HTTP status, feed sequence), host state changes, marker actions, gate evaluations (which condition was false), download ranges and resumes, install timing, and migration steps (the image module also logs them, [android-image.md](android-image.md) §14.2). Paths are logged relative to the data root.
- Markers ([diagnostics.md](diagnostics.md) §4.2): `SELF_UPDATE_CHECK_END`, `HOST_UPDATE_PREPARE_START`, `HOST_UPDATE_PREPARED`, `HOST_UPDATED`, `IMAGE_CHECK_END`, `IMAGE_DOWNLOAD_START`, `IMAGE_DOWNLOAD_END`, `IMAGE_INSTALL_END`, `IMAGE_MIGRATION_START`, `IMAGE_MIGRATION_END`, `IMAGE_ROLLBACK_END`.
- The diagnostics bundle gets `maintenance/state.json`: `SelfUpdateStatus`, `HostState`, the marker, and `Images/update-state.json`. Feed URLs are public, so they are kept.

| Check | Requirement | Pass | Info | Warning | Failure |
|---|---|---|---|---|---|
| `maintenance.selfUpdate` | daemon | up to date, with a successful check in the last 7 days | an update is available, or automatic checks are off | a critical update has been available for more than 3 days; no successful check for 7 days while automatic checks are on; `restartPending` for more than 24 hours; an abandoned host update in the last 24 hours; APKRun was downgraded | — |
| `maintenance.imageUpdate` | daemon | up to date, or an update in progress | an update is downloading or ready; a newer image needs a newer APKRun | ready for more than 14 days; the last migration was rejected (in the last 7 days); the feed signature is invalid, replayed, or expired; no successful feed check for 7 days; not enough space for the update | the current image can't boot with this APKRun (§4.10) |

The warnings of `maintenance.selfUpdate` are, in order, `maintenance.criticalUpdateWaiting`, `maintenance.selfUpdateCheckOverdue`, `diagnostics.serviceVersionMismatch / restartPending`, `maintenance.hostUpdateAbandoned`, and `maintenance.hostDowngraded`. The warnings of `maintenance.imageUpdate` are `maintenance.imageUpdateWaiting`, `maintenance.imageMigrationFailed`, the feed errors of §11, `maintenance.imageCheckOverdue`, and `maintenance.insufficientSpace`. Its failure is `image.incompatibleProtocol / hostNewer`, `image.incompatibleRuntime`, or `maintenance.noCompatibleImage` ([error-catalog.md](../03-reference/error-catalog.md) §20.2).

`apkrund.version` ([diagnostics.md](diagnostics.md) §7.3) reports a `restartPending` apkrund. Its remediation is "An APKRun update is waiting for your Android apps to close. Close them, or choose Restart Now."

---

## 14. Tests

| Tier | Test | Location |
|---|---|---|
| T0 | `components.json` equals the compiled constants (§2.1) | `Packages/<Module>/Tests/` |
| T0 | appcast parsing for the probe: channels, `minimumSystemVersion`, phased rollout, critical updates, a malformed feed, a bad feed signature | same |
| T0 | marker rules at startup (§3.6), one case per table row, with a fake clock | same |
| T0 | schema migration golden fixtures for every file and version (§5); a newer schema gives `dataCreatedByNewerVersion` and writes nothing | same |
| T0 | feed validation (§4.1): signature, channel, sequence, expiry, unknown fields, unknown schema; manifest–feed agreement | same |
| T0 | candidate selection C1–C7, including the rollout bucket distribution (10,000 random instance IDs within ±2 % of the percentage) | same |
| T0 | archive extraction rules with crafted archives: `..`, absolute paths, symlinks, hard links, devices, extra files | same |
| T1 | `MaintenanceService` with a fake runtime: `prepareForHostUpdate` refused during a migration; waits for store transactions; sessions end with `.runtimeUpdating`; stop with the deadline; exit after the reply | `Tests/IntegrationTests/` |
| T1 | `BundleWatcher`: replacing the bundle's `Info.plist` in a temporary copy gives `restartPending`; exit happens only after the last session ends | same |
| T1 | `ImageUpdateCoordinator` with a fake store, supervisor, and clock: every transition of §4.3, a restart in each persisted phase, the gate A1–A7, ask-mode reminders, a rejected version skipped, rollback | same |
| T1 | downloader against a local HTTP server: resume with `Range`/`If-Range`, a `200` reply to a range request, a server sending too many bytes, a hash mismatch | same |
| T2 | **APKRun N → N+1 (#057 acceptance).** Builds 9000 and 9001 of the `ReleaseUpdateTest` configuration from the same commit; 9001 adds `Resources/test-build-marker`. Install 9000, provision image A, install HelloText and HelloUpdate V1, create both wrappers, write data (HelloText counter). Record the SHA-256 of every file under `Packages/` (except `.trash/`), the decoded `PackageRecord`s, `Wrappers/registry.json`, and every file of both wrapper bundles. Open HelloText. Trigger the update with a test user driver that accepts every prompt (§3.2), with the local appcast offering 9001. Expect: HelloText shows screen U and reopens by itself on 9001; the running apkrund reports build 9001, and `Resources/test-build-marker` is in its bundle; `Runtime/maintenance.json` is gone; the `Packages/` hashes, records, registry, and both wrapper bundles are unchanged; the journal has no open transaction; `apkrun list` shows the same packages and versions; HelloText's counter is kept; HelloUpdate still launches; the agent is registered (`SMAppService.status == .enabled`) | `Tests/IntegrationTests/` |
| T2 | variants of the update test: (a) Install When Apps Are Closed: nothing happens until HelloText closes, then the update runs; (b) bundle replaced with `ditto` while HelloText is open: `restartPending`, HelloText keeps running, apkrund 9001 serves the next launch after it closes; (c) APKRun.app killed right after `prepareForHostUpdate`, with `APKRUN_TEST_MARKER_TIMEOUT=30s`: marker cleared, next launch works on 9000; (d) 9001 with a changed agent plist: re-registration happens, and no session is killed | same |
| T2 | migration A → B, and a failed migration B → B′ that returns to B ([android-image.md](android-image.md) §12.4), started with `apkrun image install` | same |
| T2 | a session opened during a migration waits, then opens on the new image; after an induced failure it opens on the previous image | same |
| T2 | feed-driven update on the lab Mac: image A installed, local feed offering B. apkrund downloads B in the background, applies it once the gate opens (test hooks for idle time and power source), and HelloText's data is kept (#087 acceptance) | same |
| T3 | release smoke matrix (R2): each release candidate against the current and the previous stable image | manual, [test-strategy.md](../04-plan/test-strategy.md) §9.2 |

---

## 15. Open items

- [R-23](../04-plan/risks.md): Sparkle details to confirm with the pinned version: the two recent Info.plist keys, installing a postponed update on quit (§3.5.1), the signed appcast format, and whether plain HTTP on loopback works for tests.
- [R-24](../04-plan/risks.md): whether launchd runs the new apkrund from a replaced bundle without re-registration when the agent plist is unchanged. Fallback: re-register on every build change (§3.7).
- [OQ-01](../04-plan/open-questions.md): hosting domain for the appcast, the feed, and the archives. Until settled, `<updates host>` is the placeholder.
- [OQ-26](../04-plan/open-questions.md): default of `maintenance.installAPKRunAutomatically`. Working default: off in v1; review after 1.0.
- [R-25](../04-plan/risks.md): extraction writes the zero runs of `os.img` before the holes are punched (§4.5). Fallback: a sparse-aware extraction sink.
- [OQ-27](../04-plan/open-questions.md): delta image updates. Working default: v1 downloads full archives.
- [OQ-28](../04-plan/open-questions.md): automatic rollback of APKRun itself. Working default: install an older release by hand (§3.9).
