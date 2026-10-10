# Command-Line Tool (`apkrun`)

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [runtime-daemon.md](runtime-daemon.md) §8.5, §10, [package-store.md](package-store.md) §11.4, [update-system.md](update-system.md) §11.3, [wrapper.md](wrapper.md) §12.2, [desktop-integration.md](desktop-integration.md) §11, [diagnostics.md](diagnostics.md), [runtime-maintenance.md](runtime-maintenance.md), [host-ui.md](host-ui.md), [../03-reference/runtime-api.md](../03-reference/runtime-api.md), [../03-reference/error-catalog.md](../03-reference/error-catalog.md), [../03-reference/configuration.md](../03-reference/configuration.md) |
| Tasks | #001 (skeleton), #027 (store commands, embedded), #032 (switch to RuntimeClient), #075 (`wrap`), #059 (`doctor`), #060 (`diagnostics`), and the command parts of every task that names a command below |

`apkrun` is the scripting and development interface to APKRun. It is a client of apkrund like APKRun.app ([runtime-daemon.md](runtime-daemon.md) §8.5). Everything it can do, apart from the `dev` commands, the GUI can do too.

This page is the complete command set. Subsystem documents show the commands they own. Those listings are summaries of this page.

---

## 1. Principles

1. **One code path.** Every non-`dev` command calls a `RuntimeService` operation through `RuntimeClient`. The CLI never touches `~/Library/Application Support/APKRun/`, never runs `adb`, and never talks to the VM ([../01-architecture/modules.md](../01-architecture/modules.md) §2, the CI lint of [package-store.md](package-store.md) §15).
2. **Same words as the GUI.** Error messages and remediations come from the error catalog. Plural forms and translations come from the String Catalog ([host-ui.md](host-ui.md) §13).
3. **Scriptable.** Stable exit codes (§3.3), `--json` for every command that prints data (§3.2), no prompts without a terminal (§3.4).
4. **Safe by default.** Destructive commands ask for confirmation unless `--yes` is given ([../01-architecture/security-model.md](../01-architecture/security-model.md) §3.1).

---

## 2. Build, installation, and authorization

- Source: `CLI/apkrun`, built with swift-argument-parser ([../01-architecture/modules.md](../01-architecture/modules.md) §1). Dependencies: `RuntimeClient`, `RuntimeAPI`, `DiagnosticsCore`. With the build flag `APKRUN_EMBEDDED_RUNTIME` (development builds only), `RuntimeHost`, `WindowingCore`, and `InputCore` as well, for the `dev` commands ([runtime-daemon.md](runtime-daemon.md) §10).
- Installed location: `APKRun.app/Contents/Resources/bin/apkrun` ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §4). The binary is signed with APKRun's identity, so apkrund's control endpoint accepts it ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).
- To put it on `PATH`, Settings → Advanced → **Install Command-Line Tool…** ([host-ui.md](host-ui.md) §9.9) shows, with a **Copy** button:

  ```sh
  sudo ln -sf "/Applications/APKRun.app/Contents/Resources/bin/apkrun" /usr/local/bin/apkrun
  ```

  A symlink keeps the signature valid (the kernel checks the real file). A copied binary also works until APKRun updates. After an update, `apkrun` detects that its version differs from apkrund's and prints a hint to use the symlink.
- Development builds install as `apkrun-dev` from `scripts/dev/install-dev-app.sh` and talk to `io.apkrun.apkrund.dev.xpc` ([runtime-daemon.md](runtime-daemon.md) §2.6).
- **Before #032** (M0–M3), the commands marked **E** in §4 run with the embedded runtime in the CLI process ([runtime-daemon.md](runtime-daemon.md) §10). #032 switches them to RuntimeClient without changing their syntax or output.

---

## 3. Conventions

### 3.1 Syntax

- `apkrun <command> [<subcommand>] [arguments] [options]`. Long options only, except `-y` (`--yes`), `-h` (`--help`), and `-v` (`--verbose`).
- `<package>` is an Android package name (`com.example.app`). It is validated against the package-name grammar before any request is sent.
- `<spec>` (update source) is `local:<path>`, `direct:<https-url>`, `fdroid[:<repository-url>#<fingerprint>]`, or `github:<owner>/<name>[:<asset-glob>][@prerelease]` ([update-system.md](update-system.md) §11.3).
- File arguments are opened by the CLI and passed as file handles. apkrund never opens a path given on the command line ([package-store.md](package-store.md) §4.1). Relative paths resolve against the current directory.
- Shell completion: `apkrun --generate-completion-script zsh|bash|fish` (swift-argument-parser). Package arguments complete from `apkrun list --json`.

### 3.2 Output

