# Diagnostics, observability, and performance measurement

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../01-architecture/modules.md](../01-architecture/modules.md) (DiagnosticsCore), [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §2, [../01-architecture/security-model.md](../01-architecture/security-model.md), [runtime-daemon.md](runtime-daemon.md) §3.6, §9.1, §12, [cli.md](cli.md) §3, §4.8, [host-ui.md](host-ui.md) §9.8, [guest-protocol.md](guest-protocol.md) (`CollectDiagnostics`, `Health`), [../03-reference/error-catalog.md](../03-reference/error-catalog.md) |
| Tasks | #061 diagnostics foundation (M0), #070 performance harness (M4), #059 `apkrun doctor` (M11), #060 diagnostics bundle (M11), #090 compatibility database (M12) |

This document defines how APKRun reports errors, writes logs, measures performance, checks its own health, and packages all of that into a report a user can attach to a bug. Every subsystem design has a "Logging, markers, health" section. This document is the common model those sections plug into.

---

## 1. Responsibilities and components

`DiagnosticsCore` is a leaf module ([../01-architecture/modules.md](../01-architecture/modules.md) §2). It imports no other APKRun module, so every process can use it: apkrund, APKRun.app, APKRunMenuBar, the launcher, and the CLI.

| Component (DiagnosticsCore) | Role | Section |
|---|---|---|
| `APKRunPaths` | every file path of [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) | — |
| `BuildInfo` | version, build number, git commit, configuration (debug/release), embedded-runtime flag | §8.2 |
| `APKRunError`, `ErrorDomain`, `RemediationAction`, `ErrorCatalog` | the error model and its texts | §2 |
| `OperationID`, `OperationContext` | correlation of one user-visible operation across processes and into the guest | §2.4 |
| `APKLogger`, `LogSubsystem`, `LogMessage`, `Sensitive<T>`, `LogSink`, `LogMirrorWriter` | the logging facade. `APKLogger` writes through the `LogSink` protocol: `os.Logger` in production, `RecordingLogSink` in tests | §3 |
| `PerfMarker`, `Perf`, `PerfTimeline`, `PerfRecordWriter` | lifecycle markers and signposts | §4 |
| `MetricsSampler`, `MetricsSnapshot` | process CPU and memory sampling | §5 |
| `Redactor`, `RedactionRules` | redaction of everything that leaves the Mac in a report | §6 |
| `HealthCheck`, `HealthResult`, `HealthReport`, `HealthCheckRegistry`, `HostChecks`, `DoctorFormatter` | the health model and `apkrun doctor` | §7 |
| `DiagnosticsContributor`, `DiagnosticsBundleWriter`, `ZipWriter` | the diagnostics bundle | §8 |
| `DiagnosticsContext` | the `Sendable` value that module entry points receive (for example `VMController.init`, [vm.md](vm.md) §2): the `LogSink`, the `HealthCheckRegistry`, the `PerfTimeline`, `APKRunPaths`, and a clock. `DiagnosticsContext.live(paths:)` builds the production value; `DiagnosticsContext.testing()` lives in `DiagnosticsCoreTestSupport` | — |

Components outside DiagnosticsCore:

| Component | Module | Role |
|---|---|---|
| `DiagnosticsService` | RuntimeHost | serves the health, diagnostics, and statistics operations of the control endpoint (§7.6, §8.1); owns the apkrund `HealthCheckRegistry` and contributor list |
| Health checks and contributors | each module | implement the checks listed in their design documents (§7.4) and contribute their bundle sections (§8.2) |
| `CompatibilityDatabase`, `PackageSettingsResolver` | APKStoreCore | the compatibility database (§10) |
| `apkrun-perf` | `Tests/PerformanceTests/` | the performance harness (§9) |
| Wire types (`WireError`, `WireHealthReport`, `WirePerfStatistics`, `DiagnosticsRequest`) | RuntimeAPI | field-for-field copies of the DiagnosticsCore types. RuntimeAPI imports only Foundation and IOSurface ([../01-architecture/modules.md](../01-architecture/modules.md) §3), so RuntimeHost converts to wire types and RuntimeClient converts back. A round-trip test covers every type |

---

## 2. Error model (#061, FR-CLI-02, NFR-DEV-03)

### 2.1 `APKRunError`

Every error that can reach a user is a typed domain error ([../01-architecture/overview.md](../01-architecture/overview.md), "Typed errors"). Each domain enum conforms to `APKRunError`:

```swift
public protocol APKRunError: Error, Sendable {
    static var domain: ErrorDomain { get }
    var code: String { get }                          // the enum case name, stable: "downgradeRefused"
    var parameters: [String: ErrorParameter] { get }  // public-safe values for the message template
    var cause: (any APKRunError)? { get }             // a nested domain error, if any
    var underlying: UnderlyingError? { get }          // a system error: domain and code only
}

public extension APKRunError {
    var qualifiedCode: String { "\(Self.domain.rawValue).\(code)" }   // "store.downgradeRefused"
}

public enum ErrorParameter: Sendable, Codable, Equatable {
    case text(String)            // must be public-safe: package ID, version name, app label, step name
    case bytes(Int64)            // formatted with ByteCountFormatter
    case count(Int)
    case duration(Duration)
    case fileName(String)        // last path component only. Full paths are never parameters
}

public struct UnderlyingError: Sendable, Codable, Equatable {
    public var domain: String    // "VZErrorDomain", "NSPOSIXErrorDomain", "OSStatus"
    public var code: Int         // userInfo is dropped: it may contain paths (NSFilePathErrorKey)
}
```

| Domain (`ErrorDomain`) | Swift type | Code prefix | Owner |
|---|---|---|---|
| `vm` | `VMFailure`, `VMConfigurationFailure` | `vm.` | VirtualMachineCore ([vm.md](vm.md)) |
| `graphics` | `GraphicsFailure` | `graphics.` | GraphicsCore ([graphics.md](graphics.md)) |
| `runtime` | `RuntimeFailure` | `runtime.` | RuntimeCore, RuntimeHost ([runtime-daemon.md](runtime-daemon.md)) |
| `guestProtocol` | `GuestProtocolFailure` | `guestProtocol.` | GuestProtocol ([guest-protocol.md](guest-protocol.md)) |
| `image` | `ImageFailure` | `image.` | ImageCore ([android-image.md](android-image.md)) |
| `store` | `StoreFailure` | `store.` | APKStoreCore ([package-store.md](package-store.md)) |
| `update` | `UpdateFailure` (with nested `ValidationFailure`, `HealthCheckFailure`) | `update.` | UpdateCore ([update-system.md](update-system.md)) |
| `wrapper` | `WrapperFailure` | `wrapper.` | WrapperCore ([wrapper.md](wrapper.md)) |
| `integration` | `IntegrationFailure` | `integration.` | IntegrationCore ([desktop-integration.md](desktop-integration.md)) |
| `maintenance` | `MaintenanceFailure` | `maintenance.` | APKRun and image updates ([runtime-maintenance.md](runtime-maintenance.md)) |
| `diagnostics` | `DiagnosticsFailure` | `diagnostics.` | DiagnosticsCore (this document, below) |
| `cli` | `CLIFailure` | `cli.` | CLI ([cli.md](cli.md)), for example `cli.confirmationRequired` |

Rules:

- A code never changes meaning once released. A removed case keeps its code reserved in the catalog (`"retired": true`).
- Nested errors (`UpdateFailure.installFailed(StoreFailure)`) keep the outer code. The outer message may include `{cause}`, which renders the inner message. When the outer entry has no remediation, the inner one is used. JSON output carries the chain (`cause`).
- Error codes, configuration keys, and health check IDs use the same `<domain>.<name>` shape but are separate namespaces. A catalog test fails if an error code equals a health check ID, so they cannot be confused in support conversations.
- `fatalError` and `preconditionFailure` are for programming errors only. Anything caused by input, the guest, the host, or the network is a typed error.

DiagnosticsCore's own domain covers reports, fixes, and the findings of the host and background service checks (§7.3). The findings are never thrown. They are only the `HealthResult.error` of their checks ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §15):

```swift
public enum DiagnosticsFailure: APKRunError {
    // reports and fixes (§7.5, §7.6, §8.1)
    case stagingFailed                                  // the staging directory in $TMPDIR can't be created or written (§8.1 step 3)
    case bundleWriteFailed                              // writing the ZIP into the client's file handle fails. apkrund truncates the output; the client deletes the file
    case unknownHealthCheck(check: HealthCheckID)       // healthReport or applyHealthFixes names an ID that this apkrund doesn't have (an N−1 client)
    case fixNotAvailable(check: HealthCheckID)          // the check has no fix, or its fix is not offered now (apkrund.version while Android runs)
    case fixFailed(check: HealthCheckID, underlying: any APKRunError)   // a fix ran and failed. The fix's error is the cause
    // findings of the host and background service checks (§7.3), never thrown
    case appNotInApplications                           // host.appLocation
    case appSignatureInvalid                            // host.appSignature
    case componentVersionMismatch(build: String)        // host.componentVersions
    case lowDiskSpace(available: Int64)                 // host.dataVolume, image.freeSpace, and the store.hostSpace warning
    case lowMemory(memory: Int64)                       // host.memory
    case serviceVersionMismatch(build: String)          // apkrund.version. Variants restartPending, androidRunning
    case serviceCrashLoop(count: Int)                   // apkrund.crashLoop
}
```

A cancelled report is `runtime.cancelled`. A contributor that fails or runs out of time is not an error: it is recorded in `omitted` (§8.1).

### 2.2 The error catalog

The catalog is the single source of user-facing error text for the GUI, the menu bar, the launcher, and the CLI ([host-ui.md](host-ui.md) §13).

- Human-readable design source: [../03-reference/error-catalog.md](../03-reference/error-catalog.md). #061 turns it into `Packages/DiagnosticsCore/ErrorCatalog/errors.json`. From then on the JSON is the source, and `swift scripts/errorgen.swift --markdown` regenerates the tables of [../03-reference/error-catalog.md](../03-reference/error-catalog.md) §5–§16 and §20.3. CI fails if the two differ.
- `errors.json` entry:

  ```json
  {
    "code": "store.downgradeRefused",
    "parameters": ["app", "installedVersion", "newVersion"],
    "message":     { "en": "{app} {newVersion} is older than the installed version {installedVersion}.",
                     "ja": "…" },
    "remediation": { "en": "Keep the installed version, or uninstall {app} first.", "ja": "…" },
    "action": "none",
    "cliExit": 5
  }
  ```

- Optional members ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §3.1):
  - `variants`: texts and an action per sub-reason, for example per `InstallFailureKind` of `store.guestInstallFailed`. The keys are the case names of the sub-enum, or the fixed keys `hostNewer`, `guestNewer`, `sharedFolders`, `schemaVersion`, `restartPending`, and `androidRunning`. The error passes the key as the parameter `reason`. A variant may override `message`, `remediation`, and `action`. Code, parameters, and `cliExit` stay those of the entry. A list case (`vm.configurationInvalid`, `runtime.hostRequirementsNotMet`) passes the case names of its items in the parameter `items`, and each item renders its variant as one hint line ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §3.4).
  - `transparent: true`: a pure container such as `runtime.image(ImageFailure)`. It has no text of its own. Message, remediation, action, and exit code come from the first non-transparent error in the cause chain. `"cliExit": "cause"` is allowed only on a transparent entry ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §3.5).
  - `retired: true`: a removed case. Its entry keeps its last texts, so a code that an N−1 peer sends still renders. errorgen generates no Swift for it ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §2.2).
  - `cliExitRule`: a named rule for list errors whose exit depends on their items. The entry's fixed `cliExit` is the fallback, and the catalog defines each supported rule.
