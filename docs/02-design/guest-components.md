# Guest Components (Guest Agent, APKRun IME, Store Agent, apkrun_vsockd)

The guest components run inside the Android guest. This document covers the Guest Agent in its two modes, the APKRun IME, the Store Agent, and the `apkrun_vsockd` bridge. The messages they exchange are in [guest-protocol.md](guest-protocol.md).

---

## 1. Components

| Component | Package / binary | Mode | Main responsibilities |
|---|---|---|---|
| Guest Agent daemon | `io.apkrun.guest.daemon.Main`, nice name `apkrun_guestd` | development (stock image): `app_process` under the shell uid | control, input, display, and launch services ([guest-protocol.md](guest-protocol.md) §7–§9) |
| Guest Agent app | `io.apkrun.guest` | development: hosts the IME only. Custom image: persistent priv-app that hosts **all** Guest Agent services, including the daemon code | IME, notification listener, URL handler, documents provider, and the daemon services on the custom image |
| APKRun IME | `io.apkrun.guest/.ime.ApkRunInputMethodService` | both | text input from the macOS input method ([input.md](input.md) §5.6) |
| Store Agent | `io.apkrun.store` | custom image only: persistent priv-app | installs, updates, uninstalls, metadata, icons ([guest-protocol.md](guest-protocol.md) §11) |
| vsock bridge | `apkrun_vsockd` (Rust) | custom image only (also pushed as root for the #35 validation) | vsock ports 6100–6111 → the agents' abstract sockets |

The same daemon code runs in both modes. The difference is how it gets a process and which privileges it has. `AgentMode` in `Hello` tells the host which mode it talks to ([guest-protocol.md](guest-protocol.md) §5.1).

---

## 2. Source layout and build

```text
Guest/
├── settings.gradle.kts          # one Gradle build for all Kotlin guest code
├── gradle/libs.versions.toml    # pinned AGP, Kotlin, coroutines, protobuf-javalite, test libraries
├── protocol/                    # Android library: protobuf lite classes from Packages/GuestProtocol/proto, FrameCodec
├── agentruntime/                # Android library shared by both agents: SystemServices, socket server, peer checks, logging
├── guestd/                      # application io.apkrun.guest: daemon Main, services, IME, listener, URL handler
├── APKRunStore/                 # application io.apkrun.store
├── vsockd/                      # Rust crate apkrun_vsockd (Cargo for development, Soong rust_binary in the product)
└── product/                     # AOSP product (android-image.md §11.1)
```

`Guest/protocol` and `Guest/agentruntime` (listed in [modules.md](../01-architecture/modules.md) §1) keep the codec and the system-service wrappers out of both agents.

| Setting | Value |
|---|---|
| Language | Kotlin (JVM target 17), coroutines for concurrency |
| `minSdk` / `compileSdk` / `targetSdk` | 34 / 37 / 37 (guest floor API 34, [scope.md](../00-product/scope.md); guest image Android 17, [android-image.md](android-image.md) §2.1) |
| Dependencies | Kotlin stdlib, kotlinx-coroutines, protobuf-javalite. No AndroidX in the daemon code path, because `app_process` has no application context |
| Build | `./gradlew -p Guest assembleRelease` (called by `scripts/build-guest.sh`). Output: `Guest/build/out/{apkrun-guest.apk, apkrun-store.apk}` |
| Development signing | `Tests/Fixtures/signing/test-guest-dev.jks` (test-only, [modules.md](../01-architecture/modules.md) §1) |
| Custom image signing | the product imports the APKs with `android_app_import { certificate: "platform", privileged: true, presigned: false }`, which re-signs them with the image's platform key ([android-image.md](android-image.md) §11.1) |
| Version | `versionCode = major × 1 000 000 + minor × 1 000 + patch` of the APKRun release that built them. `versionName` is the APKRun version plus the git revision |

The host app bundle carries the development-mode APK at `APKRun.app/Contents/Resources/guest/apkrun-guest.apk`, with its version record `apkrun-guest.json`. The host finds the bundle in this order:

1. the `--guest-dir` flag,
2. the `APKRUN_GUEST_DIR` environment variable,
3. `Resources/guest` of the app bundle that holds the executable (`DevGuestAgentLocation`).

Custom images carry both agents in `/system_ext/priv-app/`. The agents on a custom image are updated only with the image (#59). v1 does not update platform-signed agents through the Store Agent.

---

## 3. Guest Agent in development mode (stock image, M3–M4)

### 3.1 Installation

`GuestAgentProvisioner` (RuntimeCore, ADB implementation) runs after `sys.boot_completed=1`. It runs every ADB command through the `AdbClient` helpers (`listPackages`, `install`, `uninstall`, `startGuestAgent`, `pidof`, `pkill`, `forward`, `forwardRemove`). So the command strings live only in `AdbClient` ([test-strategy.md](../04-plan/test-strategy.md) §3.3).

1. Read `apkrun-guest.json` next to the bundled APK.
2. `adb shell pm list packages --show-versioncode io.apkrun.guest` gives the installed versionCode.
3. Install the bundled APK with `adb install -r -t` on **every** start, even when the versionCode matches. A rebuilt agent with the same versionCode then takes effect.
4. If the installed versionCode is higher, remove the installed package first. `install -r` cannot downgrade.
5. If Android refuses with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (another signer), remove the installed copy and install the bundled one. No signer comparison is made. The agent keeps no user data in development mode, so this is safe.

The provisioner waits for the device before these steps.

### 3.2 Start

`AdbClient.startGuestAgent` runs:

```sh
adb shell 'CLASSPATH=$(pm path io.apkrun.guest | sed "s/^package://") \
  setsid nohup app_process -Dapkrun.mode=development / --nice-name=apkrun_guestd \
  io.apkrun.guest.daemon.Main >/dev/null 2>&1 &'
```

- `app_process` with the installed APK on the class path is the scrcpy pattern. The process runs under the shell uid in the `shell` SELinux domain, with the shell's permissions (§5).
- `setsid nohup … &` detaches it from the ADB session, so it survives host reconnects.
- Single instance: the daemon binds the abstract socket `@apkrun-guestd-control` first. If the bind fails with `EADDRINUSE`, another instance runs, and the new one exits with status 3.
- `Main` calls `Looper.prepareMainLooper()`, creates the service objects, binds `@apkrun-guestd-control`, `@apkrun-guestd-input`, and `@apkrun-guestd-bulk`, and runs the looper. The development `app_process` path has no app `Context`; system services are reached through `SystemServices` (§6.2). The custom-image Application supplies its real context to the same daemon.

### 3.3 Supervision

- The host's `GuestAgentSupervisor` connects through the ADB forward ([guest-protocol.md](guest-protocol.md) §13.2). If the connection fails and `adb shell pidof apkrun_guestd` finds no process, the provisioner starts the agent again (§3.2). The restart budget is 3 restarts per 60 s. When it is spent, health `agent.guest` fails with `runtime.requiredAgentUnavailable` ([runtime-daemon.md](runtime-daemon.md) §12).
- The daemon has an uncaught-exception handler. It logs the stack trace (logcat tag `ApkRunGuest` and the agent log, §9) and exits with status 70.
- In development mode the host kills the daemon before it reinstalls the APK. It finds the daemon with `pidof` and sends `kill` to that PID. Do not use `pkill -f`, which matches the device shell's own command line, or `pkill -x`, which does not match the daemon.

### 3.4 Device setup applied at start

The daemon applies these once per start. They are idempotent and use one service call for each setting.

| Setting | Call (shell equivalent) | Why |
|---|---|---|
| Stay awake | `Settings.Global.STAY_ON_WHILE_PLUGGED_IN = 7`, `Settings.System.SCREEN_OFF_TIMEOUT = Int.MAX_VALUE` (`svc power stayon true`) | external displays follow the power state of display 0 ([display-and-windowing.md](display-and-windowing.md) §4) |
| No keyguard | `ILockSettings.setBoolean("lockscreen.disabled", true, 0)` (`cmd lock_settings set-disabled true`) | a keyguard would cover app displays |
| APKRun IME enabled and default | `Settings.Secure.ENABLED_INPUT_METHODS` += the IME, `DEFAULT_INPUT_METHOD` = the IME (`ime enable`, `ime set`) | [input.md](input.md) §5.6 |
| Window animations | unchanged | apps expect normal animation. `apkrun dev --no-animations` turns them off for tests |
| Show IME with a hardware keyboard | `Settings.Secure.SHOW_IME_WITH_HARD_KEYBOARD = 1` | keeps Android from hiding the IME's input connection when key events come from a "physical" keyboard source |

The IME rows are the IME steps. The daemon applies the other rows without the IME. Without the IME, Android's own IME stays the default one. Key mode needs neither ([input.md](input.md) §5.2).

The original values are not restored when the agent stops. The stock image is a development runtime.

In development mode the steps run through each service's shell entry point (`IBinder.shellCommand`), because the settings provider and keyguard switch refuse direct calls from the shell uid. On the custom image the privileged app uses `Settings.Global` and `Settings.System` for the stay-awake settings, and `ILockSettings.setBoolean("lockscreen.disabled", true, 0)` for keyguard (R-18). Neither path starts a process.

---

## 4. Guest Agent on the custom image (M5+)

### 4.1 Manifest

The application is `io.apkrun.guest`, with `android:persistent="true"` in the AOSP prebuilt and false in the development APK, `directBootAware="true"`, `defaultToDeviceProtectedStorage="true"`, `allowBackup="false"`, class `.GuestAgentApplication`, and label "APKRun Guest Agent".

| Component | Declaration | Purpose |
|---|---|---|
| `.ime.ApkRunInputMethodService` | service, `BIND_INPUT_METHOD`, exported, action `android.view.InputMethod`, `@xml/method` | APKRun IME (§7) |
| `.notifications.ApkRunNotificationListener` | service, `BIND_NOTIFICATION_LISTENER_SERVICE`, exported, action `android.service.notification.NotificationListenerService` | notification forwarding (§5, [desktop-integration.md](desktop-integration.md) §5) |
| `.url.UrlRedirectActivity` | activity, exported, `Theme.NoDisplay`, `excludeFromRecents`. `VIEW` (categories `DEFAULT`, `BROWSABLE`; schemes `http`, `https`, `mailto`) and `SENDTO` (`DEFAULT`; `mailto`) | URL redirect ([desktop-integration.md](desktop-integration.md) §7) |
| `.health.HealthCheckActivity` | activity, exported, `excludeFromRecents`, `noHistory`, `Theme.DeviceDefault.NoActionBar` | health check (below) |
| `.files.MacFilesProvider` | provider, authorities `io.apkrun.guest.macfiles`, `MANAGE_DOCUMENTS`, exported, `grantUriPermissions`, action `android.content.action.DOCUMENTS_PROVIDER` | Mac shared folders ([desktop-integration.md](desktop-integration.md) §6.4) |
| `androidx.core.content.FileProvider` | provider, authorities `io.apkrun.guest.files`, not exported, `grantUriPermissions`, `@xml/file_paths` | URI grants for shares |

- `persistent="true"` (allowed for system apps) makes ActivityManager start the app at `systemReady` and restart it if it dies. `directBootAware` lets it start before the user is unlocked. With the keyguard disabled, unlock follows at once.
- `GuestAgentApplication.onCreate` starts the same daemon code as §3.2, with a real `Context`, in `AgentMode.PRIVILEGED_APP`. It binds the same abstract socket names, which `apkrun_vsockd` reaches.
- `HealthCheckActivity` fills its window with a fixed four-quadrant color pattern. It logs `APKRUN-HEALTH: drawn` after the first `onDraw` and finishes itself after 2 s. The host launches it on a fresh display to check the whole path: display, launch, composition, and frame delivery ([runtime-daemon.md](runtime-daemon.md) §9.2, [android-image.md](android-image.md) §12.3). It is exported because the shell uid must be able to start it. It is enabled in both modes.
- The development-only components are the same classes. In development mode the listener, URL handler, and documents provider stay disabled (`android:enabled="false"`). The agent enables them only in `PRIVILEGED_APP` mode. The features from M9 (#55, #82, #83) need the custom image.

### 4.2 SELinux

- `seapp_contexts`: `user=_app isPrivApp=true seinfo=platform name=io.apkrun.guest domain=apkrun_guest_app type=app_data_file levelFrom=all`, and the same for `io.apkrun.store` with `apkrun_store_app`.
- `apkrun_guest_app.te` (sketch; the final rules come from the audit of permissive-mode denials, §13):

```text
type apkrun_guest_app, domain;
app_domain(apkrun_guest_app)
# system services it calls (§5)
allow apkrun_guest_app { activity_service activity_task_service input_service input_method_service
                         window_service display_service clipboard_service notification_service
                         power_service package_service lock_settings_service role_service
                         adb_service alarm_service }:service_manager find;
# only the bridge may connect to our abstract sockets
allow apkrun_vsockd apkrun_guest_app:unix_stream_socket connectto;
```

- `apkrun_store_app` follows the same pattern, with `package_service`, `storagestats_service`, and the installer-related services.
- The new domains are developed in permissive mode only (`permissive apkrun_guest_app;` in userdebug development builds), and the denials become rules. Release builds have no permissive domains. CI checks that `permissive` does not appear in a `user` build's policy.

### 4.3 Privileged permissions

`permissions/privapp-permissions-apkrun.xml` lists every privileged permission (§5) that the agents request. Signature permissions are granted by the platform signature and are not listed. Android enforces the list at boot (`ro.control_privapp_permissions=enforce` on Cuttlefish), so a missing entry prevents boot.

### 4.4 Custom-image defaults

The product sets the device-setup values of §3.4 as defaults through a `SettingsProvider` overlay: `def_stay_on_while_plugged_in`, `def_screen_off_timeout`, `def_lockscreen_disabled`, `def_device_provisioned`, and `def_user_setup_complete`. It sets the default IME through `config_default_input_method`. The agent still re-applies the §3.4 values at start, so a changed setting is corrected.

---

## 5. Privileges per operation

"Shell" is development mode. "Priv-app" is the platform-signed privileged app on the custom image. Items marked *verify* are open. They are listed in §13.

| Area | API | Permission | Shell | Priv-app |
|---|---|---|---|---|
| Input injection | `InputManager.injectInputEvent` + `setDisplayId` (hidden) | `INJECT_EVENTS` (signature) | yes (scrcpy) | yes |
| Launch on a display | `ActivityOptions.setLaunchDisplayId` with `startActivityAsUser` | `INTERNAL_SYSTEM_WINDOW` or `ACTIVITY_EMBEDDING` for displays the caller does not own | yes | yes |
| Density per display | `IWindowManager.setForcedDisplayDensityForUser` | `WRITE_SECURE_SETTINGS` | yes | yes (privileged) |
| IME policy per display | `IWindowManager.setDisplayImePolicy` | `INTERNAL_SYSTEM_WINDOW` | yes | yes |
| Task tracking, focus, move, remove | `IActivityTaskManager.registerTaskStackListener`, `getTasks`, `setFocusedTask`, `moveRootTaskToDisplay`, `removeTask` | `MANAGE_ACTIVITY_TASKS`, `REMOVE_TASKS` | yes | yes |
| Force stop | `IActivityManager.forceStopPackage` | `FORCE_STOP_PACKAGES` | yes | yes (privileged) |
| Crash and ANR events | `IActivityManager.setActivityController` | `SET_ACTIVITY_WATCHER` | yes (`am monitor`) | yes. Only one controller exists. If a developer runs `am monitor`, ours is replaced, and the agent reports `HealthWarning` |
| Package queries | `PackageManager.getPackageInfo`, `getInstalledPackages` | `QUERY_ALL_PACKAGES` | yes | yes |
| Clipboard read, write, listen | `ClipboardManager` / `IClipboard` | background read needs the default IME's uid or `READ_CLIPBOARD_IN_BACKGROUND` | *verify* (§13). If a restriction applies, the IME process does it | yes. The IME is the default IME and runs in the same uid |
| IME enable and select | `Settings.Secure` | `WRITE_SECURE_SETTINGS` | yes | yes |
| Notification listener grant | `INotificationManager.setNotificationListenerAccessGranted` | `MANAGE_NOTIFICATION_LISTENERS` (signature) | n/a (not enabled) | yes |
| Browser role for URL redirect | `RoleManager.addRoleHolderAsUser(ROLE_BROWSER)` | `MANAGE_ROLE_HOLDERS` | n/a | yes |
| Stay awake, keyguard | `Settings.Global` / `ILockSettings` | `WRITE_SECURE_SETTINGS`, `ACCESS_KEYGUARD_SECURE_STORAGE` | yes | product defaults (§4.4) |
| Shutdown | `IPowerManager.shutdown` | `REBOOT` | yes | yes (privileged) |
| Locale | `LocalePicker.updateLocales` equivalent (`IActivityManager.updatePersistentConfigurationWithAttribution`) | `CHANGE_CONFIGURATION` | yes | yes (privileged) |
| Time zone | `AlarmManager.setTimeZone` | `SET_TIME_ZONE` | *verify* (§13) | yes (privileged) |
| Time | `AlarmManager.setTime` | `SET_TIME` | no. `SyncTime` answers `UNSUPPORTED`. Development builds set the clock over ADB as root ([desktop-integration.md](desktop-integration.md) §9) | yes (privileged). The product sets `AUTO_TIME` and `AUTO_TIME_ZONE` to 0 |
| 12/24-hour format | `Settings.System.putString(TIME_12_24)` | `WRITE_SETTINGS` | yes | yes |
| Notification click from the background | `PendingIntent.send` with `ActivityOptions.setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)` and a launch display | `START_ACTIVITIES_FROM_BACKGROUND` (signature/privileged) | n/a | *verify* (§13) that the activity starts on the requested display |
| Share to an app on a display, Save to Mac | `startActivity` with `ACTION_SEND` / `SEND_MULTIPLE` and URI grants from the agent's `FileProvider`; `MediaStore.Downloads` insert; a share-target activity | as "Launch on a display" | n/a | yes |
| Mac document provider | `DocumentsProvider`, `StorageManager.openProxyFileDescriptor` | none (public APIs) | n/a | yes |
| Microphone gating | `AppOpsManager.setUidMode` / `setMode(OP_RECORD_AUDIO, …, MODE_IGNORED)` | `MANAGE_APP_OPS_MODES` | yes (`appops set`) | yes |
| Active recordings with package names | `AudioManager.getActiveRecordingConfigurations` (client uid and package) | `MODIFY_AUDIO_ROUTING` (without it the list is anonymized) | n/a | yes (privileged) |
| ADB key authorization | `IAdbManager.allowDebugging` | `MANAGE_DEBUGGING` | n/a | yes |
| Package install and uninstall (Store Agent) | `PackageInstaller` sessions, `PackageInstaller.uninstall` | `INSTALL_PACKAGES`, `DELETE_PACKAGES` (signature/privileged) | n/a (`adb install-multiple` and `pm uninstall` run as shell) | yes |
| Update ownership (Store Agent) | `SessionParams.setRequestUpdateOwnership`, `PackageManager.relinquishUpdateOwnership` | `ENFORCE_UPDATE_OWNERSHIP` (signature/privileged) | n/a | yes. Enforcement on the image: *verify* (§13) |
| Update rollback (Store Agent) | `SessionParams.setEnableRollback`, `RollbackManager.getAvailableRollbacks`, `commitRollback` | `MANAGE_ROLLBACKS` (signature/privileged) and `TEST_MANAGE_ROLLBACKS` (signature). Without an allowlist entry, only `TEST_MANAGE_ROLLBACKS` lets an installer enable rollback for arbitrary packages | n/a (downgrade reinstall with `adb install -r -d` on debuggable images) | *verify* (§13) on `user` and `userdebug` builds ([package-store.md](package-store.md) §7.3) |
| Install constraints (Store Agent) | `PackageInstaller.checkInstallConstraints` with `InstallConstraints.GENTLE_UPDATE` | the installer of record, the update owner, or `INSTALL_PACKAGES` (*verify* the exact rule, §13) | n/a (the host uses `ListTasks` instead, [update-system.md](update-system.md) §7.1) | yes. How a foreground service counts: *verify* (§13) |

---

## 6. Guest Agent internals

### 6.1 Structure

```text
Main / GuestAgentApplication
 └─ AgentRuntime (mode, config, lifecycle)
     ├─ SocketServer ×3 (+ IME socket in development)   LocalServerSocket in the abstract namespace, SO_PEERCRED check
     ├─ SessionManager            handshake, session token, secondary stream binding, keepalive bookkeeping
     ├─ Dispatcher                Request.op → service; per-display serial executors; timeouts; cancel
     ├─ EventBus                  ordered event queue per control connection (Event.seq)
     └─ Services
         ├─ DisplayService        DisplayListener → display events; SetDisplayPolicy
         ├─ TaskService           ITaskStackListener + getTasks → task events; ClearDisplay; MoveTaskToDisplay; FocusDisplay
         ├─ LaunchService         LaunchApplication, StopApplication
         ├─ InputInjector         input stream → MotionEvent / KeyEvent; gesture integrity (input.md §7.3)
         ├─ ImeBridge             IME commands and state (in-process on the custom image)
         ├─ PackageService        QueryPackage, ListPackages, PackageChanged (development mode)
         ├─ HealthService         GetHealth, HealthWarning, AppProcessEvent
         ├─ ClipboardBridge       clipboard (custom image)
         ├─ NotificationBridge    notifications (custom image)
         ├─ UrlRedirect           URL redirect (custom image)
         ├─ FilesBridge           ImportFiles, SaveToMacActivity, MacFilesProvider (custom image; agent → host requests)
         ├─ LocaleTimeService     SetLocale, SetTimeZone, SetClockFormat, SyncTime
         ├─ MicrophoneGate        app-op gating, RecordingChanged (custom image)
         ├─ SystemService         Shutdown, AuthorizeAdbKey
         └─ DiagnosticsService    CollectDiagnostics and its items
```

### 6.2 SystemServices

`SystemServices` (in `Guest/agentruntime`) wraps the hidden framework interfaces. It gets each service with `ServiceManager.getService(name)` and `I*.Stub.asInterface`, through reflection, as scrcpy does. Each wrapper:

- resolves its methods once at start and records which signatures exist. Android changes hidden signatures between releases, so each wrapper has variants selected by `Build.VERSION.SDK_INT` and by what is present at run time;
- fails the owning capability, not the agent, when a method is missing. The capability is then left out of `Hello`. When `health.v1` remains available, `GetHealth` reports missing method names; when a missing health method disables `health.v1`, startup diagnostics report the unavailable method because `GetHealth` cannot be called;
- is covered by an instrumented test on each supported image (§12).

Hidden API restrictions do not apply to `app_process` or to platform-signed system apps, so the same wrappers work in both modes. On the custom image, public or system APIs are used where they exist (`Context.getSystemService`). The reflection wrappers are used only where they do not.

### 6.3 Threading

- One coroutine per connection reads frames. Requests are dispatched to `Dispatchers.Default`, with a per-display serial executor (`limitedParallelism(1)` per display ID) for display-affecting operations ([guest-protocol.md](guest-protocol.md) §6).
- Framework callbacks (display listener, task listener) arrive on a dedicated `HandlerThread` ("apkrun-callbacks") and are posted to `EventBus`.
- Input injection runs on a dedicated thread ("apkrun-input") with `THREAD_PRIORITY_URGENT_DISPLAY`, so control work cannot delay it.
- The IME runs on the app's main thread, as Android requires. `ImeBridge` posts commands to it with `Handler.post`.

### 6.4 Launch details

- `LaunchApplication` resolves the component (`getLaunchIntentForPackage`, or the given component). It builds the intent with `FLAG_ACTIVITY_NEW_TASK`, plus `FLAG_ACTIVITY_CLEAR_TASK` for `CLEAR_TASK`.
- A negative `display_id` is `INVALID_ARGUMENT`. A nonnegative ID that Android does not report is `NOT_FOUND`.
- On the stock image the activity starts through `startActivityAsUser` with `com.android.shell` as the calling package. A start through the system context is refused.
- Launch options select the requested display and `WINDOWING_MODE_FULLSCREEN` ([display-and-windowing.md](display-and-windowing.md) §4).
- If the package already has a root task, the agent moves it to the requested display (`moveRootTaskToDisplay`) and brings it to the front. It does not start a second task ([guest-protocol.md](guest-protocol.md) §7.1).
- The result is returned when `ITaskStackListener` reports the task on the target display. Otherwise, when `startActivity` returned `START_SUCCESS` or `START_TASK_TO_FRONT` and the task appears in `getTasks` within 2 s, the result is returned from that. If neither happens, the agent answers `TIMEOUT` with the start result in `detail`.

---

## 7. APKRun IME

The behavior is defined in [input.md](input.md) §5. The component details are:

- `res/xml/method.xml`: `<input-method android:isDefault="true" android:supportsSwitchingToNextInputMethod="false" android:showInInputMethodPicker="false"/>` with one subtype: `imeSubtypeMode="keyboard"`, `isAsciiCapable="true"`, and no locale. The macOS input method does the language work.
- `onCreateInputView()` returns an empty zero-height view. `onEvaluateInputViewShown()`, `onEvaluateFullscreenMode()`, and `onShowInputRequested()` return false. Nothing is drawn, and Android does not resize windows for a keyboard.
- `onStartInput(attribute, restarting)` records `EditorInfo` (input type, IME options, initial selection) and sends `ImeState{editor_focused = true}`. `onFinishInput()` sends `editor_focused = false`.
- `requestCursorUpdates(CURSOR_UPDATE_MONITOR | CURSOR_UPDATE_IMMEDIATE)` on each input start. `onUpdateCursorAnchorInfo` turns the insertion marker into `cursor_rect_px` in display coordinates, using `CursorAnchorInfo.getMatrix()`.
- The display of the current editor is the IME window's display (`getWindow().getWindow().getDecorView().getDisplay().getDisplayId()`). With the `LOCAL` policy the IME runs on the editor's display ([display-and-windowing.md](display-and-windowing.md) §4).
- Transport: in-process `ImeBridge` on the custom image. In development mode the IME process listens on `@apkrun-guest-ime` itself ([input.md](input.md) §5.6), with a `SO_PEERCRED` check that accepts the shell uid only.

---

## 8. Store Agent

### 8.1 Manifest and identity

- `io.apkrun.store`, persistent (`android:persistent="true"`, `directBootAware`), privileged, platform-signed, domain `apkrun_store_app`.
- Permissions: `INSTALL_PACKAGES`, `DELETE_PACKAGES`, `ENFORCE_UPDATE_OWNERSHIP`, `MANAGE_ROLLBACKS`, `TEST_MANAGE_ROLLBACKS`, `QUERY_ALL_PACKAGES`, `PACKAGE_USAGE_STATS` (storage stats in metadata), `RECEIVE_BOOT_COMPLETED`. The privileged ones are listed in the product's `privapp-permissions-apkrun.xml` ([android-image.md](android-image.md) §11.1). `TEST_MANAGE_ROLLBACKS` is a signature permission that the platform-signed agent is granted. Holding it in a production image is a known risk ([risks.md](../04-plan/risks.md)).
- The agent is persistent, so the host can reach it whenever it needs to. An update can be applied while no app window is open. Its steady memory use is open (OQ-34, §13).

### 8.2 Internals

```text
StoreAgentApplication
 ├─ SocketServer ×2 (@apkrun-store-control, @apkrun-store-artifacts), SessionManager, Dispatcher   (shared with the Guest Agent via Guest/agentruntime)
 ├─ InstallService      BeginInstall / artifact writes / CommitInstall / AbandonInstall; session bookkeeping
 ├─ ArchiveInspector    InspectArchive and pre-commit checks with PackageManager.getPackageArchiveInfo
 ├─ UninstallService    PackageInstaller.uninstall (DELETE_KEEP_DATA when keep_data)
 ├─ RollbackService     RollbackPackage: RollbackManager.getAvailableRollbacks → commitRollback
 ├─ OwnershipService    RelinquishUpdateOwnership: PackageManager.relinquishUpdateOwnership
 ├─ ConstraintsService  CheckInstallConstraints: PackageInstaller.checkInstallConstraints
 ├─ MetadataService     GetPackageMetadata / ListManagedPackages (InstallSourceInfo, SigningInfo, StorageStatsManager)
 ├─ IconRenderer        RenderIcon: loadUnbadgedIcon → AdaptiveIconDrawable layers or a legacy bitmap → PNG
 └─ PackageMonitor      ACTION_PACKAGE_ADDED/REPLACED/REMOVED/CHANGED receivers + PackageInstaller.SessionCallback → PackageChanged
```

- Install sessions: `SessionParams(MODE_FULL_INSTALL)`, `setAppPackageName(expected)`, `setInstallReason(INSTALL_REASON_USER)`, `setPackageSource(PACKAGE_SOURCE_OTHER)`, `setRequestUpdateOwnership(request_update_ownership)`, `setEnableRollback(true, PackageManager.ROLLBACK_DATA_POLICY_RETAIN)` when `enable_rollback` is set, and `setRequireUserAction(USER_ACTION_NOT_REQUIRED)`. The streaming flow is in [guest-protocol.md](guest-protocol.md) §11.3. The host-side transaction around each call is in [package-store.md](package-store.md) §5–§7.
- Update ownership (FR-UPD-06): whether enforcement is active on the image is read from the `DeviceConfig` flag for update-ownership enforcement. The agent reports the result in `Hello`, as part of the `store.ownership.v1` details. The host policy is in [package-store.md](package-store.md) §6.3 and [update-system.md](update-system.md) §2.
- Rollback (FR-UPD-11): `RollbackService` accepts a request only when an available rollback matches the package and both version codes. It waits for the rollback's status intent and reports the installed version afterwards. Android keeps available rollbacks for a limited time (about 14 days by default). After that, `RollbackPackage` answers `NOT_AVAILABLE`.
- Install constraints (FR-UPD-07): `ConstraintsService` builds `InstallConstraints` from the request flags and answers when the callback arrives, or with `TIMEOUT` after 10 s. It never waits for the constraints to become true. The host gate re-checks them ([update-system.md](update-system.md) §7.2). So the agent does not use `waitForInstallConstraints` or `commitSessionAfterInstallConstraintsAreMet`.
- Icon rendering: the adaptive icon's layers are drawn at `size_px × size_px` on the 108 dp canvas, without a mask. A legacy icon is drawn from its highest-density bitmap at the same size. Monochrome layers are included when present. The host composes the layers, and macOS applies the shape ([wrapper.md](wrapper.md) §8).
- The Store Agent never shows UI.

---

## 9. Logging

| Component | Logcat tag | File |
|---|---|---|
| Guest Agent | `ApkRunGuest` | `agent.log` ring buffer (2 × 1 MiB) in the agent's cache directory (development: `/data/local/tmp/apkrun/agent.log`) |
| Input and IME | `ApkRunInput`, `ApkRunIme` | same file |
| Store Agent | `ApkRunStore` | `store.log` ring buffer |
| Bridge | `apkrun_vsockd` | logcat only |

The content rules of the host apply ([guest-protocol.md](guest-protocol.md) §14, [diagnostics.md](diagnostics.md) §3.4). Clipboard content, notification text, typed or IME text, and account names are never logged, at any level. Key codes, pointer positions, and file names are logged only at debug level. Release builds compile that level out (a `BuildConfig.DEBUG` guard). `CollectDiagnostics` returns the log files through the bulk stream.

---

## 10. apkrun_vsockd

### 10.1 Behavior

- A static table maps vsock ports to abstract socket names ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1): 6100, 6101, 6102 → `apkrun-guestd-*`; 6110, 6111 → `apkrun-store-*`. There is no configuration file, so nothing can redirect a port at run time.
- For each port: `socket(AF_VSOCK, SOCK_STREAM)`, bind `VMADDR_CID_ANY:<port>`, and listen. On accept, check that the peer CID is `VMADDR_CID_HOST` (2). Then connect to the abstract socket and splice both directions until either side closes. `SO_KEEPALIVE` stays off. Liveness is the protocol's job.
- Limits: at most 8 concurrent connections per port. Excess connections are closed at once. If the upstream connect fails (the agent is not running), the vsock connection is closed at once, and the host's backoff handles it ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).
- The bridge does not parse, log, or buffer payloads beyond a 64 KiB copy buffer per direction.
- The agents accept peers by uid (`PeerCheck`, the `SO_PEERCRED` rule of [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1). The daemon maps its explicit `AgentMode` to a peer policy for each socket: `PRIVILEGED_APP` selects the custom-image rule, allowing `system` (1000, the bridge) and `root` (0), plus `shell` (2000) only when `ro.boot.apkrun.devmode=1`; an unreadable or unset developer-mode property never enables `shell`. `DEVELOPMENT_SHELL` is the stock-image path and accepts only `shell` and `root`, because adbd is the only peer there. Unknown modes are refused. The custom-image rule does not depend on reading `ro.apkrun.product` from the app domain.

### 10.2 Implementation

- Rust, `std` plus `libc`, `log`, and `android_logger`, all available in AOSP `external/rust/crates`. One thread per direction per connection (at most 5 ports × 8 connections × 2 threads).
- Development build: `cargo ndk -t arm64-v8a build --release` (NDK r28 or later, pinned in [environment-setup.md](../05-development/environment-setup.md)). Product build: `rust_binary { name: "apkrun_vsockd", srcs: ["src/main.rs"], rustlibs: [...] }` in `Guest/vsockd/Android.bp`. The local manifest maps that file into the AOSP tree next to the product ([build-system.md](../05-development/build-system.md) §9). The product makefile adds `apkrun_vsockd` to `PRODUCT_PACKAGES`.
- `init/apkrun.rc`:

```text
service apkrun_vsockd /system_ext/bin/apkrun_vsockd
    class main
    user system
    group system
    capabilities
    restart_period 1
```

- `sepolicy/apkrun_vsockd.te` (sketch):

```text
type apkrun_vsockd, domain;
type apkrun_vsockd_exec, exec_type, system_file_type, file_type;
init_daemon_domain(apkrun_vsockd)
typeattribute apkrun_vsockd unconstrained_vsock_violators;
allow apkrun_vsockd self:vsock_socket { create bind listen accept read write getattr getopt setopt shutdown };
allow apkrun_vsockd self:unix_stream_socket { create connect read write getattr shutdown };
allow apkrun_vsockd { apkrun_guest_app apkrun_store_app }:unix_stream_socket connectto;
```

The exact names of the attribute and the permission set are confirmed against the image's `system/sepolicy` (R-13).

---

## 12. Tests

| Tier | What is tested | Where |
|---|---|---|
| T0 | Agent dispatcher, session binding, per-display serialization, input validation, IME command mapping (fake `InputConnection`) | `Guest/guestd/src/test/` |
| T0 | `SystemServices` wrappers: a missing framework method fails only its capability | `Guest/agentruntime/src/test/` (`SystemServiceWrapperTest.kt`) |
| T0 | Rust unit tests for the bridge's port table and connection limits (`cargo test`) | `Guest/vsockd/` |
| T1 | `apkrun_vsockd` on Linux with the `vsock_loopback` kernel module | `Guest/vsockd/` |
| T2 | Instrumented `SystemServicesTest` on each supported image (`am instrument`): every wrapper resolves, and a missing method fails only its capability | on the image |
| T2 | Development mode: install, start, kill, restart, and reinstall with a different version | `Tests/IntegrationTests/GuestAgentTests/` |
| T2 | Custom image: persistent restart after `kill`. The HelloProbe fixture app (an ordinary `untrusted_app`) fails to connect to the agents' sockets. No denials for the agents in enforcing mode during the suite | `Tests/IntegrationTests/` |
| T2 | Store Agent: install, update, uninstall, metadata | `Tests/IntegrationTests/AndroidPackageTests/` |

---

## 13. Open items

| Item | Plan |
|---|---|
| Clipboard read, write, and listen as shell in development mode (§5) | #54 checks it. If a restriction applies, the IME process does it |
| A notification click from the background starts the app's activity on the requested display (§5) | #55 checks it on the custom image |
| `SET_TIME_ZONE` for the shell-launched agent (§5) | #86 checks it |
| Update ownership: granted for an owner-less package, and enforcement active on the image (§5, §8.2) | OQ-12. #40 checks both and reports enforcement in `Hello`. Working default: APKRun keeps ownership on the host only, and health reports `store.ownership` as a warning |
| `checkInstallConstraints`: the exact caller rule, and how a foreground service counts with `GENTLE_UPDATE` (§5, §8.2) | OQ-17. #41 checks it. Working default: trust `GENTLE_UPDATE` with `setAppNotForegroundRequired()`. If a foreground service is not reported as busy, custom images add the `ListTasks` rule and a process-importance query ([update-system.md](update-system.md) §7.1) |
| Rollback with `TEST_MANAGE_ROLLBACKS` on `user` and `userdebug` builds (§5) | OQ-11. #44 checks it. Working default: the confirmed data-loss path ([package-store.md](package-store.md) §7.3) |
| Hidden and privileged APIs change between Android releases (§3.4, §5, §6.2) | R-18. A missing method fails only its capability (§6.2). The per-API fallbacks are in R-18 |
| vsock on the stock image with `apkrun_vsockd` run as root (§10) | #35 tries it. If the stock image's policy does not allow it, the validation moves to #36. See [guest-protocol.md](guest-protocol.md) §17 |
| Final SELinux rules, and the exact names of the vsock attribute and permission set (§4.2, §10.2) | R-13. The permissive-mode denials become rules, and the names are confirmed against the image's `system/sepolicy`. Fallback: move the function to a system service in the product, or use the platform-signed priv-app path |
| Release image variant: signing and the AVB state (§4.2) | OQ-36. The answer affects SELinux on `user` builds (R-13) and OQ-11 ([android-image.md](android-image.md) §11.4) |
| Steady memory use of the persistent Store Agent, against NFR-RES-04 (§8.1) | OQ-34. Fallback: the Guest Agent starts the Store Agent on demand (`EnsureStoreAgent`) |
