# APKRun: Rules for Implementers

These rules apply to everyone who changes this repository, human or AI coding agent. The documents in [docs/](docs/README.md) are the specification. This file lists the rules that are never broken and points to the detailed design.

If a task seems to need a change to one of these rules, stop. A change to a rule needs an ADR ([docs/01-architecture/decisions/README.md](docs/01-architecture/decisions/README.md)), and the ADR has to be accepted before code depends on it.

---

## 1. What APKRun is

APKRun runs Android ARM64 apps on Apple silicon Macs as ordinary, automatically updating Mac apps. It is not an emulator UI. The user never sees Android itself.

```text
Android APK
    ↓
APKRun (package store, updates, wrapper generator)
    ↓
Thin Mac app wrapper (/Applications/App.app)
    ↓
apkrund (per-user LaunchAgent, owns the VM)
    ↓
Android ARM64 guest (AOSP Cuttlefish based) on Virtualization.framework
```

The target command is:

```bash
apkrun wrap app.apk --install # → /Applications/App.app
```

A generated `.app` is a thin, immutable launcher. APK files, Android data, update metadata, runtime images, and all Android state live outside the signed bundle ([docs/02-design/wrapper.md](docs/02-design/wrapper.md), ADR-0009).

Start with [docs/00-product/vision.md](docs/00-product/vision.md) and [docs/01-architecture/overview.md](docs/01-architecture/overview.md).

---

## 2. Before you start a task

1. Pick the task from [docs/04-plan/issues/README.md](docs/04-plan/issues/README.md) §3. Take the lowest-numbered task in the current milestone whose dependencies are done, unless [docs/04-plan/roadmap.md](docs/04-plan/roadmap.md) says otherwise.
2. Read the whole task entry in its milestone file: goal, scope, steps, tests, acceptance criteria, and notes.
3. Read every design section the entry links to. The design wins over your assumptions. If the design looks wrong, see §15.
4. Check the risks and open questions the entry names ([docs/04-plan/risks.md](docs/04-plan/risks.md), [docs/04-plan/open-questions.md](docs/04-plan/open-questions.md)). Build to the working default of an open question. A Decision question that is still open at its deadline task blocks that task.
5. Set up the environment ([docs/05-development/environment-setup.md](docs/05-development/environment-setup.md)).

---

## 3. Platform

| | Supported |
|---|---|
| Host | Apple silicon (arm64) Macs with macOS 27 or later. No Intel Macs and no Rosetta. |
| Guest | Android ARM64, based on AOSP Cuttlefish (`aosp_cf_arm64_only_phone`), Android 17 (API 37) |
| Virtualization | Virtualization.framework with the macOS 27 custom virtio device API (ADR-0002) |
| Graphics | Android GLES → Mesa VirGL → virtio-gpu → virglrenderer → ANGLE → Metal (ADR-0004) |

