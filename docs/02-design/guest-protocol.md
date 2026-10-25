# Guest Protocol (GuestProtocol)

The guest protocol is the only interface between host code and APKRun's guest components: the Guest Agent, the Store Agent, and the APKRun IME. This document defines the framing, the handshake, the version and capability rules, every operation and event, the errors, and the limits. The components are in [guest-components.md](guest-components.md).

---

## 1. Scope and principles

GuestProtocol owns the message definitions, the framing codec, and the version constants. It has no business logic. RuntimeCore, APKStoreCore, and IntegrationCore build typed channels on top of it ([modules.md](../01-architecture/modules.md) §2).

1. **One schema.** The `.proto` files in `Packages/GuestProtocol/proto/` are the source of truth for both sides.
2. **Host initiates, guest serves.** The host opens every connection and sends every request. The guest sends responses and events and never waits for the host, so a slow or absent host cannot block Android threads.
3. **Snapshot plus events.** After every (re)connect the host reads a snapshot and then applies events. The guest does not replay missed events.
4. **Validate everything on both sides.** Messages from the guest are untrusted input to apkrund ([security-model.md](../01-architecture/security-model.md)). The agents check messages from the host too.
5. **No per-event process spawning.** Every production operation is one message on an open stream (FR-IN-06, NFR-PERF).

---

## 2. Files and code generation

```text
Packages/GuestProtocol/
├── proto/apkrun/guest/v1/      # envelope, common, control, input, integration, bulk, store .proto
├── buf.yaml                    # lint and breaking rules
├── Sources/GuestProtocol/
│   ├── Generated/              # swift-protobuf output, checked in
│   ├── FrameCodec.swift        # §4
│   ├── ProtocolVersion.swift   # §5.2
│   └── Capabilities.swift      # §5.3
├── Tests/GuestProtocolTests/
└── testdata/frames/            # golden frames (§16)
```

