# Command-Line Tool (`apkrun`)

`apkrun` is the scripting and development interface to APKRun. Like APKRun.app, it is a client of apkrund ([runtime-daemon.md](runtime-daemon.md) §8.5). Everything it does, except the `dev` commands, the GUI can do too. This document is the complete command set. Subsystem documents list only the commands they own, as summaries of this page.

---

## 1. Principles

1. **One code path.** Every non-`dev` command calls a `RuntimeService` operation through `RuntimeClient`. The CLI never touches `~/Library/Application Support/APKRun/`, never runs `adb`, and never talks to the VM ([modules.md](../01-architecture/modules.md) §2).
2. **Same words as the GUI.** Error messages and remediations come from the error catalog. Translations come from the String Catalog ([host-ui.md](host-ui.md) §13).
3. **Scriptable.** Stable exit codes (§3.3), `--json` for every command that prints data (§3.2), and no prompts without a terminal (§3.4).
4. **Safe by default.** Destructive commands ask for confirmation unless `--yes` is given ([security-model.md](../01-architecture/security-model.md) §3.1).

---

## 2. Build, installation, and authorization

- Source: `CLI/apkrun`, built with swift-argument-parser ([modules.md](../01-architecture/modules.md) §1). Dependencies: `RuntimeClient`, `RuntimeAPI`, `DiagnosticsCore`. Development builds with the flag `APKRUN_EMBEDDED_RUNTIME` also link `RuntimeHost`, `WindowingCore`, and `InputCore`, for the `dev` commands ([runtime-daemon.md](runtime-daemon.md) §10).
- Installed at `APKRun.app/Contents/Resources/bin/apkrun` ([filesystem-layout.md](../01-architecture/filesystem-layout.md) §4). APKRun's identity signs the binary, so apkrund's control endpoint accepts it ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).
- Settings → Advanced → **Install Command-Line Tool…** ([host-ui.md](host-ui.md) §9.9) shows this command, with a **Copy** button:

  ```sh
  sudo ln -sf "/Applications/APKRun.app/Contents/Resources/bin/apkrun" /usr/local/bin/apkrun
  ```

  A symlink keeps the signature valid, because the kernel checks the real file. A copied binary works until APKRun updates. After an update, `apkrun` detects that its version differs from apkrund's and prints a hint to use the symlink.
- Development builds install as `apkrun-dev` from `scripts/dev/install-dev-app.sh` and talk to `io.apkrun.apkrund.dev.xpc` ([runtime-daemon.md](runtime-daemon.md) §2.6).

---

## 3. Conventions

### 3.1 Syntax

- `apkrun <command> [<subcommand>] [arguments] [options]`. Long options only, except `-y` (`--yes`), `-h` (`--help`), and `-v` (`--verbose`).
- `<package>` is an Android package name (`com.example.app`). It is validated against the package-name grammar before any request is sent.
- `<spec>` (update source) is `local:<path>`, `direct:<https-url>`, `fdroid[:<repository-url>#<fingerprint>]`, or `github:<owner>/<name>[:<asset-glob>][@prerelease]` ([update-system.md](update-system.md) §11.3).
- The CLI opens file arguments and passes them as file handles. apkrund never opens a path given on the command line ([package-store.md](package-store.md) §4.1). Relative paths resolve against the current directory.
- `apkrun --generate-completion-script zsh|bash|fish` generates completion. Package arguments complete from `apkrun list --json`.

### 3.2 Output

| Stream | Content |
|---|---|
| stdout | The result: tables, key/value blocks, or JSON |
| stderr | Progress, warnings, errors, and prompts |

- Human output adapts to the terminal width. Color is used only when stdout is a TTY and `NO_COLOR` is unset. `--no-color` turns color off.
- `--json` prints one JSON document on stdout and nothing else there:

  ```json
  { "schemaVersion": 1, "result": { … } }
  { "schemaVersion": 1, "error": { "code": "store.downgradeRefused", "message": "…", "remediation": "…", "operationID": "…" } }
  ```

  `result` is the RuntimeAPI DTO of the operation, encoded by [runtime-api.md](../03-reference/runtime-api.md) §4.2–§4.3: camelCase keys, ISO 8601 dates, `versionCode` as a number, and digests as `sha256:` plus lowercase hex. Minor versions may add fields. Removing or renaming a field increments `schemaVersion`.
