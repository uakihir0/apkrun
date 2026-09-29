# Implementation Decisions for Review

| Field | Value |
|---|---|
| Status | Open review items |
| Related | [issues/README.md](issues/README.md), [roadmap.md](roadmap.md), [../05-development/workflow.md](../05-development/workflow.md) |

This log records implementation choices made to keep work moving when the
specification has gaps or conflicting statements. Every entry is marked for
maintainer review; recording a choice does not change an accepted ADR.

## IR-001: EmbeddedRuntime dependency set

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #001 |
| Affected documents | [modules.md](../01-architecture/modules.md) §3, [M00](issues/M00-repository-and-vm-foundation.md) #001, [cli.md](../02-design/cli.md) §2, [build-system.md](../05-development/build-system.md) §2.1 |

**Choice.** The `EmbeddedRuntime` trait conditionally enables `RuntimeHost`,
`WindowingCore`, and `InputCore` for the `apkrun` target.

**Reason.** The normative module graph already lists all three edges. The task,
CLI design, and build-system text listed only two. Keeping `InputCore` as an
explicit direct edge preserves the final dependency contract and avoids relying
on a transitive `WindowingCore` dependency for future CLI input commands. The
three documents were synchronized with the module graph; no module ownership or
allowed dependency was added.

## IR-002: ZIPFoundation pin in #001

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #001 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #001, [build-system.md](../05-development/build-system.md) §2.1, [ADR-0017](../01-architecture/decisions/0017-zipfoundation-zip-reading.md) |

**Choice.** Include the exact ZIPFoundation dependency in the initial manifest,
with its package product used only by `APKStoreCore` and `UpdateCore`.

**Reason.** The build-system dependency table requires all three Swift packages
at an exact version, and ADR-0017 already accepts ZIPFoundation for those two
modules. Adding the pin now keeps SwiftPM and Xcode resolution aligned and
avoids introducing an undocumented dependency later.

## IR-003: Defer Sparkle from the bootstrap project

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #001 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #001, [build-system.md](../05-development/build-system.md) §2.2, [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2 |

**Choice.** The #001 Xcode project does not link Sparkle. The dependency and
embed phase are added by #057.

**Reason.** The #001 scope explicitly places Sparkle outside the bootstrap task,
while the target table described the later product state without identifying
when that dependency arrives. The target table now marks Sparkle as introduced
by #057.

## IR-004: Seed the third-party lock in #001

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #001 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #001, [M00](issues/M00-repository-and-vm-foundation.md) #062, [build-system.md](../05-development/build-system.md) §6.1 |

**Choice.** Add all three Swift package pins and their license copies to the
repository during #001. #062 still adds validation scripts and CI checks.

**Reason.** The repository rule requires every third-party dependency to be
recorded in `ThirdParty/ThirdParty.lock.json` as soon as code depends on it.
The initial task already introduces three exact package dependencies, so
waiting for #062 would leave the working tree outside that invariant.

## IR-005: Relocate caches with `APKRUN_HOME`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [filesystem-layout.md](../01-architecture/filesystem-layout.md) §§1–3, [diagnostics.md](../02-design/diagnostics.md) §11 step 1 |

**Choice.** When a caller explicitly enables `APKRUN_HOME`, the disposable
system cache root is `<APKRUN_HOME>/Caches`, while the persistent image
download cache remains `<APKRUN_HOME>/Cache`.

**Reason.** The filesystem specification gives system caches and persistent
application data separate roots. Keeping both below the override makes tests
and development runs relocatable without conflating the two storage roles.

## IR-006: Keep image artifact paths manifest-driven

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [filesystem-layout.md](../01-architecture/filesystem-layout.md) §§1–2, [android-image.md](../02-design/android-image.md) §3, [AGENTS.md](../../AGENTS.md) §6.3 |

**Choice.** `APKRunPaths` exposes installed image roots, manifest metadata,
staging locations, and containing directories. It does not construct paths to
individual image payload files; those are resolved by `AndroidImageManifest`.
Fixed recovery point files are exposed directly.

**Reason.** The implementer rules require image payload access through the
manifest after inventory. Keeping that boundary avoids assumptions in the
DiagnosticsCore leaf module while still centralizing the documented writable
paths and recovery point layout.

## IR-007: Use short operation IDs in log fields

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §§2.4, 3.2; [M00](issues/M00-repository-and-vm-foundation.md) #061 step 3 |

**Choice.** Log fields use `op=<first 8 hex>`; JSON, wire fields, and Copy
Details retain the full UUID.

