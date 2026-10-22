# RuntimeAPI Reference

This document is the wire contract of RuntimeAPI, the XPC interface between apkrund and its clients: APKRun.app, APKRunMenuBar, the `apkrun` CLI, and the launchers. It defines endpoints, encoding, limits, operations, errors, events, and allowed clients. Design documents own behavior and are linked from each row. Swift types are in `Packages/RuntimeAPI`; where a built type exists, its shape here is the code's shape.

---

## 1. Overview

### 1.1 Scope and modules

Built operations: broker `hello`, `requestEndpoint`; control `runtimeStatus`, `startRuntime`, `stopRuntime`, `restartRuntime`, `resetRuntime`, `listPackages`, `packageInfo`, `importPackage`, `installImported`, `beginInstallImported`, `beginUninstallPackage`, `cancelOperation`, `listOperations`, `operationStatus`, `subscribe`, `unsubscribe`, `launch`, `terminate`; event sink `handshake`, `deliver`. Every other operation and type is target contract.

| Part | Module | Role |
|---|---|---|
| Contract: DTOs, `@objc` protocols, `APIVersion`, service protocols | RuntimeAPI | Foundation and IOSurface only ([modules.md](../01-architecture/modules.md) §2) |
| Server | RuntimeHost (`RuntimeXPCServer.swift`, `RuntimeEventHub.swift`) | Serves the contract ([runtime-daemon.md](../02-design/runtime-daemon.md) §8.1) |
| Client | RuntimeClient (`RuntimeControlClient.swift`, `RuntimeEventDelivery.swift`) | Connection, reconnect, error conversion |

### 1.2 Endpoints

| Endpoint | Reached by | Served to | Protocol | Version rule (§2.2) |
|---|---|---|---|---|
| Broker | Mach service `io.apkrun.apkrund.xpc` (dev: `.dev.xpc`; update-test: `io.apkrun.apkrund.updatetest.xpc`) | any process of the user | `RuntimeBrokerXPC` | every revision |
| Control | anonymous listener per grant, bound to the client's code requirement | APKRun.app, APKRunMenuBar, apkrun, APKRunLauncher | `RuntimeControlXPC` | same major, minor ≤ server |
| Maintenance (target) | anonymous listener per host client | APKRun.app, APKRunMenuBar, apkrun | `MaintenanceControl` | frozen, additive only |
| Wrapper (target) | anonymous listener per registered wrapper, dropped 10 min after its last connection | that wrapper's launcher | `RuntimeWrapperXPC` | major N and N−1 |

Clients that subscribe or open sessions export one `RuntimeEventSink` on their endpoint connection (§4.1). The broker exposes no capabilities ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).

### 1.3 Client kinds

| `RuntimeClientKind` | Process | Identifier (release) | Endpoint |
|---|---|---|---|
| `app` | APKRun.app | `io.apkrun.APKRun` | control |
| `menuBar` | APKRunMenuBar | `io.apkrun.APKRunMenuBar` | control |
| `cli` | apkrun | `io.apkrun.cli` | control |
| `launcher` | APKRunLauncher (`--package <id>`) | `io.apkrun.APKRunLauncher` | control, restricted (§1.4) |
| `wrapper` (target) | a wrapper's launcher | `io.apkrun.android.<mapped package>` ([wrapper.md](../02-design/wrapper.md) §4) | wrapper |

Dev builds append `.dev`; update-test builds append `.updatetest` to host identifiers ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6). Wrapper identifiers do not change.

### 1.4 Permission notation

| Letter | Who | Endpoint |
|---|---|---|
| C | APKRun.app, APKRunMenuBar, apkrun | control |
| A | APKRun.app only | control |
| L | the generic launcher | control |
| W | a wrapper, for its own package only (target) | wrapper |
| M | APKRun.app, APKRunMenuBar, apkrun (target) | maintenance |
| B | any process | broker |

- C is the full control surface. A narrows operations that answer prompts or report Sparkle state.
- L may call `runtimeStatus`, `packageInfo`, and `subscribe`/`unsubscribe` for topic `runtime`. Target: `packageIcon` and the session operations of §6. Anything else returns `runtime.notAuthorized`.
- W may call only the operations of §10.1. A request naming another package returns `runtime.notAuthorized` and writes a security log entry ([runtime-daemon.md](../02-design/runtime-daemon.md) §8.2).
- The server derives the client kind from the listener that accepted the connection. A header `clientKind` that differs, or an operation the kind may not call, returns `runtime.notAuthorized`.

### 1.5 Code-signing requirements

apkrund sets a requirement on each listener with `setConnectionCodeSigningRequirement(_:)`. Clients set one for apkrund with `setCodeSigningRequirement(_:)` before `resume()`.

| Connection | Release | Development (ad hoc) |
|---|---|---|
| control and maintenance listener | `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "<identifier>"` | `cdhash H"<cdhash>"` of that binary, computed at apkrund start |
| wrapper listener | `identifier "<bundleID>" and cdhash H"<registered cdhash>"` from `Wrappers/registry.json` | the same |
| client → apkrund | `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>" and identifier "io.apkrun.apkrund"` | `identifier "io.apkrun.apkrund.dev"` |

- A failed requirement invalidates the connection. A claim in `hello` grants nothing.
- apkrund never authorizes by `auditToken` or `processIdentifier` ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).
- Each wrapper is signed ad hoc with its bundle ID, so each has its own cdhash ([wrapper.md](../02-design/wrapper.md) §7.1).

### 1.6 Connection model

- A client opens the broker, calls `hello` and `requestEndpoint`, and closes the broker connection. A wrapper keeps it open while it waits for approval (§3.4).
- A client holds at most one endpoint connection of each kind.
- A connection holds at most one app session. Only launchers open sessions (ADR-0006).
- Session events go only to the owning connection. Topic events go to every subscriber (§16.1).
- Long operations outlive their connection (§4.7). A session is orphaned for 3 s after its connection drops (§6.2).
- Limits: §4.10.

---

## 2. Versioning and compatibility

### 2.1 Constants

`APIVersion.current` is the control protocol version. `APIVersion` has `major` and `minor` (Int) and encodes as `{"major": 1, "minor": 12}`. Ordering compares `major`, then `minor`.

```swift
public struct APIVersion: Codable, Comparable, Equatable, Sendable {
    public static let current = APIVersion(major: 1, minor: 12)
    public let major: Int
    public let minor: Int
}
```

Target constants (not in code): `wrapperMajors = [1]` (served on the wrapper endpoint: N and N−1), `brokerRevision = 2`, `maintenanceRevision = 1`. A release's `components.json` records `"runtimeAPI": { "current": "M.m", "wrapperMajors": [N−1, N] }` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.3).

| Version | Adds |
|---|---|
| 1.0 | broker `hello`, `requestEndpoint`; control `runtimeStatus`, `startRuntime`, `stopRuntime` |
| 1.1 | optional `guestAgentState`, `guestAgentProtocolVersion` in `RuntimeHostStatus` |
| 1.2 | control `launch`, `terminate` |
| 1.3 | admission bounds (§4.10); rejection `busy`. API 1.0–1.2 clients get `hostShuttingDown` at the control limit |
| 1.4 | control `listPackages`, `packageInfo`. Package queries never start Android |
| 1.5 | control `resetRuntime` |
| 1.6 | control `restartRuntime` |
| 1.7 | control `importPackage` (file handles), `installImported` (synchronous) |
| 1.8 | `beginInstallImported`, `cancelOperation`, `listOperations`, `operationStatus`; the last 50 finished operations are kept in memory |
| 1.9 | `subscribe`, `unsubscribe`; event-sink handshake; sequenced batches |
| 1.10 | `packages.installed` and `packages.updated` events |
| 1.11 | `beginUninstallPackage`; `PackageChange.removed`; `OperationSnapshot.requestFingerprint` |
| 1.12 | Optional `StartRuntimeRequest.hold` keeps a CLI start activity until its control connection closes |

### 2.2 Rules per endpoint

| Endpoint | Accepts | On mismatch |
|---|---|---|
| Broker | every revision. `hello` never fails on a version | — |
| Control | server's major; minor ≤ server's minor | `runtime.apiVersionMismatch` |
| Wrapper (target) | server's major and N−1 | `runtime.apiVersionMismatch` |
| Maintenance (target) | every client | — |

A client newer than the server in minor only is refused on control. That happens only during an APKRun update, which the maintenance endpoint covers ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6).

### 2.3 Minor and major changes

| Change | Kind |
|---|---|
| new operation, optional request field, reply field, event, topic, enum case, error code | minor |
| optional `WireError.listItems` | minor |
| new request-enum case | minor. The server rejects an unknown request case with `runtime.malformedRequest` |
| making an optional request field required; removing or renaming a field, case, or operation; changing a type, meaning, or encoding | major |

- Reply and event enums are open: an unknown case decodes as `.unknown`.
- Broker and maintenance accept only minor changes.
- The wrapper endpoint keeps N−1 DTOs in a versioned namespace (`RuntimeAPI.V<N−1>`) and converts them. Tests decode fixtures of every served major.

### 2.4 Wrapper compatibility

The launcher is built against `M.m`, and apkrund serves `N.n` ([wrapper.md](../02-design/wrapper.md) §5.3):

| Condition | Result |
|---|---|
| `runtimeVersion` < `runtime.minimumVersion` in `wrapper.json` | screen V |
| `M == N`, `m ≤ n` | OK |
| `M == N`, `m > n`, or `M > N` | screen V |
| `M == N − 1` | OK; apkrund marks the wrapper for a launcher refresh (`.launcher` in `refreshReasons`) |
| `M < N − 1` | screen L |

---

## 3. Connection lifecycle

### 3.1 Sequence

```text
client                                     apkrund
  connect io.apkrun.apkrund.xpc         ─▶ broker
  hello(RuntimeHelloRequest)            ─▶ RuntimeHelloReply
  requestEndpoint(RuntimeEndpointRequest) ─▶ RuntimeEndpointReply (.granted + endpoint | .rejected)
     wrapper, rejected: requestApproval ─▶ ApprovalReply, then requestEndpoint again
  close the broker connection
  connect the endpoint (exportedInterface = RuntimeEventSink)
  subscribe(…), other operations
```

### 3.2 `hello`

`RuntimeHelloRequest`:

| Field | Type | Meaning |
|---|---|---|
| `clientKind` | `RuntimeClientKind` | §1.3 |
| `claimedIdentity` | String | 1–255 bytes. Selects the listener; grants nothing |
| `apiVersion` | `APIVersion` | the client's version |
| `clientVersion` | String? | for logs; at most 128 bytes |
| `clientBuild` | Int? | for logs; ≥ 0 |

`RuntimeHelloReply`:

| Field | Type | Meaning |
|---|---|---|
| `runtimeVersion` | String | marketing version, for example `1.2.0` |
| `runtimeBuild` | Int | build number |
| `apiVersion` | `APIVersion` | the server's control version |
| `hostState` | String | `starting`, `running`, `degraded`, `shuttingDown`, or `stopped`. The update host state is §3.7 (target) |

- `hello` fails with `runtime.malformedRequest` only for an undecodable body, a bad identity or client version length, or major 0.
- Target: `hello` runs the bundle check, so a client that connects after APKRun was replaced sees `restartPending` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6).
- Deadline: 5 s (§4.6).

### 3.3 `requestEndpoint`

`RuntimeEndpointRequest`:

| Field | Type | Meaning |
|---|---|---|
| `kind` | `RuntimeEndpointKind` | `control` in code. Target: `maintenance`, `wrapper(bundleID:)` |
| `clientKind` | `RuntimeClientKind` | must match the listener |
| `claimedIdentity` | String | must equal this build's identifier for `clientKind`, else `unknownClient` |
| `apiVersion` | `APIVersion` | §2 |
| `selfCdhash` | String? (target) | wrappers; advisory only |

`RuntimeEndpointReply`: `granted` (the `NSXPCListenerEndpoint` travels in the reply argument) or `rejected(RuntimeEndpointRejection)`.

| `RuntimeEndpointRejection` | Meaning |
|---|---|
| `unknownClient` | no listener for the claimed identity |
| `malformedRequest` | over 16 KiB, undecodable, kind not `control`, major 0, or minor above the server's |
| `hostShuttingDown` | apkrund is draining; retry after launchd restarts it |
| `busy` | grant or control limit reached (§4.10) |
| `unknown` | decode-only |

- Pending grants: at most 32, each valid 5 s and bound to one broker connection. A grant does not use the 8 live control slots.
- A rejected control client shows the damaged-app message ([host-ui.md](../02-design/host-ui.md) §3). A rejected wrapper goes to approval (§3.4).
- Deadline: 5 s.

### 3.4 `requestApproval` (broker, target)

Flow: [wrapper.md](../02-design/wrapper.md) §7.3. Request: `bundleURL` (URL), `bundleID` (String), `packageID` (`RuntimePackageID`). Reply `ApprovalReply`: `approved`, `denied(until: Date)` (24 h), `timedOut` (10 min).

| Error | When |
|---|---|
| `wrapper.bundleInvalid` | static check failed: signature, identifier ≠ bundle ID, bundle ID ≠ map(package ID), or `wrapper.json` invalid |
| `runtime.busy` | more than 5 requests in a minute, from all wrappers |

- An unexpired denial for the same cdhash answers `denied` at once. A second request for the same bundle ID joins the pending one.
- The launcher shows screen A while it waits. It maps `denied` and `timedOut` to `wrapper.approvalDenied` and `wrapper.approvalTimedOut`.

### 3.5 Invalidation and interruption

| Event on the endpoint | Meaning | Client action |
|---|---|---|
| `interruptionHandler` | apkrund exited or crashed; launchd restarts it on demand (NFR-REL-02) | reconnect (§3.6) |
| `invalidationHandler` right after `resume()` | requirement failed | wrapper: `cdhashMismatch` → approval. Control: `runtime.notAuthorized` |
| `invalidationHandler` later | apkrund dropped the connection | reconnect |
| no reply within deadline + 5 s | lost request | `runtime.requestTimedOut(operation:)`; invalidate |

On the server, an invalidated connection: is removed from all topics (§16.1); orphans its session for 3 s, after which the close policy applies ([display-and-windowing.md](../02-design/display-and-windowing.md) §7.6); does not cancel its operations (§4.7); releases its `hold` activity; ends its relays and streams (§11.3, §16.4).

### 3.6 Reconnect

RuntimeClient reconnects from the broker step and never replays a request ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.5).

| Failure | Behavior |
|---|---|
| service not registered (`SMAppService.status != .enabled`) | GUI and launchers open APKRun.app with `--register-runtime`. The CLI prints "APKRun's background service is not set up. Open APKRun once, or run: apkrun setup" and exits 69 |
| broker does not answer | `runtime.serviceUnavailable(.notRunning)`; launchers show screen R or S ([wrapper.md](../02-design/wrapper.md) §5.4) |
| apkrund crashed during a session | launcher retries `openSession` after 1, 2, and 4 s, then shows screen E |
| control major mismatch | CLI fails with `runtime.apiVersionMismatch`; APKRun.app asks to restart |
| `runtime.hostUpdating`, or session ended `runtimeUpdating` | launchers show screen U and retry every 2 s for up to 10 min |
| `runtimeBuild` changed | APKRunMenuBar relaunches from the current bundle ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.7) |

After reconnect, the client subscribes again and fetches fresh snapshots. Sequence numbers restart (§16.2).

### 3.7 Update host state (target)

Target `HostState`: `normal`; `updating(targetBuild: Int)`; `restartPending(bundleBuild: Int?)`. It appears in the maintenance status and the `maintenance` topic ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.6). Until it is built, `hello` carries the lifecycle string of §3.2.

| State | Refused with `runtime.hostUpdating` |
|---|---|
| `normal` | — |
| `updating` | everything except the broker, maintenance, `runtimeStatus`, `subscribe`, `unsubscribe`, `cancelOperation`, `listOperations`, `operationStatus`, `healthReport`, `applyHealthFixes`, `createDiagnostics`, `perfStatistics`, `guestLog`. Android never starts |
| `restartPending` | operations that start Android while it is stopped (`openSession`, `launch`, `startRuntime`, `setup`, installs and updates), `createWrapper`, `refreshWrapper`, `buildDistributionWrapper`, `refreshAllWrappers`, and operations that read bundle resources. When idle, apkrund stops Android and exits 0 |

### 3.8 Embedded mode (`apkrun dev`)

`apkrun dev` links RuntimeHost and runs `EmbeddedRuntimeService` in-process ([runtime-daemon.md](../02-design/runtime-daemon.md) §10). It uses the same `RuntimeService` protocol without encoding. `clientKind` is always `cli`, there is no version check, and events arrive as `AsyncStream` values. Its instance is `APKRUN_HOME` (default `…/APKRun-Dev/`). The instance lock refuses a second owner with `runtime.instanceLocked(owner:)` (CLI exit 75). Round-trip tests encode every DTO so the two paths cannot drift. `DeveloperService` (§15) exists only here.

---

## 4. Conventions

### 4.1 Wire shape

```swift
func runtimeStatus(_ request: Data, reply: @escaping (Data) -> Void)
func importPackage(_ request: Data, files: [FileHandle], reply: @escaping (Data) -> Void)
// target: IOSurfaces come back next to the JSON
func openSession(_ request: Data, reply: @escaping (Data, [IOSurface]?) -> Void)
// target: one-way messages
func sendInput(_ batch: Data)
```

- A built control request is a struct with `header: APIRequestHeader` and its own fields. A built reply is a struct with `result` and `error`, of which exactly one is set.
- `APIRequestHeader`: `apiVersion` (`APIVersion`), `operationID` (`UUID`, for log correlation), `clientKind` (`RuntimeClientKind`).
- Built `RuntimeEventSink` (client-exported): `handshake(reply:)` confirms the peer exported the sink; `deliver(_:reply:)` receives a JSON array of `EventEnvelope`, and the reply acknowledges it (§16.2). Target: `sessionEvent`, `frameReady`, `surfacesReplaced`, `streamEvent`.
- One-way messages carry no header. The `@objc` method names equal the operation names.
- `RuntimeService` composes `RuntimePackageService` and `RuntimeSessionService`. Target: one protocol per group of §5–§15. Every method is `async throws(RuntimeWireError)`.

