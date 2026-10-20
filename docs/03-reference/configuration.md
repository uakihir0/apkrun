# Configuration Reference

This document lists every input that changes APKRun's behavior: global settings, per-package settings, wrapper defaults, environment variables, launch arguments, build constants, and plist keys. Design documents own the behavior; each entry links to them.

Keys use dots. **Applies** uses these values:

| Applies | Meaning |
|---|---|
| live | takes effect at once |
| next session | the next time the app's window opens. An open window keeps the old value |
| runtime restart | the next Android start. The UI offers **Restart Android Now** |
| next check | the next scheduled or manual check |
| next login | the next user login (apkrund `RunAtLoad`) |
| new packages | packages recorded after the change. Existing packages keep their values |
| provisioning | when the Android instance is created (first setup or **Reset Android**) |
| next boot | the next Android boot. A boot in progress keeps the old value |
| next health-check result | the next health-check result of an app update ([update-system.md](../02-design/update-system.md) §8) |
| next update | the next update of the app |

---

## 1. Where configuration lives

### 1.1 Files

| File | Holds | Only writer | Schema (`dataSchemas`) | Format |
|---|---|---|---|---|
| `~/Library/Application Support/APKRun/settings.json` | global settings (§2) | RuntimeHost in apkrund | `settings`, 2 | §1.2 |
| `Packages/<id>/settings.json` | per-package settings (§3) | APKStoreCore in apkrund | `packageSettings`, 1 | [package-metadata-json.md](package-metadata-json.md) §3 |
| `Packages/<id>/metadata.json` | update authority and provider. Written together with `update.mode` (§3.1) | APKStoreCore | `packageRecord`, 1 | [package-metadata-json.md](package-metadata-json.md) |
| `‹Wrapper›.app/Contents/Resources/wrapper.json` | initial values for a package (§4). Never rewritten | WrapperCore, once, at generation | `formatVersion` 1 | [wrapper-json.md](wrapper-json.md) |
| wrapper user defaults (bundle ID) | the window frame (`APKRunSessionWindow` autosave) | the wrapper (AppKit) | none | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.2 |

- Debug builds use `~/Library/Application Support/APKRun-Dev/` as the root ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6). `apkrun dev` uses `APKRUN_HOME` (§5.1) and owns those files while it holds the instance lock.
- Only apkrund writes settings files. Other processes change settings through RuntimeAPI (§1.4) and never read the files.
- Hand edits are not supported. apkrund reads a hand edit at the next start and validates it (§8.2). The next API change may overwrite it.
- Package settings survive updates, rollbacks, reinstalls, and Reset Android. They are deleted on uninstall unless app data is kept ([package-store.md](../02-design/package-store.md) §2.4, §8).

### 1.2 Storage form

- `settings.json` holds only keys that were set. An absent key has its default. `apkrun config reset <key>` removes the key.
- Dotted keys map to nested objects: `runtime.memoryGiB` is `{"runtime": {"memoryGiB": …}}`.
- A package's `settings.json` holds only explicit values: user values and values copied at the first record (§3.3). This lets the resolver tell a user value from a recommendation ([diagnostics.md](../02-design/diagnostics.md) §10.3). Schema: [package-metadata-json.md](package-metadata-json.md) §3.

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

- Each file has an integer `schemaVersion`. This build's values are in `components.json` `dataSchemas` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1).
- Older files migrate on load ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §5): keep the original as `<name>.v<old>.json` (one backup per old version, deleted 90 days after migration); migrate and validate in memory; write atomically with `FileManager.replaceItemAt`.
- A migration never changes what a value means.
- Adding a key raises the schema version, because an older build would drop the key on decode.
- Renaming or removing a key is a migration step.
- A file with a newer schema is handled per §8.3.

### 1.4 Reading and writing through RuntimeAPI

Signatures are in [runtime-api.md](runtime-api.md) §14, the authority for them.

| Operation | Endpoint | Behavior |
|---|---|---|
| `configuration()` → `ConfigurationSnapshot` | control | every key of §2 with effective value, default, whether set, and when a change applies |
| `updateConfiguration(patch)` | control | RFC 7396 merge patch on the nested form (§1.2). `null` resets a key. The whole patch is validated first (§8.1). A patch with `sharedFolders` is refused |
| `sharedFolders()`, `addSharedFolder`, `removeSharedFolder`, `setSharedFolderAccess` | control | the only way to change `sharedFolders.roots` ([desktop-integration.md](../02-design/desktop-integration.md) §6.4) |
| `packageSettings(id)` → `ResolvedPackageSettings` | control | every key of §3 with effective value and source: `globalSwitch`, `user`, `recommended`, or `default` (§3.2) |
| `updatePackageSettings(id, patch)` | control | validated merge patch on package settings ([package-store.md](../02-design/package-store.md) §11.1). `null` removes the user value |
| `setUpdatePolicy(id, UpdatePolicy)` | control | writes authority, provider, and `update.mode` together ([update-system.md](../02-design/update-system.md) §2.3) |
| `SessionDescriptor.windowPrefs`, `windowPrefsChanged` | wrapper | own package only: `resizable`, `alwaysOnTop`, `zoom` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3) |

- Wrapper endpoints read the resolved `window.*` and `input.*` values of their own package. Their only write is `window.zoom`, through `resize` ([runtime-api.md](runtime-api.md) §14.3).
- Every accepted change is written before the reply. The owner writes a temporary file in the same directory, calls `fcntl(F_BARRIERFSYNC)`, and renames it over the old file. `F_FULLFSYNC` is not used. Writes are not coalesced.
- A no-op patch writes nothing and posts no event. Setting a key to its default stores it, so an explicit value beats a recommendation (§3.2).

### 1.5 Change notification

