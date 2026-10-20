# M11 Diagnostics

M11 lets a user or maintainer tell every failure class apart without reading source code, and hand over a secret-free support file. `apkrun doctor` and the Troubleshooting pane show one health report with remediations. `apkrun diagnostics` and **Create Diagnostics Report…** produce a redacted ZIP. The ZIP is also produced after a boot failure and without apkrund. #61 depends on #60. M11 closes no gate, and it can run in parallel with M8–M10.

---

## #60 `apkrun doctor`

| Field | Value |
|---|---|
| Milestone | M11 (v0.5) |
| Depends on | #32, #35, #37 |
| Design | [diagnostics.md](../../02-design/diagnostics.md) §7; [runtime-daemon.md](../../02-design/runtime-daemon.md) §12; [cli.md](../../02-design/cli.md) §4.8; [host-ui.md](../../02-design/host-ui.md) §9.8 |
| Code | `Packages/DiagnosticsCore/` (`HealthCheckRegistry`, `HostChecks`, `DoctorFormatter`, `ErrorCatalog/errors.json`), `Packages/RuntimeHost/` (`DiagnosticsService`), `Packages/RuntimeAPI/` (`HealthRequest`, `HealthFixRequest`, `WireHealthReport`), `CLI/apkrun/Commands/Doctor.swift`, `Apps/APKRun/Features/Troubleshooting/`, `Apps/APKRunMenuBar/`, `Tests/IntegrationTests/DiagnosticsTests/` |

**Goal.** `apkrun doctor` and the Troubleshooting pane show one health report, grouped by subsystem, with a remediation on every row that does not pass. The verdict tells apart a stopped runtime, an Android boot failure, a graphics failure, an unavailable Guest Agent, and a healthy runtime. Doctor never starts Android.