- `--quiet` prints only the essential result: the package ID for `install`, the bundle path for `wrap`.
- `--verbose` adds the operation ID and timings to human output.

### 3.3 Exit codes

| Code | Name | When |
|---|---|---|
| 0 | success | |
| 1 | failure | The operation failed with a typed error. The code is in the message and in JSON |
| 2 | partial | The main step succeeded and a follow-up failed: installed but the Mac app could not be created, or some packages of `update` failed |
| 3 | warnings | `doctor` found warnings but no failures |
| 4 | not found | Unknown package, wrapper, operation (`runtime.operationNotFound`), or setting key |
| 5 | refused | Refused by policy: downgrade, other signer, not authorized, or a dialog the user declined |
| 64 | usage | Invalid arguments (`EX_USAGE`) |
| 69 | unavailable | apkrund is not set up ([runtime-daemon.md](runtime-daemon.md) §8.5) or not reachable (`EX_UNAVAILABLE`) |
| 70 | internal | `RuntimeFailure.internal`, or a malformed reply (`EX_SOFTWARE`) |
| 75 | try again | `RuntimeFailure.busy`, or the instance lock is held by another owner (`EX_TEMPFAIL`) |
| 130 | interrupted | Ctrl-C cancelled the operation (§3.5) |

The mapping is generated, not hand-written. `CLI/apkrun/Support/ExitCodes.swift` reads each entry's `cliExit` from `ErrorCatalog.generated.swift` ([error-catalog.md](../03-reference/error-catalog.md) §19.1). Each catalog code maps to exactly one exit code. A transparent container entry maps to `"cause"`, which is the exit code of its cause ([error-catalog.md](../03-reference/error-catalog.md) §3.5).

Errors that the CLI raises itself belong to the `cli` domain ([error-catalog.md](../03-reference/error-catalog.md) §16):

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

swift-argument-parser usage failures (unknown commands, missing arguments, unknown options) are caught by the root command and rendered through `cli.invalidArguments` with exit 64. The parser's raw diagnostic is neither logged nor included in the error.

### 3.4 Confirmations and non-interactive use

- Commands that change or delete data show what will happen and ask `Continue? [y/N]` on the terminal.
- `--yes` answers yes. Without a TTY on stdin and without `--yes`, the command fails with `cli.confirmationRequired` (exit 1) and names the flag. A command never waits for input that cannot come.
- Reset Android requires typing `Reset`, as the GUI does ([runtime-daemon.md](runtime-daemon.md) §9.5). `--yes` replaces the typing.

### 3.5 Long-running operations

For operations that return an `OperationHandle` ([runtime-daemon.md](runtime-daemon.md) §8.3):

- The CLI subscribes to the `operations` topic, shows a progress line on stderr (TTY only), and waits for the result.
- **Ctrl-C** sends `cancel(operationID)` and waits up to 10 s for the cancellation result. A second Ctrl-C exits at once and leaves the operation to finish or cancel on its own. Exit code 130.
- `--detach` prints the operation ID and exits 0 as soon as the operation has started. `apkrun operations wait <id>` resumes waiting. `install` and `operations wait` accept `--detach`.

### 3.6 Environment

| Variable | Effect |
|---|---|
| `NO_COLOR` | No color |
| `APKRUN_HOME` | `dev` commands only: the data root for the embedded runtime ([filesystem-layout.md](../01-architecture/filesystem-layout.md)). Other commands ignore it, because apkrund owns its paths |
| `APKRUN_LOG_LEVEL` | `dev` commands only: `debug` or `info` for the in-process runtime |

---

## 4. Command reference

**Task** is the task that introduces the command. Details are in the linked design sections. This section defines the syntax, output, and edge cases that the CLI owns.

### 4.1 Setup, status, and runtime