| Event | Topic | Posted when |
|---|---|---|
| `configurationChanged(keys: [String])` | `runtime` | global keys changed (dotted keys) |
| `settingsChanged(PackageID, keys: [String])` | `packages` | package keys changed ([package-store.md](../02-design/package-store.md) §11.3) |
| `sharedFoldersChanged` | `integrations` | a shared folder root was added, removed, or changed |
| `windowPrefsChanged(WindowPrefs)` | session channel | `window.resizable`, `window.alwaysOnTop`, or `window.zoom` changed |

- Consumers read the current value after the event and never cache across it ([package-store.md](../02-design/package-store.md) §2.4).
- Components inside apkrund (IdleController, UpdateScheduler, IntegrationPolicy, DisplayPool, ImageUpdateCoordinator) receive the change in process.
- APKRun.app applies the Sparkle settings at launch and on each `configurationChanged` that contains a `maintenance.*` key ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2).

### 1.6 What is not a setting

| Item | Where it lives |
|---|---|
| menu bar item | APKRunMenuBar's login item registration (`SMAppService`). No key ([host-ui.md](../02-design/host-ui.md) §9.1) |
| `lastLaunchedBuild`, `registeredAgentPlistSHA256` | APKRun.app user defaults `io.apkrun.APKRun`. Bookkeeping ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §9) |
| update authority, source, provider | package record `metadata.json` ([update-system.md](../02-design/update-system.md) §2) |
| provider tokens | Keychain, service `io.apkrun.provider.github` ([update-system.md](../02-design/update-system.md) §4.6) |
| denied wrappers | `Wrappers/registry.json` ([wrapper.md](../02-design/wrapper.md) §7.3) |
| debug logging in release builds | `log config` (macOS), not an APKRun key ([diagnostics.md](../02-design/diagnostics.md) §3) |

### 1.7 Diagnostics

- The diagnostics bundle contains `config.json` (global settings) and each package's `settings.json` ([diagnostics.md](../02-design/diagnostics.md) §6.2).
- Every key of §2 and §3 is on the allowlist and copied as is.
- `sharedFolders.roots` is reduced to a count and the last path component of each root. Bookmarks are never copied.
- `apkrun config list --json` has the same content as `configuration()`.

---

## 2. Global settings

Stored in `settings.json` (§1.1). The **UI** column names the tab in APKRun Settings ([host-ui.md](../02-design/host-ui.md) §9). The CLI form for every key is `apkrun config get | set | reset <key>` ([cli.md](../02-design/cli.md) §4.6).

### 2.1 `runtime.*`

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `runtime.startPolicy` | enum | `onDemand`, `atLogin` | `onDemand` | next login | Runtime: "Start Android" | [runtime-daemon.md](../02-design/runtime-daemon.md) §5.4 |
| `runtime.idleSuspendMinutes` | integer | 0–1440; `0` = never | `10` | live | Runtime: "Put Android to sleep after ‹n› minutes without apps" | [runtime-daemon.md](../02-design/runtime-daemon.md) §5.2 |
| `runtime.idleStopMinutes` | integer | 0–1440; `0` = never | `60` | live | Runtime: "Stop Android after ‹n› minutes" | [runtime-daemon.md](../02-design/runtime-daemon.md) §5.2 |
| `runtime.autoRestart` | bool | `true`, `false` | `true` | live | Runtime: "Restart Android automatically after a crash" | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.6 |
| `runtime.cpuCount` | integer | 2 … min(8, performance + efficiency cores) | `4` | runtime restart | Runtime: "Memory, processors" | [vm.md](../02-design/vm.md) §10 |
| `runtime.memoryGiB` | integer (GiB) | 3 … 50 % of physical memory, rounded down | `4`, lowered to fit 50 % | runtime restart | Runtime: "Memory, processors" | [vm.md](../02-design/vm.md) §10, [runtime-daemon.md](../02-design/runtime-daemon.md) §12 |
| `runtime.userdataGiB` | integer (GiB) | 8–256; at provisioning at most the free space minus 10 GiB | `32` | provisioning | Runtime: "Android storage" (not yet in host-ui.md) | [android-image.md](../02-design/android-image.md) §5.2 |
| `runtime.bootTimeoutSeconds` | integer | 120–1800 | `180` | next boot | none | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |
| `runtime.firstBootTimeoutSeconds` | integer | 600–3600 | `900` | next boot | none | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |

- `runtime.idleStopMinutes` counts from when idleness began, including suspended time. A value below `runtime.idleSuspendMinutes` means stop without suspending. A change does not reset the idle clock ([runtime-daemon.md](../02-design/runtime-daemon.md) §5.2).
- `runtime.startPolicy = atLogin` preboots 60 s after login. Preboot is skipped on battery below 30 % and while the boot-loop guard is active ([runtime-daemon.md](../02-design/runtime-daemon.md) §5.4).
- `cpuCount`, `memoryGiB`, and `userdataGiB` depend on the Mac. `set` checks them against this Mac. A stored value that no longer fits is clamped when used; the file is not changed (§8.2).
- `userdataGiB` is fixed at provisioning. A change takes effect only with **Reset Android**, which deletes Android data. `config set` prints "Applies after Reset Android."
- The two boot timeouts have no UI. They are for slow Macs and testing.

### 2.2 `display.*`

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `display.maxSessions` | integer | 1–15 | `8` | live; checked when a session opens. Open sessions stay open when lowered | Runtime: "Maximum open apps" | [display-and-windowing.md](../02-design/display-and-windowing.md) §2 |

System sessions (for example the update health check, at most 90 s) do not count. A session beyond the limit fails with `RuntimeFailure.displayPoolExhausted`.

### 2.3 `graphics.*`

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `graphics.safeMode` | bool | `true`, `false` | `false` | runtime restart | Troubleshooting: **Start in Graphics Safe Mode** | [graphics.md](../02-design/graphics.md) §9 |
| `graphics.limits.*` | integer | see below; development builds only | see below | runtime restart | none | [graphics.md](../02-design/graphics.md) §5.4 |

