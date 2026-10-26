# Workflow

How work moves from a GitHub issue to `main`: task states, labels, branches, commits, review, merges, versions, releases, parallel work, and experiments. The steps one agent follows for one task are in [../../AGENTS.md](../../AGENTS.md) §2.

---

## 1. Roles

| Role | Who | May |
|---|---|---|
| Contributor | a person or an AI agent | work on tasks, commit, open issues and pull requests |
| Maintainer | the repository owner | everything, plus decide open questions, approve pull requests and CI-policy changes, approve release jobs |

- An AI agent never approves a pull request or a release job, and never applies the `ci-policy-approved` label.
- An AI agent that cannot decide something stops and asks ([../../AGENTS.md](../../AGENTS.md) §2.1).

---

## 2. Tasks

### 2.1 Picking a task

Run `scripts/dev/next-task.py`. It reads the task index ([../04-plan/issues/README.md](../04-plan/issues/README.md) §3, in working order) and the GitHub issue states, and prints:

1. tasks labeled `needs-verification`, which need a run on a real Mac;
2. open tasks whose dependencies are met, in working order.

Take the first task you can do. A task that needs a real Mac, a VM, or a person for its main work is not for an agent without one.

### 2.2 States

The GitHub issue is the only place that records state.

| State | On GitHub | Meaning |
|---|---|---|
| open | open issue | not done |
| in progress | open, assigned | someone works on it; do not take it |
| needs verification | open, label `needs-verification` | the code is on `main`; T2, T3, or gate runs on a real Mac are left. A comment lists them |
| blocked | open, label `blocked` | waits for a decision or another issue; a comment names it |
| done | closed | every `Done when` item holds and the listed tests passed |

A dependency is met when its issue is closed or labeled `needs-verification`. A version is complete only when its tasks are closed ([../04-plan/roadmap.md](../04-plan/roadmap.md) §3).

When a task closes, shorten its entry to the closed format ([../04-plan/issues/README.md](../04-plan/issues/README.md) §2.2) in the same commit as the last change, or right after.

### 2.3 Claiming

- Assign the issue to yourself before you start: `gh issue edit <N> --add-assignee @me`.
- Never work on an issue someone else is assigned to. Ask in the issue.
- When you stop before the task is done, comment the state, the next step, and open questions, then unassign.

### 2.4 New tasks and numbers

- A task's number is its GitHub issue number. GitHub assigns it, so two agents never take the same number.
- To add a task: `gh issue create --label task --title "<Title>" --body "Entry follows."`, then add the entry `## #<N> <Title>` to its milestone file and the row to [../04-plan/issues/README.md](../04-plan/issues/README.md) §3 in one commit, then run `scripts/dev/sync-task-issues.py --apply <N>` to write the issue body.
- The milestone files are the source of truth for task text. The issue body is generated from the entry. When they disagree, fix the file and sync again.

### 2.5 When the task is wrong

- If a step is wrong or impossible, change the design document and the task entry in the same commit, and say why in the commit message.
- If the change is architectural, the ADR comes first and is accepted before code depends on it.
- If finishing the task needs work outside its scope, file a follow-up task (§2.4). Do not widen the task.

---

## 3. Issues and labels

### 3.1 Kinds of issues

