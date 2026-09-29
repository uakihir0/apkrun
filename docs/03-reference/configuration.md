# Configuration Reference

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §1, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5, §6, [../02-design/host-ui.md](../02-design/host-ui.md) §7, §9, [../02-design/cli.md](../02-design/cli.md) §4.2, §4.6, [../02-design/package-store.md](../02-design/package-store.md) §2.4, §11, [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2, [../02-design/diagnostics.md](../02-design/diagnostics.md) §10.3, [package-metadata-json.md](package-metadata-json.md) §3, [wrapper-json.md](wrapper-json.md), [runtime-api.md](runtime-api.md), [error-catalog.md](error-catalog.md) |

This document lists every input that changes how APKRun behaves: global settings, per-package settings, wrapper defaults, environment variables, launch arguments, build constants, and plist keys. The design documents own the behavior. If this document and a design document disagree, the design document wins and this document is fixed.

Keys use dots. In the tables, **Applies** uses these values:

| Applies | Meaning |
|---|---|
| live | takes effect at once. Nothing restarts |
| next session | the next time the app's window opens. An open window keeps the old value. The UI says "Applies the next time ‹App› opens." |
| runtime restart | the next Android start. The UI offers **Restart Android Now** |
| next check | the next scheduled or manual check |
| next login | the next user login (apkrund `RunAtLoad`) |
| new packages | packages recorded after the change. Existing packages keep their values |
| provisioning | when the Android instance is created (first setup or **Reset Android**) |
| next boot | the next Android boot. A boot in progress keeps the old value. No restart is offered |
| at the next health-check result | the next health-check result of an update of the app ([../02-design/update-system.md](../02-design/update-system.md) §8) |
| next update | the next update of the app |

---

## 1. Where configuration lives

### 1.1 Files

| File | Holds | Owner (the only writer) | Schema (`dataSchemas` key, current) | Format |
|---|---|---|---|---|
| `~/Library/Application Support/APKRun/settings.json` | global settings (§2) | RuntimeHost in apkrund | `settings`, 2 | §1.2 |
| `Packages/<id>/settings.json` | per-package settings (§3) | APKStoreCore in apkrund | `packageSettings`, 1 | [package-metadata-json.md](package-metadata-json.md) §3 |
| `Packages/<id>/metadata.json` | update authority and provider. Not settings, but written together with `update.mode` (§3.1) | APKStoreCore | `packageRecord`, 1 | [package-metadata-json.md](package-metadata-json.md) |
| `‹Wrapper›.app/Contents/Resources/wrapper.json` | initial values for a package (§4) | WrapperCore, once, at generation. Never rewritten | `formatVersion` 1 | [wrapper-json.md](wrapper-json.md) |
| wrapper user defaults (the wrapper's bundle ID) | the window frame (`APKRunSessionWindow` autosave) | the wrapper (AppKit) | none | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.2 |

Rules:

- Debug builds use `~/Library/Application Support/APKRun-Dev/` as the root ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6). `apkrun dev` uses the root in `APKRUN_HOME` (§5.1). It owns that root's settings files while it holds the instance lock.
- Only apkrund writes settings files. APKRun.app, APKRunMenuBar, the CLI, and wrappers change settings through RuntimeAPI (§1.4). No other process reads the files.
- Hand edits are not supported. apkrund does not watch the files. A hand edit is read at the next apkrund start and validated (§8.2). The next change through the API may overwrite it.
- Settings of a package survive updates, rollbacks, reinstalls, and Reset Android. They are deleted on uninstall unless the user keeps the app data ([../02-design/package-store.md](../02-design/package-store.md) §2.4, §8).

### 1.2 Storage form

- `settings.json` holds only the keys that were set. An absent key has its default (§2). `apkrun config reset <key>` removes the key.
- Dotted keys map to nested objects. `runtime.memoryGiB` is stored as `{"runtime": {"memoryGiB": …}}`. `integrations.enabled.microphone` is stored as `{"integrations": {"enabled": {"microphone": …}}}`.
- A package's `settings.json` also holds only explicit values: the user's values and the values copied at the first record (§3.3). The resolver needs this to tell a user value from a recommendation ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10.3). The exact schema is in [package-metadata-json.md](package-metadata-json.md) §3.

```json
{
  "schemaVersion": 1,
  "runtime": { "memoryGiB": 6, "idleSuspendMinutes": 5 },
  "maintenance": { "channel": "beta" },
  "integrations": { "enabled": { "microphone": false } },
  "sharedFolders": {
    "roots": [ { "id": "6F1C2A9E-…", "bookmark": "<base64 security-scoped bookmark>", "access": "readOnly" } ]
  }
}
```

### 1.3 Schema versions and migration

- Each file has an integer `schemaVersion`. This build's values are in `components.json` `dataSchemas` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1).
- Older files are migrated when they are loaded, as in [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5:
  1. The original is kept as `<name>.v<old>.json`, one backup per old version, deleted 90 days after the migration.
  2. The file is migrated in memory and validated.
  3. The result is written atomically with `FileManager.replaceItemAt`.
- A migration never changes what a value means.
- Adding a key raises the schema version, because an older build that decodes the file with `Codable` would drop the key.
- Renaming or removing a key is a migration step. It moves the value to the new key or drops it.
- A file with a newer schema than the build understands: §8.3.

### 1.4 Reading and writing through RuntimeAPI

The global settings operations are named here. [runtime-api.md](runtime-api.md) has the signatures and is the authority for them.

| Operation | Endpoint | Behavior |
|---|---|---|
| `configuration()` → `ConfigurationSnapshot` | control | every key of §2 with its effective value, its default, whether it was set, and when a change applies |
| `updateConfiguration(patch)` | control | a JSON merge patch (RFC 7396) on the nested form of §1.2. `null` removes a key (reset). The whole patch is validated first. If one key fails, nothing is written (§8.1). A patch that contains `sharedFolders` is refused |
| `sharedFolders()`, `addSharedFolder(bookmark, access)`, `removeSharedFolder(id)`, `setSharedFolderAccess(id, access)` | control | the only way to change `sharedFolders.roots` ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §11) |
| `packageSettings(id)` → `ResolvedPackageSettings` | control | every key of §3 with its effective value and its source: `globalSwitch`, `user`, `recommended`, or `default` (§3.2) |
| `updatePackageSettings(id, patch)` | control | a validated JSON merge patch on `PackageSettings` ([../02-design/package-store.md](../02-design/package-store.md) §11.1). `null` removes the user's value (**Reset**) |
| `setUpdatePolicy(id, UpdatePolicy)` | control | writes the record's authority and provider and `update.mode` together ([../02-design/update-system.md](../02-design/update-system.md) §2.3) |
| `SessionDescriptor.windowPrefs`, `windowPrefsChanged(WindowPrefs)` | wrapper | the wrapper's own package only: `resizable`, `alwaysOnTop`, `zoom` ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3) |