- A code that the receiving build doesn't know is treated as transparent when its cause chain contains a known code. Otherwise the generic entry of [../03-reference/error-catalog.md](../03-reference/error-catalog.md) §3.8 is shown, and the `code:` line keeps the original code.
- `swift scripts/errorgen.swift` generates `ErrorCatalog.generated.swift` with every language compiled in as Swift literals. The generated file is checked in, and CI verifies that it is current. Compiling the strings in is required because the launcher carries no resource bundles ([wrapper.md](wrapper.md) §5.9).
- Language selection follows `Locale.preferredLanguages` of the presenting process, with English as the fallback.
- Tests: every case of every domain enum has a catalog entry (one test per module, iterating a `CaseIterable` fixture list of representative values); every placeholder in a template is declared in `parameters`; every entry has `en` and `ja` text in release builds (#092); every `cliExit` value is one of the exit codes of [cli.md](cli.md) §3.3, or `"cause"` on a transparent entry, and `CLI/apkrun/Support/ExitCodes.swift` agrees with it. Named `cliExitRule`s have catalog-specific validation and deterministic fallback behavior.

### 2.3 Remediation actions and presentation

```swift
public enum RemediationAction: String, Sendable, Codable {
    case none, retry, openTroubleshooting, restartAndroid, startGraphicsSafeMode,
         openRuntimeSettings, openStorageSettings, openPrivacySettings,
         openLoginItemsSettings,        // System Settings → General → Login Items & Extensions
         openNotificationSettings,      // System Settings → Notifications
         openDownloadsPage,             // the APKRun downloads page in the browser
         updateAPKRun, updateAndroid, updateMacApp, createMacApp, reinstallApp, reportProblem
}
```

`updateAPKRun` opens Settings → General and starts a user-initiated Sparkle check. `updateAndroid` opens Settings → General and starts the Android system update (check, download, and apply, [runtime-maintenance.md](runtime-maintenance.md) §4.6). `openDownloadsPage` is the action for "reinstall APKRun": it opens the Info.plist URL `APKRunDownloadsURL` ([../03-reference/configuration.md](../03-reference/configuration.md) §7.1) with `NSWorkspace.open(_:)`. The launcher opens `LauncherBuild.downloadURL`, the same URL compiled into the launcher template, because APKRun.app may be missing ([wrapper.md](wrapper.md) §5.4).

| Surface | Presentation |
|---|---|
| APKRun.app, APKRunMenuBar | alert or inline error view: the message as the title, the remediation as the body, a button for `action` (for example **Restart Android**), **Copy Details**, and **Troubleshooting…** where it helps ([host-ui.md](host-ui.md) §1) |
| Launcher (wrapper window) | the error screens of [wrapper.md](wrapper.md) §5.4 with the same texts and actions |
| CLI | three lines on stderr (below). `--json` puts the same fields in the `error` object ([cli.md](cli.md) §3.2) |

CLI format (FR-CLI-02):

```text
error: Hello GL 1.2 is older than the installed version 1.3.
hint: Keep the installed version, or uninstall Hello GL first.
code: store.downgradeRefused (operation 3f9a1c2e)
```

**Copy Details** copies one line with no personal data:

```text
APKRun 1.0 (1000) · image 2026.10.0-cf16373615-arm64 · store.downgradeRefused · op 3f9a1c2e-5b7d-4e8f-9a01-2c3d4e5f6a7b · 2026-09-28T10:15:02Z · underlying NSPOSIXErrorDomain 28
```

### 2.4 Operation IDs

An `OperationID` ties together everything that happens for one user-visible operation (NFR-OBS-01).

- Format: a random UUID (version 4), lowercase. UI and CLI human output show the first 8 hex digits. JSON and Copy Details use the full value; logs use `op=<first 8 hex>` as specified in §3.2.
- Created by the client that starts the operation: the GUI or CLI for a command, the launcher for `openSession`. apkrund creates IDs for work it starts itself (scheduled update runs, idle stop, recovery at startup).
- Carried in `APIRequestHeader.operationID` over XPC ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.1), in `OperationHandle` for long-running operations, and in the guest envelope's `operation_id` ([guest-protocol.md](guest-protocol.md) §4.1).
- Inside a process, `OperationContext` is a task-local value (`@TaskLocal static var current`). `APKLogger` adds it to every entry automatically. Work started from a task inherits it. A sub-operation (one package of `apkrun update --all`) gets its own ID with `parent` set to the run's ID.
- Guest agents log `op=<first 8 hex>` with every entry that has an operation ID ([guest-components.md](guest-components.md) §9).
- Operation IDs identify operations, not users or Macs. They are safe in bug reports.

---

## 3. Logging (#061, NFR-OBS-01, NFR-SEC-05)

### 3.1 Subsystems and categories

Unified logging (`os_log`) is the primary sink. Every host process logs only through `APKLogger`. Direct use of `os.Logger`, `print`, or `NSLog` outside DiagnosticsCore fails `scripts/check-logging.sh` (CI, #062).

| Subsystem | Processes | Categories | Defined in |
|---|---|---|---|
| `io.apkrun.runtime` | apkrund | `host`, `supervisor`, `agents`, `idle`, `power`, `sessions`, `display`, `xpc` | [runtime-daemon.md](runtime-daemon.md) §12 |
| `io.apkrun.vm` | apkrund | `lifecycle`, `config`, `console`, `vsock`, `network`, `virtio` (VirtioDeviceCore) | [vm.md](vm.md) §14 |
| `io.apkrun.graphics` | apkrund | `device`, `renderer`, `present`, `stats` | [graphics.md](graphics.md) |
| `io.apkrun.input` | launcher, apkrund | `translate`, `route`, `ime` | [input.md](input.md) §11 |
| `io.apkrun.image` | apkrund | `store`, `install`, `verify`, `instance`, `boot`, `migration` | [android-image.md](android-image.md) §14 |
| `io.apkrun.store` | apkrund | `import`, `transaction`, `channel`, `reconcile` | [package-store.md](package-store.md) §13 |
| `io.apkrun.update` | apkrund | `scheduler`, `provider`, `validate`, `install`, `health` | [update-system.md](update-system.md) §14 |
| `io.apkrun.wrapper` | apkrund, launcher | `generate`, `sign`, `icon`, `registry`, `approval`, `lifecycle`, `launcher`, `window`, `integration` | [wrapper.md](wrapper.md) §14 |
| `io.apkrun.integration` | apkrund | `clipboard`, `notifications`, `links`, `files`, `audio`, `locale` | [desktop-integration.md](desktop-integration.md) §13 |
| `io.apkrun.maintenance` | APKRun.app, apkrund | `selfUpdate`, `imageUpdate` | [runtime-maintenance.md](runtime-maintenance.md) |
| `io.apkrun.ui` | APKRun.app | `app`, `onboarding`, `operations`, `approval`, `settings` | [host-ui.md](host-ui.md) |
| `io.apkrun.menubar` | APKRunMenuBar | `status` | [host-ui.md](host-ui.md) §12 |
| `io.apkrun.cli` | apkrun | `command`, `client` | [cli.md](cli.md) |
| `io.apkrun.diagnostics` | all | `health`, `bundle`, `perf`, `redaction` | this document |

`LogSubsystem` is a closed enum with exactly these values. Categories are per-subsystem enums, so a typo is a compile error.

### 3.2 The facade and privacy

```swift
let log = APKLogger(.store, category: .transaction)
log.info("commit \(txn, .public) \(packageID, .public) \(fromCode, .public)→\(toCode, .public)")
log.error("import failed for \(fileName, .private)", error: failure)   // adds err=store.<code>
```

- `LogMessage` is a custom string-interpolation type. **Every interpolation must state its privacy** (`.public`, `.private`, or `.hashed`). There is no default, so forgetting is a compile error.
- `.hashed` renders `#` plus the first 8 hex digits of SHA-256 over a random salt created at process start and the value. It lets a reader see that two entries refer to the same file without seeing the name. Hashes correlate within one process lifetime only.
- `Sensitive<T>` wraps values that must never be logged at any level: clipboard content, notification title and text, IME text, file contents, credentials and tokens, Android account names. Its `description` is `<redacted>`, and `LogMessage` has no interpolation overload for it, so logging one does not compile. IntegrationCore, InputCore, and UpdateCore (provider credentials) hold these values only inside `Sensitive`.
- Structured context: the facade appends ` op=<id8> pkg=<packageID> disp=<displayID> sess=<sessionID> err=<qualifiedCode>` from `OperationContext` and the call's `error:` argument (NFR-OBS-01). These fields are always public. `apkrun logs` and the bundle's "Recent problems" (§8.3) parse them.
- Rendering: the facade renders a **public text**, where private values become `<private>` and hashed values become their hash, and, only when the message has private values, a **full text**. It sends `"\(publicText, privacy: .public)\u{1F}\(fullText, privacy: .private)"` to `os.Logger`. Unified logging shows the second part as `<private>` unless a private-data logging profile is installed. The bundle writer cuts every entry at U+001F, so a developer Mac with such a profile still produces a clean report (§6.2).
- Messages are rendered only if the level is enabled (`OSLog.isEnabled(type:)`), so debug messages cost almost nothing in release builds.
- What may be public: IDs (package, bundle, session, display, operation, transaction), versions, error codes, counts, sizes, durations, states, digests truncated to 12 hex, provider type and host name. What must be `.private` or `.hashed`: paths (after `APKRunPaths` reduction, §6.3), file names, URLs beyond scheme and registrable domain, window titles, Android app labels in free text. What is never logged: everything that `Sensitive` wraps. Input details (key codes, pointer positions) are `.private` and logged only at debug level in development builds ([input.md](input.md) §9).

| Level | Use |
|---|---|
| `debug` | per-frame, per-event, and per-message detail. Off in release unless enabled with `log config` |
| `info` | state transitions, operation start and end, timings |
| `notice` (`default`) | user-visible outcomes: installed, updated, rolled back, Android started or stopped |
| `error` | an operation failed with a typed error. Always carries `err=` |
| `fault` | an invariant was violated (for example an invalid state transition, [../01-architecture/state-machines.md](../01-architecture/state-machines.md)) |

### 3.3 File mirrors

`os_log` can be unavailable for reports: `log show` needs an administrator account and can be slow on busy Macs. apkrund therefore keeps file mirrors ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §2):

| File | Writer | Content | Rotation |
|---|---|---|---|
| `apkrund.log`, `apkrund.1.log`, `apkrund.2.log` | `LogMirrorWriter` in apkrund | the public text of every `info` and higher entry of apkrund, one line each: ISO 8601 time, level, subsystem/category, message, structured fields | 10 MiB × 3 |
| `vm/console.log`, `vm/console.<n>.log`, `vm/boot-<timestamp>.log` | `ConsoleLogWriter` ([vm.md](vm.md)) | guest serial console, unredacted | 20 MiB × 5; last 5 boots |
| `guest/logcat-<timestamp>.log` | RuntimeCore | logcat console capture (§8.3) | 20 MiB each; last 5 |
| `crash/<timestamp>-runtime/` | RuntimeCore | failure snapshots ([runtime-daemon.md](runtime-daemon.md) §3.6) | last 10 |
| `perf/launches.jsonl`, `perf/boots.jsonl` | `PerfRecordWriter` in apkrund | perf records (§4.3) | newest 2,000 / 200 records |

- The mirror writer is asynchronous: a serial queue with a 1 MiB buffer, flushed every second and immediately after `error` and `fault` entries. A slow disk never blocks a logging call. When the buffer is full, entries are dropped and counted (`diagnostics.mirrorDropped`, shown in the bundle manifest).
- Other processes (APKRun.app, the menu bar, launchers, the CLI) do not write mirrors. Their entries are in unified logging, and their failures that matter reach apkrund as operation results.
- Files are created with mode 0600. The logs directory is not in any location that syncs or backs up differently from the rest of `~/Library`.

### 3.4 Guest logs

| Source | Content | Reaches the host through |
|---|---|---|
| logcat tags `ApkRunGuest`, `ApkRunInput`, `ApkRunIme`, `ApkRunStore`, `apkrun_vsockd` | agent logs ([guest-components.md](guest-components.md) §9) | `CollectDiagnostics` (§8.3), logcat capture |
| `agent.log`, `store.log` ring buffers (2 × 1 MiB) | agent logs that survive logcat rotation | `CollectDiagnostics` item `AGENT_LOG` |
| Kernel log, init, `VIRTUAL_DEVICE_*` status lines | early boot | serial console `hvc0` → `vm/console.log` ([android-image.md](android-image.md) §7.1) |
| logcat console | full logcat stream | `hvc2` → `guest/logcat-<timestamp>.log` when capture is on (§8.3) |