**Reason.** The general operation ID description said logs use the full value,
while the logging format and #061 acceptance criteria specifically require
`op=<first 8 hex>`. The concrete logging format takes precedence for log lines,
and §2.4 now states that distinction.

## IR-008: Resolve configuration-list exit status from every item

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [error-catalog.md](../03-reference/error-catalog.md) §§3.1, 5.2, 19.1; [diagnostics.md](../02-design/diagnostics.md) §2.2 |

**Choice.** `vm.configurationInvalid` has `cliExit: 1` as its safe fallback and
the named `cliExitRule: allConfigurationItemsInternalOrFailure`. It exits 70
only when every listed item resolves to a VM catalog entry with exit 70.

**Reason.** The error catalog specifies a mixed exit (70 only when all
configuration failures are internal), while the base `errors.json` format
allows only one fixed code or `"cause"`. A named rule expresses the existing
behavior, keeps the fallback fail-safe, and is constrained to this list entry
by generator validation.

## IR-009: Catalog swift-argument-parser usage failures

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [cli.md](../02-design/cli.md) §§3.2–3.3; [error-catalog.md](../03-reference/error-catalog.md) §§16, 19.2 |

**Choice.** The root command presents parser syntax failures as
`cli.invalidArguments`, with no raw argument text in the message, logs, or JSON.

**Reason.** #061 explicitly requires every user-visible failure to use
`ErrorPresenter` and specifies the catalog-backed usage entry. This conflicts
with the earlier CLI note that swift-argument-parser owns its output. The
catalog path provides consistent remediation while avoiding accidental
disclosure of sensitive command-line values.
Built-in `--help`, `--version`, and completion requests continue through
swift-argument-parser's clean-exit presenter, so they retain their normal output
and exit status.

## IR-010: Attribute performance signposts from the marker catalogue

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §§4.1–4.2; [M00](issues/M00-repository-and-vm-foundation.md) #061 step 5 |

**Choice.** `Perf.mark` selects the signpost subsystem from the marker's
catalogue emitter, while `Perf.interval` selects it from the documented
`gpu.*` and `input.*` prefixes. All marker events use the static signpost name
`APKRunPerfMarker`; unknown marker strings are stored as `UNKNOWN`. The mark
API accepts an optional `PerfTimeline` so callers can use the instance from
`DiagnosticsContext`. Each marker has an attribute schema that checks
key-marker pairs, value types, and numeric ranges. It accepts at most 16
attributes, with bounded names and string sizes. The timeline retains those
bounded values, while public signposts expose only the finite `bootKind` and
`agent` strings. Other string values are omitted from signposts. It records
the difference between the supplied marker instant and signpost emission time
as `sourceTimeOffsetMsAtSample`, sampled after preparing the base fields and
immediately before final message encoding and emission.

**Reason.** DiagnosticsCore cannot determine the calling module at runtime,
so using the catalogue's declared emitter gives deterministic subsystem
attribution without requiring each call site to repeat it. `OSSignposter`
requires a static event name and timestamps the event when it is emitted;
the marker therefore belongs in the event message. The offset sample
approximates the difference to the event time for cross-process correlations.
Per-marker key/type/range checks
prevent unrelated values from being presented under another marker, and
count/size bounds cap memory. Limiting public string fields prevents
unvalidated values from reaching signposts. Later writers of timeline data
must still apply the catalogue's public-data rules. Injecting the timeline
makes the documented per-context timeline usable and keeps tests isolated.

## IR-011: Remove the duplicate Android boot marker name

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §4.2; [M00](issues/M00-repository-and-vm-foundation.md) #061 step 5 |

**Choice.** Use `BOOT_COMPLETED` as the sole marker for the `.bootCompleted`
phase and remove `ANDROID_BOOT_COMPLETED` from the required catalogue and API.

**Reason.** The required-marker sentence names `ANDROID_BOOT_COMPLETED`, but
the catalogue table, runtime-daemon design, and M1 boot task define only
`BOOT_COMPLETED` for that phase. No distinct emitter or timing is specified
for the additional name, and retaining it as a no-op would advertise a
required marker that cannot be recorded. The table's executable event
definition takes precedence; maintainers should confirm the removed name was
a duplicate rather than a separate guest broadcast event.

## IR-012: Verify performance marker I/O through the declared effects

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #061 step 5; [diagnostics.md](../02-design/diagnostics.md) §4.1 |

**Choice.** Verify that `Perf.mark` has no filesystem, mirror-writer, or
`LogSink` dependency by reviewing its API and implementation. The T0 tests
exercise the injected in-memory `PerfTimeline` and check that intervals do
not append events.

