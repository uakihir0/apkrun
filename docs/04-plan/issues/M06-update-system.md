# M6 Update system

M6 keeps installed Android apps up to date. apkrund validates a provider's newer version on the host, stages it, and installs it through one `PackageInstaller` session when the app is not in use, keeping its data. A failed health check restores the previous APK set. The host also reads `.apks`, `.xapk`, and `.apkm` files and checks their signatures. M6 closes gate G7 ([roadmap.md](../roadmap.md) §2) and the update items of the v0.3 Definition of Done ([roadmap.md](../roadmap.md) §3.3). Tests run on the custom image (#36). "Both image kinds" tests also run on stock. Work in the order below. `Depends on` names the hard dependencies.

---

## #74 Host inspection and import formats

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #37 |
| Design | [package-store.md](../../02-design/package-store.md) §4.1–§4.7, §10.1; [cli.md](../../02-design/cli.md) §4.2 |
| Code | `Packages/APKStoreCore/Sources/APKStoreCore/{Import,Signing}/`, `Packages/RuntimeHost/`, `CLI/apkrun/Commands/` |

**Goal.** `apkrun inspect` and the import preview show name, icon, version, signer, permissions, and warnings with Android stopped. Signer digests match `apksigner`. Unsafe containers are refused with a reason (FR-PKG-02, FR-PKG-03, FR-PKG-06).