| Stream | Content |
|---|---|
| stdout | the result: tables, key/value blocks, or JSON |
| stderr | progress, warnings, errors, and prompts |

- Human output adapts to the terminal width and uses color only when stdout is a TTY and `NO_COLOR` is not set (`--no-color` forces it off).
- `--json` prints one JSON document on stdout and nothing else there:

  ```json
  { "schemaVersion": 1, "result": { … } }
  { "schemaVersion": 1, "error": { "code": "store.downgradeRefused", "message": "…", "remediation": "…", "operationID": "…" } }
  ```

  `result` is the RuntimeAPI DTO of the operation encoded with the rules of [../03-reference/runtime-api.md](../03-reference/runtime-api.md) (camelCase keys, ISO 8601 dates, `versionCode` as a number, digests as `sha256:` and lowercase hex; runtime-api.md §4.2, §4.3). New fields may appear in minor versions. Removing or renaming a field increments `schemaVersion`.
- `--quiet` prints only the essential result (for `install`, the package ID; for `wrap`, the bundle path).
- `--verbose` adds the operation ID and timings to human output.

### 3.3 Exit codes

| Code | Name | When |
|---|---|---|
| 0 | success | |
| 1 | failure | the operation failed with a typed error (code in the message and in JSON) |
| 2 | partial | the main step succeeded and a follow-up failed (installed but the Mac app could not be created; some packages of `update` failed) |
| 3 | warnings | `doctor` found warnings but no failures |
| 4 | not found | an unknown package, wrapper, operation (`runtime.operationNotFound`), or setting key |
| 5 | refused | refused by policy: downgrade, other signer, not authorized, blocked by a dialog the user declined |
| 64 | usage | invalid arguments (`EX_USAGE`, swift-argument-parser's validation failure) |
| 69 | unavailable | apkrund is not set up ([runtime-daemon.md](runtime-daemon.md) §8.5) or not reachable (`EX_UNAVAILABLE`) |
| 70 | internal | `RuntimeFailure.internal`, malformed replies (`EX_SOFTWARE`) |
| 75 | try again | `RuntimeFailure.busy`, the instance lock is held by another owner (`EX_TEMPFAIL`) |
| 130 | interrupted | Ctrl-C cancelled the operation (§3.5) |

The mapping from error domains and codes to exit codes is not a hand-written table. `CLI/apkrun/Support/ExitCodes.swift` reads each entry's `cliExit` from the generated catalog (`ErrorCatalog.generated.swift`, [../03-reference/error-catalog.md](../03-reference/error-catalog.md) §19.1), so it can't drift from the catalog. Every catalog code maps to exactly one exit code, except a transparent container entry, which maps to `"cause"`: the exit code of its cause ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §3.5).

Errors that the CLI raises itself, before or after a request to apkrund, belong to the `cli` domain ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §16):

```swift
public enum CLIFailure: APKRunError {
    case confirmationRequired(flag: String)                 // no TTY on stdin and no --yes (§3.4). Exit 1
    case declined                                           // the user answered no, or did not type Reset (§3.4). Exit 5
    case invalidPackageName(package: String)                // a <package> argument fails the grammar. No request is sent (§3.1). Exit 64
    case invalidSourceSpec(argument: String)                // a <spec> argument matches no update source form (§3.1). Exit 64
    case invalidArgument(argument: String, reason: String)  // another validation the CLI does itself, for example a --since duration. reason is a stable key. Exit 64
    case fileNotAccessible(file: String, FileProblem)       // a file argument can't be opened, or the --output file can't be created. file is the last path component. Exit 1
    case developerModeRequired(command: String)             // apkrun logs --guest while developer.enabled is off (§4.8). Exit 5
    case logsUnavailable                                    // /usr/bin/log fails and the file mirrors can't be read (§4.8). Exit 1
    case malformedReply(operation: String)                  // a reply the CLI can't decode. Exit 70
    case versionSkew(version: String, found: String)        // the CLI's build differs from apkrund's (§2). A warning. Exit 0
    case invalidArguments                                   // swift-argument-parser reports invalid command syntax. Exit 64
}

public enum FileProblem: String, Sendable, Codable {
    case notFound, permissionDenied, isDirectory
}
```

swift-argument-parser's usage failures (unknown commands, missing arguments, unknown options) are caught by the root command and rendered through `cli.invalidArguments` with exit 64. The parser's raw diagnostic is not logged or included in the error.

### 3.4 Confirmations and non-interactive use

- Commands that change or delete data show what will happen and ask `Continue? [y/N]` on the terminal.
- `--yes` answers yes. Without a TTY on stdin and without `--yes`, the command fails with `cli.confirmationRequired` (exit 1) and names the flag. A command never waits for input that cannot come.
- Reset Android asks the user to type `Reset`, like the GUI ([runtime-daemon.md](runtime-daemon.md) §9.5). `--yes` replaces the typing.

