# Development Workflow

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../../AGENTS.md](../../AGENTS.md), [../04-plan/issues/README.md](../04-plan/issues/README.md), [../04-plan/roadmap.md](../04-plan/roadmap.md), [../04-plan/test-strategy.md](../04-plan/test-strategy.md), [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md), [build-system.md](build-system.md), [environment-setup.md](environment-setup.md), [coding-conventions.md](coding-conventions.md), [legal-and-licensing.md](legal-and-licensing.md) |
| Tasks | every task (§1–§7, §11, §12); #057, #087, #088, #094 (release pipeline, §9, §10); #060, #090 (issue templates, §3) |

This guide says how work moves from a task entry to `main`, and from `main` to users: issues, branches, commits, pull requests, review, merging, releases, parallel work, and experiments. It applies to people and AI coding agents alike. [../../AGENTS.md](../../AGENTS.md) has the short form of these rules. This guide has the details. A change to this guide is a pull request that a maintainer approves. A change that also changes a rule of AGENTS.md needs an accepted ADR first ([../01-architecture/decisions/README.md](../01-architecture/decisions/README.md)).

---

## 1. Roles

| Role | Who | May |
|---|---|---|
| Contributor | anyone, a person or an AI coding agent | open issues, claim a task, push to their own branches, open pull requests |
| Maintainer | a person with write access to the repository | everything a contributor may, plus review and approve, merge, triage issues, approve jobs in the `signing` and `release` environments ([environment-setup.md](environment-setup.md) §6.4) |
| Release manager | the maintainer named in a release issue | tag and run the release workflows of §9 and §10 for that release |

- Approvals come from people. An AI agent never approves a pull request, merges one, or approves an environment job.
- An AI agent that cannot decide something stops and asks in the issue or the pull request ([../../AGENTS.md](../../AGENTS.md) §15). It does not guess.

---

## 2. Task lifecycle

### 2.1 Picking a task

- Take the lowest-numbered task in the current milestone whose dependencies are done, unless the roadmap says otherwise ([../04-plan/issues/README.md](../04-plan/issues/README.md) §4, [../../AGENTS.md](../../AGENTS.md) §2).
- "Done" means merged to `main` with the issue closed. A dependency whose pull request is still open is not done (§11.2 covers stacked work).
- Tasks that can run at the same time are listed in [../04-plan/roadmap.md](../04-plan/roadmap.md) §1.4.

### 2.2 States

| State | Visible as | Next step |
|---|---|---|
| open | issue without assignee | a contributor claims it (§2.3) |
| claimed | assignee set, comment "Working on this", draft pull request linked | work in small commits; push at least once a working day while active |
| blocked | label `blocked`, a comment that names the blocking issue or question | the blocker is resolved, then back to claimed |
| in review | the pull request is marked ready for review | review (§6) |
| done | the closing pull request is merged; `Closes #NNN` closes the issue | none |

### 2.3 Claiming

- Assign the issue to yourself (an AI agent uses the account it pushes with) and comment "Working on this".
- Open a draft pull request as soon as the branch has its first commit, so others can see the work.
- A claim with no push and no comment for 5 working days may be released by a maintainer, after a comment to the assignee.
- Never work on a task that someone else has claimed. Ask in the issue instead.

### 2.4 Task text and numbers

