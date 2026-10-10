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
| Affected documents | [build-system.md](../05-development/build-system.md) §15.1, [workflow.md](../05-development/workflow.md) §§5.1, 7; [test-strategy.md](test-strategy.md) §2.4; [M00](issues/M00-repository-and-vm-foundation.md) #003 |

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

**Superseded by IR-241 for the proposed lock classification and tooling
allowlist.** Review IR-241 together with this original decision; #003 remains
open until the maintainer accepts the interpretation or selects a compliant
replacement.

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

**Verification.** On macOS 27.0 (build 26A428), the real-archive `extract`
command and `manifest --check` passed on 2026-10-06. The archive SHA-256
remained
`051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18`;
`Images/tools/tests/test_extract.py` passed all 19 tests. The target capture
and its reference-derived layout values are still unavailable, so the
157-byte command line remains provisional. Merging the current vendor and
layout bootconfig layers produced six keys and 284 serialized bytes, below the
16 KiB limit.

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
reference-dependent values must come from the #064 `target` profile. A nested
Linux/Cuttlefish reference VM is now available, but the committed captures are
incomplete `default` diagnostics and no `target` profile has been captured.
Those records do not establish the target bootconfig or final command line.
Shipping this incomplete baseline makes extraction reproducible while
keeping guessed boot properties out of the image. The Android bootconfig is
not complete until a normalized `target` capture provides the omitted values;
#010 remains open.

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
`source.target` against the actual inventory generated using the archive's
adjacent `fetch.json` sidecar, even if both the manifest and recorded inventory
agree on altered values. Fail closed when actual archive inventory lacks any
required build metadata; an absent `fetch.json` does not independently confirm
source origin. The sidecar itself is unsigned local metadata; see IR-230.
Escape and bound inventory-derived values in diagnostics, and reject control,
format, surrogate, line-separator, and paragraph-separator characters in
fetched archive names before using them as paths.

**Reason.** Manifest generation only accepts an inventory of a fetched
archive, and M10 requires its recorded archive fingerprint to match the
manifest. Accepting `directory` here would let an edited inventory remove its
archive name and fingerprints while retaining fetched build metadata, bypassing
the archive consistency check. Comparing the build identifiers to the re-read
archive inventory prevents a jointly edited manifest and inventory from
disagreeing with the sidecar, but does not authenticate that sidecar or its
build metadata. Control, format, surrogate, line-separator, and
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

**Choice.** Do not synthesize a composite specification from an instance's
individual image paths. The initial capture retained `cuttlefish_config.json`
and marked `composite-disk-specs.json` missing when that JSON had no
composite-disk section. **The missing-item rule is superseded by IR-151,**
which collects the dedicated config files emitted in the selected instance
runtime when available.

**Supersession.** IR-151 replaces only the initial rule for marking the
composite-spec artifact missing. The rule against inferring disk topology
from unrelated image paths remains in effect.

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
Linux. Ruff, Python compilation, and `git diff --check` passed. A live retry
of this schema-5 `bdinfo` rejection path was planned but was superseded by the
direct memory-read protocol in IR-137. The active helper no longer sends
`bdinfo`; schema-5 fixture validation remains covered by the diagnosis suite.
Do not describe the earlier `bdinfo` probe as a Linux or Android boot unless
the corresponding markers were observed.

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
formatting, shell syntax, and `git diff --check` passed after that change.
The completed 3000-second run observed launcher event 5 at 16:22:11.114Z,
private ADB server readiness at 16:22:12.585Z, and later ADB state `device`.
It ended after 3004 seconds when the shared deadline terminated Cuttlefish
startup; the normalized result is retained in M01. No `sys.boot_completed`
value was observed. The old poll records have a null `getpropExitCode` and
`commandTimedOut=true`, which cannot distinguish an unstarted property query
from one that timed out. IR-136 adds explicit fields for later captures. A
separate read-only `adb logcat -d -t 1` query through the private server also
timed out at its eight-second bound; no raw logcat output was retained. The
capture confirms the observer can see ADB transport `device`, but not Android
boot completion.

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

**Choice.** Treat PC `0x000000017f63e1f4` as matching a U-Boot
virtual-address cache-maintenance instruction at candidate relocated image
base `0x000000017f63c000`. A live paused-U-Boot read corroborates that
instruction window at runtime. Describe the slow cache-flush explanation as
“consistent with” the evidence until the bootloader's exact build
configuration and runtime call path are confirmed. Do not call it a proven
hang or root cause.

**Reason.** The attached static analysis identifies file offset `0x21f4` as
`dc civac, x0`; subtracting that offset from the traced PC yields a
4-KiB-aligned candidate image base. The pinned U-Boot source at
`3fe9647575890b846172e546201eff7614c8cb59` contains the matching
`__asm_flush_dcache_range` instruction sequence. Its `cache_v8.c` page-table
walker iterates 512-entry tables, limits cache operations to RAM mappings,
and calls the range callback; with `CONFIG_CMO_BY_VA_ONLY`, `flush_dcache_all`
uses that walker before disabling the data cache. The captured source contains
this implementation, but the exact Cuttlefish U-Boot defconfig and whether
the packaged binary enables that option have not been verified. The
712,032-byte `bootloader.crosvm` was independently read from the pinned
Cuttlefish image path and matched SHA-256
`f464a92c6086fa876c0bc775397d20b7491b6b34e2260feb0e19b5ca97f2dd30`. An
aligned scan found the little-endian instruction word `0xd50b7e20` only at
file offset `0x21f4`. Wrapping the bytes in a Mach-O `__TEXT,__text` section
with `.incbin`, compiling with
`xcrun clang -target arm64-apple-macosx15.0 -c wrapper.S -o wrapper.o`, and
disassembling with
`xcrun llvm-objdump --disassemble --no-show-raw-insn --start-address=0x21dc --stop-address=0x2220 wrapper.o`
reproduced `dc civac, x0` at `0x21f4` and its cache-line loop. A second window
from `0x220c` to `0x2250` reproduced the following `dc ivac, x0` loop. The
traced PC minus the verified file offset gives the 4-KiB-aligned candidate
base `0x000000017f63c000`. This independently verifies the binary instruction
and the address arithmetic. The later nonce-framed paused-U-Boot probe read
`d50b7e20` at `0x000000017f63e1f4` and `d53b0023` at
`0x000000017f63e1dc`, corroborating that the expected code window occupies
those runtime addresses in the pinned Cuttlefish package. The probe and trace
were separate runs, so the read does not by itself establish the execution
context of the earlier PC sample. The 174-candidate relocation search has
since been independently reproduced; the generated bootloader configuration
and whether the packaged binary uses this runtime call path remain
unverified.

Together, the reproduced relocation result and repeated RSS timing make a
RAM-wide virtual-address cache flush the leading working hypothesis for the
long U-Boot interval. The build setting, the caller in the packaged binary,
and the proposed nested stage-2 fault cost remain unverified; this is not a
proven hang or root cause.

The saved `default-20261001T120904-49816` logs record the U-Boot banner at
11:59:04 and the Linux banner at 12:02:14, a 190-second interval. They later
record `adbd` startup and Cuttlefish ADB proxy event 5 at 12:05:16, while the
host connector reports `device offline` at 12:05:29. The capture never reached
its post-`cvd start` ADB polling loop, so that run did not measure external ADB
readiness or `sys.boot_completed`. A 120-second run is therefore too short to
test whether the same path completes. An unpaused capture of at least 2400
seconds, with memory and ADB observation but without console interaction or
vCPU tracing, was the next discriminating probe; the completed 3000-second
retry is documented below.

**Verification.** Reviewed `cache.S` and `cache_v8.c` from the pinned source
commit and independently reproduced the instruction window from the
hash-verified Cuttlefish binary using the Mach-O wrapper and `xcrun` commands
above. The instruction-word scan found one 4-byte-aligned occurrence at
`0x21f4`; subtracting it from the traced PC yields the aligned candidate
base. Existing `kernel.log` and `launcher.log` timestamps confirm Linux boot
at +190 seconds, later `adbd` and proxy startup, and an offline connector
state. These checks confirm the packaged instruction and that the candidate
address arithmetic is consistent. The later paused-U-Boot memory probe
separately corroborates the expected instruction words at the candidate
runtime addresses, but does not establish that the earlier trace sampled this
code while executing. These observations do not show that the shipped binary
was built with the relevant option or that the traced PC was executing this
call path, and they do not establish that all observed delay is cache
maintenance.

Follow-up verification used the Lima-packaged binary with the same SHA-256.
Enumerating `0x1f4 + 0x1000*n` offsets within its 712,032 bytes yielded 174
aligned-base candidates and a single matching instruction at `0x21f4`.
Disassembling the whole image found only the one `dc civac` and one `dc ivac`
instruction, with no set/way cache operation. The exact U-Boot source commit
`3fe9647575890b846172e546201eff7614c8cb59` confirms the conditional
`cleanup_before_linux()` to `dcache_disable()` to `flush_dcache_all()` path,
the 512-entry `__cmo_on_leaves()` walk, and the RAM-bounded VA callback. Its
`CONFIG_CMO_BY_VA_ONLY` Kconfig symbol has no default, and its
`cuttlefish.fragment` does not set the symbol. No generated `.config` or
defconfig was present beside the packaged bootloader. Thus the source path is
verified, but whether the shipped binary was built with the option and
executed that path remains unknown.

The recovered `default-20261002T224455-600285` capture records the U-Boot
banner at 22:34:27 and Linux at 22:43:24 Lima local time, a 537-second
interval. Its `host.json` records a 634-second duration; the 2400-second outer
deadline was not reached because Cuttlefish's independent ten-minute
boot-state timeout logged `VIRTUAL_DEVICE_BOOT_FAILED`. The run did not record
launcher event 5 or ADB readiness. Its normalized logs are now retained in
M01. The difference between this interval and the artifact-backed 190-second
interval does not support a deterministic RAM-scan rate or prove the
cache-maintenance hypothesis.

The completed 3000-second retry recorded Linux and Android first-stage init,
followed by zygote and vendor service starts through guest uptime 2240.96
seconds. Its final kernel tail includes repeated `aidl/activity` lookups from
audioserver; as the attached diagnosis notes, that message alone does not
establish a fatal failure. In one five-second host sample, each of the four
crosvm vCPU threads used about five CPU seconds. The run recorded launcher
event 5 at 16:22:11Z, started its private ADB server at 16:22:12Z, and later
observed ADB state `device`. Its old poll records do not confirm
`sys.boot_completed` and cannot distinguish a skipped property command from
one that timed out; IR-136 adds that distinction for later captures. A
bounded eight-second logcat query also timed out. This confirms guest
progress beyond the earlier handoff boundary, but does not identify which
guest code consumed the CPU, prove ownership of the earlier PC, establish
that U-Boot cache maintenance caused the delay, or establish a successful
Android boot.

The 600 five-second crosvm memory samples sharpen the timing evidence. VmRSS
rose from 4,191,176 KiB at 16:09:12.534Z to 4,212,284 KiB at 16:09:17.533Z;
this was the first sample at or above 4 GiB and immediately preceded the
launcher-recorded Linux banner at 16:09:18Z, whose timestamp has one-second
resolution. RssShmem first crossed 4 GiB at 16:09:22.534Z, the next sample
after the banner. The Cuttlefish configuration records `memory_mb=4096` and
`ddr_mem_mb=4915`, and `internal-bootconfig.txt` reports
`androidboot.ddr_size=4915MB`. Treat 4 GiB as an RSS milestone, not evidence
that all configured DDR was resident. The timing is consistent with
substantial guest RAM becoming resident during U-Boot's slow transition and
supports, but does not prove, the cache-maintenance hypothesis. RSS sampling
does not identify the executing code, establish a stage-2 fault mechanism,
confirm the exact bootloader configuration, or explain the subsequent
Android delay.

The completed 2400-second `default` retry adds another observation: U-Boot was
logged at 17:07:35Z and Linux at 17:11:01Z, 206 seconds later. Of 479 valid
five-second crosvm samples, VmRSS/RssShmem was 4,193,260/4,171,596 KiB at
17:10:59.974Z and 4,216,196/4,194,532 KiB at 17:11:04.974Z. The latter
crosses 4 GiB for both measures; the Linux banner falls within that sampling
interval. This is consistent with substantial guest memory becoming resident
during the U-Boot-to-Linux transition, but the `ddr_mem_mb=4915` setting means
it does not show that all guest DDR was resident. The observed intervals of
190, 537, 753, 206, and 266 seconds also vary too much to infer a deterministic
scan rate. The additional run strengthens the timing correlation without proving
that the traced instruction owns the PC, that cache maintenance caused the
delay, or that stage-2 page allocation explains the faults.

The same run reached Android first-stage init and zygote. Servicemanager
records calls from the `system_server` SELinux domain near guest uptime
1795.5 seconds, and init later logs an untracked zombie named `system_server`
exiting with status 0 near uptime 2038.2 seconds. The logs do not establish
whether those records refer to the same process or why it exited. No boot
completion marker was observed. ADB reported `device` after launcher event 5,
but 112 of 113 attempted property queries timed out under the then-current
two-second cap; one completed without a `sys.boot_completed` value. A
separate bounded query took about seven seconds and returned no property
text. These are Android progress and ADB transport observations, not proof
that the guest boot completed or a diagnosis of its later state. The
normalized capture is recorded in M01.

The 1200-second verification run adds a fifth interval: its launcher log
records U-Boot at 17:58:44Z and Linux at 18:03:10Z, 266 seconds later. Of 239
valid five-second crosvm samples, VmRSS/RssShmem was 4,167,692/4,146,036 KiB
at 18:03:05.265Z and 4,216,188/4,194,532 KiB at 18:03:10.265Z; the latter
first crosses 4 GiB for both measures, within the sample interval containing
the Linux banner. The config still specifies `ddr_mem_mb=4915`, so the
crossing does not prove that all guest DDR was resident. This is additional
timing correlation, not proof of a deterministic scan rate or cause. The
capture reached first-stage init and zygote. It recorded neither a
`VIRTUAL_DEVICE_BOOT_COMPLETED` event nor a positive `sys.boot_completed=1`
value; the kernel log records init setting `sys.bootstat.first_boot_completed`
to `0` at guest uptime 458.78 seconds. Its full normalized record is in M01.

The later 2400-second unpaused retry adds a sixth interval: U-Boot at
20:42:09Z and Linux at 20:55:09Z, 780 seconds later. Of 479 valid five-second
crosvm samples, the first sample where both VmRSS and RssShmem reached 4 GiB
was at 20:55:11.141Z, two seconds after the Linux banner. The guest had
`ddr_mem_mb=4915`, so this does not prove that all configured DDR was
resident. Its output directory is named with Lima local time:
`default-20261003T062208-792872` corresponds to October 2 UTC. This mapping is
corroborated by the UTC observer start and stop events and the sidecar's
`verifiedAtUtc` timestamp; `capture.sh` uses local `date` when forming the
incomplete-record directory name. The timing correlation does not identify the
code executed at the traced PC or establish that cache maintenance caused the
delay; the full incomplete record is in M01.

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

**Reason.** The recovered 2026-10-02 run at
`Images/reference/16373615/incomplete/default-20261002T224455-600285/` set
the outer capture deadline to 2400 seconds, but Cuttlefish 1.57.0 logged
`TimeoutThreadLoop: waiting for 10m` and returned failure at its 600-second
inner timeout. Its `cvd start --help` exposes
`--boot_timeout_secs=SECS` with a 600-second default. The run reached Linux
537 seconds after U-Boot, so the fixed inner timeout left too little time to
observe later Android boot stages. Passing the configured budget keeps the
inner monitor from preempting the capture; the outer shared deadline remains
the limit for create, start, and guest readiness. The attached diagnostic
note proposes 2400 seconds; the completed retry used 3000 seconds with the
same guest settings, adding a bounded ten-minute observation window because the
guest is progressing slowly. This duration choice does not establish a
performance root cause.

**Verification.** The capture integration test checks that a configured
321-second budget is passed as `--boot_timeout_secs=321`. The completed
capture passed 3000 seconds to the pinned Cuttlefish CLI and ran for 3004
seconds in total; the shared deadline then ended startup. It reached Linux,
Android init, zygote, vendor services, and `adbd`, but did not reach
`sys.boot_completed=1`; the normalized incomplete record is in M01. This
confirms the CLI accepts the longer value and that its independent 600-second
default no longer ends startup early. The run did not establish a successful
boot. A later 2400-second run also passed the configured value to Cuttlefish:
`launcher.log` records `TimeoutThreadLoop: waiting for 40m`. `host.json`
records a total capture duration of 2403 seconds when the outer deadline
ended startup. It likewise did not reach `sys.boot_completed=1`; see the
normalized record in M01.

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
log-snapshot integration failure; that case passed when rerun alone. After the
capture ended, the low-load full Image tools suite passed 381 tests with four
platform-specific skips, including the previously timing-sensitive
log-snapshot case. The first hostile review found
three process/path validation gaps; all were fixed, and its follow-up review
reported no findings. A read-only procfs cross-check against the active Linux
reference instance confirmed the actual managed symlink chain, current UID,
ADB-port mapping, direct `process_restarter` parent, staged crosvm `argv[0]`,
and `/proc/<pid>/exe` same-file check. The completed Cuttlefish result and its
final observer timeline are recorded in M01.

## IR-136: Distinguish an unstarted ADB property query from a timeout

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py` |

**Choice.** Add `getpropAttempted` and nullable `getpropTimedOut` to each
bounded `adb_poll` record. `getpropAttempted` is true only when the ADB
subprocess was started. Keep `commandTimedOut` strictly for an ADB subprocess
that timed out, and add `pollDeadlineReached` for the shared deadline
preventing the poll from continuing. When the deadline expires before
`getprop` starts, record `getpropAttempted=false` and
`getpropTimedOut=null`; when the process starts, record
`getpropAttempted=true` and its actual timeout result. Keep the quick
`connect` and `get-state` commands capped at two seconds, but allow the guest
`getprop` shell command up to ten seconds, still subject to the shared
deadline and cleanup reserve.

**Reason.** The preceding 3000-second capture's ADB record has
`deviceState="device"`, `getpropExitCode=null`, `sysBootCompleted=null`, and
`commandTimedOut=true`. In the old schema that field could mean an ADB child
timed out or the poll deadline prevented a later command from starting; it
does not show whether `getprop` was invoked. Guessing either case would
overstate the evidence. The new fields distinguish a child timeout from
deadline exhaustion and identify whether the property query process started,
without storing raw ADB output. In the updated live run, an ADB `device` state
was followed by repeated `getprop` timeouts under the existing two-second
cap. A separate bounded query through the same private socket finished in
about seven seconds with no property text under a 12-second limit. The
two-second cap therefore cannot distinguish a slow guest shell from an
unavailable property. The ten-second property cap leaves the transport
commands unchanged; the three subprocess caps total fourteen seconds against
the 15-second poll interval, and missed points are skipped.

**Verification.** The observer tests assert the successful property-query
fields and exercise deadline expiration before the query, expiration in the
after-connect and after-`get-state` branches, expiration in the small gap
before process start, a query that times out, an offline device, a timed-out
`get-state` command, and the distinct two-second and ten-second subprocess
caps, including the shared-deadline clamp. A 2400-second live capture using
the updated record schema has completed. It recorded 116 polls: three initial
polls had no device state and `getpropAttempted=false`; one timed out, while
the other two had a successful `connect` exit status but still no device
state. The remaining 113 polls reported `device` and had
`getpropAttempted=true`. Of the latter, 112 timed out and one exited 0 without
an accepted property value. All polls had
`pollDeadlineReached=false`, and `sysBootCompleted` remained null. This
capture used the earlier two-second property cap. A separate bounded
read-only query through the same private socket returned no property text in
about seven seconds under a 12-second limit. The 1200-second run below
subsequently exercised the ten-second cap against the guest. The focused
observer suite passed 33 tests with one Linux-only parent-death test skipped
on macOS; Ruff, formatting, Python compilation, and `git diff --check`
passed. After the ten-second cap change, the full Image tools suite passed
383 tests with four platform-specific skips. The first hostile review found
an uninitialized property-attempt field and an ambiguous timeout flag; both
were corrected, and its follow-up review reported no findings.

A subsequent 1200-second `default` capture used a VM copy of
`boot_observer.py` with SHA-256
`d19b56edf45b7011a53b42ca4ab2d1c6c60d89b52163a9780ac49688d2702494`, matching
the local source; that source sets the `getprop` timeout to ten seconds. The
source and VM copy were checked before launch. It recorded 33 polls: three
initial polls had no device state and did not attempt the property query (one
connection timeout and two `connect` exit-code-0 results); the other 30
reported `device` and attempted `getprop`. Twenty-nine timed out, and one
exited 0 without an accepted
property value. One final poll reached the ADB polling cutoff before the
15-second cleanup reserve, and
`sysBootCompleted` stayed null throughout. A separate bounded
`getprop sys.boot_completed` query and `logcat -d -t 1` query, each limited to
12 seconds through the same private ADB socket, both exited 124. Their output
was discarded. This verifies that the observer exercised the extended
property-query path and retained the timeout distinction, but it does not
show whether a longer guest shell query would return a property.

A later 2400-second `default` capture used a surviving Lima copy of
`boot_observer.py` with SHA-256
`d19b56edf45b7011a53b42ca4ab2d1c6c60d89b52163a9780ac49688d2702494`; the
post-capture source comparison is retained in `post-run-verification.json`.
It recorded 70 polls: three initial polls had no device state (one
connection command timed out and two `connect` commands exited 0); the other
67 reported `device` and attempted `getprop` under the ten-second cap. Fifty-
five timed out, and twelve exited 0 without an accepted property value. The
final poll reached the ADB polling cutoff before the 15-second cleanup
reserve, and `sysBootCompleted` remained null.
This confirms repeated execution of the extended query path and stable ADB
transport state, but not Android boot completion or the reason that the
property text was unavailable. The normalized record is in M01.

## IR-137: Read the traced guest words directly when `bdinfo` is unavailable

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Experiments/cuttlefish-boot-diagnosis/README.md`; `Experiments/cuttlefish-boot-diagnosis/drive_cuttlefish_console.py`; `Experiments/cuttlefish-boot-diagnosis/experiment_support.py`; `Images/reference/16373615/incomplete/default-20261003T052650-788232/{capture files, LIMA-SHA256SUMS}` |

**Choice.** Before the paused-U-Boot memory read, clear the dedicated `w0` and
`w1` environment variables and require an exact echo, the empty-state marker
`APKRUN_PROBE_READY`, and the following prompt. If the marker includes
variable values or the framing is otherwise rejected while a prompt is
available, skip the read and continue boot. Then send
`setexpr.l w0 *0x17f63e1f4;setexpr.l w1 *0x17f63e1dc;echo ${w0} ${w1} <nonce>`,
where each helper run creates a fresh seven-character nonce. The command and
the `=> ` prompt occupy 79 of the console's 80 columns. It reads one 32-bit
word at the traced PC and one at the preceding loop instruction address; it
does not write the inspected guest-memory locations. Accept only the exact
echoed command, one response line containing a pair of 32-bit hexadecimal
words and the same run's nonce, and the next U-Boot prompt. Record a unique
well-formed pair even if it differs from the expected `d50b7e20 d53b0023`.
Reject additional output, missing or malformed values, duplicate pairs, and
responses carrying another run's nonce when the prompt arrives, then continue
boot. Leave the VM paused if the command echo or prompt is missing or the
shared five-second preparation/read timeout expires. Start that timeout before
sending the preparation command and enforce it while sending both commands
and waiting for their responses. Write these states and values in summary
schema 6 while continuing to validate schema 3–5 records. Do not send
`bdinfo` in this active path. Keep its schema-4/5 fields to validate legacy
summaries and to omit the mirrored `kernel.log` when an older paused-U-Boot
record says the `bdinfo` command was sent. Publication also omits that log
after either current memory-probe command has been sent and records the
omission before moving the record into results.

**Reason.** The packaged `bootloader.crosvm` hash was verified, but filtered
strings exposed no `bdinfo` or relocation labels, and the first live
`bdinfo` response contained no relocation fields. The user-provided diagnosis
recommends reading the two known addresses directly. This is its optional
paused-U-Boot probe (C), pursued after the primary long, untraced capture (A)
had completed; those unpaused, instrumented results are recorded in M01 and
IR-133. The current driver sends the direct memory-read command and no longer
executes `bdinfo`. The old fields remain for schema-4/5 validation and to
preserve the legacy `kernel.log` omission safeguard when those records are
published. This avoids repeating a probe that returned no relocation
metadata while preserving compatibility with prior summaries. The targeted
probe does not replace the unpaused boot observation.
Clearing and checking
the variables prevents old U-Boot environment values from masquerading as
fresh memory reads. Requiring the response to contain the current run's nonce
also rejects a delayed complete transcript from another run; it is a framing
guard, not endpoint authentication. The seven-character nonce keeps the
command and prompt within 79 columns, leaving one column of margin. Draining
queued PTY output and then requiring the exact command echo prevents
pre-command stale text from being accepted. The code records the observed
words rather than treating the expected values as a precondition, so an
unexpected result remains useful evidence. The live read is direct evidence
that the expected instruction words occupy the candidate addresses while
U-Boot is paused, corroborating the relocated code window. Because the probe
was a separate run, it does not alone establish the earlier trace's execution
context or call path, nor does it show that cache maintenance caused the slow
boot.

**Verification.** The Linux Screen-PTY suite exercises variable clearing,
stale preparation values, the exact read command, accepted values, duplicate,
malformed, and additional output, stale pre-command output, and a delayed
response carrying another run's nonce after the current command echo. It also
checks that the wrong-nonce response is rejected, command width, nonce
validation, a missing response prompt, timeouts during either phase and
command transmission, global deadline handling, and the subsequent
kernel-handoff signal. The Cuttlefish launch tests verify that both the direct
and supervised start paths pass the boot timeout to Cuttlefish. The summary
validator checks schema 6 value ranges and state consistency while retaining
legacy schema 3–5 coverage. Publication tests verify that sending either
probe command omits the mirrored `kernel.log` and records that omission. The
full Linux experiment suite passes 349 tests. Adversarial review found a
documentation mismatch and a stale-response test-ordering gap; both were
fixed, and final follow-up review found no remaining findings.

A live validation of commit `638a596` used the paused-U-Boot path with
SwiftShader, console enabled, and a 180-second deadline. The helper observed
the U-Boot banner and exact echoes, accepted the current run's nonce-framed
response with words `d50b7e20` and `d53b0023`, sent `boot`, and observed the
kernel-handoff marker without a probe timeout. The capture lasted 185 seconds
and returned exit code 1 at the guest deadline; `cvd-start`'s child exit code
is null. All 13 ADB samples were
`unknown`; there was no positive `sys.boot_completed` result or guest logcat.
The publisher omitted `kernel.log`, so this result does not show Linux or
Android progress after handoff. The normalized nine-file record is in
`Images/reference/16373615/incomplete/default-20261003T052650-788232/`.
`LIMA-SHA256SUMS` contains Lima-side digests, and host-side `sha256sum -c`
verified all nine capture files. The privacy scan found no host paths, MAC
addresses, or PEM key markers. `experiment.json` records complete helper and
capture cleanup; `MISSING.txt` says no crosvm process matched the private HOME
at artifact-collection time. This validates the nonce-framed live exchange
and the instruction words at the candidate addresses, not Android boot.

## IR-138: Compare Cuttlefish boot with 2048 MiB guest memory

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; `Experiments/cuttlefish-boot-diagnosis/{README.md,capture-gpu-none.sh,experiment_support.py,run_cvd_with_console.py}` and tests; the two normalized memory-comparison records in M01 |

**Choice.** Keep 4096 MiB as the default and add an explicit
`APKRUN_DIAGNOSTIC_MEMORY_MB=2048` comparison option. Accept only 2048 or 4096
MiB. Pass the selected value to both `cvd create --memory_mb` and
`cvd start --memory_mb`; the latter otherwise restores its 4096 MiB default.
Keep the pinned build, four CPUs, `guest_swiftshader`, console disabled, and
other explicit Cuttlefish arguments fixed. Use the existing 600-second
diagnostic deadline for both memory settings; do not expand the runner's
supported deadline as part of this comparison. Record the 4096 MiB baseline,
selected value, and slug in verified host and experiment metadata, include the
selection in workspace and result names, and reject publication if saved
configuration does not match. Preserve compatibility with older records that
lack memory fields and with the previous schema that contains only
`memoryMb=4096`.

**Reason.** The supplied U-Boot diagnosis proposes an optional 2 GiB run to
check whether the long U-Boot-to-Linux interval changes with guest-memory
size. Restricting the selector prevents accidental uncontrolled values and
keeps the baseline invocation unchanged. The generated Cuttlefish
configuration remains in the capture so any derived DDR size is visible. A
single changed timing is diagnostic evidence only. If the U-Boot start marker
is observed but Linux is not observed before the configured deadline, report
the U-Boot-to-Linux interval as right-censored. If the U-Boot marker is absent,
report that interval as unmeasured. Neither outcome confirms or rejects the
cache-flush hypothesis. The historical 4 GiB/600-second record matches the
guest settings but does not identify its capture-tool revision, so this
comparison also includes a 4 GiB run on the current tool commit. Keep the
interpretation limited to the U-Boot-to-Linux marker interval; the optional
2 GiB run does not diagnose later Android or ADB progress.

**Verification.** Unit and publication coverage checks the 2048 and 4096 MiB
selections, generated `create` and `start` arguments, recorded metadata,
directory labels, acceptance of the prior `memoryMb=4096` record shape, and
rejection of a mismatched saved configuration. The first live 2048 MiB
attempt was rejected before publication: the requested value appeared in
`cvd create`, but Cuttlefish 1.57.0's `cvd start` default rewrote the saved
configuration to 4096 MiB. The pinned CLI help confirms that `cvd start`
accepts `--memory_mb`; the launch path now passes and checks the selected
value in both commands. The rejected attempt is not comparison evidence.

The valid 2048 MiB capture saved `memory_mb=2048` and
`ddr_mem_mb=2457`; its U-Boot-to-Linux interval was 281 seconds. A 4096 MiB
control on the same current capture-tool commit saved `memory_mb=4096` and
`ddr_mem_mb=4915`, but did not record Linux before the 600-second deadline, so
its interval is right-censored. The older 4096 MiB baseline reached Linux in
190 seconds but does not identify its capture-tool revision; other 4096 MiB
captures range up to 780 seconds. The pair therefore shows run-to-run
variability and does not establish a memory-size effect or a cache-maintenance
cause. The ten normalized files in each record match its Lima-side SHA-256
manifest, and privacy scans found no tested host paths, MAC/EUI-64 addresses,
or PEM key markers. Both `experiment.json` files record
`captureRun.cleanupComplete=true`. The records do not preserve post-run fleet,
process, or shared-ADB checks; `MISSING.txt` only records that no crosvm
matched the private Cuttlefish HOME at artifact-collection time and does not
establish whether it ran earlier. The full diagnosis suite passes 404 tests;
Bash syntax and Python compilation pass. `git diff --check` passes for the
documentation changes; it flags a trailing blank line in the preserved 4 GiB
`kernel.log`, which remains byte-for-byte intact to retain its Lima SHA-256.
Ruff reports the same 52 lint diagnostics on the parent and current revisions
and marks the same four files as unformatted, with no increase from this
change.

## IR-139: Summarize final-window Android process events during boot observation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py` |

**Choice.** On captures with a finite deadline, reserve 28 seconds before the
existing ADB polling cutoff for a final diagnostic window. Its 26.5-second
minimum covers two two-second host commands, the ten-second logcat limit,
termination and reaping for all three ADB client process groups, up to four
seconds for private ADB server shutdown, and a one-second safety margin; the
remaining 1.5 seconds absorb scheduler delay. Stop starting ordinary polls
18 seconds before this window, then reconnect through the
private ADB server and require a fresh `get-state=device` before querying
`logcat -d -b events -v descriptive -t 128`. Cap the command at ten seconds
and 64 KiB of stdout. Cap each two-second `connect` and `get-state` command
at 4 KiB of stdout. Keep all output in memory and persist an
`adb_logcat_summary` JSONL event with a fixed schema: overall event,
process-start, process-exit, process-crash and ANR counts, plus bounded
per-command status fields and per-event-type counts for selected lines
mentioning `system_server` and `zygote`. These are mention/event-type
co-occurrence counts; they do not identify the event's target process or
establish causation. Guest-event timestamps and identities are not stored.
A timed-out or truncated query may contribute counts from its captured
prefix. Run each ADB client in its own process group; at the bound, terminate
the entire group, reap its client leader, and verify that the group is gone.
Observer shutdown waits through the full 28-second probe reservation before
reporting cleanup failure, allowing in-flight clients to finish their bounded
cleanup. Record a bounded summary event when the guest is unavailable,
without running logcat. Do not run this final-window probe when `cvd start`
returns early or when no finite deadline is configured.

**Reason.** The 3000-second capture
(`default-20261003T014646-643687`) reached ADB state `device`, but its legacy
observer records do not distinguish a skipped `getprop` command from one
that timed out; a separate eight-second `logcat -d -t 1` request also timed
out. A distinct 2400-second capture (`default-20261003T024733-676851`)
recorded calls from the
`system_server` SELinux domain followed much later by an untracked zombie
named `system_server`; 112 of 113 property requests timed out at that time's
two-second cap. Neither the relationship between those kernel records nor
the reason for the exit is established. A separate 1200-second capture
(`default-20261003T031842-703886`) recorded 12-second `getprop` and
`logcat -d -t 1` requests both timing out; its kernel log ended at guest
uptime 924 seconds and does not connect those timeouts with the separately
documented `system_server` observations. A small events-buffer
summary may establish whether Android recorded a process start, death, crash,
or ANR near the end of a follow-up run, and whether such an event line
mentions `system_server` or `zygote`. A fixed tag allowlist, output cap,
in-memory parsing, and aggregate counts preserve that diagnostic value
without retaining event payloads, guest-event timestamps, or identities. The schema
labels process-name counters as mentions because the parser does not infer
event-field roles from descriptive logcat payloads.
The reserved window protects the existing cleanup allowance and does not
change the Cuttlefish launch configuration.

**Verification.** T0 covers descriptive logcat line parsing, counts for the
allowlisted event tags and process-name mention/event-type counts, payload/identity
exclusion from JSONL, one-shot behavior, offline-state skip, output
truncation, timeout, descendants that inherit stdout for each final-probe
client, process-group reaping, per-command cleanup failure reporting, private
ADB routing, and the final-window schedule with a fake ADB server. The live
reference-host run and its evidence are recorded in M01 after this
implementation is committed; no boot or root-cause result is inferred from
the unit tests. A close-time regression checks that observer shutdown waits
through the full derived final-probe reservation.
IR-141 adds a separate main/system/crash query while retaining the
events-only query for process-event counts. The expanded-query live capture is
recorded in IR-142 below.

## IR-140: Run a 2400-second untraced U-Boot and Android observation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; `Images/reference/16373615/incomplete/default-20261003T115618-900776/` |

**Choice.** Run one 2400-second `default` capture with normal U-Boot
progression, no console commands, no vCPU tracing, and the established
four-CPU, 4096-MiB, `guest_swiftshader` Cuttlefish configuration. Enable the
existing boot observer to sample crosvm RSS every five seconds and begin ADB
polling after launcher event 5. Use its new bounded final events-buffer
summary; do not retain raw logcat output. Record the separate manual
events-buffer query and its incomplete cleanup verification as a limitation.
Keep this record diagnostic and incomplete unless Android reports
`sys.boot_completed=1` or an equivalent documented completion marker.

**Reason.** The attached diagnosis recommends an ordinary untraced capture
that can correlate U-Boot/Linux marker timing, crosvm RSS, and later ADB and
Android progress. This isolates those observations from the vCPU tracing and
paused-console probes while keeping the guest configuration fixed. The
result's 116-second U-Boot-to-Linux interval and RSS milestones are consistent
with substantial guest memory becoming resident around the transition, but
the configured `ddr_mem_mb=4915` means a 4-GiB RSS crossing does not show that
all RAM was resident. Prior intervals vary substantially, so this run does
not establish a deterministic scan rate or cache-maintenance cause. The
`system_server` SELinux-domain calls and two untracked same-name process exits
do not establish a causal relation. The zombie entries identify PIDs 2086 and
4156; the later all-CPU snapshot shows PID 1700 for `system_server` on CPU 3,
so the records do not link either exit to PID 1700. A task named `watchdog`
issued SysRq blocked-state, memory, and all-CPU backtrace requests. No blocked
task entry appears before the memory dump, which reports 620,318 free pages
and 0 kB total/free swap. These are snapshot values and do not establish why
the SysRq dump was triggered or rule out earlier or later memory pressure.
`kernel.log` ends at that dump; RSS sampling continued to the capture
deadline, while the private ADB server had already stopped after the final
events query. A successful events query with zero allowlisted matches does
not prove the events buffer was empty, and the separate timed-out manual
query has no retained output or verified process-group cleanup. That query
was capped at ten seconds and 64 KiB. Keep all of these inferences bounded to
the recorded observations.

**Verification.** `host.json` records the 2404-second capture duration and
the selected build/profile; `post-run-verification.json` records the source
revision and matching local/Lima source hashes. The ten-entry Lima-side
manifest verifies on the host. The post-capture inventory found an empty
Cuttlefish fleet, no crosvm or `process_restarter`, no private ADB listener,
and the pre-existing loopback ADB server on 127.0.0.1:5037, which was left
untouched. The observer's final events query and private server cleanup
completed; the separate manual query cleanup remains unverified. Privacy
scans found no tested host paths, MAC/EUI-64 addresses, or PEM key markers.
The full Image tools suite passed 394 tests with four skips on macOS and 397
tests with one skip on Lima Linux. After the final test-fixture-only ADB
interval adjustment, the targeted regression passed on both systems and
Ruff/format checks passed. All six `scripts/ci/run-checks.sh` checks passed
before that final fixture-only adjustment. The capture did not record Android
boot completion and does not resolve the U-Boot or Android failure cause.

## IR-141: Summarize bounded Android logcat markers after incomplete boot

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py` |

**Choice.** Keep the finite-deadline one-shot ADB probe and run two sequential
logcat queries after a fresh `device` state: the existing 128-line,
ten-second, 64 KiB `events` query, followed by a 128-line, ten-second, 64 KiB
query for the `main`, `system`, and `crash` buffers. Raise the final probe
reservation from 28 seconds to 40.5 seconds; its computed minimum is 39
seconds. Keep process-event counts only from `events`. Put the second query's
bounded command status and fixed counts for lines mentioning `FATAL
EXCEPTION`, `Fatal signal`, ANR text, `Watchdog`, `system_server`, and
`zygote` in a nested `androidLogcat` object. Keep both command outputs in
memory and persist only counts and bounded statuses. Do not write log lines,
guest-log timestamps, tags, PIDs, package names, or other guest identities;
the JSONL record retains its ordinary host-side `timestampUtc`.

**Reason.** The 2400-second capture in M01 reached Linux, first-stage init,
zygote, and servicemanager calls attributed to `system_server`, but did not
record `sys.boot_completed=1`. Its final `events`-buffer query succeeded
with zero recognized process events. The kernel log also records a watchdog
task issuing SysRq dumps and a later all-CPU snapshot of PID 1700 for
`system_server`. The events buffer alone could not reveal AndroidRuntime,
ANR, native-fatal-signal, or Watchdog text from the main, system, or crash
buffers. The attached diagnosis recommends inspecting ADB logcat when Linux
progresses but Android does not complete. A single `all`-buffer query would
mix process-event tags with regular log text and could inflate event counts
without proving each line's buffer. Separate bounded queries preserve that
provenance and add only 12.5 seconds to the reserved window. The second
query's line counts are mentions, not proof that an exception, crash, ANR,
or watchdog caused the incomplete boot. A truncated or timed-out query may
contribute counts from its captured prefix.

**Verification.** Focused tests cover separate buffer selections, marker
counts, event-source provenance, one-shot private ADB routing, the derived
39-second minimum and 40.5-second reservation, command bounds, and assertions
that event payloads, app names, PIDs, guest timestamps, and marker text are
not written to JSONL. The full Image tools suite passed 396 tests with four
skips on macOS and 399 tests with one skip on Lima Linux. The dedicated
timestamp-privacy regression passed on both systems. Ruff, formatting,
whitespace, and final hostile-review checks passed. The live reference-host
verification with both buffer-scoped queries is recorded in IR-142.

## IR-142: Live verify bounded Android boot log summaries

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; [risks.md](risks.md) R-06; `Images/reference/16373615/incomplete/default-20261003T131605-949526/` |

**Choice.** Repeat the untraced `default` capture for 2400 seconds with the
established four guest CPUs, 4096 MiB memory, 4915 MiB configured DDR,
`guest_swiftshader`, console off, and normal U-Boot progression. Enable the
five-second RSS observer and the private ADB probe after launcher event 5.
Keep the result incomplete because Android did not report
`sys.boot_completed=1`; retain the normalized capture, bounded summaries, and
post-run cleanup evidence. Do not treat the absence of composite-disk
specifications in the Cuttlefish config as a boot failure.

**Reason.** The supplied diagnosis predicts a slow U-Boot-to-Linux transition
followed by a separate Android startup problem. In this run, the U-Boot banner
was logged at 12:36:05 and Linux 6.12.74 at 12:42:09 in Lima's Asia/Tokyo
local time, an interval of 364 seconds (03:36:05Z to 03:42:09Z). The
first five-second sample with both VmRSS and RssShmem at or above 4 GiB was
03:42:12.208Z (4,216,200 and 4,194,532 KiB), three seconds after the Linux
banner. This supports slow guest-memory residency around the transition but
does not establish a RAM-wide cache flush or its cause.

Launcher event 5 occurred at 03:51:01.248Z and the private ADB server was
ready at 03:51:02.259Z. The first `device` state arrived at 03:51:57.272Z.
Across 96 polls, three had no device state; the remaining 93 reported
`device`. Their property commands timed out 56 times and exited successfully
37 times without an accepted property value. No poll returned a value for
`sys.boot_completed`.

The terminal events-buffer query succeeded with 23,984 bytes and zero
recognized process events. The separate main/system/crash query succeeded
with 18,338 bytes and was neither truncated nor timed out. Its fixed marker
counts were zero for fatal-exception lines, fatal-signal lines, ANR text, and
`system_server` mentions; it recorded ten Watchdog mentions and eight zygote
mentions. These are line mentions, not proof that a Watchdog action or zygote
activity caused the incomplete boot. A separate manual bounded logcat query
timed out after ten seconds with zero captured bytes and completed client
cleanup. Its timestamp was not recorded, so its order relative to the
terminal query is unknown.

`kernel.log` records zygote startup at guest uptime 234.916 seconds and
`sys.bootstat.first_boot_completed=0` at 557.083 seconds; the latter is not
Android boot completion. The log continues with repeated audioserver
`aidl/activity` lookups through guest uptime 2029.731 seconds. Neither the
kernel log nor the ADB probe establishes `sys.boot_completed=1` or a
`VIRTUAL_DEVICE_BOOT_COMPLETED` marker. The 2402-second capture ended at its
deadline. `cvd-create-console.log` also records two `liblp` errors reporting
invalid logical-partition geometry magic at 12:36:02.231 Lima local time.
Their relevance to the incomplete guest boot is unknown. The JSON-only
collector found no composite-named keys in `cuttlefish_config.json` and
recorded `composite-disk-specs.json` as missing. That capture did not
inventory the dedicated files later found in the selected instance runtime,
so their presence in that run cannot be determined. The unavailable
normalized artifact prevents profile publication but does not determine the
cause of the guest state. Update R-06 to say that #064 cannot provide a
known-good Cuttlefish boot baseline until Android boot completion is recorded;
this result must not be projected onto the separate VZ topology.

**Verification.** The observer recorded 481 crosvm-memory events, of which
479 contained valid RSS values. The first valid sample was 90,904 / 69,088
KiB VmRSS/RssShmem at 03:36:07.208Z. The last was 4,233,192 / 4,205,908 KiB
at 04:15:57.209Z. The Lima SHA-256 manifest covers the nine normalized
capture files and `post-run-verification.json`; all ten entries verified on
the host. Local and Lima source hashes match for the image manifest, observer,
capture script, start helper, and normalization rules. Post-run checks found
an empty Cuttlefish fleet, no crosvm or `process_restarter`, no private ADB
socket or listener on port 6520, and only the loopback ADB server on port
5037, whose process predates this capture and was left untouched. Privacy
scans found no tested private host paths, MAC/EUI-64 addresses, or PEM key
markers. The macOS Image tools suite passed 396 tests with four skips; the
Lima Linux suite passed 399 tests with one skip. The hostile review of IR-141
found no actionable findings. This capture still does not satisfy #064's
boot-completion acceptance criterion or establish the U-Boot or Android
failure cause.

## IR-143: Record the SystemServer boot milestone during reference capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; `Images/tools/tests/test_reference_capture.py` |

**Choice.** Extend each private-socket ADB poll to read
`sys.system_server.start_count` and `sys.boot_completed` in one ten-second
shell command. Store a bounded integer count when available and a nullable
Boolean indicating whether a successful query returned a non-empty
start-count value. For `sys.boot_completed`, store a nullable Boolean
`sysBootCompletedPresent` for a successful non-empty value and parse only
`0` or `1` into the nullable Boolean readiness signal. This distinguishes an
empty value from an unexpected non-empty value without retaining property
text.
The shell query replaces non-digit `start_count` values and `boot_completed`
values other than empty, `0`, or `1` with a fixed marker so property contents
cannot inject protocol lines. Accept only the fixed output order emitted by
the shell command; retain a valid prefix when a timeout truncates the reply.
Reject unexpected, duplicate, empty interior, or out-of-order lines by
invalidating the entire reply, including its exit statuses. Record each
property command's bounded exit status independently with a non-newline
delimiter, so command substitution preserves trailing property newlines.
Remove only the single output newline emitted by `getprop` before validating
the value. This prevents a value ending in `1` plus a newline from becoming
the accepted value `1`. Accept CRLF transport line endings by removing one
carriage return only when it is immediately before a line feed. Preserve a
terminal carriage return without a following line feed; shell-side value
sanitization ensures the CRLF normalization cannot restore a raw property
value. Pass successful and partial-timeout property output from `_run_adb`
without trimming so this framing validation also applies to the real
subprocess path; normalize whitespace only for the separate `get-state`
response. The enclosing shell command's final status-printing command can
succeed after an individual `getprop` fails. Parse partial timeout output in
memory without storing it. The JSONL uses the explicit fields
`systemServerGetpropExitCode` and `bootCompletedGetpropExitCode`.

**Reason.** The runtime boot design uses a non-empty
`sys.system_server.start_count` as its `.systemServer` readiness signal. Prior
reference captures reached Linux and zygote but did not report
`sys.boot_completed=1`. Recording this existing signal can distinguish a
SystemServer milestone from later framework boot without another ADB client,
extending the poll interval, or retaining guest logs.

**Verification.** Parser tests cover valid counts, empty and malformed
values, non-ASCII digits, overflow, duplicate fields, independent command
failures and their recorded exit statuses, CRLF transport line endings,
unterminated trailing-carriage-return handling,
carriage-return property-value sanitization, valid partial prefixes, fixed
field ordering, malformed output rejection, multiline property-value
sanitization, boot-completion presence and Boolean parsing, and preservation
of a trailing carriage return or duplicate final line feed through `_run_adb`.
ADB observer tests execute the fixed shell query with a fake `getprop` for
success and independent property failures, verify the resulting JSONL
status fields, cover missing and timed-out polls and partial timeout
parsing, and confirm that neither property payload is written to JSONL.
The focused observer suite had 84 cases: 83 passed and one platform-specific
case was skipped on macOS; all 84 passed on Lima Linux. The full Image tools
suite passed 433
tests with four skips on macOS and 428 tests with nine skips on Lima Linux.
The shared-deadline integration test accepts the positive, integer-second
remainder up to its configured 600-second ceiling and checks that subsequent
command deadlines decrease.
One full macOS run observed 599 seconds because the shared deadline is
computed with second-resolution timestamps; the isolated case and the final
full suite passed. Treating 599 as valid avoids a timing-sensitive assertion
without allowing a command deadline to exceed the configured ceiling. Ruff
lint and format, shell syntax, and `git diff --check` passed. The initial
hostile review caught stale test counts (P3); they were refreshed from these
final runs. A later review found that `_run_adb` stripped output before the
parser could reject malformed framing (P2). Successful and partial-timeout
property output now reaches the parser unchanged; whitespace normalization
is limited to the separate `get-state` response. Regression cases exercise a
bare terminal carriage return and duplicate final line feeds through
`_run_adb`. The final hostile re-review of the corrected provenance and
verification counts found no findings.

Live verification used an untraced, unpaused 2400-second `default` capture
with four guest CPUs, 4096 MiB memory, 4915 MiB configured DDR,
`guest_swiftshader`, and console off. `host.json` records a 2403-second
capture. The normalized result and post-run evidence are in
`Images/reference/16373615/incomplete/default-20261003T151738-1012957/`.
This capture predates `sysBootCompletedPresent`: its
`post-run-verification.json` records source revision `af7f5d4`, so the 54
successful boot-completion queries cannot distinguish empty from unexpected
non-empty output. Raw property output was not retained and cannot be
recovered for this record.
Launcher timestamps place the U-Boot banner at 05:37:39Z and Linux 6.12.74
at 05:41:18Z, 219 seconds later. The first five-second sample with both
VmRSS and RssShmem at or above 4 GiB was 05:41:20.333Z (4,216,192 and
4,194,532 KiB), two seconds after the Linux banner. This is consistent with
substantial guest-memory residency around the transition, but does not prove
a RAM-wide cache flush, a deterministic scan rate, or its cause.

The kernel log records first-stage init at uptime 23.015 seconds, the
`zygote-start` init action at 98.229 seconds, the zygote service start request
at 98.384 seconds, the service process start at 98.473 seconds, and
`bootanim` at 319.644 seconds. It contains 38 service-manager lookups
attributed to the `system_server` SELinux domain between uptimes 994.970 and
2077.182 seconds. These calls do not prove the
`sys.system_server.start_count` readiness signal. Across 126 observer polls,
124 reported `device`. Successful `getprop sys.system_server.start_count`
commands were recorded in 81 polls and all returned an empty property;
`getprop sys.boot_completed` exited 0 in 54 polls, but no poll produced a
parsed value or reported `1`. Other commands timed out. Neither property
payload was retained. Both final logcat queries timed out with zero captured
bytes and completed client cleanup, so the run could not provide logcat
marker counts. No `VIRTUAL_DEVICE_BOOT_COMPLETED` marker was found.

The console log again reports invalid logical-partition geometry magic; its
relevance remains unknown. The missing normalized composite-spec artifact
prevents profile publication but does not establish the boot cause. The JSON-only collector found no
composite-named keys; this run did not inventory the dedicated instance files
later identified by IR-151, so their presence is unknown. Post-run checks
found an empty Cuttlefish fleet, no crosvm or `process_restarter`, no private
ADB listener on port 6520, the removed private socket HOME, and only the
pre-existing loopback ADB server on port 5037. All ten Lima manifest entries
verified against the host capture, all five Lima source hashes matched the
local sources, and privacy scans found no tested private host paths,
MAC/EUI-64 addresses, or PEM key markers. The run does not establish Android
boot completion or a root cause.

## IR-144: Verify the unpaused U-Boot transition with a bounded retry

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; `Images/reference/16373615/incomplete/default-20261003T165948-1083660/` |

**Choice.** Repeat the `default` profile with the existing four-CPU,
4096-MiB guest, `guest_swiftshader`, console disabled, and normal unpaused
U-Boot path. Extend the boot deadline to 2400 seconds while leaving the guest
configuration unchanged. Keep vCPU tracing and console interaction disabled.
Use the existing passive five-second crosvm RSS sampler and private-socket ADB
observer during `cvd start`. Preserve the normalized run as incomplete because
the deadline expired and required profile artifacts are missing.

**Reason.** IR-127 identified a longer, untraced run as the next way to
distinguish a slow U-Boot-to-Linux transition from later Android startup.
Passive memory and ADB observations avoid the additional perturbation of vCPU
tracing and allow transport readiness to be measured before `cvd start`
returns. An incomplete run is still useful evidence, but it must not be
promoted to a reference profile or treated as a root-cause diagnosis.

**Verification.** The Ubuntu 24.04.4 arm64 Lima VM ran Cuttlefish 1.57.0 with
nested virtualization enabled. `host.json` records a 2403-second duration
and eight host CPUs. `cuttlefish_config.json` records four guest CPUs,
4096 MiB configured memory, 4915 MiB configured DDR, `guest_swiftshader`,
and console off. The source revision was
`9695c947748d9e972a7b547fceaac17b43524121`; the sidecar records matching
local and Lima SHA-256 values for the manifest, observer, capture script,
start helper, and normalization rules. The captured observer predates the
later CRLF parser and raw-output framing fixes.

The U-Boot banner at 07:19:50Z was followed by Linux 6.12.74 at 07:21:31Z,
an interval of 101 seconds. Of 481 five-second memory events, 479 were valid.
VmRSS first reached 4 GiB at 07:21:31.168Z (4,212,728 KiB); RssShmem first
reached 4 GiB at 07:21:36.168Z (4,194,532 KiB). These RSS values are
residency observations and do not prove a RAM-wide cache flush, its execution
path, or its cause. The 101-second interval also does not establish a
deterministic scan rate; earlier captures recorded materially different
U-Boot-to-Linux intervals.

First-stage init appeared at guest uptime 26.998 seconds, zygote at
111.284 seconds, and boot animation at 410.584 seconds. Init set
`sys.bootstat.first_boot_completed` to `0` at uptime 262.373 seconds. A later
zygote restart occurred at uptime 2147.331 seconds after init killed the
earlier process. Neither this event nor the two `system_server` text
mentions in the final diagnostic logcat establish a cause. The events-buffer
summary recognized zero process events; the other diagnostic counts for ANR,
fatal exception, fatal signal, Watchdog, and zygote were zero. No
`VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`, or parsed
`sys.boot_completed` signal was recorded.

Launcher event 5 occurred at 07:25:42.881Z, and the private ADB server was
ready at 07:25:46.220Z. Of 132 private-socket polls, 130 reported `device`.
Among 130 attempted property commands, 113 timed out and 17 outer shell
commands exited 0; neither per-property exit status parsed in any poll, and
both property values remained null. Raw property output was intentionally
not retained, so the exact reason is unknown. The capture therefore measures
ADB transport availability but does not prove that CRLF caused the parser
failure or establish SystemServer readiness.

`MISSING.txt` records the 2400-second deadline, no crosvm command line at
artifact-collection time, and a missing normalized composite-spec artifact.
The JSON-only collector found no composite-named keys; this run did not
inventory the dedicated instance files later identified by IR-151, so their
presence is unknown. The sidecar records complete capture-client cleanup, an
empty Cuttlefish fleet, no crosvm or `process_restarter`, no private ADB
listener on port 6520, and preservation of the pre-existing loopback server
on port 5037. One offline
ADB entry was explicitly disconnected and the device list was then empty.
The ten Lima manifest entries verified on the host, and privacy scans found
no tested private host paths, MAC/EUI-64 addresses, or PEM key markers. This
run does not satisfy #064's boot-completion or reference-profile criteria.

## IR-145: Trigger ADB observation independently of RSS sampling

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py` |

**Choice.** Rescan the launcher log on a one-second schedule while keeping
RSS sampling on its existing configured interval. Start the ADB observer as
soon as the scan detects launcher event 5, even when the next RSS sample is
not due.

**Reason.** The previous scheduler only noticed event 5 during a five-second
memory sample. The ADB observer could therefore start several seconds after
the launcher event, and the same coupling delayed the first poll. Separating
the launcher scan schedule reduces that avoidable diagnostic delay without
increasing the default RSS sampling rate.

**Verification.** A regression test places event 5 between RSS deadlines and
confirms that the ADB observer starts before the next memory sample, with no
additional RSS record. `Images/tools/tests/test_boot_observer.py` passed 84
tests with one Linux-only skip. Ruff lint and format checks passed. Hostile
review found no actionable issues. The live effect remains to be verified in
a subsequent reference capture.

## IR-146: Prioritize and preserve the boot-completion query

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py` |

**Choice.** Query `sys.boot_completed` first and emit its sanitized value and
exit status before querying `sys.system_server.start_count`. When the combined
shell command times out, permit the parser to ignore only a final
unterminated fragment that is a prefix of the next expected field label.
Retain the complete earlier property pair in that case; continue to reject
complete malformed or out-of-order lines.

**Reason.** The boot-completion property is the primary signal required by
#064. A later SystemServer query must not hide a result already obtained.
Timeout output can end in the middle of a shell protocol field, so parsing
needs a narrowly bounded way to preserve the preceding complete pair without
weakening validation for normal or fully malformed replies.

**Verification.** Shell integration tests confirm the boot property is
emitted before the SystemServer query and remains parseable when that later
query is interrupted. ADB-poll tests confirm truncated-label retention is
enabled only for a timed-out shell command. The focused property tests passed
41 cases; `test_boot_observer.py` passed 86 tests with one Linux-only skip.
Ruff lint and format checks passed. Hostile review found and prompted a fix
for the incomplete-label boundary; follow-up review found no remaining
issues.

## IR-147: Preserve per-stage ADB transport diagnostics

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8.3; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py` |

**Choice.** Add `connectAttempted`, `connectTimedOut`, `getStateAttempted`,
`getStateExitCode`, and `getStateTimedOut` to each `adb_poll` record. Keep
timeouts null when a stage did not start. Add the fixed `getStateResult`
classification `notAttempted`, `timedOut`, `commandFailed`, `device`,
`offline`, `unauthorized`, `empty`, or `other`; do not persist raw output.

**Reason.** The aggregate `commandTimedOut` field cannot show which command
timed out or distinguish an unstarted command from a successful command with
an unrecognized response. Per-stage status makes the host ADB transport
diagnosable while the allowlist avoids retaining guest or host command text.

**Verification.** Parameterized tests cover connect launch failure and
timeout, get-state timeout and nonzero exit, empty and unrecognized output,
recognized states, and a deadline that prevents the later command from
starting. They also assert that unrecognized raw output is absent from the
JSONL record. The focused stage tests passed 14 cases;
`Images/tools/tests/test_boot_observer.py` passed 91 tests with one
Linux-only skip. Ruff lint and format checks passed. Hostile review found no
actionable issues. A subsequent reference run will verify the live record
shape.

## IR-148: Preserve the incomplete unpaused default capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §8; `Images/reference/16373615/incomplete/default-20261003T183619-1148306/` |

**Choice.** Keep the 2400-second unpaused `default` run under `incomplete/`.
Do not publish it as a profile because the boot deadline expired and the
normalized composite-spec artifact was missing after the JSON-only collector
found no composite-named keys. The run did not inventory the dedicated
instance files later identified by IR-151, so their presence is unknown.
Record the observations and cleanup checks without assigning a root cause.

**Reason.** The run supplies another long observation of the U-Boot-to-Linux
transition, guest memory residency, ADB transport, and bounded Android
logcat while preserving the existing guest configuration. Missing required
profile artifacts and boot-completion evidence make it unsuitable as a
reference profile. In particular, the absence of a crosvm command line at
artifact collection does not mean crosvm never ran; the observer recorded
480 valid memory samples.

**Verification.** The Ubuntu 24.04.4 aarch64 Lima VM used Cuttlefish 1.57.0,
nested virtualization, four guest CPUs, 4096 MiB memory, 4915 MiB DDR,
`guest_swiftshader`, console off, and a 2400-second guest boot deadline.
`host.json` records a 3002-second total capture duration. The U-Boot banner
at 17:46:21 Lima local time was followed by Linux 6.12.74 at 17:52:00, 339
seconds later. Of 481 crosvm memory events, 480 had valid RSS data. VmRSS
first reached 4 GiB at 08:51:57.755Z; RssShmem did so at 08:52:02.755Z.
Launcher event 5 occurred at 08:59:30.761Z, with the private ADB server
ready 2.046 seconds later. Of 103 polls, 99 reported `device`; all property
values and statuses remained unparsed. The final logcat queries completed,
with zero recognized process events and five Watchdog mentions in the
diagnostic buffers. No boot-completion marker or parsed boot property was
recorded.

The Cuttlefish fleet was empty after cleanup, the private server and socket
HOME were removed, and the pre-existing loopback ADB server on port 5037 was
preserved. All nine entries in `LIMA-SHA256SUMS` verified on the host; all
five copied sources matched revision
`736374602c7c64b67dbade2b78450758316e48e9`. Privacy scans found no tested
private host paths, MAC/EUI-64 addresses, or PEM key markers. This source
revision predates IR-145–147, so this capture does not live-verify those
observer changes and does not establish Android boot completion or a cause.

## IR-149: Record the live observer follow-up

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064; [android-image.md](../02-design/android-image.md) §7.7, §8; `Images/reference/16373615/incomplete/default-20261003T195146-1175735/` |

**Choice.** Keep this 2400-second unpaused `default` run under `incomplete/`.
Treat it as live verification of the event-5 observer trigger and per-stage
ADB transport records from IR-145 and IR-147. Do not mark the live property
parser behavior from IR-146 as verified: no property field was parsed. Record
the observed display-state marker without treating it as a boot-phase
completion signal. Do not attribute the guest state to the untracked
`system_server` process exit, the `aidl/activity` lookups, the liblp warnings,
or the missing composite-disk specs.

**Reason.** The guest boot deadline expired and `sys.boot_completed=1` was
never observed. The JSON-only collector found no composite-named keys in the
saved Cuttlefish config and recorded the normalized spec artifact as missing;
the run did not inventory the dedicated instance files later identified by
IR-151, so their historical presence is unknown. The captures preserve the
ADB stage outcomes and bounded logs, but the distinct `system_server` PIDs
and mention counts do not establish process causality or a failure cause.
The missing crosvm command line describes only post-timeout artifact
collection; 480 valid memory samples prove that crosvm was observed earlier.

**Verification.** On the Ubuntu 24.04.4 aarch64 Lima VM with Cuttlefish 1.57.0
and nested virtualization, U-Boot was logged at 10:11:46Z and Linux 6.12.74
at 10:15:07Z. The observer recorded 481 memory events (480 valid), event 5
at 10:20:55.277Z, and private ADB server readiness at 10:20:55.328Z. Of 119
ADB polls, 116 reported `device`, three `get-state` commands failed, one
`connect` timed out, and the other 118 `connect` commands exited 0. Of 116
property attempts, 113 timed out and three outer shell commands exited 0
without parsed property fields. The final events query captured 20,620 bytes
with zero recognized process events; the diagnostic buffers captured 17,148
bytes with 10 `system_server` mentions and five Watchdog mentions. The kernel
log records `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED display=0 mode=ON` at
guest uptimes 485.849 and 547.700 seconds, but no
`VIRTUAL_DEVICE_BOOT_COMPLETED` marker.

The Cuttlefish fleet was empty after cleanup; no crosvm or
`process_restarter` remained, private port 6520 had no listener, the private
socket HOME was removed, and only the ADB server already bound to
`127.0.0.1:5037` remained. All ten `LIMA-SHA256SUMS` entries verified on the
host, all five source-copy hashes matched revision
`fa9c0ee1f7e4ab6a07e594e93264f371fbd96286`, and privacy scans found no tested
private host paths, MAC/EUI-64 addresses, or PEM key markers. The run is not
a reference profile and does not establish a boot failure cause.

## IR-150: Bound regular ADB poll subprocesses

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Run ordinary `connect`, `get-state`, and boot-property ADB
commands through the process-group runner already used by the final probe.
Cap their stdout at 4 KiB and record per-stage truncation, probe-error, and
cleanup status. Do not accept truncated or probe-error `get-state` replies
as device states, and do not parse truncated or probe-error property replies.
If process-group cleanup is unverified, record the poll, stop later ADB work,
and fail capture shutdown. Increase the regular-poll reservation to 25.5
seconds.

**Reason.** The previous `subprocess.run(timeout=...)` path killed only its
direct ADB client and did not bound its output or verify descendants. A
descendant could therefore remain after a poll timeout, while the final
capture status looked clean. The reservation covers three maximum command
timeouts (14 seconds), three process-group cleanup bounds (7.5 seconds), and
a four-second scheduling margin. A probe can also yield a valid-looking
`device` prefix before a later read error; treating that partial observation
as a valid state would make the recorded result misleading.

**Verification.** A focused regression supplies `device` output together
with `probeError` and confirms that no `deviceState` is accepted and no
property query starts. `pytest Images/tools/tests -q` passed 445 tests with
four platform skips. Ruff format and lint checks passed. Hostile review found
and fixed the misleading `device` classification when a later read error
occurred; the follow-up review found no further actionable issue. The
2026-10-03 live capture used source revision
`fa9c0ee1f7e4ab6a07e594e93264f371fbd96286`, before this change, so it does
not live-verify this process cleanup path.

## IR-151: Collect composite-disk config files from the selected instance

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/capture.sh`; `Images/tools/reference/collect_composite_specs.py`; `Images/tools/tests/test_collect_composite_specs.py`; `Images/tools/tests/test_reference_capture.py`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Build `composite-disk-specs.json` from every
`*_composite_disk_config.txt` file beneath the selected Cuttlefish instance
runtime beneath the per-run private Cuttlefish HOME. Store the UTF-8 contents
in a `files` object keyed by relative path. Walk and open descendants relative
to directory descriptors with no-follow flags. Reject matching config paths
that are symlinks or non-regular files (including FIFOs), as well as empty
files, invalid UTF-8, more than 32 matching files, files over 256 KiB,
aggregate content over 1 MiB, inventories over 100,000 entries or 4096
directories, and directory depth over 128. Skip unrelated symlinks without
following them. Resolve `/tmp` to its physical path, require it to match a
normalizer-supported temporary root, and use that same path for the private
Cuttlefish HOME and `TMPDIR`, regardless of the caller's `TMPDIR`. This keeps
host-generated paths under roots covered by normalization, keeps temporary
socket paths short, and makes startup and removal use the same HOME when
`/tmp` is a symlink. Keep missing or rejected input in `MISSING.txt`; do not
infer disk topology from image names or unrelated configuration.
Remove interrupted temporary JSON before normalization. If cleanup fails,
attempt to discard the staging tree; when removal also fails, report the path
for manual cleanup.

**Reason.** The live Cuttlefish 1.57.0 instance had dedicated composite-disk
config files in `instances/cvd-1`, while its `cuttlefish_config.json` had no
composite-named keys. The old collector searched only the JSON object and
reported those real files as missing. Reading the selected instance's emitted
config files supplies the serialized data without synthesizing topology.
Descriptor-relative traversal closes the parent-symlink race; nonblocking
opens and bounded incremental inventory prevent special-file hangs and
unbounded directory fan-out. A hostile review found that a caller-selected
`TMPDIR` could be outside the normalizer's known roots, so the capture now
resolves `/tmp`, verifies its physical path is supported for normalization,
and uses that path for Cuttlefish HOME and temporary files. This preserves the
privacy guarantee, keeps socket paths short, and avoids alias mismatches
between startup and cleanup. Cleanup before interrupted normalization
prevents raw temporary JSON from entering a retained incomplete capture.
JSON path normalization prevents private host paths from surviving in the
capture.

**Verification.** The full image-tools suite passed 465 tests with four
platform-specific skips. All six checks in `scripts/ci/run-checks.sh` passed;
Ruff lint and format, `sh -n Images/tools/reference/capture.sh`, and
`git diff --check` passed. The 19 collector tests also passed on the Linux
reference VM, in addition to the macOS run. A follow-up hostile review found
no actionable findings. Fresh 2403-second `default`, 2405-second `target`
(`drm_virgl`), and 2405-second `swiftshader` captures completed with all
three selected-instance files in each composite artifact. For each run, the
11-entry Lima manifest (ten normalized capture files plus
`post-run-verification.json`) verified on the host. The sidecars retain
source-copy hashes, privacy-scan counts, and post-capture cleanup
observations; scans found no tested host paths, MAC/EUI-64 addresses, or PEM
private-key markers. The `target` observer's final events-buffer query
recorded 23,987 bytes and zero recognized process events. Its separate
20,611-byte Android diagnostic logcat query counted two SystemServer and ten
Watchdog mention lines, with zero ANR, fatal-exception, fatal-signal, or
zygote mention lines. The `default` and `swiftshader` runs' final logcat
queries timed out with zero captured bytes. The `swiftshader` run reached
Linux, first-stage init, and zygote; init successfully set
`sys.bootstat.first_boot_completed` to `0` at guest uptime 475.263 seconds.
This is separate from the observer's 82 property queries after ADB reported
`device`, which all timed out. These bounded observations do not establish a
boot cause. Post-run checks for all three runs found an empty Cuttlefish
fleet, no crosvm or `process_restarter`, no private ADB listener, removed
private HOMEs, and no leftover composite-spec temporary files. All three
captures remain under `incomplete/` because no boot-completion property or
marker was observed; none satisfies the reference-profile or boot
acceptance criteria. Hostile review of the SwiftShader record found two
wording inaccuracies about its bootstat property and zygote start timing;
both were corrected, and follow-up review found no remaining actionable
findings.

## IR-152: Distinguish shell startup from a stalled boot-property query

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Initial choice (superseded by IR-153).** On the first boot-property command that is actually launched after
ADB reports `device`, prefix the existing shell command with the fixed
`APKRun shell ready` marker. Run it in the same ADB client, timeout, 4 KiB
output cap, and process group as the property queries. Record only bounded
status fields and whether stdout began with the marker. Remove the marker
from in-memory output before property parsing, and never retain the command
output. If the command could not launch, leave the one-shot marker pending
for the next property attempt; after a launched attempt, do not retry it.
Recognize and strip the marker with either LF or CRLF line framing.

**Reason.** In the three incomplete reference captures, ADB often reported
`device` while the property query returned no parsed values. The existing
combined shell command prints no property status until after `getprop`
returns, so its timeout does not show whether the shell reached the command
or stalled while querying a property. A leading fixed `printf` records shell
progress before the property calls with no guest-state changes. A matched
marker proves that the shell reached that statement; a missing marker alone
does not prove why the command failed. Using the existing bounded ADB client
avoids a second shell request and leaves the 25.5-second regular-poll reserve
and 40.5-second final-logcat window unchanged. Hostile review caught a false
negative when the marker used CRLF; the marker parser and regression coverage
now accept both supported line endings and preserve subsequent property
fields.

**Verification.** The focused boot-observer regressions passed 22 tests,
including CRLF preservation, one-shot behavior, marker privacy, timeout
handling, cleanup failure, and the unchanged deadline reserve. The full
image-tools suite passed 468 tests with four platform-specific skips. All six
checks in `scripts/ci/run-checks.sh`, Ruff lint and format, shell syntax, and
`git diff --check` passed. Hostile review found a CRLF marker false negative;
the parser and regression test now cover both LF and CRLF, and follow-up
review found no actionable findings.

A fresh `swiftshader` run at
`Images/reference/16373615/incomplete/swiftshader-20261004T021050-1310893/`
used source revision `1f204c5e30a3017e234b0167b1ead99e2e43bfdc`. `host.json`
records `captureDurationSeconds=2406`; this field excludes the later ADB and
Cuttlefish teardown. The observer start-to-stop interval was 2400.118 seconds.
The first launched property query followed `get-state=device` at
16:44:36.085Z and timed out with exit -15 before a matching one-shot marker
was received. Across 103 polls, 100 reported `device` and three `get-state`
commands exited 1. The 100 property queries yielded no parsed values: 96
timed out with exit -15 and four exited 0. The final bounded logcat queries
did return data, but that does not locate the stalled shell/property
operation. `kernel.log` contains Linux and zygote traces; the separate Android
logcat summary counted zero zygote mentions. No `sys.boot_completed=1` signal
was recorded. The run therefore confirms the marker timeout behavior without
establishing whether the shell reached the marker or identifying a boot cause.
All 11 Lima-side manifest entries verified on both hosts; source-copy hashes,
normalization idempotence, privacy scans, and post-run cleanup checks passed.
The capture remains incomplete and is not a reference profile.

## IR-153: Probe Android shell independently of boot properties

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** On the first poll where ADB reports `device`, run the fixed
`APKRun shell ready` `printf` command as a separate bounded `adb shell`
request. Use that guest-command slot in place of the poll's property query;
resume property queries on the next scheduled poll. Keep the probe one-shot:
if the process was not launched, retry on the next eligible poll; after a
launched attempt, do not retry. Persist only exit, timeout, truncation,
cleanup, probe-error, and marker-match fields. Retain no command output.

**Reason.** The IR-152 live capture timed out before returning its marker while
the marker and both `getprop` calls shared one shell command. That result does
not separate failure to return a simple shell command from a stall in a
property query. Running `printf` alone makes the shell response independently
observable. Replacing the first poll's property query with this probe keeps
the same number and maximum duration of guest ADB clients, preserves the
25.5-second polling reserve, and leaves only the first property sample
deferred until the next scheduled poll (15 seconds later). This is an
opt-in diagnostic probe and does not change guest state.

**Verification.** Focused observer tests cover the standalone command,
marker success with LF and CRLF, missing-marker and timeout results,
one-shot retry only when the process did not launch, deferred property
sampling, cleanup failure, output privacy, and the unchanged polling reserve.
The boot-observer file passed 103 tests with one Linux-only skip after adding
multi-poll timeout and missing-marker cases; Ruff lint and format passed. The
full `Images/tools/tests` suite passed 473 tests with four platform-specific
skips. All six checks in `scripts/ci/run-checks.sh`, Ruff lint and format,
shell syntax, and `git diff --check` passed.
Adversarial review requested explicit no-retry coverage after a launched
timeout or missing marker; the multi-poll test now verifies both outcomes
resume at the property query without repeating the one-shot. Follow-up
hostile review found no actionable findings.

**Live verification (2026-10-03 UTC).** The 2404-second SwiftShader capture
at [the normalized incomplete record](../../Images/reference/16373615/incomplete/swiftshader-20261004T034715-1337678/)
used source revision `f2a152421003701302ceb64c9e2812221e839a33`. The ADB poll
record stamped `2026-10-03T18:23:27.943Z` shows that its first standalone
shell probe timed out with exit `-15`, returned no marker, and completed
process-group cleanup; the probe's start time was not recorded. Of 94 ADB
polls, 91 reported `device`; the 90 property queries had 88 timeouts and two
exit-zero results, but no accepted property values. The kernel log recorded
Android first-stage init at guest uptime 25.868 seconds and zygote started at
197.418 seconds, but no `sys.boot_completed=1`,
`VIRTUAL_DEVICE_BOOT_COMPLETED`, or `VIRTUAL_DEVICE_BOOT_FAILED`. The final
bounded logcat requests completed, without recognized process events. The
capture remains incomplete. This confirms that the timeout was not limited to
the `getprop` query, but does not establish whether the guest shell began
executing the command or identify a boot cause. All 11 manifest entries and
seven source-copy hashes verified; privacy scans were clear and a second
normalization pass changed zero files.

## IR-154: Preserve the ADB observer's monotonic poll schedule

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Advance each ADB poll from its scheduled monotonic time, then skip
every elapsed 15-second slot until the next future slot. Do not calculate the
next poll from the previous poll's completion time.

**Reason.** A bounded poll can still take longer than one 15-second interval
when several ADB stages and process-group cleanup run near their limits.
Scheduling from its completion would shift all later polls, contrary to the
fixed monotonic schedule and the existing rule to skip missed slots rather
than replay them.

**Verification.** Regression cases cover a poll finishing before its next
slot, a 17-second overrun, multiple missed slots, and a poll ending exactly
on a scheduled boundary. The boot-observer suite passed 107 tests with one
Linux-only skip; Ruff lint, Ruff format, and `git diff --check` passed.
Adversarial review found no actionable findings. The #064 test plan now
describes the standalone shell probe and deferred property query used by the
implementation.

## IR-155: Compare the standalone shell probe across GPU profiles

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/capture.sh`; `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Run the next 2400-second diagnostic capture with the `target`
profile and the same standalone shell probe, explicitly setting
`APKRUN_TARGET_GPU_MODE=drm_virgl`. Compare it with the SwiftShader capture
using the same build, reference host, guest CPU and memory settings, and
insecure secure-HAL flags. Accept the comparison only if the captured
`host.json` records `targetGpuMode=drm_virgl` and `selectedGpuMode=drm_virgl`,
the selected-instance config agrees, and `MISSING.txt` is empty. A mismatch
capture may retain observer data for diagnosis but is not comparable. Do not
use `default` for this comparison because that profile also changes the
secure-HAL flags.

**Reason.** The standalone probe timed out without returning a marker in the
SwiftShader profile, while earlier `target` captures did not isolate a simple
shell command from the property query. Comparing `target` with `swiftshader`
holds the guest resources and secure-HAL settings constant while changing the
GPU mode. The comparison can show whether the observation also occurs with
`drm_virgl`; it cannot establish a boot cause.

**Verification plan.** Record the `target` capture's shell-probe, property,
kernel, and cleanup results in its normalized incomplete or complete capture.
Compare them with the SwiftShader record only after verifying that the actual
selected GPU mode matches the requested mode. A successful shell probe alone
does not satisfy #064 or validate Android boot.

## IR-156: Verify the selected Cuttlefish GPU mode before comparing profiles

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/capture.sh`; `Images/tools/tests/test_reference_capture.py`; [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Pass the requested GPU mode to both `cvd create` and `cvd start`
for `target` and `swiftshader`. Read the actual mode from the selected
instance's `cuttlefish_config.json`, bounded to 64 MiB, and record it as
`selectedGpuMode` in `host.json`; retain `targetGpuMode` to mean the requested
target-profile mode. Reject duplicate JSON keys so a last-value-wins parse
cannot accept an ambiguous GPU mode. If the live mode is absent, invalid, or
differs from the requested mode, write a reason to `MISSING.txt`, skip regular
ADB boot polling and guest capture, and retain the result only as an
incomplete diagnostic record. Revalidate the staged config before
publication; if it became absent, invalid, or different after the live check,
retain any ADB data already collected but mark the capture incomplete and
non-comparable.
Observer samples collected during `cvd start` do not make an incomplete
capture comparable.

**Reason.** Earlier `target` captures
`target-20261004T043330-1364484`, `target-20261004T051544-1366201`, and
`target-20261003T233118-1257055` recorded a requested
`targetGpuMode=drm_virgl`, but their selected-instance configs recorded
`gpu_mode=guest_swiftshader`. The captures establish that requested/selected
mismatch, but do not retain the exact capture-tool revision and command
arguments for each run. The repository's pre-IR-156 helper passed the GPU
mode to `cvd create` but omitted it from `cvd start`; this is a plausible
explanation for Cuttlefish selecting its default, not proof of the cause for
each capture. Comparing the request field alone could therefore attribute a
SwiftShader observation to `drm_virgl`. Verifying the selected config and
excluding mismatches keeps the diagnostic comparison tied to the runtime
configuration. Duplicate keys are rejected because the JSON parser's
last-value-wins behavior would otherwise allow an ambiguous config to appear
valid. A 64 MiB bound also prevents the newly inspected config from being
copied or parsed without a size limit.

**Verification.** The reference-capture suite passed 48 tests with three
Linux GNU `timeout` cases skipped on macOS. Coverage includes the correct
flags on both commands, matching mode metadata, live and staged mismatch,
missing and malformed config, an oversized sparse config, skipped ADB
commands for unusable live modes, non-standard JSON constants, conflicting
duplicate mode keys, staged config mutation after ADB begins, exactly one
mode-failure entry, bounded config copying, and private HOME removal. The
observer test uses a handshake from the observer-triggered ADB process so
`cvd start` stays alive until the launcher marker is recorded. Shell syntax,
Ruff lint and format, all six repository checks, and hostile review of the
capture implementation passed. The corrected real `drm_virgl` run and the
earlier mismatch captures remain incomplete; they are not successful
reference profiles.

## IR-157: Disable vhost-user GPU for arm64 reference captures

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/capture.sh`; `Images/tools/tests/test_reference_capture.py`; [android-image.md](../02-design/android-image.md) §8.2; [environment-setup.md](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Pass Cuttlefish's `--gpu_vhost_user_mode=off` flag to both
`cvd create` and `cvd start` for all three reference profiles. Read
`gpu_mode` and `enable_gpu_vhost_user` from the selected instance's
`cuttlefish_config.json`; reject missing, invalid, duplicate, or oversized
settings, and require `enable_gpu_vhost_user` to be the JSON Boolean `false`.
Record the selected mode and the Boolean as `selectedGpuMode` and
`gpuVhostUserEnabled` in `host.json`. If the live config fails either check,
skip regular ADB polling and retain only an incomplete capture. Revalidate
both settings in the staged config before publication.

**Reason.** The 2026-10-03 target captures
`target-20261004T060430-1393505`,
`target-20261004T061407-1394457`, and
`target-20261004T061552-1395715` selected `drm_virgl`, but Cuttlefish 1.57.0
auto-enabled its vhost-user GPU backend on the arm64 host and `run_cvd`
failed with `GPU mode drm_virgl not yet supported with vhost user gpu`.
Installing Mesa's development package and using `EGL_PLATFORM=surfaceless`
made Cuttlefish's host GLES check pass, but did not address that backend
failure. Applying the same explicit host setting to every profile keeps this
variable controlled in profile comparisons. A string such as `"false"` is
not equivalent to the Boolean `false`; accepting it could allow a malformed
or ambiguous configuration to pass the comparison gate.

The corrected capture `target-20261004T064521-1396609` selected
`drm_virgl`, recorded `enable_gpu_vhost_user=false`, and passed the host
GLES checks. The launcher records `process_restarter` starting the Android
crosvm child with the Virgl backend and observing its unexpected exit.
The unpacked Apport `ProcStatus` identifies the child as crosvm PID 1397163
with parent PID 1397147, matching the launcher record. Apport records a
SIGSEGV for that executable; the sanitized summary documents the process
correlation. This run no longer shows the earlier vhost-user GPU rejection,
but it does not establish that Virgl caused the crash or that `drm_virgl`
boots.

**Verification.** `Images/tools/.venv/bin/pytest
Images/tools/tests/test_reference_capture.py -q` passed 48 tests with three
Linux GNU `timeout` cases skipped on macOS. `sh -n
Images/tools/reference/capture.sh`, Ruff lint and format checks, and all six
checks in `scripts/ci/run-checks.sh` passed. Hostile review of the capture
implementation found no actionable findings. The corrected real capture
verifies the selected mode and disabled vhost-user setting, but remains
incomplete and does not verify that `drm_virgl` boots.

## IR-158: Retain sanitized crosvm crash evidence

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261004T064521-1396609/crosvm-crash-summary.txt`; [android-image.md](../02-design/android-image.md) §8.3; [environment-setup.md](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Keep the capture incomplete and add only a sanitized textual
summary of the host crosvm crash. Do not commit the raw Apport report or core
dump. Record the signal, fault address, faulting symbol and instruction,
available stack frames, executable and library build IDs, and the unresolved
caller frames. A crash summary is diagnostic context only; it cannot make a
capture complete or comparable.

**Reason.** The corrected target run verified `drm_virgl` with
vhost-user GPU disabled. The Apport report records SIGSEGV for crosvm. GDB
15.1 places the program counter at `unw_get_reg+68` in
`libgfxstream_backend.so` and reports `si_addr=0x10`. The unpacked Apport
`ProcStatus` lists `Name=crosvm`, `Pid=1397163`, and `PPid=1397147`. The
launcher records `process_restarter` PID 1397147 starting crosvm PID 1397163
with the Virgl backend at 21:45:18Z and reports the unexpected exit at
21:45:20Z, directly matching the report to the launched child. This narrows
the immediate failure but the stripped caller frames do not identify the
trigger. A raw core dump can contain guest RAM and private runtime state; the
summary preserves the useful evidence without publishing that memory. The
capture provides no Linux kernel, stable ADB-ready transport, or Android
boot-completion evidence.

**Verification.** The sanitized summary agrees with the Apport report, GDB
output, and launcher process record. Its PID and PPID match the launcher
record. It contains no raw core data or private host paths and does not
attribute the crash to Virgl. The seven newly added
capture directories contain 70 files; all JSON and JSONL files parse, no file
exceeds 64 MiB, and the privacy scan found no tested host paths, private-key
markers, or six- and eight-octet colon-form MAC/EUI-64 addresses. The raw
report and core are absent from the repository. All six checks in
`scripts/ci/run-checks.sh` passed after these documentation and evidence
updates. The initial hostile review found and prompted corrections to the ADB
wording, capture-cause attribution, and process correlation. Follow-up hostile
reviews confirmed the Apport PID/PPID match and found no further actionable
issues. Keep IR-158 in `Needs maintainer review` until the backtrace
interpretation and raw-core exclusion are reviewed.

## IR-159: Retain sanitized live Android boot-stall observations

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/swiftshader-20261004T081603-1401833/android-boot-stall-summary.txt`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Keep a sanitized summary of bounded ADB, process-list, and logcat
observations from the 2400-second SwiftShader capture. State that the boot
observer was disabled, distinguish the sampled observations from a complete
time-series, and keep the capture incomplete and non-comparable.

**Reason.** The capture reached Zygote preloading but expired before Android
reported boot completion. Its normalized host files do not include the
interactive ADB and logcat samples taken during the run. Retaining only the
bounded observations preserves the state needed to guide another diagnostic
run without copying raw guest memory or an unfiltered logcat dump. The sampled
state does not establish a boot root cause.

**Verification.** The summary was checked against `host.json`, `MISSING.txt`,
the normalized kernel and launcher logs, and the bounded ADB/logcat results.
All 10 files in the artifact directory were scanned: JSON and JSONL parse,
no file exceeds 64 MiB, and the scan found no tested host paths, private-key
markers, or MAC/EUI-64 patterns; no core dump or unfiltered logcat dump is
present. `pytest Images/tools/tests/test_reference_capture.py
Images/tools/tests/test_boot_observer.py -q` passed 155 tests with four
Linux-only skips. All six checks in `scripts/ci/run-checks.sh` passed, as did
`git diff --check`. The initial hostile review found three documentation
issues: it did not distinguish the OpenWrt crosvm sidecar reset from the
Android guest crosvm, it labeled a guest logcat timestamp UTC without
evidence, and it referred to verification results that were not yet recorded.
The summary now distinguishes the two crosvm processes, leaves the guest
logcat timezone unspecified, and records the verification results here.
Follow-up hostile review found no further actionable findings. Keep IR-159 in
`Needs maintainer review` until the evidence summary and its interpretation
are reviewed.

## IR-160: Back off timed-out Android property probes

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Keep ADB `connect` and `get-state` checks on their existing
15-second schedule. After the first consecutive timed-out Android property
query, defer the next property query for 30 seconds; after the second and
later consecutive timeouts, defer it for 60 seconds. A property command that
returns without timing out clears the backoff. Record the selected or
remaining delay in `getpropRetryInSeconds`; keep skipped queries explicit
with `getpropAttempted=false` and `getpropTimedOut=null`.

**Reason.** In the interim live SwiftShader capture snapshot through guest
uptime 1388.713 seconds, all 17 observed guest `SIGHUP` events for untracked
`(sh)` and `(printf)` processes aligned with observer shell-query poll times
within 0.85 seconds after anchoring guest uptime to the first shell-probe
poll. This strongly associates repeated remote shell timeouts with the
guest-side process entries, while timing alignment alone does not prove the
origin of every process. The former 15-second property retry schedule could
launch another remote shell after each timeout. Backoff lowers that repeated
guest-side activity without reducing the ADB transport-state sampling
cadence. The retry timer sets the earliest eligible property poll. While
ordinary polling continues and `get-state` reports `device`, the query runs
on the first scheduled poll at or after that delay, after that poll's
`connect` and `get-state` commands complete. Their durations and scheduler
delays add to the actual query time. Offline or unavailable transport states
and the reserved final logcat-probe window defer ordinary property retries.

**Verification.** The full `test_boot_observer.py` suite passed 108 tests with
one Linux-only parent-death test skipped on macOS. The new test drives three
consecutive property timeouts through the 30/60-second backoff, verifies
transport polls continue while property commands are deferred, and confirms
that a successful property command restores the regular schedule. The full
Image tools suite passed 492 tests with four platform-specific skips; the
focused observer suite passed 108 tests with one Linux-only skip. Ruff lint
and formatting, `git diff --check`, and all six checks in
`scripts/ci/run-checks.sh` passed. Hostile reviews found a missing transport
poll assertion, an interim-snapshot cutoff omission, and overbroad retry
latency wording; these were corrected. Final follow-up hostile review found
no further actionable findings. The active 3600-second capture started before
this change and therefore uses the old property-query cadence. The 1200-second
post-change capture recorded the configured 30/60-second delays and continued
transport checks; see IR-162. A longer post-change run is still needed to
compare later boot progress and guest shell events.

## IR-161: Preserve the full incomplete SwiftShader observer capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/swiftshader-20261004T093436-1428464/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Retain the normalized host-side files and a bounded, sanitized
summary for the 3600-second SwiftShader observer capture. Keep it marked
incomplete and non-comparable because Cuttlefish did not produce
`sys.boot_completed=1`, `VIRTUAL_DEVICE_BOOT_COMPLETED`, or the guest capture
command output. Record the observed `system_server` exits, zygote restarts,
timed-out ADB shell probes, guest untracked-process events, memory samples,
and cleanup state without assigning a boot root cause.

**Reason.** The long capture adds a later boot-progress window than the
previous 2400-second observation, including `system_server` activity and
subsequent process exits, while its ADB property probes still do not return
accepted boot state. Preserving the normalized evidence makes the next
bounded diagnostic run actionable. The captured timing correlations and
logcat counts are insufficient to establish why Android failed to complete
boot; the summary therefore distinguishes observations from causal claims.

**Verification.** The summary was checked against `host.json`, `MISSING.txt`,
the normalized kernel, launcher, and observer logs, and the bounded final
logcat result. The ten original capture files matched their Lima source
copies by SHA-256, with digests retained in the artifact's
`source-sha256.txt`; each recorded digest passes `shasum -a 256 -c`. The
source and local copies were compared on 2026-10-04. Normalization changed
zero files. Cleanup claims are limited to the observer's recorded private
ADB-server shutdown and `MISSING.txt`'s crosvm lookup at artifact-collection
time; the bundle has no complete fleet, process, or listener audit. After
adding the hash manifest and revised summary, all 12 artifact files
(2,591,381 bytes total; largest file 1,433,649 bytes) passed the 64 MiB size
limit and scans for the tested host paths, private-key markers, and
MAC/EUI-64 patterns. The four JSON/JSONL files parsed successfully. The
initial hostile review found chronology, cleanup-evidence, hash-auditability,
and premature review-status issues. The chronology and cleanup wording were
corrected, digests were retained, and review status is explicitly pending.
A follow-up review then found that the JSON/JSONL parsing claim included
non-JSON files; this wording was narrowed. Final hostile review found no
further actionable findings. `git diff --check` and all six checks in
`scripts/ci/run-checks.sh` passed after the evidence corrections. Keep IR-161 in
`Needs maintainer review` until the incomplete-capture evidence and its
interpretation are reviewed.

## IR-162: Verify property-query backoff on the Linux reference host

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/swiftshader-20261004T102250-1468492/`; `Images/tools/reference/boot_observer.py`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Run a bounded 1200-second SwiftShader capture with the updated
observer and retain its normalized host evidence and a sanitized summary.
Treat it as incomplete and non-comparable because the observer recorded no
successful observation of `sys.boot_completed=1`, the captured kernel and
launcher logs contain no `VIRTUAL_DEVICE_BOOT_COMPLETED` marker, and the
guest capture command list was not run. All eight property queries timed
out, so this does not establish whether the guest property ever reached 1.
Use it to verify live retry scheduling and transport polling, not to claim a
boot root cause or a reduction in guest shell activity.

**Reason.** Unit tests verified the retry state machine, but only a live
reference-host capture could show whether real ADB command timeouts recorded
the configured delay while transport checks continued. A bounded run yields
that check without treating the still-incomplete Android boot as a reference
profile.

**Verification.** `host.json` records a 1205-second `guest_swiftshader`
capture on Cuttlefish 1.57.0/build 16373615, with vhost-user GPU disabled.
The observer recorded 40 transport polls: 37 `device`, three
`commandFailed`; 39 `connect` commands returned 0 and one timed out. Eight
property queries all timed out with exit status -15. The first timeout
recorded `getpropRetryInSeconds=30`; each of the next seven recorded 60.
Twenty-eight scheduled polls deferred property queries while transport
checks continued. Property-query-attempt poll records were about 45 seconds apart after
the first timeout and about 75 seconds apart thereafter. These timestamps
are emitted after bounded commands return, so they do not establish
query-start intervals. The guest kernel recorded two untracked
`sh` SIGHUP events, which do not establish their source or a reduction in
guest shell activity. No successful observation of `sys.boot_completed=1` was recorded,
and the captured logs contain no boot-complete marker. Since all property queries
timed out, the guest property state at the deadline is unknown. The bounded
final Android logcat query also timed out, so its summary does not establish
the absence of a boot error.

The ten source files matched their Lima copies by SHA-256 on 2026-10-04;
`source-sha256.txt` records the digests and each passes `shasum -a 256 -c`.
Normalization changed zero files. The post-capture audit at
2026-10-04T01:24:52Z found an empty Cuttlefish fleet, no `crosvm`, `run_cvd`,
`process_restarter`, or `cvd_server` process, no listener on port 6520, and
at audit time, loopback port 5037 had an ADB listener at PID 2704; no stop command was issued for it. No pre-capture identity check was retained, so the audit does not establish continuity during the capture. The artifact has 13 files (1,246,632 bytes; largest 550,914 bytes);
all four JSON/JSONL files parse, and the size and tested privacy scans pass.
`test_boot_observer.py` passed 108 tests with one Linux-only parent-death
test skipped on macOS. `git diff --check` and all six checks in
`scripts/ci/run-checks.sh` passed. Hostile review prompted clarification of
the unobserved property state, poll-record timestamp semantics, audit-time
listener state, and exact artifact byte count. Final hostile review found no
further actionable findings. Keep IR-162 in `Needs maintainer review` until
the live verification and its limits are reviewed.

## IR-163: Record a long post-change SwiftShader observer capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/swiftshader-20261004T114734-1483038/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Retain the normalized 3600-second post-change SwiftShader capture
as incomplete and non-comparable. The capture did not record an accepted
`sys.boot_completed=1` value or `VIRTUAL_DEVICE_BOOT_COMPLETED`, and it did
not run the guest capture command list. Treat the eight getprop commands
that exited 0 as unparsed responses: none yielded accepted property fields,
so the guest's `sys.boot_completed` value is unknown. Record the `system_server`
exits, zygote SIGKILL/restart, and guest SIGHUP events without assigning a
root cause. Keep the 5037 ADB listener running.

**Reason.** Cuttlefish start event 5 and a private ADB server became
available about ten minutes after observer start, and 192 transport polls
reported `device`. However, the shared deadline expired while the Cuttlefish
create/start command was still running. The installed Cuttlefish 1.57.0
`cvd start --help` describes `boot_timeout_secs` as waiting for completed
boot before failing. Kernel logs show first-stage init, zygote startup,
servicemanager calls attributed to `system_server`, three untracked
`system_server` exits, and a zygote SIGKILL followed by restart. Those
observations do not explain why the boot-completion condition was not
reported. Compared with the pre-change capture, fewer guest SIGHUP events
were observed through uptime 800 seconds; the independent runs make this
consistent with the backoff but do not establish causation.

**Verification.** The ten captured source files match their Lima copies by
SHA-256; `source-sha256.txt` retains the digests and all entries pass
`shasum -a 256 -c`. The capture normalizer changed zero files. The artifact
contains 13 files totaling 2,467,557 bytes, with a largest file of 1,336,545
bytes; every file is below the 64 MiB limit. Three JSON documents and all
924 JSONL records parse with duplicate-key and non-standard-constant
rejection. Scans for the tested user and temporary host paths, private-key
markers, and MAC/EUI-48/EUI-64 patterns pass.

The observer recorded 195 transport polls (192 `device`, three
`commandFailed`), 48 property queries (40 timeouts with exit status -15 and
eight exit status 0 with no accepted parsed fields), and 147 polls without a
property query. The timed-out queries recorded the 30/60-second delays:
seven first timeouts in consecutive-timeout streaks recorded 30, and 33
later timeouts recorded 60. The shell-ready probe timed out. The bounded
events-buffer query returned 17,948 bytes with zero recognized process
events; the separate Android logcat query timed out with zero bytes.

Kernel logs record first-stage init at uptime 47.496 seconds, zygote startup
at 209.251 seconds, system_server callers from 1737.851 through 3345.618
seconds, untracked `system_server` exits at 1940.390, 2759.823, and
3186.678 seconds, and a zygote SIGKILL at 2767.776 followed by a start at
2775.947. They contain five untracked-process SIGHUP events, at uptimes
939.071, 2049.115, 2273.782, 2633.587, and 3278.964 seconds. Through
uptime 800 seconds, the pre-change run recorded five SIGHUP events, the
1200-second post-change run recorded one, and this run recorded zero. Do
not interpret these independent-run counts as causal proof.

A read-only audit at 2026-10-04T02:52:12Z found an empty Cuttlefish fleet,
no `crosvm`, `run_cvd`, `process_restarter`, or `cvd_server` processes, and
no port 6520 listener. Loopback port 5037 had an ADB listener at PID 2704;
no stop command was issued for it. The audit is point-in-time and has no
pre-capture PID observation. `MISSING.txt` separately records the crosvm
lookup at artifact-collection time. Keep IR-163 in `Needs maintainer review`
until the evidence and its interpretation are reviewed.

## IR-164: Record bounded property-response parsing status

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Add `getpropOutputBytes` and nullable `getpropOutputParsed` to
observer poll records. The byte count is limited by the existing 4 KiB
response cap. `getpropOutputParsed=true` means at least one expected response
field parsed, `false` means none parsed, and `null` means the parser did not
run or the query was not attempted. Continue to discard all raw property
output.

**Reason.** IR-163 recorded eight property commands that exited 0 but no
accepted property fields. The existing record could not distinguish a
zero-byte response from a non-empty response that did not match the expected
format. These bounded metadata fields clarify future captures without
retaining guest output; per-property fields still determine whether each
value was present and valid.

**Verification.** `test_boot_observer.py` passed 113 tests with one
Linux-only parent-death test skipped on macOS. The full Image tools suite
passed 497 tests with four platform-specific skips. Coverage distinguishes
parsed complete and partial timeout responses, empty and malformed
responses, and truncated output; it also verifies that response contents
are not persisted. Ruff lint and formatting, `git diff --check`, and all six
checks in `scripts/ci/run-checks.sh` passed. The hostile follow-up review
reported no actionable findings.

## IR-165: Record a long SwiftShader capture with bounded property-response diagnostics

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/swiftshader-20261004T133202-1522663/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Retain the normalized 3600-second SwiftShader run as incomplete
and non-comparable. The shared deadline expired while Cuttlefish create/start
was still running, no guest capture command list ran, and neither an accepted
`sys.boot_completed=1` property nor `VIRTUAL_DEVICE_BOOT_COMPLETED` was
recorded. Keep the property values unknown and retain only bounded response
metadata, not raw getprop output. Record the blocked `system_server` stack and
process events without assigning a root cause. Keep the pre-existing status
of the port 5037 ADB listener unresolved; do not stop it.

**Reason.** The observer recorded 197 ADB polls, of which 195 reported
`device`, and 54 property queries. Thirty-nine queries timed out and 15
exited 0, but all 54 responses were unparsed: 31 contained zero bytes, seven
contained 46 bytes, and 16 contained 90 bytes. The distinct sizes exercise
the IR-164 metadata and show why an exit status alone is insufficient to
infer that a property value was read. The raw responses were not retained.

The kernel log shows successful progress through U-Boot, first-stage init,
and zygote startup. Init records an untracked `system_server` exit with status
0 at uptime 1798.486. A watchdog-issued SysRq requested blocked-state and
memory dumps at 2465.850; zygote received SIGKILL at 2487.490 and restarted
at 2497.959. Init recorded another untracked `system_server` exit with status
0 at 2886.400. A later watchdog SysRq at 3245.973 produced a blocked-state
dump at 3247.400, showing `system_server` waiting in
`rwsem_down_write_slowpath` and `down_write_killable` before
`do_mprotect_pkey`. At the captured kernel revision,
[`do_mprotect_pkey`](https://android.googlesource.com/kernel/common/+/3ec022196c4e9d5c1434599cdda63f622dd6f586/mm/mprotect.c#744)
calls `mmap_write_lock_killable(current->mm)`, so the operation was waiting
for that address space's mmap write lock. The dump does not identify its
holder. A concurrent memory snapshot does not show low free memory at that
instant. An all-CPU NMI snapshot at 3248.822 records the same PID 4364 as the
current CPU 1 task with a user-space program counter, so this capture does
not show that the D-state persisted. Zygote received SIGKILL again at
3271.995; libprocessgroup removed PID 4364's cgroup at 3274.415, and
untracked `system_server` PID 5070 received SIGKILL during cleanup at
3277.543, before zygote restarted at 3277.772. These observations do not
explain the failure to complete boot. This capture reached Linux and Android
startup and does not reproduce a halt in U-Boot; it does not establish a
causal link between U-Boot and the later stall.

The Lima mount was read-only, so the pinned reference tools and manifest were
staged under a VM-local writable directory for the capture. The seven
reference-tool hashes and manifest hash matched the checkout; the temporary
staging directory was removed after capture. Their eight digests are retained
in `capture-source-sha256.txt`, and a fresh writable Lima staging copy
reproduced them. The capture used
Cuttlefish 1.57.0, build 16373615, Ubuntu 24.04.4 LTS/aarch64 with nested
virtualization, four guest CPUs, 4096 MiB memory, `guest_swiftshader`, and
vhost-user GPU disabled.

**Verification.** The artifact contains 14 regular files totaling 2,552,731
bytes; the largest is 1,471,808 bytes. All three JSON documents and all 926
JSONL records parse with duplicate-key and non-standard-constant rejection.
The 197 ADB polls contain 54 attempted and 143 polls without a getprop
attempt: 140 skipped the query during backoff, two had
`getStateResult=commandFailed`, and one ran the shell-ready probe. All
attempted responses are at most 4096 bytes and marked unparsed; polls without
a getprop attempt have null response metadata. The 39 timeout, 15
successful-exit, and 0/46/90-byte histogram counts match the retained
summary.

All ten captured-artifact digests pass `shasum -a 256 -c`; the eight
capture-source digests also match the source files in the checkout. The
capture normalizer changed zero files. Scans of every artifact file for the
tested host paths, PEM private-key markers, EUI-48 addresses, and
EUI-64-style IPv6 addresses passed. The observer stopped its private ADB
server; the point-in-time host audit found an empty Cuttlefish fleet, no
listed Cuttlefish processes, no private CVD HOME matching the capture prefix
under `/tmp`, and no port 6520 listener. Port 5037 had a loopback ADB
listener at PID 2704, which was left running; without a pre-capture process
inventory, its relationship to this run is unknown.
Keep IR-165 in `Needs maintainer review` until the evidence and its
interpretation are reviewed.

## IR-166: Capture SystemServer thread state after a blocked mprotect trace

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/reference/capture_cvd_start.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** When the optional observer sees a `system_server` D-state record
whose bounded kernel-log call trace contains `do_mprotect_pkey`, record its
guest uptime and wake the private ADB poller. On the next device-state result,
run one bounded `su 0` command over ADB to read every current SystemServer
thread's state, wait channel, and kernel stack. Read the proc entries in one
command, but document that they are sequential rather than atomic. Retain
only thread states, allowlisted wait-channel strings, and kernel function
symbols; discard PIDs, TIDs, thread names, addresses, and raw command output.
Use a 10-second command timeout and 64 KiB output limit. Do not retry a
launched command, even if it times out. Increase the ordinary-poll reserve
from 25.5 to 38 seconds to cover the possible fourth command and its process
group cleanup before the final logcat probe. A required status, wait-channel,
or stack read failure emits an invalid-snapshot marker and rejects the whole
response while the task still exists; a task that exits during the sequential
read may be skipped.
For kernel-log continuity, pass the original source's device, inode, size, and
modification time with each copied snapshot. Reset and record a gap on inode
replacement, truncation, same-size modification, or a prefix/overlap mismatch.
Treat growth on a stable inode as append-only to avoid repeatedly scanning the
whole log. The upstream `KernelLogServer` uses `O_APPEND`; verify the pinned
host package when its version changes. Search every byte read in a bounded
scan before trimming the retained excerpt. Check the stop event after
consuming an ADB wake so shutdown cannot turn its wake signal into a new poll.

**Reason.** IR-165 recorded `system_server` blocked in the
`do_mprotect_pkey` mmap-lock path, but the all-CPU snapshot 1.4 seconds later
showed the same process in user space. This does not establish a persistent
lockup or identify the lock owner. Triggering on the specific trace should
collect relevant thread state promptly if it recurs, while keeping the
diagnostic opt-in, bounded, and free of process identifiers and raw stacks.
The sequential read may still miss a transient lock owner, so its absence is
not evidence that no owner existed.

**Verification.** Initial focused and full image-tool runs passed before the
hostile review. The review then found four issues: partial proc reads could be
accepted, new kernel-log bytes beyond the retained excerpt could be skipped,
log replacement continuity lacked coverage, and shutdown could race with an
ADB wake. These findings are addressed with fail-closed proc framing,
pre-trim scanning, source markers and bounded boundary checks, replacement
and truncate/regrowth tests, and a stop-aware wake consumer. A second hostile
review identified quadratic I/O from hashing the full prefix on ordinary
growth and noted that a disappearing task can be omitted by the sequential
read. The hash was removed in favor of source metadata and boundary checks;
the stable-inode append-only assumption is called out for maintainer review.
The design now documents that tasks which exit during collection may be
omitted. Final verification: the full image-tool suite passed 531 tests with
four platform-only skips; after the final skipped-byte accounting change, both
catch-up regression cases passed. Ruff, format, repository CI, and
`git diff --check` passed. The final hostile review found no remaining
actionable issues.

## IR-167: Record a SwiftShader boot failure before the SystemServer thread probe

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/swiftshader-20261004T174319-1563170/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Retain the 447-second SwiftShader run as incomplete and
non-comparable. Cuttlefish 1.57.0 reported `VIRTUAL_DEVICE_BOOT_FAILED`,
`run_cvd returned 10`, and exit status 255. Keep the captured U-Boot, Linux,
init, launcher, and observer records as diagnostics; do not claim that the
known logical-partition geometry warning caused the failure. The kernel log
ends at guest uptime 317.057 seconds during init service startup. No
`system_server`, `do_mprotect_pkey` blocked trace, kernel panic, or OOM
marker was recorded. The observer matched the `Start event (5) received.`
marker emitted by `socket_vsock_proxy`; all three ADB `get-state` probes
returned `commandFailed`, so it captured no Android properties or
SystemServer thread state. The launcher log records the proxy failing to
start a TCP server on port 6520 after ten attempts, then aborting with
`SIGABRT`. The critical-process monitor stopped the remaining monitored
processes, after which `run_cvd` exited and Cuttlefish reported
`VIRTUAL_DEVICE_BOOT_FAILED`. The bind error is logged as `0`, so the reason
for the bind failure is not explicit. The post-run audit identified an ADB
fork-server listener on the same port, with a process start time of 17:41:29
JST, before the proxy's ten attempts from 17:42:41 through 17:42:52. The
launcher also records ADB connections to `127.0.0.1:6520` during those
attempts. This timing makes a port collision likely, but does not prove the
listener's provenance or the exact bind error. This is the observed CVD
failure sequence, not an established Android boot root cause. The run does
not exercise IR-166's thread-state probe and is not evidence that the earlier
transient blocked trace recurred or was fixed.

After CVD cleanup, the ADB fork-server listener on port 6520 remained. The
process kind and command are recorded, but the pre-run port state was not
recorded, so its provenance and parent are unknown. After verifying that the
Cuttlefish fleet and listed Cuttlefish processes were empty, issue
`adb -P 6520 kill-server`; a follow-up audit found no listener on 6520.
Leave the separate port 5037 listener running. The observer's own private
Unix-socket ADB server reported successful cleanup.

**Reason.** Preserve useful boot-progress evidence without overstating what
it proves. The launcher logs provide a direct failure chain for the CVD
startup, and the concurrently present listener makes a port collision
probable, but neither the exact bind errno nor an Android-side cause is
identified. Event 5 is the marker emitted by `socket_vsock_proxy`, not
Android boot completion. The failed ADB state probes and missing
`system_server` marker leave the guest's later state unknown. Keep the run
out of profile comparisons until a complete capture exists.

**Verification.** The capture was produced from source commit `ef70045`.
`LIMA-SHA256SUMS` stores the reference-VM digests for all ten captured
artifact files, and `shasum -a 256 -c` passed for each file after transfer.
A second `compare_boot.py normalize` pass changed zero files. The
`post-run-verification.json` records the CVD process and port audit,
including the 6520 listener command and start time, its unverified
provenance, the likely collision assessment, and the scoped kill-server
action. The audit found an empty Cuttlefish fleet, no listed Cuttlefish
processes, the temporary CVD HOME removed, and no port 6520 listener after
cleanup; the separate port 5037 listener remained. The diagnostic
interpretation and record are pending hostile review.

## IR-168: Record target drm_virgl prerequisite failure

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `.gitattributes`; `Images/reference/16373615/incomplete/target-20261004T180433-1573318/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Retain the `target` attempt as incomplete and non-comparable;
`host.json` records an 8-second capture duration. It used source commit
`ef70045`, build 16373615, Cuttlefish
1.57.0 on Ubuntu 24.04.4 arm64 with nested virtualization, requested
`drm_virgl`, and disabled vhost-user GPU. `assemble_cvd.log` records
`PopulateEglAndGlesAvailability: Failed to initialize display`, followed by
Cuttlefish's warning that the `drm_virgl` prerequisites were not detected.
The host inventory found no virglrenderer executable or library visible
to `ldconfig`, and no virglrenderer pkg-config module. The tested Lima VM has
no `/dev/dri`, which [environment setup](../05-development/environment-setup.md)
§3.3 documents as expected; its absence alone does not show VirGL is
unavailable. A follow-up read-only check before changing the VM confirmed
`libgles2-mesa-dev` was installed, but `libvirglrenderer1` was not installed;
no virglrenderer library was visible to `ldconfig`, and the capture invocation
did not set `EGL_PLATFORM=surfaceless`. These observations establish the
package and linker-cache state, not that no compatible library existed
elsewhere on the host. Section 3.3 prescribes the Mesa development package
and this EGL setting to enable
off-screen EGL and the host GLES check, while noting that this does not
guarantee the guest or backend will start. This attempt preceded the
documented EGL setting, had no installed `libvirglrenderer1` package, and had
no virglrenderer library visible to `ldconfig`; it does not establish whether
the VM can run `target` after those host prerequisites are completed.

The launcher identifies the monitored process role as `process_restarter`,
configured to launch Android `crosvm run` with `backend=virglrenderer`. It
logs `Process exited with unexpected si_code: 3`, then exits with code 1;
the process monitor logs that unexpected exit and stops the other monitored
processes. Normalization redacts the `crosvm` executable path. The launcher records
`si_code: 3` and the `process_restarter` exit code 1, but do not identify the
child's signal. The sanitized Apport/GDB summary records SIGSEGV and the fault
site for this first attempt (IR-170), while the original trigger remains
unknown. The launcher then reports `run_cvd returned 10` and
`VIRTUAL_DEVICE_BOOT_FAILED`. `kernel.log` is empty,
the observer did not see start event 5, and no ADB polls ran; this attempt
therefore supplies no guest boot evidence. Do not attribute the failure to a
specific GPU prerequisite or Android cause.

Do not switch this capture to the documented `guest_swiftshader` fallback
without the required pinned `bootconfig_args.cpp` revision and
source-derived graphics-properties file. Neither was available in the
checkout, so the fallback was not invoked. The post-run audit found an empty
Cuttlefish fleet, no listed Cuttlefish processes or temporary CVD HOME, and
no port 6520 listener. The separate port 5037 listener remained running and
was not stopped.

**Reason.** Preserve the failed host-side graphics setup as evidence while
keeping profile selection and source-derived fallback properties
reproducible. The EGL display error, missing `libvirglrenderer1` package,
absence of a virglrenderer library from `ldconfig`, and missing
`EGL_PLATFORM=surfaceless` setting are consistent with incomplete host
graphics setup. They do not prove which prerequisite caused the EGL check to
fail or identify the original trigger for the crosvm SIGSEGV recorded under
IR-170. An incomplete target attempt cannot serve as the reference profile or
establish guest behavior.

**Verification.** `host.json` confirms the requested and selected mode was
`drm_virgl`, with vhost-user GPU disabled. `LIMA-SHA256SUMS` contains hashes
for all ten captured artifacts and the post-run audit; all entries verified
after transfer. A second `compare_boot.py normalize` pass changed zero
files. Strict JSON parsing succeeded, and the tested host-path, PEM-header,
EUI-48, and EUI-64 scans found no matches across the record. The Cuttlefish
fleet/process/temporary-home audit passed; port 6520 was absent after
cleanup, while port 5037 was left running. Hostile review caught that the
process role was identifiable from the launcher arguments; the wording was
corrected, and the final hostile review found no further actionable issues.
The raw `cvd-create-console.log` is preserved byte-for-byte, and
`.gitattributes` exempts captured logs' source trailing whitespace from Git's
whitespace check; `git diff --check` passes without changing the verified
capture bytes.

## IR-169: Record the 3600-second default observer capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/default-20261004T192056-1574666/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Keep the 3600-second `default` capture incomplete and
non-comparable. It used source commit `ef70045`, build 16373615, Cuttlefish
1.57.0 on Ubuntu 24.04.4 arm64 with nested virtualization. `host.json`
records selected `guest_swiftshader` and vhost-user GPU disabled. The
create/start deadline expired at 3600 seconds; `host.json` records a
3604-second duration at `capture_finished_at`, before the script's explicit
ADB disconnect and Cuttlefish group removal. `MISSING.txt` records the
deadline, and
`cvd-create-console.log` says Cuttlefish received a termination signal
during cleanup. It contains two logical-partition geometry warnings at
startup; their relationship to the later guest state is unknown.

The observer detected `socket_vsock_proxy`'s `Start event (5)` marker at
2026-10-04T09:33:09.044Z for the TCP 6520 to vsock 3:5555 proxy. Later
launcher lines record failures connecting to vsock 3:5555, so this marker is
not Android boot readiness. The private ADB server was ready 51 ms after the
marker. Of 185 ADB polls, 183 returned `device` and two returned
`commandFailed`. There were 44 property queries: 36 timed out with exit
status -15 and eight exited 0, but none produced an accepted field. Output
sizes were 0 bytes 35 times, 46 bytes once, and 90 bytes eight times.
`sys.boot_completed` and `sys.system_server.start_count` remain unknown. The
one-shot shell marker timed out. No SystemServer thread snapshot was
attempted.

The kernel log reaches guest uptime 3309.094 seconds and contains no
`VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`,
`do_mprotect_pkey`, kernel-panic, or OOM marker. It records untracked
`system_server` exits with status 0 at uptimes 1761.684 and 2842.050 seconds
and 36 `crash_dump64` mentions; later service lookups do not establish the
cause of either exit. The observer collected 721 crosvm memory samples,
720 with valid VmRSS and a peak of 4,234,488 KiB. Its bounded logcat summary captured
17,754 bytes with two SystemServer mentions and no ANR, fatal-exception, or
fatal-signal lines. The separate events query captured 23,067 bytes and
recognized no process events. These observations do not establish why boot
completion remained unobserved.

**Reason.** Preserve a long-run timeline and its ADB/property behavior
without treating transport readiness or SystemServer service lookups as
Android boot completion. The property values are unknown, no completion
marker was captured, and the bounded logcat/event summaries identify no
cause. Keep the record out of profile comparisons until a complete default
capture exists.

**Verification.** `LIMA-SHA256SUMS` contains hashes for all ten captured
artifacts and the post-run audit; all eleven entries verified after
transfer. A second `compare_boot.py normalize` pass changed zero files.
Strict JSON/JSONL parsing passed, and scans across all 12 files found no
tested host paths, PEM headers, EUI-48 addresses, or EUI-64 IPv6 candidates.
The post-run audit found an empty Cuttlefish fleet, no checked Cuttlefish
processes or temporary CVD HOME, no listener on port 6520, and the existing
port 5037 ADB listener still running. The focused normalizer tests passed
(17 passed, 23 deselected). The initial hostile review identified four
evidence-wording corrections. A follow-up review confirmed those corrections
and found two further wording/status issues, which were corrected. Final
hostile review found no remaining actionable findings.

## IR-170: Diagnose the first Virgl crosvm crash and record the retry

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261004T180433-1573318/`; `Images/reference/16373615/incomplete/target-20261004T192939-1614388/`; [environment setup](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Keep both `drm_virgl` attempts incomplete and non-comparable. Add
only a sanitized crash summary for the first attempt at
`target-20261004T180433-1573318/crosvm-crash-summary.txt`. The Apport report
identifies crosvm PID 1573779, whose parent and launch time match the
`process_restarter` entry in `launcher.log`. It reports SIGSEGV in
`libgfxstream_backend.so` at `unw_get_reg+68`, with `SEGV_MAPERR` and fault
address `0x10`; the recorded instruction loads from `[x8, #16]` while `x8` is
zero. The backtrace's crosvm caller frames are unavailable. The summary
records both executable and loaded-library Build IDs. The same-named debug
library available in the host package has a different Build ID, so it was not
used to infer the missing callers. The original trigger remains unknown; this
stack does not establish that Virgl caused it.

At the time of the original capture, the raw Apport report and embedded core
were retained on the Lima reference host because the core may contain guest
memory. A later read-only search did not locate this PID's report or core in
the locations checked; see IR-224. The temporary GDB extraction was deleted,
and no raw core or report was copied into the repository. After
installing `libvirglrenderer1` and setting `EGL_PLATFORM=surfaceless`, the
retry made `libEGL.so`, `libGLESv2.so`, and `libvirglrenderer.so.1` visible to
`ldconfig`, and Cuttlefish passed its host graphics-prerequisite check.
`launcher.log` records crosvm configured with the virglrenderer backend;
runtime loading of the library is not confirmed. `host.json` records a
9-second capture duration. The retry failed before guest kernel output,
start event 5, or ADB polling. `process_restarter` logged
`si_code: 3` (`CLD_DUMPED`) and exited 1, but the record has no child signal
number. Apport did not write a report for this retry: `/var/log/apport.log`
records that it skipped crosvm because the first attempt's report still
existed and was unseen. The retry record therefore has no child signal number
or crash report. Do not infer that the retry failed with the same signal or
at the same stack location as the first attempt.

**Reason.** Preserve the confirmed first-attempt crash location while
separating it from the unknown original trigger and from the second attempt's
less-specific termination evidence. The host-side setup instructions now
include the dependencies and EGL platform that made Cuttlefish's prerequisite
check pass on the tested Ubuntu 24.04.4 arm64 Lima VM; they do not claim that
this setup is sufficient to boot the guest.

**Verification.** The first record contains ten captured artifacts, the
post-run audit, the sanitized summary, and its manifest; all 12 manifest
entries verify on the Mac and Lima. Its strict JSON/JSONL parsing passed,
scans of all 13 files found no tested user or temporary host paths, PEM
headers, EUI-48 addresses, EUI-64-style IPv6 addresses, or oversized files,
and two normalization passes changed zero files. The retry record contains
ten captured artifacts and the post-run audit; all 11 manifest entries verify
on the Mac and Lima. Strict JSON/JSONL parsing passed, scans of all 12 files
found no tested user or temporary host paths, PEM headers, EUI-48 addresses,
EUI-64-style IPv6 addresses, or oversized files, and two normalization
passes changed zero files. Both post-run audits found an empty Cuttlefish
fleet, no checked Cuttlefish processes or temporary CVD HOME, and no listener
on port 6520. The first audit records a port 5037 listener as present; the
retry audit identifies the listener as PID 2704. Neither audit issued a stop
command for it. Final hostile review found no remaining actionable findings.

## IR-171: Diagnose crosvm panic output

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/capture.sh`; `Images/tools/tests/test_reference_capture.py`; `Experiments/cuttlefish-boot-diagnosis/{README.md,build-crosvm-built-virgl-launcher.sh,crosvm-built-virgl-launcher.c,crosvm-libgcc-preload.sh,patches/enable-pinned-crosvm-virgl.patch}`; [android-image.md](../02-design/android-image.md) §8.2; [environment setup](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064; [R-06](risks.md#r-06-stock-cuttlefish-image-on-the-vz-topology); `Images/reference/16373615/incomplete/target-20261004T211540-1617589/`; `target-20261004T212141-1619115/`; `target-20261004T212512-1620453/`; `target-20261004T232534-1622675/`; `target-20261004T233833-1630294/`; `target-20261004T235047-1637967/` |

**Choice.** Recover crosvm's panic message before requiring matching debug
symbols. Cuttlefish tag
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d` pins crosvm source commit
`fd4df63707aee57092a28db63bc1ff8945c76058` and gfxstream commit
`6e68776cefbe1f1a662bb7321aa98e5348e8c062`. The `Launcher Build ID` in
Cuttlefish logs is the Cuttlefish VCS revision; it is not the crosvm ELF Build
ID. The sanitized Apport summary identifies executable package
`cuttlefish-base 1.57.0` and crosvm Build ID
`d724bf54f045b0ec7dbe14049b0fed9a16e52a23`; the loaded
`libgfxstream_backend.so` Build ID is
`6b8f3105442da5c66988881a1fa76e812b13c3e8`. `readelf` shows crosvm needs both
`libgfxstream_backend.so` and `libgcc_s.so.1`; gfxstream exports
`unw_get_reg` and `_Unwind_GetIP`.

The pinned crosvm panic hook at
[`src/sys/linux/panic_hook.rs`](https://chromium.googlesource.com/crosvm/crosvm/+/fd4df63707aee57092a28db63bc1ff8945c76058/src/sys/linux/panic_hook.rs)
sets `RUST_BACKTRACE=1`, redirects stderr to a pipe, invokes Rust's default
panic hook, then reads and logs the captured output. In the first diagnostic
capture `target-20261004T211540-1617589`, GDB placed the SIGSEGV at
`unw_get_reg+68` in `libgfxstream_backend.so`; `x8` was zero at
`ldr x8, [x8, #16]`. The frames above it included gfxstream's `_Unwind_GetIP`
and libgcc's `_Unwind_Backtrace`. Its sanitized `crosvm-crash-summary.txt`
records relative offsets for the stripped crosvm caller frames. Those offsets
belong to that capture and cannot be transferred to PID 1573779. The separate
IR-170 summary for PID 1573779 marks its stripped crosvm caller frames
unavailable and records no offsets. The executable Build ID is
`d724bf54f045b0ec7dbe14049b0fed9a16e52a23`.

The first diagnostic wrapper was passed to `cvd create` only. A second
instrumented attempt showed no wrapper marker, and its crosvm environment
contained no `LD_PRELOAD`. The pinned `cvd start` also accepts
`--crosvm_binary` and applies its own default, so `capture.sh` now passes the
opt-in override to both `cvd create` and `cvd start`. The corrected capture
`target-20261004T212512-1620453` records the wrapper marker and an
`LD_PRELOAD` entry in Apport's environment. The panic hook then logged:

```text
thread 'v_gpu' panicked at .../src/virtio/gpu/mod.rs:1687:14:
Failed to create virtio gpu worker thread: invalid rutabaga build parameters
```

The crosvm process ended with SIGABRT after logging the panic. The selected
GPU mode was `drm_virgl`, vhost-user GPU was disabled, and the crosvm command
line selected `backend=virglrenderer`. `kernel.log` is empty and there is no
Android boot evidence.

The panic matches the pinned build configuration. The
[Cuttlefish crosvm Bazel spec](https://github.com/google/android-cuttlefish/blob/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/build_external/crosvm/crosvm.MODULE.bazel)
sets `default_features = False` and enables `gfxstream` and `gpu`, but omits
`virgl_renderer`. In the pinned
[crosvm Cargo features](https://github.com/google/crosvm/blob/fd4df63707aee57092a28db63bc1ff8945c76058/Cargo.toml#L303-L315),
`virgl_renderer` enables `devices/virgl_renderer`. The pinned
[Rutabaga 0.1.80 source](https://docs.rs/crate/rutabaga_gfx/0.1.80/source/src/rutabaga_core.rs#L1492-L1496)
returns `InvalidRutabagaBuild` when the selected default component is
VirglRenderer but the build lacks that feature. This matches the panic text.
Installing `libvirglrenderer1` and satisfying Cuttlefish's EGL/GLES check do
not enable the missing crosvm build feature.

The later suggestion that the original SIGSEGV may have interrupted crosvm's
panic hook while it was capturing a backtrace is plausible but unverified. The
first capture has no recovered panic text; the later preload capture recovered
the distinct missing-`virgl_renderer` panic above. Treat that panic as the
demonstrated cause of that later attempt only, and do not retroactively assign
it to PID 1573779. At the time of the 2026-10-04 retry, IR-170 records that
Apport skipped a new report because the first report still existed and had
not been seen. Exact executable
path attribution for PID 1573779 remains unresolved; the installed package's
Build ID does not, by itself, prove which path that historical process used.

**Diagnostic rebuild.** A diagnostic-only build of
`//build_external/crosvm:crosvm_bin_opt` was completed in the pinned Debian
13 container from the source revisions above with the
`virgl_renderer` feature patch. The Cuttlefish container recipe runs
unversioned `apt upgrade`, omits `libvirglrenderer-dev` from its declared
dependencies, and generated Abseil repositories needed temporary
`layering_check` cache adjustments before the build passed. These
environment changes are not repository source and make the result
non-reproducible as a canonical host package. The ARM64 crosvm and gfxstream
outputs have Build IDs `1f6c03321061aa58e1d1ec0d0a1ff54f` and
`257833fa4c8e65fc5294f3fa2ea311c4`, with SHA-256 values
`48a9553740a947a2f6f1679692a73d022ea364d43b7e4652d7c9ab6a0ac5aaf7` and
`c8e1f380e2ebfbe5814c57ba1f81d94659be0d6771edac421493cac02575f503`.

**Diagnostic captures.** The three later target attempts used this modified
crosvm and remain incomplete and non-comparable:

| Record | EGL setup | Observation |
|---|---|---|
| `target-20261004T232534-1622675` | `EGL_PLATFORM` was not set. | Cuttlefish logged that EGL/GLES prerequisites were not detected. Although the Virgl backend was configured and the kernel reached init, this does not establish a valid Virgl guest path. |
| `target-20261004T233833-1630294` | Set explicitly in the invocation. | Host EGL/GLES checks passed and the guest reached Android init/APEX activity, but the 600-second deadline expired without ADB readiness, a confirmed zygote service start, `system_server`, or boot completion. |
| `target-20261004T235047-1637967` | Set explicitly in the invocation. | The static launcher ran the patched crosvm and the guest reached Android init. The kernel log imports and parses zygote init configuration files, but does not confirm that zygote started. Its final retained init records show `odsign` starting at guest uptime 200.727 seconds, receiving PID 594 at 200.832 seconds, and the `start odsign` action succeeding after 116 ms at 200.836 seconds. No later kernel-log line establishes the service's eventual outcome. No `system_server`, boot-complete marker, or ADB state sample was observed before the 600-second deadline. |

These captures were produced by the older Lima-local checkout at
`e7cd1c0`, so their `host.json` files use schema version 1 and have no
`eglPlatform` field, even though the latter two invocations explicitly set
the environment. The current `capture.sh` sets `EGL_PLATFORM=surfaceless`
automatically for `target`/`drm_virgl`, clears inherited `EGL_PLATFORM` for
all other profile and GPU-mode combinations, records the effective value in
schema version 2, and has profile-configuration regression coverage. The
third capture's observer made 121 crosvm memory polls, all with no candidate
and unavailable identity, so it recorded no crosvm memory measurements; it
also recorded no ADB state events. Its post-run audit found an empty
Cuttlefish fleet, no crosvm, `process_restarter`, or `run_cvd` process, no
listener on port 6520, and no private capture HOME. The pre-existing ADB
server PID 2704 remained running and was not stopped. The nine, nine, and ten
normalized files in the three records match their Lima-side `LIMA-SHA256SUMS`
manifests; a second normalization pass changed zero files. The tested
host-path, PEM-header, and EUI-48 scans found no matches or oversized files.

**Launcher hardening.** The first static launcher used by the third capture
had Build ID `01d7480ecd9f6ccf0e4613caa3f2ba85831cbcea` and SHA-256
`28a84deba33a97bbbf9002c1b31e4c83a8bd3c97283233b21c37b0cab16e9494`.
The current static AArch64 launcher has Build ID
`faf3eaf415ce2d1fc6c90f5090a9e82ba8abccab` and SHA-256
`d09e4a87ac8d174d9925bcedd0ff2d77f138f63f00c6eff9bbc1c7865e33c819`.
The build script compares adjacent binaries with the hashes pinned in the
experiment README and embeds those exact values. At runtime the launcher
checks the staged files through open descriptors, labels the emitted hashes
as staged-file hashes, clears inherited loader variables, and executes
crosvm from its open file descriptor. It rejects symlinked files and writable
directory ancestors that another user could change. The dynamic loader later
opens gfxstream by pathname, so the hash log does not independently prove the
mapped bytes if a same-UID process mutates the directory; same-UID processes
remain trusted. The build script requires a fresh output path and refuses to
overwrite any existing file or follow an output symlink.

**Reason.** The original SIGSEGV is consistent with a secondary failure
during panic-hook backtrace collection: the retained stack includes
libgcc's `_Unwind_Backtrace` and gfxstream's exported `_Unwind_GetIP` and
`unw_get_reg`. Preloading the system `libgcc_s.so.1` in a subsequent
run let the hook finish and log the triggering panic: the stock pinned
crosvm build cannot instantiate the requested Virgl component. This
identifies the immediate Virgl failure without matching debug symbols.

The precise unwinder failure remains unproven. The dynamic symbol table and
dependency list establish that the symbols are exported and both libraries
are dependencies; they do not establish which implementation handled each
runtime call. The null-base load at offset `0x10` does not by itself identify
a vtable slot or prove the proposed `validReg` interpretation. If exact
symbolization becomes necessary, compare runtime mappings and section
addresses as well as section bytes; a different Build ID alone neither
proves nor disproves code-byte identity. The feature-enabled diagnostic
crosvm passes the recovered panic and produces guest kernel logs, but the
observed Android startup still does not reach a confirmed `system_server`.
This does not validate the target GPU profile or establish the remaining
Android boot cause.

**Verification.** Raw Apport reports and core payloads for the
2026-10-04 diagnostic captures were kept in Lima's private storage and were
not copied into the repository; only normalized logs and sanitized summaries
are tracked. A later search did not locate PID 1573779's report or core in the
checked locations; see IR-224. On the running Lima VM, `dpkg -L cuttlefish-base` lists
`/usr/lib/cuttlefish-common/bin/crosvm` and
`/usr/lib/cuttlefish-common/bin/libgfxstream_backend.so`. `readelf` confirms
the installed files have Build IDs `d724bf54f045b0ec7dbe14049b0fed9a16e52a23`
and `6b8f3105442da5c66988881a1fa76e812b13c3e8`; the library's dynamic symbol
table exports `unw_get_reg`, `_Unwind_GetIP`, and the related unwind symbols,
and crosvm needs both `libgfxstream_backend.so` and `libgcc_s.so.1`. This
confirms the installed package contents, not the `ExecutablePath` of the
earlier crashed process. A read-only scan found six readable `.crash` reports
under `/var/crash` and no crosvm report; the readable `/var/log/apport.log`
contains no crosvm entries. The exact crash executable path therefore remains
unavailable from the current Lima evidence.
The crosvm override is applied to both CVD commands. The current launcher
build passed static-link and AArch64 ELF checks. An ARM64 container test ran
crosvm `--help` with injected `LD_*` variables and `GLIBC_TUNABLES`, verified
the staged-file hashes, and confirmed rejection of modified crosvm and
gfxstream files, a symlinked crosvm, a group/world-writable ancestor, and a
different-user-owned writable ancestor. It also exercised closed standard
file descriptors without hanging. The build script rejects mismatched pinned
inputs and all existing output paths, including direct, symlink, and hardlink
aliases, without changing the inputs. The full reference-capture test module
passed 50 tests; three Linux-only GNU `timeout` cases were skipped. The
focused profile-configuration tests passed three cases. Ruff lint and format,
shell syntax checks, and `git diff --check` passed. Final hostile subagent
review found no actionable issues. The target capture and all its artifacts
remain diagnostic-only.

**Open provenance check for maintainer review.** The sanitized Apport summary
for IR-170's 2026-10-04 crash does not retain the exact `ExecutablePath`
field. The user-readable Lima `.crash` inventory and Apport log checked on
2026-10-05 contained no crosvm report or entry, so the path for PID 1573779
remains unconfirmed.
IR-158's separate report for PID 1397163 names
`/usr/lib/cuttlefish-common/bin/crosvm`; that evidence applies only to that
older process. The `Launcher Build ID` is the Cuttlefish VCS revision, not a
crosvm ELF identity. If the original report for PID 1573779 becomes
available, record only its `ExecutablePath` field and keep the raw report
and core private.

## IR-172: Diagnose guest EGL selection

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261004T161206Z-1646389/`; [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §3.3 |

**Choice.** Keep the 1200-second `target` capture incomplete and
non-comparable. Retain its normalized host artifacts and a bounded manual
guest EGL summary. Do not change the canonical GPU profile or guest graphics
properties based on this run. The capture tools came from checkout
`74de6953ede33f0bbad6e0a330609f4ee6603f1d`; the selected configuration
records `gpu_mode=drm_virgl`, `enable_gpu_vhost_user=false`, and
`EGL_PLATFORM=surfaceless`.

The run used the diagnostic crosvm launcher with Build ID
`faf3eaf415ce2d1fc6c90f5090a9e82ba8abccab` and SHA-256
`d09e4a87ac8d174d9925bcedd0ff2d77f138f63f00c6eff9bbc1c7865e33c819`.
Its crosvm had Build ID `1f6c03321061aa58e1d1ec0d0a1ff54f` and SHA-256
`48a9553740a947a2f6f1679692a73d022ea364d43b7e4652d7c9ab6a0ac5aaf7`;
gfxstream had Build ID `257833fa4c8e65fc5294f3fa2ea311c4` and SHA-256
`c8e1f380e2ebfbe5814c57ba1f81d94659be0d6771edac421493cac02575f503`.
These are diagnostic build outputs, not a reproducible or canonical host
package. These identities were recorded from `readelf` and SHA-256
inspection of the temporary Lima build outputs. The ELF files and raw
`readelf` output are not retained in this record, so the identities cannot be
independently recalculated from its committed artifacts. The Cuttlefish
`Launcher Build ID` printed in logs is the source revision and is distinct
from the crosvm and gfxstream ELF Build IDs above. The pinned crosvm panic
and build-feature mismatch are documented in IR-171.

The guest kernel initialized `virtio_gpu` with `+virgl`; the Cuttlefish
configuration selected the virglrenderer backend. Android first-stage init
ran and zygote was requested at approximately guest uptime 184.5 seconds.
The guest reported `ro.hardware.egl=mesa`. Pinned Cuttlefish revision
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d` intentionally sets
`androidboot.hardware.egl=mesa` for `GpuMode::DrmVirgl` in
`CrosvmManager::ConfigureGraphics()` in `crosvm_manager.cpp`; the saved
`internal-bootconfig.txt` contains the matching graphics properties. The
source file SHA-256 is
`ec273ead56c32bc4c294d2072c6b379400620f9ac98dbba1242acd4442572f43`.
The inspected `/vendor/lib64/egl` directory contained only emulator EGL/GLES
libraries, and `/system/lib64/egl` was absent. `libEGL` reported that it
could not load drivers for `mesa` and could not find an OpenGL ES
implementation.

Manual ADB logcat samples showed SurfaceFlinger repeatedly aborting through
EGL initialization and `SkiaGLRenderEngine::create`, followed by zygote
restarts, from approximately guest uptime 434 to 849 seconds. The saved
`kernel.log` records a later SurfaceFlinger SIGABRT at uptime 983.431
seconds, the `exited 4 times before boot completed` event at 983.714
seconds, and a restart at 988.033 seconds. Those later kernel records do not
retain the EGL error from the manual logcat samples. The sampled
`sys.boot_completed` query returned an empty value; no
`sys.boot_completed=1` value was observed or accepted. No successful
`system_server` startup or `VIRTUAL_DEVICE_BOOT_COMPLETED` marker was
established.

**Reason.** The run gets past the previously recovered crosvm
`virgl_renderer` feature panic and reaches Android userspace. The direct
loader error shows that the guest could not load a usable Mesa EGL/GLES
implementation for the selected `drm_virgl` mode. The property is expected
from the pinned Cuttlefish source; this does not establish why build 16373615
cannot satisfy that mode, rule out a Mesa implementation outside the
inspected directories, prove that Virgl produced frames, or explain every
remaining boot issue. The
[AOSP GLES/EGL driver-loading guidance](https://source.android.com/docs/core/graphics/implement-opengl-es)
states that the system image supplies drivers selected using
`ro.hardware.egl` or `ro.board.platform`, preferably under
`/vendor/lib64/egl` on 64-bit devices. Confirm the property and driver
packaging against image build sources before changing the image. The
documented `guest_swiftshader` target fallback was subsequently attempted;
IR-173 records that it also remained incomplete and did not establish guest
rendering.

**Verification.** `host.json` and `cuttlefish_config.json` parse and record
the requested target mode, disabled vhost-user GPU, and `surfaceless` host
EGL setup. Before the later ADB-serial redaction, all nine copied capture
artifacts matched their Lima-side hashes. The original
`LIMA-SHA256SUMS` remains unchanged; after redaction the other eight
artifacts still match it, the original launcher input hash is recorded in
`post-capture-normalization.json`, and all 14 entries in
`POST-NORMALIZATION-SHA256SUMS` verify; see IR-174. All 12 capture-tool,
manifest, and launcher-source hashes matched the recorded checkout. A second
`compare_boot.py normalize` pass changed zero files. The tested host-path,
private-key, MAC-address, and ADB-serial scans found no matches. The post-run
audit found an empty Cuttlefish fleet, no crosvm, `run_cvd`,
`process_restarter`, or `cvd_server`, no private CVD HOME or capture staging
directory, and no port 6520 listener. It found the shared ADB server PID
2704 listening on port 5037; the final device inventory was empty. The
focused reference-capture suite passed 50 tests with three Linux-only GNU
`timeout` tests skipped on macOS before the capture. No scripted guest
capture or successful boot marker was produced. Keep this record
diagnostic-only and #064 open.

## IR-173: SwiftShader target fallback

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261004T165409Z-1660660/`; [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §3.3; [android image](../02-design/android-image.md) §8.2 |

**Choice.** Use the documented `guest_swiftshader` target fallback after the
`drm_virgl` attempt failed to reach Android boot completion. Keep the 1200
second run incomplete and non-comparable, and preserve the canonical target
profile unchanged. This capture used the stock Cuttlefish host runtime, not
the feature-enabled diagnostic crosvm. It used Cuttlefish 1.57.0, build
16373615, Ubuntu 24.04.4 arm64 with nested virtualization, selected
`guest_swiftshader`, and disabled vhost-user GPU. The capture tools came from
checkout `74de6953ede33f0bbad6e0a330609f4ee6603f1d`; their original hashes
are in `capture-source-sha256.txt`. The exact Cuttlefish source revision for
the separately recorded `drm_virgl` properties is
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`.

The capture ran for 1203 seconds and `cvd start` exceeded its 1200-second
deadline. The guest kernel records first-stage init at uptime 50.532 seconds,
`virtio_gpu` initialization at 54.189 seconds, zygote starting at 170.018
seconds, and SurfaceFlinger starting at 304.618 seconds. It records
`VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED` at 418.578 and 454.875 seconds.
From 622.463 through 1070.062 seconds, init and `servicemanager` repeatedly
report that `aidl/activity` cannot be found after audioserver requests. The
captured kernel and launcher logs do not establish `system_server` startup
or its state, and these messages do not establish the cause of the boot
delay. The launcher also contains Cuttlefish-managed ADB connector attempts,
success messages, and transport errors; they are not evidence that an ADB
shell query succeeded. Because `cvd start` did not return before the
deadline, the regular ADB polling and guest-capture stages did not run.
`sys.boot_completed` was not queried, and no
`VIRTUAL_DEVICE_BOOT_COMPLETED` marker was captured.

The selected SwiftShader guest bootconfig contains
`androidboot.hardware.egl=angle` and `androidboot.opengles.version=196609`.
The separately saved `drm_virgl` properties contain `mesa` and `196608`.
That difference is expected: the source-derived file records the pinned
Virgl configuration, while the running guest uses the selected SwiftShader
mode. The file is provenance and was not injected as the guest's active
SwiftShader graphics configuration.

**Reason.** The fallback validates that the Cuttlefish configuration selected
`guest_swiftshader` with vhost-user GPU disabled and records how far Android
startup progressed. It still did not satisfy the #064 boot-completion or
profile-capture criteria, and it does not prove guest rendering. The repeated
`aidl/activity` messages were also present in the later observer-enabled
capture in IR-175. That capture recorded the ADB transport and command
timeouts but still did not diagnose these messages or their cause. Do not
change the guest image properties or claim G2 or G3 from this run.

**Verification.** `host.json`, `cuttlefish_config.json`,
`composite-disk-specs.json`, and the post-run JSON records parse. The selected
GPU mode is `guest_swiftshader` and `enable_gpu_vhost_user` is false. All 11
copied capture artifacts matched their Lima-side SHA-256 values before the
post-capture serial-normalization repair; the 12 capture-source hashes were
verified against checkout `74de6953ede33f0bbad6e0a330609f4ee6603f1d` before
this local normalization fix. A second normalizer pass changed zero files.
The tested host-path, private-key, MAC-address, and loopback ADB-serial scans
found no matches in the retained record. The post-run audit found an empty
Cuttlefish fleet, no crosvm, `run_cvd`, `process_restarter`, or `cvd_server`,
no private CVD HOME or capture staging path, and no port 6520 listener. It
found the shared ADB server PID 2704 listening on 5037; `adb devices` listed
no devices. IR-174 records the one post-capture file repair and its hashes.
Keep this record incomplete and #064 open.

## IR-174: Redact Cuttlefish loopback ADB serials

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/normalize.yaml`; `Images/tools/tests/test_compare_boot.py`; `Images/reference/16373615/incomplete/target-20261004T161206Z-1646389/`; `Images/reference/16373615/incomplete/target-20261004T165409Z-1660660/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Extend normalization to replace Cuttlefish ADB endpoints with
`<ADB_SERIAL>` in host log files. Match the Cuttlefish `--addresses` field,
ADB connector messages, and ADB device-not-found messages in
`crosvm-command-line.txt`, `assemble_cvd.log`, `launcher.log`,
`launch-cvd-console.log`, and `cvd-create-console.log`. Leave unrelated
loopback endpoints in those logs and loopback addresses in guest network
captures unchanged. Apply the rule to retained incomplete captures when an
earlier normalization pass predates the rule.

**Reason.** The SwiftShader fallback's `launcher.log` contained the selected
ADB serial in Cuttlefish `adb_connector` lines. An adversarial review then
found the same missed host-log form in the earlier Virgl diagnostic record.
The existing normalization covered serial-number fields but not these
contexts, violating #064's requirement to omit device serials. The scoped
rule redacts Cuttlefish ADB endpoints while preserving unrelated loopback
endpoints and guest network evidence.

**Verification.** A regression test checks command-line, connection, and
device-not-found forms, and confirms that unrelated loopback endpoints in a
host log and a guest properties file are preserved. Before repair, all nine
Virgl and 11 SwiftShader capture artifact hashes matched their Lima-side
manifests. Normalizing each retained `launcher.log` changed one file; a
second pass changed zero files. Each record has a
`post-capture-normalization.json` with its original and normalized launcher
hashes and the normalization-rule hash, plus a
`POST-NORMALIZATION-SHA256SUMS` covering the sanitized record. The original
`LIMA-SHA256SUMS` manifests remain unchanged. The SwiftShader record's
normalization was reproduced from its original Lima log; the Virgl input
matched its Lima manifest before the same repair. Post-repair scans found no
selected ADB serial in either retained record.

## IR-175: Observe the SwiftShader target fallback

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261004T173358Z-1674431/`; [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §3.3 |

**Choice.** Repeat the documented `guest_swiftshader` target fallback with
the optional boot observer enabled for a 1200-second deadline. Keep the
capture incomplete and non-comparable and leave the canonical GPU profile
unchanged. The host was Cuttlefish 1.57.0, build 16373615, Ubuntu 24.04.4
arm64 with nested virtualization. `host.json` records
`targetGpuMode=guest_swiftshader`, `selectedGpuMode=guest_swiftshader`, and
`gpuVhostUserEnabled=false`. Cuttlefish revision
`9bb9c72329cedcb436bb75afc05c24d73fbcdf5d` is recorded as the provenance
for the separate `drm_virgl` graphics-properties file; the active
SwiftShader bootconfig uses its own properties.

The guest kernel records first-stage init at uptime 48.191 seconds,
`virtio_gpu` initialization at 50.657 seconds, init starting zygote at
178.792 seconds, SurfaceFlinger at 366.012 seconds, and boot animation at
591.812 seconds. `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED` appears at
551.522 and 589.420 seconds. The kernel log contains 162
`aidl/activity` interface-not-found requests from uptime 823.435 through
1071.385 seconds. It contains no `system_server`,
`VIRTUAL_DEVICE_BOOT_COMPLETED`, or `VIRTUAL_DEVICE_BOOT_FAILED` line.
These logs do not establish the state of `system_server` or the cause of
the missing interface.

The observer recorded 288 events: 241 crosvm memory events (240 with a valid
VmRSS value and one with `candidateCount=0` and `identity=unavailable`), 39
ADB polls, one Cuttlefish start event 5 marker, one final logcat-summary
event, and six lifecycle/path events. The peak valid VmRSS was 4,229,472
KiB. Of the ADB polls, 36 returned device state and three returned
`commandFailed`. The first device-state poll's standalone
shell-readiness command timed out with exit status -15 without matching its
marker. Eight property-query attempts also timed out with exit status -15;
none produced parsed `sys.boot_completed` or
`sys.system_server.start_count` values. The final logcat attempt timed out
before capturing any bytes. The observer's private ADB server stopped with
`cleanupComplete=true`. The run therefore shows that a reported ADB
`device` state did not establish that an Android shell command could finish.
It does not identify why the command timed out.

`cvd start` exceeded the 1200-second deadline and the capture ran for 1204
seconds. No guest capture was produced. `MISSING.txt` records that no crosvm
process matched the private Cuttlefish HOME at artifact-collection time;
this does not establish whether it ran earlier. Keep #064 open and do not
claim boot completion or guest rendering.

**Verification.** All 12 copied capture artifacts match
`LIMA-SHA256SUMS`. Seven reference-tool and manifest hashes match checkout
`74de6953ede33f0bbad6e0a330609f4ee6603f1d`; the eighth matches the scoped
normalizer copied to Lima for this run. A second normalization pass changed
zero files. The tested host-path, private-key, EUI-48, EUI-64, and numeric
ADB-context scans found no matches. `host.json`,
`cuttlefish_config.json`, `composite-disk-specs.json`, and
`post-run-verification.json` parse. The post-run audit found an empty
Cuttlefish fleet, no crosvm, `run_cvd`, `process_restarter`, or `cvd_server`,
no private CVD HOME or capture staging directory, and no listener on port
6520. It found shared ADB PID 2704 listening on port 5037 and no ADB device
rows. The record remains incomplete and diagnostic-only.

## IR-176: Complete the in-progress SwiftShader target observation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261004T182603Z-1688586/`; [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §3.3 |

**Choice.** Let the already-running 2400-second observer-enabled
`guest_swiftshader` target capture finish after the prior review found that
additional time at the same configuration had low expected diagnostic yield.
Keep its output incomplete and non-comparable. Do not repeat the configuration
without a material host or guest code/configuration change.

The run used Cuttlefish 1.57.0, build 16373615, Ubuntu 24.04.4 LTS/aarch64
with nested virtualization, `guest_swiftshader`, and vhost-user GPU disabled.
`host.json` records a 2404-second duration. The capture source's eight
reference-tool and manifest hashes match checkout
`1b7dfb28c9a5e7c15400006a8514104bd25efaa7`; the remote checkout did not
retain Git metadata, so this is a file-hash match, not a remote `HEAD`
assertion. The normalized Cuttlefish config does not retain the crosvm
executable path, and this run did not save the selected crosvm's Build ID or
hash. Attribute no result here to a particular crosvm binary.

The kernel log records Linux at guest uptime 0, first-stage init at 61.569
seconds, and `virtio_gpu` initialization from 61.954 through 63.564 seconds.
Init logged a request to start zygote at 212.081 seconds; later start requests
at 578.507 and 1972.653 seconds reported that zygote was already running. Two
`VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED` markers appear at 571.626 and
609.641 seconds. No `VIRTUAL_DEVICE_BOOT_COMPLETED` or
`VIRTUAL_DEVICE_BOOT_FAILED` marker appears. The log contains 751
servicemanager interface-not-found requests for `aidl/activity` from guest
uptime 856.826 through 2048.362 seconds. It also contains eight
`system_server` mentions from 1678.093 through 1906.001 seconds, including
one exit-related line. These messages neither prove SystemServer readiness
nor establish that the missing AIDL interface caused a delay.

The observer recorded 591 events, including 481 crosvm memory samples, 478
with valid VmRSS; peak VmRSS/RssShmem was 4,233,752/4,205,908 KiB. It
recorded 102 ADB polls: 99 reported `device` and three had no device-state
value. Of 23 property queries, 21 timed out with exit status -15 (20 captured
zero bytes and one captured 46 bytes); two exited with status 0 after
capturing 90 bytes each. None yielded a parsed property, and raw property
output was not retained. The one-shot shell-readiness probe timed out with
exit status -15 without matching its marker. The final Android logcat query
timed out with zero captured bytes. The observer stopped its private ADB
server with
`cleanupComplete=true`. The property values remain unknown; ADB `device`
state is not evidence that guest shell commands succeeded.

The read-only post-run audit found an empty Cuttlefish fleet, no crosvm,
`run_cvd`, `process_restarter`, or `cvd_server` process, no private CVD HOME
or capture staging directory, no listener on port 6520, and no ADB device
rows. The shared ADB server PID 2704 remained running on port 5037. The Lima
artifact manifest verifies all 12 capture files. A second normalization pass
changed zero files; scans for tested host paths, private-key markers,
EUI-48/EUI-64 addresses, and numeric ADB endpoint contexts found no matches.
The record remains incomplete and diagnostic-only.

**Reason.** This capture had already started before the adversarial review
compared it with earlier long SwiftShader runs. Completing it preserves the
authorized experiment without spending additional time on a new run. It
extends the observed `aidl/activity` requests and SystemServer mentions but
does not resolve their relationship or recover a usable boot property.
Repeating the same configuration would not address the missing runtime
identity or the guest-side AIDL question.

**Verification.** All 12 files in `LIMA-SHA256SUMS` verify locally; the
eight source-file digests match the stated checkout. JSON and JSONL parsing
passed, the local normalization re-run changed zero files, and the tested
privacy and file-size scans passed. The post-run audit JSON records the
read-only ADB inventory and confirms that shared ADB PID 2704 was left
running.

## IR-177: Inventory AIDL lazy-service init declarations in build 16373615

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [init inventory](../../Images/reference/16373615/aidl-init-inventory.json); `Images/work/16373615/download/fetch.json` (local provenance); `Images/reference/16373615/incomplete/target-20261004T182603Z-1688586/kernel.log`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Inspect the already-downloaded guest image before considering any
further VM run. Its ZIP SHA-256,
`051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18`,
matches the artifact entry in `fetch.json`. That file records the branch as
caller-asserted, not as independently verified source provenance.

The repository's read-only liblp parser found nine non-empty logical
partitions in `super.img`: `odm_a`, `odm_dlkm_a`, `product_a`, `system_a`,
`system_b`, `system_dlkm_a`, `system_ext_a`, `vendor_a`, and `vendor_dlkm_a`.
The init `.rc` files in those partitions and in all 93 bundled APEX payloads
were inspected: 114 partition `.rc` files and 66 APEX `.rc` files. The boot-image
manifest records an empty `boot.img` ramdisk, a 2,992,407-byte `init_boot`
ramdisk, and one 18,816,072-byte PLATFORM fragment in `vendor_boot`. The
repository image extractor combined the latter two; its LZ4-decoded CPIO
contains eight more init `.rc` files. Across all these sources, 188 init
`.rc` files were searched. The 93 APEX payloads are distributed across
`system_a` (38), `system_ext_a` (7), and `vendor_a` (48); 92 use ext4 and
`com.android.virt.apex` uses EROFS. No file declares
`interface aidl activity` or contains `aidl/activity`. The checked-in
[`aidl-init-inventory.json`](../../Images/reference/16373615/aidl-init-inventory.json)
records every scanned `.rc` path and content SHA-256, every APEX payload
name, filesystem format and digest, source artifact hashes, tool versions,
scope, and match count for reproduction.

The [AOSP dynamic AIDL documentation](https://source.android.com/docs/core/architecture/aidl/dynamic-aidl)
shows `interface aidl <name>` in an init service stanza so servicemanager can
find a lazy AIDL service. The dynamic lifecycle also uses init's `disabled`
and `oneshot` options and lazy registration by the service process. The
captured log states that if `activity` is not configured as a lazy service,
it may be stuck starting or still starting (`kernel.log` lines 3603–3605).
The inventory establishes that the inspected partitions, bundled APEX
payloads, and boot ramdisks do not declare `activity` as an init-managed lazy
service. `userdata.img` contents and runtime-added or activated APEX state
were not inspected. The inventory does not establish that the Binder
service's component is missing, explain why it was not registered, or prove
whether SystemServer was ready. The build's source revision was not
established by `fetch.json`, and static image contents do not reveal runtime
service state.

**Reason.** This read-only inventory answers the planned question about
whether the inspected build artifacts declare `aidl/activity` as a lazy init
service without spending another long interval on the unchanged SwiftShader
configuration. In a future eligible capture, start bounded guest logcat
early enough to cover the first requests. As soon as shell commands succeed,
collect `service check activity`, `service list`, `pidof system_server`, and
boot properties. If shell readiness arrives after the first requests, those
snapshots cannot establish the earlier service state. Keep any such run
diagnostic-only and do not infer causality from the init lookup failure by
itself.

**Verification.** The ZIP digest matched `fetch.json`. The project parser
successfully read the sparse `super.img`; `fsck.erofs` extracted all nine
non-empty logical partitions; the extracted `super.img` digest also matches
the image manifest. The repository `apkrun_image extract` command validated
the boot-image artifact hashes and produced the combined ramdisk. The 92 ext4
APEX payloads were extracted with `debugfs`, and the EROFS payload was
extracted with `fsck.erofs`; all 93 extracted payload directories contained
files. The 188 `.rc` file paths and content digests and the per-payload
names, formats, and digests are in the checked-in inventory. Its scan reports
zero matches for both declaration forms.
`fsck.erofs` was unpacked under Lima `/tmp` without installation; its package
digest matched Ubuntu package metadata. No guest or host ADB commands were
issued during this inventory. The shared ADB server PID 2704 was not touched.

## IR-178: Capture bounded Android service readiness in the boot observer

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Extend the observer's existing one-shot shell probe to run
`service check activity`, search `service list` for the `activity` entry, and
check `pidof system_server`. Emit only the fixed classifications
`found`/`notFound`/`unknown` and `present`/`notPresent`/`unknown`; never retain
the service-list output or process ID. Parse only complete, ordered,
allowlisted lines. Accept `service list` results only when its header, row
numbering, service-name field, non-empty bracketed descriptor, and declared
row count are consistent. An empty or malformed listing is `unknown`. If the
bounded command times out after emitting complete fields, retain that valid
prefix and discard any incomplete final line.

**Reason.** IR-177 calls for a runtime snapshot as soon as shell commands
succeed. Reusing the existing private-socket, ten-second shell probe adds no
ADB client or deadline reservation. The classifications distinguish service
lookup, registration-list, and SystemServer process observations while
keeping guest output out of the host record. The result is diagnostic only:
an absent service lookup does not establish why the service was unavailable,
and a one-shot that times out before emitting fields leaves their state
unknown.

**Verification.** The focused observer selection passed 40 tests. The complete
`Images/tools/tests` suite passed 551 tests with four platform-specific skips
(Linux parent-death signals and GNU `timeout`). `scripts/ci/run-checks.sh`,
Ruff lint and format checks, and `git diff --check` passed. The final
adversarial review found no actionable issues. No live guest or ADB command
was run for this tooling change.

## IR-179: Track the crosvm launcher and fexecve executable separately

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/capture.sh`; `Images/tools/reference/capture_cvd_start.py`; `Images/tools/reference/boot_observer.py`; image-tool tests; [android-image.md](../02-design/android-image.md) §8.3; [environment-setup.md](../05-development/environment-setup.md); [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Track the command requested by `process_restarter` and the
resulting process executable as separate identities. Preserve the supplied
command basename, even when its path is a symlink, when resolving the
restarter's request under the validated private Cuttlefish instance. By
default the process executable is the staged command's target. A diagnostic
wrapper that calls `fexecve` can provide its actual executable through
`APKRUN_CROSVM_OBSERVER_EXECUTABLE`. The observer accepts only known command
or executable paths for the child's `argv[0]`, then verifies
`/proc/<pid>/exe` with `samefile` against the expected executable.

**Reason.** The retained target run's restarter requested the staged command
basename `crosvm-built-virgl-launcher`, while the observer expected `crosvm`;
all 241 memory records therefore had `candidateCount=0` and
`identity=unavailable`. Reviewing the launcher implementation also showed
that it sets `argv[0]` to the adjacent `crosvm` and calls `fexecve` on that
binary. Passing only the wrapper path would still fail the observer's
`argv[0]` and `/proc/<pid>/exe` checks. The run did not separately preserve
the child executable path, so its runtime basename remains unverified.
Separate path inputs let future diagnostic captures identify both processes
without weakening private-instance or executable identity checks. ADB
polling uses a separate path. A later hostile review also found that resolving
a symlink override before reading its basename could reject the command name
that Cuttlefish stages. The observer now preserves the supplied basename and
resolves the executable target separately; a dedicated symlink fixture
covers this case.

**Verification.** The full `Images/tools/tests` suite passed 557 tests with
four Linux-only skips on macOS. The parent-death test and all three GNU
`timeout` cases passed separately on Lima. The focused observer suite passed
166 tests with its Linux-only parent-death case skipped on macOS; focused
capture tests passed 25 cases. `scripts/ci/run-checks.sh`, Ruff lint and
format, shell syntax, JSON parsing, and `git diff --check` passed. Adversarial
reviews found and drove fixes for the launcher/executable split, symlinked
command basename, and a Linux test's stale attribute reference; the final
review found no remaining actionable issue. The retained target capture used
source `fe08df8`, before these path corrections, so it does not validate the
corrected observer path at runtime.

## IR-180: Preserve the late-start feature-enabled Virgl target capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261005T061754-1724643/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Keep the 1200-second feature-enabled `drm_virgl` run under
`incomplete/`, marked diagnostic-only and non-comparable. Retain its kernel,
launcher, observer, host, and Cuttlefish logs with `post-run-verification.json`
and a ten-file Lima-side hash manifest. Do not treat start event 5, process
launch messages, or display setup as Android boot completion or rendered
frames.

**Reason.** The kernel log establishes Linux startup, virtio-gpu
initialization, and init requests that start zygote and SurfaceFlinger. It
does not contain a `system_server`, `aidl/activity`, or
`VIRTUAL_DEVICE_BOOT_COMPLETED` marker, and no boot-property query ran.
Cuttlefish start event 5 arrived about 18 minutes 45 seconds after observer
startup. The observer then made no regular ADB polls; its final ADB connect
timed out, `get-state` was not attempted, and the activity-service probe did
not run. This does not establish whether the guest had previously reached
ADB's `device` state or identify why Cuttlefish exceeded the deadline.

All 241 crosvm memory samples lacked a process identity. A read-only process
sample during the run showed the restarter requesting basename
`crosvm-built-virgl-launcher`, while the observer expected `crosvm`. The
capture did not separately record the child process executable. Inspection
of the diagnostic launcher source showed that it sets `argv[0]` to the
adjacent `crosvm` binary before `fexecve`; IR-179 now lets the observer check
the staged command and resulting executable separately. That fix was not in
this run's `fe08df8` source snapshot, so runtime attribution remains
unverified. The post-run audit found an empty CVD fleet, no checked
Cuttlefish processes, no private CVD HOME or capture staging directory, and
no listener on port 6520. It found the existing loopback ADB server PID 2704
on port 5037; no ADB command was issued to that shared server.

**Verification.** All ten artifact hashes computed from the retained Lima
copy matched the local capture. Eight tracked source hashes match revision
`fe08df8`, and the four generated bytecode hashes match the capture-source
manifest. JSON and JSONL parse, a second normalization pass changed zero
files, and the tested privacy scans found no matches or oversized files. The
capture remains incomplete and does not validate G2 or G3.

## IR-181: Preserve the short SwiftShader pre-kernel capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/swiftshader-20261005T055130-1716760/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Retain the 600-second `guest_swiftshader` profile run under
`incomplete/` as diagnostic-only and non-comparable. Its crosvm memory
observations are useful, but they do not establish a guest boot or the reason
the Cuttlefish start deadline expired.

**Reason.** The capture used Cuttlefish 1.57.0 and source snapshot `fe08df8`.
The observer discovered the private instance and recorded 119 identified
crosvm samples over the run. `VmRSS` increased from 25,884 KiB to 3,073,168
KiB. The observer did not see Cuttlefish start event 5; its private ADB
poller did not start. The retained `kernel.log` has no Linux version marker,
and `MISSING.txt` records that guest capture and a crosvm command-line
snapshot were unavailable at artifact collection. This does not establish
that the guest never ran or that crosvm crashed, ran out of memory, or caused
the timeout.

**Verification.** All eleven artifact hashes computed on Lima matched the
local files. All eight tracked source hashes match `fe08df8`. The observer
JSONL parses, and the tested host-path, private-key, ADB-endpoint, and MAC
address scans found no matches. Keep this run out of reference comparisons.

## IR-182: Match explicitly configured external crosvm launchers

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; `Images/reference/16373615/incomplete/target-20261005T082217-1740702/`; [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §3.3 |

**Choice.** Accept a `process_restarter` command only when its absolute path
matches the validated Cuttlefish-staged command, the explicitly configured
crosvm command path, or that command's resolved path. The requested file must
exist. Continue checking the child's instance arguments and serial endpoint,
then verify `/proc/<pid>/exe` with `samefile` against the separately
configured post-`fexecve` executable.

**Reason.** A point-in-time, read-only process listing during a live
feature-enabled Virgl run showed that Cuttlefish preserved the external
`crosvm-built-virgl-launcher` path in `process_restarter` rather than copying
that file into the instance's `artifacts/host_tools/bin` directory. That
listing was not retained in the normalized artifacts. The separately saved
observer sample records the matched process PID and RSS only; it cannot
independently verify the requested command path. The observer previously
required the derived staged path, so it reported no crosvm candidates even
while the crosvm child was running. The explicit command path is already
supplied by the capture configuration; a bare basename or arbitrary
executable path remains rejected. A regression test models an external
launcher with no runtime-staged copy. Applying the updated process checks
directly to the live CVD process found exactly one child and read its RSS.
The long-running capture had loaded the older observer before this fix, so
its unavailable RSS records do not validate the new observer.

**Verification.** The focused observer suite passed 167 tests with its
Linux-only parent-death case skipped on macOS. The external-launcher
regression also passed on Lima, and the live-process check matched one
crosvm child. The separate record
`Images/reference/16373615/incomplete/target-20261005T082217-1740702/observer-fix-live-sample.jsonl`
preserves a later live sample from the patched observer: it matched PID
1741301 and read VmRSS while the long capture was still running. The main
capture had already imported the old observer, so its 481 unavailable samples
remain uncorrected and are not presented as validation of this fix. Ruff lint
and format checks passed.

The first full image-tool run, while the Lima capture was active, reported
557 passes and four skips plus one fixture failure: the fake-Linux
`test_reference_capture` preflight correctly saw the real concurrent crosvm
process and exited before the test's expected product-image hash failure.
After the capture cleaned up, a fresh full run passed **558 tests with four
skips**. `scripts/ci/run-checks.sh` also passed all checks. All 14 entries in
the new Lima-side artifact manifest verify locally; the eight tracked capture
source hashes match `e5854d6`, the supplemental observer source hash matches
`7a2f7ff`, a second normalization pass changed zero files, and the privacy
scans found no matches. The earlier hostile review of the observer fix found
no actionable issue. Keep #064 open until the end-to-end capture and the
task's remaining acceptance criteria are verified.

## IR-183: Separate Cuttlefish transport retries from Android ADB readiness

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261005T082217-1740702/`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Treat Cuttlefish's `adb_connector` and WebRTC retry messages as
transport observations only. Do not treat an `adb connected` helper message
as an Android ADB `device` state. Keep the capture incomplete and
non-comparable; the available messages do not identify why the control
connections failed.

**Reason.** During the 2400-second target capture, the observer did not see
Cuttlefish start event 5 and made no ADB polls. Separately, `launcher.log`
records, across retries, 160 `adb_connector` connection attempts, 160
`adb connected` messages, 159 `device not found` warnings, and 159
disconnects. Those entries interleave; the final attempt and `adb connected`
message occur at 23:22:03Z and 23:22:08Z, with no later warning or disconnect
before `run_cvd` logs cancellation at 23:22:13Z. The log also records 2285
WebRTC `Failed to connect:` messages from `vsock_connection.cpp`: 819 end in
`OK`, while 1466 report `UNAVAILABLE` with `Connection reset by peer`.
Separately, 2285 WebRTC `shared_fd.cpp` messages say `cannot connect to
3:6900`. The normalized serial is redacted. These messages do not show an
Android ADB `device` state, establish that the guest ADB service was ready,
or explain the Cuttlefish start timeout. They also do not establish a causal
link between the ADB and WebRTC failures or the final kernel-log state.

**Verification.** The counts were parsed from the normalized launcher log;
the observer event counts and guest milestones were parsed from the retained
JSONL and kernel log. No ADB device inventory was queried. The post-run audit
found no port 6520 listener and left the shared ADB server on port 5037
untouched. Preserve this as an observation about one diagnostic run, not a
root-cause finding.

## IR-184: Record Cuttlefish host binary identities

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/elf_identity.py`; `Images/tools/reference/capture.sh`; `Images/tools/tests/test_elf_identity.py`; `Images/tools/tests/test_reference_capture.py`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Add schema-version-3 `hostToolIdentities` to `host.json`. Record SHA-256 and GNU ELF Build ID for the configured crosvm command, the separately configured expected process executable, and the adjacent `libgfxstream_backend.so` candidate. Store no absolute paths. Preserve a SHA-256 when the file is readable but its ELF Build ID is absent; report a bounded status when identity collection is unavailable or the input is not a valid ELF. If any SHA-256 cannot be collected, mark the capture incomplete. Do not present the gfxstream candidate as proof of the library mapped by the loader.

**Reason.** The supplied diagnosis correctly separates the Cuttlefish VCS revision printed as `Launcher Build ID` from the ELF Build IDs of crosvm and gfxstream. `host.json` previously recorded the Cuttlefish package version and selected profile, but not those binary identities; IR-176 explicitly notes that the crosvm identity was not captured. On 2026-10-05, a read-only Lima check found that the configured `$CVD_HOST_DIR/bin/crosvm` and `$CVD_HOST_DIR/bin/libgfxstream_backend.so` symlink to the installed Cuttlefish package files. Their ELF Build IDs match `d724bf54f045b0ec7dbe14049b0fed9a16e52a23` and `6b8f3105442da5c66988881a1fa76e812b13c3e8`; SHA-256 values were `976c85081250f4a332d0fca6573d62f8aa5e71c6924d8d49f6de44624f24891a` and `f7d5665978d4a3f872789348934e13a1cab5441821359e18562b14e804199250`. `readelf` again found the gfxstream unwind exports and the crosvm dependencies described in IR-171. The current `/var/crash` inventory has no crosvm report, and the readable Apport log has no crosvm entry; this does not establish the executable path for IR-170's later PID 1573779. IR-158 separately documents the path for the earlier PID 1397163. The data model therefore records configured inputs and avoids a historical-runtime claim. The Build IDs, hashes, symbol exports, dependencies, and current Apport inventory above are unarchived one-time observations from the read-only Lima check; they are not preserved as raw command output or evidence of the earlier process. Repeat the current binary check with `python3 Images/tools/reference/elf_identity.py --crosvm-command "$CVD_HOST_DIR/bin/crosvm" --crosvm-executable "$CVD_HOST_DIR/bin/crosvm" --gfxstream-backend "$CVD_HOST_DIR/bin/libgfxstream_backend.so"`, then compare its identities with `readelf -n`, `readelf --dyn-syms -W`, `readelf -d`, and `sha256sum` on those two files.

The configured command and expected executable are separate because a diagnostic launcher can `fexecve` another binary. The adjacent gfxstream path is only a candidate: Cuttlefish or the dynamic loader may select another library. `elf_identity.py` uses bounded ELF note parsing and streaming SHA-256; it does not add a host-tool dependency and emits no paths or raw file data.

**Verification.** The focused identity suite passed 13 tests, including ELF32/ELF64, little- and big-endian notes, missing and malformed Build IDs, short non-ELF files, mutation during inspection, and unavailable/non-regular paths. The full image-tool suite passed 572 tests with four platform-specific skips. `scripts/ci/run-checks.sh` passed all six checks, and the final adversarial review found no remaining actionable issues. The helper run directly on the Lima host reproduced the crosvm and gfxstream Build IDs and SHA-256 values above. The configured `$CVD_HOST_DIR` files resolve to the installed package files, confirming current configured-file identity but not, by itself, the executable used by a historical process. IR-158 separately records that Apport named `/usr/lib/cuttlefish-common/bin/crosvm` for the older crosvm PID 1397163. Do not transfer that path claim to IR-170's later PID 1573779. No new Cuttlefish boot was attempted; #064 remains open.

## IR-188: Pin the available RiftVM source for #018

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #018 |
| Affected files | [graphics.md](../02-design/graphics.md) §2; [riftvm-analysis.md](../02-design/riftvm-analysis.md); [M02 graphics](issues/M02-graphics.md) #018; [M12 legal compliance](issues/M12-v1-release.md) #093; [build-system.md](../05-development/build-system.md) §3.1, §6.1, §6.5; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.1, §4, §5, §6; `scripts/tools/check-lock.swift`; `scripts/tests/run.sh`; `ThirdParty/ThirdParty.lock.json`; `ThirdParty/licenses/riftvm/LICENSE` |

**Choice.** Use the public `riftvm-v0.6.1` tag as the source-only reference for #018, pinned to commit `51f19193b1d3326b2e164d37a2a59e9970375170`. Analyze its `Experiments/VZVirtioGPUPrototype`, its production-facing app integration and lifecycle, and the source/build files named in the analysis. Classify the pin as `ships: reference` because no RiftVM code or binary is built, copied, or distributed. Treat this tag as a current technical reference, not as a replacement equivalent to the planned v1.0.4.

**Reason.** The upstream tag listing checked on 2026-10-05 contains `riftvm-v0.6.1` but no `v1.0.4` or `riftvm-v1.0.4` ref. The pinned tag retains the low-level macOS custom virtio-gpu prototype needed by #018. Adversarial review found that this is not an isolated experiment: the main RiftVM app links `RiftVMVirGLRuntime`, and `VMCustomVirGLGraphicsBackend` constructs and shuts down that runtime in the ordinary VM path. The maintained architecture supports general Linux VMs as well as an Omarchy integration; the detailed end-to-end results cited in the source are specifically Omarchy/Hyprland. `ships: derived` would falsely claim that #018 copies or adapts RiftVM code and would force an incorrect app notice. A dedicated `reference` classification preserves the pin and license evidence while excluding it from build inputs and redistribution notices. The upstream tag is unsigned and its GitHub release is not immutable, so the lock stores the full commit rather than trusting a tag for content identity; that does not independently authenticate the publisher. The upstream release-notice document also conflicts with its source-build documentation and release script about which renderer artifacts are packaged. The analysis therefore relies on the exact source, pinned build scripts, and recipe checksums at the locked commit, and makes no claim about which binaries a published RiftVM release shipped. RiftVM's root MIT license covers its own source; renderer libraries and build-recipe inputs retain separate license/provenance entries when APKRun later adopts them.

**Verification.** The remote tag ref peels to the locked commit, and the read-only checkout is at that exact commit. The root `LICENSE` is copied to `ThirdParty/licenses/riftvm/LICENSE`. The lock entry is in the `graphics-reference` group with empty build flags and patches; renderer build-group processing and `check-lock.sh --apply` exclude it. The future `generate-notices.py --check` may fetch it solely to verify the committed license copy; it does not build RiftVM or include it in generated notices. Lock tests accept the repository entry and reject reference entries with a non-source kind, build flags, patches, or an unknown classification. The build/legal documentation excludes reference entries from renderer build groups and redistribution notices while retaining the identified license and a committed copy of the upstream license. Adversarial review identified lifecycle, reference-validation, and licensing-scope gaps; those fixes passed a full CI check run. Follow-up reviews corrected the license-file path description, notice scope, and license-check fetch description; the final adversarial review found no remaining actionable issues. `git diff --check` passed, and the committed RiftVM license copy matches the pinned root license. No RiftVM code or renderer binary is copied or built for this task. The source choice, unsigned tag provenance, and v1.0.4 substitution remain for maintainer review.

**Follow-up hostile review (2026-10-06).** A read-only subagent review of
the #018 criteria, analysis, lock entry, and graphics design found no
additional actionable documentation or lock inconsistencies. The pinned
RiftVM source tree was not available in that review workspace, so it did not
independently recheck the source-level claims; those remain supported by the
pinned-checkout review recorded above. Maintainer review remains pending.

## IR-185: Verify Mesa driver payload in the pinned Cuttlefish image

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [environment setup](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064; [android-image.json](../../Images/manifests/16373615/android-image.json); `Images/tools/apkrun_image/{lp.py,sparse.py}` |

**Choice.** Keep build 16373615 and its `drm_virgl` target capture unchanged and incomplete. Record the guest driver packaging mismatch against this pinned image. Any capture using a corrected guest image is separate scope and needs its own source provenance and tracked packaging work.

**Reason.** IR-172 recorded that the guest selected `ro.hardware.egl=mesa`, could not load a Mesa EGL/GLES implementation, and repeatedly aborted SurfaceFlinger during EGL/Skia renderer creation. A static inspection now checks the pinned input image. The clean `super.img` used for inspection has SHA-256 `54052b9f2d0f463e995c90b9eecc4b3a8aad29d110044aac9c2170108feb5a05`, matching the committed manifest. The repository's sparse-image and liblp readers located the active-slot EROFS partitions. `vendor_a:/lib64/egl` contains only `libEGL_emulation.so`, `libGLESv1_CM_emulation.so`, and `libGLESv2_emulation.so`. In `system_a`, both `/lib64/egl` and `/system/lib64/egl` are absent; checking both covers the guest path whether the partition is mounted at `/system` or at `/`. Its `/system/lib64` contains the platform EGL/GLES and ANGLE libraries but no Mesa-named driver. This confirms the absence of Mesa drivers from the preferred vendor directory and the corresponding system EGL directory in the pinned image, consistent with the guest loader failure recorded in IR-172. It does not establish why later Android service and boot-readiness probes stalled.

**Verification.** `read_dynamic_partitions(..., sparse=True)` parsed the manifest-matching super image. The `system_a` and `vendor_a` EROFS payloads were read and inspected with `dump.erofs` from `erofs-utils` 1.7.1. Both possible `system_a` mount-relative EGL paths were checked directly, and its `/system/lib64` listing was filtered for Mesa, EGL, and GLES library names. The temporary package was unpacked under Lima `/tmp`; it was not installed. The live guest listing in IR-172 independently reports only the three emulator libraries under `/vendor/lib64/egl` and an absent `/system/lib64/egl`. No guest was booted or modified for this check, and no extracted image or raw third-party report was added to the repository.

## IR-186: Check guest-capture syntax with the pinned Android shell

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/guest-capture.txt`; [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §3.3; [android-image.json](../../Images/manifests/16373615/android-image.json) |

**Choice.** Record syntax acceptance by the pinned Android shell as supplemental evidence. Do not mark the `guest-capture.txt` execution acceptance criterion complete without running it through both ADB and the serial shell.

**Reason.** The task's current T0 parses every command with the host's `/bin/sh`. A check against the actual Android `/system/bin/sh` in build 16373615 can catch shell-parser incompatibilities earlier, without starting Cuttlefish. Syntax-only parsing does not establish that the Android commands succeed or that either transport passes the command strings unchanged.

**Verification.** The clean `super.img` used for IR-185 matched the manifest SHA-256. The repository's sparse-image and liblp readers extracted `system_a`; EROFS and the `com.android.runtime` APEX were mounted read-only under Lima. The image's `/system/bin/sh` accepted all 27 non-comment command strings with `-n -c`. `shlex.split` identified nine nested `su 0 sh -c` bodies, and the same Android shell accepted each body separately with `-n -c`. A negative control (`if then`) was rejected with a syntax error. The Android linker warned that the generated `/linkerconfig/ld.config.txt` was unavailable in the chroot, but all syntax checks returned success. No guest boot, guest command execution, ADB query, or serial-shell execution was performed. Temporary extracts and package files were removed after the check.

## IR-187: Verify runtime crosvm unwinder symbol binding

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [environment setup](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Record the runtime symbol-binding comparison as supplemental
evidence for IR-171. Rely on the already completed preload capture to recover
the panic text; do not repeat a Cuttlefish boot solely for that purpose.

**Reason.** IR-171's third diagnostic capture already applied the wrapper to
both `cvd create` and `cvd start`, recorded `LD_PRELOAD`, and recovered the
panic message before crosvm exited with `SIGABRT`. Its source investigation
traced that panic to the host package requesting `backend=virglrenderer`
without crosvm's `virgl_renderer` feature. A loader-only comparison can
directly check the interposition hypothesis without another guest boot. It
cannot by itself prove which callback frame caused the earlier SIGSEGV.

**Verification.** On the arm64 Lima host, the installed package binaries have the
same Build IDs as the prior crosvm crash record: crosvm
`d724bf54f045b0ec7dbe14049b0fed9a16e52a23` and
`libgfxstream_backend.so` `6b8f3105442da5c66988881a1fa76e812b13c3e8`.
`readelf` confirms that crosvm needs both `libgfxstream_backend.so` and
`libgcc_s.so.1`, that crosvm imports `_Unwind_GetIP` and `_Unwind_Backtrace`,
and that gfxstream exports `_Unwind_GetIP` and `unw_get_reg`. In a
`crosvm --help` process with `LD_BIND_NOW=1 LD_DEBUG=bindings`, the loader
binds crosvm's `_Unwind_GetIP` to gfxstream and `_Unwind_Backtrace` to
libgcc_s. In a separate `crosvm --help` process with the same loader settings
and `LD_PRELOAD=/lib/aarch64-linux-gnu/libgcc_s.so.1`, it binds `_Unwind_GetIP`
references from both crosvm and gfxstream to libgcc_s. These checks exercise
dynamic loading, not the panic hook or GPU worker. The prior IR-171 run
already recovered `Failed to create virtio gpu worker thread: invalid
rutabaga build parameters`; it had no guest kernel output or Android boot
evidence. This loader comparison did not start a Cuttlefish VM or issue ADB
or serial-shell commands.

The maintainer-supplied follow-up analysis recommends recovering panic output
before pursuing matching debug symbols and proposes that a second fault may
occur while the panic hook unwinds the backtrace. The symbol-free preload
capture it recommends was already completed in IR-171, so no matching-symbol
search or duplicate VM boot is needed. IR-187 confirms the loader binding
change in `crosvm --help` processes, but neither run executes the panic hook's
backtrace callback. The proposed LLVM/libgcc cursor mismatch and null-vtable
slot explanation therefore remain hypotheses; the recovered missing
`virgl_renderer` build feature is the demonstrated cause of the panic itself.
The unavailable Apport record for the later PID remains unconfirmed; do not
transfer the executable path recorded for the earlier PID to it.

## IR-189: Preflight pinned patch series before applying

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #020 |
| Affected files | `scripts/tools/check-lock.swift`; `scripts/tests/run.sh`; [build-system.md](../05-development/build-system.md) §6.2; [M02 graphics](issues/M02-graphics.md) #020 |

**Choice.** Make `check-lock.sh --apply` read one immutable lock-file snapshot, serialize its own apply invocations, and preflight every complete patch series in disposable clones before creating a separate root-level staging checkout. Open the random staging directory before Git runs, then use that directory as Git's working directory through its open descriptor. Read each patch through no-follow directory descriptors into one bounded byte snapshot, then use those same bytes for preflight and application. Keep the pinned source checkout detached, clean, and unchanged; open output directories without following symlinks and atomically publish only a fully validated patched checkout under `ThirdParty/out/patched-src/<name>/<commit>/<patch-set SHA-256>/`. Detect output-directory identity changes and attempt to roll a just-published checkout back to root-level staging. Preserve a failed staging checkout without running `git am --abort` or `git reset --hard`; diagnostics report last-known paths, which may become stale if another same-user process moves the directories.

**Reason.** An advisory lock coordinates this tool's own invocations but cannot control other Git processes. Applying directly to a pinned source checkout leaves a race where another process can advance its HEAD before `git am`, and automatic abort or reset can overwrite concurrent state. Applying to a separate generated checkout avoids modifying that input and prevents a concurrent source checkout change from becoming part of the patch commit chain. Disposable-clone preflight detects invalid later patches before publishing output. The lock and patch snapshots prevent validation and application from interpreting different bytes if their files change mid-run; `GIT_OPTIONAL_LOCKS=0` prevents `git status` from refreshing the source index. No-follow directory-descriptor traversal prevents a parent-path symlink swap from redirecting patch reads or staging writes. Staging at the project root keeps clone and patch writes away from the output path until publication. Output path identities are checked before and after the FD-relative rename; if reopening the output path fails, the code uses the held output descriptor to attempt rollback. A same-user process can still move the open staging directory while Git runs, move the published checkout between identity checks, or rename it during rollback; POSIX directory descriptors pin an inode but not its pathname. Such changes can redirect staging writes or make recovery paths stale. The apply lock coordinates only this command, so rollback and diagnostics remain best-effort when another same-user process changes the project namespace. Maintainer review should decide whether that threat boundary is acceptable.

**Verification.** `scripts/tests/run.sh` passed, including patch-application fixtures for valid application and idempotent reuse, failed preflight, dirty or incorrectly pinned sources, Git operation/index states, FIFOs, configured helpers, pre-existing symlinks, an output-parent move during application, and concurrent invocations. The repository's lock, module-dependency, workflow-security, CI-policy, marker, format, and release fixtures also passed. `scripts/check-lock.sh --root scripts/tests/fixtures/lock/base`, `xcrun swift-format lint --strict scripts/tools/check-lock.swift`, `bash -n scripts/check-lock.sh scripts/tests/run.sh`, and `git diff --check` passed. Hostile review confirmed the source index remains unchanged and rollback is attempted on every post-publication verification failure. It also confirmed the documented same-user rename boundary: an open directory descriptor pins an inode, not its pathname, so out-of-band directory moves can redirect writes or make recovery paths stale.

## IR-190: Scope renderer build flags and cache identity

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #020 |
| Affected files | `ThirdParty/ThirdParty.lock.json`; `ThirdParty/patches/{angle,libepoxy,virglrenderer}/`; `scripts/tools/build_third_party.py`; `scripts/build-third-party.sh`; `ThirdParty/build/`; [graphics.md](../02-design/graphics.md) §5.1; [build-system.md](../05-development/build-system.md) §6; [M02 graphics](issues/M02-graphics.md) #020 |

**Choice.** Build virglrenderer with `venus=false` for v1, while retaining the ANGLE Metal GLES backend. Carry the pinned recipe patches for macOS renderer support, EGL/GLES dispatch, Metal boolean `mix`, and VirGL MSAA fallback, rebased as ordered `git format-patch` files against APKRun's exact source commits. Add a local virglrenderer patch that links CoreFoundation and the Objective-C runtime required by the Metal backend when Venus is disabled. Use `@rpath` install names and only `@loader_path` runpaths so bundled dependencies resolve beside each library. Fetch each selected source commit before calling `check-lock.sh --apply`; keep source and patched checkouts clean and run ANGLE `gclient sync` and compilation in separate work areas under `ThirdParty/out/work/`. Run depot_tools only from its work-area clone because gclient writes CIPD and metrics state. Pin PyYAML 6.0.3 by commit in the same tooling group and expose its source tree only to virglrenderer's Meson process. Identify the build output with both the lock-input hash and an environment hash that includes Xcode/SDK/Metal, compiler, Python, the PyYAML pin, Git, Meson, Ninja, and pkg-config. Sanitize build environment variables, serialize same-key builds, validate the lock before computing or reusing a cache entry, reject patch paths that escape or link out of the patch tree, treat malformed manifests as cache misses, and validate each artifact's digest, architecture, minimum OS, install name, runpaths, and bundled dependency targets before publishing the output directory.

**Reason.** The product rules defer Vulkan to a later track, while the v1 graphics path uses GLES through VirGL and ANGLE Metal. Disabling the host Venus backend avoids adding a Vulkan implementation and its build dependencies to this v1 build; RiftVM's `venus=true` is not inherited wholesale. The source-only and patched checkouts are shared build inputs and must not be modified by `gclient` or compilation. A lock-only cache key could reuse artifacts built with a different Xcode, SDK, Metal compiler, or Meson toolchain; the environment component prevents that cross-toolchain reuse. Fetching first resolves the clean-checkout failure identified in adversarial review, because `check-lock.sh --apply` intentionally requires exact source checkouts. An initial build also exposed that virglrenderer’s Meson configuration imports `yaml`, which had been available only from the developer's user-site Python packages and disappeared in the sanitized build environment. Pinning PyYAML and setting `PYTHONPATH` only for that Meson invocation removes this undeclared host dependency. These are implementation choices that affect the renderer's optional backend and build reproducibility and therefore need maintainer review.

**Verification.** T0 tests cover canonical lock hashing, exclusion of reference-only entries, invalidation by flags/patches/scripts, environment-hash changes, exact source fetching, dirty-source rejection, safe patch paths, lock validation before cache lookup, and partial or corrupted manifests. The implementation also checks the generated Mach-O files before atomic publication. The pinned-PyYAML import test passes. Record the full ANGLE/libepoxy/virglrenderer build and second-run cache hit here before closing #020. The chosen `venus=false` flag and the exact adopted patch set remain for maintainer review.

## IR-191: Verify and embed the graphics runtime with notices

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #020 |
| Affected files | `scripts/tools/build_third_party.py`; `scripts/build/embed-virgl-runtime.sh`; `scripts/release/generate-notices.py`; `scripts/release/check-release-build.sh`; `project.yml`; `.github/workflows/{ci,clean-third-party}.yml`; [graphics.md](../02-design/graphics.md) §5.1; [build-system.md](../05-development/build-system.md) §§6, 11, 15.1; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §6 |

**Choice.** Require every runtime dylib to carry only an `@loader_path` runpath and resolve each non-system dependency to one of the four files in the runtime directory. Normalize ANGLE, libepoxy, and virglrenderer runpaths and install names before checking them. Compare `gn desc` dependencies for both ANGLE Metal targets against the locked ASTC encoder, Vulkan headers, and zlib notice entries; fail the build if a `//third_party/` dependency is missing or no longer used. Make the APKRun target verify the composite cache entry, replace the destination runtime directory, copy the four libraries into `Contents/Frameworks/VirGLRuntime`, and sign each inner library with the app's build identity when signing is enabled. Make the app build wait for the third-party CI job and restore the same cache key; run the weekly empty-cache build on the ephemeral `xcode-27` runner. Generate notices from the committed lock and license copies. While OQ-40 remains open, the notice page says the project license has not been selected rather than choosing one.

**Reason.** The previous validator accepted absolute work-tree runpaths and did not ensure that `@rpath` dependencies existed in the runtime directory. The first native link also recorded libepoxy's temporary install prefix in virglrenderer, so the builder now normalizes libepoxy's install ID before linking its consumer. A validator initially mistook `otool`'s file-name header for a load-command path; only load-command records are now checked. The app build had no phase to embed the produced libraries, and a successful third-party job did not make them available to a separate build runner. Recreating the destination avoids carrying a stale library forward in reused DerivedData, and the release checker rejects unexpected files. The ANGLE inventory makes the notice check fail when its Metal target graph gains or loses a third-party subtree. A clean ephemeral runner gives the weekly job a genuinely empty workspace without relying on a persistent machine. Checking reference and resolved package licenses belongs to the broader #093 legal task. OQ-40 is unresolved, so inventing a project license for the HTML would conflict with the maintained policy.

**Verification.** T0 coverage checks that the ANGLE graph exactly matches the locked `gnTargetPrefixes`, that the bundled libraries have valid arm64 Mach-O metadata and no work-tree paths, that notices are deterministic and safely escaped, and that stale runtime files are replaced and rejected by release checks. `scripts/tests/run.sh`, the final clean native build and cache hit, release configuration build, and hostile review results are recorded below as they complete. Full GraphicsBridge creation/capset coverage remains a separate #020 deliverable.

## IR-192: Add the host VirGL renderer bridge

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #020 |
| Affected files | `Package.swift`; `Packages/GraphicsCore/Sources/GraphicsBridge/`; `Packages/GraphicsCore/Sources/GraphicsCore/GraphicsCore.swift`; `Packages/GraphicsCore/Tests/GraphicsCore{Tests,SystemTests}/`; `Packages/DiagnosticsCore/ErrorCatalog/errors.json`; `scripts/errorgen.swift`; `.github/workflows/ci.yml`; [graphics.md](../02-design/graphics.md) §5.2, §16; [build-system.md](../05-development/build-system.md) §15.1; [M02 graphics](issues/M02-graphics.md) #020 |

**Choice.** Resolve bundled libraries only from an ancestor app whose `CFBundleIdentifier` and `APKRunBuildIdentity` match one of three exact pairs: `io.apkrun.APKRun`/`release`, `io.apkrun.APKRun.updatetest`/`updatetest`, and, in Debug, `io.apkrun.APKRun.dev`/`dev`. ReleaseUpdateTest uses Release-built package code, so the bridge checks the app identity at runtime and supports that one designated test identity without accepting arbitrary bundle identifiers. Reject the runtime directory and individual library symlinks if they resolve outside the matched bundle. Debug builds also accept `APKRUN_VIRGL_RUNTIME_PATH` and search the repository's verified `ThirdParty/out/virgl-runtime/current` cache. Keep the C interface opaque and fixed-width, copy the public callback table into renderer-owned state, and retain the virglrenderer callback table through cleanup. Enforce one process-wide renderer because virglrenderer has global state, record the creating thread, and return a typed failure for every wrong-thread operation on a live renderer. Require callers to serialize access and finish all in-flight calls, including rejected off-thread calls, before destruction; successful destruction invalidates the handle. Require a caller-supplied capset output length and reject undersized buffers before calling upstream. Locate Clang's UBSan runtime with `xcrun` and add its library directory and rpath to Debug links from GraphicsBridge without enabling UBSan; Release products do not receive this link setting. In the embedded CLI, read `APKRUN_TEST_LINUX_DIR` only in Debug and use a generic runtime error message so Release binaries satisfy the no-test-hooks rule.

**Reason.** Loading the same four verified dylibs that are embedded in the app avoids link-time exposure of EGL, Objective-C, or virglrenderer types to Swift. Build-system §2.4 requires local package code for ReleaseUpdateTest to use the Release configuration, so GraphicsBridge cannot compile a configuration-specific test exception. Instead, the resolver matches the running app's exact bundle identifier and `APKRunBuildIdentity` pair; the shipped APKRun bundle continues to resolve only as `io.apkrun.APKRun`/`release`, while the separately signed maintenance test app resolves as `io.apkrun.APKRun.updatetest`/`updatetest`. Unknown and mismatched apps are rejected. This runtime identity choice is recorded for maintainer review because the Release-built package contains the narrow test-pair allowance. Resolved-path checks keep both the runtime directory and every dylib inside that identified app tree. The dedicated 1 × 1 GLES context lets virglrenderer create shared contexts through the pinned callback-v4 EGL path and exposes the exact ANGLE Metal device for later IOSurface textures. The singleton guard prevents two callers from corrupting virglrenderer’s process-global tables. A final hostile review identified that checking a raw renderer pointer's owner thread cannot protect it from concurrent destruction by another thread. A registry or reference-counted admission gate would add synchronization and reentrancy complexity to this narrow C API, so the bridge instead makes object lifetime explicit: callers must quiesce and synchronize every operation before destroy, and must not reuse the handle after successful destroy. This matches the render-thread ownership model; the T1 test joins its worker before owner-thread teardown. This is an implementation judgment for maintainer review. Buffer length validation prevents the upstream capset writer from overrunning caller storage. The T1 renderer test's executable is SwiftPM's `.build` test runner, so it sets the documented Debug override from its source location. A Debug-only resolver probe lets the test exercise bundle identities and path containment using temporary app fixtures without adding a production test hook. The first Release bundle check also exposed a pre-existing `APKRUN_TEST_LINUX_DIR` string in the embedded CLI and the shared error catalog. Keeping that override Debug-only and making its error text generic removes a test marker from every Release executable without changing the Debug test workflow. SwiftPM instruments the C target for `swift test --sanitize=undefined` but omits Clang's dynamic runtime at the final link. Linking the runtime at the GraphicsBridge boundary supports every test product that includes its static object; this is a runtime link only and does not select UBSan for all Debug builds.

**Verification.** On arm64 macOS 27.0 build 26A428 with Xcode 27.0 build 27A266a, the pinned ANGLE, libepoxy, and virglrenderer native build completed earlier; its second run verified cache key `154fc8299ff3181c003a5c118152b38509e0b134d03016ba049c3c5f967b3171-130256a8a5ba36a2bf7032d66937b2c69bb684336c515ca06a20149185d32ad0` (IR-191). `swift test --filter GraphicsCoreTests -j 2` passed all three T0 tests. The final host T1 suite passed normally, with Address Sanitizer, and with Undefined Behavior Sanitizer. It covers renderer creation, capset fill and undersized-buffer rejection, context ID recreation, all public operations on the wrong thread, worker completion before owner-thread teardown, process-slot recreation, exact Release and ReleaseUpdateTest identity pairs, mismatched and unknown identities, and runtime-directory/library symlink escapes. Hostile review found no actionable P1/P2 issues after the lifetime contract was clarified; it confirmed the caller must synchronize all in-flight calls and never use a handle after destruction. Residual risk: the raw-pointer C API documents but does not internally enforce that quiescence requirement. The Release app build and `scripts/release/check-release-build.sh` passed, including checks for the production bundle identity and embedded runtime. The current XcodeGen project does not define a `ReleaseUpdateTest` configuration: `xcodebuild -showBuildSettings` resolves that name to Debug and the `.dev` identity, so this task validates the `updatetest` resolver pair with signed-app fixtures; actual maintenance-app integration remains for #057. After the lifetime-contract test comment and documentation were added, `scripts/check-format.sh`, both `scripts/errorgen.swift` generated-file checks, `git diff --check`, and the full `scripts/ci/run-checks.sh` all passed.

## IR-193: Confine custom virtio teardown and completion to device queues

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #063 |
| Affected files | `Packages/VirtioDeviceCore/`; `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/VZVirtualMachineDriver.swift`; `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/`; `Tests/IntegrationTests/LinuxGuestTests/`; `project.yml`; [graphics.md](../02-design/graphics.md) §3, §12, §14, §16; [vm.md](../02-design/vm.md) §9; [test-strategy.md](test-strategy.md) §2.2; [M00](issues/M00-repository-and-vm-foundation.md) #063 |

**Choice.** Keep `VirtioDeviceContext` non-`Sendable` so its synchronous queue, feature, and memory methods remain on the device queue; create one context per model callback and bind it to that generation. Queue, feature, and mapping access through an older context fails with `.notReady`, and its stale reset request is ignored. The separate `Sendable` configuration updater carries the captured generation across async work, so an old handle also fails with `.notReady` after a later `DRIVER_OK`. Make `PendingElement` noncopyable and `Sendable`; its VZ storage only schedules completion back onto the serial device queue. When an escaping closure requires a copyable capture, transfer ownership to a package-scoped, lock-backed one-shot completion token that traps at runtime on duplicate completion and uses the same serial completion path. Serialize configuration updates and resolve requests with `.notReady` when reset or release invalidates them. Cache one queue adapter per queue index. The wrapper weakly references its adapter, while a queue lease weakly references its owner and drops the VZ queue on invalidation; this prevents a model that retains a queue wrapper from forming an adapter/model cycle or extending the framework queue's lifetime. The pending handle weakly references its target; invalidating element storage releases its `VZVirtioQueueElement`, and a later completion becomes a no-op. A lock-backed pending-element lifecycle checks a thread-safe VZ epoch as well as per-element invalidation; advancing the epoch is the reset barrier visible to handles before per-element cleanup runs. A live forgotten handle still schedules completion and asserts in Debug, while a handle dropped after epoch invalidation is ignored. Before releasing a VM, synchronously drain each custom-device queue, invalidate pending elements and mappings, notify the model once, and clear the weak VZ delegate. Invalidate guest state before model reset/stop callbacks so a model cannot accidentally use stale guest memory during cleanup. The T2 fixture probes one 4 KiB page at `0x70000000`, the RAM start recorded for the Linux test guest in [vm.md](../02-design/vm.md) §5. Probe mode retains only the invalidated mapping token after reset so it can verify that access is rejected in both reset and stop callbacks. The reboot observer fails promptly on a guest-check failure, an early `.done`, a failed VM state, or a terminal stop before the marker, and has a timeout before and after the reboot marker. The reboot T2 verifies the guest-console record order and the serialized VZ callback order independently because they arrive on different queues. Preserve successful T2 console, host-log, and reboot-observation attachments with `keepAlways`. Use Swift Testing's built-in process-exit assertion for the two debug-only forgotten-handle checks required by #063; additional exit and concurrent epoch tests cover live abandonment and reset invalidation.

**Reason.** The VZ adapter is the only owner of framework-backed memory and queue elements, so keeping access on its serial device queue makes reset and release the invalidation barrier. A model can retain a queue returned from its context; the weak-owner lease prevents that client reference from keeping the adapter, model, or VZ queue alive after reset. A renderer fence may signal on another queue; a sendable pending handle allows that completion to cross actor boundaries without exposing VZ objects off-queue. Reset or release must also release the VZ element and its buffers even if a renderer never signals its fence; the weak target and invalidated element storage let the adapter drop those resources while keeping late completion safe. The handle may be dropped concurrently from another actor while reset runs on the device queue, so the shared, lock-protected epoch makes the generation invalidation visible before the adapter releases each element individually. Binding the context and updater to their creation generation prevents both synchronous access and delayed async work from reaching a restarted device; the T2 guest reset exercises those checks against the actual VZ adapter. The old configuration update's completion remains the queue's active barrier after its caller has received `.notReady`; this avoids starting a new generation's update concurrently with an update still in flight. The static test GPA follows the documented VZ guest topology and is confined to the Linux test guest; #011 still records the hardware topology for the product. The ordinary shutdown probe observes `WillReset` before `WillStop`, so it cannot prove stop-only mapping invalidation; the forced-stop T2 closes that gap with model-callback observers recorded on the adapter's serial device queue; it asserts that no reset callback occurs between mapping creation and stop, independent of log message text. The reboot probe treats a failed VM state as an error after or before the reboot marker. Its attachments preserve the guest-console record order and serialized VZ callback order independently. Persistent attachments preserve the evidence when Xcode removes default `deleteOnSuccess` attachments. The task explicitly requires a Swift Testing exit test for code that asserts during `deinit`, so the built-in exit-test facility is used instead of hand-written subprocess management. The T0 strategy otherwise prohibits subprocesses; the built-in facility is a narrow task-specific exception that needs maintainer review. `APKRunTestHost` now depends on the `BuildStamp` aggregate because the shared Info.plist prefix is a required build input, and the clean integration build exposed that missing dependency.

**Verification.** On arm64 macOS 27.0 build 26A428 with Xcode 27.0 build 27A266a, `swift test --filter VirtioDeviceCoreTests -j 2` passed 26 tests and `swift test --filter VirtualMachineCoreTests -j 2` passed 71. A clean filtered-copy `xcodebuild build-for-testing` passed, then all 10 LinuxGuest XCTest cases and 6 observer tests passed. The forced-stop callback attachment confirms that no `WillReset` occurred between mapping creation and `WillStop`, and records the late completion attempt after stop. The reboot attachment records guest-console and VZ callback order as separate streams; it does not establish cross-stream ordering. `scripts/check-format.sh`, `scripts/check-module-deps.sh`, `sh -n Tests/Fixtures/linux/init`, and `git diff --check` passed. The first hostile review found a queue-retention cycle, VZ element retention after invalidation, and asked that the reboot observation be verified from an attachment. Later reviews found and led to fixes for pending-element reset races, stale VZ contexts, failed-VM reboot observations, reset-free forced-stop evidence, and per-stream reboot ordering. The final review found one documentation overclaim about type-system protection for the copyable completion token; the wording now distinguishes compile-time handle protection from the token's runtime guard, which has a duplicate-completion process-exit regression test. The final read-only check confirmed that correction, the reported test counts, and no remaining actionable P1/P2 findings.

## IR-194: Persist serial console output and add the Linux development console

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #004 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Console/`; `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/VMController.swift`; `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Health/VMHealthChecks.swift`; `Packages/RuntimeCore/Sources/RuntimeCore/Dev/LinuxTestGuestRunner.swift`; `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevConsole.swift`; `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevConsoleInputWriter.swift`; `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevConsoleOutputWriter.swift`; `CLI/apkrun/Dev/`; `Packages/DiagnosticsCore/ErrorCatalog/`; `Tests/Fixtures/linux/init`; `Tests/IntegrationTests/LinuxGuestTests/`; [vm.md](../02-design/vm.md) §6; [cli.md](../02-design/cli.md) §5; [test-strategy.md](test-strategy.md) #004 |

**Choice.** In M0, `apkrun dev console` boots the pinned Linux test guest, places the caller's terminal in raw mode, connects both directions to hvc0, and treats Ctrl-] as a guest-stop request followed by a bounded forced-stop fallback. Android/dev-socket attachment remains for #014. The test guest announces when it has configured hvc1 and hvc2 before the host sends service-port markers, avoiding a race with guest tty setup. Persist hvc0 bytes through a separate bounded subscription into private current and per-boot files; rotate at the documented limits and report both file-write failures and dropped stream bytes through `vm.consoleWriter`. Read guest output on a dedicated nonblocking `DispatchSourceRead` queue with a 1 MiB per-callback budget. Each drain barrier runs on that queue after one bounded snapshot (at most 4 MiB or 50 ms), then marks the bytes yielded before it. A log stream reserves one additional queue slot for the barrier, so a full data buffer cannot reject or evict the control marker; the writer releases a data slot only after persisting that chunk and recording any loss. Waiters that arrive during an active barrier are held for a fresh read-queue snapshot after that barrier is acknowledged, rather than inheriting a snapshot that predates their failure. The bounded snapshot avoids an endless failure transition under continuous guest output. Register natural-stop resource release before publishing `.stopped`; the integration harness joins that release before reading logs and preserves the run directory when resources cannot be released. Host input writes run on a bounded serial writer outside the signal loop and lifecycle lock. The input channel latches Ctrl-] when the producer publishes it, so an already-published detach outranks a concurrent writer error; Ctrl-] cancels queued input, while detachment closes the guest-readable pipe endpoint, waits for in-flight writes, and suppresses `SIGPIPE` on the host writer. A nonblocking stdout writer polls for capacity and checks cancellation every 50 ms; it counts unwritten bytes and restores the original descriptor flags before leaving raw terminal mode. If output must stop before stream cleanup finishes, the writer can stop terminal writes and restore the descriptor while the raw stream consumer stays attached through a drain barrier. If stop and reset both fail, the CLI restores the terminal immediately, reports cleanup pending, and keeps the instance lock while VM and log resources remain active. The two-second parsed-console EOF wait cancels and joins its consumer before the later VM log-release wait. Session drain waits for the VM log writer's final sync before the CLI releases its instance lock. The Linux test session exposes a combined dropped-and-pending byte snapshot from its bounded raw-output stream; the CLI combines it with terminal-writer loss only after the raw consumer joins.

**Reason.** The plan orders Linux boot and serial console work before Android, so the M0 console targets the test guest without skipping the later #014 integration. A readiness marker on hvc0 provides an explicit ordering point for each service port. Disk I/O remains isolated from the pipe reader by a bounded stream, and loss counters prevent identical truncation in two files from looking like a complete capture. Hostile review found that a barrier could overtake a pending read-source callback; every barrier now inserts its bounded drain and marker in one read-queue turn. A second finding showed that unbounded draining could starve failure under continuous output, so one snapshot is capped at 4 MiB and 50 ms. The consumer-drain gate retains waiters only for their own acknowledged barrier; for `preserveNewest`, it counts the displaced guest chunk when the marker replaces it. The log stream's reserved control slot keeps the marker available while data slots are full, and the writer acknowledges each data slot after persistence and loss accounting. A separate review found that synchronous host input could prevent Ctrl-] from being processed; input now goes through a bounded serial writer and stop cancels pending chunks. The detach request is latched at publication time so an already-buffered Ctrl-] still wins over a racing writer error. Cancellation cannot interrupt a synchronous `FileHandle.write`, so the raw terminal output path uses nonblocking `write` plus bounded `poll`; cancellation is checked after each 50 ms wait and unsent bytes are counted. The CLI restores output flags and terminal settings only after stopping and joining terminal writes, while keeping the raw subscriber alive until a bounded read-queue barrier is acknowledged. Each stream chunk is counted as pending before `yield`, so a waiting consumer cannot acknowledge it before the counter changes; displaced and rejected chunks are removed from pending as they are counted as dropped. The final dropped-plus-pending snapshot uses the counter's single lock. The real-pipe test joins bytes from any number of reads instead of assuming pipe reads match host writes. A further review found that the two-second parser deadline cancelled `recordTask` only after leaving a structured task group whose child awaited that task, so the scope could wait past the deadline. Cancellation now happens before the task group joins its children, and a T0 regression test verifies that an open `AsyncStream` consumer is cancelled and joined. A cleanup failure therefore restores the terminal promptly, still accounts output during the final drain, and reports the combined stream and writer loss after the consumer joins. If both stop and reset fail, the instance lock remains held while VM/log resources remain active. Reset runs once in the shared error cleanup path. Revalidating the VM transition after the await prevents a late stop event or duplicate failure callback from replacing the settled state. The attached crosvm analysis is consistent with the evidence already recorded in IR-171 and IR-187: the installed package Build IDs, exported/imported unwinder symbols, loader binding comparison, and diagnostic preload capture have been checked, and the preload recovered the `invalid rutabaga build parameters` panic. Matching debug symbols are not needed to identify that demonstrated panic. The earlier SIGSEGV may still have been a secondary fault during backtrace collection; the null-vtable explanation remains a hypothesis, and the later recovered panic does not establish the earlier PID's exact executable path or root cause. Raw Apport reports and core payloads for the 2026-10-04 diagnostic captures were kept in Lima’s private storage and were not copied into the repository; see IR-224 for the later availability search for PID 1573779. This Linux-guest console work does not change that Cuttlefish diagnosis or claim that Virgl/gfxstream caused the secondary signal.

**Loss-reporting review.** Output cancellation runs through a separate callback before serialized event delivery, so a console write waiting on terminal capacity cannot block cleanup from restoring the terminal. The cleanup-pending message is deferred until after the raw stream consumer acknowledges its bounded drain barrier and is joined; this prevents a blocked stderr write from holding the event-sink lock needed by that consumer. The consumer stays active through its barrier, then is joined before loss is reported. The failure-drain budget is intentionally fixed at 4 MiB or 50 ms, checked between pipe reads; output still in the guest pipe beyond that cutoff is not included, so the cataloged count says “at least.” The instance lock remains held while VM or log cleanup continues after the warning.

**Verification.** The earlier `swift test -j 2` suite passed after the timeout-ordering, read-deadline, and cleanup-message-order fixes, including 78 `VirtualMachineCoreTests`, 12 `VirtualMachineCoreSystemTests`, four `RuntimeHostTests`, and the `RuntimeCore` console-task timeout regression. The continuous-output drain test passed in 25 ms; the open-stream task cancellation test passed at its 10 ms deadline. `swift build --traits EmbeddedRuntime` passed. The non-TTY CLI check returned the expected exit 64 and cataloged terminal remediation. On 2026-10-06 UTC, the final `ConsoleLogWriterTests` passed 9/9, `VirtualMachineCoreTests` passed 84/84, `VirtualMachineCoreSystemTests` passed 18/18, and `apkrunTests` passed 19/19. Signed `LinuxGuestConsoleTests` passed 5/5 on arm64 macOS 27.0 (26A428), including console persistence, LF/CRLF matching, forced stop during flood, panic/call-trace capture, and service-port numbering. The final result bundle is local at `/tmp/apkrun-console-signed-T2-batchbound.xcresult`; `APKRunTestHost.app` passed strict signature verification and contains the Virtualization entitlement. The guest reported hvc1/hvc2 in attachment-array order. The manual SIGKILL flood check terminated the CLI 50 ms after line 100; stdout had received 1,025 contiguous records and both persisted logs held the same 1,024 complete contiguous records, ending at line 1,024. The last log timestamp is rounded to milliseconds and was within 1 ms of the kill. The interactive console echoed `APKRUN-INTERACTIVE-OK`, accepted Ctrl-], and exited 0. `scripts/ci/run-checks.sh` passed all six checks, as did `scripts/check-format.sh`, `sh -n Tests/Fixtures/linux/init`, and `git diff --check`. Final hostile review found no actionable issues in the batching boundary, cursor, rotation, loss accounting, flood CLI, CRLF, or panic changes.

## IR-195: Select an allowed LGPL version for the Linux block tools

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #005 |
| Affected files | `ThirdParty/ThirdParty.lock.json`; `ThirdParty/licenses/alpine-e2fsprogs/`; `ThirdParty/licenses/alpine-e2fsprogs-libs/`; `ThirdParty/licenses/alpine-libcom-err/`; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §5; [M00](issues/M00-repository-and-vm-foundation.md) #005 |

**Choice.** Record `LGPL-2.1-only` for the e2fsprogs package components whose upstream notice grants LGPL version 2 or any later version. Keep the existing tooling allow-list unchanged, and include the package license files in the lock inventory.

**Reason.** The pinned Alpine package metadata describes these components with an LGPL-2.0-or-later term, while the project's tooling allow-list admits LGPL-2.1-only but not LGPL-2.0-or-later. The upstream notice's later-version grant permits selecting version 2.1 for those covered files. This is a license interpretation made to use the test-only ext4 tools without changing repository policy; it needs maintainer review and is not legal approval. The remaining package licenses are recorded separately in their lock entries.

**Verification.** The copied upstream notices and package license texts are present under `ThirdParty/licenses/`; `scripts/check-lock.sh` passes. The separate `scripts/check-licenses.sh` policy checker belongs to #093 and is not present in this checkout.

## IR-196: Require observable ext4 journal replay after a forced stop

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #005 |
| Affected files | `Tests/Fixtures/linux/init`; `Tests/IntegrationTests/LinuxGuestTests/BlockTests.swift`; [M00](issues/M00-repository-and-vm-foundation.md) #005 |

**Choice.** Mount the stress filesystem with a 600-second journal commit interval, signal readiness only after the first stress-file write and rename succeed, stop the VM three seconds later, and require `e2fsck -fy` output to contain `recovering journal` before declaring recovery successful. Continue to verify that the synced token survives.

**Reason.** Accepting `e2fsck` exit 0 or 1 alone can pass on an already-clean filesystem, so it does not prove journal recovery occurred. Signaling only after a successful write and rename proves the stress workload began before the host's delay. The long commit interval is intended to suppress periodic journal commits during the short forced-stop window, and the recovery marker is the required evidence that journal replay happened. The signed T2 run required by this decision has now passed on the lab Mac.

**Verification.** Guest shell syntax and the host-side fixture checks pass. Hostile review caught that the original readiness marker preceded the first write; it now follows the first successful write and rename, and the final re-review found no remaining actionable issues. On 2026-10-05 UTC, `LinuxGuestBlockTests.testForcedStopDuringWritesCanRecoverTheExt4Disk` passed on arm64 macOS 27.0 (26A428); the guest emitted `APKRUN-BLK-RECOVERY journal replayed`, then mounted the filesystem and verified the token.

## IR-197: Create block fixtures only in a fresh directory

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #005 |
| Affected files | `Tests/Fixtures/linux/make-test-disks.sh`; `scripts/tests/test_make_test_disks.sh`; `Tests/IntegrationTests/LinuxGuestTests/BlockTests.swift` |

**Choice.** The disk generator creates the requested output directory with mode 0700 and fails if that directory already exists.

**Reason.** The previous `mkdir -p` accepted an existing directory, after which opening `ro.img` for writing followed a pre-existing symlink and could truncate a file outside the fixture directory. Atomic creation of the final directory rejects that case before either image is opened.

**Verification.** The fixture test checks deterministic image sizes and hash output, and verifies that the generator refuses a directory containing a symlink without modifying its target.

## IR-198: Record measured guest-visible block order

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #005 |
| Affected documents | [vm.md](../02-design/vm.md) §§5, 17; [M00](issues/M00-repository-and-vm-foundation.md) #005 |

**Choice.** Record the signed T2 observation that guest-visible `/sys/block/vdX/serial` order follows the VZ attachment array for both `[ro, rw]` and `[rw, ro]` on macOS 27.0 (26A428). Keep this as a platform observation; product behavior must not depend on `vdX` letters or PCI slot numbers.

**Reason.** T0 proves the order in the built `VZVirtualMachineConfiguration.storageDevices` array, but only the guest test can establish its visible enumeration. The signed T2 test now covers both attachment orders on this OS build. VZ numbering may change with a future macOS release, so the host-side API continues to identify disks by serial rather than letter.

**Verification.** `LinuxGuestBlockTests.testBlockDeviceSerialOrderTracksBothAttachmentOrders` passed on 2026-10-05 UTC, arm64 macOS 27.0 (26A428). The guest reported the expected serial sequence for `[ro, rw]` and `[rw, ro]`.

## IR-199: Use a temporary local signing identity for LinuxGuest T2

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #005 |
| Affected files | [M00](issues/M00-repository-and-vm-foundation.md) #005; [vm.md](../02-design/vm.md) §17 |

**Choice.** When the documented signing environment variables were unset, select the locally valid Apple Development identity with the latest certificate expiration for this T2 invocation. Pass the identity and Linux test artifact path only to the child `xcodebuild` process; do not write them to shell startup files or repository configuration.

**Reason.** The signed LinuxGuest test is required to validate VZ disk behavior, and multiple valid local identities were available. Selecting the one with the latest expiration avoids choosing an identity near expiry while keeping the run temporary and independent of a committed team ID or certificate fingerprint.

**Verification.** On 2026-10-05 UTC, the test host signed `APKRunTestHost.app` and `IntegrationTests.xctest`; `codesign --verify --deep --strict` passed for both, and the host app carried the Virtualization entitlement. The `LinuxGuest` test-plan configuration passed all three `LinuxGuestBlockTests`. The xcresult is local to the test host at `/tmp/apkrun-blk-signed-T2.xcresult`; no signing identity or team identifier is recorded in the repository.

## IR-200: Make the console flood crash check runnable from the development CLI

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #004 |
| Affected files | `CLI/apkrun/Dev/`; `CLI/apkrun/Tests/apkrunTests.swift`; `CLI/apkrun/Tests/Golden/help.txt`; `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevLinux.swift`; `Tests/Fixtures/linux/init`; [cli.md](../02-design/cli.md) §5; [vm.md](../02-design/vm.md) §12; [M00](issues/M00-repository-and-vm-foundation.md) #004 |

**Choice.** Make `--tests flood` request 10,000,000 guest lines by default and add `--flood-lines` for an explicit count from 1 through 10,000,000. Reject `--flood-lines` unless `flood` is in `--tests`. After printing the requested lines, the guest reports `APKRUN-TEST: flood ok` so a completed CLI run satisfies its normal check contract.

**Reason.** The guest fixture requires `apkrun.test.flood=<n>` to emit output; requesting only `--tests flood` previously passed no count and produced a failure instead of a flood. A success record also lets the test run finish cleanly if the caller does not terminate it early. The option makes the planned `kill -9` durability check reproducible from `apkrun-dev dev linux`, while the finite limit bounds the requested test workload.

**Verification.** `apkrunTests` passed all 19 tests on 2026-10-06 UTC, including default and explicit flood counts, invalid option use, count bounds, and the development CLI help golden. Signed `LinuxGuestConsoleTests` passed 5/5 on arm64 macOS 27.0 (26A428); the final xcresult is local at `/tmp/apkrun-console-signed-T2-batchbound.xcresult`. The guest initramfs was rebuilt from pinned, hash-verified inputs. The final manual SIGKILL run terminated the CLI 50 ms after flood line 100; stdout received 1,025 contiguous records, while both persisted logs matched at 1,024 complete contiguous records, with the last persisted timestamp within 1 ms of termination. The interactive guest echo and Ctrl-] exit check also passed.

## IR-201: Bound console log batching after measuring flood lag

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #004 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Console/ConsoleLogWriter.swift`; `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/ConsoleLogWriterTests.swift`; `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTestSupport/FakeConsoleLogFileSystem.swift`; [vm.md](../02-design/vm.md) §6.4; [M00](issues/M00-repository-and-vm-foundation.md) #004 |

**Choice.** Cache the UTC prefix formatter, scan appended console bytes linearly with a cursor across incomplete records, and write complete prefixed records in batches bounded by 64 KiB of guest data and the next rotation boundary. Keep per-record timestamps and rotation semantics. Count guest bytes as unconfirmed if either required destination fails to accept them, and retain bytes pending from a failed `fsync` until a later synchronization of both destinations succeeds.

**Reason.** The first CRLF-aware flood run showed the log writer could not keep up: when the monitor terminated the guest 50 ms after line 100, stdout held 845 flood records while the per-boot log held 191. Repeated front-removal from `Data`, formatter construction for every record, per-record file writes, and rescanning an incomplete record on each append were avoidable writer costs. The bounded batching path reduced those costs while preserving private per-boot/current logs, record order, rotation boundaries, and durability accounting. This is a measured optimization; the bounded batch limit avoids an unbounded memory queue.

**Verification.** On 2026-10-06 UTC, the writer tests passed 9/9, including a near-limit record followed by a maximum-length record that forces a batch flush before the combined guest bytes exceed 64 KiB, two writes for a 500-record burst across both destinations, a 65,535-byte record delivered in 256-byte chunks, deterministic retained records across rotation, and targeted one-destination write/fsync failures with recovery. `VirtualMachineCoreTests` passed 84/84 and `VirtualMachineCoreSystemTests` passed 18/18. The signed T2 suite passed 5/5; its final result bundle is `/tmp/apkrun-console-signed-T2-batchbound.xcresult`. In the final SIGKILL run, the CLI had received 1,025 contiguous flood records and the current and per-boot logs contained the same 1,024 complete contiguous records, through line 1,024. Their last timestamp, rounded to milliseconds, was within 1 ms of termination. The six repository checks, standalone format check, fixture shell syntax, and diff check passed. Final hostile review found no actionable issues in the batching boundary, cursor, rotation, dropped-byte accounting, flood CLI, CRLF, or panic changes.

## IR-202: Preserve warning severity in unified logs without a message marker

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | `Packages/DiagnosticsCore/Sources/DiagnosticsCore/Logging/`; `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/`; [diagnostics.md](../02-design/diagnostics.md) §3.2 |

**Choice.** Write warning entries with OSLog's `default` type under the reserved `.__apkrun_warning` category suffix. `apkrun logs` removes that suffix and restores the warning level. Apply a requested minimum level to normalized records from both OSLog and file mirrors; keep missing or unrecognized OSLog types as `unknown` and omit them when a minimum level is requested.

**Reason.** Unified logging has no distinct warning type. Encoding severity in the message can misclassify retained legacy records or arbitrary user-controlled text. The category is set by the logger, so message contents cannot manufacture the warning signal. Filtering only debug specially did not implement the documented minimum-level contract.

**Verification.** `DiagnosticsCoreTests` passed 85/85 on 2026-10-06 UTC, including OSLog category restoration, warning threshold behavior, message-text spoof resistance, unknown-type filtering, and mirror filtering. Hostile re-review found no actionable issues.

## IR-203: Test NAT disconnect handling at T0 and live networking at T2

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | [M00](issues/M00-repository-and-vm-foundation.md) #006; [test-strategy.md](test-strategy.md) §6.1; [vm.md](../02-design/vm.md) §7 |

**Choice.** Verify disconnect state, warning log, degraded health, and reset with the fake driver at T0. The real-VM T2 network test verifies DHCP, the host HTTP 204 request, and passing `vm.network` health throughout the run.

**Reason.** Virtualization.framework provides no reliable supported trigger for intentionally disconnecting a NAT attachment. A T2 assertion that the callback fired would depend on an unavailable trigger. The tier split directly verifies the callback contract with its controllable driver and verifies real guest networking with VZ.

**Verification.** On 2026-10-06 UTC, the focused T0 disconnect-controller and network-health tests passed with fake drivers. Signed `LinuxGuestNetworkTests` passed 3/3 on arm64 macOS 27.0 (26A428), verifying DHCP, the host HTTP 204 request, lease logging, and passing `vm.network` health.

## IR-204: Publish network health source changes for live diagnostics

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/VMController.swift`; `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Health/VMNetworkHealthState.swift`; [vm.md](../02-design/vm.md) §7 |

**Choice.** `VMController` exposes `networkHealthUpdates` with an initial available state, a sanitized disconnect event containing only the VZ domain and code, and an available event when a later start clears the failure. The live diagnostics service consumes these changes to re-run `vm.network` and publish `healthChanged` under #059.

**Reason.** A health check that only reads controller state when a report is requested can leave a subscribed UI stale after a disconnect. RuntimeAPI and DiagnosticsService are placeholders at M0, so #006 provides the VM-owned source-change stream while #059 owns subscription and wire publication. The event omits `VZErrorInfo.description`, which is private diagnostic data.

**Verification.** On 2026-10-06 UTC, `VirtualMachineCoreTests` passed 87/87. The focused `vmControllerKeepsRunningWhenNetworkAttachmentDisconnects` test observed the initial, disconnect, and recovery events alongside the running-state and warning-log assertions; `vmNetworkHealthWarnsOnDisconnectAndResetsAfterRestart` passed the degraded and recovery health assertions. Hostile re-review found no actionable issues.

## IR-205: Pin the guest HTTPS probe client and runtime libraries

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | `ThirdParty/ThirdParty.lock.json`; `ThirdParty/licenses/alpine-ssl-client/`; `scripts/fetch-test-linux.sh`; `scripts/build-test-initramfs.sh`; [build-system.md](../05-development/build-system.md) §6.5; [legal-and-licensing.md](../05-development/legal-and-licensing.md) |

**Choice.** Use Alpine v3.24's pinned `ssl_client` package and its OpenSSL libraries for BusyBox `wget` in the Linux test guest. Record the package URL, version, hash, and GPL-2.0-only license, and include its license text. The binaries ship only in the test initramfs, not the APKRun product.

**Reason.** The #006 nightly probe must exercise an HTTPS request from the guest. Pinning the distribution's matching TLS helper and libraries keeps that check within the existing guest toolchain and avoids an untracked host-side substitute. BusyBox `wget` does not validate server certificates in this fixture; the check measures DNS and network reachability only, as specified by #006.

**Verification.** The repository lock check passed, and the initramfs builder verified `ssl_client`, `libcrypto.so.3`, and `libssl.so.3` in the generated guest. Signed run `apkrun-network-t3-20261006-a.xcresult` on arm64 macOS 27.0 (26A428) returned `ext=204`. Final run `apkrun-network-t3-20261006-g.xcresult` had 2 passed, 0 failed, and 1 `external` skip after `wget: download timed out` repeated on both attempts.

## IR-206: Classify only unavailable external responses as external

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | `Tests/AcceptanceTests/Network/LinuxGuestNetworkAcceptanceTests.swift`; `Tests/Fixtures/linux/init`; `Tests/Fixtures/linux/network-errors.sh`; `scripts/tests/test_network_error_classification.sh`; [M00](issues/M00-repository-and-vm-foundation.md) #006; [test-strategy.md](test-strategy.md) §2.7, §3.9; [build-system.md](../05-development/build-system.md) §15 |

**Choice.** Capture at most 4 KiB plus one sentinel byte from external `wget` output, then append a non-newline pipeline-status marker so command substitution preserves a trailing newline. Any output over 4 KiB fails and cannot be classified as `external`. Retry one DNS failure, a line matching BusyBox `wget`'s `can't connect to remote host` socket-connect diagnostic, or its exact `download timed out` diagnostic when it produced no HTTP response or TLS/client diagnostic, while keeping the host-local endpoint available. Keep socket-connect and download-timeout failures as distinct details so only the same classified failure kind on the retry is skipped as `external`. Treat TLS/client diagnostics, boot, DHCP, host HTTP, unexpected HTTP status, malformed response, guest client failure after HTTP 204, and teardown failures as test failures.

**Reason.** Nightly lab egress can fail independently of the VM, but BusyBox `wget` and `ssl_client` report failures through the same output stream. The exact timeout or socket-connect line is eligible only when there is no accompanying TLS/client diagnostic; a TLS/client stall therefore remains a failure. Capturing one sentinel byte beyond the 4 KiB limit detects truncation even if the prefix looks like an external error, so truncated output fails instead of retaining unbounded data or masking later diagnostics. Separate guest details ensure a socket-connect failure followed by a download timeout is not mistaken for the same repeated failure. Classifying a repeated no-response download timeout as external availability is an explicit policy judgment that needs maintainer review.

**Verification.** The local shell test exercises raw BusyBox-style connection-timeout, no-route, and download-timeout output; it rejects TLS/client diagnostics when accompanied by a timeout, prefixed lookalikes, a TLS error beyond a captured 4 KiB prefix, and the boundary case where byte 4097 is a newline. Acceptance-test assertions cover DNS, recognized socket errors, distinct and repeated timeout details, cross-kind retry mismatches, TLS/client errors, HTTP errors, missing status, post-204 client failures, and teardown failure. Final signed T3 run `apkrun-network-t3-20261006-g.xcresult` passed the two classifier/retry cases; the live external case correctly skipped after the identical download-timeout failure on both attempts. The earlier signed run `apkrun-network-t3-20261006-a.xcresult` returned `ext=204`. Hostile re-review found no actionable findings.

## IR-207: Bind the network test endpoint on a bounded ephemeral listener

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | `Tests/IntegrationTests/LinuxGuestTests/LinuxGuestHTTPServer.swift`; `Tests/IntegrationTests/LinuxGuestTests/NetworkTests.swift`; [vm.md](../02-design/vm.md) §§7, 15; [M00](issues/M00-repository-and-vm-foundation.md) #006 |

**Choice.** Bind the test server to an ephemeral port on all IPv4 interfaces, accept only `GET /generate_204` for the 204 response, cap complete request headers (including the `\r\n\r\n` terminator) at 16 KiB, close incomplete requests after 10 seconds, and cancel active connections during teardown.

**Reason.** The NAT router address and `bridge100` interface are created with the running VM, so the test must discover the guest's router through DHCP and make the endpoint reachable on whichever host interface VZ uses. Binding before the VM starts avoids depending on an interface that may not exist yet. Header and time bounds ensure a malformed or stalled guest request cannot keep the test process alive indefinitely.

**Verification.** On 2026-10-06, signed `LinuxGuestNetworkTests` passed 3/3 on arm64 macOS 27.0 (26A428), including DHCP, host HTTP 204, lease logging, and passing `vm.network` health.

## IR-208: Keep signed LinuxGuest test products outside Documents

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | [M00](issues/M00-repository-and-vm-foundation.md) #006; [vm.md](../02-design/vm.md) §17 |

**Choice.** For local signed LinuxGuest runs, put `-derivedDataPath`, Linux test artifacts, and `-resultBundlePath` under `/private/tmp`, outside the user's Documents directory.

**Reason.** When the signed `APKRunTestHost` app was launched from `build/DerivedData` under `~/Documents`, macOS TCC requested Documents-folder access from the test host and the test stalled before completing. Moving the test app bundle and outputs to `/private/tmp` avoids granting that extra folder access and keeps the guest fixture's existing path guard satisfied.

**Verification.** The interrupted run's TCC log showed a pending `SystemPolicyDocumentsFolder` request for `io.apkrun.testhost` at its DerivedData path in the repository. The signed T2 retry from `/private/tmp` passed 3/3 without a Documents-folder approval request.

## IR-209: Load AF_PACKET for the pinned Linux network guest

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | `Tests/Fixtures/linux/modules.list`; `scripts/build-test-initramfs.sh`; [vm.md](../02-design/vm.md) §12; [M00](issues/M00-repository-and-vm-foundation.md) #006 |

**Choice.** Load the pinned kernel's `af_packet` module in the test guest before running `udhcpc`.

**Reason.** The first signed T2 run reached the guest but BusyBox `udhcpc` failed at `socket(AF_PACKET, ...)` with `Address family not supported by protocol`. The pinned Alpine kernel packages `af_packet.ko` as a module, so enabling NAT alone did not provide the packet socket required by the DHCP client.

**Verification.** `modules.dep` for the locked kernel contains `kernel/net/packet/af_packet.ko.gz`. The signed T2 retry loaded it and passed the DHCP lease, host HTTP, and network-health checks.

## IR-210: Bring up the Linux test guest interface before DHCP

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #006 |
| Affected files | `Tests/Fixtures/linux/init`; [vm.md](../02-design/vm.md) §12; [M00](issues/M00-repository-and-vm-foundation.md) #006 |

**Choice.** Run BusyBox `ifconfig eth0 up` before starting `udhcpc`.

**Reason.** The T2 console showed that the packet socket was now available, but DHCP reported `sendto: Network is down`. The test guest owns bringing its discovered virtio network interface up before requesting a lease.

**Verification.** The signed T2 run with `eth0` brought up obtained a DHCP lease and passed the host HTTP 204 check.

## IR-211: Bound vsock input and report lifecycle interruption distinctly

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Vsock/VsockConnection.swift`; `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/VMController.swift`; `Packages/VirtualMachineCore/Sources/VirtualMachineCore/State/VMFailure.swift`; [vm.md](../02-design/vm.md) §8; [M00](issues/M00-repository-and-vm-foundation.md) #007 |

**Choice.** Read vsock input with 64 KiB `DispatchIO` operations and cap unread buffered input at 1 MiB. A VM lifecycle operation cancels pending connects with the target state that made the connection unavailable. Report a VZ device missing from an enabled VM as `vsockDeviceUnavailable`, separately from `vsockDeviceNotConfigured`.

**Reason.** A background reader must continue after returning a partial read so it can observe peer EOF while additional bytes remain buffered. The fixed cap prevents a guest from making the host retain unbounded input when the client stops reading. `VMController` can be re-entered while a VZ operation or console drain is pending, so the state that interrupted a connect must be captured before the state transition finishes. The error catalog describes a disabled definition separately from an enabled definition whose VZ driver does not expose a socket device.

**Verification.** On 2026-10-06, the 102 `VirtualMachineCoreTests` and 23 `VirtualMachineCoreSystemTests` passed. The signed T2 suite also passed 5/5; the observed unused-port VZ error domain and code are recorded in [vm.md](../02-design/vm.md) §8.

## IR-212: Preserve vsock read order and cancellation ownership

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Vsock/VsockConnection.swift`; `Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/VsockConnectionSystemTests.swift`; [vm.md](../02-design/vm.md) §8 |

**Choice.** DispatchIO read callbacks yield events into one ordered `AsyncStream` consumer. Set the channel's low-water limit to one byte. `read(upTo:)` checks cancellation before returning already-buffered bytes. For a pending read, cancellation and data delivery are arbitrated by a lock-protected state token before buffered bytes are consumed.

**Reason.** Creating independent tasks from DispatchIO callbacks can reorder data and EOF. The default low-water threshold can also delay a small read on a stream socket. Cancellation must become visible synchronously in the cancellation handler; otherwise an already queued read event can consume bytes before an actor task removes the cancelled continuation.

**Verification.** On 2026-10-06, all 23 `VirtualMachineCoreSystemTests` passed, covering 1 MiB multi-chunk reads, prompt small reads, peer EOF with unread data and at the full-buffer limit, overflow rejection without buffering beyond 1 MiB, cancellation after a registration handshake, and cancellation before reading already-buffered bytes.

## IR-213: Bound retries while the guest vsock listener starts

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift`; [vm.md](../02-design/vm.md) §8 |

**Choice.** The T2 host retries `.vsockPortNotListening`, per-attempt `.vsockConnectTimedOut`, and `NSPOSIXErrorDomain/ECONNRESET` failures for up to five seconds. Each connect attempt is capped at 500 ms, with the existing exponential backoff starting at 100 ms.

**Reason.** The harness invokes its host action as soon as `VMController.start()` returns, before the guest init script has started `socat`. Initial signed T2 attempts returned `ECONNRESET` within 140–510 ms of VM start for both listener ports, before the guest readiness record was available. The probe therefore retries this observed startup failure alongside refused and timed-out attempts, while preserving the same bounded five-second deadline.

**Verification.** On 2026-10-06, the signed LinuxGuest T2 suite passed 5/5. Startup `ECONNRESET` failures on ports 7000 and 7001 recovered on retry, within the five-second bound.

## IR-214: Decide guest-close success before timeout cleanup

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift` |

**Choice.** The disconnect test records which task-group result wins the one-second race, then closes the connection only after a timeout has already been selected.

**Reason.** Closing from the timeout task can make `connection.closed` complete and race the task group, incorrectly reporting a local cleanup close as a guest disconnect.

**Verification.** On 2026-10-06, signed `testVsockGuestClosureCompletesClosedWithinOneSecond` passed on arm64 macOS 27.0 (26A428).

## IR-215: Remediate an unconfigured vsock device at its source

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Packages/DiagnosticsCore/ErrorCatalog/errors.json`; [error-catalog.md](../03-reference/error-catalog.md) §5.1 |

**Choice.** `vm.vsockDeviceNotConfigured` tells the caller to enable vsock in the VM definition and uses the troubleshooting action instead of telling the user to restart the same VM.

**Reason.** Restarting a VM created from the unchanged definition cannot add a disabled device. The error is raised because a caller requested host communication without enabling vsock.

**Verification.** On 2026-10-06, `swift scripts/errorgen.swift --check` passed, along with all 86 DiagnosticsCore tests.

## IR-216: Synchronize the pending-read regression test

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Vsock/VsockConnection.swift`; `Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/VsockConnectionSystemTests.swift` |

**Choice.** The socketpair test constructor accepts a callback that signals after a read continuation is registered. Production connections use a no-op callback.

**Reason.** A timed sleep cannot prove that a test task has reached the pending-read state before cancellation. The signal makes the cancellation-vs-delivery regression deterministic without exposing the actor's private state in the public API.

**Verification.** The T1 cancellation test waits for the registration signal, cancels the read, immediately sends peer bytes, then verifies cancellation and that a following read receives the bytes.

## IR-217: Close live vsock connections before releasing a stopped VM
| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift`; [vm.md](../02-design/vm.md) §8–§9 |

**Choice.** Keep a real host-to-guest connection open after a successful echo, then require it to signal closure within one second after `LinuxGuestHarness` force-stops the VM.

**Reason.** Unit tests can check the controller's bookkeeping, but only a T2 connection exercises the Virtualization.framework-owned file descriptor and confirms `VMController.stop()` closes the connection before releasing VM resources.

**Verification.** On 2026-10-06, the signed T2 stop test passed on arm64 macOS 27.0 (26A428); the connection echoed data while live and `closed` completed after the VM stopped.

## IR-218: Record the limit on direct CID assertions
| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | [vm.md](../02-design/vm.md) §8; `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift` |

**Choice.** Keep the documented guest CID 3 and host CID 2 as Virtualization.framework defaults; do not add a T2 assertion that queries those values from the host.

**Reason.** The framework does not expose a host API to query or set the guest CID. A host-to-guest connection is exercised directly by the T2 echo tests; the guest can inspect its own CID, but that does not independently prove the host CID. [Apple's Virtualization.framework discussion](https://developer.apple.com/forums/thread/772288?answerId=820780022) confirms the default guest CID 3 and host CID 2, and that the host has no guest-CID query API.

**Verification.** T2 host-to-guest connections provide a functional check. A direct numeric host-side assertion remains unavailable through the supported framework API.

## IR-219: Preserve the observed unused-port error mapping
| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Controller/VMController.swift`; `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift`; [vm.md](../02-design/vm.md) §8 |

**Choice.** Map only `NSPOSIXErrorDomain/ECONNREFUSED` to `.vsockPortNotListening`. On the reference macOS 27.0 host, require `NSPOSIXErrorDomain/ECONNRESET` for the unused port and keep it as `.vsockConnectFailed` with its underlying error. Other supported macOS versions may return `.vsockPortNotListening`, `.vsockConnectTimedOut`, or a different `.vsockConnectFailed`; the T2 attachment records the returned type and VZ error details.

**Reason.** The T2 probe to unused guest port 7999 returned code 54 (`ECONNRESET`) immediately. Treating it as refused would silently broaden the designed error mapping and discard the distinction between VZ's actual error and `ECONNREFUSED`. Pinning the assertion on the reference macOS 27.0 release keeps the observed mapping regression-tested while allowing later supported releases to surface their own documented timeout/refusal behavior.

**Verification.** On 2026-10-06, signed `testVsockUnusedPortReturnsTypedFailureWithinDeadline` passed within its two-second bound. The result attachment records `vsockConnectFailed port=7999 domain=NSPOSIXErrorDomain code=54`.

## IR-220: Use a dedicated guest port for disconnect validation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Tests/Fixtures/linux/init`; `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift` |

**Choice.** Run the guest-close probe on port 7001, separate from the echo service on port 7000.

**Reason.** The echo service must remain available for the 1 MiB transfer. The disconnect case needs the guest to read a fixed prefix and then close predictably, so an independent `socat` listener using `head -c 16` makes the expected EOF observable without changing the echo service.

**Verification.** The signed T2 disconnect test sent 32 bytes, read the 16-byte prefix, and observed `closed` within one second.

## IR-221: Probe peer EOF at the unread-buffer limit

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Packages/VirtualMachineCore/Sources/VirtualMachineCore/Vsock/VsockConnection.swift`; `Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/VsockConnectionSystemTests.swift`; [vm.md](../02-design/vm.md) §8 |

**Choice.** When the 1 MiB unread buffer is full, issue a one-byte read probe. If it receives another byte, close the connection and report `bufferedInputLimitExceeded` after buffered data is drained.

**Reason.** Stopping reads at the buffer cap also stops EOF detection if the peer closes while unread data fills the buffer. The one-byte probe detects EOF without growing the buffer; closing at the first over-limit byte prevents unbounded memory use and silent data loss.

**Verification.** On 2026-10-06, two socketpair T1 tests passed: one filled the buffer exactly, shut down the peer, and observed `closed` before draining the buffered bytes; the other sent one byte over the limit and observed connection closure plus `bufferedInputLimitExceeded`.

## IR-222: Verify listener readiness through host connections

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Tests/Fixtures/linux/init`; `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift`; [M00](issues/M00-repository-and-vm-foundation.md) #007 |

**Choice.** Keep the guest's readiness record and make its T2 test connect to both listener ports before it passes. Initiate probe closes and leave resource cleanup to the harness's VM stop.

**Reason.** The init script's process-existence checks only prove that `socat` started; they do not prove that the guest is accepting connections. Host-side connections exercise the actual Virtualization.framework path and avoid adding a separate in-guest probe whose tools and host CID assumptions would need independent validation. Awaiting connection closure can block harness cleanup if the framework stalls, so the probe starts closing and lets the controller close any remaining connection during VM stop.

**Verification.** On 2026-10-06, the signed `testVsockGuestServicesReportReady` passed on arm64 macOS 27.0 (26A428) after the host connected to both guest ports.

## IR-223: Make the vsock close deadline nonblocking

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #007 |
| Affected files | `Tests/IntegrationTests/LinuxGuestTests/VsockTests.swift` |

**Choice.** Race the close signal against a timer with a lock-protected one-shot continuation. If the timer wins, initiate `close()` and return without joining the task that awaits the non-cancellable `closed` signal.

**Reason.** A structured task group waits for every child before leaving scope. Cancelling a child that awaits `connection.closed.value` does not cancel that wait, so a timeout can still hang the test and prevent `LinuxGuestHarness` from stopping the VM.

**Verification.** On 2026-10-06, the signed LinuxGuest vsock suite passed 5/5 on arm64 macOS 27.0 (26A428), including guest disconnect and VM-stop closure checks using the nonblocking deadline helper.

## IR-224: Check for the first crosvm crash core

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/target-20261004T180433-1573318/crosvm-crash-summary.txt`; [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §3.3 |

**Choice.** Do not derive `crosvm+0x…` offsets unless a core attributable to PID 1573779 is available. Record the missing evidence and do not substitute a core from another process.

**Reason.** The supplied diagnostic recommends collecting PCs from the existing core. IR-170 records that the original Apport report and embedded core were retained on Lima at the time of that capture. A later read-only check from a non-root Lima shell found no crosvm-named report among the six visible files in `/var/crash`; `/var/lib/systemd/coredump` was empty, and `coredumpctl` was unavailable. The saved Apport metadata in `/home/lima.guest/.apkrun-apport-analysis/preloaded-retry-20261004`, `start-override-20261004`, and `traced-wrapper-retry-20261004` identifies crosvm PIDs 1618196 (SIGSEGV), 1620954 (SIGABRT), and 1619678 (SIGSEGV), respectively. Those records belong to different processes and cannot establish PID 1573779's executable path or code offsets. This does not establish that the original report or core never existed or was deleted. The IR-170 summary marks PID 1573779's stripped caller frames unknown and records no offsets. IR-171's separate 1617589 capture records offsets for its own process; those offsets do not identify PID 1573779's callers. The later preload run recovered its own panic text without matching symbols; that does not identify the first crash's missing callers.

**Verification.** The non-root Lima shell could enumerate `/var/crash` and `/var/lib/systemd/coredump`; it found six visible `.crash` files, none for crosvm, and no files in the systemd coredump directory. `coredumpctl` was not installed. The analysis directories named above contain `ProcStatus` and `SignalName` metadata for the later crosvm processes; their `CoreDump` payloads were not read. A matching-name search for `.crash`, `.core`, `core.*`, `*coredump*`, and `*1573779*` under `/tmp` and `/var` was attempted but returned permission errors for protected subdirectories, so that search was incomplete. No core file was copied or modified, and no VM boot or ADB command was issued for this check.

## IR-225: Summarize Cuttlefish ADB connector logs

| Field | Value |
|---|---|
| Status | Needs maintainer review; startup trigger superseded by IR-233 |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; `Images/tools/tests/test_reference_capture.py`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Parse only four fixed `adb_connector` message classes from complete launcher-log lines, retain aggregate counts, and emit one summary when the observer shuts down. Start ADB polling only after a complete, source-qualified `socket_vsock_proxy` line records launcher event 5.

The event-5-only startup trigger above is historical and is superseded by
IR-233. The passive connector summary and its privacy findings remain current.

**Reason.** IR-072 intentionally delayed active ADB observation until event 5 because that event identifies Cuttlefish's ADB proxy for this instance. Requiring a complete line tagged by `socket_vsock_proxy` prevents unrelated or partial text from opening the ADB observer. The recent target capture has many connector attempts but no event 5. The passive summary extracts Cuttlefish's own connection-attempt, message-sent, device-not-found, and disconnect counts without opening any host connection or exposing a foreign ADB listener. The field `connectMessagesSent` records Cuttlefish's log wording and is not a transport-readiness signal; the classifier requires a single serial token followed by the exact `successfully sent` suffix. Launcher lines are capped at 64 KiB, and an overlong line is discarded through its newline even when it spans reads. A missing, inaccessible, non-regular, or over-cap log resets counts and process identities and marks a gap. The output contains no connector PID, device serial, address, or raw log line. Launcher snapshot gaps and a partial line at shutdown remain explicit.

**Verification.** The observer test module passed 172 tests with one Linux-only skip; the full image-tools suite passed 577 tests with four platform-specific skips. Ruff lint and formatting checks and `git diff --check` passed. The focused regression tests cover source-qualified and complete event-5 lines, negated send text, oversized complete and split lines, capped logs, and disappearance after observation. A parser-only run over the retained `target-20261005T082217-1740702/launcher.log` emitted 160 `connectAttempts`, 160 `connectMessagesSent`, 159 `deviceNotFoundResponses`, and 159 `disconnectRequests`; it recorded `launcherLogObserved=true`, `launcherLogGapDetected=false`, `partialLauncherLineAtStop=false`, and `startEvent5Observed=false`. This parser-only check started no ADB process and did not boot Cuttlefish.

## IR-226: Require sidecar build metadata when generating image manifests

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected files | `Images/tools/apkrun_image/manifest.py`; `Images/tools/tests/test_manifest.py` |

**Choice.** The manifest generator rejects an archive inventory unless a fresh inventory of its source includes non-empty branch, build ID, and target metadata from a `fetch.json` sidecar whose archive fingerprint matches the bytes. This closes the missing-sidecar and stale-local-metadata paths; it does not authenticate who created the sidecar.

**Reason.** A standalone archive and an edited `inventory.json` could otherwise produce a draft that copied local metadata without checking it against the current archive, then fail only at the later file-backed check. Requiring complete matching sidecar metadata during generation surfaces missing or stale local consistency data before writing a manifest. The sidecar remains unsigned and locally editable; see IR-230 for that trust boundary.

**Verification.** A regression test first reproduced the draft generated without sidecar metadata, then passed after the generator required complete matching metadata. The shared fixture generator test also passed.

## IR-227: Normalize JSON parser limit failures

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected files | `Images/tools/apkrun_image/manifest.py`; `Images/tools/tests/test_manifest.py` |

**Choice.** Convert Python's oversized-integer and excessive-nesting parser exceptions into concise `ManifestError` diagnostics, without echoing the rejected JSON value.

**Reason.** Those parser exceptions bypassed the CLI's typed error handling and printed tracebacks containing attacker-controlled input. Returning the same safe failure class as other malformed manifests keeps both the CLI and generator actionable.

**Verification.** CLI regression tests exercise a 5,000-digit integer and 10,000 nested arrays; both return exit code 2 with a bounded diagnostic and no traceback.

## IR-228: Bound manifest integers to ImageCore's representation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected documents | [android-image-manifest.md](../03-reference/android-image-manifest.md) §7; `Images/tools/schemas/android-image-manifest.schema.json`; Python and Swift manifest tests |

**Choice.** Cap `schemaVersion` and all manifest byte-size fields at `9223372036854775807`.

**Reason.** ImageCore decodes these values as Swift `Int` on supported 64-bit platforms. Python's arbitrary-precision integers previously let schema-only validation accept documents that Swift could not decode. The bound makes Python reject those documents while preserving the model's current type and behavior.

**Verification.** On 2026-10-06, the focused Python manifest and no-file-name suites passed 41 tests. Regression cases reject values above the cap and accept the largest valid signed-64-bit archive, artifact, and aligned partition sizes. The Swift ImageCore manifest suite passed 26 tests, including typed rejection above `Int.max` and acceptance at its valid size boundaries. Both implementations also accept integral floating-form JSON numbers such as `37.0` for integer fields.

## IR-229: Run the manifest CLI check in CI

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009 |
| Affected files | `.github/workflows/ci.yml`; `Images/tools/tests/test_manifest.py` |

**Choice.** The image CI job runs `manifest --check --no-files` for every committed `Images/manifests/*/android-image.json`, and a Python regression test exercises the same CLI path.

**Reason.** The CI job previously called the validation function only through unit tests, leaving the documented command-line check and its exit behavior untested.

**Verification.** On 2026-10-06, the committed-manifest CLI regression passed in the 41-test focused Python run. `manifest --check Images/manifests/16373615/android-image.json` also succeeded with the real archive present.

## IR-230: Define the fetch sidecar trust boundary

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #009, #064 |
| Affected documents | [android-image.md](../02-design/android-image.md) §3.1; [android-image-manifest.md](../03-reference/android-image-manifest.md) §4.2, §8; [M01](issues/M01-android-bring-up.md) #009 and #064 |

**Choice.** Treat `fetch.json` as unsigned local consistency metadata. Require its archive name, size, and SHA-256 to match the archive, and compare its build ID, target, and caller-asserted branch with inventory and manifest fields. Do not describe those checks as cryptographic authentication or proof that the `fetch` command wrote the sidecar.

**Reason.** The inventory and manifest checks catch missing metadata and inconsistent local edits, while a locally fabricated sidecar containing the correct archive fingerprint and asserted build fields is indistinguishable from a sidecar written by `fetch`. The plan does not specify signed provenance or a signing-key lifecycle. Adding an attestation system would expand the design and create a new trust dependency. Preserve the documented local workflow and make the limitation visible for maintainer review; keep source-derived manifest values under the existing human review in IR-062.

**Verification.** Documentation now distinguishes archive-byte consistency from source-origin authentication in the design, reference, and task documents. No code path or source metadata format changed for this clarification. The sidecar remains editable by a local user; the current checks do not establish who created it.

## IR-231: Check installed crosvm unwinder symbols

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [environment setup](../05-development/environment-setup.md) §3.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Record the installed package path, ELF identities, dependencies, exported symbols, and saved Apport executable metadata as read-only evidence. Do not infer the earlier SIGSEGV's caller offsets or root cause from other processes, and do not repeat a VM boot for this check.

**Reason.** The supplied diagnostic identified a possible collision between libgcc's backtrace context and LLVM unwinder entry points exported by gfxstream. Checking the installed package and saved Apport metadata tests whether the involved binaries and symbols are present without requiring matching debug symbols or another guest run. The loader checks in IR-187 were performed in separate `crosvm --help` processes, so these observations do not establish the actual symbol binding in PID 1573779 or prove the secondary-crash hypothesis.

**Verification.** On the arm64 Lima host, `readelf -n` reported crosvm Build ID `d724bf54f045b0ec7dbe14049b0fed9a16e52a23` and gfxstream Build ID `6b8f3105442da5c66988881a1fa76e812b13c3e8`. `readelf --dyn-syms -W` showed gfxstream exports for `unw_get_reg` and `_Unwind_GetIP`; `readelf -d` showed crosvm dependencies on both `libgfxstream_backend.so` and `libgcc_s.so.1`. Three saved retry Apport metadata records for PIDs 1618196, 1620954, and 1619678 identify `/usr/lib/cuttlefish-common/bin/crosvm` and package `cuttlefish-base 1.57.0 [origin: android-cuttlefish]`. Those are not the first-crash PID 1573779. No core was opened or modified and no VM boot was run.

## IR-232: Normalize fetch sidecar JSON parser limits

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #008 |
| Affected files | `Images/tools/apkrun_image/{fetch.py,inventory.py}`; `Images/tools/tests/{test_fetch.py,test_inventory.py}`; [M01](issues/M01-android-bring-up.md) #008 |

**Choice.** Convert JSON integer-digit and nesting-limit exceptions while reading `fetch.json` into fixed `FetchError` or `InventoryError` diagnostics. Do not include rejected JSON values in the messages.

**Reason.** `fetch.json` is editable local input read by both commands. Python can raise `ValueError` for an oversized integer token and `RecursionError` for excessive nesting; neither CLI handled these exceptions, so they escaped the typed error path with a traceback. Normalize both in the same way as manifest parser limits.

**Verification.** The `fetch` CLI regression cases supply a 5,000-digit integer and 10,000 nested arrays in `fetch.json`; the inventory CLI has matching cases. Each command returns its documented error code with a bounded diagnostic, no traceback, and no echoed integer. The focused `test_fetch.py` and `test_inventory.py` suites passed 86 tests, and the full image-tools suite passed 594 tests with four platform skips.

## IR-233: Observe ADB before Cuttlefish event 5

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/tools/reference/boot_observer.py`; `Images/tools/tests/test_boot_observer.py`; [android-image.md](../02-design/android-image.md) §8.3; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Start the private ADB observer after either the first complete,
source-qualified `adb_connector` connection-attempt line or the complete
`socket_vsock_proxy` event-5 line. Use a 60-second interval before event 5.
Outside the final-probe reservation, event 5 wakes the existing thread for an
immediate poll and changes subsequent regular polls to 15 seconds. Keep the
final-probe reservation: regular polls, shell checks, and property queries
remain paused in that window while the observer performs its bounded final
state and logcat probe.

**Reason.** The latest target captures contain connector attempts without
event 5, leaving the observer unable to tell whether Cuttlefish's selected
loopback ADB endpoint ever reaches `device`. A complete connector attempt is
the earliest source-qualified evidence of the intended endpoint. The
60-second pre-event interval bounds extra local probes, and event 5 retains
its separate meaning while making later observation more frequent. Only an
ADB `device` state permits shell diagnostics; none of these observations
establishes Android boot completion. The reserved final window protects the
capture deadline and final logcat collection. The event wake is not cleared
from inside an in-flight SystemServer snapshot, so a newly observed event
cannot be lost there.

**Verification.** `test_boot_observer.py` passed 175 tests with one
Linux-only skip. `ruff check Images/tools`, `ruff format --check Images/tools`,
and `git diff --check` passed. The targeted synthetic capture case
`staged-invalid-config-invalidates-capture` passed. An initial full
image-tools run reported 588 passed, 6 failed, 3 errors, and 4 skipped because
the host ran out of temporary storage. Five real-archive checks stopped before
snapshotting because the 1,101,175,103-byte archive requires 1,369,610,559
bytes of free temporary space including the reserve, while only 890,961,920
bytes were available; the other failure and three setup errors also reported
`No space left on device`. After host space recovered, the full
`Images/tools/tests` suite passed 597 tests with four platform-specific skips
in 314.31 seconds. The skips require Linux parent-death signals or GNU
`timeout`. Ruff lint and formatting checks and `git diff --check` passed, and
the hostile review found no remaining actionable findings. No T2 guest
verification or new reference capture was possible because Lima's guest SSH
remained unavailable after a graceful VM restart.

## IR-234: Gate the reference-derived image layout on the target capture

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #010 |
| Affected files | [issues index](issues/README.md); [roadmap.md](roadmap.md) §1.3; [M01](issues/M01-android-bring-up.md) #010 and #013; [android-image.md](../02-design/android-image.md) §§6.2, 16; `Images/tools/tests/test_extract.py` |

**Choice.** Make #064 an explicit dependency for completing #010. #064
captures the Cuttlefish reference values, #010 copies them into the initial
layer-2 layout, and #013 compares a live VZ boot with that reference. If
evidence shows direct boot needs a different layer-2 value, #013 may update
the VZ layout to the observed value and records the key and reason in
`expected-differences.yaml`; the original remains in the #064 capture. Add a
real-archive regression check that computes the five AVB values, merges them
with the extracted vendor bootconfig and committed image layer, and enforces
the 16 KiB build limit.

**Reason.** M1's task order already places #064 before #010, and #010's final
layout step requires its `target` capture, but the task index omitted that
dependency. The design text also said the values would be filled in during
#013, conflating reference collection with VZ validation. Making the two
roles explicit prevents guessed values and keeps the task gate consistent
with its acceptance criteria. A VZ adjustment must be supported by a live
observation and retain the original reference in #064. AVB-computed values
are part of layer 2, so the regression test includes them instead of checking
only the layout's literal keys. The existing serialization API enforces the
size limit.

**Verification.** `Images/tools/tests/test_extract.py` passed all 19 tests.
The complete `Images/tools/tests` suite passed 597 tests with four
platform-specific skips in 301.48 seconds. Ruff lint, formatting checks, and
`git diff --check` passed. No T2 guest check or new reference capture was
possible because Lima guest SSH remained unavailable after the graceful VM
restart.

## IR-235: Avoid timestamp-sensitive PID substring assertion

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064; `Images/tools/tests/test_boot_observer.py` |

**Choice.** Remove the assertion that scans the entire observer JSONL output
for the substring `593`. Keep the focused checks that reject PID 593 from
shell-probe output and reject unexpected or PID fields in parsed diagnostics.

**Reason.** A full-suite run failed because the substring also appeared in a
JSONL event timestamp ending in `.593`; the assertion was unrelated to whether
the PID had leaked. The dedicated allowlist and parser tests check the
intended privacy behavior against the actual PID field and diagnostic output,
without interpreting timestamps or unrelated serialized data as a PID.

**Verification.** The focused parameterized case passed. The complete
`Images/tools/tests` suite passed 597 tests with four platform-specific skips
in 301.48 seconds. Ruff lint, formatting checks, and `git diff --check` passed.
Hostile review found no remaining issue with the code change; the
documentation reference mismatch it identified is corrected in
`android-image.md` §16.

## IR-236: Restore disk headroom and diagnose Lima networking after reported VPN disconnect

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064; [environment setup](../05-development/environment-setup.md) §2 |

**Choice.** Following the user's report that the VPN was disconnected, retry
the existing Lima VM with an additional per-instance `vzNAT` network and
retain that setting for further diagnosis. Do not manually add or delete host
routes. The prescribed `df -g` check reported 148 GiB free, below the 150 GiB
developer-host minimum. After `lsof +D ThirdParty/out/work` reported no open
files, remove that 70 GiB generated work cache while preserving `src`,
`patched-src`, and `virgl-runtime`.

**Reason.** Lima continued waiting for SSH at `192.168.5.15:22`; Lima
[documents](https://lima-vm.io/docs/config/network/user/) that default
user-mode address as intentionally inaccessible from the host.
An earlier route lookup for candidate VZ NAT address `192.168.64.2` selected
`en0`, and ordinary and source-bound TCP probes timed out. This candidate was
not confirmed as the VM's assigned address. On 2026-10-07, `scutil --nc list`
reported Tailscale as disconnected, but route lookups for `192.168.5.15`,
`192.168.64.2`, `192.168.105.2`, and `192.168.104.2` selected `utun5` through
`10.142.128.64`. The host has a VZ NAT `bridge100` interface at
`192.168.64.1/24`; a route lookup scoped to `bridge100` selects that interface,
while the ordinary lookup selects `utun5` for `192.168.64.0/24`. This is an
overlapping host route; the owner of `utun5` is not established. `arp` showed
no neighbor on `bridge100`, so the guest IP remains unknown. The `bootpd`
firewall rule permits incoming connections, but the empty serial log leaves
guest boot state unknown. A fresh TCP probe bound to `192.168.64.1` also
timed out when connecting to candidate `192.168.64.2:22`; this does not verify
that the candidate is the guest's address. Lima's
[VMNet documentation](https://lima-vm.io/docs/config/network/vmnet/)
describes VZ NAT as host-reachable without `socket_vmnet`; its `lima:shared`
alternative uses the root-managed helper.
`ThirdParty/out/work` is generated build work and can be recreated from the
pinned sources and patches. Removing only this directory restores disk
headroom while retaining the checked-out sources and published renderer
cache.

**Verification.** The earlier `limactl start` attempt did not receive its
`running` status event while `limactl list` reported the instance as running.
On the 2026-10-07 retry, VZ reported `running` and `limactl list` continued to
report `Running`, but `limactl start apkrun-cuttlefish --timeout=180s` exited
with `did not receive an event with the running status`. The hostagent kept
waiting for `192.168.5.15:22`; `serialv.log` remained empty and `arp` showed no
guest on `bridge100`. The Tailscale service remained reported as disconnected
while the global route still selected `utun5`. No Cuttlefish capture or T2
guest test ran, and no host route or product code was changed. The only Lima
instance setting changed was the additional `vzNAT` network. Removing
`ThirdParty/out/work` completed; the immediate post-cleanup `df -g` check
reported 351 GiB available, and the latest check reported 390 GiB available.
`ThirdParty/out` measures 561 MiB; pinned source, patched-source, and published
renderer directories remain. The documentation checks and
`scripts/tests/run.sh` passed.

**VPN-off follow-up (2026-10-07).** With the VPN reported disconnected, an
earlier route lookup for `192.168.5.15` selected gateway `100.64.0.1` on
`en0`; the latest lookup selected `10.253.56.1` on `en0`. The lookup for
`192.168.64.2` selected `bridge100`. `limactl restart` exited with
`did not receive an event with the running status`; `limactl list` still
reported the instance as `Running` with SSH forward `127.0.0.1:54899`.
`limactl shell apkrun-cuttlefish -- uname -a` then ended with
`kex_exchange_identification: read: Connection reset by peer`. The guest IP,
boot state, and SSH readiness remain unverified. No capture or T2 guest test
ran, and no host route was changed.

The final read-only check of `ha.stderr.log` found repeated SSH-forward
attempts through `127.0.0.1:54899` failing to dial
`192.168.5.15:22` with `no route to host`; SSH attempts ended with the same
connection reset, and the Lima guest-agent event stream closed unexpectedly.
`serialv.log` remained zero bytes. This confirms that Lima still cannot reach
the configured guest SSH endpoint, but does not distinguish a guest boot
problem from Lima's guest-network path. No route, VM setting, or guest state
was changed.

## IR-237: Bound guest reference commands and clean up before publication

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064; `Images/tools/reference/capture.sh`; `Images/tools/reference/capture_guest_command.py`; `Images/tools/reference/capture_cvd_start.py`; `Images/tools/tests/test_capture_guest_command.py`; `Images/tools/tests/test_reference_capture.py` |

**Choice.** Run each guest-side ADB capture command through a deadline-aware
helper using the capture's remaining boot deadline. Stream command output to a
temporary file, atomically publish only successful output, and enforce a
64 MiB cumulative raw guest-output budget, with a separate 64 MiB limit on
the compressed logcat artifact. Read `internal/bootconfig` only after opening
it without following symlinks, confirming it is a regular file, and checking
its size against a 64 MiB limit. Terminate the supervised process group even
when the command leader exits before its descendants.
Remove the private Cuttlefish HOME before publishing a complete profile; if
cleanup fails, retain the data as incomplete and report the HOME that remains.

**Reason.** A guest diagnostic can stall or emit unbounded data, so independent
per-command timeouts and output limits do not provide a shared capture bound.
Streaming avoids holding raw command output in memory, and atomic publication
prevents partial files from looking complete. A regular-file and size check
keeps bootconfig reads from following an unexpected path or allocating an
unbounded input. A command that closes stdout can still leave descendants
running, so process-group cleanup must also run on normal leader exit.
On macOS, a leader can exit between the non-reaping `waitid` check and
`killpg`, which can report `EPERM` for a zombie-only group. Recheck exit state
for a short, bounded interval while keeping the leader unreaped; still fail
closed if it remains alive or the group contains live descendants. Publishing
while the private HOME remains would leave runtime state behind and
misrepresent cleanup as complete.

**Verification.** The focused guest-command and Cuttlefish process-supervision
tests passed 30 cases. They include a child that closes stdout and continues
running, a normally exiting leader with a surviving descendant, cleanup
failure with hidden-temp removal, exit-state rechecking after `EPERM`, and a
bounded retry when the leader remains alive. The dedicated
`test_reference_capture.py` suite passed 56 tests with three Linux-only skips.
The final complete `Images/tools/tests` suite passed 610 tests with four
platform-specific skips. Ruff lint and formatting, `sh -n`, `git diff --check`,
and `scripts/tests/run.sh` passed. The hostile review confirmed the cleanup
fix and the bounded `EPERM` retry preserves the process-group safety
invariant. Lima SSH remains unavailable, so no live reference profile or T2
guest verification was possible.

## IR-238: Repair the Lima guest root filesystem from a preserved copy

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Preserve a byte-for-byte copy of the stopped Lima disk, attach a
separate working copy to a rescue Linux VM, unmount the affected ext4
partition, and run `fsck.ext4 -f -y` there. Promote the repaired image to the
Lima instance only after a forced read-only fsck succeeds. Keep the original
pre-repair copy and the image from the first failed boot attempt.

**Reason.** The VM screen identified the Linux root filesystem as inconsistent
and explicitly requested manual fsck. Running the repair inside a rescue Linux
guest keeps the operation on the ext4 block device, avoids accessing macOS
filesystems, and ensures fsck does not run against a mounted partition. The
separate untouched image provides a rollback point if filesystem repair or
subsequent boot validation fails.

**Verification.** Before repair, the stopped Lima disk and its preserved copy
compared byte-for-byte. The rescue VM attached the working image as `/dev/vdb`;
`/dev/vdb1` was confirmed unmounted before repair. `fsck.ext4 -f -y
/dev/vdb1` corrected the orphaned inode list and block/inode allocation
counters. A subsequent `fsck.ext4 -f -n /dev/vdb1` completed without errors.
The promoted Lima disk matched the repaired rescue image byte-for-byte.
`limactl start apkrun-cuttlefish` reached `READY`; `systemctl
is-system-running` reported `running`, and `limactl shell` successfully ran
commands including `uptime`, `command -v launch_cvd`, and `adb version`.
The Cuttlefish Android guest has not been boot-tested after this recovery;
#064 remains open.


## IR-239: Diagnose post-recovery Cuttlefish boot and guard known Virgl failure

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064; [instance-1 collision](../../Images/reference/16373615/incomplete/default-20261007T154512-2416/); [default capture](../../Images/reference/16373615/incomplete/default-20261007T160227-2967/); [SwiftShader-profile capture](../../Images/reference/16373615/incomplete/swiftshader-20261007T161446-10503/); [stock Virgl failure](../../Images/reference/16373615/incomplete/target-20261007T164344-18219/); [feature-enabled Virgl diagnostic](../../Images/reference/16373615/incomplete/target-20261007T170221-19521/); [host-logcat Virgl diagnostic](../../Images/reference/16373615/incomplete/target-20261007T193655-32887/); `Images/tools/reference/{boot_observer.py,capture.sh,capture_cvd_start.py,check_virgl_crosvm.py,compare_boot.py,normalize.yaml}`; related tests |

**Choice.** Keep the stale instance-1 registry entry for maintainer diagnosis; do
not run global `cvd reset`. Use instance 2 for post-recovery captures. Do not
repeat the stock `target` run: its crosvm Build ID matches the already diagnosed
IR-171 binary. Add a `target`/`drm_virgl` preflight that records the configured
launch command separately from the crosvm ELF expected to execute. Require the
expected ELF to have a GNU Build ID and SHA-256, refuse the exact known-bad Build
ID, rehash the expected ELF before both CVD commands, and compare each matching
running crosvm process's `/proc/<pid>/exe` identity with that hash. A launcher
wrapper is allowed when its executed crosvm ELF is identified explicitly with
`APKRUN_CROSVM_OBSERVER_EXECUTABLE`; for a direct override, that variable defaults
to `APKRUN_CROSVM_BINARY`, while the packaged crosvm is the default otherwise.
Builds other than the known-bad one may proceed for diagnosis, but are marked
uncertified in `host.json` and make the capture diagnostic-only until reviewed.
The exact known-bad Build ID is checked in both the expected ELF and an
identifiable launch ELF; an identified wrapper is otherwise allowed when its
executed crosvm ELF is configured separately. The denylist covers only the
observed full Build ID; it makes no claim about other architectures or builds.
The guard does not certify general Virgl support.

Capture the Cuttlefish instance's host-side `logcat` once after the CVD command
returns, if the selected instance exposes it. Do not copy it on every live
`cvd logs` poll because it can grow quickly. Keep the artifact bounded to 64
MiB, rename it to `host-logcat.txt`, and apply the capture's path, serial, MAC,
secret, and attestation identifier-array redactions before retaining it. Arrays
for `serial`, `imei`, `imei2`, and `meid` are replaced as a whole. If truncated,
the retained data starts at a complete log line so a multibyte UTF-8 character
is not split. An
absent or unsafe logcat is recorded as missing; if it cannot be safely
normalized, discard the artifact and keep the capture incomplete. On
interruption, remove nested `.logcat.*` snapshot temporaries before
normalization; discard the stage if cleanup fails.

When the optional boot observer finds one uniquely verified Android crosvm, it
also hashes `/proc/<pid>/exe` once per process generation and records a
path-free `crosvm_runtime_identity` event with the PID, status, SHA-256, and GNU
Build ID. It verifies the crosvm and parent restarter start times, opens the
proc executable once, and hashes through that pinned file descriptor. Before
hashing it checks the descriptor against the expected ELF and proc link; after
hashing it rechecks descriptor metadata, both process generations, and
executable identity. A transient unavailable read is retried up to three times
for the same process generation; the final path-free event records its attempt
count. Ambiguous candidates are not hashed. An unavailable or raced read is
retained with a typed status and no hash; a readable non-ELF or Build-ID-less
file retains its SHA-256 without a GNU Build ID.

**Reason.** The persisted `apkrun_target_whuuql/1` registry entry still blocks
instance 1 although the group runtime directory and Cuttlefish processes were
absent. `cvd help reset` describes a reset over all groups owned by the current
user, so it could remove unrelated runtime state. The stock `target` record
reports crosvm Build ID `d724bf54f045b0ec7dbe14049b0fed9a16e52a23`, the build for
which [IR-171](#ir-171-diagnose-crosvm-panic-output) recovered
`Failed to create virtio gpu worker thread: invalid rutabaga build parameters`
with the libgcc preload. The pinned Cuttlefish build omits Rutabaga's
`virgl_renderer` feature. In the 2026-10-07 stock record, `process_restarter`
reports its monitored child dumped (`si_code: 3`), and `run_cvd` reports the
monitored `process_restarter` exited with code 1. The code 1 belongs to
`process_restarter`, not crosvm. The feature-enabled diagnostic ELF had a
`DT_NEEDED` entry for `libvirglrenderer.so.1`, unlike the stock ELF; that
comparison applies to those tested builds only.

A separate feature-enabled diagnostic crosvm got past the host-side feature
failure. Review of its guest kernel log corrects the earlier provisional
interpretation: SurfaceFlinger, not zygote, is the first recorded failure. The
log records 17 SurfaceFlinger starts and 16 SIGABRT receipts. On the first
cycle, the audit event records `surfaceflinger` with signal 6 at uptime 170.123;
init records SurfaceFlinger's SIGABRT at 171.951, then sends SIGKILL to the
zygote process group. The `surfaceflinger` `onrestart` action runs
`restart --only-if-running zygote`; init records a second zygote SIGKILL send
and the SIGKILL receipt. Across the run there are 32 zygote SIGKILL send records
and 16 receipts. `system_server` never starts. These are init cleanup and
restart actions following SurfaceFlinger's abort, not evidence that zygote
independently crashed. At uptime 309.221, apexd logs an attempted revert because
SurfaceFlinger is crashing; at 309.315 it reports that the revert failed
because there are no active sessions.

The `default` and `swiftshader` guest-SwiftShader records each show one
SurfaceFlinger start, no SurfaceFlinger SIGABRT, and no zygote SIGKILL. The
feature-enabled `target` record negotiates guest DRM features
`+virgl +edid +resource_blob +host_visible` and discovers the `drm_hwcomposer`
APEX. A later 600-second `drm_virgl` run retained the Cuttlefish host logcat.
Across five SurfaceFlinger aborts, `libEGL` reports that it cannot load the
`mesa` driver selected by `ro.hardware.egl`; each crash summary says no OpenGL
ES implementation could be found. This identifies the immediate guest-side
abort as EGL driver loading. It agrees with [IR-185](#ir-185-verify-mesa-driver-payload-in-the-pinned-cuttlefish-image),
which found no Mesa EGL/GLES driver in the pinned image's preferred vendor or
system EGL paths. The log does not establish that the host Virgl renderer
started successfully or that Android rendered a frame.

**Verification.** The failed instance-1 capture lasted two seconds and records
the exact registry conflict. The `default` and `swiftshader` instance-2 captures
used build 16373615, Cuttlefish 1.57.0, Ubuntu 24.04.4 arm64 with nested
virtualization, ADB port 6521, and a 600-second boot deadline; their capture
durations were 602 and 603 seconds. Both selected `guest_swiftshader`, so they
do not compare different GPU backends. Their `aidl/activity` lookup failures
attributed to `audioserver` do not establish the boot stall's cause.

The stock `target` record selected `drm_virgl` and stopped after seven seconds
with an empty guest kernel log. The later diagnostic used a feature-enabled
crosvm (Build ID `1f6c03321061aa58e1d1ec0d0a1ff54f`) through its static launcher
(Build ID `faf3eaf415ce2d1fc6c90f5090a9e82ba8abccab`). ADB reported `device` on
18 of 23 polls. Four of five property probes timed out; the remaining output
could not be parsed, and the first shell-marker probe timed out. No poll
produced `sys.boot_completed`, `systemServerProcess`, or activity-service state.
No `VIRTUAL_DEVICE_BOOT_COMPLETED` or `VIRTUAL_DEVICE_BOOT_FAILED` marker
appeared. The run did not verify Android boot completion, system-server
readiness, or rendering and remains diagnostic evidence, not a reference
profile.

The first feature-enabled diagnostic, captured earlier that day, did not
retain host `logcat`. The later run at
`Images/reference/16373615/incomplete/target-20261007T193655-32887/` captured it
from the selected Cuttlefish 1.57.0 instance. This confirms the real log listing
label and instance path used by the bounded host-logcat collector. Its normalized
`host-logcat.txt` contains 11,093 lines and five `libEGL` Mesa-driver load
failures, five SurfaceFlinger SIGABRTs, and five explicit abort messages.

The same run produced 121 `crosvm_memory` events; 119 identify PID 33476 and
include RSS measurements, while two correctly report `unavailable` before the
runtime link resolves and after teardown. ADB reported `device` on 12 of 20
polls; the other eight had no device-state result. No poll parsed
`sys.boot_completed` or `system_server` state. Three property probes timed out.
The 600-second run did not complete Android boot and remains diagnostic-only.
`host.json` records the expected crosvm ELF Build ID
`1f6c03321061aa58e1d1ec0d0a1ff54f` and SHA-256
`48a9553740a947a2f6f1679692a73d022ea364d43b7e4652d7c9ab6a0ac5aaf7`; the
launcher log records verification of that staged input, and each valid observer
sample passed the `/proc/<pid>/exe` `samefile` check. The post-run
`crosvm-runtime-identity.txt` contains only its header because no crosvm remained
at artifact-collection time. The launcher-log association between its verified
hash and PID 33476 is indirect. This capture predates the new observer event, so
the event's live output still needs confirmation in a later capture.

No stock target capture was repeated. After the run, the port-5038 ADB server
and task-created Cuttlefish processes were stopped; a fleet check listed only
the pre-existing stale instance-1 entry, which remains untouched. The private
capture HOME was removed. The new capture remains under `incomplete/`, and two
normalization passes on a copy changed zero files and produced identical tree
hashes. Its host logcat contains no private host paths, MAC addresses, or
private-key markers. All six captures from this post-recovery sequence remain incomplete; no boot profile is
comparable and #064 remains open.

**Verification.** The final `Images/tools/tests` suite passed 635 tests with
four platform-specific skips: one Linux parent-death-signal check and three GNU
`timeout` checks. The focused observer, ELF-identity, and comparison suites
passed 248 tests with one Linux-only skip. Ruff lint and formatting,
`sh -n Images/tools/reference/capture.sh`, and `git diff --check` passed. Two
normalization passes on a copy changed zero files; the saved host logcat has no
remaining attestation identifier arrays, and the tested host-path, MAC-address,
and private-key scans found no matches. The live capture confirms the Cuttlefish
1.57.0 host-logcat label and path, but predates the runtime identity
instrumentation and does not verify that event. It remains incomplete: it did
not establish Android boot completion or rendered frames.

## IR-240: Plan a Mesa-enabled VirGL guest image without changing the reference pin

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064; proposed follow-up task number pending GitHub issue initialization |
| Affected files | [M01](issues/M01-android-bring-up.md) #064; [M02](issues/M02-graphics.md) #022; [M05](issues/M05-custom-android-image.md) #035; [task index](issues/README.md); [workflow](../05-development/workflow.md) |

**Choice.** Preserve build 16373615 as the #064 reference. A corrected Mesa guest
image must have its own build identity, manifest, hashes, and source/build
provenance. The suggested follow-up is a candidate M2 task after #020 and #021
and before #022; if adopted, #022 should depend on it, and #035 should reuse its
verified product fragment. This keeps the image correction separate from #064.
It does not establish a usable VirGL guest or unblock #064 by itself.

The placement is deliberate. #022's acceptance criteria require Mesa VirGL,
SurfaceFlinger, and `sys.boot_completed=1`. Putting the guest packaging work only
in M5 would make it depend on #035, which depends on #034 and is downstream of
#027, #026, and G3/#023. That creates a cycle if #022 also needs the Mesa image.
The M2 task could build a minimal reusable product fragment; #035 can add the
Guest Agent and other product services later. The M1 dependency does not block
all M2 preparation: #018 can start, and #019 and #020 can proceed before M1
closes. However, #021 depends on #014, which depends on #013 and transitively on
#064. That unresolved chain gates the proposed task placement after #021 and
before #022, as well as #022 integration; resolve the #064 acceptance question
or revise the dependency path before those tasks proceed. The builder setup is
also currently scheduled during M3; an M2 task that needs AOSP builds must move
that prerequisite earlier or choose another documented build path. Do not
assume that adding one `PRODUCT_PACKAGES` entry is sufficient: first compare
the exact pinned source and built image, then verify the module, loader path,
ABI, and dependencies.

**Task-numbering constraint.** The authenticated local `gh` checks found no
visible issues or pull requests, and the GitHub connector rejected issue
creation with HTTP 403. This looks like a repository still awaiting its initial
task-issue sequence, but the next GitHub number was not established. The
workflow requires creating #001–#097 in order in a new repository before
opening a later task or pull request. Therefore this note records the proposed
scope but does not add an unnumbered task to the canonical index or create an
issue with an unverified number. After the required issue sequence exists,
obtain the next number from GitHub, add the task to M2 and the index, add it to
FR-GFX-03 traceability, make #022 depend on it, record its reuse in #035, and
update the builder setup order if required.

If the exact source audit confirms that the needed modules are already in the
pinned AOSP Mesa source, packaging them would use the existing Mesa/VirGL
architecture of ADR-0004 without changing the reference image or graphics
protocol. If it requires a new third-party driver source or a different
renderer, pin and license it and complete the applicable ADR before
implementation.

**Reason.** IR-185 and IR-239 establish that build 16373615 selects `mesa` but
does not contain Mesa-named drivers in the inspected vendor or system EGL
directories. The feature-enabled diagnostic host reached ADB `device`, while
the guest EGL loader reported that it could not load Mesa and SurfaceFlinger
aborted. The evidence does not establish successful host VirGL initialization,
rendered frames, or boot completion. The canonical capture remains incomplete;
the separate image must not be used to mark #064 complete.

**Verification.** Reviewed the #064, #022, and #035 scopes, the task dependency
index, roadmap, workflow numbering rules, and ADR-0004. `scripts/bootstrap
--check` passed for the current Mac environment; no project source or runtime
image was changed. `gh issue list --state all` and `gh pr list --state all`
returned no visible items, so no task number could be verified. A subagent
adversarial review confirmed the M5 dependency cycle, flagged the unresolved
M1/#064 prerequisite and the builder schedule, and agreed that an ADR is not
needed only if the exact source audit confirms the existing pinned AOSP Mesa
modules are sufficient.

## IR-241: Propose a tooling-only license policy for Alpine test inputs

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected files | [M00](issues/M00-repository-and-vm-foundation.md) #003; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §§4.4, 5; `ThirdParty/ThirdParty.lock.json` (`alpine-socat`) |

**Choice.** Keep the pinned `socat` package and its committed `COPYING` and
`COPYING.OpenSSL` files. Propose `GPL-2.0-only` as the lock's conservative
policy basis, while explicitly recognizing that this is not the full Alpine
metadata expression `GPL-2.0-only WITH OpenSSL-Exception`. Add SPDX `X11` only
to the tooling allowlist for the pinned ncurses test packages. Do not change
the app or image allowlists.

**Reason.** These are downloaded `ships: tooling` inputs for the local Linux
test guest; the project policy says they are never committed, uploaded as a CI
artifact, or published. The package metadata's `OpenSSL-Exception` is not an
exception identifier in the official SPDX 3.29.0 exception list, so the
current lock schema cannot express the full metadata as an SPDX expression
without changing policy. The proposed base-only value is a policy
interpretation, not a claim that Alpine supplied no exception, that the binary
is unlinked from OpenSSL, or that `COPYING.OpenSSL` contains the socat
exception. The exception statement is in the upstream README; the committed
license files retain the package's GPL and OpenSSL/SSLeay license texts. A
maintainer must accept this narrower policy basis or require a compliant
replacement before #003 closes. `X11` is an SPDX license identifier whose
license text includes notice-retention and non-endorsement conditions;
allowing it only for pinned test tooling resolves the two ncurses entries
without changing product policy. The tooling-list change also requires
maintainer approval.

**Verification.** The pinned lock entries classify `socat`, `libncursesw`,
and `ncurses-terminfo-base` as `ships: tooling`; both `socat` license files
and both ncurses `COPYING` files are committed. The SPDX 3.29.0 license list
contains `X11`, and its exception index does not contain a general
`OpenSSL-Exception`. No APKRun runtime code or guest image behavior changes in
this decision. `scripts/check-lock.sh`, `scripts/ci/run-checks.sh` (all six
checks), and `git diff --check` passed; the format check skipped the absent
Guest Kotlin and Rust sources. The repository's `check-licenses.sh` is planned
for #093 and does not yet exist, so this lock interpretation and the tooling
allowlist are not verified by a license-specific checker.

## IR-242: Probe VZ configuration validation from the Swift test process

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002 |
| Affected files | [M00](issues/M00-repository-and-vm-foundation.md) #002; [vm.md](../02-design/vm.md) §§3, 17; [environment-setup.md](../05-development/environment-setup.md) §2.8; `Packages/VirtualMachineCore/Tests/VirtualMachineCoreSystemTests/VZConfigurationValidationSystemTests.swift` |

**Choice.** Add an opt-in T1 system test that runs only when
`APKRUN_TEST_LINUX_DIR` is nonempty. It safely resolves the artifact directory
without entering `~/Documents`, builds the same configuration as the production
validator, inspects the running process entitlement, and asserts that validation
succeeds when entitled or returns the explicit missing-entitlement failure when
unentitled. The test never creates or starts a `VZVirtualMachine`.

**Reason.** The result depends on the process hosting `swift test`; a standalone
probe outside the test runner cannot answer the #002 question. An empty
environment variable means “not configured,” matching the fetch scripts. The
opt-in requires the pinned kernel and initramfs but leaves ordinary, offline
Swift tests independent of downloaded guest artifacts. The path guard prevents
direct and symlinked Documents paths from triggering macOS file-access prompts.
Checking the localized failure reason avoids attributing every `VZErrorDomain/2`
to an entitlement problem.

**Verification.** With the pinned kernel and initramfs, the opt-in SwiftPM
system test passed on arm64 Mac17,9, macOS 27.0.1 (26A434), Xcode 27.0
(27A266a). `VZVirtualMachine.isSupported` was true, the Security entitlement
query succeeded and returned no `com.apple.security.virtualization` value, and
validation returned `VZErrorDomain/2` with an explicit missing-entitlement
failure reason. The artifact SHA-256 values and reproducible command are in
[vm.md](../02-design/vm.md) §3. No runtime code changed.

## IR-243: Classify delegate failures received during VM start

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 |
| Affected files | [vm.md](../02-design/vm.md) §§9, 17; `VMController.swift`; `VirtualMachineDriver.swift`; `VMStartupEventBuffer.swift`; `VZVirtualMachineDriver.swift`; `VMControllerTests.swift`; `VMStartupEventBufferTests.swift`; `VirtualMachineDriverTests.swift`; `FakeVirtualMachineDriver.swift`; `StartFailureProbeTests.swift` |

**Choice.** While `start()` is pending, buffer VZ delegate events on the VM
queue and return the events produced before the start completion with that
completion result. If start succeeds but the buffer contains
`didStopWithError`, transition directly from `.starting` to
`.failed(.startFailed)` using the first buffered delegate error and discard
duplicate terminal reports. If the completion throws, keep its error as the
start failure cause.

**Reason.** #003 requires every failed start to end in the typed
`.startFailed` state. A delegate event yielded before the VZ start completion
could remain queued in the asynchronous event-stream consumer while
`VMController` published `.running`, misclassifying the same failure as
`.stoppedWithError`. Returning events buffered on the same serial VM queue
removes that scheduling race. The completion error remains authoritative when
that operation itself fails.

**Verification.** The 110 `VirtualMachineCoreTests` and 25 default
`VirtualMachineCoreSystemTests` passed. T0 exercises the production VZ
delegate's buffer/stream routing, the shared `VMStartupEventBuffer`, and
separately verifies the controller's buffered-start mapping with its fake
driver. The signed T2 probe directly measures Virtualization.framework behavior
rather than instantiating the production VZ driver: its positive control
recorded successful start completion, `guestDidStop`, and final VZ state
`stopped`; after VZ machine construction, removing the kernel produced
`VZErrorDomain/2` in the start completion, no delegate callback within two
seconds, and final VZ state `error`. Both VMs reached terminal states before
release. The source probe and configuration-rejection/reset test passed 2/2,
with result bundle `/tmp/apkrun-start-probe-final-3.xcresult`. The bounded
callback observation does not establish that a callback cannot arrive later;
see [vm.md](../02-design/vm.md) §17.

## IR-244: Verify live crosvm identity and repeat Mesa EGL diagnosis

| Field | Value |
|---|---|
| Status | Diagnostic evidence recorded; #064 remains open |
| Task | #064 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064; [progress snapshot](issues/README.md) §5; `Images/tools/reference/{capture.sh,boot_observer.py,elf_identity.py,check_virgl_crosvm.py}`; `Images/reference/16373615/incomplete/target-20261008T030306-2167/` and its [verification receipt](../../Images/reference/16373615/incomplete/target-20261008T030306-2167.verification.txt) |

**Choice.** Repeat one observer-enabled `target` capture in an isolated,
writable Lima scratch checkout copied from commit
`3c0e413ddc49e18f684c55306d607f1c8ead906a`. Keep the result in `incomplete/`
because the configured crosvm override has no recorded Virgl certification.
Use this run to verify the newly added live `/proc/<pid>/exe` identity event
and to check whether the pinned guest still fails during Mesa EGL loading.

**Reason.** The previous 600-second target diagnostic predates the live runtime
identity event and therefore could not validate that observer change. The
uncertified host binary and known guest-image mismatch make a canonical profile
or a rendering claim unjustified. An isolated scratch tree also avoids
overwriting the saved captures or changing the pinned product image.

**Verification.** The pinned product's ten manifest artifacts passed their
size and SHA-256 checks before capture. The 604-second run used Cuttlefish
1.57.0 / VCS `9bb9c72329cedcb436bb75afc05c24d73fbcdf5d`, Ubuntu 24.04.4
arm64 with nested virtualization, build 16373615, `drm_virgl`, and
`EGL_PLATFORM=surfaceless`. The observer recorded a live crosvm identity for
PID 2677 as `identified`, with SHA-256
`48a9553740a947a2f6f1679692a73d022ea364d43b7e4652d7c9ab6a0ac5aaf7` and GNU
Build ID `1f6c03321061aa58e1d1ec0d0a1ff54f`, matching the preflighted
executable. The 600-second startup deadline expired. ADB reported `device` on
13 of 20 polls; all three property probes timed out, with no parsed boot or
SystemServer value. The kernel log has no boot-complete, boot-failed, or
`system_server` marker. Host logcat recorded eight Mesa driver-load failures,
eight fatal-signal records, and eight abort messages stating that no OpenGL ES
implementation could be found. `MISSING.txt` records
`crosvm-command-line.txt` as unavailable at artifact collection; the
`crosvm-runtime-identity.txt` sidecar contains only its header because crosvm
had already exited.

The normalized schema-v3 `host.json` records path-free identities. The
[verification receipt](../../Images/reference/16373615/incomplete/target-20261008T030306-2167.verification.txt)
lists all 12 artifact hashes and records that they matched their Lima-side
copies. A second normalization changed zero files; the JSON artifacts and all
151 observer JSONL records parsed. The scans found no host paths, loopback ADB
endpoints, MAC addresses, unmasked serial/IMEI/MEID arrays, raw IMEI/MEID
values, or private-key markers; all 16 guest serial-property occurrences are
`<SERIAL>` placeholders. Per IR-122, 48 Cuttlefish virtual UART endpoint
tokens in `launcher.log` remain intentionally visible to preserve the UART
mapping. The capture's Cuttlefish group, private HOME, staging directory, and
lock were removed; the pre-existing stale instance-1 registry entry was left
untouched. The dedicated ADB server on port 5038 was stopped, with no
remaining listener on ports 5038 or 6521. This verifies the live identity
event and reconfirms the guest-side EGL failure; it does not prove host Virgl
initialization, Android boot completion, rendered frames, or any of #064's
remaining profile acceptance criteria.

## IR-245: Reconcile RiftVM analysis with the implemented graphics path

| Field | Value |
|---|---|
| Status | Documentation findings corrected; final hostile review passed; maintainer review pending |
| Task | #018 |
| Affected documents | [riftvm-analysis.md](../02-design/riftvm-analysis.md) §§1–2, 4, 7–8; [graphics.md](../02-design/graphics.md) §§5.1, 16; [progress snapshot](issues/README.md) §5 |

**Choice.** Describe RiftVM's 4 GiB renderer budget as a four-byte-per-texel
workload estimate, map command-specific error paths for backing attachment and
context attach/detach (including the successful `CTX_ATTACH_RESOURCE` path),
distinguish a resize event on RiftVM's single scanout from connector-topology
hotplug, and reconcile each current APKRun patch with the pinned RiftVM recipe
and the completed #020 build. Describe CI as checking source-only lock
metadata and the license-file reference; retain the manual byte comparison of
the MIT copy as this review's evidence.

**Reason.** The pinned implementation, current graphics design, and existing
#020 verification record describe different layers of evidence. Stating those
boundaries directly avoids treating a workload estimate as a memory guarantee,
a single-head resize as multi-display hotplug, or already-built patch inputs
as future work. A source-only reference lock also has different notice checks
from shipped source components.

**Verification.** The edits address the first hostile review's resource
estimate, response mapping, scanout behavior, patch crosswalk, and lock-license
claims. A later hostile follow-up found the missing invalid-context and
missing/non-renderer-resource responses for `CTX_ATTACH_RESOURCE` and an
ambiguous backing-attachment mapping; the table now separates each condition
and response using the pinned handler. A final hostile review found no
remaining actionable findings. Maintainer review remains pending.
`scripts/ci/run-checks.sh` passed all six checks:
`scripts/tests/run.sh`, `scripts/check-module-deps.sh`,
`scripts/check-logging.sh`, `scripts/check-todos.sh`,
`scripts/check-format.sh`, and `scripts/check-lock.sh`. The repository also
passed `git diff --check`. #020's clean build and tests remain recorded in
IR-191.

## IR-246: Keep invalid update-source input out of rendered errors

| Field | Value |
|---|---|
| Status | Implemented; hostile review passed; maintainer review pending |
| Task | #061 |
| Affected documents | [error-catalog.md](../03-reference/error-catalog.md) §16; [diagnostics.md](../02-design/diagnostics.md) §2; [#061](issues/M00-repository-and-vm-foundation.md#061-diagnostics-foundation) |

**Choice.** Render `cli.invalidSourceSpec` with a fixed message and no
interpolated argument. Keep the original value only in the typed failure for
local control flow; do not expose it through CLI, JSON, or catalog parameters.

**Reason.** Update-source specifications may contain credentials, tokens,
private paths, or query values. A generic message avoids disclosing them while
the remediation still lists the supported source forms and help command.

**Verification.** The CLI regression test supplies a source with URL user-info,
a private path, and a query token, then checks both human and JSON output for
the absence of those values.

## IR-247: Preserve typed parameters for ordered VM configuration findings

| Field | Value |
|---|---|
| Status | Implemented; follow-up hostile review pending; maintainer review pending |
| Task | #061 |
| Affected documents | [diagnostics.md](../02-design/diagnostics.md) §2; [error-catalog.md](../03-reference/error-catalog.md) §§3.4, 3.6, 5; [runtime-api.md](../03-reference/runtime-api.md) §§2.3, 4.5; [#061](issues/M00-repository-and-vm-foundation.md#061-diagnostics-foundation); [#032](issues/M04-daemon-and-guest-protocol.md#032-xpc-runtime-api) |

**Choice.** Add an ordered `APKRunError.listItems` payload whose items select a
catalog code or variant and carry their own typed parameters. Use it for
`VMConfigurationFailure.configurationInvalid` while retaining the existing
comma-separated `items` parameter as a fallback. Render each item through the
catalog on CLI, GUI, and JSON surfaces. Give parameterized VM messages
placeholders for safe values such as requested CPU count, allowed range, and
disk role. When either a typed item or an older flattened payload lacks a value
required by a child message, use the aggregate's generic message for that item.
Add an optional
`WireError.listItems` field and old-peer conversion tests to RuntimeAPI task
#032. Keep host requirement health findings in their existing
`ErrorInfo`/localized-text representation.

**Reason.** A list-wide parameter dictionary cannot associate values with
repeated child codes, so it can lose which value belongs to which finding.
Ordered typed records preserve association and display order. Keeping the
existing `items` field provides a fallback during the transition; placing the
wire representation in #032 keeps the XPC contract and its compatibility tests
with the task that implements RuntimeAPI. Falling back per item preserves
useful catalog text when its values are present while avoiding blank
placeholders when a value is unavailable.

**Verification.** T0 tests cover repeated error codes with distinct values on
all three presentation surfaces and exercise actual VM catalog messages for
CPU count and disk roles. A hostile follow-up caught blank placeholders for
older flattened list payloads; those now fall back to the aggregate's generic
message. A subsequent review found the same risk in typed items and noted the
old-peer rule was underspecified; typed code and variant selectors now use the
same fallback, covered on CLI, GUI, and JSON, and the RuntimeAPI text states
the per-item rule. A prior review caught an invalid health-check variant in the
API example; it now uses a compiled catalog variant, with renderer coverage.
The generator test confirms retired catalog entries remain available to
render errors from older peers.

## IR-248: Start #019 while the #003 gate is still open

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md#003-boot-minimal-arm64-linux) #003; [README](issues/README.md) §3, §5; [M02](issues/M02-graphics.md#019-virtio-gpu-device-layer) #019 |

**Choice.** #019 starts on the implementation evidence of #003 (the signed `LinuxGuest` run on commit `d31e7e3` passed 33 of 33) and does not wait for #003's formal G1 closure, its ten-boot gate run, or its task-closing review. #019 does not claim #003's acceptance, and its own T2 acceptance still needs a booted guest.

**Reason.** [README](issues/README.md) §5 allows parallel tracks to advance while #003's clean `main` gate run stays open. #019 changes only the device model, the guest's `gpu` check, and the runner that attaches the device. Waiting for the gate would hold the M2 chain for a step that does not change the device contract.

**Verification.** The #003 acceptance boxes remain unticked in M00. No #019 test depends on a gate run. The T2 part of #019 is blocked by IR-251, so the dependency choice does not change what #019 can prove today.

## IR-249: Error policy for requests the device does not implement

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2, §4.6; [riftvm-analysis.md](../02-design/riftvm-analysis.md) §2.1; [M02](issues/M02-graphics.md#019-virtio-gpu-device-layer) #019 steps 2 and acceptance |

**Choice.** In #019 the device answers `GET_DISPLAY_INFO` and `GET_EDID`, and it answers every other command with an error. On the control queue an unsupported command gets `ERR_UNSPEC`. On the cursor queue, `UPDATE_CURSOR` and `MOVE_CURSOR` get `ERR_UNSPEC`, and any other command gets `ERR_INVALID_PARAMETER`, because it is on the wrong queue. Requests shorter than the 24-byte header get no response but are completed. Requests above 4 MiB plus 32 bytes get `ERR_INVALID_PARAMETER`. `GET_EDID` before EDID negotiation gets `ERR_UNSPEC`, and an out-of-range scanout gets `ERR_INVALID_SCANOUT_ID`. A response that does not fit gets an error header when the element can hold one, and otherwise nothing is written.

**Reason.** The task's step 2 and its acceptance criterion ask for an error response to every command other than the two. Section 4.2 and §4.6 say cursor commands are acknowledged. The acceptance criterion is the contract for this task, and the acknowledgement depends on cursor-plane work that belongs to #022 and #023, so this task follows the criterion. The wrong-queue and unsupported-command split follows the mapping that RiftVM was observed to use. It is observed behavior, not an APKRun policy.

**Verification.** T0 `everyOtherControlCommandGetsAnErrorResponse` covers all 22 other control-queue commands. `cursorQueueCommandsGetErrorResponses`, `aRequestLargerThanFourMebibytesGetsAnInvalidParameterError`, `aResponseThatDoesNotFitIsReplacedByAnErrorHeaderOrDropped`, and `aRequestShorterThanTheHeaderGetsNoResponseButIsCompleted` cover the rest. Each test checks that the element is completed exactly once.

## IR-250: Golden virtio-gpu vectors are written from the layouts, not captured

| Field | Value |
|---|---|
| Status | Needs maintainer review; partly resolved by the captured Linux trace (2026-10-08, `376bf4e`) |
| Task | #019 |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#019 step 1), §14; [M02](issues/M02-graphics.md#019-virtio-gpu-device-layer) #019 deliverables |

**Choice.** `Tests/Fixtures/graphics/virtio-gpu-vectors.json` holds 28 request and 8 response vectors. An independent script writes them from the field layouts of `virtio_gpu.h`, with zero padding. The file's `provenance` field says so. When the T2 guest runs, bytes captured from the Linux driver replace these vectors, and the capture uses the device's `traceObserver`.

**Reason.** Driver traces need a booted guest, which the current lock cannot build (IR-251). Layout vectors still test every field offset, every length rule, and the fence and context echo rules. They cannot show which flags Linux actually sets, so the captured traces are still required for the acceptance.

**Verification.** T0 decodes and re-encodes every vector byte for byte. Truncation at every byte and one trailing byte are rejected. The EDID in the response vector is one of the golden blocks in IR-252.

**Update (2026-10-08).** The `gpu` check of the T2 run captured 28 exchanges from the Linux driver (`Tests/Fixtures/graphics/virtio-gpu-linux-trace.json`). Every one decodes and re-encodes exactly. The device answers the 17 display and EDID requests as the driver received them (`deviceAnswersTheCapturedDisplayAndEDIDRequestsLikeTheLinuxDriverSaw`). The layout vectors remain the coverage set for the commands this guest does not send.

## IR-251: The test Linux guest cannot be built from the current lock file

| Field | Value |
|---|---|
| Status | Resolved by [IR-258](#ir-258-bump-the-alpine-libcrypto3-and-libssl3-pins-to-359-r0); the pin bump needs maintainer review |
| Task | #019; also #003 and the test artifacts of [environment-setup.md](../05-development/environment-setup.md) §4 |
| Affected documents | [ThirdParty.lock.json](../../ThirdParty/ThirdParty.lock.json) (`alpine-libcrypto3`, `alpine-libssl3`); [vm.md](../02-design/vm.md) §12 |

**Choice.** #019 does not change the lock. `scripts/fetch-test-linux.sh` downloads the kernel and the minirootfs, then fails on `alpine-libcrypto3` (`libcrypto3-3.5.8-r0.apk`), which returns HTTP 404. The Alpine v3.24 `main` index lists `libcrypto3` and `libssl3` at 3.5.9-r0. A maintainer needs to bump both pins with reviewed SHA-256 values. Until then the `gpu` and `gpu-hotplug` checks, the R-01 spike, the golden capture, and the T2 acceptance boxes of #019 stay unrun.

**Reason.** The pins are the reproducibility contract of NFR-DEV-01. A bump changes the bits that every T2 suite boots, and it belongs to the #003 artifact pins, not to the graphics device task.

**Verification.** The fetch log shows the 404 after the kernel and minirootfs succeed. `curl -I` on the pinned Alpine URLs returns 404 only for `libcrypto3-3.5.8-r0.apk`. The `APKINDEX.tar.gz` of v3.24/main, fetched on 2026-10-08, lists `libcrypto3` and `libssl3` at 3.5.9-r0.

## IR-252: Test mode, EDID constants, and the CVT reduced-blanking parameters

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.1, §6.1, §6.4; [M02](issues/M02-graphics.md#019-virtio-gpu-device-layer) #019 step 3 |

**Choice.** Scanout 0's fixed test mode is 1024×768 at 60 Hz and 160 dpi (`DisplayMode.testDefault`). The EDID uses manufacturer `APK`, week 0, model year 2026, digital 8-bit input, gamma 2.2, and sRGB chromaticity computed from the sRGB coordinates with 10-bit rounding. The range limits are 24–120 Hz vertical, 30–255 kHz horizontal, and 660 MHz maximum pixel clock. The detailed timing uses CVT reduced blanking with horizontal blank 160, sync 32, and front porch 48; vertical front porch 3, vertical sync 8, minimum back porch 6, and minimum vertical blank 460 µs; the pixel clock steps down to 0.25 MHz. Accepted modes have 1–4095 pixels, 24–120 Hz, and 1–1200 dpi.

**Reason.** §6.4 names the rules but not the constants. The golden blocks decode in edid-decode 5332a3b with no failure or warning lines. They report the requested modes, sizes, and names. I did not verify CVT-RB conformance. The vertical sync width of 8 lines is my reading of CVT 1.2 for reduced blanking, and the 16:9 value may differ. A maintainer should confirm it, and check whether edid-decode's CVT-RB reporting agrees.

**Verification.** T0 compares generated blocks with the golden files (scanouts 0, 1, and 15). An independent T0 decoder reads back the manufacturer, product code, serial, name, timing, and sizes. Accepted modes are checked for checksum and decoded width and height. edid-decode output is committed beside each block.

## IR-253: Display-event rules that the design leaves open

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [graphics.md](../02-design/graphics.md) §3.1, §4.3, §8 |

**Choice.** (1) A scanout change that leaves the state as it was does not bump `displayGeneration`. (2) `events_read` is written by one writer task per DRIVER_OK generation. It always writes the newest wanted value and stops when that value matches the last successful write. Updates that complete out of order therefore cannot leave an old value behind. (3) A writer from an earlier generation exits without changing state. (4) Reset sets the wanted `events_read` to 0 and keeps the host's scanouts. The next DRIVER_OK writes the current value if it differs. (5) The device treats the last successful write as the configuration bytes that survive a reset.

**Reason.** §4.3 gives the generation logic but not the ordering of asynchronous updates, the no-op rule, or reset. Rule (5) assumes that VZ keeps the configuration bytes across a reset. That assumption is not measured for the GPU device, so the R-01 spike should check it.

**Verification.** T0 covers a change before DRIVER_OK, a GET_DISPLAY_INFO that clears the event, a change during an in-flight query that keeps it set, a reset that keeps scanout 1 enabled and clears the event, a rejected mode that sends nothing, and a disable that sends one. The VZ-side behavior is not verified (IR-251).

## IR-254: ResourceTable is not connected to the device in #019

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.4, §5.4, §8; [M02](issues/M02-graphics.md#019-virtio-gpu-device-layer) #019 scope |

**Choice.** `ResourceTable` is a standalone type with its own T0 tests. `VirtioGPUDevice` does not hold one. Every resource command gets an error response (IR-249), so the table's reset and attach paths run only in tests until #022 connects them.

**Reason.** The acceptance requires an error response for every command other than the two EDID and display commands. Connecting the table now would change those responses. The table's rules are specified in §4.4 and §5.4, so writing it now lets #022 connect it without redesign.

**Verification.** 12 ResourceTable T0 tests cover IDs, format and dimension rules, the single-resource, total-memory, and live-resource limits, backing validation with no partial state, the entry limit, detach, unref, and reset.

## IR-255: The fuzz smoke target is a time-boxed Swift test

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [test-strategy.md](test-strategy.md) §7.2; [graphics.md](../02-design/graphics.md) §11 |

**Choice.** The #019 "time-boxed fuzz smoke target" is a T1 Swift Testing test in `GraphicsCoreSystemTests`. It mutates the golden vectors with a fixed seed for up to 5 s (requests) and 2 s (responses). Each input must either decode with a typed error or re-encode to bytes that decode to the same value. The libFuzzer target and its CI schedule stay with #091.

**Reason.** The docs do not define how libFuzzer runs on macOS in CI. A deterministic in-process smoke test gives CI a bounded check now without choosing that toolchain setup.

**Verification.** `mutatedRequestsDecodeWithTypedErrorsOrRoundTrip` and `mutatedResponsesDecodeWithTypedErrorsOrRoundTrip` passed on macOS 27.0.1 (26A434).

## IR-256: The R-01 spike is a development-only option selected by test name

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.3, §12 (#019 step 5), §15; [risks.md](risks.md) R-01 |

**Choice.** `VirtioGPUDevice(hotplugSpikeDelay:)` enables scanout 1 once, 3 seconds after the first DRIVER_OK. `LinuxTestGuestRunner` sets the delay only when the `gpu-hotplug` test is requested. The guest's `gpu-hotplug` check waits up to 30 seconds for `card0-Virtual-2` to report `connected`. A failed wait is recorded as `fail`, which is the R-01 negative result.

**Reason.** §4.3 requires a runtime scanout change in a running guest, but it does not say how the host reaches the device. The device queue is owned by VZ and is not exposed to the model, so the device enables the scanout itself through its thread-safe lock. The option is off in every other build.

**Verification.** T0 `theHotplugSpikeEnablesScanoutOneAfterTheFirstDriverOK` passes. The T2 run on 2026-10-08 recorded the Linux result. The host enabled scanout 1 3.0 s after DRIVER_OK, and the guest's `gpu-hotplug` check reported `scanout1=connected` after about 4 s and 5 s in two runs. The R-01 Linux part is positive. Android stays with #028.

## IR-257: edid-decode is built outside the lock for fixture generation

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [ThirdParty.lock.json](../../ThirdParty/ThirdParty.lock.json); [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.1 |

**Choice.** edid-decode was built with meson from upstream `git.linuxtv.org/edid-decode.git`, parent commit `5332a3b`, in a gitignored build directory. The upstream `HEAD` only points to v4l-utils, so the code comes from its parent. The tool is not in `ThirdParty.lock.json`. It does not ship and does not run in CI. Its output (SPDX `MIT`) is committed as text beside each golden EDID.

**Reason.** Homebrew has no edid-decode formula, and the deliverable needs its output. Pinning a tool used only for fixture generation would add a lock entry that no build step reads.

**Verification.** The three golden blocks decode with exit status 0 and no failure or warning lines. The decode output is in `Tests/Fixtures/graphics/edid/*.edid-decode.txt`. A maintainer may decide to pin the tool in the lock.

## IR-258: Bump the Alpine libcrypto3 and libssl3 pins to 3.5.9-r0

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 (T2 acceptance); the test Linux artifacts of #003 |
| Affected documents | [ThirdParty.lock.json](../../ThirdParty/ThirdParty.lock.json) (`alpine-libcrypto3`, `alpine-libssl3`); [environment-setup.md](../05-development/environment-setup.md) §4; [IR-251](#ir-251-the-test-linux-guest-cannot-be-built-from-the-current-lock-file) |

**Choice.** Replace the two pins with 3.5.9-r0 from the Alpine v3.24 `main`
aarch64 index, with these values:

- `libcrypto3-3.5.9-r0.apk`: 2,286,800 bytes, SHA-256
  `2676a2b0b6e23ea2edccf3ee982b9842a665d52603d047de3d0a185dc316d983`.
- `libssl3-3.5.9-r0.apk`: 373,023 bytes, SHA-256
  `20ac252b276d73f2c69c1d25f84537c7fba81caefc026c6be1094b394af2082e`.

The bump is made by the implementer instead of waiting for a separate review,
because the old pins return HTTP 404 and block every test Linux guest run.
IR-251 asked for this review; this entry is the maintainer's review item.

**Reason.** The 3.5.8-r0 packages are no longer served, so
`scripts/fetch-test-linux.sh` cannot complete. The new version stays on the same
release line (v3.24), the same license (Apache-2.0), and the same `tooling`
class. It is the smallest change that restores the pinned fetch.

**Verification.** The `APKINDEX.tar.gz` of v3.24/main/aarch64, fetched on
2026-10-08, lists both packages at 3.5.9-r0 with the sizes above. The downloaded
files match those sizes. The SHA-1 of each file's control gzip member matches
the index `C:` field (`Q1` plus base64). `scripts/check-lock.sh` passes, and
`scripts/fetch-test-linux.sh` exits 0.

**Limit.** The index does not carry SHA-256 values for the `.apk` files, and this
checkout has no `apk` tool to check Alpine's package signature. The SHA-256 values
are therefore trust-on-first-use over HTTPS, checked against the index for size
and control checksum. A maintainer should confirm them against the Alpine signing
key before the bump is accepted.

## IR-259: Accept only the modes the EDID detailed timing and range descriptor can express

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #019 |
| Affected documents | [graphics.md](../02-design/graphics.md) §6.4; [IR-252](#ir-252-test-mode-edid-constants-and-the-cvt-reduced-blanking-parameters) |

**Choice.** `DisplayMode.isSupported` now also requires that the CVT
reduced-blanking timing of the mode fits the 16-bit detailed-timing clock
(655.35 MHz) and that its horizontal frequency lies in the 30–255 kHz range of
the range limits descriptor. Modes outside that check are rejected when a
scanout is enabled, not when the guest asks for its EDID. Two accepted modes
change as a result: `4095x4095@60` (about 1051 MHz) is rejected, and
`4095x4095@24` is accepted. `1024x768@24` (about 18.8 kHz) is also rejected.
The EDID bytes do not change, so the golden files stay the same.

**Reason.** Before this change, `isSupported` accepted modes that the EDID
generator then refused. An enabled scanout then reported a connector change the
guest could not read, and GET_EDID returned an error. The range descriptor also
claimed that every accepted mode lies within its limits, which was false for
some modes. Rejecting an inexpressible mode keeps the advertised EDID
truthful. The alternative was to widen the descriptor's horizontal minimum to
about 1 kHz, but that changes the golden EDID bytes for every mode. It also
accepts a 24 Hz 768-line mode that no standard range descriptor covers well.
A maintainer may prefer that alternative, which would then change the golden
files.

**Verification.** `ScanoutTableTests` checks the four cases above. `GraphicsCoreTests`
passes 69 tests, including the golden EDID tests, which are unchanged.

## IR-260: Shape the schema where the design leaves messages and field numbers open

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §4.1, §5.1, §7–§12; [Packages/GuestProtocol/proto/apkrun/guest/v1/](../../Packages/GuestProtocol/proto/apkrun/guest/v1/) |

**Choice.** Where the design names an operation's result or a payload but gives no fields, or only prose, the schema defines the smallest message that carries the design's fields. Fields are numbered from 1 in declaration order. The choices a reviewer is most likely to overturn are:

- A result that is a list is a message with one `repeated` field: `TaskList`, `PackageList`, `PackageSummary`, `RootList`, `DocPage`, `StorePackageList`, and `ReadRangeResult` (for `bytes data`).
- `ResolveExport` returns `ExportStart`, whose `transfer_id` is `optional`. The design's "Empty" on decline is an unset `transfer_id`, because the operation has one result type.
- `install_id` is a `string` everywhere, because `BulkBegin.context` carries `"inspect"` as well as install IDs.
- `CollectDiagnostics` has a `properties` field for the allowlisted `GETPROP` keys. `DiagnosticsItemResult.transfer_id` is `optional`, so an unset ID means the item is not `OK`.
- The fields the design marks "optional" are `optional` in proto3: `LaunchApplication.component`, `data_uri`, and `action`; `ListTasks.display_id`; `ActivateNotification.action_index`; and `ImportFiles.package`.
- The design's "constraints (GENTLE_UPDATE)" is one `InstallConstraint` value in `CheckInstallConstraints.constraint`, not a list.
- The design does not list these enums, so the schema defines them, each with `UNSPECIFIED = 0`: `NotificationRemovalReason`, `UninstallStatus`, `RollbackStatus`, `IconKind`, `IconRole`, `UrlAction`, `ExportDecision`, `ClockFormat`, `OpenMode`, `AccessLevel`, `ImportDisposition`, `ImportTarget`, `ManagedPackageFilter`, `BulkKind`, `BulkAckStatus`, `ContextMenuAction`, `ClipOrigin`, `DiagnosticsItemStatus`, `InstallMode`, `InstallStage`, `InstallStatus`, `TouchPhase`, `MouseAction`, `KeyAction`, `PackageFilter`, `PackageChangeKind`, `HealthWarningKind`, and `AppProcessEventKind`.
- Messages the design names in prose only are defined with the fields that the prose gives: `ArchiveInfo`, `PackageSummary`, `MemoryInfo`, `InputCounters`, `AgentInfo`, `AndroidInfo`, `SigningInfo`, `IconLayer`, `PackageConstraint`, `ArtifactRef`, and `ArtifactSpec`.
- `PackageRef`, listed in guest-protocol.md §2 for `common.proto`, is not defined, because no operation takes it. Every operation carries `package` as a string.

**Reason.** The field numbers are frozen when #033 merges (guest-protocol.md §17), and §8–§11 leave these shapes open. The smallest shape that carries the design's fields keeps every choice visible in the schema and in one place. The alternative is to let #072 and #034 add these shapes later. That would allocate numbers after the merge, which the design does not allow without a major change.

**Verification.** `buf lint` passes on every file. `NumberingRuleTests` checks the 50 operations of §7.1, §7.5, and §11.1: each has a result with the same number and name, every referenced message is defined, and each event number is in its range. The golden frames cover every envelope body kind, and the Swift and Kotlin codecs decode and re-encode them.

**Limit.** A maintainer should review the list above before the field numbers freeze at merge. A change before the merge is free. After it, a change to a field meaning or number is a major change (guest-protocol.md §5.2).

## IR-261: Name enum values with their enum prefix, and keep GuestError in common.proto

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §2, §4.1, §12.1; [coding-conventions.md](../05-development/coding-conventions.md) §2, §6.1; `Packages/GuestProtocol/buf.yaml` |

**Choice.** Every enum value carries its enum's name as a prefix, in upper snake case. `GuestErrorCode.INVALID_ARGUMENT` is `GUEST_ERROR_CODE_INVALID_ARGUMENT` in the .proto, and it is `.invalidArgument` in the generated Swift. The design's shorthand values, such as `INVALID_ARGUMENT` and `FINISH_TASKS`, are not used as schema names. `GuestError`, `GuestErrorCode`, and `AgentMode` are in `common.proto`, not `envelope.proto` as §2 lists. The buf configuration is `Packages/GuestProtocol/buf.yaml`, the location that §2 and the #033 entry name, not `proto/buf.yaml` as coding-conventions §2 said. The rule set is `STANDARD`, the name buf 1.55.1 gives to the rule set that the docs call `DEFAULT`. The old name is deprecated and only prints a warning.

**Reason.** buf's `STANDARD` rules include `ENUM_VALUE_PREFIX`, so `buf lint` fails on `INVALID_ARGUMENT` and on every other shorthand. The prefix is also needed because protobuf scopes enum values to the package. `envelope.proto` imports `control.proto`, and `control.proto` needs `GuestError` for `Health.last_error` and `AgentMode` for `Health.mode`. Keeping those types in the envelope would make an import cycle, which protoc rejects.

**Verification.** `scripts/check-protos.sh` passes with the pinned buf, and protoc compiles the package without errors. The generated Swift is `GPGuestErrorCode.invalidArgument`, and the tests use it.

**Limit.** The design still shows the shorthand names. Their meaning is the same, but a search for `INVALID_ARGUMENT` in the schema finds nothing. The conventions document was corrected in the same change to name `Packages/GuestProtocol/buf.yaml` and `STANDARD`.

## IR-262: Split the handshake rules between host and agent, and close a refused agent connection

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 (handshake matrix); #072 and #034 implement the connections |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §5.1, §5.2, §5.4, §12.3; [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.3 |

**Choice.** The host enforces the major-version rule and the channel rule on the agent's Hello. It answers with `HelloAck.rejected(INCOMPATIBLE_VERSION)` or `rejected(WRONG_CHANNEL)` and then closes. This is `GuestHandshake`, in Swift. The agent enforces `BAD_TOKEN` and `DUPLICATE_SESSION` on its own control session (`ControlSessions`, in Kotlin). It refuses a connection by closing it and logging the reason, and it sends no `Rejected`. The agent also checks the host's major version in the HelloAck that it receives (`AgentHandshake`).

**Reason.** §5.1 makes the agent speak first, with Hello, and the host answer with HelloAck. `Rejected` is part of HelloAck, so only the host can send it. Two rules in §5.4 are therefore decisions of the agent: a secondary connection with the wrong token, and a second control connection while one is open. The agent sends no HelloAck, so it cannot send `Rejected` for either. Hello also has no token field, so the agent cannot check a token before the host's HelloAck arrives. For a secondary connection, the agent compares the token in the host's HelloAck with the token of its control session. The alternatives were a token field in Hello, or a new agent-to-host rejection message. Both change the wire format, and the design asks for neither.

**Verification.** `HandshakeTests` (Swift) covers the same major, a higher minor, a different major (a fake agent with major 2 is rejected with `incompatibleVersion`), an older major, a wrong channel, an unspecified channel, and a Hello without a version. `AgentHandshakeTest` and `ControlSessionsTest` (Kotlin) cover the host's rejections, a host with major 2, a bad token, a duplicate session, the exact 15 s boundary, and a session that is silent for more than 15 s.

**Limit.** A refused agent connection ends without a reason on the wire. The host therefore sees a disconnect (`guestProtocol.disconnected`), not `handshakeFailed`, when the agent refuses. The agent logs the reason. A maintainer may prefer an agent-side rejection message, which would change the message set or the HelloAck direction. #072 implements the host side against this split.

## IR-263: Generate the golden frames from text sources with protoc, and keep each map to one entry

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §4, §16; [coding-conventions.md](../05-development/coding-conventions.md) §6.1 |

**Choice.** Each valid golden frame is a text-format `Envelope` in `Packages/GuestProtocol/testdata/frames/valid-*.txtpb`. `scripts/generate-protos.sh` encodes it with the pinned protoc (`--encode`) and adds the 4-byte length prefix. The invalid frames (`invalid-zero-length`, `invalid-oversize`, `invalid-truncated`, and `invalid-malformed`) are fixed byte sequences that the script writes. The set has 13 valid frames and 5 invalid ones. The fifth, `invalid-no-body`, is an envelope with an id and no body, which both decoders reject. The only map in any golden frame has one entry.

**Reason.** Text sources make each frame reviewable. The CI codegen job then covers the binary files too, because it regenerates them and fails on any diff. Swift and Java serialize a `map` in different orders, so a multi-entry map would make the byte-for-byte re-encode check depend on the implementation. A one-entry map keeps the check exact. The rule is recorded here so that later golden frames, such as the #072 frames, follow it.

**Verification.** Regeneration is deterministic. Two runs produce identical Swift sources and identical frame bytes, which were compared by SHA-256 (18 frames). `GoldenFrames` in Swift and `FrameCodecTest` in Kotlin decode every valid frame, re-encode it byte for byte, and reject each invalid frame with its typed error. A test also fails if an invalid frame has no expected error.

**Limit.** The text sources depend on protoc's text format. A protoc upgrade could change how a text value is read, and the pin in `scripts/tool-versions.env` is the control for that.

## IR-264: Pin protoc, buf, and protoc-gen-swift in bootstrap

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 (bootstrap line "protoc and buf — added by #033") |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.7, §2.9; `scripts/tool-versions.env`; `scripts/bootstrap` |

**Choice.** `scripts/tool-versions.env` pins protoc 31.1 and buf 1.55.1 with the SHA-256 of each release archive. `scripts/bootstrap` downloads both, checks the digest before extracting, and installs them under `build/tools`. protoc-gen-swift is built from the `swift-protobuf` revision that `Package.resolved` pins (`55d7a1cc`). The build's revision is recorded in `build/tools/protoc-gen-swift/REVISION`, and bootstrap checks the checkout against it. The archive digests are protoc `4aeea0a3…` (the zip) and buf `d8a71a9f…` (the tar.gz).

**Reason.** environment-setup.md §2.7 requires these pins and says bootstrap installs them. The protoc digest came from the GitHub release. It was cross-checked against Maven Central: the `bin/protoc` in the archive has SHA-1 `23f9cbc6…`, which is the SHA-1 of `com.google.protobuf:protoc:4.31.1:osx-aarch_64.exe`. The buf digest matches the one that GitHub publishes for the asset. `swift package resolve` alone does not guarantee the checkout is the pinned revision, so the revision is checked.

**Verification.** The install functions ran in isolation. protoc 31.1 and buf 1.55.1 installed, and protoc-gen-swift built in 26 s, with 0 failures. `scripts/bootstrap --check` reports all three as `ok`. The full bootstrap was not run, because it also runs `brew bundle` and `pip install`, which change the host beyond this task.

**Limit.** bootstrap still skips the JDK and the Android SDK, as its own line says (#015). See IR-265.

## IR-265: Install the Android SDK inside the repository, and name the platform package android-37.0

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 (`./gradlew -p Guest :guestd:assemble`) |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.5 (corrected in this change); [IR-264](#ir-264-pin-protoc-buf-and-protoc-gen-swift-in-bootstrap) |

**Choice.** The SDK is in `build/android-sdk`, which is git-ignored, not in `~/Library/Android/sdk`. `Guest/local.properties`, also git-ignored, points at it. The platform package is `platforms;android-37.0`. The SDK repository lists API 37 under that name and has no `platforms;android-37`, so §2.5 is corrected. `build-tools;37.0.0` is installed as §2.5 says. `platform-tools` and the NDK are not installed, because #033 uses neither. The license terms were accepted through `sdkmanager`, which is the step §2.5 gives. This is the one acceptance in this task that a maintainer should know about.

The `sdkmanager` script delegates to the Android CLI, which wrote `~/.android/bin` and `~/.android/cli` outside the repository during the first run. Those two directories were created by that run and were removed. The install then ran the classic `SdkManagerCli` from `cmdline-tools/latest/lib/sdklib/tools.sdklib.jar`, with `ANDROID_SDK_HOME` set to `build/android-sdk/home`, so no more files reached the home directory.

**Reason.** `./gradlew -p Guest :guestd:assemble` needs a compile platform, and §2.5 is the documented way to provide one. The repository keeps changes outside it to a minimum, so the SDK goes in the repository's `build/`. #015 owns the bootstrap step that installs the JDK and the SDK, as the bootstrap line says.

**Verification.** `sdkmanager --list_installed` lists both packages. `:guestd:assembleDebug` and `:guestd:assemble` pass with exit 0.

**Limit.** The hosted lint job runs `ktfmtCheck`, which configures the Android modules and needs the SDK. Until #015 adds the SDK to bootstrap, that job cannot pass on a clean runner (see IR-267). A maintainer should decide whether the SDK location in §2.5 should stay under `$HOME`.

## IR-266: Build the Gradle modules with AGP 9 built-in Kotlin, protobuf plugin 0.10.0, and ktfmt as a pinned library

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §2; [coding-conventions.md](../05-development/coding-conventions.md) §2, §8; [environment-setup.md](../05-development/environment-setup.md) §2.5 |

**Choice.** The build uses AGP 9.4.1 with its built-in Kotlin, Gradle 9.6.1 (the wrapper is at the repository root and is pinned by SHA-256), protobuf-javalite and the protoc artifact at 4.31.1, the protobuf Gradle plugin 0.10.0, kotlinx-coroutines 1.11.0 (pinned, not yet used), and JUnit 4.13.2. ktfmt 0.64 runs from the shadowed `com.facebook:ktfmt` jar, through the `ktfmtCheck` and `ktfmtFormat` tasks in `Guest/build.gradle.kts`, not through the ktfmt Gradle plugin. Kotlin is not set to `allWarningsAsErrors`.

**Reason.** The ktfmt Gradle plugin (0.27.0) needs the classic Kotlin Gradle plugin, which AGP 9 does not provide. The classic Kotlin plugin (2.4.20), even with `android.builtInKotlin=false`, references `BaseExtension`, which AGP 9 removed. The protobuf plugin 0.9.6 has the same cast, and 0.10.0 loads. It does not expose the `proto` source set in the usual way, so the module configures that extension directly, which reads the schema from `Packages/GuestProtocol/proto`. The task names `ktfmtCheck`, so `check-format.sh` is unchanged.

**Verification.** `ktfmtCheck` passes after `ktfmtFormat`. `:protocol:testDebugUnitTest` runs 25 JUnit tests with no failures or skips. The build prints no Kotlin compiler warnings.

**Limit.** `allWarningsAsErrors` is not set. AGP's built-in Kotlin has no hook I could find for it, so CI does not enforce warning-free Kotlin. Warnings are zero today. The ktfmt task should move back to the plugin when the plugin supports built-in Kotlin. The kotlinx-coroutines pin is unused until #072.

## IR-267: Lint the schema through run-checks, and record the gap in the hosted lint job

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 (CI jobs) |
| Affected documents | [workflow.md](../05-development/workflow.md); [build-system.md](../05-development/build-system.md) §4; `.github/workflows/ci.yml` (`lint`, `codegen`) |

**Choice.** `buf lint` runs as `scripts/check-protos.sh`, and `scripts/ci/run-checks.sh` calls that script. The `lint` job therefore runs the schema lint without a change to `ci.yml`. The regeneration check is the existing `codegen` job, which runs `scripts/ci/codegen.sh`. That script runs `scripts/generate-protos.sh` and then fails on any diff, so it covers the Swift sources and the golden frames.

**Reason.** The `lint` job already runs `run-checks.sh`, so a separate job would only repeat the bootstrap and the tool install.

**Verification.** `scripts/check-protos.sh` passes with the pinned buf. `scripts/generate-protos.sh` regenerates the Swift sources and the golden frames with no change. The `codegen` script was run locally. The hosted jobs were not run, because this repository has no remote.

**Limit.** The `lint` job also runs `check-format.sh`, which runs `./gradlew -p Guest ktfmtCheck`. That needs the Android SDK, which bootstrap does not install until #015, so a clean hosted runner would fail there. The task entry therefore keeps the CI acceptance box open.

## IR-268: Leave out a capability that the agent does not implement, instead of failing the handshake

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 (capability negotiation); #034 and #072 implement the request checks |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §5.2, §5.3; [guest-components.md](../02-design/guest-components.md) §6.2 |

**Choice.** When the host's HelloAck lists a capability that the agent does not implement, the agent drops it from its enabled set. `GuestCapability.enabled` intersects the host's list with the agent's implemented set, and the handshake still succeeds. The agent then answers `UNSUPPORTED` for any request that needs the capability (§5.3). The host reacts through its missing-capability path, `capabilityMissing` (§5.2).

**Reason.** §5.3 says that the host "echoes the subset it will use", and that the agent "must reject (`UNSUPPORTED`) requests for capabilities that are not enabled, so both sides agree on what is in use". It does not say that a handshake must fail when the host enables something the agent does not implement. §5.2 handles the same situation for an older agent, per request: the agent answers `UNSUPPORTED`, and "the host treats a missing capability the same way before sending". Failing the whole handshake for one optional feature would also stop the operations that the agent does implement, such as `Ping` and `GetSnapshot`. guest-components.md §6.2 requires that a missing system method fails only its capability.

**Verification.** `AgentHandshakeTest` pins the behavior. The host enables `display.v1` and `core.v1`, the agent implements only `core.v1`, and the enabled set is `[core.v1]`.

**Limit.** The handshake does not tell the host that a capability was dropped, so the host's view can be wider than the agent's until the first `UNSUPPORTED` answer. A maintainer may prefer that the agent fail the handshake with a typed failure, or that the agent send its enabled set back. The first option needs only a new failure reason. The second needs a new message. Both should be reviewed before the field numbers freeze at merge.

## IR-269: Keep #064 open after the 2026-10-08 reference-capture audit

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064; [progress snapshot](issues/README.md) §5; [android-image.md](../02-design/android-image.md) §7.7; [runtime-daemon.md](../02-design/runtime-daemon.md) §3.3; `Images/reference/16373615/boot-signals.json`; `Images/tools/reference/boot_signals.py` |

**Choice.** Keep #064 open, and start no new reference capture in this pass. The
remaining blockers are recorded as follows.

1. `target` (`drm_virgl`) is blocked by the guest's Mesa EGL load failure. The
   pinned image selects `mesa`, but it has no Mesa EGL or GLES driver in the
   vendor or system EGL paths (IR-185, IR-240). The 2026-10-08 live run
   reproduced the failure: eight `libEGL` driver-load errors, eight SurfaceFlinger
   aborts, and no boot completion (IR-244). The guest image correction is outside
   #064, so it is not changed here.
2. `default` and `swiftshader`, which both select `guest_swiftshader`, have never
   reached boot completion. No record of the 62 incomplete captures contains a
   `VIRTUAL_DEVICE_BOOT_COMPLETED` line, and every `sysBootCompleted` field in
   the observer logs (2,524 entries) is null. The longest run was 3,600 seconds.
   The cause is not established.
3. `capture.sh` skips guest collection unless Android is ready, so no profile can
   be published as complete. The items that need a booted guest stay open: the
   §8.3 guest items, normalized publication under
   `Images/reference/16373615/<profile>/`, per-profile schema-version-3
   `host.json`, and the three-profile comparison. Guest collection is not moved
   ahead of boot completion, because a reference is a booted guest, and pre-boot
   data cannot satisfy §8.3.

**Reason.** Each capture runs for 10 to 60 minutes and ends at its deadline. The
entry notes say not to repeat the SwiftShader configuration without a material
host or guest change, and no such change is in scope for #064. Another run
would not produce a complete profile, so the effort went into the evidence that
already exists.

**Verification.** `boot_signals.py` summarized the 62 incomplete records; its 10
T0 tests pass, and Ruff is clean. A privacy scan of the 62 records found no host
path, MAC or EUI address, or PEM marker in any capture file. The one `/home/lima`
match is a receipt line that names the scanned pattern. All 7 schema-version-3
`host.json` files list path-free host-tool identities. The installed host
package's token set was read with `grep` in the Lima VM (IR-270). The Lima VM was
started from its stopped state and reached READY. No capture was run.

## IR-270: Correct the boot-signal table from observed captures

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [android-image.md](../02-design/android-image.md) §7.7; [runtime-daemon.md](../02-design/runtime-daemon.md) §3.3; `Images/reference/16373615/boot-signals.json`; `Images/tools/reference/boot_signals.py` |

**Choice.** Update the design text from the observed captures, and mark each
candidate as confirmed or corrected.

- `.kernel`: corrected. U-Boot prints its banner and `Starting kernel ...` before
  Linux. The Linux line `Booting Linux on physical CPU` is at kernel uptime
  0.000 s, which confirms it. U-Boot came first in all 40 records that contain
  both lines.
- `.init`: confirmed. `init: init first stage started!` first appears at median
  kernel uptime 42.0 s (n = 40; range 6.0 to 101.9 s).
- `.systemServer`: corrected. The console line `init: starting service 'zygote'`
  marks zygote's start (median 197.5 s; n = 36; range 55.8 to 635.7 s). No
  console line marks SystemServer's start in the 62 records. `system_server`
  appears only in untracked-process exit lines and servicemanager caller lines.
  The phase name and its ADB signal are kept. Whether the console signal should
  change is a `BootPhaseDetector` decision, so the detector is not changed here.
- `.bootCompleted`: unconfirmed. `VIRTUAL_DEVICE_BOOT_COMPLETED` is in the pinned
  host binaries, but no captured record contains it, so no timing is recorded.
- `VIRTUAL_DEVICE_BOOT_FAILED`: §7.7 said the guest writes it to the kernel log.
  In the 13 records that contain it, it appears only in host `run_cvd` output
  (`boot_state_machine.cc:211`), and no kernel log contains it. The guest path is
  not excluded, because the host monitor binary matches the token.
- `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED display=0 mode=ON`: seen in 28 kernel
  logs, with first-occurrence median 569.6 s (n = 28; range 198.9 to 965.8 s).

All medians combine GPU modes and come from diagnostic records, so they are not
reference timings.

**Reason.** Entry step 6 and its acceptance criterion require the exact strings
and their timing, with each §3.3 candidate confirmed or corrected. Two claims in
the design text are contradicted by the captures: the Linux line is not the
first console output, and `BOOT_FAILED` is not seen in the guest kernel log. The
extractor reports n, minimum, and maximum, so the sample sizes are visible.

**Verification.** `boot_signals.py` passes 10 synthetic T0 tests. Its JSON output
was checked against per-record readings: the medians were recomputed from
`boot-signals.json`, and U-Boot ordering was checked across records. The token
set was read with `grep -a` from the installed 1.57.0 host package in the Lima
VM, and only token names were printed. The "not observed" statements cover the
62 incomplete records, not any reference boot. The acceptance criterion stays
open because `VIRTUAL_DEVICE_BOOT_COMPLETED` has no timing.

## IR-271: Assign the plain sh console clause to the serial shell

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064; the serial shell belongs to #014 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064 (step 2 and acceptance criterion 4); [M01](issues/M01-android-bring-up.md) #014 |

**Choice.** Keep the acceptance criterion "`guest-capture.txt` runs unchanged over
`adb shell` and over a plain `sh` console" open. Only syntax is checked: IR-186
parsed the list with the pinned `/system/bin/sh`. A live `adb shell` run needs a
booted guest (IR-269). The plain-console channel is the serial shell that step 2
assigns to #014. The maintainer should choose one of two options. Either move the
serial-console clause to #014, so #064 closes on the `adb shell` run once a boot
completes, or accept `adb exec-out` as the second channel, which step 2 also
names.

**Reason.** Step 2 names `adb shell` for #064 and the serial shell for #014. The
acceptance criterion names a plain `sh` console inside #064. Building the serial
path here would widen #064 into #014's scope (AGENTS.md §11).

**Verification.** Compared step 2 with the acceptance list in the entry. IR-186
covers syntax only. No console run was attempted, because no guest reached boot
completion (IR-269).

## IR-272: Run the G1 gate from a fast-forwarded local main worktree

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (G1 gate), #002 (formal closure) |
| Affected documents | [roadmap.md](../roadmap.md) §2 (G1); [M00](issues/M00-repository-and-vm-foundation.md) #003 acceptance; [workflow.md](../../05-development/workflow.md) |

**Choice.** The repository has no git remote, so the `main` merge that the G1
gate asks for cannot happen through a pull request. The local `main` branch was
fast-forwarded to the `codex` head (`bba2959`). It was an ancestor with no
divergence (394 commits ahead, 0 behind). The gate ran in a separate clean
worktree, `/tmp/apkrun-gate-main`, that was checked out on `main` after the
fast-forward. The worktree was not dirty, and its third-party sources were built
from the locked inputs with `scripts/build-third-party.sh virgl-runtime`. That
build did not reuse the tree's cache, which keys on the work directory. The G1
command was `scripts/run-gate.sh G1` with the lab Apple Development team and
identity from the environment. `codex` stays the working branch.

**Reason.** The gate definition requires a clean `main` checkout. With no remote,
the closest faithful substitute is a local fast-forward, which keeps the tree
state reproducible and is reversible. The `codex` branch remains the place where
work continues, so the user's branch layout does not change. A maintainer should
decide whether the local `main` should stay at this commit and whether the G1
evidence should be attached to a real gate issue.

**Verification.** The gate report is copied to `docs/04-plan/evidence/G1-bba2959-report.txt`. The worktree was removed after the run, when `codex` was renamed to `main`:
commit `bba2959eac29c778355149bb80311ae7932c5711`, Mac17,9, macOS 26A434,
`status: passed`, `exit_code: 0`. The LinuxGuest suite ran 29 tests with 0
failures. The G1 suite ran 5 tests with 0 failures and 1 configuration-scoped
skip, `testGuestResolvesDNSAndReachesExternalHTTPSProbe`, which belongs to the
Network configuration.

## IR-273: Require every ci.yml job, not only the four named in #062

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062 acceptance criteria 1 and 9 and step 7; [build-system.md](../05-development/build-system.md) §15.1; IR-021 |

**Choice.** Branch protection on `main` requires `workflow-policy` and every job
present in `ci.yml`: `lint`, `codegen`, `third-party`, `build`, `test-swift`,
`test-graphics`, and `test-images`. That is eight checks, not the five that #062
names.

**Reason.** §15.1 says every job present in `ci.yml` is required, and IR-021 says
a planned job becomes required when a later task adds it. Three jobs were added
after #062 (`third-party`, `test-graphics`, `test-images`). Requiring all of them
keeps a removed or skipped job from passing silently. One conflict is left for
the maintainer. `test-graphics` runs T1 tests (`GraphicsCoreSystemTests`) on a
hosted `xcode-27` VM, which the #062 pitfall says not to do, and it needs a Metal
device that a hosted image may not provide. The job fails with
`runnerMissingMetal` when the device is missing. If that is unacceptable, the job
should move to a real Mac and the required set should shrink to match.

**Verification.** `scripts/tests/run.sh` checks the `ci.yml` job set against the
seven names (`expected_jobs`). `scripts/tests/test_workflow_runners.rb` checks that
`lint`, `codegen`, `build`, and `test-swift` have no `if` or `paths` key, and that
pull requests and pushes to `main` carry no path filter. Branch protection itself
cannot be read here. The remote `origin` has no branches or workflows (IR-278).

## IR-274: Protect the notices generator and the lowercase test trees

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062 workflow section; [build-system.md](../05-development/build-system.md) §3.1, §15.1; IR-025 |

**Choice.** The policy checker's protected list adds
`scripts/release/generate-notices.py`. It also treats any `tests/` or `test/`
directory as a test tree, in addition to `Tests/` and `UITests/`.

**Reason.** `generate-notices.py` writes `ThirdPartyNotices.html`. CI's
`third-party` job runs it, and `check-release-build.sh` imports its `generate_html`
function to check the bundle. Before this change, a pull request could change the
generator without a reviewer, which could drop a notice while no protected path
changed. `Images/tools/tests` (run by pytest in `test-images`) and Gradle `src/test`
trees hold tests that CI runs, so an unreviewed edit could delete a failing test.
IR-025 names the test trees with capitalized names only. Extending the list to the
lowercase directories follows its intent, but it goes beyond the literal names and
makes more pull requests need `ci-policy-approved`. A maintainer may narrow it.

**Verification.** `scripts/tests/run.sh` asserts that the three new kinds of path
are protected, and that `scripts/release/notes.md` is not. Commit `82d5ad9` passed
`scripts/ci/run-checks.sh` in a worktree built from its staged state.

## IR-275: Keep run-checks.sh as an explicit list with a registration guard

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062 step 5; [build-system.md](../05-development/build-system.md) §3, §12 |

**Choice.** `scripts/ci/run-checks.sh` keeps its explicit list of checks instead of
running every `scripts/check-*.sh`. `scripts/tests/test_run_checks_coverage.sh`
fails when a `scripts/check-*.sh` is missing from that list. `check-compile-fail.sh`
is the only exception, because it is the manual T1 check.

**Reason.** Step 5 says the runner runs "every §3 script present in the tree". A
glob would also run checks that do not belong in lint. `check-compile-fail.sh`
needs a debug build on a Mac, and `check-launcher.sh` (#068) needs built products.
The explicit list plus the guard keeps the "present in the tree" guarantee without
that risk. A later task that adds a check must register it, and the guard fails
until it does.

**Verification.** `scripts/tests/test_run_checks_coverage.sh` passes on the tree and
rejects a fixture in which `check-beta.sh` is not registered. Commit `14fa271`
passed `scripts/ci/run-checks.sh` in a worktree built from its staged state.

## IR-276: Detect untracked codegen outputs in the three generated locations only

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062 step 5; [build-system.md](../05-development/build-system.md) §4 |

**Choice.** `scripts/ci/codegen.sh` fails when a file under one of the three
generated outputs is untracked and not ignored: `ErrorCatalog.generated.swift`,
`docs/03-reference/error-catalog.md`, and
`Packages/GuestProtocol/Sources/GuestProtocol/Generated/`. A new generator must add
its output path to the list in the script.

**Reason.** `git diff --exit-code` compares only tracked files, so a generated file
that no commit tracks passed codegen. The new fixture showed that before the fix. A
check over the whole tree would also fail on a developer's local scratch file. The
§4 table names the outputs, so the three paths are the documented ones. The
alternative, having each generator report what it wrote, would change the
generators.

**Verification.** `scripts/tests/test_codegen.sh` runs the real script in
disposable repositories: a clean tree passes, a committed stale output fails, and an
output that was never committed fails. Commit `5ff1d1f`. On the clean real tree at
`4a076a1`, `scripts/ci/codegen.sh` exited 0 on 2026-10-08.

## IR-277: Tick the policy and runner criteria on configuration and decision-logic evidence

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062 acceptance criteria 2, 3, and 13 |

**Choice.** Acceptance criteria 2 (control-file policy) and 3 (fork pull requests run
on hosted VMs, and no `pull_request` job uses a self-hosted runner) are ticked. Their
evidence is the offline decision fixtures of `scripts/ci/check-pr-control-changes.py`
and the workflow fixtures of `scripts/tests/test_workflow_runners.rb`. The live
parts stay with criterion 13: a fork run on GitHub and the negative pull request.

**Reason.** Both criteria describe what the checked-in workflows and the checker
decide. The decision fixtures cover each event: commit, reopen, edit, label,
unlabel, withdrawn approval, and base change. The workflow fixture checks the
trigger types and the hosted runner labels. The live GitHub behavior cannot be
tested here, because the remote has no workflows and this task does not push.
Branch protection that makes `workflow-policy` required is part of criterion 1,
which stays open. A maintainer should confirm this reading. If the maintainer wants
a live fork run for criterion 3, that criterion should be reopened.

**Verification.** On `4a076a1`, `scripts/tests/run.sh` passed its 16 policy decision
fixtures, and `scripts/tests/test_check_pr_control_context.py` passed its 5 context
fixtures. `scripts/tests/test_workflow_runners.rb` printed 9 PASS lines, one per
rule and fixture. The counts are in the #062 Notes.

## IR-278: Record that origin exists but holds no branches or workflows

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062 Notes; [issues/README.md](issues/README.md) §5; IR-021; IR-272 |

**Choice.** The #062 brief and IR-021 say this checkout has no Git remote. It does
have `origin`, set to `https://github.com/uakihir0/apkrun`. Read-only `gh` queries
on 2026-10-08 found no branches, no workflows, no `ci-policy-approved` label, and no
open pull requests, and `main` returns "Branch not found". This task did not push
and did not change any remote setting. The #062 Notes and the progress row describe
the remote as empty, not absent.

**Reason.** The live GitHub run, branch protection, and the negative pull request
cannot be verified until a branch is pushed, and the brief forbids pushing here.
Recording the actual state lets the maintainer confirm that this is the intended
remote before anything is pushed.

**Verification.** `git remote -v` lists `origin`. `gh api repos/uakihir0/apkrun/branches`
returned no branch names. `gh api repos/uakihir0/apkrun/actions/workflows` returned
no workflows. `gh api repos/uakihir0/apkrun/labels` returned ten GitHub default
labels and no `ci-policy-approved`. `gh api repos/uakihir0/apkrun/pulls?state=open`
returned zero pull requests.

## IR-279: Classify the default-profile stall as guest-side Watchdog kills

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | [M01](issues/M01-android-bring-up.md) #064 Notes; [progress snapshot](issues/README.md) §5; `Images/reference/16373615/incomplete/default-20261008-diagnosis.txt` |

**Choice.** Record the `default` profile's stall as a guest-side failure. Each
`system_server` start was killed by its own Watchdog after the main thread
stopped answering a handler check for about 185 seconds. The `swiftshader`
profile has the same GPU mode and an identical bootconfig, so it is taken to
stop the same way, but it was not re-run. #064 stays open. No profile is
published, and the Android image and `capture.sh` are not changed.

**Reason.** Two live runs, one with a 600-second deadline and one with 3000
seconds, separate the candidate causes. The host did not stall: vCPU threads
ran, and crosvm memory stayed near 4.2 GiB after its first minute. The
SurfaceFlinger EGL abort seen in `target` did not occur: SurfaceFlinger
initialized ANGLE on SwiftShader and started the boot animation. Zygote did not
hang: its preload finished at guest uptime 863 seconds in the 3000-second run,
and system_server was entered at 909 seconds. The 600-second run ended during
preload, so its missing boot is explained by the deadline. The two Watchdog
kills on the main thread were at different code paths: in cycle 1 the top
annotated frame was `ArtManagerLocal$Injector.getDexoptHelper`, and in cycle 2
it was `FakeSoundTriggerHal.createDefaultProperties`, after `StartAudioService`
took 54,296 ms. A varying block location points to a slow main thread, not one
deadlock. The root cause of the slowness is not established.

**Verification.** The receipt lists the guest timeline (`boot_progress_*`,
Watchdog kill lines, `SystemServerTiming`) for both runs, with SHA-256 values
for their normalized files. The 2026-10-08 `default` records contain no host-path
pattern (`/home/lima`, `/var/tmp/cvd`, `/tmp/apkrun`, `/Users/`). The
observer's crosvm samples were checked directly: 118 in the 600-second run and
about 120 in the 3000-second run. Its earlier apparent `candidateCount` of zero
came from the first lines of the file, not from a failure of the observer. The
guest debugging routes (`adb root`, `debuggerd`, `/data/anr` traces) were
refused because `ro.secure=1`, so Java thread stacks were not obtained.

## IR-280: Keep raw diagnostic records outside git and use instance 2

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/default-20261008-diagnosis.txt`; [M01](issues/M01-android-bring-up.md) #064 Notes |

**Choice.** Three operational choices were made for the diagnostic runs.

1. The raw records (3.2 MB and 15 MB, including host logcat up to 13.7 MB) stay
   out of git. Only a receipt with hashes and timings is committed. The records
   are kept in the local store named in the receipt's setup section.
2. Instance 2 was used, and the stale instance-1 group
   `apkrun_target_whuuql` (status `Starting`, left from the 2026-10-07 target
   run) was not removed.
3. The deadline was 3000 seconds, with the boot observer enabled. This matches
   the earlier long unpaused run and covers three `system_server` cycles.

The branch named in the brief, `codex`, no longer exists. The reflog shows it
was renamed to `main` at `d98823f`, which this task did not do. The commits
therefore land on `main`, with no new branch created.

**Reason.** The brief and AGENTS.md §9 say large or raw captures stay out of
git. The stale group is a registry entry that blocks instance 1
(`cvd fleet` reports it), and removing it would change a shared host state the
earlier reports chose to preserve. A 3000-second run is the comparison point
for the earlier long run. Committing to `main` follows the brief's instruction
not to create branches; the rename itself is not reverted.

**Verification.** `cvd fleet` shows the stale group on instance 1 and nothing
on instance 2 after each run. Both raw records and a `SHA256SUMS.txt` manifest
are in the local store, and `git status` shows only the receipt and the
entries recorded here.

## IR-281: Route production log entries to the category that wrote them

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (acceptance: every transition logged under `io.apkrun.vm`, category `lifecycle`); #061 (DiagnosticsCore owner) |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #003 acceptance criterion 8; [diagnostics.md](../02-design/diagnostics.md) §3 |

**Choice.** `DiagnosticsContext.live` now uses `RoutingOSLogSink`. It keeps one
`OSLogSink` per subsystem and category, and writes each entry to the destination
that `APKLogger` recorded in it. `APKLogger`'s default path keeps the
fixed-destination `OSLogSink`. The routing sink reports every level as enabled,
because the destination is not known when the level is checked, so the level
gate of `OSLogSink.isEnabled` does not apply on this path.

**Reason.** The live context gave every logger one `OSLogSink` fixed to
`io.apkrun.diagnostics` and category `health`. `APKLogger` had already put each
entry's subsystem and category into `LogEntry`, and `OSLogSink.write` ignored
them. The signed LinuxGuest run at `d98823f` printed `[health] VM state changed`
lines, so the unified log did not show VM lifecycle entries under
`io.apkrun.vm` / `lifecycle`. The T0 tests passed because `RecordingLogSink`
keeps the metadata. The defect affected every subsystem that used the live
context, not only VM. A sink injected per controller was rejected, because the
other loggers would stay mis-filed.

**Verification.** `OSLogRoutingTests` (two T0 tests) passed, and the
`DiagnosticsCore` SwiftPM filter passed. The signed `LinuxGuest` suite at
`ef9b729` passed 29 of 29 and printed 87 `[lifecycle] VM state changed` lines.
`log stream --predicate 'subsystem == "io.apkrun.vm"'` during `apkrun dev linux`
at `ef9b729` printed `[io.apkrun.vm:lifecycle] VM state changed from stopped to
starting op=e7ea405d`, and the stop had its own operation ID. `scripts/check-logging.sh`
passed.

## IR-282: Create validation and identifier VZ objects on a VM queue

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (acceptance: VZ objects created and called only on `io.apkrun.vm.queue`); #002 (code owner) |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #003 acceptance criterion 6; [vm.md](../02-design/vm.md) §4; [AGENTS.md](../../AGENTS.md) §6.2 |

**Choice.** The live framework validator, the machine-identifier check in
`VMDefinitionValidator`, and `MachineIdentity` run their VZ work through
`VMQueue().performSynchronously`. Each call creates a private queue with the
label `io.apkrun.vm.queue` and waits for the result. The #002 public API does
not change. Class-level queries that create no VZ object stay on the caller's
thread: `VZVirtualMachine.isSupported` in `VMHealthChecks`, and the CPU and
memory limits in `LiveVMHostEnvironment`.

**Reason.** Before this change, `VZFrameworkConfigurationValidator.validate`
built and validated a `VZVirtualMachineConfiguration` on the caller's thread.
`MachineIdentity` and the identifier check created `VZGenericMachineIdentifier`
and `VZMACAddress` there. No controller exists while validation runs, so the
controller's queue cannot serve it. Making validation `async` would change the
#002 API and every caller. The per-call queue keeps the rule literal for VZ
objects. The class-level queries are not VZ objects.

**Verification.** `VMQueueTests` (two T0 tests) passed. `swift test --filter
VirtualMachineCore` passed 114 `VirtualMachineCoreTests` and 25
`VirtualMachineCoreSystemTests`, including the live validator path. The signed
`LinuxGuest` suite at `ef9b729` passed 29 of 29, and every T2 test validates
through the live validator. The `apkrun dev linux` smoke at `ef9b729` exited 0.

## IR-283: Keep the G1 reference-Mac criterion open

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (acceptance: G1 on the reference Mac with a clean build from `main`, evidence attached to the gate issue); OQ-02 |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #003 acceptance criterion 5; [open-questions.md](../open-questions.md) OQ-02; [roadmap.md](../roadmap.md) §2 |

**Choice.** Criterion 5 stays open. The G1 passes are recorded as evidence, not
as closure. The `scripts/run-gate.sh G1` pass at `bba2959` (IR-272) and the
signed G1 test-plan run at `ef9b729` both ran on Mac17,9 (macOS 26A434). The
second run came from the `codex` branch, not from `main`. The evidence has not
been attached to a gate issue.

**Reason.** The criterion names the reference Mac. OQ-02 is still open, and its
working proposal is the lowest-tier lab Mac (M1 with 16 GB,
[diagnostics.md](../../02-design/diagnostics.md) §9.4). Mac17,9 is not that
proposal, and no record names it as the reference. Creating a gate issue needs
GitHub access, which this session does not have (IR-278). A pass on another Mac
supports G1, but it does not meet the box. A maintainer should decide the
reference Mac under OQ-02, and the gate should then run there from a clean
`main` checkout.

**Verification.** The G1 report at `build/gates/G1/report.txt` in the `/tmp`
gate worktree shows commit `bba2959`, Mac17,9, macOS 26A434, and
`status: passed`. On `ef9b729`, `xcodebuild test -scheme AcceptanceTests
-testPlan AcceptanceTests -only-test-configuration G1` executed 5 tests, with 1
configuration-scoped skip and 0 failures. `testTenBootsStopThroughTheGuestPowerButton`
passed in 3.079 s, and `testFailedStartCanBeReset` passed.

## IR-284: Accept the no-nil-state audit as evidence for the state criterion

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (acceptance: no state is inferred from a nil `VZVirtualMachine`) |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #003 acceptance criterion 7; [AGENTS.md](../../AGENTS.md) §6.2; [state-machines.md](../01-architecture/state-machines.md) §1 |

**Choice.** Criterion 7 is ticked on a code audit, not on a test. `VMController.state`
is assigned in one place, `transition(to:source:)`, and that function logs every
change. The `driver` optional works only as a resource handle. The five
`guard let driver` sites (`pause`, `resume`, `stop`, `requestGuestStop`, and
`connect`) follow an explicit state check. A nil driver there is an invariant
violation (`assertionFailure`), not a state. In the forced-stop path,
`releaseResources()` clears `driver` while the state is still `stopping`, as
[vm.md](../02-design/vm.md) §9.2 describes. No driver guard can run in that
window, because the active public operation blocks other lifecycle calls and
`connect` requires `running`.

**Reason.** No test can show that a state is not inferred from nil, because a nil
driver never changes `state`. Such a test would have to exercise an internal
path that cannot occur. The audit covers every code path that can clear
`driver`. A maintainer should confirm that this reading of the criterion is the
intended one.

**Verification.** On `ef9b729`, `grep` found `state =` only at the initializer
and in `transition`, and `guard let driver` only at the five sites above and in
`await driver?.release()`. The signed `LinuxGuest` suite at `ef9b729` passed
29 of 29, including the stop, forced-stop, and failed-start paths.

## IR-285: Accept a clean-clone repeat as the reproducibility evidence

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (acceptance: pinned by SHA-256 in the lock; the scripts produce the same artifacts on a clean clone) |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #003 acceptance criterion 10; [build-system.md](../../05-development/build-system.md) §6.1; [vm.md](../02-design/vm.md) §12 |

**Choice.** Criterion 10 is ticked. The kernel package, the minirootfs, and the
socat, libgpiod, and runtime packages are pinned by SHA-256 in
`ThirdParty.lock.json`, and `fetch-test-linux.sh` checks each one. The
reproducibility evidence is a fresh clone of `d98823f`, where both scripts ran
twice into an empty directory. The hashes of `Image` and `initramfs.cpio.gz`
matched across the two runs and matched the artifacts that the signed T2 runs
used. The built initramfs and the extracted `Image` are outputs, not lock
entries. The lock pins their inputs.

**Reason.** NFR-DEV-01 pins the inputs of the test guest, and the criterion asks
that the scripts reproduce the same artifacts. A clean clone with repeated runs
shows that reproduction. [vm.md](../02-design/vm.md) §17 records a different
initramfs hash for #005 (`0f50…`). This check does not explain that difference,
and it is not a reproducibility failure for the current inputs. Whether the
outputs should also be pinned is a separate decision for the maintainer.

**Verification.** `git clone` of `d98823f` into `/tmp/apkrun-003-clone`, then
`scripts/fetch-test-linux.sh` and `scripts/build-test-initramfs.sh` with
`APKRUN_TEST_LINUX_DIR` set to an empty `/tmp` directory, twice. Both runs gave
`Image` `e31110ab…bbc4` and `initramfs.cpio.gz` `d1d1273e…705c`. These hashes
equal `/tmp/apkrun-test-linux`. The second run verified all 16 locked packages
without downloading them again.

## IR-286: Record the missing stderr copy of failing lines in apkrun dev linux

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (step 8: failing lines on stderr; acceptance box for `apkrun-dev dev linux`) |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #003 step 8; [cli.md](../../02-design/cli.md) §5 |

**Choice.** The `apkrun-dev dev linux` acceptance box is ticked. Step 8 says a
failing run "prints the failing lines on stderr and exits 1". The
implementation streams the console, including the
`APKRUN-TEST: <name> fail <detail>` line, to stdout. Stderr gets only the
catalog error `runtime.devLinuxCheckFailed` and a hint to check the console
output. The step-8 stderr copy is recorded as a gap and is not fixed in this task.

**Reason.** The box asks for live output, exit 0 only when every requested check
printed `ok`, and exit 75 under the instance lock. The implementation meets all
three. The smallest fix needs the failing record in the CLI. The CLI does not
import RuntimeCore (AGENTS §6.1), so the fix is a failing-check case on
`DevLinuxEvent` in RuntimeHost, which the CLI then writes to stderr. That changes
the event model of an embedded-only facade. A maintainer should decide whether
step 8's stderr copy is required before #003 closes.

**Verification.** `apkrun dev linux --tests nosuchcheck` at `ef9b729` exited 1
with `runtime.devLinuxCheckFailed`. Stdout contained
`APKRUN-TEST: nosuchcheck fail unsupported test in this guest build`, and stderr
had only the catalog error and the hint.

## IR-287: Record the 8-vCPU default variant as a repeat, not a CPU test

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/default-20261008-diagnosis.txt` (repeat run section); [M01](issues/M01-android-bring-up.md) #064 Notes |

**Choice.** Treat the run intended as an 8-vCPU variant as a repeat of the
4-vCPU `default` profile. Its record is kept as a diagnostic repeat, and its
result is reported as run-to-run variance. The vCPU-count hypothesis stays open.
A retry must pass the count to `cvd start` as well as `cvd create`, and confirm
`cpus` in the saved configuration before its result is read.

**Reason.** The scratch copy changed `cvd create --cpus` from 4 to 8, but the
saved configuration and the launcher log both record 4 vCPUs (`"cpus" : 4`,
`--cpus=4`). Interpreting the run as a CPU-count test would be wrong. The repeat
is still useful: under the same flags, its zygote start came at guest uptime
466 seconds, against 233 seconds in E1, and PackageManager became ready at 2473
seconds, against 1467 seconds. So the 4-vCPU timeline varies by about 1.7 times
between runs, and any single-run timing in the diagnosis carries that spread.

**Verification.** `cuttlefish_config.json` and `launcher.log` of the record
were read directly: `"cpus" : 4` at line 103, and `--cpus=4` at launcher lines
1690 and 1762. The E2 and E1 boot markers come from each run's `host-logcat.txt`
(`boot_progress_*` and `SystemServer` lines). E2 reached PackageManager scanning
at the 3000-second deadline, so it recorded no Watchdog kill. The record's
SHA-256 values are in the local store manifest described in the receipt.

## IR-288: Download the Metal toolchain in bootstrap when it is missing

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 (hosted `lint`, `codegen`, and `third-party` jobs); #001 (bootstrap) |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2; [build-system.md](../05-development/build-system.md) §15 |

**Choice.** `scripts/bootstrap` now runs `xcodebuild -downloadComponent MetalToolchain`
when `xcrun --find metal` and `metallib` are missing, and then checks again. The
download is attempted only when a tool is absent, so a machine that already has
the toolchain sees no change. The download is not a CI-only step. It runs for
local developers too, because the same script defines their setup.

**Reason.** The first hosted run of CI on `main` failed the `Install pinned repository
tools` step in `lint`, `codegen`, and `third-party`. The hosted `xcode-27` image does
not ship the Metal toolchain, which Xcode 27 installs as a separate component.
Putting the fix in the shared bootstrap covers every job at once. A CI-only step
would leave local setup able to fail the same way.

**Verification.** On this Mac, `scripts/bootstrap` exits 0 with
`ok Metal toolchain: Apple metal version 32023.921`. The hosted result is in the
next CI run on `main` after this commit. The earlier failure is run
37748879197, jobs `lint`, `codegen`, and `third-party`.

## IR-289: Run the swiftshader repeat with a 2100-second deadline

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/default-20261008-diagnosis.txt` (swiftshader section); [M01](issues/M01-android-bring-up.md) #064 Notes |

**Choice.** The `swiftshader` profile was run once with the unchanged tools, a
2100-second boot deadline, instance 2, and the boot observer. The record is
diagnostic and is not published. The deadline is shorter than the 3000-second
`default` runs.

**Reason.** The session time budget ended before a 3000-second run could
finish. The 2100-second deadline still covers the point where the first
`system_server` was killed in the `default` run, at uptime 1846 seconds.
This choice shortens the observation window, so the record shows the kill and
the start of a second cycle, not a full boot attempt.

**Verification.** The record's `host.json` records `selectedGpuMode=guest_swiftshader`
and `gpuVhostUserEnabled=false`, and `cuttlefish_config.json` records 4 vCPUs.
Its kernel log shows the Watchdog sysrq dump at uptime 1512 to 1514 seconds and
zygote's SIGKILL at 1528.9 seconds. A second system_server was active by 1788
seconds. The retained `host-logcat.txt` ends before the kill, so the kill is
evidenced by the kernel log. Cleanup left no crosvm, run_cvd, or ADB device.

## IR-290: Inject the virtualization probe in the network health test

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 (CI) |
| Affected files | `Packages/VirtualMachineCore/Tests/VirtualMachineCoreTests/VMHealthChecksTests.swift` |

**Choice.** `vmNetworkHealthWarnsOnDisconnectAndResetsAfterRestart` passes
`virtualizationSupported: { true }` to `VMHealthChecks.register`, as the sibling
test `vmStateHealthCheckReportsCataloguedFailure` already does. The production
default, `VZVirtualMachine.isSupported`, is unchanged.

**Reason.** The hosted `test-swift` job failed at line 95, where
`HealthVerdict.evaluate` returned `.hostUnsupported` instead of `.degraded`. The
test registers only the VM checks, so that verdict needs a failed
`vm.virtualizationSupported` check. The real probe therefore returned false on
the hosted runner. The assertion is about the network verdict, so the runner's
virtualization support must not decide it.

**Verification.** The test passes locally. With the probe forced to `false`, it
fails at line 95 with `.hostUnsupported`, the same failure as CI run
37754807446, job `test-swift`.

## IR-291: Give the host-check tests a generous health-check budget

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 (CI) |
| Affected files | `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTestSupport/DiagnosticsContext+Testing.swift`; `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/HostChecksTests.swift` |

**Choice.** `DiagnosticsContext.testing` takes a `healthTimeouts` parameter that
defaults to `.standard`. The host-check helper `runHostChecks` passes quick and
deep budgets of 30 and 60 seconds. The production budgets, and every other
caller of `DiagnosticsContext.testing`, keep the 2-second quick budget.

**Reason.** The hosted run failed `hostChecksProducePassingResultsFromInjectedProbe`
at line 9. Every host check in that test reads only the injected probe and
`BuildInfo.current`, which the test compares with itself. The only remaining
way to get a non-pass result is the registry's timeout path, which reports a
`warning` with "check timed out". That budget is 2 seconds of wall-clock time.
During this batch the hosted test process stalled for about 11 seconds, as the
other tests of the batch show (for example `operationContextPropagatesToChildTasks`
took 11.3 seconds). A check can miss a 2-second budget in that state, and the
test then reports the runner's scheduling as a host failure.

**Verification.** The test passes locally. With the quick budget forced to 1 ms,
it fails at line 9 with the same expectation as CI run 37754807446, job
`test-swift`. The three other host-check tests in the file use the same helper.

## IR-292: Stamp the unseen-rows log fixture ahead of the clock

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 (CI) |
| Affected files | `Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/LogReaderTests.swift` |

**Choice.** `logReaderAcceptsUnseenRowsAtTheExistingTimestampBoundary` stamps its
boundary and catch-up rows one minute after the test starts. The reader and its
window rules are unchanged. The one-minute offset is a fixture value, not a log
timestamp a real `log show` would return.

**Reason.** The hosted run delivered 1 entry where the test expects 5001. The fake
catch-up runner ignores `--start`, but `LogRecordAccumulator` applies the
`startingAt` filter to every row. That start is `floor(lastCoverageTime) - 1`, and
`lastCoverageTime` is set when the fake stream returns. A row stamped at test start
is dropped once that checkpoint reaches two seconds past the row's whole-second
stamp. The hosted process ran this test for 24.7 seconds, which allowed that gap.
Local runs finish the stream within a second, so the window never excluded the rows.

**Verification.** With the rows stamped 5 seconds in the past, the test fails with
`recorder.entries.count → 1`, the count reported by CI. With the offset in place it
passes locally. The other boundary tests in this file use the same wall-clock stamp.
They passed on the hosted run and are not changed.

## IR-293: Mirror tasks #001–#097 as issues #2–#98

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 (repository process), all tasks |
| Affected documents | [issues/README.md](issues/README.md) §4; [workflow.md](../05-development/workflow.md) §2.4; `.github/ISSUE_TEMPLATE/task.md` |

**Choice.** The 97 task issues were created in number order, from the milestone
files, with the `task` label and the title `#NNN Title`. Each body holds the
field table and the Goal of its entry, with a link to the entry in the repository.
GitHub numbered them #2 to #98, so task `#NNN` is issue `#(NNN+1)`. The title
keeps the task number, so the mapping is visible.

**Reason.** The workflow asks that issue numbers equal task numbers, and that
#001–#097 come before any other issue or pull request. A closed negative-test pull
request (#1) had already used number 1 before this step, so the offset cannot be
removed. The milestone files stay the source of truth, and the title makes the
mapping explicit. The offset is caused by my negative-test pull request, which
was opened for #062 criterion 13.

**Verification.** `gh issue list` returns 97 issues before any new issue. Issue #2
is titled `#001 Bootstrap Xcode workspace`, and #98 is `#097 Google Play authority`.
The G1 evidence is attached to issue #4, `#003 Boot minimal ARM64 Linux`.

## IR-294: Branch protection on main requires the eight CI checks

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062 (acceptance criterion 1) |
| Affected documents | [M00](issues/M00-repository-and-vm-foundation.md) #062; [IR-273](#ir-273-require-every-ciyml-job-not-only-the-four-named-in-062) |

**Choice.** Branch protection on `main` requires the eight checks of IR-273:
`workflow-policy`, `lint`, `codegen`, `third-party`, `build`, `test-swift`,
`test-graphics`, and `test-images`. Force pushes and branch deletion are
disallowed. Administrators are not blocked (`enforce_admins` is false), and no
pull-request review is required.

**Reason.** The repository has one maintainer, who cannot approve their own
pull request. Requiring reviews would stop all merges. Without the
`enforce_admins` exception, the same protection would also stop the direct
pushes this work uses. The control-file policy in `workflow-policy` still covers
changes to CI files, through the `ci-policy-approved` label. A maintainer may
prefer a required review once a second maintainer exists.

**Verification.** `gh api PUT repos/uakihir0/apkrun/branches/main/protection`
returned the eight contexts, `enforce_admins: false`, and `allow_force_pushes: false`.
The protected-file policy fails as designed on pull request #1
(run `37771569527`).

## IR-295: Do not register a self-hosted runner on this Mac

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #062; #003 (acceptance `linux-guest`); #064 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §4; [build-system.md](../05-development/build-system.md) §15; `.github/workflows/integration.yml`, `nightly.yml` |

**Choice.** The lab workflows (`Integration tests`, and the nightly gates
`gates` and `network`) need self-hosted runners with the labels `apkrun-lab` and
`apkrun-reference`. No such runner is registered. This Mac is not registered
either. The queued `Integration tests` run is cancelled, so it does not stay
queued for a day, and the nightly lab jobs are left as they are.

**Reason.** The repository is public. A self-hosted runner executes the code of
the workflow it is given, on a personal Mac that holds signing material and the
lab certificate. Forked or changed workflows could reach it. The docs say
persistent self-hosted runners stay disconnected until the owner can enforce
workflow restrictions ([#062](issues/M00-repository-and-vm-foundation.md)
Risks). A dedicated, isolated lab machine is the safer place for those runners.

**Consequence.** #003's acceptance box for the `linux-guest` job stays open. The
T2 result for the reviewed commit is linked from the #003 issue instead. The
nightly `gates` job for G1 cannot run until a runner exists.

## IR-296: Accept the Android SDK license on this Mac for the pinned packages

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #033 (Kotlin guest modules); #015 (JDK and Android SDK in bootstrap) |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2 |

**Choice.** The `sdkmanager` license was accepted on this Mac, for
`platforms;android-37.0` and `build-tools;37.0.0`. The SDK sits in the git-ignored
`build/android-sdk`. Nothing else was installed, and the `~/.android` directories
the tool created on its first run were removed.

**Reason.** The Kotlin guest modules of #033 need the Android platform to compile.
The license is the Android SDK's own, and the lab machine needs it for the
Android tasks anyway. Accepting it is a consent given on the user's behalf, so it
is recorded here for review. Deleting `build/android-sdk` withdraws the
installation. The license is not re-accepted anywhere else.

## IR-297: Close #002 and #003 with the maintainer review still open

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #002, #003 |
| Affected documents | [issues/README.md](issues/README.md) §5; [M00](issues/M00-repository-and-vm-foundation.md) #002, #003 |

**Choice.** #002 is closed as implemented and accepted. Its one hard dependency,
#061 step 4, is on `main`, because `main` is now the working line. #003 is closed
as implemented, with the G1 gate passed, and its acceptance boxes are ticked except
the `linux-guest` box (IR-295). The maintainer review items of each task remain
open: IR-242 for #002, and IR-243 with IR-044 and IR-241 for #003.

**Reason.** The hook's acceptance rule is met by the evidence. The reviews are
judgment calls that a maintainer should confirm, and they do not block the next
tasks. Keeping the tasks formally open would only hold back the Android chain,
which depends on them.

## IR-298: Run the #064 boot ladder as bounded single-variant runs

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 (and #014) |
| Affected files | [M01](issues/M01-android-bring-up.md) #064 and #014 Notes; `Experiments/cuttlefish-boot-diagnosis/boot_variant.sh`; `Images/reference/16373615/incomplete/ladder-064-20261008.txt` |

**Choice.** Each ladder step is one bounded run of the `default` flags of
android-image.md §8.2 with one variant flag passed to both `cvd create` and
`cvd start`. The runner is `Experiments/cuttlefish-boot-diagnosis/boot_variant.sh`.
It uses instance 2 and copies the pinned product directory before launch, verifies
the copy against the checked-in manifest, and never writes the pinned files. Only
a summary receipt is committed. The raw logs stay in the guest and are deleted.

**Reason.** The existing `capture.sh` and the Experiments harness are fixed to
the 2026-10-01 baseline. The harness accepts only 2048 or 4096 MiB, and
`capture.sh` fixes four guest CPUs and the GPU mode. Testing 8 GiB, eight vCPUs,
or audio off would widen either tool beyond this task. A small runner keeps each
run to one changed flag, and it records the saved configuration so a flag that
does not reach the saved file is visible.

**Verification.** Each run verified 10 product artifacts against the manifest
before launch. Saved configuration was checked for `gpu_mode=none` with 4096 MiB,
4 CPUs, and `enable_gpu_vhost_user=False`. The first runs wrote their receipts
inside the guest, which rebooted at 22:50 and cleared its `/tmp` before the
receipts were copied. Those raw receipts are lost. The summary receipt keeps only
the values printed in the session, and it says so. Two runner defects were found
and fixed after the first run: the instance logs live under `/var/tmp/cvd`, not
under `--base_directory`, and an unset `sys.boot_completed` was recorded as
`none`. Cleanup after the first two runs left no crosvm and no work directory. The
8-vCPU run did not (IR-302).

## IR-299: Record the 8 GiB, four-vCPU run as not booted within 2400 seconds

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/ladder-064-20261008.txt` (step 1a); [M01](issues/M01-android-bring-up.md) #064 Notes |

**Choice.** Record the `--memory_mb 8192` run (create and start, four vCPUs, 2400
seconds) as a non-booting diagnostic variant. Do not attribute the stall to
memory size. The U-Boot-to-Linux comparison of IR-138 is unchanged.

**Reason.** Guest memory was the first lever of the ladder. The run reached its
deadline. adb answered `device` from 866 seconds, but `sys.boot_completed` stayed
unset in every poll. crosvm RSS reached its plateau at 8.24 GiB at about 436
seconds, which shows the guest used its full memory. The live kernel log showed
zygote starting at guest uptime 160.1 seconds, and it showed no Watchdog line at
the last check (guest uptime about 1950 seconds). That is earlier than the
233-second zygote start of E1 but still not boot. Whether memory size shortens the
slow startup is not settled by one run.

**Verification.** The runner's poll output (adb state, unset property, RSS per 15
seconds) and the live kernel-log reads are summarized in step 1a. The saved
configuration of this run was not recorded, because the first runner did not read
the instance logs; `memory_mb` was passed to both commands but not verified in the
saved file. The raw receipt is lost (IR-298).

## IR-300: Record `--gpu_mode=none` as blocked before the Android guest starts

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 |
| Affected files | `Images/reference/16373615/incomplete/ladder-064-20261008.txt` (step 1b); [M01](issues/M01-android-bring-up.md) #014 step 2 |

**Choice.** Treat `--gpu_mode=none` as blocked for this host package and
configuration. Do not use it as the #014 headless profile until its launch is
unblocked. The run was stopped after about nine minutes rather than at its
2400-second deadline.

**Reason.** The design's M1 headless profile (#014 step 2) needs a headless boot.
In this run the kernel log stayed at 0 bytes, and the Android crosvm had one
thread, asleep in a tun-device read since its start (16.6 MB RSS). Earlier
`gpu_mode=none` records stopped at 600 seconds with an empty kernel log (IR-112
and IR-113), so this matches them and is not new evidence of a boot result. Running
to the deadline would have cost about 30 minutes without new information.

**Verification.** The saved configuration recorded `gpu_mode=none`, 4096 MiB, 4
CPUs, and `enable_gpu_vhost_user=False`. The thread count and wait channel were
read from procfs. Cleanup left no crosvm process. The tun descriptor that the
Android crosvm waits on was not identified; this is the next #014 question.

## IR-301: Find no host-settable key for the Watchdog timeout

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 |
| Affected files | `Images/reference/16373615/incomplete/ladder-064-20261008.txt` (step 2); [M01](issues/M01-android-bring-up.md) #014 |

**Choice.** Do not add any bootconfig or kernel-command-line key for the
`system_server` Watchdog or the ART first-boot work. The reference boot keeps the
keys of android-image.md §6.2.

**Reason.** The brief asked whether the Watchdog or ART first-boot work reads a
key that the host can set. The pinned system partition was read from the pinned
`super.img` into a private copy, read-only, and `framework/services.jar` was
searched. The jar contains `WatchdogTimeoutMillis` and
`system_server_watchdog_timeout_ms`. The second is an AOSP DeviceConfig key; this
jar does not show which class reads it, so that is not verified here. The jar
has `persist.debug.framework_watchdog.*` strings, which belong to PackageWatchdog,
not to the system_server kill. The jar has no Watchdog-specific `ro.boot.*` or
`androidboot.*` key. It reads `ro.debuggable` and `ro.secure`, but no link to the
kill path was found. The dexopt strings are `dalvik.vm.*` and `pm.dexopt`, which
host bootconfig cannot set. Changing the DeviceConfig value needs guest data
written before first boot, which is guest state and outside the launch-option
scope of this ladder.

**Verification.** The `services.jar` string search covered the `classes*.dex`
files of the extracted jar. The system partition extraction read one linear
extent (959,066,112 bytes) from the pinned super image and wrote only to a private
copy. Nothing was written into the repository, and no guest run was needed. The
search is by string, not by call graph, so a missed reader cannot be excluded.

## IR-302: Record the 8-vCPU run and the runner's cleanup gap

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 |
| Affected files | `Images/reference/16373615/incomplete/variant-cpus8-20261008T135241Z.txt`; `Images/reference/16373615/incomplete/ladder-064-20261008.txt` (step 1d); `Experiments/cuttlefish-boot-diagnosis/boot_variant.sh` |

**Choice.** Record the eight-vCPU run (`--cpus 8` on create and start, 4096 MiB,
1800 seconds) as a non-booting diagnostic variant. It answers IR-287's question
for this runner: the saved configuration records eight CPUs, so the earlier E2
result (IR-287) was not a CPU test, and this is one. The runner's launch path is
unchanged. Its cleanup sweep is not fixed in this pass, so the next run must stop
the group by its runtime path and verify that nothing remains.

**Reason.** The E2 record failed to apply the CPU count, so the CPU hypothesis
stayed open. This run applied it: the saved configuration records `cpus=8`. The
kernel log reached `starting service 'zygote'` at 215.7 seconds, against 233.0
seconds in E1 at 4 GiB and four vCPUs. The display marker appeared at 696.4
seconds. adb answered from about 800 seconds, but `sys.boot_completed` stayed
unset. The run ended at its deadline without a Watchdog kill. The cleanup gap is
separate: `cvd remove` returned 0, while a crosvm process and `secure_env` of the
group survived the runner's TERM and KILL sweep. The runner matched processes by
the private work path. A likely cause, not verified, is that the `process_restarter`
restarted crosvm after the kill. The two survivors were stopped by hand after the
runner finished, and afterwards no crosvm or group process remained.

**Verification.** The receipt holds the saved configuration, the kernel-log marker
counts, the per-poll adb and RSS record, and the cleanup result. Its paths are
placeholders, and a scan found no host path, `/tmp` path, or `/var/tmp` path. The
manual stop is recorded in the receipt's cleanup section, not hidden. The ladder
receipt lists the lost first-run receipts (IR-298).

## IR-303: Close the final attempt with #064 open

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064 (and #014) |
| Affected files | `Images/reference/16373615/incomplete/final-step1-watchdog-dumps-20261009.txt`; `Images/reference/16373615/incomplete/final-step2-device-config-20261009.txt`; `Images/reference/16373615/incomplete/final-default-run-20261009.txt`; `Experiments/cuttlefish-boot-diagnosis/boot_variant.sh`; [M01](issues/M01-android-bring-up.md) #064 |

**Choice.** Keep #064 open. No option reached `sys.boot_completed=1`, and no
profile is publishable. Steps 1 and 2 of the final attempt are closed as
refused, and step 3 was not applicable. #014 stays open too.

1. The Watchdog's own dump files are not readable as the shell user. `/data/anr`
   lists two files, both owned by `system` or `tombstoned` with no read for
   `shell`. `cat` returns `Permission denied`. `/data/system/dropbox` returns
   `Permission denied`, and `dumpsys dropbox` reports the service absent. The
   logcat lines remain readable. No privilege was requested.
2. `cmd device_config put system_performance system_server_watchdog_timeout_ms
   600000` is refused for the shell user. The response is a
   `SecurityException`: the flag is not on the DeviceConfig allowlist. The
   `activity_manager` namespace gives the same refusal. The write was not made,
   so `get` returns `null`.
3. Not run, because (2) was not accepted.

**Reason.** The allowlist is a platform restriction on the flag, not a
permission the shell could obtain. Writing it through another route would be
privilege escalation, which the brief rules out. The run itself showed three
facts. `device_config` registered only after PackageManager (about 1840 s). The
display wait took 29.7 s in `OnBootPhase_100`. Zygote started three times in the
kernel log, which is consistent with system_server restarts, but no
`WATCHDOG KILLING` line was in the kernel log. Those facts are not enough to
close #064. The boot is still missing, and no Watchdog stack or dump was obtained.

**Verification.** The receipts hold the exact commands, the responses, and the
exit codes. The run's receipt is `final-default-run-20261009.txt`. Its cleanup
records `cvd remove` exit 0, and two crosvm processes were still listed after the
sweep. Both were gone by the next check, and no crosvm, `secure_env`, or
`run_cvd` process remained. The runner's sweep was changed in this pass to stop
`process_restarter` first and to verify the result. That change did not clear the
group in time, so the next run must check that nothing remains. The VM was
stopped afterwards.

## IR-304: File the Mesa-enabled VirGL guest image as task #099

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (new), #064, #022 |
| Affected documents | [M02](issues/M02-graphics.md) #099; [issues/README.md](issues/README.md) §1 and §3; [IR-240](#ir-240-plan-a-mesa-enabled-virgl-guest-image-without-changing-the-reference-pin) |

**Choice.** IR-240 proposed a follow-up for the Mesa-enabled guest image, and it
could not be numbered until GitHub issues existed. The issues now exist, so the
follow-up is filed as task #099, as the next issue number. It sits in M2 between
#021 and #022, and depends on #020 and #021, as IR-240 describes. Its entry is
in M02, and its GitHub issue is #99. The reference build `16373615` is not
changed, so #064 is unaffected.

**Reason.** The workflow requires new tasks to take the number GitHub gives them,
and the next free issue number is 99. Filing the task now keeps the guest
packaging work visible and gives #022 an explicit dependency on it. The task
cannot start yet, because #021 waits for #014 and #014 waits for the Android boot.

**Verification.** `gh issue list` shows issue #99 with the title `#099 Mesa-enabled
VirGL guest image`, and the entry is in M02 and in the task index.

## IR-305: Re-scope #064 and keep Virtualization.framework instead of QEMU

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #064, #010, #011, #013, #014 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #064, #010, #011, #013, #014; [issues/README.md](issues/README.md) §3 and §5; [android-image.md](../02-design/android-image.md) §8.1, §7.7, §15–§17; [runtime-daemon.md](../02-design/runtime-daemon.md) §3.3; [risks.md](risks.md) R-06 |

**Choice.** Stop trying to complete a crosvm reference boot on the nested
reference host, and remove #064 as a hard dependency of #010, #011, and #013.
The launcher captures under `Images/reference/16373615/incomplete/` are the
reference for what the Cuttlefish launcher and U-Boot produce. Behaviour that
needs a booted reference comes from the Cuttlefish source at the pinned
revision (`android17-release`) and from the VZ boot itself. #064 keeps its
completed criteria, and the criteria that need a complete crosvm boot are
deferred until a non-nested arm64 Linux host exists. QEMU is not adopted,
either as the product VMM or as the reference host.

**Reason.** The nested host was the cause of the stall. Across 62 records the
guest there ran about 100 times slower than the same image, kernel command line,
and launcher bootconfig on VZ: `zygote` started at 233 s of uptime against
1.3 s, and `boot_progress_pms_ready` came at 1467 s against 3.6 s (IR-306).
`system_server`'s Watchdog then killed it during startup, with a different
blocked frame in each cycle, which fits guest-wide slowness rather than one
defect. No arm64 Linux machine is available.

QEMU with HVF on macOS avoids the nesting, but it does not help here. The
Cuttlefish host tools (`launch_cvd`, `run_cvd`, `secure_env`, the simulators)
are Linux binaries, so a QEMU reference would need the same hand-built direct
boot (kernel, initrd with bootconfig, GPT disks) as VZ, and it would no longer
be the standard Cuttlefish stack that #064 wanted. macOS QEMU also has no
vsock device (vhost-vsock is Linux-only), which ADB and the guest protocol use.
As the product VMM, QEMU was already rejected in [ADR-0002](../01-architecture/decisions/0002-virtualization-framework-macos27.md), and
the VZ result removes the reason to revisit that.

**Verification.** `Experiments/vz-android-boot/README.md` holds the timing
table and the commands. The deferred criteria are marked in the #064 entry.

## IR-306: Record the VZ direct-boot spike and the substitutes it needs

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #011, #012, #013, #095, #014, #015 |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.2, §5, §6.2, §7, §9, §13, §17; [vm.md](../02-design/vm.md) §4, §5, §6.1, §7, §17; [graphics.md](../02-design/graphics.md) §9; [risks.md](risks.md) R-06, R-11, R-12; [M01](issues/M01-android-bring-up.md) |

**Choice.** Boot the pinned stock image directly on Virtualization.framework in
an experiment before the #011–#015 production code, and write what it needed
into the design. The experiment is `Experiments/vz-android-boot/`: a disk
builder, a bootconfig and initrd builder that reuses `bootconfig.py` and
`avb.py`, a small signed VZ harness, and `g2_spike.py`, which runs the G2 pass
conditions.

**Reason.** #064 could not produce a known-good boot (IR-305), and every M1 task
after #010 depended on one. The product boots VZ directly, so the quickest way
to learn whether the stock image works on the VZ topology was to try it with
the smallest harness possible, without committing to production APIs first.

**Verification.** 2026-10-08 UTC, arm64 Mac17,9 (M5 Pro), macOS 27.0.1
(26A434), build 16373615:

- The image reached `VIRTUAL_DEVICE_BOOT_COMPLETED` at 7.5 s of uptime on a
  first boot and at 3.9–4.7 s on later cold boots. `g2_spike.py` passed five
  cold boots in a row; each stayed up 10 minutes with
  `sys.system_server.start_count` 1, no Watchdog kill, no init service exiting
  three times, and no tombstone. With the two-disk layout of IR-308 it passed
  two cold boots.
- Kernel, first-stage init, dynamic partitions, AVB, and first-boot formatting
  worked without image changes. `boot_devices` is `40000000.pci`.
  `/proc/bootconfig` equalled the merged block. SELinux was enforcing with no
  AVC denials.
- What it needed: ports 10–19 on one multiport console device (VZ allows 10
  single-port devices), the sensors responder (IR-310), the keys of guest-side
  servers and `modem_simulator_ports`, three NAT NICs with `virt_wifi` and a
  matching `eth2` MAC, VZ's 2D virtio-gpu for the headless profile (IR-307), two
  disks (IR-308), and the first-boot settings (IR-309).
- ADB works through a loopback forwarder to guest vsock 5555, and `adb root`
  works on this userdebug build.

The harness is not production code and is not imported by any target. G2 still
needs the product code and a clean `main`.

## IR-307: Give the M1 headless profile VZ's 2D virtio-gpu

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #012, #014 |
| Affected documents | [android-image.md](../02-design/android-image.md) §9.1, §9.2; [graphics.md](../02-design/graphics.md) §9; [vm.md](../02-design/vm.md) §4; [M01](issues/M01-android-bring-up.md) #012, #014 |

**Choice.** The development-only `headless` GPU profile attaches VZ's own 2D
`VZVirtioGraphicsDeviceConfiguration` (one 720×1280 scanout, no view), through
a new development-only `VMDefinition.builtInDisplay`, and uses the launcher's
`guest_swiftshader` graphics keys. It replaces the planned "no GPU device and
Cuttlefish's no-GPU keys".

**Reason.** The planned profile cannot boot the stock image. Without
`ro.hardware.egl`, zygote and SurfaceFlinger abort ("couldn't find an OpenGL ES
implementation"), and `init.cutf_cvm.rc` waits for `/dev/dri/card0` in
`early-init`. #014's notes foresaw a follow-up that attaches the #019 device
instead, but that device answers only `GET_DISPLAY_INFO` and `GET_EDID` until
#022 and #023. VZ's 2D device needs no code, and ADR-0002 already keeps it as a
debugging fallback. It is never set together with the GraphicsCore device and
never in a release bundle; G3 is unaffected.

**Verification.** With it, SurfaceFlinger found HWC display 0 (720×1280,
60 Hz) over DRM, the boot animation ran and exited, and boot completed.

## IR-308: Use two disks instead of three

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #011, #012, #066 |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.2, §4.5, §5, §10.1, §12.2; [filesystem-layout.md](../01-architecture/filesystem-layout.md) §1; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §3, §4.5, the schema, and §6.2; [android-image-manifest.md](../03-reference/android-image-manifest.md); [vm.md](../02-design/vm.md) §5; [runtime-daemon.md](../02-design/runtime-daemon.md); [M01](issues/M01-android-bring-up.md) #011, #012 |

**Choice.** The instance has one writable disk, `userdata.img`, with the
partitions `misc`, `metadata`, `frp`, and a last `userdata`. `persistent.img`
is gone, and the bundle has one template.

**Reason.** The stock fstab contains `/devices/*/block/vdc auto auto defaults
voldmanaged=sdcard1:auto`. In the three-disk layout `vdc` is the userdata disk,
mounted as `/data`, and vold scanned it as removable storage (`disk:253,32`,
`sgdisk`, then "failed to identify, giving up"). The scan failed this time, but
a disk that holds `/data` must never be offered for formatting as an SD card.
Keeping the name `userdata.img` leaves the documents that mean "Android user
data" correct; the small partitions belong to the same instance lifetime.
`userdata` stays last, so growth (§5.2) is unchanged.

**Verification.** With two disks the kernel found `vda` with 9 partitions and
`vdb` with 4, every by-name label existed, vold reported no disk, and
`g2_spike.py --disk-set disks2` passed two cold boots.

## IR-309: Apply Bluetooth and Wi-Fi first-boot settings over the serial shell

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095, #014 |
| Affected documents | [android-image.md](../02-design/android-image.md) §6.2, §7.4, §7.6, §13 |

**Choice.** Set `androidboot.cuttlefish_service_bluetooth_checker=false`. After
the first `.bootCompleted` of a fresh instance, RuntimeCore runs
`cmd bluetooth_manager disable`, `cmd wifi set-wifi-enabled enabled`, and
`cmd wifi connect-network VirtWifi open` once, over the serial shell in M1 and
through the Guest Agent from #072. The custom image (#035) moves the defaults
into its overlays.

**Reason.** Without rootcanal on hvc5, `com.android.bluetooth` aborts in
`waitForInitialization` seven times in about 3.5 minutes on every boot, until
BluetoothManagerService's recovery limit. Disabling the HAL APEX with
`androidboot.vendor.apex.com.google.cf.bt=none` made it worse, and the boot
reporter waits for Bluetooth and reports `VIRTUAL_DEVICE_BOOT_FAILED`. The
checker key is what Cuttlefish's automotive product sets. Wi-Fi is off on a
fresh `/data`; Cuttlefish's automotive `wifi_on.sh` runs the same two `cmd
wifi` commands. Both settings are standard Android commands, persist in
`/data`, and need no image change.

**Verification.** Turning Bluetooth off right after `.bootCompleted` prevented
every abort on the first boot, and later boots had none. Wi-Fi joined
`VirtWifi`, and NetworkMonitor validated the network.

## IR-310: Answer the sensors HAL from the host

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 |
| Affected documents | [android-image.md](../02-design/android-image.md) §7.1, §7.6, §13 |

**Choice.** RuntimeCore attaches a "no sensors" responder to hvc18. It answers
the HAL's `list-sensors` with the frame the real `sensors_simulator` sends for
an empty mask (`02 00 00 80 02 00 00 00 30 0a`) and discards everything else.
hvc19 stays silent.

**Reason.** This is a host-side substitute, which §7 prefers to avoid. No
configuration avoids it in this build: the HAL hard-codes `/dev/hvc18` and
`/dev/hvc19`, it is a plain vendor package rather than a selectable APEX, and
`HalProxy` loads `/vendor/etc/sensors/hals.conf` unconditionally. A silent port
blocks the HAL forever in `ReadExactBinary`, which blocks `SensorService` and
then the `system_server` main thread; its Watchdog killed `system_server` after
185 s on every restart. A missing port makes the HAL abort in a loop. The
responder is the smallest adapter that lets the stock HAL finish, and it
exposes no host data to the guest.

**Verification.** With the responder, the HAL logged `host sensors mask=0,
available sensors mask=0`, registered `ISensors/default`, and boot completed.
The framing comes from `common/libs/transport/channel.h` and
`host/commands/sensors_simulator/sensors_hal_proxy.cpp` on `android17-release`.

## IR-311: Test the provisioner's volume checks with an injected probe

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #011 |
| Affected files | `Packages/ImageCore/Sources/ImageCore/Disks/InstanceDiskProvisioner.swift`; `Packages/ImageCore/Tests/ImageCoreTests/InstanceDiskProvisionerTests.swift` |

**Choice.** `InstanceDiskProvisioner` reads the destination volume's file
system type, name, and free space through an injectable probe (`statfs` by
default). The tests use the real probe and a real `clonefile` on the APFS
temporary directory for the clone-and-grow case, and an injected probe for the
non-APFS (`cloneUnsupported`) and free-space (`insufficientSpace`) cases. The
#011 entry planned T1 tests on `hdiutil create` scratch volumes, an APFS one and
an HFS+ one.

**Reason.** The checks depend only on what `statfs` reports, and the probe tests
exercise exactly that decision without creating and mounting disk images in a
`swift test` process. The clone-and-grow test still runs against the real file
system, which is where the sparse-growth claim (NFR-RES-02) is measured.

**Verification.** The four provisioner tests pass; the grown 32 GiB disk was
allocated below 16 MiB on APFS.

## IR-312: Keep the M1 boot failures in a RuntimeCore type of their own

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #012, #014 |
| Affected files | `Packages/RuntimeCore/Sources/RuntimeCore/Boot/RuntimeBootFailure.swift`; `Packages/RuntimeHost/Sources/RuntimeHost/RuntimeFailure.swift`; [error-catalog.md](../03-reference/error-catalog.md) §7.6 |

**Choice.** The first-cut `RuntimeSupervisor` reports its failures as
`RuntimeBootFailure` in RuntimeCore, with the catalog codes of error-catalog.md
§7.2 (`runtime.image`, `runtime.vmConfiguration`, and `runtime.vm` as
transparent entries, and `runtime.kernelPanic`, `runtime.androidBootFailed`,
`runtime.bootTimedOut`, and `runtime.bootStalled`). RuntimeHost's
`RuntimeFailure` keeps its host-process cases.

**Reason.** state-machines.md §2 puts `RuntimeFailure` in RuntimeCore, but the
existing enum of that name lives in RuntimeHost, and the CLI, which may not
import RuntimeCore, names its cases. Moving it would need a re-export or CLI
changes outside #012. Both enums are in the `runtime` domain, which RuntimeCore
and RuntimeHost share, and their codes do not collide; the CLI prints either
through the catalog. They merge when the full `RuntimeSupervisor` arrives with
#031.

**Verification.** The catalog test lists the new codes, and `apkrun dev boot`
prints them through `ErrorOutput`.

## IR-313: Run Integration tests on manual dispatch only until a lab runner exists

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (acceptance `linux-guest`); #062 |
| Affected files | `.github/workflows/integration.yml`; `scripts/tests/test_workflow_runners.rb`; [build-system.md](../05-development/build-system.md) §15.1; [test-strategy.md](test-strategy.md) §2.4 |

**Choice.** `integration.yml` has no push trigger, only `workflow_dispatch`. The
`linux-guest` job is unchanged.

**Reason.** No `apkrun-lab` runner is registered (IR-295). The push to `main` on
2026-10-09 (`87ee2c0`) started a `linux-guest` run that could only stay queued,
like the run IR-295 cancelled. With the trigger off, pushes start nothing. A
maintainer can still dispatch the job by hand.

**Consequence.** #003's `linux-guest` acceptance box stays open, as in IR-295.
When a lab runner is registered, the push trigger comes back with the path
filter of build-system.md §15.1. The nightly lab jobs (`nightly.yml`) are not
changed by this entry.

## IR-314: Run the nightly lab jobs on manual dispatch only until lab runners exist

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #003 (nightly `gates`); #006 (nightly `network`); #062 |
| Affected files | `.github/workflows/nightly.yml`; [build-system.md](../05-development/build-system.md) §15.1; [test-strategy.md](test-strategy.md) §2.5 |

**Choice.** `nightly.yml` has no `schedule` trigger, only `workflow_dispatch`.
Its jobs (`gates` on `apkrun-reference`, `network` on `apkrun-lab`) are
unchanged.

**Reason.** No `apkrun-reference` or `apkrun-lab` runner is registered (IR-295).
A daily run could only stay queued. IR-313 turned off the push trigger of
`integration.yml` for the same reason. IR-295 had left the nightly jobs as they
were; the maintainer has now asked for them to be stopped as well.

**Consequence.** Gate regressions and the network check do not run on a
schedule. Gate checks run locally with `scripts/run-gate.sh G<n>`, and their
results are recorded by hand. When the lab runners are registered, the daily
schedule (`cron: "15 3 * * *"`) comes back.

## IR-315: Bind the ADB loopback forwarder with a POSIX socket, not NWListener

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [vm.md](../02-design/vm.md) §8; [android-image.md](../02-design/android-image.md) §7.3; [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 step 6 |

**Choice.** `VsockLoopbackForwarder` listens on a POSIX IPv4 socket bound to
`127.0.0.1` only. Before it binds, it connects once to the port, and a connection
that succeeds is reported as `vm.loopbackPortInUse`. `SO_REUSEADDR` is set after
that probe.

**Reason.** vm.md §8 asked for an `NWListener` with `requiredLocalEndpoint` on the
loopback address. On macOS 27 that call fails with `EINVAL` for a listener. With
`requiredInterfaceType = .loopback`, the listener stays on every address (`*:6520`),
which fails the #015 check that `lsof` shows only `127.0.0.1`. `SO_REUSEADDR` is
needed so that a restart is not blocked by a TIME_WAIT connection from the previous
run. On this host it also lets a bind to `127.0.0.1` succeed while another process
listens on the wildcard address, so the probe closes that gap.

**Consequence.** Developer mode depends on a POSIX listener. The security review
(NFR-SEC-06) should confirm it. `vm.md` §8 describes the implementation, and
`VsockLoopbackForwarderSystemTests` checks the `lsof` result.

## IR-316: Report loopback listener failures as VMFailure cases in the vm domain

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [error-catalog.md](../03-reference/error-catalog.md) §5.1; [vm.md](../02-design/vm.md) §8 |

**Choice.** The forwarder's failures are two cases of `VMFailure`:
`loopbackPortInUse(port:)` and `loopbackListenFailed(port:underlying:)`. Their
catalog codes are `vm.loopbackPortInUse` and `vm.loopbackListenFailed`.

**Reason.** The forwarder belongs to VirtualMachineCore, which owns the `vm` domain,
and a new domain would split one subsystem across two. RuntimeCore logs the failure
and boots without ADB, so the codes show up in the log and in `apkrun doctor`
rather than in a user message. Both entries still carry a remediation, as the
catalog requires.

## IR-317: Add each ADB helper with the task that first uses it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015, #016, #017 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #015 step 3; [guest-protocol.md](../02-design/guest-protocol.md) §15 |

**Choice.** `AdbClient` in #015 has the helpers that the ADB signals, the stop
sequence, and the connection need: `connect`, `getprop`, `shell`, `logcat`
(`logcatDump`), and `rebootPowerOff`. The helpers `install`, `uninstall`,
`listPackages`, and `dumpsysPackage` come with #016, and `startActivity`, `pidof`,
`dumpsysActivities`, and `forceStop` come with #017. Each helper is defined in the
task whose deliverables name it.

**Reason.** #015 step 3 lists the whole helper set, but the deliverables of #016 and
#017 name the install and launch helpers. A helper with no caller and no test
would be unverified code. The rule that every command string lives in a helper
still holds, so the #027 lint needs no exception.

**Consequence.** `AdbClient` gains methods in three steps. Nothing outside
`AdbClient` builds an `adb` command line.

## IR-318: Keep the ADB client's errors in the runtime domain with their own codes

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [error-catalog.md](../03-reference/error-catalog.md) §7.6; [diagnostics.md](../02-design/diagnostics.md) §3.1 |

**Choice.** `AdbFailure` is a RuntimeCore type in the `runtime` domain, with the
codes `runtime.adbExecutableMissing`, `adbLaunchFailed`, `adbConnectionUnavailable`,
`adbCommandFailed`, `adbCommandTimedOut`, `adbInvalidArgument`, and
`adbUnexpectedOutput`. Its logs go to a new `io.apkrun.runtime` category, `adb`.

**Reason.** The ADB client talks to the Android guest, so it belongs with the other
runtime-domain errors and the catalog's `runtime` section. A separate domain would
add a second top-level family for one client. The category keeps the ADB traffic
separate in `apkrun logs`. The command output is never put in an error or a log
line: it can carry app data or logcat text, so only the command name, exit status,
and timeout are kept.

## IR-319: Connect to the ADB endpoint only when the device reports `device`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [android-image.md](../02-design/android-image.md) §7.3; [vm.md](../02-design/vm.md) §8 |

**Choice.** `AdbClient.connect` succeeds only when `adb connect 127.0.0.1:6520`
reports a connection and `adb -s 127.0.0.1:6520 get-state` prints `device`. It
retries with a backoff of 250 ms, doubling to 2 s, until its deadline (30 s).

**Reason.** The loopback forwarder accepts a TCP connection before the guest has
an adbd listener behind it, and the forwarder then closes it at once. `adb connect`
alone therefore reports success while the device is still `offline` or missing.
Checking `get-state` is the only way the client knows that the adb protocol
handshake has finished, so the first command after `connect` does not fail.

## IR-320: Stop developer Android over ADB first and keep the serial shell as the fallback

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [vm.md](../02-design/vm.md) §9.3; [runtime-daemon.md](../02-design/runtime-daemon.md) §3.5 step 6 |

**Choice.** In developer mode, `RuntimeSupervisor.stop()` runs `adb shell reboot -p`
when the ADB poller has connected in this boot. Otherwise it runs
`su 0 reboot -p` over the serial shell, as #014 did. Either way it waits up to 20 s
for `stopped`, and then it forces the stop.

**Reason.** #015 step 4 asks for `adb shell reboot -p` on Ctrl-C, and the ADB path
does not need the serial console. The serial path stays for a boot where ADB never
connected, so the stop still works without ADB. Verified on 2026-10-09 with a
headless boot: the stop took 2 s, the guest logged `reboot: Power down`, and the
notice `Stopping Android with reboot -p over ADB` was logged.

**Consequence.** `adb shell reboot -p` runs as the `shell` user (uid 2000) on this
image, and init accepted it. If a future image refuses it, the reply's exit status
is ignored and the stop falls back to the forced stop after 20 s, so the ADB path
needs a check in the T2 test.

## IR-321: Start no ADB poller when the loopback forwarder cannot start

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 step 6; [configuration.md](../03-reference/configuration.md) §2.5 |

**Choice.** `RuntimeSupervisor` starts the forwarder and the ADB poller only in
developer mode. If the forwarder does not start, nothing else in the ADB bridge
starts: no `adb` client, no poll, and no ADB signal. The boot continues on the
console signals, and the failure is logged with its code (`vm.loopbackPortInUse` or
`vm.loopbackListenFailed`). The poller reads `sys.system_server.start_count` and
`sys.boot_completed` through two `getprop` calls every 500 ms, until
`sys.boot_completed` is `1`, and a failed read is skipped.

**Reason.** When another process holds port 6520, `adb connect 127.0.0.1:6520` would
reach that process, not the guest. Polling would then read another program's
answers as Android's boot state. Stopping the ADB bridge at a failed forwarder
keeps the boot signals honest. The developer mode boot still works, because the
console signals reach `.bootCompleted` on their own, as #014 shows.

**Consequence.** Without the forwarder, `apkrun dev adb` fails with
`runtime.adbConnectionUnavailable`, and no ADB signal is seen. The poller stops at
`sys.boot_completed`, so the ADB client stays connected only as far as later
commands need it. The supervisor takes the environment as an init parameter, so
that tests can point it at a fake `adb`.

## IR-322: Do not implement the ADB key append on the stock image

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #015 step 1; [android-image.md](../02-design/android-image.md) §11.3 |

**Choice.** #015 step 1 asks that, when `ro.adb.secure=1`, developer mode append
`~/.android/adbkey.pub` to `/data/misc/adb/adb_keys` over the serial shell before the
first connect. The branch is not implemented. The stock image is checked for the value
instead: `ro.adb.secure` is unset on build 16373615 (`getprop` prints an empty line,
checked on 2026-10-09 and recorded in the #015 notes).

**Reason.** The branch cannot run on the stock image, and no secure development image
exists yet to test it. android-image.md §11.3 says the Guest Agent authorizes the host
key on a `user` build, through `AdbManager.allowDebugging`, which is #035 and #072 work.
Writing the key from the host would be a second, untested path that the design assigns
elsewhere. If a secure image appears before #035, its boot fails with an unauthorized
device, which `AdbClient.connect` reports as `runtime.adbConnectionUnavailable`.

## IR-323: Give the ADB tests a private adb server, and drop stale transports before connecting

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §8; [M01](../04-plan/issues/M01-android-bring-up.md) #015 |

**Choice.** `AdbClient` runs `adb disconnect <endpoint>` before each `adb connect`
attempt. The AndroidADB test configuration sets `ANDROID_ADB_SERVER_PORT=15037`, so
the tests use their own adb server, not the default one on port 5037.

**Reason.** The adb server is shared by every process on the Mac. On this host the
server on port 5037 was started by the Homebrew `platform-tools` cask. A transport left
over from an earlier boot is reported as "already connected", and it stays `offline`
until it is dropped, so the first T2 run failed to reach a booted device for 30 s.
Dropping the transport before each attempt fixes the client for every caller. The
private server keeps the tests from depending on what other tools left on the shared
server. The `apkrun dev adb` command still uses the default server, as a developer
expects.

## IR-324: Pass the SDK path to the T2 host through its Info.plist

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015, #016, #017 |
| Affected documents | [test-strategy.md](../04-plan/test-strategy.md) §2; [build-system.md](../05-development/build-system.md) §8 |

**Choice.** The IntegrationTests host's `Info.plist` carries `APKRUN_ANDROID_HOME`,
set by a build setting, the same way as `APKRUN_TEST_LINUX_DIR`. The AndroidADB test
configuration of `IntegrationTests.xctestplan` runs the tests with the `android-adb`
suite. The tests are skipped outside that suite.

**Reason.** xcodebuild does not pass the caller's environment to the test host, so
`ANDROID_HOME` was unset in the test process and the first run skipped the developer
test. A build setting follows the existing pattern for the test directory. The T2
signing team is the one in the certificate's OU field, which is the `DEVELOPMENT_TEAM`
value. The certificate's common name carries a different identifier.

## IR-325: Close both sides of a loopback connection when either side ends

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [vm.md](../02-design/vm.md) §8 |

**Choice.** `VsockLoopbackForwarder` closes the TCP client and the guest connection
as soon as either side reaches end of stream. It does not keep a half-closed
connection open for the other direction.

**Reason.** The forwarder carries adb's protocol, and adb never half-closes: it
closes the whole connection when a command ends. Keeping a half-closed connection
would need a per-direction state machine for no caller. A later caller that needs
half-close has to change this rule and say so in its own record.

**Consequence.** A reply that the guest sends after the client has closed its write
side is dropped. The forwarder's header documents the rule.

## IR-326: Keep AdbClient.shell public as the one generic command helper

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015, #027 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #015 step 3; [guest-protocol.md](../02-design/guest-protocol.md) §15 |

**Choice.** `AdbClient.shell(_:timeout:)` stays public and accepts any device command.
The named helpers (`getprop`, `logcatDump`, `rebootPowerOff`) validate or fix their
own command lines, and the T2 test uses `shell` only for `ps -A` and `pm list packages`,
which are fixed strings.

**Reason.** The T2 check and the M1 control paths need a way to run a fixed device
command that has no named helper yet. Removing `shell` would force a helper per
check. No caller passes untrusted text: the one dynamic argument, the property name
of `getprop`, is validated.

**Consequence.** The #027 lint has to treat `shell(` as a helper call and check that
its arguments are literals or validated. This is noted for #027.

## IR-327: A stop during the VM start leaves the boot failed, not stopped

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 |
| Affected documents | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.1, §3.5; [vm.md](../02-design/vm.md) §9.1 |

**Choice.** When `stop()` runs while `VMController.start()` is still in progress,
`boot()` stops the VM it started, does not start the ADB bridge, and throws
`androidBootFailed("the runtime was stopped while starting")`. The state then
becomes `failed`, not `stopped`.

**Reason.** `VMController.stop()` is rejected while a start is pending, so `stop()`
cannot stop a starting VM. Before this change a late start left the VM running
after `stop()` had reported `stopped`. The new guard keeps the VM and the bridge
from outliving the stop. Reporting `failed` instead of `stopped` is the smaller
change: the runtime-daemon state machine has no `stopping`-during-start transition,
and `failed` triggers the diagnostics capture that a user-stopped start does not need.

**Consequence.** A stop within the first moments of a start shows a failed boot in
the logs. Making this a clean `stopped` needs `stop()` to wait for the start, which
belongs to the state-machine work of #031 (`RuntimeSupervisor`). The race is
recorded here, not fixed in #015.

## IR-328: Commit one test-only fixture keystore, with its password in the Gradle file

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #016 |
| Affected documents | [build-system.md](../05-development/build-system.md) §8; [security-model.md](../01-architecture/security-model.md) §7; [test-strategy.md](test-strategy.md) §4.4 |

**Choice.** `Tests/Fixtures/signing/test-fixture-a.jks` is a new keystore for the fixture
apps. It holds one RSA 2048 key with alias `fixture-a`, valid for 36500 days, with the
subject `CN=APKRun test fixture A, OU=test only, O=APKRun, C=US`. It is a PKCS12 store
under the `.jks` name, which the spec requires and which avoids keytool's JKS warning.
`HelloText/build.gradle.kts` holds the store and key passwords, and the release variant is
signed through AGP's `signingConfig`. `scripts/build-fixtures.sh` checks that the APK's
signer SHA-256 is the pinned certificate digest, and it does not sign a second time.

**Reason.** The entry requires a committed test-only key, and no key existed. A test key
signs nothing that a user installs, and security-model.md §7 and AGENTS.md §9 allow it in
`Tests/Fixtures/signing/`. A password in a test build file is the only way AGP can read it
without a secret store, and the password protects nothing.

**Consequence.** Every fixture APK is signed with this key, so a T2 test can tell the
fixture's signature from a real one. A second test key, `test-fixture-b.jks`, comes with the
HelloUpdate variants (#056), not with this task.

## IR-329: Run the fixture unit tests on the release variant

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #016 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #016 step 1 |

**Choice.** `HelloText/build.gradle.kts` sets `testBuildType = "release"`, so the JVM unit
tests run as `:HelloText:testReleaseUnitTest`, which the entry names.

**Reason.** AGP creates only debug unit-test tasks by default. The release variant is the
one that ships, so the counter logic is tested in the form that is installed.

## IR-330: Define the fixture reproducibility check by badging, dex hashes, and archive listing

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #016 |
| Affected documents | [build-system.md](../05-development/build-system.md) §14 |

**Choice.** `scripts/build-fixtures.sh --check-reproducible` builds twice from `clean`.
It compares the `aapt2 dump badging` output, the SHA-256 of the concatenated `classes*.dex`
files, and the listing of the archive entries. The APK bytes are not compared.

**Reason.** build-system.md §14 defines reproducibility for guest APKs as the same
`versionCode`, content, and dex, and the entry names the badging and the dex hashes. The
APK also carries a signature and zip metadata, which the check does not need to match. A
byte comparison can be added later if the signature scheme becomes deterministic.

## IR-331: Copy the Gradle wrapper into the fixture project

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #016 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.5 |

**Choice.** `Tests/Fixtures/AndroidApps/` has its own `gradlew`, wrapper jar, and wrapper
properties, copied from the repository root (Gradle 9.6.1, with the same distribution
checksum). Its AGP version (9.4.1) is copied from `Guest/gradle/libs.versions.toml` into
`gradle/libs.versions.toml`.

**Reason.** environment-setup.md §2.5 asks for a separate wrapper with the same version.
A shared include would make the fixture build depend on the Guest build's layout. A
version change has to be made in both places, and the check that compares them is
out of scope for #016.

## IR-332: Take the PackageInstaller path of FR-PKG-01 from adb's install command and the device's metadata

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #016 |
| Affected documents | [package-store.md](../02-design/package-store.md) §6.1; [traceability.md](traceability.md) FR-PKG-01 |

**Choice.** The T2 suite checks that `adb install -r` prints `Success`, and that
`dumpsys package` reports the fixture's `versionCode`, `versionName`, `minSdkVersion`, and
`targetSdkVersion`. It does not assert the PackageInstaller session itself. The recorded
guest metadata shows `initiatingPackageName=com.android.shell` and `packageSource=1` (a local
file), and `installerPackageName=null`, because a shell install has no installer app.

**Reason.** Android 17 exposes no shell command that reports the session of an install
after it commits. `adb install` runs `cmd package install`, which creates a PackageInstaller
session, as package-store.md §6.1 requires. The check that APKRun controls is that the
install goes through adb and nowhere else: the host never copies an APK, and the
`AdbClient` has no code path that writes into `/data/app`.

**Consequence.** FR-PKG-01 is verified by the design's own mapping plus this evidence. A
PackageInstaller-level check, for example through the Store Agent, belongs to #036, which
does not use adb install. The traceability row names the T2 suite, which stays accurate.

## IR-333: Leave the SharedPreferences path of the counter without a JVM test

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #016 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #016 step 1 and acceptance criterion 1 |

**Choice.** The counter's persistence contract is tested on the JVM with an in-memory
`KeyValueStore`. `PreferencesKeyValueStore`, which wraps `SharedPreferences`, has no test.
The on-device counter check waits for rendering and input (#026).

**Reason.** The fixture's JVM tests run without Robolectric, so `SharedPreferences`
cannot be created there. Adding Robolectric would add a runtime dependency to the
fixture for one adapter of two lines. The adapter does one call, `commit()`, and its
result is checked by `CounterStore`.

**Consequence.** Criterion 1 stays open until the device check. The adapter has no
automated test until then.

## IR-334: Read the resumed activity from every form that Android prints

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #017 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #017 step 3 |

**Choice.** `AdbClient.dumpsysActivities()` reads the resumed activity from the first of
these lines that names a record: `topResumedActivity=`, `mResumedActivity:`,
`ResumedActivity:`, or `Resumed:`. The record is written
`ActivityRecord{<hash> u<user> <package>/<class> t<task>}`.

**Reason.** #017 names `topResumedActivity` and `mResumedActivity`. The guest on this
image (Android 17, build 16373615) prints `ResumedActivity:` for the global state and
`Resumed:` under "Resumed activities in task display areas". It does not print
`topResumedActivity=` in that dump. The earlier capture of the same guest did print it,
so the reader accepts every form it has seen. The T0 tests run on the recorded forms.

**Consequence.** A dump with none of these lines is an unexpected reply: `dumpsysActivities`
throws `unexpectedOutput`. A dump that names a resumed record which is not an activity has
no component and is not an error. A future Android release that prints only a fifth form
therefore fails on the T2 check, and not silently.

## IR-335: Read a pidof reply of nothing as "no process"

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #017 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #017 step 2 |

**Choice.** `AdbClient.pidof` returns nil only when the command exits 1 with no output and no
error text. It returns the first process ID when the command exits 0, and the ID must be a
positive number. Every other reply is a failure: exit 1 with error text is a broken adb
connection, not a missing process.

**Reason.** `pidof` exits 1 with no output and no error when nothing matches. Treating that as an error
would make "the process is gone" look like a failure, and #017's stop check depends on
the difference. A recorded reply confirms the behaviour: after `am force-stop`, `pidof`
exits 1 with no output.

## IR-336: Refuse a `$` in an activity class name instead of quoting it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #017 |
| Affected documents | [M01](../04-plan/issues/M01-android-bring-up.md) #017 step 1 |

**Choice.** `AdbClient.startActivity` refuses a component whose class name contains `$`,
so a nested class such as `.Outer$Inner` is not started. The check is an `invalidArgument`
error, not a quoted command line.

**Reason.** The command runs through the device's shell (`adb shell`), and the shell expands
`$` in an unquoted word. Quoting the component would be correct, but the only callers today
pass constant component names, and no fixture has a nested class. Refusing the character
is the smaller, safe change. Nested classes are a follow-up for the first task that starts
one: that task quotes the component, adds a test, and removes the refusal.

## IR-337: Installed templates are read-only, and clonefile keeps their mode: provisioning and boot fail on main

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015, #016, #017 (found by the T2 suites on main) |
| Affected documents | [android-image.md](../02-design/android-image.md) §5.1 and §6.3; [build-system.md](../05-development/build-system.md) §8 |

**Choice.** Not fixed in these three tasks. main fixes it in cbaaf36: `FileCloner.cloneWritable` clones the file and then adds the owner's write bit, keeping the read bits.

**Reason.** On main, an installed image is read-only (`templates/userdata.img`, `disks/os.img`, and
`boot/ramdisk.img` are mode 0444). `clonefile(2)` keeps the mode of its source, so the instance disk
clone and the per-boot initrd clone are read-only, and the write that follows fails with `EACCES`.
Provisioning reports `image.cloneFailed(underlying: NSPOSIXErrorDomain 13)`, and a boot reports
`runtime.image`. `apkrun dev image install` on a fresh home fails the same way. Two local, uncommitted
experiments confirmed the cause: a `chmod` to 0600 after each clone (`InstanceDiskProvisioner.swift`
after `clonefile`, and `AndroidBootPlanner.swift` before the trailer is written) made the AndroidPackage
suite pass 4 of 4 and the AndroidADB suite pass 2 of 2 on the rebased tip.

**Consequence.** The T2 suites of #015 to #017 cannot pass on main without a writable clone. With
cbaaf36 they pass without any local change, and the T2 check is the one that confirms it.

## IR-338: Pin the test keystore by its digest in the release check, and scan bundles for its material

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #016 (the HelloText fixture), #062 (the release checks) |
| Affected documents | [build-system.md](../05-development/build-system.md) §3.1 (updated); [coding-conventions.md](../05-development/coding-conventions.md) §11 (test key naming, unchanged); [test-strategy.md](test-strategy.md) §4.4 (unchanged) |

**Choice.** `scripts/release/check-release-build.sh` accepts a test keystore only when its file name and the SHA-256 of its full bytes both match an entry in `scripts/release/test-keystore-pins.json`. That file is the one place that lists the committed test keystores; today it holds `test-fixture-a.jks` (PKCS#12) and `test-guest-dev.jks` (JKS, the Guest Agent's development key, pinned in the same way as `build-guest.sh`'s signer). Each entry also records the keystore's certificate and public key as DER, so the bundle scan can match them. The search covers the regular files directly in `Tests/Fixtures/signing/` and nothing below them: a subdirectory fails the check as an unexpected directory. A `.jks` file that lacks the `test-` prefix, or that is not pinned, fails as an unsupported format, whatever its bytes look like.

For each pinned keystore, the app bundle and the image bundle (the second argument) are refused when they contain any of:

- the full keystore bytes;
- 16 fragments of 16 bytes spread across the file, so a truncated copy still matches;
- the certificate DER and the public key DER, and their hex, base64, and SHA-256 forms (full digest, first 16 hex digits, and colon-separated);
- the same bytes inside a zip member: a zip archive is opened, and each member is scanned as stored or deflated.

**Reason.** The first version of this rule (commit 7b49f4e) accepted a file by its name, magic, and structure, so a forged or renamed JKS passed as test material. It also searched the signing folder recursively and scanned only the app bundle. An independent review against 7b49f4e found these problems. A pinned digest closes the first. The scan additions close the bundle gaps (the certificate, the public key, the fragments, deflated members, and the image bundle), and the search is limited to the folder's own `test-*.jks` files.

**Tests.** `scripts/tests/test_release_check_keystores.py` runs its cases on a temporary repository. They check that every committed keystore is pinned, that each pinned file matches its digest, and that each pinned certificate and public key are the committed keystore's: a JKS is parsed, a PKCS#12 keystore is opened with openssl and the store password its Gradle file gives. A pin with a changed digest, a certificate or public key taken from another keystore, an unpinned keystore, or a pin for a missing file must each be refused. The committed keystore is accepted: this is the regression case for a wrong refusal of a real JKS. A renamed copy, a release-named copy, a JKS-magic file named `test-prod.jks`, a garbage `test-garbage.jks`, a truncated and a tampered committed copy, and a `.p12` copy are refused. A subdirectory in the signing folder is refused. The app bundle refuses the full, truncated, deflated, split, certificate-DER, certificate-fingerprint, public-key, and public-key-identity forms, and accepts a clean bundle. The image bundle refuses the keystore and accepts a clean one. `scripts/tests/run.sh` also embeds the keystore in a bundle, and that case must fail. Three mutants were run against the test file (the digest check removed, the certificate token removed, the fragments removed), and each mutant was caught by at least one case.

**Limitations.** The rule does not cover these cases, and the consequences are stated here, not hidden:

- A copy split into pieces of about 180 bytes or less can fall between the fragments. The fragments of the 2702-byte keystore are 179 bytes apart. Halves of the file are caught.
- Only zip archives are opened. A keystore inside another compressed container (tar.gz, 7z, a raw deflate stream) is not decoded and is not caught.
- The keystore keeps its certificate and key in encrypted containers, so the certificate and public key are matched only where a bundle exports them. The DER case is matched through the public key that the certificate embeds; the fingerprint case through the certificate's own token.

**Follow-up.** The two open gaps (pieces of about 180 bytes or less, and compressed containers other than zip) are not closed by this change. They need a task. No task number exists for them yet, so the coordinator should assign one (AGENTS.md §11: a new task takes the number GitHub gives its issue, #098 and up).

**Consequence.** A keystore that is not pinned fails the release check, whatever its name. A new test keystore is added by committing it under `Tests/Fixtures/signing/` as `test-*.jks` and adding its entry to the pins file in the same change. The pins test fails until both match.

## IR-339: Read adb pipes on threads of their own, so a parked command cannot stall the timeouts of others

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (the ADB client; its T0 tests on the hosted runner) |
| Affected documents | none (the comment on `AdbProcess.run` in `Packages/RuntimeCore/Sources/RuntimeCore/Android/AdbProcess.swift` describes the reads) |

**Choice.** `AdbProcess.run` reads stdout and stderr to their end on a thread of its own for each pipe, not in a `Task.detached`. The FakeADB helper and the connect tests are unchanged. `adbClientEndsEveryTimedOutCommandWhileOthersHoldTheirPipesOpen` runs 32 commands that keep their pipes open past a 2 s timeout, and requires every one to end on its timeout within 20 s.

**Reason.** Run 37949261551 on `424a171` failed three AdbClient connect tests with `connectionUnavailable` after about 30 s, and the timeout test recorded no timeout. Those tests only run fake scripts, so the cause is in the process runner. A blocking pipe read holds one thread of the Swift concurrency pool until the pipe closes. A command that keeps its pipes open (the fake's `sleep 30`) therefore holds pool threads, and the timers that end the other commands cannot run. A local repro with 64 parked `sleep 30` commands produced the same failure on the unfixed code: `connect` failed after 30.0 s with `connectionUnavailable`. With the fix, the same `connect` succeeded in 0.2 s, and the regression test fails on the unfixed code. The brief asked for a fix in the test or the FakeADB helper. Neither is the cause, so the fix is in the production runner, in the same #015 file, and this entry records that departure.

## IR-340: Store the developer image key as PKCS#8 PEM, with a base64 public file

## IR-360: Check the kernel command line over the serial shell, not on hvc0

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §6.1; [build-system.md](../05-development/build-system.md) §10.1 |

**Choice.** `keygen` writes the private key as an unencrypted PKCS#8 PEM with mode 0600, and the public key as the base64 of the raw 32 bytes on one line, in `<name>.pub`. It refuses to overwrite either file.

**Reason.** The spec fixes the `.pub` format and the key ID, but not the private key's format. PKCS#8 is what `openssl genpkey -algorithm ed25519` writes, so the key can be checked with standard tools, and the release checker reads the same format. A passphrase would need a prompt inside a build step, and the file stays in the developer's home with mode 0600. The Python tests check the modes, the round trip, and the refusal to overwrite.

## IR-341: Release builds trust no image key until the release key ceremony

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 (acceptance: no stock bundle is published, R-10); #093 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §6.1; [android-image.md](../02-design/android-image.md) §10.1 |

**Choice.** `ImageTrustStore.release` is an empty list. A Release build refuses every bundle with `untrustedKey`. No placeholder release key is compiled in.

**Reason.** No release key exists yet, and R-10 keeps stock bundles out of publication. A placeholder key would be a trust anchor nobody controls. Failing closed keeps a Release build from trusting a development key. Product images (`kind: apkrun`) cannot be installed in a Release build until #093 adds the release key IDs. `check-release-build.sh` already refuses the test key and the developer key.

## IR-342: Read the developer key under `#if DEBUG`, not under the ReleaseUpdateTest configuration

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065; the maintenance tests (M10) |
| Affected documents | [build-system.md](../05-development/build-system.md) §2.4; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §6.1 |

**Choice.** `ImageTrustStore.standard()` reads `~/.config/apkrun/dev-image-key.pub` only in Debug builds. `ReleaseUpdateTest` builds do not trust the developer key yet.

**Reason.** build-system.md §2.4 says package code must not use compilation conditions for ReleaseUpdateTest, because Xcode builds packages only in Debug and Release. A runtime switch on the build identity would put the developer key path into Release binaries, and the release check forbids that string. The maintenance tests that need a lab-signed image should inject the developer key from the app target, the composition root. That belongs to the task that first needs it.

## IR-343: Commit the test image key as PKCS#8 Ed25519, and make the release checker read it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [build-system.md](../05-development/build-system.md) §3.1; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §13 |

**Choice.** The test key is `Tests/Fixtures/signing/test-image-ed25519`, a PKCS#8 PEM Ed25519 key, with its `.pub`. `check-release-build.sh` now reads PKCS#8 Ed25519 files as well as RSA ones, and it reads a PEM file whatever its extension.

**Reason.** AGENTS §9 puts test keystores in `Tests/Fixtures/signing`, and the spec names the file without its format. The checker fails closed on a format it does not know, so it must recognise this key. Without that recognition, a Release app that carried the test key would pass, because the scan would not know the key exists.

## IR-344: Refuse a kernel that declares no page size, and let the test fixture declare 4 KiB

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.1, §10.2; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.4, §7.3 |

**Choice.** `bundle` stops when the arm64 Image header's flags bits 1-2 are 0, because the schema has no value for an undeclared page size. The synthetic fixture kernel declares none, so `test_bundle.py` records 4096 for it through a test shim. A test checks the refusal with the real extraction.

**Reason.** §4.4 requires `kernelPageSize` to be 4096, 16384, or 65536, and §7.3 says the build checks it. Guessing would make the field mean nothing. Regenerating the pinned fixture archive would change checksums in several suites, which is more than this task should touch. The real stock kernel declares 4096, so the product path is unaffected. The alternative is to pin `kernel.pageSize` in the layout, for the maintainer to choose.

## IR-345: Add four ImageFailure cases that §14.1 does not list

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [android-image.md](../02-design/android-image.md) §14.1; [error-catalog.md](../03-reference/error-catalog.md) |

**Choice.** `ImageFailure` gains `unexpectedFile(file:)`, `imageNotInstalled(version:)`, `noCurrentImage`, and `downgradeRejected(from:to:)`. Each has an `image.*` catalog entry, and the first three have rows in §14.1 (the last already had one).

**Reason.** The store needs its own errors for a manifest that differs under the same version, an activation of an image that is not installed, and a boot with no current image. Reusing `missingFile` or `manifestInvalid` would hide what the user has to do.

## IR-346: Check the staged clone in full, and the source only quickly

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.3; [android-image.md](../02-design/android-image.md) §10.3 |

**Choice.** A directory install verifies the source quickly (signature, schema, rules, file set, sizes), clones the files, runs the full check on the clone, renames it into place, and makes it current. Reinstalling an identical image clones nothing and runs the full check on the installed copy.

**Reason.** The clone is the snapshot that gets activated, so hashing it closes the window between verification and copying. Hashing the source as well would double the cost of a 1.8 GB data image. §8.3 describes the steps for an archive, and the directory path follows the same order.

## IR-347: Refuse an install of a lower version, and offer no rollback command yet

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §2.3; [android-image.md](../02-design/android-image.md) §10.3 |

**Choice.** `install(from: .directory)` throws `downgradeRejected` for a version below `current`, ordered by year, month, and sequence. `setCurrent` can move back to `previous`, but no command or API exposes that as a rollback.

**Reason.** §2.3 says APKRun never activates a lower version automatically. A developer install is manual, but a monotonic rule that holds for every path is safer than a manual exception. A rollback command belongs with the activation commands of #058 and #066. For now, a developer who needs an older stock bundle has to choose a higher `--image-version`.

## IR-348: Keep the zero blocks of RAW data as holes in the disk writer

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #011 (writer), #065 (acceptance: sparse `os.img`) |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.3, §10.2 |

**Choice.** `write_skipping_zeros` writes only the 4 KiB blocks of RAW chunks and raw partitions that hold a non-zero byte. The writer used to write every zero byte, so the stock `os.img` took about 8.3 GB where its data is 1.8 GB.

**Reason.** §10.2 requires a sparse `os.img` whose physical size is about the data. The file contents read back the same, because a hole reads as zeros. The disk tests check that a zero run stays unallocated, and the real build allocates 1.8 GB. This changes #011's writer, so the maintainer should confirm it.

## IR-349: Keep the Python tests inside the worktree, and link the XcodeGen tool into it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065; the test environment |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) |

**Choice.** The bundle tests write their layouts under `build/apkrun-image-tests` instead of `Images/work`. `scripts/tests/run.sh` needs `build/tools` linked into a worktree for its XcodeGen check.

**Reason.** In a worktree `Images/work` and `build/tools` are git-ignored symlinks to the main checkout. `Path.resolve()` took the layout outside the repository, and `bundle` refused it, so three tests failed in a worktree before this change. The other test helpers that write under `Images/work` have the same problem and are not changed here.

## IR-350: Run G2 with a 60-second dwell in this task

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 (G2), #065 (acceptance: boot from the installed bundle) |
| Affected documents | [android-image.md](../02-design/android-image.md) §17; [run-gate.sh](../../scripts/run-gate.sh) |

**Choice.** The five-cold-boot G2 test ran with `TEST_RUNNER_APKRUN_G2_DWELL_SECONDS=60` instead of the 600-second default. All five boots reached `sys.boot_completed=1` from the installed bundle, and the test passed.

**Reason.** The full run holds the shared VM lock for about 55 minutes, and two other agents were queued for it. The gate itself keeps its 600-second default. The 10-minute stability of the installed image is therefore not re-verified here. The maintainer should run `scripts/run-gate.sh G2` from a clean `main`.

## IR-351: Refuse to boot an instance that was made from another image version

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065; migration is #058 |
| Affected documents | [android-image.md](../02-design/android-image.md) §9.3, §12.3, §14.1 |

**Choice.** `apkrun dev boot` throws `instanceCorrupt` with the remedy `--reset` when `instance.json` names another image version. `apkrun dev image install` reports the mismatch and leaves the instance as it is.

**Reason.** Migrating an instance's data from one image to another is #058 (§12.3). Booting an instance whose data another image made would fail in unknown ways, so the refusal names the remedy instead.

## IR-352: Leave boot-time compatibility checks out of #065

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065; #066, #058 |
| Affected documents | [android-image.md](../02-design/android-image.md) §9.3 step 3; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1 |

**Choice.** `incompatibleRuntime` and `incompatibleProtocol` are not checked at install or boot. The manifest's `requirements` block is decoded and validated, but not compared with APKRun's version or `components.json`.

**Reason.** The entry's deliverables do not name these checks, and they need `components.json`, which the development CLI does not read. They belong with the first-run provisioning of #066 and the activation of #058. The follow-up is recorded in the M01 notes.

## IR-353: Check that the image version equals the directory name in ImageStore

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.2, §7.2 |

**Choice.** `ImageStore` rejects an installed image whose `imageVersion` differs from its directory name, as `manifestInvalid` at `imageVersion`. The Python validator cannot check this, because it does not know the directory.

**Reason.** §4.2 says the version equals the directory name, which is a property of the installed layout, not of the document. It belongs with the store, which knows the layout.

## IR-354: Fail on a non-APFS volume instead of falling back to a copy

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [android-image.md](../02-design/android-image.md) §14.1 (`cloneUnsupported`) |

**Choice.** A directory install needs `clonefile(2)`. Where it is not supported, the install fails with `cloneUnsupported`, and no copy fallback is written.

**Reason.** A copy of a 1.8 GB data image would not keep the holes, and the fallback would hide a volume that is not APFS. §14.1 gives `cloneUnsupported` for this case. The store's tests run on the APFS temporary directory and fail elsewhere.

## IR-355: Note: the quick verification cache is keyed by the identity of manifest.json and manifest.sig

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.1 |

**Choice.** `ImageStore` caches steps 1–6 of the quick check. The key is the inode, size, and modification time of `manifest.json` and `manifest.sig`, as §7.1 says. Step 7 always runs.

**Reason.** This follows §7.1. A file rewritten in place with the same size and modification time would pass the cache. Install never reads the cache, and `verify(.full)` always hashes the files. Recorded so that a reviewer knows the trade-off.

## IR-356: The release check can name only the developer key of the machine that runs it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065; #093 |
| Affected documents | [build-system.md](../05-development/build-system.md) §3.1 |

**Choice.** The image bundle row refuses a bundle signed with the test key, or with the developer key in `~/.config/apkrun/dev-image-key.pub` on the machine that runs the check. It cannot refuse a bundle signed with another developer's key.

**Reason.** The release job runs on a build machine that holds only its own key, and the spec lists no other keys to compare with. The primary defence is the empty release trust list (IR-341): a Release build refuses every bundle whatever key signed it. The row is a second line of defence for the keys it can know.

## IR-357: Refuse a repeated key and a byte-order mark in manifest.json

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §11, §13 |

**Choice.** Both readers refuse a JSON object that names one key twice, and a document that starts with a byte-order mark. The validator uses `object_pairs_hook` to raise, and ImageCore scans the bytes before it decodes.

**Reason.** §11 defines unknown fields but not repeated keys. Python's `json` keeps the last value and `JSONDecoder` keeps the first, so a validated document could mean different things to the validator and to the device. A byte-order mark is refused because the Python reader does not take one. Both cases are shared fixtures with the rule `schema`.

## IR-358: Refuse a line break in any string value

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §5, §11 |

**Choice.** A string that contains a line feed or carriage return fails the schema, in both readers, before any pattern is checked.

**Reason.** The schema patterns end in `$`. Python's `re` matches `$` before a trailing line feed, so `"sha256": "<64 hex>\n"` passed the Python validator and failed Swift. ECMA regular expressions, which JSON Schema specifies, do not match there. The rule makes the two readers agree without changing the committed schema, which must stay byte for byte as §5 gives it.

## IR-359: Refuse any candidate that is not newer than an installed image, and treat links as unexpected files

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #065 (review of the store, findings 1-6) |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §2.3, §3.1, §4.9, §5; [android-image.md](../02-design/android-image.md) §10.3; [filesystem-layout.md](../01-architecture/filesystem-layout.md) §1 |

**Choice.** Six decisions, one per finding of the review:

1. The downgrade check compares the candidate with every installed image, not only with `current`. The installed images are the version-named directories under `Images/` and the target of `current`, even when that directory is missing. A candidate is refused as `downgradeRejected` when any installed image other than itself is not strictly older than it, so the reported `from` is the highest such image. This covers a missing link and a crash between the rename and the activation, which a hook in the store lets the tests reproduce.
2. A same-triple image with another base is refused, whether its base is lower or higher. §2.3 says such a candidate is not newer, so the check does not order bases. `ImageVersion.<` keeps comparing the triple only, as the spec requires.
3. The schema bounds `userdata.schemaVersion` and `userdata.upgradableFrom` at 9223372036854775807. The reference text in §4.9 and the schema in §5 change with it, and the schema file is regenerated from §5. Swift's `Int` is 64-bit, so both readers now hold the same integers.
4. A link, or any other entry that is not a regular file, is refused as `unexpectedFile` before its size or bytes are read. `lstat` decides, and files are opened with `O_NOFOLLOW`. A link is not `manifestInvalid`, because the bundle holds an entry the manifest does not allow, the same as any extra file.
5. The staged copy loses every write bit, for files and directories, after its full check and before the rename. Removal restores the owner's write bit first, so garbage collection and a failed staging still delete their images. Links are left alone, since `chmod` would follow them.
6. In Debug builds the developer key is read only from a regular file owned by the current user with no group or other write bit. Any other file trusts nothing. The owner check is implemented but not tested, because a test needs a file owned by another user, which needs root.

**Reason.** Each choice follows the spec's text and the rules that the reviewer cited. Choice 2 goes further than the coordinator's wording ("a lower base"): §2.3 says a same-triple candidate is not newer, and a higher base is not newer either, so refusing both is the rigorous reading. Choice 3 changes a schema text that §5 gives byte for byte, so the maintainer should confirm it. Choice 4 uses `unexpectedFile` for links, which is how the file walker already reported them. Choice 5 makes the installed tree match the store's documented read-only rule, and it adds the restore step that removal needs.

**Follow-up: writable instance clones (IR-337, branch fix/065-writable-instance-clones, cbaaf36).** Choice 5 made the installed tree read-only, and `clonefile(2)` carries the mode of the template into each clone. Provisioning and the initrd write then failed with EACCES. Every clone that is written after it is made is now cloned with `FileCloner.cloneWritable`, which adds the owner's write bit and keeps the read bits: the instance disk (`InstanceDiskProvisioner`) and the initrd, including its copy fallback (`AndroidBootPlanner.writeInitrd`). The installed templates and the installed ramdisk stay read-only, because the store clones them with the plain clone and never writes the copy. The install staging clones are not written either, so they stay read-only as well. The owner's write bit is the only bit added, so a clone keeps the read bits of its source. Tests clone a read-only template, write to the clone, and check the mode of both files. The provisioning and initrd tests failed on the old code with `cloneFailed` (`NSPOSIXErrorDomain`), which is the reported regression.

| Task | #012, #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #012, #013; [android-image.md](../02-design/android-image.md) §6.4, §13 |

**Choice.** The #012 criterion "the `Kernel command line:` log line equals
`cmdline.txt`" is reworded to "`/proc/cmdline`, read over the Android serial
shell, equals `cmdline.txt`". The check runs in `AndroidBootTests.testReachesInit`
(#013), so the criterion stays open on the #012 branch until #013 runs it.

**Reason.** On VZ the kernel prints `Kernel command line:` before virtio_console
is loaded, so the line never reaches hvc0 and cannot be read from the console
log (IR-306, and the #012 notes). `/proc/cmdline` is the same string, and it can
be read once the serial shell on hvc1 answers, which is after first-stage init.
The criterion's intent, that the kernel gets the exact `cmdline.txt`, does not
change.

**Consequence.** `testKernelBoot` (#012) does not check the command line. Its
`Kernel command line:` assertion is not written, and `dmesg` over the shell
(#013) carries the same line.

## IR-361: Expect bootStalled for a truncated ramdisk, not kernelPanic

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #012 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #012 step 6; [android-image.md](../02-design/android-image.md) §6.5; [runtime-daemon.md](../02-design/runtime-daemon.md) §3.3 |

**Choice.** `AndroidBootTests.testTruncatedRamdiskStallsBoot` (renamed from
`testKernelPanicDetected` in `29eedb2`, because the old name claimed a panic check
it did not make) asserts `failed(.bootStalled(phase: .kernel))` for a ramdisk cut
to half its size, and that no init line appears. The entry expected
`failed(.kernelPanic)`. The panic path stays covered by `BootPhaseDetectorTests`
over captured console logs, and no T2 check produces a live panic.

**Reason.** The ramdisk is legacy LZ4, and the kernel unpacks it before
first-stage init runs. `virtio_console` is a module in that ramdisk, so hvc0
does not exist yet when the unpacking fails, and the panic text reaches no
console the host can read. The boot then makes no progress, and the stall
limit ends it. A cut that lets first-stage init start would need a chosen
archive offset, and it would test a different failure. The stall outcome was
observed: the first run stopped at `bootStalled(kernel)` after 30 s with no
init line.

**Consequence.** `Kernel panic - not syncing` on hvc0 remains the detector's
signal for panics after `virtio_console` is loaded. A reviewer can accept the
stall as the observed outcome, or ask for a deliberately chosen cut point as a
follow-up.

## IR-362: Check /proc/bootconfig on Android, because the test kernel has no CONFIG_BOOT_CONFIG

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #012, #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #012 step 5 and criteria, #013; [android-image.md](../02-design/android-image.md) §6.3, §6.5 |

**Choice.** `LinuxGuestBootconfigTests.testBootconfigTrailer` is written. It
merges a golden input with `BootconfigWriter`, appends the trailer, and compares
the kernel's listing with the merged block by key. On the pinned test kernel it
skips, and the skip reason carries the kernel's dmesg line. The #012 criterion
"`/proc/bootconfig` equals the merged block" stays open on this branch. #013
checks `/proc/bootconfig` over the Android serial shell (`testReachesInit`).

**Reason.** The test kernel is Alpine `linux-virt` 6.18.54. Its dmesg reports
`WARNING: 'bootconfig' found on the kernel command line but CONFIG_BOOT_CONFIG
is not set.`, and `/proc/bootconfig` is absent. Step 5 of #012 allows a skip
with the reason and places the check on Android in #013. Changing the pinned
kernel's configuration is a ThirdParty change and out of scope for #012.

**Consequence.** The #012 criterion is not ticked by this branch, and the
Android check decides it. The listing parser has a test that runs without a
VM, so the comparison logic is exercised on every kernel.

## IR-363: Record the forced-stop hang after a VZ stop error

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #012, #014 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #012, #014; [vm.md](../02-design/vm.md) §9.3 |

**Choice.** The T2 Android tests bound each stop at 60 s with
`ConsoleBuffer.completes(within:)` and fail with "the forced stop returns within
60 s" when it does not return. The first version of this entry left the
`VMController` fix to #014; it landed in #012 (see Consequence).

**Reason.** `AndroidBootTests.testKernelBoot` stops the VM about one second
after `init`. In one of three runs, VZ returned `vm.stoppedWithError`
("Internal Virtualization error"), the controller moved to `failed`, and the
stop did not return. The run printed no further lines, so the hang was not
traced past `RuntimeSupervisor.stop()`, `fail()`, and
`VMController.waitForConsoleLogDrain()`. The other two runs stopped cleanly in
0.3 s. `RuntimeSupervisor.stop()` and `fail()` were rewritten in #012 (the
stop-during-boot fix), but the VZ error and the hang come from `VMController`,
which #012 does not change.

**Consequence.** The hang is fixed in `0e32d62` (`fix(vm)`, on
`task/012-android-kernel-boot-closure`): `VMController` releases the VM after a
failed stop, and `waitForConsoleLogDrain()` releases a failed VM, so a stop that
follows a VZ error returns. The 60 s bound stays in the T2 tests as a guard. The
#012 entry records the fix. The G2 gate found no hang in its runs.

## IR-364: Accept the unsigned development vbmeta messages in the AVB check

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #013 step 4; [android-image.md](../02-design/android-image.md) §6.6, §13 CF-16 |

**Choice.** The step 4 check "no `libfs_avb` error lines" allows four messages
of the unsigned development vbmeta: `OK_NOT_SIGNED`, "public key data shouldn't
be empty", "Found unknown public key", and the `VerificationError` status for
`/system` and `/system_dlkm`. The test requires that AVB output is present, so
the check cannot pass on an empty log.

**Reason.** The development bundle is unsigned (android-image.md §10.2, replaced
by #065), so AVB cannot verify it. With `verifiedbootstate=orange` the boot
continues, and the dm-verity tables are built as on a signed image. Failing on
these lines would fail every development boot without testing anything more.

**Consequence.** Release images (§11.4) are signed, so they must not produce
these messages. #035 must check AVB without this allowance.

## IR-365: Expect the built-in and bootconfig tokens before cmdline.txt in /proc/cmdline

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #012, #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #012 criterion 2; [android-image.md](../02-design/android-image.md) §6.4, §6.6, §13 CF-17 |

**Choice.** The #012 criterion "`/proc/cmdline` equals `cmdline.txt`" (IR-360)
is reworded to "`/proc/cmdline` ends with `cmdline.txt` unchanged, and the
tokens before it are the bootconfig `kernel.*` key and the kernel's built-in
command line, in that order. `AndroidBootTests.testReachesInit` asserts the exact
value: `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size=16384`
from bootconfig, then the built-in `console=ttynull stack_depot_disable=on
cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig`
(present in the Android kernel image), then `cmdline.txt`.

**Reason.** The kernel appends the bootconfig `kernel.*` keys to its command
line, and it starts from its built-in `CONFIG_CMDLINE`. The reference kernel
prints the same built-in prefix. APKRun passes `cmdline.txt` as the boot command
line, and the kernel's own prefix is not APKRun's to remove.

**Consequence.** A reviewer may want `/proc/cmdline` to equal `cmdline.txt`
exactly. That needs a kernel built without the built-in command line, which is
outside #012 and #013.

## IR-366: Add log_buf_len=2M so that dmesg keeps the boot

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #013 step 1; [android-image.md](../02-design/android-image.md) §6.4, §6.6, §13 CF-18; `Images/tools/layouts/cuttlefish-phone-arm64.json` |

**Choice.** The layout's command-line additions get `log_buf_len=2M`, after
`console=hvc0`. Every bundle built from the layout then carries it, so the
`cmdline.txt` of the bundle changes.

**Reason.** Step 1 allows a command-line addition when the kernel's log lines do
not reach the shell at the default level. The default 256 KiB buffer had wrapped
by the time the shell answered. The shell's `dmesg` held 1,021 lines and none of
the first-stage, kernel-start, or command-line lines. A 2 MiB buffer holds the
whole boot, about 4,000 lines, at a cost of 2 MiB of kernel memory.

**Consequence.** `Kernel command line:` and the first-stage lines are in `dmesg`,
as step 1 expects. The #014 G2 run uses the bundle with this addition.

## IR-367: Derive the reference differences from the launcher's bootconfig and command line

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #013, #014 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #013 and #014; [IR-305](#ir-305-re-scope-064-and-keep-virtualizationframework-instead-of-qemu); `Images/reference/16373615/expected-differences.yaml`; [android-image.md](../02-design/android-image.md) §6.6, §13 |

**Choice.** `expected-differences.yaml` lists 25 bootconfig entries and 5 cmdline
entries. They come from comparing the launcher's `internal-bootconfig.txt` and
the `Kernel command line:` line of `kernel.log` with the planner's merged block
and `cmdline.txt`. Each entry names the design section that decides the value.

**Reason.** The reference capture is incomplete (IR-305). It has no booted
`/proc/bootconfig`, no `cmdline.txt`, and no `lsmod` or `getprop`. The launcher's
internal bootconfig is the only reference bootconfig, and the keys it lacks are
the ones the reference takes from vendor_boot and the bootloader. APKRun sets
those in its own layers (§6.2).

**Consequence.** `compare_boot.py` reads a category only from a file it knows
(`FILE_CATEGORIES`). `kernel.log` is not one, so the cmdline category cannot be
compared yet. #014 decides how the reference command line is read, and the five
cmdline entries wait for that decision.

## IR-368: Check by-name against the manifest and the bootconfig against the planner

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #013 step 3; [android-image.md](../02-design/android-image.md) §4.2, §6.6 |

**Choice.** The `/dev/block/by-name` check takes its expected names from the
bundle's manifest (`disks[].partitions[].label`), not from a reference list. The
bootconfig check compares `/proc/bootconfig` with the entries
`AndroidBootPlanner` merges for the same instance.

**Reason.** No booted reference by-name list exists (IR-305). The manifest is
what the disk plan (§4.2) was built from. The planner's merged block is what the
kernel must show, and a hand-written golden would copy it and go stale when the
layout changes.

**Consequence.** A partition the manifest does not list is not checked, and
neither are dm devices that init creates.

## IR-369: Keep the balloon device without a driver

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #013; [android-image.md](../02-design/android-image.md) §6.6 |

**Choice.** The VZ memory balloon stays in the definition (`memoryBalloon: true`).
On build 16373615 no driver binds it.

**Reason.** The balloon device (virtio id 5) is present. The first-stage ramdisk
has no balloon module, and the boot shows no balloon line. An unbound device
costs nothing. Shipping the module is an image change for memory reclaim, which
no M1 check needs. The reference's binding is unknown, because it was never
booted.

**Consequence.** Host-side memory reclaim is inactive. #014's capture records the
binding. An image change (#035 or later) decides whether the module ships.

## IR-370: Keep shell commands short and read long output from a guest file

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #013 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #013 (`AndroidShellConsole`); [android-image.md](../02-design/android-image.md) §6.6 |

**Choice.** The T2 shell checks keep each command short. They write `dmesg` to a
file on the guest and grep that file. Patterns use bracket classes (`[f]irst`),
so the echoed command cannot match itself.

**Reason.** The Android shell on hvc1 echoes each typed command, and a long line
comes back with line-editing redraws. A 220-character `dmesg | grep` came back
garbled. Its echo matched the patterns, which made a run look as if the kernel
lines were present. `su 0 dmesg` in the first version did not answer within
60 s.

**Consequence.** A later check that needs long output uses the same pattern.
`AndroidShellConsole` does not add a wrapping layer.

## IR-371: Pass the port-marker check for the ports the test kernel exposes, and skip the 20-port check

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #095 step 1 and its criterion; [android-image.md](../02-design/android-image.md) §7.8 |

**Choice.** `LinuxGuestConsolePortTests.testConsolePortMarkersMatchTheirNumbers`
attaches eight ports and checks the marker of each one on its own `/dev/hvc<i>`.
It passes. `testTwentyConsolePorts` attaches twenty ports and skips, with the
kernel's reason, when it reaches a missing `hvc` node. It does not fail.

**Reason.** The pinned test kernel (Alpine `linux-virt` 6.18.54) creates
`/dev/hvc0` through `/dev/hvc7` and no more, with ten or twenty ports attached
(IR-372). A skip with the reason is the form #012 step 5 used for the
bootconfig check. A failing twenty-port test would block every Linux guest run,
and the Android guest shows that VZ itself creates the twenty nodes.

**Consequence.** The #095 criterion "all 20 console ports are attached, and
their numbering is verified with markers" stays open. Closing it needs a test
kernel that exposes twenty `hvc` nodes (a ThirdParty pin change, outside #095)
or a marker method that works on the Android guest.

## IR-372: The pinned test kernel exposes eight hvc consoles, and the Android kernel exposes twenty

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 |
| Affected documents | [android-image.md](../02-design/android-image.md) §7.8; [vm.md](../02-design/vm.md) §6.1; [risks.md](risks.md) R-12 |

**Choice.** Recorded as a finding. The Linux test guest's kernel creates
`/dev/hvc0` to `/dev/hvc7` for the twenty-port layout, and its dmesg shows
thirteen virtio-pci devices, all enabled. The Android kernel (6.12) creates
`/dev/hvc0` to `/dev/hvc19` on the same VZ configuration, as the VZ capture
lists.

**Reason.** The test shows the console nodes that exist, and the failing node
is `/dev/hvc8`. The Android kernel's log buffer and numbering differ from the
Alpine kernel's. The cause in the Alpine kernel was not traced further (its
configuration is not in the pin). No VZ-side change would fix it, because the
Android guest on the same attachments has all twenty.

**Consequence.** The numbering check runs with eight ports on the test kernel.
For the Android guest, the holders in the VZ capture (`hvc1` for the shell,
`hvc2` for logcat, `hvc18` for sensors) are the only evidence of the numbering.

## IR-373: Do not apply ConsolePortPlan on the boot path, because VZ numbers the ports as attached

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #095 step 1; [android-image.md](../02-design/android-image.md) §7.1 |

**Choice.** `ConsolePortPlan` is a data function with T0 tests (identity,
permutation, and rejected mappings). The boot path does not call it.

**Reason.** The eight-port marker test shows the identity mapping on VZ, so
there is no order to correct. The product does not run the port test, so it
has no device-number evidence to feed a plan at boot. Wiring the plan into the
boot without evidence would add a mapping that nothing checks.

**Consequence.** If a later kernel or VZ release changes the numbering, the
port test fails first. The plan then gets its mapping from that test's output.

## IR-374: The network does not come up after the first boot, so #095's network criterion stays open

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 (follow-up for the first boot's Wi-Fi join) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #095 criteria and notes; [android-image.md](../02-design/android-image.md) §7.4, §7.6, §7.8 |

**Choice.** The network check is #095's open T2 check, not a condition of #014. It
is `AndroidNetworkTests.testNetwork` (moved from `AndroidBootTests` in `3099d9a`),
and it runs only in the `AndroidNetwork` configuration of `IntegrationTests`. It
checks the design's configuration: an IPv4 address on `wlan0`, a default route
through vmnet, name resolution with `getent`, and the validated WIFI network. Each
stage is polled for up to 120 s, and each assertion reads the stage's last value.
The stage that fails intermittently is the validated one. #095's network criterion
stays open.

**Why it moved.** The check stayed in the AndroidBoot configuration, which is the
#014 T2 set. There it failed the configuration on a stage that the G2 conditions do
not include. CI (`integration.yml`) and the gate (`scripts/run-gate.sh`) select only
the LinuxGuest and G2 configurations, so a separate configuration keeps the check
out of both, and it stays runnable by hand with `-only-test-configuration
AndroidNetwork`. The test is kept, not deleted.

**Reason.** The 21:13 run (`/tmp/apkrun-m1-ab-final`) failed because the check
ran once, right after `ready`. Its `wifi:` record says `Wifi is disabled`, and
`wlan0` has no carrier. The first join finishes later: in the later runs the
same boot reports `Wifi is connected to "VirtWifi"` with `192.168.64.25`, and
the address, the route, and DNS pass within the poll. So the first-boot Wi-Fi
state is a timing problem, not a permanent disable, and the earlier description
of a network that stays down is withdrawn. The remaining failure is the
validated stage: the WIFI `NetworkAgentInfo` line carries `INTERNET` and not
`VALIDATED`, because the captive-portal probe has not succeeded. Of the five
polled runs, one validated (27 s) and four did not within 120 s. The probe needs the
test host's NAT to reach the internet, which this lab does not guarantee; the
cause was not traced further.

**Consequence.** `testNetwork` can fail on the validated stage, and that failure is
#095's open network check, not a #014 failure. The #014 gate evidence (G2) does
not depend on it, and the AndroidBoot configuration does not run it. #095's
criterion for the validated network stays unchecked until a run validates
reliably or the probe's dependence on the host is ruled out.

## IR-375: Record categories the launcher capture lacks as not compared, and read the reference command line from kernel.log

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 (step 5) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #014 step 5; [android-image.md](../02-design/android-image.md) §8.4; [IR-305](#ir-305-re-scope-064-and-keep-virtualizationframework-instead-of-qemu); [IR-367](#ir-367-derive-the-reference-differences-from-the-launchers-bootconfig-and-command-line) |

**Choice.** `compare_boot.py` lists a category as not compared when the reference
holds no data for it and the candidate does, and the category is not bootconfig
or cmdline. The report lists those categories (`notComparedCategories`). A
category with data on one side only stays a difference, and so does a
candidate-only bootconfig or cmdline. The reference command line comes from the
`Kernel command line:` line of `kernel.log`, which the launcher capture holds.

**Reason.** The launcher capture has no booted data for props, block devices,
mounts, modules, HALs, hvc users, network, and SELinux (IR-305), and the step 5
text says those are recorded, not compared. Bootconfig and cmdline are the two
categories the launcher does hold, so skipping them would hide a real change.

**Consequence.** The G2 diff compares bootconfig and cmdline and records the
other eight categories. The VZ capture of 2026-10-09 gives 30 differences, all
explained (25 bootconfig, 5 cmdline), and exit 0.

## IR-376: Run the G2 gate from a task branch with the same commands as run-gate.sh

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 (step 6) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #014 step 6 and its criteria; [build-system.md](../05-development/build-system.md) §15 |

**Choice.** The G2 gate ran from commit `691e114` on `task/014-system-server-boot`
(rebased onto `main` at `0770318`) with the same `xcodebuild` steps as
`scripts/run-gate.sh` (the LinuxGuest suite, then G2 with the default 600 s dwell),
under `lockf -k /tmp/apkrun-vm.lock`. Result: LinuxGuest 49 run, 16 skipped, 0
failed; G2 passed, 6 run, 3 skipped (the other acceptance suites), 0 failed, in
3063 s. The artifacts and the bundle came from `/tmp/apkrun-m1-linux`, which this
task built with `scripts/build-test-initramfs.sh` and
`scripts/build-test-android-bundle.sh`.

**Reason.** `run-gate.sh` refuses to run unless the branch is `main`, and it
refuses unless the tree is clean. Neither holds on a task branch: `Images/work`
and the other ignored artifacts are symlinks into the main checkout, which Git
lists as untracked. The gate's evidence rule is `main`; running it here is the
only way to measure the stack before it merges.

**Consequence.** The #014 entry records the result as evidence from the task
branch, not from `main`. The G2 result must be repeated from a clean `main`
after the branches merge, as the #014 entry requires. Two gate runs before
`691e114` failed on bugs the gate exposed, and their fixes are on the branch:
the stale `.stopped` state of the VM controller ended every boot (`b2aa305`),
and the reference diff did not find `expected-differences.yaml` (`6da60d7`).
`scripts/run-gate.sh` now removes the dwell overrides before any run and records
`dwell_seconds` in the G2 report (`30446a0`), so a branch run cannot silently use a
shorter dwell.

**Reason.** `run-gate.sh` refuses to run unless the branch is `main`, and it
refuses unless the tree is clean. Neither holds on a task branch: `Images/work`
and the other ignored artifacts are symlinks into the main checkout, which Git
lists as untracked. The gate's evidence rule is `main`; running it here is the
only way to measure the stack before it merges.

**Consequence.** The #014 entry records the result as evidence from the task
branch, not from `main`. The G2 result must be repeated from a clean `main`
after the branches merge, as the #014 entry requires.

**The clean-main gate stopped at LinuxGuest (2026-10-10).** The gate on `main` at
`424a171` failed in `LinuxGuestAndroidDiskLayoutTests.testAndroidDiskLayout`:
"Android disks are missing." The cause is the gate's artifact directory.
`run-gate.sh` defaulted to `${TMPDIR:-/tmp}/apkrun-test-linux`, and on macOS
`TMPDIR` is `/var/folders/.../T/`. Every producer script and the test harness
default to `/tmp/apkrun-test-linux`. The gate built the kernel, the initramfs, and
the Android bundle in the `$TMPDIR` directory, and no step built the Android disks
there, because `run-gate.sh` never ran `scripts/build-test-android-disks.sh`. The
shared `/tmp/apkrun-test-linux` had the disks, but the gate never read it. The test
host is not sandboxed (`ENABLE_APP_SANDBOX: NO`). It reads the directory from its
Info.plist, which expands the build setting `APKRUN_TEST_LINUX_DIR` the gate passes;
the built host of the failed run carried the `$TMPDIR` path. The environment
variable is read first by the harness, but in a gate run both carry the same value,
so the build setting is the one that matters.

**Decision and fix (`4b7a6ea`).** The gate defaults to `/tmp/apkrun-test-linux`, the
directory the producers and the harness use. Both gates build the Android disks, so
no run depends on disks from an earlier build. Before any test runs, the gate checks
the files its test plans read (`scripts/tools/verify-gate-artifacts.sh`), builds the
test host, and checks that the host's Info.plist reads the same directory
(`scripts/tools/verify-test-host-directory.sh`). The report records
`artifact_directory`. `scripts/tests/test_gate_artifacts.sh` covers both verifiers
and the order of the steps. The harness's environment-first lookup is unchanged.

**Review decisions on the gate's integrity (2026-10-09).** An independent review
of `0c5ad6c` raised two points on the gate's evidence. Both are recorded here for
maintainer review; the first is changed, the second is not.

- *Retries (changed, `57a3d5f`).* The IntegrationTests plan retried each failing
  test once (`retryOnFailure`, one repetition). A LinuxGuest test that failed once
  and passed on retry was green in the gate. The retry is removed from the plan's
  defaults, so each failure counts. The AcceptanceTests plan never had a retry.
- *Skips count as passes (recorded, not changed).* The gate counts a skipped test
  as a pass, because `xcodebuild` reports a skip as success. `BootconfigTests`
  (`LinuxGuestBootconfigTests.testBootconfigTrailer`) skips under LinuxGuest on the
  pinned kernel, and the AndroidPackage tests skip when the HelloText fixture is
  missing. The gate report records the status of the run, not the skip count; the
  counts are in the result bundles. Changing the gate to count skips as failures is
  a maintainer decision.

## IR-377: Keep dmesg and logcat out of the G2 capture, because the serial shell is slow

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 (step 5) |
| Affected documents | [android-image.md](../02-design/android-image.md) §8.3, §8.4; `Images/tools/reference/guest-capture-compare.txt` |

**Choice.** The G2 capture runs `guest-capture-compare.txt`, which has the
fourteen cheap commands of `guest-capture.txt`. It leaves out `dmesg`,
`logcat -d`, `lshal`, `dumpsys connectivity`, and the AVC greps. The full list
stays for the launcher-style capture (`capture-vz --commands guest-capture.txt`).

**Reason.** Over hvc1 the `dmesg` capture (about 4,000 lines) and `logcat` did not
finish within five minutes, and `properties` (28 KB) took about a minute. The
comparison reads only bootconfig and cmdline (IR-375), so the slow commands add
no evidence to the gate. The full capture is still available for a manual run.

**Consequence.** The VZ boot's dmesg and logcat are not in the G2 record. Their
checks (AVC, the first-stage lines, LockSettings) are in T2 (`testReachesInit`,
`testHostServiceSubstitutes`), which read the kernel log through a file.

## IR-378: The developer console serves one client, and a socket closes with its VM

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 (step 4) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #014 step 4; [cli.md](../02-design/cli.md) §5 |

**Choice.** `apkrun dev boot` serves hvc0 and, in developer mode, hvc1 on
sockets under `Runtime/dev-console/`. One client is attached at a time, and a
second client is closed at once. A socket file exists only while its VM runs,
and `stop()` removes it. A `serve` after `stop()` fails with
`devConsoleSocketUnavailable`. A client whose socket path is too long is told
`devConsoleNotRunning`, because such a path cannot be a running owner's socket.

**Reason.** Two clients would interleave shell commands and their sentinels, and
the shell has one prompt. Keeping the socket only while the VM runs gives the
"no owner" error a single meaning. The bounded path length follows
`sockaddr_un`.

**Consequence.** A second `apkrun dev console --android-shell` waits for the
first to exit (it is refused at once). A future multi-client console needs a
protocol for the sentinels first.

## IR-379: Follow-ups from the #014 review that this task does not fix

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #014 (follow-ups) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #014; [vm.md](../02-design/vm.md) §9.3 |

**Choice.** Recorded, not fixed here:

- `VMController.stop()` during `starting` is rejected (`VMController.swift`, the
  `stopWithinOperation` allow-list), and `waitForConsoleLogDrain()` waits on a
  console task that starts before the driver does. A VM stopped while it starts
  keeps running, and `stop()` never returns. The dev boot does not stop during
  boot, so this is not reachable from `apkrun dev boot`.
- The Linux guest's CLI path (`apkrun dev console`, not `--android-shell`) has
  the same EOF behaviour the attach command had, and it is not part of #014.
- `apkrun dev console --android-shell` reports a too-long socket path as "not
  running" rather than as an unavailable socket (IR-378).

**Reason.** The first item is a VM lifecycle defect that the dev boot cannot
reach, and fixing it needs a change to the controller's start path that is not
part of #014's readiness work. The rest are noted for the owner tasks.

**Consequence.** #014 does not claim that a stop during VM start works.

## IR-410: Copied RiftVM MSAA code ships under a reference pin

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #018, #020 |
| Affected documents | `ThirdParty/patches/virglrenderer/0002-downgrade-unsupported-msaa.patch`; `ThirdParty/ThirdParty.lock.json` (`riftvm`, `virglrenderer`); [riftvm-analysis.md](../02-design/riftvm-analysis.md) §4, §5; [graphics.md](../02-design/graphics.md) §5.1; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.1, §3.2, §4.1 |

**Choice.** Treat `virglrenderer/0002` as copied RiftVM MIT code. Reclassify the `riftvm` lock entry from `ships: reference` to `ships: derived`, and add the RiftVM MIT text and the marked file list to the generated notices, as [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.1 requires. The patch header keeps the `f615e16` origin and also cites the pinned commit `51f19193`. The rule as written requires this change, so this entry records it as the choice. The alternative is an independent rewrite of the downgrade, which would keep the `reference` pin. That needs new code and review, so it is not chosen here. #018 does not make the change, because its acceptance criteria require the pin to stay source-only and IR-188 chose `reference`. Release artifacts that contain the runtime wait for the change.

**Reason.** `virglrenderer/0002` carries RiftVM's `virglrenderer-msaa-downgrade.patch`. Its added lines equal the code of `scripts/virgl-patches/virglrenderer-msaa-downgrade.patch` at the pinned commit, apart from blank-line placement, and its comments say "RiftVM:". The patch is shipped in APKRun's virglrenderer dylib (`ships: app`). So it is copied RiftVM code, and [legal-and-licensing.md](../05-development/legal-and-licensing.md) §4.1 defines `reference` as "not built, copied, linked, or distributed". §3.1 requires the lock entry to become `ships: derived` when APKRun copies RiftVM code. IR-188 chose `reference` on the premise that no RiftVM code is copied, and that premise does not hold for this patch. The header cites `f615e16`, not the pinned commit, so the §3.1 marker does not match the pin either. §3.2 keeps the original `From:` author, who matches the author of `f615e16`, so attribution is right. The gap is the notice and the classification.

**Verification.** On 2026-10-10 the added lines of `0002` were compared with the pinned file, `f615e16` was confirmed to exist upstream (2026-09-19, same author as the patch's `From:` line), and the shipped code was confirmed to carry the `RiftVM:` comments. `scripts/check-lock.sh` passes because it does not inspect code for copies. The `scripts/check-licenses.sh` checker that would test the marker is planned for #093 and is not in this checkout.

## IR-411: ANGLE patch omits the Vulkan-backend hunk of the recipe

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #020; follow-up to the Vulkan track (#096) |
| Affected documents | `ThirdParty/patches/angle/0001-fix-metal-boolean-mix.patch`; [riftvm-analysis.md](../02-design/riftvm-analysis.md) §4; [graphics.md](../02-design/graphics.md) §5.1 |

**Choice.** Keep `angle/0001` without the recipe's `VertexArrayVk.cpp` hunk for v1. Record that the hunk, or an equivalent fix, must be applied before the ANGLE Vulkan backend is enabled, and that the Vulkan track (#096) owns that step. #018 changes no patch.

**Reason.** The recipe's `angle-changes-main.patch` changes four files. APKRun's `angle/0001` changes three, and it leaves out `src/libANGLE/renderer/vulkan/VertexArrayVk.cpp`, where the recipe replaces `bufferVk->getSize()` with `bufferHelper.getSize()` in the `padVertexAttribBufferSizeIfNeeded` call. The pinned Vulkan renderer's `BUILD.gn` asserts `angle_enable_vulkan`, and the lock sets `angle_enable_vulkan=false`, so the Metal-only library does not compile that file. The omission therefore does not change the v1 library. But no record shows that the omission was intended, and a later Vulkan build would differ from the recipe.

**Verification.** On 2026-10-10 the two sequences were applied to copies of the pinned ANGLE files that the patches touch. The only difference was that one line. The `BUILD.gn` assertion was read from the pinned archive. #020's build evidence (IR-191) does not cover a Vulkan build.

## IR-412: Carried patch headers do not record upstream status

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #020 |
| Affected documents | `ThirdParty/patches/virglrenderer/0001-add-macos-metal-support.patch`; `ThirdParty/patches/virglrenderer/0002-downgrade-unsupported-msaa.patch`; `ThirdParty/patches/angle/0001-fix-metal-boolean-mix.patch`; `ThirdParty/patches/libepoxy/0001-improve-library-detection.patch`, `0002-disable-desktop-extensions-on-gles.patch`, `0003-enable-egl-platform-display.patch`; [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3.2 |

**Choice.** Each carried patch header gets one line that states whether the patch was sent upstream, and where. This is a follow-up to the #020 patch set. #018 does not edit patch files.

**Reason.** §3.2 requires the patch header to keep the author, the reason, and whether the patch was sent upstream. `virglrenderer/0003` states "Upstream: not submitted". The carried patches state only their recipe or RiftVM origin. The libepoxy headers are series patches (`[PATCH n/3]`) and do not say whether they were merged or submitted. Without that line, a reviewer cannot check the upstream status of these patches from the files.

**Verification.** On 2026-10-10 each of the six headers was read. None of them states an upstream status. The one APKRun patch that does, `virglrenderer/0003`, is not in this list.

## IR-413: Renderer flags that RiftVM does not pass

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #020 |
| Affected documents | `ThirdParty/ThirdParty.lock.json` (`buildFlags` of `virglrenderer`, `libepoxy`, and `angle`); [riftvm-analysis.md](../02-design/riftvm-analysis.md) §4; [graphics.md](../02-design/graphics.md) §5.1 |

**Choice.** Keep the three flags that RiftVM does not pass: virglrenderer `-Dplatforms=egl`, libepoxy `-Dglx=no`, and ANGLE `mac_deployment_target="27.0"`. The maintainer confirms them at the next #020 build review. #018 changes no build input.

**Reason.** The flags match the v1 scope, which is a macOS 27 Metal-only renderer. For virglrenderer, RiftVM's default `platforms=auto` already selects EGL on macOS when libepoxy reports it, as the pinned `meson.build` shows. So `-Dplatforms=egl` makes a missing EGL a build error instead of a silent omission, and it does not change the compiled winsys. For libepoxy, `-Dglx=no` removes GLX, which is not used on macOS; the expected effect is nil, but libepoxy's `meson.build` was not read for this entry. For ANGLE, RiftVM's GN arguments do not set `mac_deployment_target`, so the minimum OS of the shipped libraries follows the SDK default. The lock sets 27.0 to match the product minimum. The effect of the default was not measured.

**Verification.** On 2026-10-10 the flags were compared with the pinned `build-virgl-runtime-from-source.sh` and with the lock. The virglrenderer `platforms` handling was read from the pinned `meson.build` with the recipe patch applied. #018 ran no build. The #020 build (IR-191) ran with these flags; whether they change the runtime's behavior is not established.

## IR-380: Refuse a GPU profile that the device does not offer

| Field | Value |
|---|---|
| Status | Needs maintainer review; the drmVirgl refusal is superseded by IR-580 |
| Task | #021 (step 1) |
| Affected documents | [M02](issues/M02-graphics.md) #021, #022; [graphics.md](../02-design/graphics.md) §9; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.7; [error-catalog.md](../03-reference/error-catalog.md) §7.2 |

**Choice.** `RuntimeSupervisor` checks the profile's `requiredHostCapabilities`, from the bundle manifest, against the names of the device's features (`VirtioGPUDevice.hostCapabilities`: `edid`, and `virgl` once the renderer offers it). A profile the device cannot satisfy fails with `runtime.gpuProfileUnavailable` before the instance is read or the initrd is written. `drmVirgl` fails this way until #022. The entry is `cliExit` 1 with action `none`.

**Reason.** Without the check, a `drmVirgl` boot would start without `VIRTIO_GPU_F_VIRGL`, although the profile's bootconfig selects Mesa's VirGL path (`androidboot.hardware.egl=mesa`). The problem would then surface inside the guest, not as a host error. The manifest already names the features a profile needs, so the check uses that vocabulary and does not hard-code a list of profiles.

**Consequence.** `drmVirgl` cannot boot in this build, and `--gpu virgl` is refused (IR-382). #022 offers `VIRTIO_GPU_F_VIRGL` in the descriptor, and this check then passes without a change to it.

**Superseded by IR-580 for drmVirgl.** The refusal of drmVirgl is removed, before its boot is verified on the VM, and `--gpu virgl` is offered (IR-584). The check itself stays: a profile whose bundle entry is missing, or whose device lacks a required feature, is still refused with `runtime.gpuProfileUnavailable` before the VM starts (IR-581). The text of the entry was changed by IR-587.

## IR-381: Append the GPU device in RuntimeSupervisor, for every caller

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 1) |
| Affected documents | [android-image.md](../02-design/android-image.md) §9.2; [vm.md](../02-design/vm.md) §2; [runtime-daemon.md](../02-design/runtime-daemon.md) §3 |

**Choice.** `RuntimeSupervisor.boot()` decides the profile's devices (`AndroidGraphicsDevices.devices(for:requiredHostCapabilities:)`) before it reads the instance. It assigns them to a copy of the planner's `VMDefinition` before validation. The CLI and RuntimeHost pass only the profile.

**Reason.** ImageCore cannot depend on GraphicsCore (modules.md §3), and the planner leaves `customDevices` empty (android-image.md §9.2). RuntimeCore already owns the device list of a boot, and the supervisor is the boot path that apkrund will host, so every caller gets the same device.

**Consequence.** Assignment replaces `customDevices`, so a planner that later fills it would lose its devices silently. The current contract is that the planner leaves it empty, and a later change to that contract needs a check here.

## IR-382: Offer only the GPU profiles of this build in `apkrun dev boot --gpu`

| Field | Value |
|---|---|
| Status | Needs maintainer review; `--gpu virgl` is superseded by IR-584 (the default question stays open there) |
| Task | #021 (step 4) |
| Affected documents | [cli.md](../02-design/cli.md) §5; [runtime-api.md](../03-reference/runtime-api.md) §15; [M02](issues/M02-graphics.md) #021 |

**Choice.** `DevGPUProfile` has `none` (headless) and `swiftshader`. `--gpu virgl` is refused as an invalid argument. The default stays `none`.

**Reason.** A profile that the CLI offers must boot, and `virgl` cannot boot before #022 (IR-380). Keeping `none` as the default leaves the headless bring-up unchanged.

**Consequence.** runtime-api.md §15 names `.virgl` and the default that follows #022 is `virgl`. cli.md §5 lists the values without a default. The maintainer should confirm when #022 changes the default.

**Superseded by IR-584 for `virgl`.** `--gpu virgl` is offered now, and it maps to drmVirgl. The default stays `none`, because a default change needs the verified drmVirgl boot. The question of the default is still open, and IR-584 records it.

## IR-383: Keep the 1024×768 test mode on scanout 0 in #021

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §6.1, §12 (#023 step 3); [android-image.md](../02-design/android-image.md) §6.2 |

**Choice.** The device is created with the default `ScanoutTable`, so scanout 0 is the 1024×768 at 60 Hz test mode. graphics.md §6.1 says that scanout 0 takes the image's default mode at device creation. #021 does not implement that.

**Reason.** No manifest key or capture value fixes the default mode. The reference capture pins `lcd_density` only, and the mode depends on the window and display policy that #023 implements (display-and-windowing.md). The #021 acceptance (only `Virtual-1` connected) holds at any mode.

**Consequence.** Under `guestSwiftshader`, Android's display 0 is 1024×768 until #023. The maintainer should decide whether §6.1's default mode belongs to #021.

## IR-384: Read the DRM connector status as root, through `adb root`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#021 step 2), §16; [test-strategy.md](../04-plan/test-strategy.md) §6.3 |

**Choice.** `AdbClient.restartAsRoot()` runs `adb root`, connects again, and checks that `id -u` is 0. The #021 capture runs as root. A user build refuses `adb root`, so the call throws `commandFailed`. The production path never calls it.

**Reason.** On the development image, SELinux denies the shell domain every read of a connector's `status`, `enabled`, `edid`, `modes`, and `dpms` (`Permission denied`), so the check cannot tell which connector is connected. The guest protocol that would report the DRM state has no Guest Agent yet (guest-protocol.md, guest-components.md).

**Consequence.** The T2 check depends on a development-only root restart (`ro.debuggable=1`). The DRM connector state should come from a guest-protocol query when the Guest Agent exists. That is a follow-up for the guest-protocol owners, not part of #021.

## IR-385: Fall back to the console only for the kernel log

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#021 step 2) |

**Choice.** The kernel log is `dmesg` over adb. If `dmesg` fails, the check uses the hvc0 console text instead. The sysfs captures have no console fallback, so an unreachable adb fails the check. The hvc0 console is always saved as `hvc0-console.log`.

**Reason.** The console carries the kernel's messages, so it is a valid kernel log. It does not carry sysfs state, and a fallback there would be false evidence.

**Consequence.** Step 2's "when ADB is not up, use the kernel console" is applied to the kernel log only. The binding check needs adb.

## IR-386: Read the guest while Android runs, and do not wait for readiness

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §9, §12 (#021) |

**Choice.** The T2 check starts the boot, waits for adb, reads the guest, saves the capture, and stops Android. It does not require `ready`. The summary records the supervisor state and `sys.boot_completed` at capture time.

**Reason.** graphics.md §12 says `boot_completed` is not needed for #021, because the 2D commands fail until #022. Waiting for readiness would tie the check to #022.

**Consequence.** On this host the first capture came while the boot was in `booting(systemServer)`, before `sys.boot_completed`, so the check's evidence is taken early in Android's boot (IR-390).

## IR-387: Keep the captures beside the test bundle and in the test report

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 2) |
| Affected documents | [test-strategy.md](../04-plan/test-strategy.md) §6.3 |

**Choice.** The captures are written to `<APKRUN_TEST_LINUX_DIR>/android-graphics/` (`kernel-log.txt`, `drm-connectors.txt`, `virtio-devices.txt`, `summary.txt`, `hvc0-console.log`) and attached to the XCTest result with `keepAlways`.

**Reason.** The Linux `gpu` check keeps its driver trace beside the guest artifacts (`GPUDeviceTests`). The bundle directory is outside `~/Documents`, as the rule requires.

**Consequence.** The captures are overwritten by the next run of the check.

## IR-388: Run the T2 adb from a copy of the SDK platform-tools, outside `~/Documents`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 6) |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.5; [test-strategy.md](../04-plan/test-strategy.md) §3.5 |

**Choice.** The run that graphics.md §16 records set `APKRUN_ANDROID_HOME=/tmp/apkrun-021-sdk`, a copy of `build/android-sdk/platform-tools` (adb 1.0.41, Android Debug Bridge version 37.0.1-15733141). It is the same binary, not a different adb.

**Reason.** Inside the test host, a child adb blocked in dyld on an `open` under the worktree's `~/Documents` path: `adb version` never returned. The same binary from `/tmp` returned in 0.1 s, and the test then passed. The cause is the macOS file-access rule for `~/Documents`, so the fix is the location, not the code.

**Consequence.** A checkout under `~/Documents` can hang the AndroidADB and AndroidGraphics configurations the same way. The maintainer should decide whether environment-setup.md says where the SDK goes for the test host.

## IR-389: Give the AndroidGraphics configuration its own adb server port

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (step 6) |
| Affected documents | [IntegrationTests.xctestplan](../../Tests/IntegrationTests/IntegrationTests.xctestplan) |

**Choice.** The configuration sets `ANDROID_ADB_SERVER_PORT=15038`. The AndroidADB configuration uses 15037.

**Reason.** Configurations should not share an adb server, because the server keeps transport state between runs. The port change was made while the first runs were being diagnosed. It is not established as the cause of the earlier failure, since port 15038 failed the same way until the SDK location changed (IR-388).

**Consequence.** None for the other configurations.

## IR-390: With `guestSwiftshader`, Android completes its boot before #022

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #021 (steps 1 and 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §9, §12 (#021 notes), §16 |

**Choice.** Recorded as an observation, not as a design change. A CLI boot, `apkrun dev boot --gpu swiftshader`, reached `ready` about 9 s after the VM started. Its console, saved as `cli-swiftshader-boot.log` beside the test bundle's captures, shows `sys.boot_completed=1` at kernel time 8.5 s. The 2D commands (`SET_SCANOUT`, `RESOURCE_CREATE_2D`, `TRANSFER_TO_HOST_2D`, `RESOURCE_FLUSH`) return `VIRTIO_GPU_RESP_ERR_UNSPEC` (`0x1200`), and the kernel logs each one as `*ERROR*`. The T2 capture came earlier, in `booting(systemServer)`.

**Reason.** graphics.md §12 says that `boot_completed` is not required here. This host reaches it anyway, and the error responses did not stop the boot.

**Consequence.** A boot that completes with this profile does not show that the display works. #022 must check the 2D path with rendering, not only `boot_completed`. The maintainer should confirm the wording of graphics.md §12.

## IR-400: Keep the unconfirmed drm_virgl values and leave the layer-2 criterion open

| Field | Value |
| Status | Needs maintainer review |
| Task | #010, #022 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #010 and #022; [android-image.md](../02-design/android-image.md) §6.2; [graphics.md](../02-design/graphics.md) §9; `Images/tools/layouts/cuttlefish-phone-arm64.json` (`gpuProfiles.drmVirgl`) |

**Choice.** The layout keeps the eight `drmVirgl` bootconfig keys. The #010
acceptance bullet "every (reference) value traces to the launcher capture or a
VZ observation" stays unchecked. The maintainer chooses one of two outcomes:
(a) accept the source-derived `drm_virgl` set for #010, let #022 confirm it,
and narrow the bullet to the image layer and the guest_swiftshader and headless
profiles; or (b) empty `gpuProfiles.drmVirgl.bootconfig` until #022 confirms
the keys, so the layout carries only capture-verified values.

**Reason.** Every other image and GPU value traces to the launcher capture or to
the VZ record. The eight `drmVirgl` values trace to neither. Their only source
is `graphics-props-from-source.txt`, which records the Cuttlefish source at
revision `9bb9c72` (`crosvm_manager.cpp`). That file sits under the git-ignored
`Images/work/`, so the repository cannot check it. Removing the keys would
change a profile that #022 needs. Narrowing the bullet changes the milestone's
acceptance text, which is the maintainer's decision.

**Consequence.** #010 stays open. #011 lists #010 as a dependency, so this
decision also decides when #011 starts.

## IR-401: Leave display_framebuffer_format out of the drm_virgl set

| Field | Value |
| Status | Needs maintainer review |
| Task | #022 (from #010) |
| Affected documents | [android-image.md](../02-design/android-image.md) §6.2; [graphics.md](../02-design/graphics.md) §9; `Images/tools/layouts/cuttlefish-phone-arm64.json` (`gpuProfiles.drmVirgl`) |

**Choice.** The layout's `drmVirgl` set has no
`androidboot.hardware.hwcomposer.display_framebuffer_format`, although
`graphics-props-from-source.txt` lists it with `rgba`. The key stays out until
#022 decides.

**Reason.** The file's header says that the `rgba` value is the one observed in
`internal-bootconfig.txt`, which is the guest_swiftshader capture, and that the
source selects `bgra` only when `guest_uses_bgra_framebuffers` is set. The
header does not say that the drm_virgl path sets `rgba`, so the layout follows
the source-derived set. #022 confirms the key on a drm_virgl boot, which needs
the virtio-gpu device.

**Consequence.** If #022 finds the key is needed, the layout gains one entry and
the `drmVirgl` bootconfig changes. The G2 record uses the guest_swiftshader and
headless sets, not `drmVirgl`.

## IR-402: Check the layer-2 values in the tests, not only in the layout's sources text

| Field | Value |
| Status | Needs maintainer review |
| Task | #010, #012 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #010 (acceptance and Tests); [android-image.md](../02-design/android-image.md) §6.2; `Images/tools/tests/test_layout.py` |

**Choice.** `test_layout.py` builds the expected image layer from the committed
launcher capture: the capture keys without the graphics keys and the eight
pinned omitted keys, with the seven decided values of §6.2 applied. The test
fails on any change to a value, a key, or the omitted set. Three further tests
check the guestSwiftshader and headless profiles against the capture's graphics
keys, check that each android-image.md section the layout cites exists, and
check the two command-line additions.

**Reason.** The layout's `sources` block is documentation, and nothing reads it.
The G2 record depends on these values, so a change must fail in the test suite,
not later in a boot. The decided values are written in the test, so changing one
means changing the layout, the test, and the §6.2 record together. The omitted
set is pinned too: when it was read from the layout itself, a key could move
from the image layer into the omitted list without failing any test.

**Consequence.** A later decision that changes one of the pinned values updates
the test in the same change.

## IR-403: Worktree test runs must put the worktree's apkrun_image first

| Field | Value |
| Status | Needs maintainer review |
| Task | #010; parallel work ([workflow.md](../05-development/workflow.md)) |
| Affected documents | [workflow.md](../05-development/workflow.md) (parallel work); `Images/tools/.venv` |

**Choice.** Run the Python suite from a worktree with the worktree's
`Images/tools` first on `sys.path`, for example
`python3 -I -c "import sys; sys.path.insert(0, '<worktree>/Images/tools'); import pytest; raise SystemExit(pytest.main([...]))"`.
The maintainer decides whether each worktree gets its own venv, or whether the
venv symlink should not exist.

**Reason.** `Images/tools/.venv` is a symlink to the main checkout's venv, and
its editable install maps `apkrun_image` to
`/Users/N3275/Documents/projects/apkrun/Images/tools`. Run from the worktree root,
`Images/tools/.venv/bin/python3 -c "import apkrun_image"` prints the main
checkout's path. A plain `python -m pytest` in a worktree therefore imports the
main checkout's package while it collects the worktree's tests. The results of
#010's runs depend on the explicit insert.

**Consequence.** The #010 results were produced with the insert. Other
worktrees that use the same venv have the same risk until the maintainer decides.

## IR-404: Confirm androidboot.hypervisor.vm.supported=0 on a reference boot, or record it as a spike choice

| Field | Value |
| Status | Needs maintainer review |
| Task | #010, #013 |
| Affected documents | [android-image.md](../02-design/android-image.md) §6.2; `Images/tools/layouts/cuttlefish-phone-arm64.json` (`bootconfig.sources.decided`); `Images/reference/16373615/incomplete/default-20261001T120904-49816/kernel.log` (line 1154) |

**Choice.** The image layer keeps `androidboot.hypervisor.vm.supported=0`,
which the VZ spike booted with and which G2 depends on. Its §6.2 status is now
"decided", not "verified". The maintainer decides whether `0` stays, with the
reason recorded, or whether the key is removed to reproduce the reference's
absent state. Changing it needs a new VZ boot, so this task does not change it.

**Reason.** The launcher capture has no such key. Its `kernel.log` shows that
init's `setprop hypervisor.memory_reclaim.supported
${ro.boot.hypervisor.vm.supported}` fails because the property does not exist.
So the key changes what the guest does at that step: the setprop succeeds. The
VZ spike set `0` and booted, but it never ran without the key, so the record
does not show which state is right on VZ.

**Consequence.** Whichever value the maintainer keeps, the record in §6.2 and the
layout's decided note say why.

## IR-405: The reference record has no expected-differences entry for androidboot.serialno

| Field | Value |
| Status | Needs maintainer review |
| Task | #013 (record), #010 |
| Affected documents | `Images/reference/16373615/expected-differences.yaml`; [android-image.md](../02-design/android-image.md) §6.2; [IR-367](#ir-367-derive-the-reference-differences-from-the-launchers-bootconfig-and-command-line) |

**Choice.** This task does not add the entry. The maintainer decides whether
`androidboot.serialno` (instance layer, `APKRUN` plus the instance UUID, §6.2)
joins `expected-differences.yaml` now or when #013 next updates it.

**Reason.** The file is #013's evidence, and IR-367 states its entry count. Its
25 bootconfig entries are the record for the launcher's differences. The #010
test pins the eight omitted keys, and serialno is the only omitted key with no
entry in that file.

**Consequence.** The entry count in IR-367 changes if the entry is added.

## IR-406: The complete manifest example still shows the 157-byte command line

| Field | Value |
| Status | Needs maintainer review |
| Task | #065, #010 |
| Affected documents | [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.1 (complete example) and §6.2 (`SHA256SUMS` example); [android-image.md](../02-design/android-image.md) §4.1 |

**Choice.** #010 updates the command-line example in §3.3 to 172 bytes. The
complete example in §4.1 and the sample `SHA256SUMS` in §6.2 are not changed.
They still show `boot/cmdline.txt` at 157 bytes, and sizes that do not match the
pinned build (for example, a kernel of 43,581,440 bytes, where the pinned kernel
is 42,031,616). The maintainer decides whether to mark them as illustrative now
or to regenerate them from #065's first real bundle.

**Reason.** Those blocks are generated sample output, not measured values from
the pinned build. Regenerating them by hand would invent values, and #065 writes
the real manifest.

**Consequence.** Until then, a reader can take the sample sizes as measured.
## IR-420: The development agent's version record is apkrun-guest.json

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [build-system.md](../05-development/build-system.md) §7.1; [guest-components.md](../02-design/guest-components.md) §3.1 |

**Choice.** `scripts/build-guest.sh` writes `apkrun-guest.json` next to `apkrun-guest.apk`, with the package name, the versionCode, and the versionName. The host reads that record before it installs. The versionCode of `components.json` (`devGuestAgentVersionCode`) is not written, because `components.json` is the release component manifest, and #072 does not produce it.

**Reason.** The host has to know the bundled versionCode without parsing a binary manifest. A record written by the same script that builds the APK cannot disagree with it.

**Consequence.** `components.json` gains the agent's version when the release manifest is built (#058 or the release task).

## IR-421: A test-only key signs the development agent

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §2; [build-system.md](../05-development/build-system.md) §7.1 |

**Choice.** `Tests/Fixtures/signing/test-guest-dev.jks` is a JKS keystore with the alias `apkrun-test-guest-dev`. Its certificate's SHA-256 is pinned in `scripts/build-guest.sh`, and the script fails unless the APK is signed by that certificate. The keystore password is the test password in `Guest/guestd/build.gradle.kts` and in the script's comment. The key is not a production key.

**Reason.** The design names the key and requires that no other signer reach a device. Pinning the digest makes a changed key fail the build, not a device install.

**Consequence.** Anyone who changes the test key must update the digest in the script, and the APK changes with it.

## IR-422: Device setup uses the framework's shell entry points

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §3.4; [R-18](risks.md) |

**Choice.** The agent applies stay awake and no keyguard by calling each service's shell entry point, `IBinder.shellCommand`, with the same arguments that `cmd settings put global stay_on_while_plugged_in 7`, `cmd settings put system screen_off_timeout 2147483647`, and `cmd lock_settings set-disabled true` take. The agent starts no process. The keyguard is stored under `lockscreen.disabled`.

**Reason.** On build 16373615 the settings provider refuses a write whose package is not the caller's uid, and `ILockSettings.setBoolean` needs `ACCESS_KEYGUARD_SECURE_STORAGE`, which the shell uid does not hold. The design's "one service call" is the same class of call that `cmd` makes, so the shell entry point is the least-privileged path that the image allows.

**Consequence.** The step depends on the framework's shell command set, which can change between releases. A failed step is logged with the framework's cause, and the other steps still run.

## IR-423: The agent is installed on every start, so a rebuild with the same versionCode takes effect

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §3.1 |

**Choice.** The provisioner runs `install -r -t` on every start, whatever the installed versionCode. It does not skip an install whose versionCode matches the bundle, so the skip in §3.1 step 1 is not used.

**Reason.** A development rebuild keeps its versionCode, and a skipped install would leave the old agent on the device. A skip would also hide a signer change at the same versionCode, which Android's refusal reports (IR-425). The install takes a few seconds, and the start waits for the device anyway (IR-435).

**Consequence.** A boot is longer by the install time. A developer does not need to uninstall the agent to pick up a rebuild. The T2 suite still uses two versionCodes, to test the replacement in both directions.

## IR-424: The provisioner replaces a newer agent by removing it first

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §3.1 |

**Choice.** When the installed versionCode is higher than the bundled one, the provisioner uninstalls the installed agent before it installs the bundled one. `install -r` cannot downgrade, and Android refuses it with `INSTALL_FAILED_VERSION_DOWNGRADE`. The uninstall is safe because the development agent keeps no user data.

**Reason.** "An installed agent with another version … is replaced by the bundled one" (#072 acceptance) covers a downgrade. The alternative, `install -r -d`, needs a debuggable image, which the custom path does not have.

**Consequence.** The downgrade removes the agent for a moment. The agent is restarted by the same start.

## IR-425: A signer mismatch is detected by Android's refusal

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §3.1 |

**Choice.** The provisioner does not compare signers with `dumpsys package`. It installs the bundled APK on every start (IR-423). When Android refuses with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, it uninstalls the installed copy and installs again. A refusal that the second install does not clear is `installFailed`, with Android's reason.

**Reason.** Android's own check is the authority on whether an update can replace a package. A host-side comparison could disagree with it, for example for a rotated signing lineage. An install that is skipped for a matching versionCode would never reach that check, which is why the install runs on every start.

**Consequence.** The signer path is covered by T0 with a fake adb. The test checks that the uninstall comes between the refused install and the retry, and that an unrecovered refusal is reported with Android's reason. It has not been run on the device, because the mismatch needs a second signing key on the device.

## IR-426: The agent is stopped by its PID, not by pkill

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §3.3 |

**Choice.** The host finds the agent with `pidof apkrun_guestd` and sends `kill` to that PID. The design's `pkill -f apkrun_guestd` is not used.

**Reason.** On build 16373615 `pkill -x apkrun_guestd` did not stop the daemon, although `pidof` finds it. `pkill -f` would match the device shell's own command line, which contains the pattern, and so could stop the shell that runs it.

**Consequence.** A second agent process cannot be stopped by name. The host only ever stops the one that `pidof` reports.

## IR-427: The service check runs through app_process, not am instrument

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §12, §14 |

**Choice.** The "SystemServicesTest" check runs `io.apkrun.guest.daemon.ServiceCheck` through `app_process`, the same process type as the daemon, and the T2 suite reads its output. The design's `am instrument` run is not used.

**Reason.** `am instrument` runs the test in an app process, where hidden-API restrictions apply to the app's own calls. The check would then test a different path from the one the daemon takes. `app_process` is the daemon's path.

**Consequence.** The check needs no instrumentation APK. Its output lists the five wrappers, with their missing methods.

## IR-428: The launch starts the activity as the shell package, through PackageManager

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §6.4; [R-18](risks.md) |

**Choice.** The launcher component comes from `PackageManager.getLaunchIntentForPackage` on the system context. The start is `IActivityTaskManager.startActivityAsUser` with the calling package `com.android.shell` and the display in `ActivityOptions`. The start through the system context is not used.

**Reason.** The context start was refused on build 16373615: `Permission Denial: package=android does not belong to uid=2000`. A package-only intent was refused as not resolved for the shell's visibility, while the explicit component resolves.

**Consequence.** The start depends on the 12-parameter signature of `startActivityAsUser`, which is recorded in R-18 for the image.

## IR-429: The start result codes are read from the framework at run time

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [R-18](risks.md) |

**Choice.** `START_SUCCESS`, `START_INTENT_NOT_RESOLVED`, `START_CLASS_NOT_FOUND`, and `START_PERMISSION_DENIED` are read from `android.app.ActivityManager` on each call, not written into the agent. The image's values are `START_INTENT_NOT_RESOLVED = -91`, `START_CLASS_NOT_FOUND = -92`, and `START_PERMISSION_DENIED = -94`.

**Reason.** Android renumbers these between releases. The first device run used the values of an older release and reported a different failure than the one that occurred. Reading them keeps the mapping true on each image.

**Consequence.** A result code that the image does not define maps to `internal`, with the code in the detail.

## IR-430: The display and task callbacks are Binder listeners

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-components.md](../02-design/guest-components.md) §6.1; [R-18](risks.md) |

**Choice.** The listeners of `IDisplayManagerCallback` and `ITaskStackListener` are Binder objects. Each call on one triggers a refresh of the display or task list, which is compared with the last list. The agent does not use a Java proxy.

**Reason.** The framework reads the listener through `asBinder()`, and a proxy returned null, so the registration failed with "listener must not be null". The refresh-and-diff keeps the design's "listener and getTasks" model.

**Consequence.** Callback arguments are not read. The state is read again after each notification, which is correct for the events that the agent sends.

## IR-431: Two framework signatures differ from the design on build 16373615

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [R-18](risks.md); [guest-components.md](../02-design/guest-components.md) §6.2 |

**Choice.** The task list uses `IActivityTaskManager.getTasks(int, boolean, boolean, int)` when the 4-parameter form exists, and `getTasks(int)` otherwise. The keyguard switch is `setBoolean(String, boolean, int)` on `ILockSettings`, because `setLockScreenDisabled` is absent. Both variants are resolved by `MethodRequirement`, and the choice is in the wrapper's record.

**Reason.** The design's §6.2 requires variants for hidden signatures. Both signatures were read from the device with `ServiceCheck --methods`.

**Consequence.** A future image can change either signature. The wrapper then reports the method as missing, and only the capability fails.

## IR-432: The GuestOperation set is the five operations that #072 uses

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §4.1, §13.1 |

**Choice.** The typed `GuestOperation` structs are `GuestPing`, `GuestGetSnapshot`, `GuestSetDisplayPolicy`, `GuestLaunchApplication`, and `GuestFocusDisplay`. A test checks that each one's number and name match the `Request` and `Response` fields of `envelope.proto`. The other operations get their structs with their tasks.

**Reason.** The design asks for the pairing "of every operation" (step 5). Writing structs for operations that no code calls would add untested surface. The schema-level pairing of all operations is already tested by #033.

**Consequence.** A task that adds an operation must add its struct and its pairing check.

## IR-433: The input stream validates and acknowledges, and does not inject

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §9; [guest-components.md](../02-design/guest-components.md) §11 |

**Choice.** The agent decodes the input batches, drops the events that fail validation (coordinates outside the display, non-finite values, unknown kinds, pointers outside 0–9, key codes outside 1–65535), counts them, and answers `InputAck` when asked. It does not inject an event, and `events_injected` stays 0.

**Reason.** The design puts injection in #024 and #025. Validation belongs with the stream, so the stream's contract is complete before the injector exists.

**Consequence.** The T0 tests of the validation are the only coverage of the input path in #072.

## IR-434: Capabilities are advertised whole, and unimplemented operations answer UNSUPPORTED

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §5.3, §5.2 |

**Choice.** The agent advertises `core.v1`, `display.v1`, `launch.v1`, and `input.v1`. Operations of these capabilities that #072 does not implement, such as `ClearDisplay`, `StopApplication`, and `ListTasks`, answer `UNSUPPORTED` with "this agent build has no such operation".

**Reason.** The §5.3 table lists the capabilities by task, and `display.v1` spans #072 and #028. Advertising only the operations that exist would split the capability across releases, which the design does not allow.

**Consequence.** A host that enables `display.v1` must still handle `UNSUPPORTED` for `ClearDisplay` until #028. The dispatcher and the connection both do.

## IR-435: The agent start waits for the device, and the connect deadline follows the install and the start

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §12.2, §13.2, §15 (#072); [guest-components.md](../02-design/guest-components.md) §3 |

**Choice.** The agent start runs in this order. It waits up to 30 s until `adb get-state` reports `device`. It removes the stale `localabstract:apkrun-` forwards, best effort. It installs the bundle (IR-423), starts the agent, and then waits up to 5 s for the Hello and the HelloAck. The 5 s covers the transport's open as well as the Hello and the HelloAck. A refused version or Hello ends the wait at once as `handshakeFailed`, and a loopback connection that the device refuses fails at once. A start whose process is not running when its connection fails is `startFailed`. A `stop()` during the start ends it as `stopped`, and a connection that completes after a stop is closed. Each stage logs its name when it fails. A forward is removed when its stream closes. After the connection, five protocol violations within 10 minutes stop the reconnection, and the agent is `requiredAgentUnavailable` (guest-protocol.md §12.2).

**Reason.** The design's "within 5 s of sys.boot_completed" cannot include an install on the first boot, which takes several seconds by itself, so the deadline starts with the connection. On the first run after boot, adb reported the device offline for several seconds, and the forward listing then failed the start, so the device is awaited first. A forward that cannot be listed should not stop the agent from starting, and each new forward gets its own port. A start that could hang in the transport, or that kept a connection after a stop, is not acceptable for the boot that waits on it.

**Consequence.** A first boot can take longer than 5 s from `sys.boot_completed` to the connection. A steady-state boot does not. A stale forward can remain until the next start, without blocking it. The new `runtime.guestAgentStopped` code is in the catalog. The T2 suite measures neither interval separately.

## IR-436: The development boot fails when no agent bundle is found

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [cli.md](../02-design/cli.md) §5; [guest-components.md](../02-design/guest-components.md) §3 |

**Choice.** `apkrun dev boot` and `apkrun dev launch` load the agent bundle from `--guest-dir`, then from `APKRUN_GUEST_DIR`, then from `Resources/guest` of the app bundle that holds the executable. A missing bundle fails the boot with `runtime.guestAgentBundleMissing`. The boot does not continue without the agent.

**Reason.** The entry says `apkrun dev boot` installs and starts the agent, and input (#024) needs it. A boot that silently lacks the agent would look successful and fail later.

**Consequence.** The embedded tests that do not need the agent pass no bundle, and they boot as before.

## IR-437: An answer that arrives after its deadline is discarded

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [guest-protocol.md](../02-design/guest-protocol.md) §6, §12.2 |

**Choice.** A request with no answer by its deadline fails with `timeout(operation:)`, and its id is kept. An answer that arrives later with that id is discarded, and the connection stays open. An answer whose id the host never sent is still a protocol violation.

**Reason.** §12.2 makes a response whose `reply_to` matches no outstanding request a violation. A late answer after a timeout is that case, but §6 says a timeout "produces a failure. The connection stays open". Closing the connection on a late answer would turn one slow operation into a reconnect and a resync.

**Consequence.** The kept ids are released when their answers arrive. An agent that never answers keeps one id per timed-out request, and the host sends only a bounded number of requests.

## IR-438: The T2 suite cannot drive adb from the Xcode test host on this machine

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [test-strategy.md](test-strategy.md) §6.4; [M03](issues/M03-input-and-basic-runtime.md) #072 |

**Choice.** `GuestAgentTests` is committed and compiles. It has not passed in the Xcode test host. The run of 2026-10-10 (after the user allowed APKRunTestHost access to Documents) ended without a passing test, and the test case did not complete. Only `testAFourthDeathWithinAMinuteIsRequiredAgentUnavailable` reached a verdict, and it was an allowance failure. The inputs are in /tmp, rebuilt on 2026-10-10 from the same sources. The suite is not counted as a T2 pass.

**Evidence.**
- The adb binary that the test host runs is `/Users/N3275/Documents/projects/apkrun-wt/072/build/android-sdk/platform-tools/adb`, which `APKRUN_ANDROID_HOME` names. That path is a symlink into `~/Documents`. An orphaned `adb devices` started by the test host (pid 82572, 05:19) was sampled. It was stuck in `open()` inside dyld while it loaded that binary. A shell with Documents access runs the same binary without a delay.
- With the adb binary copied to `/tmp/apkrun-072-sdk` and set as `ANDROID_HOME` in the AndroidGuestAgent configuration (run at 07:19, not committed), the host reached the device: `ADB connected to 127.0.0.1:6520`, then `Connected to guest vsock port 5555`, then `Android boot entered bootCompleted`, and the agent connected.
- With the original path after the Documents access was allowed (run at 08:15, the file is the committed plan), the host did not reach the device. The log has no `ADB connected` line and no `Connected to guest vsock port 5555` line. The device wait failed after 30 s with `The Guest Agent failed at the device wait err=runtime.adbConnectionUnavailable`, and then `Android boot failed err=runtime.guestAgent`. The first failing error is the boot failure, and it came from the device wait. An XCTest assertion never printed, because the test case did not complete.
- After a boot failure, the teardown stops the loopback forwarder (`Stopped the loopback forwarder on port 6520`), then the test case waits silently until the 10-minute allowance expires (`exceeded execution time allowance of 10 minutes`). Three runs show this (07:08, 07:22, 08:16). The stop path is `VsockLoopbackForwarder.stop`, reached from `RuntimeCore.Supervisor.closeDevelopmentChannels`, and the sample shows a priority-inversion warning on that thread. The eight tests would each spend the allowance, about 80 minutes in total.
- In the `/tmp` run, the first kill of the agent was followed by `The Guest Agent did not restart err=runtime.guestAgentStartFailed` after about 70 ms, and the budget then stopped the agent. That log predates the fix that records the real code (5157c6b). The cause is not isolated.

**Reason.** The Documents-path adb did not reach the device in the run with the access allowed, while the `/tmp` copy of the same adb build did. The evidence shows that the binary's location is the variable, and it does not show that the privacy prompt is the cause. Whether the grant covers the adb binary that the test host executes is not established. The teardown hang is a separate fault in the VM forwarder stop path, which the CLI does not hit.

**Consequence.** The T2 acceptance boxes that need the test host stay open, and the M03 T2 gate cannot close until the test host runs adb and the forwarder stop returns. Next steps: check whether the adb binary is readable by the test host from Documents (for example by running it from the test host with the grant), or run the suite with adb in a path outside Documents. Fix the forwarder stop so that a failed boot returns promptly, and check the restart failure with the logged code.

**Update (2026-10-10, current T2 state).**
- **adb location.** The test host runs adb from `~/Documents` (through the worktree `build/android-sdk` symlink), and that copy did not connect. A copy of the same platform-tools (adb 1.0.41) under `/tmp/apkrun-072-sdk/platform-tools`, passed as `APKRUN_ANDROID_HOME`, connected in the 07:18 run. The committed test plan is unchanged. The decision was requested under IR-388, which is not in the review log. The outside-Documents rule is recorded in IR-046 and IR-061. No record of a #021 run that used a copied SDK was found, so this entry does not cite one.
- **Result with the `/tmp` copy (07:18 run).** The boot reached `bootCompleted`, the host connected, and the agent connected. The first kill's restart failed with `The Guest Agent did not restart err=runtime.guestAgentStartFailed`. That run predates the fix that logs the real code (5157c6b), so the cause is not known. The test then exceeded its allowance after teardown. No GuestAgentTests test has passed.
- **Fake-adb run (08:37, a script that exits 1 for every command).** Not evidence for the real path. `testAFourthDeathWithinAMinuteIsRequiredAgentUnavailable` failed at 45.7 s with the boot error and did not hang.
- **Remaining blocker.** After `Stopped the loopback forwarder on port 6520`, the runs with the real adb went silent until the 10-minute allowance expired. The fake-adb run did not reproduce the silence, and no sample of the stalled test host was taken. The teardown fix and its T0 test are not done.
- **Single next step.** Run `testAFourthDeathWithinAMinuteIsRequiredAgentUnavailable` once with the `/tmp` copy, and `sample` the test host while it is silent after the forwarder stop, to name the blocked wait.

**Update (after the rebase onto main 3a0cc60).**
- **T2 run deferred.** The T2 run of `GuestAgentTests` is deferred until the G2 gate ends and releases the VM lock. No VM test ran after the rebase.
- **adb location.** The T2 run uses the approach of [IR-388](#ir-388) on main: `platform-tools` copied to `/tmp/apkrun-072-sdk` and passed as `APKRUN_ANDROID_HOME`. The committed test plan is unchanged.
- **Teardown after a failed boot (8a5f703).** `VsockLoopbackForwarder.stopAndWait(timeout:)` waits for the listener on a dispatch thread, bounded by the timeout, and `RuntimeSupervisor` awaits it. The synchronous `stop()` keeps its contract. The T0 test `loopbackForwarderStopReturnsWhileAGuestConnectionNeverOpens` stops a forwarder whose guest connect never returns, and checks that the stop returns within its bound, closes the client, and frees the port. It passes on the host.
- **Not proven.** The fake-adb run did not reproduce the silence, and no sample of the stalled test host was taken. Main's `AdbProcess` change (3a0cc60) also moves the pipe readers off the concurrency pool, which is the same starvation mechanism. The device run must show whether the silence is gone.
- **Next step, when the lock is free.** Run `testAFourthDeathWithinAMinuteIsRequiredAgentUnavailable` once with `APKRUN_ANDROID_HOME=/tmp/apkrun-072-sdk`. If the test host still goes silent after `Stopped the loopback forwarder`, `sample` it during the silence to name the blocked wait.

## IR-439: The test inputs are read from /tmp, and the entry's path is stale

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #072 |
| Affected documents | [M03](issues/M03-input-and-basic-runtime.md) #072, Conventions; [test-strategy.md](test-strategy.md) §4 |

**Choice.** The T2 suite reads the agent bundles and the HelloText fixture from `/tmp` paths that the test plan names (`APKRUN_GUEST_DIR`, `APKRUN_GUEST_OTHER_DIR`, `APKRUN_FIXTURE_APK`). The Android bundle is `/tmp/apkrun-test-linux/android-bundle`, as `AndroidBootSession` already uses, not `Images/work/16373615`, which the entry's conventions name.

**Reason.** macOS privacy protection stops the test host from reading the repository's `Documents` folder, while a terminal can read it. The existing helper already reads `/tmp`. The entry's path predates that helper.

**Consequence.** The suite needs a shell step before the run, which the entry's notes describe.

## IR-460: A renderer failure is counted and logged, and the guest still sees success

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2, §4.5, §8, §16 |

**Choice.** A 3D or 2D command gets its response when the device validates it on the device queue. If the renderer then fails, the failure is logged and counted in `GraphicsCounters.rendererFailures`, and the guest still gets success. The device does not write an error response later.

**Reason.** The response bytes must be written into the guest's element before `deferCompletion()`. VirtioDeviceCore's `PendingElement` only completes; it cannot carry bytes that are written after deferral. Adding that to the VZ adapter is outside this task and cannot be checked without a VM. The device can still reject everything the guest can cause: unknown or live IDs, out-of-range boxes, limits, and invalid sizes. A renderer failure is a host fault. The one command whose result the guest needs at once, `TRANSFER_FROM_HOST_3D`, runs synchronously and does return its error (IR-464).

**Consequence.** Section 4.2 says a GL error returns `ERR_UNSPEC`. That holds only for readbacks in this build. The follow-up is a response-carrying completion in VirtioDeviceCore. Until it exists, a renderer failure shows in the counters and the log, not in the guest.

## IR-461: A fence above 32 bits is refused, and every 32-bit fence is valid

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2, §4.5, §5.2 |

**Choice.** A fenced request whose fence ID does not fit in 32 bits gets `ERR_INVALID_PARAMETER` before any command runs, and no renderer call is made. Every 32-bit value is a valid fence. The bridge passes the bit pattern of the fence to `virgl_renderer_create_fence`.

**Reason.** The virglrenderer context-0 fence takes an `int` and reports a `uint32_t` to `write_fence` (`virglrenderer.c`, `virgl_renderer_create_fence` and `ctx0_fence_retire`). The header carries 64 bits, so a wider value would be truncated and could complete the wrong fence. An earlier bridge check refused every value above 2^31 - 1, which left the upper half of the range without a fence. It was fixed in review, and a T1 test now retires a fence of `0x80000001`.

**Consequence.** A guest that numbers fences past 2^32 gets errors. Linux's counter does not reach that in practice.

## IR-462: The planner still refuses drmVirgl until its boot is verified

| Field | Value |
|---|---|
| Status | Needs maintainer review; superseded by IR-580 |
| Task | #022 (step 4) |
| Affected documents | [graphics.md](../02-design/graphics.md) §9; [IR-380](#ir-380-refuse-a-gpu-profile-that-the-device-does-not-offer), [IR-382](#ir-382-offer-only-the-gpu-profiles-of-this-build-in-apkrun-dev-boot---gpu) |

**Choice.** `AndroidGraphicsDevices.devices(for:)` still builds the EDID-only device for `drmVirgl`, so the profile is refused with `runtime.gpuProfileUnavailable`. `VirtioGPUDevice.virgl()` exists and offers VIRGL with two capsets, but RuntimeCore does not construct it, and `apkrun dev boot --gpu virgl` stays refused.

**Reason.** Removing the refusal starts a VM with the VirGL features. The `drmVirgl` boot has not run, and the task forbids a VM run here. IR-380 expected the check to pass by itself once the device offered VIRGL. That does not hold for the planner, which builds its own device, so the switch and the removal of the refusal must happen together, after a verified boot.

**Consequence.** The `drmVirgl` acceptance criteria of #022 stay unmet (M02 #022). The follow-up is a one-line switch in `AndroidGraphicsDevices`, plus the removal of the refusal of IR-380 and IR-382, in the same commit as the verified boot.

**Superseded by IR-580.** The switch and the removal of the refusal happened in code before the verified boot, as IR-580 records. The verified boot still gates the `drmVirgl` criteria of #022, but not the code path. The reasoning above, that the removal must follow the boot, is the part that IR-580 replaces.

## IR-463: Every VirGL context shares the root context's objects

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (steps 1 and 3) |
| Affected documents | [graphics.md](../02-design/graphics.md) §5.1, §5.2 |

**Choice.** `gb_create_gl_context` shares every context with the root EGL context. The `shared` flag that virglrenderer passes is not honoured.

**Reason.** The T1 round trip uploaded a texture through context 0 and read zeros back. The same transfer through a guest context read the bytes correctly, and the T1 test `virglRoundTripsATextureUploadAndRetiresAFence` now shows the fix. virglrenderer creates context 0 with `shared` unset, so its GL objects were in a separate namespace from the texture the root context made.

**Consequence.** All contexts share one object namespace. A resource is visible to every context, as the virgl model expects.

## IR-464: TRANSFER_FROM_HOST_3D runs on the device queue and waits for the render thread

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.7, §7 (`guestReadbacks`) |

**Choice.** The device queue asks the render thread to read the box, waits for the answer, writes the box into the guest backing, and only then answers the guest. Every other 3D command goes to the render thread asynchronously.

**Reason.** `GuestMemory` is confined to the device queue. Off that queue, VirtioDeviceCore's `validate()` fails with `guestMemoryInvalidated`, so a render-thread completion cannot write the guest's memory. The rule of §4.7 that the device queue never calls virglrenderer is therefore broken for this one command. Readbacks are rare: `glReadPixels` and query results. The render thread never waits on the device queue, so the wait cannot deadlock.

**Consequence.** A readback blocks the device queue for the length of the GL read. A guest that reads back often will see latency, which #023 measures.

## IR-465: Backing is gathered by copies, not handed to the renderer

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2, §4.4, §7 (`guestUploadBytes`) |

**Choice.** `RESOURCE_ATTACH_BACKING` maps and validates each entry and keeps the views on the device queue. It does not call `virgl_renderer_resource_attach_iov`. A `TRANSFER_TO_HOST` gathers the box's guest bytes into a host buffer, and the renderer reads that buffer.

**Reason.** `GuestMemory` exposes only copy calls, not a pointer, and a pointer into guest memory would outlive a reset or stop, which VirtioDeviceCore invalidates. virglrenderer's transfer calls take their buffer as an argument (`virgl_renderer_transfer_write_iov`), so the attached iovec is not needed for transfers.

**Consequence.** An upload costs one copy of its box, counted in `guestUploadBytes`. The scanout path has no upload, so the frame-path rule of AGENTS.md §6.4 is unaffected. A zero-copy path needs a pointer API in VirtioDeviceCore, which is a follow-up.

## IR-466: The waiting elements are one ordered queue on the render thread

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.7 |

**Choice.** The elements that wait for execution or a fence sit in one ordered queue, `ControlCompletionQueue`, which the render thread completes. Each completion calls `PendingElementCompletionToken.complete()`, and VirtioDeviceCore returns the element on the device queue. No separate single-producer ring or `DispatchQueue.async` is built.

**Reason.** The token is already `Sendable`, and VirtioDeviceCore already moves a completion from another thread to the device queue (`VZPendingElementStorage.complete` leads to `completePendingAsync`). A ring would repeat that hop. The queue takes one lock per operation, and AGENTS.md §8 says not to optimize before measuring.

**Consequence.** The ring of §4.7 is not built. #070 should measure the lock before it is replaced.

## IR-467: The completion waiter is built in #023, not in #022

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.7, §6.2; [M02](issues/M02-graphics.md) #022, #023 |

**Choice.** No completion-waiter thread is created in #022. #023 creates it with the present blits.

**Reason.** The waiter waits on the EGL syncs of present blits, and #022 makes none, because the pools arrive in #023. An empty thread would add nothing and could not be measured.

**Consequence.** Step 1 of #022 is met without the waiter. The §4.7 row of the waiter stays with #023.

## IR-468: Sizes, layers, and the limits that the spec does not set

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.4, §5.4 |

**Choice.** (a) A buffer (target 0) takes its width as a byte count, and the 8192 limit applies to textures only. The 8192 check moved from the request decoder to `ResourceTable`, which knows the target. (b) The byte estimate is the level-0 size times depth, or times array layers for array and cube targets; mip levels are not added. (c) `lastLevel` is at most 13, and the sample count is at most 16. (d) A transfer's extent is at most 256 MiB, the single-resource limit. (e) A transfer with more than 4 Mi rows is refused with `ERR_INVALID_PARAMETER`.

**Reason.** Mesa creates buffers with the size in the width field, so a decoder-level 8192 check would refuse ordinary vertex buffers. The spec gives the estimate as `width × height × bpp`, and (b) follows it. Rules (c) to (e) are not in the spec. (c) is the largest mip count of an 8192-pixel texture. (d) and (e) bound the host memory and the device queue's time for one request, which the review found could otherwise reach gigabytes.

**Consequence.** The byte estimate undercounts a mip chain by up to a third, so the 2 GiB total is a lower bound. #070 should count mip levels with the memory metric.

## IR-469: The 3D formats are an allow-list with known sizes

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.4, §5.3 |

**Choice.** `ResourceTable` accepts the uncompressed formats of `virgl_hw.h` whose size per pixel is fixed, and the block-compressed DXT and RGTC/LATC formats with 4 × 4 blocks. Any other format, including the planar YUV formats, gets `ERR_INVALID_PARAMETER`.

**Reason.** The limits need a size for each format, so an unlisted format cannot be sized. The list is taken from the enumeration in `virgl_hw.h` (`virgl_formats`), and the renderer decides which of the listed formats it supports.

**Consequence.** A guest that uses a rejected format gets an error. Adding a format is one table entry.

## IR-470: The render thread is a condition-variable loop, not a run loop

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.5, §4.7 |

**Choice.** The render thread is a `Thread` that waits on an `NSCondition`. It waits with a 1 ms timeout while a fence is outstanding and without a timeout otherwise. It runs queued work in order, and it calls the poll handler at most once per millisecond, only while polling is requested.

**Reason.** §4.7 proposes a `DispatchSourceTimer` on the thread's run loop. A dispatch timer needs a dispatch queue, and a serial queue does not pin work to one thread. The condition wait gives the same cadence on one thread, with no run loop to manage.

**Consequence.** None observable. The T0 test `aPollRequestNeverRunsTheHandlerWithoutAPendingRequest` checks that the poll is idle when no fence waits.

## IR-471: Reset and stop return every waiting element, and forget the fence mark

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §8 (`WillReset`, `WillStop`) |

**Choice.** On reset and on stop, every waiting element is completed at once, and the highest completed fence is forgotten. Nothing is abandoned.

**Reason.** An abandoned `PendingElement` asserts in DEBUG builds, and VirtioDeviceCore drops the element of an old generation safely when it is completed. Forgetting the fence mark matters because the renderer restarts its fence numbers after a reset; without it, a new fence below the old mark would count as complete at once (found in review and fixed).

**Consequence.** The guest's responses from before a reset are returned without their fences having completed. The guest is resetting, so it discards them.

## IR-472: RESOURCE_CREATE_2D under drmVirgl is a renderer resource with the render-target bind

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2 (`RESOURCE_CREATE_2D`) |

**Choice.** Under `drmVirgl`, a 2D resource is created in the renderer with target 2, depth 1, one layer, and the render-target bind flag (`1 << 1`). Its transfers go through the renderer with context 0.

**Reason.** §4.2 says the VirGL profile uses `virgl_renderer_resource_create` with the 2D target. The bind flag is the one a 2D render target needs. Context 0 is the path that the 2D transfers use.

**Consequence.** Only the VM run can confirm the bind flag, which is one of the checks of step 2 and step 4.

## IR-473: A zero stride resolves as virglrenderer does, and a stride must hold a row

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2 (`TRANSFER_TO_HOST_3D`) |

**Choice.** A zero `stride` becomes the tight row size of the mip level, in blocks times bytes per block. A zero `layer_stride` becomes the stride times the block rows. A nonzero stride must hold one row, and a nonzero layer stride must hold one layer. The renderer receives the resolved values.

**Reason.** virglrenderer resolves a zero stride the same way (`vrend_renderer.c`, `util_format_get_nblocksx(...) * blsize`). Passing the resolved values makes the table's extent and the renderer's reads agree. A stride below a row would overlap the rows of a box, so it is refused.

**Consequence.** None for conforming guests.

## IR-474: The 2D profile keeps host shadows until the pools arrive in #023

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 5) |
| Affected documents | [graphics.md](../02-design/graphics.md) §9, §12 (#022 step 5) |

**Choice.** Each 2D resource of the `guestSwiftshader` path has a host shadow buffer. `TRANSFER_TO_HOST_2D` copies the rectangle into it and counts one CPU pixel copy and its bytes. The flush completes without a blit, because no pool exists before #023.

**Reason.** Step 5 needs the 2D commands to succeed so that the boot can reach `boot_completed`. The shadow is the path that #023 extends with the pool blit. The shadow's memory is at most the resource's estimate, which is inside the 2 GiB total.

**Consequence.** The shadow is not read until #023. The `guestSwiftshader` boot check of step 5 is not run here.

## IR-475: The test-only readback has a trait, and the replay test replays a recorded session

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3) |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#022 step 3), §14; [coding-conventions.md](../05-development/coding-conventions.md) (`DEBUG-READBACK`) |

**Choice.** The test-only readback is `readResourceForTest`, compiled only under `#if APKRUN_TEST_READBACK`, which the `TestReadback` trait sets (`swift test --traits TestReadback`). A recorder captures the renderer's state-changing calls as `VirGLRecording`, and a T1 test replays a recorded session on a fresh renderer and compares the bytes. The kmscube stream of step 3 is not recorded.

**Reason.** The kmscube stream needs the Linux guest, which the task forbids here. A recording of the renderer's own calls gives the same replay mechanism, and it runs on this Mac.

**Consequence.** The replay test of §14 is met by the session replay. The kmscube recording is a follow-up that needs the VM. The trait is a new entry in `Package.swift`.

## IR-476: The renderer tests run in one serialized suite

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3) |
| Affected documents | [test-strategy.md](../04-plan/test-strategy.md) §3 (T1) |

**Choice.** Every test that creates a virglrenderer instance is in one `@Suite(.serialized)`, `VirGLRendererSuite`.

**Reason.** virglrenderer admits one instance per process, and `gb_renderer_create` returns `GB_E_RENDERER_ALREADY_EXISTS` for a second. Top-level `.serialized` tests still ran in parallel with each other, and two of them collided.

**Consequence.** The T1 suite runs one test at a time, which takes about three seconds.

## IR-477: The HelloGL fixture is a module of the fixture project, and it is built apart from the script

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 6) |
| Affected documents | [test-strategy.md](../04-plan/test-strategy.md) §4.2; [build-system.md](../05-development/build-system.md) §8 |

**Choice.** HelloGL is a module of the fixture Gradle project in `Tests/Fixtures/AndroidApps/`, built with `./gradlew :HelloGL:assembleRelease`, and signed with the test fixture key. `scripts/build-fixtures.sh` still builds HelloText only.

**Reason.** The script is specific to HelloText, which it names in its output and in its signer check. The HelloGL release APK builds offline, and its signer matches the pinned fixture certificate. Extending the script and the committed copies belongs to the fixture pipeline (#016 and #029), not to this task.

**Consequence.** HelloGL's `renderer` and `fps` events are not checked here. The check needs a `drmVirgl` boot.

## IR-478: Context errors: zero and duplicate IDs, and the limit

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2, §5.4 |

**Choice.** `CTX_CREATE` with ID 0, or with a live ID, gets `ERR_INVALID_CONTEXT_ID`. The 257th live context gets `ERR_UNSPEC`, which is the §5.4 row. A command on an unknown context gets `ERR_INVALID_CONTEXT_ID`.

**Reason.** §4.2 defines `ERR_INVALID_CONTEXT_ID`, and §5.4 gives `ERR_UNSPEC` for the context limit. The spec does not say which error a zero or duplicate ID gets, and `ERR_INVALID_CONTEXT_ID` is the one that names it.

**Consequence.** None.

## IR-479: Capsets are read when the renderer starts, and GET_CAPSET accepts only the cached version

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 1) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2 (`GET_CAPSET_INFO`, `GET_CAPSET`), §5.2 (`gb_capset_fill`), §8 |

**Choice.** The renderer's two capsets are read on the render thread when the device is created. The device answers `GET_CAPSET_INFO` and `GET_CAPSET` from that cache, and `GET_CAPSET` accepts only the cached maximum version.

**Reason.** The device queue must not call virglrenderer (§4.7), and a renderer build's capsets do not change while it runs. A renderer that cannot offer its capsets fails at creation, before the VM starts (§8).

**Consequence.** A guest that asks for an older capset version gets `ERR_INVALID_PARAMETER`.

## IR-480: Mesa 26.1.8 is the pinned release, not the newest 26.2.4

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 1) |
| Affected documents | [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 1; [M02](issues/M02-graphics.md) #099 |

**Choice.** Pin the Mesa 26.1.8 release: tag `mesa-26.1.8`, commit `0fadfea4f394211946f308458f614839ef253ee8`. The newest release tag on the upstream repository is 26.2.4.

**Reason.** The AOSP android-17 snapshot is the 26.1 series (`VERSION` 26.1.0-devel, IR-440 on `task/099-mesa-virgl-guest-image`). A 26.1 point release keeps the Android platform code closest to that tree. The spec does not name a Mesa version.

**Consequence.** A move to 26.2 is a pin update under [build-system.md](../05-development/build-system.md) §6.8. It repeats the ELF checks and the symbol contract of IR-488.

## IR-481: The NDK is installed from its archive, not with sdkmanager, and outside the shared SDK

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 3) |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.5; [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 6 |

**Choice.** The NDK r28c (`ndk;28.2.13676358`) is in `~/Library/Android/sdk/ndk/28.2.13676358`. The archive `android-ndk-r28c-darwin.zip` (952,495,160 bytes) came from `https://dl.google.com/android/repository/`, the URL that `repository2-3.xml` lists. Its SHA-1 equals the value in that manifest (`fc20a6bf15a30fb3428c9b60a7308793a362dc6d`), and its SHA-256 (`0d4599e8…`) is in the lock. `scripts/guest/build-mesa-android.sh --ndk-archive FILE` checks the archive against the lock. Without that option, the build checks the NDK by the revision in `source.properties`. `build/android-sdk`, which the other checkouts share, has no `ndk` directory, and this task did not change it. `sdkmanager` was not run.

**Reason.** The task asked for a location outside the shared SDK. `sdkmanager` needs a JDK, and no JDK is installed on this Mac. Installing one would be an environment change that the task did not ask for. The archive is the file that `sdkmanager` downloads.

**Consequence.** The shared SDK already has the acceptance record of an earlier `sdkmanager` run: `build/android-sdk/licenses/android-sdk-license` holds the SHA-1 `24333f8a63b6825ea9c5514f83c2829b004d1fee`. This task wrote nothing there. The lock's copy of the licence text (SHA-1 `efa68a6b…`, from `repository2-3.xml`) is not the text that the record hashes, and the two were not compared further. The maintainer confirms that the record covers the NDK (IR-486). The download copy was damaged after it was complete, because a retry loop appended 857 bytes to it. The checked copy is its first 952,495,160 bytes, whose SHA-1 and SHA-256 match the manifest and the lock. `unzip -tq` reports no errors in that copy, and the 8,365 regular files of the installed NDK have the sizes that the archive lists.

## IR-482: The NDK r28c sysroot stops at API 35, and Mesa's platform SDK is 37

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (steps 2 and 3) |
| Affected documents | [android-image.md](../02-design/android-image.md) §11.1; [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 2 |

**Choice.** The libraries are compiled with `aarch64-linux-android35`, the highest API that r28c provides. Mesa's `platform-sdk-version` is 37, the platform of the guest image (Android 17).

**Reason.** The r28c sysroot has library directories for API 21 to 35 only. The guest runs Android 17 (API 37), which is newer than the compile API, so an API 35 binary runs on it. Mesa's platform code reads `platform-sdk-version` for its gates, so it gets the guest's value.

**Consequence.** The link would fail on any symbol that the API 35 sysroot lacks, and it did not. A symbol that needs API 36 or 37 at run time would not show up in the build, so the VM check covers it.

## IR-483: HPND and the Bison-generated parsers are not on the app list

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §4.1, §4.2, §4.5; [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 7 |

**Choice.** The lock records the Mesa licence expression as found: `MIT AND BSD-2-Clause AND BSD-3-Clause AND BSL-1.0 AND HPND AND (CC0-1.0 OR Apache-2.0) AND GPL-3.0-or-later WITH Bison-exception-2.2 AND Apache-2.0 WITH LLVM-exception` (IR-493). The app list is not changed. The image does not ship Mesa until the maintainer decides how to treat the two terms that the app list does not name.

**Reason.** The source scan covered the 859 files that the four shipped libraries compile. The scan found the terms as follows:

- HPND (the "sell this software" notice) in `src/loader/loader_dri_helper.c`;
- GPL-3.0-or-later with the Bison skeleton exception, in the three Bison-generated parsers `src/compiler/glsl/glsl_parser.cpp`, `src/compiler/glsl/glcpp/glcpp-parse.c`, and `src/mesa/program/program_parse.tab.c`;
- BSD-2-Clause in `pp_mlaa.c`, BSD-3-Clause in `softfloat.c`, BSL-1.0 in `c11/impl/time.c`, and CC0 or Apache-2.0 in the BLAKE3 files, which the lock treats as upstream-identified;
- public-domain dedications in `src/util/fast_idiv_by_const.c` and `src/util/rand_xor.c`, which the app list does not name;
- MIT for the rest.

The app list (§4.2) allows only the identifiers it names. §4.5 fails `A WITH E` unless the whole expression is on the list. HPND is not on the list, and neither is `GPL-3.0-or-later WITH Bison-exception-2.2`. The flex-generated lexers carry no GPL notice.

**Consequence.** The image release is blocked until the maintainer decides. The options are to add HPND and the Bison exception to the app list, or to replace the component. The BLAKE3 identification comes from the upstream project, because the Mesa tree has no licence file for it, and the maintainer confirms it.

## IR-484: Ninja and Bison are built from pinned source, and Bison's signature is checked against the GNU keyring

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [build-system.md](../05-development/build-system.md) §6.1, §6.5 |

**Choice.** Ninja 1.13.2 is built from the upstream tag `v1.13.2` (commit `3441b633c2fe2c494e958780ba0f4227b1327634`) with its bootstrap script. Bison 3.8.2 is built from `bison-3.8.2.tar.xz`, pinned by SHA-256 `9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2`, and its detached signature was checked against the GNU keyring (`gnu-keyring.gpg`, signer `7DF84374B1EE1F9764BBE25D0DDCAA3278D5264E`) when the pin was chosen. The build script checks the SHA-256 only. Meson, mako, MarkupSafe, and packaging are PyPI wheels, pinned by SHA-256.

**Reason.** The PyPI ninja wheel reports the version `1.13.2.git.kitware.jobserver-pipe-1`, so it is not the upstream build, and the upstream source is the pin. macOS ships Bison 2.3, and Mesa needs a newer one (`meson.build`, the `bison` version check). `gpg` reports that the signer is not certified by a trusted signature. The check therefore shows that the tarball matches the keyring, not that the keyring belongs to the maintainer.

**Consequence.** The maintainer confirms that the GNU keyring is trusted for this check.

## IR-485: flex and m4 come from macOS and are not pinned

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [build-system.md](../05-development/build-system.md) §6.5; [environment-setup.md](../05-development/environment-setup.md) §2.3 |

**Choice.** The build uses the macOS flex 2.6.4 and GNU m4 1.4.6. The manifest records both versions. The lock does not pin them.

**Reason.** Mesa needs flex for its GLSL lexers, and Bison runs m4 when it generates code. Both come with the macOS installation. Mesa's install notes (`docs/install.rst`) name flex 2.5.35 and bison 2.4.1, and they say that some versions, such as 2.6.2, can be buggy. The macOS flex is 2.6.4. Pinning either tool means a source build with more tools.

**Consequence.** The maintainer decides whether flex and m4 go into the lock or into `scripts/Brewfile`.

## IR-486: The NDK's licence is not an SPDX identifier, and the lock records its text

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §4.1, §4.4, §4.5; [build-system.md](../05-development/build-system.md) §6.1 |

**Choice.** The NDK entry has `license` `LicenseRef-Android-SDK-License` and `licenseFiles` `["android-sdk-license.txt"]`. The file is the text of `android-sdk-license` from the SDK manifest. The NDK's own `NOTICE` and `NOTICE.toolchain` are not copied.

**Reason.** The NDK is under the Android Software Development Kit License, which is not an SPDX identifier. §4.5 fails `LicenseRef-*` for tooling, so the entry fails the policy as written. The licence text is the licence that the package states. The NOTICE files are 504 KB and 781 KB, and the NDK is not distributed.

**Consequence.** The maintainer decides whether this licence may appear in the lock for build tooling, and whether the NOTICE files are required.

## IR-487: libz.so is a NEEDED entry that the receipt does not cover

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 4) |
| Affected documents | Receipt of build 16373615 on `task/099-mesa-virgl-guest-image` §5; [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Consequences |

**Choice.** Zlib stays enabled, so `libgallium_dri.so` has `DT_NEEDED libz.so`. The test lists it as expected, with the note that the image inventory has not confirmed it.

**Reason.** The receipt lists the libraries that the EGL emulation needs, and `libz.so` is not among them. The Mesa Android documentation (`docs/android.rst`) lists `libz` as a shared library of the Mesa Vulkan module, so AOSP's Mesa expects `libz` in the image. The alternative is `-Dzlib=disabled` together with `-Dshader-cache=disabled`, because Mesa's shader cache requires compression. That alternative drops the on-disk shader cache.

**Consequence.** If the image lacks `libz.so`, the maintainer chooses between an image change and the build change. The check stays open until then.

## IR-488: The stub libraries are link-time only, and the symbol contract is checked only in the VM

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 4) |
| Affected documents | [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 4 and Consequences; [android-image.md](../02-design/android-image.md) §8 |

**Choice.** The five stub libraries (`cutils`, `hardware`, `log`, `nativewindow`, `sync`) are not in the output. The shipped libraries import 37 symbols from those stubs and from libdrm. `scripts/guest/mesa_android.py` (`GUEST_SYMBOL_CONTRACT`) lists them. The guest must export them, and the VM check (`apkrun.test=egl`) is the first check that can show it.

**Reason.** `-Dandroid-stub=true` builds the stubs for non-Bionic targets. Shipping them would shadow the guest's libraries of the same names. The receipt (§5) lists the files `libcutils.so`, `libhardware.so`, `libdrm.so` (vendor), and `liblog.so`, `libnativewindow.so`, `libsync.so` (system) by name only, so the symbols are not established.

**Consequence.** A symbol that the guest lacks shows as a load failure of `libEGL_mesa.so`, which is an open check until the VM run.

## IR-489: The image placement of the libraries is not decided by this task

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 3) |
| Affected documents | [android-image.md](../02-design/android-image.md) §11.1; [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 9 |

**Choice.** The build output mirrors Meson's install with prefix `/vendor` and libdir `lib64`, so all four libraries are under `vendor/lib64/`. The image integration step moves `libEGL_mesa.so` and `libGLESv2_mesa.so` (and `libGLESv1_CM_mesa.so`) into `vendor/lib64/egl/`, and places `libgallium_dri.so` where the vendor linker finds it. This task does not move them.

**Reason.** Meson installs the EGL library to libdir. The `egl/` subdirectory is the Android loader's location for `ro.hardware.egl` drivers, as in the Mesa documentation's `file_contexts` (docs/android.rst). Linker search in the vendor namespace is not checked without a VM.

**Consequence.** The image integration task places the files and checks the `DT_NEEDED` resolution in the guest.

## IR-490: The aosp-mesa3d candidate of the feasibility branch is not carried into this branch

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | `ThirdParty/ThirdParty.lock.json`; IR-441 and IR-444 on `task/099-mesa-virgl-guest-image` |

**Choice.** The `aosp-mesa3d` entry exists only on `task/099-mesa-virgl-guest-image`, not on `main`, and this branch does not add it. The lock adds `mesa`, the upstream release that the build compiles, in its place. The candidate's `LICENSE` is not copied.

**Reason.** The task asked for the candidate to be replaced. The feasibility record shows that the AOSP tree does not provide the libraries (IR-440 on that branch), and that its licence classification conflicts with the image rules (IR-444 on that branch).

**Consequence.** The feasibility branch is not merged. Its IR-440 to IR-451 stay on that branch.

## IR-491: The libdrm tarball has no licence file, so the lock copies the MIT notice of `xf86drm.c`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [build-system.md](../05-development/build-system.md) §6.1 (`licenseFiles`); [legal-and-licensing.md](../05-development/legal-and-licensing.md) §6.1 |

**Choice.** The `libdrm` lock entry has `license` `MIT`, which `libdrm`'s `meson.build` declares, and `licenseFiles` `["MIT-notice-xf86drm.txt"]`. The file is lines 9 to 31 of `xf86drm.c` in the 2.4.123 tarball, which carry the copyright lines and the MIT permission notice.

**Reason.** The lock needs a licence file under `ThirdParty/licenses/`. The 2.4.123 tarball has no `COPYING` or `LICENSE` file at its top level, and its README does not state a licence. The excerpt is the MIT notice of `xf86drm.c`, and `meson.build` declares `license : 'MIT'`. That permission text is also in 234 other files of the tarball.

**Consequence.** The licence file is an excerpt, not a full copy of the upstream licence. libdrm is `ships: tooling`, so it is not in the image, and the excerpt does not affect the image. A maintainer who wants the upstream file copies it from the libdrm repository at the same commit.

## IR-492: The lock group `guest-mesa` names the guest build's pins, and the build-third-party driver does not build it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [build-system.md](../05-development/build-system.md) §6.1 (`group`), §6.3; [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 6 |

**Choice.** The nine new entries (`mesa`, `libdrm`, `ninja`, `bison`, `meson`, `mako`, `markupsafe`, `packaging`, `ndk`) are in the group `guest-mesa`. `scripts/build-third-party.sh` does not build this group. `scripts/guest/build-mesa-android.sh` reads the `mesa` entry's `buildFlags` and the URL, commit, and SHA-256 of each tool from the lock.

**Reason.** The group `virgl-runtime` builds the renderer with a driver of its own (`scripts/tools/build_third_party.py`), and the guest Mesa uses a different tool chain (the NDK and a cross file). A separate group keeps the renderer's lock hash (§6.1) unchanged by these entries. The `pyyaml` entry is reused from `virgl-runtime`, because it is the same pinned PyYAML.

**Consequence.** A change to a `guest-mesa` entry does not change the `virgl-runtime` cache key. The maintainer decides whether the guest build should become a build group of §6.1 when the image is released.

## IR-493: The NDK's static C++ runtime is linked into the shipped library, and its licence term is in the Mesa entry

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §4.2, §7.1; [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decisions 5 and 7 |

**Choice.** The C++ objects are linked with `-static-libstdc++`. The NDK's libc++abi and libunwind code is therefore inside `libgallium_dri.so`: the unstripped build defines 21 `__cxa_` and `_Unwind_` symbols (18 in the text section, 3 in data), and it has no `std::__1` symbol. The Mesa entry's `license` adds `Apache-2.0 WITH LLVM-exception`. `ThirdParty/licenses/mesa/ndk-llvm-exception.txt` is the exception text, copied verbatim from `NOTICE.toolchain` of NDK r28c (lines 2040 to 2052).

**Reason.** The guest has `libc++.so` and no `libc++_shared.so` (the receipt, §5). A dynamic link to `libc++_shared.so` would need a library the image does not have, and a link to the system `libc++.so` would depend on an ABI the build does not check. The Mesa Android documentation uses the static runtime too. The term is on the app list, and the static code is what its notice covers.

**Consequence.** The exception text is an excerpt that the NDK's notice contains, not the notice itself. The NDK's full notice files stay out of the lock (IR-486). The image also has to carry the Apache-2.0 text, which the Mesa licence folder already holds. The app-list failures of IR-483 are unchanged.

## IR-494: The shipped libraries are stripped, and the unstripped build stays in the work area

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 3) |
| Affected documents | [0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) Decision 3; [build-system.md](../05-development/build-system.md) §6.3 |

**Choice.** `scripts/guest/build-mesa-android.sh` installs the shipped libraries with `meson install --strip`, which runs the NDK's `llvm-strip`. The debug sections are removed, and the dynamic symbol table stays, so the export and `DT_NEEDED` checks still apply. The unstripped libraries stay in `build-mesa` under the work area.

**Reason.** A release image should not carry debug sections that the guest does not use. The stripped `libgallium_dri.so` is 18.2 MB, and the unstripped one is 22.7 MB. The work area keeps the symbols for a crash analysis.

**Consequence.** A crash trace from the guest shows dynamic symbols only, unless the maintainer keeps a symbol package for each Mesa build. The choice is for the maintainer to confirm, together with the symbol policy of the image release.

## IR-495: The default output is a symlink into the main checkout in this worktree

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 3) |
| Affected documents | [build-system.md](../05-development/build-system.md) §6.6 (caches) |

**Choice.** The script writes to `ThirdParty/out/mesa-android` by default, and the work area to `ThirdParty/out/mesa-android-work`. Both are git-ignored. This task ran them with `--out` and `--work` set to a scratch directory outside the repository, because `ThirdParty/out` and `build` are symlinks into the main checkout in this worktree. Writing there would change the main checkout, which the task forbids.

**Reason.** The default follows the design (§6.6 keeps the output under `ThirdParty/out/`). The worktree layout is an environment fact, not a design choice.

**Consequence.** The build output of this task is outside the repository. A maintainer rebuilds it in the main checkout (or the release machine) with `scripts/guest/build-mesa-android.sh`, and then runs the output check of IR-496.

## IR-496: The output checks run on a built output, not in the default test run

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 4) |
| Affected documents | [test-strategy.md](../04-plan/test-strategy.md) (T0 and T1); [build-system.md](../05-development/build-system.md) §3 |

**Choice.** `scripts/tests/run.sh` runs the T0 part of `scripts/tests/test_guest_mesa_build.py`: the lock pins, the ELF parsers, and the verifier, run against fake ELF tools. The output part runs only with `--out DIR`, and it needs the NDK's `llvm-readelf` and `llvm-nm`.

**Reason.** The default test run has no NDK and no build output, and it must stay fast and runnable on any checkout. A Mesa build takes about ten minutes on this Mac. The output check is therefore run by hand after a build, and the result is recorded in the M02 #099 entry.

**Consequence.** CI does not check the built output. The maintainer adds that check to a release job, which needs the NDK on the runner.

## IR-497: The Mesa build script lives under `scripts/guest/`, not under `Images/tools/` or `ThirdParty/build/`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2) |
| Affected documents | [M02](issues/M02-graphics.md) #099 (`Modules / paths`, `Deliverables`); [build-system.md](../05-development/build-system.md) §6.8 (step 4); [android-image.md](../02-design/android-image.md) §1.2 |

**Choice.** `scripts/guest/build-mesa-android.sh` and its helper `scripts/guest/mesa_android.py` are under `scripts/guest/`, as the task asked. The M02 entry named `Images/tools/`, and build-system §6.8 says that a source build's script goes under `ThirdParty/build/`.

**Reason.** `Images/tools/` is the `apkrun_image` package, which handles the image and its manifests (AGENTS §6.3). The Mesa build makes a third-party component and its provenance record, not an image. `ThirdParty/build/` holds the scripts that the virgl-runtime group runs through `scripts/tools/build_third_party.py`, and this group is not run by that driver (IR-492).

**Consequence.** The maintainer decides the final location when the image integration (M02 step 2, the product fragment) is written. The M02 entry now lists `scripts/guest/` and `scripts/tests/`.

## IR-560: Test the developer stop through AndroidStopSequence, not RuntimeSupervisor

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (criterion 5) |
| Affected documents | [vm.md](../02-design/vm.md) §9.3; [M01 #015](issues/M01-android-bring-up.md#015-adb-debugging-over-vsock) |

**Choice.** The bounded wait and the forced stop move out of `RuntimeSupervisor.stop()` into `AndroidStopSequence`, an internal type. It takes the power-off request, the VM's state check, and the forced stop as `@Sendable` closures, and its deadline is a parameter that defaults to 20 s. The T0 tests drive that type with a fake VM. The channel choice (ADB, then the serial shell) moves into `AndroidStopSequence.sendPowerOff`, which takes the two attempts as closures, so it can be tested too.

**Reason.** `RuntimeSupervisor` reaches a running VM only through `ensureReady`, which needs an installed image, an instance, and the boot planner's manifest and disk files. The supervisor creates its `VMController` inside `boot()`, so no seam can be injected at that point. `VMController` has a `driverFactory` seam, but its fakes live in `VirtualMachineCoreTests`, which RuntimeCore tests cannot import. The smallest seam that makes the 20 s rule testable without a VM is the extracted decision.

**Consequence.** The wiring from `RuntimeSupervisor.stop()` to the sequence is covered by reading and by the T2 graceful path, not by a T0 test that drives the real controller. The real forced stop is covered by the `VMController` stop-timeout tests.

## IR-561: Give a developer power-off the full 20 s once a channel was tried

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (criterion 5) |
| Affected documents | [vm.md](../02-design/vm.md) §9.3 |

**Choice.** In developer mode the stop waits the full 20 s after the power-off request whenever a channel was tried, including when every channel failed. Only a stop that no channel could try (no ADB connection and no serial shell) forces the VM at once.

**Reason.** The previous code forced at once when neither channel reported success. An ADB request that times out is killed after 5 s (`AdbProcess`), but Android may already have received it. The serial fallback can also fail while the guest is powering off. A forced stop then cuts a graceful power-off short. vm.md §9.3 gives Android 20 s after the request, and the criterion says "falls back to a forced stop after 20 s", so the immediate force did not match the spec. The graceful path that T2 checks does not change, because ADB accepts the request there.

**Consequence.** A stop whose request was lost waits up to 20 s before the forced stop, where it previously forced at once. Developer mode has a serial shell from the start of the boot, so the no-channel case should not occur in practice.

## IR-562: Force outside developer mode at once until a Shutdown request is sent

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (criterion 5) |
| Affected documents | [vm.md](../02-design/vm.md) §9.3 |

**Choice.** Outside developer mode `stop()` sends no request and forces the VM at once, as before this change.

**Reason.** vm.md §9.3 names the Guest Agent `Shutdown` RPC as the production request. The message exists in `control.proto`, but RuntimeCore does not send it. Without a request, no graceful stop is running, so a 20 s wait would only delay the stop. Sending `Shutdown` belongs with the Guest Agent wiring, not with #015.

**Consequence.** The production stop has no graceful step until the Guest Agent request lands. The CLI always boots in developer mode, so no CLI path is affected today.

## IR-563: Tick criterion 5 on the T0 fallback and the T2 SIGINT run

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (criterion 5) |
| Affected documents | [M01 #015](issues/M01-android-bring-up.md#015-adb-debugging-over-vsock); [vm.md](../02-design/vm.md) §9.3, §17 |

**Choice.** Criterion 5 is ticked on two results. The first is the T0 fallback in `AndroidStopSequenceTests`, which drives a VM that never finishes its graceful stop: the forced stop comes after the deadline, and the VM ends stopped. The second is the T2 SIGINT run, which stopped Android with `reboot -p` in 1.71 s. The files do not record the channel. The timing points to ADB, because a timed-out ADB call would take 5 s. No fault hook that keeps a real guest running is added. The fallback test uses a 300 ms deadline, and a separate test checks that the production deadline is 20 s.

**Reason.** The #015 note asked for "a test or fault hook that keeps Android running". A guest-side hook, for example one that stops init from powering off, changes the boot and the guest images, and no seam offers it today. The T0 test covers the logic that decides the fallback. The real forced stop is covered by the `VMController` stop-timeout tests, and the T2 run covers the path that SIGINT takes into the request.

**Consequence.** The fallback has not run against a real guest that ignores `reboot -p`. A later fault hook would add that check.

## IR-564: Run the T2 SIGINT check as a script, not in XCTest

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (criterion 5) |
| Affected documents | [M01 #015](issues/M01-android-bring-up.md#015-adb-debugging-over-vsock) Notes; [cli.md](../02-design/cli.md) §3.5 |

**Choice.** The SIGINT check is a shell script, run under `lockf -k /tmp/apkrun-vm.lock`. It starts the signed embedded `apkrun dev boot`, waits for "press Ctrl-C to stop Android", sends SIGINT with `kill -INT`, and then checks the exit status, the elapsed time, and the guest's `reboot: Power down` line. The script is kept outside the repository, and its steps are in #015 Notes.

**Reason.** The SIGINT handler is in the `apkrun` executable (`CLI/apkrun/Dev/DevBoot.swift`), not in a library. The XCTest host runs `RuntimeSupervisor` in-process, so it never reaches that handler. A SIGINT sent to the XCTest host would end the host, because its disposition is the default. Only the real binary reaches the handler. The binary needs the virtualization entitlement, and the check needs a built guest APK and an installed test bundle, which the XCTest plans do not provide.

**Consequence.** The check is manual and is not repeated by the T2 suites. It should become a repeatable check once a harness can launch the CLI.

## IR-565: Map the headless launch of apkrun dev launch to the none GPU profile

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (build of the embedded CLI, outside criterion 5) |
| Affected documents | [cli.md](../02-design/cli.md) §5 (`apkrun dev launch`) |

**Choice.** `apkrun dev launch` passes `gpu: .none` to `DevBootOptions`. `DevGPUProfile.none` is documented as the development `headless` profile, so the launch keeps its headless profile. The change is one line in `CLI/apkrun/Dev/DevLaunch.swift`.

**Reason.** `DevBootOptions` replaced its `headless` flag with `gpu` (commit 09d8824). `DevLaunch.swift` still passed `headless: true`, so the embedded runtime build of `apkrun` failed to compile on main. The Debug CLI that the app embeds is built with that trait, and the T2 SIGINT check needs it.

**Consequence.** The embedded CLI builds again. `apkrun dev launch` has no new test, and its behavior is the same as the headless launch it was written for.

## IR-566: Do not handle Ctrl-C while the dev boot is still booting

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (outside criterion 5) |
| Affected documents | [cli.md](../02-design/cli.md) §3.5, §5 (`apkrun dev boot`) |

**Choice.** Not changed by #015. `DevBoot.execute` awaits `ensureReady` before it reads the stop stream, so a Ctrl-C during the boot is buffered and acts only after Android is ready. The boot runs to the end before anything happens. This was found by reading `Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevBoot.swift`. It was not run.

**Reason.** The criterion covers the stop after the boot. Making Ctrl-C end a boot needs a test with a booting VM, and that is a separate task.

**Consequence.** Ctrl-C during a boot (up to 180 s, or 900 s on a first boot) does not stop it. A follow-up should read the stop stream from the start and call `supervisor.stop()`, which already handles a stop during boot (`stopRequested`).

## IR-567: Do not exit on a second Ctrl-C

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (outside criterion 5) |
| Affected documents | [cli.md](../02-design/cli.md) §3.5 |

**Choice.** Not changed by #015. The dev boot takes the first SIGINT as the stop request, and it ignores later ones.

**Reason.** cli.md §3.5 says a second Ctrl-C exits at once with status 130. The dev boot does not do that. The exit path interacts with the forced-stop bound, so it needs its own decision.

**Consequence.** While the stop waits for Android (up to 20 s), a second Ctrl-C has no effect, so the user cannot skip the wait.

## IR-568: Count the 20 s from the start of the power-off request

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (criterion 5) |
| Affected documents | [vm.md](../02-design/vm.md) §9.3 |

**Choice.** The deadline starts before the first channel is tried, so the ADB attempt (at most 5 s) and the serial attempt (2 s) count within the 20 s. The forced stop follows 20 s after the start of the request, not 20 s after its reply.

**Reason.** The criterion says "after 20 s" from Ctrl-C, and the previous code measured this way (its comment said the deadline starts before the request). If the clock started after a 7 s channel failure, the stop could take 27 s.

**Consequence.** After a failed ADB request, the wait for Android is shorter than 20 s by the time that request took.

## IR-569: Do not join a second stop to the first one

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (found by review; the same behavior is on main) |
| Affected documents | [vm.md](../02-design/vm.md) §9.3; [runtime-daemon.md](../02-design/runtime-daemon.md) §3 |

**Choice.** Not changed by #015. `RuntimeSupervisor.stop()` does not record that a stop is under way, so a second call runs the sequence again.

**Reason.** The first `stop()` awaits the power-off wait, and the actor can run the second call during that await. The `apkrun dev boot` command calls `stop()` once, so the second call is not reachable from the CLI. The rule for joining a second caller to the stop in progress belongs with the XPC client of the runtime daemon.

**Consequence.** A second `stop()` during the wait sends a second `reboot -p`, and it can force the VM a second time. The VM still ends stopped.

## IR-570: The serial shell does not support overlapping commands

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (found by review; the same code is on main) |
| Affected documents | [runtime-daemon.md](../02-design/runtime-daemon.md) §3.2 |

**Choice.** Not changed by #015. `AndroidSerialShell` keeps one `waiter` continuation and clears the received output at the start of each `run`, so two overlapping runs are not supported.

**Reason.** A stop's power-off request can overlap the boot's `getprop` over the same shell when `stop()` runs during `confirmBootCompleted`. A second run would replace the first waiter, and the first continuation would then never resume. The reviewer found this by reading the code. It was not reproduced. `DevBoot` does not call `stop()` during the boot (IR-566), so the CLI does not reach it.

**Consequence.** A `stop()` during the boot's readiness check can leave that check hung. A fix serializes the shell's commands, or joins the stop to the boot, and belongs with the runtime-daemon work.

## IR-571: Keep the stop deadline when the stop task is cancelled

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (criterion 5) |
| Affected documents | [vm.md](../02-design/vm.md) §9.3; [runtime-daemon.md](../02-design/runtime-daemon.md) (operations survive the caller) |

**Choice.** The developer stop's wait ignores the cancellation of the caller. The forced stop still comes after the 20 s deadline. The wait sleeps in a detached task, so the cancellation does not reach the sleep.

**Reason.** A cancelled `Task.sleep` returns at once. The first version of the wait broke out of its loop on cancellation, so the VM was forced at once. The VM still has to stop, and the runtime's operations survive the caller that started them. A cancelled sleep that is not replaced by a detached one would also spin until the deadline.

**Consequence.** A stop that is cancelled takes the full deadline, as an uncancelled one does. No caller of the CLI cancels a stop today.

## IR-572: Sign the AndroidADB test host with the maintainer's Apple Development identity

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #015 (T2 AndroidADB configuration) |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.8 (`APKRUN_TEST_DEVELOPMENT_TEAM`, `APKRUN_TEST_CODE_SIGN_IDENTITY`) |

**Choice.** The AndroidADB run signs the test host with the Apple Development identity of the maintainer's git account. The team is `X4A37LMRPS`, and the identity is its SHA-1 fingerprint. It is passed as `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` on the `xcodebuild` command line.

**Reason.** The `APKRUN_TEST_DEVELOPMENT_TEAM` and `APKRUN_TEST_CODE_SIGN_IDENTITY` variables that name the lab certificate are not set in this shell, and the project file does not name a team. The VM tests need a signed test host, and the task's definition of done needs its T2 tier to run. The choice is the one identity on this Mac that matches the git account.

**Consequence.** The result is valid for this Mac. It is not signed with the CI lab certificate. The maintainer should repeat the AndroidADB run with the lab identity if the lab certificate is required for the record.

## IR-500: The virgl packages come from Alpine v3.23, not v3.24

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#022 step 1); [vm.md](../02-design/vm.md) §12; [build-system.md](../05-development/build-system.md) §3 (prebuilt inputs); [legal-and-licensing.md](../05-development/legal-and-licensing.md) §3 |

**Choice.** The Mesa virgl stack, kmscube, and their runtime closure of 32 packages come from the Alpine v3.23 `main` and `community` repositories: mesa 25.2.7, llvm21-libs 21.1.2, and the other packages that apk resolves for them. The kernel and the minirootfs stay on v3.24. musl is not unpacked from the closure, because the minirootfs musl (1.2.6-r2) is newer than the v3.23 musl (1.2.5).

**Reason.** The Alpine v3.24 `mesa` APKBUILD builds aarch64 Mesa without `virgl` in `_gallium_drivers`. The pinned mesa 26.1.6 `libgallium-26.1.6.so` has no virgl winsys. The guest's `virtio_gpu` driver was the stub of `drm_helper.h`, which printed `virtio_gpu: driver missing`, so Mesa fell back to llvmpipe. The v3.23 APKBUILD lists `virgl` for aarch64. Its `libgallium-25.2.7.so` has no `virtio_gpu` stub message, and the guest run with it reports the virgl renderer.

**Consequence.** The test guest runs Mesa 25.2.7 with LLVM 21. The closure unpacks to 220 MB, and the initramfs archive is 85.9 MB. This entry does not decide #099 or the product image (IR-240), which need their own Mesa build. A later Alpine release may drop `virgl` again, so the pins are checked against the APKBUILD at each update.

## IR-501: License texts for the closure come from the verified upstream tarballs

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §6.1; `ThirdParty/licenses/alpine-*/` |

**Choice.** Each `licenseFiles` entry of the 32 new components is a copy of a file from the upstream source tarball of its Alpine origin. The tarball is the one named in the Alpine APKBUILD, and its SHA-512 matches the APKBUILD `sha512sums`. The lock's `repository` is the APKBUILD `url`, the project home page, because the sources are tarballs. The lock's `license` is the APKINDEX expression. The llvm text is taken from the 159 MB llvm-project tarball.

**Reason.** The Alpine apk files carry no license texts: none of the 33 packages has a `usr/share/licenses` directory or a license-named file. The legal document requires a committed copy of each license text, and `scripts/tools/check-lock.swift` checks that each one exists.

**Consequence.** The `licenseFiles` paths are paths in the upstream tree, as §6.1 says, except for the libdrm notice of IR-502.

## IR-502: libdrm's MIT notice is copied from a source header

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §6.1 |

**Choice.** The libdrm tarballs (2.4.131 and 2.4.134) have no license file. `ThirdParty/licenses/alpine-libdrm/xf86drm.c-notice.txt` is the notice that `xf86drm.c` carries, copied verbatim from the comment block that contains "Permission is hereby granted". The lock lists that file as the only `licenseFiles` entry of `alpine-libdrm`.

**Reason.** Alpine gives libdrm the MIT license, and the header notice is the MIT text with its copyright holders. Another project's license text would be less accurate, and an invented file would not be upstream text.

**Consequence.** This is the only lock license path that is not a file of the upstream tree. A reviewer should compare it with the notices of other libdrm sources.

## IR-503: The #022 note that the initramfs needs the x86-64 builder is wrong

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2); #099 |
| Affected documents | [M02-graphics.md](../04-plan/issues/M02-graphics.md) #022 Notes; [environment-setup.md](../05-development/environment-setup.md) §4 |

**Choice.** The Linux test initramfs is built on the Mac from aarch64 Alpine packages, with the existing builder. Step 2 needs no x86-64 builder, and the #022 note that names one is corrected.

**Reason.** The builder only unpacks `.apk` tarballs with `tar`, `cpio`, and `gzip` from the base system, as environment-setup §4 already says. The virgl packages are aarch64 binaries from the v3.23 index. #099 is an Android image task (ImageCore, `Images/`), and it does not build the test initramfs.

**Consequence.** The #022 notes no longer say that step 2 waits for #099. The product image still needs its own VirGL EGL work under #099.

## IR-504: GET_CAPSET answers every version up to the cached maximum

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2 (`GET_CAPSET`); supersedes the version rule of IR-479 |

**Choice.** `GET_CAPSET` answers a version from 0 up to the cached maximum with the cached capset. A version above the maximum gets `ERR_INVALID_PARAMETER`. The exact-version rule of IR-479 is replaced.

**Reason.** The Linux kernel forwards the `cap_set_ver` that userspace passes. Mesa 25.2.7 (`virgl_drm_get_caps`) leaves it at 0 for capset 2. The exact-version rule answered with `ERR_INVALID_PARAMETER`, which the guest logged as `response 0x1205 (command 0x109)`, and Mesa fell back to llvmpipe. The pinned virglrenderer's `virgl_renderer_fill_caps` refuses only a version above the maximum, and it fills the same struct for the lower versions.

**Consequence.** A guest that asks for an older version gets the cached bytes, which are the maximum version's bytes. The T0 test `getCapsetAnswersEveryVersionUpToTheCachedMaximum` pins the rule.

## IR-505: The initramfs manifest check is part of the build

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [vm.md](../02-design/vm.md) §12; [test-strategy.md](../04-plan/test-strategy.md) §6 (T0) |

**Choice.** `scripts/tools/initramfs-manifest.py` runs after the packages are unpacked and before the archive is moved into place. It fails the build unless each package matches its lock entry (the SHA-256 of the apk, and the version in its URL), each path of `virgl-paths.list` resolves to a regular file in the root through relative symlinks, and each DT_NEEDED soname of an ELF file that these packages install is a file in the root's `lib` or `usr/lib`. On success it writes `initramfs.manifest.json` with the package and file hashes, the needed sonames, and the archive hash.

**Reason.** A missing library does not stop Mesa loudly. The driver falls back to llvmpipe, as this step showed. The check fails the build instead.

**Consequence.** A soname is matched by file name, not by its DT_SONAME field. The closure has 42 needed sonames, and all of them resolve. A future package whose SONAME differs from its file name would fail the build, and the tool would need to read DT_SONAME.

## IR-506: The virgl check passes on the renderer name and kmscube's frame report

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#022 step 2); [M02-graphics.md](../04-plan/issues/M02-graphics.md) #022 |

**Choice.** The guest runs `kmscube -D /dev/dri/card0 -c 60`. The check passes only if kmscube's GL renderer string contains `virgl`, and its final report says `Rendered 59 frames`. The guest prints `requested=60 reported=59`. The host test also requires `hostReadbacks == 0`.

**Reason.** kmscube's report counts `i - 1` frames, with the comment "first frame ignored" (drm-atomic.c and drm-legacy.c), so 60 requested frames are reported as 59. The check matches the report, which is what kmscube prints. A llvmpipe renderer string does not contain `virgl`, so the software fallback fails.

**Consequence.** The check depends on kmscube's report text. A kmscube update that changes the report needs a matching change to the check. The lock pins kmscube, so this does not change by accident.

## IR-507: `--tests virgl` attaches the virgl renderer device

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [graphics.md](../02-design/graphics.md) §8, §12 (#022 step 2) |

**Choice.** `LinuxTestGuestRunner.customDevices(for:)` attaches `VirtioGPUDevice.virgl()` when the tests include `virgl`. The function throws, because the renderer can fail to start. `gpu-hotplug` is not combined with `virgl`: the virgl device has no hotplug spike, so the guest reports scanout 1 as not connected and this code does not enable it.

**Reason.** The renderer must start before the VM, so a renderer failure is reported before any boot (graphics.md §8). The R-01 spike is a separate device setup, and combining it with the renderer is not part of this step.

**Consequence.** `apkrun dev linux --tests virgl,gpu-hotplug` fails the hotplug check by design.

## IR-508: The signing pair of the T2 run on this Mac

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [build-system.md](../05-development/build-system.md) §12.4; [environment-setup.md](../05-development/environment-setup.md) §4 |

**Choice.** The hosted T2 run used `DEVELOPMENT_TEAM=QTXBTFA8BQ` and `CODE_SIGN_IDENTITY="Apple Development: Chihiro Tachinami (6JT3HP32BQ)"`, the pair in the last recorded T2 log of this host. The pair `Akihiro Urushihara (X4A37LMRPS)` failed for the package targets with "No certificate for team".

**Reason.** The recorded pair ran the LinuxGuest suite before. The other pair could not sign the Swift package targets.

**Consequence.** A maintainer should confirm which lab identity the T2 records use. The signing values are not committed.

## IR-509: The hosted virgl test needs the runtime path through TEST_RUNNER

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [build-system.md](../05-development/build-system.md) §12.4; [graphics.md](../02-design/graphics.md) §5.2 |

**Choice.** `VirglTests` needs `TEST_RUNNER_APKRUN_VIRGL_RUNTIME_PATH` set to the verified cache, `ThirdParty/out/virgl-runtime/current`. The test does not set the path itself.

**Reason.** The debug search of GraphicsBridge starts from the test host's executable, which lies in DerivedData, so it cannot reach the repository's cache. The T1 renderer test sets the variable from its source location, and the hosted test has no equivalent path.

**Consequence.** Without the variable the test fails with `graphics.libraryMissing`. A maintainer may prefer the test to set the path from `#filePath`, as T1 does.

## IR-510: The 1 GiB Linux test guest runs the virgl check

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [vm.md](../02-design/vm.md) §12 |

**Choice.** The Linux test guest keeps its 1 GiB of memory. The virgl check ran on it with the 85.9 MB initramfs, which unpacks to about 250 MB with the base image.

**Reason.** The guest booted, Mesa loaded the virgl driver, and kmscube rendered in the observed run. Increasing the guest without a measured need would change a shared fixture.

**Consequence.** Boot time and peak memory were not measured. The kernel log shows 83920K of initrd memory freed after unpacking. A later task that adds more to the guest should measure this.

## IR-511: A download cache keyed by file name is kept

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [build-system.md](../05-development/build-system.md) (test artifacts) |

**Choice.** `scripts/fetch-test-linux.sh` keeps its download cache keyed by file name, as before. A cached file with the same name and a different hash is reported as a mismatch, downloaded again, and verified against the lock.

**Reason.** `zlib-1.3.2-r1.apk` and `zstd-libs-1.5.7-r2.apk` have the same names in v3.23 and v3.24, with different hashes. The re-download is correct, and the lock verifies it. Keying the cache by release would change the fetch script beyond this step.

**Consequence.** The mismatch line is printed on the normal path after a pin change. It does not mean that the build failed.

## IR-512: The third-party notice check did not run in this worktree

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2) |
| Affected documents | [legal-and-licensing.md](../05-development/legal-and-licensing.md) §6.2 |

**Choice.** `scripts/release/generate-notices.py --check` was not run for this change. It runs `check-lock --apply`, which refuses a source-checkout path that contains a symlink. The worktree's `ThirdParty/out` is a symlink to the main checkout, so the check stops there. Nothing was written.

**Reason.** `--apply` writes patches into the source checkouts. Running it on the main checkout would change another checkout.

**Consequence.** CI's third-party job must run this check on a real checkout before the task closes. The new components are `ships: tooling`, so they do not change the app notices.

## IR-513: The signing fixture checks of run.sh are fixed on main by f14faf8

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2); the signing fixtures of b44ad19 |
| Affected documents | [test-strategy.md](../04-plan/test-strategy.md) (script T0 checks); `Tests/Fixtures/signing/`, `scripts/release/check-release-build.sh` |

**Choice.** This branch makes no change to the signing checks. Before the rebase onto main f14faf8, `scripts/tests/run.sh` stopped at the keystore pin check and at the release fixture check of `check-release-build.sh`, both on `test-guest-dev.jks`, which b44ad19 committed without a pin. f14faf8 pins that keystore and verifies every pin. On the rebased tip, `scripts/tests/test_release_check_keystores.py` passes, and `scripts/tests/run.sh` exits 0 with 201 PASS lines.

**Reason.** f14faf8 is the fix that this entry asked the fixture owner for, so the branch takes it from main instead of making a second change.

**Consequence.** One run of `run.sh` on the rebased tip stopped at a 30-second timeout in a `check-lock --apply` fixture, while the host's load average was about 24. A rerun on a quiet host passed. The timeout reflects host load and not the code, but a run on a loaded host can fail the same way.

## IR-514: The #022 replay fixture is synthetic, because no Linux run recorded kmscube

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3) |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#022 step 2), §14, §16; [build-system.md](../05-development/build-system.md) §8; [test-strategy.md](../04-plan/test-strategy.md) §4; [M02-graphics.md](issues/M02-graphics.md) #022 |

**Choice.** The replay input is `Tests/Fixtures/graphics/synthetic-virgl-session.json`. It is a `VirGLRecording` of six renderer calls that the existing helpers make: one context, one 16 × 16 BGRA target, a full upload, a 4 × 4 upload at (4, 4), and a fence. `RecordingVirGLEngine` records it around a real renderer. The file is not a `kmscube` capture, and the documents say so until a Linux run records the real stream.

**Reason.** This step runs no VM. I checked the artifacts that the step named. `/private/tmp/apkrun-l22` holds the virgl run logs and xcresults. The hvc0 console of the successful run shows `renderer: "virgl"` and `Rendered 59 frames`, and it holds no command stream. `/private/tmp/apkrun-l22-linux/gpu-driver-trace.json` is the 2D `gpu` check of #019, with no `SUBMIT_3D`. The commit that added the run, d312886, names no artifact path: its test writes only the console and the xcresult. The main checkout's build area (`ThirdParty/out` links there) holds no file named like a recording. The run used `VirtioGPUDevice.virgl()`, which attaches no recorder (`LinuxTestGuestRunner.swift:55`), so no stream was written. IR-475 had already deferred the `kmscube` recording to a follow-up that needs the VM.

**Consequence.** The replay checks the renderer's replay path and the test-only readback. It does not check the `kmscube` command set. The real capture is a follow-up that needs one Linux run with a recorder attached (IR-519). No pass is claimed for the `kmscube` stream.

## IR-515: The replay runs on the device's render thread through test-only seams

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3) |
| Affected documents | [graphics.md](../02-design/graphics.md) §7, §14; [M02-graphics.md](issues/M02-graphics.md) #022 step 3; [coding-conventions.md](../05-development/coding-conventions.md) (`DEBUG-READBACK`) |

**Choice.** `VirtioGPUDevice` has two seams, compiled only under `#if APKRUN_TEST_READBACK`: `replayRecordingForTest(_:)` replays a recording on the device's renderer, and `readResourceForTest(_:byteCount:)` calls the renderer's test-only readback. Both run on the render thread, and neither touches `counters`. The T1 test replays the fixture on a `drmVirgl` device, reads the scanout through the device, and requires `hostReadbacks` and `guestReadbacks` to be 0.

**Reason.** The entry requires the readback counter to stay at 0 on the normal path, and the test-only readback to be excluded from it. A bare `VirGLRenderer` has no counter, so a replay on it cannot show either. The seams put the replay on the device's own render thread and counters, with the smallest change. A later regression that counted the test readback in the device would fail the test.

**Consequence.** The seams are production source under a test flag, and they can be removed with it. A maintainer who prefers no production seam can keep the engine-level replay that `aRecordedSessionReplaysOntoAFreshRenderer` already runs, and accept that the counter check is then vacuous. `hostReadbacks` has no increment in any code path, so the check guards future code only.

## IR-516: The synthetic replay has zero tolerance and an independently pinned hash

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3) |
| Affected documents | [graphics.md](../02-design/graphics.md) §14 (T1); [M02-graphics.md](issues/M02-graphics.md) #022 step 3 |

**Choice.** The replayed scanout must equal the expected image byte for byte. The test counts the bytes that differ, and the tolerance is zero. The expected image is the recorded transfers applied by the box rule of virglrenderer's `read_transfer_data`. Its SHA-256, `41172b76…`, was computed from the fixture JSON by a separate Python script and pinned in the test. The script is not committed: it is the same nine-line loop as `expectedSyntheticScanout`, written in another language. The fixture's own SHA-256 is pinned too.

**Reason.** The synthetic stream has no rasterization, so an exact match is the right criterion, and a tolerance would hide errors. The entry's "within tolerance" wording is for rendered output, where GPU rounding can differ. Pinning a value that a separate script computed means a mistake in the Swift rule cannot make the expectation match the output. A mutation that reversed the channel order failed the test, so the comparison is live.

**Consequence.** The `kmscube` fixture needs a tolerance chosen from its own observed output, and then the pinned hash becomes a per-byte check rather than an exact one.

## IR-517: A sub-box upload starts at the box origin, and the doc comments say otherwise

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3) |
| Affected documents | [graphics.md](../02-design/graphics.md) §4.2, §4.4; the `VirGLTransfer` and `TransferGeometry` doc comments in `Packages/GraphicsCore/Sources/GraphicsCore/Renderer/VirGLEngine.swift` and `Resources/TransferGeometry.swift` |

**Choice.** No code changes. The synthetic 4 × 4 upload at (4, 4) has data that starts at the box's first pixel, with rows 64 bytes apart, so 208 bytes cover it. The replay matches that layout on the real renderer. The doc comments instead say that the host buffer begins at the resource origin, and that the offset is the byte offset of the resource origin in the guest backing. This entry records the discrepancy and leaves the wording to the maintainer.

**Reason.** In the pinned virglrenderer (`src/vrend/vrend_renderer.c`), `read_transfer_data` reads row `h` from `offset + h * stride`, and `vrend_transfer_size` is `stride * (h - 1) + w * bpp`. The GL upload then places the data at `box.x` and `box.y`, so the box's pixels must be at the start of the data. The replay confirms this.

**Consequence.** The device gathers from the guest's `offset` field, so a sub-box upload is correct only if the guest puts the box origin in that field. No trace in the repository has a sub-box transfer: the #019 and #022 traces are full-screen. This is unverified for non-zero x or y. A maintainer should check a guest trace with a non-zero box before the comments are corrected, or before a device test with a sub-box is added.

## IR-518: The fixture is regenerated by an environment-gated test and checked byte for byte

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3) |
| Affected documents | [build-system.md](../05-development/build-system.md) §8; [graphics.md](../02-design/graphics.md) §14 |

**Choice.** `regenerateTheSyntheticReplayFixture` rewrites the fixture when `APKRUN_REGENERATE_FIXTURES=1` is set, and it is skipped otherwise. `theSyntheticReplayFixtureIsWhatItsGeneratorRecords` runs on every T1 pass. It records the same session and requires the committed bytes to equal it, and it pins the file's SHA-256.

**Reason.** A committed recording that nobody can regenerate is opaque, and a script outside the test would drift from the generator. Keeping the generator and the check in one file, with byte equality, makes the fixture reproducible from its source.

**Consequence.** The recording is JSON with sorted keys, so any change to `VirGLOperation` changes the bytes. The fixture must then be regenerated and its pinned hash updated. That forces a review of the fixture whenever the format changes.

## IR-519: The synthetic stream has no SUBMIT_3D, and the kmscube capture is a follow-up

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 3); a follow-up is needed |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 (#022 step 2), §14; [M02-graphics.md](issues/M02-graphics.md) #022 |

**Choice.** The synthetic session uses only the context, resource, transfer, and fence calls. It has no `submit`, because the repository has no virgl command encoder, and writing one is new test code outside this step. The T1 check ran on this Mac, with and without the `TestReadback` trait, not on a CI runner. The `kmscube` capture is a follow-up: the Linux test runner must attach a `VirGLRecorder`, through a test-only seam or a development option, run `kmscube`, and commit the recording with its source and SHA-256.

**Reason.** The step asks for a synthetic stream made by the existing helpers. Those helpers include no command-buffer encoder, so a `SUBMIT_3D` would need an encoder, which is a larger change than this step allows. The CI runner is not available from this worktree.

**Consequence.** The T1 replay does not exercise virglrenderer's command decoder. Until the real capture exists, the `kmscube` check of step 2 is the only test of the decoder on real commands. The step 3 criteria that name the `kmscube` stream stay open.

## IR-520: The developer ADB port is a per-boot option, and the product default stays 6520

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10; [../03-reference/configuration.md](../03-reference/configuration.md) §2.5; [../02-design/vm.md](../02-design/vm.md) §8 |

**Choice.** `BootOptions.adbHostPort` carries the developer ADB port of one boot. Its default, `BootOptions.defaultADBHostPort`, is 6520, and the forwarder and the ADB client of the boot use that port. `apkrun dev boot`, `apkrun dev adb`, and `AdbClient.developmentEndpoint` keep 6520.

**Reason.** The forwarder bound 6520 for every developer-mode boot, so two VM runs on one Mac collided. The port is an option of the boot, so the test harness can give each run its own value without changing a product path. The documented developer contract names 6520 (configuration.md §2.5, cli.md §5), and it stays.

**Consequence.** Only the T2 harness passes another port. A developer's `apkrun dev adb` does not reach a test VM, which is the intended separation.

## IR-521: A test run takes a kernel-chosen port, and the supervisor reports the bound port

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10; [../02-design/vm.md](../02-design/vm.md) §8 |

**Choice.** The harness passes `0` unless `APKRUN_TEST_ADB_PORT` is set. The supervisor exposes the port the forwarder bound as `developmentADBHostPort`, and the ADB test reads it after `ensureReady`.

**Reason.** A harness that probes a free port and closes it before the forwarder binds leaves a window in which another process can take the port. `VsockLoopbackForwarder` already accepts `0` and reports the port it bound, so the port is chosen and bound in one step.

**Consequence.** The port is known only after the bridge starts. A pinned port remains possible through the environment (IR-522).

## IR-522: APKRUN_TEST_ADB_PORT is parsed strictly, and xcodebuild passes it with the TEST_RUNNER_ prefix

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10 |

**Choice.** An unset or empty value means `0`. Any other value must be a decimal port number from 0 to 65535, with ASCII digits only. Anything else fails the run with `VMRunResourcesFailure.invalidADBPort`. xcodebuild passes the variable to the test process as `TEST_RUNNER_APKRUN_TEST_ADB_PORT`, as `scripts/run-gate.sh` already does for `APKRUN_G2_DWELL_SECONDS` (line 53).

**Reason.** A silent fallback could send a run to a port that another run owns, which is the cross-talk failure of test-strategy §3.10. The prefix is the one the repository already relies on.

**Consequence.** The coordinator sets `TEST_RUNNER_APKRUN_TEST_ADB_PORT`. A VM run has not yet confirmed that the prefix reaches the test process (test-strategy §3.10, Notes item 2).

## IR-523: Each run's home is a /tmp directory named with its UUID, and the console sockets keep their names

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.9, §3.10 |

**Choice.** A run's home is `/tmp/apkrun-vm-<UUID>`, and every product path under it comes from `APKRunPaths`. The console sockets keep the names `hvc0.sock` and `hvc1.sock`. Their uniqueness comes from the per-run directory. A run's home is never under `$TMPDIR`.

**Reason.** `DevConsoleSocketServer.serve` removes whatever file is at the socket path before it binds (`DevConsoleSocket.swift:64-66`), so two servers on one directory replace each other's socket silently. The CLI (`apkrun dev console`) depends on the names. A `$TMPDIR` home puts the socket path beyond the 103-byte `sockaddr_un` limit.

**Consequence.** The boot fixtures and G2 use the same root. A T0 test checks that every run's console socket path fits the limit.

## IR-524: The harness helper is a SwiftPM test target, and the Xcode bundles compile the same file

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §2.2, §3.10; [../05-development/build-system.md](../05-development/build-system.md) §2.1, §2.2 |

**Choice.** `VMRunResourcesTests` is a SwiftPM test target at `Tests/IntegrationTests/RunResources`. `project.yml` compiles the helper into the IntegrationTests and AcceptanceTests bundles and excludes the T0 file from them.

**Reason.** CI runs T0 with `swift test --skip SystemTests`, which reaches only SwiftPM targets, and the Xcode bundles cannot run in that job. A product module would have added an architecture module, and the helper is test code only. `check-module-deps` classifies the target as an integration target, and it passes.

**Consequence.** The helper is built twice, once by SwiftPM and once by Xcode, so a change to it must keep both builds green.

## IR-525: Parallel VM runs go against the one-VM rule of §3.6, and a maintainer must decide

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.6, §3.10 |

**Choice.** test-strategy §3.6 is not changed here. §3.10 describes parallel runs as allowed only under the coordinator rules, and that takes effect when a maintainer accepts this entry.

**Reason.** §3.6 is the lab's operating rule ("runs one VM at a time"), not a test rule. Changing it changes what the lab Mac does on every run, and the memory cost of two Android VMs on a 16 GB Mac has not been measured (IR-537).

**Consequence.** Until this entry is accepted, a parallel run is a manual exception that the coordinator records.

## IR-526: The artifact directory stays shared, and no producer runs during a parallel run

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10 |

**Choice.** Runs keep reading `APKRUN_TEST_LINUX_DIR` directly. The producers (`run-gate.sh`, `build-test-initramfs.sh`, `fetch-test-linux.sh`, `build-test-android-bundle.sh`, `build-test-android-disks.sh`) do not run while a VM run is active.

**Reason.** A per-run snapshot of the artifacts would change where each run reads its inputs. The race it would prevent is rare, and a coordinator rule prevents it, so the change is not needed for the parallel rule of this task.

**Consequence.** A producer that rewrites a file during a VM start can make that start fail, and the failure does not name the cause.

## IR-527: Gate runs use the per-run ADB port too

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [roadmap.md](roadmap.md) §2 (G2); [test-strategy.md](test-strategy.md) §5, §3.10 |

**Choice.** G2 takes its ADB port from the run's environment, as every other suite does. It does not pin 6520. Unless `TEST_RUNNER_APKRUN_TEST_ADB_PORT` is set, G2 uses a kernel-chosen port.

**Reason.** No G2 pass condition names the ADB port (roadmap.md §2). A gate that kept 6520 would be the one suite that differs from the others, which would hide port problems from the gate. The gates run alone under the lock, so their port does not affect their safety.

**Consequence.** The G2 report does not record the port.

## IR-528: The GitHub issue of #098 is #100

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 (GitHub issue #100; reserved for follow-ups, AGENTS §11) |
| Affected documents | [../05-development/workflow.md](../05-development/workflow.md) §2.4; [issues/README.md](issues/README.md) §3 (not edited here) |

**Choice.** The task keeps the name #098 in the branch, the docs, and the commits. Its GitHub issue is #100, because GitHub skips #098. Before merge, the commit `Refs` lines and the pull request take #100, and the entry goes into its milestone file and into `issues/README.md` §3 in the same pull request. This change does not edit `issues/README.md`, as the task requires.

**Reason.** workflow §2.4 says that GitHub gives each new task its number, so that two agents never take the same one. GitHub did not issue #098 to this task, so the number of its issue is #100.

**Consequence.** The branch cannot merge until issue #100 exists. The `Refs` lines are rewritten from #098 to #100 at that time.

**Result of the teardown fix (2026-10-10, rebased onto main 18dbf01).** After an AndroidADB run, the run's home stayed behind without a message. An installed image is read-only (`dr-xr-xr-x`, `r--`), and `AndroidBootSession.finish()` removed the home with `try?`. `VMRunResources.removeHome(_:)` now restores the owner's write bit on each directory and file under the home and never follows a symbolic link, then removes the home. A failure throws with the path and the underlying error. `VMRunResources.removeHomeOrReport(_:)` writes the path and the error to standard error, so they appear in the test output. `AndroidBootSession.finish()`, `AndroidBootFixture.removeTestHome`, and the G2 teardown use it. T0 `VMRunResourcesTests`: 11 of 11 passed before the change, and 14 of 14 after it, including `removesAReadOnlyHomeAndLeavesSymbolicLinkTargetsAlone`, `aHomeThatCannotBeRemovedThrowsItsPathAndTheError`, and `removingAHomeThatIsGoneIsNotAnError`. T0 `BootOptionsTests`: 2 of 2 passed. One AndroidADB run under `lockf -k /tmp/apkrun-vm.lock`, `AndroidADBTests/testDevelopmentBootServesADBOnLoopbackOnlyAndStopsGracefully`: 1 passed, 0 failed, 17.1 s. No removal error was written, and no `/tmp/apkrun-vm-*` home was left. G2 was not run.

## IR-529: Parallel xcodebuild runs need their own DerivedData and result bundle paths

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10; [../05-development/build-system.md](../05-development/build-system.md) §2.3 |

**Choice.** test-strategy §3.10 states the rule. The harness does not check it.

**Reason.** The paths are chosen on the `xcodebuild` command line, outside the test process, so a test cannot see another run's build. Two runs with one DerivedData path replace one test host app under each other, and two runs with one result path overwrite it.

**Consequence.** The coordinator follows the rule. A wrapper script that enforces it can be added later.

## IR-530: The developer-mode-off test still checks the product port

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10 (Notes item 3) |

**Choice.** `testDeveloperModeOffListensOnNoPort` asserts that no forwarder starts (`developmentADBHostPort` is nil) and that nothing listens on the product port, 6520.

**Reason.** The product port is the one a developer's `apkrun dev boot` uses, and the test has always checked it. A stricter check, that no TCP listener belongs to the test host process, was not chosen, because XCTest could hold a listener inside the host and no VM run has shown that it does not. A check that cannot be verified could fail falsely.

**Consequence.** The test fails while a developer boot holds 6520, so the coordinator runs it with no dev boot up. A follow-up can switch to the process check after a VM run confirms that the host holds no listener.

## IR-531: The DiagnosticsCore T0 tests share fixed directories under /tmp

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10 |

**Choice.** Not changed. The fixed directories are `/tmp/apkrun-health-tests` (`Packages/DiagnosticsCore/Tests/DiagnosticsCoreTests/HealthTests.swift:385`) and `/tmp/apkrun-host-check-tests` (`HostChecksTests.swift:125`).

**Reason.** These T0 tests run no VM, and the parallel VM runs do not run them. Two concurrent `swift test` processes can still collide on them.

**Consequence.** Concurrent T0 runs are not safe until these tests use per-run directories. That is a follow-up.

## IR-532: The Debug apkrund label names one LaunchAgent per user, and no T2 suite starts apkrund

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10 |

**Choice.** Parallel runs do not start apkrund in two runs at once. This is a rule for future suites, since the current suites do not start apkrund.

**Reason.** `io.apkrun.apkrund.dev` (`Packages/DiagnosticsCore/Sources/DiagnosticsCore/Build/BuildInfo.swift:33`) names one LaunchAgent per user, and the host checks read it (`HostChecks.swift:216`). Giving each run its own label would change the Debug identity, which is a product decision.

**Consequence.** A future suite that starts apkrund cannot run in parallel until the maintainer decides the identity.

## IR-533: The error catalog keeps the port 6520 in its documentation text

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [../03-reference/error-catalog.md](../03-reference/error-catalog.md) (`runtime.adbConnectionUnavailable`) |

**Choice.** `Packages/DiagnosticsCore/ErrorCatalog/errors.json` (the `doc.when` text of `runtime.adbConnectionUnavailable`, line 1289) is not changed.

**Reason.** The remediation a user sees names `apkrun dev boot` and does not name the port. The port appears only in the documentation field, and changing it means regenerating `ErrorCatalog.generated.swift` for text that is still true of the product.

**Consequence.** In a test run on another port, the catalog's documentation can name a port that the run does not use. The user-visible text is unaffected.

## IR-534: DevConsoleSocketServer.serve removes a live socket file

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10; [../02-design/cli.md](../02-design/cli.md) §5 |

**Choice.** Not changed in #098. Recorded as a product hazard.

**Reason.** `DevConsoleSocketServer.serve` removes whatever file is at the socket path before it binds (`Packages/RuntimeHost/Sources/RuntimeHost/Dev/DevConsoleSocket.swift:64-66`), even when a live server owns it. The product's own dev boot runs one server per home, so normal use is not affected. Refusing to replace a live socket changes the product's behavior in RuntimeHost, which needs a decision.

**Consequence.** The test harness avoids the hazard with per-run directories (IR-523). A follow-up can make `serve` refuse a socket that still accepts connections.

## IR-535: The bundle and disk builders take no lock, unlike the initramfs and kernel fetch

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.4, §3.5, §3.10 |

**Choice.** Not changed in #098. Recorded.

**Reason.** `scripts/build-test-android-bundle.sh` and `scripts/build-test-android-disks.sh` write into `APKRUN_TEST_LINUX_DIR` without the `.artifacts.lock` that `build-test-initramfs.sh` and `fetch-test-linux.sh` take. Two producers can interleave. The fix changes the image pipeline's producers, which the image tasks own.

**Consequence.** Two producers at once can leave a mixed set of files. The coordinator rule (IR-526) keeps the producers from running during a parallel run.

## IR-536: Each run clones the Android image into its home, and the cost of the clones is not measured

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10 |

**Choice.** Not changed. The image install of each run clones the bundle into the run's home with `clonefile(2)` (`Packages/ImageCore/Sources/ImageCore/Store/FileCloner.swift`, used at `Packages/ImageCore/Sources/ImageCore/Store/ImageStore.swift:166`).

**Reason.** A clone shares blocks with its source, so one run's install costs little space until the files diverge. The time and the space of many clones on the lab's APFS volume are not measured, and AGENTS §8 says not to optimize before measuring. The instance disks are sparse, but their logical size is large (`removeTestHome` in `Tests/IntegrationTests/AndroidBootTests/AndroidBootFixture.swift`).

**Consequence.** The coordinator checks the free space of the volume before a parallel run. A later task can measure the clone cost.

## IR-537: The host capacity for parallel Android VMs is not verified

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.1, §3.10 (Notes item 4) |

**Choice.** No limit is set in code. The coordinator checks the memory of the Mac and the number of VMs before a parallel run.

**Reason.** No run on the lab Mac has measured two Android VMs together, and the Virtualization.framework limit on concurrent VMs has not been checked on this host.

**Consequence.** The check is test-strategy §3.10, Notes item 4. Until it passes, parallel runs stay a manual exception (IR-525).

## IR-538: The G2 reference capture stays after the run

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [../02-design/android-image.md](../02-design/android-image.md) §8.4; [test-strategy.md](test-strategy.md) §3.10 |

**Choice.** The capture directory is `/tmp/apkrun-vm-<UUID>-capture`, a sibling of the run's home, and the teardown does not remove it.

**Reason.** The capture is gate evidence (android-image.md §8.4), and the teardown removes the home. The old code also kept the capture, in `$TMPDIR`.

**Consequence.** Each G2 run leaves one capture directory under `/tmp`. The coordinator removes it after copying the evidence (test-strategy §3.10, Notes item 7).

## IR-539: #098 is verified without a VM, and its T2 behavior is unverified

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #098 |
| Affected documents | [test-strategy.md](test-strategy.md) §3.10 (Notes) |

**Choice.** The change is verified by the T0 run (`swift test --skip SystemTests` passes), by the lint and the module graph check, and by building the IntegrationTests and AcceptanceTests bundles for testing. No test ran on a VM. The T2 behavior of the port, the console sockets, and the per-run homes is unverified until the coordinator runs the checks of test-strategy §3.10, Notes. Two checks cannot run in this worktree, because it has no `build/tools`: `scripts/check-protos.sh` (no proto file changed) and `scripts/check-lock.sh`, whose Swift checker passes when given the pinned xcodegen. `scripts/tests/run.sh` fails its keystore pin check, and the same check fails at the baseline eb23d2b: `Tests/Fixtures/signing/test-guest-dev.jks` is committed but not pinned (`scripts/tests/test_release_check_keystores.py`). That failure predates #098 and is not fixed here. The IR range was full, so it is recorded in this entry.

**Reason.** The lab Mac runs VMs under the lock, and this task must not run a VM.

**Consequence.** The change must not be merged as verified for T2 until the coordinator's checks pass. The decisions IR-520 to IR-539 remain open for the maintainer.

## IR-553: Check name resolution with the first line of `ping -c 1`, because the stock image has no getent

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 (step 5) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #095 step 5 and criterion; [android-image.md](../02-design/android-image.md) §7.4, §7.8 |

**Choice.** `AndroidNetworkTests.testNetwork` checks name resolution with `ping -c 1 -W 2 connectivitycheck.gstatic.com 2>&1 | head -n 1`, run as root (`su 0`), since the shell cannot reach the resolver (IR-555). The DNS stage passes only when that line starts with `PING connectivitycheck.gstatic.com (`. An error line such as `ping: unknown host ...` does not pass. The poll and its 120 s bound are unchanged.

**Reason.** The stock image (build 16373615) has no `getent` or `nslookup` (android-image.md §7.8, read from the `system_a` partition and confirmed by `command -v` in the guest). `dumpsys dnsresolver` reported `Can't find service: dnsresolver` on the probe boot, `ndc resolver` printed nothing as the shell (and `500 0 Command not recognized` as root), and `getprop` has no DNS property. Of the candidates, only `ping` reports a name-resolution result, and M01 #095 step 5 already names `ping -c 1 connectivitycheck.gstatic.com` as the check.

**Consequence.** The first run in which the name resolved is the root run of `11f93c7` (before the rebase onto main; `c839ef8` is the same change after it): its `resolved:` line is `PING connectivitycheck.gstatic.com (142.251.150.120) 56(84) bytes of data.`, which has the prefix. The shell's runs (`806d07a`, now `ed40540`) never resolved, so only the root run shows the banner for a resolved name.

## IR-554: The VALIDATED stage also rejects `NOT_VALIDATED`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 (step 5) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #095 step 5; [android-image.md](../02-design/android-image.md) §7.8 |

**Choice.** The VALIDATED stage passes only when the WIFI `NetworkAgentInfo` line contains `VALIDATED` and does not contain `NOT_VALIDATED`. The loop's break condition and the final assertion use the same test.

**Reason.** The stage on main is a substring match. IR-547 on `task/095-network-and-port-markers` records that a substring match can pass a line that the dump does not mark as validated. The network run of `806d07a` (now `ed40540`) shows `VALIDATED` as a capability (`...&NOT_VPN&VALIDATED&NOT_ROAMING...`) and does not show `NOT_VALIDATED`, so this guard does not change the result of that run.

**Consequence.** The stage keeps its meaning: it asks whether NetworkMonitor validated the Wi-Fi network. A dump that contains `NOT_VALIDATED` now fails the stage instead of passing it.

## IR-555: The DNS failure is the serial shell's: it cannot reach netd's DNS proxy, while the network and the resolver work

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 (step 5) |
| Affected documents | [M01](issues/M01-android-bring-up.md) #095 acceptance criteria; [android-image.md](../02-design/android-image.md) §7.4, §7.8 |

**Choice.** The DNS stage runs its ping as root (`su 0`), commit `11f93c7` (now `c839ef8`). The network is not changed. The shell's access to netd's DNS proxy is an image policy question, and it belongs to #035 (the APKRun AOSP product, which owns the image's SELinux policy; android-image.md §7.8 and §11). This task does not change the policy. The network criterion stays unchecked.

**Reason.** The evidence is from probe boots on 2026-10-10 (20:29 to 21:22 JST, probes 1 to 8), each under `lockf`. The records are in scratch files outside the repository, and §7.8 summarises them.
1. The servers of the LinkProperties line answer. `DnsAddresses: [ /fe80::fcb2:14ff:feba:7a64%wlan0,/192.168.64.1 ]`. A hand-built A query for `connectivitycheck.gstatic.com` from the guest (`toybox nc -u`) got RCODE 0 and `142.251.150.120` from `192.168.64.1` and from `fe80::fcb2:14ff:feba:7a64%wlan0` (`nc -6`). The control `8.8.8.8` also answered. ICMP to both servers got `100% packet loss`, which is the vmnet ICMP behaviour the design records.
2. The host's query to the vmnet server works: `dig @192.168.64.1 connectivitycheck.gstatic.com A` returned `NOERROR` with `142.251.150.120` in 1 to 6 ms, and `dig @fe80::fcb2:14ff:feba:7a64%bridge100` did too. `dig +tcp` to `192.168.64.1` reported `end of file`.
3. The resolver serves other clients on netid 100. The log shows `resolv_set_nameservers: netid = 100, addr = 192.168.64.1` and `addr = fe80::fcb2:14ff:feba:7a64%wlan0`. NetworkMonitor (uid 1000) logged `PROBE_DNS connectivitycheck.gstatic.com 9ms OK 142.251.150.120` and `PROBE_HTTP ... ret=204`. App uids 10029, 10066, and 10111 each got `doQuery: rcode=0` through netid 100.
4. The shell cannot reach the resolver. The serial shell is `uid=2000(shell)` in `u:r:shell:s0`. `toybox nc -U /dev/socket/dnsproxyd` printed `nc: connect: Permission denied`, and `ls -lZ /dev/socket/dnsproxyd` printed `Permission denied`. The shell's lookups fail at once with no resolver log line: `ping` printed `ping: unknown host connectivitycheck.gstatic.com` (elapsed 0), and `toybox nc -z` printed `No address associated with hostname` (elapsed 0).
5. Root connects and resolves. Root is `uid=0(root)` in `u:r:su:s0`. `toybox nc -U /dev/socket/dnsproxyd` returned `status=0`, and `su 0 ping -c 1 -W 2 connectivitycheck.gstatic.com` printed `PING connectivitycheck.gstatic.com (142.251.150.120) 56(84) bytes of data.` with `elapsed=2`.
6. The earlier reading that the resolver service was absent was wrong. `service list` registers `dnsresolver: []` and `netd: []`. `dumpsys dnsresolver` (probes 1 and 6) and `dumpsys netd` (probe 5) print `Can't find service`, because the shell's service lookup is denied: `avc: denied { find } for pid=3977 uid=2000 name=dnsresolver scontext=u:r:shell:s0 tcontext=u:object_r:dnsresolver_service:s0 tclass=service_manager permissive=0`.
7. Not separated: the log has no AVC line for the DNS-proxy connect, so whether SELinux or the socket's permissions refuse it is not shown. Not traced: the first probe boot (20:29 JST) also failed its root lookup. Its logs were not captured, so the cause of that failure is open.

**Consequence.** The DNS stage can pass only as root, because the shell cannot resolve on this image. Five runs after the change (`AndroidNetwork`, `testNetwork`, one boot each, under `lockf`, 22.3 to 27.2 s) all passed, and each `validated:` line has `&VALIDATED&` and no `NOT_VALIDATED` (android-image.md §7.8). Five of five is the reliable validation that IR-374 asks for, so the network criterion of #095 is ticked in M01. The DNS stage still runs as root, and the follow-up below is unchanged. Follow-up, not implemented here, owner #035: decide whether the custom image should let the shell domain connect to `dnsproxyd`. The denial was observed on the stock build 16373615 under Virtualization.framework; whether a stock Cuttlefish device grants the shell this access was not tested. If the custom image should match the stock behaviour, the fix is in the image's policy. If the shell is meant to be denied, the test stays on root.

## IR-556: The DNS pass recorded in IR-374 is unverified, and the old check could pass on an error line

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 (follow-up of IR-374) |
| Affected documents | [android-image.md](../02-design/android-image.md) §7.4, §7.8; IR-374 (not edited) |

**Choice.** IR-374 says that in the later runs the address, the route, and DNS passed within the poll. This entry does not rely on that statement. The DNS pass in those runs is treated as unverified.

**Reason.** On main, the DNS check was `getent hosts connectivitycheck.gstatic.com` with `!resolved.isEmpty`, and `AndroidShellConsole.value` does not check the exit status. The stock image has no `getent`, so the shell's `getent: inaccessible or not found` line is the likely reply, and it is non-empty, so the check counted it as resolved. IR-547 on `task/095-network-and-port-markers` records the same gap. The probe boots and the network run of `806d07a` (now `ed40540`) show the name not resolving with the shell's `ping`, and IR-555 gives the cause.

**Consequence.** §7.4's 2026-10-08 DNS result is kept as the spike's record and marked as not reproduced on 2026-10-10 (IR-555). IR-374 is not edited. Its DNS statement should be read with this entry.

## IR-557: This branch keeps main's test, so it conflicts with the stage walk on task/095-network-and-port-markers

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 |
| Affected documents | [M01](issues/M01-android-bring-up.md) #095 step 5; [android-image.md](../02-design/android-image.md) §7.8 |

**Choice.** `task/095-dns-probe` is created from main `0cb8900`, as the task asked, and changes the shared poll on main. The stage walk on `task/095-network-and-port-markers` (`ee171e1`; IR-546 to IR-552) changes the same file, by 143 insertions and 44 deletions, and it still calls `getent` (its line 55). The two branches cannot both merge without one choice.

**Reason.** Both branches test the same criterion with the same file. The walk reports the stage that stopped it (IR-546), which this branch does not do. The ping stage has to replace the `getent` stage on the walk before that branch's network run can mean anything.

**Consequence.** Decide the base for #095's test before either branch merges. If the walk is the base, port the ping stage and the `NOT_VALIDATED` guard (IR-553, IR-554) onto it. If this branch is the base, the walk's stage records are lost, and IR-546 to IR-552 need a new home.

## IR-558: The image listing in §7.8 comes from a scratch reader, because `Images/tools` has no reader for the files in a filesystem

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 (step 5) |
| Affected documents | [android-image.md](../02-design/android-image.md) §7.8; [images tools](../../Images/tools/apkrun_image/) |

**Choice.** The partition listing in §7.8 was read with a scratch EROFS directory walker in `/tmp`, not committed. The walker used the `liblp` reader in `Images/tools` (`lp.py`, `read_dynamic_partitions` on the sparse `super.img`) to extract `system_a`. `Images/tools` detects the filesystem type inside a logical partition (`inventory.py`, `_parse_filesystem_at`), but it has no reader for the files inside that filesystem.

**Reason.** The task asks to check which commands exist on the image by reading its files. The repository has no way to list them, so the listing cannot be rerun from a checkout.

**Consequence.** §7.8 records the result, not a command that reproduces it. Decision needed: whether to add a read-only listing command to `Images/tools` (EROFS now, ext4 for the other images), so that the listing is part of the image inventory. Until then, the scratch walker stays outside the repository.

## IR-559: The commit scope table has no `plan` scope, but main uses `docs(plan)` and `docs(<area>)` for documentation commits

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #095 |
| Affected documents | [workflow.md](../05-development/workflow.md) §4.2 (scope table); [AGENTS.md](../../AGENTS.md) §13 |

**Choice.** The documentation commits of this branch follow main: `docs(plan)` for the plan files and `docs(android)` for the Android image design. Neither scope is in the table in workflow §4.2, where `docs` covers `docs/`. This entry does not change the table.

**Reason.** AGENTS.md §13 says a commit scope is one of the scopes in workflow §4.2. Main's history uses `docs(plan)` and `docs(<area>)` for documentation commits, for example `289e997` and `08fbd0f`. A reviewer applying the table literally would reject these commits, and applying main's practice breaks the table as written.

**Consequence.** Decision needed: add `plan` to the table and state that `docs(<area>)` names the design area that a document describes, or use `docs` for these commits. Until then the commits follow main's practice and do not match the table as written.

## IR-580: Remove the drmVirgl refusal before the drmVirgl boot is verified on the VM

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [graphics.md](../02-design/graphics.md) §8, §9, §12 (#022), §16; [M02](issues/M02-graphics.md) #022; supersedes the order of [IR-462](#ir-462-the-planner-still-refuses-drmvirgl-until-its-boot-is-verified) and the drmVirgl part of [IR-380](#ir-380-refuse-a-gpu-profile-that-the-device-does-not-offer) |

**Choice.** RuntimeCore attaches the VirGL device (`VirtioGPUDevice.virgl()`) for `drmVirgl` now. The removal does not wait for the verified boot. The `drmVirgl` criteria of #022 (step 4 and criteria 1 to 4) stay open until the VM check runs, and no document marks them as met.

**Reason.** The task asked for the host side of the profile to be enabled without a VM run, because the G2 gate holds the VM lock in the main checkout. IR-462 tied the removal to a verified boot. This entry supersedes that order, because the host side can now be tested at T0 and T1: the device list, the bootconfig against §9, and the real renderer start. The cost is that a `drmVirgl` boot that the VM check later rejects can now reach the VM. Before this change the host refused it, and the failure would have surfaced only in the guest, as a stall. The boot timeouts and stall limits of the supervisor (runtime-daemon.md §3.2) still bound such a boot.

**Consequence.** `apkrun dev boot --gpu virgl`, and the default profile of `BootOptions` (drmVirgl, android-image.md §9.1), now start a VM with `VIRTIO_GPU_F_VIRGL` and a VirGL renderer that no VM check has run. Any caller that boots the default profile now reaches that path. The maintainer should confirm that no release path does so before the #022 VM check passes. The default of `apkrun dev boot` stays `none` (IR-584).

## IR-581: A profile that the bundle does not list starts no renderer

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [graphics.md](../02-design/graphics.md) §8, §9; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.7 |

**Choice.** `AndroidGraphicsDevices.devices(for:requiredHostCapabilities:)` checks that the bundle lists the profile before it makes the device. The VirGL device is made by a factory parameter, so a T0 test counts the renderer starts (`drmVirglProfileStartsNoRendererWhenTheBundleDoesNotListIt`). A device that lacks a required feature is still refused, after the device is made, and the refused device is dropped at once.

**Reason.** Making a VirGL device starts a render thread and creates a virglrenderer instance, and one process admits one instance at a time (graphics.md §5.2). A refusal must not hold that resource. Before this change the check came after a cheap EDID-only device was made, so the order did not matter.

**Consequence.** The factory parameter exists for tests. The production overload passes `VirtioGPUDevice.virgl()`.

## IR-582: A renderer failure ends the boot as the transparent `runtime.graphics`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [graphics.md](../02-design/graphics.md) §8, §13.1; [error-catalog.md](../03-reference/error-catalog.md) §7.2 |

**Choice.** `RuntimeBootFailure` gets the case `graphics(GraphicsFailure)`. Its catalog entry `runtime.graphics` is transparent, with `cliExit` `cause`, so the CLI shows the `graphics.*` entry of the cause: `graphics.rendererInitFailed` with stage `virgl`, or `graphics.libraryMissing`.

**Reason.** graphics.md §8 requires an EGL, ANGLE, or virglrenderer failure to be reported as a `GraphicsFailure` before Android boots. Mapping it to `runtime.gpuProfileUnavailable` would say the profile is unsupported, and mapping it to `runtime.androidBootFailed` would blame the guest. The transparent case follows the existing `image`, `vm`, and `guestAgent` cases.

**Consequence.** The remediation shown depends on the cause. A `graphics.rendererInitFailed` gets the Graphics Safe Mode text. A `graphics.libraryMissing` gets "Reinstall APKRun.", and a `graphics.rendererOperationFailed` from the renderer start gets the restart text. The `runtime.graphics` entry itself has no remediation, because it is transparent.

## IR-583: The integration test of the old refusal is removed

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [M02](issues/M02-graphics.md) #021 ("Refusal check") and #022; [graphics.md](../02-design/graphics.md) §12 |

**Choice.** `Tests/IntegrationTests/AndroidGraphicsTests/AndroidGraphicsRefusalTests.swift` is deleted. Its premise, that a `drmVirgl` boot is refused, no longer holds. Its refusal order is covered at T0 through the device factory. Its check that a refusal leaves the home directory unchanged is not replaced at the supervisor level.

**Reason.** The test called `ensureReady` with `drmVirgl` in the AndroidGraphics configuration of the VM suite. With the refusal gone, that call would start a VM. A valid bundle must list `drmVirgl` and `guestSwiftshader` (`RuntimeImageManifestRules`), so an unlisted profile can only come from an invalid bundle. A supervisor-level replacement would need a renderer failure that the test forces, and that test would run in the VM suite, which this task does not run.

**Consequence.** A supervisor-level check that a renderer failure leaves the instance untouched is open. A candidate for the VM suite: set `APKRUN_VIRGL_RUNTIME_PATH` to an empty directory, then expect `runtime.graphics` and no change under the home directory.

## IR-584: `apkrun dev boot --gpu virgl` is offered, and the default stays `none`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [cli.md](../02-design/cli.md) §5; [runtime-api.md](../03-reference/runtime-api.md) §15; [graphics.md](../02-design/graphics.md) §9; [IR-382](#ir-382-offer-only-the-gpu-profiles-of-this-build-in-apkrun-dev-boot---gpu) |

**Choice.** `DevGPUProfile` has the case `virgl`, which maps to `drmVirgl`. The default of `apkrun dev boot` stays `none`, the headless bring-up.

**Reason.** cli.md §5 and runtime-api.md §15 say that `virgl` becomes the default once #022 exists, and IR-382 left that switch to the maintainer. A default change would send every developer boot down the path that the VM has not verified, and it would replace the headless bring-up that the M1 checks use. Keeping `none` until the VM check passes is the rigorous option.

**Consequence.** Developers select `--gpu virgl` on purpose until the maintainer changes the default. cli.md §5 and runtime-api.md §15 now say that the default is `none` until the check passes.

## IR-585: The renderer tests name the built runtime, and run one at a time

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [graphics.md](../02-design/graphics.md) §5.2, §14 |

**Choice.** `AndroidGraphicsDevicesRendererTests` finds `ThirdParty/out/virgl-runtime/current` from its source path, sets `APKRUN_VIRGL_RUNTIME_PATH` to it, and runs as a serialized suite. It is skipped without a Metal device or without the built cache.

**Reason.** Without the variable, both renderer tests failed with `libraryMissing(name: "VirGLRuntime")` in the Swift Testing runner, and with the variable set they pass. The GraphicsCore suites set the same variable for the same reason. One process admits one virglrenderer instance (graphics.md §5.2), so when two renderer tests ran at once, one failed with `rendererInitFailed` (`a virglrenderer instance is already active in this process`).

**Consequence.** The T1 tests live in RuntimeCoreTests, because RuntimeCore has no system-test target, and a new target would change Package.swift and the test plan. The cause of the missing lookup was not traced. The lookup in GraphicsBridge walks up from the executable, which the runner does not place inside the checkout. Whether the CLI executable finds the cache was not checked in this task.

## IR-586: The drmVirgl bootconfig check includes the composer key

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [graphics.md](../02-design/graphics.md) §9 (table); [android-image.md](../02-design/android-image.md) §6.2 |

**Choice.** The T0 test `androidBootPlannerBuildsTheDrmVirglBootOfTheDesign` expects eight drmVirgl keys: the seven of §9 and `androidboot.vendor.apex.com.android.hardware.graphics.composer=com.android.hardware.graphics.composer.ranchu`. §9 now lists the composer key.

**Reason.** android-image.md §6.2 says the layout file is the source of truth, names the composer key as a GPU-profile key, and the committed layout sets it for drmVirgl. A check that left the key out of §9 would disagree with the layout and with §6.2.

**Consequence.** If the maintainer wants the composer key out of drmVirgl, the layout, §9, and this test change together.

## IR-587: The text of `runtime.gpuProfileUnavailable` describes the bundle and device check

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [error-catalog.md](../03-reference/error-catalog.md) §7.2 (generated); `Packages/DiagnosticsCore/ErrorCatalog/errors.json` |

**Choice.** The remediation no longer says that VirGL is unavailable in this version. It now says to start Android in Graphics Safe Mode, and if that does not help, to update APKRun and create a diagnostics report, in English and Japanese. The `when` text describes the bundle and device check. The message is unchanged.

**Reason.** Once drmVirgl is attached, the old remediation is false for the drmVirgl case, and it would tell users to wait for a feature that is present. The Japanese text was written in this task without a native review.

**Consequence.** The Japanese text of the remediation needs a native review before a release.

## IR-588: The superseded entries are annotated, not rewritten

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [IR-380](#ir-380-refuse-a-gpu-profile-that-the-device-does-not-offer), [IR-382](#ir-382-offer-only-the-gpu-profiles-of-this-build-in-apkrun-dev-boot---gpu), [IR-462](#ir-462-the-planner-still-refuses-drmvirgl-until-its-boot-is-verified) |

**Choice.** IR-380, IR-382, and IR-462 keep their Choice and Reason text. Each gets a Status note and a "Superseded" paragraph that names IR-580 or IR-584. The current state is in graphics.md §9 and §16 and in M02 #022.

**Reason.** This file is the decision history, and the history stays. A reader who opens only IR-380 or IR-462 needs a pointer to the change.

**Consequence.** The refusal check of IR-380 stays in the code for a profile that the bundle does not list or whose device cannot satisfy it (IR-581).

## IR-589: A boot that fails releases its renderer through ARC and the stop hook

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [graphics.md](../02-design/graphics.md) §5.2, §8 (`WillStop`) |

**Choice.** `RuntimeSupervisor.boot()` makes no explicit renderer stop when it fails. On a failure before the VM controller exists, the local device is released when `boot()` exits. On a failure after it exists, `fail()` stops the VM, which runs `VirtioGPUDevice.deviceWillStop()`, and then clears `controller`. In both cases `VirGLBackend.deinit` shuts the renderer down when the last reference goes. T1 `aReleasedVirglDeviceLetsTheNextBootStartItsRenderer` checks the release.

**Reason.** The renderer is started before the instance is read, so the failure paths that follow have a live renderer to release. Adding a separate stop call on each path would duplicate the release that ARC already performs, and it would be a second owner of the renderer's lifetime.

**Consequence.** The release depends on no other reference to the device surviving a failed boot. A future path that keeps the device alive would make the next boot fail with "a virglrenderer instance is already active". The T1 test is the guard.

## IR-590: The format check fails on a file that this change does not touch

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 4) |
| Affected documents | [workflow.md](../05-development/workflow.md) §4 (checks); `Tests/IntegrationTests/RunResources/VMRunResourcesTests.swift` |

**Choice.** `scripts/check-format.sh` fails on `Tests/IntegrationTests/RunResources/VMRunResourcesTests.swift` (lines 143, 144, and 181, `LineLength`). The file is the same on main, so the failure predates this branch. It is not fixed here.

**Reason.** The file is outside the #022 scope. Formatting it in this change would mix an unrelated edit into the task.

**Consequence.** The repository-wide format check fails until someone formats that file. The modules check of `scripts/check-module-deps.sh` could not run in this checkout, because the pinned XcodeGen is not installed (`scripts/bootstrap`). Its rules for the new test imports were read, not run.

## IR-600: The G2 stall is most likely a hosted test blocked on a read under `~/Documents`, and the fix stages both inputs outside it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (and #019 for the EDID check) |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §4 (artifact directory); [graphics.md](../02-design/graphics.md) §12; `Tests/IntegrationTests/GuestAgentTests/GuestAgentTests.swift` (the policy comment) |

**Choice.** Treat a read of the checkout under `~/Documents` by the hosted test as the likely cause of the stall, and remove those reads. The producer copies the golden EDID block and the host virgl runtime into the artifact directory (`7e428b7`), and the two tests read them from there (`31cc0ca`). The stall did not reproduce, so the cause is a hypothesis that the next gate run must confirm.

**Reason.** At fa8df7f the EDID test wrote `gpu-driver-trace.json` (28 records) at 22:03:43 JST, the second the guest's VM stopped (22:03:43.437). So `run()` had returned, and the next statement that reads a file is `Data(contentsOf:)` on the golden block under `~/Documents`. Nothing failed before the timeout. The Virgl test never logged a VM start. In a debug build the runtime lookup of `GraphicsBridge.m` walks up from the test host to the checkout, and the gate's DerivedData sits inside the checkout (`build/gates/G2/DerivedData`). The test host executable there is eleven levels below the repository, inside the walk-up's limit of 12 levels. `GuestAgentTests.swift` records that the test process cannot read the checkout's `Documents` folder. Four VM runs on fa8df7f did not reproduce the stall: runs 1, 2, and 4 passed, and run 3 failed fast because its DerivedData was outside the checkout, so the runtime was not found. Runs 5 and 6 passed on the fix. The prompt was not observed.

**Consequence.** The next G2 run decides it. If either test still stalls, the next suspect is the DerivedData location (IR-603).

## IR-601: No commit in `4961787..fa8df7f` is a deterministic culprit; no bisect was run, and d312886 is the candidate for the Virgl stall

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 |
| Affected documents | [graphics.md](../02-design/graphics.md) §12 |

**Choice.** Record no culprit commit. The commit that first loads the host virgl runtime in the LinuxGuest stage is `d312886` (`test(tests): run kmscube through virgl on the Linux test guest`), which adds `VirglTests.swift`. That is the candidate for the Virgl stall. The EDID stall has no commit in the range: `GPUDeviceTests.swift`, `Tests/Fixtures/graphics/edid/`, `GraphicsBridge.m`, and `scripts/run-gate.sh` are unchanged between `4961787` and `fa8df7f`.

**Reason.** A bisect needs a symptom that reproduces on a known-good commit. Neither hung test reproduced on `fa8df7f` in four VM runs, and the budget was eight runs for the whole task. Running `4961787` would have cost at least one more run and would show a pass unless the gate's process history or macOS consent differs, which no commit in the range changes.

**Consequence.** If the stall returns after `7e428b7` and `31cc0ca`, bisect with the gate's own LinuxGuest stage, not a single test, because the stall depends on the process history of that stage.

## IR-602: The debug runtime lookup walks up from the test host to the checkout, so a DerivedData inside the checkout loads the runtime from `~/Documents`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §4; `Packages/GraphicsCore/Sources/GraphicsBridge/GraphicsBridge.m` (`gb_debug_repository_runtime`) |

**Choice.** Keep the lookup for development builds. The hosted tests bypass it with `APKRUN_VIRGL_RUNTIME_PATH` (`31cc0ca`). Decision needed: whether the lookup should stop at the DerivedData boundary, or be removed in favour of an explicit path.

**Reason.** The lookup finds the runtime for development app builds without an extra variable. Changing it changes the development app's path, which this branch does not need.

**Consequence.** Until decided, any debug host whose DerivedData sits under `~/Documents` reads its runtime from there.

## IR-603: The gate's DerivedData sits inside the checkout under `~/Documents`

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 |
| Affected documents | `scripts/run-gate.sh` (`gate_dir`, `-derivedDataPath`); [environment-setup.md](../05-development/environment-setup.md) §4 |

**Choice.** Keep `build/gates/<gate>/DerivedData` inside the checkout for this branch. Decision needed: move the gate's DerivedData, and so the test host bundle, to a path outside `~/Documents`, such as the artifact directory.

**Reason.** The test host's own bundle loads from `~/Documents` in the gate, and the other LinuxGuest tests ran in the same stage after the stall, so the process can load its own bundle. Moving the DerivedData changes the gate's evidence layout and `verify-test-host-directory.sh`, which is a process change.

**Consequence.** If the gate stalls again after `7e428b7` and `31cc0ca`, this is the next change to make.

## IR-604: The virgl runtime that `current` names was built in an earlier environment, and this environment has no build of it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 |
| Affected documents | [build-system.md](../05-development/build-system.md) (third-party cache); [environment-setup.md](../05-development/environment-setup.md) §4 |

**Choice.** Do not rebuild the runtime on this branch. Decision needed: run `scripts/build-third-party.sh virgl-runtime` in the main checkout, and record the result as a gate input.

**Reason.** `build-third-party.sh --print-cache-key virgl-runtime` gives `154fc…-de6cd9de…` in both the main checkout and the worktree, but `ThirdParty/out/virgl-runtime/current` names `154fc…-4808…`, built on 2026-10-08. The current key has no build, so a build compiles the runtime's sources. A build started in the worktree and was stopped, because the compile is long and changes the runtime under test.

**Consequence.** The tests use the 2026-10-08 runtime. The stage passes with it (runs 4 and 6). A fresh checkout must build `current` before the producer runs, because the stager stops until it exists. A rebuild can change renderer behaviour (IR-605), so it needs its own gate run.

## IR-605: The virgl test passes while the renderer rejects 61 operations, and the test does not check the rejects

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 (step 2, [graphics.md](../02-design/graphics.md) §12) |
| Affected documents | [graphics.md](../02-design/graphics.md) §12; `Tests/IntegrationTests/LinuxGuestTests/VirglTests.swift` |

**Choice.** Record it for review. This branch does not change the renderer or the test's assertions. Decision needed: after the rejected operations are identified, whether the test should also assert that the renderer failure count is zero.

**Reason.** Runs 4 and 6 each log 61 `graphics renderer operation failed` messages, and the device logs each one again. In run 6 they fall within 130 ms before the renderer is destroyed, at the guest's shutdown. The log does not name the operations. The host readback count is zero, and the test passes.

**Consequence.** The pass does not show that the rejected operations are harmless.

## IR-606: A worktree needs a real `ThirdParty/out` and a copy of the pinned XcodeGen; a symlink into the main checkout writes into it

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #022 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) (worktrees); `scripts/tools/build_third_party.py` (cache root check) |

**Choice.** A worktree that runs the producer or a VM test gets its own `ThirdParty/out` directory, with the cached subtree copied in, and its own `build/tools/xcodegen-*`. Decision needed: write this in the environment setup, or have the worktree setup create it.

**Reason.** `build_third_party.py` refuses a symlink at the cache root, and `scripts/check-lock.sh` needs the pinned XcodeGen under `build/tools`. The worktree `hang` had `ThirdParty/out` linked to the main checkout, so a copy into it wrote into the main checkout's runtime directory. One nested copy was removed, and the main checkout's `git status` is clean. A `build_third_party.py build virgl-runtime` started through that link also survived the kill of its wrapper and held `.artifacts.lock` for four minutes, until it was killed.

**Consequence.** Worktree setup needs an explicit step, or the producer's lock can be held by a process the wrapper no longer tracks.

## IR-620: The Mesa output of the feasibility run is not on this machine, so the injection uses a rebuild

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [ADR-0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) (Verification); [M02](issues/M02-graphics.md) #099 (Notes) |

**Choice.** The injection takes the output of `scripts/guest/build-mesa-android.sh` as its input. The output of the earlier build was written outside the repository (IR-495), and it is not on this machine. The build was run again with `--out /tmp/apkrun-099-inject-mesa/out --work /tmp/apkrun-099-inject-mesa/work`, and `scripts/tests/test_guest_mesa_build.py --out` checked the result (28 tests). Decision needed: where the verified output of the image build is kept.

**Reason.** The SHA-256 values of the four libraries equal ADR-0018's: `libEGL_mesa.so` `73cb1755…`, `libGLESv2_mesa.so` `7da942f6…`, `libGLESv1_CM_mesa.so` `2a082937…`, and `libgallium_dri.so` `a261e62b…`. The build needs no VM, and it fetches its sources by commit.

**Consequence.** The input of this step is a rebuild made on 2026-10-11, and its hashes are the ones that the ADR records. ADR-0018 is unchanged.

## IR-621: erofs-utils comes from the Homebrew bottle of the receipt, relocated, not from a source build

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [ThirdParty.lock.json](../../ThirdParty/ThirdParty.lock.json) (`erofs-utils`); [build-system.md](../05-development/build-system.md) §6.6 |

**Choice.** The lock pins the erofs-utils 1.9.4 bottle for `arm64_golden_gate` (SHA-256 `52f58391…`). It is the bottle that the feasibility receipt used. Its binaries name Homebrew's lz4 and xz with the placeholder `@@HOMEBREW_PREFIX@@`, so the lock records two `install_name_tool -change` pairs, and the SHA-256 of each binary after the change and the ad-hoc signature (`mkfs.erofs` `645d8d55…`, `fsck.erofs` `d0fa5337…`, `dump.erofs` `850ddb32…`). `python3 -m apkrun_image erofs-tools --out DIR` fetches, relocates, and checks them. `inject-vendor` checks them before its first tool run. The helpers do not check again on each call. Decision needed: whether to build erofs-utils from a pinned source tarball instead.

**Reason.** A source build needs autotools and a tarball that the lock does not pin. The bottle is the byte set that the receipt already names, so the record and the tool agree.

**Consequence.** At run time the binaries load Homebrew's lz4 1.10.0 and xz 5.8 from `/opt/homebrew`. Those libraries are not pinned. A Homebrew upgrade changes them without changing any pinned hash, and the tool checks the binaries, not those libraries.

## IR-622: The Mesa libraries go to `/vendor/lib64/egl`, not to the `lib64` root that the Meson install uses

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline; closes the placement that IR-489 left open) |
| Affected documents | [ADR-0018](../01-architecture/decisions/0018-guest-mesa-ndk-build.md) §9; [android-image.md](../02-design/android-image.md) §1.2; [graphics.md](../02-design/graphics.md) §5.3 |

**Choice.** The four libraries go to `/vendor/lib64/egl/` in the partition. The Meson install writes them to `vendor/lib64/`, and the tool moves them. Decision needed: confirm this placement. The VM check is the first evidence that the EGL namespace finds `libgallium_dri.so` in that directory.

**Reason.** (1) ADR-0018 §9 names `vendor/lib64/egl/` for the EGL and GLES libraries, and the build sets `-Ddri-drivers-path=/vendor/lib64/egl`, so the build itself names that directory for the gallium driver. (2) The platform contexts of build 16373615 have the line `/(vendor|system/vendor)/lib(64)?/egl(/.*)?`, which labels all four files `same_process_hal_file` (IR-623). The `lib64` root would give `libgallium_dri.so` the generic `vendor_file`, because no line names it. (3) The stock `libEGL_emulation.so` in `lib64/egl` depends on libraries in the `lib64` root. That shows that `lib64` is searched, and the image does not show whether `lib64/egl` is.

**Consequence.** If the VM check finds that `lib64/egl` is not searched for `DT_NEEDED`, the fallback is `lib64/libgallium_dri.so`. That needs its own label, which means a line in `vendor_file_contexts`, a change to another file of the partition. That is a second decision.

## IR-623: The label rule is the longest literal stem, with ties to the later rule, over the platform and then the vendor contexts

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [android-image.md](../02-design/android-image.md) §1.2; [selinux_labels.py](../../Images/tools/apkrun_image/selinux_labels.py) |

**Choice.** The labels of the added files use this rule: the platform contexts (`plat_file_contexts`, from `system_a`) load first, then the vendor's (`vendor_file_contexts`). For a path, the rule with the longest literal prefix wins, and a tie goes to the later rule. The tool refuses a file for which the last matching rule gives a different label. The rule was measured against the stock labels, not read from libselinux.

**Reason.** The rule gives the stock label of all 522 entries of the stock vendor partition, and the last-match rule also gives all 522. Both rules agree on the four added files (`same_process_hal_file`). Measuring the rule on real data was the check that was possible without a device.

**Consequence.** The rule is a model that fits build 16373615. The VM check confirms the labels of the added files with `ls -Z`.

## IR-624: The verity tree and footer are made without FEC, because no `fec` tool is pinned

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [android-image.md](../02-design/android-image.md) §4 (partitions); [build-system.md](../05-development/build-system.md) §6 |

**Choice.** The output's hashtree and footer come from the vendored avbtool (`add_hashtree_footer --do_not_generate_fec`, algorithm NONE, the stock salt). avbtool reproduces the stock root digest `d8895f6a…` from the stock bytes with the same salt, and `verify_image` checks the new partition. Decision needed: pin a `fec` tool (libfec) and generate FEC, or accept a partition without FEC data.

**Reason.** avbtool calls an external `fec` binary for FEC. None is installed or pinned here. The root digest does not depend on FEC.

**Consequence.** The footer has no FEC section, and the guest cannot repair blocks with FEC. When `vbmeta` is signed again (IR-625), the top-level descriptor of `vendor` must describe the same partition. The stock descriptor's FEC fields are not checked by this task.

## IR-625: The top-level vbmeta is not signed again, so the output does not verify until the signing key is used

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline; blocks step 4) |
| Affected documents | [android-image.md](../02-design/android-image.md) §11.4 (variants and verified boot); [graphics.md](../02-design/graphics.md) §9 |

**Choice.** The tool writes the partition and records that it does not match the top-level vbmeta (`vbmeta.matchesOutput: false`). It does not sign. The stock vbmeta is SHA256_RSA4096 with the key `2597c218…` (sha1), and its vendor descriptor holds the stock root digest `d8895f6a…`. The output's digest is `a373fc52…`. Decision needed, one of: (a) the maintainer signs the new vbmeta with the key of the stock build; (b) APKRun gets its own key, and the guest trusts it, which changes the trust chain; (c) the development boot turns verification off for `vendor`, which conflicts with §11.4.

**Reason.** The private key is not in this repository, and AGENTS §9 forbids creating or guessing a key. Option (c) would also weaken the design that §11.4 fixes.

**Consequence.** The partition cannot pass verification with verity on until one of (a), (b), or (c) is chosen. The VM check of the Mesa image depends on that choice.

## IR-626: The partition keeps the size of its super extent, and `super.img` is not rewritten

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [android-image.md](../02-design/android-image.md) §4.2, §4.5 (disk plan and assembly) |

**Choice.** The output is 291,229,696 bytes, which is the size of `vendor_a`'s single linear extent in super. The rebuilt EROFS uses 45,404 of the 71,101 blocks, so no extent grows. The tool does not write `super.img`, and it does not make a manifest or an identity for the corrected image. Decision needed: when the super is rewritten (this needs an LP metadata writer, and `lp.py` only reads), and whether criterion 1 of #099 waits for that.

**Reason.** The task says not to rebuild other partitions. Writing the super needs a writer that the tree does not have.

**Consequence.** The next step writes this file into the super's extent. The metadata does not change size.

## IR-627: The rebuild is checked by logical equality, not by the bytes of the stock image

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [android-image.md](../02-design/android-image.md) §3, §4 |

**Choice.** A plain rebuild of the stock tree and the injected rebuild are compared entry by entry: kind, mode, owner, group, timestamp, target, content, and label. Directory sizes are compared in the plain rebuild only. The EROFS bytes are not compared. The rebuild uses `lz4hc,9` and 4 KiB blocks. The stock image has 69,747 blocks, where the same content takes 43,956 blocks in the rebuild. Decision needed: whether to match the stock image's mkfs options.

**Reason.** The mkfs options of the stock image are not in its archive or its manifest. A guessed set would not give the stock bytes either.

**Consequence.** Every other file is unchanged in every property that the check reads. Their on-disk compression and layout differ from the stock image.

## IR-628: The owners, modes, timestamps, and labels come from the EROFS image, not from the host

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [android-image.md](../02-design/android-image.md) §3.1 (inventory and content rules) |

**Choice.** Each entry's owner, group, mode, and timestamp come from `dump.erofs --path`. The host copy keeps only the content and the link target. A rebuild writes a PAX tar that carries the labels as `SCHILY.xattr.security.selinux`. The export stops at any host xattr other than `security.selinux`, except `com.apple.provenance`, which macOS adds to extracted files.

**Reason.** A host that is not root cannot restore the stock owners (uid 0, gid 0 or 2000). The stock image uses no xattr other than `security.selinux`: all 522 entries carry it (the root included), and no other name was found.

**Consequence.** The tool needs `dump.erofs` for metadata and the xattr tool of the host (`/usr/bin/xattr` on macOS) for labels.

## IR-629: A file that the rebuild adds is never written without a label

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [android-image.md](../02-design/android-image.md) §1.2 |

**Choice.** The task asked for labels "if the image's file_contexts can be read". The tool fails closed instead: it stops when the contexts cannot be read, or when they do not reproduce the stock labels. It does not write an unlabelled file. Decision needed: none; recorded because the wording of the task allows the other reading.

**Reason.** An unlabelled library fails at run time, with a denial that the image build does not show.

**Consequence.** An image without its file contexts produces no output.

## IR-630: Six tests need the erofs-utils tools and skip without `APKRUN_EROFS_UTILS`, and CI does not fetch them

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [test-strategy.md](../04-plan/test-strategy.md) (T0); [build-system.md](../05-development/build-system.md) §15.1 (`test-images`) |

**Choice.** Six tests skip with a stated reason when `APKRUN_EROFS_UTILS` is unset: two in `test_erofs.py` and four in `test_vendor_inject.py`. This task did not change the `test-images` job. Decision needed: add `erofs-tools` and a cache to that job, or keep the skip.

**Reason.** The job's runners have no erofs-utils, and a fetch needs the network. A failure would block every image test.

**Consequence.** CI runs the other tests. On a developer Mac with the variable set, all of them run and pass.

## IR-631: The image tools' virtualenv installs the main checkout, so a worktree's tests import the wrong package unless `PYTHONPATH` is set

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline); the same class of problem as IR-606 |
| Affected documents | [environment-setup.md](../05-development/environment-setup.md) §2.4 (Python 3.12) |

**Choice.** This task runs the image tests with `PYTHONPATH=<worktree>/Images/tools`. The first baseline run, without it, had six failures in `test_bundle.py`. They came from the main checkout's package, which rejected the worktree's build directory as outside its repository. With `PYTHONPATH` set, the same ten tests pass. Decision needed: worktree setup should create a virtualenv for its own `Images/tools`.

**Reason.** `Images/tools/.venv` in a worktree is a symlink to the main checkout's virtualenv, and that is an editable install of the main checkout's package.

**Consequence.** Any worktree run without `PYTHONPATH` tests the wrong code, and it can report failures that are not in the code.

## IR-632: The injection checks the `mesa` lock entry, not the whole-lock hash in the Mesa manifest

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [build-system.md](../05-development/build-system.md) §6.6; `scripts/guest/mesa_android.py` (manifest `lock.sha256`) |

**Choice.** `load_mesa_output` compares the commit, the version, and the Meson flags of the Mesa manifest with the `mesa` entry of the current lock. It does not compare the whole-file hash `lock.sha256` that the manifest records. Adding erofs-utils (commit `1dcde80`) changed that hash without changing any Mesa pin. Decision needed: whether the Mesa manifest should hash only the pins of its group.

**Reason.** The whole-file hash makes every unrelated lock edit stale an output that is still correct.

**Consequence.** The check depends on the content of the `mesa` entry. The file hashes of the four libraries are still checked against the manifest and the bytes.

## IR-633: The injection lives in `Images/tools`, and its output must be outside the repository

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline; the M02 entry names `Images/tools/`) |
| Affected documents | [M02](issues/M02-graphics.md) #099 (Modules / paths); [AGENTS.md](../../AGENTS.md) §6.3 |

**Choice.** `vendor_inject.py` and its helpers are in `Images/tools/apkrun_image/`, because they handle an image and go through the manifest (AGENTS §6.3). The Mesa build stays in `scripts/guest/` (IR-497). The `--out` and `--work` directories must resolve outside the repository, and they must be new or empty, so a 290 MB partition cannot land in the checkout.

**Reason.** AGENTS §6.3 puts image handling in the image tools. The guard is a cheap check against a large file in the tree.

**Consequence.** A caller who wants the output in the repository's git-ignored `Images/work` must choose a path that the guard accepts, or the guard must change by a decision.

## IR-634: The contexts files are read from their fixed paths inside the partitions, which the manifest does not index

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #099 (step 2, offline) |
| Affected documents | [AGENTS.md](../../AGENTS.md) §6.3 (image file names); [android-image.md](../02-design/android-image.md) §3.1 (inventory) |

**Choice.** The tool reads `/system/etc/selinux/plat_file_contexts` from `system_a` and `/etc/selinux/vendor_file_contexts` from the vendor partition, at those fixed AOSP paths. The manifest records artifacts, not the files inside a partition. Decision needed: index the files of each partition through the manifest (a larger change to the inventory), or keep these two fixed paths and name them in the image design.

**Reason.** AGENTS §6.3 forbids assuming file names inside an artifact, and these paths are names inside a partition. The tool cannot label a file without the rules, and the manifest has no entry for them. The tool guards the paths: it refuses an image whose contexts do not reproduce the stock labels (IR-623), and it records their SHA-256 in the output.

**Consequence.** A different AOSP layout (for example a moved contexts file) makes the tool stop with a missing-file error, and it writes no output.
