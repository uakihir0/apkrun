# RuntimeAPI Reference

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2, [../01-architecture/modules.md](../01-architecture/modules.md) §2, §3, [../01-architecture/state-machines.md](../01-architecture/state-machines.md), [../01-architecture/security-model.md](../01-architecture/security-model.md), [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8, [../02-design/cli.md](../02-design/cli.md), [../02-design/wrapper.md](../02-design/wrapper.md) §5, §7, §12, [../02-design/package-store.md](../02-design/package-store.md) §11, [../02-design/update-system.md](../02-design/update-system.md) §11, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6, §8, [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §3.3, §11, [../02-design/diagnostics.md](../02-design/diagnostics.md) §2, §7.6, [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md), [../02-design/input.md](../02-design/input.md), [../02-design/host-ui.md](../02-design/host-ui.md), [error-catalog.md](error-catalog.md), [configuration.md](configuration.md) |

This document is the complete reference of RuntimeAPI, the XPC interface between apkrund and its clients: APKRun.app, APKRunMenuBar, the apkrun CLI, and the launchers built from APKRunLauncher (wrappers and the generic launcher).

The design documents own the behavior. This document owns the wire contract: operation names, request and reply fields, encoding, deadlines, limits, events, and which client may call what. Each operation links to the design section that defines its behavior. If this document and a design document disagree, the design document wins and this document is fixed. Names and values that no design document gives are chosen here and listed in §19.

---

## 1. Overview

### 1.1 Scope and modules

| Part | Module | Role |
|---|---|---|
| DTOs, `@objc` protocols, version constants, the `RuntimeService` Swift protocol | RuntimeAPI | the contract. Foundation and IOSurface only, no logic ([../01-architecture/modules.md](../01-architecture/modules.md) §2) |
| Server | RuntimeHost (`XPCBrokerListener`, `ControlEndpoint`, `WrapperEndpoint`, `EventHub`, `XPCRuntimeExporter`) | adapts `EmbeddedRuntimeService` to the `@objc` protocols ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.1) |
| Client | RuntimeClient (`XPCRuntimeService`) | connection, reconnect, client-side session objects that carry frames and input as wire types, conversion of wire errors to `APKRunError`. It imports neither WindowingCore nor InputCore ([../01-architecture/modules.md](../01-architecture/modules.md) §2) |
| Maintenance server | RuntimeHost (`MaintenanceService`) | the `.maintenance` endpoint ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.1) |

Out of scope: the host–guest protocol ([../02-design/guest-protocol.md](../02-design/guest-protocol.md)), the `apkrun://` URL scheme ([../02-design/host-ui.md](../02-design/host-ui.md)), and the on-disk formats ([configuration.md](configuration.md), [package-metadata-json.md](package-metadata-json.md), [wrapper-json.md](wrapper-json.md)).

### 1.2 Endpoints

| Endpoint | How it is reached | Served to | `@objc` protocol | Version rule (§2) | Served in host state (§3.7) |
|---|---|---|---|---|---|
| Broker | Mach service `io.apkrun.apkrund.xpc` of the LaunchAgent `io.apkrun.apkrund`. Debug builds: `io.apkrun.apkrund.dev.xpc`, label `io.apkrun.apkrund.dev` | any process of the logged-in user | `RuntimeBrokerXPC` | frozen, additive only | all |
| Control | anonymous `NSXPCListener`, one per host client identifier | APKRun.app, APKRunMenuBar, apkrun CLI, the generic launcher | `RuntimeControlXPC` | same major, minor ≤ server | all, with the restrictions of §3.7 |
| Maintenance | anonymous `NSXPCListener`, one per host client identifier | APKRun.app, APKRunMenuBar, apkrun CLI | `MaintenanceControl` | frozen, additive only | all |
| Wrapper(bundleID) | anonymous `NSXPCListener`, one per registered wrapper, created on first request, dropped 10 minutes after its last connection closes, replaced on re-registration | that wrapper's launcher | `RuntimeWrapperXPC` | major N and N−1 | all, with the restrictions of §3.7 |

Every client that subscribes to events or opens a session exports one object that implements `RuntimeEventSink` on its endpoint connection (§4.1).

The broker exposes no capabilities. It only identifies the server, hands out endpoints, and starts wrapper approval ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).

### 1.3 Client kinds

| `ClientKind` | Raw value | Process | Code identifier (release) | Endpoint |
|---|---|---|---|---|
| `app` | `app` | APKRun.app | `io.apkrun.APKRun` | control, maintenance |
| `menuBar` | `menuBar` | APKRunMenuBar | `io.apkrun.APKRunMenuBar` | control, maintenance |
| `cli` | `cli` | apkrun CLI | `io.apkrun.cli` | control, maintenance |
| `launcher` | `launcher` | the generic launcher `APKRun.app/Contents/Helpers/APKRunLauncher.app --package <id>` | `io.apkrun.APKRunLauncher` | control (restricted, §1.4) |
| `wrapper` | `wrapper` | a wrapper's launcher | the wrapper bundle ID `io.apkrun.android.<mapped package>` ([../02-design/wrapper.md](../02-design/wrapper.md) §4) | wrapper(bundleID) |

Debug builds add the suffix `.dev` to every host identifier (`io.apkrun.APKRun.dev`, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6). Wrapper identifiers do not change.

### 1.4 Permission notation

The operation tables of §5–§15 use these letters in the **Clients** column.

| Letter | Who | Endpoint |
|---|---|---|
| C | APKRun.app, APKRunMenuBar, apkrun CLI | control |
| A | APKRun.app only | control |
| L | the generic launcher | control, launcher identity |
| W | a wrapper, for its own package only | wrapper(bundleID) |
| M | APKRun.app, APKRunMenuBar, apkrun CLI | maintenance |
| B | any process | broker |

- C is the full `RuntimeService` of [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2. A narrows a few operations to APKRun.app, because they answer prompts or report Sparkle state that only APKRun.app has.
- L may call only the session operations (§6.2, §6.3), `runtimeStatus`, `packageInfo`, `packageIcon`, and `subscribe` and `unsubscribe` for the topic `runtime` (§16.1). It may open a session for any installed package. Anything else returns `runtime.notAuthorized`.
- W may call only what §10.1 lists for the wrapper endpoint. A request that names another package returns `runtime.notAuthorized` and writes a security log entry ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.2).
- The server derives the client kind from the listener that accepted the connection, never from the payload. A header whose `clientKind` differs from the listener's kind is refused with `runtime.notAuthorized`.

### 1.5 Code-signing requirements

apkrund sets the requirement on each anonymous listener with `NSXPCListener.setConnectionCodeSigningRequirement(_:)`. The client sets a requirement for apkrund with `NSXPCConnection.setCodeSigningRequirement(_:)` before `resume`, on the broker connection and on the endpoint connection.

| Connection | Release requirement | Development requirement (ad-hoc) |
|---|---|---|
| control and maintenance listener, per identifier | `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "<identifier>"` | `cdhash H"<cdhash>"` of that binary in the same APKRun.app, computed at apkrund start |
| wrapper listener | `identifier "<bundleID>" and cdhash H"<registered cdhash>"` from `Wrappers/registry.json` | the same |
| client → apkrund | `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "io.apkrun.apkrund"` | `identifier "io.apkrun.apkrund.dev"` |

- A process that fails the requirement gets an invalidated connection. The system checks the connecting process's code, so a claim in `hello` grants nothing.
- apkrund never uses `auditToken` or `processIdentifier` for authorization ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).
- Wrappers are re-signed per wrapper (ad-hoc, identifier = bundle ID), so every wrapper has its own cdhash ([../02-design/wrapper.md](../02-design/wrapper.md) §7.1).

### 1.6 Connection model

- A client opens a broker connection, calls `hello` and `requestEndpoint`, and closes the broker connection when it has the endpoint. A wrapper keeps it open while it waits for approval (§3.4).
- A client holds at most one endpoint connection of each kind. All requests of one client go over that connection.
- A connection holds at most one app session. APKRun.app does not open app sessions (the window process always does, ADR-0006), so in practice only launchers open sessions.
- Session events go only to the connection that owns the session. Topic events go to every subscribed connection (§16).
- Long operations outlive the connection that started them (§4.7). Sessions do not: a dropped connection orphans its session for 3 s (§6.2).
- Limits per connection and per endpoint are in §4.10.

---

## 2. Versioning and compatibility

### 2.1 Constants

```swift
public enum RuntimeAPI {
    public static let version = APIVersion(major: 1, minor: 0) // the control and wrapper protocols
    public static let wrapperMajors: [Int] = [1] // served on the wrapper endpoint: N and N−1
    public static let brokerRevision = 1 // additive-only broker protocol
    public static let maintenanceRevision = 1 // additive-only MaintenanceControl
}

public struct APIVersion: Codable, Sendable, Comparable { public var major: Int; public var minor: Int } // encoded "1.0"
```

- The first released version is `1.0` at #032. Before #032 there is no XPC and no version check (§3.8).
- `components.json` of a release records `"runtimeAPI": { "current": "M.m", "wrapperMajors": [N−1, N] }` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.3). A major is dropped only as that section allows.

### 2.2 Rules per endpoint

| Endpoint | Accepts | On mismatch |
|---|---|---|
| Broker | every revision. `hello` never fails on a version | — |
| Control | the server's major, any minor ≤ the server's minor | `runtime.apiVersionMismatch(client:server:)`, remediation "Update APKRun" |
| Wrapper | the server's major and the previous major (N−1), any minor for N−1, minor ≤ the server's for N | `runtime.apiVersionMismatch(client:server:)`, remediation "Update Mac App". The launcher normally avoids this with the checks of §2.4 |
| Maintenance | every client. No major | — |

A client newer than the server in minor only (for example client `1.3`, server `1.2`) is refused on the control endpoint. Control clients ship in the same APKRun.app as apkrund, so this happens only during an APKRun update, which the maintenance endpoint covers ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6).

### 2.3 Minor and major changes

| Change | Kind |
|---|---|
| new operation, new optional request field, new reply field, new event, new topic | minor |
| new case of a reply or event enum, new error code | minor. Reply and event enums are open: an unknown case decodes as `.unknown` and the client shows a generic state |
| new case of a request enum | minor. The server rejects an unknown request case with `runtime.malformedRequest`, so a client uses the case only when `HelloReply.apiVersion` shows the server has it |
| making an optional request field required, removing or renaming a field, a case, or an operation, changing a field's type or meaning, changing the encoding | major |

- The broker and `MaintenanceControl` accept only minor-kind changes, forever. A new revision number documents what was added.
- The wrapper endpoint keeps the N−1 DTOs frozen in a versioned namespace (`RuntimeAPI.V<N−1>`). The server converts them to the current types. Tests decode fixtures of every served major.

### 2.4 Wrapper compatibility

The launcher is built against `M.m`. apkrund serves `N.n`. The launcher decides after `hello` ([../02-design/wrapper.md](../02-design/wrapper.md) §5.3):

| Condition | Result |
|---|---|
| `HelloReply.runtimeVersion` < `wrapper.json runtime.minimumVersion` | screen V ("‹App› needs APKRun ‹minimum› or later.") |
| `M == N`, `m ≤ n` | OK |
| `M == N`, `m > n` | screen V (the runtime is older than the launcher's API) |
| `M == N − 1` | OK. apkrund marks the wrapper for a launcher refresh (`WrapperStatus.refreshReasons` contains `.launcher`) |
| `M < N − 1` | screen L ("This Mac app was made by an older APKRun and needs to be updated.") |
| `M > N` | screen V |

---

## 3. Connection lifecycle

### 3.1 Sequence

```text
client apkrund
connect io.apkrun.apkrund.xpc, requirement for apkrund ─▶ broker
hello(HelloRequest) ─▶ HelloReply
requestEndpoint(EndpointRequest) ─▶ EndpointReply (.granted + endpoint |.rejected)
wrapper, rejected: requestApproval(ApprovalRequest) ─▶ ApprovalReply; then requestEndpoint again
close the broker connection
connect the endpoint, requirement for apkrund,
exportedInterface = RuntimeEventSink ─▶ control | maintenance | wrapper endpoint
subscribe(…), openSession(…), other operations
```

### 3.2 `hello`

```swift
public struct HelloRequest: Codable, Sendable {
    public var clientKind: ClientKind
    public var claimedIdentity: String // the client's bundle or code identifier; used to pick the listener
    public var apiVersion: APIVersion // the version the client was built against
    public var clientVersion: String? // marketing version, for logs
    public var clientBuild: Int?
}

public struct HelloReply: Codable, Sendable {
    public var runtimeVersion: String // APKRun marketing version, "1.2.0"
    public var runtimeBuild: Int
    public var apiVersion: APIVersion // the server's version for the control protocol
    public var hostState: HostState // §3.7
}
```

- `hello` never fails on a version. The client compares versions itself (§2.2, §2.4).
- apkrund runs its `BundleWatcher` check on every `hello` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6), so a client that connects after APKRun was replaced sees `restartPending` at once.
- Deadline: 5 s (§4.6).

### 3.3 `requestEndpoint`

```swift
public enum EndpointKind: Codable, Sendable, Hashable {
    case control
    case maintenance
    case wrapper(bundleID: String)
}

public struct EndpointRequest: Codable, Sendable {
    public var kind: EndpointKind
    public var apiVersion: APIVersion
    public var selfCdhash: String? // wrappers: the launcher's own cdhash (SecCodeCopySelf); advisory only
}

public enum EndpointRejection: String, Codable, Sendable {
    case notRegistered // wrapper: bundle ID not in the registry
    case cdhashMismatch // wrapper: registered with another cdhash
    case unsupportedAPI // wrapper major outside RuntimeAPI.wrapperMajors
    case unknownClient // control or maintenance: no listener for the claimed identity
}
```

```swift
public enum EndpointReply: Codable, Sendable {
    case granted // the NSXPCListenerEndpoint travels next to the JSON reply (§4.9)
    case rejected(EndpointRejection)
}
// @objc: func requestEndpoint(_ request: Data, reply: @escaping (Data, NSXPCListenerEndpoint?) -> Void)
```

- `selfCdhash` lets apkrund answer `cdhashMismatch` without an endpoint round trip. It grants nothing: the listener requirement still checks the real cdhash. When `selfCdhash` is missing and the cdhash differs, the endpoint connection is invalidated right after `resume`, and the launcher treats that as `cdhashMismatch`.
- A rejected wrapper goes to approval (§3.4). A rejected control client shows "APKRun is damaged. Download it again." (`runtime.notAuthorized`).
- Deadline: 5 s.

### 3.4 `requestApproval` (broker)

Flow and dialog: [../02-design/wrapper.md](../02-design/wrapper.md) §7.3.

```swift
public struct ApprovalRequest: Codable, Sendable {
    public var bundleURL: URL // file URL of the wrapper bundle
    public var bundleID: String
    public var packageID: PackageID
}

public enum ApprovalReply: Codable, Sendable {
    case approved
    case denied(until: Date) // the denial lasts 24 h
    case timedOut // no answer in 10 min
}
```

| Error | When |
|---|---|
| `wrapper.bundleInvalid` | a static check failed: signature not valid, identifier ≠ bundle ID, bundle ID ≠ map(package ID), `wrapper.json` invalid. A modified local wrapper (`signatureInvalid`) always fails here |
| `runtime.busy` | more than 5 approval requests in the last minute from all wrappers |

- An unexpired denial for the same cdhash answers `.denied(until:)` at once, without a prompt.
- A second request for the same bundle ID while one is pending joins it and gets the same reply.
- The launcher maps `.denied` and `.timedOut` to `wrapper.approvalDenied` and `wrapper.approvalTimedOut` for screen A.
- The call waits until the user answers or 10 minutes pass. The launcher shows screen A meanwhile.
- After `.approved`, the launcher calls `requestEndpoint` again on the same broker connection.

### 3.5 Invalidation and interruption

| Event on the endpoint connection | Meaning | Client action |
|---|---|---|
| `interruptionHandler` | apkrund exited or crashed; launchd restarts it on demand (NFR-REL-02) | reconnect (§3.6) |
| `invalidationHandler` right after `resume` | the code-signing requirement failed | wrapper: `cdhashMismatch` → approval. Control client: `runtime.notAuthorized` |
| `invalidationHandler` later | apkrund dropped the connection (limits, invalid use) or exited | reconnect (§3.6) |
| a reply block never called within the deadline + 5 s | a lost request | the client fails the call with `runtime.requestTimedOut(operation:)` and invalidates the connection |

On the server, an invalidated connection:

- is removed from every topic at once (§16.1);
- orphans its session: the session keeps its display for 3 s and re-attaches if the same client opens a session for the same package ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.6). After 3 s the close policy of the package applies;
- does not cancel long operations it started;
- releases activity assertions it held (`runtime start --hold`, §5.2);
- ends the notification relay and streams of that connection (§11.3, §16.4).

### 3.6 Reconnect

RuntimeClient reconnects from the broker step on. It never replays requests. Behavior by failure ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.5):

| Failure | Client behavior |
|---|---|
| apkrund not registered (`SMAppService.status != .enabled`) | GUI clients and launchers open APKRun.app with `--register-runtime`. The CLI prints "APKRun's background service is not set up. Open APKRun once, or run: apkrun setup" and exits 69 ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.5) |
| the broker does not answer (no Mach service, or `hello` times out) | `runtime.serviceUnavailable(.notRunning)`. Launchers show screen R when APKRun.app is missing, otherwise screen S ([../02-design/wrapper.md](../02-design/wrapper.md) §5.4) |
| apkrund crashed during a session | the launcher retries `openSession` after 1 s, 2 s, and 4 s (3 attempts), then shows screen E |
| control major mismatch | a dialog "APKRun needs to be restarted" in APKRun.app; the CLI fails with `runtime.apiVersionMismatch` |
| `hostState` is `updating`, a call returns `runtime.hostUpdating`, or a session ended with `.runtimeUpdating` | launchers show screen U and retry every 2 s for up to 10 minutes. Control clients show "Updating APKRun…" |
| endpoint rejected (wrapper) | `requestApproval` (§3.4) |
| `HelloReply.runtimeBuild` changed since the last connection | APKRunMenuBar relaunches itself from the current bundle. APKRun.app runs its first-launch steps ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.7) |

After a reconnect the client subscribes again and asks for fresh snapshots (for example `runtimeStatus`, `listOperations`). Event sequence numbers restart with each connection (§16.2).

### 3.7 Host states

`HostState` is in `HelloReply`, `RuntimeStatus`, `MaintenanceStatus`, and the `maintenance` topic ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6).

```swift
public enum HostState: Codable, Sendable, Equatable {
    case normal
    case updating(targetBuild: Int) // an APKRun update is being installed, or is finishing
    case restartPending(bundleBuild: Int?) // the bundle on disk is newer than the running apkrund
}
```

| Host state | Served | Refused with `runtime.hostUpdating` |
|---|---|---|
| `normal` | everything | — |
| `updating` | the broker; the maintenance endpoint; `runtimeStatus`, `subscribe`, `unsubscribe`, `cancel`, `listOperations`, `operationStatus`; `healthReport`, `applyHealthFixes`, `createDiagnostics`, `perfStatistics`, `guestLog` | every other operation. Android never starts |
| `restartPending` | everything that does not need a new Android start or the bundle's resources. Open sessions and background tasks continue | operations that must start Android while it is stopped (`openSession`, `launch`, `startRuntime`, `setup`, installs and updates), `createWrapper`, `refreshWrapper`, `buildDistributionWrapper`, `refreshAllWrappers`, and operations that read bundle resources (the dev Guest Agent, `compatibility.json`, the launcher template). When nothing is active, apkrund stops Android and exits 0 |

Operations that need Android while Android is already `ready` in `restartPending` are served.

### 3.8 Embedded mode (before #031, and `apkrun dev`)

Before #031 there is no daemon. `apkrun dev …` links RuntimeHost and runs `EmbeddedRuntimeService` in the CLI process ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §1.2, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §10).

| Aspect | XPC | Embedded |
|---|---|---|
| Transport | NSXPC, JSON DTOs | direct Swift calls on the same `RuntimeService` protocol. DTOs are passed as Swift values, not encoded |
| Broker, endpoints, code signing | yes | none |
| `clientKind` | per client | always `cli` |
| Version check | §2.2 | none (one binary) |
| Events | `RuntimeEventSink` batches | `AsyncStream` per topic, same `EventEnvelope` values |
| Sessions | the launcher owns the window | WindowingCore's development window in the CLI process |
| Instance | the user's (`~/Library/Application Support/APKRun/`) | `APKRUN_HOME` (default `…/APKRun-Dev/`). The instance lock refuses to share: `runtime.instanceLocked(owner:)`, CLI exit 75 |

- Round-trip tests encode and decode every DTO, so the embedded path (no encoding) and the XPC path cannot drift.
- `DeveloperService` (§15) exists only in embedded mode. It is not exported over XPC.

---

## 4. Conventions

### 4.1 Wire shape

Every operation of the control, wrapper, and maintenance protocols has one of these `@objc` shapes.

```swift
// request/reply
func runtimeStatus(_ request: Data, reply: @escaping (Data) -> Void)
// request/reply with file handles (sent as NSSecureCoding next to the JSON)
func importPackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
// openSession: IOSurfaces come back next to the JSON descriptor
func openSession(_ request: Data, reply: @escaping (Data, [IOSurface]?) -> Void)
// one-way (session channel and stream responses only)
func sendInput(_ batch: Data)
func frameDisplayed(generation: UInt32, frameSeq: UInt64)
```

```swift
public struct RequestEnvelope<Body: Codable & Sendable>: Codable, Sendable {
    public var header: APIRequestHeader
    public var body: Body // `Empty` for operations without arguments
}

public struct APIRequestHeader: Codable, Sendable {
    public var apiVersion: APIVersion
    public var operationID: OperationID
    public var clientKind: ClientKind
}

public struct ReplyEnvelope<Result: Codable & Sendable>: Codable, Sendable {
    public var result: Result? // exactly one of result and error is set
    public var error: WireError?
}
```

- One-way messages carry no header. They belong to the session or stream of the connection. Their log lines carry the session's operation ID.
- The client-exported object:

```swift
@objc public protocol RuntimeEventSink {
    func deliver(_ batch: Data, reply: @escaping () -> Void) // [EventEnvelope], topic events; the reply is the ack (§16.2)
    func sessionEvent(_ event: Data) // SessionEvent, own session only (§6.3)
    func frameReady(generation: UInt32, surfaceIndex: UInt8, frameSeq: UInt64, presentationTime: UInt64)
    func surfacesReplaced(_ set: Data, surfaces: [IOSurface])
    func streamEvent(_ event: Data, reply: @escaping () -> Void) // StreamEnvelope; the reply is the ack (§16.4)
}
```

- The Swift side is `RuntimeService`, composed of one protocol per group of §5–§15 (`RuntimeStatusService`, `SessionService`, `StoreService`, `UpdateService`, `WrapperService`, `IntegrationService`, `MaintenanceUpdateService`, `DiagnosticsService`, `ConfigurationService`, `OperationService`, `EventService`). Every method is `async throws(WireError)`. `WrapperRuntimeService` is the wrapper subset. `MaintenanceControl` is also a Swift protocol with the same name. RuntimeClient implements all of them over XPC; `EmbeddedRuntimeService` implements them in process.
- The `@objc` method names equal the operation names in this document.

### 4.2 DTO encoding