Guest agents follow the same rules as the host: clipboard content, notification text, typed or IME text, and account names are never logged, at any level. Key codes, pointer positions, and file names appear only at debug level, which release builds of the agents compile out ([guest-components.md](guest-components.md) §9).

### 3.5 Reading logs

- `apkrun logs` ([cli.md](cli.md) §4.8) runs `/usr/bin/log show` or `log stream` with `--predicate 'subsystem BEGINSWITH "io.apkrun"' --style ndjson`, cuts each message at U+001F, and prints time, level, subsystem/category, and message. If `log` fails (not an administrator, or no result within 30 s), it reads the mirrors instead and says so on stderr.
- `apkrun logs --guest` reads the logcat console through the `guestLog` stream (§7.6, [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §13.1). It needs developer mode.
- Developers: `log stream --level debug --predicate 'subsystem BEGINSWITH "io.apkrun"'`. Instruments shows the signposts of §4 in the Points of Interest and os_signpost instruments.

---

## 4. Performance markers (#061, #070, FR-OPS-05)

### 4.1 Model

```swift
public struct PerfMarker: RawRepresentable, Hashable, Sendable { public let rawValue: String }   // "FIRST_FRAME"
public enum PerfValue: Sendable, Equatable {
    case string(String), integer(Int64), double(Double), boolean(Bool)
}

public enum Perf {
    public static let timeline: PerfTimeline
    public static func mark(_ marker: PerfMarker,
                            at time: ContinuousClock.Instant = .now,
                            _ attributes: [String: PerfValue] = [:],
                            timeline: PerfTimeline = Perf.timeline)
    public static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T  // signpost only
}
```

- `Perf.mark` emits a signpost event (`OSSignposter`, category `pointsOfInterest`) and appends the marker, timestamp, attributes, and operation context to the selected process `PerfTimeline` (a ring of the last 2,000 markers). The timeline argument lets a module use the timeline from `DiagnosticsContext`.
- A marker uses the subsystem of its catalogue emitter in §4.2. This keeps attribution stable when one process records a marker on behalf of another process. An unrecognized raw marker uses `io.apkrun.diagnostics`; high-frequency interval names use `io.apkrun.graphics` for `gpu.*`, `io.apkrun.input` for `input.*`, and `io.apkrun.diagnostics` otherwise.
- `OSSignposter` event names are static strings. Lifecycle events therefore use the fixed event name `APKRunPerfMarker`; the marker name and its fields are included in the event message. A marker outside the catalogue is stored as `UNKNOWN`.
- Public marker fields are allowlisted. `Perf.mark` accepts at most 16 attributes per event and only the attribute keys listed in §4.2. If the caller supplies more than 16 attributes, all attributes are dropped. Attribute names are at most 64 ASCII bytes and string values at most 256 UTF-8 bytes; longer values and unknown keys are dropped before storage. The in-memory timeline retains bounded string values for later processing, but the public signpost emits strings only for finite catalogue values: `bootKind` (`cold`, `firstBoot`, `migration`) and `agent` (`guest`, `store`). Other string values are omitted from the signpost. Any later writer that persists timeline data must apply the public-data rules of §3.2.
- The signpost timestamp is when `OSSignposter` receives the event. Because it cannot be backdated, the payload includes `sourceTimeOffsetMsAtSample`, the signed millisecond distance from the supplied `at:` instant to a `ContinuousClock` sample taken after the base fields are prepared and immediately before final message encoding and `emitEvent`. The signpost timestamp follows that sample by the small cost of encoding and emission. The timeline retains the supplied instant as the marker's source time; consumers can use the offset as an approximation when correlating an event received from another process.
- `Perf.interval` creates only a signpost interval. It is for high-frequency work (`gpu.flush`, `gpu.present`, `input.translate`, `input.route`), which is not recorded in the timeline.
- **Clock.** All host markers use `ContinuousClock` (`mach_continuous_time`), which is the same clock in every process on the Mac, so marker times from the launcher and apkrund can be subtracted directly. Guest times are never mixed with host times. Only durations measured on one side are combined ([input.md](input.md) §8).
- Cost: markers are lifecycle events (a few per launch). A mark performs one signpost emission and one in-memory ring append; it does no filesystem I/O and never writes through `LogSink` or `LogMirrorWriter`.

### 4.2 Catalogue

The marker catalogue requires `VM_START`, `APP_LAUNCH_REQUEST`, `ACTIVITY_STARTED`, `FIRST_FRAME`, `UPDATE_CHECK_START`, `UPDATE_DOWNLOAD_END`, and `UPDATE_INSTALL_END`. `BOOT_COMPLETED` is the marker for Android's `sys.boot_completed=1` event and the emitted marker for the `.bootCompleted` phase below.

| Marker | Emitted by | When | Attributes |
|---|---|---|---|
| `DAEMON_READY` | RuntimeHost | apkrund's broker listener is resumed after startup recovery ([runtime-daemon.md](runtime-daemon.md) §2.2) | `startupMs`, `recoverySteps` |
| `VM_START` | VirtualMachineCore | `VZVirtualMachine.start` is called | `bootKind` (`cold`, `firstBoot`, `migration`) |
| `KERNEL_START` | RuntimeCore `BootPhaseDetector` | first kernel console line | |
| `ANDROID_INIT` | `BootPhaseDetector` | first-stage init starts | |
| `SYSTEM_SERVER_READY` | `BootPhaseDetector` | system server is up | |
| `BOOT_COMPLETED` | `BootPhaseDetector` | `sys.boot_completed=1` | |
| `AGENT_CONNECTED` | RuntimeCore | an agent handshake is accepted | `agent` (`guest`, `store`) |
| `RUNTIME_READY` | RuntimeCore | `RuntimeState` becomes `ready` | `bootMs` |
| `VM_PAUSED`, `VM_RESUMED` | RuntimeCore | idle suspend and resume ([runtime-daemon.md](runtime-daemon.md) §5) | `pausedMs` on resume |
| `WRAPPER_PROCESS_START` | launcher, recorded by apkrund | kernel start time of the launcher process (`proc_pidinfo(PROC_PIDTBSDINFO)`), so dyld and AppKit start-up are included | |
| `APP_LAUNCH_REQUEST` | launcher, recorded by apkrund | `openSession` is sent ([wrapper.md](wrapper.md) §5.2) | `xpcDelayMs` (send to receipt) |
| `DISPLAY_ATTACHED` | RuntimeCore `DisplayPool` | the lease is ready ([display-and-windowing.md](display-and-windowing.md) §3) | `slot`, `displayID`, `reused` |
| `ACTIVITY_STARTED` | RuntimeCore | the agent reports the launched activity resumed | `processStarted` (the app process was started for this launch) |
| `FIRST_FRAME` | RuntimeCore | the first `frameReady` on the session's scanout ([graphics.md](graphics.md) §7) | |
| `FIRST_FRAME_DISPLAYED` | RuntimeCore | the first `frameDisplayed` from the wrapper: the frame is in the window's layer. The glass is at most one display refresh later | |
| `WRAPPER_GENERATE_START`, `WRAPPER_GENERATE_END`, `WRAPPER_REFRESH_END`, `WRAPPER_APPROVAL_END` | WrapperCore | [wrapper.md](wrapper.md) §14 | `result`, `durationMs`, `kind` |
| `PACKAGE_IMPORT_START`, `PACKAGE_INSPECTED`, `PACKAGE_INSTALL_START`, `PACKAGE_INSTALL_COMPLETE`, `PACKAGE_ROLLBACK_COMPLETE` | APKStoreCore | [package-store.md](package-store.md) §13 | `bytes`, `splits`, `status` |
| `UPDATE_CHECK_START`, `UPDATE_CHECK_END`, `UPDATE_DOWNLOAD_START`, `UPDATE_DOWNLOAD_END`, `UPDATE_INSTALL_START`, `UPDATE_INSTALL_END`, `UPDATE_HEALTH_END`, `UPDATE_ROLLBACK_END` | UpdateCore | [update-system.md](update-system.md) §14 | `provider`, `result`, `bytes` |
| `CLIPBOARD_PUSH`, `NOTIFICATION_DELIVERED`, `FILE_TRANSFER` | IntegrationCore | [desktop-integration.md](desktop-integration.md) §13 | `durationMs`, `bytes` |
| `SELF_UPDATE_CHECK_END`, `HOST_UPDATE_PREPARE_START`, `HOST_UPDATE_PREPARED`, `HOST_UPDATED` | RuntimeHost `MaintenanceService`, `SelfUpdateProbe` | [runtime-maintenance.md](runtime-maintenance.md) §12 | `result`, `fromBuild`, `toBuild`, `durationMs` |
| `IMAGE_CHECK_END`, `IMAGE_DOWNLOAD_START`, `IMAGE_DOWNLOAD_END`, `IMAGE_INSTALL_END`, `IMAGE_MIGRATION_START`, `IMAGE_MIGRATION_END`, `IMAGE_ROLLBACK_END` | RuntimeHost `ImageUpdateCoordinator` | [runtime-maintenance.md](runtime-maintenance.md) §12 | `imageVersion`, `result`, `bytes`, `durationMs` |

The launcher passes its two times in `OpenSessionRequest.launchTiming { processStart, requestSent }` (continuous-clock nanoseconds, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3). apkrund records them as `WRAPPER_PROCESS_START` and `APP_LAUNCH_REQUEST` in the session's timeline, so one process holds the whole launch.

Signpost intervals (not in the timeline): `gpu.flush`, `gpu.present` ([graphics.md](graphics.md) §7), `input.translate`, `input.route` ([input.md](input.md) §8).

### 4.3 Perf records

apkrund writes one record per launch and per boot with `PerfRecordWriter`. These files contain no personal data beyond package IDs, and they give real-world numbers without any telemetry: nothing leaves the Mac unless the user attaches a diagnostics report.

`perf/launches.jsonl`, one line per session launch, written at `FIRST_FRAME_DISPLAYED` or when the session ends before it:

```json
{"v":1,"recordedAt":"2026-09-28T10:15:02Z","packageID":"io.apkrun.fixture.hellotext","versionCode":3,
 "sessionID":"s-12","operationID":"3f9a1c2e-…","launchState":"warm","windowMode":"secondaryDisplay",
 "build":"1.0 (1000)","image":"2026.10.0-cf16373615-arm64","gpuProfile":"drmVirgl",
 "markers":{"WRAPPER_PROCESS_START":0,"APP_LAUNCH_REQUEST":138.2,"DISPLAY_ATTACHED":412.9,
            "ACTIVITY_STARTED":1104.5,"FIRST_FRAME":1188.0,"FIRST_FRAME_DISPLAYED":1196.3},
 "totalMs":1196.3,"outcome":"shown"}
```

| `launchState` | Meaning | Target |
|---|---|---|
| `hot` | the app process was already running (a window reopened) | — |
| `warm` | Android `ready`, app process not running | NFR-PERF-01: p50 ≤ 1.5 s, p95 ≤ 3 s |
| `suspended` | Android was `suspended` and resumed for this launch | NFR-PERF-01 + 0.5 s ([runtime-daemon.md](runtime-daemon.md) §5) |
| `cold` | Android was stopped and booted for this launch | NFR-PERF-02: p50 ≤ 40 s |
| `firstBoot` | the provisioning boot | excluded from statistics |

- Times are milliseconds relative to `WRAPPER_PROCESS_START`. `outcome` is `shown`, `ended(<reason>)`, or `failed(<code>)`.
- `perf/boots.jsonl`, one line per boot, with the same `v` schema version ([runtime-maintenance.md](runtime-maintenance.md) §5): `VM_START` as 0, then `KERNEL_START`, `ANDROID_INIT`, `SYSTEM_SERVER_READY`, `BOOT_COMPLETED`, `AGENT_CONNECTED` (both agents), `RUNTIME_READY`, plus `bootKind`, `gpuProfile`, `memoryGiB`, `cpuCount`, and the outcome.
- Retention: at apkrund start, a file with more than the limit (§3.3) is rewritten atomically with the newest records.

---

## 5. Metrics

`MetricsSnapshot` is collected on demand: for `apkrun doctor --deep`, for diagnostics bundles, and by the performance harness through `perfStatistics` (§9.3). There is no background polling. The one periodic sampler (`apkrundCPU`, once per second) runs only while a scanout is presenting or a statistics subscriber exists, so an idle apkrund does no periodic work (NFR-PERF-06).

| Metric | Source | Notes |
|---|---|---|
| VM memory | configured size (`VMDefinition`), balloon target, guest `MemTotal` and `MemAvailable` from the agent's `Health.memory` ([guest-protocol.md](guest-protocol.md) §7.4), host footprint of the Virtualization XPC service process (`proc_pid_rusage`, `ri_phys_footprint`) | finding the VZ service process reliably is verified in #070 (§13) |
| `system_server`, `SurfaceFlinger`, `zygote`/`zygote64`, each app process | `CollectDiagnostics` item `DUMPSYS_MEMINFO` (`dumpsys meminfo -c`): PSS and RSS per process | on demand only; one call costs about 1 s of guest CPU |
| Host graphics memory | GraphicsCore `resourceMemory` and high-water mark, SurfacePool IOSurface bytes (`IOSurfaceGetAllocSize`), `MTLDevice.currentAllocatedSize` | [graphics.md](graphics.md) §5.4, §6.3 |
| apkrund memory | `task_vm_info.phys_footprint` and `resident_size` | |
| apkrund CPU | `task_info` thread times, sampled as above | NFR-PERF-06 |

Graphics metrics are defined in [graphics.md](graphics.md) §7 (`fps`, `guestFlushRate`, `flushToReady`, `readyToDisplayed`, `presentGPUTime`, `droppedFrames`, `hostReadbacks`, `guestReadbacks`, `cpuPixelCopies`, `resourceMemory`, `gpuUtilization`). Input counters are in [input.md](input.md) §11. Store and update metrics are in [package-store.md](package-store.md) §13 and [update-system.md](update-system.md) §14. The snapshot includes all of them, grouped by subsystem.

---

## 6. Redaction (NFR-SEC-05, #060)

A diagnostics report must be safe to post in a public GitHub issue. Redaction is layered. Each layer assumes the layers before it can fail.

### 6.1 Layer 1: never collected

The bundle has no code path that reads these, so they cannot leak:

| Never collected | Why it matters |
|---|---|
| Clipboard contents (host and guest) | #060 |
| Notification titles and text | private messages |
| Files the user shared, dropped, imported, or saved; the contents of shared folders | #060 "user files" |
| Android app data: `/data/data`, `/data/user*`, `/sdcard`, app databases, app caches, `userdata.img` | #060 "app private data" |
| Android accounts (`dumpsys account`), Wi-Fi configuration, keystore, lock settings | credentials |
| Keychain items (update provider tokens), `~/.ssh`, browser data | #060 "tokens, passwords" |
| Google credentials | APKRun ships no Google services. Any `google` account data on a user-modified image is covered by the account rule above |
| IME text and key events | typed passwords |
| Mac hardware serial number, hardware UUID, provisioning UDID | device identifiers |
| Screenshots of app windows | may show anything |

### 6.2 Layer 2: allowlists for structured data

Structured sources are copied field by field from an allowlist, not filtered by a blocklist:

- **getprop:** the agent returns only allowlisted properties, and the host filters again with the same list. Allowed: `ro.build.fingerprint`, `ro.build.id`, `ro.build.type`, `ro.build.version.*`, `ro.product.cpu.abilist*`, `ro.product.model`, `ro.product.device`, `ro.hardware*`, `ro.boot.hardware.*` (egl, gralloc, vulkan), `ro.opengles.version`, `ro.kernel.version`, `ro.apkrun.*` (image identity), `sys.boot_completed`, `init.svc.*` (service states), `dalvik.vm.heap*`, `persist.sys.locale`, `debug.hwui.renderer`. Everything else, including `ro.serialno` and `ro.boot.serialno`, is left out.
- **Configuration:** global settings ([../03-reference/configuration.md](../03-reference/configuration.md)) and per-package settings are copied by key. `sharedFolders.roots` becomes a count plus last path components.
- **Package records:** package ID, label, version name and code, state, installer and update owner, provider type and host, signer digest truncated to 12 hex, sizes. Provider configuration values other than type and host are left out.
- **Unified log entries:** every message is cut at U+001F (§3.2), so only the public text remains even when a private-data logging profile is installed.
- **Wrapper registry:** paths are reduced to their last component, and bookmarks are removed ([wrapper.md](wrapper.md) §14).
- **Bootconfig and instance data:** `androidboot.serialno`, the instance UUID, the VM machine identifier, and the MAC address are replaced by stable placeholders (`<serial-1>`, `<uuid-1>`), so the same value is recognizable across files of one report ([android-image.md](android-image.md) §14).

### 6.3 Layer 3: structural reduction of free text

Applied by `Redactor` to every text file in the bundle (logs, console output, logcat, dumpsys):

| Rule | Replacement |
|---|---|
| The user's home directory | `~` |
| The account name (`NSUserName()`), full name (`NSFullUserName()`), computer name and local host name (`SCDynamicStoreCopyComputerName`, `SCDynamicStoreCopyLocalHostName`) | `<user>`, `<user-name>`, `<computer>` |
| Paths inside the home directory other than `~/Library/Application Support/APKRun`, `~/Library/Logs/APKRun`, and `/Applications/APKRun.app` | `~/…/<last component>` |
| URLs | `scheme://host/…`: path, query, fragment, and user info are removed. Hosts of APKRun's own endpoints are kept with their path (they carry no user data) |
| E-mail addresses | `<email>` |
| IPv4 and IPv6 addresses except loopback, link-local, and the VM's NAT subnet | `<ip>` |
| MAC addresses | `<mac>` |
| Android `content://` URIs and intent data in dumpsys output | `content://<authority>/…` |

### 6.4 Layer 4: secret patterns and known secrets

The last line of defense, also applied to every text file:

| Pattern | Examples |
|---|---|
| `key: value` and `key=value` where the key matches `(?i)(authorization|bearer|token|access_token|refresh_token|id_token|api[_-]?key|secret|client_secret|password|passwd|pwd|cookie|set-cookie|session)` | HTTP headers, query strings that survived, config dumps |
| JSON Web Tokens: `eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}` | |
| Provider tokens: `gh[pousr]_[A-Za-z0-9]{36,}`, `github_pat_[A-Za-z0-9_]{50,}`, `ya29\.[0-9A-Za-z_-]+`, `AIza[0-9A-Za-z_-]{35}`, `AKIA[0-9A-Z]{16}`, `xox[abprs]-[0-9A-Za-z-]{10,}` | GitHub, Google, AWS, Slack |
| PEM private keys: `-----BEGIN [A-Z ]*PRIVATE KEY-----` … `-----END [A-Z ]*PRIVATE KEY-----` | |
| Base64 runs of 64 characters or more that are not part of a known structured field | opaque blobs |
| **Known secrets:** the exact values of the secrets APKRun stores (update provider tokens from the Keychain, read by `DiagnosticsService` only for this purpose and never written anywhere), in raw, URL-encoded, base64, and UTF-16 forms | the strongest check for our own secrets |

Matches become `<redacted:rule>`. The manifest records counts per rule (§8.2), never the matched values.

### 6.5 Verification and failure

- After redaction, the writer re-scans each file with the layer 4 rules. A hit of a **known secret** means a redaction bug: the file is dropped, `omitted` records `redactionFailed`, and the bundle is still produced. Pattern hits after redaction are impossible by construction and are treated the same way.
- `RedactionRules.version` is recorded in the manifest. Changing a rule increases it.
- The redactor never runs on the local log files. `ConsoleLogWriter` and the mirrors keep full local data ([vm.md](vm.md) §6.4); redaction happens only when a report is built.

---

## 7. Health model and `apkrun doctor` (#059, FR-OPS-01, NFR-OBS-02, NFR-OBS-03)

### 7.1 Types

```swift
public enum HealthState: String, Sendable, Codable { case pass, info, warning, failure, skipped }

public enum HealthGroup: String, Sendable, Codable, CaseIterable {
    case host, backgroundService, virtualization, android, graphics, guest,
         store, updates, applications, macApps, integrations, maintenance
}

public enum HealthRequirement: Sendable { case host, daemon, runningRuntime }   // what the check needs
public enum HealthCost: Sendable { case quick, deep }                            // deep: --deep only

public protocol HealthCheck: Sendable {
    var id: HealthCheckID { get }                   // "runtime.boot"
    var group: HealthGroup { get }
    var requirement: HealthRequirement { get }
    var cost: HealthCost { get }
    var fix: HealthFix? { get }                     // a safe automatic fix, if any (§7.5)
    func run(_ context: HealthContext) async -> HealthResult
}

public struct HealthResult: Sendable, Codable {
    public var id: HealthCheckID
    public var group: HealthGroup
    public var state: HealthState
    public var title: LocalizedText                 // "Boot completed"
    public var detail: String?                      // public-safe: "31 s", "stopped at systemServer after 180 s"
    public var error: ErrorInfo?                    // code, message, remediation, action (§2)
    public var fixAvailable: Bool
    public var lastKnown: LastKnown?                // for skipped checks: the last result and its time
    public var measuredAt: Date
}

public struct HealthReport: Sendable, Codable {
    public var generatedAt: Date
    public var build: BuildInfo
    public var imageVersion: String?
    public var runtimeRunning: Bool
    public var verdict: HealthVerdict               // §7.2
    public var results: [HealthResult]              // ordered by group, then registration order
}
```

- Each process has a `HealthCheckRegistry`. apkrund's registry is filled at startup by RuntimeHost with the checks of every module. The CLI and APKRun.app have a registry with only the host checks (§7.3).
- `HealthResult.error` is empty for `pass`, `info`, and `skipped` results. A `warning` or `failure` carries it whenever there is a next step: the GUI shows its remediation and action on the row, and `apkrun doctor` prints its hint. The entry of each check is listed in [../03-reference/error-catalog.md](../03-reference/error-catalog.md) §20.2.
- A quick check must finish in 2 s. A deep check has 60 s. A check that times out returns `warning` with `detail = "check timed out"` and no `error`. Checks run concurrently, at most 8 at a time. Checks that need the guest share one agent round trip where possible (`Health`, [guest-protocol.md](guest-protocol.md) §7.4).
- Checks with `requirement == .runningRuntime` never start Android. While Android is stopped they return `skipped` with "Android is not running" and `lastKnown` (for example "last boot completed in 31 s, today 10:02"). Opening Troubleshooting or running `apkrun doctor` does not start Android ([host-ui.md](host-ui.md) §1).
- **Live checks.** A subset re-evaluates when its source state changes (no polling) and publishes `healthChanged(HealthResult)` on the `health` topic of `subscribe` ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.4): `runtime.state`, `runtime.boot`, `agent.*`, `vm.network`, `graphics.renderer`, `graphics.memory`, `runtime.memoryPressure`, `store.packages`, `store.hostSpace`, `wrappers.status`. The main window header and the menu bar show "Needs attention" while any live check is `warning` or `failure` ([host-ui.md](host-ui.md) §5, §12).

