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

The raw Apport report and embedded core remain on the Lima reference host
because the core may contain guest memory. The temporary GDB extraction was
deleted, and no raw core or report was copied into the repository. After
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
capture, GDB placed the SIGSEGV at `unw_get_reg+68` in
`libgfxstream_backend.so`; `x8` was zero at `ldr x8, [x8, #16]`. The frames
above it included gfxstream's `_Unwind_GetIP` and libgcc's
`_Unwind_Backtrace`. The stripped crosvm callers are recorded as offsets in
`crosvm-crash-summary.txt` with Build ID
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
it to PID 1573779. IR-170 already records why Apport produced no report for the
retry: the first report still existed and had not been seen. Exact executable
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

**Verification.** The raw Apport reports and core files remain private on
Lima; only normalized logs and sanitized summaries are in the repository.
On the running Lima VM, `dpkg -L cuttlefish-base` lists
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
field. The current Lima `.crash` inventory and Apport log also contain no
crosvm report or entry, so the path for PID 1573779 remains unconfirmed.
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

**Reason.** The plan orders Linux boot and serial console work before Android, so the M0 console targets the test guest without skipping the later #014 integration. A readiness marker on hvc0 provides an explicit ordering point for each service port. Disk I/O remains isolated from the pipe reader by a bounded stream, and loss counters prevent identical truncation in two files from looking like a complete capture. Hostile review found that a barrier could overtake a pending read-source callback; every barrier now inserts its bounded drain and marker in one read-queue turn. A second finding showed that unbounded draining could starve failure under continuous output, so one snapshot is capped at 4 MiB and 50 ms. The consumer-drain gate retains waiters only for their own acknowledged barrier; for `preserveNewest`, it counts the displaced guest chunk when the marker replaces it. The log stream's reserved control slot keeps the marker available while data slots are full, and the writer acknowledges each data slot after persistence and loss accounting. A separate review found that synchronous host input could prevent Ctrl-] from being processed; input now goes through a bounded serial writer and stop cancels pending chunks. The detach request is latched at publication time so an already-buffered Ctrl-] still wins over a racing writer error. Cancellation cannot interrupt a synchronous `FileHandle.write`, so the raw terminal output path uses nonblocking `write` plus bounded `poll`; cancellation is checked after each 50 ms wait and unsent bytes are counted. The CLI restores output flags and terminal settings only after stopping and joining terminal writes, while keeping the raw subscriber alive until a bounded read-queue barrier is acknowledged. Each stream chunk is counted as pending before `yield`, so a waiting consumer cannot acknowledge it before the counter changes; displaced and rejected chunks are removed from pending as they are counted as dropped. The final dropped-plus-pending snapshot uses the counter's single lock. The real-pipe test joins bytes from any number of reads instead of assuming pipe reads match host writes. A further review found that the two-second parser deadline cancelled `recordTask` only after leaving a structured task group whose child awaited that task, so the scope could wait past the deadline. Cancellation now happens before the task group joins its children, and a T0 regression test verifies that an open `AsyncStream` consumer is cancelled and joined. A cleanup failure therefore restores the terminal promptly, still accounts output during the final drain, and reports the combined stream and writer loss after the consumer joins. If both stop and reset fail, the instance lock remains held while VM/log resources remain active. Reset runs once in the shared error cleanup path. Revalidating the VM transition after the await prevents a late stop event or duplicate failure callback from replacing the settled state. The attached crosvm analysis is consistent with the evidence already recorded in IR-171 and IR-187: the installed package Build IDs, exported/imported unwinder symbols, loader binding comparison, and diagnostic preload capture have been checked, and the preload recovered the `invalid rutabaga build parameters` panic. Matching debug symbols are not needed to identify that demonstrated panic. The earlier SIGSEGV may still have been a secondary fault during backtrace collection; the null-vtable explanation remains a hypothesis, and the later recovered panic does not establish the earlier PID's exact executable path or root cause. The raw Apport reports and core remain private on the Lima host. This Linux-guest console work does not change that Cuttlefish diagnosis or claim that Virgl/gfxstream caused the secondary signal.