### 3.5 Long-running operations

Operations that return an `OperationHandle` ([runtime-daemon.md](runtime-daemon.md) §8.3):

- The CLI subscribes to the `operations` topic, shows a progress line on stderr (TTY only), and waits for the result.
- **Ctrl-C** sends `cancel(operationID)` and waits up to 10 s for the cancellation result. A second Ctrl-C exits at once and leaves the operation to finish or cancel on its own. Exit code 130.
- `--detach` prints the operation ID and exits 0 as soon as the operation has started. `apkrun operations wait <id>` picks it up again.

### 3.6 Environment

| Variable | Effect |
|---|---|
| `NO_COLOR` | no color |
| `APKRUN_HOME` | `dev` commands only: the data root for the embedded runtime ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md)). Ignored by other commands, because apkrund owns its paths |
| `APKRUN_LOG_LEVEL` | `dev` commands only: `debug` or `info` for the in-process runtime |

---

## 4. Command reference

**E**: available in embedded mode before #032. **Task**: the task that introduces the command. Details and semantics are in the linked design sections. This section defines the syntax, output, and edge cases the CLI owns.

### 4.1 Setup, status, and runtime

| Command | Task | Behavior |
|---|---|---|
| `apkrun version [--json]` | #001 | CLI version, build, and, when reachable, apkrund's version and the installed Android image version. `apkrun --version` prints only the CLI version |
| `apkrun setup [--image <path>] [--yes]` | #066 | first-run provisioning ([runtime-daemon.md](runtime-daemon.md) §9). If apkrund is not registered, it opens `APKRun.app --register-runtime` (only the app bundle can register its agent with SMAppService) and waits up to 5 minutes for the user's approval in System Settings, printing the instructions. Then it runs `setup` with the image source: `--image` takes a bundle directory or an `.aar`; without it, release builds use the image feed (#087) and development builds fail with a hint to pass `--image`. Progress shows the `ProvisioningState` steps. Resumes at the first incomplete step. Already complete: prints "Setup is complete." and exits 0 |
| `apkrun status [--json]` | #032 | the menu bar summary ([host-ui.md](host-ui.md) §12): runtime state, running apps, updates available, developer mode, microphone in use |
| `apkrun runtime status [--json]` | #032 | `RuntimeStatus`: state, boot phase, owner (`apkrund` or `apkrun-dev`), uptime, idle timers, boot-loop guard, image version, agent connections |
| `apkrun runtime start [--hold] [--timeout <s>]` | #032 | `ensureReady(.cli)`. Returns when the runtime is `ready`, printing the boot time. `--hold` keeps it ready (activity `.cli`, [runtime-daemon.md](runtime-daemon.md) §5.1) until the CLI exits or is interrupted |
| `apkrun runtime stop [--force] [--yes]` | #032 | graceful stop ([runtime-daemon.md](runtime-daemon.md) §3.5). Asks when sessions are open or an install runs ("Android is installing ‹App›. Stop anyway?"). `--force` skips the graceful phase |
| `apkrun runtime restart [--yes]` | #032 | stop, then start |
| `apkrun runtime reset [--yes]` | #032 | clears a `failed` state and the boot-loop guard ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §2). Deletes nothing |
| `apkrun runtime reset --erase [--no-backup] [--yes]` | #066 | **Reset Android** ([runtime-daemon.md](runtime-daemon.md) §9.5): deletes all Android data. Creates a 7-day recovery point unless `--no-backup`. Asks to type `Reset` |
| `apkrun info [--runtime] [--displays] [--json]` | #032, #028 | without a package: runtime overview (versions, state, memory and CPU, display pool size). `--runtime` adds resource use (guest memory, IOSurface memory, [graphics.md](graphics.md) §6.3). `--displays` prints the pool snapshot ([display-and-windowing.md](display-and-windowing.md) §10) |

### 4.2 Apps

