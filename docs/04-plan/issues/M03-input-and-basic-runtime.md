# M3 Input and basic runtime

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.1 (#033, #072, #024–#027, #067) / v0.2 (#028–#030) |
| Related | [README.md](README.md), [../roadmap.md](../roadmap.md) §2, [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../traceability.md](../traceability.md), [../../02-design/input.md](../../02-design/input.md), [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md), [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md), [../../02-design/guest-components.md](../../02-design/guest-components.md), [../../05-development/workflow.md](../../05-development/workflow.md) |

## Milestone goal

HelloText runs in a normal Mac window and responds to the mouse and the keyboard (gate G4). Then two apps run at the same time in two windows, each on its own Android display, and input reaches only the app of the focused window (gate G5).

Input is injected by the Guest Agent inside Android, not by a host virtio-input device ([ADR-0013](../../01-architecture/decisions/0013-input-via-guest-injection.md)). The path is `NSEvent → InputCore → GuestProtocol → Guest Agent → Android input injection`. Task #033 delivers the protocol before input task #024; task #072 bootstraps a development Guest Agent reached through an ADB forward. The vsock transport and the rest of the agent are in #034.

RuntimeCore gets the package operations of #027 through `PackageStore` and an ADB-backed store channel. `DisplayPool` then maps app sessions to the scanouts 1–15 of the virtio-gpu device (#028). Retina density and resize come with #067.

Everything in M3 runs in embedded development mode: the runtime runs in the CLI process, and the windows belong to the CLI ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §10). apkrund arrives in M4 (#031).

M3 delivers these items of the Definition of Done ([../roadmap.md](../roadmap.md) §3):

- v0.1: "Hello APK visible", "Mouse", "Keyboard", "Native Mac window", and, with #017, "CLI launch" in its embedded form.
- v0.2: "Multiple APKs" and, with #068, "Multiple native windows".

## Exit criteria

- [ ] All 10 tasks below meet every acceptance criterion.
- [ ] Gates G4 and G5 pass on the reference Mac with a clean build from `main`, meeting every condition of [../roadmap.md](../roadmap.md) §2.
- [ ] These files are committed:
  - `Packages/GuestProtocol/proto/apkrun/guest/v1/*.proto`, `buf.yaml`, the generated Swift sources, and the golden frames in `Packages/GuestProtocol/testdata/frames/`.
  - The `Guest/` Gradle build with the `protocol`, `agentruntime`, and `guestd` modules.
  - `Packages/InputCore/Resources/keymap-mac-android.csv`.
  - The fixtures HelloCompose, HelloWebView, and HelloSplit, and the HelloText additions (context menu event, Details screen, `screen` and `text` events).
  - `scripts/dev/validate-input-coordinates.sh`.
  - `docs/06-user/keyboard-and-text-input.md` (the stub of #025).
- [ ] The verified results are recorded in the Verification log sections:
  - [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18, the rows of #033 and #072.
  - [../../02-design/guest-components.md](../../02-design/guest-components.md) §14, the rows of #072.
  - [../../02-design/input.md](../../02-design/input.md) §15, the rows of #024 and #025, and the #030 part of the two-window row.
  - [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §11, rows 1 (Android), 2, 3, 4, and 6.
  - [../../02-design/graphics.md](../../02-design/graphics.md) §16, the rows of #028 and #067, and the #030 part of the two-display row.
- [ ] R-01 (Android part), R-04, R-05, and R-08 each have a result and an updated status. R-03 has the two-display measurement, and R-18 has the stock-image result for the hidden APIs used so far.
- [ ] OQ-31 and OQ-39 have answers for display 0 and for pool displays.
- [ ] Tests pass:
  - T0 and T1 on `main`, including the Kotlin tests (`./gradlew -p Guest test`).
  - T2 on the reference Mac: `GuestAgentTests`, `AndroidInputTests`, `NativeWindowTests`, `PackageStoreTests`, and `DisplayPoolTests`.
  - The G4 and G5 checks are in the nightly T3 run.
- [ ] The manual checks C01-1 to C01-6 (v0.1) and C02-1 (v0.2) of [../test-strategy.md](../test-strategy.md) are recorded.
- [ ] The milestone review of [../roadmap.md](../roadmap.md) §4 is done.

## Task order

1. #033 Define GuestProtocol. It needs only #007 from M0, so it can start during M2.
2. #072 Guest Agent bootstrap. It needs #033 and #015 from M1, and can also run during M2.
3. #024 Pointer input. It needs #023 from M2 and #072.
4. #025 Keyboard input.
5. #026 HelloText in a native Mac window. This task closes G4.
6. In parallel: #027 RuntimeCore package operations and #067 Retina, density, and resize. Both need only #026 ([../roadmap.md](../roadmap.md) §1.4).
7. #028 DisplayPool. It needs #027, and in this file also #067 (see its Notes).
8. #029 App on a secondary Android display.
9. #030 Two APKs in two native windows. This task closes G5.

Outside M3: apkrund (#031), the XPC CLI (#032), the full Guest Agent with the vsock transport (#034), the XPC frame path (#068), and the IME (#071) are M4 tasks.

Conventions used by every task in this file:

- Dev commands. The `apkrun dev` commands of [../../02-design/cli.md](../../02-design/cli.md) §5 are run through the Debug CLI `apkrun-dev` ([../../05-development/build-system.md](../../05-development/build-system.md) §13). For example: `apkrun-dev dev launch Tests/Fixtures/apks/HelloText.apk`.
- Home directory. Debug builds use `APKRUN_HOME` = `~/Library/Application Support/APKRun-Dev/`, and logs go to `~/Library/Logs/APKRun-Dev/`.
- Embedded mode. The runtime runs in the CLI process, and only one process owns the instance. A second process fails with exit 75 ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §3.8).
- Guest Agent. From #072 on, `apkrun dev boot` and `apkrun dev launch` install and start the development Guest Agent over ADB and connect to it through an ADB forward on host loopback ([../../02-design/guest-components.md](../../02-design/guest-components.md) §3).
- Where tests live.

  | Tier | Location |
  |---|---|
  | T0 Swift | `Packages/<Module>/Tests/<Module>Tests/` |
  | T1 Swift | `Packages/<Module>/Tests/<Module>SystemTests/` |
  | T0 and T1 Kotlin | `Guest/<module>/src/test/` |
  | T2 | `Tests/IntegrationTests/` |
  | T3 | `Tests/AcceptanceTests/` |
  | Fixture apps | `Tests/Fixtures/AndroidApps/<App>/`, built by `scripts/build-fixtures.sh` |

- Running T2 tests. T2 tests run with `xcodebuild test -project APKRun.xcodeproj -scheme IntegrationTests -only-testing:IntegrationTests/<Suite>` inside the signed test host ([../../05-development/build-system.md](../../05-development/build-system.md) §12.4).
  - Android T2 suites skip with a message when `Images/work/16373615/` holds no bundle. With `APKRUN_CI=1`, a missing bundle fails the run.
  - Each suite uses a temporary `APKRUN_HOME` on the same APFS volume as the bundle.
- Reference build. Build ID `16373615` is the pinned M1–M4 build ([../../01-architecture/decisions/0003-cuttlefish-base-image.md](../../01-architecture/decisions/0003-cuttlefish-base-image.md)).
- Fixture log. Fixture apps log `APKRUN-FIXTURE:` lines. Tests read them with the `FixtureLog` helper of `AdbClient` ([../test-strategy.md](../test-strategy.md) §4.1).

---

## #033 Define GuestProtocol

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #007 |
| Requirements | FR-RT-04, NFR-REL-04 ([../traceability.md](../traceability.md) §2.5, §2.12) |
| Design | [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §2, §4–§12, §15 (#033), §16, §17, §18; [../../01-architecture/decisions/0014-protobuf-guest-protocol.md](../../01-architecture/decisions/0014-protobuf-guest-protocol.md); [../../02-design/guest-components.md](../../02-design/guest-components.md) §2 |
| Modules / paths | `Packages/GuestProtocol/` (`proto/apkrun/guest/v1/`, `buf.yaml`, `Sources/GuestProtocol/{Generated/,FrameCodec.swift,ProtocolVersion.swift,Capabilities.swift}`, `Tests/GuestProtocolTests/`, `testdata/frames/`); `scripts/generate-protos.sh`; `Guest/settings.gradle.kts`, `Guest/gradle/libs.versions.toml`, `Guest/protocol/`, `Guest/guestd/` (empty module) |
| Risks / questions | None. Open item: the field numbers are frozen when this task merges (§17) |

### Goal

One versioned Protocol Buffers schema defines every message between the host and the guest components. It compiles for the host and the guest. The version mismatch behavior is documented and tested.

### Scope

- The `.proto` files for §4–§11: `envelope`, `common`, `control`, `input`, `integration`, `bulk`, and `store`. All messages are defined now, including the ones later tasks implement, so field numbers are allocated once.
- The protocol message list: handshake, health, launch, stop, package query, input, display lifecycle, clipboard, and notifications.
- Options: proto3, `java_package` `io.apkrun.guest.protocol.v1`, and `swift_prefix` `GP` (§2).
- Code generation: `scripts/generate-protos.sh` with swift-protobuf for the host (the output is checked in), and the Gradle protobuf lite plugin for the guest.
- `FrameCodec` in Swift and Kotlin (§4): a big-endian length, 4 MiB maximum, and length 0 invalid.
- `ProtocolVersion`, the capability constants of §5.3, and the version rules of §5.2 as code.
- The CI regeneration check and `buf lint`.
- Out of scope:
  - Any transport: the ADB forward is #072, vsock is #034.
  - Agent behavior (#072, #034) and Store Agent behavior (#036).
  - `buf breaking` against the last release tag, which starts with #062.

### Deliverables

- The `.proto` files and `buf.yaml`.
- The checked-in generated Swift sources in `Sources/GuestProtocol/Generated/`.
- `FrameCodec.swift`, `ProtocolVersion.swift`, and `Capabilities.swift`, and their Kotlin counterparts in `Guest/protocol/`.
- The Gradle skeleton of [../../02-design/guest-components.md](../../02-design/guest-components.md) §2 with the `protocol` module and an empty `guestd` module that depends on it.
- The golden frames in `testdata/frames/`: one per body kind, plus invalid frames (oversize length, zero length, truncated body).
- The CI jobs: regeneration check and `buf lint`.

### Implementation steps

1. **Schema.**
   - Write the `.proto` files for §4–§11 with the field number ranges of §4 and the operation and event numbers of §7.1 and §8.1.
   - Check: `buf lint` passes.
2. **Generation.**
   - `scripts/generate-protos.sh` writes the Swift sources. The Gradle protobuf lite plugin generates the Kotlin sources.
   - The CI check regenerates and fails when the checked-in sources differ.
   - Check: `swift build` and `./gradlew -p Guest :guestd:assemble` pass.
3. **Frame codec.**
   - Write `FrameCodec` in Swift and Kotlin with the limits of §4.
   - Commit the golden frames. Both test suites decode all of them, reject the invalid ones, and re-encode the valid ones byte for byte.
   - Check: T0 in both languages.
4. **Versions and capabilities.**
   - Write `ProtocolVersion` (`supportedMajors = 1...1`), the capability constants of §5.3, and the rules of §5.2.
   - An incompatible major version fails with the typed error `incompatibleVersion` (§12.3). It never continues silently.
   - Check: T0 handshake matrix.
5. **Numbering rule.**
   - Every `Request.op` case has a `Response.result` case with the same number and a paired `GuestOperation`.
   - Check: T0.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/GuestProtocol/Tests/GuestProtocolTests/`, `Guest/protocol/src/test/`):
  - Golden frames in Swift and Kotlin, the codec limits, and malformed input.
  - The handshake matrix: same major, higher minor, different major, wrong channel, bad token, and duplicate session.
  - The numbering rule.

### Acceptance criteria

- [x] The schemas cover handshake, health, launch, stop, package query, input, display lifecycle, clipboard, and notifications, using Protocol Buffers.
- [x] The schemas compile for the host and guest environments: `swift build` and `./gradlew -p Guest :guestd:assemble`.
- [x] The version mismatch behavior is documented in §5.2, and a T0 test shows that a fake agent sending major 2 is rejected with `incompatibleVersion` (FR-RT-04, NFR-REL-04).
- [x] Both codecs decode every golden frame, reject every invalid one, and re-encode the valid ones byte for byte.
- [ ] The CI regeneration check and `buf lint` pass.

### Notes

- **Record:** the result in the #033 row of [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18.
- The field numbers are frozen when this task merges. From then on, the evolution rules of §5.2 apply (§17).
- **Pitfall:** the guest uses `protobuf-javalite` only ([../../02-design/guest-components.md](../../02-design/guest-components.md) §2). Do not use features that need the full runtime, such as reflection or JSON.
- The `guestd` module is empty here so that the §15 acceptance command works. #072 fills it.
- **Evidence (2026-10-08, macOS 27.0.1 build 26A434, arm64; Swift 6.4, Java 17, Gradle 9.6.1):**
  - Schema: `scripts/check-protos.sh` (the pinned buf 1.55.1, `buf lint` with the STANDARD rules) passes, and protoc compiles all seven files. The numbering rule is checked by `NumberingRuleTests`: the 50 operations of §7.1, §7.5, and §11.1 pair with results of the same number and name, the number ranges hold, 71 is reserved, and every referenced message is defined. A temporary rename of a result made the pairing test fail, which confirms the test.
  - Swift: `swift build` passes. `swift test --filter GuestProtocolTests` passes 29 tests: 10 codec tests (every golden frame decodes, re-encodes byte for byte, and each invalid frame fails with its typed error; the streaming reader; the length limits), 8 handshake rows (same major, higher minor, a fake agent with major 2 rejected with `incompatibleVersion`, an older major, wrong channel, unspecified channel, missing version), 6 version and capability tests, and 5 numbering tests.
  - Kotlin: `./gradlew -p Guest :guestd:assemble` passes (exit 0). `./gradlew -p Guest :protocol:testDebugUnitTest` passes 25 JUnit tests (9 frame codec, 9 agent handshake, 7 control session) with no skips. The Kotlin codec re-encodes the same golden frames byte for byte. The build prints no Kotlin warnings.
  - Golden frames and sources: `scripts/generate-protos.sh` regenerates the Swift sources and the 17 golden frames with no diff, and two runs are byte-identical.
  - Format and repository checks: `scripts/check-format.sh` (swift-format strict and `ktfmtCheck`) passes. `scripts/tests/run.sh` passes. `scripts/ci/run-checks.sh` passes all seven of its checks, and `scripts/ci/codegen.sh` reports that the generated files are up to date. Both were run on the final tree on 2026-10-08.
  - Decisions that a maintainer should review before the field numbers freeze: IR-260 to IR-267 (schema shapes, enum prefixes and placement, the handshake split, golden frame generation, tool pins, the Android SDK, the Gradle build, and CI wiring).
- **Remaining:**
  - The hosted CI jobs cannot run here, because the repository has no remote. The `lint` job runs `check-format.sh`, which runs `ktfmtCheck` and needs the Android SDK. Bootstrap installs the SDK only with #015 (IR-267). So the CI acceptance box stays open until a runner passes both `lint` and `codegen`.
  - `buf breaking` against the last release tag is #062. Fuzzing of both decoders is #091.
  - The paired `GuestOperation` types (guest-protocol.md §13.1) are implemented with #072. This task checks the schema side of the numbering rule.
  - `allWarningsAsErrors` is not set for the Kotlin modules (IR-266). Warnings are zero today.
- **Scope note:** the codec, the version rules, and the handshake live in the `GuestProtocol` target, in `GuestProtocolFailure.swift`, `FrameDecoder.swift`, and `Handshake.swift`, which the Modules list does not name. They add no target and no dependency.

---

## #072 Guest Agent bootstrap

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #033, #015 |
| Requirements | FR-IN-06. Constraints: NFR-SEC-06 (the ADB forward listens on host loopback only) |
| Design | [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3, §5, §6, §7.1, §8.1, §9, §12, §13.1–§13.3, §15 (#072), §16, §18; [../../02-design/guest-components.md](../../02-design/guest-components.md) §2, §3, §5, §6, §9, §11 (#072), §12, §14; [../../01-architecture/decisions/0008-guest-agents.md](../../01-architecture/decisions/0008-guest-agents.md) |
| Modules / paths | RuntimeCore `ADBForwardGuestTransport`, `GuestConnection`, `GuestAgentSupervisor`, `GuestAgentProvisioner`, `Android/AdbClient.swift`; `Guest/agentruntime/`, `Guest/guestd/`; `scripts/build-guest.sh`; `Tests/Fixtures/signing/test-guest-dev.jks`; `Tests/IntegrationTests/GuestAgentTests/` |
| Risks / questions | R-18 |

### Goal

In a development build, `apkrun dev boot` installs and starts the Guest Agent (`apkrun_guestd`) as the shell user. The host connects to it through an ADB forward, completes the handshake, keeps the connection alive, and launches an app on display 0 with `LaunchApplication`. This is the path that input (#024) needs.

### Scope

- The Gradle build of [../../02-design/guest-components.md](../../02-design/guest-components.md) §2 with the `protocol`, `agentruntime`, and `guestd` modules. `scripts/build-guest.sh` writes `Guest/build/out/apkrun-guest.apk`, and the host build copies it into the app bundle (`Contents/Resources/guest/apkrun-guest.apk`).
- `SystemServices` wrappers for DisplayManager, WindowManager, ActivityTaskManager, and InputManager, reached by reflection. A missing method fails only its capability ([../../02-design/guest-components.md](../../02-design/guest-components.md) §6.2).
- The daemon: `Main`, `SocketServer` (control, input, and bulk sockets), `SessionManager`, `Dispatcher`, and `EventBus`.
- The services `DisplayService` (display events, `SetDisplayPolicy`), `TaskService` (task events, `FocusDisplay`), `LaunchService` (`LaunchApplication`), and the input stream: `InputBatch` decoding, validation, and `InputAck`. Event injection comes with #024 and #025.
- `Ping` and `GetSnapshot`.
- Host: `ADBForwardGuestTransport`, `GuestConnection`, the handshake (§5), and `GuestAgentSupervisor` with keepalive, reconnection, and resync (§6).
- Host: `GuestAgentProvisioner` ([../../02-design/guest-components.md](../../02-design/guest-components.md) §3.1–§3.3): version check, install, start, supervision, and reinstall.
- The device setup of [../../02-design/guest-components.md](../../02-design/guest-components.md) §3.4 without the IME steps: stay awake and no keyguard.
- `apkrun dev launch <package>` without a window: it launches through `LaunchApplication` and prints the result.
- Out of scope:
  - The vsock transport and the remaining operations (#034).
  - The IME and its device setup (#071).
  - The Store Agent (#036) and the persistent priv-app mode (#035).

### Deliverables

- The `Guest/` build and `scripts/build-guest.sh`. The APK is signed with `Tests/Fixtures/signing/test-guest-dev.jks`, and its versionCode follows the rule of [../../02-design/guest-components.md](../../02-design/guest-components.md) §2.
- The guest daemon and services listed in Scope.
- The instrumented `SystemServicesTest`.
- The host transport, connection, supervisor, and provisioner.
- New `AdbClient` helpers: `forward`, `forwardRemove`, `forwardList`, `pkill`, `install` with `-t`, and `startGuestAgent`.
- `apkrun dev launch <package>` (windowless until #024).
- `GuestAgentTests`.

### Implementation steps

1. **Gradle build.**
   - Create the `agentruntime` and `guestd` modules next to `protocol`. Only the Kotlin standard library, coroutines, and `protobuf-javalite` are allowed.
   - Check: `scripts/build-guest.sh` writes the signed APK, and the host build copies it into the app bundle.
2. **SystemServices.**
   - Write the four wrappers and the instrumented test, run with `am instrument`.
   - Check: every wrapper resolves on build 16373615, and a wrapper with a missing method fails only its capability.
3. **Daemon and services.**
   - Write `Main`, `SocketServer`, `SessionManager`, `Dispatcher`, and `EventBus`, and the services of Scope. Use the threads `apkrun-callbacks` and `apkrun-input` ([../../02-design/guest-components.md](../../02-design/guest-components.md) §6.3).
   - `LaunchApplication` checks the launch after 2 s and answers `TIMEOUT` if the task has not appeared ([../../02-design/guest-components.md](../../02-design/guest-components.md) §6.4).
   - The agent logs with the tag `ApkRunGuest` and to `/data/local/tmp/apkrun/agent.log` (2 × 1 MiB) ([../../02-design/guest-components.md](../../02-design/guest-components.md) §9).
   - Check: T1 JVM tests for the dispatcher, session binding, per-display serialization, and input validation.
4. **Host connection.**
   - `ADBForwardGuestTransport` sets up the forwards through `AdbClient` on host loopback.
   - `GuestConnection` pipelines up to 64 requests with the timeouts of §6. `Hello` and `HelloAck` time out after 5 s.
   - `GuestAgentSupervisor` sends `Ping` every 5 s, marks the agent unresponsive after 3 misses, reconnects with a backoff from 100 ms doubling to 2 s, and resyncs with `GetSnapshot`.
   - Check: T0 with the in-memory fake agent covers pipelining, out-of-order responses, timeouts, cancel, keepalive loss, and resync ordering.
5. **Provisioner.**
   - `GuestAgentProvisioner` reads the installed version, installs with `-r -t`, and uninstalls first on a signer mismatch ([../../02-design/guest-components.md](../../02-design/guest-components.md) §3.1).
   - It starts the agent with the `app_process` command of [../../02-design/guest-components.md](../../02-design/guest-components.md) §3.2, with `-Dapkrun.mode=development` and `--nice-name=apkrun_guestd`.
   - It restarts a dead agent at most 3 times per minute, then reports `runtime.requiredAgentUnavailable`. Before a reinstall it stops the old agent ([../../02-design/guest-components.md](../../02-design/guest-components.md) §3.3).
   - Check: T2 install, start, kill, restart, and reinstall with a different version.
6. **Device setup.**
   - Apply stay awake and no keyguard. Leave the animations unchanged unless `--no-animations` is given.
   - Check: after `apkrun dev boot`, the screen stays on and there is no keyguard.
7. **Launch.**
   - `apkrun dev launch io.apkrun.fixture.hellotext` sends `LaunchApplication` for display 0 and prints the result.
   - Check: T2 receives `TaskAppeared` for the package on display 0.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/RuntimeCore/Tests/RuntimeCoreTests/`): `GuestConnection` with the fake agent, and the handshake matrix against the real supervisor.
- **T1** (`Guest/guestd/src/test/`): the Kotlin agent server against a scripted host; dispatcher, session binding, per-display serialization, and input validation.
- **T2** (`GuestAgentTests`):
  - The ADB-forward transport on build 16373615.
  - Development mode: install, start, kill, restart, and reinstall.
  - `SystemServicesTest` with `am instrument`.
  - Reconnection after the agent is killed.

### Acceptance criteria

- [ ] `apkrun dev boot` connects to the agent within 5 s of `sys.boot_completed` (§15).
- [ ] `apkrun dev launch` launches HelloText on display 0 through `LaunchApplication` (§15).
- [ ] After the agent process is killed, the host restarts it and the supervisor reconnects and resyncs. A fourth death within a minute gives `runtime.requiredAgentUnavailable`.
- [ ] An installed agent with another version or signer is replaced by the bundled one.
- [ ] Every `SystemServices` wrapper resolves on the stock image, and a missing method fails only its capability.
- [ ] The ADB forward listens on host loopback only.
- [ ] A protocol violation or an incompatible agent fails with a typed `GuestProtocolFailure` (§12.3).

### Notes

- **Record:** the connection result in the #072 row of [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §18, the two #072 rows of [../../02-design/guest-components.md](../../02-design/guest-components.md) §14, and the hidden-API result for these four services in R-18.
- **Pitfall:** the agent exits with code 3 when its socket name is in use (`EADDRINUSE`), which means an old agent still runs. The provisioner stops it before a restart.
- **Pitfall:** remove the forwards when the VM stops (`forwardRemove`). A stale forward makes the next boot's forward fail.
- The transport is `ADBForwardGuestTransport` only. The M3 and M4 stock-image setup uses it ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §13.3).

---

## #024 Pointer input

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #023, #072 |
| Requirements | FR-IN-01, FR-IN-02, FR-IN-06, NFR-PERF-03 ([../traceability.md](../traceability.md) §2.4, §2.12). Constraints: NFR-SEC-01 (the agent validates every event, [../../02-design/input.md](../../02-design/input.md) §9) |
| Design | [../../02-design/input.md](../../02-design/input.md) §1–§4, §7.1, §7.3, §8, §9, §11, §12 (#024), §13, §14, §15; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §3, §9; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §7.1–§7.2; [../../01-architecture/decisions/0013-input-via-guest-injection.md](../../01-architecture/decisions/0013-input-via-guest-injection.md) |
| Modules / paths | InputCore `InputEvent`, `CoordinateMapper`, `EventTranslator`; RuntimeCore `InputRouter`; WindowingCore `IOSurfaceLayerView` (event capture); `CLI/apkrun/Dev/EmbeddedInputSink.swift`; `Guest/guestd/` `InputInjector`; `scripts/dev/validate-input-coordinates.sh`; `Tests/Fixtures/AndroidApps/{HelloText,HelloCompose}/`; `Tests/IntegrationTests/AndroidInputTests/` |
| Risks / questions | R-05, R-18; OQ-31 |

### Goal

Mouse clicks, drags, and scrolling in the Mac window reach the app on Android display 0 as touch and scroll input, injected by the Guest Agent. HelloText's button can be clicked reliably.

### Scope

- Coordinate validation with ADB input first, as a one-off script.
- The InputCore pointer model: mouse down, move and drag, up, and scroll.
- `CoordinateMapper` (§3), including the letterbox of the fixed-size window of #023: points in the letterbox are dropped, and drags that leave the content are clamped.
- `EventTranslator` with the §4.1 table: the left button as a touchscreen finger, hover at up to 120 Hz, the right button and Ctrl-click as `SOURCE_MOUSE` with the secondary button, and scrolling as `AXIS_VSCROLL` and `AXIS_HSCROLL` (§4.4, at most one scroll event per 8 ms).
- `.cancelAll` when a session ends (§4.2).
- `InputRouter` for one session on display 0: `route` and `sessionEnded`, the rate limits of §7.1, and coalescing that never merges `DOWN`, `UP`, or keys.
- The guest `InputInjector`: `MotionEvent` construction, `setDisplayId` through reflection, asynchronous injection, and gesture integrity (§7.3).
- The development input path: `apkrun dev launch` opens the #023 development window with input, on a fixed development session for display 0.
- The fixture work: HelloCompose, and the HelloText `contextmenu` event.
- The OQ-31 check on display 0.
- The counters, logging, and signposts of §11.
- Out of scope:
  - The keyboard (#025) and the IME (#071).
  - Focus handling and routing between sessions (#030).
  - The latency measurement (#070). This task adds the signposts only.

### Deliverables

- `scripts/dev/validate-input-coordinates.sh`.
- The InputCore model, mapper, and translator.
- `InputRouter` in RuntimeCore.
- Event capture in `IOSurfaceLayerView`, and `EmbeddedInputSink` in the CLI. `EmbeddedInputSink` converts InputCore events to the wire types of [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §7.2, and RuntimeHost converts them back before `InputRouter` ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §7.1, §17.4).
- `InputInjector` in the Guest Agent.
- HelloCompose: a `LazyColumn` and a `TextField`, with the `scroll first=<index>` and `text` events ([../test-strategy.md](../test-strategy.md) §4.2).
- The HelloText `contextmenu` event.
- `AndroidInputTests`.

### Implementation steps

1. **Validate coordinates with ADB.**
   - The script computes points with `CoordinateMapper` from window clicks and sends `adb shell input -d 0 tap <x> <y>`. This is the only use of `adb shell input` (§1).
   - Check: taps at the mapped points hit the HelloText button, and the result is recorded.
2. **InputCore.**
   - Write the `InputEvent` model, `CoordinateMapper`, and `EventTranslator` for mouse, hover, and scroll (§3, §4).
   - Check: T0 with synthesized `NSEvent`s and `CGEvent` scroll events covers every row of §4.1 and the scroll signs.
3. **Guest injection.**
   - `InputInjector` builds `MotionEvent`s, sets the display ID, and injects asynchronously on the `apkrun-input` thread. It sends `InputAck` as §8 specifies.
   - Check: T1 JVM tests of the `MotionEvent` construction.
4. **Routing and the development window.**
   - `InputRouter` routes one session on display 0. `apkrun dev launch` opens the #023 window with event capture and the embedded input path.
   - Check: a click in the window logs `APKRUN-FIXTURE: click 1`.
5. **Android's own pointer (OQ-31).**
   - Check whether Android draws a pointer for injected `SOURCE_MOUSE` events on display 0. If it does, hide it with pointer icon `TYPE_NULL`. If that API is refused, make `input.hover = false` the default (§14).
   - Check: the result is recorded.
6. **Fixtures.**
   - Add HelloCompose and the HelloText `contextmenu` event to the fixture project.
   - Check: `scripts/build-fixtures.sh` builds them, and the committed copies in `Tests/Fixtures/apks/` are updated.
7. **Acceptance run.**
   - Check: T2 passes on the reference Mac.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/InputCore/Tests/InputCoreTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`):
  - `CoordinateMapper`: steady state, letterbox, clamping, and a generation change.
  - `EventTranslator`: every row of §4.1, the scroll conversion and signs, and the hover rate limit.
  - `InputRouter`: ownership, state gating, rate limits, and the coalescing rules.
- **T1** (`Guest/guestd/src/test/`): `MotionEvent` construction.
- **T2** (`AndroidInputTests`). The test host synthesizes `NSEvent`s and sends them to the window:
  - 100 of 100 clicks on the HelloText button.
  - HelloCompose drag and scroll.
  - A right-click opens the context menu.
  - The `adb shell` counter of `AdbClient` does not change during the input sequence.
- **T3:** the v0.1 manual checks C01-2 (natural scrolling) and C01-3 (right-click context menu).

### Acceptance criteria

- [ ] The coordinates are validated with ADB input first, and the result is recorded.
- [ ] The InputCore pointer model covers mouse down, move and drag, up, and scroll.
- [ ] HelloText's button can be clicked reliably from the Mac window: 100 of 100 clicks are logged as `APKRUN-FIXTURE: click <n>`.
- [ ] Dragging scrolls HelloCompose's list, and trackpad and wheel scrolling move it in the direction macOS uses.
- [ ] A right-click opens HelloText's context menu.
- [ ] No shell command runs per event (FR-IN-06): the `adb shell` counter does not change, and no `input` process runs during the sequence.
- [ ] Clicks in the letterbox are dropped, and drags that leave the content are clamped.
- [ ] OQ-31 has an answer for display 0.

### Notes

- **Record:** the results in the four #024 rows of [../../02-design/input.md](../../02-design/input.md) §15, the partial result for input on displays in R-05, and the `setDisplayId` result in R-18.
- **Pitfall:** trackpads and wheel mice give different scroll deltas and signs. Check both with HelloCompose's list (§14).
- **Pitfall:** the window of #023 has a fixed size with aspect fit. The mapper must use the content rectangle, not the window bounds.
- The window here is the #023 development window. #026 replaces it with `SessionWindowController`.
- The embedded CLI and RuntimeHost import InputCore for `EmbeddedInputSink` and the conversion back from wire types ([../../01-architecture/modules.md](../../01-architecture/modules.md) §3).

---

## #025 Keyboard input

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #024 |
| Requirements | FR-IN-03, FR-IN-04, FR-IN-08 ([../traceability.md](../traceability.md) §2.4) |
| Design | [../../02-design/input.md](../../02-design/input.md) §5.1, §5.2, §6, §9, §10, §12 (#025), §13, §15; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §9 |
| Modules / paths | InputCore `KeyCodeMap`, `Packages/InputCore/Resources/keymap-mac-android.csv`, `EventTranslator` (key mode); `Guest/guestd/` `InputInjector` (`KeyEvent`); `Tests/Fixtures/AndroidApps/HelloText/`; `docs/06-user/keyboard-and-text-input.md`; `Tests/IntegrationTests/AndroidInputTests/` |
| Risks / questions | R-05 |

### Goal

The user can type into an Android text field from the Mac window. Special keys, Esc as Back, and the common shortcuts work in key mode.

### Scope

- `KeyCodeMap` from the CSV, with the US map (§5.2).
- Key mode (§5.2): key down and up, modifiers and the meta state, key repeat, Backspace, Enter, the arrow keys, and Escape.
- Esc and ⌘[ → `BACK`. The Escape mapping is configurable with `input.escapeKey`.
- The shortcuts of §6: ⌘C, ⌘X, ⌘V, ⌘A, and ⌘Z become the Ctrl combinations. ⌃ shortcuts pass through. Other Command combinations are not forwarded.
- `KeyEvent` construction in the injector.
- The unsupported IME behavior of §10, written down in a user documentation stub.
- The fixture work: HelloText's Details screen, and the `screen` and `text` events.
- Out of scope:
  - The IME, `NSTextInputClient`, marked text, and Japanese input (#071). Before #071, all keyboard input is key mode (§5.1).
  - Clipboard sync between the Mac and Android (#053).

### Deliverables

- `keymap-mac-android.csv` and `KeyCodeMap`.
- Key mode in `EventTranslator`.
- `KeyEvent` injection in `InputInjector`.
- The HelloText Details screen and events.
- `docs/06-user/keyboard-and-text-input.md`.

### Implementation steps

1. **Key map.**
   - Write the CSV and `KeyCodeMap`. Generate the list of `KEYCODE_*` constants from the Android SDK `KeyEvent` class.
   - Check: T0 shows that every row is unique and every `KEYCODE_*` exists.
2. **Key mode.**
   - Translate key down and up, the meta state, repeat, Esc and ⌘[, the ⌃ shortcuts, and the ⌘ shortcuts of §6.
   - Check: T0 covers the meta state and repeat.
3. **Injection.**
   - `InputInjector` builds `KeyEvent`s with the meta state and repeat count and injects them on the session's display.
   - Check: T1 JVM tests.
4. **Fixture.**
   - Add the Details screen to HelloText and the `screen <name>` and `text <JSON>` events.
   - Check: the committed fixture copy is updated.
5. **Documentation.**
   - Write the stub `docs/06-user/keyboard-and-text-input.md`: key mode, the shortcuts, and the unsupported behavior of §10.
   - Check: review.
6. **Acceptance run.**
   - Check: T2 passes on the reference Mac.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/InputCore/Tests/InputCoreTests/`): the `KeyCodeMap` table checks, the key mode meta state, and repeat.
- **T1** (`Guest/guestd/src/test/`): `KeyEvent` construction.
- **T2** (`AndroidInputTests`):
  - Typing `Hello, APKRun 123!` gives exactly that text.
  - Backspace, Enter, and the arrow keys.
  - Esc on the Details screen goes back to `screen main`.
- **T3:** the v0.1 manual check C01-4: `Hello, APKRun 123!` with the US and the JIS layouts.

### Acceptance criteria

- [ ] The user can type into an Android text field: typing `Hello, APKRun 123!` into HelloText's field produces exactly that text.
- [ ] Key down and up, text entry, modifiers, Backspace, Enter, the arrow keys, and Escape as Back work.
- [ ] Esc and ⌘[ navigate back (FR-IN-04).
- [ ] ⌘C, ⌘X, ⌘V, ⌘A, and ⌘Z act as the Ctrl combinations in key mode (FR-IN-08, key-mode part).
- [ ] The unsupported IME behavior is documented.
- [ ] No shell command runs per key event.

### Notes

- **Record:** the result in the #025 row of [../../02-design/input.md](../../02-design/input.md) §15.
- **Pitfall:** macOS sends repeated `keyDown` events with `isARepeat`. Map them to the repeat count. Do not send a new `DOWN` without an `UP`.
- In key mode, ⌘V sends Ctrl+V, which pastes Android's clipboard. Pasting Mac text comes with #071 and #053.

---

## #026 HelloText in a native Mac window

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #023, #024, #025 |
| Gate | G4 |
| Requirements | None named in requirements.md |
| Design | [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §1, §3.1, §5.3, §7.3, §7.5, §7.6, §12 (#026), §13; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7, §10; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §3.8, §6; [../../02-design/cli.md](../../02-design/cli.md) §5; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §3; [../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md) |
| Modules / paths | WindowingCore `SessionWindowController`, `IOSurfaceLayerView`, `FrameSource`, `InputSink`; RuntimeCore `SessionRegistry`; RuntimeHost `EmbeddedRuntimeService`; `CLI/apkrun/Dev/`; `Guest/guestd/` `LaunchService` (`StopApplication`); `Tests/IntegrationTests/NativeWindowTests/`; `Tests/AcceptanceTests/` |
| Risks / questions | None |

### Goal

`apkrun dev launch` with HelloText opens a normal Mac window that contains HelloText and supports mouse and keyboard interaction. There is no emulator chrome.

### Scope

- WindowingCore `SessionWindowController`: a normal `NSWindow` with a title and the standard window buttons. There is no host-side emulator chrome: no toolbar, device frame, or control buttons.
- `IOSurfaceLayerView` from #023 and #024, with the `FrameSource` and `InputSink` protocols and the placeholder states of §7.3.
- A fixed-size window with display 0's mode from the image. Resize comes with #067.
- `SurfacePoolFrameSource` bound to the session (§5.3).
- A minimal `SessionRegistry` for embedded sessions on display 0 ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7). It calls `ScanoutController` directly for scanout 0 (§3.1).
- `apkrun dev launch <apk|package>`: boots Android if needed, installs an APK through `AdbClient`, launches it on display 0 through the Guest Agent, and opens the window.
- The close policy of §7.6 with `stop` only: closing the window stops the app with `StopApplication` (`FINISH_TASKS`). The CLI exits when the last window closes.
- The G4 gate check.
- Out of scope:
  - `DisplayPool` and secondary displays (#028, #029).
  - Resize, density, and fullscreen (#067).
  - The XPC frame path and the wrapper (#068, #031, M7).
  - Package operations through `PackageStore` (#027).

### Deliverables

- `SessionWindowController`, the placeholder states, and the `FrameSource` and `InputSink` protocols in WindowingCore.
- The minimal `SessionRegistry`, and embedded session calls in `EmbeddedRuntimeService`.
- `StopApplication` with `FINISH_TASKS` in the Guest Agent.
- `apkrun dev launch` with a window.
- `NativeWindowTests`, and the G4 check run by `scripts/run-gate.sh G4`.

### Implementation steps

1. **Window.**
   - Write `SessionWindowController` and the placeholder states. The #023 development window is removed.
   - Check: T1 screenshot comparison of `IOSurfaceLayerView` with a synthetic `FrameSource` in the UI test host.
2. **Frame source.**
   - Bind `SurfacePoolFrameSource` to the session's `SurfaceSet`. The placeholder shows until the first frame.
   - Check: T2 sees the placeholder, then HelloText.
3. **Sessions.**
   - The minimal `SessionRegistry` opens and closes sessions on display 0 and follows the states of [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §3.
   - Check: T0 of the session states that apply to display 0.
4. **Launch command.**
   - `apkrun dev launch <apk|package>` boots, installs, launches, and opens the window. Pointer and keyboard input go through InputCore to the Guest Agent (#024, #025).
   - Check: T2 opens the window, clicks the button, and types into the field.
5. **Close policy.**
   - Closing the window sends `StopApplication` with `FINISH_TASKS`. Write the policy into §7.6.
   - Check: T2 receives `TaskVanished` for HelloText, and the CLI exits 0 after the last window closes.
6. **Gate.**
   - Check: `scripts/run-gate.sh G4` passes on the reference Mac.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T1** (`Packages/WindowingCore/Tests/WindowingCoreSystemTests/`): an `IOSurfaceLayerView` screenshot with a synthetic `FrameSource`.
- **T2** (`NativeWindowTests`): the HelloText window, a click, and typing.
- **T3:**
  - The G4 check ([../test-strategy.md](../test-strategy.md) §5, `G4NativeWindow`): 100 of 100 clicks, `Hello, APKRun 123!`, Esc → `screen main`, and the `adb shell` counter does not change during the input sequence.
  - The v0.1 manual check C01-5: the launch from a new Terminal shows no emulator chrome.

### Acceptance criteria

- [ ] Launching the test opens a normal Mac window containing HelloText and supports mouse and keyboard interaction.
- [ ] Unnecessary emulator chrome is hidden.
- [ ] A normal `NSWindow` owns the Android scanout, shown through the IOSurface pool (ADR-0006).
- [ ] Closing the window stops the app according to the documented policy: the `stop` policy, documented in §7.6.
- [ ] The placeholder shows until the first frame.
- [ ] Gate G4 passes, meeting all four conditions of [../roadmap.md](../roadmap.md) §2.

### Notes

- **Record:** the G4 report and evidence of [../test-strategy.md](../test-strategy.md) §5. The close policy goes into §7.6.
- **Pitfall:** Android's own status bar and navigation bar stay on display 0. They are not emulator chrome, and trimming Android is not allowed before the baseline works ([AGENTS.md](../../../AGENTS.md) §4). Pool displays have no system decorations from #028 (§4).
- This task brings `StopApplication` with `FINISH_TASKS` forward from #034 ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §15 #034 step 1). `FORCE_STOP` stays in #034.
- In M3 the G4 check uses `apkrun-dev dev launch` ([../roadmap.md](../roadmap.md) §2, C01-5). `apkrun launch` over XPC comes with #032.

---

## #027 RuntimeCore package operations

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #026 |
| Requirements | FR-RT-01, FR-PKG-07, FR-PKG-04 (the `current/` layout and the journal; `previous/` and `staged/` come with #037), FR-CLI-01 (`install`, `uninstall`, `list`, `info`), NFR-REL-01 ([../traceability.md](../traceability.md) §2.5, §2.6, §2.10, §2.12) |
| Design | [../../02-design/package-store.md](../../02-design/package-store.md) §5, §11.1, §15 (#027), §16; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §3.8, §6.2, §8.1; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7.2; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §13.2; [../../02-design/cli.md](../../02-design/cli.md) §4; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §5 |
| Modules / paths | APKStoreCore `PackageID`, `VersionCode`, `PackageStore`, the journal, `APKInspector`; RuntimeCore `ADBStoreAgentChannel`, `Android/AdbClient.swift`; RuntimeHost `EmbeddedRuntimeService` (`StoreRuntimeAccess`); `CLI/apkrun/` (`install`, `uninstall`, `list`, `info`); `scripts/check-raw-adb.sh`; `Tests/Fixtures/AndroidApps/HelloSplit/`; `Tests/IntegrationTests/PackageStoreTests/` |
| Risks / questions | None |

### Goal

The CLI and the tests install, launch, terminate, uninstall, list, and inspect apps through the runtime API, not through raw shell commands. ADB is still the transport underneath, behind one channel.

### Scope

- The APKStoreCore types of §15 (#027) step 1. `updateAuthority` is `manual` for every package in M3.
- `PackageStore`: `open()`, the journal, `firstInstall`, `reinstall`, `uninstall`, and `forget`, the recovery of §5.5, and fault injection with `APKRUN_STORE_FAULT`.
- `APKInspector` v0: `aapt2` metadata and SHA-256. The signing check reports `notPerformed`.
- `ADBStoreAgentChannel` ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §13.2): `adb install-multiple -r --no-streaming`, `pm uninstall` with `-k` to keep data, `-r -d` for a downgrade reinstall on debuggable images, and `QueryPackage` and `ListPackages` through the Guest Agent.
- `StoreRuntimeAccess` in `EmbeddedRuntimeService`.
- The package operations of [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §8.1 that #027 needs (`installImported` through an import, `uninstallPackage`, `listPackages`, `packageInfo`), and embedded `launch` and `terminate` ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §6.2). Without a session, `terminate` force-stops the app with `StopApplication`.
- The embedded CLI commands `apkrun install`, `uninstall`, `list`, and `info` ([../../02-design/cli.md](../../02-design/cli.md) §4, marked **E**).
- The raw-ADB lint, and the migration of the #016 and #017 tests to the runtime API.
- The HelloSplit fixture for the split install test.
- Out of scope:
  - The Store Agent and the vsock path (#036).
  - Host signature checks and update rules (M6).
  - The CLI commands `apkrun launch` and `apkrun stop`, which come with #032.
  - Wrapper deletion on uninstall (#076).

### Deliverables

- The APKStoreCore types, `PackageStore`, and `APKInspector` v0.
- `ADBStoreAgentChannel` and the `AdbClient.installMultiple` helper.
- The embedded runtime operations and the four CLI commands.
- `scripts/check-raw-adb.sh`, run in CI.
- HelloSplit as described in [../test-strategy.md](../test-strategy.md) §4.2: base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, and an install-time feature split.
- `PackageStoreTests`.

### Implementation steps

1. **Types.**
   - Write `PackageID`, `VersionCode`, the APK set digest, and the other types of §15 (#027) step 1.
   - Check: T0 of the `PackageID` grammar, `VersionCode`, and the set digest.
2. **PackageStore.**
   - Write `open()`, the journal, the four operations, and the recovery table of §5.5. `APKRUN_STORE_FAULT` stops the process at a named step.
   - Check: T0 of the journal and the recovery table (kind × step), and T1 crash injection at every step of `firstInstall` and `uninstall`.
3. **Inspector.**
   - `APKInspector` v0 reads the metadata with `aapt2` and hashes every file. Host parsing is for previews only; `PackageManager` stays the source of truth ([AGENTS.md](../../../AGENTS.md) §4).
   - Check: T1 against HelloText and HelloSplit.
4. **Channel.**
   - `ADBStoreAgentChannel` installs, uninstalls, and queries. `QueryPackage` and `ListPackages` go through the Guest Agent.
   - Check: T1 of `PackageStore` with a fake channel.
5. **Runtime operations and CLI.**
   - Add the package operations and embedded `launch` and `terminate` to `EmbeddedRuntimeService`, and the four CLI commands.
   - Check: `apkrun-dev install Tests/Fixtures/apks/HelloText.apk`, then `apkrun-dev list` shows the package with its versionCode.
6. **Lint and migration.**
   - `scripts/check-raw-adb.sh` rejects `adb shell` and `pm ` in Swift sources and scripts outside `ADBStoreAgentChannel`, `AdbClient`, and the allowlist (`scripts/dev/`, `Tests/Compatibility/`, `Images/tools/reference/`).
   - Move the #016 and #017 tests to the runtime API.
   - Check: the lint passes on `main` and fails on a planted raw call.
7. **Acceptance run.**
   - Check: T2 passes on the reference Mac.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`): `PackageID`, `VersionCode`, the set digest, the journal, and the recovery table.
- **T1** (`Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): `PackageStore` with a fake channel, crash injection, and the raw-ADB lint.
- **T2** (`PackageStoreTests`): install, split install, uninstall with and without data, reinstall, and downgrade reinstall.

### Acceptance criteria

- [ ] The CLI and the tests use the runtime API, not raw shell commands. The raw-ADB lint passes.
- [ ] install, launch, terminate, uninstall, listInstalled, and applicationInfo exist with the mapping of §11.1 (FR-RT-01).
- [ ] ADB is used only inside `ADBStoreAgentChannel` and `AdbClient` (ADB is acceptable internally).
- [ ] An installed package has the layout `Packages/io.apkrun.fixture.hellotext/current/{base.apk,artifact.json,metadata.json}`.
- [ ] `apkrun-dev list` shows the versionCode.
- [ ] A crash at any step of `firstInstall` or `uninstall` is recovered at the next `open()` (NFR-REL-01).
- [ ] Uninstall keeps or deletes the app data as asked (FR-PKG-07, data part).
- [ ] HelloSplit installs as one package with all its splits.

### Notes

- **Record:** the #027 row of §18, and any change to the steps in §15 (#027).
- This task brings `QueryPackage` and `ListPackages` forward from #034 ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §15 #034 step 1).
- [../test-strategy.md](../test-strategy.md) §4.2 does not list #027 as a HelloSplit user. This task creates the fixture; #042 adds the `.apks` container and the locale checks.

---

## #067 Retina, density, and resize

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #026 |
| Requirements | FR-DSP-04, FR-DSP-05 ([../traceability.md](../traceability.md) §2.3) |
| Design | [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §4, §6.1–§6.3, §7.1, §7.2, §7.4, §7.7, §11, §12 (#067), §13; [../../02-design/graphics.md](../../02-design/graphics.md) §6.4, §15, §16; [../../02-design/input.md](../../02-design/input.md) §3 |
| Modules / paths | RuntimeCore `DisplayGeometryResolver`; GraphicsCore `EDIDGenerator`, `ScanoutController.configure`; WindowingCore `SessionWindowController`; InputCore `CoordinateMapper`; `Guest/guestd/` `DisplayService` (density); `Tests/IntegrationTests/NativeWindowTests/` |
| Risks / questions | R-04; OQ-39 |

### Goal

The Android display follows the Mac window's size and backing scale. On a Retina screen text is sharp at zoom 1, resizing re-lays out the app, and moving the window to another screen changes the density.

### Scope

- `DisplayGeometryResolver` (§6.1): `renderScale = min(backingScale, 4095 / w, 4095 / h)`, even pixel sizes, and `densityDpi = round(160 × renderScale × zoom)`, with the limits of §6.2.
- The EDID physical size from the density ([../../02-design/graphics.md](../../02-design/graphics.md) §6.4).
- Density through `SetDisplayPolicy` (§4).
- Live resize (§7.1): a 150 ms quiet time, a new scanout mode, `DisplayChanged` within 3 s, a new `SurfaceSet` with `surfacesReplaced`, a `CoordinateMapper` generation change, and coalescing.
- The backing-scale change (§7.2), fullscreen (§7.4), and the zoom commands.
- The display-ID stability test of §7.1 (R-04).
- The orientation decision (§7.7).
- All on display 0, with direct `ScanoutController` calls. #028 repeats the pool-display parts.
- Out of scope:
  - Pool displays (#028).
  - The XPC frame path (#068).
  - The IME (#071).

### Deliverables

- `DisplayGeometryResolver` and its T0 table tests.
- The EDID physical size, with updated golden EDIDs.
- Density application in the Guest Agent's `DisplayService`.
- The resize, backing-scale, fullscreen, and zoom paths in `SessionWindowController` and the embedded runtime.
- The orientation decision, written into §7.7.

### Implementation steps

1. **Resolver.**
   - Write `DisplayGeometryResolver` with the formula of §6.1 and the limits of §6.2 (320 × 400 dp minimum, 120–640 dpi, default window 480 × 850 pt).
   - Check: T0 table tests for Retina, non-Retina, the 4095 cap, the zoom clamp, and the minimum size.
2. **Density and EDID.**
   - Apply the density with `SetDisplayPolicy`, which calls `setForcedDisplayDensityForUser` (§4). Write the physical size into the EDID.
   - Check: T0 golden EDIDs, and T2 reads the density from `wm density`.
3. **Resize.**
   - Implement the sequence of §7.1, the backing-scale change, fullscreen, and zoom. The placeholder or the scaled last frame shows until the new generation's first frame.
   - Check: T2 resize and backing-scale change.
4. **Display ID.**
   - Run the display-ID stability test. If the ID changes, use fallback B for now: a fixed size and `window.resizable = false`. Fallback A needs pool displays and is tried in #028.
   - Check: the result is recorded.
5. **Orientation and OQ-39.**
   - Decide how orientation requests are handled (§7.7). Check how the EDID physical size affects the density on display 0 (OQ-39).
   - Check: both are recorded.
6. **Acceptance run.**
   - Check: T2 passes, and C01-1 is recorded.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/RuntimeCore/Tests/RuntimeCoreTests/`, `Packages/InputCore/Tests/InputCoreTests/`, `Packages/GraphicsCore/Tests/GraphicsCoreTests/`): the resolver table, the mapper generation change, and the EDID size.
- **T2** (`NativeWindowTests`): resize and backing-scale change.
- **T3:** the v0.1 manual check C01-1: Retina sharpness, and non-Retina if a screen is available.

### Acceptance criteria

- [ ] On a Retina Mac, a 480 × 850 pt window shows a 960 × 1700 px display at 320 dpi (FR-DSP-04).
- [ ] Text is sharp: there is no scaling at `zoom = 1`.
- [ ] Resizing re-lays out HelloCompose without restarting the app process, when the app handles configuration changes (FR-DSP-05).
- [ ] Moving the window to a non-Retina screen switches to 160 dpi and 480 × 850 px.
- [ ] The resize policy is defined and documented (FR-DSP-05): the §7.1 sequence, or fallback B, recorded under R-04.
- [ ] Input hits the right point after a resize.
- [ ] The orientation decision is written into §7.7.

### Notes

- **Record:** the display 0 results in rows 3 and 4 of §11, the #067 row of [../../02-design/graphics.md](../../02-design/graphics.md) §16, OQ-39 for display 0, and the partial R-04 result.
- **Pitfall:** a frame of the old size can arrive after `surfacesReplaced`. The view drops frames whose generation is older than the current one.
- This task builds `DisplayGeometryResolver`, because resize needs it. #028 uses it and depends on this task ([../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §12).

---

## #028 DisplayPool

| Field | Value |
|---|---|
| Milestone | M3 (v0.2) |
| Depends on | #027, #067 |
| Requirements | FR-DSP-01, FR-DSP-02 ([../traceability.md](../traceability.md) §2.3) |
| Design | [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §1, §2, §3.1–§3.6, §4, §10, §11, §12 (#028), §13; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §4; [../../02-design/graphics.md](../../02-design/graphics.md) §4.3, §6.1, §15, §16; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1, §8.1 |
| Modules / paths | RuntimeCore `DisplayPool`, `SessionRegistry`; `RuntimeCoreTestSupport` (`FakeDisplayControlChannel`); `GraphicsCoreTestSupport` (`FakeScanoutController`); GraphicsCore `ScanoutController`; `Guest/guestd/` `DisplayService`, `TaskService`; `CLI/apkrun/Dev/` (`dev displays`); `Tests/IntegrationTests/DisplayPoolTests/` |
| Risks / questions | R-01, R-04, R-08; OQ-39 |

### Goal

`DisplayPool` allocates, releases, and reuses the Android displays on scanouts 1–15 centrally. Displays are reused without stale scanouts or conflicting IDs.

### Scope

- The `DisplayPool` actor of §3.1: `acquire`, `reconfigure`, `release`, `snapshot`, and `events`. Each lease carries the `SessionID` (`.app` or `.system`).
- The slot states of §3.2 ([../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §4): available → `free`, allocated → `attaching`, attached → `allocated(SessionID)`, releasing → `releasing`, then `free`. `faulted(DisplayFault)` handles failed transitions.
- The serialized acquire of §3.3, the release of §3.4, the fault retry, and `displayAttachFailed`.
- The reuse rules of §3.5: a fresh `SurfacePool` per lease, the placeholder until the first frame, and the property test for invariant 2.
- `display.maxSessions` (default 8) and `displayPoolExhausted` (§2, §10).
- The Android display settings of §4: density (fallback 213), IME policy `LOCAL`, no system decorations, stay awake, launch options, and task tracking.
- Guest: `DisplayAdded`, `DisplayChanged`, and `DisplayRemoved` with the product info, `ClearDisplay`, `TasksCleared`, and the task events.
- Hotplug on Android with the fallbacks of [../../02-design/graphics.md](../../02-design/graphics.md) §4.3 (R-01).
- `reconfigure` with the #067 resize sequence. The #067 display-ID test and the density check (OQ-39) are repeated on pool displays, and fallback A is available.
- `SessionRegistry` sessions acquire a lease from `DisplayPool`.
- `apkrun dev displays add|remove|list`.
- Out of scope:
  - Launching apps on pool displays (#029).
  - Two sessions and input routing (#030).
  - The XPC frame path (#068).

### Deliverables

- `DisplayPool` and the fakes in the test support targets.
- The display and task messages in the Guest Agent.
- The hotplug path, with a fallback if the spike needs one.
- `apkrun dev displays`.
- `DisplayPoolTests`.

### Implementation steps

1. **Pool with fakes.**
   - Write `DisplayPool` with the slot states, the serialized acquire, release, and fault handling, against `FakeScanoutController` and `FakeDisplayControlChannel`. `DisplayGeometryResolver` comes from #067.
   - Check: T0 state machine tests, serialized attach, fault retry, and the invariant 2 property test.
2. **Guest display messages.**
   - Implement the display events with the product info, `ClearDisplay`, `TasksCleared`, and the task events.
   - Check: T1 JVM tests.
3. **Hotplug on Android.**
   - Configure scanout 1 at runtime and wait for `DisplayAdded` with the product info `APK` and the scanout index (5 s).
   - If no event arrives, apply fallback A, then B, then C ([../../02-design/graphics.md](../../02-design/graphics.md) §4.3).
   - Check: T2 sees the display, and the result is recorded.
4. **Integration.**
   - Connect `DisplayPool` to `ScanoutController` and the Guest Agent. `SessionRegistry` uses `acquire` and `release`. Add `apkrun dev displays add|remove|list`.
   - Check: `apkrun-dev dev displays add --size 960x1700 --dpi 320` adds a display that `list` shows, and `remove` frees it.
5. **Pool-display checks.**
   - Run `reconfigure` with the #067 sequence. Repeat the display-ID test and the density check on a pool display.
   - Check: the results are recorded.
6. **Acceptance run.**
   - Check: T2 passes on the reference Mac.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/RuntimeCore/Tests/RuntimeCoreTests/`): the `DisplayPool` state machine and the invariant property test.
- **T2** (`DisplayPoolTests`): 50 acquire and release cycles across slots with no stale frames (checked with the first-frame rule), no duplicate Android display IDs, and every slot `free` at the end.

### Acceptance criteria

- [ ] The lifecycle available → allocated → attached → releasing → available is implemented as `free` → `attaching` → `allocated` → `releasing` → `free`, with `faulted` ([display-and-windowing.md](../../02-design/display-and-windowing.md) §3.2).
- [ ] Each allocation is associated with the package and window identity through its `SessionID`.
- [ ] Displays are reused without stale scanouts or conflicting IDs: 50 cycles pass.
- [ ] Every slot is `free` at the end of the run.
- [ ] A request beyond `display.maxSessions` fails with `displayPoolExhausted` and its remediation.
- [ ] The hotplug result is recorded, and the chosen fallback, if any, is implemented.
- [ ] The host memory per display is measured.

### Notes

- **Record:** rows 1 (Android part), 2, 3, and 4 (pool displays) of §11, the #028 row of [../../02-design/graphics.md](../../02-design/graphics.md) §16, OQ-39 for pool displays, and R-01, R-04, and R-08 in [../risks.md](../risks.md).
- **Pitfall:** wait for `DisplayRemoved` before a slot becomes `free` (3 s, §3.4). A slot reused earlier can get the old display's events.
- This task depends on #067, because #067 builds `DisplayGeometryResolver` and the resize sequence that `acquire` and `reconfigure` use.
- Before this task, the development commands call `ScanoutController` directly for scanout 0 only (§3.1).

---

## #029 App on a secondary Android display

| Field | Value |
|---|---|
| Milestone | M3 (v0.2) |
| Depends on | #028 |
| Requirements | FR-DSP-01, FR-DSP-06 ([../traceability.md](../traceability.md) §2.3) |
| Design | [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §3.6, §4, §8, §11, §12 (#029), §13; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7.1; [../../02-design/guest-components.md](../../02-design/guest-components.md) §6.4; [../../02-design/input.md](../../02-design/input.md) §4.2, §14 |
| Modules / paths | `Guest/guestd/` `LaunchService`; RuntimeCore `SessionRegistry`, `DisplayPool`; `CLI/apkrun/Dev/` (`dev launch --display`); `Tests/Fixtures/AndroidApps/HelloWebView/`; `Tests/IntegrationTests/DisplayPoolTests/` |
| Risks / questions | R-04, R-05; OQ-31 |

### Goal

HelloText renders correctly on a non-primary Android display in its own Mac window, and accepts input.

### Scope

- `LaunchApplication(package, displayID)` with the launch options of §4.
- `apkrun dev launch --display secondary <apk>`: acquires a pool display and opens the window on its scanout.
- The `primaryDisplayCompatibility` mode (§3.6, §8): the session leases display 0. A second request for display 0 fails with `primaryDisplayBusy`.
- Runs of HelloText, HelloCompose, HelloGL, and HelloWebView on a secondary display, recording for each app whether rendering, input, the IME, and dialogs work.
- The HelloWebView fixture with its `loaded` event.
- The OQ-31 check on a pool display.
- Out of scope:
  - Two sessions at the same time (#030).
  - The per-app setting for the compatibility mode in the UI (#079).
  - The compatibility runs of real apps (#090).

### Deliverables

- The display ID in `LaunchApplication`.
- `--display 0|secondary` for `apkrun dev launch`.
- The `primaryDisplayCompatibility` lease.
- HelloWebView.
- The per-app results in §11 row 6, and the seed list for #090.

### Implementation steps

1. **Launch on a display.**
   - `LaunchService` launches with the display ID and the launch options of §4.
   - Check: T1 JVM test of the launch options.
2. **Development command.**
   - `apkrun dev launch --display secondary <apk>` acquires a pool display and opens the window.
   - Check: T2 shows HelloText on a pool display.
3. **Compatibility mode.**
   - `apkrun dev launch --display 0 <apk>` leases display 0 in `primaryDisplayCompatibility` mode.
   - Check: T2 launches HelloText on display 0 this way, and a second request fails with `primaryDisplayBusy`.
4. **Fixture runs.**
   - Add HelloWebView. Run the four fixtures on a secondary display, and repeat the OQ-31 check there.
   - Check: the results are recorded.
5. **Acceptance run.**
   - Check: T2 passes on the reference Mac.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T2** (`DisplayPoolTests`): HelloText on a secondary display, clicked and typed into; the HelloCompose, HelloGL, and HelloWebView results; the compatibility lease and `primaryDisplayBusy`.

### Acceptance criteria

- [ ] An additional virtual display is created or enabled through `DisplayPool`.
- [ ] HelloText is launched with a selected display ID.
- [ ] The scanout is mapped to a Mac window.
- [ ] HelloText renders correctly on a non-primary display and accepts input.
- [ ] The `primaryDisplayCompatibility` mode works, and a second request gets `primaryDisplayBusy` (FR-DSP-06, runtime part).
- [ ] The results of the four fixtures are recorded in §11 row 6.
- [ ] OQ-31 has an answer for pool displays.

### Notes

- **Record:** row 6 of §11, the #090 seed list, OQ-31, and the partial R-04 and R-05 results.
- **Pitfall:** if the task does not appear on the target display, the agent answers `TIMEOUT` after 2 s ([../../02-design/guest-components.md](../../02-design/guest-components.md) §6.4). An app that ignores the launch display appears on display 0; record such apps in §11 row 6.

---

## #030 Two APKs in two native windows

| Field | Value |
|---|---|
| Milestone | M3 (v0.2) |
| Depends on | #029 |
| Gate | G5 |
| Requirements | FR-DSP-01, FR-DSP-03, FR-IN-05 ([../traceability.md](../traceability.md) §2.3, §2.4) |
| Design | [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §1, §7.5, §7.6, §12 (#030), §13; [../../02-design/input.md](../../02-design/input.md) §7.1–§7.3, §12 (#030), §15; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7; [../../02-design/graphics.md](../../02-design/graphics.md) §7, §16 |
| Modules / paths | RuntimeCore `InputRouter`, `SessionRegistry`; WindowingCore `SessionWindowController` (focus); `Guest/guestd/` `TaskService` (`FocusDisplay`); `CLI/apkrun/Dev/`; `Tests/IntegrationTests/DisplayPoolTests/`; `Tests/AcceptanceTests/` |
| Risks / questions | R-03, R-05 |

### Goal

Two Android apps run at the same time in two independent Mac windows, each on its own Android display. Input goes only to the app of the focused window.

### Scope

- `apkrun dev launch <apk1> <apk2>`: two sessions and two windows in the embedded runtime.
- HelloCompose as the second test APK.
- Focus handling ([../../02-design/input.md](../../02-design/input.md) §7.2): the key window sends `focusChanged`, and the agent's `FocusDisplay` calls `setFocusedTask`. When a window loses focus, its session gets `.cancelAll`.
- `InputRouter` ownership for several sessions: events for a display that the session does not own are dropped.
- Closing one window stops only its app (§7.6).
- The two-display measurement: fps, present time p95, and memory (R-03).
- The G5 gate check.
- Out of scope:
  - The IME on secondary displays (#071).
  - Windows owned by the wrapper over XPC (#068, #031).
  - The full latency run (#070).

### Deliverables

- Several apps in `apkrun dev launch`.
- Focus handling in `SessionWindowController`, `InputRouter`, and the Guest Agent.
- The G5 check, run by `scripts/run-gate.sh G5`.

### Implementation steps

1. **Two sessions.**
   - `apkrun dev launch <apk1> <apk2>` opens two sessions on two pool displays and two windows.
   - Check: T2 shows both apps.
2. **Routing.**
   - Implement focus handling and multi-session routing in `InputRouter` ([../../02-design/input.md](../../02-design/input.md) §7).
   - Check: T0 ownership tests, and T2 typing and clicking reach only the focused app.
3. **Close one.**
   - Closing one window releases its display. The other session keeps running.
   - Check: T2.
4. **Measurement.**
   - Run HelloGL in both windows and read the statistics of [../../02-design/graphics.md](../../02-design/graphics.md) §7.
   - Check: the result is recorded.
5. **Gate.**
   - Check: `scripts/run-gate.sh G5` passes on the reference Mac, and C02-1 is recorded.

### Tests

See [../test-strategy.md](../test-strategy.md) §6.4.

- **T0** (`Packages/RuntimeCore/Tests/RuntimeCoreTests/`): `InputRouter` ownership.
- **T2** (`DisplayPoolTests`): two sessions, and routing to the focused window.
- **T3:** the G5 check ([../test-strategy.md](../test-strategy.md) §5, `G5TwoWindows`), the v0.2 manual check C02-1 (focus moves correctly between HelloText and HelloCompose), and the v0.2 checklist.

### Acceptance criteria

- [ ] A second test APK is added: HelloCompose.
- [ ] Two displays and two windows are allocated.
- [ ] Focus and input routing follow the active window: typing and clicking go only to the focused window's app (FR-IN-05).
- [ ] Two Android apps operate simultaneously in two independent Mac windows (FR-DSP-03).
- [ ] Closing one window leaves the other app running and interactive.
- [ ] Gate G5 passes, meeting all three conditions of [../roadmap.md](../roadmap.md) §2.
- [ ] The two-display measurement is recorded.

### Notes

- **Record:** the #030 part of the two-window row of [../../02-design/input.md](../../02-design/input.md) §15, the #030 part of the two-display row of [../../02-design/graphics.md](../../02-design/graphics.md) §16, and R-03 and R-05 in [../risks.md](../risks.md).
- **Pitfall:** a drag that is in progress when focus moves must end with `.cancelAll`. Otherwise the first app keeps a finger down.
- Typing into a text field on a secondary display with the IME is #071. In M3, key mode is used on every display.