| Item | Rule |
|---|---|
| Format | JSON (`JSONEncoder`), UTF-8. A switch to binary property lists is a major change |
| Keys | the Swift property names, lowerCamelCase |
| Enums without payload | `String` raw-value enums, encoded as the case name: `"warm"` |
| Enums with payload | Swift's synthesized `Codable`: an object with one key, the case name: `{"booting": {"phase": "systemServer"}}`. A case without payload in such an enum is an object with an empty payload: `{"stopped": {}}`. Unlabeled payloads use `_0`, `_1` |
| Open enums | reply and event enums with an `unknown` case (§2.3). The synthesized `Codable` would fail on a case name it does not know, so these enums implement `init(from:)`: an unknown case name, with or without a payload, decodes as `.unknown`. `.unknown` is never encoded. A T0 test decodes every open enum from `"futureCase"` and `{"futureCase": {}}` |
| Optional values | omitted when `nil`. Merge patches (§14) use explicit `null` to reset a key |
| Unknown fields | ignored |
| Dates | ISO 8601 UTC with fractional seconds: `"2026-11-02T10:15:02.123Z"` |
| Durations | `Int64` milliseconds, with the suffix `Ms` in the field name (`uptimeMs`). Exceptions: `InputTimestamp.hostNanos` and `LaunchTiming`, which are mach continuous time; `presentationTime`, which is `mach_absolute_time` ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §5); and the performance values of `WirePerfStatistics`, which are microseconds with the suffix `Us` (§13.1) |
| Byte counts | `Int64`, bytes |
| Fractions | `Double` in 0…1 |
| Sizes and points | `CGSize` and `CGPoint` as `{"width":…,"height":…}` and `{"x":…,"y":…}` |
| URLs | absolute file or https URL strings. apkrund never reads a user-chosen file from a URL; it gets a file handle or a bookmark (§4.9). Exceptions: wrapper destinations, which apkrund probes and then leaves to the client when access is denied (§10.3), and wrapper bundles, which apkrund checks for approval and verification (§3.4, §10.4, §10.6) |
| Bookmarks | security-scoped bookmark `Data`, Base64 |
| Localized text | `WireLocalizedText { key, parameters: [String: WireErrorParameter], fallback: String }`. The client renders it in its own language ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2.2) |

### 4.3 Identifiers

| Type | Wire form | Notes |
|---|---|---|
| `PackageID` | string, Android package grammar, at most 255 characters | [../02-design/package-store.md](../02-design/package-store.md) §2 |
| `VersionCode` | `Int64` | |
| `SHA256Digest` | `"sha256:<64 lowercase hex>"` | package set, file, and signer digests |
| cdhash | 40 lowercase hex characters | `GeneratedWrapper.cdhash` |
| `OperationID` | lowercase UUID v4 string | [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.4 |
| `SessionID` | `{"app": "<uuid>"}` or `{"system": <SystemDisplayUse>}` | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3.1. Only `.app` sessions appear on the session channel |
| `DisplayID` | lowercase UUID string | a pool slot lease, not the Android display ID |
| `ImportTicket`, `ApprovalID`, `PromptID`, `OfferID`, `StreamID`, `SharedFolderID`, `StagingToken` | lowercase UUID string | `SharedFolderID` is the `id` of `sharedFolders.roots` ([configuration.md](configuration.md) §2.8). The built-in Shared folder has the fixed ID `shared` |
| `RecoveryPointID` | string, the directory name `<timestamp>-<imageVersion>` | [../02-design/android-image.md](../02-design/android-image.md) §12.2 |
| `HealthCheckID` | string, dotted: `"runtime.boot"` | [../02-design/diagnostics.md](../02-design/diagnostics.md) §7.1 |
| `ImageVersion` | `{year, month, sequence, base, architecture}` | [../02-design/android-image.md](../02-design/android-image.md) §9.1 |

UUIDs are compared case-insensitively. Human output shows the first 8 hex digits of an operation ID.

### 4.4 Operation IDs

- The client that starts a user-visible operation creates its `OperationID` and sends it in every request of that operation. `apkrun install app.apk --wrap` sends `importPackage`, `installImported`, and `createWrapper` with the same ID.
- apkrund creates IDs for work it starts itself (scheduled update checks, idle stop, startup recovery) and for sub-operations. A sub-operation has `parent` set ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2.4).
- The operation ID is in every log line and perf marker caused by the request ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.2) and in every error reply (`WireError.context.operationID`).

### 4.5 Errors

Every error on the wire is a `WireError`, the RuntimeAPI copy of `APKRunError` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2.1). RuntimeAPI cannot import DiagnosticsCore, so RuntimeHost converts `APKRunError` to `WireError`, and RuntimeClient converts it back.

```swift
public struct WireError: Error, Codable, Sendable, Equatable {
    public var domain: String // "runtime", "store", … (error-catalog.md §2)
    public var code: String // qualified code "store.downgradeRefused"
    public var parameters: [String: WireErrorParameter]
    public var cause: WireErrorBox? // nested error, same shape
    public var underlying: WireUnderlyingError? // { domain, code }, no userInfo
    public var context: ErrorContext?
}

public enum WireErrorParameter: Codable, Sendable, Equatable {
    case text(String), bytes(Int64), count(Int), durationMs(Int64), fileName(String)
}

public struct ErrorContext: Codable, Sendable, Equatable {
    public var operationID: OperationID?
    public var packageID: PackageID?
    public var displayID: DisplayID?
}
```

- Codes, messages, remediations, actions, and CLI exit codes are in [error-catalog.md](error-catalog.md). This document names errors by code only.
- A code the client does not know renders with the catalog's generic entry and keeps its code in Copy Details. Codes are never reused ([error-catalog.md](error-catalog.md) §2.2).
- Errors that every operation can return are not repeated in the operation tables:

| Code | When | Raised by |
|---|---|---|
| `runtime.apiVersionMismatch` | header major not served (§2.2) | server |
| `runtime.malformedRequest` | undecodable header or body, unknown request case, a limit of §4.10 on field size exceeded | server |
| `runtime.notAuthorized` | client kind or package not allowed (§1.4) | server |
| `runtime.busy` | a connection or in-flight limit of §4.10 | server |
| `runtime.hostUpdating` | host state refuses the operation (§3.7) | server |
| `runtime.hostShuttingDown` | apkrund is exiting (logout, idle exit in progress) | server |
| `runtime.internal` | a reply guard was released without a reply, or an unexpected error | server |
| `runtime.serviceUnavailable` | the broker or endpoint cannot be reached (§3.6) | client |
| `runtime.requestTimedOut` | no reply within the deadline + 5 s (§4.6) | client |

`runtime.serviceUnavailable` (with `ServiceUnavailableReason` `notRegistered`, `requiresApproval`, `notRunning`) and `runtime.requestTimedOut` are cases of `RuntimeFailure` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §11) that RuntimeClient raises. It never receives them from the server.

### 4.6 Operation kinds and deadlines

| Kind (column **Kind**) | Meaning | Server deadline |
|---|---|---|
| Q | query: reads state, no side effects | 5 s |
| U | update: changes state, returns when done | 30 s |
| L | long: returns an `OperationHandle` within 5 s, then reports on the `operations` topic (§4.7) | the handle in 5 s; the operation has its own design timeouts |
| W | waits: returns when a condition is met | the design timeout of the operation (listed per operation) |
| S | stream: returns a `StreamHandle`, then delivers on `streamEvent` until closed (§16.4) | 5 s for the handle |
| 1 | one-way message on the session channel or a stream | none |

Exceptions to the default deadlines:

| Operation | Deadline |
|---|---|
| `hello`, `requestEndpoint` | 5 s |
| `requestApproval` | 10 min |
| `startRuntime` | the request's `timeoutMs`, default `runtime.bootTimeoutSeconds` + 30 s |
| `openSession` | 30 s after `acquiringDisplay` is reached; a wait for the runtime or a package transaction is reported through session states, not by the reply (§6.2) |
| `launch` | the launcher must connect within 20 s; then the session's own timeouts |
| `checkSelfUpdate` | 30 s |
| `setUpdatePolicy` | 30 s (it may validate the provider) |
| `healthReport` | 15 s quick, 3 min deep |
| `applyHealthFixes` | 3 min |
| `verifyWrapper` | 5 s, 60 s with `deep` |
| `prepareForHostUpdate` | 3 min (apkrund waits up to 2 min for store transactions) |
| `restartForUpdate`, `stopRuntime` in `restartPending` | 60 s |

The client waits the deadline plus 5 s. Then it fails the call with `runtime.requestTimedOut(operation:)` and invalidates the connection (§3.5).

### 4.7 Long operations and cancellation

```swift
public struct OperationHandle: Codable, Sendable {
    public var operationID: OperationID
    public var parent: OperationID?
    public var kind: OperationKind
}

public enum OperationKind: String, Codable, Sendable {
    case `import`, inspect, install, uninstall, repair, rollback,
    update, updateCheck,
    wrapperCreate, wrapperRefresh, wrapperRefreshAll, distributionWrapper, bootstrapImport,
    setup, resetAndroid, runtimeStop, runtimeRestart,
    imageCheck, imageDownload, imageInstall, imageApply, imageRollback,
    diagnostics
}
```

- The handle's `operationID` is the header's. While an operation with that ID and kind runs, a repeated request returns the same handle (a retry after reconnect). A long request whose ID is already used by an operation of another kind (running, or among the kept finished ones) gets a new ID, with `parent` set to the header's. This is how `apkrun install app.apk --wrap` gets one import, one install, and one wrapper operation under one user-visible ID.
- Progress and the result arrive on the `operations` topic: `OperationEvent.started`, `.progress`, `.finished` (§16.3). Domain topics carry their own events too (for example `PackageChange.operationProgress`).
- Operations survive the connection that started them. The CLI sends `cancel` on `SIGINT` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.3). A dropped connection cancels nothing.
- `apkrund` keeps running operations and the last 50 finished ones in memory. They are not persisted.

**Operation tracking** (control and wrapper endpoints):

| Operation | Request → Reply | Clients | Kind |
|---|---|---|---|
| `cancel` | `CancelRequest { operationID }` → `CancelReply` | C, W (own operations) | U |
| `listOperations` | `Empty` → `[OperationSnapshot]` | C | Q |
| `operationStatus` | `OperationStatusRequest { operationID }` → `OperationSnapshot` | C, W (own operations) | Q |

```swift
public enum CancelReply: Codable, Sendable {
    case cancelling // the operation will stop at its next cancellation point
    case notCancellable(reason: String) // past its last cancellation point; it continues
    case alreadyFinished(OperationResult)
}

public struct OperationSnapshot: Codable, Sendable {
    public var operationID: OperationID
    public var parent: OperationID?
    public var kind: OperationKind
    public var packageID: PackageID?
    public var clientKind: ClientKind? // nil for work apkrund started itself
    public var startedAt: Date
    public var progress: OperationProgress?
    public var result: OperationResult? // nil while running
    public var finishedAt: Date?
}
```

`operationStatus` and `cancel` for an unknown or expired ID return `runtime.operationNotFound(OperationID)`.

Cancellation points:

| Kind | Cancellable | After cancellation |
|---|---|---|
| `import`, `inspect` | any time | the incoming files are deleted |
| `install` | until `CommitInstall` ([../02-design/package-store.md](../02-design/package-store.md) §5) | the guest session is abandoned; the store is unchanged |
| `uninstall` | until the guest uninstall starts | nothing changed |
| `repair` | until the guest install starts | |
| `rollback`, `imageApply`, `imageRollback`, `runtimeStop` | never | `notCancellable` |
| `resetAndroid` | until Android has stopped | nothing deleted |
| `update` | until the phase `installing` ([../02-design/update-system.md](../02-design/update-system.md) §5) | the download is kept in the cache |
| `updateCheck`, `imageCheck` | any time | |
| `imageDownload` | any time | the partial file is kept for resume |
| `imageInstall` | during download and extraction | as `imageDownload`; extracted files are deleted |
| `setup` | between steps, not during first boot | resumes at the first incomplete step next time |
| `wrapperCreate`, `wrapperRefresh`, `distributionWrapper` | until the bundle swap or placement ([../02-design/wrapper.md](../02-design/wrapper.md) §6) | staging is deleted |
| `wrapperRefreshAll` | between wrappers | |
| `bootstrapImport` | as `import`, then as `install` | |
| `diagnostics` | any time | apkrund truncates the output to 0 bytes. It has only the handle, so the client deletes the file |
| `runtimeRestart` | during the stop phase: no; before the start: yes | Android stays stopped |

A cancellation of an operation that is waiting (for example an update that waits for the app to quit) ends only the wait. The result is `cancelled`.

### 4.8 Events and topics

Topics, payloads, coalescing, and ordering are in §16. Summary:

| Topic | Payload | Subscribers |
|---|---|---|
| `runtime` | `RuntimeChange` | C, L |
| `sessions` | `SessionListChange` | C |
| `packages` | `PackageChange` | C |
| `updates` | `UpdateEvent` | C |
| `operations` | `OperationEvent` | C; W for its own operations |
| `health` | `HealthEvent` | C |
| `maintenance` | `MaintenanceEvent` | C |
| `wrappers` | `WrapperChange` | C |
| `integrations` | `IntegrationChange` | C |

### 4.9 File handles, bookmarks, and IOSurfaces

| Object | Direction | Rule |
|---|---|---|
| `FileHandle` (`NSFileHandle`) | client → apkrund | for every user-chosen file: APK imports, update files, image archives, icons, drag and drop, Save to Mac, diagnostics output. The client opens the file; apkrund never opens a user-chosen path ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3). Read handles are positioned at 0; apkrund reads with `pread` and does not seek. Write handles must be empty regular files |
| bookmark `Data` | client → apkrund | for folders apkrund must reach again later: shared folders, wrapper destinations after `destinationNotAccessible` |
| `IOSurface` | apkrund → launcher | three per `SurfaceSet`, sent only in the `openSession` reply and `surfacesReplaced`, never per frame ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §5) |
| `NSXPCListenerEndpoint` | broker → client | in the `requestEndpoint` reply |

- File handles travel in a separate `files:` array next to the JSON body. The JSON refers to them by index (`fileIndex`). A request whose indices do not match the array is `runtime.malformedRequest`.
- Allowed classes are set on the `NSXPCInterface` for each argument (`setClasses(_:for:argumentIndex:ofReply:)`): `NSFileHandle`, `IOSurface`, `NSXPCListenerEndpoint`, `NSData`, `NSArray`. Nothing else is decoded.

### 4.10 Limits and rate limiting

| Limit | Value | Over the limit |
|---|---|---|
| Requests in flight per connection | 64 | `runtime.busy` |
| Control connections at once | 8 | new connection invalidated; the pending `requestEndpoint` returns `runtime.busy` |
| Connections per wrapper endpoint | 4 | as above |
| Broker connections at once | 32 | new connections invalidated |
| Message size (JSON) | 32 MiB | `runtime.malformedRequest` |
| File handles per request | 20 for imports and drag and drop, 1 elsewhere | the operation's own error (`integration.tooManyFiles`) or `runtime.malformedRequest` |
| Approval requests | 1 pending per bundle ID, 5 per minute in total | joins the pending one / `runtime.busy` |
| `sendInput` | 512 events per batch; 2000 events/s per session | extra events dropped and counted (`input.dropped.rate`) |
| `sendText` | 4 KiB per event, 64 KiB/s per session | dropped and counted |
| Clipboard, files, links | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §3 (§11.4) | `integration.*` errors |
| Event queue per subscriber | 1024 events | `resyncRequired` (§16.2) |
| Coalesced events | at most 10 per second per key and subscriber | older values dropped |
| `updateHistory.limit` | default 50, at most 1000 | clamped |
| `packageIcon.sizePx` | 16…1024 | `runtime.malformedRequest` |

- Lists are returned whole. There is no pagination; the largest lists (packages, wrappers) stay well below the message limit.
- Checks started by a user while the same check runs join the running one and get its handle.

### 4.11 Reading the operation tables

- **Request → Reply**: the DTO names. `Empty` means no fields. The fields are in the Swift blocks after each table and in §17.
- **Clients**: §1.4.
- **Kind**: §4.6.
- **Events**: topic and case names, emitted by the operation or its effects.
- **Design**: the section that defines the behavior. Operations that this document first named are now listed in their owning design documents (§19.2).
- Errors per operation follow each group. The common errors of §4.5 are not repeated.

---

## 5. Runtime and status

### 5.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `runtimeStatus` | `Empty` → `RuntimeStatus` (control), `RuntimeSummary` (wrapper) | C, L, W | Q | — | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.1, [../02-design/cli.md](../02-design/cli.md) §4.1 |
| `runtimeInfo` | `RuntimeInfoRequest` → `RuntimeInfo` | C | Q (15 s with `resources`) | — | [../02-design/cli.md](../02-design/cli.md) §4.1 (`apkrun info`), runtime-daemon §8.6 |
| `startRuntime` | `StartRuntimeRequest` → `RuntimeStatus` | C | W | `runtime.stateChanged`, `runtime.bootProgress` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.1, §3.2 |
| `stopRuntime` | `StopRuntimeRequest` → `OperationHandle` (`runtimeStop`) | C | L | `runtime.stateChanged`, `sessions.ended`, `operations.*` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.5 |
| `restartRuntime` | `RestartRuntimeRequest` → `OperationHandle` (`runtimeRestart`) | C | L | as `stopRuntime`, then as `startRuntime` | [../02-design/cli.md](../02-design/cli.md) §4.1 |
| `resetRuntime` | `Empty` → `RuntimeStatus` | C | U | `runtime.stateChanged`, `runtime.bootLoopGuardChanged` | [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §2, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.6 |
| `resetAndroid` | `ResetAndroidRequest` → `OperationHandle` (`resetAndroid`) | C | L | `runtime.*`, `packages.stateChanged` (`needsReinstall(.userdataReset)`), `operations.*` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9.5 |
| `setup` | `SetupRequest` → `OperationHandle` (`setup`) | C | L | `runtime.provisioningChanged`, `operations.*` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9 |

`resetRuntime` and `resetAndroid` are two different operations. `resetRuntime` clears a `failed` state and the boot-loop guard and deletes nothing (`apkrun runtime reset`). `resetAndroid` deletes all Android data (`apkrun runtime reset --erase`, **Reset Android…**).

### 5.2 Start, stop, restart, and reset

```swift
public struct StartRuntimeRequest: Codable, Sendable {
    public var hold: Bool // keep an activity assertion (.cli) until this connection closes
    public var timeoutMs: Int64? // default runtime.bootTimeoutSeconds + 30 s (first boot: firstBootTimeoutSeconds + 30 s)
}

public struct StopRuntimeRequest: Codable, Sendable {
    public var force: Bool // stop even when sessions, store operations, or other activities exist
}

public struct RestartRuntimeRequest: Codable, Sendable {
    public var force: Bool
}
```

- `startRuntime` calls `ensureReady(.cli)` for the CLI and `ensureReady(.user)` for APKRun.app and the menu bar (the client kind of `hello`). It returns when the runtime is `ready`. It is an explicit start, so it clears the boot-loop guard ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §3.1). APKRun.app's **Start Android** and **Restart** use the same operation.
- `hold = true` adds the activity `.cli` ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §5.1) for as long as the connection that sent the request stays open. The CLI keeps its connection open with `apkrun runtime start --hold` until it is interrupted. A second `hold` on the same connection is a no-op.
- Progress arrives on the `runtime` topic (`bootProgress`, coalesced). The reply carries the final `RuntimeStatus`. A boot failure returns the `RuntimeFailure` of the boot (`runtime.bootTimedOut`, `runtime.bootStalled`, …).
- `stopRuntime` without `force` refuses at once, before a handle, with `runtime.busy(activities:)` when sessions are open or activities other than idle-neutral ones exist. The client asks the user ("Stop Android and close 2 apps?", "Android is installing ‹App›. Stop anyway?") and repeats with `force = true`. With `force`, sessions end with `.runtimeStopped` and the stop reason is `.user`.
- `stopRuntime` in the host state `restartPending` has a 60 s deadline. When the stop is the last activity, apkrund exits 0 after the reply ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6).
- `restartRuntime` is `stopRuntime` followed by `ensureReady` (reason as for `startRuntime`) under one operation ID. Its result is the final `RuntimeStatus` (`OperationOutput.runtime`). A cancel during the stop is `notCancellable`. A cancel after the stop leaves Android stopped.
- `resetRuntime` in any state other than `failed` and without an active boot-loop guard is a no-op that returns the current status.

### 5.3 Status DTOs

```swift
public struct RuntimeStatus: Codable, Sendable {
    public var state: WireRuntimeState
    public var bootProgress: BootProgress? // while booting
    public var owner: RuntimeOwner //.apkrund,.apkrunDev (the instance lock holder)
    public var hostState: HostState // §3.7
    public var provisioning: WireProvisioningState
    public var uptimeMs: Int64? // since the last ready
    public var idle: IdleStatus
    public var bootLoopGuard: BootLoopGuardStatus?
    public var imageVersion: ImageVersion? // the current image
    public var agents: [AgentConnection]
    public var developerMode: Bool
    public var runtimeVersion: String
    public var runtimeBuild: Int
    public var lastFailure: WireError? // the last RuntimeFailure, kept until the next ready
    public var lastStopReason: WireStopReason?
}

public enum WireRuntimeState: Codable, Sendable, Equatable { // state-machines.md §2
    case stopped
    case booting(BootPhase)
    case ready
    case suspended
    case stopping(WireStopReason)
    case failed(WireError)
    case unknown // open enum (§2.3)
}

public enum BootPhase: String, Codable, Sendable { case kernel, `init`, systemServer, bootCompleted, agentsConnecting }
public enum WireStopReason: String, Codable, Sendable { case user, idle, hostShutdown, hostUpdate, migration, reset, failure }
public enum RuntimeOwner: String, Codable, Sendable { case apkrund, apkrunDev }

public struct BootProgress: Codable, Sendable, Equatable {
    public var phase: BootPhase
    public var fraction: Double? // an estimate from the phase and the last boot's durations
    public var elapsedMs: Int64
    public var purpose: BootPurpose
}

public enum BootPurpose: Codable, Sendable, Equatable {
    case normal
    case firstBoot // provisioning
    case imageUpdate(from: ImageVersion, to: ImageVersion) // runtime-maintenance.md §4.7
}

public struct IdleStatus: Codable, Sendable {
    public var activities: [ActivityKind] // §17.2; empty = idle
    public var idleSince: Date?
    public var suspendAt: Date? // nil when runtime.idleSuspendMinutes = 0 or not idle
    public var stopAt: Date?
}

public struct BootLoopGuardStatus: Codable, Sendable {
    public var failures: Int // within the window
    public var windowStartedAt: Date
    public var tripped: Bool // 3 failures within 10 minutes (runtime-daemon.md §3.6)
}

public struct AgentConnection: Codable, Sendable {
    public var agent: AgentKind // §17.2
    public var state: AgentConnectionState //.connected,.connecting,.disconnected,.incompatible
    public var protocolVersion: String?
    public var required: Bool // dev image: guestd; custom image: guestd and store
}

public struct RuntimeSummary: Codable, Sendable { // the wrapper endpoint's view
    public var state: WireRuntimeState
    public var bootProgress: BootProgress?
    public var hostState: HostState
    public var provisioned: Bool
    public var runtimeVersion: String
}
```

`runtimeInfo`:

```swift
public struct RuntimeInfoRequest: Codable, Sendable {
    public var resources: Bool // apkrun info --runtime
    public var displays: Bool // apkrun info --displays
}

public struct RuntimeInfo: Codable, Sendable {
    public var status: RuntimeStatus
    public var sizing: RuntimeSizing // cpuCount, memoryGiB, userdataGiB in effect
    public var displayPoolSize: Int
    public var resources: ResourceUsage? // guest memory, IOSurface memory, host process memory, disk use of the instance
    public var displays: [DisplaySlotSnapshot]? // slot, DisplayState, holder SessionID, pixel size, density
}
```

`runtimeInfo` never starts Android. With Android stopped, `resources` has only the host values.

### 5.4 Setup and Reset Android

```swift
public struct SetupRequest: Codable, Sendable {
    public var image: SetupImageSource
    public var recreateInstance: Bool? // Start Over (host-ui.md §4) after 2 failed first boots: delete the instance, then create it again. Chosen (§19.1)
}

public enum SetupImageSource: Codable, Sendable {
    case archive(fileIndex: Int) // a signed image archive the client opened (apkrun setup --image <file>)
    case directory(bookmark: Data) // a local bundle directory (development, M4–M9)
    case feed // download from the release feed (#087)
}

public struct ResetAndroidRequest: Codable, Sendable {
    public var keepBackup: Bool // create a recovery point, kept 7 days (default true)
    public var confirmed: Bool // the user typed "Reset" (GUI) or answered the prompt / --yes (CLI)
}

public enum WireProvisioningState: Codable, Sendable, Equatable { // runtime-daemon.md §9.2
    case notStarted, checkingHost
    case installingImage(fraction: Double)
    case creatingInstance
    case firstBoot(BootPhase, fraction: Double)
    case installingAgents, verifying, complete
    case failed(step: ProvisioningStep, error: WireError)
    case unknown
}

public enum ProvisioningStep: String, Codable, Sendable {
    case checkingHost, installingImage, creatingInstance, firstBoot, installingAgents, verifying
}
```

