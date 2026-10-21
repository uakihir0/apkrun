# APKRun: Rules for Implementers

These rules apply to everyone who changes this repository, human or AI agent. [docs/](docs/README.md) is the specification. This file is the part you must always follow. Read §2 before every task.

If a task seems to need breaking one of these rules, stop and ask. Changing a rule needs an accepted ADR first ([docs/01-architecture/decisions/README.md](docs/01-architecture/decisions/README.md)).

---

## 1. What APKRun is

APKRun runs Android ARM64 apps on Apple silicon Macs as ordinary, automatically updating Mac apps. It is not an emulator UI: the user never sees Android itself.

```text
Android APK
    ↓
APKRun (package store, updates, wrapper generator)
    ↓
Thin Mac app wrapper  (/Applications/App.app)
    ↓
apkrund (per-user LaunchAgent, owns the VM)
    ↓
Android ARM64 guest (AOSP Cuttlefish based) on Virtualization.framework
```

Target command: `apkrun wrap app.apk --install` → `/Applications/App.app`. The `.app` is a thin, immutable launcher. APKs, Android data, update metadata, and runtime images live outside it ([docs/02-design/wrapper.md](docs/02-design/wrapper.md), ADR-0009).

Background: [docs/00-product/vision.md](docs/00-product/vision.md), [docs/01-architecture/overview.md](docs/01-architecture/overview.md).

---

## 2. How to do a task

1. **Pick the task.** Use the task the user names. Otherwise run `scripts/dev/next-task.py` and take the first task it lists. A task number is its GitHub issue number.
2. **Read.** `gh issue view <N>` links to the task entry in `docs/04-plan/issues/`. Read the whole entry. Then read the design sections in its `Design` row, and nothing else unless a step needs it. The design wins over your assumptions.
3. **Check open questions and risks** named in the entry ([docs/04-plan/open-questions.md](docs/04-plan/open-questions.md), [docs/04-plan/risks.md](docs/04-plan/risks.md)). Build to the working default of an open question.
4. **Do the steps in order.** After each step, run its **Check:**. Commit when the check passes (§13).
5. **Run the tests** the entry lists, at every tier you can run:

   ```bash
   swift build                                   # builds every Swift package and the CLI
   swift test --skip SystemTests                 # T0, as in CI
   swift test --filter <Module>Tests             # one module
   scripts/ci/run-checks.sh                      # lint: module graph, TODOs, format, lock, protos, docs
   scripts/ci/codegen.sh                         # when errors.json, .proto files, or project.yml changed
   ```

   T2 and T3 tests need a real Apple silicon Mac, a VM, and sometimes a signing identity or a person. If you cannot run them, say so. Never claim that a test passed when it did not run.
6. **Update the documents** when the code does something the design does not say, in the same commit ([docs/README.md](docs/README.md) §4). Run `scripts/check-docs.sh`.
7. **Finish.**
   - Every `Done when` item holds, and every listed test passed → close the issue (`gh issue close <N> --comment "<what was verified>"`), and shorten the entry to the closed format ([docs/04-plan/issues/README.md](docs/04-plan/issues/README.md) §2.2).
   - The code is done but T2/T3 or the gate could not run → leave the issue open and add the label: `gh issue edit <N> --add-label needs-verification`. Comment which tests are left.
8. **Report** to the user: what changed, which tests ran and their results, and what is not verified.

### 2.1 Stop and ask when

- a rule in this file would be broken;
- the design looks wrong, or a step is impossible as written;
- the work needs files or behavior outside the task's scope (file a follow-up instead, §11);
- you would need to delete or rewrite code that the task does not mention.

---

## 3. Platform

| | Supported |
|---|---|
| Host | Apple silicon (arm64) Macs with macOS 27 or later. No Intel Macs and no Rosetta. |
| Guest | Android ARM64, based on AOSP Cuttlefish (`aosp_cf_arm64_only_phone`), Android 17 (API 37) |
| Virtualization | Virtualization.framework with the macOS 27 custom virtio device API (ADR-0002) |
| Graphics | Android GLES → Mesa VirGL → virtio-gpu → virglrenderer → ANGLE → Metal (ADR-0004) |