- The milestone files in [../04-plan/issues/](../04-plan/issues/README.md) are the source of truth for task text. The GitHub issue is a copy. When they disagree, fix the file first, then the issue.
- The first 97 tasks (#001–#097) must keep their numbers. In a new repository, the issues are created from the milestone files in number order before any other issue or pull request is opened, because GitHub numbers issues and pull requests in one sequence.
- A new task (#098 and up) gets its number from GitHub: open the issue with the task template, then add the entry `## #NNN Title` to its milestone file and to [../04-plan/issues/README.md](../04-plan/issues/README.md) §3 in a pull request. Task numbers are therefore not contiguous. Because GitHub assigns the numbers, two agents can never take the same number.
- Adding, removing, or renaming a task also updates [../04-plan/traceability.md](../04-plan/traceability.md) ([../../AGENTS.md](../../AGENTS.md) §14).

### 2.5 When the task is wrong

- If a step is wrong or impossible, change the design document and the task entry in the same pull request and say why in the pull request ([../04-plan/issues/README.md](../04-plan/issues/README.md) §4).
- If the change is architectural, the ADR comes first, in its own pull request, and is `Accepted` before code that depends on it merges ([../../AGENTS.md](../../AGENTS.md) §15).
- If finishing the task needs something outside its scope, stop and file a follow-up task (§2.4). Do not widen the pull request ([../../AGENTS.md](../../AGENTS.md) §11).

---

## 3. Issues, templates, and labels

### 3.1 Kinds of issues

| Kind | Opened by | Template or title | Label |
|---|---|---|---|
| Task | a maintainer or contributor, from a milestone file | `.github/ISSUE_TEMPLATE/task.md`, title `#NNN Title` | `task` |
| Bug report | users and contributors | `.github/ISSUE_TEMPLATE/bug-report.md` (§3.2) | `bug` |
| App compatibility report | users | `.github/ISSUE_TEMPLATE/app-compatibility.md` (§3.3) | `compatibility` |
| Release | the release manager | title `Release <version>` (§9.3) | `release` |
| Image release | the release manager | title `Android <YYYY.MM.N>` (§10.3) | `image-release` |
| CI finding | a workflow | the title names the workflow, the job, and the commit or component | `nightly-failure`, `macos-regression`, `fuzz-crash`, or `third-party-security` |

Security vulnerabilities are never reported in a public issue (§3.5).

### 3.2 Bug report template (#060)

The template `bug-report.md` is added by #060, together with the link at the end of the Report a Problem flow ([../02-design/diagnostics.md](../02-design/diagnostics.md) §8.5). It asks for:

| Field | Content |
|---|---|
| What happened | free text |
| What you expected | free text |
| Steps to reproduce | numbered steps |
| Summary | the text from **Copy Summary** (`summary.txt`), or the summary that `apkrun diagnostics` prints |
| Versions | the output of `apkrun version` (APKRun, apkrund, and the Android image), when the summary is not available |
| Mac | Mac model and macOS version |
| App | package ID and version, if one app is involved |
| Diagnostics bundle | optional: the user attaches `APKRun-Diagnostics-<yyyyMMdd-HHmmss>.zip` themselves |

- APKRun uploads nothing. The user decides whether to attach the bundle ([../02-design/diagnostics.md](../02-design/diagnostics.md) §8.1).
- The template says that issues are public, that the bundle is redacted ([../02-design/diagnostics.md](../02-design/diagnostics.md) §6), and that the user should look at it before attaching it.
- A maintainer who confirms a bug adds `bug` and either links it to the task that owns the code or files a new task (§2.4).

### 3.3 App compatibility template (#090)

The template `app-compatibility.md` is added by #090. Its fields map to a database entry ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10.2):

| Field | Entry field |
|---|---|
| App name and package ID | `packageID` |
| App version and where it came from (F-Droid, GitHub, the developer's site, a file) | `versionCodes`; the source lets a maintainer get the same signed build (`signerDigests`) |
| Result: Works, Works with limitations, or Unsupported | `level`. The maintainer picks the internal level after reproducing it: Works is `nativeLike`; Works with limitations is `compatible` or `compatibilityMode`; Unsupported is `unsupported` ([../00-product/scope.md](../00-product/scope.md) §4) |
| What does not work, and any workaround | `issues` |
| Settings that helped (window mode, input) | `recommendedSettings` |
| APKRun version and Android system version | `testedWith` |

- A report becomes an entry only after a maintainer reproduces it on a lab Mac. The entry then gets `source: report` and the maintainer's `testedWith` values. The entry is committed to `Tests/Compatibility/database/compatibility.json` in a pull request that links the report.
- The template tells users not to attach APKs they have no right to share.

### 3.4 Labels

| Label | Meaning | Set by |
|---|---|---|
| `task` | a numbered task | task template |
| `blocked` | the task waits for another issue or a decision | assignee |
| `bug`, `compatibility` | user reports (§3.2, §3.3) | templates, maintainers |
| `security` | a security finding filed as a task (#091) | maintainers |
| `security-review` | the pull request needs the security review of §6.3 | author or reviewer |
| `run-t2` | request every T2 suite for the pull request; execution needs disposable lab capacity or a maintainer-run reviewed commit | author |
| `t2-android`, `t2-maintenance` | request only those T2 suites; execution needs disposable lab capacity or a maintainer-run reviewed commit ([build-system.md](build-system.md) §15.1) | author |
| `release`, `image-release` | release issues (§9, §10) | release manager |
| `release-blocker` | must be fixed before the named release is promoted | maintainers |
| `nightly-failure` | a failure on `main` or in a nightly run (§7.4) | CI |
| `macos-regression` | a failure on a new macOS build ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.4) | CI |
| `fuzz-crash` | a crash found by `fuzz-long` ([build-system.md](build-system.md) §15.2) | CI |
| `third-party-security` | an upstream security fix for a pinned component ([build-system.md](build-system.md) §6.7) | CI |

### 3.5 Security vulnerabilities

- The repository has GitHub private vulnerability reporting turned on. Reporters use it, not a public issue.
- A maintainer confirms the report, develops the fix in a private security advisory fork, and gets the security review of §6.3.
- The fix ships as a critical release (§9.6). The advisory is published after the release reaches stable.

---

## 4. Branches and commits

### 4.1 Branches

| Branch | Use | Merged to `main` |
|---|---|---|
| `main` | the only long-lived branch. Protected (§7.3) | — |
| `task/<NNN>-<short-name>` | one task, or one part of one task (§5.1). Example `task/024-pointer-input` | yes |
| `fix/<NNN>-<short-name>` | a bug fix, where `<NNN>` is the bug issue | yes |
| `docs/<short-name>` | a documentation change that belongs to no task and no bug | yes |
| `experiment/<name>` | an experiment (§12). Examples `experiment/vz-linux-boot`, `experiment/android-virgl` | never |

- `<short-name>` is lowercase words joined by hyphens, at most 40 characters.
- Branch from the latest `main`. Keep the branch current by rebasing onto `main`, not by merging `main` into it.
- There are no release branches. Every release is a tag on `main` ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.1 step 1).
- Delete the branch after the merge.

### 4.2 Commit messages

Commits use Conventional Commits with a required scope ([../../AGENTS.md](../../AGENTS.md) §13):

```text
<type>(<scope>): <subject>

<body: why the change is needed, and what a reviewer should know>

Refs: #NNN
```

```text
feat(vm): boot arm64 linux with Virtualization.framework
feat(graphics): expose virtio-gpu through custom virtio device
fix(update): reject mismatched signing certificate
feat(android): reach Android boot_completed
feat(wrapper): generate thin macOS app bundle
```

- The subject is imperative, lowercase after the colon, at most 72 characters, with no period at the end.
- The body is wrapped at 72 characters. `Refs: #NNN` names the task or bug.
- A change that raises a RuntimeAPI major, a guest protocol major, or makes a persisted format incompatible has a `BREAKING CHANGE:` footer that names the ADR ([coding-conventions.md](coding-conventions.md) §6).
- Never `work`, `changes`, `fix stuff`, `wip final`, or `wip`.
- Prefer small commits. Each commit should build. Generated files go in the same commit as their source (`*.pb.swift` with the `.proto` file, the error catalog tables with `errors.json`).

| Type | Use |
|---|---|
| `feat` | new behavior |
| `fix` | a bug fix |
| `perf` | a measured performance change; the body gives the measurement ([coding-conventions.md](coding-conventions.md) §12) |
| `refactor` | no change in behavior |
| `test` | tests or fixtures only |
| `docs` | documentation only |
| `build` | `Package.swift`, `project.yml`, `ThirdParty/`, `scripts/build/` |
| `ci` | `.github/workflows/`, runner scripts |
| `chore` | anything else that users cannot notice, for example `.gitignore` |
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

A commit that touches two modules uses the scope of the module whose behavior changes. If both change, it is probably two commits.

---

## 5. Pull requests and the Definition of Done

### 5.1 Pull requests

- Title: `#NNN Title`, the task number and title ([../../AGENTS.md](../../AGENTS.md) §13). A bug fix uses the bug's number and a short title.
- Body: [../../.github/pull_request_template.md](../../.github/pull_request_template.md). Fill every section. Write "None" where a section does not apply.
- One task per pull request. A large task may be split into several pull requests on several `task/<NNN>-…` branches. Each one says which steps it covers. Only the last one says `Closes #NNN`; the others say `Part of #NNN`.
- Aim for at most about 600 changed lines, not counting generated files, fixtures, and lock files.
- Documentation changes go in the same pull request as the code that needs them ([../../AGENTS.md](../../AGENTS.md) §14).
- New third-party code is pinned in `ThirdParty/ThirdParty.lock.json` in the same pull request, with an ADR where one is needed ([build-system.md](build-system.md) §6.8, [legal-and-licensing.md](legal-and-licensing.md) §4).
- The pull request that closes a task carries the label `run-t2`, runs every T2 suite that the task lists on disposable lab capacity, or has a maintainer-run result for the reviewed commit linked ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.4). Add the label when the pull request is ready, not on every push: lab Macs run one job at a time.

### 5.2 Definition of Done

A task is done when all of [../../AGENTS.md](../../AGENTS.md) §12 holds. The pull request shows the evidence:

| Condition | Evidence in the pull request |
|---|---|
| every acceptance criterion of the task entry is met | the checked criteria in the task entry, and "Implementation steps covered" |
| the tests of every tier the entry lists pass | the Tests table: T0 from hosted CI; T1 from trusted main jobs, disposable PR capacity, or linked real-Mac manual results; T2 from the linked `integration.yml` run when available, or a maintainer-run result for the reviewed commit; T3 and other manual results with their records |
| logging and typed errors are in place | review ([coding-conventions.md](coding-conventions.md) §5); new user-visible errors are in `errors.json` with a remediation, and the generated error catalog is committed |
| non-obvious behavior is documented, and the design documents describe what was built | the changed documents in the diff |
| the manual checks the entry requires are recorded | "Verification results to record": each result and where it was written |
| verification results are written where the entry's Notes say | the same section: design verification logs, [../04-plan/risks.md](../04-plan/risks.md), [../04-plan/open-questions.md](../04-plan/open-questions.md), ADRs |

- Every temporary workaround has `TODO(#NNN): reason` with a tracking task (NFR-DEV-04). `scripts/check-todos.sh` fails on a `TODO` or `FIXME` without a number.
- A task cannot close while one of its listed tests is quarantined ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.7).
- Gate evidence (logs, screen recordings, measurements) is attached to the task's issue, and the pull request links it ([build-system.md](build-system.md) §15.1).