- proto3, `package apkrun.guest.v1`, `option java_package = "io.apkrun.guest.protocol.v1"`, `option java_multiple_files = true`, `option swift_prefix = "GP"`.
- **Host:** `swift-protobuf`, pinned in `Package.resolved`. The generated Swift is checked in, so `swift build` needs no `protoc`. `scripts/generate-protos.sh` regenerates it with the pinned `protoc` and `protoc-gen-swift`. CI (#63) fails if regeneration changes the tree.
- **Guest:** the Gradle builds of `Guest/guestd` and `Guest/APKRunStore` use the `com.google.protobuf` plugin with the lite runtime (`protobuf-javalite`, pinned) and read the same `proto/` directory. The AOSP product imports the built APKs ([android-image.md](android-image.md) §11.1), so Soong never compiles the protos.
- **Golden frames:** `testdata/frames/valid-*.txtpb` are the sources. `scripts/generate-protos.sh` writes `valid-*.bin` and `invalid-*.bin`.
- CI runs `buf lint` (DEFAULT rules, with `ENUM_ZERO_VALUE_SUFFIX = _UNSPECIFIED`) and `buf breaking` against the last release tag (#63).

---

## 3. Channels

The transports and the port plan are in [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1. This table gives the protocol role of each channel.

| Channel | Server | Carries | Envelope bodies allowed |
|---|---|---|---|
| Guest control (6100) | Guest Agent | requests and responses, events | `hello`, `hello_ack`, `request`, `response`, `event`, `cancel` |
| Guest input (6101) | Guest Agent | input batches, IME commands, IME state, acks | `hello`, `hello_ack`, `input_batch`, `ime_command`, `ime_state`, `input_ack` |
| Guest bulk (6102) | Guest Agent | large payloads and the agent → host file operations of §7.5 | `hello`, `hello_ack`, `bulk`, `request` (agent → host only), `response` (host → agent only) |
| Store control (6110) | Store Agent | install, uninstall, metadata, icons | as guest control |
| Store artifacts (6111) | Store Agent | APK and icon payloads | as guest bulk |
| IME (development only, `@apkrun-guest-ime`) | IME service in the `io.apkrun.guest` process | IME commands and IME state | as guest input, without `input_batch` ([input.md](input.md) §5.6) |

A body that is not allowed on a channel is a protocol violation (§12.2).

---

## 4. Framing

```text
frame := length:uint32 (big-endian) || Envelope (protobuf binary, `length` bytes)
```

- The maximum `length` is 4 MiB (4 194 304). A larger length closes the connection with `frameTooLarge`. A length of 0 is invalid.
- Frames are written whole. The writer never interleaves two frames on one connection.
- Readers use a fixed 64 KiB read buffer plus an allocation up to the frame length. They never allocate on the basis of an unvalidated length above the limit.
- `FrameCodec` (Swift) and `io.apkrun.guest.protocol.FrameCodec` (Kotlin) are pure functions over byte buffers. They share golden test vectors (§16).

### 4.1 Envelope

```proto
message Envelope {
  uint64 id = 1;            // per connection and per sender, starts at 1, strictly increasing
  uint64 reply_to = 2;      // set on `response`: the id of the request
  string operation_id = 3;  // host OperationID for log correlation (DiagnosticsCore); optional
  oneof body {
    Hello hello = 10;
    HelloAck hello_ack = 11;
    Request request = 12;
    Response response = 13;
    Event event = 14;
    Cancel cancel = 15;
    InputBatch input_batch = 20;
    InputAck input_ack = 21;
    ImeCommand ime_command = 22;
    ImeState ime_state = 23;
    BulkFrame bulk = 30;
  }
}

message Request {
  uint32 timeout_ms = 1;    // the agent gives up after this; the host waits timeout_ms + 1000
  oneof op { /* §7.1 and §11.1 */ }
}

message Response {
  oneof result {
    GuestError error = 1;   // the only field outside the operation numbers
    /* one result message per op, same field number as the op in Request */
  }
}

message Event {
  uint64 seq = 1;           // per connection, starts at 1; gaps are a protocol violation
  oneof kind { /* §8 and §11.2 */ }
}

message Cancel { uint64 target_id = 1; }   // best effort; the response still arrives (CANCELLED or the result)
```

Numbering rule: an operation uses the same field number in `Request.op` and in `Response.result`. The result type has the operation's name.

| Range | Area |
|---|---|
| 10–39 | core and control (Guest Agent) |
| 40–59 | integration, host → Guest Agent |
| 60–69 | integration, Guest Agent → host (file operations, §7.5) |
| 70–79 | system and diagnostics (Guest Agent) |
| 100–139 | Store Agent |
| 200+ | experiments behind a capability, never in a release build |

---

## 5. Handshake, versions, capabilities

### 5.1 Hello

The server (the agent) speaks first after the connection is established. The message definitions match [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.3.

```proto
message ProtocolVersion { uint32 major = 1; uint32 minor = 2; }

message Hello {
  ProtocolVersion protocol_version = 1;
  AgentInfo agent = 2;                    // kind (GUEST_AGENT, STORE_AGENT, GUEST_IME), version_name, version_code, build_id
  string runtime_image_version = 3;       // ro.boot.apkrun.image: the imageVersion that ImageCore wrote into bootconfig (android-image.md §6.2)
  AndroidInfo android = 4;                // sdk_int, release, build_fingerprint, build_type (user/userdebug)
  repeated string capabilities = 5;       // §5.3
  ChannelKind channel = 6;                // the channel this server believes it is (§3)
  AgentMode mode = 7;                     // DEVELOPMENT_SHELL (app_process under shell) or PRIVILEGED_APP
}

message HelloAck {
  oneof outcome { Accepted accepted = 1; Rejected rejected = 2; }
  ProtocolVersion host_protocol_version = 3;
  bytes session_token = 4;                // 16 random bytes, see §5.4
  repeated string enabled_capabilities = 5;
  string host_version = 6;                // APKRun version, for guest logs
}
message Accepted {}
message Rejected { RejectReason reason = 1; string detail = 2; }   // INCOMPATIBLE_VERSION, WRONG_CHANNEL, BAD_TOKEN, DUPLICATE_SESSION
```

- The host waits 5 s for `Hello` after it connects, and closes the connection otherwise. The agent waits 5 s for `HelloAck`.
- No other frame may be sent before the handshake completes.
- The host side is `GuestHandshake` in `Packages/GuestProtocol`. The agent side is `AgentHandshake` in `Guest/protocol`.

### 5.2 Version rules

| Situation | Result |
|---|---|
| Same major, any minor | accepted. Features are negotiated through capabilities |
| Different major | the host sends `Rejected{INCOMPATIBLE_VERSION}` and closes. Health marks the agent `incompatible`. The user sees `GuestProtocolFailure.incompatibleVersion` with "Update APKRun" (agent newer) or "Update Android" (agent older) (NFR-REL-04) |
| Unknown request op (older agent) | the agent answers `GuestError{UNSUPPORTED}`. The host treats a missing capability the same way before sending |
| Unknown event kind (newer agent) | the host ignores it and counts `guest.unknownEvent` |
| Unknown enum value | treated as `*_UNSPECIFIED` |

- The host supports protocol major **1** in v1: `ProtocolVersion.supportedMajors = 1...1` in `ProtocolVersion.swift`.
- Runtime images declare the agent protocol range in the manifest (`requirements.guestProtocol`, [android-image.md](android-image.md) §12.1). ImageCore refuses to activate an image whose range does not intersect the host's range. The handshake check is the second line of defense.
- Development (stock image): the host carries the matching Guest Agent APK and installs it on every start ([guest-components.md](guest-components.md) §3.1), so a development mismatch is corrected automatically.
- The agent checks the host's major version too. A host with major 2 fails the handshake on the agent side with the same typed `incompatibleVersion`.

Evolution rules (`buf breaking` checks them):

- Field numbers are frozen. Never change or reuse a field number or a oneof case. Removed fields become `reserved`.
- Adding a field, message, enum value, or oneof case is a minor change. If the host must know whether the guest implements it, it also gets a capability.
- Changing the meaning of an existing field, or making a new field mandatory for correctness, is a major change. It needs an ADR and a transition window in which the host supports both majors.

### 5.3 Capabilities

A capability is a string `<area>.<feature>.v<n>`. The agent lists what it implements. The host echoes the subset it uses in `enabled_capabilities`. The agent rejects (`UNSUPPORTED`) requests for capabilities that are not enabled.

| Capability | Agent | Operations and events |
|---|---|---|
| `core.v1` | all | `Ping`, `GetSnapshot`, `SystemStateChanged` |
| `display.v1` | Guest | `SetDisplayPolicy`, `ClearDisplay`, display events |
| `launch.v1` | Guest | `LaunchApplication`, `StopApplication`, `MoveTaskToDisplay`, `ListTasks`, task events |
| `input.v1` | Guest | input stream, `FocusDisplay` |
| `input.ack_trace.v1` | Guest | optional Android uptime in `InputAck` when a batch requests it (§9) |
| `ime.v1` | Guest, IME | `ImeCommand`, `ImeState` |
| `packages.v1` | Guest | `QueryPackage`, `ListPackages`, `PackageChanged` |
| `health.v1` | Guest | `GetHealth`, `HealthWarning`, `AppProcessEvent` |
| `system.v1` | Guest | `Shutdown`, `AuthorizeAdbKey` |
| `clipboard.text.v1` | Guest | `SetClipboard` (text), `ClipboardChanged` |
| `clipboard.image.v1` | Guest | image clip items over the bulk stream |
| `notifications.v1` | Guest | notification events, `ActivateNotification`, `DismissNotification`, `SetNotificationForwarding` |
| `url.v1` | Guest | `SetUrlRedirect`, `OpenUrlOnHost`, `ResolveUrl` |
| `files.v1` | Guest | `ImportFiles`, `ExportFileOffered`, `ResolveExport` |
| `files.shared.v1` | Guest | `SetSharedFolderAccess`, the agent → host operations 60–69 (§7.5) |
| `locale.v1` | Guest | `SetLocale`, `SetTimeZone`, `SetClockFormat`, `SyncTime` |
| `audio.v1` | Guest | `SetMicrophoneAccess`, `RecordingChanged` |
| `diagnostics.v1` | Guest | `CollectDiagnostics` |
| `bulk.v1` | Guest, Store | bulk and artifact stream |
| `store.install.v1` | Store | `BeginInstall`, `CommitInstall`, `AbandonInstall`, `Uninstall`, install events |
| `store.metadata.v1` | Store | `InspectArchive`, `GetPackageMetadata`, `ListManagedPackages` |
| `store.icon.v1` | Store | `RenderIcon` |
| `store.rollback.v1` | Store | `InstallRequest.enable_rollback`, `RollbackPackage` |
| `store.ownership.v1` | Store | `InstallRequest.request_update_ownership`, `RelinquishUpdateOwnership` |
| `store.constraints.v1` | Store | `CheckInstallConstraints` |

### 5.4 Session token and stream binding

- The host creates a new random `session_token` for each **control** connection (guest control and store control) and sends it in `HelloAck`.
- The secondary connections of the same agent (input, bulk, artifacts, development IME) receive the same token in their `HelloAck`. The agent rejects a secondary connection with `BAD_TOKEN` when the token does not match its current control session.
- When the control connection closes, the agent closes that session's secondary connections, resets input state ([input.md](input.md) §7.3), and aborts bulk transfers. Android-side settings (density, IME policy) stay as they are. The host re-applies them after the next snapshot.
- A second control connection while one is open is rejected with `DUPLICATE_SESSION`, unless the old one has been silent for more than 15 s. Then the agent closes the old one and accepts the new one, which covers a crashed apkrund whose socket was not closed cleanly.
- Who enforces each rule: `Hello` has no token field, and `Rejected` exists only inside `HelloAck`. So the host enforces the major version and the channel, and answers with `Rejected`. The agent enforces `BAD_TOKEN` and `DUPLICATE_SESSION` on its control session. It closes the connection, logs the reason, and sends no `Rejected`.

---

## 6. Requests, events, and liveness

- **Pipelining:** the host may have up to 64 requests in flight per control connection. Responses may arrive in any order. The agent processes requests concurrently unless an operation says otherwise. Operations on the same display (`SetDisplayPolicy`, `LaunchApplication`, `ClearDisplay`, `MoveTaskToDisplay`) are serialized per display inside the agent.
- **Default timeouts** (host side, `Request.timeout_ms`): 5 s. `LaunchApplication` 15 s, `ClearDisplay` 5 s ([display-and-windowing.md](display-and-windowing.md) §3.4), `Shutdown` 20 s, `CollectDiagnostics` 60 s, `CommitInstall` and `Uninstall` 120 s. A host timeout produces `GuestProtocolFailure.timeout(operation)`. The connection stays open.
- **Late answers:** an answer that arrives after its deadline is discarded, and the connection stays open. Only an answer whose id the host never sent is a protocol violation.
- **Events** are delivered in order per connection. A response is sent only after all events caused by earlier requests. For example, after `SetDisplayPolicy` returns, the matching `DisplayChanged` (new density) has already been sent.
- **Keepalive:** the host sends `Ping` every 5 s on each control connection. Three consecutive missed `Pong`s (15 s) mark the agent `unresponsive`. The host then closes the connection and reconnects with backoff (100 ms doubling to 2 s, [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1). Secondary connections have no pings. They follow the control connection.
- **Resync:** after every control handshake the host sends `GetSnapshot` before anything else and replaces its view of guest state with the result. Events received before the snapshot response are buffered and applied afterwards if their state is newer. Display and task events carry the IDs needed to deduplicate.

---

## 7. Guest Agent control operations

### 7.1 Operation catalogue

Numbers are the `Request.op` and `Response.result` field numbers.

| # | Operation | Request | Result | Capability | Notes |
|---|---|---|---|---|---|
| 10 | `Ping` | `nonce` | `Pong{nonce, guest_uptime_ms}` | `core.v1` | keepalive (§6) |
| 11 | `GetSnapshot` | — | `Snapshot` (§7.2) | `core.v1` | sent after every handshake |
| 12 | `SetDisplayPolicy` | `display_id`, `density_dpi`, `ime_policy` (`LOCAL`, `FALLBACK_DISPLAY`, `HIDE`) | `Empty` | `display.v1` | [display-and-windowing.md](display-and-windowing.md) §4. Density: `setForcedDisplayDensityForUser`. IME policy: `setDisplayImePolicy` |
| 13 | `ClearDisplay` | `display_id`, `policy` (`FINISH_TASKS`, `MOVE_TO_DEFAULT_DISPLAY`) | `Empty`, then event `TasksCleared` | `display.v1` | close policies `stop` and `keepRunning` ([display-and-windowing.md](display-and-windowing.md) §7.6) |
| 14 | `LaunchApplication` | `package`, optional `component`, `display_id`, optional `data_uri` and `action`, `mode` (`BRING_TO_FRONT_OR_START`, `CLEAR_TASK`) | `LaunchResult{task_id, component, outcome: STARTED / BROUGHT_TO_FRONT / MOVED_FROM_DISPLAY}` | `launch.v1` | resolves the component with `PackageManager.getLaunchIntentForPackage`. Options: [display-and-windowing.md](display-and-windowing.md) §4. A task on another display is moved (`MOVED_FROM_DISPLAY`) |
| 15 | `StopApplication` | `package`, `mode` (`FINISH_TASKS`, `FORCE_STOP`) | `Empty` | `launch.v1` | `FINISH_TASKS`: `removeTask` per task of the package. `FORCE_STOP`: `IActivityManager.forceStopPackage` |
| 16 | `MoveTaskToDisplay` | `task_id`, `display_id`, `to_back` | `Empty` | `launch.v1` | `moveRootTaskToDisplay`. Used by `keepRunning` and by resize fallback A ([display-and-windowing.md](display-and-windowing.md)) |
| 17 | `ListTasks` | optional `display_id` | `repeated TaskInfo` | `launch.v1` | |
| 18 | `FocusDisplay` | `display_id` | `Empty` | `input.v1` | focuses the top task of the display (`setFocusedTask`, [input.md](input.md) §7.2) |
| 19 | `QueryPackage` | `package` | `PackageInfo` or `NOT_FOUND` | `packages.v1` | §7.3 |
| 20 | `ListPackages` | `filter` (`LAUNCHABLE`, `USER_INSTALLED`, `ALL`) | `repeated PackageSummary` | `packages.v1` | |
| 21 | `GetHealth` | — | `Health` (§7.4) | `health.v1` | `apkrun doctor` ([diagnostics.md](diagnostics.md)) |
| 40 | `SetClipboard` | `ClipData` (§8.4) | `Empty` | `clipboard.*` | [desktop-integration.md](desktop-integration.md) |
| 41 | `ActivateNotification` | `key`, optional `action_index`, `display_id` | `Empty` | `notifications.v1` | sends the content or action intent on launch display `display_id`. `NOT_FOUND` when the notification is gone; the host then launches the app normally ([desktop-integration.md](desktop-integration.md) §5.4) |
| 42 | `DismissNotification` | `key` | `Empty` | `notifications.v1` | `cancelNotification(key)` |
| 43 | `SetNotificationForwarding` | `repeated string packages` | `Empty` | `notifications.v1` | only these packages' notifications leave the guest. Afterwards the agent sends `NotificationPosted` with `replay = true` for each of their active notifications (§8.4) |
| 44 | `SetUrlRedirect` | `enabled`, `repeated string excluded_packages` | `Empty` | `url.v1` | links of excluded packages go to the in-Android browser without an event |
| 45 | `ImportFiles` | `target` (`DOWNLOADS`, `SHARE_TO_PACKAGE`), optional `package`, `display_id`, `repeated FileRef` (bulk transfer ID, name, MIME type, size) | `ImportResult{repeated content_uri, disposition: SHARED / SAVED_TO_DOWNLOADS}` | `files.v1` | `SHARE_TO_PACKAGE` falls back to Downloads when the package has no send target ([desktop-integration.md](desktop-integration.md) §6.2) |
| 46 | `SetLocale` | `repeated string bcp47` | `Empty` | `locale.v1` | |
| 47 | `SetTimeZone` | `tz_id` (IANA) | `Empty` | `locale.v1` | |
| 48 | `SyncTime` | `unix_time_ms`, `rtt_ms` | `Empty` | `locale.v1` | sent after host wake, every 30 min, and after a host clock change. Applied when the difference is over 500 ms. Privileged app only; `UNSUPPORTED` in development mode |
| 49 | `SetClockFormat` | `format` (`TWELVE`, `TWENTY_FOUR`) | `Empty` | `locale.v1` | `Settings.System.TIME_12_24` |
| 50 | `ResolveUrl` | `request_id`, `action` (`OPENED_ON_HOST`, `OPEN_IN_GUEST`, `DROP`) | `Empty` | `url.v1` | answers `OpenUrlOnHost`. `OPEN_IN_GUEST` starts the kept intent in the in-Android browser. Kept intents expire after 60 s (`NOT_FOUND`) |
| 51 | `ResolveExport` | `offer_id`, `decision` (`ACCEPT`, `DECLINE`) | `ExportStart{transfer_id}` or `Empty` | `files.v1` | answers `ExportFileOffered`. On `ACCEPT` the agent sends the file on the bulk stream |
| 52 | `SetSharedFolderAccess` | `repeated SharedRoot roots` (`root_id`, `title`, `max_access`), `repeated PackageAccess access` (`package`, `READ_ONLY` / `READ_WRITE`) | `Empty` | `files.shared.v1` | replaces the whole list. Unlisted packages have no access. The provider notifies `DocumentsContract` root changes |
| 53 | `SetMicrophoneAccess` | `repeated string packages` | `Empty` | `audio.v1` | `OP_RECORD_AUDIO` is `MODE_IGNORED` for every other user-installed package ([desktop-integration.md](desktop-integration.md) §8.2) |
| 70 | `Shutdown` | `reason` | `Empty`, then the VM powers off | `system.v1` | `PowerManager.shutdown` ([vm.md](vm.md) §9.3) |
| 71 | reserved | — | — | — | not used. Developer mode is the boot parameter `androidboot.apkrun.devmode`, set by the host before each start ([android-image.md](android-image.md) §11.3). No guest operation changes it |
| 72 | `AuthorizeAdbKey` | `public_key` (adbkey.pub format) | `Empty` | `system.v1` | `AdbManager.allowDebugging` on `user` builds |
| 73 | `CollectDiagnostics` | `repeated DiagnosticsItem` (`GETPROP` (allowlisted properties only, [diagnostics.md](diagnostics.md) §6.2), `LOGCAT`, `DUMPSYS_WINDOW`, `DUMPSYS_DISPLAY`, `DUMPSYS_INPUT`, `DUMPSYS_ACTIVITY`, `DUMPSYS_SURFACEFLINGER`, `DUMPSYS_MEMINFO`, `TOMBSTONE_LIST`, `AGENT_LOG`), `max_bytes` | `CollectDiagnosticsResult{repeated DiagnosticsItemResult{item, status, transfer_id, truncated}}`, one entry per requested item. `status` is `OK`, `UNSUPPORTED` (an item the agent does not know), `TOO_LARGE`, or `FAILED`. `transfer_id` is set only with `OK`. An item status other than `OK` does not fail the request | `diagnostics.v1` | payloads go over the bulk stream (§10), truncated at `max_bytes` (`truncated = true`). The host enforces a 16 MiB cap per item and the 60 s timeout. Redaction happens on the host ([diagnostics.md](diagnostics.md)) |

In development mode (`AgentMode.DEVELOPMENT_SHELL`) the agent runs with the shell uid's permissions. Operations that need more privilege answer `UNSUPPORTED` there, and `Hello` does not list them as capabilities. The per-operation privileges are in [guest-components.md](guest-components.md) §5.

### 7.2 Snapshot

```proto
message Snapshot {
  SystemState system = 1;                 // boot_completed, user_unlocked, android uptime
  repeated DisplayInfo displays = 2;
  repeated TaskInfo tasks = 3;
  int32 focused_display_id = 4;
  bool ime_selected = 5;                  // APKRun IME is the default IME
  bool notification_listener_enabled = 6;
  uint64 clipboard_seq = 7;               // the agent's current clip sequence (§8.4)
}

message DisplayInfo {
  int32 display_id = 1;
  string unique_id = 2;                   // Display.getUniqueId (stable per connector)
  string name = 3;
  DeviceProductInfo product = 4;          // manufacturer_pnp_id ("APK"), product_id (scanout index), model_year, name
  DisplayMode mode = 5;                   // width_px, height_px, refresh_hz
  int32 density_dpi = 6;                  // current effective density
  int32 rotation = 7;                     // Surface.ROTATION_*
  DisplayState state = 8;                 // ON, OFF, UNKNOWN
  float vertical_scroll_factor_dp = 9;    // input.md §4.4
  float horizontal_scroll_factor_dp = 10;
  uint32 flags = 11;                      // Display.FLAG_* as reported
}

message TaskInfo {
  int32 task_id = 1;
  int32 display_id = 2;
  string package = 3;
  string base_component = 4;
  string top_component = 5;
  int32 windowing_mode = 6;
  bool visible = 7;
}
```

### 7.3 PackageInfo (Guest Agent view)

`PackageInfo{ package, version_code (int64), version_name, label (default locale), enabled, launchable_component, installer_package, first_install_time_ms, last_update_time_ms, target_sdk, min_sdk, signing_sha256 (repeated, current signers) }`.

The Store Agent's `GetPackageMetadata` (§11.1) returns more, including the update owner and signing lineage. `QueryPackage` exists so that launch and diagnostics work on stock images, which have no Store Agent.

### 7.4 Health

`Health{ agent_uptime_ms, mode, displays_count, ime_selected, notification_listener_enabled, adb_enabled, memory: {total_kb, available_kb, low_memory}, last_error (GuestError), input: {batches, events_injected, events_rejected}, open_sessions }`. `apkrun doctor` maps it to health checks ([diagnostics.md](diagnostics.md)).

### 7.5 Agent → host file operations (`files.shared.v1`)

The agent sends these requests to the host. They serve `MacFilesProvider`, the Android document provider for the Mac shared folders ([desktop-integration.md](desktop-integration.md) §6.4). They travel on the guest bulk channel (6102), so file data never delays control traffic. The host still opens the connection ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1).

| # | Operation | Request | Result |
|---|---|---|---|
| 60 | `HostListRoots` | `package` | `repeated RootInfo{root_id, title, access (READ_ONLY / READ_WRITE), available, bytes_free}` |
| 61 | `HostQueryChildren` | `package`, `root_id`, `path`, `page_token` | `repeated DocInfo{path, name, is_dir, size, mtime_ms, mime_type}`, `next_page_token` (4096 entries per page) |
| 62 | `HostStat` | `package`, `root_id`, `path` | `DocInfo` |
| 63 | `HostOpenFile` | `package`, `root_id`, `path`, `mode` (`READ`, `WRITE`, `READ_WRITE`, `TRUNCATE`) | `OpenFile{handle, size}` |
| 64 | `HostReadRange` | `handle`, `offset`, `length` (≤ 1 MiB) | `bytes data` (shorter at end of file) |
| 65 | `HostWriteRange` | `handle`, `offset`, `bytes data` (≤ 1 MiB) | `Empty` |
| 66 | `HostCloseFile` | `handle`, `fsync` | `Empty` |
| 67 | `HostCreateDocument` | `package`, `root_id`, `parent_path`, `name`, `is_dir` | `DocInfo` (the name is made unique, as Android's providers do) |
| 68 | `HostDeleteDocument` | `package`, `root_id`, `path` | `Empty` |
| 69 | `HostRenameDocument` | `package`, `root_id`, `path`, `new_name` | `DocInfo` |

- `package` is the Android package that called the provider (`getCallingPackage()`), or `com.android.documentsui` while the user browses in the picker. The host checks it against its own settings on every request and does not trust the agent's access list.
- `path` is relative to the root, uses `/` separators, and never contains `..`. The host resolves it itself ([desktop-integration.md](desktop-integration.md) §6.4) and answers `PERMISSION_DENIED` or `NOT_FOUND` otherwise.
- Handles are host-allocated, valid for the bulk connection that opened them, and closed when it closes. At most 64 open handles per package (`RESOURCE_EXHAUSTED`).
- The agent may have up to 16 of these requests in flight. The host answers in any order.

---

## 8. Guest Agent events

### 8.1 Catalogue

| # | Event | Payload | Capability | Consumer |
|---|---|---|---|---|
| 10 | `SystemStateChanged` | `SystemState` | `core.v1` | RuntimeCore readiness ([state-machines.md](../01-architecture/state-machines.md) §2) |
| 11 | `DisplayAdded` | `DisplayInfo` | `display.v1` | `DisplayPool` ([display-and-windowing.md](display-and-windowing.md) §3.3) |
| 12 | `DisplayChanged` | `DisplayInfo` | `display.v1` | `DisplayPool`, InputCore scroll factors |
| 13 | `DisplayRemoved` | `display_id` | `display.v1` | `DisplayPool` |
| 14 | `TaskAppeared` | `TaskInfo` | `launch.v1` | SessionRegistry |
| 15 | `TaskChanged` | `TaskInfo` (moved display, visibility, top activity) | `launch.v1` | SessionRegistry |
| 16 | `TaskVanished` | `task_id`, `display_id`, `package` | `launch.v1` | SessionRegistry |
| 17 | `DisplayEmpty` | `display_id` | `launch.v1` | SessionRegistry → `.appExited` ([display-and-windowing.md](display-and-windowing.md) §7.6) |
| 18 | `TasksCleared` | `display_id`, `remaining_tasks` | `display.v1` | `DisplayPool` release ([display-and-windowing.md](display-and-windowing.md) §3.4) |
| 19 | `FocusedDisplayChanged` | `display_id` | `input.v1` | diagnostics only |
| 20 | `PackageChanged` | `package`, `kind` (`ADDED`, `REPLACED`, `REMOVED`, `CHANGED`), `version_code` | `packages.v1` | APKStoreCore reconcile on stock images. The Store Agent sends the same event on custom images |
| 21 | `HealthWarning` | `kind` (`LOW_MEMORY`, `IME_NOT_SELECTED`, `NOTIFICATION_LISTENER_DISABLED`, `BROWSER_ROLE_LOST`, `DISPLAY_POLICY_LOST`), `detail` | `health.v1` | health |
| 22 | `AppProcessEvent` | `package`, `kind` (`CRASH`, `ANR`, `NATIVE_CRASH`), `pid`, `short_message` | `health.v1` | session placeholder ("‹App› stopped"), diagnostics. Observed with `IActivityController`, as `am monitor` does |
| 40 | `ClipboardChanged` | `ClipData` | `clipboard.*` | IntegrationCore |
| 41 | `NotificationPosted` | `Notification` (§8.4) | `notifications.v1` | IntegrationCore |
| 42 | `NotificationRemoved` | `key`, `reason` | `notifications.v1` | IntegrationCore |
| 43 | `OpenUrlOnHost` | `request_id`, `url`, `source_package` (from `getLaunchedFromPackage()`), `display_id` | `url.v1` | IntegrationCore `LinkForwarder`, answered with `ResolveUrl` ([desktop-integration.md](desktop-integration.md) §7) |
| 44 | `ExportFileOffered` | `offer_id`, `name`, `mime_type`, `size`, `source_package`, `display_id` | `files.v1` | IntegrationCore, answered with `ResolveExport` ([desktop-integration.md](desktop-integration.md) §6.3) |
| 45 | `RecordingChanged` | `repeated string packages` (active recorders) | `audio.v1` | IntegrationCore, menu bar indicator ([desktop-integration.md](desktop-integration.md) §8.2) |

### 8.2 Display event rules

- `DisplayAdded` is sent once for every non-private display that Android reports through `DisplayManager.DisplayListener.onDisplayAdded`. Display 0 is included in the snapshot.
- `DisplayChanged` is sent when the mode, density, rotation, or state changes. Changes are coalesced per display over 16 ms.
- The agent reports what Android reports. It does not map displays to scanouts. `DisplayPool` correlates them through `DeviceProductInfo` ([display-and-windowing.md](display-and-windowing.md) §3.3).

### 8.3 Task event rules

- The agent uses `ITaskStackListener` (task created, removed, moved to front, display changed) and confirms with `IActivityTaskManager.getTasks`. `TaskChanged` is coalesced per task over 16 ms.
- `DisplayEmpty` is sent when the last task on a display other than 0 vanishes. It is not sent for a display that `ClearDisplay` is clearing; `TasksCleared` is sent instead.

### 8.4 Integration payloads

```proto
message ClipData {
  uint64 seq = 1;                 // sender's sequence number
  ClipOrigin origin = 2;          // HOST or GUEST; the agent ignores its own writes echoed back (loop prevention)
  string text = 3;                // up to 1 MiB; larger text is truncated with a flag
  bool truncated = 4;
  string html = 5;                // optional, same limit
  ClipImage image = 6;            // clipboard.image.v1: mime_type, width, height, transfer_id on the bulk stream
  string source_package = 7;      // guest → host only
  bool sensitive = 8;             // ClipDescription.EXTRA_IS_SENSITIVE; the host marks the pasteboard item concealed
}

message Notification {
  string key = 1;                 // StatusBarNotification key
  string package = 2;
  string title = 3;               // at most 256 characters
  string text = 4;                // at most 2048 characters
  int64 when_ms = 5;
  string category = 6;
  bool has_content_intent = 7;
  repeated NotificationAction actions = 8;   // title only; no remote input in v1
  bool ongoing = 9;
  string channel_id = 10;
  int32 importance = 11;
  string group_key = 12;          // Notification.getGroup(); empty when not grouped
  bool alert = 13;                // false for an update with FLAG_ONLY_ALERT_ONCE
  bool replay = 14;               // re-sent after SetNotificationForwarding; the host rebuilds state, posts no new banner
}
```

- The agent never sends group summaries, ongoing notifications, or `IMPORTANCE_MIN` notifications ([desktop-integration.md](desktop-integration.md) §5.1). `ongoing` stays in the schema for later use.
- Loop prevention, clipboard size policy, notification grouping, and what the host does with each field are in [desktop-integration.md](desktop-integration.md). The protocol only carries the data.

---

## 9. Input stream

The semantics are in [input.md](input.md). The wire messages are:

```proto
message InputBatch {
  uint64 batch_seq = 1;
  int32 display_id = 2;           // stamped by InputRouter, never by the wrapper
  uint64 host_send_nanos = 3;     // for host-side latency accounting only
  bool ack_requested = 4;         // every 32nd batch; diagnostic mode requests each batch
  repeated InputEvent events = 5; // at most 256 per batch
  bool trace_event_time = 6;      // request guest MotionEvent.eventTime in this ACK; capability-gated
}

message InputEvent {
  uint64 host_time_nanos = 1;     // relative spacing is preserved by the injector
  oneof kind {
    TouchEvent touch = 10;        // phase DOWN/MOVE/UP/CANCEL, pointer_id, x, y (display px, float)
    MouseEvent mouse = 11;        // action HOVER_ENTER/HOVER_MOVE/HOVER_EXIT/PRESS/RELEASE, button, button_state, x, y
    ScrollEvent scroll = 12;      // x, y, vscroll, hscroll (Android axis units)
    KeyEvent key = 13;            // action DOWN/UP, key_code, meta_state, repeat_count
    LongPress long_press = 14;    // x, y
    CancelAll cancel_all = 15;
  }
}

message InputAck {
  uint64 batch_seq = 1;
  uint32 receive_to_inject_micros = 2;
  uint32 rejected_events = 3;
  optional uint64 last_event_time_millis = 4; // Android uptime eventTime; input.ack_trace.v1 only
}

message ImeCommand {
  uint64 seq = 1;
  int32 display_id = 2;
  oneof kind {
    string commit_text = 10;                       // at most 4 KiB UTF-8
    Composing set_composing = 11;                  // text, selection_start, selection_end (relative to the text)
    FinishComposing finish_composing = 12;
    KeyEvent key = 13;                             // sent through InputConnection.sendKeyEvent
    int32 editor_action = 14;                      // EditorInfo.IME_ACTION_*
    ContextMenuAction context_menu_action = 15;    // COPY, CUT, PASTE, SELECT_ALL
  }
}

message ImeState {                                 // guest → host; never contains the field's text
  bool editor_focused = 1;
  int32 display_id = 2;
  string package = 3;
  int32 input_type = 4;
  int32 ime_options = 5;
  int32 selection_start = 6;
  int32 selection_end = 7;
  int32 composing_start = 8;                       // -1 when there is no composition
  int32 composing_end = 9;
  Rect cursor_rect_px = 10;                        // display pixels; empty when unknown
}
```

- The input stream has no request/response pairs. A validation failure drops the offending event and is reported as a count in the next `InputAck` and in `Health.input`. It does not close the stream (§12.2 lists what does).
- `last_event_time_millis` is an optional field of protocol 1.1, for diagnostics. The guest sets it only when `input.ack_trace.v1` was negotiated, `trace_event_time` and `ack_requested` are true for that batch, and the batch has an accepted `MotionEvent`. Ordinary periodic ACKs do not request or carry it. An ACK proves queue injection acceptance, not Android view dispatch or app action.
- The IME coalesces `ImeState` updates to at most one per 16 ms. A change of `editor_focused` is sent immediately.

---

## 10. Bulk and artifact streams

```proto
message BulkFrame {
  uint64 transfer_id = 1;         // host-allocated IDs are even, agent-allocated IDs are odd
  oneof kind {
    BulkBegin begin = 10;         // kind, name, mime_type, size, sha256 (optional here), context (e.g. install_id)
    bytes chunk = 11;             // at most 1 MiB, in order
    BulkEnd end = 12;             // sha256 (required if not given in begin)
    BulkAck ack = 13;             // receiver → sender after end: OK, HASH_MISMATCH, TOO_LARGE, REJECTED
    BulkAbort abort = 14;         // either side; reason
  }
}
```

- A transfer is announced on the control channel. For example, `ImportFiles` lists transfer IDs, and `CollectDiagnostics` returns them. The data then flows on the bulk stream in either direction. At most 4 transfers are interleaved per stream, chunk by chunk.
- Limit: 2 GiB per transfer. The receiver writes to a temporary file: on the host under `~/Library/Caches/io.apkrun.APKRun/transfers/`, on the guest in the agent's cache directory or directly into a `PackageInstaller` session for install artifacts (§11.3). Incomplete transfers are deleted when the stream closes.
- Flow control is the stream's own (vsock or TCP back-pressure). Senders do not read whole files into memory.
- The artifact stream (6111) uses the same messages with the Store Agent. Its kinds are `INSTALL_ARTIFACT` (host → guest) and `ICON_LAYER` (guest → host).

---

## 11. Store Agent protocol

The install and update flows that use these messages are in [package-store.md](package-store.md) and [update-system.md](update-system.md). The Store Agent exists only on custom images. On stock images APKStoreCore uses the ADB implementation of `StoreAgentChannel` (§13.2).

### 11.1 Operations

| # | Operation | Request | Result | Capability |
|---|---|---|---|---|
| 100 | `InspectArchive` | `repeated ArtifactRef` (transfer IDs already sent with kind `INSTALL_ARTIFACT` and context `inspect`) | `ArchiveInfo` | `store.metadata.v1` |
| 101 | `BeginInstall` | `InstallRequest` (§11.3) | `BeginInstallResult{install_id, android_session_id}` | `store.install.v1` |
| 102 | `CommitInstall` | `install_id` | `Empty` (the outcome arrives as `InstallFinished`) | `store.install.v1` |
| 103 | `AbandonInstall` | `install_id` | `Empty` | `store.install.v1` |
| 104 | `Uninstall` | `package`, `keep_data` | `UninstallResult{status, message}` | `store.install.v1` |
| 105 | `GetPackageMetadata` | `package` | `StorePackageInfo` (§11.4) | `store.metadata.v1` |
| 106 | `ListManagedPackages` | `filter` (`MANAGED_BY_APKRUN`, `ALL_USER_INSTALLED`) | `repeated StorePackageInfo` | `store.metadata.v1` |
| 107 | `RenderIcon` | `package`, `size_px` (up to 1536; the host asks for 1536 so that the inner 72 dp are exactly 1024 px, [wrapper.md](wrapper.md) §8.1) | `IconResult{kind: ADAPTIVE / LEGACY, repeated IconLayer{role: FOREGROUND/BACKGROUND/MONOCHROME/LEGACY, transfer_id}}` | `store.icon.v1` |
| 108 | `RollbackPackage` | `package`, `from_version_code`, `to_version_code` | `RollbackResult{status: SUCCESS / NOT_AVAILABLE / FAILURE, message, installed_version_code}`. The agent finds the matching entry in `RollbackManager.getAvailableRollbacks()` and calls `commitRollback`. `NOT_AVAILABLE` when there is none (no rollback was enabled at install, or it expired) | `store.rollback.v1` |
| 109 | `RelinquishUpdateOwnership` | `package` | `Empty`. Calls `PackageManager.relinquishUpdateOwnership(package)` (API 34). `FAILED_PRECONDITION` when the Store Agent is not the update owner | `store.ownership.v1` |
| 110 | `CheckInstallConstraints` | `repeated string packages`, `constraints` (`GENTLE_UPDATE`), `app_not_foreground_required`, `app_not_interacting_required`, `app_not_top_visible_required` | `ConstraintsResult{repeated PackageConstraint{package, satisfied}}`. Calls `PackageInstaller.checkInstallConstraints(packages, constraints, executor, callback)` with `InstallConstraints` (API 34) built from the flags, 10 s timeout. A hint only: the gentle-update gate re-evaluates before each install ([update-system.md](update-system.md) §7) | `store.constraints.v1` |

### 11.2 Events

| # | Event | Payload |
|---|---|---|
| 100 | `InstallProgress` | `install_id`, `stage` (`RECEIVING`, `VERIFYING`, `COMMITTING`), `fraction` |
| 101 | `InstallFinished` | `install_id`, `status` (`SUCCESS`, `FAILURE`, `ABORTED`, `INCOMPATIBLE`, `CONFLICT`, `STORAGE`, `INVALID`, `BLOCKED`, `USER_ACTION_REQUIRED`), `android_status` (`PackageInstaller.STATUS_*`), `legacy_status` (`INSTALL_FAILED_*` name when known), `message`, `installed_version_code` |
| 102 | `PackageChanged` | as §8.1 event 20 |

### 11.3 InstallRequest and artifact streaming

```proto
message InstallRequest {
  string expected_package = 1;
  int64 expected_version_code = 2;            // 0 = do not check
  repeated bytes expected_signer_sha256 = 3;  // host-verified signer digests; empty when verification is deferred to Android
  InstallMode mode = 4;                       // INSTALL_NEW, UPDATE, REINSTALL
  bool request_update_ownership = 5;          // SessionParams.setRequestUpdateOwnership (API 34)
  bool allow_downgrade = 6;                   // always false in v1; the field exists so the refusal is explicit
  repeated ArtifactSpec artifacts = 7;        // name ("base", "split_config.arm64_v8a", …), size, sha256
  int32 install_reason = 8;                   // PackageManager.INSTALL_REASON_USER
  int32 package_source = 9;                   // PackageInstaller.PACKAGE_SOURCE_OTHER
  bool enable_rollback = 10;                  // SessionParams.setEnableRollback(true, ROLLBACK_DATA_POLICY_RETAIN); UPDATE mode only
}
```

1. `BeginInstall` creates a `PackageInstaller` session (`MODE_FULL_INSTALL`) and returns `install_id`. `request_update_ownership` needs `store.ownership.v1`, and `enable_rollback` needs `store.rollback.v1`. The agent answers `INVALID_ARGUMENT` when a field is set without its capability, when `enable_rollback` is set with a mode other than `UPDATE`, or when `allow_downgrade` is `true`.
2. The host streams each artifact on 6111 with `BulkBegin{kind: INSTALL_ARTIFACT, context: install_id, name, size, sha256}`. The agent writes the chunks to both `session.openWrite(name, 0, size)` and an app-private per-install verification copy, while hashing them as they arrive. A hash mismatch abandons the session and answers `BulkAck{HASH_MISMATCH}`.
3. `CommitInstall`. Before committing, the agent checks the complete app-private copies with Android's own parser against `expected_package`, `expected_version_code`, and `expected_signer_sha256` when the host supplied signer digests. Android must report at least one signer. The copies contain the same bytes streamed into the PackageInstaller session. A mismatch finishes with `INVALID` and a message; a match commits the session, where Android verifies the APK signature. The copies are deleted after validation and any leftovers are removed when the Store Agent starts.
4. `InstallFinished` reports the outcome from the session's status receiver. The Store Agent holds `INSTALL_PACKAGES` as a privileged app, so `STATUS_PENDING_USER_ACTION` is not expected. If it happens, the agent abandons the session and reports `USER_ACTION_REQUIRED`. It never shows UI on a display the user may not see.

The agent abandons sessions that are not committed within 10 minutes, and sessions whose control connection closes.

### 11.4 StorePackageInfo

`StorePackageInfo{ package, version_code, version_name, label, installer_of_record, update_owner, initiating_package, first_install_time_ms, last_update_time_ms, min_sdk, target_sdk, splits[], native_abis[], signing: {current_sha256[], past_sha256[] (lineage), scheme_version}, enabled, suspended, requested_permissions_count, launchable_component }`.

`update_owner` comes from `InstallSourceInfo.getUpdateOwnerPackageName()` (API 34). APKStoreCore uses it to confirm that APKRun owns updates for the packages it manages ([update-system.md](update-system.md)). `launchable_component` is Android's flattened launcher `ComponentName`, or empty when the package has no enabled launcher activity.

---

## 12. Errors

### 12.1 GuestError

```proto
message GuestError {
  GuestErrorCode code = 1;
  string message = 2;                  // English, for developers and logs; no user data
  map<string, string> detail = 3;      // for example "android_exception" → class name, "status" → code
}

enum GuestErrorCode {
  GUEST_ERROR_CODE_UNSPECIFIED = 0;
  INVALID_ARGUMENT = 1;
  NOT_FOUND = 2;                       // package, display, task, notification key, transfer
  ALREADY_EXISTS = 3;
  PERMISSION_DENIED = 4;               // Android refused (SecurityException)
  FAILED_PRECONDITION = 5;             // e.g. boot not completed, display being cleared
  UNAVAILABLE = 6;                     // a system service is not ready
  TIMEOUT = 7;
  CANCELLED = 8;
  UNSUPPORTED = 9;                     // capability not enabled, or not possible in this AgentMode
  RESOURCE_EXHAUSTED = 10;             // too many in-flight requests or sessions
  INTERNAL = 11;
}
```

On the host, `GuestError` becomes `GuestProtocolFailure.remote(code, message, operation)`. Callers translate the cases they understand into their own domain. For example, `NOT_FOUND` on `LaunchApplication` becomes `RuntimeFailure.packageNotInstalled`. The mapping is in [error-catalog.md](../03-reference/error-catalog.md).

### 12.2 Protocol violations

These close the connection. They are logged with the Envelope id, never the payload:

- a frame that is too large, empty, or does not decode;
- a body that is not allowed on the channel (§3), or any frame before the handshake;
- a non-increasing `Envelope.id` or a gap in `Event.seq`;
- a `response` whose `reply_to` does not match an outstanding request;
- a `request` from the agent on any channel other than guest bulk, or with an operation outside 60–69 (§7.5).

The host reports `GuestProtocolFailure.malformedFrame` and reconnects with backoff. The `GuestAgentSupervisor` counts the closes that are protocol violations (`malformedFrame` and `frameTooLarge`). Five violations within 10 minutes stop reconnecting. Health `agent.guest` or `agent.store` then fails with `runtime.requiredAgentUnavailable` ([runtime-daemon.md](runtime-daemon.md) §12). Other closes reconnect with backoff, within the restart budget of [guest-components.md](guest-components.md) §3.3.

### 12.3 Host error domain

`GuestProtocolFailure` cases: `incompatibleVersion(host, guest)`, `handshakeFailed(reason)`, `handshakeTimedOut`, `disconnected`, `timeout(operation)`, `remote(code, message, operation)`, `frameTooLarge`, `malformedFrame`, `capabilityMissing(capability)`, `agentUnavailable(kind)`. Codes and remediations are in [error-catalog.md](../03-reference/error-catalog.md).

---

## 13. Host-side API (GuestProtocol and RuntimeCore)

### 13.1 Connection layer

```swift
public enum GuestEndpoint: Sendable, Hashable {
    case guestControl, guestInput, guestBulk, storeControl, storeArtifacts, developmentIME
}

public protocol GuestTransport: Sendable {
    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream
}

public struct VsockGuestTransport: GuestTransport { /* VZVirtioSocketDevice.connect(toPort:), ports from process-model §3.1 */ }
public struct ADBForwardGuestTransport: GuestTransport { /* §13.2 */ }

public actor GuestConnection {
    public init(endpoint: GuestEndpoint, transport: any GuestTransport, token: SessionToken?)
    public func open() async throws -> GuestHello                        // handshake, §5
    public func send<Op: GuestOperation>(_ op: Op, timeout: Duration?) async throws -> Op.Result
    public func send(frame: GPEnvelope) async throws                     // input and bulk streams
    public nonisolated var events: AsyncStream<GPEvent> { get }
    public func close() async
}
```

- `GuestOperation` is a small protocol with one struct per operation. It pairs the request oneof case with its result type. Call sites are typed, and the numbering rule (§4.1) is checked in one place.
- `GuestAgentSupervisor` (RuntimeCore, actor) owns the control, input, and bulk connections of the Guest Agent. It does the reconnection, keepalive, and resync (§6). It exposes typed facades: `DisplayControlChannel` ([display-and-windowing.md](display-and-windowing.md) §3.1), `AndroidControlChannel` (launch, stop, tasks, packages, health, shutdown), the input sink used by `InputRouter`, and `IntegrationChannel`.
- `StoreAgentSupervisor` does the same for the Store Agent and implements `StoreAgentChannel` for APKStoreCore.

### 13.2 Development transport (ADB forward)

- `ADBForwardGuestTransport` runs `adb -s 127.0.0.1:6520 forward tcp:0 localabstract:<name>` with the `adb` of the developer's platform-tools ([environment-setup.md](../05-development/environment-setup.md)). It reads the allocated port from stdout and connects to `127.0.0.1:<port>`. When the stream closes, it removes the forward with `adb -s 127.0.0.1:6520 forward --remove tcp:<port>`. In Debug builds only, forwards left over from a crash are removed at startup. List them with `adb -s 127.0.0.1:6520 forward --list`, then remove the TCP locals whose serial is `127.0.0.1:6520` and whose remote starts with `localabstract:apkrun-`.
- This is one `adb` process per **connection**, not per message. It satisfies FR-IN-06.
- `ADBStoreAgentChannel` covers stock images. It runs `adb install-multiple -r --no-streaming` (the `-g` flag is not used), `pm uninstall` (`-k` to keep data), and reads metadata from the Guest Agent's `QueryPackage`. It cannot set update ownership, enable Android rollbacks, inspect archives, or render icons. APKStoreCore treats those as missing capabilities (`capabilityMissing`), not as errors. On debuggable images (`ro.debuggable=1`, the stock `userdebug` image) it offers rollback as a downgrade reinstall, `adb install-multiple -r -d` ([package-store.md](package-store.md) §7.3).

### 13.3 Which implementation is used

| Build and image | Guest Agent | Store Agent |
|---|---|---|
| M3–M4, stock image | `ADBForwardGuestTransport` | `ADBStoreAgentChannel` |
| M4, stock userdebug image with the bridge pushed and run as root (#35 validation only) | `VsockGuestTransport` | `ADBStoreAgentChannel` |
| M5+, custom image | `VsockGuestTransport` | `VsockGuestTransport` (store endpoints) |
| M5+, custom image, developer mode | vsock by default. `apkrun dev … --guest-transport adb` forces ADB for debugging | same |

---

## 14. Security and limits

| Limit | Value | Enforced by |
|---|---|---|
| Frame size | 4 MiB | both codecs |
| In-flight requests per control connection | 64 (`RESOURCE_EXHAUSTED` above) | agent |
| String fields | 64 KiB unless stated (clipboard 1 MiB, IME commit 4 KiB, notification title/text 256/2048 characters) | both sides. A longer string is truncated with a flag where the schema has one, otherwise rejected |
| Repeated fields | 4096 elements (input batch 256) | both sides |
| Transfer size | 2 GiB | bulk receivers |
| Agent → host file operations | 16 in flight, 1 MiB per read or write, 64 open handles per package | host (§7.5) |
| Connections per agent | 1 control session plus its secondary streams | agent (§5.4) |

- The agents authenticate peers with `SO_PEERCRED` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1). The session token binds only the streams opened by the same host session.
- The host validates package names, URLs, paths, and content URIs from the guest before use. Package names follow the Android package-name grammar. `OpenUrlOnHost` accepts only `http`, `https`, and `mailto`. Shared-folder paths resolve inside their root ([desktop-integration.md](desktop-integration.md) §6.4, §7.2).
- Logs contain operation names, IDs, sizes, and error codes. Clipboard content, notification text, and typed text are never logged at any level. Input events and file names appear only at debug level in development builds ([diagnostics.md](diagnostics.md) §3.4).
- Both decoders are fuzz targets (#92). The Swift frame decoder runs under a libFuzzer harness on the host. The Kotlin frame decoder and the injector's batch validator run under Jazzer.

---

## 16. Tests

| Tier | What is tested | Where |
|---|---|---|
| T0 | Golden frames in Swift and Kotlin: every golden frame decodes, valid ones re-encode byte for byte, invalid ones are rejected. Codec limits and malformed input | `Packages/GuestProtocol/Tests/GuestProtocolTests/FrameCodecTests.swift`, `Guest/protocol/src/test/` (`FrameCodecTest.kt`); vectors in `Packages/GuestProtocol/testdata/frames/` |
| T0 | Handshake matrix: same major, higher minor, different major, wrong channel, bad token, duplicate session. Major 2 from a fake agent is rejected with `incompatibleVersion` | `Packages/GuestProtocol/Tests/GuestProtocolTests/HandshakeTests.swift`, `Guest/protocol/src/test/` (`AgentHandshakeTest.kt`) |
| T0 | Numbering rule: every `Request.op` case has a `Response.result` case with the same number and a paired `GuestOperation` | `Packages/GuestProtocol/Tests/GuestProtocolTests/NumberingRuleTests.swift` |
| T0 | `GuestConnection` with a fake agent: pipelining, out-of-order responses, timeouts, cancel, keepalive loss, resync ordering | `Packages/RuntimeCore/Tests/RuntimeCoreTests/GuestConnectionTests.swift`, `GuestAgentSupervisorTests.swift` |
| T0 | Agent dispatcher: per-display serialization, `UNSUPPORTED` for operations the build lacks and capabilities the host did not enable, timeouts. A missing framework method fails only its request | `Guest/guestd/src/test/` (`DispatcherTest.kt`) |
| T0 | Store Agent argument rules: `enable_rollback` with `INSTALL_NEW`, fields without their capability, and `allow_downgrade = true` answer `INVALID_ARGUMENT` | `Guest/APKRunStore/` |
| T1 | Kotlin agent server against a scripted host, with JVM fakes of the Android services | `Guest/guestd/src/test/`, `Guest/agentruntime/src/test/` |
| T1 | Fuzzing of both decoders: short runs in CI, long runs nightly | fuzz harnesses (#92) |
| T2 | ADB-forward and vsock transports on real images; reconnect after agent kill; the `adb shell` counter | `Tests/IntegrationTests/GuestAgentTests/` |
| T2 | Store Agent: install, update, hash and signer mismatch, uninstall; rollback, ownership, and `CheckInstallConstraints` (§11.1) | `Tests/IntegrationTests/AndroidPackageTests/`; host side in `Packages/RuntimeHost/Tests/RuntimeHostTests/ADBStoreAgentChannelTests.swift` |

---

## 17. Open items

| Item | Plan |
|---|---|
| vsock on the stock userdebug image needs the `su` domain to be allowed to use vsock (§13.3) | #35 tries it with `apkrun_vsockd` run as root. If the policy does not allow it, the vsock validation moves to #36. See [risks.md](../04-plan/risks.md) R-13 |
| SELinux policy for the bridge and the agents' sockets on the custom image (§14) | R-13. #36 checks the handshake over vsock with no ADB, and that an `untrusted_app` cannot connect to `@apkrun-guestd-control` |
| `GENTLE_UPDATE` with an app that runs a foreground service (§11.1) | OQ-17. Working default: trust `GENTLE_UPDATE` with `app_not_foreground_required`. If the app is not reported as busy, custom images add the `ListTasks` rule and a process-importance query ([update-system.md](update-system.md) §7.1) |
