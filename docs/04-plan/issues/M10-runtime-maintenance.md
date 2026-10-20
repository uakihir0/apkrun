# M10 Runtime maintenance

M10 keeps APKRun and its Android system up to date without touching the user's apps. APKRun updates as one signed `APKRun.app` through Sparkle 2 ([ADR-0016](../../01-architecture/decisions/0016-sparkle-host-updates.md)). Before an install, apkrund ends the Android sessions, stops Android, and exits. Android system updates come from a signed image feed. They download in the background and apply when the Mac is idle. A failed migration returns to the previous image. The order is strict: #057, #058, #087. M10 closes no gate.

---

## #057 APKRun runtime updater

| Field | Value |
|---|---|
| Milestone | M10 (v0.5) |
| Depends on | #031, #049 |
| Design | [ADR-0016](../../01-architecture/decisions/0016-sparkle-host-updates.md); [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3, §8; [runtime-daemon.md](../../02-design/runtime-daemon.md) §2.2; [host-ui.md](../../02-design/host-ui.md) §9.1 |
| Code | `Apps/APKRun/Maintenance/`, `Packages/RuntimeHost/Sources/RuntimeHost/Maintenance/`, `Packages/RuntimeAPI/`, `Packages/DiagnosticsCore/` (`SchemaMigrator`), `scripts/build/write-components.py`, `scripts/release/`, `Tests/IntegrationTests/MaintenanceTests/` |

**Goal.** An APKRun update, found by Sparkle or by apkrund's probe, replaces `APKRun.app`. apkrund ends the Android apps, stops Android, and exits first. The new build starts, the apps reopen, and no data under `Packages/`, in the wrappers, or in the Android image changes.

**Out of scope.** Android image updates (#058, #087). Automatic rollback of APKRun (post-v1; reinstall the previous release). Notarization and the DMG (#088): until then the release workflow is a dry run. The diagnostics bundle (#060), `apkrun doctor` (#059), and the wrapper refresh (#076).

**Steps.**
1. **Sparkle.** Add Sparkle 2 pinned to an exact version in `project.yml`, linked into APKRun.app only and embedded in `Contents/Frameworks/`. `scripts/release/sign-bundle.sh` signs nested code in the order of [build-system.md](../../05-development/build-system.md) §12.3. Confirm the keys and delegate behavior of [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.2 with that version, and record the result in ADR-0016 and R-23. If Sparkle refuses plain HTTP on loopback, `appcast-server.py` serves HTTPS with a lab-only certificate, and `ReleaseUpdateTest` may add `NSAllowsLocalNetworking`. Release builds never get it. **Check:** R-23 is settled.
2. **`components.json`.** `scripts/build/write-components.py` writes the fields of [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §2.1 at build time. `BuildInfo` reads the file. **Check:** a T0 test fails when an API, protocol, or schema constant changes without the file.
3. **`SelfUpdateController` and settings.** In `Apps/APKRun/Maintenance/`, it owns `SPUStandardUpdaterController`. It starts only when `SUFeedURL` exists, and not on `--notify` launches. It maps `maintenance.*` settings as [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.2 says, and builds the APKRun part of Settings → General → Updates ([host-ui.md](../../02-design/host-ui.md) §9.1). **Check:** T0 settings and channel mapping pass with a fake updater.
4. **Endpoint and DTOs.** Add the `.maintenance` endpoint and the frozen `MaintenanceControl` protocol (`maintenanceRevision = 1`, additive changes only), with `HostState`, `MaintenanceEvent`, and the self-update operations of [runtime-api.md](../../03-reference/runtime-api.md) §8. **Check:** T0 DTO round trips pass, and the endpoint answers in every host state (T1).
5. **`MaintenanceService` and install.** `MaintenanceService` is a RuntimeHost actor. It runs `prepareForHostUpdate` as [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.5 step 4 says, and applies the markers of [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.6. It writes `Runtime/maintenance.json`, ends sessions with `ended(.runtimeUpdating)`, stops Android with `StopReason.hostUpdate`, and exits after the reply. `UpdateInstallCoordinator` in APKRun.app shows the dialog of [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.5 and then calls Sparkle's block. **Check:** T0 marker tests (one per row, fake clock) and T1 service tests pass.
6. **Restart, first launch, screen U.** `BundleWatcher` re-reads `CFBundleVersion` from `Contents/Info.plist` by path and reports `restartPending` ([runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.6). `completeUpdateIfNeeded()` and `AgentRegistrar` run at launch ([runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.7). The launcher shows screen U while the runtime is updating ([wrapper.md](../../02-design/wrapper.md) §5.4). **Check:** T1 `BundleWatcher` test passes, and T2 variant (d) keeps a session.
7. **Schemas.** `SchemaMigrator` in DiagnosticsCore runs `n → n+1` steps, keeps `<name>.v<old>.json` for 90 days, and writes with `FileManager.replaceItemAt`. A newer schema gives `dataCreatedByNewerVersion` and is never written ([runtime-maintenance.md](../../02-design/runtime-maintenance.md) §5). Goldens live in `Tests/Fixtures/schemas/`. **Check:** golden and newer-schema tests pass.
8. **Probe, release, health.** `SelfUpdateProbe` follows [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.4. It parses the appcast with `XMLParser` and checks its signature with CryptoKit `Curve25519.Signing`. Add the CLI `apkrun self-update check [--json]` (exit 69 with "Open APKRun to check for updates." when apkrund is unreachable), `apkrun self-update install` (opens `apkrun://settings/general`), and `apkrun self-update finish [--yes]` ([cli.md](../../02-design/cli.md) §4.7). Keep the last check time, the ETag and `Last-Modified`, and the notified versions under `selfUpdate` in `state.json` (schema 1). `scripts/release/` builds, signs, and publishes the appcast, and `.github/workflows/release.yml` runs as a dry run. Register `maintenance.selfUpdate` ([runtime-maintenance.md](../../02-design/runtime-maintenance.md) §12). **Check:** the probe test against a local HTTP server passes, and the dry run gives a signed archive and appcast.

**Tests.**
- T0 (`Packages/RuntimeHost/Tests/RuntimeHostTests/`, `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`): `components.json`, appcast parsing, the marker table, schema goldens, DTO round trips, the settings mapping.
- T1: `MaintenanceService` with a fake runtime (migration refusal, store-transaction wait, stop deadline, exit after reply). `BundleWatcher` on a temporary bundle copy. The probe against a local HTTP server.
- T2 (`Tests/IntegrationTests/MaintenanceTests/`, CI job `maintenance`): N → N+1 with `ReleaseUpdateTest` 9000 and 9001, and variants (a) Install When Apps Are Closed, (b) the bundle replaced while HelloText is open, (c) APKRun.app killed after `prepareForHostUpdate` with `APKRUN_TEST_MARKER_TIMEOUT=30s`, (d) 9001 with a changed agent plist. `TestUserDriver`, compiled only into `ReleaseUpdateTest`, answers APKRun's install dialog from `APKRUN_TEST_INSTALL_CHOICE=closeApps|whenClosed`. The launch argument `--test-check-for-updates` starts a user-initiated check.
- T3: the smoke row "APKRun update" ([test-strategy.md](../test-strategy.md) §9.2) and checklist C05-5, once OQ-01 and #088 allow a real appcast.

**Done when.**
- After N → N+1, apkrund reports 9001, and `Runtime/maintenance.json` is gone. Every file under `Packages/` (except `.trash/`), `Wrappers/registry.json`, and both wrapper bundles are unchanged. HelloText keeps its counter.
- Nothing writes under `Packages/` or inside a wrapper, except one journaled schema migration.
- apkrund ends the sessions, stops Android, and exits before Sparkle installs. Variants (a)–(d) pass.
- An APKRun update leaves `Updates/` and `Images/` unchanged.
- HelloText shows screen U and reopens on 9001. A wrapper made by 9000 launches on 9001 (NFR-CMP-02).
- After the update the agent is registered. With a changed agent plist it is registered again, and no session is killed (R-24 recorded).
- A file from a newer schema gives `dataCreatedByNewerVersion` and is not written.
- No update check, download, or install runs on a launch path (NFR-PERF-07).

**Pitfalls.**
- Sparkle replaces the bundle by renaming it, and a vnode watch follows the old directory. `BundleWatcher` reads the plist by path and then watches the new directory.
- The `--notify` launch must not start Sparkle or count as a connected APKRun.app. The probe counts only an APKRun.app that sent `noteSelfUpdateStatus` on its current connection.
- apkrund exits 0, so launchd does not restart it (`KeepAlive.SuccessfulExit = false`). Do not add a restart of your own.

---

## #058 Guest image versioning and migration

| Field | Value |
|---|---|
| Milestone | M10 (v0.5) |
| Depends on | #035, #057 |
| Design | [android-image.md](../../02-design/android-image.md) §12; [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4.3, §4.7, §4.8; [runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §8.3; [state-machines.md](../../01-architecture/state-machines.md) §7 |
| Code | `Packages/ImageCore/` (`ImageStore`, migration steps, `garbageCollect`), `Packages/RuntimeCore/` (`RuntimeSupervisor.migrateImage`), `Packages/RuntimeHost/Sources/RuntimeHost/Maintenance/` (`ImageUpdateCoordinator`), `Apps/APKRun/Features/Settings/`, `CLI/apkrun/`, `Tests/IntegrationTests/MaintenanceTests/` |

**Goal.** An Android image B, given as a signed `.aar` file, is installed next to the current image A and applied as a migration. Android boots B with the existing userdata. If B fails, Android returns to A with its data unchanged. After a successful migration the user can go back to A.

**Out of scope.**
- The feed, downloads, the apply gate, and reminders (#087). Delta image updates (post-v1).
- Restoring the Reset Android recovery point. OQ-41 decides it. The working default is that v1 has no restore. `recoveryPoints` lists the point, and `deleteRecoveryPoint` deletes it.

**Steps.**
1. **Compatibility and data steps.** In `ImageCore`, check `ImageVersion` (YYYY, MM, N), `requirements.minimumRuntimeVersion`, the `guestProtocol` range, `userdata.upgradableFrom`, and `compatibility.upgradeFrom` as [android-image.md](../../02-design/android-image.md) §12.1 says. Refuse a lower version with `downgradeRejected`. Run the migration steps of [android-image.md](../../02-design/android-image.md) §12.3, recording state before each step. Take recovery point R with `InstanceStore.createRecoveryPoint` while the VM is stopped. **Check:** a T1 test interrupts each step and ends in `installed(A)` with R restored.
2. **`ImageUpdateCoordinator`.** An actor in `Packages/RuntimeHost/Sources/RuntimeHost/Maintenance/`, with phases `idle`, `ready`, `applying`, and `failed` ([runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4.3). It is the only writer of `Images/update-state.json`. At startup it reconciles `applying`: `installed(A)` means B was rejected, and `installed(B)` means success. It publishes the image events on the `maintenance` topic. **Check:** T1 transitions pass, including a restart in each persisted phase.
3. **`migrateImage`.** `RuntimeSupervisor.migrateImage(to:operation:)` ends sessions with `ended(.runtimeUpdating)`. `openSession` waits in `waitingForRuntime`, and installs and launches wait in `ensureReady`. It holds a power assertion named "Updating Android". The 15-minute first-boot timeout uses `SuspendingClock`. The health check is [android-image.md](../../02-design/android-image.md) §12.3 step 5. `bootPurpose` is set on `RuntimeStatus`. **Check:** the T2 migration tests of this entry pass.
4. **Archive and manual install.** `ImageStore.install(from: .archive(url))` extracts with AppleArchive into `Images/.installing-<name>/`, rejects unsafe entries with `imageArchiveUnsafeEntry(path)`, verifies, punches holes over all-zero 1 MiB blocks, and renames. Startup deletes leftover `.installing-*`. `installImage(.file(FileHandle))` reads with `pread`, and never opens or deletes the user's file. Space: file size + 10 GiB before, and 10 GiB free during extraction ([runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §8.3). Release builds accept only release-key images. Add `apkrun image install <file.aar> [--yes]` and **Install from File…**. **Check:** T0 crafted-archive tests and a T1 install with an injected trust store pass.
5. **Rejection, rollback, GC.** A failed migration sets `rejected[B]` and keeps B for 7 days. A retry needs `retryRejected`. `rollbackImage` (**Go Back to Android ‹A›…** and `apkrun image rollback`) restores R, sets `current → A`, and rejects B with `userRolledBack`. `garbageCollect()` keeps `current`, `previous`, a `ready` image, and rejected images younger than 7 days. It never deletes a recovery point. **Check:** T1 rollback and GC tests pass.
6. **Incompatible image and surfaces.** An incompatible protocol or runtime leaves Android stopped and fails `ensureReady` with `RuntimeFailure.image(…)`, with the remediation of [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4.10. Add `apkrun image list [--json]` and `apkrun image recovery-points list|delete <id>`. Add the Android rows of Settings → Storage ([host-ui.md](../../02-design/host-ui.md) §9.7), "◐ Updating Android… (‹phase›)" in Home and the menu bar, and the failure notification "Android couldn't be updated to ‹B›. Your apps and data are unchanged." with **Report a Problem…**. Emit `IMAGE_MIGRATION_START`/`END` and `IMAGE_ROLLBACK_END`. **Check:** T0 health-check rows pass.

**Tests.**
- T0 (`Packages/ImageCore/Tests/ImageCoreTests/`): `ImageVersion` ordering, the compatibility table, archive entry rules with crafted archives (`..`, absolute paths, symlinks, hard links, devices), and the `maintenance.imageUpdate` rows.
- T1: the migration interrupted at each step. The coordinator with a fake store, supervisor, and clock. A fixture `.aar` signed with `test-image-ed25519`. Hole punching (the physical size drops, the bytes stay). Rollback and GC on a temporary data root.
- T2 (`Tests/IntegrationTests/MaintenanceTests/`, custom image): migration A → B, and a failed B → B′ that returns to B ([android-image.md](../../02-design/android-image.md) §12.4). A session opened during migration waits, then opens on the new image, or on the previous one after an induced failure. Go Back from B to A.
- T3: the image release candidate matrix ([test-strategy.md](../test-strategy.md) §9.3) and the smoke row "image migration" ([test-strategy.md](../test-strategy.md) §9.2).

**Done when.**
- After `apkrun image install` of B, the state is `installed(B)`, and HelloText keeps its counter.
- With an induced failure of B′ (`fail_health=1`), the state ends at `installed(B)`, B′ is rejected, and the data is intact.
- Version, compatibility range, userdata schema, and migration state are checked at activation and boot. `migrating(A, B)` is recorded before boot, and a crash during migration counts as a failure.
- B replaces only the read-only image in `Images/`. The disks in `Runtime/instance/` are reused.
- After a migration, `previous` is A and recovery point R exists. Go Back returns to A with R's data, and B is rejected with `userRolledBack`.
- An unsafe archive gives `imageArchiveUnsafeEntry`, and no `.installing-*` is left.
- A release build refuses an image not signed with a release key.
- During a migration, `prepareForHostUpdate` returns `hostUpdateBusy(.migration)`.
- Every failed migration posts the failure notification, and `maintenance.imageUpdate` warns for 7 days.

**Pitfalls.**
- Never delete or move the user's `.aar`. The archive deletion of [runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §8.3 applies only to `Cache/images/` (#087).
- `SuspendingClock` pauses during Mac sleep, so sleep does not use up the first-boot timeout.
- Bootconfig sets only `ro.boot.*` properties. Bundle B carries `androidboot.apkrun.test.marker=B`, which the T2 test reads as `ro.boot.apkrun.test.marker` ([android-image.md](../../02-design/android-image.md) §12.4).

---

## #087 Runtime image distribution

| Field | Value |
|---|---|
| Milestone | M10 (v0.5) |
| Depends on | #058, #065 |
| Design | [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4.1, §4.2, §4.4, §4.6; [runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §8, §9; [host-ui.md](../../02-design/host-ui.md) §4 |
| Code | `Packages/ImageCore/Sources/ImageCore/Updates/` (`ImageFeedClient`, `ImageDownloader`), `Packages/RuntimeHost/Sources/RuntimeHost/Maintenance/` (`ImageUpdateCoordinator`), `Apps/APKRun/Features/Settings/`, `Apps/APKRun/Features/Onboarding/`, `CLI/apkrun/`, `scripts/release/image-feed.py`, `scripts/dev/image-feed-server.py`, `.github/workflows/image-release.yml`, `.github/workflows/image-feed-resign.yml`, `Tests/Fixtures/runtime-updates/image-feed/` |

**Goal.** Android system updates arrive by themselves. apkrund reads a signed image feed, downloads a compatible newer image in the background, installs it, and applies it when the Mac is idle or when the user asks. A new APKRun gets its first image from the same feed.

**Out of scope.** Delta image updates (post-v1). The migration, extraction, rollback, and GC of #058. The updates host and the real upload (OQ-01): until OQ-01 is settled, publishing is a dry run. Building the release `-user` image ([test-strategy.md](../test-strategy.md) §9.3).

**Steps.**
1. **Feed tooling.** `scripts/release/image-feed.py add --channel <c> --archive <aar>` builds the entry from the archive (`aa archive -a lzfse`, [build-system.md](../../05-development/build-system.md) §10.2) and the manifest, per [runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §8.1 and §9.4. It sets `sequence`, `generatedAt`, and `expiresAt` (30 days), and signs `feed.json.sig`. `resign` signs again with a new sequence. `image-release.yml` (manual) and `image-feed-resign.yml` (weekly) are dry runs until OQ-01. Fixtures use `test-image-ed25519`. **Check:** a feed written by the script passes the T1 client.
2. **`ImageFeedClient`.** In `Packages/ImageCore/Sources/ImageCore/Updates/`, fetch the feed over HTTPS with the limits of [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4.1. Verify the signature with `ImageTrustStore` before parsing, then check channel, sequence, expiry, and schema. Keep the highest sequence per channel in `Images/update-state.json`. A refused feed keeps the last accepted one. The base URL is the Info.plist key `APKRunImageFeedBaseURL`, set in Release builds only. Send no identifiers. **Check:** T0 feed validation tests pass.
3. **Candidates and gate.** `ImageUpdateCoordinator` selects the candidate with C1–C7 and applies the gate A1–A7 as [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4.2 and §4.6 say. The rollout bucket comes from the instance ID; user-initiated checks and critical entries ignore it. Checks never start Android, and apkrund never stays alive only to wait. Debug builds replace idle time and power with `APKRUN_TEST_IDLE_SECONDS` and `APKRUN_TEST_POWER`. **Check:** T0 selection tests pass (10,000 instance IDs within ±2 % of the rollout), and the T1 gate tests pass.
4. **`ImageDownloader`.** Download into `Cache/images/<imageVersion>.aar.partial` and hash while downloading. Resume with `Range` and `If-Range`, re-hash the partial first, and restart from zero on a `200`. A transfer over `size` gives `imageArchiveSizeMismatch`. A hash mismatch gives `imageArchiveHashMismatch`. Check space (archive + `expandedSize` + 10 GiB) before the download and the install (`insufficientSpace`). Apply the network and retry rules of [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §4.4. Ask before a user-initiated download on an expensive network. The first download in onboarding follows [host-ui.md](../../02-design/host-ui.md) §4. **Check:** T1 downloader tests against `scripts/dev/image-feed-server.py` pass.
5. **Feed install and R-25.** A feed install checks the archive SHA-256 against the entry before extraction, and then the manifest against the entry (`imageFeedInvalid`). It deletes the archive from `Cache/images/` after the install. On the reference Mac, measure the install's wall time and bytes written (`ri_diskio_byteswritten`). Build a sparse-aware extraction sink only if the install takes more than 5 min or writes more than twice `expandedSize`. Otherwise record R-25 as `accepted`. **Check:** R-25 is settled.
6. **Surfaces.** Add `apkrun image check [--json]` and `apkrun image install --latest [--yes]`. Settings → General gets the Android controls and status lines ([runtime-maintenance.md](../../02-design/runtime-maintenance.md) §7.1), and the menu bar gets "Android system update ready" with **Update Now**. Add the `maintenance.imageUpdate` rows for feed, download, ready, and space. Emit `IMAGE_CHECK_END` and `IMAGE_DOWNLOAD_START`/`END`. **Check:** checklist C05-6 passes.

**Tests.**
- T0 (`Packages/ImageCore/Tests/ImageCoreTests/`, `Packages/RuntimeHost/Tests/RuntimeHostTests/`): feed validation (signature, channel, sequence, expiry, unknown fields, unknown schema, duplicate versions), candidate selection C1–C7, the schedule and backoff with a fake clock, the gate table, and the `maintenance.imageUpdate` rows.
- T1: the downloader against a local HTTP server (resume, a `200` to a range request, too many bytes, hash mismatch, cancel). The coordinator with fakes (transitions, restart per phase, ask-mode reminders, a skipped rejected version). The feed server `scripts/dev/image-feed-server.py` serving `Tests/Fixtures/runtime-updates/image-feed/`: a valid feed, a tampered feed, a replayed sequence, an expired feed, a download interrupted at 50 %, and too little space.
- T2 (`Tests/IntegrationTests/MaintenanceTests/`, CI job `maintenance`): on the lab Mac, image A is installed and a local feed offers B, signed at run time with `image-feed.py --key`. apkrund downloads B and applies it when the gate opens (`APKRUN_TEST_IDLE_SECONDS=900`, `APKRUN_TEST_POWER=ac`). HelloText's data is kept.
- T3: checklist C05-6, and the release smoke matrix with the current and previous stable image from the published feed ([test-strategy.md](../test-strategy.md) §9.2), once OQ-01 is settled.

**Done when.**
- A valid feed selects the right candidate for each of C1–C7.
- A tampered, replayed, or expired feed is refused, and the last accepted feed stays in effect.
- A download interrupted at 50 % resumes and gives the same SHA-256. Too little space is reported before the download starts.
- On the lab Mac, apkrund downloads B in the background, applies it once the gate opens, and keeps HelloText's data.
- An image is never applied while a session, activity, or store operation exists, or while the host state is not `normal`.
- Checks and downloads never start Android and never run on a launch path (NFR-PERF-07).
- A release build with no image gets its first image from the feed during onboarding, with the size and a progress bar.
- `image-feed.py`, `image-release.yml`, and `image-feed-resign.yml` pass a dry run, and the client accepts the signed feed.

**Pitfalls.**
- The committed feed fixtures are signed with `test-image-ed25519`, which only T0 and T1 trust, through an injected trust store ([test-strategy.md](../test-strategy.md) §3.5). The T2 feed is signed at run time with the lab key.
- `If-Range` with a weak ETag makes some servers answer `200`. Treat that as a restart from zero, not as an error.
- Never send the instance ID, and never log it with the feed URL. The rollout bucket depends on it.