- `graphics.safeMode = true` boots with the `guestSwiftshader` profile instead of `drmVirgl` (`BootOptions.gpuProfile`, [android-image.md](../02-design/android-image.md) §9.1). There is no automatic fallback. While on, the health check `graphics.safeMode` warns: "Graphics safe mode is on. Apps are slower."

Development-only limits. Release builds treat them as unknown keys (§8.1).

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

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `audio.output` | bool | `true`, `false` | `true` | runtime restart | Runtime: "Sound output" | [desktop-integration.md](../02-design/desktop-integration.md) §8.1, [vm.md](../02-design/vm.md) §11 |

The microphone is not a global key. It follows the per-package `integrations.microphone` values (§3.1).

### 2.5 `developer.*`

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `developer.enabled` | bool | `true`, `false` | `false` | runtime restart for ADB and logcat capture; live for UI items | Advanced: **Developer mode** (asks for confirmation) | [android-image.md](../02-design/android-image.md) §11.3, [security-model.md](../01-architecture/security-model.md) |

- At the next Android start it sets `androidboot.apkrun.devmode=1`: ADB listens on host loopback `127.0.0.1:6520`, and logcat is captured ([filesystem-layout.md](../01-architecture/filesystem-layout.md) §2).
- At once it shows LocalProvider ([update-system.md](../02-design/update-system.md) §4.3) and the frame statistics overlay ([display-and-windowing.md](../02-design/display-and-windowing.md) §7.7).
- The header and menu bar show "Developer mode" while the key is on, or while running Android still has ADB on.
- Health check `agent.developerMode` fails when ADB is on while the key is off.
- `config set developer.enabled true` asks `Continue? [y/N]`; `--yes` skips the question. Without a terminal and without `--yes` it fails with `cli.confirmationRequired` ([cli.md](../02-design/cli.md) §3.4).

### 2.6 `maintenance.*` (APKRun and Android system updates)

Meanings: [runtime-maintenance.md](../02-design/runtime-maintenance.md) §6.

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `maintenance.checkAutomatically` | bool | `true`, `false` | `true` | live | General: "Check for updates automatically" | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §6 |
| `maintenance.channel` | enum | `stable`, `beta` | `stable` | live; starts an Android system update check at once | General: channel | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4, §6 |
| `maintenance.installAPKRunAutomatically` | bool | `true`, `false` | `false` | live | General: "Install APKRun updates automatically" | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.5.1, §6 |
| `maintenance.downloadImagesAutomatically` | bool | `true`, `false` | `true` | next check | General: "Download Android system updates in the background" | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.4 |
| `maintenance.installImages` | enum | `automatic`, `ask` | `automatic` | live; used at the next idle-gate evaluation (every 5 min) | General: **Install automatically when the Mac is idle** / **Ask before installing** | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.6 |
| `maintenance.notifyImageInstalled` | bool | `true`, `false` | `false` | live | General: "Notify me when Android was updated" | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §6, §7.1 |

- Sparkle gets its settings from these keys: `automaticallyChecksForUpdates` from `maintenance.checkAutomatically`, and `automaticallyDownloadsUpdates` from `maintenance.installAPKRunAutomatically`. `allowedChannels` is `["beta"]` on the beta channel ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2).
- Switching from `beta` to `stable` never downgrades APKRun or Android.

### 2.7 `updates.*` (Android app updates)

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `updates.checkIntervalHours` | integer | `1`, `3`, `6`, `12`, `24`, `72`, `168` | `6` | next check; each package's next check is recomputed from its last check | Updates: check interval | [update-system.md](../02-design/update-system.md) §3.2 |
| `updates.downloadOnExpensiveNetwork` | bool | `true`, `false` | `false` | live; waiting downloads start when turned on | Updates: "Download on expensive networks" | [update-system.md](../02-design/update-system.md) §3.4 |
| `updates.startRuntimeToInstall` | bool | `true`, `false` | `false` | live | Updates: "Start Android to install updates" | [update-system.md](../02-design/update-system.md) §3.5 |
| `updates.notifyInstalled` | bool | `true`, `false` | `false` | live | Updates: "Notify me after automatic updates" | [update-system.md](../02-design/update-system.md) §9 |

### 2.8 `integrations.*` and `sharedFolders.*`

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `integrations.enabled.clipboard`, `.notifications`, `.links`, `.files`, `.sharedFolders`, `.microphone` | bool | `true`, `false` | `true` | live | Privacy: global switches | [desktop-integration.md](../02-design/desktop-integration.md) §2.2 |
| `integrations.defaults.clipboard`, `.notifications`, `.files` | bool | `true`, `false` | `true` | new packages | Privacy: defaults for new apps | [desktop-integration.md](../02-design/desktop-integration.md) §2.2 |
| `integrations.defaults.links` | enum | `ask`, `mac`, `android` | `ask` | new packages | same | same |
| `integrations.defaults.sharedFolders` | enum | `off`, `readOnly`, `readWrite` | `off` | new packages | same | same |
| `integrations.defaults.microphone` | bool | `true`, `false` | `false` | new packages | same | same |
| `sharedFolders.roots` | list of `{id, bookmark, access}` | `access`: `readOnly`, `readWrite`; at most 32 added folders | empty (only the built-in Shared folder) | live | Files: the folder list | [desktop-integration.md](../02-design/desktop-integration.md) §6.4 |

- `integrations.enabled.<name> = false` turns the integration off for every package. It changes no package's settings (§3.2).
- `integrations.defaults.*` are copied into a package's settings at its first record (§3.3). `wrapper.json` values win for packages installed from a portable wrapper, within the cap of §3.3.
- `sharedFolders.roots`: `id` is a UUID string; `bookmark` is base64 security-scoped bookmark data, so moved and renamed folders are followed; `access` is the maximum.
- The APKRun Shared folder (`~/Library/Application Support/APKRun/Shared/`) is built in, not stored, always first, `readWrite`, and cannot be removed.
- `apkrun shared-folders add` without `--read-write` adds `readOnly`. `config reset --all` does not touch `sharedFolders.roots`.