**Out of scope.** Relations (#39), rules V1–V6 (#42), splits (#43), Store Agent icons (#56), the Add sheet (#79). OBB files are refused (OQ-13).

**Steps.**
1. **Containers.** Add ZIPFoundation with an `exact:` version ([ADR-0017](../../01-architecture/decisions/0017-zipfoundation-zip-reading.md)). `ContainerReader.detect(_:)` detects by content; `extract(into:)` streams into `incoming/<ticket>/` under the limits of [package-store.md](../../02-design/package-store.md) §4.2. Refuse the formats [package-store.md](../../02-design/package-store.md) §4.2 refuses. **Check:** T0 container tests.
2. **`SplitSelector`.** Rules of [package-store.md](../../02-design/package-store.md) §4.4. Excluded splits go to `ImportPreview.excludedSplits`. **Check:** T0 selection test.
3. **`APKSignatureVerifier`.** In `Signing/`: [package-store.md](../../02-design/package-store.md) §4.5 steps 1–6 with `SecKeyVerifySignature`. Add `scripts/dev/verify-corpus.sh` to the nightly `compatibility` job ([build-system.md](../../05-development/build-system.md) §12). **Check:** every T0 vector.
4. **`ArtifactVerifier`.** `verify(set, guest:)` runs I1–I12 and the warnings of [package-store.md](../../02-design/package-store.md) §4.6. Failures are `StoreFailure` cases. **Check:** one T0 fixture per check and warning.
5. **Preview and inspect.** Fill `ImportPreview` ([package-store.md](../../02-design/package-store.md) §10.1). `inspectFile` deletes its ticket. `apkrun inspect <file>… [--json]` runs with the runtime stopped. **Check:** goldens; no VM starts.
6. **aapt2 sandbox.** Profile in `Contents/Resources/tools/` denies network and writes, allows reads of the ticket and the tool. 20 s timeout, 16 MiB output cap, `LANG=C`. **Check:** T1: no write outside the ticket.
7. **`adoptPackage`.** Record `installer: external`, `updateAuthority: external`, no artifact, `source: adopted` ([package-store.md](../../02-design/package-store.md) §9.3). Merge after #38 step 1. **Check:** `apkrun adopt` gives authority `external`.

**Tests.**
- T0 (`APKStoreCoreTests`): containers (zip bomb and ZIP64 generated at test time); split selection; apksig vectors (v2, v3, v3.1, lineage, multi-signer, RSA, ECDSA, DSA, v1-only at targetSdk 29 and 30, bad digest, bad signature, truncated); I1–I12.
- T1 (`APKStoreCoreSystemTests`): aapt2 goldens; `fuzz-short` (60 s) for the container reader and signing-block parser.
- T2 (`Tests/IntegrationTests/StoreTests/`, stock): step 7.
- T3: nightly 50-APK F-Droid corpus matches `apksigner` ([test-strategy.md](../test-strategy.md) §7.1).

**Done when.**
- Both fuzz targets run clean in `fuzz-short`.
- `.apks`, `.xapk` without OBB, `.apkm`, and a ZIP of APKs import as one split set (FR-PKG-06). `.aab`, encrypted `.apkm`, and `.xapk` with OBB are refused with their own messages.
- Inspect takes under 1 s per 50 MiB APK with no VM (FR-PKG-03). After install, `apkrun info` shows Android's values (FR-PKG-02).
- `targetSdkTooLow`, `legacySignatureNotAllowed`, and `resourcesArscNotAligned` refuse before install ([R-15](../risks.md)).

**Pitfalls.**
- Generate the zip bomb at test time. Never commit it ([test-strategy.md](../test-strategy.md) §4.1).
- The host verifier may refuse what Android accepts (OQ-15), never the reverse.

---

## #38 LocalUpdateProvider

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #37 |
| Design | [update-system.md](../../02-design/update-system.md) §4.1–§4.3, §10; [package-store.md](../../02-design/package-store.md) §2.3, §5.5 |
| Code | `Packages/UpdateCore/` (new), `Packages/APKStoreCore/`, `Packages/RuntimeHost/`, `CLI/apkrun/Commands/Update.swift`, `Tests/Fixtures/update-repos/local/` |

**Goal.** With HelloUpdate V1 installed and V2 in a local folder, `apkrun update --check-only` reports V2 available, with no network (FR-PKG-04, FR-UPD-01 to FR-UPD-03).

**Out of scope.** Download and install (#39). Full authority rules (#40). Scheduled checks (#75). Other providers and the Add sheet (#51–#53, #79).

**Steps.**
1. **Authority in the record.** APKStoreCore: `UpdateAuthority`, `UpdateProviderRef`, `ProviderType`, `ProviderConfiguration`; `PackageRecord.updateAuthority` and `updateProvider` ([package-store.md](../../02-design/package-store.md) §2.3); `claimsUpdateOwnership`. A file import without a provider gets `manual`. **Check:** T0 round trip; a #37 record reads unchanged.
2. **UpdateCore types.** `UpdateProvider`, `UpdateCandidate`, `RemoteArtifact`, `ProviderContext`, `ProviderCursor`, `UpdatePhase` ([state-machines.md](../../01-architecture/state-machines.md) §6), `UpdateFailure`. **Check:** #63 module check.
3. **`LocalProvider`.** `ProviderRegistry` parses `local:<path>`. The CLI sends a bookmark (`ProviderSpec.bookmark`), never a path ([runtime-api.md](../../03-reference/runtime-api.md) §9.2). `check` reads `<root>/<packageId>/` and takes the highest numeric directory above the installed versionCode. A directory holds `app.apk`, or `base.apk` plus `split_*.apk`, or one `.apks`. No hashes. Hidden unless developer mode is on ([configuration.md](../../03-reference/configuration.md) §2.5). **Check:** T0 over temporary folders.
4. **State and coordinator.** `UpdateStateStore` writes `Updates/state.json` and `Updates/history.jsonl` ([update-system.md](../../02-design/update-system.md) §10). `UpdateCoordinator` runs `checking` → `available` with the outcomes of [update-system.md](../../02-design/update-system.md) §4.2 and §5. `notifyOnly` stops at `available`, and `HostNotifier` posts the notification. Later tasks change only their own phases. **Check:** T1 transitions; restart in `available`.
5. **Stage and discard.** `stage(ticket, StagedUpdateInfo)` and `discardStaged` with the recovery rows of [package-store.md](../../02-design/package-store.md) §5.5 and the `APKRUN_STORE_FAULT` hooks. `artifacts.staged` records the source ([package-store.md](../../02-design/package-store.md) §7.1). **Check:** T1 crash at every step.
6. **CLI.** `.control` `checkForUpdates`, `listUpdates`, `updateHistory`, `setUpdatePolicy` (attach: authority `apkrun`; remove: `manual`). Commands per [cli.md](../../02-design/cli.md) §4.2 and [update-system.md](../../02-design/update-system.md) §11.3. Add `update` codes to `errors.json`, then run `swift scripts/errorgen.swift --markdown`. **Check:** goldens in `CLI/apkrun/Tests/Golden/`.
7. **Fixtures.** `scripts/build-fixtures.sh` fills `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/`. **Check:** matches committed copies.

**Tests.**
- T0 (`UpdateCoreTests`, `APKStoreCoreTests`): directory rules and cursors; spec parser; state and record round trips; `stage` and `discardStaged` recovery rows.
- T1 (`UpdateCoreSystemTests`, `APKStoreCoreSystemTests`): coordinator with fakes; `APKRUN_STORE_FAULT` at each step; CLI goldens.
- T2 (`Tests/IntegrationTests/UpdateTests/`, both images): `--check-only` reports 2 with V1 installed.
- T3: none.

**Done when.**
- With only `1`, the check reports "up to date". `0` is never a candidate. No network is needed.
- Authority and provider are separate record fields (FR-UPD-01, FR-UPD-02).
- A staged set shows in `apkrun info`; `discardStaged` removes it; both survive a crash at each step (FR-PKG-04).
- `notifyOnly` stops at `available` with one notification. Deleting `state.json` makes the package due again.

**Pitfalls.**
- UpdateCore never imports RuntimeCore ([modules.md](../../01-architecture/modules.md) §3).
- Send a bookmark, never a path that apkrund would open.

---

## #39 PackageInstaller updates

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #38, #74 |
| Design | [update-system.md](../../02-design/update-system.md) §5, §6, §8.1; [package-store.md](../../02-design/package-store.md) §5.2, §6.4, §7.2; [guest-protocol.md](../../02-design/guest-protocol.md) §11.3 |
| Code | `Packages/APKStoreCore/`, `Packages/UpdateCore/`, `Packages/RuntimeHost/`, `Packages/RuntimeAPI/`, `CLI/apkrun/Commands/Update.swift`, `Tests/IntegrationTests/UpdateTests/` |

**Goal.** With V1 installed and launched once, V2 from the local provider is downloaded, validated on the host, staged, and installed in one `PackageInstaller` session. V2 reads V1's data. A V2 signed by another key never reaches Android. A crash at any step leaves store and Android consistent (FR-UPD-15, NFR-REL-01).

**Out of scope.** Gentle installs and `--now` (#41). Rules V4–V6 and rotation (#42); a rotated V2 is refused until then. Splits (#43). Rollback and ownership fields (#44, #40), masked until the channel has the capability.

**Steps.**
1. **`update` transaction.** `installStaged(id, enableRollback:)` runs [package-store.md](../../02-design/package-store.md) §5.2 and sends the `InstallRequest` of [guest-protocol.md](../../02-design/guest-protocol.md) §11.3. Stock: `adb install-multiple -r --no-streaming`, then `QueryPackage`. `hasOpenSession` before `BeginInstall` fails with `packageInUse(id)`. Promote with `renamex_np(RENAME_SWAP)`. Add `APKRUN_STORE_FAULT=update:<step>`. **Check:** T0 recovery rows per step; T1 crash injection.
2. **Download.** `beginDownloadTicket(id)`; hash while streaming; retries and failures as [update-system.md](../../02-design/update-system.md) §5. **Check:** T1 with a manual clock.
3. **Validation V0–V2.** `inspect(ticket)` runs I1–I12 as V0. `UpdateValidator` runs V1, V2, and signer equality ([update-system.md](../../02-design/update-system.md) §6). Failure: `completed(.skipped(.validationFailed(reason)))`. **Check:** T0 with V1, V2, V2-other-signer, HelloText.
4. **Stage, install, H1.** `stage(ticket, StagedUpdateInfo)` from #38. If `hasActiveUse` is false, `installStaged(id, enableRollback: true)`, then `installing` and `healthChecking`. Only H1 of [update-system.md](../../02-design/update-system.md) §8.1 runs. First `UpdateRuntimeAccess` in RuntimeHost (`runtimeState`, `hasActiveUse`, `ensureReady(.update)`). Automatic runs need `ready`. A package with a session stays `staged`. **Check:** T1 transitions with fake store and runtime.
5. **Relations and CLI.** Classify imports ([package-store.md](../../02-design/package-store.md) §4.7). `update` enters UpdateCore at `validating`, trigger `manual`. `googlePlay` and `external` fail with `update.authorityDoesNotAllowUpdates`. `apkrun update <package> [--file <apk>…]`; `update` without `--check-only` continues `automatic` past `available`; `CheckForUpdatesRequest.checkOnly` stops at `available`. **Check:** T0 relation tests; goldens.

**Tests.**
- T0 (`APKStoreCoreTests`, `UpdateCoreTests`): every `ImportRelation` case; `update` recovery rows with a scripted channel; V0–V2 and signer equality over HelloUpdate.
- T1 (`APKStoreCoreSystemTests`, `UpdateCoreSystemTests`): `packageInUse`; process crash at each host step, restart, `open()`; coordinator transitions; goldens.
- T2 (`Tests/IntegrationTests/UpdateTests/`, `StoreTests/`, both images): V2 reports 2 and logs `data HELLO`; V2-other-signer refused by the host; `AdbClient.install(apk:)` of it fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; `update --file` works. Custom only: apkrund killed during `CommitInstall`, before and after the commit.
- T3: none.

**Done when.**
- V1 → V2 installs in one session on both images (FR-UPD-15); `apkrun info` shows 2.
- V2-other-signer is refused before any Android call. No build can disable the host check ([AGENTS.md](../../../AGENTS.md) §4, invariant 10).
- Equal versionCode gives `notNewer`; lower gives `downgrade`. A newer file takes the same path with trigger `manual`.
- `installStaged` with a session fails `store.packageInUse`, and the set stays in `staged/`.
- A fault at each `update` step leaves `current/`, `previous/`, and `staged/` matching Android (NFR-REL-01). Each run appends one history line.

**Pitfalls.**
- Do not send `enable_rollback` or `request_update_ownership` before the capability; the agent answers `INVALID_ARGUMENT`.
- Recovery identifies slots by `setDigest`, never by directory name ([package-store.md](../../02-design/package-store.md) §5.5).
- No hook skips a host check. Tests that need Android's refusal use `AdbClient` ([test-strategy.md](../test-strategy.md) §3.3).

---

## #40 Update ownership

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #39 |
| Design | [update-system.md](../../02-design/update-system.md) §2.1–§2.4, §11.3; [package-store.md](../../02-design/package-store.md) §6.3; [guest-components.md](../../02-design/guest-components.md) §8.2; [guest-protocol.md](../../02-design/guest-protocol.md) §11.1 |
| Code | `Guest/APKRunStore/`, `Packages/GuestProtocol/` (op 109), `Packages/APKStoreCore/`, `Packages/UpdateCore/`, `CLI/apkrun/Commands/Update.swift`, `Tests/Fixtures/AndroidApps/OtherInstaller/` |

**Goal.** APKRun holds Android update ownership for each `apkrun` and `manual` package, so no other installer can update it without user approval. It never claims ownership of a `googlePlay` or `external` package (FR-UPD-01, FR-UPD-06).

**Out of scope.** "Updated by" and the Updates choice (#80, #79). Google Play as an authority (#98). Gentle updates and rollback (#41, #44).

**Steps.**
1. **Store Agent.** Op 109 and `store.ownership.v1` in Swift and Kotlin (additions only; `scripts/generate-protos.sh`). `OwnershipService` calls `PackageManager.relinquishUpdateOwnership`, answering `FAILED_PRECONDITION` when not the owner. `InstallService` sets `setRequestUpdateOwnership`. Report the enforcement flag in `Hello` ([guest-components.md](../../02-design/guest-components.md) §8.2). **Check:** the flag without the capability gives `INVALID_ARGUMENT`.
2. **Ownership on install.** Request ownership on `firstInstall`, `reinstall`, and `update` as [package-store.md](../../02-design/package-store.md) §6.3 defines. Record `android.updateOwner`. `store.ownership` warns `store.updateOwnerMissing` when an `apkrun` or `manual` owner is not `io.apkrun.store`. **Check:** T1 per authority and capability.
3. **Store authority change.** `setUpdateAuthority(id, authority, provider:)` under the operation lock. Leaving `apkrun` or `manual` for `googlePlay` or `external` calls `RelinquishUpdateOwnership` before the record write. Without a `ready` runtime, it is a post-boot task. **Check:** T1 call order and post-boot task.
4. **Authority rules.** Implement [update-system.md](../../02-design/update-system.md) §2.1–§2.4 in UpdateCore. `setUpdatePolicy` writes `settings.json` `update.mode` before the record's `updateAuthority` and `updateProvider`, so a crash never leaves automatic updates on. **Check:** T0 mapping; a T1 counting fake gets no call for `manual`.
5. **`setUpdateAuthority` and CLI.** `.control` `setUpdateAuthority(id, AuthorityChoice)` (`SetUpdateAuthorityRequest`; only #98 sets `googlePlay`). Moving to `external` discards staged sets. `apkrun update authority <package> apkrun|manual|external` ([cli.md](../../02-design/cli.md) §4.3). **Check:** T1: a move to `external` sends `RelinquishUpdateOwnership` before the record write.
6. **OtherInstaller fixture.** As [test-strategy.md](../test-strategy.md) §4.2 specifies. **Check:** logs a status on stock.
7. **Owner-less check.** Custom image, developer mode: install V1 with `AdbClient.install(apk:)`, adopt, switch to `manual`, update to V2 with `--file`, and read `updateOwner`. **Check:** OQ-12 and R-18 record the result.

**Tests.**
- T0 (`UpdateCoreTests`, `APKStoreCoreTests`, `GuestProtocolTests`): authority mapping per UI choice and install path; `setUpdatePolicy` and `setUpdateAuthority` rules from every authority; argument rule.
- T1 (`UpdateCoreSystemTests`, `APKStoreCoreSystemTests`): counting fake provider; relinquish order; crash between the two `setUpdatePolicy` writes; CLI goldens.
- T2 (`Tests/IntegrationTests/StoreTests/`, custom; stock for the warning): owner is `io.apkrun.store` after install and update. OtherInstaller's session ends `STATUS_PENDING_USER_ACTION`, and HelloUpdate stays at 1. After `external`, the owner is cleared.
- T3: none.

**Done when.**
- HelloUpdate installed with authority `apkrun` reports `updateOwner == io.apkrun.store` after install and update, and `metadata.json` holds `updateAuthority` and `android.updateOwner`.
- OtherInstaller cannot update HelloUpdate without user action.
- `googlePlay` and `external` installs never request ownership. After a switch to `external`, Android reports no owner.
- Switching to Manual stops all provider checks. No crash leaves automatic updates on.
- On stock, updates work without ownership, and health warns `store.ownership`.
- OQ-12 and R-18 record the owner-less result.

**Pitfalls.**
- `STATUS_PENDING_USER_ACTION` alone does not prove enforcement. The version must stay unchanged, with the enforcement flag on.
- A crash between relinquish and the record write is safe; the next install requests ownership again ([package-store.md](../../02-design/package-store.md) §6.3).

---

## #41 Gentle updates

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #40 |
| Gate | G7 |
| Design | [update-system.md](../../02-design/update-system.md) §7.1–§7.5; [package-store.md](../../02-design/package-store.md) §5.3, §7.2; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1 |
| Code | `Packages/UpdateCore/` (`GentleUpdateGate`), `Packages/RuntimeHost/`, `Packages/RuntimeCore/` (`SessionRegistry`), `Packages/GuestProtocol/` (op 110), `Guest/APKRunStore/` (`ConstraintsService`), `Tests/AcceptanceTests/G7GentleUpdate/` |

**Goal.** An update is never installed while its app is in use. After the app quits it installs within 30 s, without user action. A click during the install has one defined result on both images (FR-UPD-07). G7 passes.

**Out of scope.** Scheduled checks and `updates.startRuntimeToInstall` (#75); G7 starts with `apkrun update`. Health checks beyond H1 (#44). Home and app-page buttons (#79, #80).

**Steps.**
1. **`CheckInstallConstraints`.** Op 110 and `store.constraints.v1`. `ConstraintsService` answers on the callback or with `TIMEOUT` after 10 s, and never waits for `true`. **Check:** T2 shows `satisfied = false` with a visible task.
2. **`UpdateRuntimeAccess`.** Complete the #39 class with the members of [update-system.md](../../02-design/update-system.md) §7.5 except `healthCheckLaunch`. GU5 uses op 110 on custom and `ListTasks` on stock. **Check:** T1 with fake sessions and agents.
3. **`GentleUpdateGate`.** `isOpen(package)` evaluates GU1–GU7 ([update-system.md](../../02-design/update-system.md) §7.1) at the triggers of [update-system.md](../../02-design/update-system.md) §7.2. Log each false condition (`install`). Installs run under a `storeOperation` assertion, one at a time: user-initiated first, then longest waiting. Add `updates.waiting`. **Check:** T1 with a manual clock covers each condition, trigger, and the queue.
4. **Races.** The `openSession` rules of [update-system.md](../../02-design/update-system.md) §7.2 and [runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1. The first frame counts as H4. **Check:** T1 at each transaction step.
5. **User-initiated and 7-day notice.** [update-system.md](../../02-design/update-system.md) §7.3 and §7.4. `apkrun update <package>` prints "will update when ‹App› quits" without `--now`; `--now` is Update Now without the question. APKRun never closes an app itself. **Check:** CLI goldens; T1 with a manual clock.
6. **Foreground services.** Custom image: HelloUpdate V1 with the `fgs` extra ([test-strategy.md](../test-strategy.md) §4.3), window closed, op 110 with `GENTLE_UPDATE`. Record whether it reports busy, and the `checkInstallConstraints` caller rule. If not busy, GU5 adds `ListTasks` and a process-importance query. **Check:** OQ-17 records both results.
7. **G7 check.** `Tests/AcceptanceTests/G7GentleUpdate` for `scripts/run-gate.sh G7` ([test-strategy.md](../test-strategy.md) §5). **Check:** passes on the reference Mac from a clean build of `main`.

**Tests.**
- T0 (`UpdateCoreTests`): waiting-reason mapping; queue order.
- T1 (`UpdateCoreSystemTests`, `RuntimeCoreSystemTests`): GU1–GU7 each false alone; every trigger; step 4 races; `closeRunningApp` both ways; 7-day notice once; goldens with and without `--now`.
- T2 (`Tests/IntegrationTests/UpdateTests/`, custom; stock for `ListTasks`): with V1's window open and V2 staged, no install for 10 min; no install with `keepRunning` or within 15 s after session end; V2 installs within 30 s after quit and logs `data HELLO`; clicks before and after commit. The test sets `window.closeBehavior = keepRunning` with `updatePackageSettings`.
- T3: G7 nightly; checklist C03-2 ([test-strategy.md](../test-strategy.md) §8.4).

**Done when.**
- No install while the window is open for 10 min, with `keepRunning`, or within 15 s after session end.
- Within 30 s after quit, V2 installs and opens with `data HELLO`.
- A click before the commit cancels the install and opens V1; after it, "Updating ‹App›…" then V2.
- `apkrun update` with the app open prints "will update when ‹App› quits"; `--now` installs and reopens V2.
- A 7-day staged update posts one notification with **Update Now**.
- OQ-17 is settled, and G7 passes.

**Pitfalls.**
- GU5 is only a hint. GU2–GU4 and step 4 decide. Never skip GU2 because op 110 said `satisfied`.
- Never cache a `CheckInstallConstraints` result. Re-evaluate before each install.
- A closed client connection cancels nothing ([runtime-api.md](../../03-reference/runtime-api.md) §4.7).

---

## #42 Package and signature verification

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #39, #74 |
| Design | [update-system.md](../../02-design/update-system.md) §6, §9; [package-store.md](../../02-design/package-store.md) §3.1, §4.5 |
| Code | `Packages/APKStoreCore/` (signer-set, `VersionCode`, set-digest comparisons), `Packages/UpdateCore/` (`UpdateValidator`, `ValidationReport`), `scripts/build-fixtures.sh`, `Tests/Fixtures/AndroidApps/HelloUpdate/` |

**Goal.** Every update, from a provider or a file, passes V0–V6 before staging. Wrong package, wrong signer, downgrade, corrupted APK, changed file, and provider metadata that disagrees with the APK are refused with a readable reason. Rotation is accepted exactly where Android accepts it. No setting or build turns a rule off (FR-UPD-04, FR-UPD-05, FR-UPD-14, NFR-SEC-04).

**Out of scope.** I1–I12 (#74; V0 calls them). The download hash check (#39). Splits (#43). Writes to `skippedVersions` (#44).

**Steps.**
1. **Primitives.** Signer-set comparison with the lineage rules of [update-system.md](../../02-design/update-system.md) §6 (`INSTALLED_DATA` for updates, `ROLLBACK` for undone rotations). Multi-signer sets must be equal. Compare SHA-256 of the certificate DER. `VersionCode` and set-digest comparison. **Check:** T0 over hand-built signer sets and lineages.
2. **Fixtures.** `scripts/build-fixtures.sh` builds the rotation variants and the corrupted V2 of [test-strategy.md](../test-strategy.md) §4.3, with pinned `apksigner rotate` and `sign --lineage`. **Check:** `scripts/check-fixtures.sh` reproduces the bytes.
3. **`UpdateValidator`.** Run V0–V6 in table order, stopping at the first failure; unrun rules report "not run" ([update-system.md](../../02-design/update-system.md) §6). V3 uses *S* from Android and *S′* from the host verifier, and at `.certificateOnly` compares certificate digests. V5 only refuses. Failure: `completed(.skipped(.validationFailed(reason)))`. **Check:** the T0 matrix.
4. **Report.** `ValidationReport` with each rule, its inputs, its verdict, and the UI records of [update-system.md](../../02-design/update-system.md) §6. Save as JSON in `staged/validation.json` ([package-store.md](../../02-design/package-store.md) §3.1), outside `setDigest`. Post "Update refused" for V3 and V5 ([update-system.md](../../02-design/update-system.md) §9). **Check:** T1 reads it back after restart; a fake UI client gets the notification.

**Tests.**
- T0 (`UpdateCoreTests`, `APKStoreCoreTests`): V0–V6 with the [test-strategy.md](../test-strategy.md) §4.3 fixtures against a scripted installed state, covering each `ValidationFailure` case and the valid V1 → V2 upgrade; signer-set primitives; "not run" entries.
- T1 (`UpdateCoreSystemTests`): report read back after restart; "Update refused" through a fake UI client.
- T2, T3: none.

**Done when.**
- V2 over V1 passes V0–V6.
- Each refusal in [update-system.md](../../02-design/update-system.md) §6 gives its named reason, including `packageMismatch`, `signerMismatch`, `lineageMissingCapability`, `downgrade`, `invalidSignature`, `providerHashMismatch`, `providerMetadataMismatch`, and `skippedVersion`.
- A rotation with `INSTALLED_DATA` is accepted and recorded in the history.
- A lower versionCode is refused always, with no flag, setting, or build to allow it (FR-UPD-05).
- Metadata that disagrees with the APK is refused; the APK decides (FR-UPD-14).
- Every validated update's history holds a `ValidationReport`.
- No setting, environment variable, hook, or build type disables a rule. The release check of [test-strategy.md](../test-strategy.md) §3.3 finds none (NFR-SEC-04).
- [R-15](../risks.md) records which install floors the host checks catch, with their fixtures.

**Pitfalls.**
- Compare signers by SHA-256 of the certificate DER, never by subject or key alone.
- V5 only refuses. A provider value never replaces an APK value.
- Refuse every downgrade. Only the binary rollback of #44 installs an older version.

---

## #43 Split APK installation

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #42, #74 |
| Design | [package-store.md](../../02-design/package-store.md) §4.4, §6.2, §6.4, §7.2; [guest-protocol.md](../../02-design/guest-protocol.md) §11.3 |
| Code | `Packages/APKStoreCore/` (split sets on both channels), `Guest/APKRunStore/` (`InstallService`), `Tests/Fixtures/AndroidApps/HelloSplit/`, `Tests/IntegrationTests/StoreTests/` |

**Goal.** A split set installs, updates, and reinstalls in one `PackageInstaller` session on both channels. HelloSplit, imported from `.apks`, installs and launches. Its native library loads, and its Japanese string shows at guest locale `ja-JP` (FR-PKG-05).

**Out of scope.** Split selection (#74). macOS locale sync (#86); T2 sets the guest locale directly. On-demand feature splits (Google Play). `MODE_INHERIT_EXISTING`: every install sends the full set.

**Steps.**
1. **HelloSplit.** Build from an App Bundle with the pinned bundletool ([build-system.md](../../05-development/build-system.md) §8.1), per [test-strategy.md](../test-strategy.md) §4.2. **Check:** `scripts/check-fixtures.sh` passes; the `.apks` holds base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, and the feature split.
2. **ADB channel.** One `adb install-multiple -r --no-streaming` call with every file, base first. Results map as [package-store.md](../../02-design/package-store.md) §6.4 says. **Check:** T1 fake `AdbClient` sees one call.
3. **Store Agent channel.** One `ArtifactSpec` per file in `BeginInstall`; stream each into the same session; commit once. Extend `InstallService` if needed. **Check:** T1: one session; a hash mismatch on one split aborts all.
4. **Update and reinstall.** Send the full set. `current/`, `previous/`, and `staged/` hold every file; `setDigest` covers them. **Check:** T1 with a fake channel.
5. **Density record.** Record the density bucket `SplitSelector` picked and whether the window looks right. Settle OQ-14. **Check:** the OQ-14 row has the result.

**Tests.**
- T0 (`APKStoreCoreTests`): split selection over HelloSplit's `.apks` (shared with #74); the `ArtifactSpec` list.
- T1 (`APKStoreCoreSystemTests`): one `install-multiple` call; one session with several artifacts; update and reinstall.
- T2 (`Tests/IntegrationTests/StoreTests/`, both images): installs and launches; logs `native ok`; at guest locale `ja-JP` (set through `AdbClient` in developer mode) logs the Japanese string; `QueryPackage` lists the splits.
- T3: none here. The macOS-Japanese check is C05-9 in #86 ([test-strategy.md](../test-strategy.md) §8.6).

**Done when.**
- HelloSplit installs and launches on both images.
- One session: one `install-multiple` on stock; one `BeginInstall` and one `CommitInstall` on custom.
- `current/` holds every file, and Android lists the same splits.
- Update and reinstall send the full set in one session. The density choice is in OQ-14.

**Pitfalls.**
- The base must share one session with its splits. Splits in a second session fail the first commit with `INSTALL_FAILED_MISSING_SPLIT`.
- `setDigest` sorts by file name. The same files in another order are the same install.

---

## #44 Update rollback

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #42, #43 |
| Design | [update-system.md](../../02-design/update-system.md) §8.1–§8.5, §9; [package-store.md](../../02-design/package-store.md) §5.5, §7.3; [guest-protocol.md](../../02-design/guest-protocol.md) §11.1 |
| Code | `Packages/UpdateCore/` (`UpdateHealthChecker`), `Packages/RuntimeHost/` (`healthCheckLaunch`), `Packages/APKStoreCore/` (`rollback`), `Packages/GuestProtocol/` (op 108), `Guest/APKRunStore/` (`RollbackService`), `CLI/apkrun/Commands/`, `Tests/IntegrationTests/UpdateTests/` |

**Goal.** After each update, APKRun checks that Android reports the new version, the app launches, its process stays alive, and it draws a frame. A broken update returns to the previous APK set without user action, and that version is skipped. App data is never reverted, and every rollback message says so (FR-UPD-10, FR-UPD-11).

**Out of scope.** Skip and rollback controls in package settings (#80). Data rollback (OQ-16). Repair of a `broken` package (#77).

**Steps.**
1. **Custom rollback.** Op 108 `RollbackPackage` and `store.rollback.v1`. `RollbackService` accepts only a rollback matching the package and both versionCodes, else `NOT_AVAILABLE`. `InstallService` calls `setEnableRollback(true, ROLLBACK_DATA_POLICY_RETAIN)`. `rollback` transaction: begin → `guestRollbackRequested` → `guestRolledBack` → `filesRestored` → `metadataWritten` → commit ([package-store.md](../../02-design/package-store.md) §5.5). **Check:** T0 recovery rows; T1 crash injection.
2. **Other mechanisms.** The three mechanisms of [package-store.md](../../02-design/package-store.md) §7.3. The data-loss path runs only after a confirmed user action (`allowDataLoss: true`). **Check:** T1 per mechanism; a background call never uninstalls.
3. **`UpdateHealthChecker`.** H1–H4, the budget, and the levels of [update-system.md](../../02-design/update-system.md) §8.1. `healthCheckLaunch` follows [update-system.md](../../02-design/update-system.md) §8.2. Record the level and each step. **Check:** T1 with a manual clock covers each level and each failing step.
4. **Outcomes and notices.** [update-system.md](../../02-design/update-system.md) §8.3 decides the result; [update-system.md](../../02-design/update-system.md) §8.4 and §8.5 handle skipped versions. CLI: `apkrun rollback <package> [--allow-data-loss] [--yes]`, `apkrun update skip|unskip <package> <versionCode>`. Markers `UPDATE_HEALTH_END` and `UPDATE_ROLLBACK_END`; health check `updates.failed`. **Check:** T1 per [update-system.md](../../02-design/update-system.md) §8.3 row; goldens.
5. **`user` image.** Custom `user` and `userdebug`: V2 over V1 with `enable_rollback`; `getAvailableRollbacks` lists it; `commitRollback` restores V1. Settle OQ-11; update R-18, which keeps its #59 part open. **Check:** OQ-11 and R-18 record the result.

**Tests.**
- T0 (`APKStoreCoreTests`, `UpdateCoreTests`, `GuestProtocolTests`): `rollback` recovery rows with a scripted Android state; level choice; [update-system.md](../../02-design/update-system.md) §8.3 mapping; `enable_rollback` argument rules.
- T1 (`UpdateCoreSystemTests`, `APKStoreCoreSystemTests`): health levels and timeouts; crash injection at each `rollback` host step; each mechanism; CLI goldens.
- T2 (`Tests/IntegrationTests/UpdateTests/`, both images): V3-broken (crashes 2 s after launch) over V2 fails H3 and rolls back to V2; V3 is skipped; `files/v2.txt` remains; V4 installs; `RollbackPackage` without a rollback returns `NOT_AVAILABLE`; the data-loss fallback after confirmation; `apkrun rollback` V2 → V1.
- T3: checklist C03-1: rollback messages say data is not rolled back ([test-strategy.md](../test-strategy.md) §8.4).

**Done when.**
- V3-broken is rolled back to V2 on both images.
- The notification, history entry, and `apkrun rollback` output say app data is not rolled back.
- `previous/` holds V2 before V3 installs and becomes `current/` after the rollback; V3's set is in `failed/3/`.
- V2's `files/v2.txt` survives (`ROLLBACK_DATA_POLICY_RETAIN`).
- V3 stays skipped, V4 installs, and `apkrun update unskip <package> 3` lists V3 again.
- With no rollback, a background rollback never erases data; the notification offers **Keep** and **Restore (Erases Data)…**.
- With `update.autoRollback` off, a failed update is kept with **Roll Back**.
- OQ-11 records the `TEST_MANAGE_ROLLBACKS` result on `user` and `userdebug`.

**Pitfalls.**
- Do not force-stop after a health-check launch; alarms and jobs stop ([update-system.md](../../02-design/update-system.md) §8.2).
- The data-loss fallback erases app data. Never run it without the user's confirmation.

---

## #51 DirectProvider

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #38, #42 |
| Design | [update-system.md](../../02-design/update-system.md) §3.4, §4.4, §12; [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §5–§8 |
| Code | `Packages/UpdateCore/` (`Providers/DirectProvider.swift`, `DirectManifest`), `docs/03-reference/schemas/direct-provider-manifest.schema.json`, `scripts/dev/update-server.py`, `Tests/Fixtures/update-repos/direct/`, `CLI/apkrun/` |

**Goal.** A distributor publishes an APKRun manifest over HTTPS, and APKRun updates the package from it. The manifest lists package, versionCode, versionName, artifacts, and hashes. The APK's own values decide; the manifest can only refuse (FR-UPD-12).

**Out of scope.** Signed manifests (OQ-19). F-Droid and GitHub providers (#52, #53). Provider picker (#80). Long fuzz runs (#92).

**Steps.**
1. **Model and schema.** `Codable` `DirectManifest` and rules D1–D9 of [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §6. The published JSON Schema wins on structure. **Check:** T0 for every fixture in `direct/valid/` and `direct/invalid/`.
2. **HTTP and download.** Shared `URLSession` and the HTTP rules of [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §5 and [update-system.md](../../02-design/update-system.md) §3.4. Refuse user info and non-HTTPS URLs. A failed check keeps the last cursor. `download` hashes while streaming and fails with `update.hashMismatch` after one retry. **Check:** T1 against `update-server.py`.
3. **Local test service.** `scripts/dev/update-server.py` serves `Tests/Fixtures/update-repos/local/` and `direct/` as Direct manifests on `http://127.0.0.1:<port>`. `--delay <seconds>` holds every manifest response. Debug builds only ([update-system.md](../../02-design/update-system.md) §12). **Check:** a Release build refuses a loopback `http` URL in `setUpdatePolicy`.
4. **Configuration and CLI.** `direct:<https-url>` in the #38 parser; `--update-provider direct --update-url <url>` maps to it. `setUpdatePolicy` checks the configuration before storing. **Check:** goldens for `update policy --provider direct:<url>`, `install <file> --provider direct:<url>`, and the alternate flags.

**Tests.**
- T0 (`UpdateCoreTests`): schema cases of [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §12; model and schema agreement; URL resolution; candidate mapping.
- T1 (`UpdateCoreSystemTests`): `DirectProvider` against `update-server.py` on `127.0.0.1`: `304`, redirects, body cap, `429`, cursor; versionCode mismatch refused by V5; wrong `sha256` gives `update.hashMismatch` after one retry.
- T2 (`Tests/IntegrationTests/UpdateTests/`, custom): V1 → V2 through `update-server.py`, `data HELLO` kept; versionCode mismatch refused by V5; wrong `sha256` refused while downloading.
- T3: none.

**Done when.**
- With a `direct:` provider pointing to `update-server.py`, V2 is found, validated, installed, and logs `data HELLO`.
- The model reads every field of [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §3 and agrees with the schema.
- A versionCode mismatch gives V5 (`providerMetadataMismatch(versionCode)`). A wrong `sha256` is refused while downloading, after one retry.
- Release builds accept only `https` manifest and artifact URLs, after redirects and relative resolution. Debug builds also accept `http://127.0.0.1` and `http://localhost`.
- Each D-rule failure gives `providerMetadataInvalid` naming the field and rule, and keeps the last good cursor.
- `direct:<https-url>` and `--update-provider direct --update-url <url>` attach the same provider.

**Pitfalls.**
- Resolve relative artifact URLs against the final manifest URL after redirects, not the configured URL.
- `signingCertificates` is not a check filter. A rotated signer differs from the installed one, and V3 decides after download.

---

## #75 Update scheduler

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #38, #41, #51 |
| Design | [update-system.md](../../02-design/update-system.md) §2.2, §3; [runtime-daemon.md](../../02-design/runtime-daemon.md) §2.4, §7.1; [configuration.md](../../03-reference/configuration.md) §2.7 |
| Code | `Packages/UpdateCore/` (`UpdateScheduler`, `noteLaunched`), `Packages/RuntimeHost/` (exit rule), `Packages/RuntimeCore/` (`SessionRegistry`), `Tests/PerformanceTests/`, `Tests/AcceptanceTests/G7GentleUpdate/` |

**Goal.** apkrund checks every `apkrun` package on a schedule without making a launch wait. Checks use jitter, backoff, and network and power rules. A launch checks only after its first frame, and apkrund exits when nothing is due (FR-UPD-08, FR-UPD-09, NFR-PERF-07).

**Out of scope.** The Updates pane and app-page mode (#80); the menu bar list (#87). The "Updated" notification text (#38).

**Steps.**
1. **`UpdateScheduler`.** Timing, backoff, triggers, and resource limits as [update-system.md](../../02-design/update-system.md) §3.2–§3.4; per-mode behavior as [update-system.md](../../02-design/update-system.md) §2.2. Skip packages in `downloading`, `validating`, `installing`, `healthChecking`, `rollingBack`, and non-`apkrun` packages. A newer candidate replaces a `staged` set. **Check:** T1 with a manual clock.
2. **Exit rule and `noteLaunched`.** RuntimeHost answers "work due within the grace period" ([runtime-daemon.md](../../02-design/runtime-daemon.md) §2.4). `SessionRegistry` calls `noteLaunched(package)` after the `openSession` reply ([runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1). A due check starts 30 s after the first frame. **Check:** `openSession` returns before any UpdateCore call.
3. **Settings.** `updates.checkIntervalHours`, `updates.downloadOnExpensiveNetwork`, `updates.startRuntimeToInstall`, `updates.notifyInstalled` with the rules of [configuration.md](../../03-reference/configuration.md) §2.7; `apkrun config get|set`. **Check:** T1 per apply rule.
4. **Background install.** The conditions of [update-system.md](../../02-design/update-system.md) §3.5 boot the runtime headless with `ensureReady(.update)`; installs follow the gate. **Check:** T1 with fake power and idle sources.
5. **`apkrun update` output.** One line per `apkrun` package: up to date, available, installed, waiting, or failed. Exit 2 when some failed ([cli.md](../../02-design/cli.md) §3.3). **Check:** goldens.
6. **`update-check-launch`.** Ten packages with a Direct provider from `update-server.py --delay 5`; each package except HelloUpdate answers at its installed versionCode. Run `warm-launch` 30 times during the checks ([diagnostics.md](../../02-design/diagnostics.md) §9). **Check:** p50 difference at most 50 ms.
7. **Scheduled G7 run.** A second run in `G7GentleUpdate`: attach the provider just before V1 launches, so the package is due; the check 30 s after V1's first frame stages V2 while V1's window is open. **Check:** `scripts/run-gate.sh G7` passes both runs.

**Tests.**
- T0 (`UpdateCoreTests`): `nextCheckAt` with jitter and backoff; mode per package.
- T1 (`UpdateCoreSystemTests`, `RuntimeHostSystemTests`): 20 packages on schedule with a manual clock; backoff; skipped phases; concurrency and network rules; exit rule; step 4; goldens.
- T2 (`Tests/IntegrationTests/UpdateTests/`, custom): with `update-server.py --delay 30`, `apkrun launch` reaches `FIRST_FRAME` as fast as with the provider disabled, and the check starts after the first frame. apkrund with nothing due exits after the grace period.
- T3: nightly `update-check-launch` (NFR-PERF-07) and the step 7 run.

**Done when.**
- With a manual clock, 20 packages are checked on schedule with jitter; a failing provider backs off; `downloading` and `installing` packages are not checked; a newer candidate replaces a staged one.
- A 30 s slow provider does not delay `FIRST_FRAME` (FR-UPD-08).
- An hourly start with nothing due exits after the 2-minute grace period.
- `update-check-launch` p50 difference is at most 50 ms.
- Only allowed interval values are accepted; a change recomputes next check times.
- Scheduled checks follow each mode (FR-UPD-09). `apkrun update` exits 2 when some failed.

**Pitfalls.**
- Use `ContinuousClock`, not `SuspendingClock`, so checks due during sleep run after wake.
- Jitter is fixed per package per cycle. A new random value per evaluation breaks the backoff tests.
- Updates never block launch. No UpdateCore work runs before `openSession` replies.