---

## 6. Review

### 6.1 Who reviews

- Every pull request needs one approval from a maintainer who is not the author.
- A pull request from an AI agent needs the approval of a person. Another AI agent may comment, but its comments do not count as a review.
- Pull requests that need the security review (§6.3) also need that review.
- A reviewer gives a first answer within 2 working days. If a review needs a person with a specific skill, the reviewer says so and asks that person.

### 6.2 What the reviewer checks

The CI checks of [build-system.md](build-system.md) §3 cover formatting, the dependency graph, `TODO` numbers, logging calls, the lock file, and generated code. The reviewer checks what CI cannot:

| Area | Question |
|---|---|
| scope | Does the change stay within the task? Is every extra item filed as a follow-up ([../../AGENTS.md](../../AGENTS.md) §11)? |
| design | Does the code do what the design sections say? If not, was the design document changed in the same pull request, with the reason? |
| order of preference | Does it use existing Android, virtio, Cuttlefish, or RiftVM behavior before a new mechanism ([../../AGENTS.md](../../AGENTS.md) §15)? |
| module boundaries | Is each type in the module that owns it ([../01-architecture/modules.md](../01-architecture/modules.md) §2)? |
| conventions | [coding-conventions.md](coding-conventions.md): errors, logging privacy, concurrency, protocol evolution, comments and markers |
| tests | Are the listed tests present, at the lowest tier that can fail, using the fixture apps? Is the T2 result linked for a closing pull request? |
| graphics | No readback in the normal frame path. Graphics work verified on real hardware, not only on mocks |
| input | No shell command per input event |
| documentation | Do the documents describe what was built? Are traceability, risks, and open questions updated where needed? |
| third party | Is new code pinned, with its license checked ([legal-and-licensing.md](legal-and-licensing.md) §4) and an ADR where needed? |

### 6.3 Security review

