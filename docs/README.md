# APKRun Documentation

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [../README.md](../README.md), [../AGENTS.md](../AGENTS.md) |

This directory is the specification of APKRun. Code implements what these documents say. When the code has to differ, the documents are changed in the same pull request ([../AGENTS.md](../AGENTS.md) §14).

---

## 1. Map

### 1.1 Product (`00-product/`)

| Document | What it answers |
|---|---|
| [vision.md](00-product/vision.md) | What APKRun is for, and the user experience it aims at |
| [scope.md](00-product/scope.md) | Platforms, what v1 includes, non-goals, compatibility levels, scope discipline |
| [requirements.md](00-product/requirements.md) | Functional (FR-*) and non-functional (NFR-*) requirements with priority, version, and tasks |
| [glossary.md](00-product/glossary.md) | Terms used everywhere else |

### 1.2 Architecture (`01-architecture/`)

| Document | What it answers |
|---|---|
| [overview.md](01-architecture/overview.md) | The four layers, the component diagram, and the main flows (frames, input, launch, install, update) |
| [modules.md](01-architecture/modules.md) | Repository layout, module ownership, the allowed dependency graph, naming (normative) |
| [process-model-and-ipc.md](01-architecture/process-model-and-ipc.md) | Processes, XPC, sessions, and who talks to whom |
| [state-machines.md](01-architecture/state-machines.md) | VM, runtime, session, DisplayPool, install, and update state machines |
| [filesystem-layout.md](01-architecture/filesystem-layout.md) | Every host path APKRun reads or writes, and the guest disks |
| [security-model.md](01-architecture/security-model.md) | Trust boundaries, signing, XPC authorization, guest capabilities |
| [decisions/](01-architecture/decisions/README.md) | Architecture decision records ADR-0001 to ADR-0017 |

### 1.3 Design (`02-design/`)

One document per subsystem. Each has the same shape: responsibilities, types, behavior, failure handling, tests, open items, and a verification log.

| Document | Subsystem | First tasks |
|---|---|---|
| [vm.md](02-design/vm.md) | Virtualization.framework VM, devices, serial log, test Linux guest | #002–#007 |
| [android-image.md](02-design/android-image.md) | Cuttlefish artifacts, image manifest, disks, boot, host-service substitution, the APKRun AOSP product, image migration | #008–#014, #035, #058 |
| [graphics.md](02-design/graphics.md) | virtio-gpu device, virglrenderer, ANGLE, Metal scanout | #018–#023 |
| riftvm-analysis.md | RiftVM prototype analysis; written by #018 | #018 |
| [input.md](02-design/input.md) | Mouse, keyboard, scroll, IME, and routing to displays | #024, #025, #071 |
| [display-and-windowing.md](02-design/display-and-windowing.md) | DisplayPool, one display per window, IOSurface frames, Retina and resize | #026–#030, #067, #068 |
| [guest-protocol.md](02-design/guest-protocol.md) | Protobuf protocol, handshake, versioning, channels, transports | #033, #034 |
| [guest-components.md](02-design/guest-components.md) | Guest Agent, APKRun IME, Store Agent, `apkrun_vsockd` | #072, #034, #036 |
| [runtime-daemon.md](02-design/runtime-daemon.md) | apkrund: lifecycle, idle policy, sleep and wake, XPC API, provisioning | #031, #032, #066, #069 |
| [package-store.md](02-design/package-store.md) | Package store, APK inspection, signature verification, install, uninstall | #027, #036, #041, #042, #073 |
| [update-system.md](02-design/update-system.md) | Authorities, providers, scheduler, gentle updates, health checks, rollback | #037–#043, #050–#052, #074 |
| [wrapper.md](02-design/wrapper.md) | Thin wrappers: bundle layout, launcher, generator, signing, icons, lifecycle, `apkrun wrap` | #044–#049, #055, #056, #075, #076, #089 |
| [desktop-integration.md](02-design/desktop-integration.md) | Clipboard, notifications, links, files, audio, microphone, locale and time | #053, #054, #080–#085 |
| [host-ui.md](02-design/host-ui.md) | APKRun.app, the add flow, settings, the menu bar, localization | #077–#079, #086, #092 |
| [cli.md](02-design/cli.md) | The `apkrun` command | #017, #027, #075 |
| [diagnostics.md](02-design/diagnostics.md) | Logging, errors, markers, health, `apkrun doctor`, diagnostics bundles, performance harness, compatibility database | #061, #059, #060, #070, #090 |
| [runtime-maintenance.md](02-design/runtime-maintenance.md) | APKRun updates (Sparkle), image updates and distribution, compatibility between versions | #057, #058, #087 |

