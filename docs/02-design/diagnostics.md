# Diagnostics, observability, and performance measurement

This document defines error reporting, logging, performance markers, health checks, `apkrun doctor`, the diagnostics bundle, the performance harness, and the compatibility database. Subsystem documents add their log categories, markers, and health checks to this model.

---

## 1. Responsibilities and components

`DiagnosticsCore` is a leaf module ([modules.md](../01-architecture/modules.md) §2). Every process uses it.

| Component (DiagnosticsCore) | Section |
|---|---|
| `APKRunPaths` (every path of [filesystem-layout.md](../01-architecture/filesystem-layout.md)), `BuildInfo` | §8.2 |
| `APKRunError`, `ErrorDomain`, `RemediationAction`, `ErrorCatalog` | §2 |
| `OperationID`, `OperationContext` | §2.4 |
| `APKLogger`, `LogSubsystem`, `LogMessage`, `Sensitive<T>`, `LogSink`, `LogMirrorWriter`. `LogSink` is `os.Logger` in production and `RecordingLogSink` in tests | §3 |
| `PerfMarker`, `Perf`, `PerfTimeline`, `PerfRecordWriter` | §4 |
| `MetricsSampler`, `MetricsSnapshot` | §5 |
| `Redactor`, `RedactionRules` | §6 |
| `HealthCheck`, `HealthResult`, `HealthReport`, `HealthCheckRegistry`, `HostChecks`, `DoctorFormatter` | §7 |
| `DiagnosticsContributor`, `DiagnosticsBundleWriter`, `ZipWriter` | §8 |
| `DiagnosticsContext`: the `Sendable` value that module entry points take (for example `VMController.init`, [vm.md](vm.md) §2). `DiagnosticsContext.live(paths:)` builds it; `DiagnosticsContext.testing()` is in `DiagnosticsCoreTestSupport` | — |

Outside DiagnosticsCore:

| Component | Module | Role |
|---|---|---|
| `DiagnosticsService` | RuntimeHost | serves health, diagnostics, and statistics operations (§7.6, §8.1); owns apkrund's registry and contributor list |
| health checks, contributors | each module | implement the checks of their documents (§7.4) and bundle sections (§8.2) |
| `CompatibilityDatabase`, `PackageSettingsResolver` | APKStoreCore | §10 |
| `apkrun-perf` | `Tests/PerformanceTests/` | the harness (§9) |
| wire types `WireError`, `WireHealthReport`, `WirePerfStatistics`, `DiagnosticsRequest` | RuntimeAPI | copies of the DiagnosticsCore types. RuntimeAPI imports only Foundation and IOSurface ([modules.md](../01-architecture/modules.md) §3); RuntimeHost converts to them, RuntimeClient back |

---

## 2. Error model (FR-CLI-02, NFR-DEV-03)

### 2.1 `APKRunError`

Every error that can reach a user is a typed domain error. Each domain enum conforms to `APKRunError`:

```swift
public protocol APKRunError: Error, Sendable {
    static var domain: ErrorDomain { get }
    var code: String { get }                          // the case name, stable: "downgradeRefused"
    var parameters: [String: ErrorParameter] { get }  // public-safe values for the template
    var listItems: [ErrorListItem] { get }            // ordered details of list cases
    var cause: (any APKRunError)? { get }             // nested domain error
    var underlying: UnderlyingError? { get }          // system error: domain and code only
}
public extension APKRunError {
    var qualifiedCode: String { "\(Self.domain.rawValue).\(code)" }   // "store.downgradeRefused"
}
public enum ErrorParameter: Sendable, Codable, Equatable {
    case text(String)        // public-safe: package ID, version name, app label, step name
    case bytes(Int64)        // ByteCountFormatter
    case count(Int)
    case duration(Duration)
    case fileName(String)    // last path component only. Full paths are never parameters
}
public enum ErrorListItemSelector: Codable, Sendable, Equatable {
    case errorCode(String)                       // fully qualified catalog code
    case variant(code: String, key: String)      // catalog code and variant key
}
public struct ErrorListItem: Codable, Sendable, Equatable {
    public let selector: ErrorListItemSelector
    public let parameters: [String: ErrorParameter]
}
public struct UnderlyingError: Sendable, Codable, Equatable {
    public var domain: String    // "VZErrorDomain", "NSPOSIXErrorDomain", "OSStatus"
    public var code: Int         // userInfo is dropped: it may contain paths
}
```

- `VMConfigurationFailure.configurationInvalid` fills `listItems` in validation order, including repeated codes. RuntimeAPI carries `listItems` in a compatible wire field.
- Health findings (for example `runtime.hostRequirementsNotMet`) use `ErrorInfo`, not `listItems`.

| Domain (`ErrorDomain`) | Swift type | Owner |
|---|---|---|
| `vm` | `VMFailure`, `VMConfigurationFailure` | [vm.md](vm.md) |
| `graphics` | `GraphicsFailure` | [graphics.md](graphics.md) |
| `runtime` | `RuntimeFailure` | [runtime-daemon.md](runtime-daemon.md) |
| `guestProtocol` | `GuestProtocolFailure` | [guest-protocol.md](guest-protocol.md) |
| `image` | `ImageFailure` | [android-image.md](android-image.md) |
| `store` | `StoreFailure` | [package-store.md](package-store.md) |
| `update` | `UpdateFailure` (nested `ValidationFailure`, `HealthCheckFailure`) | [update-system.md](update-system.md) |
| `wrapper` | `WrapperFailure` | [wrapper.md](wrapper.md) |
| `integration` | `IntegrationFailure` | [desktop-integration.md](desktop-integration.md) |
| `maintenance` | `MaintenanceFailure` | [runtime-maintenance.md](runtime-maintenance.md) §11 |
| `diagnostics` | `DiagnosticsFailure` (below) | this document |
| `cli` | `CLIFailure` (for example `cli.confirmationRequired`) | [cli.md](cli.md) |

The code prefix is `<domain>.`.

- A code never changes meaning once released. A removed case keeps its code reserved (`"retired": true`, §2.2).
- A nested error keeps the outer code (`UpdateFailure.installFailed(StoreFailure)` keeps `update.installFailed`). `{cause}` in the outer message renders the inner message. Without an outer remediation, the inner one is used. JSON carries the chain as `cause`.
- Error codes, configuration keys, and health check IDs use `<domain>.<name>` in separate namespaces. A catalog test fails if an error code equals a health check ID.
- `fatalError` and `preconditionFailure` are for programming errors only.

`DiagnosticsFailure` covers reports, fixes, and the host and service findings of §7.3. Findings are never thrown; they appear only as `HealthResult.error`:

```swift
public enum DiagnosticsFailure: APKRunError {
    // reports and fixes (§7.5, §7.6, §8.1)
    case stagingFailed                                  // $TMPDIR staging directory cannot be created or written
    case bundleWriteFailed                              // writing the ZIP to the client's file handle failed
    case unknownHealthCheck(check: HealthCheckID)       // apkrund does not know this ID (N−1 client)
    case fixNotAvailable(check: HealthCheckID)          // no fix, or not offered now
    case fixFailed(check: HealthCheckID, underlying: any APKRunError)
    // findings of host and service checks (§7.3), never thrown
    case appNotInApplications                           // host.appLocation
    case appSignatureInvalid                            // host.appSignature
    case componentVersionMismatch(build: String)        // host.componentVersions
    case lowDiskSpace(available: Int64)                 // host.dataVolume, image.freeSpace, store.hostSpace
    case lowMemory(memory: Int64)                       // host.memory
    case serviceVersionMismatch(build: String)          // apkrund.version: variants restartPending, androidRunning
    case serviceCrashLoop(count: Int)                   // apkrund.crashLoop
}
```

A cancelled report is `runtime.cancelled`. A contributor that fails or overruns goes to `omitted` (§8.1), not to an error.

### 2.2 The error catalog

- The catalog is the only source of user-facing error text for the GUI, menu bar, launcher, and CLI ([host-ui.md](host-ui.md) §13).
- `Packages/DiagnosticsCore/ErrorCatalog/errors.json` is the source. `swift scripts/errorgen.swift --markdown` regenerates the tables of [error-catalog.md](../03-reference/error-catalog.md) §5–§16 and §20.3; CI fails if they differ. `errorgen` also writes `ErrorCatalog.generated.swift` with all languages as Swift literals, because the launcher has no resource bundles ([wrapper.md](wrapper.md) §5.9). CI checks it is current.
- Entry:

  ```json
  {
    "code": "store.downgradeRefused",
    "parameters": ["app", "installedVersion", "newVersion"],
    "message":     { "en": "{app} {newVersion} is older than the installed version {installedVersion}.", "ja": "…" },
    "remediation": { "en": "Keep the installed version, or uninstall {app} first.", "ja": "…" },
    "action": "none",
    "cliExit": 5
  }
  ```

- Optional members ([error-catalog.md](../03-reference/error-catalog.md) §3.1):
  - `variants`: texts and action per sub-reason, for example per `InstallFailureKind` of `store.guestInstallFailed`. Keys are sub-enum case names, or `hostNewer`, `guestNewer`, `sharedFolders`, `schemaVersion`, `restartPending`, `androidRunning`. The error passes the key as parameter `reason`. A variant overrides `message`, `remediation`, and `action` only. A list case keeps its names in the `items` parameter and an ordered `listItems` array, one hint line per item ([error-catalog.md](../03-reference/error-catalog.md) §3.4).
  - `transparent: true`: a pure container (for example `runtime.image(ImageFailure)`). Texts and exit code come from the first non-transparent error in the cause chain. `"cliExit": "cause"` is allowed only here ([error-catalog.md](../03-reference/error-catalog.md) §3.5).
  - `retired: true`: a removed case. Its texts stay, so a code sent by an N−1 peer still renders ([error-catalog.md](../03-reference/error-catalog.md) §2.2).
  - `cliExitRule`: a named rule for list errors whose exit depends on items. The fixed `cliExit` is the fallback.
