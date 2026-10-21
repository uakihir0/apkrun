# M3 Input and basic runtime

M3 makes HelloText run in a normal Mac window that responds to the mouse and the keyboard, which closes gate G4 ([roadmap.md](../roadmap.md) §2). Then two apps run at once, each on its own Android display in its own window, and input reaches only the focused window's app, which closes gate G5. The Guest Agent injects input inside Android ([ADR-0013](../../01-architecture/decisions/0013-input-via-guest-injection.md)). M3 runs in embedded development mode ([runtime-daemon.md](../../02-design/runtime-daemon.md) §10); apkrund arrives in M4 (#32).

---

## #34 Define GuestProtocol

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #8 |
| Design | [guest-protocol.md](../../02-design/guest-protocol.md) §2, §4, §5 |
| Code | `Packages/GuestProtocol/`, `Guest/protocol/` |

**Goal.** One versioned Protocol Buffers schema defines every message between the host and the guest components. It compiles for the host and the guest, and a version mismatch fails with a typed error.

**Result.** The `.proto` files are in `Packages/GuestProtocol/proto/apkrun/guest/v1/`. The Swift sources are generated and checked in. `FrameCodec`, `ProtocolVersion`, and `Capabilities` exist in Swift and in Kotlin (`Guest/protocol/`). An incompatible major version fails with `incompatibleVersion`. The field numbers are frozen, and the evolution rules are in [guest-protocol.md](../../02-design/guest-protocol.md) §5.2. Tests are T0 in `GuestProtocolTests` and `Guest/protocol/src/test/`. Known limit: fuzzing of both decoders is #92.

---

