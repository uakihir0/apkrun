# M12 v1.0 release

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v1.0 |
| Related | [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../../AGENTS.md](../../../AGENTS.md) |

## Milestone goal

APKRun 1.0 ships. M12 adds the v1.0 items that no earlier milestone delivers: audio output (#083), the microphone (#084), and the compatibility database (#090). It also finishes the release path. APKRun.app is Developer ID signed and notarized, and users can create distribution wrappers (#088). Every trust boundary is reviewed and fuzzed (#091). English and Japanese are complete and the app works with VoiceOver (#092). License obligations are met (#093). #094 checks the ten release criteria of [../roadmap.md](../roadmap.md) §3.6 and tags v1.0.

## Exit criteria

- [ ] #083, #084, #088, #090, #091, #092, and #093 meet all their acceptance criteria. A task may instead move to a later milestone, with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4 item 1). #094 is done last.
- [ ] T0 and T1 suites pass on `main`. This includes `fuzz-short` for every fuzz target and the replay of every reproducer in `Tests/Fixtures/fuzz/`.
- [ ] The T2 tests of this milestone pass in the AndroidCustom suite on the reference Mac. They are the audio and microphone tests, App Translocation of a distribution wrapper, the security tests of #091, the accessibility audit, and the pseudo-language run.
- [ ] The nightly T3 jobs `fuzz-long`, `compatibility`, and `notarize` pass. The v1.0 checklist C10-1 to C10-10 ([../test-strategy.md](../test-strategy.md) §8.7) is complete.
- [ ] Each of these requirements has its tasks done and its verification recorded in [../traceability.md](../traceability.md) §2:
  - FR-INT-07 and FR-INT-08;
  - the distribution part of FR-WRP-10;
  - NFR-SEC-01 to NFR-SEC-07;
  - NFR-L10N-01 and NFR-L10N-02.
- [ ] Perf numbers for the milestone are recorded ([../roadmap.md](../roadmap.md) §4 item 4). They include:
  - the audio output latency and the underrun result ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.1);
  - a full `apkrun-perf` run on the v1.0 candidate, with no NFR miss or with an ADR that records the measured numbers.