- `setup` runs only the steps that are not complete. A second `setup` while one runs returns the running handle (§4.7). `setup` on a provisioned instance returns `OperationResult.succeeded` at once.
- `checkingHost` failures return `runtime.hostRequirementsNotMet([HostRequirement])` with every failed requirement ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9.1).
- `resetAndroid` with `confirmed = false` returns `runtime.malformedRequest`. Confirmation is the client's job; the flag exists so no client can erase data by accident.
- `resetAndroid` runs `stop(.reset, force)`, creates the recovery point unless `keepBackup` is false, deletes the instance, provisions again, and marks every managed package `needsReinstall(.userdataReset)`.

### 5.5 Errors

| Operation | Errors |
|---|---|
| `startRuntime` | `runtime.notProvisioned`, `runtime.instanceLocked`, `runtime.hostRequirementsNotMet`, `runtime.image`, `runtime.vm`, `runtime.graphics`, `runtime.bootTimedOut`, `runtime.bootStalled`, `runtime.kernelPanic`, `runtime.androidBootFailed`, `runtime.agentIncompatible`, `runtime.requiredAgentUnavailable`, `maintenance.noCompatibleImage` |
| `stopRuntime`, `restartRuntime` | `runtime.busy(activities:)` (without `force`), `runtime.stopTimedOut` (in the result; the forced stop still completes), `runtime.invalidTransition` |
| `resetRuntime` | `runtime.invalidTransition` (while `stopping`) |
| `resetAndroid` | `runtime.busy`, `runtime.notProvisioned`, `image.*` (recovery point), `runtime.hostRequirementsNotMet` |
| `setup` | `runtime.hostRequirementsNotMet`, `runtime.instanceLocked`, `image.*`, `maintenance.imageFeedUnreachable` and the other feed errors (`.feed`), `maintenance.insufficientSpace`, the boot errors of `startRuntime` |

---

## 6. Sessions and displays

### 6.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `openSession` | `OpenSessionRequest` → `SessionDescriptor` + `[IOSurface]` | W, L | W (30 s after `acquiringDisplay`) | session channel (§6.3), `sessions.opened` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.1, [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7 |
| `launch` | `LaunchRequest` → `LaunchReply` | C | W | `sessions.*` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.2 |
| `terminate` | `TerminateRequest` → `Empty` | C | U | `sessions.ended` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.2 |
| `listSessions` | `Empty` → `[SessionSummary]` | C | Q | — | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.6 |
| session channel messages | §6.3 | W, L (own session) | 1 or U | §6.3 | [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3 |

APKRun.app and the CLI never open app sessions. They call `launch`, which opens the wrapper or the generic launcher, and that process opens the session (ADR-0006).

### 6.2 `openSession`, `launch`, `terminate`

```swift
public struct OpenSessionRequest: Codable, Sendable {
    public var packageID: PackageID
    public var geometry: DisplayGeometry
    public var screenSize: CGSize // visible frame of the window's screen, in points
    public var launchTiming: LaunchTiming? // diagnostics.md §4.2
}

public struct DisplayGeometry: Codable, Sendable, Equatable {
    public var pointSize: CGSize // window content size in points
    public var backingScale: Double // 1.0 or 2.0
    public var zoom: Double // 0.75…2.0
}

public struct LaunchTiming: Codable, Sendable {
    public var processStart: UInt64 // continuous-clock nanoseconds
    public var requestSent: UInt64
}

public struct SessionDescriptor: Codable, Sendable {
    public var sessionID: UUID // the.app session
    public var displayID: DisplayID
    public var windowPrefs: WindowPrefs
    public var inputPrefs: InputPrefs // the input.* values in effect for this session (§14.2)
    public var windowMode: AndroidWindowMode //.secondaryDisplay,.primaryDisplayCompatibility
    public var state: SessionPhase
    public var surfaces: SurfaceSet // the IOSurfaces travel next to the JSON, in index order
}

public struct SurfaceSet: Codable, Sendable {
    public var generation: UInt32
    public var surfaceCount: Int // 3
    public var pixelSize: PixelSize // { width, height }, Int
    public var densityDpi: Int
}

public struct WindowPrefs: Codable, Sendable, Equatable {
    public var resizable: Bool
    public var alwaysOnTop: Bool
    public var zoom: Double
}
```

Server steps ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.1):

1. Authorize. A wrapper may name only its own package. The generic launcher may name any installed package.
2. An existing session for the package: the same client gets the existing descriptor, and the window just activates. Another client takes the session over; the old client receives `windowRequest(.close)`. An orphaned session is re-attached (below).
3. `runtime.packageNotInstalled` when the store has no installed record.
4. A store transaction for the package is running: the session reports `waitingForPackage` and waits up to 30 s ("Updating ‹App›…"). Then it continues or fails with `store.operationInProgress`.
5. The runtime is not `ready`: the session reports `booting(BootProgress)` and calls `ensureReady(.session(id))`. `openSession` is accepted in every runtime state except `failed` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §2). Queued sessions stay queued across a stop and start a new boot after it.
6. `acquiringDisplay`: the pool allocates a display. The reply is sent here, with the surfaces.
7. `launching`, then `running` at the first frame. These arrive as `stateChanged` events.

While the reply is outstanding, apkrund sends `stateChanged` at least every 10 s (a repeat of the current phase with a new `elapsedMs`). The client's timeout (§4.6) restarts with every session event.

Session phase on the wire:

```swift
public enum SessionPhase: Codable, Sendable, Equatable {
    case starting // requested, acquiringDisplay
    case booting(BootProgress) // waitingForRuntime
    case waitingForPackage // a store transaction of the package is running
    case launching
    case running // running and backgrounded
    case ended(SessionEndReason)
    case unknown
}

public enum SessionEndReason: Codable, Sendable, Equatable { // state-machines.md §3
    case userClosed, appExited, appCrashed, runtimeStopped
    case updating // "Update Now" for this package; APKRun reopens it after the update
    case runtimeUpdating // APKRun or Android system update; the launcher shows screen U and reopens
    case packageUninstalled // the package is being uninstalled (package-store.md §8)
    case error(WireError)
    case unknown
}
```

`closing` is not sent. The client that sent `closeSession` knows it. `backgrounded` is not sent, because the client caused it with `visibilityChanged(false)`.

Orphaned sessions ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §7.3): a connection that is invalidated without `closeSession` leaves its session orphaned for 3 s. An `openSession` for the same package within 3 s re-attaches it: the reply has the current descriptor with a new surface generation. After 3 s, the package's close policy applies.

```swift
public struct LaunchRequest: Codable, Sendable {
    public var packageID: PackageID
}

public struct LaunchReply: Codable, Sendable {
    public var session: SessionSummary // state running, or the ended state
    public var via: LaunchPath //.wrapper(bundleURL: URL),.genericLauncher
}

public struct TerminateRequest: Codable, Sendable {
    public var packageID: PackageID
}
```

- `launch` opens the registered wrapper when its `WrapperStatus.state` is `valid`, otherwise the generic launcher (`APKRun.app/Contents/Helpers/APKRunLauncher.app --package <id>`). A running wrapper is activated. The process must connect within 20 s, or the reply is `runtime.launchTimedOut`. Then the reply waits until the session is `running` or `ended`.
- `terminate` sends `windowRequest(.close)` to the session's client, stops keep-running tasks of the package, and sends `StopApplication` to the Guest Agent. The session ends with `.userClosed`. Without a session, it only force-stops the app when Android is `ready`. It never starts Android.

`SessionSummary` (also the payload of the `sessions` topic):

```swift
public struct SessionSummary: Codable, Sendable {
    public var sessionID: UUID
    public var packageID: PackageID
    public var displayName: String
    public var state: SessionPhase
    public var displayID: DisplayID?
    public var clientKind: ClientKind //.wrapper or.launcher
    public var openedAt: Date
    public var windowMode: AndroidWindowMode
    public var recording: Bool // microphone in use (desktop-integration.md §8.2)
    public var pointSize: CGSize? // window content size of the last openSession or resize; Use Current Size (§14.3)
}
```

### 6.3 Session channel

The session channel is the set of messages on the connection that owns a session. They need no session ID: a connection holds at most one session (§1.6). Messages before `openSession` replied, or after the session ended, are dropped (one-way) or return `runtime.invalidTransition` (request/reply).

Client → apkrund:

| Message | Shape | Kind | Rule | Design |
|---|---|---|---|---|
| `frameDisplayed` | `(generation: UInt32, frameSeq: UInt64)` | 1 | sent from the Core Animation transaction completion block. Frees older buffers | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §5 |
| `visibilityChanged` | `(Bool)` | 1 | `false` → `backgrounded`: presents stop | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.5 |
| `focusChanged` | `(Bool)` | 1 | key window. `false` also sends `cancelAll` to the input stream | [../02-design/input.md](../02-design/input.md) §7.2, [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.5 |
| `sendInput` | `InputBatch` | 1 | §7 | [../02-design/input.md](../02-design/input.md) §8 |
| `sendText` | `WireImeTextEvent` | 1 | §7 | [../02-design/input.md](../02-design/input.md) §5 |
| `resize` | `DisplayGeometry` → `Empty` | U | after live resize ends, and on backing-scale or zoom changes. New surfaces arrive with `surfacesReplaced` | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.1, §7.2 |
| `closeSession` | `CloseSessionRequest` → `Empty` | U | window closed. The session goes to `closing`, then `ended(.userClosed)` | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.6 |
| `pushClipboard` | `ClipItem` → `ClipAck` | U (500 ms at the client) | §11.2 | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §4.2 |
| `clipboardWritten` | `ClipboardWritten` | 1 | §11.2 | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §4.3 |
| `importFiles` | `ImportFilesRequest` + `[FileHandle]` → `ImportResult` | W (10 min) | §11.2 | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6.2 |
| `acceptExport` | `AcceptExportRequest` + `[FileHandle]` (0 or 1) → `Empty` | W (10 min) | §11.2 | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §6.3 |
| `resolveLinkPrompt` | `ResolveLinkPromptRequest` → `Empty` | U | §11.2 | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §7.2 |
| `restartApp` | `Empty` → `Empty` | U | Android → Restart ‹App›: force-stops the app and launches it again on the same display. The session stays open; the phase goes to `launching`, then `running` | [../02-design/wrapper.md](../02-design/wrapper.md) §5.6, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.6 |
| `frameStatistics` | `Empty` → `SessionGraphicsStatistics` (§13.1) | Q | View → Show Frame Statistics. Developer mode only. The launcher polls once per second while the overlay is shown. Never starts Android | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §7.7 |

```swift
public struct CloseSessionRequest: Codable, Sendable {
    public var policy: ClosePolicy? //.stop,.keepRunning. nil = the package's window.closeBehavior
}
```

apkrund → client, on `RuntimeEventSink`:

| Callback | Payload | Notes |
|---|---|---|
| `frameReady` | `generation, surfaceIndex, frameSeq, presentationTime` | not JSON. `frameSeq` increases monotonically per session. `presentationTime` is `mach_absolute_time` |
| `surfacesReplaced` | `SurfaceSet` JSON + `[IOSurface]` | after `resize`, a backing-scale change, or a re-attach |
| `sessionEvent` | `SessionEvent` JSON | below |

```swift
public enum SessionEvent: Codable, Sendable {
    case stateChanged(SessionPhase)
    case imeStateChanged(EditorState)
    case windowRequest(WindowRequest) //.activate,.close,.setTitle(String)
    case windowPrefsChanged(WindowPrefs)
    case clipboardFromGuest(ClipItem) // only to the key window's session
    case exportOffered(ExportOffer)
    case linkPrompt(LinkPrompt)
    case unknown
}

public struct EditorState: Codable, Sendable, Equatable { // input.md §5.1
    public var focused: Bool
    public var inputType: Int32 // EditorInfo.inputType
    public var imeOptions: Int32
    public var selection: TextRange? // { start, end } in UTF-16 units
    public var composing: TextRange?
    public var cursorRect: DisplayRect? // display pixels { x, y, width, height }
}
```

### 6.4 Frames and surface generations

- apkrund owns the buffer states. A buffer is free again when the client reported `frameDisplayed` for a newer sequence and `IOSurfaceIsInUse` is false.
- No `frameDisplayed` for 1 s while frames are offered: the session is treated as not visible and presents stop until the next `frameDisplayed` or `visibilityChanged(true)`.
- After `surfacesReplaced(generation g+1)`, both sides ignore messages of generation g. The old pool is released after the first `frameDisplayed` of g+1, or after 1 s.
- Sizes are resolved by `DisplayGeometryResolver`: at least 320 × 400 dp, density 120–640 dpi, at most 4095 px per side, zoom clamped to 0.75…2.0 ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §6.1, §6.2). Out-of-range geometry is clamped, not refused.

### 6.5 Errors

| Operation | Errors |
|---|---|
| `openSession` | `runtime.packageNotInstalled`, `store.operationInProgress` (after 30 s), `runtime.bootLoop`, `runtime.notProvisioned`, `runtime.displayPoolExhausted`, `runtime.displayAttachFailed`, `runtime.primaryDisplayBusy`, `runtime.launchTimedOut`, `runtime.launchFailed`, `runtime.guestAgentUnavailable`, the boot errors of §5.5. After the reply, failures arrive as `ended(.error(…))` |
| `launch` | as `openSession`, plus `runtime.launchTimedOut` (the process did not connect, for example because a damaged wrapper shows screen D), `wrapper.launcherTemplateInvalid` (the generic launcher is missing) |
| `terminate` | `runtime.packageNotInstalled` |
| `resize` | `runtime.displayReconfigureFailed`, `runtime.displayLost` |
| `closeSession` | none beyond §4.5 |
| `restartApp` | `runtime.launchFailed`, `runtime.launchTimedOut`, `runtime.guestAgentUnavailable` |
| `frameStatistics` | `runtime.developerModeRequired` |

---

## 7. Input

### 7.1 Messages

| Message | Shape | Clients | Kind | Design |
|---|---|---|---|---|
| `sendInput` | `InputBatch` | W, L (own session) | 1 | [../02-design/input.md](../02-design/input.md) §2, §7, §8 |
| `sendText` | `WireImeTextEvent` | W, L (own session) | 1 | [../02-design/input.md](../02-design/input.md) §5 |
| `focusChanged` | `(Bool)` | W, L | 1 | §6.3 |

The input types of InputCore are `Sendable` but not `Codable`, and RuntimeAPI cannot import InputCore. RuntimeAPI therefore has wire copies. RuntimeClient imports neither InputCore nor WindowingCore, and its session object takes and delivers wire values only. In the launcher, `XPCInputSink` (APKRunLauncher) converts InputCore values to wire values, and `XPCFrameSource` (APKRunLauncher) adapts the session object to WindowingCore's `FrameSource`. RuntimeHost converts the wire values back to InputCore values before `InputRouter` ([../01-architecture/modules.md](../01-architecture/modules.md) §2, §3, [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §1).

### 7.2 Wire types

```swift
public struct InputBatch: Codable, Sendable {
    public var events: [WireInputEvent] // 1…512, in the order they happened
}

public struct InputTimestamp: Codable, Sendable { public var hostNanos: UInt64 } // mach continuous time of the NSEvent
public struct DisplayPoint: Codable, Sendable { public var x: Double; public var y: Double } // display pixels
public struct TextRange: Codable, Sendable { public var start: Int; public var end: Int } // UTF-16 code units

public enum WireInputEvent: Codable, Sendable {
    case touch(WireTouchEvent)
    case mouse(WireMouseEvent)
    case scroll(WireScrollEvent)
    case key(WireKeyEvent)
    case longPress(DisplayPoint, InputTimestamp)
    case cancelAll(InputTimestamp)
}

public struct WireTouchEvent: Codable, Sendable {
    public var phase: TouchPhase //.down,.move,.up,.cancel
    public var pointerID: Int // 0 in v1
    public var position: DisplayPoint
    public var time: InputTimestamp
}

public struct WireMouseEvent: Codable, Sendable {
    public var action: MouseAction //.hoverEnter,.hoverMove,.hoverExit,.press(MouseButton),.release(MouseButton)
    public var position: DisplayPoint
    public var buttons: Int32 // Android MotionEvent BUTTON_* bit mask of the buttons now down
    public var time: InputTimestamp
}

public enum MouseButton: String, Codable, Sendable { case primary, secondary, tertiary, back, forward }

public struct WireScrollEvent: Codable, Sendable {
    public var position: DisplayPoint
    public var vertical: Double // AXIS_VSCROLL units
    public var horizontal: Double // AXIS_HSCROLL units
    public var time: InputTimestamp
}

public struct WireKeyEvent: Codable, Sendable {
    public var action: KeyAction //.down,.up
    public var androidKeyCode: Int32 // KEYCODE_*
    public var metaState: Int32 // Android META_* bit mask
    public var repeatCount: Int32
    public var time: InputTimestamp
}

public enum WireImeTextEvent: Codable, Sendable {
    case commit(String)
    case setComposing(String, selection: TextRange)
    case finishComposing
    case key(WireKeyEvent) // editor-mode keys
    case editorAction(Int32) // EditorInfo.IME_ACTION_*
    case contextMenuAction(ContextMenuAction) //.copy,.cut,.paste,.selectAll
}
```

### 7.3 Rules and limits

- The session comes from the connection. Launchers never send display IDs. `InputRouter` adds the Android display ID of the session's lease.
- Coordinates are in the pixel space of the latest `SurfaceSet` the client received (§6.3).
- `sendInput` is batched per run-loop turn. `sendText` is sent at once, one event per message. Both keep their order on the connection.
- Events are accepted only while the session is `running` or `backgrounded`. Otherwise they are dropped.
- Per session: 2000 events per second and 64 KiB of text per second. `sendText` payloads are at most 4 KiB. A batch with more than 512 events is cut at 512. Excess is dropped.
- A `focusChanged(false)` makes apkrund send `cancelAll`, so no key or gesture stays pressed.
- Nothing is returned for dropped events. They are counted in the diagnostics snapshot: `input.dropped.rate`, `input.dropped.notRunning`, `input.dropped.invalid`, `input.coalesced` ([../02-design/input.md](../02-design/input.md) §11). An undecodable message is counted as `input.dropped.invalid` and does not invalidate the connection.

---

## 8. Packages and store

Store semantics: [../02-design/package-store.md](../02-design/package-store.md) §11. Store operations are served on the control endpoint. Wrappers get `packageInfo` and `packageIcon` for their own package only (package-store §11.2). The generic launcher gets both for any package.

### 8.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `importPackage` | `ImportPackageRequest` + files → `OperationHandle` (`import`) → `.importPreview(ImportPreview)` | C | L | `operations.*` (stages `copying`, `inspecting`) | [../02-design/package-store.md](../02-design/package-store.md) §4 |
| `installImported` | `InstallImportedRequest` → `OperationHandle` (`install`, or `update` for `relation == .update`) → `.package(PackageSummary)` (`.update(UpdateOutcome)` for kind `update`) | C | L | `packages.installed`, `.updated`, `.stateChanged`, `.operationProgress`; `updates.*` for updates | package-store §6.2 |
| `cancelImport` | `CancelImportRequest { ticket }` → `Empty` | C | U | — | package-store §11.1 |
| `inspectFile` | `ImportPackageRequest` + files → `OperationHandle` (`inspect`) → `.importPreview(ImportPreview)` | C | L | `operations.*` | package-store §4.3 |
| `listPackages` | `ListPackagesRequest { filter }` → `[PackageSummary]` | C | Q | — | package-store §9 |
| `packageInfo` | `PackageRequest { packageID }` → `PackageDetails` | C, L, W | Q | — | package-store §11.1 |
| `packageIcon` | `PackageIconRequest { packageID, sizePx }` → `PackageIcon` | C, L, W | Q | `packages.iconChanged` | package-store §10 |
| `uninstallPackage` | `UninstallPackageRequest` → `OperationHandle` (`uninstall`) | C | L | `packages.stateChanged`, `.removed`; `wrappers.removed`; `sessions.ended(.packageUninstalled)` | package-store §8 |
| `repairPackage` | `PackageRequest` → `OperationHandle` (`repair`) | C | L | `packages.stateChanged` | package-store §11.1 |
| `rollbackPackage` | `RollbackPackageRequest { packageID, allowDataLoss }` → `OperationHandle` (`rollback`) | C | L | `packages.rolledBack`; `updates.phaseChanged(rollingBack(.userRequested))` | package-store §7.3, [../02-design/update-system.md](../02-design/update-system.md) §8.5 |
| `adoptPackage` | `PackageRequest` → `PackageSummary` | C | U | `packages.installed`, `.unmanagedChanged` | package-store §9.3 |
| `updatePackageSettings` | §14 | C | U | `packages.settingsChanged` | package-store §2.4 |

`rollbackPackage` appears in [../02-design/update-system.md](../02-design/update-system.md) §11.1 and [../02-design/package-store.md](../02-design/package-store.md) §11.1. It is one operation, documented here. The mapping of #027's `install`, `uninstall`, `listInstalled`, and `applicationInfo` is in package-store §11.1.

### 8.2 Import and install

```swift
public struct ImportPackageRequest: Codable, Sendable {
    public var files: [ImportSourceFile] // 1…20
    public var origin: ImportOrigin //.addFlow,.document,.dropOnHome,.cli,.wrap. For logs and PackageSource
}

public struct ImportSourceFile: Codable, Sendable {
    public var fileIndex: Int // into the files: array (§4.9)
    public var name: String // last path component only; used for the container type and in messages
}

public struct InstallImportedRequest: Codable, Sendable {
    public var ticket: ImportTicket
    public var options: InstallOptions
}

public struct InstallOptions: Codable, Sendable {
    public var authority: UpdateAuthority? //.manual or.apkrun; nil = the default of update-system.md §2.4
    public var provider: ProviderSpec? // implies authority.apkrun
    public var updateChoice: UpdateChoice? //.automatic,.notifyOnly (apkrun install --updates); nil = the default choice
    public var createWrapper: Bool // create the Mac app at ~/Applications after the install (child operation)
}

public struct CancelImportRequest: Codable, Sendable { public var ticket: ImportTicket }
```

- `ImportPreview` and `ImportRelation` are the store's types, copied field for field ([../02-design/package-store.md](../02-design/package-store.md) §4.7). `icon` is a PNG (Base64).
- The client shows the preview and asks. `apkrun install --yes` skips the question. The server does not know whether the user was asked.
- `installImported` by relation: `newPackage` and `reinstallSameVersion` install; `uninstalledWithData` installs and keeps the data; `update` hands the ticket to UpdateCore as a manual update (handle kind `update`); `sameAsInstalled` returns `store.alreadyInstalled`; `downgrade` returns `store.downgradeRefused`; `otherSigner` returns `store.signerMismatch`.
- A ticket is valid for 60 minutes after its preview, and until apkrund exits. Later use returns `store.importExpired`. `inspectFile` deletes its ticket when it finishes.
- `createWrapper` failures do not fail the install. The result is `.package(PackageSummary)` with `wrapperError` set (§8.3). A client that needs the destination rules of [../02-design/wrapper.md](../02-design/wrapper.md) §6.3 (the CLI with `--wrap --output`) calls `createWrapper` itself with the same operation ID.

### 8.3 Queries