| Command | Task | Behavior |
|---|---|---|
| `apkrun version [--json]` | #001 | CLI version and build. When apkrund is reachable, also its version and the installed Android image version. `apkrun --version` prints only the CLI version |
| `apkrun setup [--image <path>] [--yes]` | #066 | First-run provisioning ([runtime-daemon.md](runtime-daemon.md) §9). If apkrund is not registered, opens `APKRun.app --register-runtime` (only the app bundle can register its agent) and waits up to 5 minutes for approval in System Settings, printing the instructions. Then runs `setup` with the image source. `--image` takes a bundle directory or an `.aar`. Without it, release builds use the image feed (#087) and development builds fail with a hint to pass `--image`. Shows the `ProvisioningState` steps and resumes at the first incomplete step. When already complete, prints "Setup is complete." and exits 0 |
| `apkrun status [--json]` | #032 | The menu bar summary ([host-ui.md](host-ui.md) §12): runtime state, running apps, available updates, developer mode, and microphone in use |
| `apkrun runtime status [--json]` | #031, #032 | Daemon and runtime state, boot progress, startup failure, boot-loop guard, daemon PID, and image version. Also the owner, uptime, idle timers, and agent connections |
| `apkrun runtime start [--hold] [--timeout <s>]` | #031, #032 | Starts Android and returns when it is ready. Prints boot progress on stderr. `--hold` keeps the runtime ready until the CLI exits or is interrupted ([runtime-daemon.md](runtime-daemon.md) §5.1). `--timeout` limits the wait |
| `apkrun runtime stop [--force] [--yes]` | #031, #032 | Gracefully stops Android and leaves apkrund running. Asks for confirmation when sessions or installs are active. `--force` skips the busy check ([runtime-daemon.md](runtime-daemon.md) §3.5) |
| `apkrun runtime restart [--yes]` | #032 | Sends one authenticated `restartRuntime` request. apkrund stops and starts Android under one lifecycle reservation. Asks before restarting unless `--yes` is given. Until `runtimeStatus` reports active sessions, the prompt appears on every restart. The reply is the final runtime status. A client timeout or cancellation can end the wait without stopping the restart, so check `apkrun runtime status` before retrying |
| `apkrun runtime reset` | #032 | Clears the automatic boot-loop guard. Does not start or stop Android, and does not delete Android data. Reports the current runtime state |
| `apkrun runtime reset --erase [--no-backup] [--yes]` | #066 | **Reset Android** ([runtime-daemon.md](runtime-daemon.md) §9.5): deletes all Android data. Creates a 7-day recovery point unless `--no-backup`. Requires typing `Reset` (§3.4) |
| `apkrun info [--runtime] [--displays] [--json]` | #032, #028 | Without a package: CLI version and build, daemon and Android state, and image version. `--runtime` adds the fields of `RuntimeHostStatus`. `--displays` shows display snapshots (#028). Until the daemon exposes them, it fails with an unavailable error that gives the remediation |

### 4.2 Apps