**Loss-reporting review.** Output cancellation runs through a separate callback before serialized event delivery, so a console write waiting on terminal capacity cannot block cleanup from restoring the terminal. The cleanup-pending message is deferred until after the raw stream consumer acknowledges its bounded drain barrier and is joined; this prevents a blocked stderr write from holding the event-sink lock needed by that consumer. The consumer stays active through its barrier, then is joined before loss is reported. The failure-drain budget is intentionally fixed at 4 MiB or 50 ms, checked between pipe reads; output still in the guest pipe beyond that cutoff is not included, so the cataloged count says “at least.” The instance lock remains held while VM or log cleanup continues after the warning.

**Verification.** The final `swift test -j 2` suite passed after the timeout-ordering, read-deadline, and cleanup-message-order fixes, including 78 `VirtualMachineCoreTests`, 12 `VirtualMachineCoreSystemTests`, four `RuntimeHostTests`, and the new `RuntimeCore` console-task timeout regression. The continuous-output drain test passed in 25 ms; the open-stream task cancellation test passed at its 10 ms deadline. `swift build --traits EmbeddedRuntime` passed. The non-TTY CLI check returned the expected exit 64 and cataloged terminal remediation. `xcodebuild -quiet build-for-testing` passed for the IntegrationTests scheme with code signing disabled. `scripts/ci/run-checks.sh` passed all six checks: test fixtures, module dependencies, logging, TODOs, formatting, and lock validation; both error-catalog generator checks and `sh -n Tests/Fixtures/linux/init` also passed. Hostile review found stderr backpressure could hold the event-sink lock before drain acknowledgment; the warning now follows raw consumer drain and join. The reviewer confirmed no remaining actionable P1/P2 findings in cleanup ordering, bounded loss reporting, or parser cancellation. Signed T2 guest execution and the `kill -9` manual check are not complete: this shell does not have `APKRUN_TEST_DEVELOPMENT_TEAM` or `APKRUN_TEST_CODE_SIGN_IDENTITY`. The three-port result remains pending, so #004 is not complete.

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

**Reason.** Accepting `e2fsck` exit 0 or 1 alone can pass on an already-clean filesystem, so it does not prove journal recovery occurred. Signaling only after a successful write and rename proves the stress workload began before the host's delay. The long commit interval is intended to suppress periodic journal commits during the short forced-stop window, and the recovery marker is the required evidence that journal replay happened. The virtual-machine run remains required to validate this behavior on the lab Mac.

**Verification.** Guest shell syntax and the host-side fixture checks pass. Hostile review caught that the original readiness marker preceded the first write; it now follows the first successful write and rename, and the final re-review found no remaining actionable issues. Signed T2 execution has not run, so journal replay remains unverified until the `recover` marker is observed on the guest.

## IR-197: Create block fixtures only in a fresh directory

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #005 |
| Affected files | `Tests/Fixtures/linux/make-test-disks.sh`; `scripts/tests/test_make_test_disks.sh`; `Tests/IntegrationTests/LinuxGuestTests/BlockTests.swift` |

**Choice.** The disk generator creates the requested output directory with mode 0700 and fails if that directory already exists.

**Reason.** The previous `mkdir -p` accepted an existing directory, after which opening `ro.img` for writing followed a pre-existing symlink and could truncate a file outside the fixture directory. Atomic creation of the final directory rejects that case before either image is opened.

**Verification.** The fixture test checks deterministic image sizes and hash output, and verifies that the generator refuses a directory containing a symlink without modifying its target.

## IR-198: Keep guest-visible block order unverified until T2

| Field | Value |
|---|---|
| Status | Needs maintainer review |
| Task | #005 |
| Affected documents | [vm.md](../02-design/vm.md) §§5, 17; [M00](issues/M00-repository-and-vm-foundation.md) #005 |

**Choice.** Describe attachment-array order as the #005 test expectation, while marking the corresponding guest-visible `/sys/block/vdX/serial` order unverified until the signed T2 test records it.

**Reason.** T0 proves the order in the built `VZVirtualMachineConfiguration.storageDevices` array, but that does not prove the guest's device enumeration. The current environment lacks the local signing settings needed to run the virtualization test. No product code relies on `vdX` letters or PCI slot numbers.

**Verification.** T0 configuration inspection passes. The order and reversed-order guest checks are implemented but have not run against the Linux VM; do not record a device-order result yet.