### 1.4 Reference (`03-reference/`)

Exact formats. Code and tests are written against these documents.

| Document | Format |
|---|---|
| [error-catalog.md](03-reference/error-catalog.md) | Every error domain and case, with the message and the remediation |
| [configuration.md](03-reference/configuration.md) | Every setting, default, and where it is stored |
| [runtime-api.md](03-reference/runtime-api.md) | The XPC `RuntimeAPI` between clients and apkrund |
| [wrapper-json.md](03-reference/wrapper-json.md) | `wrapper.json` inside wrappers |
| [package-metadata-json.md](03-reference/package-metadata-json.md) | Package store `metadata.json` |
| [android-image-manifest.md](03-reference/android-image-manifest.md) | `AndroidImageManifest` of a Cuttlefish artifact set |
| [runtime-image-manifest.md](03-reference/runtime-image-manifest.md) | Runtime image bundle manifest and image feed |
| [direct-provider-manifest.md](03-reference/direct-provider-manifest.md) | The JSON served to the Direct update provider |

### 1.5 Plan (`04-plan/`)

| Document | What it answers |
|---|---|
| [roadmap.md](04-plan/roadmap.md) | Milestones, the critical path, gates G1–G9, versions and their Definitions of Done, milestone reviews |
| [issues/README.md](04-plan/issues/README.md) | The task index (#001–#097), the task entry format, and the rules for working a task. The milestone files hold every task in full |
| [test-strategy.md](04-plan/test-strategy.md) | Test tiers T0–T3, fixture apps, CI and lab runs, gate tests |
| [risks.md](04-plan/risks.md) | Technical and project risks, with mitigation, fallback, and the task that settles each |
| [open-questions.md](04-plan/open-questions.md) | Undecided items, each with a working default |
| [traceability.md](04-plan/traceability.md) | Requirements → tasks → design → verification |

### 1.6 Development (`05-development/`)

| Document | What it answers |
|---|---|
| [environment-setup.md](05-development/environment-setup.md) | Setting up a development Mac and the Linux AOSP builder |
| [build-system.md](05-development/build-system.md) | SwiftPM and XcodeGen targets, third-party builds, the lock file, CI, signing |
| [coding-conventions.md](05-development/coding-conventions.md) | Swift, C/Objective-C++, Kotlin, Rust, and Python rules; errors, logging, concurrency |
| [workflow.md](05-development/workflow.md) | Branches, commits, reviews, merges, and parallel work by several agents |
| [legal-and-licensing.md](05-development/legal-and-licensing.md) | Licenses of APKRun and its components, redistribution of Android images |

### 1.7 Release notes (`releases/`)

The directory is created by the first release. It holds one file per release, in English:

| File | Written by |
|---|---|
| `releases/<version>.md` | the preparation pull request of an APKRun release ([workflow.md](05-development/workflow.md) §9.3) |
| `releases/android-<YYYY.MM.N>.md` | the release of a runtime image ([workflow.md](05-development/workflow.md) §10.3) |

### 1.8 User documentation (`06-user/`)

User-facing guides, in English. Unlike the rest of `docs/`, they describe behavior for users, not for implementers. #025 creates the directory with `06-user/keyboard-and-text-input.md` (key mode, shortcuts, and the limits before the APKRun IME), and #071 updates that page. A task that adds user-visible behavior adds or updates the matching page in the same pull request.

---

## 2. Reading order

| You are | Read |
|---|---|
| New to the project | [vision.md](00-product/vision.md) → [scope.md](00-product/scope.md) → [overview.md](01-architecture/overview.md) → [roadmap.md](04-plan/roadmap.md) |
| About to implement a task | [../AGENTS.md](../AGENTS.md) → the task entry in [issues/](04-plan/issues/README.md) → the design sections it links → [coding-conventions.md](05-development/coding-conventions.md) → [workflow.md](05-development/workflow.md) |
| Setting up a machine | [environment-setup.md](05-development/environment-setup.md) → [build-system.md](05-development/build-system.md) |
| Reviewing a pull request | the task entry → the design sections it links → [../AGENTS.md](../AGENTS.md) §12 (Definition of done) |
| Changing the architecture | [decisions/README.md](01-architecture/decisions/README.md) → [modules.md](01-architecture/modules.md) → [traceability.md](04-plan/traceability.md) |

---

## 3. Conventions

- **Language.** All documents are in English.
- **Header.** Each document starts with a title and a table with `Status` and `Related`.
  - `Baseline` means the document is agreed and implementation follows it.
  - `Design baseline` means the same for a design whose details are expected to change during implementation. The verification log records the changes.
- **Numbering.** Sections are `## 1.` and subsections `### 1.1`. References to sections are written `§N` after a link to the document, for example [vm.md](02-design/vm.md) §6. A bare `§N` refers to the current document, except in a task entry, where it refers to the first document of the entry's Design row ([issues/README.md](04-plan/issues/README.md) §2).
- **References.** Cite current requirements, task numbers, linked design sections, risks, open questions, and accepted ADRs. [traceability.md](04-plan/traceability.md) connects requirements to implementation and verification.
- **IDs.**

  | Prefix | Meaning | Defined in |
  |---|---|---|
  | `#NNN` | task | [issues/README.md](04-plan/issues/README.md) |
  | `FR-*`, `NFR-*` | requirement | [requirements.md](00-product/requirements.md) |
  | `G1`–`G9` | gate | [roadmap.md](04-plan/roadmap.md) §2 |
  | `M0`–`M12` | milestone | [roadmap.md](04-plan/roadmap.md) §1.2 |
  | `R-NN` | risk | [risks.md](04-plan/risks.md) |
  | `OQ-NN` | open question | [open-questions.md](04-plan/open-questions.md) |
  | `ADR-NNNN` | architecture decision | [decisions/](01-architecture/decisions/README.md) |
  | `CF-NN` | deviation from standard Cuttlefish | [android-image.md](02-design/android-image.md) §13 |
  | `SR-NN` | security review item | [security-model.md](01-architecture/security-model.md) §9 |
  | `T0`–`T3` | test tier | [test-strategy.md](04-plan/test-strategy.md) |

  IDs are never reused. A removed item keeps its ID with a note.
- **Normative words.** "must", "never", and "only" are requirements. "should" is a default that needs a reason to break. Examples are marked as examples.
- **Code in documents.** Type and function names in design documents are the names the code uses. A rename in code renames them in the documents in the same pull request.

---

## 4. Changing the documents

| Change | Also update |
|---|---|
| A requirement | [requirements.md](00-product/requirements.md) and [traceability.md](04-plan/traceability.md) §2 |
| A task (added, split, moved, dependencies) | the milestone file, [issues/README.md](04-plan/issues/README.md) §3, [roadmap.md](04-plan/roadmap.md) §1.2 when the milestone changes, and [traceability.md](04-plan/traceability.md) §3 |
| An architectural decision | a new ADR, then the affected architecture and design documents |
| A persisted format | the reference document, its version number, and the migration described in the design |
| A risk or question settled | [risks.md](04-plan/risks.md) or [open-questions.md](04-plan/open-questions.md), and the design documents that named the default |
| A design clarification that affects multiple documents | the canonical design documents; add an ADR when required by [decisions/README.md](01-architecture/decisions/README.md) |