**Reason.** The specified API accepts a `PerfTimeline` and emits an
`OSSignposter` event; it has no file-writer or sink parameter. Adding an
unused failing sink would be disconnected from the code path and would give
a false-positive test. The task check now matches the actual effects without
adding a production dependency solely for a test seam.

## IR-013: Make health verdict inputs and skipped-check behavior explicit

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §§7.1–7.3; [error-catalog.md](../03-reference/error-catalog.md) §20.1–20.2; [M00](issues/M00-repository-and-vm-foundation.md) #061 step 6 |

**Choice.** The verdict takes an explicit runtime-state context containing
provisioning completion, boot-loop state, and the last boot error code.
Unrecognized runtime states resolve to `degraded` rather than `healthy`.
When apkrund is unavailable, non-host checks are skipped without an
`ErrorInfo`; the separate `apkrund.registration` or `apkrund.reachable`
failure row supplies remediation. The memory check warns below 8 GiB, while
16 GiB remains the recommended amount. `BuildInfo.launchAgentLabel` maps the
known `dev` and `updatetest` identities to their separate LaunchAgent labels
and defaults other identities to the release label. Component-version checks
read build numbers from embedded signing metadata instead of executing
unverified bundled binaries. A check's timeout budget includes waiting for a
concurrency slot; caller cancellation returns no partial report.

**Reason.** The health design specified verdict conditions but did not define
their input model or what to do for transitional runtime states. Returning
`degraded` avoids claiming a healthy runtime when its state is not recognized.
The diagnostics text also said both that skipped rows have no error and that
unavailable-service skips carry a service error. Keeping the explicit
no-error rule avoids duplicating remediation on every skipped row; the
registration/reachability row remains actionable. The 8 GiB threshold follows
the host-check pass condition, and the 16 GiB recommendation remains visible
in the warning text. Build identities are mapped through a closed set so
caller-supplied identity text is never used as a `launchctl` label. Reading
build metadata without starting the daemon or CLI keeps a health check from
executing application code before the separate deep signature check. Including
permit wait in the same deadline makes the documented timeout a bound on the
entire check, while returning an empty report on caller cancellation avoids
presenting a misleading partial health result.

## IR-014: Bound and combine host log reads

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §3.5; [cli.md](../02-design/cli.md) §4.8 |

**Choice.** `apkrun logs` defaults to the most recent hour, restricts
`--subsystem` to `io.apkrun` names, and accepts `--since` durations through
30 days. Follow mode starts `log stream` before reading history, buffers live
records until history is ready, then emits history and live records with
occurrence-aware overlap removal. It reads public daemon mirrors when `log
show` fails, times out, or returns no matching records. Stream exits trigger
retries with backoff from one to 30 seconds. It reports `cli.logsUnavailable`
when neither unified logging nor a mirror file provides a readable source.
Human-readable output escapes Unicode control and formatting characters.

**Reason.** `log show` without a window may read an unnecessarily large store;
one hour gives useful context and the 30-day cap rejects accidental unbounded
history requests. Restricting the filter keeps this APKRun command inside its
own namespace and makes the predicate safe to compose. `log stream` already
follows events and this host's `log stream --help` has no `--follow` option.
Starting it before the snapshot lets buffered events cover the interval while
`log show` runs. Backoff avoids a tight retry loop when stream startup fails.
Mirrors contain only public daemon records, so they remain a partial fallback
when unified records from other host processes cannot be read. A human-readable
terminal line escapes control and formatting scalars so untrusted log messages
cannot issue terminal control sequences or visually reorder adjacent text.

## IR-015: Bound log duration and terminal output

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §3.5; [cli.md](../02-design/cli.md) §4.8 |

**Choice.** `--since` accepts at most 30 days. Human-readable log output
renders control and Unicode formatting scalars as `\u{...}` escapes, with
readable escapes for tab, newline, and carriage return. JSON output escapes
formatting, line-separator, and paragraph-separator scalars using JSON Unicode
escapes, preserving the decoded record.

**Reason.** A maximum horizon limits unexpectedly large `log show` results
while leaving a month of history available for investigations. APK code and
guest input can contribute to log messages, so plain output must prevent
terminal control sequences and direction-format characters from affecting the
terminal display. NDJSON remains a structured encoding of the original public
message while avoiding physical line breaks or display-direction effects.

## IR-016: Stream host logs with bounded history state

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §3.5; [cli.md](../02-design/cli.md) §4.8 |