**Out of scope.**
- The diagnostics bundle, the redactor, and **Create Diagnostics Report…** (#61).
- Checks that other modules own (`store.*`, `updates.*`, `wrappers.*`, `integrations.*`, `image.*`, `maintenance.*`). #60 registers and renders them and does not redefine them.
- `perfStatistics` (#71), the compatibility database (#91), and Japanese text (#93).
- Starting Android from doctor, and any fix that restarts Android while windows are open.

**Steps.**
1. **Registry.** `DiagnosticsService` in RuntimeHost builds apkrund's `HealthCheckRegistry` from every module's checks. Add the missing checks: `graphics.device`, `graphics.renderer`, `graphics.guestDriver` (deep), `graphics.present`, `graphics.memory`, `graphics.safeMode`, `agent.guest`, `agent.store`, `agent.input`, `agent.ime`, `agent.developerMode`, `apkrund.reachable`, `apkrund.version`, and `apkrund.crashLoop`. Extend the #62 `HostChecks`, and add the `restartPending` variant of `apkrund.version` from #58. Add `DUMPSYS_SURFACEFLINGER` to op 73 on the host and in the Guest Agent. Run rules: 2 s for quick checks and 60 s for deep ones, and a timeout gives `warning` "check timed out". At most 8 checks run at once. Guest checks share one `Health` round trip. `runningRuntime` checks return `skipped` "Android is not running" with `lastKnown`. **Check:** a T0 test shows each ID of [diagnostics.md](../../02-design/diagnostics.md) §7.4 exactly once, a timeout test with a fake clock, and no check calls the start path.
2. **Wire types and live checks.** Add `HealthRequest{deep, checks?}`, `HealthFixRequest{checks}`, and `WireHealthReport` to RuntimeAPI. Add `healthReport` and `applyHealthFixes` to the control endpoint only. Publish `healthChanged(HealthResult)` on the `health` topic. **Check:** T0 round trips pass, and a T1 test shows one `healthChanged` per `runtime.state` change.
3. **Output and exit codes.** `DoctorFormatter` in DiagnosticsCore renders groups, the symbols ✓ ℹ ⚠ ✕ –, indented remediations, the status line, and a **Metrics** block for `--deep`. It uses colour only on a TTY without `NO_COLOR`. `CLI/apkrun/Commands/Doctor.swift` adds `--deep`, `--fix`, and `--json` (`{schemaVersion: 1, result}`). Exit 0 for `healthy` and `stopped`, 3 for `degraded` without failures, and 1 otherwise. When apkrund is unreachable, the CLI runs `HostChecks` and lists every other check as `skipped` with "Background service not running". **Check:** golden files (human and JSON) for each verdict and for the host-only case.
4. **Troubleshooting pane.** `Apps/APKRun/Features/Troubleshooting/` lists the checks grouped as in [diagnostics.md](../../02-design/diagnostics.md) §7.4. A group where every check passes collapses to one line. Rows show "–" with the last result while Android is stopped. **Run Again** (all, or one row through `checks`), **Deep Check**, and **Fix** are available. **Restart Android**, **Start in Graphics Safe Mode** (or **Turn Off Graphics Safe Mode**), and **Reset Android…** call the existing operations. The header and the menu bar show "⚠ Needs attention" while a live check warns or fails. `apkrun://settings/troubleshooting` opens the pane. **Check:** a T0 model test covers grouping, collapse, and the header state.
5. **Safe fixes.** `wrappers.registration` runs `LSRegisterURL`. `agent.ime` selects the APKRun IME again. `integrations.notificationListener` and `integrations.browserRole` restore the grant or the role. `apkrund.registration` runs `open -a APKRun --args --register-runtime` after confirmation (CLI), or `SMAppService.register()` (app). `apkrund.version` runs `launchctl kickstart -k gui/<uid>/io.apkrun.apkrund`, and is offered only while Android is stopped. `--fix` runs the fix of each `warning` or `failure` row that has one, prints "Fixed: ‹title›" or the error, and then reruns the report. `applyHealthFixes` does the same in the app. **Check:** T2-7 passes for `wrappers.registration` and `agent.ime`.

**Tests.**
- T0 (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`, `Packages/RuntimeHost/Tests/RuntimeHostTests/`, `CLI/apkrun/Tests/`, `Apps/APKRun/Tests/`): the verdict table of #62 against the full registry (`graphicsFailure` before `bootFailure`), English text for each new error code, registry completeness, the timeout and no-start rules, wire round trips, formatter and CLI golden files, and the Troubleshooting model.
- T1 (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`, `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`): `healthChanged` over XPC. `HostChecks` on the macOS runner (`host.appleSilicon`, `host.macOSVersion`, `host.dataVolume`, `host.appSignature`). A host-only doctor with apkrund unregistered, in a separate macOS test account.
- T2 (`Tests/IntegrationTests/DiagnosticsTests/`, custom image): `DoctorVerdictTests` (T2-4): (a) stopped runtime gives `stopped`, and opening the pane does not start Android; (b) test bundle F (`androidboot.apkrun.test.fail_boot=1`, [test-strategy.md](../test-strategy.md) §3.5) gives `bootFailure` with the phase; (c) `APKRUN_GRAPHICS_FAULT=rendererInit` gives `graphicsFailure`; (d) `APKRUN_RUNTIME_FAULT=rejectAgent:guest` gives `agentUnavailable`; (e) a normal boot gives `healthy`. Fault hooks exist in debug builds only. `DoctorFixTests` (T2-7).
- T3: the quick doctor time (≤ 3 s) on the reference Mac, nightly ([test-strategy.md](../test-strategy.md) §7.1), and checklist C05-7 for the pane.

**Done when.**
- `apkrun doctor` checks every item of Scope step 1 and gives each check the ID in its row.
- Every row that is not passing shows a remediation (FR-CLI-02).
- The verdicts `stopped`, `bootFailure` (with the phase), `graphicsFailure`, `agentUnavailable`, and `healthy` each appear in their T2-4 case, with the expected remediation (FR-OPS-01).
- Exit codes are 0 for `healthy` and `stopped`, 3 for warnings only, and 1 otherwise.
- With apkrund unreachable, the CLI prints the host checks and lists the rest as `skipped` with its remediation.
- `--json` prints `{"schemaVersion": 1, "result": …}` with stable check IDs, states, and error codes.
- `--fix` repairs `wrappers.registration` and `agent.ime`, prints "Fixed: ‹title›", and reruns the report.
- The quick report on a healthy runtime finishes in ≤ 3 s on the reference Mac.
- Neither doctor nor the pane starts Android. `runningRuntime` checks show "–" with the last known result.
- The pane has **Run Again**, **Deep Check**, and **Fix**. The header and the menu bar show "Needs attention" while a live check warns or fails.

**Pitfalls.**
- The `agent.*` checks must share one `Health` round trip, or the 2 s quick budget is at risk.
- If an earlier module's check is wrong, fix it in that module and in its design document, in the same pull request. Do not reimplement it in DiagnosticsCore.

---

## #61 Diagnostics bundle

| Field | Value |
|---|---|
| Milestone | M11 (v0.5) |
| Depends on | #5, #60 |
| Design | [diagnostics.md](../../02-design/diagnostics.md) §6, §8; [guest-protocol.md](../../02-design/guest-protocol.md) §7 (op 73); [cli.md](../../02-design/cli.md) §4.8; [host-ui.md](../../02-design/host-ui.md) §9.8; [wrapper.md](../../02-design/wrapper.md) §5.6 |
| Code | `Packages/DiagnosticsCore/` (`Redactor`, `RedactionRules`, `ZipWriter`, `DiagnosticsBundleBuilder`, `DiagnosticsBundleWriter`, `DiagnosticsContributor`), `Packages/RuntimeHost/` (`DiagnosticsService.createDiagnostics`), contributors in RuntimeCore, GraphicsCore, InputCore, ImageCore, APKStoreCore, UpdateCore, WrapperCore, IntegrationCore, `Packages/RuntimeAPI/` (`DiagnosticsRequest`, `DiagnosticsResult`), `Guest/guestd/` (`DiagnosticsService`), `CLI/apkrun/Commands/Diagnostics.swift`, `Apps/APKRun/Features/Troubleshooting/`, `Apps/APKRunLauncher/`, `Tests/IntegrationTests/DiagnosticsTests/`, `Tests/Fixtures/AndroidApps/` |

**Goal.** `apkrun diagnostics` and **Create Diagnostics Report…** produce a ZIP with a human-readable `summary.txt` and a `manifest.json`. The ZIP holds no secrets, clipboard contents, user files, app private data, or Google credentials. It is produced while healthy, after a boot failure, with the Guest Agent unavailable, and without apkrund.

**Out of scope.**
- Uploading. APKRun has no upload code.
- Tombstone contents, screenshots, app data, and the other items that [diagnostics.md](../../02-design/diagnostics.md) §6.1 never collects.
- Starting Android to collect guest data. Redacting local logs: only what leaves the Mac is redacted ([diagnostics.md](../../02-design/diagnostics.md) §6.5).
- The perf harness (#71) and the compatibility runs (#91).

**Steps.**
1. **Redactor.** In DiagnosticsCore, follow [diagnostics.md](../../02-design/diagnostics.md) §6.1–§6.5. L1: the builder API has no way to request the never-collected items. L2: allowlists for getprop, config keys, package records, the unified log cut at U+001F, registry paths, and bootconfig. L3: reduce the home directory, user and computer names, paths, URLs (to `scheme://host/…`), e-mail, IP and MAC addresses, and `content://` URIs. L4: secret patterns and the known Keychain secrets in raw, URL-encoded, base64, and UTF-16 forms, replaced by `<redacted:rule>`. A final re-scan drops any file that still holds a known secret (`redactionFailed`). `RedactionRules.version` starts at 1. **Check:** the redactor tests of the Tests section pass.
2. **Writer.** `ZipWriter` streams Compression.framework deflate entries into the client's `FileHandle`. `DiagnosticsBundleBuilder` accepts text and JSON only, plus `.ips` files. `DiagnosticsBundleWriter` uses a staging directory (mode 0700 in `$TMPDIR`), runs the redactor, and writes `summary.txt` (English), `manifest.json` (`format 1`, random `reportID`, SHA-256 of each file, `omitted`, redaction counts), and a 0600 ZIP. It deletes the staging directory at the end and on cancel. **Check:** a T1 test shows that `ditto -x -k` opens the ZIP, the manifest hashes match, the mode is 0600, and the staging directory is gone.
3. **Contributors.** One `DiagnosticsContributor` per owner: RuntimeCore (`runtime/`, `guest/`), GraphicsCore (`runtime/graphics.json`), InputCore (`runtime/input.json`), ImageCore (`runtime/image/`), APKStoreCore (`packages/`), UpdateCore (`packages/updates.json`), WrapperCore (`wrappers/`), IntegrationCore (`integrations/`), and RuntimeHost (`maintenance/`, `host/`). Apply the caps of [diagnostics.md](../../02-design/diagnostics.md) §8.2 and a budget of 10 s per host contributor (45 s for `log show`). `focusPackage` adds that package's update history and last 20 launch records, and lists its issues first. **Check:** a T1 test with fake services shows each contributor's files, and an over-budget contributor appears in `omitted`.
4. **Guest data.** Complete op 73 with the items of [diagnostics.md](../../02-design/diagnostics.md) §8.3 that #60 and #71 did not add, including `GETPROP`. The Guest Agent's `DiagnosticsService` runs `logcat -d -b main,system,crash -v threadtime,uid,UTC,year`, reads the allowlisted properties, runs the dumpsys commands, and lists tombstones without their contents. The host filter keeps system UIDs (below 10000), APKRun tags, and the fatal-exception lines of app processes. `--include-logcat` keeps every line, still redacted. After a failed boot, RuntimeCore attaches `hvc2` as `.log("logcat")` for the next boot and writes `guest/logcat-<timestamp>.log`. The bundle includes the newest capture, filtered. Verify `-v uid` on the Android 17 image. If the UID is missing, filter with a PID → UID map from `ps -A -o PID,UID`, taken at the same time. Record the result in [open-questions.md](../open-questions.md) (OQ-05). **Check:** the logcat filter tests pass.
5. **Control operation.** `createDiagnostics(DiagnosticsRequest{output, includeLogcat, deep, focusPackage?})` is on the control endpoint. The client opens the file and passes the handle. apkrund never opens a user-chosen path. Progress goes through `OperationHandle` (collecting, redacting, writing). Cancel deletes the partial output. The result carries the summary, the size, and the omitted items. **Check:** T0 DTO round trips pass, and a T1 test that cancels during `redacting` finds no output file.
6. **Entry points.** `apkrun diagnostics [--output <path>] [--include-logcat] [--package <id>] [--deep] [--json]` uses the default `~/Desktop/APKRun-Diagnostics-<yyyyMMdd-HHmmss>.zip`. When apkrund is unreachable, the CLI or APKRun.app builds a host-only bundle (`mode: "hostOnly"`, `createdBy: "cli"` or `"app"`). It holds `launchctl print gui/<uid>/io.apkrun.apkrund`, `runtime/daemon.json`, `runtime/console/`, `runtime/crash/`, and `packages/packages.json` from `Packages/*/metadata.json`. The wrapper registry is listed in `omitted`. The GUI sheet shows the included and never-collected items, says that installed package IDs are included, offers **Include Android app logs** (off by default) and a focus package, and then a Save panel, progress with **Cancel**, and **Show in Finder**, **Copy Summary**, and the issue link. `apkrun://report[?package=<id>]` only opens the sheet. The launcher's **Report a Problem…** (Help menu and error screens) opens it. **Check:** T0 CLI golden files for the full and host-only runs pass, and a model test shows that the URL opens the sheet and creates nothing.
7. **Acceptance.** Produce bundles while healthy, after a boot failure, with the Guest Agent unavailable, and with apkrund stopped. Run the secret fixture test. Measure the time and size of a healthy bundle. **Check:** every Done-when item passes.

**Tests.**
- T0 (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`, `CLI/apkrun/Tests/`, `Apps/APKRun/Tests/`): every redaction rule on fixture text, stable placeholders within one report, the known secrets in raw, URL-encoded, base64, and UTF-16 forms, and the dropped file on a failed re-scan. The logcat filter (system UIDs kept, app UIDs dropped, app fatal-exception lines kept, `--include-logcat` keeps all). The manifest and summary, DTO round trips, CLI golden files, and the sheet model.
- T1 (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreSystemTests/`, `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`): the ZIP, its modes, staging cleanup, contributors and budgets, and cancel. `DiagnosticsHostOnlyTests` (the bundle part of T2-1), in the separate macOS test account used by #60.
- T2 (`Tests/IntegrationTests/DiagnosticsTests/`, custom image): `DiagnosticsBundleTests` (T2-5): a bundle while healthy, after a boot failure with test bundle F, with the Guest Agent unavailable (`APKRUN_RUNTIME_FAULT=rejectAgent:guest`), and without apkrund. Every expected file or `omitted` reason is present, and `ditto -x -k` opens the ZIP. `DiagnosticsSecretFixtureTests` (T2-6): `APKRUN-FIXTURE-SECRET-<n>` values are planted in a provider token, a URL query, a `.private` log argument, the console, app logcat, the clipboard and a notification, a shared-folder file name, a wrapper path, the Mac user name, and `persist.apkrun.test.secret` in getprop. None may appear in any form, with or without `--include-logcat`. `OperationIDTests` (T2-3): an `apkrun install` OperationID appears in the CLI, apkrund, and Store Agent logs, and in the bundle's `host/logs/` and `guest/store.log`.
- T3: the bundle size and time on the reference Mac, nightly ([test-strategy.md](../test-strategy.md) §7.1), and the bundle half of checklist C05-7.

**Done when.**
- The bundle holds the host environment, APKRun versions, runtime status, graphics capabilities, the getprop subset, host and guest logs, and installed package IDs and versions, in the layout of [diagnostics.md](../../02-design/diagnostics.md) §8.2.
- Tokens, passwords, clipboard contents, user files, app private data, and Google credentials are redacted or never collected (NFR-SEC-05).
- The output is a ZIP with mode 0600, with a human-readable `summary.txt` and a `manifest.json` (FR-OPS-02).
- The ZIP is created while healthy, after an Android boot failure (with the console logs and boot phases of the failed boot), with the Guest Agent unavailable, and with apkrund not running. Missing items are listed in `omitted` with a reason.
- No secret fixture string appears in the archive, with or without `--include-logcat`.
- A healthy bundle is ≤ 100 MiB and takes ≤ 60 s on the reference Mac.
- Creating a report never starts Android. Cancel removes the partial file. apkrund never opens the user-chosen path.
- `apkrun://report?package=<id>` opens the sheet with the package preselected, and creates nothing until **Create Report…** is clicked.

**Pitfalls.**
- The secret test must search UTF-16 forms too. `.ips` files and dumpsys output can hold UTF-16 text.
- Any new redaction rule increases `RedactionRules.version`.
- The summary is English on purpose. The GUI shows the localized health report. Excluding package IDs from reports is a follow-up task, not part of #61.