### 2.9 `system.*`

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `system.syncLocale` | bool | `true`, `false` | `true` | live; pushed to a running Android and at every boot | Language & Region: "Use the Mac's language in Android" | [desktop-integration.md](../02-design/desktop-integration.md) §9 |
| `system.syncTimeZone` | bool | `true`, `false` | `true` | as above | Language & Region: "Use the Mac's time zone" | same |
| `system.syncClockFormat` | bool | `true`, `false` | `true` | as above | Language & Region: "Use the Mac's 12/24-hour setting" | same |

### 2.10 `wrappers.*` and the menu bar item

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `wrappers.defaultLocation` | enum | `userApplications` (`~/Applications`), `allUsersApplications` (`/Applications`), `ask` | `userApplications` | live (the next add flow) | General: "Default location for new Mac apps" | [host-ui.md](../02-design/host-ui.md) §6, §9.1, [wrapper.md](../02-design/wrapper.md) §6.3 |

- The add flow's location pop-up starts at this value. `ask` shows the pop-up with no preselected folder.
- `allUsersApplications` is offered only to administrators. For a non-administrator it acts as `ask`.
- The CLI does not use this key. `apkrun wrap --output` defaults to `~/Applications` ([wrapper.md](../02-design/wrapper.md) §12.2).
- **Show APKRun in the menu bar** has no key. It shows and changes the APKRunMenuBar login item registration (`SMAppService.loginItem(identifier:)`). It is on by default; removing the login item in System Settings makes it show off. It is not in `apkrun config`.

---

## 3. Per-package settings

Stored in `Packages/<id>/settings.json` ([package-metadata-json.md](package-metadata-json.md) §3, which wins on any difference). The **UI** column names the app page section ([host-ui.md](../02-design/host-ui.md) §7). The CLI form is `apkrun settings <package> get | set | reset <key>` ([cli.md](../02-design/cli.md) §4.2).

### 3.1 Keys

`window.*`:

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `window.mode` | enum | `secondaryDisplay`, `primaryDisplayCompatibility` | `secondaryDisplay` | next session | Window: **Standard** / **Compatibility** | [display-and-windowing.md](../02-design/display-and-windowing.md) §8 |
| `window.defaultWidth` | integer (pt) | ≥ 320 | `480`, or `850` when the launcher activity requests landscape | next session | Window: default size, **Use Current Size** | [display-and-windowing.md](../02-design/display-and-windowing.md) §6.2 |
| `window.defaultHeight` | integer (pt) | ≥ 400 | `850`, or `480` in landscape | next session | same | same |
| `window.resizable` | bool | `true`, `false` | `true` (`false` with fallback B) | live | Window: "Resizable" | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.1 |
| `window.alwaysOnTop` | bool | `true`, `false` | `false` | live | Window: "Always on top" | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.7 |
| `window.zoom` | number | 0.75–2.0 | `1.0` | live (next session with fallback B) | Window: 75 %–200 %; View → Zoom In, Zoom Out, Actual Size | [display-and-windowing.md](../02-design/display-and-windowing.md) §6.1 |
| `window.closeBehavior` | enum | `stop`, `keepRunning` | `stop` | live; read when the window closes | Window: **Quit the app** / **Keep it running in the background** | [display-and-windowing.md](../02-design/display-and-windowing.md) §7.6 |

- The default size is clamped when used: to 90 % of the screen's visible frame, and to the 4095 px backing limit. A saved window frame (`APKRunSessionWindow`) wins over the default ([display-and-windowing.md](../02-design/display-and-windowing.md) §6.2, §7.2).

`input.*` ([host-ui.md](../02-design/host-ui.md) §7.3, [input.md](../02-design/input.md)):

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `input.escapeKey` | enum | `back`, `escape` | `back` | next session | Input: "Esc key" | [input.md](../02-design/input.md) §5.2 |
| `input.secondaryClick` | enum | `mouseSecondary`, `longPress` | `mouseSecondary` | next session | Input: "Right click" | [input.md](../02-design/input.md) §4.3 |
| `input.scrollMode` | enum | `scroll`, `touchDrag` | `scroll` | next session | Input: "Scrolling" | [input.md](../02-design/input.md) §4.4 |
| `input.hover` | bool | `true`, `false` | `true` | next session | Input: "Mouse hover" | [input.md](../02-design/input.md) §4.1 |
| `input.sendCommandKey` | bool | `true`, `false` | `false` | next session | Input: "Send the Command key to the app" | [input.md](../02-design/input.md) §5.2 |

Input is translated in the wrapper process, and `WindowPrefs` carries no input keys, so input keys apply at the next session.

`integrations.*` ([desktop-integration.md](../02-design/desktop-integration.md) §2.1):

| Key | Type | Allowed values | Default | Applies | UI | Design |
|---|---|---|---|---|---|---|
| `integrations.clipboard` | bool | `true`, `false` | `true` | live | Integrations: Clipboard | [desktop-integration.md](../02-design/desktop-integration.md) §4 |
| `integrations.notifications` | bool | `true`, `false` | `true` | live | Integrations: Notifications | [desktop-integration.md](../02-design/desktop-integration.md) §5 |
| `integrations.links` | enum | `ask`, `mac`, `android` | `ask` | live | Integrations: Links (**Ask** / **Open in Mac browser** / **Open in Android**) | [desktop-integration.md](../02-design/desktop-integration.md) §7 |
| `integrations.files` | bool | `true`, `false` | `true` | live | Integrations: Files | [desktop-integration.md](../02-design/desktop-integration.md) §6.2, §6.3 |
| `integrations.sharedFolders` | enum | `off`, `readOnly`, `readWrite` | `off` | live | Integrations: Shared folders (**Off** / **Read only** / **Read and write**) | [desktop-integration.md](../02-design/desktop-integration.md) §6.4 |
| `integrations.microphone` | bool | `true`, `false` | `false` | live, see below | Integrations: Microphone | [desktop-integration.md](../02-design/desktop-integration.md) §8.2 |