- An unknown code is transparent when its cause chain holds a known code. Otherwise the generic entry of [error-catalog.md](../03-reference/error-catalog.md) §3.8 is shown, with the original code on the `code:` line.
- Language follows `Locale.preferredLanguages` of the presenting process, English as fallback.

### 2.3 Remediation actions and presentation

```swift
public enum RemediationAction: String, Sendable, Codable {
    case none, retry, openTroubleshooting, restartAndroid, startGraphicsSafeMode,
         openRuntimeSettings, openStorageSettings, openPrivacySettings,
         openLoginItemsSettings,        // System Settings → General → Login Items & Extensions
         openNotificationSettings,      // System Settings → Notifications
         openDownloadsPage,             // the APKRun downloads page
         updateAPKRun, updateAndroid, updateMacApp, createMacApp, reinstallApp, reportProblem
}
```

- `updateAPKRun` opens Settings → General and starts a user-initiated Sparkle check. `updateAndroid` opens Settings → General and starts the Android system update ([runtime-maintenance.md](runtime-maintenance.md) §4.6).
- `openDownloadsPage` (reinstall APKRun) opens the Info.plist URL `APKRunDownloadsURL` ([configuration.md](../03-reference/configuration.md) §7.1) with `NSWorkspace.open(_:)`. The launcher opens `LauncherBuild.downloadURL`, the same URL compiled into its template, because APKRun.app may be missing ([wrapper.md](wrapper.md) §5.4).
- APKRun.app and APKRunMenuBar show the message as title, the remediation as body, a button for `action`, **Copy Details**, and **Troubleshooting…** where it helps ([host-ui.md](host-ui.md) §1). The launcher uses its error screens ([wrapper.md](wrapper.md) §5.4).
- CLI: three stderr lines. `--json` puts the same fields in the `error` object ([cli.md](cli.md) §3.2):

  ```text
  error: Hello GL 1.2 is older than the installed version 1.3.
  hint: Keep the installed version, or uninstall Hello GL first.
  code: store.downgradeRefused (operation 3f9a1c2e)
  ```

- **Copy Details** copies one line: version, image, code, operation, time, and the underlying domain and code. It has no personal data and no paths.

### 2.4 Operation IDs

An `OperationID` ties together everything one user-visible operation does (NFR-OBS-01).

- A random UUID (version 4), lowercase. UI and CLI show the first 8 hex digits. JSON and Copy Details use the full value. Logs use `op=<first 8 hex>`.
- The starting client creates the ID: the GUI or CLI for a command, the launcher for `openSession`. apkrund creates IDs for its own work (scheduled updates, idle stop, startup recovery).
- The ID travels in `APIRequestHeader.operationID` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.1), `OperationHandle`, and the guest envelope's `operation_id` ([guest-protocol.md](guest-protocol.md) §4.1).
- `OperationContext` is a task-local value (`@TaskLocal static var current`). `APKLogger` adds it to every entry. Child work inherits it. A sub-operation (one package of `apkrun update --all`) has its own ID, with `parent` set to the run's ID.
- Guest agents log `op=<first 8 hex>` ([guest-components.md](guest-components.md) §9). IDs identify operations, not users or Macs.

---

## 3. Logging (NFR-OBS-01, NFR-SEC-05)

### 3.1 Subsystems and categories

Unified logging (`os_log`) is the primary sink. Host processes log only through `APKLogger`. `os.Logger`, `print(`, and `NSLog` outside DiagnosticsCore fail `scripts/check-logging.sh` in CI. `LogSubsystem` is a closed enum with exactly these values. Categories are per-subsystem enums.

| Subsystem | Processes | Categories | Defined in |
|---|---|---|---|
| `io.apkrun.runtime` | apkrund | `host`, `supervisor`, `agents`, `idle`, `power`, `sessions`, `display`, `xpc`, `adb` | [runtime-daemon.md](runtime-daemon.md) §12 |
| `io.apkrun.vm` | apkrund | `lifecycle`, `config`, `console`, `vsock`, `network`, `virtio` | [vm.md](vm.md) §14 |
| `io.apkrun.graphics` | apkrund | `device`, `renderer`, `present`, `stats` | [graphics.md](graphics.md) |
| `io.apkrun.input` | launcher, apkrund | `translate`, `route`, `ime` | [input.md](input.md) §11 |
| `io.apkrun.image` | apkrund | `store`, `install`, `verify`, `instance`, `boot`, `migration` | [android-image.md](android-image.md) §14 |
| `io.apkrun.store` | apkrund | `import`, `transaction`, `channel`, `reconcile` | [package-store.md](package-store.md) §13 |
| `io.apkrun.update` | apkrund | `scheduler`, `provider`, `validate`, `install`, `health` | [update-system.md](update-system.md) §14 |
| `io.apkrun.wrapper` | apkrund, launcher | `generate`, `sign`, `icon`, `registry`, `approval`, `lifecycle`, `launcher`, `window`, `integration` | [wrapper.md](wrapper.md) §14 |
| `io.apkrun.integration` | apkrund | `clipboard`, `notifications`, `links`, `files`, `audio`, `locale` | [desktop-integration.md](desktop-integration.md) §13 |
| `io.apkrun.maintenance` | APKRun.app, apkrund | `selfUpdate`, `imageUpdate` | [runtime-maintenance.md](runtime-maintenance.md) §12 |
| `io.apkrun.ui` | APKRun.app | `app`, `onboarding`, `operations`, `approval`, `settings` | [host-ui.md](host-ui.md) |
| `io.apkrun.menubar` | APKRunMenuBar | `status` | [host-ui.md](host-ui.md) §12 |
| `io.apkrun.cli` | apkrun | `command`, `client` | [cli.md](cli.md) |
| `io.apkrun.diagnostics` | all | `health`, `bundle`, `perf`, `redaction` | this document |

### 3.2 The facade and privacy

```swift
let log = APKLogger(.store, category: .transaction)
log.info("commit \(txn, .public) \(packageID, .public) \(fromCode, .public)→\(toCode, .public)")
log.error("import failed for \(fileName, .private)", error: failure)   // adds err=store.<code>
```

- **Every interpolation states its privacy** (`.public`, `.private`, or `.hashed`). There is no default, so a missing privacy is a compile error.
- `.hashed` renders `#` plus the first 8 hex digits of SHA-256 over a random per-process salt and the value. Hashes correlate within one process only.
- `Sensitive<T>` wraps values never logged at any level: clipboard content, notification title and text, IME text, file contents, credentials and tokens, Android account names. Its `description` is `<redacted>`. `LogMessage` has no overload for it, so logging one does not compile. IntegrationCore, InputCore, and UpdateCore (provider credentials) hold such values only inside `Sensitive`.
- The facade appends ` op=<id8> pkg=<packageID> disp=<displayID> sess=<sessionID> err=<qualifiedCode>` (always public) from `OperationContext` and the `error:` argument. `apkrun logs` and the bundle's "Recent problems" (§8.3) parse these fields.
- The facade renders a **public text** (private values as `<private>`, hashed values as their hash) and, only when private values exist, a **full text**. It sends `"\(publicText, privacy: .public)\u{1F}\(fullText, privacy: .private)"` to `os.Logger`. Messages render only when `OSLog.isEnabled(type:)`.
- Public: IDs, versions, error codes, counts, sizes, durations, states, digests truncated to 12 hex, provider type, host name. `.private` or `.hashed`: paths (after §6.3), file names, URLs beyond scheme and registrable domain, window titles, Android app labels in free text. Input details are `.private` and logged only at debug level in development builds ([input.md](input.md) §9).

| Level | Use |
|---|---|
| `debug` | per-frame, per-event, per-message detail. Off in release unless `log config` enables it |
| `info` | state transitions, operation start and end, timings |
| `notice` (`default`) | user-visible outcomes: installed, updated, rolled back, Android started or stopped |
| `warning` (`default`) | a recoverable condition. Carries its catalog code when one applies |
| `error` | an operation failed with a typed error. Always carries `err=` |
| `fault` | an invariant was violated, for example an invalid state transition ([state-machines.md](../01-architecture/state-machines.md)) |

OSLog has no warning type. Warnings are written as `default` under the reserved category suffix `.__apkrun_warning`. `apkrun logs` removes the suffix and restores the level, so message text cannot set severity. Unknown or missing types stay `unknown`, never `notice`.

### 3.3 File mirrors

`log show` needs an administrator account and can be slow, so apkrund keeps file mirrors ([filesystem-layout.md](../01-architecture/filesystem-layout.md) §2):

| File | Writer | Content | Rotation |
|---|---|---|---|
| `apkrund.log`, `apkrund.1.log`, `apkrund.2.log` | `LogMirrorWriter` | public text of every apkrund `info` and higher entry: ISO 8601 time, level, subsystem/category, message, fields | 10 MiB × 3 |
| `vm/console.log`, `vm/console.<n>.log`, `vm/boot-<timestamp>.log` | `ConsoleLogWriter` ([vm.md](vm.md)) | guest serial console, unredacted | 20 MiB × 5; last 5 boots |
| `guest/logcat-<timestamp>.log` | RuntimeCore | logcat capture (§8.3) | 20 MiB each; last 5 |
| `crash/<timestamp>-runtime/` | RuntimeCore | failure snapshots ([runtime-daemon.md](runtime-daemon.md) §3.6) | last 10 |
| `perf/launches.jsonl`, `perf/boots.jsonl` | `PerfRecordWriter` | perf records (§4.3) | newest 2,000 / 200 |

