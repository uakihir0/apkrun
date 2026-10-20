# M5 Custom Android runtime image

APKRun gets its own Android image: the APKRun AOSP product, built on a Linux builder from Cuttlefish's arm64 phone product. The Guest Agent runs in it as a persistent, platform-signed priv-app. `apkrun_vsockd` bridges vsock to the agents' local sockets, and SELinux confines all of it. The host talks to the agents over vsock with ADB off, and the Store Agent installs apps without `adb install`. From M5 on, this image is the product test image. The milestone closes no gate; the G2–G6 checks run again on it ([test-strategy.md](../test-strategy.md) §5). AOSP is never built on macOS: every image build runs on the Linux x86-64 builder ([build-system.md](../../05-development/build-system.md) §9).

---

## #36 APKRun AOSP product

| Field | Value |
|---|---|
| Milestone | M5 (v0.3) |
| Depends on | #35 |
| Design | [android-image.md](../../02-design/android-image.md) §8.4, §11, §13; [guest-components.md](../../02-design/guest-components.md) §4, §5, §10 |
| Code | `Guest/product/`; `Guest/vsockd/`; `Guest/guestd/`; `scripts/aosp/`; `Images/manifests/ar<n>/`; `Tests/Fixtures/AndroidApps/` (HelloProbe); `Tests/IntegrationTests/AndroidBootTests/`, `GuestAgentTests/`, `SecurityTests/` |

**Goal.** The APKRun AOSP product builds reproducibly on the Linux builder. Its image boots under the APKRun VM with the Guest Agent as a platform-signed priv-app, reached over vsock with ADB off.