- IntegrationPolicy reads the settings at each evaluation and pushes only changes to the Guest Agent ([desktop-integration.md](../02-design/desktop-integration.md) §2.3, §3.2).
- The microphone device is attached only while at least one package has `integrations.microphone` on. Turning it on for the first package, or off for the last, needs a runtime restart: **Restart Android Now** / **Later** ([host-ui.md](../02-design/host-ui.md) §7.4).
- Camera is not supported in v1 and has no key.

`update.*` ([update-system.md](../02-design/update-system.md)):

| Key | Type | Allowed values | Default | Applies | UI | CLI | Design |
|---|---|---|---|---|---|---|---|
| `update.mode` | enum | `automatic`, `notifyOnly` | `automatic` | next check | Updates: **Automatic** / **Notify only** / **Manual** | `apkrun update policy <package> --mode automatic\|notify\|manual` (or `settings`) | [update-system.md](../02-design/update-system.md) §2.2, §2.3 |
| `update.autoRollback` | bool | `true`, `false` | `true` | at the next health-check result | Updates: "Undo updates that fail to start" | `settings` | [update-system.md](../02-design/update-system.md) §8.3 |
| `update.healthCheckLaunch` | bool | `true`, `false` | `true` | next update | Updates: "Open the app briefly after updating to check it" | `settings` | [update-system.md](../02-design/update-system.md) §8.1 |

- **Manual** is the authority `manual` in the package record, not a mode. `update.mode` has an effect only while the authority is `apkrun` ([update-system.md](../02-design/update-system.md) §2.1–§2.3).
- The UI and `apkrun update policy` use `setUpdatePolicy`, which writes authority, provider, and `update.mode` together. `apkrun settings set update.mode` changes only the mode, is stored while the authority is `manual`, and takes effect when the authority returns to `apkrun`.
- `update.healthCheckLaunch = false` limits the health check to `versionOnly` ([update-system.md](../02-design/update-system.md) §8.1).

### 3.2 Precedence

`PackageSettingsResolver` returns each key's effective value. The first matching rule wins:

| Order | Source | Notes |
|---|---|---|
| 1 | global switch `integrations.enabled.<name> = false` | forces the integration off. The stored value is kept |
| 2 | the value in the package's `settings.json` | a user value, or a value copied at the first record (§3.3) |
| 3 | compatibility database recommendation for the installed version | only `window.*`, `input.*`, `integrations.*` (only to turn one off), and `update.healthCheckLaunch` ([diagnostics.md](../02-design/diagnostics.md) §10.3) |
| 4 | built-in default of §3.1 | |

- Recommendations are never written to `settings.json`. The UI marks them "Recommended for this app".
- **Reset** (`apkrun settings <package> reset <key>`, or `null`) removes the stored value. The effective value falls back to rule 3 or 4.
- Effective shared-folder access is the lower of the root's maximum and the package's `integrations.sharedFolders` ([desktop-integration.md](../02-design/desktop-integration.md) §6.4).
- Packages that APKRun does not manage use the built-in defaults, with `integrations.notifications` off ([desktop-integration.md](../02-design/desktop-integration.md) §2.3).
- Global settings do not override package values, except the rule 1 switches. There are no global window or input defaults in v1. `integrations.defaults.*` act only at the first record.

### 3.3 Values written at the first record

The store writes initial settings when it creates a package record: at install and import, at a bootstrap import, and at approval of a wrapper whose package has no settings ([wrapper.md](../02-design/wrapper.md) §3). For each key, the first source with a value wins:

1. The flags of the installing command: `apkrun wrap … --window-size <w>x<h>`, `--resizable` or `--no-resizable`, `--updates automatic|notify|manual` ([wrapper.md](../02-design/wrapper.md) §12.2).
2. `wrapper.json` (§4).
3. `integrations.defaults.*`, for integration keys only.

- A value equal to the built-in default is not written, so a later recommendation can still apply.
- `--updates` and `wrapper.json` `updates.authority` and `updates.provider` go to the package record ([update-system.md](../02-design/update-system.md) §2.4). The mode goes to `update.mode`.
- After the first record, only user changes write settings. `wrapper.json` is not read again for settings.
- **Cap for wrappers from elsewhere.** A wrapper that this Mac did not generate (registry `approval: user`: portable, distribution, or copied from another Mac, [wrapper.md](../02-design/wrapper.md) §7.3) cannot grant more than this Mac's defaults. For each integration key, its value is used only if it is not more permissive than `integrations.defaults.<key>`; otherwise the default is written. Order: `false` < `true`; `off` < `readOnly` < `readWrite`; `android` < `ask` < `mac`. Such a wrapper can turn an integration off or down, never on or up. The approval dialog lists the integrations the app gets.

---

## 4. Defaults from `wrapper.json`

Schema and validation: [wrapper-json.md](wrapper-json.md). This section only maps values to keys.

| `wrapper.json` | Becomes | Notes |
|---|---|---|
| `window.mode`: `standard`, `compatibility` | `window.mode`: `secondaryDisplay`, `primaryDisplayCompatibility` | [wrapper.md](../02-design/wrapper.md) §3 |
| `window.defaultWidth`, `window.defaultHeight`, `window.resizable` | the same keys | |
| `updates.mode` | `update.mode` | [update-system.md](../02-design/update-system.md) §2.4 |
| `updates.authority`, `updates.provider` | the package record, not settings | [update-system.md](../02-design/update-system.md) §2.4 |
| `integration.<key>` (no prefix) | `integrations.<key>` | absent keys get `integrations.defaults.*`. Unknown keys are ignored |
| `application.*`, `runtime.*`, `formatVersion`, `kind` | identity and launcher compatibility, not settings | `runtime.minimumVersion` is `LauncherBuild.minimumRuntimeVersion` |

