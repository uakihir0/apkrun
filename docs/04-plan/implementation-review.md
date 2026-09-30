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

## IR-017: Normalize locked repository URLs conservatively

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [build-system.md](../05-development/build-system.md) §6.1 |

**Choice.** Lock validation accepts only parseable HTTPS repository URLs
without credentials, queries, or fragments. It normalizes the scheme and
host, removes trailing slashes and a trailing `.git` suffix, and preserves
repository path casing and all other path characters. It removes an explicit
default HTTPS port (`443`).

**Reason.** Git hosting treats the host as case-insensitive, while repository
paths identify the project and should compare exactly. Removing every `.git`
substring or lowercasing the complete URL could make a different repository
appear to match the manifest. A fallback that lowercased unparsable URLs
could also make different malformed paths appear equal; parseable URLs with
an empty host or an out-of-range port must fail too. Hostile review
reproduced these cases; the lock fixtures now ensure they fail. Normalizing
port 443 allows the equivalent HTTPS URLs with and without that default port
to match.

## IR-018: Read dependency declarations from normalized tool output

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [build-system.md](../05-development/build-system.md) §6.1 |

**Choice.** The lock checker obtains Swift package declarations from
`swift package dump-package` and XcodeGen package declarations from its pinned
`dump --type parsed-json` output.

**Reason.** Searching manifest text for `.package(...)` can mistake comments,
multiline strings, variables, or raw string literals for active declarations,
and can miss values brought in by XcodeGen includes. The official tools
evaluate their supported syntax and expose resolved declaration fields, so
the checker compares actual packages and exact requirements rather than
approximate source text.

## IR-019: Derive release test-key markers from committed fixtures

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [build-system.md](../05-development/build-system.md) §3.1; [test-strategy.md](test-strategy.md) §3.3 |

**Choice.** The Release checker derives searchable key encodings, SHA-256
fingerprints, and the image key ID from supported Ed25519 fixtures under
`Tests/Fixtures/signing/`, then scans every file in the app bundle for those
tokens. Unsupported certificate and keystore formats fail the check closed
until their public material can be extracted. The fixture uses the public RFC
8032 Ed25519 test vector; no private key is stored. The `apkrun` and `apkrund`
Mach-O files must contain a parseable embedded Info.plist whose
`APKRunBuildIdentity` is exactly `release`; a missing key fails.

**Reason.** Deriving tokens from the fixture directory means adding a test
key does not require a parallel hard-coded list in the checker. The first
eight SHA-256 bytes, rendered as 16 hexadecimal characters, follow the image
manifest key-ID format in [android-image.md](../02-design/android-image.md)
§10.1. Scanning all bundle files catches raw binary keys and resources with
extensions other than the usual text formats. Rejecting an unsupported
keystore keeps a future JKS fixture from silently weakening the check. A
release artifact without the embedded identity is ambiguous, so the checker
fails closed; linked Mach-O fixtures cover both a present release identity
and the missing-key case.

## IR-020: Validate generators available in the checkout

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [build-system.md](../05-development/build-system.md) §4, §15.1 |

**Choice.** `codegen.sh` runs each §4 generator that is present, including
`generate-project.sh`. Compiler-fail checks run as T1 on a real Apple Silicon
Mac before merge.

**Reason.** The task asks CI to validate generators already introduced while
later tasks own generators and checks not yet in this checkout. Project
generation is ignored output, so it validates the pinned project generator
without creating a committed diff. Compile-fail checks use `swiftc` and are
classified T1 in the test strategy, so they do not run in the hosted T0 job.

## IR-021: Apply the initial five required checks

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [workflow.md](../05-development/workflow.md) §7; [build-system.md](../05-development/build-system.md) §15.1 |

**Choice.** The initial branch-protection baseline requires `workflow-policy`,
`lint`, `codegen`, `build`, and `test-swift`. Planned jobs in §15.1 become
required when later tasks add them.

**Reason.** #062 defines four source-executing jobs and one metadata-only policy
job. Source-executing jobs use fresh GitHub-hosted macOS runners so no
persistent self-hosted machine receives untrusted checkout or execution. The
policy job is required to detect attempts to disable those source-executing
checks. This checkout has no Git remote, so applying repository branch
protection and opening the negative-test pull request remain an external
maintainer step.