- Wrapper endpoints may read, not change, the resolved `window.*` and `input.*` values of their own package: through `packageInfo`, `SessionDescriptor`, and `windowPrefsChanged` ([runtime-api.md](runtime-api.md) §14.1). The window process translates input with them (§3.1). Their only write is `window.zoom`, through `resize` ([runtime-api.md](runtime-api.md) §14.3). They cannot read or change any other setting.
- Every accepted change is written before the reply. The owner writes a temporary file in the same directory, calls `fcntl(F_BARRIERFSYNC)`, and renames it over the old file. `F_FULLFSYNC` is not used. Settings writes are not coalesced.
- A patch that changes nothing is accepted. Nothing is written and no event is posted.
- Setting a key explicitly to its default value stores it. For a package this matters: an explicit value beats a recommendation (§3.2).

### 1.5 Change notification

| Event | Topic | Posted when |
|---|---|---|
| `configurationChanged(keys: [String])` | `runtime` | global keys changed. `keys` holds dotted keys |
| `PackageChange.settingsChanged(PackageID, keys: [String])` | `packages` | package keys changed ([../02-design/package-store.md](../02-design/package-store.md) §11.3) |
| `sharedFoldersChanged` | `integrations` | a shared folder root was added, removed, or changed |
| `windowPrefsChanged(WindowPrefs)` | session channel | `window.resizable`, `window.alwaysOnTop`, or `window.zoom` of that package changed |

- Consumers read the current value after the event. They never cache a value across the event ([../02-design/package-store.md](../02-design/package-store.md) §2.4).
- Components inside apkrund (IdleController, UpdateScheduler, IntegrationPolicy, DisplayPool, ImageUpdateCoordinator) get the same change in process.
- APKRun.app applies the Sparkle settings at launch and on every `configurationChanged` that contains a `maintenance.*` key ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2).

### 1.6 What is not a setting

| Item | Where it lives | Reference |
|---|---|---|
| The menu bar item | the registration of the APKRunMenuBar login item (`SMAppService`). There is no key (§2.10) | [../02-design/host-ui.md](../02-design/host-ui.md) §2.1, §9.1 |
| `lastLaunchedBuild`, `registeredAgentPlistSHA256` | APKRun.app user defaults `io.apkrun.APKRun`. Bookkeeping, not choices | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §9 |
| Update authority, update source, provider configuration | the package record (`metadata.json`) | [../02-design/update-system.md](../02-design/update-system.md) §2 |
| Provider tokens | Keychain, service `io.apkrun.provider.github` | [../02-design/update-system.md](../02-design/update-system.md) §4.6 |
| Denied wrappers | `Wrappers/registry.json` | [../02-design/wrapper.md](../02-design/wrapper.md) §7.3 |
| Debug logging in release builds | `log config` (macOS), not an APKRun key | [../02-design/diagnostics.md](../02-design/diagnostics.md) §3 |

### 1.7 Diagnostics

- The diagnostics bundle has `config.json` with the global settings and each package's `settings.json` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §6.2).
- Every key of §2 and §3 is on the allowlist and is copied as is.
- `sharedFolders.roots` is reduced to a count and the last path component of each root. Bookmarks are never copied.
- `apkrun config list --json` has the same content as `configuration()`.

---

## 2. Global settings

Stored in `settings.json` (§1.1). The UI column names the tab in APKRun Settings ([../02-design/host-ui.md](../02-design/host-ui.md) §9). In the CLI column, `config` means `apkrun config get | set | reset <key>` ([../02-design/cli.md](../02-design/cli.md) §4.6). Every key is also listed by `apkrun config list`.

### 2.1 `runtime.*`

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `runtime.startPolicy` | enum | `onDemand`, `atLogin` | `onDemand` | next login | Runtime: "Start Android" | `config` | [runtime-daemon.md](../02-design/runtime-daemon.md) §5.4 |
| `runtime.idleSuspendMinutes` | integer | 0–1440. `0` = never | `10` | live | Runtime: "Put Android to sleep after ‹n› minutes without apps" | `config` | [runtime-daemon.md](../02-design/runtime-daemon.md) §5.2 |
| `runtime.idleStopMinutes` | integer | 0–1440. `0` = never | `60` | live | Runtime: "Stop Android after ‹n› minutes" | `config` | [runtime-daemon.md](../02-design/runtime-daemon.md) §5.2 |
| `runtime.autoRestart` | bool | `true`, `false` | `true` | live | Runtime: "Restart Android automatically after a crash" | `config` | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.6 |
| `runtime.cpuCount` | integer | 2 … min(8, performance + efficiency cores) | `4` | runtime restart | Runtime: "Memory, processors" | `config` | [vm.md](../02-design/vm.md) §10 |
| `runtime.memoryGiB` | integer (GiB) | 3 … 50 % of physical memory, rounded down | `4`, lowered to fit 50 % | runtime restart | Runtime: "Memory, processors" | `config` | [vm.md](../02-design/vm.md) §10, [runtime-daemon.md](../02-design/runtime-daemon.md) §12 |
| `runtime.userdataGiB` | integer (GiB) | 8–256. At provisioning also at most the free space of the volume minus 10 GiB | `32` | provisioning | Runtime: "Android storage" (not yet in host-ui.md) | `config` | [android-image.md](../02-design/android-image.md) §5.2 |
| `runtime.bootTimeoutSeconds` | integer | 120–1800 | `180` | next boot | none | `config` | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |
| `runtime.firstBootTimeoutSeconds` | integer | 600–3600 | `900` | next boot | none | `config` | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |

- `runtime.idleStopMinutes` counts from when idleness began, including suspended time. A value below `runtime.idleSuspendMinutes` means "stop without suspending" ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5.2). A change does not reset the idle clock.
- `runtime.startPolicy = atLogin` preboots 60 s after login. Preboot is skipped on battery below 30 % and while the boot-loop guard is active ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5.4).
- `runtime.cpuCount`, `runtime.memoryGiB`, and `runtime.userdataGiB` depend on the Mac. `set` checks them against this Mac. A stored value that no longer fits (for example after moving to a Mac with less memory) is clamped when it is used. The file is not changed (§8.2).
- `runtime.userdataGiB` is fixed when the instance is provisioned. After provisioning, a change takes effect only with **Reset Android**, which deletes Android data. `config set` prints "Applies after Reset Android."
- The two boot timeouts have no UI. They are for slow Macs and for testing.

### 2.2 `display.*`

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `display.maxSessions` | integer | 1–15 | `8` | live. Checked when a session opens. Open sessions stay open when the value is lowered | Runtime: "Maximum open apps" | `config` | [display-and-windowing.md](../02-design/display-and-windowing.md) §2 |

System sessions (for example the update health check, at most 90 s) do not count against `display.maxSessions`. A session beyond the limit fails with `RuntimeFailure.displayPoolExhausted`.

### 2.3 `graphics.*`

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `graphics.safeMode` | bool | `true`, `false` | `false` | runtime restart | Troubleshooting: **Start in Graphics Safe Mode** | `config` | [graphics.md](../02-design/graphics.md) §9 |
| `graphics.limits.*` | integer | see below. Development builds only | see below | runtime restart | none | `config` (development builds only) | [graphics.md](../02-design/graphics.md) §5.4 |

- `graphics.safeMode = true` boots with the `guestSwiftshader` profile instead of `drmVirgl` (`BootOptions.gpuProfile`, [../02-design/android-image.md](../02-design/android-image.md) §9.1). **Start in Graphics Safe Mode** sets the key and restarts Android. There is no automatic fallback.
- While it is on, the health check `graphics.safeMode` warns: "Graphics safe mode is on. Apps are slower." `apkrun config reset graphics.safeMode` turns it off.

`graphics.limits.*` exist only in development builds. Release builds treat them as unknown keys (§8).

| Key | Allowed values | Default |
|---|---|---|
| `graphics.limits.totalResourceMemoryMiB` | ≥ 1 | `2048` |
| `graphics.limits.maxResourceMiB` | ≥ 1 | `256` |
| `graphics.limits.maxDimension` | 1–16384 | `8192` |
| `graphics.limits.maxContexts` | ≥ 1 | `256` |
| `graphics.limits.maxResources` | ≥ 1 | `65536` |
| `graphics.limits.maxBackingEntries` | ≥ 1 | `16384` |
| `graphics.limits.maxSubmit3DMiB` | ≥ 1 | `4` |

### 2.4 `audio.*`

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `audio.output` | bool | `true`, `false` | `true` | runtime restart | Runtime: "Sound output" (**Restart Android Now**) | `config` | [desktop-integration.md](../02-design/desktop-integration.md) §8.1, [vm.md](../02-design/vm.md) §11 |

The microphone device is not a global key. It follows the per-package `integrations.microphone` values (§3.1).

### 2.5 `developer.*`

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `developer.enabled` | bool | `true`, `false` | `false` | runtime restart for ADB and logcat capture. Live for the UI items | Advanced: **Developer mode** (asks for confirmation) | `config`. Turning it on asks `Continue? [y/N]`. `--yes` skips the question | [android-image.md](../02-design/android-image.md) §11.3, [security-model.md](../01-architecture/security-model.md) |

- At the next Android start it sets `androidboot.apkrun.devmode=1`: ADB listens on host loopback `127.0.0.1:6520`, and logcat is captured ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §2).
- At once it shows LocalProvider ([../02-design/update-system.md](../02-design/update-system.md) §4.3) and the frame statistics overlay ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.7).
- The main window header and the menu bar show "Developer mode" while the key is on, and also while the running Android still has ADB on.
- The health check `agent.developerMode` fails when ADB is on while the key is off.
- Without a terminal and without `--yes`, `config set developer.enabled true` fails with `cli.confirmationRequired` ([../02-design/cli.md](../02-design/cli.md) §3.4).

### 2.6 `maintenance.*` (APKRun and Android system updates)