**Out of scope.** The Store Agent (#37). M9 components (#55, #82, #83). Image updates (#59, #88). Removing services without #96 evidence; kernel, partition, or fstab changes (R-14).

**Steps.**
1. **Builder.** `scripts/aosp/builder.Dockerfile`, `build-product.sh --revision <commit> --variant userdebug|user`, and `remote-build.sh` ([android-image.md](../../02-design/android-image.md) §11.1, §11.5). **Check:** a userdebug build without APKRun modules yields `apkrun_arm64-img-ar<n>.zip`.
2. **Priv-apps.** `GuestAgentApplication` runs in `AgentMode.PRIVILEGED_APP`. `Android.bp` imports both APKs with `certificate: "platform"`, `privileged: true`, `presigned: false` ([guest-components.md](../../02-design/guest-components.md) §4.1). Permissions: [guest-components.md](../../02-design/guest-components.md) §5. Product changes: [android-image.md](../../02-design/android-image.md) §11.2. **Check:** `dumpsys package io.apkrun.guest` shows the platform signature and every permission granted.
3. **`apkrun_vsockd`.** `Guest/vsockd` builds a `rust_binary` in `PRODUCT_PACKAGES`; ports and the init service are in [guest-components.md](../../02-design/guest-components.md) §10.1 and §10.2. **Check:** T0 `cargo test` for ports and limits; T1 with `vsock_loopback`: a ninth connection and a peer CID other than 2 are refused.
4. **SELinux.** Domains: [guest-components.md](../../02-design/guest-components.md) §4.2, §10.2. The three new domains are `permissive` in `userdebug` only; `scripts/check-sepolicy.sh` rejects `permissive` in `user` builds. Fix the virtio-gpu `sysfs` label in the product policy, and never grant `sysfs` to app domains ([android-image.md](../../02-design/android-image.md) §11.1). **Check:** T2 `SelinuxDenialTests`: no `avc: denied` for the three domains when enforcing.
5. **Developer mode.** adbd listens on vsock 5555 only with `ro.boot.apkrun.devmode=1`. Override the base product's always-on adbd, and record the override in [android-image.md](../../02-design/android-image.md) §11.3. **Check:** T2 `DeveloperModeAdbTests`: `devmode=1` works on `127.0.0.1:6520`; `devmode=0` runs no adbd and refuses uid `shell`.
6. **Bundle and release.** `scripts/inventory-cuttlefish.py`, then `python3 -m apkrun_image bundle` (`kind: apkrun`); commit `Images/manifests/ar<n>/`. vsock is the custom-image transport. Rebuild test bundles A, B, B′, F, P, and S ([test-strategy.md](../test-strategy.md) §3.5). Add CF rows to [android-image.md](../../02-design/android-image.md) §13. The `user` variant uses the OQ-36 default ([android-image.md](../../02-design/android-image.md) §11.4). **Check:** T2 `VsockAgentTests`.
7. **Acceptance.** Compare with `Images/reference/16373615/target` ([android-image.md](../../02-design/android-image.md) §8.4). Run AndroidCustom, HelloProbe, G2–G6, and the graphics checks without the #99 profile. **Check:** the Done-when items.

**Tests.**
- T0 (`Guest/vsockd`, `cargo test`): port table, connection limits.
- T1 (`Guest/vsockd`, `vsock_loopback`): the bridge splices both ways and refuses peers other than CID 2.
- T2 (`Tests/IntegrationTests/AndroidBootTests/`, `GuestAgentTests/`, `SecurityTests/`, AndroidCustom): `CustomImageBootTests`, `AgentSocketIsolationTests`, `SystemServicesTest`, `DeveloperModeAdbTests`, `VsockAgentTests`, `SelinuxDenialTests`.
- T3: G2–G6 on the custom image; the `user` release-candidate boot.
- HelloProbe fixture: [test-strategy.md](../test-strategy.md) §4.2.

**Done when.**
- The image reaches `boot_completed` with its enforcing policy and no diagnostic profile. SurfaceFlinger reports Mesa VirGL, and HelloGL renders in `u:r:untrusted_app` (FR-IMG-05).
- Built from the pinned manifest on the Linux builder; bundle `provenance` records the manifest, container digest, and APKRun revision (FR-IMG-05).
- Agents run as persistent, platform-signed priv-apps, and boot succeeds with `ro.control_privapp_permissions=enforce`. With developer mode off, `Hello` lists every capability up to number 21 (FR-RT-04).
- HelloProbe cannot reach agent sockets or use vsock, and the new domains log no `avc: denied` (R-13).
- ADB works on `127.0.0.1:6520` with developer mode on, and adbd stays off without it (FR-RT-05).
- The reference diff shows only documented changes, a `user` image boots, and the AVB state and signing are decided (OQ-36).

---

## #37 Store Agent

| Field | Value |
|---|---|
| Milestone | M5 (v0.3) |
| Depends on | #36 |
| Design | [package-store.md](../../02-design/package-store.md) §6.1–§6.4, §9; [guest-protocol.md](../../02-design/guest-protocol.md) §11 |
| Code | `Guest/APKRunStore/`; `Guest/agentruntime/`; `Guest/product/`; `Packages/APKStoreCore/` (`StoreAgentSupervisor`, reconciliation); `Tests/IntegrationTests/StoreTests/` |

**Goal.** The host installs, updates, and uninstalls apps, and reads their metadata, through the Store Agent over vsock, without `adb install`. `io.apkrun.store` is the installer of record on the custom image.

**Out of scope.** `RenderIcon` (#56). Update ownership, constraints, rollback, and the update transaction (#39 to #41, #44). Host import and preview (#28, #74).

**Steps.**
1. **Store Agent app.** `StoreAgentApplication` in `Guest/agentruntime/` serves `@apkrun-store-control` and `@apkrun-store-artifacts`, with `InstallService`, `ArchiveInspector`, `UninstallService`, `MetadataService`, and `PackageMonitor`. Implement operations 100–106 and events 100–102 ([guest-protocol.md](../../02-design/guest-protocol.md) §11). Answer `INVALID_ARGUMENT` for `allow_downgrade = true` and for `enable_rollback` outside `UPDATE` ([guest-protocol.md](../../02-design/guest-protocol.md) §11.3). Hash while writing, and check `expected_package`, `expected_version_code`, and `expected_signer_sha256` before `CommitInstall`. **Check:** T0 argument rules; T1 JVM tests for every operation.
2. **Product integration.** Add the Store Agent permissions to `privapp-permissions-apkrun.xml` ([guest-components.md](../../02-design/guest-components.md) §8.1), with `TEST_MANAGE_ROLLBACKS` allowlisted from this task. Complete `apkrun_store_app.te` from the #36 denials. **Check:** the store domain enforces; `apkrun_vsockd` reaches both sockets.
3. **Host channel.** `StoreAgentSupervisor` implements `StoreAgentChannel` over vsock ports 6110 and 6111 with `.install`, `.metadata`, and `.inspect` only ([package-store.md](../../02-design/package-store.md) §6.1). It streams artifacts and handles `InstallFinished` with the timeouts of [package-store.md](../../02-design/package-store.md) §6.2, §6.4. Cancel works up to `CommitInstall`. The custom image uses it; stock uses `ADBStoreAgentChannel`. **Check:** T2 `StoreAgentInstallTests`: install, update, uninstall, and metadata. Mismatch tests call `StoreAgentChannel` with a wrong `sha256` and a wrong `expected_signer_sha256`.
4. **Reconciliation.** Refresh metadata after each install. Reconciliation v1 ([package-store.md](../../02-design/package-store.md) §9.1–§9.2) runs `ListManagedPackages(ALL_USER_INSTALLED)` after each handshake and `GetPackageMetadata` on `PackageChanged`. A package removed inside Android moves to `broken(.removedInAndroid)`. **Check:** T2: the store matches Android's list after `PackageChanged`.
5. **Acceptance.** With ADB disabled, run `apkrun install HelloText.apk --yes`. **Check:** the Done-when items.

**Tests.**
- T0 (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`): argument rules, channel choice, reconciliation with a fake channel.
- T1 (`Guest/APKRunStore` JVM tests): every operation.
- T2 (`Tests/IntegrationTests/StoreTests/`, AndroidCustom): install without ADB, update, hash and signer mismatch, uninstall, metadata.
- T3: none.

**Done when.**
- `apkrun install HelloText.apk --yes` succeeds with ADB disabled, and the `adb` process counter stays at zero (FR-PKG-01).
- Install, update, uninstall, and metadata work over vsock, and metadata comes from `PackageManager` (FR-PKG-02).
- `io.apkrun.store` is the installer of record.
- A hash or signer mismatch is refused, and nothing is installed ([guest-protocol.md](../../02-design/guest-protocol.md) §11.3).
- After a handshake and after `PackageChanged`, the store matches Android's package list.

**Pitfalls.**
- Never install the development-signed agent on the custom image; agents come from the image build.
- OQ-34: if the Store Agent's memory is too large, start it on demand (`EnsureStoreAgent`).
