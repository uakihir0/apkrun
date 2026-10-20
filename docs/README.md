# APKRun Documentation

This directory is the specification of APKRun. Code does what these documents say. When code has to differ, change the document in the same commit ([../AGENTS.md](../AGENTS.md) §14).

---

## 1. Map

### 1.1 Product (`00-product/`)

| Document | What it answers |
|---|---|
| [vision.md](00-product/vision.md) | What APKRun is for, and the user experience it aims at |
| [scope.md](00-product/scope.md) | Platforms, what v1 includes, non-goals, scope discipline |
| [requirements.md](00-product/requirements.md) | Functional (`FR-*`) and non-functional (`NFR-*`) requirements, with version and tasks |
| [glossary.md](00-product/glossary.md) | Terms used everywhere else |

### 1.2 Architecture (`01-architecture/`)

| Document | What it answers |
|---|---|
| [overview.md](01-architecture/overview.md) | The layers, the components, and the main flows |
| [modules.md](01-architecture/modules.md) | Repository layout, module owners, the allowed dependency graph, naming. CI parses it. |
| [process-model-and-ipc.md](01-architecture/process-model-and-ipc.md) | Processes, XPC, sessions, and who talks to whom |
| [state-machines.md](01-architecture/state-machines.md) | VM, runtime, session, DisplayPool, install, and update state machines |
| [filesystem-layout.md](01-architecture/filesystem-layout.md) | Every host path APKRun reads or writes, and the guest disks |
| [security-model.md](01-architecture/security-model.md) | Trust boundaries, signing, XPC authorization, guest capabilities |
| [decisions/](01-architecture/decisions/README.md) | Architecture decision records (ADRs) |

### 1.3 Design (`02-design/`)

One document per subsystem. Each says what the subsystem does and must do: responsibilities, types, behavior, failure handling, errors, logging, tests, and open items.

| Document | Subsystem |
|---|---|
| [vm.md](02-design/vm.md) | Virtualization.framework VM, devices, serial log, test Linux guest |
| [android-image.md](02-design/android-image.md) | Cuttlefish artifacts, image manifest, disks, boot, host-service substitution, the APKRun AOSP product |
| [graphics.md](02-design/graphics.md) | virtio-gpu device, virglrenderer, ANGLE, Metal scanout |
| [riftvm-analysis.md](02-design/riftvm-analysis.md) | What APKRun took from the RiftVM GPU prototype |
| [input.md](02-design/input.md) | Mouse, keyboard, scroll, IME, routing to displays |
| [display-and-windowing.md](02-design/display-and-windowing.md) | DisplayPool, one display per window, IOSurface frames, Retina and resize |
| [guest-protocol.md](02-design/guest-protocol.md) | Protobuf protocol, handshake, versions, channels, transports |
| [guest-components.md](02-design/guest-components.md) | Guest Agent, APKRun IME, Store Agent, `apkrun_vsockd` |
| [runtime-daemon.md](02-design/runtime-daemon.md) | apkrund: lifecycle, idle policy, sleep and wake, XPC server, provisioning |
| [package-store.md](02-design/package-store.md) | Package store, APK inspection, signature checks, install, uninstall |
| [update-system.md](02-design/update-system.md) | Update authorities, providers, scheduler, gentle updates, health checks, rollback |
| [wrapper.md](02-design/wrapper.md) | Thin wrappers: bundle layout, launcher, generator, signing, icons, lifecycle |
| [desktop-integration.md](02-design/desktop-integration.md) | Clipboard, notifications, links, files, audio, microphone, locale and time |
| [host-ui.md](02-design/host-ui.md) | APKRun.app, the add flow, settings, the menu bar, localization |
| [cli.md](02-design/cli.md) | The `apkrun` command |
| [diagnostics.md](02-design/diagnostics.md) | Logging, errors, markers, health, `apkrun doctor`, diagnostics bundles |
| [runtime-maintenance.md](02-design/runtime-maintenance.md) | APKRun updates (Sparkle), Android image updates, compatibility between versions |

