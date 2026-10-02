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
fingerprints, and the image key ID from supported Ed25519 fixtures and the
synthetic AVB RSA fixture under `Tests/Fixtures/signing/`, then scans every
file in the app bundle for those tokens. Unsupported certificate and
keystore formats fail the check closed until their public material can be
extracted. The Ed25519 fixture uses the public RFC 8032 test vector. The
`apkrun` and `apkrund` Mach-O files must contain a parseable embedded
Info.plist whose `APKRunBuildIdentity` is exactly `release`; a missing key
fails.

**Reason.** Deriving tokens from the fixture directory means adding a test
key does not require a parallel hard-coded list in the checker. The first
eight SHA-256 bytes, rendered as 16 hexadecimal characters, follow the image
manifest key-ID format in [android-image.md](../02-design/android-image.md)
§10.1. Scanning all bundle files catches raw binary keys and resources with
extensions other than the usual text formats. The AVB fixture's generated
PKCS#8 private key and matching AVB public-key blob are also scanned.
Rejecting an unsupported keystore keeps a future JKS fixture from silently
weakening the check. A release artifact without the embedded identity is
ambiguous, so the checker fails closed; linked Mach-O fixtures cover both a
present release identity and the missing-key case.

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
the T2 workflow selects `$RUNNER_TEMP/apkrun-test-linux`. An
`APKRUN_TEST_LINUX_DIR` override must be absolute and outside `~/Documents`.
The fetch/build scripts and hosted test reject a Documents path, including
symlink aliases, before accessing guest artifacts. The G1/T2 `xcodebuild`
invocations pass the selected path and `APKRUN_CI` as build settings; the
hosted test process reads them from `APKRunTestHost.app/Contents/Info.plist`.

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

## IR-061: Reject T2 artifacts inside protected Documents

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #003; [environment-setup.md](../05-development/environment-setup.md) §4; [build-system.md](../05-development/build-system.md) §12.4; `scripts/{fetch-test-linux,build-test-initramfs,run-gate}.sh`; `LinuxGuestHarness.swift` |

**Choice.** Keep the `/tmp` and CI temporary-directory defaults. Reject an
absolute artifact-directory override inside the current account's
`~/Documents`, regardless of an overridden `HOME`, in both artifact
preparation scripts and the signed test host. Check the lexical path first,
then resolve symlink components while stopping before any filesystem lookup
inside protected Documents. Resolve the Swift default path through the same
check, so a `/tmp` symlink cannot bypass it. Fail before creating or opening
guest artifacts.

**Reason.** A stale or explicit override into Documents is a reproducible
source of macOS file-access prompts. The exact path behind the reported
interruption was not established, so this guard covers both direct paths and
symlink aliases without claiming that they caused that particular prompt.
Using the account database home prevents a caller-controlled `HOME` from
disabling the check. The `/tmp` defaults keep normal local and CI runs
unprompted and preserve custom artifact paths elsewhere.

**Residual risk.** A same-user process could rename or replace an ancestor
after validation and before a later shell or Virtualization.framework open.
The guard is intended to prevent accidental TCC prompts from configured paths;
it does not claim to protect against a concurrent same-user path swap.

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

## IR-054: Pin the complete mkbootimg import set

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #008; [build-system.md](../05-development/build-system.md) §6.4; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.3; `ThirdParty/ThirdParty.lock.json` |

**Choice.** Vendor and hash
`gki/generate_gki_certificate.py` with `mkbootimg.py` and
`unpack_bootimg.py`, all from the same pinned AOSP commit.

**Reason.** The pinned `mkbootimg.py` imports the GKI helper at module load,
even when the fixture generator does not request a GKI signature. Omitting it
would make the official tool fail to start in a clean checkout. Keeping the
helper at its upstream path and locking its hash preserves the exact upstream
import closure without patching vendored code.

## IR-055: Bound image metadata reads and label branch provenance

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [android-image.md](../02-design/android-image.md) §2.2–§3.1; [M01](issues/M01-android-bring-up.md) #008; `Images/tools/apkrun_image/{fetch,inventory,lp,sparse}.py` |

**Choice.** Limit parsed liblp metadata and vbmeta descriptor tables to
16 MiB, sparse logical images to 64 GiB, and vendor ramdisk tables to 16 MiB
and 4096 entries. Reject sparse chunks that exceed the declared expanded
block count before calculating their CRC, and combine repeated-pattern CRCs
in logarithmic time. Reject liblp extents, device sizes, and filesystem sizes
that exceed their containing image. Record `fetch.json.branchProvenance` as
`caller-asserted`. Copy and verify bytes in a private staging directory, make
the file read-only, and atomically hard-link it to the final name; never
replace an existing path or expose partial bytes at that name. When an
existing file has no verifiable API or prior-manifest digest, preserve it and
ask the user to move it aside or use the documented manual verification path.

**Reason.** The inventory handles untrusted image bytes and should reject
malformed dimensions before allocating or doing input-sized work. The design
does not specify parser resource ceilings, so these limits are conservative
implementation bounds above the selected image's expected sizes. The Build
API lookup used here is keyed by build ID and target; the tool does not
independently prove that the supplied branch names that build. The provenance
field prevents the local manifest from overstating what was verified.
Private staging keeps incomplete bytes away from the final name, and atomic
hard-link publication cannot clobber a pre-existing artifact. If a final path
changes after publication, error handling leaves the replacement untouched.
Rejecting an unverifiable pre-existing file avoids silently replacing user
data when the API provides no digest.

## IR-056: Keep the synthetic AVB signing key with other test keys

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #008; [build-system.md](../05-development/build-system.md) §3.1; [security-model.md](../01-architecture/security-model.md) §7 |

**Choice.** Store the synthetic RSA private key and its derived AVB public
key in `Tests/Fixtures/signing/`. Extend the release checker to recognize and
scan PKCS#8 RSA fixture material and Android AVB public-key blobs.

**Reason.** The vendored AOSP `avbtool.py` needs an RSA key to build the
required chain-partition descriptors. The repository rule keeps test signing
material in one reviewed fixture directory. The existing release checker
recognized only Ed25519 public keys, so it now scans the new formats instead
of rejecting the fixture or leaving its public material unchecked. The key
is generated only for tests and has no production use.

## IR-057: Classify bounded vendor boot v3 images

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [android-image.md](../02-design/android-image.md) §3.1; [android-image-manifest.md](../03-reference/android-image-manifest.md) §4.4; [M01](issues/M01-android-bring-up.md) #008 |

**Choice.** Inventory v3 and v4 vendor boot images when the header, ramdisk,
and DTB ranges fit the file. Parse the ramdisk table and bootconfig fields
only for v4. Keep the Android image manifest and runtime support gate at v4.

**Reason.** Inventory describes what an archive contains, including older
standard image headers; safely classifying v3 is more useful than treating it
as unknown. Runtime bring-up still requires v4 as specified by gate M6, so
this parser behavior does not broaden the supported guest image format.

## IR-058: Version inventory details for validated AVB footer fields

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [android-image-manifest.md](../03-reference/android-image-manifest.md) §§4, 10; [android-image.md](../02-design/android-image.md) §3.1; `Images/tools/apkrun_image/inventory.py` |

**Choice.** Emit the AVB footer's `vbmetaSize` and `version` alongside
`originalSize` and `vbmetaOffset`, and raise the inventory schema version from
1 to 2. Require supported footer version 1.0 and validate its image bounds
before adding it to the inventory.

**Reason.** The extra fields make inventory evidence more useful and can be
validated against the pinned AOSP footer layout. Inventory consumers reject
unknown fields and rely on the version to understand the exact shape, so
silently extending version 1 would violate the documented contract. The
committed inventory is regenerated in the same change.

## IR-059: Carry checked fetch provenance through the inventory

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [android-image.md](../02-design/android-image.md) §2.2–§3.1; [android-image-manifest.md](../03-reference/android-image-manifest.md) §4; [environment-setup.md](../05-development/environment-setup.md) §3.2 |

**Choice.** When the inventory command receives a download directory with one
archive and `fetch.json`, inventory that archive, verify its recorded size
and SHA-256, and copy build ID, target, and caller-asserted branch provenance
into the inventory source. Keep ordinary unpacked directories as directory
inventories.

**Reason.** The documented #008 command passes the download directory.
Treating it as a generic directory would inventory the ZIP file and
`fetch.json` instead of the files inside the archive. Carrying the checked
fetch fields also gives the #009 manifest generator the branch, target, and
build ID required by the documented `--inventory`-only command.

## IR-060: Bound and stabilize inventory input handling

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [android-image.md](../02-design/android-image.md) §3.1; [android-image-manifest.md](../03-reference/android-image-manifest.md) §4.5–§4.7; [M01](issues/M01-android-bring-up.md) #008 |

**Choice.** Read the EROFS block count at byte offset 36. Limit archives to
16 GiB and 4096 entries, the central directory to 64 MiB, a ZIP64 end record
to 1 MiB, individual files to 16 GiB, and total expanded input to 64 GiB.
Read standard ZIP/ZIP64 directory bounds, scan and count actual central-
directory records before loading them into `zipfile`, then verify the actual
count against the end record. Reject ZIP64 extensible data sectors, which the
pinned Python reader does not safely support. Resolve ZIP64 self-extracting
prefixes from the record located immediately before the locator. Bound Build
API JSON responses to 1 MiB, listings to 100 pages, and page tokens to 4096
characters; accept only integral artifact sizes. Open directory members
relative to directory descriptors without following symlinks, and verify the
same file version is hashed and classified. Reject inventory output inside
the input tree before creating output directories. Serialize fetches by
flocking the output parent directory descriptor, with no sidecar lock path.
This keeps the lock stable if an output directory is replaced and serializes
sibling output directories. Remove only the verified partial inode by
atomically moving it to a private quarantine name before unlinking.

**Reason.** Image archives and unpacked trees are untrusted input. These
ceilings bound metadata allocation, decompression, and total work while
remaining above the selected build's size. Stable descriptor-relative reads
prevent path swaps from redirecting inventory outside the input tree. Reading
and parsing one unchanged file keeps the recorded hash and details consistent.
Bounding API metadata prevents an oversized response or unending pagination
from consuming unbounded memory or time. Locking the parent inode avoids a
replaceable sidecar lock and the macOS `O_CREAT|O_NOFOLLOW` race reproduced
with concurrent lock-file creation. It does serialize different outputs under
the same parent. Quarantine cleanup avoids deleting a replacement that
appears between an inode check and unlink.

## IR-062: Derive the pinned manifest from inspected build metadata

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected documents | [android-image.md](../02-design/android-image.md) §3.2; [android-image-manifest.md](../03-reference/android-image-manifest.md) §§5, 8; [M01](issues/M01-android-bring-up.md) #009; `Images/manifests/16373615/android-image.json` |

**Choice.** Generate the pinned manifest from the committed inventory and
inspect the source archive. Include all nine non-empty liblp partitions,
including `system_b`, even though the prior abbreviated example listed only
slot-A partitions. Derive artifact identifiers from discovered paths and
strip the conventional `cuttlefish_example_` prefix so the custom partition
uses the stable ID `custom`. Record the boot header's security patch month,
`2026-06`, in place of the example's illustrative `2026-09`.

**Reason.** The manifest must describe every non-empty logical partition and
the source build's actual metadata. `system_b` has a non-zero 4,747,264-byte
filesystem, and the inventory reports `2026-06` in both boot headers. The
prefix mapping keeps the source archive's custom image usable under the
manifest's concise artifact ID convention. The generated manifest matches
the archive and inventory byte for byte; the maintainer review step remains
pending.

## IR-063: Require complete vbmeta artifact role coverage

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected documents | [android-image-manifest.md](../03-reference/android-image-manifest.md) §§7–8; [M01](issues/M01-android-bring-up.md) #009; Python and Swift manifest validators |

**Choice.** Require every source-inventory file classified as `vbmeta` to
appear as a `kind: vbmeta` artifact and in `roles.vbmeta`. Order available
child artifacts by the chain descriptors in the top-level image, and validate
that the role array preserves that exact descriptor order. Do not
require every chain descriptor to have a corresponding artifact in the
downloaded set. Run role completeness only after the first role entry has
been validated as the top-level `vbmeta` partition.

**Reason.** An omitted child artifact otherwise disappears from the ordered
chain used by extraction and AVB checks. The pinned build's top-level image
also has descriptors for boot and init_boot that are not separate vbmeta
artifacts, so requiring every descriptor to have an artifact would reject
valid input. The source-inventory check also catches a child omitted from
both the artifact list and role chain. The top-level descriptor order is
preserved because downstream AVB digest calculation consumes the chain in
that order. Deferring role completeness when the top-level entry is malformed
avoids a redundant M11 diagnostic after the more specific M3 role-kind
failure. A hostile review found that the file-backed validator previously
accepted a manifest with two child roles swapped; a regression check now
reverses the pinned build's children and requires validation to fail. A child
with no matching chain descriptor retains its specific diagnostic without an
extra order error. The source-omission case is Python-only because Swift
validates a manifest without opening source archives.

## IR-064: Bound artifact transfers and validate redirects

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [android-image.md](../02-design/android-image.md) §2.2; [android-image-manifest.md](../03-reference/android-image-manifest.md) §4.5; [M01](issues/M01-android-bring-up.md) #008 |

**Choice.** Enforce the inventory's 16 GiB per-file ceiling when parsing API
metadata, loading prior `fetch.json` records, verifying existing files,
starting a download, and publishing the partial. Open existing files without
following a final symlink, hash through the opened descriptor with the
declared size as a hard bound, and compare descriptor and path identity before
accepting the result. Finalization reads no more than the declared size plus
one byte before rejecting concurrent growth. Apply redirect validation to
Build API JSON and artifact requests. The CLI permits HTTPS only. The Python
test API must explicitly opt into loopback HTTP, with redirects constrained
to the same loopback origin; HTTPS-to-HTTP redirects remain rejected. A
regression test covers the opt-in boundary, an allowed same-origin loopback
redirect, and rejected external, cross-port, and downgrade redirects. Reject
overlong decimal sizes before integer conversion and convert JSON integer
parser failures into actionable `FetchError` diagnostics.

**Reason.** Inventory rejects a file larger than 16 GiB, so the fetcher must
not download or trust a declaration that inventory will later reject.
Redirecting an API or signed artifact URL to an unsafe origin can expose
metadata or bypass the initial URL checks. Checking each redirect before
opening the next hop keeps remote requests encrypted and retains only an
explicit, same-origin loopback HTTP test path. Descriptor-based hashing and
bounded finalization constrain concurrent file growth and avoid hashing a
replacement opened through the same path. Bounding decimal strings before
conversion prevents malformed metadata from escaping the typed CLI error
path.

## IR-065: Bound vendor_boot table parsing to inventory limits

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.1; [M01](issues/M01-android-bring-up.md) #010; `Images/tools/apkrun_image/bootimg.py` |

**Choice.** Parse only boot/init_boot v4 and vendor_boot v4 for this task.
Validate each section against the source file before reading it. Restrict
vendor page sizes to the pinned `mkbootimg.py` choices, require the table byte
size to match `entry_count * entry_size`, and require fragment ranges to
cover the vendor ramdisk exactly without gaps or overlap. Cap the table at
16 MiB and 4096 entries, matching the existing inventory parser. Decode
fragment names and command lines as UTF-8, matching `mkbootimg.py` and
`unpack_bootimg.py`.

**Reason.** #010 and M6 require these v4 formats. The selected Cuttlefish
archive uses boot page size 4096 and vendor_boot page size 2048; offsets must
therefore follow each format's page-alignment rules rather than fixed
filenames or assumed offsets. A bounded table prevents malformed metadata
from causing large allocations or excessive entry loops. Exact fragment
coverage prevents extraction from silently omitting or duplicating bytes.
UTF-8 text preserves values accepted by the vendored writer. Fixture outputs
are checked against the vendored AOSP unpacker, including a non-empty DTB,
UTF-8 name, and UTF-8 command-line case; the pinned ZIP member streams are
parsed without extracting the full archive.

## IR-066: Cap decompressed kernel output

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.1; [M01](issues/M01-android-bring-up.md) #010; `Images/tools/apkrun_image/kernel.py` |

**Choice.** Stream kernel decompression with a 1 GiB maximum output size.
Limit decompressed output to 8 MiB per legacy LZ4 block, and require each
non-final block to expand to the full block size. Decode concatenated gzip
members and LZ4 frames as one kernel stream.

**Reason.** The kernel section comes from a downloaded archive and may be
malformed. A strict aggregate output ceiling bounds disk use and decompression
work, while chunked decoding avoids loading the complete result into memory.
The per-block bound follows the legacy container's fixed block format, and
concatenated members/frames are valid inputs for the declared compression
formats. The pinned build's 42,031,616-byte kernel section and 42,795,008-byte
effective image size fit comfortably; no source artifact is modified. Keep
the cap reviewable in case later supported Android kernels need a larger image.

## IR-067: Roll back extraction output publication

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.1; [M01](issues/M01-android-bring-up.md) #010; `Images/tools/apkrun_image/extract.py` |