| Kind | Title | Label |
|---|---|---|
| Task | the task title, without a number | `task` |
| Bug | what goes wrong | `bug` |
| App compatibility report | app name and what goes wrong | `compatibility` (from #91) |
| Release | `Release <version>` or `Android <YYYY.MM.N>` | `release`, `image-release` (from #58, #88) |

Security vulnerabilities are never reported in a public issue (§3.5).

### 3.2 Bug report template

#61 adds `.github/ISSUE_TEMPLATE/bug-report.md` with: what happened, what was expected, steps, the summary from **Copy Summary** or `apkrun diagnostics`, `apkrun version`, Mac model and macOS version, the package ID if one app is involved, and an optional diagnostics bundle that the user attaches. APKRun uploads nothing ([../02-design/diagnostics.md](../02-design/diagnostics.md) §8).

### 3.3 App compatibility template

#91 adds `.github/ISSUE_TEMPLATE/app-compatibility.md`. Its fields map to a compatibility database entry ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10). A report becomes an entry only after a maintainer reproduces it.

### 3.4 Labels

| Label | Meaning | Set by |
|---|---|---|
| `task` | a task with an entry in a milestone file | whoever opens the issue |
| `needs-verification` | code on `main`, real-Mac verification left (§2.2) | the implementer |
| `blocked` | waits for a decision or another issue | anyone, with a comment |
| `bug` | a confirmed defect | anyone |
| `security` | a security finding filed as a task (#92) | maintainer |
| `ci-policy-approved` | a person approved a CI control change in a pull request (§7.3) | maintainer only |

Tasks that add a workflow add its labels here (for example `release-blocker`, `nightly-failure`).

### 3.5 Security vulnerabilities

The repository has GitHub private vulnerability reporting turned on. The fix is made in a private advisory fork and ships as a critical release (§9.6). The advisory is published after the release reaches stable.

---

## 4. Branches and commits

### 4.1 Branches

- Work on `main` when the maintainer says so. Otherwise use a branch and a pull request (§5).
- Branch names: `task/<N>-<short-name>` (for example `task/25-pointer-input`), `fix/<N>-<short-name>` for a bug issue, `docs/<short-name>` for a document change that belongs to no task, `experiment/<name>` for a spike that never merges.

### 4.2 Commit messages

Conventional Commits with a required scope:

```text
<type>(<scope>): <subject>

<body: why the change is needed, and what a reader should know>

Refs: #<N>
```

- The subject is imperative, lowercase after the colon, at most 72 characters, no period.
- `Refs: #<N>` names the GitHub issue of the task or bug.
- A change that raises a RuntimeAPI major or a guest protocol major, or makes a persisted format incompatible, has a `BREAKING CHANGE:` footer that names the ADR ([coding-conventions.md](coding-conventions.md) §6).
- Small commits. Each commit builds. Generated files go in the same commit as their source (`*.pb.swift` with the `.proto` file, the error catalog with `errors.json`).
- Never `work`, `changes`, `fix stuff`, or `wip`.

| Type | Use |
|---|---|
| `feat` | new behavior |
| `fix` | a bug fix |
| `perf` | a measured performance change; the body gives the measurement |
| `refactor` | no change in behavior |
| `test` | tests or fixtures only |
| `docs` | documentation only |
| `build` | `Package.swift`, `project.yml`, `ThirdParty/`, `scripts/build/` |
| `ci` | `.github/workflows/`, CI scripts |
| `chore` | anything else users cannot notice |
| `revert` | a revert (§7.5) |

| Scope | Covers |
|---|---|
| `diagnostics` | DiagnosticsCore |
| `virtio` | VirtioDeviceCore |
| `vm` | VirtualMachineCore |
| `graphics` | GraphicsCore, GraphicsBridge, the `virgl-runtime` build |
| `input` | InputCore |
| `windowing` | WindowingCore |
| `protocol` | GuestProtocol, `Guest/protocol` |
| `image` | ImageCore, `Images/tools` |
| `api` | RuntimeAPI |
| `runtime` | RuntimeCore |
| `client` | RuntimeClient |
| `daemon` | RuntimeHost, `Daemon/apkrund` |
| `store` | APKStoreCore, `Guest/APKRunStore` |
| `update` | UpdateCore |
| `wrapper` | WrapperCore, APKRunLauncher |
| `integration` | IntegrationCore |
| `cli` | `CLI/apkrun` |
| `app` | `Apps/APKRun` |
| `menubar` | APKRunMenuBar |
| `guest` | `Guest/guestd`, `Guest/agentruntime` |
| `vsockd` | `Guest/vsockd` |
| `android` | `Guest/product` and the AOSP product build |
| `thirdparty` | `ThirdParty/` |
| `tests` | `Tests/` harnesses and fixtures |
| `release` | `scripts/release/` and the release workflows |
| `ci` | the other workflows and runner setup |
| `docs` | `docs/`, `AGENTS.md`, `README.md` |
| `plan` | `docs/04-plan/` |

A commit that touches two modules uses the scope of the module whose behavior changes. If both change, make two commits.

---

## 5. Pull requests

### 5.1 Pull requests

- Title: `#<N> <Title>`. Body: [../../.github/pull_request_template.md](../../.github/pull_request_template.md).
- One task per pull request. The pull request that finishes the task says `Closes #<N>`; earlier ones say `Part of #<N>`.
- Aim for at most about 600 changed lines, not counting generated files, fixtures, and lock files.
- Documentation changes go in the same pull request as the code that needs them.
- Test evidence (T2 results, gate logs, recordings) goes into the pull request description or the issue, not into the repository.

### 5.2 Definition of done

[../../AGENTS.md](../../AGENTS.md) §12. A task cannot close while one of its listed tests is quarantined ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.7).

---

## 6. Review

### 6.1 Who reviews

A person reviews every pull request. Another AI agent may comment, but its comments are not an approval.

### 6.2 What the reviewer checks

CI checks formatting, the dependency graph, `TODO` numbers, logging calls, the lock file, generated code, and document references. The reviewer checks what CI cannot: scope (§2.5), that the code does what the design says, the order of preference ([../../AGENTS.md](../../AGENTS.md) §15), module ownership ([../01-architecture/modules.md](../01-architecture/modules.md) §2), the conventions ([coding-conventions.md](coding-conventions.md)), that the listed tests exist at the lowest tier, no readback in the frame path, no shell command per input event, and that new third-party code is pinned and licensed.

### 6.3 Security review

Changes to these need a review comment that starts with "Security review:": code marked `// SECURITY:` and parsers of guest or APK input; the policy layer, XPC peer validation, and per-wrapper authorization; signature checks for APKs, images, feeds, and APKRun updates; entitlements, signing, and `scripts/release/`; `.github/workflows/` and anything that handles a secret; new shipped third-party components.

### 6.4 Responding to review

Answer every comment: change the code, or explain why not. `fixup!` commits are folded before the merge.

---

## 7. Merging and CI

### 7.1 When a pull request may merge

1. Every required CI check passes: `workflow-policy` and every job of `ci.yml` (`lint`, `test-vsockd`, `codegen`, `third-party`, `build`, `test-swift`, `test-graphics`, `test-images`).
2. A pull request that closes a task links the results of every T2 suite the task lists, run on a real Mac.
3. A person approved it, and the security review is done where §6.3 requires it.
4. The branch is rebased on the current `main`.

### 7.2 How to merge

Rebase and merge. `main` has a linear history with no merge commits.

### 7.3 Protection of `main`

`main` requires the checks of §7.1, linear history, and resolved conversations. `workflow-policy` runs trusted code from `main`: a pull request that changes a CI control file (`.github/workflows/`, `scripts/ci/`, `scripts/tests/`, `scripts/tools/`, build files, `docs/01-architecture/modules.md`, and the others listed in `scripts/ci/check-pr-control-changes.py`) needs an approving review from a person who also applied `ci-policy-approved` after the last push.

### 7.4 A red `main`

A failure on `main` is fixed or reverted before other work merges into the affected area. A flaky test is quarantined only by the rules of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.7.

### 7.5 Reverts

`revert(<scope>): <original subject>`, with `Refs: #<N>` of the original task and a body that says why. The task the revert undoes is reopened.

---

## 8. Versioning and build numbers

### 8.1 APKRun version

- `MAJOR.MINOR.PATCH` in `CFBundleShortVersionString`, shown without a zero patch ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1).
- Before v1.0 the versions follow the roadmap: `0.1.0` to `0.5.0`, then `1.0.0` ([../04-plan/roadmap.md](../04-plan/roadmap.md) §1.2). After v1.0: MINOR for features, PATCH for fixes, MAJOR only with an ADR.
- `MARKETING_VERSION` in `project.yml` is the next release version ([build-system.md](build-system.md) §2.5).
- Every version is published once, as one build. A failed candidate is never promoted; its fix ships as the next patch version.

### 8.2 Build number

`CFBundleVersion` = `MAJOR × 1000 + MINOR × 100 + PATCH × 10` (0.1.0 → 100, 1.1.5 → 1150). It increases with every published build on every channel (R1). MINOR and PATCH are at most 9; more needs a new formula in an ADR. The release job passes it as `CURRENT_PROJECT_VERSION`; local builds use `1`. `ReleaseUpdateTest` builds use 9000 and 9001 and are never published ([build-system.md](build-system.md) §2.4).

### 8.3 Tags

| Tag | Points at | Created by |
|---|---|---|
| `v<MAJOR>.<MINOR>.<PATCH>` | a `main` commit whose `MARKETING_VERSION` is that version | the maintainer, annotated; it starts `release.yml` (§9.4) |
| `image-<YYYY.MM.N>` | the `main` commit the image was built from | the maintainer, before the image release (§10.3) |

Tags are never moved or deleted after a push.

### 8.4 Other versions

| Version | Rule | Defined in |
|---|---|---|
| RuntimeAPI | `major.minor`; the wrapper endpoint serves majors N and N−1 | [coding-conventions.md](coding-conventions.md) §6.2 |
| guest protocol | majors; dropped only as R4 allows | [coding-conventions.md](coding-conventions.md) §6.1 |
| data schemas | one integer `schemaVersion` per file, migrated step by step | [coding-conventions.md](coding-conventions.md) §6.3 |
| guest APKs | `versionCode = major × 1,000,000 + minor × 1,000 + patch` of the APKRun version | [build-system.md](build-system.md) §7.1 |
| image version | `YYYY.MM.N-<base>-<arch>`, monotonic | [../02-design/android-image.md](../02-design/android-image.md) §12.1 |
| third-party builds | upstream version plus `+apkrun.<n>` when patched | [build-system.md](build-system.md) §6.1 |

---

## 9. APKRun release

The release steps below are complete only after #58, #89, and #88 (§9.7).

### 9.1 Release rules

| # | Rule | Checked by |
|---|---|---|
| R1 | The build number is higher than every published build, on every channel | `check-release-build.sh` |
| R2 | The release passes the T3 release smoke matrix ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.2) with the current and the previous stable image | the release issue |
| R3 | An image entry's `minimumRuntimeVersion` is the oldest APKRun release it was tested with, and that release is on the same channel | `image-feed.py` |
| R4 | A RuntimeAPI major or guest protocol major is dropped only as [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.2 allows | T0 handshake matrix, smoke matrix |
| R5 | Every persisted file has a migration chain from every schema version shipped in a stable release in the last 24 months, each step with a T0 golden test | T0 goldens, `check-release-build.sh` |
| R6 | The Sparkle EdDSA key and the Developer ID certificate never change in the same release | `check-release-build.sh` |
| R7 | A stable image is released at least once a quarter, plus extra releases for critical security fixes and for tzdata changes within 60 days ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.11) | §10.2 |