Vulkan and Google Play are post-v1 tracks (#096, #097). Do not add code for them to v1 tasks.

---

## 4. Product invariants

These hold in every task. Each links to the document that specifies it.

1. **Do not reimplement Android.** Android runs in the guest. Never implement Android APIs on Darwin (ADR-0001).
2. **Use existing standards.** virtio, virtio-gpu, virtio-vsock, `PackageInstaller`, `PackageManager`, Android multi-display, Mesa, VirGL, ANGLE. Do not invent a graphics protocol unless the standard one has been proven unusable.
3. **Do not trim Android before the baseline works.** Launcher, SystemUI, SetupWizard, and unused system apps stay until boot, ADB, GPU, Hello APK, input, and a native window all work.
4. **apkrund owns the VM**, not the GUI. APKRun.app, the menu bar app, the CLI, and wrappers are clients over XPC through `RuntimeClient`. Quitting the GUI does not stop the VM ([docs/02-design/runtime-daemon.md](docs/02-design/runtime-daemon.md), ADR-0007).
5. **The wrapper owns its window**; apkrund renders into shared IOSurfaces (ADR-0006).
6. **One Android display ≈ one Mac window**, managed by `DisplayPool`. Never hard-code app ↔ display mappings ([docs/02-design/display-and-windowing.md](docs/02-design/display-and-windowing.md), ADR-0005).
7. **Four update systems stay separate:** Android apps (UpdateCore and the Store Agent), APKRun itself (Sparkle, ADR-0016), the Android image, and wrapper metadata ([docs/02-design/update-system.md](docs/02-design/update-system.md), [docs/02-design/runtime-maintenance.md](docs/02-design/runtime-maintenance.md)).
8. **One update authority per package** (`apkrun`, `googlePlay`, `external`, `manual`). Two automatic updaters never manage the same package (ADR-0010).
9. **Updates never block launch.** Launch immediately; check, download, and install asynchronously; install only when the app is not in use.
10. **No signature bypass.** Before an update: the package ID matches, `versionCode` increases, the signing lineage is valid, ABI and SDK fit, the split set is consistent, and the hash matches. No flag, setting, or debug path skips a check.
11. **Rollback is binary only.** Keep the previous APK set until the new version passes its health check. Never claim that data migrations can be reversed.
12. **Install only through `PackageInstaller`.** Never copy APKs into Android package directories. `PackageManager` is the source of truth for package identity; host-side APK parsing is for previews only ([docs/02-design/package-store.md](docs/02-design/package-store.md)).
13. **Wrappers are immutable.** An APK update never changes, re-signs, or regenerates a wrapper. A wrapper never contains the Android app's version (G9).
14. **Bundle IDs are deterministic.** `io.apkrun.android.<mapped package>`, never random or per machine ([docs/02-design/wrapper.md](docs/02-design/wrapper.md) §4.1).

---

## 5. Development order and gates

The order is fixed:

```text
Linux VM → Android boot → ADB → APK install → virtio-gpu → Android rendering → input
→ single native window → multi-display → apkrund → Guest Agent → custom Android image
→ store → automatic updates → Mac wrapper → desktop integration → Vulkan → optional Google integration
```

Do not skip ahead because a later task looks easier or more interesting. The gates G1–G9 and their pass conditions are in [docs/04-plan/roadmap.md](docs/04-plan/roadmap.md) §2.

- Do not declare the core architecture validated before **G3** (SurfaceFlinger renders through virtio-gpu to Metal).
- Do not declare the product concept validated before **G9** (the wrapper stays unchanged while the APK updates automatically).

---

## 6. Architecture rules

### 6.1 Modules

- The module set, the owner of each responsibility, and the allowed imports are in [docs/01-architecture/modules.md](docs/01-architecture/modules.md). An import that is not in the dependency graph is forbidden, and CI rejects it (#062).
- No dumping grounds: no `Common/`, `Utils/`, `Helpers/`, or `Misc/`. A shared abstraction needs a named owner module.
- Client executables (APKRun.app, APKRunMenuBar, the CLI, APKRunLauncher) never import RuntimeCore. The only exception is the CLI built with `APKRUN_EMBEDDED_RUNTIME` for development, which links RuntimeHost ([docs/01-architecture/modules.md](docs/01-architecture/modules.md) §3).

### 6.2 VM

- `VMController` is an actor with async `start`, `stop`, `pause`, and `resume`.
- VM state is an explicit `VMState` enum ([docs/01-architecture/state-machines.md](docs/01-architecture/state-machines.md) §1). Never infer state from whether a reference is `nil`.

### 6.3 Android images

- Never assume file names inside Cuttlefish artifacts. Every artifact set is inventoried first, and all access goes through `AndroidImageManifest` ([docs/02-design/android-image.md](docs/02-design/android-image.md) §3).
- Code like `directory.appendingPathComponent("boot.img")` outside the manifest layer is a review failure.
- Image handling lives in `ImageCore` and `Images/tools/`, never in `VirtualMachineCore`.

### 6.4 Graphics

- Graphics is the largest technical risk. Study the RiftVM prototype (#018, which writes `docs/02-design/riftvm-analysis.md`; [docs/02-design/graphics.md](docs/02-design/graphics.md) §2) before writing new virtual GPU code.
- The normal frame path never uses `glReadPixels`, CPU framebuffer readback, or CPU texture copies. Debug readback is behind a clearly marked, removable switch, and the readback counter must stay at 0 in tests ([docs/02-design/graphics.md](docs/02-design/graphics.md) §6–§7).

### 6.5 Native code boundary

- Swift → narrow C API → Objective-C++/C++ → virglrenderer/ANGLE. Expose opaque handles, never C++ object graphs, to Swift ([docs/05-development/coding-conventions.md](docs/05-development/coding-conventions.md)).

### 6.6 Third-party code

- Every third-party dependency is pinned in `ThirdParty/ThirdParty.lock.json` with repository, commit, license, build flags, and local patches. Never build from a moving branch.
- A new third-party component with runtime impact needs an ADR ([docs/05-development/build-system.md](docs/05-development/build-system.md), [docs/05-development/legal-and-licensing.md](docs/05-development/legal-and-licensing.md)).

### 6.7 Input

- Early validation may use `adb shell input`. The production path never runs a shell command per event (FR-IN-06).
- Production input: `NSEvent → InputCore → GuestProtocol → Guest Agent → Android input injection` (ADR-0013, [docs/02-design/input.md](docs/02-design/input.md)).

### 6.8 Guest communication

- ADB is the main debugging interface until the guest protocol is stable, and it stays available in development builds (FR-RT-05). Production control uses vsock ([docs/02-design/guest-protocol.md](docs/02-design/guest-protocol.md) §13).
- The guest protocol is versioned protobuf (ADR-0014). Every connection starts with a handshake. An incompatible major version fails with a typed error; never continue silently.
- Guest components: the Guest Agent and the Store Agent (Kotlin) and `apkrun_vsockd` (Rust) ([docs/02-design/guest-components.md](docs/02-design/guest-components.md), ADR-0008).

---

## 7. Storage and naming

- Host data lives under `~/Library/Application Support/APKRun/` ([docs/01-architecture/filesystem-layout.md](docs/01-architecture/filesystem-layout.md)). Nothing mutable lives inside a generated `.app`.
- Reverse-DNS root: `io.apkrun` for bundle IDs, XPC and launchd names, log subsystems, and guest packages ([docs/01-architecture/modules.md](docs/01-architecture/modules.md) §5).
- Configuration keys and defaults: [docs/03-reference/configuration.md](docs/03-reference/configuration.md).

---

## 8. Logging, diagnostics, and errors

- Log through DiagnosticsCore with structured fields. Use the `io.apkrun.*` subsystems in [docs/02-design/diagnostics.md](docs/02-design/diagnostics.md) §3.
- Every critical lifecycle event carries an operation ID, and the package ID, display ID, error domain, and error code where they apply.
- Never log secrets, clipboard contents, file contents, or private app data.
- Errors are typed domains (`enum GraphicsFailure: Error { … }`), never `NSError(domain: "error", code: 1)`. Every user-visible error has an entry with a remediation in [docs/03-reference/error-catalog.md](docs/03-reference/error-catalog.md). CLI errors say what to do next.
- Every major subsystem reports health to `apkrun doctor`. A user must be able to tell apart a VM failure, an Android boot failure, a graphics failure, a Guest Agent failure, a package failure, and an update failure without reading source code.
- Record the performance markers of [docs/02-design/diagnostics.md](docs/02-design/diagnostics.md) §4.2. Do not optimize before measuring.

---

## 9. Security

- All APK code is untrusted.
- Never expose the host file system directly. Never mount `~/`, `~/.ssh`, `~/Library`, or `~/Documents` automatically. Only the shared folder and folders the user picks are shared ([docs/02-design/desktop-integration.md](docs/02-design/desktop-integration.md) §6).
- Every guest ↔ host capability goes through an explicit policy layer ([docs/01-architecture/security-model.md](docs/01-architecture/security-model.md)).
- XPC peers are validated, and a wrapper is authorized for its own package only (NFR-SEC-07).
- Test keystores live in `Tests/Fixtures/signing/`. Never commit production keys or credentials.

---

## 10. Tests

- Tiers ([docs/04-plan/test-strategy.md](docs/04-plan/test-strategy.md)): **T0** unit tests (every module where meaningful), **T1** host integration without a VM, **T2** against a real guest VM (the test Linux guest or Android), **T3** acceptance and manual checks on real Apple silicon Macs.
- Graphics is never complete on mocks alone.
- Use the fixture apps in `Tests/Fixtures/AndroidApps/` (HelloText, HelloCompose, HelloGL, HelloWebView, HelloNotification, HelloClipboard, HelloUpdate V1/V2, and the others in the test strategy) before blaming a third-party APK.
- A task lists its tests by tier. All of them pass before the task is done.

---

## 11. Scope discipline and experiments

- One risk per task. A task about Android boot does not also touch the wrapper UI, the updater, Google Play, or Vulkan ([docs/00-product/scope.md](docs/00-product/scope.md) §5).
- If finishing a task needs a large expansion of scope, stop and file a follow-up task. It takes the number GitHub gives its issue (#098 and up), and its entry goes into the milestone file and the task index ([docs/05-development/workflow.md](docs/05-development/workflow.md) §2.4).
- Experiments live in `Experiments/` or on `experiment/*` branches (for example `experiment/android-virgl`). Production targets never import them. When an experiment works, reimplement the minimum cleanly in the production modules, and have it reviewed.

---

## 12. Definition of done

A task is not done when it compiles. It is done when:

- the implementation meets every acceptance criterion of the task entry,
- the tests of every tier the entry lists pass,
- logging and typed error handling are in place,
- non-obvious behavior is documented, and the design documents describe what was built,
- the manual checks the entry requires are recorded, and
- verification results are written where the entry's Notes say (design verification logs, risks, ADRs).

Every temporary workaround has `TODO(#NNN): reason`, with a tracking task (NFR-DEV-04). CI rejects a `TODO` without a task number.

---

## 13. Branches, commits, and pull requests

- One task per branch: `task/<NNN>-<short-name>` (for example `task/024-pointer-input`). The pull request title is `#NNN Title`.
- A bug fix uses `fix/<NNN>-<short-name>` with the bug's issue number, a documentation change that belongs to no task uses `docs/<short-name>`, and an experiment uses `experiment/<name>`, which is never merged ([docs/05-development/workflow.md](docs/05-development/workflow.md) §4.1).
- A commit scope is one of the scopes in [docs/05-development/workflow.md](docs/05-development/workflow.md) §4.2. The body ends with `Refs: #NNN`.
- Small commits in Conventional Commits style, scoped to a module or area:

  ```text
  feat(vm): boot arm64 linux with Virtualization.framework
  feat(graphics): expose virtio-gpu through custom virtio device
  fix(update): reject mismatched signing certificate
  ```

  Never `work`, `changes`, `fix stuff`, or `wip final`.
- Use [.github/pull_request_template.md](.github/pull_request_template.md). The review, merge, and parallel-work rules are in [docs/05-development/workflow.md](docs/05-development/workflow.md).

---

## 14. Documentation

- All documentation is in English.
- Documentation changes go in the same pull request as the code that makes them necessary.
- Adding, removing, or renaming a requirement, a task, or a design section also updates [docs/04-plan/traceability.md](docs/04-plan/traceability.md).
- [docs/](docs/README.md) is the maintained product and implementation specification. Requirements, tasks, design sections, and accepted ADRs are the canonical references.
- Document conventions: [docs/README.md](docs/README.md) §3.

---

## 15. When unsure

Prefer, in this order:

1. existing Android behavior,
2. documented virtio behavior,
3. existing Cuttlefish behavior,
4. existing RiftVM behavior,
5. minimal adapter code,
6. a new custom mechanism, only as the last resort.

APKRun is an integration project, not a collection of custom subsystems.

If the design is wrong or a step is impossible, fix the design document and the task entry in the same pull request and explain why in the pull request. If the fix changes an architectural decision, write an ADR first. If you are an AI agent and the right choice is still unclear, stop and ask instead of guessing.