## IR-022: Fail closed for unclassified and non-graph build dependencies

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [modules.md](../01-architecture/modules.md) §3 |

**Choice.** The module check rejects SwiftPM targets with no role in the
documented graph, scans their sources with an empty import allowlist, and
requires each graph module target to live at
`Packages/<Module>/Sources/<Module>`. It obtains target names from every
nested `Package.swift` under `Experiments/` using `swift package dump-package`,
and recognizes backtick-escaped Swift imports. Production SwiftPM sources
are scanned even under nested `Tests/` directories unless their manifest
explicitly excludes that path; XcodeGen source roots retain their nested test
directory exclusion. XcodeGen app targets accept only graph products and the
documented non-linking helper target edges; explicit SDK, framework,
Carthage, bundle, or unknown dependency forms fail. A graph-listed external
product is required when its package is declared in the XcodeGen project.

**Reason.** Skipping unknown target roles or XcodeGen dependency shapes would
allow new imports and linked products to avoid the graph check. The package
availability condition preserves the current staged plan: `Sparkle` appears
in the architecture graph, while its XcodeGen package is added by #057. Once
declared in `project.yml`, the product becomes required and an omitted target
edge fails. Matching target ownership to its source path and parsing quoted
identifiers prevents a target or import from borrowing another module's
allowlist. Nested package manifests are parsed by SwiftPM so an allowed
product name cannot hide an experiment target's actual module name.

## IR-023: Validate stable fields in the current Debug version envelope

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #001 and #062; [build-system.md](../05-development/build-system.md) §15.1 |

**Choice.** The product smoke check validates the complete current CLI JSON
key set and stable Debug values, while accepting either a clean seven-digit
commit stamp or the same stamp with `-dirty`.

**Reason.** #061 extended the version envelope with build identity, commit,
configuration, and embedded-runtime metadata, so #001's original two-field
example had become stale and made the required Debug smoke test fail. The
commit stamp is generated from the checkout and can legitimately include
`-dirty` in a local run; all other fields remain exact.

## IR-024: Run pull request CI on fresh GitHub-hosted macOS VMs

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [workflow.md](../05-development/workflow.md) §7; [build-system.md](../05-development/build-system.md) §15.1; [test-strategy.md](test-strategy.md) §§2–3; [environment-setup.md](../05-development/environment-setup.md) §§1, 6; [scripts/ci/check-pr-control-changes.py](../../scripts/ci/check-pr-control-changes.py) |

**Choice.** The four #062 source-executing jobs use the unprivileged
`pull_request` event and GitHub-hosted `xcode-27` runners. Each gets a fresh
macOS VM, checks out the exact head SHA with persisted credentials disabled,
and has only `contents: read`. The workflow does not reference secrets or a
self-hosted runner. It runs T0 Swift tests; T1 suites and the GUI product
smoke check run on a real Apple Silicon Mac before merge. A separate
`pull_request_target` workflow runs `workflow-policy` for PRs to `main`; it
checks out `refs/heads/main`, reads PR metadata through the API, and never
checks out or executes PR code.