### 7.2 Verdict (FR-OPS-01)

The report's verdict is the first row that applies:

| Verdict | Condition | Status line |
|---|---|---|
| `hostUnsupported` | a `host.*` check or `vm.virtualizationSupported` fails | "APKRun can't run on this Mac" |
| `serviceUnavailable` | `apkrund.registration` or `apkrund.reachable` fails | "Background service not running" |
| `notSetUp` | `runtime.provisioning` is not complete, or `image.current` fails | "Setup not finished" |
| `graphicsFailure` | `graphics.renderer` fails (renderer initialization failed or the renderer was lost in the current or last boot), or the last boot failed with a `GraphicsFailure` | "Graphics failed to start" |
| `bootFailure` | `runtime.state` is `failed`, or `runtime.boot` fails (the last boot failed and no boot has succeeded since), or the boot-loop guard is set | "Android failed to start" plus the boot phase reached |
| `agentUnavailable` | Android is `ready` and `agent.guest` or `agent.store` fails | "Guest Agent unavailable" / "Store Agent unavailable" |
| `degraded` | any other failure, or any warning | "Needs attention (‹n› warnings)" |
| `stopped` | no failures or warnings, Android is stopped | "Healthy · Android is not running" |
| `healthy` | no failures or warnings, Android is `ready` or `suspended` | "Healthy" |