### 4.2 DTO encoding

| Item | Rule |
|---|---|
| Format | JSON, UTF-8. Binary property lists would be a major change |
| Keys | Swift property names, lowerCamelCase. Default key and date strategies |
| Enums without payload | `String` raw value: `"warm"` |
| Enums with payload | one key, the case name: `{"booting": {"_0": "kernel"}}`; labeled payloads use labels; a payload-less case is `{"stopped": {}}` |
| Open enums | unknown case names decode as `.unknown`; `.unknown` is never sent |
| Optional values | omitted when `nil`. Merge patches (§14) use `null` to reset |
| Unknown fields | ignored |
| Dates | built: `JSONEncoder` default numbers, seconds since 2001-01-01T00:00:00Z |
| Durations | target: `Int64` milliseconds, suffix `Ms`. Exceptions: `hostNanos` and `LaunchTiming` (mach time), `presentationTime`, and `WirePerfStatistics` in `Us` (§13.1) |
| Byte counts | `Int64` bytes. Fractions: `Double` 0…1 |
| `CGSize`, `CGPoint` | `{"width", "height"}`, `{"x", "y"}` |
| `Data` | Base64 |
| URLs | absolute file or https URL strings. apkrund never opens a user-chosen path (§4.9) |

### 4.3 Identifiers

| Type | Wire form |
|---|---|
| `RuntimePackageID` | string, Android package grammar, at most 255 characters |
| `RuntimeVersionCode` | `Int64` |
| `RuntimeSHA256Digest` | `"sha256:<64 lowercase hex>"` |
| `OperationID` | lowercase UUID string |
| `RuntimeImportTicket` | UUID string, opaque, store-issued |
| `DisplayID` | lowercase UUID; a pool lease, not the Android display ID |
| `ImageVersion` | `YYYY.MM.seq-base-arm64`, for example `2026.11.3-cf12-arm64`; `base` is `cf<digits>` or `ar<6 digits>` |
| `cdhash` | 40 lowercase hex characters |
| target: `SessionID` | `{"app": "<uuid>"}` or `{"system": <SystemDisplayUse>}` |
| target: `ApprovalID`, `PromptID`, `OfferID`, `StreamID`, `StagingToken` | lowercase UUID |
| target: `SharedFolderID` | `shared` for the built-in folder; otherwise a UUID ([configuration.md](configuration.md) §2.8) |
| target: `RecoveryPointID` | `<timestamp>-<imageVersion>` |
| target: `HealthCheckID` | dotted string, for example `runtime.boot` |

### 4.4 Operation IDs

- The client that starts a user-visible operation creates its `OperationID` and sends it in every request. `apkrun install app.apk --wrap` uses one ID for import, install, and wrapper.
- apkrund creates IDs for work it starts itself and sets `parent` on sub-operations ([diagnostics.md](../02-design/diagnostics.md) §2.4).
- The ID appears in every log line and in every error (`context.operationID`).

### 4.5 Errors

| Type | Shape | Used by |
|---|---|---|
| `RuntimeWireError` | `domain`, `code` (qualified, for example `store.packageNotFound`), `message` (fallback text), `remediation` (String?) | the `error` of control replies, except the five below |
| `RuntimeControlError` | `code`, `message` | `error` of `runtimeStatus`, `startRuntime`, `stopRuntime`, `restartRuntime`, `resetRuntime`, and broker rejections |
| `WireError` | `domain`, `code`, `parameters`, `listItems`?, `cause`?, `underlying`?, `context`? | states and events |

`WireError` parameters (`WireErrorParameter`): `text` (String), `bytes` (Int64), `count` (Int), `durationMs` (Int64), `fileName` (String), `unknown`. `WireErrorListItem` has `selector` (`errorCode(String)` or `variant(code:key:)`) and `parameters`. `listItems` is optional. When it is absent, the client reads the case names in `parameters["items"]`. `ErrorContext` has `operationID`, `packageID`, and `displayID`.

- Codes, messages, and remediations are in [error-catalog.md](error-catalog.md). Codes are never reused ([error-catalog.md](error-catalog.md) §2.2).
- These errors can come from any operation and are not repeated:

| Code | When | Raised by |
|---|---|---|
| `runtime.apiVersionMismatch` | header major not served | server |
| `runtime.malformedRequest` | undecodable, unknown request case, size or count limit exceeded | server |
| `runtime.notAuthorized` | client kind or operation not allowed (§1.4) | server |
| `runtime.busy` | connection or in-flight limit (§4.10) | server |
| `runtime.hostUpdating` | host state refuses (§3.7) | server |
| `runtime.hostShuttingDown` | apkrund is draining or exiting | server |
| `runtime.internal` | unexpected error | server |
| `runtime.serviceUnavailable` | broker or endpoint unreachable (§3.6) | client |
| `runtime.requestTimedOut` | no reply within deadline + 5 s | client |
| `runtime.operationResultUnknown` | a `beginInstallImported` reply was lost and the operation cannot be recovered (§4.6) | client |

`runtime.serviceUnavailable` (reasons `notRegistered`, `requiresApproval`, `notRunning`) and `runtime.requestTimedOut` are `RuntimeFailure` cases that RuntimeClient raises ([runtime-daemon.md](../02-design/runtime-daemon.md) §11). The server never sends them.

### 4.6 Operation kinds and deadlines

| Kind | Meaning | Server deadline |
|---|---|---|
| Q | query, no side effects | 5 s |
| U | update, returns when done | 30 s |
| L | long: returns `OperationHandle` within 5 s, reports on `operations` (§4.7) | handle in 5 s |
| W | waits for a condition | the operation's design timeout |
| S | stream: `StreamHandle`, then `streamEvent` until closed (§16.4) | 5 s for the handle |
| 1 | one-way message | none |

| Operation | Deadline |
|---|---|
| `hello`, `requestEndpoint` | 5 s |
| `requestApproval` | 10 min |
| `startRuntime` | `timeoutMs`, default `runtime.bootTimeoutSeconds` + 30 s (first boot: `firstBootTimeoutSeconds` + 30 s) |
| `restartRuntime` | graceful stop (up to 40 s), then the start deadline. Client cap when unknown: 3675 s (3600 + 30 + 40 + 5) |
| `openSession` | 30 s after `acquiringDisplay`; waits are session states, not the reply |
| `launch` | launcher connects within 20 s |
| `checkSelfUpdate`, `setUpdatePolicy` | 30 s |
| `healthReport` | 15 s quick, 3 min deep |
| `applyHealthFixes` | 3 min |
| `verifyWrapper` | 5 s; 60 s with `deep` |
| `prepareForHostUpdate` | 3 min |
| `restartForUpdate`, `stopRuntime` in `restartPending` | 60 s |

- The client waits the deadline plus 5 s, then fails with `runtime.requestTimedOut(operation:)` and invalidates the connection (§3.5).
- Cancelling the caller's wait on `restartRuntime` returns `runtime.cancelled`. The daemon restart continues; check `runtimeStatus` before a retry.
- `importPackage` is synchronous. `beginInstallImported` returns an `OperationHandle`; the synchronous `installImported` remains for existing clients.
- If the `beginInstallImported` reply is lost, RuntimeClient queries the same operation ID with `operationStatus`. It never resends. If recovery fails, it returns `runtime.operationResultUnknown`; the user checks `apkrun info <package>` before any retry.

### 4.7 Long operations and cancellation

`OperationHandle`: `operationID`, `parent` (`OperationID`?), `kind` (`OperationKind`).

`OperationKind` cases: `import`, `inspect`, `install`, `uninstall`, `repair`, `rollback`, `update`, `updateCheck`, `wrapperCreate`, `wrapperRefresh`, `wrapperRefreshAll`, `distributionWrapper`, `bootstrapImport`, `setup`, `resetAndroid`, `runtimeStop`, `runtimeRestart`, `imageCheck`, `imageDownload`, `imageInstall`, `imageApply`, `imageRollback`, `diagnostics`, `unknown`.

- A repeated request with the same ID and kind returns the same handle. A request whose ID belongs to another kind gets a new ID with `parent` set.
- Progress and results arrive on `operations` (§16.3). A dropped connection cancels nothing. Running and last-50 finished operations are kept in memory only.

Built tracking operations (control):

| Operation | Request → Reply | Clients | Kind |
|---|---|---|---|
| `cancelOperation` | `RuntimeCancelOperationControlRequest` (`operationID`) → `RuntimeCancelOperationControlReply` (`result`: `CancelReply`) | C (target: W) | U |
| `listOperations` | `RuntimeListOperationsControlRequest` → `RuntimeListOperationsControlReply` (`result`: `[OperationSnapshot]`) | C | Q |
| `operationStatus` | `RuntimeOperationStatusControlRequest` (`operationID`) → `RuntimeOperationStatusControlReply` (`result`: `OperationSnapshot`) | C (target: W) | Q |

`CancelReply`: `cancelling`; `notCancellable(reason: String)` (it continues); `alreadyFinished(OperationResult)`; `unknown`.

`OperationSnapshot`:

| Field | Type | Meaning |
|---|---|---|
| `operationID`, `parent` | `OperationID`, `OperationID`? | |
| `kind` | `OperationKind` | |
| `packageID` | `RuntimePackageID`? | |
| `requestFingerprint` | String? | `sha256:<hex>` of the sorted-keys JSON of the begin request (`RuntimeOperationRequestFingerprint`) |
| `clientKind` | `RuntimeClientKind`? | nil for work apkrund started |
| `startedAt`, `finishedAt` | Date, Date? | |
| `progress` | `OperationProgress`? | |
| `result` | `OperationResult`? | nil while running |

`operationStatus` and `cancelOperation` return `runtime.operationNotFound` for an unknown or expired ID.

Cancellation points:

| Kind | Cancellable until | After cancellation |
|---|---|---|
| `import`, `inspect` | any time | incoming files deleted |
| `install` | Store Agent install call starts ([package-store.md](../02-design/package-store.md) §5) | Android and record unchanged; ticket kept |
| `uninstall` | guest uninstall starts | package stays installed |
| `repair` | guest install starts | |
| `rollback`, `imageApply`, `imageRollback`, `runtimeStop` | never | `notCancellable` |
| `resetAndroid` | Android has stopped | nothing deleted |
| `update` | phase `installing` ([update-system.md](../02-design/update-system.md) §5) | download kept |
| `updateCheck`, `imageCheck`, `diagnostics` | any time | diagnostics output truncated to 0 bytes; client deletes the file |
| `imageDownload` | any time | partial file kept |
| `imageInstall` | download and extraction | extracted files deleted |
| `setup` | between steps, not during first boot | resumes next time |
| `wrapperCreate`, `wrapperRefresh`, `distributionWrapper` | until the bundle swap ([wrapper.md](../02-design/wrapper.md) §6) | staging deleted |
| `wrapperRefreshAll` | between wrappers | |
| `bootstrapImport` | as `import`, then as `install` | |
| `runtimeRestart` | before the start | Android stays stopped |

- A cancel during a wait (for example for the app to quit) ends the wait; the result is `cancelled`.

### 4.8 Topics

| Topic | Payload | Subscribers |
|---|---|---|
| `runtime` | `RuntimeChange` | C, L |
| `sessions` | `SessionListChange` (target) | C |
| `packages` | `PackageChange` | C |
| `updates` | `UpdateEvent` (target) | C |
| `operations` | `OperationEvent` | C; W for own operations (target) |
| `health` | `HealthEvent` (target) | C |
| `maintenance` | `MaintenanceEvent` (target) | C |
| `wrappers` | `WrapperChange` (target) | C |
| `integrations` | `IntegrationChange` (target) | C |

API 1.10 publishes `packages.installed` and `packages.updated` after a successful install; `from` is the best pre-install version observed. API 1.11 publishes `packages.removed` after the uninstall commits; `keptData` says whether app data stayed. `uninstall --forget` removes only APKRun's record and publishes no event.

### 4.9 File handles, bookmarks, IOSurfaces

| Object | Direction | Rule |
|---|---|---|
| `FileHandle` | client → apkrund | every user-chosen file: imports, update files, image archives, icons, drops, Save to Mac, diagnostics output. The client opens it. Read handles are read with `pread` from offset 0 and the caller's offset is unchanged. Write handles must be empty regular files ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3) |
| bookmark `Data` | client → apkrund | folders apkrund must reach later: shared folders, wrapper destinations |
| `IOSurface` (target) | apkrund → launcher | three per `SurfaceSet`, only in `openSession` and `surfacesReplaced` ([display-and-windowing.md](../02-design/display-and-windowing.md) §5) |
| `NSXPCListenerEndpoint` | broker → client | `requestEndpoint` reply |

- File handles travel in a `files:` array; the JSON refers to them by `fileIndex`. An index that does not match returns `runtime.malformedRequest`.
- Allowed classes per argument: `NSFileHandle`, `IOSurface`, `NSXPCListenerEndpoint`, `NSData`, `NSArray`. Nothing else is decoded.
- `importPackage` accepts 1–20 handles, each a regular file; `fileIndex` must cover the array exactly once.

### 4.10 Limits

| Limit | Value | Over the limit |
|---|---|---|
| requests in flight per connection | 64 | `runtime.busy` |
| control connections | 8 | new connection invalidated; pending `requestEndpoint` returns `busy` |
| pending control grants | 32, 5 s each, one per broker connection | `busy` |
| broker connections | 32 | invalidated |
| request size, control | 1 MiB | `runtime.malformedRequest` |
| request size, broker | 16 KiB | `malformedRequest` rejection, or `runtime.malformedRequest` for `hello` |
| file handles per request | 20 for imports, 1 otherwise | `runtime.malformedRequest` |
| approval requests (target) | 1 per bundle ID; 5 per minute | joins pending / `runtime.busy` |
| streams per connection (target) | 4 | `runtime.busy` |
| events queued per subscriber | 1024 | `resyncRequired` (§16.2) |
| coalesced events | 10 per second per key and subscriber | older values dropped |
| `sendInput` (target) | 512 per batch; 2000 per second per session | dropped and counted (`input.dropped.rate`) |
| `sendText` (target) | 4 KiB per event; 64 KiB per second per session | dropped and counted |
| clipboard, files, links | [desktop-integration.md](../02-design/desktop-integration.md) §4.4, §6, §7 | `integration.*` errors |
| `updateHistory.limit` (target) | default 50, max 1000 | clamped |
| `packageIcon.sizePx` (target) | 16…1024 | `runtime.malformedRequest` |

Lists are returned whole. A check requested while the same check runs joins it.

### 4.11 Reading the operation tables

- **Request → Reply:** the DTO names; fields are in the tables of the section. **Clients:** §1.4. **Kind:** §4.6.
- **Events:** the topic and case names that the operation or its effects emit. **Design:** the section that defines the behavior.
- Errors per operation follow each group. The common errors of §4.5 are not repeated.

---

## 5. Runtime and status

### 5.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `runtimeStatus` | `RuntimeStatusRequest` → `RuntimeControlReply` (`status`: `RuntimeHostStatus`) | C, L | Q | — | [runtime-daemon.md](../02-design/runtime-daemon.md) §8.1 |
| `runtimeInfo` (target) | `RuntimeInfoRequest` → `RuntimeInfo` | C | Q | — | [cli.md](../02-design/cli.md) §4.1 |
| `startRuntime` | `StartRuntimeRequest` → `RuntimeControlReply` | C | W | `runtime.stateChanged`, `runtime.bootProgress` | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.1–§3.2 |
| `stopRuntime` | `StopRuntimeRequest` → `RuntimeControlReply` | C | W | `runtime.stateChanged`, `sessions.ended` | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.5 |
| `restartRuntime` | `RestartRuntimeRequest` → `RuntimeControlReply` | C | W | — | [cli.md](../02-design/cli.md) §4.1 |
| `resetRuntime` | `RuntimeResetControlRequest` → `RuntimeControlReply` | C | U | `runtime.stateChanged`, `runtime.bootLoopGuardChanged` | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.6 |
| `resetAndroid` (target) | `ResetAndroidRequest` → `OperationHandle` (`resetAndroid`) | C | L | `runtime.*`, `packages.stateChanged`, `operations.*` | [runtime-daemon.md](../02-design/runtime-daemon.md) §9.5 |
| `setup` (target) | `SetupRequest` → `OperationHandle` (`setup`) | C | L | `runtime.provisioningChanged`, `operations.*` | [runtime-daemon.md](../02-design/runtime-daemon.md) §9 |

`resetRuntime` clears a `failed` state and the boot-loop guard and deletes nothing. `resetAndroid` deletes all Android data.

### 5.2 Start, stop, restart, reset

| Request | Built fields | Target fields |
|---|---|---|
| `StartRuntimeRequest` | `header`, `hold` (optional Bool: keep a `cli` activity until the connection closes) | `timeoutMs` (Int64?) |
| `StopRuntimeRequest` | `header` | `force` (Bool: stop even with sessions or activities) |
| `RestartRuntimeRequest`, `RuntimeResetControlRequest` | `header` | — |

- `startRuntime` calls `ensureReady(.cli)` for the CLI and `ensureReady(.user)` for APKRun.app and the menu bar. It returns when the runtime is `ready`, with `RuntimeControlReply.status`. A boot failure returns its error (for example `runtime.bootTimedOut`). Target: it clears the boot-loop guard, and progress arrives on `runtime` (coalesced).
- `stopRuntime` is synchronous and replies with the status after the stop. Target: without `force` it refuses with `runtime.busy(activities:)` while sessions or non-idle activities exist; the client asks, then repeats with `force`. With `force`, sessions end with `runtimeStopped`, and the stop reason is `user`.
- `restartRuntime` stops and starts Android in one request and returns the final status. It emits no progress and returns no handle. Cancelling the caller's wait returns `runtime.cancelled` and does not stop the daemon-side restart.
- `resetRuntime` clears `failed` and the boot-loop guard and returns the status. It is a no-op when neither applies.