```swift
public struct ListPackagesRequest: Codable, Sendable { public var filter: PackageFilter } //.managed,.all
public struct PackageRequest: Codable, Sendable { public var packageID: PackageID }

public struct PackageSummary: Codable, Sendable {
    public var packageID: PackageID
    public var displayName: String
    public var versionCode: VersionCode
    public var versionName: String?
    public var state: WirePackageState
    public var managed: Bool // false: installed in Android by something else, no record
    public var installer: Installer //.apkrun,.external
    public var updateAuthority: UpdateAuthority //.apkrun,.googlePlay,.external,.manual
    public var updateChoice: UpdateChoice? // for .apkrun and .manual authority (update-system.md §2.3)
    public var wrapperStatus: WrapperStatus? // nil = no Mac app
    public var iconDigest: SHA256Digest?
    public var wrapperError: WireError? // only in the result of installImported with createWrapper
}

public enum WirePackageState: Codable, Sendable, Equatable { // state-machines.md §5
    case importing, inspecting, installing, installed
    case updating(WireUpdatePhase)
    case uninstalling, uninstalledKeepingData
    case needsReinstall(ReinstallReason) //.userdataReset,.userdataRestored
    case broken(WireBrokenReason) //.removedInAndroid,.signerChanged,.artifactMissing,.reinstallFailed(WireError)
    case unknown
}

public struct PackageDetails: Codable, Sendable {
    public var summary: PackageSummary
    public var record: WirePackageRecord? // the metadata.json form (package-metadata-json.md); nil for unmanaged packages
    public var settings: ResolvedPackageSettings // §14.2
    public var slots: ArtifactSlotsSummary // the artifacts object of package-metadata-json.md §2.3.2: current?, previous?, staged?; all nil for unmanaged packages
    public var sizes: PackageSizes // artifactsBytes, androidDataBytes?, androidCacheBytes? (last known)
    public var wrapperCount: Int
    public var lastOperation: OperationSummary?
    public var skippedVersions: [VersionCode]
    public var compatibility: CompatibilityInfo? // for the installed version (#090); nil = no database entry
}

public struct CompatibilityInfo: Codable, Sendable, Equatable { // diagnostics.md §10.3
    public var level: CompatibilityLevel //.nativeLike,.compatible,.compatibilityMode,.unsupported,.unknown (scope.md §4)
    public var label: CompatibilityLabel //.works,.worksWithLimitations,.unsupported,.unknown: the user-facing label
    public var issues: [CompatibilityIssue]
    public var recommendedKeys: [String] // the settings keys the entry recommends, for "Recommended for this app"
}

public struct CompatibilityIssue: Codable, Sendable, Equatable {
    public var id: String // "blank-secondary-display"
    public var title: [String: String] // language code → text, as in compatibility.json; the client picks its language
    public var workaround: [String: String]?
}

public struct PackageIconRequest: Codable, Sendable {
    public var packageID: PackageID
    public var sizePx: Int // 16…1024
}

public struct PackageIcon: Codable, Sendable {
    public var png: Data
    public var digest: SHA256Digest
    public var source: IconSource //.rendered,.hostPreview,.placeholder
}
```

- `listPackages` and `packageInfo` work while Android is stopped. They show the last known Android facts.
- A wrapper's `packageInfo` returns the same `PackageDetails`. The wrapper uses `summary` and the per-app window settings in `settings.window` (§14.2).
- `ImportPreview.compatibility` (package-store §4.7) and `PackageDetails.compatibility` come from the compatibility database in APKRun.app. `apkrun inspect` and `apkrun info <package>` print them. An app without an entry has `nil`, and the clients show nothing.

### 8.4 Uninstall, repair, rollback, adopt

```swift
public struct UninstallPackageRequest: Codable, Sendable {
    public var packageID: PackageID
    public var options: UninstallOptions
}

public struct UninstallOptions: Codable, Sendable {
    public var keepData: Bool // state uninstalledKeepingData
    public var trashWrappers: Bool // default true; apkrun uninstall --keep-wrapper sets false
    public var forget: Bool // remove the record without Android (for a broken package)
}

public struct RollbackPackageRequest: Codable, Sendable {
    public var packageID: PackageID
    public var allowDataLoss: Bool
}
```

- An open session of the package ends with `.packageUninstalled` before the guest uninstall.
- `rollbackPackage` with `allowDataLoss = false` fails with `store.rollbackUnavailable` when only the data-loss fallback remains. The client asks and repeats with `true`.
- `repairPackage` applies only to `broken` packages. Others return `store.operationInProgress` (a running transaction) or succeed without work.

### 8.5 Errors

| Operation | Errors |
|---|---|
| `importPackage`, `inspectFile` | the import and inspection cases of `StoreFailure` ([../02-design/package-store.md](../02-design/package-store.md) §12): `store.unsupportedContainer` … `store.insufficientHostSpace`; `integration.tooManyFiles` is not used here, more than 20 files is `runtime.malformedRequest` |
| `installImported` | `store.importExpired`, `store.alreadyInstalled`, `store.downgradeRefused`, `store.signerMismatch`, `store.operationInProgress`, `store.guestInstallFailed`, `store.guestStorageFull`, `store.userActionRequired`, `store.runtimeUnavailable`, `store.capabilityMissing`, `update.*` for manual updates |
| `cancelImport` | `store.importExpired` |
| `listPackages`, `packageInfo`, `packageIcon` | `store.packageNotFound`, `store.metadataUnreadable` |
| `uninstallPackage` | `store.packageNotFound`, `store.operationInProgress`, `store.uninstallFailed`, `store.runtimeUnavailable` |
| `repairPackage` | `store.packageNotFound`, `store.guestInstallFailed`, `store.runtimeUnavailable` |
| `rollbackPackage` | `store.rollbackUnavailable`, `store.rollbackFailed`, `store.packageInUse`, `store.operationInProgress` |
| `adoptPackage` | `store.packageNotFound`, `store.operationInProgress` |
| all store operations | `store.journalUnreadable`, `store.storeReadOnly` |

---

## 9. Updates

Update semantics: [../02-design/update-system.md](../02-design/update-system.md). All update operations are control only. Wrappers get nothing from UpdateCore (update-system §11.1).

### 9.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `checkForUpdates` | `CheckForUpdatesRequest { packages? }` → `OperationHandle` (`updateCheck`) → `.updateCheck([UpdateCheckResult])` | C | L | `updates.phaseChanged`, `.summaryChanged` | update-system §3, §11.1 |
| `listUpdates` | `Empty` → `[PackageUpdateStatus]` | C | Q | — | update-system §11.1 |
| `updatePackage` | `UpdatePackageRequest` (+ files) → `OperationHandle` (`update`) → `.update(UpdateOutcome)` | C | L | `updates.*`, `packages.updated`, `sessions.ended(.updating)` | update-system §7.3 |
| `setUpdatePolicy` | `SetUpdatePolicyRequest` → `PackageUpdateStatus` | C | U (30 s) | `packages.settingsChanged`, `packages.stateChanged` | update-system §2.3 |
| `setUpdateAuthority` | `SetUpdateAuthorityRequest` → `PackageUpdateStatus` | C | U | `packages.settingsChanged`, `packages.stateChanged` | update-system §2.1 |
| `skipVersion` | `SkipVersionRequest { packageID, versionCode }` → `Empty` | C | U | `updates.phaseChanged(completed(.skipped(.userSkipped)))` | update-system §8.4 |
| `unskipVersion` | `SkipVersionRequest` → `Empty` | C | U | — | update-system §8.4 |
| `updateHistory` | `UpdateHistoryRequest { packageID?, limit }` → `[UpdateHistoryEntry]` | C | Q | — | update-system §10.2 |
| `rollbackPackage` | §8.4 | C | L | | update-system §8.5 |

### 9.2 DTOs

```swift
public struct CheckForUpdatesRequest: Codable, Sendable {
    public var packages: [PackageID]? // nil = every package with authority.apkrun
    public var checkOnly: Bool // default false. true: report only, nothing is downloaded or installed (apkrun update --check-only; the field comes with #038)
}
```

- `checkOnly` defaults to `false`, and a missing key decodes as `false`. With `true`, the check only reports: no result is `installed` or `waiting`, and nothing is downloaded. `apkrun update --check-only` sets it. The flag exists since #037, when every check still stops at `available`; the field comes with #038, which lets a check go past `available` ([../04-plan/issues/M06-update-system.md](../04-plan/issues/M06-update-system.md) #038 Notes).
- With `false`, each package goes on as its update choice says ([../02-design/update-system.md](../02-design/update-system.md) §5). An `automatic` package downloads and installs under the gentle rules, so its result can be `installed` or `waiting`. A `notifyOnly` or `manual` package stops at `available`.

```swift
public struct UpdateCheckResult: Codable, Sendable {
    public var packageID: PackageID
    public var outcome: UpdateCheckOutcome //.upToDate,.available(WireUpdateCandidate),.installed(from:to:),.waiting(WaitingReason),.failed(WireError)
}

public struct PackageUpdateStatus: Codable, Sendable {
    public var packageID: PackageID
    public var choice: UpdateChoice? // nil for googlePlay and external
    public var authority: UpdateAuthority
    public var provider: ProviderSummary? // type and host only, never full URLs or tokens
    public var phase: WireUpdatePhase?
    public var candidate: WireUpdateCandidate?
    public var lastCheckAt: Date?
    public var nextCheckAt: Date?
    public var consecutiveFailures: Int
    public var waiting: [WaitingReason] // the gate conditions that are false: GU1…GU7 (update-system.md §7)
}

public struct ProviderSummary: Codable, Sendable, Equatable {
    public var type: ProviderType //.local,.direct,.fdroid,.github
    public var label: String // the folder name (local), the host (direct, fdroid), or owner/name (github)
    public var channel: String? // github: "stable" or "prerelease"
    public var hasToken: Bool // github: a token is stored in the Keychain. The token itself is never returned
}

public enum WireUpdatePhase: Codable, Sendable, Equatable { // state-machines.md §6
    case checking
    case available(WireUpdateCandidate)
    case downloading(progress: Double)
    case validating, staged, installing, healthChecking
    case rollingBack(RollbackReason) //.healthCheckFailed(WireError),.userRequested
    case completed(UpdateOutcome)
    case unknown
}

public enum UpdateOutcome: Codable, Sendable, Equatable {
    case updated(from: VersionCode, to: VersionCode)
    case rolledBack(reason: RollbackReason)
    case keptAfterFailedHealthCheck(reason: WireError)
    case skipped(SkipReason) //.upToDate,.checkFailed(WireError),.downloadFailed(WireError),.validationFailed(WireError),.installFailed(WireError),.userSkipped,.authorityChanged (state-machines.md §6, update-system.md §5)
}

public struct WireUpdateCandidate: Codable, Sendable, Equatable {
    public var versionCode: VersionCode? // nil when the provider cannot know it before download
    public var versionName: String?
    public var provider: ProviderType //.local,.direct,.fdroid,.github
    public var releaseNotes: String? // plain text, at most 16 KiB
    public var publishedAt: Date?
    public var downloadBytes: Int64?
}

public struct UpdatePackageRequest: Codable, Sendable {
    public var packageID: PackageID
    public var options: UpdateNowOptions
}

public struct UpdateNowOptions: Codable, Sendable {
    public var closeRunningApp: Bool // true: the session ends with .updating and reopens after; false: wait until the app quits
    public var files: [ImportSourceFile]? // a manual update from files (apkrun update --file)
}

public struct SetUpdatePolicyRequest: Codable, Sendable {
    public var packageID: PackageID
    public var policy: UpdatePolicy
}

public struct SetUpdateAuthorityRequest: Codable, Sendable {
    public var packageID: PackageID
    public var authority: AuthorityChoice //.apkrun,.manual,.external. Only #097 sets googlePlay
}

public struct UpdatePolicy: Codable, Sendable {
    public var choice: UpdateChoice //.automatic,.notifyOnly,.manual
    public var provider: ProviderChange //.keep,.set(ProviderSpec),.remove
}

public struct ProviderSpec: Codable, Sendable {
    public var spec: String // local:<path>, direct:<https-url>, fdroid[:<url>#<fingerprint>], github:<owner>/<name>[:<glob>][@prerelease]
    public var bookmark: Data? // required for local: apkrund does not open the path
    public var token: String? // github: written to the Keychain, never returned
}

public struct UpdateHistoryRequest: Codable, Sendable {
    public var packageID: PackageID?
    public var limit: Int // default 50, at most 1000
}

public struct UpdateHistoryEntry: Codable, Sendable { // one line of Updates/history.jsonl
    public var time: Date
    public var packageID: PackageID
    public var from: VersionCode?
    public var to: VersionCode?
    public var provider: ProviderType?
    public var trigger: UpdateTrigger //.scheduled,.userInitiated,.manual,.launchOpportunistic
    public var outcome: UpdateOutcome
    public var failure: WireError?
    public var phaseDurationsMs: [String: Int64]
}
```

- `ProviderSpec.spec` accepts alternate flag spellings only on the CLI. The CLI translates `--update auto|notify|manual` and `--update-provider direct --update-url <url>` before calling UpdateCore ([../02-design/update-system.md](../02-design/update-system.md) §11.3).
- `setUpdatePolicy` validates the provider configuration. For F-Droid and GitHub it makes one test request. A failure writes nothing.
- `ProviderSpec.token` goes only from the client to apkrund. apkrund stores it in the Keychain (service `io.apkrun.provider.github`) and never returns it, logs it, or writes it to `settings.json` (update-system §4.6). A request without `token` keeps a stored token for the same repository, and `""` deletes it. Replies show only `ProviderSummary.hasToken`.
- The choices `.automatic` and `.notifyOnly` need a provider. Without one, `setUpdatePolicy` returns `update.providerNotConfigured`.
- `updatePackage` for a package whose app is open and `closeRunningApp = false` stays running with `waiting` until the app quits. The CLI prints "will update when ‹App› quits" and returns; a closed connection cancels nothing, and only a cancel ends the wait (§4.7). With `closeRunningApp = true`, the session ends with `.updating`, the update installs, and the app reopens. In both cases, an app opened again before the Android commit is requested cancels the install: the update goes back to `staged`, and the operation waits until the app quits ([../02-design/update-system.md](../02-design/update-system.md) §7.3).
- `setUpdateAuthority` goes through `PackageStore.setUpdateAuthority`, which calls `RelinquishUpdateOwnership` before it writes the record when the package moves to `external` ([../02-design/package-store.md](../02-design/package-store.md) §6.3). It never starts Android. A move to `apkrun` needs the provider kept in the record.

### 9.3 Errors

| Operation | Errors |
|---|---|
| `checkForUpdates` | per package in `UpdateCheckResult.failed`: `update.providerUnreachable`, `update.providerHTTPStatus`, `update.providerRateLimited`, `update.providerMetadataInvalid`, `update.providerSignatureInvalid`, `update.noCompatibleArtifact`, `update.ambiguousAsset` |
| `updatePackage` | the above, plus `update.downloadFailed`, `update.hashMismatch`, `update.tooLarge`, `update.validation`, `update.authorityDoesNotAllowUpdates`, `update.installFailed`, `update.healthCheckFailed`, `update.rollbackFailed`, `update.cancelled` |
| `setUpdatePolicy` | `update.providerNotConfigured`, `update.providerUnreachable`, `update.providerMetadataInvalid`, `update.authorityDoesNotAllowUpdates` (googlePlay, external), `store.packageNotFound` |
| `setUpdateAuthority` | `update.providerNotConfigured` (to `apkrun` without a kept provider), `update.authorityDoesNotAllowUpdates` (googlePlay), `store.packageNotFound` |
| `skipVersion`, `unskipVersion`, `updateHistory` | `store.packageNotFound` |

---

## 10. Wrappers

Wrapper semantics: [../02-design/wrapper.md](../02-design/wrapper.md). Generation, refresh, removal, verification, and approval answers are served on the control endpoint. The wrapper endpoint serves only the operations of §10.1.

### 10.1 Wrapper endpoint

A wrapper's launcher may call exactly these operations. They always refer to the package in the wrapper's registry entry. A request that names another package returns `runtime.notAuthorized` (§1.4).

| Endpoint | Operation | Section |
|---|---|---|
| broker | `hello`, `requestEndpoint`, `requestApproval` | §3.2–§3.4 |
| wrapper | `runtimeStatus` (reply `RuntimeSummary`) | §5.1 |
| wrapper | `openSession` and the session channel | §6.2, §6.3 |
| wrapper | `packageInfo`, `packageIcon` (own package) | §8.3 |
| wrapper | `importBootstrap` | §10.7 |
| wrapper | `notificationRelay` (stream), `notificationRelayResponse` (one-way) | §11.3 |
| wrapper | `subscribe`, `unsubscribe` (topic `operations` only, own operations) | §16.1 |
| wrapper | `cancel`, `operationStatus` (own operations) | §4.7 |
| wrapper | `closeStream` | §16.4 |

The wrapper endpoint serves major N and N−1 (§2.4). Every item of this list is part of the wrapper contract. Removing one, or changing its shape, is a major change.

### 10.2 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `createWrapper` | `WrapperRequest` (+ 0 or 1 icon file) → `OperationHandle` (`wrapperCreate`) → `.wrapper(WrapperInfo)` | C | L | `wrappers.created`, `operations.*` | [../02-design/wrapper.md](../02-design/wrapper.md) §6 |
| `placeStagedWrapper` | `PlaceStagedWrapperRequest` → `WrapperInfo` | C | U | `wrappers.created` or `.refreshed` | wrapper §6.3 |
| `listWrappers` | `Empty` → `[WrapperSummary]` | C | Q (results cached 60 s) | `wrappers.statusChanged` | wrapper §9.1, §12.1 |
| `wrapperInfo` | `PackageRequest` → `WrapperInfo` | C | Q | — | wrapper §12.1 |
| `refreshWrapper` | `RefreshWrapperRequest` (+ 0 or 1 icon file) → `OperationHandle` (`wrapperRefresh`) → `.wrapper(WrapperInfo)` | C | L | `wrappers.refreshed`, `operations.*` | wrapper §9.3 |
| `refreshAllWrappers` | `RefreshAllWrappersRequest` → `OperationHandle` (`wrapperRefreshAll`) → `.wrappers(WrapperBatchResult)` | C | L | `wrappers.refreshed` per wrapper, `operations.*` | wrapper §9.1, §9.4, §12.1 |
| `removeWrapper` | `RemoveWrapperRequest` → `Empty` | C | U | `wrappers.removed` | wrapper §9.5 |
| `verifyWrapper` | `VerifyWrapperRequest` → `WrapperVerification` | C | Q (5 s, 60 s with `deep`) | `wrappers.statusChanged` for a registered bundle | wrapper §9.1 |
| `approveWrapper` | `ApproveWrapperRequest` → `WrapperSummary` | C | U | `wrappers.created` | wrapper §7.3 |
| `pendingApprovals` | `Empty` → `[ApprovalPrompt]` | A | Q | — | wrapper §7.3, §12.1 |
| `decideApproval` | `DecideApprovalRequest` → `Empty` | A | U | `wrappers.approvalResolved`, `wrappers.created` on allow | wrapper §7.3 |
| `deniedWrappers` | `Empty` → `[DeniedWrapper]` | C | Q | — | wrapper §7.3, §12.1 |
| `clearWrapperDenial` | `ClearWrapperDenialRequest` → `Empty` | C | U | — | wrapper §7.3, §12.1 |
| `rescanWrappers` | `RescanWrappersRequest` → `RescanResult` | C | U | `wrappers.created` per registered bundle | wrapper §7.2, §12.1 |
| `buildDistributionWrapper` | `DistributionWrapperRequest` (+ 0 or 1 icon file) → `OperationHandle` (`distributionWrapper`) → `.distributionWrapper(DistributionWrapperResult)` | C | L | `operations.*` | wrapper §11 (M12) |
| `importBootstrap` | `ImportBootstrapRequest` + files → `OperationHandle` (`bootstrapImport`) → `.package(PackageSummary)` | W | L | `operations.*` (own), `packages.installed` | wrapper §10.2 |

- `pendingApprovals` lets APKRun.app show a prompt that was requested before it connected. `wrappers.approvalRequested` carries the same `ApprovalPrompt`.
- `deniedWrappers` and `clearWrapperDenial` back Settings → Privacy → denied Mac apps and its **Remove** button ([../02-design/host-ui.md](../02-design/host-ui.md) §9.4, wrapper §7.3 step 5).
- `rescanWrappers` backs **Re-register Mac Apps** after a lost registry (wrapper §7.2). With `register = false` it only lists the candidates, so the client can show the confirmation.

### 10.3 Generation and placement

```swift
public struct WrapperRequest: Codable, Sendable {
    public var packageID: PackageID
    public var destination: WireWrapperDestination? // nil = wrappers.defaultLocation; "ask" there means.userApplications
    public var fileName: String? // override of the file name rule (wrapper.md §4.3)
    public var displayName: String? // nil = the package's display name
    public var icon: WrapperIconChoice? // nil = the Android icon
    public var portable: Bool
    public var replace: WireReplacePolicy //.never,.sameWrapper
    public var importTicket: ImportTicket? // portable wrapper of a package that is not installed (wrapper.md §10.1)
    public var windowDefaults: WrapperWindowDefaults? // wrapper.json "window"; --window-size, --resizable
    public var updateDefaults: WrapperUpdateDefaults? // wrapper.json "updates"; only together with importTicket
}

public enum WireWrapperDestination: Codable, Sendable, Equatable {
    case userApplications // ~/Applications, created if missing
    case applications // /Applications; needs an admin user
    case directory(URL)
}

public enum WrapperIconChoice: Codable, Sendable, Equatable {
    case android // the store's icon files (package-store.md §10)
    case custom(fileIndex: Int) // PNG, square, at least 512 px
}

public enum WireReplacePolicy: String, Codable, Sendable { case never, sameWrapper }

public struct WrapperWindowDefaults: Codable, Sendable, Equatable {
    public var defaultWidth: Int? // points
    public var defaultHeight: Int?
    public var resizable: Bool?
}

public struct WrapperUpdateDefaults: Codable, Sendable, Equatable {
    public var authority: UpdateAuthority?
    public var choice: UpdateChoice?
    public var provider: ProviderSpec? // ProviderSpec.token is refused here: a wrapper never carries a token
}

public struct PlaceStagedWrapperRequest: Codable, Sendable {
    public var stagingToken: StagingToken
    public var finalURL: URL // where the client moved the bundle, or the wrapper whose Contents it swapped (§10.5)
    public var bookmark: Data // bookmark of finalURL, created by the client
}
```

- The `.wrapper(WrapperInfo)` output is sent after step 13 of wrapper §6.2. `registrationFailed` does not fail the operation. It is in `WrapperInfo.warnings`.
- `replace =.sameWrapper` for an existing wrapper of the same package runs a refresh at that location (wrapper §6.4). For a `signatureInvalid` wrapper it moves the modified bundle to the Trash and generates again (**Create It Again**, wrapper §9.1).
- `updateDefaults` for an installed package returns `runtime.malformedRequest`. The CLI says to use `apkrun update policy` instead (wrapper §12.2).
- An `importTicket` must be a ticket of a `newPackage` preview for the same package ID. The operation uses the ticket's artifact set and the host preview icon, and does not consume the ticket.

**Access denied at the destination.** When apkrund may not write to the destination (macOS privacy controls), the operation fails with `wrapper.destinationNotAccessible(URL, stagingToken)`. The error has two parameters: `stagingToken`, and `stagedPath` (a `.fileName` parameter with the path of the signed bundle in staging, `~/Library/Application Support/APKRun/Wrappers/staging/<stagingToken>/<fileName>.app`). The client moves the bundle to the destination itself and calls `placeStagedWrapper`, and apkrund finishes steps 12 and 13 of wrapper §6.2. The CLI does this automatically. The GUI does it after the Save panel (**Choose Another Location…**, [../02-design/host-ui.md](../02-design/host-ui.md) §6).

- A staging token is valid for 60 minutes and until apkrund exits. Later use returns `wrapper.stagingExpired`. An expired token's staging directory is deleted.
- `placeStagedWrapper` checks that the bundle at `finalURL` has the staged cdhash. Otherwise it returns `wrapper.verificationFailed`.

### 10.4 Status, list, and verification

`WrapperStatus` and `WrapperState` are the types of [../02-design/wrapper.md](../02-design/wrapper.md) §9.1, copied field for field. `refreshReasons` encodes as an array.