- The mirror writer is asynchronous: a serial queue with a 1 MiB buffer, flushed every second and after each `error` and `fault`. A full buffer drops and counts entries (`diagnostics.mirrorDropped`).
- Only apkrund writes mirrors. Other processes log to unified logging; their failures that matter reach apkrund as operation results. Files are created with mode 0600.

### 3.4 Guest logs

- Agent logs use logcat tags `ApkRunGuest`, `ApkRunInput`, `ApkRunIme`, `ApkRunStore`, and `apkrun_vsockd` ([guest-components.md](guest-components.md) §9). They reach the host through `CollectDiagnostics` (§8.3) and logcat capture. The ring buffers `agent.log` and `store.log` (2 × 1 MiB) survive logcat rotation and come through item `AGENT_LOG`.
- Kernel log, init, and `VIRTUAL_DEVICE_*` status lines (early boot) go to serial `hvc0` → `vm/console.log` ([android-image.md](android-image.md) §7.1). The full logcat stream goes to `hvc2` → `guest/logcat-<timestamp>.log` when capture is on.
- Agents follow the host rules: clipboard, notification text, typed or IME text, and account names are never logged. Key codes, pointer positions, and file names appear only at debug level, which release builds compile out.

### 3.5 Reading logs

- `apkrun logs` ([cli.md](cli.md) §4.8) runs `/usr/bin/log show` or `log stream` with `--predicate 'subsystem BEGINSWITH "io.apkrun"' --style ndjson`, cuts messages at U+001F, and prints time, level, subsystem/category, and message. Default window: the last hour. `--since` replaces it, up to 30 days. `--subsystem` adds a narrower prefix. `--json` prints NDJSON with Unicode formatting scalars escaped, one record per line. Human output escapes Unicode control and formatting characters. A minimum level applies to unified-log and mirror records alike; unrecognized levels are omitted when one is set.
- `--follow`:
  - `apkrun logs --follow` waits up to 30 s for the `/usr/bin/log stream` subscription notice (stderr) or the first record (stdout) before the history query. `/usr/bin/log stream` has no `--follow` option. Records over 1 MiB are discarded through the next newline.
  - Live records are buffered during the history read: at most 4,096 records or 4 MiB of estimated text. Pipe reads pause at either limit. `--since` applies to history only.
  - After a stream exit, retry with a delay growing from 1 s to 30 s. When the replacement is ready, run `log show --start` from one second before the last covered instant, while buffering live output.
  - The checkpoint advances only through the later of the query start and the replacement-stream end. After a partial history query it stays at the oldest requested boundary until a complete query covers the gap. Identical records are kept separate. Late rows are kept, not suppressed by timestamp.
  - If the stream is not ready after three attempts, a one-shot history query with mirror fallback runs and the command exits. A quiet live stream stays open.
- If `log show` fails, times out, or matches nothing, mirrors are read and stderr says so. With no readable source, the command reports `cli.logsUnavailable` and exits 1. Partial output and an empty successful query both count as readable.
- `apkrun logs --guest` reads the `guestLog` stream (§7.6, [runtime-api.md](../03-reference/runtime-api.md) §13.1) and needs developer mode.
- Developers: `log stream --level debug --predicate 'subsystem BEGINSWITH "io.apkrun"'`. Instruments shows the signposts of §4.

---

## 4. Performance markers (FR-OPS-05)

### 4.1 Model

```swift
public struct PerfMarker: RawRepresentable, Hashable, Sendable { public let rawValue: String }   // "FIRST_FRAME"
public enum PerfValue: Sendable, Equatable { case string(String), integer(Int64), double(Double), boolean(Bool) }

public enum Perf {
    public static let timeline: PerfTimeline
    public static func mark(_ marker: PerfMarker,
                            at time: ContinuousClock.Instant = .now,
                            _ attributes: [String: PerfValue] = [:],
                            timeline: PerfTimeline = Perf.timeline)
    public static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T  // signpost only
}
```

- `Perf.mark` emits an `OSSignposter` event (category `pointsOfInterest`) and appends marker, time, attributes, and operation context to the process `PerfTimeline`, a ring of the last 2,000 markers.
- Subsystem: a marker uses the subsystem of its catalogue emitter (§4.2). An unknown marker uses `io.apkrun.diagnostics`. Intervals use `io.apkrun.graphics` for `gpu.*`, `io.apkrun.input` for `input.*`, and `io.apkrun.diagnostics` otherwise.
- Lifecycle events use the static event name `APKRunPerfMarker`; the marker name and fields go in the message. A marker outside the catalogue is stored as `UNKNOWN`.
- Attributes are allowlisted: at most 16 per event, only keys of §4.2 (more than 16 drops all). Names are at most 64 ASCII bytes; strings at most 256 UTF-8 bytes. Longer values and unknown keys are dropped before storage. The signpost emits strings only for `bootKind` (`cold`, `firstBoot`, `migration`) and `agent` (`guest`, `store`). Writers that persist timeline data apply §3.2.
- Signposts cannot be backdated. The payload carries `sourceTimeOffsetMsAtSample`: the signed millisecond distance from the `at:` instant to a `ContinuousClock` sample taken after the base fields are prepared and just before encoding and `emitEvent`. The timeline keeps the `at:` instant.
- `Perf.interval` makes a signpost interval only, for high-frequency work. It is not recorded in the timeline.
- Host markers use `ContinuousClock` (`mach_continuous_time`), the same clock in every process, so launcher and apkrund times can be subtracted. Guest times are never mixed with host times ([input.md](input.md) §8).
- A mark does one signpost emission and one in-memory append. It does no file I/O and never writes through `LogSink` or `LogMirrorWriter`.

### 4.2 Catalogue

The catalogue requires these markers: `VM_START`, `APP_LAUNCH_REQUEST`, `ACTIVITY_STARTED`, `FIRST_FRAME`, `UPDATE_CHECK_START`, `UPDATE_DOWNLOAD_END`, and `UPDATE_INSTALL_END`. `BOOT_COMPLETED` is Android's `sys.boot_completed=1` event and the marker of the `.bootCompleted` phase.

| Marker | Emitted by | Emitted when | Attributes |
|---|---|---|---|
| `DAEMON_READY` | RuntimeHost | broker listener resumed after startup recovery | `startupMs`, `recoverySteps` |
| `VM_START` | VirtualMachineCore | `VZVirtualMachine.start` called | `bootKind` (`cold`, `firstBoot`, `migration`) |
| `KERNEL_START`, `ANDROID_INIT`, `SYSTEM_SERVER_READY`, `BOOT_COMPLETED` | RuntimeCore `BootPhaseDetector` | first kernel console line; first-stage init; system server up; `sys.boot_completed=1` | |
| `AGENT_CONNECTED` | RuntimeCore | agent handshake accepted | `agent` (`guest`, `store`) |
| `RUNTIME_READY` | RuntimeCore | `RuntimeState` becomes `ready` | `bootMs` |
| `VM_PAUSED`, `VM_RESUMED` | RuntimeCore | idle suspend and resume ([runtime-daemon.md](runtime-daemon.md) §5) | `pausedMs` on resume |
| `WRAPPER_PROCESS_START` | launcher, recorded by apkrund | kernel start time of the launcher (`proc_pidinfo(PROC_PIDTBSDINFO)`) | |
| `APP_LAUNCH_REQUEST` | launcher, recorded by apkrund | `openSession` sent ([wrapper.md](wrapper.md) §5.2) | `xpcDelayMs` |
| `DISPLAY_ATTACHED` | RuntimeCore `DisplayPool` | lease ready ([display-and-windowing.md](display-and-windowing.md) §3) | `slot`, `displayID`, `reused` |
| `ACTIVITY_STARTED` | RuntimeCore | agent reports the activity resumed | `processStarted` |
| `FIRST_FRAME` | RuntimeCore | first `frameReady` on the session scanout ([graphics.md](graphics.md) §7) | |
| `FIRST_FRAME_DISPLAYED` | RuntimeCore | first `frameDisplayed` from the wrapper | |
| `WRAPPER_GENERATE_START`, `WRAPPER_GENERATE_END`, `WRAPPER_REFRESH_END`, `WRAPPER_APPROVAL_END` | WrapperCore | [wrapper.md](wrapper.md) §14 | `result`, `durationMs`, `kind` |
| `PACKAGE_IMPORT_START`, `PACKAGE_INSPECTED`, `PACKAGE_INSTALL_START`, `PACKAGE_INSTALL_COMPLETE`, `PACKAGE_ROLLBACK_COMPLETE` | APKStoreCore | [package-store.md](package-store.md) §13 | `bytes`, `splits`, `status` |
| `UPDATE_CHECK_START`, `UPDATE_CHECK_END`, `UPDATE_DOWNLOAD_START`, `UPDATE_DOWNLOAD_END`, `UPDATE_INSTALL_START`, `UPDATE_INSTALL_END`, `UPDATE_HEALTH_END`, `UPDATE_ROLLBACK_END` | UpdateCore | [update-system.md](update-system.md) §14 | `provider`, `result`, `bytes` |
| `CLIPBOARD_PUSH`, `NOTIFICATION_DELIVERED`, `FILE_TRANSFER` | IntegrationCore | [desktop-integration.md](desktop-integration.md) §13 | `durationMs`, `bytes` |
| `SELF_UPDATE_CHECK_END`, `HOST_UPDATE_PREPARE_START`, `HOST_UPDATE_PREPARED`, `HOST_UPDATED` | `MaintenanceService`, `SelfUpdateProbe` | [runtime-maintenance.md](runtime-maintenance.md) §12 | `result`, `fromBuild`, `toBuild`, `durationMs` |
| `IMAGE_CHECK_END`, `IMAGE_DOWNLOAD_START`, `IMAGE_DOWNLOAD_END`, `IMAGE_INSTALL_END`, `IMAGE_MIGRATION_START`, `IMAGE_MIGRATION_END`, `IMAGE_ROLLBACK_END` | `ImageUpdateCoordinator` | [runtime-maintenance.md](runtime-maintenance.md) §12 | `imageVersion`, `result`, `bytes`, `durationMs` |