| Command | Task | Behavior |
|---|---|---|
| `apkrun install <file>… [--yes] [--provider <spec>] [--updates automatic\|notify\|manual] [--wrap [--output <dir>]]` | #027 **E**, #073, #037 (`--provider`, `--updates`), #075 (`--wrap`) | imports the files as one package ([package-store.md](package-store.md) §4), prints the preview (name, package, version, signer digest, size, warnings, relation), asks, and installs. `--provider` sets authority `apkrun` with the mode `automatic`, or `notifyOnly` with `--updates notify`. `--updates manual` sets authority `manual` (`InstallOptions.authority`) and keeps a given provider unused. Without either flag, the defaults of [update-system.md](update-system.md) §2.4 apply. The alternate flag spellings (`--update auto\|notify\|manual`, `--update-provider direct --update-url <url>`) map to the current options ([update-system.md](update-system.md) §11.3). `--wrap` also creates the Mac app (as `apkrun wrap`). Refused relations (downgrade, other signer) exit 5 with the store's message. Already installed with the same version: exits 0 with "already installed" |
| `apkrun uninstall <package> [--keep-data] [--keep-wrapper] [--forget] [--yes]` | #027 **E**, #076 | [package-store.md](package-store.md) §8. The Mac app goes to the Trash unless `--keep-wrapper`. `--forget` removes the record without Android (when Android cannot start) |
| `apkrun list [--all] [--json]` | #027 **E** | managed packages: name, package, version, update choice, status, Mac app. `--all` adds unmanaged packages (`managed = false`) |
| `apkrun info <package> [--json]` | #027 **E** | name, package, version (`versionName (versionCode)`), update authority, update source, Mac app path and status, runtime status, installed/updated dates, signer digest, settings summary, and `compatibility` when the compatibility database has an entry for the installed version (#090, [diagnostics.md](diagnostics.md) §10.3) |
| `apkrun inspect <file>… [--json]` | #073, #090 | `inspectFile`: the host preview only ([package-store.md](package-store.md) §4.3, §11.1), with `compatibility` when the database has an entry (#090). Needs apkrund but never starts Android, and nothing is installed |
| `apkrun launch <package> [--json]` | #032 | `launch(packageID)` ([runtime-daemon.md](runtime-daemon.md) §7.2). Opens the Mac app (or the generic launcher) and returns when the session is `running`, printing the first-frame time |
| `apkrun stop <package>` | #032 | `terminate(packageID)`: closes the window and force-stops the app |
| `apkrun repair <package> [--yes]` | #076 | `repairPackage` for a `broken` package ([package-store.md](package-store.md) §11.1) |
| `apkrun rollback <package> [--allow-data-loss] [--yes]` | #043 | `rollbackPackage` ([update-system.md](update-system.md) §8.5) |
| `apkrun adopt <package>` | #073 | `adoptPackage` for an unmanaged package ([package-store.md](package-store.md) §9.3) |
| `apkrun settings <package> list [--json]` | #079 | every per-package key with its effective value and its source: `user`, `recommended` (compatibility database, #090), `default`, or `globalSwitch` ([../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §3, [../03-reference/configuration.md](../03-reference/configuration.md) §3.2) |
| `apkrun settings <package> get <key>` | #079 | one value |
| `apkrun settings <package> set <key> <value>` | #079 | `updatePackageSettings(id, patch)`. The value is parsed by the key's type (bool: `true`/`false`/`on`/`off`; enums by name; numbers). Invalid values exit 64 with the allowed values. Prints "applies the next time ‹App› opens" where that is true |
| `apkrun settings <package> reset (<key> \| --all)` | #079 | removes the stored value. The effective value falls back to the compatibility recommendation, else the default ([../03-reference/configuration.md](../03-reference/configuration.md) §3.2) |

### 4.3 Updates

The syntax is in [update-system.md](update-system.md) §11.3. CLI-owned details:

| Command | Task | Behavior |
|---|---|---|
| `apkrun update [--check-only] [--json]` | #037 (`--check-only`), #074 | checks every `apkrun` package. Prints one line per package: up to date, available, installed, waiting ("will update when ‹App› quits"), failed. Exit 2 if some failed |
| `apkrun update <package> [--now] [--file <apk>…]` | #038, #040 | checks and installs one package (user-initiated rules, [update-system.md](update-system.md) §7.3). The app is open: without `--now`, the command prints "will update when ‹App› quits" and returns, and the operation keeps waiting in apkrund until the app quits (`apkrun operations cancel` ends the wait). `--now` (`closeRunningApp`) asks nothing: it closes the app, installs, and reopens the app. `--file` is a manual update from files |
| `apkrun update policy <package> --mode automatic\|notify\|manual [--provider <spec> \| --no-provider]` | #037, #039 | `setUpdatePolicy` ([update-system.md](update-system.md) §2.3). #037 attaches and removes providers; #039 adds the full rules and refusals |
| `apkrun update authority <package> apkrun\|manual\|external` | #039 | `setUpdateAuthority` ([update-system.md](update-system.md) §2.1). `external` hands the updates to another installer inside Android and gives up APKRun's update ownership. `apkrun` needs a kept update source (`update.providerNotConfigured`) |
| `apkrun update skip <package> <versionCode>` | #043 | skips a version |
| `apkrun update unskip <package> <versionCode>` | #043 | `unskipVersion`: the version can be offered again ([update-system.md](update-system.md) §8.4) |
| `apkrun update history [<package>] [--limit <n>] [--json]` | #037 | from `Updates/history.jsonl` |

