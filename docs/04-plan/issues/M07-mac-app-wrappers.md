# M7 Mac app wrappers

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.4 |
| Related | [wrapper.md](../../02-design/wrapper.md), [host-ui.md](../../02-design/host-ui.md), [package-store.md](../../02-design/package-store.md), [update-system.md](../../02-design/update-system.md), [cli.md](../../02-design/cli.md), [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../open-questions.md](../open-questions.md), [../test-strategy.md](../test-strategy.md), [../traceability.md](../traceability.md) |

Each task below uses the entry format of [README.md](README.md) §2. Titles, dependencies, the milestone, and the gates follow the index in [README.md](README.md) §3.

## Milestone goal

An Android app becomes an ordinary Mac app. `apkrun wrap` or the add flow creates a thin, locally signed `.app` for an installed package. It opens from Finder, the Dock, and Spotlight, shows the app in its own native window, and never needs a terminal (M7, gate G8). The same wrapper keeps working, byte for byte unchanged, while APKRun updates the Android app behind it (gate G9). APKRun.app gets the home and store UI, the add flow, per-app settings, and the wrapper lifecycle ([../roadmap.md](../roadmap.md) §3.4).

v0.4 is the first public demo: the end-to-end flow runs on a clean Mac without terminal use. Do not declare the product concept validated until G9 passes.

These design decisions hold for every task below:

- The launcher stays running and owns the window. apkrund renders into shared IOSurfaces (ADR-0006, [0006-wrapper-owned-window-iosurface.md](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md)).
- The launcher is arm64 only, matching the Apple silicon host requirement.
- The wrapper endpoint serves RuntimeAPI majors N and N−1 ([wrapper.md](../../02-design/wrapper.md) §5.3).
- Settings live in the package store. `wrapper.json` holds initial values only (ADR-0009, [0009-thin-immutable-wrappers.md](../../01-architecture/decisions/0009-thin-immutable-wrappers.md)).
- Bundle IDs map `_` to `-`, and IDs with uppercase letters get a `-h<8 hex>` suffix ([wrapper.md](../../02-design/wrapper.md) §4.1). `wrapper.json` carries the runtime, provider, and integration settings described in [wrapper.md](../../02-design/wrapper.md) §3. The CLI uses `--updates` and `--provider`, plus the documented alternate flag spellings.
- Use `HelloText.app` for G8 and `HelloUpdate.app` for G9; the fixture's label determines the app name ([../test-strategy.md](../test-strategy.md) §4.9).
- The user-facing term is "Mac app", never "wrapper" ([host-ui.md](../../02-design/host-ui.md) §13.1).

## Exit criteria

- [ ] All 14 tasks meet their acceptance criteria, or a task is moved to a later milestone with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4 item 1).
- [ ] **G8 passes** ([../roadmap.md](../roadmap.md) §2): `apkrun wrap` with HelloText produces `HelloText.app` with the bundle ID `io.apkrun.android.io.apkrun.fixture.hellotext`, ad-hoc signed, which passes `codesign --verify --strict`. Double-clicking it in Finder shows an interactive HelloText window. No terminal interaction is needed, and launching from the Dock works with the runtime stopped and with it warm. `scripts/run-gate.sh G8` (`Tests/AcceptanceTests/G8Wrapper`) passes on the reference Mac with a clean build from `main` ([../test-strategy.md](../test-strategy.md) §5).
- [ ] **G9 passes** ([../roadmap.md](../roadmap.md) §2): `HelloUpdate.app` runs V1. V2 is detected in the background and installed after `HelloUpdate.app` quits, and `HelloUpdate.app` then runs V2. App data is kept. The bundle is byte-for-byte unchanged (same file hashes and the same cdhash), and it was not re-signed. `scripts/run-gate.sh G9` (`G9WrapperIntegrity`) passes.
- [ ] The v0.4 Definition of Done holds ([../roadmap.md](../roadmap.md) §3.4): APK → Mac app (#044–#047), `.app` generated (#046, #075), Dock launch and Spotlight launch (#056), icon extraction (#055), wrapper unchanged during APK updates (#048, #049), automatic APK update (#049), and update settings per wrapper (#079). Also #076, #077, #078, and #089.
- [ ] Every `Must` requirement for 0.4 in FR-WRP, FR-UI-01 to FR-UI-04, FR-PKG-07, FR-UPD-09, and FR-CLI-01 (the `wrap` part) is covered by passing tests ([../traceability.md](../traceability.md) §2).
- [ ] The first public demo runs: on a clean Mac with the #035 image bundle picked in onboarding, install APKRun, add HelloUpdate V1 from a file, generate `HelloUpdate.app`, launch it from the Dock and from Spotlight, publish HelloUpdate V2 on a Direct or Local provider, quit `HelloUpdate.app`, and show that the next launch runs V2 from the same, unchanged wrapper. Nothing needs a terminal ([../roadmap.md](../roadmap.md) §3.4, [../test-strategy.md](../test-strategy.md) §8.5 C04-9).
- [ ] Tests ([../roadmap.md](../roadmap.md) §4 item 3): T0 and T1 pass on `main`. T2 passes on the reference Mac. The G8 and G9 checks are in the nightly T3 run. The v0.4 manual checklist ([../test-strategy.md](../test-strategy.md) §8.5, C04-1 to C04-9) is done and recorded in the release issue.
- [ ] Performance ([../roadmap.md](../roadmap.md) §4 item 4): the perf harness numbers are recorded for M7, measured through a generated wrapper. NFR-PERF-01 (warm p50 ≤ 1.5 s, p95 ≤ 3 s) and NFR-PERF-02 (cold p50 ≤ 40 s) are reported, and any regression against M6 is explained ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §9.4). Wrapper generation stays within 2 s p50 without a bootstrap ([wrapper.md](../../02-design/wrapper.md) §6.2).
- [ ] Risks ([../roadmap.md](../roadmap.md) §4 item 5, [../risks.md](../risks.md)):
  - R-17 has its result recorded (the product behavior of local wrappers under Gatekeeper and App Management on macOS 27), and its status is updated. The #088 part stays for M12.
  - R-19 has the #076 part recorded (the bundle ID is kept across a refresh). It stays `open` and names #054 for the rest.
  - R-20 is `closed`, or `realized` with the fallback recorded in [wrapper.md](../../02-design/wrapper.md) §9.3.
- [ ] Questions ([../roadmap.md](../roadmap.md) §4 item 6, [../open-questions.md](../open-questions.md)): OQ-01 (namespace) was settled before #045 started. OQ-08 was settled before #077. OQ-09 and OQ-35 are settled in #079. The OQ-22 verification is recorded in #056. Decisions with a deadline in M8 are settled or carried over.
- [ ] Documents ([../roadmap.md](../roadmap.md) §4 item 7): [wrapper.md](../../02-design/wrapper.md), [host-ui.md](../../02-design/host-ui.md), [package-store.md](../../02-design/package-store.md), [update-system.md](../../02-design/update-system.md), and [cli.md](../../02-design/cli.md) describe what was built. The verification results of #046, #055, #056, and #076 are in the design documents. The [../roadmap.md](../roadmap.md) §3.4 items are marked delivered.
- [ ] Version ([../roadmap.md](../roadmap.md) §4 item 8): the v0.4 Definition of Done is checked and v0.4 is tagged.

## Task order

1. #044 Launcher as a wrapper (APKRunLauncher).
2. #045 WrapperCore generator.
3. #046 Generate Hello.app. **Parallel with #055.**
4. #047 Launch Hello.app end to end (gate G8). **Parallel with #055 and #056.**
5. #055 Android icon to macOS icon pipeline. It needs #045 and #036 (M5). **Parallel with #046 and #047.**
6. #056 Finder, Dock, and Spotlight integration. After #055.
7. #048 Wrapper independent of the APK file. After #047 and #037 (M6).
8. #049 Automatic update behind an unchanged wrapper (gate G9). After #043 (M6) and #048. **Parallel with #075–#079.**
9. #075 `apkrun wrap` CLI. After #046 and #048. **Parallel with #076 and #077.**
10. #076 Wrapper lifecycle and uninstall choices. After #048. **Parallel with #075 and #077.**
11. #077 Home and store UI. After #048. **Parallel with #075 and #076.**
12. #078 Add flow. After #077 and #073 (M6). **Parallel with #079.**
13. #079 Per-app settings. After #077. **Parallel with #078.**
14. #089 Portable wrappers. After #075.

The critical path is #044 → #045 → #046 → #047 (G8) → #048 → #049 (G9) ([../roadmap.md](../roadmap.md) §1.3).

Shared files:

- Most tasks touch `Packages/WrapperCore/`. #045 creates the generator, the installer, and the registry. Later tasks add files next to them and change only the entry points.
- #076 and #077 both touch the app rows in `Apps/APKRun/Features/Home/`. #077 owns the rows. #076 owns the wrapper-state actions and the uninstall and repair sheets. Whichever task merges second connects the row buttons (**Repair…**, **Uninstall…**, and the wrapper actions) to the other task's code.
- #076 builds the Mac App section view. #079 places it on the app page.
- #047 creates the `Settings` scene in `Apps/APKRun/Features/Settings/` with the Privacy pane. #076 adds Storage and Troubleshooting rows, and #079 adds the app-wide panes and the tab order. #076 and #079 both touch `StoragePane.swift`: whichever merges first creates it ([../../02-design/host-ui.md](../../02-design/host-ui.md) §14).

---

## #044 Launcher as a wrapper (APKRunLauncher)

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #032, #068 |
| Requirements | FR-WRP-06, FR-WRP-09, NFR-CMP-02, NFR-SEC-07 |
| Design | [wrapper.md](../../02-design/wrapper.md) §2.1, §3, §5, §7.2, §7.3, §7.4, §12.1, §13, §15 #044, §16; [wrapper-json.md](../../03-reference/wrapper-json.md); [runtime-api.md](../../03-reference/runtime-api.md); [display-and-windowing.md](../../02-design/display-and-windowing.md) §5, §7; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1; [host-ui.md](../../02-design/host-ui.md) §3.1; [cli.md](../../02-design/cli.md) §4.4; [error-catalog.md](../../03-reference/error-catalog.md) (`wrapper` domain); ADR-0006 [0006-wrapper-owned-window-iosurface.md](../../01-architecture/decisions/0006-wrapper-owned-window-iosurface.md) |
| Modules / paths | `Apps/APKRunLauncher/` (`WrapperIdentity`, launcher screens, `LauncherMenus`, `Localizable.xcstrings`, `LauncherStrings.generated.swift`), `Packages/RuntimeAPI/` (`WrapperDocument`, wrapper endpoint and approval DTOs), `Packages/RuntimeClient/` (`.wrapper(bundleID)`), `Packages/WrapperCore/` (`WrapperApprovalService`, first `WrapperRegistry`), `Packages/RuntimeHost/`, `Daemon/apkrund/` (wrapper endpoint), `CLI/apkrun/Commands/Wrapper` (`approve`), `scripts/dev/make-wrapper.sh`, `Tests/IntegrationTests/` |
| Risks / questions | R-17 (Gatekeeper and App Management for wrappers, first observation), R-19 (no `LSUIElement` here). None open for this task in [../open-questions.md](../open-questions.md) |

### Goal

A wrapper that was put together by hand opens HelloText in its own window. The same `APKRunLauncher` executable reads its identity from the bundle, connects to apkrund through XPC as that wrapper, and requests the launch. When the runtime is missing, not set up, too old, or too new, the launcher shows a screen that says what to do.

### Scope