- The launcher passes `OpenSessionRequest.launchTiming { processStart, requestSent }` (continuous-clock nanoseconds, [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3). apkrund records `WRAPPER_PROCESS_START` and `APP_LAUNCH_REQUEST` in the session timeline.
- Interval-only signposts, not in the timeline: `gpu.flush`, `gpu.present` ([graphics.md](graphics.md) §7), `input.translate`, `input.route` ([input.md](input.md) §8).

### 4.3 Perf records

apkrund writes one record per launch and one per boot. They hold no personal data beyond package IDs. Nothing leaves the Mac unless the user attaches a report.

`perf/launches.jsonl` gets one line per session launch, at `FIRST_FRAME_DISPLAYED` or when the session ends first. Keys: `v` (1), `recordedAt`, `packageID`, `versionCode`, `sessionID`, `operationID`, `launchState`, `windowMode`, `build`, `image`, `gpuProfile`, `markers` (ms relative to `WRAPPER_PROCESS_START`), `totalMs`, `outcome` (`shown`, `ended(<reason>)`, `failed(<code>)`).

| `launchState` | Meaning | Target |
|---|---|---|
| `hot` | app process already running (window reopened) | — |
| `warm` | Android `ready`, app process not running | NFR-PERF-01: p50 ≤ 1.5 s, p95 ≤ 3 s |
| `suspended` | Android was `suspended` and resumed | NFR-PERF-01 + 0.5 s ([runtime-daemon.md](runtime-daemon.md) §5) |
| `cold` | Android was stopped and booted for this launch | NFR-PERF-02: p50 ≤ 40 s |
| `firstBoot` | provisioning boot | excluded from statistics |

`perf/boots.jsonl` gets one line per boot with the same `v`: markers `VM_START` (as 0), `KERNEL_START`, `ANDROID_INIT`, `SYSTEM_SERVER_READY`, `BOOT_COMPLETED`, `AGENT_CONNECTED` (both agents), `RUNTIME_READY`; plus `bootKind`, `gpuProfile`, `memoryGiB`, `cpuCount`, `outcome` ([runtime-maintenance.md](runtime-maintenance.md) §5). At apkrund start, a file over its limit (§3.3) is rewritten atomically with the newest records.

---

## 5. Metrics

`MetricsSnapshot` is collected on demand: for `apkrun doctor --deep`, bundles, and `perfStatistics` (§9.3). There is no background polling. The one periodic sampler (`apkrundCPU`, once per second) runs only while a scanout is presenting or a statistics subscriber exists (NFR-PERF-06).

| Metric | Source |
|---|---|
| VM memory | `VMDefinition` size, balloon target, guest `MemTotal` and `MemAvailable` from `Health.memory` ([guest-protocol.md](guest-protocol.md) §7.4), host footprint of the Virtualization XPC service (`proc_pid_rusage`, `ri_phys_footprint`; OQ-06) |
| guest processes (`system_server`, `SurfaceFlinger`, `zygote`/`zygote64`, apps) | `CollectDiagnostics` item `DUMPSYS_MEMINFO` (`dumpsys meminfo -c`): PSS and RSS. On demand; about 1 s of guest CPU |
| host graphics memory | `resourceMemory` and high-water mark, SurfacePool IOSurface bytes (`IOSurfaceGetAllocSize`), `MTLDevice.currentAllocatedSize` ([graphics.md](graphics.md) §5.4, §6.3) |
| apkrund memory and CPU | `task_vm_info.phys_footprint`, `resident_size`; `task_info` thread times |

Graphics metrics (defined in [graphics.md](graphics.md) §7): `fps`, `guestFlushRate`, `flushToReady`, `readyToDisplayed`, `presentGPUTime`, `droppedFrames`, `hostReadbacks`, `guestReadbacks`, `cpuPixelCopies`, `resourceMemory`, `gpuUtilization`. Input counters: [input.md](input.md) §11. Store and update metrics: [package-store.md](package-store.md) §13 and [update-system.md](update-system.md) §14.

---

## 6. Redaction (NFR-SEC-05)

A report must be safe to post in a public issue. Four layers apply; each assumes the earlier ones can fail.

### 6.1 Layer 1: never collected

The bundle has no code path that reads:

- Clipboard contents; notification titles and text; IME text and key events.
- Files the user shared, dropped, imported, or saved; contents of shared folders.
- Android app data: `/data/data`, `/data/user*`, `/sdcard`, app databases and caches, `userdata.img`.
- Android accounts (`dumpsys account`), Wi-Fi configuration, keystore, lock settings. Google account data on a user-modified image falls under the account rule; APKRun ships no Google services.
- Keychain items, `~/.ssh`, browser data. Google credentials. Mac serial number, hardware UUID, provisioning UDID. Screenshots of app windows.

### 6.2 Layer 2: allowlists for structured data

Structured sources are copied field by field from an allowlist, never filtered by a blocklist.

- **getprop:** the agent and the host both keep only `ro.build.fingerprint`, `ro.build.id`, `ro.build.type`, `ro.build.version.*`, `ro.product.cpu.abilist*`, `ro.product.model`, `ro.product.device`, `ro.hardware*`, `ro.boot.hardware.*` (egl, gralloc, vulkan), `ro.opengles.version`, `ro.kernel.version`, `ro.apkrun.*`, `sys.boot_completed`, `init.svc.*`, `dalvik.vm.heap*`, `persist.sys.locale`, `debug.hwui.renderer`. `ro.serialno` and `ro.boot.serialno` are left out.
- **Configuration:** settings are copied by key ([configuration.md](../03-reference/configuration.md)). `sharedFolders.roots` becomes a count and last path components.
- **Package records:** package ID, label, version name and code, state, installer and update owner, provider type and host, signer digest truncated to 12 hex, sizes. Other provider configuration is left out.
- **Unified log entries:** cut at U+001F (§3.2).
- **Wrapper registry:** paths reduced to the last component; bookmarks removed ([wrapper.md](wrapper.md) §14).
- **Bootconfig and instance data:** `androidboot.serialno`, the instance UUID, the VM machine identifier, and the MAC address become `<serial-1>`, `<uuid-1>`, and so on, stable within one report ([android-image.md](android-image.md) §14).

### 6.3 Layer 3: structural reduction of free text

`Redactor` applies these rules to every text file (logs, console, logcat, dumpsys):

| Rule | Replacement |
|---|---|
| home directory | `~` |
| `NSUserName()`, `NSFullUserName()`, computer and local host name (`SCDynamicStoreCopyComputerName`, `SCDynamicStoreCopyLocalHostName`) | `<user>`, `<user-name>`, `<computer>` |
| paths in the home directory except `~/Library/Application Support/APKRun`, `~/Library/Logs/APKRun`, `/Applications/APKRun.app` | `~/…/<last component>` |
| URLs | `scheme://host/…`; path, query, fragment, and user info removed. APKRun's own endpoint hosts keep their path |
| e-mail addresses | `<email>` |
| IPv4 and IPv6, except loopback, link-local, and the VM's NAT subnet | `<ip>` |
| MAC addresses | `<mac>` |
| Android `content://` URIs and intent data in dumpsys | `content://<authority>/…` |

### 6.4 Layer 4: secret patterns and known secrets

Also applied to every text file:

| Pattern | Examples |
|---|---|
| `key: value` and `key=value` where the key matches `(?i)(authorization\|bearer\|token\|access_token\|refresh_token\|id_token\|api[_-]?key\|secret\|client_secret\|password\|passwd\|pwd\|cookie\|set-cookie\|session)` | HTTP headers, surviving query strings, config dumps |
| JSON Web Tokens: `eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}` | |
| Provider tokens: `gh[pousr]_[A-Za-z0-9]{36,}`, `github_pat_[A-Za-z0-9_]{50,}`, `ya29\.[0-9A-Za-z_-]+`, `AIza[0-9A-Za-z_-]{35}`, `AKIA[0-9A-Z]{16}`, `xox[abprs]-[0-9A-Za-z-]{10,}` | GitHub, Google, AWS, Slack |
| PEM private keys: `-----BEGIN [A-Z ]*PRIVATE KEY-----` … `-----END [A-Z ]*PRIVATE KEY-----` | |
| Base64 runs of 64 characters or more outside a known structured field | opaque blobs |
| **Known secrets:** exact values of APKRun's stored secrets (update provider tokens from the Keychain). `DiagnosticsService` reads them only for this check and never writes them. Matched in raw, URL-encoded, base64, and UTF-16 forms | APKRun's own secrets |

Matches become `<redacted:rule>`. The manifest records counts per rule (§8.2), never values.

### 6.5 Verification and failure

- After redaction, each file is re-scanned with the layer 4 rules. A **known secret** hit is a redaction bug: the file is dropped, `omitted` records `redactionFailed`, and the bundle is still produced. Other hits after redaction are handled the same way.
- `RedactionRules.version` goes into the manifest; changing a rule increases it.
- Local logs are never redacted. Redaction happens only when a report is built ([vm.md](vm.md) §6.4).

---

## 7. Health model and `apkrun doctor` (FR-OPS-01, NFR-OBS-02, NFR-OBS-03)

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
    var fix: HealthFix? { get }                     // safe automatic fix, if any (§7.5)
    var title: LocalizedText { get }
    func run(_ context: HealthContext) async -> HealthResult
}
public struct HealthResult: Sendable, Codable {
    public var id: HealthCheckID
    public var group: HealthGroup
    public var state: HealthState
    public var title: LocalizedText                 // "Boot completed"
    public var detail: String?                      // public-safe: "31 s"
    public var error: ErrorInfo?                    // code, message, remediation, action (§2)
    public var fixAvailable: Bool
    public var lastKnown: LastKnown?                // skipped checks: last result and time
    public var measuredAt: Date
}
public struct HealthReport: Sendable, Codable {
    public var generatedAt: Date
    public var build: BuildInfo
    public var imageVersion: String?
    public var runtimeRunning: Bool
    public var verdict: HealthVerdict               // §7.2
    public var results: [HealthResult]              // by group, then registration order
}
```

- apkrund's `HealthCheckRegistry` is filled at startup by RuntimeHost with every module's checks. The CLI and APKRun.app register only host checks (§7.3).
- `HealthResult.error` is empty for `pass`, `info`, and `skipped`. A `warning` or `failure` carries it when there is a next step. Check entries are in [error-catalog.md](../03-reference/error-catalog.md) §20.2.
- Budgets: a quick check finishes in 2 s, a deep check in 60 s, both including the wait for a slot. A timed-out check returns `warning` with `detail = "check timed out"` and no `error`. At most 8 checks run at once. Guest checks share one `Health` round trip where possible ([guest-protocol.md](guest-protocol.md) §7.4).
- Checks with `requirement == .runningRuntime` never start Android. While it is stopped they return `skipped` with "Android is not running" and `lastKnown`. Troubleshooting and `apkrun doctor` never start Android ([host-ui.md](host-ui.md) §1).
- Checks with `cost == .deep` are `skipped` unless `--deep`. `.daemon` and `.runningRuntime` checks are skipped when apkrund is unavailable; host checks and `apkrund.registration` still run. Skipped results have no `error`.
- `HealthCheckRegistry.run(deep:context:)` keeps registration order within a group and sorts groups by `HealthGroup.allCases`. IDs are unique. Caller cancellation returns an empty result. A timed-out check is cancelled; one that ignores cancellation keeps its slot until it exits.
- `HealthContext` provides daemon and runtime availability, prior results, `BuildInfo`, `APKRunPaths`, a clock, and a `HostProbe`. All host reads, process calls, and Security and ServiceManagement calls go through the probe.
- Verdict input: runtime state (`stopped`, `ready`, `suspended`, `failed`, `other`), provisioning completion, the boot-loop guard, and the last boot error code. `other` with no higher finding gives `degraded`, never "healthy".
- **Live checks** (no polling) publish `healthChanged(HealthResult)` on the `health` topic ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.4): `runtime.state`, `runtime.boot`, `agent.*`, `vm.network`, `graphics.renderer`, `graphics.memory`, `runtime.memoryPressure`, `store.packages`, `store.hostSpace`, `wrappers.status`. While one is `warning` or `failure`, the window header and menu bar show "Needs attention" ([host-ui.md](host-ui.md) §5, §12).

### 7.2 Verdict (FR-OPS-01)

The first row that applies wins:

| Verdict | Condition | Status line |
|---|---|---|
| `hostUnsupported` | a `host.*` check or `vm.virtualizationSupported` fails | "APKRun can't run on this Mac" |
| `serviceUnavailable` | `apkrund.registration` or `apkrund.reachable` fails | "Background service not running" |
| `notSetUp` | `runtime.provisioning` incomplete, or `image.current` fails | "Setup not finished" |
| `graphicsFailure` | `graphics.renderer` fails (initialization failed, or lost in the current or last boot), or the last boot failed with a `GraphicsFailure` | "Graphics failed to start" |
| `bootFailure` | `runtime.state` is `failed`; or `runtime.boot` fails (last boot failed, none succeeded since); or the boot-loop guard is set | "Android failed to start" plus the boot phase |
| `agentUnavailable` | Android `ready` and `agent.guest` or `agent.store` fails | "Guest Agent unavailable" / "Store Agent unavailable" |
| `degraded` | any other failure or warning | "Needs attention (‹n› warnings)" |
| `stopped` | no failures or warnings; Android stopped | "Healthy · Android is not running" |
| `healthy` | no failures or warnings; Android `ready` or `suspended` | "Healthy" |

- `graphicsFailure` precedes `bootFailure`: a renderer failure also fails the boot, and the graphics remediation is better ("Start in Graphics Safe Mode", [graphics.md](graphics.md) §9).
- `degraded` with Android stopped adds "· Android is not running". With only failures left, the line says "Needs attention".
- For `bootFailure`, `runtime.boot.detail` is appended only when that row is a failure.
- CLI exit codes ([cli.md](cli.md) §3.3): `healthy`, `stopped` → 0; `degraded` without failures → 3; otherwise → 1.

### 7.3 Host checks

These need neither apkrund nor RuntimeHost. The CLI and APKRun.app run them directly when apkrund is unreachable ([cli.md](cli.md) §4.8). `HostRequirementsCheck` builds on them for provisioning ([runtime-daemon.md](runtime-daemon.md) §9.1).

| Check | Group | Pass condition | Remediation on failure |
|---|---|---|---|
| `host.appleSilicon` | host | `sysctl hw.optional.arm64 == 1` and `sysctl.proc_translated == 0` | "APKRun needs a Mac with Apple silicon" |
| `host.macOSVersion` | host | macOS 27 or later | "Update macOS" |
| `host.hypervisor` | virtualization | `sysctl kern.hv_support == 1`. apkrund also checks `VZVirtualMachine.isSupported` as `vm.virtualizationSupported` | "Virtualization is not available on this Mac (APKRun can't run inside a virtual machine)" |
| `host.appLocation` | host | in `/Applications` or `~/Applications`, not translocated | "Move APKRun to the Applications folder" |
| `host.appSignature` (deep) | host | `SecStaticCodeCheckValidity` of APKRun.app with its designated requirement, nested code included | "Reinstall APKRun" |
| `host.componentVersions` | host | apkrund, CLI, and launcher builds equal APKRun.app's. Read from embedded signing metadata, without running executables | "Reinstall APKRun" |
| `host.dataVolume` | host | data root on APFS with ≥ 10 GiB free (warning below) | "Free up space" / "Move APKRun's data to an APFS volume" |
| `host.memory` | host | physical memory ≥ 8 GiB (warning below) | "APKRun works best with 16 GB or more" |
| `apkrund.registration` | backgroundService | APKRun.app: `SMAppService.status == .enabled`. CLI: `launchctl print gui/<uid>/<label>` succeeds (`<label>` from `BuildInfo`) | `requiresApproval`: "Allow APKRun in System Settings → General → Login Items & Extensions" (`openLoginItemsSettings`). Not registered: "Open APKRun to finish setup" |
| `apkrund.reachable` | backgroundService | broker `hello` answers within 5 s with the same API major | "Restart the background service" |
| `apkrund.version` | backgroundService | apkrund build equals the client build | `restartPending`: "An APKRun update is waiting for your Android apps to close. Close them, or choose Restart Now." Otherwise "Quit and reopen APKRun" ([runtime-maintenance.md](runtime-maintenance.md) §3.6) |
| `apkrund.crashLoop` | backgroundService | fewer than 3 unclean exits in 10 minutes ([runtime-daemon.md](runtime-daemon.md) §2.5). Without apkrund: counted from `~/Library/Logs/DiagnosticReports/apkrund-*.ips` | "Create a diagnostics report and report the problem" |

- Errors: `host.appleSilicon`, `host.macOSVersion`, `host.hypervisor`, and `host.dataVolume` (on non-APFS) give `runtime.hostRequirementsNotMet` with one item each. `apkrund.registration` and `apkrund.reachable` give `runtime.serviceUnavailable`. The others give a `DiagnosticsFailure` (§2.1).
- Without apkrund, every non-host check except `apkrund.registration` is `skipped` with "Background service not running". The failed `apkrund.registration` or `apkrund.reachable` row carries the service remediation.

### 7.4 Check catalogue

Owner modules implement their checks with their feature's task ([issues/README.md](../04-plan/issues/README.md) §3). The health model, verdict function, `HostChecks`, and `apkrund.registration` come with #061. The report plumbing, output, host-only mode, and the other `apkrund.*` checks come with #059.

| Group (doctor heading) | Checks | Defined in |
|---|---|---|
| Host | `host.appleSilicon`, `host.macOSVersion`, `host.appLocation`, `host.appSignature`, `host.componentVersions`, `host.dataVolume`, `host.memory` | §7.3 |
| Background Service | `apkrund.registration`, `apkrund.reachable`, `apkrund.version`, `apkrund.crashLoop` | §7.3 |
| Virtualization | `host.hypervisor`, `vm.virtualizationSupported`, `vm.state`, `vm.network`, `vm.consoleWriter` | [vm.md](vm.md) |
| Android | `runtime.provisioning`, `image.current`, `image.instance`, `image.kind`, `image.migration`, `image.recoveryPoint`, `image.freeSpace`, `runtime.state`, `runtime.boot`, `runtime.stop`, `runtime.memoryPressure` | [runtime-daemon.md](runtime-daemon.md) §12, [android-image.md](android-image.md) §14.3 |
| Graphics | `graphics.device`, `graphics.renderer`, `graphics.guestDriver` (deep), `graphics.present`, `graphics.memory`, `graphics.safeMode` | below, [graphics.md](graphics.md) |
| Guest | `agent.guest`, `agent.store`, `agent.input`, `agent.ime`, `agent.developerMode` | below, [input.md](input.md) §11 |
| Store | `store.journal`, `store.pending`, `store.ownership`, `store.externallyUpdated`, `store.hostSpace`, `store.packages` | [package-store.md](package-store.md) §13 |
| Updates | `updates.scheduler`, `updates.providers`, `updates.waiting`, `updates.failed` | [update-system.md](update-system.md) §14 |
| Mac Apps | `wrappers.template`, `wrappers.registry`, `wrappers.status`, `wrappers.launcher`, `wrappers.registration` | [wrapper.md](wrapper.md) §14 |
| Integrations | `integrations.capabilities`, `integrations.notificationListener`, `integrations.browserRole`, `integrations.sharedFolders`, `integrations.microphone`, `integrations.time` | [desktop-integration.md](desktop-integration.md) §13 |
| APKRun Updates | `maintenance.selfUpdate`, `maintenance.imageUpdate` | [runtime-maintenance.md](runtime-maintenance.md) §12 |

Checks defined here:

| Check | Requirement | Pass | Warning | Failure |
|---|---|---|---|---|
| `graphics.device` | runningRuntime | virtio-gpu attached with the expected features and scanout count for the GPU profile ([graphics.md](graphics.md) §4.1, §9) | — | missing or negotiation failed: `graphics.deviceSetupFailed` |
| `graphics.renderer` | daemon (last known) / runningRuntime | virglrenderer and ANGLE (Metal) initialized; detail shows versions and Metal device name | one `rendererLost`, recovered by restart in 24 h | `rendererInitFailed`, or `rendererLost` twice in 24 h. Remediation `startGraphicsSafeMode` |
| `graphics.guestDriver` (deep) | runningRuntime | `DUMPSYS_SURFACEFLINGER` GLES renderer contains `virgl` (profile `drmVirgl`) | — | other renderer on `drmVirgl`: `graphics.softwareRendering` |
| `graphics.present` | runningRuntime | `hostReadbacks == 0`, and on `drmVirgl` `cpuPixelCopies == 0`, since boot (NFR-PERF-05) | either non-zero (regression): `graphics.presentationSlowPath` | — |
| `graphics.memory` | runningRuntime | below the limits of [graphics.md](graphics.md) §5.4 | limit reached: `graphics.memoryLimitReached` | — |
| `graphics.safeMode` | daemon | safe mode off | on: `graphics.safeModeOn` ("Graphics safe mode is on. Apps are slower.") | — |
| `agent.input` | runningRuntime | input stream connected | `disconnected` ([input.md](input.md) §11), or `input.dropped.invalid` above 0.1 % of events since boot: `runtime.inputDegraded` | — |
| `agent.ime` | runningRuntime | APKRun input method selected (`Health.ime_selected`) | not selected (fixable, §7.5): `runtime.inputMethodNotSelected` | — |
| `agent.developerMode` | runningRuntime | `Health.adb_enabled` matches `developer.enabled` | ADB on: `info` "Developer mode: ADB on 127.0.0.1:6520" | ADB on while developer mode off ([security-model.md](../01-architecture/security-model.md)): `runtime.adbEnabledUnexpectedly` |

### 7.5 Fixes (`--fix`)

A fix must be idempotent, lose no data, change no user choice, and not restart Android in a way that closes windows.

| Check | Fix |
|---|---|
| `wrappers.registration` | re-register the wrapper with LaunchServices (`LSRegisterURL`) |
| `agent.ime` | ask the Guest Agent to select the APKRun input method again |
| `integrations.notificationListener`, `integrations.browserRole` | ask the Guest Agent to restore the grant or role ([desktop-integration.md](desktop-integration.md)) |
| `apkrund.registration` | CLI: `open -a APKRun --args --register-runtime` after confirmation ([cli.md](cli.md) §4.1). APKRun.app: `SMAppService.register()` |
| `apkrund.version` | `launchctl kickstart -k gui/<uid>/io.apkrun.apkrund`, only while Android is stopped. Otherwise not offered; the remediation says to stop Android first |

`apkrun doctor --fix` runs the fixes of every `warning` or `failure` check that has one, prints "Fixed: ‹title›" or the error, and runs the whole report again. APKRun.app shows **Fix** on those rows.

### 7.6 Control endpoint operations

| Operation | Result | Notes |
|---|---|---|
| `healthReport(HealthRequest{ deep, checks? })` | `WireHealthReport` | `checks` limits the run (**Run Again** on one row) |
| `applyHealthFixes(HealthFixRequest{ checks })` | `WireHealthReport` | fixes, then a full report |
| `createDiagnostics(DiagnosticsRequest)` | `OperationHandle` → `DiagnosticsResult` | §8.1 |
| `perfStatistics(PerfStatisticsRequest{ reset })` | `WirePerfStatistics` | §9.3 |
| `guestLog(GuestLogRequest{ follow })` | stream of `GuestLogChunk` | §3.5. Developer mode only, else `runtime.developerModeRequired`. Never starts Android |

These are on the control endpoint only, not on wrapper endpoints ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2). A wrapper's **Report a Problem…** opens APKRun.app (§8.5).

### 7.7 Output

`apkrun doctor [--deep] [--fix] [--json]` prints a heading per group, one line per check, and the status last. Passing rows show title and detail; other rows add an indented remediation. `--deep` adds a **Metrics** block (§5).

- Symbols: ✓ pass, ℹ info, ⚠ warning, ✕ failure, – skipped (with reason). Color only on a TTY without `NO_COLOR` ([cli.md](cli.md) §3.2).
- The Troubleshooting list of APKRun.app collapses groups whose checks all pass to one line. The CLI prints every line.
- `--json`: `{ "schemaVersion": 1, "result": <WireHealthReport> }` with stable IDs, states, and error codes. Titles are in the user's language.

---

## 8. Diagnostics bundle (FR-OPS-02)

### 8.1 Flow

1. The client picks the destination. `apkrun diagnostics` uses `--output`, or `~/Desktop/APKRun-Diagnostics-<yyyyMMdd-HHmmss>.zip` ([cli.md](cli.md) §4.8). APKRun.app shows a Save panel with that name (§8.5).
2. The client passes the output's `FileHandle` in `DiagnosticsRequest{ output, includeLogcat, deep, focusPackage? }`. apkrund never opens a user-chosen path.
3. `DiagnosticsService` creates a staging directory in `$TMPDIR` (mode 0700) and runs the contributors (§8.2) concurrently, each within its budget. It runs `Redactor` (§6), writes `summary.txt` and `manifest.json`, streams the ZIP into the handle with `ZipWriter` (deflate through Compression.framework), and deletes the staging directory. The ZIP is mode 0600.
4. Progress stages: `collecting`, `redacting`, `writing`. On cancel, apkrund truncates the output to 0 bytes; the client deletes the file ([runtime-api.md](../03-reference/runtime-api.md) §4.7).
5. The result has the summary, size, and omitted items. The CLI prints the path and summary; APKRun.app shows **Show in Finder**.

- **Always a result (FR-OPS-02).** A contributor that fails or overruns goes to `omitted`. The bundle is produced in `failed` state, after a boot failure, with the Guest Agent down, and with no image.
- Budgets: 10 s per host contributor; 60 s for the guest items together ([guest-protocol.md](guest-protocol.md) §6); 45 s for `log show`. Healthy runtime: p95 ≤ 60 s. Size ≤ 100 MiB compressed.
- Nothing is uploaded. The user attaches the file to a bug report ([workflow.md](../05-development/workflow.md)).

### 8.2 Contents

```text
APKRun-Diagnostics-20260928-101502/
├── summary.txt                     human-readable summary (§8.3)
├── manifest.json                   format, options, file list, omitted items, redaction counts
├── host/
│   ├── environment.json            Mac model, chip, memory, macOS version and build, displays, locale, data volume
│   ├── versions.json               BuildInfo of APKRun.app, apkrund, CLI, launcher template; image and agent versions
│   ├── health.json, health.txt     HealthReport (deep when requested) and its doctor rendering
│   ├── config.json                 global settings (allowlisted keys)
│   ├── metrics.json                MetricsSnapshot (§5)
│   ├── logs/unified.ndjson         APKRun subsystems, last 24 h, newest 30 MiB (or mirrors/ when log show failed)
│   ├── logs/mirrors/               apkrund.log*
│   ├── crash-reports/              .ips of apkrund, APKRun, APKRunMenuBar, apkrun, APKRunLauncher; last 7 days, at most 20
│   └── perf/                       launches.jsonl, boots.jsonl (newest 500 / 50)
├── runtime/
│   ├── status.json                 RuntimeStatus, agent states, sessions, display pool (as `apkrun info --displays`)
│   ├── daemon.json                 apkrund run record: clean-exit flag, unclean exits, boot history
│   ├── boot-phases.json            BootPhaseDetector events of the last 5 boots
│   ├── console/                    boot-<ts>.log of the last 5 boots; last 8 MiB of console.log
│   ├── crash/                      last 3 failure snapshots (§3.3)
│   ├── graphics.json               GPU profile, Metal device name and family, virglrenderer and ANGLE versions, statistics
│   ├── input.json                  input counters
│   └── image/                      image store state, manifest summary, bootconfig and cmdline (placeholders), migration state
├── guest/                          only when the Guest Agent answered, or from a logcat capture file
│   ├── getprop.txt                 allowlisted properties (§6.2)
│   ├── logcat.txt                  filtered (§8.3), or full with --include-logcat
│   ├── dumpsys-{window,display,input,activity,surfaceflinger,meminfo}.txt
│   ├── tombstones.txt              list only: time, process name, signal
│   └── agent.log, store.log
├── packages/
│   ├── packages.json               allowlisted package records (§6.2)
│   ├── settings.json               per-package settings (allowlisted keys)
│   ├── journal-tail.jsonl          last 500 store journal entries (paths reduced)
│   └── updates.json                update phase, last result, last 10 history entries per package
├── wrappers/registry.json          paths reduced to the last component, bookmarks removed
├── integrations/status.json        capabilities, enabled integrations per package (booleans), shared folder count
└── maintenance/state.json          HostState, SelfUpdateStatus, host-update marker, Images/update-state.json (runtime-maintenance.md §12)
```

- Each section comes from a `DiagnosticsContributor` owned by the module that knows the data:

  ```swift
  public protocol DiagnosticsContributor: Sendable {
      var name: String { get }                         // "store", "graphics"
      var budget: Duration { get }
      func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws
  }
  ```

- Owners: RuntimeCore `runtime/` and `guest/`; GraphicsCore `runtime/graphics.json`; InputCore `runtime/input.json`; ImageCore `runtime/image/`; APKStoreCore `packages/`; UpdateCore `packages/updates.json`; WrapperCore `wrappers/`; IntegrationCore `integrations/`; RuntimeHost `maintenance/`; RuntimeHost and DiagnosticsCore `host/`.
- `DiagnosticsBundleBuilder` accepts only files under the bundle tree, only text or JSON, and runs every file through the redactor. The one exception is `.ips` crash reports, which are JSON text.
- `focusPackage` (CLI `--package <id>`; GUI: the package picked in **Report a Problem…**) adds that package's full update history and its last 20 launch records, and lists its issues first in the summary. It adds no app data.
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

- The report ID is random and not linked to the Mac or the user.

### 8.3 Guest data, summary, and boot failures

- **Android running, Guest Agent connected:** `CollectDiagnostics` (operation 73, capability `diagnostics.v1`, [guest-protocol.md](guest-protocol.md) §7.1) with items `GETPROP`, `LOGCAT`, `DUMPSYS_WINDOW`, `DUMPSYS_DISPLAY`, `DUMPSYS_INPUT`, `DUMPSYS_ACTIVITY`, `DUMPSYS_SURFACEFLINGER`, `DUMPSYS_MEMINFO`, `TOMBSTONE_LIST`, `AGENT_LOG`; `max_bytes` 16 MiB per item. The agent omits non-allowlisted properties; the host applies §6 regardless.
- **Logcat filter (default):** the agent runs `logcat -d -b main,system,crash -v threadtime,uid,UTC,year`. The host keeps system-UID entries (UID below 10000) and APKRun-tagged entries. From app UIDs it keeps only a fatal exception's crash-buffer lines: `FATAL EXCEPTION`, `Process:`, the exception line, and stack frames. Other app lines are dropped. `--include-logcat` (GUI: "Include Android app logs") keeps everything, still redacted; the sheet warns about app information.
- **Android failed or stopped:** console logs of the last 5 boots, boot phases, and failure snapshots ([runtime-daemon.md](runtime-daemon.md) §3.6). Their `logcat -d` part goes through the same filter.
- **Failed boot:** when `daemon.json` records a failed last boot, RuntimeCore attaches the logcat console (`hvc2`) as `.log("logcat")` for the next boot and writes `guest/logcat-<timestamp>.log` ([android-image.md](android-image.md) §7.1). Developer mode captures on every boot.
- APKRun never starts Android to build a report. The summary says when guest data is missing and why.

`summary.txt` is in English, for maintainers. Its parts, in order: title (creation time, report ID, operation ID); status line with remediation; build line (APKRun, apkrund, CLI, launcher, image, agents); health rows that are not `pass`; recent problems; apps line; privacy line. Example:

```text
APKRun Diagnostics Report
Created 2026-09-28 10:15:02 +0900 · Report 7c1e0f7a · operation 3f9a1c2e