### 5.3 Status DTOs

`RuntimeHostStatus` (built):

| Field | Type | Meaning |
|---|---|---|
| `hostState` | String | `starting`, `running`, `degraded`, `shuttingDown`, `stopped` |
| `runtimeState` | String | `stopped`, `booting(<phase>)`, `ready`, `stopping`, `failed` |
| `bootProgress` | Double? | estimate 0 to 0.95 while booting |
| `startupFailureStep` | Int? | failed startup step while degraded |
| `startupFailureCode` | String? | catalog code of that failure |
| `crashLoopActive` | Bool | recent unclean exits activate the boot-loop guard |
| `daemonPID` | Int32 | apkrund's process ID |
| `imageVersion` | String? | installed image version |
| `guestAgentState` | `GuestAgentConnectionState`? | nil if no Guest Agent is observable (1.1) |
| `guestAgentProtocolVersion` | String? | from the latest handshake (1.1) |

`GuestAgentConnectionState`: `notStarted`, `connecting`, `connected`, `reconnecting`, `unresponsive`, `unavailable`, `incompatible`, `unknown`.

Target `RuntimeStatus` replaces `RuntimeHostStatus` for `runtimeStatus`. Fields: `state` (`WireRuntimeState`), `bootProgress`, `owner` (`apkrund` or `apkrunDev`), `hostState` (§3.7), `provisioning` (`WireProvisioningState`), `uptimeMs`, `idle` (`IdleStatus`), `bootLoopGuard`, `imageVersion`, `agents` (`[AgentConnection]`), `developerMode`, `runtimeVersion`, `runtimeBuild`, `lastFailure` (`WireError`?), `lastStopReason`. Target `RuntimeSummary` (wrapper view): `state`, `bootProgress`, `hostState`, `provisioned`, `runtimeVersion`.

`RuntimeInfo` (target): `status`, `sizing` (`cpuCount`, `memoryGiB`, `userdataGiB`), `displayPoolSize`, `resources` (`ResourceUsage`?), `displays` (`[DisplaySlotSnapshot]`?). `RuntimeInfoRequest`: `resources`, `displays` (Bool each). It never starts Android.

### 5.4 Setup, Reset Android, provisioning (target)

`SetupRequest`: `image` (`SetupImageSource`: `archive(fileIndex:)`, `directory(bookmark:)`, `feed`), `recreateInstance` (Bool?: "Start Over" after two failed first boots). `ResetAndroidRequest`: `keepBackup` (Bool, default true: recovery point kept 7 days), `confirmed` (Bool; false returns `runtime.malformedRequest`).

- `setup` runs only incomplete steps. A second call returns the running handle. On a provisioned instance it returns `succeeded` at once.
- `resetAndroid` runs `stop(reset, force)`, creates the recovery point, deletes the instance, provisions again, and marks every managed package `needsReinstall(userdataReset)`.

`WireProvisioningState` (built): `notStarted`, `checkingHost`, `installingImage(fraction:)`, `creatingInstance`, `firstBoot(BootPhase, fraction:)`, `installingAgents`, `verifying`, `complete`, `failed(step: ProvisioningStep, error: WireError)`, `unknown`. `ProvisioningStep`: `checkingHost`, `installingImage`, `creatingInstance`, `firstBoot`, `installingAgents`, `verifying`, `unknown`. A failed host check returns `runtime.hostRequirementsNotMet` with every requirement ([runtime-daemon.md](../02-design/runtime-daemon.md) §9.1).

### 5.5 Errors

| Operation | Errors |
|---|---|
| `startRuntime` | `runtime.notProvisioned`, `runtime.instanceLocked`, `runtime.hostRequirementsNotMet`, `runtime.image`, `runtime.vm`, `runtime.graphics`, `runtime.bootTimedOut`, `runtime.bootStalled`, `runtime.kernelPanic`, `runtime.androidBootFailed`, `runtime.agentIncompatible`, `runtime.requiredAgentUnavailable`, `maintenance.noCompatibleImage` |
| `stopRuntime`, `restartRuntime` | `runtime.busy(activities:)`, `runtime.stopTimedOut`, `runtime.invalidTransition` |
| `resetRuntime` | `runtime.invalidTransition` (while `stopping`) |
| `resetAndroid`, `setup` (target) | `runtime.busy`, `runtime.notProvisioned`, `runtime.hostRequirementsNotMet`, `runtime.instanceLocked`, `image.*`, `maintenance.imageFeedUnreachable` and other feed errors, `maintenance.insufficientSpace` |

---

## 6. Sessions and displays

### 6.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `launch` (built) | `RuntimeLaunchControlRequest` (`packageID`) → `RuntimeLaunchControlReply` (`result`: `RuntimeLaunchResult`) | C | W | `sessions.*` (target) | [runtime-daemon.md](../02-design/runtime-daemon.md) §7.2 |
| `terminate` (built) | `RuntimeTerminateControlRequest` (`packageID`) → `RuntimeTerminateControlReply` (`result`: `RuntimeTerminateResult`) | C | U | `sessions.ended` (target) | [runtime-daemon.md](../02-design/runtime-daemon.md) §7.2 |
| `openSession` (target) | `OpenSessionRequest` → `SessionDescriptor` + `[IOSurface]` | W, L | W | session channel, `sessions.opened` | [runtime-daemon.md](../02-design/runtime-daemon.md) §7.1 |
| `listSessions` (target) | — → `[SessionSummary]` | C | Q | — | [runtime-daemon.md](../02-design/runtime-daemon.md) §8.6 |

APKRun.app and the CLI never open app sessions. They call `launch`, and the launched process opens the session (ADR-0006). Debug builds can use `APKRUN_TEST_HEADLESS_LAUNCH=1` for a daemon-owned headless session until #69 removes it ([configuration.md](configuration.md) §5.1).

- `RuntimeLaunchResult`: `sessionID` (UUID), `packageID`, `state` (`RuntimeSessionPhase`).
- `RuntimeSessionPhase` (built): `starting`, `booting`, `waitingForPackage`, `launching`, `running`, `ended`, `unknown`.
- `RuntimeTerminateResult`: `packageID`, `hadSession` (Bool).
- `launch` opens the registered wrapper when its `WrapperStatus.state` is `valid`, otherwise the generic launcher. A running wrapper is activated. The process must connect within 20 s, or `runtime.launchTimedOut`.
- `terminate` closes the window and force-stops the app through the Guest Agent. Without a session it force-stops only when Android is `ready`. It never starts Android.

### 6.2 `openSession` (target)

`OpenSessionRequest`: `packageID`, `geometry` (`DisplayGeometry`: `pointSize` (CGSize), `backingScale` (1.0 or 2.0), `zoom` (0.75…2.0)), `screenSize` (CGSize, points), `launchTiming` (`processStart`, `requestSent`: UInt64 nanoseconds, optional).

`SessionDescriptor`: `sessionID`, `displayID`, `windowPrefs` (`resizable`, `alwaysOnTop`, `zoom`), `inputPrefs` (§14.2), `windowMode` (`secondaryDisplay` or `primaryDisplayCompatibility`), `state` (`SessionPhase`), `surfaces` (`SurfaceSet`: `generation` UInt32, `surfaceCount` 3, `pixelSize`, `densityDpi`).

Server steps ([runtime-daemon.md](../02-design/runtime-daemon.md) §7.1):

1. Authorize. A wrapper names only its own package.
2. An existing session for the package: the same client gets the descriptor and the window activates. Another client takes over; the old one gets `windowRequest(.close)`. An orphaned session is re-attached.
3. No installed record: `runtime.packageNotInstalled`.
4. A store transaction is running: `waitingForPackage` for up to 30 s, then `store.operationInProgress`.
5. Runtime not `ready`: `booting(BootProgress)`, and `ensureReady`. Accepted in every state except `failed` ([state-machines.md](../01-architecture/state-machines.md) §2).
6. `acquiringDisplay`: the pool allocates a display. The reply is sent here, with surfaces.
7. `launching`, then `running` at the first frame.

While the reply is pending, `stateChanged` arrives at least every 10 s.

`SessionPhase` (target): `starting`, `booting(BootProgress)`, `waitingForPackage`, `launching`, `running`, `ended(SessionEndReason)`, `unknown`. `SessionEndReason`: `userClosed`, `appExited`, `appCrashed`, `runtimeStopped`, `updating`, `runtimeUpdating`, `packageUninstalled`, `error(WireError)`, `unknown`. `closing` and `backgrounded` are not sent.

`SessionSummary` (target): `sessionID`, `packageID`, `displayName`, `state`, `displayID`?, `clientKind` (`wrapper` or `launcher`), `openedAt`, `windowMode`, `recording` (Bool), `pointSize` (CGSize?; for **Use Current Size**, §14.3).

### 6.3 Session channel (target)

The session channel needs no session ID: a connection holds at most one session. Before the reply, or after the session ends, one-way messages are dropped and requests return `runtime.invalidTransition`.

Client → apkrund:

| Message | Shape | Kind | Rule |
|---|---|---|---|
| `frameDisplayed` | `(generation: UInt32, frameSeq: UInt64)` | 1 | from the Core Animation completion block; frees older buffers |
| `visibilityChanged` | `(Bool)` | 1 | `false` → `backgrounded`; presents stop |
| `focusChanged` | `(Bool)` | 1 | key window; `false` also sends `cancelAll` ([input.md](../02-design/input.md) §7.2) |
| `sendInput` | `InputBatch` | 1 | §7 |
| `sendText` | `WireImeTextEvent` | 1 | §7 |
| `resize` | `DisplayGeometry` → `RuntimeEmpty` | U | after live resize, backing-scale or zoom change; new surfaces via `surfacesReplaced` |
| `closeSession` | `CloseSessionRequest` (`policy`: `stop`, `keepRunning`, or nil for `window.closeBehavior`) → `RuntimeEmpty` | U | window closed; session goes to `ended(userClosed)` |
| `pushClipboard` | `ClipItem` → `ClipAck` | U (500 ms) | §11.2 |
| `clipboardWritten` | `ClipboardWritten` | 1 | §11.2 |
| `importFiles` | `ImportFilesRequest` + files → `ImportResult` | W (10 min) | §11.2 |
| `acceptExport` | `AcceptExportRequest` + 0 or 1 file → `RuntimeEmpty` | W (10 min) | §11.2 |
| `resolveLinkPrompt` | `ResolveLinkPromptRequest` → `RuntimeEmpty` | U | §11.2 |
| `restartApp` | `RuntimeEmpty` → `RuntimeEmpty` | U | force-stop and relaunch on the same display ([wrapper.md](../02-design/wrapper.md) §5.6) |
| `frameStatistics` | `RuntimeEmpty` → `SessionGraphicsStatistics` | Q | developer mode only; never starts Android |

apkrund → client (`RuntimeEventSink`): `frameReady(generation, surfaceIndex, frameSeq, presentationTime)` (not JSON; `presentationTime` is `mach_absolute_time`); `surfacesReplaced(SurfaceSet, [IOSurface])`; `sessionEvent(SessionEvent)`.

`SessionEvent`: `stateChanged(SessionPhase)`, `imeStateChanged(EditorState)`, `windowRequest(WindowRequest)` (`activate`, `close`, `setTitle(String)`), `windowPrefsChanged(WindowPrefs)`, `clipboardFromGuest(ClipItem)` (key window only), `exportOffered(ExportOffer)`, `linkPrompt(LinkPrompt)`, `unknown`.

`EditorState`: `focused` (Bool), `inputType`, `imeOptions` (Int32), `selection`, `composing` (`TextRange`?), `cursorRect` (`DisplayRect`? in display pixels).

### 6.4 Frames and generations (target)

- A buffer is free when the client reported `frameDisplayed` for a newer sequence and `IOSurfaceIsInUse` is false.
- No `frameDisplayed` for 1 s while frames are offered means not visible; presents stop until the next `frameDisplayed` or `visibilityChanged(true)`.
- After `surfacesReplaced(generation g+1)`, both sides ignore generation g. The old pool is released after the first `frameDisplayed` of g+1, or after 1 s.
- Sizes resolve in `DisplayGeometryResolver`: at least 320 × 400 dp, 120–640 dpi, at most 4095 px per side, zoom 0.75…2.0. Out-of-range values are clamped, not refused ([display-and-windowing.md](../02-design/display-and-windowing.md) §6).

### 6.5 Errors

| Operation | Errors |
|---|---|
| `openSession` (target) | `runtime.packageNotInstalled`, `store.operationInProgress`, `runtime.bootLoop`, `runtime.notProvisioned`, `runtime.displayPoolExhausted`, `runtime.displayAttachFailed`, `runtime.primaryDisplayBusy`, `runtime.launchTimedOut`, `runtime.launchFailed`, `runtime.guestAgentUnavailable`, and the boot errors of §5.5. Later failures arrive as `ended(error(…))` |
| `launch` | `runtime.packageNotInstalled`, `runtime.launchTimedOut` (for example a damaged wrapper, screen D), `runtime.launchFailed`, `wrapper.launcherTemplateInvalid` |
| `terminate` | `runtime.packageNotInstalled` |
| `resize` (target) | `runtime.displayReconfigureFailed`, `runtime.displayLost` |
| `restartApp` (target) | `runtime.launchFailed`, `runtime.launchTimedOut`, `runtime.guestAgentUnavailable` |
| `frameStatistics` (target) | `runtime.developerModeRequired` |

---

## 7. Input

### 7.1 Messages

| Message | Shape | Clients | Kind | Design |
|---|---|---|---|---|
| `sendInput` | `InputBatch` | W, L (own session) | 1 | [input.md](../02-design/input.md) §2, §7, §8 |
| `sendText` | `WireImeTextEvent` | W, L | 1 | [input.md](../02-design/input.md) §5 |
| `focusChanged` | `(Bool)` | W, L | 1 | §6.3 |

RuntimeAPI carries wire copies of the InputCore types (`InputWireTypes.swift`), because RuntimeAPI cannot import InputCore. `XPCInputSink` in the launcher converts to wire values; RuntimeHost converts back before `InputRouter` ([modules.md](../01-architecture/modules.md) §2, §3).

### 7.2 Wire types

| Type | Definition |
|---|---|
| `InputBatch` | `events: [WireInputEvent]`, 1…512 in order |
| `WireInputEvent` | `touch(WireTouchEvent)`, `mouse(WireMouseEvent)`, `scroll(WireScrollEvent)`, `key(WireKeyEvent)`, `longPress(DisplayPoint, InputTimestamp)`, `cancelAll(InputTimestamp)` |
| `WireTouchEvent` | `phase` (`TouchPhase`: `down`, `move`, `up`, `cancel`), `pointerID` (Int; 0 in v1), `position` (`DisplayPoint`), `time` |
| `WireMouseEvent` | `action` (`MouseAction`: `hoverEnter`, `hoverMove`, `hoverExit`, `press(MouseButton)`, `release(MouseButton)`), `position`, `buttons` (Int32: Android `BUTTON_*` mask), `time` |
| `MouseButton` | `primary`, `secondary`, `tertiary`, `back`, `forward` |
| `WireScrollEvent` | `position`, `vertical`, `horizontal` (Double, `AXIS_*` units), `time` |
| `WireKeyEvent` | `action` (`KeyAction`: `down`, `up`), `androidKeyCode` (Int32), `metaState` (Int32), `repeatCount` (Int32), `time` |
| `WireImeTextEvent` | `commit(String)`, `setComposing(String, selection: TextRange)`, `finishComposing`, `key(WireKeyEvent)`, `editorAction(Int32)`, `contextMenuAction(ContextMenuAction)` (`copy`, `cut`, `paste`, `selectAll`) |
| `InputTimestamp` | `hostNanos` (UInt64, mach continuous time) |
| `DisplayPoint` | `x`, `y` (Double, display pixels) |
| `TextRange` | `start`, `end` (Int, UTF-16 units) |

### 7.3 Rules and limits

- The session comes from the connection. Launchers never send display IDs; `InputRouter` adds the Android display ID of the lease.
- Coordinates use the pixel space of the latest `SurfaceSet` received (§6.3).
- `sendInput` is batched per run-loop turn; `sendText` is sent at once. Both keep order.
- Events are accepted only while the session is `running` or `backgrounded`.
- Per session: 2000 events and 64 KiB of text per second. `sendText` is at most 4 KiB. A batch over 512 events is cut at 512.
- `focusChanged(false)` sends `cancelAll`, so no key or gesture stays pressed.
- Dropped events get no reply. They are counted: `input.dropped.rate`, `input.dropped.notRunning`, `input.dropped.invalid`, `input.coalesced` ([input.md](../02-design/input.md) §11).

---

## 8. Packages and store

Store semantics: [package-store.md](../02-design/package-store.md) §11. A wrapper gets `packageInfo` and `packageIcon` for its own package only; the launcher gets both for any package.

### 8.1 Operations