- `graphicsFailure` comes before `bootFailure`, because a renderer failure also fails the boot, and the graphics verdict carries the better remediation ("Start in Graphics Safe Mode", [graphics.md](graphics.md) §9).
- When the verdict is `degraded` and Android is stopped, the status line adds "· Android is not running", so the stopped state stays visible.
- CLI exit codes ([cli.md](cli.md) §3.3): `healthy` and `stopped` → 0; `degraded` without failures → 3; everything else → 1.

### 7.3 Host checks (DiagnosticsCore `HostChecks`)

These need neither apkrund nor RuntimeHost. The CLI and APKRun.app run them directly when apkrund is unreachable ([cli.md](cli.md) §4.8), and RuntimeHost's `HostRequirementsCheck` builds on them for provisioning ([runtime-daemon.md](runtime-daemon.md) §9.1).

| Check | Group | Pass condition | Remediation on failure |
|---|---|---|---|
| `host.appleSilicon` | host | `sysctl hw.optional.arm64 == 1` and `sysctl.proc_translated == 0` | "APKRun needs a Mac with Apple silicon" |
| `host.macOSVersion` | host | macOS 27 or later | "Update macOS" |
| `host.hypervisor` | virtualization | `sysctl kern.hv_support == 1`. apkrund additionally checks `VZVirtualMachine.isSupported` as `vm.virtualizationSupported` | "Virtualization is not available on this Mac (APKRun can't run inside a virtual machine)" |
| `host.appLocation` | host | APKRun.app is in `/Applications` or `~/Applications` and not translocated | "Move APKRun to the Applications folder" |
| `host.appSignature` (deep) | host | `SecStaticCodeCheckValidity` of APKRun.app with its designated requirement, including nested code | "Reinstall APKRun" |
| `host.componentVersions` | host | apkrund, the CLI, and the generic launcher in the bundle all have the same build as APKRun.app | "Reinstall APKRun" |
| `host.dataVolume` | host | the data root is on APFS and has at least 10 GiB free (warning below) | "Free up space" / "Move APKRun's data to an APFS volume" |
| `host.memory` | host | physical memory ≥ 8 GiB (warning only) | "APKRun works best with 16 GB or more" |
| `apkrund.registration` | backgroundService | APKRun.app: `SMAppService.status == .enabled`. CLI: `launchctl print gui/<uid>/io.apkrun.apkrund` succeeds | `requiresApproval` → "Allow APKRun in System Settings → General → Login Items & Extensions" (`openLoginItemsSettings`); not registered → "Open APKRun to finish setup" |
| `apkrund.reachable` | backgroundService | broker `hello` answers within 5 s with the same API major version | "Restart the background service" (Troubleshooting) |
| `apkrund.version` | backgroundService | apkrund's build equals the client's build | while apkrund is in `restartPending` ([runtime-maintenance.md](runtime-maintenance.md) §3.6): "An APKRun update is waiting for your Android apps to close. Close them, or choose Restart Now." Otherwise "Quit and reopen APKRun" |
| `apkrund.crashLoop` | backgroundService | fewer than 3 unclean exits in 10 minutes ([runtime-daemon.md](runtime-daemon.md) §2.5). Without apkrund: counted from `~/Library/Logs/DiagnosticReports/apkrund-*.ips` | "Create a diagnostics report and report the problem" |

The `HealthResult.error` of these checks is `runtime.hostRequirementsNotMet` with one item (`host.appleSilicon`, `host.macOSVersion`, `host.hypervisor`, and `host.dataVolume` on a volume that is not APFS), `runtime.serviceUnavailable` (`apkrund.registration`, `apkrund.reachable`), or a finding of `DiagnosticsFailure` (§2.1) for the other checks.

When apkrund is unreachable, the report lists every other check as `skipped` with "Background service not running" and the remediation of `apkrund.registration` or `apkrund.reachable`.

### 7.4 Check catalogue

Checks are implemented by their owner module, as part of the task that builds the checked feature. #061 adds the health model, the verdict function (§7.2), and `HostChecks` with the `host.*` checks and `apkrund.registration`. #059 adds the report plumbing, the output, the host-only mode, and the other `apkrund.*` checks. The owning documents define the exact conditions.

| Group (doctor heading) | Checks | Defined in |
|---|---|---|
| Host | `host.appleSilicon`, `host.macOSVersion`, `host.appLocation`, `host.appSignature`, `host.componentVersions`, `host.dataVolume`, `host.memory` | §7.3 |
| Background Service | `apkrund.registration`, `apkrund.reachable`, `apkrund.version`, `apkrund.crashLoop` | §7.3, [runtime-daemon.md](runtime-daemon.md) §12 |
| Virtualization | `host.hypervisor`, `vm.virtualizationSupported`, `vm.state`, `vm.network`, `vm.consoleWriter` | [vm.md](vm.md) |
| Android | `runtime.provisioning`, `image.current`, `image.instance`, `image.kind`, `image.migration`, `image.recoveryPoint`, `image.freeSpace`, `runtime.state`, `runtime.boot`, `runtime.stop`, `runtime.memoryPressure` | [runtime-daemon.md](runtime-daemon.md) §12, [android-image.md](android-image.md) §14.3 |
| Graphics | `graphics.device`, `graphics.renderer`, `graphics.guestDriver` (deep), `graphics.present`, `graphics.memory`, `graphics.safeMode` | below, [graphics.md](graphics.md) |
| Guest | `agent.guest`, `agent.store`, `agent.input`, `agent.ime`, `agent.developerMode` | below, [runtime-daemon.md](runtime-daemon.md) §12, [input.md](input.md) §11 |
| Store | `store.journal`, `store.pending`, `store.ownership`, `store.externallyUpdated`, `store.hostSpace` | [package-store.md](package-store.md) §13 |
| Updates | `updates.scheduler`, `updates.providers`, `updates.waiting`, `updates.failed` | [update-system.md](update-system.md) §14 |
| Applications | `store.packages` (rendered as "‹n› installed", plus the packages that need attention) | [package-store.md](package-store.md) §13 |
| Mac Apps | `wrappers.template`, `wrappers.registry`, `wrappers.status`, `wrappers.launcher`, `wrappers.registration` | [wrapper.md](wrapper.md) §14 |
| Integrations | `integrations.capabilities`, `integrations.notificationListener`, `integrations.browserRole`, `integrations.sharedFolders`, `integrations.microphone`, `integrations.time` | [desktop-integration.md](desktop-integration.md) §13 |
| APKRun Updates | `maintenance.selfUpdate`, `maintenance.imageUpdate` | [runtime-maintenance.md](runtime-maintenance.md) |

Checks defined here, because no other document owns them:

| Check | Requirement | Pass | Warning | Failure |
|---|---|---|---|---|
| `graphics.device` | runningRuntime | virtio-gpu attached with the expected features and scanout count for the GPU profile ([graphics.md](graphics.md) §4.1, §9) | — | device missing or feature negotiation failed: `graphics.deviceSetupFailed` |
| `graphics.renderer` | daemon (last known) / runningRuntime | virglrenderer and ANGLE (Metal backend) initialized; detail shows their versions and the Metal device name | one `rendererLost` recovered by a restart in the last 24 h | `rendererInitFailed`, or `rendererLost` twice in 24 h. Remediation: `startGraphicsSafeMode` |
| `graphics.guestDriver` (deep) | runningRuntime | `DUMPSYS_SURFACEFLINGER` reports a GLES renderer string that contains `virgl` (profile `drmVirgl`) | — | another renderer while the profile is `drmVirgl` (Android fell back to software rendering): `graphics.softwareRendering` |
| `graphics.present` | runningRuntime | `hostReadbacks == 0` and, on `drmVirgl`, `cpuPixelCopies == 0` since boot (NFR-PERF-05) | either counter non-zero (a regression: report it): `graphics.presentationSlowPath` | — |
| `graphics.memory` | runningRuntime | below the limits of [graphics.md](graphics.md) §5.4 | a limit was reached: `graphics.memoryLimitReached` | — |
| `graphics.safeMode` | daemon | `graphics.safeMode` off | on: `graphics.safeModeOn` ("Graphics safe mode is on. Apps are slower.") | — |
| `agent.input` | runningRuntime | the agent's input stream is connected | `disconnected` ([input.md](input.md) §11) or `input.dropped.invalid` above 0.1 % of events since boot: `runtime.inputDegraded` | — |
| `agent.ime` | runningRuntime | the APKRun input method is selected (`Health.ime_selected`) | not selected (fixable, §7.5): `runtime.inputMethodNotSelected` | — |
| `agent.developerMode` | runningRuntime | `Health.adb_enabled` matches `developer.enabled` | ADB is on: `info` "Developer mode: ADB on 127.0.0.1:6520" | ADB is on while developer mode is off (security, [../01-architecture/security-model.md](../01-architecture/security-model.md)): `runtime.adbEnabledUnexpectedly` |

### 7.5 Fixes (`--fix`)

A fix is offered only when it is safe: idempotent, no data loss, no change to a user choice, and no restart of Android that would close windows.

| Check | Fix |
|---|---|
| `wrappers.registration` | re-register the wrapper with LaunchServices (`LSRegisterURL`) |
| `agent.ime` | ask the Guest Agent to select the APKRun input method again |
| `integrations.notificationListener`, `integrations.browserRole` | ask the Guest Agent to restore the grant or role (custom image, privileged agent; [desktop-integration.md](desktop-integration.md)) |
| `apkrund.registration` | CLI: `open -a APKRun --args --register-runtime` after a confirmation ([cli.md](cli.md) §4.1). APKRun.app: `SMAppService.register()` |
| `apkrund.version` | restart apkrund (`launchctl kickstart -k gui/<uid>/io.apkrun.apkrund`), only while Android is stopped. Otherwise the fix is not offered and the remediation says to stop Android first |

`apkrun doctor --fix` runs the fixes of every check in `warning` or `failure` that has one, prints "Fixed: ‹title›" or the error, then runs the whole report again. APKRun.app shows a **Fix** button on those rows.

### 7.6 Control endpoint operations

| Operation | Result | Notes |
|---|---|---|
| `healthReport(HealthRequest{ deep, checks? })` | `WireHealthReport` | `checks` limits the run to some IDs (the GUI uses it for **Run Again** on one row) |
| `applyHealthFixes(HealthFixRequest{ checks })` | `WireHealthReport` | runs the fixes, then a full report |
| `createDiagnostics(DiagnosticsRequest)` | `OperationHandle` → `DiagnosticsResult` | §8.1 |
| `perfStatistics(PerfStatisticsRequest{ reset })` | `WirePerfStatistics` | §9.3 |
| `guestLog(GuestLogRequest{ follow })` | stream of `GuestLogChunk` | `apkrun logs --guest` (§3.5). Developer mode only, otherwise `runtime.developerModeRequired`. Never starts Android. Built in #032 |

All are on the control endpoint only, not on wrapper endpoints ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2). A wrapper's **Report a Problem…** opens APKRun.app instead (§8.5).

### 7.7 Output

Human output has headings per group, one line per check, and the status at the end. Rows that pass show their title (and detail). Other rows add the remediation on an indented line. `--deep` adds a **Metrics** block (§5).