**Choice.** `LogReader` parses `/usr/bin/log` output incrementally instead of
retaining the full stdout buffer. Duration validation also runs in
`DiagnosticsCore`, so direct API callers receive the same 30-day bound as CLI
callers. Follow mode retains a timestamp watermark and occurrence counts for
the boundary record set; it does not retain a set of all historical records.
It caps live records waiting for history at 4,096 records or 4 MiB of
estimated record text, whichever is reached first, and backpressures pipe reads
while that buffer is full. Individual NDJSON lines are capped at 1 MiB;
oversized lines are discarded through the next newline. It waits for the
`Filtering the log data using`
stderr notice or first stdout record before it considers `log stream` ready;
if neither arrives within 30 seconds, it terminates the process and retries.
It reads the initial history only after readiness, while buffering live
records, and applies `--since` to that initial history only. After any stream
exit, it retries; after a replacement stream becomes ready, it runs a catch-up
`log show --start` query from one second before the last covered instant while
buffering live records. For complete unified queries, older live timestamps
inside the initial history window are covered by the snapshot; older live
records outside that fixed window remain eligible. At the timestamp boundary,
it suppresses only the occurrences represented in history and preserves
identical records beyond that count. For partial or mirror history, it
suppresses only exact boundary occurrences and allows older timestamps
through; partial unified output does not imply that earlier mirror or catch-up
records were covered. Follow history fixes its `--since` cutoff at command
start and uses `--start` with a timestamp filter; delayed live records remain
eligible outside that window. The timestamp parser accepts fractional ISO 8601
timestamps emitted by NDJSON. The recent-record cache is limited to 4,096
records and 1 MiB of text. The query-side occurrence cache used to reconcile
buffered live rows is limited to 4,096 records and 4 MiB, matching the maximum
live buffer. A bounded count map preserves query matches for rows already
present in the live buffer as the query advances; its keys are bounded by the
live queue. If a matching live row arrives only after its query-side occurrence
has been evicted, it can be replayed; retaining late rows is preferred over
suppressing them by timestamp.
Captured stderr is limited to a 64 KiB tail, and non-capturing log reads do
not retain stderr.
An initial or reconnect checkpoint advances only after a complete unified
query, to the later of the query's launch time and stream's end time when both
sources jointly cover the interval. If an incomplete catch-up gap outlives the
bounded recent-record cache, a later retry can repeat older rows. This preserves
at-least-once delivery instead of suppressing potentially late records based
only on timestamp. An incomplete initial history query retains the original
oldest requested boundary as its checkpoint so a later catch-up still covers
events emitted before stream readiness. If a replacement stream cannot become
ready after three attempts, the reader runs one final catch-up query with mirror
fallback and returns. Without a readable source it returns
`cli.logsUnavailable`. A mirror notice is emitted only after at least one
mirror file can be read, and partial parsed output counts as a readable source.

**Reason.** A 30-day query can produce more output than should be held in
memory, while the history/live overlap only needs the newest timestamp
boundary. Pipe backpressure and the byte and event caps bound handoff memory;
the line limit also bounds a malformed or unterminated JSON record. The
bounded exact-record cache may evict entries from a gap that remains unresolved
after repeated partial queries. Replaying an older row in that case is safer
than suppressing a late record solely because its timestamp is old. During a
large successful query, a matching live row that reaches the handoff only
after its query occurrence leaves the bounded cache can also be repeated;
rows already in the live buffer are matched against the query as it advances.
Waiting for the subscription notice prevents the history query from racing
ahead of the stream attachment; the first output is a fallback readiness
signal if the notice is absent. Applying the `--since` cutoff only to history
keeps delayed live records from expiring while the query runs. The handoff
limits history deduplication to timestamps inside the fixed query window, so
older live entries remain eligible. A one-second
catch-up margin handles `log show --start` accepting whole-second timestamps,
and readiness before that query leaves the live stream covering its later
portion. A failed command's partial rows do not prove older timestamps were
covered, so mirrors and catch-up queries may fill that gap; the watermark only
supports exact duplicate checks at its latest timestamp. Fractional ISO 8601
support preserves timestamps used to filter and order NDJSON records. Counting
exact occurrences avoids collapsing distinct but identical records. The
bounded recent-record window deduplicates the reconnect overlap without
retaining the full history. Retaining the previous checkpoint after a failed
catch-up lets a later reconnect retry the unverified gap. Retrying clean EOF
keeps follow mode alive when the stream process ends normally. The final
one-shot query after repeated startup failures recovers logs when `show` works
but `stream` does not. The query launch time plus stream end time define the
latest point jointly covered by the two sources; using the catch-up command's
completion time could skip records created after its snapshot while the stream
is already closed. Bounding captured stderr prevents a long-running
process from retaining diagnostic output indefinitely. Distinguishing
readable output from process exit status avoids discarding useful partial
records and avoids claiming a mirror fallback when no mirror file was
accessible.