## #73 Guest Agent bootstrap

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #34, #16 |
| Design | [guest-components.md](../../02-design/guest-components.md) §3, §6.4; [guest-protocol.md](../../02-design/guest-protocol.md) §5, §6 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Guest/`, `Guest/guestd/`, `Guest/agentruntime/`, `scripts/build-guest.sh`, `Tests/IntegrationTests/GuestAgentTests/` |

**Goal.** In a development build, `apkrun dev boot` installs and starts the Guest Agent (`apkrun_guestd`). The host connects through an ADB forward on host loopback, completes the handshake, and launches an app on display 0 with `LaunchApplication`.

**Result.** `ADBForwardGuestTransport`, `GuestConnection`, `GuestAgentSupervisor`, and `GuestAgentProvisioner` are in RuntimeCore. The supervisor sends `Ping` every 5 s, and it reconnects with a backoff from 100 ms to 2 s. The connection is ready within 5 s of `sys.boot_completed`. `apkrun dev launch <package>` launches without a window. Tests are T0 in `RuntimeCoreTests` and T2 in `GuestAgentTests`. Not tracked: no CLI command reports `runtime.requiredAgentUnavailable`.

---

## #25 Pointer input

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #24, #73 |
| Design | [input.md](../../02-design/input.md) §3, §4, §7.1, §8 |
| Code | `Packages/InputCore/Sources/InputCore/`, `Packages/RuntimeCore/Sources/RuntimeCore/Input/InputRouter.swift`, `CLI/apkrun/Dev/EmbeddedInputSink.swift`, `Guest/guestd/src/main/kotlin/io/apkrun/guest/daemon/InputInjector.kt`, `scripts/dev/validate-input-coordinates.sh`, `Tests/IntegrationTests/AndroidInputTests/` |

**Goal.** Mouse clicks, drags, and scrolling in the Mac window reach the app on Android display 0 as touch and scroll input. The Guest Agent injects them.

**Result.** `CoordinateMapper` drops points in the letterbox and clamps drags that leave the content. `EventTranslator` covers the pointer rows of [input.md](../../02-design/input.md) §4.1. `InputRouter` routes one session on display 0. No shell command runs per event. `AndroidInputTests` covers clicks, drags, the right-click context menu, and scrolling. Known limits:
- The 100-of-100 click criterion is open; #103 tracks it.
- Trackpad and wheel scrolling direction is manual check C01-2 in [test-strategy.md](../test-strategy.md) §8.
- Route rebinding after agent loss: #101.
- Tap focus on a text field: #102.
- Right-button drags are dropped. No task tracks this.

---

## #26 Keyboard input

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #25 |
| Design | [input.md](../../02-design/input.md) §5.1, §5.2, §6, §10 |
| Code | `Packages/InputCore/Sources/InputCore/KeyCodeMap.swift`, `Packages/InputCore/Resources/keymap-mac-android.csv`, `Packages/WindowingCore/Sources/WindowingCore/KeyEventAdapter.swift`, `Guest/guestd/src/main/kotlin/io/apkrun/guest/daemon/InputInjector.kt`, `docs/06-user/keyboard-and-text-input.md`, `Tests/IntegrationTests/AndroidInputTests/` |

**Goal.** The user types into an Android text field from the Mac window. Special keys and the common shortcuts work in key mode.

**Result.** `KeyCodeMap` reads the US key map from the CSV. The translator covers key down and up, modifiers, repeat, Backspace, Enter, arrows, and Escape. Esc and ⌘[ send `BACK`. ⌘C, ⌘X, ⌘V, ⌘A, and ⌘Z send the Ctrl combinations. The IME is not started (#72). Tests are T0 in `InputCoreTests`, T1 in the guest JVM tests, and T2 in `AndroidInputTests`. Known limits: a tap does not reliably focus a field (#102), so the T2 cases move focus with Tab. The JIS layout check is manual check C01-4 in [test-strategy.md](../test-strategy.md) §8.

---

## #101 Input route rebinds after the guest agent is lost

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #25 |
| Design | [input.md](../../02-design/input.md) §3, §7.1; [guest-components.md](../../02-design/guest-components.md) §3.3 |
| Code | `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevBoot.swift`, `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevInputBinding.swift`, `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevInputRoute.swift`, `Packages/RuntimeHost/Sources/RuntimeHost/EmbeddedRuntimeService.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Input/InputRouter.swift`, `Packages/RuntimeHost/Tests/RuntimeHostTests/DevInputBindingTests.swift`, `Packages/RuntimeHost/Tests/RuntimeHostTests/DevInputRouteTests.swift`, `Packages/RuntimeHost/Tests/RuntimeHostTests/EmbeddedRuntimeServiceTests.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Guest/DevelopmentGuestAgent.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Guest/GuestAgentSupervisor.swift`, `Packages/RuntimeCore/Tests/RuntimeCoreTests/GuestAgentSupervisorTests.swift`, `Tests/IntegrationTests/AndroidInputTests/` |

**Goal.** After the guest agent restarts, pointer input works again in the same window without ending the boot. Today the bound channel stays after the loss, so input stays dead until the boot ends. This is a follow-up of #25.

**Result.** `DevInputBinding` releases the old input channel when its Guest Agent session ends and rebinds display 0 when a new session is ready. A shared route gate closes synchronously on loss, generation checks prevent stale activation, and route focus is reconciled before input resumes. A closed window retires its route so Guest Agent recovery cannot re-register that display. Ending a disconnected stream skips redundant guest cancellation. `GuestAgentSupervisorTests` covers loss, rebind, and `input.dropped.channel`; `AndroidInputTests.testWindowInputRebindsAfterGuestAgentRestartWithoutRebooting` verifies on a VM that a click reaches HelloText after `apkrun_guestd` restarts without changing Android's boot ID.

---

## #102 A pointer tap reliably focuses a text field

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #25 |
| Design | [input.md](../../02-design/input.md) §4.1, §7.3 |
| Code | `Packages/InputCore/Sources/InputCore/EventTranslator.swift`, `Guest/guestd/src/main/kotlin/io/apkrun/guest/daemon/InputInjector.kt`, `Packages/WindowingCore/Sources/WindowingCore/IOSurfaceLayerView.swift`, `Tests/IntegrationTests/AndroidInputTests/` |

**Goal.** A click from the Mac window on a text field focuses the field, and the next key goes to it, every time. Today a tap does not reliably focus it, while the same tap through ADB does. This is a follow-up of #25 and #26.

**Steps.**
1. **Compare the sequences.** Compare the Mac press sequence with an ADB tap at the same point: press timing, pointer ID, move during the press, and release. **Check:** the difference that fails is named in the pull request.
2. **Reproduce.** Write a T0 or T1 test that replays the failing sequence. **Check:** the test fails before the fix.
3. **Fix in the translator or the injector.** Change `EventTranslator` or `InputInjector`. Do not change the fixture. **Check:** the test passes.
4. **Device run.** Click the field 50 times through the Mac window. **Check:** all 50 focus it, and the adb and drop counters of #25 stay at zero.

**Tests.**
- T0: the reproduction in `Packages/InputCore/Tests/InputCoreTests/`.
- T1: the guest rule in `Guest/guestd/src/test/`, when guest code changes.
- T2: `AndroidInputTests`, the 50-click focus run. Needs a Mac with a VM.
- T3: none.

**Done when.**
- 50 of 50 clicks on the field of HelloText focus it, with the adb counter and the drop counters at zero.
- A T0 or T1 test reproduces the failing sequence and passes after the fix.

**Pitfalls.**
- The keyboard cases of `AndroidInputTests` move focus with Tab, which hides this failure. Do not count them as proof of tap focus.

---

## #103 Trace intermittent click loss during repeated presses

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #24, #73 |
| Design | [input.md](../../02-design/input.md) §4, §8, §11 |
| Code | `Guest/guestd/`, `Tests/Fixtures/AndroidApps/HelloText/` (debug trace and touch trace), `Tests/IntegrationTests/AndroidInputTests/` |

**Goal.** A press from the Mac window is either delivered as a click, or its loss is explained at the stage where it occurs. Some presses do not produce a click, and the cause is not established. This is the follow-up that resolves the click criterion of #25.

**Steps.**
1. **Reproduce in product mode.** Run three consecutive 100-click batches in one guest session on the ordinary input path, without the debug trace. Record the image identity, the fixture APK hash, the persisted counter deltas, the host counters, and the guest rejection totals with their sequence coverage. **Check:** each batch result can be verified from the fixture's persisted counter.
2. **Trace one failure.** Use the opt-in trace (`AndroidInputTrace`) to join the host receipt, the translation, the guest injection result, the fixture DOWN, MOVE, UP, and CANCEL, the click callback, and the persisted count by a sequence or timestamp. **Check:** every event is joined, and the trace reports overflow.
3. **Check the framework.** Map the tested image to the `View`, `InputManager`, `InputManagerService`, and `InputDispatcher` source. If the build cannot be mapped, inspect the framework bytecode and state that limit. **Check:** the proposed cause fits the observed event order.
4. **Correct only with evidence.** Change guest input behavior only if the product-mode trace shows a guest-controlled cause. Add the smallest T0 or T1 regression test. Do not retry on the Mac. If no safe correction is supported, change nothing and record the evidence. **Check:** the regression test fails before the change and passes after it.
5. **Product-path run.** On a dedicated lab GUI session, run `AndroidInputTests/testThreeConsecutiveHundredClickBatchesThroughWindowServer` with `AndroidInputInteractive`, using the command in [build-system.md](../../05-development/build-system.md) §12.4. **Check:** the result bundle holds the image identity, the ACK coverage, and the outcome of each batch.

**Tests.**
- T0 and T1: the exact ordering or timing rule, in `Guest/guestd/src/test/`, if guest code changes. The synthetic checks `AndroidInputTraceJoinTests` run under the `LinuxGuest` selector without a VM.
- T2: `AndroidInputTests` on a dedicated lab GUI session: the three-batch test above, and `testOneHundredClickDiagnosticTraceJoinsHostGuestAndFixture` with `AndroidInputTrace`.
- T3: none.

**Done when.**
- The cause, and the framework source revision of the tested image, are recorded in the pull request. Or a bytecode inspection and its limit are recorded.
- If a safe product correction exists, it has a T0 or T1 regression test, and three consecutive product-mode T2 batches of 100 clicks pass. Each persisted delta is 100, the host drop and coalescing counters are zero, and every normal ACK reports zero guest rejections.
- If the correction changes event timing, #71's `input-latency` scenario shows p95 ≤ 16 ms ([input.md](../../02-design/input.md) §8).
- If no safe correction is supported, the evidence and its limits are recorded, with no speculative change. #25's click criterion then stays open.
- #25's click criterion is met only after the three batches pass.

**Pitfalls.**
- An ACK means the guest queued the event. It does not mean Android dispatched it or that the app clicked.
- Tracing and per-event ACKs can change timing. The acceptance batches run without the debug listener.
- Do not add a host-side retry. It hides the loss.

---

## #27 HelloText in a native Mac window

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #24, #25, #26, #107 |
| Gate | G4 |
| Design | [display-and-windowing.md](../../02-design/display-and-windowing.md) §5.3, §7.3, §7.6; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7, §10; [cli.md](../../02-design/cli.md) §5 |
| Code | `Packages/WindowingCore/Sources/WindowingCore/SessionWindowController.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Input/SessionRegistry.swift`, `Packages/RuntimeHost/Sources/RuntimeHost/EmbeddedRuntimeService.swift`, `CLI/apkrun/Dev/SurfacePoolFrameSource.swift`, `Tests/IntegrationTests/NativeWindowTests/` |

**Goal.** `apkrun dev launch` with HelloText opens a normal Mac window that shows HelloText and accepts mouse and keyboard input. The window has no emulator chrome.

**Out of scope.**
- `DisplayPool` and secondary displays (#29, #30).
- Resize, density, and fullscreen (#68). The window is fixed-size until then.
- The XPC frame path and the wrapper (#69, #32, M7).

**Steps.**
1. **Window.** Write `SessionWindowController`: a normal `NSWindow` with a title and the standard buttons, and no toolbar, device frame, or control buttons. Show the placeholder of [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.3. Replace the #24 development window. **Check:** a T1 screenshot of `IOSurfaceLayerView` with a synthetic `FrameSource`.
2. **Frame source.** Bind `SurfacePoolFrameSource` to the session's `SurfaceSet` ([display-and-windowing.md](../../02-design/display-and-windowing.md) §5.3). **Check:** T2 sees the placeholder, then HelloText.
3. **Sessions.** `SessionRegistry` opens and closes display 0 sessions, calls `ScanoutController` for scanout 0, and follows the session states of [state-machines.md](../../01-architecture/state-machines.md) §3. **Check:** T0 covers the states that apply to display 0.
4. **Launch command.** `apkrun dev launch <apk|package>` boots Android if needed, installs the APK through `AdbClient`, launches it on display 0 through the Guest Agent, and opens the window. **Check:** T2 clicks the button and types into the field.
5. **Close policy.** Closing the window sends `StopApplication` with `FINISH_TASKS` ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.6). The CLI exits 0 after the last window closes. **Check:** T2 receives `TaskVanished` for HelloText.
6. **Gate.** **Check:** `scripts/run-gate.sh G4` passes on the reference Mac.

**Tests.**
- T1: the screenshot test in `Packages/WindowingCore/Tests/WindowingCoreSystemTests/`.
- T2: `NativeWindowTests`: the window, a click, and typing.
- T3: G4 check `G4NativeWindow` ([test-strategy.md](../test-strategy.md) §5): 100 of 100 clicks, `Hello, APKRun 123!`, Esc goes to `screen main`, and the adb shell counter does not change. Manual check C01-5.

**Done when.**
- Launching the test opens a normal Mac window with HelloText. Mouse and keyboard input work.
- No emulator chrome is shown.
- A normal `NSWindow` shows the Android scanout through the IOSurface pool ([ADR-0006](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)).
- Closing the window stops the app with the `stop` policy ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.6).
- The placeholder shows until the first frame.
- G4 passes, meeting its four conditions ([roadmap.md](../roadmap.md) §2).

**Pitfalls.**
- Android's status bar and navigation bar stay on display 0. They are not emulator chrome. Do not trim Android before the baseline works ([AGENTS.md](../../../AGENTS.md) §4).
- Window close sends `FINISH_TASKS`. `FORCE_STOP` is for an explicit terminate, which comes with #33.

---

## #28 RuntimeCore package operations

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #27 |
| Design | [package-store.md](../../02-design/package-store.md) §2.3, §5, §11.1; [runtime-api.md](../../03-reference/runtime-api.md) §8.1 |
| Code | `Packages/APKStoreCore/`, `Packages/RuntimeHost/Sources/RuntimeHost/ADBStoreAgentChannel.swift`, `Packages/RuntimeHost/Sources/RuntimeHost/DevelopmentStoreRuntimeAccess.swift`, `CLI/apkrun/`, `scripts/check-raw-adb.sh`, `Tests/IntegrationTests/PackageStoreTests/` |

**Goal.** Install, launch, terminate, uninstall, list, and inspect use the runtime API, not raw shell commands. ADB stays behind one channel.

**Out of scope.** The Store Agent (#37), host signature and update rules (M6), the CLI `launch` and `stop` (#33), and wrapper deletion (#77).

**Steps.**
1. **Types.** `PackageID`, `VersionCode`, `SHA256Digest`, `ArtifactFile`, `ArtifactSet`, `PackageRecord` (`updateAuthority` is `manual`), `PackageState`, and the APK set digest, in `APKStoreCore`. **Check:** T0 covers `PackageID`, `VersionCode`, and the set digest.
2. **PackageStore.** `open()`, the journal and recovery table ([package-store.md](../../02-design/package-store.md) §5.1, §5.5), and the kinds `firstInstall`, `reinstall`, `uninstall`, and `forget`. `APKRUN_STORE_FAULT=<kind>:<step>` stops a debug build after that step. **Check:** T0 covers the journal and recovery table. T1 crashes at every step of `firstInstall` and `uninstall`.
3. **Inspector and channel.** `APKInspector` v0 reads metadata with `aapt2` and hashes every file; the signature check is `notPerformed`. `ADBStoreAgentChannel` installs with `adb install-multiple -r --no-streaming`, uninstalls with `pm uninstall` (`-k` keeps data), downgrades with `-r -d` on debuggable images, and queries through the Guest Agent. **Check:** T1 with a fake channel, and `APKInspector` on HelloText and HelloSplit.
4. **Runtime operations and CLI.** Add `importPackage`, `installImported`, `listPackages`, `packageInfo`, and `uninstallPackage` ([runtime-api.md](../../03-reference/runtime-api.md) §8.1), and embedded `launch` and `terminate`. Without a session, `terminate` force-stops with `StopApplication`. Add the CLI `install`, `uninstall`, `list`, and `info`. **Check:** after `apkrun-dev install Tests/Fixtures/apks/HelloText.apk`, `apkrun-dev list` shows its versionCode.
5. **Lint and migration.** `scripts/check-raw-adb.sh` rejects `adb shell` and `pm` package commands outside `ADBStoreAgentChannel`, `AdbClient`, and the allowlist (`scripts/dev/`, `Images/tools/reference/`). Move the #17 and #18 tests to the runtime API. **Check:** the lint passes on `main` and fails on a planted raw call.
6. **HelloSplit.** The fixture is specified in [test-strategy.md](../test-strategy.md) §4.2. **Check:** the split set installs as one package.

**Tests.**
- T0: `Packages/APKStoreCore/Tests/APKStoreCoreTests/`: types, journal, and recovery table.
- T1: `Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`: crash injection and the raw-ADB lint.
- T2: `PackageStoreTests`: install, split install, uninstall with and without data, reinstall, downgrade.
- T3: none.

**Done when.**
- The CLI and the tests use runtime API package operations, and the raw-ADB lint passes.
- `install`, `launch`, `terminate`, `uninstall`, `listInstalled`, and `applicationInfo` exist with the mapping of [package-store.md](../../02-design/package-store.md) §11.1. ADB is used only inside `ADBStoreAgentChannel` and `AdbClient`.
- An installed package has `Packages/io.apkrun.fixture.hellotext/current/{base.apk,artifact.json,metadata.json}`.
- A crash at any step of `firstInstall` or `uninstall` is recovered at the next `open()`. Uninstall keeps or deletes the app data, as asked.
- HelloSplit installs as one package with all its splits.

**Pitfalls.**
- `APKInspector` is for previews only. `PackageManager` is the source of truth ([AGENTS.md](../../../AGENTS.md) §4, invariant 12).

---

## #68 Retina, density, and resize

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #27 |
| Design | [display-and-windowing.md](../../02-design/display-and-windowing.md) §6, §7.1, §7.2, §7.4, §7.7; [graphics.md](../../02-design/graphics.md) §6.4 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Display/DisplayGeometryResolver.swift`, `Packages/GraphicsCore/Sources/GraphicsCore/Display/EDIDGenerator.swift`, `Packages/WindowingCore/Sources/WindowingCore/SessionWindowController.swift`, `Guest/guestd/src/main/kotlin/io/apkrun/guest/daemon/DisplayService.kt`, `Tests/IntegrationTests/NativeWindowTests/` |