### 4.4 Mac apps (wrappers)

The syntax, the import/install table, and the alternate flag spellings are in [wrapper.md](wrapper.md) §12.2 (`apkrun wrap`, `apkrun wrapper list|info|refresh|remove|verify|approve`). CLI-owned details:

- `apkrun wrap` prints the bundle path on success. With `--json`, the `WrapperInfo` DTO.
- The CLI resolves `--output` and checks that it exists and is a directory. When apkrund reports `destinationNotAccessible`, the CLI places the staged wrapper itself ([wrapper.md](wrapper.md) §6.3), because the CLI runs with the user's own file access.
- `apkrun wrapper approve <path>` shows the same facts as the GUI prompt ([host-ui.md](host-ui.md) §10.1) and asks. `--yes` approves without asking.

### 4.5 Integrations

| Command | Task | Behavior |
|---|---|---|
| `apkrun integrations status <package> [--json]` | #053 | `integrationStatus`: per integration the setting, the effective decision, support on the image, and the macOS permission ([desktop-integration.md](desktop-integration.md) §11) |
| `apkrun shared-folders list [--json]` | #082 | shared roots with their access and availability |
| `apkrun shared-folders add <path> [--read-write]` | #082 | the CLI creates the security-scoped bookmark from the path it opened, then calls `addSharedFolder` |
| `apkrun shared-folders remove <path\|id>` | #082 | `removeSharedFolder` |

Per-package integration settings use `apkrun settings <package> set integrations.<key> <value>`.

### 4.6 App-wide configuration

| Command | Task | Behavior |
|---|---|---|
| `apkrun config list [--json]` | #032 | every global key ([../03-reference/configuration.md](../03-reference/configuration.md)) with its value and default |
| `apkrun config get <key>` | #032 | one value |
| `apkrun config set <key> <value>` | #032 | validated like `settings set`. Keys that apply at the next Android start say so (`runtime.memoryGiB`, `runtime.cpuCount`, `audio.output`, `graphics.safeMode`, `developer.enabled`). `runtime.userdataGiB` says "Applies after Reset Android." |
| `apkrun config reset (<key> \| --all)` | #032 | back to the default |

### 4.7 Android image and APKRun updates

Owned by [runtime-maintenance.md](runtime-maintenance.md).

| Command | Task | Behavior |
|---|---|---|
| `apkrun image list [--json]` | #058 | installed images (`current`, `previous`), their versions, state, and recovery points |
| `apkrun image check [--json]` | #087 | checks the image feed now (user-initiated: ignores the interval and the rollout) and prints the update phase, the candidate, and any "needs a newer APKRun" note ([runtime-maintenance.md](runtime-maintenance.md) §4.2). Exit 0 |
| `apkrun image install (<file.aar> \| --latest) [--yes]` | #058, #087 | installs a signed image archive, or downloads and installs the feed's candidate, then applies it: the migration of [android-image.md](android-image.md) §12.3. Only the missing steps run. Asks when apps are open, and before retrying a rejected version; `--yes` answers both. Ctrl-C during the download keeps the partial file ([runtime-maintenance.md](runtime-maintenance.md) §4.4–§4.8). Unpacked bundle directories are `apkrun dev image install` |
| `apkrun image rollback [--yes]` | #058 | "Go back to the previous Android version" from the recovery point. Warns that data written since the migration is lost |
| `apkrun image recovery-points list \| delete <id>` | #058 | recovery points ([android-image.md](android-image.md) §12.2) |
| `apkrun self-update check [--json]` | #057 | apkrund checks the APKRun appcast (user-initiated) and prints "APKRun 1.3.0 is available (you have 1.2.0). Open APKRun to install it." or "APKRun is up to date." Exit 0 in both cases; `--json` has `available`. Exit 69 when apkrund can't be reached ([runtime-maintenance.md](runtime-maintenance.md) §3.4) |
| `apkrun self-update install` | #057 | opens `apkrun://settings/general`, where Sparkle installs the update. The CLI doesn't wait. Installing is done in APKRun.app, because Sparkle replaces the app bundle |
| `apkrun self-update finish [--yes]` | #057 | when APKRun was replaced while Android apps were open (`restartPending`): restarts Android on the new build. Asks when apps are open. Prints "Nothing to finish." otherwise ([runtime-maintenance.md](runtime-maintenance.md) §3.6) |

### 4.8 Diagnostics

Owned by [diagnostics.md](diagnostics.md).