These changes need a security review in addition to the normal review:

- code marked `// SECURITY:` ([coding-conventions.md](coding-conventions.md) §12), and code that parses guest or APK input;
- the policy layer, XPC peer validation, per-wrapper authorization ([../01-architecture/security-model.md](../01-architecture/security-model.md));
- signature checks for APKs, images, feeds, and APKRun updates;
- entitlements, code signing, and the scripts under `scripts/release/`;
- `.github/workflows/`, the `signing` and `release` environments, and anything that handles a secret;
- new third-party components that ship, and upstream security fixes (`third-party-security`).

Rules:

- The author, or any reviewer, adds the label `security-review`.
- The security reviewer is a maintainer other than the author. They can be the same person as the normal reviewer.
- The reviewer leaves a comment that starts with "Security review:" and says what they checked. The label is removed only after that comment.
- A finding that needs more than a local fix becomes a task with the label `security` (#091).

### 6.4 Responding to review

- Answer every comment: change the code, or explain why not.
- Push new commits during review. `fixup!` commits are fine. They are folded before the merge (§7.2).
- Re-request review after the changes. A new push dismisses earlier approvals (§7.3).

---

## 7. Merge rules and CI gates

### 7.1 When a pull request may merge

All of these hold:

1. Every required CI check passes. The required checks are `workflow-policy` and every job of `ci.yml`, as [build-system.md](build-system.md) §15.1 requires: `lint`, `codegen`, `third-party`, `build`, `test-swift`, `test-graphics`, and `test-images` at present. A later task that adds a job to `ci.yml` makes it required too ([implementation-review.md](../04-plan/implementation-review.md#ir-273-require-every-ciyml-job-not-only-the-four-named-in-062), IR-273).
2. Until a disposable lab runner is provisioned, `linux-guest` is not a pull-request status check; the task-closing PR links a maintainer-run result for its reviewed commit (§5.1, [build-system.md](build-system.md) §15.1).
3. The pull request that closes a task has passed every T2 suite that the task lists, and the result is linked (§5.1).
4. Host-dependent T1 suites that cannot run on the hosted VM pass on a real Apple Silicon Mac, and their result is linked in the pull request.
5. One maintainer approval (§6.1), and the security review where §6.3 requires it.
6. No unresolved review thread.
7. The branch is rebased on the current `main`.
8. `main` is not blocked by a failure in the affected area (§7.4).

T2 suites are not a merge check for other pull requests. T3 runs nightly and gates releases, not merges ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.1).

### 7.2 How to merge

- Use **Rebase and merge**. `main` has a linear history with no merge commits.
- Before the merge, fold the `fixup!` commits and push:

  ```bash
  git fetch origin
  GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash origin/main
  git push --force-with-lease
  ```

- A maintainer merges. The author may merge their own pull request if they are a maintainer and every rule of §7.1 holds.

### 7.3 Protection of `main`

| Setting | Value |
|---|---|
| Require a pull request before merging | on, 1 approval |
| Dismiss stale approvals when new commits are pushed | on |
| Required status checks | `workflow-policy` and every `ci.yml` job: `lint`, `codegen`, `third-party`, `build`, `test-swift`, `test-graphics`, and `test-images` (IR-273); the branch must be up to date |
| Require linear history | on |
| Require conversation resolution | on |
| Force pushes and deletion | blocked |
| Apply to administrators | on |

`linux-guest` is not a required pull-request status check while `integration.yml` has no pull-request trigger and uses the persistent lab Mac only for trusted `main` code. Until disposable lab capacity is available, the reviewer checks the maintainer-run T2 result linked from each task-closing PR. Once disposable capacity is provisioned, enable the matching pull-request trigger and require its check for matching changes. `workflow-policy` is the required metadata-only check for pull requests targeting `main`; it runs trusted code from `main` and checks that CI control changes have an approved review on the current head and that the same human reviewer applied `ci-policy-approved`. Removing that label revokes the check. Any new commit, reopening, later label event, or PR edit resets this check; the reviewer removes and reapplies the policy label last. To revoke the CI-policy approval, remove the label. Branch protection separately requires an active PR approval.

### 7.4 A red `main`

- A T2 failure on `main` blocks every merge until the change is fixed or reverted ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.7).
- A failure in a nightly run opens an issue with the label `nightly-failure` ([build-system.md](build-system.md) §15.3). The owner of the breaking change fixes or reverts it within one working day. Until then, no other pull request merges into the affected area. The issue names the area (the modules or suites).
- A test that is flaky is quarantined only by the rules of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.7.

### 7.5 Reverts

- A revert is `revert(<scope>): <original subject>` with `Refs: #NNN` for the original task and a body that says why.
- A revert that fixes a red `main` needs one approval but no T2 result. It follows the other rules of §7.1.
- The task that the revert undoes is reopened.

---

## 8. Versioning and build numbers

### 8.1 APKRun version

- The version is `MAJOR.MINOR.PATCH`, `CFBundleShortVersionString`. It is shown without a zero patch ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1).
- Before v1.0 the versions follow the roadmap: `0.1.0` to `0.5.0`, then `1.0.0` ([../04-plan/roadmap.md](../04-plan/roadmap.md) §1.2).
- After v1.0: MINOR for new features, PATCH for fixes only, MAJOR only with an ADR.
- `MARKETING_VERSION` in `project.yml` is the next release version ([build-system.md](build-system.md) §2.5). A pull request sets it right after each release, and the release preparation (§9.3) may change it, for example to a patch version.
- Every version is published once, as one build. A candidate that fails on beta is never promoted. Its fix ships as the next patch version (§9.5).

### 8.2 Build number