| Command | Task | Behavior |
|---|---|---|
| `apkrun install <file>… [--yes] [--provider <spec>] [--updates automatic\|notify\|manual] [--wrap [--output <dir>]] [--detach]` | #027, #073, #037, #075, #032 | Imports the files as one package ([package-store.md](package-store.md) §4). Prints the preview (name, package, version, signer digest, size, warnings, relation), asks, and installs. `--provider` sets authority `apkrun` with mode `automatic`, or `notifyOnly` with `--updates notify`. `--updates manual` sets authority `manual` (`InstallOptions.authority`) and leaves a given provider unused. Without either flag, the defaults of [update-system.md](update-system.md) §2.4 apply. The alternate spellings `--update auto\|notify\|manual` and `--update-provider direct --update-url <url>` map to the same options ([update-system.md](update-system.md) §11.3). `--wrap` also creates the Mac app, as `apkrun wrap` does. `--detach` prints the install operation ID once the daemon accepts the install; `apkrun operations wait <id>` shows the result. Refused relations (downgrade, other signer) exit 5 with the store's message. A preview of the same APK set as the stored artifacts still asks and then reinstalls, because PackageManager does not report installed APK byte digests |
| `apkrun uninstall <package> [--keep-data] [--keep-wrapper] [--forget] [--yes]` | #027, #076 | [package-store.md](package-store.md) §8. The Mac app goes to the Trash unless `--keep-wrapper`. `--forget` removes the record without Android, for when Android cannot start |
| `apkrun list [--all] [--json]` | #027, #032 | Queries apkrund over XPC. Lists managed records by default. `--all` also lists packages from the daemon's current or cached Android inventory, without starting Android |
| `apkrun info <package> [--json]` | #027, #032 | Queries apkrund over XPC for the package summary: version, state, managed flag, update authority, stored APK count and bytes, and known Android data size. Wrapper paths, signer details, settings, update source, and compatibility come from #027 and #090 |
| `apkrun inspect <file>… [--json]` | #073, #090 | `inspectFile`: host preview only ([package-store.md](package-store.md) §4.3, §11.1), with `compatibility` when the database has an entry (#090). Needs apkrund but never starts Android. Installs nothing |
| `apkrun launch <package> [--json]` | #032 | `launch(packageID)` ([runtime-daemon.md](runtime-daemon.md) §7.2). Opens the Mac app or the generic launcher, and returns when the session is `running` or has failed. Prints the result and the first-frame time |
| `apkrun stop <package>` | #032 | `terminate(packageID)`: closes the window and stops the app |
| `apkrun repair <package> [--yes]` | #076 | `repairPackage` for a `broken` package ([package-store.md](package-store.md) §11.1) |
| `apkrun rollback <package> [--allow-data-loss] [--yes]` | #043 | `rollbackPackage` ([update-system.md](update-system.md) §8.5) |
| `apkrun adopt <package>` | #073 | `adoptPackage` for an unmanaged package ([package-store.md](package-store.md) §9.3) |
| `apkrun settings <package> list [--json]` | #079 | Every per-package key with its effective value and its source: `user`, `recommended` (compatibility database, #090), `default`, or `globalSwitch` ([package-metadata-json.md](../03-reference/package-metadata-json.md) §3, [configuration.md](../03-reference/configuration.md) §3.2) |
| `apkrun settings <package> get <key>` | #079 | One value |
| `apkrun settings <package> set <key> <value>` | #079 | `updatePackageSettings(id, patch)`. The value is parsed by the key's type: bool (`true`, `false`, `on`, `off`), enums by name, numbers. Invalid values exit 64 and list the allowed values. Prints "applies the next time ‹App› opens" where that is true |
| `apkrun settings <package> reset (<key> \| --all)` | #079 | Removes the stored value. The effective value falls back to the compatibility recommendation, else the default ([configuration.md](../03-reference/configuration.md) §3.2) |

The daemon-backed `install` path opens up to 20 regular files and passes their handles over control XPC. It prints each file's size and SHA-256 with the signing status, then confirms before `installImported`. Preview and import leave Android stopped; install starts it on demand. A dropped connection during `install` can leave the outcome unknown, so query the package state before retrying.

### 4.3 Updates

The syntax is in [update-system.md](update-system.md) §11.3. CLI-owned details:

| Command | Task | Behavior |
|---|---|---|
| `apkrun update [--check-only] [--json]` | #037, #074 | Checks every `apkrun` package. Prints one line per package: up to date, available, installed, waiting ("will update when ‹App› quits"), or failed. Exit 2 if some failed |
| `apkrun update <package> [--now] [--file <apk>…]` | #038, #040 | Checks and installs one package ([update-system.md](update-system.md) §7.3). If the app is open and `--now` is absent, prints "will update when ‹App› quits" and returns; the operation keeps waiting in apkrund until the app quits. `apkrun operations cancel` ends the wait. `--now` (`closeRunningApp`) asks nothing: it closes the app, installs, and reopens it. `--file` makes a manual update from files |
| `apkrun update policy <package> --mode automatic\|notify\|manual [--provider <spec> \| --no-provider]` | #037, #039 | `setUpdatePolicy` ([update-system.md](update-system.md) §2.3). Attaches and removes providers, and applies the full rules and refusals |
| `apkrun update authority <package> apkrun\|manual\|external` | #039 | `setUpdateAuthority` ([update-system.md](update-system.md) §2.1). `external` hands updates to another installer inside Android and gives up APKRun's update ownership. `apkrun` needs a kept update source (`update.providerNotConfigured`) |
| `apkrun update skip <package> <versionCode>` | #043 | Skips a version |
| `apkrun update unskip <package> <versionCode>` | #043 | `unskipVersion`: the version can be offered again ([update-system.md](update-system.md) §8.4) |
| `apkrun update history [<package>] [--limit <n>] [--json]` | #037 | Reads `Updates/history.jsonl` |

### 4.4 Mac apps (wrappers)

The syntax, the import and install table, and the alternate flag spellings are in [wrapper.md](wrapper.md) §12.2 (`apkrun wrap`, `apkrun wrapper list|info|refresh|remove|verify|approve`).