### 9.2 Environments and secrets

The `release` environment holds `APKRUN_DEVELOPER_ID_P12` and its password, `APKRUN_NOTARY_KEY_P8` with its key and issuer IDs, `APKRUN_SPARKLE_ED_PRIVATE_KEY`, `APKRUN_IMAGE_SIGNING_KEY`, and `APKRUN_PUBLISH_CREDENTIALS`. It accepts only `v*` and `image-*` tags and `main`, and every job waits for a maintainer's approval. Pull request jobs never see these secrets. Offline key copies are kept outside the repository and CI ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7).

### 9.3 Preparing a release

1. Open the issue `Release <version>` with the steps of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.1 and the manual checklist of the version (§8 there). For v1.0 the issue is #95.
2. In one commit or pull request: set `MARKETING_VERSION`, add `docs/releases/<version>.md` (what changed; for v1.0 also the unfinished `Should` requirements), and commit the reviewed compatibility results.
3. Dry run: `release.yml` with `dry-run` on `main`.
4. Tag: `git tag -a v<version> -m "APKRun <version>"` and `git push origin v<version>`.

### 9.4 The release job

`release.yml` runs on the tag after approval: clean checkout (tag on `main`, `MARKETING_VERSION` equals the tag, `ci.yml` passed); build number (§8.2); third-party and guest builds; assemble the Release app with `APKRUN_CHANNEL=stable`; sign with the Developer ID; `check-release-build.sh`; notarize and staple; make the DMG; make the Sparkle zip; sign it, make deltas from the last three releases, add a beta appcast item; publish; create a GitHub pre-release with the zip, the DMG, `components.json`, and `SHA256SUMS`. A failure in any step stops the job before anything is published. Details of each script: [build-system.md](build-system.md) §11–§12.