Status: Android failed to start
  The last start stopped at "system services" after 180 s (runtime.bootTimedOut).
  Suggested: Start in Graphics Safe Mode (Settings → Troubleshooting).

Health: 1 failure, 2 warnings (see host/health.txt)
  ✕ runtime.boot           last boot failed: timeout at systemServer
  ⚠ graphics.renderer      renderer lost once in the last 24 h

Recent problems (last 7 days, from logs)
  2026-09-28 10:02  runtime.bootTimedOut                 op 91ab22c0

Privacy
  Not collected: clipboard, notification text, your files, app data, accounts, passwords, Keychain items.
  Removed: 118 paths, 40 URLs, 2 tokens, 1 e-mail address, 9 user or computer names, 3 IP addresses.
  Omitted: guest logs (Android was not running).
```

"Recent problems" are the `error`-level entries (their `err=` fields) in the collected logs. The apps line comes from the package store and `launches.jsonl`.

### 8.4 Host-only bundle

When apkrund is unreachable, the CLI ([cli.md](cli.md) §4.8) and APKRun.app build the bundle with DiagnosticsCore: `mode: "hostOnly"`, `createdBy: "cli"` or `"app"`.

- Included: `host/` (environment; versions from Info.plist files; §7.3 host checks; `launchctl print gui/<uid>/io.apkrun.apkrund`; `log show`; mirrors; crash reports; perf records; allowlisted `settings.json`), `runtime/daemon.json`, `runtime/console/`, `runtime/crash/`, and `packages/packages.json`, read from `Packages/*/metadata.json` with the same allowlist. Read-only: only apkrund writes under `Packages/`.
- Not included: live status, guest data, statistics, and the wrapper registry. Its file name goes to `omitted`, because reducing it needs WrapperCore.

### 8.5 GUI flow

1. Settings → Troubleshooting → **Create Diagnostics Report…**, a failed step's **Report…** in onboarding, the launcher's **Report a Problem…** (Help menu and error screens), or `apkrun://report?package=<id>` opens the report sheet. The URL only opens the sheet; creating the report needs a click ([host-ui.md](host-ui.md) §3.1).
2. The sheet lists what is included and never collected (§6.1). It offers **Include Android app logs** (off by default) and the focus package (preselected from a wrapper), and has **Create Report…**.
3. The Save panel suggests `~/Desktop/APKRun-Diagnostics-<timestamp>.zip`. Progress shows in the sheet, with **Cancel**.
4. When done: **Show in Finder**, **Copy Summary** (the text of `summary.txt`), and a link to the project's issue page.

---

## 9. Performance harness

### 9.1 Goals

- Measure NFR-PERF targets repeatably and track them over time.
- Split every launch and boot into the marker segments of §4, so a regression points to one step ([display-and-windowing.md](display-and-windowing.md) §9).
- Run nightly on a lab Mac and on demand on a developer Mac. Not in per-PR CI: it needs Virtualization.framework, a GPU, and minutes of runtime.

### 9.2 The tool

`apkrun-perf` is a Swift executable in `Tests/PerformanceTests/`. It links RuntimeClient and DiagnosticsCore only, and drives the product like a user (CLI, `NSWorkspace`, synthesized events).

```text
swift run apkrun-perf <scenario> [--runs <n>] [--warmup <n>] [--output <dir>] [--baseline <file>]
scenarios: warm-launch, suspended-launch, cold-launch, input-latency, hellogl-fps, idle-cpu,
           update-check-launch, boot-phases, memory, all
```

- Preconditions, checked before every run and recorded in the results: AC power; Low Power Mode off; `ProcessInfo.thermalState == .nominal`; display awake (`caffeinate -d`); no other virtual machines; APKRun Release configuration; fixture apps from `Tests/Fixtures/AndroidApps` installed, with Mac apps generated by `apkrun wrap <package> --output <dir>` into a temporary folder. A failed precondition stops the run with a message and no numbers.
- Staging: until `apkrun wrap` exists (#075), launch scenarios open the generic launcher (`APKRunLauncher.app --package <id>`, #068) through `NSWorkspace`. `results.json` records the path (`launcher` or `wrapper`); the two paths' numbers are never compared. `update-check-launch` needs #037 and #074; until both exist it is `skipped` with that reason.
- `input-latency` synthesizes events with `CGEvent.postToPid`, which needs the harness's Accessibility permission on the lab Mac ([environment-setup.md](../05-development/environment-setup.md)).

### 9.3 Scenarios

| Scenario | Procedure | Measure | Target |
|---|---|---|---|
| `warm-launch` | Android `ready`. Each run: `apkrun stop <package>`, wait 2 s, open HelloText's Mac app with `NSWorkspace.openApplication`, wait for its `launches.jsonl` record, close the window. 3 warm-ups, 30 runs | `t0` (the `openApplication` call) → `FIRST_FRAME_DISPLAYED`, per segment | NFR-PERF-01: p50 ≤ 1.5 s, p95 ≤ 3 s |
| `suspended-launch` | as above, after `VM_PAUSED` (`runtime.idleSuspendMinutes` = 1) | the same, plus `VM_RESUMED` → `ready` | NFR-PERF-01 + 0.5 s; resume p50 ≤ 500 ms ([runtime-daemon.md](runtime-daemon.md) §5) |
| `cold-launch` | `apkrun runtime stop`, then open HelloText. 10 runs | `t0` → `FIRST_FRAME_DISPLAYED`; boot phases from `boots.jsonl` | NFR-PERF-02: p50 ≤ 40 s |
| `input-latency` | HelloText in front; 1,000 clicks and 1,000 key presses at 20 Hz | `input.translate`, `input.route` (`perfStatistics`); `receive_to_inject` from `InputAck` ([input.md](input.md) §8) | NFR-PERF-03: p95 ≤ 16 ms |
| `hellogl-fps` | HelloGL in a 1080 × 2400 window, 60 s after 5 s warm-up | `fps` (10 s averages), `droppedFrames`, `hostReadbacks`, `cpuPixelCopies`, `presentGPUTime` | NFR-PERF-04: ≥ 55 fps; NFR-PERF-05: readbacks 0 |
| `idle-cpu` | no app; wait for `VM_PAUSED`; apkrund CPU time (`proc_pid_rusage`) at start and after 300 s | CPU time ÷ wall time | NFR-PERF-06: < 1 % |
| `update-check-launch` | `update-repos` fixture answers after 5 s; check 10 packages (`apkrun update --check-only`); `warm-launch` 30 times meanwhile | launch p50 and p95 against `warm-launch` of the same session | NFR-PERF-07: p50 difference ≤ 50 ms; no launch waits on a check |
| `boot-phases` | 10 cold boots without an app (`apkrun runtime start`) | each boot segment of §4.3 | tracked against baseline |
| `memory` | after `warm-launch`, `MetricsSnapshot` with `DUMPSYS_MEMINFO` | §5 memory metrics | tracked only; no v1 target |

`perfStatistics(reset:)` (§7.6) returns host-side values the harness cannot see: input histograms, per-session graphics statistics, and marker durations. `reset: true` clears them at a scenario's start.

### 9.4 Results and regressions

- Output: `<output>/<timestamp>-<build>/results.json` (every sample, preconditions, Mac model, macOS and APKRun builds, image version) and `summary.md` (per scenario: p50, p95, target, baseline).
- Baselines: `Tests/PerformanceTests/baselines/<model identifier>.json`, changed only by a reviewed pull request that states why.
- A nightly run fails when an NFR target is missed, or a p50 is more than 15 % worse than baseline (10 % for `hellogl-fps`, where lower is worse). The failure names the segment that grew most.
- Reference Mac: the lowest-tier lab Mac, M1 with 16 GB ([open-questions.md](../04-plan/open-questions.md) OQ-02).

---

## 10. Compatibility database (FR-OPS-06)

### 10.1 Purpose and rules

The database records how well known apps work on APKRun and which settings help. It uses the levels of [scope.md](../00-product/scope.md) §4.

- It ships in APKRun.app (`Contents/Resources/compatibility.json`) and changes only with APKRun updates. APKRun never downloads it, and nothing is sent about installed apps. The code signature covers it.
- It is advice and never blocks an install. Blocking conditions stay in [package-store.md](package-store.md) §4.6.
- Owner: APKStoreCore (`CompatibilityDatabase`). apkrund loads it from `Contents/Helpers/apkrund` → `Contents/Resources/`.

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

- `signerDigests` (optional): the entry applies only to builds signed by these certificates.
- `versionCodes` (optional, inclusive, `null` = open): when several entries match, the narrowest range wins.
- `recommendedSettings` may use only per-package keys ([package-metadata-json.md](../03-reference/package-metadata-json.md)): `window.*`, `input.*`, `integrations.*` (only to turn an integration off), `update.healthCheckLaunch`. A schema test rejects other keys.
- `source`: `lab` (§10.4) or `report` (a user report a maintainer reproduced).
- Schema: `Tests/Compatibility/compatibility.schema.json`. CI validates the database against it.

### 10.3 Use in the product

- **Setting resolution:** `PackageSettingsResolver` applies [configuration.md](../03-reference/configuration.md) §3.2 per key. A global integration switch set to off (`integrations.enabled.<name> = false`) wins. Then the stored package value, the database recommendation for the installed version, and the built-in default. A recommendation never turns on an integration that is off globally. Recommendations are not copied into `settings.json`, so a corrected entry takes effect with the APKRun update, and **Reset** returns to the recommendation. Values copied at the first record (`wrapper.json`, `integrations.defaults.*`) that equal the default are not written ([configuration.md](../03-reference/configuration.md) §3.3). Settings marks database values "Recommended for this app" ([host-ui.md](host-ui.md) §7).
- **Display:** the add-flow review shows the label (Works / Works with limitations / Unsupported) and issues ([host-ui.md](host-ui.md) §6); the app page shows them under General. `apkrun inspect` and `apkrun info <package>` include a `compatibility` field. No entry shows nothing.
- `unsupported` apps can still be installed. The review says why, and the button becomes **Install Anyway**.
- RuntimeAPI carries `CompatibilityInfo{ level, label, issues, recommendedKeys }` ([runtime-api.md](../03-reference/runtime-api.md)).

### 10.4 Maintaining the data

- `Tests/Compatibility/apps.json` lists the run's apps: fixture apps, the 50-APK F-Droid corpus ([package-store.md](package-store.md) §16), and popular apps that maintainers install by hand.
- A run (nightly for the corpus, before each release for the full list) installs each app and launches it in standard window mode. It requires a non-blank first frame within 20 s, runs a 60 s `monkey` smoke test with a fixed seed through ADB in developer mode, and checks the integrations the app uses. If standard mode fails, it repeats in compatibility window mode. Output: a proposed level and issues per app.
- A proposal enters `Tests/Compatibility/database/compatibility.json` only after a maintainer checks it. The build copies that file into APKRun.app.
- Users report apps with the "App compatibility" issue template ([workflow.md](../05-development/workflow.md)). A report becomes an entry only after a maintainer reproduces it.

---

## 12. Tests

Test IDs are stable names that task entries cite. Tiers follow [test-strategy.md](../04-plan/test-strategy.md) §2.

| ID | Tier | What is tested |
|---|---|---|
| T1-1 | T0 | `LogMessage`: each privacy mode renders the expected texts; U+001F only with private values; structured fields from `OperationContext` |
| T1-2 | T1 | compile-fail (a `swift build` of small fixture files in CI): interpolation without privacy, and of a `Sensitive` value, do not compile |
| T1-3 | T1 | `LogMirrorWriter`: rotation at 10 MiB; drop counting when full; mode 0600; no private values in the file |
| T1-4 | T0 | catalog: every domain case has an entry; `en` and `ja` in release builds (#092); placeholders declared; no code equals a health check ID; `cliExit` valid and equal to `CLI/apkrun/Support/ExitCodes.swift`; `errorgen` output current |
| T1-5 | T0 | `ErrorPresenter`: three-line CLI format; JSON with `cause`; Copy Details without paths |
| T1-6 | T0 | verdict (§7.2) for every combination, including `graphicsFailure` before `bootFailure` and the stopped suffix |
| T1-7 | T0 | `Redactor`: each rule of §6.2–§6.4; stable placeholders; known secrets in raw, URL-encoded, base64, UTF-16; verification drops a file that holds a known secret |
| T1-8 | T0 | logcat filter: system UID lines kept; app UID lines dropped; app fatal-exception lines kept; `--include-logcat` keeps all |
| T1-9 | T0 | `PerfRecordWriter`: record format, relative times, retention rewrite, `launchState` classes |
| T1-10 | T0 | `CompatibilityDatabase`: signer, version range, narrowest range; resolution order |
| T2-1 | T1 | host-only doctor and bundle with apkrund unregistered. Run as a separate macOS test account: `APKRUN_HOME` relocation does not work, because commands other than `apkrun dev` ignore it ([cli.md](cli.md) §3.6) |
| T2-2 | T1 | `apkrun logs` with and without `log show` access |
| T2-3 | T2 | the `OperationID` of `apkrun install` appears in CLI, apkrund, and Store Agent logs |
| T2-4 | T2 | FR-OPS-01: (a) runtime stopped → `stopped`; (b) `androidboot.apkrun.test.fail_boot=1` → `bootFailure` with the phase; (c) `APKRUN_GRAPHICS_FAULT=rendererInit` → `graphicsFailure`; (d) `APKRUN_RUNTIME_FAULT=rejectAgent:guest` → `agentUnavailable`; (e) healthy → `healthy`. Fault hooks are compiled into debug builds only, like `APKRUN_STORE_FAULT` ([package-store.md](package-store.md) §16) |
| T2-5 | T2 | bundle while healthy, after (b), with the Guest Agent unavailable (d), and without apkrund: each expected file or `omitted` reason present; ZIP opens with `ditto -x -k` |
| T2-6 | T2 | **secret fixture test** (#060): secrets `APKRUN-FIXTURE-SECRET-<n>` planted in a provider token, URL query, `.private` log argument, console (`/dev/kmsg` from test bundle S, [test-strategy.md](../04-plan/test-strategy.md) §3.5), app logcat and clipboard and notification (HelloClipboard, HelloNotification), shared-folder file name, wrapper path, Mac user name, and getprop `persist.apkrun.test.secret`. None may appear in the unzipped bundle, in raw, URL-encoded, base64, or UTF-16 form, with or without `--include-logcat` |
| T2-7 | T2 | `--fix` for `wrappers.registration` and `agent.ime` |
| T3-1 | T3 | performance scenarios of §9.3 on the reference Mac (NFR-PERF-01…07) |
| T3-2 | T3 | doctor and bundle from the Troubleshooting pane, including **Report a Problem…** from a wrapper |

Where the tests live: T0 in each module's `Packages/<Module>/Tests/`; T1 and T2 in `Tests/IntegrationTests/`; the harness in `Tests/PerformanceTests/`; compatibility schema tests in `Tests/Compatibility/`.

---

## 13. Open items

- [OQ-02](../04-plan/open-questions.md): reference Mac for NFR numbers. Working default: the lowest-tier lab Mac, M1 with 16 GB (§9.4).
- [OQ-03](../04-plan/open-questions.md): package IDs in bundles. Working default: included, and the sheet says so (§8.5).
- [OQ-04](../04-plan/open-questions.md): `log show` for non-admin users. Working default: file mirrors (§3.3) cover the gap either way.
- [OQ-05](../04-plan/open-questions.md): whether `logcat -v uid` prints the UID on the Android 17 image. Fallback: a PID → UID map from `ps -A -o PID,UID` (§8.3).
- [OQ-06](../04-plan/open-questions.md): identifying the Virtualization.framework XPC process (§5). Working default: match by process name, user, and start time right after `VM_START`; otherwise report the VM footprint as unavailable.
- [OQ-07](../04-plan/open-questions.md): `gpuUtilization` from IOKit accelerator statistics, not a documented API. Working default: best effort; unavailable when the key is missing (§5).