**Choice.** Stage the five extracted files and `extraction.json`, move any
existing known outputs into a temporary backup directory, publish the new
files, and publish `extraction.json` last. If a rename fails, remove files
already published and restore the prior set. Keep the backup directory and
withhold the metadata marker if rollback itself fails.

**Reason.** The output directory may contain files owned by adjacent image
build steps, so replacing the directory as a whole would remove unrelated
outputs. Per-file replacement without rollback can leave a mixture of old and
new boot artifacts after a disk or permission error. A regression test injects
a mid-publication failure and verifies that the previous set and unrelated
files remain intact.

## IR-068: Mark the pinned command-line measurement provisional

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected documents | [android-image.md](../02-design/android-image.md) §§4.1, 6.4, 8; [M01](issues/M01-android-bring-up.md) #010; `Images/tools/layouts/cuttlefish-phone-arm64.json` |

**Choice.** Record the pinned build's 157-byte command line from the real
extraction with only the required `console=hvc0` layout addition, and label it
provisional. Do not add any other reference-derived command-line arguments or
layer-2 bootconfig values while `Images/reference/16373615/target/` is absent.

**Reason.** The design identifies the #064 target capture as the source for
those values. Guessing them would make the recorded measurement and layout
look complete without evidence. The measurement confirms the current vendor
and boot command lines plus the mandatory console fit the limit; the final
command-line length and reference-backed layout remain open until that capture
exists.

## IR-069: Enforce bootconfig parser structure limits

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected documents | [android-image.md](../02-design/android-image.md) §6.1; [M01](issues/M01-android-bring-up.md) #010; `Images/tools/apkrun_image/bootconfig.py` |

**Choice.** Count one node for every distinct component in dotted keys and one
value node per key, and reject a merged block above 1024 nodes. Parse full-line
and inline `#` comments, but reject array and statement-separator syntax
because the layer model stores one string value per key. Require the
`bootconfig` command-line token before `--`.

**Reason.** The documented kernel parser limit is structural as well as
byte-based, so a small block with many short keys can still fail during boot.
The documented 1024-node bound is applied conservatively across kernel
branches. Treating arrays as strings would change their meaning, and a
`bootconfig` token after the kernel command-line separator is not an enabling
option. These boundaries are covered by independent node-count, comment,
array, and separator tests.

## IR-070: Include footer-backed images in the AVB chain digest

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected documents | [android-image.md](../02-design/android-image.md) §6.2; [android-image-manifest.md](../03-reference/android-image-manifest.md) §9; [M01](issues/M01-android-bring-up.md) #010; `Images/tools/apkrun_image/avb.py` |

**Choice.** Follow the top-level vbmeta chain descriptors in descriptor order.
Use `roles.vbmeta` to validate the relative order of raw vbmeta artifacts, and
resolve other chain entries, including `boot` and `init_boot`, through their
manifest artifacts and AVB footer offsets. Hash each AVB0 header,
authentication block, and auxiliary block, excluding partition padding and
the footer. Report AVB version 1.4 from the pinned toolchain, and default the
hashtree error policy to `restart_and_invalidate`. Reject a top-level vbmeta
with `VERIFICATION_DISABLED`.

**Reason.** The pinned Android build has AVB footers on `boot.img` and
`init_boot.img`, while the manifest correctly classifies those files as
`bootImage` artifacts rather than adding them to `roles.vbmeta`. Omitting their
footer-referenced metadata produces a digest that differs from the vendored
`avbtool`. Descriptor order reproduces that tool's chained-image digest. The
manifest does not encode the runtime libavb version or hashtree error mode, so
the pinned toolchain version and explicit fail-closed policy are deterministic
defaults pending maintainer review and the #064 reference capture. A vbmeta
that disables verification cannot supply the AVB-derived boot properties:
libavb deliberately emits none, so APKRun fails instead of generating values
that could misrepresent the image's verification state.

## IR-071: Keep reference-capture YAML dependency-free

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/{normalize.yaml,compare_boot.py}` |

**Choice.** Store normalization rules and expected differences as
JSON-compatible YAML and parse them with Python's standard `json` module after
removing full-line YAML comments.

**Reason.** The reference tool needs only objects, arrays, strings, and numeric
schema versions. Adding a YAML parser solely for this configuration would add
a dependency to the image tooling and its third-party lock. JSON documents are
valid YAML, remain easy to review, and keep the parser surface small. The T0
tests exercise comments, normalization rules, and expected-difference entries.

## IR-072: Do not synthesize reference captures or silently change GPU profile

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture.sh` |

**Choice.** Keep the `target` profile on the documented `drm_virgl` flags and
do not check in fake profile directories when no Linux Cuttlefish host is
available. A `target` run that cannot start is retained as incomplete with
`MISSING.txt` and a nonzero status; the `guest_swiftshader` fallback and its
source-derived graphics properties must be selected and recorded explicitly
on the reference host.

**Reason.** The three committed profiles are ground truth used by #010–#014
and R-06/R-11. Synthetic outputs can test the tooling but cannot establish
boot behavior. Automatically replacing `drm_virgl` with SwiftShader would
make a profile appear to represent the target configuration while omitting
the required graphics properties from the pinned Cuttlefish source. The
current macOS checkout has no `launch_cvd` or `adb`, so real captures and boot
timings remain unverified.