| Operation | Request → Reply | Clients | Kind | Events | Design |
|---|---|---|---|---|---|
| `importPackage` (built) | `RuntimeImportPackageControlRequest` + files → `RuntimeImportPackageControlReply` (`result`: `RuntimeImportPreview`) | C | synchronous | — | [package-store.md](../02-design/package-store.md) §4 |
| `installImported` (built) | `RuntimeInstallImportedControlRequest` → `RuntimeInstallImportedControlReply` (`result`: `RuntimePackageSummary`) | C | synchronous | `packages.installed`, `packages.updated` | [package-store.md](../02-design/package-store.md) §6.2 |
| `beginInstallImported` (built) | `RuntimeBeginInstallImportedControlRequest` → `RuntimeBeginInstallImportedControlReply` (`result`: `OperationHandle`) | C | L | `operations.*` | [package-store.md](../02-design/package-store.md) §6.2 |
| `beginUninstallPackage` (built) | `RuntimeBeginUninstallPackageControlRequest` (`RuntimeUninstallPackageRequest`) → `RuntimeBeginUninstallPackageControlReply` (`result`: `OperationHandle`) | C | L | `operations.*`, `packages.removed`, `sessions.ended(packageUninstalled)` (target) | [package-store.md](../02-design/package-store.md) §8 |
| `listPackages` (built) | `RuntimeListPackagesControlRequest` (`filter`) → `RuntimeListPackagesControlReply` (`result`: `RuntimePackageListResult`) | C | Q | — | [package-store.md](../02-design/package-store.md) §9 |
| `packageInfo` (built) | `RuntimePackageInfoControlRequest` (`packageID`) → `RuntimePackageInfoControlReply` (`result`: `RuntimePackageDetails`) | C, L | Q | — | [package-store.md](../02-design/package-store.md) §11.1 |
| `inspectFile` (target) | `ImportPackageRequest` + files → `OperationHandle` (`inspect`) | C | L | `operations.*` | [package-store.md](../02-design/package-store.md) §4.3 |
| `cancelImport` (target) | `CancelImportRequest` (`ticket`) → `RuntimeEmpty` | C | U | — | [package-store.md](../02-design/package-store.md) §11.1 |
| `packageIcon` (target) | `PackageIconRequest` (`packageID`, `sizePx`) → `PackageIcon` | C, L, W | Q | `packages.iconChanged` | [package-store.md](../02-design/package-store.md) §10 |
| `repairPackage` (target) | `RuntimePackageRequest` → `OperationHandle` (`repair`) | C | L | `packages.stateChanged` | [package-store.md](../02-design/package-store.md) §11.1 |
| `rollbackPackage` (target) | `RollbackPackageRequest` (`packageID`, `allowDataLoss`) → `OperationHandle` (`rollback`) | C | L | `packages.rolledBack`, `updates.phaseChanged` | [package-store.md](../02-design/package-store.md) §7.3, [update-system.md](../02-design/update-system.md) §8.5 |
| `adoptPackage` (target) | `RuntimePackageRequest` → `RuntimePackageSummary` | C | U | `packages.installed`, `packages.unmanagedChanged` | [package-store.md](../02-design/package-store.md) §9.3 |
| `updatePackageSettings` (target) | §14 | C | U | `packages.settingsChanged` | [package-store.md](../02-design/package-store.md) §2.4 |

The Swift `RuntimePackageService.uninstallPackage` is the operation the daemon tracks as `beginUninstallPackage`. `rollbackPackage` is documented once here; [update-system.md](../02-design/update-system.md) §11.1 names it too.

### 8.2 Import and install

`RuntimeImportPackageRequest`: `files` (`[RuntimeImportSourceFile]`, 1…20), `origin` (`RuntimeImportOrigin`: `addFlow`, `document`, `dropOnHome`, `cli`, `wrap`).

`RuntimeImportSourceFile`: `fileIndex` (Int, into `files:`), `name` (basename only).

`RuntimeImportPreview`:

| Field | Type | Meaning |
|---|---|---|
| `ticket` | `RuntimeImportTicket` | for the install |
| `packageID` | `RuntimePackageID` | |
| `displayName` | String | |
| `versionCode` | `RuntimeVersionCode` | |
| `versionName` | String? | |
| `signerDigests` | `[RuntimeSHA256Digest]` | the current inspector reports none and `signingNotChecked` |
| `files` | `[RuntimeArtifactFile]` | `name`, `splitName`?, `size` (Int64), `sha256` |
| `excludedSplits` | `[String]` | |
| `relation` | `RuntimeImportRelation` | below |
| `warnings` | `[RuntimeImportWarning]` | `missingHardwareFeature(feature:)`, `certificateOnlyVerification`, `signingNotChecked`, `debuggable`, `lowTargetSDK(target:)` |

`RuntimeImportRelation`: `newPackage`, `sameAsInstalled`, `reinstallSameVersion`, `update(from:)`, `downgrade(from:)`, `otherSigner`, `uninstalledWithData(versionCode)`, `unknown`.

`RuntimeInstallImportedRequest`: `ticket`, `options` (`RuntimeInstallOptions`).

`RuntimeInstallOptions`:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `authority` | `RuntimeUpdateAuthority` | `manual` | `apkrun`, `googlePlay`, `external`, `manual` |
| `createWrapper` | Bool | `false` | create the Mac app after install; a failure sets `wrapperError` (target) |
| `allowDowngrade` | Bool | `false` | kept for compatibility, ignored; lower versions are always refused |
| `provider` | `ProviderSpec`? (target) | — | implies authority `apkrun` |
| `updateChoice` | `UpdateChoice`? (target) | — | `automatic` or `notifyOnly` |

- Import returns the preview directly. Target: the preview also carries the icon (PNG) and the compatibility entry ([package-store.md](../02-design/package-store.md) §4.7).
- `apkrun install` sends `authority: manual`. `--yes` skips only the confirmation prompt, not identity, signer, version, ABI, SDK, split, or hash checks.
- An active app session of the package returns `store.packageInUse`.
- By relation: `newPackage` and `reinstallSameVersion` install; `uninstalledWithData` installs and keeps data; `sameAsInstalled` reinstalls the staged set (the guest bytes cannot be confirmed); `update` goes to UpdateCore as a manual update (target); `downgrade` returns `store.downgradeRefused` even if `allowDowngrade` is set; `otherSigner` returns `store.signerMismatch`.
- A ticket is valid 60 minutes and until apkrund exits; later use returns `store.importExpired`.
- A tracked install returns a `RuntimePackageSummary`, a typed error, or `cancelled` before PackageStore starts the guest operation. Success publishes `packages.installed` or `packages.updated`.

### 8.3 Queries

`RuntimePackageListResult`: `packages` (`[RuntimePackageSummary]`), `source` (`RuntimePackageListSource`: `managedRecords`, `liveAndroid`, `cachedAndroid`, `noAndroidInventory`), `observedAt` (Date?).

`RuntimeListPackagesRequest.filter`: `managed` (default) or `all`.

`RuntimePackageSummary`:

| Field | Type | Meaning |
|---|---|---|
| `packageID` | `RuntimePackageID` | |
| `displayName` | String | |
| `versionCode`, `versionName` | `RuntimeVersionCode`?, String? | nil when the record is unreadable |
| `state` | `RuntimePackageState` | `installing`, `installed`, `uninstalling`, `uninstalledKeepingData`, `broken(reason: String)`, `unknown` |
| `managed` | Bool | false: installed in Android by something else |
| `updateAuthority` | `RuntimeUpdateAuthority` | |

`RuntimePackageDetails`: `summary`, `files` (`[RuntimeArtifactFile]`; empty when unmanaged), `artifactBytes` (Int64; 0 when unmanaged), `androidDataBytes` (Int64?, last known).

Target `PackageDetails` adds `record`, `settings` (`ResolvedPackageSettings`, §14.2), `slots`, `sizes`, `wrapperCount`, `lastOperation`, `skippedVersions`, and `compatibility` (`level`, `label`, `issues`, `recommendedKeys`; [diagnostics.md](../02-design/diagnostics.md) §10.3). `PackageIcon` (target): `png`, `digest`, `source` (`rendered`, `hostPreview`, `placeholder`).

- Both queries work while Android is stopped. A `managedRecords` record marked `installed` but missing from a full inventory is listed as `broken("removedInAndroid")`; the query does not write it.
- `listPackages(all)` never starts Android. A live query or any install or uninstall refreshes the saved inventory.
- A wrapper's `packageInfo` is limited to its own package. The launcher cannot list packages.

### 8.4 Uninstall, repair, rollback, adopt