```swift
public struct WrapperSummary: Codable, Sendable {
    public var packageID: PackageID
    public var bundleID: String
    public var displayName: String
    public var kind: WrapperKindTag //.local,.portable,.distribution
    public var bundleURL: URL // the registry path, updated after a move
    public var status: WrapperStatus
    public var approval: WrapperApproval //.generated,.user
    public var launcherVersion: String
    public var createdAt: Date
    public var refreshedAt: Date?
}

public struct WrapperInfo: Codable, Sendable {
    public var summary: WrapperSummary
    public var fileName: String
    public var customization: WrapperCustomization // displayName?, customIcon: Bool
    public var signer: WrapperSigner
    public var cdhash: String
    public var launcherAPI: APIVersion
    public var formatVersion: Int
    public var iconDigest: SHA256Digest
    public var lastValidatedAt: Date?
    public var warnings: [WireError] // for example wrapper.registrationFailed
}

public enum WrapperSigner: Codable, Sendable, Equatable {
    case adHoc
    case developerID(teamID: String, teamName: String?, notarized: Bool)
    case unknown
}

public struct VerifyWrapperRequest: Codable, Sendable {
    public var bundleURL: URL
    public var deep: Bool // adds SecStaticCodeCheckValidity (strict, all architectures)
}

public struct WrapperVerification: Codable, Sendable {
    public var bundleURL: URL
    public var bundleID: String?
    public var packageID: PackageID? // APKRunPackageID of the bundle
    public var kind: WrapperKindTag?
    public var registered: Bool // bundle ID and cdhash match the registry
    public var state: WrapperState? // registered bundles only
    public var problems: [BundleProblem] // wrapper.md §13; empty = passes the approval checks
    public var signer: WrapperSigner?
    public var cdhash: String?
    public var launcherVersion: String?
    public var launcherAPI: APIVersion?
    public var bundledVersion: VersionCode? // portable and distribution wrappers
}
```

- `listWrappers` runs the quick checks of wrapper §9.1 and caches the result for 60 s. `packages.*` events do not invalidate the cache; `wrappers.statusChanged` reports changes found later.
- `verifyWrapper` works for any bundle, registered or not. It reports problems in the reply and fails only when `bundleURL` is not an APKRun wrapper at all (`wrapper.bundleInvalid`).
- A `moved(URL)` state appears in one reply only. The registry path is already updated.

### 10.5 Refresh and removal

```swift
public struct RefreshWrapperRequest: Codable, Sendable {
    public var packageID: PackageID
    public var change: WrapperRefresh
}

public struct WrapperRefresh: Codable, Sendable {
    public var displayName: String? // "" = back to the package's display name
    public var icon: WrapperIconChoice? // nil = keep the current choice
    public var launcherOnly: Bool // only a new launcher (wrapper.md §9.4)
    public var makeLocal: Bool // Make Local Mac App: drop bootstrap/, kind.local (wrapper.md §10.2)
    public var closeRunningApp: Bool // false: a running wrapper fails with wrapper.wrapperRunning
}

public struct RefreshAllWrappersRequest: Codable, Sendable {
    public var scope: WrapperRefreshScope //.needingRefresh (refresh reasons set),.all
    public var launcherOnly: Bool
}

public struct WrapperBatchResult: Codable, Sendable {
    public var refreshed: [PackageID]
    public var skippedRunning: [PackageID]
    public var failed: [WrapperBatchFailure] // { packageID, error: WireError }
}

public struct RemoveWrapperRequest: Codable, Sendable {
    public var packageID: PackageID
    public var options: RemoveWrapperOptions // { trash: Bool }; false = Remove from List
}
```

- `closeRunningApp = true` is the answer to "Quit ‹App› to update its Mac app?". apkrund sends `windowRequest(.close)` to the session, waits up to 30 s for it to end, and continues. If the session does not end, the operation fails with `wrapper.wrapperRunning`. The client never sends `windowRequest`: it is a server event (§6.3).
- `refreshAllWrappers` skips running wrappers and lists them in `skippedRunning` (wrapper §9.4).
- If macOS App Management blocks apkrund, the refresh fails with `wrapper.refreshBlocked(path, stagingToken:)`. apkrund has run steps 1–4 of wrapper §9.3 and left the new, signed `Contents` in `Wrappers/staging/<stagingToken>/`. APKRun.app swaps `Contents` itself (steps 5 and 6) and calls `placeStagedWrapper` with the wrapper's URL. apkrund checks the cdhash and runs steps 7 and 8, and publishes `wrappers.refreshed`. The token rules of §10.3 apply. The CLI shows the error and names APKRun.app. This fallback exists only if #076 finds the block (R-20); otherwise `stagingToken` is always nil and is removed.
- `removeWrapper` never deletes. With `trash = true` the bundle goes to the Trash (wrapper §9.5).

### 10.6 Approval

The broker call `requestApproval` is in §3.4. The control side:

```swift
public struct ApprovalPrompt: Codable, Sendable {
    public var approvalID: ApprovalID
    public var kind: ApprovalKind //.wrapper,.bootstrapInstall(ImportPreview)
    public var bundleURL: URL
    public var bundleID: String
    public var packageID: PackageID
    public var displayName: String
    public var signer: WrapperSigner
    public var packageInstalled: Bool
    public var installedVersion: String? // versionName
    public var bundledVersion: String? // portable and distribution wrappers
    public var replacesURL: URL? // an active entry for the bundle ID is replaced (wrapper.md §7.3)
    public var integrations: [IntegrationKind: WireIntegrationDecision] // wrapper.json values capped by this Mac's defaults
    public var icon: Data? // PNG, at most 256 px
    public var requestedAt: Date
    public var expiresAt: Date // requestedAt + 10 min
}

public struct DecideApprovalRequest: Codable, Sendable {
    public var approvalID: ApprovalID
    public var allow: Bool
}

public struct ApproveWrapperRequest: Codable, Sendable { public var bundleURL: URL }

public struct DeniedWrapper: Codable, Sendable {
    public var bundleID: String
    public var packageID: PackageID?
    public var cdhash: String
    public var until: Date
}

public struct ClearWrapperDenialRequest: Codable, Sendable {
    public var bundleID: String
    public var cdhash: String
}

public struct RescanWrappersRequest: Codable, Sendable { public var register: Bool }

public struct RescanResult: Codable, Sendable {
    public var candidates: [WrapperVerification] // bundles with APKRunPackageID in ~/Applications and /Applications
    public var registered: [PackageID] // empty when register == false
}
```

- apkrund publishes `wrappers.approvalRequested` and opens APKRun.app when no A client is connected (wrapper §7.3 step 4). The first `decideApproval` wins. A later one, or one for an expired prompt, returns `wrapper.approvalNotFound`.
- `approveWrapper` runs steps 1–3 and 5 of wrapper §7.3 without a prompt. The CLI asks first (`apkrun wrapper approve`).
- `rescanWrappers` with `register = true` registers only bundles whose static checks pass, with `approval: generated` semantics (wrapper §7.2).

### 10.7 Portable bootstrap

```swift
public struct ImportBootstrapRequest: Codable, Sendable {
    public var bootstrapJSON: Data // Contents/Resources/bootstrap/bootstrap.json, at most 64 KiB
    public var files: [ImportSourceFile] // 1…20, in bootstrap.json order
}
```

Server steps ([../02-design/wrapper.md](../02-design/wrapper.md) §10.2):

1. The wrapper must be approved, `bootstrapJSON.packageId` must equal the registry's package, and the package must not be installed (or be `uninstalledKeepingData`). Otherwise `wrapper.bootstrapNotAllowed(.notApproved |.alreadyInstalled)`.
2. The store copies the files and checks each SHA-256 and the set digest against `bootstrapJSON`, then runs all intrinsic checks and the preview. The source is `wrapperBootstrap`. A mismatch is `wrapper.bootstrapInvalid(.hashMismatch |.packageMismatch |.malformed)`.
3. Preview warnings (for example a low `targetSdk`) need a confirmation. apkrund publishes `wrappers.approvalRequested` with `kind =.bootstrapInstall(ImportPreview)`, and APKRun.app shows the install sheet. **Don't Install** ends the operation with `cancelled`. No answer in 10 min is `wrapper.approvalTimedOut`.
4. apkrund reads `wrapper.json` from the registered bundle, not from the request. Its `updates` values become the initial authority, choice, and provider. Its `window` and `integration` values become the package settings.
5. The result is `.package(PackageSummary)`. The launcher then repeats `openSession`.

### 10.8 Distribution (M12)

```swift
public struct DistributionWrapperRequest: Codable, Sendable {
    public var packageID: PackageID
    public var outputDirectory: URL // the CLI passes --output, or the current directory
    public var fileName: String?
    public var displayName: String?
    public var icon: WrapperIconChoice?
    public var identity: String // "Developer ID Application: Name (TEAMID)", in the user's keychain
    public var notarize: Bool
    public var keychainProfile: String? // notarytool store-credentials profile; required with notarize
    public var redistributionConfirmed: Bool // the legal confirmation of wrapper.md §11; false = runtime.malformedRequest
}

public struct DistributionWrapperResult: Codable, Sendable {
    public var appURL: URL // <dir>/<name>.app
    public var zipURL: URL // <dir>/<name>.zip
    public var bundleID: String
    public var cdhash: String
    public var teamID: String
    public var notarized: Bool
    public var submissionID: String?
    public var assessment: String? // spctl output, with notarize only
}
```

- The bundle is not placed and not registered. `outputDirectory` follows the access rule of §10.3: when apkrund may not write there, the error is `wrapper.destinationNotAccessible` and the client places both files. `placeStagedWrapper` is not used for distribution wrappers.
- apkrund never stores Apple ID passwords. The notary credentials stay in the keychain profile.

### 10.9 Events

Topic `wrappers` ([../02-design/wrapper.md](../02-design/wrapper.md) §12.1):

```swift
public enum WrapperChange: Codable, Sendable {
    case created(WrapperSummary)
    case refreshed(WrapperSummary)
    case removed(PackageID)
    case statusChanged(PackageID, WrapperStatus)
    case approvalRequested(ApprovalPrompt) // APKRun.app shows the dialog
    case approvalResolved(ApprovalID)
    case unknown
}
```

`statusChanged` is coalesced per package (§16.2).

### 10.10 Errors

| Operation | Errors |
|---|---|
| `createWrapper` | `wrapper.packageNotInstalled`, `wrapper.invalidName`, `wrapper.customIconInvalid`, `wrapper.iconConversionFailed`, `wrapper.launcherTemplateInvalid`, `wrapper.destinationNotWritable`, `wrapper.destinationNotAccessible`, `wrapper.nameConflict`, `wrapper.wrapperExists`, `wrapper.signingFailed`, `wrapper.verificationFailed`, `wrapper.registryUnavailable`, `store.importExpired` (with `importTicket`). `wrapper.registrationFailed` is a warning only |
| `placeStagedWrapper` | `wrapper.stagingExpired`, `wrapper.verificationFailed`, `wrapper.nameConflict`, `wrapper.registryUnavailable` |
| `refreshWrapper` | as `createWrapper`, plus `wrapper.wrapperNotFound`, `wrapper.wrapperRunning`, `wrapper.refreshBlocked` |
| `refreshAllWrappers` | per wrapper in `WrapperBatchResult.failed`; the operation itself fails only with `wrapper.registryUnavailable` or `wrapper.launcherTemplateInvalid` |
| `wrapperInfo`, `removeWrapper` | `wrapper.wrapperNotFound`, `wrapper.registryUnavailable` |
| `verifyWrapper` | `wrapper.bundleInvalid` (not an APKRun wrapper) |
| `approveWrapper` | `wrapper.bundleInvalid`, `wrapper.approvalDenied` (an unexpired denial for that cdhash), `wrapper.registryUnavailable` |
| `decideApproval` | `wrapper.approvalNotFound` |
| `clearWrapperDenial` | `wrapper.wrapperNotFound` |
| `importBootstrap` | `wrapper.bootstrapNotAllowed`, `wrapper.bootstrapInvalid`, `wrapper.approvalTimedOut`, the install errors of §8.5 (`store.downgradeRefused` when kept data is newer) |
| `buildDistributionWrapper` | as `createWrapper`, plus `wrapper.distributionToolMissing`, `wrapper.identityNotFound`, `wrapper.notarizationFailed` |

---

## 11. Integrations

Integration semantics: [../02-design/desktop-integration.md](../02-design/desktop-integration.md). Per-package integration settings are package settings and change through `updatePackageSettings` (§14). This section has the status and shared-folder operations, the session DTOs of the integration messages of §6.3, and the notification streams.

### 11.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `integrationStatus` | `PackageRequest` → `IntegrationStatus` | C | Q | `integrations.statusChanged` | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2.3, §11 |
| `sharedFolders` | `Empty` → `[SharedFolder]` | C | Q | — | desktop-integration §6.4 |
| `addSharedFolder` | `AddSharedFolderRequest` → `SharedFolder` | C | U | `integrations.sharedFoldersChanged`, `runtime.configurationChanged(["sharedFolders.roots"])` | desktop-integration §6.4 |
| `removeSharedFolder` | `SharedFolderRequest` → `Empty` | C | U | as `addSharedFolder` | desktop-integration §6.4 |
| `setSharedFolderAccess` | `SetSharedFolderAccessRequest` → `SharedFolder` | C | U | as `addSharedFolder` | desktop-integration §6.4 |
| `activeRecordings` | `Empty` → `ActiveRecordings` | C | Q | `integrations.recordingChanged` | desktop-integration §8.2 |
| `notificationRelay` | `NotificationRelayRequest` → `StreamHandle` | W | S | stream of `RelayMessage` | desktop-integration §5.3 |
| `notificationRelayResponse` | `RelayResponse` | W | 1 | — | desktop-integration §5.3, §5.4, §11 |
| `hostNotifications` | `HostNotificationsRequest` → `StreamHandle` | A | S | stream of `HostNotificationMessage` | [../02-design/update-system.md](../02-design/update-system.md) §9, [../02-design/host-ui.md](../02-design/host-ui.md) §11, desktop-integration §11 |
| `hostNotificationResponse` | `HostNotificationResponse` | A | 1 | — | host-ui §11, desktop-integration §11 |

```swift
public struct IntegrationStatus: Codable, Sendable {
    public var packageID: PackageID
    public var items: [IntegrationItemStatus] // one per IntegrationKind
    public var microphoneNeedsRestart: Bool // the microphone input is attached at VM start only (desktop-integration.md §8.2)
}

public struct IntegrationItemStatus: Codable, Sendable {
    public var kind: IntegrationKind // clipboard, notifications, links, files, sharedFolders, microphone
    public var value: JSONValue // the package setting in effect: true, "ask", "readOnly", …
    public var source: SettingSource // §14.2
    public var decision: WireIntegrationDecision // without the session context (focus, rate)
    public var support: IntegrationSupport
    public var macPermission: MacPermissionState? // notifications: the wrapper's; microphone: APKRun's
}

public enum WireIntegrationDecision: Codable, Sendable, Equatable {
    case allow
    case ask // links only
    case deny(IntegrationDenial) //.globallyOff,.packageOff,.notFocused,.noSession,.notSupported(capability),.rateLimited
    case unknown
}

public enum IntegrationSupport: Codable, Sendable, Equatable {
    case supported
    case unsupported(capability: String) // the running image lacks the capability (desktop-integration.md §2.4)
    case unknown // Android has not run with this image yet
}

public enum MacPermissionState: String, Codable, Sendable {
    case notDetermined, denied, restricted, authorized, provisional, ephemeral, unknown
}

public struct SharedFolder: Codable, Sendable {
    public var id: SharedFolderID // "shared" for the built-in folder
    public var name: String // the root's name in the Android file picker
    public var path: String // for display only; apkrund uses the bookmark
    public var access: SharedFolderAccess //.readOnly,.readWrite: the root's maximum
    public var builtIn: Bool // the APKRun Shared folder; cannot be removed
    public var availability: FolderAvailability //.available,.missing,.privacyDenied,.offline,.unknown
}

public struct AddSharedFolderRequest: Codable, Sendable {
    public var bookmark: Data // from the open panel, or created by the CLI for <path>
    public var access: SharedFolderAccess // default.readOnly; --read-write sets.readWrite
}

public struct SharedFolderRequest: Codable, Sendable { public var id: SharedFolderID }

public struct SetSharedFolderAccessRequest: Codable, Sendable {
    public var id: SharedFolderID
    public var access: SharedFolderAccess
}

public struct ActiveRecordings: Codable, Sendable { public var packages: [PackageID] }
```

- `updateConfiguration` refuses a patch that contains `sharedFolders.roots` (§14). The shared-folder operations are the only way to change the root list, because each root needs a bookmark and the checks of desktop-integration §6.4.
- `apkrun shared-folders remove <path|id>` resolves a path to an ID on the client with `sharedFolders`, then calls `removeSharedFolder`.
- `removeSharedFolder` for `shared` returns `runtime.malformedRequest`.

### 11.2 Session DTOs

The integration messages of the session channel (§6.3) use these types ([../02-design/desktop-integration.md](../02-design/desktop-integration.md) §3.3).

```swift
public struct ClipItem: Codable, Sendable {
    public var text: String? // UTF-8, at most 1 MiB
    public var html: String? // at most 1 MiB, always together with text
    public var image: ClipImage? // #080
    public var sensitive: Bool // org.nspasteboard.ConcealedType / EXTRA_IS_SENSITIVE
    public var digest: SHA256Digest // over the normalized text or image bytes (loop prevention)
    public var truncated: Bool // the text was cut at 1 MiB
    public var trigger: ClipTrigger? // client → server:.paste,.focus; nil from the guest
}

public struct ClipImage: Codable, Sendable {
    public var png: Data // at most 16 MiB encoded
    public var pixelSize: PixelSize // at most 8192 px per side
}

public struct ClipAck: Codable, Sendable { public var seq: UInt64 } // the guest's ClipData.seq

public struct ClipboardWritten: Codable, Sendable {
    public var changeCount: Int // NSPasteboard.changeCount after the write
    public var digest: SHA256Digest
}

public struct ImportFilesRequest: Codable, Sendable {
    public var files: [ImportFileInfo] // 1…20, in the order of the files: array
    public var target: ImportTarget //.shareToApp
}

public struct ImportFileInfo: Codable, Sendable {
    public var fileIndex: Int
    public var name: String
    public var size: Int64
    public var uti: String
}

public struct ImportResult: Codable, Sendable {
    public var contentURIs: [String]
    public var disposition: ImportDisposition //.shared,.savedToDownloads
}

public struct ExportOffer: Codable, Sendable {
    public var offerID: OfferID
    public var name: String // sanitized as in wrapper.md §4.3
    public var size: Int64?
    public var type: String // MIME type from Android
}

public struct AcceptExportRequest: Codable, Sendable {
    public var offerID: OfferID
    public var fileIndex: Int? // a write handle (§4.9); nil = the user cancelled
}

public struct LinkPrompt: Codable, Sendable {
    public var promptID: PromptID
    public var host: String // Unicode host, or the mail address for mailto
    public var registrableDomain: String? // shown in bold
    public var scheme: String // http, https, mailto
    public var signInHint: Bool // the path contains oauth, authorize, or login
    public var keepInAndroidAvailable: Bool // false when the image has no in-Android browser
    public var expiresAt: Date // 60 s after the prompt; then Cancel
}

public struct ResolveLinkPromptRequest: Codable, Sendable {
    public var promptID: PromptID
    public var choice: LinkChoice //.openOnMac,.keepInAndroid,.cancel
    public var remember: Bool // writes integrations.links = mac | android
}
```

- The link prompt never carries the path or query of the URL. They can contain tokens (desktop-integration §7.2).
- `acceptExport` with `fileIndex` set writes the bytes to the handle and replies when the SHA-256 matches. On failure the reply is an error and the window deletes the partial file.
- `resolveLinkPrompt` for an expired prompt returns `integration.promptTimedOut`.

### 11.3 Notification streams

**Relay (wrappers).** One relay per wrapper connection, opened by a window process or a wrapper in background mode (`--apkrun-background notifications`, [../02-design/wrapper.md](../02-design/wrapper.md) §5.8).

```swift
public struct NotificationRelayRequest: Codable, Sendable {
    public var background: Bool // started in background mode; for logs and the queue timeout
}

public enum RelayMessage: Codable, Sendable { // server → wrapper, in StreamEnvelope.event
    case post(NotificationPayload)
    case remove([String]) // identifiers
    case setBadge(Int?) // nil clears the Dock badge
    case unknown
}

public struct NotificationPayload: Codable, Sendable {
    public var identifier: String // "<package>|<first 16 hex of SHA-256(key)>"
    public var threadID: String // "<package>/<group or channel>"
    public var title: String
    public var body: String
    public var sound: Bool
    public var interruption: NotificationInterruption //.passive,.active
    public var actions: [String] // titles, at most 3 (a0–a2)
    public var badge: Int?
    public var replay: Bool // re-sent after a reconnect: update without a banner
}

public enum RelayResponse: Codable, Sendable { // wrapper → server, one-way
    case activated(identifier: String, actionIndex: Int?) // after the session is running
    case dismissed(identifier: String)
    case authorizationChanged(MacPermissionState) // the wire form of UNAuthorizationStatus
    case unknown
}
```

- A second `notificationRelay` on the same connection returns the existing `StreamHandle`.
- While no relay is connected for a registered wrapper, apkrund starts the wrapper in background mode and queues up to 50 payloads per package for 10 s. On timeout the queue is dropped and counted (desktop-integration §5.3).

**Host notifications (APKRun.app).** apkrund has no user-interface identity. It sends the notifications of [../02-design/update-system.md](../02-design/update-system.md) §9, of Android apps without a usable wrapper, and of runtime maintenance to APKRun.app, which posts them ([../02-design/host-ui.md](../02-design/host-ui.md) §11).

```swift
public struct HostNotificationsRequest: Codable, Sendable {
    public var background: Bool // APKRun.app was opened with --notify
}

public enum HostNotificationMessage: Codable, Sendable { // server → APKRun.app
    case post(HostNotificationPayload)
    case remove([String])
    case unknown
}

public struct HostNotificationPayload: Codable, Sendable {
    public var identifier: String
    public var kind: HostNotificationKind
    public var packageID: PackageID?
    public var title: WireLocalizedText
    public var subtitle: String? // the app's display name for Android app notifications
    public var body: WireLocalizedText
    public var threadID: String?
    public var sound: Bool
    public var interruption: NotificationInterruption
    public var actions: [HostNotificationAction]
    public var targetURL: URL? // apkrun:// URL opened by a click on the notification itself
}

public enum HostNotificationKind: String, Codable, Sendable {
    case androidApp, updateAvailable, updated, updateWaiting, updateRolledBack, updateRefused, providerProblem,
    runtimeStopped, approvalNeeded, selfUpdateAvailable, imageUpdateReady, imageUpdated,
    imageUpdateFailed, imageIncompatible, unknown
}

public enum HostNotificationAction: Codable, Sendable, Equatable {
    case updateNow, open, restart, update, later, reportProblem, openAPKRun
    case android(index: Int, title: String) // the Android actions of an androidApp notification
    case unknown
}

public enum HostNotificationResponse: Codable, Sendable { // APKRun.app → server, one-way
    case activated(identifier: String, action: HostNotificationAction?) // nil = the notification itself
    case dismissed(identifier: String)
    case unknown
}
```

- Only one host-notification stream is served at a time. A new one replaces the old one, and the old stream ends.
- With no stream, apkrund opens APKRun.app in the background with `--notify` and queues up to 50 notifications for 30 s ([../02-design/update-system.md](../02-design/update-system.md) §9).
- APKRun.app handles **Update Now** and **Update…** itself, then calls the matching operation (`updatePackage`, `applyImageUpdate`, or a Sparkle check). An `androidApp` activation makes apkrund call `launch(packageID)` and then `ActivateNotification` (desktop-integration §5.4).

### 11.4 Limits