## IR-073: Isolate Cuttlefish capture ownership and bound published artifacts

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8; [environment-setup.md](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/{capture.sh,compare_boot.py,normalize.yaml}` |

**Choices.**

- Launch one explicit Cuttlefish instance in a private temporary CVD `HOME`
  and base directory, connect ADB to that instance's loopback port while
  waiting for boot, and disconnect that serial before group removal with a
  10-second timeout and 2-second forced-stop grace period. Assign a unique CVD
  group name and remove only that group, including after a failed launch. Bound
  `cvd remove` to 120 seconds by default with a 10-second forced-stop grace
  period. The private `HOME` is removed after successful cleanup and retained
  for inspection or cleanup if removal fails.
- Use one atomic capture lock directory under `/tmp` so separate checkouts and
  users on the reference host cannot run overlapping profiles. A forced kill
  may leave this shared lock; the setup guide records the safe cleanup step.
- Store the footer-stripped internal bootconfig as UTF-8 text so it receives
  the same secret normalization and bootconfig comparison as guest
  `/proc/bootconfig`.
- Redact complete quoted secret values, underscore/camel-case compound secret
  keys, and common host paths including `/run`, `/var/...`, `/srv`, and
  `/usr/local/google/home` in host-only capture files.
- Reject gzip artifacts whose compressed input or decompressed output exceeds
  64 MiB. Write reports through atomic file replacement so a report symlink
  cannot redirect writes.
- Scope host logs and config copies to the chosen instance directory, filter
  crosvm command lines by the private runtime path, and record individual
  file-copy failures in `MISSING.txt`.
- On abnormal exit, remove any raw logcat file before normalization. If it
  cannot be removed, try to discard the entire stage and never publish it.
  Report the private staging path for manual cleanup if the host filesystem
  also refuses stage deletion. Otherwise normalize and retain the stage as
  incomplete; normalization failures also prevent publication.

**Reason.** A sole-device ADB snapshot does not establish which launch owns
that device, and an unqualified shutdown can affect another Cuttlefish guest.
Cuttlefish keeps group registration outside its runtime directory, so a private
`HOME` alone does not isolate group lifecycle operations. A unique group name
lets cleanup target only this run; a private base directory keeps its runtime
artifacts beneath the temporary `HOME`. The explicit instance number provides
identity for launch and ADB selection. Connecting and disconnecting the
selected loopback serial makes capture independent of a prior manual
`adb connect` and avoids leaving a stale host-side device after shutdown. The
bounded disconnect ensures a stuck ADB command cannot prevent group cleanup.
The runtime path is also required when selecting a crosvm process; matching the
instance number alone could mix processes from another group.
Separate worktrees and users can share an Android host, so one host-wide lock
in shared `/tmp` prevents overlapping profile captures. A bounded shutdown
lets signal cleanup continue to normalize or discard staging data and release
the lock if `stop_cvd` hangs.
Internal bootconfig values may contain the same identifiers or secrets as
guest bootconfig, so keeping it binary bypassed normalization. Quoted values
can contain spaces, and host logs can include system runtime paths outside the
home and temporary roots. Finally, compressed logs are untrusted input and
may be unusually large or expand far beyond their on-disk size; separate
fixed caps keep normalization bounded. Atomic replacement protects files
outside the report directory even when an existing report name is a symlink.
Raw logcat remains unnormalized until compression; refusing publication when
it cannot be deleted prevents that private data from entering an incomplete
capture. If the filesystem prevents both file and stage deletion, the script
cannot remove those bytes but reports the remaining path and still refuses
publication. A forced kill can leave a stale `/tmp` lock, which the setup
guide explains how the lock owner or an administrator can remove after
confirming that no capture is active.
T0 coverage exercises these boundaries, while real host behavior remains
subject to the open #064 T3 run.

## IR-074: Keep the initial device layout free of unverified reference values

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected documents | [android-image.md](../02-design/android-image.md) §§4.1, 6.2, 6.4; [M01](issues/M01-android-bring-up.md) #010; `Images/tools/layouts/cuttlefish-phone-arm64.json` |

**Choice.** Commit the initial phone layout with only the image bootconfig
values already decided or verified by the design and ADR-0015, plus the
mandatory `console=hvc0` command-line addition. Omit every key marked
`reference` until the #064 `target` capture exists, and leave AVB-derived
properties to `avb.py` rather than duplicating them in the static layout.

**Reason.** `extract` requires the committed default layout, and the selected
image has a usable baseline from source and accepted boot decisions. The
reference-dependent values cannot be established on this macOS host because
no Linux Cuttlefish reference VM is available. Shipping this incomplete
baseline makes extraction reproducible while keeping guessed boot properties
out of the image. The Android bootconfig is not complete until the reference
capture fills the omitted entries; #010 remains open.

## IR-075: Normalize manifest decoding errors without echoing input values

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected documents | [android-image-manifest.md](../03-reference/android-image-manifest.md) §12; [M01](issues/M01-android-bring-up.md) #009; `Images/tools/apkrun_image/manifest.py`; `Packages/ImageCore/Sources/ImageCore/Manifest/{AndroidImageManifest.swift,AndroidImageManifestValidator.swift}` |

**Choice.** Convert `DecodingError` cases into `ImageFailure.manifestInvalid`
with the manifest field path, the expected static type where available, and a
short remediation. Do not include `DecodingError.debugDescription` or raw
input values in the reported reason. Escape control, quoting, and
bidirectional-formatting characters in input-derived field-path components,
unknown JSON field names, invalid `androidInfo` keys, and other displayed
values; limit each displayed value to 128 Unicode scalars. Python manifest
checks use exact full-string build ID matching and escape manifest-controlled
values in schema, semantic, and file-backed diagnostics.

**Reason.** ImageCore promises one typed failure for invalid manifests, while
decoder diagnostics may include attacker-controlled content. Unknown JSON
field names and `androidInfo` keys are input-controlled too, so raw newlines
could forge additional log lines or visually reorder text. Other invalid
fields can also contain control characters, and decoder paths can include an
arbitrary dictionary key. Escaping and length limits keep diagnostics
single-line, visually stable, and bounded; the field path and expected type
still identify what to fix.

## IR-076: Pass Cuttlefish artifact roots and private runtime paths

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture.sh` |

**Choice.** Require `CVD_HOST_DIR` to name the matching host package and pass
`--host_path`, `--product_path`, `--base_directory`, and a unique
`--group_name` through one shared helper for every profile. Create each group
with `--nostart`, then start it by the unique group name.

**Reason.** The capture uses a private `HOME` to isolate temporary Cuttlefish
state. With the installed Cuttlefish CLI, starting from that empty home fails
to locate the host tools unless both artifact roots are explicit. Cuttlefish
also places runtime data under a global default directory unless
`--base_directory` is passed, but this version's `launch_cvd` wrapper rejects
that option and forwards it to the lower-level start command. Creating the
group without starting it records the private base directory before a
separately selected start. Group cleanup also needs an explicit unique
selector. Passing these values lets all profiles use the pinned build while
keeping runtime files and cleanup scoped to the temporary capture.

## IR-077: Require archive-backed manifest inventory provenance

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected documents | [android-image-manifest.md](../03-reference/android-image-manifest.md) §8; [M01](issues/M01-android-bring-up.md) #009; `Images/tools/apkrun_image/{inventory.py,manifest.py}` |

**Choice.** File-backed manifest validation requires the recorded inventory
source type to be `zip` before comparing its archive name, size, and hash with
`source.archives`. It also compares `source.branch`, `source.buildId`, and
`source.target` against the actual inventory generated from the fetched
archive's `fetch.json`, even if both the manifest and recorded inventory agree
on altered values. Fail closed when actual archive inventory lacks any fetched
provenance field; an absent `fetch.json` is not independent confirmation.
Escape and bound inventory-derived values in diagnostics, and reject control,
format, surrogate, line-separator, and paragraph-separator characters in
fetched archive names before using them as paths.

**Reason.** Manifest generation only accepts an inventory of a fetched
archive, and M10 requires its recorded archive fingerprint to match the
manifest. Accepting `directory` here would let an edited inventory remove its
archive name and fingerprints while retaining fetched build metadata, bypassing
the provenance check. Comparing the build identifiers to the re-read archive
inventory prevents a jointly edited manifest and inventory from overriding
the fetch record. Control, format, surrogate, line-separator, and
paragraph-separator characters in fetched archive names could forge diagnostics
or make a path unencodable, so inventory rejects them before path use. Escaping
metadata values prevents malformed local inventory files from forging log
lines.

## IR-078: Give Cuttlefish a writable copy of the product images

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture.sh` |

**Choice.** Reject symbolic links in the verified `ANDROID_PRODUCT_OUT`, copy
its contents into the capture's private temporary Cuttlefish `HOME`, make the
copy writable, check that the copy contains no symbolic links, re-verify every
manifest-pinned artifact's size and SHA-256, and pass that directory to
`cvd create`.

**Reason.** The first real Cuttlefish launch expanded `super.img` and
`userdata.img` in the product directory and rewrote vbmeta images before the
capture script's integrity check could run. Passing a private writable copy
keeps later profile runs reproducible and leaves the downloaded, verified
artifacts intact. `cp -a` preserves absolute symbolic links, which could make
Cuttlefish write through the copy into the source tree or another target.
Rejecting links before copying, and verifying the copied tree and hashes
before launch, keeps the writable boundary explicit and detects source changes
during the copy. T0 simulates an in-place image modification, verifies the
source remains unchanged, and proves that a modified copy is rejected before
Cuttlefish starts.

## IR-079: Require exact end-of-input for manifest string patterns

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected documents | [android-image-manifest.md](../03-reference/android-image-manifest.md) §§6.1, 8; [M01](issues/M01-android-bring-up.md) #009; `Images/tools/apkrun_image/manifest.py`; `Packages/ImageCore/Sources/ImageCore/Manifest/AndroidImageManifest.swift` |

**Choice.** Append an end-of-input assertion to every anchored string pattern
in the shared JSON Schema. The Swift `matches` helper also requires the
regular-expression match to cover the complete input string.

**Reason.** Regex `$` can match immediately before a final line terminator,
letting values such as archive names or `androidInfo` keys pass despite
violating their documented formats. Applying the exact-end rule across every
anchored pattern closes the same gap for build identifiers, targets,
partitions, hashes, and file paths as well. The schema remains portable and
continues to be the shared source of string constraints.

## IR-080: Bound Cuttlefish startup by the reference boot deadline

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture.sh`; `Images/tools/tests/test_reference_capture.py` |

**Choice.** Start the configurable boot deadline (600 seconds by default)
immediately before `cvd create`. Bound `cvd create`, the named-group
`cvd start`, ADB connection and discovery, `sys.boot_completed`,
`wait-for-device`, and retry sleeps by that same remaining time. Give each
boot command a two-second TERM grace before GNU `timeout` sends KILL. Bound
the initial host-wide `adb devices` preflight separately to ten seconds with
the same two-second grace. If Android is not ready or `wait-for-device`
fails, record the missing guest data and skip further ADB collection. Keep
group removal on its separate shutdown timeout and grace period.

**Reason.** A real reference run spent 1,029 seconds inside `cvd start` before
reporting `VIRTUAL_DEVICE_BOOT_FAILED`; the capture script's former boot
deadline began only after `cvd start` returned and therefore could not bound
this wait. Bounded ADB calls and retry sleeps ensure a stalled server cannot
prevent cleanup before or after VM startup. Skipping guest collection after a
readiness failure avoids replacing the recorded timeout with another
unbounded ADB command. The two-second TERM grace caps time spent waiting for
an unresponsive boot command before forced termination; group removal retains
its longer independent shutdown allowance. The same real run logged an
invalid logical-partition geometry signature, but Cuttlefish continued into
Android service startup and the converted super image had the expected
geometry magic at offset 4096. The available evidence does not show whether
that warning contributed to the later boot failure, so its cause remains open
pending a successful boot.

## IR-081: Verify Cuttlefish command-line records by executable

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture.sh`; `Images/tools/tests/test_reference_capture.py`; `Images/reference/16373615/incomplete/` |

**Choice.** Enumerate PIDs, require `/proc/<pid>/exe` to resolve to an
executable whose basename is exactly `crosvm`, and then require its command
line as rendered by `ps` to contain the selected Cuttlefish instance between
accepted text delimiters. Trim procps's leading PID padding before constructing
the `/proc` path. Remove earlier `crosvm-command-line.txt` files that contain
only the scanner's own `awk` process, and record the unavailable command line
in each affected `MISSING.txt`.

**Reason.** The previous filter searched each full command line for the word
`crosvm`. Its own `awk` program contained that word and the instance path in
its arguments, so failed and timed-out captures could publish the scanner as
the VM's command line. Parsing `comm` from a whitespace-delimited `ps` row is
also ambiguous because Linux process names may contain spaces or change.
Checking the executable target excludes the scanner and similarly named
helpers. The `ps` text delimiters are a best-effort diagnostic heuristic:
commas and colons can occur inside an argument, so this does not prove
NUL-delimited `argv` boundaries and must not authorize an operation. A
regression fixture includes both rows that would match the old filter, uses
procps-style padded PIDs, rejects an instance path embedded in ordinary
surrounding text, and verifies that failed startup records missing crosvm data.

## IR-082: Keep the 600-second reference run inconclusive

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Images/reference/16373615/incomplete/default-20260930T201303Z-17984/` |

**Choice.** Retain the 600-second run as an incomplete diagnostic record and
keep its result separate from the earlier 1,029-second run that reported
`VIRTUAL_DEVICE_BOOT_FAILED`. Record the observed Android-init, `/metadata`,
ADB, and host-graphics messages without naming any as the root cause.

**Reason.** The 600-second run ended when the configured deadline terminated
`cvd start`; Cuttlefish then removed the live instance logs. The guest had
progressed into init and service startup, `/metadata` was later mounted, and
the ADB transport was not stably available. These observations neither
confirm `sys.boot_completed` nor establish a fatal failure. The host's missing
GLES support is also only a candidate until the selected graphics path and
guest-side errors are captured together. Keep the boot cause open until a
repeat run preserves the live logs and ADB server state before cleanup.

## IR-083: Preserve Cuttlefish logs during startup

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8; `Images/tools/reference/capture.sh`; `Images/tools/reference/capture_cvd_start.py`; `Images/tools/reference/compare_boot.py`; `Images/tools/reference/normalize.yaml`; `Images/tools/tests/test_capture_cvd_start.py`; `Images/tools/tests/test_compare_boot.py`; `Images/tools/tests/test_reference_capture.py` |

**Choice.** Run both `cvd create --nostart` and named-group `cvd start` through
a Python helper under the shared boot deadline. The helper schedules
`cvd logs --nopretty` polls 0.5 seconds apart based on each poll's start time,
then streams its output and snapshots each listed log as soon as its path
arrives. Poll snapshots stay in a per-poll temporary directory while the
listing runs. After it exits or is stopped, each complete bounded file
atomically replaces the last snapshot, even if the listing timed out or
returned an error. An incomplete read leaves the previous snapshot intact.
`assemble_cvd.log`, `kernel.log`, and `launcher.log` must each be regular files
beneath this run's private Cuttlefish HOME and are limited to 64 MiB.
Each selected log name is attempted at most once per listing poll after its
path is validated as a regular file beneath the private HOME. An invalid
duplicate row therefore cannot suppress a later valid path.
If a listing takes longer than 0.5 seconds, the next poll starts as soon as it
returns. Final log copies use the same bounded atomic path; a failed copy
leaves the last snapshot intact. `compare_boot.py` limits plain and compressed
inputs, decompressed gzip content, normalized output, and compressed gzip
output to 64 MiB. Before applying each configured substitution, it estimates
the expanded UTF-8 size and rejects a result above the limit before allocating
it. Comparison iterates normalized category lines instead of materializing
`splitlines()` results. JSON and ambiguous command-line redaction enforce the
same output limit while building their results. Each capture is capped at
100,000 records and 64 MiB of key/value text across all categories. Log-listing
paths retain spaces, decoding failures are handled, and child termination runs
in a `finally` path. Rules and expected-difference input must be regular files,
are opened without blocking, and are read with a 1 MiB limit. Capture-tree
walks reject more than 100,000 filesystem entries, and comparison indexes
recognized files once instead of rescanning and sorting the whole tree for
every category. Complete PEM private-key blocks are redacted with a single
linear marker scan whose labels have a fixed length limit.
The log-listing supervisor remains the process-group leader until the group
has been terminated and reaped, so failed commands cannot leave same-group
descendants behind or expose a recycled group ID to cleanup.

**Reason.** Cuttlefish 1.57 removed its live instance logs while cleaning up a
timed-out `cvd start`, before the previous collector ran; a failed create can
also leave logs only briefly. Keeping bounded snapshots in the already-private
capture stage makes failures diagnosable without retaining Cuttlefish HOME.
The integration tests delay the first listing so the old post-return poll
schedule misses short-lived create logs. A helper test streams a listed path,
deletes its source while `cvd logs` is still running, and verifies that the
snapshot survives. Another test removes the source and times out the listing
after a valid snapshot was streamed, verifying that the data is kept.
Other tests cover timed-out start, FIFO rejection, early EOF, paths with
spaces, malformed or oversized log listings, snapshot-preserving copy
failure, safe termination of the listing process group, and shutdown of
TERM-ignoring descendants. Child exit statuses 124 and 137 are mapped to a
normal command failure so only the helper or shared deadline marks a timeout.
Normalization redacts host paths attached directly to one-letter options
across all configured host roots. Quoted JSON paths keep their string
structure: a tokenizer decodes and rewrites escaped JSON string tokens, then
re-escapes the value. For an unquoted space-containing host path in a configured
plain-text host log, a linear token scan applies only to a Cuttlefish
`command.cc` `Started (pid: …):` record. If a later token containing `/`
appears, or any continuation token follows the attached path, it redacts the
path and the ambiguous remainder of that command record. This covers
dash-prefixed components such as `-x/cvd`, `--workspace/cvd`, and a final
component without a slash. A short-option token (`-v`, `-vv`, or `-v=1`) or
`--` immediately followed by a recognized diagnostic phrase preserves it only
when the remaining context contains known connector words and configured host
paths; arbitrary suffix tokens are redacted.
Diagnostic endings at a newline or sentence period are retained, while
filename-like values such as `error.log` and `error:private` do not qualify.
Diagnostic suffix paths are preserved only when they are under a configured
host root and are therefore redacted by the ordinary path rules. Quoted
host-path normalization treats escaped quotes as part of the path value rather
than as the end of the quote; disjoint escape and non-escape alternatives keep
the matcher linear on unterminated input.
The marker uses the first `Started` record on each line. Ordinary diagnostic
records do not use this fallback. The scanner processes log lines
incrementally instead of materializing a line list and avoids
regular-expression backtracking on long records.

## IR-084: Do not infer composite disks from Cuttlefish instance paths

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8; `Images/reference/16373615/incomplete/default-20261001T001530Z-48053/cuttlefish_config.json`; `Images/tools/reference/capture.sh` |

**Choice.** Keep the normalized `cuttlefish_config.json` and record
`composite-disk-specs.json` as missing when the config does not expose a
composite-disk section. Do not synthesize a composite specification from the
instance's individual image paths.

**Reason.** The real pinned Cuttlefish 1.57.0 capture has an `instances` map
and no top-level `disks` object, while the existing synthetic fixture used an
older shape. Individual image paths do not establish the exact
`os_composite` and persistent-composite topology. Keep the missing-data reason
visible until an authoritative source for that topology is verified.

## IR-085: Accept group and instance prefixes in Cuttlefish log labels

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture_cvd_start.py`; `Images/tools/tests/test_capture_cvd_start.py` |

**Choice.** Accept both bare log labels and labels prefixed with a Cuttlefish
group and instance, such as `apkrun_default:1:kernel.log`. Match only the
final component against the fixed set of selected log names. Continue to
require an absolute regular file whose resolved path is beneath the private
Cuttlefish `HOME` before snapshotting it.

**Reason.** The pinned Cuttlefish 1.57.0 `cvd logs --nopretty` command emits
group and instance prefixes. Treating the entire label as a filename silently
ignored its live logs, which could leave no diagnostic record when cleanup
removed the runtime files. The regression test uses the observed prefixed
format in both listing parsing and live snapshot collection, including an
outside path before the valid in-home path.

## IR-086: Redact EUI-64-style IPv6 interface identifiers

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/compare_boot.py`; `Images/tools/tests/test_compare_boot.py`; `Images/reference/16373615/incomplete/default-20261001T120904-49816/cuttlefish_config.json` |

**Choice.** During normalization and comparison, parse IPv6 address candidates,
including compressed, expanded, and IPv4-embedded forms. Replace any address
whose interface identifier has the EUI-64 `ff:fe` marker at the insertion
position with `<EUI64_STYLE_IPV6>`. Preserve other IPv6 addresses.

**Reason.** The Cuttlefish configuration's `ethernet_mac` is redacted by the
existing MAC rule, but its link-local `ethernet_ipv6` encodes the same MAC in
an EUI-64-style interface identifier. The address alone cannot prove that
another matching identifier came from a MAC, so this rule conservatively
redacts all addresses with that byte pattern, including a manually configured
one. This can hide the value of an uncommon non-MAC address with the same
layout, while preserving ordinary IPv6 observations. The broader match keeps
a MAC-derived identifier from bypassing the no-MAC capture requirement.

## IR-087: Give the live log-snapshot test time to observe command completion

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Images/tools/tests/test_capture_cvd_start.py` |

**Choice.** Set the timeout in
`test_collect_logs_snapshots_a_log_before_the_listing_command_exits` to three
seconds. Keep the fake listing command's 0.2-second delay and all assertions.

**Reason.** A full suite run once reached the one-second test deadline after the
log contents had been snapshotted but before the supervisor's completion
status was observed. The log-content assertion passed while the expected
completion entry was absent. A three-second observation window leaves the
test's before-exit behavior unchanged; the separate timeout regression test
continues to cover incomplete listings.

## IR-088: Preserve source whitespace in captured Cuttlefish logs

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064; `.gitattributes`; `Images/reference/16373615/incomplete/` |

**Choice.** Disable only Git's `blank-at-eol` whitespace check for captured
Cuttlefish `.log` files and `cuttlefish_config.json` beneath `Images/reference/`.
Keep the captured file bytes unchanged.

**Reason.** Cuttlefish source logs contain lines ending in spaces, including
empty diagnostic fields, and its generated configuration JSON also retains
trailing spaces. Trimming either would mutate the evidence. Restricting the
attribute to those captured file types keeps whitespace checks active for
source code and other documentation.

## IR-089: Attribute the early Cuttlefish reset to the auxiliary OpenWrt VM

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Images/reference/16373615/incomplete/default-20261001T120904-49816/launcher.log` |

**Choice.** Classify the reset at 11:59:25 as an auxiliary OpenWrt crosvm
reset, not an Android guest reset. Record the distinct process IDs and retain
the Android boot diagnosis as unresolved.

**Reason.** `launcher.log` shows `run_cvd` starting PID 50263 with
`--process_name=openwrt`; its child command uses `cvd-wifiap-01` and
`root=/dev/vda1`. The reset lines are tagged `log_tee(50263)`, followed by a
restart from that process restarter. The separately started Android crosvm is
PID 50271. This process evidence makes the earlier M01 wording misleading;
correcting it avoids treating an auxiliary VM event as evidence of an Android
reboot. The logs still do not identify why Android never registered the
`activity` service.

## IR-090: Isolate the `gpu_mode=none` boot diagnosis

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Experiments/cuttlefish-boot-diagnosis/` |

**Choice.** Compare the pinned default `guest_swiftshader` capture with a
separate `gpu_mode=none` run using the same Android build, Cuttlefish VCS
revision, capture-tool blobs, Linux distribution and kernel, architecture,
host CPU count, nested-virtualization state, Cuttlefish instance number, four
guest CPUs, 4096 MiB, and 600-second boot deadline. Write results outside the
repository by default. Use a dedicated ADB server on a unique private
`localfilesystem` socket. Pass `--gpu_mode=none` to both `cvd create` and
`cvd start`, with `--gpu_vhost_user_mode=off` on both commands, because the
pinned arm64 host otherwise auto-enables a GPU path that is incompatible with
`none`. Require the saved config to show both `gpu_mode=none` and
`enable_gpu_vhost_user=false`. The first real capture still recorded
`guest_swiftshader` after only changing the create command. Cap guest outputs
and live logcat while streaming,
bound control output before parsing, and enforce a 900-second overall runner
deadline with process-group cleanup. Publish only counts and boot-state
samples, and require confirmed capture-process, Cuttlefish, ADB server, ADB
helper process, and live-logcat cleanup before moving the normalized record
into the experiment results directory. Scrub regular and in-progress raw
logcat files before retaining a private failure workspace. If scrubbing fails
while Cuttlefish still needs cleanup, remove the capture and live-ADB output
trees with Python's symlink-safe tree removal. Create an ownership marker with
a per-run random token and the exact workspace path; require the expected
data-root layout, generated workspace name, and marker before deleting output
trees or the full workspace. Apply the same token and marker checks to the
standalone logcat scrub command. Reject control characters in data-root paths
before printing their canonical spelling to the shell. Open directory
components without following symbolic links. Create the data root and its
`work` and `results` children
through descriptor-relative operations with mode `0700`; reject roots whose
ancestors are writable by other users unless a root-owned or current-user-owned
sticky directory protects them. Keep the ownership marker until all other
workspace entries have been removed so a partial cleanup can be retried. If
the final directory removal fails, restore the marker through the opened
workspace descriptor. Retry by generated name only if that name still resolves
to the same workspace; if it changed, preserve the original marker and require
manual cleanup rather than replacing the new entry. If all removal attempts
fail while Cuttlefish remains active,
preserve its runtime and report that manual cleanup is needed; raw logcat may
remain in the private workspace until cleanup succeeds. Once Cuttlefish is
verified clean, attempt to discard the full workspace. Fail closed if the
startup process check cannot run, and keep normalization, final scrubbing,
runtime and ADB cleanup verification, destination checks, and result movement
in one tested publication function. Anchor the final rename to opened source
and destination directories and use Linux `renameat2(RENAME_NOREPLACE)` so a
changed results parent or occupied destination cannot redirect or nest the
published record. Before removal or publication, atomically move the entry to
an unpredictable quarantine name in its opened private parent and compare
the moved inode with the pinned identity. Restore an unexpected entry with a
no-replace rename and fail. After publication, verify the destination inode
and attempt a no-replace rollback if it changed. Treat other processes under
the same user ID as trusted: Linux has no inode-conditional `unlink` or
`rmdir`, and same-user processes can write the mode-0700 data root.

Resolve `/tmp` to its physical directory and create a random mode-0700 short
Cuttlefish HOME root beneath it. Use short `h.XXXXXX` and `p.XXXXXX` children
for the capture and fleet preflight. Do not infer the socket-specific suffix
length from a HOME template: before removing either HOME, audit the actual
filesystem Unix sockets beneath the private temporary tree and the Cuttlefish
UID-wide state directory. Count the filesystem-encoded pathname plus its
terminating NUL against Linux's 108-byte `sun_path` capacity, and record only
counts and maximum lengths. Keep fleet and capture metrics separately in the
published diagnostic record. If a socket path is too long or the audit cannot
complete, preserve the private state and block publication.

Cuttlefish's instance database and server are UID-wide, outside the private
HOME. Do not run `cvd reset` or terminate a shared Cuttlefish server as part of
this experiment. Before deleting a generated HOME, inspect same-UID processes
under `/proc`, verify their owner and start identity, and check environment,
command line, working directory, and open file descriptors for the private
HOME or TMPDIR. Exclude the cleanup caller's ancestry only when each PID and
start time still match. If a process reference cannot be inspected or a
reference remains, retain the HOME and workspace and block publication. One
observed Lima systemd session monitor (`sd-pam`) denies environment reads; skip
it only when its cgroup exactly matches the current user's systemd
`user@<uid>.service/init.scope`. Any other unreadable same-UID process blocks
cleanup. The fleet HOME gets the same process-reference check before removal.
Cuttlefish can leave socket entries in the private temporary tree after its
group stops, so an empty temporary directory is not the cleanup criterion.
After the capture record has copied its logs, verify that no process references
the private tree, repeat the socket audit, and remove only the per-run
`/tmp/x.XXXXXX` tree through one descriptor-relative, no-follow helper,
whether `t/` is empty or populated. Check the root inode before `rmdir` through
the opened `/tmp` directory. Directory symlinks and symlinks to sockets beneath
an audit root block cleanup; regular-file and dangling symlinks are not
followed, and recursive removal unlinks them without following. Restore the
ownership marker if final removal fails. Never delete the UID-wide Cuttlefish
state directory. Preserve and report the private paths if any check or removal
is uncertain.

Capture the supervised command's combined stdout and stderr in a mode-0600
file capped at 1 MiB. Capture the supervisor's own stderr through a private
FIFO into a separate mode-0600 file capped at 64 KiB; keep draining after the
limit so the writer cannot stall. Hold the reader at a startup gate until its
PID and process start time are recorded. Before releasing the gate, open a
pidfd in a dedicated signal broker and verify the start time. Bound
stderr-reader shutdown after EXIT or a signal; route TERM and KILL requests
through the broker's pinned descriptor instead of resolving the PID again.
Preserve the workspace if the reader identity changes, requires a signal, or
does not exit. Incomplete or truncated supervisor stderr blocks publication.
Never include host output in a published result. Retain the private workspace
and report its path when a nonzero capture exit is published, so the bounded
output remains available for diagnosis.

**Reason.** The default capture reached zygote and SurfaceFlinger but did not
confirm `system_server` or `sys.boot_completed=1`; Cuttlefish also reported
graphics capability failures before selecting `guest_swiftshader`. A single
GPU-mode change tests whether that difference correlates with the stall
without promoting a diagnostic run to a canonical reference profile. The
baseline is incomplete and may contain private guest logs, so input identity,
temporary storage, per-command and aggregate byte limits, content-free
summaries, experiment-code hashes, and cleanup are checked before publishing
any result. The random token ties deletion to the current run, and
centralizing publication makes the last cleanup checks observable in focused
tests. Quarantine-and-verify catches replacements present at the atomic move
boundary and prevents those unexpected entries from being silently removed or
published. Safe ancestors plus mode-0700 roots enforce the documented
same-user trust boundary. Requiring the marker for standalone scrubbing keeps
a malformed or mistargeted invocation from deleting a similarly named
workspace's logs. Rejecting Unicode control characters avoids shell command
substitution changing the canonical path and keeps path-output handling
unambiguous. Restoring the marker after a final directory-removal failure
keeps cleanup retryable while the generated name still identifies the opened
workspace. If another same-user process changes that name, cleanup preserves
the marker in the original directory and requires manual cleanup. The remaining
same-user limitation follows from the private directory ownership model and
available Linux filesystem operations. The 2026-10-01 capture verified that passing the GPU
mode only to `cvd create` left the saved configuration at
`guest_swiftshader`; the pinned CLI exposes the same setting on `cvd start`,
so the runner now sets it on both commands. The follow-up record verified
`gpu_mode=none`, four CPUs, and 4096 MiB, but Cuttlefish exited after seven
seconds with no boot-complete or system-server lines and no logcat bytes.
Cleanup completed and no canonical profile was changed. Three hostile review
rounds found five actionable issues; all were fixed, and the final round
reported no findings. The Linux focused suite passed 40 tests, Ruff lint and
format checks passed, shell and Python syntax checks passed, and all six checks
in `scripts/ci/run-checks.sh` passed. Keep these choices marked for maintainer
review.

A sanitized Cuttlefish startup log later reported a requested Unix socket
`sun_path` length of 130 bytes against the 108-byte limit. This occurred before
Android boot and therefore does not explain the Android boot stall. A retry
using a short symlink alias still produced the same error because Cuttlefish
canonicalized its target. The first physical-root attempt restored the pinned
product images and reached Cuttlefish, but still failed with the same socket
length. That run shortened the Cuttlefish HOME while leaving `TMPDIR` pointed
at the long workspace path. The runner now sets both `HOME` and `TMPDIR` to
short physical paths. A later isolated run measured 12 filesystem socket paths
with a maximum of 60 bytes including the NUL, then Cuttlefish reported
`VIRTUAL_DEVICE_BOOT_FAILED`. This measurement covers socket nodes that were
created; it cannot rule out an overlong path from a failed bind that left no
node. The earlier 130-byte request therefore remains unexplained. Cuttlefish
left private socket entries after group removal, so publication correctly
stopped. Cleanup now rechecks process references and socket lengths, then
removes only the token-marked per-run `/tmp` tree; this cleanup and the next
reference run remain subject to maintainer review.

A later real capture showed that Cuttlefish creates dangling and
regular-file symlinks in its temporary HOME for logs and runtime metadata.
Rejecting every symlink prevented the capture audit from writing its metrics.
The revised audit rejects symlinks to directories and sockets, skips only
missing targets and non-directory, non-socket targets, and leaves removal to
the descriptor-relative no-follow walker. A process audit also found that
Lima's `sd-pam` monitor denies `/proc/<pid>/environ`; allow it only with the
exact current-user systemd service cgroup. All other unreadable same-UID
processes block cleanup. Ancestry exclusions now require matching PID start
times so a reused PID cannot be skipped. Empty and populated short HOME roots
both go through the same descriptor-relative remover, and EXIT/signal cleanup
uses a bounded stderr-reader shutdown.

The repeat `gpu_mode=none` capture at
`$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis/results/gpu-none-20261001T165340Z-81386`
measured 12 filesystem Unix socket paths with a 59-byte maximum pathname
(60 bytes including NUL). Cuttlefish again reported
`VIRTUAL_DEVICE_BOOT_FAILED`; the normalized record contains no
`system_server`, boot-complete, or logcat lines. The child exited 1 without
truncation, cleanup completed, no `crosvm` remained, and the marked private
`/tmp` root was removed. Its bounded host output remains in the private
workspace because the capture exited nonzero. This is not a boot success or a
root-cause finding. The focused suites passed 82 tests on Linux and 61 on
macOS, with 21 platform-specific skips; Ruff, shell syntax, and whitespace
checks passed. These new choices remain marked for maintainer review.

The final cleanup review found that the stderr-reader PID could be reused
between a liveness check and pidfd opening, including after `wait` reaped it.
The runner now holds that child behind a startup FIFO until its start time is
recorded, then starts a broker that verifies the identity and retains a pidfd
before the child is released. TERM and KILL requests use that pinned
descriptor. Regression tests confirm a mismatched start time is rejected and
exercise broker TERM delivery through a real Linux pidfd. The focused suites
then passed 85 tests on Linux and 63 on macOS, with 22 platform-specific
skips; the six repository checks passed. A real
Linux retry published
`gpu-none-20261001T170532Z-83150`: 12 filesystem sockets measured at a maximum
of 59 pathname bytes (60 including NUL), capture exit 1, no logcat or boot
completion signals, and verified cleanup. It remains diagnostic evidence,
not a successful boot or a root-cause finding. The final hostile re-review is
pending.

The follow-up replaced shell PID liveness checks with atomic exit and stopped
records emitted by the broker watching its pinned pidfd. Focused suites passed
85 tests on Linux and 63 on macOS, with 22 platform-specific skips; Ruff,
formatting, shell syntax, and whitespace checks passed. A real Linux retry
published `gpu-none-20261001T172756Z-88844`. It measured 12 filesystem sockets
with a 59-byte maximum pathname (60 including NUL), exited 1 without timing
out, and captured no logcat or boot-completion evidence. The stderr reader's
exit record and broker stopped marker were present, its bounded status reported
complete cleanup without a signal, and the run-owned short HOME root was
removed. The normalized record was published, and bounded host output remains
in its private workspace. This still does not establish Android boot success
or a root cause. The hostile re-review of the exit-marker version and the full
repository check are pending.

## IR-091: Verify Lima's protected `sd-pam` process without `/proc/1/exe`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), [AGENTS.md](../../AGENTS.md) §8.2 |

**Choice.** Treat an environment-protected process as Lima's session monitor
only when its `comm` is `sd-pam`, its cgroup is exactly
`/user.slice/user-<uid>.slice/user@<uid>.service/init.scope`, and its first
command-line argument is `(sd-pam)`. Also verify that its parent is the same
UID's `systemd --user` process in that cgroup, and that the parent's executable
matches the installed systemd binary. If the `sd-pam` executable is readable,
it must match the same binary. Keep command-line inspection mandatory; check
the working directory and file descriptors whenever readable, and block
cleanup if either reveals a private-path reference. All other unreadable
same-UID processes still block cleanup.

**Reason.** The Linux reference VM denies access to `/proc/1/exe`,
`/proc/<sd-pam>/exe`, and `/proc/<sd-pam>/environ`. The monitor's parent is
readable and identifies as the current user's `systemd --user` process in the
same service cgroup. Requiring this parent lineage and the actual installed
systemd executable keeps the cleanup exception usable in Lima while rejecting
a Cuttlefish executable that merely adopts the `sd-pam` name and command line.
Regression tests cover the verified parent, a Cuttlefish executable decoy,
other cgroups and command lines, and visible private-path references.

## IR-092: Bound aggregate Cuttlefish log snapshots

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Limit the aggregate size of retained and in-progress Cuttlefish
host-log snapshots to 384 MiB. Each of the three selected logs remains capped
at 64 MiB. If an atomic replacement would exceed the aggregate limit, reject
that snapshot and retain the last complete copy.

**Reason.** Live polling can temporarily keep the previous three-log set while
building a new set before promotion. Six 64 MiB copies bound that atomic
old/new overlap and prevent repeated snapshots from growing without limit.
Counting temporary copies in the stage-wide budget also covers interrupted
poll directories.

## IR-093: Treat truncated supervisor output as incomplete evidence

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** A capture whose private 1 MiB combined stdout/stderr log is
truncated keeps its workspace and cannot publish a normalized result.

**Reason.** Missing later host output can hide the startup or cleanup failure
that explains an incomplete guest capture. The runner already keeps this log
private, so refusing publication preserves diagnostic value without exposing
host output in results.

## IR-094: Reap detached Cuttlefish descendants with Linux subreapers

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Enable Linux child-subreaper mode in each Python capture supervisor
before it starts a Cuttlefish command. After the command exits, terminate and
reap its adopted descendants as well as any remaining members of its original
process group. Treat unverified cleanup as incomplete and block publication.

**Reason.** A Cuttlefish child can create a new session and escape the
supervisor's process group. It may also keep an inherited output pipe open,
which otherwise delays EOF until the long outer timeout. The Linux-only
diagnostic runs one supervised process tree per supervisor. Subreaper adoption
makes orphaned descendants direct children, whose PIDs remain reserved until
this supervisor reaps them; it can therefore signal that owned tree without
scanning and signaling unrelated processes. Regression tests exercise a
detached child that ignores TERM and retains the output pipe.

## IR-095: Pin process leaders until descendant cleanup finishes

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Keep each supervised child unreaped while checking and stopping
its process group and adopted descendants. Reap the child only after cleanup
is complete, or after the final bounded cleanup check fails. Return as soon as
an exited child has no live group members or adopted descendants.

**Reason.** Reaping the group leader releases its PID while cleanup may still
signal adopted children. Keeping it as a zombie reserves the PID and prevents
a newly adopted descendant from reusing that numeric ID and being skipped.
Returning early for an empty tree avoids spending the configured cleanup
grace after ordinary successful commands.

## IR-096: Require EOF before claiming stdin producer cleanup

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** A bounded stdin collector reports `cleanupComplete: true` only
after it observes EOF. A signal or an early byte-limit stop reports incomplete
cleanup; callers that require a verified status keep draining until EOF.

**Reason.** The collector does not own or control the process writing to its
stdin. Closing the read end can make a producer exit, but it cannot prove that
the producer stopped. EOF is direct evidence that every writer closed its end
of the pipe.

## IR-097: Abort pinned-process startup through its gate

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Hold startup gate FIFOs open read/write in the parent, defer
signals while a pinned target is starting, and complete the abort or pidfd
stop handshake before exiting. Verify the target's exit record before opening
the gate. Bound startup abort waits, close the broker channel to trigger its
pidfd owner-disconnect cleanup, and disable the EXIT trap before a signal
handler performs cleanup. Defer watcher startup signals until its PID has
been recorded before normal cleanup begins.

**Reason.** A dead gated target can leave a FIFO writer blocked, and a signal
between fork and PID bookkeeping can otherwise orphan the target. The parent
gate descriptor makes writes nonblocking; the deferred signal lets startup
record the exact child and broker state before cleanup. If the target has not
read the abort token, the closed control channel invokes the broker's bounded
TERM/KILL fallback. A still-stopped direct child is continued only while its
unreaped PID remains reserved, so it can consume the abort token. If cleanup
cannot be verified before the deadline, the workspace is preserved.
Disabling EXIT cleanup prevents a failed stop from repeating the same long
wait during shell exit. Deferring watcher signals closes the same
PID-bookkeeping gap for its direct child.

## IR-098: Trust only a protected systemd executable for the `sd-pam` exception

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Accept the systemd executable used by the `sd-pam` cleanup
exception only when the binary and every resolved parent directory are
root-owned and not group-writable or world-writable. Match the running
executable to that installed binary by device and inode.

**Reason.** Matching a path string or an unprotected user-owned binary would
let the same user create a fake `systemd --user` parent and spoofed `sd-pam`
process. The path ownership and mode checks make that exception depend on the
system installation rather than user-controlled files.

## IR-099: Close inherited descriptors in every background diagnostic worker

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** The ADB watcher, bounded stderr reader, pinned target, and signal
broker close every inherited descriptor numbered 3 or above before starting
their work.

**Reason.** A descriptor above the previously enumerated range can keep a
private FIFO open and delay EOF or cleanup. Applying the same close-all rule
to every background worker avoids relying on a fixed maximum descriptor
number. Tests pass descriptor 32 into the pinned target and broker; shell
contract checks cover the watcher and stderr workers.

## IR-100: Bound broker reaping after its stopped marker

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** After validating the broker's stopped marker, wait for its direct
child process to exit for a bounded interval. If it remains alive, send TERM
and then KILL with bounded exit checks; report cleanup failure even when the
broker is eventually reaped.

**Reason.** The broker publishes the marker before closing its pidfd and
returning. Waiting on the marker alone does not prove that the process has
exited, and an unbounded shell `wait` could hang startup abort or normal
cleanup. The broker PID is still an unreaped direct child, so it remains
reserved while the bounded fallback signals it.

## IR-101: Complete ADB cleanup after startup signals

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Mark the dedicated ADB server as started before startup signal
handoff can reach normal cleanup. Signal cleanup removes its private socket
directory only after the pinned ADB server is verified stopped. Create that
directory in a command substitution that ignores HUP, INT, and TERM until the
path has been assigned.

**Reason.** A signal can arrive after the startup gate opens but before the
caller resumes from the launch helper. Setting the state inside that helper
prevents cleanup from skipping the server. Removing the socket directory only
after verified server exit avoids deleting a live server's endpoint. Ignoring
signals in the short `mktemp` command substitution lets process-group
interrupts finish returning the created path before the parent runs its trap.
Regression tests send both INT and TERM to the isolated process group.

## IR-102: Preserve state when watcher shutdown cannot be verified

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** If the watcher stop marker cannot be written, stop and reap its
unreaped direct child with bounded TERM/KILL checks, mark watcher cleanup
incomplete, and preserve the diagnostic workspace and ADB server.

**Reason.** Without the marker the watcher can continue polling indefinitely
when Cuttlefish never exposes a device. The fallback stops its owned child
without targeting a reused PID. Retaining the workspace and server records
that the watcher may not have completed its active bounded ADB helper.

## IR-103: Defer signals while creating private workspaces

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Install cleanup and signal traps before allocating the per-run
workspace. Defer startup signals until the workspace and short Cuttlefish
HOME have their ownership markers and cleanup paths recorded. Run each `mktemp`
command substitution with HUP, INT, and TERM ignored so a process-group signal
cannot kill it between directory creation and path output.

**Reason.** `mktemp` creates a directory before it prints the path captured by
the parent shell. A process-group signal in that interval could otherwise
leave an untracked per-run or short HOME directory. Startup deferral lets the
parent finish recording ownership and then run the normal verified cleanup.
Regression tests signal the entire process group during workspace, short HOME,
and ADB socket directory creation.

## IR-104: Invalidate capture status after a late signal

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** A fully completed capture supervisor returns zero and records the
guest command's exit code separately in its status file. If a signal arrives
after finalization starts, create an exclusive `<status>.interrupted` marker,
remove the atomic status file, and exit with the signal status. If either
invalidation operation fails, exit with a reserved failure status. The outer
runner rejects every nonzero supervisor exit and the interruption marker
before recording or publishing the capture.

**Reason.** A signal can arrive after the status file's atomic replacement.
If the supervisor returned the guest command's exit code, that process exit
code could equal a naturally returned guest-command code (for example, 143),
making exit-code comparison alone insufficient to detect the interruption.
Returning zero for completed supervision keeps this result separate from
every signal exit; the runner rejects a nonzero supervisor exit even if both
status invalidation operations fail. Regression tests signal after the real
status writer commits while the child returns 143, both with successful
invalidation and with marker creation and status removal forced to fail.

## IR-105: Make short HOME setup and cleanup signal-safe

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Ignore HUP, INT, and TERM in short HOME and fleet HOME filesystem
setup subprocesses, and defer the fleet HOME signal handoff until its path and
ownership marker are recorded. On a setup failure, remove only the tracked,
current-user-owned temporary directory and its expected marker and empty `t/`
child. Defer signal handoff and ignore those signals in the fleet HOME and
short HOME deletion subprocesses, clear each recorded path after successful
removal, remove the fleet HOME before the containing short HOME, and refresh
the Unix-socket audit immediately before root removal.

**Reason.** Process-group signals can reach a `python3`, `chmod`, or `mktemp`
child after directory creation but before the shell records or validates the
path. Untracked partial roots cannot pass the marker-validated normal remover.
The setup rollback is limited to the exact random paths created by this run,
and refuses unexpected entries. A fleet HOME may exist before its socket
metrics are generated, so cleanup must first remove that owned child and
produce a fresh audit for the containing root. Process-group signals must not
interrupt removal after the fleet marker is unlinked or after the short-root
remover quarantines `t`; the shell defers signals while these bounded
operations finish. Tests signal the whole process group during root and fleet
HOME `mktemp`, Python, permission, and deletion steps, then verify cleanup.

## IR-106: Record baseline and observed capture tool revisions separately

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Keep the original reference-capture tool commit and its blob IDs
immutable, and record the current committed tool commit and blob IDs separately
in the diagnostic record. Require the current working tree copies of those
tools to match the current commit and have no staged or unstaged changes.
Verify the private reference-tool and manifest copies against those recorded
Git blobs before guest launch and again during record creation. Validate that
the experiment-tool and patched-capture copies match the complete SHA-256 map
recorded from the exact bytes used. Keep a separate unpatched `capture.sh` copy
for the Git-blob check; verify the runnable patched copy by its recorded
SHA-256.

**Reason.** The default reference record predates intentional, committed
updates to `capture_cvd_start.py` that preserve Cuttlefish startup logs. Requiring
the current tool to equal the historical baseline rejected the diagnostic
before guest launch. Rewriting the baseline revision would falsely claim that
the updated helper produced the original capture; using the historical helper
would discard its later log-capture fixes. Recording both revisions preserves
the original provenance and identifies exactly which current tools produced
the diagnosis. Tests cover an unchanged baseline, a committed tool update, an
uncommitted tool edit, and a transient source change copied before the
repository file is restored.

## IR-107: Require the pinned baseline path for GPU-none diagnosis

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Accept only the resolved
`Images/reference/16373615/incomplete/default-20261001T120904-49816` baseline
path and commit `64da28a551b0b33e258c8f37057b9a8a6d90846d` in host preflight
and record validation. Require complete, correctly formatted path and digest
maps, then verify every recorded Git object and private copy before guest
launch and record publication.

**Reason.** `verify-host` previously read a caller-supplied baseline path but
reported the canonical baseline path unconditionally. A second record with
matching host and Cuttlefish details could therefore be reported as the pinned
baseline. The path guard binds the report to the documented input; validating
the private copies also catches files changed between staging and provenance
collection, including a source file restored before host verification.

## IR-109: Derive experiment source provenance from Git

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Pin the baseline commit instead of resolving the latest commit
touching its host record. Derive experiment-tool source hashes from the
observed committed Git revision, require clean tracked working copies, and
compare the private copies and runtime `capture_bounded.py` and
`capture_processes.py` copies against those committed bytes. Before host
identity exists, run `experiment_support.py` only after loading its source
from `HEAD` and matching the private copy to it.

**Reason.** A later commit could otherwise move the baseline's provenance
without changing the baseline path. A transient edit copied and then restored
could also let the initial verifier report a self-generated hash for different
bytes. Runtime helper copies are separate from the experiment-tool directory,
so checking that directory alone did not verify the files actually invoked.
Tests pin a synthetic baseline commit, reject a copied-and-restored verifier,
and reject a modified runtime helper.

## IR-108: Execute digest-verified publication snapshots

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Immediately before normalization, verify the private tool copies
again. Read `compare_boot.py` into memory, check it against its recorded Git
blob ID, then execute those exact bytes. Read the normalization rules, verify
their Git blob ID, and pass them through a sealed Linux memory file. Run
`experiment_support.py publish-record` from the private copy after checking
its recorded SHA-256, executing the exact in-memory bytes.

**Reason.** Record creation occurs before normalization and publication.
Executing a mutable path later could run different code from the source hashes
already recorded, and the former publication command loaded `experiment_support.py`
from the repository checkout instead of the recorded private copy. Snapshot
execution binds each Python invocation to the bytes that passed its digest
check, while the sealed rules file prevents replacement between validation
and normalization. Regression tests replace the on-disk script after snapshot
loading and verify execution still uses the checked bytes.

## IR-110: Execute the verified capture snapshot under its private tool root

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md) |

**Choice.** Load `run_capture.py` and `capture_processes.py` into memory only
after checking their source bytes against the observed committed revision and
the host identity's SHA-256 map. Load the host identity and both source files
through nonblocking, no-follow file descriptors, require regular files, and
cap their sizes. The supervisor reads the patched `capture.sh` the same way,
checks its recorded SHA-256, copies it into a sealed Linux memory file, and
passes that descriptor to Bash. Set `APKRUN_CAPTURE_SCRIPT_DIR` to the private
reference-tool directory so the script still finds its neighboring helpers
and manifest when its `$0` is `/proc/self/fd/<n>`. Start an outer GNU
`timeout` before this bootstrap with the same 900-second budget and send TERM
when it expires; pass the remaining budget to the capture supervisor.

**Reason.** A mutable pathname left a window for capture code to change after
verification but before Bash read it. Running the exact sealed snapshot binds
execution to the verified digest. A nonblocking open, regular-file check, and
size cap prevent a FIFO or oversized replacement from stopping startup before
or during its hard deadline. The outer watchdog also bounds Git verification
and other bootstrap work before the inner supervisor can start. The watchdog
does not escalate to KILL because the supervisor's guest process runs in its
own session; the supervisor sends signals to that process group and reports
incomplete cleanup if it cannot verify the tree is stopped. The private
script-directory override preserves the reference capture's existing
relative-path behavior. Tests change the source after snapshot creation,
reject digest mismatches and FIFOs, and verify the private tool directory is
retained.

## IR-111: Distinguish exited processes from incomplete `/proc` inspection

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{experiment_support.py,capture-lifecycle.sh,capture-gpu-none.sh}` |

**Choice.** On the real Linux process table, pin each same-UID process being
audited with a pidfd. Ignore a process only when its `/proc/<pid>` directory
has disappeared or its verified state is `Z` or `X`. A readable pidfd paired
with a live process at the same numeric PID is PID reuse, even when the
start-time tick matches; fail closed when a live process is missing fields.
If one descriptor vanishes while the same process remains live, continue only
after checking the pidfd and start time again. Route watcher and startup-abort
signals through the existing pidfd broker. If a broker cannot be verified as
stopped, preserve the workspace without sending a numeric-PID fallback.
Pin the current process ancestry during each real `/proc` walk, recheck each
parent-child link and start time, and repeat the ancestry scan after candidate
process inspection. Fail closed if the chain changes.

**Reason.** `/proc` entries can disappear while short-lived helper processes
exit. Treating every `FileNotFoundError` as an unsafe live process retained
otherwise clean private HOME roots; treating every such error as harmless
could miss a live process that still uses the root. Linux start-time values
have clock-tick resolution and cannot alone distinguish a process from a
same-tick PID replacement, so a pidfd remains pinned for each real process
scan. Reading each ancestor's `/proc` entry separately can splice together a
chain when an intermediate parent exits and its PID is reused; pinning and
rechecking the full chain prevents a false ancestor match. Bash can reap
background children asynchronously, so being the original parent is not a
sufficient reason to signal by PID later. The verified pidfd path handles
these races; an unverified broker failure retains data for safe manual
recovery.

## IR-112: Disable vhost-user GPU for the `gpu_mode=none` diagnosis

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{experiment_support.py,tests/test_experiment_support.py}` |

**Choice.** Pass Cuttlefish's supported `--gpu_vhost_user_mode=off` flag to
both `cvd create` and `cvd start` in the isolated `gpu_mode=none` profile.
Before publishing a result, require `cuttlefish_config.json` to record
`enable_gpu_vhost_user=false` as well as `gpu_mode=none`.

**Reason.** The real GPU-none retry at
`$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis-codex-retry-3/results/gpu-none-20261001T213427Z-139362`
showed Cuttlefish 1.57.0 auto-enabling vhost-user GPU on the arm64 host despite
`gpu_mode=none`. `run_cvd` then failed in `BuildVhostUserGpu` with
“GPU mode none not yet supported with vhost user gpu” and returned 10 before
guest boot. The pinned `cvd help start` and `cvd help create` list
`gpu_vhost_user_mode` values `auto`, `on`, and `off`; selecting `off` avoids
that unsupported combination and keeps the experiment on Cuttlefish's own
configuration path. The separate logical-partition geometry warnings in the
same capture are not established as causal. This diagnoses the experiment's
startup failure, not the earlier Android boot stall; repeat the capture and
continue #064's acceptance checks before drawing that conclusion.

## IR-113: Audit Cuttlefish socket aliases within pinned roots

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, `Experiments/cuttlefish-boot-diagnosis/{experiment_support.py,tests/test_experiment_support.py}` |

**Choice.** Traverse each socket-audit root through pinned directory file
descriptors opened without following symlinks, and recheck directory identity
and attachment after scanning. Permit a symlink to a socket only when its
lexically normalized target lies within an audited root, every target-directory
component opens without following symlinks, and the link, target, parent, and
root identities remain stable. Measure both the alias and target paths, while
counting each path once. Continue to reject directory symlinks, targets outside
the audited roots, symlinked target-directory components, and detected races.

**Reason.** The corrected GPU-none run at
`$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis-codex-retry-4/results/gpu-none-20261001T215602Z-145104`
created Cuttlefish's `internal/vhost_user_mac80211` alias to a socket inside
the same private temporary tree. The target path was 53 bytes including its
terminating NUL and the alias was 81 bytes, both within Linux's 108-byte
`sun_path` limit. The previous audit correctly refused to delete the temporary
root but treated every socket symlink as unsafe. Descriptor-relative target
verification now accounts for this Cuttlefish layout while still failing
closed on external targets and path replacement. Regression tests cover
contained and external aliases, dangling and non-socket target changes, direct
socket replacement, directory replacement, and a target parent replaced after
the directory listing. This changes only the isolated diagnostic runner's
cleanup policy; it does not change the product architecture or establish
Android boot success.

## IR-114: Validate the GPU-none configuration after Cuttlefish creates it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{experiment_support.py,tests/test_experiment_support.py}` |

**Choice.** Keep `--gpu_mode=none` and `--gpu_vhost_user_mode=off` on the
actual `cvd create` and `cvd start` invocations. Verify their argument vectors
in the Linux fake-Cuttlefish integration test. Validate
`cuttlefish_config.json` after capture and before publishing the experiment
record; require `gpu_mode=none` and the JSON boolean
`enable_gpu_vhost_user=false`.

**Reason.** A real Cuttlefish 1.57.0 `cvd create --nostart` probe produced no
`cuttlefish_config.json`; the file is created during `cvd start`. A pre-start
configuration guard would reject a valid lifecycle because its input does not
exist yet. The result builder already rejects mismatched persisted values
before publication. The integration fixture now confirms the configuration
file is absent after create, appears after start, and reflects the flags passed
to both commands. A separate corrected GPU-none run recorded both expected
values, but Cuttlefish create/start exceeded the 600-second boot deadline
without Android boot evidence. Capture completed under the separate 900-second
runner deadline; see the #064 notes. This records the earliest reliable validation
point available in the pinned Cuttlefish lifecycle and does not establish a
boot diagnosis.

## IR-115: Enable the serial console for the GPU-none diagnosis

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU-none diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{experiment_support.py,tests/test_experiment_support.py}` |

**Choice.** Pass Cuttlefish's `--console=true` option to both `cvd create`
and `cvd start` in the isolated GPU-none diagnosis. Before publishing a
result, require `cuttlefish_config.json` to record `console=true` along with
the expected GPU settings and VM shape.

**Reason.** In the sanitized current-code retry, Cuttlefish create/start
exceeded the 600-second boot deadline with an empty `kernel.log`; capture
cleanup completed before the separate 900-second runner deadline. Its launcher
log shows an early crosvm system
reset about 15 seconds after launch. Process attribution identifies that event
as the auxiliary OpenWrt crosvm (`process_name=openwrt`), not the Android VM;
see IR-089. The ADB connector repeatedly could not find the guest, so the
Android boot failure remained undiagnosed. The pinned Cuttlefish 1.57.0 CLI
reports that its serial console is disabled by default and supports
`--console=true`. Enabling it is a diagnostic choice to expose the guest serial
endpoint and see whether it provides additional evidence. It does not
guarantee guest output, change the canonical reference profiles, or establish
the Android boot failure's cause.

The 2026-10-02 retry verified `console=true` and `enable_kernel_log=true` in
the saved Cuttlefish configuration, but `kernel.log` stayed empty. An initial
60-second Screen attempt and a later 25-second attachment from a pseudoterminal
to the advertised endpoint showed no guest text. The first attempt left a
detached Screen session, which was explicitly quit and verified gone. The
diagnosis runner does not currently persist a Screen transcript. The normalized
launcher log records the auxiliary OpenWrt crosvm (`process_name=openwrt`)
resetting about 18 seconds after launch and its process restarter starting a
replacement. This is not evidence of an Android VM reset. All 40 ADB samples
remained unknown. The retry therefore verifies that the setting was applied,
but does not validate serial capture or Android boot.

## IR-116: Compare GPU modes with the same diagnostic revision

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [GPU boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{capture-gpu-none.sh,experiment_support.py,tests/test_experiment_support.py}` |

**Choice.** Extend the isolated GPU diagnosis runner to accept
`APKRUN_DIAGNOSTIC_GPU_MODE=none` or `guest_swiftshader`, defaulting to `none`.
Pass the selected mode to both `cvd create` and `cvd start`, keep
`--gpu_vhost_user_mode=off`, `--console=true`, the pinned build, host, CPU,
memory, and deadline unchanged, and reject results whose saved configuration
does not match the selection. Include the mode in result names and metadata.
Run fresh `none` and `guest_swiftshader` captures consecutively from the same
checkout, then compare that pair. Treat earlier captures as diagnostic context,
not as members of the controlled pair.

**Reason.** The prior default capture used `guest_swiftshader` and recorded
Linux, zygote, and SurfaceFlinger output. The current GPU-none capture used the
same Cuttlefish package and host conditions but produced no `kernel.log`
bytes. The records differ in GPU mode, console setting, and capture-tool
revision, so they do not establish that GPU mode caused the boot difference.
Running both modes with this same diagnostic revision, `console=true`, and all
other captured settings held constant makes GPU mode the only planned
configuration change within the new pair. The comparison can narrow the cause
but cannot alone prove it. It remains an isolated diagnostic and does not
change the canonical profiles or claim Android boot success.

**Observed pair (2026-10-02).** The records
`gpu-none-20261002T010755Z-222215` and
`gpu-guest-swiftshader-20261002T011835Z-233820` both identify tool commit
`508658fea65ca701eea382f6720d3d91c15c65cc`, the same observed capture-tool
blob map, host, pinned build, and Cuttlefish 1.57.0 revision
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`. The baseline capture-tool commit
is `64da28a551b0b33e258c8f37057b9a8a6d90846d` in both records. The experiment
source hashes match except for `patched-capture.sh`, which embeds the selected
GPU mode. Both saved the shared explicit settings `console=true`,
`enable_gpu_vhost_user=false`, four CPUs, and 4096 MiB. The saved config also
differs in mode-derived ANGLE and hwcomposer settings, per-run WebRTC and
group identifiers. The `host.json` `captureDurationSeconds` values are 603
and 604.

**Result.** Both captures ended with exit status 1 at the 600-second boot
deadline; the outer 900-second capture runner completed cleanup. The `none`
record has an empty `kernel.log`; the `guest_swiftshader` record has 10,308
bytes across 158 lines of U-Boot output, 103 of which mention virtio. It ends
at the `Starting kernel ...` handoff and contains no Linux version or init
marker.
Both records have 40/40 ADB samples unknown, no guest logcat, and no boot
completion or Android userspace evidence. After each run, `cvd fleet` was
empty and a host-side `pgrep -x crosvm` check found no process. The failed-run
workspaces retain the bounded host output for diagnosis.

**Interpretation.** The SwiftShader run recorded U-Boot output through the
kernel handoff, but no Linux kernel output; neither mode reached ADB or
completed Android boot. The pair does not establish why either guest failed
before ADB. The prior capture that reached zygote and SurfaceFlinger used
another tool revision and is not part of this comparison.

## IR-117: Compare Cuttlefish serial-console settings

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{capture-gpu-none.sh,experiment_support.py,tests/test_experiment_support.py}` |

**Choice.** Add `APKRUN_DIAGNOSTIC_CONSOLE=true|false`, defaulting to `true`,
to the isolated diagnosis runner. Pass the selection to both `cvd create` and
`cvd start`, verify the saved `console` value before publication, and record
the selection in metadata and generated work and result directory names. The
controlled pair keeps `guest_swiftshader`, vhost-user GPU disabled, the pinned
host, build, CPU and memory settings, capture deadline, and tool revision
fixed while running `console=true` and `console=false` consecutively from the
same checkout.

**Reason.** The same-commit GPU-mode pair under IR-116 reached different
pre-kernel evidence: the SwiftShader run recorded U-Boot through
`Starting kernel ...`, while the GPU-none run had an empty `kernel.log`.
Neither reached ADB. The earlier SwiftShader run that reached Linux and
Android userspace had `console=false`, but it used another tool revision, so
that observation is context rather than a controlled comparison. Holding
SwiftShader and the documented host inputs fixed while changing the console
selection tests whether that setting changes boot progress. The comparison
can narrow the cause but cannot alone prove it. It does not change canonical
profiles or claim Android boot success. Per-run generated Cuttlefish fields
may still differ and must be inspected when interpreting the pair.

**Observed pair (2026-10-02).** The records
`gpu-guest-swiftshader-console-on-20261002T020749Z-266868` and
`gpu-guest-swiftshader-console-off-20261002T021851Z-278509` both identify
tool commit `6ff41f8fd698f67958369a9dba8b86bb7dabbe13`, the same observed
capture-tool blob map, host, pinned build, and Cuttlefish 1.57.0 revision
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`. The baseline capture-tool commit
is `64da28a551b0b33e258c8f37057b9a8a6d90846d` in both records. Experiment
source hashes match except for `patched-capture.sh`. Both saved
`guest_swiftshader`, `enable_gpu_vhost_user=false`, four CPUs, and 4096 MiB;
the selected `console` value matches the metadata and generated directory
names. The other saved-config differences are per-run `group_uuid` and
`webrtc_device_id`. Both `host.json` records show a 604-second capture.

**Result.** Both captures exited 1 at the 600-second boot deadline, and the
900-second runner completed cleanup. Each `kernel.log` has 10,308 bytes across
158 lines of U-Boot output and ends at `Starting kernel ...`; neither contains
a Linux version marker. Each has 40/40 ADB samples unknown and no guest
logcat. After the second run, `cvd fleet` was empty and no `crosvm` process
remained. The bounded host output is retained in the private workspaces.

**Interpretation.** The console toggle did not change the observed log stage:
both U-Boot logs end at `Starting kernel ...`, and neither record contains
later Linux-kernel output or Android-userspace evidence. The records do not
establish whether the kernel started or why post-handoff evidence is absent.

## IR-118: Repeat the current SwiftShader console-off capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/capture-gpu-none.sh` |

**Choice.** Run one additional capture with
`APKRUN_DIAGNOSTIC_GPU_MODE=guest_swiftshader` and
`APKRUN_DIAGNOSTIC_CONSOLE=false`, using the same pinned host, build, CPU and
memory settings, deadline, and committed capture-tool revision as IR-117.
Treat it as a repeatability check of the console-off result, not as another
console-setting comparison. Do not change the canonical profiles.

**Reason.** The earlier incomplete capture
`default-20261001T120904-49816` used `console=false` and recorded Linux boot,
Android init, zygote, and SurfaceFlinger activity, but it did not pass the
reference-boot acceptance check and its capture-tool revision is not recorded
in the result. The console-off member of IR-117 used the current pinned tool
revision and stopped producing logs at U-Boot's kernel handoff. A repeat with
the current revision can establish whether that observed stopping point
repeats under the same selected settings. It cannot alone identify whether the
kernel started or explain the missing later evidence.

**Observed repeat (2026-10-02).** The incomplete result at
`$HOME/.local/share/apkrun/cuttlefish-boot-diagnosis/results/gpu-guest-swiftshader-console-off-20261002T023646Z-290359`
identifies tool commit `6ff41f8fd698f67958369a9dba8b86bb7dabbe13`, baseline
capture-tool commit `64da28a551b0b33e258c8f37057b9a8a6d90846d`, host
`linux-apple` / Ubuntu 24.04.4 / Linux 6.8.0-134, build `16373615`, and
Cuttlefish 1.57.0 revision `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`.
Its saved configuration has `gpu_mode=guest_swiftshader`,
`enable_gpu_vhost_user=false`, `console=false`, four CPUs, and 4096 MiB.
`captureDurationSeconds` is 605; Cuttlefish exceeded the 600-second boot
deadline and exited 1, while the capture supervisor completed cleanup
(`timedOut=false`, `cleanupComplete=true`). The 10,308-byte, 158-line
`kernel.log` shows U-Boot verification and loading the init boot image, kernel,
and vendor boot image, then ends at `Starting kernel ...`. It contains no
later Linux or Android init marker. All 40 ADB samples are unknown, and the
guest logcat capture wrote zero bytes. The normalized internal bootconfig has
the same key/value set as the earlier incomplete capture after excluding the
serial number and Wi-Fi MAC prefix identifiers. The sanitized
`cuttlefish_config.json` also has the same values as the earlier incomplete
capture after excluding `group_uuid`, `webrtc_device_id`, `serialno`, and
`wifi_mac_prefix`, and masking absolute paths. A live `ps` sample showed the
Android crosvm process at 99.9% CPU. A thread sample near eight minutes into
the run showed `crosvm_vcpu0` at 99.9% and the other three vCPU threads at
0.0%; subsequent samples still reported 99.9% for vCPU0. These are sampled
observations, not a continuous trace, and were not stored in the normalized
result. After cleanup, `cvd fleet` was empty and no `crosvm` process remained.

**Interpretation.** The same current-tool `console=false` settings reproduce
the missing post-handoff log and ADB evidence. The compared bootconfig keys and
sanitized `cuttlefish_config.json` values match the older incomplete capture.
That does not explain why the older run produced later logs: the configuration
comparison omits per-run identifier values and masks absolute paths, the older
capture-tool revision is not recorded, and other run-to-run variation remains.
These results do not distinguish a tooling difference from other variation.
The sampled vCPU0 activity is consistent with guest CPU activity after
U-Boot's handoff, but does not prove Linux reached its first log point or
identify what it was executing. Neither capture establishes a root cause or
completes #064.

## IR-119: Pause at U-Boot and continue through the private console

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{capture-gpu-none.sh,experiment_support.py,drive_cuttlefish_console.py,run_cvd_with_console.py,tests/}` |

**Choice.** Add an opt-in
`APKRUN_DIAGNOSTIC_PAUSE_IN_BOOTLOADER=true` mode to the isolated diagnosis
runner, leaving the default disabled. Pass
`--pause_in_bootloader=true` to both `cvd create` and `cvd start`, verify the
saved configuration, and require the serial console to be enabled. A supervisor
runs CVD startup and a bounded console helper together under the existing boot
deadline, and sends termination to both processes before waiting for either
one. The runner temporarily unblocks INT and TERM for its own cancellation
handler, blocks them across the CVD spawn boundary, then restores the active
signal mask in the child before exec and the caller's original mask on exit.
The outer capture supervisor reaps detached descendants if the console helper
has to be forcibly stopped. The helper sends `boot` once only after it observes
the U-Boot prompt, then allows at most ten seconds for a kernel handoff
received after that command. A successful handoff observed after the shared
deadline still counts as a timeout. It keeps at most 64 KiB of console text in
memory and atomically publishes only a private status summary. The normalized
record validator rechecks the embedded console evidence before publication:
the helper may report only SIGINT or SIGTERM, Screen's wait status must be a
valid process return code and must agree with whether Screen started, and the
helper exit status must match its recorded signal. Resolve Cuttlefish runtime
symlinks only when their targets stay under the unique private HOME and remain
owned by the current user. The console endpoint may additionally resolve to a
current-user character device with a numeric name directly under root-owned,
non-writable `/dev/pts`. Preserve the existing host, build, GPU, CPU, memory,
and cleanup checks; do not change the canonical profiles.

**Reason.** The normal-start Screen attempts under IR-115 produced no guest
text, and the controlled console-off repeat under IR-118 still had no Linux
output after U-Boot's kernel handoff. Those attempts did not hold U-Boot at an
interactive prompt. The [Cuttlefish bootloader debugging
instructions](https://source.android.com/docs/devices/cuttlefish/bootloader-dev)
describe pausing at the bootloader, connecting to the private console, and
typing `boot` to continue. Testing that documented flow can distinguish a
console-attachment problem from the existing boot stall. Console-disabled
pause mode cannot provide the documented connection, so it is rejected before
startup instead of spending the shared boot deadline waiting for an endpoint.
The shared cleanup grace prevents a slow Screen shutdown from delaying the
CVD stop request. Managing signal masks keeps cancellation deliverable to the
runner and CVD helper even when the caller initially blocked those signals.
Deadline precedence prevents a completion observed after the run budget from
being recorded as success. A post-command byte boundary prevents an earlier
kernel marker in the console buffer from being mistaken for a successful
handoff. Atomic publication avoids leaving a readable success summary when
writing its contents fails. Revalidating the summary and its allowed exit
codes at record publication prevents later metadata edits from bypassing the
original capture checks. Restricting signal and Screen wait-status values to
states the helper can actually produce rejects internally contradictory
summaries. The bounded status-only capture avoids retaining raw bootloader
text. This diagnostic does not change a canonical profile or claim a successful
Android boot.

**Initial live-run correction.** Cuttlefish 1.57.0 rejected the enum-like value
`BOOTLOADER` while parsing `pause_in_bootloader` as a Boolean, before creating
the instance configuration. The startup arguments now pass `true` to both
`cvd create` and `cvd start`; the rejected run left no Cuttlefish group.

**Console path correction.** The pinned Cuttlefish runtime creates
`cuttlefish_runtime` as a symlink whose target is inside the unique private
HOME and owned by the current user. Its `console` endpoint is a symlink to a
current-user PTY character device under `/dev/pts`. The helper resolves the
runtime link within HOME and accepts the console link only for that verified
PTY shape; other links that leave HOME or change owner remain rejected.

**Initial live result.** The 2026-10-02 run recorded under
`Images/reference/16373615/incomplete/gpu-none-console-on-20261002T062002Z-375629/`
saved `pause_in_bootloader=true` and `console=true`. Cuttlefish 1.57.0's
`cvd start --help` says this flag stops the bootflow in U-Boot until `boot` is
typed at the device console, and the selected `bootloader.crosvm` contains
U-Boot markers. The private PTY endpoint was found and Screen started, but
the bounded summary reports no prompt, no command, and no kernel handoff
after the 600-second deadline. It counted 83 bytes from the Screen session;
because raw bytes are intentionally discarded, that count does not establish
that guest console text was received. A separate synthetic PTY check with the
installed Screen executable passed prompt recognition, command delivery, and
kernel-marker recognition, which checks the local Screen/PTY path but not
Cuttlefish.

Keep the exact prompt gate and do not send `boot` without observing it. The
live result gives no evidence that a U-Boot prompt was present, while the
synthetic check confirms the helper can drive one through Screen. Relaxing
the gate would risk sending input at an unknown boot stage without
distinguishing the observed timeout.

**Status-only follow-up.** The helper now emits summary schema 2 with a
`uBootBannerObserved` Boolean, computed from a line-anchored, version-shaped
U-Boot banner match in its existing bounded in-memory buffer and revalidated
before publication. It strips Screen's short display escapes and OSC/DCS
control strings through their terminators (or through the end of an
unterminated sequence) before matching. It treats 8-bit C1 controls as such
only when the byte is not a valid UTF-8 continuation, preserving ordinary
UTF-8 text. Validation rejects the flag when no output bytes were observed.
The helper still discards the transcript. A synthetic run through the
installed Screen executable observed the versioned banner, prompt, sent
`boot`, and observed the kernel marker. The first Cuttlefish run predates this
field and remains schema 1.

**Schema-2 live repeat and review decision.** The retry recorded under
`Images/reference/16373615/incomplete/gpu-none-console-on-20261002T070032Z-417640/`
used observed tool commit `ee60ce575deeea3f69d962d74c85e89110492449`.
After 600 seconds, its summary reports `uBootBannerObserved=false`,
`promptObserved=false`, `bootCommandSent=false`, and
`kernelHandoffObserved=false`. The helper found the PTY endpoint and started
Screen; it counted 83 bytes, whose raw contents remain discarded. Therefore,
the run shows that the helper did not recognize a versioned U-Boot banner;
it does not prove the console carried no guest text or explain why the banner
was absent. ADB remained unknown in all 40 samples, `kernel.log` remained
empty, and cleanup left the Cuttlefish fleet empty with no helper processes.
Do not repeat this identical 600-second pause run without new evidence. The
next useful diagnosis is a bounded inspection of Cuttlefish's console-forwarder
and bootloader output path. The #064 capture remains incomplete and no boot
root cause has been established.

**Verification.** The final Linux host suite passed 268 tests; the macOS host
suite passed 166 tests with 102 skipped. Ruff lint and format checks and
`git diff --check` passed. These host-side results validate the capture helper
and its tests; they do not satisfy #064's live Android boot or reference-profile
acceptance criteria. Keep this review item open.

## IR-120: Separate Screen terminal controls from forwarded text

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{drive_cuttlefish_console.py,experiment_support.py,tests/}` |

**Choice.** Bump the private bootloader-console summary to schema 3 and add
`escapeStrippedBytesObserved` beside `outputBytesObserved`. The first count
includes all bytes Screen wrote to the helper's terminal PTY; the second counts
the remaining bytes after stripping the terminal escape sequences used by the
helper's banner, prompt, and handoff recognizers. Keep discarding the raw
transcript. Record whether the parser reaches the end of the observed bytes
inside an incomplete escape sequence.

**Reason.** In the running Linux reference VM, a controlled PTY with no guest
data produced exactly 83 bytes from the installed `/usr/bin/screen`. All 83
were terminal initialization sequences, and stripping them produced zero
bytes. This matches the earlier live record's byte count but cannot establish
that the discarded live bytes had the same contents. Recording the second
count prevents future reviewers from treating Screen's own terminal UI bytes
as evidence that Cuttlefish forwarded guest text, without retaining the
transcript or claiming source attribution. An incomplete escape sequence
causes the parser to discard its ambiguous tail, so a zero escape-stripped
count alone cannot establish that the tail contained no text.

**Verification.** A deterministic helper test feeds the same 83-byte
terminal-initialization sequence and checks that the raw count is 83, the
escape-stripped count is zero, no U-Boot banner or prompt is reported, and no
`boot` command is sent. A second test confirms the helper flags an unterminated
escape sequence and does not classify text inside its discarded tail.
Summary publication rejects negative counts, counts larger than the raw PTY
output, and a banner or prompt with zero escape-stripped bytes. The Screen
readiness handshake now waits for `execve` to close its close-on-exec pipe,
clamps the deadline remainder, and reaps the child if the wait raises. This
status refinement does not change Cuttlefish settings or establish an Android
boot root cause. The bounded direct-PTY observation is recorded in IR-124.
The earlier live record's 83 raw bytes remain unavailable, so their content
cannot be compared with the controlled Screen-only PTY output.

## IR-121: Signal the Screen child during session setup

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, `Experiments/cuttlefish-boot-diagnosis/{drive_cuttlefish_console.py,tests/test_drive_cuttlefish_console.py}` |

**Choice.** During Screen cleanup, signal both the expected process group and
the known child PID. Continue to verify group cleanup and reap the child using
the existing checks.

**Reason.** The child calls `setsid()` after `fork()`. If the parent fails
before the child establishes its session, signaling process group `pid` can
return `ESRCH`, while the child PID still exists. Sending the signal to that
PID closes the startup race without changing Screen's session or terminal
setup.

**Verification.** A Linux regression test forks a child that remains in the
parent's process group and confirms `_stop_screen()` terminates and reaps it.
A second synchronized regression test makes the child create its own session
and fork a descendant after the first `SIGKILL` group check reports no group;
cleanup then retries `SIGKILL` while checking for live group members. Existing
tests continue to cover Screen descendants and forced group cleanup. This is a
host-helper lifecycle fix and does not establish a Cuttlefish boot root cause.

## IR-122: Preserve Cuttlefish serial endpoint identity in normalized logs

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), [normalization rules](../../Images/tools/reference/normalize.yaml), [normalization tests](../../Images/tools/tests/test_compare_boot.py) |

