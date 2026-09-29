# Runtime Maintenance: APKRun Updates and Android System Updates

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [android-image.md](android-image.md) §9.3, §10.4, §12, [runtime-daemon.md](runtime-daemon.md) §2, §3, §8, §9, [update-system.md](update-system.md) (Android app updates, a separate system), [wrapper.md](wrapper.md) §5.3–§5.5, §9.4, [host-ui.md](host-ui.md) §5.2, §9.1, §9.7, §11, §12, [cli.md](cli.md) §4.7, [diagnostics.md](diagnostics.md), [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.1, §2.2, [../01-architecture/security-model.md](../01-architecture/security-model.md) §7, [../01-architecture/decisions/0016-sparkle-host-updates.md](../01-architecture/decisions/0016-sparkle-host-updates.md), [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) (manifest and image feed formats) |
| Tasks | #057 APKRun runtime updater (M10), #058 guest image versioning and migration (M10; this document has the orchestration and UI, [android-image.md](android-image.md) §12 has the data steps), #087 runtime image distribution (M10) |

This document covers two of APKRun's four update systems:

| Update | What changes | Where it is designed |
|---|---|---|
| Android application | an APK set inside Android | [update-system.md](update-system.md) |
| **APKRun runtime** ("APKRun update") | the APKRun.app bundle: APKRun.app, apkrund, APKRunMenuBar, the CLI, the launcher template, VirGLRuntime | this document, §3 (#057) |
| **Android guest image** ("Android system update" in the UI) | the runtime image bundle: AOSP, kernel, Mesa, the guest agents | this document, §4 (#058, #087), and [android-image.md](android-image.md) §10.4, §12 |
| Wrapper metadata | a wrapper's name, icon, URL handling, window preferences | [wrapper.md](wrapper.md) |

The design says "Do not mix them." APKRun updates and Android system updates have separate code paths, state files, schedules, and UI rows. They are connected in only two ways: the compatibility contract (§2.2), and a mutual-exclusion rule so that the two never run at the same time (§2.4).

---

## 1. Responsibilities and components

| Component | Module, process | Responsibility | Section |
|---|---|---|---|
| `SelfUpdateController` | APKRun.app (`Apps/APKRun/Maintenance/`) | owns Sparkle's `SPUStandardUpdaterController`, maps settings to Sparkle, implements `SPUUpdaterDelegate` | §3.2 |
| `UpdateInstallCoordinator` | APKRun.app | the safe-restart handshake with apkrund before Sparkle installs | §3.5 |
| `AgentRegistrar` | APKRun.app | registers apkrund (`SMAppService.agent`) and the menu bar login item; re-registers after an update when needed | §3.7 |
| `MaintenanceService` (actor) | RuntimeHost (apkrund) | the host state (`normal`, `updating`, `restartPending`), the host-update marker, post-update tasks, the maintenance endpoint | §3.5–§3.8, §8.1 |
| `SelfUpdateProbe` | RuntimeHost | a background appcast check for people who rarely open APKRun.app | §3.4 |
| `BundleWatcher` | RuntimeHost | detects that APKRun.app was replaced while apkrund was running | §3.6 |
| `ImageUpdateCoordinator` (actor) | RuntimeHost | owns `ImageUpdatePhase`: check → download → install → apply | §4 |
| `ImageFeedClient` | ImageCore | fetches and verifies the image feed | §4.1 |
| `ImageDownloader` | ImageCore | resumable, verified archive downloads into `Cache/images/`. First-run provisioning uses it too ([runtime-daemon.md](runtime-daemon.md) §9.3) | §4.4 |
| `ImageStore.install(from: .archive)` | ImageCore | safe extraction, verification, hole punching | §4.5, [android-image.md](android-image.md) §10.4 |
| `RuntimeSupervisor.migrateImage(to:operation:)` | RuntimeCore | migration A → B: boot, health check, restore on failure | §4.7, [android-image.md](android-image.md) §12.3 |
| `SchemaMigrator` | DiagnosticsCore (generic runner); each store supplies its steps | forward-only migrations of host data files | §5 |

Rules:

- Only APKRun.app links Sparkle, and only Sparkle replaces the APKRun.app bundle. apkrund, the menu bar, and the CLI never download or install APKRun updates.
- Neither update system writes under `Packages/` or inside a wrapper bundle (#057: "Updater must not modify Android application package metadata"). The one exception is a data schema migration shipped in a release (§5). It runs as a journaled store transaction in the new apkrund and keeps the meaning of every field.
- APKRun updates never change the Android image, and Android system updates never change the APKRun bundle.

---

## 2. Versions and compatibility

### 2.1 APKRun version and component list

- `CFBundleShortVersionString` is `MAJOR.MINOR.PATCH`. It is shown without a zero patch, so "1.0" means 1.0.0. `CFBundleVersion` is the **build number**: a positive integer that increases with every published build on every channel. Sparkle compares `sparkle:version` against it. Every executable in the bundle has the same two values.
- The build writes `Contents/Resources/components.json` ([../05-development/build-system.md](../05-development/build-system.md)). `BuildInfo` ([diagnostics.md](diagnostics.md) §1) reads it. `host.componentVersions`, `apkrun --version --verbose`, and the diagnostics bundle (`versions.json`) show it.

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

The values are an example of a later release. In v1.0 every data schema is at version 1. A test in the build checks that `runtimeAPI`, `guestProtocol`, and `dataSchemas` equal the constants compiled into the code (`RuntimeAPI.version`, `ProtocolVersion.supportedMajors`, each store's `currentSchemaVersion`).

### 2.2 Compatibility contract

| Pair | Rule | Enforced by |
|---|---|---|
| APKRun ↔ Android image | the image's `requirements.minimumRuntimeVersion` ≤ the APKRun version, and its `requirements.guestProtocol` range intersects `guestProtocol.majors` | ImageCore: feed filtering (§4.2), activation, and every boot ([android-image.md](android-image.md) §9.3, §12.1) |
| APKRun ↔ older images | every APKRun release boots the **current and the previous stable image**. A guest protocol major is dropped only after both of the last two stable images support the newer major | release rules R2 and R4 (§2.3) |
| APKRun ↔ wrappers | the wrapper endpoint serves RuntimeAPI majors N and N−1. Wrappers two majors behind show screen L, and APKRun.app offers to refresh them | [wrapper.md](wrapper.md) §5.3, §9.4 |
| APKRun ↔ its data | every data file has a `schemaVersion`. A newer build migrates forward. An older build refuses data it doesn't understand (the host starts degraded) | §5 |
| APKRun ↔ its own parts | one bundle, one build. apkrund, the CLI, the menu bar, and the launcher template are never updated separately | `host.componentVersions`, `apkrund.version` ([diagnostics.md](diagnostics.md) §7.3) |
| APKRun ↔ guest agents | custom image: the agents are part of the image and are updated with it. Stock image (development): the host installs the dev Guest Agent from `Resources/guest/` when its versionCode differs, so an APKRun update updates it at the next boot | [guest-protocol.md](guest-protocol.md) §5.2 |
| Android image ↔ userdata | the image's `userdata.upgradableFrom` must contain the instance's userdata schema | [android-image.md](android-image.md) §12.1 |
| APKRun maintenance ↔ any APKRun | the maintenance endpoint is version-stable, so an old apkrund and a new APKRun.app can always coordinate | §8.1 |

### 2.3 Release rules

The release workflow checks these before it publishes an appcast item or a feed entry ([../05-development/workflow.md](../05-development/workflow.md)).

| # | Rule |
|---|---|
| R1 | The build number is higher than every build published before, on every channel |
| R2 | The APKRun release passes the T3 release smoke matrix (boot, one app launch, migration A → B; §14 and [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.2) with the current stable image and with the previous stable image |
| R3 | An image entry's `minimumRuntimeVersion` is the oldest APKRun release it was tested with. An image that needs an unreleased APKRun is published only after that APKRun is on the same channel |
| R4 | A RuntimeAPI major or guest protocol major is dropped only as §2.2 allows |
| R5 | For every file, the migration chain exists from every schema version shipped in a stable release in the last 24 months, and each step has a T0 golden test (§5) |
| R6 | The Sparkle EdDSA key and the Developer ID certificate are never changed in the same release ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7) |
| R7 | A stable image is released at least once a quarter, for Android security patches and time zone data. An extra release is made for a critical security fix, and for a tzdata change that affects a zone within 60 days (§4.11) |

### 2.4 Mutual exclusion

| While | Refused or delayed | Error or behavior |
|---|---|---|
| An image migration runs (`RuntimeImageState.migrating`) | installing an APKRun update | `prepareForHostUpdate` returns `maintenance.hostUpdateBusy(.migration)`. APKRun.app shows "Waiting for the Android system update to finish…" and tries again every 30 s |
| The host state is `updating` or `restartPending` (§3.6) | applying an Android system update | the apply gate stays closed (A3, §4.6). Downloads continue |
| A package transaction or app update install runs | installing an APKRun update | `prepareForHostUpdate` waits up to 2 minutes, then returns `maintenance.hostUpdateBusy(.storeOperation)` |
| An image migration runs | package installs, app updates, `apkrun launch` | they wait in `ensureReady` for the migration's boot and health check ([runtime-daemon.md](runtime-daemon.md) §3.1). The CLI prints "Waiting for the Android system update to finish…" |

---

## 3. APKRun updates (#057)

### 3.1 What an APKRun update replaces

#057 asks for a "versioned runtime package containing appropriate host binaries". That package is the APKRun.app bundle itself: Developer ID signed, notarized, and stapled. It is versioned by §2.1 and published as a Sparkle archive (§3.3). There is no separate runtime package, because apkrund, the menu bar, and the CLI must always match APKRun.app (§2.2).

| Replaced by an APKRun update | Not touched |
|---|---|
| everything inside `APKRun.app/Contents/` ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §4): APKRun.app, `Helpers/apkrund`, `Helpers/APKRunLauncher.app` (the wrapper template), `Library/LaunchAgents/io.apkrun.apkrund.plist`, `Library/LoginItems/APKRunMenuBar.app`, `Frameworks/` (VirGLRuntime, Sparkle), `Resources/bin/apkrun` (the user's PATH symlink keeps pointing at it), `Resources/tools/aapt2`, `Resources/guest/`, `compatibility.json`, `components.json` | the Android image and instance (`Images/`, `Runtime/instance/`), `Packages/` (apps, records, settings, journal), `Wrappers/` and every wrapper bundle, `Updates/`, `Providers/`, `Shared/`, Keychain items. `state.json` and `settings.json` change only through schema migrations (§5) |

Wrappers keep their own copy of the launcher. They go on working under the N−1 rule. §3.7 step 5 covers the refresh prompt.

### 3.2 Sparkle integration

- **Dependency:** Sparkle 2 (`https://github.com/sparkle-project/Sparkle`, MIT) through SwiftPM, pinned to an exact version in `project.yml` and linked into APKRun.app only. The framework goes into `Contents/Frameworks/Sparkle.framework` and is signed inside-out with the rest of the nested code ([../05-development/build-system.md](../05-development/build-system.md)). ADR-0016 records the choice.
- **User interface:** Sparkle's standard user driver (`SPUStandardUserDriver`): the update alert with release notes, download progress, and **Install and Relaunch**. APKRun adds its own dialog only for the handshake (§3.5).
- **Info.plist (release builds):**

| Key | Value | Reason |
|---|---|---|
| `SUFeedURL` | `https://<updates host>/apkrun/appcast.xml` (the host is OQ-01) | one appcast; channels select the beta items |
| `SUPublicEDKey` | the base64 Ed25519 public key | Sparkle refuses archives that are not signed with the matching private key |
| `SUEnableAutomaticChecks` | `YES` | Sparkle doesn't ask for permission at the second launch. The user's choice is `maintenance.checkAutomatically` (§6) |
| `SUScheduledCheckInterval` | `86400` | one check a day while APKRun.app runs |
| `SUAllowsAutomaticUpdates` | `YES` | allows the "Install APKRun updates automatically" option |
| `SUAutomaticallyUpdate` | `NO` | the first-launch default. It is overwritten from settings at every launch |
| `SUEnableSystemProfiling` | `NO` | no system profile is sent |
| `SUVerifyUpdateBeforeExtraction` | `YES` | the archive signature is checked before extraction |
| `SURequireSignedFeed` | `YES` | the appcast itself carries an EdDSA signature |

`SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` are recent Sparkle 2 additions. #057 step 1 confirms them against the pinned version. If one is missing, the other protections still hold (the archive signature and the Developer ID check), and the gap is recorded in R-23 ([../04-plan/risks.md](../04-plan/risks.md)).

- **Settings are the source of truth.** At launch and whenever a setting changes, `SelfUpdateController` sets `updater.automaticallyChecksForUpdates = maintenance.checkAutomatically` and `updater.automaticallyDownloadsUpdates = maintenance.installAPKRunAutomatically`. Sparkle's own UserDefaults are never read back.
- **Delegate** (`SPUUpdaterDelegate`):

| Method | Use |
|---|---|
| `allowedChannels(for:)` | `["beta"]` when `maintenance.channel == beta`, otherwise empty (stable items only) |
| `updater(_:didFindValidUpdate:)`, `updaterDidNotFindUpdate(_:)` | send the result to apkrund (`noteSelfUpdateStatus`, §8.2), so the menu bar and the CLI agree with Sparkle |
| `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` | returns `true`, runs the handshake of §3.5, then calls the block |
| `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` | an automatic update is downloaded and will be installed when APKRun.app quits. Settings shows "APKRun ‹version› will be installed when you quit APKRun." with **Install and Relaunch Now** (which calls the immediate-installation block through the handshake). apkrund is told with `noteSelfUpdateStatus(pendingOnQuit:)` |
| `updater(_:didAbortWithError:)`, `updater(_:failedToDownloadUpdate:error:)` | logged as `maintenance.sparkle(code:)`. If a marker was written, `abortHostUpdate` is called |

- **Development builds** have no `SUFeedURL`, and `SelfUpdateController` does nothing. The test configuration `ReleaseUpdateTest` points `SUFeedURL` at the local appcast server and uses the test EdDSA key (`Tests/Fixtures/signing/test-sparkle-ed25519.pub`). The CI-built `ReleaseUpdateTest` bundles are Developer ID signed but not notarized (§14).

### 3.3 Release artifacts and the appcast

- **Archive:** `APKRun-<version>.zip`, made with `ditto -c -k --sequesterRsrc --keepParent APKRun.app` from the notarized, stapled bundle. The website offers `APKRun-<version>.dmg` (notarized) for first installs.
- **Deltas:** `generate_appcast` makes delta updates from the last three releases, which release storage keeps.
- **Signing:** the release job signs each archive with `sign_update` (the EdDSA key is a CI secret, [../01-architecture/security-model.md](../01-architecture/security-model.md) §7) and signs the appcast. Sparkle also checks that the new bundle's Developer ID signature matches the installed one (R6).
- **Appcast item:**

```xml
<item>
  <title>APKRun 1.2.0</title>
  <pubDate>Mon, 02 Nov 2026 09:00:00 +0000</pubDate>
  <sparkle:version>1200</sparkle:version>
  <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
  <sparkle:releaseNotesLink>https://<updates host>/apkrun/release-notes/1.2.0.html</sparkle:releaseNotesLink>
  <sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>
  <!-- beta items only -->      <sparkle:channel>beta</sparkle:channel>
  <!-- security fixes only -->  <sparkle:criticalUpdate sparkle:version="1150"/>
  <enclosure url="https://<updates host>/apkrun/APKRun-1.2.0.zip" length="48213377"
             type="application/octet-stream" sparkle:edSignature="…"/>
</item>
```

- **Phased rollout:** stable items use `phasedRolloutInterval` 86400, so Sparkle spreads them over about a week. Beta items and critical updates are not phased. A user-initiated check ignores the phasing (Sparkle's behavior).
- **Hosting:** static HTTPS (OQ-01). The appcast is served with `Cache-Control: max-age=300`, and archives are immutable (their URL contains the version).

### 3.4 Background probe in apkrund (`SelfUpdateProbe`)

Sparkle checks only while APKRun.app is running. Many people only open their Mac apps (wrappers) and rarely open APKRun.app. The probe tells them about updates.

- **When:** once per 24 hours (± 1 hour of jitter, `ContinuousClock`), at the hourly `StartInterval` wake or while apkrund is running, and only while `maintenance.checkAutomatically` is on. It also runs on request (`checkSelfUpdate(userInitiated: true)`) from the CLI and the menu bar.
- **What:** one conditional GET of the appcast (`If-None-Match`, `If-Modified-Since`), with a 30 s timeout and a 2 MiB size limit. It follows the network rules of [update-system.md](update-system.md) §3.4 (HTTPS only, system proxy). `XMLParser` reads the items. The probe keeps the items whose channel is allowed, whose `minimumSystemVersion` is at most the running macOS, and whose `sparkle:version` is higher than its own build, and it picks the highest. Items under phased rollout are ignored until `pubDate + 7 × phasedRolloutInterval`, except critical updates and user-initiated checks. The probe can't see Sparkle's rollout group. When the appcast is signed (`SURequireSignedFeed`), the probe checks the signature with `SUPublicEDKey` from the bundle's Info.plist (CryptoKit `Curve25519.Signing`). A bad signature makes the result `unknown` and logs `maintenance.selfUpdateFeedInvalid`.
- **Informational only:** it never downloads or installs. A forged appcast can cause at worst a wrong notification. An install always goes through Sparkle and all of Sparkle's checks.
- **Result:** `SelfUpdateStatus { currentVersion, currentBuild, latest: AvailableRelease?, critical, lastCheckedAt, lastError, pendingOnQuit }`, published on the `maintenance` topic (§8.3). `AvailableRelease` is the chosen appcast item ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §12.2).
- **Notification:** once per version, posted through `HostNotifier` ([update-system.md](update-system.md) §9), and only when APKRun.app is not connected, because Sparkle shows its own alert then. "APKRun ‹1.2.0› is available. Open APKRun to install it." with **Update…**. APKRun.app handles the action itself: it opens Settings → General and starts a user-initiated Sparkle check (`checkForUpdates()`). A critical update is notified again after 3 days if it is still not installed.
- **Menu bar:** a row "APKRun ‹1.2.0› is available" with **Update…** ([host-ui.md](host-ui.md) §12). **CLI:** `apkrun self-update check` (§7.6).

### 3.5 Install coordination (#057 "safe restart coordination for daemon")

Sparkle replaces APKRun.app, but apkrund, the menu bar, and the VM's GPU renderer run code from inside that bundle, and Sparkle does not know about them (ADR-0007). An apkrund that keeps running over a replaced bundle mixes versions. For example, it would copy the new launcher template while speaking the old API, or read new resources with old code. So Android is stopped and apkrund exits before Sparkle installs.

**The main path.** The user clicks **Install and Relaunch** in Sparkle's alert, or **Install and Relaunch Now** for an update that is pending on quit.

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

The dialog when apps are open (sessions and `keepRunning` background tasks, [runtime-daemon.md](runtime-daemon.md) §5.1):

```text
Install APKRun 1.2.0?
Discord and Spotify will close while APKRun updates.
Their windows reopen when the update is finished.
               [Install When Apps Are Closed]   [Cancel]   [Close Apps and Install]
```

- The whole of step 4 has a 3-minute timeout on the APKRun.app side. If step 4 fails or times out, APKRun.app calls `abortHostUpdate`, which deletes the marker and returns the host state to `normal`. It then shows the error with **Try Again**. Sparkle keeps the downloaded update.
- If apkrund isn't running, the connection starts it (launchd starts it on demand for the Mach service), and it answers at once.
- Open wrappers get `ended(.runtimeUpdating)`, show screen U, and reconnect by themselves (§7.5). That is why the dialog can promise that their windows reopen.

#### 3.5.1 Install When Apps Are Closed

APKRun.app holds on to Sparkle's postponed block and subscribes to the `sessions` and `runtime` topics. When no session and no background task is left, it runs step 4 with `closeSessions = false` and continues. Settings shows "APKRun 1.2.0 will be installed when your Android apps are closed." with **Install Now…**, which goes back to the dialog.

If APKRun.app quits before that, Sparkle installs the postponed update when it quits. apkrund then finds its bundle replaced and finishes the update itself (§3.6, `restartPending`). #057 step 1 confirms this Sparkle behavior.

### 3.6 Host state, the marker, and a replaced bundle

`HostState` belongs to RuntimeHost. It is published, with `runtimeBuild`, in the broker's `HelloReply` ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2), in `runtimeStatus`, and on the `maintenance` topic.

| State | Meaning | apkrund behavior |
|---|---|---|
| `normal` | — | — |
| `updating(targetBuild)` | a coordinated update is being installed: §3.5 step 4 ran, or apkrund started and found the marker | serves the broker and the maintenance endpoint (§8.1). Health and diagnostics operations work. Everything else returns `RuntimeFailure.hostUpdating`. Android is never started |
| `restartPending(bundleBuild)` | the bundle on disk has a different build than this process. Causes: Sparkle installed on quit, the user copied a new APKRun.app from the DMG, Homebrew, or MDM | running sessions and background tasks go on. Refused with `hostUpdating`: starting Android, wrapper generation and refresh, and anything else that reads bundle resources (the dev Guest Agent, `compatibility.json`, the launcher template). When no session, background task, or operation is left, apkrund stops Android if it is running and exits 0 at once, without the 2-minute grace period. The next client connection starts the new apkrund |

**`BundleWatcher`** reads `CFBundleVersion` from the bundle's `Contents/Info.plist` on disk, not from the cached `Bundle` values. It does this on every broker `hello`, every 60 s, and on a vnode event (`DispatchSource`: rename, delete) for the bundle directory. A different build means `restartPending(build)`. A missing bundle (the app was moved or deleted) means `restartPending(nil)`, with the same behavior. apkrund links all of its bundle code at launch and never `dlopen`s code from the bundle later, so a replaced bundle can't load mismatched code into a running apkrund.

**The marker `Runtime/maintenance.json`** is written by apkrund in §3.5 step 4d and read at every apkrund start (startup step 4, [runtime-daemon.md](runtime-daemon.md) §2.2):

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

The finishing wait matters when a wrapper reconnects before Sparkle has relaunched APKRun.app. Without it, the new apkrund could boot Android and then be stopped by the agent re-registration in §3.7 step 2.

When APKRun.app starts and finds a marker whose `targetBuild` is higher than its own build, the update failed after step 4 (a crash, or an error in Sparkle's installer). It calls `abortHostUpdate` at once and shows "APKRun couldn't be updated." Sparkle shows the details.

### 3.7 First launch of the new APKRun.app

`SelfUpdateController.completeUpdateIfNeeded()` runs in `applicationDidFinishLaunching`, before any view uses the runtime:

1. Compare the own build with UserDefaults `lastLaunchedBuild`. If they are equal, stop here.
2. **Agent registration (`AgentRegistrar`):** if `SMAppService.agent(plistName:).status != .enabled`, or the SHA-256 of the embedded agent plist differs from UserDefaults `registeredAgentPlistSHA256`, then `unregister()` and `register()`, and store the new hash. Unregistering stops a running apkrund with `SIGTERM`. In the coordinated path apkrund is in `updating` at this point and has no sessions. Outside the coordinated path (install on quit, DMG copy), if apkrund has sessions, re-registration waits for the "Finish updating APKRun" banner (§7.3). If the plist is unchanged, no re-registration is needed: `BundleProgram` is resolved when launchd spawns the job, so the next spawn runs the new binary. #057 verifies this in T2. If it does not hold, the fallback is to re-register on every build change, with the same coordination.
3. **Menu bar:** if "Show APKRun in the menu bar" is on and APKRunMenuBar is not running, or runs another build, terminate it and open the new one. The menu bar also checks by itself: at every connection it compares `HelloReply.runtimeBuild` with its own build, and when apkrund is newer it opens its own bundle URL again and exits. That covers updates made while APKRun.app is not opened.
4. `completeHostUpdate()` on the maintenance endpoint (§3.6).
5. **Launcher refresh prompt:** if some wrappers are two RuntimeAPI majors behind, or the new build sets `LauncherBuild.recommendsRefresh`, show "‹N› Mac apps need to be updated to work with this version of APKRun." with **Update Now** and **Later** ([wrapper.md](wrapper.md) §9.4).
6. Store `lastLaunchedBuild`.

There is no "What's New" window. Sparkle showed the release notes before the install.

### 3.8 Post-update tasks in apkrund

These run once, when `state.json.lastRuntimeBuild` is lower than the own build:

1. Data schema migrations, as each store loads its files (§5).
2. Record the `HOST_UPDATED { fromBuild, toBuild }` marker and a log line.
3. Check again whether the current image can boot with this build. If not, §4.10.
4. Check the image feed now. A newer build may accept newer images.
5. Recompute wrapper refresh reasons (`WrapperValidator`, [wrapper.md](wrapper.md) §9.1), so Home shows **Update All Mac Apps**.
6. Write `state.json.lastRuntimeVersion` and `lastRuntimeBuild`.

If `lastRuntimeBuild` is **higher** than the own build, someone installed an older APKRun by hand. Files with a newer schema make the host start degraded (§5). If no file is newer, apkrund runs normally and `maintenance.selfUpdate` shows a warning ("APKRun was downgraded from ‹version›").

### 3.9 Failure cases

| Case | Result |
|---|---|
| appcast unreachable or invalid | Sparkle shows its error for a user-initiated check. The probe records `lastError`. `maintenance.selfUpdate` warns after 7 days without a successful check |
| archive signature or Developer ID mismatch | Sparkle refuses the update. Nothing is installed |
| the user cancels the dialog | nothing changes. The update stays available |
| `prepareForHostUpdate` fails (busy, timeout, stop failed) | `abortHostUpdate`, the error with **Try Again**. Sparkle keeps the download |
| APKRun.app crashes after step 4, or Sparkle's installer fails | the marker remains. An old apkrund started by a client waits at most 10 minutes in `updating`, then clears the marker. The next APKRun.app launch aborts at once (§3.6) |
| power loss during the install | Sparkle swaps the bundle atomically, so either the old or the new bundle is in place. The marker rules decide the rest |
| the new apkrund crash-loops | launchd restarts it (`KeepAlive`), and `apkrund.crashLoop` reports it. Sparkle never installs an older version. The recovery is to install the previous release from the website; data is safe because migrations keep backups (§5). APKRun has no automatic host rollback in v1 |
| a schema migration fails | the owning component starts degraded with `maintenance.schemaMigrationFailed`. The original file and its backup are unchanged |
| APKRun.app was replaced outside Sparkle | `restartPending` (§3.6) |

---

## 4. Android system updates (#087, #058)

### 4.1 The image feed

- **Location:** `https://<updates host>/apkrun/images/<channel>/feed.json` and `feed.json.sig`, where the channel is `stable` or `beta` (OQ-01). The base URL is the Info.plist key `APKRunImageFeedBaseURL` of the Release build. Debug builds have no feed URL, and tests set `APKRUN_TEST_IMAGE_FEED_URL` ([../03-reference/configuration.md](../03-reference/configuration.md) §5.1, §7.1). The field-by-field format is in [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) ("Image feed").

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

- `feed.json.sig` uses the same signature format and trust store as `manifest.sig` (`ImageTrustStore`, [android-image.md](android-image.md) §10.1). It signs the exact bytes of `feed.json`.
- **Client rules (`ImageFeedClient`):**
  1. HTTPS only. `feed.json` at most 1 MiB, `feed.json.sig` at most 4 KiB. Conditional GET with the stored ETag.
  2. The signature is checked before parsing. An unknown key or a bad signature gives `imageFeedSignatureInvalid`, and the last accepted feed stays in effect.
  3. `channel` must equal the requested channel.
  4. **Replay and freeze protection:** `sequence` must be at least the highest sequence accepted for this channel (stored in `Images/update-state.json`). If it is equal, the bytes must be identical. A lower sequence gives `imageFeedReplayed`. A feed whose `expiresAt` has passed gives `imageFeedExpired` and is not used. The release workflow signs the feed again with a new sequence at least once a week, with `expiresAt = generatedAt + 30 days`.
  5. Unknown fields are ignored. An unknown `schemaVersion` means the feed is not used, and a health warning says "Update APKRun to receive Android system updates."
  6. The feed is only a pointer. The archive's SHA-256 and the manifest signature inside the archive are checked on their own (§4.5), and the manifest's `imageVersion`, `requirements`, and `userdata` must equal the feed entry (`imageFeedInvalid` otherwise).

### 4.2 Checks and candidate selection

| Trigger | Notes |
|---|---|
| every 24 hours (± 1 hour of jitter), at the hourly wake or while apkrund runs | only while `maintenance.checkAutomatically` is on |
| APKRun.app opens | at most once every 6 hours |
| after an APKRun update (§3.8) or a channel change | immediately |
| Settings **Check Now**, `apkrun image check` | user-initiated: ignores the interval, the backoff, and the rollout |

A failed check is retried after 1 hour, then after 6 hours, then on the daily schedule. Checks never start Android and don't count as runtime activity.

The **candidate** is the highest `imageVersion` in the feed that meets all of these:

| # | Condition | When it fails |
|---|---|---|
| C1 | newer than `current` (never a downgrade) | — |
| C2 | `minimumRuntimeVersion` ≤ the APKRun version | remembered as `requiresNewerAPKRun(version)`. Settings says "A newer Android version is available after you update APKRun." |
| C3 | `guestProtocol` intersects the host's majors | skipped |
| C4 | `userdata.upgradableFrom` contains the instance's userdata schema, and `current` ≥ `upgradeFrom.minimumImageVersion` | skipped. A manual activation is refused with `image.userdataSchemaUnsupported` or `image.migrationSourceTooOld` |
| C5 | not rejected (§4.8) | skipped, except for a user-initiated update that confirms the retry |
| C6 | rollout: `bucket < rolloutPercent`, where `bucket` = the first two bytes of SHA-256(instance ID ‖ imageVersion) as an integer, modulo 100. The instance ID is in `state.json` and never leaves the Mac | skipped until the percentage grows. Ignored for user-initiated checks and `critical` entries |
| C7 | `kind == apkrun`, and the current image is also `apkrun` | a development instance on a `stock` image never gets feed updates. It moves to the product image only through Reset Android (the platform keys differ, so its data can't carry over) |

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

`ImageCandidate` is one feed entry that passed C1–C7 (§4.2). On the wire the phase is `WireImageUpdatePhase`, with `WireImageCandidate` and a `WireError` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §12.3).

| From | To | Trigger |
|---|---|---|
| `idle`, `available`, `ready`, `failed` | `checking` | a trigger of §4.2. In `ready`, a newer candidate replaces the ready image, which GC deletes |
| `checking` | `idle`, `available` | the check result |
| `available` | `downloading` | automatic download is allowed (§4.4), or the user asked |
| `downloading` | `installing` | the archive is complete, and its size and SHA-256 match |
| `downloading` | `failed` | an error. Retries after 15 minutes, 1 hour, then 6 hours. The partial file is kept if the server supports ranges |
| `installing` | `ready` | `ImageStore.install` returned |
| `installing` | `failed` | a verification error: the archive is deleted and downloaded once more. After a second failure, no retry until the feed changes |
| `ready` | `applying` | the apply gate opened (automatic), or the user asked (§4.6) |
| `applying` | `idle` | the migration succeeded (`current` = B), or it failed and A was restored. `lastResult` records `installed(B)` or `rejected(B, failure)` |

**Relation to `RuntimeImageState`** ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §7). `RuntimeImageState` describes the current image. While B downloads and installs, it stays `installed(A)`. Its `installing(progress)` state is used only for the first image, at provisioning. `applying(A, B)` corresponds to `migrating(A, B)`.

**Persistence:** `Images/update-state.json` is written only by `ImageUpdateCoordinator`. It holds the channel, `lastCheckAt`, `nextCheckAt`, the backoff, the feed ETag, the highest accepted sequence per channel, the candidate, the download state (partial file, bytes, the server's ETag), the phase, the rejected versions, `lastAutomaticApplyAt`, and the versions already notified. The transient phases (`checking`, `installing`) are stored as the phase before them, so a restart runs them again. At startup the coordinator reconciles `applying` with `RuntimeImageState`: `installed(A)` means the migration was rejected, and `installed(B)` means it succeeded.

### 4.4 Download

- `ImageDownloader` downloads over HTTPS into `Cache/images/<imageVersion>.aar.partial` and hashes it with SHA-256 as the bytes arrive. To resume, it sends `Range: bytes=<n>-` with `If-Range: <ETag>`. A `200` reply starts again from zero. Before it resumes, it hashes the partial file again, which takes a few seconds at SSD speed. When size and hash match, it renames the file to `.aar`. If the server sends more than `size` bytes, it stops with `imageArchiveSizeMismatch`.
- **Space:** before downloading and before installing, the free space must be at least the archive size + `expandedSize` + 10 GiB. Otherwise the result is `insufficientSpace`, and the Storage pane explains what is needed. A manual install (§4.5) has no `expandedSize`: it needs the file size + 10 GiB before it starts, and the extraction stops with `insufficientSpace` when less than 10 GiB would be left ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.3).
- **Network:** background downloads use `networkServiceType = .background`, `waitsForConnectivity`, `allowsExpensiveNetworkAccess = false`, and `allowsConstrainedNetworkAccess = false`. They wait while Low Power Mode is on. A user-initiated download on an expensive or constrained network asks first: "This download is ‹1.8 GB›. You're on a network that may charge for data."
- Background downloads run only while `maintenance.downloadImagesAutomatically` is on (the default). With it off, the phase stays `available` until the user clicks.
- A running download counts as an operation in flight, so apkrund does not exit ([runtime-daemon.md](runtime-daemon.md) §2.4). It never starts Android. When the Mac sleeps, the connection drops, and the download resumes 2 minutes after wake.
- **Cancel** (Settings, or Ctrl-C of `apkrun image install --latest`) keeps the partial file for a later resume. Partial files are deleted after 7 days, or when a newer candidate replaces them.

### 4.5 Installing into `Images/`

`ImageStore.install(from: .archive(url))` ([android-image.md](android-image.md) §10.4) extracts with the AppleArchive framework under these rules:

- Every entry must be a regular file or a directory, with a relative path inside the bundle root. Entries with `..`, absolute paths, symlinks, hard links, devices, or FIFOs are rejected. Permissions are reset (0644 for files, 0755 for directories), and extended attributes and ACLs are dropped. A violation gives `imageArchiveUnsafeEntry(path)`: the install stops and `Images/.installing-*` is removed.
- Verification: signature → manifest schema → every file ([android-image.md](android-image.md) §10.1). In addition, the manifest must agree with the feed entry (§4.1 rule 6).
- The archive is deleted after a successful install.
- An install changes neither `current` nor `previous`. It needs neither Android nor the user's confirmation.

`apkrun image install <file.aar>` and **Install from File…** in Settings → Storage use the same install. The file reaches apkrund as a file handle, as package imports do, so apkrund never opens a path the user chose. Release builds accept only images signed with the release keys. Unpacked bundle directories are for development only (`apkrun dev image install`, [android-image.md](android-image.md) §10.3). The apply step that follows is user-initiated (§4.6).

### 4.6 When an update is applied

**Automatic apply gate** (`maintenance.installImages == automatic`, the default). All conditions must hold:

| # | Condition |
|---|---|
| A1 | the phase is `ready`, B is not rejected, and `RuntimeImageState` is `installed(A)` |
| A2 | no session exists except `ended` ones. No activity assertion exists (background task, store operation, ADB client, `runtime start --hold`, diagnostics; [runtime-daemon.md](runtime-daemon.md) §5.1). No package transaction runs, and no app update is in `installing`, `healthChecking`, or `rollingBack` |
| A3 | the host state is `normal` (§3.6) |
| A4 | the user has been idle for at least 10 minutes (`HIDIdleTime`) |
| A5 | AC power, Low Power Mode off, and `ProcessInfo.thermalState` is `nominal` or `fair` |
| A6 | at least 10 GiB free ([android-image.md](android-image.md) §12.3 precondition) |
| A7 | no automatic apply attempt in the last 24 hours |

The coordinator evaluates the gate every 5 minutes while an image is `ready` and apkrund runs, and also on events that can open it: a session ended, the power source changed, an activity was released. apkrund doesn't stay alive only to wait for the gate. The hourly `StartInterval` wake evaluates it too, which usually opens it at night.

**User-initiated apply:** Settings **Update Android Now…**, the notification's **Update Now**, or `apkrun image install --latest` (which also downloads and installs if needed). A1, A3, and A6 are still required. If sessions or background tasks exist, the user is asked first:

```text
Update Android now?
Discord and Spotify will close. Updating Android takes a few minutes,
and your apps and data are kept.
                                     [Cancel]   [Close Apps and Update]
```

Store transactions are waited for (at most 2 minutes). A4, A5, and A7 are ignored. On battery below 20 %, the dialog adds a warning.

**Ask mode** (`maintenance.installImages == ask`): nothing is applied automatically. When an image becomes `ready`, APKRun posts "Android system update ready" once, with **Update Now** and **Later**, and shows it in Settings and in the menu bar. It reminds once more after 7 days, or after 1 day for a `critical` image.

**A gate that never opens:** in automatic mode, if an image has been `ready` for 7 days (for example because the Mac is never idle on AC power), APKRun posts the same notification once. A `critical` image gets it after 1 day.

### 4.7 The migration

`ImageUpdateCoordinator.apply(B, userInitiated:)` calls `RuntimeSupervisor.migrateImage(to: B, operation:)`. That function runs the steps of [android-image.md](android-image.md) §12.3 with these additions:

1. **Sessions** end with `ended(.runtimeUpdating)`, with the user's consent in the user-initiated case. A wrapper shows screen U and calls `openSession` again. apkrund accepts the new session, and it waits in `waitingForRuntime` until the migration's health check has finished (§7.5).
2. **Activity and power:** the supervisor holds the `.migration` activity assertion, so the idle policy never suspends the first boot. It also holds an `IOPMAssertionTypePreventUserIdleSystemSleep` assertion named "Updating Android". The 15-minute first-boot timeout is measured with `SuspendingClock`, so time asleep doesn't count (the VM is paused while the Mac sleeps, [runtime-daemon.md](runtime-daemon.md) §6).
3. **Progress:** `RuntimeState` goes through `booting(BootPhase)` as usual. `RuntimeStatus` and the `runtime` topic also carry `bootPurpose = .imageUpdate(from: A, to: B)` (the default is `.normal`), so the runtime header shows "◐ Updating Android… (‹phase›)" instead of "Starting Android…", and so do the menu bar and waiting wrappers.
4. **Afterwards:** Android returns to its earlier state. If sessions are waiting, they go ahead. If Android was stopped before an automatic apply, it is stopped right after the health check. If it was running without sessions, it stays `ready` and the idle policy takes over.
5. **On failure** (step 6b, A restored): Android boots A only if a session is waiting. APKRun always posts a notification: "Android couldn't be updated to ‹B›. Your apps and data are unchanged." with **Report a Problem…** (`apkrun://report`, [diagnostics.md](diagnostics.md) §8.5). B is rejected (§4.8).
6. **Crash safety:** [android-image.md](android-image.md) §12.3 (a `migration` field in `instance.json`, found at startup, is treated as failed). The coordinator's own phase is reconciled as in §4.3.

After a restore, APKStoreCore reconciles the packages with the restored userdata ([package-store.md](package-store.md) §9): the generation changed, so packages are reinstalled or updated from their stored artifact sets as the reconciliation rules say.

### 4.8 Rejected versions and rollback

- A failed migration rejects B: `rejected[B] = { at, reason }` in `Images/update-state.json`. Automatic updates skip B, and a newer version is offered normally. The user can retry B from Settings ("The last attempt to update to ‹B› failed. Try Again?") or with `apkrun image install --latest`, which asks, or proceeds with `--yes`.
- B's installed directory is kept for 7 days, for diagnostics and for a retry without downloading again. Then GC deletes it.
- **Going back** ("Go Back to Android ‹A›…" in Settings → Storage, `apkrun image rollback`) is possible while the recovery point R from the last migration and the `previous` image A exist, which is until the next migration. It restores R ([android-image.md](android-image.md) §12.3) after this confirmation:

```text
Go back to Android 2026.07.0?
Android returns to the state it was in before the update on 2 October.
Changes made in Android since then are lost, including app data.
Apps you added since then are installed again, without their data.
                                                 [Cancel]   [Go Back]
```

  The rolled-back version is then rejected with reason `userRolledBack`, so it is not applied again automatically.

### 4.9 Garbage collection and disk use

- `ImageStore.garbageCollect()` runs after every migration, rejection, and install, and once a day. It keeps `current`, `previous`, a `ready` image, and a rejected image younger than 7 days. It deletes everything else under `Images/`.
- Recovery points follow [android-image.md](android-image.md) §12.2: after a successful migration, only the newest one is kept. APKRun never deletes it automatically, because deleting it removes the way back. The Storage pane and `image.freeSpace` suggest deleting it when free space is below 10 GiB.
- `Cache/images/`: partial downloads older than 7 days and archives of images that are already installed are deleted.
- The Storage pane ([host-ui.md](host-ui.md) §9.7) shows "Android system": the current version with its size, the previous version, an update that is ready, and the recovery point with its date.

### 4.10 An image this APKRun can't boot

Release rules R2–R4 should prevent this. It can still happen after a long time without image updates (updates failing, or automatic checks off) combined with an APKRun update that dropped an old guest protocol major.

- **Detection:** the post-update tasks (§3.8) and every boot preparation ([android-image.md](android-image.md) §9.3 step 3) report `ImageFailure.incompatibleProtocol` or `incompatibleRuntime`.
- **Behavior:** Android stays `stopped`. `ensureReady` fails with `RuntimeFailure.image(…)`. Its remediation action is `updateAndroid` ([diagnostics.md](diagnostics.md) §2.3) for `incompatibleProtocol / hostNewer`, and `updateAPKRun` for `incompatibleProtocol / guestNewer` and `incompatibleRuntime` ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §9).
- **`incompatibleProtocol / hostNewer`** (the image is too old for this APKRun): only a newer image helps. The coordinator checks the feed at once and downloads without waiting for the network rules. Nothing can run in the meantime, so it applies the image as soon as it is `ready`, ignoring A4, A5, and A7. Home and the wrappers show "Android needs an update to work with this version of APKRun." with the progress.
- **`incompatibleProtocol / guestNewer` and `incompatibleRuntime`** (the image needs a newer APKRun): a newer image doesn't help, so nothing is checked or downloaded. Home and the wrappers show the entry's own text with **Check for Updates** (`updateAPKRun`).
- If the feed has no image this APKRun can boot, the result is `noCompatibleImage`. That is a release defect. The remediation is to install the previous APKRun from the website. The action is `openDownloadsPage` ([diagnostics.md](diagnostics.md) §2.3), which opens the Info.plist URL `APKRunDownloadsURL` ([../03-reference/configuration.md](../03-reference/configuration.md) §7.1). `LauncherBuild.downloadURL` ([wrapper.md](wrapper.md) §5.4) is the same URL.

The opposite case, an image that needs a newer APKRun, can only come from a manual install. It is refused when the image is activated (`incompatibleRuntime`, "Update APKRun").

### 4.11 Security patches and time zone data

- The Android security patch level and the time zone database change only with image updates. If Android doesn't know a Mac time zone, [desktop-integration.md](desktop-integration.md) §9 falls back to `Etc/GMT∓h`. Release rule R7 sets the cadence.
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

Rules:

- Every JSON file has an integer `schemaVersion`. In JSONL files, every line has it (`"v"`).
- A build knows its current schema for each file (`components.json dataSchemas`, §2.1). It has a migration step `n → n+1` for every older schema in the window of R5.
- **On load:** read the file. Keep the original bytes as `<name>.v<old>.json` next to it (one backup per old version, deleted 90 days after the migration). Migrate in memory, validate the result, and write it atomically (`FileManager.replaceItemAt`). The `Packages/` records are migrated in one journaled store transaction (`schemaMigration`), so a crash in the middle resumes at the next start ([package-store.md](package-store.md) §5).
- **A newer schema than the build understands:** the owning component starts degraded ([runtime-daemon.md](runtime-daemon.md) §2.2 step 4) with `maintenance.dataCreatedByNewerVersion(file, schema, supported)`: "This data was created by a newer version of APKRun. Install the latest version of APKRun." The file is never written in that case. The package store limits this to one package: a newer `metadata.json` or `settings.json` makes that package read-only with `store.metadataUnreadable`, and a newer journal makes the store degraded ([package-store.md](package-store.md) §5.4).
- Additive changes also raise the schema version. `Codable` drops unknown keys, so an older build that wrote the file would lose the new fields.
- Migrations never change what a value means. #057's acceptance test compares the decoded `PackageRecord`s field by field before and after an update.
- The journal is normally clean at an update, because §3.5 step 4c waits for transactions. A newer build still replays older journal entries, because each entry has its version.
- T0 golden fixtures: `Tests/Fixtures/schemas/<file>/v<n>.json`, each migrated to the current schema and compared with `v<n>.expected.json`.

---

## 6. Settings

The keys are also listed in [../03-reference/configuration.md](../03-reference/configuration.md).

| Key | Values | Default | Meaning |
|---|---|---|---|
| `maintenance.checkAutomatically` | bool | `true` | daily checks for APKRun updates (Sparkle and the probe) and Android system updates |
| `maintenance.channel` | `stable`, `beta` | `stable` | the channel for both. Switching from beta to stable never downgrades: APKRun stays on its build until stable passes it, and so does the image |
| `maintenance.installAPKRunAutomatically` | bool | `false` | Sparkle downloads updates in the background and installs them when APKRun.app quits (§3.5.1, §3.6) |
| `maintenance.downloadImagesAutomatically` | bool | `true` | download Android system updates in the background (§4.4) |
| `maintenance.installImages` | `automatic`, `ask` | `automatic` | apply at idle (§4.6), or wait for the user |
| `maintenance.notifyImageInstalled` | bool | `false` | post a notification after a successful automatic Android system update |

---

## 7. User-facing surfaces

### 7.1 Settings → General ([host-ui.md](host-ui.md) §9.1)

```text
Updates
  APKRun 1.2.0 (1200) · Android 2026.10.0 (security patch 5 September 2026)
  ☑ Check for updates automatically
  ☐ Install APKRun updates automatically
  Android system updates:  (•) Install automatically when the Mac is idle
                           ( ) Ask before installing
  ☑ Download Android system updates in the background
  ☐ Notify me when Android was updated
  Channel: [Stable ▾]
  [Check Now]   Last checked today at 09:14

  Status line (one of):
  APKRun 1.3.0 is available.                                   [Install Update…]
  APKRun 1.3.0 will be installed when you quit APKRun.         [Install and Relaunch Now]
  Android 2026.11.0 is ready to install.                       [Update Android Now…]
  Downloading Android 2026.11.0… 45 % of 1.8 GB                [Cancel]
  A newer Android version needs APKRun 1.3 or later.           [Install Update…]
  The last Android update failed. Android 2026.10.0 is still in use.  [Try Again] [Report a Problem…]
```

**Install Update…** starts a user-initiated Sparkle check with its UI. When this pane opens, it also runs Sparkle's `checkForUpdateInformation()` (no UI) at most once every 5 minutes, so the status line is current. Wrapper screen V opens this pane (§7.5).

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
| "Android system update ready" | ask mode, or in automatic mode after 7 days of waiting (§4.6) | **Update Now**, **Later** |
| "Android was updated to ‹B›" | after a successful automatic update, only with `maintenance.notifyImageInstalled` | — |
| "Android couldn't be updated to ‹B›. Your apps and data are unchanged." | every failed migration | **Report a Problem…** |
| "Android needs an update to work with this version of APKRun" | §4.10 `incompatibleProtocol / hostNewer`, while no APKRun window is open | **Open APKRun** |

### 7.5 Wrappers

A new launcher screen **U** ([wrapper.md](wrapper.md) §5.4): "APKRun is updating. ‹App› opens again when the update is finished." It has only **Quit**. It appears:

- on `ended(.runtimeUpdating)`, for an APKRun update and for an Android system update,
- when `HelloReply.hostState` is `updating`, or `openSession` fails with `RuntimeFailure.hostUpdating`.

While U is shown, the launcher tries to connect and call `openSession` every 2 s for up to 10 minutes. During an Android system update, `openSession` is accepted at once and the placeholder shows "Updating Android…" until the session goes ahead (§4.7). After 10 minutes the launcher shows screen E with `hostUpdating` and **Try Again**. If the new APKRun no longer serves the wrapper's API major, the next `hello` leads to screen L.

Screen V ("‹App› needs APKRun ‹minimum› or later.") opens `apkrun://settings/general` for **Check for Updates** (§7.1). URLs only navigate, and the pane itself runs the harmless information check.

### 7.6 CLI ([cli.md](cli.md) §4.7)

| Command | Behavior |
|---|---|
| `apkrun self-update check [--json]` | runs the probe through apkrund as a user-initiated check (phasing is ignored) and prints "APKRun 1.3.0 is available (you have 1.2.0). Open APKRun to install it." or "APKRun is up to date." Exit 0 either way; `--json` has `available`. If apkrund can't be reached: exit 69, "Open APKRun to check for updates." |
| `apkrun self-update install` | opens `apkrun://settings/general`, where the update is installed. The CLI does not wait |
| `apkrun self-update finish [--yes]` | in `restartPending`: restarts the runtime on the new build. Asks first when apps are open ("2 apps will close"). Without a pending restart it prints "Nothing to finish." |
| `apkrun image list`, `check`, `install (<file.aar> \| --latest) [--yes]`, `rollback [--yes]`, `recovery-points list \| delete <id>` | as listed in [cli.md](cli.md) §4.7. `image install --latest` downloads, installs, and applies, whichever steps are still needed (§4.6). `image check` exits 0 and prints the phase, the candidate, and any `requiresNewerAPKRun` |

---

## 8. Runtime API surface

The DTOs are in [../03-reference/runtime-api.md](../03-reference/runtime-api.md).

### 8.1 Maintenance endpoint (version-stable)

The endpoint kind is `.maintenance`, with the same code-signing requirement as `.control` ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2). Its protocol `MaintenanceControl` is **frozen**: it has no major version, and changes are additive only (new optional fields, new operations). It has to work between an old apkrund and a new APKRun.app (§3.6, §3.7), and between an old APKRun.app and an old apkrund in `updating`, even when the RuntimeAPI major changes between the two builds. The endpoint is available in every host state.

| Operation | Behavior |
|---|---|
| `maintenanceStatus()` | `MaintenanceStatus { version, build, hostState, sessions: [PackageID], backgroundTasks: [PackageID], activities: [ActivityKind], imageMigrating, marker? }` |
| `prepareForHostUpdate(HostUpdateRequest{ targetVersion, targetBuild, closeSessions })` | §3.5 step 4. Errors: `hostUpdateBusy(ActivityKind)`, `hostUpdateSessionsOpen([PackageID])` (when `closeSessions` is false), `selfUpdateNotNewer` |
| `abortHostUpdate()` | deletes the marker. The host state becomes `normal`. Idempotent |
| `completeHostUpdate()` | ends the finishing wait (§3.6). Idempotent |
| `restartForUpdate(closeSessions)` | in `restartPending`: ends sessions with `.runtimeUpdating`, stops Android, and exits. Returns `hostUpdateSessionsOpen` if sessions exist and `closeSessions` is false |

### 8.2 Control endpoint

| Operation | Behavior | Long operation |
|---|---|---|
| `selfUpdateStatus()` | `SelfUpdateStatus` (§3.4) | no |
| `checkSelfUpdate(userInitiated)` | runs the probe | no (30 s timeout) |
| `noteSelfUpdateStatus(SelfUpdateNote{ found: AvailableRelease?, pendingOnQuit, checkedAt })` | APKRun.app reports Sparkle's results ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §12.2) | no |
| `imageUpdateStatus()` | phase, candidate and sizes, `requiresNewerAPKRun`, rejected versions, last result, and the gate conditions that are false | no |
| `checkImageUpdate()` | user-initiated check | yes |
| `downloadImageUpdate()`, `cancelImageDownload()` | §4.4 | yes / no |
| `applyImageUpdate(ApplyImageUpdateRequest{ version, closeSessions, retryRejected })` | user-initiated apply (§4.6) | yes |
| `installImage(ImageInstallRequest{ source: .file(fileIndex:) \| .latest, apply })` | §4.5, then apply if `apply`. This is the `imageInstall` long operation of [runtime-daemon.md](runtime-daemon.md) §8.3 | yes |
| `rollbackImage(RollbackImageRequest{ confirmed })` | §4.8 | yes |
| `listImages()`, `recoveryPoints()`, `deleteRecoveryPoint(id)` | [android-image.md](android-image.md) §12.2 | no |

The DTOs are in [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §12.2 and §12.3. A file source passes as a file handle, named by its index in the request (runtime-api.md §4.9).

Wrappers get only `hostState` in `HelloReply` and the `hostUpdating` error. They have no maintenance operations.

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
| downloads | `Cache/images/` (§4.4); safe to delete | apkrund (`ImageDownloader`) |
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
| a downgrade to a vulnerable APKRun | Sparkle only installs a higher `sparkle:version`; `criticalUpdate` for security fixes |
| a forged Android image | feed signature, archive SHA-256, and manifest signature, all against `ImageTrustStore` (§4.1, §4.5) |
| replay of an old feed (freeze or rollback attack) | `sequence` and `expiresAt` (§4.1 rule 4). Images are never downgraded automatically |
| path tricks in an archive | the extraction rules of §4.5 |
| another local process forcing updates or restarts | the maintenance and control endpoints require APKRun's signing identity. `apkrun://` URLs only navigate |
| a compromised signing key | Sparkle: a new EdDSA key is shipped in a release signed with the old key (Sparkle's key rotation). Never together with a Developer ID change (R6). Images: the key ID is removed from `ImageTrustStore` in an APKRun release, and the feed and manifests are signed with a new key |

Privacy: the probe and the feed client send no identifiers. There is no system profile, and the rollout bucket (C6) is computed on the Mac. The `User-Agent` is `APKRun/<version> (macOS <version>)`.

---

## 11. Errors

`MaintenanceFailure` is the error domain `maintenance` ([diagnostics.md](diagnostics.md) §2.1). Codes, messages, and remediations are in [../03-reference/error-catalog.md](../03-reference/error-catalog.md).

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
    case criticalUpdateWaiting(version: String)              // maintenance.selfUpdate: a critical update has been available for more than 3 days
    case selfUpdateCheckOverdue                              // maintenance.selfUpdate: no successful check for 7 days while automatic checks are on
    case hostDowngraded(version: String)                     // maintenance.selfUpdate: APKRun was downgraded from version
    case imageUpdateWaiting(version: ImageVersion)           // maintenance.imageUpdate: an update has been ready for more than 14 days
    case imageCheckOverdue                                   // maintenance.imageUpdate: no successful feed check for 7 days
}
```

Other domains gain these cases:

- `RuntimeFailure.hostUpdating`: remediation "APKRun is updating. Try again in a minute." ([runtime-daemon.md](runtime-daemon.md) §11).
- `SessionEndReason.runtimeUpdating` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3).
- `StopReason.hostUpdate` ([runtime-daemon.md](runtime-daemon.md) §3.1).
- `RemediationAction.updateAndroid` ([diagnostics.md](diagnostics.md) §2.3): opens Settings → General and starts the Android system update.

---

## 12. Logging, markers, health

- `os_log` subsystem `io.apkrun.maintenance` ([diagnostics.md](diagnostics.md) §3.1): category `selfUpdate` (APKRun.app and apkrund) and category `imageUpdate` (apkrund). Logged: check results (versions, HTTP status, feed sequence), host state changes, marker actions, gate evaluations (which condition was false), download ranges and resumes, install timing, and migration steps (the image module also logs them, [android-image.md](android-image.md) §14.2). Paths are logged relative to the data root.
- Markers ([diagnostics.md](diagnostics.md) §4.2): `SELF_UPDATE_CHECK_END`, `HOST_UPDATE_PREPARE_START`, `HOST_UPDATE_PREPARED`, `HOST_UPDATED`, `IMAGE_CHECK_END`, `IMAGE_DOWNLOAD_START`, `IMAGE_DOWNLOAD_END`, `IMAGE_INSTALL_END`, `IMAGE_MIGRATION_START`, `IMAGE_MIGRATION_END`, `IMAGE_ROLLBACK_END`.
- The diagnostics bundle gets `maintenance/state.json`: `SelfUpdateStatus`, `HostState`, the marker, and `Images/update-state.json`. Feed URLs are public, so they are kept.

| Check | Requirement | Pass | Info | Warning | Failure |
|---|---|---|---|---|---|
| `maintenance.selfUpdate` | daemon | up to date, with a successful check in the last 7 days | an update is available, or automatic checks are off | a critical update has been available for more than 3 days; no successful check for 7 days while automatic checks are on; `restartPending` for more than 24 hours; an abandoned host update in the last 24 hours; APKRun was downgraded | — |
| `maintenance.imageUpdate` | daemon | up to date, or an update in progress | an update is downloading or ready; a newer image needs a newer APKRun | ready for more than 14 days; the last migration was rejected (in the last 7 days); the feed signature is invalid, replayed, or expired; no successful feed check for 7 days; not enough space for the update | the current image can't boot with this APKRun (§4.10) |

The warnings of `maintenance.selfUpdate` are, in order, `maintenance.criticalUpdateWaiting`, `maintenance.selfUpdateCheckOverdue`, `diagnostics.serviceVersionMismatch / restartPending`, `maintenance.hostUpdateAbandoned`, and `maintenance.hostDowngraded`. The warnings of `maintenance.imageUpdate` are `maintenance.imageUpdateWaiting`, `maintenance.imageMigrationFailed`, the feed errors of §11, `maintenance.imageCheckOverdue`, and `maintenance.insufficientSpace`. Its failure is `image.incompatibleProtocol / hostNewer`, `image.incompatibleRuntime`, or `maintenance.noCompatibleImage` ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §20.2).

`apkrund.version` ([diagnostics.md](diagnostics.md) §7.3) reports a `restartPending` apkrund. Its remediation is "An APKRun update is waiting for your Android apps to close. Close them, or choose Restart Now."

---

## 13. Implementation steps

The three tasks are built in the order #057 → #058 → #087. #058 works with local image files. #087 adds the feed, downloads, and the automatic apply gate.

### #057 APKRun runtime updater (M10; depends on #031, #049)

1. Add Sparkle 2 (SwiftPM, pinned in `project.yml`), embed and sign it. Against the pinned version, confirm the Info.plist keys of §3.2, the delegate methods, that a postponed update is installed on quit (§3.5.1), the signed appcast format, and whether the test appcast can be served over HTTP on loopback. Record the results in ADR-0016 "Verification".
2. `components.json` generation in the build (§2.1) and its consistency test. `BuildInfo` reads it.
3. `SelfUpdateController`: settings mapping, channels, delegate. The Settings → General section (§7.1).
4. RuntimeAPI: the `.maintenance` endpoint kind and the frozen `MaintenanceControl` protocol (§8.1), `HostState` in `HelloReply`, the `maintenance` event topic.
5. `MaintenanceService` in RuntimeHost: host states, `prepareForHostUpdate`, the marker and its startup rules (§3.6), `RuntimeFailure.hostUpdating`, `StopReason.hostUpdate`, `SessionEndReason.runtimeUpdating`.
6. `UpdateInstallCoordinator` in APKRun.app: the handshake, the dialog, Install When Apps Are Closed (§3.5).
7. `BundleWatcher`, `restartPending`, the Home banner, `restartForUpdate`, `apkrun self-update finish` (§3.6, §7.3).
8. First-launch tasks (§3.7): the `AgentRegistrar` hash rule, the menu bar relaunch, `completeHostUpdate`, the launcher refresh prompt.
9. `SchemaMigrator` and the post-update tasks (§3.8, §5), with golden fixtures for every current schema.
10. `SelfUpdateProbe`, its notification and menu bar row, `apkrun self-update check|install` (§3.4, §7.6).
11. Launcher screen U and the reconnect loop ([wrapper.md](wrapper.md) §5.4, §5.5).
12. Release workflow: the archive, `sign_update`, `generate_appcast` with deltas, the signed appcast, publishing (`scripts/release/`; the host depends on OQ-01). The release rules of §2.3 that can be checked by a script (R1, R5, R6).
13. Health checks, markers, logging (§12).
14. Acceptance (#057: "A test runtime upgrade replaces host components without corrupting installed Android applications"): the T2 test "APKRun N → N+1" of §14.

### #058 Guest image versioning and migration (M10; depends on #035, #057)

The data steps (`ImageVersion`, recovery points, the migration steps) are in [android-image.md](android-image.md) §12. This task adds:

1. `ImageUpdateCoordinator` with the phases `ready`, `applying`, and `failed`, `Images/update-state.json`, and the startup reconciliation (§4.3).
2. `RuntimeSupervisor.migrateImage(to:operation:)`: the additions of §4.7 (sessions, activity and power assertions, `SuspendingClock` timeout, progress purpose, the state afterwards).
3. The archive install with the extraction rules and hole punching (§4.5, [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.3), and the local installs on top of it: `installImage(.file)`, `apkrun image install <file.aar>`, **Install from File…**, and the user-initiated apply with its dialog (§4.6).
4. Rejected versions, rollback (`rollbackImage`, `apkrun image rollback`, **Go Back…**), GC (§4.8, §4.9).
5. Detection and handling of an incompatible current image, without the feed part (§4.10).
6. `image list`, `recovery-points list|delete`, the Storage pane rows (§7.2), the migration header text (§7.3), and the failure notification (§7.4).
7. Acceptance (#058: "Test guest image A → B migration boots with existing userdata, and simulated B failure can return to A"): [android-image.md](android-image.md) §12.4, run through `apkrun image install` on the lab Mac, plus the orchestration tests of §14.

### #087 Runtime image distribution (M10; depends on #058, #065)

1. The release pipeline on macOS: `aa archive -a lzfse`, the feed entry, feed signing, weekly re-signing with a new sequence, publishing (`scripts/release/image-feed.py`; the host depends on OQ-01).
2. `ImageFeedClient` with the rules of §4.1, and the feed section of [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md).
3. Candidate selection C1–C7 and the check schedule (§4.2).
4. `ImageDownloader`: resume, space checks, network rules, cancel (§4.4). First-run provisioning from the feed ([runtime-daemon.md](runtime-daemon.md) §9.3).
5. The feed checks of the archive install: the archive SHA-256 against the feed entry before extraction, and the manifest against the feed entry after verification (§4.5). The extraction itself comes from #058.
6. The automatic apply gate A1–A7, ask mode, reminders, and critical entries (§4.6).
7. `apkrun image check`, `image install --latest`, the Settings status lines, notifications, the menu bar row (§7).
8. Acceptance: (a) T1 against a local feed server: a valid feed selects the right candidate for each of C1–C7; a tampered feed, a replayed sequence, and an expired feed are refused; a download interrupted at 50 % resumes and gives the same SHA-256; not enough space is reported before the download starts. (b) T2 on the lab Mac: with image A installed and a local feed offering B, apkrund downloads B in the background, applies it once the gate opens (test hooks for idle time and power source), and HelloText's data is kept.

---

## 14. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | `components.json` equals the compiled constants | #057 |
| T0 | Appcast parsing for the probe: channels, `minimumSystemVersion`, phased rollout, critical updates, a malformed feed, a bad feed signature | #057 |
| T0 | Marker rules at startup (§3.6), one case per table row, with a fake clock | #057 |
| T0 | Schema migration golden fixtures for every file and version (§5); a newer schema gives `dataCreatedByNewerVersion` and writes nothing | #057 |
| T0 | Feed validation: signature, channel, sequence, expiry, unknown fields, unknown schema; manifest–feed agreement | #087 |
| T0 | Candidate selection C1–C7, including the rollout bucket distribution (10,000 random instance IDs within ±2 % of the percentage) | #087 |
| T0 | Archive extraction rules with crafted archives: `..`, absolute paths, symlinks, hard links, devices, extra files | #058 |
| T1 | `MaintenanceService` with a fake runtime: `prepareForHostUpdate` refused during a migration, waiting for store transactions, sessions ending with `.runtimeUpdating`, stop with the deadline, exit after the reply | #057 |
| T1 | `BundleWatcher`: replacing the bundle's `Info.plist` in a temporary copy gives `restartPending`; the exit happens only after the last session ends | #057 |
| T1 | `ImageUpdateCoordinator` with a fake store, a fake supervisor, and a fake clock: every transition of §4.3, a restart in each persisted phase, the gate A1–A7, ask-mode reminders, a rejected version skipped, rollback | #058, #087 |
| T1 | Downloader against a local HTTP server: resume with `Range`/`If-Range`, a `200` reply to a range request, a server sending too many bytes, a hash mismatch | #087 |
| T2 | **APKRun N → N+1 (#057 acceptance).** Builds 9000 and 9001 of the `ReleaseUpdateTest` configuration from the same commit; 9001 adds `Resources/test-build-marker`. Install 9000, provision image A, install HelloText and HelloUpdate V1, create both wrappers, and write data (HelloText counter). Record the SHA-256 of every file under `Packages/` (except `.trash/`), the decoded `PackageRecord`s, `Wrappers/registry.json`, and every file of both wrapper bundles. Open HelloText. Trigger the update through a test user driver that accepts every prompt (§3.2), with the local appcast offering 9001. Expect: HelloText shows screen U and reopens by itself on 9001; the running apkrund reports build 9001 and `Resources/test-build-marker` is present in its bundle; `Runtime/maintenance.json` is gone; the `Packages/` hashes, the records, the registry, and both wrapper bundles are unchanged; the journal has no open transaction; `apkrun list` shows the same packages and versions; HelloText's counter is kept; HelloUpdate still launches; the agent is registered (`SMAppService.status == .enabled`) | #057 |
| T2 | Variants of the update test: (a) Install When Apps Are Closed: nothing happens until HelloText is closed, then the update runs; (b) the bundle is replaced with `ditto` while HelloText is open: `restartPending`, HelloText keeps running, and apkrund 9001 serves the next launch after HelloText is closed; (c) APKRun.app is killed right after `prepareForHostUpdate`: with `APKRUN_TEST_MARKER_TIMEOUT=30s`, the marker is cleared and the next launch works on 9000; (d) 9001 with a changed agent plist: re-registration happens, and no session is killed | #057 |
| T2 | Migration A → B, and a failed migration B → B′ that returns to B ([android-image.md](android-image.md) §12.4), started with `apkrun image install` | #058 |
| T2 | A session opened during a migration waits and then opens on the new image; after an induced failure it opens on the previous image | #058 |
| T2 | Feed-driven update on the lab Mac (§13 #087 step 8b) | #087 |
| T3 | Release smoke matrix (R2): each release candidate against the current and the previous stable image | #057, #087 |

---

## 15. Open items

Recorded in [../04-plan/open-questions.md](../04-plan/open-questions.md) and [../04-plan/risks.md](../04-plan/risks.md):

- R-23: Sparkle details to confirm with the pinned version (#057 step 1): the two recent Info.plist keys, installing a postponed update on quit, the signed appcast format, and whether plain HTTP on loopback works for tests.
- R-24: whether launchd runs the new apkrund from a replaced bundle without re-registration when the agent plist is unchanged (#057 T2). The fallback is re-registration on every build change (§3.7).
- The hosting domain for the appcast, the feed, and the archives (OQ-01).
- The default of `maintenance.installAPKRunAutomatically` (off in v1, to be reviewed after 1.0).
- R-25: extraction writes the zero runs of `os.img` before the holes are punched (§4.5). #087 measures the time and SSD writes, and a sparse-aware extraction sink is the fallback.
- Delta image updates (post-v1; v1 downloads full archives).
- Automatic rollback of APKRun itself (post-v1; v1 relies on installing an older release by hand, §3.9).

---

## 16. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| R-23: do `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` work in the pinned Sparkle version? | #057 | pending (§3.2) |
| R-23: is a postponed update installed when APKRun.app quits? | #057 | pending (§3.5.1) |
| R-23: the signed appcast format, and whether the test appcast can be served over plain HTTP on loopback | #057 | pending (§3.3) |
| R-24: does launchd run the new apkrund from a replaced bundle without re-registration when the agent plist is unchanged? | #057 | pending (§3.7) |
| First-boot time of image B after a migration (package scan and dexopt) on the reference Mac | #058 | pending (§4.7) |
| R-25: extraction time and SSD bytes written for `os.img` | #087 | pending (§4.5) |