`RuntimeUninstallOptions`: `keepData` (Bool, false), `trashWrappers` (Bool, true; `--keep-wrapper` sets false), `forget` (Bool, false: remove APKRun's record without Android). `RuntimeUninstallPackageRequest`: `packageID`, `options`.

Target `RollbackPackageRequest` (`packageID`, `allowDataLoss`): with `false`, fails with `store.rollbackUnavailable` when only the data-loss fallback remains.

- An open session of the package ends with `packageUninstalled` before the guest uninstall.
- `repairPackage` applies only to `broken` packages.

### 8.5 Errors

| Operation | Errors |
|---|---|
| `importPackage`, `inspectFile` | the `StoreFailure` import cases ([package-store.md](../02-design/package-store.md) §12), for example `store.unsupportedContainer`, `store.insufficientHostSpace`. More than 20 files is `runtime.malformedRequest` |
| `installImported`, `beginInstallImported` | `store.importExpired`, `store.alreadyInstalled`, `store.downgradeRefused`, `store.signerMismatch`, `store.packageInUse`, `store.operationInProgress`, `store.guestInstallFailed`, `store.guestStorageFull`, `store.userActionRequired`, `store.runtimeUnavailable`, `store.capabilityMissing`, `update.*` |
| `listPackages`, `packageInfo` | `store.packageNotFound`, `store.metadataUnreadable`, `store.androidInventoryUnreadable` |
| `beginUninstallPackage` | `store.packageNotFound`, `store.operationInProgress`, `store.uninstallFailed`, `store.runtimeUnavailable` |
| `repairPackage`, `rollbackPackage`, `adoptPackage` (target) | `store.packageNotFound`, `store.guestInstallFailed`, `store.rollbackUnavailable`, `store.rollbackFailed`, `store.packageInUse`, `store.operationInProgress` |
| all store operations | `store.journalUnreadable`, `store.storeReadOnly` |

---

## 9. Updates

Update semantics: [update-system.md](../02-design/update-system.md). All of §9 is control only and target. Wrappers get nothing from UpdateCore ([update-system.md](../02-design/update-system.md) §11.1).

### 9.1 Operations

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `checkForUpdates` | `CheckForUpdatesRequest` → `OperationHandle` (`updateCheck`) → `[UpdateCheckResult]` | C | L | `updates.phaseChanged`, `updates.summaryChanged` |
| `listUpdates` | — → `[PackageUpdateStatus]` | C | Q | — |
| `updatePackage` | `UpdatePackageRequest` → `OperationHandle` (`update`) → `UpdateOutcome` | C | L | `updates.*`, `packages.updated`, `sessions.ended(updating)` |
| `setUpdatePolicy` | `SetUpdatePolicyRequest` → `PackageUpdateStatus` | C | U (30 s) | `packages.settingsChanged`, `packages.stateChanged` |
| `setUpdateAuthority` | `SetUpdateAuthorityRequest` → `PackageUpdateStatus` | C | U | `packages.settingsChanged`, `packages.stateChanged` |
| `skipVersion` / `unskipVersion` | `SkipVersionRequest` (`packageID`, `versionCode`) → `RuntimeEmpty` | C | U | `updates.phaseChanged(completed(skipped(userSkipped)))` |
| `updateHistory` | `UpdateHistoryRequest` → `[UpdateHistoryEntry]` | C | Q | — |

Design: [update-system.md](../02-design/update-system.md) §3, §2.3, §7.3, §8.4, §10.2, §11.1.

### 9.2 DTOs

`CheckForUpdatesRequest`: `packages` ([RuntimePackageID]?, nil = every `apkrun` package), `checkOnly` (Bool, default false; true reports only).

- With `checkOnly = false`, each package follows its update choice ([update-system.md](../02-design/update-system.md) §5). `automatic` can end `installed` or `waiting`; `notifyOnly` and `manual` stop at `available`.

`UpdateCheckResult`: `packageID`, `outcome` (`upToDate`, `available(WireUpdateCandidate)`, `installed(from:to:)`, `waiting(WaitingReason)`, `failed(WireError)`).

`PackageUpdateStatus`: `packageID`, `choice` (`UpdateChoice`?: `automatic`, `notifyOnly`, `manual`; nil for googlePlay and external), `authority`, `provider` (`ProviderSummary`?), `phase` (`WireUpdatePhase`?), `candidate` (`WireUpdateCandidate`?), `lastCheckAt`, `nextCheckAt` (Date?), `consecutiveFailures` (Int), `waiting` (`[WaitingReason]`: false gates GU1…GU7, [update-system.md](../02-design/update-system.md) §7.1).

`ProviderSummary`: `type` (`local`, `direct`, `fdroid`, `github`), `label` (folder, host, or `owner/name`), `channel` (github: `stable` or `prerelease`), `hasToken` (Bool). The token is never returned.

`WireUpdatePhase`: `checking`, `available(WireUpdateCandidate)`, `downloading(progress: Double)`, `validating`, `staged`, `installing`, `healthChecking`, `rollingBack(RollbackReason)` (`healthCheckFailed(WireError)`, `userRequested`), `completed(UpdateOutcome)`, `unknown`.

`UpdateOutcome`: `updated(from:to:)`, `rolledBack(reason:)`, `keptAfterFailedHealthCheck(reason:)`, `skipped(SkipReason)` (`upToDate`, `checkFailed`, `downloadFailed`, `validationFailed`, `installFailed` (each with `WireError`), `userSkipped`, `authorityChanged`).

`WireUpdateCandidate`: `versionCode` (`RuntimeVersionCode`?), `versionName`, `provider` (`ProviderType`), `releaseNotes` (plain text, at most 16 KiB), `publishedAt`, `downloadBytes`.

`UpdatePackageRequest`: `packageID`, `options` (`UpdateNowOptions`: `closeRunningApp` (Bool; true ends the session with `updating` and reopens it; false waits for quit), `files` ([RuntimeImportSourceFile]?; `apkrun update --file`)).

`SetUpdatePolicyRequest`: `packageID`, `policy` (`UpdatePolicy`: `choice` (`UpdateChoice`), `provider` (`ProviderChange`: `keep`, `set(ProviderSpec)`, `remove`)).

`SetUpdateAuthorityRequest`: `packageID`, `authority` (`AuthorityChoice`: `apkrun`, `manual`, `external`; only #98 sets `googlePlay`).

`ProviderSpec`: `spec` (`local:<path>`, `direct:<https-url>`, `fdroid[:<url>#<fingerprint>]`, `github:<owner>/<name>[:<glob>][@prerelease]`), `bookmark` (Data?; required for local), `token` (String?; github only, stored in the Keychain under `io.apkrun.provider.github`, never returned).

`UpdateHistoryRequest`: `packageID` (nil = all), `limit` (default 50, max 1000). `UpdateHistoryEntry`: `time`, `packageID`, `from`, `to`, `provider`, `trigger` (`scheduled`, `userInitiated`, `manual`, `launchOpportunistic`), `outcome`, `failure` (`WireError`?), `phaseDurationsMs`.

- The CLI maps `--update auto|notify|manual` and `--update-provider direct --update-url <url>` before calling UpdateCore ([update-system.md](../02-design/update-system.md) §11.3).
- `setUpdatePolicy` validates the provider with one test request for F-Droid and GitHub. A failure writes nothing.
- A request without `token` keeps the stored token for the same repository; `""` deletes it. Tokens are never logged or written to `settings.json` ([update-system.md](../02-design/update-system.md) §4.6).
- `automatic` and `notifyOnly` need a provider. Without one: `update.providerNotConfigured`.
- `setUpdateAuthority` to `external` calls `RelinquishUpdateOwnership` first ([package-store.md](../02-design/package-store.md) §6.3). It never starts Android.

### 9.3 Errors

| Operation | Errors |
|---|---|
| `checkForUpdates` (per package) | `update.providerUnreachable`, `update.providerHTTPStatus`, `update.providerRateLimited`, `update.providerMetadataInvalid`, `update.providerSignatureInvalid`, `update.noCompatibleArtifact`, `update.ambiguousAsset` |
| `updatePackage` | the above, plus `update.downloadFailed`, `update.hashMismatch`, `update.tooLarge`, `update.validation`, `update.authorityDoesNotAllowUpdates`, `update.installFailed`, `update.healthCheckFailed`, `update.rollbackFailed`, `update.cancelled` |
| `setUpdatePolicy`, `setUpdateAuthority` | `update.providerNotConfigured`, `update.providerUnreachable`, `update.providerMetadataInvalid`, `update.authorityDoesNotAllowUpdates`, `store.packageNotFound` |
| `skipVersion`, `unskipVersion`, `updateHistory` | `store.packageNotFound` |

---

## 10. Wrappers

Semantics: [wrapper.md](../02-design/wrapper.md). All of §10 is target except as noted. Generation, refresh, removal, verification, and approval are control operations.

### 10.1 Wrapper endpoint

A wrapper's launcher calls exactly these operations, and only for its own package:

| Endpoint | Operation | Section |
|---|---|---|
| broker | `hello`, `requestEndpoint`, `requestApproval` | §3.2–§3.4 |
| wrapper | `runtimeStatus` (`RuntimeSummary`), `openSession` and the session channel | §5.3, §6.2–§6.3 |
| wrapper | `packageInfo`, `packageIcon` | §8.3 |
| wrapper | `importBootstrap` | §10.7 |
| wrapper | `notificationRelay` (stream), `notificationRelayResponse` | §11.3 |
| wrapper | `subscribe`, `unsubscribe` (topic `operations`, own operations) | §16.1 |
| wrapper | `cancelOperation`, `operationStatus` (own operations), `closeStream` | §4.7, §16.4 |

The wrapper endpoint serves major N and N−1 (§2.4). Removing an operation from this list is a major change.

### 10.2 Operations

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `createWrapper` | `WrapperRequest` (+ 0 or 1 icon file) → `OperationHandle` (`wrapperCreate`) → `WrapperInfo` | C | L | `wrappers.created`, `operations.*` |
| `placeStagedWrapper` | `PlaceStagedWrapperRequest` → `WrapperInfo` | C | U | `wrappers.created` or `.refreshed` |
| `listWrappers` | — → `[WrapperSummary]` (cached 60 s) | C | Q | `wrappers.statusChanged` |
| `wrapperInfo` | `RuntimePackageRequest` → `WrapperInfo` | C | Q | — |
| `refreshWrapper` | `RefreshWrapperRequest` (+ 0 or 1 icon file) → `OperationHandle` (`wrapperRefresh`) → `WrapperInfo` | C | L | `wrappers.refreshed`, `operations.*` |
| `refreshAllWrappers` | `RefreshAllWrappersRequest` → `OperationHandle` (`wrapperRefreshAll`) → `WrapperBatchResult` | C | L | `wrappers.refreshed` per wrapper |
| `removeWrapper` | `RemoveWrapperRequest` → `RuntimeEmpty` | C | U | `wrappers.removed` |
| `verifyWrapper` | `VerifyWrapperRequest` → `WrapperVerification` | C | Q (5 s; 60 s deep) | `wrappers.statusChanged` |
| `approveWrapper` | `ApproveWrapperRequest` → `WrapperSummary` | C | U | `wrappers.created` |
| `pendingApprovals` | — → `[ApprovalPrompt]` | A | Q | — |
| `decideApproval` | `DecideApprovalRequest` → `RuntimeEmpty` | A | U | `wrappers.approvalResolved`, `wrappers.created` on allow |
| `deniedWrappers` | — → `[DeniedWrapper]` | C | Q | — |
| `clearWrapperDenial` | `ClearWrapperDenialRequest` → `RuntimeEmpty` | C | U | — |
| `rescanWrappers` | `RescanWrappersRequest` → `RescanResult` | C | U | `wrappers.created` |
| `buildDistributionWrapper` | `DistributionWrapperRequest` (+ 0 or 1 icon) → `OperationHandle` (`distributionWrapper`) → `DistributionWrapperResult` | C | L | `operations.*` (M12) |
| `importBootstrap` | `ImportBootstrapRequest` + files → `OperationHandle` (`bootstrapImport`) → `RuntimePackageSummary` | W | L | `operations.*` (own), `packages.installed` |

- `pendingApprovals` lets APKRun.app show a prompt requested before it connected. `rescanWrappers` with `register = false` only lists candidates.

### 10.3 Generation and placement

`WrapperRequest`:

| Field | Type | Meaning |
|---|---|---|
| `packageID` | `RuntimePackageID` | |
| `destination` | `WireWrapperDestination`? | nil = `wrappers.defaultLocation`; `ask` there means `userApplications` |
| `fileName` | String? | overrides the rule of [wrapper.md](../02-design/wrapper.md) §4.3 |
| `displayName` | String? | nil = the package's name |
| `icon` | `WrapperIconChoice`? | nil = Android icon |
| `portable` | Bool | |
| `replace` | `WireReplacePolicy` | `never` or `sameWrapper` |
| `importTicket` | `RuntimeImportTicket`? | portable wrapper of an uninstalled package |
| `windowDefaults` | `WrapperWindowDefaults`? | `defaultWidth`, `defaultHeight` (Int?), `resizable` (Bool?) |
| `updateDefaults` | `WrapperUpdateDefaults`? | `authority`, `choice`, `provider` (a token is refused); only with `importTicket` |

`WireWrapperDestination`: `userApplications` (`~/Applications`), `applications` (`/Applications`, admin only), `directory(URL)`. `WrapperIconChoice`: `android`, `custom(fileIndex:)` (PNG, square, at least 512 px). `PlaceStagedWrapperRequest`: `stagingToken`, `finalURL` (URL), `bookmark` (Data).

- The reply follows step 13 of [wrapper.md](../02-design/wrapper.md) §6.2. `registrationFailed` is a warning in `warnings`, not an error.
- `replace = sameWrapper` refreshes the wrapper at that location ([wrapper.md](../02-design/wrapper.md) §6.4). A `signatureInvalid` wrapper is moved to the Trash and generated again.
- `updateDefaults` on an installed package returns `runtime.malformedRequest`. Use `apkrun update policy`.
- An `importTicket` must come from a `newPackage` preview of the same package. It is not consumed.

**Access denied.** When apkrund cannot write to the destination, the operation fails with `wrapper.destinationNotAccessible(URL, stagingToken)`, plus a `stagedPath` parameter inside `~/Library/Application Support/APKRun/Wrappers/staging/<stagingToken>/`. The client moves the bundle and calls `placeStagedWrapper`; apkrund finishes steps 12 and 13 of [wrapper.md](../02-design/wrapper.md) §6.2. Staging tokens last 60 minutes and until apkrund exits; later use returns `wrapper.stagingExpired`. `placeStagedWrapper` checks the staged cdhash and otherwise returns `wrapper.verificationFailed`.

### 10.4 Status, list, verification

`WrapperSummary`: `packageID`, `bundleID`, `displayName`, `kind` (`WrapperKindTag`: `local`, `portable`, `distribution`), `bundleURL` (registry path), `status` (`WrapperStatus`), `approval` (`WrapperApproval`: `generated`, `user`), `launcherVersion`, `createdAt`, `refreshedAt`. Types are those of [wrapper.md](../02-design/wrapper.md) §9.1.

`WrapperInfo`: `summary`, `fileName`, `customization` (`displayName`?, `customIcon`), `signer` (`WrapperSigner`: `adHoc`, `developerID(teamID:teamName:notarized:)`, `unknown`), `cdhash`, `launcherAPI` (`APIVersion`), `formatVersion`, `iconDigest`, `lastValidatedAt`, `warnings` (`[WireError]`).

`VerifyWrapperRequest`: `bundleURL`, `deep` (Bool; adds strict all-architecture check). `WrapperVerification`: `bundleURL`, `bundleID`?, `packageID`?, `kind`?, `registered` (Bool), `state` (`WrapperState`?; `moved(URL)` appears once), `problems` (`[BundleProblem]`, [wrapper.md](../02-design/wrapper.md) §13), `signer`?, `cdhash`?, `launcherVersion`?, `launcherAPI`?, `bundledVersion`?.

- `verifyWrapper` fails only when the bundle is not an APKRun wrapper (`wrapper.bundleInvalid`).

### 10.5 Refresh and removal

`RefreshWrapperRequest`: `packageID`, `change` (`WrapperRefresh`: `displayName` (String?; `""` resets), `icon`?, `launcherOnly` (Bool), `makeLocal` (Bool; [wrapper.md](../02-design/wrapper.md) §10.2), `closeRunningApp` (Bool; false fails a running wrapper with `wrapper.wrapperRunning`)).

`RefreshAllWrappersRequest`: `scope` (`needingRefresh` or `all`), `launcherOnly`. `WrapperBatchResult`: `refreshed`, `skippedRunning` ([RuntimePackageID]), `failed` (`packageID`, `error`).

`RemoveWrapperRequest`: `packageID`, `options` (`trash` Bool; false = **Remove from List**).

- `closeRunningApp = true` answers "Quit ‹App› to update its Mac app?". apkrund sends `windowRequest(.close)` and waits 30 s; if the session does not end, the operation fails with `wrapper.wrapperRunning`.
- If macOS App Management blocks the swap, the refresh fails with `wrapper.refreshBlocked(path, stagingToken:)`. APKRun.app then swaps `Contents` and calls `placeStagedWrapper`. This exists only if #77 finds the block (R-20); otherwise `stagingToken` is removed.
- `removeWrapper` never deletes; with `trash = true` the bundle goes to the Trash.

### 10.6 Approval (control side)

`ApprovalPrompt`: `approvalID`, `kind` (`wrapper` or `bootstrapInstall(RuntimeImportPreview)`), `bundleURL`, `bundleID`, `packageID`, `displayName`, `signer`, `packageInstalled` (Bool), `installedVersion`, `bundledVersion` (String?), `replacesURL` (URL?), `integrations` (`[IntegrationKind: WireIntegrationDecision]`, capped by this Mac's defaults, [configuration.md](configuration.md) §3.3), `icon` (PNG ≤ 256 px, Data?), `requestedAt`, `expiresAt` (10 min).

`DecideApprovalRequest`: `approvalID`, `allow`. `ApproveWrapperRequest`: `bundleURL`. `DeniedWrapper`: `bundleID`, `packageID`?, `cdhash`, `until`. `ClearWrapperDenialRequest`: `bundleID`, `cdhash`. `RescanWrappersRequest`: `register` (Bool). `RescanResult`: `candidates` (`[WrapperVerification]` in `~/Applications` and `/Applications`), `registered` ([RuntimePackageID]).

- The first `decideApproval` wins. Later ones, or ones for expired prompts, return `wrapper.approvalNotFound`.
- `approveWrapper` runs steps 1–3 and 5 of [wrapper.md](../02-design/wrapper.md) §7.3 without a prompt.

### 10.7 Portable bootstrap

`ImportBootstrapRequest`: `bootstrapJSON` (Data, at most 64 KiB; `Contents/Resources/bootstrap/bootstrap.json`), `files` (1…20, in `bootstrap.json` order).

Server steps ([wrapper.md](../02-design/wrapper.md) §10.2):

1. The wrapper must be approved, the package ID must match the registry, and the package must be uninstalled or `uninstalledKeepingData`. Otherwise `wrapper.bootstrapNotAllowed(notApproved | alreadyInstalled)`.
2. The store copies files and checks each SHA-256 and the set digest. A mismatch returns `wrapper.bootstrapInvalid(hashMismatch | packageMismatch | malformed)`.
3. Preview warnings need confirmation (`wrappers.approvalRequested` with `bootstrapInstall`). **Don't Install** ends with `cancelled`; no answer in 10 min is `wrapper.approvalTimedOut`.
4. apkrund reads `wrapper.json` from the registered bundle, not from the request. `updates` becomes authority, choice, and provider; `window` and `integration` become package settings.
5. The reply is `RuntimePackageSummary`. The launcher then repeats `openSession`.

### 10.8 Distribution (M12, target)

`DistributionWrapperRequest`: `packageID`, `outputDirectory` (URL), `fileName`, `displayName`, `icon`, `identity` (`Developer ID Application: Name (TEAMID)`), `notarize` (Bool), `keychainProfile` (String?; required with `notarize`), `redistributionConfirmed` (Bool; false returns `runtime.malformedRequest`).

`DistributionWrapperResult`: `appURL`, `zipURL`, `bundleID`, `cdhash`, `teamID`, `notarized`, `submissionID`?, `assessment`? (`spctl` output with `notarize`).

- The bundle is not placed or registered. A write failure returns `wrapper.destinationNotAccessible`, and the client places both files. apkrund never stores Apple ID passwords.

### 10.9 Events

`WrapperChange` (topic `wrappers`, [wrapper.md](../02-design/wrapper.md) §12.1): `created(WrapperSummary)`, `refreshed(WrapperSummary)`, `removed(RuntimePackageID)`, `statusChanged(RuntimePackageID, WrapperStatus)` (coalesced per package), `approvalRequested(ApprovalPrompt)`, `approvalResolved(ApprovalID)`, `unknown`.

### 10.10 Errors

| Operation | Errors |
|---|---|
| `createWrapper` | `wrapper.packageNotInstalled`, `wrapper.invalidName`, `wrapper.customIconInvalid`, `wrapper.iconConversionFailed`, `wrapper.launcherTemplateInvalid`, `wrapper.destinationNotWritable`, `wrapper.destinationNotAccessible`, `wrapper.nameConflict`, `wrapper.wrapperExists`, `wrapper.signingFailed`, `wrapper.verificationFailed`, `wrapper.registryUnavailable`, `store.importExpired` |
| `placeStagedWrapper` | `wrapper.stagingExpired`, `wrapper.verificationFailed`, `wrapper.nameConflict`, `wrapper.registryUnavailable` |
| `refreshWrapper` | as `createWrapper`, plus `wrapper.wrapperNotFound`, `wrapper.wrapperRunning`, `wrapper.refreshBlocked` |
| `refreshAllWrappers` | per wrapper in `failed`; the operation fails only with `wrapper.registryUnavailable` or `wrapper.launcherTemplateInvalid` |
| `wrapperInfo`, `removeWrapper`, `clearWrapperDenial` | `wrapper.wrapperNotFound`, `wrapper.registryUnavailable` |
| `verifyWrapper` | `wrapper.bundleInvalid` |
| `approveWrapper` | `wrapper.bundleInvalid`, `wrapper.approvalDenied`, `wrapper.registryUnavailable` |
| `decideApproval` | `wrapper.approvalNotFound` |
| `importBootstrap` | `wrapper.bootstrapNotAllowed`, `wrapper.bootstrapInvalid`, `wrapper.approvalTimedOut`, and the install errors of §8.5 |
| `buildDistributionWrapper` | as `createWrapper`, plus `wrapper.distributionToolMissing`, `wrapper.identityNotFound`, `wrapper.notarizationFailed` |

---

## 11. Integrations

Semantics: [desktop-integration.md](../02-design/desktop-integration.md). Per-package integration settings change through `updatePackageSettings` (§14). All of §11 is target.

### 11.1 Operations

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `integrationStatus` | `RuntimePackageRequest` → `IntegrationStatus` | C | Q | `integrations.statusChanged` |
| `sharedFolders` | — → `[SharedFolder]` | C | Q | — |
| `addSharedFolder` | `AddSharedFolderRequest` → `SharedFolder` | C | U | `integrations.sharedFoldersChanged`, `runtime.configurationChanged(["sharedFolders.roots"])` |
| `removeSharedFolder` | `SharedFolderRequest` (`id`) → `RuntimeEmpty` | C | U | as `addSharedFolder` |
| `setSharedFolderAccess` | `SetSharedFolderAccessRequest` (`id`, `access`) → `SharedFolder` | C | U | as `addSharedFolder` |
| `activeRecordings` | — → `ActiveRecordings` | C | Q | `integrations.recordingChanged` |
| `notificationRelay` | `NotificationRelayRequest` (`background`) → `StreamHandle` | W | S | stream of `RelayMessage` |
| `notificationRelayResponse` | `RelayResponse` (one-way) | W | 1 | — |
| `hostNotifications` | `HostNotificationsRequest` (`background`) → `StreamHandle` | A | S | stream of `HostNotificationMessage` |
| `hostNotificationResponse` | `HostNotificationResponse` (one-way) | A | 1 | — |

- `IntegrationStatus`: `packageID`, `items` (`IntegrationItemStatus` per kind: `value` (`JSONValue`), `source` (`SettingSource`), `decision` (`WireIntegrationDecision`), `support` (`IntegrationSupport`), `macPermission` (`MacPermissionState`?)), `microphoneNeedsRestart` (Bool).
- `WireIntegrationDecision`: `allow`, `ask` (links), `deny(IntegrationDenial)` (`globallyOff`, `packageOff`, `notFocused`, `noSession`, `notSupported(capability)`, `rateLimited`), `unknown`.
- `IntegrationSupport`: `supported`, `unsupported(capability:)`, `unknown`. `MacPermissionState`: `notDetermined`, `denied`, `restricted`, `authorized`, `provisional`, `ephemeral`, `unknown`.
- `SharedFolder`: `id` (`shared` for the built-in folder), `name`, `path` (display only), `access` (`readOnly` or `readWrite`: maximum), `builtIn` (Bool; not removable), `availability` (`available`, `missing`, `privacyDenied`, `offline`, `unknown`).
- `AddSharedFolderRequest`: `bookmark` (Data), `access` (default `readOnly`). `ActiveRecordings`: `packages`.
- `updateConfiguration` refuses `sharedFolders.roots` (§14). `apkrun shared-folders remove <path|id>` resolves the ID on the client. Removing `shared` returns `runtime.malformedRequest`.

### 11.2 Session DTOs

| Type | Fields |
|---|---|
| `ClipItem` | `text` (String?, UTF-8, at most 1 MiB), `html` (String?, at most 1 MiB, with `text`), `image` (`ClipImage`? target #81), `sensitive` (Bool), `digest` (`RuntimeSHA256Digest`), `truncated` (Bool), `trigger` (`paste` or `focus`, client only) |
| `ClipImage` | `png` (Data, at most 16 MiB), `pixelSize` (`PixelSize`, at most 8192 px) |
| `ClipAck` | `seq` (UInt64) |
| `ClipboardWritten` | `changeCount` (Int), `digest` |
| `ImportFilesRequest` | `files` (`ImportFileInfo`: `fileIndex`, `name`, `size` (Int64), `uti`; 1…20), `target` (`shareToApp`) |
| `ImportResult` | `contentURIs` ([String]), `disposition` (`shared`, `savedToDownloads`) |
| `ExportOffer` | `offerID`, `name` (sanitized, [wrapper.md](../02-design/wrapper.md) §4.3), `size` (Int64?), `type` (MIME) |
| `AcceptExportRequest` | `offerID`, `fileIndex` (Int?; nil = user cancelled) |
| `LinkPrompt` | `promptID`, `host`, `registrableDomain` (bold), `scheme` (`http`, `https`, `mailto`), `signInHint` (Bool), `keepInAndroidAvailable` (Bool), `expiresAt` (60 s) |
| `ResolveLinkPromptRequest` | `promptID`, `choice` (`openOnMac`, `keepInAndroid`, `cancel`), `remember` (Bool; writes `integrations.links`) |

- The link prompt never carries the URL path or query.
- `acceptExport` writes to the handle and replies when the SHA-256 matches; on failure the window deletes the partial file.
- `resolveLinkPrompt` on an expired prompt returns `integration.promptTimedOut`.

### 11.3 Notification streams

Relay (wrappers): `RelayMessage` is `post(NotificationPayload)`, `remove([String])`, `setBadge(Int?)`, `unknown`. `NotificationPayload`: `identifier` (`<package>|<first 16 hex of SHA-256(key)>`), `threadID`, `title`, `body`, `sound`, `interruption` (`passive` or `active`), `actions` (at most 3), `badge`?, `replay` (Bool). `RelayResponse`: `activated(identifier:actionIndex:)`, `dismissed(identifier:)`, `authorizationChanged(MacPermissionState)`, `unknown`. One relay per connection; a second request returns the existing handle. With no relay, apkrund starts the wrapper in background mode and queues up to 50 payloads for 10 s ([desktop-integration.md](../02-design/desktop-integration.md) §5.3).

Host notifications (APKRun.app): `HostNotificationMessage` is `post(HostNotificationPayload)`, `remove([String])`, `unknown`. `HostNotificationPayload`: `identifier`, `kind` (`HostNotificationKind`: `androidApp`, `updateAvailable`, `updated`, `updateWaiting`, `updateRolledBack`, `updateRefused`, `providerProblem`, `runtimeStopped`, `approvalNeeded`, `selfUpdateAvailable`, `imageUpdateReady`, `imageUpdated`, `imageUpdateFailed`, `imageIncompatible`, `unknown`), `packageID`?, `title`, `body` (`WireLocalizedText`), `subtitle`?, `threadID`?, `sound`, `interruption`, `actions` (`updateNow`, `open`, `restart`, `update`, `later`, `reportProblem`, `openAPKRun`, `android(index:title:)`, `unknown`), `targetURL`? (`apkrun://`). `HostNotificationResponse`: `activated(identifier:action:)` (nil action = the notification), `dismissed(identifier:)`, `unknown`.

- Only one host-notification stream is served. A new one replaces the old, and the old stream ends with `replaced`.
- With no stream, apkrund opens APKRun.app with `--notify` and queues up to 50 notifications for 30 s ([update-system.md](../02-design/update-system.md) §9).

### 11.4 Limits

| Item | Limit | Over the limit |
|---|---|---|
| clipboard text | 1 MiB UTF-8 | truncated at a character boundary; `truncated = true` |
| clipboard HTML | 1 MiB | `integration.clipboardTooLarge` |
| clipboard image | 16 MiB; 8192 px | `integration.clipboardTooLarge` |
| drop into an app | 20 files; 2 GiB each; 4 GiB total | `integration.tooManyFiles`, `integration.fileTooLarge` |
| Save to Mac | 20 items per share | rest declined |
| links | 8 KiB per URL; 3 per 10 s per package | dropped and counted |
| link prompt | 60 s | `cancel` |
| notification actions | 3 | extra not shown |
| notification queue (starting wrapper) | 50 per package, 10 s | dropped and counted |
| host notification queue | 50, 30 s | dropped and counted |
| shared folders | 32 added roots | `integration.folderRefused(limitReached)` |
| shared-folder I/O | 4096 entries per page; 1 MiB per read or write; 64 handles per package | guest errors |

### 11.5 Errors

| Operation | Errors |
|---|---|
| `integrationStatus` | `store.packageNotFound` |
| `addSharedFolder` | `integration.folderRefused`, `integration.folderUnavailable` |
| `removeSharedFolder`, `setSharedFolderAccess` | `integration.folderUnavailable` |
| `pushClipboard` | `integration.disabled`, `integration.clipboardTooLarge`, `integration.guestUnavailable`, `integration.notSupportedOnImage` |
| `importFiles` | `integration.disabled`, `integration.tooManyFiles`, `integration.fileTooLarge`, `integration.transferFailed`, `integration.guestUnavailable` |
| `acceptExport` | `integration.transferFailed` |
| `resolveLinkPrompt` | `integration.promptTimedOut` |

Health findings `integration.notificationAccessMissing`, `integration.browserRoleMissing`, and `integration.timeSyncFailed` appear in `healthReport` only.

---

## 12. Maintenance

Semantics: [runtime-maintenance.md](../02-design/runtime-maintenance.md). Covers APKRun's own updates (Sparkle, coordinated with apkrund) and Android image updates. Package updates are §9. All of §12 is target. The maintenance endpoint coordinates host updates; self-update and image operations are on control. Wrappers see only `hostState` and `runtime.hostUpdating` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.2).

### 12.1 Maintenance endpoint (frozen)

`MaintenanceControl` has no major version and accepts additive changes only. It must work with an old apkrund and a new APKRun.app ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.1). The server ignores the header's version.

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `maintenanceStatus` | — → `MaintenanceStatus` | M | Q | — |
| `prepareForHostUpdate` | `HostUpdateRequest` → `RuntimeEmpty` | M | W (3 min) | `maintenance.hostStateChanged(updating)`, `sessions.ended(runtimeUpdating)` |
| `abortHostUpdate` | — → `RuntimeEmpty` | M | U | `maintenance.hostStateChanged(normal)` |
| `completeHostUpdate` | — → `RuntimeEmpty` | M | U | `maintenance.hostStateChanged(normal)` |
| `restartForUpdate` | `RestartForUpdateRequest` → `RuntimeEmpty` | M | W (60 s) | `sessions.ended(runtimeUpdating)`, `runtime.stateChanged` |

- `MaintenanceStatus`: `version`, `build`, `hostState`, `sessions` ([RuntimePackageID]), `backgroundTasks`, `activities` ([ActivityKind]), `imageMigrating` (Bool), `marker` (`HostUpdateMarker`?: `fromVersion`, `fromBuild`, `targetVersion`, `targetBuild`, `createdAt`, `operationID`).
- `HostUpdateRequest`: `targetVersion`, `targetBuild`, `closeSessions` (Bool; false with open sessions returns `maintenance.hostUpdateSessionsOpen`). It replies after Android has stopped and the marker is written; apkrund exits 1 s later.
- `RestartForUpdateRequest`: `closeSessions` (Bool). It acts only in `restartPending`; elsewhere it does nothing.
- `abortHostUpdate` and `completeHostUpdate` are idempotent.

### 12.2 Self-update (control)

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `selfUpdateStatus` | — → `SelfUpdateStatus` | C | Q | `maintenance.selfUpdateStatusChanged` |
| `checkSelfUpdate` | `CheckSelfUpdateRequest` (`userInitiated`) → `SelfUpdateStatus` | C | U (30 s) | `maintenance.selfUpdateStatusChanged` |
| `noteSelfUpdateStatus` | `SelfUpdateNote` → `RuntimeEmpty` | A | U | `maintenance.selfUpdateStatusChanged` |

- `SelfUpdateStatus`: `currentVersion`, `currentBuild`, `latest` (`AvailableRelease`?: `version`, `build`, `channel`?, `minimumSystemVersion`?, `releaseNotesURL`?, `publishedAt`?), `critical` (Bool), `lastCheckedAt`, `lastError` (`WireError`?), `pendingOnQuit` (Bool).
- `SelfUpdateNote` (Sparkle's result): `found` (`AvailableRelease`?), `pendingOnQuit`, `checkedAt`.
- The probe never downloads or installs. `apkrun self-update install` opens `apkrun://settings/general`. A non-user check follows the 24-hour interval.

### 12.3 Android system updates (control)

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `imageUpdateStatus` | — → `ImageUpdateStatus` | C | Q | `maintenance.imageUpdatePhaseChanged` |
| `checkImageUpdate` | — → `OperationHandle` (`imageCheck`) → `ImageUpdateStatus` | C | L | `maintenance.imageUpdatePhaseChanged` |
| `downloadImageUpdate` | — → `OperationHandle` (`imageDownload`) → `ImageUpdateStatus` | C | L | `maintenance.imageUpdateProgress`, `.imageUpdatePhaseChanged` |
| `cancelImageDownload` | — → `RuntimeEmpty` | C | U | `maintenance.imageUpdatePhaseChanged` |
| `applyImageUpdate` | `ApplyImageUpdateRequest` → `OperationHandle` (`imageApply`) → `ImageUpdateStatus` | C | L | `maintenance.*`, `runtime.stateChanged`, `sessions.ended(runtimeUpdating)` |
| `installImage` | `ImageInstallRequest` (+ 0 or 1 file) → `OperationHandle` (`imageInstall`) → `WireImageInfo` | C | L | as download; with `apply`, as apply |
| `rollbackImage` | `RollbackImageRequest` → `OperationHandle` (`imageRollback`) → `WireImageInfo` | C | L | `maintenance.imageUpdateFinished(rolledBack)`, `runtime.*`, `packages.stateChanged` |
| `listImages` | — → `[WireImageInfo]` | C | Q | — |
| `recoveryPoints` | — → `[WireRecoveryPoint]` | C | Q | — |
| `deleteRecoveryPoint` | `RecoveryPointRequest` (`id`) → `RuntimeEmpty` | C | U | — |

- `ImageUpdateStatus`: `phase` (`WireImageUpdatePhase`), `current` (`ImageVersion`?), `requiresNewerAPKRun` (String?), `rejected` (`version`, `at`, `reason`), `lastResult` (`ImageUpdateOutcome`?), `waitingFor` (`ImageApplyCondition`: `a1Ready`, `a2NoActivity`, `a3HostNormal`, `a4UserIdle`, `a5Power`, `a6FreeSpace`, `a7NotRecentlyAttempted`, `unknown`), `installMode` (`automatic` or `ask`), `lastCheckAt`, `nextCheckAt`.
- `WireImageUpdatePhase`: `idle`, `checking`, `available(WireImageCandidate)`, `downloading(WireImageCandidate, DownloadProgress)` (`bytes`, `totalBytes`, `resumed`), `installing(WireImageCandidate, fraction:)`, `ready(ImageVersion)`, `applying(from:to:)`, `failed(WireImageCandidate?, WireError, retryAt: Date?)`, `unknown`.
- `WireImageCandidate`: `version`, `kind` (`apkrun` or `stock`), `publishedAt`, `downloadBytes`, `expandedBytes`, `securityPatchLevel` (for example `2026-09-05`), `critical`, `releaseNotesURL`?.
- `ImageUpdateOutcome`: `installed(ImageVersion)`, `rejected(ImageVersion, WireError)`, `rolledBack(to:)`, `unknown`.
- `ApplyImageUpdateRequest`: `version` (must be the ready image), `closeSessions`, `retryRejected` (false for a rejected version returns `maintenance.imageUpdateRejected`).
- `ImageInstallRequest`: `source` (`file(fileIndex:)` for a signed `.aar`, or `latest`), `apply` (Bool), `closeSessions`, `retryRejected`. Release builds accept only release-key images.
- `RollbackImageRequest`: `confirmed` (Bool; false returns `runtime.malformedRequest`).
- `WireImageInfo`: `version`, `role` (`current`, `previous`, `ready`, `rejected`, `other`), `kind`, `sizeBytes`, `installedAt`?, `securityPatchLevel`?.
- `WireRecoveryPoint`: `id` (`RecoveryPointID`), `imageVersion`, `createdAt`, `reason` (`migration`, `resetAndroid`, `unknown`), `sizeBytes`?, `failed` (Bool).
- `applyImageUpdate` requires gate conditions a1, a3, and a6. With active sessions and `closeSessions = false` it returns `runtime.busy`.
- `cancelImageDownload` keeps the partial file. `rollbackImage` needs the `previous` image and a recovery point, else `maintenance.rollbackUnavailable`. `deleteRecoveryPoint` on an unknown ID returns `image.recoveryPointMissing`. A Reset Android recovery point has no restore operation in v1 (OQ-41).

### 12.4 Events

Topic `maintenance` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §8.3). `MaintenanceEvent`: `hostStateChanged(HostState)`, `selfUpdateStatusChanged(SelfUpdateStatus)`, `imageUpdatePhaseChanged(WireImageUpdatePhase)`, `imageUpdateProgress(OperationID, fraction:, bytes:)` (10 per second), `imageUpdateFinished(ImageUpdateOutcome)`, `unknown`.

### 12.5 Errors

| Operation | Errors |
|---|---|
| `prepareForHostUpdate` | `maintenance.hostUpdateBusy`, `maintenance.hostUpdateSessionsOpen`, `maintenance.selfUpdateNotNewer`, `maintenance.hostUpdateStopFailed` |
| `restartForUpdate` | `maintenance.hostUpdateSessionsOpen`, `maintenance.hostUpdateStopFailed` |
| `checkSelfUpdate` | `maintenance.selfUpdateFeedUnreachable`, `maintenance.selfUpdateFeedInvalid` |
| `checkImageUpdate` | `maintenance.imageFeedUnreachable`, `maintenance.imageFeedHTTPStatus`, `maintenance.imageFeedSignatureInvalid`, `maintenance.imageFeedInvalid`, `maintenance.imageFeedReplayed`, `maintenance.imageFeedExpired`, `maintenance.noCompatibleImage` |
| `downloadImageUpdate` | `maintenance.imageUpdateNotReady`, `maintenance.imageDownloadFailed`, `maintenance.imageArchiveSizeMismatch`, `maintenance.imageArchiveHashMismatch`, `maintenance.insufficientSpace`, `maintenance.cancelled` |
| `applyImageUpdate` | `maintenance.imageUpdateNotReady`, `maintenance.imageUpdateRejected`, `maintenance.insufficientSpace`, `maintenance.imageMigrationFailed`, `runtime.busy` |
| `installImage` | the errors above, plus `maintenance.imageArchiveUnsafeEntry`, `maintenance.imageInstallFailed` |
| `rollbackImage` | `maintenance.rollbackUnavailable`, `image.recoveryPointMissing`, `image.recoveryPointStale` |
| `deleteRecoveryPoint` | `image.recoveryPointMissing` |
| all image operations | `maintenance.dataCreatedByNewerVersion` |

---

## 13. Diagnostics and health

Semantics: [diagnostics.md](../02-design/diagnostics.md). All of §13 is control only and target. A wrapper's **Report a Problem…** opens `apkrun://report?package=<id>` in APKRun.app ([diagnostics.md](../02-design/diagnostics.md) §8.5). These operations are served in every host state and in runtime state `failed`.

### 13.1 Operations

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `healthReport` | `HealthRequest` → `WireHealthReport` | C | W (15 s quick; 3 min deep) | — |
| `applyHealthFixes` | `HealthFixRequest` → `WireHealthReport` | C | W (3 min) | `health.healthChanged` |
| `createDiagnostics` | `DiagnosticsRequest` + 1 write handle → `OperationHandle` (`diagnostics`) → `DiagnosticsResult` | C | L | `operations.*` (stages `collecting`, `redacting`, `writing`) |
| `perfStatistics` | `PerfStatisticsRequest` (`reset`) → `WirePerfStatistics` | C | Q | — |
| `guestLog` | `GuestLogRequest` (`follow`) → `StreamHandle` | C | S | stream of `GuestLogChunk` |

- `HealthRequest`: `deep` (Bool), `checks` ([HealthCheckID]?; nil = all). `HealthFixRequest`: `checks` (empty = every fixable check in warning or failure).
- `WireHealthReport`: `generatedAt`, `build` (`version`, `build`, `commit`?, `channel`), `imageVersion`?, `runtimeRunning` (Bool), `verdict` (`hostUnsupported`, `serviceUnavailable`, `notSetUp`, `graphicsFailure`, `bootFailure`, `agentUnavailable`, `degraded`, `stopped`, `healthy`, `unknown`), `results` (`WireHealthResult`).
- `WireHealthResult`: `id`, `group` (`host`, `backgroundService`, `virtualization`, `android`, `graphics`, `guest`, `store`, `updates`, `applications`, `macApps`, `integrations`, `maintenance`), `state` (`pass`, `info`, `warning`, `failure`, `skipped`), `title` (`WireLocalizedText`), `detail`?, `error`? (warnings and failures), `fixAvailable` (Bool), `lastKnown`? (`state`, `detail`?, `measuredAt`), `measuredAt`.
- `DiagnosticsRequest`: `outputFileIndex` (empty regular file), `includeLogcat` (Bool; still redacted), `deep` (Bool), `focusPackage` (`RuntimePackageID`?). `DiagnosticsResult`: `summary` (String), `sizeBytes` (Int64), `omitted` (`item`, `reason`).
- `GuestLogRequest`: `follow` (Bool; false returns buffered lines, then ends). `GuestLogChunk`: `lines` ([String]), `dropped` (Int).
- `healthReport` never starts Android; checks that need a runtime return `skipped` with `lastKnown` ([diagnostics.md](../02-design/diagnostics.md) §7.1).
- `createDiagnostics` produces a result whenever the writer works. A cancel truncates the handle to 0 bytes; the client deletes the file (§4.7).
- `guestLog` needs `developer.enabled`, else `runtime.developerModeRequired`. It never starts Android. Host logs use `apkrun logs --follow` in the CLI, without an operation ([cli.md](../02-design/cli.md) §4.8).

`WirePerfStatistics`: `since` (Date), `markers` (`name`, `count`, `p50Us`, `p95Us`, `maxUs`), `input` (`segment` (`input.translate`, `input.route`), `boundsUs`, `counts`), `sessions` (`SessionGraphicsStatistics`: `packageID`, `displayID`, `fps` (Double, last 10 s), `droppedFrames`, `hostReadbacks` (must stay 0; [AGENTS.md](../../AGENTS.md) §6.4), `cpuPixelCopies`, `presentGPUTimeP50Us`, `presentGPUTimeP95Us`). Values are microseconds with suffix `Us`, an exception to §4.2.

### 13.2 Events

Topic `health`: `healthChanged(WireHealthResult)`, coalesced per check ID; live checks only.

### 13.3 Errors

| Operation | Errors |
|---|---|
| `healthReport` | `diagnostics.unknownHealthCheck` |
| `applyHealthFixes` | `diagnostics.unknownHealthCheck`, `diagnostics.fixNotAvailable`. A failed fix is `diagnostics.fixFailed` in that row's `error` |
| `createDiagnostics` | `diagnostics.stagingFailed`, `diagnostics.bundleWriteFailed`, `runtime.malformedRequest` |
| `guestLog` | `runtime.developerModeRequired` |

---

## 14. Settings

Semantics: [configuration.md](configuration.md) §1.4, §1.5, §3. Global keys live in apkrund's `settings.json`; package keys in each package's `settings.json`. Update policy uses `setUpdatePolicy` (§9); shared-folder roots use §11.1.

### 14.1 Operations

| Operation | Request → Reply | Clients | Kind | Events |
|---|---|---|---|---|
| `configuration` | — → `ConfigurationSnapshot` | C | Q | — |
| `updateConfiguration` | `ConfigurationPatch` → `ConfigurationSnapshot` | C | U | `runtime.configurationChanged(keys)` |
| `packageSettings` | `RuntimePackageRequest` → `ResolvedPackageSettings` | C | Q | — |
| `updatePackageSettings` | `PackageSettingsPatch` → `ResolvedPackageSettings` | C | U | `packages.settingsChanged(id, keys)`, session `windowPrefsChanged` |

A launcher reads its own settings from `packageInfo`, `SessionDescriptor.windowPrefs` and `.inputPrefs`, and `windowPrefsChanged`. It changes only `window.zoom`, through `resize` (§14.3). It cannot read or change other settings ([configuration.md](configuration.md) §1.4).

### 14.2 DTOs

- `ConfigurationSnapshot`: `entries` (`ConfigurationEntry`: `key` (dotted), `value` (`JSONValue`), `defaultValue`, `isSet` (Bool: present in `settings.json`, even when equal to the default), `applies` (`SettingApplies`)).
- `ConfigurationPatch`: `patch` (`JSONValue`, RFC 7396 merge patch on the nested form, [configuration.md](configuration.md) §1.2).
- `PackageSettingsPatch`: `packageID`, `patch` (`JSONValue`, merge patch on package keys, [configuration.md](configuration.md) §3.1).
- `ResolvedPackageSettings`: `packageID`, `entries` (`ResolvedSetting`: `key`, `value`, `source` (`SettingSource`), `defaultValue`, `recommended`? (compatibility database), `applies`), `window` (`WindowSettings`), `input` (`InputPrefs`).
- `SettingSource`: `globalSwitch`, `user`, `recommended`, `default`, `unknown`. `SettingApplies`: `live`, `nextSession`, `runtimeRestart`, `nextCheck`, `nextLogin`, `newPackages`, `provisioning`, `nextBoot`, `nextHealthCheckResult`, `nextUpdate`, `unknown`. For compound values, `applies` is the first.
- `WindowSettings`: `mode` (`secondaryDisplay` or `primaryDisplayCompatibility`), `defaultWidth` (≥ 320), `defaultHeight` (≥ 400), `resizable`, `alwaysOnTop`, `zoom` (0.75…2.0), `closeBehavior` (`stop`, `keepRunning`).
- `InputPrefs`: `escapeKey` (`back`, `escape`), `secondaryClick` (`mouseSecondary`, `longPress`), `scrollMode` (`scroll`, `touchDrag`), `hover` (Bool), `sendCommandKey` (Bool).
- `packageSettings` works for unmanaged packages. Every source is then `globalSwitch` or `default`, and `integrations.notifications` is `false` ([configuration.md](configuration.md) §3.2).

### 14.3 Rules

- `null` resets a key: global keys fall back to the default; package keys fall back to the recommendation, then the default.
- The whole patch is validated before any write. If one key fails, nothing is written, and the reply is the first failing key's error.
- Arrays are replaced whole. An unknown key group is `unknownSetting`.
- A no-op patch is accepted: nothing is written, no event is posted.
- An explicit default value is stored (`isSet = true`, source `user`).
- A patch containing `sharedFolders` returns `runtime.invalidSettingValue` (§11.1 is the only writer). A package patch containing `update.mode` returns `store.invalidSettingValue`; `setUpdatePolicy` is the only writer.
- `updatePackageSettings` on an unmanaged package returns `store.packageNotFound`; the user adopts it first.
- `config reset --all` and `settings reset --all` are built by the client as one patch with `null` for each set key.
- Changes to `window.resizable`, `window.alwaysOnTop`, or `window.zoom` send `windowPrefsChanged` to the open session. Other keys apply at the next session.
- **Zoom.** View → Zoom In, Zoom Out, and Actual Size send `resize` with the new `zoom`. apkrund stores `window.zoom` (source `user`) and posts `packages.settingsChanged(id, ["window.zoom"])`. The sending session gets no `windowPrefsChanged`.
- **Use Current Size** reads `SessionSummary.pointSize` and writes `window.defaultWidth` and `window.defaultHeight` with `updatePackageSettings` ([host-ui.md](../02-design/host-ui.md) §7).

### 14.4 Errors

| Operation | Errors |
|---|---|
| `updateConfiguration` | `runtime.unknownSetting`, `runtime.invalidSettingValue`, `runtime.hostStartupFailed` (read-only while degraded) |
| `packageSettings` | `store.packageNotFound`, `store.metadataUnreadable` |
| `updatePackageSettings` | `store.packageNotFound`, `store.unknownSetting`, `store.invalidSettingValue`, `store.storeReadOnly`, `runtime.hostStartupFailed` |

---

## 15. Developer operations

`DeveloperService` is a Swift protocol in RuntimeHost, next to `EmbeddedRuntimeService`. It exists only in embedded mode (§3.8). It has no wire form, no version, and no round-trip tests. It takes Swift values and URLs.

| Method | Arguments → Result | Command | Design |
|---|---|---|---|
| `bootLinux` | `LinuxBootRequest { kernel, initrd: URL?, tests: [String], window, stats: Bool, timeoutMs: Int64? }` → `LinuxBootResult` | `apkrun dev linux` | [vm.md](../02-design/vm.md) §12 |
| `installImageBundle` | `ImageBundleInstallRequest { source: URL }` (directory or `.aar`) → `WireImageInfo` | `apkrun dev image install` | [android-image.md](../02-design/android-image.md) §10.3 |
| `boot` | `DevBootRequest { bundle: URL?, gpu: DevGPUProfile?, window, stats, noAnimations: Bool, guestTransport: vsock or adb, waitReady: Bool }` → `RuntimeStatus` (target) | `apkrun dev boot` | [cli.md](../02-design/cli.md) §5, [graphics.md](../02-design/graphics.md) §9 |
| `launchApps` | `DevLaunchRequest { items: [apk(URL) or package(RuntimePackageID)], display: primary or secondary, window }` → `[DevLaunchResult]` | `apkrun dev launch` | [cli.md](../02-design/cli.md) §5, [guest-protocol.md](../02-design/guest-protocol.md) §7.1 |
| `addDisplay` | `DevDisplayRequest { pixelSize?, densityDpi? }` → `DisplaySlotSnapshot` | `apkrun dev displays add` | [cli.md](../02-design/cli.md) §5 |
| `removeDisplay`, `listDisplays` | `DisplayID` → Void; → `[DisplaySlotSnapshot]` | `apkrun dev displays` | [cli.md](../02-design/cli.md) §5 |
| `injectPower` | `sleep` or `wake` → Void | `apkrun dev power` | [runtime-daemon.md](../02-design/runtime-daemon.md) §6 |

- Errors are domain errors (`VMFailure`, `ImageFailure`, `RuntimeFailure`) as `APKRunError`, not wire errors.
- `DevGPUProfile`: `none` → `headless`, `swiftshader` → `guestSwiftshader`, `virgl` → `drmVirgl` ([graphics.md](../02-design/graphics.md) §9). `nil` selects the CLI default.
- `stats` adds the overlay of [graphics.md](../02-design/graphics.md) §7. It has no effect without `window`.
- `launchApps` boots Android if needed, installs each APK through `AdbClient`, and launches it through the Guest Agent. With `window = false` it opens no window.
- `injectPower` runs in the `apkrun dev boot` process, reached through its control socket. `console` and `adb` use no method.
- `DeveloperService` works only on the dev instance and is never compiled into release builds.

---

## 16. Events and streams

Topics fan out state changes to every subscriber. Streams deliver a sequence to one connection. Session events go only to the owning connection (§6.3). Server side: `RuntimeEventHub` ([runtime-daemon.md](../02-design/runtime-daemon.md) §8.1, §8.4).

### 16.1 Subscription

| Operation | Request → Reply | Clients | Kind |
|---|---|---|---|
| `subscribe` (built) | `RuntimeSubscribeControlRequest` (`topics`) → `RuntimeSubscribeControlReply` (`result`: `[EventTopic]`) | C; L (`runtime` only); W (`operations`, target) | U |
| `unsubscribe` (built) | `RuntimeUnsubscribeControlRequest` (`topics`) → `RuntimeUnsubscribeControlReply` (`result`: `RuntimeEmpty`) | C, L, W | U |

`EventTopic` raw values: `runtime`, `sessions`, `packages`, `updates`, `operations`, `health`, `maintenance`, `wrappers`, `integrations`.

- The connection must export a responsive `RuntimeEventSink`. Otherwise `subscribe` returns `runtime.malformedRequest`. The server confirms the sink with a bounded handshake first.
- A topic the kind may not have fails the whole request with `runtime.notAuthorized`. Built gates: C (`app`, `menuBar`, `cli`) get all nine topics; L (`launcher`) gets `runtime` only; `wrapper` gets none in the built code.
- An unknown topic name fails decoding with `runtime.malformedRequest`.
- `subscribe` and `unsubscribe` are idempotent. Subscriptions end on invalidation (§3.5).
- Replies and batches of one connection go from one serial queue. Events that arrive before a snapshot reply are older than the snapshot, and the client drops them.

### 16.2 Envelope, delivery, coalescing

`EventEnvelope`: `topic` (`EventTopic`), `seq` (UInt64, per connection from 1, assigned at send), `time` (Date), `operationID` (`OperationID`?), `payload` (`EventPayload`).

`EventPayload`: `runtime(RuntimeChange)`, `sessions(SessionListChange)` (target), `packages(PackageChange)`, `updates(UpdateEvent)` (target), `operations(OperationEvent)`, `health(HealthEvent)` (target), `maintenance(MaintenanceEvent)` (target), `wrappers(WrapperChange)` (target), `integrations(IntegrationChange)` (target), `resyncRequired(EventTopic)`, `unknown`.

| Rule | Value |
|---|---|
| Batch | `deliver` carries a JSON array. A batch goes out after 16 ms or 64 queued events |
| Acknowledgement | the client calls the reply block after decoding. At most 4 unacknowledged batches per connection |
| Queue | 1024 per connection. When full, drop the queued events of the topic with the most events and queue `resyncRequired(topic)` |
| Order | `seq` increases with no gaps; it is assigned after coalescing and dropping |
| Coalescing | latest value per key, at most 10 per second per key. State changes, results, and `finished` are never coalesced |

- RuntimeClient bounds each local stream to 1024 envelopes. On drop or reconnect it emits a locally synthesized `resyncRequired(topic)` with `seq == 0`, never sent over XPC. The consumer fetches a fresh snapshot.

Coalescing keys: `runtime.bootProgress` (one key); `operations.progress` and `packages.operationProgress` (`OperationID`); `updates.progress` and `maintenance.imageUpdateProgress` (`OperationID`, target); `health.healthChanged` (`HealthCheckID`, target); `wrappers.statusChanged` and `integrations.statusChanged` (`RuntimePackageID`, target).

`RuntimeChange` (topic `runtime`; it carries no host state or health): `stateChanged(WireRuntimeState)`, `bootProgress(BootProgress)` (coalesced), `bootLoopGuardChanged(BootLoopGuardStatus?)`, `provisioningChanged(WireProvisioningState)`, `configurationChanged(keys: [String])`, `idleChanged(IdleStatus)`, `agentsChanged([AgentConnection])`, `developerModeChanged(Bool)`, `unknown`.

| Type | Definition |
|---|---|
| `WireRuntimeState` | `stopped`, `booting(BootPhase)`, `ready`, `suspended`, `stopping(WireStopReason)`, `failed(WireError)`, `unknown` ([state-machines.md](../01-architecture/state-machines.md) §2) |
| `BootPhase` | `kernel`, `init`, `systemServer`, `bootCompleted`, `agentsConnecting`, `unknown` |
| `WireStopReason` | `user`, `idle`, `hostShutdown`, `hostUpdate`, `migration`, `reset`, `failure`, `unknown` |
| `BootProgress` | `phase`, `fraction` (Double?, an estimate), `elapsedMs` (Int64), `purpose` (`normal`, `firstBoot`, `imageUpdate(from:to:)`, `unknown`) |
| `IdleStatus` | `activities` ([ActivityKind]; empty = idle), `idleSince`?, `suspendAt`? (nil when `idleSuspendMinutes` is 0), `stopAt`? |
| `BootLoopGuardStatus` | `failures` (Int, in window), `windowStartedAt`, `tripped` (Bool: 3 failures in 10 min, [runtime-daemon.md](../02-design/runtime-daemon.md) §3.6) |
| `AgentConnection` | `agent` (`AgentKind`: `guest`, `store`, `unknown`), `state` (`AgentConnectionState`), `protocolVersion`?, `required` (Bool) |

`PackageChange` (topic `packages`): `installed(RuntimePackageSummary)`, `updated(RuntimePackageSummary, from: RuntimeVersionCode)` (also same-version reinstall; `from` is a best observation), `removed(RuntimePackageID, keptData: Bool)`, `unknown`. Target cases: `rolledBack`, `stateChanged(RuntimePackageID, WirePackageState)`, `operationProgress(RuntimePackageID, OperationID, StoreOperationProgress)`, `iconChanged`, `settingsChanged(RuntimePackageID, keys:)`, `unmanagedChanged([RuntimePackageSummary])` ([package-store.md](../02-design/package-store.md) §11.3). Target `WirePackageState` adds `importing`, `inspecting`, `updating`, `needsReinstall`.

Other target events: `UpdateEvent` (`phaseChanged`, `progress`, `finished`, `summaryChanged(available:waiting:failed:)`) ([update-system.md](../02-design/update-system.md) §11.2); `IntegrationChange` (`statusChanged`, `recordingChanged`, `sharedFoldersChanged`) ([desktop-integration.md](../02-design/desktop-integration.md) §11); `SessionListChange` (`opened`, `stateChanged`, `ended`, each with `SessionSummary`).

`StoreOperationProgress`: `stage` (`StoreOperationStage`: `copying`, `inspecting`, `receiving`, `verifying`, `committing`, `uninstalling`, `unknown`; target), `fraction` (Double?).

### 16.3 Operation events

Topic `operations`. Reports every long operation of §4.7, including sub-operations with `parent`.

| Case | Payload |
|---|---|
| `started` | `OperationSnapshot` |
| `progress` | `OperationID`, `OperationProgress` (coalesced per operation) |
| `finished` | `OperationID`, `OperationResult` |
| `unknown` | — |

- `OperationProgress`: `fraction` (Double?, nil = indeterminate), `stage` (String?), `bytes`, `totalBytes` (Int64?), `message` (String?; target: `WireLocalizedText`).
- `OperationResult`: `succeeded(OperationOutput)`, `failed(RuntimeWireError)`, `cancelled`, `unknown`.
- `OperationOutput`: `none`, `package(RuntimePackageSummary)`, `unknown` (built). Target cases: `runtime`, `importPreview`, `update`, `updateCheck`, `wrapper`, `wrappers`, `distributionWrapper`, `imageUpdate`, `image`, `diagnostics`.
- Output by kind: `install`, `repair`, `rollback`, `bootstrapImport` → `package`; `uninstall` → `none`; `import`, `inspect` → `importPreview`; `update` → `update`; `updateCheck` → `updateCheck`; `wrapperCreate`, `wrapperRefresh` → `wrapper`; `wrapperRefreshAll` → `wrappers`; `distributionWrapper` → `distributionWrapper`; `setup`, `resetAndroid`, `runtimeStop`, `runtimeRestart` → `runtime`; `imageCheck`, `imageDownload`, `imageApply` → `imageUpdate`; `imageInstall`, `imageRollback` → `image`; `diagnostics` → `diagnostics`.
- `started` precedes any `progress`; `finished` is last. A client that subscribes mid-operation calls `operationStatus`.
- A wrapper receives only operations started on its own endpoint.

### 16.4 Streams (target)

| Operation | Request → Reply | Clients | Kind |
|---|---|---|---|
| `notificationRelay`, `hostNotifications`, `guestLog` | §11.3, §13.1 → `StreamHandle` | as there | S |
| `closeStream` | `CloseStreamRequest` (`streamID`) → `RuntimeEmpty` | C, W | U |

- `StreamHandle`: `streamID`. `StreamEnvelope`: `streamID`, `seq` (per stream from 1), `event` (`StreamEvent`: `relay`, `hostNotification`, `guestLog`, `ended(StreamEndReason)`, `unknown`).
- `StreamEndReason`: `closed`, `replaced`, `finished` (`guestLog` with `follow = false`), `error(WireError)`, `unknown`.
- A stream ends without `ended` when its connection is invalidated. `ended` is the last event; the client does not call `closeStream` after it.
- `closeStream` is idempotent: an unknown, ended, or foreign stream returns `RuntimeEmpty` and changes nothing.
- Flow control: at most 4 unacknowledged events per stream. `guestLog` drops and counts lines in `dropped`.
- At most 4 streams per connection; a further request returns `runtime.busy`.

---

## 17. Shared types

### 17.1 `JSONValue` and `RuntimeEmpty`

Built: `RuntimeEmpty` is an empty struct that encodes as `{}`. It is the argument and result of operations that carry none.

Target: `JSONValue` encodes as plain JSON (`true`, `1.25`, `"ask"`, `{…}`). It is the only exception to §4.2's enum rule. It carries setting values and patches. `null` in a patch means reset; in a value it means no value. Integers are exact up to 2^53.

### 17.2 Types defined here

| Type | Definition |
|---|---|
| `ActivityKind` (built) | `RawRepresentable` string. Known: `session`, `backgroundTask`, `storeOperation`, `diagnostics`, `migration`, `provisioning`, `adbClient`, `cli`. `session` is listed once while any session is open ([runtime-daemon.md](../02-design/runtime-daemon.md) §5.1) |
| `AgentKind` (built) | `guest`, `store`, `unknown` |
| `AgentConnectionState` (built) | `notStarted`, `connecting`, `connected`, `reconnecting`, `unresponsive`, `unavailable`, `incompatible`, `unknown` |
| `ImageVersion` (built) | §4.3 |
| `WireDisplayState` (target) | `free`, `attaching`, `allocated(SessionID)`, `releasing`, `faulted(WireError)`, `unknown` ([state-machines.md](../01-architecture/state-machines.md) §4) |
| `DisplaySlotSnapshot` (target) | `slot` (0 is Android's primary display), `state`, `displayID`?, `androidDisplayID` (Int32?), `pixelSize`?, `densityDpi`? |
| `StoreOperationStage` (target) | §16.2 |
| `AndroidWindowMode`, `ClosePolicy`, `EscapeKeyMapping`, `SecondaryClickMapping`, `ScrollMode` (target) | the cases of §6.2 and §14.2, each with `unknown` |
| `PixelSize` (target) | `width`, `height` (Int) |
| `WaitingReason` (target) | `gu1RuntimeReady`, `gu2NoSession`, `gu3NoKeepRunningTask`, `gu4QuietPeriod`, `gu5AndroidAgrees`, `gu6NoStoreTransaction`, `gu7DisplaySlot`, `unknown` ([update-system.md](../02-design/update-system.md) §7.1) |

- `ActivityKind` is a string so RuntimeCore can add kinds without a RuntimeAPI change.

### 17.3 Types copied from design documents

RuntimeAPI imports no other module ([modules.md](../01-architecture/modules.md) §3), so it declares these itself, keeping design field names.

| Wire type | Defined in |
|---|---|
| `ImportPreview`, `ImportRelation` (built as `RuntimeImportPreview`, `RuntimeImportRelation`) | [package-store.md](../02-design/package-store.md) §4.7 |
| `WirePackageRecord`, `OperationSummary`, `ArtifactSlotsSummary` | [package-metadata-json.md](package-metadata-json.md) |
| `WrapperStatus`, `WrapperState` | [wrapper.md](../02-design/wrapper.md) §9.1 |
| `BundleProblem` | [wrapper.md](../02-design/wrapper.md) §13 |
| `IntegrationKind` | [desktop-integration.md](../02-design/desktop-integration.md) §2 |
| `SessionID`, `SystemDisplayUse` | [display-and-windowing.md](../02-design/display-and-windowing.md) §3.1 |
| `HostRequirement` | [runtime-daemon.md](../02-design/runtime-daemon.md) §9.1 |

### 17.4 Ownership and conversion

Modules that import RuntimeAPI (RuntimeCore, APKStoreCore, UpdateCore, WrapperCore, IntegrationCore) use a wire type directly or convert to it. InputCore and DiagnosticsCore do not import RuntimeAPI; RuntimeHost converts for them on the server. APKRunLauncher converts input (`XPCInputSink`). RuntimeClient converts wire errors to `APKRunError` (§4.5).

| Wire type | Domain type | Owner | Definition |
|---|---|---|---|
| `WireRuntimeState`, `BootPhase`, `WireStopReason` | `RuntimeState` | RuntimeCore | [state-machines.md](../01-architecture/state-machines.md) §2 |
| `SessionPhase`, `SessionEndReason` | session state | RuntimeCore (SessionRegistry) | [state-machines.md](../01-architecture/state-machines.md) §3 |
| `WireDisplayState` | `DisplayState` | RuntimeCore (DisplayPool) | [state-machines.md](../01-architecture/state-machines.md) §4 |
| `RuntimePackageState`, `PackageChange` | `PackageState` | APKStoreCore | [state-machines.md](../01-architecture/state-machines.md) §5 |
| `WireUpdatePhase`, `UpdateOutcome`, `UpdateEvent` | `UpdatePhase` | UpdateCore | [state-machines.md](../01-architecture/state-machines.md) §6 |
| `WireProvisioningState` | provisioning state | RuntimeHost | [runtime-daemon.md](../02-design/runtime-daemon.md) §9.2 |
| `WireImageUpdatePhase`, `WireImageCandidate` | image update phase | RuntimeHost (`ImageUpdateCoordinator`) | [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.3 |
| `WrapperStatus`, `WrapperSummary`, `WrapperInfo` | registry entry | WrapperCore | [wrapper.md](../02-design/wrapper.md) §9.1 |
| `WireIntegrationDecision`, `IntegrationStatus` | integration decision | IntegrationCore | [desktop-integration.md](../02-design/desktop-integration.md) §2.3 |
| input types (§7.2) | input events | InputCore | [input.md](../02-design/input.md) §8 |
| `WireError`, `WireLocalizedText` | `APKRunError`, localized text | DiagnosticsCore | [diagnostics.md](../02-design/diagnostics.md) §2.1, §2.2 |
| `WireHealthReport`, `WireHealthResult`, `WirePerfStatistics` | health, perf | DiagnosticsCore | [diagnostics.md](../02-design/diagnostics.md) §7, §9.3 |

A new domain-enum case needs a wire case. Until then RuntimeHost sends `unknown`, and a T0 test that maps every domain case fails.

---

## 18. Client mappings

These tables show which operations each command and screen calls, so a reviewer can check that no surface needs an operation this document lacks. Behavior belongs to the cited design documents.

Every client connects with `hello`, then `requestEndpoint` (§3.1). A client showing live state subscribes to its topics (§16.1), and reloads snapshots after reconnect (§3.6). A long operation waits for `OperationEvent.finished` (§16.3) and sends `cancelOperation` on Ctrl-C or **Cancel**. "No operation" means a local action: an `apkrun://` URL, AppKit, Sparkle, `SMAppService`, or the file system.

### 18.1 CLI

Uses the control endpoint, and the maintenance endpoint only for `self-update finish`. `--json` prints the reply DTO ([cli.md](../02-design/cli.md) §3.2). Operations marked (target) are not built.

| Command | Operations | Notes |
|---|---|---|
| `version` | `hello`, `runtimeStatus` | CLI version alone when apkrund is unreachable |
| `setup [--image]` | `setup` (target) | `--image <file>` sends `archive(fileIndex:)`; registers first if needed |
| `status` | `runtimeStatus`, `listSessions`, `listUpdates`, `activeRecordings` | menu bar summary |
| `runtime status` / `restart` / `reset` | `runtimeStatus` / `restartRuntime` / `resetRuntime` | |
| `runtime start [--hold] [--timeout]` | `startRuntime` | `hold`, `timeoutMs` (target) |
| `runtime stop [--force]` | `stopRuntime` | on `runtime.busy` asks, then `force` (target) |
| `runtime reset --erase [--no-backup]` | `resetAndroid` (target) | `keepBackup = !--no-backup`; `confirmed` after prompt or `--yes` |
| `info [--runtime] [--displays]` | `runtimeInfo` (target) | |
| `install <file>…` | `importPackage`, `installImported` | `--provider`, `--updates` become `RuntimeInstallOptions`; `--updates manual` sets `authority = manual`; `--wrap` adds `createWrapper` (target) |
| `uninstall <package>` | `beginUninstallPackage` | `--keep-data`, `--keep-wrapper`, `--forget` set the options |
| `list [--all]`, `info <package>` | `listPackages`, `packageInfo` | |
| `inspect <file>…` | `inspectFile` (target) | |
| `launch <package>`, `stop <package>` | `launch`, `terminate` | |
| `repair`, `rollback`, `adopt <package>` | `repairPackage`, `rollbackPackage`, `adoptPackage` (target) | `--allow-data-loss` for rollback |
| `settings <package> list`, `get` | `packageSettings` | |
| `settings <package> set`, `reset` | `updatePackageSettings` | `reset` sends `null`; `--all` builds a patch (§14.3) |
| `update [--check-only]` | `checkForUpdates` | `packages = nil`; `checkOnly` (target) |
| `update <package> [--now] [--file]` | `updatePackage` (target) | `--now` sets `closeRunningApp`; without it, prints "will update when ‹App› quits" |
| `update policy`, `authority`, `skip`, `unskip`, `history` | `setUpdatePolicy`, `setUpdateAuthority`, `skipVersion`, `unskipVersion`, `updateHistory` | target |
| `integrations status <package>` | `integrationStatus` | target |
| `shared-folders list`, `add`, `remove` | `sharedFolders`, `addSharedFolder`, `removeSharedFolder` | `add` creates the bookmark in the CLI |
| `config list`, `get`, `set`, `reset` | `configuration`, `updateConfiguration` | `reset` sends `null` |
| `image list`, `check`, `install`, `rollback`, `recovery-points` | `listImages`, `checkImageUpdate`, `installImage`, `rollbackImage`, `recoveryPoints`, `deleteRecoveryPoint` | target; `install --latest` sends `.latest` with `apply = true` |
| `self-update check` / `install` / `finish` | `checkSelfUpdate` / no operation / `restartForUpdate` | `install` opens `apkrun://settings/general` |
| `doctor [--deep] [--fix]` | `healthReport`, `applyHealthFixes` | `--fix` sends `checks = []` (target) |
| `diagnostics` | `createDiagnostics` | the CLI creates the output file and passes its handle |
| `logs`, `logs --guest [--follow]` | none, `guestLog` | host logs via `log show` or `log stream`; guest logs need developer mode |
| `operations list`, `wait <id>`, `cancel <id>` | `listOperations`, `operationStatus`, `cancelOperation` | `wait` also watches `operations` |
| `wrap <file>…`, `wrap <package>`, `--distribution` | `importPackage`, `installImported`, `createWrapper`, `buildDistributionWrapper` (target) | combinations of [wrapper.md](../02-design/wrapper.md) §12.2; `--portable` without install sends `importTicket` |
| `wrapper list`, `info`, `refresh`, `remove`, `verify`, `approve` | `listWrappers`, `wrapperInfo`, `refreshWrapper`, `refreshAllWrappers`, `removeWrapper`, `verifyWrapper`, `approveWrapper` | target; `refresh --all` uses `scope = all` |

### 18.2 APKRun.app

Sections refer to [host-ui.md](../02-design/host-ui.md). Operations marked (target) are not built.

| Surface | Operations | Notes |
|---|---|---|
| Models | `runtimeStatus`, `listPackages(all)`, `packageInfo`, `listOperations`; target: `integrationStatus`, `listWrappers`, `listUpdates`, `listSessions`, `configuration`, `selfUpdateStatus`, `imageUpdateStatus`, `pendingApprovals`, `hostNotifications` | topics `runtime`, `packages`, `operations`; target: others |
| Banner **Restart Service**, `--register-runtime` | no operation | `SMAppService` |
| Onboarding | `setup` (target) | **Start Over** sets `recreateInstance`; **Report…** calls `createDiagnostics` |
| Header: **Start/Stop Android**, **Restart** | `startRuntime`, `stopRuntime`, `restartRuntime` | stop asks on `runtime.busy` |
| Header: **Start in Graphics Safe Mode** | `updateConfiguration({ graphics.safeMode: true })`, `restartRuntime` | target |
| Header: **Reset Android…**, **Continue Setup**, **Restart Now** | `resetAndroid`, `setup`, `restartForUpdate` | target |
| App rows: **Open**, **Update Now** | `launch`, `updatePackage` | target update |
| App rows: **Uninstall…**, **Remove from APKRun** | `beginUninstallPackage` (`forget` for the second) | |
| App rows: **Repair…**, **Update Mac App** | `repairPackage`, `refreshWrapper` | target |
| Other Android apps | `launch`, `adoptPackage` (target) | |
| Add flow | `importPackage`, `installImported`, `cancelImport` (target), `createWrapper` (target), `terminate` (**Quit and Update**, §19.1), `placeStagedWrapper` (target) | `origin` is `addFlow`, `document`, or `dropOnHome` |
| App page (target) | `packageSettings`, `updatePackageSettings`, `listSessions`, `setUpdatePolicy`, `checkForUpdates`, `updateHistory`, `rollbackPackage`, `setUpdateAuthority`, `wrapperInfo`, `refreshWrapper`, `removeWrapper` | **Reset** sends `null`; **Use Current Size** reads `pointSize` |
| Settings → General, Runtime, Updates, Language & Region | `configuration`, `updateConfiguration`, `selfUpdateStatus`, `imageUpdateStatus`, `checkImageUpdate`, `applyImageUpdate` (target) | Sparkle reports via `noteSelfUpdateStatus` |
| Settings → Privacy | `deniedWrappers`, `clearWrapperDenial` | target |
| Settings → Files | `sharedFolders`, `addSharedFolder`, `removeSharedFolder`, `setSharedFolderAccess` | target |
| Settings → Storage | `runtimeInfo { resources: true }`, `listPackages(all)`, `listImages`, `recoveryPoints`, `importPackage` + `installImported`, `deleteRecoveryPoint`, `rollbackImage`, `installImage` | target; **Delete Data** uses `beginUninstallPackage { forget: true }` |
| Troubleshooting | `healthReport`, `applyHealthFixes`, `createDiagnostics`, `restartRuntime`, `updateConfiguration`, `resetAndroid` | **Cancel** sends `cancelOperation`; target except `restartRuntime` |
| **Re-register Mac Apps** | `rescanWrappers { register: false }`, then `{ register: true }` | target |
| Advanced: **Developer mode** | `updateConfiguration({ developer.enabled })` | target |
| Approval prompt | `pendingApprovals`, `decideApproval` | target |
| Notifications | `hostNotifications`, `hostNotificationResponse`, then `updatePackage`, `applyImageUpdate`, or `startRuntime` | target |

### 18.3 APKRunMenuBar

Sections refer to [host-ui.md](../02-design/host-ui.md) §12. The menu bar observes and never holds an activity.

| Item | Operations | Notes |
|---|---|---|
| Runtime line, dot | `runtimeStatus` | topics `runtime`, `maintenance`; target `health` |
| **Apps** | `listSessions`, `activeRecordings`, `launch` | target except `launch` |
| **Updates**: **Update**, **Update All** | `listUpdates`, `updatePackage` | target |
| Maintenance rows | `selfUpdateStatus`, `imageUpdateStatus`, `applyImageUpdate`, `restartForUpdate` | target; **Update…** opens `apkrun://settings/general` |
| **Stop Android**, **Start Android** | `stopRuntime`, `startRuntime` | |
| **Open APKRun…**, **Quit Menu Bar Item** | no operation | |

### 18.4 Wrapper and generic launcher

Sections refer to [wrapper.md](../02-design/wrapper.md). The launcher (L) uses the same code with a different endpoint (§1.4).

| Surface | Operations | Notes |
|---|---|---|
| Start | `hello`, `requestEndpoint(wrapper)`, `requestApproval`, `runtimeStatus`, `packageInfo`, `openSession` | `packageInfo` supplies window defaults (wrapper §14.1). Target except the first four and `packageInfo` |
| Window | `frameDisplayed`, `visibilityChanged`, `focusChanged`, `resize` | §6.3 (target) |
| Input and text | `sendInput`, `sendText` | §7 (target) |
| Integrations | `pushClipboard`, `clipboardWritten`, `importFiles`, `acceptExport`, `resolveLinkPrompt`, `notificationRelay`, `notificationRelayResponse` | §11 (target) |
| Screen N **Install from This App** | `importBootstrap` | §10.7 (target) |
| Screen E **Try Again**, reconnect | `openSession` | target |
| ⌘W, ⌘Q, logout | `closeSession` | target |
| View: zoom, Show Frame Statistics | `resize`, `frameStatistics` | target |
| Android: Back, Restart ‹App› | `sendInput`, `restartApp` | target |
| Long wrapper operations | `operationStatus`, `cancelOperation`, topic `operations` | own operations only (§16.3) |
| Open APKRun, Get APKRun, Check for Updates, Settings…, Report a Problem… | no operation | `apkrun://` URLs or the downloads page |

---

## 19. Decisions and open items

### 19.1 Choices made in this document

The design documents do not fix these values; changes follow §2.3.

| Item | Choice | Section |
|---|---|---|
| **Start Over** after two failed first boots | `SetupRequest.recreateInstance` | §5.4 |
| `inputPrefs`, `pointSize` | `SessionDescriptor.inputPrefs`; `SessionSummary.pointSize` | §6.2, §14.3 |
| Staging token | 60 minutes, and until apkrund exits | §10.3 |
| `destination = nil` | `wrappers.defaultLocation`; `ask` there means `userApplications` | §10.3 |
| Bootstrap import | `bootstrapJSON` at most 64 KiB; 1–20 files | §10.7 |
| Host notifications | APKRun.app only; one stream at a time | §11.3 |
| Zoom | `resize` writes `window.zoom`; the sending session gets no `windowPrefsChanged` | §14.3 |
| `update.mode` in a package patch | refused; `setUpdatePolicy` is the only writer | §14.3 |
| Unmanaged package settings | `store.packageNotFound`; adopt first | §14.3 |
| Reply and event order | one serial queue per connection | §16.1 |
| Event batching | 16 ms or 64 events; 4 unacknowledged batches | §16.2 |
| Queue overflow | drop the topic with the most events; send `resyncRequired` | §16.2 |
| Streams | 4 per connection; 4 unacknowledged events per stream; `closeStream` is idempotent | §16.4 |
| `ActivityKind.session` | listed once while any session is open | §17.2 |
| `WaitingReason` | `gu1RuntimeReady` … `gu7DisplaySlot` | §17.2 |
| `DeveloperService` | Swift protocol, no wire form | §15 |
| Add flow **Quit and Update** | `terminate`; the waiting `update` then continues | §18.2 |

### 19.2 Owners of operations

Each operation is defined in the section of its own design document. These operations are listed here because their owner is not in their own section:

| Operations | Owner |
|---|---|
| `startRuntime`, `stopRuntime`, `restartRuntime`, `resetRuntime`, `runtimeInfo`, `listSessions`, `restartApp`, `listOperations`, `unsubscribe`, `closeStream` | [runtime-daemon.md](../02-design/runtime-daemon.md) §8.6 |
| `refreshAllWrappers`, `rescanWrappers`, `pendingApprovals`, `deniedWrappers`, `clearWrapperDenial` | [wrapper.md](../02-design/wrapper.md) §12.1 |
| `notificationRelayResponse`, `hostNotifications`, `hostNotificationResponse` | [desktop-integration.md](../02-design/desktop-integration.md) §11, [host-ui.md](../02-design/host-ui.md) §11 |
| `guestLog` | [diagnostics.md](../02-design/diagnostics.md) §7.6 |
| `DeveloperService` methods | [cli.md](../02-design/cli.md) §5 |

Error codes this document introduces (`runtime.developerModeRequired`, `wrapper.stagingExpired`, `wrapper.approvalNotFound`) are in [error-catalog.md](error-catalog.md).

### 19.3 Open items

| Item | Why it is open | Until then |
|---|---|---|
| The `refreshBlocked` fallback (`stagingToken`; APKRun.app swaps `Contents`) | needed only if macOS App Management blocks apkrund's swap; #77 finds out ([risks.md](../04-plan/risks.md) R-20) | §10.5; if #77 finds no block, `stagingToken` is removed |
| Restoring a Reset Android recovery point | no operation or UI restores it ([open-questions.md](../04-plan/open-questions.md) OQ-41) | no restore in v1 (§12.3) |
