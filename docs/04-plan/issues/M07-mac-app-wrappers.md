# M7 Mac app wrappers

M7 (v0.4) makes an installed Android app an ordinary Mac app. `apkrun wrap` or the add flow creates a thin, immutable `.app` that opens in its own window from Finder, the Dock, and Spotlight, and keeps working while APKRun updates the app behind it. It closes gate G8 (#45–#48) and gate G9 (#50). Work #45–#48 right after #69, before M5 and M6, because they need neither the custom image nor the update system. After M6, work #56, #57, #49, #50, #76, #77, #78, #79, #80, and #90, in that order. A wrapper never contains the Android app's version, and its bundle ID is deterministic: `io.apkrun.android.<mapped package>` ([wrapper.md](../../02-design/wrapper.md) §4.1).

---

## #45 Launcher as a wrapper (APKRunLauncher)

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #33, #69 |
| Design | [wrapper.md](../../02-design/wrapper.md) §3, §5, §7.2, §7.3 |
| Code | `Apps/APKRunLauncher/`, `Packages/RuntimeAPI/`, `Packages/RuntimeClient/`, `Packages/RuntimeCore/`, `Packages/RuntimeHost/`, `Packages/WindowingCore/`, `Packages/WrapperCore/`, `CLI/apkrun/Commands/WrapperCommands.swift`, `scripts/dev/make-wrapper.sh`, `Tests/IntegrationTests/LauncherTests/` |

**Goal.** A hand-built wrapper opens HelloText in its own window. The launcher reads its identity from the bundle and connects to apkrund as that wrapper. The launcher process owns the window (ADR-0006).

**Out of scope.** Generation and icons (#46, #47, #56). The approval window (#48). Screen U (#58), background mode (#55), **Install from This App** (#90).

**Steps.**
1. **Identity.** Add `WrapperDocument` to `Packages/RuntimeAPI/` with every field of [wrapper.md](../../02-design/wrapper.md) §3 (schema: [wrapper-json.md](../../03-reference/wrapper-json.md)). `WrapperIdentity.load(Bundle.main)` reads the Info.plist keys of [wrapper.md](../../02-design/wrapper.md) §2.1 and `wrapper.json`, and requires `application.packageId == APKRunPackageID`. Otherwise: `wrapperDamaged`. **Check:** T0 encoding and schema tests pass; an unknown `formatVersion` is rejected.
2. **Endpoint.** `RuntimeClient.connect(.wrapper(bundleID))`. apkrund builds `identifier "<bundleId>" and cdhash H"<cdhash>"` from the registry, serves RuntimeAPI majors N and N−1, and allows `openSession` and `packageInfo` only for the registered package ([runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1, NFR-SEC-07). The launcher applies [wrapper.md](../../02-design/wrapper.md) §5.3. **Check:** the T0 matrix passes; a T1 test refuses another package.
3. **Registry and approval.** Create `BundleIDMapper.map(_:)` ([wrapper.md](../../02-design/wrapper.md) §4.1); #46 reuses it. Add `WrapperRegistry` ([wrapper.md](../../02-design/wrapper.md) §7.2) and `WrapperApprovalService` ([wrapper.md](../../02-design/wrapper.md) §7.3): the broker's `requestApprovalEndpoint`, `.control` `approveWrapper` and `decideApproval`, and events `approvalRequested` and `approvalResolved`. Only apkrund writes the registry, atomically. **Check:** T0 mapper table and 1,000 random IDs pass; T1 approval tests pass.
4. **`apkrun wrapper approve`.** `.control` op `approveWrapper(url)` runs steps 1–3 and 5 of [wrapper.md](../../02-design/wrapper.md) §7.3 with the CLI as confirmer. The CLI prints the prompt facts ([host-ui.md](../../02-design/host-ui.md) §10.1). `--yes` skips the question; without a TTY and `--yes`, exit with `cli.confirmationRequired`. **Check:** golden tests pass; an approved hand-built wrapper connects.
5. **Screens.** In `Apps/APKRunLauncher/`, implement the startup of [wrapper.md](../../02-design/wrapper.md) §5.2 and screens R, S, V, L, A, N, D, T, E of [wrapper.md](../../02-design/wrapper.md) §5.4 in the #69 session window, with `LauncherStrings`, `LauncherMenus` ([wrapper.md](../../02-design/wrapper.md) §5.6), and the debug switch `APKRUN_LAUNCHER_TEST_NO_RUNTIME=1` ([configuration.md](../../03-reference/configuration.md) §5.1). **Check:** each screen appears in the T2 tests.
6. **Hand-built wrapper.** `scripts/dev/make-wrapper.sh <package> <out-dir> [--minimum-version <v>] [--package-id <id>]` copies the launcher, writes Info.plist and `wrapper.json`, signs as in [wrapper.md](../../02-design/wrapper.md) §7.1, and runs `apkrun wrapper approve --yes`. Never shipped. **Check:** `scripts/dev/make-wrapper.sh io.apkrun.fixture.hellotext /tmp/w` passes `codesign --verify --strict`.

**Tests.**
- T0: `WrapperDocument` encoding and schema; the matrix of [wrapper.md](../../02-design/wrapper.md) §5.3 (`APKRunLauncherTests`, sources in `Tests/IntegrationTests/LauncherTests/`).
- T1: approval with a fake UI client (approve, deny, timeout, rate limit, replacement); registry writes; cross-package refusal (`Packages/WrapperCore/Tests/`).
- T2 (`Tests/IntegrationTests/`): hand-built `HelloText.app` launches HelloText; screens R, S, V (`--minimum-version 99.0`), L (launcher two majors behind), D (`--package-id`). A changed copy and a re-signed launcher need approval.
- T3: C04-6 and the #45 part of C04-7.

**Done when.**
- After `apkrun wrapper approve`, `open HelloText.app` shows HelloText in the launcher's window.
- Screen D on a mismatched `packageId`; screen S retries every 2 s for 60 s; screen V with `runtime.minimumVersion` 99.0; each screen has its action and **Quit**.
- A launcher one RuntimeAPI major behind still opens its app (NFR-CMP-02).
- The executable is a byte copy of the generic launcher with a new signature (FR-WRP-06), `arm64` only.
- Only the wrapper's own package opens; modified or re-signed copies need approval (NFR-SEC-07).
- Unknown wrapper: screen A until approved; Don't Allow shows "APKRun did not allow ‹App› to open." Translocated wrapper: screen T, no approval.
- Startup steps 1–5: at most 150 ms p50, with no network or signature check.

**Pitfalls.**
- The launcher never reads `~/Library/Application Support/APKRun/` or writes into its bundle; a write breaks the seal.
- Do not set `LSUIElement` (R-19).
- Screen R needs "no APKRun.app" and "no Mach answer". Release builds must not contain the debug switch ([test-strategy.md](../test-strategy.md) §3.3).

---

## #46 WrapperCore generator

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #45 |
| Design | [wrapper.md](../../02-design/wrapper.md) §2, §4.3, §6.2, §6.4, §6.5, §7.2 |
| Code | `Packages/WrapperCore/Sources/WrapperCore/` (`WrapperFileName`, `AppWrapperGenerator`, `WrapperConfiguration`, `WrapperInstaller`, `WrapperRegistry`, `WrapperValidator`, `InfoPlistWriter`), `Packages/RuntimeHost/`, `Packages/WrapperCore/Tests/` |

**Goal.** WrapperCore generates `<name>.app` for a package with the bundle ID from #45. Generating twice gives byte-identical files, and the bundle passes validation and opens from Finder.

**Out of scope.** Signing and `createWrapper` (#47; T1 tests sign with a helper until then). Icons (#56). `placeStagedWrapper` and other destinations (#57). Portable and distribution kinds (#90, #89). Refresh and removal (#77).

**Steps.**
1. **File names.** `WrapperFileName` ([wrapper.md](../../02-design/wrapper.md) §4.3). **Check:** T0 cases pass; `io.apkrun.fixture.odd_name` maps to `io.apkrun.android.io.apkrun.fixture.odd-name`.
2. **Generator.** `AppWrapperGenerator.generate(_:)` runs steps 1–7 of [wrapper.md](../../02-design/wrapper.md) §6.2 into `Wrappers/staging/<uuid>/<name>.app`. It writes the files of [wrapper.md](../../02-design/wrapper.md) §2 for a non-portable wrapper: Info.plist (`InfoPlistWriter`), `PkgInfo`, `wrapper.json` (`WrapperDocument`; no version, APK path, or digest), `AppIcon.icns` (host preview or placeholder), and the launcher by `clonefile`. Modes 0644 and 0755. Emit `WRAPPER_GENERATE_START` and `WRAPPER_GENERATE_END`. Errors: `launcherTemplateInvalid`, `wrapperExists`. **Check:** a T1 test generates `HelloText.app`; the tree matches [wrapper.md](../../02-design/wrapper.md) §2.
3. **Placement.** `WrapperInstaller` places the bundle with `rename`, or copies and renames across volumes. Conflicts follow [wrapper.md](../../02-design/wrapper.md) §6.4: only this package's wrapper is replaced, else `nameConflict`. Then `LSRegisterURL(final, true)` and `noteFileSystemChanged`; an error is a `registrationFailed` warning. Never run `mdimport`. **Check:** T1 conflict cases pass.
4. **Registry and recovery.** `WrapperRegistry` writes a `pending` entry before placement and `active` after ([wrapper.md](../../02-design/wrapper.md) §6.2 steps 10, 12). One entry per bundle ID. `recover()` at apkrund start activates a `pending` entry whose bundle exists; otherwise it deletes staging and `.apkrun-<uuid>` leftovers. A corrupt file becomes `registry.json.corrupt-<timestamp>` (`registryUnavailable`). Add `wrappers.registry`. **Check:** T1 recovery passes for a crash after each step of [wrapper.md](../../02-design/wrapper.md) §6.2.
5. **Structural validation.** `WrapperValidator.verify(url, deep: false)`, exposed as `verifyWrapper` on `.control`, runs checks 1–3 and 5 of [wrapper.md](../../02-design/wrapper.md) §9.1 and validates the layout and `wrapper.json`. Add `wrappers.template`. **Check:** T1 passes on a generated bundle and fails without `wrapper.json`.

**Tests.**
- T0: `WrapperFileName` with `/`, `:`, emoji ZWJ sequences (OddName), 300-byte and empty names.
- T1 (temporary directory, test signing helper): two generations give the same SHA-256 for every file ([wrapper.md](../../02-design/wrapper.md) §6.5); conflicts; `pending` recovery; atomic writes, corrupt file, one entry per bundle ID; structural validation.
- T2 (`Tests/IntegrationTests/`): `NSWorkspace.open` works; `mdls -name kMDItemContentType` reports `com.apple.application-bundle`.
- T3: none.

**Done when.**
- The bundle contains only the files of [wrapper.md](../../02-design/wrapper.md) §2 for a non-portable wrapper.
- `io.apkrun.fixture.odd_name` maps to `io.apkrun.android.io.apkrun.fixture.odd-name` (FR-WRP-05).
- Two generations give byte-identical trees. If `codesign` or `iconutil` is not deterministic, the test excludes that file and says why.
- `wrapper.json` has no versionCode, versionName, APK path, or digest (FR-WRP-03).
- An existing item is never replaced unless it is this package's wrapper and the request allows it.
- After `recover()`, a crash at any step leaves a complete active wrapper or nothing.

**Pitfalls.**
- Settle OQ-01 first. The `io.apkrun.android.` prefix is permanent; the default is `io.apkrun`.
- `WrapperCore` never reads APKs or package state; everything arrives through `WrapperConfiguration` ([modules.md](../../01-architecture/modules.md) §2).
- The template's version and API come from `LauncherBuild`, not from the APKRun.app version.

---

## #47 Generate Hello.app

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #46 |
| Design | [wrapper.md](../../02-design/wrapper.md) §6.2, §7.1, §12.1; [package-store.md](../../02-design/package-store.md) §10.1; [cli.md](../../02-design/cli.md) §4.4 |
| Code | `Packages/WrapperCore/Sources/WrapperCore/WrapperSigner.swift`, `Packages/RuntimeHost/`, `Daemon/apkrund/` (`.control`), `Packages/RuntimeAPI/`, `CLI/apkrun/Commands/Wrap.swift`, `Tests/IntegrationTests/` |

**Goal.** From the installed HelloText package, apkrund creates `HelloText.app` (the Android label as name, the icon, the package ID), signs it ad-hoc, and records its cdhash. `open HelloText.app` starts the launcher, which opens HelloText.

**Out of scope.** `apkrun wrap <file.apk>` (#76). Rendered icons (#56). `~/Applications` checks, `LSRegisterURL` checks, Spotlight (#57). Developer ID (#89).

**Steps.**
1. **Sign.** `WrapperSigner.sign(_:)` runs `/usr/bin/codesign --force --sign - --identifier <bundleID> --options runtime --timestamp=none <app>` as the last write. Then `SecStaticCodeCheckValidity` (`kSecCSStrictValidate | kSecCSCheckAllArchitectures`, requirement `identifier "<bundleID>"`), and it returns the cdhash from `kSecCodeInfoUnique`. Errors: `signingFailed(status:message:)`, `verificationFailed`. Never `--deep` (TN2206). **Check:** a T1 test gets a 40-character cdhash.
2. **Registry and `createWrapper`.** The `pending` entry gets the cdhash, `launcherVersion`, `launcherAPI`, and `approval: generated` ([wrapper.md](../../02-design/wrapper.md) §6.2 step 9). Add `createWrapper(WrapperRequest{packageID, destination, fileName?, displayName?, iconFile?, portable, replace})` on `.control` as a long operation. RuntimeHost fills `WrapperConfiguration` from the package record and the store's icon ([package-store.md](../../02-design/package-store.md) §10.1). It returns `WrapperInfo` and posts `created`. **Check:** the registry has an `active` entry, and the launcher endpoint accepts the wrapper without approval.
3. **`apkrun wrap <package>`.** `[--output <dir>] [--json]` in `CLI/apkrun/Commands/Wrap.swift`. `--output` defaults to `~/Applications` and is sent as an absolute path. `--json` prints `WrapperInfo` ([cli.md](../../02-design/cli.md) §4.4). **Check:** golden tests pass for success, `packageNotInstalled`, `wrapperExists`.

**Tests.**
- T0: `apkrun wrap` golden output, human and JSON, against a fake `RuntimeService` ([cli.md](../../02-design/cli.md) §6.3).
- T1: signing and cdhash; two generations give identical trees, including `_CodeSignature/CodeResources`.
- T2 (`Tests/IntegrationTests/`): `apkrun wrap io.apkrun.fixture.hellotext --output <suite folder>`; `codesign -dv` shows `Signature=adhoc` and the identifier; `codesign --verify --strict` passes; `NSWorkspace.open` starts the launcher, and HelloText logs `start`.
- T3: none.

**Done when.**
- `HelloText.app` has the Android label as `CFBundleDisplayName` and bundle name, the HelloText icon (host preview until #56), and `APKRunPackageID` `io.apkrun.fixture.hellotext`.
- Its bundle ID is `io.apkrun.android.io.apkrun.fixture.hellotext`.
- `codesign -dv` shows `Signature=adhoc`; `codesign --verify --strict` passes (FR-WRP-10).
- The registry entry has the cdhash, `approval: generated`, and state `active`; no approval prompt appears.
- The bundle is at most 8 MiB (NFR-RES-03), has no `com.apple.quarantine` attribute, and opens without a Gatekeeper dialog.

**Pitfalls.**
- The CLI resolves `--output` with the user's file access; apkrund never does ([cli.md](../../02-design/cli.md) §4.4).

---

## #48 Launch Hello.app end to end

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #47, #32 |
| Gate | G8 |
| Design | [wrapper.md](../../02-design/wrapper.md) §5, §7.3; [host-ui.md](../../02-design/host-ui.md) §3.3, §10.1; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7.2 |
| Code | `Apps/APKRun/Features/Approvals/`, `Apps/APKRun/Models/ApprovalCenter.swift`, `Apps/APKRun/Features/Settings/` (`SettingsScene.swift`, `PrivacyPane.swift`), `Apps/APKRun/APKRunApp.swift`, `Packages/RuntimeHost/` (wrapper branch of `launch`, `pendingApprovals`, `deniedWrappers`, `clearWrapperDenial`), `Tests/AcceptanceTests/G8Wrapper` |

**Goal.** Double-clicking `HelloText.app` in Finder shows an interactive HelloText window, with the runtime stopped or warm, and no terminal. The flow is wrapper → launcher → XPC → apkrund → DisplayPool → Android activity → the launcher's NSWindow. This task closes gate G8.

**Out of scope.** Dock and Spotlight after a logout (#57); the Dock check here is "Keep in Dock" in the same session. Portable approval (#90). New launcher screens.

**Steps.**
1. **Approval window.** `ApprovalCenter` answers `approvalRequested` with `decideApproval` and calls `pendingApprovals` on connect ([wrapper.md](../../02-design/wrapper.md) §7.3 step 4). `Window(id: "approval")` uses the layout of [host-ui.md](../../02-design/host-ui.md) §10.1; **Allow** is not the default button; requests queue one at a time. When APKRun.app is not running, apkrund opens it with `--approve` and `activates = true`, showing only the approval window ([host-ui.md](../../02-design/host-ui.md) §3.3). **Check:** the T1 XCUITest passes.
2. **Denied list.** Add the `Settings` scene with only `PrivacyPane.swift`; #80 adds the rest. Privacy lists **Mac apps you didn't allow** from `deniedWrappers`; **Remove** calls `clearWrapperDenial(bundleID)` ([wrapper.md](../../02-design/wrapper.md) §7.3 step 5). **Check:** T0 DTO round trips pass.
3. **Wrapper branch of `launch`.** `launch(packageID)` opens the registered wrapper with `NSWorkspace.openApplication` when checks 1–3 of [wrapper.md](../../02-design/wrapper.md) §9.1 pass and the cdhash matches; otherwise it opens the generic launcher with `--package <id>` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §7.2). **Check:** `apkrun launch io.apkrun.fixture.hellotext` opens `HelloText.app`.
4. **End-to-end run.** With apkrund as a LaunchAgent (#32), run the flow; measure warm and cold click-to-first-frame with the perf harness (#71). No new wrapper component. **Check:** T2 passes for a warm and a stopped runtime.
5. **G8 check.** `Tests/AcceptanceTests/G8Wrapper` with the assertions of [test-strategy.md](../test-strategy.md) §5, wired into `scripts/run-gate.sh G8`. **Check:** the gate passes on the reference Mac from a clean build of `main`.

**Tests.**
- T0: DTO round trips of the three operations.
- T1 (`Apps/APKRun/UITests/`, XCUITest against the embedded runtime fake): prompt appears; Return does not allow; Don't Allow writes a denied entry; a second request queues; a prompt requested before APKRun.app started shows; **Remove** clears the entry ([host-ui.md](../../02-design/host-ui.md) §15).
- T2 (`Tests/IntegrationTests/`): `NSWorkspace.open` and an XCUITest click reach HelloText (`click <n>`, `text …`); only the wrapper and apkrund start as new processes; Dock launch after "Keep in Dock" with a cold runtime (placeholder, then app) and a warm one.
- T3: `Tests/AcceptanceTests/G8Wrapper` (`scripts/run-gate.sh G8`), never retried.

**Done when.**
- Finder double-click shows an interactive HelloText window: clicks log `click <n>`, and typed text arrives exactly.
- No Terminal window opens, and no process other than the wrapper and apkrund starts. The window is the launcher's NSWindow (ADR-0006).
- The same works from the Dock after "Keep in Dock", with the runtime stopped and warm.
- The G8 conditions of [roadmap.md](../roadmap.md) §2 hold, and `scripts/run-gate.sh G8` passes.
- Return does not allow in the approval window; requests queue; a timeout closes the prompt ([host-ui.md](../../02-design/host-ui.md) §10.1).
- **Mac apps you didn't allow** lists denied wrappers; **Remove** makes the next launch ask again.
- Warm and cold launch times through the wrapper are measured against NFR-PERF-01 (warm p50 ≤ 1.5 s, p95 ≤ 3 s) and NFR-PERF-02 (cold p50 ≤ 40 s).

---

## #56 Android icon to macOS icon pipeline

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #46, #37 |
| Design | [wrapper.md](../../02-design/wrapper.md) §8.2, §8.3, §8.4, §8.5; [package-store.md](../../02-design/package-store.md) §10.2; [guest-protocol.md](../../02-design/guest-protocol.md) §11.1 |
| Code | `Packages/WrapperCore/Sources/WrapperCore/Icons/` (`IconComposer`, `IconsetWriter`, `ICNSWriter`), `Packages/APKStoreCore/`, `Packages/RuntimeCore/`, `Guest/APKRunStore/` (`IconRenderer`), `Packages/GuestProtocol/proto/`, `Packages/WrapperCore/Tests/` |

**Goal.** Every wrapper gets a correct macOS icon made from the Android icon. The Store Agent renders the app's icon layers, the store keeps them, and WrapperCore composes a 1024 px opaque master and writes `AppIcon.icns`. macOS applies its own shape, with no gray plate.

**Out of scope.** Refreshing existing wrappers and **Refresh Dock Icons** (#77). Wrappers never change automatically (FR-WRP-04). Icon Composer files and tinted styles. Stock-image icons, which use the host preview ([package-store.md](../../02-design/package-store.md) §10.2).

**Steps.**
1. **Store Agent render.** `IconRenderer` in `Guest/APKRunStore/` calls `loadUnbadgedIcon`. An adaptive icon draws its background, foreground, and monochrome layers at `size_px` on the full 108 dp canvas; a legacy icon draws its highest-density bitmap. Serve op 107 `RenderIcon(package, size_px)` as PNGs; add the `store.icon.v1` capability to `Hello` ([guest-protocol.md](../../02-design/guest-protocol.md) §11.1). **Check:** a T2 test gets two 1536 px layers for HelloText and one bitmap for IconLegacy.
2. **Store storage.** APKStoreCore calls `RenderIcon(package, 1536)` after install, update, and rollback; writes `Packages/<id>/icon/` and `icon.json`; computes the digest with `IconComposer`; and emits `PackageChange.iconChanged` when it differs ([package-store.md](../../02-design/package-store.md) §10.2). **Check:** a T1 test with a fake channel emits `iconChanged` only on a changed render.
3. **Composition.** `IconComposer` is pure (Core Graphics and ImageIO, no AppKit) and implements [wrapper.md](../../02-design/wrapper.md) §8.2. The master is sRGB, 8 bits per channel, opaque. RuntimeHost passes `.rendered`, else `.preview`, else `.placeholder`. **Check:** T0 rule tests pass.
4. **`.icns` writer.** `IconsetWriter` downscales with Core Graphics (`interpolationQuality = .high`), runs `/usr/bin/iconutil -c icns`, and deletes the iconset. `ICNSWriter` writes the same entries directly and is the fallback when `iconutil` fails or is not deterministic ([wrapper.md](../../02-design/wrapper.md) §8.3, §8.4). Error: `iconConversionFailed`. **Check:** two generations give identical `AppIcon.icns` bytes.
5. **Refresh reason.** Store `iconDigest` in the registry. On `iconChanged`, if the digest differs and there is no custom icon, add the `.icon` reason ([wrapper.md](../../02-design/wrapper.md) §8.5). **Check:** a T1 test adds `.icon` for a changed render, and not for a custom icon.

**Tests.**
- T0 (`Packages/WrapperCore/Tests/`): the rules of [wrapper.md](../../02-design/wrapper.md) §8.2.
- T1: golden 1024 px masters for HelloText and IconLegacy within a perceptual threshold; `.icns` determinism; `iconChanged` and `.icon` with a fake channel.
- T2 (`Tests/IntegrationTests/`, custom image): `RenderIcon` for both fixtures; `AppIcon.icns` matches the golden master ([test-strategy.md](../test-strategy.md) §4.2).
- T3: C04-1 (no gray plate in Finder, the Dock, Spotlight, or the Apps view).

**Done when.**
- HelloText (adaptive, vector layers) and IconLegacy (legacy PNG with transparency, on a white square) show the right icon in Finder, the Dock, and Spotlight.
- The 1024 px masters match the goldens within the threshold.
- An app on the stock image, or not yet rendered, gets the host preview or placeholder; generation never fails for a missing render.
- A changed icon after an update adds the `.icon` reason and does not change the wrapper (FR-WRP-04).
- A custom icon under 512 px, or not square, is refused with `customIconInvalid`.

**Pitfalls.**
- Do not draw a squircle. macOS masks an opaque square cleanly ([wrapper.md](../../02-design/wrapper.md) §8.2).
- Layers are 1536 px because 72/108 of 1536 is exactly 1024. Never upscale ([wrapper.md](../../02-design/wrapper.md) §8.1).

---

## #57 Finder, Dock, and Spotlight integration

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #56 |
| Design | [wrapper.md](../../02-design/wrapper.md) §6.2, §6.3, §7.4, §14; [configuration.md](../../03-reference/configuration.md) §2.10; [cli.md](../../02-design/cli.md) §4.4 |
| Code | `Packages/WrapperCore/` (`WrapperInstaller`, `WrapperDestination`), `Packages/RuntimeHost/`, `Daemon/apkrund/`, `CLI/apkrun/Commands/Wrap.swift`, `Tests/IntegrationTests/` |

**Goal.** A generated wrapper behaves like any Mac app. It can be placed in `~/Applications`, `/Applications`, or a folder the user picks. Spotlight finds it by name, the Dock keeps it across a logout, and Finder lists it as an application, with no indexing tools.

**Out of scope.** The location pop-up and Save panel (#79). `doctor --fix` (#60). Launchpad as a separate product (the Apps view replaces it on macOS 27).

**Steps.**
1. **Destinations.** `WrapperGenerationRequest.destination` accepts `.userApplications` (creates `~/Applications` if missing), `.applications` (admin group, else `destinationNotWritable`), and `.directory(URL)` ([wrapper.md](../../02-design/wrapper.md) §6.3). The CLI defaults to `~/Applications`; the GUI defaults to `wrappers.defaultLocation` ([configuration.md](../../03-reference/configuration.md) §2.10). **Check:** a T2 test places into all three with an admin user; a non-admin gets `destinationNotWritable` for `/Applications`.
2. **Protected folders.** On `EPERM` from the probe in [wrapper.md](../../02-design/wrapper.md) §6.2 step 3, generation finishes signing in staging and returns `destinationNotAccessible(URL, stagingToken)`. The client moves the bundle and calls `placeStagedWrapper(token, finalPath, bookmark)`, which finishes steps 12 and 13. Tokens expire with the staging cleanup. `apkrun wrap --output ~/Desktop/…` moves it itself ([cli.md](../../02-design/cli.md) §4.4). **Check:** a T2 test with a Desktop folder places the wrapper through the client path.
3. **Registration.** The `wrappers.registration` health check reports a registered wrapper that LaunchServices does not know ([wrapper.md](../../02-design/wrapper.md) §14). APKRun never runs `mdimport`, `lsregister`, or any indexing tool. **Check:** in the T2 test, a read-only `lsregister -dump` lists the bundle.

**Tests.**
- T2 (`Tests/IntegrationTests/`): wrappers in `~/Applications` and a Desktop folder pass `plutil -lint`; `mdfind "kMDItemCFBundleIdentifier == 'io.apkrun.android.io.apkrun.fixture.hellotext'"` finds each within 60 s. A quarantined copy opened from a download folder shows screen T and asks for no approval ([wrapper.md](../../02-design/wrapper.md) §7.4). Suites clean up `~/Applications` ([test-strategy.md](../test-strategy.md) §3.9).
- T3: C04-2 (Dock pin survives log out and in), C04-3 (Spotlight launch by label), C04-4 (whether the Apps view lists the Desktop copy).

**Done when.**
- Spotlight finds the wrapper within 60 s, in `~/Applications` and a Desktop folder, and launches `HelloText.app` by its label (C04-3).
- The wrapper can be pinned in the Dock and opened after a logout and login (C04-2).
- A wrapper can be written to a user-selected folder, including the Desktop, through the client path.
- The bundle passes `plutil -lint` and has a bundle ID, display name, icon, and executable.
- No `mdimport` or other indexing tool runs. `/Applications` works for an admin and fails with `destinationNotWritable` otherwise.
- OQ-22 is settled with the C04-4 result. If the Apps view does not list other folders, #79 says so next to **Other…**.

**Pitfalls.**
- `~/Applications` may not exist on a clean account. Create it with default permissions and set no custom folder icon.
- The Dock pins apps by file identity. A refresh must keep it (#77, R-20).

---

## #49 Wrapper independent of the APK file

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #48, #38 |
| Design | [wrapper.md](../../02-design/wrapper.md) §1, §3; [package-store.md](../../02-design/package-store.md) §4.1; [0009-thin-immutable-wrappers.md](../../01-architecture/decisions/0009-thin-immutable-wrappers.md) |
| Code | `Packages/WrapperCore/`, `Packages/APKStoreCore/` (import path), `Packages/RuntimeHost/`, their `Tests/` folders, `Tests/IntegrationTests/` |

**Goal.** The wrapper stores only the app's identity and initial settings. The runtime resolves the installed artifact at every launch. Deleting the original APK, or updating the app, does not affect the wrapper.

**Out of scope.** The full `wrap <file>` table (#76). Updates behind the wrapper (#50).

**Steps.**
1. **Store side.** Confirm that `beginImport` copies the file into `incoming/` and that nothing after it stores or opens the source path ([package-store.md](../../02-design/package-store.md) §4.1). Remove any reference that does. **Check:** a T1 test deletes the source right after `beginImport`, and the install still succeeds.
2. **Wrapper side.** Confirm that `WrapperConfiguration`, `WrapperDocument`, the registry entry, and the bundle hold no import path, file name, versionCode, or digest (FR-WRP-03). The only link to the app is `packageId` (FR-WRP-11). **Check:** a T1 test generates a wrapper from a package imported from `HelloText.apk` and finds no `HelloText.apk` in the bundle.
3. **`--install` for files.** If #76 has not landed, add the row `wrap <file> --install` of [wrapper.md](../../02-design/wrapper.md) §12.2: install with `apkrun install --yes`, then wrap. **Check:** `apkrun wrap HelloText.apk --install --output <suite folder>` works.

**Tests.**
- T1 (`Packages/APKStoreCore/Tests/`): the install succeeds after the source is deleted.
- T1 (`Packages/WrapperCore/Tests/`): no import path or file name in the bundle.
- T2 (`Tests/IntegrationTests/`): `apkrun wrap HelloText.apk --install`, delete the APK, open the wrapper; HelloText starts; `grep -r HelloText.apk` over the bundle finds nothing.
- T3: none.

**Done when.**
- The original APK can be removed, and the wrapper still launches the installed package.
- `wrapper.json` has no version, APK path, or digest (FR-WRP-03).
- The runtime resolves the installed artifact at every launch; the wrapper refers to the app only by `packageId` (FR-WRP-11).
- The store never stores or reads the import source after `beginImport`.

**Pitfalls.**
- File names leak through bookmark data and log strings. Check every field of `wrapper.json`, not only `application`.

---

## #50 Automatic update behind an unchanged wrapper

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #44, #49 |
| Gate | G9 |
| Design | [wrapper.md](../../02-design/wrapper.md) §8.5, §9.1; [update-system.md](../../02-design/update-system.md) §7; [package-store.md](../../02-design/package-store.md) §7; [test-strategy.md](../test-strategy.md) §5 |
| Code | `Packages/WrapperCore/` (`WrapperFileHashes`, deep `verifyWrapper`), `Tests/AcceptanceTests/G9WrapperIntegrity`, `scripts/run-gate.sh`, `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/`, `scripts/dev/update-server.py` |

**Goal.** `HelloUpdate.app` runs V1. APKRun finds V2 in the background and installs it after the app quits. The same wrapper then runs V2 with V1's data, unchanged and not re-signed. This task closes gate G9. The product concept counts as validated only when G9 passes.

**Out of scope.** New update logic; a failure is fixed in the task that owns the failing part. Real update sources (M8).

**Steps.**
1. **Hash list and deep check.** `WrapperFileHashes.compute(bundleURL)` returns a sorted list of relative path and SHA-256 for every regular file: `Contents/MacOS/APKRunLauncher`, `Contents/Info.plist`, `Contents/Resources/wrapper.json`, `Contents/Resources/AppIcon.icns`, and everything under `Contents/_CodeSignature/`. `verifyWrapper(url, deep: true)` adds `SecStaticCodeCheckValidity` ([wrapper.md](../../02-design/wrapper.md) §9.1). **Check:** a T0 test over a fixed directory gives a stable list.
2. **Set up V1.** Install HelloUpdate V1 from `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/1/` in automatic mode, generate `HelloUpdate.app`, open it, and let V1 write `HELLO` to its data. Keep the hash list and cdhash. **Check:** V1's marker is logged.
3. **Update behind the wrapper.** Publish V2 (directory `2`, or Direct through `scripts/dev/update-server.py`). It is staged while V1 runs, and nothing is installed. Quit `HelloUpdate.app`; the gentle-update rules ([update-system.md](../../02-design/update-system.md) §7) install V2. **Check:** the update history shows detection, staging, the wait, and the install.
4. **Run V2 from the same wrapper.** Open `HelloUpdate.app`; V2 logs `data HELLO`. Recompute the hash list, read the cdhash, and run the deep check. **Check:** the values equal the V1 values, and no `codesign` runs on the bundle.
5. **G9 check.** Steps 2–4 go into `Tests/AcceptanceTests/G9WrapperIntegrity`; run `scripts/run-gate.sh G9` on the reference Mac from a clean build of `main`. **Check:** the gate passes.

**Tests.**
- T0: `WrapperFileHashes` stability.
- T2 (`Tests/IntegrationTests/`): steps 2–4 with the LocalProvider and with the Direct test service.
- T3: `Tests/AcceptanceTests/G9WrapperIntegrity` (`scripts/run-gate.sh G9`), with the assertions of [test-strategy.md](../test-strategy.md) §5, never retried; manual check C04-9.

**Done when.**
- V2 runs from the same `HelloUpdate.app` that ran V1 and logs `data HELLO`.
- The SHA-256 of every file in step 1 and the cdhash in `Wrappers/registry.json` are unchanged; no re-signing happened.
- V2 is staged while V1 runs and installed only after `HelloUpdate.app` quits, with no user action.
- `scripts/run-gate.sh G9` passes on the reference Mac.
- The first public demo (C04-9) runs on a clean Mac, with the #36 image bundle picked in onboarding, from the GUI only.

**Pitfalls.**
- A V2 icon change may add only the `.icon` reason (#56), never change the bundle (FR-WRP-04).
- Spotlight can add extended attributes. The hash list covers file contents only.

---

## #76 `apkrun wrap` CLI

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #47, #49 |
| Design | [wrapper.md](../../02-design/wrapper.md) §6.4, §12.2; [cli.md](../../02-design/cli.md) §3.3, §4.2; [update-system.md](../../02-design/update-system.md) §11.3; [configuration.md](../../03-reference/configuration.md) §3.3 |
| Code | `CLI/apkrun/Commands/Wrap.swift`, `CLI/apkrun/Commands/Wrapper.swift` (`verify`, `info`), `CLI/apkrun/Commands/Install.swift` (`--wrap`), `CLI/apkrun/Support/`, `CLI/apkrun/Tests/Golden/`, `Packages/RuntimeHost/` |

**Goal.** `apkrun wrap app.apk` installs an APK and creates its Mac app in one command. It follows the import/install table of [wrapper.md](../../02-design/wrapper.md) §12.2, accepts the alternate flag spellings, and works in scripts with `--yes` and `--json`.

**Out of scope.** `apkrun wrapper list|refresh|remove` (#77); `approve` (#45). `--portable` (#90). `--distribution`, `--identity`, `--notarize` (#89). Japanese strings (#93).

**Steps.**
1. **Arguments.** Parse the syntax of [wrapper.md](../../02-design/wrapper.md) §12.2 with swift-argument-parser. `--update auto` and `--updates auto` mean `automatic`; `--update-provider <type> --update-url <url>` means `--provider <type>:<url>` ([update-system.md](../../02-design/update-system.md) §11.3). `--provider` implies authority `apkrun` ([cli.md](../../02-design/cli.md) §4.2). Invalid combinations exit 64. **Check:** T0 argument tests pass for every alias and invalid combination.
2. **Import/install table.** For a file, call `beginImport` and read the `ImportPreview` relation; implement the seven rows of [wrapper.md](../../02-design/wrapper.md) §12.2. Without a TTY and `--yes`, a confirmation fails with `packageNotInstalled` (hint `--install`) or `cli.confirmationRequired`. Refused relations (downgrade, other signer) exit 5 with the store's message. **Check:** T0 golden tests pass for every row.
3. **Initial values.** With `--install`, pass `--updates`, `--provider`, `--window-size`, and `--resizable` to the install, and write them to `wrapper.json` (`updates`, `window`). Precedence: flags, then `wrapper.json`, then `integrations.defaults.*` ([configuration.md](../../03-reference/configuration.md) §3.3). For an installed package, `--updates` and `--provider` exit 64 with the hint `apkrun update policy`. **Check:** a T2 test shows that `--updates auto --update-provider direct --update-url <url>` gives authority `apkrun`, mode `automatic`, and a Direct provider.
4. **Placement.** `--output` defaults to `~/Applications`. On `destinationNotAccessible`, the CLI moves the staged bundle and calls `placeStagedWrapper` (#57). Without `--replace`, a second wrap exits with `wrapperExists`; `--replace` refreshes the wrapper ([wrapper.md](../../02-design/wrapper.md) §6.4). `--open` opens it. **Check:** golden tests pass for `wrapperExists`, `nameConflict`, and `--replace`.
5. **`install --wrap`, `wrapper verify`, `wrapper info`.** `apkrun install <file>… --wrap` exits 2 when only the wrapper fails ([cli.md](../../02-design/cli.md) §3.3). `wrapper verify <path> [--deep] [--json]` calls `verifyWrapper`; `--deep --json` adds the hash list of #50. `wrapper info <package> [--json]` prints `wrapperInfo`. Map every `wrapper` error code to its exit code. **Check:** golden tests pass.

**Tests.**
- T0 (`CLI/apkrun/Tests/`, fake `RuntimeService`): golden output (human and JSON) for every row, alias, and error path, with exit codes ([cli.md](../../02-design/cli.md) §6.3).
- T2 (`Tests/IntegrationTests/`, per-suite `--output` folders, [test-strategy.md](../test-strategy.md) §3.9): `apkrun wrap HelloText.apk` with a scripted answer, `--install --output ~/Applications`, the update flags, a second wrap, `--replace`, and `install --wrap`.
- T3: none.

**Done when.**
- `apkrun wrap app.apk` prints the preview, asks, then installs and creates the Mac app in `~/Applications`.
- `apkrun wrap app.apk --install --updates auto --output ~/Applications` installs and wraps without asking.
- `--updates auto --update-provider direct --update-url <url>` gives authority `apkrun`, mode `automatic`, and a Direct provider.
- A second wrap fails with `wrapperExists`; `--replace` refreshes it.
- Each row of [wrapper.md](../../02-design/wrapper.md) §12.2 behaves as written. Another item at the destination is never replaced (`nameConflict`).
- `apkrun install <file> --wrap` exits 2 when only the install succeeded. Without a TTY and `--yes`, no command waits.

**Pitfalls.**
- The CLI runs with the user's file access; apkrund does not. The CLI sends absolute `--output` paths ([cli.md](../../02-design/cli.md) §4.4).

---

## #77 Wrapper lifecycle and uninstall choices

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #49 |
| Design | [wrapper.md](../../02-design/wrapper.md) §7.2, §9.1, §9.3, §9.5; [package-store.md](../../02-design/package-store.md) §8; [host-ui.md](../../02-design/host-ui.md) §8 |
| Code | `Packages/WrapperCore/Sources/WrapperCore/Lifecycle/`, `Packages/APKStoreCore/` (`UninstallOptions`), `Guest/APKRunStore/` (`UninstallService`), `Packages/RuntimeHost/`, `Apps/APKRun/Features/Uninstall/`, `Apps/APKRun/Features/AppPage/MacAppSection.swift`, `Apps/APKRun/Features/Settings/` (Storage, Troubleshooting), `CLI/apkrun/Commands/` |

**Goal.** APKRun tracks every Mac app it created, notices when one is moved, renamed, deleted, or modified, and shows what the user can do. Names, icons, and launchers can change without breaking the Dock pin. Uninstalling offers to keep data and to move the Mac app to the Trash.

**Out of scope.** The app page and app rows (#80, #78); this task provides the views and actions. Screen U and the post-update prompt (#58). `apkrun doctor` output (#60). **Make Local Mac App** (#90).

**Steps.**
1. **Verify R-20 first.** On macOS 27, pin a generated `HelloText.app` in the Dock. Build a new `Contents` in `<parent>/.apkrun-<uuid>/`, sign it, and swap it in with `renamex_np(…, RENAME_SWAP)` from apkrund. Check whether App Management blocks it and whether the pin survives a rename. If apkrund is blocked, run the steps in APKRun.app and return `refreshBlocked`. If the pin breaks, replace the whole bundle ([wrapper.md](../../02-design/wrapper.md) §9.3). **Check:** R-20 is closed or realized in [risks.md](../risks.md), with the method chosen.
2. **Validator.** `WrapperValidator` returns `WrapperStatus` (`valid`, `moved(URL)`, `missing`, `inaccessible`, `signatureInvalid`, `unknownPackage`) by running checks 1–6 of [wrapper.md](../../02-design/wrapper.md) §9.1 in order. The sweep runs at apkrund start + 60 s; `listWrappers` caches 60 s; changes post `statusChanged`. Add `wrappers.status` and `wrappers.launcher`. **Check:** T1 validator tests pass for fixture bundles of every state.
3. **Refresh.** `refreshWrapper(packageID, WrapperRefresh{displayName?, icon?, launcher})` runs steps 1–8 of [wrapper.md](../../02-design/wrapper.md) §9.3. A running wrapper gives `wrapperRunning`; on OK the call repeats with `closeRunningApp = true`, and apkrund waits up to 30 s for the session to close ([runtime-api.md](../../03-reference/runtime-api.md) §10.5). `recover()` completes or rolls back a `refreshing` entry. **Check:** T1 recovery passes for a crash before and after step 5.
4. **Bulk actions.** `refreshAllWrappers(RefreshAllWrappersRequest{scope, launcherOnly})` backs **Update All Mac Apps** and `apkrun wrapper refresh --all`. It skips running wrappers, returns `WrapperBatchResult{refreshed, skippedRunning, failed}`, and one failure does not stop the rest. `rescanWrappers(RescanWrappersRequest{register})` lists, or with `register = true` registers, the valid `APKRunPackageID` bundles in `~/Applications` and `/Applications` ([wrapper.md](../../02-design/wrapper.md) §7.2). **Refresh Dock Icons** restarts the Dock after confirmation only ([wrapper.md](../../02-design/wrapper.md) §8.5). **Check:** T1 tests of the re-register scan and of `refreshAllWrappers` with a running wrapper pass.
5. **Removal and wrapper CLI.** `removeWrapper(packageID, {trash})` removes the registry entry and, with `trash`, moves the bundle with `FileManager.trashItem` ([wrapper.md](../../02-design/wrapper.md) §9.5). Wrappers are never deleted. Add `apkrun wrapper list|refresh|remove`. **Check:** T0 golden tests pass.
6. **Store side and uninstall CLI.** `UninstallOptions{keepData, trashWrappers, forget}` goes into the uninstall transaction ([package-store.md](../../02-design/package-store.md) §8). With `keepData`, `UninstallService` passes `DELETE_KEEP_DATA`, which keeps `metadata.json` (state `uninstalledKeepingData`) and `settings.json`. Add `apkrun uninstall <package> [--keep-data] [--keep-wrapper] [--forget] [--yes]` and `apkrun repair <package> [--yes]`. **Check:** T1 store tests pass for keep, not keep, and `forget`.
7. **UI.** `UninstallDialog` follows [host-ui.md](../../02-design/host-ui.md) §8. `MacAppSection` follows [host-ui.md](../../02-design/host-ui.md) §7.6 and [wrapper.md](../../02-design/wrapper.md) §9.1. The Repair sheet is [host-ui.md](../../02-design/host-ui.md) §7.7. **Apps with kept data** (**Reinstall…**, **Delete Data**) goes in `StoragePane.swift`. **Check:** the T1 XCUITest for the uninstall choices passes.

**Tests.**
- T0: `apkrun wrapper`, `uninstall`, and `repair` golden output and exit codes; DTO round trips.
- T1 (`Packages/WrapperCore/Tests/`): validator states with fixture bundles (moved, in the Trash, unreadable, edited `wrapper.json`, re-signed, unknown package, older launcher); `refreshing` recovery; re-register scan; `refreshAllWrappers` with a running and a failing wrapper. (`Packages/APKStoreCore/Tests/`, fake channel): uninstall with and without keep data, and `forget`. (`Apps/APKRun/UITests/`, XCUITest): the uninstall choices ([host-ui.md](../../02-design/host-ui.md) §15).
- T2 (`Tests/IntegrationTests/`, custom image): keep-data reinstall restores data; full uninstall removes `Packages/<id>/` and trashes the wrapper; move, rename, Trash, and restore give the expected states; a refresh with a new name and icon keeps the bundle ID and records the new cdhash.
- T3: C04-5 (the Dock pin survives a refresh) and C04-8 (the uninstall sheet matches [host-ui.md](../../02-design/host-ui.md) §8).

**Done when.**
- Moving or renaming a wrapper gives `moved`, then `valid` (FR-WRP-12). Trashing it gives `missing`; restoring it gives `valid`.
- Editing `wrapper.json` gives `signatureInvalid` in `apkrun wrapper verify --deep`.
- A name and icon change regenerates the wrapper with the same bundle ID; the Dock pin still works; the registry has the new cdhash (FR-WRP-13). The bundle ID stays, so notification settings stay (R-19; #55 holds the rest).
- Uninstall with "Also move the Mac app to the Trash" leaves the wrapper in the Trash; without it, the wrapper shows `unknownPackage`.
- Keep-data uninstall, then reinstalling the same APK, restores the data (FR-PKG-07). Uninstall without keeping data removes `Packages/<id>/`.
- A running wrapper is not refreshed until the user agrees to quit it (`wrapperRunning`). **Update All Mac Apps** skips and lists running wrappers.
- After the registry is deleted, **Re-register Mac Apps** registers the generated wrappers after one confirmation.

**Pitfalls.**
- Resolve bookmarks without UI and without mounting volumes. A validation pass never spins up a disk or shows a dialog.
- `renamex_np` with `RENAME_SWAP` works only on one volume. Build the new `Contents` inside the bundle's parent directory.

---

## #78 Home and store UI

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #49 |
| Design | [host-ui.md](../../02-design/host-ui.md) §2.2, §3.1, §5.2, §5.3; [wrapper.md](../../02-design/wrapper.md) §9.1 |
| Code | `Apps/APKRun/Models/` (`PackageListModel`, `PackageDetailModel`, `UpdatesModel`, `SessionsModel`, `OperationCenter`, `WrapperListModel`), `Apps/APKRun/Features/Home/`, `Apps/APKRun/Components/`, `Apps/APKRun/APKRunApp.swift`, `Packages/WrapperCore/` (quick `listWrappers`) |

**Goal.** APKRun.app's main window lists the user's Android apps with Android version, update mode, and status, plus a runtime header, an Updates list with **Update Now**, other Android apps, and a drop zone. It works while Android is stopped, and `apkrun://` links open the right place.

**Out of scope.** The add sheet (#79); until then drops show the `ImportPreview` summary only. The app page (#80). Wrapper states beyond checks 1–3 and 5, and their actions (#77). Runtime header rows of #58, #59, #88, and the "Needs attention" line (#60). A catalog of apps outside the Mac (OQ-08).

**Steps.**
1. **Wrapper list.** `listWrappers() -> [WrapperSummary]` on `.control` runs checks 1–3 and 5 of [wrapper.md](../../02-design/wrapper.md) §9.1 with a 60 s cache. `WrapperListModel` reloads when the window becomes key and every 60 s while visible. **Check:** a T2 test trashes a wrapper, and `listWrappers` reports `missing` within 60 s.
2. **Models.** The models in Code are `@Observable` main-actor models fed by `RuntimeClient` requests and the topics `packages`, `updates`, `sessions`, and `wrappers`. All reload on reconnect. While apkrund is unreachable, show the **Restart Service** and **Troubleshooting…** banner. Views never call XPC. **Check:** T0 reconnection tests pass.
3. **Main window.** A `NavigationSplitView` with the sidebar (**Apps**, **Updates** with badge, **Other Android Apps**), the runtime header ([host-ui.md](../../02-design/host-ui.md) §5.2), and rows (icon, name, "Android version ‹versionName›", update mode, status line). The status line is the first matching row of [host-ui.md](../../02-design/host-ui.md) §5.3. **Open** calls `launch(packageID)`. Row buttons connect to the #77 actions. Add the empty state, search, sort, and ⌘O. **Check:** T0 status-priority tests pass for every row and tie.
4. **URL routing.** In `APKRunApp.swift`, handle the routes of [host-ui.md](../../02-design/host-ui.md) §3.1, including `report[?package=<id>]`. URLs only navigate. Reject invalid package IDs. Unknown routes, including `report` until #61, open home. **Check:** T0 routing tests pass.

**Tests.**
- T0 (`Apps/APKRun/Tests/`, fake `RuntimeService`): status priority table, reconnection reload, routing and package ID validation ([host-ui.md](../../02-design/host-ui.md) §15).
- T2 (`Tests/IntegrationTests/`, custom image): HelloText and HelloGL installed, and HelloCompose installed unmanaged with `adb install`. Rows show the right versions and states; HelloCompose is under **Other Android Apps**. A staged HelloUpdate update shows "Update available", and **Update Now** installs it. A trashed wrapper shows "Mac app not found" within 60 s. With Android stopped, the list loads and **Open** starts Android.
- T3: none.

**Done when.**
- Home shows the drop area, the installed apps with update mode and status, and the runtime status (FR-UI-01).
- Each row shows "Android version ‹versionName›" and update status; **Update Now** installs a staged HelloUpdate update (FR-UI-04).
- HelloCompose, installed unmanaged, appears under **Other Android Apps** with **Manage with APKRun**.
- A wrapper moved to the Trash shows "Mac app not found" within 60 s.
- With Android stopped, the list loads, and **Open** starts Android and the app.
- When apkrund is unreachable, the **Restart Service** banner appears, and models reload after reconnect.
- `apkrun://` URLs only navigate, and invalid package IDs are rejected.

**Pitfalls.**
- Settle OQ-08 first; its default is no app catalog. The home screen never starts Android by itself: only **Open**, **Start Android**, and user-started updates may boot it.
- #77 and #78 both touch the rows in `Features/Home/`. Whichever merges second connects the row actions.

---

## #79 Add flow

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #78, #74 |
| Design | [host-ui.md](../../02-design/host-ui.md) §3.2, §6.1, §6.2; [update-system.md](../../02-design/update-system.md) §4.7; [wrapper.md](../../02-design/wrapper.md) §4.3, §6.6 |
| Code | `Apps/APKRun/Features/AddFlow/`, `Apps/APKRun/APKRunApp.swift`, APKRun.app `Info.plist`, `Packages/RuntimeAPI/` (`InstallOptions.createWrapper`), `Packages/RuntimeHost/` |

**Goal.** Adding an Android app takes one drag or one double-click. APKRun shows the app's name, icon, version, signer, and update choices, and installs it with a Mac app in `~/Applications` when the user clicks **Install**. Each relation to an installed app gets its own sheet, and refused files say why.

**Out of scope.** The `wrappers.defaultLocation` control (#80). The F-Droid suggestion, which needs the cached index (#52). The compatibility label (#91). `.aab` and `.xapk` with OBB, which the store refuses ([package-store.md](../../02-design/package-store.md) §4.2).

**Steps.**
1. **Document types and entry points.** Declare the types of [host-ui.md](../../02-design/host-ui.md) §3.2 in APKRun.app's Info.plist. Route document opens, drops, **Add App…** (⌘O), double-click, **Open With**, and `open -a APKRun file.apk` into `AddFlowModel`, which calls `beginImport` with file handles, never paths. A split set is one import. Other files are refused with "APKRun can add .apk, .apks, .xapk, and .apkm files." **Check:** double-clicking `HelloText.apk` in Finder opens the sheet.
2. **Review and relations.** Show [host-ui.md](../../02-design/host-ui.md) §6.1 from `ImportPreview`. Implement `newPackage`, `sameAsInstalled`, `reinstallSameVersion`, `update(from:)`, `downgrade(from:)`, `otherSigner`, and `uninstalledWithData(version)`. A blocking problem replaces **Install** with its reason. Refused relations show the store's message and **Done** only. **Check:** T0 relation tests pass.
3. **Installing and Done.** **Install** calls `installImported(ticket, options)` with `InstallOptions.createWrapper` when the toggle is on, so the wrapper is generated after the store commit in the same operation. An install failure shows the catalog message and **Try Again** (the ticket is kept). A wrapper failure keeps the app installed and offers **Try Again**; for `destinationNotAccessible`, also **Choose Another Location…** (Save panel), then `placeStagedWrapper`. Closing the sheet does not stop the work. **Check:** a T2 test with the toggle on produces `~/Applications/HelloText.app`.
4. **Update choices and Mac app options.** Without an update source, only **Manual** is enabled, with **Choose…** for the provider picker ([update-system.md](../../02-design/update-system.md) §4). A detected provider is a suggestion that stays off until the user turns it on ([update-system.md](../../02-design/update-system.md) §4.7). The Create Mac app toggle is on. The name starts with the host label and follows [wrapper.md](../../02-design/wrapper.md) §4.3. The location pop-up offers **Applications (for me)**, **Applications (all users)** for admins, and **Other…**; it starts at `wrappers.defaultLocation`, and `ask` selects nothing. If OQ-22 says the Apps view does not list other folders, **Other…** says so. **Check:** T0 model tests pass.

**Tests.**
- T0 (`Apps/APKRun/Tests/`, fake `RuntimeService`): relation handling; update modes with and without a source; name and location defaults ([host-ui.md](../../02-design/host-ui.md) §15).
- T1 (`Apps/APKRun/UITests/`, XCUITest): each relation, the refusals, and the wrapper failure with **Choose Another Location…**.
- T2 (`Tests/IntegrationTests/`, custom image): drag `HelloText.apk` onto APKRun and install with "Create Mac app"; double-click an `.apk` in Finder; install the `.xapk` and `.apks` fixtures as split sets; HelloUpdate V1 over V2 gives `downgrade(from:)`; HelloUpdate V2 from another signer over V1 gives `otherSigner`; OddName gets a sanitized name ([test-strategy.md](../test-strategy.md) §4.2–§4.3).
- T3: none.

**Done when.**
- (FR-UI-02) Dragging `HelloText.apk` onto APKRun shows its name, package, icon, and update options; **Install** with "Create Mac app" produces `~/Applications/HelloText.app`, which opens the app.
- (FR-UI-06) Double-clicking an `.apk` in Finder opens the same sheet.
- `.xapk` and `.apks` fixtures install as split sets.
- HelloUpdate V1 over V2, and V2 from another signer over V1, are refused, each with only **Done**.
- OddName gets a sanitized Mac app name ([wrapper.md](../../02-design/wrapper.md) §4.3).
- Every relation of [host-ui.md](../../02-design/host-ui.md) §6.1 shows its sheet and button.
- Without an update source, only **Manual** is enabled, and no suggestion is on by default.

**Pitfalls.**
- The GUI passes file handles, never paths ([package-store.md](../../02-design/package-store.md) §4.1). Open a drop's security-scoped URL in the app process before sending the handle.

---

## #80 Per-app settings

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #78, #40, #75 |
| Design | [host-ui.md](../../02-design/host-ui.md) §7, §9; [configuration.md](../../03-reference/configuration.md) §3; [display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7; [update-system.md](../../02-design/update-system.md) §2.1 |
| Code | `Apps/APKRun/Features/AppPage/`, `Apps/APKRun/Features/Settings/`, `Packages/WindowingCore/`, `Packages/APKStoreCore/` (`updatePackageSettings`), `CLI/apkrun/Commands/Settings.swift`, `CLI/apkrun/Tests/Golden/` |

**Goal.** Every app has a page in APKRun.app for its name and icon, window behavior, input, integrations, updates, Mac app, and storage. Changes save at once in the package store, never in the wrapper. `apkrun settings` offers the same keys. The Settings window gets its app-wide panes.

**Out of scope.** Integration features (#55, #82, #83, #85), whose controls write keys here. Other panes and rows (#58, #59, #60, #61, #83, #84, #86, #88). "Recommended for this app" values (#91). Refresh mechanics (#77).

**Steps.**
1. **App page and writes.** `AppPageView` (icon, name, version, running state, **Open**, **Update Now**, the **…** menu) is reached from the row's **Settings** button and `apkrun://package/<id>/<section>`. Every control writes at once with `updatePackageSettings(id, patch)`. Next-session keys show "Applies the next time ‹App› opens." while the app runs. A recommended value shows "Recommended for this app"; **Reset** sends `null` ([configuration.md](../../03-reference/configuration.md) §3.2). **Check:** T0 patch tests pass for every control.
2. **Sections.** `GeneralSection`, `WindowSection`, `InputSection`, `IntegrationsSection`, `UpdatesSection`, `StorageSection`, and `MacAppSection` (#77) follow [host-ui.md](../../02-design/host-ui.md) §7.1–§7.7. `UpdatesSection` changes the mode through `setUpdatePolicy` and **Updated by** through `setUpdateAuthority` ([update-system.md](../../02-design/update-system.md) §2.1). **Check:** each control writes its key and value ([configuration.md](../../03-reference/configuration.md) §3.1), and the Updates section shows the HelloUpdate history.
3. **Always on top.** In `Packages/WindowingCore/`, apply `window.alwaysOnTop` as `NSWindow.level = .floating`, live on `windowPrefsChanged` ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7). No effect in full screen (OQ-09). The status bar stays visible on display 0 in compatibility mode (OQ-35); both use their working defaults unless tests show a problem. **Check:** a T2 test turns it on while HelloText is open, and the level changes without a restart.
4. **`apkrun settings`.** `list [--json]`, `get <key>`, `set <key> <value>`, `reset (<key> | --all)` in `CLI/apkrun/Commands/Settings.swift`. `set` parses by key type; an invalid value exits 64 with the allowed values; an unknown key exits 4. **Check:** every key of [package-metadata-json.md](../../03-reference/package-metadata-json.md) §3 round-trips through `set` and `get`.
5. **Settings window.** In `SettingsScene.swift`, set the tab order of [host-ui.md](../../02-design/host-ui.md) §9; show a pane only when it has content. Fill the M7 panes (General, Updates, Runtime, Privacy, Storage summary, Advanced) with the keys of [configuration.md](../../03-reference/configuration.md) §2. `integrations.defaults.*` apply only to later-recorded apps ([configuration.md](../../03-reference/configuration.md) §2.8). **Developer mode** asks for confirmation first. **Install Command-Line Tool…** shows the command and never runs `sudo`. **Check:** T0 settings tests pass for every pane control.

**Tests.**
- T0 (`Apps/APKRun/Tests/`, fake `RuntimeService`): each control writes its key and value; **Developer mode** only after confirmation; **Updated by** ([host-ui.md](../../02-design/host-ui.md) §15). `apkrun settings` golden output and exit codes.
- T2 (`Tests/IntegrationTests/`, custom image, HelloText): one test per section of [host-ui.md](../../02-design/host-ui.md) §7.2–§7.4. The key changes in `settings.json`, and the effect appears where stated. Updates shows the history and rolls back HelloUpdate. **Updated by** makes HelloUpdate `external`, then `apkrun` again. The add flow's pop-up starts at **Applications (all users)** when Settings → General says so.
- T3: none.

**Done when.**
- Each setting of [host-ui.md](../../02-design/host-ui.md) §7.2–§7.4 changes `settings.json` and takes effect where stated (FR-UI-03).
- The Updates section changes mode and source, shows history, and rolls back HelloUpdate (FR-UPD-09).
- **Another app store in Android** makes HelloUpdate `external` after confirmation; **APKRun** makes it `apkrun` again with its kept source. `googlePlay` is read-only.
- The Settings window has the General, Updates, Runtime, and Advanced panes, the Privacy switches and defaults, and the Storage summary. The default location sets where the next Mac app goes.
- Changing name or icon offers **Update Mac App**; the wrapper changes only when the user clicks it, and no setting is written to the wrapper bundle (ADR-0009).
- "Always on top" floats the window at once, with no effect in full screen (OQ-09).
- **Compatibility** window mode applies at the next session (FR-DSP-06, OQ-35).
- `apkrun settings` round-trips every key; invalid values exit 64.

**Pitfalls.**
- Input keys apply at the next session, and `WindowPrefs` carries only `resizable`, `alwaysOnTop`, and `zoom` ([configuration.md](../../03-reference/configuration.md) §3.1, [runtime-api.md](../../03-reference/runtime-api.md) §10.2).
- `apkrun settings set update.mode` changes only the mode. The UI uses `setUpdatePolicy`, which writes authority, provider, and mode together.

---

## #90 Portable wrappers

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #76 |
| Design | [wrapper.md](../../02-design/wrapper.md) §5.4, §7.3, §10.1, §10.2; [host-ui.md](../../02-design/host-ui.md) §10.1; [package-store.md](../../02-design/package-store.md) §4.1 |
| Code | `Packages/WrapperCore/` (`BootstrapSet`, `BootstrapDocument`), `Packages/RuntimeAPI/` (bootstrap DTOs), `Daemon/apkrund/` (`importBootstrap`), `Packages/APKStoreCore/` (source `wrapperBootstrap`), `Apps/APKRunLauncher/` (screen N), `Apps/APKRun/Features/Approvals/`, `Apps/APKRun/Features/AppPage/MacAppSection.swift`, `CLI/apkrun/Commands/Wrap.swift` |

**Goal.** A portable Mac app also carries the app's APK set. Copied to another Mac, or another user account, that has APKRun but not the app, it asks for approval, installs the app from its own bundle, and opens it. The bundle never changes, and an installed app is never updated or downgraded from it.

**Out of scope.** Distribution wrappers and notarization (#89). A GUI entry point to create portable wrappers: none exists in M7, so the CLI is the only one ([wrapper.md](../../02-design/wrapper.md) §6.6).

**Steps.**
1. **Bootstrap contents.** Add `BootstrapSet` (the installed `current/` files, or an import ticket's files) to `WrapperConfiguration`. Clone the files into `Contents/Resources/bootstrap/` and write `bootstrap.json` with sorted keys ([wrapper.md](../../02-design/wrapper.md) §10.1). Set `APKRunWrapperKind` and `wrapper.json` `kind` to `portable`. `apkrun wrap <package> --portable` prints the size with the portable note of [legal-and-licensing.md](../../05-development/legal-and-licensing.md) §9. `apkrun wrap app.apk --portable` without `--install` uses the ticket's files and warns about the icon. **Check:** T0 `bootstrap.json` encoding passes; an unknown `formatVersion` is rejected.
2. **Approval.** `ApprovalPrompt` carries the bundled version. The approval window shows "Android app not installed. This Mac app contains version ‹version›." (or the installed version) and "Includes ‹App› ‹version›" ([wrapper.md](../../02-design/wrapper.md) §10.2). Allow registers the wrapper with `approval: user`. **Check:** the T1 approval test with a portable fixture passes.
3. **`importBootstrap`.** Allowed only when the wrapper is approved, `bootstrap.json` `packageId` equals the registry `packageId`, and the package is not installed or is `uninstalledKeepingData`. Otherwise `bootstrapNotAllowed`; a `packageId` mismatch or bad JSON is `bootstrapInvalid` ([wrapper.md](../../02-design/wrapper.md) §13). The store checks each SHA-256 and runs the intrinsic checks and preview with source `wrapperBootstrap` ([package-store.md](../../02-design/package-store.md) §4.1). `wrapper.json` `updates` gives the initial authority, mode, and provider; `window` and `integration` are first-record settings ([configuration.md](../../03-reference/configuration.md) §3.3). A newer version already in Android fails with the store's downgrade error. **Check:** T1 rule tests pass for not approved, package mismatch, installed, and hash mismatch.
4. **Launcher and APKRun.app.** When `openSession` returns `packageNotInstalled` for a portable wrapper, screen N shows **Install from This App**, skipping the question right after the first-run approval. The launcher then repeats `openSession`. The `unknownPackage` action **Install from Mac App** runs the same flow. **Make Local Mac App** in `MacAppSection` refreshes the wrapper as `kind: local` without `bootstrap/` (#77). **Check:** after an uninstall, opening the portable wrapper asks again.

**Tests.**
- T0: `bootstrap.json` encoding and schema; an unknown `formatVersion` is rejected.
- T1 (`Packages/WrapperCore/Tests/`, fake UI client): portable approval; `importBootstrap` rules.
- T2 (`Tests/IntegrationTests/`): first run in a second user account: approval, install from the bundle, launch. A second open does not import. Bundle hashes (#50 step 1) are unchanged throughout.
- T3: the #90 part of C04-7 (the approval prompt for a copied wrapper is clear, and Return does not allow).

**Done when.**
- A portable `HelloText.app` made in one account, copied to a second account or Mac with APKRun but not the package, asks for approval, installs HelloText from the bundle, and launches it.
- A second open does not import again; the bootstrap is used only when the package is not installed.
- The bundle hashes are unchanged throughout. An installed package is never updated or downgraded from a bootstrap (`bootstrapNotAllowed`); a changed bootstrap file is refused (`bootstrapInvalid`).
- The approval prompt shows the bundled version, and Return does not allow.
- `apkrun wrap app.apk --portable` without `--install` creates a portable wrapper and warns about the icon.
- **Make Local Mac App** removes `bootstrap/`, and the wrapper keeps its bundle ID.

**Pitfalls.**
- OQ-40 (APKRun's license) is a decision due with this task. Settle it first: the portable note names the license.
- A portable wrapper copied through a quarantining app is translocated when opened from a download location. Screen T comes before the approval ([wrapper.md](../../02-design/wrapper.md) §7.4).
- After the first install, `bootstrap/` is dead weight. The 8 MiB limit (NFR-RES-03) does not include it.
