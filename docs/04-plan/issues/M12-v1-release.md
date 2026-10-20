# M12 v1.0 release

APKRun 1.0 ships. M12 adds audio output (#84) and the microphone (#85). It finishes the release path: Developer ID signing and notarization with distribution wrappers (#89), the compatibility database (#91), the trust-boundary review and fuzzing (#92), English and Japanese localization with VoiceOver support (#93), and license compliance (#94). #95 checks the release criteria of [roadmap.md](../roadmap.md) §3.6 and tags v1.0. #85 waits for #84. The other tasks can run in parallel once their earlier dependencies are done. M12 closes no gate.

Several tasks share files: `errors.json`, the String Catalogs, `Daemon/apkrund/`, [security-model.md](../../01-architecture/security-model.md), `ThirdParty/ThirdParty.lock.json`, and `.github/workflows/nightly.yml`. Merge them in small steps. After #93 merges, every later pull request adds the Japanese text for its new strings.

---

## #84 Audio output

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #36 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §8.1, §8.3; [vm.md](../../02-design/vm.md) §4, §11; [android-image.md](../../02-design/android-image.md) §7.5, §11; [configuration.md](../../03-reference/configuration.md) §2.4 |
| Code | `Packages/VirtualMachineCore/` (`SoundDefinition` → `VZVirtioSoundDeviceConfiguration`), `Packages/ImageCore/` (`AndroidBootPlanner`, `BootOptions.soundOutput`), `Packages/RuntimeCore/` (`AudioPolicy`), `Apps/APKRun/Features/Settings/` (Runtime pane), `Guest/product/` (only if a part is missing), `Tests/Fixtures/AndroidApps/helloaudio/`, `Tests/IntegrationTests/DesktopIntegrationTests/`, `Tests/AcceptanceTests/AudioLoopback/` |

**Goal.** Android apps play sound on the Mac through one virtio-snd output stream to the current macOS default output device, and follow it when it changes. `audio.output = false` leaves the sound device out at the next start. Latency, underruns, and the negotiated format are measured.

**Out of scope.** The microphone (#85). Per-app mute, Now Playing, and media keys (post-v1). Host-side mixing or per-app volume. Choosing an output device in APKRun.

**Steps.**
1. **Sound device.** `SoundDefinition` with `output = true` maps to one `VZVirtioSoundDeviceConfiguration` with one output stream whose sink is `VZHostAudioOutputStreamSink`. `nil` gives no sound device. `input` stays `false` until #85. **Check:** T0 builder tests pass, and the output-only configuration passes validation.
2. **`audio.output` and boot.** RuntimeCore reads `audio.output` before each boot and sets `BootOptions.soundOutput`. `AndroidBootPlanner` maps it to `SoundDefinition(output:input:)` ([configuration.md](../../03-reference/configuration.md) §2.4). A change while Android runs does not touch the running VM. Settings → Runtime shows "Sound output" with **Restart Android Now**. `apkrun config set audio.output …` says the change applies at the next start ([cli.md](../../02-design/cli.md) §4.6). **Check:** a T0 test with a fake store keeps the running definition, and the next boot follows the key.
3. **Guest audio path.** On the custom image, check that `virtio_snd` is loaded (`lsmod`) or built in, `/proc/asound/cards` shows the card, `ro.hardware.audio.primary` is `goldfish`, and the HAL opens the tinyalsa card ([android-image.md](../../02-design/android-image.md) §7.5). Add a missing part to `Guest/product/` and rebuild through #36 ([android-image.md](../../02-design/android-image.md) §11). Settle OQ-38 in [open-questions.md](../open-questions.md). **Check:** a T2 test finds the card through `AdbClient`.
4. **HelloAudio.** Add the fixture in `Tests/Fixtures/AndroidApps/helloaudio/`, signed with `test-fixture-a.jks` ([build-system.md](../../05-development/build-system.md) §8.1). Its actions play a 1 kHz tone, a sweep, a click track (one click per second), and a 5 s recording that shows the level. It logs `play <name>` at playback start and `recorded <frames> <peak>` after a recording. Its spec is in [test-strategy.md](../test-strategy.md) §4.2. **Check:** `scripts/check-fixtures.sh` passes, and the APK installs on the custom image.
5. **Measurement.** T2 reads `/proc/asound/card*/pcm*p/sub0/hw_params` and `status` through `AdbClient` during playback, and asserts that the stream runs. On a lab Mac with a virtual loopback output, latency is the click onset in the capture minus the `play click` event time (guest clock from #70), and the error bound is stated. A 10-minute playback with the VM idle shows no gap in the tone, and no increase of the underrun counter in `dumpsys media.audio_flinger`. Switching the macOS default output during playback moves the sound. **Check:** the Done-when items pass.

**Tests.**
- T0 (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`, `Packages/ImageCore/Tests/ImageCoreTests/`, `Apps/APKRun/Tests/`): the sound builder, `audio.output` → `BootOptions` → `SoundDefinition` (next boot only), and the Settings row model.
- T2 (`Tests/IntegrationTests/DesktopIntegrationTests/AudioOutputTests`, custom image): the card is present, HelloAudio opens an output stream through `virtio_snd`, the rate and format are logged, and after `audio.output = false` and a restart Android has no sound card.
- T3 (`Tests/AcceptanceTests/AudioLoopback/`): loopback capture, latency, and the 10-minute underrun run, nightly on a lab Mac with a virtual audio device. Otherwise a manual check, C10-5 ([test-strategy.md](../test-strategy.md) §8.7).

**Done when.**
- With `audio.output = true` (the default), the VM has one virtio-snd device with one output stream and no input stream.
- Android plays through the goldfish HAL on the virtio-snd card, and the rate and format are logged.
- The tone and sweep are heard on the current default output, and the sound follows a change of default output.
- Output latency is measured with the click track. The target is ≤ 120 ms (provisional). A miss gets a follow-up task with the number.
- A 10-minute playback with the VM otherwise idle has no underrun.
- `audio.output = false` leaves the device out at the next start and does not change the running VM. Settings offers **Restart Android Now**.
- C10-5 passes: tone, sweep, and click track are heard, in sync.

**Pitfalls.**
- macOS shows apkrund as the process that plays audio. That is expected.
- The virtual audio device on the lab Mac is a runner prerequisite. Document its setup in [environment-setup.md](../../05-development/environment-setup.md) §6.

---

## #85 Microphone

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #84 |
| Design | [desktop-integration.md](../../02-design/desktop-integration.md) §8.2, §8.3; [vm.md](../../02-design/vm.md) §3, §11; [guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §8.1 (op 53, event 45); [host-ui.md](../../02-design/host-ui.md) §7.4, §9.4, §12; [security-model.md](../../01-architecture/security-model.md) §3.2 |
| Code | `Packages/IntegrationCore/` (`AudioPolicy` microphone part, `integrationStatus`, `activeRecordings`), `Packages/RuntimeCore/` (`BootOptions.microphone`, `SetMicrophoneAccess` push), `Packages/VirtualMachineCore/` (input stream), `Packages/GuestProtocol/proto/` (`audio.v1`), `Guest/guestd/` (`MicrophoneGate`), `Guest/product/permissions/privapp-permissions-apkrun.xml`, `Daemon/apkrund/` (Info.plist, `apkrund.entitlements`), `Apps/APKRun/Features/AppPage/`, `Apps/APKRun/Features/Settings/`, `Apps/APKRunMenuBar/`, `Tests/IntegrationTests/DesktopIntegrationTests/` |

**Goal.** An Android app that the user allows can record from the Mac microphone. Every other package records silence. macOS asks for microphone permission once, for APKRun. The input stream exists only while at least one app has the microphone on. The menu bar shows which app is recording.

**Out of scope.** The camera (FR-INT-10, 1.x). Choosing an input device (macOS's default input is used). A usage description in wrappers, which have none ([wrapper.md](../../02-design/wrapper.md) §2.1). Attaching or detaching the input stream without a restart.

**Steps.**
1. **Input stream rule.** `AudioPolicy` computes the set of managed packages whose effective `integrations.microphone` is `true` ([configuration.md](../../03-reference/configuration.md) §3.2). `integrations.enabled.microphone = false` empties the set. RuntimeCore sets `BootOptions.microphone` to "set is not empty" before each boot. VirtualMachineCore adds one `VZHostAudioInputStreamSource` input stream to the #84 device. Both the first-on and the last-off change need a restart, and the UI offers it. **Check:** T0 tests of the set (global switch off, one package on, all off, unmanaged package off) pass, and a builder test with `input = true` gives one output and one input stream.
2. **Usage description and entitlement.** Add `NSMicrophoneUsageDescription` to apkrund's Info.plist source in `Daemon/apkrund/`, and `com.apple.security.device.audio-input` to `apkrund.entitlements` ([build-system.md](../../05-development/build-system.md) §12.2). Update the apkrund row of [security-model.md](../../01-architecture/security-model.md) §3.2 in the same pull request. The `build` job checks the Release binary: `otool -s __TEXT __info_plist` shows the key, and `codesign -d --entitlements -` shows the entitlement. **Check:** the build check passes, and `sound.input = true` without the key fails with `.microphoneUsageDescriptionMissing`.
3. **App-ops gating.** Add `SetMicrophoneAccess(repeated string packages)` to `audio.v1` (op 53). `MicrophoneGate` in `Guest/guestd` sets `OP_RECORD_AUDIO` to `MODE_IGNORED` for every user-installed package not in the list, and to `MODE_ALLOWED` or the default for listed ones. It reapplies the list on `PACKAGE_ADDED` and after each reconnect. Grant `MANAGE_APP_OPS_MODES` in `privapp-permissions-apkrun.xml`. Android's own `RECORD_AUDIO` dialog still appears. **Check:** a Kotlin test of the mode table against a fake `AppOpsManager` passes. T2: `appops get <pkg> RECORD_AUDIO` shows `ignore` for an unlisted package.
4. **Active-recording events.** `MicrophoneGate` registers an `AudioManager.AudioRecordingCallback` and sends `RecordingChanged(packages)` (event 45). Grant `MODIFY_AUDIO_ROUTING`, because without it the package list is anonymized. IntegrationCore publishes `recordingChanged` on the `integrations` topic and serves `activeRecordings()`. The menu bar shows "‹App› is using the microphone" and the microphone symbol ([host-ui.md](../../02-design/host-ui.md) §12). **Check:** T2: `recordingChanged` names HelloAudio while it records, and is empty afterwards.
5. **Restart prompt and permission state.** When the first app turns the microphone on, the app page shows "Android needs to restart to use the microphone." with **Restart Android Now** and **Later**. The last-off change shows the same prompt. `integrationStatus` reports apkrund's permission from `AVCaptureDevice.authorizationStatus(for: .audio)`. The app page and Settings → Privacy show it, and a denied state explains how to allow access with **Open System Settings** ([host-ui.md](../../02-design/host-ui.md) §9.4). The `integrations.microphone` check warns when permission is denied or a restart is pending, with the errors `microphonePermissionDenied` and `microphoneNeedsRestart`. **Check:** T0 model tests cover first-on, last-off, and denied; a T0 test covers the health check.

**Tests.**
- T0 (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`, `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`, `Packages/GuestProtocol/Tests/GuestProtocolTests/`, `Guest/guestd/src/test/`, `Apps/APKRun/Tests/`, `Apps/APKRunMenuBar/Tests/`): the in-effect set, the input builder and validation, the `audio.v1` codec round trip, the app-ops table, the restart prompt, the denied state, and the menu bar indicator.
- T2 (`Tests/IntegrationTests/DesktopIntegrationTests/MicrophoneTests`, custom image): HelloAudio's 5 s recording with the microphone on has a non-zero peak. Another package records silence (peak 0). The input stream is absent when no package has the microphone on. `recordingChanged` names the recording package. The lab Mac grants microphone access to `io.apkrun.apkrund.dev` once, by hand ([test-strategy.md](../test-strategy.md) §3.6). A missing grant fails with `runnerMissingPermission`.
- T3 (`Tests/AcceptanceTests/AudioLoopback/`): with a virtual input device, the level follows a test signal (nightly where the runner has the device, otherwise manual). Checklist C10-4 records when the prompt appears.

**Done when.**
- With the microphone on for HelloAudio and permission granted, its 5 s recording follows a test signal.
- With the microphone off for HelloAudio and on for another package, HelloAudio records silence. Android's `RECORD_AUDIO` dialog still appears in the app's window.
- With no package using the microphone, the VM has no input stream. The first-on and last-off changes each offer **Restart Android Now**.
- macOS asks for microphone permission once, for APKRun. Wrappers carry no usage description.
- The Release binary embeds `NSMicrophoneUsageDescription` and carries `com.apple.security.device.audio-input`, which [security-model.md](../../01-architecture/security-model.md) §3.2 lists.
- With permission denied, the app page explains how to allow it, and `integrations.microphone` warns.
- While an app records, the menu bar shows "‹App› is using the microphone".
- C10-4 passes.

**Pitfalls.**
- Re-apply the app-ops mode for newly installed packages. Otherwise an app installed after the last push can record from the Mac.
- Microphone contents and levels never go into logs or diagnostics. Log package IDs only (NFR-SEC-05).

---

## #89 Developer ID signing, notarization, and distribution wrappers

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #63, #47 |
| Design | [wrapper.md](../../02-design/wrapper.md) §10.2, §11, §12; [build-system.md](../../05-development/build-system.md) §3.1, §12; [security-model.md](../../01-architecture/security-model.md) §3.2 |
| Code | `Packages/WrapperCore/` (`WrapperSigner` Developer ID path, `DistributionWrapperBuilder`), `Packages/RuntimeHost/` (`buildDistributionWrapper`), `Packages/RuntimeAPI/`, `CLI/apkrun/Commands/` (`wrap --distribution`), `scripts/release/`, `.github/workflows/release.yml`, `.github/workflows/nightly.yml`, `Tests/IntegrationTests/WrapperTests/` |

**Goal.** The Release APKRun.app is Developer ID signed with Hardened Runtime and a secure timestamp. It is notarized, stapled, and shipped in a notarized DMG. `apkrun wrap <package> --distribution` produces a Developer ID signed wrapper, optionally notarized, that opens on a clean Mac after the standard Gatekeeper confirmation.

**Out of scope.** Self-updating distribution wrappers and trust by Developer ID team (OQ-25, post-v1; v1 trusts wrappers by cdhash). A GUI for distribution wrappers. Apple ID passwords (keychain profiles only). Publishing the appcast and the image feed (#58, #88, #95; host OQ-01).

**Steps.**
1. **Release signing.** `scripts/release/assemble-bundle.sh` builds Release with `CODE_SIGNING_ALLOWED=NO`. `sign-bundle.sh <app> <identity>` (created by #58) signs inside out with `--force --sign "$IDENTITY" --options runtime --timestamp` and the entitlements of [build-system.md](../../05-development/build-system.md) §12.2. It never uses `--deep`, and it fails if a Mach-O file is unsigned. Confirm the Sparkle nested paths for the pinned version. **Check:** `codesign --verify --strict --deep --verbose=2` passes, `codesign -d --entitlements -` shows only the entitlements of [build-system.md](../../05-development/build-system.md) §12.2, and `scripts/check-launcher.sh` passes on the signed launcher.
2. **Notarize and DMG.** `scripts/release/notarize.sh <path>` zips with `ditto -c -k --keepParent`, runs `xcrun notarytool submit … --wait`, staples, and runs `spctl --assess --type execute -vv`. It uses the profile `apkrun-notary` on the lab Mac, and `--key`, `--key-id`, and `--issuer` in CI. `make-dmg.sh` builds `APKRun-<version>.dmg` with `hdiutil create -format UDZO`, then signs, notarizes, and staples it. **Check:** on the lab Mac `spctl` reports "Notarized Developer ID" for the app, and `xcrun stapler validate` passes for the app and the DMG.
3. **Release workflow and nightly.** Extend `release.yml` from #58 (tags `v*`, environment `release`). It assembles, signs, runs `check-release-build.sh` with every row including R1, R5, and R6, notarizes and staples the app, and builds the DMG. The Sparkle archive is made from the stapled app. A manual dry-run input stops before publishing. Add the nightly `notarize` job in environment `signing`. **Check:** a dry run on `main` gives a stapled DMG and a passing `check-release-build.sh`, and pull-request jobs never receive release secrets.
4. **Distribution builder.** `DistributionWrapperBuilder` in WrapperCore generates the wrapper in staging with `APKRunWrapperKind = distribution`. It is not placed or registered. `WrapperSigner` signs with `codesign --force --sign "<identity>" --identifier <bundleID> --options runtime --timestamp`, then verifies with `codesign --verify --strict` and `SecStaticCodeCheckValidity`. Tools run through `Process` with absolute paths. Before any work, check `xcrun --find notarytool` and `xcrun --find stapler` (missing gives `distributionToolMissing`), and `security find-identity -v -p codesigning` (missing gives `identityNotFound`). **Check:** a T0 test with a fake process runner covers the argument lists and both errors. A T1 test signs with a test identity imported into a temporary keychain from `Tests/Fixtures/signing/test-*`.
5. **Notarization output.** With `--notarize`, zip with `ditto -c -k --keepParent` and run `xcrun notarytool submit <zip> --keychain-profile <profile> --wait --output-format json`. `Accepted` leads to `xcrun stapler staple` and a new zip. `Invalid` gives `notarizationFailed(submissionID:summary:)`, with the summary from `notarytool log`. Then `spctl --assess --type execute -vv` must report "source=Notarized Developer ID". Output is `<dir>/<name>.app` and `<dir>/<name>.zip`. If apkrund cannot write `--output`, the CLI places the staged result, as for local wrappers ([wrapper.md](../../02-design/wrapper.md) §6.3). **Check:** a T0 test parses recorded `notarytool` outputs for `Accepted`, `Invalid`, and `In Progress` until the timeout.
6. **API, CLI, confirmation.** Add `buildDistributionWrapper(DistributionWrapperRequest{packageID, identity, notarize, keychainProfile?, outputDirectory})` → `DistributionWrapperResult{appURL, zipURL, submissionID?, assessment}` as a long operation with progress. The CLI is `apkrun wrap <package> --distribution --identity … [--notarize --keychain-profile …] [--output …] [--yes] [--json]`. It asks the creator to confirm that the APK may be redistributed, and `--yes` skips the question. Add a HelloText distribution wrapper to the nightly `notarize` job. **Check:** CLI golden files pass, human and JSON, including the three errors.
7. **Acceptance.** On a clean test account, download a notarized `HelloText.app` zip with Safari. It opens after the standard "downloaded from the Internet" confirmation, with no other Gatekeeper warning. When translocated, it asks to move to Applications, then asks for approval showing the Developer ID team, and installs from the bootstrap. Run checklist C10-6 and C10-7, and settle R-17 in [risks.md](../../04-plan/risks.md). **Check:** every Done-when item passes.

**Tests.**
- T0 (`Packages/WrapperCore/Tests/WrapperCoreTests/`, `Packages/RuntimeAPI/Tests/RuntimeAPITests/`, `CLI/apkrun/Tests/`): argument lists and errors with a fake runner, `notarytool` output parsing, DTO round trips, and CLI golden files.
- T1 (`Packages/WrapperCore/Tests/WrapperCoreSystemTests/`): Developer ID-style signing and verification with a test identity in a temporary keychain, and `sign-bundle.sh` over a Release build, followed by `codesign --verify --strict --deep`.
- T2 (`Tests/IntegrationTests/WrapperTests/DistributionWrapperTests`, custom image): App Translocation with a quarantined copy, the move-to-Applications prompt, approval, and the bootstrap install ([wrapper.md](../../02-design/wrapper.md) §16).
- T3: the nightly `notarize` job (Release app and HelloText distribution wrapper, `spctl`, `stapler validate`), and checklist items C10-6 and C10-7.

**Done when.**
- The Release APKRun.app is Developer ID signed inside out with Hardened Runtime and a secure timestamp. `codesign --verify --strict --deep` passes, and no binary has an entitlement beyond [build-system.md](../../05-development/build-system.md) §12.2.
- APKRun.app and `APKRun-<version>.dmg` are notarized and stapled. `spctl` accepts the app, and `stapler validate` passes (C10-7).
- `check-release-build.sh` runs every check, including R1, R5, and R6. A dry run stops before publishing.
- `apkrun wrap <package> --distribution --identity …` gives a Developer ID wrapper that passes `codesign --verify --strict`. With `--notarize` it is stapled, and `spctl` reports "Notarized Developer ID".
- Without `notarytool` or `stapler` the command fails with `distributionToolMissing`. An unknown identity gives `identityNotFound`. A rejected submission gives `notarizationFailed` with the submission ID and the log summary.
- The CLI asks for the redistribution confirmation, and `--yes` skips it.
- A notarized HelloText distribution wrapper downloaded with Safari opens after the standard Gatekeeper confirmation. It asks to move to Applications when translocated, asks for approval, and installs from the bootstrap (C10-6).
- The nightly `notarize` job passes.

**Pitfalls.**
- Signing must be the last write to a bundle. Stapling adds a ticket without changing the seal, but any other change after signing breaks it.
- `notarytool` comes with the Xcode Command Line Tools on the creator's Mac. End users never need it.

---

## #91 Compatibility database

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #60 |
| Design | [diagnostics.md](../../02-design/diagnostics.md) §10; [configuration.md](../../03-reference/configuration.md) §3.2; [host-ui.md](../../02-design/host-ui.md) §6.1, §7.1; [cli.md](../../02-design/cli.md) §4.2; [display-and-windowing.md](../../02-design/display-and-windowing.md) §8 |
| Code | `Packages/APKStoreCore/` (`CompatibilityDatabase`, `PackageSettingsResolver`), `Packages/RuntimeAPI/` (`CompatibilityInfo`), `Apps/APKRun/Features/AddFlow/`, `Apps/APKRun/Features/AppPage/`, `CLI/apkrun/Commands/`, `Tests/Compatibility/` (`apps.json`, `compatibility.schema.json`, `database/compatibility.json`, `run-compatibility.sh`), `scripts/check-compatibility-db.sh`, `.github/ISSUE_TEMPLATE/app-compatibility.md` |

**Goal.** APKRun ships a compatibility database in its bundle. For each known app it shows the level (Works, Works with limitations, Unsupported), the known issues, and the recommended settings. Recommendations apply without being written to the user's settings, and an explicit user choice always wins. The database is advice and never blocks an install.

**Out of scope.** Downloading the database separately, or sending data about installed apps (the file changes only with APKRun updates). Blocking installs ([package-store.md](../../02-design/package-store.md) §4.6). Fixing the problems that the runs find (follow-up tasks). An in-app catalog ([host-ui.md](../../02-design/host-ui.md) §16).

**Steps.**
1. **Schema and lint.** Write `Tests/Compatibility/compatibility.schema.json` for the format of [diagnostics.md](../../02-design/diagnostics.md) §10.2: `packageID`, `signerDigests`, `versionCodes`, `level`, `issues` (in `en` and `ja`), `recommendedSettings`, `testedWith`, and `source`. Allowed `recommendedSettings` keys are `window.*`, `input.*`, `integrations.*` with `false` only, and `update.healthCheckLaunch`. `scripts/check-compatibility-db.sh` (lint job) validates `database/compatibility.json`. **Check:** T0 schema tests reject an unknown key, `integrations.links: true`, and an issue without `ja`.
2. **Loader and matcher.** `CompatibilityDatabase` in APKStoreCore loads `Contents/Resources/compatibility.json` once at apkrund start. It resolves the path from `Contents/Helpers/apkrund`. Match by package ID, then by signer digest when the entry lists digests, then by version range. The narrowest range wins. A missing or invalid file logs an error and gives an empty database. **Check:** T0 tests cover the signer, version range, and narrowest-range rules, and a corrupt file gives an empty database without a crash.
3. **Settings resolution and DTO.** `PackageSettingsResolver` returns the effective value and its source for each key. The first match wins: a global switch that is off, the value in `settings.json`, the recommendation for the installed version, then the built-in default ([configuration.md](../../03-reference/configuration.md) §3.2). Recommendations are never written. **Reset** removes the stored value. A first-record value equal to the default is not written. `PackageStore.settings(for:)` uses the resolver. Add `CompatibilityInfo{level, label, issues, recommendedKeys}` to the package DTOs and to `inspectFile`. **Check:** T0 resolution-order tests and DTO round trips pass.
4. **UI and CLI.** The add-flow review shows the label and issues. `unsupported` changes the button to **Install Anyway** ([host-ui.md](../../02-design/host-ui.md) §6.1). The app page shows them under General, and a recommended value shows "Recommended for this app" ([host-ui.md](../../02-design/host-ui.md) §7.1). `apkrun inspect` and `apkrun info <package>` print `compatibility`, and `apkrun settings <package> list` shows each value's source ([cli.md](../../02-design/cli.md) §4.2). **Check:** T0 model tests cover the three labels, no entry, and **Install Anyway**, and CLI golden files pass.
5. **Corpus runs and seed.** `Tests/Compatibility/run-compatibility.sh` reads `apps.json` (fixture apps, the 50-APK F-Droid corpus, and the hand-installed sample). For each app it installs and launches in the standard window mode, expects a non-blank first frame within 20 s, runs `monkey` for 60 s with a fixed seed through ADB, checks the integrations the app uses, and repeats in the compatibility window mode if the standard mode fails ([display-and-windowing.md](../../02-design/display-and-windowing.md) §8). It writes one proposal per app to `Tests/Compatibility/out/`, which is git-ignored and uploaded as a CI artifact. Review the proposals, then commit the seed with the #30 results. The nightly `compatibility` job runs the corpus. Settle R-02, R-09, and R-15 from the results. **Check:** the first corpus run finishes, and the committed seed passes the schema check.
6. **Issue template.** `.github/ISSUE_TEMPLATE/app-compatibility.md` asks for the package ID, version, signer digest (from `apkrun info`), observed level, steps, and a diagnostics bundle. It says that a report becomes an entry only after a maintainer reproduces it. **Check:** the template renders on GitHub with its fields.

**Tests.**
- T0 (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Packages/RuntimeAPI/Tests/RuntimeAPITests/`, `CLI/apkrun/Tests/`, `Apps/APKRun/Tests/`): matching and the resolution order, the schema tests, corrupt-file handling, DTO round trips, UI models, and CLI golden files.
- T1 (`Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): loading from a built bundle layout (`Contents/Helpers/apkrund` → `Contents/Resources/compatibility.json`).
- T2 (`Tests/IntegrationTests/DiagnosticsTests/CompatibilityDatabaseTests`, custom image): a test database with a `compatibilityMode` entry for a fixture opens it on display 0. An explicit `window.mode` wins. A wrong signer digest does not apply.
- T3: the `compatibility` nightly corpus, and the full list before each release ([test-strategy.md](../test-strategy.md) §7.4).

**Done when.**
- An app with a `compatibilityMode` entry opens in the compatibility window mode with no user setting.
- An explicit user choice overrides the recommendation. **Reset** returns to it, and recommended values show "Recommended for this app".
- An entry with another signer digest does not apply. With several matching entries, the narrowest version range wins.
- `compatibility.json` ships in `Contents/Resources/` and passes schema validation in CI. Keys outside the allowed set are rejected.
- The add flow and the app page show the label and the known issues. `unsupported` apps can still be installed with **Install Anyway**. Apps without an entry show nothing.
- `apkrun inspect` and `apkrun info <package>` include the `compatibility` field.
- The corpus run proposes levels, the reviewed seed is committed, and the issue template exists.

**Pitfalls.**
- The database is advice. If an entry would need to block an install, put the rule in [package-store.md](../../02-design/package-store.md) §4.6 instead.
- Never commit proposals straight into the database. Review them first.

---

## #92 Security hardening and fuzzing

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #32, #35 |
| Design | [security-model.md](../../01-architecture/security-model.md) §9; [build-system.md](../../05-development/build-system.md) §15.2; [graphics.md](../../02-design/graphics.md) §11; [guest-protocol.md](../../02-design/guest-protocol.md) §16; [package-store.md](../../02-design/package-store.md) §14; [update-system.md](../../02-design/update-system.md) §12 |
| Code | `Packages/<Module>/Tests/<Module>Fuzz/`, `Packages/<Module>/Sources/<Module>TestSupport/`, `Tests/Fixtures/fuzz/<target>/`, `scripts/run-fuzz.sh`, `scripts/tool-versions.env`, `Guest/protocol/`, `Guest/guestd/`, `Tests/IntegrationTests/SecurityTests/` |

**Goal.** Every trust boundary of [security-model.md](../../01-architecture/security-model.md) is reviewed, and the result is recorded in its review items ([security-model.md](../../01-architecture/security-model.md) §9). Every parser of untrusted input has a fuzz target. `fuzz-short` runs on pull requests, and `fuzz-long` runs nightly. The XPC and malicious-agent tests pass. v1.0 ships with no open fuzz crash and every review item closed.

**Out of scope.**
- Moving the renderer into its own process (post-v1, [graphics.md](../../02-design/graphics.md) §11). Signed Direct manifests (v1.x, [open-questions.md](../open-questions.md)).
- Fixing design-level findings. They become follow-up tasks (#100 and up). High-impact ones block v1.0.
- Signature bypass or Play Integrity of any kind (NFR-SEC-04). It is never implemented.

**Steps.**
1. **Review items.** Fill in the review items of [security-model.md](../../01-architecture/security-model.md) §9, SR-01 to SR-11, one per boundary: the XPC broker and endpoints; the guest-to-host parsers (virtio-gpu, guest protocol, input); the agent's host operations; APK and container parsing, including aapt2; provider parsing and the update pipeline; APKRun and image updates; signing and release checks; the custom image's SELinux, vsock, and privileged permissions; ADB exposure; secrets in logs and bundles; key storage. Each item names its evidence (a test, a fuzz target, or a review note) and a status. **Check:** every item has evidence and a status.
2. **Fuzz infrastructure.** Confirm and pin `SWIFT_FUZZ_TOOLCHAIN` in `scripts/tool-versions.env`. With `APKRUN_FUZZ=1`, add the `<Module>Fuzz` executables, built with `--sanitize=fuzzer --sanitize=address --sanitize=undefined`. `scripts/run-fuzz.sh <target>|--changed|--all [--seconds <n>]` runs each target with `-timeout=10 -rss_limit_mb=2048 -artifact_prefix=build/fuzz/<target>/`. Add the `fuzz-short` job (60 s per changed target) and the `fuzz-long` job (1 h per target, corpus merge with `-merge=1`). **Check:** a planted crash on a throwaway branch fails `fuzz-short` and uploads the reproducer, and a plain `swift build` still works.
3. **Swift targets.** Each parser gets a `<Module>Fuzz` target. Its entry function is in `<Module>TestSupport` with `package` access, its seed corpus is in `Tests/Fixtures/fuzz/<target>/`, and a replay test is in `<Module>SystemTests`. The targets are: `VirtioGPUProtocol` with `ResourceTable`, enforcing the RiftVM limits (8192 px, 256 MiB buffers, 256 contexts), and a virgl command-stream fuzzer in a separate test process; the guest frame decoder; `ContainerReader` (ZIP, `.apks`, `.xapk`, `.apkm`, [ADR-0017](../../01-architecture/decisions/0017-zipfoundation-zip-reading.md)); the APK Signing Block parser; the aapt2 output parser, seeded with recorded outputs; the Direct manifest parser (1 MiB); the F-Droid index decoder (64 MiB) and `entry.jar` parser; and the GitHub release decoder (4 MiB). Each enforces its size limit before parsing. Also add the targets of [test-strategy.md](../test-strategy.md) §7.2. **Check:** each target runs 60 s without a crash, and an oversized input gives a typed error, never a trap.
4. **Kotlin targets.** Jazzer `@FuzzTest` targets cover the frame decoder in `Guest/protocol`, the agent's `InputBatch` decoder, and the injector's batch validator in `Guest/guestd`. Invalid batches are dropped and counted, never thrown past the decoder. **Check:** they run in the Gradle test run and in `fuzz-long`.
5. **aapt2 sandbox.** The profile is a string constant in APKStoreCore, passed to `sandbox-exec -p`. It denies network and writes, and allows reads of the ticket directory and the tool. Without `sandbox-exec`, aapt2 runs unsandboxed and logs a warning ([package-store.md](../../02-design/package-store.md) §4). **Check:** a T1 test runs a probe under the profile. Writes outside the ticket directory and network connections are denied, and reading the ticket directory works.
6. **Malicious agent and XPC.** Extend the #83 malicious-agent build (test-only, never in a release image) into protocol fuzzing of every agent-to-host operation and integration payload. It sends mutated requests, oversized frames, and floods above the rate limits. NFR-SEC-07 tests: T1 authorization per endpoint, and T2 refusal of another signing identity, a `notAuthorized` for a wrapper of another package, and a refusal of a modified or re-signed wrapper. NFR-SEC-06 tests: the ADB forward listens on `127.0.0.1` only (`lsof -nP -iTCP -sTCP:LISTEN`), and with developer mode off nothing listens on vsock 5555. **Check:** the T2 tests pass, apkrund survives with no crash, and every rejected request is counted.
7. **Code audit and long runs.** List every `// SECURITY:` entry point. Each needs a fuzz target or a named test. Review every `// UNSAFE:` block. Check overflow-checked arithmetic on guest values and absolute tool paths ([coding-conventions.md](../../05-development/coding-conventions.md) §13). Fix what fuzzing finds, and add each reproducer to `Tests/Fixtures/fuzz/<target>/`. File design-level findings as follow-up tasks with the label `security`. A change to `// SECURITY:` code needs the review of [workflow.md](../../05-development/workflow.md) §6. **Check:** `fuzz-long` has run nightly for at least a week with no open crash, and every review item is closed or linked to a follow-up task that is not High impact.

**Tests.**
- T0 (`<Module>Tests` of GraphicsCore, GuestProtocol, APKStoreCore, and UpdateCore): the RiftVM limits, the size limit of every parser, and typed errors for oversized and malformed input.
- T1 (`<Module>SystemTests`, `Guest/protocol/src/test/`, `Guest/guestd/src/test/`): every fuzz target in `fuzz-short`, the reproducer replay, the aapt2 sandbox test, and XPC authorization per endpoint.
- T2 (`Tests/IntegrationTests/SecurityTests/`, custom image): the malicious agent, XPC client validation, and the ADB loopback-only check.
- T3: `fuzz-long` nightly, 1 h per target, and the review items closed. New targets are added to the table in [test-strategy.md](../test-strategy.md) §7.2 in the same pull request.

**Done when.**
- Every parser named in Scope has a fuzz target, a seed corpus, and a replay test. `fuzz-short` runs on every pull request that changes its code.
- `fuzz-long` runs nightly, and no fuzz crash is open at release time.
- The RiftVM limits are enforced in `ResourceTable`.
- The malicious-agent build causes no apkrund crash and no access outside a share or another package's data.
- XPC clients are validated: another signing identity is refused, a wrapper for another package gets `notAuthorized`, and a modified or re-signed wrapper is refused (NFR-SEC-07).
- The ADB forward listens on `127.0.0.1` only, and with developer mode off nothing listens on vsock 5555 (NFR-SEC-06).
- aapt2 runs under the `sandbox-exec` profile, which denies network and writes.
- Every `// SECURITY:` entry point has a fuzz target or a named test.
- The review items of [security-model.md](../../01-architecture/security-model.md) §9 are closed, and none has an open High-impact finding.

---

## #93 Localization and accessibility

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #78 |
| Design | [host-ui.md](../../02-design/host-ui.md) §13, §13.1, §15; [cli.md](../../02-design/cli.md) §6.1, §6.3; [wrapper.md](../../02-design/wrapper.md) §5.9; [error-catalog.md](../../03-reference/error-catalog.md) §3 |
| Code | `Apps/APKRun/Resources/` (`Localizable.xcstrings`, `InfoPlist.xcstrings`), `Apps/APKRunMenuBar/`, `Apps/APKRunLauncher/` (`Localizable.xcstrings`, `LauncherStrings.generated.swift`), `CLI/apkrun/` (`Localizable.xcstrings`, `CLIStrings.generated.swift`), `Packages/DiagnosticsCore/ErrorCatalog/errors.json`, `scripts/check-strings.sh`, `Tests/IntegrationTests/HostUITests/` |

**Goal.** With the Mac set to Japanese, every screen of APKRun.app, the menu bar, the launcher, and every human CLI message is Japanese. The pseudo-language run finds no truncation. APKRun.app works with VoiceOver and passes the accessibility audit. Release builds fail on an untranslated or stale catalog entry.

**Out of scope.** Languages other than English and Japanese. Accessibility inside Android apps ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7). Android-side language behavior (#43, #72, #86). Localizing JSON keys and error codes.

**Steps.**
1. **Strings and terms.** Every user-facing string of APKRun.app, APKRunMenuBar, the launcher, and the CLI comes from a catalog key. Error texts come from error catalog keys. Replace string concatenation with format strings and plural variants, using the formatters of [host-ui.md](../../02-design/host-ui.md) §13. Add the Japanese term for each row of [host-ui.md](../../02-design/host-ui.md) §13.1. **Check:** a lint test fails on a string literal passed to a user-facing text API outside the catalogs.
2. **Japanese for the apps.** Translate `Localizable.xcstrings` and `InfoPlist.xcstrings` of APKRun.app and APKRunMenuBar, and the `ja` field of every `errors.json` entry, using the terms of [host-ui.md](../../02-design/host-ui.md) §13.1. **Check:** every catalog entry is translated, and every error code has `ja` text with the declared placeholders (the Japanese part of T1-4 in [diagnostics.md](../../02-design/diagnostics.md) §12).
3. **Launcher and CLI.** Translate `Apps/APKRunLauncher/Localizable.xcstrings`. The generator writes both languages into `LauncherStrings.generated.swift` ([wrapper.md](../../02-design/wrapper.md) §5.9). Move the CLI's human strings into `CLI/apkrun/Localizable.xcstrings` and generate `CLIStrings.generated.swift` with the same generator. The CLI picks the language from the preferred languages. `--json` output is never localized ([cli.md](../../02-design/cli.md) §6.1). **Check:** Japanese golden files for every human message of the #76 and #60 tests pass ([cli.md](../../02-design/cli.md) §6.3), and `scripts/check-launcher.sh` passes.
4. **Catalog check.** `scripts/check-strings.sh` (lint job) reads every `.xcstrings` file and `errors.json`. For Release it fails on a missing `ja` value, a `stale` entry, or a `needs review` entry. Debug builds only warn. **Check:** the lint job fails on a test catalog with one untranslated entry.
5. **Pseudo-language run.** In `Tests/IntegrationTests/HostUITests/`, run the onboarding, home, add flow, app page, Settings, uninstall, approval, and menu bar screens with `-AppleLanguages "(en-XA)"`, which uses double-length strings. The test checks each label's frame against its text, and saves screenshots as artifacts. **Check:** no text is clipped, and the screenshots are checked (C10-2).
6. **Accessibility.** Add a label to every control, text labels to icon-only buttons, and text to every coloured status dot. Make the main window, sheets, and Settings fully keyboard operable. Run `performAccessibilityAudit()` over the main screens. **Check:** the audit passes with no issue, and the VoiceOver walkthrough C10-1 is done.
7. **Japanese acceptance.** With the Mac set to Japanese, check every screen of [host-ui.md](../../02-design/host-ui.md) §4–§12, and every CLI message of the #76 and #60 tests. **Check:** every Done-when item passes.

**Tests.**
- T0 (`Apps/APKRun/Tests/`, `CLI/apkrun/Tests/`, `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`): every human CLI message in Japanese, the error catalog in `en` and `ja`, the catalog-key lint, and the `check-strings.sh` behavior.
- T2 (`Tests/IntegrationTests/HostUITests/`): the accessibility audit and the pseudo-language run ([host-ui.md](../../02-design/host-ui.md) §15).
- T3: checklist C10-1 (VoiceOver walkthrough of onboarding, home, add flow, per-app settings, Settings, and uninstall) and C10-2 (Japanese UI complete, no truncation, pseudo-language screenshots reviewed).

**Done when.**
- With the Mac set to Japanese, every screen of [host-ui.md](../../02-design/host-ui.md) §4–§12 is in Japanese.
- Every human CLI message of the #76 and #60 tests is in Japanese. JSON output is unchanged.
- The launcher's screens and prompts are in Japanese.
- Every error code and remediation has `en` and `ja` text.
- The pseudo-language run shows no truncation.
- A Release build fails when a catalog has an untranslated or stale entry.
- The accessibility audit passes. Every control has a label, and no status is shown by colour alone. The main window, sheets, and Settings are fully keyboard operable.
- C10-1 and C10-2 are done.

**Pitfalls.**
- `-AppleLanguages "(en-XA)"` shows truncation only for strings that come from catalogs. A hard-coded string stays short and hides the problem.
- Strings added after this task need `ja` in the same pull request. The catalog check enforces this for Release builds.

---

## #94 Legal and licensing compliance

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #21, #36 |
| Design | [legal-and-licensing.md](../../05-development/legal-and-licensing.md); [build-system.md](../../05-development/build-system.md) §6.1–§6.3, §6.8, §11; [android-image.md](../../02-design/android-image.md) §2.3, §10, §11; [runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §4.2 |
| Code | `ThirdParty/ThirdParty.lock.json`, `scripts/release/generate-notices.py`, `scripts/check-licenses.sh`, `scripts/release/check-release-build.sh` (notices row), `Apps/APKRun/` (Help menu item), `Guest/product/` (image notices), `Images/tools/` (bundle notice file), `docs/05-development/legal-and-licensing.md` |

**Goal.** Every component that APKRun.app or the runtime image ships has a known, compatible license. The app and the image show their notices. Source offers exist for GPL and LGPL components. The legal checklist is complete before v1.0.

**Out of scope.** Replacing a component with a problematic license (an ADR and a follow-up task). Legal advice on rights to APKs: the creator confirms them (#89). Google Play and GMS licensing (#98, post-v1).

**Steps.**
1. **Inventory.** Fill `license`, `licenseFiles`, and `ships` for every entry of `ThirdParty/ThirdParty.lock.json` ([build-system.md](../../05-development/build-system.md) §6.1, §6.5). Entries include virglrenderer, libepoxy, ANGLE, the RiftVM reference, aapt2, swift-protobuf, swift-argument-parser, Sparkle, the Kotlin libraries, and the Cargo crates. Cover the SwiftPM, Gradle, and Cargo locks, and list the image components with the licenses of the AOSP build's notice data. **Check:** every shipped component has a license and license files.
2. **License check.** `scripts/check-licenses.sh` (lint job) fails on a missing or unresolved license (`NOASSERTION` or empty), and on a license outside the allow-list of [legal-and-licensing.md](../../05-development/legal-and-licensing.md) §4 for components that APKRun distributes or uses as build or test tooling. A `ships: reference` entry needs an identified license and a committed license copy, without the allow-list. Add the script to the table of [build-system.md](../../05-development/build-system.md) §3. **Check:** a T0 test fails on a lock sample with one missing license, and the real lock passes.
3. **App notices.** `generate-notices.py` writes `Contents/Resources/ThirdPartyNotices.html` from the locks: one section per `ships: app` or `ships: derived` component, with its license text and copyright lines. `reference` entries are excluded. RiftVM attribution is included only if RiftVM code is copied or adapted and its entry is `derived`. The Help menu item **Third-Party Notices** opens the file. `check-release-build.sh` checks that every `app` and `derived` entry has a section. **Check:** a Release build lists every such component, and a fixture bundle with a missing section fails the release check.
4. **Image notices and source offers.** Keep AOSP's notice generation in the custom image, so Android Settings → About → Legal information shows the image notices. The bundle tool adds `legal/notice.html` to the bundle, names it in the manifest `legal.notice`, and lists it in `files` ([runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §4.2). The notice file offers the source for each GPL and LGPL component, naming the exact revision from the manifest `provenance` and the place where it is published. Publish the corresponding source for each release image. **Check:** a release bundle passes ImageCore verification with the notice file, and the notices show in Android.
5. **Redistribution review.** Confirm three things: no stock Google-built image is distributed ([android-image.md](../../02-design/android-image.md) §2.3); no GMS component is in the image ([ADR-0001](../../01-architecture/decisions/0001-real-android-in-vm.md)); and the distribution wrapper confirmation text states the creator's responsibility ([wrapper.md](../../02-design/wrapper.md) §11). **Check:** each item has a result in the checklist.
6. **Checklist.** A maintainer completes the compliance checklist in [legal-and-licensing.md](../../05-development/legal-and-licensing.md). It covers notices, source offers, allowed licenses, identified licenses for reference entries, and redistribution. Settle R-10 in [risks.md](../../04-plan/risks.md), and run checklist C10-8. **Check:** every Done-when item passes.

**Tests.**
- T0 (`scripts/` tests, run in the `lint` job): the license inventory of `ThirdParty/ThirdParty.lock.json`. Every component has a license, and none is unresolved.
- T1: the Release build contains `ThirdPartyNotices.html` with every `ships: app` and `ships: derived` component (a `check-release-build.sh` row).
- T3: checklist C10-8 (notices visible in APKRun.app and in the image).

**Done when.**
- Every shipped component has a known license in the inventory. The license check passes, and a missing or unresolved license fails the `lint` job.
- `ThirdPartyNotices.html` ships in APKRun.app. It lists every `app` and `derived` component, omits `reference` entries, and includes RiftVM attribution only if RiftVM code is copied or adapted. The Help menu opens it.
- The custom image shows its notices in Android. The image bundle carries a notice file with source offers for GPL and LGPL components, and the source is published.
- No stock Google-built image and no GMS component is distributed.
- The legal checklist is complete, and R-10 has a result (C10-8).

**Pitfalls.**
- A new third-party component needs its license entry, and it passes the license check, in the same pull request ([build-system.md](../../05-development/build-system.md) §6.8).
- The production host for published sources is OQ-01.

---

## #95 v1.0 release readiness

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | All other tasks of M0–M12 |
| Design | [roadmap.md](../roadmap.md) §3.6, §4; [test-strategy.md](../test-strategy.md) §8.7, §9; [build-system.md](../../05-development/build-system.md) §12; [workflow.md](../../05-development/workflow.md) §9 |
| Code | `scripts/release/check-readiness.sh`, `.github/workflows/release.yml`, `Tests/AcceptanceTests/ReleaseSmoke/`, the release notes |

**Goal.** The v1.0 candidate meets the ten release criteria of [roadmap.md](../roadmap.md) §3.6, and the evidence for each is in the pull request. The candidate passes release testing ([test-strategy.md](../test-strategy.md) §9). v1.0 is tagged and published.

**Out of scope.** New features and fixes. A failing criterion reopens its task or opens a new one (#100 and up). The post-v1 tracks #97 and #98.

**Steps.**
1. **Readiness script.** `scripts/release/check-readiness.sh` reads the requirement status in [requirements.md](../../00-product/requirements.md), [risks.md](../risks.md), and [open-questions.md](../open-questions.md). It uses `gh` to list open issues with the labels `fuzz-crash`, `nightly-failure`, and `security`, and reads the latest nightly results. It prints one line per criterion, pass, fail, or manual with the evidence to attach, and exits non-zero on a failure. **Check:** it runs on `main` and prints all ten criteria.
2. **Criteria 1–3.** (1) Every Must requirement for v1.0 or earlier has its tasks done and its tests passing. Unfinished Should items go into the release notes. (2) A full `apkrun-perf` run on the reference Mac meets the NFR targets, or an ADR revises a target with the measured numbers. (3) The release smoke matrix passes with the current and the previous stable image: boot, install and launch, update, rollback, wrapper generation, the oldest wrapper (NFR-CMP-02), APKRun N → N+1, and image migration A → B (NFR-CMP-03). **Check:** the evidence is in the pull request.
3. **Criteria 4–6.** (4) Every fixture app is `nativeLike`, the corpus results are in the database (#91), and the level names of [scope.md](../../00-product/scope.md) §4 are shown to users. (5) #92 is done: no open fuzz crash, and the review items are closed. (6) The candidate is Developer ID signed, notarized, and stapled (C10-7). The Sparkle appcast and the image feed are signed and served from the production host (OQ-01). Distribution wrappers work (#89). **Check:** the evidence is in the pull request.
4. **Criteria 7–10.** (7) The #94 checklist is complete. (8) English and Japanese are complete, and the VoiceOver checks pass (#93). (9) `apkrun doctor` tells apart every FR-OPS-01 failure class, and a bundle from a boot failure is secret-free (FR-OPS-02). (10) No open High-impact risk remains without an accepted fallback, and no Decision due at or before v1.0 is open. **Check:** the evidence is in the pull request.
5. **Release candidate.** Tag the merge commit of the release preparation as `v1.0.0`. `release.yml` builds it and publishes it on the beta channel. Its build number must be higher than every published build (R1). Run T0, T1, the release checks, every T2 suite, every closed gate, the performance scenarios, the full compatibility list, the network checks, and nightly notarization on the reference Mac. Update a stable install to the candidate through the real appcast, then run the smoke matrix. If a new image ships, run [test-strategy.md](../test-strategy.md) §9.3. Complete the v1.0 checklist C10-1 to C10-10, including the v0.4 demo repeated on the candidate. **Check:** every step of [test-strategy.md](../test-strategy.md) §9.1 passes, and no smoke matrix cell failed.
6. **Review, notes, tag.** Run the M12 review of [roadmap.md](../roadmap.md) §4: tasks, gates, tests, performance, risks, questions, documents, and version. Write the release notes. Promote the `v1.0.0` candidate from beta to stable without rebuilding it (`release.yml` with `promote`, [workflow.md](../../05-development/workflow.md) §9). A failed candidate is never re-tagged: fix it, and tag `v1.0.1` for the next candidate. **Check:** every Done-when item passes.

**Tests.**
- T0, T1: the full suites on the candidate commit, including the release checks of `check-release-build.sh`.
- T2: every T2 suite on the reference Mac with the candidate.
- T3: the release testing of [test-strategy.md](../test-strategy.md) §9 (candidate, smoke matrix, image candidate, macOS build check), every closed gate, the performance scenarios, the full compatibility list, the network checks, checklist items C10-7 and C10-10, and the complete v1.0 checklist.

**Done when.**
- Every Must requirement for v1.0 or earlier has its tasks done and its tests passing. The unfinished Should items are in the release notes.
- The NFR targets are met on the reference Mac, or an ADR revises them with the measured numbers.
- The release smoke matrix passes, including NFR-CMP-02 and NFR-CMP-03.
- Every fixture app is `nativeLike`, and the corpus results are in the compatibility database.
- #92 is done: no fuzz crash is open, the NFR-SEC-07 tests pass, and the review items are closed.
- APKRun.app is Developer ID signed, notarized, and stapled. The appcast and the image feed are signed and served from the production host (OQ-01). Distribution wrappers work.
- The #94 checklist is complete.
- English and Japanese are complete, and the VoiceOver checks pass.
- `apkrun doctor` tells apart every FR-OPS-01 class, and a boot-failure bundle is secret-free.
- No open High-impact risk remains without an accepted fallback, and no Decision due at or before v1.0 is open.
- Every step of [test-strategy.md](../test-strategy.md) §9.1 passes, checklist items C10-1 to C10-10 are complete, and v1.0 is tagged.

**Pitfalls.**
- Do not fix defects in #95. Reopen the task that owns the failing criterion, or open a new task.
- After v1.0, the post-v1 items of [roadmap.md](../roadmap.md) §5 are reviewed before they become tasks.
