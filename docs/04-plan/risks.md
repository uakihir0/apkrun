# Risk Register

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [open-questions.md](open-questions.md), [roadmap.md](roadmap.md), [issues/README.md](issues/README.md), [test-strategy.md](test-strategy.md), [../01-architecture/decisions/README.md](../01-architecture/decisions/README.md) |

A risk is something that could make a planned design fail or cost much more than planned. Each risk names the task that settles it and the fallback if it goes badly. An open question that is only a choice, with no risk of failure, is in [open-questions.md](open-questions.md) instead.

---

## 1. How the register is used

- **IDs are permanent.** A closed risk keeps its ID. New risks take the next free number (R-26 and up).
- **Status:** `open` (not yet checked), `watching` (checked once, could return, for example on a new macOS build), `closed` (settled; the result is recorded), `realized` (it happened and the fallback is in use).
- **Impact** is what happens if the risk is realized and the fallback is needed: **High** blocks a version's Definition of Done or a gate, **Medium** degrades a feature or costs weeks, **Low** is local.
- **Likelihood** is our estimate before the settling task runs: High, Medium, or Low.
- The settling task records the result in the "Result" line of the risk (§3), in the design document's verification log, and, if the design changes, in an ADR. The pull request that closes the task updates this file.
- Risks are reviewed at every milestone exit ([roadmap.md](roadmap.md) §4). Any risk still `open` whose settling task is in the finished milestone blocks the exit. When a risk has settling tasks in several milestones, each earlier milestone exit records the partial result in the Result line, and only the milestone that holds the last settling task must close it (or mark it `watching` or `realized`).

---

## 2. Summary

| ID | Risk | Impact | Likelihood | Settled by | Status |
|---|---|---|---|---|---|
| R-01 | Limits of the macOS 27 custom virtio device API | High | Medium | #063, #019, #028 | open |
| R-02 | virglrenderer / ANGLE correctness for Android's GLES use | High | Medium | #020, #022, #023 | open |
| R-03 | Graphics performance with one renderer thread | Medium | Medium | #023, #030, #068, #070 | open |
| R-04 | Multi-display: scanout hotplug, mode changes, apps on secondary displays | High | Medium | #028, #029, #067, #030 | open |
| R-05 | Input injection and IME on secondary displays | High | Low | #024, #030, #071 | open |
| R-06 | The stock Cuttlefish image does not boot on the VZ topology | High | Medium | #012–#014, #064 | open |
| R-07 | No VM save/restore while VirGL is active | Medium | High (known) | accepted; #070 measures cold start | watching |
| R-08 | Memory footprint of the guest and the renderer | Medium | Medium | #028, #070 | open |
| R-09 | No Google Mobile Services: apps that need them do not work | Medium | High (known) | accepted; #090 labels apps | watching |
| R-10 | Licensing of redistributed images and libraries | High | Low | #093 | open |
| R-11 | Direct kernel boot is not enough (AVB, slots, boot devices) | High | Low | #012–#014 | open |
| R-12 | Cuttlefish host-service dependencies (hvc HALs, input, network naming) | High | Medium | #095, #014 | open |
| R-13 | SELinux policy for the vsock bridge and the privileged agents | Medium | Medium | #035 | open |
| R-14 | AOSP build infrastructure and upstream branch changes | Medium | Medium | #035 | open |
| R-15 | Android install floors reject older apps (targetSdk, signature, alignment) | Low | High (known) | #041, #073, #090 | watching |
| R-16 | Virtualization.framework changes on new macOS builds | High | Low | T2 suite on every new macOS build | watching |
| R-17 | Gatekeeper and App Management policy for generated wrappers | High | Low | #046, #047, #076, #088 | open |
| R-18 | Hidden or privileged Android APIs used by the guest agents change or are refused | Medium | Medium | #072, #034, #039, #043 | open |
| R-19 | Background mode without a Dock tile flash; notification permission across wrapper refreshes | Medium | Medium | #054, #076 | open |
| R-20 | Dock pins and App Management with the `Contents` swap | Medium | Medium | #076 | open |
| R-21 | Pasteboard read prompts on macOS 27 for the focus push | Medium | Medium | #053 | open |
| R-22 | Privacy prompts and their attribution when apkrund reads user folders | Medium | Medium | #082 | open |
| R-23 | Sparkle details differ from the design | Low | Low | #057 step 1 | open |
| R-24 | launchd does not run the new apkrund from a replaced bundle | Medium | Low | #057 (T2) | open |
| R-25 | Image extraction writes the zero runs of `os.img` before holes are punched | Low | High | #087 | open |