- [ ] [../risks.md](../risks.md) is reviewed:
  - R-10 (#093) and R-17 (#088) have results and updated statuses;
  - R-02, R-09, and R-15 are updated with the compatibility results of #090;
  - no `open` High-impact risk remains without an accepted fallback.
- [ ] The microphone prompt timing is settled and recorded. It is an open item of [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §16 and [../../02-design/vm.md](../../02-design/vm.md) §11.
- [ ] No Decision in [../open-questions.md](../open-questions.md) with a deadline at or before v1.0 is open. This includes OQ-01, because the production host serves the appcast and the image feed.
- [ ] The design documents describe what was built:
  - [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8;
  - [../../02-design/vm.md](../../02-design/vm.md) §11;
  - [../../02-design/wrapper.md](../../02-design/wrapper.md) §11;
  - [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §10;
  - [../../02-design/host-ui.md](../../02-design/host-ui.md) §13;
  - [../../01-architecture/security-model.md](../../01-architecture/security-model.md);
  - [../../05-development/build-system.md](../../05-development/build-system.md) §3, §11, §12, §15;
  - [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md);
  - the new entries in [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) and [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- [ ] #094 checks the v1.0 Definition of Done (the ten release criteria of [../roadmap.md](../roadmap.md) §3.6), and v1.0 is tagged.

## Task order

1. #083 Audio output.
2. #084 Microphone (after #083).
3. #088 Developer ID signing, notarization, and distribution wrappers. **Parallel.**
4. #090 Compatibility database. **Parallel.**
5. #091 Security hardening and fuzzing. **Parallel.**
6. #092 Localization and accessibility. **Parallel.**
7. #093 Legal and licensing compliance. **Parallel.**
8. #094 v1.0 release readiness (last).

Every dependency of #083, #088, #090, #091, #092, and #093 is in an earlier milestone. These six can start together. #084 waits for #083.

Several tasks touch the same shared files. Merge those files often:
- `Packages/DiagnosticsCore/ErrorCatalog/errors.json`;
- the String Catalogs;
- `Daemon/apkrund/` (#084 Info.plist and entitlements, #091 review);
- [../../01-architecture/security-model.md](../../01-architecture/security-model.md) (#084 entitlement, #091 review items);
- `ThirdParty/ThirdParty.lock.json` (#091, #093);
- `.github/workflows/nightly.yml`.

#092 translates every string that exists when it merges. After that, its catalog check fails Release builds on untranslated entries. Every later pull request, including those of #083, #084, #088, and #090, then adds its Japanese text in the same pull request.

---

## #083 Audio output

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #035 |
| Requirements | FR-INT-07, NFR-CMP-01 |
| Design | [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §2.2, §2.4, §8.1, §8.3, §14 (#083), §15; [../../02-design/vm.md](../../02-design/vm.md) §2, §4, §11; [../../02-design/android-image.md](../../02-design/android-image.md) §7.5, §9, §11; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.4; [../../02-design/host-ui.md](../../02-design/host-ui.md) §9.2; [../../02-design/cli.md](../../02-design/cli.md) §4.6; [../test-strategy.md](../test-strategy.md) §4.2 |
| Modules / paths | VirtualMachineCore (`SoundDefinition` → `VZVirtioSoundDeviceConfiguration`); ImageCore (`AndroidBootPlanner`, `BootOptions.soundOutput`); RuntimeCore and IntegrationCore (`AudioPolicy`, output part); `Apps/APKRun/Features/Settings/` (Runtime pane); `Guest/product/` (only if the image lacks `virtio_snd` or the HAL setup); `Tests/Fixtures/AndroidApps/` (HelloAudio); `Tests/IntegrationTests/DesktopIntegrationTests/`; `Tests/AcceptanceTests/AudioLoopback/` |
| Risks / questions | OQ-38 (`virtio_snd` in the stock kernel; working default: add the module in the custom image if missing). Open items: [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §16 |

### Goal

Android apps play sound on the Mac through one virtio-snd output stream. The stream goes to the current macOS default output device. `audio.output = false` leaves the sound device out at the next Android start. Latency, underruns, and the negotiated format are measured and recorded.

### Scope

- One `VZVirtioSoundDeviceConfiguration` with one output stream to `VZHostAudioOutputStreamSink`. It is attached while `audio.output` is `true` (the default) ([../../02-design/vm.md](../../02-design/vm.md) §11).
- The global key `audio.output`. It applies at the next runtime start through `BootOptions.soundOutput` and `SoundDefinition(output:input:)` ([../../02-design/android-image.md](../../02-design/android-image.md) §9.2).
- Settings → Runtime "Sound output" with **Restart Android Now** ([../../02-design/host-ui.md](../../02-design/host-ui.md) §9.2). `apkrun config set audio.output …` says that the change applies at the next Android start ([../../02-design/cli.md](../../02-design/cli.md) §4.6).
- The guest checks of [../../02-design/android-image.md](../../02-design/android-image.md) §7.5:
  - `virtio_snd` is loaded or built in;
  - `/proc/asound/cards` shows the card;
  - the goldfish audio HAL uses it;
  - the negotiated rate and format are logged.
  - If a part is missing, the custom image adds it (§11).
- The HelloAudio fixture (`io.apkrun.fixture.helloaudio`, [../test-strategy.md](../test-strategy.md) §4.2), if it does not exist yet. It has the tone, the sweep, the click track, and the 5 s recording that #084 uses.
- Measurement of latency (target ≤ 120 ms, provisional), underruns (none in 10 minutes with the VM otherwise idle), and the negotiated format ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.1).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - The microphone and the input stream (#084).
  - Per-app mute, Now Playing, and media keys. They are post-v1 ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §16).
  - Host-side mixing or per-app volume. Android mixes all apps into one stream.
  - Choosing an output device in APKRun. macOS's default output device is used, and changes to it are followed.

### Deliverables

- The sound device mapping in VirtualMachineCore, with T0 tests.
- `audio.output` → `BootOptions.soundOutput` in RuntimeCore, read before each boot.
- The "Sound output" row in `Apps/APKRun/Features/Settings/`.
- HelloAudio in `Tests/Fixtures/AndroidApps/`. It is a plain APK signed with `test-fixture-a.jks` ([../../05-development/build-system.md](../../05-development/build-system.md) §8.1). It logs `play <name>` and `recorded <frames> <peak>`.
- `AudioOutputTests` in `Tests/IntegrationTests/DesktopIntegrationTests/`.
- `Tests/AcceptanceTests/AudioLoopback/` with the loopback capture and the latency measurement.
- Image changes in `Guest/product/`, only if the checks of step 3 find a missing part.
- Recorded results in [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.1 and [../../02-design/android-image.md](../../02-design/android-image.md) §7.5.

### Implementation steps

The design steps are [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §14 #083, steps 1–2. Design step 1 is split into steps 1–4 here. Design step 2 is step 5.

1. **Sound device** (design step 1; [../../02-design/vm.md](../../02-design/vm.md) §4, §11).
   - Map `SoundDefinition` in VirtualMachineCore. `output == true` gives one `VZVirtioSoundDeviceConfiguration` with one `VZVirtioSoundDeviceOutputStreamConfiguration` whose sink is `VZHostAudioOutputStreamSink`.
   - `sound == nil` gives no sound device. `input` stays `false` until #084.
   - Check: T0 tests of the configuration builder. Output only gives one device with one output stream. `nil` gives no sound device. The `.frameworkRejected` validation passes for the output-only configuration.
2. **`audio.output` and the boot options** (design step 1; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.4; [../../02-design/android-image.md](../../02-design/android-image.md) §9.2).
   - RuntimeCore reads `audio.output` before each boot and sets `BootOptions.soundOutput`. `AndroidBootPlanner` maps it to `SoundDefinition(output:input:)`.
   - A change while Android runs does not touch the running VM. Settings → Runtime shows "Sound output" with **Restart Android Now**. The CLI prints that the key applies at the next Android start.
   - Check: a T0 test with a fake store. Changing the key while Android runs keeps the running `VMDefinition`. The next boot's definition follows the key.
3. **Guest audio path** (design step 1; [../../02-design/android-image.md](../../02-design/android-image.md) §7.5, §11).
   - On the custom image, check four things: `virtio_snd` is loaded (`lsmod`) or built in, `/proc/asound/cards` shows the card, `ro.hardware.audio.primary` is `goldfish`, and the HAL opens the tinyalsa card.
   - If a part is missing, add it to `Guest/product/` and rebuild the image through the #035 product.
   - Check: a T2 test finds the card through `AdbClient`.
4. **HelloAudio fixture** ([../test-strategy.md](../test-strategy.md) §4.2).
   - If the fixture does not exist, add it to the Gradle project in `Tests/Fixtures/AndroidApps/`. It has buttons and intents for:
     - a 1 kHz tone;
     - a sweep;
     - a click track (one click per second);
     - a 5 s recording that shows the level.
   - It logs `play <name>` when playback starts and `recorded <frames> <peak>` after a recording.
   - Check: `scripts/check-fixtures.sh` passes, and the APK installs on the custom image.
5. **Acceptance and measurement** (design step 2; [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.3 #083).
   - T2: HelloAudio plays the tone. During playback the test reads `/proc/asound/card*/pcm*p/sub0/hw_params` and `status` through `AdbClient`. It asserts that the stream is running and logs the negotiated rate and format.
   - T3 on a lab Mac whose default output is a virtual loopback audio device:
     - Capture the output and detect the 1 kHz tone and the sweep.
     - Measure the latency as the click onset in the capture minus the time of the `play click` event. The event time is the guest wall clock, which #069 keeps in sync. Record the method and its error bound.
     - Play for 10 minutes with the VM otherwise idle. The capture has no gap inside the tone. The underrun counter of the playback track in `dumpsys media.audio_flinger` does not increase.
   - Switch the macOS default output device during playback, and check that the sound moves.
   - Do checklist item C10-5 ([../test-strategy.md](../test-strategy.md) §8.7).
   - Check: the acceptance criteria below. The numbers are recorded in [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.1.

### Tests

- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`, `Packages/ImageCore/Tests/ImageCoreTests/`, `Apps/APKRun/Tests/`):
  - the sound configuration builder (step 1);
  - `audio.output` → `BootOptions` → `SoundDefinition`, next boot only (step 2);
  - the Settings row model.
- **T1**: none ([../test-strategy.md](../test-strategy.md) §6.13).
- **T2** (`Tests/IntegrationTests/DesktopIntegrationTests/AudioOutputTests`, AndroidCustom suite):
  - the card is present;
  - HelloAudio opens an output stream through `virtio_snd`;
  - the rate and format are logged;
  - after `audio.output = false` and a restart, Android has no sound card.
- **T3** (`Tests/AcceptanceTests/AudioLoopback/`):
  - the loopback capture, the latency, and the 10-minute underrun run, nightly on a lab Mac with a virtual audio device ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §15);
  - otherwise a manual check. Checklist C10-5.

### Acceptance criteria

- [ ] With `audio.output = true` (the default), the VM has one virtio-snd device with one output stream to `VZHostAudioOutputStreamSink`, and no input stream.
- [ ] On the custom image, `virtio_snd` is loaded or built in, `/proc/asound/cards` shows the card, and the goldfish HAL plays through it. The negotiated rate and format are logged ([../../02-design/android-image.md](../../02-design/android-image.md) §7.5).
- [ ] HelloAudio's 1 kHz tone and sweep are heard on the Mac's current default output device. When the default output device changes, the sound follows it.
- [ ] The output latency is measured with the click track and recorded. The target is ≤ 120 ms (provisional). A miss is recorded with the number and a follow-up task.
- [ ] A 10-minute playback with the VM otherwise idle has no underrun.
- [ ] `audio.output = false` leaves the sound device out at the next start and does not change the running VM. Settings offers **Restart Android Now**.
- [ ] Checklist item C10-5 is done: tone, sweep, and click track are heard, in sync.

### Notes

- Record the latency, the underrun result, and the rate and format in [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.1. Record the `virtio_snd` result in [../../02-design/android-image.md](../../02-design/android-image.md) §7.5.
- Record whether the stock image has `virtio_snd` in the support table of [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §2.4.
- The virtual audio device on the lab Mac is a runner prerequisite. The task picks one and documents its setup with the runner setup ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §6).
- macOS shows apkrund as the process that plays audio. This is expected (§8.1).

---

## #084 Microphone

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #083 |
| Requirements | FR-INT-08, NFR-SEC-03, NFR-SEC-05 |
| Design | [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §2.1–§2.4, §3.2, §8.2, §8.3, §11, §12, §13, §14 (#084), §15, §16; [../../02-design/vm.md](../../02-design/vm.md) §3, §11; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §5.3 (`audio.v1`), §7.1 (op 53), §8.1 (event 45); [../../02-design/guest-components.md](../../02-design/guest-components.md) §4.3, §5, §6.1; [../../02-design/host-ui.md](../../02-design/host-ui.md) §7.4, §9.4, §12; [../../05-development/build-system.md](../../05-development/build-system.md) §2.2, §12.2; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §3.2, §6 |
| Modules / paths | IntegrationCore (`AudioPolicy`, microphone part; `integrationStatus`, `activeRecordings`); RuntimeCore (`BootOptions.microphone`, `SetMicrophoneAccess` push); VirtualMachineCore (input stream); GuestProtocol (`audio.v1`); `Guest/guestd` (`MicrophoneGate`); `Guest/product/permissions/privapp-permissions-apkrun.xml`; `Daemon/apkrund/` (embedded Info.plist, `apkrund.entitlements`); RuntimeAPI; `Apps/APKRun/Features/AppPage/`, `Apps/APKRun/Features/Settings/`; `Apps/APKRunMenuBar/`; `Tests/IntegrationTests/DesktopIntegrationTests/`; `Tests/AcceptanceTests/AudioLoopback/` |
| Risks / questions | OQ-29 (prompt at VM start or at first capture; working default: attach the input stream only while a package uses the microphone). Open items: [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §16 |

### Goal

An Android app that the user allows can record from the Mac microphone. Every other package records silence. macOS asks for microphone permission once, for APKRun. The input stream exists only while at least one app has the microphone on. The menu bar shows which app is recording.

### Scope

- The input stream (`VZHostAudioInputStreamSource`) is attached only while at least one package has `integrations.microphone` in effect ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.2). Both the first-on change and the last-off change need a runtime restart, and the UI offers it.
- `NSMicrophoneUsageDescription` in apkrund's embedded Info.plist. `com.apple.security.device.audio-input` in `apkrund.entitlements` ([../../05-development/build-system.md](../../05-development/build-system.md) §12.2). The `.microphoneUsageDescriptionMissing` validation rule ([../../02-design/vm.md](../../02-design/vm.md) §3).
- Per-package gating with app ops. The Guest Agent's `MicrophoneGate` sets `OP_RECORD_AUDIO` to `MODE_IGNORED` for every user-installed package outside `SetMicrophoneAccess` (op 53). Listed packages get `MODE_ALLOWED` or the default. Android's own `RECORD_AUDIO` dialog still appears.
- Active recordings from `AudioManager.getActiveRecordingConfigurations`, sent as `RecordingChanged` (event 45). The host side:
  - `recordingChanged` on the `integrations` topic;
  - `activeRecordings()`;
  - the menu bar line "‹App› is using the microphone" and the microphone symbol ([../../02-design/host-ui.md](../../02-design/host-ui.md) §12).
- The macOS permission state:
  - in `integrationStatus`;
  - on the app page ([../../02-design/host-ui.md](../../02-design/host-ui.md) §7.4);
  - in Settings → Privacy with **Open System Settings** ([../../02-design/host-ui.md](../../02-design/host-ui.md) §9.4);
  - in the `integrations.microphone` health check (§13);
  - through the errors `microphonePermissionDenied` and `microphoneNeedsRestart` (§12).
- Verifying when macOS shows the prompt: at VM start or at the first capture.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Camera (FR-INT-10, 1.x).
  - Choosing an input device in APKRun. macOS's default input is used.
  - A usage description in wrappers. Wrappers have none ([../../02-design/wrapper.md](../../02-design/wrapper.md) §2.1).
  - Attaching or detaching the input stream without a restart. The VM configuration is fixed at start.

### Deliverables

- The input stream in VirtualMachineCore and the validation rule, with T0 tests.
- `AudioPolicy` (microphone part) computes the "in effect" set. RuntimeCore sets `BootOptions.microphone` and pushes `SetMicrophoneAccess`.
- `audio.v1` messages (op 53, event 45) in `Packages/GuestProtocol/proto/` with codec tests.
- `MicrophoneGate` in `Guest/guestd`, and the `MANAGE_APP_OPS_MODES` and `MODIFY_AUDIO_ROUTING` grants in `privapp-permissions-apkrun.xml`.
- `NSMicrophoneUsageDescription` in apkrund's Info.plist source in `Daemon/apkrund/`, and the entitlement in `Daemon/apkrund/apkrund.entitlements`. [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §3.2 is updated in the same pull request.
- `integrationStatus` (microphone), `activeRecordings`, and `recordingChanged` in RuntimeAPI and [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- The app page row, the Privacy pane row, and the menu bar indicator.
- The error codes, in English, in `errors.json` and [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md).
- `MicrophoneTests` in `Tests/IntegrationTests/DesktopIntegrationTests/`. The microphone part of `Tests/AcceptanceTests/AudioLoopback/`.

### Implementation steps

The design steps are [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §14 #084, steps 1–2. Design step 1 lists five parts: the input stream rule, the embedded usage description, app-ops gating, active-recording events, and the restart prompt. They are steps 1–5 here. Design step 2 is step 6.

1. **Input stream rule** (design step 1, "the input stream rule"; §8.2; [../../02-design/vm.md](../../02-design/vm.md) §11).
   - `AudioPolicy` computes the set of managed packages whose effective `integrations.microphone` is `true`. The effective value follows [../../03-reference/configuration.md](../../03-reference/configuration.md) §3.2, so `integrations.enabled.microphone = false` empties the set.
   - RuntimeCore sets `BootOptions.microphone` to "set is not empty" before each boot. VirtualMachineCore adds one input stream with `VZHostAudioInputStreamSource` to the #083 device.
   - Check: T0 tests of the set for these cases: global switch off, one package on, all packages off, and an unmanaged package (default off). A T0 builder test gives one output stream and one input stream when `input` is `true`.
2. **Embedded usage description and entitlement** (design step 1, "the embedded usage description"; [../../05-development/build-system.md](../../05-development/build-system.md) §2.2, §12.2).
   - Add `NSMicrophoneUsageDescription` to apkrund's Info.plist source in `Daemon/apkrund/`. `CREATE_INFOPLIST_SECTION_IN_BINARY` embeds it as `__TEXT,__info_plist`.
   - Add `com.apple.security.device.audio-input` to `apkrund.entitlements`. Update the apkrund row of [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §3.2 in the same pull request.
   - The `build` job checks the Release binary. `otool -s __TEXT __info_plist` must show the key, and `codesign -d --entitlements -` must show the entitlement.
   - Check: the build check passes. A T0 test shows that `sound.input = true` without the key fails with `.microphoneUsageDescriptionMissing`.
3. **App-ops gating in the agent** (design step 1, "app-ops gating in the agent"; §8.2; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1 op 53; [../../02-design/guest-components.md](../../02-design/guest-components.md) §5).
   - Add `SetMicrophoneAccess(repeated string packages)` under `audio.v1` with `Hello` capability reporting.
   - `MicrophoneGate` sets `OP_RECORD_AUDIO` to `MODE_IGNORED` for every user-installed package that is not listed. Listed packages get `MODE_ALLOWED` or the default.
   - The gate applies the last list again on `PACKAGE_ADDED`, so a newly installed app is gated at once. It also applies it again after each reconnect, because RuntimeCore pushes the list after every handshake (§3.2).
   - Grant `MANAGE_APP_OPS_MODES` in `privapp-permissions-apkrun.xml`.
   - Check: a Kotlin T0 test of the mode table against a fake `AppOpsManager`. T2: `appops get <pkg> RECORD_AUDIO` shows `ignore` for an unlisted package and `allow` or `default` for a listed one.
4. **Active-recording events** (design step 1, "active-recording events"; §8.2, §11; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §8.1 event 45).
   - `MicrophoneGate` registers an `AudioManager.AudioRecordingCallback`. It sends `RecordingChanged(packages)` with the package names from `getActiveRecordingConfigurations`. Grant `MODIFY_AUDIO_ROUTING`, because without it the list is anonymized.
   - IntegrationCore publishes `recordingChanged([PackageID])` on the `integrations` topic and serves `activeRecordings()`. The menu bar shows "‹App› is using the microphone" and marks the app with the microphone symbol ([../../02-design/host-ui.md](../../02-design/host-ui.md) §12).
   - Check: a T0 model test of the menu bar with a fake event stream. T2: `recordingChanged` names HelloAudio while it records and is empty afterwards.
5. **Restart prompt and permission state** (design step 1, "the restart prompt"; §8.2, §11–§13; [../../02-design/host-ui.md](../../02-design/host-ui.md) §7.4, §9.4).
   - The app page shows "Android needs to restart to use the microphone." with **Restart Android Now** and **Later** when the first app turns the microphone on. The last-off change shows the same kind of prompt, so the input stream is removed.
   - `integrationStatus` reports the macOS permission of apkrund. apkrund reads it with `AVCaptureDevice.authorizationStatus(for: .audio)`.
   - The app page and Settings → Privacy show the state. Denied shows how to allow it, with **Open System Settings**.
   - The `integrations.microphone` check warns when permission is denied or a restart is pending. Add `microphonePermissionDenied` and `microphoneNeedsRestart`.
   - Check: T0 model tests of the prompt for first-on and last-off, and of the denied state. A T0 test of the health check.
6. **Acceptance** (design step 2; §8.3 #084).
   - Turn the microphone on for HelloAudio, and restart. Record 5 s while a test signal plays into the virtual input device. The level follows the signal.
   - Turn it off for HelloAudio and on for another package. The HelloAudio recording is silent.
   - With macOS permission denied, the app page shows how to allow it.
   - Record when the macOS prompt appears: at VM start or at the first capture. Do checklist item C10-4.
   - Check: the acceptance criteria below.

### Tests

- **T0** (`Packages/IntegrationCore/Tests/IntegrationCoreTests/`, `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`, `Packages/GuestProtocol/Tests/GuestProtocolTests/`, `Guest/guestd/src/test/`, `Apps/APKRun/Tests/`, `Apps/APKRunMenuBar/Tests/`):
  - the "in effect" set;
  - the input stream builder and the validation rule;
  - the `audio.v1` codec round trip;
  - the app-ops mode table;
  - the restart prompt, the denied state, and the menu bar indicator.
- **T1**: none ([../test-strategy.md](../test-strategy.md) §6.13).
- **T2** (`Tests/IntegrationTests/DesktopIntegrationTests/MicrophoneTests`, AndroidCustom suite):
  - a 5 s recording by HelloAudio with the microphone on has a non-zero peak;
  - another package records silence (peak 0);
  - the input stream is absent when no package has the microphone on;
  - `recordingChanged` names the recording package.
  - The lab Mac grants microphone access to `io.apkrun.apkrund.dev` once, by hand ([../test-strategy.md](../test-strategy.md) §3.6). A missing grant fails the test with `runnerMissingPermission`.
- **T3** (`Tests/AcceptanceTests/AudioLoopback/`):
  - with a virtual input device, the level follows a test signal, nightly where the runner has the device;
  - otherwise a manual check;
  - checklist C10-4 records the prompt timing.

### Acceptance criteria

- [ ] With the microphone on for HelloAudio and macOS permission granted, HelloAudio's 5 s recording follows a test signal.
- [ ] With the microphone off for HelloAudio and on for another package, HelloAudio records silence. Android's own `RECORD_AUDIO` dialog still appears in the app's window.
- [ ] With no package using the microphone, the VM has no input stream. The first-on change and the last-off change each offer **Restart Android Now**.
- [ ] macOS asks for microphone permission once, for APKRun. Wrappers carry no usage description.
- [ ] apkrund's Release binary embeds `NSMicrophoneUsageDescription` and carries `com.apple.security.device.audio-input`. [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §3.2 lists the entitlement.
- [ ] With macOS permission denied, the app page shows how to allow it, and `integrations.microphone` warns.
- [ ] While an app records, the menu bar shows "‹App› is using the microphone".
- [ ] Checklist item C10-4 is done. When the prompt appears (VM start or first capture) is recorded in [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.2 and [../../02-design/vm.md](../../02-design/vm.md) §11.

### Notes

- Close the open item of [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §16 and the open question in [../../02-design/vm.md](../../02-design/vm.md) §11 with the result.
- Record which name the macOS prompt shows for apkrund. Record whether the usage text appears in Japanese when the Mac is set to Japanese (#092).
- Microphone contents and recording levels never go into logs or diagnostics bundles (NFR-SEC-05). Log package IDs only.
- Pitfall: the app-ops mode must be re-applied for newly installed packages. Otherwise an app installed after the last push records from the Mac.

---

## #088 Developer ID signing, notarization, and distribution wrappers

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #062, #046 |
| Requirements | FR-WRP-10 (distribution part), FR-WRP-06, NFR-SEC-07 |
| Design | [../../02-design/wrapper.md](../../02-design/wrapper.md) §7.4, §10.2, §11, §12, §13, §15 (#088), §16, §17; [../../05-development/build-system.md](../../05-development/build-system.md) §3.1, §11, §12, §15.1; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §6.4; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §3.1, §3.2, §7; [../../05-development/workflow.md](../../05-development/workflow.md) §9; [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) |
| Modules / paths | WrapperCore (`WrapperSigner` Developer ID path, `DistributionWrapperBuilder`); RuntimeHost (`buildDistributionWrapper` on `.control`); RuntimeAPI; `CLI/apkrun/Commands/` (`wrap --distribution`); `scripts/release/` (`assemble-bundle.sh`, `sign-bundle.sh`, `notarize.sh`, `make-dmg.sh`, `check-release-build.sh`); `.github/workflows/release.yml`, `nightly.yml` (`notarize`); `Tests/IntegrationTests/WrapperTests/`; `Tests/AcceptanceTests/` |
| Risks / questions | R-17. OQ-25 (self-updating distribution wrappers; deferred to post-v1, working default: registry trust by cdhash). Open items: [../../02-design/wrapper.md](../../02-design/wrapper.md) §17 |

### Goal

The Release build of APKRun.app is Developer ID signed with Hardened Runtime and a secure timestamp. It is notarized and stapled, and it ships in a notarized DMG. `apkrun wrap <package> --distribution` produces a Developer ID signed, optionally notarized wrapper. On a clean Mac, that wrapper opens after the standard Gatekeeper confirmation.

### Scope

- Release signing inside out with the Developer ID through `scripts/release/sign-bundle.sh`, which #057 created ([../../05-development/build-system.md](../../05-development/build-system.md) §12.3). Release assembly with `assemble-bundle.sh` (§11).
- `scripts/release/notarize.sh` and `scripts/release/make-dmg.sh` ([../../05-development/build-system.md](../../05-development/build-system.md) §12.6), in the keychain-profile form on a Mac and the API-key form in CI.
- The notarization steps of the `release.yml` workflow that #057 created, up to a notarized, stapled DMG and a Sparkle archive made from the stapled app ([../../05-development/workflow.md](../../05-development/workflow.md) §9). It runs every check of `check-release-build.sh`, including R1, R5, and R6 ([../../05-development/build-system.md](../../05-development/build-system.md) §3.1).
- The nightly `notarize` job: the Release app and a HelloText distribution wrapper ([../../05-development/build-system.md](../../05-development/build-system.md) §15.1).
- Distribution wrappers ([../../02-design/wrapper.md](../../02-design/wrapper.md) §11):
  - the six-step flow;
  - `buildDistributionWrapper` on the control endpoint (long-running);
  - `apkrun wrap <package> --distribution --identity … [--notarize --keychain-profile …] [--output …]`;
  - the tool checks;
  - the legal confirmation;
  - the errors `distributionToolMissing`, `identityNotFound`, and `notarizationFailed`.
- The recipient flow: quarantine, Gatekeeper, the move to Applications when translocated (§7.4), approval with the Developer ID team, and the bootstrap install (§10.2).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Self-updating distribution wrappers and registry trust by Developer ID team (post-v1, [../../02-design/wrapper.md](../../02-design/wrapper.md) §17). v1 trusts wrappers by cdhash.
  - A GUI for distribution wrappers. v1 has the CLI only.
  - Storing Apple ID passwords. APKRun uses `notarytool store-credentials` profiles only.
  - Publishing the appcast and the image feed. That belongs to #057, #087, and #094. The production host is OQ-01.
  - Extra entitlements for the launcher. It needs none.

### Deliverables

- `sign-bundle.sh` (extended; #057 created it), `assemble-bundle.sh`, `notarize.sh`, and `make-dmg.sh` in `scripts/release/`.
- The notarization and DMG steps and a manual dry-run input that stops before publishing, added to the `release.yml` of #057, and the nightly `notarize` job.
- `DistributionWrapperBuilder` in WrapperCore and the Developer ID path of `WrapperSigner`. Both run tools through `Process` with absolute paths ([../../05-development/coding-conventions.md](../../05-development/coding-conventions.md) §13).
- `buildDistributionWrapper(DistributionWrapperRequest)` → `DistributionWrapperResult` in RuntimeAPI, RuntimeHost, and [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- `apkrun wrap --distribution` in the CLI, with golden files.
- The three error codes, in English, in `errors.json` and [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md).
- `DistributionWrapperTests` (App Translocation) in `Tests/IntegrationTests/WrapperTests/`.
- The R-17 result in [../risks.md](../risks.md).

### Implementation steps

The design steps are [../../02-design/wrapper.md](../../02-design/wrapper.md) §15 #088, steps 1–2. Steps 1–3 here are the release signing of [../../05-development/build-system.md](../../05-development/build-system.md) §12. Steps 4–6 are design step 1. Step 7 is design step 2.

1. **Release signing** ([../../05-development/build-system.md](../../05-development/build-system.md) §11, §12.1–§12.3).
   - `assemble-bundle.sh` runs `xcodebuild -configuration Release` with `CODE_SIGNING_ALLOWED=NO`. `sign-bundle.sh <APKRun.app> <identity>` signs in the order of [../../05-development/build-system.md](../../05-development/build-system.md) §12.3 with `--force --sign "$IDENTITY" --options runtime --timestamp` and the entitlements of [../../05-development/build-system.md](../../05-development/build-system.md) §12.2. It never uses `--deep`.
   - Confirm the Sparkle nested-code paths for the pinned version. The script fails if a Mach-O file is left unsigned.
   - Check: `codesign --verify --strict --deep --verbose=2 APKRun.app` passes. `codesign -d --entitlements -` shows only the §12.2 entitlements for each binary. `scripts/check-launcher.sh` passes on the signed launcher.
2. **Notarization and DMG** ([../../05-development/build-system.md](../../05-development/build-system.md) §12.6; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §6.4).
   - `notarize.sh <path>` zips with `ditto -c -k --keepParent`, submits with `xcrun notarytool submit … --wait`, and staples. It then runs `spctl --assess --type execute -vv`.
   - It uses the keychain profile `apkrun-notary` on the lab Mac and `--key`, `--key-id`, and `--issuer` in CI.
   - `make-dmg.sh` builds `APKRun-<version>.dmg` with `hdiutil create -format UDZO`, signs it with the Developer ID, then notarizes and staples it.
   - Check: on the lab Mac, `spctl --assess --type execute -vv APKRun.app` reports "Notarized Developer ID". `xcrun stapler validate` passes for the app and the DMG.
3. **Release workflow and nightly job** ([../../05-development/build-system.md](../../05-development/build-system.md) §3.1, §15.1; [../../05-development/workflow.md](../../05-development/workflow.md) §9).
   - Extend the `release.yml` that #057 created ([../../05-development/workflow.md](../../05-development/workflow.md) §9.7). It runs on tags `v*` in environment `release`. It assembles, signs, runs `check-release-build.sh` with every row including R1, R5, and R6, notarizes and staples the app, and builds the DMG (workflow §9.4 steps 7–8).
   - The Sparkle archive `APKRun-<version>.zip` is now made from the stapled app (workflow §9.4 step 9), so an update installed by Sparkle is notarized too. The DMG and the archive contain the same signed bundle.
   - A manual dry-run input stops before anything is published.
   - Add the nightly `notarize` job in environment `signing`. Distribution wrappers are added to it in step 6.
   - Check: a dry run on `main` produces a stapled DMG and a green `check-release-build.sh`. Pull request jobs never receive the release secrets.
4. **Distribution builder** (design step 1; [../../02-design/wrapper.md](../../02-design/wrapper.md) §11 steps 1–3).
   - `DistributionWrapperBuilder` generates a portable wrapper in staging with `APKRunWrapperKind = distribution`. The wrapper is not placed and not registered.
   - `WrapperSigner` signs it with `codesign --force --sign "<identity>" --identifier <bundleID> --options runtime --timestamp`. It then verifies with `codesign --verify --strict` and `SecStaticCodeCheckValidity`.
   - The tool checks come before any work:
     - `xcrun --find notarytool` and `xcrun --find stapler`. A missing tool gives `distributionToolMissing`.
     - `security find-identity -v -p codesigning` for the identity. A missing identity gives `identityNotFound`.
   - Check: T0 tests with a fake process runner cover the argument lists, the missing-tool error, and the missing-identity error. A T1 test signs a wrapper with a test identity that it imports into a temporary keychain from `Tests/Fixtures/signing/test-*`, and verifies the seal.
5. **Notarization and output** (design step 1; §11 steps 4–6).
   - With `--notarize`, the builder zips with `ditto -c -k --keepParent`. It runs `xcrun notarytool submit <name>.zip --keychain-profile <profile> --wait --output-format json`.
   - `Accepted` leads to `xcrun stapler staple` and a new zip. `Invalid` gives `notarizationFailed(submissionID:summary:)`, with the summary taken from `notarytool log`.
   - Then `spctl --assess --type execute -vv` must report "source=Notarized Developer ID".
   - The output is `<dir>/<name>.app` and `<dir>/<name>.zip`. When apkrund cannot write `--output`, the CLI places the staged result itself, the same way as for local wrappers ([../../02-design/wrapper.md](../../02-design/wrapper.md) §6.3).
   - Check: T0 tests of the JSON result parsing (`Accepted`, `Invalid`, `In Progress` until timeout) with recorded `notarytool` outputs.
6. **API, CLI, and legal confirmation** (design step 1; §12, §13; [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md)).
   - Add `buildDistributionWrapper(DistributionWrapperRequest{packageID, identity, notarize, keychainProfile?, outputDirectory})` → `DistributionWrapperResult{appURL, zipURL, submissionID?, assessment}` to the control endpoint as a long-running operation with progress.
   - The CLI asks for the confirmation that the creator may redistribute the APK. `--yes` skips it. `--json` prints the result.
   - Add the nightly `notarize` step for a HelloText distribution wrapper.
   - Check: CLI golden files (human and JSON, including the three errors). The nightly job passes.
7. **Acceptance** (design step 2; §16).
   - Download a notarized `HelloText.app` zip with Safari on a clean test account. It opens after the standard "downloaded from the Internet" confirmation and shows no other Gatekeeper warning.
   - When translocated, it asks to move to Applications. It then asks for approval, showing the Developer ID team, and installs from the bootstrap. `spctl --assess` reports "Notarized Developer ID".
   - Do checklist items C10-6 and C10-7.
   - Check: the acceptance criteria below.

### Tests

- **T0** (`Packages/WrapperCore/Tests/WrapperCoreTests/`, `Packages/RuntimeAPI/Tests/RuntimeAPITests/`, `CLI/apkrun/Tests/`):
  - argument lists and errors with a fake process runner;
  - `notarytool` output parsing;
  - DTO round trips;
  - CLI golden files.
- **T1** (`Packages/WrapperCore/Tests/WrapperCoreSystemTests/`):
  - Developer ID-style signing and verification with a test identity in a temporary keychain;
  - `sign-bundle.sh` over a Release build signed with the test identity, then `codesign --verify --strict --deep`.
- **T2** (`Tests/IntegrationTests/WrapperTests/DistributionWrapperTests`, AndroidCustom suite): App Translocation with a quarantined copy, together with #056 ([../../02-design/wrapper.md](../../02-design/wrapper.md) §16): the move-to-Applications prompt, approval, and the bootstrap install.
- **T3**:
  - the nightly `notarize` job (Release app and HelloText distribution wrapper, `spctl`, `stapler validate`);
  - checklist items C10-6 (Safari download on a clean account) and C10-7 (`spctl --assess --type execute`, `stapler validate` on APKRun.app).

### Acceptance criteria

- [ ] The Release APKRun.app is Developer ID signed inside out with Hardened Runtime and a secure timestamp. `codesign --verify --strict --deep` passes, and no binary has an entitlement outside [../../05-development/build-system.md](../../05-development/build-system.md) §12.2.
- [ ] APKRun.app and `APKRun-<version>.dmg` are notarized and stapled. `spctl --assess --type execute` accepts the app, and `stapler validate` passes (C10-7).
- [ ] The release workflow runs `check-release-build.sh` with every check, including R1, R5, and R6, and a dry run stops before publishing.
- [ ] `apkrun wrap <package> --distribution --identity …` produces a Developer ID signed wrapper that passes `codesign --verify --strict`. With `--notarize`, it is stapled and `spctl` reports "Notarized Developer ID".
- [ ] Without `notarytool` or `stapler`, the command fails with `distributionToolMissing`. With an unknown identity it fails with `identityNotFound`. A rejected submission gives `notarizationFailed` with the submission ID and the log summary.
- [ ] The CLI asks for the redistribution confirmation, and `--yes` skips it.
- [ ] A notarized HelloText distribution wrapper downloaded with Safari on a clean account opens after the standard Gatekeeper confirmation. It asks to move to Applications when translocated, asks for approval, and installs from the bootstrap (C10-6).
- [ ] The nightly `notarize` job passes.

### Notes

- Record the R-17 result for distribution wrappers in [../risks.md](../risks.md) and update its status. M7 left this part to M12.
- #057 created `sign-bundle.sh` for the `ReleaseUpdateTest` bundles. Extend it; do not write a second script.
- Pitfall: signing must be the last write to a bundle. Stapling adds a ticket but does not change the seal. Any other change after signing breaks the seal.
- Pitfall: `notarytool` needs the Xcode Command Line Tools only on the creator's Mac. End users never need them.

---

## #090 Compatibility database

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #059 |
| Requirements | FR-OPS-06, FR-UI-02, FR-UI-03, FR-CLI-01, NFR-CMP-01 |
| Design | [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §10, §11 (#090), §12 (T1-10); [../../03-reference/configuration.md](../../03-reference/configuration.md) §3.2, §3.3; [../../02-design/host-ui.md](../../02-design/host-ui.md) §6.1, §7, §7.1; [../../02-design/cli.md](../../02-design/cli.md) §4.2; [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §8; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §8.3, §14.2; [../../00-product/scope.md](../../00-product/scope.md) §4; [../../05-development/build-system.md](../../05-development/build-system.md) §3, §11 |
| Modules / paths | APKStoreCore (`CompatibilityDatabase`, `PackageSettingsResolver`); RuntimeAPI (`CompatibilityInfo`); RuntimeHost (loading at start); `Apps/APKRun/Features/AddFlow/`, `Apps/APKRun/Features/AppPage/`; `CLI/apkrun/Commands/`; `Tests/Compatibility/` (`apps.json`, `compatibility.schema.json`, `database/compatibility.json`, `run-compatibility.sh`); `scripts/check-compatibility-db.sh`; `.github/ISSUE_TEMPLATE/app-compatibility.md`; `.github/workflows/nightly.yml` (`compatibility`) |
| Risks / questions | R-02, R-09, R-15. OQ-20 (visible side effects of health-check launches on the corpus apps; working default: keep the default health-check level). Open items: [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §13 |

### Goal

APKRun ships a signed-in-bundle compatibility database. For each known app it shows the level (Works, Works with limitations, Unsupported), the known issues, and the recommended settings. Recommendations apply without being written to the user's settings. An explicit user choice always wins. The database is advice and never blocks an install.

### Scope

- The format and schema of [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §10.2:
  - `packageID`;
  - `signerDigests`;
  - `versionCodes`, where the narrowest range wins;
  - `level`;
  - `issues`, in `en` and `ja`;
  - `recommendedSettings`, limited to the allowed keys;
  - `testedWith`;
  - `source`.
- `CompatibilityDatabase`, loaded by apkrund at start from `Contents/Resources/compatibility.json` (§10.1). The copy phase that puts it into the bundle ([../../05-development/build-system.md](../../05-development/build-system.md) §11).
- `PackageSettingsResolver` with the four rules of [../../03-reference/configuration.md](../../03-reference/configuration.md) §3.2, a source per value, and **Reset** back to the recommendation.
- `CompatibilityInfo{level, label, issues, recommendedKeys}` in RuntimeAPI. The `compatibility` field in the package DTOs and in `apkrun inspect` and `apkrun info <package>`.
- The UI:
  - the add flow's review with **Install Anyway** for `unsupported` ([../../02-design/host-ui.md](../../02-design/host-ui.md) §6.1);
  - the app page, General → Compatibility (§7.1);
  - "Recommended for this app" (§7).
- `Tests/Compatibility/`: the app list, the run, and proposals for maintainer review (§10.4). The first seed of the database, including the #029 results.
- The "App compatibility" issue template.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Downloading the database separately, or sending anything about installed apps. The file changes only with APKRun updates.
  - Blocking installs. Blocking stays in the inspection checks of [../../02-design/package-store.md](../../02-design/package-store.md) §4.6.
  - Fixing the app problems the runs find. They become follow-up tasks.
  - An in-app catalog for browsing apps ([../../02-design/host-ui.md](../../02-design/host-ui.md) §16).

### Deliverables

- `Tests/Compatibility/compatibility.schema.json`, `Tests/Compatibility/database/compatibility.json` (seeded), and `Tests/Compatibility/apps.json`.
- `scripts/check-compatibility-db.sh` in the `lint` job ([../../05-development/build-system.md](../../05-development/build-system.md) §3). It validates the database, rejects keys outside the allowed `recommendedSettings` set, and requires `en` and `ja` in every issue.
- `CompatibilityDatabase` (loader and matcher) and `PackageSettingsResolver` in APKStoreCore. Create the resolver, or extend it if #079 added one with a source field.
- `CompatibilityInfo` in RuntimeAPI and [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- The add flow, app page, and settings UI changes. The `compatibility` field in `inspect` and `info`, with golden files.
- `Tests/Compatibility/run-compatibility.sh`. It writes proposals to `Tests/Compatibility/out/`, which is git-ignored and uploaded as a CI artifact. The nightly `compatibility` job runs it.
- `.github/ISSUE_TEMPLATE/app-compatibility.md`.

### Implementation steps

The design steps are [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §11 #090, steps 1–5. Design step 1 is split into steps 1–3 here. Design steps 2–5 are steps 4–7.

1. **Schema and CI check** (design step 1, "schema"; §10.2).
   - Write `compatibility.schema.json` for the §10.2 format. Only the allowed `recommendedSettings` keys pass: `window.*`, `input.*`, `integrations.*` with the value `false` only, and `update.healthCheckLaunch`.
   - `check-compatibility-db.sh` validates `database/compatibility.json` against it.
   - Check: T0 schema tests with valid and invalid samples (an unknown key, `integrations.links: true`, a missing `ja`). The lint job fails on an invalid file.
2. **Loader and matcher** (design step 1, "`CompatibilityDatabase` loader and matcher"; §10.1, §10.2).
   - `CompatibilityDatabase` loads the bundled file once at apkrund start. It resolves the path from `Contents/Helpers/apkrund` to `Contents/Resources/`.
   - It matches entries by package ID, then by signer digest (when the entry lists digests), then by version range. When several entries match, the one with the narrowest range wins.
   - A missing or invalid file logs an error, and apkrund runs with an empty database.
   - Check: T0 test T1-10 of [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §12 (signer, version range, narrowest range wins). T0: a corrupt file gives an empty database and no crash.
3. **Settings resolution and the RuntimeAPI field** (design step 1, "`PackageSettingsResolver`, and the `compatibility` field in the RuntimeAPI package DTOs"; §10.3; [../../03-reference/configuration.md](../../03-reference/configuration.md) §3.2, §3.3).
   - `PackageSettingsResolver` returns the effective value and its source for each key. The first matching rule wins:
     1. a global switch that is off;
     2. the value in `settings.json`;
     3. the recommendation for the installed version;
     4. the built-in default.
   - Recommendations are never written. **Reset** removes the stored value. Values from the first record that equal the built-in default are not written.
   - `PackageStore.settings(for:)` uses the resolver, so policy and window code see the recommendation.
   - Add `CompatibilityInfo{level, label, issues, recommendedKeys}` to the package DTOs and to the `inspectFile` result.
   - Check: T0 resolution-order tests (T1-10) and DTO round trips. A T0 test shows that a first-record value equal to the default is not written.
4. **UI and CLI** (design step 2; [../../02-design/host-ui.md](../../02-design/host-ui.md) §6.1, §7, §7.1; [../../02-design/cli.md](../../02-design/cli.md) §4.2).
   - The add flow's review shows the label and the known issues. `unsupported` shows why and changes the button to **Install Anyway**.
   - The app page shows them under General. An app without an entry shows nothing.
   - Settings rows whose source is a recommendation show "Recommended for this app".
   - `apkrun inspect` and `apkrun info <package>` print the `compatibility` field in human and JSON form. `apkrun settings <package> list` shows the source of each value.
   - Check: T0 model tests for the three labels, no entry, and **Install Anyway**. CLI golden files.
5. **Runs and the first seed** (design step 3; §10.4; [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §8).
   - `run-compatibility.sh` reads `apps.json` (the fixture apps, the 50-APK F-Droid corpus, and the hand-installed sample). For each app it:
     - installs and launches it in the standard window mode;
     - checks for a non-blank first frame within 20 s;
     - runs `monkey` for 60 s with a fixed seed through ADB in developer mode;
     - checks the integrations the app uses;
     - repeats in the compatibility window mode when the standard mode fails.
   - It writes one proposal per app to `Tests/Compatibility/out/`.
   - A maintainer reviews the proposals and commits the seed, together with the #029 results. The nightly `compatibility` job runs the corpus.
   - Check: the first run over the corpus and the fixtures finishes. The committed seed passes the schema check.
6. **Issue template** (design step 4; §10.4).
   - Add `.github/ISSUE_TEMPLATE/app-compatibility.md`. It asks for the package ID, the version, the signer digest (from `apkrun info`), the level observed, the steps, and a diagnostics bundle. It states that a report becomes an entry only after a maintainer reproduces it.
   - Check: the template renders on GitHub with its fields.
7. **Acceptance** (design step 5).
   - An app with a `compatibilityMode` entry opens in the compatibility window mode without any user setting. A user's explicit choice overrides it.
   - An entry with a different signer digest does not apply.
   - The file ships in the release bundle and passes schema validation in CI.
   - Check: the acceptance criteria below.

### Tests

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Packages/RuntimeAPI/Tests/RuntimeAPITests/`, `CLI/apkrun/Tests/`, `Apps/APKRun/Tests/`):
  - T1-10 matching and the resolution order ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §12 labels it T1-10 at tier T0);
  - the schema tests;
  - the corrupt-file handling;
  - DTO round trips;
  - UI models;
  - CLI golden files.
- **T1** (`Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): loading from a built app bundle layout (`Contents/Helpers/apkrund` → `Contents/Resources/compatibility.json`).
- **T2** (`Tests/IntegrationTests/DiagnosticsTests/CompatibilityDatabaseTests`, AndroidCustom suite):
  - a test database with a `compatibilityMode` entry for a fixture opens it on display 0;
  - an explicit `window.mode` wins;
  - a wrong signer digest does not apply.
- **T3**: the `compatibility` job runs the corpus nightly and the full list before each release ([../test-strategy.md](../test-strategy.md) §7.4).

### Acceptance criteria

- [ ] An app with a `compatibilityMode` entry opens in the compatibility window mode without any user setting.
- [ ] A user's explicit choice overrides the recommendation. **Reset** returns to the recommendation, and settings show "Recommended for this app" for recommended values.
- [ ] An entry with a different signer digest does not apply. With several matching entries, the narrowest version range wins.
- [ ] `compatibility.json` ships in `Contents/Resources/` of the release bundle and passes schema validation in CI. Keys outside the allowed set are rejected.
- [ ] The add flow and the app page show the label and the known issues. `unsupported` apps can still be installed with **Install Anyway**. Apps without an entry show nothing.
- [ ] `apkrun inspect` and `apkrun info <package>` include the `compatibility` field.
- [ ] The corpus run proposes levels, and the reviewed seed is committed. The "App compatibility" issue template exists.

### Notes

- Record the corpus results in R-02, R-09, and R-15 of [../risks.md](../risks.md).
- The database is advice. If an entry would block something, the blocking rule belongs in [../../02-design/package-store.md](../../02-design/package-store.md) §4.6 instead.
- Proposals stay in `Tests/Compatibility/out/` until review. Never commit them straight into the database.

---

## #091 Security hardening and fuzzing

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #031, #034 |
| Requirements | NFR-SEC-01, NFR-SEC-02, NFR-SEC-03, NFR-SEC-04, NFR-SEC-05, NFR-SEC-06, NFR-SEC-07 |
| Design | [../../01-architecture/security-model.md](../../01-architecture/security-model.md); [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.2; [../../02-design/graphics.md](../../02-design/graphics.md) §5.4, §11; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §14, §16; [../../02-design/input.md](../../02-design/input.md) §9, §13; [../../02-design/package-store.md](../../02-design/package-store.md) §4, §14; [../../02-design/update-system.md](../../02-design/update-system.md) §6, §12; [../../03-reference/direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md); [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §6.4, §15; [../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §10; [../test-strategy.md](../test-strategy.md) §7.2; [../../05-development/build-system.md](../../05-development/build-system.md) §3.1, §15.2; [../../05-development/coding-conventions.md](../../05-development/coding-conventions.md) §11, §13 |
| Modules / paths | GraphicsCore (`VirtioGPUProtocol`, `ResourceTable`); GuestProtocol; `Guest/protocol`, `Guest/guestd`; APKStoreCore (`ContainerReader`, `APKInspector`, `APKSignatureVerifier`, the aapt2 output parser and sandbox profile); UpdateCore (provider parsers); RuntimeHost (XPC peer validation); IntegrationCore and RuntimeCore (host operations); `Packages/<Module>/Tests/<Module>Fuzz/`, `<Module>TestSupport`; `Tests/Fixtures/fuzz/<target>/`; `scripts/run-fuzz.sh`, `scripts/tool-versions.env`; `Tests/IntegrationTests/SecurityTests/`; `docs/01-architecture/security-model.md` |
| Risks / questions | None. Open items: none in [../../01-architecture/security-model.md](../../01-architecture/security-model.md). This task fills in its review items (§9) |

### Goal

Every trust boundary of [../../01-architecture/security-model.md](../../01-architecture/security-model.md) is reviewed, and the result is recorded in its review items (§9). Every parser of untrusted input has a fuzz target. `fuzz-short` runs in pull requests and `fuzz-long` runs nightly. The XPC and malicious-agent tests pass. v1.0 ships with no open fuzz crash and every review item closed.

### Scope

- The "Review items" section of [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §9 (SR-01…SR-11, one item per boundary), each closed with its evidence. [../roadmap.md](../roadmap.md) §3.6 item 5 refers to these items.
- The fuzzing infrastructure of [../../05-development/build-system.md](../../05-development/build-system.md) §15.2:
  - the pinned `SWIFT_FUZZ_TOOLCHAIN`;
  - `<Module>Fuzz` targets behind `APKRUN_FUZZ=1`;
  - Jazzer `@FuzzTest`;
  - `scripts/run-fuzz.sh`;
  - seed corpora;
  - reproducer replay in `<Module>SystemTests`;
  - the `fuzz-short` and `fuzz-long` jobs.
- The fuzz targets:
  - every target in the list of [../test-strategy.md](../test-strategy.md) §7.2;
  - the other parsers that the design documents assign to #091:
    - `ResourceTable` and a virgl command-stream fuzzer in a separate test process ([../../02-design/graphics.md](../../02-design/graphics.md) §11);
    - the aapt2 output parser ([../../02-design/package-store.md](../../02-design/package-store.md) §14);
    - the Direct manifest parser, the F-Droid index decoder and `entry.jar` parser, and the GitHub release decoder ([../../02-design/update-system.md](../../02-design/update-system.md) §12);
    - the injector's batch validator in Kotlin ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §16).
- The malicious-agent T2 test of host operations. It extends the #082 test build ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §15).
- The aapt2 `sandbox-exec` profile, which [package-store.md](../../02-design/package-store.md) §4 lists as a hardening item of this task.
- Complete tests for NFR-SEC-06 and NFR-SEC-07 ([../test-strategy.md](../test-strategy.md) §7.2).
- An audit of the [../../05-development/coding-conventions.md](../../05-development/coding-conventions.md) §13 rules over the code base:
  - every `// SECURITY:` entry point has a fuzz target or a test;
  - every `// UNSAFE:` block is reviewed;
  - overflow-checked arithmetic on guest values;
  - absolute tool paths.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Moving the renderer into a separate process (post-v1 research, [graphics.md](../../02-design/graphics.md) §11).
  - Signed Direct manifests (deferred to v1.x, [../open-questions.md](../open-questions.md) §5).
  - Fixing findings that need a design change. They become follow-up tasks (#098 and up). High-impact ones block v1.0.
  - Play Integrity or signature bypass of any kind (NFR-SEC-04). It is never implemented.

### Deliverables

- The review items in [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §9, all closed or linked to a follow-up task.
- `SWIFT_FUZZ_TOOLCHAIN` confirmed in `scripts/tool-versions.env`.
- `scripts/run-fuzz.sh` and the `fuzz-short` and `fuzz-long` jobs.
- One fuzz target per parser, each with:
  - its entry function in `<Module>TestSupport` (`package` access, [../../05-development/coding-conventions.md](../../05-development/coding-conventions.md) §3.3);
  - a seed corpus in `Tests/Fixtures/fuzz/<target>/`;
  - a replay test in `<Module>SystemTests`.
- Jazzer targets in `Guest/protocol` and `Guest/guestd`.
- The virgl command-stream fuzzer, run against the renderer in a separate test process.
- `MaliciousAgentTests` and `XPCClientValidationTests` in `Tests/IntegrationTests/SecurityTests/`. The ADB loopback test for NFR-SEC-06.
- The aapt2 sandbox profile in APKStoreCore, with a T1 test.
- The fixes for every crash and finding, each with its reproducer.

### Implementation steps

1. **Review items** ([../../01-architecture/security-model.md](../../01-architecture/security-model.md) §2–§8; [../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §10).
   - Fill in the "Review items" section (§9). It already lists one item (SR-01…SR-11) for each of these:
     - the XPC broker and endpoints;
     - the guest → host parsers (virtio-gpu, guest protocol, input);
     - the agent host operations (clipboard, notifications, links, files, microphone);
     - APK and container parsing, including aapt2;
     - provider parsing and the update validation pipeline;
     - APKRun and image updates;
     - signing, entitlements, and the release checks;
     - the custom image's SELinux, vsock, and privileged permissions;
     - ADB exposure;
     - secrets in logs and bundles;
     - keys and secrets storage.
   - Each item names its evidence (a test, a fuzz target, or a review note) and has a status.
   - Check: each item names its evidence and has a status.
2. **Fuzzing infrastructure** ([../../05-development/build-system.md](../../05-development/build-system.md) §15.2).
   - Confirm and pin `SWIFT_FUZZ_TOOLCHAIN`. `APKRUN_FUZZ=1` adds the `<Module>Fuzz` executables. Build them with `--sanitize=fuzzer --sanitize=address --sanitize=undefined`.
   - Write `scripts/run-fuzz.sh <target>|--changed|--all [--seconds <n>]` with `-timeout=10 -rss_limit_mb=2048 -artifact_prefix=build/fuzz/<target>/`.
   - Add `fuzz-short` (60 s per changed target) and `fuzz-long` (1 h per target, corpus merge with `-merge=1`).
   - Check: a deliberately planted crash on a throwaway branch fails `fuzz-short` and uploads the reproducer. `swift build` without `APKRUN_FUZZ` still works with Xcode's toolchain.
3. **Host protocol targets** ([../../02-design/graphics.md](../../02-design/graphics.md) §5.4, §11; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §14, §16).
   - `VirtioGPUProtocol` decoding with `ResourceTable`. The RiftVM limits (8192 px, 256 MiB buffers, 256 contexts) are enforced and have T0 tests.
   - The guest protocol frame decoder in Swift, with the limits of [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §14.
   - The virgl command-stream fuzzer runs against the renderer in a separate test process.
   - Check: each target runs 60 s without a crash. Seeds come from recorded frames and command streams. The T0 limit tests pass.
4. **Guest targets** ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §16; [../../02-design/input.md](../../02-design/input.md) §9, §13).
   - Jazzer `@FuzzTest` for the Kotlin frame decoder (`Guest/protocol`), the agent's `InputBatch` decoder, and the injector's batch validator (`Guest/guestd`).
   - Check: the targets run in the Gradle test run and in `fuzz-long`. Invalid batches are dropped and counted, never thrown past the decoder.
5. **APK and provider targets** ([../../02-design/package-store.md](../../02-design/package-store.md) §14; [../../02-design/update-system.md](../../02-design/update-system.md) §12; [../../03-reference/direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md)).
   - Targets:
     - the `ContainerReader` of APKStoreCore (ZIP, `.apks`, `.xapk`, `.apkm`, ADR-0017);
     - the APK Signing Block parser of `APKSignatureVerifier`;
     - the aapt2 output parser, seeded with recorded outputs;
     - the Direct manifest parser (1 MiB);
     - the F-Droid index decoder (64 MiB memory) and `entry.jar` parser;
     - the GitHub release decoder (4 MiB).
   - Each parser enforces its size limit before parsing.
   - Check: each target runs 60 s without a crash. An oversized input gives the typed error, never a trap.
6. **aapt2 sandbox** ([../../02-design/package-store.md](../../02-design/package-store.md) §4).
   - The profile is a string constant in APKStoreCore, passed with `sandbox-exec -p`. It denies network and writes, and allows reads only of the ticket directory and the tool.
   - If `sandbox-exec` is missing, aapt2 runs unsandboxed and a warning is logged, as designed.
   - Check: a T1 test runs a probe tool under the generated profile. Writes outside the ticket directory and a network connection are denied, and reading the ticket directory works.
7. **Malicious agent and XPC validation** ([../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §6.4, §15; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.2).
   - Extend the #082 malicious-agent test build into protocol fuzzing of host operations. It sends mutated requests for every agent → host operation and every integration payload, oversized frames, and floods above the rate limits.
   - The build is test-only and never part of a release image.
   - Complete the NFR-SEC-07 tests:
     - T1 authorization per endpoint;
     - T2: another signing identity is refused, a wrapper for another package gets `notAuthorized`, and a modified or re-signed wrapper is refused.
   - Complete NFR-SEC-06:
     - the ADB forward listens on `127.0.0.1` only (`lsof -nP -iTCP -sTCP:LISTEN`);
     - with developer mode off, nothing listens on vsock 5555.
   - Check: the T2 tests pass. apkrund survives the malicious agent with no crash, and every rejected request is counted.
8. **Code audit and long runs** ([../../05-development/coding-conventions.md](../../05-development/coding-conventions.md) §11, §13).
   - List every `// SECURITY:` entry point. Each one must have a fuzz target or a named test. Review every `// UNSAFE:` block.
   - Fix what fuzzing finds, adding each reproducer to `Tests/Fixtures/fuzz/<target>/`. File design-level findings as follow-up tasks.
   - Close the review items with their evidence.
   - Check: `fuzz-long` has run nightly for at least one week with no open crash. Every review item is closed or linked to a follow-up task that is not High impact.

### Tests

- **T0** (`<Module>Tests` of GraphicsCore, GuestProtocol, APKStoreCore, and UpdateCore):
  - the RiftVM limits in `ResourceTable`;
  - the size limits of every parser;
  - the typed errors for oversized and malformed input.
- **T1** (`<Module>SystemTests`, `Guest/protocol/src/test/`, `Guest/guestd/src/test/`):
  - all fuzz targets in `fuzz-short`;
  - the reproducer replay;
  - the aapt2 sandbox test;
  - the XPC authorization per endpoint.
- **T2** (`Tests/IntegrationTests/SecurityTests/`, AndroidCustom suite):
  - the malicious agent;
  - XPC client validation (another identity, another package, a modified or re-signed wrapper);
  - the ADB loopback-only check.
- **T3**: `fuzz-long` nightly, 1 h per target; the security review items closed ([../test-strategy.md](../test-strategy.md) §6.13).

### Acceptance criteria

- [ ] Every parser of untrusted input named in the Scope has a fuzz target with a seed corpus and a replay test. `fuzz-short` runs in every pull request that changes its code.
- [ ] `fuzz-long` runs nightly, and there is no open fuzz crash at release time.
- [ ] The RiftVM limits (8192 px, 256 MiB buffers, 256 contexts) are enforced in `ResourceTable`.
- [ ] The malicious-agent build causes no apkrund crash and no access outside a share or another package's data.
- [ ] XPC clients are validated: another signing identity is refused, a wrapper for another package gets `notAuthorized`, and a modified or re-signed wrapper is refused (NFR-SEC-07).
- [ ] The ADB forward listens on `127.0.0.1` only, and with developer mode off nothing listens on vsock 5555 (NFR-SEC-06).
- [ ] aapt2 runs under the `sandbox-exec` profile, which denies network and writes.
- [ ] Every `// SECURITY:` entry point has a fuzz target or a named test.
- [ ] The review items of [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §9 are closed, and none has an open High-impact finding.

### Notes

- Record the fuzz toolchain version in `scripts/tool-versions.env` and [../../05-development/build-system.md](../../05-development/build-system.md) §15.2.
- The fuzz table of [../test-strategy.md](../test-strategy.md) §7.2 lists every target of this task. A target added during the work is added to that table in the same pull request.
- A change to `// SECURITY:` code needs the security review of [../../05-development/workflow.md](../../05-development/workflow.md) §6.
- Findings that need more than a local fix become tasks #098 and up, filed with the label `security`. They are listed in the #094 evidence.

---

## #092 Localization and accessibility

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #077 |
| Requirements | NFR-L10N-01, NFR-L10N-02, FR-CLI-02 |
| Design | [../../02-design/host-ui.md](../../02-design/host-ui.md) §13, §13.1, §14 (#092), §15; [../../02-design/wrapper.md](../../02-design/wrapper.md) §5.9; [../../02-design/cli.md](../../02-design/cli.md) §6.1, §6.2, §6.3; [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §3; [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §12 (T1-4); [../../05-development/build-system.md](../../05-development/build-system.md) §2.5, §3; [../test-strategy.md](../test-strategy.md) §7.5, §8.7 |
| Modules / paths | `Apps/APKRun/Resources/` (`Localizable.xcstrings`, `InfoPlist.xcstrings`); `Apps/APKRunMenuBar/`; `Apps/APKRunLauncher/Localizable.xcstrings` and the generated `LauncherStrings.generated.swift`; `CLI/apkrun/` (`Localizable.xcstrings`, generated `CLIStrings.generated.swift`); `Packages/DiagnosticsCore/ErrorCatalog/errors.json`; `scripts/check-strings.sh`; `Tests/IntegrationTests/HostUITests/` |
| Risks / questions | None. Open items: [../../02-design/host-ui.md](../../02-design/host-ui.md) §16 |

### Goal

With the Mac set to Japanese, every screen of APKRun.app, the menu bar, the launcher, and every human CLI message is in Japanese. The pseudo-language run finds no truncation. APKRun.app is usable with VoiceOver and passes the accessibility audit. Release builds fail when a catalog has untranslated or stale entries.

### Scope

- Japanese for:
  - all String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`) of APKRun.app and APKRunMenuBar;
  - the launcher's compiled strings;
  - the CLI's human messages;
  - the `ja` text of every error code and remediation in `errors.json`.
- Plural variants, `ByteCountFormatter`, and `Date.FormatStyle` wherever the English strings need them ([../../02-design/host-ui.md](../../02-design/host-ui.md) §13).
- The terms of §13.1, with one fixed Japanese term for each.
- The catalog check for Release builds. The pseudo-language run with `-AppleLanguages "(en-XA)"`.
- Accessibility:
  - a label on every control, and text labels on icon-only buttons;
  - no status shown by colour alone;
  - full keyboard operation of the main window, sheets, and Settings;
  - `performAccessibilityAudit()` over the main screens.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Languages other than English and Japanese.
  - Accessibility inside Android apps ([../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7).
  - Android-side language behavior. #042, #071, and #085 test it.
  - Localizing JSON keys and error codes. They are never localized.

### Deliverables

- `ja` for every entry of every catalog, the launcher's and the CLI's compiled strings, and `errors.json`.
- The CLI's strings compiled into the executable. `CLIStrings.generated.swift` is generated from `CLI/apkrun/Localizable.xcstrings` by the same generator as `LauncherStrings.generated.swift`.
- `scripts/check-strings.sh` in the `lint` job. For the Release configuration it fails on an untranslated, stale, or `needs review` entry.
- The pseudo-language run and the accessibility audit in `Tests/IntegrationTests/HostUITests/`.
- A Japanese column in the terms table of [../../02-design/host-ui.md](../../02-design/host-ui.md) §13.1.
- CLI golden files in Japanese for the #075 and #059 tests.

### Implementation steps

The design steps are [../../02-design/host-ui.md](../../02-design/host-ui.md) §14 #092, steps 1–3. Design step 1 is split into steps 1–3 here. Design step 2 is steps 4–5, and design step 3 is steps 6–7.

1. **String inventory and terms** (design step 1; §13, §13.1).
   - Check that every user-facing string of APKRun.app, APKRunMenuBar, the launcher, and the CLI comes from a catalog key. Error texts must come from error catalog keys.
   - Replace string concatenation with format strings and plural variants. Use the formatters of §13.
   - Add the Japanese term for each row of §13.1.
   - Check: a T0 test fails on any string literal passed to a user-facing text API outside the catalogs (a lint rule or test over the sources). The terms table has a Japanese column.
2. **Japanese translations** (design step 1, "Japanese translations for all catalogs").
   - Translate `Localizable.xcstrings` and `InfoPlist.xcstrings` of APKRun.app and APKRunMenuBar, and the `ja` fields of `errors.json`, using the §13.1 terms.
   - Check: every catalog entry has a `translated` `ja` value. T0 test T1-4 (Japanese part, [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §12) passes: every error code has `ja` text with the declared placeholders.
3. **Launcher and CLI strings** (design step 1, "the launcher's compiled strings, and the CLI"; [../../02-design/wrapper.md](../../02-design/wrapper.md) §5.9; [../../02-design/cli.md](../../02-design/cli.md) §6.1).
   - Translate `Apps/APKRunLauncher/Localizable.xcstrings`. The generator writes both languages into `LauncherStrings.generated.swift`.
   - Move the CLI's human strings into `CLI/apkrun/Localizable.xcstrings` and generate `CLIStrings.generated.swift`. The CLI picks the language from the user's preferred languages, and `--json` output is never localized.
   - Check: T0 golden files in Japanese for every human message of the #075 and #059 tests ([../../02-design/cli.md](../../02-design/cli.md) §6.3). `scripts/check-launcher.sh` still passes.
4. **Catalog check** (design step 2, "the catalog CI check").
   - `scripts/check-strings.sh` reads every `.xcstrings` file and `errors.json`. For Release it fails on a missing `ja` value, a `stale` entry, or a `needs review` entry. Debug builds only warn.
   - Check: the `lint` job fails on a test catalog with one untranslated entry.
5. **Pseudo-language run** (design step 2, "the pseudo-language UI run"; §15).
   - Run the main screens with `-AppleLanguages "(en-XA)"` (double-length strings) in `Tests/IntegrationTests/HostUITests/`. The screens are onboarding, home, the add flow, the app page, Settings, uninstall, approval, and the menu bar. Save screenshots as artifacts.
   - Check: no text is truncated or clipped. The test checks each label's frame against its text, and a maintainer reviews the screenshots (C10-2).
6. **Accessibility** (design step 3, "the accessibility audit passes"; §13).
   - Add missing accessibility labels. Give icon-only buttons text labels. Add text to every coloured status dot.
   - Make the main window, sheets, and Settings fully keyboard operable.
   - Run `performAccessibilityAudit()` over the main screens.
   - Check: the audit passes with no issue. C10-1 (VoiceOver walkthrough) is done.
7. **Acceptance** (design step 3).
   - With the Mac set to Japanese, check every screen of §4–§12 and every CLI message of the #075 and #059 tests.
   - Check: the acceptance criteria below.

### Tests

- **T0** (`Apps/APKRun/Tests/`, `CLI/apkrun/Tests/`, `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`):
  - every human CLI message in Japanese;
  - the error catalog in `en` and `ja` (T1-4);
  - the catalog-key lint;
  - the `check-strings.sh` behavior.
- **T1**: none ([../test-strategy.md](../test-strategy.md) §6.13).
- **T2** (`Tests/IntegrationTests/HostUITests/`): the accessibility audit and the pseudo-language run ([../../02-design/host-ui.md](../../02-design/host-ui.md) §15).
- **T3**: checklist items C10-1 (VoiceOver walkthrough of onboarding, home, add flow, per-app settings, Settings, and uninstall) and C10-2 (Japanese UI complete, no truncation, pseudo-language screenshots reviewed).

### Acceptance criteria

- [ ] With the Mac set to Japanese, every screen of [../../02-design/host-ui.md](../../02-design/host-ui.md) §4–§12 is in Japanese.
- [ ] With the Mac set to Japanese, every human CLI message of the #075 and #059 tests is in Japanese. JSON output is unchanged.
- [ ] The launcher's screens and prompts are in Japanese.
- [ ] Every error code and remediation has `en` and `ja` text.
- [ ] The pseudo-language run shows no truncation.
- [ ] A Release build fails when a catalog has an untranslated or stale entry.
- [ ] The accessibility audit passes. Every control has a label, and no status is shown by colour alone.
- [ ] The main window, sheets, and Settings are fully keyboard operable.
- [ ] Checklist items C10-1 and C10-2 are done.

### Notes

- Record in [../../02-design/desktop-integration.md](../../02-design/desktop-integration.md) §8.2 whether apkrund's microphone usage text appears in Japanese. apkrund is a bare executable with an embedded Info.plist, so the prompt may show English only.
- Strings added after this task need `ja` in the same pull request. The catalog check enforces it for Release builds.
- Pitfall: `-AppleLanguages "(en-XA)"` works only for strings that come from catalogs. A hard-coded string stays short and hides truncation.

---

## #093 Legal and licensing compliance

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | #020, #035 |
| Requirements | NFR-DEV-01 |
| Design | [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md); [../../05-development/build-system.md](../../05-development/build-system.md) §6.1–§6.3, §6.5, §6.8, §11; [../../02-design/android-image.md](../../02-design/android-image.md) §2.3, §10, §11; [../../02-design/graphics.md](../../02-design/graphics.md) §2; [../../02-design/wrapper.md](../../02-design/wrapper.md) §11; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §4; [../../01-architecture/decisions/0001-real-android-in-vm.md](../../01-architecture/decisions/0001-real-android-in-vm.md) |
| Modules / paths | `ThirdParty/ThirdParty.lock.json`; `scripts/release/generate-notices.py`; `scripts/check-licenses.sh`; `scripts/release/check-release-build.sh` (the notices row); `Apps/APKRun/` (Help menu item); `Guest/product/` (image notices); `Images/tools/` (bundle notice file); `docs/05-development/legal-and-licensing.md` |
| Risks / questions | R-10 |

### Goal

Every component that APKRun.app or the runtime image ships has a known, compatible license. The app and the image show their notices. Source offers exist for GPL and LGPL components. The legal checklist is complete before v1.0, and R-10 has a result.

### Scope

- The license inventory:
  - every entry of `ThirdParty/ThirdParty.lock.json` has `license`, `licenseFiles`, and `ships` ([../../05-development/build-system.md](../../05-development/build-system.md) §6.1);
  - the SwiftPM, Gradle, and Cargo locks are covered;
  - the Android image components are covered.
- A lint check that fails on a missing or unresolved license for any lock entry, and on a license outside the allowed list of [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) §4 for components APKRun distributes or uses as build/test tooling. A `reference` entry must still identify its license and commit the license file ([../../05-development/build-system.md](../../05-development/build-system.md) §6.8 step 3).
- `Contents/Resources/ThirdPartyNotices.html` from `generate-notices.py` ([../../05-development/build-system.md](../../05-development/build-system.md) §11). It includes notices for the virglrenderer, libepoxy, and ANGLE components (§6.3). Include RiftVM attribution only if RiftVM source is later copied or adapted and its lock entry is changed from `reference` to `derived`. APKRun.app shows the notices from the Help menu.
- The image notices:
  - the custom image shows its notices in Android Settings → About → Legal information;
  - the image bundle carries a notice file that lists the source offers for GPL and LGPL components, such as the kernel.
- The redistribution rules:
  - stock Google-built images are for development only ([../../02-design/android-image.md](../../02-design/android-image.md) §2.3);
  - GMS is not included ([../../01-architecture/decisions/0001-real-android-in-vm.md](../../01-architecture/decisions/0001-real-android-in-vm.md));
  - a review of the redistribution confirmation text of distribution wrappers (#088).
- The legal review and the compliance checklist in [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Replacing a component with a problematic license. That needs an ADR and a follow-up task.
  - Legal advice on the rights to APKs that users install or redistribute. The creator confirms these rights (#088).
  - Google Play and GMS licensing (#097, post-v1).

### Deliverables

- A complete license inventory, and `scripts/check-licenses.sh` in the `lint` job.
- `ThirdPartyNotices.html` generated in every build, and a **Third-Party Notices** item in APKRun.app's Help menu that opens it.
- The image notices in the custom image, and the bundle notice file with the source offers, listed in the manifest `files`.
- The published corresponding source for GPL and LGPL components, at the location that the notices name.
- The completed checklist in [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) (the task creates the document if it does not exist yet).
- The R-10 result in [../risks.md](../risks.md).

### Implementation steps

1. **Inventory** ([../../05-development/build-system.md](../../05-development/build-system.md) §6.1, §6.5).
   - Fill `license`, `licenseFiles`, and `ships` for every lock entry. The entries include virglrenderer, libepoxy, ANGLE, the RiftVM source reference (or derived code if later copied or adapted), aapt2, swift-protobuf, swift-argument-parser, Sparkle, the Kotlin libraries, and the Cargo crates. Cover `Package.resolved`, the Gradle lock, and `Cargo.lock`.
   - List the image components with the licenses from the AOSP build's notice data.
   - Check: every shipped component has a license and license files.
2. **License check** ([../../05-development/build-system.md](../../05-development/build-system.md) §3, §6.8 step 3).
   - `scripts/check-licenses.sh` fails on a missing license, an unresolved license (`NOASSERTION` or empty), or a license outside the allowed list of [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) §4 for components APKRun distributes or uses as build/test tooling. For `ships: reference`, require an identified license and committed license copy without applying the redistribution allow-list. Add it to the `lint` job and to the table of [../../05-development/build-system.md](../../05-development/build-system.md) §3.
   - Check: T0 test. A lock sample with one missing license fails, and the real lock passes.
3. **App notices** ([../../05-development/build-system.md](../../05-development/build-system.md) §6.2, §6.3, §11).
   - `generate-notices.py` writes `Contents/Resources/ThirdPartyNotices.html` from the locks. It has one section per distributed app/derived component with the license text and copyright lines. It excludes `reference` entries; it includes the RiftVM MIT attribution only if RiftVM code is copied or adapted and the lock entry is classified as `derived`.
   - The Help menu item **Third-Party Notices** opens the file.
   - Add the notices row to `scripts/release/check-release-build.sh` ([../../05-development/build-system.md](../../05-development/build-system.md) §3.1): the file has a section for every lock entry with `ships: app` or `ships: derived`.
   - Check: the file in a Release build lists every component with `ships: app` or `ships: derived` and omits `reference` entries. A fixture bundle with a required section missing fails the release check. The menu item opens it.
4. **Image notices and source offers** ([../../02-design/android-image.md](../../02-design/android-image.md) §2.3, §10.1, §11).
   - The custom image build keeps AOSP's notice generation, so Android Settings → About → Legal information shows the image notices.
   - The bundle tool adds the notice file `legal/notice.html` to the bundle, names it in the manifest `legal.notice`, and lists it in `files` ([../../03-reference/runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §4.2). The file has the source offer for each GPL and LGPL component. The offer names the exact source revision, which comes from the manifest `provenance`, and the place where that source is published.
   - Publish the corresponding source for each release image.
   - Check: a release bundle passes ImageCore verification with the notice file. The notices are visible in Android.
5. **Redistribution review** ([../../01-architecture/decisions/0001-real-android-in-vm.md](../../01-architecture/decisions/0001-real-android-in-vm.md); [../../02-design/wrapper.md](../../02-design/wrapper.md) §11).
   - Confirm three things:
     - no stock Google-built image is distributed;
     - no GMS component is in the image;
     - the distribution wrapper confirmation text states the creator's responsibility.
   - Record the results in the checklist.
   - Check: each item has a result.
6. **Legal review and checklist** ([../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md)).
   - A maintainer completes the compliance checklist. The review covers notices, source offers, allowed licenses for distributed and build/test tooling components, identified licenses for reference-only entries, and redistribution. Record the result in R-10.
   - Do checklist item C10-8.
   - Check: the acceptance criteria below.

### Tests

- **T0** (`scripts/` tests, run in the `lint` job): the license inventory of `ThirdParty/ThirdParty.lock.json`. Every component has a license, and none is unresolved ([../test-strategy.md](../test-strategy.md) §6.13).
- **T1**: the Release build contains `ThirdPartyNotices.html` with every `ships: app` and `ships: derived` component (a `check-release-build.sh` row).
- **T2**: none.
- **T3**: checklist item C10-8 (notices visible in APKRun.app and in the image).

### Acceptance criteria

- [ ] Every shipped component has a known license in the inventory, and the license check passes. A missing or unresolved license fails the `lint` job.
- [ ] `ThirdPartyNotices.html` ships in APKRun.app, lists every component with `ships: app` or `ships: derived`, and excludes `reference` entries. The RiftVM attribution appears only if RiftVM code is copied or adapted. The Help menu opens it.
- [ ] The custom image shows its notices in Android. The image bundle carries a notice file with source offers for GPL and LGPL components, and the source is published.
- [ ] No stock Google-built image and no GMS component is distributed.
- [ ] The legal checklist is complete, and R-10 has a result (C10-8).

### Notes

- Record the R-10 result and status in [../risks.md](../risks.md).
- The production host for published sources is OQ-01.
- A new third-party component after this task needs its license entry and passes the license check in the same pull request ([../../05-development/build-system.md](../../05-development/build-system.md) §6.8).

---

## #094 v1.0 release readiness

| Field | Value |
|---|---|
| Milestone | M12 (v1.0) |
| Depends on | Every other v1.0 task ([README.md](README.md) §3): all tasks of M0–M12 except #094 itself |
| Requirements | Every `Must` requirement for v1.0 or earlier ([../traceability.md](../traceability.md) §2) |
| Design | [../roadmap.md](../roadmap.md) §3, §3.6, §4; [../test-strategy.md](../test-strategy.md) §8.7, §9; [../../05-development/build-system.md](../../05-development/build-system.md) §3.1, §12, §15.1; [../../05-development/workflow.md](../../05-development/workflow.md) §9; [../traceability.md](../traceability.md) §2; [../risks.md](../risks.md); [../open-questions.md](../open-questions.md) |
| Modules / paths | `scripts/release/check-readiness.sh`; `.github/workflows/release.yml`; `Tests/AcceptanceTests/ReleaseSmoke/`; [../traceability.md](../traceability.md), [../risks.md](../risks.md), [../open-questions.md](../open-questions.md), [../roadmap.md](../roadmap.md); the release notes |
| Risks / questions | Every open risk and question. OQ-01 must be settled |

### Goal

The v1.0 candidate meets the ten release criteria of [../roadmap.md](../roadmap.md) §3.6. The evidence for each criterion is in the pull request. The candidate passes release testing ([../test-strategy.md](../test-strategy.md) §9), and v1.0 is tagged and published.

### Scope

- A readiness script that collects the machine-checkable evidence.
- Each of the ten criteria, checked with its evidence.
- The release candidate process of [../test-strategy.md](../test-strategy.md) §9.1 and the release smoke matrix ([../test-strategy.md](../test-strategy.md) §9.2). The image release candidate ([../test-strategy.md](../test-strategy.md) §9.3) when a new image ships with v1.0.
- Checklist items C10-7 and C10-10. The v1.0 checklist as a whole ([../test-strategy.md](../test-strategy.md) §8.7).
- The M12 milestone review ([../roadmap.md](../roadmap.md) §4 items 1–8), the release notes, and the tag.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - New features or fixes. A failing criterion goes back to its task, or becomes a new task.
  - The post-v1 tracks #096 and #097.

### Deliverables

- `scripts/release/check-readiness.sh`. It prints one line per criterion with pass, fail, or manual, and it exits non-zero on a failure.
- The #094 pull request with the evidence for criteria 1–10.
- Updated [../traceability.md](../traceability.md) §2, [../risks.md](../risks.md), and [../open-questions.md](../open-questions.md).
- The release notes, including every unfinished `Should` requirement.
- The v1.0 tag, and the published, notarized DMG and appcast entry.

### Implementation steps

1. **Readiness script** ([../roadmap.md](../roadmap.md) §3.6).
   - `check-readiness.sh` reads the requirement status table of [../traceability.md](../traceability.md) §2, the risk table of [../risks.md](../risks.md), and the question table of [../open-questions.md](../open-questions.md). It uses `gh` to query the open issues with the labels `fuzz-crash`, `nightly-failure`, and `security`, and the latest nightly results.
   - Criteria that need a person are printed as "manual" with the evidence to attach.
   - Check: the script runs on `main` and prints all ten criteria.
2. **Requirements, performance, and reliability** (criteria 1–3).
   - Criterion 1: every `Must` requirement for v1.0 or earlier has its tasks done and its tests passing. List the unfinished `Should` items in the release notes.
   - Criterion 2: a full `apkrun-perf` run on the reference Mac meets the NFR targets, or an ADR revises a target with the measured numbers.
   - Criterion 3: the release smoke matrix passes with the current and the previous stable image. It covers boot, install and launch, update, rollback, wrapper generation, the oldest wrapper (NFR-CMP-02), APKRun N → N+1, and image migration A → B (NFR-CMP-03).
   - Check: the evidence for criteria 1–3 is in the pull request.
3. **Compatibility, security, and distribution** (criteria 4–6).
   - Criterion 4: every fixture app is `nativeLike`. The corpus results are in the database (#090), and the [../../00-product/scope.md](../../00-product/scope.md) §4 level names are shown to users.
   - Criterion 5: #091 is done, with no open fuzz crash and the review items closed.
   - Criterion 6: the candidate is Developer ID signed, notarized, and stapled (C10-7). The Sparkle appcast and the image feed are signed and served from the production host (OQ-01). Distribution wrappers work (#088).
   - Check: the evidence for criteria 4–6 is in the pull request.
4. **Legal, localization, diagnostics, risks, and questions** (criteria 7–10).
   - Criterion 7: the #093 checklist is complete.
   - Criterion 8: English and Japanese are complete, and the VoiceOver checks pass (#092).
   - Criterion 9: `apkrun doctor` tells apart every FR-OPS-01 class, and a bundle from a boot failure is secret-free (FR-OPS-02).
   - Criterion 10: no `open` High-impact risk remains without an accepted fallback. No Decision with a deadline at or before v1.0 is open.
   - Check: the evidence for criteria 7–10 is in the pull request.
5. **Release candidate** ([../test-strategy.md](../test-strategy.md) §9.1–§9.5).
   - Tag the merge commit of the release preparation pull request `v1.0.0`. `release.yml` builds the candidate from the tag and publishes it on the beta channel ([../../05-development/workflow.md](../../05-development/workflow.md) §9). The build number must be higher than every published one (R1).
   - Run T0, T1, and the release checks, then every T2 suite, every closed gate, the performance scenarios, the full compatibility list, the network checks, and nightly notarization on the reference Mac.
   - Update a stable install to the candidate through the real appcast. Then run the smoke matrix.
   - When a new image ships with v1.0, run the image release candidate steps of [../test-strategy.md](../test-strategy.md) §9.3.
   - Complete the v1.0 checklist, including C10-10, the v0.4 demo repeated on the candidate.
   - Check: every step of [../test-strategy.md](../test-strategy.md) §9.1 passes, and no smoke matrix cell failed.
6. **Milestone review, notes, and tag** ([../roadmap.md](../roadmap.md) §4; [../../05-development/workflow.md](../../05-development/workflow.md) §9).
   - Do the M12 review for tasks, gates, tests, performance, risks, questions, documents, and version.
   - Write the release notes. Promote the candidate built from the `v1.0.0` tag from beta to stable, unchanged (`release.yml` with `promote`, [../../05-development/workflow.md](../../05-development/workflow.md) §9). A failed candidate is never re-tagged: fix it, and tag `v1.0.1` for the next candidate.
   - Check: the acceptance criteria below.

### Tests

- **T0, T1**: the full suites on the candidate commit, including the release checks of `check-release-build.sh`.
- **T2**: every T2 suite on the reference Mac with the candidate.
- **T3**:
  - the release testing of [../test-strategy.md](../test-strategy.md) §9: the release candidate, the smoke matrix, the image release candidate, and the macOS build check;
  - every closed gate;
  - the performance scenarios;
  - the full compatibility list;
  - the network checks;
  - checklist items C10-7 and C10-10;
  - the complete v1.0 checklist.

### Acceptance criteria

- [ ] Criterion 1: every `Must` requirement for v1.0 or earlier has its tasks done and its tests passing. The unfinished `Should` requirements are in the release notes.
- [ ] Criterion 2: the NFR targets are met on the reference Mac, or revised by an ADR with the measured numbers.
- [ ] Criterion 3: the release smoke matrix passes, including NFR-CMP-02 and NFR-CMP-03.
- [ ] Criterion 4: every fixture app is `nativeLike`, the corpus results are in the compatibility database, and the level definitions are shown to users.
- [ ] Criterion 5: #091 is done. The NFR-SEC-07 tests pass, no fuzz crash is open, and the security review items are closed.
- [ ] Criterion 6: APKRun.app is Developer ID signed, notarized, and stapled. The appcast and the image feed are signed and served from the production host (OQ-01). Distribution wrappers work.
- [ ] Criterion 7: the #093 checklist is complete.
- [ ] Criterion 8: English and Japanese are complete, and the VoiceOver checks pass.
- [ ] Criterion 9: doctor tells apart every FR-OPS-01 failure class, and a boot-failure bundle is secret-free.
- [ ] Criterion 10: no `open` High-impact risk remains without an accepted fallback, and no Decision due at or before v1.0 is open.
- [ ] The release candidate steps of [../test-strategy.md](../test-strategy.md) §9.1 pass, and the v1.0 checklist C10-1 to C10-10 is complete.
- [ ] The evidence for each criterion is in the #094 pull request, and v1.0 is tagged.

### Notes

- A failing criterion reopens its task, or opens a new task (#098 and up). #094 does not fix it itself.
- Record the release result in [../roadmap.md](../roadmap.md) §3.6, and the final requirement status in [../traceability.md](../traceability.md) §2.
- After v1.0, the deferred items of [../open-questions.md](../open-questions.md) §5 are reviewed before they become tasks ([../roadmap.md](../roadmap.md) §5).
