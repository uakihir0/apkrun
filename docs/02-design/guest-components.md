# Guest Components Design (Guest Agent, APKRun IME, Store Agent, apkrun_vsockd)

| Field | Value |
|---|---|
| Status | Design baseline |
| Related | [../01-architecture/decisions/0008-guest-agents.md](../01-architecture/decisions/0008-guest-agents.md), [guest-protocol.md](guest-protocol.md), [input.md](input.md), [display-and-windowing.md](display-and-windowing.md) §4, [android-image.md](android-image.md) §11, [../01-architecture/security-model.md](../01-architecture/security-model.md) §4 |
| Tasks | #072, #034, #071, #035, #036, #053, #054, #081, #082, #085, #060 |

---

## 1. Components

| Component | Package / binary | Mode | Main responsibilities |
|---|---|---|---|
| Guest Agent daemon | `io.apkrun.guest.daemon.Main`, nice name `apkrun_guestd` | development (stock image): `app_process` under the shell uid | control, input, display, and launch services ([guest-protocol.md](guest-protocol.md) §7–§9) |
| Guest Agent app | `io.apkrun.guest` (process `io.apkrun.guest`) | development: hosts the IME only. Custom image: persistent priv-app that hosts **all** Guest Agent services, including the daemon code | IME, notification listener, URL handler, documents provider, plus everything above on the custom image |
| APKRun IME | `io.apkrun.guest/.ime.ApkRunInputMethodService` | both | text input from the macOS input method ([input.md](input.md) §5.6) |
| Store Agent | `io.apkrun.store` | custom image only: persistent priv-app | installs, updates, uninstalls, metadata, icons ([guest-protocol.md](guest-protocol.md) §11) |
| vsock bridge | `apkrun_vsockd` (Rust) | custom image only (and pushed as root for the #034 validation) | vsock ports 6100–6111 → the agents' abstract sockets |

The same daemon code runs in both modes. The difference is how it gets a process and which privileges it has. `AgentMode` in `Hello` tells the host which mode it is talking to ([guest-protocol.md](guest-protocol.md) §5.1).

---

## 2. Source layout and build

```text
Guest/
├── settings.gradle.kts # one Gradle build for all Kotlin guest code
├── gradle/libs.versions.toml # pinned AGP, Kotlin, coroutines, protobuf-javalite, test libraries
├── protocol/ # Android library: generated protobuf lite from Packages/GuestProtocol/proto, FrameCodec
├── agentruntime/ # Android library, the shared runtime of both agents: SystemServices (reflection wrappers), socket server, peer checks, logging
├── guestd/ # application io.apkrun.guest: daemon Main, services, IME, listener, URL handler
├── APKRunStore/ # application io.apkrun.store
├── vsockd/ # Rust crate apkrun_vsockd (Cargo for development, Soong rust_binary in the product)
└── product/ # AOSP product (android-image.md §11.1)
```

`Guest/protocol` and `Guest/agentruntime` (listed in [../01-architecture/modules.md](../01-architecture/modules.md) §1) avoid duplicating the codec and the system-service wrappers in both agents.

| Setting | Value |
|---|---|
| Language | Kotlin (JVM target 17), coroutines for concurrency |
| `minSdk` / `compileSdk` / `targetSdk` | 34 / 37 / 37 (guest floor API 34, [../00-product/scope.md](../00-product/scope.md); guest image Android 17, [android-image.md](android-image.md) §2.1) |
| Dependencies | Kotlin stdlib, kotlinx-coroutines, protobuf-javalite. Nothing else (no AndroidX in the daemon code path, because `app_process` has no application context) |
| Build | `./gradlew -p Guest assembleRelease` (called by `scripts/build-guest.sh`), output `Guest/build/out/{apkrun-guest.apk, apkrun-store.apk}` |
| Development signing | a development key in `Tests/Fixtures/signing/test-guest-dev.jks` (test-only, [../01-architecture/modules.md](../01-architecture/modules.md) §1) |
| Custom image signing | the product imports the APKs with `android_app_import { certificate: "platform", privileged: true, presigned: false }`, which re-signs them with the image's platform key ([android-image.md](android-image.md) §11.1) |
| Version | `versionCode = major × 1 000 000 + minor × 1 000 + patch` of the APKRun release that built them. `versionName` is the APKRun version plus the git revision |

The host app bundle carries the development-mode APK at `APKRun.app/Contents/Resources/guest/apkrun-guest.apk` for stock images ([guest-protocol.md](guest-protocol.md) §5.2). Custom images carry both agents in `/system_ext/priv-app/`. The agents on a custom image are updated only with the image (#058). v1 does not update platform-signed agents through the Store Agent.

---

## 3. Guest Agent in development mode (stock image, M3–M4)

### 3.1 Installation

`GuestAgentProvisioner` (RuntimeCore, ADB implementation) runs after `sys.boot_completed=1`. It runs every ADB command through the `AdbClient` helpers (`listPackages`, `install`, `uninstall`, `startGuestAgent`, `pidof`, `pkill`, `forward`, `forwardRemove`), so the command strings below live only in `AdbClient` and the raw-ADB lint needs no exception ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.3):

1. `adb shell pm list packages --show-versioncode io.apkrun.guest`. If the package is missing or the version code differs from the bundled APK, run `adb install -r -t <bundle>/guest/apkrun-guest.apk`.
2. If the installed package has a different signer (for example after switching between development machines), uninstall it first. The agent keeps no user data in development mode, so this is safe.

### 3.2 Start

`AdbClient.startGuestAgent` runs:

```sh
adb shell 'CLASSPATH=$(pm path io.apkrun.guest | sed "s/^package://") \
  setsid nohup app_process -Dapkrun.mode=development / --nice-name=apkrun_guestd \
  io.apkrun.guest.daemon.Main >/dev/null 2>&1 &'
```

- `app_process` with the installed APK on the class path is the scrcpy pattern. The process runs under the shell uid in the `shell` SELinux domain, with the shell's permissions (§5).
- `setsid nohup … &` detaches it from the ADB session, so it survives host reconnects.
- Single instance: the daemon binds the abstract socket `@apkrun-guestd-control` first. If the bind fails with `EADDRINUSE`, another instance is running, and the new one exits with status 3.
- `Main` calls `Looper.prepareMainLooper`, creates the service objects, binds the three sockets (`@apkrun-guestd-control`, `@apkrun-guestd-input`, `@apkrun-guestd-bulk`), and runs the looper. There is no `Context`. System services are reached through `SystemServices` (§6.2).

### 3.3 Supervision

- The host's `GuestAgentSupervisor` connects through the ADB forward ([guest-protocol.md](guest-protocol.md) §13.2). If the connection fails, and `adb shell pidof apkrun_guestd` finds no process, the provisioner starts it again (§3.2). It tries up to 3 times per minute. After that, health `agent.guest` fails with `runtime.requiredAgentUnavailable` ([runtime-daemon.md](runtime-daemon.md) §12).
- The daemon installs an uncaught-exception handler. It logs the stack trace (logcat tag `ApkRunGuest`, and the agent log file, §9) and exits with status 70, so the host sees a clean restart.
- In development mode, the host kills the daemon (`adb shell pkill -f apkrun_guestd`) before reinstalling the APK.

### 3.4 Device setup applied at start

The daemon applies these once per start. They are idempotent, and each one is one service call, not a shell command.

| Setting | Call (shell equivalent) | Why |
|---|---|---|
| Stay awake | `Settings.Global.STAY_ON_WHILE_PLUGGED_IN = 7`, `Settings.System.SCREEN_OFF_TIMEOUT = Int.MAX_VALUE` (`svc power stayon true`) | external displays follow the power state of display 0 ([display-and-windowing.md](display-and-windowing.md) §4) |
| No keyguard | `ILockSettings.setLockScreenDisabled(true, 0)` (`cmd lock_settings set-disabled true`) | a keyguard would cover app displays |
| APKRun IME enabled and default | `Settings.Secure.ENABLED_INPUT_METHODS` += the IME, `DEFAULT_INPUT_METHOD` = the IME (`ime enable`, `ime set`) | [input.md](input.md) §5.6 |
| Window animations | unchanged | apps expect normal animation behavior. `apkrun dev` can turn them off for tests (`--no-animations`) |
| Show IME with a hardware keyboard | `Settings.Secure.SHOW_IME_WITH_HARD_KEYBOARD = 1` | our IME has no visible view anyway. The setting keeps Android from hiding the IME's input connection when key events come from a "physical" keyboard source |

The two IME rows (APKRun IME enabled and default, and show IME with a hardware keyboard) are the IME steps. #072 applies the other rows, and #071 adds the IME rows together with the IME. Before #071, `SHOW_IME_WITH_HARD_KEYBOARD` keeps its default, and Android's own IME stays the default one; key mode needs neither ([input.md](input.md) §5.2).

The original values are not restored when the agent stops. The stock image is a development runtime.

---

## 4. Guest Agent on the custom image (M5+)

### 4.1 Manifest (excerpt)

```xml
<manifest package="io.apkrun.guest">
  <application android:persistent="true" android:directBootAware="true"
  android:defaultToDeviceProtectedStorage="true" android:allowBackup="false"
  android:name=".GuestAgentApplication" android:label="APKRun Guest Agent">
  <service android:name=".ime.ApkRunInputMethodService"
  android:permission="android.permission.BIND_INPUT_METHOD" android:exported="true">
  <intent-filter><action android:name="android.view.InputMethod"/></intent-filter>
  <meta-data android:name="android.view.im" android:resource="@xml/method"/>
</service>
<service android:name=".notifications.ApkRunNotificationListener"
android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE" android:exported="true">
<intent-filter><action android:name="android.service.notification.NotificationListenerService"/></intent-filter>
</service>
<activity android:name=".url.UrlRedirectActivity" android:exported="true"
android:theme="@android:style/Theme.NoDisplay" android:excludeFromRecents="true">
<intent-filter>
  <action android:name="android.intent.action.VIEW"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <category android:name="android.intent.category.BROWSABLE"/>
  <data android:scheme="http"/><data android:scheme="https"/><data android:scheme="mailto"/>
</intent-filter>
<intent-filter>
  <action android:name="android.intent.action.SENDTO"/>
  <category android:name="android.intent.category.DEFAULT"/>
  <data android:scheme="mailto"/>
</intent-filter>
</activity>
<activity android:name=".health.HealthCheckActivity" android:exported="true"
android:excludeFromRecents="true" android:noHistory="true"
android:theme="@android:style/Theme.DeviceDefault.NoActionBar"/>
<provider android:name=".files.MacFilesProvider" android:authorities="io.apkrun.guest.macfiles"
android:permission="android.permission.MANAGE_DOCUMENTS" android:exported="true"
android:grantUriPermissions="true">
<intent-filter><action android:name="android.content.action.DOCUMENTS_PROVIDER"/></intent-filter>
</provider>
<provider android:name="androidx.core.content.FileProvider" android:authorities="io.apkrun.guest.files"
android:exported="false" android:grantUriPermissions="true">
<meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/file_paths"/>
</provider>
</application>
</manifest>
```

- `persistent="true"` (allowed for system apps) makes ActivityManager start the app at `systemReady` and restart it if it dies. `directBootAware` lets it start before the user is unlocked. With the keyguard disabled, unlock follows immediately.
- `GuestAgentApplication.onCreate` starts the same daemon code as §3.2 with a real `Context`, in `AgentMode.PRIVILEGED_APP`. It binds the same abstract socket names. `apkrun_vsockd` reaches them there.
- `HealthCheckActivity` fills its window with a fixed test pattern (four colored quadrants), logs `APKRUN-HEALTH: drawn` after the first `onDraw`, and finishes itself after 2 s. The host launches it on a fresh display to check the whole path (display, launch, composition, frame delivery). Uses: first-run verification ([runtime-daemon.md](runtime-daemon.md) §9.2) and the migration health check ([android-image.md](android-image.md) §12.3). It is exported because the development-mode agent (shell uid) must be able to start it. It is enabled in both modes and has no other function.
- The development-only components are the same classes. In development mode the listener, URL handler, and documents provider are not enabled (they are `android:enabled="false"` by default and enabled by the agent only in `PRIVILEGED_APP` mode). The features from M9 (#054, #081, #082) need the custom image.

### 4.2 SELinux

- `seapp_contexts`: `user=_app isPrivApp=true seinfo=platform name=io.apkrun.guest domain=apkrun_guest_app type=app_data_file levelFrom=all`, and the same for `io.apkrun.store` → `apkrun_store_app`.
- `apkrun_guest_app.te` (sketch; final rules come from the #035 audit log):

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

- `apkrun_store_app.te` follows the same pattern with `package_service`, `storagestats_service`, and the installer-related services.
- The rules are developed in permissive mode for the new domains only (`permissive apkrun_guest_app;` in userdebug development builds), with the denials turned into rules. Release builds have no permissive domains. CI checks that `permissive` does not appear in a `user` build's policy.

### 4.3 Privileged permissions

`permissions/privapp-permissions-apkrun.xml` lists every privileged permission (§5) that the agents request. Signature permissions are granted by the platform signature and are not listed. Android enforces the list at boot (`ro.control_privapp_permissions=enforce` on Cuttlefish), so a missing entry prevents boot. The #035 acceptance boot catches that.

### 4.4 Custom-image defaults

The product sets the device-setup values of §3.4 as defaults through a `SettingsProvider` overlay (`def_stay_on_while_plugged_in`, `def_screen_off_timeout`, `def_lockscreen_disabled`, `def_device_provisioned`, `def_user_setup_complete`) and the default IME through `config_default_input_method`. The agent still re-applies them at start, so a changed setting is corrected.

---

## 5. Privileges per operation

"Shell" is development mode. "Priv-app" is the platform-signed privileged app on the custom image. Items marked *verify* are checked in the named task, and the results are recorded in this table.

| Area | API | Permission | Shell | Priv-app |
|---|---|---|---|---|
| Input injection | `InputManager.injectInputEvent` + `setDisplayId` (hidden) | `INJECT_EVENTS` (signature) | yes (scrcpy) | yes |
| Launch on a display | `ActivityOptions.setLaunchDisplayId` with `startActivityAsUser` | `INTERNAL_SYSTEM_WINDOW` or `ACTIVITY_EMBEDDING` for displays the caller does not own | yes | yes |
| Density per display | `IWindowManager.setForcedDisplayDensityForUser` | `WRITE_SECURE_SETTINGS` | yes | yes (privileged) |
| IME policy per display | `IWindowManager.setDisplayImePolicy` | `INTERNAL_SYSTEM_WINDOW` | yes | yes |
| Task tracking, focus, move, remove | `IActivityTaskManager.registerTaskStackListener`, `getTasks`, `setFocusedTask`, `moveRootTaskToDisplay`, `removeTask` | `MANAGE_ACTIVITY_TASKS`, `REMOVE_TASKS` | yes | yes |
| Force stop | `IActivityManager.forceStopPackage` | `FORCE_STOP_PACKAGES` | yes | yes (privileged) |
| Crash and ANR events | `IActivityManager.setActivityController` | `SET_ACTIVITY_WATCHER` | yes (`am monitor`) | yes. Only one controller exists at a time. If a developer runs `am monitor`, ours is replaced, and the agent reports `HealthWarning` |
| Package queries | `PackageManager.getPackageInfo`, `getInstalledPackages` | `QUERY_ALL_PACKAGES` | yes | yes |
| Clipboard read, write, listen | `ClipboardManager` / `IClipboard` | background read needs the default IME's uid or `READ_CLIPBOARD_IN_BACKGROUND` | *verify* in #053 (scrcpy reads the clipboard as shell; if a restriction applies, the IME process does it) | yes. The IME is the default IME and runs in the same uid |
| IME enable and select | `Settings.Secure` | `WRITE_SECURE_SETTINGS` | yes | yes |
| Notification listener grant | `INotificationManager.setNotificationListenerAccessGranted` | `MANAGE_NOTIFICATION_LISTENERS` (signature) | n/a (not enabled) | yes |
| Browser role for URL redirect | `RoleManager.addRoleHolderAsUser(ROLE_BROWSER)` | `MANAGE_ROLE_HOLDERS` | n/a | yes |
| Stay awake, keyguard | `Settings.Global` / `ILockSettings` | `WRITE_SECURE_SETTINGS`, `ACCESS_KEYGUARD_SECURE_STORAGE` | yes | product defaults (§4.4) |
| Shutdown | `IPowerManager.shutdown` | `REBOOT` | yes | yes (privileged) |
| Locale | `LocalePicker.updateLocales` equivalent (`IActivityManager.updatePersistentConfigurationWithAttribution`) | `CHANGE_CONFIGURATION` | yes | yes (privileged) |
| Time zone | `AlarmManager.setTimeZone` | `SET_TIME_ZONE` | *verify* in #085 | yes (privileged) |
| Time | `AlarmManager.setTime` | `SET_TIME` | no (`SyncTime` answers `UNSUPPORTED`; development builds set the clock over ADB as root, [desktop-integration.md](desktop-integration.md) §9) | yes (privileged). The product sets `AUTO_TIME` and `AUTO_TIME_ZONE` to 0 |
| 12/24-hour format | `Settings.System.putString(TIME_12_24)` | `WRITE_SETTINGS` | yes | yes |
| Notification click from the background | `PendingIntent.send` with `ActivityOptions.setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)` and a launch display | `START_ACTIVITIES_FROM_BACKGROUND` (signature/privileged) | n/a | *verify* in #054 that the app's activity starts on the requested display |
| Share to an app on a display, Save to Mac | `startActivity` with `ACTION_SEND` / `SEND_MULTIPLE` and URI grants from the agent's `FileProvider`; `MediaStore.Downloads` insert; a share-target activity | as "Launch on a display" | n/a | yes |
| Mac document provider | `DocumentsProvider`, `StorageManager.openProxyFileDescriptor` | none (public APIs) | n/a | yes |
| Microphone gating | `AppOpsManager.setUidMode` / `setMode(OP_RECORD_AUDIO, …, MODE_IGNORED)` | `MANAGE_APP_OPS_MODES` | yes (`appops set`) | yes |
| Active recordings with package names | `AudioManager.getActiveRecordingConfigurations` (client uid and package) | `MODIFY_AUDIO_ROUTING` (without it the list is anonymized) | n/a | yes (privileged) |
| ADB key authorization | `IAdbManager.allowDebugging` | `MANAGE_DEBUGGING` | n/a | yes |
| Package install and uninstall (Store Agent) | `PackageInstaller` sessions, `PackageInstaller.uninstall` | `INSTALL_PACKAGES`, `DELETE_PACKAGES` (signature/privileged) | n/a (`adb install-multiple` and `pm uninstall` run as shell) | yes |
| Update ownership (Store Agent) | `SessionParams.setRequestUpdateOwnership`, `PackageManager.relinquishUpdateOwnership` | `ENFORCE_UPDATE_OWNERSHIP` (signature/privileged) | n/a | yes. Whether enforcement is active on the image is *verify* in #039 |
| Update rollback (Store Agent) | `SessionParams.setEnableRollback`, `RollbackManager.getAvailableRollbacks`, `commitRollback` | `MANAGE_ROLLBACKS` (signature/privileged) and `TEST_MANAGE_ROLLBACKS` (signature). Without an allowlist entry, only `TEST_MANAGE_ROLLBACKS` lets an installer enable rollback for arbitrary packages | n/a (downgrade reinstall with `adb install -r -d` on debuggable images) | *verify* in #043 on `user` and `userdebug` builds ([package-store.md](package-store.md) §7.3) |
| Install constraints (Store Agent) | `PackageInstaller.checkInstallConstraints` with `InstallConstraints.GENTLE_UPDATE` | the installer of record, the update owner, or `INSTALL_PACKAGES` (*verify* the exact rule in #040) | n/a (the host uses `ListTasks` instead, [update-system.md](update-system.md) §7.1) | yes. How a foreground service counts is *verify* in #040 |

---

## 6. Guest Agent internals

### 6.1 Structure

```text
Main / GuestAgentApplication
└── AgentRuntime (mode, config, lifecycle)
    ├── SocketServer ×3 (+ IME socket in development): abstract-namespace `LocalServerSocket`, `SO_PEERCRED` check
    ├── SessionManager: handshake, session token, secondary stream binding, keepalive bookkeeping
    ├── Dispatcher: `Request.op` → service; per-display serial executors; timeouts; cancellation
    ├── EventBus: ordered event queue per control connection (`Event.seq`)
    └── Services
        ├── DisplayService: `DisplayManager.DisplayListener` → display events; `SetDisplayPolicy`
        ├── TaskService: `ITaskStackListener` + `getTasks` → task events; `ClearDisplay`, `MoveTaskToDisplay`, `FocusDisplay`
        ├── LaunchService: `LaunchApplication`, `StopApplication`
        ├── InputInjector: input stream → `MotionEvent` / `KeyEvent`; gesture integrity ([input.md](input.md) §7.3)
        ├── ImeBridge: IME commands and state (in-process on the custom image)
        ├── PackageService: `QueryPackage`, `ListPackages`, `PackageChanged` (development mode)
        ├── HealthService: `GetHealth`, `HealthWarning`, `AppProcessEvent`
        ├── ClipboardBridge: #053, #080
        ├── NotificationBridge: #054 (custom image)
        ├── UrlRedirect: #081 (custom image)
        ├── FilesBridge: #082 (custom image); `ImportFiles`, `SaveToMacActivity`, `MacFilesProvider` (agent → host requests)
        ├── LocaleTimeService: #085 (`SyncTime` from #069)
        └── MicrophoneGate: #084 (custom image); `SetMicrophoneAccess`, `RecordingChanged`
├─ SystemService Shutdown, AuthorizeAdbKey
└─ DiagnosticsService CollectDiagnostics (#070, items from #059 and #060)
```

### 6.2 SystemServices

`SystemServices` (in `Guest/agentruntime`) wraps the hidden framework interfaces through `ServiceManager.getService(name)` and `I*.Stub.asInterface` with reflection, as scrcpy does. Each wrapper:

- resolves its methods once at start and records which signatures exist. Android changes hidden signatures between releases, so each wrapper has variants selected by `Build.VERSION.SDK_INT` and by what is present at run time;
- fails the owning capability (not the agent) when a method is missing. The capability is then left out of `Hello`, and `GetHealth` reports the missing method name;
- is covered by an instrumented test on each supported image (§12).

Hidden API restrictions do not apply to `app_process` or to platform-signed system apps, so the same wrappers work in both modes. On the custom image, public or system APIs are used where they exist (`Context.getSystemService`) and the reflection wrappers only where they do not.

### 6.3 Threading

- One coroutine per connection reads frames. Requests are dispatched to `Dispatchers.Default` with per-display serial executors (`limitedParallelism(1)` per display ID) for display-affecting operations ([guest-protocol.md](guest-protocol.md) §6).
- Framework callbacks (display listener, task listener) arrive on a dedicated `HandlerThread` ("apkrun-callbacks") and are posted to `EventBus`.
- Input injection runs on a dedicated thread ("apkrun-input") with `THREAD_PRIORITY_URGENT_DISPLAY`, so it is not delayed by control work.
- The IME runs on the app's main thread, as Android requires. `ImeBridge` posts commands to it with `Handler.post`.

### 6.4 Launch details

- `LaunchApplication` resolves the component (`getLaunchIntentForPackage`, or the given component) and builds the intent with `FLAG_ACTIVITY_NEW_TASK` (plus `FLAG_ACTIVITY_CLEAR_TASK` for `CLEAR_TASK`).
- If the package already has a root task, the agent moves it to the requested display (`moveRootTaskToDisplay`) and brings it to the front instead of starting a second task ([guest-protocol.md](guest-protocol.md) §7.1).
- The result is returned when `ITaskStackListener` reports the task on the target display, or after `startActivity` returned `START_SUCCESS`/`START_TASK_TO_FRONT` and the task appears in `getTasks` within 2 s. Otherwise the agent answers `TIMEOUT` with the start result in `detail`.

---

## 7. APKRun IME

The behavior is defined in [input.md](input.md) §5. The component details are:

- `res/xml/method.xml`: `<input-method android:isDefault="true" android:supportsSwitchingToNextInputMethod="false" android:showInInputMethodPicker="false"/>` with one subtype, `imeSubtypeMode="keyboard"`, `isAsciiCapable="true"`, and no locale (the macOS input method does the language work).
- `onCreateInputView` returns an empty zero-height view. `onEvaluateInputViewShown` and `onEvaluateFullscreenMode` return false. `onShowInputRequested` returns false, so nothing is drawn and Android does not resize windows for a keyboard.
- `onStartInput(attribute, restarting)` records `EditorInfo` (input type, IME options, initial selection) and sends `ImeState{editor_focused = true}`. `onFinishInput` sends `editor_focused = false`.
- `requestCursorUpdates(CURSOR_UPDATE_MONITOR | CURSOR_UPDATE_IMMEDIATE)` on each input start, and `onUpdateCursorAnchorInfo` turns the insertion marker into `cursor_rect_px` in display coordinates (using `CursorAnchorInfo.getMatrix`).
- The display of the current editor is taken from the IME window's display (`getWindow.getWindow.getDecorView.getDisplay.getDisplayId`), because with the `LOCAL` policy the IME runs on the editor's display ([display-and-windowing.md](display-and-windowing.md) §4).
- Transport: in-process `ImeBridge` on the custom image. In development mode the IME process listens on `@apkrun-guest-ime` itself ([input.md](input.md) §5.6), with a `SO_PEERCRED` check that accepts the shell uid only.

---

## 8. Store Agent

### 8.1 Manifest and identity

- `io.apkrun.store`, persistent (`android:persistent="true"`, `directBootAware`), privileged, platform-signed, domain `apkrun_store_app`.
- Permissions: `INSTALL_PACKAGES`, `DELETE_PACKAGES`, `ENFORCE_UPDATE_OWNERSHIP`, `MANAGE_ROLLBACKS`, `TEST_MANAGE_ROLLBACKS`, `QUERY_ALL_PACKAGES`, `PACKAGE_USAGE_STATS` (for storage stats in metadata), `RECEIVE_BOOT_COMPLETED`. The privileged ones are listed in the product's `privapp-permissions-apkrun.xml` ([android-image.md](android-image.md) §11.1). `TEST_MANAGE_ROLLBACKS` is a signature permission that the platform-signed agent is granted. Holding it in a production image is a deliberate choice, recorded as a risk ([../04-plan/risks.md](../04-plan/risks.md)).
- It is persistent so the host can reach it whenever it needs to (an update may be applied while no app window is open). Its steady memory use is measured after #036 with the `memory` scenario of #070 and recorded against NFR-RES-04. If it is too large, making it start on demand (the Guest Agent starts it on `EnsureStoreAgent`) is the fallback, noted in [../04-plan/open-questions.md](../04-plan/open-questions.md).

### 8.2 Internals

```text
StoreAgentApplication
├── SocketServer ×2 (`@apkrun-store-control`, `@apkrun-store-artifacts`), `SessionManager`, `Dispatcher` (shared via `Guest/agentruntime`)
├── InstallService: `BeginInstall`, artifact writes, `CommitInstall`, `AbandonInstall`; session bookkeeping
├── ArchiveInspector: `InspectArchive` and pre-commit checks with `PackageManager.getPackageArchiveInfo`
├── UninstallService: `PackageInstaller.uninstall` (`DELETE_KEEP_DATA` when `keep_data`)
├── RollbackService: `RollbackPackage`, `RollbackManager.getAvailableRollbacks` → `commitRollback` (#043)
├── OwnershipService: `RelinquishUpdateOwnership`, `PackageManager.relinquishUpdateOwnership` (#039)
├── ConstraintsService: `CheckInstallConstraints`, `PackageInstaller.checkInstallConstraints` (#040)
├── MetadataService: `GetPackageMetadata` / `ListManagedPackages` (`InstallSourceInfo`, `SigningInfo`, `StorageStatsManager`)
├── IconRenderer: `RenderIcon`, `loadUnbadgedIcon` → adaptive-icon layers or a legacy bitmap → PNG
└── PackageMonitor: `ACTION_PACKAGE_ADDED/REPLACED/REMOVED/CHANGED` receivers + `PackageInstaller.SessionCallback` → `PackageChanged`
```

- Install sessions: `SessionParams(MODE_FULL_INSTALL)`, `setAppPackageName(expected)`, `setInstallReason(INSTALL_REASON_USER)`, `setPackageSource(PACKAGE_SOURCE_OTHER)`, `setRequestUpdateOwnership(request_update_ownership)`, `setEnableRollback(true, PackageManager.ROLLBACK_DATA_POLICY_RETAIN)` when `enable_rollback` is set, and `setRequireUserAction(USER_ACTION_NOT_REQUIRED)`. The streaming flow is in [guest-protocol.md](guest-protocol.md) §11.3. The host-side transaction around each call is in [package-store.md](package-store.md) §5–§7.
- Update ownership (FR-UPD-06): whether enforcement is active on the image (the `DeviceConfig` flag for update-ownership enforcement) is checked in #039 and reported in `Hello` as part of the `store.ownership.v1` details. The host policy is in [package-store.md](package-store.md) §6.3 and [update-system.md](update-system.md) §2.
- Rollback (FR-UPD-11): `RollbackService` accepts a request only when an available rollback matches the package and both version codes. It waits for the rollback's status intent and reports the installed version afterwards. Android keeps available rollbacks for a limited time (about 14 days by default), after which `RollbackPackage` answers `NOT_AVAILABLE`.
- Install constraints (FR-UPD-07): `ConstraintsService` builds `InstallConstraints` from the request flags and answers when the callback arrives, or with `TIMEOUT` after 10 s. It never waits for the constraints to become true (the host gate re-checks, [update-system.md](update-system.md) §7.2), so it does not use `waitForInstallConstraints` or `commitSessionAfterInstallConstraintsAreMet`.
- Icon rendering: the adaptive icon's layers are drawn at `size_px × size_px` on the 108 dp canvas, without a mask. A legacy icon is drawn from its highest-density bitmap at the same size. The host composes the layers and macOS applies the shape ([wrapper.md](wrapper.md) §8). Monochrome layers are included when present.
- The Store Agent never shows UI.

---

## 9. Logging

| Component | Logcat tag | File |
|---|---|---|
| Guest Agent | `ApkRunGuest` | `agent.log` ring buffer (2 × 1 MiB) in the agent's cache directory (development: `/data/local/tmp/apkrun/agent.log`) |
| Input and IME | `ApkRunInput`, `ApkRunIme` | same file |
| Store Agent | `ApkRunStore` | `store.log` ring buffer |
| Bridge | `apkrun_vsockd` | logcat only |

The same content rules as the host apply ([guest-protocol.md](guest-protocol.md) §14, [diagnostics.md](diagnostics.md) §3.4): clipboard content, notification text, typed or IME text, and account names are never logged, at any level. Key codes, pointer positions, and file names are logged only at debug level, which release builds of the agents compile out (a `BuildConfig.DEBUG` guard). `CollectDiagnostics` returns the files through the bulk stream.

---

## 10. apkrun_vsockd

### 10.1 Behavior

- A static table of (vsock port → abstract socket name) from [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1: 6100, 6101, 6102 → `apkrun-guestd-*`; 6110, 6111 → `apkrun-store-*`. There is no configuration file, so nothing can redirect a port at run time.
- For each port: `socket(AF_VSOCK, SOCK_STREAM)`, bind `VMADDR_CID_ANY:<port>`, and listen. On accept, check that the peer CID is `VMADDR_CID_HOST` (2). Then connect to the abstract socket and splice both directions until either side closes. `SO_KEEPALIVE` stays off. Liveness is the protocol's job.
- Limits: at most 8 concurrent connections per port. Excess connections are closed immediately. If the upstream connect fails (the agent is not running), the vsock connection is closed at once, and the host's backoff handles it ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).
- It does not parse, log, or buffer payloads beyond a 64 KiB copy buffer per direction.

### 10.2 Implementation

- Rust, `std` only plus `libc`, `log`, and `android_logger`, all available in AOSP `external/rust/crates`. One thread per direction per connection (at most 5 ports × 8 connections × 2 threads). The traffic is small except the artifact stream, and threads keep the code short.
- Development build for the #034 validation: `cargo ndk -t arm64-v8a build --release` (NDK r28 or later, pinned in [../05-development/environment-setup.md](../05-development/environment-setup.md)). Product build: `rust_binary { name: "apkrun_vsockd", srcs: ["src/main.rs"], rustlibs: [...] }` in its own `Guest/vsockd/Android.bp`, which the local manifest maps into the AOSP tree next to the product ([../05-development/build-system.md](../05-development/build-system.md) §9). The product makefile adds `apkrun_vsockd` to `PRODUCT_PACKAGES`.
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

The exact names of the attribute and the permission set are confirmed against the image's `system/sepolicy` in #035 (R-13).

---

## 11. Implementation steps

### #072 Guest Agent bootstrap (M3)

1. Create the Gradle build (§2) with `protocol`, `agentruntime`, and `guestd`. `scripts/build-guest.sh` builds `apkrun-guest.apk`. The host build copies it into the app bundle.
2. `SystemServices` wrappers for DisplayManager, WindowManager, ActivityTaskManager, and InputManager, with the instrumented test (§12).
3. Daemon `Main`, `SocketServer`, `SessionManager`, `Dispatcher`, and `EventBus`. Services: `DisplayService`, `TaskService` (events, `FocusDisplay`), `LaunchService` (`LaunchApplication`), and `InputInjector`.
4. Device setup (§3.4) without the IME steps (the IME comes in #071).
5. Host: `GuestAgentProvisioner` (§3.1–§3.3).
6. Acceptance: in [guest-protocol.md](guest-protocol.md) §15 (#072).

### #034 Guest Agent full service set (M4)

1. Remaining services of [guest-protocol.md](guest-protocol.md) §7.1 up to #21 and the system operations (`Shutdown`). `LaunchService.StopApplication` with `FINISH_TASKS` comes with #026, `PackageService.QueryPackage` and `ListPackages` with #027, and `TaskService.ClearDisplay` with #028 ([guest-protocol.md](guest-protocol.md) §15 #034 step 1).
2. `HealthService` with `AppProcessEvent` (activity controller) and memory data.
3. The vsock validation with `apkrun_vsockd` built by `cargo ndk` (§10.2), pushed to `/data/local/tmp`, and run as root. If the stock image's policy does not allow it, record that and defer to #035.
4. Acceptance: in [guest-protocol.md](guest-protocol.md) §15 (#034).

### #071 APKRun IME (M4)

The IME is built as §7 describes, with the steps of [input.md](input.md) §12 (#071). The device setup adds the two IME rows of §3.4.

### #035 Custom image integration (M5)

1. `GuestAgentApplication` (persistent priv-app mode, §4.1), with the development-only components enabled only in this mode.
2. `apkrun_vsockd` as a product module, `init/apkrun.rc`, sepolicy (§4.2, §10.2), `privapp-permissions-apkrun.xml` (§4.3), and the settings overlay (§4.4).
3. Build the image ([android-image.md](android-image.md) §11.5). Collect SELinux denials in the permissive development build and turn them into rules. Then boot with the domains enforcing.
4. Acceptance: [android-image.md](android-image.md) §11.5, plus: the Guest Agent is reachable over vsock with ADB disabled, and all capabilities of [guest-protocol.md](guest-protocol.md) §7.1 up to #21 are present in `Hello`.

### #036 Store Agent (M5)

1. `APKRunStore` app (§8) with `InstallService`, `ArchiveInspector`, `UninstallService`, `MetadataService`, and `PackageMonitor`. `IconRenderer` is added in #055, `OwnershipService` in #039, `ConstraintsService` in #040, and `RollbackService` in #043.
2. Product integration: priv-app, permissions, domain.
3. Host: `StoreAgentSupervisor` and the vsock implementation of `StoreAgentChannel`.
4. Acceptance: the host installs HelloText through the Store Agent without `adb install`. In addition, `GetPackageMetadata` reports `io.apkrun.store` as the installer of record.

### Later tasks

| Task | Guest work |
|---|---|
| #053 | `ClipboardBridge`: listener, loop prevention, text. The development-mode clipboard *verify* item (§5) |
| #054 | `ApkRunNotificationListener` and `NotificationBridge`, listener grant, forwarding allowlist |
| #055 | `IconRenderer` |
| #039 | `OwnershipService`, `setRequestUpdateOwnership`, enforcement-flag check (§5 *verify*) |
| #040 | `ConstraintsService`, the foreground-service *verify* item (§5) |
| #043 | `RollbackService`, `setEnableRollback`, the `TEST_MANAGE_ROLLBACKS` *verify* item (§5) |
| #080 | image clips over the bulk stream |
| #081 | `UrlRedirectActivity`, browser role, `OpenUrlOnHost` with `getLaunchedFromPackage` as the source, kept intents and `ResolveUrl`, `BROWSER_ROLE_LOST` warning |
| #082 | `FilesBridge` (import with the Downloads fallback, `SaveToMacActivity`, `ResolveExport`), `MacFilesProvider` with proxy file descriptors and the agent → host operations ([guest-protocol.md](guest-protocol.md) §7.5) |
| #085 | `LocaleTimeService`: `SetLocale`, `SetTimeZone`, `SetClockFormat` (`SyncTime` exists from #069) |
| #084 | `MicrophoneGate`: app-op gating, `RecordingChanged` |
| #070 | `DiagnosticsService` with `CollectDiagnostics` and the item `DUMPSYS_MEMINFO` |
| #059 | the `DUMPSYS_SURFACEFLINGER` item |
| #060 | the other `CollectDiagnostics` items ([diagnostics.md](diagnostics.md) §8.3) |

The host side of each is in [desktop-integration.md](desktop-integration.md), and for the `CollectDiagnostics` tasks in [diagnostics.md](diagnostics.md).

---

## 12. Tests

| Tier | Test | Task |
|---|---|---|
| T1 | JVM unit tests: dispatcher, session binding, per-display serialization, input validation, IME command mapping (fake `InputConnection`) | #072, #034, #071 |
| T0 | Rust unit tests (`cargo test`) for the bridge's port table and connection limits | #035 |
| T1 | Integration test of `apkrun_vsockd` on Linux with `vsock_loopback` (kernel module) | #035 |
| T2 | Instrumented `SystemServicesTest` (run with `am instrument` on each supported image): every wrapper resolves; a missing method fails only its capability | #072, #035 |
| T2 | Development mode: install, start, kill, restart, reinstall with a different version | #072 |
| T2 | Custom image: persistent restart after `kill`; SELinux: the HelloProbe fixture app (an ordinary `untrusted_app`) fails to connect to the agents' sockets; no denials for the agents in enforcing mode during the T2 suite | #035 |
| T2 | Store Agent install, update, uninstall, metadata | #036, #038 |

---

## 13. Open items

| Item | Plan |
|---|---|
| Clipboard read, write, and listen as shell in development mode (§5) | #053 checks it. If a restriction applies, the IME process does it |
| A notification click from the background starts the app's activity on the requested display (§5) | #054 checks it on the custom image |
| `SET_TIME_ZONE` for the shell-launched agent (§5) | #085 checks it |
| Update ownership: granted for an owner-less package, and enforcement active on the image (§5, §8.2, OQ-12) | #039 checks both and reports enforcement in `Hello` (`store.ownership.v1`). Working default: APKRun keeps ownership on the host only, and health reports `store.ownership` as a warning |
| `checkInstallConstraints`: the exact caller rule, and how a foreground service counts with `GENTLE_UPDATE` (§5, §8.2, OQ-17) | #040. Working default: trust `GENTLE_UPDATE` with `setAppNotForegroundRequired`. If a foreground service is not reported as busy, custom images add the `ListTasks` rule and a process-importance query ([update-system.md](update-system.md) §7.1) |
| Rollback with `TEST_MANAGE_ROLLBACKS` on `user` and `userdebug` builds (§5, OQ-11) | #043. Working default: the confirmed data-loss path ([package-store.md](package-store.md) §7.3) |
| Hidden and privileged APIs change between Android releases (§5, §6.2, R-18) | #072, #034, #039, #043, and #058 for each new Android base. A missing method fails only its capability (§6.2). The per-API fallbacks are listed in R-18 |
| vsock on the stock image with `apkrun_vsockd` run as root (§11, #034 step 3) | #034 tries it. If the stock image's policy does not allow it, #034 records that, and the validation moves to #035 |
| Final SELinux rules, and the exact names of the vsock attribute and permission set (§4.2, §10.2, R-13) | #035 turns the permissive-mode denials into rules and confirms the names against the image's `system/sepolicy`. Fallback: move the function to a system service in the product, or use the platform-signed priv-app path |
| Release image variant: signing and the AVB state passed (OQ-36) | decided in #035 ([android-image.md](android-image.md) §11.4). The answer affects SELinux on `user` builds (R-13) and OQ-11 |
| Steady memory use of the persistent Store Agent (§8.1, OQ-34) | Measured after #036 with the `memory` scenario of #070, against NFR-RES-04. Fallback: the Guest Agent starts the Store Agent on demand (`EnsureStoreAgent`) |

---

## 14. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| Every `SystemServices` wrapper resolves on the stock image; a missing method fails only its capability | #072 | pending (§6.2) |
| Development mode: install, start, kill, restart, and reinstall with a different version | #072 | pending (§3) |
| vsock with `apkrun_vsockd` run as root on the stock image | #034 | pending (§11) |
| Custom image: SELinux rules from the denials, attribute and permission names, boot with the domains enforcing and the privapp allowlist complete (R-13) | #035 | pending (§4.2, §4.3, §10.2) |
| Custom image: the Guest Agent is reachable over vsock with ADB disabled; HelloProbe fails to connect to the agents' sockets | #035 | pending (§11, §12) |
| The host installs HelloText through the Store Agent without `adb install`; `io.apkrun.store` is the installer of record | #036 | pending (§11) |
| Update-ownership grant and enforcement flag (OQ-12) | #039 | pending (§5, §8.2) |
| Install-constraints caller rule and the foreground-service case (OQ-17) | #040 | pending (§5) |
| Rollback with `TEST_MANAGE_ROLLBACKS` on `user` and `userdebug` builds (OQ-11) | #043 | pending (§5) |
| Clipboard as shell in development mode | #053 | pending (§5) |
| A notification click starts the activity on the requested display | #054 | pending (§5) |
| `SET_TIME_ZONE` as shell | #085 | pending (§5) |
| Store Agent steady memory use against NFR-RES-04 (OQ-34) | after #036 (`apkrun-perf memory`) | pending (§8.1) |
| Hidden API signatures on a new Android base (R-18) | #058 | pending (§6.2) |