### 1.4 Reference (`03-reference/`)

Exact formats. Code and tests are written against these documents.

| Document | Format |
|---|---|
| [error-catalog.md](03-reference/error-catalog.md) | Every error domain and case, with message and remediation. Its tables are generated from `errors.json`. |
| [configuration.md](03-reference/configuration.md) | Every setting, its default, and where it is stored |
| [runtime-api.md](03-reference/runtime-api.md) | The XPC `RuntimeAPI` between clients and apkrund |
| [wrapper-json.md](03-reference/wrapper-json.md) | `wrapper.json` inside wrappers |
| [package-metadata-json.md](03-reference/package-metadata-json.md) | Package store `metadata.json` |
| [android-image-manifest.md](03-reference/android-image-manifest.md) | `AndroidImageManifest` of a Cuttlefish artifact set |
| [runtime-image-manifest.md](03-reference/runtime-image-manifest.md) | Runtime image bundle manifest and image feed |
| [direct-provider-manifest.md](03-reference/direct-provider-manifest.md) | The JSON served to the Direct update provider |

### 1.5 Plan (`04-plan/`)

| Document | What it answers |
|---|---|
| [roadmap.md](04-plan/roadmap.md) | Milestones, working order, gates G1–G9 and their results, versions |
| [issues/README.md](04-plan/issues/README.md) | The task index, the task entry format, and old task numbers. The milestone files hold every task. |
| [test-strategy.md](04-plan/test-strategy.md) | Test tiers T0–T3, fixtures, gate tests, manual checklists |
| [risks.md](04-plan/risks.md) | Technical risks, with fallback and the task that settles each |
| [open-questions.md](04-plan/open-questions.md) | Undecided items, each with a working default |

### 1.6 Development (`05-development/`)

| Document | What it answers |
|---|---|
| [environment-setup.md](05-development/environment-setup.md) | Setting up a development Mac and the Linux AOSP builder |
| [build-system.md](05-development/build-system.md) | SwiftPM and XcodeGen targets, third-party builds, the lock file, CI, signing |
| [coding-conventions.md](05-development/coding-conventions.md) | Swift, C/Objective-C++, Kotlin, Rust, and Python rules; errors, logging, concurrency |
| [workflow.md](05-development/workflow.md) | Issues, labels, branches, commits, closing a task, releases |
| [legal-and-licensing.md](05-development/legal-and-licensing.md) | Licenses of APKRun and its components, redistribution of Android images |

### 1.7 User documentation (`06-user/`)

Guides for users, not implementers. A task that adds user-visible behavior adds or updates the matching page. Release notes go to `releases/<version>.md` when the first release is made ([05-development/workflow.md](05-development/workflow.md) §9).

---

## 2. Reading order

| You are | Read |
|---|---|
| New to the project | [vision.md](00-product/vision.md) → [overview.md](01-architecture/overview.md) → [roadmap.md](04-plan/roadmap.md) |
| Implementing a task | [../AGENTS.md](../AGENTS.md) §2 → the task entry → only the design sections the entry lists → [coding-conventions.md](05-development/coding-conventions.md) |
| Setting up a machine | [environment-setup.md](05-development/environment-setup.md) → [build-system.md](05-development/build-system.md) |
| Changing the architecture | [decisions/README.md](01-architecture/decisions/README.md) → [modules.md](01-architecture/modules.md) |

---

## 3. Conventions