---

## 3. Risks

### R-01 Limits of the macOS 27 custom virtio device API

- **Risk.** The API exists (macOS 27 SDK, WWDC26 session 224) but has limits that shape the devices APKRun can build: there is no callback for guest writes to config space and no call to raise an interrupt; queues are valid only after `DRIVER_OK`; guest memory mappings are invalid after a reboot; the maximum number of shared-memory regions (`maximumAllowedSharedMemoryRegionCount`) is undocumented; and it is not verified that `updateDeviceSpecificConfiguration` raises a config-change interrupt in the guest.
- **Consequences already designed in.** No host virtio-input device; input goes through guest injection ([ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md)). The virtio-gpu `events_clear` write is not observable, so the device uses the display-generation workaround ([../02-design/graphics.md](../02-design/graphics.md) §4.3). No blob resources or host-visible shared memory in v1.
- **Open part.** Scanout hotplug through a config-change interrupt.
- **Fallbacks** ([../02-design/graphics.md](../02-design/graphics.md) §4.3): A. the Guest Agent forces a DRM connector re-probe (custom image); B. all pool scanouts enabled at boot with a placeholder mode; C. a fixed display count per boot (a product regression, then also recorded under R-04).
- **Settled by.** #063 (the test device exercises queues, config updates, and resets), #019 (hotplug spike with the Linux test guest), #028 (the same with Android).
- **Result.** Not yet run.

### R-02 virglrenderer / ANGLE correctness

- **Risk.** Android's GLES 3.0 through Mesa virgl, translated by virglrenderer and ANGLE to Metal, renders incorrectly or crashes for common apps: MSAA (RiftVM needs a patch), texture formats, `EGL_METAL_TEXTURE_ANGLE` scanout import, WebView and Skia paths.
- **Mitigation.** Pinned revisions and patches in `ThirdParty/ThirdParty.lock.json` ([../02-design/graphics.md](../02-design/graphics.md) §5); HelloGL, HelloCompose, and HelloWebView fixtures; the renderer runs isolated so that a crash is reported, not hidden.
- **Fallback.** The `guestSwiftshader` GPU profile ([../02-design/graphics.md](../02-design/graphics.md) §9), turned on by Graphics Safe Mode (`graphics.safeMode`, [../03-reference/configuration.md](../03-reference/configuration.md)), with a warning. The profile is chosen at boot, so it applies to the whole VM, never to one app. Upstream fixes are carried as patches.
- **Settled by.** #020 (build and host tests), #022 (Android VirGL), #023 (gate G3), then the compatibility runs of #090.
- **Result.** Not yet run.

### R-03 Graphics performance

- **Risk.** One renderer thread (the RiftVM model: one frame in flight plus one pending) cannot serve several displays at 60 fps, or the present cost exceeds the budget (present < 2 ms p95, NFR-PERF-*).
- **Mitigation.** No CPU readback on the normal path (FR-GFX-05), IOSurface pools shared with the wrapper ([ADR-0006](../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)), frame statistics and readback counters ([../02-design/graphics.md](../02-design/graphics.md) §7), the perf harness ([../02-design/diagnostics.md](../02-design/diagnostics.md) §9).
- **Fallback.** Lower the frame rate of background windows; one renderer context thread per display if virglrenderer allows it; revise the provisional targets with an ADR ([../00-product/requirements.md](../00-product/requirements.md) §2).
- **Settled by.** #023 (one display), #030 (two displays, embedded runtime), #068 and #070 (through the XPC path in apkrund, measured by the perf harness).
- **Result.** RiftVM reports about 60 fps and 0.4–0.8 ms per present for one display (research); not yet measured in APKRun.

### R-04 Multi-display