- `apkrun wrap` prints the bundle path on success. With `--json`, it prints the `WrapperInfo` DTO.
- The CLI resolves `--output` and checks that it exists and is a directory. When apkrund reports `destinationNotAccessible`, the CLI places the staged wrapper itself ([wrapper.md](wrapper.md) §6.3), because the CLI runs with the user's own file access.
- `apkrun wrap <package> --distribution` (#088) builds a distribution wrapper ([wrapper.md](wrapper.md) §11).
- `apkrun wrapper approve <path>` shows the same facts as the GUI prompt ([host-ui.md](host-ui.md) §10.1) and asks. `--yes` approves without asking.

### 4.5 Integrations

| Command | Task | Behavior |
|---|---|---|
| `apkrun integrations status <package> [--json]` | #053 | `integrationStatus`: per integration, the setting, the effective decision, support on the image, and the macOS permission ([desktop-integration.md](desktop-integration.md) §11) |
| `apkrun shared-folders list [--json]` | #082 | Shared roots with their access and availability |
| `apkrun shared-folders add <path> [--read-write]` | #082 | The CLI creates the security-scoped bookmark from the path it opened, then calls `addSharedFolder` |
| `apkrun shared-folders remove <path\|id>` | #082 | `removeSharedFolder` |

Per-package integration settings use `apkrun settings <package> set integrations.<key> <value>`.

### 4.6 App-wide configuration

| Command | Task | Behavior |
|---|---|---|
| `apkrun config list [--json]` | #032 | Every global key ([configuration.md](../03-reference/configuration.md)) with its value and default |
| `apkrun config get <key>` | #032 | One value |
| `apkrun config set <key> <value>` | #032 | Validated like `settings set`. Keys that apply at the next Android start say so: `runtime.memoryGiB`, `runtime.cpuCount`, `audio.output`, `graphics.safeMode`, `developer.enabled`. `runtime.userdataGiB` says "Applies after Reset Android." |
| `apkrun config reset (<key> \| --all)` | #032 | Back to the default |

### 4.7 Android image and APKRun updates

Owned by [runtime-maintenance.md](runtime-maintenance.md).

| Command | Task | Behavior |
|---|---|---|
| `apkrun image list [--json]` | #058 | Installed images (`current`, `previous`), their versions and state, and recovery points |
| `apkrun image check [--json]` | #087 | Checks the image feed now. User-initiated: it ignores the interval and the rollout. Prints the update phase, the candidate, and any "needs a newer APKRun" note ([runtime-maintenance.md](runtime-maintenance.md) §4.2). Exit 0 |
| `apkrun image install (<file.aar> \| --latest) [--yes]` | #058, #087 | Installs a signed image archive, or downloads and installs the feed's candidate, then applies it: the migration of [android-image.md](android-image.md) §12.3. Only the missing steps run. Asks when apps are open and before retrying a rejected version; `--yes` answers both. Ctrl-C during the download keeps the partial file ([runtime-maintenance.md](runtime-maintenance.md) §4.4–§4.8). Unpacked bundle directories use `apkrun dev image install` |
| `apkrun image rollback [--yes]` | #058 | "Go back to the previous Android version" from the recovery point. Warns that data written since the migration is lost |
| `apkrun image recovery-points list \| delete <id>` | #058 | Recovery points ([android-image.md](android-image.md) §12.2) |
| `apkrun self-update check [--json]` | #057 | apkrund checks the APKRun appcast (user-initiated) and prints "APKRun 1.3.0 is available (you have 1.2.0). Open APKRun to install it." or "APKRun is up to date." Exit 0 in both cases. `--json` has `available`. Exit 69 when apkrund cannot be reached ([runtime-maintenance.md](runtime-maintenance.md) §3.4) |
| `apkrun self-update install` | #057 | Opens `apkrun://settings/general`, where Sparkle installs the update. The CLI does not wait. Installing happens in APKRun.app, because Sparkle replaces the app bundle |
| `apkrun self-update finish [--yes]` | #057 | When APKRun was replaced while Android apps were open (`restartPending`), restarts Android on the new build. Asks when apps are open. Otherwise prints "Nothing to finish." ([runtime-maintenance.md](runtime-maintenance.md) §3.6) |

### 4.8 Diagnostics

Owned by [diagnostics.md](diagnostics.md).

| Command | Task | Behavior |
|---|---|---|
| `apkrun doctor [--deep] [--fix] [--json]` | #059 | Runs the health checks and prints them grouped by subsystem, each with ✓ / ℹ / ⚠ / ✕ / – (not checked) and a remediation. `--deep` adds slow checks (image hashes, wrapper signatures). `--fix` runs the safe automatic fixes that the checks declare, for example re-registering a wrapper with LaunchServices. Exit 0 when healthy or stopped, 3 for warnings only, 1 for failures ([diagnostics.md](diagnostics.md) §7.2). Without apkrund, runs DiagnosticsCore's host checks ([diagnostics.md](diagnostics.md) §7) and reports every other check as "background service not running" with its remediation |
| `apkrun diagnostics [--output <path>] [--include-logcat] [--package <id>] [--deep] [--json]` | #060 | Creates the diagnostics ZIP ([diagnostics.md](diagnostics.md) §8). `--include-logcat` keeps all Android app log lines, still redacted. `--package` adds that app's update history and launch records. `--deep` uses the deep health checks. Default output: `~/Desktop/APKRun-Diagnostics-<timestamp>.zip`. Prints the path and the summary. Works after a boot failure. Without apkrund, builds a host-only bundle with DiagnosticsCore's writer and redaction ([diagnostics.md](diagnostics.md) §8.4) |
| `apkrun logs [--follow] [--since <duration>] [--subsystem <name>] [--level info\|debug] [--json]` | #061 | Host logs. See the rules below the table |
| `apkrun logs --guest [--follow]` | #032 | Guest logcat from the logcat console port, through apkrund ([android-image.md](android-image.md) §7.1). Needs developer mode (`developerModeRequired`) |

`apkrun logs` rules:

- The default is the last hour. `--since` accepts durations up to 30 days.
- The command runs `/usr/bin/log show`, or `log stream` with `--follow`, with the predicate `subsystem BEGINSWITH "io.apkrun"`, and formats the entries ([diagnostics.md](diagnostics.md) §3).
- `--follow` waits for the stream's subscription notice or first output before it reads history. It buffers live entries during that query, up to 4,096 entries and 4 MiB. `--since` applies only to the initial history.
- NDJSON records over 1 MiB are discarded through the next newline.
- After a stream exits, the command retries. It then runs a catch-up query from one second before the last covered instant, once the replacement stream is ready. The checkpoint advances only through time that both a complete history query and the stream cover. Duplicate removal is occurrence-aware, so identical independent records are kept.
- `--json` emits single-line NDJSON and escapes Unicode formatting scalars.
- If unified logging fails or matches nothing, the command reads the public file mirrors in `~/Library/Logs/APKRun/`. If neither source is readable, it exits with `cli.logsUnavailable`.
- If a stream is not ready after three attempts, it runs a one-shot history query with mirror fallback and exits.

### 4.9 Operations

| Command | Task | Behavior |
|---|---|---|
| `apkrun operations list [--json]` | #032 | Running and recent (last 50) long-running operations, with ID, kind, package, progress, and result |
| `apkrun operations wait <id> [--detach]` | #032 | Waits and exits with the operation's result code. `--detach` prints the current snapshot and leaves the operation running |
| `apkrun operations cancel <id>` | #032 | `cancel(operationID)` |

---

## 5. Development commands (`apkrun dev`)

Available in development builds only (`APKRUN_EMBEDDED_RUNTIME`). They run the runtime inside the CLI process ([runtime-daemon.md](runtime-daemon.md) §10). They refuse to use the user's instance while apkrund holds the lock (exit 75). They use `APKRUN_HOME` (default `~/Library/Application Support/APKRun-Dev/`).

| Command | Task | Behavior |
|---|---|---|
| `apkrun dev linux [--kernel <path>] [--initrd <path>] [--tests <list>] [--flood-lines <n>] [--window] [--stats] [--timeout <s>]` | #003–#007, #019, #022, #023 | Boots the test Linux guest ([vm.md](vm.md) §12). `--tests blk,net,vsock,ports,rng,gpu,virgl` sets `apkrun.test=`. With `--tests flood`, `--flood-lines` sets `apkrun.test.flood=<n>` (1–10,000,000; default 10,000,000). Using `--flood-lines` without `flood` is an error. Prints the `APKRUN-TEST:` lines and exits 0 only if every requested check printed `ok`. `--window` shows scanout 0 in a development window. `--stats` adds an overlay with the fps and readback counters ([graphics.md](graphics.md) §7) |
| `apkrun dev image install <dir>` | #065 | Verifies a signed runtime image bundle directory, installs it under `Images/<version>/`, and makes it current. Provisions the instance when there is none. Holds the instance lock. `.aar` archives use `apkrun image install` (§4.7) ([android-image.md](android-image.md) §10.3, [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.3) |
| `apkrun dev boot [--gpu none\|swiftshader\|virgl] [--window] [--stats] [--no-animations] [--guest-transport vsock\|adb] [--wait-ready]` | #012–#014, #021, #022, #023 | Boots Android from `current`, which `apkrun dev image install` sets. `--gpu` selects the GPU profile ([graphics.md](graphics.md) §9): `none` is the development-only `headless` profile, `swiftshader` is `guestSwiftshader`, and `virgl` is `drmVirgl`. The default is `none`. `--window` shows display 0 and binds the development input route to it, so pointer events reach the Guest Agent. `--stats` adds the overlay of `dev linux --stats`. Streams boot phases. Stays in the foreground until Ctrl-C, which stops Android gracefully. While it runs, it serves hvc0, and hvc1 in developer mode, on Unix sockets `$APKRUN_HOME/Runtime/dev-console/<port>.sock` (mode 0600, removed at stop). It always boots in developer mode, provisions the instance when there is none, writes the logcat port to `<logs>/guest/logcat-<timestamp>.log`, and prints state changes on standard error. `--reset` provisions a fresh instance first, `--stop-when-ready` stops Android once it is ready, `--console` copies hvc0 to standard output, and `--cpus`, `--memory-gib`, and `--userdata-gib` size a new instance |
| `apkrun dev console [--kernel <path>] [--initrd <path>] [--android-shell]` | #004, #014 | Connects an interactive raw terminal to hvc0 through the console socket of the running `apkrun dev boot`. `--android-shell` selects hvc1 in developer mode ([android-image.md](android-image.md) §7.1). Exits 69 when no `apkrun dev boot` owns the instance. Ctrl-] requests guest shutdown; after 20 s the VM is force-stopped. Output lost to stream buffering or terminal writes is reported as `runtime.devConsoleOutputDropped`, with the known byte count as a lower bound. If stop and reset both fail, the command stops terminal output and restores the terminal at once, reports `runtime.devConsoleCleanupPending`, and keeps the instance lock until the VM is released |
| `apkrun dev launch [--display 0\|secondary] [--no-window] <apk\|package>…` | #072, #024, #026, #029, #030 | Boots Android if needed, installs each APK through `AdbClient`, and launches each app through the Guest Agent (`LaunchApplication`). The development window is the default, with input on display 0: its pointer events reach the app, and Android keeps running until the window closes or Ctrl-C. A close during boot stops Android before install or launch. After launch starts, the Guest Agent finishes package tasks before Android stops. `--no-window` makes Android stop once the launch is done, and prints the result. Each app gets its own window. `--display secondary` uses a pool display, and several apps run side by side |
| `apkrun dev displays` | #028 | Starts one embedded virgl guest and an interactive prompt. Enter `add --size <w>x<h> --dpi <n>`, `list`, `remove <scanout>`, or `quit` while the process runs |
| `apkrun dev power sleep \| wake` | #069 | Injects host sleep or wake messages ([runtime-daemon.md](runtime-daemon.md) §6) into the running `apkrun dev boot`. Like `dev console`, it does not run a runtime and does not take the instance lock. It writes the request to the control socket `$APKRUN_HOME/Runtime/dev-console/control.sock`, and the owning process calls `DeveloperService.injectPower` ([runtime-api.md](../03-reference/runtime-api.md)). Exits 69 when no `apkrun dev boot` owns the instance |
| `apkrun dev adb [<args>…]` | #015 | Runs the developer's `adb` as `adb -s 127.0.0.1:6520 <args>` against the dev instance, with the terminal attached. It finds `adb` in `$ANDROID_HOME/platform-tools`, then on `PATH`, and connects the endpoint once (up to 2 s) so adb knows the device. It passes adb's exit status through. It does not take the instance lock and does not start Android. Without `adb` it fails with `runtime.adbExecutableMissing` (exit 69, [environment-setup.md](../05-development/environment-setup.md) §2.5). APKRun does not ship `adb` |

- For `apkrun dev launch <apk>`, the source APK is limited to 2 GiB, the package store's per-file transfer limit ([package-store.md](package-store.md) §4.2–§4.3). Larger files fail before `aapt2` staging.
- In Debug builds, `apkrun dev linux` honors `APKRUN_TEST_LINUX_DIR`. It must be an absolute path, so the artifact scripts, the CLI, and hosted T2 tests select the same directory from any working directory. Release builds ignore this test-only override and use `/tmp/apkrun-test-linux` unless the kernel and initramfs paths are given.

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

### 6.3 Tests

| Tier | What is tested | Where |
|---|---|---|
| T0 | Golden output (human and JSON) per command against a fake `RuntimeService`, including every error path. Argument validation (package names, specs, sizes) | `CLI/apkrun/Tests/` |
| T0 | Exit-code table against the error catalog: every entry's `cliExit`, with `"cause"` resolved through the chain | `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/ErrorCatalogTests.swift` |
| T0 | Non-interactive rules: no TTY and no `--yes` gives `cli.confirmationRequired` | `CLI/apkrun/Tests/` |
| T1 | Ctrl-C during `install` cancels the operation (the fake service records `cancel`) | `CLI/apkrun/Tests/` |
| T2 | The acceptance commands of each task against a real apkrund | `Tests/IntegrationTests/` |

---

## 7. Open items

| Item | Working default |
|---|---|
| How `log show` behaves for a standard (non-admin) user on macOS 27 (§4.8, [OQ-04](../04-plan/open-questions.md)) | The file mirrors cover the gap either way. If `log show` fails, `apkrun logs` reads the file mirrors ([diagnostics.md](diagnostics.md) §3.3) |
| Where the image feed and the APKRun appcast are hosted (§4.1, §4.7, [OQ-01](../04-plan/open-questions.md)) | Decide before #057 and #087. Until then the host is the `<updates host>` placeholder. `apkrun setup` without `--image` in release builds, `image check`, `image install --latest`, and `self-update check` depend on it |
