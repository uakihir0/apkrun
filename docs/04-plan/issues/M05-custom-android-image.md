# M5 Custom Android runtime image

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.3 |
| Related | [android-image.md](../../02-design/android-image.md), [guest-components.md](../../02-design/guest-components.md), [guest-protocol.md](../../02-design/guest-protocol.md), [package-store.md](../../02-design/package-store.md), [../../01-architecture/security-model.md](../../01-architecture/security-model.md), [../../05-development/environment-setup.md](../../05-development/environment-setup.md), [../../05-development/build-system.md](../../05-development/build-system.md), ADR-0008 [0008-guest-agents.md](../../01-architecture/decisions/0008-guest-agents.md), [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../open-questions.md](../open-questions.md), [../test-strategy.md](../test-strategy.md), [../traceability.md](../traceability.md) |

Each task below uses the entry format of [README.md](README.md) §2. Titles, dependencies, the milestone, and the gates follow the index in [README.md](README.md) §3.

## Milestone goal

APKRun gets its own Android image: the APKRun AOSP product, built reproducibly on a Linux builder from Cuttlefish's arm64 phone product. The Guest Agent runs in it as a persistent, platform-signed priv-app, `apkrun_vsockd` bridges vsock to the agents' local sockets, and SELinux confines all of it. The host talks to the agents over vsock with ADB off, and the Store Agent installs apps without `adb install`. From M5 on, this image is the one the product is tested on ([../roadmap.md](../roadmap.md) §3.3).

These design decisions hold for every task below:

- AOSP is never built on macOS. Every image build runs on the Linux x86-64 builder in the pinned container ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §5, [../../05-development/build-system.md](../../05-development/build-system.md) §9). Developers drive it from the Mac with `scripts/aosp/remote-build.sh`. The built `*-img-*.zip` goes through the same pipeline as the stock image, starting with inventory ([../../02-design/android-image.md](../../02-design/android-image.md) §3–§10).
- The product inherits Cuttlefish's `vsoc_arm64_only` phone product and changes only what §11.2 of [../../02-design/android-image.md](../../02-design/android-image.md) lists. It does not change the kernel, the partition layout, or fstab, so the stock image stays a valid development target (R-14). "Do not aggressively remove services" (#035): a HAL or service is disabled only with evidence from #095.
- The agents are Kotlin apps plus the Rust bridge `apkrun_vsockd`, not a native `guestd` (D-15, see [../traceability.md](../traceability.md) §3.2). Their identities are `io.apkrun.guest` and `io.apkrun.store` (D-01).
- The agents are identified by package name plus the platform signature (`seinfo=platform`). Only `apkrun_vsockd` (and adbd in developer mode) may use vsock, only `apkrun_vsockd` may connect to the agents' sockets, and the agents check `SO_PEERCRED` too ([../../01-architecture/security-model.md](../../01-architecture/security-model.md) §4). ADB is off unless the user turns developer mode on.
- SELinux rules are developed in permissive mode for the new domains only, and only in `userdebug` development builds. No `user` build contains a `permissive` statement, and CI checks that (R-13).

## Exit criteria