```text
APKRun Doctor                          APKRun 1.0 (1000) · Android image 2026.10.0-cf16373615-arm64

Host
✓ Apple silicon (Mac15,6)
✓ macOS 27.0 (27A5301)
✓ APKRun is in Applications

Background Service
✓ Running (apkrund 1.0)

Virtualization
✓ Available

Android
✓ Runtime image 2026.10.0 (custom)
✓ Boot completed (31 s)

Graphics
✓ virtio-gpu (3 displays in use)
✓ VirGL
✓ virglrenderer 1.1.1 · ANGLE / Metal (Apple M3 Pro)

Guest
✓ Guest Agent connected (1.0.3)
✓ Store Agent connected (1.0.3)

Store
✓ Package store consistent
✓ Update checks on schedule

Applications
✓ 4 installed

Mac Apps
⚠ “Hello GL” was moved to the Trash
  → Create the Mac app again: APKRun → Hello GL → Mac App

Status
Needs attention (1 warning)
```

- Symbols: ✓ pass, ℹ info, ⚠ warning, ✕ failure, – skipped (with the reason). Color only on a TTY without `NO_COLOR` ([cli.md](cli.md) §3.2).
- Groups whose checks all pass collapse to one line in APKRun.app's Troubleshooting list; the CLI prints every line.
- `--json`: `{ "schemaVersion": 1, "result": <WireHealthReport> }`, with stable check IDs, states, and error codes. Titles and details are in the user's language; scripts should use the IDs.

---

## 8. Diagnostics bundle (#060, FR-OPS-02)

### 8.1 Flow

1. The client asks for a destination: the CLI uses `--output` or `~/Desktop/APKRun-Diagnostics-<yyyyMMdd-HHmmss>.zip` ([cli.md](cli.md) §4.8). APKRun.app shows a Save panel with that name (§8.5).
2. The client opens the file for writing and passes the `FileHandle` in `DiagnosticsRequest{ output, includeLogcat, deep, focusPackage? }`. apkrund never opens a user-chosen path itself, so it needs no TCC access to Desktop or Documents.
3. `DiagnosticsService` creates a staging directory in apkrund's `$TMPDIR` (mode 0700), runs the contributors (§8.2) concurrently with a time budget each, then runs `Redactor` over the staged files (§6), writes `summary.txt` and `manifest.json`, streams the ZIP into the handle with `ZipWriter` (deflate through Compression.framework), and deletes the staging directory. The ZIP file is created with mode 0600.
4. Progress is reported through the `OperationHandle` (stages: collecting, redacting, writing). On cancel, apkrund truncates the output to 0 bytes. It has only the handle, not the path, so the client deletes the file ([../03-reference/runtime-api.md](../03-reference/runtime-api.md) §4.7).
5. The result has the summary text, the size, and the omitted items. The CLI prints the path and the summary. APKRun.app shows **Show in Finder**.

- **Always a result (FR-OPS-02).** A contributor that fails or exceeds its budget is recorded in `omitted` with the reason. The bundle is produced whenever the writer itself works: in `failed` state, after a boot failure, with the Guest Agent down, with no image installed.
- Budgets: 10 s per host contributor, the `CollectDiagnostics` timeout of 60 s for the guest items together ([guest-protocol.md](guest-protocol.md) §6), 45 s for `log show`. p95 for a whole bundle on a healthy runtime: ≤ 60 s. Size target: ≤ 100 MiB compressed (caps below).
- Nothing is uploaded. There is no upload code in APKRun. The user attaches the file to a bug report themselves ([../05-development/workflow.md](../05-development/workflow.md), issue template).

### 8.2 Contents

```text
APKRun-Diagnostics-20260928-101502/
├── summary.txt                     human-readable summary (§8.3)
├── manifest.json                   format, options, file list, omitted items, redaction counts
├── host/
│   ├── environment.json            Mac model identifier, chip, memory, macOS version and build, displays (count, scales),
│   │                               locale and region, free space and file system of the data volume
│   ├── versions.json               BuildInfo of APKRun.app, apkrund, CLI, launcher template; image version; agent versions
│   ├── health.json, health.txt     the HealthReport (deep when requested) and its doctor rendering
│   ├── config.json                 global settings (allowlisted keys, §6.2)
│   ├── metrics.json                MetricsSnapshot (§5)
│   ├── logs/unified.ndjson         APKRun subsystems, last 24 h, newest 30 MiB (or mirrors/ when log show failed)
│   ├── logs/mirrors/               apkrund.log*
│   ├── crash-reports/              .ips files of apkrund, APKRun, APKRunMenuBar, apkrun, APKRunLauncher; last 7 days, at most 20
│   └── perf/                       launches.jsonl and boots.jsonl (newest 500 / 50 records)
├── runtime/
│   ├── status.json                 RuntimeStatus, agent states, sessions, display pool snapshot (as `apkrun info --displays`)
│   ├── daemon.json                 apkrund run record: clean-exit flag, unclean exits, boot history
│   ├── boot-phases.json            BootPhaseDetector events of the last 5 boots
│   ├── console/                    boot-<ts>.log of the last 5 boots and the last 8 MiB of console.log
│   ├── crash/                      the last 3 failure snapshots (§3.3)
│   ├── graphics.json               GPU profile, Metal device name and family, virglrenderer and ANGLE versions, statistics (graphics.md §7)
│   ├── input.json                  input counters (input.md §11)
│   └── image/                      image store state, manifest summary, bootconfig and cmdline (placeholders, §6.2), migration state
├── guest/                          only when the Guest Agent answered, or from a logcat capture file
│   ├── getprop.txt                 allowlisted properties (§6.2)
│   ├── logcat.txt                  filtered (§8.3), or full with --include-logcat
│   ├── dumpsys-{window,display,input,activity,surfaceflinger,meminfo}.txt
│   ├── tombstones.txt              list only: time, process name, signal. Tombstone contents are never collected
│   └── agent.log, store.log
├── packages/
│   ├── packages.json               allowlisted package records (§6.2)
│   ├── settings.json               per-package settings (allowlisted keys)
│   ├── journal-tail.jsonl          the last 500 store journal entries (paths reduced)
│   └── updates.json                update phase, last result, and the last 10 history entries per package
├── wrappers/registry.json          paths reduced to the last component, bookmarks removed
├── integrations/status.json        capabilities, enabled integrations per package (booleans), shared folder count
└── maintenance/state.json          HostState, SelfUpdateStatus, the host-update marker, Images/update-state.json (runtime-maintenance.md §12)
```

- Every section comes from a `DiagnosticsContributor` owned by the module that knows the data:

  ```swift
  public protocol DiagnosticsContributor: Sendable {
      var name: String { get }                         // "store", "graphics"
      var budget: Duration { get }
      func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws
  }
  ```

  RuntimeCore contributes `runtime/` and `guest/`, GraphicsCore `runtime/graphics.json`, InputCore `runtime/input.json`, ImageCore `runtime/image/`, APKStoreCore `packages/`, UpdateCore `packages/updates.json`, WrapperCore `wrappers/`, IntegrationCore `integrations/`, RuntimeHost `maintenance/`, and RuntimeHost and DiagnosticsCore `host/`.
- `DiagnosticsBundleBuilder` accepts only files under the bundle's own tree and only text or JSON. Every file goes through the redactor. Binary files are not accepted, with one exception: `.ips` crash reports, which are JSON text and are redacted like other text.
- `focusPackage` (CLI `--package <id>`; GUI: the package selected from **Report a Problem…**) adds that package's full update history and its last 20 launch records, and orders its issues first in the summary. It does not add app data.
- `manifest.json`:

  ```json
  { "format": 1, "reportID": "7c1e0f7a-…", "createdAt": "2026-09-28T01:15:02Z",
    "createdBy": "apkrund", "mode": "full",
    "options": { "includeLogcat": false, "deep": false, "focusPackage": null },
    "build": "1.0 (1000)", "redactionRulesVersion": 1,
    "files": [ { "path": "host/environment.json", "bytes": 1432, "sha256": "…", "contributor": "host" } ],
    "omitted": [ { "item": "guest/logcat.txt", "reason": "guestAgentUnavailable" } ],
    "redaction": { "path": 118, "url": 40, "token": 2, "email": 1, "user": 9, "ip": 3 },
    "counters": { "diagnostics.mirrorDropped": 0 } }
  ```

  The report ID is random. It is not linked to the Mac or the user.

### 8.3 Guest data and boot failures

- **Android running and the Guest Agent connected:** `CollectDiagnostics` (operation 73, [guest-protocol.md](guest-protocol.md) §7.1) with items `GETPROP`, `LOGCAT`, `DUMPSYS_WINDOW`, `DUMPSYS_DISPLAY`, `DUMPSYS_INPUT`, `DUMPSYS_ACTIVITY`, `DUMPSYS_SURFACEFLINGER`, `DUMPSYS_MEMINFO`, `TOMBSTONE_LIST`, `AGENT_LOG`, and `max_bytes` 16 MiB per item. The payloads arrive over the bulk stream. The agent itself leaves out non-allowlisted properties. The host applies every rule of §6 regardless.
- **Logcat filter (default):** the agent runs `logcat -d -b main,system,crash -v threadtime,uid,UTC,year`. The host keeps entries from system UIDs (below 10000), entries with APKRun tags, and from app UIDs only the crash-buffer lines of a fatal exception (the `FATAL EXCEPTION` line, `Process:`, the exception line, and the stack frames). Other app log lines are dropped, because apps may log anything. `--include-logcat` (GUI: "Include Android app logs") keeps all entries, still redacted, and the sheet warns that they may contain information from the user's apps.
- **Android failed or stopped:** the bundle has the console logs of the last 5 boots, the boot phases, and the failure snapshots of [runtime-daemon.md](runtime-daemon.md) §3.6. Their `logcat -d` part goes through the same filter.
- **Logcat capture after a failed boot:** when `daemon.json` records that the last boot failed, RuntimeCore attaches the logcat console (`hvc2`) as `.log("logcat")` for the next boot and writes `guest/logcat-<timestamp>.log` ([android-image.md](android-image.md) §7.1). The bundle includes the newest capture file, filtered like other logcat data. Developer mode captures on every boot.
- APKRun never starts Android to build a report. The summary tells the user when guest data is missing and why ("Android was not running").

`summary.txt` (English, so that a report is readable by maintainers; the GUI shows the localized health report):

```text
APKRun Diagnostics Report
Created 2026-09-28 10:15:02 +0900 · Report 7c1e0f7a · operation 3f9a1c2e

Status: Android failed to start
  The last start stopped at "system services" after 180 s (runtime.bootTimedOut).
  Suggested: Start in Graphics Safe Mode (Settings → Troubleshooting).

APKRun 1.0 (1000) · apkrund 1.0 (1000) · CLI 1.0 (1000) · launcher 1.0
Android image 2026.10.0-cf16373615-arm64 (custom) · Guest Agent 1.0.3 · Store Agent 1.0.3
Mac15,6 · Apple M3 Pro · 36 GB · macOS 27.0 (27A5301) · 2 displays

Health: 1 failure, 2 warnings (see host/health.txt)
  ✕ runtime.boot           last boot failed: timeout at systemServer
  ⚠ graphics.renderer      renderer lost once in the last 24 h
  ⚠ wrappers.status        1 Mac app is missing

Recent problems (last 7 days, from logs)
  2026-09-28 10:02  runtime.bootTimedOut                 op 91ab22c0
  2026-09-27 18:40  update.healthCheckFailed  org.example.notes 2.1 → rolled back to 2.0

Apps: 4 installed, 1 needs attention · last launches: warm p50 1.2 s (12 launches)

Privacy
  Not collected: clipboard, notification text, your files, app data, accounts, passwords, Keychain items.
  Removed: 118 paths, 40 URLs, 2 tokens, 1 e-mail address, 9 user or computer names, 3 IP addresses.
  Omitted: guest logs (Android was not running).
```

"Recent problems" comes from `error`-level entries (their `err=` fields) in the collected logs. "Last launches" comes from `launches.jsonl`.

### 8.4 Host-only bundle

When apkrund is unreachable, the CLI ([cli.md](cli.md) §4.8) and APKRun.app build the bundle themselves with DiagnosticsCore:

- `mode: "hostOnly"`, `createdBy: "cli"` or `"app"`.
- Included: `host/` (environment, versions from the bundle's Info.plist files, the host checks of §7.3, the output of `launchctl print gui/<uid>/io.apkrun.apkrund`, `log show`, mirrors, crash reports, perf records, allowlisted `settings.json`), `runtime/daemon.json`, `runtime/console/`, `runtime/crash/`, and `packages/packages.json` from reading `Packages/*/metadata.json` with the same key allowlist (read-only; only apkrund writes under `Packages/`).
- Not included: live status, guest data, statistics, the wrapper registry (it needs WrapperCore to reduce correctly; its file name is listed in `omitted`).
- The same redactor and verification run (§6).

### 8.5 GUI flow (#060 with [host-ui.md](host-ui.md) §9.8)

1. Settings → Troubleshooting → **Create Diagnostics Report…**, a failed step's **Report…** in onboarding, the launcher's **Report a Problem…** (Help menu and error screens), or the URL `apkrun://report?package=<id>` open the report sheet. The URL only opens the sheet; creating the report still needs a click ([host-ui.md](host-ui.md) §3.1).
2. The sheet lists what is included and what is never collected (§6.1), offers **Include Android app logs** (off by default) and the focus package (preselected when opened from a wrapper), and has **Create Report…**.
3. The Save panel suggests `~/Desktop/APKRun-Diagnostics-<timestamp>.zip`. Progress shows in the sheet with **Cancel**.
4. Done: **Show in Finder** and **Copy Summary** (the text of `summary.txt`), plus a link to the project's issue page in the browser.

---

## 9. Performance harness (#070)

### 9.1 Goals

- Measure the NFR-PERF targets in a repeatable way and track them over time.
- Break every launch and boot into the marker segments of §4, so a regression points to one step ([display-and-windowing.md](display-and-windowing.md) §9 budget).
- Run nightly on the lab Mac and on demand on a developer Mac. It is not part of per-PR CI, because it needs Virtualization.framework, a GPU, and minutes of runtime.

### 9.2 The tool

`apkrun-perf` is a Swift executable target in `Tests/PerformanceTests/`. It links RuntimeClient and DiagnosticsCore only and drives the product like a user: through the CLI, `NSWorkspace`, and synthesized events.

```text
swift run apkrun-perf <scenario> [--runs <n>] [--warmup <n>] [--output <dir>] [--baseline <file>]
scenarios: warm-launch, suspended-launch, cold-launch, input-latency, hellogl-fps, idle-cpu,
           update-check-launch, boot-phases, memory, all
```

Preconditions, checked before every run and recorded in the results: AC power; Low Power Mode off; `ProcessInfo.thermalState == .nominal`; display awake (`caffeinate -d` held by the harness); no other virtual machines running; APKRun Release configuration (in the lab, signed with the lab identity); fixture apps installed from `Tests/Fixtures/AndroidApps` and their Mac apps generated into a temporary folder with `apkrun wrap <package> --output <dir>`. A failed precondition stops the run with a message rather than producing misleading numbers.

Staging: #070 (M4) builds the harness before `apkrun wrap` exists (#075, M7). Until #075, the launch scenarios open the generic launcher (`APKRunLauncher.app --package <id>`, #068) with `NSWorkspace`, and `results.json` records the launch path (`launcher` or `wrapper`). Numbers from the two paths are not compared with each other. `update-check-launch` needs update checks (#037) and the update scheduler (#074); until both exist it is reported as `skipped` with that reason.

The input scenario synthesizes events with `CGEvent.postToPid`, which needs the Accessibility permission for the harness on the lab Mac ([../05-development/environment-setup.md](../05-development/environment-setup.md)).

### 9.3 Scenarios

| Scenario | Procedure | Measure | Target |
|---|---|---|---|
| `warm-launch` | Android `ready`. For each run: `apkrun stop <package>`, wait 2 s, open the HelloText Mac app with `NSWorkspace.openApplication`, wait for its record in `launches.jsonl`, close the window. 3 warm-up runs, then 30 | `t0` (the harness's `openApplication` call) → `FIRST_FRAME_DISPLAYED`, and each marker segment | NFR-PERF-01: p50 ≤ 1.5 s, p95 ≤ 3 s |
| `suspended-launch` | as above, but wait until `VM_PAUSED` first (`runtime.idleSuspendMinutes` set to 1 for the run) | the same, plus `VM_RESUMED` → `ready` | NFR-PERF-01 + 0.5 s; resume p50 ≤ 500 ms ([runtime-daemon.md](runtime-daemon.md) §5) |
| `cold-launch` | `apkrun runtime stop`, then open HelloText. 10 runs | `t0` → `FIRST_FRAME_DISPLAYED`, boot phases from `boots.jsonl` | NFR-PERF-02: p50 ≤ 40 s |
| `input-latency` | HelloText in front. 1,000 synthetic clicks and 1,000 key presses at 20 Hz | host segments from `perfStatistics` (`input.translate`, `input.route`) plus the agent's `receive_to_inject` from `InputAck` ([input.md](input.md) §8) | NFR-PERF-03: p95 ≤ 16 ms |
| `hellogl-fps` | HelloGL in a 1080 × 2400 pixel window for 60 s after 5 s of warm-up | `fps` (10 s averages), `droppedFrames`, `hostReadbacks`, `cpuPixelCopies`, `presentGPUTime` | NFR-PERF-04: ≥ 55 fps average; NFR-PERF-05: readbacks = 0 |
| `idle-cpu` | no app open; wait for `VM_PAUSED`; sample apkrund CPU time with `proc_pid_rusage` at the start and after 300 s | CPU time ÷ wall time | NFR-PERF-06: < 1 % |
| `update-check-launch` | the `update-repos` fixture provider answers after 5 s. Trigger checks for 10 packages (`apkrun update --check-only`), then run `warm-launch` 30 times while they run | launch p50 and p95 compared with `warm-launch` of the same session | NFR-PERF-07: p50 difference ≤ 50 ms (within noise); no launch waits on a check |
| `boot-phases` | 10 cold boots without launching an app (`apkrun runtime start`) | each boot segment of §4.3 | tracked against the baseline (input for reducing NFR-PERF-02) |
| `memory` | after `warm-launch`, collect `MetricsSnapshot` with `DUMPSYS_MEMINFO` | the memory metrics of §5 | tracked only; no v1 target |

`perfStatistics(reset:)` (§7.6) returns the aggregated host-side values the harness cannot see from outside: input latency histograms, per-session graphics statistics, and marker durations. `reset: true` clears the aggregates at the start of a scenario.

### 9.4 Results and regressions

- Output: `<output>/<timestamp>-<build>/results.json` (every sample, the preconditions, the Mac model, macOS build, APKRun build, image version) and `summary.md` (a table per scenario with p50, p95, target, and baseline).
- Baselines: `Tests/PerformanceTests/baselines/<model identifier>.json`, updated only by a reviewed PR that states why.
- A nightly run fails when an NFR target is missed, or when a p50 is more than 15 % worse than the baseline (10 % for `hellogl-fps`, where lower is worse). The failure names the marker segment that grew the most.
- Reference Mac for the NFR numbers: the lowest-tier Mac in the lab (M1 with 16 GB). Other lab Macs report for information ([../04-plan/open-questions.md](../04-plan/open-questions.md)).

---

## 10. Compatibility database (#090, FR-OPS-06)

### 10.1 Purpose and rules

The database records how well known apps work on APKRun and which settings help. It uses the levels of [../00-product/scope.md](../00-product/scope.md) §4.

- It ships inside APKRun.app (`Contents/Resources/compatibility.json`) and changes only with APKRun updates. APKRun does not download it separately, and nothing is sent about which apps a user installs. The app's code signature covers the file.
- It is advice. It never blocks an install. Blocking conditions stay in the inspection checks of [package-store.md](package-store.md) §4.6.
- Owner: APKStoreCore (`CompatibilityDatabase`, loaded by apkrund at start from the bundle it lives in: `Contents/Helpers/apkrund` → `Contents/Resources/`).

### 10.2 Format

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-02T00:00:00Z",
  "entries": [
    {
      "packageID": "org.example.notes",
      "signerDigests": ["3f2a…"],
      "versionCodes": { "min": 120, "max": null },
      "level": "compatibilityMode",
      "issues": [
        { "id": "blank-secondary-display",
          "title":  { "en": "Shows a blank window in the standard window mode", "ja": "…" },
          "workaround": { "en": "APKRun uses the compatibility window mode for this app.", "ja": "…" } }
      ],
      "recommendedSettings": { "window.mode": "primaryDisplayCompatibility" },
      "testedWith": { "apkrun": "1.0", "image": "2026.10.0-cf16373615-arm64", "date": "2026-10-30" },
      "source": "lab"
    }
  ]
}
```

- `signerDigests` (optional): the entry applies only to builds signed by one of these certificates, so a different app that reuses a package name does not get the advice.
- `versionCodes` (optional, inclusive, `null` = open): the entry applies to these versions. When several entries match, the one with the narrowest range wins.
- `recommendedSettings` may use only per-package settings keys ([../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md)): `window.*`, `input.*`, `integrations.*` (only to turn an integration off), `update.healthCheckLaunch`. A schema test rejects other keys.
- `source`: `lab` (the compatibility runs, §10.4) or `report` (a user report a maintainer reproduced).
- The JSON Schema is `Tests/Compatibility/compatibility.schema.json`. CI validates the database against it.

### 10.3 Use in the product

- **Setting resolution.** `PackageSettingsResolver` applies the precedence of [../03-reference/configuration.md](../03-reference/configuration.md) §3.2, per key: a global switch that turns an integration off (`integrations.enabled.<name> = false`) wins over everything, then the package's stored value, then the database recommendation for the installed version, then the built-in default. A recommendation never turns on an integration that a global switch turns off. Recommendations are not copied into `settings.json`, so a corrected database entry takes effect after the APKRun update, and **Reset** returns to the recommendation. Values copied at the first record (`wrapper.json`, `integrations.defaults.*`) that equal the built-in default are not written either, so they do not hide a recommendation ([../03-reference/configuration.md](../03-reference/configuration.md) §3.3). Settings show "Recommended for this app" next to values that come from the database ([host-ui.md](host-ui.md) §7).
- **Display.** The add flow's review shows the user-facing label (Works / Works with limitations / Unsupported) and the known issues ([host-ui.md](host-ui.md) §6). The app page shows them under General. `apkrun inspect` and `apkrun info <package>` include a `compatibility` field. An app with no entry shows nothing ("not tested" is the normal case).
- `unsupported` apps can still be installed. The review says why the app is unsupported and changes the button to **Install Anyway**.
- The `compatibility` value in RuntimeAPI is `CompatibilityInfo{ level, label, issues, recommendedKeys }` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md)).

### 10.4 Maintaining the data

- `Tests/Compatibility/apps.json` lists the apps of the compatibility runs: the fixture apps, the 50-APK F-Droid corpus ([package-store.md](package-store.md) §16), and a sample of popular apps the maintainers install by hand.
- A run (nightly for the corpus, before each release for the full list) installs each app, launches it in the standard window mode, checks for a non-blank first frame within 20 s, runs a 60 s smoke test (`monkey` with a fixed seed through ADB in developer mode), checks the integrations the app uses, and repeats in the compatibility window mode when the standard mode fails. The output is a proposed level and issues per app.
- A maintainer reviews the proposals and commits them to `Tests/Compatibility/database/compatibility.json`. The build copies it into APKRun.app.
- Users report apps with the "App compatibility" issue template ([../05-development/workflow.md](../05-development/workflow.md)). A report becomes an entry only after a maintainer reproduces it.

---

## 11. Implementation steps

### #061 Diagnostics foundation (M0; depends on #001)

1. `APKRunPaths` and `BuildInfo` (version and build from the bundle's Info.plist; git commit injected at build time).
2. `LogSubsystem`, per-subsystem category enums, `LogMessage` with mandatory privacy, `Sensitive<T>`, `APKLogger` with the U+001F rendering and structured fields (§3.2). `LogMirrorWriter` with rotation (§3.3), used by apkrund only.
3. `OperationID`, `OperationContext` (task-local), propagation helpers for XPC headers and the guest envelope.
4. `APKRunError`, `ErrorDomain`, `ErrorParameter`, `UnderlyingError`, `RemediationAction`. `errors.json` with the first entries (`vm.*`, `cli.*`), `scripts/errorgen.swift` for the Swift and Markdown outputs, and `ErrorPresenter` for the GUI, launcher, and CLI formats of §2.3.
5. `PerfMarker`, `Perf.mark`, `Perf.interval`, `PerfTimeline`. `PerfRecordWriter` comes with #070.
6. `HealthCheck`, `HealthResult`, `HealthReport`, `HealthCheckRegistry`, the verdict function (§7.2), and `HostChecks` (§7.3). Modules add their checks as they are built. `DiagnosticsContext` (§1), with `DiagnosticsContext.testing()` in `DiagnosticsCoreTestSupport`.
7. `scripts/check-logging.sh` (no `os.Logger`, `print`, or `NSLog` outside DiagnosticsCore; no `Sensitive` unwrapping in logging calls) in CI (#062).
8. The CLI uses the error presentation from its first command (`apkrun version`, [cli.md](cli.md) §6.2).
9. Acceptance: unit tests (§12) pass. `apkrun version` logs one entry under `io.apkrun.cli` that `log show` finds. A deliberately invalid CLI argument prints the three-line error format and exits 64.

### #070 Performance harness (M4; depends on #031, #068)

1. `PerfRecordWriter` in apkrund, `launches.jsonl` and `boots.jsonl` (§4.3); `OpenSessionRequest.launchTiming` in RuntimeAPI and the launcher; `FIRST_FRAME_DISPLAYED`.
2. `perfStatistics` on the control endpoint (§7.6): input histograms, graphics statistics per session, marker aggregates.
3. `MetricsSampler` (§5), including the search for the Virtualization service process and its verification.
4. `apkrun-perf` with the preconditions and all scenarios of §9.3. For `memory`, this task adds `CollectDiagnostics` (operation 73, capability `diagnostics.v1`, [guest-protocol.md](guest-protocol.md) §7.1) on the host and in the Guest Agent's `DiagnosticsService`, with the bulk transfer, the 16 MiB item cap, the 60 s timeout, and the one item `DUMPSYS_MEMINFO`. #059 and #060 add the other items.
5. Results and summary output, baselines for the lab Macs, and the nightly job with the regression rule (§9.4).
6. Acceptance: two consecutive runs of `warm-launch` on the reference Mac agree within 10 % at p50. The segments add up to the total within 5 ms. The first report of every scenario is attached to the #070 issue and becomes the initial baseline.

### #059 `apkrun doctor` (M11; depends on #031, #034, #036)

1. `DiagnosticsService` in RuntimeHost with apkrund's registry, filled with every module's checks. Missing module checks are completed here: `graphics.*` and `agent.*` of §7.4 and the `apkrund.*` checks. `graphics.guestDriver` needs the `CollectDiagnostics` item `DUMPSYS_SURFACEFLINGER`, which this task adds on both sides (operation 73 exists since #070).
2. `healthReport` and `applyHealthFixes` in RuntimeAPI with wire types and round-trip tests. The live checks publish on the `health` topic.
3. CLI `apkrun doctor [--deep] [--fix] [--json]` with `DoctorFormatter` (§7.7) and the exit codes (§7.2). Host-only mode when apkrund is unreachable.
4. APKRun.app Troubleshooting list ([host-ui.md](host-ui.md) §9.8) with **Run Again**, **Deep Check**, and **Fix** buttons. The "Needs attention" state in the header and the menu bar.
5. Fixes of §7.5.
6. Acceptance (FR-OPS-01, #059): the scenarios of §12 T2-4 produce the verdicts `stopped`, `bootFailure`, `graphicsFailure`, `agentUnavailable`, and `healthy`, each with the expected remediation. Doctor on a healthy runtime finishes in ≤ 3 s (quick) and never starts Android.

### #060 Diagnostics bundle (M11; depends on #004, #059)

1. `Redactor` with all layers (§6), the rules version, and the verification pass.
2. `ZipWriter`, `DiagnosticsBundleBuilder`, `DiagnosticsBundleWriter`, `summary.txt` and `manifest.json` generation.
3. `DiagnosticsContributor` implementations in each module (§8.2), with budgets.
4. The remaining `CollectDiagnostics` items of §8.3 (every item except `DUMPSYS_MEMINFO` from #070 and `DUMPSYS_SURFACEFLINGER` from #059), on the host and in the Guest Agent ([guest-components.md](guest-components.md)); the logcat filter; and the logcat capture after a failed boot (§8.3).
5. `createDiagnostics` on the control endpoint with file-handle output and progress.
6. CLI `apkrun diagnostics` and the host-only bundle (§8.4). GUI sheet and `apkrun://report` (§8.5). The launcher's **Report a Problem…**.
7. Acceptance (FR-OPS-02, #060): a bundle is produced while healthy, after a boot failure, with the Guest Agent unavailable (`APKRUN_RUNTIME_FAULT=rejectAgent:guest`, as in §12 T2-4 (d)), and with apkrund not running. The secret fixture test (§12 T2-6) passes. The bundle of a healthy runtime is ≤ 100 MiB and takes ≤ 60 s.

### #090 Compatibility database (M12; depends on #059)

1. Schema, `CompatibilityDatabase` loader and matcher, `PackageSettingsResolver`, and the `compatibility` field in the RuntimeAPI package DTOs.
2. UI in the add flow, the app page, and Settings ("Recommended for this app"); CLI fields in `inspect` and `info`.
3. `Tests/Compatibility/`: `apps.json`, the run script, and the proposal output. The first run over the corpus and the fixture apps seeds the database, together with the #029 results ([display-and-windowing.md](display-and-windowing.md) §8).
4. The "App compatibility" issue template.
5. Acceptance: an app with a `compatibilityMode` entry opens in the compatibility window mode without any user setting; a user's explicit choice overrides it; an entry with a different signer digest does not apply; the file ships in the release bundle and passes schema validation in CI.

---

## 12. Tests

The IDs are stable names used by the task entries. They do not state the tier; the Tier column does ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2).

| ID | Tier | Test |
|---|---|---|
| T1-1 | T0 | `LogMessage`: every privacy mode renders the expected public and full texts; U+001F appears only when there are private values; structured fields come from `OperationContext` |
| T1-2 | T1 | compile-fail tests (a `swift build` of small fixture files in CI): interpolation without privacy, and interpolating a `Sensitive` value, do not compile |
| T1-3 | T1 | `LogMirrorWriter`: rotation at 10 MiB, drop counting when the buffer is full, mode 0600, no private values in the file |
| T1-4 | T0 | error catalog: every code has `en` and `ja` text (release), every placeholder is declared, no code equals a health check ID, every `cliExit` is valid; `errorgen` output is current |
| T1-5 | T0 | `ErrorPresenter`: CLI three-line format, JSON error object with `cause`, Copy Details line without paths |
| T1-6 | T0 | health verdict table (§7.2) for every combination of the conditions, including `graphicsFailure` before `bootFailure` and the stopped suffix |
| T1-7 | T0 | `Redactor`: each rule of §6.2–§6.4 on fixture text; placeholders are stable within one report; known secrets in raw, URL-encoded, base64, and UTF-16 forms; verification drops a file that still contains a known secret |
| T1-8 | T0 | logcat filter: system UID lines kept, app UID lines dropped, fatal exception lines of app processes kept; `--include-logcat` keeps everything |
| T1-9 | T0 | `PerfRecordWriter`: record format, relative times, retention rewrite; `launchState` classification |
| T1-10 | T0 | `CompatibilityDatabase` matching (signer, version range, narrowest range wins) and settings resolution order |
| T2-1 | T1 | host-only doctor and bundle with apkrund unregistered (run as a separate macOS test user account; relocating `APKRUN_HOME` does not work, because commands other than `apkrun dev` ignore it, [cli.md](cli.md) §3.6) |
| T2-2 | T1 | `apkrun logs` with and without `log show` access (mirror fallback) |
| T2-3 | T2 | `OperationID` of `apkrun install` appears in the CLI, apkrund, and Store Agent logs |
| T2-4 | T2 | FR-OPS-01 scenarios: (a) runtime stopped → `stopped`; (b) boot failure with the test image flag that stops boot (`androidboot.apkrun.test.fail_boot=1`) → `bootFailure` with the phase; (c) renderer failure through the fault hook `APKRUN_GRAPHICS_FAULT=rendererInit` → `graphicsFailure`; (d) apkrund rejecting the Guest Agent handshake through `APKRUN_RUNTIME_FAULT=rejectAgent:guest` (the agent is persistent on the custom image, so stopping it is not reliable) → `agentUnavailable`. Fault hooks are compiled into debug builds only, like `APKRUN_STORE_FAULT` ([package-store.md](package-store.md) §16); (e) healthy → `healthy` |
| T2-5 | T2 | bundle while healthy, after (b), with the Guest Agent unavailable (d), and without apkrund: every expected file or `omitted` reason is present; the ZIP opens with `ditto -x -k` |
| T2-6 | T2 | **secret fixture test** (#060): fixture secrets `APKRUN-FIXTURE-SECRET-<n>` planted in a provider token (test Keychain), a URL query, a log message argument marked `.private`, the console (`/dev/kmsg` write from test bundle S, [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.5), app logcat (HelloClipboard logs its clipboard text), the clipboard and a notification (HelloClipboard, HelloNotification), a shared folder file name, a wrapper path, the Mac user name (test account name contains a fixture string), and getprop (`persist.apkrun.test.secret`). The unzipped bundle, searched in raw, URL-encoded, base64, and UTF-16 forms, contains none of them, with and without `--include-logcat` |
| T2-7 | T2 | `--fix` for `wrappers.registration` and `agent.ime` |
| T3-1 | T3 | perf harness scenarios of §9.3 on the reference Mac (NFR-PERF-01…07) |
| T3-2 | T3 | doctor and bundle from APKRun.app's Troubleshooting pane, including **Report a Problem…** from a wrapper |

---

## 13. Open items

| Item | Plan |
|---|---|
| Identifying the Virtualization.framework XPC service process that hosts APKRun's VM (for the host-side VM footprint, §5) | #070 tries matching by process name, user, and start time right after `VM_START`. If it is unreliable, the metric is reported as unavailable |
| `log show` needs an administrator account; the exact behavior on macOS 27 for standard users | verify in #061. The mirrors (§3.3) cover the gap either way |
| `logcat -v uid` output on the Android 17 image | verify in #060 on the stock image; if the UID is missing, filter by the PID → UID map from `ps -A -o PID,UID` collected at the same time |
| Package IDs in reports reveal which apps a user has | included by default because support needs them (#060); the sheet says so. Revisit if users ask for an option to exclude them ([../04-plan/open-questions.md](../04-plan/open-questions.md)) |
| The reference Mac for NFR numbers (§9.4) | confirm the lab hardware before #070 ([../04-plan/open-questions.md](../04-plan/open-questions.md)) |
| `gpuUtilization` through IOKit accelerator statistics is not a documented API | best effort; reported as unavailable when the key is missing |

---

## 14. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| How does `log show` behave for standard users on macOS 27? | #061 | pending (§3.5, OQ-04) |
| Does `logcat -v uid` print the UID on the Android 17 image, or is the `ps` fallback used? | #060 | pending (§8.3, OQ-05) |
| Can the Virtualization.framework XPC service process of APKRun's VM be identified? | #070 | pending (§5, OQ-06) |
| Is `gpuUtilization` from the IOKit accelerator statistics usable? | #070 | pending (§5, OQ-07) |
| The first report of every scenario on the reference Mac (the initial baseline) | #070 | pending (§9.4) |
| Two consecutive `warm-launch` runs agree within 10 % at p50, and the segments add up to the total within 5 ms | #070 | pending (§11 #070) |
| Quick doctor time (≤ 3 s) and deep doctor time on a healthy runtime | #059 | pending (§7) |
| Size (≤ 100 MiB) and time (≤ 60 s) of the bundle of a healthy runtime | #060 | pending (§8.1) |