**Goal.** The Android display follows the size and backing scale of the Mac window. Text is sharp at zoom 1, resizing re-lays out the app, and moving the window to another screen changes the density. This task builds `DisplayGeometryResolver`, which #29 uses.

**Out of scope.** Pool displays (#29), the XPC frame path (#69), and the IME (#72).

**Steps.**
1. **Resolver.** Write `DisplayGeometryResolver` with the formula and limits of [display-and-windowing.md](../../02-design/display-and-windowing.md) §6.1 and §6.2. **Check:** T0 table tests for Retina, non-Retina, the 4095 cap, the zoom clamp, and the minimum size.
2. **Density and EDID.** `SetDisplayPolicy` applies the density ([display-and-windowing.md](../../02-design/display-and-windowing.md) §4). The EDID carries the physical size ([graphics.md](../../02-design/graphics.md) §6.4). **Check:** T0 golden EDIDs, and T2 reads the density from `wm density`.
3. **Resize.** Implement the sequence of [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.1, the backing-scale change ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.2), fullscreen ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.4), and zoom. **Check:** T2 resize and backing-scale change.
4. **Display ID.** Run the display-ID stability test of [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.1 (R-04). If the ID changes, use fallback B: a fixed size and `window.resizable = false`. **Check:** the result is in the pull request.
5. **Orientation and OQ-39.** Write the orientation decision into [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7. Check how the EDID physical size changes the density on display 0 (OQ-39). **Check:** both answers are in the pull request.

**Tests.**
- T0: the resolver table in `Packages/RuntimeCore/Tests/RuntimeCoreTests/`, the mapper generation change in `Packages/InputCore/Tests/InputCoreTests/`, and the EDID size in `Packages/GraphicsCore/Tests/GraphicsCoreTests/`.
- T2: `NativeWindowTests`: resize and backing-scale change.
- T3: C01-1: Retina sharpness, and non-Retina if a screen is available.

**Done when.**
- On a Retina Mac, a 480 × 850 pt window shows a 960 × 1700 px display at 320 dpi.
- Text is sharp: there is no scaling at `zoom = 1`.
- Resizing re-lays out HelloCompose without restarting the app process, if the app handles configuration changes.
- Moving the window to a non-Retina screen switches to 160 dpi and 480 × 850 px.
- The resize policy is the sequence of [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.1, or fallback B, and the R-04 result is recorded.
- Input hits the right point after a resize.
- The orientation decision is in [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7.

**Pitfalls.**
- A frame of the old size can arrive after `surfacesReplaced`. Drop frames whose generation is older than the current one.

---

## #29 DisplayPool

| Field | Value |
|---|---|
| Milestone | M3 (v0.2) |
| Depends on | #28, #68 |
| Design | [display-and-windowing.md](../../02-design/display-and-windowing.md) §3, §4; [graphics.md](../../02-design/graphics.md) §4.3 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Display/DisplayPool.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Input/SessionRegistry.swift`, `Packages/GraphicsCore/Sources/GraphicsCore/Display/ScanoutController.swift`, `Guest/guestd/src/main/kotlin/io/apkrun/guest/daemon/DisplayService.kt`, `CLI/apkrun/Dev/` (`dev displays`), `Tests/IntegrationTests/DisplayPoolTests/` |

**Goal.** `DisplayPool` allocates, releases, and reuses the Android displays on scanouts 1–15 in one place. Displays are reused without stale scanouts or conflicting IDs.

**Out of scope.** Apps on pool displays (#30) and two sessions (#31).

**Steps.**
1. **Pool with fakes.** Write the `DisplayPool` actor (`acquire`, `reconfigure`, `release`, `snapshot`, `events`) with the slot states, serialized acquire and release, and fault retry of [display-and-windowing.md](../../02-design/display-and-windowing.md) §3.2–§3.5. Each lease carries a `SessionID`. Test against `FakeScanoutController` and `FakeDisplayControlChannel`. **Check:** T0 state machine tests and the invariant 2 property test.
2. **Reuse rules.** A lease gets a fresh `SurfacePool`, and the placeholder shows until its first frame. `display.maxSessions` (default 8) bounds the pool, and a request beyond it fails with `displayPoolExhausted` ([display-and-windowing.md](../../02-design/display-and-windowing.md) §2, §10). **Check:** T0.
3. **Guest messages.** The Guest Agent sends `DisplayAdded`, `DisplayChanged`, and `DisplayRemoved` with product info, and handles `ClearDisplay`, `TasksCleared`, and task events, with the settings of [display-and-windowing.md](../../02-design/display-and-windowing.md) §4. **Check:** T1 JVM tests.
4. **Hotplug on Android.** Enable scanout 1 at runtime. Wait 5 s for `DisplayAdded` with product info `APK` and the scanout index as product code. If no event arrives, use fallback A, then B, then C ([graphics.md](../../02-design/graphics.md) §4.3). **Check:** T2 sees the display, and the result is in the pull request.
5. **Integration.** Connect `DisplayPool` to `ScanoutController` and the Guest Agent. `SessionRegistry` uses `acquire` and `release`. Add `apkrun dev displays` with `add --size <WxH> --dpi <n>`, `remove <scanout>`, and `list` in one live session. **Check:** `add --size 960x1700 --dpi 320` creates a display that `list` shows, and `remove` frees it.
6. **Pool-display checks.** Repeat the display-ID test (R-04) and the density check (OQ-39) on a pool display. Measure the host memory per display (R-08). **Check:** the results are in the pull request.

**Tests.**
- T0: `Packages/RuntimeCore/Tests/RuntimeCoreTests/`: the state machine and the invariant 2 property test.
- T2: `DisplayPoolTests`: 50 acquire and release cycles across slots, with no stale frames, no duplicate Android display IDs, and every slot `free` at the end.

**Done when.**
- The slot lifecycle of [display-and-windowing.md](../../02-design/display-and-windowing.md) §3.2 is implemented, including `faulted`.
- Each allocation is tied to its package and window through `SessionID`.
- 50 cycles pass with no stale scanouts or conflicting IDs, and every slot is `free` at the end.
- A request beyond `display.maxSessions` fails with `displayPoolExhausted`.
- The hotplug result is recorded, the fallback in use is implemented, and the host memory per display is measured.

**Pitfalls.**
- Wait for `DisplayRemoved` before a slot becomes `free` (3 s, [display-and-windowing.md](../../02-design/display-and-windowing.md) §3.4). A reused slot can receive the old display's events.

---

## #30 App on a secondary Android display

| Field | Value |
|---|---|
| Milestone | M3 (v0.2) |
| Depends on | #29 |
| Design | [display-and-windowing.md](../../02-design/display-and-windowing.md) §3.6, §4, §8; [guest-protocol.md](../../02-design/guest-protocol.md) §7.1; [guest-components.md](../../02-design/guest-components.md) §6.4 |
| Code | `Guest/guestd/src/main/kotlin/io/apkrun/guest/daemon/LaunchService.kt`, `Packages/RuntimeCore/Sources/RuntimeCore/Display/DisplayPool.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Input/SessionRegistry.swift`, `CLI/apkrun/Dev/` (`dev launch --display`), `Tests/Fixtures/AndroidApps/HelloWebView/`, `Tests/IntegrationTests/DisplayPoolTests/` |

**Goal.** HelloText renders correctly on a non-primary Android display, in its own Mac window, and accepts input.

**Out of scope.**
- Two sessions at the same time (#31).
- The per-app compatibility setting in the UI (#80).
- The compatibility runs of real apps (#91).

**Steps.**
1. **Launch on a display.** `LaunchService` launches `LaunchApplication(package, displayID)` with the launch options of [display-and-windowing.md](../../02-design/display-and-windowing.md) §4. **Check:** T1 JVM test of the launch options.
2. **Development command.** `apkrun dev launch --display secondary <apk>` acquires a pool display and opens the window on its scanout. **Check:** T2 shows HelloText on a pool display.
3. **Compatibility mode.** `apkrun dev launch --display 0 <apk>` leases display 0 in `primaryDisplayCompatibility` mode ([display-and-windowing.md](../../02-design/display-and-windowing.md) §3.6, §8). **Check:** T2 launches HelloText this way, and a second request for display 0 fails with `primaryDisplayBusy`.
4. **Fixture runs.** Run HelloText, HelloCompose, HelloGL, and HelloWebView on a secondary display. For each app, record whether rendering, input, IME, and dialogs work. Repeat the OQ-31 pointer check there. Fixture specs are in [test-strategy.md](../test-strategy.md) §4.2. **Check:** the table of results is in the pull request, and it is the seed list for #91.
5. **Acceptance run.** **Check:** `DisplayPoolTests` passes on the reference Mac.

**Tests.**
- T1: the launch options, in `Guest/guestd/src/test/`.
- T2: `DisplayPoolTests`: HelloText on a secondary display, clicked and typed into. The HelloCompose, HelloGL, and HelloWebView results. The compatibility lease and `primaryDisplayBusy`.
- T3: none.

**Done when.**
- An additional virtual display is created or enabled through `DisplayPool`.
- HelloText launches with a selected display ID, and its scanout is mapped to a Mac window.
- HelloText renders correctly on a non-primary display and accepts input.
- The `primaryDisplayCompatibility` mode works, and a second request gets `primaryDisplayBusy`.
- The results of the four fixtures are recorded for the #91 seed list.
- OQ-31 has an answer for pool displays.

**Pitfalls.**
- An app that ignores the launch display appears on display 0. Record such an app in the seed list.
- If the task does not appear on the target display, the agent answers `TIMEOUT` after 2 s ([guest-components.md](../../02-design/guest-components.md) §6.4).

---

## #31 Two APKs in two native windows

| Field | Value |
|---|---|
| Milestone | M3 (v0.2) |
| Depends on | #30 |
| Gate | G5 |
| Design | [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.5, §7.6; [input.md](../../02-design/input.md) §7.2, §7.3; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7; [graphics.md](../../02-design/graphics.md) §7 |
| Code | `Packages/RuntimeCore/Sources/RuntimeCore/Input/InputRouter.swift`, `Packages/RuntimeCore/Sources/RuntimeCore/Input/SessionRegistry.swift`, `Packages/WindowingCore/Sources/WindowingCore/SessionWindowController.swift`, `Guest/guestd/src/main/kotlin/io/apkrun/guest/daemon/TaskService.kt`, `CLI/apkrun/Dev/`, `Tests/IntegrationTests/DisplayPoolTests/`, `Tests/AcceptanceTests/` (G5) |

**Goal.** Two Android apps run at the same time in two independent Mac windows, each on its own Android display. Input goes only to the app of the focused window.

**Out of scope.**
- The IME on secondary displays (#72).
- Windows owned by the wrapper over XPC (#69, #32).
- The full latency run (#71).

**Steps.**
1. **Two sessions.** `apkrun dev launch <apk1> <apk2>` opens two sessions on two pool displays, in two windows. HelloCompose is the second test APK ([test-strategy.md](../test-strategy.md) §4.2). **Check:** T2 shows both apps.
2. **Focus and routing.** The key window sends `focusChanged`, and the agent's `FocusDisplay` calls `setFocusedTask` ([input.md](../../02-design/input.md) §7.2). A window that loses focus sends `.cancelAll` for its session. `InputRouter` drops events for a display that its session does not own. **Check:** T0 ownership tests, and T2 typing and clicking reach only the focused app.
3. **Close one.** Closing a window stops only its app ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.6) and releases its display. The other session keeps running. **Check:** T2.
4. **Measurement.** Run HelloGL in both windows, and read the statistics of [graphics.md](../../02-design/graphics.md) §7: fps, present time p95, and memory (R-03). **Check:** the results are in the pull request.
5. **Gate.** **Check:** `scripts/run-gate.sh G5` passes on the reference Mac, and manual check C02-1 is recorded.

**Tests.**
- T0: `Packages/RuntimeCore/Tests/RuntimeCoreTests/`: `InputRouter` ownership.
- T2: `DisplayPoolTests`: two sessions, and routing to the focused window.
- T3: G5 check `G5TwoWindows` ([test-strategy.md](../test-strategy.md) §5), manual check C02-1 (focus moves correctly between HelloText and HelloCompose), and the v0.2 checklist.

**Done when.**
- HelloCompose is the second test APK.
- Two displays and two windows are allocated.
- Typing and clicking go only to the focused window's app.
- Two Android apps run at the same time in two independent Mac windows.
- Closing one window leaves the other app running and interactive.
- G5 passes, meeting its three conditions ([roadmap.md](../roadmap.md) §2).
- The two-display measurement is recorded.

**Pitfalls.**
- A drag in progress when focus moves must end with `.cancelAll`. Otherwise the first app keeps a finger down.
- In M3, key mode is used on every display. The IME comes with #72.

---

## #100 Parallel VM test runs

| Field | Value |
|---|---|
| Milestone | M3 (v0.1) |
| Depends on | #15 |
| Design | [test-strategy.md](../test-strategy.md) §3.9, §3.10 |
| Code | `Tests/IntegrationTests/RunResources/`, `Packages/RuntimeCore/Sources/RuntimeCore/Supervisor/RuntimeSupervisor.swift`, `Tests/IntegrationTests/AndroidSupport/AndroidBootSession.swift`, `Tests/IntegrationTests/AndroidBootTests/AndroidBootFixture.swift`, `Tests/IntegrationTests/AndroidADBTests/`, `Tests/AcceptanceTests/G2AndroidBoot/` |

**Goal.** Two VM test runs can run on one Mac at the same time without sharing a port, a home, or a capture directory. The product default ADB host port `6520` stays. Until this task is done, the one-VM-at-a-time rule of [test-strategy.md](../test-strategy.md) §3.6 holds.

**Steps.**
1. **Per-run home.** `VMRunResources` gives each run its own home, `/tmp/apkrun-vm-<UUID>`, and a capture directory beside it. Every VM test uses that home as `APKRUN_HOME`, and removes it at teardown. The path stays under the 103-byte console socket limit. **Check:** no two runs share a home, and no `/tmp/apkrun-vm-<UUID>` remains after a run, except the G2 capture.
2. **ADB port.** `APKRUN_TEST_ADB_PORT` (set from `TEST_RUNNER_APKRUN_TEST_ADB_PORT`) selects the port. When it is unset or empty, the port is 0, and the kernel chooses a free loopback port. The supervisor reports the bound port as `developmentADBHostPort`. **Check:** `AndroidADBTests` reports the port, and the product default stays 6520 (`BootOptions.adbHostPort`).
3. **Fixed paths.** Replace each fixed test path that a VM test reaches (the test homes and the G2 capture path in [test-strategy.md](../test-strategy.md) §3.10) with a per-run path. **Check:** a grep of the test sources finds no fixed test home.
4. **Parallel checks.** Run checks 1–5 and 7–8 of [test-strategy.md](../test-strategy.md) §3.10 on the reviewed commit, first alone and then in parallel. The G2 gate runs alone under the lock. **Check:** the results are in the pull request.

**Tests.**
- T0: `VMRunResourcesTests`, with `swift test --skip SystemTests`.
- T2: `AndroidADBTests` and `AndroidBootTests`, run in parallel. Each run has its own `-derivedDataPath` and `-resultBundlePath`.
- T3: G2 gate under `lockf`, with the same report fields as before.

**Done when.**
- `AndroidADBTests` and `AndroidBootTests` pass when run at the same time, on different ports.
- A developer boot with the default home keeps `127.0.0.1:6520` while a test runs.
- No run leaves a test home behind.
- The G2 gate passes under the lock with the same report fields.
- `swift test --skip SystemTests` passes.

**Pitfalls.**
- Do not run a producer (`scripts/run-gate.sh`, `build-test-*.sh`, `fetch-test-linux.sh`) while two VM runs are active. Producers rewrite the shared artifact directory `APKRUN_TEST_LINUX_DIR`.
- Two `xcodebuild` runs that share a DerivedData or result bundle path overwrite each other. Give each run its own paths.
- Leave `TEST_RUNNER_APKRUN_TEST_ADB_PORT` unset unless a test needs a fixed port. Never set it to a port that another run uses.