The keys and meanings are in [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §6. This table adds when they apply and where they appear.

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `maintenance.checkAutomatically` | bool | `true`, `false` | `true` | live | General: "Check for updates automatically" | `config` | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §6 |
| `maintenance.channel` | enum | `stable`, `beta` | `stable` | live. Starts an Android system update check at once | General: channel | `config` | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4, §6 |
| `maintenance.installAPKRunAutomatically` | bool | `true`, `false` | `false` | live | General: "Install APKRun updates automatically" | `config` | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.5.1, §6 |
| `maintenance.downloadImagesAutomatically` | bool | `true`, `false` | `true` | next check | General: "Download Android system updates in the background" | `config` | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.4 |
| `maintenance.installImages` | enum | `automatic`, `ask` | `automatic` | live. Used at the next evaluation of the idle gate (every 5 min) | General: **Install automatically when the Mac is idle** / **Ask before installing** | `config` | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.6 |
| `maintenance.notifyImageInstalled` | bool | `true`, `false` | `false` | live | General: "Notify me when Android was updated" | `config` | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §6, §7.1, [host-ui.md](../02-design/host-ui.md) §9.1, §11 |

- Sparkle gets its settings from these keys. `automaticallyChecksForUpdates` comes from `maintenance.checkAutomatically`, and `automaticallyDownloadsUpdates` from `maintenance.installAPKRunAutomatically`. `allowedChannels` is `["beta"]` on the beta channel. The mapping is in [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2.
- Switching from `beta` to `stable` never downgrades APKRun or Android.

### 2.7 `updates.*` (Android app updates)

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `updates.checkIntervalHours` | integer | `1`, `3`, `6`, `12`, `24`, `72`, `168` | `6` | next check. Each package's next check time is recomputed from its last check | Updates: check interval | `config` | [update-system.md](../02-design/update-system.md) §3.2 |
| `updates.downloadOnExpensiveNetwork` | bool | `true`, `false` | `false` | live. Waiting downloads start when it is turned on | Updates: "Download on expensive networks" | `config` | [update-system.md](../02-design/update-system.md) §3.4 |
| `updates.startRuntimeToInstall` | bool | `true`, `false` | `false` | live | Updates: "Start Android to install updates" | `config` | [update-system.md](../02-design/update-system.md) §3.5 |
| `updates.notifyInstalled` | bool | `true`, `false` | `false` | live | Updates: "Notify me after automatic updates" | `config` | [update-system.md](../02-design/update-system.md) §9 |

### 2.8 `integrations.*` and `sharedFolders.*`

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `integrations.enabled.clipboard`, `.notifications`, `.links`, `.files`, `.sharedFolders`, `.microphone` | bool | `true`, `false` | `true` | live | Privacy: global switches | `config` | [desktop-integration.md](../02-design/desktop-integration.md) §2.2 |
| `integrations.defaults.clipboard` | bool | `true`, `false` | `true` | new packages | Privacy: defaults for new apps | `config` | [desktop-integration.md](../02-design/desktop-integration.md) §2.2 |
| `integrations.defaults.notifications` | bool | `true`, `false` | `true` | new packages | same | `config` | same |
| `integrations.defaults.links` | enum | `ask`, `mac`, `android` | `ask` | new packages | same | `config` | same |
| `integrations.defaults.files` | bool | `true`, `false` | `true` | new packages | same | `config` | same |
| `integrations.defaults.sharedFolders` | enum | `off`, `readOnly`, `readWrite` | `off` | new packages | same | `config` | same |
| `integrations.defaults.microphone` | bool | `true`, `false` | `false` | new packages | same | `config` | same |
| `sharedFolders.roots` | list of `{id, bookmark, access}` | `access`: `readOnly`, `readWrite`. At most 32 added folders | empty: only the APKRun Shared folder | live | Files: the folder list | `apkrun shared-folders list | add | remove`. `config get` and `config list` show it. `config set` and `config reset` refuse it | [desktop-integration.md](../02-design/desktop-integration.md) §6.4 |

- `integrations.enabled.<name> = false` turns the integration off for every package. It does not change any package's settings (§3.2).
- `integrations.defaults.*` are copied into a package's settings when the package is first recorded (§3.3). A change does not affect existing packages. `wrapper.json` values win for packages installed from a portable wrapper, within the cap of §3.3.
- `sharedFolders.roots` holds the folders the user added. `id` is a UUID string. `bookmark` is base64 security-scoped bookmark data, so moved and renamed folders are followed. `access` is the folder's maximum access.
- The APKRun Shared folder (`~/Library/Application Support/APKRun/Shared/`) is built in and is not stored. It is always the first root. Its maximum access is `readWrite`, and it cannot be removed.
- `apkrun shared-folders add` without `--read-write` adds a folder with `readOnly`.
- `config reset --all` does not touch `sharedFolders.roots`.

### 2.9 `system.*`

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `system.syncLocale` | bool | `true`, `false` | `true` | live (pushed to a running Android, and at every boot) | Language & Region: "Use the Mac's language in Android" | `config` | [desktop-integration.md](../02-design/desktop-integration.md) §9 |
| `system.syncTimeZone` | bool | `true`, `false` | `true` | live, as above | Language & Region: "Use the Mac's time zone" | `config` | same |
| `system.syncClockFormat` | bool | `true`, `false` | `true` | live, as above | Language & Region: "Use the Mac's 12/24-hour setting" | `config` | same |

### 2.10 `wrappers.*` and the menu bar item

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `wrappers.defaultLocation` | enum | `userApplications` (`~/Applications`), `allUsersApplications` (`/Applications`), `ask` | `userApplications` | live (the next add flow) | General: "Default location for new Mac apps" | `config` | [host-ui.md](../02-design/host-ui.md) §6, §9.1, [wrapper.md](../02-design/wrapper.md) §6.3 |

- The add flow's location pop-up starts at this value. `ask` shows the pop-up with no preselected folder.
- `allUsersApplications` is offered to administrators only. For a user who is not an administrator, it acts as `ask`.
- The CLI does not use this key. `apkrun wrap --output` defaults to `~/Applications` ([../02-design/wrapper.md](../02-design/wrapper.md) §12.2).

**Show APKRun in the menu bar** (General) has no key. The toggle shows and changes the registration of the APKRunMenuBar login item (`SMAppService.loginItem(identifier:)`). APKRun.app registers it at the first launch, so the default is on. If the user removes the login item in System Settings → General → Login Items & Extensions, the toggle shows off. It is not in `apkrun config`.

---

## 3. Per-package settings

Stored in `Packages/<id>/settings.json`. The schema is in [package-metadata-json.md](package-metadata-json.md) §3, and that file wins if a key or default differs from this table. The UI column names the section of the app page ([../02-design/host-ui.md](../02-design/host-ui.md) §7). In the CLI column, `settings` means `apkrun settings <package> get | set | reset <key>` ([../02-design/cli.md](../02-design/cli.md) §4.2).

### 3.1 Keys

`window.*`:

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `window.mode` | enum | `secondaryDisplay`, `primaryDisplayCompatibility` | `secondaryDisplay` | next session | Window: **Standard** / **Compatibility** | `settings` | [display-and-windowing.md](../02-design/display-and-windowing.md) §8 |
| `window.defaultWidth` | integer (pt) | ≥ 320 | `480`, or `850` when the launcher activity requests landscape | next session | Window: default size, **Use Current Size** | `settings` | [display-and-windowing.md](../02-design/display-and-windowing.md) §6.2 |
| `window.defaultHeight` | integer (pt) | ≥ 400 | `850`, or `480` in landscape | next session | same | `settings` | same |
| `window.resizable` | bool | `true`, `false` | `true` (`false` with fallback B) | live | Window: "Resizable" | `settings` | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.1 |
| `window.alwaysOnTop` | bool | `true`, `false` | `false` | live | Window: "Always on top" | `settings` | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.7 |
| `window.zoom` | number | 0.75–2.0 | `1.0` | live (next session with fallback B) | Window: 75 %–200 %. View → Zoom In, Zoom Out, Actual Size | `settings` | [display-and-windowing.md](../02-design/display-and-windowing.md) §6.1 |
| `window.closeBehavior` | enum | `stop`, `keepRunning` | `stop` | live. Read when the window closes | Window: **Quit the app** / **Keep it running in the background** | `settings` | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.6 |

- The default size is clamped when it is used: to 90 % of the screen's visible frame, and to the 4095 px backing limit ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §6.2).
- A window frame that AppKit saved (`APKRunSessionWindow`) wins over the default size when the window opens ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.2).

`input.*` ([../02-design/host-ui.md](../02-design/host-ui.md) §7.3, [../02-design/input.md](../02-design/input.md)):

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `input.escapeKey` | enum | `back`, `escape` | `back` | next session | Input: "Esc key" | `settings` | [input.md](../02-design/input.md) §5.2 |
| `input.secondaryClick` | enum | `mouseSecondary`, `longPress` | `mouseSecondary` | next session | Input: "Right click" | `settings` | [input.md](../02-design/input.md) §4.3 |
| `input.scrollMode` | enum | `scroll`, `touchDrag` | `scroll` | next session | Input: "Scrolling" | `settings` | [input.md](../02-design/input.md) §4.4 |
| `input.hover` | bool | `true`, `false` | `true` | next session | Input: "Mouse hover" | `settings` | [input.md](../02-design/input.md) §4.1 |
| `input.sendCommandKey` | bool | `true`, `false` | `false` | next session | Input: "Send the Command key to the app" | `settings` | [input.md](../02-design/input.md) §5.2 |

Input is translated in the wrapper process, and `WindowPrefs` carries no input keys, so input keys apply at the next session.

`integrations.*` ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2.1):

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `integrations.clipboard` | bool | `true`, `false` | `true` | live | Integrations: Clipboard | `settings` | [desktop-integration.md](../02-design/desktop-integration.md) §4 |
| `integrations.notifications` | bool | `true`, `false` | `true` | live | Integrations: Notifications | `settings` | [desktop-integration.md](../02-design/desktop-integration.md) §5 |
| `integrations.links` | enum | `ask`, `mac`, `android` | `ask` | live | Integrations: Links (**Ask** / **Open in Mac browser** / **Open in Android**) | `settings` | [desktop-integration.md](../02-design/desktop-integration.md) §7 |
| `integrations.files` | bool | `true`, `false` | `true` | live | Integrations: Files | `settings` | [desktop-integration.md](../02-design/desktop-integration.md) §6.2, §6.3 |
| `integrations.sharedFolders` | enum | `off`, `readOnly`, `readWrite` | `off` | live | Integrations: Shared folders (**Off** / **Read only** / **Read and write**) | `settings` | [desktop-integration.md](../02-design/desktop-integration.md) §6.4 |
| `integrations.microphone` | bool | `true`, `false` | `false` | live, but see below | Integrations: Microphone | `settings` | [desktop-integration.md](../02-design/desktop-integration.md) §8.2 |