`CFBundleVersion` is the build number. It is a positive integer that increases with every published build on every channel (R1):

```text
build = MAJOR × 1000 + MINOR × 100 + PATCH × 10
```

| Version | Build |
|---|---|
| 0.1.0 | 100 |
| 0.5.0 | 500 |
| 1.0.0 | 1000 |
| 1.1.5 | 1150 |
| 1.2.0 | 1200 |

- The formula gives the numbers used in [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.3. The last digit is always 0.
- MINOR and PATCH are at most 9. A version that needs more needs a new formula first, recorded in an ADR. The new formula must give numbers above every published build.
- The release job computes the number from the tag and passes it as `CURRENT_PROJECT_VERSION`. Local builds use `1` ([build-system.md](build-system.md) §2.5).
- `ReleaseUpdateTest` builds use 9000 and 9001 ([build-system.md](build-system.md) §2.4). They have their own identity (`.updatetest`) and are never published, so R1 does not apply to them.

### 8.3 Tags

| Tag | Points at | Created by |
|---|---|---|
| `v<MAJOR>.<MINOR>.<PATCH>`, for example `v1.2.0` | a commit on `main` whose `MARKETING_VERSION` is that version | the release manager, as an annotated tag; it starts `release.yml` (§9.4) |
| `image-<YYYY.MM.N>`, for example `image-2026.10.0` | the commit on `main` that the image was built from | the release manager, before the image release (§10.3) |

Tags are never moved or deleted after a push. A mistake gets a new version.

### 8.4 Other versions

| Version | Rule | Defined in |
|---|---|---|
| RuntimeAPI | `major.minor`; the wrapper endpoint serves majors N and N−1 | [coding-conventions.md](coding-conventions.md) §6.2, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.2 |
| guest protocol | majors; a major is dropped only as R4 allows | [coding-conventions.md](coding-conventions.md) §6.1 |
| data schemas | one integer `schemaVersion` per file, migrated step by step | [coding-conventions.md](coding-conventions.md) §6.3, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5 |
| guest APKs | `versionCode = major × 1,000,000 + minor × 1,000 + patch` of the APKRun version | [build-system.md](build-system.md) §7.1 |
| image version | `YYYY.MM.N-<base>-<arch>`, monotonic; `YYYY.MM.N` in user text | [../02-design/android-image.md](../02-design/android-image.md) §12.1 |
| third-party builds | upstream version plus `+apkrun.<n>` when patched | [build-system.md](build-system.md) §6.1 |

`components.json` records these values for each build ([build-system.md](build-system.md) §5).

---

## 9. APKRun release

### 9.1 Release rules

These rules come from [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.3. The release workflows check them before they publish an appcast item or a feed entry. The "Checked by" column is [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.5 plus the scripts of this guide.

| # | Rule | Checked by |
|---|---|---|
| R1 | The build number is higher than every build published before, on every channel | `check-release-build.sh` in the release job ([build-system.md](build-system.md) §3.1) |
| R2 | The APKRun release passes the T3 release smoke matrix (boot, one app launch, migration A → B; [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14 and [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.2) with the current stable image and with the previous stable image | the smoke matrix, recorded in the release issue; the approver of the promotion (§9.5) |
| R3 | An image entry's `minimumRuntimeVersion` is the oldest APKRun release it was tested with. An image that needs an unreleased APKRun is published only after that APKRun is on the same channel | test-strategy §9.3 step 5; `image-feed.py` refuses an entry whose `minimumRuntimeVersion` is above the highest APKRun on the channel (§10.4) |
| R4 | A RuntimeAPI major or guest protocol major is dropped only as [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.2 allows | the T0 handshake matrix; the smoke matrix with the previous stable image; review of the `BREAKING CHANGE:` commit (§4.2) |
| R5 | For every file, the migration chain exists from every schema version shipped in a stable release in the last 24 months, and each step has a T0 golden test ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5) | the T0 schema goldens; `check-release-build.sh` in the release job |
| R6 | The Sparkle EdDSA key and the Developer ID certificate are never changed in the same release ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7) | `check-release-build.sh` in the release job |
| R7 | A stable image is released at least once a quarter, for Android security patches and time zone data. An extra release is made for a critical security fix, and for a tzdata change that affects a zone within 60 days ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.11) | the release calendar (§10.2); test-strategy §9.3 |

### 9.2 Environments and secrets

| Secret | Environment | Used by |
|---|---|---|
| `APKRUN_DEVELOPER_ID_P12`, `APKRUN_DEVELOPER_ID_P12_PASSWORD` | `signing`, `release` | `sign-bundle.sh`, imported into a temporary keychain that the job deletes |
| `APKRUN_NOTARY_KEY_P8`, `APKRUN_NOTARY_KEY_ID`, `APKRUN_NOTARY_ISSUER_ID` | `signing`, `release` | `notarize.sh` in the API key form |
| `APKRUN_SPARKLE_ED_PRIVATE_KEY` | `release` | `sign_update` and the appcast signature |
| `APKRUN_IMAGE_SIGNING_KEY` | `release` | image bundle signing, `image-feed.py` (§10) |
| `APKRUN_PUBLISH_CREDENTIALS` | `release` | `publish.py`: upload to the updates host (OQ-01) |

- The `release` environment accepts only the tags `v*` and `image-*` and the `main` branch. Every job waits for a maintainer's approval ([environment-setup.md](environment-setup.md) §6.4).
- The offline copies of the Sparkle and image keys are kept by the maintainers, outside the repository and outside CI ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7).
- Pull request jobs never see these secrets.

### 9.3 Preparing a release

1. The release manager opens the release issue `Release <version>` with the label `release`. For v0.1–v0.5 the milestone review issue is the release issue, and for v1.0 it is #094 ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §8.1). The issue lists the steps of test-strategy §9.1 and the manual checklist of the version (§8).
2. A preparation pull request on `task/<issue>-release-<version>`, titled `#<issue> Prepare <version>`:
   - sets `MARKETING_VERSION` to the version;
   - adds the release notes `docs/releases/<version>.md` in English: what changed, the unfinished `Should` requirements (for v1.0), and the follow-up issue of every waived non-security check ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §8.1);
   - commits the reviewed results of the full compatibility run to `Tests/Compatibility/database/compatibility.json` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10.4).