- Values are initial only (§3.3). Only portable and distribution wrappers provide them. A local wrapper is generated for a package that already has a record.
- A value not allowed for its key in §3.1 is treated as absent and logged. Other keys still apply.

---

## 5. Environment variables and launch arguments

### 5.1 Environment variables

| Variable | Read by | Effect | Builds that honor it | Test only |
|---|---|---|---|---|
| `NO_COLOR` | `apkrun` | no color in output (like `--no-color`) | all | no |
| `APKRUN_HOME` | `APKRunPaths` in `apkrun dev`, debug apkrund, test hosts | relocates the data root ([filesystem-layout.md](../01-architecture/filesystem-layout.md)) | debug only; release ignores it | development and tests |
| `APKRUN_LOG_LEVEL` | `apkrun dev` | `debug` or `info` for the in-process runtime | debug only | development |
| `APKRUN_STORE_FAULT=<kind>:<step>` | APKStoreCore | injects a store fault | debug only | yes |
| `APKRUN_GRAPHICS_FAULT=rendererInit` | graphics host | makes renderer initialization fail | debug only | yes |
| `APKRUN_RUNTIME_FAULT=rejectAgent:guest` | RuntimeCore | rejects the Guest Agent handshake | debug only | yes |
| `APKRUN_LAUNCHER_TEST_NO_RUNTIME=1` | APKRunLauncher | runs the launcher without a runtime | debug only | yes |
| `APKRUN_TEST_HEADLESS_LAUNCH=1` | apkrund | `launch` opens a daemon-owned session that discards its frames. Removed by #068 | debug only | yes |
| `APKRUN_TEST_MARKER_TIMEOUT=<n>s` or `<n>m` | MaintenanceService | replaces the 10-minute maintenance marker timeout | Debug and `ReleaseUpdateTest`; shipped Release ignores it | yes |
| `APKRUN_TEST_INSTALL_CHOICE=closeApps\|whenClosed` | `TestUserDriver` in APKRun.app | answers the install dialog in maintenance tests | `ReleaseUpdateTest` only | yes |
| `APKRUN_TEST_IMAGE_FEED_URL=<url>` | `ImageFeedClient` | replaces the image feed base URL (may be `http://127.0.0.1`) | debug only | yes |
| `APKRUN_TEST_IDLE_SECONDS=<n>` | image apply gate | replaces the idle time read from `HIDIdleTime` | debug only | yes |
| `APKRUN_TEST_POWER=ac\|battery:<percent>` | image apply gate | replaces the power source read from IOKit | debug only | yes |
| `APKRUN_ANDROID_BUILD_API_KEY` | Android image fetch tool | API key for build downloads | build machines only; not read by the product | build tooling |

References: [cli.md](../02-design/cli.md) §3.6, [package-store.md](../02-design/package-store.md), [diagnostics.md](../02-design/diagnostics.md) §12, [wrapper.md](../02-design/wrapper.md), [runtime-maintenance.md](../02-design/runtime-maintenance.md) §14, [android-image.md](../02-design/android-image.md) §2.2.

### 5.2 Launch arguments and URLs

| Process | Argument or URL | Effect | Reference |
|---|---|---|---|
| APKRun.app | none | normal start; onboarding opens if setup is incomplete | [host-ui.md](../02-design/host-ui.md) §3.3 |
| APKRun.app | `--notify` | started by apkrund to post notifications. No window; quits 30 s after the last notification | [host-ui.md](../02-design/host-ui.md) §3.3 |
| APKRun.app | `--approve` | started by apkrund for a wrapper approval; shows only the approval window | [host-ui.md](../02-design/host-ui.md) §3.3 |
| APKRun.app | `--register-runtime` | registers the apkrund LaunchAgent, then quits | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.6, [cli.md](../02-design/cli.md) §4.1 |
| APKRun.app | `--test-check-for-updates` | starts a user-initiated Sparkle check (`ReleaseUpdateTest` only) | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 |
| APKRunLauncher | `--package <id>` | the generic launcher opens that package | [runtime-daemon.md](../02-design/runtime-daemon.md) §7.2 |
| a wrapper | `--apkrun-background notifications` | starts in the background to deliver notifications | [wrapper.md](../02-design/wrapper.md) §5.8 |
| `apkrun` | `--json`, `--yes`, `--no-color`, `--detach` | output and confirmation flags | [cli.md](../02-design/cli.md) §3 |
| APKRun.app | `apkrun://settings/<pane>` | opens Settings at `general`, `runtime`, `updates`, `privacy`, `files`, `language`, `storage`, `troubleshooting`, or `advanced` | [host-ui.md](../02-design/host-ui.md) §3.1 |
| APKRun.app | `apkrun://package/<packageId>/<section>` | opens the app page at `general`, `window`, `input`, `integrations`, `updates`, `mac-app`, or `storage` | [host-ui.md](../02-design/host-ui.md) §3.1 |

### 5.3 Boot parameters

| Parameter | Set from | Builds | Reference |
|---|---|---|---|
| `androidboot.apkrun.devmode=0\|1` | `developer.enabled`, at every boot | custom image | [android-image.md](../02-design/android-image.md) §6.2, §11.3 |
| GPU profile (`drmVirgl` or `guestSwiftshader`) | `graphics.safeMode`, at every boot | all | [graphics.md](../02-design/graphics.md) §9 |
| `androidboot.apkrun.test.*` (`marker=<value>`, `fail_health=1`, `fail_boot=1`) | test harness | test image bundles only; a CI check keeps them out of release manifests | [android-image.md](../02-design/android-image.md) §6.2 |
| `apkrun.test=…`, `apkrun.test.poweroff=1` | test harness | Linux test guest only | [vm.md](../02-design/vm.md) §12 |