**Choice.** Keep Cuttlefish `--serial=hardware=...` option structure,
including hardware, port, and type fields. Replace private path prefixes in
its `path` and `input` endpoints while retaining their final filenames.
Continue to redact guest serial identifiers such as `androidboot.serialno`.

**Reason.** Existing normalized U-Boot-pause logs replaced the entire
`--serial=hardware=...` option with `<SERIAL>`, which erased the UART/hvc
mapping needed to distinguish the kernel-log path from the device-console
path. The associated temporary work directories no longer contain
pre-normalized launcher logs, so the lost fields cannot be recovered from
those records. Retaining endpoint filenames in future normalized captures
allows that comparison while hiding machine-specific directory prefixes.

**Verification.** A normalization fixture checks that serial hardware,
number, type, and unambiguous endpoint filenames survive; private directories
and guest serial identifiers do not. A later review found that paths
containing spaces could leave a suffix after the original matcher stopped at
whitespace. IR-125 records the conservative fallback for quoted or ambiguous
endpoint values. Previously published captures remain unchanged because
their erased values cannot be reconstructed.

## IR-123: Describe missing crosvm output as a timed process snapshot

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), [capture script](../../Images/tools/reference/capture.sh), [capture tests](../../Images/tools/tests/test_reference_capture.py) |