- IntegrationPolicy reads the settings at every evaluation and pushes only changes to the Guest Agent ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2.3, §3.2).
- The microphone input device is attached only while at least one package has `integrations.microphone` on. Turning it on for the first package, or off for the last, needs a runtime restart. The UI asks **Restart Android Now** / **Later** ([../02-design/host-ui.md](../02-design/host-ui.md) §7.4).
- Camera is not supported in v1. It has no key.

`update.*` ([../02-design/update-system.md](../02-design/update-system.md)):

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `update.mode` | enum | `automatic`, `notifyOnly` | `automatic` | next check | Updates: **Automatic** / **Notify only** / **Manual** | `apkrun update policy <package> --mode automatic\|notify\|manual`, or `settings` | [update-system.md](../02-design/update-system.md) §2.2, §2.3 |
| `update.autoRollback` | bool | `true`, `false` | `true` | at the next health-check result | Updates: "Undo updates that fail to start" | `settings` | [update-system.md](../02-design/update-system.md) §8.3 |
| `update.healthCheckLaunch` | bool | `true`, `false` | `true` | next update | Updates: "Open the app briefly after updating to check it" | `settings` | [update-system.md](../02-design/update-system.md) §8.1 |

- **Manual** is the authority `manual` in the package record, not a mode. `update.mode` has an effect only while the authority is `apkrun` ([../02-design/update-system.md](../02-design/update-system.md) §2.1–§2.3).
- The UI and `apkrun update policy` use `setUpdatePolicy`, which writes the authority, the provider, and `update.mode` together. `apkrun settings set update.mode` changes only the mode. It is stored while the authority is `manual` and takes effect when the authority returns to `apkrun`.
- `update.healthCheckLaunch = false` limits the health check to `versionOnly` ([../02-design/update-system.md](../02-design/update-system.md) §8.1).

### 3.2 Precedence

`PackageSettingsResolver` returns the effective value of each key. The first rule that matches wins:

| Order | Source | Notes |
|---|---|---|
| 1 | Global switch `integrations.enabled.<name> = false` | forces the integration off. The package's stored value is kept |
| 2 | The value in the package's `settings.json` | the user's value, or a value copied at the first record (§3.3) |
| 3 | The compatibility database recommendation for the installed version | only `window.*`, `input.*`, `integrations.*` (only to turn an integration off), and `update.healthCheckLaunch` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10.3) |
| 4 | The built-in default of §3.1 | |

- Recommendations are never written to `settings.json`. The UI marks them "Recommended for this app".
- **Reset** (`apkrun settings <package> reset <key>`, or `null` in a patch) removes the stored value. The effective value falls back to rule 3 or 4.
- For shared folders, the effective access is the lower of the root's maximum access and the package's `integrations.sharedFolders` ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6.4).
- Packages that APKRun does not manage (installed inside Android by other means) use the built-in defaults, with `integrations.notifications` off ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2.3).
- Global settings do not override package values, except the switches of rule 1. There are no global window or input defaults in v1. `integrations.defaults.*` are not a rule here. They act only at the first record.

### 3.3 Values written at the first record

When the store creates a package record, it writes initial settings. This happens at install and import, at a bootstrap import from a wrapper, and at the approval of a wrapper whose package has no settings ([../02-design/wrapper.md](../02-design/wrapper.md) §3). For each key, the first source that has a value wins:

1. The flags of the installing command: `apkrun wrap … --window-size <w>x<h>`, `--resizable` or `--no-resizable`, `--updates automatic|notify|manual` ([../02-design/wrapper.md](../02-design/wrapper.md) §12.2).
2. `wrapper.json` (§4).
3. `integrations.defaults.*`, for integration keys only.

Rules:

- A value equal to the built-in default is not written, so a later compatibility recommendation can still apply.
- `--updates` and `wrapper.json` `updates.authority` and `updates.provider` go to the package record ([../02-design/update-system.md](../02-design/update-system.md) §2.4). The mode goes to `update.mode`.
- After the first record, only the user's changes write settings. `wrapper.json` is not read again for settings.
- **Cap for wrappers from elsewhere.** A wrapper that apkrund on this Mac did not generate (registry `approval: user`: a portable or distribution wrapper, or a copy from another Mac, [../02-design/wrapper.md](../02-design/wrapper.md) §7.3) cannot grant more than this Mac's defaults. For each `integration` key, its value is used only when it is not more permissive than `integrations.defaults.<key>`; otherwise the default is written. The order is `false` < `true`, `off` < `readOnly` < `readWrite`, and `android` < `ask` < `mac`. So such a wrapper can turn an integration off or down, never on or up. The approval dialog and the bootstrap install sheet list the integrations the app gets.

---

## 4. Defaults from `wrapper.json`

The schema and its validation are in [wrapper-json.md](wrapper-json.md). This section only shows where each value goes.

| `wrapper.json` | Becomes | Notes |
|---|---|---|
| `window.mode`: `standard`, `compatibility` | `window.mode`: `secondaryDisplay`, `primaryDisplayCompatibility` | [../02-design/wrapper.md](../02-design/wrapper.md) §3 |
| `window.defaultWidth`, `window.defaultHeight` | the same keys | |
| `window.resizable` | `window.resizable` | |
| `updates.mode` | `update.mode` | [../02-design/update-system.md](../02-design/update-system.md) §2.4 |
| `updates.authority`, `updates.provider` | the package record, not settings | [../02-design/update-system.md](../02-design/update-system.md) §2.4 |
| `integration.<key>` (no prefix) | `integrations.<key>` | absent keys get `integrations.defaults.*`. Unknown keys are ignored |
| `application.*`, `runtime.*`, `formatVersion`, `kind` | identity and launcher compatibility, not settings | `runtime.minimumVersion` is `LauncherBuild.minimumRuntimeVersion` |

- The values are initial values only (§3.3).
- In practice only portable and distribution wrappers provide them. A local wrapper is generated for a package that already has a record, so its values are never copied.
- A value that is not allowed for its key in §3.1 is treated as absent and logged. The other keys are still used.

---

## 5. Environment variables and launch arguments

### 5.1 Environment variables

| Variable | Read by | Effect | Builds that honor it | Test only |
|---|---|---|---|---|
| `NO_COLOR` | `apkrun` | no color in output (like `--no-color`) | all | no |
| `APKRUN_HOME` | `APKRunPaths` in `apkrun dev`, in debug apkrund, and in test hosts | relocates the data root ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md)) | debug builds only. Release builds ignore it: apkrund owns its paths, and `apkrun dev` is not compiled | development and tests |
| `APKRUN_LOG_LEVEL` | `apkrun dev` | `debug` or `info` for the in-process runtime | debug builds only | development |
| `APKRUN_STORE_FAULT=<kind>:<step>` | APKStoreCore | injects a store fault | debug builds only | yes |
| `APKRUN_GRAPHICS_FAULT=rendererInit` | the graphics host | makes renderer initialization fail | debug builds only | yes |
| `APKRUN_RUNTIME_FAULT=rejectAgent:guest` | RuntimeCore | rejects the Guest Agent handshake | debug builds only | yes |
| `APKRUN_LAUNCHER_TEST_NO_RUNTIME=1` | APKRunLauncher | runs the launcher without a runtime | debug builds only | yes |
| `APKRUN_TEST_HEADLESS_LAUNCH=1` | apkrund | `launch` opens a session owned by apkrund that discards its frames. Exists from #032 until #068 removes it ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §13 #032) | debug builds only | yes |
| `APKRUN_TEST_MARKER_TIMEOUT=<n>s` or `<n>m` | MaintenanceService | replaces the 10-minute maintenance marker timeout | Debug and `ReleaseUpdateTest`. Shipped Release builds ignore it | yes |
| `APKRUN_TEST_INSTALL_CHOICE=closeApps\|whenClosed` | `TestUserDriver` in APKRun.app | answers APKRun's own install dialog during the maintenance tests | `ReleaseUpdateTest` only | yes |
| `APKRUN_TEST_IMAGE_FEED_URL=<url>` | `ImageFeedClient` | replaces the image feed base URL. May be `http://127.0.0.1` | debug builds only | yes |
| `APKRUN_TEST_IDLE_SECONDS=<n>` | the image apply gate | replaces the idle time read from `HIDIdleTime` | debug builds only | yes |
| `APKRUN_TEST_POWER=ac\|battery:<percent>` | the image apply gate | replaces the power source read from IOKit | debug builds only | yes |
| `APKRUN_ANDROID_BUILD_API_KEY` | the Android image fetch tool | API key for build downloads | build machines only. Not read by the product | build tooling |

