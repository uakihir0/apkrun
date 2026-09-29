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