- `WrapperIdentity`: reads the Info.plist keys of [wrapper.md](../../02-design/wrapper.md) §2.1 and `Resources/wrapper.json` (§3), with schema validation ([wrapper-json.md](../../03-reference/wrapper-json.md)). `WrapperDocument` is the Codable model of `wrapper.json`, with the §3 encoding rules.
- The launcher startup of §5.2, steps 1–7, on top of the #068 session window.
- The `.wrapper(bundleID)` endpoint in RuntimeClient and apkrund. The compatibility rules of §5.3 include support for the previous RuntimeAPI major.
- Wrapper authorization in apkrund: a wrapper connection may open sessions for its registered `packageId` only ([runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1, NFR-SEC-07).
- The approval of unknown wrappers (§7.3): broker `requestApproval`, `WrapperApprovalService` (static checks, signer summary, limits, denied entries), `.control` `decideApproval`, and the `wrappers` events `approvalRequested` and `approvalResolved`.
- A first `WrapperRegistry` (§7.2) with `active` entries, `approval: user`, the `denied` list, and atomic writes. #045 adds `pending`, recovery, `generated` entries, and corrupt-file handling.
- Launcher screens R, S, V, L, A, N, D, T, and E (§5.4), `LauncherStrings` (§5.9), the menus and the Dock menu (§5.6), and the About panel.
- `apkrun wrapper approve <path> [--yes]` ([cli.md](../../02-design/cli.md) §4.4).
- `scripts/dev/make-wrapper.sh` for hand-built wrappers.

Out of scope:

- Generating wrappers (#045, #046). Icons (#055).
- The approval window in APKRun.app (#047). Here the approval is answered by `apkrun wrapper approve` or by a fake UI client.
- Screen U and its reconnect loop (#057, [runtime-maintenance.md](../../02-design/runtime-maintenance.md) §13 step 11).
- Background mode and the notification relay (§5.8, #054).
- **Install from This App** on screen N and `importBootstrap` (#089).
- The report sheet behind Help → Report a Problem… (#060). The menu item opens `apkrun://report?package=<id>`, and APKRun.app routes unknown routes to home until then.
- Japanese strings (#092). The string catalog exists, with English only.

### Deliverables

- `Apps/APKRunLauncher/` with `WrapperIdentity`, the launcher screens, `LauncherMenus`, the About panel, `Localizable.xcstrings`, and the build step that generates `LauncherStrings.generated.swift`.
- `WrapperDocument` and the wrapper endpoint and approval DTOs (`ApprovalRequest`, `ApprovalPrompt`, `ApprovalID`) in `Packages/RuntimeAPI/`, as listed in [runtime-api.md](../../03-reference/runtime-api.md).
- The `.wrapper(bundleID)` connection in `Packages/RuntimeClient/`, and the N and N−1 wrapper endpoint in apkrund.
- `WrapperApprovalService` and the first `WrapperRegistry` in `Packages/WrapperCore/`, wired into apkrund by RuntimeHost.
- `apkrun wrapper approve` in `CLI/apkrun/Commands/Wrapper.swift`, with its golden output.
- `scripts/dev/make-wrapper.sh <package> <out-dir> [--minimum-version <v>] [--package-id <id>]`.
- T0, T1, and T2 tests (see Tests).

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #044, steps 1–6. Design step 3 (the first registry and the approval service) is split into steps 3 and 4 here, because the wrapper endpoint cannot authorize a wrapper without it.

1. **`WrapperIdentity` and `WrapperDocument` (design step 1).** Add `WrapperDocument` (all fields of [wrapper.md](../../02-design/wrapper.md) §3 and [wrapper-json.md](../../03-reference/wrapper-json.md), sorted keys, pretty printed, no escaped slashes, trailing newline) to `Packages/RuntimeAPI/`. Add `WrapperIdentity.load(Bundle.main)` to the launcher: it reads `APKRunPackageID`, `APKRunWrapperFormat`, `APKRunWrapperKind`, `APKRunLauncherVersion`, and `APKRunLauncherAPI`, decodes `wrapper.json`, and checks that `application.packageId` equals `APKRunPackageID`. An unknown `formatVersion`, an unreadable file, or a mismatch is `wrapperDamaged`. The generic launcher keeps its `--package <id>` identity from #068. Check: the T0 encoding and schema tests pass, and an unknown `formatVersion` is rejected.
2. **Wrapper endpoint and compatibility (design step 2).** Add `.wrapper(bundleID)` to `RuntimeClient.connect`. In apkrund, build the endpoint requirement `identifier "<bundleId>" and cdhash H"<cdhash>"` from the registry entry ([../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §2.2). Serve the current RuntimeAPI major and the previous one on this endpoint only. Implement the §5.3 table in the launcher with `HelloReply`. apkrund marks a wrapper one major behind as needing a launcher refresh (the reason itself is shown in #076). Authorization allows `openSession`, `packageInfo`, and `packageIcon` only for the registered `packageId` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1). Check: the T0 compatibility matrix passes, and a T1 test shows that a wrapper connection asking for another package is refused.
3. **Registry and approval (design step 3).** Add `WrapperRegistry` to `Packages/WrapperCore/` with the `Wrappers/registry.json` format of §7.2, `active` entries, `approval: user`, and the `denied` list. Writes are atomic (write, `fsync`, rename), and only apkrund writes. Add `WrapperApprovalService` with the five steps of §7.3: static checks (strict signature, identifier equals the bundle ID, the bundle ID equals the mapping of `APKRunPackageID`, `wrapper.json` valid, package IDs equal), the signer summary, the limits (one pending request per bundle ID, 5 per minute), the prompt to a connected UI client through `approvalRequested`, and the result (Allow writes a `user` entry, Don't Allow writes a 24 h `denied` entry, no answer in 10 minutes is `timedOut`). Add broker `requestApproval` and `.control` `decideApproval`. Approving a bundle ID that already has an entry replaces it. Check: the T1 approval tests with a fake UI client pass (approve, deny, timeout, rate limits, replacement).
4. **`apkrun wrapper approve` (design step 3; design step 5 needs it).** Add the `.control` operation `approveWrapper(url)`, which runs §7.3 steps 1–3 and 5 without the UI prompt, with the CLI as the confirming client. The CLI first shows the facts of the GUI prompt ([host-ui.md](../../02-design/host-ui.md) §10.1: name, package, location, signer, installed version) from `verifyWrapper`, then asks. `--yes` skips the question. Without a TTY and without `--yes`, it exits with `cli.confirmationRequired`. Check: the golden output passes, and an approved hand-built wrapper connects.
5. **Launcher screens, strings, and menus (design step 4).** Implement screens R, S, V, L, A, N, D, T, and E of §5.4 in the session window's placeholder view, each with its message, primary action, and **Quit**. Screen S retries the connection every 2 s for 60 s. Screen T is shown when the bundle path contains `/AppTranslocation/`, before any approval (§7.4). **Open APKRun** opens `apkrun://package/<id>` (§5.4, [host-ui.md](../../02-design/host-ui.md) §3.1). Generate `LauncherStrings.generated.swift` from `Apps/APKRunLauncher/Localizable.xcstrings` for the languages in `CFBundleLocalizations` (§5.9). Build the menus of §5.6 in `LauncherMenus`, the Dock menu item **Show in APKRun**, and the custom About panel (icon, name, `versionName (versionCode)` from `packageInfo`, package ID, "Runs with APKRun ‹version›", launcher version). Add the debug-only `APKRUN_LAUNCHER_TEST_NO_RUNTIME=1` switch that forces screen R ([../../03-reference/configuration.md](../../03-reference/configuration.md) §5). Check: each screen appears with the switches of step 7.
6. **`scripts/dev/make-wrapper.sh` (design step 5).** The script copies `APKRunLauncher.app/Contents/MacOS/APKRunLauncher` into a new bundle, writes Info.plist and `wrapper.json`, signs with the command of [wrapper.md](../../02-design/wrapper.md) §7.1, and registers the result with `apkrun wrapper approve --yes`. `--minimum-version` writes another `runtime.minimumVersion`. `--package-id` writes a different `application.packageId` to test screen D. It lives in `scripts/dev/` and is never shipped. Check: `scripts/dev/make-wrapper.sh io.apkrun.fixture.hellotext /tmp/w` produces a bundle that passes `codesign --verify --strict`.
7. **Acceptance (design step 6).** Run the T2 tests below on the reference Mac and record the results. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.8):

- **T0** (`Packages/RuntimeAPI/Tests/`, `Apps/APKRunLauncher` unit tests): `wrapper.json` encoding (sorted keys, byte-stable output), schema validation, an unknown `formatVersion` rejected. The §5.3 compatibility matrix (versions and API majors: equal, minor older, one major behind, two majors behind, newer launcher, runtime below `minimumVersion`).
- **T1** (`Packages/WrapperCore/Tests/`): approval service with the fake UI client: approve, deny, timeout, rate limits (a second request for the same bundle ID, the sixth in one minute), replacement of an existing entry, and a denied entry that has not expired. Registry atomic writes. Authorization: a wrapper connection cannot open a session for another package.
- **T2** (`Tests/IntegrationTests/`, real apkrund): a hand-built `HelloText.app` launches HelloText. Screens R (`APKRUN_LAUNCHER_TEST_NO_RUNTIME=1`), S (apkrund not registered), V (`--minimum-version 99.0`), L (a launcher built against a RuntimeAPI major two behind, from the test build), and D (`--package-id` mismatch). Endpoint security (NFR-SEC-07): a copy of the wrapper with a changed resource, and the launcher re-signed by the test with the same identifier, are both refused and need approval.
- **T3 / manual**: v0.4 checklist C04-6 (the text and layout of screens R, S, V, L, and D) and the #044 part of C04-7 ([../test-strategy.md](../test-strategy.md) §8.5).

### Acceptance criteria

- [ ] A manually constructed wrapper launches HelloText: `scripts/dev/make-wrapper.sh` builds `HelloText.app`, `apkrun wrapper approve` registers it, and `open HelloText.app` shows HelloText in the launcher's window.
- [ ] The launcher takes its package from Info.plist and `wrapper.json`. A mismatched `application.packageId` shows screen D.
- [ ] The launcher connects on `.wrapper(bundleID)` and calls `openSession`. The launcher process stays running and owns the window (ADR-0006).
- [ ] Screen R appears with `APKRUN_LAUNCHER_TEST_NO_RUNTIME=1`. Screen S appears when apkrund is not registered and retries every 2 s for 60 s. Screen V appears with `runtime.minimumVersion` set to `99.0`. Screen L appears for a launcher two RuntimeAPI majors behind. Each screen has its primary action and **Quit**.
- [ ] A launcher one RuntimeAPI major behind still opens its app (NFR-CMP-02).
- [ ] The executable in the wrapper is a byte copy of the generic launcher's executable with a new signature (FR-WRP-06). `lipo -archs` prints `arm64` only.
- [ ] A wrapper connection can open sessions only for its own package. A modified copy and a re-signed binary are refused and need approval (NFR-SEC-07).
- [ ] An unknown wrapper shows screen A while it waits for approval. Don't Allow gives "APKRun did not allow ‹App› to open." and a 24 h denied entry.
- [ ] A translocated wrapper shows screen T and asks for no approval.
- [ ] Steps 1–5 of the startup take at most 150 ms p50 on the reference Mac, with no network or signature check on that path ([wrapper.md](../../02-design/wrapper.md) §5.2).

### Notes

- **Record:** the first observation for R-17: whether a hand-built, ad-hoc signed wrapper opens from Finder without a Gatekeeper or App Management prompt on macOS 27. The product result is recorded in #046 and #047.
- `LSUIElement` is not set (R-19). The background-mode verification is #054.
- This task adds a first registry and the approval service ([wrapper.md](../../02-design/wrapper.md) §15 #044, step 3), because the wrapper endpoint cannot authorize a hand-built wrapper without them. #045 extends the same types, and #047 adds the approval window.
- `apkrun wrapper approve` uses the `.control` operation `approveWrapper(url)` ([wrapper.md](../../02-design/wrapper.md) §12.1, [runtime-api.md](../../03-reference/runtime-api.md)).
- **Pitfall:** screen R needs both conditions of §5.4: no APKRun.app for `io.apkrun.APKRun`, and no answer from the Mach service. On a development Mac both exist, so the test uses the debug switch. Release builds must not contain the switch string ([../test-strategy.md](../test-strategy.md) §3.3).
- **Pitfall:** the launcher never reads files under `~/Library/Application Support/APKRun/` and never writes inside its own bundle (§5.10). A write would break the seal.

---

## #045 WrapperCore generator

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #044 |
| Requirements | FR-WRP-01, FR-WRP-03, FR-WRP-05 |
| Design | [wrapper.md](../../02-design/wrapper.md) §2, §3, §4, §6.1, §6.2, §6.4, §6.5, §7.2, §9.1 (steps 1–3 and 5), §13, §14, §15 #045, §16; [wrapper-json.md](../../03-reference/wrapper-json.md); [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) |
| Modules / paths | `Packages/WrapperCore/` (`BundleIDMapper`, `WrapperFileName`, `AppWrapperGenerator`, `WrapperConfiguration`, `WrapperInstaller`, `WrapperRegistry`, `WrapperValidator` (structural part)), `Packages/RuntimeHost/`, `Packages/RuntimeAPI/` (`verifyWrapper` DTOs), `Packages/WrapperCore/Tests/` |
| Risks / questions | OQ-01 (the `io.apkrun` namespace, must be settled before this task starts) |

### Goal

WrapperCore generates a wrapper bundle for a package: `Contents/MacOS/APKRunLauncher`, `Contents/Resources/wrapper.json`, `Contents/Resources/AppIcon.icns`, and `Contents/Info.plist`, with a deterministic bundle ID. Generating twice gives byte-identical files, and the bundle passes structural validation and opens from Finder.

### Scope

- `BundleIDMapper` (§4.1) and the file-name rules (§4.3).
- `WrapperConfiguration`, `WrapperGenerationRequest`, `GeneratedWrapper`, and `AppWrapperGenerator.generate` (§6.1) with steps 1–7 and 10–13 of §6.2. The icon is the host preview or the placeholder until #055.
- `WrapperInstaller`: placement into the destination directory with `rename`, or copy and rename across volumes, and the conflict rules of §6.4.
- `WrapperRegistry` completed: `pending` entries as the journal, `recover()` at apkrund start, `approval: generated`, one entry per bundle ID, and corrupt-file handling (§7.2).
- Structural validation: `verifyWrapper(url, deep: false)` with the §9.1 checks 1–3 and 5.
- Markers `WRAPPER_GENERATE_START` and `WRAPPER_GENERATE_END`. The `wrappers.template` and `wrappers.registry` health checks (§14).

Out of scope:

- Signing, the cdhash, and `createWrapper` on the control endpoint (#046). Until #046, the T1 tests sign with the same `codesign` call through a test helper.
- Icon composition (#055). Destinations other than a given directory, `destinationNotAccessible`, and `placeStagedWrapper` (#056).
- Portable and distribution kinds (steps 8 of §6.2; #089, #088).
- Refresh, the full validator, and removal (#076).
- `doctor` output for the health checks (#059). This task registers the checks.

### Deliverables

- `Packages/WrapperCore/Sources/WrapperCore/`: `BundleIDMapper.swift`, `WrapperFileName.swift`, `WrapperConfiguration.swift`, `AppWrapperGenerator.swift`, `WrapperInstaller.swift`, `WrapperRegistry.swift` (extended), `WrapperValidator.swift` (structural checks), and `InfoPlistWriter.swift`.
- RuntimeHost code that fills `WrapperConfiguration` from the package record, the settings, and the host preview icon (§6.1).
- The `verifyWrapper` operation on `.control` (structural depth).
- The `wrappers.template` and `wrappers.registry` health checks.
- T0 and T1 tests in `Packages/WrapperCore/Tests/WrapperCoreTests/`.

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #045, steps 1–4. Design step 1 is split into steps 1–3 here.

1. **Bundle IDs and file names (design step 1).** `BundleIDMapper.map(_:)` implements §4.1: `_` becomes `-`, and a package ID with an uppercase letter gets `-h` plus the lowercase hex of the first 4 bytes of SHA-256 of the UTF-8 package ID. The prefix is `io.apkrun.android.` (OQ-01). `WrapperFileName` implements the four steps of §4.3 (NFC, removal of Cc and Cf except ZWJ and variation selectors, `/` and `:` to `-`, whitespace collapse, leading `.` removed, 200-byte cut at a grapheme boundary, fallback to the last package segment). Check: the T0 table of §4.1 and 1,000 random valid package IDs pass (the output is valid and unique ignoring case), and the §4.3 cases pass.
2. **Generator (design step 1).** `AppWrapperGenerator.generate` runs §6.2 steps 1–7 and 10–13 into `Wrappers/staging/<uuid>/<name>.app`: validation (package ID syntax, a non-empty name, the icon source readable, the launcher template valid (strict) and arm64, else `launcherTemplateInvalid`), the registry lookup (`wrapperExists` for a valid wrapper and `replace == .never`), Info.plist (XML, sorted keys, every key of §2.1, and the category mapping), `PkgInfo`, `wrapper.json` from `WrapperDocument`, the icon (a preview PNG or the placeholder written through the iconset path of §8.3, so the file is always `AppIcon.icns`), and `clonefile` of the template executable. Files get modes 0644 and 0755. PNGs are written without metadata (§6.5). Emit `WRAPPER_GENERATE_START` and `WRAPPER_GENERATE_END {durationMs, kind}`. Check: a T1 test generates `HelloText.app` into a temporary directory, and the tree matches §2.
3. **Placement and conflicts (design step 1).** `WrapperInstaller` places the staged bundle with `rename`. On another volume it copies to `<dest>/.<name>.app.apkrun-<uuid>` and renames. It applies §6.4: nothing there is placed, the same package's wrapper needs `.sameWrapper`, and a wrapper of another package, a native app, a folder, or a file is never replaced (`nameConflict`). Registration after placement calls `LSRegisterURL(final, true)` and `noteFileSystemChanged`. A registration error becomes the `registrationFailed` warning. No `mdimport` is run. Check: the T1 conflict cases pass.
4. **Registry with recovery (design step 2).** Extend `WrapperRegistry`: step 10 writes a `pending` entry with the staging and final paths, and step 12 makes it `active` with the bookmark. `recover()` runs at apkrund start: it activates a pending entry whose final bundle exists with the recorded cdhash, otherwise it deletes the staging directory, removes leftover `.apkrun-<uuid>` items, and drops the entry. A corrupt file is renamed `registry.json.corrupt-<timestamp>`, and `registryUnavailable` is reported. There is one entry per bundle ID. Add the `wrappers.registry` health check. Check: the T1 recovery tests pass for a crash after each step of §6.2.
5. **Structural validation (design step 3).** `verifyWrapper(url, deep: false)` runs the §9.1 checks 1–3 and 5 for any bundle, registered or not: the bundle resolves, it is readable, `CFBundleIdentifier` and the executable's cdhash equal the registry (cdhash cached by inode, size, and mtime), and the store has a record for the package. It also checks the §2 layout, Info.plist with `plutil`-equivalent parsing, and `wrapper.json` against the schema. Add the `wrappers.template` health check. Check: a T1 test with a generated bundle passes, and one with a missing `wrapper.json` fails.
6. **Acceptance (design step 4).** Run the T1 and T2 tests below. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.8):

- **T0**: `BundleIDMapper`: the §4.1 table, `_` mapping, the uppercase suffix, 1,000 random IDs. File names (§4.3) with `/`, `:`, emoji ZWJ sequences (OddName's label), 300-byte names, and empty names.
- **T1** (temporary directory, test signing helper): determinism: two generations into different directories give the same SHA-256 for every file (§6.5). Conflicts (§6.4). `pending` recovery after a crash at each step of §6.2. Registry: atomic writes, corrupt-file handling, one entry per bundle ID. Structural validation.
- **T2** (`Tests/IntegrationTests/`): a generated bundle opens with `NSWorkspace.open`, and `mdls -name kMDItemContentType` reports `com.apple.application-bundle`.

### Acceptance criteria

- [ ] The generated bundle contains `Contents/MacOS/APKRunLauncher`, `Contents/Resources/wrapper.json`, `Contents/Resources/AppIcon.icns`, and `Contents/Info.plist`, and nothing that §2 does not list.
- [ ] The bundle ID mapping is defined and implemented: `io.apkrun.android.<mapped package>` with `_` → `-` and the uppercase suffix (FR-WRP-05). `io.apkrun.fixture.odd_name` maps to `io.apkrun.android.io.apkrun.fixture.odd-name`.
- [ ] The generated bundle passes structural validation and can be opened by Finder (`NSWorkspace.open`). `mdls -name kMDItemContentType` reports `com.apple.application-bundle`.
- [ ] Generating twice gives byte-identical trees (§6.5). If `codesign` or `iconutil` is not deterministic, the test excludes the affected file, and the reason is recorded in [wrapper.md](../../02-design/wrapper.md) §18.
- [ ] `wrapper.json` holds no versionCode, versionName, APK path, or digest (FR-WRP-03).
- [ ] An existing item at the destination is never replaced unless it is this package's wrapper and the request allows it (§6.4).
- [ ] A crash at any step of §6.2 leaves either a complete, active wrapper or nothing, after `recover()`.

### Notes

- **Before starting:** OQ-01 must be settled, because the prefix `io.apkrun.android.` becomes permanent in every bundle ID. The default is to keep `io.apkrun`.
- **Record:** whether `codesign` and `iconutil` produce byte-identical output on macOS 27 ([wrapper.md](../../02-design/wrapper.md) §6.5). If `iconutil` does not, use `ICNSWriter` (§8.4) and record it.
- `WrapperCore` must not read APKs or package state. Everything comes through `WrapperConfiguration` ([../../01-architecture/modules.md](../../01-architecture/modules.md) §2).
- The launcher template's version and API come from `LauncherBuild`, not from the APKRun.app version string.

---

## #046 Generate Hello.app

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #045 |
| Requirements | FR-WRP-01, FR-WRP-10 (local wrappers), NFR-RES-03 (at most 8 MiB without `bootstrap/`) |
| Design | [wrapper.md](../../02-design/wrapper.md) §4, §6.2 step 9, §7.1, §7.2, §12.1, §12.2, §15 #046; [package-store.md](../../02-design/package-store.md) §10.1; [cli.md](../../02-design/cli.md) §4.4; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §3.3 |
| Modules / paths | `Packages/WrapperCore/` (`WrapperSigner`), `Packages/RuntimeHost/`, `Daemon/apkrund/`, `Packages/RuntimeAPI/` (`WrapperRequest`, `WrapperInfo`, `WrapperSummary`), `CLI/apkrun/Commands/Wrap.swift`, `Tests/IntegrationTests/` |
| Risks / questions | R-17 |

### Goal

From the installed HelloText package, apkrund creates `HelloText.app` with the Android label, the icon, and the package ID, signs it ad-hoc, and records its cdhash. `open HelloText.app` starts APKRunLauncher and opens HelloText.

### Scope

- `WrapperSigner` (§7.1): the `codesign` call, strict verification, and the cdhash.
- §6.2 step 9 and the cdhash in the registry entry.
- `createWrapper(WrapperRequest)` on `.control` as a long operation (§12.1), with `WrapperInfo` and the `wrappers` event `created`.
- A first `apkrun wrap <package>` for an installed package, with `--output <dir>`.
- The label, icon, and package ID come from the installed package metadata. The icon is the host preview or the placeholder until #055.

Out of scope:

- `apkrun wrap <file.apk>`, the import/install table, and the other flags (#075).
- Rendered icons (#055). `~/Applications` handling, `LSRegisterURL` checks, and Spotlight (#056).
- Developer ID signing and notarization (#088).

### Deliverables

- `Packages/WrapperCore/Sources/WrapperCore/WrapperSigner.swift`.
- `createWrapper` in RuntimeHost and on the apkrund control endpoint.
- `CLI/apkrun/Commands/Wrap.swift` with `apkrun wrap <package> [--output <dir>] [--json]`, and its golden output.
- The T2 test that generates and opens `HelloText.app`.

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #046, steps 1–2. Design step 1 is split into steps 1–3 here.

1. **Signing (design step 1).** `WrapperSigner.sign(_:)` runs `/usr/bin/codesign --force --sign - --identifier <bundleID> --options runtime --timestamp=none <staging>/<name>.app`. Signing is the last write. It then runs `SecStaticCodeCheckValidity` with `kSecCSStrictValidate | kSecCSCheckAllArchitectures` and the requirement `identifier "<bundleID>"`, and reads the cdhash from `kSecCodeInfoUnique` as 40 hex characters. Failures are `signingFailed(status:message:)` and `verificationFailed`. Check: a T1 test signs a staged bundle and reads a 40-character cdhash.
2. **Registry and operation (design step 1).** §6.2 step 9 writes the cdhash into the `pending` entry, with `launcherVersion`, `launcherAPI`, and `approval: generated`. Add `createWrapper(WrapperRequest{packageID, destination, fileName?, displayName?, iconFile?, portable, replace})` on `.control`. RuntimeHost fills `WrapperConfiguration` from the package record (display name, category), the settings, and the store's icon ([package-store.md](../../02-design/package-store.md) §10.1). It returns `WrapperInfo` and posts `WrapperChange.created`. Check: after `createWrapper`, the registry has an active entry, and the launcher's endpoint requirement accepts the new wrapper without approval.
3. **`apkrun wrap <package>` (design step 1).** Add the command for an installed package. It prints the bundle path on success, or the `WrapperInfo` DTO with `--json` ([cli.md](../../02-design/cli.md) §4.4). `--output` defaults to `~/Applications`. Check: the golden tests pass for success, `packageNotInstalled`, and `wrapperExists`.
4. **Acceptance (design step 2).** Generate `HelloText.app` from the installed fixture and run the T2 checks. Check: every acceptance criterion is checked.

### Tests

- **T0**: `apkrun wrap` golden output (human and JSON) against a fake `RuntimeService` ([cli.md](../../02-design/cli.md) §6.3).
- **T1**: signing and cdhash reading. Two generations give byte-identical trees, including `_CodeSignature/CodeResources` (§6.5).
- **T2** (`Tests/IntegrationTests/`): `apkrun wrap io.apkrun.fixture.hellotext --output <suite folder>`. `codesign -dv` shows `Signature=adhoc` and the identifier. `codesign --verify --strict` passes. `NSWorkspace.open` starts the launcher, and HelloText logs `start`. `mdls` reports the content type.

### Acceptance criteria

- [ ] The label, icon, and package ID are taken from the installed package: `HelloText.app` has the Android label as its name and `CFBundleDisplayName`, the HelloText icon (the host preview until #055), and `APKRunPackageID` `io.apkrun.fixture.hellotext`.
- [ ] `HelloText.app` is generated. Its bundle ID is `io.apkrun.android.io.apkrun.fixture.hellotext`.
- [ ] Local ad-hoc signing is used: `codesign -dv` shows `Signature=adhoc` and that identifier, and `codesign --verify --strict` passes (FR-WRP-10).
- [ ] `open HelloText.app` invokes APKRunLauncher, which opens HelloText.
- [ ] The registry entry has the cdhash from `kSecCodeInfoUnique`, `approval: generated`, and state `active`. The wrapper opens without an approval prompt.
- [ ] The bundle is at most 8 MiB (NFR-RES-03).
- [ ] The bundle has no `com.apple.quarantine` attribute, and opening it shows no Gatekeeper dialog.

### Notes

- **Record:** the R-17 result for local wrappers in [../risks.md](../risks.md) and in [wrapper.md](../../02-design/wrapper.md) §7.1: whether an ad-hoc wrapper written by apkrund into `~/Applications` opens without a Gatekeeper or App Management prompt on macOS 27. The research tested this, but the product has not ([../risks.md](../risks.md) R-17).
- The task names the bundle "Hello.app". The fixture's label decides the name, so it is `HelloText.app`.
- `--deep` is never used for signing (TN2206). The bundle has no nested code.

---

## #047 Launch Hello.app end to end

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #046, #031 |
| Gate | G8 |
| Requirements | NFR-SEC-07, NFR-PERF-01 (warm p50 ≤ 1.5 s, p95 ≤ 3 s), NFR-PERF-02 (cold p50 ≤ 40 s) |
| Design | [wrapper.md](../../02-design/wrapper.md) §5, §7.3, §15 #047, §16; [host-ui.md](../../02-design/host-ui.md) §2.1, §2.2, §3.3, §9.4, §10.1, §11; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7.2, §7.3; [display-and-windowing.md](../../02-design/display-and-windowing.md) §5, §7; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §10.2, §10.6; [../roadmap.md](../roadmap.md) §2 (G8); [../test-strategy.md](../test-strategy.md) §5 |
| Modules / paths | `Apps/APKRun/Features/Approvals/`, `Apps/APKRun/Models/ApprovalCenter.swift`, `Apps/APKRun/Features/Settings/` (Privacy), `Apps/APKRun/APKRunApp.swift` (`--approve`, `Window(id: "approval")`), `Packages/RuntimeHost/` (the wrapper branch of `launch(packageID)`, `pendingApprovals`, `deniedWrappers`, `clearWrapperDenial`), `Packages/RuntimeAPI/` (their DTOs), `Tests/IntegrationTests/`, `Tests/AcceptanceTests/G8Wrapper` |
| Risks / questions | R-17 |

### Goal

Double-clicking `HelloText.app` in Finder shows an interactive HelloText window, with the runtime warm or stopped, and no terminal is involved. The flow is `HelloText.app` → APKRunLauncher → XPC → apkrund → DisplayPool → Android activity → the launcher's NSWindow. The window belongs to the launcher, not to apkrund (ADR-0006). This task closes gate G8.

### Scope

- The end-to-end check of #044–#046 with apkrund as a LaunchAgent (#031). The design says "no new component" for the wrapper.
- The wrapper branch of `launch(packageID)`: a registered wrapper whose cdhash matches is opened, otherwise the generic launcher with `--package` ([runtime-daemon.md](../../02-design/runtime-daemon.md) §7.2).
- The approval UI in APKRun.app (host-ui "UI parts" table): `ApprovalCenter`, `Window(id: "approval")`, the `--approve` launch argument, the "APKRun needs your attention" notification, and Settings → Privacy → **Mac apps you didn't allow** with **Remove**.
- The control operations behind it ([wrapper.md](../../02-design/wrapper.md) §12.1, [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §10.2): `pendingApprovals` → `[ApprovalPrompt]` for the prompts requested before APKRun.app connected, and `deniedWrappers` → `[DeniedWrapper]` with `clearWrapperDenial(bundleID)` for the denied list.
- The G8 acceptance check `G8Wrapper` and `scripts/run-gate.sh G8`.

Out of scope:

- Dock and Spotlight after logout (#056). The Dock check here is "Keep in Dock" in the same login session.
- Portable approval details (#089).
- New launcher screens or menus.

### Deliverables

- `Apps/APKRun/Models/ApprovalCenter.swift`, `Apps/APKRun/Features/Approvals/ApprovalWindow.swift`, the `approval` window scene, and `--approve` handling.
- The "APKRun needs your attention" notification in `HostNotificationClient`.
- `Apps/APKRun/Features/Settings/SettingsScene.swift` with `PrivacyPane.swift`, which holds only **Mac apps you didn't allow** (the denied list with **Remove**) until #079 adds the app-wide panes.
- The wrapper branch in `launch(packageID)`.
- `pendingApprovals`, `deniedWrappers`, and `clearWrapperDenial` in RuntimeHost, with their DTOs in RuntimeAPI and round-trip tests.
- `Tests/AcceptanceTests/G8Wrapper` and its gate script entry.
- The G8 evidence: the script report, the xcresult, and a screen recording ([../test-strategy.md](../test-strategy.md) §5).

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #047, steps 1–2. The approval window of [host-ui.md](../../02-design/host-ui.md) §10.1 is assigned to this task by the host-ui "UI parts" table, so it is step 1 here.

1. **Approval window.** Add `ApprovalCenter`, which subscribes to `approvalRequested` and `approvalResolved` and answers with `decideApproval`. When it connects, it first calls `pendingApprovals` and queues the prompts that were requested before APKRun.app ran ([wrapper.md](../../02-design/wrapper.md) §7.3 step 4). Add `Window(id: "approval")` with the layout of [host-ui.md](../../02-design/host-ui.md) §10.1: the wrapper icon, "Allow “‹App›” to open ‹package› in APKRun?", location, signer, the installed version, and "Only allow Mac apps you trust." **Allow** is not the default button, so Return does not press it. Requests queue in arrival order, one prompt at a time. A request that times out after 10 minutes closes its prompt. When APKRun.app is not running, apkrund opens it with `--approve` and `activates = true`, and only the approval window is shown ([host-ui.md](../../02-design/host-ui.md) §3.3). If the window cannot be shown, post "APKRun needs your attention" (§11). Add the `Settings` scene (§2.1). It is the first task with a settings pane, so it creates the scene with only the Privacy pane; #079 adds the other panes and the tab order. Add **Mac apps you didn't allow** to Settings → Privacy (§9.4). It lists `deniedWrappers`, and **Remove** calls `clearWrapperDenial(bundleID)`, so the next launch of that Mac app asks again (§7.3 step 5). Check: the T1 XCUITest with the embedded runtime fake passes.
2. **Wrapper branch of `launch`.** In RuntimeHost, `launch(packageID)` opens the registered wrapper with `NSWorkspace.openApplication` when its quick validation (§9.1 checks 1–3) passes and the cdhash matches. Otherwise it opens the generic launcher with `--package`. Check: `apkrun launch io.apkrun.fixture.hellotext` opens `HelloText.app`, and a Dock tile with the HelloText name appears.
3. **End to end (design step 1).** Run the flow with apkrund registered as a LaunchAgent: Finder double-click, launcher, `.wrapper(bundleID)`, `openSession`, DisplayPool, the activity on a secondary display, and the IOSurface window. Measure the warm and cold click-to-first-frame times with the perf harness (#070) through the wrapper. Check: the T2 test passes for a warm and a stopped runtime.
4. **G8 check (design step 2).** Add `Tests/AcceptanceTests/G8Wrapper` with the assertions of [../test-strategy.md](../test-strategy.md) §5 and run `scripts/run-gate.sh G8` on the reference Mac with a clean build from `main`. Check: the gate passes, and the evidence is attached to the gate issue.

### Tests

- **T1**: XCUITest with the embedded runtime fake: the approval prompt appears, Return does not allow, Don't Allow writes a denied entry, a queued second request appears after the first one is answered, a prompt requested before APKRun.app started is shown from `pendingApprovals`, and **Remove** in the denied list clears the entry through `clearWrapperDenial` ([host-ui.md](../../02-design/host-ui.md) §15). T0 round trips of the three operations' DTOs.
- **T2** (`Tests/IntegrationTests/`): `NSWorkspace.open` of `HelloText.app` plus an XCUITest-driven click. Pointer and keyboard reach HelloText (`click <n>`, `text …`). The process list during the launch contains only the wrapper and apkrund as new processes. Dock launch after "Keep in Dock" with a cold runtime (placeholder, then the app) and a warm runtime.
- **T3** (`Tests/AcceptanceTests/G8Wrapper`, `scripts/run-gate.sh G8`): the G8 assertions of [../test-strategy.md](../test-strategy.md) §5. Never retried.

### Acceptance criteria

- [ ] Double-clicking `HelloText.app` in Finder displays an interactive HelloText window: pointer clicks are logged as `click <n>`, and typed text arrives exactly.
- [ ] No terminal interaction is required. No Terminal window opens, and no process other than the wrapper and apkrund is started.
- [ ] The window is the launcher's NSWindow, fed through XPC by apkrund and DisplayPool from the Android activity (ADR-0006).
- [ ] The same works from the Dock after "Keep in Dock", with the runtime stopped (the placeholder, then the app) and warm.
- [ ] G8 condition 1: `apkrun wrap` with HelloText produces `HelloText.app` with the bundle ID `io.apkrun.android.io.apkrun.fixture.hellotext`, ad-hoc signed, which passes `codesign --verify --strict` ([../roadmap.md](../roadmap.md) §2).
- [ ] G8 condition 3: no terminal interaction is needed, and the Finder and Dock launches work with the runtime stopped before the click and with it warm.
- [ ] `scripts/run-gate.sh G8` passes on the reference Mac with a clean build from `main`, and the evidence is attached.
- [ ] The approval window follows [host-ui.md](../../02-design/host-ui.md) §10.1: Return does not allow, requests queue, and a timeout closes the prompt. A request made before APKRun.app started is shown when it opens (`pendingApprovals`).
- [ ] Settings → Privacy → **Mac apps you didn't allow** lists the denied wrappers, and **Remove** makes the next launch ask again.
- [ ] The warm and cold launch times through the wrapper are recorded against NFR-PERF-01 and NFR-PERF-02.

### Notes

- **Record:** the G8 result in [../roadmap.md](../roadmap.md) §2 and the gate issue. The R-17 product result is recorded here if #046 did not already record it for the Finder and Dock paths.
- The design says "no new component" for this task, but the host-ui "UI parts" table gives it the approval window. Both are true: nothing new in the wrapper, and a new window in APKRun.app.
- If G8 fails, follow [../roadmap.md](../roadmap.md) §2: stop dependent tasks (#048 and everything after it), and record the failure.

---

## #055 Android icon to macOS icon pipeline

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #045, #036 |
| Requirements | FR-WRP-07 |
| Design | [wrapper.md](../../02-design/wrapper.md) §8, §9.1 (refresh reasons), §15 #055, §16; [package-store.md](../../02-design/package-store.md) §10; [guest-components.md](../../02-design/guest-components.md) §8.2; [guest-protocol.md](../../02-design/guest-protocol.md) §11.1 (op 107, capability `store.icon.v1`); [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) |
| Modules / paths | `Packages/WrapperCore/` (`IconComposer`, `ICNSWriter`, `IconsetWriter`), `Packages/APKStoreCore/` (`icon/`, `icon.json`, `PackageChange.iconChanged`), `Packages/RuntimeCore/` (the `StoreAgentChannel` call), `Guest/APKRunStore/` (`IconRenderer`), `Packages/GuestProtocol/proto/`, `Packages/WrapperCore/Tests/` (icon masters and goldens) |
| Risks / questions | None open in [../risks.md](../risks.md) or [../open-questions.md](../open-questions.md). The macOS 27 gray-plate behavior is checked manually (C04-1) |

### Goal

Every wrapper gets a correct macOS icon made from the Android icon. The Store Agent renders the installed app's icon layers, the store keeps them, and WrapperCore composes a 1024 px opaque master and writes `AppIcon.icns`. The icon looks right in Finder, the Dock, and Spotlight, and macOS applies its own shape with no gray plate.

### Scope

- Store Agent `IconRenderer` and `RenderIcon(package, size_px)` (op 107), rendering adaptive layers or a legacy bitmap at 1536 px.
- Store side: rendering after the first install and after every update or rollback, `icon/` with `icon.json {kind, sizePx, renderedForVersionCode, setDigest}`, and `PackageChange.iconChanged` when the composed result differs ([package-store.md](../../02-design/package-store.md) §10.2).
- `IconComposer`: the adaptive, legacy, host preview, custom, and placeholder rules of [wrapper.md](../../02-design/wrapper.md) §8.2.
- The iconset and `iconutil` (§8.3), with the `ICNSWriter` fallback (§8.4).
- The `.icon` refresh reason and `iconDigest` in the registry (§8.5). #076 shows the reason and does the refresh.
- `customIconInvalid` and `iconConversionFailed` errors.

Out of scope:

- Refreshing existing wrappers (#076). Wrappers are never changed automatically (FR-WRP-04).
- **Refresh Dock Icons** in Settings → Troubleshooting (#076).
- Icon Composer `.icon` files, `Assets.car`, tinted and clear icon styles (§8.4). The monochrome layer is stored but not used.
- Icons for stock images: `ADBStoreAgentChannel` has no rendering, and the host preview is used ([package-store.md](../../02-design/package-store.md) §10.2).

### Deliverables

- `Guest/APKRunStore/` `IconRenderer` and the op 107 handler, and the `store.icon.v1` capability in `Hello`.
- The `RenderIcon` message in `Packages/GuestProtocol/proto/` and its host call in the `StoreAgentChannel` implementation.
- APKStoreCore icon storage (`Packages/<id>/icon/`, `icon.json`) and the `iconChanged` event.
- `Packages/WrapperCore/Sources/WrapperCore/Icons/`: `IconComposer.swift`, `IconsetWriter.swift`, `ICNSWriter.swift`.
- `iconDigest` in the registry entry and the `.icon` refresh reason in the validator's step 6 inputs.
- Icon masters and golden images in `Packages/WrapperCore/Tests/WrapperCoreTests/Resources/` ([../test-strategy.md](../test-strategy.md) §4.6).

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #055, steps 1–3. Design step 2 comes first here, because the composer needs real renders to tune against.

1. **Store Agent rendering (design step 2).** In `Guest/APKRunStore/`, `IconRenderer` calls `loadUnbadgedIcon`. For an `AdaptiveIconDrawable` it draws the background, foreground, and monochrome layers each at `size_px` on the full 108 dp canvas without a mask. For a legacy icon it draws the highest-density bitmap at the same size. It returns PNGs through the artifact transfer ([guest-components.md](../../02-design/guest-components.md) §8.2, [guest-protocol.md](../../02-design/guest-protocol.md) §11.1 op 107). Check: a T2 test on the custom image gets two 1536 px layers for HelloText and one bitmap for IconLegacy.
2. **Store icon storage (design step 2).** APKStoreCore calls `RenderIcon(package, 1536)` after the first install and after every update or rollback. It writes the files to `Packages/<id>/icon/` with `icon.json`, composes the master through WrapperCore's pure `IconComposer` function to get the digest, and emits `PackageChange.iconChanged` when the digest differs ([package-store.md](../../02-design/package-store.md) §10.2). Check: a T1 test with a fake channel emits `iconChanged` only when the render changes.
3. **Composition (design step 1).** `IconComposer` implements §8.2: adaptive (background, then foreground on a 1536 px canvas, white under a background with alpha, crop the centered 1024 px), legacy and host preview (trim alpha < 8; full bleed when the aspect is 0.97–1.03 and all four corners have alpha ≥ 250 at 2 % insets; otherwise a white square with the image fitted in the centered 820 px box), custom (PNG, JPEG, or HEIC, square and at least 512 px, or an `.icns` copied as is; else `customIconInvalid`), and placeholder (the first grapheme of the display name, white, on a color picked by SHA-256 of the package ID). The master is sRGB, 8 bits per channel, and opaque. RuntimeHost passes `.rendered` when `icon/` exists, else `.preview`, else `.placeholder`. Check: the T0 rule tests pass.
4. **`.icns` (design step 1).** `IconsetWriter` downscales with Core Graphics (`interpolationQuality = .high`) to 16, 32, 64, 128, 256, 512, and 1024 px with the iconset names, runs `/usr/bin/iconutil -c icns`, and deletes the iconset (§8.3). `ICNSWriter` writes the `ic04`–`ic14` PNG entries directly. It is used when `iconutil` fails or is not deterministic (§6.5), and the choice is recorded in the design. Failures are `iconConversionFailed`. Check: two generations give the same `AppIcon.icns` bytes.
5. **Refresh reason (design step 1).** Store `iconDigest` in the registry entry at generation. On `iconChanged`, WrapperCore composes the new master and, when the digest differs and the wrapper has no custom icon, adds the refresh reason `.icon` (§8.5). Check: a T1 test with a changed render adds `.icon`, and one with a custom icon does not.
6. **Acceptance (design step 3).** Generate `HelloText.app` (adaptive icon with vector layers) and `IconLegacy.app` on the custom image, and check Finder, the Dock, Spotlight, and the Apps view on macOS 27. Check: every acceptance criterion is checked.

### Tests

- **T0** (`Packages/WrapperCore/Tests/`): the §8.2 rules: adaptive crop, alpha trimming, the squareness and corner tests, the 820 px box, custom icon validation, the placeholder color from the package ID.
- **T1**: golden images of the 1024 px master for HelloText and IconLegacy within a perceptual threshold. `.icns` determinism. `iconChanged` and the `.icon` refresh reason with a fake channel.
- **T2** (`Tests/IntegrationTests/`, custom image): `RenderIcon` through the Store Agent for HelloText and IconLegacy, and a generated wrapper whose `AppIcon.icns` matches the golden master.
- **Manual**: v0.4 checklist C04-1 ([../test-strategy.md](../test-strategy.md) §8.5).

### Acceptance criteria

- [ ] The wrapper shows the correct icon in Finder, the Dock, and Spotlight, for HelloText (adaptive, vector layers) and for IconLegacy (a legacy PNG with transparency, placed on a white square).
- [ ] The 1024 px masters match the golden images within the perceptual threshold (T1).
- [ ] Neither icon gets the gray system plate on macOS 27 in Finder, the Dock, Spotlight, or the Apps view (C04-1).
- [ ] An app installed on the stock image, or not yet rendered, gets the host preview or the placeholder, and generation never fails because of a missing render.
- [ ] A changed icon after an update adds the `.icon` refresh reason and does not change the wrapper (FR-WRP-04).
- [ ] A custom icon smaller than 512 px or not square is refused with `customIconInvalid`.

### Notes

- **Record:** whether `iconutil` output is deterministic on macOS 27, and whether `ICNSWriter` became the default ([wrapper.md](../../02-design/wrapper.md) §8.4).
- The layer size is 1536 px because 72/108 of 1536 px is exactly 1024 px, so no upscaling is needed (§8.1).
- The host never draws its own squircle. An opaque square is what macOS masks cleanly (§8.2).
- **Pitfall:** `IconComposer` must stay a pure function over pixel data (Core Graphics and ImageIO only, no AppKit), because APKStoreCore also uses it for the digest ([../../01-architecture/modules.md](../../01-architecture/modules.md) §2).

---

## #056 Finder, Dock, and Spotlight integration

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #055 |
| Requirements | FR-WRP-08 (Finder, Dock, Spotlight, and Launchpad; on macOS 27 Launchpad is the Apps view) |
| Design | [wrapper.md](../../02-design/wrapper.md) §6.2 (steps 3, 11–13), §6.3, §7.4, §12.1, §14, §15 #056, §16; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.10 (`wrappers.defaultLocation`); [cli.md](../../02-design/cli.md) §4.4 |
| Modules / paths | `Packages/WrapperCore/` (`WrapperInstaller`, `WrapperDestination`), `Packages/RuntimeHost/`, `Daemon/apkrund/`, `CLI/apkrun/Commands/Wrap.swift` (client-side placement), `Tests/IntegrationTests/` |
| Risks / questions | OQ-22 (whether the Apps view lists apps outside the Applications folders, recorded here), R-17 |

### Goal

A generated wrapper behaves like any Mac app. It can be placed in `~/Applications`, in `/Applications`, or in a folder the user picks. Spotlight finds it by its name, the Dock keeps it across a logout, and Finder shows it as an application, without any indexing tools.

### Scope

- The destinations of [wrapper.md](../../02-design/wrapper.md) §6.3: `~/Applications` (the default, created if missing), `/Applications` (admin users, else `destinationNotWritable`), and any other directory.
- The TCC case: the `EPERM` probe gives `destinationNotAccessible(stagingToken)`, and the client finishes with `placeStagedWrapper(token, finalURL, bookmark)`. The CLI does this automatically.
- `LSRegisterURL(final, true)` and `noteFileSystemChanged` after placement, with `registrationFailed` as a warning.
- The `wrappers.registration` health check (§14).
- The Spotlight, Dock, Finder, and translocation checks on macOS 27.

Out of scope:

- The GUI location pop-up and the Save panel (#078). This task provides the operations it calls.
- `doctor --fix` re-registration (#059).
- Launchpad as a separate product (it was replaced by the Apps view on macOS 27).

### Deliverables

- `WrapperDestination` handling in `Packages/WrapperCore/` and `placeStagedWrapper` on `.control`.
- Client-side placement in `apkrun wrap` for `destinationNotAccessible`.
- The `wrappers.registration` health check.
- T2 tests for placement, Spotlight, and translocation, and the recorded manual checks.

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #056, steps 1–2. Design step 1 is split into steps 1–3 here.

1. **Destinations (design step 1).** `WrapperGenerationRequest.destination` accepts `.userApplications` (creates `~/Applications` if missing), `.applications` (checks the `admin` group, else `destinationNotWritable`), and `.directory(URL)`. The CLI's default comes from `wrappers.defaultLocation` ([../../03-reference/configuration.md](../../03-reference/configuration.md) §2.10). Check: a T2 test places into all three with an admin test user and fails with `destinationNotWritable` for a non-admin user.
2. **Protected folders (design step 1).** Step 3 of §6.2 probes the destination. On `EPERM`, generation finishes signing in staging and returns `destinationNotAccessible(URL, stagingToken)`. `placeStagedWrapper(token, finalPath, bookmark)` finishes steps 12 and 13 after the client moved the bundle. Tokens expire with the staging directory cleanup of `recover()`. `apkrun wrap --output ~/Desktop/…` does the move itself. Check: a T2 test with the Desktop folder places the wrapper through the client path.
3. **Registration (design step 1).** After placement, call `LSRegisterURL(final, true)` and `noteFileSystemChanged`. Add the `wrappers.registration` health check (a registered wrapper that LaunchServices does not know). Never run `mdimport` or another indexing tool. Check: `lsregister -dump` (read only, in the test) lists the new bundle.
4. **Acceptance (design step 2).** Run the T2 tests and the manual checks C04-2, C04-3, and C04-4. Record the OQ-22 result. Check: every acceptance criterion is checked.

### Tests

- **T2** (`Tests/IntegrationTests/`): wrappers in `~/Applications` and in a user-selected folder on the Desktop pass `plutil -lint` and are found by `mdfind "kMDItemCFBundleIdentifier == 'io.apkrun.android.io.apkrun.fixture.hellotext'"` within 60 s. App Translocation: a quarantined copy opened from a download folder shows screen T and asks for no approval ([wrapper.md](../../02-design/wrapper.md) §7.4). Suites that write to `~/Applications` clean up ([../test-strategy.md](../test-strategy.md) §3.9).
- **Manual**: C04-2 (Keep in Dock, log out and in, launch from the Dock), C04-3 (launch from Spotlight by its label), and C04-4 (whether the Apps view lists the Desktop copy, OQ-22) ([../test-strategy.md](../test-strategy.md) §8.5).

### Acceptance criteria

- [ ] The generated app can be found through Spotlight: `mdfind` by bundle ID finds the wrappers in `~/Applications` and in a Desktop folder within 60 s, and Spotlight launches `HelloText.app` by its label (C04-3).
- [ ] The generated app can be pinned in the Dock and opened from there, including after a logout and login (C04-2).
- [ ] The wrapper can be written to a user-selected directory, including a protected folder such as the Desktop through the client path.
- [ ] The bundle has a valid Info.plist (`plutil -lint`), bundle ID, display name, icon, and executable.
- [ ] No indexing hacks: no `mdimport` or other indexing tool is run.
- [ ] `/Applications` works for an admin user and fails with `destinationNotWritable` otherwise.
- [ ] Whether the Apps view lists the Desktop copy is recorded in [wrapper.md](../../02-design/wrapper.md) §6.3 and for OQ-22 (C04-4).

### Notes

- **Record:** the OQ-22 result. If the Apps view does not list apps outside the Applications folders, the destination picker (#078) says so next to **Other…** ([../open-questions.md](../open-questions.md) OQ-22).
- The Dock keeps pinned apps by file identity. A later refresh must keep it (R-20, #076).
- **Pitfall:** `~/Applications` may not exist on a clean account. Create it with default permissions, and do not set a custom folder icon (Finder shows the Applications icon by itself).

---

## #048 Wrapper independent of the APK file

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #047, #037 |
| Requirements | FR-WRP-03, FR-WRP-11 |
| Design | [wrapper.md](../../02-design/wrapper.md) §1, §3, §15 #048; [package-store.md](../../02-design/package-store.md) §4.1, §15 #048, §16; [update-system.md](../../02-design/update-system.md) §3; ADR-0009 [0009-thin-immutable-wrappers.md](../../01-architecture/decisions/0009-thin-immutable-wrappers.md) |
| Modules / paths | `Packages/WrapperCore/`, `Packages/APKStoreCore/` (import path), `Packages/RuntimeHost/`, `Packages/WrapperCore/Tests/`, `Packages/APKStoreCore/Tests/`, `Tests/IntegrationTests/` |
| Risks / questions | None |

### Goal

The wrapper stores only the app's identity and its initial settings. The runtime resolves the current installed artifact for every launch. Deleting the original APK file, or updating the app, does not affect the wrapper.

### Scope

- A review of every WrapperCore path (configuration, generator, validator) and the store's import path: nothing keeps, or reads again, the import source after `beginImport`.
- A test that deletes the source right after `beginImport` and still installs.
- The end-to-end check with `apkrun wrap HelloText.apk --install` and a deleted APK.

Out of scope:

- The `wrap <file>` table itself (#075). This task needs only the `--install` row, and #075 builds the rest.
- Updates behind the wrapper (#049).

### Deliverables

- Code changes, if the review finds a reference to the source.
- The T1 store test and the T1 WrapperCore check (no `WrapperConfiguration` field can hold a file path to an APK).
- The T2 end-to-end test.

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #048, steps 1–2, and [package-store.md](../../02-design/package-store.md) §15 #048, steps 1–2.

1. **Store side.** Confirm that `beginImport` copies the file into `incoming/` and that nothing after it stores or opens the source path ([package-store.md](../../02-design/package-store.md) §4.1). Add the T1 test that deletes the source right after the call. Check: the test passes.
2. **Wrapper side.** Confirm that `WrapperConfiguration`, `WrapperDocument`, the registry entry, and the generated bundle contain no import path, file name, versionCode, or digest (FR-WRP-03). The only link to the app is `packageId` (FR-WRP-11). Check: a T1 test generates a wrapper from a package imported from `HelloText.apk` and finds no occurrence of `HelloText.apk` in any file of the bundle.
3. **`--install` for files.** If #075 is not merged yet, add the `wrap <file> --install` row of [wrapper.md](../../02-design/wrapper.md) §12.2 (install as `apkrun install --yes`, then wrap). #075 adds the other rows. Check: `apkrun wrap HelloText.apk --install --output <suite folder>` works.
4. **Acceptance.** Run the T2 test. Check: every acceptance criterion is checked.

### Tests

- **T1** (`Packages/APKStoreCore/Tests/`): the source is deleted after `beginImport`, and the install still succeeds.
- **T1** (`Packages/WrapperCore/Tests/`): no import path or file name in the generated bundle.
- **T2** (`Tests/IntegrationTests/`): `apkrun wrap HelloText.apk --install`, delete `HelloText.apk`, open the wrapper, and HelloText starts. `grep -r HelloText.apk` over the bundle finds nothing.

### Acceptance criteria

- [ ] The original source APK can be removed, and the wrapper still launches the installed package.
- [ ] The wrapper stores only identity and configuration. `wrapper.json` has no version, APK path, or digest (FR-WRP-03), and a `grep` over the bundle for the APK file name finds nothing.
- [ ] The runtime resolves the current installed artifact at every launch. The wrapper references the app only by `packageId` (FR-WRP-11).
- [ ] The store never stores or reads the import source again after `beginImport`.

### Notes

- This task mostly proves a property that #045 and #073 already have. Keep it as a separate check, because a later change could break it without anyone noticing.
- **Pitfall:** the file name can leak through `NSURL` bookmark data or log strings copied into `wrapper.json`. Check every field, not only `application`.

---

## #049 Automatic update behind an unchanged wrapper

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #043, #048 |
| Gate | G9 |
| Requirements | FR-WRP-04 |
| Design | [update-system.md](../../02-design/update-system.md) §15 #049, §16; [wrapper.md](../../02-design/wrapper.md) §9.1 (deep validation), §15 #049; [package-store.md](../../02-design/package-store.md) §7; [../roadmap.md](../roadmap.md) §2 (G9), §3.4 (first public demo); [../test-strategy.md](../test-strategy.md) §4.3, §5 |
| Modules / paths | `Packages/WrapperCore/` (`WrapperFileHashes`, deep `verifyWrapper`), `Tests/IntegrationTests/`, `Tests/AcceptanceTests/G9WrapperIntegrity`, `scripts/run-gate.sh`, `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/`, `scripts/dev/update-server.py` |
| Risks / questions | None open. This gate validates the product concept |

### Goal

The product promise holds end to end: `HelloUpdate.app` runs V1, APKRun finds V2 in the background and installs it after the app quits, and the same wrapper then runs V2 with V1's data. The wrapper was not changed or re-signed. This task closes gate G9.

### Scope

- No new product component. The end-to-end test of #040 (gentle updates), #043 (rollback safety), #046 (signing), and #048 (identity only).
- The wrapper-side helpers for the test: the file hash list of a bundle and the deep validation ([wrapper.md](../../02-design/wrapper.md) §9.1 step 4).
- The G9 acceptance check `G9WrapperIntegrity` and `scripts/run-gate.sh G9`.
- The first public demo run (C04-9).

Out of scope:

- New update logic. A failure here is fixed in the task that owns the failing part.
- Real update sources (M8).

### Deliverables

- `WrapperFileHashes` (a sorted list of relative path and SHA-256 for every file in a bundle) in `Packages/WrapperCore/`, used by the tests and by `apkrun wrapper verify --deep --json` (#075).
- The T2 building-block test and `Tests/AcceptanceTests/G9WrapperIntegrity`.
- The G9 evidence and the C04-9 demo record.

### Implementation steps

The design steps are [update-system.md](../../02-design/update-system.md) §15 #049, steps 1–2. The design has one acceptance step. It is split into steps 2–4 here.

1. **Hash list and deep validation.** Add `WrapperFileHashes.compute(bundleURL)`: every regular file under the bundle, sorted by relative path, with SHA-256, including `Contents/MacOS/APKRunLauncher`, `Contents/Info.plist`, `Contents/Resources/wrapper.json`, `Contents/Resources/AppIcon.icns`, and `Contents/_CodeSignature/`. `verifyWrapper(url, deep: true)` adds `SecStaticCodeCheckValidity` (strict, all architectures). Check: a T0 test over a fixed directory gives a stable list.
2. **Set up V1.** Install HelloUpdate V1 with the LocalProvider at `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/1/` and mode automatic, generate `HelloUpdate.app`, open it, and let V1 write `HELLO` to its data. Record the hash list and the registry cdhash. Check: HelloUpdate logs its V1 marker.
3. **Update behind the wrapper.** Publish V2 (`…/2/`, or Direct through `scripts/dev/update-server.py`). The scheduler finds and stages it while V1 runs, and nothing is installed. Quit `HelloUpdate.app`. The gentle-update rules install V2 without user action. Check: the update history records detection, staging, the wait, and the install.
4. **Run V2 from the same wrapper.** Open the same `HelloUpdate.app`. V2 runs and logs `data HELLO`. Compute the hash list and read the cdhash again. Run the deep validation. Check: the hashes and the cdhash equal the V1 values, and no `codesign` ran on the bundle (the process log of the test).
5. **G9 check.** Put steps 2–4 in `Tests/AcceptanceTests/G9WrapperIntegrity` and run `scripts/run-gate.sh G9` on the reference Mac with a clean build from `main`. Then run the demo of [../roadmap.md](../roadmap.md) §3.4 on a clean Mac with the #035 image bundle picked as a local bundle in onboarding, from the GUI only (C04-9). Check: the gate passes, and the evidence and the demo record are attached.

### Tests

- **T0**: `WrapperFileHashes` stability.
- **T2** (`Tests/IntegrationTests/`): the building-block test of steps 2–4 with the LocalProvider and with the Direct test service.
- **T3** (`Tests/AcceptanceTests/G9WrapperIntegrity`, `scripts/run-gate.sh G9`): the G9 assertions of [../test-strategy.md](../test-strategy.md) §5. Never retried.
- **Manual**: C04-9, the first public demo ([../test-strategy.md](../test-strategy.md) §8.5).

### Acceptance criteria

- [ ] V2 runs from the same `HelloUpdate.app` that ran V1.
- [ ] Application data is preserved: V2 logs `data HELLO`.
- [ ] The wrapper is unchanged: the SHA-256 of `APKRunLauncher`, `Info.plist`, `wrapper.json`, `AppIcon.icns`, and every file of `_CodeSignature/` is the same before and after, and the cdhash in `Wrappers/registry.json` is unchanged.
- [ ] No wrapper re-signing was needed because the APK changed.
- [ ] V2 was detected and staged in the background while V1 ran, and installed only after `HelloUpdate.app` quit, with no user action.
- [ ] `scripts/run-gate.sh G9` passes on the reference Mac with a clean build from `main`, and the evidence is attached.
- [ ] The first public demo (C04-9) runs on a clean Mac with no terminal.

### Notes

- **Record:** the G9 result in the gate issue. The product concept counts as validated only after this gate passes.
- If G9 fails, follow [../roadmap.md](../roadmap.md) §2, and record the failure in [update-system.md](../../02-design/update-system.md) §18 and [wrapper.md](../../02-design/wrapper.md) §18.
- **Pitfall:** the icon of V2 may differ from V1. That must add only the `.icon` refresh reason, never change the bundle (#055, FR-WRP-04). The HelloUpdate V1 and V2 icons are the same, so the gate is not affected, but check the refresh reason if they ever differ.
- **Pitfall:** Spotlight and `mds` can add extended attributes to the bundle. The hash list covers file contents only, and `codesign --verify --strict` decides about extended attributes.

---

## #075 `apkrun wrap` CLI

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #046, #048 |
| Requirements | FR-WRP-01, FR-WRP-02 (without `--portable`, which is #089), FR-CLI-01 (`wrap`) |
| Design | [wrapper.md](../../02-design/wrapper.md) §6.3, §6.4, §6.6, §12.1, §12.2, §15 #075; [cli.md](../../02-design/cli.md) §3.3, §3.4, §3.5, §4.2 (`install --wrap`), §4.4, §6; [update-system.md](../../02-design/update-system.md) §2, §11.3; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.10, §3.3, §4; [package-store.md](../../02-design/package-store.md) §4.7 |
| Modules / paths | `CLI/apkrun/Commands/Wrap.swift`, `CLI/apkrun/Commands/Wrapper.swift` (`verify`, `info`), `CLI/apkrun/Commands/Install.swift` (`--wrap`), `CLI/apkrun/Support/` (Prompt, OperationWaiter, ExitCodes), `CLI/apkrun/Tests/Golden/`, `Packages/RuntimeHost/` (`wrapper.json` initial values) |
| Risks / questions | None |

### Goal

`apkrun wrap app.apk` installs an APK and creates its Mac app in one command. The command follows the import/install table of [wrapper.md](../../02-design/wrapper.md) §12.2, accepts the documented alternate flag spellings, and works in scripts with `--yes` and `--json`.

### Scope

- The full `apkrun wrap <file.apk…|package>` syntax of [wrapper.md](../../02-design/wrapper.md) §12.2, except `--portable` (#089) and `--distribution` (#088).
- The import/install table (7 rows) for files, with the preview and the question for the "not installed" row.
- `--updates automatic|notify|manual`, `--provider <spec>`, and the aliases `--update auto`, `--updates auto`, and `--update-provider <type> --update-url <url>`. They apply only when this command installs the package, and as the initial values in `wrapper.json`. For an installed package they are rejected with a hint to use `apkrun update policy`.
- `--name`, `--icon`, `--window-size`, `--resizable` / `--no-resizable`, `--output`, `--replace`, `--open`, `--yes`, and `--json`.
- Client-side placement for `destinationNotAccessible` (§6.3), if #056 did not already add it.
- `apkrun install <file>… --wrap [--output <dir>]` ([cli.md](../../02-design/cli.md) §4.2).
- `apkrun wrapper verify <path> [--deep] [--json]` and `apkrun wrapper info <package> [--json]`.

Out of scope:

- `apkrun wrapper list`, `refresh`, and `remove` (#076). `apkrun wrapper approve` (#044).
- `--portable` (#089). `--distribution`, `--identity`, and `--notarize` (#088).
- Japanese CLI strings (#092).

### Deliverables

- `CLI/apkrun/Commands/Wrap.swift` completed, `Wrapper.swift` with `verify` and `info`, and `--wrap` in `Install.swift`.
- The exit-code mapping for every `wrapper` error code ([cli.md](../../02-design/cli.md) §3.3).
- Golden files for every row of the table and every error path in `CLI/apkrun/Tests/Golden/` ([../test-strategy.md](../test-strategy.md) §4.6).
- The T2 acceptance commands.

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #075, steps 1–2. Design step 1 is split into steps 1–4 here.

1. **Arguments and aliases (design step 1).** Parse the §12.2 syntax with swift-argument-parser. Map `--update auto` and `--updates auto` to `automatic`, and `--update-provider <type> --update-url <url>` to `--provider <type>:<url>` ([update-system.md](../../02-design/update-system.md) §11.3). `--provider` implies authority `apkrun` ([cli.md](../../02-design/cli.md) §4.2). Invalid combinations exit 64. Check: T0 argument tests pass for every alias and every invalid combination.
2. **The import/install table (design step 1).** For files, call `beginImport` and read the `ImportPreview` relation. Implement the rows: not installed without `--install` (print the preview, ask "Install and create the Mac app?", and without a TTY and without `--yes` fail with `packageNotInstalled` and the hint `--install`), not installed with `--install` (install as `apkrun install --yes`, then wrap), same version (wrap only), newer without `--install` (wrap the installed version and say that the file is newer), newer with `--install` (a manual update through UpdateCore, then wrap), and older (wrap the installed version and say that the older file was ignored). Refused relations (downgrade, other signer) exit 5 with the store's message. For a package argument, wrap the installed package. Check: the T0 golden tests pass for every row.
3. **Initial values (design step 1).** When the command installs, pass `--updates` and `--provider` to the install as the initial policy, and `--window-size` and `--resizable` as the initial package settings. Write the same values into `wrapper.json` (`updates`, `window`). The first-record precedence of [../../03-reference/configuration.md](../../03-reference/configuration.md) §3.3 applies: command flags, then `wrapper.json`, then `integrations.defaults.*`. For an installed package, `--updates` and `--provider` exit 64 with the hint `apkrun update policy`. Check: a T2 test shows that `--updates auto --update-provider direct --update-url <url>` gives authority `apkrun`, mode `automatic`, and a Direct provider.
4. **Placement, conflicts, and output (design step 1).** `--output` defaults to `~/Applications` ([wrapper.md](../../02-design/wrapper.md) §12.2). The CLI does not read `wrappers.defaultLocation` ([../../03-reference/configuration.md](../../03-reference/configuration.md) §2.10). The CLI checks that the directory exists. On `destinationNotAccessible`, the CLI moves the staged bundle itself and calls `placeStagedWrapper`. A second wrap without `--replace` exits with `wrapperExists`, and `--replace` refreshes the wrapper at that location (§6.4). `--open` opens the wrapper. Success prints the bundle path, and `--json` prints `WrapperInfo`. Check: the golden tests pass for `wrapperExists`, `nameConflict`, and `--replace`.
5. **`install --wrap`, `wrapper verify`, `wrapper info`.** `install --wrap` installs and then calls `createWrapper`. When the install succeeds and the wrapper fails, it exits 2 (partial) with both results ([cli.md](../../02-design/cli.md) §3.3). `wrapper verify` calls `verifyWrapper(url, deep)` and prints the state, the refresh reasons, the signer, and with `--deep --json` the file hash list of #049. `wrapper info` prints `wrapperInfo`. Check: the golden tests pass.
6. **Acceptance (design step 2).** Run the T2 commands below. Check: every acceptance criterion is checked.

### Tests

- **T0** (`CLI/apkrun/Tests/`, fake `RuntimeService`): golden output (human and JSON) for every table row, every alias, every error path, and the exit codes. The non-interactive rule: no TTY and no `--yes` gives `cli.confirmationRequired` for confirmations and `packageNotInstalled` with the hint for the first row ([cli.md](../../02-design/cli.md) §6.3).
- **T2** (`Tests/IntegrationTests/`, per-suite `--output` folders, [../test-strategy.md](../test-strategy.md) §3.9): `apkrun wrap HelloText.apk` with a scripted TTY answer, `--install --output ~/Applications`, the update flags, a second wrap, `--replace`, and `install --wrap`.

### Acceptance criteria

- [ ] `apkrun wrap app.apk` prints the preview, asks, and then installs the app and creates the Mac app in `~/Applications`.
- [ ] `apkrun wrap app.apk --install --updates auto --output ~/Applications` installs and wraps without asking.
- [ ] `--updates auto --update-provider direct --update-url <url>` gives a package with authority `apkrun`, mode `automatic`, and a Direct provider.
- [ ] A second `apkrun wrap` for the same package fails with `wrapperExists`, and `--replace` refreshes the wrapper.
- [ ] Each row of the [wrapper.md](../../02-design/wrapper.md) §12.2 table behaves as written, and an existing item that is not this package's wrapper is never replaced (`nameConflict`).
- [ ] `--updates` or `--provider` for an installed package is rejected with the hint `apkrun update policy`.
- [ ] `apkrun install <file> --wrap` installs and wraps, and exits 2 when only the install succeeded.
- [ ] Without a TTY and without `--yes`, no command waits for input ([cli.md](../../02-design/cli.md) §3.4).

### Notes

- The acceptance above uses `--updates auto`. It is a listed alias of `--updates automatic` ([wrapper.md](../../02-design/wrapper.md) §12.2, [update-system.md](../../02-design/update-system.md) §11.3), and the #075 acceptance in [wrapper.md](../../02-design/wrapper.md) §15 uses it, so the alias golden tests cover it.
- `apkrun wrapper …` is split over three tasks ([wrapper.md](../../02-design/wrapper.md) §15, [cli.md](../../02-design/cli.md) §6.2): #044 `approve`, #075 `verify` and `info`, #076 `list`, `refresh`, and `remove`.
- **Pitfall:** the CLI runs with the user's own file access, apkrund does not. Never resolve `--output` inside apkrund with the user's current directory. The CLI sends an absolute path ([cli.md](../../02-design/cli.md) §4.4).

---

## #076 Wrapper lifecycle and uninstall choices

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #048 |
| Requirements | FR-WRP-12 (Should, 0.4), FR-WRP-13 (Should, 0.5), FR-PKG-07 |
| Design | [wrapper.md](../../02-design/wrapper.md) §7.2, §8.5, §9, §12, §13, §14, §15 #076, §16; [package-store.md](../../02-design/package-store.md) §8, §11.1 (`repairPackage`), §15 #076, §16; [host-ui.md](../../02-design/host-ui.md) §5.3, §7.6, §7.7, §8, §9.7, "UI parts of other tasks"; [cli.md](../../02-design/cli.md) §4.2, §4.4; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §8; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7.2; [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §10.2, §10.5 |
| Modules / paths | `Packages/WrapperCore/` (`WrapperValidator`, `WrapperRefresher`, `WrapperRemover`, registry sweep), `Packages/APKStoreCore/` (`UninstallOptions`, keep-data records), `Guest/APKRunStore/` (`UninstallService` with `DELETE_KEEP_DATA`), `Packages/RuntimeHost/`, `Apps/APKRun/Features/Uninstall/`, `Apps/APKRun/Features/AppPage/MacAppSection.swift`, `Apps/APKRun/Features/Settings/` (Storage, Troubleshooting), `CLI/apkrun/Commands/{Wrapper, Uninstall}.swift`, `CLI/apkrun/Commands/` (`repair`) |
| Risks / questions | R-20 (the `Contents` swap, the Dock pin, and App Management; verified first), R-19 (the bundle ID stays across a refresh; the rest is #054), R-17 |

### Goal

APKRun keeps track of every Mac app it created. It notices when a Mac app is moved, renamed, deleted, or modified, and shows what the user can do. The user can change a Mac app's name and icon, or update its launcher, without breaking the Dock pin. Uninstalling an app offers to keep its data and to move the Mac app to the Trash.

### Scope

- Wrapper side:
  - `WrapperValidator` with all states (`valid`, `moved`, `missing`, `inaccessible`, `signatureInvalid`, `unknownPackage`), checks 1–6, and the refresh reasons `.launcher(version)`, `.icon`, and `.displayName` ([wrapper.md](../../02-design/wrapper.md) §9.1).
  - The validation triggers (apkrund start + 60 s, `listWrappers` with its 60 s cache, `launch`), `statusChanged` events, and the registry update for moved wrappers.
  - Refresh with the `Contents` swap (§9.3 steps 1–8), `wrapperRunning`, the `refreshing` state with `pendingCdhash`, and its crash recovery.
  - Launcher refresh reasons and the **Update All Mac Apps** action (§9.4).
  - Removal (§9.5): **Remove Mac App…**, **Remove from List**, and the Trash after uninstall.
  - **Re-register Mac Apps** for a missing registry (§7.2), and **Refresh Dock Icons** (§8.5).
  - The `wrappers.status` and `wrappers.launcher` health checks.
  - `apkrun wrapper list`, `refresh`, and `remove`.
- Store side: `UninstallOptions{keepData, trashWrappers, forget}`, `DELETE_KEEP_DATA`, `uninstalledKeepingData` records, and **Apps with kept data** in Settings → Storage with **Reinstall…** and **Delete Data** ([package-store.md](../../02-design/package-store.md) §8).
- UI: the uninstall dialog ([host-ui.md](../../02-design/host-ui.md) §8), the wrapper-state lines and actions in the app rows ([host-ui.md](../../02-design/host-ui.md) §5.3 priorities 6 and 7), the Mac App section view ([host-ui.md](../../02-design/host-ui.md) §7.6), and the Repair sheet ([host-ui.md](../../02-design/host-ui.md) §7.7).
- CLI: `apkrun uninstall --keep-data --keep-wrapper --forget` and `apkrun repair`.

Out of scope:

- Placing the Mac App section on the app page (#079) and the rows themselves (#077). This task provides the views and actions.
- Screen U and the "N Mac apps need to be updated" prompt after an APKRun update (#057). This task provides the refresh operation it calls.
- `apkrun doctor` and `doctor --deep` output (#059). This task registers the health checks and adds `apkrun wrapper verify --deep` (#075) as the M7 way to run the deep check.
- **Make Local Mac App** (#089).

### Deliverables

- `Packages/WrapperCore/Sources/WrapperCore/Lifecycle/`: `WrapperValidator.swift`, `WrapperRefresher.swift`, `WrapperRemover.swift`, `WrapperSweep.swift`, and the re-register scan.
- `listWrappers`, `refreshWrapper`, `refreshAllWrappers`, `removeWrapper`, and `rescanWrappers` on `.control`, and the `wrappers` events `refreshed`, `removed`, and `statusChanged`. Their DTOs in RuntimeAPI with round-trip tests ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §10.2, §10.5).
- `UninstallOptions`, the keep-data records, and `DELETE_KEEP_DATA` in the Store Agent.
- `Apps/APKRun/Features/Uninstall/UninstallDialog.swift`, `Apps/APKRun/Features/AppPage/MacAppSection.swift`, the Repair sheet, and **Apps with kept data** in `Apps/APKRun/Features/Settings/StoragePane.swift`.
- **Refresh Dock Icons** in Settings → Troubleshooting. If #059 has not created the pane, this task adds a minimal pane that #059 extends.
- CLI: `apkrun wrapper list|refresh|remove`, the `uninstall` flags, and `apkrun repair`.
- The R-20 verification record in [wrapper.md](../../02-design/wrapper.md) §9.3 and [../risks.md](../risks.md).

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #076, steps 1–3, and [package-store.md](../../02-design/package-store.md) §15 #076, steps 1–2. Wrapper design step 2 (verify R-20 first) is step 1 here. Wrapper design step 1 is split into steps 2–5.

1. **Verify R-20 (wrapper design step 2).** Before building the refresh, test on macOS 27 with a generated `HelloText.app` kept in the Dock: build a new `Contents` in `<parent>/.apkrun-<uuid>/`, sign it, and swap it with `renamex_np(…, RENAME_SWAP)` from apkrund. Record whether App Management blocks the swap, whether the Dock pin still opens the app, whether a rename afterwards keeps the pin, and whether Finder aliases still resolve. If the swap is blocked for apkrund, the refresh runs in APKRun.app with the same steps, and `refreshBlocked` explains the System Settings switch. If the pin breaks, the fallback replaces the whole bundle and says that a Dock pin may need to be recreated. Check: the result is recorded in [wrapper.md](../../02-design/wrapper.md) §9.3, and R-20 is `closed` or `realized` in [../risks.md](../risks.md).
2. **Validator (wrapper design step 1).** `WrapperValidator` runs the checks of §9.1 in order: the bookmark (`.withoutUI`, `.withoutMounting`, then `NSWorkspace.urlsForApplications(withBundleIdentifier:)` with the registered cdhash; inside a `.Trash` folder is `missing`), read access, the bundle ID and cdhash (cached by inode, size, and mtime), deep only `SecStaticCodeCheckValidity`, the store record, and the refresh reasons. A new path updates the registry path and bookmark and reports `moved(newURL)` once. The sweep runs at apkrund start + 60 s at low priority. `listWrappers` caches for 60 s. A state change posts `statusChanged`. Add the `wrappers.status` and `wrappers.launcher` health checks. Check: the T1 validator tests pass for fixture bundles of every state.
3. **Refresh (wrapper design step 1).** `refreshWrapper(packageID, WrapperRefresh{displayName?, icon?, launcher})` runs §9.3 steps 1–8 (or the fallback of step 1): a running wrapper gives `wrapperRunning`, and the UI asks "Quit ‹App› to update its Mac app?" and on OK repeats the refresh with `closeRunningApp = true`. apkrund then sends `windowRequest(.close)` to the session and waits up to 30 s for it to end ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §10.5). The registry holds `refreshing` with `pendingCdhash`, and both cdhashes are accepted until step 7. A name change renames the bundle with the §6.4 rules. Custom icons are copied to `Wrappers/icons/<bundleId>.png`. `recover()` completes or rolls back a `refreshing` entry. Emit `WRAPPER_REFRESH_END`. Check: the T1 `refreshing` recovery tests pass for a crash before and after step 5.
4. **Launcher refresh and bulk actions (wrapper design step 1).** Wrappers with an older `APKRunLauncherVersion` get `.launcher(version)` (§9.4). **Update All Mac Apps** and `apkrun wrapper refresh --all` call `refreshAllWrappers(RefreshAllWrappersRequest{scope, launcherOnly})`, a long operation (`wrapperRefreshAll`). With `scope = .needingRefresh` it refreshes every wrapper with a reason, with `.all` every wrapper. It skips running wrappers and returns `WrapperBatchResult{refreshed, skippedRunning, failed}`. One wrapper's failure goes into `failed` and does not stop the others. Add **Refresh Dock Icons** (restarts the Dock after a confirmation, never automatically, §8.5). Add the **Re-register Mac Apps** operation `rescanWrappers(RescanWrappersRequest{register})`: scan `~/Applications` and `/Applications` for bundles with `APKRunPackageID` and validate each one statically. With `register = false` it only returns the candidates, so the client can show its one confirmation. With `register = true` it registers the bundles that pass, with `approval: generated` semantics, and posts `wrappers.created` for each (§7.2). The home-screen banner that offers it is #077. Check: a T1 test with a registry deleted by the test lists two fixture wrappers with `register = false` and re-registers them with `register = true`, and a T1 test of `refreshAllWrappers` with one running wrapper lists it in `skippedRunning`.
5. **Removal and CLI (wrapper design step 1).** `removeWrapper(packageID, {trash})`: with `trash`, `FileManager.trashItem` and registry removal. Without it, registry removal only (§9.5). Wrappers are never deleted, only moved to the Trash. Add `apkrun wrapper list [--json]`, `apkrun wrapper refresh (<package>… | --all) [--name] [--icon <file> | --android-icon] [--launcher-only]`, and `apkrun wrapper remove <package> [--trash] [--yes]`. Check: the T0 golden tests pass.
6. **Store side (store design step 1).** Add `UninstallOptions{keepData, trashWrappers, forget}` to the uninstall transaction of [package-store.md](../../02-design/package-store.md) §8. The Store Agent's `UninstallService` passes `DELETE_KEEP_DATA` when `keep_data` is set. Keep-data leaves `metadata.json` (state `uninstalledKeepingData`) and `settings.json` and deletes the artifact slots. After the commit, WrapperCore trashes the wrapper when chosen, otherwise the wrapper becomes `unknownPackage`. `forget` removes the record without Android. Reinstalling the same package and signer restores the data (`uninstalledWithData` relation). Add `apkrun uninstall <package> [--keep-data] [--keep-wrapper] [--forget] [--yes]` and `apkrun repair <package> [--yes]` (`repairPackage`). Check: the T1 store tests pass for keep and not keep.
7. **UI.** Build the uninstall dialog of [host-ui.md](../../02-design/host-ui.md) §8: "Keep app data" (off), "Also move the Mac app to the Trash" (on, shown only when a wrapper exists), "‹App› is open and will be closed." for an open app, and **Remove from APKRun** when Android cannot start. Build `MacAppSection` (status, name, icon, location with **Show in Finder**, **Update Mac App** with the reasons, **Create Mac App**, **Remove Mac App…**). Provide the state lines and actions of §9.1 for the rows (**Create Mac App**, **Remove from List**, **Create It Again**, **Move Mac App to Trash**, **Update Mac App**). Build the Repair sheet ([host-ui.md](../../02-design/host-ui.md) §7.7) and **Apps with kept data** in Settings → Storage ([host-ui.md](../../02-design/host-ui.md) §9.7). Check: the T1 XCUITest for the uninstall choices passes.
8. **Acceptance (wrapper design step 3, store design step 2).** Run the T2 tests and the manual checks C04-5 and C04-8. Check: every acceptance criterion is checked.

### Tests

- **T0**: `apkrun wrapper list|refresh|remove`, `uninstall`, and `repair` golden output and exit codes. Round trips of the operation DTOs.
- **T1** (`Packages/WrapperCore/Tests/`): `WrapperValidator` states with fixture bundles (moved, in the Trash, unreadable, edited `wrapper.json`, re-signed, unknown package, older launcher). `refreshing` recovery. Re-register scan (`rescanWrappers` with `register` false and true). `refreshAllWrappers` with a running and a failing wrapper.
- **T1** (`Packages/APKStoreCore/Tests/`, fake channel): uninstall with and without keep data, and `forget`.
- **T1** (XCUITest, embedded runtime fake): the uninstall choices ([host-ui.md](../../02-design/host-ui.md) §15).
- **T2** (`Tests/IntegrationTests/`, custom image): keep-data uninstall and reinstall restores the data. A full uninstall removes `Packages/<id>/` and trashes the wrapper. Move, rename, Trash, and restore give the expected states. A refresh with a new name and icon keeps the bundle ID and records the new cdhash.
- **Manual**: C04-5 (the Dock pin survives a refresh, R-20) and C04-8 (the uninstall sheet matches [host-ui.md](../../02-design/host-ui.md) §8) ([../test-strategy.md](../test-strategy.md) §8.5).

### Acceptance criteria

- [ ] Moving a wrapper to another folder and renaming it is followed: the state is `moved`, then `valid` (FR-WRP-12).
- [ ] Moving a wrapper to the Trash gives `missing`, and putting it back gives `valid` (FR-WRP-12).
- [ ] Editing `wrapper.json` inside a wrapper gives `signatureInvalid` in `apkrun wrapper verify --deep` (the design says `doctor --deep`, which comes with #059).
- [ ] Changing the name and the icon on the app page regenerates the wrapper with the same bundle ID. The Dock pin still works, and the registry has the new cdhash (FR-WRP-13, C04-5).
- [ ] Uninstalling with "Also move the Mac app to the Trash" leaves the wrapper in the Trash. Without it, the wrapper stays and shows `unknownPackage`.
- [ ] (store) Uninstalling with "Keep app data" and reinstalling the same APK brings back the data written before (FR-PKG-07).
- [ ] (store) Uninstalling without keeping data removes `Packages/<id>/`.
- [ ] A running wrapper is not refreshed until the user agreed to quit it (`wrapperRunning`). **Update All Mac Apps** skips running wrappers and lists them.
- [ ] After the registry is deleted, **Re-register Mac Apps** finds the generated wrappers in `~/Applications` and `/Applications` and registers them after one confirmation.
- [ ] The uninstall dialog matches [host-ui.md](../../02-design/host-ui.md) §8: the defaults, the Mac app choice only when a wrapper exists, **Remove from APKRun** when Android cannot start, and the note for an open app (C04-8).
- [ ] The R-20 result is recorded, and the refresh uses the verified method or its fallback.

### Notes

- **Record:** the R-20 result in [wrapper.md](../../02-design/wrapper.md) §9.3 and [../risks.md](../risks.md). The R-19 part: a refresh keeps the bundle ID, so the notification settings stay. R-19 stays open for #054. The R-17 part for App Management during a refresh.
- FR-WRP-13 is a `Should` for 0.5 in [../../00-product/requirements.md](../../00-product/requirements.md), but the design builds it here with the refresh. Nothing blocks v0.4 if the name and icon change moves to M9 with a reason.
- The design gives the Mac App section to both this task ("UI parts of other tasks") and #079 ([wrapper.md](../../02-design/wrapper.md) §15 "#077, #078, #079 wrapper parts"). The split: this task builds the view and its actions, and #079 places it on the app page.
- **Pitfall:** the bookmark must be resolved without UI and without mounting volumes. A validation pass must never make a disk spin up or show a dialog.
- **Pitfall:** `renamex_np` with `RENAME_SWAP` works only on the same volume. Always build the new `Contents` inside the bundle's parent directory.

---

## #077 Home and store UI

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #048 |
| Requirements | FR-UI-01, FR-UI-04 |
| Design | [host-ui.md](../../02-design/host-ui.md) §1, §2, §3.1, §5, §13, §14 #077, §15; [wrapper.md](../../02-design/wrapper.md) §9.1, §12.1, §15 "#077, #078, #079 wrapper parts"; [runtime-daemon.md](../../02-design/runtime-daemon.md) §7.2, §8.3; [update-system.md](../../02-design/update-system.md) §7.3, §7.4, §8.3, §11; [package-store.md](../../02-design/package-store.md) §9.3, §11 |
| Modules / paths | `Apps/APKRun/Models/` (`PackageListModel`, `PackageDetailModel`, `UpdatesModel`, `SessionsModel`, `OperationCenter`, `WrapperListModel`), `Apps/APKRun/Features/Home/`, `Apps/APKRun/Components/` (`AppIconView`, `StatusBadge`, `ErrorView`, `ProgressRow`, `DropZone`), `Apps/APKRun/APKRunApp.swift` (URL routing), `Packages/WrapperCore/` (quick `listWrappers`) |
| Risks / questions | OQ-08 (must be settled before this task starts; the default is no catalog) |

### Goal

APKRun.app gets its main window: a list of the user's Android apps with their Android version, update mode, and status, a runtime header, an Updates list with **Update Now**, the other Android apps, and a drop zone. The window stays usable while Android is stopped, and `apkrun://` links open the right place.

### Scope

- The models of [host-ui.md](../../02-design/host-ui.md) §2.2 with event subscriptions, reload on reconnect, and the banner "APKRun's background service isn't running" with **Restart Service** and **Troubleshooting…**. `OperationCenter` with the toolbar activity indicator.
- The main window of §5: the sidebar (**Apps**, **Updates** with its badge, **Other Android Apps**), the runtime header (§5.2, the M7 rows), the app rows with the priority table of §5.3, the context menu, **Open** through `launch(packageID)`, **Other Android Apps** with **Open** and **Manage with APKRun**, the empty state, the drop zone, search, sort, and the toolbar.
- The `apkrun://` routes of §3.1 with package ID validation.
- A quick `listWrappers` (§9.1 checks 1–3 and 5, cached for 60 s) and a `WrapperListModel` that reloads when the window becomes key and every 60 s while it is visible.
- The home-screen banner for a missing registry with **Re-register Mac Apps** (the operation is #076).

Out of scope:

- The add sheet behind drops and **Add App…** (#078). Until #078, drops open a sheet that shows the `ImportPreview` summary only.
- The app page and its sections (#079). **Settings** in a row opens the app page shell.
- Wrapper validation states beyond checks 1–3 and 5, refresh reasons, and the row actions for them (#076).
- The runtime header rows for #057, #058, and #087 ([runtime-maintenance.md](../../02-design/runtime-maintenance.md)), and the "Needs attention" health line (#059).
- A catalog or search of apps outside the Mac (OQ-08 default).
- Japanese strings and the accessibility audit (#092). Accessibility labels are added here.

### Deliverables

- The models in `Apps/APKRun/Models/` and their T0 tests with a fake `RuntimeService`.
- `Apps/APKRun/Features/Home/` (sidebar, header, rows, Updates list, Other Android Apps, empty state).
- The shared components in `Apps/APKRun/Components/`.
- URL routing in `APKRunApp.swift`.
- The quick `listWrappers` operation in apkrund.

### Implementation steps

The design steps are [host-ui.md](../../02-design/host-ui.md) §14 #077, steps 1–4. Design step 1 is split into steps 1–2 here.

1. **Wrapper list (design step 1).** Add `listWrappers()` → `[WrapperSummary]` on `.control` with the quick checks of [wrapper.md](../../02-design/wrapper.md) §9.1 (1–3 and 5) and the 60 s cache. #076 replaces the check body with the full validator and adds `statusChanged`. Until then, `WrapperListModel` reloads when the main window becomes key and every 60 s. Check: a T2 test trashes a wrapper, and `listWrappers` reports `missing` within 60 s.
2. **Models (design step 1).** Implement `PackageListModel`, `PackageDetailModel`, `UpdatesModel`, `SessionsModel`, `WrapperListModel`, and `OperationCenter` as `@Observable` main-actor models fed by `RuntimeClient` requests and topics (`packages`, `updates`, `sessions`, `wrappers`). On a reconnect every model reloads. While apkrund is unreachable, show the banner with **Restart Service** (re-registers the agent) and **Troubleshooting…**. Views never call XPC. Check: the T0 reconnection tests pass.
3. **Main window (design step 2).** Build the `NavigationSplitView`, the runtime header for the M7 states (§5.2), and the rows (icon from `packageIcon` at 64 px or the host preview, display name, "Android version ‹versionName›", update mode, status line). The status line picks the first matching row of §5.3: 1 broken (**Repair…**), 2 installing and similar with progress, 3 update failed or rolled back (**Details**), 4 waiting (**Update Now**), 5 available (**Update Now**), 6 wrapper state not `valid`, 7 refresh reasons (**Update Mac App**), 8 otherwise (**Open**, **Settings**). Add the running dot, the context menu (**Open**, **Show Mac App in Finder**, **Check for Updates**, **Settings…**, **Uninstall…**), **Open** through `launch(packageID)`, **Other Android Apps** (**Open**, **Manage with APKRun** through `adoptPackage`), the empty state, drops ("APKRun can add .apk, .apks, .xapk, and .apkm files." for other files), search, sort (Name, Recently Used, Recently Updated), and ⌘O. The buttons of rows 1, 6, and 7 and **Uninstall…** call the #076 actions. Whichever of #076 and #077 merges second connects them. Check: the T0 status-priority tests pass.
4. **URL routing (design step 3).** Handle `apkrun://home`, `package/<id>`, `package/<id>/<section>`, `updates`, `settings/<pane>`, `setup`, and `report[?package=<id>]` (§3.1). URLs only navigate. An invalid or unknown package ID shows home with "‹id› isn't installed in APKRun.", and unknown routes, including `report` until #060, open home. Check: the T0 routing tests pass.
5. **Acceptance (design step 4).** Run the T2 tests below. Check: every acceptance criterion is checked.

### Tests

- **T0** (fake `RuntimeService`): the status priority table (every row, and ties), reconnection reload, URL routing and package ID validation ([host-ui.md](../../02-design/host-ui.md) §15).
- **T2** (`Tests/IntegrationTests/`, custom image): with HelloText and HelloGL installed and HelloCompose installed with `adb install` in developer mode (unmanaged), the rows show the right versions and states, and HelloCompose is under **Other Android Apps**. A staged update of HelloUpdate shows "Update available", and **Update Now** installs it. A wrapper moved to the Trash shows "Mac app not found" within 60 s. With Android stopped, the window lists the apps and **Open** starts Android.

### Acceptance criteria

- [ ] The home screen shows the drop area, the installed apps with their update mode and status, and the runtime status (FR-UI-01).
- [ ] Each row shows "Android version ‹versionName›" and the update status, and **Update Now** installs a staged update of HelloUpdate (FR-UI-04).
- [ ] With HelloText, HelloGL, and the unmanaged HelloCompose installed, the rows show the right versions and states, and HelloCompose appears under **Other Android Apps** with **Manage with APKRun**.
- [ ] A wrapper moved to the Trash changes its row to "Mac app not found" within 60 s.
- [ ] The window works with Android stopped: the list loads, and **Open** starts Android and the app.
- [ ] When apkrund is unreachable, the banner with **Restart Service** appears, and the models reload after the reconnect.
- [ ] `apkrun://` URLs only navigate, and invalid package IDs are rejected.

### Notes

- **Before starting:** OQ-08 must be settled. The default is no app catalog, so the "store UI" is the list of the user's own apps and their updates.
- The design makes #077 depend only on #048, but its rows need `listWrappers`, the validator states, and the uninstall and repair actions, which the design places in #076. This task adds a quick `listWrappers` so it does not wait for #076. The README dependency is kept.
- The user-facing terms follow [host-ui.md](../../02-design/host-ui.md) §13.1: "Mac app", "Android", "app", "update source".
- **Pitfall:** the home screen must never start Android by itself. Only **Open**, **Start Android**, and updates that the user starts may boot it.

---

## #078 Add flow

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #077, #073 |
| Requirements | FR-UI-02, FR-UI-06 (Should) |
| Design | [host-ui.md](../../02-design/host-ui.md) §3.2, §5.5, §6, §9.1, §14 #078, §15; [package-store.md](../../02-design/package-store.md) §4.1, §4.2, §4.7, §6.2; [update-system.md](../../02-design/update-system.md) §2, §4, §4.7, §7.3; [wrapper.md](../../02-design/wrapper.md) §4.3, §6.3, §6.6; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.10, §3.3 |
| Modules / paths | `Apps/APKRun/Features/AddFlow/` (sheet, stages, relation views, provider picker), `Apps/APKRun/APKRunApp.swift` (document handling), the APKRun.app Info.plist (`CFBundleDocumentTypes`, `UTImportedTypeDeclarations`, `UTExportedTypeDeclarations`), `Apps/APKRun/Features/Settings/` (General: default location), `Packages/RuntimeAPI/` (`InstallOptions.createWrapper`), `Packages/RuntimeHost/` |
| Risks / questions | OQ-22 (the **Other…** location note, from the #056 result) |

### Goal

Adding an Android app takes one drag or one double-click. APKRun reads the file, shows the app's name, icon, version, signer, and update choices, and installs it with a Mac app in `~/Applications` when the user clicks **Install**. Every relation to an installed app gets the right sheet, and refused files say why.

### Scope

- The document types of [host-ui.md](../../02-design/host-ui.md) §3.2 and the entry points: drops on the drop zone, the list, and the Dock icon, **Add App…** (⌘O), double-click, **Open With**, and `open -a APKRun file.apk`. Several files form one import when they are a split set, otherwise one add flow each, in order.
- The add sheet with its four stages (Reading, Review, Installing, Done), passing open file handles, never paths.
- The review content of §6.1 and the relation table (`newPackage`, `sameAsInstalled`, `reinstallSameVersion`, `update(from:)`, `downgrade(from:)`, `otherSigner`, `uninstalledWithData(version)`).
- The update choices: the three modes, the provider picker, and the provider suggestion hook ([update-system.md](../../02-design/update-system.md) §4.7).
- The Create Mac app options: toggle (on), name field, location pop-up (**Applications (for me)**, **Applications (all users)** for admin users, **Other…**), and the icon preview ([wrapper.md](../../02-design/wrapper.md) §6.6).
- The Installing and Done stages with the progress texts, the install failure, and the wrapper failure after an install, including **Choose Another Location…** for `destinationNotAccessible`.
- Reading `wrappers.defaultLocation` for the location pop-up.

Out of scope:

- The control for `wrappers.defaultLocation` in Settings → General. #079 builds the Settings window ([host-ui.md](../../02-design/host-ui.md) §14 #079).
- The F-Droid suggestion itself. It needs the cached F-Droid index (#051). Until then the hook returns no suggestion for F-Droid. Direct suggestions come from a portable wrapper or an install spec.
- The compatibility database label (#090). The row shows nothing for apps without an entry.
- `.aab` and `.xapk` with OBB, which the store refuses ([package-store.md](../../02-design/package-store.md) §4.2).

### Deliverables

- `Apps/APKRun/Features/AddFlow/` with the sheet, the stage views, one view per relation, and the provider picker (shared with #079).
- The document type declarations and the document open handling.
- `InstallOptions.createWrapper` (a `WrapperRequest`), so that `installImported` runs the wrapper generation after the install commits, in the same long operation.
- T0 model tests, the T1 XCUITest per relation, and the T2 acceptance tests.

### Implementation steps

The design steps are [host-ui.md](../../02-design/host-ui.md) §14 #078, steps 1–3. Design step 1 is split into steps 1–3 here.

1. **Document types and entry points (design step 1).** Declare `.apk` as `com.android.package-archive` (imported, conforms to `public.zip-archive` and `public.data`, Viewer, `Default`) and `io.apkrun.apks`, `io.apkrun.xapk`, and `io.apkrun.apkm` (exported, Viewer, `Owner`). Route document opens, drops, and **Add App…** into one `AddFlowModel` that calls `beginImport` with file handles. Unsupported files are refused with "APKRun can add .apk, .apks, .xapk, and .apkm files." Check: double-clicking `HelloText.apk` in Finder opens the sheet.
2. **Review stage and relations (design step 1).** Show the §6.1 elements from `ImportPreview`: name and icon (host preview), package and `versionName (versionCode)`, the signer digest with the ⓘ popover, warnings as yellow rows (blocking problems replace **Install** with the reason), and **Details** (files, sizes, excluded splits, permissions). Implement each relation row of §6.1. `update(from:)` is gentle: when the app is open, "‹App› will update when you quit it" with **Quit and Update**. Refused relations show the store's message with **Done** only. Check: the T0 relation tests and the T1 XCUITest pass.
3. **Installing and Done (design step 1).** **Install** calls `installImported(ticket, options)` with `InstallOptions.createWrapper` when the toggle is on. RuntimeHost runs the wrapper generation after the store commits. The sheet shows "Starting Android…" (when the runtime was stopped), "Installing in Android…", and "Creating Mac app…". An install failure shows the catalog message, and **Try Again** keeps the ticket. A wrapper failure after a successful install shows "‹App› was installed, but the Mac app couldn't be created: ‹reason›" with **Try Again**, and `destinationNotAccessible` offers **Choose Another Location…** (a Save panel) and then `placeStagedWrapper`. The sheet can be closed while installing, and the work continues in `OperationCenter`. Done shows **Open ‹App›**, **Show in Finder**, and **Done**. Check: a T2 test with the toggle on produces `~/Applications/HelloText.app`.
4. **Update choices and Mac app options (design step 2).** Without an update source, only **Manual** is enabled, with "Choose an update source to turn on automatic updates" and **Choose…** (the provider picker for Local, Direct, F-Droid, and GitHub specs of [update-system.md](../../02-design/update-system.md) §4). A detected provider is shown as a suggestion that is off until the user turns it on ([update-system.md](../../02-design/update-system.md) §4.7). The Mac app name field starts with the host label, and the file name follows [wrapper.md](../../02-design/wrapper.md) §4.3. The location pop-up starts at `wrappers.defaultLocation` (`ask` selects nothing and requires a choice). If #056 recorded that the Apps view does not list other folders, **Other…** says so (OQ-22). Check: the T0 model tests for the options pass.
5. **Acceptance (design step 3).** Run the T2 tests below. Check: every acceptance criterion is checked.

### Tests

- **T0** (fake `RuntimeService`): relation handling, the enabled update modes with and without a source, the name and location defaults ([host-ui.md](../../02-design/host-ui.md) §15).
- **T1** (XCUITest, embedded runtime fake): the add flow for each relation, including the refusals and the wrapper failure with **Choose Another Location…**.
- **T2** (`Tests/IntegrationTests/`, custom image): drag `HelloText.apk` onto APKRun, check the review content, **Install** with "Create Mac app", and open `~/Applications/HelloText.app`. Double-click an `.apk` in Finder. Install the `.xapk` and `.apks` container fixtures ([../test-strategy.md](../test-strategy.md) §4.3) as split sets. HelloUpdate V1 dropped while V2 is installed shows the `downgrade(from:)` refusal. HelloUpdate V2-other-signer dropped while V1 is installed shows the `otherSigner` refusal. The OddName fixture gets a sanitized Mac app name.

### Acceptance criteria

- [ ] (FR-UI-02) Dragging `HelloText.apk` onto APKRun shows its name, package, icon, and update options, and **Install** with "Create Mac app" produces `~/Applications/HelloText.app`, which opens the app.
- [ ] (FR-UI-06) Double-clicking an `.apk` in Finder opens the same sheet.
- [ ] An `.xapk` and an `.apks` fixture install as split sets.
- [ ] HelloUpdate V1 over V2 shows the `downgrade(from:)` refusal, and HelloUpdate V2-other-signer over V1 shows the `otherSigner` refusal. Both offer only **Done**.
- [ ] OddName (a label with `/`, `:`, and an emoji ZWJ sequence) gets a sanitized Mac app name ([wrapper.md](../../02-design/wrapper.md) §4.3).
- [ ] Every relation of [host-ui.md](../../02-design/host-ui.md) §6.1 shows its sheet and button.
- [ ] A wrapper failure after a successful install keeps the app installed and offers **Try Again**.
- [ ] Without an update source only **Manual** is enabled, and a suggestion is never turned on by default.

### Notes

- The add-flow and settings requirements are tracked under #078 and #079 in this milestone.
- **Pitfall:** the GUI passes file handles, never paths ([package-store.md](../../02-design/package-store.md) §4.1). A security-scoped URL from a drop must be opened in the app process before the handle is sent.

---

## #079 Per-app settings

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #077, #039, #074 |
| Requirements | FR-UI-03, FR-UPD-09, FR-DSP-06 (Should) |
| Design | [host-ui.md](../../02-design/host-ui.md) §7, §9.1–§9.4, §9.7, §9.9, §14 #079, §15; [../../03-reference/configuration.md](../../03-reference/configuration.md) §3; [../../03-reference/package-metadata-json.md](../../03-reference/package-metadata-json.md) §3; [display-and-windowing.md](../../02-design/display-and-windowing.md) §6, §7.6, §7.7, §8; [update-system.md](../../02-design/update-system.md) §2.1, §2.3, §3, §8, §9; [desktop-integration.md](../../02-design/desktop-integration.md) §2; [cli.md](../../02-design/cli.md) §2, §4.2; [wrapper.md](../../02-design/wrapper.md) §6.6; ADR-0009 [0009-thin-immutable-wrappers.md](../../01-architecture/decisions/0009-thin-immutable-wrappers.md) |
| Modules / paths | `Apps/APKRun/Features/AppPage/` (one file per section), `Apps/APKRun/Features/Settings/` (the panes of the `Settings` scene that #047 created), `Packages/WindowingCore/` (`alwaysOnTop`), `Apps/APKRunLauncher/` (`windowPrefsChanged`), `Packages/APKStoreCore/` (`updatePackageSettings`), `CLI/apkrun/Commands/Settings.swift`, `CLI/apkrun/Tests/Golden/` |
| Risks / questions | OQ-09 (always on top in full screen, settled here; default no effect), OQ-35 (status bar on display 0 in compatibility mode, settled here; default visible) |

### Goal

Every app has a page in APKRun.app where the user changes its name and icon, window behavior, input, integrations, updates, Mac app, and storage. Changes are saved at once in the package store, never in the wrapper, and each one takes effect when the design says it does. `apkrun settings` offers the same keys from the terminal. APKRun.app's Settings window also gets its app-wide panes: the default location for new Mac apps, the global update settings, the runtime settings, the global integration switches and defaults, the disk-use summary, and the advanced items.

### Scope

- The app page header (icon, name, version, running state, **Open**, **Update Now**, and the **…** menu) and the sections §7.1–§7.7 of [host-ui.md](../../02-design/host-ui.md).
- Immediate writes with `updatePackageSettings(id, patch)`, "Applies the next time ‹App› opens." for next-session keys, and "Recommended for this app" with **Reset**.
- `window.alwaysOnTop` in the launcher: `NSWindow.level = .floating`, live through `windowPrefsChanged`, with no effect in full screen (OQ-09).
- `window.mode` with the Standard and Compatibility explanation, and the status bar decision for compatibility mode (OQ-35).
- The Updates section with the mode, the update source, **Check Now**, history, rollback, the two update switches, and **Updated by** ([host-ui.md](../../02-design/host-ui.md) §7.5).
- The panes of the `Settings` scene ([host-ui.md](../../02-design/host-ui.md) §2.1, §9), which #047 created with the Privacy pane. This task sets the tab order and adds:
  - General with **Default location for new Mac apps** (§9.1), and Updates (§9.3);
  - Runtime (§9.2), without **Sound output** (#083);
  - the global switches `integrations.enabled.*` and the defaults for new apps `integrations.defaults.*` in Privacy (§9.4). The denied list is #047's, and the microphone permission row is #084's;
  - the disk-use summary at the top of Storage (§9.7). **Apps with kept data** is #076's, and the Android system rows are #058's;
  - Advanced (§9.9): **Developer mode** with its confirmation, **Install Command-Line Tool…**, and **Reveal Logs in Finder**.
  Other tasks add their panes and rows ([host-ui.md](../../02-design/host-ui.md) §14).
- Placing the Mac App section built by #076, and the Storage section with **Uninstall…** and **Repair…**.
- `apkrun settings <package> list [--json] | get <key> | set <key> <value> | reset (<key> | --all)`.

Out of scope:

- The integration features themselves (#053 is done; notifications #054, links #081, files and shared folders #082, microphone #084). Their controls write the keys here and show `integrationStatus`.
- The compatibility database values behind "Recommended for this app" (#090). The label and **Reset** work from the resolver's source field.
- The other panes and rows of the Settings window: the APKRun and Android system update rows of General (#057, #087), **Sound output** (#083), the microphone permission row (#084), Files (#082), Language & Region (#085), the rest of Storage (#076, #058), and Troubleshooting (#059, #060, #076).
- Name and icon refresh mechanics (#076). This task calls them.

### Deliverables

- `Apps/APKRun/Features/AppPage/`: `AppPageView.swift`, `GeneralSection.swift`, `WindowSection.swift`, `InputSection.swift`, `IntegrationsSection.swift`, `UpdatesSection.swift`, `StorageSection.swift`, with `MacAppSection` from #076.
- `Apps/APKRun/Features/Settings/`: `GeneralPane.swift`, `UpdatesPane.swift`, `RuntimePane.swift`, `AdvancedPane.swift`, the global switches and defaults in `PrivacyPane.swift`, and the disk-use summary in `StoragePane.swift` (which #076 creates, or this task when it merges first). The tab order in `SettingsScene.swift`.
- `alwaysOnTop` handling in WindowingCore and the launcher.
- `CLI/apkrun/Commands/Settings.swift` with golden files.
- The OQ-09 and OQ-35 decisions recorded in [../open-questions.md](../open-questions.md) and the design.

### Implementation steps

The design steps are [host-ui.md](../../02-design/host-ui.md) §14 #079, steps 1–4. Design step 1 is split into steps 1–3 here, the CLI of [cli.md](../../02-design/cli.md) §6.2 is step 5, and design step 3 is step 6.

1. **App page and writes (design step 1).** Build the header and the section list, reachable from the row's **Settings** button and from `apkrun://package/<id>/<section>`. Every control writes at once with `updatePackageSettings(id, patch)`. A next-session key shows "Applies the next time ‹App› opens." while the app runs. A value whose resolver source is a recommendation shows "Recommended for this app", and **Reset** sends `null` for the key ([../../03-reference/configuration.md](../../03-reference/configuration.md) §3.2). Check: the T0 settings-patch tests pass for every control.
2. **General, Window, Input, Integrations (design step 1).** General (§7.1): name and icon (**Android Icon** or **Choose…**), which offer **Update Mac App** (#076 refresh), and the package facts, signer, and size. Window (§7.2): default size with **Use Current Size**, resizable, always on top, zoom, close behavior, and window mode (FR-DSP-06). Input (§7.3): the five input keys. Integrations (§7.4): each control with its `integrationStatus` line, the notification hint for `closeBehavior = stop`, and the microphone restart question. Check: each control writes the documented key and value.
3. **Updates, Mac App, Storage (design step 1).** Updates (§7.5): the mode with the authority rules through `setUpdatePolicy`, the update source picker from #078, **Check Now**, the last check, the history, **Roll Back to ‹version›…** (`rollbackPackage`), `update.autoRollback`, `update.healthCheckLaunch` (FR-UPD-09), and **Updated by** through `setUpdateAuthority` ([update-system.md](../../02-design/update-system.md) §2.1): **Another app store in Android** asks first, then sets `external`; **APKRun** sets `apkrun` when the record keeps a provider, else `manual`; a `googlePlay` package shows it read-only. Mac App (§7.6): place `MacAppSection`. Storage (§7.7): sizes, **Uninstall…**, and **Repair…** for `broken` packages. Check: the Updates section shows the HelloUpdate history.
4. **Always on top and window mode (design step 2).** In WindowingCore, apply `window.alwaysOnTop` as `NSWindow.level = .floating` and update it live when the launcher receives `windowPrefsChanged` ([display-and-windowing.md](../../02-design/display-and-windowing.md) §7.7). In full screen it has no effect (OQ-09 default). Settle OQ-09 and OQ-35 with the defaults unless testing shows a problem: the status bar stays visible on display 0 in compatibility mode. Check: a T2 test turns the setting on while HelloText is open, and the window level changes without a restart.
5. **`apkrun settings`.** Implement `list [--json]` (every key with its value and whether it is the default), `get`, `set` (values parsed by the key's type: bool `true`/`false`/`on`/`off`, enums by name, numbers; invalid values exit 64 with the allowed values; "applies the next time ‹App› opens" where true), and `reset (<key> | --all)`. Unknown keys exit 4. Check: every key of [../../03-reference/package-metadata-json.md](../../03-reference/package-metadata-json.md) §3 round-trips through `set` and `get`.
6. **Settings window (design step 3).** Set the tab order of the `Settings` scene that #047 created (General, Runtime, Updates, Privacy, Files, Language & Region, Storage, Troubleshooting, Advanced, as in [host-ui.md](../../02-design/host-ui.md) §9). Show a pane only when it has content. Each control writes its key with the configuration operations ([../../03-reference/configuration.md](../../03-reference/configuration.md) §1.4).
   - General: **Default location for new Mac apps** (`wrappers.defaultLocation`).
   - Updates ([update-system.md](../../02-design/update-system.md) §3): `updates.checkIntervalHours`, `updates.downloadOnExpensiveNetwork`, `updates.startRuntimeToInstall`, `updates.notifyInstalled`, and the list of configured update sources.
   - Runtime (§9.2): `runtime.startPolicy`, `runtime.idleSuspendMinutes`, `runtime.idleStopMinutes`, `runtime.autoRestart`, `runtime.memoryGiB` and `runtime.cpuCount` ("applies at the next start"), `runtime.userdataGiB` (fixed after setup; the control says that a change needs **Reset Android…**), and `display.maxSessions`.
   - Privacy (§9.4): the switches `integrations.enabled.*` and the defaults `integrations.defaults.*`, under the denied list of #047. A default applies only to apps recorded later ([../../03-reference/configuration.md](../../03-reference/configuration.md) §2.8), and the pane says so.
   - Storage (§9.7): the disk use of images, the Android instance, packages, and caches from `runtimeInfo { resources: true }` and `listPackages(.all)` ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md) §5.1, §18.2).
   - Advanced (§9.9): **Developer mode** (`developer.enabled`) explains the risk of ADB on `127.0.0.1:6520` and asks for confirmation before it turns on, and says that it applies at the next Android start. **Install Command-Line Tool…** shows the `sudo ln -sf` command of [cli.md](../../02-design/cli.md) §2 with **Copy**. It never runs `sudo` itself. **Reveal Logs in Finder** opens `~/Library/Logs/APKRun/` ([../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §2).
   - Check: the T0 settings tests pass for every pane control.
7. **Acceptance (design step 4).** Run the T2 tests below. Check: every acceptance criterion is checked.

### Tests

- **T0** (fake `RuntimeService`): settings patches: each control writes the documented key and value, including the Settings window controls (Runtime, Privacy switches and defaults, **Developer mode** only after its confirmation) and **Updated by** ([host-ui.md](../../02-design/host-ui.md) §15). `apkrun settings` golden output, parsing, and exit codes.
- **T2** (`Tests/IntegrationTests/`, custom image, HelloText): one test per section of §7.2–§7.4: the key in `settings.json` changes, and the effect appears where stated (live keys in the open window, next-session keys after reopening). For integrations whose features are not built yet, the test checks the write and the `integrationStatus` line. The Updates section shows the history and rolls back HelloUpdate. **Updated by** makes HelloUpdate `external` and then `apkrun` again. With Settings → General set to **Applications (all users)**, the add flow's location pop-up starts there.

### Acceptance criteria

- [ ] Each setting of [host-ui.md](../../02-design/host-ui.md) §7.2–§7.4 changes `settings.json` and takes effect where stated (a T2 test per section with HelloText) (FR-UI-03).
- [ ] The Updates section changes the mode (Automatic, Notify only, Manual) and the update source, shows the history, and rolls back HelloUpdate (FR-UPD-09).
- [ ] **Updated by** → **Another app store in Android** makes HelloUpdate `external` after a confirmation, and **APKRun** makes it `apkrun` again with its kept update source. A `googlePlay` package shows it read-only.
- [ ] The Settings window has the General, Updates, Runtime, and Advanced panes, the Privacy switches and defaults, and the Storage disk-use summary. Each control writes its key, and the default location sets where the next Mac app is created.
- [ ] **Developer mode** turns on only after its confirmation, and **Install Command-Line Tool…** shows the command without running it.
- [ ] Changing the name or icon offers **Update Mac App**, and the wrapper is changed only when the user clicks it (ADR-0009).
- [ ] No setting is written to the wrapper bundle. Settings live in `Packages/<id>/settings.json` (ADR-0009).
- [ ] "Always on top" floats the open window at once, and has no effect in full screen (OQ-09).
- [ ] **Compatibility** window mode applies at the next session, and the status bar decision is recorded (FR-DSP-06, OQ-35).
- [ ] `apkrun settings` round-trips every key, and invalid values exit 64 with the allowed values.

### Notes

- **Record:** the OQ-09 and OQ-35 decisions in [../open-questions.md](../open-questions.md), [display-and-windowing.md](../../02-design/display-and-windowing.md), and [host-ui.md](../../02-design/host-ui.md).
- Per-app settings live in the package store; `wrapper.json` holds initial values only (ADR-0009).
- `apkrun settings set update.mode` changes only the mode. The UI uses `setUpdatePolicy`, which writes the authority, the provider, and the mode together ([../../03-reference/configuration.md](../../03-reference/configuration.md) §3.1).
- **Pitfall:** the input keys apply only at the next session ([../../03-reference/configuration.md](../../03-reference/configuration.md) §3.1), and `WindowPrefs` carries only `resizable`, `alwaysOnTop`, and `zoom` ([../../03-reference/runtime-api.md](../../03-reference/runtime-api.md)). A key that is live but not in `WindowPrefs` (`window.closeBehavior`) is read when the window closes. Show the next-session note exactly for the keys that configuration.md marks as next session.

---

## #089 Portable wrappers

| Field | Value |
|---|---|
| Milestone | M7 (v0.4) |
| Depends on | #075 |
| Requirements | FR-WRP-02 (`--portable`, Should) |
| Design | [wrapper.md](../../02-design/wrapper.md) §5.4 (screen N), §6.2 step 8, §7.3, §9.1 (`unknownPackage`), §10, §12, §13, §15 #089, §16; [host-ui.md](../../02-design/host-ui.md) §7.6, §10.1; [package-store.md](../../02-design/package-store.md) §4.1, §4.4, §4.6; [update-system.md](../../02-design/update-system.md) §2, §4.7; [../../03-reference/configuration.md](../../03-reference/configuration.md) §3.3, §4; [wrapper-json.md](../../03-reference/wrapper-json.md) |
| Modules / paths | `Packages/WrapperCore/` (`BootstrapSet`, `BootstrapDocument`), `Packages/RuntimeAPI/` (bootstrap DTOs), `Daemon/apkrund/` (`importBootstrap` on the wrapper endpoint), `Packages/APKStoreCore/` (source `wrapperBootstrap`), `Apps/APKRunLauncher/` (screen N **Install from This App**), `Apps/APKRun/Features/Approvals/`, `Apps/APKRun/Features/AppPage/MacAppSection.swift`, `CLI/apkrun/Commands/Wrap.swift` (`--portable`) |
| Risks / questions | OQ-40 (APKRun's own license, a Decision with this task as its deadline: portable wrappers give `APKRunLauncher` to other people, and the portable note names the license). NFR-RES-03 limits a wrapper to 8 MiB without `bootstrap/`; the APK set of a portable wrapper comes on top |

### Goal

A portable Mac app also carries the app's APK set. Copied to another Mac, or to another user account, that has APKRun but not the app, it asks for approval, installs the app from its own bundle, and opens it. The bundle is never changed, and an installed app is never updated or downgraded from it.

### Scope

- `BootstrapSet` in `WrapperConfiguration`, §6.2 step 8, and `Contents/Resources/bootstrap/` with `bootstrap.json` ([wrapper.md](../../02-design/wrapper.md) §10.1). `kind: portable` in Info.plist and `wrapper.json`.
- `apkrun wrap … --portable`, for an installed package and for a file without `--install` (the import ticket's set and the host preview icon, with a warning). The size is printed with the portable note of [../../05-development/legal-and-licensing.md](../../05-development/legal-and-licensing.md) §9.
- Approval details for portable wrappers: the bundled version in the prompt ([host-ui.md](../../02-design/host-ui.md) §10.1).
- `importBootstrap(bootstrapJSON, [FileHandle])` on the wrapper endpoint with the rules of §10.2, and the store import with source `wrapperBootstrap`.
- Initial values from `wrapper.json` at the first record ([../../03-reference/configuration.md](../../03-reference/configuration.md) §3.3, §4).
- Launcher screen N with **Install from This App**, and the `unknownPackage` action **Install from Mac App** in APKRun.app.
- **Make Local Mac App** on the app page (§10.2).

Out of scope:

- Distribution wrappers, Developer ID signing, and notarization (#088).
- A GUI entry point to create a portable wrapper. The design names none ([wrapper.md](../../02-design/wrapper.md) §6.6), so the CLI is the only one in M7.
- Updating or downgrading an installed package from a bootstrap (never allowed).

### Deliverables

- `BootstrapSet` and `BootstrapDocument` in `Packages/WrapperCore/`, and the bootstrap DTOs in `Packages/RuntimeAPI/`.
- `importBootstrap` in apkrund with its checks, and `wrapperBootstrap` as an import source in APKStoreCore.
- Screen N with **Install from This App** in the launcher.
- The portable details in the approval window, **Install from Mac App**, and **Make Local Mac App**.
- `--portable` in `apkrun wrap`.
- T0, T1, and T2 tests.

### Implementation steps

The design steps are [wrapper.md](../../02-design/wrapper.md) §15 #089, steps 1–2. Design step 1 is split into steps 1–4 here.

1. **Bootstrap contents (design step 1).** Add `BootstrapSet` (the files of the package's `current/` set as installed, or of an import ticket) to `WrapperConfiguration`. §6.2 step 8 clones the files into `Contents/Resources/bootstrap/` and writes `bootstrap.json` (`formatVersion`, `packageId`, `versionCode`, `versionName`, `setDigest`, `signers`, `files` with name, size, and SHA-256; sorted keys). The signature seals them like any resource. Set `APKRunWrapperKind` and `wrapper.json` `kind` to `portable`. `apkrun wrap <package> --portable` prints the size. `apkrun wrap app.apk --portable` without `--install` uses the import ticket's set and the host preview icon or the placeholder, and warns about the icon. Check: T0 `bootstrap.json` encoding, and an unknown `formatVersion` is rejected.
2. **Approval for portable wrappers (design step 1).** `ApprovalPrompt` carries the bundled version. The approval window shows "Android app not installed. This Mac app contains version ‹version›." or the installed version, and the includes line "Includes ‹App› ‹version›" of §10.2. Allow registers the wrapper with `approval: user`. Check: the T1 approval test with a portable fixture and the fake UI client passes.
3. **`importBootstrap` (design step 1).** On the wrapper endpoint, `importBootstrap` is allowed only when the wrapper is approved, `bootstrap.json` `packageId` equals the registry's `packageId`, and the package is not installed or is `uninstalledKeepingData`. A wrapper that is not approved or a package that is installed fails with `bootstrapNotAllowed`, and a `packageId` mismatch or bad JSON fails with `bootstrapInvalid` ([wrapper.md](../../02-design/wrapper.md) §13). The store copies the files, checks SHA-256 against `bootstrap.json` (a mismatch is `bootstrapInvalid`), and runs all intrinsic checks and the preview with source `wrapperBootstrap` ([package-store.md](../../02-design/package-store.md) §4.1, §4.6). Preview warnings make APKRun.app show the install sheet to confirm. The install takes `wrapper.json` `updates` as the initial authority, mode, and provider, and `window` and `integration` as the first-record settings. A newer version kept in Android's data makes the install fail with the store's downgrade error. Check: the T1 rule tests pass (not approved, package mismatch, installed, hash mismatch).
4. **Launcher and APKRun.app actions (design step 1).** When `openSession` returns `packageNotInstalled` for a portable wrapper, screen N shows **Install from This App** with "Install ‹App› ‹version› from this Mac app?". The question is skipped right after an approval on the first run, because the approval already asked. After the import, the launcher repeats `openSession`. In APKRun.app, the `unknownPackage` action **Install from Mac App** opens the wrapper, which runs the same screen N flow. **Make Local Mac App** in the Mac App section refreshes the wrapper as `kind: local` without `bootstrap/` (the #076 refresh with a kind change). Check: after an uninstall, opening the portable wrapper asks again.
5. **Acceptance (design step 2).** Generate a portable `HelloText.app` in account A, copy it to a second user account on the same Mac that has APKRun set up but not HelloText, and run the checks below. Check: every acceptance criterion is checked.

### Tests

- **T0**: `bootstrap.json` encoding and schema, and an unknown `formatVersion` rejected.
- **T1** (`Packages/WrapperCore/Tests/`, fake UI client): approval for a portable wrapper, and the `importBootstrap` rules.
- **T2** (`Tests/IntegrationTests/`): the first run in the second user account: approval, install from the bundle, launch. A second open does not import. The bundle hashes (#049 hash list) are unchanged throughout.
- **Manual**: the #089 part of C04-7 (the approval prompt for a copied wrapper is clear, and Return does not allow) ([../test-strategy.md](../test-strategy.md) §8.5).

### Acceptance criteria

- [ ] A portable `HelloText.app` generated in one account, copied to a second user account on the same Mac (or a second Mac) that has APKRun but not the package, asks for approval, installs HelloText from the bundle, and launches it.
- [ ] A second open does not import again. The bootstrap is used only when the package is not installed.
- [ ] The bundle hashes are unchanged throughout.
- [ ] An installed package is never updated or downgraded from a bootstrap (`bootstrapNotAllowed`), and a changed bootstrap file is refused (`bootstrapInvalid`).
- [ ] The approval prompt shows the bundled version, and Return does not allow (C04-7).
- [ ] `apkrun wrap app.apk --portable` without `--install` creates a portable wrapper and warns about the icon.
- [ ] **Make Local Mac App** removes `bootstrap/`, and the wrapper keeps its bundle ID.

### Notes

- The initial update settings in `wrapper.json` let a portable wrapper bring its update source, for example Direct ([update-system.md](../../02-design/update-system.md) §4.7).
- After the first install, `bootstrap/` is dead weight. **Make Local Mac App** is the way to remove it (§10.2).
- NFR-RES-03 ([../../00-product/requirements.md](../../00-product/requirements.md)) limits a wrapper to 8 MiB without `bootstrap/`. The APK set of a portable wrapper comes on top of that limit ([../../02-design/wrapper.md](../../02-design/wrapper.md) §2).
- **Pitfall:** a portable wrapper copied through a quarantining app is translocated when opened from its download location. Screen T must come before the approval (§7.4).