| Item | Limit | Over the limit |
|---|---|---|
| Clipboard text | 1 MiB UTF-8 | truncated at a character boundary, `truncated = true` |
| Clipboard HTML | 1 MiB | `integration.clipboardTooLarge` |
| Clipboard image | 16 MiB encoded, 8192 px per side | `integration.clipboardTooLarge` |
| Drop into an app (`importFiles`) | 20 files, each at most 2 GiB, 4 GiB in total | `integration.tooManyFiles`, `integration.fileTooLarge` |
| Save to Mac | 20 items per share, one panel per item | the rest is declined |
| Links | 8 KiB per URL, 3 per 10 s per package | dropped and counted |
| Link prompt | 60 s | `.cancel` |
| Notification actions | 3 | extra actions are not shown |
| Notification queue for a starting wrapper | 50 per package, 10 s | dropped and counted |
| Host notification queue | 50, 30 s | dropped and counted |
| Shared folders | 32 added roots | `integration.folderRefused(.limitReached)` |
| Shared-folder I/O | 4096 entries per listing page, 1 MiB per read or write, 64 open handles per package | guest-side errors |

### 11.5 Errors

| Operation | Errors |
|---|---|
| `integrationStatus` | `store.packageNotFound` |
| `addSharedFolder` | `integration.folderRefused`, `integration.folderUnavailable` |
| `removeSharedFolder`, `setSharedFolderAccess` | `integration.folderUnavailable` (unknown ID) |
| `pushClipboard` | `integration.disabled`, `integration.clipboardTooLarge`, `integration.guestUnavailable`, `integration.notSupportedOnImage` |
| `importFiles` | `integration.disabled`, `integration.tooManyFiles`, `integration.fileTooLarge`, `integration.transferFailed`, `integration.guestUnavailable` |
| `acceptExport` | `integration.transferFailed` |
| `resolveLinkPrompt` | `integration.promptTimedOut` |
| `notificationRelay`, `hostNotifications` | none beyond §4.5. With notifications turned off for the package, the relay opens and delivers only `remove` and `setBadge(nil)` |

The health findings `integration.notificationAccessMissing`, `integration.browserRoleMissing`, and `integration.timeSyncFailed` appear in `healthReport` only (§13).

---

## 12. Maintenance

Maintenance semantics: [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md). It covers APKRun's own updates (Sparkle, coordinated with apkrund) and Android system image updates. Package updates are §9. The maintenance endpoint serves the host-update coordination. The self-update and image operations are on the control endpoint. Wrappers get only `hostState` (in `HelloReply` and `RuntimeSummary`) and `runtime.hostUpdating` (runtime-maintenance §8.2).

### 12.1 Maintenance endpoint (frozen)

`MaintenanceControl` has no major version. Every change is additive: new optional fields, new operations, new enum cases (the client decodes unknown cases as `unknown`). It must work between an old apkrund and a new APKRun.app, even when the RuntimeAPI major differs (runtime-maintenance §8.1). Its requests carry the same `APIRequestHeader`. The server ignores the header's version.

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `maintenanceStatus` | `Empty` → `MaintenanceStatus` | M | Q | — | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.1 |
| `prepareForHostUpdate` | `HostUpdateRequest` → `Empty` | M | W (3 min) | `maintenance.hostStateChanged(.updating)`, `sessions.ended(.runtimeUpdating)` | runtime-maintenance §3.5 |
| `abortHostUpdate` | `Empty` → `Empty` | M | U | `maintenance.hostStateChanged(.normal)` | runtime-maintenance §3.5, §8.1 |
| `completeHostUpdate` | `Empty` → `Empty` | M | U | `maintenance.hostStateChanged(.normal)` | runtime-maintenance §3.6 |
| `restartForUpdate` | `RestartForUpdateRequest` → `Empty` | M | W (60 s) | `sessions.ended(.runtimeUpdating)`, `runtime.stateChanged` | runtime-maintenance §3.6, §8.1 |

```swift
public struct MaintenanceStatus: Codable, Sendable {
    public var version: String // apkrund's CFBundleShortVersionString
    public var build: Int // apkrund's CFBundleVersion
    public var hostState: HostState
    public var sessions: [PackageID] // packages with a session that is not ended
    public var backgroundTasks: [PackageID]
    public var activities: [ActivityKind] // §17.2
    public var imageMigrating: Bool
    public var marker: HostUpdateMarker? // Runtime/maintenance.json while updating
}

public struct HostUpdateMarker: Codable, Sendable {
    public var fromVersion: String
    public var fromBuild: Int
    public var targetVersion: String
    public var targetBuild: Int
    public var createdAt: Date
    public var operationID: OperationID
}

public struct HostUpdateRequest: Codable, Sendable {
    public var targetVersion: String
    public var targetBuild: Int
    public var closeSessions: Bool // false with open sessions: maintenance.hostUpdateSessionsOpen
}

public struct RestartForUpdateRequest: Codable, Sendable {
    public var closeSessions: Bool
}
```

- `prepareForHostUpdate` replies after Android has stopped and the marker is written (runtime-maintenance §3.5 step 4). apkrund exits 1 s later. The client treats the following invalidation as expected and does not reconnect until Sparkle has relaunched the app.
- `restartForUpdate` acts only in `restartPending`. In another host state it does nothing and returns, and the CLI prints "Nothing to finish." In `restartPending` it replies before apkrund exits. `apkrun self-update finish` calls it and then waits for launchd to start the new apkrund (§3.6).
- `abortHostUpdate` and `completeHostUpdate` are idempotent. They succeed in `normal` without work.

### 12.2 Self-update (control)

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `selfUpdateStatus` | `Empty` → `SelfUpdateStatus` | C | Q | `maintenance.selfUpdateStatusChanged` | runtime-maintenance §3.4 |
| `checkSelfUpdate` | `CheckSelfUpdateRequest { userInitiated }` → `SelfUpdateStatus` | C | U (30 s) | `maintenance.selfUpdateStatusChanged` | runtime-maintenance §3.4 |
| `noteSelfUpdateStatus` | `SelfUpdateNote` → `Empty` | A | U | `maintenance.selfUpdateStatusChanged` | runtime-maintenance §3.3, §8.2 |

```swift
public struct SelfUpdateStatus: Codable, Sendable {
    public var currentVersion: String
    public var currentBuild: Int
    public var latest: AvailableRelease? // nil = up to date, or never checked
    public var critical: Bool
    public var lastCheckedAt: Date?
    public var lastError: WireError? // maintenance.selfUpdateFeedUnreachable,.selfUpdateFeedInvalid
    public var pendingOnQuit: Bool // Sparkle has downloaded an update that installs on quit
}

public struct AvailableRelease: Codable, Sendable {
    public var version: String // sparkle:shortVersionString
    public var build: Int // sparkle:version
    public var channel: String? // nil = stable
    public var minimumSystemVersion: String?
    public var releaseNotesURL: URL?
    public var publishedAt: Date?
}

public struct SelfUpdateNote: Codable, Sendable { // Sparkle's results, reported by APKRun.app
    public var found: AvailableRelease?
    public var pendingOnQuit: Bool
    public var checkedAt: Date
}
```

- The probe in apkrund is informational only. It never downloads or installs (runtime-maintenance §3.4). `apkrun self-update install` calls no operation. It opens `apkrun://settings/general`.
- `checkSelfUpdate` with `userInitiated = false` follows the 24-hour interval and returns the cached status when the interval has not passed.

### 12.3 Android system updates (control)

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `imageUpdateStatus` | `Empty` → `ImageUpdateStatus` | C | Q | `maintenance.imageUpdatePhaseChanged` | runtime-maintenance §4.3, §8.2 |
| `checkImageUpdate` | `Empty` → `OperationHandle` (`imageCheck`) → `.imageUpdate(ImageUpdateStatus)` | C | L | `maintenance.imageUpdatePhaseChanged` | runtime-maintenance §4.2 |
| `downloadImageUpdate` | `Empty` → `OperationHandle` (`imageDownload`) → `.imageUpdate(ImageUpdateStatus)` | C | L | `maintenance.imageUpdateProgress`, `.imageUpdatePhaseChanged` | runtime-maintenance §4.4 |
| `cancelImageDownload` | `Empty` → `Empty` | C | U | `maintenance.imageUpdatePhaseChanged` | runtime-maintenance §4.4 |
| `applyImageUpdate` | `ApplyImageUpdateRequest` → `OperationHandle` (`imageApply`) → `.imageUpdate(ImageUpdateStatus)` | C | L | `maintenance.*`, `runtime.stateChanged`, `sessions.ended(.runtimeUpdating)` | runtime-maintenance §4.6, §4.7 |
| `installImage` | `ImageInstallRequest` (+ 0 or 1 file) → `OperationHandle` (`imageInstall`) → `.image(WireImageInfo)` | C | L | as `downloadImageUpdate`; with `apply`, as `applyImageUpdate` | runtime-maintenance §4.5 |
| `rollbackImage` | `RollbackImageRequest` → `OperationHandle` (`imageRollback`) → `.image(WireImageInfo)` | C | L | `maintenance.imageUpdateFinished(.rolledBack)`, `runtime.*`, `packages.stateChanged` | runtime-maintenance §4.8 |
| `listImages` | `Empty` → `[WireImageInfo]` | C | Q | — | [../02-design/android-image.md](../02-design/android-image.md) §12.2 |
| `recoveryPoints` | `Empty` → `[WireRecoveryPoint]` | C | Q | — | android-image §12.2 |
| `deleteRecoveryPoint` | `RecoveryPointRequest { id }` → `Empty` | C | U | — | android-image §12.2 |

```swift
public struct ImageUpdateStatus: Codable, Sendable {
    public var phase: WireImageUpdatePhase
    public var current: ImageVersion?
    public var requiresNewerAPKRun: String? // the minimum APKRun version of a newer image this build cannot use
    public var rejected: [RejectedImage] // { version, at, reason: WireError }
    public var lastResult: ImageUpdateOutcome?
    public var waitingFor: [ImageApplyCondition] // the gate conditions (a1…a7) that are false now
    public var installMode: ImageInstallMode //.automatic,.ask (maintenance.installImages)
    public var lastCheckAt: Date?
    public var nextCheckAt: Date?
}

public enum WireImageUpdatePhase: Codable, Sendable, Equatable { // runtime-maintenance.md §4.3
    case idle
    case checking
    case available(WireImageCandidate)
    case downloading(WireImageCandidate, DownloadProgress) // { bytes, totalBytes, resumed }
    case installing(WireImageCandidate, fraction: Double)
    case ready(ImageVersion)
    case applying(from: ImageVersion, to: ImageVersion)
    case failed(WireImageCandidate?, WireError, retryAt: Date?)
    case unknown
}

public struct WireImageCandidate: Codable, Sendable, Equatable { // one entry of the image feed
    public var version: ImageVersion
    public var kind: ImageKind //.apkrun,.stock
    public var publishedAt: Date
    public var downloadBytes: Int64 // archive.size
    public var expandedBytes: Int64 // expandedSize
    public var securityPatchLevel: String // "2026-09-05"
    public var critical: Bool
    public var releaseNotesURL: URL?
}

public enum ImageApplyCondition: String, Codable, Sendable {
    case a1Ready, a2NoActivity, a3HostNormal, a4UserIdle, a5Power, a6FreeSpace, a7NotRecentlyAttempted, unknown
}

public enum ImageUpdateOutcome: Codable, Sendable, Equatable {
    case installed(ImageVersion)
    case rejected(ImageVersion, WireError)
    case rolledBack(to: ImageVersion)
    case unknown
}

public struct ApplyImageUpdateRequest: Codable, Sendable {
    public var version: ImageVersion // must be the ready image
    public var closeSessions: Bool
    public var retryRejected: Bool // false for a rejected version: maintenance.imageUpdateRejected
}

public struct ImageInstallRequest: Codable, Sendable {
    public var source: ImageInstallSource //.file(fileIndex: Int) (a signed.aar),.latest (the feed candidate)
    public var apply: Bool // apply after the install (the CLI always sets true)
    public var closeSessions: Bool // used by the apply step
    public var retryRejected: Bool
}

public struct RollbackImageRequest: Codable, Sendable {
    public var confirmed: Bool // the data-loss confirmation of runtime-maintenance.md §4.8; false = runtime.malformedRequest
}

public struct WireImageInfo: Codable, Sendable {
    public var version: ImageVersion
    public var role: ImageRole //.current,.previous,.ready,.rejected,.other
    public var kind: ImageKind
    public var sizeBytes: Int64
    public var installedAt: Date?
    public var securityPatchLevel: String?
}

public struct WireRecoveryPoint: Codable, Sendable {
    public var id: RecoveryPointID
    public var imageVersion: ImageVersion
    public var createdAt: Date
    public var reason: RecoveryPointReason //.migration,.resetAndroid,.unknown
    public var sizeBytes: Int64? // blocks not shared with the instance, when known
    public var failed: Bool // recovery-points/failed-<ts>/ kept for diagnostics
}

public struct RecoveryPointRequest: Codable, Sendable { public var id: RecoveryPointID }
```

- `applyImageUpdate` requires the gate conditions A1, A3, and A6 (runtime-maintenance §4.6). If sessions or background tasks exist and `closeSessions` is false, it returns `runtime.busy` with the parameter `activities`, and the client asks "Update Android now?" and repeats with `true`.
- `installImage` with `.latest` runs only the missing steps: check, download, install, apply. With `.file`, release builds accept only images signed with the release keys. Unpacked directories are `DeveloperService` only (§15).
- `cancelImageDownload` keeps the partial file. It is the same as `cancel` on the `imageDownload` operation.
- `rollbackImage` restores the recovery point of the last migration while the `previous` image exists. Without one it returns `maintenance.rollbackUnavailable`.
- `deleteRecoveryPoint` for an unknown ID returns `image.recoveryPointMissing`. Deleting the recovery point of the last migration removes the way back, so the client asks first.
- A recovery point made by Reset Android (`reason =.resetAndroid`) has no restore operation in v1. `recoveryPoints` lists it and `deleteRecoveryPoint` deletes it (runtime-daemon §9.5, [../04-plan/open-questions.md](../04-plan/open-questions.md) OQ-41).

### 12.4 Events

Topic `maintenance` (runtime-maintenance §8.3):

```swift
public enum MaintenanceEvent: Codable, Sendable {
    case hostStateChanged(HostState)
    case selfUpdateStatusChanged(SelfUpdateStatus)
    case imageUpdatePhaseChanged(WireImageUpdatePhase)
    case imageUpdateProgress(OperationID, fraction: Double, bytes: Int64?) // coalesced to 10 per second
    case imageUpdateFinished(ImageUpdateOutcome)
    case unknown
}
```

### 12.5 Errors

| Operation | Errors |
|---|---|
| `prepareForHostUpdate` | `maintenance.hostUpdateBusy`, `maintenance.hostUpdateSessionsOpen`, `maintenance.selfUpdateNotNewer`, `maintenance.hostUpdateStopFailed` |
| `restartForUpdate` | `maintenance.hostUpdateSessionsOpen`, `maintenance.hostUpdateStopFailed` |
| `checkSelfUpdate` | `maintenance.selfUpdateFeedUnreachable`, `maintenance.selfUpdateFeedInvalid` (also kept in `lastError`) |
| `checkImageUpdate` | `maintenance.imageFeedUnreachable`, `maintenance.imageFeedHTTPStatus`, `maintenance.imageFeedSignatureInvalid`, `maintenance.imageFeedInvalid`, `maintenance.imageFeedReplayed`, `maintenance.imageFeedExpired`, `maintenance.noCompatibleImage` |
| `downloadImageUpdate` | `maintenance.imageUpdateNotReady` (no candidate), `maintenance.imageDownloadFailed`, `maintenance.imageArchiveSizeMismatch`, `maintenance.imageArchiveHashMismatch`, `maintenance.insufficientSpace`, `maintenance.cancelled` |
| `applyImageUpdate` | `maintenance.imageUpdateNotReady`, `maintenance.imageUpdateRejected`, `maintenance.insufficientSpace`, `maintenance.imageMigrationFailed`, `runtime.busy` |
| `installImage` | the check, download, and apply errors above, plus `maintenance.imageArchiveUnsafeEntry`, `maintenance.imageInstallFailed` (wraps the `image.*` verification errors) |
| `rollbackImage` | `maintenance.rollbackUnavailable`, `image.recoveryPointMissing`, `image.recoveryPointStale` |
| `deleteRecoveryPoint` | `image.recoveryPointMissing` |
| all image operations | `maintenance.dataCreatedByNewerVersion` (a state file of a newer APKRun) |

---

## 13. Diagnostics and health

Diagnostics semantics: [../02-design/diagnostics.md](../02-design/diagnostics.md). All operations are control only. A wrapper's **Report a Problem…** opens `apkrun://report?package=<id>` in APKRun.app (diagnostics §8.5, [../02-design/wrapper.md](../02-design/wrapper.md) §5.6). These operations are served in every host state (§3.7) and in the runtime state `failed`.

### 13.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `healthReport` | `HealthRequest` → `WireHealthReport` | C | W (15 s quick, 3 min deep) | — | [../02-design/diagnostics.md](../02-design/diagnostics.md) §7.1, §7.6 |
| `applyHealthFixes` | `HealthFixRequest` → `WireHealthReport` | C | W (3 min) | `health.healthChanged` | diagnostics §7.5, §7.6 |
| `createDiagnostics` | `DiagnosticsRequest` + 1 write handle → `OperationHandle` (`diagnostics`) → `.diagnostics(DiagnosticsResult)` | C | L | `operations.*` (stages `collecting`, `redacting`, `writing`) | diagnostics §8.1 |
| `perfStatistics` | `PerfStatisticsRequest { reset }` → `WirePerfStatistics` | C | Q | — | diagnostics §9.3 |
| `guestLog` | `GuestLogRequest` → `StreamHandle` | C | S | stream of `GuestLogChunk` | diagnostics §3.5, §7.6, [../02-design/cli.md](../02-design/cli.md) §4.8, [../02-design/android-image.md](../02-design/android-image.md) §7.1 |

```swift
public struct HealthRequest: Codable, Sendable {
    public var deep: Bool
    public var checks: [HealthCheckID]? // nil = all; Run Again on one row sends one ID
}

public struct HealthFixRequest: Codable, Sendable {
    public var checks: [HealthCheckID] // empty = every check in warning or failure that has a fix (doctor --fix)
}

public struct WireHealthReport: Codable, Sendable {
    public var generatedAt: Date
    public var build: WireBuildInfo // { version, build, commit?, channel }
    public var imageVersion: ImageVersion?
    public var runtimeRunning: Bool
    public var verdict: HealthVerdict // diagnostics.md §7.2
    public var results: [WireHealthResult] // ordered by group, then registration order
}

public enum HealthVerdict: String, Codable, Sendable {
    case hostUnsupported, serviceUnavailable, notSetUp, graphicsFailure, bootFailure,
    agentUnavailable, degraded, stopped, healthy, unknown
}

public struct WireHealthResult: Codable, Sendable {
    public var id: HealthCheckID
    public var group: HealthGroup // host, backgroundService, virtualization, android, graphics, guest,
    // store, updates, applications, macApps, integrations, maintenance
    public var state: HealthState // pass, info, warning, failure, skipped
    public var title: WireLocalizedText
    public var detail: String? // public-safe text
    public var error: WireError? // warning and failure with a next step
    public var fixAvailable: Bool
    public var lastKnown: LastKnownResult? // skipped checks: { state, detail?, measuredAt }
    public var measuredAt: Date
}

public struct DiagnosticsRequest: Codable, Sendable {
    public var outputFileIndex: Int // an empty regular file opened for writing (§4.9)
    public var includeLogcat: Bool // keep all Android app log lines (still redacted)
    public var deep: Bool // deep health checks in the bundle
    public var focusPackage: PackageID? // adds the package's update history and launch records
}

public struct DiagnosticsResult: Codable, Sendable {
    public var summary: String // summary.txt
    public var sizeBytes: Int64
    public var omitted: [OmittedItem] // { item, reason }: contributors that failed or ran out of time
}

public struct GuestLogRequest: Codable, Sendable {
    public var follow: Bool // false: the buffered lines, then the stream ends
}

public struct GuestLogChunk: Codable, Sendable {
    public var lines: [String] // logcat lines as read from the logcat console port
    public var dropped: Int // lines dropped because the client was slow
}
```

