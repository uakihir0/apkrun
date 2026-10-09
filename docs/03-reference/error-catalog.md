# Error catalog

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../02-design/diagnostics.md](../02-design/diagnostics.md) §2, §7, [../02-design/cli.md](../02-design/cli.md) §3.3, [../02-design/host-ui.md](../02-design/host-ui.md) §1, §13, [../02-design/wrapper.md](../02-design/wrapper.md) §5.4, [../01-architecture/state-machines.md](../01-architecture/state-machines.md), [runtime-api.md](runtime-api.md), [configuration.md](configuration.md) §8 |

This document lists every typed error of APKRun: its stable code, when it is raised, its user text, its remediation, and its CLI exit code. It also lists the non-error enums that decide what users see (session end reasons, stop reasons, launcher screens) and the mapping from health checks to errors.

The error model is defined in [../02-design/diagnostics.md](../02-design/diagnostics.md) §2: `APKRunError`, `ErrorParameter`, causes, presentation, and operation IDs. The list payload in §3.4 extends that model for `vm.configurationInvalid`; host health findings use `ErrorInfo` and localized text. XPC serialization for typed list details is specified in RuntimeAPI task #032.

This document is the design source of `Packages/DiagnosticsCore/ErrorCatalog/errors.json`. #061 creates the JSON from it. From then on the JSON is the source, and `swift scripts/errorgen.swift --markdown` regenerates the tables of §5–§16 and §20.3. CI fails if the two differ ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2.2).

---

## 1. How to read this catalog

### 1.1 Columns of the domain tables

| Column | Content |
|---|---|
| Case | the Swift case with its associated values, as the owning design document declares it. A variant row (§3.4) shows the sub-case, for example `guestInstallFailed(.conflict, …)` |
| Code | the stable code `<domain>.<case>` (§2). It is also the text key of the entry. A variant row adds the variant key after a slash: `store.guestInstallFailed / conflict` |
| When raised | the condition |
| Raised by | the module or component that throws the error |
| Message | the English message template (`message.en`). `{name}` is a parameter (§3.2). "(cause)" means that the entry is transparent (§3.5) |
| Remediation · action | the English remediation (`remediation.en`), then the `RemediationAction` (§4) in backticks. "—" means that the entry has no remediation of its own. When it has a cause, the cause's remediation and action are shown |
| Exit | `cliExit`, the CLI exit code ([../02-design/cli.md](../02-design/cli.md) §3.3). "cause" means the exit code of the cause (§3.5) |
| Ref | a section of the owning design document, which is named at the start of each domain section, or a link to another document |

### 1.2 Conventions

- `‹App›` in the design documents is `{app}` here. `{app}` is the app's display label, or the package ID when the raiser doesn't know the label.
- Every case in this catalog is declared in its owning design document. A case that no design document declares yet is marked **Proposed** and listed in §22. The owning document adds the case before it is implemented. No row is marked **Proposed** now.
- Texts that a design document gives are used word for word. The catalog only adds a final period, replaces `‹…›` with a parameter, and adapts wording to the voice rules of §3.3.
- The Japanese texts (`ja`) are not in this document. They are written in `errors.json` (#092).
- Inside the tables of §5–§16, a bare §N refers to the owning design document named at the start of the domain section, and "catalog §N" refers to this document. Everywhere else, a bare §N refers to this document.

---

## 2. Codes

### 2.1 Format

- `qualifiedCode = "<domain>.<case>"`. `<domain>` is `ErrorDomain.rawValue`. `<case>` is the Swift case name without associated values. Examples: `vm.startFailed`, `store.downgradeRefused`.
- A nested error type uses the domain of the type that contains it. `VMConfigurationFailure` codes are `vm.*`. `ValidationFailure` and `HealthCheckFailure` codes are `update.*`.
- Case names are lowerCamelCase. They name the condition, not the remedy.

| Domain | Swift types | Owner | Section | Design source |
|---|---|---|---|---|
| `vm` | `VMFailure`, `VMConfigurationFailure` | VirtualMachineCore | §5 | [../02-design/vm.md](../02-design/vm.md) §3, §13 |
| `graphics` | `GraphicsFailure` | GraphicsCore | §6 | [../02-design/graphics.md](../02-design/graphics.md) §13.1 |
| `runtime` | `RuntimeFailure` | RuntimeCore, RuntimeHost | §7 | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §11 |
| `guestProtocol` | `GuestProtocolFailure` | GuestProtocol | §8 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §12 |
| `image` | `ImageFailure` | ImageCore | §9 | [../02-design/android-image.md](../02-design/android-image.md) §14.1 |
| `store` | `StoreFailure` | APKStoreCore | §10 | [../02-design/package-store.md](../02-design/package-store.md) §12 |
| `update` | `UpdateFailure`, `ValidationFailure`, `HealthCheckFailure` | UpdateCore | §11 | [../02-design/update-system.md](../02-design/update-system.md) §13 |
| `wrapper` | `WrapperFailure` | WrapperCore | §12 | [../02-design/wrapper.md](../02-design/wrapper.md) §13 |
| `integration` | `IntegrationFailure` | IntegrationCore | §13 | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §12 |
| `maintenance` | `MaintenanceFailure` | RuntimeHost (maintenance services) | §14 | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §11 |
| `diagnostics` | `DiagnosticsFailure` | DiagnosticsCore | §15 | this document |
| `cli` | `CLIFailure` | CLI | §16 | this document, [../02-design/cli.md](../02-design/cli.md) §3 |

### 2.2 Allocation rules

1. A new case gets the code derived from its name. No registry of numbers exists.
2. Case names are unique within a domain, including the nested types of that domain. `ErrorCatalogTests` fails on a duplicate code.
3. A code never changes meaning. If the meaning of a case changes, add a new case and retire the old one.
4. Do not rename a case. A rename is a retirement plus a new code.
5. A code is never reused. A removed case keeps its entry in `errors.json` with `"retired": true` and its last texts. Peers of an older build can still send it over XPC (the wrapper endpoint serves N−1, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.1), and the retired entry still renders.
6. Deprecation: a case that the code no longer throws but that an N−1 peer can still send stays in the catalog unchanged. It is retired when no supported peer sends it. The generated Swift catalog retains retired entries so older peer errors still render; per-module fixture lists skip them.
7. Adding an associated value keeps the code when the meaning is the same. A new placeholder in the template must be declared in `parameters` (§3.2).

### 2.3 Namespaces

Error codes, health check IDs, settings keys, log events, and UI text keys are separate namespaces. They look alike because they share subsystem prefixes.

| Namespace | Example | Defined in |
|---|---|---|
| Error codes | `runtime.bootTimedOut` | this document |
| Health check IDs | `runtime.boot` | [../02-design/diagnostics.md](../02-design/diagnostics.md) §7.4 |
| Settings keys | `runtime.bootTimeoutSeconds` | [configuration.md](configuration.md) |
| Log events that are not errors | `store.hostCheckMissed` | the owning design document, §17.10 |
| Launcher UI keys | `launcher.screen.updating` | [../02-design/wrapper.md](../02-design/wrapper.md) §5.9; this catalog §18 |

- A test fails if an error code equals a health check ID ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2.1). No code in this catalog does. Every finding code of §20.3 differs from its check ID (for example `store.updatedOutsideAPKRun`, not `store.externallyUpdated`).
- A log entry of an error carries the code in its `err=` field ([../02-design/diagnostics.md](../02-design/diagnostics.md) §3). The log event and the error code are then the same string, for example `maintenance.hostUpdateAbandoned`.

---

## 3. Entries and presentation

### 3.1 The `errors.json` entry