3. A dry run: `release.yml` with the input `dry-run` on `main`. It runs §9.4 steps 1–9 and stops before publishing.
4. After the preparation pull request merges, the release manager tags its merge commit: `git tag -a v<version> -m "APKRun <version>"` and `git push origin v<version>`.

### 9.4 The release job

`release.yml` runs on the tag in the `release` environment on `apkrun-lab` ([build-system.md](build-system.md) §15.1). The job waits for a maintainer's approval, then:

| # | Step | Tool |
|---|---|---|
| 1 | Clean checkout of the tag with an empty DerivedData. The tag must be on `main`, `MARKETING_VERSION` must equal the tag version, the tree must not be dirty, and `ci.yml` must have passed on this commit | `git merge-base --is-ancestor`, [build-system.md](build-system.md) §14 |
| 2 | Compute the build number (§8.2) | release job |
| 3 | Build the third-party libraries from the lock hash cache and the guest APKs | `scripts/build-third-party.sh virgl-runtime`, `scripts/build-guest.sh` |
| 4 | Assemble APKRun.app, Release configuration, with `CURRENT_PROJECT_VERSION=<build>` and `APKRUN_CHANNEL=stable` | `scripts/release/assemble-bundle.sh` ([build-system.md](build-system.md) §11) |
| 5 | Sign inside out with the Developer ID and a secure timestamp | `scripts/release/sign-bundle.sh` ([build-system.md](build-system.md) §12.3) |
| 6 | Every release check, including R1, R5, and R6 against the published releases | `scripts/release/check-release-build.sh` ([build-system.md](build-system.md) §3.1) |
| 7 | Notarize and staple the app, then assess it | `scripts/release/notarize.sh` ([build-system.md](build-system.md) §12.6) |
| 8 | Build, sign, notarize, and staple `APKRun-<version>.dmg` | `scripts/release/make-dmg.sh` |
| 9 | Make the Sparkle archive `APKRun-<version>.zip` from the stapled app, with its SHA-256 | `ditto -c -k --sequesterRsrc --keepParent` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.3) |
| 10 | Sign the archive, make deltas from the last three releases, add the beta item, and sign the appcast | `scripts/release/appcast.py add --channel beta [--critical]` (wraps `sign_update` and `generate_appcast`) |
| 11 | Upload the archive, deltas, DMG, rendered release notes (`release-notes/<version>.html`), and the appcast | `scripts/release/publish.py` |
| 12 | Create a GitHub pre-release on the tag with the zip, the DMG, `components.json`, and `SHA256SUMS` | `gh release create --prerelease` |

- `APKRUN_CHANNEL` is `stable` in every tag build, because the candidate that goes to beta is the build that is later promoted unchanged ([build-system.md](build-system.md) §5).
- R5 and R1 read the `components.json` attached to earlier GitHub releases and the published appcast. That is why step 12 attaches it.
- A failure in any step stops the job before anything is published. Steps 11 and 12 run only after every earlier step passed.
- The job uploads its logs and the unsigned and signed bundles as artifacts. Release candidate artifacts are kept permanently ([build-system.md](build-system.md) §15.1).

### 9.5 Beta and promotion to stable

After the job, the candidate is on the beta channel. The release manager then runs [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.1 steps 3–6 and records each result in the release issue.

The candidate may be promoted when all of these hold:

| Condition | Value |
|---|---|
| test-strategy §9.1 steps 1–6 | passed and recorded in the release issue, including the smoke matrix with the current and the previous stable image (R2) |
| time on beta | at least 3 days for a MAJOR or MINOR release, at least 1 day for a PATCH release, no minimum for a critical fix (§9.6) |
| blocking issues | no open issue with the label `release-blocker` for this version |
| newer builds | the candidate's build is the highest published build |

Promotion is `release.yml` with the input `promote` and the version, run on `main`. The approver checks the release issue before approving. The job:

1. changes the item to a stable item: removes `<sparkle:channel>`, sets `pubDate` to now (phasing counts from it), and adds `phasedRolloutInterval` 86400 unless the item is critical (`appcast.py promote`);
2. signs and publishes the appcast (`publish.py`);
3. marks the GitHub release as the latest release, and points the website download at the DMG.

The archive is not rebuilt or re-signed. A candidate that fails a condition is not promoted. The fix ships as the next patch version, which becomes the new candidate. Stable users then go from the previous stable version directly to it.

### 9.6 Critical security fixes

- A security fix ships as a new PATCH version through §9.3–§9.5 with `appcast.py add --critical`. The item carries `<sparkle:criticalUpdate sparkle:version="<build>"/>` with its own build number.
- Every later item carries the same element with the build of the latest security fix, so an install older than the fix still gets a critical update ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.3).
- The candidate still goes to beta first and still runs test-strategy §9.1 step 4, but it needs no minimum time on beta. Critical items are not phased.
- Security and privacy checks are never waived ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §8.1).

### 9.7 Before the pipeline is complete