Vulkan and Google Play are post-v1 tracks (#97, #98). Do not add code for them to v1 tasks.

---

## 4. Product invariants

These hold in every task.

1. **Do not reimplement Android.** Android runs in the guest. Never implement Android APIs on Darwin (ADR-0001).
2. **Use existing standards:** virtio, virtio-gpu, virtio-vsock, `PackageInstaller`, `PackageManager`, Android multi-display, Mesa, VirGL, ANGLE. Do not invent a protocol unless the standard one is proven unusable.
3. **Do not trim Android** (Launcher, SystemUI, SetupWizard, system apps) before boot, ADB, GPU, Hello APK, input, and a native window all work.
4. **apkrund owns the VM**, not the GUI. APKRun.app, the menu bar app, the CLI, and wrappers are XPC clients through `RuntimeClient`. Quitting the GUI does not stop the VM (ADR-0007).
5. **The wrapper owns its window.** apkrund renders into shared IOSurfaces (ADR-0006).
6. **One Android display per Mac window**, managed by `DisplayPool`. Never hard-code app ↔ display mappings (ADR-0005).
7. **Four update systems stay separate:** Android apps (UpdateCore and the Store Agent), APKRun itself (Sparkle, ADR-0016), the Android image, and wrapper metadata.
8. **One update authority per package** (`apkrun`, `googlePlay`, `external`, `manual`). Two automatic updaters never manage the same package (ADR-0010).
9. **Updates never block launch.** Launch at once; check, download, and install in the background; install only when the app is not in use.
10. **No signature bypass.** Before an update: the package ID matches, `versionCode` increases, the signing lineage is valid, ABI and SDK fit, the split set is consistent, and the hash matches. No flag, setting, or debug path skips a check.
11. **Rollback is binary only.** Keep the previous APK set until the new version passes its health check. Never claim that data migrations can be reversed.
12. **Install only through `PackageInstaller`.** Never copy APKs into Android package directories. `PackageManager` is the source of truth for package identity. Host-side APK parsing is for previews and for refusing bad input early ([docs/02-design/package-store.md](docs/02-design/package-store.md) §4); it never decides what is installed.
13. **Wrappers are immutable.** An APK update never changes, re-signs, or regenerates a wrapper. A wrapper never contains the Android app's version.
14. **Bundle IDs are deterministic:** `io.apkrun.android.<mapped package>`, never random or per machine ([docs/02-design/wrapper.md](docs/02-design/wrapper.md) §4.1).

---

## 5. Development order and gates

The working order is [docs/04-plan/roadmap.md](docs/04-plan/roadmap.md) §1.3. Do not skip ahead because a later task looks easier. The gates G1–G9 and their pass conditions are in [docs/04-plan/roadmap.md](docs/04-plan/roadmap.md) §2.

- Do not declare the core architecture validated before **G3** (passed).
- Do not declare the product concept validated before **G9** (the wrapper stays unchanged while the APK updates automatically).

---

## 6. Architecture rules

### 6.1 Modules

- Modules, owners, and allowed imports are in [docs/01-architecture/modules.md](docs/01-architecture/modules.md). An import outside the dependency graph is forbidden, and CI rejects it.
- No dumping grounds: no `Common/`, `Utils/`, `Helpers/`, or `Misc/`. A shared abstraction needs a named owner module.
- Client executables (APKRun.app, APKRunMenuBar, the CLI, APKRunLauncher) never import RuntimeCore. The only exception is the CLI built with the `EmbeddedRuntime` trait for development, which links RuntimeHost.

### 6.2 VM

- `VMController` is an actor with async `start`, `stop`, `pause`, and `resume`.
- VM state is the explicit `VMState` enum ([docs/01-architecture/state-machines.md](docs/01-architecture/state-machines.md) §1). Never infer state from whether a reference is `nil`.

### 6.3 Android images

- Never assume file names inside Cuttlefish artifacts. All access goes through `AndroidImageManifest` ([docs/02-design/android-image.md](docs/02-design/android-image.md) §3).
- `directory.appendingPathComponent("boot.img")` outside the manifest layer is a review failure.
- Image handling lives in `ImageCore` and `Images/tools/`, never in `VirtualMachineCore`.

### 6.4 Graphics

- Read [docs/02-design/graphics.md](docs/02-design/graphics.md) and [docs/02-design/riftvm-analysis.md](docs/02-design/riftvm-analysis.md) before writing virtual GPU code.
- The frame path never uses `glReadPixels`, CPU framebuffer readback, or CPU texture copies. Debug readback is behind a clearly marked switch, and the readback counters stay at 0 in tests ([docs/02-design/graphics.md](docs/02-design/graphics.md) §6–§7).

### 6.5 Native code boundary

Swift → narrow C API → Objective-C++/C++ → virglrenderer/ANGLE. Expose opaque handles to Swift, never C++ object graphs ([docs/05-development/coding-conventions.md](docs/05-development/coding-conventions.md)).

### 6.6 Third-party code

- Every third-party dependency is pinned in `ThirdParty/ThirdParty.lock.json` with repository, commit, license, build flags, and local patches. Never build from a moving branch.
- A new third-party component with runtime impact needs an ADR ([docs/05-development/build-system.md](docs/05-development/build-system.md), [docs/05-development/legal-and-licensing.md](docs/05-development/legal-and-licensing.md)).

### 6.7 Input

- Tests and early checks may use `adb shell input`. The production path never runs a shell command per event (FR-IN-06).
- Production input: `NSEvent → InputCore → GuestProtocol → Guest Agent → Android input injection` (ADR-0013, [docs/02-design/input.md](docs/02-design/input.md)).

### 6.8 Guest communication

- ADB stays available in development builds for debugging (FR-RT-05). Production control uses vsock ([docs/02-design/guest-protocol.md](docs/02-design/guest-protocol.md) §13).
- The guest protocol is versioned protobuf (ADR-0014). Every connection starts with a handshake. An incompatible major version fails with a typed error; never continue silently.
- Guest components: the Guest Agent and the Store Agent (Kotlin), and `apkrun_vsockd` (Rust) ([docs/02-design/guest-components.md](docs/02-design/guest-components.md), ADR-0008).

---

## 7. Storage and naming

- Host data lives under `~/Library/Application Support/APKRun/` ([docs/01-architecture/filesystem-layout.md](docs/01-architecture/filesystem-layout.md)). Nothing mutable lives inside a generated `.app`.
- Reverse-DNS root: `io.apkrun` for bundle IDs, XPC and launchd names, log subsystems, and guest packages.
- Settings and defaults: [docs/03-reference/configuration.md](docs/03-reference/configuration.md).

---

## 8. Logging, diagnostics, and errors

- Log through DiagnosticsCore with structured fields and the `io.apkrun.*` subsystems ([docs/02-design/diagnostics.md](docs/02-design/diagnostics.md) §3).
- Every lifecycle event carries an operation ID, and the package ID, display ID, error domain, and error code where they apply.
- Never log secrets, clipboard contents, file contents, or private app data.
- Errors are typed domains (`enum GraphicsFailure: Error { … }`), never `NSError(domain: "error", code: 1)`. Every user-visible error has an entry with a remediation in `Packages/DiagnosticsCore/ErrorCatalog/errors.json`; run `swift scripts/errorgen.swift --markdown` to regenerate the code and [docs/03-reference/error-catalog.md](docs/03-reference/error-catalog.md). CLI errors say what to do next.
- Every major subsystem reports health to `apkrun doctor`, so a user can tell apart VM, Android boot, graphics, Guest Agent, package, and update failures.
- Measure before optimizing. Performance markers: [docs/02-design/diagnostics.md](docs/02-design/diagnostics.md) §4.

---

## 9. Security

- All APK code is untrusted.
- Never expose the host file system directly. Never mount `~/`, `~/.ssh`, `~/Library`, or `~/Documents` automatically. Only the shared folder and folders the user picks are shared ([docs/02-design/desktop-integration.md](docs/02-design/desktop-integration.md) §6).
- Every guest ↔ host capability goes through an explicit policy layer ([docs/01-architecture/security-model.md](docs/01-architecture/security-model.md)).
- XPC peers are validated, and a wrapper is authorized for its own package only (NFR-SEC-07).
- Test keystores live in `Tests/Fixtures/signing/`. Never commit production keys or credentials.

---

## 10. Tests

- Tiers ([docs/04-plan/test-strategy.md](docs/04-plan/test-strategy.md) §2): **T0** unit tests, **T1** host integration without a VM, **T2** against a real VM (the test Linux guest or Android), **T3** acceptance and manual checks on a real Mac.
- A test lives in the lowest tier that can catch the failure. Tests wait for markers, never for fixed sleeps.
- Graphics is never complete on mocks alone.
- Use the fixture apps in `Tests/Fixtures/AndroidApps/` ([docs/04-plan/test-strategy.md](docs/04-plan/test-strategy.md) §4.2) before blaming a third-party APK.

---

## 11. Scope and experiments

- One risk per task. A task about Android boot does not also touch the wrapper UI, the updater, Google Play, or Vulkan.
- Work outside the task's scope becomes a follow-up task: `gh issue create --label task`, then its entry and index row ([docs/05-development/workflow.md](docs/05-development/workflow.md) §2.4).
- Experiments live in `Experiments/` or on `experiment/*` branches. Production targets never import them. When an experiment works, reimplement the minimum cleanly in the production modules.

---

## 12. Definition of done

A task is done when:

- every `Done when` item of its entry holds;
- the tests of every tier the entry lists pass;
- logging and typed errors are in place;
- the design documents describe what was built, and `scripts/check-docs.sh` passes.

Every temporary workaround has `TODO(#N): reason` with an open issue number. CI rejects a `TODO` without one.

---

## 13. Commits

- Conventional Commits with a scope from [docs/05-development/workflow.md](docs/05-development/workflow.md) §4.2, and `Refs: #N` (the GitHub issue number) at the end of the body:

  ```text
  feat(vm): boot arm64 linux with Virtualization.framework

  Start the VM through VZLinuxBootLoader and wait for the serial marker.

  Refs: #4
  ```

- Small commits. Each commit builds. Generated files go in the same commit as their source.
- Never `work`, `changes`, `fix stuff`, or `wip`.
- Branches and pull requests: [docs/05-development/workflow.md](docs/05-development/workflow.md) §4–§7.

---

## 14. Documentation

- Documents are in English and follow [docs/README.md](docs/README.md) §3.
- A change that makes a document wrong updates the document in the same commit.
- Do not add history, test evidence, or progress reports to documents. They go into commit messages, pull requests, and GitHub issue comments.

---

## 15. When unsure

Prefer, in this order:

1. existing Android behavior,
2. documented virtio behavior,
3. existing Cuttlefish behavior,
4. existing RiftVM behavior,
5. minimal adapter code,
6. a new custom mechanism, only as the last resort.

APKRun is an integration project, not a collection of custom subsystems. If the right choice is still unclear, stop and ask (§2.1).
