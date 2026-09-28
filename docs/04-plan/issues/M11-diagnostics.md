# M11 Diagnostics

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.5 |
| Related | [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../../AGENTS.md](../../../AGENTS.md) |

## Milestone goal

A user or a maintainer can tell every failure class apart without reading source code, and can hand over a secret-free support artifact. `apkrun doctor` and APKRun.app's Troubleshooting pane show one health report with remediations. `apkrun diagnostics` and **Create Diagnostics Report…** produce a redacted ZIP with a human-readable summary, also after a boot failure and without apkrund. M11 completes the v0.5 extras of [../roadmap.md](../roadmap.md) §3.5.

## Exit criteria

- [ ] #059 and #060 meet every acceptance criterion below.
- [ ] T0 and T1 suites pass on `main`, including the host-only doctor and bundle tests (diagnostics T2-1, which [../test-strategy.md](../test-strategy.md) §2.8 runs as T1). The T2 tests of this milestone (diagnostics T2-3 to T2-7) pass in the AndroidCustom suite on the reference Mac. The T3 check of the Troubleshooting pane (diagnostics T3-2, checklist C05-7 of [../test-strategy.md](../test-strategy.md) §8.6) is done, and the doctor and bundle timings run nightly ([../roadmap.md](../roadmap.md) §4).
- [ ] FR-OPS-01 and FR-OPS-02 have their tasks done and their verification recorded in [../traceability.md](../traceability.md) §2.
- [ ] Perf numbers for the milestone are recorded ([../roadmap.md](../roadmap.md) §4 item 4), including the quick doctor time (≤ 3 s) and the bundle time and size of a healthy runtime (≤ 60 s, ≤ 100 MiB).
- [ ] The `logcat -v uid` open item of [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §13 is settled, and the result is recorded in [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14.
- [ ] [../risks.md](../risks.md) is reviewed. No risk has its settling task in M11. Statuses are updated where M11 results bear on them.
- [ ] The design documents describe what was built: [../../02-design/diagnostics.md](../../02-design/diagnostics.md), [../../02-design/cli.md](../../02-design/cli.md) §4.8, [../../02-design/host-ui.md](../../02-design/host-ui.md) §9.8, and the `diagnostics` domain of [../../03-reference/error-catalog.md](../../03-reference/error-catalog.md).
- [ ] When M8–M10 are also complete, the v0.5 Definition of Done ([../roadmap.md](../roadmap.md) §3.5) is checked and v0.5 is tagged.

## Task order

1. #059 `apkrun doctor`.
2. #060 Diagnostics bundle (after #059).

There are no parallel tasks inside M11, because #060 depends on #059. M11 as a whole can run in parallel with M8–M10: #059 needs only #031, #034, and #036.

---

## #059 `apkrun doctor`

| Field | Value |
|---|---|
| Milestone | M11 (v0.5) |
| Depends on | #031, #034, #036 |
| Requirements | FR-OPS-01, FR-CLI-01, FR-CLI-02, NFR-OBS-02, NFR-OBS-03 |
| Design | [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §7, §11, §12; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §12; [../../02-design/cli.md](../../02-design/cli.md) §3.3, §4.8, §6; [../../02-design/host-ui.md](../../02-design/host-ui.md) §5.2, §9.8, §12 |
| Modules / paths | DiagnosticsCore (`Packages/DiagnosticsCore/`: `HealthCheckRegistry`, `HostChecks`, the verdict, `DoctorFormatter`, `ErrorCatalog/errors.json`); RuntimeHost (`DiagnosticsService`); RuntimeAPI (`HealthRequest`, `HealthFixRequest`, `WireHealthReport`); RuntimeCore and GraphicsCore (their checks); `CLI/apkrun/Commands/Doctor.swift`; `Apps/APKRun/Features/Troubleshooting/`; `Apps/APKRunMenuBar/`; `Tests/IntegrationTests/`; `Tests/AcceptanceTests/` |
| Risks / questions | None. Open items: [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §13 |

### Goal

`apkrun doctor` and the Troubleshooting pane show one health report, grouped by subsystem, with a remediation on every row that is not passing. The verdict tells apart a stopped runtime, an Android boot failure, a graphics failure, an unavailable Guest Agent, and a healthy runtime. Doctor never starts Android.

### Scope

- `DiagnosticsService` in RuntimeHost with apkrund's `HealthCheckRegistry`, filled with the checks of every module ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §7.4).
- The checks that no earlier task owns: `graphics.*` and `agent.*` of §7.4, and the `apkrund.*` checks of §7.3.
- The #059 checks, by check ID:

  | #059 check | Check IDs |
  |---|---|
  | Apple Silicon | `host.appleSilicon` |
  | macOS version | `host.macOSVersion` |
  | Virtualization support | `host.hypervisor`, `vm.virtualizationSupported` |
  | runtime files | `host.componentVersions`, `image.current`, `image.instance` |
  | VM status | `vm.state` |
  | Android boot state | `runtime.state`, `runtime.boot` |
  | graphics initialization | `graphics.device`, `graphics.renderer`, `graphics.guestDriver` |
  | Guest Agent connectivity | `agent.guest` |
  | Store Agent connectivity | `agent.store` |
  | package store consistency | `store.journal`, `store.packages` |

- The status line of §7.2 (the verdict function exists since #061), the exit codes 0, 3, and 1, and the host-only report when apkrund is unreachable (§7.3).
- `healthReport` and `applyHealthFixes` on the control endpoint (§7.6), live checks on the `health` topic (§7.1).
- CLI `apkrun doctor [--deep] [--fix] [--json]` in the format (§7.7).
- The Troubleshooting list in APKRun.app, and "Needs attention" in the main window header and the menu bar.
- The safe fixes of §7.5.
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - The diagnostics bundle, the Redactor, and **Create Diagnostics Report…**. They belong to #060.
  - Checks owned by other modules that their tasks already delivered (`store.*`, `updates.*`, `wrappers.*`, `integrations.*`, `image.*`, `maintenance.*`). #059 registers and renders them. It does not redefine them.
  - `perfStatistics` (#070) and the compatibility database (#090).
  - Starting Android from doctor, and any fix that restarts Android while windows are open.
  - Japanese translations. English catalog entries are added here, and Japanese comes with #092.

### Deliverables

- `DiagnosticsService` (RuntimeHost) with the registry, the §7.1 run rules, and the live checks.
- The graphics checks (GraphicsCore), the agent checks (RuntimeCore), and the remaining `apkrund.*` checks (`apkrund.reachable` and `apkrund.version` in DiagnosticsCore `HostChecks` on the client side, and `apkrund.crashLoop` in RuntimeHost). `apkrund.registration` exists since #061.
- The RuntimeAPI wire types with round-trip tests. `healthReport` and `applyHealthFixes` in [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- `DoctorFormatter` and `CLI/apkrun/Commands/Doctor.swift` with golden files.
- `Apps/APKRun/Features/Troubleshooting/` with the health list, and the "Needs attention" state in the header and in `Apps/APKRunMenuBar/`.
- `diagnostics` error codes and health titles in `Packages/DiagnosticsCore/ErrorCatalog/errors.json`, in English.
- The T1 test `DoctorHostOnlyTests` (the doctor half of T2-1) in `Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`, and the T2 tests `DoctorVerdictTests` (T2-4) and `DoctorFixTests` (T2-7) in `Tests/IntegrationTests/DiagnosticsTests/`.

### Implementation steps

1. **Registry and checks** ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §11 #059 step 1, §7.1, §7.3, §7.4; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §12).
   - Add `DiagnosticsService` to `Packages/RuntimeHost/`. At startup it builds apkrund's `HealthCheckRegistry` from every module's checks.
   - Complete the missing checks: `graphics.device`, `graphics.renderer`, `graphics.guestDriver` (deep), `graphics.present`, `graphics.memory`, `graphics.safeMode`, `agent.guest`, `agent.store`, `agent.input`, `agent.ime`, `agent.developerMode`, and `apkrund.reachable`, `apkrund.version`, `apkrund.crashLoop`. The `HostChecks` from #061 are extended, not replaced. If #057 has merged, `apkrund.version` also gets its `restartPending` variant, which reads `HostState` ([../../02-design/runtime-maintenance.md](../../02-design/runtime-maintenance.md) §3.6, §12); otherwise #057 adds it.
   - `graphics.guestDriver` reads the `DUMPSYS_SURFACEFLINGER` item of `CollectDiagnostics` (op 73, [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7). Op 73 exists since #070 with the item `DUMPSYS_MEMINFO`. Add `DUMPSYS_SURFACEFLINGER` on the host and in the Guest Agent's `DiagnosticsService`. #060 adds the rest ([../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §15).
   - Apply the run rules: 2 s for quick checks and 60 s for deep ones, a timeout gives `warning` with "check timed out", and at most 8 checks run at a time. Guest checks share one `Health` round trip. `runningRuntime` checks return `skipped` with "Android is not running" and `lastKnown` while Android is stopped.
   - Check: a T0 test asserts that the registry holds every ID of §7.4 exactly once, with the group and the cost of the table. A T0 test with a fake clock shows the timeout rule. A T0 test shows that no check calls the runtime's start path.
2. **Wire types and live checks** (§11 #059 step 2, §7.6, §7.1).
   - Add `HealthRequest{deep, checks?}`, `HealthFixRequest{checks}`, and `WireHealthReport` to RuntimeAPI. RuntimeHost converts to them, and RuntimeClient converts back.
   - Add `healthReport` and `applyHealthFixes` to the control endpoint only.
   - Publish `healthChanged(HealthResult)` on the `health` topic for the live checks of §7.1.
   - Check: T0 round-trip tests for every wire type. A T1 test over an in-process anonymous XPC listener with a fake runtime shows that a change of `runtime.state` publishes one `healthChanged` event.
3. **CLI** (§11 #059 step 3, §7.2, §7.7; [../../02-design/cli.md](../../02-design/cli.md) §4.8).
   - Add `DoctorFormatter` to DiagnosticsCore. It renders groups, symbols (✓ ℹ ⚠ ✕ –), indented remediations, the status line, and the **Metrics** block for `--deep`. Colour is used only on a TTY without `NO_COLOR`.
   - Add `CLI/apkrun/Commands/Doctor.swift` with `--deep`, `--fix`, and `--json` (`{schemaVersion: 1, result}`). Exit codes: `healthy` and `stopped` give 0, `degraded` without failures gives 3, and everything else gives 1.
   - Host-only mode: when `apkrund.reachable` fails, the CLI runs `HostChecks` itself and lists every other check as `skipped` with "Background service not running" and the remediation.
   - Check: T0 golden files (human and JSON) against a fake `RuntimeService`, one per verdict of §7.2, plus the host-only case ([../../02-design/cli.md](../../02-design/cli.md) §6.3).
4. **Troubleshooting and "Needs attention"** (§11 #059 step 4; [../../02-design/host-ui.md](../../02-design/host-ui.md) §9.8, §5.2, §12).
   - Build the list in `Apps/APKRun/Features/Troubleshooting/`, grouped as in §7.4. Groups where every check passes collapse to one line. Rows show "–" with the last known result while Android is stopped.
   - Add **Run Again** (the whole report, or one row through `checks`), **Deep Check**, and **Fix** on rows with a fix. **Restart Android**, **Start in Graphics Safe Mode** (or **Turn Off Graphics Safe Mode**), and **Reset Android…** call the existing runtime operations.
   - Show "Needs attention" in the runtime header and a dot plus "⚠ Needs attention" in the menu bar while a live check warns or fails. `apkrun://settings/troubleshooting` opens the pane.
   - Check: a T0 model test with a fake `RuntimeService` for grouping, collapse, and the header state. Opening the pane with Android stopped does not start it (T2-4 (a)).
5. **Fixes** (§11 #059 step 5, §7.5).
   - Implement the fixes of `wrappers.registration` (`LSRegisterURL`), `agent.ime` (select the APKRun IME again), `integrations.notificationListener` and `integrations.browserRole` (restore the grant or the role, custom image), `apkrund.registration` (CLI: `open -a APKRun --args --register-runtime` after a confirmation; app: `SMAppService.register`), and `apkrund.version` (`launchctl kickstart -k gui/<uid>/io.apkrun.apkrund`, offered only while Android is stopped).
   - `--fix` runs the fix of every `warning` or `failure` row that has one, prints "Fixed: ‹title›" or the error, then runs the whole report again. `applyHealthFixes` does the same for the app.
   - Check: T2-7 passes for `wrappers.registration` and `agent.ime`.
6. **Acceptance** (§11 #059 step 6, §12 T2-4).
   - Run the five T2-4 scenarios and check the verdict and the remediation of each.
   - Measure the quick report on a healthy runtime on the reference Mac. Record the time in [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14.
   - Check: the acceptance criteria below.

### Tests

- **T0** (in `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`, `Packages/RuntimeHost/Tests/RuntimeHostTests/`, `CLI/apkrun/Tests/`, and `Apps/APKRun/Tests/`). [diagnostics.md](../../02-design/diagnostics.md) §12 labels these "T1-n, unit". They are T0 here ([../test-strategy.md](../test-strategy.md) §2.8).
  - The verdict table of #061 (T1-6) against the full registry: every check of §7.4 feeds the verdict row its group names, and `graphicsFailure` still comes before `bootFailure`.
  - The error catalog: `en` text for every new code, declared placeholders, and no code equal to a health check ID (T1-4, English part).
  - Registry completeness, the timeout rule, and the no-start rule (step 1).
  - Wire-type round trips (step 2).
  - `DoctorFormatter` and CLI golden files for each verdict, `--json`, and host-only mode (step 3).
  - The Troubleshooting model (step 4).
- **T1** (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`, `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`):
  - `healthChanged` publishing over XPC (step 2).
  - `HostChecks` on the macOS runner: `host.appleSilicon`, `host.macOSVersion`, `host.dataVolume`, and `host.appSignature` against a signed test bundle.
  - T2-1, doctor part: host-only doctor with apkrund unregistered. The test runs in a separate macOS test user account. Relocating `APKRUN_HOME` does not work, because only `apkrun dev` reads it ([../../02-design/cli.md](../../02-design/cli.md) §3.6).
- **T2** (`Tests/IntegrationTests/DiagnosticsTests/`, AndroidCustom suite, custom image):
  - T2-4: (a) runtime stopped gives `stopped`. (b) test bundle F (`androidboot.apkrun.test.fail_boot=1`, [../test-strategy.md](../test-strategy.md) §3.5) gives `bootFailure` with the phase. (c) `APKRUN_GRAPHICS_FAULT=rendererInit` gives `graphicsFailure`. (d) `APKRUN_RUNTIME_FAULT=rejectAgent:guest` gives `agentUnavailable`. (e) A normal boot gives `healthy`. The fault hooks exist in debug builds only.
  - T2-7: `--fix` for `wrappers.registration` and `agent.ime`.
- **T3**: the quick doctor time (≤ 3 s) on the reference Mac, nightly ([../test-strategy.md](../test-strategy.md) §7.1). The doctor half of T3-2 (the Troubleshooting pane) is checklist item C05-7 ([../test-strategy.md](../test-strategy.md) §8.6).

### Acceptance criteria

- [ ] `apkrun doctor` checks Apple silicon, the macOS version, Virtualization support, the runtime files, the VM status, the Android boot state, graphics initialization, Guest Agent connectivity, Store Agent connectivity, and package store consistency (#059). Each check has the ID listed under Scope.
- [ ] Every row that is not passing shows a remediation (#059, FR-CLI-02).
- [ ] Doctor distinguishes a stopped runtime (`stopped`), an Android boot failure (`bootFailure` with the phase), a graphics failure (`graphicsFailure`), an unavailable Guest Agent (`agentUnavailable`), and a healthy runtime (`healthy`), each with the expected remediation (#059, FR-OPS-01, T2-4).
- [ ] Exit codes: 0 for `healthy` and `stopped`, 3 for warnings only, and 1 otherwise.
- [ ] With apkrund unreachable, the CLI prints the host checks and lists every other check as `skipped` with "Background service not running" and its remediation (T2-1).
- [ ] `--json` prints `{"schemaVersion": 1, "result": …}` with stable check IDs, states, and error codes.
- [ ] `--fix` repairs `wrappers.registration` and `agent.ime`, prints "Fixed: ‹title›", and reruns the report (T2-7).
- [ ] The quick report on a healthy runtime finishes in ≤ 3 s on the reference Mac.
- [ ] Neither `apkrun doctor` nor the Troubleshooting pane starts Android. `runningRuntime` checks show "–" with the last known result.
- [ ] The Troubleshooting pane has **Run Again** (all or one row), **Deep Check**, and **Fix**. The header and the menu bar show "Needs attention" while a live check warns or fails.

### Notes

- Record the measured quick and deep doctor times in [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14.
- [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §12 calls the unit tests "T1-n unit". They are T0 in this plan.
- The check names are mapped to check IDs under Scope. The additions over #059 (`--deep`, `--fix`, `--json`, the GUI list, live checks) come from [diagnostics.md](../../02-design/diagnostics.md) §7.
- If a module's check from an earlier task is missing or wrong, fix it in that module and in its design document in the same pull request (README §4). Do not reimplement it in DiagnosticsCore.
- Pitfall: `agent.*` checks must use the shared `Health` round trip, or the 2 s quick budget is at risk with many checks.

---

## #060 Diagnostics bundle

| Field | Value |
|---|---|
| Milestone | M11 (v0.5) |
| Depends on | #004, #059 |
| Requirements | FR-OPS-02, NFR-SEC-05, NFR-OBS-01, FR-CLI-01 |
| Design | [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §6, §8, §11, §12; [../../02-design/guest-protocol.md](../../02-design/guest-protocol.md) §7 (op 73), §10; [../../02-design/guest-components.md](../../02-design/guest-components.md) §6.1; [../../02-design/cli.md](../../02-design/cli.md) §4.8; [../../02-design/host-ui.md](../../02-design/host-ui.md) §3.1, §9.8; [../../02-design/wrapper.md](../../02-design/wrapper.md) §5.6 |
| Modules / paths | DiagnosticsCore (`Redactor`, `RedactionRules`, `ZipWriter`, `DiagnosticsBundleBuilder`, `DiagnosticsBundleWriter`, `DiagnosticsContributor`); RuntimeHost (`DiagnosticsService.createDiagnostics`, `maintenance/` and `host/` contributors); RuntimeCore, GraphicsCore, InputCore, ImageCore, APKStoreCore, UpdateCore, WrapperCore, IntegrationCore (contributors); RuntimeAPI (`DiagnosticsRequest`, `DiagnosticsResult`); GuestProtocol (op 73 items); `Guest/guestd` (`DiagnosticsService`); `CLI/apkrun/Commands/Diagnostics.swift`; `Apps/APKRun/Features/Troubleshooting/`; `Apps/APKRunLauncher/`; `Tests/IntegrationTests/`; `Tests/Fixtures/AndroidApps/` |
| Risks / questions | OQ-05 (`logcat -v uid` on the Android 17 image; working default: a PID → UID map), OQ-03 (package IDs in reports; working default: included, and the sheet says so). Open items: [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §13 |

### Goal

`apkrun diagnostics` and **Create Diagnostics Report…** produce a ZIP with a human-readable `summary.txt` and a `manifest.json`. The ZIP holds no secrets, clipboard contents, user files, app private data, or Google credentials. It is produced while healthy, after a boot failure, with the Guest Agent unavailable, and without apkrund.

### Scope

- The four redaction layers, the rules version, and the verification pass ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §6).
- The bundle flow with a client-opened file handle, a staging directory, budgets, progress, and cancel (§8.1).
- The contents of §8.2, one contributor per owning module.
- Guest data through `CollectDiagnostics` (op 73), the logcat filter, and the logcat capture after a failed boot (§8.3).
- The host-only bundle (§8.4).
- `createDiagnostics` on the control endpoint, CLI `apkrun diagnostics [--output <path>] [--include-logcat] [--package <id>] [--deep] [--json]`, the report sheet, `apkrun://report[?package=<id>]`, and the launcher's **Report a Problem…** (§8.5).
- The #060 contents, by section: host environment (`host/environment.json`), APKRun versions (`host/versions.json`), runtime status (`runtime/status.json`), graphics capabilities (`runtime/graphics.json`), the getprop subset (`guest/getprop.txt`), recent host and guest logs (`host/logs/`, `runtime/console/`, `guest/logcat.txt`), and installed package IDs and versions (`packages/packages.json`).
- Out of scope ([../../00-product/scope.md](../../00-product/scope.md) §5):
  - Uploading. APKRun has no upload code (§8.1).
  - Tombstone contents, screenshots, app data, and every other item of §6.1.
  - Starting Android to collect guest data.
  - Redacting local logs. Only what leaves the Mac in a report is redacted (§6.5).
  - The perf harness (#070) and the compatibility runs (#090).

### Deliverables

- In DiagnosticsCore: `Redactor` and `RedactionRules` (with `version`), `ZipWriter` (deflate through Compression.framework), `DiagnosticsBundleBuilder`, `DiagnosticsBundleWriter`, and the `summary.txt` and `manifest.json` writers.
- `DiagnosticsContributor` implementations in RuntimeCore, GraphicsCore, InputCore, ImageCore, APKStoreCore, UpdateCore, WrapperCore, IntegrationCore, and RuntimeHost, each with a budget.
- The remaining op 73 items in GuestProtocol and in the Guest Agent's `DiagnosticsService` ([../../02-design/guest-components.md](../../02-design/guest-components.md) §6.1). Op 73 itself and `DUMPSYS_MEMINFO` come from #070, and `DUMPSYS_SURFACEFLINGER` from #059.
- `createDiagnostics(DiagnosticsRequest) → OperationHandle → DiagnosticsResult` in RuntimeAPI and [../../03-reference/runtime-api.md](../../03-reference/runtime-api.md).
- `CLI/apkrun/Commands/Diagnostics.swift`, the report sheet in `Apps/APKRun/Features/Troubleshooting/`, and **Report a Problem…** in the launcher.
- `diagnostics` error codes (`DiagnosticsFailure`) in `Packages/DiagnosticsCore/ErrorCatalog/errors.json`.
- The secret fixtures: `APKRUN-FIXTURE-SECRET-<n>` values planted by the T2-6 test, `helloclipboard` and `hellonotification` in `Tests/Fixtures/AndroidApps/`, and the test-image property `persist.apkrun.test.secret`.
- The T1 test `DiagnosticsHostOnlyTests` (the bundle half of T2-1) in `Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`, and the T2 tests `DiagnosticsBundleTests` (T2-5), `DiagnosticsSecretFixtureTests` (T2-6), and `OperationIDTests` (T2-3) in `Tests/IntegrationTests/DiagnosticsTests/`.

### Implementation steps

1. **Redactor** ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §11 #060 step 1, §6).
   - L1: the never-collected list is enforced by the builder API (§6.1). No contributor can request those items.
   - L2: allowlists for getprop, config keys, package records, the unified log cut at U+001F, registry paths, and bootconfig placeholders (§6.2).
   - L3: structural reduction of the home directory, user and computer names, paths, URLs (to `scheme://host/…`), e-mail addresses, IP and MAC addresses, and `content://` URIs (§6.3).
   - L4: secret patterns (key=value secrets, JWT, `gh*`/`github_pat`/`ya29`/`AIza`/`AKIA`/`xox` tokens, PEM, base64 of 64 characters or more) and known secrets from the Keychain in raw, URL-encoded, base64, and UTF-16 forms. Matches become `<redacted:rule>` (§6.4).
   - Verification re-scans every file. A file that still contains a known secret is dropped with `redactionFailed` (§6.5). `RedactionRules.version` starts at 1.
   - Check: T0 Redactor tests (diagnostics T1-7) pass.
2. **Writer** (§11 #060 step 2, §8.1, §8.2).
   - `ZipWriter` streams deflate entries into a `FileHandle`. `DiagnosticsBundleBuilder` accepts only text or JSON under the bundle tree, and `.ips` files as the one exception.
   - `DiagnosticsBundleWriter` runs the staging directory (mode 0700, in apkrund's `$TMPDIR`), the redactor, `summary.txt` (English), `manifest.json` (`format 1`, random `reportID`, `files` with SHA-256, `omitted`, redaction counts, counters), and a 0600 ZIP. It deletes the staging directory at the end and on cancel.
   - Check: a T0 test builds the manifest and the summary from fake contributors, and a failing contributor appears in `omitted`. A T1 test writes the bundle to a temporary directory: `ditto -x -k` opens it, the manifest lists every file with the right SHA-256, the ZIP has mode 0600, and the staging directory is gone.
3. **Contributors** (§11 #060 step 3, §8.2).
   - Add one contributor per owner: RuntimeCore `runtime/` and `guest/`, GraphicsCore `runtime/graphics.json`, InputCore `runtime/input.json`, ImageCore `runtime/image/`, APKStoreCore `packages/`, UpdateCore `packages/updates.json`, WrapperCore `wrappers/`, IntegrationCore `integrations/`, RuntimeHost `maintenance/`, and RuntimeHost with DiagnosticsCore `host/`.
   - Apply the caps of §8.2 (24 h and 30 MiB of unified log, 7 days and at most 20 `.ips` files, the last 5 boots, 500 journal entries, 10 update entries per package, 500 and 50 perf records). Budgets: 10 s per host contributor and 45 s for `log show`.
   - `focusPackage` adds that package's full update history and its last 20 launch records, and orders its issues first in the summary.
   - Check: a T1 test with fake module services shows each contributor's files, and a contributor that exceeds its budget in `omitted`.
4. **Guest data** (§11 #060 step 4, §8.3).
   - Complete op 73 with every item of §8.3 that #070 and #059 did not add, including `GETPROP`. The item cap (16 MiB), the bulk transfer, the capability `diagnostics.v1`, and the 60 s timeout exist since #070.
   - Extend `DiagnosticsService` in the Guest Agent. It runs `logcat -d -b main,system,crash -v threadtime,uid,UTC,year`, reads the allowlisted properties, runs the dumpsys commands, and lists tombstones without their contents.
   - Add the host logcat filter. It keeps system UIDs (below 10000), APKRun tags, and the fatal-exception lines of app processes. `--include-logcat` keeps every line, still redacted.
   - Add the capture after a failed boot. When `daemon.json` records a failed last boot, RuntimeCore attaches `hvc2` as `.log("logcat")` for the next boot and writes `guest/logcat-<timestamp>.log`. The bundle includes the newest capture, filtered.
   - Verify `-v uid` on the Android 17 image. If the UID is missing, filter by a PID → UID map from `ps -A -o PID,UID` collected at the same time ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §13).
   - Check: T0 logcat filter tests (diagnostics T1-8) pass. Record the `-v uid` result in [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14.
5. **Control operation** (§11 #060 step 5, §8.1).
   - Add `createDiagnostics(DiagnosticsRequest{output, includeLogcat, deep, focusPackage?})` to the control endpoint. The client opens the file and passes the handle. apkrund never opens a user-chosen path.
   - Report progress through the `OperationHandle` (collecting, redacting, writing). Cancel deletes the partial output. The result carries the summary, the size, and the omitted items.
   - Check: T0 round-trip tests for the DTOs. A T1 test cancels during `redacting` and finds no output file.
6. **Entry points** (§11 #060 step 6, §8.4, §8.5).
   - CLI `apkrun diagnostics` with the default path `~/Desktop/APKRun-Diagnostics-<yyyyMMdd-HHmmss>.zip`. It prints the path and the summary, and `--json` prints the result.
   - Host-only bundle: when apkrund is unreachable, the CLI and APKRun.app build the bundle with DiagnosticsCore (`mode: "hostOnly"`, `createdBy: "cli"` or `"app"`), including `host/` with the `launchctl print gui/<uid>/io.apkrun.apkrund` output, `runtime/daemon.json`, `runtime/console/`, `runtime/crash/`, and `packages/packages.json` from `Packages/*/metadata.json`. The wrapper registry is listed in `omitted`.
   - GUI: the report sheet (included and never-collected items, a line saying that installed package IDs are included, **Include Android app logs** off by default, the focus package), the Save panel, progress with **Cancel**, then **Show in Finder**, **Copy Summary**, and the issue page link. `apkrun://report?package=<id>` only opens the sheet. Add the launcher's **Report a Problem…** (Help menu and error screens), which opens that URL, and the onboarding **Report…**.
   - Check: T0 CLI golden files for the full and host-only runs. A T0 model test shows that the URL opens the sheet and creates nothing.
7. **Acceptance** (§11 #060 step 7, §12 T2-5, T2-6).
   - Produce bundles while healthy, after a boot failure, with the Guest Agent unavailable, and with apkrund not running.
   - Run the secret fixture test.
   - Measure the time and the size of a healthy bundle on the reference Mac.
   - Check: the acceptance criteria below.

### Tests

- **T0** (in `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`, `CLI/apkrun/Tests/`, and `Apps/APKRun/Tests/`). [diagnostics.md](../../02-design/diagnostics.md) §12 labels these "T1-n, unit". They are T0 here ([../test-strategy.md](../test-strategy.md) §2.8).
  - T1-7 `Redactor`: every rule of §6.2–§6.4 on fixture text, stable placeholders within one report, known secrets in raw, URL-encoded, base64, and UTF-16 forms, and a dropped file when verification finds a known secret.
  - T1-8 logcat filter: system UID lines kept, app UID lines dropped, and app fatal-exception lines kept. `--include-logcat` keeps everything.
  - The manifest and summary, the DTO round trips, the CLI golden files, and the sheet model (steps 2, 5, 6).
- **T1** (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`, `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`):
  - The written ZIP, file modes, and staging cleanup (step 2); contributors and budgets (step 3); cancel (step 5).
  - T2-1, bundle part: a host-only bundle with apkrund unregistered, in the same separate macOS test user account as #059.
- **T2** (`Tests/IntegrationTests/DiagnosticsTests/`, AndroidCustom suite, custom image):
  - T2-5: a bundle while healthy, after a boot failure with test bundle F, with the Guest Agent unavailable (`APKRUN_RUNTIME_FAULT=rejectAgent:guest`), and without apkrund. Every expected file or `omitted` reason is present. The ZIP opens with `ditto -x -k`.
  - T2-6, the secret fixture test: `APKRUN-FIXTURE-SECRET-<n>` values are planted in a provider token (test Keychain), a URL query, a `.private` log argument, the console (test bundle S writes it to `/dev/kmsg`), app logcat (`helloclipboard` logs its clipboard text), the clipboard and a notification (`helloclipboard`, `hellonotification`), a shared folder file name, a wrapper path, the Mac user name (a test account), and getprop (`persist.apkrun.test.secret`, set by bundle S). The unzipped bundle contains none of them in raw, URL-encoded, base64, or UTF-16 form, with and without `--include-logcat`.
  - T2-3: the `OperationID` of an `apkrun install` appears in the CLI, apkrund, and Store Agent logs, and in the bundle's `host/logs/` and `guest/store.log`.
- **T3**: the bundle size and time (≤ 100 MiB, ≤ 60 s) on the reference Mac, nightly ([../test-strategy.md](../test-strategy.md) §7.1). The bundle half of T3-2 (**Create Diagnostics Report…** in Troubleshooting and **Report a Problem…** from a wrapper) is checklist item C05-7 ([../test-strategy.md](../test-strategy.md) §8.6).

### Acceptance criteria

- [ ] The bundle holds the host environment, the APKRun versions, the runtime status, the graphics capabilities, the getprop subset, recent host and guest logs, and the installed package IDs and versions (#060), in the layout of [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §8.2.
- [ ] Tokens, passwords, clipboard contents, user files, app private data, and Google credentials are redacted or never collected (#060, NFR-SEC-05).
- [ ] The output is a ZIP (mode 0600) with a human-readable `summary.txt` and a `manifest.json` (#060, FR-OPS-02).
- [ ] The archive is created while the runtime is healthy (#060, T2-5).
- [ ] The archive is created after an Android boot failure, with the console logs and boot phases of the failed boot (#060, T2-5).
- [ ] The archive is created with the Guest Agent unavailable and with apkrund not running (host-only mode). Missing items are listed in `omitted` with a reason (T2-5, T2-1).
- [ ] An automated test verifies that none of the secret fixture strings appears in the archive, with and without `--include-logcat` (#060, T2-6).
- [ ] A bundle of a healthy runtime is ≤ 100 MiB and takes ≤ 60 s on the reference Mac.
- [ ] Creating a report never starts Android. Cancel removes the partial file. apkrund never opens the user-chosen path.
- [ ] `apkrun://report?package=<id>` opens the sheet with the package preselected and creates nothing until **Create Report…** is clicked.

### Notes

- Record in [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §14 whether `logcat -v uid` works on the Android 17 image, or that the `ps` fallback is used.
- Package IDs are included by default, and the sheet says so ([diagnostics.md](../../02-design/diagnostics.md) §13). A request to exclude them becomes a follow-up task, not part of #060.
- `summary.txt` is English on purpose. The GUI shows the localized health report.
- Any new redaction rule increases `RedactionRules.version`.
- Pitfall: T2-6 must search for UTF-16 forms too. `.ips` files and dumpsys output can hold UTF-16 text.