---

## 6. Build-time configuration and limits

### 6.1 Build configurations

| Configuration | What changes | Reference |
|---|---|---|
| Debug | `.dev` identities (`io.apkrun.APKRun.dev`, `io.apkrun.apkrund.dev`, `io.apkrun.apkrund.dev.xpc`); `APKRun-Dev` data roots; no `SUFeedURL`; `APKRUN_EMBEDDED_RUNTIME` compiles `apkrun dev`. Debug-only variables of §5.1 and `graphics.limits.*` are honored | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.6, [cli.md](../02-design/cli.md) §5 |
| Release | shipped build: Developer ID signed, notarized, with the Sparkle feed of [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 |
| `ReleaseUpdateTest` | release code; `SUFeedURL` points at the local appcast server; test key `Tests/Fixtures/signing/test-sparkle-ed25519.pub`; signed, not notarized; honors `APKRUN_TEST_MARKER_TIMEOUT`; trusts the build machine's development image key as well ([android-image.md](../02-design/android-image.md) §10.1) | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 |

### 6.2 Limits and constants

These values are compiled in, not settings. The owning document wins on any difference.

| Area | Constants | Owner |
|---|---|---|
| apkrund | exit grace 2 min; crash loop: 3 unclean exits in 10 min; at most 64 requests in flight per connection and 8 control connections; wrapper endpoint dropped 10 min after its last connection | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.4, §2.5, §8.2 |
| Boot | stall 90 s (first boot 600 s); agent handshake 30 s; boot-loop guard 3 failures in 10 min; automatic restart: one cold boot, not retried within 10 min; graceful stop up to 40 s | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2, §3.5, §3.6 |
| Host | at least 8 GiB physical memory; reset recovery point kept 7 days | [runtime-daemon.md](../02-design/runtime-daemon.md) §9.5, §12 |
| Display | 15 slots; system sessions at most 90 s; minimum content 320 × 400 dp × zoom; density 120–640 dpi; backing at most 4095 px; close timeout 5 s | [display-and-windowing.md](../02-design/display-and-windowing.md) §2, §6.2, §7.6 |
| Graphics | defaults of `graphics.limits.*` (§2.3) | [graphics.md](../02-design/graphics.md) §5.4 |
| Clipboard | text 1 MiB; HTML 1 MiB; image 16 MiB and 8192 px | [desktop-integration.md](../02-design/desktop-integration.md) §4.4 |
| Files | drops: at most 20 files, 2 GiB each, 4 GiB total; shared folders: 4096 entries per page, 1 MiB per read or write, 64 open handles per package | [desktop-integration.md](../02-design/desktop-integration.md) §6 |
| Links | at most 8 KiB, 3 per 10 s; prompt timeout 60 s | [desktop-integration.md](../02-design/desktop-integration.md) §7 |
| Notifications | 50 per 10 s; title 256 and text 2048 characters; 32 categories (LRU) | [desktop-integration.md](../02-design/desktop-integration.md) §5 |
| Package store | import space 2 × source + 2 GiB; staging set size + 2 GiB; extraction 2 GiB per file, 8 GiB total; aapt2 20 s and 16 MiB; journal compaction at 1 MiB; host space warning below 5 GiB, refusal below 2 GiB; `incoming/` kept 24 h; `failed/` kept 7 days | [package-store.md](../02-design/package-store.md) §3.4 |
| App updates | jitter ±10 %; backoff 30 min, 2 h; 4 parallel checks, 2 per host, 1 background download; Low Power Mode holds downloads over 50 MiB; background install after 24 h waiting, on AC power, idle 15 min; health budget 90 s; download cap 8 GiB; parser caps: manifest 1 MiB, release JSON 4 MiB, index 64 MiB, notes 16 KiB; gentle wait 7 days; history 365 days or 5 000 lines | [update-system.md](../02-design/update-system.md) §3, §7, §8, §10 |
| APKRun and Android system updates | probe every 24 h ± 1 h, 30 s, 2 MiB; image feed 1 MiB, signature 4 KiB, expiry 30 days; check backoff 1 h, 6 h, then daily; check on app open at most every 6 h; download retries 15 min, 1 h, 6 h; free space: archive + expanded + 10 GiB; idle gate: idle 10 min, AC power, checked every 5 min, 1 attempt per 24 h; reminders every 7 days (critical: 1 day); marker 10 min, handshake 3 min, store wait 2 min; `hostUpdateBusy` retry 30 s; Sparkle check every 86 400 s; migration backups 90 days | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3, §4, §5 |
| Logs | VM console 20 MiB × 5; boot logs last 5; logcat last 5; crash snapshots last 10; `apkrund.log` 10 MiB × 3; `perf/launches.jsonl` newest 2,000; `perf/boots.jsonl` newest 200 | [filesystem-layout.md](../01-architecture/filesystem-layout.md) §2 |
| launchd | `RunAtLoad` true; `StartInterval` 3600; `ExitTimeOut` 45 | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.1 |

---

## 7. Info.plist and bundle keys read at runtime

### 7.1 APKRun.app

| Key | Value | Read by | Reference |
|---|---|---|---|
| `CFBundleShortVersionString` | `MAJOR.MINOR.PATCH` | Settings → General, Sparkle, diagnostics | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1 |
| `CFBundleVersion` | build number | Sparkle; BundleWatcher in apkrund reads it from the Info.plist on disk to detect a replaced bundle | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1, §3 |
| `CFBundleIdentifier` | `io.apkrun.APKRun` (`.dev` in Debug) | user defaults domain; dev identities | [runtime-daemon.md](../02-design/runtime-daemon.md) §2.6 |
| `APKRunImageFeedBaseURL` | base URL of the Android image feed (`<base>/<channel>/feed.json`); set by Release, absent in Debug | `ImageFeedClient` in apkrund | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1 |
| `APKRunDownloadsURL` | APKRun downloads page, `https://<updates host>/apkrun/download/` (host is OQ-01); set in every configuration | `openDownloadsPage` in APKRun.app and APKRunMenuBar; the launcher template compiles the same value as `LauncherBuild.downloadURL` | [diagnostics.md](../02-design/diagnostics.md) §2.3, [wrapper.md](../02-design/wrapper.md) §5.4 |
| Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, others) | release values in the owner document; Debug has no `SUFeedURL` | Sparkle in APKRun.app | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 |