**Choice.** When no matching crosvm process is visible, record that the
process snapshot had no match at artifact-collection time and state that this
does not establish whether crosvm ran earlier.

**Reason.** A process snapshot taken after a timed-out Cuttlefish start or
cleanup describes only that observation. The launcher log in the U-Boot-pause
record shows crosvm was launched, so the former `MISSING.txt` wording could
mislead readers into treating a later empty process list as evidence that it
never ran.

**Verification.** The capture integration fixture fails Cuttlefish start
before a crosvm process is available to the artifact collector and checks the
time-scoped `MISSING.txt` wording. Existing tests still check that a live
matching crosvm command line is captured when present.

## IR-124: Compare the two Cuttlefish console observation paths

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), [pinned Cuttlefish source](https://github.com/google/android-cuttlefish/tree/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/cuttlefish/host) |

**Choice.** For a same-commit pair of bounded `guest_swiftshader` and `none`
runs with console-on and bootloader-pause, compare the Screen helper's status
flags with each captured `kernel.log`. Keep the console transcript discarded.

**Reason.** In the pinned Cuttlefish 1.57.0 source at revision
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`, `crosvm_manager.cpp` maps
`/dev/hvc0` to the kernel log and configures the bootloader's interactive
serial console on its console pipes when enabled. `console_forwarder/main.cpp`
queues console-output bytes to its PTY client and kernel-log pipe. A one-byte
PTY packet with value 3 is logged as a control message; Linux headers define
that value as `TIOCPKT_FLUSHREAD | TIOCPKT_FLUSHWRITE`, and this path does not
forward it to guest input. `boot_config.cc` implements the bootloader pause by
wrapping the Android boot entrypoint in its generated environment.

An inventory of a retained older, non-paused instance found
`mkenvimg_input` and `uboot_env.img`. Its generated input contained `ethprime`
and `uenvcmd`, with no explicit `stdin`, `stdout`, `bootdelay`, or `bootcmd`
overrides. That instance had `console=false` and `pause_in_bootloader=false`,
so it does not establish what the new paused run will emit.

**Verification.** The source paths above were read at the pinned revision, and
the Linux `TIOCPKT` constants were checked in the reference VM headers. A
same-commit pair used a 180-second boot deadline. In the
`gpu-guest-swiftshader-console-on-20261002T081726Z-477707` record, Screen
observed the U-Boot banner and prompt, sent `boot`, and observed kernel
handoff. Its 19,143 escape-stripped bytes included `Starting kernel ...`;
`kernel.log` held 18,870 bytes with the same U-Boot, prompt, and handoff
markers, but no Linux version. In
`gpu-none-console-on-20261002T082317Z-482634`, Screen counted 83 terminal
control bytes that stripped to zero, with no banner or prompt; `kernel.log`
was empty. Both records use the same observed tool commit and blob map, each
has 13 unknown ADB samples, no guest logcat, and completed cleanup. These
observations confirm both channels carried U-Boot output in the SwiftShader
run. The single pair does not establish GPU mode as the cause of the
difference, prove that Linux began executing, or identify the boot root cause.
If a future run has a `kernel.log` banner without a Screen banner, investigate
the PTY/Screen observation path. If neither records it, the result remains
inconclusive because guest silence and a failure before the shared forwarding
path remain possible. This does not establish a successful Android boot.

## IR-125: Redact ambiguous Cuttlefish endpoint paths

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), [normalization rules](../../Images/tools/reference/normalize.yaml), [normalization tests](../../Images/tools/tests/test_compare_boot.py) |

**Choice.** Preserve an endpoint basename only when the normalizer can parse
the Cuttlefish `path` or `input` value unambiguously. Replace the full value
with `<HOST_PATH>` when it is quoted or contains whitespace.

**Reason.** The endpoint filename helps identify console and kernel-log
mapping, but a path containing spaces could be partially matched and leave the
private username and directory suffix visible in a published command line.
Quoted paths do not always expose a safely separable basename. Full-value
redaction favors privacy in those ambiguous cases.

**Verification.** Normalization fixtures cover ordinary endpoints with
retained basenames, an unquoted path containing a space, and a quoted path.
They assert that path fragments and directory names are absent while serial
hardware and port fields remain available. This changes only normalized
captures; existing published records are not rewritten.

## IR-126: Bound a focused bootloader-console retry

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), `Experiments/cuttlefish-boot-diagnosis/{capture-gpu-none.sh,experiment_support.py,tests/}` |

**Choice.** Keep the diagnostic runner's default boot deadline at 600 seconds.
Add an input that allows a deadline from 120 through 600 seconds, validates it
before starting Cuttlefish, and records the selected value in `experiment.json`.
Use 180 seconds for a same-commit pair of SwiftShader and GPU-none runs with
console-on and bootloader-pause.

**Reason.** Two 600-second bootloader-pause retries produced no U-Boot banner
or prompt, and their retained raw console data is intentionally unavailable.
The paired run compares direct Screen status with `kernel.log` in both GPU
modes; capturing those fields early is useful, and another ten-minute wait is
not needed to distinguish output on the observation paths. The 120-second
minimum leaves time for Cuttlefish setup and the bounded console helper.

**Verification.** Shell input validation and the experiment-record builder
share the 120–600-second range. Unit tests check its endpoints, reject
out-of-range and non-integer values, and verify that a selected 180-second
deadline is recorded. A 119-second input exits with status 2 before Cuttlefish
starts. The paired SwiftShader and GPU-none captures both recorded the chosen
180-second deadline and completed cleanup; see IR-124 and the #064 notes.

## IR-127: Trace vCPU PC after the handoff log marker

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Use short KVM traces filtered to the Android guest's exact vCPU
thread to capture its PC and guest-fault addresses after `kernel.log` records
`Starting kernel ...`. Record event formats, the PID/TID selection, filter,
monotonic event spans, and loss statistics. Treat the PC only as a high
guest-DRAM address until it is resolved against the exact bootloader mapping;
do not attribute it to U-Boot based on its address alone.

**Reason.** Repeated U-Boot logs ended at the handoff marker without showing
whether the guest began executing Linux. A high guest-DRAM address does not
identify which image owns the instruction. Filtering by one vCPU TID avoids
collecting unrelated VM events; retaining trace metadata but not the raw trace
keeps the result auditable without committing raw host data. The fault records
do not establish why execution remained at that address.

**Verification.** On the Ubuntu 24.04 arm64 Lima host with Linux 6.8 and
`trace-cmd` 3.2.0, a direct Cuttlefish 1.57.0 launch of build 16373615 used
four CPUs, 4096 MiB, and no bootloader-pause flag. It ended at the 120-second
deadline with exit status 124; `kernel.log` contained 10,308 bytes and ended
at `Starting kernel ...`, with no Linux earlycon or init marker. In a
four-vCPU Android crosvm process was PID 489124; its `crosvm_vcpu0` thread was
TID 489213. A separate one-vCPU crosvm was present and excluded. All captures
used the event filter `common_pid == 489213`.

The two PC captures used
`trace-cmd record -b 1024 -e kvm:kvm_entry -f 'common_pid == 489213' -e kvm:kvm_exit -f 'common_pid == 489213' -- sleep 3`.
Their monotonic event spans were 130225.286633–130228.287169 and
130269.782893–130272.783049. They contained 10,182 and 7,601 `kvm_entry`
events respectively, with the same count of `kvm_exit` events in each window.
Every reported `vcpu_pc` was `0x000000017f63e1f4`. In the first window,
`esr_ec` rendered as `DABT_LOW` 7,645 times and `UNKNOWN` 2,537 times.

The third capture enabled `kvm_guest_fault`, `kvm_access_fault`, and
`kvm_mmio` with the same TID filter and a three-second duration. Its monotonic
event span was 130285.831603–130288.831846. It contained 4,410
`kvm_guest_fault` events at the same PC. IPA and HXFAR were equal and advanced
by 4096 bytes per event from `0xb37a9000` through `0xb48e2000`. HSR was
`0x92000147` for 4,401 events and `0x92000146` for 9. No
`kvm_access_fault` or `kvm_mmio` events appeared.

Tracefs formats exposed `vcpu_pc` for `kvm_entry`; `esr_ec` and `vcpu_pc` for
`kvm_exit`; `vcpu_pc`, `hsr`, `hxfar`, and `ipa` for `kvm_guest_fault`; `ipa`
for `kvm_access_fault`; and `type`, `len`, `gpa`, and `val` for `kvm_mmio`.
`trace-cmd report --stat` showed zero dropped, overrun, and commit-overrun
events in all three captures. Each trace started after the log marker was
already present; the marker-to-trace delay was not measured. The exact
instruction and code owner remain unknown.

**Syndrome interpretation.** Under Arm's [ESR_EL2 definition](https://developer.arm.com/docs/ddi0601/latest/aarch64-system-registers/esr_el2),
both HSR values encode a Data Abort from a lower exception level with `CM=1`,
which identifies a cache-maintenance or address-translation operation.
DFSC `0x07` and `0x06` mean translation faults at levels 3 and 2. This narrows
the operation but does not identify its code owner or explain the missing
translation.

**Cleanup.** `cvd remove` succeeded, `cvd fleet` was empty, and no Cuttlefish
VM process remained. The private ADB socket was absent; the pre-existing
shared ADB server was left untouched. The private HOME, trace files, product
copy, and temporary source checkout were removed after recording their
necessary metadata.

**Next probe.** Resolve PC `0x000000017f63e1f4` against the exact bootloader
binary and its load/relocation map, then correlate the instruction with the
guest translation state for the sequential IPA range. IR-128 records the
binary hash and the environment inspection. Do not attribute the failure to
KASLR or graphics without evidence from that probe.

## IR-128: Verify pinned Cuttlefish console and boot configuration

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [pinned Cuttlefish source](https://github.com/google/android-cuttlefish/tree/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/cuttlefish/host) |

**Choice.** Use the Cuttlefish source at the observed host-tool revision and
the generated runtime U-Boot environment as the authority for serial routing
and bootloader pause behavior. Keep binary and environment fingerprints with
the diagnosis so that a later PC-to-symbol lookup uses the exact bootloader.

**Reason.** The attached diagnosis correctly cautioned against inferring
console-forwarder behavior from GPU-none silence, but some of its source
descriptions were based on memory. Checking the pinned source and a live,
inventoried runtime environment distinguishes the PTY path, kernel-log path,
and generated boot variables without changing the boot configuration.

**Verification.** Reviewed `crosvm_manager.cpp`,
`console_forwarder/main.cpp`, and `boot_config.cc` at Cuttlefish revision
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`. When the bootloader is enabled
and `console=true`, `crosvm_manager.cpp` maps the serial console to
`ConsoleOutPipeName` and `ConsoleInPipeName`; when `console=false` and kernel
logging is enabled, it maps the bootloader UART to the kernel-log pipe. The
HVC kernel-log port is configured separately. `console_forwarder` enables
`TIOCPKT`; a one-byte control notification read from the PTY client is logged
and not forwarded as guest input. Linux UAPI defines `TIOCPKT_FLUSHREAD` as 1 and
`TIOCPKT_FLUSHWRITE` as 2, so a control byte of 3 is the combination of
those flags, not guest output. See the pinned
[`crosvm_manager.cpp`](https://github.com/google/android-cuttlefish/blob/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/cuttlefish/host/libs/vm_manager/crosvm_manager.cpp),
[`console_forwarder/main.cpp`](https://github.com/google/android-cuttlefish/blob/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/cuttlefish/host/commands/console_forwarder/main.cpp),
and [`boot_config.cc`](https://github.com/google/android-cuttlefish/blob/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/cuttlefish/host/commands/assemble_cvd/boot_config.cc).

`boot_config.cc` wraps the Android entrypoint with the `paused` sentinel only
when `pause_in_bootloader` is true; otherwise it writes the entrypoint
directly. The inventoried direct-launch instance contained `mkenvimg_input`
(229 bytes) and `uboot_env.img` (73,728 bytes). The supplemental environment
set only `ethprime` and `uenvcmd`, and did not override `bootcmd`, `bootdelay`,
`stdin`, or `stdout`. The generated `uenvcmd` sets kernel arguments, checks
the BCB quiescent command, then runs `bootcmd_android`.

The Cuttlefish host package and its staged runtime copy of
`bootloader.crosvm` had identical SHA-256
`f464a92c6086fa876c0bc775397d20b7491b6b34e2260feb0e19b5ca97f2dd30`; the
binary contains version string `U-Boot 2024.04-g3fe964757589-ab15108624`.
The inventoried `bootloader_aarch64` directory contained `bootloader.crosvm`
and `bootloader.qemu`, with no map file. Thus the source/runtime check
confirms the no-pause environment and console routes, but it does not resolve
the traced PC to U-Boot code. The environment-inspection run ended at its
90-second deadline, followed by successful group removal and verification of
an empty fleet and no Cuttlefish processes. Temporary files were deleted.

## IR-129: Query U-Boot relocation metadata before boot

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md), [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), [console helper](../../Experiments/cuttlefish-boot-diagnosis/drive_cuttlefish_console.py) |

**Choice.** In the opt-in paused-U-Boot diagnostic, drain PTY output queued
after the first prompt through a quiet interval, then send the fixed command
shape `echo APK_<token>; bdinfo; echo APK_<token>`, using a
fresh 96-bit random token for each run. Require U-Boot to echo the exact
command, print the matching token before and after `bdinfo`, and return to the
prompt. Accept only unique 64-bit hexadecimal values from `relocaddr` and
`reloc off` between the two markers. If the command echo, both markers, and
the following prompt complete but the fields are absent, malformed, or
ambiguous, record the response as rejected with null relocation values and
continue normal boot. Stop without booting if framing or the prompt is
incomplete or the response times out. The summary records whether the command
echo and both markers were observed, but never stores the token or console
transcript. At this implementation stage, continue accepting schema-3
summaries and write new summaries as schema 4; IR-130 advances the writer to
schema 5 while retaining schema-3 and schema-4 reads.

**Reason.** The Cuttlefish package contains the raw AArch64 U-Boot image but
no map, ELF, or debug artifact. The vCPU PC and fault addresses alone do not
identify which binary owns the instruction. The U-Boot source for the revision
embedded in the image's version string prints its runtime relocation address
and relocation offset from `bdinfo`; these values can narrow the follow-up
binary-offset and symbol investigation. `bdinfo` can also print network and
other board data. The pinned
[`common/cli_readline.c`](https://android.googlesource.com/platform/external/u-boot/+/3fe9647575890b846172e546201eff7614c8cb59/common/cli_readline.c)
echoes input;
[`cmd/Kconfig`](https://android.googlesource.com/platform/external/u-boot/+/3fe9647575890b846172e546201eff7614c8cb59/cmd/Kconfig)
defaults `CMD_ECHO` to enabled. The pinned
[`common/cli_simple.c`](https://android.googlesource.com/platform/external/u-boot/+/3fe9647575890b846172e546201eff7614c8cb59/common/cli_simple.c)
and
[`common/cli_hush.c`](https://android.googlesource.com/platform/external/u-boot/+/3fe9647575890b846172e546201eff7614c8cb59/common/cli_hush.c)
support sequential semicolon-separated commands. The probe therefore places
token-printing `echo` commands before and after `bdinfo` in one command line.
The short command stays within an 80-column console including the U-Boot
prompt. The helper parses relocation fields only between these fresh markers, so an
old prompt or data delivered before the start marker cannot authorize boot.
The boundary assumes an ordered, trusted Cuttlefish console path; an endpoint
that can synthesize arbitrary output could forge the marker sequence. The
helper still drains output already queued after the initial prompt, but does
not rely on that short quiet interval to identify the response. It keeps
bounded console bytes only in memory and publishes the two allowlisted numeric
fields. Since Cuttlefish mirrors the serial console to `kernel.log`, publication
removes that whole file after the probe command was sent and then records the
omission in `MISSING.txt`. If capture or publication fails, the private
mode-0700 work area may retain raw `kernel.log` output.

**Verification.** Source revision
`3fe9647575890b846172e546201eff7614c8cb59` defines `relocaddr` and
`reloc off` in [`cmd/bdinfo.c`](https://android.googlesource.com/platform/external/u-boot/+/3fe9647575890b846172e546201eff7614c8cb59/cmd/bdinfo.c).
Synthetic Screen/PTTY tests exercise stale values between the command echo and
start marker, missing markers, ambiguous duplicate values, unanswered
queries, and successful responses bounded by both markers. Publication tests
verify that `kernel.log` is omitted only after successful unlink and that
schema-3 summaries still publish. The initial live Cuttlefish probe observed
both markers but no relocation fields and stopped before normal boot. The
follow-up implementation and live result are recorded in IR-130. Until the
probe returns relocation data and the resulting address mapping is
independently checked, the traced PC remains unattributed and no root cause is
claimed.

## IR-130: Continue boot after a complete but unusable relocation response

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, [boot diagnosis README](../../Experiments/cuttlefish-boot-diagnosis/README.md), [console helper](../../Experiments/cuttlefish-boot-diagnosis/drive_cuttlefish_console.py), [summary validator](../../Experiments/cuttlefish-boot-diagnosis/experiment_support.py) |

**Choice.** Continue boot when the opt-in probe has a complete command echo,
both fresh markers, and the following U-Boot prompt, even if parsing yields
missing, malformed, or ambiguous relocation fields. Record
`bdinfoResponseRejected=true`, retain null relocation values, and require the
normal kernel-handoff marker before the helper succeeds. Record the
post-response prompt separately from the initial prompt. Write schema 5 for
new summaries and continue accepting schema 3 and 4. Continue to fail closed
without sending `boot` when the echo, framing, or prompt is incomplete, or
when the bounded probe times out. Recheck deadlines after each console read,
before sending the `bdinfo` probe or `boot`, and before accepting the
kernel-handoff marker. When the global deadline and handoff deadline expire
together, record the handoff timeout only.

**Reason.** The first live probe completed its marker frame but yielded no
relocation values, so the previous fail-closed behavior left Cuttlefish paused
and prevented the capture from observing the next boot phase. The exact
packaged and staged `bootloader.crosvm` binary has SHA-256
`f464a92c6086fa876c0bc775397d20b7491b6b34e2260feb0e19b5ca97f2dd30`.
Filtered string inspection found the expected `echo` help text but no
`bdinfo`, `relocaddr`, or `reloc off` labels. The pinned U-Boot source defaults
`CMD_BDI` to enabled, so that source default alone does not establish the
runtime build configuration. A complete response frame is sufficient to
release the optional diagnostic pause, but its rejected values cannot be used
to attribute the traced PC. The summary needs a separate post-response prompt
field so publication validation cannot mistake the initial U-Boot prompt for
the prompt that ends the bounded query. Screen polling waits briefly for
console data, so a read that returns at a deadline can contain output that
arrived too late to accept. Checking the deadline before parsing, acting on,
or accepting that output keeps late markers from advancing guest state and
avoids contradictory timeout flags.

**Verification.** Synthetic Screen/PTTY tests cover missing and ambiguous
fields with successful continuation through a simulated kernel marker, and
retain the no-boot behavior for a missing marker and a timed-out response.
Schema-5 validation requires the post-response prompt before accepting either
relocation metadata or a rejected response; schema-3 and schema-4 summaries
remain accepted. A regression test rejects a summary that has both markers
but lacks the post-response prompt. Deadline tests also block before the
`bdinfo` and `boot` writes and verify that neither command is sent after the
global deadline. Schema-4 summaries with the interim
`bdinfoResponseRejected` field set to false are also accepted; schema-4
rejected responses fail closed because that schema has no separate
post-response prompt evidence. The full diagnosis suite passed 325 tests on
Linux and 197 tests on macOS with 128 Linux-specific skips after the deadline
guards and regressions were added. The deadline-crossing tests passed on
Linux. Ruff, Python compilation, and `git diff --check` passed. A live
retry using the pinned binary is pending; its result must not be described as
a Linux or Android boot unless the corresponding markers are observed.

## IR-131: Observe guest memory and ADB while Cuttlefish start is running

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/{capture.sh,capture_cvd_start.py,boot_observer.py}`; `Images/tools/tests/{test_boot_observer.py,test_capture_cvd_start.py,test_reference_capture.py}` |

**Choice.** Add an opt-in `APKRUN_CAPTURE_BOOT_OBSERVER=1` path for the
existing `cvd start` capture only. While that process is live, sample the
launcher-identified Android crosvm `VmRSS` and `RssShmem` every five seconds.
Use a background monotonic sampler. In Cuttlefish 1.57, `--process_name=crosvm`
belongs to the corresponding `log_tee`, while the actual crosvm process is a
child of the following `process_restarter` and has no `--process_name` argument.
Launcher output includes source process names and PIDs. Collect candidate
restarter PIDs directly from `process_restarter(<pid>)` prefixes; do not infer
them by pairing interleaved `Started` lines with argument lines. Accept RSS
only when a candidate's executable and command line identify this run's
private instance, include Android's `kernel-log-pipe` serial, and exclude the
OpenWrt serial. This role filter distinguishes Android from an interleaved
OpenWrt restarter. Require the selected restarter's direct child to have the
expected crosvm executable and private instance path. Pin and recheck procfs
start times for both restarter and crosvm.
Pass the private HOME's `cuttlefish_runtime` link to the observer without
resolving it before `cvd start`: Cuttlefish may create that link during start,
and its target is Cuttlefish-managed storage outside the private HOME. Resolve
it during sampling, accept only a target with the
`home/cuttlefish/instances/cvd-<n>` layout, and pin the first valid target.
Record a pending event while the link is absent and a failure if it never
resolves. If it later points to another instance, clear process identities,
record an observation gap, and stop sampling rather than switching targets.
`capture_cvd_start.py` atomically replaces the bounded launcher snapshot, so
do not use inode identity to detect log generations.
Check the initial prefix and bytes around the consumed offset. If the snapshot
is truncated or those bytes change, clear retained process identities and
record an observation gap.
Start a private ADB server only after launcher event 5, using a mode-0700
socket directory beneath the run's private HOME. Remove inherited ADB socket,
port, serial, and vendor-key overrides from the observer environment. Poll the
capture's localhost serial on a monotonic 15-second schedule and record
bounded state, including `sys.boot_completed`. Skip expired polling targets
instead of replaying them. Do not store raw ADB output. Cap each ADB command by
the remaining time before the 15-second cleanup reserve, and do not start a
following command after reaching that boundary. On Linux, launch the private
ADB server with a `SIGKILL` parent-death signal, so it cannot survive an
observer killed without cleanup. Capture cleanup removes the private HOME and
any stale socket path. Leave the observer disabled by default and do not apply
it to `cvd create`.

**Reason.** The earlier incomplete reference capture did not reach
`capture.sh`'s post-start ADB loop because `cvd start` exhausted its 600-second
budget. A later 2400-second outer capture found that Cuttlefish itself still
used a 600-second boot-state timeout, which ended `cvd start` before the outer
deadline. That run reached the Linux banner 537 seconds after the U-Boot
banner, but had no launcher event 5 or ADB readiness result. Its first observer
also reported no crosvm candidates: the logger marker identifies a `log_tee`,
not the Android crosvm PID, and the configured instance path incorrectly
appended another `instances/cvd-1` below the runtime symlink. The private
concurrent probe is needed to track the process through this launcher
relationship and measure guest ADB state if event 5 arrives, without retaining
app or shell output. The observer is optional so ordinary capture output, ADB
configuration, and launch behavior remain unchanged.

**Verification.** Synthetic tests cover launcher PID selection against an
OpenWrt decoy, private-instance command-line matching before the first
sample, process-start-time changes, capped-log identity gaps, background
sampling, private-socket client routing, target-based ADB polling, sanitized
records, inherited vendor-key removal, the cleanup boundary, normal and
forced ADB-server cleanup, and server exit after its Linux observer parent is
killed. The parent-death test makes the fake server ignore `SIGTERM`, verifies
that `SIGKILL` terminates it, and checks that capture cleanup removes its stale
socket. The latest `test_boot_observer.py` and `test_reference_capture.py`
regressions passed 48 cases on macOS with four Linux-only skips and 51 cases
on Linux with one skip. The macOS full Image tools suite passed 365 cases with
four Linux-only skips before the final process-source filtering change. Ruff,
formatting, shell syntax, and `git diff --check` passed after that change. A
follow-up live capture is pending to verify process selection and the
`cvd start` boot-timeout setting; the 2400-second value remains a shared
capture deadline, not a dedicated `cvd start` allowance.

## IR-132: Detect same-size inventory mutations on coarse-timestamp filesystems

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected documents | [android-image.md](../02-design/android-image.md) §3.1; `Images/tools/apkrun_image/inventory.py`; `Images/tools/tests/test_inventory.py` |

**Choice.** Copy directory files and the ZIP archive into private seekable
snapshots while hashing them, then classify those exact bytes. Re-hash each
source after parsing and reject persistent changes. Classify and hash ZIP
members directly from the immutable archive snapshot so an expanded member
does not need another temporary copy.

**Reason.** Linux testing on the Lima VM showed that its temporary filesystem
can report identical `mtime_ns` and `ctime_ns` for immediate same-size writes
to the same inode. Re-hashing detects persistent changes but alone could miss
a write that is reverted during parsing, allowing a digest from one version
to accompany classification from another. The bounded private snapshot makes
the digest and classification coherent; the final source re-hash detects
changes that remain in place. Snapshots are capped at 16 GiB per input, use at
most 8 MiB of memory, and spill into a per-user mode-0700 temporary directory.
A per-user file lock allows one inventory at a time to use this scratch
budget. The tool checks free space before copying and every 64 MiB during the
copy, preserving a 256 MiB reserve. ZIP members reuse the archive snapshot,
avoiding a second full-size expanded copy.

**Verification.** All 48 inventory tests passed on Linux and macOS, including
same-size source mutation, mutation-and-revert, archive replacement, concurrent
inventory serialization, low-scratch-space rejection, and the 16 GiB limit.
The full Image tools suite passed 363 tests on Linux with one macOS-only skip,
and 360 tests on macOS with four Linux-only skips. Ruff and formatting checks
passed. A successful inventory describes one coherent snapshot and verifies
the source again after parsing; it cannot prevent a writer from changing the
source after the final check.

## IR-133: Interpret the traced PC as consistent with U-Boot cache maintenance

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [pinned U-Boot source](https://android.googlesource.com/platform/external/u-boot/+/3fe9647575890b846172e546201eff7614c8cb59/arch/arm/cpu/armv8/cache.S); `Images/reference/16373615/incomplete/default-20261001T120904-49816/{kernel.log,launcher.log}` |

**Choice.** Treat PC `0x000000017f63e1f4` as a strong, testable match for a
U-Boot virtual-address cache-maintenance loop, with candidate relocated image
base `0x000000017f63c000`. Describe this as “consistent with” the cache-flush
hypothesis until the bootloader's exact build configuration and the runtime
call path are confirmed. Do not call the PC a proven hang or root cause.

**Reason.** The attached static analysis identifies file offset `0x21f4` as
`dc civac, x0`; subtracting that offset from the traced PC yields a
4-KiB-aligned candidate image base. The pinned U-Boot source at
`3fe9647575890b846172e546201eff7614c8cb59` contains the matching
`__asm_flush_dcache_range` instruction sequence. Its `cache_v8.c` page-table
walker iterates 512-entry tables, limits cache operations to RAM mappings,
and calls the range callback; with `CONFIG_CMO_BY_VA_ONLY`, `flush_dcache_all`
uses that walker before disabling the data cache. The captured source contains
this implementation, but the exact Cuttlefish U-Boot defconfig and whether
the packaged binary enables that option have not been verified. The attached
binary scan and relocation arithmetic also remain independently unreplicated.

The saved `default-20261001T120904-49816` logs record the U-Boot banner at
11:59:04 and the Linux banner at 12:02:14, a 190-second interval. They later
record `adbd` startup and Cuttlefish ADB proxy event 5 at 12:05:16, while the
host connector reports `device offline` at 12:05:29. The capture never reached
its post-`cvd start` ADB polling loop, so that run did not measure external ADB
readiness or `sys.boot_completed`. A 120-second run is therefore too short to
test whether the same path completes; a passive 2400-second capture is the
next discriminating probe.

**Verification.** Reviewed `cache.S` and `cache_v8.c` from the pinned source
commit; the assembly loop and conditional page-table walker match the
reported instruction pattern. Existing `kernel.log` and `launcher.log`
timestamps confirm Linux boot at +190 seconds, later `adbd` and proxy startup,
and an offline connector state. This verifies source consistency and the
captured timeline only. It does not confirm the binary's defconfig, prove the
candidate relocation base, establish that the traced PC belongs to this
function, or establish that all observed delay is cache maintenance.

The later 2026-10-02 `default` capture recorded the U-Boot banner at 22:34:27
and the Linux banner at 22:43:24 local time, a 537-second interval. Cuttlefish
then failed at 22:44:26 after its independent ten-minute boot-state timeout.
The run did not record launcher event 5 or ADB readiness. The differing
190-second and 537-second intervals show that this capture's timing is not
enough to infer a deterministic RAM-scan rate or prove the cache-maintenance
hypothesis.

## IR-134: Carry the capture deadline into Cuttlefish boot-state monitoring

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture.sh`; `Images/tools/tests/test_reference_capture.py`; Cuttlefish 1.57.0 `cvd start --help` |

**Choice.** Pass the configured `APKRUN_BOOT_TIMEOUT_SECONDS` value to
`cvd start` as `--boot_timeout_secs`, in addition to enforcing the existing
shared outer capture deadline. Do not let Cuttlefish's independent 600-second
default end a longer diagnostic capture early.

**Reason.** The 2026-10-02 live run set the outer capture deadline to 2400
seconds, but Cuttlefish 1.57.0 logged `TimeoutThreadLoop: waiting for 10m` and
returned failure at 600 seconds. Its `cvd start --help` exposes
`--boot_timeout_secs=SECS` with a 600-second default. The run reached Linux
537 seconds after U-Boot, so the fixed inner timeout left too little time to
observe later Android boot stages. Passing the configured budget keeps the
inner monitor from preempting the capture; the outer shared deadline remains
the limit for create, start, and guest readiness.

**Verification.** The capture integration test checks that a configured
321-second budget is passed as `--boot_timeout_secs=321`. A new live capture
with the pinned Cuttlefish package is required to verify that the CLI accepts
the value and continues beyond the previous 600-second cutoff.

## IR-135: Resolve Cuttlefish's runtime link during boot observation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/{capture.sh,boot_observer.py}`; `Images/tools/tests/test_boot_observer.py` |

**Choice.** Pass the private HOME's `cuttlefish_runtime` symlink to the
observer without resolving it before `cvd start`. During sampling, read its
direct target and accept only `/var/tmp/cvd/<uid>/<run>/home/cuttlefish/instances/cvd-N`,
where the UID is the current user and `N` agrees with the selected ADB port.
Resolve that direct target and require its destination to be exactly
`<private HOME>/cuttlefish/instances/cvd-N`; this accepts Cuttlefish's managed
`home` symlink while rejecting redirected path components. Pin the first
valid target. If the symlink disappears, becomes invalid, or points to
another target, clear the process identities, record an observation gap, and
stop sampling. Check the target again immediately before recording RSS.
Identify the crosvm binary from the Android `process_restarter` command after
its exact `--` separator, require its path to be this Cuttlefish run's
`artifacts/host_tools/bin/crosvm`, and match both `/proc/<pid>/exe` and the
child's `argv[0]` to that path (`samefile` for `/proc/<pid>/exe`, since the
staged file is a symlink to Cuttlefish's installed binary). Also read the
child's PPID from procfs and require it to remain a direct child of the
identified restarter while both pinned process start times still match.

**Reason.** The pinned Cuttlefish 1.57.0 runtime creates `cuttlefish_runtime`
during `cvd start`, with a direct target under `/var/tmp/cvd` outside the
capture's private HOME. A pre-start `readlink` therefore found no target and
substituted an unmatched sentinel. Resolving the target with `realpath` is
also incorrect: symlinks inside Cuttlefish's managed tree can resolve back
into the private HOME. The live path has the expected
`/var/tmp/cvd/<uid>/<run>/home/cuttlefish/instances/cvd-N` form, and its
resolved destination is the matching instance beneath the private HOME.
Checking both forms rejects a symlink that keeps the expected suffix but
redirects elsewhere. Separately, Cuttlefish stages a stripped host-tool
crosvm copy in the per-run `artifacts/host_tools/bin/` directory; the running
process's executable differs in size and hash from `$CVD_HOST_DIR/bin/crosvm`.
Comparing those paths directly rejected the actual Android process. The
launcher-identified Android restarter provides the intended staged executable
path, and its direct child, serial role, exact instance path, executable, and
stable procfs start time jointly identify the process. The child's PPID is
rechecked at sampling time so a stale child PID or a replacement process
cannot inherit the restarter's identity. Constraining the direct link target
to Cuttlefish's managed root, binding its resolved target to this private
HOME, and matching `cvd-N` to the ADB port prevents a similarly named
directory or another instance from being accepted.

**Verification.** Regression tests cover a delayed link to a target outside
the private HOME, rejection of a matching path suffix outside
`/var/tmp/cvd`, symlink redirection through `home` or `instances`, a
foreign-UID target, rejection of a mismatched instance number, runtime-link
replacement and disappearance, a child PID reused by a different parent
between enumeration and sampling, and selection of the run-staged crosvm
through the verified Android restarter. The tests also accept the production
staged symlink to a `cuttlefish-common/bin/crosvm` executable and reject a
different executable with the same basename. The focused observer suite
passed 25 tests with one macOS-only skip; an earlier focused capture-script
suite passed 33 tests with three GNU-timeout skips. Ruff lint and formatting,
Python compilation, shell syntax, and `git diff --check` passed. The full
Image tools suite passed 374 tests with four skips but had one timing-sensitive
log-snapshot integration failure; that case passed when rerun alone. A
low-load full-suite rerun remains pending. The first hostile review found
three process/path validation gaps; all were fixed, and its follow-up review
reported no findings. The active Cuttlefish result and its final observer
timeline are recorded in M01 when the capture exits.