- [ ] #035 and #036 meet every acceptance criterion below, or a task is moved to a later milestone with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4 item 1).
- [ ] The custom `userdebug` image (`apkrun_arm64-trunk_staging-userdebug`) is built on the Linux builder from the pinned manifest, turned into a signed runtime image bundle, and is the image of the `AndroidCustom` suite. A `user` build of the same revision builds and boots, as the first release candidate.
- [ ] Tests ([../roadmap.md](../roadmap.md) §4 item 3): T0 and T1 pass on `main`, including the `apkrun_vsockd` tests. T2 passes on the reference Mac in the `AndroidCustom` suite (AndroidBootTests, GuestAgentTests, SecurityTests, StoreTests, and the M4 tests repeated on the custom image) and still passes in the `AndroidStock` suite. The G2–G6 checks pass again on the custom image ([../test-strategy.md](../test-strategy.md) §6.6).
- [ ] Performance ([../roadmap.md](../roadmap.md) §4 item 4): `apkrun-perf all` has run on the custom image on the reference Mac. The numbers are recorded, and any regression against the stock image numbers of M4 is explained. The `memory` scenario includes the Store Agent (OQ-34).
- [ ] Risks ([../roadmap.md](../roadmap.md) §4 item 5, [../risks.md](../risks.md)): R-13 has the #035 results (the final rules, the attribute and permission names, enforcing boot, the `user` build policy check), and R-14 has the builder and pin results. Their statuses are updated.
- [ ] Questions ([../roadmap.md](../roadmap.md) §4 item 6, [../open-questions.md](../open-questions.md)): OQ-36 (AVB state and signing of the release variant) is decided in #035. OQ-34 (Store Agent memory) is measured after #036.
- [ ] The verification log rows that name an M5 task are filled in: [../../02-design/android-image.md](../../02-design/android-image.md) §17, [../../02-design/guest-components.md](../../02-design/guest-components.md) §14, and [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18.
- [ ] The design documents describe what was built: [../../02-design/android-image.md](../../02-design/android-image.md) §11 and §13, [../../02-design/guest-components.md](../../02-design/guest-components.md) §4, §8, §10, [../../02-design/package-store.md](../../02-design/package-store.md) §6, and [../../05-development/build-system.md](../../05-development/build-system.md) §9.
- [ ] v0.3 is tagged only when M6 is also complete ([../roadmap.md](../roadmap.md) §3.3).

## Task order

1. #035 APKRun AOSP product (after #034).
2. #036 Store Agent (after #035).

There are no parallel tasks inside M5, because #036 needs the image of #035. M5 can start as soon as #034 is done, in parallel with the rest of M4, because the Linux builder is set up during M3 ([../roadmap.md](../roadmap.md) §1.3, [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §5). When #035 is done, #082 can start too, and so can #054, #081, and #085 once their other dependencies are done. When #036 is done, M6 (#037, #073) can start ([../roadmap.md](../roadmap.md) §1.4).

---

## #035 APKRun AOSP product

| Field | Value |
|---|---|
| Milestone | M5 (v0.3) |
| Depends on | #034 |
| Requirements | FR-IMG-05 |
| Design | [../../02-design/android-image.md](../../02-design/android-image.md) §6.2, §8.4, §10, §11, §13; [../../02-design/guest-components.md](../../02-design/guest-components.md) §4, §5, §10, §11 #035; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3, §13.3, §14, §15; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §4, §7; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §5; [../../05-development/build-system.md](../../05-development/build-system.md) §9 |
| Modules / paths | `Guest/product/` (`AndroidProducts.mk`, `apkrun_arm64.mk`, `Android.bp`, `init/apkrun.rc`, `sepolicy/`, `permissions/`, `overlay/`, `settings/`, `manifest/pinned.xml`); `Guest/vsockd/` (the crate and its `Android.bp`); `Guest/guestd/` (`GuestAgentApplication`, the privileged operations); `scripts/aosp/` (`builder.Dockerfile`, `build-product.sh`, `remote-build.sh`); `scripts/check-sepolicy.sh`; `Images/manifests/ar<n>/`; RuntimeCore (vsock as the production transport); `Tests/Fixtures/AndroidApps/` (HelloProbe); `Tests/IntegrationTests/AndroidBootTests/`, `GuestAgentTests/`, `SecurityTests/` |
| Risks / questions | R-13, R-14, OQ-36 |

### Goal

The APKRun AOSP product builds reproducibly on the Linux builder, and its image reaches `boot_completed` under the APKRun VM with the Guest Agent running as a platform-signed priv-app. The host reaches the agent over vsock with ADB disabled, and no other app can reach the agent's sockets.

### Scope

- The product tree `Guest/product/` of [../../02-design/android-image.md](../../02-design/android-image.md) §11.1, mapped into the AOSP tree as `device/apkrun/apkrun_arm64/` by `.repo/local_manifests/apkrun.xml`:
  - `AndroidProducts.mk` with the lunch choices `apkrun_arm64-trunk_staging-userdebug` and `apkrun_arm64-trunk_staging-user`.
  - `apkrun_arm64.mk`, which inherits `device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk`, sets `PRODUCT_NAME:= apkrun_arm64` (`PRODUCT_DEVICE` stays `vsoc_arm64_only`), adds `apkrun_vsockd ApkRunGuest ApkRunStore` to `PRODUCT_PACKAGES`, adds the product sepolicy directory, and sets the APKRun property `ro.apkrun.product=1` plus the GPU properties of the default profile. The image version comes from bootconfig at boot (`ro.boot.apkrun.image`, [../../02-design/android-image.md](../../02-design/android-image.md) §11.1), not from the build (#035: "APKRun properties", "graphics config").
  - `Android.bp` with `android_app_import` for both agent APKs (`certificate: "platform"`, `privileged: true`, `presigned: false`, installed in `/system_ext/priv-app/`) and `prebuilt_etc` for the permission and init files.
  - `init/apkrun.rc`, `sepolicy/`, `permissions/`, `overlay/`, `settings/`, and `manifest/pinned.xml`.
- The product changes of [../../02-design/android-image.md](../../02-design/android-image.md) §11.2: the agents, the bridge, the policy, and the allowlist; the in-guest KeyMint and Gatekeeper defaults; `virtio_snd` only if the stock kernel lacks it; `AUTO_TIME = 0` and `AUTO_TIME_ZONE = 0`; `Browser2` if the base has no browser; the multi-display and freeform overlays. No kernel, partition, or fstab change.
- The Guest Agent in privileged mode ([../../02-design/guest-components.md](../../02-design/guest-components.md) §4.1): `GuestAgentApplication` (persistent, `directBootAware`) starts the daemon in `AgentMode.PRIVILEGED_APP`, and enables the components that are off in development mode. The operations the shell-mode agent answered `UNSUPPORTED` work here: `SyncTime` (48, built in #069) with `SET_TIME` ([../../02-design/guest-components.md](../../02-design/guest-components.md) §5), and `AuthorizeAdbKey` (72, built here) with `AdbManager.allowDebugging` and `MANAGE_DEBUGGING`, which `user` builds need because of `ro.adb.secure=1`.
- `apkrun_vsockd` as a product module ([../../02-design/guest-components.md](../../02-design/guest-components.md) §10): the static port table 6100, 6101, 6102 → `apkrun-guestd-*` and 6110, 6111 → `apkrun-store-*`, peer CID 2 only, 8 connections per port, a 64 KiB copy buffer, no parsing or logging of payloads.
- The SELinux policy, the privileged-permission allowlist, and the settings overlay (R-13, detailed in the steps).
- Developer mode on the custom image ([../../02-design/android-image.md](../../02-design/android-image.md) §11.3): `androidboot.apkrun.devmode=1`, set by the host before each Android start, makes `init/apkrun.rc` start adbd on vsock 5555, which the host bridges to `127.0.0.1:6520` (#035: "development ADB"). With `devmode=0`, adbd does not run. `user` builds set `ro.adb.secure=1`.
- vsock as the production transport in RuntimeCore on the custom image. ADB forwards stay for the stock image and `--guest-transport adb`.
- The build scripts of [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §5 and [../../05-development/build-system.md](../../05-development/build-system.md) §9, the first image through the bundle pipeline with `kind: apkrun`, and the release-variant decision (OQ-36).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - The Store Agent's services and the host `StoreAgentSupervisor` (#036). #035 ships `ApkRunStore` only as a package that starts, with its domain and allowlist entries.
  - The M9 components (notification listener, URL handler, documents provider) beyond being present and enabled in privileged mode (#054, #081, #082).
  - Image updates, the image feed, and migration (#058, #087).
  - Removing services or HALs without #095 evidence, and any kernel, partition, or fstab change.

### Deliverables

- `Guest/product/` with every file of [../../02-design/android-image.md](../../02-design/android-image.md) §11.1, and `Guest/vsockd/Android.bp` with `rust_binary { name: "apkrun_vsockd", srcs: ["src/main.rs"], rustlibs: [...] }`.
- `init/apkrun.rc` with the `apkrun_vsockd` service and the developer-mode trigger, and a `userdebug`-only test init file for the test bundle triggers (see step 5).
- `sepolicy/`: `apkrun_vsockd.te`, `apkrun_guest_app.te`, `apkrun_store_app.te`, `file_contexts`, `seapp_contexts`.
- `permissions/privapp-permissions-apkrun.xml`, the default-permission and feature files, and the `SettingsProvider` and framework overlays.
- `scripts/aosp/builder.Dockerfile`, `scripts/aosp/build-product.sh`, `scripts/aosp/remote-build.sh`, and `scripts/check-sepolicy.sh`, with the container digest recorded.
- The first custom image: `apkrun_arm64-img-ar<n>.zip`, its `build-info.json`, the committed `Images/manifests/ar<n>/inventory.json` and `android-image.json` (`kind: apkrun`, with the required agents and the guest protocol range in `requirements`), and a signed runtime image bundle.
- `GuestAgentApplication` and `AuthorizeAdbKey` in `Guest/guestd/`, and `SyncTime` enabled in privileged mode.
- The fixture HelloProbe (`io.apkrun.fixture.helloprobe`, logs `probe <target> <result>`).
- Test bundles A, B, B′, F, P, and S rebuilt from the custom `userdebug` image ([../test-strategy.md](../test-strategy.md) §3.5).
- T0 and T1 tests for `apkrun_vsockd`, and T2 tests `CustomImageBootTests` (AndroidBootTests), `VsockAgentTests` (GuestAgentTests), and `AgentSocketIsolationTests`, `DeveloperModeAdbTests`, and `SelinuxDenialTests` (SecurityTests).

### Implementation steps

1. **Builder and product skeleton** ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §5; [../../05-development/build-system.md](../../05-development/build-system.md) §9; [../../02-design/android-image.md](../../02-design/android-image.md) §11.1).
   - Build the container from `scripts/aosp/builder.Dockerfile` (`ubuntu:22.04`) and record its digest. Check out AOSP with `repo init -b aosp-android-latest-release --partial-clone` and the pinned manifest `Guest/product/manifest/pinned.xml`.
   - Add `scripts/aosp/build-product.sh --revision <commit> --variant userdebug|user`. It writes `.repo/local_manifests/apkrun.xml` (this repository at `<commit>`, `Guest/product/` mapped to `device/apkrun/apkrun_arm64/`), runs `scripts/build-guest.sh` and copies the APKs to `Guest/product/prebuilt/`, then runs `lunch`, `m`, and `m dist DIST_DIR=out/dist` with `BUILD_NUMBER=ar<counter>`, and writes `build-info.json`.
   - Add `scripts/aosp/remote-build.sh`: it checks that the revision exists on `origin`, builds on the builder, copies the zip and `build-info.json` to `Images/work/ar<n>/download/`, and prints the next commands.
   - Add `AndroidProducts.mk` and `apkrun_arm64.mk` with only the inheritance and the properties first.
   - Check: a `userdebug` build with no APKRun modules produces `apkrun_arm64-img-ar<n>.zip`, and Kati and Soong see each product file exactly once (if the `repo` mapping does not work, the script copies the tree instead, as [../../05-development/build-system.md](../../05-development/build-system.md) §9 allows).
2. **Agents as platform-signed priv-apps** ([../../02-design/guest-components.md](../../02-design/guest-components.md) §2, §4.1, §4.3, §4.4, §11 #035 step 1).
   - Add `GuestAgentApplication` with `AgentMode.PRIVILEGED_APP`. It binds the same abstract socket names as development mode, and enables the privileged-only components.
   - Import both APKs in `Android.bp` with `android_app_import { certificate: "platform", privileged: true, presigned: false }`, so the build re-signs them with the image's platform key: the AOSP test platform key in `userdebug` builds, the offline APKRun platform key in `user` builds ([../../01-architecture/security-model.md](../../01-architecture/security-model.md) §7).
   - Write `permissions/privapp-permissions-apkrun.xml` with every privileged permission the two agents request ([../../02-design/guest-components.md](../../02-design/guest-components.md) §5, §8.1). Signature permissions are not listed. Cuttlefish enforces the list (`ro.control_privapp_permissions=enforce`), so a missing entry stops the boot.
   - Add the `SettingsProvider` overlay (`def_stay_on_while_plugged_in`, `def_screen_off_timeout`, `def_lockscreen_disabled`, `def_device_provisioned`, `def_user_setup_complete`) and `config_default_input_method` for the APKRun IME. The agent still re-applies them at start.
   - Apply the other product changes of [../../02-design/android-image.md](../../02-design/android-image.md) §11.2: `AUTO_TIME = 0` and `AUTO_TIME_ZONE = 0`, the in-guest KeyMint and Gatekeeper APEX defaults, `virtio_snd` only if the stock kernel modules lack it, `Browser2` only if the base product has no browser, and the multi-display and freeform settings and overlays (`enable_freeform_support`, `force_resizable_activities`).
   - Implement `AuthorizeAdbKey` in privileged mode, and let `SyncTime` apply the time in privileged mode instead of answering `UNSUPPORTED`. The M4 tests that needed the privileged agent (the time sync of #069, the clipboard of #053) run again in the `AndroidCustom` suite.
   - Check: the image boots, `pm list packages -f` shows both agents under `/system_ext/priv-app/`, `dumpsys package io.apkrun.guest` shows the platform signature and every privileged permission granted, and the agent restarts by itself after it is killed (`persistent`).
3. **`apkrun_vsockd` and its init service** ([../../02-design/guest-components.md](../../02-design/guest-components.md) §10, §11 #035 step 2).
   - Add `Guest/vsockd/Android.bp` with the `rust_binary`, and add `apkrun_vsockd` to `PRODUCT_PACKAGES`.
   - Add the service to `init/apkrun.rc`:

     ```text
     service apkrun_vsockd /system_ext/bin/apkrun_vsockd
     class main
     user system
     group system
     capabilities
     restart_period 1
     ```

   - Label the binary in `file_contexts` (`/system_ext/bin/apkrun_vsockd u:object_r:apkrun_vsockd_exec:s0`).
   - Check: T0 (`cargo test`) for the port table and the connection limits. T1 with `vsock_loopback` on the test Linux guest: a ninth connection to a port is closed, and a connection from a peer CID other than 2 is refused.
4. **SELinux policy** ([../../02-design/guest-components.md](../../02-design/guest-components.md) §4.2, §10.2, §11 #035 step 3; R-13).
   - Add `seapp_contexts`, so the agents run in their own domains only when they are privileged and platform-signed:

     ```text
     user=_app isPrivApp=true seinfo=platform name=io.apkrun.guest domain=apkrun_guest_app type=app_data_file levelFrom=all
     user=_app isPrivApp=true seinfo=platform name=io.apkrun.store domain=apkrun_store_app type=app_data_file levelFrom=all
     ```

   - Add `apkrun_vsockd.te`: its own domain through `init_daemon_domain`, the vsock exemption through `typeattribute apkrun_vsockd unconstrained_vsock_violators`, `vsock_socket` permissions on itself, and `connectto` on the two agent domains' `unix_stream_socket`. Add `apkrun_guest_app.te` (`app_domain`, `service_manager find` for the system services of [../../02-design/guest-components.md](../../02-design/guest-components.md) §5, and `allow apkrun_vsockd apkrun_guest_app:unix_stream_socket connectto;`) and `apkrun_store_app.te` (`package_service`, `storagestats_service`, and the installer services). No other domain gets `connectto` on the agents, and no other new domain gets vsock.
   - In `userdebug` builds, mark only the three new domains `permissive`. Boot, run the `AndroidCustom` suite, collect the `avc: denied` lines of the three domains, turn them into rules, confirm the attribute and permission-set names against the tree's `system/sepolicy`, then remove the `permissive` statements and boot again with the domains enforcing.
   - The policy goes in through `BOARD_SEPOLICY_DIRS` as in [../../02-design/android-image.md](../../02-design/android-image.md) §11.1. If the Treble `neverallow` checks reject types for `/system_ext` files in that directory, move them to `SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS`, and update §11.1.
   - Add `scripts/check-sepolicy.sh`: it fails when a `user` build's policy contains `permissive`. `build-product.sh` runs it before `m` for `user` builds, and CI runs it on every change under `Guest/product/sepolicy/`.
   - Check: T2 `SelinuxDenialTests`: with the domains enforcing, no `avc: denied` line for `apkrun_vsockd`, `apkrun_guest_app`, or `apkrun_store_app` appears during the `AndroidCustom` suite. `scripts/check-sepolicy.sh` fails on a test policy with `permissive` and passes on the real one.
5. **Developer mode and test triggers** ([../../02-design/android-image.md](../../02-design/android-image.md) §6.2, §11.3; [../test-strategy.md](../test-strategy.md) §3.3, §3.5).
   - In `init/apkrun.rc`, start adbd listening on vsock 5555 only when `ro.boot.apkrun.devmode` is `1`. The base product always runs adbd on `vsock:5555` and `tcp:5555` (`persist.adb.tcp.port=5555`, [../../02-design/android-image.md](../../02-design/android-image.md) §7.3), so the product overrides that, and adbd stays stopped with `devmode=0`. The exact override (the property and the init trigger that start adbd in the base) is found in this step and recorded in [../../02-design/android-image.md](../../02-design/android-image.md) §11.3.
   - The privileged agent reports the adbd state in `Health.adb_enabled` ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.4), which the doctor check `agent.developerMode` uses later (#059). Its `SO_PEERCRED` check accepts uid `system` or `root` (the bridge), and uid `shell` (the ADB forward) only with `devmode=1` ([../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §3.1).
   - Put the handlers for the `androidboot.apkrun.test.*` keys (the `marker`, `fail_boot`, and `fail_health` triggers and the secret script of bundle S) in a separate init file that only `userdebug` builds install. The release manifest check of [../test-strategy.md](../test-strategy.md) §3.3 stays in force.
   - Check: T2 `DeveloperModeAdbTests`: with `devmode=1`, `adb -s 127.0.0.1:6520 shell` works and `Health.adb_enabled` is true; with `devmode=0`, no adbd process runs, nothing listens on vsock 5555 or tcp 5555, `Health.adb_enabled` is false, and a connection to an agent socket from uid `shell` is refused. A `user` build has no test trigger file.
6. **Image bundle and vsock transport** ([../../02-design/android-image.md](../../02-design/android-image.md) §10, §11.5; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §13.3).
   - Build the `userdebug` image with `remote-build.sh`, run `scripts/inventory-cuttlefish.py`, and bundle it with `python3 -m apkrun_image bundle` (`kind: apkrun`, `requirements` with the agents' package names and version codes and the guest protocol range). Commit `Images/manifests/ar<n>/`.
   - Make vsock the production transport for the custom image in RuntimeCore. If #034 deferred the vsock validation, run it here.
   - Rebuild test bundles A, B, B′, F, P, and S from this image.
   - Check: T2 `VsockAgentTests`: with developer mode off, the Guest Agent's handshake works over vsock, and `Hello` lists every capability of [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1 up to #21.
7. **Release variant** ([../../02-design/android-image.md](../../02-design/android-image.md) §11.4; OQ-36).
   - Decide the AVB state and the signing flow of the `user` variant. Working default (the §11.4 proposal): pass `orange`/`unlocked`, keep dm-verity on through the vbmeta hashtree descriptors, and sign the target files with the offline APKRun release keys on the builder only.
   - Implement the signing in `build-product.sh` (step 5 of [../../05-development/build-system.md](../../05-development/build-system.md) §9), and build and boot a `user` image.
   - Check: the `user` image boots to `boot_completed` with the domains enforcing, `ro.adb.secure=1`, and no `permissive` in its policy.
8. **Acceptance** ([../../02-design/android-image.md](../../02-design/android-image.md) §8.4, §11.5; [../../02-design/guest-components.md](../../02-design/guest-components.md) §11 #035 step 4).
   - Boot the custom image under APKRun, run the reference diff of [../../02-design/android-image.md](../../02-design/android-image.md) §8.4 against the stock reference capture (`Images/reference/16373615/target`), and list every product change of §11.2 with its reason in `expected-differences.yaml` (§8.4).
   - Run the `AndroidCustom` suite, HelloProbe, and the G2–G6 checks on the custom image.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.6):

- **T0** (`Guest/vsockd`, `cargo test`): the port table and the connection limits.
- **T1** (`Guest/vsockd`, on the test Linux guest with `vsock_loopback`): the bridge splices both directions, closes the ninth connection, and refuses peers other than CID 2.
- **T2** (`Tests/IntegrationTests/AndroidBootTests/`, `GuestAgentTests/`, `SecurityTests/`, AndroidCustom suite, custom `userdebug` image):
  - `boot_completed` under APKRun, and the agents start; the persistent agent restarts after it is killed.
  - HelloProbe cannot connect to `@apkrun-guestd-control` or any other agent socket, and cannot create an `AF_VSOCK` socket (`probe <target> denied` for each).
  - No agent or bridge denials in enforcing mode during the suite.
  - `SystemServicesTest` (every `SystemServices` wrapper resolves on the custom image).
  - adbd listens on vsock 5555 only with developer mode.
  - The Guest Agent handshake over vsock with ADB off, with every capability up to #21 in `Hello`.
- **T3**: the G2–G6 checks on the custom image; the `user` release-candidate boot.

### Acceptance criteria

- [ ] The custom image reaches `boot_completed` under the APKRun VM (#035, FR-IMG-05).
- [ ] The product inherits the Cuttlefish arm64 phone product and includes the Guest Agent, the bridge, the graphics configuration, development ADB, and the APKRun properties, with no service removed without #095 evidence (#035).
- [ ] The image is built on the Linux builder with `scripts/aosp/remote-build.sh` from the pinned manifest, and its bundle's `provenance` records the pinned manifest, the container digest, and the APKRun revision (FR-IMG-05).
- [ ] The Guest Agent and the Store Agent start as persistent, platform-signed priv-apps in `apkrun_guest_app` and `apkrun_store_app`, and the boot succeeds with `ro.control_privapp_permissions=enforce`.
- [ ] With developer mode off, the host reaches the Guest Agent over vsock, and `Hello` lists every capability of [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1 up to #21.
- [ ] An app in the `untrusted_app` domain (HelloProbe) cannot connect to `@apkrun-guestd-control` or the other agent sockets, and cannot use vsock (R-13).
- [ ] With the three new domains enforcing, the `AndroidCustom` suite causes no `avc: denied` for them, and `scripts/check-sepolicy.sh` passes for the `user` build (R-13).
- [ ] With developer mode on, ADB works through `127.0.0.1:6520` (FR-RT-05). With it off, adbd does not run and the agents refuse uid `shell` ([../../01-architecture/security-model.md](../../01-architecture/security-model.md) §4).
- [ ] The reference diff against the stock reference capture shows no unexplained differences beyond the documented product changes ([../../02-design/android-image.md](../../02-design/android-image.md) §11.5).
- [ ] The release variant's AVB state and signing flow are decided and recorded, and a `user` image boots (OQ-36).

### Notes

- Record in [../../02-design/android-image.md](../../02-design/android-image.md) §17 (the AVB state and the SELinux denials), [../../02-design/guest-components.md](../../02-design/guest-components.md) §14 (the final rules, the attribute and permission names, enforcing boot, the allowlist, vsock with ADB off, HelloProbe), and [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18 (the vsock handshake with no ADB, HelloProbe). Update R-13, R-14, and OQ-36.
- **R-13 fallback.** If a rule the agents need cannot be written without a `neverallow` violation, move that function into a system service of the product, or keep it in the platform-signed priv-app path ([../risks.md](../risks.md) R-13). Record the choice in [../../02-design/guest-components.md](../../02-design/guest-components.md) §13.
- **R-14.** A new AOSP release drop is a pin move in its own pull request, never a silent `repo sync`. The stock image stays usable for development until the custom image passes the same pipeline.
- The agents on the custom image are platform-signed by the image build. The host never installs the development-signed agent (`test-guest-dev.jks`) there: `installingAgents` of #066 applies to the stock image only, and agent updates on the custom image come with image updates (#058).
- Add a row to [../../02-design/android-image.md](../../02-design/android-image.md) §13 for each product change that alters Cuttlefish behavior (at least: adbd only in developer mode, and the time settings).
- Test bundles F and S need the product's init files, so they exist only on the custom image. Bundle P works on both images.

---

## #036 Store Agent

| Field | Value |
|---|---|
| Milestone | M5 (v0.3) |
| Depends on | #035 |
| Requirements | FR-PKG-01, FR-PKG-02 |
| Design | [../../02-design/package-store.md](../../02-design/package-store.md) §6, §9, §15 #036; [../../02-design/guest-components.md](../../02-design/guest-components.md) §8, §11 #036; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3, §11, §15; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §4 |
| Modules / paths | `Guest/APKRunStore/` (`StoreAgentApplication`, `InstallService`, `ArchiveInspector`, `UninstallService`, `MetadataService`, `PackageMonitor`); `Guest/agentruntime/`; `Guest/product/` (priv-app, allowlist, domain); APKStoreCore (`StoreAgentSupervisor`, `StoreAgentChannel` over vsock, reconciliation); RuntimeCore (readiness with the Store Agent); `Tests/IntegrationTests/StoreTests/` |
| Risks / questions | OQ-34 |

### Goal

The host installs, updates, and uninstalls apps and reads their metadata through the Store Agent over vsock, without `adb install`. `io.apkrun.store` is the installer of record of every app APKRun installs on the custom image.

### Scope

- The Store Agent `io.apkrun.store` ([../../02-design/guest-components.md](../../02-design/guest-components.md) §8): persistent, `directBootAware`, privileged, platform-signed, in the domain `apkrun_store_app`, with the permissions of §8.1 in the allowlist. It never shows UI.
- Its internals for M5 (§8.2): the two sockets `@apkrun-store-control` and `@apkrun-store-artifacts`, `InstallService`, `ArchiveInspector`, `UninstallService`, `MetadataService`, and `PackageMonitor`.
- Store operations 100–106 of [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §11 (`InspectArchive`, `BeginInstall`, `CommitInstall`, `AbandonInstall`, `Uninstall`, `GetPackageMetadata`, `ListManagedPackages`), the events 100–102 (`InstallProgress`, `InstallFinished`, `PackageChanged`), and the artifact stream (port 6111), behind `store.install.v1` and `store.metadata.v1`.
- The Store Agent operations are install, update, uninstall, and metadata. "Update" here is `BeginInstall` with `mode = UPDATE` for a newer version of an installed package, through the same session flow. The host's update transaction and policy are M6 (#038).
- Host side ([../../02-design/package-store.md](../../02-design/package-store.md) §6): `StoreAgentSupervisor` implements `StoreAgentChannel` over vsock (ports 6110 and 6111) with the handshake, the capabilities, artifact streaming with progress, and `InstallFinished` handling; the timeouts of §6.2 (`BeginInstall` 30 s, a 30 s stall, `InstallFinished` 10 minutes, `GetPackageMetadata` 10 s); cancel until step 3c.
- The `GetPackageMetadata` refresh after an install, and reconciliation v1 (§9.1–§9.2): `ListManagedPackages(ALL_USER_INSTALLED)` after each Store Agent handshake, and `GetPackageMetadata` on `PackageChanged`.
- The channel is chosen from the image: the custom image uses the Store Agent, and the stock image (or `--guest-transport adb`) uses `ADBStoreAgentChannel`.
- The Store Agent as a required agent for readiness on the custom image ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §3.4).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - `RenderIcon` and `IconRenderer` (#055). Until then the host preview icon is used.
  - Update ownership (#039), install constraints (#040), rollback (#043), and the update transaction (#038).
  - The host package import, the preview, and validation (#027, #073).

### Deliverables

- `Guest/APKRunStore/` with the M5 services, built by `scripts/build-guest.sh` into `apkrun-store.apk`, and its product integration (priv-app, allowlist entries, `apkrun_store_app` rules).
- `StoreAgentSupervisor` and the vsock `StoreAgentChannel` in APKStoreCore, the channel choice, and reconciliation v1.
- T0 tests for the Store Agent argument rules, T1 JVM tests for the services, and T2 `StoreAgentInstallTests` in `Tests/IntegrationTests/StoreTests/`.

### Implementation steps

1. **Store Agent app** ([../../02-design/guest-components.md](../../02-design/guest-components.md) §8, §11 #036 step 1; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §11).
   - Build `StoreAgentApplication` on `Guest/agentruntime/` with the two sockets and `InstallService`, `ArchiveInspector`, `UninstallService`, `MetadataService`, and `PackageMonitor`.
   - Install sessions use the `SessionParams` of §8.2 (`MODE_FULL_INSTALL`, `setAppPackageName`, `INSTALL_REASON_USER`, `PACKAGE_SOURCE_OTHER`, `USER_ACTION_NOT_REQUIRED`).
   - `InstallMode` `INSTALL_NEW` is a first install and `UPDATE` an update ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §11.3). The agent answers `INVALID_ARGUMENT` for `allow_downgrade = true`, for `enable_rollback` with a mode other than `UPDATE`, and for `request_update_ownership` or `enable_rollback` while their capabilities (#039, #043) do not exist.
   - The agent hashes each artifact as it writes it into the session (`BulkAck{HASH_MISMATCH}` on a mismatch), and before `CommitInstall` it checks the staged package against `expected_package`, `expected_version_code`, and `expected_signer_sha256` (`InstallFinished{INVALID}` on a mismatch).
   - Check: T0 tests for the argument rules ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §16). T1 JVM tests for every operation against a scripted host.
2. **Product integration** ([../../02-design/guest-components.md](../../02-design/guest-components.md) §4.2, §4.3, §11 #036 step 2).
   - Add the Store Agent's privileged permissions to `privapp-permissions-apkrun.xml`, and complete `apkrun_store_app.te` from the permissive-mode denials, as in #035 step 4.
   - Check: the image boots with the store domain enforcing, and `apkrun_vsockd` reaches both store sockets.
3. **Host channel** ([../../02-design/package-store.md](../../02-design/package-store.md) §6, §15 #036 step 1; [../../02-design/guest-components.md](../../02-design/guest-components.md) §11 #036 step 3).
   - Implement `StoreAgentSupervisor` as the vsock `StoreAgentChannel` with the capabilities `.install`, `.metadata`, and `.inspect`, the streaming flow of §6.2, the timeouts, and cancel.
   - Choose the channel from the image, and keep `ADBStoreAgentChannel` for the stock image and `--guest-transport adb`.
   - Check: T2 `StoreAgentInstallTests`: install, update to a newer version, uninstall, and metadata. For the hash and signer mismatches the test drives `StoreAgentChannel` directly with a wrong `sha256` and a wrong `expected_signer_sha256`, so the refusal comes from the guest and nothing is installed.
4. **Metadata and reconciliation** ([../../02-design/package-store.md](../../02-design/package-store.md) §9, §15 #036 steps 2–4).
   - Refresh `GetPackageMetadata` after each install. Run reconciliation v1 after each handshake and on `PackageChanged`.
   - Check: T2: a package removed inside Android (same userdata generation) moves to `broken(.removedInAndroid)` after the next `PackageChanged` ([../../02-design/package-store.md](../../02-design/package-store.md) §9.2).
5. **Acceptance** ([../../02-design/package-store.md](../../02-design/package-store.md) §15 #036 step 5).
   - On the custom image with ADB disabled, run `apkrun install HelloText.apk --yes` and `apkrun info io.apkrun.fixture.hellotext`.
   - Check: the acceptance criteria below.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.6):

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Guest/APKRunStore` unit tests): the Store Agent argument rules; the channel choice; the reconciliation rules with a fake channel.
- **T1** (`Guest/APKRunStore` JVM tests): every store operation against a scripted host.
- **T2** (`Tests/IntegrationTests/StoreTests/`, AndroidCustom suite, custom `userdebug` image): install without ADB; update; hash mismatch and signer mismatch; uninstall; metadata.
- **T3**: none. OQ-34 is measured with `apkrun-perf memory` after this task.

### Acceptance criteria

- [ ] The host installs HelloText through the Store Agent without `adb install`: with ADB disabled in the image, `apkrun install HelloText.apk --yes` succeeds, and the `adb` process counter stays at zero (#036, FR-PKG-01).
- [ ] Install, update, uninstall, and metadata work through the Store Agent over vsock, and the metadata comes from Android's `PackageManager` (#036, FR-PKG-02).
- [ ] `apkrun info io.apkrun.fixture.hellotext` and `GetPackageMetadata` report `io.apkrun.store` as the installer of record (#036, D-01).
- [ ] A hash mismatch and a signer mismatch are refused by the Store Agent, and nothing is installed ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §11.3).
- [ ] After a Store Agent handshake and after `PackageChanged`, the package store matches Android's package list (reconciliation v1, [../../02-design/package-store.md](../../02-design/package-store.md) §9).

### Notes

- Record in [../../02-design/guest-components.md](../../02-design/guest-components.md) §14 and [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18: the install through the Store Agent without `adb install`, and the installer of record.
- OQ-34: the Store Agent is persistent. Measure its steady memory with the `memory` scenario of #070 once this task is done, and record it against NFR-RES-04 in [../../02-design/guest-components.md](../../02-design/guest-components.md) §14. If it is too large, the fallback is to start it on demand (`EnsureStoreAgent`).
- `TEST_MANAGE_ROLLBACKS` is in the allowlist from this task on, because the platform-signed Store Agent requests it ([../../02-design/guest-components.md](../../02-design/guest-components.md) §8.1). It is used from #043.