References: [../02-design/cli.md](../02-design/cli.md) §3.6, [../02-design/package-store.md](../02-design/package-store.md), [../02-design/diagnostics.md](../02-design/diagnostics.md) §12, [../02-design/wrapper.md](../02-design/wrapper.md), [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14, [../02-design/android-image.md](../02-design/android-image.md) §2.2.

### 5.2 Launch arguments and URLs

| Process | Argument | Effect | Reference |
|---|---|---|---|
| APKRun.app | none | normal start. Onboarding opens if setup is not complete | [../02-design/host-ui.md](../02-design/host-ui.md) §3.3 |
| APKRun.app | `--notify` | started by apkrund to post notifications. No window. Quits 30 s after the last notification | [../02-design/host-ui.md](../02-design/host-ui.md) §3.3 |
| APKRun.app | `--approve` | started by apkrund for a wrapper approval. Shows only the approval window | [../02-design/host-ui.md](../02-design/host-ui.md) §3.3 |
| APKRun.app | `--register-runtime` | registers the apkrund LaunchAgent, then quits | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6, [../02-design/cli.md](../02-design/cli.md) §4.1 |
| APKRun.app | `--test-check-for-updates` | starts a user-initiated Sparkle check. `ReleaseUpdateTest` only | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| APKRunLauncher | `--package <id>` | the generic launcher opens that package | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.2 |
| a wrapper | `--apkrun-background notifications` | starts the wrapper in the background to deliver notifications | [../02-design/wrapper.md](../02-design/wrapper.md) §5.8 |
| `apkrun` | `--json`, `--yes`, `--no-color`, `--detach` | output and confirmation flags | [../02-design/cli.md](../02-design/cli.md) §3 |
| APKRun.app | URL `apkrun://settings/<pane>` | opens Settings at `general`, `runtime`, `updates`, `privacy`, `files`, `language`, `storage`, `troubleshooting`, or `advanced` | [../02-design/host-ui.md](../02-design/host-ui.md) §3.1 |
| APKRun.app | URL `apkrun://package/<packageId>/<section>` | opens the app page at `general`, `window`, `input`, `integrations`, `updates`, `mac-app`, or `storage` | [../02-design/host-ui.md](../02-design/host-ui.md) §3.1 |

### 5.3 Boot parameters

| Parameter | Set from | Builds | Reference |
|---|---|---|---|
| `androidboot.apkrun.devmode=0|1` | `developer.enabled`, at every boot | custom image | [../02-design/android-image.md](../02-design/android-image.md) §6.2, §11.3 |
| GPU profile (`drmVirgl` or `guestSwiftshader`) | `graphics.safeMode`, at every boot | all | [../02-design/graphics.md](../02-design/graphics.md) §9 |
| `androidboot.apkrun.test.*` (`marker=<value>`, `fail_health=1`, `fail_boot=1`) | test harness | test image bundles only. A CI check keeps them out of release manifests | [../02-design/android-image.md](../02-design/android-image.md) §6.2 |
| `apkrun.test=…`, `apkrun.test.poweroff=1` | test harness | the Linux test guest only | [../02-design/vm.md](../02-design/vm.md) §12 |

---

## 6. Build-time configuration and limits

### 6.1 Build configurations

| Configuration | What changes | Reference |
|---|---|---|
| Debug | `.dev` identities (`io.apkrun.APKRun.dev`, `io.apkrun.apkrund.dev`, `io.apkrun.apkrund.dev.xpc`). Data in `APKRun-Dev` roots. No `SUFeedURL`. `APKRUN_EMBEDDED_RUNTIME` compiles `apkrun dev` (`apkrun-dev`). The debug-only variables of §5.1 and `graphics.limits.*` are honored | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6, [../02-design/cli.md](../02-design/cli.md) §5 |
| Release | the shipped build. Developer ID signed, notarized, with the Sparkle feed of [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 |
| `ReleaseUpdateTest` | release code. `SUFeedURL` points at the local appcast server. Test key `Tests/Fixtures/signing/test-sparkle-ed25519.pub`. Signed, not notarized. Honors `APKRUN_TEST_MARKER_TIMEOUT`. Trusts the build machine's development image key in addition to the release image keys ([../02-design/android-image.md](../02-design/android-image.md) §10.1) | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 |

### 6.2 Limits and constants

These values are compiled in. They are not settings. The owning document is the authority. If a value here differs from it, the owning document wins.

| Area | Constants | Owner |
|---|---|---|
| apkrund | exit grace 2 min. Crash loop: 3 unclean exits in 10 min. At most 64 requests in flight per connection and 8 control connections. A wrapper endpoint is dropped 10 min after its last connection | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.4, §2.5, §8.2 |
| Boot | stall 90 s (first boot 600 s). Agent handshake 30 s. Boot-loop guard: 3 failures in 10 min. Automatic restart: one cold boot, not retried within 10 min. Graceful stop up to 40 s | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2, §3.5, §3.6 |
| Host | at least 8 GiB of physical memory. Reset recovery point kept 7 days | [runtime-daemon.md](../02-design/runtime-daemon.md) §9.5, §12 |
| Display | 15 display slots. System sessions at most 90 s. Minimum content 320 × 400 dp × zoom. Density 120–640 dpi. Backing at most 4095 px. Close timeout 5 s | [display-and-windowing.md](../02-design/display-and-windowing.md) §2, §6.2, §7.6 |
| Graphics | the defaults of `graphics.limits.*` (§2.3) | [graphics.md](../02-design/graphics.md) §5.4 |
| Clipboard | text 1 MiB, HTML 1 MiB, image 16 MiB and 8192 px | [desktop-integration.md](../02-design/desktop-integration.md) §4.4 |
| Files | drops: at most 20 files, 2 GiB each, 4 GiB total. Shared folders: 4096 entries per listing page, 1 MiB per read or write, 64 open handles per package | [desktop-integration.md](../02-design/desktop-integration.md) §6 |
| Links | at most 8 KiB, 3 per 10 s. Prompt timeout 60 s | [desktop-integration.md](../02-design/desktop-integration.md) §7 |
| Notifications | 50 per 10 s. Title 256, text 2048 characters. 32 categories (LRU) | [desktop-integration.md](../02-design/desktop-integration.md) §5 |
| Package store | import space 2 × source + 2 GiB. Staging: set size + 2 GiB. Extraction: 2 GiB per file, 8 GiB total. aapt2: 20 s, 16 MiB. Journal compaction at 1 MiB. Host space: warning below 5 GiB, refusal below 2 GiB. `incoming/` 24 h. `failed/` 7 days | [package-store.md](../02-design/package-store.md) §3.4 |
| App updates | jitter ±10 %. Backoff 30 min, 2 h. 4 parallel checks, 2 per host, 1 background download. Low Power Mode holds downloads over 50 MiB. Background install: waited over 24 h, AC power, idle 15 min. Health budget 90 s. Download cap 8 GiB. Parser caps: manifest 1 MiB, release JSON 4 MiB, index 64 MiB, notes 16 KiB. Gentle wait 7 days. History: 365 days or 5 000 lines | [update-system.md](../02-design/update-system.md) §3, §7, §8, §10 |
| APKRun and Android system updates | probe every 24 h ± 1 h, 30 s, 2 MiB. Image feed 1 MiB, signature 4 KiB, expiry 30 days. Check backoff 1 h, 6 h, then daily. Check on app open at most every 6 h. Download retries 15 min, 1 h, 6 h. Free space: archive + expanded + 10 GiB. Idle gate: idle 10 min, AC power, checked every 5 min, 1 attempt per 24 h. Reminders every 7 days (critical: 1 day). Marker 10 min, handshake 3 min, store wait 2 min. `hostUpdateBusy` retry 30 s. Sparkle check every 86 400 s. Migration backups 90 days | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3, §4, §5 |
| Logs | VM console 20 MiB × 5. Boot logs: last 5. Logcat: last 5. Crash snapshots: last 10. `apkrund.log` 10 MiB × 3. `perf/launches.jsonl` newest 2,000, `perf/boots.jsonl` newest 200 | [filesystem-layout.md](../01-architecture/filesystem-layout.md) §2 |
| launchd | `RunAtLoad` true, `StartInterval` 3600, `ExitTimeOut` 45 | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.1 |

---

## 7. Info.plist and bundle keys read at runtime

### 7.1 APKRun.app

| Key | Value | Read by | Reference |
|---|---|---|---|
| `CFBundleShortVersionString` | `MAJOR.MINOR.PATCH` | Settings → General, Sparkle, diagnostics | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1 |
| `CFBundleVersion` | the build number | Sparkle. BundleWatcher in apkrund reads it from the Info.plist on disk to detect a replaced bundle | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1, §3 |
| `CFBundleIdentifier` | `io.apkrun.APKRun` (`io.apkrun.APKRun.dev` in Debug) | the user defaults domain, the dev identities | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6 |
| `APKRunImageFeedBaseURL` | the base URL of the Android image feed (`<base>/<channel>/feed.json`). Set by the Release build, absent in Debug | `ImageFeedClient` in apkrund, read from the bundle apkrund lives in | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1 |
| `APKRunDownloadsURL` | the APKRun downloads page, `https://<updates host>/apkrun/download/` (the host is OQ-01). Set in every configuration: the page is only opened in the browser | the `openDownloadsPage` action in APKRun.app and APKRunMenuBar. The launcher template compiles the same value as `LauncherBuild.downloadURL` | [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.3, [../02-design/wrapper.md](../02-design/wrapper.md) §5.4 |
| Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, and others) | release values in the owner document. Debug builds have no `SUFeedURL` | Sparkle in APKRun.app | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 |

The user's choices for Sparkle come from `maintenance.*` (§2.6), not from Info.plist. `SUAutomaticallyUpdate` in Info.plist is only the first-launch default. APKRun.app overwrites it from settings at every launch.

### 7.2 Wrappers

`APKRunPackageID`, `APKRunWrapperFormat` (`1`), `APKRunWrapperKind` (`local`, `portable`, `distribution`), `APKRunLauncherVersion`, `APKRunLauncherAPI`, and the standard `CFBundle*` keys. The launcher reads them at start. WrapperCore reads them when it verifies a wrapper. They are defined in [../02-design/wrapper.md](../02-design/wrapper.md) §2.1.

### 7.3 LaunchAgent plist

`Contents/Library/LaunchAgents/io.apkrun.apkrund.plist` is read by launchd: `MachServices` (`io.apkrun.apkrund.xpc`), `RunAtLoad`, `StartInterval`, `ExitTimeOut`, `KeepAlive.SuccessfulExit = false` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.1). APKRun.app compares its hash with `registeredAgentPlistSHA256` to decide whether to register the agent again ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3, §9).