- **Risk.** virtio-gpu multi-scanout with the ranchu HWC does not behave as designed: scanouts cannot be added at runtime (see R-01), a mode change is reported as disconnect + connect and changes the Android display ID, or apps misbehave on secondary displays.
- **Mitigation.** `DisplayPool` owns all allocation ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3); EDID-derived stable display IDs; `primaryDisplayCompatibility` window mode for apps that fail on secondary displays (FR-DSP-06).
- **Fallback.** Fixed pool size per boot (R-01 fallback C); for resize, fallback A or B in [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.1 (move the task to a new display, or fixed window size).
- **Settled by.** #028 (hotplug), #067 (mode change keeps the display ID), #029, #030 (gate G5).
- **Result.** Not yet run.

### R-05 Input and IME on secondary displays

- **Risk.** Events injected by the Guest Agent with a display ID do not reach the right app on a secondary display, focus follows the wrong display, or the IME attaches to display 0.
- **Mitigation.** Per-display injection and focus routing ([../02-design/input.md](../02-design/input.md) §7); the APKRun IME with the per-display `ime_policy` (`LOCAL`, `FALLBACK_DISPLAY`, `HIDE`; [../02-design/guest-protocol.md](../02-design/guest-protocol.md)).
- **Fallback.** `primaryDisplayCompatibility` for affected apps; `FALLBACK_DISPLAY` IME policy.
- **Settled by.** #024, #030 (independent input to two displays), #071 (typing goes to the focused display).
- **Result.** Not yet run.

### R-06 Stock Cuttlefish image on the VZ topology

- **Risk.** The Cuttlefish arm64 image expects crosvm's machine: its device set, interrupt layout, and console count. VZ gives one PCI ECAM host, GICv3, PSCI hvc, a PL031 RTC, a PL061 power button, no PL011, and RAM at 0x70000000 ([../02-design/vm.md](../02-design/vm.md) §5). Android could fail in the kernel, in first-stage init (block devices, `boot_devices`), or later in HALs.
- **Mitigation.** The reference boot capture on crosvm (#064) gives a known-good boot to diff against; direct kernel boot with a generated bootconfig ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)); topology discovery with the Linux test guest (#011).
- **Fallback.** Adapt the custom image (#035): kernel config, fstab, init scripts. That moves the fix to M5 and delays G2 with the stock image.
- **Settled by.** #012, #013, #014 (gate G2), #064.
- **Result.** Not yet run.

### R-07 No VM save/restore while VirGL is active

- **Risk (accepted).** Host renderer state cannot be serialized, so the custom GPU device sets `supportsSaveRestore = false` ([../02-design/vm.md](../02-design/vm.md) §9.5). Cold start cannot be shortened by restoring a saved VM, and APKRun cannot save the VM across host restarts.
- **Mitigation.** Keep the VM warm under apkrund with pause/resume ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5); trim boot time measured by the perf harness (NFR-PERF-02).
- **Watch.** Revisit if a later virglrenderer or a Venus track (#096) can rebuild state.
- **Result.** Accepted in ADR-0002 and ADR-0004.

### R-08 Memory footprint

- **Risk.** Guest RAM, the renderer's host memory, and one IOSurface pool per display exceed what a typical Mac can give, especially with several windows (NFR-RES-*).
- **Mitigation.** `display.maxSessions` (default 8) bounds displays ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3; [../03-reference/configuration.md](../03-reference/configuration.md)); memory defaults in [../02-design/vm.md](../02-design/vm.md) §10; idle pause ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5); measurements in #070.
- **Fallback.** Lower defaults, smaller pools, balloon before pause (an open question in [open-questions.md](open-questions.md)).
- **Settled by.** #028, #070.
- **Result.** Not yet measured.

### R-09 No Google Mobile Services

- **Risk (accepted).** Many apps need Google Play services for sign-in, push (FCM), maps, or Play Integrity. They fail or lose features. Apps that rely only on FCM get no push while they are not running ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §5).
- **Mitigation.** Clear scope ([../00-product/scope.md](../00-product/scope.md) §3); the compatibility database (#090) labels apps; the FCM limit is stated in the FR-INT-03 row ([traceability.md](traceability.md) §2).
- **Never.** Integrity bypass. Google Play is only considered as the isolated post-v1 track #097.
- **Result.** Accepted.

### R-10 Licensing of images and libraries

- **Risk.** Redistributing Cuttlefish-derived images, GPL/LGPL components, or ANGLE/virglrenderer builds without meeting their terms (source offers, notices), or depending on a component whose license is incompatible with distribution.
- **Mitigation.** Every third-party component is listed with its license in `ThirdParty/ThirdParty.lock.json`; notices are generated for the app and the image; the rules are in [../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md). Stock Google-built images are used for development only; shipped images are built by APKRun from AOSP source (#035).
- **Settled by.** #093 (legal review and compliance checklist) before v1.0.
- **Result.** Not yet reviewed.

### R-11 Direct kernel boot is not enough

- **Risk.** Android needs something that U-Boot provides on Cuttlefish: AVB results, the slot suffix, the boot reason, or `boot_devices`. Direct kernel boot through `VZLinuxBootLoader` (an uncompressed arm64 `Image`) with a generated bootconfig misses it.
- **Mitigation.** The bootconfig carries the values U-Boot would set (`androidboot.slot_suffix=_a`, `verifiedbootstate`, `boot_devices`; [../02-design/android-image.md](../02-design/android-image.md) §6); the reference capture (#064) lists what U-Boot passes.
- **Fallback.** A U-Boot EFI build as the boot loader ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)).
- **Settled by.** #012–#014.
- **Result.** Not yet run.

### R-12 Cuttlefish host-service dependencies

- **Risk.** The guest expects Cuttlefish host processes (secure_env, modem simulator, GNSS, sensors, vhost-user input, `socket_vsock_proxy`) on fixed hvc ports and vsock ports. VZ's ordering of 20 virtio-console devices is not confirmed, a HAL may crash-loop on a silent port, and network interface naming depends on Cuttlefish's multi-NIC setup.
- **Mitigation.** #095 decides port by port and service by service: attach all 20 ports in order, verified with `APKRUN-PORT-<i>` markers ([../02-design/vm.md](../02-design/vm.md) §6.2); in-guest KeyMint and Gatekeeper implementations selected through bootconfig; one NAT NIC set up as Wi-Fi ([../02-design/android-image.md](../02-design/android-image.md) §7).
- **Fallback.** Attach fewer ports and move the affected HALs into the custom image ([../02-design/android-image.md](../02-design/android-image.md) §7).
- **Settled by.** #095, #014.
- **Result.** Not yet run.

### R-13 SELinux policy for the bridge and agents

- **Risk.** The permissions the custom image grants to `apkrun_vsockd`, the Guest Agent, and the Store Agent (vsock sockets, local sockets, privileged services) need more policy than planned, or conflict with neverallow rules.
- **Mitigation.** New domains developed in permissive mode on userdebug only, denials turned into rules, CI check that release builds have no permissive domains ([../02-design/guest-components.md](../02-design/guest-components.md) §4.2).
- **Fallback.** Move a function from the agent to a system service in the product, or use the platform-signed priv-app path.
- **Settled by.** #035.
- **Result.** Not yet run.

### R-14 AOSP build infrastructure

- **Risk.** Building the APKRun product needs a large x86_64 Linux builder ([../05-development/environment-setup.md](../05-development/environment-setup.md) §5). Public AOSP arrives as release drops (the pinned branch is `aosp-android-latest-release`, [../02-design/android-image.md](../02-design/android-image.md) §2), and the Cuttlefish device tree can change layout between drops. Build breaks or long builds slow M5 and every image release.
- **Mitigation.** Pinned `repo` manifests, a scripted remote build, the stock image kept usable for development until the custom image passes the same pipeline ([../02-design/android-image.md](../02-design/android-image.md) §11).
- **Settled by.** #035.
- **Result.** Not yet run.

### R-15 Android install floors

- **Risk (known).** Android refuses some apps: `targetSdkVersion` below the install floor (23 on API 34, 24 on API 35 and later), no v2+ signature with `targetSdk ≥ 30`, and uncompressed-and-aligned `resources.arsc` for `targetSdk ≥ 30`. Users see older apps fail.
- **Mitigation.** The host inspection reports these before install with clear errors (`targetSdkTooLow`, `legacySignatureNotAllowed`, `resourcesArscNotAligned`; [../02-design/package-store.md](../02-design/package-store.md) §4.6). APKRun never bypasses the floor (`--bypass-low-target-sdk-block` is not used).
- **Settled by.** #041, #073; the corpus runs of #090 show the real share.
- **Result.** Rules known; field share not measured.

### R-16 Virtualization.framework changes on new macOS builds

- **Risk.** A macOS update changes the VZ guest topology (PCI paths, device order), the custom virtio API behavior, or console numbering. `boot_devices` and hvc numbering depend on them.
- **Mitigation.** The topology is recorded in `Images/reference/vz/<macOS build>/topology.txt` by #011 and re-checked by the T2 suite on every new macOS build (beta seeds included) ([../02-design/vm.md](../02-design/vm.md) §5, [../02-design/android-image.md](../02-design/android-image.md) §5.3); `boot_part_uuid` is the alternative if the path is unstable ([../02-design/android-image.md](../02-design/android-image.md) §5.3).
- **Status.** Watching for every macOS release.

### R-17 Gatekeeper and App Management policy for wrappers

- **Risk.** Future macOS policy blocks or prompts for locally created, ad-hoc signed wrappers, or App Management blocks apkrund from updating wrappers in `/Applications`.
- **Mitigation.** Local wrappers are created by apkrund, never downloaded, and carry no quarantine attribute, so Gatekeeper does not assess them ([../02-design/wrapper.md](../02-design/wrapper.md) §7.1); the registry trusts wrappers by cdhash; distribution wrappers are Developer ID signed and notarized (#088).
- **Fallback.** Wrappers in `~/Applications` by default; a one-time App Management permission prompt with instructions.
- **Settled by.** #046, #047 (gate G8), #076, #088.
- **Result.** Tested on macOS 27 during research (`open` runs a locally created wrapper without assessment). Not yet tested in the product.

### R-18 Hidden or privileged Android APIs

- **Risk.** The guest agents rely on APIs that are hidden, privileged, or signature-protected and can change between Android releases: input injection with a display ID, the pointer-icon API, `moveRootTaskToDisplay`, update ownership (`setRequestUpdateOwnership`), and `RollbackManager` with `MANAGE_ROLLBACKS` / `TEST_MANAGE_ROLLBACKS`. On the stock image the agent runs as a shell-launched `app_process`; on the custom image it is a platform-signed priv-app.
- **Mitigation.** The privilege table in [../02-design/guest-components.md](../02-design/guest-components.md) §5 names each API and its permission; every call has a capability check reported in `Health`; the custom image grants permissions through privapp allowlists.
- **Fallback.** Per API, as listed in the design: hover off if the pointer cannot be hidden ([../02-design/input.md](../02-design/input.md) §4); the confirmed data-loss path if rollback is refused ([../02-design/package-store.md](../02-design/package-store.md) §7.3).
- **Settled by.** #072, #034, #039, #043, and again for each new Android base in #058.
- **Result.** Not yet run.

### R-19 Background mode and notification permission

- **Risk.** A wrapper that keeps its app running without a window shows a Dock tile flash, or notification authorization is lost when a wrapper is regenerated ([../02-design/wrapper.md](../02-design/wrapper.md) §5.8).
- **Settled by.** #054, #076.
- **Fallback.** As in [../02-design/wrapper.md](../02-design/wrapper.md) §5.8 and [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §5.

### R-20 Dock pins with the `Contents` swap

- **Risk.** Replacing a wrapper's `Contents` directory during regeneration breaks Dock pins or triggers App Management prompts on macOS 27 ([../02-design/wrapper.md](../02-design/wrapper.md) §9.3).
- **Settled by.** #076 (verified first, before the rest of the task).
- **Fallback.** Replace the whole bundle, with a note that a Dock pin may need to be re-added.

### R-21 Pasteboard read prompts

- **Risk.** macOS 27 shows a paste-permission prompt when apkrund or a wrapper reads the pasteboard on focus to push it to Android ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §4.2).
- **Settled by.** #053: which process reads, whether reading on focus prompts, and which API tells the change count without reading.
- **Fallback.** Push on paste only (Cmd+V in the window) instead of on focus.

### R-22 Privacy prompts for user folders

- **Risk.** Reading user-added shared folders from apkrund triggers privacy prompts attributed to the wrong app, or none that the user can act on ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6.4).
- **Settled by.** #082.
- **Fallback.** Security-scoped bookmarks created by APKRun.app through an open panel; Settings → Files explains how to allow access.

### R-23 Sparkle details

- **Risk.** The pinned Sparkle 2 version differs from the design in the two recent Info.plist keys (`SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`), in installing a postponed update on quit, in the signed appcast format, or in allowing plain HTTP on loopback for tests ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2).
- **Settled by.** #057 step 1. Differences are recorded here and in [ADR-0016](../01-architecture/decisions/0016-sparkle-host-updates.md).
- **Fallback.** Keep the archive signature and Developer ID checks, and document the gap.

### R-24 launchd and a replaced bundle

- **Risk.** launchd keeps running or spawns the old apkrund binary after Sparkle replaces the bundle, when the agent plist is unchanged and APKRun does not re-register it ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.7).
- **Settled by.** #057 T2 test "APKRun N → N+1", variant (d) and the unchanged-plist case.
- **Fallback.** Re-register the agent on every build change.

### R-25 Extraction writes zero runs

- **Risk.** Extracting a runtime image archive writes the all-zero runs of `os.img` to disk before holes are punched, costing time and SSD writes ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.5).
- **Settled by.** #087 measures time and bytes written.
- **Fallback.** A sparse-aware extraction sink that seeks over zero blocks.