The user's Sparkle choices come from `maintenance.*` (§2.6), not Info.plist. `SUAutomaticallyUpdate` in Info.plist is only the first-launch default; APKRun.app overwrites it from settings at every launch.

### 7.2 Wrappers

`APKRunPackageID`, `APKRunWrapperFormat` (`1`), `APKRunWrapperKind` (`local`, `portable`, `distribution`), `APKRunLauncherVersion`, `APKRunLauncherAPI`, and the standard `CFBundle*` keys. The launcher reads them at start; WrapperCore reads them to verify a wrapper. Defined in [wrapper.md](../02-design/wrapper.md) §2.1.

### 7.3 LaunchAgent plist

`Contents/Library/LaunchAgents/io.apkrun.apkrund.plist` is read by launchd: `MachServices` (`io.apkrun.apkrund.xpc`), `RunAtLoad`, `StartInterval`, `ExitTimeOut`, and `KeepAlive.SuccessfulExit = false` ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.1). APKRun.app compares its hash with `registeredAgentPlistSHA256` to decide whether to register the agent again ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3, §9).

### 7.4 Bundle resources

| File | Content | Read by |
|---|---|---|
| `Resources/components.json` | version, build, channel, commit, `runtimeAPI`, `guestProtocol`, `agentPlistSHA256`, `dataSchemas`, pinned components | apkrund, APKRun.app, diagnostics ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1) |
| `Resources/compatibility.json` | compatibility database, including `recommendedSettings` (§3.2) | apkrund ([diagnostics.md](../02-design/diagnostics.md) §10) |

Both are part of the signed bundle. Users cannot change them.

---

## 8. Validation

### 8.1 Changes through the API and the CLI

| Problem | API result | CLI |
|---|---|---|
| unknown key (including `graphics.limits.*` in release builds) | `RuntimeFailure.unknownSetting(key)` (global) or `StoreFailure.unknownSetting(key)` (package) | exit 4 |
| wrong type, or a value outside the allowed values of §2 or §3 | `RuntimeFailure.invalidSettingValue(key, allowed)` or `StoreFailure.invalidSettingValue(key, allowed)` | exit 64, with the allowed values |
| a patch with `sharedFolders`, or `config set`/`reset` of `sharedFolders.roots` | `RuntimeFailure.invalidSettingValue(key, allowed)`; the message names the shared-folder operations | exit 64: "Use apkrun shared-folders." |
| the owner is degraded (§8.3) | `RuntimeFailure.hostStartupFailed(step:)` | exit 69 |

- The whole patch is validated before anything is written. One bad key rejects the whole patch.
- Mac-dependent values (`runtime.cpuCount`, `runtime.memoryGiB`, `runtime.userdataGiB`) are checked against this Mac when set.
- CLI syntax: `true`, `false`, `on`, `off` for bool; enums by name; decimal numbers ([cli.md](../02-design/cli.md) §4.2).
- The cases are declared in `RuntimeFailure` ([runtime-daemon.md](../02-design/runtime-daemon.md) §11) and `StoreFailure` ([package-store.md](../02-design/package-store.md) §12). [error-catalog.md](error-catalog.md) is the authority for codes and remediation.

### 8.2 Loading a file at a supported schema

| Problem | Behavior |
|---|---|
| older schema | migrated (§1.3) |
| unknown key | ignored; a warning is logged once per load; the key is dropped at the next write |
| invalid value | that key uses its default; an error is logged; the value is dropped at the next write |
| Mac-dependent value out of range for this Mac | clamped when used; the file is not changed |
| not valid JSON, or no `schemaVersion` | the file is renamed to `<name>.corrupt-<time>`; all keys use defaults; an error is logged; the next change writes a new file. Same rule as the wrapper registry ([wrapper.md](../02-design/wrapper.md) §7.2, §13) |

Package settings follow the same rules, one package at a time. A problem in one package's file affects no other package.

### 8.3 Newer schema

Follows [runtime-maintenance.md](../02-design/runtime-maintenance.md) §5:

- The owning component starts degraded with `maintenance.dataCreatedByNewerVersion(file, schema, supported)`: "This data was created by a newer version of APKRun. Install the latest version of APKRun."
- The file is never written: not by a migration, a change, or a reset.
- Global `settings.json`: startup step 4 fails ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.2). apkrund still serves the broker. `runtimeStatus` returns `RuntimeFailure.hostStartupFailed(step:)`, and `configuration()`, `updateConfiguration`, and every operation that needs settings (such as starting Android) return the same error.
- A package `settings.json`: only that package is affected. It is read-only with `store.metadataUnreadable`, as for a newer `metadata.json`; other packages work ([package-metadata-json.md](package-metadata-json.md) §4.2, [package-store.md](../02-design/package-store.md) §5.4).
- apkrund never crash-loops on data it cannot read.
- A `wrapper.json` with a newer `formatVersion` follows [wrapper-json.md](wrapper-json.md) and [wrapper.md](../02-design/wrapper.md) §2.