The format is the one of [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.2, plus the two optional members of §3.4 and §3.5:

```json
{
  "code": "store.guestInstallFailed",
  "parameters": ["app"],
  "message":     { "en": "Android couldn't install {app}.", "ja": "…" },
  "remediation": { "en": "Try again. If it fails again, create a diagnostics report.", "ja": "…" },
  "action": "retry",
  "cliExit": 1,
  "variants": {
    "conflict": {
      "message":     { "en": "Android refused {app} because it conflicts with an installed app.", "ja": "…" },
      "remediation": { "en": "Uninstall the conflicting app, then try again.", "ja": "…" },
      "action": "none"
    }
  }
}
```

| Member | Required | Content |
|---|---|---|
| `code` | yes | the qualified code (§2.1) |
| `parameters` | yes | every placeholder used by any text of the entry, including `cause` |
| `message` | yes, unless transparent | the message template per language |
| `remediation` | no | the remediation template per language |
| `action` | yes, unless transparent | a `RemediationAction` raw value (§4) |
| `cliExit` | yes | an exit code of [../02-design/cli.md](../02-design/cli.md) §3.3, or `"cause"` (§3.5) |
| `cliExitRule` | no | a named data-dependent CLI exit rule; `cliExit` is its fallback |
| `retired` | no | `true` for a removed case (§2.2) |
| `variants` | no | texts and actions per sub-case (§3.4) |
| `transparent` | no | `true` for a pure container (§3.5) |

### 3.2 Parameters and privacy

Parameters use only the `ErrorParameter` kinds of [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.1. The catalog uses these names:

| Parameter | Kind | Content |
|---|---|---|
| `app` | text | display label, or the package ID |
| `package` | text | package ID |
| `version`, `installedVersion`, `newVersion`, `oldVersion` | text | an Android `versionName`, an APKRun version, or an image version |
| `file` | fileName | the last path component. For APK sets, the file name inside the set |
| `needed`, `available`, `limit`, `bytes`, `memory` | bytes | rendered with `ByteCountFormatter` ("1.8 GB") |
| `count`, `required`, `guest`, `target`, `floor` | count | counts and API levels |
| `duration` | duration | for example the wait before a retry |
| `agent` | text | "Guest Agent" or "Store Agent" |
| `integration` | text | the display name of an `IntegrationKind`: Clipboard, Notifications, Links, Files, Shared folders, Microphone |
| `step`, `phase`, `stage`, `reason`, `key`, `allowed`, `check`, `flag`, `argument`, `command`, `capability`, `operation`, `owner`, `code`, `split`, `field`, `tool`, `identity`, `submission`, `found`, `supported`, `build` | text | stable identifiers, enum case names, or public version data |
| `cause` | — | the rendered message of the cause. The renderer fills it |

- User text never contains a path, a URL, a user name, clipboard content, notification text, file contents, console excerpts, or free text from Android or the network (NFR-SEC-05, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §11, [../02-design/package-store.md](../02-design/package-store.md) §12).
- Free-text associated values (`detail`, `reason: String`, `message`, `summary`, `VZErrorInfo.description`, `GuestError.message`, the `String` of `internal`) are never parameters. They go to the log and to the redacted diagnostics bundle.
- URL payloads (`destinationNotWritable(URL)` and others) are passed as `.fileName`: the last path component only.
- System errors become `UnderlyingError` (domain and integer code). Copy Details shows them ("underlying NSPOSIXErrorDomain 28").

### 3.3 Message text policy

- **Message**: what happened, from the user's point of view. One sentence, ending with a period. It should fit one terminal line (about 100 characters in English).
- **Remediation**: the next step, in the imperative. One or two sentences. It names the button or the Settings pane where one exists.
- Voice of [../02-design/host-ui.md](../02-design/host-ui.md) §13: "Mac app", not wrapper or bundle. "Android" ("Start Android"), not VM, guest, or runtime. "app", not package or APK. "update source", not provider or authority. "APKRun's background service", not apkrund.
- Exceptions: "Guest Agent" and "Store Agent" appear because the health verdicts use them ([../02-design/diagnostics.md](../02-design/diagnostics.md) §7.2). File-format names (.apk, base APK, OBB) appear in import errors, because the user chose those files. CLI-only entries (§16) name commands and flags.
- Contractions as in host-ui.md ("can't", "couldn't", "isn't"). No "please", no "error", no exclamation marks, no blame.
- Where a design document gives the text, it is used as given (§1.2).

### 3.4 Variants

Some cases carry a sub-reason whose design texts or actions differ, for example `guestInstallFailed(InstallFailureKind, …)` ([../02-design/package-store.md](../02-design/package-store.md) §6.4). One message per code cannot express that. This catalog therefore uses an optional `variants` member:

- The key is the stable case name of the sub-reason (`conflict`, `appBundle`, `privacyDenied`). The error passes it as the parameter `reason` (`.text`). No change to `APKRunError` is needed.
- A variant may override `message`, `remediation`, and `action`. Code, parameters, and `cliExit` stay those of the entry.
- Lookup order: the variant's text, then the entry's text, then the cause's remediation.
- Tests: every variant key is a case of the sub-enum (the fixture iterates the sub-enum), and every variant has `en` and `ja` in release builds.
- For a container code, the variant key is the case name of the cause.
- Version-direction variants use the keys `hostNewer` (APKRun is newer than what Android supports: update Android) and `guestNewer` (Android needs a newer APKRun: update APKRun).
- `vm.configurationInvalid` keeps the item case names, separated by commas, in the `items` parameter (`.text`) as a fallback. It also carries an ordered `APKRunError.listItems` array. Each `ErrorListItem` selects either a fully qualified catalog code or a variant key and carries that item's own typed parameters. The renderer uses those parameters to produce one hint line per item; repeated codes remain distinct and ordered. If an older payload has no per-item value needed by a message, it uses the aggregate's generic message instead of showing a blank placeholder. RuntimeAPI task #032 transports these details as an optional field.

### 3.5 Nested errors and transparent containers

- Nested errors keep the outer code. The outer message may include `{cause}`. When the outer entry has no remediation, the cause's remediation and action are used. JSON output carries the whole `cause` chain ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2.1).
- A **transparent** entry (`"transparent": true`) is a pure container such as `RuntimeFailure.image(ImageFailure)`. It has no text of its own. Message, remediation, action, and exit code come from the first non-transparent error in the cause chain. The `code:` line still shows the outer code.
- `"cliExit": "cause"` is allowed only for transparent entries. `ExitCodes.swift` resolves it through the chain. The exit-code test checks every fixture value of a transparent case against the exit of its cause. Without this rule, a downgrade that arrives as `update.validation(update.downgrade)` would exit 1 instead of 5 ([../02-design/cli.md](../02-design/cli.md) §3.3).
- Transparent entries: `runtime.image`, `runtime.vm`, `runtime.vmConfiguration`, `runtime.graphics`, `store.runtimeUnavailable`, `update.validation`, `update.intrinsic`, `update.installFailed`, `maintenance.imageInstallFailed`.

### 3.6 Surfaces

| Surface | What is shown | Reference |
|---|---|---|
| APKRun.app, APKRunMenuBar | the message as the title, the remediation as the body, a button for `action`, **Copy Details**, and **Troubleshooting…** where it helps. Principle 5: every error has a next step | [../02-design/host-ui.md](../02-design/host-ui.md) §1, [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.3 |
| Launcher | the screens of §18 with the same texts. Screen E shows the message, the remediation, **Try Again**, and **Open APKRun** | [../02-design/wrapper.md](../02-design/wrapper.md) §5.4 |
| CLI | three lines on stderr: `error:` message, `hint:` remediation, `code:` code and the first 8 hex digits of the operation ID | [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.3 |
| CLI `--json` | `{ "schemaVersion": 1, "error": { "code", "message", "remediation", "operationID" } }` on stdout | [../02-design/cli.md](../02-design/cli.md) §3.2 |
| Copy Details | one line: build, image version, code, full operation ID, time, underlying error | [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.3 |
| Health results | `HealthResult.error` carries the entry (§20) | [../02-design/diagnostics.md](../02-design/diagnostics.md) §7.1 |
| Logs | `err=<code>` on the entry that records the failure | [../02-design/diagnostics.md](../02-design/diagnostics.md) §3 |

- **Warnings.** Entries with `cliExit` 0 are warnings: the command succeeded. The CLI prints them as `warning:`, `hint:`, and `code:` lines, and the exit code stays 0. They are `wrapper.registrationFailed`, `store.alreadyInstalled`, and `cli.versionSkew`.
- **Several problems.** `vm.configurationInvalid` carries typed `listItems`; the GUI and CLI render every item, including its own values. `runtime.hostRequirementsNotMet` is a health `ErrorInfo` with localized item text, not an `APKRunError.listItems` payload. The CLI prints one `hint:` line per item, so both presentations can exceed three lines.

### 3.7 Languages

- The presenting process chooses the language from `Locale.preferredLanguages`, with English as the fallback.
- Release builds need `en` and `ja` for every entry and every variant (#092).
- `ErrorCatalog.generated.swift` compiles every language in as literals, because the launcher has no resource bundles ([../02-design/wrapper.md](../02-design/wrapper.md) §5.9).
- Launcher texts that are not errors are in `Apps/APKRunLauncher/Localizable.xcstrings` (§18.2).

### 3.8 Unknown codes

A peer can send a code that the receiving build's catalog doesn't have: a newer apkrund answers a launcher of the previous major (the wrapper endpoint serves N−1, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.1), or a CLI copied out of an older APKRun. The receiver then shows a generic entry (chosen):

| Member | Value |
|---|---|
| message | "APKRun couldn't complete the operation." |
| remediation | "Update APKRun. If it happens again, create a diagnostics report." |
| action | `updateAPKRun` |
| cliExit | 1 |

- The `code:` line and Copy Details keep the original code, so a report still names the real error.
- `WireError` carries no text, only the code, the parameters, the cause, and the underlying error ([runtime-api.md](runtime-api.md) §4.5). The receiver can only render from its own catalog. When the cause chain of an unknown code contains a known code, the unknown code is treated as transparent (§3.5, chosen): texts, action, and exit code come from the first known entry. The generic entry above is used only when no code in the chain is known.
- A retired code (§2.2) is not unknown. It renders with its last texts.
- An unknown variant key uses the entry's own texts (§3.4). An unknown parameter is ignored, and a missing one renders as an empty string and is logged (chosen).

---

## 4. Remediation actions

`RemediationAction` is defined in [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.3. APKRun URLs only navigate ([../02-design/host-ui.md](../02-design/host-ui.md) §3.1), so the launcher can offer only navigation.

| Action | APKRun.app, APKRunMenuBar | Launcher | CLI equivalent (for reference; the hint is the remediation text) |
|---|---|---|---|
| `none` | no action button | the screen's own buttons | — |
| `retry` | **Try Again**: the same request with a new operation ID | **Try Again** | run the command again |
| `openTroubleshooting` | **Troubleshooting…**: Settings → Troubleshooting | **Open APKRun** (`apkrun://settings/troubleshooting`) | `apkrun doctor` |
| `restartAndroid` | **Restart Android** | **Try Again** (a new session starts Android) | `apkrun runtime restart` |
| `startGraphicsSafeMode` | **Start in Graphics Safe Mode**: sets `graphics.safeMode` and restarts Android | **Open APKRun** (`apkrun://settings/troubleshooting`) | `apkrun config set graphics.safeMode on`, then `apkrun runtime restart` |
| `openRuntimeSettings` | **Open Settings**: Settings → Runtime | **Open APKRun** (`apkrun://settings/runtime`) | `apkrun config list` |
| `openStorageSettings` | **Open Settings**: Settings → Storage | **Open APKRun** (`apkrun://settings/storage`) | `apkrun image list` |
| `openPrivacySettings` | **Open Settings**: Settings → Privacy, which shows APKRun's macOS permissions with **Open System Settings** | **Open APKRun** (`apkrun://settings/privacy`) | — |
| `openLoginItemsSettings` | **Open System Settings**: System Settings → General → Login Items & Extensions | **Open APKRun** | — |
| `openNotificationSettings` | **Open System Settings**: System Settings → Notifications | **Open System Settings** (the same pane) | — |
| `openDownloadsPage` | **Download APKRun**: opens `APKRunDownloadsURL` ([configuration.md](configuration.md) §7.1) in the browser | **Get APKRun**: opens `LauncherBuild.downloadURL`, the same URL | — |
| `updateAPKRun` | **Check for Updates**: Settings → General and a user-initiated Sparkle check | **Check for Updates** (`apkrun://settings/general`) | `apkrun self-update check` |
| `updateAndroid` | **Update Android**: Settings → General and the Android system update | **Open APKRun** (`apkrun://settings/general`) | `apkrun image install --latest` |
| `updateMacApp` | **Update Mac App** | **Update Mac App** (`apkrun://package/<id>/mac-app`) | `apkrun wrapper refresh <package>` |
| `createMacApp` | **Create Mac App** | **Open APKRun** (`apkrun://package/<id>/mac-app`) | `apkrun wrap <package>` |
| `reinstallApp` | **Repair…** on the app page | **Open APKRun** (`apkrun://package/<id>`) | `apkrun repair <package>` |
| `reportProblem` | **Report a Problem…**: the diagnostics report sheet | **Report a Problem…** (`apkrun://report?package=<id>`) | `apkrun diagnostics` |

---
## 5. Domain `vm`

Owner: VirtualMachineCore. Design: [../02-design/vm.md](../02-design/vm.md). Users see these errors inside `runtime.vm` (transparent, §7.2), so the texts below are the user texts. `VZErrorInfo` becomes the `UnderlyingError` (`VZErrorDomain` and code). Its description goes to the log only.

`VMDefinitionValidator` checks a `VMDefinition` before every boot ([../02-design/vm.md](../02-design/vm.md) §3). RuntimeCore and ImageCore build the definition, so almost every failure is a bug in APKRun or a damaged installation. A single failure uses the grouped text below. Several failures are listed as individual hints; the top-level message remains generic.

The port number is logged, never shown.

<!-- errorgen:begin vm -->
### 5.1 `VMFailure`

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `invalidTransition(from:to:)` | `vm.invalidTransition` | a lifecycle call that `VMState` does not allow. A bug | VMController | "Android is in an unexpected state." | "Restart Android. If this happens again, report the problem." `restartAndroid` | 70 | §9, [../01-architecture/state-machines.md](../01-architecture/state-machines.md) |
| `startFailed(underlying:)` | `vm.startFailed` | `VZVirtualMachine.start` fails | VMController | "Android couldn't start." | "Try again. If it fails again, create a diagnostics report." `retry` | 1 | §9.1 |
| `stoppedWithError(underlying:)` | `vm.stoppedWithError` | the delegate reports `didStopWithError` | VMController | "Android stopped unexpectedly." | "Restart Android." `restartAndroid` | 1 | §9.2 |
| `pauseFailed(underlying:)` | `vm.pauseFailed` | `pause()` fails (idle suspend, host sleep) | VMController | "Android couldn't be paused." | "Restart Android if apps stop responding." `restartAndroid` | 1 | §9.4 |
| `resumeFailed(underlying:)` | `vm.resumeFailed` | `resume()` fails | VMController | "Android couldn't resume." | "Restart Android." `restartAndroid` | 1 | §9.4 |
| `stopTimedOut` | `vm.stopTimedOut` | the forced stop did not reach `stopped` | VMController | "Android didn't stop in time." | "Try again. If it fails again, quit and reopen APKRun." `retry` | 1 | §9.3 |
| `vsockDeviceNotConfigured` | `vm.vsockDeviceNotConfigured` | VMController.connect is called for a VM definition without vsock enabled | VMController | "Android's host connection isn't enabled." | "Enable vsock in the VM definition before connecting. If APKRun created this VM, update the caller to request vsock and restart the VM." `openTroubleshooting` | 70 | §8 |
| `vsockDeviceUnavailable` | `vm.vsockDeviceUnavailable` | the VM definition enables vsock but Virtualization.framework does not expose its device | VMController | "Android's host connection is unavailable." | "Restart Android. If this happens again, create a diagnostics report." `restartAndroid` | 70 | §8 |
| `vsockConnectFailed(port:underlying:)` | `vm.vsockConnectFailed` | `VZVirtioSocketDevice.connect` fails | VMController | "APKRun couldn't connect to Android." | "Restart Android." `restartAndroid` | 1 | §8 |
| `vsockPortNotListening(port:)` | `vm.vsockPortNotListening` | no guest listener on the port yet | VMController | "Android isn't ready yet." | "Try again in a moment." `retry` | 75 | §8 |
| `vsockConnectTimedOut(port:)` | `vm.vsockConnectTimedOut` | the connection did not open within the timeout | VMController | "Android didn't answer in time." | "Try again. If it fails again, restart Android." `retry` | 1 | §8 |
| `loopbackPortInUse(port:)` | `vm.loopbackPortInUse` | developer mode is on and another process already listens on the ADB port | VsockLoopbackForwarder | "APKRun couldn't open developer debugging port {port}, because another program is using it." | "Quit the program that uses port {port}, then start Android again. Android starts without ADB until then." `retry` | 75 | §8 |
| `loopbackListenFailed(port:underlying:)` | `vm.loopbackListenFailed` | the loopback listener cannot be created or bound for a reason other than a port in use | VsockLoopbackForwarder | "APKRun couldn't open developer debugging port {port} on this Mac." | "Check that no security tool blocks local connections, then start Android again. Android starts without ADB until then." `retry` | 1 | §8 |
| `virtualizationUnavailable` | `vm.virtualizationUnavailable` | `VZVirtualMachineConfiguration.isSupported` is false, or the entitlement is missing | VMController | "Virtualization is not available on this Mac." | "APKRun can't run inside a virtual machine. On a real Mac, reinstall APKRun." `openTroubleshooting` | 1 | §13 |
| `networkAttachmentLost` | `vm.networkAttachmentLost` | Virtualization.framework reports `attachmentWasDisconnectedWithError` | VMController | "Android lost its network connection." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | §7, §9.2 |
| `consoleLogWriteFailed` | `vm.consoleLogWriteFailed` | writing or synchronizing a VM serial console log failed | ConsoleLogWriter | "APKRun couldn't write Android's console log." | "Check the free disk space. Settings → Storage shows what APKRun uses." `openStorageSettings` | 1 | §14 |

### 5.2 `VMConfigurationFailure`

| Case | Code | Cause | Exit |
|---|---|---|---|
| `cpuCountOutOfRange(requested, allowed)` | `vm.cpuCountOutOfRange` | CPU count outside the VZ and host limits; `allowed` is `none` when the interval is empty | 70 |
| `memoryOutOfRange` | `vm.memoryOutOfRange` | memory not a multiple of 1 MiB, or outside the VZ limits | 70 |
| `memoryExceedsHostCap(cap)` | `vm.memoryExceedsHostCap` | memory above 50 % of physical memory (NFR-RES-01) | 1 |
| `kernelMissing(url)` | `vm.kernelMissing` | no kernel file | 1 |
| `kernelNotUncompressedImage(detected)` | `vm.kernelNotUncompressedImage` | gzip or lz4 kernel, or no arm64 `Image` magic | 70 |
| `initrdMissing` | `vm.initrdMissing` | the initrd file is missing | 1 |
| `initrdTooLarge` | `vm.initrdTooLarge` | initrd above 512 MiB | 70 |
| `commandLineInvalid` | `vm.commandLineInvalid` | above 2048 bytes, or not ASCII | 70 |
| `diskMissing(role)` | `vm.diskMissing` | a disk file is missing | 1 |
| `diskIsAndroidSparse(role)` | `vm.diskIsAndroidSparse` | a disk is an Android sparse image | 70 |
| `duplicateDisk(role)` | `vm.duplicateDisk` | the same disk URL twice | 70 |
| `diskNotReadable(role)` | `vm.diskNotReadable` | a disk is not readable | 1 |
| `diskNotWritable(role)` | `vm.diskNotWritable` | a read-write disk is not writable | 1 |
| `diskSyncModeTestOnly(role)` | `vm.diskSyncModeTestOnly` | the unsynchronized disk mode is reserved for tests | 70 |
| `diskIdentifierInvalid` | `vm.diskIdentifierInvalid` | identifier above 20 ASCII characters | 70 |
| `missingSystemConsole` | `vm.missingSystemConsole` | console port 0 is not the system console | 70 |
| `invalidMACAddress` | `vm.invalidMACAddress` | not a locally administered unicast address | 70 |
| `machineIdentifierInvalid` | `vm.machineIdentifierInvalid` | the stored machine identifier doesn't decode | 70 |
| `customDeviceInvalid(name, reason)` | `vm.customDeviceInvalid` | a custom virtio device configuration is rejected | 70 |
| `microphoneUsageDescriptionMissing` | `vm.microphoneUsageDescriptionMissing` | sound input without `NSMicrophoneUsageDescription` | 70 |
| `frameworkRejected(underlying)` | `vm.frameworkRejected` | `VZVirtualMachineConfiguration.validate()` throws | 70 |
| `configurationInvalid([VMConfigurationFailure])` | `vm.configurationInvalid` | more than one rule failed (catalog §3.6) | 70 when every item is 70, otherwise 1 |

Texts:

| Entries | Message | Remediation · action |
|---|---|---|
| `vm.diskNotReadable` | "APKRun can't read the {role} disk." | "Quit and reopen APKRun. If it happens again, reset Android in Settings → Troubleshooting." `openTroubleshooting` |
| `vm.diskNotWritable` | "APKRun can't write to the {role} disk." | "Quit and reopen APKRun. If it happens again, reset Android in Settings → Troubleshooting." `openTroubleshooting` |
| `vm.cpuCountOutOfRange` | "Android can't use a CPU count of {requested}; the allowed range is {allowed}." | "Report the problem. The code identifies the rule that failed." `reportProblem` |
| `vm.commandLineInvalid`, `vm.configurationInvalid`, `vm.diskIdentifierInvalid`, `vm.frameworkRejected`, `vm.initrdTooLarge`, `vm.invalidMACAddress`, `vm.machineIdentifierInvalid`, `vm.memoryOutOfRange`, `vm.microphoneUsageDescriptionMissing`, `vm.missingSystemConsole` | "Android's configuration is not valid." | "Report the problem. The code identifies the rule that failed." `reportProblem` |
| `vm.memoryExceedsHostCap` | "Android's memory allocation exceeds this Mac's {cap} limit." | "Choose less memory for Android in Settings → Runtime." `openRuntimeSettings` |
| `vm.customDeviceInvalid` | "Custom device {name} is invalid." | "Report the problem. The code identifies the rule that failed." `reportProblem` |
| `vm.initrdMissing`, `vm.kernelMissing` | "Files that Android needs are missing, or APKRun can't read or write them." | "Quit and reopen APKRun. If it happens again, reset Android in Settings → Troubleshooting." `openTroubleshooting` |
| `vm.kernelNotUncompressedImage` | "The kernel image has an unsupported format ({detected})." | "Report the problem. The code identifies the rule that failed." `reportProblem` |
| `vm.diskMissing` | "The {role} disk file is missing." | "Quit and reopen APKRun. If it happens again, reset Android in Settings → Troubleshooting." `openTroubleshooting` |
| `vm.duplicateDisk` | "The {role} disk is listed more than once." | "Report the problem. The code identifies the rule that failed." `reportProblem` |
| `vm.diskIsAndroidSparse` | "The {role} disk uses Android's unsupported sparse image format." | "Report the problem. The code identifies the rule that failed." `reportProblem` |
| `vm.diskSyncModeTestOnly` | "The {role} disk uses a test-only synchronization mode." | "Report the problem. The code identifies the rule that failed." `reportProblem` |
<!-- errorgen:end vm -->

- The validator of vm.md §3 collects all failures. One failure is thrown as itself. Several are thrown as `configurationInvalid`, whose items the GUI and the CLI list (§3.6). `apkrun doctor` prints all of them.
- `RuntimeFailure.vmConfiguration(VMConfigurationFailure)` carries these failures to clients. It is a transparent container like `runtime.vm` (§7.2).

---

## 6. Domain `graphics`

Owner: GraphicsCore. Design: [../02-design/graphics.md](../02-design/graphics.md) §13.1. Users see these errors inside `runtime.graphics` (transparent, §7.2), in `DisplayFault.graphics` (§17.3), and in health checks (§20). Guest-caused virtio-gpu error responses are not `GraphicsFailure`s (graphics.md §4.2).

<!-- errorgen:begin graphics -->
| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `rendererInitFailed(stage, detail)` | `graphics.rendererInitFailed` | EGL, ANGLE, or virglrenderer initialization fails before Android boots. `stage`: `egl`, `metal`, `virgl` | GraphicsBridge | "Graphics failed to start." | "Start Android in Graphics Safe Mode. If that doesn't help, update macOS and APKRun, and create a diagnostics report." `startGraphicsSafeMode` | 1 | §8, §13.1 |
| `rendererOperationFailed(operation, detail)` | `graphics.rendererOperationFailed` | a renderer operation fails, including a call made from the wrong thread | GraphicsBridge | "A graphics operation could not be completed." | "Restart Android. If the problem continues, create a diagnostics report." `reportProblem` | 1 | §5.2, §13.1 |
| `rendererLost(reason)` | `graphics.rendererLost` | context loss or GPU removal. RuntimeCore restarts Android | GraphicsBridge | "Android's graphics stopped working." | "Android restarts automatically. If this happens often, start Android in Graphics Safe Mode." `startGraphicsSafeMode` | 1 | §8 |
| `libraryMissing(name)` | `graphics.libraryMissing` | a VirGLRuntime dylib is missing or its signature is invalid | GraphicsBridge | "Part of APKRun is missing or damaged." | "Reinstall APKRun." `openDownloadsPage` | 1 | §5.1 |
| `scanoutInvalid(ScanoutID)` | `graphics.scanoutInvalid` | a host request names a scanout outside 0…15. A bug | ScanoutTable | "Android's display configuration is not valid." | "Report the problem." `reportProblem` | 70 | §6.1 |
| `modeUnsupported(DisplayMode)` | `graphics.modeUnsupported` | a mode beyond the EDID or size limits. A bug (DisplayPool clamps) | ScanoutTable | "Android's display configuration is not valid." | "Report the problem." `reportProblem` | 70 | §6.4 |
| `poolAllocationFailed(PixelSize)` | `graphics.poolAllocationFailed` | an IOSurface or Metal texture can't be created | SurfacePool | "There isn't enough graphics memory for this window." | "Close other apps or windows, then try again. If it happens again, create a diagnostics report." `retry` | 1 | §6.3 |
| `configUpdateFailed(detail)` | `graphics.configUpdateFailed` | `updateConfigurationSpace` fails | VirtioGPUDevice | "Android couldn't apply a display change." | "Restart Android." `restartAndroid` | 1 | §4.3 |
| `deviceNotReady` | `graphics.deviceNotReady` | a host request before DRIVER_OK. DisplayPool retries after `.guestBound` or boot completion | VirtioGPUDevice | "Android's display isn't ready yet." | "Try again in a moment." `retry` | 75 | §4.1 |
<!-- errorgen:end graphics -->

- Reinstalling APKRun is the fix for `graphics.libraryMissing`, so its action is `openDownloadsPage`, as for the host checks `host.appSignature` and `host.componentVersions` (§15, §20.2).
- `rendererLost` twice in 24 hours, or any `rendererInitFailed`, makes the health check `graphics.renderer` suggest `startGraphicsSafeMode` (§20.2).

---

## 7. Domain `runtime`

Owners: RuntimeCore and RuntimeHost. Design: [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §11, [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §10, [runtime-api.md](runtime-api.md) §4.5. A `RuntimeFailure` also appears in `RuntimeState.failed`, in `SessionEndReason.error` (§17.1), and in `runtime.state` health results (§20.2).

### 7.1 Host process

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `hostStartupFailed(step:underlying:)` | `runtime.hostStartupFailed` | a degraded startup step (§2.2 steps 4–7, 9) failed. `runtimeStatus` and every operation that needs the component return it | RuntimeHost | "Part of APKRun's background service couldn't start: {cause}" | — (the cause's) | 69 | §2.2, [configuration.md](configuration.md) §8.1 |
| `hostShuttingDown` | `runtime.hostShuttingDown` | apkrund is exiting (logout, `SIGTERM`, idle exit) and answers pending requests | RuntimeHost | "APKRun's background service is stopping." | "Try again in a moment." `retry` | 75 | §2.4 |
| `hostUpdating` | `runtime.hostUpdating` | the host state `updating` or `restartPending` refuses the operation ([runtime-api.md](runtime-api.md) §3.7) | RuntimeHost | "APKRun is updating." | "Try again in a minute." `retry` | 75 | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6 |
| `notProvisioned` | `runtime.notProvisioned` | Android is not set up yet: first-run provisioning is incomplete (§9) | RuntimeSupervisor | "APKRun needs to finish setup." | "Open APKRun to finish setup, or run: apkrun setup" `none` | 69 | §3.2 step 0, §9.2 |
| `hostRequirementsNotMet([HostRequirement])` | `runtime.hostRequirementsNotMet` | `HostRequirementsCheck` finds one or more failed requirements. The list has one item per failure | HostRequirementsCheck | "APKRun can't run on this Mac." | one line per item (catalog §7.5) `none` | 1 | §9.1 |

### 7.6 Runtime errors implemented so far (#003, #012)

<!-- errorgen:begin runtime -->
| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `instanceLocked(owner:)` | `runtime.instanceLocked` | another process holds `Runtime/instance.lock` | RuntimeHost, `apkrun dev` | "Another APKRun process is using Android." | "Try again when it has finished." `retry` | 75 | §2.3 |
| — | `runtime.instanceLocked / apkrunDev` | apkrund finds an `apkrun dev` session | RuntimeHost | "A development session (apkrun dev) is using Android." | "Stop the development session, then try again." `retry` | 75 | §2.3 |
| — | `runtime.instanceLocked / apkrund` | `apkrun dev` finds apkrund running on the same data root | `apkrun dev` | "APKRun's background service is using Android." | "Quit APKRun and its Mac apps, or set APKRUN_HOME to another folder." `none` | 75 | §2.3, §2.6 |
| `instanceLockFailed(underlying:)` | `runtime.instanceLockFailed` | the lock directory or file cannot be opened or updated | RuntimeHost | "APKRun couldn't reserve the Android instance." | "Check permissions for APKRun's data folder, then try again." `retry` | 1 | §2.3 |
| `devConsoleGuestFailed` | `runtime.devConsoleGuestFailed` | the Linux VM enters its failed state during `apkrun dev console` | `apkrun dev console` | "The Linux guest failed during the interactive console session." | "Inspect the VM console log and run apkrun doctor for the subsystem health checks." `retry` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devConsoleInputFailed` | `runtime.devConsoleInputFailed` | terminal input cannot be read or delivered to the guest during `apkrun dev console` | `apkrun dev console` | "Console input could not be delivered during the interactive session." | "Check the terminal and VM console log, then run the command again." `retry` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devConsoleOutputDropped` | `runtime.devConsoleOutputDropped` | the bounded raw console stream drops bytes or some buffered bytes do not reach the terminal | `apkrun dev console` | "The interactive console dropped at least {bytes} bytes, so terminal output is incomplete." | "Inspect the VM console log and reduce guest output before repeating the session." `none` | 0 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devConsoleCleanupPending` | `runtime.devConsoleCleanupPending` | both graceful and forced VM cleanup fail during `apkrun dev console` | `apkrun dev console` | "APKRun could not release the Linux VM. It is keeping the instance lock while cleanup continues." | "The terminal has been restored. Wait for cleanup to finish before starting another VM." `none` | 0 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devConsoleNotRunning(console:)` | `runtime.devConsoleNotRunning` | `apkrun dev console --android-shell` finds no socket under `Runtime/dev-console/`, so no `apkrun dev boot` owns the instance | `apkrun dev console` | "No Android {console} console is open, because no `apkrun dev boot` is running." | "Start Android with `apkrun dev boot --bundle <dir>` in another terminal, then run this command again." `none` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devConsoleSocketUnavailable` | `runtime.devConsoleSocketUnavailable` | `apkrun dev boot` cannot create or bind `Runtime/dev-console/<name>.sock` (the path is too long, or the folder cannot be created) | RuntimeHost, `apkrun dev boot` | "APKRun could not open the developer console socket for Android." | "Check permissions for APKRun's data folder, then start `apkrun dev boot` again." `retry` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devLinuxTimedOut(seconds:)` | `runtime.devLinuxTimedOut` | `apkrun dev linux` does not receive the `done` marker before its timeout | `apkrun dev linux` | "The Linux test guest didn't finish within {seconds} seconds." | "Inspect the guest console output and run the test again." `retry` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devLinuxInvalidOptions` | `runtime.devLinuxInvalidOptions` | `apkrun dev linux` receives an invalid timeout or test name | `apkrun dev linux` | "The Linux development command options are invalid." | "Use a timeout from 1 to 86400 seconds and comma-separated test names containing only letters, digits, hyphens, and underscores." `none` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devLinuxArtifactDirectoryMustBeAbsolute` | `runtime.devLinuxArtifactDirectoryMustBeAbsolute` | `APKRUN_TEST_LINUX_DIR` is set to a relative path | `apkrun dev linux` | "The Linux guest artifact directory must be an absolute path." | "Use an absolute path such as /tmp/apkrun-test-linux." `none` | 64 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devLinuxCheckFailed` | `runtime.devLinuxCheckFailed` | the guest reports a requested check as failed | `apkrun dev linux` | "A Linux test guest check failed." | "Inspect the guest console output, then fix or retry the requested check." `retry` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `devLinuxDidNotFinish` | `runtime.devLinuxDidNotFinish` | the console stream ends without the `done` marker | `apkrun dev linux` | "The Linux test guest exited before finishing its checks." | "Inspect the guest console output and run the test again." `retry` | 1 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `executableMissing` | `runtime.adbExecutableMissing` | neither `$ANDROID_HOME/platform-tools/adb` nor `adb` on `PATH` exists | AdbClient | "APKRun can't find the Android debug bridge (adb)." | "Install the Android SDK platform-tools, set ANDROID_HOME to the SDK folder, then try again. See environment-setup.md §2.5." `none` | 69 | [../05-development/environment-setup.md](../05-development/environment-setup.md) §2.5 |
| `launchFailed` | `runtime.adbLaunchFailed` | the adb executable exists but the process cannot start | AdbClient | "APKRun couldn't start the Android debug bridge (adb)." | "Check that the platform-tools folder of the Android SDK is complete, then try again." `none` | 1 | [../05-development/environment-setup.md](../05-development/environment-setup.md) §2.5 |
| `connectionUnavailable` | `runtime.adbConnectionUnavailable` | the development endpoint 127.0.0.1:6520 does not reach the device state before the deadline | AdbClient | "APKRun couldn't reach Android over ADB." | "Start Android in developer mode with apkrun dev boot, then try again." `retry` | 75 | [../02-design/cli.md](../02-design/cli.md) §5 |
| `commandFailed(command:status:)` | `runtime.adbCommandFailed` | an adb command exits with a nonzero status. The output is not logged | AdbClient | "The Android debug command {command} failed." | "Try again. If it fails again, restart Android." `retry` | 1 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §15 |
| `commandTimedOut(command:seconds:)` | `runtime.adbCommandTimedOut` | an adb command runs past its timeout, and the process is terminated | AdbClient | "The Android debug command {command} didn't finish within {seconds} seconds." | "Try again. If it fails again, restart Android." `retry` | 75 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §15 |
| `invalidArgument(command:)` | `runtime.adbInvalidArgument` | a helper receives a value that could change the command line. This is a bug | AdbClient | "APKRun refused an invalid argument for the Android debug command {command}." | "Report the problem." `reportProblem` | 70 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §15 |
| `unexpectedOutput(command:)` | `runtime.adbUnexpectedOutput` | the output of an adb command has no shape the parser knows | AdbClient | "Android answered the debug command {command} in an unexpected way." | "Try again. If it happens again, report the problem." `reportProblem` | 70 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §15 |
| `packageRejected(command:reason:)` | `runtime.adbPackageRejected` | adb install or uninstall replies `Failure [CODE]`. The code is Android's name for the reason | AdbClient | "Android didn't complete the package command {command}: {reason}." | "Check the reason, fix the app or the device, then try again." `retry` | 1 | [../02-design/package-store.md](../02-design/package-store.md) §6.1 |
| `image(ImageFailure)` | `runtime.image` | ImageCore fails in the pre-boot checks or while writing the initrd | RuntimeSupervisor | "" | — `none` | cause | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 step 2 |
| `vmConfiguration(VMConfigurationFailure)` | `runtime.vmConfiguration` | `VMDefinitionValidator` rejects the Android definition | RuntimeSupervisor | "" | — `none` | cause | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 step 4 |
| `vm(VMFailure)` | `runtime.vm` | the VM fails to start or fails while booting | RuntimeSupervisor | "" | — `none` | cause | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 step 4 |
| `kernelPanic` | `runtime.kernelPanic` | the console shows `Kernel panic - not syncing` | BootPhaseDetector | "Android's system crashed while starting." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |
| `androidBootFailed(detail:)` | `runtime.androidBootFailed` | the console shows `VIRTUAL_DEVICE_BOOT_FAILED`, the guest stops while booting, or `sys.boot_completed` does not become 1. `detail` is logged | BootPhaseDetector, RuntimeSupervisor | "Android failed to start." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |
| `bootTimedOut(phase:)` | `runtime.bootTimedOut` | the whole boot exceeds 180 s, or 900 s on a first boot | RuntimeSupervisor | "Android took too long to start (stopped at {phase})." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |
| `bootStalled(phase:)` | `runtime.bootStalled` | no phase progress for 90 s (first boot: 600 s) | RuntimeSupervisor | "Android stopped making progress while starting ({phase})." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.2, §3.3 |
| `gpuProfileUnavailable(profile:)` | `runtime.gpuProfileUnavailable` | the boot profile needs a virtio-gpu feature that the device does not offer: drmVirgl until the VirGL renderer (#022) | RuntimeSupervisor | "Android can't use the {profile} graphics profile in this version of APKRun." | "Start Android in Graphics Safe Mode. This version of APKRun can't use the VirGL graphics profile yet." `startGraphicsSafeMode` | 1 | [../02-design/graphics.md](../02-design/graphics.md) §9; [../02-design/android-image.md](../02-design/android-image.md) §9.2 |
| `guestAgent(GuestAgentFailure)` | `runtime.guestAgent` | the development Guest Agent cannot be installed, started, or reached after boot completion | RuntimeSupervisor | "" | — `none` | cause | [../02-design/guest-components.md](../02-design/guest-components.md) §3 |
| `adb(AdbFailure)` | `runtime.adb` | an ADB command that installs, starts, or forwards to the Guest Agent fails | GuestAgentProvisioner, ADBForwardGuestTransport | "" | — `none` | cause | [../02-design/guest-components.md](../02-design/guest-components.md) §3.1 |
| `bundleMissing` | `runtime.guestAgentBundleMissing` | apkrun-guest.apk or apkrun-guest.json is missing, or the record does not name io.apkrun.guest | GuestAgentBundle | "APKRun can't find the Guest Agent for Android." | "Build the Guest Agent with scripts/build-guest.sh, or set APKRUN_GUEST_DIR to the folder that holds apkrun-guest.apk and apkrun-guest.json, then try again." `none` | 1 | [../05-development/build-system.md](../05-development/build-system.md) §7.1 |
| `installFailed(reason:)` | `runtime.guestAgentInstallFailed` | adb install of the bundled agent is refused. The reason is Android's code | GuestAgentProvisioner | "Android didn't install the Guest Agent: {reason}." | "Check the reason, fix the device, then try again." `retry` | 1 | [../02-design/guest-components.md](../02-design/guest-components.md) §3.1 |
| `startFailed` | `runtime.guestAgentStartFailed` | the connection failed and no agent process runs, or the device shell refused the start | DevelopmentGuestAgent | "The Guest Agent didn't start." | "Restart Android with apkrun dev boot. If it happens again, create a diagnostics report." `restartAndroid` | 1 | [../02-design/guest-components.md](../02-design/guest-components.md) §3.2 |
| `stopped` | `runtime.guestAgentStopped` | Android is stopped while the agent is starting, so the start ends without a connection | DevelopmentGuestAgent | "The Guest Agent start was stopped before the agent answered." | "Start Android again with apkrun dev boot." `restartAndroid` | 1 | [../02-design/guest-components.md](../02-design/guest-components.md) §3.3 |
| `connectTimedOut` | `runtime.guestAgentConnectTimedOut` | no handshake completes before the connect deadline, and no refusal that would repeat was received | GuestAgentSupervisor | "APKRun couldn't connect to the Guest Agent within 5 seconds." | "Restart Android with apkrun dev boot. If it happens again, create a diagnostics report." `restartAndroid` | 75 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §15 (#072) |
| `handshakeFailed(reason:)` | `runtime.guestAgentHandshakeFailed` | the handshake fails with a typed protocol failure: an incompatible version, a wrong channel, or a bad token | GuestAgentSupervisor | "The Guest Agent refused the connection: {reason}." | "Update APKRun and Android so that both speak the same guest protocol version, then try again." `none` | 1 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §5.2, §12.3 |
| `requiredAgentUnavailable` | `runtime.requiredAgentUnavailable` | the agent died a fourth time within a minute, which the restart budget does not allow | DevelopmentGuestAgent | "The Guest Agent keeps stopping, so APKRun stopped restarting it." | "Restart Android with apkrun dev boot. If it happens again, create a diagnostics report." `restartAndroid` | 1 | [../02-design/guest-components.md](../02-design/guest-components.md) §3.3 |
| `operationFailed(reason:)` | `runtime.guestAgentOperationFailed` | a request to the agent fails with a protocol failure or a remote error. The reason is the catalog name of the failure | DevelopmentGuestAgent | "The Guest Agent didn't complete the request: {reason}." | "Try again. If it fails again, restart Android." `retry` | 1 | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §12.3 |
<!-- errorgen:end runtime -->

### 7.2 Runtime lifecycle

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `invalidTransition(from:to:)` | `runtime.invalidTransition` | a call that `RuntimeState` does not allow. A bug | RuntimeSupervisor | "Android is in an unexpected state." | "Restart Android. If this happens again, report the problem." `restartAndroid` | 70 | [../01-architecture/state-machines.md](../01-architecture/state-machines.md) |
| `image(ImageFailure)` | `runtime.image` | ImageCore fails in pre-boot checks or a migration boot | RuntimeSupervisor | (cause) | (cause) | cause | §3.2 step 2 |
| `vm(VMFailure)` | `runtime.vm` | `VMState → failed` or a VM call fails | RuntimeSupervisor | (cause) | (cause) | cause | §3.2 step 4 |
| `vmConfiguration(VMConfigurationFailure)` | `runtime.vmConfiguration` | `VMDefinitionValidator` rejects the definition | RuntimeSupervisor | (cause) | (cause) | cause | §5.2 |
| `graphics(GraphicsFailure)` | `runtime.graphics` | `rendererInitFailed` during boot, `rendererLost` while `ready` | RuntimeSupervisor | (cause) | (cause) | cause | §3.2, §3.6 |
| `bootTimedOut(phase:)` | `runtime.bootTimedOut` | the whole boot exceeds `runtime.bootTimeoutSeconds` (180 s), or `runtime.firstBootTimeoutSeconds` (900 s) on a first boot | RuntimeSupervisor | "Android took too long to start (stopped at {phase})." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | §3.2 |
| `bootStalled(phase:)` | `runtime.bootStalled` | no phase progress for 90 s (first boot: 600 s) | BootPhaseDetector | "Android stopped making progress while starting ({phase})." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | §3.2, §3.3 |
| `kernelPanic` | `runtime.kernelPanic` | the console shows `Kernel panic - not syncing` | BootPhaseDetector | "Android's system crashed while starting." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | §3.2 |
| `androidBootFailed(detail:)` | `runtime.androidBootFailed` | the console shows `VIRTUAL_DEVICE_BOOT_FAILED` | BootPhaseDetector | "Android failed to start." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | §3.2 |
| `agentIncompatible(agent:guest:host:)` | `runtime.agentIncompatible` | the agent handshake is rejected for a major version mismatch (NFR-REL-04) | agent supervisor | "The {agent} in Android doesn't match this version of APKRun." | variants below | 1 | §4.1, [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §5.2 |
| — | `runtime.agentIncompatible / hostNewer` | APKRun supports only newer agent majors | agent supervisor | "Android needs an update to work with this version of APKRun." | "Update Android." `updateAndroid` | 1 | §4.1 |
| — | `runtime.agentIncompatible / guestNewer` | the agent is newer than APKRun supports | agent supervisor | "This version of Android needs a newer APKRun." | "Update APKRun." `updateAPKRun` | 1 | §4.1 |
| `requiredAgentUnavailable(agent:)` | `runtime.requiredAgentUnavailable` | a required agent did not connect within 30 s after `bootCompleted`, or stayed away for more than 30 s while `ready` | agent supervisor | "The {agent} in Android isn't responding." | "Restart Android." `restartAndroid` | 1 | §3.2, §4.3 |
| `guestUnresponsive` | `runtime.guestUnresponsive` | agents, ADB, and the console are silent for 60 s while `ready` | hung-guest watchdog | "Android stopped responding." | "Restart Android." `restartAndroid` | 1 | §4.3 |
| `bootLoop(failures:)` | `runtime.bootLoop` | `bootLoopBlocked` is set: 3 runtime failures or unclean apkrund exits within 10 minutes. `ensureReady(.session)` refuses | RuntimeSupervisor | "Android failed to start several times." | "Start Android from APKRun, or start it in Graphics Safe Mode. Settings → Troubleshooting also offers Reset Android." `openTroubleshooting` | 1 | §2.5, §3.6 |
| `stopTimedOut` | `runtime.stopTimedOut` | the stop sequence did not reach `stopped`, even with the forced stop | RuntimeSupervisor | "Android didn't stop in time." | "Try again. If it fails again, quit and reopen APKRun." `retry` | 1 | §3.5 |
| `busy(activities:)` | `runtime.busy` | a stop without `force` while activities other than `backgroundTask` run (§3.5), or an XPC limit (§8.2 rule 7) | RuntimeSupervisor, XPC server | "Android is busy with another task." | "Try again when it has finished." `retry` | 75 | §3.5, §8.2 |

- The GUI does not show `runtime.busy` for a stop. It asks "Android is installing {app}. Stop anyway?" first ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.5) and stops with `force`. The CLI prints the error and exits 75 unless `--force` is given.
- After `runtime.graphics(rendererInitFailed)` or `runtime.bootLoop`, the GUI offers **Start in Graphics Safe Mode** ([../02-design/graphics.md](../02-design/graphics.md) §9).

### 7.3 Sessions and displays

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `packageNotInstalled(PackageID)` | `runtime.packageNotInstalled` | `openSession` or `launch` for a package that the store does not have, or Android answers `NOT_FOUND` to `LaunchApplication` (catalog §8.2) | SessionRegistry | "{app} isn't installed in APKRun." | "Install {app} in APKRun, then open it again." `none` | 4 | §7.1 step 3 |
| `launchTimedOut(PackageID)` | `runtime.launchTimedOut` | the activity did not start in time (`TIMEOUT`) | SessionRegistry | "{app} took too long to open." | "Try again. If it happens again, restart Android." `retry` | 1 | §7.1 step 6 |
| `launchFailed(PackageID, GuestError)` | `runtime.launchFailed` | `LaunchApplication` failed for another reason | SessionRegistry | "Android couldn't open {app}." | "Try again. If it fails again, create a diagnostics report." `retry` | 1 | §7.1 step 6 |
| `displayPoolExhausted` | `runtime.displayPoolExhausted` | no free display slot, or `display.maxSessions` reached | DisplayPool | "Too many Android apps are open." | "Close another Android app window. To allow more windows, raise the limit in Settings → Runtime." `openRuntimeSettings` | 1 | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3, §10 |
| `displayAttachFailed(scanout:reason:)` | `runtime.displayAttachFailed` | no `DisplayAdded` after one retry | DisplayPool | "Android couldn't create a window for the app." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` | 1 | display-and-windowing §3.3, §10 |
| `displayReconfigureFailed(reason:)` | `runtime.displayReconfigureFailed` | a mode change is not confirmed within 3 s | DisplayPool | "Android couldn't resize the window." | "The window keeps its old size. Try again." `retry` | 1 | display-and-windowing §7.1, §10 |
| `displayLost` | `runtime.displayLost` | the Android display of a session disappeared | SessionRegistry | "The app's window closed because Android removed its display." | "Open the app again." `retry` | 1 | §4.2 |
| `primaryDisplayBusy(PackageID)` | `runtime.primaryDisplayBusy` | a second `primaryDisplayCompatibility` session while display 0 is leased. `{app}` is the other app | DisplayPool | "{app} is already using the compatibility window mode." | "Close {app} or switch one of them to the standard window mode." `none` | 1 | display-and-windowing §8 |
| `guestAgentUnavailable` | `runtime.guestAgentUnavailable` | a request needs the Guest Agent, which did not reconnect within 5 s | RuntimeCore | "The Guest Agent in Android isn't connected." | "APKRun reconnects automatically. Try again in a moment." `retry` | 75 | §4.3 |

### 7.4 Runtime API

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `apiVersionMismatch(client:server:)` | `runtime.apiVersionMismatch` | the request header's major version is not served | XPC server | "APKRun needs to be restarted." | "Quit and reopen APKRun." `none` | 69 | §8.2, [runtime-api.md](runtime-api.md) §3.6 |
| `notAuthorized(operation:)` | `runtime.notAuthorized` | the endpoint kind does not allow the operation, or a wrapper asks for another package | XPC server | "This part of APKRun isn't allowed to do that ({operation})." | "Report the problem." `reportProblem` | 5 | §8.2 |
| `malformedRequest` | `runtime.malformedRequest` | an undecodable request, or a size limit ([runtime-api.md](runtime-api.md) §4.10) | XPC server | "APKRun's background service couldn't read the request." | "Report the problem." `reportProblem` | 70 | §8.2 |
| `cancelled` | `runtime.cancelled` | the operation was cancelled (Ctrl-C, **Cancel**) | any long operation | "The operation was cancelled." | — `none` | 130 | §8.3 |
| `internal(String)` | `runtime.internal` | a reply guard released without a reply, or an unexpected error | XPC server | "Something went wrong in APKRun's background service." | "Try again. If it happens again, report the problem." `reportProblem` | 70 | §8.2 |
| `operationNotFound(OperationID)` | `runtime.operationNotFound` | `operationStatus`, `cancel`, or `apkrun operations wait` for an unknown or expired ID | OperationRegistry | "That operation doesn't exist or has expired." | "List the current operations with: apkrun operations list" `none` | 4 | [runtime-api.md](runtime-api.md) §4.7, [../02-design/cli.md](../02-design/cli.md) §4.9 |
| `serviceUnavailable(ServiceUnavailableReason)` | `runtime.serviceUnavailable` | RuntimeClient can't reach the broker or an endpoint | RuntimeClient | "APKRun's background service isn't running." | "Restart the background service in Settings → Troubleshooting." `openTroubleshooting` | 69 | [runtime-api.md](runtime-api.md) §3.6 |
| — | `runtime.serviceUnavailable / notRegistered` | `SMAppService.status` is `notRegistered` or `notFound` | RuntimeClient, host checks | "APKRun's background service is not set up." | "Open APKRun once, or run: apkrun setup" `none` | 69 | §8.5 |
| — | `runtime.serviceUnavailable / requiresApproval` | `SMAppService.status == .requiresApproval` | RuntimeClient, host checks | "APKRun's background service is turned off in Login Items." | "Allow APKRun in System Settings → General → Login Items & Extensions." `openLoginItemsSettings` | 69 | [../02-design/host-ui.md](../02-design/host-ui.md) §4 (step 1) |
| `requestTimedOut(operation:)` | `runtime.requestTimedOut` | no reply within the operation's deadline plus 5 s | RuntimeClient | "APKRun's background service didn't answer in time." | "Try again." `retry` | 75 | [runtime-api.md](runtime-api.md) §4.6 |
| `developerModeRequired` | `runtime.developerModeRequired` | a developer-mode operation (`guestLog`, `frameStatistics`) while `developer.enabled` is off. The CLI shows `cli.developerModeRequired` instead | XPC server | "This needs developer mode." | "Turn on Developer mode in Settings → Advanced." `none` | 5 | [runtime-api.md](runtime-api.md) §6.3, §13.1, [configuration.md](configuration.md) |
| `unknownSetting(key)` | `runtime.unknownSetting` | a global settings key that does not exist | SettingsStore | "There is no setting named {key}." | "List the settings with: apkrun config list" `none` | 4 | [configuration.md](configuration.md) §8.1 |
| `invalidSettingValue(key, allowed)` | `runtime.invalidSettingValue` | a value of the wrong type or outside the allowed values | SettingsStore | "{key} can't be set to that value." | "Allowed values: {allowed}." `none` | 64 | [configuration.md](configuration.md) §8.1 |
| — | `runtime.invalidSettingValue / sharedFolders` | a patch or `config set` that touches `sharedFolders.roots` | SettingsStore | "Shared folders can't be changed with this command." | "Use apkrun shared-folders." `none` | 64 | [configuration.md](configuration.md) §8.1 |

- `runtime.serviceUnavailable / notRegistered` is the entry behind the text of [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.5. The CLI checks `SMAppService.status` before it connects and exits 69 with that text.
- The variant key `sharedFolders` of `invalidSettingValue` is a fixed key, not a sub-enum case. The fixture passes it explicitly.
- `runtime.serviceUnavailable` and `runtime.requestTimedOut` are raised by RuntimeClient ([runtime-api.md](runtime-api.md) §4.5). `ServiceUnavailableReason` has the cases `notRegistered`, `requiresApproval`, and `notRunning` (the base entry).

### 7.5 Sub-enums and parameters

| Type | Cases | Status | User text |
|---|---|---|---|
| `HostStartupStep` | `settings`, `maintenance`, `imageStore`, `packageStore`, `wrapperRegistry`, `services` | declared in §11. The degraded steps 4–7 and 9 of §2.2 | none: the cause is shown |
| `InstanceLockOwner` | `apkrund`, `apkrunDev` | declared in §11. §2.3 (`apkrun-dev` in the lock file) | variants of `runtime.instanceLocked` |
| `HostRequirement` | `appleSilicon`, `macOSVersion`, `virtualization`, `apfsVolume`, `freeDiskSpace(needed:)` | declared in §11. §9.1. Memory is a warning, not a requirement | the table below |
| `ServiceUnavailableReason` | `notRegistered`, `requiresApproval`, `notRunning` | declared in §11 | variants of `runtime.serviceUnavailable` |
| `AgentKind` | `guest`, `store` | [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §3 | `{agent}`: "Guest Agent", "Store Agent" |
| `BootPhase` | `kernel`, `init`, `systemServer`, `bootCompleted`, `agentsConnecting` | §3.3 | `{phase}`: "kernel", "init", "system server", "boot completed", "agent connection" |
| `ActivityKind` | `backgroundTask`, `storeOperation`, `diagnostics`, `migration`, `provisioning`, `adbClient`, `cli`, `boot` | §5.1 | not shown in the error. The GUI names the running app in its stop dialog |

`runtime.hostRequirementsNotMet` items (variant keys of the entry, texts from [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9.1 and [../02-design/diagnostics.md](../02-design/diagnostics.md) §7.3):

| Item | Hint line |
|---|---|
| `appleSilicon` | "APKRun needs a Mac with Apple silicon." |
| `macOSVersion` | "APKRun needs macOS 27 or later. Update macOS." |
| `virtualization` | "Virtualization is not available on this Mac (APKRun can't run inside a virtual machine)." |
| `apfsVolume` | "Move APKRun's data to an APFS volume." |
| `freeDiskSpace(needed:)` | "Free up {needed}." |

---

## 8. Domain `guestProtocol`

Owner: GuestProtocol. Design: [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §12. `GuestProtocolFailure` is declared only in prose (guest-protocol.md §12.3). The case list below is that list. Callers translate the failures they understand into their own domain (catalog §8.2). The rest reach users unchanged.

### 8.1 `GuestProtocolFailure`

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `incompatibleVersion(host, guest)` | `guestProtocol.incompatibleVersion` | the agent's major version is outside `supportedMajors`. The host sends `Rejected{INCOMPATIBLE_VERSION}`. During a boot the supervisor raises `runtime.agentIncompatible` instead | GuestConnection | "The {agent} in Android doesn't match this version of APKRun." | variants below | 1 | §5.2 |
| — | `guestProtocol.incompatibleVersion / hostNewer` | the agent is older than APKRun supports | GuestConnection | "Android needs an update to work with this version of APKRun." | "Update Android." `updateAndroid` | 1 | §5.2 |
| — | `guestProtocol.incompatibleVersion / guestNewer` | the agent is newer than APKRun supports | GuestConnection | "This version of Android needs a newer APKRun." | "Update APKRun." `updateAPKRun` | 1 | §5.2 |
| `handshakeFailed(reason)` | `guestProtocol.handshakeFailed` | `Hello` is invalid, or the handshake is rejected with `WRONG_CHANNEL`, `BAD_TOKEN`, or `DUPLICATE_SESSION` | GuestConnection | "APKRun couldn't connect to the {agent}." | "APKRun retries automatically. If it keeps failing, restart Android." `restartAndroid` | 1 | §5.1, §5.4 |
| `handshakeTimedOut` | `guestProtocol.handshakeTimedOut` | no `Hello` within 5 s of connecting | GuestConnection | "The {agent} didn't answer." | "APKRun retries automatically. If it keeps failing, restart Android." `restartAndroid` | 1 | §5.1 |
| `disconnected` | `guestProtocol.disconnected` | the connection closed while a request was outstanding | GuestConnection | "The connection to the {agent} was lost." | "APKRun reconnects automatically. Try again in a moment." `retry` | 75 | §13.1 |
| `timeout(operation)` | `guestProtocol.timeout` | no response within the operation's timeout, or the agent answered `TIMEOUT` | GuestConnection | "The {agent} didn't answer in time." | "Try again. If it happens again, restart Android." `retry` | 1 | §6 |
| `remote(code, message, operation)` | `guestProtocol.remote` | the agent answered a `GuestError` that the caller does not translate (catalog §8.2) | GuestConnection | "Android couldn't complete the request." | "Try again. If it fails again, create a diagnostics report." `retry` | 1 | §12.1 |
| — | `guestProtocol.remote / unavailable` | `UNAVAILABLE`: a system service in Android is not ready | GuestConnection | "Android isn't ready yet." | "Try again in a moment." `retry` | 1 | §12.1 |
| — | `guestProtocol.remote / permissionDenied` | `PERMISSION_DENIED`: Android refused (SecurityException) | GuestConnection | "Android didn't allow the request." | "Create a diagnostics report and report the problem." `reportProblem` | 1 | §12.1 |
| `frameTooLarge` | `guestProtocol.frameTooLarge` | a frame above the size limit (a protocol violation) | GuestConnection | "APKRun received data from Android that it couldn't read." | "APKRun reconnects automatically. If this keeps happening, report the problem." `reportProblem` | 70 | §4, §12.2 |
| `malformedFrame` | `guestProtocol.malformedFrame` | any other protocol violation of §12.2 | GuestConnection | "APKRun received data from Android that it couldn't read." | "APKRun reconnects automatically. If this keeps happening, report the problem." `reportProblem` | 70 | §12.2 |
| `capabilityMissing(capability)` | `guestProtocol.capabilityMissing` | the agent does not offer a capability that the request needs, or answered `UNSUPPORTED` | GuestConnection | "This version of Android doesn't support this feature ({capability})." | "Update Android." `updateAndroid` | 1 | §5.3 |
| `agentUnavailable(kind)` | `guestProtocol.agentUnavailable` | no connected agent of that kind | agent supervisor | "The {agent} in Android isn't connected." | "APKRun reconnects automatically. Try again in a moment." `retry` | 75 | §13.1 |

- `{agent}` is "Guest Agent" or "Store Agent" (catalog §3.2). `{code}` of `GuestError` and `message` are logged, never shown.
- Variant keys of `guestProtocol.remote` are the `GuestErrorCode` names in lowerCamelCase. Codes without a variant use the entry's text.
- Five violations within 10 minutes stop reconnecting. Health `agent.guest` or `agent.store` then fails with `runtime.requiredAgentUnavailable` (catalog §20.2, [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §12.2). There is no error code of its own.

### 8.2 Translation of `GuestError` by callers

The table lists the translations that callers perform. `GuestError.message` and `detail` go to the log in every case.

| Operation (guest-protocol.md §7.1, §11.1) | Guest answer | Result on the host | Ref |
|---|---|---|---|
| 14 `LaunchApplication` | `NOT_FOUND` | `runtime.packageNotInstalled` | §12.1 |
| 14 `LaunchApplication` | `TIMEOUT` | `runtime.launchTimedOut` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.1 |
| 14 `LaunchApplication` | any other code | `runtime.launchFailed` (the `GuestError` is the payload) | runtime-daemon.md §11 |
| 19 `QueryPackage` | `NOT_FOUND` | not an error: the package is absent (reconciliation) | [../02-design/package-store.md](../02-design/package-store.md) §9 |
| 41 `ActivateNotification` | `NOT_FOUND` | not an error: the notification is gone, and the host launches the app | §7.1 |
| 47 `SetTimeZone` | `NOT_FOUND`, `INVALID_ARGUMENT` | not an error: the time zone falls back to a fixed offset, and the health check `integrations.time` warns | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §9 |
| 48 `SyncTime` | `UNSUPPORTED` (development mode) | not an error: logged once | §7.1 |
| 50 `ResolveUrl` | `NOT_FOUND` | not an error: the kept intent expired after 60 s. Logged | §7.1 |
| 45 `ImportFiles`, 51 `ResolveExport` | `NOT_FOUND`, `INTERNAL`, `BulkAck{HASH_MISMATCH / TOO_LARGE / REJECTED}` | `integration.transferFailed` | desktop-integration.md §6 |
| 101 `BeginInstall` | `INVALID_ARGUMENT` | `store.capabilityMissing` when a field lacks its capability. Otherwise `guestProtocol.remote` (a bug in the host) | §11.3 |
| bulk `INSTALL_ARTIFACT` | `BulkAck{HASH_MISMATCH}` | `store.guestInstallFailed / aborted` | §11.3 |
| 102 `CommitInstall` → `InstallFinished` | `INVALID`, `CONFLICT`, … | `store.guestInstallFailed / <kind>`, `store.guestStorageFull`, `store.userActionRequired` (catalog §10.3) | package-store.md §6.4 |
| 104 `Uninstall` | `NOT_FOUND` | not an error: the store treats it as success | package-store.md §8 |
| 104 `Uninstall` | failure status | `store.uninstallFailed` | package-store.md §8 |
| 108 `RollbackPackage` | `NOT_AVAILABLE` | `store.rollbackUnavailable / expired`, or `/ notEnabled` when the update was installed without `enable_rollback` | package-store.md §7.3 |
| 108 `RollbackPackage` | `FAILURE` | `store.rollbackFailed` | package-store.md §7.3 |
| 109 `RelinquishUpdateOwnership` | `FAILED_PRECONDITION` | not an error: the Store Agent is not the update owner. The health check `store.ownership` warns | §11.1 |
| any | `UNSUPPORTED` | the caller's capability error: `store.capabilityMissing`, `integration.notSupportedOnImage`, or `guestProtocol.capabilityMissing` | §5.2 |
| any | `RESOURCE_EXHAUSTED` | `runtime.busy` | §14 |
| any | `CANCELLED` | the caller's `cancelled` (`runtime.cancelled`, `update.cancelled`, `maintenance.cancelled`) | §12.1 |
| any | `TIMEOUT` | `guestProtocol.timeout` | §12.1 |
| any other | — | `guestProtocol.remote`, with a variant where one exists | §12.1 |

### 8.3 Host answers to agent requests (ops 60–69)

The host serves `MacFilesProvider` (guest-protocol.md §7.5, [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6.4). It answers with a `GuestErrorCode`, and it logs the matching `integration.*` code with `err=` for health.

| Condition | Answer | Logged code |
|---|---|---|
| `integrations.sharedFolders` is `off` for the calling package | `PERMISSION_DENIED` | `integration.disabled` |
| path outside the root, containing `..`, hidden, or not a regular file or folder | `PERMISSION_DENIED` | `integration.pathRejected` |
| write, create, delete, or rename in a `readOnly` root, or with read-only package access | `PERMISSION_DENIED` | `integration.readOnly` |
| root missing, or macOS privacy controls deny access | `NOT_FOUND` / `PERMISSION_DENIED` | `integration.folderUnavailable` |
| root on a volume that is offline | `UNAVAILABLE` | `integration.folderUnavailable` |
| document or handle not found | `NOT_FOUND` | — |
| more than 64 open handles for the package | `RESOURCE_EXHAUSTED` | — |
| `length` or `data` above 1 MiB, or an unknown `page_token` | `INVALID_ARGUMENT` | — |
| a file system error | `INTERNAL` | `integration.transferFailed` |

`UNAVAILABLE` for an offline volume, `INVALID_ARGUMENT` for oversized ranges, and `NOT_FOUND` for unknown handles are chosen here. guest-protocol.md §7.5 names only `PERMISSION_DENIED`, `NOT_FOUND`, and `RESOURCE_EXHAUSTED`.

---

## 9. Domain `image`

Owner: ImageCore. Design: [../02-design/android-image.md](../02-design/android-image.md) §14.1. The verification steps are in [runtime-image-manifest.md](runtime-image-manifest.md) §7.1. Users see these errors in three places: inside `runtime.image` (transparent, catalog §7.2) before a boot, inside `maintenance.imageInstallFailed` (transparent, catalog §14.2) during an install, and as the cause of `maintenance.imageMigrationFailed` (catalog §14.2). "Android system" in the texts is the runtime image (host-ui.md §13).

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `manifestInvalid(path, reason)` | `image.manifestInvalid` | a size limit, the JSON, the schema, or a semantic rule S1–S14 fails (steps 1, 4–6, 8). `path` and `reason` are logged | ImageStore | "This Android system isn't valid." | "Install Android again from Settings → Storage." `openStorageSettings` | 1 | §3.3, §10.1 |
| `signatureInvalid(keyID)` | `image.signatureInvalid` | the Ed25519 signature of `manifest.json` does not verify (step 3) | ImageStore | "This Android system isn't signed correctly." | "Install Android only from APKRun's updates. Update Android in Settings → General." `updateAndroid` | 1 | §10.1 |
| `untrustedKey(keyID)` | `image.untrustedKey` | the key ID is not in `ImageTrustStore` (step 2) | ImageStore | "This Android system is signed with a key that APKRun doesn't trust." | "Install Android only from APKRun's updates. Update Android in Settings → General." `updateAndroid` | 1 | §10.1 |
| `hashMismatch(file)` | `image.hashMismatch` | a file's size (quick) or SHA-256 (full) differs from the manifest (steps 7, 8) | ImageStore | "Some Android system files are damaged." | "Install Android again from Settings → Storage. To check every file, run: apkrun doctor --deep" `openStorageSettings` | 1 | §9.3, §10.1 |
| `missingFile(file)` | `image.missingFile` | a file listed in `files` is missing (step 7) | ImageStore | "Some Android system files are missing." | "Install Android again from Settings → Storage. To check every file, run: apkrun doctor --deep" `openStorageSettings` | 1 | §10.1 |
| `unexpectedFile(file)` | `image.unexpectedFile` | a file not listed in `files` (step 7), or an install finds a different image directory of the same name ([runtime-image-manifest.md](runtime-image-manifest.md) §8.3 step 5) | ImageStore | "The Android system folder contains files that don't belong to it." | "Install Android again from Settings → Storage. To check every file, run: apkrun doctor --deep" `openStorageSettings` | 1 | §10.1 |
| `incompatibleRuntime(required)` | `image.incompatibleRuntime` | `minimumRuntimeVersion` is above the APKRun version, at activation or before a boot. `{version}` is `required` | ImageStore, AndroidBootPlanner | "This Android system needs APKRun {version} or later." | "Update APKRun." `updateAPKRun` | 1 | §9.3, §12.1, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.10 |
| `incompatibleProtocol(range)` | `image.incompatibleProtocol` | the image's `guestProtocol` range does not intersect the host's majors | ImageStore, AndroidBootPlanner | "This Android system doesn't work with this version of APKRun." | variants below | 1 | §9.3, §12.1 |
| — | `image.incompatibleProtocol / hostNewer` | the image's range ends below the host's lowest major | ImageStore | "Android needs an update to work with this version of APKRun." | "Update Android." `updateAndroid` | 1 | runtime-maintenance.md §4.10 |
| — | `image.incompatibleProtocol / guestNewer` | the image's range starts above the host's highest major | ImageStore | "This version of Android needs a newer APKRun." | "Update APKRun." `updateAPKRun` | 1 | runtime-maintenance.md §4.10 |
| `userdataSchemaUnsupported(instance, image)` | `image.userdataSchemaUnsupported` | the image's `upgradableFrom` lacks the instance's userdata schema | ImageStore | "This Android system can't use your existing Android data." | "Choose a newer Android system, or reset Android in Settings → Troubleshooting. Resetting erases all Android data." `openTroubleshooting` | 1 | §12.1 |
| `migrationSourceTooOld(minimum)` | `image.migrationSourceTooOld` | a manual activation of an image whose `compatibility.upgradeFrom.minimumImageVersion` is above the current image (C4). Provisioning a new instance doesn't check it. `{version}` is `minimum` | ImageStore | "This Android system can only replace Android {version} or later." | "Update Android in Settings → General first, then install this Android system again. Or reset Android in Settings → Troubleshooting. Resetting erases all Android data." `updateAndroid` | 1 | §12.1, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.2 |
| `downgradeRejected(from, to)` | `image.downgradeRejected` | an install or activation of a lower `imageVersion`. `{installedVersion}` is `from`, `{newVersion}` is `to` | ImageStore | "Android {newVersion} is older than the Android system in use ({installedVersion})." | "Keep the current Android system. To return to the previous one, use Go Back to Android in Settings → Storage." `openStorageSettings` | 5 | §12.1 |
| `insufficientSpace(required, available)` | `image.insufficientSpace` | less free space than an install, provisioning, or migration needs. `{needed}` is `required` | ImageStore, InstanceStore | "Android needs {needed} of free disk space, but only {available} is free." | "Free up disk space, then try again." `openStorageSettings` | 1 | §5.1, §12.3 |
| `cloneUnsupported(volume)` | `image.cloneUnsupported` | the Application Support volume is not APFS | InstanceStore | "APKRun's data is not on an APFS volume." | "Move APKRun's data to an APFS volume." `none` | 1 | §5.1 |
| `cloneFailed(errno)` | `image.cloneFailed` | `clonefile(2)` fails. `errno` becomes the `UnderlyingError` | InstanceStore | "Android's disks couldn't be created." | "Check the free disk space, then try again. If it fails again, create a diagnostics report." `retry` | 1 | §5.1, §12.2 |
| `instanceMissing` | `image.instanceMissing` | the instance disks or `instance.json` are missing after provisioning | InstanceStore | "Android's data is missing." | "Reset Android in Settings → Troubleshooting, or go back to a recovery point in Settings → Storage." `openTroubleshooting` | 1 | §9.3 step 2 |
| `instanceCorrupt(reason)` | `image.instanceCorrupt` | disk sizes or `instance.json` are inconsistent | InstanceStore | "Android's data is damaged." | "Reset Android in Settings → Troubleshooting, or go back to a recovery point in Settings → Storage." `openTroubleshooting` | 1 | §9.3 step 2 |
| `bootconfigConflict(key, layerA, layerB)` | `image.bootconfigConflict` | two bootconfig layers set one key without `overrides` | AndroidBootPlanner | "Android's start configuration isn't valid." | "Report the problem." `reportProblem` | 70 | §6.1 |
| `bootconfigTooLarge(size)` | `image.bootconfigTooLarge` | the serialized bootconfig is above 32 KiB | AndroidBootPlanner | "Android's start configuration isn't valid." | "Report the problem." `reportProblem` | 70 | §6.3, [runtime-image-manifest.md](runtime-image-manifest.md) §3.2 |
| `cmdlineTooLong(length)` | `image.cmdlineTooLong` | the kernel command line is above 2048 bytes | AndroidBootPlanner | "Android's start configuration isn't valid." | "Report the problem." `reportProblem` | 70 | §6.4 |
| `migrationHealthFailed(report)` | `image.migrationHealthFailed` | the first boot of B fails the health check of §12.3 step 5 (timeout, crash loop, failed check). `{version}` is B | RuntimeSupervisor | "Android {version} failed its first start after the update." | "APKRun restored the previous Android system. Report the problem so it can be fixed." `reportProblem` | 1 | §12.3 |
| `migrationInterrupted` | `image.migrationInterrupted` | apkrund starts and finds the `migration` field of `instance.json` (`migrating(A, B)`) with no VM running. `{version}` is B | ImageStore | "The update of Android to {version} was interrupted." | "APKRun restored the previous Android system. Report the problem so it can be fixed." `reportProblem` | 1 | §12.3 |
| `recoveryPointMissing` | `image.recoveryPointMissing` | a rollback or restore is requested without a recovery point | InstanceStore | "There is no recovery point to go back to." | "A recovery point exists only from an Android system update until the next one." `none` | 4 | §12.2, runtime-maintenance.md §4.8 |

- android-image.md §14.1 gives "reinstall the image" as the remediation. No `RemediationAction` installs an image again (catalog §22). The catalog uses `openStorageSettings`, where **Install from File…** is, for a damaged image, and `updateAndroid` for a signature problem. In development builds, trusting the developer's own key ([../02-design/android-image.md](../02-design/android-image.md) §10.1) is a setup step, not an error text.
- A `manifestInvalid` whose reason is "needs a newer APKRun" (an unknown `schemaVersion`, [runtime-image-manifest.md](runtime-image-manifest.md) §7.1 step 4) keeps the generic text. It is not converted to `incompatibleRuntime`, because the required version is unknown.
- The version-direction variant of `incompatibleProtocol` is chosen by the raiser (android-image.md §14.1).
- `insufficientSpace` exists in two domains. `image.insufficientSpace` is ImageCore's check. `maintenance.insufficientSpace` is the update coordinator's check before a download (catalog §14.2). The codes differ, so both can exist.
- The parameters `path`, `reason`, `keyID`, `file`, `report`, `key`, and `layerA`/`layerB` are logged and not shown. `{version}`, `{newVersion}`, and `{installedVersion}` are image versions.

### 9.1 Image errors implemented by #011 and #012

<!-- errorgen:begin image -->
| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `manifestInvalid(path:reason:)` | `image.manifestInvalid` | a size limit, the JSON, the schema, or a semantic rule fails. `path` and `reason` are logged | ImageCore | "This Android system isn't valid." | "Install Android again from Settings → Storage." `openStorageSettings` | 1 | [runtime-image-manifest.md](runtime-image-manifest.md) §7.1 |
| `insufficientSpace(required:available:)` | `image.insufficientSpace` | provisioning would leave less than the 10 GiB margin of free space. `{needed}` is `required` | InstanceStore | "Android needs {needed} of free disk space, but only {available} is free." | "Free up disk space, then try again." `openStorageSettings` | 1 | [../02-design/android-image.md](../02-design/android-image.md) §5.1, §5.2 |
| `cloneUnsupported(volume:)` | `image.cloneUnsupported` | the volume of the instance directory is not APFS, so `clonefile(2)` cannot share blocks | InstanceStore | "APKRun's data is not on an APFS volume." | "Move APKRun's data to an APFS volume." `none` | 1 | [../02-design/android-image.md](../02-design/android-image.md) §5.1 |
| `cloneFailed(underlying:)` | `image.cloneFailed` | `clonefile(2)`, `ftruncate`, or `fsync` of an instance disk fails. `errno` becomes the `UnderlyingError` | InstanceStore | "Android's disks couldn't be created." | "Check the free disk space, then try again. If it fails again, create a diagnostics report." `retry` | 1 | [../02-design/android-image.md](../02-design/android-image.md) §5.1 |
| `instanceCorrupt(reason:)` | `image.instanceCorrupt` | an instance disk's GPT does not verify, or disk sizes or `instance.json` are inconsistent. `reason` is logged | InstanceStore | "Android's data is damaged." | "Reset Android in Settings → Troubleshooting, or go back to a recovery point in Settings → Storage." `openTroubleshooting` | 1 | [../02-design/android-image.md](../02-design/android-image.md) §5, §9.3 step 2 |
| `instanceMissing` | `image.instanceMissing` | `instance.json` exists but an instance disk is missing | InstanceStore | "Android's data is missing." | "Reset Android in Settings → Troubleshooting, or go back to a recovery point in Settings → Storage." `openTroubleshooting` | 1 | [../02-design/android-image.md](../02-design/android-image.md) §9.3 step 2 |
| `missingFile(file:)` | `image.missingFile` | a file that the manifest lists is missing | ImageStore, AndroidBootPlanner | "Some Android system files are missing." | "Install Android again from Settings → Storage. To check every file, run: apkrun doctor --deep" `openStorageSettings` | 1 | [runtime-image-manifest.md](runtime-image-manifest.md) §7.1 |
| `hashMismatch(file:)` | `image.hashMismatch` | a file's size (quick check) or SHA-256 (full check) differs from the manifest | ImageStore | "Some Android system files are damaged." | "Install Android again from Settings → Storage. To check every file, run: apkrun doctor --deep" `openStorageSettings` | 1 | [runtime-image-manifest.md](runtime-image-manifest.md) §7.1 |
| `bootconfigConflict(key:layerA:layerB:)` | `image.bootconfigConflict` | two bootconfig layers set one key without an override. `key`, `layerA`, and `layerB` are logged | AndroidBootPlanner | "Android's start configuration isn't valid." | "Report the problem." `reportProblem` | 70 | [../02-design/android-image.md](../02-design/android-image.md) §6.1 |
| `bootconfigTooLarge(size:)` | `image.bootconfigTooLarge` | the serialized bootconfig is above 32 KiB or above the kernel's 1024 nodes | AndroidBootPlanner | "Android's start configuration isn't valid." | "Report the problem." `reportProblem` | 70 | [../02-design/android-image.md](../02-design/android-image.md) §6.3 |
| `cmdlineTooLong(length:)` | `image.cmdlineTooLong` | the kernel command line is above 2048 bytes | AndroidBootPlanner | "Android's start configuration isn't valid." | "Report the problem." `reportProblem` | 70 | [../02-design/android-image.md](../02-design/android-image.md) §6.4 |
| `untrustedKey(keyID:)` | `image.untrustedKey` | manifest.sig names a key ID that is not in ImageTrustStore | ImageSignature, ImageStore | "This Android system is signed by a key this Mac does not trust." | "Install Android again from the official source. In development, sign the bundle with a key this Mac trusts: python3 -m apkrun_image keygen, then bundle again." `openStorageSettings` | 1 | [runtime-image-manifest.md](runtime-image-manifest.md) §6.1 |
| `signatureInvalid(keyID:)` | `image.signatureInvalid` | the Ed25519 signature over manifest.json does not verify under the trusted key | ImageSignature, ImageStore | "The signature of this Android system does not match its contents." | "Install Android again from the official source. The files may have been changed after they were signed." `openStorageSettings` | 1 | [runtime-image-manifest.md](runtime-image-manifest.md) §6.1 |
| `unexpectedFile(file:)` | `image.unexpectedFile` | a bundle holds a file that its manifest does not list, or an installed image has the same name and a different manifest | ImageStore | "Some files in this Android system are not part of it." | "Install Android again from the official source. To check every file, run: apkrun doctor --deep" `openStorageSettings` | 1 | [runtime-image-manifest.md](runtime-image-manifest.md) §7.1 |
| `downgradeRejected(from:to:)` | `image.downgradeRejected` | an install or activation would move the current image back to an older version | ImageStore | "Android {to} is older than the installed Android {from}, so it was not installed." | "Install a newer Android system." `openStorageSettings` | 1 | [runtime-image-manifest.md](runtime-image-manifest.md) §2.3 |
| `imageNotInstalled(version:)` | `image.imageNotInstalled` | an activation names a version that has no directory under Images/ | ImageStore | "Android {version} is not installed." | "Install that Android system first, or choose one that is installed." `openStorageSettings` | 1 | [android-image.md](../02-design/android-image.md) §10.3 |
| `noCurrentImage` | `image.noCurrentImage` | a boot or a verification needs the current image, and Images/current does not exist | ImageStore | "No Android system is installed yet." | "Install an Android system from Settings → Storage. Developers run: apkrun dev image install <bundle>" `openStorageSettings` | 1 | [android-image.md](../02-design/android-image.md) §9.3 |
<!-- errorgen:end image -->

---

## 10. Domain `store`

Owner: APKStoreCore. Design: [../02-design/package-store.md](../02-design/package-store.md) §12. The same failures reach users of manual and provider updates inside `update.intrinsic`, `update.installFailed`, and `update.rollbackFailed` (catalog §11). `{file}` is the file's name inside the set, never a path (package-store.md §12).

### 10.1 Import and inspection

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `unsupportedContainer(ContainerKind)` | `store.unsupportedContainer` | I1: the content is not a supported container (`.unknown`) | ContainerReader | "APKRun can't add this kind of file." | "APKRun can add .apk, .apks, .xapk, and .apkm files, and .zip files that contain only APKs." `none` | 1 | §4.2 |
| — | `store.unsupportedContainer / appBundle` | an `.aab` (ZIP with `BundleConfig.pb`) | ContainerReader | "This file is an Android App Bundle (.aab), which can't be installed directly." | "Get an .apk or .apks file from the app's developer. Converting a bundle would change its signature and break updates." `none` | 1 | §4.2 |
| — | `store.unsupportedContainer / encryptedAPKM` | an encrypted or non-ZIP `.apkm` | ContainerReader | "This .apkm file is encrypted." | "Download the app as an unencrypted file, for example an .apk." `none` | 1 | §4.2 |
| `unreadableArchive(detail:)` | `store.unreadableArchive` | the ZIP structure can't be read | ContainerReader | "This file couldn't be read. It may be damaged or incomplete." | "Download the file again." `none` | 1 | §4.2 |
| `archiveLimitExceeded(ArchiveLimit)` | `store.archiveLimitExceeded` | an extraction limit is violated (zip-bomb and path safety) | ContainerReader | "This file contains more than APKRun can safely unpack." | variants below | 1 | §4.2 |
| — | `store.archiveLimitExceeded / entryCount` | more than 512 entries | ContainerReader | "This file contains more than 512 entries." | "Download the app again from its developer." `none` | 1 | §4.2 |
| — | `store.archiveLimitExceeded / apkCount` | more than 256 APKs | ContainerReader | "This file contains more than 256 APKs." | "Download the app again from its developer." `none` | 1 | §4.2 |
| — | `store.archiveLimitExceeded / fileSize` | an extracted file above 2 GiB | ContainerReader | "A file inside is larger than 2 GB." | "Download the app again from its developer." `none` | 1 | §4.2 |
| — | `store.archiveLimitExceeded / totalSize` | extracted files above 8 GiB in total | ContainerReader | "The files inside are larger than 8 GB in total." | "Download the app again from its developer." `none` | 1 | §4.2 |
| — | `store.archiveLimitExceeded / compressionRatio` | an entry above 100:1 | ContainerReader | "This file is compressed in a way that isn't safe to unpack." | "Download the app again from its developer." `none` | 1 | §4.2 |
| — | `store.archiveLimitExceeded / unsafeName` | a name that is not UTF-8 or relative, contains `..`, or is a symlink or device entry | ContainerReader | "This file contains entries with unsafe names." | "Download the app again from its developer." `none` | 1 | §4.2 |
| `notAnAPK(file:)` | `store.notAnAPK` | I2: a file has no `AndroidManifest.xml` | APKInspector | "{file} isn't an Android app (APK)." | "Choose the app's .apk, .apks, .xapk, or .apkm file." `none` | 1 | §4.6 |
| `missingBase` | `store.missingBase` | I3: no base APK | ArtifactVerifier | "The base APK is missing from this set." | "Add the base APK too, or use the complete .apks, .xapk, or .apkm file." `none` | 1 | §4.4, §4.6 |
| `multipleBases` | `store.multipleBases` | I3: more than one base | ArtifactVerifier | "This set contains more than one base APK." | "Add the APKs of one app version only." `none` | 1 | §4.6 |
| `duplicateSplit(name:)` | `store.duplicateSplit` | I3: a split name appears twice. `{split}` is the name | ArtifactVerifier | "The split {split} appears more than once." | "Add each split APK only once." `none` | 1 | §4.6 |
| `inconsistentSplits(InconsistentField, file:)` | `store.inconsistentSplits` | I4, I5: the APKs differ in package, version, or signer | ArtifactVerifier | "The APKs in this set don't belong together." | "Add the APKs of one app version from one source." `none` | 1 | §4.6 |
| — | `store.inconsistentSplits / package` | a file of another package | ArtifactVerifier | "{file} belongs to another app." | "Add the APKs of one app version from one source." `none` | 1 | §4.6 |
| — | `store.inconsistentSplits / versionCode` | a file of another `VersionCode` | ArtifactVerifier | "{file} is from another version of the app." | "Add the APKs of one app version from one source." `none` | 1 | §4.6 |
| — | `store.inconsistentSplits / signer` | a file with another signer set | ArtifactVerifier | "{file} is signed by a different developer." | "Add the APKs of one app version from one source." `none` | 1 | §4.6 |
| `incompleteSplitSet(missing:)` | `store.incompleteSplitSet` | I6: `requiredSplitTypes` or `isSplitRequired` not satisfied. `{split}` lists the missing types | SplitSelector | "This set is missing parts that the app needs: {split}." | "Use the complete .apks, .xapk, or .apkm file of the app." `none` | 1 | §4.4 |
| `unsignedAPK(file:)` | `store.unsignedAPK` | I5: no signature | APKSignatureVerifier | "{file} isn't signed." | "Android installs only signed apps. Get a signed copy from the app's developer." `none` | 1 | §4.5 |
| `invalidSignature(file:reason:)` | `store.invalidSignature` | I5: a digest or signature does not verify, and the Store Agent's `InspectArchive` agrees or can't be asked | APKSignatureVerifier | "The signature of {file} isn't valid." | "The file may have been changed after signing. Download it again from the app's developer." `none` | 1 | §4.5 |
| `legacySignatureNotAllowed(targetSdk:)` | `store.legacySignatureNotAllowed` | I5: v1 signature only, and `targetSdk ≥ 30`. `{target}` is `targetSdk` | APKSignatureVerifier | "This app uses an old signature format that Android doesn't accept for apps that target API {target}." | "Get a newer build of the app from its developer." `none` | 1 | §4.5 |
| `unsupportedABI(found:supported:)` | `store.unsupportedABI` | I7: native code for no guest ABI | ArtifactVerifier | "This app is built only for {found}, but Android in APKRun needs {supported}." | "Get a build of the app for {supported}." `none` | 1 | §4.6 |
| `minSdkTooHigh(required:guest:)` | `store.minSdkTooHigh` | I8: `minSdkVersion` above the guest SDK | ArtifactVerifier | "This app needs Android API {required} or later. Android in APKRun has API {guest}." | "Update Android, or get an older build of the app." `updateAndroid` | 1 | §4.6 |
| `targetSdkTooLow(target:floor:)` | `store.targetSdkTooLow` | I9: `targetSdkVersion` below the install floor | ArtifactVerifier | "This app targets API {target}. Android in APKRun installs only apps that target API {floor} or later." | "Get a newer build of the app from its developer." `none` | 1 | §4.6 |
| `expansionFilesNotSupported` | `store.expansionFilesNotSupported` | an `.xapk` with expansions (OBB) | ContainerReader | "This file includes expansion files (OBB), which APKRun doesn't support yet." | "Get a build of the app without expansion files." `none` | 1 | §4.2 |
| `reservedPackage(PackageID)` | `store.reservedPackage` | I10: `io.apkrun.guest`, `io.apkrun.store`, or a platform package of the image | ArtifactVerifier | "{package} is part of Android or APKRun and can't be added as an app." | "No action is needed." `none` | 5 | §4.6 |
| `tooLarge(bytes:limit:)` | `store.tooLarge` | I11: a file above 2 GiB, or the set above 8 GiB | ArtifactVerifier | "This app is too large ({bytes}; the limit is {limit})." | "Get a smaller build of the app, for example one for fewer device types." `none` | 1 | §4.6 |
| `resourcesArscNotAligned(file:)` | `store.resourcesArscNotAligned` | I12: `targetSdk ≥ 30`, and `resources.arsc` in `{file}` is compressed or not 4-byte aligned | ArtifactVerifier | "{file} isn't packaged the way Android requires for apps that target API 30 or later." | "Get a build of the app made with current Android build tools from its developer." `none` | 1 | §4.6 |
| `insufficientHostSpace(needed:available:)` | `store.insufficientHostSpace` | free space below 2 × source size + 2 GiB before an import, or below 2 GiB (the `store.hostSpace` error) | PackageStore | "There isn't enough free disk space to add this app ({needed} needed, {available} free)." | "Free up disk space, then try again." `openStorageSettings` | 1 | §3.4 |
| `importExpired(ImportTicket)` | `store.importExpired` | `installImported` or `cancelImport` names a ticket that no longer exists (cancelled, removed at the next start, or garbage-collected) | PackageStore | "This import has expired." | "Add the file again." `none` | 1 | §5.4 step 5 |

- The import warnings of §4.6 are not errors. They are listed in catalog §17.9.
- A false rejection by the host verifier is corrected before `invalidSignature` is raised: the importer asks the Store Agent when the runtime is ready and logs `verifier.disagreement` (§4.5).

### 10.2 Relation to an installed package

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `alreadyInstalled(VersionCode)` | `store.alreadyInstalled` | `ImportRelation.sameAsInstalled`: the same set digest is installed. A warning (catalog §3.6) | PackageStore | "{app} {version} is already installed." | "No action is needed." `none` | 0 | §4.7 |
| `downgradeRefused(installed:candidate:)` | `store.downgradeRefused` | `ImportRelation.downgrade` (FR-UPD-05) | PackageStore | "{app} {newVersion} is older than the installed version {installedVersion}." | "Keep the installed version, or uninstall {app} first." `none` | 5 | §4.7, [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.2 |
| `signerMismatch` | `store.signerMismatch` | `ImportRelation.otherSigner` | PackageStore | "This file is signed by a different developer than the installed app." | "Install updates of {app} from its original developer, or uninstall {app} first." `none` | 5 | §4.7 |

- The text of `store.downgradeRefused` is the example of diagnostics.md §2.2. package-store.md §4.7 uses the same text.
- An import of a newer version (`ImportRelation.update`) goes to UpdateCore. Its failures are `update.*` (catalog §11). The downgrade and signer texts of `update.downgrade` and `update.signerMismatch` equal the texts above.

### 10.3 Install results from Android

`InstallFinished.status` maps to these entries (§6.4). `androidStatus`, `legacyStatus`, and `message` are logged and shown under Details, never in the message.

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `guestInstallFailed(InstallFailureKind, androidStatus:legacyStatus:message:)` | `store.guestInstallFailed` | `FAILURE` (`.other`), and the base of the variants | PackageStore | "Android couldn't install {app}." | "Try again. If it fails again, create a diagnostics report." `retry` | 1 | §6.4 |
| — | `store.guestInstallFailed / conflict` | `CONFLICT` | PackageStore | "Android refused {app} because it conflicts with an installed app." | "Uninstall the conflicting app, then try again." `none` | 1 | §6.4 |
| — | `store.guestInstallFailed / incompatible` | `INCOMPATIBLE`. Also logs `store.hostCheckMissed` | PackageStore | "{app} is not compatible with this version of Android." | "Report the problem, so that APKRun can detect this before the install." `reportProblem` | 1 | §6.4 |
| — | `store.guestInstallFailed / invalid` | `INVALID`, or the Store Agent's pre-commit check found another package, version, or signer | PackageStore | "The app file is damaged or isn't what was expected." | "Download the app again, then try again." `none` | 1 | §6.4 |
| — | `store.guestInstallFailed / blocked` | `BLOCKED`: policy or system package | PackageStore | "Android does not allow installing {app}." | "If you think this is wrong, report the problem." `reportProblem` | 1 | §6.4 |
| — | `store.guestInstallFailed / aborted` | `ABORTED`, or `BulkAck{HASH_MISMATCH}` during the transfer (catalog §8.2) | PackageStore | "Installation was interrupted." | "Try again." `retry` | 1 | §6.4 |
| `guestStorageFull` | `store.guestStorageFull` | `STORAGE` | PackageStore | "Android is out of storage." | "Increase Android storage in Settings → Runtime." `openRuntimeSettings` | 1 | §3.4, §6.4 |
| `userActionRequired` | `store.userActionRequired` | `USER_ACTION_REQUIRED`. Not expected for a privileged installer. Logged as a bug | PackageStore | "Android asked for confirmation, which APKRun does not support." | "Report the problem." `reportProblem` | 1 | §6.4 |

### 10.4 Operations

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `packageNotFound(PackageID)` | `store.packageNotFound` | a store operation names a package without a record | PackageStore | "{package} isn't in APKRun." | "Check the package ID. To list the apps, run: apkrun list" `none` | 4 | §11.1 |
| `operationInProgress(PackageID)` | `store.operationInProgress` | a second transaction for the same package, or `openSession` waited 30 s for one ([runtime-api.md](runtime-api.md) §6.5) | PackageStore | "APKRun is already working on {app}." | "Try again when it has finished." `retry` | 75 | §5.3 |
| `packageInUse(PackageID)` | `store.packageInUse` | `installStaged` finds a session of the package | PackageStore | "{app} is open." | "Close {app}, then try again." `retry` | 75 | §7.2 |
| `uninstallFailed(detail:)` | `store.uninstallFailed` | `Uninstall` fails with a status other than `NOT_FOUND` | PackageStore | "Android couldn't uninstall {app}." | "Try again. If Android can't start, choose Remove from APKRun instead." `retry` | 1 | §8 |
| `rollbackUnavailable(RollbackUnavailableReason)` | `store.rollbackUnavailable` | the base text for a reason without a variant | PackageStore | "APKRun can't restore the previous version of {app}." | "Keep the current version." `none` | 1 | §7.3 |
| — | `store.rollbackUnavailable / noPreviousSet` | `previous/` does not exist | PackageStore | "There is no previous version of {app} to restore." | "APKRun keeps the previous version only after an update." `none` | 1 | §7.3 |
| — | `store.rollbackUnavailable / notEnabled`, `/ expired`, `/ capabilityMissing` | no Android rollback exists (installed without `enable_rollback`, expired after about 14 days, or no rollback capability), and `allowDataLoss` is false | PackageStore | "APKRun can restore {app} {oldVersion} only by erasing the app's data." | "To restore it and erase its data, run: apkrun rollback {package} --allow-data-loss" `none` | 1 | §7.3, [../02-design/update-system.md](../02-design/update-system.md) §8.3 |
| `rollbackFailed(detail:)` | `store.rollbackFailed` | the rollback transaction fails. The package becomes `broken` | PackageStore | "APKRun couldn't restore {app}." | "Repair {app} on its page in APKRun." `reinstallApp` | 1 | §7.3, update-system.md §8.3 |
| `runtimeUnavailable(RuntimeFailure)` | `store.runtimeUnavailable` | an operation needs Android, and `ensureReady` fails | PackageStore | (cause) | (cause) | cause | §6.2 |
| `capabilityMissing(String)` | `store.capabilityMissing` | the channel lacks a capability that the request needs (for example `.rollback`, update ownership on the ADB channel), or `BeginInstall` answers `INVALID_ARGUMENT` for such a field | PackageStore | "This version of Android doesn't support this ({capability})." | "Update Android." `updateAndroid` | 1 | §6.1, [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §11.3 |
| `unknownSetting(key)` | `store.unknownSetting` | a package settings key that does not exist | PackageStore | "There is no app setting named {key}." | "List the app's settings with: apkrun settings {package} list" `none` | 4 | [configuration.md](configuration.md) §8.1 |
| `invalidSettingValue(key, allowed)` | `store.invalidSettingValue` | a package settings value of the wrong type or outside the allowed values | PackageStore | "{key} can't be set to that value." | "Allowed values: {allowed}." `none` | 64 | [configuration.md](configuration.md) §8.1 |

- In the GUI, `rollbackUnavailable / notEnabled` is not shown as an error. The client asks "Restoring {app} {oldVersion} requires deleting its data. Continue?" and repeats the call with `allowDataLoss: true` (§11.1).
- **Remove from APKRun** and `apkrun uninstall --forget` run `forget`, which does not need Android (§8).

### 10.5 Store integrity

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `journalUnreadable(line:)` | `store.journalUnreadable` | `journal.jsonl` can't be read beyond a torn last line, or has a newer `v`. The whole store is read-only | PackageStore | "APKRun's record of app changes is damaged." | "Apps can't be added, updated, or removed until this is fixed. Create a diagnostics report and report the problem." `reportProblem` | 1 | §5.4 |
| `metadataUnreadable(PackageID, detail:)` | `store.metadataUnreadable` | a `metadata.json` can't be read, or a package's `metadata.json` or `settings.json` has a newer `schemaVersion`. That package is read-only | PackageStore | "APKRun can't read its records for {app}." | "If a newer version of APKRun was used before, install that version again. Otherwise report the problem." `reportProblem` | 1 | §5.4 |
| `storeReadOnly(reason:)` | `store.storeReadOnly` | a write operation while the store or the package is read-only | PackageStore | "Apps can't be added, updated, or removed right now." | "Open Settings → Troubleshooting for details." `openTroubleshooting` | 1 | §5.4 |

A journal with a newer `v` also makes the host startup step `packageStore` degraded with `maintenance.dataCreatedByNewerVersion` (catalog §14.1).

### 10.6 Sub-enums

| Type | Cases | Status | User text |
|---|---|---|---|
| `ContainerKind` | `appBundle`, `encryptedAPKM`, `unknown` | declared in §12 (comment) | variants of `store.unsupportedContainer`. `unknown` uses the entry's text |
| `ArchiveLimit` | `entryCount`, `apkCount`, `fileSize`, `totalSize`, `compressionRatio`, `unsafeName` | declared in §12. The limits of §4.2 | variants of `store.archiveLimitExceeded` |
| `InconsistentField` | `package`, `versionCode`, `signer` | declared in §12. §4.6 I4, I5 | variants of `store.inconsistentSplits` |
| `InstallFailureKind` | `conflict`, `incompatible`, `invalid`, `blocked`, `aborted`, `other` | declared in §12. §6.4 | variants of `store.guestInstallFailed`. `other` uses the entry's text |
| `RollbackUnavailableReason` | `noPreviousSet`, `notEnabled`, `expired`, `capabilityMissing` | declared in §12 (comment) | variants of `store.rollbackUnavailable` |

---

## 11. Domain `update`

Owner: UpdateCore. Design: [../02-design/update-system.md](../02-design/update-system.md) §13. Most update failures are not shown as dialogs. They are recorded in `UpdateOutcome` (catalog §17.5), in the update history, in the package settings ("last check time and result", §9), and in health (catalog §20.2). They are shown as errors for user-initiated updates (**Update Now**, `apkrun update <package>`, a manual update). "update source" is the user word for a provider (catalog §3.3).

### 11.1 `UpdateFailure`

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `providerUnreachable(detail:)` | `update.providerUnreachable` | the provider's host can't be reached | provider | "APKRun couldn't reach the update source of {app}." | "Check the network connection. APKRun tries again later." `retry` | 1 | §3.2, §4 |
| `providerHTTPStatus(Int)` | `update.providerHTTPStatus` | a non-2xx status that is not a rate limit. `{code}` is the status | provider | "The update source of {app} answered with HTTP status {code}." | "APKRun tries again later. If this continues, check the update source in the app's settings." `retry` | 1 | [direct-provider-manifest.md](direct-provider-manifest.md) |
| `providerRateLimited(retryAfter:)` | `update.providerRateLimited` | `429`, `503` with `Retry-After`, or GitHub's `x-ratelimit-remaining: 0` | provider | "The update source of {app} is limiting requests." | "APKRun tries again later." `none` | 75 | §4.6 |
| `providerMetadataInvalid(detail:)` | `update.providerMetadataInvalid` | the provider's metadata breaks its format rules (for example D1–D8 of the Direct manifest) | provider | "The update information for {app} isn't valid." | "Check the update source in the app's settings." `none` | 1 | [direct-provider-manifest.md](direct-provider-manifest.md) |
| `providerSignatureInvalid` | `update.providerSignatureInvalid` | the F-Droid index signature or fingerprint check fails. No update comes from that repository | F-Droid provider | "The signature of the update source's index isn't valid." | "APKRun doesn't use this source until its signature is valid. Check the repository fingerprint in the app's settings." `none` | 1 | §4.5 |
| `providerNotConfigured` | `update.providerNotConfigured` | an `apkrun` package without a usable provider configuration, or a stored configuration that breaks the provider rules ([package-metadata-json.md](package-metadata-json.md) §2.4) | UpdateCoordinator | "No update source is set up for {app}." | "Choose an update source in the app's settings." `none` | 1 | [direct-provider-manifest.md](direct-provider-manifest.md) |
| — | `update.providerNotConfigured / invalidSpec` | `setUpdatePolicy` or `install --provider` gets a provider spec that does not parse or breaks the rules. Nothing is written | UpdateCoordinator | "The update source you entered isn't valid." | "Use direct:<https URL>, fdroid[:<URL>#<fingerprint>], github:<owner>/<name>, or local:<path>." `none` | 1 | [package-metadata-json.md](package-metadata-json.md) §2.4 |
| `noCompatibleArtifact(NoArtifactReason)` | `update.noCompatibleArtifact` | versions exist, but none fits. The check returns no candidate and records this failure | provider | "The update source has no version of {app} that works in APKRun." | variants below | 1 | §4.5 |
| — | `update.noCompatibleArtifact / abi` | no version has native code for a guest ABI | provider | "The update source has no build of {app} for Android in APKRun." | "Choose another update source in the app's settings." `none` | 1 | §4.5 |
| — | `update.noCompatibleArtifact / sdk` | the newer versions need a higher `minSdkVersion` | provider | "The newer versions of {app} need a newer Android." | "Update Android." `updateAndroid` | 1 | §4.5 |
| — | `update.noCompatibleArtifact / signerDiffers` | no version has the installed signer | provider | "The update source's builds of {app} are signed by a different developer than the installed copy." | "To use this source, uninstall {app} and install it from the source." `none` | 1 | §4.5 |
| `ambiguousAsset([String])` | `update.ambiguousAsset` | a GitHub release has several matching APK assets | GitHub provider | "The update source's release of {app} has more than one matching APK." | "Set an asset pattern for the GitHub source in the app's settings." `none` | 1 | §4.6 |
| `downloadFailed(detail:)` | `update.downloadFailed` | a network error after two retries (10 s, 60 s) | UpdateCoordinator | "The update of {app} couldn't be downloaded." | "Check the network connection. APKRun tries again later." `retry` | 1 | §5 |
| `hashMismatch(file:)` | `update.hashMismatch` | the streamed SHA-256 differs from the declared one twice | UpdateCoordinator | "The downloaded update of {app} is damaged." | "APKRun tries again later." `retry` | 1 | §5 |
| `tooLarge(bytes:)` | `update.tooLarge` | the downloads exceed 8 GiB | UpdateCoordinator | "The update of {app} is too large ({bytes}; the limit is 8 GB)." | "Get a smaller build of the app from its developer." `none` | 1 | §5 |
| `validation(ValidationFailure)` | `update.validation` | a check of the validation pipeline fails (catalog §11.2) | UpdateValidator | (cause) | (cause) | cause | §6 |
| `authorityDoesNotAllowUpdates(UpdateAuthority)` | `update.authorityDoesNotAllowUpdates` | an update request for a package whose authority does not allow it | UpdateCoordinator | "APKRun doesn't update {app}." | variants below | 1 | §2.1 |
| — | `update.authorityDoesNotAllowUpdates / manual` | a provider check or update of a `manual` package | UpdateCoordinator | "APKRun updates {app} only from files that you add." | "Add a newer file, or choose an update source in the app's settings." `none` | 1 | §2.1 |
| — | `update.authorityDoesNotAllowUpdates / googlePlay` | a `googlePlay` package | UpdateCoordinator | "Google Play manages the updates of {app}." | "Update {app} in Google Play." `none` | 1 | §2.1 |
| — | `update.authorityDoesNotAllowUpdates / external` | an `external` package | UpdateCoordinator | "Another app store in Android manages the updates of {app}." | "Update {app} in that app store, or change who updates it in the app's settings." `none` | 1 | §2.1 |
| `installFailed(StoreFailure)` | `update.installFailed` | the store transaction of the update fails | UpdateCoordinator | (cause) | (cause) | cause | §7 |
| `healthCheckFailed(HealthCheckFailure)` | `update.healthCheckFailed` | a step H1–H4 fails (catalog §11.3). The cause names the step | UpdateHealthChecker | "{app} {newVersion} didn't start correctly." | "With automatic rollback on, APKRun restores the previous version. Otherwise use Roll Back in the app's settings." `none` | 1 | §8.1, §8.3 |
| `rollbackFailed(StoreFailure)` | `update.rollbackFailed` | the rollback after a failed health check fails. The package is `broken` | UpdateCoordinator | "APKRun couldn't restore {app}." | "Repair {app} on its page in APKRun." `reinstallApp` | 1 | §8.3 |
| `cancelled` | `update.cancelled` | the user cancelled, or Android answered `CANCELLED` | UpdateCoordinator | "The update was cancelled." | — `none` | 130 | §5 |

- `update.authorityDoesNotAllowUpdates` has no variant for `apkrun`, because that authority allows updates. `UpdateAuthority` is declared in update-system.md §2.1.
- For an `external` package, the GUI asks to switch the authority to `manual` before a user-supplied file is installed (§2.1). The error is what the CLI and a declined switch show.

### 11.2 `ValidationFailure`

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `intrinsic(StoreFailure)` | `update.intrinsic` | V0: an intrinsic check I1–I12 fails (catalog §10.1) | UpdateValidator | (cause) | (cause) | cause | §6 |
| `packageMismatch(expected:found:)` | `update.packageMismatch` | V1: the APK is for another package | UpdateValidator | "The update is for {found}, not for {package}." | "Check the update source in the app's settings." `none` | 1 | §6 |
| `notNewer(installed:candidate:)` | `update.notNewer` | V2: the candidate's versionCode equals the installed one | UpdateValidator | "{app} {newVersion} isn't newer than the installed version." | "No action is needed." `none` | 1 | §6 |
| `downgrade(installed:candidate:)` | `update.downgrade` | V2: a lower versionCode (FR-UPD-05) | UpdateValidator | "{app} {newVersion} is older than the installed version {installedVersion}." | "Keep the installed version, or uninstall {app} first." `none` | 5 | §6 |
| `signerMismatch` | `update.signerMismatch` | V3: the signer set differs, and no accepted rotation exists. Posts "Update refused" | UpdateValidator | "This file is signed by a different developer than the installed app." | "Install updates of {app} from its original developer, or uninstall {app} first." `none` | 5 | §6, §9 |
| `lineageMissingCapability` | `update.lineageMissingCapability` | V3: the lineage lacks `INSTALLED_DATA` (rotation) or `ROLLBACK` (undo) | UpdateValidator | "The update of {app} is signed with a new key that the old key didn't authorize." | "APKRun doesn't install it. Contact the app's developer." `none` | 5 | §6 |
| `providerHashMismatch(file:)` | `update.providerHashMismatch` | V4: a file's SHA-256 differs from the digest that the provider declared | UpdateValidator | "The update of {app} doesn't match what its source declared." | "APKRun doesn't install it. If this continues, the update source may be compromised." `none` | 1 | §6 |
| `providerMetadataMismatch(field:)` | `update.providerMetadataMismatch` | V5: the provider's package, versionCode, or signer disagrees with the APK. Posts "Update refused" | UpdateValidator | "The update information for {app} doesn't match the downloaded file ({field})." | "APKRun doesn't install it. The update source may be out of date or compromised." `none` | 1 | §6, §9 |
| `skippedVersion(VersionCode)` | `update.skippedVersion` | V6: the version is in `skippedVersions`, and the user did not choose it | UpdateValidator | "{app} {newVersion} was skipped." | "To install it, choose Try Again for this version in the app's update history." `none` | 1 | §8.4 |

- The texts of `update.downgrade` and `update.signerMismatch` equal those of `store.downgradeRefused` and `store.signerMismatch` (catalog §10.2), so a manual update and a first import say the same.
- A provider download that differs from the declared hash fails while it streams, with `update.hashMismatch` (update-system.md §5). `update.providerHashMismatch` (V4) hashes the stored files again, so it fails only for a file that changed after the download (update-system.md §6).

### 11.3 `HealthCheckFailure`

These entries are the causes of `update.healthCheckFailed`. They have no remediation of their own. The outer entry's remediation is shown.

| Case | Code | When raised | Message | Action | Exit | Ref |
|---|---|---|---|---|---|---|
| `versionNotConfirmed(found:)` | `update.versionNotConfirmed` | H1: Android does not report the staged versionCode and signer within 30 s | "After the update, Android didn't report the new version of {app}." | `none` | 1 | §8.1 |
| `launchFailed` | `update.launchFailed` | H2: `LaunchApplication` fails or takes more than 20 s | "{app} couldn't be opened after the update." | `none` | 1 | §8.1 |
| `processDied(ProcessDeath)` | `update.processDied` | H3: the process is gone 5 s after the launch | "{app} stopped right after it opened." | `none` | 1 | §8.1 |
| — | `update.processDied / crash` | H3: a crash by 15 s | "{app} crashed right after it opened." | `none` | 1 | §8.1 |
| — | `update.processDied / anr` | H3: an ANR by 15 s | "{app} stopped responding right after it opened." | `none` | 1 | §8.1 |
| `noFirstFrame` | `update.noFirstFrame` | H4: no frame within 20 s after H2 | "{app} didn't show anything after it opened." | `none` | 1 | §8.1 |

| Type | Cases | Status |
|---|---|---|
| `NoArtifactReason` | `abi`, `sdk`, `signerDiffers` | declared in §13 (comment) |
| `HealthCheckFailure` | `versionNotConfirmed(found:)`, `launchFailed`, `processDied(ProcessDeath)`, `noFirstFrame` | declared in §13 |
| `ProcessDeath` | `crash`, `anr` | declared in §13 |

---


## 12. Domain `wrapper`

Owners: WrapperCore (in apkrund) and APKRunLauncher. Design: [../02-design/wrapper.md](../02-design/wrapper.md) §13. URL payloads are passed as `{file}`, the last path component (catalog §3.2). Store and runtime errors that pass through wrapper operations (for example `store.downgradeRefused` from `importBootstrap`) keep their own codes (§13). The launcher screens that these entries drive are mapped in catalog §18.

### 12.1 Generation and lifecycle

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `packageNotInstalled(PackageID)` | `wrapper.packageNotInstalled` | `createWrapper` for a package that is not installed, or `apkrun wrap <file>` without `--install` and without a terminal for the question | AppWrapperGenerator, CLI | "{app} isn't installed in APKRun." | "Install {app} first. apkrun wrap installs it too when you add --install." `none` | 4 | §6.2, §12.2 |
| `invalidName(String)` | `wrapper.invalidName` | a user-chosen name (name field, `--name`) is empty after the rules of §4.3 | AppWrapperGenerator | "This name can't be used for a Mac app." | "Choose a name that contains letters or digits." `none` | 64 | §4.3, §6.2 step 1 |
| `customIconInvalid(IconInputProblem)` | `wrapper.customIconInvalid` | a chosen icon file fails the input rules of §8.2 | AppWrapperGenerator | "This image can't be used as an icon." | variants below | 1 | §8.2 |
| — | `wrapper.customIconInvalid / unreadable` | the file can't be read or decoded | AppWrapperGenerator | "APKRun can't read this image." | "Choose a PNG, JPEG, HEIC, or .icns file." `none` | 1 | §8.2 |
| — | `wrapper.customIconInvalid / notSquare` | width and height differ | AppWrapperGenerator | "This image isn't square." | "Choose a square image of at least 512 × 512 pixels." `none` | 1 | §8.2 |
| — | `wrapper.customIconInvalid / tooSmall` | smaller than 512 px | AppWrapperGenerator | "This image is smaller than 512 × 512 pixels." | "Choose a square image of at least 512 × 512 pixels." `none` | 1 | §8.2 |
| `iconConversionFailed(String)` | `wrapper.iconConversionFailed` | `iconutil` fails. Its status and message are logged | AppWrapperGenerator | "APKRun couldn't create the icon of the Mac app." | "Try again. If it fails again, choose another icon or report the problem." `retry` | 1 | §8.3 |
| `launcherTemplateInvalid(String)` | `wrapper.launcherTemplateInvalid` | the generic launcher in APKRun.app is missing, is not arm64, or has an invalid signature (health `wrappers.template`) | AppWrapperGenerator | "APKRun's template for Mac apps is damaged." | "Download APKRun again and replace it in the Applications folder." `openDownloadsPage` | 1 | §6.2 step 1, §14 |
| `destinationNotWritable(URL)` | `wrapper.destinationNotWritable` | the destination can't be written, for example `/Applications` for a user who is not an administrator | AppWrapperGenerator | "APKRun can't save the Mac app in the folder {file}." | "Choose another location, for example Applications (for me)." `none` | 1 | §6.3 |
| `destinationNotAccessible(URL, stagingToken:)` | `wrapper.destinationNotAccessible` | the probe gets `EPERM` from macOS privacy controls. The bundle waits in staging. The CLI places it itself, and the GUI does after the Save panel (`placeStagedWrapper`). Users see the error only when that is not possible | AppWrapperGenerator | "APKRun's background service can't access the folder {file}." | "Choose Another Location… and select the folder, so APKRun can save the Mac app there." `none` | 1 | §6.3, [../02-design/host-ui.md](../02-design/host-ui.md) §6.2 |
| `nameConflict(URL, existing: ExistingItemKind)` | `wrapper.nameConflict` | an item of the same name exists at the destination and is never replaced (§6.4). The GUI proposes "{name} 2.app" instead of showing the error | AppWrapperGenerator | "An item named {file} already exists there." | "Choose another name or location. APKRun never replaces it." `none` | 1 | §6.4 |
| — | `wrapper.nameConflict / otherWrapper` | the item is the Mac app of another package | AppWrapperGenerator | "{file} is the Mac app of another app." | "Choose another name or location. APKRun never replaces it." `none` | 1 | §6.4 |
| — | `wrapper.nameConflict / otherApp` | the item is another Mac application | AppWrapperGenerator | "An app named {file} already exists there." | "Choose another name or location. APKRun never replaces it." `none` | 1 | §6.4 |
| `wrapperExists(PackageID, URL)` | `wrapper.wrapperExists` | a valid registered wrapper exists, and `replace == .never` | AppWrapperGenerator | "{app} already has a Mac app ({file})." | "Use Update Mac App, or run: apkrun wrap {package} --replace" `none` | 1 | §6.2 step 2, §6.4 |
| `wrapperRunning(PackageID)` | `wrapper.wrapperRunning` | a refresh while the wrapper runs. The GUI asks "Quit {app} to update its Mac app?" instead of showing the error | AppWrapperGenerator | "{app} is open." | "Quit {app}, then try again." `retry` | 75 | §9.3 step 1 |
| `wrapperNotFound(PackageID)` | `wrapper.wrapperNotFound` | `wrapperInfo`, `refreshWrapper`, or `removeWrapper` for a package without a registry entry | WrapperRegistry | "{app} has no Mac app." | "Create one with Create Mac App." `createMacApp` | 4 | §12.1 |
| `signingFailed(status:message:)` | `wrapper.signingFailed` | `codesign` exits non-zero. Status and message are logged | WrapperSigner | "APKRun couldn't sign the Mac app." | "Try again. If it fails again, create a diagnostics report." `retry` | 1 | §7.1, §11 |
| `verificationFailed(String)` | `wrapper.verificationFailed` | the strict verification after signing fails | WrapperSigner | "The new Mac app didn't pass its signature check." | "Try again. If it fails again, report the problem." `retry` | 1 | §7.1 |
| `registrationFailed(OSStatus)` | `wrapper.registrationFailed` | `LSRegisterURL` returns an error. A warning: the wrapper was created (catalog §3.6) | AppWrapperGenerator | "The Mac app was created, but macOS hasn't registered it yet." | "Finder registers it when it shows the folder. To register it now, run: apkrun doctor --fix" `none` | 0 | §6.2 |
| `registryUnavailable` | `wrapper.registryUnavailable` | `registry.json` can't be read. It is kept as `registry.json.corrupt-<time>`, and no wrapper is authorized | WrapperRegistry | "APKRun can't read its list of Mac apps, so they can't open." | "Choose Re-register Mac Apps on the APKRun home screen." `none` | 1 | §7.2 |
| `refreshBlocked(String, stagingToken:)` | `wrapper.refreshBlocked` | macOS App Management denies the change of the bundle (R-20). With a staging token, APKRun.app swaps `Contents` itself and calls `placeStagedWrapper`. Users see the error only when that is not possible, and in the CLI | AppWrapperGenerator, APKRun.app | "macOS didn't allow APKRun to update the Mac app." | "Allow APKRun in System Settings → Privacy & Security → App Management, then try again." `openPrivacySettings` | 1 | §9.3, [runtime-api.md](runtime-api.md) §10.5 |
| `stagingExpired` | `wrapper.stagingExpired` | `placeStagedWrapper` with a staging token that is unknown, older than 60 minutes, or from before apkrund restarted. The staging folder is deleted | AppWrapperGenerator | "The prepared Mac app is no longer available." | "Create or update the Mac app again." `none` | 4 | §6.3, §9.3, [runtime-api.md](runtime-api.md) §10.3 |

- `wrapper.nameConflict` has no variant for `file`. The entry's text covers it.
- A wrapper failure after a successful install is shown as "{app} was installed, but the Mac app couldn't be created: {cause}" with **Try Again** ([../02-design/host-ui.md](../02-design/host-ui.md) §6.2). That text is a UI string of APKRun.app, not an entry. The install result carries the wrapper error in `wrapperError` ([runtime-api.md](runtime-api.md)).

### 12.2 Approval and bootstrap

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `bundleInvalid(URL, reason: BundleProblem)` | `wrapper.bundleInvalid` | a static check of §7.3 step 1 fails (approval or `verifyWrapper`). The launcher shows screen D | WrapperApprovalService, WrapperValidator | "{file} isn't a valid APKRun Mac app." | "Get a new copy from where it came from, or create the Mac app again in APKRun." `none` | 1 | §7.3 step 1 |
| — | `wrapper.bundleInvalid / signatureInvalid` | the signature is not valid. A modified local wrapper always fails here | WrapperApprovalService, WrapperValidator | "This Mac app was modified after it was created." | "Create it again in APKRun." `createMacApp` | 1 | §7.3, §9.1 |
| `approvalDenied` | `wrapper.approvalDenied` | the user chose **Don't Allow**, or a denial for the same cdhash has not expired (24 h). The launcher shows screen A | WrapperApprovalService, APKRunLauncher | "APKRun did not allow {app} to open." | "To allow it, remove it from Mac apps you didn't allow in Settings → Privacy, then open {app} again." `openPrivacySettings` | 5 | §7.3 step 5, [../02-design/host-ui.md](../02-design/host-ui.md) §9.4 |
| `approvalTimedOut` | `wrapper.approvalTimedOut` | no answer within 10 minutes. The launcher shows screen A | WrapperApprovalService, APKRunLauncher | "APKRun did not allow {app} to open." | "The request wasn't answered within 10 minutes. Open {app} again to ask again." `retry` | 1 | §7.3 step 5 |
| `approvalNotFound` | `wrapper.approvalNotFound` | `decideApproval` for an approval that is unknown, already answered, or expired. The first answer wins | WrapperApprovalService | "This request to open a Mac app was already answered or has expired." | "No action is needed. To ask again, open the Mac app again." `none` | 4 | §7.3 step 5, [runtime-api.md](runtime-api.md) §10.6 |
| `translocated` | `wrapper.translocated` | the bundle path contains `/AppTranslocation/` (screen T) | APKRunLauncher | "Move {app} to your Applications folder, then open it again." | — `none` | 1 | §5.2 step 2, §7.4 |
| `bootstrapInvalid(BootstrapProblem)` | `wrapper.bootstrapInvalid` | `bootstrap.json` can't be read, names another package, or a file's SHA-256 differs | RuntimeHost (`importBootstrap`) | "The copy of {app} inside this Mac app is damaged." | "Get a new copy of the Mac app from where it came from." `none` | 1 | §10.2 step 4 |
| `bootstrapNotAllowed(BootstrapRefusal)` | `wrapper.bootstrapNotAllowed` | `importBootstrap` is refused | RuntimeHost (`importBootstrap`) | "APKRun can't install {app} from this Mac app." | variants below | 5 | §10.2 step 4 |
| — | `wrapper.bootstrapNotAllowed / alreadyInstalled` | the package is installed (and not `uninstalledKeepingData`). The bootstrap never updates or downgrades | RuntimeHost | "{app} is already installed, so this Mac app doesn't install it again." | "No action is needed." `none` | 5 | §10.2 |
| — | `wrapper.bootstrapNotAllowed / notApproved` | the wrapper is not approved | RuntimeHost | "APKRun hasn't allowed this Mac app yet." | "Open it again and choose Allow in APKRun." `none` | 5 | §10.2 |

- `wrapper.translocated` has no remediation because its message is the next step. The text is the one of screen T.
- `runtime.busy` is the answer when more than 5 approval requests arrive per minute ([runtime-api.md](runtime-api.md)). A second request for the same bundle ID joins the pending one.
- A bootstrap install for a package whose kept data is newer fails with `store.downgradeRefused` (§10.2).

### 12.3 Launcher

These entries are raised by APKRunLauncher from the `hello` reply and the connection result (§5.2, §5.3), and shown on launcher screens. The column Raised by is replaced by the screen (catalog §18). They never reach the CLI: when the launcher shows one of its screens instead of connecting, the reply of `launch` is `runtime.launchTimedOut` ([runtime-api.md](runtime-api.md) §6.2, §6.5).

| Case | Code | When raised | Screen | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `runtimeMissing` | `wrapper.runtimeMissing` | no application with bundle ID `io.apkrun.APKRun`, and the Mach service does not answer | R | "APKRun is required to open {app}." | "Choose Get APKRun to download it." `none` | 69 | §5.4 |
| `runtimeNotReady` | `wrapper.runtimeNotReady` | APKRun.app exists, but apkrund is not registered (`runtime.serviceUnavailable`), or Android is not set up (`runtime.notProvisioned`) | S | "APKRun needs to finish setup." | "Open APKRun to finish setup." `none` | 69 | §5.4 |
| `runtimeTooOld(required:found:)` | `wrapper.runtimeTooOld` | `runtimeVersion` < `runtime.minimumVersion`, or the launcher's API major is newer than apkrund's (`M > N`). `{version}` is the required version, `{found}` the installed one | V | "{app} needs APKRun {version} or later." | "Update APKRun. This Mac has APKRun {found}." `updateAPKRun` | 1 | §5.3 |
| `launcherTooOld(launcherAPI:runtimeAPI:)` | `wrapper.launcherTooOld` | the launcher's API major is two or more behind (`M < N − 1`) | L | "This Mac app was made by an older APKRun and needs to be updated." | "Choose Update Mac App." `updateMacApp` | 1 | §5.3, §9.4 |
| `wrapperDamaged(String)` | `wrapper.wrapperDamaged` | startup step 1 fails: unreadable or mismatched `wrapper.json`, or an unknown format version | D | "{app} is damaged." | "Create it again in APKRun." `createMacApp` | 1 | §5.2 step 1 |

- For `M > N`, `{version}` is the APKRun version that built the launcher (`LauncherBuild`), because `runtime.minimumVersion` is already satisfied.
- Screens show the message as the title and the remediation below it. Screen D therefore reads "{app} is damaged. Create it again in APKRun.", as in §5.4.

### 12.4 Distribution (M12)

CLI-only entries of `apkrun wrap --distribution` (§11). They may name commands (catalog §3.3).

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `distributionToolMissing(String)` | `wrapper.distributionToolMissing` | `notarytool` or `stapler` is missing. `{tool}` is its name | distribution builder | "Creating a distribution Mac app needs the Xcode Command Line Tools ({tool} is missing)." | "Install them with: xcode-select --install" `none` | 1 | §11 |
| `identityNotFound(String)` | `wrapper.identityNotFound` | the `--identity` is not in the keychain. `{identity}` is the name as given | distribution builder | "The signing identity {identity} isn't in your keychain." | "List the identities with: security find-identity -v -p codesigning" `none` | 1 | §11 |
| `notarizationFailed(submissionID:summary:)` | `wrapper.notarizationFailed` | `notarytool` answers `Invalid`. `{submission}` is the submission ID. The summary is printed below the error, not in the message | distribution builder | "Apple's notary service rejected the Mac app (submission {submission})." | "Show the details with: xcrun notarytool log {submission} --keychain-profile <profile>" `none` | 1 | §11 |

A failed `codesign` of a distribution wrapper is `wrapper.signingFailed` (catalog §12.1).

### 12.5 Sub-enums

| Type | Cases | Status | User text |
|---|---|---|---|
| `IconInputProblem` | `unreadable`, `notSquare`, `tooSmall` | declared in §13 | variants of `wrapper.customIconInvalid` |
| `ExistingItemKind` | `otherWrapper(PackageID)`, `otherApp`, `file` | declared in §13 (comment) | variants of `wrapper.nameConflict` |
| `BundleProblem` | `signatureInvalid`, `identifierMismatch`, `bundleIDMismatch`, `wrapperJSONInvalid`, `packageMismatch` | declared in §13. The checks of §7.3 step 1 | `signatureInvalid` has a variant. The others use the entry's text and are logged |
| `BootstrapProblem` | `hashMismatch`, `packageMismatch`, `malformed` | declared in §13 | none. Logged |
| `BootstrapRefusal` | `alreadyInstalled`, `notApproved` | declared in §13 | variants of `wrapper.bootstrapNotAllowed` |

---

## 13. Domain `integration`

Owner: IntegrationCore (in apkrund) and the window-side adapters in APKRunLauncher. Design: [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §12. Many integration failures are not shown: a dropped link or a clipboard change without a key window is only counted and logged with `err=` (§2.3). The table says where each entry is shown. `{integration}` is the display name of the `IntegrationKind` (catalog §3.2). Clipboard content, notification text, URLs, and Android file names never appear in a message (§13, NFR-SEC-05).

### 13.1 Policy and availability

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `disabled(IntegrationKind, IntegrationDenial)` | `integration.disabled` | `IntegrationPolicy` denies the request. Shown for a refused drop and in `apkrun integrations status`. Logged for the host answers of catalog §8.3 | IntegrationPolicy | "{integration} is turned off for {app}." | "Turn it on in the app's settings in APKRun." `none` | 5 | §2.3 |
| — | `integration.disabled / globallyOff` | the global switch `integrations.enabled.<name>` is off | IntegrationPolicy | "{integration} is turned off for all apps." | "Turn it on in Settings → Privacy." `openPrivacySettings` | 5 | §2.2 |
| — | `integration.disabled / notFocused` | the app's window is not key, or had no user input in the last 5 s (links) | IntegrationPolicy | "{app} can use {integration} only while you use its window." | "Click the app's window, then try again." `none` | 5 | §4.1, §7.2 |
| — | `integration.disabled / noSession` | the package has no session | IntegrationPolicy | "{app} isn't open." | "Open {app}, then try again." `none` | 5 | §2.3 |
| — | `integration.disabled / notSupported` | the running image lacks the capability | IntegrationPolicy | "This version of Android doesn't support {integration}." | "Update Android." `updateAndroid` | 5 | §2.4 |
| — | `integration.disabled / rateLimited` | a rate limit, for example more than 3 links in 10 s | IntegrationPolicy | "{app} is doing this too often." | "Wait a moment, then try again." `retry` | 5 | §7.2 |
| `notSupportedOnImage(capability:)` | `integration.notSupportedOnImage` | an operation needs a Guest Agent capability that the running image does not report (health `integrations.capabilities`) | IntegrationChannel | "This version of Android doesn't support this ({capability})." | "Update Android." `updateAndroid` | 1 | §2.4, §13 |
| `guestUnavailable` | `integration.guestUnavailable` | the Guest Agent is not connected. The operation is not queued | IntegrationChannel | "The Guest Agent in Android isn't connected." | "APKRun reconnects automatically. Try again in a moment." `retry` | 75 | §12 |
| `promptTimedOut` | `integration.promptTimedOut` | the link prompt got no answer in 60 s and was cancelled. Logged only | LinkForwarder | "The link from {app} was cancelled because the question wasn't answered." | — `none` | 1 | §7.2 |

- `integration.disabled / packageOff` uses the entry's text. `IntegrationDenial.notSupported(capability)` and `integration.notSupportedOnImage` describe the same missing capability at two places: the policy decision and the channel call. Both are kept.
- The settings UI does not show `integration.disabled` for a missing capability. It greys the switch out and says why (§2.4).

### 13.2 Clipboard, links, and files

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `clipboardTooLarge(bytes:limit:)` | `integration.clipboardTooLarge` | an image or HTML clip above its limit (§4.4). Long text is truncated instead, and the window shows "Only the first 1 MB was copied." | ClipboardCoordinator | "The copied item is too large for Android ({bytes}; the limit is {limit})." | "Copy a smaller item." `none` | 1 | §4.4 |
| `linkRejected(LinkRejection)` | `integration.linkRejected` | `LinkForwarder` drops a link (`ResolveUrl(DROP)`). Counted and logged only | LinkForwarder | "APKRun didn't open a link from {app}." | — `none` | 5 | §7.2 |
| — | `integration.linkRejected / scheme` | the scheme is not `http`, `https`, or `mailto`, or an `http(s)` link has no host | LinkForwarder | "APKRun opens only web and mail links from Android apps." | — `none` | 5 | §7.2 |
| — | `integration.linkRejected / tooLong` | longer than 8 KiB | LinkForwarder | "The link from {app} is too long to open." | — `none` | 5 | §7.2 |
| — | `integration.linkRejected / notFocused` | the window is not key and had no input in the last 5 s | LinkForwarder | "APKRun opens links from {app} only while you use its window." | — `none` | 5 | §7.2 |
| — | `integration.linkRejected / rateLimited` | more than 3 links in 10 s | LinkForwarder | "{app} opened too many links at once." | — `none` | 5 | §7.2 |
| `tooManyFiles(count:limit:)` | `integration.tooManyFiles` | a drop of more than 20 files. Shown in the window | DropTarget, FileTransferService | "Too many files at once ({count})." | "Drop at most 20 files at a time." `none` | 1 | §6.2, [runtime-api.md](runtime-api.md) §4.10 |
| `fileTooLarge(name:bytes:)` | `integration.fileTooLarge` | a dropped file above 2 GiB, or a drop above 4 GiB in total. `{file}` is the name of the dropped file | DropTarget, FileTransferService | "{file} is too large to drop into Android ({bytes})." | "Drop files of up to 2 GB each and 4 GB in total." `none` | 1 | §6.2 |
| `transferFailed(String)` | `integration.transferFailed` | a bulk transfer aborts, the SHA-256 of `BulkEnd` differs, or a file system error in `SharedFolderService`. The partial file is deleted | FileTransferService, SharedFolderService | "The file transfer didn't finish." | "Try again." `retry` | 1 | §6.2, §6.3 |

- `integration.linkRejected` has no remediation. The user did not ask for anything, so there is nothing to do.
- The limit of `integration.tooManyFiles` is written into the text because `{limit}` is a byte parameter (catalog §3.2). More than 20 file handles on `importPackage` is `runtime.malformedRequest`, not this entry ([runtime-api.md](runtime-api.md)).

### 13.3 Shared folders

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `folderUnavailable(FolderProblem)` | `integration.folderUnavailable` | a root can't be used. Shown in Settings → Files, in `apkrun shared-folders`, and by health `integrations.sharedFolders`. `{file}` is the folder's name | SharedFolderService | "APKRun can't access the shared folder {file}." | variants below | 1 | §6.4 |
| — | `integration.folderUnavailable / missing` | the folder no longer exists | SharedFolderService | "The shared folder {file} doesn't exist any more." | "Put the folder back, or remove it in Settings → Files." `none` | 1 | §6.4 |
| — | `integration.folderUnavailable / privacyDenied` | macOS privacy controls deny access | SharedFolderService | "macOS doesn't allow APKRun to access the shared folder {file}." | "Allow APKRun in System Settings → Privacy & Security → Files and Folders." `none` | 1 | §6.4, [../02-design/host-ui.md](../02-design/host-ui.md) §9.5 |
| — | `integration.folderUnavailable / offline` | the volume is not mounted | SharedFolderService | "The shared folder {file} isn't available right now." | "Connect the drive or network volume that contains it." `none` | 1 | §6.4 |
| `pathRejected(PathProblem)` | `integration.pathRejected` | an Android request names a path outside the root, a hidden item, or an item that is not a regular file or folder. Answered with `PERMISSION_DENIED` and logged (catalog §8.3) | SharedFolderService | "Android asked for a file that APKRun doesn't share." | — `none` | 5 | §6.4 rules 2–3 |
| `folderRefused(FolderRefusal)` | `integration.folderRefused` | `addSharedFolder` names a folder that can't be shared ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6.4, refused roots). Shown in Settings → Files and by `apkrun shared-folders add`. `{file}` is the folder's name | SharedFolderService | "APKRun doesn't share {file}." | variants below | 5 | §6.4 |
| — | `integration.folderRefused / volumeRoot` | the folder is the root of a volume | SharedFolderService | "APKRun doesn't share a whole disk." | "Choose a folder on the disk instead." `none` | 5 | §6.4 |
| — | `integration.folderRefused / homeFolder` | the folder is the home folder | SharedFolderService | "APKRun doesn't share your whole home folder." | "Choose a folder inside it, such as Documents or Downloads." `none` | 5 | §6.4 |
| — | `integration.folderRefused / insideLibrary` | the folder is `~/Library` or inside it | SharedFolderService | "APKRun doesn't share folders in your Library." | "Choose a folder outside ~/Library." `none` | 5 | §6.4 |
| — | `integration.folderRefused / hidden` | the folder, or a folder that contains it, is hidden | SharedFolderService | "APKRun doesn't share hidden folders." | "Choose a folder that isn't hidden." `none` | 5 | §6.4 |
| — | `integration.folderRefused / limitReached` | 32 folders are already added | SharedFolderService | "You can share at most 32 folders." | "Remove a shared folder in Settings → Files first." `none` | 5 | §6.4 |
| `readOnly` | `integration.readOnly` | a write, create, delete, or rename in a read-only root or with read-only package access. Answered with `PERMISSION_DENIED` and logged | SharedFolderService | "{app} can only read files in the shared folders." | "To allow changes, set Shared folders to Read and write in the app's settings, and give the folder Read and write access in Settings → Files." `none` | 5 | §6.4 |

The design text in Settings → Files, "Can't access. Allow APKRun in System Settings → Privacy & Security → Files and Folders.", is the short form of `integration.folderUnavailable / privacyDenied` ([../02-design/host-ui.md](../02-design/host-ui.md) §9.5).

### 13.4 Permissions and audio

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `notificationPermissionDenied` | `integration.notificationPermissionDenied` | the wrapper reports `UNAuthorizationStatus.denied`. Shown on the app page | NotificationCoordinator | "Notifications for {app} are turned off in System Settings." | "Turn them on in System Settings → Notifications → {app}." `openNotificationSettings` | 1 | §5.3 |
| `microphonePermissionDenied` | `integration.microphonePermissionDenied` | a package has the microphone on, and macOS denies microphone access to APKRun (health `integrations.microphone`) | AudioPolicy | "macOS doesn't allow APKRun to use the microphone." | "Allow APKRun in System Settings → Privacy & Security → Microphone." `openPrivacySettings` | 1 | §8.2 |
| `microphoneNeedsRestart` | `integration.microphoneNeedsRestart` | the microphone was turned on for the first package, or off for the last one, while Android runs. The input stream changes at the next start | AudioPolicy | "The microphone change applies after Android restarts." | "Choose Restart Android Now." `restartAndroid` | 1 | §8.2 |

- The app page's button for `integration.notificationPermissionDenied` is the action `openNotificationSettings`, which opens the Notifications pane of System Settings (§5.3).
- `integration.microphoneNeedsRestart` is shown as a note next to the setting, not as an alert.

### 13.5 Sub-enums

| Type | Cases | Status | User text |
|---|---|---|---|
| `IntegrationKind` | `clipboard`, `notifications`, `links`, `files`, `sharedFolders`, `microphone` | §2.3 | `{integration}`: Clipboard, Notifications, Links, Files, Shared folders, Microphone |
| `IntegrationDenial` | `globallyOff`, `packageOff`, `notFocused`, `noSession`, `notSupported(capability)`, `rateLimited` | declared in §2.3 (comment) | variants of `integration.disabled`. `packageOff` uses the entry's text |
| `LinkRejection` | `scheme`, `tooLong`, `notFocused`, `rateLimited` | declared in §12 (comment) | variants of `integration.linkRejected` |
| `FolderProblem` | `missing`, `privacyDenied`, `offline` | declared in §12 (comment) | variants of `integration.folderUnavailable` |
| `PathProblem` | `outsideRoot`, `hidden`, `notRegularFile` | declared in §12 (comment) | none. Logged |
| `FolderRefusal` | `volumeRoot`, `homeFolder`, `insideLibrary`, `hidden`, `limitReached` | declared in §12 (comment) | variants of `integration.folderRefused` |

---

## 14. Domain `maintenance`

Owner: RuntimeHost (`MaintenanceService`, `SelfUpdateProbe`, `ImageUpdateCoordinator`), ImageCore (`ImageFeedClient`, `ImageDownloader`, `ImageStore`), and APKRun.app (`SelfUpdateController`, `UpdateInstallCoordinator`, `AgentRegistrar`). Design: [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §11. `MaintenanceFailure` is the only error type that already conforms to `APKRunError`. Background checks do not show dialogs. Their failures go to `lastError`, to the status line of Settings → General (§7.1), and to the health checks `maintenance.selfUpdate` and `maintenance.imageUpdate` (catalog §20.2). Sparkle shows its own errors for a user-initiated APKRun update check (§3.9).

### 14.1 APKRun updates and data schemas

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `selfUpdateFeedUnreachable(detail:)` | `maintenance.selfUpdateFeedUnreachable` | the appcast can't be fetched (network, timeout, HTTP status) | SelfUpdateProbe | "APKRun couldn't check for updates." | "Check the network connection. APKRun tries again later." `retry` | 1 | §3.4, §3.9 |
| `selfUpdateFeedInvalid(detail:)` | `maintenance.selfUpdateFeedInvalid` | the appcast can't be parsed, or it is above 2 MiB | SelfUpdateProbe | "The APKRun update information isn't valid." | "APKRun tries again later. If this continues, report the problem." `none` | 1 | §3.4, §3.9 |
| `selfUpdateNotNewer(current:target:)` | `maintenance.selfUpdateNotNewer` | `prepareForHostUpdate` with `targetBuild` ≤ the running build | MaintenanceService | "This update isn't newer than the installed APKRun." | "No action is needed." `none` | 1 | §3.5 step 4a, §8.1 |
| `sparkle(code:detail:)` | `maintenance.sparkle` | Sparkle aborts or fails to download (`SUError` code). Logged. If a marker was written, `abortHostUpdate` runs | SelfUpdateController | "The APKRun update couldn't be downloaded or installed." | "Try again. If it fails again, download APKRun from its website." `retry` | 1 | §3.2, §3.9 |
| `hostUpdateBusy(ActivityKind)` | `maintenance.hostUpdateBusy` | `prepareForHostUpdate` is refused because Android is busy | MaintenanceService | "APKRun can't be updated while Android is busy." | "Try again when it has finished." `retry` | 75 | §2.4, §3.5 |
| — | `maintenance.hostUpdateBusy / migration` | an Android system update runs. APKRun.app shows "Waiting for the Android system update to finish…" and tries again every 30 s | MaintenanceService | "APKRun can't be updated while Android is updating." | "APKRun installs its update when the Android system update has finished." `none` | 75 | §2.4 |
| — | `maintenance.hostUpdateBusy / storeOperation` | a package transaction or an app update install still runs after 2 minutes | MaintenanceService | "APKRun can't be updated while apps are being installed or updated." | "Try again when it has finished." `retry` | 75 | §2.4 |
| `hostUpdateSessionsOpen([PackageID])` | `maintenance.hostUpdateSessionsOpen` | `prepareForHostUpdate` or `restartForUpdate` with `closeSessions` false while sessions exist | MaintenanceService | "APKRun can't be updated while Android apps are open." | "Close the apps, or choose Close Apps and Install." `none` | 75 | §3.5, §8.1 |
| `hostUpdateStopFailed(RuntimeFailure)` | `maintenance.hostUpdateStopFailed` | Android does not stop in step 4f. `abortHostUpdate` runs | MaintenanceService | "APKRun couldn't be updated because Android didn't stop." | "Try again. If it fails again, quit and reopen APKRun." `retry` | 1 | §3.5 step 4f |
| `hostUpdateAbandoned(targetBuild:)` | `maintenance.hostUpdateAbandoned` | APKRun.app starts and finds a marker with a higher `targetBuild` (the install failed after step 4), or apkrund deletes a marker that is 10 minutes old (logged, health warning for 24 h) | SelfUpdateController, RuntimeHost | "APKRun couldn't be updated." | "The installed version still works. Try the update again in Settings → General." `updateAPKRun` | 1 | §3.6 |
| `agentRegistrationFailed(status:)` | `maintenance.agentRegistrationFailed` | `SMAppService` `register()` fails in the first-launch tasks. `{reason}` is the status | AgentRegistrar | "APKRun couldn't set up its background service after the update ({reason})." | "Quit and reopen APKRun. If the service is turned off, allow APKRun in System Settings → General → Login Items & Extensions." `openLoginItemsSettings` | 69 | §3.7 step 2 |
| `dataCreatedByNewerVersion(file:schema:supported:)` | `maintenance.dataCreatedByNewerVersion` | a data file has a newer schema than this build supports. The owning component starts degraded, and the file is never written | RuntimeHost (each store) | "This data was created by a newer version of APKRun." | "Install the latest version of APKRun." `updateAPKRun` | 1 | §5, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.2 step 4 |
| `schemaMigrationFailed(file:from:to:detail:)` | `maintenance.schemaMigrationFailed` | a data schema migration fails. The owning component starts degraded. The original file and its backup are unchanged | RuntimeHost (each store) | "APKRun couldn't convert its data for this version." | "Your data is unchanged. Create a diagnostics report and report the problem." `reportProblem` | 1 | §3.9, §5 |

- A component that starts degraded makes `runtimeStatus` return `runtime.hostStartupFailed` with the `maintenance` entry as the underlying error ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.2).
- `file`, `schema`, `supported`, `from`, `to`, `current`, and `target` are logged and shown under Details. They are not in the messages.
- A failed or timed-out `prepareForHostUpdate` (3 minutes on the APKRun.app side) is shown with **Try Again** in every case (§3.5). A timeout without a reply is `runtime.requestTimedOut` (catalog §7.4).
- The `restartPending` texts ("APKRun was updated. Restart Android to finish. {count} apps will close." and "Finish updating APKRun…") are UI texts, not entries (catalog §17.6). The `apkrund.version` remediation of §12 is the variant `diagnostics.serviceVersionMismatch / restartPending` (catalog §15.2, §20.2).

### 14.2 Android system updates

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `imageFeedUnreachable(detail:)` | `maintenance.imageFeedUnreachable` | the image feed can't be fetched. Retried after 1 h, 6 h, then daily | ImageFeedClient | "APKRun couldn't check for Android system updates." | "Check the network connection. APKRun tries again later." `retry` | 1 | §4.2 |
| `imageFeedHTTPStatus(Int)` | `maintenance.imageFeedHTTPStatus` | a non-2xx status. `{code}` is the status | ImageFeedClient | "The Android update server answered with HTTP status {code}." | "APKRun tries again later." `retry` | 1 | §4.1 |
| `imageFeedSignatureInvalid(keyID:)` | `maintenance.imageFeedSignatureInvalid` | the feed signature is bad or made with an unknown key. The last accepted feed stays in effect | ImageFeedClient | "The Android update information isn't signed correctly." | "APKRun keeps using the last valid information. If this continues, update APKRun." `updateAPKRun` | 1 | §4.1 rule 2 |
| `imageFeedInvalid(detail:)` | `maintenance.imageFeedInvalid` | the feed breaks its rules: wrong channel, too large, or a manifest that differs from the feed entry | ImageFeedClient | "The Android update information isn't valid." | "APKRun tries again later." `none` | 1 | §4.1 rules 1, 3, 6 |
| — | `maintenance.imageFeedInvalid / schemaVersion` | an unknown feed `schemaVersion`. The feed is not used | ImageFeedClient | "Android system updates need a newer version of APKRun." | "Update APKRun to receive Android system updates." `updateAPKRun` | 1 | §4.1 rule 5 |
| `imageFeedReplayed(sequence:highest:)` | `maintenance.imageFeedReplayed` | the feed's sequence is lower than the highest accepted, or equal with other bytes | ImageFeedClient | "The Android update information is older than information APKRun already has." | "APKRun ignores it and tries again later." `none` | 1 | §4.1 rule 4 |
| `imageFeedExpired(Date)` | `maintenance.imageFeedExpired` | the feed's `expiresAt` has passed | ImageFeedClient | "The Android update information has expired." | "APKRun tries again later. If this continues, check the date and time of this Mac." `none` | 1 | §4.1 rule 4 |
| `noCompatibleImage(NoImageReason)` | `maintenance.noCompatibleImage` | the current image can't boot with this APKRun, and the feed has no image that it can boot (§4.10). A release defect | ImageUpdateCoordinator | "No Android version works with this version of APKRun." | "Install the previous version of APKRun from the APKRun website." `openDownloadsPage` | 1 | §4.10 |
| — | `maintenance.noCompatibleImage / requiresNewerAPKRun` | the compatible images need a newer APKRun. `{version}` is the minimum | ImageUpdateCoordinator | "A newer Android version needs APKRun {version} or later." | "Update APKRun." `updateAPKRun` | 1 | §4.2 C2, §7.1 |
| `imageDownloadFailed(detail:)` | `maintenance.imageDownloadFailed` | the download fails. The partial file is kept when the server supports ranges | ImageDownloader | "The Android system update couldn't be downloaded." | "Check the network connection. APKRun continues the download later." `retry` | 1 | §4.4 |
| `imageArchiveSizeMismatch(expected:actual:)` | `maintenance.imageArchiveSizeMismatch` | the server sends more bytes than the feed's `size` | ImageDownloader | "The downloaded Android system update is damaged." | "APKRun downloads it again later." `retry` | 1 | §4.4 |
| `imageArchiveHashMismatch` | `maintenance.imageArchiveHashMismatch` | the archive's SHA-256 differs from the feed | ImageDownloader | "The downloaded Android system update is damaged." | "APKRun downloads it again later." `retry` | 1 | §4.4 |
| `imageArchiveUnsafeEntry(path:)` | `maintenance.imageArchiveUnsafeEntry` | an archive entry with `..`, an absolute path, a link, a device, or a FIFO. The install stops. The path is logged | ImageStore | "The Android system update contains unsafe files and wasn't installed." | "Report the problem." `reportProblem` | 1 | §4.5 |
| `imageInstallFailed(ImageFailure)` | `maintenance.imageInstallFailed` | ImageCore rejects the installed bundle (catalog §9) | ImageStore | (cause) | (cause) | cause | §4.5 |
| `insufficientSpace(required:available:)` | `maintenance.insufficientSpace` | free space below the archive size + `expandedSize` + 10 GiB before a download or an install | ImageUpdateCoordinator | "The Android system update needs {needed} of free disk space, but only {available} is free." | "Free up disk space. Settings → Storage shows what APKRun uses." `openStorageSettings` | 1 | §4.4 |
| `imageUpdateNotReady` | `maintenance.imageUpdateNotReady` | an apply request without a `ready` image | ImageUpdateCoordinator | "No Android system update is ready to install." | "Check for updates in Settings → General, or run: apkrun image install --latest" `none` | 1 | §4.6, §8 |
| `imageUpdateRejected(ImageVersion)` | `maintenance.imageUpdateRejected` | an apply of a rejected version without `retryRejected` | ImageUpdateCoordinator | "The last attempt to update to Android {version} failed." | "To try again, choose Try Again in Settings → General, or run: apkrun image install --latest --yes" `none` | 5 | §4.8 |
| `imageMigrationFailed(ImageFailure)` | `maintenance.imageMigrationFailed` | the migration of §4.7 fails, and A is restored. B is rejected. The cause is the `ImageFailure` | ImageUpdateCoordinator | "Android couldn't be updated to {version}. Your apps and data are unchanged." | "Report the problem, so that it can be fixed in a later update." `reportProblem` | 1 | §4.7 step 5 |
| `rollbackUnavailable` | `maintenance.rollbackUnavailable` | **Go Back to Android…** or `apkrun image rollback` without a recovery point or a `previous` image | ImageUpdateCoordinator | "There is no earlier Android version to go back to." | "APKRun keeps the way back only until the next Android system update." `none` | 1 | §4.8 |
| `cancelled` | `maintenance.cancelled` | the user cancelled a download or an install | ImageUpdateCoordinator | "The Android system update was cancelled." | — `none` | 130 | §4.4, [../02-design/cli.md](../02-design/cli.md) §3.5 |

- `maintenance.noCompatibleImage` has no variants for `protocol`, `userdataSchema`, and `none`. They use the entry's text. The action `openDownloadsPage` opens the downloads page (§4.10, catalog §4).
- `maintenance.rollbackUnavailable` is the coordinator's check before it asks for confirmation. `image.recoveryPointMissing` (catalog §9) is ImageCore's check when the restore starts.
- The variant key `schemaVersion` of `maintenance.imageFeedInvalid` is a fixed key, not a sub-enum case. The fixture passes it explicitly.
- `maintenance.insufficientSpace` (the update pipeline) and `image.insufficientSpace` (ImageCore's own check, catalog §9) are two entries with the same kind of text.
- The status line "The last Android update failed. Android {version} is still in use." with **Try Again** and **Report a Problem…** is the Settings form of `maintenance.imageMigrationFailed` (§7.1).
- `maintenance.imageFeedSignatureInvalid`, `imageFeedReplayed`, and `imageFeedExpired` make `maintenance.imageUpdate` warn (§12). They are not shown otherwise.

### 14.3 Sub-enums

| Type | Cases | Status | User text |
|---|---|---|---|
| `NoImageReason` | `requiresNewerAPKRun(String)`, `protocol`, `userdataSchema`, `none` | declared in §11 (comment) | `requiresNewerAPKRun` is a variant of `maintenance.noCompatibleImage`. The others use the entry's text |
| `ActivityKind` | `migration`, `storeOperation` (the two that refuse a host update) | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5.1 | variants of `maintenance.hostUpdateBusy` |

---

## 15. Domain `diagnostics`

Owner: DiagnosticsCore (`HealthCheckRegistry`, `HostChecks`, `DiagnosticsService`, `DiagnosticsBundleWriter`). Design: [../02-design/diagnostics.md](../02-design/diagnostics.md) §7, §8. `DiagnosticsFailure` is declared in diagnostics.md §2.1. Its cases come from §7 and §8.

- A cancelled report is `runtime.cancelled` (catalog §7.4). A contributor that fails or runs out of time is not an error: the bundle is still produced, and the item is recorded in `omitted` (§8.1, catalog §17.10).
- An `--output` path that the CLI can't create is `cli.fileNotAccessible` (catalog §16).

### 15.1 Reports and fixes

| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `stagingFailed` | `diagnostics.stagingFailed` | the staging directory in `$TMPDIR` can't be created or written | DiagnosticsService | "APKRun couldn't prepare the diagnostics report." | "Free up disk space, then try again." `retry` | 1 | §8.1 step 3 |
| `bundleWriteFailed` | `diagnostics.bundleWriteFailed` | writing the ZIP into the client's file handle fails (disk full, the volume was ejected). The partial output is deleted | DiagnosticsBundleWriter | "The diagnostics report couldn't be saved." | "Check the free space where you save it, then try again." `retry` | 1 | §8.1 |
| `unknownHealthCheck(check)` | `diagnostics.unknownHealthCheck` | `healthReport` or `applyHealthFixes` names a check ID that this apkrund doesn't have (an N−1 client) | HealthCheckRegistry | "There is no health check named {check}." | "Run all checks with: apkrun doctor" `none` | 4 | §7.6 |
| `fixNotAvailable(check)` | `diagnostics.fixNotAvailable` | `applyHealthFixes` names a check that has no fix, or whose fix is not offered now (`apkrund.version` while Android runs) | HealthCheckRegistry | "APKRun can't fix {check} automatically." | "Follow the steps shown for this check." `none` | 1 | §7.5 |
| `fixFailed(check, underlying)` | `diagnostics.fixFailed` | a fix ran and failed. The error of the fix is the cause | HealthCheckRegistry | "The automatic fix for {check} didn't work: {cause}" | "Follow the steps shown for this check." `none` | 1 | §7.5 |

- `apkrun doctor --fix` prints "Fixed: ‹title›" or the error of each fix, then runs the whole report again (§7.5). A failed fix does not change the exit code: `doctor` exits by verdict (catalog §19, §20.1).
- A check that times out returns `warning` with the detail "check timed out" and no error (§7.1).

### 15.2 Health findings of the host and background service checks

These entries are the `HealthResult.error` of the checks of §7.3 that no other domain covers (catalog §20). They are not thrown by an operation, so their `cliExit` is 1 and is never used: `apkrun doctor` exits by verdict. The texts are those of §7.3.

| Case | Code | Check | State | Message | Remediation · action | Ref |
|---|---|---|---|---|---|---|
| `appNotInApplications` | `diagnostics.appNotInApplications` | `host.appLocation` | failure | "APKRun isn't in the Applications folder." | "Move APKRun to the Applications folder." `none` | §7.3 |
| `appSignatureInvalid` | `diagnostics.appSignatureInvalid` | `host.appSignature` (deep) | failure | "APKRun's app was modified or is damaged." | "Reinstall APKRun." `openDownloadsPage` | §7.3 |
| `componentVersionMismatch(build)` | `diagnostics.componentVersionMismatch` | `host.componentVersions` | failure | "Parts of APKRun have different versions ({build})." | "Reinstall APKRun." `openDownloadsPage` | §7.3 |
| `lowDiskSpace(available)` | `diagnostics.lowDiskSpace` | `host.dataVolume`, `image.freeSpace` | warning | "Only {available} is free on the disk with APKRun's data." | "Free up space. Settings → Storage shows what APKRun uses." `openStorageSettings` | §7.3, [../02-design/android-image.md](../02-design/android-image.md) §14.3 |
| `lowMemory(memory)` | `diagnostics.lowMemory` | `host.memory` | warning | "This Mac has {memory} of memory." | "APKRun works best with 16 GB or more." `none` | §7.3 |
| `serviceVersionMismatch(build)` | `diagnostics.serviceVersionMismatch` | `apkrund.version` | warning | "APKRun's background service has a different version ({build})." | "Quit and reopen APKRun." `none` | §7.3 |
| — | `diagnostics.serviceVersionMismatch / restartPending` | `apkrund.version` | warning | "An APKRun update is waiting for your Android apps to close." | "Close them, or choose Restart Now." `none` | §7.3, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §12 |
| — | `diagnostics.serviceVersionMismatch / androidRunning` | `apkrund.version` | warning | "APKRun's background service has a different version ({build})." | "Stop Android, then choose Fix, or run: apkrun doctor --fix" `none` | §7.5 |
| `serviceCrashLoop(count)` | `diagnostics.serviceCrashLoop` | `apkrund.crashLoop` | failure | "APKRun's background service stopped unexpectedly {count} times in 10 minutes." | "Create a diagnostics report and report the problem." `reportProblem` | §7.3, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.5 |

- The other host checks use existing entries: `host.appleSilicon`, `host.macOSVersion`, and `host.hypervisor` report `runtime.hostRequirementsNotMet` with one item. `host.dataVolume` on a volume that is not APFS reports `runtime.hostRequirementsNotMet / apfsVolume`. `apkrund.registration` and `apkrund.reachable` report `runtime.serviceUnavailable` (catalog §7.4, §20.2).
- The variant keys `restartPending` and `androidRunning` are fixed keys, not sub-enum cases. The fixture passes them explicitly.
- `{build}` is the other build number (apkrund's for `apkrund.version`, the first differing component for `host.componentVersions`).

---

## 16. Domain `cli`

Owner: the CLI (`CLI/apkrun`). Design: [../02-design/cli.md](../02-design/cli.md) §3. `CLIFailure` and `FileProblem` are declared in cli.md §3.3. The cases come from cli.md §2, §3, and §4. These entries are raised in the CLI process. They name commands and flags (catalog §3.3).

<!-- errorgen:begin cli -->
| Case | Code | When raised | Raised by | Message | Remediation · action | Exit | Ref |
|---|---|---|---|---|---|---|---|
| `confirmationRequired(flag)` | `cli.confirmationRequired` | a command that asks for confirmation runs without a TTY on stdin and without `--yes` | CLI | "This command needs a confirmation, but there is no terminal to ask." | "Run it again with {flag}." `none` | 1 | §3.4 |
| `declined` | `cli.declined` | the user answered no to `Continue? [y/N]`, or did not type `Reset` | CLI | "Nothing was changed." | — `none` | 5 | §3.3, §3.4 |
| `invalidPackageName(package)` | `cli.invalidPackageName` | a `<package>` argument fails the package-name grammar. No request is sent | CLI | "{package} isn't a valid Android package name." | "Use a package name such as com.example.app. apkrun list shows the installed apps." `none` | 64 | §3.1 |
| `invalidSourceSpec(argument)` | `cli.invalidSourceSpec` | a `<spec>` argument doesn't match any update source form | CLI | "This update source isn't valid." | "Use one of the forms local:, direct:, fdroid, or github:. apkrun update policy --help shows them." `none` | 64 | §3.1, [../02-design/update-system.md](../02-design/update-system.md) §11.3 |
| `invalidArgument(argument, reason)` | `cli.invalidArgument` | another validation that the CLI does itself, after swift-argument-parser (for example a `--since` duration). `{reason}` is a stable key | CLI | "The value of {argument} isn't valid ({reason})." | "Run the command with --help to see the allowed values." `none` | 64 | §3.1 |
| `fileNotAccessible(file, FileProblem)` | `cli.fileNotAccessible` | the CLI can't open a file argument, or can't create the `--output` file | CLI | "apkrun can't open {file}." | "Check the path and its permissions." `none` | 1 | §3.1, [../02-design/diagnostics.md](../02-design/diagnostics.md) §8.1 |
| — | `cli.fileNotAccessible / isDirectory` | a folder where a file is needed | CLI | "{file} is a folder." | "Name a file. Unpacked image folders are for apkrun dev image install." `none` | 1 | §3.1, §4.7 |
| — | `cli.fileNotAccessible / notFound` | the file doesn't exist | CLI | "{file} doesn't exist." | "Check the path." `none` | 1 | §3.1 |
| — | `cli.fileNotAccessible / permissionDenied` | the file or its folder can't be read or written | CLI | "apkrun isn't allowed to open {file}." | "Check the permissions, or give Terminal access in System Settings → Privacy & Security → Files and Folders." `none` | 1 | §3.1 |
| `developerModeRequired(command)` | `cli.developerModeRequired` | `apkrun logs --guest` while `developer.enabled` is off | CLI | "{command} needs developer mode." | "Turn on Developer mode in Settings → Advanced, or run: apkrun config set developer.enabled true" `none` | 5 | §4.8, [configuration.md](configuration.md) |
| `logsUnavailable` | `cli.logsUnavailable` | `/usr/bin/log` fails and the file mirrors can't be read | CLI | "APKRun's logs couldn't be read." | "Try again. If it fails again, create a diagnostics report." `retry` | 1 | §4.8 |
| `malformedReply(operation)` | `cli.malformedReply` | a reply that the CLI can't decode | CLI | "apkrun couldn't read the answer of APKRun's background service ({operation})." | "Make sure apkrun comes from the installed APKRun, then report the problem." `reportProblem` | 70 | §3.3 |
| `versionSkew(version, found)` | `cli.versionSkew` | the CLI's build differs from apkrund's, typically a copied binary after an APKRun update. A warning | CLI | "This apkrun ({version}) doesn't match APKRun ({found})." | "Link apkrun to the installed APKRun: Settings → Advanced → Install Command-Line Tool…" `none` | 0 | §2 |
| `—` | `cli.invalidArguments` | swift-argument-parser reports an unknown command or option, a missing argument, or another usage error | CLI | "The command arguments aren't valid." | "Run the command with --help to see the allowed values." `none` | 64 | §3.3 |
| `devConsoleRequiresTerminal` | `cli.devConsoleRequiresTerminal` | `apkrun dev console` is run without terminal input and output | `apkrun dev console` | "`apkrun dev console` requires an interactive terminal." | "Run the command from Terminal or another interactive terminal application." `none` | 64 | [../02-design/cli.md](../02-design/cli.md) §5 |
<!-- errorgen:end cli -->

- `FileProblem` (chosen): `notFound`, `permissionDenied`, `isDirectory`. `{file}` is the last path component (catalog §3.2).
- swift-argument-parser's usage failures use `cli.invalidArguments` and exit 64. Raw argument text is not included in the error.
- `apkrun self-update check` without apkrund prints `runtime.serviceUnavailable` with the hint "Open APKRun to check for updates." and exits 69 (cli.md §4.7). The CLI replaces only the hint line.
- Results that are not errors print on stdout and exit 0: "APKRun is up to date.", "APKRun 1.3.0 is available (you have 1.2.0). Open APKRun to install it.", and "Nothing to finish." (`self-update finish`).
- A second Ctrl-C exits 130 at once, without an error entry (§3.5).

---

## 17. Non-error enums

These enums are not errors. They have no code and no `errors.json` entry. Their texts are UI strings of the surface that shows them: APKRun.app, APKRunMenuBar, or the launcher's `Localizable.xcstrings` (§18.2). They are listed here because they decide which error, if any, the user sees. A case that carries a failure shows the entry of that failure.

### 17.1 `SessionEndReason`

Declared in [runtime-api.md](runtime-api.md) §6.2 and [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3. The launcher's reactions are those of [../02-design/wrapper.md](../02-design/wrapper.md) §5.5.

| Case | Sent when | Launcher | Entry shown |
|---|---|---|---|
| `userClosed` | the session was closed with `closeSession` (⌘W, ⌘Q, the close button) | quits | none |
| `appExited` | the app finished its task in Android | quits | none |
| `appCrashed` | the app's process died in Android | "{app} stopped unexpectedly" with **Reopen** (§18.2) | none |
| `runtimeStopped` | Android stopped with the `StopReason` `user`, `idle`, `hostShutdown`, or `reset` (§17.2) | quits | none |
| `updating` | **Update Now** for this package | closes the window and quits. APKRun reopens the app after the update | none. The result of the update is an `UpdateOutcome` (§17.5) |
| `runtimeUpdating` | the `StopReason` `hostUpdate` or `migration`, or `restartForUpdate` | screen U, then reopens by itself | none |
| `packageUninstalled` | the package is being uninstalled ([../02-design/package-store.md](../02-design/package-store.md) §8 step 2a) | closes the window and quits | none |
| `error(f)` | a `RuntimeFailure` ended the session: Android failed, no display could be acquired, or the launch failed ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.6, §7.4) | screen E. After a runtime failure with automatic restart, the wrapper retries `openSession` first | the entry of `f` |
| `unknown` | a case that this build doesn't know (a newer apkrund) | quits (chosen) | none |

- A connection that is invalidated is not a `SessionEndReason`. The launcher shows "APKRun restarted — reopening…" and calls `openSession` again with the backoff 1, 2, 4 s. When the third attempt fails, it shows screen E with the last error ([runtime-api.md](runtime-api.md) §3.6). A `runtime.hostUpdating` reply shows screen U instead.

### 17.2 `StartReason` and `StopReason`

Declared in [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.1.

`StartReason` (`session`, `store`, `update`, `cli`, `user`, `preboot`, `diagnostics`, `migration`, `provisioning`) has no user text. The runtime header and the placeholder show "Starting Android…", or "Updating Android… (‹phase›)" when `bootPurpose` is `imageUpdate` (§17.6). A failed start throws its `RuntimeFailure` to every waiting caller. A waiting session then ends with `error(f)`.

| `StopReason` | Cause | Sessions end with | What the user sees |
|---|---|---|---|
| `user` | **Stop Android**, `apkrun runtime stop` | `runtimeStopped` | a confirmation first when apps or activities are open. Without `force`, apkrund answers `runtime.busy` (catalog §7.2) |
| `idle` | the idle policy ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5) | `runtimeStopped` | nothing |
| `hostShutdown` | logout, shutdown, or apkrund's exit | `runtimeStopped` | nothing: the wrappers quit too |
| `hostUpdate` | `prepareForHostUpdate`, `restartForUpdate` | `runtimeUpdating` | screen U in launchers, "Updating APKRun…" in control clients |
| `migration` | applying an Android system update | `runtimeUpdating` | screen U, then the placeholder "Updating Android…" (§18.2) |
| `reset` | **Reset Android** | `runtimeStopped` | the reset confirmation of APKRun.app |
| `failure` | `RuntimeState → failed(f)` | `error(f)` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.4) | the entry of `f` |

A stop that doesn't reach `stopped`, even with the forced stop, is `runtime.stopTimedOut`. Forced stops that succeed are counted by the health check `runtime.stop` (§20.2).

### 17.3 `DisplayFault`

Declared in [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §4. The handling is in [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3.3.

| Case | Handling | Entry shown |
|---|---|---|
| `attachTimedOut` | no `DisplayAdded` within 5 s. The pool disables the scanout and retries the acquire once on the next free slot | `runtime.displayAttachFailed` when the retry fails too |
| `releaseTimedOut` | no `DisplayRemoved` within 3 s. Logged, and the slot is reset in the background (chosen) | none |
| `graphics(GraphicsFailure)` | a `GraphicsFailure` during the attach or the release | the `graphics.*` entry, when it fails the acquire |

- A faulted slot is reset in the background (disable, wait for `removed` or 3 s, then `free`). After three faults in one boot, the slot stays `faulted` until Android restarts. With fewer slots, `runtime.displayPoolExhausted` can follow.
- state-machines.md §4 and display-and-windowing.md §3.2 declare the state as `faulted(DisplayFault)`.

### 17.4 `ReinstallReason` and `BrokenReason`

Declared in [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §5. The app row texts are those of [../02-design/host-ui.md](../02-design/host-ui.md) §5.3: "Needs attention: ‹reason›" with **Repair…** for `broken(reason)`, and "Reinstalling after Android reset…" for `needsReinstall`.

| State | ‹reason› text (chosen) | Entry shown |
|---|---|---|
| `needsReinstall(.userdataReset)` | — ("Reinstalling after Android reset…") | none. After three failed boots the state becomes `broken(.reinstallFailed(f))` |
| `needsReinstall(.userdataRestored)` | — (the same text) | as above |
| `broken(.removedInAndroid)` | "removed in Android" | none. **Repair…** reinstalls it |
| `broken(.signerChanged)` | "Android has a copy from a different developer" | none |
| `broken(.artifactMissing)` | "APKRun's copy of the app is missing" | none |
| `broken(.reinstallFailed(f))` | "couldn't be reinstalled" | the entry of `f` under **Details** |

- `apkrun list` prints the same reason texts in its status column (chosen). `apkrun repair <package>` is the CLI form of **Repair…** (`reinstallApp`, §4).
- The health check `store.packages` reports these states (§20.2).

### 17.5 `UpdateOutcome`, `RollbackReason`, and `SkipReason`

Declared in [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §6 and [../02-design/update-system.md](../02-design/update-system.md) §5, §8.3. The app row texts are those of [../02-design/host-ui.md](../02-design/host-ui.md) §5.3.

| Outcome | App row | Entry shown | Counts as failed for `apkrun update` |
|---|---|---|---|
| `updated(from:to:)` | "Up to date". An optional notification | none | no |
| `rolledBack(.healthCheckFailed(f))` | "Rolled back to {version}" with **Details** | `f` (`update.healthCheckFailed`) and the rollback text of update-system.md §8.3 | yes |
| `rolledBack(.userRequested)` | "Rolled back to {version}" | none | no |
| `keptAfterFailedHealthCheck(f)` | "Update failed" with **Details**, notification with **Roll Back** | `f` | yes |
| `skipped(.upToDate)` | "Up to date" | none | no |
| `skipped(.checkFailed(f))`, `skipped(.downloadFailed(f))` | unchanged (chosen). Three failures in a row make `updates.providers` warn | `f` in the history and in `apkrun update` | yes |
| `skipped(.validationFailed(v))`, `skipped(.installFailed(s))` | "Update failed" with **Details** (chosen) | `update.validation` or `update.installFailed` with its cause | yes |
| `skipped(.userSkipped)`, `skipped(.authorityChanged)` | unchanged | none | no |

- A failed rollback leaves the package `broken`. The row shows the message of `update.rollbackFailed` ("APKRun couldn't restore {app}.") with **Repair** (update-system.md §8.3).
- `apkrun update` (all packages) prints one line per package and exits 2 when at least one package counts as failed (§19.1). `apkrun update <package>` exits with the exit code of the failure's entry.

### 17.6 Host and Android system update states

`HostState` ([runtime-api.md](runtime-api.md) §3.7, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6):

| Case | User text | Entry |
|---|---|---|
| `normal` | — | — |
| `updating(targetBuild)` | "Updating APKRun…" in control clients. Screen U in launchers | refused operations: `runtime.hostUpdating` |
| `restartPending(bundleBuild)` | Home banner "APKRun was updated. Restart Android to finish. {count} apps will close." with **Restart Now**. Menu bar item "Finish updating APKRun…" | refused operations: `runtime.hostUpdating`. Health: `diagnostics.serviceVersionMismatch / restartPending` (§20.2) |

`ImageUpdatePhase` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.3):

| Phase | User text | Entry |
|---|---|---|
| `idle`, `checking` | — | feed errors of catalog §14.2 go to health (`maintenance.imageUpdate`) |
| `available`, `downloading`, `installing` | the progress in Settings → General | download and install failures of catalog §14.2 |
| `ready` | "Android system update ready" with **Update Now** in the menu bar and as a notification, in ask mode or after 7 days of waiting (runtime-maintenance.md §7.3, §7.4) | — |
| `applying` | "Updating Android… (‹phase›)" in the runtime header (`bootPurpose = .imageUpdate`), screen U and then the placeholder "Updating Android…" in launchers | — |
| `failed(candidate, f, retryAt)` | the Settings status line of `f` | `f`, a `maintenance.*` entry. The phase retries at `retryAt` |

- `ImageUpdateOutcome` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.3): `installed(version)` has no text. `rejected(version, f)` shows `f` (normally `maintenance.imageMigrationFailed`), and a later apply of that version without `retryRejected` is `maintenance.imageUpdateRejected`. `rolledBack(to:)` is the user's **Go Back…** and has no error.
- `BootPurpose` ([runtime-api.md](runtime-api.md) §5.3): `normal` and `firstBoot` show "Starting Android…" with the boot phase text. `imageUpdate(from:to:)` shows "Updating Android… (‹phase›)" ([../02-design/host-ui.md](../02-design/host-ui.md) §5.2).
- "Android needs an update to work with this version of APKRun." on Home and in wrappers is the progress text of runtime-maintenance.md §4.10. The error behind it is `runtime.image(image.incompatibleProtocol / hostNewer)`. `image.incompatibleRuntime` needs a newer APKRun and shows its own entry (catalog §9).

### 17.7 `WrapperState`

Declared in [../02-design/wrapper.md](../02-design/wrapper.md) §9.1.

| State | App page (wrapper.md §9.1) | Home app row (host-ui.md §5.3) | `wrappers.status` | Entry when an operation needs the wrapper |
|---|---|---|---|---|
| `valid`, `moved` | — | — | pass | — |
| `missing` | "Mac app not found" · **Create Mac App** · **Remove from List** | "Mac app not found" | warning | `wrapper.wrapperNotFound` |
| `inaccessible` | "APKRun can't check this location" (information only) | "APKRun can't check this location" | pass | — |
| `signatureInvalid` | "This Mac app was modified" · **Create It Again** | "This Mac app was modified" | warning | `wrapper.bundleInvalid / signatureInvalid` |
| `unknownPackage` | "‹App› isn't installed" · **Move Mac App to Trash** · **Install from Mac App** for portable wrappers | — | warning | `wrapper.packageNotInstalled` |
| refresh reasons | badge "Update available" · **Update Mac App**, **Update All Mac Apps** | "Mac app can be updated" | `wrappers.launcher`: information, or a warning two majors behind | `wrapper.launcherTooOld` in the launcher (screen L) |

### 17.8 `AgentConnectionState`

Declared in [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §4.1.

| Case | Effect | Entry |
|---|---|---|
| `notStarted`, `connecting(attempt)` | the boot is still running | a required agent that doesn't connect within 30 s after `bootCompleted`: `runtime.requiredAgentUnavailable` |
| `connected` | — | — |
| `reconnecting(since, attempt)` | accessors of `ReadyRuntime` throw | `runtime.guestAgentUnavailable` for a request. After more than 5 s, health `agent.guest` or `agent.store` fails. After 30 s while `ready`: `runtime.requiredAgentUnavailable` |
| `incompatible(version)` | the boot fails, no retries | `runtime.agentIncompatible / hostNewer` or `/ guestNewer` |
| `paused` | the VM is suspended. No pings, no timeouts | — |

The restart limit of [../02-design/guest-components.md](../02-design/guest-components.md) §3.3 (3 restarts per minute) and the protocol-violation limit of [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §12.2 are not cases of this enum. Both make health `agent.guest` (or `agent.store`) fail with `runtime.requiredAgentUnavailable` (runtime-daemon.md §12, catalog §20.2).

### 17.9 `ImportRelation` and import warnings

Declared in [../02-design/package-store.md](../02-design/package-store.md) §4.7.

| Case | Result | Entry |
|---|---|---|
| `newPackage` | the preview, then the install | — |
| `sameAsInstalled` | "Already installed" | `store.alreadyInstalled` (a warning, exit 0) |
| `reinstallSameVersion` | allowed: install mode `REINSTALL` | — |
| `update(from:)` | a manual update through UpdateCore | `update.*` (catalog §11) |
| `downgrade(from:)` | refused | `store.downgradeRefused` (exit 5) |
| `otherSigner` | refused | `store.signerMismatch` (exit 5) |
| `uninstalledWithData(version)` | the install restores the kept data | a kept version newer than the file: `store.downgradeRefused` (chosen, as for a bootstrap, catalog §12.2) |

The import warnings of package-store.md §4.6 appear in the preview and in `apkrun inspect`. They are not errors and don't change the exit code. `ImportWarning` is declared in package-store.md §4.7. The catalog chooses the preview texts:

| Case | Condition | Preview text (chosen) |
|---|---|---|
| `missingHardwareFeature(feature)` | `uses-feature android:required="true"` for hardware that Android in APKRun lacks | "{app} asks for hardware that isn't available ({feature}). It may not work." |
| `certificateOnlyVerification` | the signature was verified as `.certificateOnly` (package-store.md §4.5) | "APKRun could check only the certificate of this file, not its whole signature." |
| `debuggable` | `debuggable="true"` | "This is a debug build of {app}." |
| `lowTargetSDK(target)` | the target SDK is far below the guest (below 28) | "{app} was made for an old Android version ({target}). It may behave differently." |

### 17.10 Log events, counters, and omitted items

These names look like codes but are not entries (§2.3).

| Name | Kind | Owner | Meaning | User-visible |
|---|---|---|---|---|
| `store.hostCheckMissed` | log event | [../02-design/package-store.md](../02-design/package-store.md) §6.4 | Android rejected as incompatible a package that host inspection accepted | no. The user sees `store.guestInstallFailed / incompatible` |
| `verifier.disagreement` | log event | [../02-design/package-store.md](../02-design/package-store.md) §17 | the host verifier and Android disagree about a signature | no |
| `integration.denied{kind, reason}` | counter, debug log | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2.3 | an integration request was refused. `reason` is an `IntegrationDenial` case | no. An operation that the user started gets `integration.disabled` with that variant |
| `input.dropped.rate`, `input.dropped.notRunning`, `input.dropped.invalid`, `input.ime.unmappedCommand`, `input.coalesced` | counters | [../02-design/input.md](../02-design/input.md) §11 | input events dropped or merged | only through `agent.input` (§20.2) |
| `diagnostics.mirrorDropped` | counter | [../02-design/diagnostics.md](../02-design/diagnostics.md) §3.3 | log entries dropped by the file mirror | in the bundle manifest |
| `omitted[].reason` | bundle manifest | [../02-design/diagnostics.md](../02-design/diagnostics.md) §6.5, §8.2 | an item that is not in the bundle: a contributor failed or timed out, the Guest Agent was unavailable, or `redactionFailed` | in `summary.txt` ("Omitted: …") |

- An `omitted` reason is the case name of the cause when there is one (`guestAgentUnavailable`), otherwise a fixed key: `timedOut`, `redactionFailed`, `notRunning` (chosen).
- An error that is logged carries its code in `err=` (§3.6). That is the error, not a separate event.

---

## 18. Launcher screens

### 18.1 Screens and entries

The launcher's screens are those of [../02-design/wrapper.md](../02-design/wrapper.md) §5.4. Each shows the entry's message as the title, its remediation below, the primary action, and **Quit**. Each step of the startup sequence (wrapper.md §5.2) stops at its first failure, so only one screen applies at a time.

| Screen | Entries and triggers | Primary action | Behavior |
|---|---|---|---|
| R | `wrapper.runtimeMissing` | **Get APKRun**: opens `LauncherBuild.downloadURL` | — |
| S | `wrapper.runtimeNotReady`. The launcher raises it when APKRun.app exists and the connection fails with `runtime.serviceUnavailable` (any reason, chosen), and for `runtime.notProvisioned` | **Open APKRun** | retries the connection every 2 s for 60 s, then stays on S (chosen) |
| V | `wrapper.runtimeTooOld` | **Check for Updates** (`apkrun://settings/general`) | — |
| L | `wrapper.launcherTooOld` | **Update Mac App** (`apkrun://package/<id>/mac-app`) | — |
| A | "Waiting for approval in APKRun…" while the request is pending. Then `wrapper.approvalDenied` or `wrapper.approvalTimedOut` | **Open APKRun** | — |
| N | `runtime.packageNotInstalled`, or the registry has no package for this bundle ID | **Open APKRun** (`apkrun://package/<id>`). Portable wrappers: **Install from This App** | a failed bootstrap install shows screen E with its `wrapper.*` or `store.*` entry |
| D | `wrapper.wrapperDamaged`, `wrapper.bundleInvalid` and its variant | **Open APKRun** | — |
| T | `wrapper.translocated` | **Quit** only | — |
| E | every other entry: `ended(.error(f))`, or a failed `hello`, `openSession`, or `importBootstrap` | **Try Again**, **Open APKRun** | see below |
| U | "APKRun is updating. {app} opens again when the update is finished." Triggered by `ended(.runtimeUpdating)`, `HelloReply.hostState == updating`, or `runtime.hostUpdating` | **Quit** only | reconnects and calls `openSession` every 2 s for up to 10 minutes, then shows screen E with `runtime.hostUpdating` (chosen) and **Try Again** |

- Screen E always has **Try Again**. The entry's action (§4) decides the second button: **Open APKRun** with the action's `apkrun://` URL, or the action's own launcher button for `updateAPKRun` (**Check for Updates**), `updateMacApp` (**Update Mac App**), and `reportProblem` (**Report a Problem…**). `retry` and `restartAndroid` add nothing, because **Try Again** does both. `none` gives **Open APKRun** with `apkrun://package/<id>`.
- Try Again runs the startup sequence again from `hello`.
- The launcher renders entries from `ErrorCatalog.generated.swift` (§3.7). It never shows the `code:` line.

### 18.2 Launcher texts that are not entries

These texts are in `Apps/APKRunLauncher/Localizable.xcstrings` ([../02-design/wrapper.md](../02-design/wrapper.md) §5.9). The keys are chosen here. The texts come from wrapper.md and [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.3.

| Key | English text | Where |
|---|---|---|
| `launcher.placeholder.starting` | "Starting Android…" | the placeholder while the session is `requested`, `waitingForRuntime`, or `booting`, with the boot phase text |
| `launcher.placeholder.updatingAndroid` | "Updating Android…" | the placeholder during an Android system update |
| `launcher.screen.waitingForApproval` | "Waiting for approval in APKRun…" | screen A |
| `launcher.screen.updating` | "APKRun is updating. {app} opens again when the update is finished." | screen U |
| `launcher.session.crashed` | "{app} stopped unexpectedly" | `ended(.appCrashed)` |
| `launcher.session.reconnecting` | "APKRun restarted — reopening…" | a connection that was invalidated (§17.1) |
| `launcher.bootstrap.prompt` | "Install {app} {version} from this Mac app?" | **Install from This App** on screen N |
| `launcher.button.getAPKRun`, `.openAPKRun`, `.checkForUpdates`, `.updateMacApp`, `.installFromThisApp`, `.tryAgain`, `.reopen`, `.reportProblem`, `.quit` | Get APKRun, Open APKRun, Check for Updates, Update Mac App, Install from This App, Try Again, Reopen, Report a Problem…, Quit | buttons |

- The approval dialog "Allow “{app}” to open {package} in APKRun?" is an APKRun.app text ([../02-design/wrapper.md](../02-design/wrapper.md) §7.3), not a launcher text.
- The screen texts of R, S, V, L, D, N, and T are the messages of their entries (catalog §12, §7.3). They have no launcher key.

---

## 19. CLI exit mapping

### 19.1 Rules

`CLI/apkrun/Support/ExitCodes.swift` reads `cliExit` from `ErrorCatalog.generated.swift` (chosen), so the mapping can't drift from the catalog. Exit codes are those of [../02-design/cli.md](../02-design/cli.md) §3.3. Rules, in order:

1. An `APKRunError` exits with its entry's `cliExit`. A variant has the exit code of its entry (§3.4).
2. A transparent entry (`"cliExit": "cause"`) exits with the exit code of the first non-transparent error in its cause chain (§3.5).
3. A code that this build doesn't know exits with the exit code of its first known cause, or 1 (§3.8).
4. An error that is not an `APKRunError` is a bug. The CLI prints it as `runtime.internal` and exits 70 (chosen).
5. Warnings (`cliExit` 0) never set the exit code. When a command prints warnings and then fails, the failure decides.
6. `apkrun doctor` exits by its verdict (§20.1): 0, 1, or 3. The entries of its results don't set the exit code. `apkrun doctor --fix` exits by the verdict of the report that runs after the fixes.
7. Exit 2 is set by the command, not by an entry:
   - `apkrun install … --wrap` and `apkrun wrap <file> --install`: the package was installed, and creating the Mac app failed. The CLI prints the `wrapper.*` error and exits 2.
   - `apkrun update` for all packages: at least one package failed (§17.5). Each failed package prints its error. When the command fails before any package is checked, the error's own exit code applies (chosen).
8. Ctrl-C: the cancellation (`runtime.cancelled`, `update.cancelled`, `maintenance.cancelled`) exits 130. A second Ctrl-C exits 130 at once, without an entry ([../02-design/cli.md](../02-design/cli.md) §3.5).
9. A named `cliExitRule` overrides the entry's fallback `cliExit`. For `vm.configurationInvalid`, exit 70 applies only when every listed item has exit 70; otherwise it uses exit 1.
10. swift-argument-parser's usage errors map to `cli.invalidArguments` and exit 64 (§16). Raw argument text is never interpolated into this entry.
11. `--detach` exits 0 as soon as the operation has started.

The exit-code test ([../02-design/cli.md](../02-design/cli.md) §3.3) checks every fixture of a non-transparent entry against its `cliExit`, and every fixture of a transparent entry against the exit code of its cause.

### 19.2 Codes per exit

Variants are listed only when the entry is not.

| Exit | Name | Codes |
|---|---|---|
| 0 | warning | `store.alreadyInstalled`, `wrapper.registrationFailed`, `cli.versionSkew` |
| 1 | failure | every entry not listed in this table, including all health findings (§15.2, §20.3), and the generic entry for an unknown code (§3.8). `vm.configurationInvalid` exits 1 unless rule 9 applies |
| 2 | partial | no entry (§19.1 rule 7) |
| 3 | warnings | no entry (`apkrun doctor`, §20.1) |
| 4 | not found | `runtime.packageNotInstalled`, `runtime.operationNotFound`, `runtime.unknownSetting`, `image.recoveryPointMissing`, `store.packageNotFound`, `store.unknownSetting`, `wrapper.packageNotInstalled`, `wrapper.wrapperNotFound`, `wrapper.stagingExpired`, `wrapper.approvalNotFound`, `diagnostics.unknownHealthCheck` |
| 5 | refused | `runtime.notAuthorized`, `runtime.developerModeRequired`, `image.downgradeRejected`, `store.reservedPackage`, `store.downgradeRefused`, `store.signerMismatch`, `update.downgrade`, `update.signerMismatch`, `update.lineageMissingCapability`, `wrapper.approvalDenied`, `wrapper.bootstrapNotAllowed`, `integration.disabled`, `integration.linkRejected`, `integration.pathRejected`, `integration.folderRefused`, `integration.readOnly`, `maintenance.imageUpdateRejected`, `cli.declined`, `cli.developerModeRequired` |
| 64 | usage | `runtime.invalidSettingValue`, `store.invalidSettingValue`, `wrapper.invalidName`, `cli.invalidPackageName`, `cli.invalidSourceSpec`, `cli.invalidArgument`, `cli.invalidArguments` |
| 69 | unavailable | `runtime.hostStartupFailed`, `runtime.notProvisioned`, `runtime.apiVersionMismatch`, `runtime.serviceUnavailable`, `wrapper.runtimeMissing`, `wrapper.runtimeNotReady`, `maintenance.agentRegistrationFailed` |
| 70 | internal | `vm.invalidTransition`, `vm.cpuCountOutOfRange`, `vm.memoryOutOfRange`, `vm.kernelNotUncompressedImage`, `vm.initrdTooLarge`, `vm.commandLineInvalid`, `vm.diskIsAndroidSparse`, `vm.diskSyncModeTestOnly`, `vm.duplicateDisk`, `vm.diskIdentifierInvalid`, `vm.missingSystemConsole`, `vm.invalidMACAddress`, `vm.machineIdentifierInvalid`, `vm.customDeviceInvalid`, `vm.microphoneUsageDescriptionMissing`, `vm.frameworkRejected`, `vm.vsockDeviceNotConfigured`, `vm.vsockDeviceUnavailable`, `vm.configurationInvalid` (only when every item exits 70), `graphics.scanoutInvalid`, `graphics.modeUnsupported`, `runtime.invalidTransition`, `runtime.malformedRequest`, `runtime.internal`, `guestProtocol.frameTooLarge`, `guestProtocol.malformedFrame`, `image.bootconfigConflict`, `image.bootconfigTooLarge`, `image.cmdlineTooLong`, `cli.malformedReply` |
| 75 | try again | `vm.vsockPortNotListening`, `graphics.deviceNotReady`, `runtime.hostShuttingDown`, `runtime.hostUpdating`, `runtime.instanceLocked`, `runtime.busy`, `runtime.guestAgentUnavailable`, `runtime.requestTimedOut`, `guestProtocol.disconnected`, `guestProtocol.agentUnavailable`, `store.operationInProgress`, `store.packageInUse`, `update.providerRateLimited`, `wrapper.wrapperRunning`, `integration.guestUnavailable`, `maintenance.hostUpdateBusy`, `maintenance.hostUpdateSessionsOpen` |
| 130 | interrupted | `runtime.cancelled`, `update.cancelled`, `maintenance.cancelled` |
| cause | — | `runtime.image`, `runtime.vm`, `runtime.vmConfiguration`, `runtime.graphics`, `store.runtimeUnavailable`, `update.validation`, `update.intrinsic`, `update.installFailed`, `maintenance.imageInstallFailed` |

- The launcher-only entries (`wrapper.runtimeMissing`, `wrapper.runtimeNotReady`, and the rest of catalog §12.3) never reach the CLI. `apkrun launch` gets `runtime.launchTimedOut` when the launcher shows one of their screens instead of connecting.
- Exit 4 for an unknown operation is `runtime.operationNotFound` (catalog §7.4, cli.md §3.3).

---

## 20. Health mapping

### 20.1 Verdicts

The verdict is the first row that applies ([../02-design/diagnostics.md](../02-design/diagnostics.md) §7.2). It is not an entry: the status line is a UI text.

| Verdict | Status line | `apkrun doctor` exit |
|---|---|---|
| `hostUnsupported` | "APKRun can't run on this Mac" | 1 |
| `serviceUnavailable` | "Background service not running" | 1 |
| `notSetUp` | "Setup not finished" | 1 |
| `graphicsFailure` | "Graphics failed to start" | 1 |
| `bootFailure` | "Android failed to start" plus the boot phase reached | 1 |
| `agentUnavailable` | "Guest Agent unavailable" / "Store Agent unavailable" | 1 |
| `degraded` | "Needs attention (‹n› warnings)", plus "· Android is not running" while Android is stopped | 3 without failures, otherwise 1 |
| `stopped` | "Healthy · Android is not running" | 0 |
| `healthy` | "Healthy" | 0 |

`HealthResult.error` is optional in diagnostics.md §7.1. The catalog uses it this way (chosen):

- `pass` and `skipped` results have no `error`. A skipped result shows "Android is not running" and its `lastKnown` result.
- `info` results have no `error`. Their `detail` is the text, for example "Developer mode: ADB on 127.0.0.1:6520".
- `warning` and `failure` results have an `error` whenever there is a next step. The GUI shows its remediation and action button on the row, and `apkrun doctor` prints its hint. A **Fix** button or `--fix` is offered only for the checks of diagnostics.md §7.5.
- A check that times out is a `warning` with `detail = "check timed out"` and no `error`.
- Below the status line, the GUI shows the remediation of the result that decided the verdict. That is the "Suggested:" line of `summary.txt` (diagnostics.md §8.3).
- The check ID and the code of its `error` are different strings (§2.3).

### 20.2 Checks and entries

The first column links the check to its owner. "Fix" marks the checks of diagnostics.md §7.5. States that the owning document doesn't give are marked "(chosen)". Codes marked † are the health-only findings of §20.3.

| Check | State | Entry | Fix |
|---|---|---|---|
| `host.appleSilicon`, `host.macOSVersion`, `host.hypervisor` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §7.3) | failure | `runtime.hostRequirementsNotMet` with one item | — |
| `host.appLocation`, `host.appSignature`, `host.componentVersions`, `host.memory` (diagnostics.md §7.3) | as in catalog §15.2 | `diagnostics.appNotInApplications`, `diagnostics.appSignatureInvalid`, `diagnostics.componentVersionMismatch`, `diagnostics.lowMemory` | — |
| `host.dataVolume` (diagnostics.md §7.3) | warning below 10 GiB. Failure on a volume that is not APFS (chosen) | `diagnostics.lowDiskSpace`; `runtime.hostRequirementsNotMet / apfsVolume` | — |
| `apkrund.registration` (diagnostics.md §7.3) | failure | `runtime.serviceUnavailable / notRegistered` or `/ requiresApproval` | yes |
| `apkrund.reachable` (diagnostics.md §7.3) | failure | `runtime.serviceUnavailable`. Another API major: `runtime.apiVersionMismatch` | — |
| `apkrund.version` (diagnostics.md §7.3) | warning | `diagnostics.serviceVersionMismatch`, variant `restartPending` or `androidRunning` | yes, only while Android is stopped |
| `apkrund.crashLoop` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §12) | failure | `diagnostics.serviceCrashLoop` | — |
| `vm.virtualizationSupported` ([../02-design/vm.md](../02-design/vm.md) §14) | failure | `vm.virtualizationUnavailable` | — |
| `vm.state` (vm.md §14) | failure | the `vm.*` entry of `failed(f)` | — |
| `vm.network` (vm.md §9.2) | warning | `vm.networkAttachmentLost` † | — |
| `vm.consoleWriter` (vm.md §14) | warning (chosen) | `vm.consoleLogWriteFailed` † | — |
| `runtime.provisioning` (runtime-daemon.md §12) | failure | `runtime.notProvisioned` | — |
| `image.current` ([../02-design/android-image.md](../02-design/android-image.md) §14.3) | failure | the verification entry: `image.manifestInvalid`, `image.signatureInvalid`, `image.untrustedKey`, `image.hashMismatch`, `image.missingFile`, `image.unexpectedFile`. No image: `runtime.notProvisioned` | — |
| `image.instance` (android-image.md §14.3) | failure (chosen) | `image.instanceMissing`, `image.instanceCorrupt` | — |
| `image.kind` (android-image.md §14.3) | warning | `image.developmentImageInUse` † | — |
| `image.migration` (android-image.md §14.3) | failure (chosen) | `image.migrationInterrupted` | — |
| `image.recoveryPoint` (android-image.md §14.3) | warning (chosen) | `image.recoveryPointStale` † | — |
| `image.freeSpace` (android-image.md §14.3) | warning | `diagnostics.lowDiskSpace` | — |
| `runtime.state` (runtime-daemon.md §12) | failure | the entry of `failed(f)` | — |
| `runtime.boot` (runtime-daemon.md §12) | failure: the last boot failed. Warning (chosen): it took more than 2× the median | failure: the entry of the last boot's failure (`runtime.bootTimedOut`, `runtime.bootStalled`, `runtime.kernelPanic`, `runtime.androidBootFailed`, `runtime.bootLoop`, `runtime.graphics`, …). Warning: `runtime.slowBoot` † | — |
| `runtime.stop` (runtime-daemon.md §12) | warning (chosen) | `runtime.stopsForced` † | — |
| `runtime.memoryPressure` (runtime-daemon.md §5.5) | warning at both levels (chosen) | `runtime.hostMemoryPressure` † | — |
| `graphics.device` (diagnostics.md §7.4) | failure | `graphics.deviceSetupFailed` † | — |
| `graphics.renderer` (diagnostics.md §7.4) | warning: one `rendererLost` recovered in 24 h. Failure: `rendererInitFailed`, or `rendererLost` twice in 24 h | `graphics.rendererLost`, `graphics.rendererInitFailed`, both with `startGraphicsSafeMode` | — |
| `graphics.guestDriver` (deep, diagnostics.md §7.4) | failure | `graphics.softwareRendering` † | — |
| `graphics.present` (diagnostics.md §7.4) | warning | `graphics.presentationSlowPath` † | — |
| `graphics.memory` (diagnostics.md §7.4) | warning | `graphics.memoryLimitReached` † | — |
| `graphics.safeMode` (diagnostics.md §7.4) | warning | `graphics.safeModeOn` † | — |
| `agent.guest`, `agent.store` (runtime-daemon.md §12) | failure | `reconnecting` for more than 5 s, stopped reconnecting after protocol violations (catalog §8.1), or the restart limit of guest-components.md §3.3: `runtime.requiredAgentUnavailable`. `incompatible`: `runtime.agentIncompatible` | — |
| `agent.input` (diagnostics.md §7.4) | warning | `runtime.inputDegraded` † | — |
| `agent.ime` (diagnostics.md §7.4) | warning | `runtime.inputMethodNotSelected` † | yes |
| `agent.developerMode` (diagnostics.md §7.4) | info: ADB on in developer mode. Failure: ADB on while developer mode is off | failure: `runtime.adbEnabledUnexpectedly` † | — |
| `store.journal` ([../02-design/package-store.md](../02-design/package-store.md) §13) | warning / failure | warning: `store.journalLineDropped` †. Failure: `store.journalUnreadable` | — |
| `store.pending` (package-store.md §13) | warning | `store.postBootTaskRequeued` † | — |
| `store.ownership` (package-store.md §13) | warning | `store.updateOwnerMissing` † | — |
| `store.externallyUpdated` (package-store.md §13) | warning | `store.updatedOutsideAPKRun` † | — |
| `store.hostSpace` (package-store.md §13) | warning below 5 GiB. Failure below 2 GiB | warning: `diagnostics.lowDiskSpace`. Failure: `store.insufficientHostSpace` | — |
| `store.packages` (package-store.md §13) | warning / failure | warning: `store.reinstallPending` †. Failure: `store.packagesNeedRepair` † | — |
| `updates.scheduler` ([../02-design/update-system.md](../02-design/update-system.md) §14) | warning | `update.schedulerLate` † | — |
| `updates.providers` (update-system.md §14) | warning / failure | warning: the package's last check failure (`update.providerUnreachable`, `update.providerHTTPStatus`, `update.providerMetadataInvalid`, …). Failure: `update.providerSignatureInvalid` | — |
| `updates.waiting` (update-system.md §14) | warning | `update.stagedTooLong` † | — |
| `updates.failed` (update-system.md §14) | warning | the failure of the last run, normally `update.healthCheckFailed` | — |
| `wrappers.template` ([../02-design/wrapper.md](../02-design/wrapper.md) §14) | warning | `wrapper.launcherTemplateInvalid` | — |
| `wrappers.registry` (wrapper.md §14) | warning | `wrapper.registryUnavailable`, also for pending entries left after recovery (chosen) | — |
| `wrappers.status` (wrapper.md §14) | warning | per state (§17.7): `wrapper.wrapperNotFound`, `wrapper.bundleInvalid / signatureInvalid`, `wrapper.packageNotInstalled` | — |
| `wrappers.launcher` (wrapper.md §14) | info: one major behind. Warning: two majors behind | warning: `wrapper.launcherTooOld` | — |
| `wrappers.registration` (wrapper.md §14) | warning | `wrapper.registrationFailed` | yes |
| `integrations.capabilities` ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §13) | warning | `integration.notSupportedOnImage` | — |
| `integrations.notificationListener` (desktop-integration.md §13) | warning | `integration.notificationAccessMissing` † | yes |
| `integrations.browserRole` (desktop-integration.md §13) | warning | `integration.browserRoleMissing` † | yes |
| `integrations.sharedFolders` (desktop-integration.md §13) | warning | `integration.folderUnavailable` with its variant | — |
| `integrations.microphone` (desktop-integration.md §13) | warning | `integration.microphonePermissionDenied`, `integration.microphoneNeedsRestart` | — |
| `integrations.time` (desktop-integration.md §13) | warning | `integration.timeSyncFailed` † | — |
| `maintenance.selfUpdate` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §12) | info: an update is available, or automatic checks are off | none | — |
| `maintenance.selfUpdate` | warning | a critical update waiting for more than 3 days: `maintenance.criticalUpdateWaiting` †. No successful check for 7 days: `maintenance.selfUpdateCheckOverdue` †. `restartPending` for more than 24 hours: `diagnostics.serviceVersionMismatch / restartPending`. An abandoned host update in the last 24 hours: `maintenance.hostUpdateAbandoned`. APKRun was downgraded: `maintenance.hostDowngraded` † | — |
| `maintenance.imageUpdate` (runtime-maintenance.md §12) | info: an update is downloading or ready, or a newer image needs a newer APKRun | none | — |
| `maintenance.imageUpdate` | warning | ready for more than 14 days: `maintenance.imageUpdateWaiting` †. The last migration was rejected: `maintenance.imageMigrationFailed`. The feed: `maintenance.imageFeedSignatureInvalid`, `maintenance.imageFeedReplayed`, `maintenance.imageFeedExpired`, `maintenance.imageFeedInvalid / schemaVersion`. No successful feed check for 7 days: `maintenance.imageCheckOverdue` †. Not enough space: `maintenance.insufficientSpace` | — |
| `maintenance.imageUpdate` | failure | the current image can't boot with this APKRun: `image.incompatibleProtocol / hostNewer` or `image.incompatibleRuntime`. No compatible image in the feed: `maintenance.noCompatibleImage` | — |

When apkrund is unreachable, every non-host check other than `apkrund.registration` is `skipped` with "Background service not running" and no `error`. The failed `apkrund.registration` or `apkrund.reachable` row carries the `runtime.serviceUnavailable` entry and its remediation (diagnostics.md §7.1, §7.3).

### 20.3 Health-only finding codes

These cases cover the checks of §20.2 that no other entry covers. Each is a case of its domain's failure type that is used only as a health finding. The owning documents declare them in their failure enums and name them in their health tables (§22.1). A finding is never thrown, so its `cliExit` is 1 and is never used (as in catalog §15.2). When #061 creates `errors.json`, the rows move into their domain sections. No code equals a check ID.

| Case | Code | Check | State | Message | Remediation · action |
|---|---|---|---|---|---|
| `networkAttachmentLost` | `vm.networkAttachmentLost` | `vm.network` | warning | "Android lost its network connection." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` |
| `consoleLogWriteFailed` | `vm.consoleLogWriteFailed` | `vm.consoleWriter` | warning | "APKRun couldn't write Android's console log." | "Check the free disk space. Settings → Storage shows what APKRun uses." `openStorageSettings` |
| `developmentImageInUse` | `image.developmentImageInUse` | `image.kind` | warning | "Android runs from a development system image." | "For everyday use, install the standard Android system in Settings → General." `updateAndroid` |
| `recoveryPointStale` | `image.recoveryPointStale` | `image.recoveryPoint` | warning | "APKRun keeps an old Android recovery point." | "It uses disk space. Settings → Storage shows it." `openStorageSettings` |
| `slowBoot(duration)` | `runtime.slowBoot` | `runtime.boot` | warning | "The last start of Android took {duration}, more than twice as long as usual." | "If starts stay slow, create a diagnostics report." `reportProblem` |
| `stopsForced` | `runtime.stopsForced` | `runtime.stop` | warning | "Android didn't shut down by itself the last 3 times." | "If it happens again, create a diagnostics report." `reportProblem` |
| `hostMemoryPressure` | `runtime.hostMemoryPressure` | `runtime.memoryPressure` | warning | "This Mac is low on memory, so Android may be slow." | "Quit apps you don't need, or give Android less memory in Settings → Runtime." `openRuntimeSettings` |
| `inputDegraded` | `runtime.inputDegraded` | `agent.input` | warning | "Keyboard and mouse input to Android isn't working correctly." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` |
| `inputMethodNotSelected` | `runtime.inputMethodNotSelected` | `agent.ime` | warning | "Android isn't using APKRun's keyboard, so typing may not work." | "Choose Fix, or run: apkrun doctor --fix" `none` |
| `adbEnabledUnexpectedly` | `runtime.adbEnabledUnexpectedly` | `agent.developerMode` | failure | "Android's debugging connection is on, but developer mode is off." | "Restart Android. If it stays on, report the problem." `restartAndroid` |
| `deviceSetupFailed` | `graphics.deviceSetupFailed` | `graphics.device` | failure | "Android's graphics device didn't start correctly." | "Start Android in Graphics Safe Mode. If that doesn't help, create a diagnostics report." `startGraphicsSafeMode` |
| `softwareRendering` | `graphics.softwareRendering` | `graphics.guestDriver` | failure | "Android draws without the Mac's graphics processor, so apps are slow." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` |
| `presentationSlowPath` | `graphics.presentationSlowPath` | `graphics.present` | warning | "Android's windows are drawn through a slower path." | "Report the problem, so that it can be fixed." `reportProblem` |
| `memoryLimitReached` | `graphics.memoryLimitReached` | `graphics.memory` | warning | "Android apps reached the graphics memory limit." | "Close some Android app windows." `none` |
| `safeModeOn` | `graphics.safeModeOn` | `graphics.safeMode` | warning | "Graphics safe mode is on. Apps are slower." | "Turn it off in Settings → Troubleshooting when graphics work again." `openTroubleshooting` |
| `journalLineDropped` | `store.journalLineDropped` | `store.journal` | warning | "APKRun dropped an incomplete entry from its record of app changes." | "No action is needed. If an app looks wrong, choose Repair… on its page." `none` |
| `postBootTaskRequeued` | `store.postBootTaskRequeued` | `store.pending` | warning | "A change to an app couldn't finish after two starts of Android." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` |
| `updateOwnerMissing(count)` | `store.updateOwnerMissing` | `store.ownership` | warning | "Android doesn't reserve updates of some apps for APKRun ({count})." | "APKRun still updates them, but other installers in Android could update them too." `none` |
| `updatedOutsideAPKRun(count)` | `store.updatedOutsideAPKRun` | `store.externallyUpdated` | warning | "Some apps were updated in Android without APKRun ({count})." | "APKRun now uses the versions in Android. No action is needed." `none` |
| `reinstallPending(count)` | `store.reinstallPending` | `store.packages` | warning | "Some apps are waiting to be reinstalled in Android ({count})." | "APKRun reinstalls them when Android starts. If they keep waiting, create a diagnostics report." `none` |
| `packagesNeedRepair(count)` | `store.packagesNeedRepair` | `store.packages` | failure | "Some apps need attention ({count})." | "Choose Repair… on the page of each app, or run: apkrun repair <package>" `none` |
| `schedulerLate(duration)` | `update.schedulerLate` | `updates.scheduler` | warning | "Automatic update checks haven't run for {duration}." | "Quit and reopen APKRun. If it happens again, create a diagnostics report." `reportProblem` |
| `stagedTooLong(PackageID)` | `update.stagedTooLong` | `updates.waiting` | warning | "An update of {app} has been waiting for more than 7 days." | "Quit {app} to install it, or choose Update Now." `none` |
| `notificationAccessMissing` | `integration.notificationAccessMissing` | `integrations.notificationListener` | warning | "APKRun can't read Android notifications, so they don't appear on the Mac." | "Choose Fix, or run: apkrun doctor --fix" `none` |
| `browserRoleMissing` | `integration.browserRoleMissing` | `integrations.browserRole` | warning | "Links in Android apps can't open on the Mac." | "Choose Fix, or run: apkrun doctor --fix" `none` |
| `timeSyncFailed` | `integration.timeSyncFailed` | `integrations.time` | warning | "Android's clock or time zone may differ from the Mac's." | "Restart Android. If it happens again, create a diagnostics report." `restartAndroid` |
| `criticalUpdateWaiting(version)` | `maintenance.criticalUpdateWaiting` | `maintenance.selfUpdate` | warning | "The important APKRun update {version} has been waiting for more than 3 days." | "Install it: choose Check for Updates." `updateAPKRun` |
| `selfUpdateCheckOverdue` | `maintenance.selfUpdateCheckOverdue` | `maintenance.selfUpdate` | warning | "APKRun hasn't checked for updates for 7 days." | "Check the internet connection, then choose Check for Updates." `updateAPKRun` |
| `hostDowngraded(version)` | `maintenance.hostDowngraded` | `maintenance.selfUpdate` | warning | "APKRun was downgraded from {version}." | "Install the latest version: choose Check for Updates." `updateAPKRun` |
| `imageUpdateWaiting(version)` | `maintenance.imageUpdateWaiting` | `maintenance.imageUpdate` | warning | "The Android system update {version} has been ready for more than 14 days." | "Install it in Settings → General." `updateAndroid` |
| `imageCheckOverdue` | `maintenance.imageCheckOverdue` | `maintenance.imageUpdate` | warning | "APKRun hasn't checked for Android system updates for 7 days." | "Check the internet connection, then check for updates in Settings → General." `updateAndroid` |

- A count in parentheses avoids plural forms, which `errors.json` doesn't have (chosen).
- The remediation "Choose Fix, or run: apkrun doctor --fix" is used only for checks with a fix (diagnostics.md §7.5).

---

## 21. Adding an error

1. **Declare the case** in the failure enum of the owning design document, with its associated values and a comment that says when it is raised. A sub-reason whose texts differ gets its own sub-enum (§3.4).
2. **Name it** by §2.1 and §2.2: lowerCamelCase, the condition and not the remedy, unique in its domain, and never equal to a health check ID (§2.3). Never rename or reuse a code.
3. **Write the entry**: `code`, `parameters` (only the kinds and names of §3.2, no paths or free text), `message` and `remediation` in `en` and `ja` by §3.3, `action` (§4), and `cliExit` (§19, [../02-design/cli.md](../02-design/cli.md) §3.3). A pure container is `"transparent": true` with `"cliExit": "cause"` (§3.5). Variants get their keys from the sub-enum (§3.4).
4. **Choose the exit code** by meaning: 4 for something that doesn't exist, 5 for a policy refusal, 64 for invalid input found before a request, 69 when apkrund isn't there, 70 for a bug, 75 when a retry can succeed, 130 for a cancellation, 0 for a warning, and 1 otherwise.
5. **Update the catalog.** Before #061 creates `errors.json`, add the row to this document. After it, edit `Packages/DiagnosticsCore/ErrorCatalog/errors.json` and run `swift scripts/errorgen.swift --markdown`, which regenerates `ErrorCatalog.generated.swift` and the tables of §5–§16 and §20.3. CI fails when the JSON and the tables differ.
6. **Add the fixture** for the case, with every variant, to the module's fixture list, and run `ErrorCatalogTests` and the exit-code test (§19.1). Release builds fail when a `ja` text is missing (§3.7).
7. **Check the surfaces.** Screen E and the GUI show a new entry without further work (§18.1). A new launcher screen, a new `RemediationAction`, or a new health finding needs a change to wrapper.md §5.4, diagnostics.md §2.3, or the owning health table as well.
8. **Remove a case** by retiring it: keep the entry with `"retired": true` (§2.2).

---

## 22. Open items and proposals

### 22.1 Cases first named here

This catalog first named these cases. The owning documents declare them now, so no row is marked **Proposed** (§1.2).

| Domain | Declared in | Cases |
|---|---|---|
| `vm` | [../02-design/vm.md](../02-design/vm.md) §13, §14 | `configurationInvalid` (catalog §5.2). Findings: `networkAttachmentLost`, `consoleLogWriteFailed` |
| `runtime` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §11, §12, [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §3 | `vmConfiguration`, `operationNotFound`, `serviceUnavailable` with `ServiceUnavailableReason`, `requestTimedOut`, `unknownSetting`, `invalidSettingValue` (catalog §7). The sub-enums `HostStartupStep`, `InstanceLockOwner`, `HostRequirement` (catalog §7.5). `SessionEndReason.packageUninstalled` (§17.1). Findings: `slowBoot`, `stopsForced`, `hostMemoryPressure`, `inputDegraded`, `inputMethodNotSelected`, `adbEnabledUnexpectedly` |
| `graphics` | [../02-design/graphics.md](../02-design/graphics.md) §13.1 | findings: `deviceSetupFailed`, `softwareRendering`, `presentationSlowPath`, `memoryLimitReached`, `safeModeOn` |
| `image` | [../02-design/android-image.md](../02-design/android-image.md) §14 | findings: `developmentImageInUse`, `recoveryPointStale` |
| `store` | [../02-design/package-store.md](../02-design/package-store.md) §4.7, §12, §13 | `unknownSetting`, `invalidSettingValue` (catalog §10.4). The sub-enums `ArchiveLimit`, `InconsistentField`, `InstallFailureKind` (catalog §10.6), and `ImportWarning` (§17.9). Findings: `journalLineDropped`, `postBootTaskRequeued`, `updateOwnerMissing`, `updatedOutsideAPKRun`, `reinstallPending`, `packagesNeedRepair` |
| `update` | [../02-design/update-system.md](../02-design/update-system.md) §13, §14 | the types `HealthCheckFailure` and `ProcessDeath` (catalog §11.3). Findings: `schedulerLate`, `stagedTooLong` |
| `wrapper` | [../02-design/wrapper.md](../02-design/wrapper.md) §13 | the sub-enums `IconInputProblem`, `BundleProblem`, `BootstrapProblem`, `BootstrapRefusal` (catalog §12.5) |
| `integration` | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §12, §13 | findings: `notificationAccessMissing`, `browserRoleMissing`, `timeSyncFailed` |
| `maintenance` | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §11, §12 | findings: `criticalUpdateWaiting`, `selfUpdateCheckOverdue`, `hostDowngraded`, `imageUpdateWaiting`, `imageCheckOverdue` |
| `diagnostics` | [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.1, §7.3 | the type `DiagnosticsFailure` with every case of catalog §15 |
| `cli` | [../02-design/cli.md](../02-design/cli.md) §3.3 | the type `CLIFailure` with every case of catalog §16, and `FileProblem` |

### 22.2 Format extensions

[../02-design/diagnostics.md](../02-design/diagnostics.md) §2.2 adopts these, and #061 implements them:

- `variants` with sub-enum keys, the fixed keys `hostNewer`, `guestNewer`, `sharedFolders`, `schemaVersion`, `restartPending`, and `androidRunning`, and the `items` parameter of list cases (§3.4).
- `transparent` and `"cliExit": "cause"` (§3.5).
- `retired` (§2.2).
- The generic entry for unknown codes and the rule that an unknown code with a known cause is transparent (§3.8).
- errorgen's `--markdown` output covers the tables of §5–§16 and §20.3.
- The rule for `HealthResult.error` (§20.1), which diagnostics.md §7.1 states.

### 22.3 Missing remediation actions

[../02-design/diagnostics.md](../02-design/diagnostics.md) §2.3 added `openDownloadsPage` (reinstall APKRun: `graphics.libraryMissing`, `wrapper.launcherTemplateInvalid`, `diagnostics.appSignatureInvalid`, `diagnostics.componentVersionMismatch`, `maintenance.noCompatibleImage`) and `openNotificationSettings` (`integration.notificationPermissionDenied`) for the next steps this section first listed. The URL is the Info.plist key `APKRunDownloadsURL` ([configuration.md](configuration.md) §7.1).

`RemediationAction` still has no action for these next steps. The affected entries use the action named in the table and say the step in the remediation text.

| Next step | Entries | Proposal |
|---|---|---|
| install an Android image again | `image.hashMismatch`, `image.missingFile`, and the other verification entries of catalog §9 | none: `openStorageSettings` leads to **Install from File…** |
| open System Settings → Privacy & Security → Files and Folders | `cli.fileNotAccessible / permissionDenied` | none: the CLI has no buttons |

### 22.4 Fixes for other documents

The catalog follows the design documents. Where two of them disagree, or where a text breaks the voice rules of §3.3, the catalog chose a form, and the owning documents follow it. The design documents and [runtime-api.md](runtime-api.md) have made the other fixes. This one remains:

| Location | Issue | Fix |
|---|---|---|
| | older names of `GraphicsFailure` cases | [graphics.md](../02-design/graphics.md) §13.1 is authoritative |