- `healthReport` never starts Android. Checks that need a running runtime return `skipped` with `lastKnown` (diagnostics §7.1).
- `createDiagnostics` always produces a result when the writer works, also in `failed` and without an image (FR-OPS-02). A cancel truncates the handle to 0 bytes. apkrund does not know the path, so the client deletes the file (§4.7).
- The CLI and APKRun.app build a host-only report and bundle when apkrund cannot be reached ([../02-design/cli.md](../02-design/cli.md) §4.8). That path uses no operation.
- `guestLog` needs `developer.enabled`. Otherwise it returns `runtime.developerModeRequired`, which the CLI shows as `cli.developerModeRequired`. It never starts Android. While Android is not `ready`, the stream delivers nothing until Android is ready; with `follow = false` it ends at once. There is no host-log operation: `apkrun logs --follow` runs `log stream` in the CLI ([../02-design/cli.md](../02-design/cli.md) §4.8, [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §10).

`WirePerfStatistics` (diagnostics §9.3):

```swift
public struct WirePerfStatistics: Codable, Sendable {
    public var since: Date // the last reset, or apkrund start
    public var markers: [MarkerStatistics] // { name, count, p50Us, p95Us, maxUs }
    public var input: [LatencyHistogram] // { segment ("input.translate", "input.route"), boundsUs: [Int64], counts: [Int] }
    public var sessions: [SessionGraphicsStatistics]
}

public struct SessionGraphicsStatistics: Codable, Sendable {
    public var packageID: PackageID
    public var displayID: DisplayID
    public var fps: Double // average of the last 10 s
    public var droppedFrames: Int64
    public var hostReadbacks: Int64 // must stay 0 (AGENTS.md §6.4)
    public var cpuPixelCopies: Int64
    public var presentGPUTimeP50Us: Int64
    public var presentGPUTimeP95Us: Int64
}
```

Performance values use microseconds with the suffix `Us`, because input latencies are below one millisecond. This is an exception to the duration rule of §4.2.

### 13.2 Events

Topic `health`:

```swift
public enum HealthEvent: Codable, Sendable {
    case healthChanged(WireHealthResult) // live checks only (diagnostics.md §7.1)
    case unknown
}
```

`healthChanged` is coalesced per check ID.

### 13.3 Errors

| Operation | Errors |
|---|---|
| `healthReport` | `diagnostics.unknownHealthCheck` |
| `applyHealthFixes` | `diagnostics.unknownHealthCheck`, `diagnostics.fixNotAvailable`. A fix that fails is `diagnostics.fixFailed` in that row's `error`, not a reply error |
| `createDiagnostics` | `diagnostics.stagingFailed`, `diagnostics.bundleWriteFailed`, `runtime.malformedRequest` (the handle is not an empty regular file) |
| `perfStatistics` | none beyond §4.5 |
| `guestLog` | `runtime.developerModeRequired` |

---

## 14. Settings

Settings semantics: [configuration.md](configuration.md) §1.4, §1.5, §3. Global keys are in `settings.json` of apkrund. Package keys are in each package's `settings.json` (configuration §3). Update policy changes use `setUpdatePolicy` (§9). Shared-folder roots use the operations of §11.1.

### 14.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `configuration` | `Empty` → `ConfigurationSnapshot` | C | Q | — | [configuration.md](configuration.md) §1.4 |
| `updateConfiguration` | `ConfigurationPatch` → `ConfigurationSnapshot` | C | U | `runtime.configurationChanged(keys)` | configuration §1.4, §1.5, §8.1 |
| `packageSettings` | `PackageRequest` → `ResolvedPackageSettings` | C | Q | — | configuration §1.4, §3.2 |
| `updatePackageSettings` | `PackageSettingsPatch` → `ResolvedPackageSettings` | C | U | `packages.settingsChanged(id, keys)`; session `windowPrefsChanged` | configuration §1.4, §3, [../02-design/package-store.md](../02-design/package-store.md) §2.4 |

A launcher reads its own package's settings without these operations. It gets them from `packageInfo` (`PackageDetails.settings`, §8.3), `SessionDescriptor.windowPrefs` and `.inputPrefs` (§6.2), and `windowPrefsChanged` (§6.3). It changes only `window.zoom`, through `resize` (§14.3). It cannot read or change any other setting ([configuration.md](configuration.md) §1.4).

### 14.2 DTOs

```swift
public struct ConfigurationSnapshot: Codable, Sendable {
    public var entries: [ConfigurationEntry] // every key of configuration.md §2, sorted by key
}

public struct ConfigurationEntry: Codable, Sendable {
    public var key: String // dotted: "runtime.idleStopMinutes"
    public var value: JSONValue // the effective value
    public var defaultValue: JSONValue
    public var isSet: Bool // present in settings.json, also when equal to the default
    public var applies: SettingApplies
}

public struct ConfigurationPatch: Codable, Sendable {
    public var patch: JSONValue // an object: RFC 7396 merge patch on the nested form (configuration.md §1.2)
}

public struct PackageSettingsPatch: Codable, Sendable {
    public var packageID: PackageID
    public var patch: JSONValue // an object: merge patch on the nested package keys (configuration.md §3.1)
}

public struct ResolvedPackageSettings: Codable, Sendable {
    public var packageID: PackageID
    public var entries: [ResolvedSetting] // every key of configuration.md §3.1, sorted by key
    public var window: WindowSettings // the window.* values of entries, typed
    public var input: InputPrefs // the input.* values of entries, typed
}

public struct ResolvedSetting: Codable, Sendable {
    public var key: String // "window.zoom"
    public var value: JSONValue // the effective value
    public var source: SettingSource
    public var defaultValue: JSONValue
    public var recommended: JSONValue? // the compatibility database value, when there is one (#090)
    public var applies: SettingApplies
}

public enum SettingSource: String, Codable, Sendable { // configuration.md §3.2, in precedence order
    case globalSwitch // integrations.enabled.<kind> = false overrides the package value
    case user // the package's settings.json: set by the user, or from wrapper.json at the first record
    case recommended // compatibility.json recommendedSettings
    case `default`
    case unknown
}

public enum SettingApplies: String, Codable, Sendable { // configuration.md "Applies"
    case live, nextSession, runtimeRestart, nextCheck, nextLogin, newPackages, provisioning
    case nextBoot // runtime.bootTimeoutSeconds, runtime.firstBootTimeoutSeconds
    case nextHealthCheckResult // update.autoRollback
    case nextUpdate // update.healthCheckLaunch
    case unknown
}

public struct WindowSettings: Codable, Sendable, Equatable {
    public var mode: AndroidWindowMode //.secondaryDisplay,.primaryDisplayCompatibility
    public var defaultWidth: Int // points, ≥ 320
    public var defaultHeight: Int // points, ≥ 400
    public var resizable: Bool
    public var alwaysOnTop: Bool
    public var zoom: Double // 0.75…2.0
    public var closeBehavior: ClosePolicy //.stop,.keepRunning
}

public struct InputPrefs: Codable, Sendable, Equatable { // applied by InputCore in the launcher (input.md)
    public var escapeKey: EscapeKeyMapping //.back,.escape
    public var secondaryClick: SecondaryClickMapping //.mouseSecondary,.longPress
    public var scrollMode: ScrollMode //.scroll,.touchDrag
    public var hover: Bool
    public var sendCommandKey: Bool
}
```

- Entries use dotted keys. Patches use the nested form: `{"window": {"zoom": 1.25}}`. `configurationChanged` and `settingsChanged` carry dotted keys.
- Where configuration.md gives a compound Applies value (for example "live (next session with fallback B)" for `window.zoom`), `applies` is the first value. The rest is in the design text.
- `packageSettings` works for unmanaged packages. They have no `settings.json`, so every source is `globalSwitch` or `default`, and `integrations.notifications` is `false` (configuration §3.2).

### 14.3 Rules

- `null` resets a key. For global keys, the value falls back to the default. For package keys, the user's value is removed, and the value falls back to the recommendation, then the default.
- The whole patch is validated before anything is written. If one key fails, nothing is written and the reply is the error of the first failing key, in key order.
- Arrays are replaced whole (RFC 7396). An object that is not a known key group is `unknownSetting`.
- A patch that changes nothing is accepted. Nothing is written, no event is posted, and the reply is the current state.
- A key set explicitly to its default value is stored (`isSet = true`, source `user`).
- A patch that contains `sharedFolders` returns `runtime.invalidSettingValue` (configuration §8.1). The roots change only through §11.1.
- A package patch that contains `update.mode` returns `store.invalidSettingValue`. `setUpdatePolicy` (§9) writes the mode, the authority, and the provider together, so there is one writer. Chosen (§19.1).
- `updatePackageSettings` for an unmanaged package returns `store.packageNotFound`. The user adopts the package first (`adoptPackage`, §8.4). Chosen (§19.1).
- `apkrun config reset --all` and `apkrun settings <package> reset --all` are built by the client: one patch with `null` for every key where `isSet` is true (global) or `source` is `user` (package).
- A change to `window.resizable`, `window.alwaysOnTop`, or `window.zoom` sends `windowPrefsChanged` to the package's open session. Other window and input keys apply at the next session.
- **Zoom.** View → Zoom In, Zoom Out, and Actual Size send `resize` with the new `zoom` (§6.3). apkrund stores the value as the package's `window.zoom` (source `user`) and posts `packages.settingsChanged(id, ["window.zoom"])`. The session that sent the `resize` gets no `windowPrefsChanged`. Chosen (§19.1). [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §6.1 names this write path.
- **Use Current Size** (host-ui.md §7) reads `SessionSummary.pointSize` of the package's open session and writes `window.defaultWidth` and `window.defaultHeight` with `updatePackageSettings`.

### 14.4 Errors

| Operation | Errors |
|---|---|
| `configuration` | none beyond §4.5 |
| `updateConfiguration` | `runtime.unknownSetting`, `runtime.invalidSettingValue`, `runtime.hostStartupFailed` (settings are read-only while apkrund is degraded) |
| `packageSettings` | `store.packageNotFound`, `store.metadataUnreadable` |
| `updatePackageSettings` | `store.packageNotFound`, `store.unknownSetting`, `store.invalidSettingValue`, `store.storeReadOnly`, `runtime.hostStartupFailed` |

---

## 15. Developer operations

`DeveloperService` backs `apkrun dev` ([../02-design/cli.md](../02-design/cli.md) §5). It is a Swift protocol in RuntimeHost, next to `EmbeddedRuntimeService`, and exists only in embedded mode (§3.8). It is not part of RuntimeAPI's `@objc` protocols, has no wire form, and has no version. It takes Swift values. It uses URLs, because it runs in the CLI process with the CLI's own file access. Its types are not DTOs and have no round-trip tests.

| Method | Arguments → Result | Command | Design |
|---|---|---|---|
| `bootLinux` | `LinuxBootRequest { kernel: URL?, initrd: URL?, tests: [String], window: Bool, stats: Bool, timeoutMs: Int64? }` → `LinuxBootResult { results: [{ name, ok, line }] }` | `apkrun dev linux` | [../02-design/vm.md](../02-design/vm.md) §12 |
| `installImageBundle` | `ImageBundleInstallRequest { source: URL }` (a directory or an `.aar`) → `WireImageInfo` | `apkrun dev image install` | [../02-design/android-image.md](../02-design/android-image.md) §10.3 |
| `boot` | `DevBootRequest { bundle: URL?, gpu: DevGPUProfile?, window: Bool, stats: Bool, noAnimations: Bool, guestTransport:.vsock \|.adb, waitReady: Bool }` → `RuntimeStatus` | `apkrun dev boot` | cli §5, [../02-design/graphics.md](../02-design/graphics.md) §9 |
| `launchApps` | `DevLaunchRequest { items: [.apk(URL) \|.package(PackageID)], display:.primary \|.secondary, window: Bool }` → `[DevLaunchResult { packageID, outcome, taskID, session: SessionSummary? }]` | `apkrun dev launch` | cli §5, [../02-design/guest-protocol.md](../02-design/guest-protocol.md) §7.1, [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §12 |
| `addDisplay` | `DevDisplayRequest { pixelSize: PixelSize?, densityDpi: Int? }` → `DisplaySlotSnapshot` | `apkrun dev displays add` | cli §5 |
| `removeDisplay` | `DisplayID` → `Void` | `apkrun dev displays remove` | cli §5 |
| `listDisplays` | → `[DisplaySlotSnapshot]` | `apkrun dev displays list` | cli §5 |
| `injectPower` | `.sleep \|.wake` → `Void` | `apkrun dev power` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §6 |

- Errors are the domain errors of the design documents (`VMFailure`, `ImageFailure`, `RuntimeFailure`, …) as `APKRunError`, not `WireError`.
- `DevGPUProfile` maps to the GPU profiles of [../02-design/graphics.md](../02-design/graphics.md) §9: `.none` → `headless` (development only, #012), `.swiftshader` → `guestSwiftshader` (#021), `.virgl` → `drmVirgl` (#022). `nil` selects the default of cli §5, which is `.virgl` once #022 exists.
- `stats` adds an overlay to the development window with the fps and the readback counters of [../02-design/graphics.md](../02-design/graphics.md) §7. It is the same overlay for `bootLinux` and `boot`. Without `window` it has no effect. Chosen (§19.1).
- `launchApps` boots Android if needed, installs each APK through `AdbClient`, and launches each app through the Guest Agent (`LaunchApplication`). `outcome` and `taskID` come from its `LaunchResult`. With `window = false` (#072) it opens no window, `session` is `nil`, and the CLI only prints the result. From #024 the CLI sends `window = true`: the development window of #023 opens with input. From #026 each app gets its own window, `display =.secondary` (#029) uses a pool display, and several items (#030) run side by side.
- `injectPower` runs in the `apkrun dev boot` process that owns the instance. `apkrun dev power` reaches it through that process's control socket (cli §5).
- `apkrun dev console` and `apkrun dev adb` use no method. They attach to the console socket and run `adb` against the dev instance directly (cli §5).
- `DeveloperService` works only on the dev instance (`APKRUN_HOME`). It is never compiled into release APKRun.app or apkrund.

---

## 16. Events and streams

Topics fan out state changes to every subscribed connection. Streams deliver a sequence of messages to one connection. Session events are neither: they go only to the connection that owns the session (§6.3). Server side: `EventHub` in RuntimeHost ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.1, §8.4).

### 16.1 Subscription

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `subscribe` | `SubscribeRequest` → `SubscribeReply` | C; L (`runtime` only); W (`operations` only) | U | — | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.4 |
| `unsubscribe` | `UnsubscribeRequest` → `Empty` | C, L, W | U | — | runtime-daemon §8.4 |

```swift
public enum EventTopic: String, Codable, Sendable {
    case runtime, sessions, packages, updates, operations, health, maintenance, wrappers, integrations
}

public struct SubscribeRequest: Codable, Sendable { public var topics: [EventTopic] }
public struct SubscribeReply: Codable, Sendable { public var topics: [EventTopic] } // every topic the connection now has
public struct UnsubscribeRequest: Codable, Sendable { public var topics: [EventTopic] }
```

- The connection must export a `RuntimeEventSink` (§4.1). Otherwise `subscribe` returns `runtime.malformedRequest`.
- A topic that the client kind may not have fails the whole request with `runtime.notAuthorized`, and nothing changes. An unknown topic is `runtime.malformedRequest` (a request enum, §2.3).
- `subscribe` and `unsubscribe` are idempotent. Subscriptions end when the connection is invalidated (§3.5), and a reconnect subscribes again (§3.6).
- apkrund sends the replies and the event batches of one connection from one serial queue. The client therefore sees them in the order the server produced them. A client subscribes first and then fetches its snapshots (`runtimeStatus`, `listPackages`, `listOperations`, …). Events that arrive before a snapshot reply are older than the snapshot, and the client drops them. Chosen (§19.1).

### 16.2 Envelope, delivery, and coalescing

```swift
public struct EventEnvelope: Codable, Sendable {
    public var topic: EventTopic
    public var seq: UInt64 // per connection, from 1, assigned when sent
    public var time: Date // when the event was produced
    public var operationID: OperationID? // the operation that caused the event, when there is one
    public var payload: EventPayload
}

public enum EventPayload: Codable, Sendable {
    case runtime(RuntimeChange)
    case sessions(SessionListChange)
    case packages(PackageChange)
    case updates(UpdateEvent)
    case operations(OperationEvent)
    case health(HealthEvent) // §13.2
    case maintenance(MaintenanceEvent) // §12.4
    case wrappers(WrapperChange) // §10.9
    case integrations(IntegrationChange)
    case resyncRequired(EventTopic) // events of the topic were dropped: fetch fresh snapshots
    case unknown
}
```

Delivery:

| Rule | Value |
|---|---|
| Batch | `deliver` carries a JSON array of envelopes. apkrund sends a batch when 16 ms have passed since the first queued event, or when 64 events are queued. Chosen (§19.1) |
| Acknowledgement | the client calls the `deliver` reply block after it has decoded the batch. At most 4 batches are unacknowledged per connection. Chosen (§19.1) |
| Queue | 1024 envelopes per connection (§4.10). When the queue is full, apkrund drops the queued envelopes of the topic with the most queued envelopes and queues one `resyncRequired(topic)` in their place |
| Order | envelopes of one connection arrive in `seq` order. `seq` has no gaps, because it is assigned after coalescing and dropping |
| Coalescing | the latest value per key, at most 10 per second per key and connection. State changes, results, and `finished` events are never coalesced (runtime-daemon §8.4) |

Coalescing keys:

| Event | Key |
|---|---|
| `runtime.bootProgress` | one key |
| `operations.progress` | `OperationID` |
| `packages.operationProgress` | `OperationID` |
| `updates.progress` | `OperationID` |
| `maintenance.imageUpdateProgress` | `OperationID` |
| `health.healthChanged` | `HealthCheckID` |
| `wrappers.statusChanged` | `PackageID` |
| `integrations.statusChanged` | `PackageID` |

Payloads not defined in other sections:

```swift
public enum RuntimeChange: Codable, Sendable {
    case stateChanged(WireRuntimeState)
    case bootProgress(BootProgress) // coalesced
    case bootLoopGuardChanged(BootLoopGuardStatus?)
    case provisioningChanged(WireProvisioningState)
    case configurationChanged(keys: [String]) // dotted keys (configuration.md §1.5)
    case idleChanged(IdleStatus)
    case agentsChanged([AgentConnection])
    case developerModeChanged(Bool)
    case unknown
}

public enum SessionListChange: Codable, Sendable {
    case opened(SessionSummary)
    case stateChanged(SessionSummary)
    case ended(SessionSummary) // state is.ended(reason)
    case unknown
}

public enum PackageChange: Codable, Sendable { // package-store.md §11.3
    case installed(PackageSummary)
    case updated(PackageSummary, from: VersionCode) // also a same-version reinstall (from == to)
    case rolledBack(PackageSummary, from: VersionCode)
    case removed(PackageID, keptData: Bool)
    case stateChanged(PackageID, WirePackageState)
    case operationProgress(PackageID, OperationID, StoreOperationProgress) // coalesced
    case iconChanged(PackageID)
    case settingsChanged(PackageID, keys: [String])
    case unmanagedChanged([PackageSummary])
    case unknown
}

public struct StoreOperationProgress: Codable, Sendable, Equatable {
    public var stage: StoreOperationStage //.copying,.inspecting (import);.receiving,.verifying,.committing (guest install);.uninstalling
    public var fraction: Double?
}

public enum UpdateEvent: Codable, Sendable { // update-system.md §11.2
    case phaseChanged(PackageID, WireUpdatePhase)
    case progress(PackageID, OperationID, fraction: Double) // download, install; coalesced
    case finished(PackageID, UpdateOutcome)
    case summaryChanged(available: Int, waiting: Int, failed: Int) // for the menu bar badge
    case unknown
}

public enum IntegrationChange: Codable, Sendable { // desktop-integration.md §11
    case statusChanged(PackageID) // the client calls integrationStatus; coalesced
    case recordingChanged([PackageID]) // the packages that use the microphone now
    case sharedFoldersChanged // the client calls sharedFolders
    case unknown
}
```

- The `runtime` topic does not carry host state. `hostStateChanged` is on `maintenance` only (§12.4).
- The `runtime` topic does not carry health. Health changes are on `health` only (§13.2, runtime-daemon §8.4).
- The store's `PackageState` and UpdateCore's `UpdatePhase` are sent as `WirePackageState` and `WireUpdatePhase` (§8.3, §9.2).

### 16.3 Operation events

Topic `operations`. These events report every long operation of §4.7, including work that apkrund started itself and sub-operations (with `parent` set).

```swift
public enum OperationEvent: Codable, Sendable {
    case started(OperationSnapshot)
    case progress(OperationID, OperationProgress) // coalesced per operation
    case finished(OperationID, OperationResult)
    case unknown
}

public struct OperationProgress: Codable, Sendable, Equatable {
    public var fraction: Double? // nil = indeterminate
    public var stage: String? // the stage names in the operation tables: "copying", "collecting", …
    public var bytes: Int64?
    public var totalBytes: Int64?
    public var message: WireLocalizedText? // "Installing ‹App›…"
}

public enum OperationResult: Codable, Sendable {
    case succeeded(OperationOutput)
    case failed(WireError)
    case cancelled
    case unknown
}

public enum OperationOutput: Codable, Sendable {
    case none
    case runtime(RuntimeStatus)
    case importPreview(ImportPreview)
    case package(PackageSummary)
    case update(UpdateOutcome)
    case updateCheck([UpdateCheckResult])
    case wrapper(WrapperInfo)
    case wrappers(WrapperBatchResult)
    case distributionWrapper(DistributionWrapperResult)
    case imageUpdate(ImageUpdateStatus)
    case image(WireImageInfo)
    case diagnostics(DiagnosticsResult)
    case unknown
}
```

Output by kind:

| `OperationKind` | Output |
|---|---|
| `import`, `inspect` | `importPreview` |
| `install`, `repair`, `rollback`, `bootstrapImport` | `package` |
| `uninstall` | `none` |
| `update` | `update` |
| `updateCheck` | `updateCheck` |
| `wrapperCreate`, `wrapperRefresh` | `wrapper` |
| `wrapperRefreshAll` | `wrappers` |
| `distributionWrapper` | `distributionWrapper` |
| `setup`, `resetAndroid`, `runtimeStop`, `runtimeRestart` | `runtime` |
| `imageCheck`, `imageDownload`, `imageApply` | `imageUpdate` |
| `imageInstall`, `imageRollback` | `image` |
| `diagnostics` | `diagnostics` |

- `started` comes before any `progress` of the operation, and `finished` is the last event. A client that subscribes while an operation runs sees only the rest. It calls `operationStatus` for the current snapshot.
- A W subscriber gets only the operations that were started on its own wrapper endpoint (`importBootstrap`, §10.7). Other operations of its package are not sent to it.

### 16.4 Streams

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `notificationRelay`, `hostNotifications`, `guestLog` | §11.3, §13.1 → `StreamHandle` | as there | S | `streamEvent` | §11.3, §13.1 |
| `closeStream` | `CloseStreamRequest` → `Empty` | C, W | U | `ended(.closed)` | runtime-daemon §8.4, §8.6 |
| `notificationRelayResponse`, `hostNotificationResponse` | one-way `(_ response: Data)` | W; A | 1 | — | §11.3 |

```swift
public struct StreamHandle: Codable, Sendable { public var streamID: StreamID }

public struct StreamEnvelope: Codable, Sendable {
    public var streamID: StreamID
    public var seq: UInt64 // per stream, from 1
    public var event: StreamEvent
}

public enum StreamEvent: Codable, Sendable {
    case relay(RelayMessage) // notificationRelay (§11.3)
    case hostNotification(HostNotificationMessage) // hostNotifications (§11.3)
    case guestLog(GuestLogChunk) // guestLog (§13.1)
    case ended(StreamEndReason)
    case unknown
}

public enum StreamEndReason: Codable, Sendable, Equatable {
    case closed // closeStream
    case replaced // a newer hostNotifications stream took over (§11.3)
    case finished // guestLog with follow = false
    case error(WireError)
    case unknown
}

public struct CloseStreamRequest: Codable, Sendable { public var streamID: StreamID }
```

- A stream belongs to the connection that opened it. It ends when that connection is invalidated (§3.5), without an `ended` event.
- `ended` is the last event of a stream. The client does not call `closeStream` after it.
- `closeStream` is idempotent. An unknown ID, an ended stream, or a stream of another connection returns `Empty` and changes nothing. Chosen (§19.1): there is no `streamNotFound` error.
- Flow control uses the `streamEvent` reply block, as for `deliver` (§16.2): at most 4 unacknowledged events per stream. When the limit is reached, `guestLog` drops lines and counts them in `GuestLogChunk.dropped`, and the notification streams queue and drop as in §11.4.
- At most 4 streams are open per connection. Another stream request returns `runtime.busy`. Chosen (§19.1).

---

## 17. Shared types

### 17.1 `JSONValue` and `Empty`

```swift
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public struct Empty: Codable, Sendable, Equatable { public init {} } // encodes as {}
```

- `JSONValue` encodes as plain JSON (`true`, `1.25`, `"ask"`, `{…}`), not with the one-key enum form of §4.2. It is the only exception to that rule. It carries setting values and merge patches (§14).
- Integers are exact up to 2^53. Every integer setting is far below that (configuration.md §2).
- `null` inside a patch means "reset" (§14.3). In a value it means that the key has no value, for example an unset optional key.

### 17.2 Types defined here

Many small enums and structs are defined by the trailing comment where they are first used, for example `FolderAvailability //.available,.missing, …`. A comment of the form `.a,.b` lists the cases. `{ x, y }` lists the fields. Every enum in a reply or event is open and also has `unknown` (§2.3). Request enums have no `unknown`. The types below are used in several sections.

```swift
public struct ActivityKind: RawRepresentable, Codable, Sendable, Hashable { // runtime-daemon.md §5.1
    public var rawValue: String
    // known values: "session", "backgroundTask", "storeOperation", "diagnostics", "migration",
    // "provisioning", "adbClient", "cli"
}

public enum AgentKind: String, Codable, Sendable { case guest, store, unknown } // Guest Agent, Store Agent (guest-components.md)
public enum AgentConnectionState: String, Codable, Sendable { case connected, connecting, disconnected, incompatible, unknown }

public enum AndroidWindowMode: String, Codable, Sendable { case secondaryDisplay, primaryDisplayCompatibility, unknown }
public enum ClosePolicy: String, Codable, Sendable { case stop, keepRunning, unknown }
public enum EscapeKeyMapping: String, Codable, Sendable { case back, escape, unknown }
public enum SecondaryClickMapping: String, Codable, Sendable { case mouseSecondary, longPress, unknown }
public enum ScrollMode: String, Codable, Sendable { case scroll, touchDrag, unknown }

public enum StoreOperationStage: String, Codable, Sendable {
    case copying, inspecting // import (package-store.md §4)
    case receiving, verifying, committing // guest install: InstallProgress stages (guest-protocol.md)
    case uninstalling
    case unknown
}

public struct PixelSize: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
}

public struct DisplaySlotSnapshot: Codable, Sendable { // DisplayPool.snapshot (display-and-windowing.md §3)
    public var slot: Int // scanout index; 0 is Android's primary display
    public var state: WireDisplayState
    public var displayID: DisplayID? // the lease, while allocated
    public var androidDisplayID: Int32?
    public var pixelSize: PixelSize?
    public var densityDpi: Int?
}

public enum WireDisplayState: Codable, Sendable, Equatable { // state-machines.md §4
    case free, attaching
    case allocated(SessionID)
    case releasing
    case faulted(WireError)
    case unknown
}
```

- `ActivityKind` is a string, not an enum, because RuntimeCore adds kinds without a RuntimeAPI change. `session` is a wire-only value: SessionRegistry tracks sessions, and `IdleStatus.activities` lists `session` once while any session is open. Chosen (§19.1). A client shows an unknown value as is.
- `AgentConnection.required` tells whether the runtime waits for the agent (§5.3).
- `WaitingReason` names the false gate conditions GU1–GU7 of [../02-design/update-system.md](../02-design/update-system.md) §7.1, in the style of `ImageApplyCondition` (§12.3): `enum WaitingReason: String { case gu1RuntimeReady, gu2NoSession, gu3NoKeepRunningTask, gu4QuietPeriod, gu5AndroidAgrees, gu6NoStoreTransaction, gu7DisplaySlot, unknown }`. Chosen (§19.1).

### 17.3 Types copied from the design documents

These types keep the field names of their design definition. RuntimeAPI imports no other module ([../01-architecture/modules.md](../01-architecture/modules.md) §3), so it declares them itself.

| Wire type | Defined in |
|---|---|
| `ImportPreview`, `ImportRelation` | [../02-design/package-store.md](../02-design/package-store.md) §4.7 |
| `WirePackageRecord`, `OperationSummary` (§2.3.5), `ArtifactSlotsSummary` (the `artifacts` object, §2.3.2) | [package-metadata-json.md](package-metadata-json.md) |
| `WrapperStatus`, `WrapperState` | [../02-design/wrapper.md](../02-design/wrapper.md) §9.1 |
| `BundleProblem` | wrapper §13 |
| `IntegrationKind` | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2 |
| `ImageVersion` | [../02-design/android-image.md](../02-design/android-image.md) §9.1 |
| `SessionID`, `SystemDisplayUse` | [../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §3.1 |
| `HostRequirement` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §9.1 |

### 17.4 Ownership and conversion

The modules that import RuntimeAPI (RuntimeCore, APKStoreCore, UpdateCore, WrapperCore, IntegrationCore) may use a wire type as their own type, or convert to it. For InputCore and DiagnosticsCore, which do not import RuntimeAPI, RuntimeHost converts on the server. On the client, APKRunLauncher converts input (`XPCInputSink`), and RuntimeClient converts errors. Clients use the wire types directly, except errors: RuntimeClient converts `WireError` back to `APKRunError` (§4.5).

| Wire type | Domain type | Owner module | Definition |
|---|---|---|---|
| `WireRuntimeState`, `BootPhase`, `WireStopReason` | `RuntimeState` | RuntimeCore | [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §2 |
| `SessionPhase`, `SessionEndReason` | session state | RuntimeCore (SessionRegistry) | state-machines §3 |
| `WireDisplayState` | `DisplayState` | RuntimeCore (DisplayPool) | state-machines §4 |
| `WirePackageState`, `PackageChange` | `PackageState` | APKStoreCore | state-machines §5, package-store §11.3 |
| `WireUpdatePhase`, `UpdateOutcome`, `UpdateEvent` | `UpdatePhase` | UpdateCore | state-machines §6, update-system §11.2 |
| `WireProvisioningState` | provisioning state | RuntimeHost | runtime-daemon §9.2 |
| `WireImageUpdatePhase`, `WireImageCandidate` | image update phase | RuntimeHost (`ImageUpdateCoordinator`) | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.3 |
| `WrapperStatus`, `WrapperSummary`, `WrapperInfo` | `WrapperStatus`, registry entry | WrapperCore | wrapper §9.1, §12.1 |
| `ImportPreview` | `ImportPreview` | APKStoreCore | package-store §4.7 |
| `WireIntegrationDecision`, `IntegrationStatus` | integration decision | IntegrationCore | desktop-integration §2.3, §11 |
| `InputBatch` and the other types of §7.2 | input events | InputCore | [../02-design/input.md](../02-design/input.md) §8 |
| `WireError`, `WireLocalizedText` | `APKRunError`, localized text | DiagnosticsCore | [../02-design/diagnostics.md](../02-design/diagnostics.md) §2.1, §2.2 |
| `WireHealthReport`, `WireHealthResult`, `WirePerfStatistics` | health report, perf statistics | DiagnosticsCore | diagnostics §7, §9.3 |

A new case in a domain enum needs a new wire case. Until the wire case exists, RuntimeHost sends `unknown`, and a T0 test that maps every domain case fails.

---

## 18. Client mappings

These tables name the operations that each command, control, and screen calls. They let a reviewer check that no surface needs an operation this document lacks. The behavior belongs to the design documents cited in each section.

Every client does the following:

- It connects with `hello` and then `requestEndpoint` (§3.1). A wrapper that is not approved yet sends `requestApproval` (§3.4).
- A client that shows live state calls `subscribe` for its topics (§16.1). After a reconnect it reloads its data with the snapshot operations (§3.6).
- For a long operation, the client waits for `OperationEvent.finished` on `operations` (§16.3). It sends `cancel` on Ctrl-C or **Cancel** (§4.7).
- "No operation" means the client acts locally: an `apkrun://` URL, AppKit, Sparkle, `SMAppService`, or the file system.

### 18.1 CLI

The CLI uses the control endpoint. It uses the maintenance endpoint only for `self-update finish`. `--json` prints the reply DTO ([../02-design/cli.md](../02-design/cli.md) §3.2). The rows follow the order of cli §4 and [../02-design/wrapper.md](../02-design/wrapper.md) §12.2. The commands under `apkrun dev` are in §15.

| Command | Operations | Notes |
|---|---|---|
| `version` | `hello`, `runtimeStatus` | the apkrund version comes from `HelloReply`, the image version from `RuntimeStatus.imageVersion`. When apkrund cannot be reached, the command prints only the CLI version |
| `setup [--image]` | `setup` | `--image <file>` sends `.archive(fileIndex:)`. When apkrund is not registered, the CLI first opens `APKRun --register-runtime` (no operation) |
| `status` | `runtimeStatus`, `listSessions`, `listUpdates`, `activeRecordings` | the summary of the menu bar. Developer mode comes from `RuntimeStatus.developerMode` |
| `runtime status` | `runtimeStatus` | |
| `runtime start [--hold] [--timeout]` | `startRuntime` | `hold`, `timeoutMs` |
| `runtime stop [--force]` | `stopRuntime` | on `runtime.busy` the CLI asks, then sends `force = true` |
| `runtime restart` | `restartRuntime` | |
| `runtime reset` | `resetRuntime` | |
| `runtime reset --erase [--no-backup]` | `resetAndroid` | `keepBackup = !--no-backup`, `confirmed` after the prompt or with `--yes` |
| `info [--runtime] [--displays]` | `runtimeInfo` | `resources`, `displays` |
| `install <file>…` | `importPackage`, `installImported` | `--provider` and `--updates` become `InstallOptions` (`--updates manual` sets `authority =.manual`). With `--wrap` it also sets `createWrapper`. With `--wrap --output` it calls `createWrapper` after the install instead (§8.2) |
| `uninstall <package>` | `uninstallPackage` | `--keep-data` sets `keepData`, `--keep-wrapper` sets `trashWrappers = false`, and `--forget` sets `forget` |
| `list [--all]` | `listPackages` | `.managed` or `.all` |
| `info <package>` | `packageInfo` | |
| `inspect <file>…` | `inspectFile` | |
| `launch <package>` | `launch` | |
| `stop <package>` | `terminate` | |
| `repair <package>` | `repairPackage` | |
| `rollback <package>` | `rollbackPackage` | `allowDataLoss` |
| `adopt <package>` | `adoptPackage` | |
| `settings <package> list` and `get` | `packageSettings` | |
| `settings <package> set` | `updatePackageSettings` | `{ "<key>": <value> }` in nested form |
| `settings <package> reset` | `updatePackageSettings` | `null` for the key. For `--all`, the client builds a patch with every key that is set (§14.3) |
| `update [--check-only]` | `checkForUpdates` | `packages = nil`. `--check-only` sets `checkOnly` (§9.2). One line per `UpdateCheckResult` |
| `update <package> [--now] [--file]` | `updatePackage` | a user-initiated update, which checks the provider first (update-system §7.3). `--now` sets `closeRunningApp`. Without `--now` and the app open, the CLI prints "will update when ‹App› quits" and returns. `--file` sends `files` |
| `update policy <package>` | `setUpdatePolicy` | |
| `update authority <package> apkrun\|manual\|external` | `setUpdateAuthority` | |
| `update skip <package> <versionCode>` | `skipVersion` | |
| `update unskip <package> <versionCode>` | `unskipVersion` | |
| `update history [<package>]` | `updateHistory` | |
| `integrations status <package>` | `integrationStatus` | |
| `shared-folders list`, `add`, `remove` | `sharedFolders`, `addSharedFolder`, `removeSharedFolder` | `add` creates the bookmark in the CLI |
| `config list` and `get` | `configuration` | |
| `config set` and `reset` | `updateConfiguration` | `reset` sends `null`. For `--all`, the client builds the patch |
| `image list` | `listImages` | |
| `image check` | `checkImageUpdate` | |
| `image install <file.aar>` and `--latest` | `installImage` | `.file(fileIndex:)` or `.latest`, with `apply = true` |
| `image rollback` | `rollbackImage` | `confirmed` after the prompt |
| `image recovery-points list` and `delete` | `recoveryPoints`, `deleteRecoveryPoint` | |
| `self-update check` | `checkSelfUpdate` | `userInitiated` |
| `self-update install` | no operation | opens `apkrun://settings/general` |
| `self-update finish` | `restartForUpdate` (maintenance endpoint) | |
| `doctor [--deep]` | `healthReport` | |
| `doctor --fix` | `healthReport`, `applyHealthFixes` | `checks = []` |
| `diagnostics` | `createDiagnostics` | the CLI creates the output file and passes its handle (§13.1) |
| `logs` | no operation | `log show` or `log stream` on the host (cli §4.8) |
| `logs --guest [--follow]` | `guestLog` | needs developer mode |
| `operations list` | `listOperations` | |
| `operations wait <id>` | `operationStatus`, topic `operations` | |
| `operations cancel <id>` | `cancel` | |
| `wrap <file>…` | `importPackage`, `installImported` when an install is needed, `createWrapper` | the combinations of wrapper §12.2. `--portable` without an install sends `importTicket` |
| `wrap <package>` | `createWrapper` | `--output` sets `destination`, `--replace` sets `replace =.sameWrapper` |
| `wrap <package> --distribution` | `buildDistributionWrapper` | M12 |
| `wrapper list` | `listWrappers` | |
| `wrapper info <package>` | `wrapperInfo` | |
| `wrapper refresh <package>…` | `refreshWrapper` | `--name`, `--icon`, `--android-icon`, `--launcher-only` |
| `wrapper refresh --all` | `refreshAllWrappers` | `scope =.all` |
| `wrapper remove <package> [--trash]` | `removeWrapper` | |
| `wrapper verify <path> [--deep]` | `verifyWrapper` | |
| `wrapper approve <path>` | `approveWrapper` | |

### 18.2 APKRun.app

Sections refer to [../02-design/host-ui.md](../02-design/host-ui.md).

| Surface | Operations | Notes |
|---|---|---|
| Models (§2.2) | `runtimeStatus`, `listPackages(.all)`, `packageInfo`, `integrationStatus`, `listWrappers`, `listUpdates`, `listSessions`, `listOperations`, `configuration`, `selfUpdateStatus`, `imageUpdateStatus`, `pendingApprovals`, `hostNotifications` | topics `runtime`, `packages`, `sessions`, `updates`, `operations`, `wrappers`, `integrations`, `health`, `maintenance` |
| Banner **Restart Service** (§2.2) | no operation | re-registers the agent with `SMAppService` |
| `--register-runtime` (§3.3) | no operation | |
| Onboarding (§4) | `setup` | **Choose Image…** sends `.archive` or `.directory`. **Try Again** sends `setup` again. **Start Over** sets `recreateInstance = true`. **Report…** calls `createDiagnostics` |
| Header (§5.2): **Start Android**, **Stop Android**, **Restart** | `startRuntime`, `stopRuntime`, `restartRuntime` | `stopRuntime` asks on `runtime.busy`, then repeats with `force` |
| Header: **Start in Graphics Safe Mode** | `updateConfiguration({ graphics.safeMode: true })`, `restartRuntime` | |
| Header: **Reset Android…**, **Continue Setup**, **Restart Now** | `resetAndroid`, `setup`, `restartForUpdate` (maintenance endpoint) | |
| App rows (§5.3): **Open**, **Update Now**, **Check for Updates** | `launch`, `updatePackage`, `checkForUpdates { [id] }` | icons come from `packageIcon` |
| App rows: **Repair…**, **Update Mac App**, **Uninstall…** | `repairPackage`, `refreshWrapper`, `uninstallPackage` | |
| App rows: **Show Mac App in Finder** | no operation | the path comes from `listWrappers` |
| Other Android Apps (§5.4): **Open**, **Manage with APKRun** | `launch`, `adoptPackage` | |
| Add flow (§6): reading and review | `importPackage`, `cancelImport` | `origin` is `.addFlow`, `.document`, or `.dropOnHome` |
| Add flow: **Install**, **Install Anyway**, **Reinstall**, **Update** | `installImported` | with **Create Mac app** at a location other than Applications (for me), the app calls `createWrapper` after the install |
| Add flow: **Quit and Update** | `terminate` | the waiting `update` operation then continues. Chosen in this document's §19.1 |
| Add flow: **Choose Another Location…** | `placeStagedWrapper` | |
| App page (§7): every control of §7.1–§7.4 and the settings rows of §7.5 | `packageSettings`, `updatePackageSettings` | **Reset** sends `null` |
| App page: **Use Current Size** | `listSessions` | the size is `SessionSummary.pointSize` (§14.3) |
| App page: Name and Icon | `refreshWrapper` | through **Update Mac App** |
| App page, Updates (§7.5): mode and source, **Check Now**, history, **Roll Back to ‹version›…**, **Updated by** | `setUpdatePolicy`, `checkForUpdates { [id] }`, `updateHistory`, `rollbackPackage`, `setUpdateAuthority` | |
| App page, Mac App (§7.6): **Create Mac App**, **Update Mac App**, **Make Local Mac App**, **Remove Mac App…** | `createWrapper`, `refreshWrapper`, `refreshWrapper { makeLocal }`, `removeWrapper { trash: true }` | the status comes from `wrapperInfo` |
| App page, Storage (§7.7): **Remove from APKRun** | `uninstallPackage { forget: true }` | |
| Uninstall dialog (§8) | `uninstallPackage` | `keepData`, `trashWrappers`. When Android cannot start, `forget` |
| Settings → General (§9.1) | `configuration`, `updateConfiguration`, `selfUpdateStatus`, `imageUpdateStatus`, `checkImageUpdate`, `applyImageUpdate` | Sparkle installs APKRun and reports through `noteSelfUpdateStatus`. The menu bar toggle is a login item (no operation) |
| Settings → Runtime, Updates, Language & Region (§9.2, §9.3, §9.6) | `configuration`, `updateConfiguration` | |
| Settings → Privacy (§9.4) | `updateConfiguration`, `deniedWrappers`, `clearWrapperDenial` | **Remove** calls `clearWrapperDenial` |
| Settings → Files (§9.5) | `sharedFolders`, `addSharedFolder`, `removeSharedFolder`, `setSharedFolderAccess` | the bookmark comes from the open panel |
| Settings → Storage (§9.7): sizes | `runtimeInfo { resources: true }`, `listPackages(.all)`, `listImages`, `recoveryPoints` | |
| Settings → Storage: **Reinstall…**, **Delete Data** | `importPackage` and `installImported`, `uninstallPackage { forget: true }` | for `uninstalledKeepingData` |
| Settings → Storage: recovery point **Delete…**, **Go Back to Android ‹A›…**, **Install from File…** | `deleteRecoveryPoint`, `rollbackImage`, `installImage {.file }` | |
| Troubleshooting (§9.8): **Run Again**, **Deep Check**, **Fix** | `healthReport`, `healthReport { deep: true }`, `applyHealthFixes` | |
| Troubleshooting: **Create Diagnostics Report…** | `createDiagnostics` | **Cancel** sends `cancel` |
| Troubleshooting: **Restart Android**, **Turn Off Graphics Safe Mode**, **Reset Android…** | `restartRuntime`, `updateConfiguration({ graphics.safeMode: null })` then `restartRuntime`, `resetAndroid` | |
| **Re-register Mac Apps** (wrapper §7.2) | `rescanWrappers { register: false }`, then `{ register: true }` after the confirmation | |
| Troubleshooting: **Refresh Dock Icons** | no operation | APKRun.app restarts the Dock after a confirmation (wrapper §8.5) |
| Advanced (§9.9): **Developer mode** | `updateConfiguration({ developer.enabled })` | **Install Command-Line Tool…** and **Reveal Logs in Finder** need no operation |
| Approval prompt (§10.1): **Allow**, **Don't Allow** | `pendingApprovals`, `decideApproval` | topic `wrappers` (`approvalRequested`) |
| Notifications (§11) | `hostNotifications`, `hostNotificationResponse` | **Update Now** calls `updatePackage` or `applyImageUpdate`. **Restart** calls `startRuntime`. **Update…** opens Sparkle (no operation) |

### 18.3 APKRunMenuBar

Sections refer to host-ui §12. The menu bar observes. It never holds an activity.

| Item | Operations | Notes |
|---|---|---|
| Runtime line, dot, "Needs attention" | `runtimeStatus` | topics `runtime`, `health` (live checks, `healthChanged`), `maintenance` |
| **Apps** | `listSessions`, `activeRecordings`, `launch` | topics `sessions`, `integrations` |
| **Updates**: **Update**, **Update All** | `listUpdates`, `updatePackage` | **Update All** calls `updatePackage` once for each listed package |
| Maintenance rows: **Update…**, **Update Now**, "Finish updating APKRun…" | `selfUpdateStatus`, `imageUpdateStatus`; then no operation, `applyImageUpdate`, `restartForUpdate` (maintenance endpoint) | **Update…** opens `apkrun://settings/general`. `restartPending` comes from `RuntimeStatus.hostState` |
| **Stop Android**, **Start Android** | `stopRuntime`, `startRuntime` | |
| **Open APKRun…**, **Quit Menu Bar Item** | no operation | |

### 18.4 Wrapper and generic launcher

Sections refer to wrapper.md. The generic launcher (L) uses the same code with a different endpoint (§1.4).

| Surface | Operations | Notes |
|---|---|---|
| Start (§5.2, §5.3) | `hello`, `requestEndpoint(.wrapper)`, `requestApproval` when needed, `runtimeStatus`, `packageInfo`, `openSession` | `packageInfo` supplies the resolved window defaults (wrapper §5.2, §14.1) |
| Window | `frameDisplayed`, `visibilityChanged`, `focusChanged`, `resize` | §6.3 |
| Input and text | `sendInput`, `sendText` | §7 |
| Integrations | `pushClipboard`, `clipboardWritten`, `importFiles`, `acceptExport`, `resolveLinkPrompt`, `notificationRelay`, `notificationRelayResponse` | §11 |
| Screen N **Install from This App** (portable) | `importBootstrap` | §10.7 |
| Screen E **Try Again**, **Reopen**, reconnect | `openSession` | |
| **Open APKRun**, **Get APKRun**, **Check for Updates**, **Update Mac App**, Settings… (⌘), Show in APKRun, Report a Problem… | no operation | `apkrun://` URLs and the downloads page |
| ⌘W, ⌘Q, logout | `closeSession` | |
| View: Zoom In, Zoom Out, Actual Size | `resize` | writes `window.zoom` (§14.3) |
| View: Show Frame Statistics | `frameStatistics` | once per second while shown (§6.3) |
| Android: Back | `sendInput` | |
| Android: Restart ‹App› | `restartApp` | §6.3 |
| About ‹App› | `packageInfo` | |
| Wrapper operations that last long | `operationStatus`, `cancel`, topic `operations` | only operations started on this endpoint (§16.3) |

---

## 19. Decisions and open items

### 19.1 Choices made in this document

The design documents do not fix these values. This document chose them, and later changes follow §2.3.

| Item | Choice | Section |
|---|---|---|
| **Start Over** after 2 failed first boots | `SetupRequest.recreateInstance` | §5.4 |
| `inputPrefs` and `pointSize` | `SessionDescriptor.inputPrefs`; `SessionSummary.pointSize` for **Use Current Size** | §6.2, §14.3 |
| Staging token | valid for 60 minutes, and until apkrund exits | §10.3 |
| `WrapperRequest.destination = nil` | `wrappers.defaultLocation`. The value "ask" there means `.userApplications` | §10.3 |
| Bootstrap import | `bootstrapJSON` at most 64 KiB, 1–20 files | §10.7 |
| Host notifications | APKRun.app only (A). One stream at a time; a new one replaces the old | §11.3 |
| Zoom | `resize` writes `window.zoom` and posts `packages.settingsChanged`. The sending session gets no `windowPrefsChanged` | §14.3 |
| `update.mode` in a package settings patch | refused with `store.invalidSettingValue`. `setUpdatePolicy` is the only writer | §14.3 |
| Settings of an unmanaged package | `store.packageNotFound`. The user adopts the package first | §14.3 |
| Reply and event order | one serial queue per connection sends replies and events. Events that arrive before a snapshot reply are older than the snapshot | §16.1 |
| Event batching | a batch goes out after 16 ms or at 64 events. At most 4 batches are unacknowledged per connection | §16.2 |
| Queue overflow | drop the queued events of the topic with the most events, then send `resyncRequired(topic)` | §16.2 |
| Streams | at most 4 per connection (then `runtime.busy`). 4 unacknowledged events per stream. `closeStream` is idempotent and has no not-found error | §16.4 |
| `ActivityKind.session` | listed once while any session is open | §17.2 |
| `WaitingReason` | `gu1RuntimeReady` … `gu7DisplaySlot`, after update-system §7 | §17.2 |
| `StoreOperationStage` | `copying`, `inspecting`, `receiving`, `verifying`, `committing`, `uninstalling` | §16.2, §17.2 |
| `DeveloperService` | a Swift protocol in RuntimeHost with no wire form. `launchApps` has `window`; `stats` without `window` has no effect | §15 |
| Add flow **Quit and Update** | `terminate`. The waiting `update` operation then continues | §18.2 |

### 19.2 Operations first named here

This document named some operations before any design document did. Their owning design documents now list them, with their tasks:

| Operations | Owner |
|---|---|
| `startRuntime`, `stopRuntime`, `restartRuntime`, `resetRuntime`, `runtimeInfo`, `listSessions`, `restartApp`, `listOperations`, `unsubscribe`, `closeStream` | [../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §8.6 |
| `refreshAllWrappers`, `rescanWrappers`, `pendingApprovals`, `deniedWrappers`, `clearWrapperDenial` | [../02-design/wrapper.md](../02-design/wrapper.md) §12.1 |
| `notificationRelayResponse`, `hostNotifications`, `hostNotificationResponse` | [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §11, [../02-design/host-ui.md](../02-design/host-ui.md) §11 |
| `guestLog` | [../02-design/diagnostics.md](../02-design/diagnostics.md) §7.6 |
| `DeveloperService` methods (no wire form, §15) | the `apkrun dev` commands of [../02-design/cli.md](../02-design/cli.md) §5 |

This document also gives the DTO shapes for operations that the design documents name without fields: `subscribe`, `wrapperInfo`, `placeStagedWrapper`, `noteSelfUpdateStatus`, `cancelImageDownload`, `integrationStatus`, and `perfStatistics`.

The error codes that this document introduced (`runtime.developerModeRequired`, `wrapper.stagingExpired`, `wrapper.approvalNotFound`) are in [error-catalog.md](error-catalog.md) §7.4, §12.1, and §12.2.

### 19.3 Open items

The conflicts with other documents that this document found are fixed in those documents. These items still wait for a decision:

| Item | Why it is open | Until then |
|---|---|---|
| The `refreshBlocked` fallback (`stagingToken`, APKRun.app swaps `Contents`) | it is needed only if macOS App Management blocks apkrund's swap. #076 finds out ([../04-plan/risks.md](../04-plan/risks.md) R-20) | specified in §10.5. If #076 finds no block, `stagingToken` is removed |
| Restoring the Reset Android recovery point | no operation and no UI restore it. A Decision before #058 ([../04-plan/open-questions.md](../04-plan/open-questions.md) OQ-41) | no restore operation in v1 (§12.3) |