| Command | Task | Behavior |
|---|---|---|
| `apkrun doctor [--deep] [--fix] [--json]` | #059 | runs the health checks and prints them grouped by subsystem in the format, each with ✓ / ℹ / ⚠ / ✕ / – (not checked) and a remediation. `--deep` adds slow checks (image hashes, wrapper signatures). `--fix` runs the safe automatic fixes the checks declare (for example re-registering a wrapper with LaunchServices). Exit 0 healthy or stopped, 3 warnings only, 1 failures ([diagnostics.md](diagnostics.md) §7.2). Without apkrund, the CLI runs the host checks of DiagnosticsCore itself ([diagnostics.md](diagnostics.md) §7) and reports every other check as "background service not running" with its remediation |
| `apkrun diagnostics [--output <path>] [--include-logcat] [--package <id>] [--deep] [--json]` | #060 | creates the diagnostics ZIP ([diagnostics.md](diagnostics.md) §8). `--include-logcat` keeps all Android app log lines (still redacted). `--package` adds that app's update history and launch records. `--deep` uses the deep health checks. Default output: `~/Desktop/APKRun-Diagnostics-<timestamp>.zip`. Prints the path and the summary. Works after a boot failure. Without apkrund, the CLI builds a host-only bundle with DiagnosticsCore's writer and redaction ([diagnostics.md](diagnostics.md) §8.4) |
| `apkrun logs [--follow] [--since <duration>] [--subsystem <name>] [--level info\|debug] [--json]` | #061 | host logs: defaults to the last hour; `--since` accepts durations through 30 days. Runs `/usr/bin/log show` or `log stream` with the predicate `subsystem BEGINSWITH "io.apkrun"` and formats the entries. `--follow` waits for the stream subscription notice or first output before reading history, buffers live entries during that query with 4,096-entry and 4 MiB limits, and uses `--since` only for the initial history. NDJSON records larger than 1 MiB are discarded through the next newline. After a stream exit, it retries and runs a catch-up query from one second before the last covered instant after the replacement stream is ready. The checkpoint advances only through time covered jointly by a complete history query and the stream. Occurrence-aware duplicate removal preserves identical independent records. `--json` emits single-line NDJSON and escapes Unicode formatting scalars. If unified logging fails or returns no matching entries, it reads the public file mirrors in `~/Library/Logs/APKRun/`; if neither source is readable, it exits with `cli.logsUnavailable`. If a stream cannot become ready after three attempts, it runs a one-shot history query with mirror fallback and exits ([diagnostics.md](diagnostics.md) §3) |
| `apkrun logs --guest [--follow]` | #032 | guest logcat from the logcat console port through apkrund ([android-image.md](android-image.md) §7.1). Needs developer mode |

### 4.9 Operations

| Command | Task | Behavior |
|---|---|---|
| `apkrun operations list [--json]` | #032 | running and recent (last 50) long-running operations with ID, kind, package, progress, and result |
| `apkrun operations wait <id>` | #032 | waits and exits with the operation's result code |
| `apkrun operations cancel <id>` | #032 | `cancel(operationID)` |

---

## 5. Development commands (`apkrun dev`)

Available in development builds only (`APKRUN_EMBEDDED_RUNTIME`). They run the runtime inside the CLI process ([runtime-daemon.md](runtime-daemon.md) §10) and refuse to use the user's instance while apkrund holds the lock (exit 75). They use `APKRUN_HOME` (default `~/Library/Application Support/APKRun-Dev/`).