### 9.5 Beta and promotion to stable

A candidate is promoted when [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.1 passed (including R2), it spent at least 3 days on beta (1 day for a PATCH, none for a critical fix), no `release-blocker` issue is open, and it is the highest published build. Promotion (`release.yml` with `promote`) turns the beta item into a stable item with phased rollout (`phasedRolloutInterval` 86400, unless critical) and does not rebuild or re-sign anything.

### 9.6 Critical security fixes

A security fix ships as a PATCH through §9.3–§9.5 with `appcast.py add --critical`. Every later item carries `<sparkle:criticalUpdate>` with the build of the latest security fix. Critical items still go to beta first but have no minimum time and no phasing. Security checks are never waived.

### 9.7 Before the pipeline is complete

| Versions | How a release is made |
|---|---|
| v0.1–v0.4 (before #58) | The tag (§8.3) and the milestone review are the release. When testers need a build, the maintainer builds the Release configuration from a clean checkout of the tag, signs it with the Developer ID when one is configured, and attaches the zip to a GitHub pre-release. There is no appcast. |
| v0.5 (after #58, before #89) | `release.yml` runs as a dry run: it writes the signed archive and the signed appcast to `build/release/` and publishes nothing. The app is not notarized. |
| v1.0 (after #89 and #88) | every step of §9.4, §9.5, and §10 |

No Android image is published before #88.

### 9.8 Key and certificate changes

The Sparkle key and the Developer ID certificate never change in the same release (R6). A new Sparkle key ships in a release signed with the old key. A new image key ID is added to `ImageTrustStore` in an APKRun release, and feeds switch to it only after that release is stable ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7).

---

## 10. Image release

### 10.1 What is released

Only `kind: apkrun` bundles built from source, `user` variant. The prebuilt Cuttlefish image is never published ([legal-and-licensing.md](legal-and-licensing.md) §2). The version is `YYYY.MM.N-ar<counter>-arm64`; `N` starts at 0 each month. Each release has an issue `Android <YYYY.MM.N>`.

### 10.2 Release calendar (R7)

| When | Release |
|---|---|
| January, April, July, October | the quarterly stable image with the latest security patch level and tzdata |
| within 7 days of a fix | a critical security release (`critical: true`) |
| as soon as known | a tzdata change that takes effect within 60 days |

### 10.3 Steps

1. Tag `image-<YYYY.MM.N>`.
2. Build on the image build machine: `scripts/aosp/build-product.sh --revision <commit> --variant user` ([build-system.md](build-system.md) §9). Release keys never leave that machine.
3. Upload the zip to private release storage; note its SHA-256 in the issue.
4. `image-release.yml candidate`: check the zip, build the bundle (`python3 -m apkrun_image bundle`), run `check-release-build.sh`, pack the `.aar`.
5. Run [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.3 on the reference Mac.
6. `beta`: upload and add the beta feed entry, `rolloutPercent` 100. Upload the corresponding GPL/LGPL source ([legal-and-licensing.md](legal-and-licensing.md) §7).
7. `stable` after at least 3 days on beta with no `release-blocker`: `rolloutPercent` 25 (critical: 100).
8. `rollout` after 7 more days: `rolloutPercent` 100.

Release notes: `docs/releases/android-<YYYY.MM.N>.md`.

### 10.4 Feed operations

`scripts/release/image-feed.py` is the only tool that writes a feed ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1): `add`, `promote`, `rollout`, `remove`, `resign`. Every command increments `sequence`, sets `generatedAt` and `expiresAt = generatedAt + 30 days`, signs `feed.json` into `feed.json.sig`, and refuses output above the client limits (1 MiB, 4 KiB). `add` and `promote` refuse an entry that breaks R3 or whose `imageVersion` is not above every earlier one. A bad image is removed and replaced by a higher version; versions are never reused.

### 10.5 Weekly re-signing

`image-feed-resign.yml` runs `image-feed.py resign` for both channels every Monday at 03:00 UTC, after approval. Clients stop using a feed 30 days after `generatedAt`, so one missed week does no harm.

---

## 11. Parallel work

### 11.1 Rules

- One task, one owner, one branch or working copy at a time. Two agents never commit to the same branch at the same time.
- Each agent works in its own clone or `git worktree`, with its own `APKRUN_HOME` for local runs.
- Stay in the task's `Code` paths. Before touching a path another open task lists, comment on that task's issue.
- Only one VM runs at a time on a Mac until #100 is done ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.6).

### 11.3 Shared files

| File | Rule when two changes meet |
|---|---|
| `*.pb.swift`, the Kotlin protobuf output, the generated error catalog | never resolve by hand: rebase, then regenerate ([build-system.md](build-system.md) §4) |
| `Package.resolved` | rebase, then `swift package resolve` |
| `errors.json`, `ThirdParty/ThirdParty.lock.json`, `Package.swift`, `project.yml` | keep both changes; `scripts/ci/run-checks.sh` must pass |
| milestone files, the task index | keep both entries and rows |
| ADRs | the second change takes the next free number |

---

## 12. Experiments

### 12.1 Where they live

An `experiment/<name>` branch for a spike that never merges. `Experiments/<name>/` on `main` for a spike others need to run again; it has a `README.md` with the question, the task, how to run it, and the result.

### 12.2 Rules

- Production targets and tests never import `Experiments/`, and CI does not build it. `scripts/check-module-deps.sh` fails on an import.
- Experiment code follows only the security and no-secrets rules ([coding-conventions.md](coding-conventions.md) §1, §13).

### 12.3 From experiment to production

Reimplement the minimum cleanly in the production module, in a task. Write the result into the design document or an ADR. Delete the experiment when production covers it.
