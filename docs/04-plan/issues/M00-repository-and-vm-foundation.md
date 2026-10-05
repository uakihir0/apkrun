# M0 Repository and VM foundation

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.1 |
| Related | [../traceability.md](../traceability.md), [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../05-development/build-system.md](../../05-development/build-system.md), [../../05-development/environment-setup.md](../../05-development/environment-setup.md), [../../../AGENTS.md](../../../AGENTS.md) |

## Milestone goal

M0 proves that Virtualization.framework works for APKRun before Android is involved. The bring-up starts with a Linux VM. At the end of M0:

- The repository has the layout of [../../01-architecture/modules.md](../../01-architecture/modules.md) §1. It has the 16 library modules, and every product builds from a clean checkout: APKRun.app, APKRunMenuBar, APKRunLauncher, apkrund, and the `apkrun` CLI.
- CI enforces the module graph, pinned dependencies, TODO numbers, formatting, and the logging rules from the first commit.
- DiagnosticsCore supplies the error model, the error catalog, logging, operation IDs, performance markers, and the health types. Every later task uses them.
- A small ARM64 Linux test guest boots with `VZLinuxBootLoader`. It exercises the serial console, virtio-blk, NAT networking, virtio-vsock, and a host-implemented custom virtio device.
- Gate G1 passes.

M0 delivers none of the v0.1 items directly ([../roadmap.md](../roadmap.md) §3.1). It delivers the foundation that #012–#014 (G2) and #019 (virtio-gpu) build on.

## Exit criteria

- [ ] Every task below meets all its acceptance criteria, or has moved to a later milestone with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4).
- [ ] G1 passes through `scripts/run-gate.sh G1` on the reference Mac ([../open-questions.md](../open-questions.md) OQ-02) with a clean build from `main`. The evidence is attached to the G1 gate issue ([../test-strategy.md](../test-strategy.md) §5).
- [ ] A clean checkout passes these steps with no manual edits (NFR-DEV-02):
  - `scripts/bootstrap --check`
  - `scripts/generate-project.sh`
  - `swift build && swift test`
  - `xcodebuild -project APKRun.xcodeproj -scheme APKRun -configuration Debug build`
- [ ] `workflow-policy` and the `ci.yml` jobs `lint`, `codegen`, `build`, and `test-swift` are required checks on `main` and are green.
- [ ] The `LinuxGuest` T2 suite passes on the reference Mac, and `apkrun-dev dev linux --tests blk,net,vsock,ports,rng` exits 0. Here, `apkrun-dev` means the Debug CLI inside the Debug build of APKRun.app, `Contents/Resources/bin/apkrun`. #031 later links it as `~/.local/bin/apkrun-dev`.
- [ ] These verification results are recorded where each task's Notes say:
  - console port numbering ([../../02-design/vm.md](../../02-design/vm.md) §6.2);
  - virtio-blk device order;
  - the VZ guest-reboot behavior;
  - the #063 part of the R-01 Result line;
  - OQ-04 settled;
  - the G1 and #063 lines of the ADR-0002 Verification section.
- [ ] The Definition of Done ([../../../AGENTS.md](../../../AGENTS.md) §12) holds for every task, including NFR-DEV-04 (every `TODO` has a task number) and NFR-DEV-05 (nothing imports `Experiments/`).
- [ ] Nothing in M0 claims that the core architecture is validated. That needs G3.
- [ ] Risks: R-01 has a Result line for its #063 part and stays `open` for #019 and #028 (see the Notes of #063).

## Task order

1. #001 Bootstrap Xcode workspace.
2. #061 Diagnostics foundation. **Parallel with #062.** Once #001 is done, #008 and #018 of M1 and M2 can also start ([../roadmap.md](../roadmap.md) §1.4).
3. #062 CI and module dependency checks. **Parallel with #061.**
4. #002 VMDefinition and VM validation. It depends on #001 and can start with #061. Its error types adopt `APKRunError` once #061 step 4 is merged, and #002 is not done before then.
5. #003 Boot minimal ARM64 Linux, which closes G1.
6. #004 Serial console logging. **Parallel with #005, #006, #007, #063.**
7. #005 virtio-blk storage. **Parallel with #004, #006, #007, #063.**
8. #006 Guest networking. **Parallel with #004, #005, #007, #063.**
9. #007 virtio-vsock. **Parallel with #004, #005, #006, #063.**
10. #063 VirtioDeviceCore and test virtio device. **Parallel with #004–#007.**

Tasks #004–#007 and #063 all extend the same shared files:

- `Tests/Fixtures/linux/init`
- `Tests/Fixtures/linux/modules.list`
- `Tests/IntegrationTests/LinuxGuestTests/`
- `ThirdParty/ThirdParty.lock.json`
- `Packages/DiagnosticsCore/ErrorCatalog/errors.json`

Keep each change to these files small and self-contained, one check per block, and merge them one after another.

---

## #001 Bootstrap Xcode workspace

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | None |
| Requirements | NFR-DEV-02. Constraints: NFR-DEV-05 (the `Experiments/` layout) |
| Design | [../../01-architecture/modules.md](../../01-architecture/modules.md) §1, §3, §5; [../../05-development/build-system.md](../../05-development/build-system.md) §1, §2, §11, §12.2, §12.4, §13; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §2.2, §2.7, §2.9, §7; [../../02-design/cli.md](../../02-design/cli.md) §2, §3.2, §3.3, §4.1, §6.1, §6.2; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §4 |
| Modules / paths | `Package.swift`, `Package.resolved`, `project.yml`, `.xcode-version`, `.gitignore`, `Packages/*/`, `CLI/apkrun/`, `Daemon/apkrund/`, `Apps/APKRun/`, `Apps/APKRunMenuBar/`, `Apps/APKRunLauncher/`, `scripts/bootstrap`, `scripts/tool-versions.env`, `scripts/generate-project.sh`, `scripts/build/embed-cli.sh`, `scripts/smoke-products.sh`, `Guest/`, `Images/`, `ThirdParty/`, `Tests/`, `Experiments/` |
| Risks / questions | None |

### Goal

A clean checkout on an Apple silicon Mac with macOS 27 builds all five products and passes `swift test`. `apkrun` prints its version and help. APKRun.app launches. apkrund starts and exits cleanly.

### Scope

- The repository layout of [../../01-architecture/modules.md](../../01-architecture/modules.md) §1, with placeholder sources.
- `Package.swift` with the 16 library modules, their dependency edges, one T0 test target per module, the `apkrun` executable, and the `EmbeddedRuntime` trait.
- `project.yml` for APKRun, APKRunMenuBar, APKRunLauncher, and apkrund. This covers the Debug and Release identities, the entitlements files, and the embed phases that exist in M0.
- The pinned-tool files, `scripts/bootstrap` (M0 subset), and `scripts/generate-project.sh`.
- `scripts/build/embed-cli.sh`, which builds and embeds the CLI with an embedded Info.plist.
- The CLI's root command, `version`, `--version`, `--help`, the JSON envelope, and the exit-code support.
- Placeholder apps and a daemon that starts and exits cleanly.
- A T1 smoke script for the products.

Out of scope:

- Any VM code (#001). The CLI's `dev` commands come with #003.
- Logging, the error catalog, and `BuildInfo` (#061). CI workflows and the static checks (#062).
- XPC and RuntimeClient (#032). The LaunchAgent plist, `SMAppService`, and `scripts/dev/install-dev-app.sh` (#031).
- Sparkle (#057). GraphicsBridge and the VirGL runtime (#020). Generated protobuf code (#033).
- Gradle and the guest components (#072 and others), `components.json` (see Notes), `apkrun-perf` (#070), and Developer ID signing (#088).
- `AGENTS.md`, `CLAUDE.md`, and `README.md` already exist. This task only updates the build commands in `README.md` if they differ from [../../05-development/build-system.md](../../05-development/build-system.md) §1.

### Deliverables

- `Package.swift`, as set out in [../../05-development/build-system.md](../../05-development/build-system.md) §2.1:
  - tools version 6.2, `swiftLanguageModes: [.v6]`, and `.macOS("27.0")`;
  - 16 library targets, each with a static library product;
  - the `apkrun` executable target at `CLI/apkrun`, which excludes `Tests`;
  - the `EmbeddedRuntime` trait;
  - `swift-argument-parser`, `swift-protobuf`, and `ZIPFoundation`, all pinned with `exact:`.
- `Package.resolved`, committed.
- `ThirdParty/ThirdParty.lock.json` and local license copies for the three pinned Swift packages, so each dependency satisfies the repository's pinning rule from its first commit.
- `Packages/<Module>/Sources/<Module>/<Module>.swift`, one placeholder per module.
- `Packages/<Module>/Tests/<Module>Tests/<Module>Tests.swift`, one Swift Testing test per module.
- `CLI/apkrun/Tests/`, with golden files in `CLI/apkrun/Tests/Golden/`.
- The CLI sources:
  - `CLI/apkrun/main.swift`;
  - `CLI/apkrun/Support/Output.swift`;
  - `CLI/apkrun/Support/ExitCodes.swift`;
  - `CLI/apkrun/Support/Version.swift`;
  - `CLI/apkrun/apkrun-dev.entitlements`.
- `Daemon/apkrund/main.swift`, `Daemon/apkrund/Info.plist`, and `Daemon/apkrund/apkrund.entitlements`.
- `Apps/APKRun/`, `Apps/APKRunMenuBar/`, and `Apps/APKRunLauncher/`: the placeholder sources, Info.plists, and `Apps/APKRun/APKRun.entitlements`.
- `project.yml` with the Debug and Release configurations.
- `.xcode-version` containing `27.0`. `scripts/tool-versions.env` containing `XCODEGEN_VERSION=2.44.1` and its SHA-256.
- The scripts:
  - `scripts/bootstrap`, with `--check`;
  - `scripts/generate-project.sh`;
  - `scripts/build/embed-cli.sh`;
  - `scripts/smoke-products.sh`.
- `.gitignore`: `/build/`, `.build/`, `.swiftpm/`, `APKRun.xcodeproj/`, `DerivedData/`, `*.xcresult`, `Images/work/`, `ThirdParty/out/`.
- Empty directories kept with `.gitkeep`:
  - `Guest/`, `Images/manifests/`, `Images/tools/`;
  - `ThirdParty/patches/`, `ThirdParty/build/`;
  - `Tests/IntegrationTests/`, `Tests/AcceptanceTests/`, `Tests/Fixtures/`;
  - `Experiments/`.

### Implementation steps

1. **Package manifest.** Write `Package.swift` with the settings of [../../05-development/build-system.md](../../05-development/build-system.md) §2.1.
   - Declare one target per directory in `Packages/`. Declare exactly the edges of [../../01-architecture/modules.md](../../01-architecture/modules.md) §3, with `GuestProtocol → SwiftProtobuf`. GraphicsBridge and its edge come with #020.
   - The `apkrun` target depends on `RuntimeClient`, `RuntimeAPI`, `DiagnosticsCore`, and `ArgumentParser` ([../../02-design/cli.md](../../02-design/cli.md) §2). It also depends on `RuntimeHost`, `WindowingCore`, and `InputCore` only through `condition: .when(traits: ["EmbeddedRuntime"])`, and defines `APKRUN_EMBEDDED_RUNTIME` under the same trait. The trait is off by default.
   - Pin `swift-argument-parser`, `swift-protobuf`, and `ZIPFoundation` with `exact:` at their latest releases, and commit `Package.resolved`.
   - Check that the pinned toolchain supports trait-conditioned dependencies between targets of the same package (SE-0450). If it does not, record the fallback in [build-system.md](../../05-development/build-system.md) §2.1 in the same pull request.

   Check: `swift build` and `swift build --traits EmbeddedRuntime` both succeed. `swift package dump-package` shows the trait condition on the three `apkrun` edges only.
2. **Placeholders and T0 targets.**
   - Give every module one public placeholder type. GuestProtocol's placeholder imports SwiftProtobuf, so that the edge is real.
   - Give every module a `<Module>Tests` target with one Swift Testing `@Test`.
   - Give the CLI a test target at `CLI/apkrun/Tests`.
   - Do not create `<Module>SystemTests` or `<Module>TestSupport` targets yet. The tasks that need them add them ([../../05-development/build-system.md](../../05-development/build-system.md) §2.1).
   - Create the directories of the Deliverables with `.gitkeep`. Create no `Common/`, `Utils/`, `Helpers/`, or `Misc/` directory.

   Check: `swift test` runs 17 test targets and passes.
3. **CLI root command.** Build the CLI following [../../02-design/cli.md](../../02-design/cli.md) §6.1.
   - `main.swift` defines the root `AsyncParsableCommand` named `apkrun` with a `version` subcommand and swift-argument-parser's `--help` and `--version`.
   - `Support/Output.swift` writes human output to stdout and the JSON envelope `{ "schemaVersion": 1, "result": … }` ([cli.md](../../02-design/cli.md) §3.2).
   - `Support/ExitCodes.swift` holds the exit codes of [cli.md](../../02-design/cli.md) §3.3 as named constants. #061 adds the mapping from error codes.
   - `Support/Version.swift` reads `CFBundleShortVersionString`, `CFBundleVersion`, and `APKRunBuildIdentity` from `Bundle.main.infoDictionary`, which the embedded Info.plist fills (step 6). #061 replaces this with `BuildInfo`.
   - Outputs:
     - `apkrun version` prints `apkrun 0.1.0 (1)`.
     - `apkrun version --json` prints the JSON envelope with version, build, build identity, commit, configuration, and embedded-runtime fields (the latter four are added by #061; see the golden at `CLI/apkrun/Tests/Golden/version-json.txt`).
     - `apkrun --version` prints `0.1.0`.
     - Without an embedded Info.plist (a plain `swift build`), the version is `0.0.0-dev` and the build is `0`.
   - The apkrund and image versions of [cli.md](../../02-design/cli.md) §4.1 are added when apkrund is reachable (#032).
   - Commands take the version source as an injected value, so the golden tests are deterministic.

   Check: the golden tests for `version`, `version --json`, `--version`, and `--help` pass.
4. **apkrund.** `Daemon/apkrund/main.swift` is a thin main. All future logic lives in RuntimeHost ([../../05-development/build-system.md](../../05-development/build-system.md) §2.1).
   - `apkrund --version` prints `apkrund 0.1.0 (1)` and exits 0.
   - Without arguments, it installs `DispatchSource` signal handlers for `SIGTERM` and `SIGINT`, calls `dispatchMain()`, and exits 0 when a signal arrives. It does nothing else in M0.

   Check: `apkrund & sleep 1; kill -TERM $!; wait $!` returns 0.
5. **Apps.**
   - APKRun is a SwiftUI app with one window titled "APKRun".
   - APKRunMenuBar is a SwiftUI `MenuBarExtra` with a Quit item and `LSUIElement` = YES.
   - APKRunLauncher is an AppKit app (`NSApplication` main, one window) that links only system frameworks. `scripts/check-launcher.sh` enforces this from #068 on.

   None of them imports RuntimeCore ([../../../AGENTS.md](../../../AGENTS.md) §6.1). They link the products listed in [../../05-development/build-system.md](../../05-development/build-system.md) §2.2. Sparkle comes with #057.

   Check: each app runs from Xcode.
6. **project.yml and embedding.** Write `project.yml` following [../../05-development/build-system.md](../../05-development/build-system.md) §2.2–§2.5.
   - Reference the root package as a local Swift package.
   - Configurations: `Debug` and `Release`. `ReleaseUpdateTest` is added later with the Maintenance suite ([../../05-development/build-system.md](../../05-development/build-system.md) §2.4).
   - Bundle IDs: the Release values of [../../05-development/build-system.md](../../05-development/build-system.md) §2.2, with the `.dev` suffix in Debug ([../../05-development/build-system.md](../../05-development/build-system.md) §13). `APKRunBuildIdentity` is `dev` or `release` in every Info.plist.
   - Settings: `MARKETING_VERSION` = `0.1.0`, `CURRENT_PROJECT_VERSION` = `1`, `ARCHS` = `arm64`, `ENABLE_HARDENED_RUNTIME` = `YES`, and warnings as errors only when `APKRUN_CI=1`.
   - apkrund is a command-line tool with `CREATE_INFOPLIST_SECTION_IN_BINARY` = YES.
   - Entitlements ([../../05-development/build-system.md](../../05-development/build-system.md) §12.2): `Apps/APKRun/APKRun.entitlements` is an empty dictionary. `Daemon/apkrund/apkrund.entitlements` and `CLI/apkrun/apkrun-dev.entitlements` contain `com.apple.security.virtualization`.
   - The APKRun target has the M0 embed phases of [../../05-development/build-system.md](../../05-development/build-system.md) §11:
     - Embed Helpers: `Contents/Helpers/apkrund`, `Contents/Helpers/APKRunLauncher.app`.
     - Embed Login Items: `Contents/Library/LoginItems/APKRunMenuBar.app`.
     - A run-script phase that calls `scripts/build/embed-cli.sh`.
   - `embed-cli.sh`:
     1. Runs `swift build -c <debug|release> --product apkrun`, adding `--traits EmbeddedRuntime` in Debug.
     2. Generates an Info.plist with `CFBundleIdentifier` `io.apkrun.cli` (or `io.apkrun.cli.dev`), the two version keys, and `APKRunBuildIdentity`.
     3. Links the plist into the binary with `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker <plist>`.
     4. Copies the result to `Contents/Resources/bin/apkrun`.
     5. Signs it with `$EXPANDED_CODE_SIGN_IDENTITY`, adding `apkrun-dev.entitlements` in Debug ([../../05-development/build-system.md](../../05-development/build-system.md) §12.4). When the identity is empty (`CODE_SIGNING_ALLOWED=NO`), it skips signing.
   - `scripts/generate-project.sh` runs only the pinned XcodeGen from `build/tools/xcodegen-2.44.1/`.

   Check: the Debug build of the APKRun scheme contains the layout of [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §4 for the M0 parts. `codesign -d --entitlements - Contents/Resources/bin/apkrun` shows the virtualization entitlement in Debug and none in Release.
7. **Bootstrap.** `scripts/bootstrap` downloads the pinned XcodeGen into `build/tools/`, checks its SHA-256 against `scripts/tool-versions.env`, and then runs the checks. `--check` only checks.
   - M0 implements these rows of [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §7:
     - Apple silicon and macOS 27+;
     - Xcode matches `.xcode-version`;
     - Swift 6.2 or later;
     - XcodeGen;
     - nested virtualization (informational);
     - free disk (warning).
   - Every other row prints `skip (added by #NNN)` and does not fail. The task that introduces a tool adds its row.
   - Output is one line per check (`ok`, `warning`, `skip`, `FAIL`). The exit status is nonzero only on `FAIL`.

   Check: on a fresh clone, `scripts/bootstrap` followed by `scripts/bootstrap --check` reports no `FAIL`.
8. **Smoke script.** `scripts/smoke-products.sh <build products dir>` checks the task acceptance criteria outside Xcode:
   - The CLI's `version`, `--version`, and `--help` exit 0 with the expected output.
   - APKRun.app starts. The script uses `open -n`, then `pgrep -x APKRun` within 10 s, then quits it through `osascript` with the bundle ID, and expects the process to be gone within 10 s.
   - apkrund starts, receives `SIGTERM` after 1 s, and exits 0.

   Check: the script passes against a Debug build made with `CODE_SIGN_IDENTITY=-`.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/<Module>/Tests/<Module>Tests/`): one placeholder test per module, so every target exists and runs. (`CLI/apkrun/Tests/`): golden tests of `version`, `version --json`, `--version`, and `--help`, with an injected version source.
- **T1** (`scripts/smoke-products.sh`, run manually on a real Apple Silicon Mac before merge): the CLI output, the GUI launch and quit, and the apkrund start and clean exit.
- **T2**: none (no VM).
- **T3**: none.

### Acceptance criteria

- [x] A clean checkout builds. `scripts/bootstrap`, `scripts/generate-project.sh`, `swift build`, and the Debug `xcodebuild` of the APKRun scheme succeed with no manual step (NFR-DEV-02).
- [x] `swift test` succeeds.
- [x] The CLI prints its version (`apkrun version`, `apkrun --version`) and its help (`apkrun --help`).
- [x] APKRun.app launches and quits.
- [x] The apkrund executable starts and exits cleanly (exit 0 on `SIGTERM`).
- [x] APKRun.app, APKRunMenuBar, APKRunLauncher, apkrund, and `apkrun` all build for arm64 and macOS 27.
- [x] `Package.swift` declares only the edges of [../../01-architecture/modules.md](../../01-architecture/modules.md) §3. The `RuntimeHost`, `WindowingCore`, and `InputCore` edges of `apkrun` exist only with the `EmbeddedRuntime` trait.
- [x] `ThirdParty/ThirdParty.lock.json` records every exact Swift package pin with its full resolved revision, license, and license file.
- [x] The Debug CLI inside APKRun.app carries the virtualization entitlement and the `io.apkrun.cli.dev` identifier. The Release CLI carries no entitlement.
- [x] `--json` output follows the envelope of [../../02-design/cli.md](../../02-design/cli.md) §3.2.
- [x] No `Common/`, `Utils/`, `Helpers/`, or `Misc/` directory exists.
- [x] `APKRun.xcodeproj` is not committed and is generated only by the pinned XcodeGen.

### Notes

- **Record:** the SE-0450 result (trait-conditioned dependencies work, or the fallback) goes into [../../05-development/build-system.md](../../05-development/build-system.md) §2.1.
- **Pitfall:** Xcode builds local Swift packages only in Debug or Release. Do not put anything into package code that must differ in `ReleaseUpdateTest` ([../../05-development/build-system.md](../../05-development/build-system.md) §2.4).
- **Pitfall:** `swift build` alone produces a CLI with no embedded Info.plist. Code must handle missing keys (`0.0.0-dev`) and must never crash on them.
- **Pitfall:** a path-level test such as "the GUI launches" needs a GUI session. The `apkrun-ci` runner has one ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §6.2). Hosted macOS runners may run static checks, builds, and T0 tests; T1 checks need the real Mac host.
- `components.json` and `scripts/build/write-components.py` ([../../05-development/build-system.md](../../05-development/build-system.md) §5) are added by #057 (M10). They are not part of #001. See the Notes of #061.
- Verification on 2026-09-29, arm64 macOS 27.0 / Xcode 27.0 / Swift 6.4: bootstrap checks, project generation, default and `EmbeddedRuntime` Swift builds, all 22 Swift tests, Xcode Debug and unsigned Release builds, Debug product smoke, bundle identities, entitlements, and arm64 slices passed.

---

## #061 Diagnostics foundation

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #001 |
| Requirements | FR-CLI-02, FR-OPS-05, NFR-OBS-01, NFR-SEC-05, NFR-DEV-03 |
| Design | [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §1–§4, §7.1–§7.3, §11 (#061), §12, §13; [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §1–§5, §16; [../../02-design/cli.md](../../02-design/cli.md) §3.2, §3.3, §4.8, §6.2; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1, §2; [../../05-development/build-system.md](../../05-development/build-system.md) §3, §4.2 |
| Modules / paths | `Packages/DiagnosticsCore/Sources/DiagnosticsCore/` (`Paths/`, `Build/`, `Logging/`, `Operations/`, `Errors/`, `Perf/`, `Health/`), `Packages/DiagnosticsCore/ErrorCatalog/errors.json`, `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`, `Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`, `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTestSupport/`, `scripts/errorgen.swift`, `scripts/check-logging.sh`, `scripts/check-compile-fail.sh`, `scripts/build/stamp-commit.sh`, `Tests/Fixtures/compile-fail/`, `CLI/apkrun/` (`Support/`, `Commands/Logs.swift`), `project.yml` |
| Risks / questions | OQ-04 (`log show` for non-admin users; partial result recorded, non-admin account unavailable here) |

### Goal

Every process can log through `APKLogger` with mandatory privacy and operation IDs, throw typed `APKRunError`s whose texts come from `errors.json`, record performance markers, and report health. The CLI prints errors in the three-line format, and `apkrun logs` reads the unified log, or the file mirrors when `log show` is not available.

### Scope

- `APKRunPaths` and `BuildInfo`.
- The logging facade (`LogSubsystem`, category enums, `LogMessage`, `Sensitive<T>`, `APKLogger`) with a `LogSink` seam, and `LogMirrorWriter`.
- `OperationID`, `OperationContext`, and propagation helpers.
- The error model:
  - `APKRunError`, `ErrorDomain`, `ErrorParameter`, `UnderlyingError`, `RemediationAction`;
  - `errors.json` with the `vm.*` and `cli.*` entries;
  - `scripts/errorgen.swift`;
  - `ErrorPresenter`.
- `PerfMarker`, `Perf.mark`, `Perf.interval`, and `PerfTimeline`.
- The health types, the verdict function, and `HostChecks`.
- `DiagnosticsContext`, the diagnostics bundle that other modules receive (see step 6).
- `scripts/check-logging.sh` and the compile-fail tests.
- In the CLI: the error presentation and the mapping to exit codes, and `apkrun logs`.

Out of scope:

- The `Redactor` and the diagnostics bundle (#060). `apkrun doctor` (#059).
- The Japanese texts (#092). In M0, `ja` is required only for release builds.
- `PerfRecordWriter` and `MetricsSampler` (#070) ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §11 step 5).
- Writing the apkrund mirror in production. apkrund starts using `LogMirrorWriter` with #031.
- `apkrun logs --guest`. It needs the logcat console port through apkrund and developer mode, and comes with #032 ([../../02-design/cli.md](../../02-design/cli.md) §5).
- The `apkrund.reachable`, `apkrund.version`, and `apkrund.crashLoop` host checks. They need the broker and `daemon.json` (#031) and come with #059.

### Deliverables

- DiagnosticsCore sources in the subdirectories listed under Modules / paths, with the public API of [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §2–§4 and §7.1–§7.3.
- `Packages/DiagnosticsCore/ErrorCatalog/errors.json`, with every `vm.*` entry of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5 and every `cli.*` entry of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §16.
- `Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/ErrorCatalog.generated.swift`, committed.
- `scripts/errorgen.swift` (Swift output and `--markdown`).
- `scripts/check-logging.sh`, `scripts/check-compile-fail.sh`, and `Tests/Fixtures/compile-fail/*.swift`.
- `scripts/build/stamp-commit.sh` and a `BuildStamp` aggregate target in `project.yml`.
- `DiagnosticsCoreTestSupport` with:
  - `RecordingLogSink`;
  - `FakeLogCommandRunner`;
  - a manual clock;
  - `DiagnosticsContext.testing()`;
  - the catalog conformance helper that module tests call with their fixture lists of error values.
- CLI: `Support/ErrorOutput.swift`, `Support/ExitCodes.swift` extended with the catalog mapping, and `Commands/Logs.swift`.
- The OQ-04 result in [../open-questions.md](../open-questions.md) and [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14.

### Implementation steps

Steps 1–9 are the design steps of [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §11 (#061), in the same order.

1. **Paths and build info.**
   - `APKRunPaths` resolves every path of [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md). The data root is `~/Library/Application Support/APKRun/`, and the logs root is `~/Library/Logs/APKRun/`. Debug builds use `APKRun-Dev` for both.
   - `APKRunPaths` honors `APKRUN_HOME` only when told to. The CLI tells it to only for `dev` commands ([../../02-design/cli.md](../../02-design/cli.md) §3.6), and tests tell it to always. With `APKRUN_HOME` set, the logs root is `$APKRUN_HOME/Logs/` (see Notes).
   - `BuildInfo` reads these fields from the bundle Info.plist, or from the executable's embedded Info.plist:
     - `CFBundleShortVersionString` and `CFBundleVersion`;
     - `APKRunBuildIdentity`;
     - `APKRunGitCommit`;
     - the configuration and the embedded-runtime flag.
   - `scripts/build/stamp-commit.sh` writes `build/generated/BuildStamp.h` with `#define APKRUN_GIT_COMMIT <7 hex>[-dirty]`. It runs in a `BuildStamp` aggregate target that every target depends on. Every Info.plist uses `INFOPLIST_PREPROCESS` with that prefix header. `embed-cli.sh` reads the same header.
   - Replace the CLI's `Support/Version.swift` with `BuildInfo`.

   Check: `apkrun version --json` shows the commit, and a T0 test decodes `BuildInfo` from a fixture plist.
2. **Logging facade.** Build the facade of §3.1–§3.2.
   - `LogSubsystem` is the closed enum of §3.1.
   - Categories are one enum per subsystem.
   - `LogMessage` is a custom string-interpolation type. Every interpolation requires `.public`, `.private`, or `.hashed`, and there is no overload for `Sensitive<T>`.
   - `APKLogger` renders the public text, the U+001F separator, and the full text. It appends ` op=… pkg=… disp=… sess=… err=…` from `OperationContext` and the `error:` argument.
   - `APKLogger` writes through a `LogSink` protocol. The production sink is `os.Logger`. The test sink is `RecordingLogSink`.
   - `LogMirrorWriter` (§3.3):
     - a serial queue and a 1 MiB buffer;
     - flushes every 1 s and right after `error` and `fault` entries;
     - rotation at 10 MiB × 3;
     - files created with mode 0600;
     - drops entries when the buffer is full and counts them as `diagnostics.mirrorDropped`.

   Check: T1-1 passes (every privacy mode, U+001F only with private values, structured fields).
3. **Operation IDs (§2.4).**
   - `OperationID` is a lowercase UUID v4. It has `short` (8 hex) and a wire string, parsed with `init?(wire:)`.
   - `OperationContext` is `@TaskLocal static var current`. It has `withNew(_:)`, `withChild(_:)` (the new context records its `parent`), and helpers that read and write the ID as a string. RuntimeAPI (#032) and GuestProtocol (#033) use those helpers for the XPC header and the guest envelope. DiagnosticsCore imports neither.

   Check: T0 shows that a child task inherits the context and that `withChild` records the parent.
4. **Error model and catalog (§2).**
   - Add `APKRunError`, `ErrorDomain`, `ErrorParameter`, `UnderlyingError`, and `RemediationAction` exactly as declared in §2.1 and §2.3.
   - Write `errors.json` with the entry format of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §3.1, including `variants`, `transparent`, `retired`, and `"cliExit": "cause"`:
     - All `vm.*` entries of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5, including the proposed `vm.configurationInvalid`.
     - The `cli.*` entries of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §16, at least `cli.confirmationRequired`, `cli.versionSkew` (a warning, exit 0), and the usage error with exit 64. The usage error is `cli.invalidArguments`.
   - `swift scripts/errorgen.swift` writes `ErrorCatalog.generated.swift` with every language as literals.
   - `--markdown` regenerates the catalog tables of the domains that are in `errors.json`. It replaces only the regions between `<!-- errorgen:begin <domain> -->` and `<!-- errorgen:end <domain> -->` markers, which this step adds to [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md). The other domains stay hand-written until their tasks move them.
   - Columns that the §3.1 entry format does not hold (When raised, Raised by, Ref) go into an optional `doc` member of the entry, which the Swift output ignores.
   - `ErrorPresenter` produces:
     - the three-line CLI format;
     - one `hint:` line per item for list cases ([../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §3.6);
     - the JSON `error` object with its `cause` chain;
     - the GUI title, body, and action;
     - the Copy Details line (§2.3).
   - Pick the language from `Locale.preferredLanguages`, falling back to English.

   Check: T1-4 and T1-5 pass. The generated file and the Markdown regions are current.
5. **Performance markers (§4.1).**
   - `PerfMarker` constants for the §4.2 catalogue.
   - `Perf.mark` emits an `OSSignposter` event in category `pointsOfInterest` and appends to `PerfTimeline`, a ring of 2,000 markers with the operation context.
   - `Perf.interval` is generic and async: `static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T`. It creates a signpost interval only.
   - The clock is `ContinuousClock`.
   - `PerfRecordWriter` comes with #070.

   Check: T0 shows that the timeline keeps the newest 2,000 markers, validates bounded marker attributes, and that `interval` never appends to the timeline. Implementation review confirms that `mark` has no filesystem, mirror-writer, or `LogSink` dependency; its only effects are the in-memory timeline append and the required `OSSignposter` event.
6. **Health and the diagnostics context (§7.1–§7.3).**
   - Add the types of §7.1 and `HealthCheckRegistry`, with a 2 s timeout for quick checks, 60 s for deep checks (including time waiting for a concurrency slot), and at most 8 checks at once.
   - Add the verdict function of §7.2.
   - `HostChecks` implements the `host.*` checks and `apkrund.registration` (through `launchctl print gui/<uid>/<label>`, with the label from `BuildInfo`). All system access goes through an injected `HostProbe`, so T0 can drive every result. The component-version check reads embedded signing metadata and never executes the bundled CLI or daemon.
   - Define `DiagnosticsContext`, the value that module entry points such as `VMController.init` ([../../02-design/vm.md](../../02-design/vm.md) §2) receive. It is a `Sendable` struct holding:
     - the `LogSink`;
     - the `HealthCheckRegistry`;
     - the `PerfTimeline`;
     - `APKRunPaths`;
     - a clock.
   - `DiagnosticsContext.live(paths:)` builds the production value. `DiagnosticsContext.testing()` lives in `DiagnosticsCoreTestSupport`.

   Check: T1-6 covers every verdict row, including `runtime.provisioning`, `runtime.state`, `runtime.boot`, `graphicsFailure` before `bootFailure`, agent failures, and the stopped suffix. T0 also drives each `HostChecks` outcome through `FakeHostProbe`, verifies timeout (including permit waiting), cancellation, and eight-check concurrency limits, and confirms that deep and unavailable requirements are skipped without system access.
7. **Logging lint.** `scripts/check-logging.sh` fails in two cases:
   - on `os.Logger`, `Logger(`, `print(`, `NSLog`, or `os_log` outside `Packages/DiagnosticsCore/`;
   - on an `APKLogger` call whose interpolation has no privacy argument, or that unwraps a `Sensitive` value.

   Exemptions: `scripts/`, the `Tests/Fixtures/compile-fail/` fixtures, and the CLI's `Support/Output.swift`, which writes command output to stdout and stderr, not logs. The CLI must use `FileHandle` writes there, not `print(`, so the exemption stays narrow.

   The `lint` job (#062) runs the script.

   Check: the lint self-test flags a fixture file for each forbidden form and passes the tree.
8. **CLI presentation and `apkrun logs`.**
   - Every CLI failure goes through `ErrorPresenter`. The root command catches swift-argument-parser errors and prints them as the usage error with exit 64. It never prints the argument text to the log.
   - `Support/ExitCodes.swift` maps each qualified code to its `cliExit`, resolving `"cause"` through the chain.
   - `apkrun logs [--follow] [--since <duration>] [--subsystem <name>] [--level info|debug] [--json]` ([../../02-design/cli.md](../../02-design/cli.md) §4.8) uses `LogReader` in DiagnosticsCore:
     - It runs `/usr/bin/log show` (or `log stream` with `--follow`) with `--predicate 'subsystem BEGINSWITH "io.apkrun"' --style ndjson`, adding `--info` or `--debug` to match `--level`.
     - It cuts each message at U+001F and prints time, level, subsystem/category, and message.
     - The process runner is injected.
     - If `log` fails, or returns nothing within 30 s, it reads the mirrors under the logs root and says so on stderr ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §3.5).
   - `apkrun version` logs one `notice` entry under `io.apkrun.cli`, category `command`.

   Check: `apkrun version` and `apkrun logs --since 1m --subsystem io.apkrun.cli` show that entry.
9. **Acceptance and OQ-04.**
   - Run the tests below.
   - On a Mac with macOS 27, run `log show --predicate 'subsystem BEGINSWITH "io.apkrun"' --last 5m` as a standard (non-admin) user and as an administrator. Record whether the standard user gets entries, an error, or nothing.
   - Settle OQ-04 in [../open-questions.md](../open-questions.md) and update [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §3.3, §3.5, and §13.

   Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)). The IDs are those of [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §12.

- **T0** (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`):
  - T1-1 `LogMessage` rendering;
  - T1-4 catalog checks: every placeholder declared, every `cliExit` valid, no code equal to a health check ID, generated output current, `ja` required only in the release check;
  - T1-5 `ErrorPresenter`, including a list case with several `hint:` lines;
  - T1-6 health verdicts;
  - `OperationContext` inheritance;
  - `PerfTimeline` retention;
  - `BuildInfo` decoding;
  - the logging lint self-test.
- **T0** (`CLI/apkrun/Tests/`): the exit-code table against the catalog, the three-line usage error with exit 64 (golden), the `--json` error object, and `logs` output against a `FakeLogCommandRunner`.
- **T1** (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`):
  - T1-3 `LogMirrorWriter` (rotation at 10 MiB, drop counting, mode 0600, no private values in the file);
  - T2-2 `apkrun logs` with and without `log show` access, where "without" uses a runner that fails and one that times out, then falls back to the mirrors.
- **T1** (`scripts/check-compile-fail.sh`, run manually on a real Apple Silicon Mac before merge): T1-2. Each file in `Tests/Fixtures/compile-fail/` (an interpolation without privacy, an interpolated `Sensitive` value) is type-checked with `swiftc -typecheck` against the built DiagnosticsCore module and must fail with the expected diagnostic.
- **T2**: none.
- **T3**: none.

### Acceptance criteria

- [ ] The T0 and T1 tests above pass. The logging lint runs in CI; the compile-fail tests run on a real Apple Silicon Mac before merge.
- [ ] `apkrun version` logs one entry under `io.apkrun.cli` that `log show` finds ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §11 step 9).
- [ ] A deliberately invalid CLI argument prints `error:`, `hint:`, and `code:` lines on stderr and exits 64.
- [ ] `errors.json` holds every `vm.*` and `cli.*` entry of the catalog. `ErrorCatalog.generated.swift` and the marked catalog tables are current.
- [ ] Logging a `Sensitive` value, or an interpolation without privacy, does not compile.
- [ ] Every log entry made inside an `OperationContext` carries `op=` with the first 8 hex digits.
- [ ] `apkrun logs` falls back to the mirrors and says so on stderr when `log` fails or returns nothing within 30 s.
- [ ] `DiagnosticsContext.testing()` is available to other modules' tests through `DiagnosticsCoreTestSupport`.
- [ ] OQ-04 is settled and the result is recorded.

### Notes

- **Record:** the OQ-04 result goes into [../open-questions.md](../open-questions.md) OQ-04 and [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14.
- **OQ-04 environment limit (2026-09-29):** macOS 27.0 (26A428) returned the version entry from an unprivileged command in an account belonging to the `admin` group. `sudo -n` required a password, and this environment has no non-admin account. The non-admin half remains open; the implementation reads file mirrors when unified logging fails or is empty.
- **Pitfall:** unified logging keeps `info` entries in memory only by default. A short-lived CLI's `info` entry may be gone before `log show` runs. That is why `apkrun version` logs at `notice`, and why `apkrun logs --level info` passes `--info` to `log`.
- **Pitfall:** a Swift build plugin or a run-script phase cannot run before Xcode processes an Info.plist in the same target. The commit stamp therefore lives in the separate `BuildStamp` target.
- **Pitfall:** `errorgen --markdown` must never touch text outside its markers. The layout of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.2 (one text row for several codes) needs a domain-specific renderer.
- `DiagnosticsContext` is used by [../../02-design/vm.md](../../02-design/vm.md) §2 and declared in [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §1. This task builds it.
- `BuildInfo` reads Info.plist keys until #057 (M10) adds `write-components.py` and `components.json` ([../../05-development/build-system.md](../../05-development/build-system.md) §5). #057 then switches `BuildInfo` to `components.json`, with the Info.plist keys as the fallback for a bundle without the file (`swift build` products).
- With `APKRUN_HOME` set, logs go to `$APKRUN_HOME/Logs/` ([../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md)).

---

## #062 CI and module dependency checks

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #001 |
| Requirements | NFR-DEV-01, NFR-DEV-02, NFR-DEV-04, NFR-DEV-05 |
| Design | [../../05-development/build-system.md](../../05-development/build-system.md) §3, §3.1, §4, §6.1, §6.5, §15.1, §15.3; [../../01-architecture/modules.md](../../01-architecture/modules.md) §1, §3; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §6; [../../05-development/workflow.md](../../05-development/workflow.md); [../../../AGENTS.md](../../../AGENTS.md) §6.1, §6.6, §11, §12 |
| Modules / paths | `ThirdParty/ThirdParty.lock.json`, `Package.resolved`, `.xcode-version`, `.swift-format`, `.swift-format-tests`, `scripts/tool-versions.env`, `scripts/build/`, `scripts/check-module-deps.sh`, `scripts/check-todos.sh`, `scripts/check-format.sh`, `scripts/check-lock.sh`, `scripts/errorgen.swift`, `scripts/generate-protos.sh`, `scripts/release/check-release-build.sh`, `scripts/tools/` (`check-module-deps.swift`, `check-lock.swift`), `scripts/ci/` (`run-checks.sh`, `codegen.sh`, `check-pr-control-changes.py`), Gradle wrapper, build files, and `buildSrc`/`build-logic` source, `scripts/tests/`, `.github/workflows/ci.yml`, `.github/workflows/ci-policy.yml` |
| Risks / questions | GitHub-hosted `xcode-27` is Public Preview with limited memory and disk; live Actions verification awaits repository access. The metadata-only `pull_request_target` policy check must never execute PR code. Persistent self-hosted runners must remain disconnected until the owner can enforce workflow-group restrictions. |

### Goal

Every pull request gets static checks, builds, and T0 tests on fresh GitHub-hosted runners. T1 tests that need real macOS services run on an Apple Silicon Mac before merge and have their results linked. A forbidden import, an unpinned or branch-pinned dependency, a `TODO` without a task number, a formatting error, stale generated code, a failing build, or a failing required test blocks the merge.

### Scope

- The lock file with its first entries, and `scripts/check-lock.sh`.
- `scripts/check-module-deps.sh`, including the layout rules: no dumping-ground directories and no production use of `Experiments/`.
- `scripts/check-todos.sh` and `scripts/check-format.sh`.
- `scripts/release/check-release-build.sh` with the first two release checks of [../../05-development/build-system.md](../../05-development/build-system.md) §3.1: no test hooks and no test keys in the Release build.
- Self-tests for the checks, with fixtures.
- `.github/workflows/ci.yml` with the jobs `lint`, `codegen`, `build`, and `test-swift`, on GitHub-hosted macOS 27 VMs.
- `.github/workflows/ci-policy.yml` and `scripts/ci/check-pr-control-changes.py`, a metadata-only guard that prevents CI control-file changes from suppressing required checks without review.
- Branch protection on `main` with `workflow-policy` and the four `ci.yml` jobs as required checks.

Out of scope:

- `integration.yml` and the `linux-guest` job, `nightly.yml`, and `scripts/run-gate.sh` (#003, which creates the first T2 suite and the first gate).
- The `test-guest`, `test-images`, `test-linux`, `third-party`, and `fuzz-short` jobs. The tasks that introduce their inputs add them ([../../05-development/build-system.md](../../05-development/build-system.md) §15.1).
- `scripts/check-launcher.sh` (#068) and the other §3 checks of later tasks. The other §3.1 release checks: the image rows (#065), the notices row (#093), and the R1, R5, and R6 rows (#057).
- Setting up the self-hosted runners. That is an operations step of [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §6.2, done before this task's pull request.

### Deliverables

- `ThirdParty/ThirdParty.lock.json` in the format of [../../05-development/build-system.md](../../05-development/build-system.md) §6.1. It has `kind: swiftpm` entries for `swift-argument-parser`, `swift-protobuf`, and ZIPFoundation, each with the full revision from `Package.resolved`, the version, license, license files, and `ships: app`.
- The four check scripts. `check-module-deps.sh` and `check-lock.sh` are thin wrappers around `swift scripts/tools/check-module-deps.swift` and `swift scripts/tools/check-lock.swift`.
- `.swift-format`, the configuration of [../../05-development/coding-conventions.md](../../05-development/coding-conventions.md) §2.
- `scripts/ci/run-checks.sh`, which runs every §3 script present in the tree, and `scripts/ci/codegen.sh`.
- `scripts/release/check-release-build.sh`.
- `scripts/tests/run.sh` with fixtures in `scripts/tests/fixtures/{module-deps,todos,lock,release}/`.
- `.github/workflows/ci.yml`.

### Implementation steps

1. **Lock file and lock check.** Complete the three swiftpm entries seeded by #001.
   - `check-lock.swift` enforces the §6.1 rules:
     - every required field is present;
     - `kind` and `ships` take only the listed values;
     - `name` is unique;
     - `commit` is 40 lowercase hex and `sha256` is 64 hex;
     - no field holds a branch name or a short hash;
     - every listed patch exists under `ThirdParty/patches/<name>/`;
     - every `swiftpm` entry matches the revision in `Package.resolved`, and the exact version in `Package.swift` or `project.yml`;
     - every Swift package pin in `Package.resolved` has a lock entry.
   - The script prints one line per violation and exits 1.
   - #020 adds `--apply`, which applies every patch to the checked-out sources in the `third-party` job. #008 adds the vendored-file hashes of `Images/tools/vendor/` ([../../05-development/build-system.md](../../05-development/build-system.md) §6.4).

   Check: the lock fixtures fail, one rule each (a branch name, a short commit, a missing patch, a pin mismatch, an unlisted pin), and the real lock file passes.
2. **Module dependency check.** `check-module-deps.swift` reads the allowed graph from the two code blocks of [../../01-architecture/modules.md](../../01-architecture/modules.md) §3, so the document stays the only source. Then it checks four sources:
   - (a) `swift package dump-package`: every target dependency is an allowed edge. Trait conditions appear only on `apkrun → RuntimeHost`, `apkrun → WindowingCore`, and `apkrun → InputCore`, with the trait `EmbeddedRuntime`.
   - (b) `build/tools/xcodegen-2.44.1/bin/xcodegen dump --type json`: the dependencies of the app, daemon, and launcher targets match the executable rows.
   - (c) An import scan of every Swift, C, and Objective-C source of each production target, including `@testable`, `@_exported`, and `@_implementationOnly` imports. SwiftPM lets a target import anything in its dependency closure, so this catches, for example, `import RuntimeCore` in the CLI.
   - (d) Third-party products are used only where the graph allows them: SwiftProtobuf in GuestProtocol, ArgumentParser in `apkrun`, Sparkle in APKRun.

   Test and support targets have their own rules:
   - A `<Module>Tests` or `<Module>SystemTests` target may use its module, that module's dependencies, and their `TestSupport` targets.
   - A `<Module>TestSupport` target may use its module and that module's dependencies.
   - `Tests/IntegrationTests` and `Tests/AcceptanceTests` may use any module.

   Layout rules:
   - No directory named `Common`, `Utils`, `Helpers`, or `Misc` under `Apps/`, `Daemon/`, `CLI/`, or `Packages/`.
   - No production target has sources under `Experiments/`.
   - No production source imports a module defined there.

   Check: with no arguments, the script passes on the tree in under 60 s. Each fixture fails with a message that names the file, the edge, and the modules.md rule: a forbidden edge, a forbidden import, a forbidden trait edge, ArgumentParser in a library, a `Helpers/` directory, and an `Experiments/` import.
3. **TODO check.** `check-todos.sh` scans the files listed by `git ls-files` with these extensions:
   - `swift`, `h`, `c`, `m`, `mm`, `cpp`
   - `kt`, `kts`, `rs`, `py`, `sh`
   - `yml`, `yaml`, `json`
   - `rc`, `te`, `mk`, `bp`

   It skips `docs/`, `*.md`, `ThirdParty/patches/`, and `Images/tools/vendor/`. Every `TODO` or `FIXME` must be followed by `(#<digits>)` (NFR-DEV-04).

   Check: the fixtures `TODO: x`, `TODO(#NNN): x`, and `FIXME(x)` fail, `TODO(#123): x` passes, and the tree passes.
4. **Format check.** `check-format.sh` runs `swift format lint --strict --recursive` over `Apps/`, `Daemon/`, `CLI/`, `Packages/`, `Tests/`, and `scripts/`. The ktfmt, `cargo fmt --check`, and `ruff format --check` parts print `skip (<dir> not present)` until `Guest/` and `Images/tools/` have sources.

   Check: a badly formatted fixture fails and the tree passes.
5. **Check runner and code generation.**
   - `scripts/ci/run-checks.sh` runs, in order:
     1. `scripts/tests/run.sh`;
     2. `check-module-deps.sh`;
     3. `check-logging.sh`, if #061 has merged;
     4. `check-todos.sh`;
     5. `check-format.sh`;
     6. `check-lock.sh`.

     It prints a summary and fails if any check fails.
   - `scripts/ci/codegen.sh` runs every generator of [../../05-development/build-system.md](../../05-development/build-system.md) §4 that exists in the tree (`swift scripts/errorgen.swift` and `--markdown` from #061, `scripts/generate-protos.sh` from #033), then runs `git diff --exit-code`.

   Check: both scripts run locally with no arguments.
6. **Workflow.** `.github/workflows/ci.yml` runs on every `pull_request` and push to `main`. All four jobs use GitHub-hosted `xcode-27` runners, which provide a fresh macOS VM per job. Each job checks out the exact PR head SHA with persisted Git credentials disabled. `lint`, `codegen`, and `build` run `scripts/bootstrap` to install pinned tools before their checks; `build` and `test-swift` cap compiler parallelism at two jobs for the standard runner's memory limit; `test-swift` runs T0 with `swift test --skip 'SystemTests'`. The workflow has only `contents: read`, references no repository secrets, and never uses a self-hosted runner.

   `.github/workflows/ci-policy.yml` runs the required `workflow-policy` job for opened, reopened, synchronized, edited, labeled, and unlabeled pull request events targeting `main`. It checks out only `refs/heads/main` on `ubuntu-latest`, has `contents: read` and `pull-requests: read`, and uses the GitHub API to inspect the event and current head/base, changed paths, and reviews. It reads the revision again after fetching paths and reviews, and fails closed if the head or base changed during verification. Changed paths come from the commit comparison endpoint using the captured base and head SHA pair, so a transient PR update cannot substitute paths from a different revision. It never checks out or executes pull request code. Protected paths include `.github/workflows/`, `.github/actions/`, `gradle/`, `Guest/gradle/`, `scripts/build/`, `scripts/ci/`, `scripts/tests/`, `scripts/tools/`, `scripts/errorgen.swift`, `scripts/generate-protos.sh`, `scripts/tool-versions.env`, any `scripts/check-*` file, every `Package.swift` and `Package.resolved`, every `project.yml`, every `build.gradle` and `settings.gradle` file, Gradle wrapper/configuration files, every `Guest/<module>/gradle.lockfile`, every `buildSrc/` and `build-logic/` tree, every Cargo manifest and lockfile, Rust toolchain and rustfmt/Clippy configuration, `.cargo/` configuration tree, `ThirdParty/ThirdParty.lock.json`, every `Tests/` and `UITests/` tree, `.swift-format`, `.swift-format-tests`, `.xcode-version`, `docs/01-architecture/modules.md`, and the named build scripts. Such changes pass only when a non-author human approves the current head and that same reviewer applies `ci-policy-approved` in a label event for that head. New commits invalidate both conditions. Any new commit, reopening, later label event, or PR edit resets the check; the reviewer removes and reapplies the policy label last. Removing the policy label revokes the check. If the reviewer withdraws the policy approval, they must remove the label; branch protection separately requires an active PR approval. `pull_request_review` is not used because GitHub runs that event's workflow from the PR merge commit. Renames check both the old and new paths; a compare API response containing 300 files is treated as potentially truncated and fails closed, so oversized pull requests must be split.

   Do not use `pull_request_target` to execute PR code. Set `APKRUN_CI=1` and concurrency per pull request or ref. GitHub may hold the first workflow run from a fork for maintainer approval; the fork check below is recorded after that approval.

   | Job | Runs |
   |---|---|
   | `lint` | `scripts/ci/run-checks.sh` |
   | `codegen` | `scripts/ci/codegen.sh` |
   | `build` | `scripts/bootstrap`, `scripts/bootstrap --check`, `scripts/generate-project.sh`, `swift build -j 2`, `swift build -j 2 --traits EmbeddedRuntime`, `xcodebuild` Debug and Release with `-jobs 2`, `scripts/release/check-release-build.sh` on the Release APKRun.app |
   | `test-swift` | `swift test --skip 'SystemTests' -j 2` (T0 only) |
   | `workflow-policy` | run `scripts/ci/check-pr-control-changes.py` from `main`; inspect PR metadata only; require a current-head approval and label when CI control files change |

   - Upload the xcresult and JUnit reports on failure ([../test-strategy.md](../test-strategy.md) §3.7).
   - Pin every action by commit SHA, not by tag.

   Require `workflow-policy` and all four `ci.yml` jobs in branch protection. The `xcode-27` standard runner currently has limited resources and is in Public Preview; the build removes Debug DerivedData before Release to reduce disk use. Record any resource failure and move only to an adequately sized fresh hosted runner.

   Check: same-repository and fork pull requests run the four `ci.yml` jobs on fresh hosted VMs, the policy workflow runs for PRs to `main`, and a push to `main` runs the four CI jobs. Approve a fork workflow run first if GitHub holds it for review.
   Manual check on a real Apple Silicon Mac before merge: run full `swift test` (including T1 `SystemTests`), `scripts/check-compile-fail.sh`, and `scripts/smoke-products.sh` against the Debug products. Link the results in the task PR; do not run these host-dependent checks on the hosted VM.
 7. **Branch protection and negative tests.** On `main`, require the five checks plus one approving review, and forbid force pushes (see [../../05-development/workflow.md](../../05-development/workflow.md)). Open a draft pull request that adds `import RuntimeCore` to `Apps/APKRun/` and a `TODO` without a number. Confirm that `lint` fails with both messages, then close it. Also verify that a pull request changing `.github/workflows/ci.yml` to skip a required job fails `workflow-policy` without a current-head approval and label, and passes that check only after both are present.

   Check: the negative draft PR results for `lint` and `workflow-policy` are linked in this task's pull request.
   Repository setup: create the `ci-policy-approved` label. The non-author human reviewer applies it last, after approving the exact current head. Removing it revokes the policy check. Any later label event or PR edit resets `workflow-policy`; the same reviewer removes and reapplies this label after confirming the review remains current. If they withdraw the policy approval, they remove the label.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

The workflow-policy fixtures also cover Cargo manifests and locks, the pinned
Rust toolchain, Cargo config, rustfmt and Clippy settings. These files can
change the `cargo fmt --check` run when Rust sources are present.

- **T0** (`scripts/tests/`, run by `lint`):
  - `check-module-deps.sh` rejects each forbidden fixture ([../test-strategy.md](../test-strategy.md) §6.1: "rejects a fixture manifest with a forbidden edge") and accepts the valid one;
  - the graph parser reads the current [modules.md](../../01-architecture/modules.md) §3 blocks into the expected edge list;
  - the lock rules;
  - the TODO rules;
  - the format check;
  - the release checks: a fixture bundle whose binary contains the string `APKRUN_STORE_FAULT` fails, one that contains a public key from `Tests/Fixtures/signing/` fails, and a clean one passes.
  - the workflow security configuration: every source-executing job uses the fresh `xcode-27` runner; checkout credentials are not persisted; the metadata-only policy job checks out trusted `main` and never PR source; fixtures cover missing, stale, self, withdrawn, bot, and mismatched labeler approvals; base-revision changes; label revocation; code generators, dependency pins, tool-version and formatter settings, Xcode build-phase scripts, Gradle wrapper/build/convention logic, per-module Gradle lockfiles, manifests, test trees, and the module graph; PR edits; renamed control files; and the GitHub compare API changed-file limit.
- **T1**: no new T1 fixtures. Before merge, run full `swift test`, `scripts/check-compile-fail.sh`, and the Debug product smoke test on a real Apple Silicon Mac; the hosted `test-swift` job runs T0 only.
- **T2**: none.
- **T3**: none.

### Acceptance criteria

- [ ] `ci.yml` runs `lint`, `codegen`, `build`, and `test-swift` on every pull request and push to `main`; `workflow-policy` runs for PRs targeting `main`; all five checks are required on `main`.
- [ ] A PR changing protected control files cannot skip required checks unless the same non-author human approved its current head and applied `ci-policy-approved`; a commit, reopen, edit, or later label event resets the check, and removing the label revokes `workflow-policy`.
- [ ] Fork pull request source runs only on a fresh GitHub-hosted macOS VM; no `pull_request` job can access a persistent self-hosted runner.
- [ ] A forbidden import edge, a forbidden trait edge, and a third-party import outside its allowed module each fail `lint` with a message that names the file and the rule.
- [ ] A `TODO` or `FIXME` without a task number fails `lint` (NFR-DEV-04).
- [ ] A lock entry pinned by a branch name or a short hash, or a Swift package pin missing from the lock, fails `lint` (NFR-DEV-01).
- [ ] A `Helpers/`-style directory, or a production import from `Experiments/`, fails `lint` (NFR-DEV-05).
- [ ] Stale generated code fails `codegen`.
- [ ] `build` proves a clean checkout builds (NFR-DEV-02), including the CLI with the `EmbeddedRuntime` trait. A real Mac manual check runs `scripts/smoke-products.sh` on Debug products before merge.
- [ ] Full Swift T0/T1 tests pass on a real Apple Silicon Mac before merge; hosted `test-swift` runs only T0.
- [ ] `build` runs `check-release-build.sh` on the Release APKRun.app, and a test hook or a test key in it fails the job.
- [ ] Local repository checks run with no arguments; the policy check fails closed without GitHub context and its decision logic is covered by offline fixtures.
- [ ] The negative-test pull request failed as expected.

### Notes

- **Record:** the required checks and the branch rules go into [../../05-development/workflow.md](../../05-development/workflow.md).
- **Local verification:** `scripts/ci/run-checks.sh`, `swift test --skip 'SystemTests' -j 2`, full `swift test`, `scripts/smoke-products.sh` on Debug products, and `scripts/release/check-release-build.sh` on the Release app all passed on the Apple Silicon host. Debug and Release `xcodebuild` jobs also passed. The live GitHub Actions run, branch protection, and negative-test pull request remain unverified because this checkout has no Git remote.
- **Pitfall:** `swift package dump-package` does not show source imports. Without the import scan, the CLI could import RuntimeCore through RuntimeHost unnoticed.
- **Pitfall:** GitHub keeps a required check "pending" forever when a workflow is skipped by a `paths:` filter. The current #003 `linux-guest` workflow is a trusted-main regression check, not a required PR check. If a future change enables PR runs, use a job that always reports a result and decides from the changed files.
- **Pitfall:** hosted macOS runners are VMs. Use them for static checks, builds, and T0 tests only. Run host-dependent T1 checks on a real Apple Silicon Mac ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §6).
- **Pitfall:** `ci-policy-approved` is a narrow CI-control approval, not a substitute for the pull request's required review. The non-author reviewer who approved the exact current head applies it; removing it revokes the policy check. Any new commit, reopen, PR edit, or label event requires a fresh policy-label event.
- `check-lock.sh` runs in two jobs ([../../05-development/build-system.md](../../05-development/build-system.md) §3, §15.1). The `lint` job runs the file checks. The `third-party` job, from #020 on, runs `check-lock.sh --apply` after it checks out the sources.
- The allowed graph is parsed from [../../01-architecture/modules.md](../../01-architecture/modules.md) §3, which lists `apkrun → RuntimeAPI` and ArgumentParser. A change to the graph is a change to that document.

---

## #002 VMDefinition and VM validation

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #001 |
| Requirements | FR-VM-01 (definition part), FR-VM-07 (state table), NFR-RES-01 (the defaults and the memory cap in validation). Constraints: NFR-DEV-03 |
| Design | [../../02-design/vm.md](../../02-design/vm.md) §2, §3, §4, §7, §10, §13, §15; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1; [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.2; [../../02-design/graphics.md](../../02-design/graphics.md) §3.2 (descriptor only) |
| Modules / paths | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Definition/`, `Validation/`, `Framework/`, `State/`, `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/` (with `Fixtures/kernel-headers/`), `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTestSupport/`, `Packages/VirtioDeviceCore/Sources/VirtioDeviceCore/` (descriptor and protocol only), `Packages/DiagnosticsCore/ErrorCatalog/errors.json` |
| Risks / questions | None |

### Goal

A `VMDefinition` value describes a VM without Android concepts. `VMDefinitionValidator` accepts only definitions that Virtualization.framework can boot, and reports every broken rule with a typed error. No `VZVirtualMachine` is created.

### Scope

- The value types of [../../02-design/vm.md](../../02-design/vm.md) §2, and `VMDefinition.summary`.
- `VMDefinitionValidator` with every rule of §3, the typed failures, and the collection of several failures.
- The VZ configuration builder (§4 mapping), used by validation to call `VZVirtualMachineConfiguration.validate()`, behind a seam.
- `VMState` and its transition table as a pure value ([../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1).
- Generating and persisting the machine identifier and the MAC address.
- The `VirtioDeviceDescriptor` and `VirtioDeviceModel` declarations that `VMDefinition.customDevices` needs.

Out of scope:

- `VMController` and every VZ lifecycle call (#003) ("Do not instantiate `VZVirtualMachine` yet").
- Console pipes (#003, #004).
- The rest of VirtioDeviceCore and the custom device adapter (#063).
- `instance.json` itself. RuntimeCore and ImageCore own it; this task only provides `Codable` values.
- The settings limits of §10 (2…8 vCPUs, 3 GiB minimum). RuntimeCore applies them before it builds a definition. The validator enforces only §3.

### Deliverables

- `Definition/`:
  - `VMDefinition.swift`: `VMDefinition`, `BootDefinition`, `DiskDefinition`, `DiskCaching`, `DiskSync`, `NetworkDefinition`, `ConsolePortDefinition`, `ConsoleRole`, `SoundDefinition`;
  - `VMDefinitionSummary.swift`;
  - `MachineIdentity.swift`.
- `Validation/`:
  - `VMDefinitionValidator.swift`;
  - `ValidatedVMDefinition.swift`;
  - `VMConfigurationFailure.swift`;
  - `KernelImageInspector.swift`;
  - `VMHostEnvironment.swift`;
  - `FrameworkConfigurationValidator.swift`.
- `Framework/VZConfigurationBuilder.swift`.
- `State/VMState.swift` and `State/VMStateTransitions.swift`. `VMState.failed` carries `VMFailure`, which is declared here with the cases of [vm.md](../../02-design/vm.md) §13 and filled in by #003.
- `VirtualMachineCoreTestSupport`: a fake `VMHostEnvironment`, a fake `FrameworkConfigurationValidator`, and definition builders for tests.
- `Fixtures/kernel-headers/`, 64-byte headers: `image-arm64.bin`, `gzip.bin`, `lz4-legacy.bin`, `lz4-frame.bin`, `zboot-gzip.bin`, `x86-bzimage.bin`, `zeros.bin`.
- The `vm.*` catalog fixture list for the catalog conformance test of #061.

### Implementation steps

1. **Value types (§2).**
   - Add the types exactly as declared in §2.
   - `VMDefinition` is a `Sendable` value. `customDevices` holds `any VirtioDeviceModel`.
   - Add the minimal `VirtioDeviceDescriptor` and `VirtioDeviceModel` of [../../02-design/graphics.md](../../02-design/graphics.md) §3.2 to VirtioDeviceCore, with no VZ adapter yet. #063 completes them.
   - `VMDefinitionSummary` is the `Codable` projection with no device objects: the paths reduced to file names, the disk roles and flags, the port roles, and the custom device names. Log it under `io.apkrun.vm`, category `config`.

   Check: T0 encodes a summary and finds no full path in it.
2. **Host environment seam.** `VMHostEnvironment` provides:
   - the active processor count;
   - physical memory;
   - VZ's `minimumAllowedCPUCount`, `maximumAllowedCPUCount`, `minimumAllowedMemorySize`, and `maximumAllowedMemorySize`;
   - a file probe (exists, regular file, size, first 64 bytes, readable, writable);
   - the host bundle's `NSMicrophoneUsageDescription`.

   The live implementation uses `ProcessInfo`, VZ, and `FileManager`. The fake lives in `VirtualMachineCoreTestSupport`.

   Check: every rule in step 3 reads the host only through this seam.
3. **Rules (§3).** Implement every row of the §3 table in order.
   - CPU count, memory limits, and the 50 % cap (NFR-RES-01).
   - Kernel checks (`KernelImageInspector`):
     - `ARM\x64` at 0x38–0x3B is an uncompressed arm64 `Image`.
     - `1f 8b` is `.gzip`.
     - `02 21 4c 18` and `04 22 4d 18` are `.lz4`.
     - `MZ` followed by `zimg` at offset 4 is `.zboot`, an EFI zboot kernel.
     - Anything else is `.unknown`, including unsupported architectures.
   - initrd at most 512 MiB. Command line at most 2048 bytes, ASCII only.
   - Disks:
     - each disk exists and is a regular file;
     - Android sparse images (magic `0xED26FF3A`) are rejected;
     - no disk URL appears twice (compared after resolving symlinks);
     - read-write disks are writable;
     - `.none` synchronization is rejected because it is reserved for tests;
     - identifiers are at most 20 ASCII characters.
   - Console port 0 is `.systemConsole`.
   - The MAC is valid: locally administered unicast.
   - Custom devices: each descriptor passes its own checks (name non-empty, at least one queue). #063 adds the VZ-level checks.
   - The microphone usage description is present when `sound.input` is set.
   - When no local rule fails, `FrameworkConfigurationValidator` builds the VZ configuration with `VZConfigurationBuilder` and calls `validate()`. A failure maps to `.frameworkRejected(underlying:)`, with the domain and code only. Skip this check when local rules fail so invalid inputs do not produce secondary framework errors.
   - The machine identifier, when present, must decode with `VZGenericMachineIdentifier(dataRepresentation:)`. Otherwise the validator raises `.machineIdentifierInvalid` ([vm.md](../../02-design/vm.md) §3; [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.2, exit 70).

   Check: one T0 test per rule passes.
4. **Collecting failures.** `validate(_:) throws(VMConfigurationFailure) -> ValidatedVMDefinition` runs every rule before throwing.
   - One failure is thrown as itself.
   - Several failures are thrown as `.configurationInvalid([VMConfigurationFailure])`, the case proposed by [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.2. The list is flat, in rule order.
   - `findings(_:) -> [VMConfigurationFailure]` returns the same list without throwing, for `apkrun doctor`.
   - `ValidatedVMDefinition` has an internal initializer, so only the validator can create one.

   Check: T0 shows a definition with three broken rules yielding one `.configurationInvalid` with three items in rule order.
5. **VZ configuration builder (§4).** `VZConfigurationBuilder` maps the definition to a `VZVirtualMachineConfiguration`:
   - platform with `machineIdentifier`;
   - `VZLinuxBootLoader`;
   - CPU and memory;
   - storage devices in array order with `blockDeviceIdentifier`;
   - NAT network with the MAC;
   - one vsock device when enabled;
   - one `VZVirtioConsoleDeviceSerialPortConfiguration` per port;
   - entropy;
   - balloon;
   - sound.

   Console attachments come from a parameter. Validation opens `/dev/null` handles, and #003 passes real pipes. Custom devices are left out until #063 adds the adapter.

   Check: T0 inspects a built configuration: disk order, identifiers, port count, and that there is no graphics, keyboard, or pointing device.
6. **State table.** `VMState` is the enum of [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1. `VMStateTransitions.isAllowed(from:to:)` encodes exactly the table's edges.

   Check: T0 iterates every (from, to) pair and asserts that exactly the table's edges are allowed.
7. **Identity values.**
   - `MachineIdentity.newMachineIdentifier()` returns `VZGenericMachineIdentifier().dataRepresentation`.
   - `MachineIdentity.newMACAddress()` returns `VZMACAddress.randomLocallyAdministered().string`.
   - Both round-trip through `Codable` so that RuntimeCore can store them in `instance.json` (§4, §7).

   Check: the T0 round-trip test passes, and 1,000 generated MACs are all valid under the step 3 rule.
8. **Errors.**
   - `VMConfigurationFailure` conforms to `APKRunError` with domain `vm` and the codes of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.2.
   - `parameters` carry only public-safe values: role names, counts, and byte sizes, never paths ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §2.1).
   - Add the fixture list to the catalog conformance test.

   If #061 step 4 has not been merged yet, the type conforms to `Error, Equatable`, and this step lands when #061 step 4 does. #002 is not done before then.

   Check: the catalog conformance test passes for every case.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`):
  - one test per §3 rule, with valid and invalid values ([../../02-design/vm.md](../../02-design/vm.md) §15);
  - kernel detection with the real 64-byte headers of `Fixtures/kernel-headers/`;
  - failure collection, and the flat list;
  - `findings(_:)`;
  - the VZ configuration mapping;
  - every state edge, allowed and forbidden;
  - MAC and machine identifier generation, and their round trip;
  - summary privacy;
  - catalog conformance.
- **T1**: `VZVirtualMachineConfiguration.validate()` for real, when the test runner allows it (see Notes). The real file and permission cases come with #005.
- **T2**: covered by #003, which validates and boots real definitions.
- **T3**: none.

### Acceptance criteria

- [x] Unit tests cover valid and invalid configurations.
- [x] Validation covers:
  - the CPU count;
  - memory minimum and maximum;
  - a missing kernel;
  - a missing disk;
  - an invalid architecture (a kernel that is not an uncompressed arm64 `Image`, including gzip, lz4, and zboot).
- [x] No `VZVirtualMachine` is created by this task's code.
- [x] Every rule of [../../02-design/vm.md](../../02-design/vm.md) §3 has a failure case, a catalog entry, and a T0 test.
- [x] Several broken rules produce one `.configurationInvalid` with every failure. One broken rule produces that failure itself.
- [x] Only `VMDefinitionValidator` can create a `ValidatedVMDefinition`.
- [x] The transition table allows exactly the edges of [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1.
- [x] Generated MACs are locally administered unicast addresses. The MAC and the machine identifier survive a `Codable` round trip.
- [x] No path appears in an error parameter or in the logged summary.

### Notes

- **Record:** whether `VZVirtualMachineConfiguration.validate()` works under `swift test` without the virtualization entitlement goes into [../../02-design/vm.md](../../02-design/vm.md) §3.
  - If it works, the T1 test runs it.
  - If it does not, T0 and T1 use the `FrameworkConfigurationValidator` fake, and the real call is covered by #003 in T2.
- **Pitfall:** Alpine and other distributions may ship arm64 kernels as EFI zboot images, which start with `MZ` rather than the `Image` header. The validator rejects them. `scripts/fetch-test-linux.sh` (#003) must extract the payload.
- **Pitfall:** creating VZ configuration objects is fine in T0. Never create a `VZVirtualMachine` from a configuration that did not pass `validate()`; VZ raises an Objective-C exception instead of throwing.
- The zboot detection and `.machineIdentifierInvalid` were added to [vm.md](../../02-design/vm.md) §3 and [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.2 for this task.

---

## #003 Boot minimal ARM64 Linux

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #002 |
| Gate | G1 |
| Requirements | FR-VM-01, FR-VM-07. Constraints: NFR-DEV-01 (the test kernel and rootfs are pinned) |
| Design | [../../02-design/vm.md](../../02-design/vm.md) §2, §4, §6.3, §9, §12, §13, §14, §15; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1; [../../01-architecture/decisions/0002-virtualization-framework-macos27.md](../../01-architecture/decisions/0002-virtualization-framework-macos27.md); [../../01-architecture/decisions/0015-direct-kernel-boot.md](../../01-architecture/decisions/0015-direct-kernel-boot.md); [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §2.3, §10; [../../02-design/cli.md](../../02-design/cli.md) §5; [../roadmap.md](../roadmap.md) §2 (G1); [../test-strategy.md](../test-strategy.md) §2.4, §3.4, §5; [../../05-development/build-system.md](../../05-development/build-system.md) §2.2, §6.5, §12.2, §12.4, §15.1; [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §4 |
| Modules / paths | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/` (`Controller/`, `Console/`, `TestGuest/`, `Health/`), `Packages/VirtualMachineCore/Tests/`, `Packages/RuntimeCore/Sources/RuntimeCore/Dev/`, `Packages/RuntimeHost/Sources/RuntimeHost/` (`Dev/`, `InstanceLock.swift`), `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`, `CLI/apkrun/Dev/DevLinux.swift`, `scripts/fetch-test-linux.sh`, `scripts/build-test-initramfs.sh`, `scripts/run-gate.sh`, `Tests/Fixtures/linux/` (`init`, `modules.list`), `Tests/IntegrationTests/` (`Host/`, `LinuxGuestTests/`, `IntegrationTests.xctestplan`), `Tests/AcceptanceTests/` (`G1LinuxBoot/`, `AcceptanceTests.xctestplan`), `ThirdParty/ThirdParty.lock.json`, `project.yml`, `.github/workflows/integration.yml`, `.github/workflows/nightly.yml` |
| Risks / questions | R-16 (the VZ behavior checked here is re-run on new macOS builds); OQ-02 (the reference Mac on which G1 must pass) |

### Goal

A pinned ARM64 Linux kernel and a minimal initramfs boot through `VZLinuxBootLoader` under `VMController`. `APKRUN-TEST: boot ok` appears on `hvc0`. The VM goes `stopped → starting → running → stopping → stopped`, and a failed start ends in `failed` with a typed error. Ten boots in a row pass on the reference Mac, which closes G1.

### Scope

- `VMController` with the API of [../../02-design/vm.md](../../02-design/vm.md) §2 plus `reset()` (§9.6), on the private queue `io.apkrun.vm.queue`, behind a `VirtualMachineDriver` seam.
- `VMFailure` and `VZErrorInfo` (§13). The delegate mapping (§9.2).
- The `vm.state` and `vm.virtualizationSupported` health checks (§14).
- A minimal `ConsoleChannel` for `hvc0` (read side only). #004 completes it.
- The test Linux guest: fetch and build scripts, `/init` steps 1, 2, and 4 of §12, power-off on the power key, and the lock entries.
- `LinuxTestGuest` (the definition builder) and `TestGuestLineParser`.
- The T2 infrastructure:
  - `APKRunTestHost`;
  - the `IntegrationTests` target, scheme, and test plan;
  - `LinuxGuestTests`;
  - the `linux-guest` job in `integration.yml`.
- `apkrun dev linux` in the Debug CLI, with the instance lock.
- G1:
  - the `AcceptanceTests` target, scheme, and test plan;
  - `Tests/AcceptanceTests/G1LinuxBoot`;
  - `scripts/run-gate.sh`;
  - the `gates` job in `nightly.yml`.

Out of scope:

- `ConsoleLogWriter`, the extra console ports, host writes, and `apkrun dev console` (#004).
- Disks (#005), the network device (#006), and vsock (#007). The test guest in this task has none of them.
- Custom devices (#063). `--window` and virtio-gpu (#019).
- Pause, resume, and host sleep (#069). RuntimeSupervisor and Android boot (#012–#014).
- The 20 s guest-stop timeout, which belongs to RuntimeCore ([../../02-design/vm.md](../../02-design/vm.md) §9.3).

### Deliverables

- `Controller/`:
  - `VMController.swift`;
  - `VMFailure.swift`;
  - `VZErrorInfo.swift`;
  - `VirtualMachineDriver.swift` (the protocol and its event stream);
  - `VZVirtualMachineDriver.swift`.
- `Console/ConsoleChannel.swift` (read side).
- `Health/VMHealthChecks.swift`.
- `TestGuest/LinuxTestGuest.swift` and `TestGuest/TestGuestLineParser.swift`.
- `FakeVirtualMachineDriver` in `VirtualMachineCoreTestSupport`.
- In RuntimeCore, `Dev/LinuxTestGuestRunner.swift`. In RuntimeHost:
  - `Dev/DevLinux.swift`, the facade the CLI uses, with its own options and event types;
  - `InstanceLock.swift`.
- `CLI/apkrun/Dev/DevLinux.swift` (compiled only with `APKRUN_EMBEDDED_RUNTIME`).
- The test Linux guest:
  - `scripts/fetch-test-linux.sh`;
  - `scripts/build-test-initramfs.sh`;
  - `Tests/Fixtures/linux/init` (POSIX `sh`);
  - `Tests/Fixtures/linux/modules.list`.
- Lock entries (`kind: prebuilt`, `ships: tooling`, full `sha256`) for:
  - the Alpine `linux-virt` package;
  - the Alpine minirootfs;
  - `socat` and its runtime dependencies (used by #007, pinned now so the initramfs layout is final);
  - `libgpiod` and its license files for the Linux guest power-input monitor.
- `project.yml` additions:
  - the `APKRunTestHost` target (`Tests/IntegrationTests/Host/`, with `APKRunTestHost.entitlements` holding `com.apple.security.virtualization`, [../../05-development/build-system.md](../../05-development/build-system.md) §12.2);
  - the `IntegrationTests` and `AcceptanceTests` unit-test bundles, both hosted by `APKRunTestHost`;
  - the `IntegrationTests` and `AcceptanceTests` schemes.
- The test plans:
  - `Tests/IntegrationTests/IntegrationTests.xctestplan`, with configuration `LinuxGuest` and one automatic retry;
  - `Tests/AcceptanceTests/AcceptanceTests.xctestplan`, with configuration `G1` and no retry.
- `Tests/IntegrationTests/LinuxGuestTests/` (`LinuxGuestHarness.swift`, `BootTests.swift`) and `Tests/AcceptanceTests/G1LinuxBoot/G1LinuxBootTests.swift`.
- `scripts/run-gate.sh`, `.github/workflows/integration.yml` (job `linux-guest`), and `.github/workflows/nightly.yml` (job `gates`).

### Implementation steps

1. **Errors.**
   - `VZErrorInfo` is a `Sendable`, `Equatable` copy of an `NSError`: domain, code, and description. The description goes to the log only.
   - `VMFailure` has the cases of §13 and conforms to `APKRunError`. `underlying` is the domain and code.
   - Add the catalog fixture list.

   Check: catalog conformance passes for `VMFailure`.
2. **Driver seam.**
   - `VirtualMachineDriver` wraps one `VZVirtualMachine`: `start`, `stop`, `requestStop`, `pause`, and `resume`, as async calls. It publishes an `AsyncStream` of `guestDidStop`, `didStopWithError`, and `networkAttachmentDisconnected` events.
   - `VZVirtualMachineDriver` creates the `VZVirtualMachine(configuration:queue:)` on `io.apkrun.vm.queue`. It calls VZ only on that queue, and bridges completion handlers with `withCheckedThrowingContinuation` (§4). In debug builds it asserts the queue with `dispatchPrecondition`.
   - `FakeVirtualMachineDriver` scripts results and events.

   Check: the driver compiles with strict concurrency, and the fake drives every event.
3. **VMController.**
   - Implement the §2 actor with `reset()` added. The state lives only in `VMState`.
   - `stateUpdates` yields every state in order.
   - `start()`:
     1. Changes `stopped → starting` and records `Perf.mark(.vmStart)`.
     2. Builds the VZ configuration with real console pipes through `VZConfigurationBuilder`.
     3. Calls `validate()`, creates the driver, and starts it.
     4. Success leads to `running`. A validation or start error leads to `failed(.startFailed(underlying:))` ([../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1).
   - `stop()` (forced) and `requestGuestStop()` change `running` or `paused` to `stopping`. `guestDidStop`, or completion of the forced stop, then leads to `stopped`.
   - The forced stop fails with `.stopTimedOut` if it has not completed after 10 s (see Notes).
   - The delegate mapping follows §9.2.
   - `reset()` is allowed only in `failed`. It releases the VZ objects, closes the pipes, and changes the state to `stopped` (§9.6).
   - A public call whose edge is not in the table throws `.invalidTransition(from:to:)` and logs a `fault`. An internal transition that breaks the table raises `assertionFailure` in debug builds ([../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1).
   - Every transition is logged at `info` under `io.apkrun.vm`, category `lifecycle`, with the operation ID.
   - Register `vm.state` and `vm.virtualizationSupported` (`VZVirtualMachineConfiguration.isSupported`).

   Check: the T0 controller tests pass with the fake driver.
4. **Console read side.**
   - `ConsoleChannel` owns two pipes per port (§6.3). It reads the guest-to-host pipe with `DispatchIO` and publishes `AsyncStream<Data>`.
   - The controller creates one channel per `consolePorts` entry. `console(_:)` returns it.
   - `TestGuestLineParser` splits the stream into lines and yields `APKRUN-TEST:` records: `bootOK`, `check(name, ok|fail, detail)`, and `done`.

   Check: T0 parser tests pass, including lines split across reads and an interleaved kernel log.
5. **Test guest artifacts** ([../../02-design/vm.md](../../02-design/vm.md) §12, [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §4).
   - `scripts/fetch-test-linux.sh`:
     1. Downloads the pinned `linux-virt` package and minirootfs into `${APKRUN_TEST_LINUX_DIR:-/tmp/apkrun-test-linux}/`.
     2. Verifies their SHA-256 against the lock file.
     3. Extracts the kernel and modules.
     4. Makes the kernel an uncompressed `Image`: it gunzips a gzip kernel, and for a zboot kernel it extracts the payload from the offset and size in its header, then decompresses it.
     5. Fails unless the result has the `ARM\x64` magic.
   - `scripts/build-test-initramfs.sh` builds `initramfs.cpio.gz` (cpio `newc`, gzip) from:
     - the minirootfs;
     - the modules named in `Tests/Fixtures/linux/modules.list`, with their `modules.dep` entries;
     - the pinned `socat` and `libgpiod` packages;
     - `Tests/Fixtures/linux/init`.

     It uses only `cpio` and `gzip` from macOS.
   - `/init`:
     1. Mounts `proc`, `sys`, and `devtmpfs`.
     2. Redirects its own stdio to `/dev/hvc0`.
     3. Loads the modules.
     4. Unless `apkrun.test.poweroff=1`, resolves the PL061 chip by label and starts pinned `gpiomon` on the verified offset 6. It uses `gpioinfo` to confirm the line is held by the monitor. If the chip or line request cannot be opened, it reports an init failure and attempts to power off.
     5. Prints `APKRUN-TEST: boot ok`, then `APKRUN-TEST: powerinput ok PL061 offset 6 line request confirmed`.
     6. Runs the checks named in `apkrun.test=`. There are none in this task; later tasks add blocks.
     7. Prints `APKRUN-TEST: done`.
     8. Powers off when `apkrun.test.poweroff=1`; otherwise keeps a shell available on `hvc0` and waits for the monitor. The rising GPIO edge maps to `poweroff -f`.
   - Add the lock entries with a `url` member for each download (see Notes).

   Check: both scripts run on a clean clone, twice in a row with the same output hashes.
6. **Test guest definition.** `LinuxTestGuest.definition(kernel:initrd:tests:powerOff:extraCommandLine:)` builds a `VMDefinition`:
   - 2 vCPUs, 1 GiB, one `.systemConsole` port, entropy on;
   - no disks, network, or vsock unless a later task's check asks for them;
   - command line `console=hvc0 apkrun.test=<list> apkrun.test.poweroff=<0|1>`.

   The default artifact directory is `APKRUN_TEST_LINUX_DIR`, or `/tmp/apkrun-test-linux/`; an override must be absolute and outside `~/Documents`, including through symlink aliases. The fetch/build scripts and hosted test reject a Documents path before accessing guest artifacts.

   Check: the definition passes `VMDefinitionValidator` with the fetched artifacts.
7. **T2 harness.**
   - `APKRunTestHost` is an app with no UI of its own, signed with the virtualization entitlement.
   - `LinuxGuestHarness` does the following:
     1. Boots a `LinuxTestGuest` through `VMController` (VirtualMachineCore only, §12).
     2. Parses `hvc0` from an oldest-preserving bounded stream and captures the newest 4 MiB from a second bounded stream for `XCTAttachment`; each stream's dropped-byte count is included in the attachment.
     3. Fails when a check prints `fail`, when a requested check prints nothing, or when `done` does not appear within 60 s ([../test-strategy.md](../test-strategy.md) §3.4).
   - Missing artifacts skip the test with a message that names both scripts. With `APKRUN_CI=1`, missing artifacts fail it.
   - `BootTests` covers:
     - boot ok and done with power-off;
     - boot with `apkrun.test.poweroff=0`, then `requestGuestStop()`;
     - boot, then `stop()`;
     - a failed start, then `reset()`.
   - `integration.yml` has the `linux-guest` job on `apkrun-lab`, triggered by matching pushes to `main` and manual dispatch from `main`. Its path filter is in [../../05-development/build-system.md](../../05-development/build-system.md) §15.1. It does not run pull-request source on the persistent lab Mac; until disposable lab capacity exists, a maintainer runs the reviewed commit and links the result before the task-closing PR merges. It runs `xcodebuild test -project APKRun.xcodeproj -scheme IntegrationTests -testPlan IntegrationTests -configuration Debug -only-test-configuration LinuxGuest` ([../../05-development/build-system.md](../../05-development/build-system.md) §12.4).

   Check: the `LinuxGuest` suite passes on a lab Mac.
8. **`apkrun dev linux`.** The path is CLI `Dev/DevLinux.swift` → RuntimeHost `DevLinux` → RuntimeCore `LinuxTestGuestRunner` → VirtualMachineCore, which keeps the edges of [modules.md](../../01-architecture/modules.md) §3.
   - Options are those of [../../02-design/cli.md](../../02-design/cli.md) §5 except `--window`, which comes with #019:
     - `--kernel`, `--initrd`, `--tests <list>`, and `--timeout <s>` (default 60);
     - with no `--tests`, only boot ok and done are expected.
   - Before booting, RuntimeHost takes `InstanceLock`: `Runtime/instance.lock` under the dev data root, with `flock(LOCK_EX | LOCK_NB)`, holding the owner `apkrun-dev`, the PID, and the binary path ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §2.3). A held lock fails with `runtime.instanceLocked`, exit 75. When `APKRUN_HOME` points elsewhere, the command prints the memory warning of [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §2.3. #031 reuses this `InstanceLock`.
   - The command prints the kernel log and the `APKRUN-TEST:` lines as they arrive. It exits 0 only when every requested check printed `ok`. Otherwise it prints the failing lines on stderr and exits 1.

   Check: `apkrun-dev dev linux` exits 0, and a second instance started meanwhile exits 75.
9. **G1.**
   - `G1LinuxBootTests` runs these assertions, all on a clean build from `main` on the reference Mac (OQ-02):
     - (a) Ten boots in a row, each with `apkrun.test.poweroff=0`. Each boot asserts `APKRUN-TEST: boot ok` on `hvc0`, `done`, and then `requestGuestStop()`. The state sequence recorded from `stateUpdates` must be exactly `stopped, starting, running, stopping, stopped`.
     - (b) One failed start (see Notes) must end in `failed(.startFailed)` with a `VZErrorInfo`, and `reset()` must then lead to `stopped`.
   - `scripts/run-gate.sh G<n>`:
     1. Checks that the tree is clean and is on `main`.
     2. Runs `scripts/generate-project.sh`, then `xcodebuild test -scheme AcceptanceTests -testPlan AcceptanceTests -only-test-configuration G<n>` with an empty DerivedData.
     3. Writes a report and the xcresult into `build/gates/G<n>/`.
     4. Never retries.
   - `nightly.yml`'s `gates` job runs `scripts/run-gate.sh` for every closed gate on `apkrun-reference`.
   - Attach the evidence to the G1 gate issue. Add G1's date, Mac model, and macOS build to the Verification section of ADR-0002.

   Check: `scripts/run-gate.sh G1` passes on the reference Mac.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`, with `FakeVirtualMachineDriver`):
  - start success and failure;
  - validation failure at start leading to `failed`;
  - the delegate mapping of §9.2 (`guestDidStop` from running and from stopping; `didStopWithError`; a network disconnect keeping `running`);
  - `stop()` and `requestGuestStop()` paths;
  - `.stopTimedOut`;
  - `reset()` from `failed` only;
  - `.invalidTransition` for public calls in the wrong state;
  - the `stateUpdates` order;
  - `TestGuestLineParser`;
  - the `vm.state` health check;
  - catalog conformance of `VMFailure`.
- **T1** (`Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`): `InstanceLock` contention, using two open file descriptions in one process; release on close.
- **T2** (`Tests/IntegrationTests/LinuxGuestTests/`, suite `LinuxGuest`): boot and the console marker; `requestGuestStop()` and `stop()` paths; failed start and `reset()`.
- **T3** (`Tests/AcceptanceTests/G1LinuxBoot`, through `scripts/run-gate.sh G1`): the G1 pass conditions of [../roadmap.md](../roadmap.md) §2. Manual: `apkrun-dev dev linux` prints the lines and exits 0, and a held lock gives exit 75. Record this in the pull request.

### Acceptance criteria

- [ ] A minimal ARM64 Linux kernel reaches userspace through `VZLinuxBootLoader`, `VZVirtualMachineConfiguration`, and a minimal initramfs.
- [ ] The serial output on `hvc0` includes the known boot marker `APKRUN-TEST: boot ok`.
- [ ] `VMController` goes `stopped → starting → running` on start and `running → stopping → stopped` on stop, as recorded from `stateUpdates`.
- [ ] A failed start ends in `failed` with a typed `VMFailure` that carries a `VZErrorInfo`. `reset()` returns to `stopped`.
- [ ] G1 passes on the reference Mac with a clean build from `main`: ten boots in a row, with the evidence attached to the gate issue.
- [ ] VZ objects are created and called only on `io.apkrun.vm.queue`.
- [ ] No state is inferred from a nil `VZVirtualMachine` ([../../../AGENTS.md](../../../AGENTS.md) §6.2).
- [ ] Every transition is logged with its operation ID under `io.apkrun.vm`, category `lifecycle`.
- [ ] `apkrun-dev dev linux` prints the boot output live and exits 0 only when every requested check printed `ok`. It refuses to run while another owner holds the instance lock (exit 75).
- [ ] The test kernel, minirootfs, and packages are pinned by SHA-256 in `ThirdParty/ThirdParty.lock.json` (NFR-DEV-01). The fetch and build scripts produce the same artifacts on a clean clone.
- [ ] Without the artifacts, the T2 tests skip with a message that names both scripts. With `APKRUN_CI=1`, they fail.
- [ ] `linux-guest` runs on matching pushes to `main` and by manual dispatch from `main`; a maintainer-run T2 result for the reviewed commit is linked before the task-closing PR merges until disposable lab capacity enables PR runs. `gates` runs G1 nightly.

### Notes

- **Record:**
  - The G1 result goes into ADR-0002 Verification and the G1 gate issue.
  - Whether VZ reports a failed start through the `start` completion or through `validate()` goes into [../../02-design/vm.md](../../02-design/vm.md) §9.1.
  - The measured boot time of the test guest goes into the pull request, for later comparison.
- **Pitfall:** the initramfs holds no `/dev/console` node, because macOS cannot create device nodes without root. `/init` must mount `devtmpfs` and redirect its stdio before it prints anything.
- **Pitfall:** check whether `virtio_console`, `virtio_pci`, and `gpio_pl061` are built into `linux-virt` or are modules, using the package's kernel config. List only the real modules in `modules.list`. The test guest reads the VZ power input through the GPIO character-device API, so it does not need `gpio_keys`.
- **Pitfall:** Alpine `.apk` files are several concatenated gzip streams. Check that macOS `tar` extracts all of the data. If it does not, split the streams in the fetch script.
- **Pitfall:** the failed-start assertion needs a start that VZ rejects after validation. Validate a copy of the kernel, delete the copy, and then call `start()`. If VZ rejects the missing file only when `start()` builds the configuration, the result is still `failed(.startFailed)`, as [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1 requires.
- The 10 s limit for a forced stop (`.stopTimedOut`) is a choice of this plan. It is recorded in [vm.md](../../02-design/vm.md) §9.3 and [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §1 (`stopping → failed`).
- Using a `url` member in prebuilt lock entries is also a choice of this plan. [../../05-development/build-system.md](../../05-development/build-system.md) §6.1 has no field for the download location, so add it there.
- The CLI command is checked manually in M0. [../../02-design/cli.md](../../02-design/cli.md) §6.2 says each task's T2 test runs through the command, but [../../02-design/vm.md](../../02-design/vm.md) §12 requires the harness to use VirtualMachineCore only. Here the harness follows vm.md.
- **Local verification:** hosted VZ tests require `APKRUN_TEST_DEVELOPMENT_TEAM` and `APKRUN_TEST_CODE_SIGN_IDENTITY`; neither is committed. See [../../05-development/environment-setup.md](../../05-development/environment-setup.md) §2.8.
- **G1 progress:** the initial 2026-09-30 T2 run timed out after `requestGuestStop()`. A later hvc0 capture identified `gpiochip0 [20060000.pl061]` and a rising event on offset 6. With a line-owner readiness check, the complete T2 suite and direct ten-boot G1 acceptance test passed on branch `codex`; a signed `apkrun-dev dev linux` smoke from `/tmp` printed boot, powerinput, and done, then exited 0. The clean-`main` `scripts/run-gate.sh G1` run remains pending, so #003 stays open.
- **TCC-safe test artifacts:** the local default is `/tmp/apkrun-test-linux`. Pass `APKRUN_TEST_LINUX_DIR` and `APKRUN_CI` as `xcodebuild` build settings; the hosted tests read them from `APKRunTestHost.app/Contents/Info.plist`.
- **TCC path-guard verification (2026-09-30):** seven script tests reject direct Documents paths, symlink aliases, a missing-component/parent-reference alias, and an overridden `HOME` before creating artifacts; three path-only `LinuxGuestArtifactDirectoryTests` XTests passed on macOS 27.0 with no VM start. The Swift default path is also symlink-resolved before use. `APKRUN_TEST_LINUX_DIR`, DerivedData, and the result bundle were under `/tmp`; no file-access prompt appeared.
- **Review before merge:** the pinned `socat` and ncurses tooling license expressions are outside the current §4.4 allowlist. The allowlist was not expanded; maintainers must resolve the dependency or accept a policy change before #003 can close.
- **Review before merge:** `linux-guest` currently runs only on trusted `main` pushes or manual dispatch. PR execution stays disabled until disposable lab runner capacity is available; meanwhile the task-closing PR must link a maintainer-run result for its reviewed commit, per [../../05-development/build-system.md](../../05-development/build-system.md) §15.1.
- **Local T2 setup:** place guest artifacts under `${TMPDIR}/apkrun-test-linux` when running the signed test host from a checkout under `~/Documents`; reading the kernel from the checkout can trigger macOS file-access approval. `scripts/run-gate.sh` and `integration.yml` select a temporary artifact directory automatically.

---

## #004 Serial console logging

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Requirements | FR-VM-02, NFR-REL-05. Constraints: NFR-SEC-05 (console logs are never parsed or redacted, and stay local) |
| Design | [../../02-design/vm.md](../../02-design/vm.md) §6, §14, §15; [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §3.3; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §2; [../../02-design/cli.md](../../02-design/cli.md) §5 |
| Modules / paths | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Console/` (`ConsoleChannel.swift`, `ConsoleLogWriter.swift`, `ConsoleLogFileSystem.swift`), `Packages/VirtualMachineCore/Tests/`, `Packages/RuntimeCore/Sources/RuntimeCore/Dev/`, `Packages/RuntimeHost/Sources/RuntimeHost/Dev/`, `CLI/apkrun/Dev/DevConsole.swift`, `Tests/Fixtures/linux/init`, `Tests/IntegrationTests/LinuxGuestTests/ConsoleTests.swift` |
| Risks / questions | R-16 (console port numbering can change with macOS) |

### Goal

Guest serial output is visible live and is written to `vm/console.log` under the logs root, with rotation and per-boot copies. The log survives a forced VM stop, a guest panic, and a crash of the host process up to at most 250 ms before the crash. The order in which VZ numbers console ports is verified with three ports.

### Scope

- The full `ConsoleChannel` with the host-to-guest pipe, and the role rules of [../../02-design/vm.md](../../02-design/vm.md) §6.3.
- `ConsoleLogWriter` (§6.4) with an injected clock and file system: line prefixes, rotation, per-boot copies, the flush and `fsync` policy, and the flush on `failed`, `stop`, and `reset`.
- Wiring `.systemConsole` to `ConsoleLogWriter`.
- The three-port numbering check (§6.2 step 1): the `ports` guest check.
- `apkrun dev console`, and the flood and panic modes of the test guest.
- The `vm.consoleWriter` health check.

Out of scope:

- The 20-port check (#095).
- `ConsolePortPlan` in RuntimeCore (#095 or later, if the numbering is not array order).
- `.log` capture into `guest/<name>-<timestamp>.log` (the logcat port, #060 and developer mode).
- `BootPhaseDetector` (RuntimeCore, #012 onward).
- Redaction (#060).

### Deliverables

- `ConsoleChannel.swift`: the read stream plus an optional writer. The writer exists only for `.systemConsole` (dev console) and `.service` ports.
- `ConsoleLogWriter.swift` and `ConsoleLogFileSystem.swift` (the protocol, the live implementation, and a fake in `VirtualMachineCoreTestSupport`).
- `/init` additions:
  - the `ports` check;
  - `apkrun.test.flood=<n>`, which prints `n` numbered lines `APKRUN-FLOOD <i>` as fast as possible;
  - `apkrun.test.panic=1`, which triggers `echo c > /proc/sysrq-trigger` after `boot ok`.
- `apkrun dev console` (development builds only).
- `Tests/IntegrationTests/LinuxGuestTests/ConsoleTests.swift`.

### Implementation steps

1. **Channel roles (§6.3).**
   - Each port gets a `VZFileHandleSerialPortAttachment` from two pipes.
   - For `.log` and `.silent` ports, the host keeps the write end of the host-to-guest pipe open and never writes to it, so guest reads block instead of seeing EOF.
   - `.silent` output is discarded and counted.
   - All pipes are closed on `stop()` and `reset()` (§9.6).

   Check: T1 with real pipes: data arrives on the stream, EOF ends the stream, and a write to a `.log` port is refused.
2. **ConsoleLogWriter (§6.4).**
   - Each record is a line prefixed with the UTC wall time in ISO 8601 with milliseconds, a space, and the host monotonic time since `VM_START` as `+<seconds>.<milliseconds>`, followed by a space. Example: `2026-09-28T10:15:02.123Z +12.345 `.
   - A line without a newline is written at the next flush with its prefix, and its remainder starts a new record. No byte is held back longer than 250 ms.
   - Bytes are written as they are, with no UTF-8 repair, parsing, or redaction.
   - Rotation at 20 MiB keeps five generations: `console.log` and `console.1.log` to `console.4.log`.
   - Each boot also writes `vm/boot-<yyyyMMdd'T'HHmmss'Z'>.log`, and the newest five are kept.
   - Flush and `fsync` every 250 ms or 64 KiB, whichever comes first. Also flush and `fsync` on `VMState.failed`, `stop()`, and `reset()`.
   - Write errors set the `vm.consoleWriter` health check to `warning`. The writer never blocks the console reader. When it falls behind, it counts dropped bytes.

   Check: the T0 writer tests pass with the fake clock and file system.
3. **Wiring.**
   - `VMController` attaches a `ConsoleLogWriter` to port 0, rooted at `APKRunPaths` `vm/`. In a Debug build that is `~/Library/Logs/APKRun-Dev/vm/`; in a release build it is `~/Library/Logs/APKRun/vm/`.
   - `apkrun dev linux` keeps printing the live stream.

   Check: after `apkrun-dev dev linux`, `console.log` and one `boot-*.log` contain every line that was printed.
4. **Port numbering (§6.2 step 1).**
   - With `ports` in `apkrun.test`, `LinuxTestGuest` attaches `[.systemConsole, .service("test-1"), .service("test-2")]`.
   - The host writes `APKRUN-PORT-1\n` into port 1 and `APKRUN-PORT-2\n` into port 2. Port 0 is identified by the kernel console output arriving on the port 0 pipe, because the host writes to `.systemConsole` only in the dev console (§6.3).
   - The guest runs `stty -F /dev/hvcN raw -echo` on `hvc1` and `hvc2`, reads one line from each with a 5 s timeout, and prints `APKRUN-TEST: ports ok hvc1=<marker> hvc2=<marker>`, or `fail` with what it saw.
   - The T2 test asserts that `hvcN` received `APKRUN-PORT-N`.

   Check: the `ports` check passes, or the mismatch is recorded (Notes).
5. **Dev console.** In M0, `apkrun dev console` boots the Linux test guest with `apkrun.test.poweroff=0` and the options of `dev linux` except `--tests`. It puts the terminal in raw mode and connects it to `hvc0` in both directions.
   - Ctrl-] detaches: the command calls `requestGuestStop()`, waits up to 20 s, then calls `stop()`, restores the terminal, and exits 0.
   - `--android-shell` comes with #014.

   Check: typing `echo hi` in the guest shell shows `hi`, and Ctrl-] exits cleanly.
6. **Crash cases.** Add `apkrun.test.flood` and `apkrun.test.panic` to `/init`. Write three T2 tests:
   - (a) `stop()` while flooding. `console.log` must hold every flood line the stream delivered before the stop, and it must end with a complete record.
   - (b) A panic. The kernel panic message and the call trace must be in `console.log` after the test stops the VM.
   - (c) A `failed` transition must flush the writer.

   Manual check: `kill -9` the `apkrun-dev dev linux` process during a flood. The log then holds every line up to at most 250 ms before the kill.

   Check: the T2 tests pass, and the manual result is recorded in the pull request.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`, fake clock and file system):
  - the prefix format;
  - partial lines;
  - rotation at 20 MiB with five generations;
  - per-boot copies with five kept;
  - `fsync` at 250 ms and at 64 KiB;
  - the flush on `failed`, `stop()`, and `reset()`;
  - invalid UTF-8 written unchanged;
  - write errors reaching `vm.consoleWriter`.
- **T1** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/`): `ConsoleChannel` with real pipes; `.log` and `.silent` ports never written, and never at EOF on the guest side; `ConsoleLogWriter` against a real directory, with file modes and rotation on disk.
- **T2** (`LinuxGuest`, `ConsoleTests`):
  - the console marker in both the stream and `console.log`;
  - console port numbering with three ports;
  - a forced stop mid-output keeping the log intact up to the last line (NFR-REL-05);
  - a panic captured;
  - the flush on `failed`.
- **T3**: none. Manual: `kill -9` during a flood, recorded in the pull request.

### Acceptance criteria

- [ ] Guest boot output is visible live: `apkrun-dev dev linux` prints it, and `apkrun dev console` gives an interactive `hvc0`.
- [ ] The same output is persisted in `vm/` under the logs root. That is `~/Library/Logs/APKRun/vm/` in release builds and `~/Library/Logs/APKRun-Dev/vm/` in Debug builds.
- [ ] Oversized logs rotate at 20 MiB with five generations, and the last five per-boot copies are kept.
- [ ] A VM crash still leaves useful logs. After a forced stop mid-output, after a guest panic, and after `kill -9` of the host process, the log holds the output up to the last complete line, or up to at most 250 ms before a host crash (NFR-REL-05).
- [ ] Each line carries the wall-clock and monotonic prefixes of [../../02-design/vm.md](../../02-design/vm.md) §6.4. The bytes are unchanged and unredacted.
- [ ] The host never writes to `.log` or `.silent` ports. It writes to `.systemConsole` only in `apkrun dev console`.
- [ ] The three-port numbering is verified by a T2 test and recorded.
- [ ] Log write errors appear in the `vm.consoleWriter` health check.

### Notes

- **Record:** the three-port numbering result goes into [../../02-design/vm.md](../../02-design/vm.md) §6.2: either "array order on macOS <build>", or the observed order. If it is not array order, file the `ConsolePortPlan` follow-up that §6.2 step 3 describes before #095, and note the result under R-16.
- **Pitfall:** `hvc` devices are ttys. Without `raw -echo`, the guest echoes the host's marker back into the host pipe, and canonical mode waits for a newline.
- **Pitfall:** do not `fsync` on every line. At boot, the kernel can print thousands of lines a second. The 250 ms and 64 KiB policy keeps the disk load bounded.
- The dev console behavior (booting the Linux test guest in embedded mode, and Ctrl-] requesting a guest stop) is a choice of this plan. [../../02-design/cli.md](../../02-design/cli.md) §5 does not say which VM `dev console` uses before #014.
- Writing no marker into port 0 is also a choice. It follows §6.3. [../../02-design/vm.md](../../02-design/vm.md) §6.2 step 1 would write into every port.

---

## #005 virtio-blk storage

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Requirements | FR-VM-03 |
| Design | [../../02-design/vm.md](../../02-design/vm.md) §2 (`DiskDefinition`), §3 (disk rules), §4 (storage mapping), §5 (device order), §12, §15; [../test-strategy.md](../test-strategy.md) §3.4 |
| Modules / paths | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/` (`Validation/`, `Framework/VZConfigurationBuilder.swift`, `TestGuest/`), `Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/`, `Tests/Fixtures/linux/` (`init`, `make-test-disks.sh`, `modules.list`), `scripts/build-test-initramfs.sh`, `ThirdParty/ThirdParty.lock.json`, `Tests/IntegrationTests/LinuxGuestTests/BlockTests.swift` |
| Risks / questions | R-16 (device order can change with macOS) |

### Goal

The Linux test guest sees read-only and read-write virtio-blk disks in the order of `VMDefinition.disks`, identified by their serials. It can format, mount, write, reboot, and recover an ext4 file system on the read-write disk. It cannot write to the read-only disk.

### Scope

- The disk attachments of [../../02-design/vm.md](../../02-design/vm.md) §4: read-only flag, caching, synchronization, and `blockDeviceIdentifier`.
- The T1 tests with real files for the invalid-path and permission rules of §3, and the unreadable-disk rule (see step 1).
- The `blk` guest check with its phases, and the test disk script.
- The pinned `e2fsprogs` packages in the test initramfs.
- The order test, including the reversed order.

Out of scope:

- Android disk images, GPT, and `androidboot.boot_devices` (#011, #012).
- ASIF images and disk resizing.
- Instance storage under the data root (RuntimeCore and ImageCore).
- Snapshot or overlay disks.

### Deliverables

- `Tests/Fixtures/linux/make-test-disks.sh <out-dir>`, which creates two disks at test time:
  - `ro.img`, 8 MiB of a deterministic pattern generated from a seed, whose SHA-256 the script prints;
  - `rw.img`, 64 MiB, sparse and unformatted.
- `/init` `blk` block, driven by `apkrun.test.blk.phase=`:
  - `format`
  - `verify`
  - `stress`
  - `recover`
  - `order`
- Its inputs:
  - `apkrun.test.blk.ro_sha256=<hex>`;
  - `apkrun.test.blk.token=<hex>`;
  - `apkrun.test.blk.order=<serial,serial>`.
- The `e2fsprogs` packages and their libraries, pinned with SHA-256 and added to the initramfs.
- `VirtualMachineCoreSystemTests` disk cases and `BlockTests.swift`.

### Implementation steps

1. **Validation with real files.** Add T1 tests that exercise the §3 disk rules against real files in a temporary directory:
   - a missing file;
   - a directory in place of a file;
   - a dangling symlink;
   - an Android sparse image header;
   - the same file twice (once through a symlink);
   - a read-write disk with mode 0444;
   - a read-only disk with mode 0444 (accepted);
   - an identifier of 21 characters.

   An unreadable disk (mode 000) fails with `.diskNotReadable(role)` ([vm.md](../../02-design/vm.md) §3; [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.2, exit 1, grouped with the "Files that Android needs" text).

   Check: the T1 tests pass on the CI runner, which does not run as root.
2. **Attachments.**
   - `VZConfigurationBuilder` creates `VZDiskImageStorageDeviceAttachment(url:readOnly:cachingMode:synchronizationMode:)` for each disk, in array order, and sets `blockDeviceIdentifier` from `identifier`.
   - `DiskSync.none` is allowed only in tests: the validator rejects it unless a test-only flag is set on the host environment.
   - Log each disk under category `config` with its role, flags, and file name, never the full path.

   Check: T0 inspection of the built configuration.
3. **Test disks and packages.**
   - `make-test-disks.sh` writes `ro.img` from the seed and `rw.img` with `mkfile -n 64m`.
   - The fetch and build scripts add `e2fsprogs` (`mkfs.ext4`, `e2fsck`) and its library packages, pinned in the lock file.
   - `LinuxTestGuest` attaches the disks with serials `apkrun-ro` and `apkrun-rw`.

   Check: the initramfs contains `mkfs.ext4` and `e2fsck`, and they run in the guest.
4. **Guest `blk` phases.** The guest finds each disk by reading `/sys/block/vd*/serial`, never by letter.
   - `format`: runs `mkfs.ext4 -F` on `apkrun-rw`, mounts it, writes `token` into `/mnt/rw/token`, runs `sync`, and unmounts. It then checks that `apkrun-ro` is read-only, with `blockdev --getro` = 1 and a write attempt that fails, and that `sha256sum` of `apkrun-ro` equals `ro_sha256`.
   - `verify`: mounts `apkrun-rw` and compares the token.
   - `stress`: writes files in a loop until the host stops the VM.
   - `recover`: runs `e2fsck -fy`, requires an exit code of 0 or 1, mounts the disk, and compares the token.
   - `order`: prints the serials in `vdX` order and compares them with `apkrun.test.blk.order`.

   Each phase prints `APKRUN-TEST: blk ok <phase>` or `fail <phase> <detail>`.

   Check: each phase passes alone on a lab Mac.
5. **Reboot and recovery tests.** A "reboot" is a power-off, then a new `VMController` on the same disk files. `BlockTests` runs `format`, then `verify` in a new VM, then `stress` stopped with `stop()` after 3 s, then `recover`. The order test boots with `[ro, rw]` and then with `[rw, ro]`, and asserts that `vda` follows the array each time.

   Check: `BlockTests` passes within the LinuxGuest budget.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`): storage mapping (order, identifiers, flags); `DiskSync.none` refused outside tests.
- **T1** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/`): the invalid path and permission cases of step 1 with real files.
- **T2** (`LinuxGuest`, `BlockTests`):
  - read-only and read-write disks with known content ([../test-strategy.md](../test-strategy.md) §6.1);
  - a write refused on the read-only disk;
  - format, then verify after a new boot;
  - recovery after a forced stop mid-write;
  - device order and reversed order.
- **T3**: none.

### Acceptance criteria

- [ ] Read-only and read-write disk images are supported. The guest reads the read-only disk's known content and cannot write to it.
- [ ] Disk order is deterministic. The guest sees the disks in `VMDefinition.disks` order, and each disk's `/sys/block/vdX/serial` equals its `identifier`.
- [ ] Tests cover invalid paths and permissions: missing, not a regular file, dangling symlink, duplicate, not writable, not readable, and a bad identifier.
- [ ] The Linux guest can mount, write, reboot, and recover a test file system. The token survives a new boot, and after a forced stop mid-write, `e2fsck` repairs the file system and the token is intact.
- [ ] Disk logs contain the role and the file name, never the full path.
- [ ] The `e2fsprogs` packages are pinned in the lock file.

### Notes

- **Record:** the observed device order on the current macOS build goes into [../../02-design/vm.md](../../02-design/vm.md) §5, which currently says "to be confirmed". If the order differs from the array, nothing in APKRun may rely on letters. Record the case under R-16.
- **Pitfall:** `rw.img` is sparse. Copying it with a tool that is not sparse-aware inflates it to 64 MiB. That is harmless, but it slows the runner cache.
- **Pitfall:** the `stress` phase must `sync` its token file before the loop starts. Otherwise a forced stop can legitimately lose the token.
- The `.diskNotReadable` case and the `blk` phase protocol are choices of this plan. The case is in [vm.md](../../02-design/vm.md) §3. The `blk` phases are defined only here.

---

## #006 Guest networking

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Requirements | FR-VM-04 |
| Design | [../../02-design/vm.md](../../02-design/vm.md) §4 (network mapping), §7, §9.2, §14, §15; [../test-strategy.md](../test-strategy.md) §2.5, §3.9, §6.1 |
| Modules / paths | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/` (`Framework/VZConfigurationBuilder.swift`, `Controller/VMController.swift`, `Health/`, `TestGuest/`), `Packages/VirtualMachineCore/Tests/`, `Tests/Fixtures/linux/init`, `ThirdParty/ThirdParty.lock.json` (`ssl_client`), `Tests/IntegrationTests/LinuxGuestTests/NetworkTests.swift`, `Tests/AcceptanceTests/Network/LinuxGuestNetworkTests.swift`, `.github/workflows/nightly.yml` |
| Risks / questions | None |

### Goal

The Linux test guest gets an IP address from VZ's NAT DHCP and fetches `generate_204` from an HTTP server on the host. In the nightly network check, it also resolves a public name and reaches `https://connectivitycheck.gstatic.com/generate_204`. The MAC address and the lease are logged, and a disconnected attachment is reported without stopping the VM.

### Scope

- The NAT attachment with the definition's MAC (§4, §7).
- The disconnect delegate: the state stays `running`, the event is logged, and `vm.network` becomes `degraded` (§9.2).
- The `vm.network` health check.
- The guest `net` check: DHCP, the host HTTP server, and optionally the external checks.
- A small HTTP server in the T2 test.
- The nightly T3 network check.

Out of scope:

- Bridged networking (restricted entitlement), port forwarding, and inbound connections (§7).
- Android networking (#095). `VsockLoopbackForwarder` (#015).
- Storing the MAC in `instance.json` (RuntimeCore). This task uses a freshly generated MAC per test run.

### Deliverables

- The network part of `VZConfigurationBuilder`: `VZVirtioNetworkDeviceConfiguration`, `VZNATNetworkDeviceAttachment`, and `macAddress`.
- `VMController` handling of `networkAttachmentDisconnected`, and the `vm.network` check.
- The `/init` `net` block:
  - `udhcpc` on `eth0`;
  - `wget -S http://<router>:<port>/generate_204`, with `<port>` from `apkrun.test.net.port=`;
  - with `apkrun.test.net.external=1`, `nslookup connectivitycheck.gstatic.com` and `wget -S https://connectivitycheck.gstatic.com/generate_204`.
- The output line: `APKRUN-TEST: net ok ip=<ip> gw=<router> dns=<server> http=204[ ext=204]`.
- The pinned `ssl_client` package (busybox `wget` uses it for HTTPS) and its libraries.
- `NetworkTests.swift` (T2) and `LinuxGuestNetworkTests.swift` (T3, nightly `network` job, one retry, classification `external`).

### Implementation steps

1. **Attachment.** When the definition has `network = .nat(macAddress:)`, the builder adds one virtio-net device with a NAT attachment and the MAC. The MAC is logged under category `config` as `.public`. It is a random, locally administered address, not a hardware identifier.

   Check: T0 inspection of the built configuration.
2. **Disconnect handling.**
   - The driver event `networkAttachmentDisconnected(error)` keeps the state `running`.
   - It logs a `warning` under category `network` with the `VZErrorInfo` domain and code.
   - It sets `vm.network` to `degraded` with the remediation from the catalog or health text. `vm.network` is a live check ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §7.1).
   - A new `start()` resets `vm.network` to `pass`.

   Check: T0 with the fake driver.
3. **Guest `net` check.**
   - `/init` loads `virtio_net` if it is a module, then runs `udhcpc -i eth0 -q -n -t 5`.
   - The router and DNS server come from the udhcpc script's environment.
   - The check prints the line in Deliverables, or `fail <step> <detail>` for `dhcp`, `http`, `dns`, or `ext`.

   Check: the guest prints `net ok` against a host server on a lab Mac.
4. **Host endpoint and logging.**
   - `NetworkTests` starts an HTTP server with Network.framework on `0.0.0.0:<ephemeral port>` that answers `GET /generate_204` with 204. It passes the port to the guest.
   - The harness parses the `net ok` line and logs `lease ip=… gw=… dns=…` under `io.apkrun.vm`, category `network`. Log the interface information when available; the guest's line is the only source.

   Check: the T2 test passes and the log entry is present.
5. **Nightly external check.**
   - `LinuxGuestNetworkTests` boots with `apkrun.test.net.external=1` and requires `ext=204`.
   - Add the `network` job to `nightly.yml` if it does not exist yet ([../../05-development/build-system.md](../../05-development/build-system.md) §15.1). It runs `Tests/AcceptanceTests/Network` with one retry, and failures are classified `external`.

   Check: one nightly run passes.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`): network mapping with the MAC; a disconnect event keeps `running`, logs a warning, and sets `vm.network` to `degraded`; the next start resets it.
- **T1**: none.
- **T2** (`LinuxGuest`, `NetworkTests`): a DHCP lease and `generate_204` from a server on the host ([../test-strategy.md](../test-strategy.md) §6.1). `vm.network` stays `pass` for the whole run. T2 needs no Internet ([../test-strategy.md](../test-strategy.md) §3.9).
- **T3** (`Tests/AcceptanceTests/Network/`, nightly): the guest resolves `connectivitycheck.gstatic.com` and fetches `https://connectivitycheck.gstatic.com/generate_204` ([../../02-design/vm.md](../../02-design/vm.md) §15).

### Acceptance criteria

- [ ] Networking uses a Virtualization.framework NAT attachment. There is no bridged mode and no `com.apple.vm.networking`.
- [ ] The guest obtains an IP address through DHCP (T2).
- [ ] The guest resolves DNS (T3 nightly, through the host's resolver).
- [ ] The guest connects to a host-visible endpoint: `generate_204` on the host returns 204 (T2).
- [ ] The guest reaches the external network: `https://connectivitycheck.gstatic.com/generate_204` returns 204 (T3 nightly).
- [ ] The assigned interface information is logged: the MAC at configuration time, and the IP address, gateway, and DNS server from the guest's report.
- [ ] A disconnected attachment leaves the VM `running`, is logged, and sets `vm.network` to `degraded`.

### Notes

- **Record:** whether the host server on `0.0.0.0` triggers the macOS application firewall on lab Macs goes into [../test-strategy.md](../test-strategy.md) §3.6 as a lab setup step if needed.
- **Pitfall:** the NAT bridge interface (`bridge100`) exists only while a NAT VM runs. Do not bind the test server to its address before the VM starts. Bind to all interfaces, and let the guest use its DHCP router address.
- **Pitfall:** busybox `wget` does not verify TLS certificates. The external check proves reachability only, which is all FR-VM-04 asks for.
- **Pitfall:** there is no reliable way to make VZ disconnect a NAT attachment on purpose. The disconnect path is therefore tested at T0 with the fake driver. [../test-strategy.md](../test-strategy.md) §6.1 lists "disconnect callback logged" under T2, which needs a trigger that the design does not give.

---

## #007 virtio-vsock

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Requirements | FR-VM-05 |
| Design | [../../02-design/vm.md](../../02-design/vm.md) §4 (vsock mapping), §8, §13, §14, §15; [../../01-architecture/process-model-and-ipc.md](../../01-architecture/process-model-and-ipc.md) §3.1; [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.1 |
| Modules / paths | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/` (`Vsock/VsockConnection.swift`, `Controller/VMController.swift`, `Controller/VirtualMachineDriver.swift`), `Packages/VirtualMachineCore/Tests/`, `Tests/Fixtures/linux/init`, `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift` |
| Risks / questions | None |

### Goal

The host opens a vsock connection to a port in the Linux test guest, sends 1 MiB, and receives exactly the same bytes back. A connection to a port where nobody listens fails with a typed error within its timeout. When the guest closes the connection, the host detects it.

### Scope

- One `VZVirtioSocketDeviceConfiguration` when `vsockEnabled` is set (§4). The guest CID is 3 and the host CID is 2.
- `VMController.connect(vsockPort:timeout:)`: host to guest only, with a timeout implemented as a `Task` race, and a late connection closed at once (§8).
- `VsockConnection`: a strong reference to `VZVirtioSocketConnection`, `DispatchIO` reads and writes, `close()`, and disconnect detection.
- The error mapping to `.vsockConnectFailed`, `.vsockPortNotListening`, and `.vsockConnectTimedOut`.
- The guest `vsock` check: an echo service on port 7000 and a closing service on port 7001.
- A host test client in the T2 tests.

Out of scope:

- `VsockLoopbackForwarder` and ADB over vsock (#015).
- Guest-to-host listeners, which are not used in v1 (§8).
- The guest protocol framing and handshake (#033). `apkrun_vsockd` (#035).
- Retry policies of callers (RuntimeCore).

### Deliverables

- `Vsock/VsockConnection.swift`, with `read(upTo:)`, `write(_:)`, `close()`, and `closed`. `closed` completes when the peer closes the connection or when the VM stops.
- `connect(vsockPort:timeout:)` in `VMController`, and the driver's `connect(toPort:)` on the VM queue.
- The `/init` `vsock` block:
  - `socat VSOCK-LISTEN:7000,fork EXEC:cat &`;
  - `socat VSOCK-LISTEN:7001,fork EXEC:'head -c 16' &`;
  - then `APKRUN-TEST: vsock ok listening 7000,7001`.
- `VsockTests.swift`.

### Implementation steps

1. **Device.** The builder adds one vsock device when `vsockEnabled` is set. The driver exposes `connect(toPort:)` from `VZVirtioSocketDevice`, called on `io.apkrun.vm.queue`.

   Check: T0 configuration inspection.
2. **Connect with timeout (§8).** `connect(vsockPort:timeout:)` is allowed only in `running`; otherwise it throws `.invalidTransition` (see Notes). It races the VZ completion against `Task.sleep(for: timeout)`:
   - A timeout throws `.vsockConnectTimedOut(port:)`.
   - A completion that arrives after the timeout closes its connection at once.
   - A refused connection throws `.vsockPortNotListening(port:)`.
   - Any other error throws `.vsockConnectFailed(port:underlying:)`.

   Log under category `vsock` with the port and the result. The port is logged, never shown ([../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §5.1).

   Check: T0 with the fake driver covers all four outcomes, including a late completion being closed.
3. **VsockConnection.**
   - The connection holds the `VZVirtioSocketConnection` for its whole life, because the file descriptor is valid only while that object lives. `DispatchIO` uses the descriptor.
   - EOF or an error completes `closed`.
   - `VMController` closes every open connection on `stop()`, `reset()`, and `guestDidStop`.

   Check: T1 over a `socketpair` stand-in for the descriptor: reads, writes, EOF, and close.
4. **Guest services and tests.**
   - `/init` starts both `socat` listeners when `vsock` is in `apkrun.test`.
   - The host retries `.vsockPortNotListening` with backoff (100 ms, doubling) for up to 5 s, because the listeners start just after `boot ok`.
   - `VsockTests` covers three cases:
     - (a) Echo: sends 1 MiB of seeded bytes to port 7000 and compares the SHA-256 of what comes back.
     - (b) An unused port: connects to port 7999 with a 2 s timeout and expects `.vsockPortNotListening` or `.vsockConnectTimedOut` within 2.5 s.
     - (c) Disconnect: sends 32 bytes to port 7001, receives 16, and expects `closed` within 1 s.

   Check: `VsockTests` passes on a lab Mac.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`, fake driver):
  - success;
  - timeout;
  - a late completion is closed;
  - refused, then `.vsockPortNotListening`;
  - another error, then `.vsockConnectFailed`;
  - `connect` outside `running`;
  - connections closed on stop.
- **T1** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/`): `VsockConnection` over a `socketpair`.
- **T2** (`LinuxGuest`, `VsockTests`): a vsock echo of 1 MiB, the timeout on an unused port, and disconnect detection ([../test-strategy.md](../test-strategy.md) §6.1).
- **T3**: none.

### Acceptance criteria

- [ ] The VM has a `VZVirtioSocketDevice`, with guest CID 3 and host CID 2.
- [ ] The Linux guest runs a minimal echo service (`socat` on port 7000).
- [ ] A host test client sends a 1 MiB payload over vsock and receives exactly the same bytes back.
- [ ] Timeouts are handled: a connection that does not open within its timeout fails with `.vsockConnectTimedOut`, and a late connection is closed at once.
- [ ] Disconnects are handled: when the guest closes the connection, `closed` completes within 1 s, and every connection is closed when the VM stops.
- [ ] A refused connection fails with `.vsockPortNotListening`, which callers treat as "not ready yet". Every other failure is `.vsockConnectFailed` with a `VZErrorInfo`.
- [ ] Connections are host to guest only. No guest-to-host listener is registered.

### Notes

- **Record:** the `NSError` domain and code that VZ returns for a refused connection, and for a connection to a port with no listener, go into [../../02-design/vm.md](../../02-design/vm.md) §8. The mapping in step 2 depends on them.
- **Pitfall:** dropping the `VZVirtioSocketConnection` while `DispatchIO` still uses its descriptor gives reads on a closed or reused descriptor. That produces silent corruption, not a crash.
- **Pitfall:** `socat` with `fork` keeps listening after each connection. Without `fork`, the second test connection would be refused.
- Throwing `.invalidTransition` from `connect` outside `running` is a choice of this plan. [../../02-design/vm.md](../../02-design/vm.md) §8 does not say what `connect` does in other states.
- Port 7001 is also a choice. It is the port of the closing service the disconnect test needs. §8 names only the echo service on 7000.

---

## #063 VirtioDeviceCore and test virtio device

| Field | Value |
|---|---|
| Milestone | M0 (v0.1) |
| Depends on | #003 |
| Requirements | FR-VM-06 |
| Design | [../../02-design/graphics.md](../../02-design/graphics.md) §3 (§3.1–§3.3), §8 (lifecycle rules that apply to every device), §12 (#063 steps 1–4), §14; [../../02-design/vm.md](../../02-design/vm.md) §3 (`customDeviceInvalid`), §4 (`customVirtioDevices`), §9.5, §12; [../../01-architecture/decisions/0002-virtualization-framework-macos27.md](../../01-architecture/decisions/0002-virtualization-framework-macos27.md) |
| Modules / paths | `Packages/VirtioDeviceCore/Sources/VirtioDeviceCore/` (`API/`, `VZAdapter/`, `TestDevices/EntropyTestDevice.swift`), `Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTests/`, `Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTestSupport/`, `Packages/VirtualMachineCore/Sources/VirtualMachineCore/` (`Framework/VZConfigurationBuilder.swift`, `Validation/`, `TestGuest/`), `Tests/Fixtures/linux/` (`init`, `modules.list`), `Tests/IntegrationTests/LinuxGuestTests/` (`EntropyDeviceTests.swift`, `LinuxGuestRebootObservationTests.swift`) |
| Risks / questions | R-01 (the #063 part: queues, config updates, resets); R-07 (`supportsSaveRestore` stays off) |

### Goal

A host-implemented virtio-rng device, built on the macOS 27 custom virtio device API through VirtioDeviceCore, replaces the built-in entropy device in the Linux test guest. The guest reads 64 KiB of the host's seeded sequence from `/dev/hwrng`. The device survives a driver reset and still serves data. The host log shows `DRIVER_OK`, the queue notifications, and the reset in order.

### Scope

- The VirtioDeviceCore API of [../../02-design/graphics.md](../../02-design/graphics.md) §3.2:
  - `VirtioDeviceDescriptor`, `VirtioDeviceModel`, `VirtioDeviceContext`;
  - `VirtioQueue`, `VirtioElement`, `PendingElement`;
  - `GuestMemory`, `GuestPhysicalRange`, `VirtioFailure`.

  The signature corrections are in step 1.
- The VZ adapter:
  - it builds `VZCustomVirtioDeviceConfiguration` from a descriptor;
  - it uses one serial device queue per device with `.userInteractive` QoS;
  - it provides the delegate provider;
  - it splits feature bits into `subset0` and `subset1`.
- The fakes in `VirtioDeviceCoreTestSupport` and the T0 tests ([../../02-design/graphics.md](../../02-design/graphics.md) §12 step 2).
- `EntropyTestDevice` (§3.3), and the `rng` guest check.
- A forced-stop `rng-pending` probe that retains a live mapping and deferred VZ queue element until stop.
- Wiring `VMDefinition.customDevices` into the VZ builder and the `.customDeviceInvalid` rule.
- The config-update probe on the host, and recording VZ's guest-reboot behavior.

Out of scope:

- virtio-gpu, the scanout hotplug spike (#019), and the renderer (#020).
- Shared memory regions, which stay empty in v1.
- Save and restore: `supportsSaveRestore` stays `NO` for every device (R-07, [../../02-design/vm.md](../../02-design/vm.md) §9.5).
- Observing the config-change interrupt in the guest. The virtio-rng driver has no config handler, so this is #019's part of R-01.

### Deliverables

- VirtioDeviceCore sources:
  - `API/`: descriptor, model, context, queue, element, guest memory, failures;
  - `VZAdapter/`: configuration, provider, delegate, the VZ-backed queue and element;
  - `TestDevices/EntropyTestDevice.swift`.
- `VirtioDeviceCoreTestSupport`: `FakeVirtioQueue`, `FakeGuestMemory`, and a fake context.
- `VZConfigurationBuilder` support for `customDevices` through the adapter. `VMDefinitionValidator` maps adapter-level rejections to `.customDeviceInvalid(name:reason:)`.
- The `/init` `rng` block and `EntropyDeviceTests.swift`.
- A verification entry in the [../../02-design/graphics.md](../../02-design/graphics.md) §16 verification log, and a Result line for the #063 part of R-01 in [../risks.md](../risks.md).

### Implementation steps

These are the design steps of [../../02-design/graphics.md](../../02-design/graphics.md) §12 (#063). Step 1 is the design's step 1 with the corrections below. Steps 2–4 match the design's steps 2–4, and step 5 records the results.

1. **API and VZ adapter (design step 1).** Implement §3.2 with three corrections, which this pull request also writes into [graphics.md](../../02-design/graphics.md) §3.2:
   - `drain` takes ownership of each element and its body is nonthrowing: `func drain(_ body: (consuming VirtioElement) -> Void)`. Virtualization.framework suppresses notifications until the queue is empty, so the body handles failures locally and completes the current element before the loop continues.
   - `defer()` becomes `deferCompletion() -> PendingElement`, because `defer` is a Swift keyword.
   - The fakes live in `VirtioDeviceCoreTestSupport`, not `VirtioDeviceCoreTesting` ([../test-strategy.md](../test-strategy.md) §3.2).

   Adapter rules:
   - VZ objects are touched only on the device queue.
   - `queue(_:)` and `negotiatedFeatures` are valid only after `DRIVER_OK`. Before that they fail with `VirtioFailure.notReady`.
   - Guest memory mappings are cached per device and invalidated on `WillReset` and `WillStop` before calling the model lifecycle method.
   - Configuration updates reject a different size with `.configSizeMismatch`, run serially, and fail with `.notReady` if reset or release invalidates their generation.
   - `VirtioDeviceContext` is not `Sendable`; each callback receives a context bound to that device generation, and async work captures its `Sendable` `configurationUpdater` while still on the device queue. A saved updater or context from an earlier generation cannot update configuration, access queues/features/memory, or reset the device after the guest sets `DRIVER_OK` again.
   - `VirtioFailure` is internal to device models. Device models convert it into their own domain errors, and it never reaches users (see Notes).

   Check: the module builds, and the adapter builds a `VZCustomVirtioDeviceConfiguration` for a test descriptor.
2. **Fakes and T0 (design step 2).** `FakeVirtioQueue` and `FakeGuestMemory` back the T0 tests:
   - the drain loop runs until the queue is empty;
   - noncopyable elements and pending handles prevent duplicate completion at compile time; the copyable one-shot completion token traps on a second completion at runtime;
   - deferred completion retains an element until its `Sendable` pending handle or one-shot completion token completes across an actor hop;
   - debug exit tests catch dropping either an uncompleted element or pending handle;
   - bounds checks, and `gpa + len` overflow;
   - `copyReadable` takes one snapshot;
   - the feature split into `subset0` and `subset1`.

   Check: the T0 tests pass.
3. **EntropyTestDevice (design step 3).** The descriptor has deviceID 4, PCI class 0x10, one queue, no features, and an 8-byte configuration space holding a generation counter.
   - The device fills each writable buffer from a deterministic generator (SplitMix64) seeded by the test.
   - On `deviceWillReset`, it restarts the generator from the seed. Mapping probe mode retains only the already-invalidated mapping token until the next start or stop callback so the test can assert that both callbacks reject access.
   - It logs `DRIVER_OK`, each notification (count and bytes, at `debug`, with an `info` summary), and each reset. Logs go to `io.apkrun.vm`, category `virtio` ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §3.1).
   - The device never sets `supportsSaveRestore`.

   `/init` `rng` block:
   1. Loads `virtio_rng` if it is a module.
   2. Checks that `rng_available` lists `virtio_rng.0`.
   3. Reads 64 KiB from `/dev/hwrng` into `/tmp/rng`.
   4. Prints `APKRUN-TEST: rng ok sha256=<hex> head=<first 16 bytes hex>`.
   5. Unbinds and rebinds the virtio device from `virtio_rng` through sysfs.
   6. Reads 64 KiB again and prints a second `rng ok` line.

   `LinuxTestGuest` adds the device and disables built-in entropy when either `rng` or `rng-pending` is requested; it adds `rng_core.default_quality=0` to the command line.

   Check: the guest prints both `rng ok` lines on a lab Mac.
4. **T2 acceptance (design step 4).** `EntropyDeviceTests` checks:
   - For each read, the test finds the offset of `head` within the first 1 MiB of the seeded stream. It then requires `sha256` to equal the SHA-256 of 64 KiB from that offset. This tolerates bytes that the kernel took for itself.
   - The host log shows `DRIVER_OK`, notifications, the reset, `DRIVER_OK` again, and more notifications, in that order.
   - Config probe (host side): after `DRIVER_OK`, `updateConfigurationSpace` with 8 new bytes completes, and 4 bytes fail with `.configSizeMismatch`.
   - A real VZ guest-memory mapping retained by the model rejects a zero-byte access as `.guestMemoryInvalidated` in both `deviceWillReset` and `deviceWillStop`. The tested VZ shutdown calls `WillReset` before `WillStop`, so the stop callback checks a mapping already invalidated by reset.
   - A validator case: a descriptor that VZ rejects becomes `.customDeviceInvalid`.
   - A separate forced-stop run records the callback stream as `DRIVER_OK`, mapping creation, then `WillStop`, with no intervening `WillReset`; it rejects the live mapping and attempts completion through the old deferred-element token after stop.

   Check: `EntropyDeviceTests` passes.
5. **VZ reboot behavior and records.**
   - Boot once with `apkrun.test.rng.reboot=1`, where `/init` calls `reboot -f` after the first read. Record what VZ does: whether it restarts the guest (with `WillReset` and a second boot) or reports `guestDidStop`. Fail the observation if the VM enters a failed state or the reboot produces neither accepted outcome.
   - Record the result in the [../../02-design/graphics.md](../../02-design/graphics.md) §16 verification log, the §3.3 acceptance text, and [../../02-design/vm.md](../../02-design/vm.md) §9. Correct §3.1 of that document where a platform fact differs.
   - Write the #063 part of the R-01 Result line in [../risks.md](../risks.md): what was confirmed about queue validity before `DRIVER_OK`, same-size config updates, resets, and mapping invalidation. R-01 stays `open` for #019 and #028.
   - Add the #063 line to the ADR-0002 Verification section.

   Check: the records are in the pull request.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/VirtioDeviceCore/Tests/VirtioDeviceCoreTests/`, with `VirtioDeviceCoreTestSupport`):
  - drain;
  - exactly-once completion, deferred completion across an actor hop, duplicate token completion trapping, and debug exit tests for forgotten elements;
  - bounds and overflow;
  - the feature split;
  - `notReady` before `DRIVER_OK`;
  - `.configSizeMismatch`;
  - `EntropyTestDevice` filling buffers from a fake queue and restarting on reset.
- **T0** (`Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`): `customDevices` in the built configuration; `.customDeviceInvalid` mapping.
- **T1**: none.
- **T2** (`LinuxGuest`, `EntropyDeviceTests`): the `rng` check ([../test-strategy.md](../test-strategy.md) §6.1); the seeded bytes before and after a driver reset; stale-context rejection by the VZ adapter after rebind; live guest-memory mapping invalidation; the host log order; the config update probe; the reboot observation run with per-stream event ordering; forced-stop invalidation of a live mapping and deferred VZ element, followed by a late completion attempt.
- **T3**: none.

### Acceptance criteria

- [x] With the built-in VZ entropy device disabled, the Linux test guest lists `virtio_rng.0` in `/sys/class/misc/hw_random/rng_available` ([../../02-design/graphics.md](../../02-design/graphics.md) §3.3).
- [x] The guest reads 64 KiB from `/dev/hwrng` that match the host's seeded sequence.
- [x] After a device reset (driver unbind and bind), a second 64 KiB read works and matches the sequence.
- [x] A retained context from the old generation cannot access the new queue, inspect its features, map its guest memory, or reset the restarted device.
- [x] A live VZ guest-memory mapping retained across reset and stop rejects access in both model lifecycle callbacks. On this macOS build, VZ sends `WillReset` before `WillStop`, so the mapping checked during stop was already invalidated by reset.
- [x] The host log shows `DRIVER_OK`, notifications, and the reset in order.
- [x] Forced VM stop without an earlier device reset invalidates a live guest-memory mapping and a deferred VZ queue element; the recorded callback sequence confirms there was no intervening `WillReset`, and completion through the old handle is attempted after stop.
- [x] After `DRIVER_OK`, a same-size configuration update succeeds and a different-size update fails with `.configSizeMismatch`.
- [x] Every element is completed exactly once. The type system prevents double completion of noncopyable handles; the one-shot completion token rejects duplicate calls at runtime, and a debug build catches a forgotten handle (T0).
- [x] VZ objects are touched only on the device queue. Guest data is copied once before it is validated (§3.2 design rules).
- [x] `supportsSaveRestore` is off for the device.
- [x] VZ's guest-reboot behavior is recorded in [graphics.md](../../02-design/graphics.md) §3.3.
- [x] R-01 has a Result line for the #063 part, and ADR-0002 Verification has the #063 line.

### Notes

- **Record:** the verification results go into the [../../02-design/graphics.md](../../02-design/graphics.md) §16 verification log (and §3.1 where a platform fact differs), R-01 in [../risks.md](../risks.md), and ADR-0002. They cover queue validity before `DRIVER_OK`, same-size config updates, reset and mapping invalidation, and VZ's handling of a guest reboot.
- **Pitfall:** the kernel's hwrng core can read from the current RNG on its own. It does this at registration, and through its fill thread when the quality is above 0. The first bytes of the device's stream may therefore never reach `/dev/hwrng` readers. `rng_core.default_quality=0` and the offset search in step 4 handle this.
- **Pitfall:** `returnToQueue` twice raises an Objective-C exception in VZ. A mistake in the adapter crashes the process that owns the VM.
- R-01 is settled by tasks in three milestones (#063, #019, #028). Under [../risks.md](../risks.md) §1, an `open` risk whose settling task is in a finished milestone blocks that milestone's exit. M0 exits with R-01 `open` and a Result line for #063; the Exit criteria above state this explicitly.
- `VirtioFailure` has no domain in [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md) §2.1. It stays internal, and device models map it to their own domain errors, for example `GraphicsFailure` in #019.