| Command | Task | Behavior |
|---|---|---|
| `apkrun dev linux [--kernel <path>] [--initrd <path>] [--tests <list>] [--flood-lines <n>] [--window] [--stats] [--timeout <s>]` | #003–#007, #019, #022, #023 (`--window`, `--stats`) | boots the test Linux guest ([vm.md](vm.md) §12). `--tests blk,net,vsock,ports,rng,gpu,virgl` sets `apkrun.test=`. With `--tests flood`, `--flood-lines` sets `apkrun.test.flood=<n>` (1–10,000,000; default 10,000,000); using the option without `flood` is an error. Prints the `APKRUN-TEST:` lines and exits 0 only if every requested check printed `ok`. `--window` shows scanout 0 in a development window. `--stats` adds an overlay with the fps and the readback counters ([graphics.md](graphics.md) §7) |
| `apkrun dev image install <dir>` | #065 | verifies a signed runtime image bundle directory, installs it under `Images/<version>/`, and makes it current. Provisions the instance when there is none. Holds the instance lock. An `.aar` arrives with #058 ([android-image.md](android-image.md) §10.3, [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.3) |
| `apkrun dev boot [--gpu none\|swiftshader\|virgl] [--window] [--stats] [--no-animations] [--guest-transport vsock\|adb] [--wait-ready]` | #012–#014, #021, #022, #023 | boots Android. It boots `current`, which `apkrun dev image install` sets (#065). `--bundle` existed from #012 until #065, which removed it. `--gpu` selects the GPU profile ([graphics.md](graphics.md) §9): `none` is the development-only `headless` profile (#012), `swiftshader` is `guestSwiftshader` (#021), and `virgl` is `drmVirgl` (#022). `none` stays the default until the drmVirgl boot is verified on the VM (IR-584). `--window` shows display 0 (#023). `--stats` adds the overlay of `dev linux --stats`. Streams boot phases. Stays in the foreground until Ctrl-C, which stops Android gracefully. While it runs, it serves hvc0, and hvc1 in developer mode, on the Unix sockets `$APKRUN_HOME/Runtime/dev-console/<port>.sock` (mode 0600, removed at stop; #014). It always boots in developer mode, provisions the instance when there is none, writes the logcat port to `<logs>/guest/logcat-<timestamp>.log`, and prints state changes on standard error. Added in #012: `--reset` provisions a fresh instance first, `--stop-when-ready` stops Android once it is ready, `--console` copies hvc0 to standard output, and `--cpus`, `--memory-gib`, and `--userdata-gib` size a new instance |
| `apkrun dev console [--kernel <path>] [--initrd <path>]` | #004, #014 | In M0 (#004), boots the Linux test guest and connects an interactive raw terminal to hvc0. The terminal output writer uses nonblocking writes and checks cancellation while waiting for space; it restores the original descriptor flags before leaving raw mode and includes unwritten bytes in the output-loss warning. Ctrl-] requests guest shutdown; after 20 seconds it force-stops the VM. It prints `runtime.devConsoleOutputDropped` with at least the known bytes lost through stream buffering or terminal writes; the count is a lower bound when cleanup stops after the bounded drain. If both stop and reset fail, it stops terminal output and restores the terminal immediately, reports `runtime.devConsoleCleanupPending`, and retains the instance lock while waiting for VM release. From #014, the command attaches to the running Android `apkrun dev boot` through its console socket; `--android-shell` selects hvc1 in developer mode ([android-image.md](android-image.md) §7.1), and it exits 69 when no `apkrun dev boot` process owns the instance |
| `apkrun dev launch [--display 0\|secondary] <apk\|package>…` | #072, #024, #026, #029, #030 | boots Android if needed, installs each APK through `AdbClient`, and launches each app through the Guest Agent (`LaunchApplication`). With #072 it only prints the launch result. From #024 it opens the development window of #023 with input, and from #026 each app gets its own window. `--display secondary` (#029) uses a pool display, and several apps (#030) run side by side ([display-and-windowing.md](display-and-windowing.md) §12) |
| `apkrun dev displays add [--size <w>x<h>] [--dpi <n>] \| remove <id> \| list` | #028 | exercises the display pool without apps |
| `apkrun dev power sleep \| wake` | #069 | injects host sleep and wake messages ([runtime-daemon.md](runtime-daemon.md) §6) of the running `apkrun dev boot`. Like `dev console`, it does not run a runtime and does not take the instance lock: it writes the request to the control socket `$APKRUN_HOME/Runtime/dev-console/control.sock` of the process that owns the instance, which calls `DeveloperService.injectPower` ([../03-reference/runtime-api.md](../03-reference/runtime-api.md)). Fails with exit 69 when no `apkrun dev boot` process owns the instance |
| `apkrun dev adb [<args>…]` | #015 | runs the developer's `adb` as `adb -s 127.0.0.1:6520 <args>` against the dev instance, with the terminal attached. It finds `adb` in `$ANDROID_HOME/platform-tools` and then on `PATH`, connects the endpoint once (up to 2 s) so that adb knows the device, and passes adb's exit status through. It does not take the instance lock, and it does not start Android. With no `adb`, it fails with `runtime.adbExecutableMissing` (exit 69, [environment-setup.md](../05-development/environment-setup.md) §2.5). APKRun does not ship `adb` |

In Debug builds, `apkrun dev linux` honors `APKRUN_TEST_LINUX_DIR`; it must be
an absolute path so the artifact scripts, CLI, and hosted T2 tests select the
same directory even when they run from different working directories. Release
builds ignore this test-only override and use `/tmp/apkrun-test-linux` unless
the kernel and initramfs paths are supplied directly.

---

## 6. Implementation

### 6.1 Source layout

```text
CLI/apkrun/
├── main.swift                 root command, version, global options
├── Support/                   Output (table, key/value, JSON envelope), Prompt, Progress, ExitCodes, OperationWaiter
├── Commands/                  one file per command group: Setup, Status, Runtime, Info, Install, Uninstall, List,
│                              Inspect, Launch, Settings, Update, Wrap, Wrapper, Integrations, SharedFolders,
│                              Config, Image, SelfUpdate, Doctor, Diagnostics, Logs, Operations
└── Dev/                       `apkrun dev …` (compiled only with APKRUN_EMBEDDED_RUNTIME)
```