**Reason.** GitHub's
[secure use guidance](https://docs.github.com/en/actions/reference/security/secure-use)
warns against checking out and running pull request code in
`pull_request_target` and against persistent self-hosted runners for untrusted
workflow code. A maintainer-applied label does not make executing fork source
in that privileged event a sound boundary, so the earlier label-gate design
was discarded before commit. The final policy workflow uses the event only to
run trusted `main` code, and requires both a non-author approval review on the
exact head SHA and the `ci-policy-approved` label event before changes to
protected CI paths pass. Rename source and destination paths are checked, and
the checker fails closed at the GitHub compare API's 300-file limit. A fresh
hosted VM limits persistence between source-executing jobs and avoids giving fork
code access to a reusable runner. GitHub's `xcode-27` runner entered Public
Preview on 10 September 2026; its standard image has 3 M1 cores, 7 GB RAM, and
14 GB SSD. Larger suites may need an adequately sized hosted runner before
they are added to this workflow. The runner availability and resource limits
are documented in
[GitHub's macOS 27 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-27-Readme.md).
The policy self-test verifies the trusted base-branch workflow and exercises
the metadata decision logic. Applying branch protection and validating a
negative PR still require repository access. GitHub runner groups can pin
workflow access to a branch; do not register the planned persistent Macs
until the owner pins access to a separate trusted workflow on
`refs/heads/main`. If this account cannot enforce that policy, leave those
runners disconnected.

## IR-025: Guard required CI workflows against pull request edits

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [workflow.md](../05-development/workflow.md) §7; [build-system.md](../05-development/build-system.md) §15.1; [environment-setup.md](../05-development/environment-setup.md) §6; [test-strategy.md](test-strategy.md) §3 |

**Choice.** The required `workflow-policy` check runs from trusted `main` on
`pull_request_target` for PRs to `main`. It fetches the current PR metadata,
changed paths, and review history through read-only GitHub API endpoints. It
does not fetch or run PR source. It compares event and API head/base revisions,
then reads the revision again after fetching changed paths and reviews. Changed
paths come from
[GitHub's commit comparison endpoint](https://docs.github.com/en/rest/commits/commits#compare-two-commits)
using the captured base and head SHA pair, so they remain bound to that
immutable revision even if the PR temporarily moves while the check runs.
Changes to workflow/local-action directories, CI/code-generation/test scripts,
Xcode build-phase scripts, Gradle wrappers/build logic including `buildSrc` and `build-logic`,
per-module Gradle lockfiles, Swift resolution and third-party lock files, tool-version
and Xcode pins, formatter settings,
every Swift and Cargo manifest and lockfile, Rust toolchain, Cargo config,
rustfmt and Clippy config, every XcodeGen `project.yml`, all `Tests/` and
`UITests/` trees, the module dependency graph, any `scripts/check-*` file, and
named build scripts require a non-author human
approval review on the exact current head. That same reviewer must apply
`ci-policy-approved`. Removing the label revokes the policy check; a new
commit, reopen, later label event, or PR edit requires the reviewer to remove
and reapply it.

**Reason.** Required GitHub Actions jobs can be bypassed if a pull request
edits their workflow definition to skip them. Repository-local tests cannot
protect a workflow from edits in the same pull request. The separate base-code
job checks the control-path diff before those source-executing jobs can satisfy
branch protection. The review and label are tied to the current commit and
base revision; file renames check both paths, and an oversized/truncated API
response or a revision change during verification fails closed. The compare
endpoint returns at most 300 changed files; a 300-file response is treated as
potentially truncated and fails closed. Requiring the approver to apply the
label makes the policy actor explicit without granting
the workflow broader repository permissions. The label is a narrow
control-file approval and does not replace the normal pull request review or
approval rules. GitHub runs `pull_request_review` workflows from the PR merge
commit, so the policy does not subscribe to that event and execute a
PR-controlled workflow definition in its metadata-only gate, following
[GitHub's event security guidance](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).
The policy label is the separate authorization state: withdrawing that
approval requires removing the label, which reruns the trusted policy
workflow and fails it. Branch protection independently requires an active PR
approval. Negative workflow-edit tests and branch-protection setup remain
unverified without a Git remote.

## IR-026: Define the shared-memory descriptor used by custom virtio devices

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [graphics.md](../02-design/graphics.md) §3.2; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** `SharedMemoryRegionDescriptor` contains a `UInt8 regionID` and a
`UInt64 sizeBytes`.

**Reason.** The custom-device descriptor already exposed a list of shared
memory regions but the design did not define that value's fields. The
macOS 27 Virtualization API identifies each region by an 8-bit ID and a
byte size, so this value mirrors those inputs and leaves validation and VZ
mapping to #063. No shared-memory region is required for v1.

## IR-027: Omit the framework label from the diagnostic summary

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §2; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** `VMDefinitionSummary` omits `VMDefinition.label`.

**Reason.** The label is an unconstrained string supplied by the definition's
caller, while the summary is serialized into logs and diagnostics. The design
does not require this value in the projection, so omitting it avoids logging
user-provided text without losing validation or configuration behavior.

## IR-028: Run framework validation only after local rules pass

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §3; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** Skip `VZVirtualMachineConfiguration.validate()` whenever any
local rule fails.

**Reason.** The VZ builder can reject malformed local values itself, which
would add a misleading `.frameworkRejected` next to the actionable local
failure. The task's `findings(_:)` API is intended to report causes, so the
framework check runs only when its inputs passed the explicit rules.

## IR-029: Reject the test-only disk synchronization mode in production

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §2–§3; [error-catalog.md](../03-reference/error-catalog.md) §5.2; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** `VMDefinitionValidator` rejects `.none` with
`vm.diskSyncModeTestOnly(role)`.

**Reason.** `DiskSync.none` is documented as tests-only, but the original
validation table had no corresponding rule. Enforcing the existing restriction
in production prevents callers from accidentally disabling write
synchronization and gives the failure a typed catalog entry.

## IR-030: Bound and redact caller-supplied diagnostic tokens

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §2–§3; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** Disk roles, console names, and custom device names enter summaries
and failure parameters only if they are at most 64 ASCII letters, digits,
periods, underscores, or hyphens; other values become `redacted`. Kernel and
disk file basenames remain in the summary as specified.

**Reason.** These labels come from configuration owners and can otherwise
contain paths, line breaks, or unbounded text. The allowlist keeps structured
diagnostics bounded and path-free while retaining the documented basename
preview.

## IR-031: Snapshot custom-device descriptors in validated definitions

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §2–§3; [graphics.md](../02-design/graphics.md) §3.2 |

**Choice.** A validated definition wraps each custom device with its captured
descriptor and a strong reference to the underlying model.

**Reason.** `VMDefinition` is a value but its device models are class
instances. Capturing descriptors ensures the values inspected by validation
are the values later passed to a controller, and retaining the model leaves
its future lifecycle implementation available. #063 must forward the added
device operations through this wrapper.

## IR-032: Represent an empty CPU-count intersection explicitly

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §3; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** `cpuCountOutOfRange.allowed` is optional. `nil` means the host's
active CPU count is below VZ's minimum and no CPU count is valid.

**Reason.** Clamping the maximum up to the minimum incorrectly accepted a
configuration that the host cannot run. Encoding an empty intersection avoids
inventing a valid range.

## IR-033: Open real `/dev/null` handles for VZ console validation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §6.3; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** Validation opens `/dev/null` separately for reading and writing
and passes those handles to `VZFileHandleSerialPortAttachment`.

**Reason.** `FileHandle.nullDevice` did not provide valid descriptors for
`VZFileHandleSerialPortAttachment` on the test host and caused an Objective-C
exception during construction. Real opened handles satisfy VZ's attachment
contract without creating pipes that the validator would need to drain.

## IR-034: Generate a missing machine identity during validation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §§2, 4; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** `validate(_:)` generates a machine identifier when the definition
does not contain one, then stores it in the returned `ValidatedVMDefinition`.

**Reason.** Validation and VM construction must use the same identity. Creating
it in the validated value gives the caller one stable value to persist in
`instance.json` and prevents a later builder from silently generating a
different machine identity.

## IR-035: Probe permissions by opening the resolved file

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §3; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** The live file probe resolves symlinks, reads the header through an
opened descriptor, and checks writability by opening without writing. Missing
or non-file URLs use the existing missing-file failures; unreadable kernels
and initrds use their respective missing-file cases.

**Reason.** Open operations test the current process's real access, unlike
metadata-only permission checks, and avoid mutating disk contents. The
existing catalog has no separate non-file or unreadable-kernel code, so the
validator uses its established safe missing-file failures.

## IR-036: Count whitespace-only declarations as empty

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §3; [M00](issues/M00-repository-and-vm-foundation.md) #002 |

**Choice.** A custom-device name or microphone usage description containing
only whitespace is treated as missing.

**Reason.** Trimming before checking avoids accepting values that are
syntactically nonempty but provide no usable name or user-facing permission
explanation.

## IR-037: Limit #002 custom-device validation to descriptor facts

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected documents | [vm.md](../02-design/vm.md) §3; [M00](issues/M00-repository-and-vm-foundation.md) #002 and #063 |

**Choice.** #002 checks that each custom-device descriptor has a nonempty
name and at least one queue. VZ-level device count and configuration checks
remain in #063 with the adapter.

**Reason.** #002's task scope explicitly leaves custom VZ devices out until
#063. Running `VZVirtualMachineConfiguration.validate()` cannot check models
that the builder does not attach, so describing those checks as part of #002
would claim coverage the implementation cannot provide.

## IR-039: Bound console buffering and drain after VZ release

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §6.3; [M00](issues/M00-repository-and-vm-foundation.md) #003–#004 |

**Choice.** `ConsoleChannel` retains at most 64 chunks of 64 KiB. It preserves
the oldest bytes, counts omitted newer bytes in `droppedByteCount`, and does
not finish reading until the VZ driver releases its attachment and the pipe
reaches EOF.

**Reason.** A console stream can outlive or overwhelm its consumer, so an
unbounded in-memory buffer could grow without limit. Preserving the earliest
bytes retains boot diagnostics, while the explicit dropped-byte count lets
later consumers report incomplete logs. Each channel retains the exact VM
queue passed at creation, and detachment is terminal; this prevents callers
from using a different queue or reusing closed handles. Releasing the VZ
objects before closing pipe endpoints avoids racing file handles that the VM
still uses, and EOF draining preserves the last bytes emitted before guest
shutdown.

## IR-038: Keep VZ descriptions in the private diagnostic path

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §13–§14; [M00](issues/M00-repository-and-vm-foundation.md) #003 |

**Choice.** `VMFailure` stores a `VZErrorInfo` value copy containing the
framework error's domain, code, and localized description. The catalog-facing
`underlying` value exposes only domain and code; the description is reserved
for private diagnostic logs.

**Reason.** Keeping the description supports useful framework diagnostics
without adding potentially path-bearing text to user-visible error parameters
or copied catalog details.

## IR-040: Bound incomplete test-guest console records

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §12; [M00](issues/M00-repository-and-vm-foundation.md) #003 |

**Choice.** `TestGuestLineParser` buffers at most 64 KiB for one unterminated
serial line. It discards the overlong line through the next newline, increments
a diagnostic counter, and resumes parsing later records.

**Reason.** Serial input can be arbitrary and may never contain a newline.
Bounding the partial-line buffer prevents a malformed guest from causing
unlimited host memory growth, while discarding only that line lets the harness
continue to observe later checks and completion.

## IR-041: Select the lab signing identity by certificate fingerprint

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.8, [build-system.md](../05-development/build-system.md) §12.4; `scripts/run-gate.sh`; `.github/workflows/integration.yml`, `.github/workflows/nightly.yml` |

**Choice.** T2 and G1 test hosts use the lab's Apple Development team ID and
certificate SHA-1 fingerprint from `APKRUN_TEST_DEVELOPMENT_TEAM` and
`APKRUN_TEST_CODE_SIGN_IDENTITY`. CI reads both values from repository
variables; neither value is committed.

**Reason.** Xcode did not reliably resolve the generic `Apple Development`
identity for a manually signed hosted test bundle. Selecting the certificate
by fingerprint reproduced the successful local T2 signing setup while keeping
personal signing details out of source control.

## IR-042: Disable hardened runtime for the VM test host and bundles

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [build-system.md](../05-development/build-system.md) §§2.5, 12.4; `project.yml` |

**Choice.** `APKRunTestHost`, `IntegrationTests`, and `AcceptanceTests` set
`ENABLE_HARDENED_RUNTIME=NO`. Product targets keep hardened runtime enabled.

**Reason.** XCTest loads the test bundles into the entitled host process.
Disabling the runtime on these test-only targets resolved the host/bundle
signing incompatibility found while bringing up T2, without changing product
target settings.

## IR-043: Keep lab VM tests off pull-request workflows until runner isolation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [build-system.md](../05-development/build-system.md) §15.1, [workflow.md](workflow.md) §§5.1, 7; [test-strategy.md](test-strategy.md) §2.4; [M00](issues/M00-repository-and-vm-foundation.md) #003 |

**Choice.** `linux-guest` runs on pushes to `main` and manual dispatch. It does
not run pull-request source on the persistent `apkrun-lab` runner.

**Reason.** The documented workflow policy requires disposable lab capacity
for pull-request code. No such runner is configured in this environment, so
running fork or unreviewed source on the persistent lab Mac would violate the
runner-isolation rule.

## IR-044: Keep Alpine tooling pins pending license-policy review

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §§4.4–4.6; [build-system.md](../05-development/build-system.md) §6.5; [M00](issues/M00-repository-and-vm-foundation.md) #003 |

**Choice.** Keep the pinned Alpine test tooling (`socat`, `libcrypto3`,
`libssl3`, `readline`, and the two ncurses packages) so later M0 tests can use
the planned guest utilities, but do not expand the tooling license allowlist or
claim that the current license check passes. The license inventory now records
the lock's full expressions, including `GPL-2.0-only WITH OpenSSL-Exception`
for `socat`.

**Reason.** Removing or replacing a task-mandated third-party input, or changing
the license policy, needs maintainer review. Matching the inventory to the
locked Alpine metadata makes the unresolved policy question visible without
misstating a package's license. #003 remains open until the license expressions
are accepted or a compliant dependency set is selected.

## IR-045: Bound reset while a stop callback remains pending

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §9.6; `VMController.swift`; `VMControllerTests.swift` |

**Choice.** A forced stop waits at most the forced-stop timeout for its VZ
completion callback before releasing resources, even if `guestDidStop` arrived
first. `reset()` also waits at most that timeout for an outstanding stop
operation. If a callback is still pending, it keeps the VM in `failed`, retains
the VZ resources, and returns `VMFailure.stopTimedOut`; a later reset can
release the resources after the callback completes.

**Reason.** The VZ completion bridge must not abandon an operation that has
already started. Waiting without a bound would make reset hang indefinitely,
while releasing the VM before its callback could race an active framework
operation. A bounded retry preserves queue and object lifetime safety.

## IR-046: Keep hosted Linux artifacts outside protected Documents

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §4, [build-system.md](../05-development/build-system.md) §12.4; `scripts/run-gate.sh`; `.github/workflows/integration.yml` |

**Choice.** The artifact scripts and local CLI default to
`/tmp/apkrun-test-linux`; local G1 selects `${TMPDIR}/apkrun-test-linux`, and
the T2 workflow selects `$RUNNER_TEMP/apkrun-test-linux`. `APKRUN_TEST_LINUX_DIR`
can select another location. The G1/T2 `xcodebuild` invocations pass the
selected path and `APKRUN_CI` as build settings; the hosted test process reads
them from `APKRunTestHost.app/Contents/Info.plist`.

**Reason.** The signed test host triggered macOS file-access approval while
opening the pinned kernel under a checkout in `~/Documents`. Putting only the
generated guest artifacts in a private temporary directory avoids blocking
the test on that prompt while leaving source and build outputs in the checkout.
An experiment also showed that a shell export alone does not reach the hosted
test process: with the old checkout artifact directory moved away, the test
skipped instead of using the temporary path. Baking the build settings into
the test host's Info.plist makes the selected artifact directory and CI
strictness explicit. A signed T2 boot passed after both checkout and default
temporary artifact paths were moved aside, confirming that the host used the
selected temporary directory.

## IR-047: Handle VZ power input through the PL061 GPIO character device

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §§4, 12, 17; [M00](issues/M00-repository-and-vm-foundation.md) #003 |

**Choice.** Keep the `requestGuestStop()` T2 check and G1 acceptance criteria
unchanged. The test initramfs discovers the GPIO chip labeled PL061 and uses
the pinned `libgpiod` `gpiomon` tool to monitor only the rising edge on offset
6. It confirms the line request by reading the consumer through `gpioinfo`;
that readiness signal precedes the test marker. If the chip or line request
cannot be opened, init reports failure and attempts to power off instead of
continuing without a stop path.

**Reason.** The pinned Alpine 6.18.54 kernel has no `CONFIG_KEYBOARD_GPIO`, and
the prior `button`/`acpid` setup did not handle the VZ event. A captured T2
console showed `gpiochip0 [20060000.pl061]` and a rising event on offset 6
after `requestGuestStop()`. A separate line-6-only T2 run passed. Monitoring
all eight lines could power off for an unrelated input, and accepting both
edges could treat a release transition as a power request, so the implementation
uses only the observed rising edge. The complete T2 suite and ten-boot G1
acceptance test passed in direct `xcodebuild` runs on branch `codex`; the
clean-`main` `scripts/run-gate.sh G1` run remains pending before #003 can close.

## IR-048: Parse the first test marker after an unterminated kernel line

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §12; `TestGuestLineParser.swift`; `TestGuestLineParserTests.swift` |

**Choice.** Search each bounded console line for the unique `APKRUN-TEST:`
marker instead of requiring it to begin at byte zero.

**Reason.** The T2 attachment showed the final kernel message and the first
`/init` marker concatenated without a newline. Requiring a line prefix dropped
`boot ok` even though the guest printed it, causing the boot test to fail.

## IR-049: Bound console shutdown and T2 diagnostic capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §§9, 12; `LinuxTestGuestRunner.swift`; `DevLinux.swift`; `LinuxGuestHarness.swift` |

**Choice.** Register the record parser's oldest-preserving console stream before
starting the guest. T2 also registers a newest-preserving stream for its raw
console attachment, retains the newest 4 MiB, and records each stream's dropped
byte count. Wait at most two seconds for console EOF after shutdown, then cancel
both consumers.

**Reason.** If a VZ stop callback remains pending, VMController safely retains
the VM and pipe, so the console may never reach EOF. A bounded drain lets CLI
and T2 error paths return, while an early parser subscription prevents fast
guest output from being missed. Keeping a separate newest-preserving stream
lets the parser retain ordered startup records while the attachment retains
recent failure details. Per-stream loss counts show when either bounded buffer
discarded output, and the bounded attachment prevents a noisy guest from
growing test-host memory without limit.

## IR-050: Retain failed Linux guest controllers until reset succeeds

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §§9, 12; `LinuxGuestHarness.swift` |

**Choice.** T2 cleanup re-reads the controller state after attempting a stop,
then attempts `reset()` if the stop moved it to `.failed`. If the controller is
still not `.stopped`, the harness retains it and retries stop/reset in the
background until the VM resources are released.

**Reason.** A bounded VZ completion wait can expire before the framework
callback arrives. Returning from the test while dropping the controller would
release the lifecycle owner too early and could leave framework resources
active during later tests. Retaining the owner allows a later retry to complete
resource release without making the failing test wait indefinitely.

## IR-051: Resolve relative Linux artifact paths from the working directory

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §12; [environment-setup.md](../05-development/environment-setup.md) §4; `fetch-test-linux.sh`; `build-test-initramfs.sh`; `DevLinux.swift`; `LinuxGuestHarness.swift` |

**Choice.** Require `APKRUN_TEST_LINUX_DIR` overrides to be absolute paths in
the artifact scripts, development CLI, and hosted T2 tests. The scripts reject
relative values, the CLI returns `runtime.devLinuxArtifactDirectoryMustBeAbsolute`,
and the hosted test reports the same requirement.

**Reason.** The scripts, CLI, and hosted test can run from different working
directories. A relative value could therefore point to different locations and
make a successful artifact build invisible to the VM runner. Requiring an
absolute path gives all entry points the same location independently of their
working directories. Defaults and CI already use absolute paths.

## IR-052: Track one unrepeatable missing boot marker

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [vm.md](../02-design/vm.md) §§12, 17; `LinuxGuestHarness.swift`; `ConsoleChannel.swift` |

**Choice.** Make no timing or buffering change after one full T2 run whose
raw `hvc0` attachment contained `APKRUN-TEST: done` but not `boot ok`. Keep
the evidence in the verification log and keep the test assertion strict.

**Reason.** The guest init script writes both records in order, neither
console stream reported dropped bytes, and the same signed T2 test passed
once in isolation, ten consecutive repetitions, and the next full T2 run.
There is not enough evidence to attribute the missing bytes to guest shutdown,
the parser, or console buffering. Adding a delay or retry to make the test
green could hide lost serial output; maintainers should review the evidence
and re-open the investigation if it recurs.

## IR-053: Record libgpiod's library and tool licenses

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §4; `ThirdParty/ThirdParty.lock.json`; `ThirdParty/licenses/alpine-libgpiod/` |

**Choice.** Lock Alpine's `libgpiod` package as
`GPL-2.0-or-later AND LGPL-2.1-or-later`, and include its upstream `COPYING`,
GPL-2.0-or-later, GPL-2.0-only, LGPL, Linux syscall-note, and CC-BY-SA
license texts. Keep it as downloaded `tooling`; do not expand the tooling
allowlist.

**Reason.** Alpine's package metadata names the library license, while upstream
`COPYING` distinguishes the LGPL library from the GPL GPIO tools, including
`gpiomon`. The upstream notice also identifies Linux UAPI headers under the
syscall-note exception. The lock records the library and tool licenses and
retains that exception's text for review; its `GPL-2.0-or-later.txt` source
path is recorded with a dereferenced copy of the shared GPL text. Maintainers
should confirm whether the syscall exception applies to the packaged binaries
before #003 closes. Upstream also licenses its copied text files under
CC-BY-SA-4.0; that text is included for the committed notices. The package is
confined to the test guest and never enters APKRun.app.