- **Language.** English.
- **One fact, one place.** Each fact is written once. Other documents link to it instead of repeating it.
- **What, not how it went.** Design and reference documents describe what the system does and must do. They hold no history, no verification evidence, no progress reports, and no implementation step lists. Steps are in the task entries. Evidence is in commit messages and pull requests.
- **Status lives in GitHub.** Whether a task is open, done, or waiting for verification is the state of its GitHub issue ([05-development/workflow.md](05-development/workflow.md) §2). Documents carry no progress dashboards. The only results in documents are the gate results in [roadmap.md](04-plan/roadmap.md) §2.
- **Start of a document.** A title and one short paragraph that says what the document covers.
- **Section numbers are stable IDs.** Sections are `## 1.` and subsections `### 1.1`. Code and other documents cite them, so a section is never renumbered. When a section is removed, its number is not reused, even if that leaves a gap.
- **References.** Cite a section as a link followed by `§N`: [vm.md](02-design/vm.md) §6. A bare `§N` refers to the current document. Task entries always name the document.
- **IDs.**

  | ID | Meaning | Defined in |
  |---|---|---|
  | `#N` | task, equal to its GitHub issue number | [issues/README.md](04-plan/issues/README.md) §3 |
  | `FR-*`, `NFR-*` | requirement | [requirements.md](00-product/requirements.md) |
  | `G1`–`G9` | gate | [roadmap.md](04-plan/roadmap.md) §2 |
  | `M0`–`M12` | milestone | [roadmap.md](04-plan/roadmap.md) §1 |
  | `R-NN` | risk | [risks.md](04-plan/risks.md) |
  | `OQ-NN` | open question | [open-questions.md](04-plan/open-questions.md) |
  | `ADR-NNNN` | architecture decision | [decisions/](01-architecture/decisions/README.md) |
  | `CF-NN` | deviation from standard Cuttlefish | [android-image.md](02-design/android-image.md) §13 |
  | `SR-NN` | security review item | [security-model.md](01-architecture/security-model.md) §9 |
  | `T0`–`T3` | test tier | [test-strategy.md](04-plan/test-strategy.md) §2 |
  | `C<nn>-<n>` | manual check | [test-strategy.md](04-plan/test-strategy.md) §8 |
  | `IR-NNNN` | old implementation review record, frozen (§5) | git history |

  IDs are never reused. A settled risk or question keeps its row with the outcome.
- **Normative words.** "must", "never", and "only" are requirements. "should" is a default that needs a reason to break.
- **Names.** Type and function names in documents are the names the code uses. A rename in code renames them in the documents in the same commit.
- **Size.** Long text is skimmed and misread. Keep a task entry under about 4 KB (a closed one under 1.5 KB); split a task whose entry needs more than about 8 KB before starting it. Design and reference documents are read by section, not in full: a task lists the sections to read, so each numbered section must make sense on its own. Prefer a table to prose, and a link to a copy.

---

## 4. Changing the documents

| Change | Also update |
|---|---|
| A requirement | [requirements.md](00-product/requirements.md), including its Tasks column |
| A task (added, split, moved, dependencies) | the milestone file, the index in [issues/README.md](04-plan/issues/README.md) §3, and the GitHub issue (`scripts/dev/sync-task-issues.py`) |
| An architectural decision | a new ADR first, then the affected documents |
| A persisted format | the reference document, its version number, and the migration in the design |
| A risk or question settled | its row in [risks.md](04-plan/risks.md) or [open-questions.md](04-plan/open-questions.md), and the documents that named the default |
| Behavior that differs from the design | the design section, in the same commit as the code |

Before committing a document change, run `scripts/check-docs.sh`. It checks that links, anchors, `§N` references (also from code comments), task numbers, and IDs resolve.

---

## 5. History

The documents were rewritten on 2026-10-21 to remove history and evidence. Two kinds of old references remain in code comments and commit messages:

- **Old task numbers.** Before 2026-10-21, tasks had their own three-digit numbers (`#024`), which differ from the GitHub issue numbers. [issues/README.md](04-plan/issues/README.md) §5 converts them.
- **`IR-NNNN`.** The implementation review records. Read one with `git show dab71d6d:docs/04-plan/implementation-review.md`, and search for `## IR-NNNN`. New work never adds IR records. Decisions go into the design documents or an ADR.

The removed gate evidence (`docs/04-plan/evidence/`) and the traceability matrix are in the same commit.