### 7.4 Bundle resources

| File | Content | Read by |
|---|---|---|
| `Resources/components.json` | version, build, channel, commit, `runtimeAPI`, `guestProtocol`, `agentPlistSHA256`, `dataSchemas`, pinned components | apkrund, APKRun.app, diagnostics ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1) |
| `Resources/compatibility.json` | the compatibility database, including `recommendedSettings` (§3.2) | apkrund ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10) |

Both are part of the signed bundle. Users cannot change them.

---

## 8. Validation

### 8.1 Changes through the API and the CLI

| Problem | API result | CLI |
|---|---|---|
| Unknown key (includes `graphics.limits.*` in release builds) | `RuntimeFailure.unknownSetting(key)` (global) or `StoreFailure.unknownSetting(key)` (package) | exit 4 |
| Wrong type, or a value outside the allowed values of §2 or §3 | `RuntimeFailure.invalidSettingValue(key, allowed)` or `StoreFailure.invalidSettingValue(key, allowed)` | exit 64, with the allowed values |
| A patch that contains `sharedFolders`, or `config set` / `config reset` of `sharedFolders.roots` | `RuntimeFailure.invalidSettingValue(key, allowed)`. The message names the shared-folder operations | exit 64: "Use apkrun shared-folders." |
| The owner is degraded (§8.3) | `RuntimeFailure.hostStartupFailed(step:)` | exit 69 |

- The whole patch is validated before anything is written. One bad key rejects the whole patch.
- Values that depend on the Mac (`runtime.cpuCount`, `runtime.memoryGiB`, `runtime.userdataGiB`) are checked against this Mac when they are set.
- CLI value syntax: `true`, `false`, `on`, `off` for bool. Enums by name. Decimal numbers ([../02-design/cli.md](../02-design/cli.md) §4.2).
- The cases are declared in `RuntimeFailure` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §11) and `StoreFailure` ([../02-design/package-store.md](../02-design/package-store.md) §12). [error-catalog.md](error-catalog.md) is the authority for codes, messages, and remediation. `sharedFolders` is a fixed variant of `runtime.invalidSettingValue`.

### 8.2 Loading a file at a supported schema

| Problem | Behavior |
|---|---|
| Older schema | migrated (§1.3) |
| Unknown key | ignored. A warning is logged once per load. The key is dropped at the next write |
| Invalid value | that key uses its default. An error is logged. The value is dropped at the next write |
| A Mac-dependent value out of range for this Mac | clamped when used. The file is not changed |
| Not valid JSON, or no `schemaVersion` | the file is renamed to `<name>.corrupt-<time>`, all keys use their defaults, and an error is logged. The next change writes a new file. This is the same rule as the wrapper registry ([../02-design/wrapper.md](../02-design/wrapper.md) §7.2, §13) |

Package settings follow the same rules, one package at a time. A problem in one package's file affects no other package.

### 8.3 Newer schema

This follows [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5:

- The owning component starts degraded with `maintenance.dataCreatedByNewerVersion(file, schema, supported)`: "This data was created by a newer version of APKRun. Install the latest version of APKRun."
- The file is never written: not by a migration, not by a change, not by a reset.
- Global `settings.json`: startup step 4 fails ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.2). apkrund still serves the broker. `runtimeStatus` returns `RuntimeFailure.hostStartupFailed(step:)`. `configuration()`, `updateConfiguration(patch)`, and every operation that needs settings (such as starting Android) return the same error.
- A package `settings.json`: only that package is affected. It is read-only with `store.metadataUnreadable`, as for a newer `metadata.json`, and the other packages work ([package-metadata-json.md](package-metadata-json.md) §4.2, [../02-design/package-store.md](../02-design/package-store.md) §5.4).
- apkrund never crash-loops on data it cannot read.
- A `wrapper.json` with a newer `formatVersion` follows [wrapper-json.md](wrapper-json.md) and [../02-design/wrapper.md](../02-design/wrapper.md) §2.