The release job grows with the tasks that add its steps: #057 step 12 adds the workflow with the archive, the appcast, the publishing scripts, and the scriptable rules R1, R5, and R6 ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §13). It runs only as a dry run and publishes nothing. #088 adds notarization, the DMG, the `dry-run` input, and turns on publishing. #087 adds the image feed. A step whose task is not done is skipped, and the release issue says so.

| Versions | How a release is made |
|---|---|
| v0.1–v0.4 (before #057) | There is no release workflow. The tag (§8.3) and the milestone review issue are the release ([../04-plan/roadmap.md](../04-plan/roadmap.md) §4 item 8). When testers need a build, the release manager builds the Release configuration from a clean checkout of the tag on a lab Mac, signs it with the Developer ID when the certificate is configured, and attaches the zip to a GitHub pre-release. There is no appcast; testers install by hand |
| v0.5 (after #057, before #088) | `release.yml` runs §9.4 steps 1–6 and 9–12 as a dry run: it writes the signed archive and the signed appcast to `build/release/` and publishes nothing. The app is Developer ID signed but not notarized, and there is no DMG. A downloaded app that is not notarized does not open, so testers get builds as in v0.1–v0.4. The first release that users get through Sparkle is the first one after #088 |
| v1.0 (after #088 and #087) | every step of §9.4, §9.5, and §10 ([../04-plan/issues/M12-v1-release.md](../04-plan/issues/M12-v1-release.md) #094) |

Until #087 is done, no Android image is published (§10).

### 9.8 Key and certificate changes

- The Sparkle EdDSA key and the Developer ID certificate never change in the same release (R6). `check-release-build.sh` compares both with the previous release.
- **Sparkle key.** The release that introduces a new key is signed with the old key and carries the new public key. The next releases are signed with the new key ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §10).
- **Developer ID.** A renewed certificate from the same team ships in a release signed with the unchanged Sparkle key.
- **Image key.** A new image key ID is added to `ImageTrustStore` in an APKRun release. The feed and manifests switch to the new key only after that release is stable. A compromised key ID is removed in an APKRun release, and the feed and manifests are signed again with the new key ([../01-architecture/security-model.md](../01-architecture/security-model.md) §7).

---

## 10. Image release

### 10.1 What is released

- Only `kind: apkrun` bundles built from source, from the `user` variant, are published. The prebuilt Cuttlefish image is never published ([legal-and-licensing.md](legal-and-licensing.md) §2, [../02-design/android-image.md](../02-design/android-image.md) §2.3).
- The image version is `YYYY.MM.N-ar<counter>-arm64` ([environment-setup.md](environment-setup.md) §5.7). `N` starts at 0 in each month and counts every image release of that month.
- Each image release has an issue `Android <YYYY.MM.N>` with the label `image-release`, which holds the [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.3 results.

### 10.2 Release calendar (R7)

| When | Release |
|---|---|
| January, April, July, October | the quarterly stable image, with the latest Android security patch level and tzdata. The candidate is built after the monthly Android security bulletin and reaches stable in the same month |
| within 7 days of a fix being available | an extra release for a critical security fix (`critical: true`) |
| as soon as the change is known | an extra release for a tzdata change that takes effect within 60 days in any zone ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.11) |

The quarterly release also carries any Guest agent changes merged since the last image.

### 10.3 Steps

1. **Tag.** The release manager tags the `main` commit to build from: `image-<YYYY.MM.N>`.
2. **Build.** On the image build machine, the release manager runs `scripts/aosp/build-product.sh --revision <commit> --variant user` ([build-system.md](build-system.md) §9). The release keys never leave that machine ([environment-setup.md](environment-setup.md) §5.6). The output is `apkrun_arm64-img-ar<counter>.zip` with `build-info.json`.
3. **Hand over.** The release manager uploads the zip to the private release storage and notes its SHA-256 in the image release issue.
4. **Candidate.** `image-release.yml` with the action `candidate` and the inputs artifact URL, SHA-256, image version, and `minimumRuntimeVersion`. On `apkrun-lab`, after approval, it downloads and checks the zip, builds the bundle with `python3 -m apkrun_image bundle` and the release image key, runs `check-release-build.sh` on the bundle, packs the `.aar` ([build-system.md](build-system.md) §10.2), and keeps the bundle and archive as artifacts.
5. **Test.** The steps of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.3 run on the reference Mac with the candidate. Each result goes into the image release issue.
6. **Beta.** `image-release.yml` with the action `beta`. It uploads the archive and adds the entry to the beta feed (`image-feed.py add --channel beta`), with `rolloutPercent` 100.
7. **Stable.** After at least 3 days on beta with no open `release-blocker`, the action `stable` adds the entry to the stable feed (`image-feed.py promote`) with `rolloutPercent` 25. A critical entry goes to 100 at once, because clients ignore the rollout for it anyway (C6).
8. **Rollout.** After 7 more days with no `release-blocker`, the action `rollout` sets `rolloutPercent` to 100.

- The beta feed also lists every entry of the stable feed, so a beta user never misses a stable image.
- Release notes are `docs/releases/android-<YYYY.MM.N>.md`, published as `android/<YYYY.MM.N>.html` (the `releaseNotesURL` of the entry).
- The published corresponding source for GPL and LGPL components is uploaded in step 6 ([legal-and-licensing.md](legal-and-licensing.md) §7).

### 10.4 Feed operations

`scripts/release/image-feed.py` is the only tool that writes a feed ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1):

| Command | Does |
|---|---|
| `add --channel <c> --archive <aar>` | adds an entry from the bundle manifest (the manifest's `imageVersion`, `requirements`, and `userdata` must equal the entry) |
| `promote --version <v>` | copies a beta entry to the stable feed |
| `rollout --version <v> --percent <n>` | changes `rolloutPercent` |
| `remove --channel <c> --version <v>` | removes an entry |
| `resign --channel <c>` | signs the feed again with no content change |

- Every command writes a new `sequence` (one higher than the last), sets `generatedAt` to now and `expiresAt` to `generatedAt + 30 days`, and signs `feed.json` into `feed.json.sig`. It refuses output larger than the client limits (1 MiB and 4 KiB).
- `add` and `promote` refuse an entry whose `minimumRuntimeVersion` is above the highest APKRun version on the target channel (R3), and an `imageVersion` that is not above every earlier one.
- A bad image is removed from the feed with `remove`, and a fixed image ships with a higher version. Versions are never reused. Macs that already installed the bad image get the fixed one as a normal update.

### 10.5 Weekly re-signing

`image-feed-resign.yml` runs every Monday at 03:00 UTC on `ubuntu-latest` in the `release` environment. Like every `release` job, it waits for a maintainer's approval, which a maintainer gives the same day. It runs `image-feed.py resign` for both channels and publishes them. Clients stop using a feed 30 days after `generatedAt` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1), so one missed week does no harm. A failed run opens a `nightly-failure` issue and is fixed within one working day.

---

## 11. Parallel work

### 11.1 Rules

- One task, one owner, one branch at a time (§2.3). Two agents never push to the same branch.
- Each agent works in its own clone or `git worktree`, with its own `APKRUN_HOME` for local runs.
- Start only tasks whose dependencies are done (§2.1). [../04-plan/roadmap.md](../04-plan/roadmap.md) §1.4 lists the tracks that can run in parallel, and [../04-plan/issues/README.md](../04-plan/issues/README.md) §3 lists every dependency.
- Stay in the task's `Modules / paths`. A change in a path that the task does not list is a sign of scope creep, or of a conflict with another task. Comment on the other task's issue before touching its paths.
- Hand work over in the issue. The comment says the state, the next step, and the open questions. Then unassign.

### 11.2 Stacked work

A task may start before its dependency merges only when the dependency's pull request is in review:

- Branch from the dependency's branch and open the pull request as a draft, based on that branch.
- After the dependency merges, rebase onto `main` and change the base to `main`.
- The stacked pull request is not marked ready while its base is not `main`.

### 11.3 Shared files

| File | Rule when two pull requests change it |
|---|---|
| `*.pb.swift`, the Kotlin protobuf output, the generated error catalog | never resolve by hand. Rebase, then regenerate ([build-system.md](build-system.md) §4) |
| `Package.resolved` | rebase, then `swift package resolve` |
| `errors.json` | keep both sets of entries. A duplicate code fails `codegen` |
| `ThirdParty/ThirdParty.lock.json` | keep both entries; `scripts/check-lock.sh` must pass after the rebase |
| `Package.swift`, `project.yml` | keep both changes; `scripts/check-module-deps.sh` must pass |
| `Localizable.xcstrings` | resolve in Xcode's String Catalog editor, not as text |
| `Tests/Compatibility/database/compatibility.json` | keep both entries; `scripts/check-compatibility-db.sh` must pass |
| milestone files, [../04-plan/issues/README.md](../04-plan/issues/README.md) §3, [../04-plan/traceability.md](../04-plan/traceability.md) | keep both rows; task numbers come from GitHub (§2.4) |
| [../04-plan/risks.md](../04-plan/risks.md), [../04-plan/open-questions.md](../04-plan/open-questions.md) | keep both results; a conflicting result for the same risk or question goes to a maintainer |
| ADRs | the second pull request to merge takes the next free number and renames its file |

### 11.4 Shared machines

- Lab Macs run one job at a time. Label `run-t2` only when the pull request is ready (§5.1); a label never enables unreviewed PR code on a persistent runner.
- The reference Mac is also a lab Mac. Gate checks and release testing have priority on it. A release manager may pause the T2 queue during release testing.
- The AOSP builder is shared. Nightly `aosp-build` has priority. A long manual build is announced in the task's issue.

---

## 12. Experiments

Experiments answer a question quickly, without the rules for production code (NFR-DEV-05).

### 12.1 Where they live

| Place | Use |
|---|---|
| `experiment/<name>` branch | a spike that never merges. Examples `experiment/vz-linux-boot`, `experiment/android-boot`, `experiment/android-virgl` |
| `Experiments/<name>/` on `main` | a spike that others need to run again, for example a reference measurement |

### 12.2 Rules

- Production targets never import or link anything from `Experiments/`. `scripts/check-module-deps.sh` fails on it.
- No test imports `Experiments/`, and CI does not build or run it ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) P12).
- Experiment code needs only the security rules and the no-secrets rule ([coding-conventions.md](coding-conventions.md) §1, §13). `scripts/check-format.sh` and `scripts/check-todos.sh` skip `Experiments/`. The secret and key checks do not.
- Commit messages follow §4.2 on experiment branches too.
- An experiment added to `Experiments/` needs a pull request with one approval. The review checks only the rules of this section.
- Each `Experiments/<name>/` has a `README.md` with the question, the task, how to run it, and the result.

### 12.3 From experiment to production

1. Record the result where the task's Notes say: the design verification log, [../04-plan/risks.md](../04-plan/risks.md), or an ADR.
2. Reimplement the minimum cleanly in the production module, in a task pull request that follows §5 and §6. Do not copy the prototype code directly into permanent architecture without review.
3. Delete the experiment from `Experiments/` when production covers it, or when the question is answered and nobody needs to run it again.