- Commands are `AsyncParsableCommand`s. They get a `RuntimeService` from a factory, so T0 tests run them against a fake `RuntimeService` and compare stdout, stderr, and the exit code with golden files.
- All user-facing strings are catalog keys ([host-ui.md](host-ui.md) §13). JSON keys are never localized.

### 6.2 Implementation steps

| Task | Steps | Acceptance |
|---|---|---|
| #001 | root command, `version`, `--help`, the output and exit-code support | the CLI prints version and help |
| #003–#007, #014, #019–#023, #026–#030 | the `dev` commands of §5 as each task needs them | the task's T2 test runs through the command |
| #027 | `install`, `uninstall`, `list`, `info` over `EmbeddedRuntimeService`, prompts, `--yes`, `--json` | [package-store.md](package-store.md) §15 #027 |
| #032 | switch to `XPCRuntimeService`, `status`, `runtime …`, `launch`, `stop`, `config …`, `operations …`, the unavailable handling (exit 69) | [runtime-daemon.md](runtime-daemon.md) §13 #032 |
| #066 | `setup`, `runtime reset --erase` | [runtime-daemon.md](runtime-daemon.md) §9.4 |
| #073 | `inspect`, `adopt`, the relation output of `install` | [package-store.md](package-store.md) §15 #073 |
| #037–#040, #043, #074 | `update …`, `rollback`, the update flags of `install` | [update-system.md](update-system.md) §15 |
| #044 | `wrapper approve` | [wrapper.md](wrapper.md) §7.3, §15 #044 |
| #075 | `wrap`, `install --wrap`, `wrapper verify`, `wrapper info` | [wrapper.md](wrapper.md) §15 #075 |
| #076 | `wrapper list`, `wrapper refresh`, `wrapper remove` | [wrapper.md](wrapper.md) §15 #076 |
| #088 | `wrap <package> --distribution` | [wrapper.md](wrapper.md) §11, [../04-plan/issues/M12-v1-release.md](../04-plan/issues/M12-v1-release.md) #088 |
| #090 | the `compatibility` field of `info` and `inspect`, the `recommended` source in `settings list` | [diagnostics.md](diagnostics.md) §10.3 |
| #079 | `settings …` | every key of package-metadata-json §3 round-trips through `set` and `get` |
| #053, #082 | `integrations status`, `shared-folders …` | [desktop-integration.md](desktop-integration.md) §14 |
| #057, #058, #087 | `self-update check\|install\|finish`, `image …` | [runtime-maintenance.md](runtime-maintenance.md) |
| #059, #060, #061 | `doctor`, `diagnostics`, `logs` | [diagnostics.md](diagnostics.md) |
| #092 | Japanese strings | every human message of the golden tests exists in Japanese |

### 6.3 Tests

| Tier | Test | Task |
|---|---|---|
| T0 | golden output (human and JSON) per command against a fake `RuntimeService`, including every error path. Argument validation (package names, specs, sizes) | each task of §6.2, for its commands |
| T0 | exit-code table vs error catalog: every entry's `cliExit`, with `"cause"` resolved through the chain | #061 |
| T0 | non-interactive rules: no TTY and no `--yes` → `cli.confirmationRequired` | #027 (the first prompts) |
| T1 | Ctrl-C during `install` cancels the operation (fake service records `cancel`) | #032 (`OperationHandle.cancel`) |
| T2 | the acceptance commands of each task against real apkrund | each task of §6.2 |

---

## 7. Open items

| Item | Plan |
|---|---|
| How `log show` behaves for a standard (non-admin) user on macOS 27 (§4.8, OQ-04) | #061 checks it. Working default: the file mirrors cover the gap either way. If `log show` fails, `apkrun logs` reads the file mirrors in `~/Library/Logs/APKRun/` ([diagnostics.md](diagnostics.md) §3.3) |
| Where the image feed and the APKRun appcast are hosted (§4.1, §4.7, OQ-01) | decided before #057 and #087. Until then the host is the `<updates host>` placeholder. `apkrun setup` without `--image` in release builds, `image check`, `image install --latest`, and `self-update check` depend on it |

---

## 8. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| The **E** commands keep their syntax and output after the switch to RuntimeClient | #032 | pending (§2) |
| `log show` with the `io.apkrun` predicate on macOS 27 (OQ-04) | #061 | 2026-09-29, macOS 27.0 (26A428): an unprivileged command from an `admin`-group account returned one `io.apkrun.cli` entry. A non-admin account was unavailable, so OQ-04 remains open (§4.8) |
| `apkrun setup` without `--image` in a release build provisions from the image feed | #087 | pending (§4.1) |
