# Build System

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [environment-setup.md](environment-setup.md), [coding-conventions.md](coding-conventions.md), [workflow.md](workflow.md), [legal-and-licensing.md](legal-and-licensing.md), [../01-architecture/modules.md](../01-architecture/modules.md), [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md), [../01-architecture/security-model.md](../01-architecture/security-model.md), [../04-plan/test-strategy.md](../04-plan/test-strategy.md) |
| Tasks | #001, #016, #020, #027, #033, #035, #044, #057, #061, #062, #065, #087, #088, #090, #091, #093 |

This guide describes how every artifact of APKRun is built: the host app and its helpers, the guest components, the third-party libraries, the runtime image, the test fixtures, and the signed release. Tool installation is in [environment-setup.md](environment-setup.md).

---

## 1. Quick start

```bash
scripts/bootstrap                                  # pinned tools, venv, local.properties (environment-setup.md §7)
scripts/build-third-party.sh virgl-runtime         # once; later runs hit the cache (§6)
scripts/build-guest.sh                             # guest agent APKs (§7)
scripts/generate-project.sh                        # APKRun.xcodeproj from project.yml (§2.2)
swift build && swift test                          # all Swift packages and the CLI, tiers T0 and T1
xcodebuild -project APKRun.xcodeproj -scheme APKRun -configuration Debug build
scripts/dev/install-dev-app.sh                     # "~/Applications/APKRun Dev.app" + agent registration (§13)
```

A clean checkout must build and pass `swift test` without manual steps (NFR-DEV-02). Steps that need artifacts that are not in the repository (a Cuttlefish build, the test Linux kernel) skip with a message that names the command that produces them.

---

## 2. Project structure

### 2.1 Package.swift

`Package.swift` at the repository root is the single SwiftPM manifest ([../01-architecture/modules.md](../01-architecture/modules.md) §1).

| Setting | Value |
|---|---|
| Tools version | `// swift-tools-version: 6.2` |
| Language mode | Swift 6 for every target (`swiftLanguageModes: [.v6]`), so strict concurrency checking is complete |
| Platform | `.macOS("27.0")` |
| Library targets | one per directory in `Packages/` (16 modules), plus the C target `GraphicsBridge` inside `Packages/GraphicsCore/` |
| Library products | static only. No `type: .dynamic`. Swift packages are linked statically into each executable ([../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §4) |
| Executables | `apkrun` (`CLI/apkrun`), `apkrun-perf` (`Tests/PerformanceTests/apkrun-perf`) |
| Test targets | `Packages/<Module>/Tests/<Module>Tests/` (T0), `Packages/<Module>/Tests/<Module>SystemTests/` (T1), and `CLI/apkrun/Tests/` (T0, goldens in `CLI/apkrun/Tests/Golden/`) ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.2, §2.3) |
| Test support targets | `Packages/<Module>/Tests/<Module>TestSupport/`: the fakes of the protocols the module owns. Only test targets depend on them ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.2) |
| Fuzz targets | `Packages/<Module>/Tests/<Module>Fuzz/`, declared only when `APKRUN_FUZZ=1` is set (§15.2) |
| Dependencies | `swift-protobuf`, `swift-argument-parser`, and `ZIPFoundation` (ADR-0017), all with `exact:` versions, so SwiftPM and Xcode resolve the same revision |
| Package trait | `EmbeddedRuntime` (off by default) adds the `RuntimeHost`, `WindowingCore`, and `InputCore` dependencies to `apkrun` and defines `APKRUN_EMBEDDED_RUNTIME` ([../02-design/cli.md](../02-design/cli.md) §2) |

`Package.resolved` is committed. `apkrund` is an Xcode target (§2.2) with a thin `main` in `Daemon/apkrund`; all its logic is in `RuntimeHost`.

The `EmbeddedRuntime` trait uses trait-conditioned target dependencies (SE-0450). Verified for #001 on Xcode 27.0 / Swift 6.4: `swift build --traits EmbeddedRuntime` succeeds with the three same-package dependencies enabled, while `swift build` succeeds with the trait off. Keep the conditional edges in the package manifest; no fallback is needed.

### 2.2 project.yml and the Xcode project

`project.yml` is the XcodeGen spec for everything that is a bundle or needs entitlements. `scripts/generate-project.sh` runs the pinned XcodeGen ([environment-setup.md](environment-setup.md) §2.7) and writes `APKRun.xcodeproj`. The generated project is git-ignored and never edited by hand. The local package (`Package.swift`) is referenced from `project.yml` as a local Swift package. Sparkle is added as a remote Swift package with an exact version in #057 ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2).

| Target | Type | Bundle ID (Release) | Sources | Links |
|---|---|---|---|---|
| `APKRun` | application | `io.apkrun.APKRun` | `Apps/APKRun` | RuntimeClient, RuntimeAPI, DiagnosticsCore; Sparkle from #057 |
| `APKRunMenuBar` | application (login item) | `io.apkrun.APKRunMenuBar` | `Apps/APKRunMenuBar` | RuntimeClient, RuntimeAPI, DiagnosticsCore |
| `APKRunLauncher` | application | `io.apkrun.APKRunLauncher` | `Apps/APKRunLauncher` | RuntimeClient, RuntimeAPI, WindowingCore, InputCore, DiagnosticsCore |
| `apkrund` | command-line tool, embedded Info.plist (`CREATE_INFOPLIST_SECTION_IN_BINARY`) | `io.apkrun.apkrund` | `Daemon/apkrund` | RuntimeHost, VirGLRuntime dylibs |
| `APKRunTestHost` | application, Debug only | `io.apkrun.testhost` | `Tests/IntegrationTests/Host` | the modules under test |
| `IntegrationTests` | unit-test bundle hosted by `APKRunTestHost` (T2) | — | `Tests/IntegrationTests` | as needed |
| `AcceptanceTests` | unit-test bundle hosted by `APKRunTestHost` (T3 gate checks, release smoke, network checks; #003 creates it) | — | `Tests/AcceptanceTests` | as needed |
| `<App>Tests`, `<App>UITests` | unit-test and UI-test bundles per app | — | `Apps/<App>/Tests/` (T0), `Apps/<App>/UITests/` (T1, XCUITest against the embedded runtime fake) | the app's modules |

The CLI is not an Xcode target. The `APKRun` target builds it with SwiftPM and embeds it (§11).

### 2.3 Schemes

| Scheme | Builds | Run / test action |
|---|---|---|
| `APKRun` | APKRun.app with all helpers | runs APKRun.app |
| `apkrund (attach)` | APKRun.app | "Wait for the executable to be launched" on `apkrund`, for daemon debugging ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6) |
| `APKRunLauncher` | the launcher | runs the launcher with a test wrapper path argument |
| `APKRunMenuBar` | the menu bar extra | runs it standalone |
| `IntegrationTests` | `APKRunTestHost` and `IntegrationTests` | T2 tests with the `IntegrationTests` test plan (§12.4) |
| `AcceptanceTests` | `APKRunTestHost` and `AcceptanceTests` | T3 checks with the `AcceptanceTests` test plan (§12.4), started by `scripts/run-gate.sh` and the nightly and weekly jobs (§15.1) |
| `APKRunUITests` | APKRun.app and `APKRunUITests` | T1 XCUITest |

### 2.4 Build configurations

| Configuration | Use | Differences |
|---|---|---|
| `Debug` | development | `.dev` identities (§13), no `SUFeedURL`, test hooks compiled in (`APKRUN_GRAPHICS_FAULT`, `APKRUN_RUNTIME_FAULT`, `APKRUN_STORE_FAULT`, `APKRUN_LAUNCHER_TEST_NO_RUNTIME`, `APKRUN_TEST_MARKER_TIMEOUT`, and the other hooks of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.3; variables in [../03-reference/configuration.md](../03-reference/configuration.md) §5.1), the per-developer image key trusted, CLI built with the `EmbeddedRuntime` trait, development signing, `-Onone` |
| `Release` | shipped builds | production identities, Developer ID signing (§12), release image keys only, Sparkle feed and key, `-O` with whole-module optimization, no test hooks (checked by §3.1) |
| `ReleaseUpdateTest` | the T2 "APKRun N → N+1" test ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §14) | Release settings, plus: `SUFeedURL` points at the local appcast server `scripts/dev/appcast-server.py` on `127.0.0.1`, `SUPublicEDKey` is `Tests/Fixtures/signing/test-sparkle-ed25519.pub`, identities get the suffix `.updatetest`, Developer ID signed but not notarized, honors `APKRUN_TEST_MARKER_TIMEOUT`, uses the Sparkle test user driver, and trusts the build machine's development image key as well as the release image keys, so the test can provision a lab-signed image ([../02-design/android-image.md](../02-design/android-image.md) §10.1). The Maintenance suite builds it as 9000 and 9001 (9001 adds `Resources/test-build-marker`) |

The identity (bundle ID suffix, LaunchAgent label, Mach service name) is written into the Info.plist of every bundle and into the embedded Info.plist of `apkrund` and the CLI as `APKRunBuildIdentity` (`release`, `dev`, or `updatetest`). RuntimeClient reads it to pick the service name ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6). Xcode builds local Swift packages only in Debug or Release, so package code must not use compilation conditions for anything that differs in `ReleaseUpdateTest`.

### 2.5 Common build settings

| Setting | Value |
|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | `27.0` |
| `ARCHS` | `arm64` only |
| `SWIFT_VERSION` | `6` |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS`, `GCC_TREAT_WARNINGS_AS_ERRORS` | `YES` in CI (`APKRUN_CI=1`), `NO` locally |
| `ENABLE_HARDENED_RUNTIME` | `YES` for product targets; see §12.4 for the hosted VM test exception |
| `DEAD_CODE_STRIPPING` | `YES` |
| `MARKETING_VERSION` | `project.yml`, the next release version (MAJOR.MINOR.PATCH) |
| `CURRENT_PROJECT_VERSION` | `1` locally; the release workflow passes the build number ([workflow.md](workflow.md) §8) |
| Localization | String Catalogs (`Localizable.xcstrings`), `en` and `ja` (NFR-L10N-01) |

All executables in one APKRun.app carry the same `CFBundleShortVersionString` and `CFBundleVersion` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1).

---

## 3. Static checks

Each check is a script that CI runs in the `lint` job (§15) and that works locally without arguments.

| Script | Checks | Task |
|---|---|---|
| `scripts/check-module-deps.sh` | parses `Package.swift` (via `swift package dump-package`) and `project.yml`, and fails on any import edge not in [../01-architecture/modules.md](../01-architecture/modules.md) §3, on third-party products used outside the places the graph names, and on trait-conditioned edges other than `EmbeddedRuntime` → `apkrun` | #062 |
| `scripts/check-logging.sh` | no `os.Logger`, `Logger(`, `print(`, `NSLog`, or `os_log` outside DiagnosticsCore; every inline interpolation in an `APKLogger` call has a privacy argument and does not use a `Sensitive` value; self-test covers each rule | #061 |
| `scripts/check-launcher.sh` | the built APKRunLauncher: `otool -L` lists only `/System/Library` and `/usr/lib`, `lipo -archs` is `arm64`, and the minimum OS is 27.0 | #068 |
| `scripts/check-todos.sh` | every `TODO` and `FIXME` carries an issue number (`TODO(#123): …`), NFR-DEV-04 | #062 |
| `scripts/check-format.sh` | `swift format lint --strict`, ktfmt check, `cargo fmt --check`, `ruff format --check` ([coding-conventions.md](coding-conventions.md) §2) | #062 |
| `scripts/check-lock.sh` | `ThirdParty/ThirdParty.lock.json` against its schema, every patch listed exists, the Swift package pins match `Package.resolved` and `project.yml` (§6.1). With `--apply`, which the `third-party` job runs against clean, pinned build sources before compiling them (§15.1), it also applies every patch | #062; `--apply` #020 |
| `scripts/check-sepolicy.sh` | release (`user`) product sources declare no permissive domain (R-13) | #035 |
| `scripts/check-raw-adb.sh` | no `adb shell` or `pm ` strings outside `ADBStoreAgentChannel` and `AdbClient`. Exempt paths: `scripts/dev/`, `Tests/Compatibility/`, `Images/tools/reference/` ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.3) | #027 |
| `scripts/check-compatibility-db.sh` | `Tests/Compatibility/database/compatibility.json` against `compatibility.schema.json` ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10) | #090 |
| `scripts/check-fixtures.sh` | every APK in `Tests/Fixtures/apks/` is newer than its sources, and no committed fixture file is larger than 10 MiB (§8) | #016 |
| `scripts/check-licenses.sh` | every lock entry, and every package in `Package.resolved` and the Gradle and Cargo locks, has an SPDX `license` and committed `licenseFiles`; distribution and tooling entries must use a license allowed for their `ships` value, while `reference` entries retain their identified upstream license without a redistribution check. It fails on missing or unresolved licenses, missing license copies, disallowed licenses ([legal-and-licensing.md](legal-and-licensing.md) §4), and a `Derived from RiftVM` marker that does not name the pinned commit ([legal-and-licensing.md](legal-and-licensing.md) §3.1) | #093 |
| `scripts/check-strings.sh` | every `.xcstrings` file and `errors.json`: for the Release configuration, no missing `ja` value, no `stale` entry, and no `needs review` entry; Debug builds only warn ([../02-design/host-ui.md](../02-design/host-ui.md) §13) | #092 |

The rules behind these checks are in [coding-conventions.md](coding-conventions.md). A new dependency edge or a new third-party component needs an ADR before the check is changed ([../01-architecture/decisions/README.md](../01-architecture/decisions/README.md)).

### 3.1 Release checks

`scripts/release/check-release-build.sh <APKRun.app> [<image bundle>]` runs in the `build` job for the Release configuration and again in the release jobs (§15, [workflow.md](workflow.md) §9, §10). It enforces the rules of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.3. #062 creates it with the first two rows. #065 adds the image rows, #093 the notices row, and #057 the R1, R5, and R6 rows. Each row comes with a fixture that fails it:

| Check | How |
|---|---|
| no test hooks in Release binaries | `strings` over every Mach-O file finds no `APKRUN_*_FAULT`, no `APKRUN_TEST_*` (such as `APKRUN_TEST_HEADLESS_LAUNCH`), no `APKRUN_LAUNCHER_TEST_NO_RUNTIME`, and no `ReleaseUpdateTest` setting ([../03-reference/configuration.md](../03-reference/configuration.md) §5.1) |
| no test keys | no public key, key ID, or certificate fingerprint of `Tests/Fixtures/signing/` in the bundle |
| image trust | `ImageTrustStore` of the Release build holds only release key IDs: no ID of `test-image-ed25519` and no per-developer key ([../02-design/android-image.md](../02-design/android-image.md) §10.1) |
| image manifest | a release image manifest has no `androidboot.apkrun.test.*` key ([../02-design/android-image.md](../02-design/android-image.md) §6.2) |
| notices | `Contents/Resources/ThirdPartyNotices.html` has a section for every lock entry with `ships: app` or `ships: derived`; reference-only entries are excluded ([legal-and-licensing.md](legal-and-licensing.md) §6, #093) |
| key rotation | the Sparkle public key and the Developer ID certificate are not both different from the previous release (release rule R6, [workflow.md](workflow.md) §9) |
| build number | `CFBundleVersion` is higher than every published build on every channel (release rule R1, [workflow.md](workflow.md) §8) |
| migration chain | for every data file, `Tests/Fixtures/schemas/<file>/` has a golden `v<n>.json` for every schema version in the `dataSchemas` of the stable releases of the last 24 months (release rule R5, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5) |

The last three rows need the published releases: the appcast, and the `components.json` that the release job attaches to each GitHub release ([workflow.md](workflow.md) §9.4). They run only in the release job.

---

## 4. Code generation

Generated files are committed. CI regenerates them and fails on any diff (`git diff --exit-code`).

| Output | Source | Command | Pinned by |
|---|---|---|---|
| `Packages/GuestProtocol/Sources/GuestProtocol/Generated/*.pb.swift` | `Packages/GuestProtocol/proto/apkrun/guest/v1/*.proto` | `scripts/generate-protos.sh` | protoc, protoc-gen-swift ([environment-setup.md](environment-setup.md) §2.7) |
| Kotlin lite classes in `Guest/protocol/build/` (not committed; built by Gradle) | the same `.proto` files | the `com.google.protobuf` Gradle plugin, lite option | protoc artifact of the same release |
| `ErrorCatalog.generated.swift` in DiagnosticsCore | `Packages/DiagnosticsCore/ErrorCatalog/errors.json` | `swift scripts/errorgen.swift` | the toolchain |
| tables in [../03-reference/error-catalog.md](../03-reference/error-catalog.md) | `errors.json` | `swift scripts/errorgen.swift --markdown` | the toolchain |
| `APKRun.xcodeproj` (not committed) | `project.yml` | `scripts/generate-project.sh` | XcodeGen |

### 4.1 Protocol buffers

- File options: `package apkrun.guest.v1`, `java_package "io.apkrun.guest.protocol.v1"`, `java_multiple_files = true`, `swift_prefix "GP"` ([../02-design/guest-protocol.md](../02-design/guest-protocol.md) §2).
- `scripts/generate-protos.sh` builds `protoc-gen-swift` from the resolved swift-protobuf (`swift build -c release --product protoc-gen-swift`), runs the pinned protoc with `--swift_opt=Visibility=Public`, and writes into `Generated/`.
- `buf lint` uses the `DEFAULT` rules with `ENUM_ZERO_VALUE_SUFFIX` = `_UNSPECIFIED` (`Packages/GuestProtocol/proto/buf.yaml`).
- `buf breaking` runs against the last release tag: `buf breaking Packages/GuestProtocol/proto --against ".git#tag=<last v tag>,subdir=Packages/GuestProtocol/proto"`. A breaking change needs a major version, an ADR, and a transition window ([coding-conventions.md](coding-conventions.md) §6).
- Golden frames in `Packages/GuestProtocol/testdata/frames/*.bin` are decoded by both the Swift and the Kotlin tests.

### 4.2 Error catalog

`errors.json` is the source from #061 on. `errorgen` compiles every language into Swift literals, because the launcher carries no resource bundles ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2). A T0 test checks that `CLI/apkrun/Support/ExitCodes.swift` matches the `cliExit` values.

---

## 5. Build metadata: components.json

The `APKRun` target runs `scripts/build/write-components.py` as a build phase. It writes `Contents/Resources/components.json` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1):

| Field | Taken from |
|---|---|
| `version`, `build` | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |
| `channel` | build setting `APKRUN_CHANNEL`: `stable` in the builds of `release.yml`, `dev` in every other build. There is no `beta` build: a candidate is published on the beta channel and promoted to stable unchanged ([workflow.md](workflow.md) §9.5) |
| `commit` | `git rev-parse --short=7 HEAD`; `-dirty` is appended if the tree has changes, and the release workflow refuses dirty trees |
| `runtimeAPI`, `guestProtocol`, `dataSchemas` | the version constants in RuntimeAPI, GuestProtocol, and the schema owners |
| `agentPlistSHA256` | SHA-256 of the embedded LaunchAgent plist (§11) |
| `components` | the `version` field of the shipped entries in `ThirdParty.lock.json`, the Sparkle version from `project.yml`, and `devGuestAgentVersionCode` from the guest build (§7.1) |

A T0 test compares `components.json` of a built bundle with the compiled constants. `BuildInfo` in DiagnosticsCore reads the file at run time.

---

## 6. Third-party builds

Every third-party input is pinned by commit or by hash, never by a moving branch (NFR-DEV-01). The pins, licenses, build flags, and patches are in `ThirdParty/ThirdParty.lock.json`.

### 6.1 Lock file

```json
{
  "schemaVersion": 1,
  "components": [
    {
      "name": "virglrenderer",
      "group": "virgl-runtime",
      "kind": "source",
      "repository": "https://gitlab.freedesktop.org/virgl/virglrenderer.git",
      "commit": "960bd667…",
      "version": "1.1.1+apkrun.2",
      "license": "MIT",
      "licenseFiles": ["COPYING"],
      "buildFlags": ["-Dplatforms=egl", "-Dtests=false"],
      "patches": ["virglrenderer/0001-msaa-downgrade.patch"],
      "ships": "app",
      "upstream": { "watch": "commits", "branch": "main" }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | unique; also the directory name under `ThirdParty/patches/` |
| `group` | build unit; `virgl-runtime` for the three renderer libraries. A reference-only entry may use a descriptive group such as `graphics-reference`, which is not a build unit and is excluded from build-group processing |
| `kind` | `source` (pinned VCS source at a commit; built only when selected by a build group and not classified as `reference`), `prebuilt` (download with `sha256`), `vendored` (copied into the tree), `swiftpm`, `gradle`, `cargo` (pinned by their own lock files; listed here for licenses and notices) |
| `repository` | the upstream git URL, for `source` and `vendored` entries |
| `url` | the download URL of a `prebuilt` entry. The download is checked against `sha256` before use, and a mismatch fails the build |
| `commit` / `sha256` | the full commit hash, or the hash of the download |
| `buildFlags` | the exact flags the build script passes, for `source` entries; must be empty for `ships: reference` |
| `patches` | the local patches, in order, relative to `ThirdParty/patches/` (§6.2). An empty list when there are none; must be empty for `ships: reference` |
| `version` | the label shown in `components.json`; for patched code, upstream version plus `+apkrun.<n>` |
| `license`, `licenseFiles` | SPDX identifier and upstream-relative license-file paths; committed copies live under `ThirdParty/licenses/<name>/<path>`. Reference entries retain those copies for review but are excluded from notice generation; distribution notice generators include files only for components in their applicable scope ([legal-and-licensing.md](legal-and-licensing.md) §§4, 6) |
| `ships` | `app` (inside APKRun.app), `image` (inside the runtime image), `tooling` (build or test only), `derived` (source copied or adapted into our code), `reference` (pinned source used only for analysis; never built, copied, or distributed); a list such as `["app", "image"]` when a component ships in more than one place ([legal-and-licensing.md](legal-and-licensing.md) §4.1) |
| `upstream` | what the security check watches (§6.7) |

The **lock hash** of a build group is the SHA-256 over its buildable lock entries (canonical JSON), their patch files, and their build scripts. It names the output directory and the CI cache key. Descriptive groups containing only `ships: reference` entries are excluded from build-group discovery, source preparation, patch application, and lock-hash calculation.

### 6.2 Patches

- Patches live in `ThirdParty/patches/<name>/NNNN-short-description.patch`, made with `git format-patch` against the pinned commit, applied in order with `git am`.
- Each patch has a header that says why it exists and whether it was sent upstream. Patches carried from RiftVM keep its attribution ([legal-and-licensing.md](legal-and-licensing.md) §3).
- A patch that no longer applies fails the build. It is never skipped.
- `scripts/check-lock.sh --apply` serializes patch applications with an advisory lock under `ThirdParty/out/`. It requires every pinned source checkout to have the exact locked commit, no symlinked checkout path, in-checkout Git and shared Git metadata, no in-progress Git operation, no tracked-index flags, no tracked, untracked, or ignored working-tree changes, and a detached HEAD. Reference-only entries are skipped.
- Git subprocesses ignore system and global configuration, disable command-based helpers such as fsmonitor and hooks, disable optional index writes, and reject configured clean/smudge filters and merge drivers. Git config includes are rejected before Git reads them. Lock and patch inputs are opened without following path symlinks, must be regular files, and are read into bounded snapshots; each patch snapshot is used for both preflight and application. Every patch series is first applied in a disposable clone, then applied to a random root-level staging directory opened before Git runs. The command opens output directories without following symlinks and atomically publishes the verified checkout with a directory-descriptor-relative rename at `ThirdParty/out/patched-src/<name>/<commit>/<patch-set SHA-256>/`. It checks the output directory identities before and after publication and attempts to roll back if they changed. Directory descriptors pin inodes, not pathnames: a same-user process can still move the staging directory while Git runs or move a checkout between publication and rollback. Such out-of-band changes can redirect writes or make reported recovery paths stale, so rollback and diagnostics are best effort under concurrent same-user filesystem mutation. The pinned input checkouts remain unchanged during normal operation. The command never runs `git am --abort` or `git reset --hard`.

### 6.3 virglrenderer, libepoxy, ANGLE

| Library | Pin | License | Build |
|---|---|---|---|
| virglrenderer | `960bd667` + patches | MIT | Meson, against libepoxy and ANGLE's EGL |
| libepoxy | `1b6d7db` | MIT | Meson, EGL only, no GLX or X11 |
| ANGLE | `2d91f554` (`chromium/7151`) | BSD-3-Clause | GN and Ninja with pinned depot_tools; Metal backend only (`angle_enable_metal=true`, GL, Vulkan, and SwiftShader backends off) |

```bash
scripts/build-third-party.sh virgl-runtime
# → ThirdParty/out/virgl-runtime/<lock hash>/{libvirglrenderer.dylib, libepoxy.dylib, libEGL.dylib, libGLESv2.dylib}
```

- The driver script calls `ThirdParty/build/build-angle.sh`, `build-libepoxy.sh`, and `build-virglrenderer.sh` in that order ([../02-design/graphics.md](../02-design/graphics.md) §5.1). Pinned source checkouts are fetched into `ThirdParty/out/src/<name>/<commit>/`; patched source checkouts are generated at `ThirdParty/out/patched-src/<name>/<commit>/<patch-set SHA-256>/` and are the build inputs.
- Entries with `ships: reference`, such as RiftVM, are validated as lock records but are not fetched, patched, or built by `scripts/build-third-party.sh` or `scripts/check-lock.sh --apply`.
- The outputs are arm64 dylibs with `@rpath` install names, built for macOS 27.0. `apkrund` finds them through `@executable_path/../Frameworks/VirGLRuntime`.
- ANGLE needs about 11 GB of checkout and build space. The output is cached by lock hash on developer machines and in CI, so ANGLE is rebuilt only when its pin, flags, patches, or build script change.
- #020 acceptance: a fresh checkout produces the libraries with this one command and no manual edits. The weekly `clean-third-party` job checks it with an empty cache (§15.1).

### 6.4 Image tooling inputs: mkbootimg and avbtool

`Images/tools/vendor/` holds pinned copies of `mkbootimg.py` and
`unpack_bootimg.py` from `platform/system/tools/mkbootimg`, its imported
`gki/generate_gki_certificate.py` helper, and `avbtool.py` from
`platform/external/avb`. `mkbootimg.py` builds the synthetic test boot images
(#008) ([../02-design/android-image.md](../02-design/android-image.md) §1.2).
They are `kind: vendored` entries with the AOSP commit and a `files` array of
repository-relative paths and SHA-256 hashes. `scripts/check-lock.sh` verifies
each listed file and fails if it changes without a lock update. Local changes
to them are not allowed; wrap them in `apkrun_image` instead.

### 6.5 Other pinned inputs

| Input | Kind | Ships | Notes |
|---|---|---|---|
| aapt2 (`com.android.tools.build:aapt2:8.9.1-12782657:osx` from Google Maven) | prebuilt | app (`Resources/tools/aapt2`) | its arm64 slice is checked with `lipo`; golden tests pin its output format; it runs under `sandbox-exec` ([../02-design/package-store.md](../02-design/package-store.md) §4.3) |
| Alpine `linux-virt` kernel and minirootfs, `socat`, `libgpiod` | prebuilt | tooling | the test Linux guest ([../02-design/vm.md](../02-design/vm.md) §12); never shipped |
| RiftVM `riftvm-v0.6.1` (`github.com/riftvm/riftvm`, `51f19193b1d3326b2e164d37a2a59e9970375170`) | source, pinned as `riftvm` | reference | analysis-only source for #018; not built, copied, imported, or distributed ([../02-design/graphics.md](../02-design/graphics.md) §2.3; [../04-plan/implementation-review.md](../04-plan/implementation-review.md) IR-188) |
| apksig test vectors | vendored | tooling | Apache-2.0, `Packages/APKStoreCore/Tests/APKStoreCoreTests/Resources/apksig/` ([../02-design/package-store.md](../02-design/package-store.md) §4.5) |
| swift-protobuf, swift-argument-parser, ZIPFoundation | swiftpm | app | exact versions in `Package.swift` (ZIPFoundation: ADR-0017) |
| Sparkle 2 | swiftpm | app | exact version in `project.yml`; confirmed by #057 step 1 (R-23) |
| Kotlin stdlib, kotlinx-coroutines, protobuf-javalite | gradle | image and app (`Resources/guest/`) | `Guest/gradle/libs.versions.toml`; the resolved versions are locked in `Guest/<module>/gradle.lockfile` (Gradle dependency locking, `./gradlew -p Guest dependencies --write-locks`) |
| libc, log, android_logger crates | cargo | image | `Guest/vsockd/Cargo.lock`; the product build uses the same crates from AOSP `external/rust/crates` |
| depot_tools (`f70835271105ca56d2cd5382a0118152bc2bdeea`) | source, pinned in `ThirdParty/ThirdParty.lock.json` | tooling | used only by the ANGLE build; in the `virgl-runtime` lock group so its revision changes the renderer cache key |

### 6.6 Caches

| Cache | Key | Where |
|---|---|---|
| `virgl-runtime` outputs | lock hash | `ThirdParty/out/virgl-runtime/<lock hash>/` locally, the runner's persistent cache in CI |
| third-party sources | commit | `ThirdParty/out/src/` |
| patched third-party sources | patch-set SHA-256 | `ThirdParty/out/patched-src/` |
| pinned tools | version and hash | `build/tools/` |
| Gradle | wrapper and catalog hash | `~/.gradle` |
| Cuttlefish downloads | build ID and artifact hash | `Images/work/<buildId>/download/` |

Caches are an optimization only. Deleting `ThirdParty/out/` or `build/` must never change a result.

### 6.7 Upstream security check

The CI workflow `third-party-security.yml` runs daily ([../02-design/graphics.md](../02-design/graphics.md) §11):

1. For every `kind: source` or `prebuilt` entry with an `upstream` block, it lists upstream commits and tags newer than the pin.
2. It queries the OSV database for the pinned commit or version.
3. It flags commits whose message or linked issue mentions a CVE, "security", or an OSS-Fuzz crash.
4. It opens or updates one issue per component with the label `third-party-security`, listing what it found. It never changes the pin itself.

A maintainer triages the issue within one week. A fix that affects the virglrenderer command decoder (the largest attack surface) is a release blocker for the next APKRun release. Updating a pin is a normal pull request: lock entry, patches rebased, `components.json` version label, notices, and the T1 renderer smoke tests.

### 6.8 Adding or updating a component

1. Adding a component with runtime impact needs an ADR ([../01-architecture/decisions/README.md](../01-architecture/decisions/README.md)) and a place in the dependency graph ([../01-architecture/modules.md](../01-architecture/modules.md) §3).
2. Add the lock entry with the full commit, license, license files, and `ships`.
3. Check the license against [legal-and-licensing.md](legal-and-licensing.md) §4. A component with an unknown or copyleft license that would ship in the app needs a maintainer decision before the pull request is merged.
4. Add the build script under `ThirdParty/build/` if it is built from source.
5. Regenerate the notices (§11) and run the affected tests.

---

## 7. Guest builds

### 7.1 Kotlin agents (Gradle)

```bash
scripts/build-guest.sh            # ./gradlew -p Guest assembleRelease, then copies to Guest/build/out/
ls Guest/build/out/               # apkrun-guest.apk  apkrun-store.apk
```

- One Gradle build in `Guest/` (`settings.gradle.kts`) with the modules `protocol`, `common`, `guestd`, and `APKRunStore` ([../02-design/guest-components.md](../02-design/guest-components.md) §2).
- `minSdk` 34, `compileSdk` 37, `targetSdk` 37, Kotlin JVM target 17. Dependencies are Kotlin stdlib, kotlinx-coroutines, and protobuf-javalite only.
- Release builds compile out debug logging through `BuildConfig.DEBUG`.
- Version: `versionCode = major × 1,000,000 + minor × 1,000 + patch` of the APKRun version that builds them, `versionName` = APKRun version plus the git revision. `build-guest.sh` reads the version from `project.yml` so host and guest agree. The Guest Agent's `versionCode` is written to `components.json` as `devGuestAgentVersionCode`.
- Signing: the development key in `Tests/Fixtures/signing/` ([../02-design/guest-components.md](../02-design/guest-components.md) §2). On the custom image the product re-signs them with the platform key (§9).
- `APKRun.app/Contents/Resources/guest/apkrun-guest.apk` is the development-mode copy used on stock images.

### 7.2 apkrun_vsockd (Rust)

```bash
cd Guest/vsockd
cargo ndk -t arm64-v8a build --release     # target/aarch64-linux-android/release/apkrun_vsockd
cargo test                                 # T0 on the host
cargo clippy --all-targets -- -D warnings
```

- Development builds use cargo-ndk with the pinned NDK ([environment-setup.md](environment-setup.md) §2.6). They are for the #034 validation, where the binary is pushed with `adb` to a userdebug image.
- The product build compiles the same sources with Soong (§9). The crate therefore uses only `std`, `libc`, `log`, and `android_logger`, all available in AOSP `external/rust/crates`.
- The `vsock_loopback` test is T1. It runs in the `test-linux` job on `ubuntu-latest` ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.3), which loads the kernel module first: `sudo modprobe vsock_loopback && cargo test --features vsock-loopback -- --ignored vsock_loopback`. If the hosted kernel lacks the module, #035 moves the test to the `apkrun-aosp` runner and updates this section.

---

## 8. Test fixtures

The fixture catalog (apps, variants, keys, repositories, golden files) is [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4. This section says how the fixtures are built and where they live.

| Path | Content | Built by |
|---|---|---|
| `Tests/Fixtures/AndroidApps/` | a separate Gradle project with the fixture apps | `scripts/build-fixtures.sh` → `Tests/Fixtures/AndroidApps/out/` (git-ignored, reproducible) |
| `Tests/Fixtures/apks/` | committed copies of the fixture APKs and derived packages that T0 tests read, so `swift test` needs no Gradle (NFR-DEV-02) | `scripts/build-fixtures.sh --refresh-committed`; `scripts/check-fixtures.sh` fails when a copy is older than its sources (§3) |
| `Tests/Fixtures/signing/` | test-only keys: `test-fixture-a.jks`, `test-fixture-b.jks`, `test-fdroid-repo.jks`, `test-sparkle-ed25519` (and `.pub`), `test-image-ed25519` (and `.pub`), `test-guest-dev.jks` ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4.4, [../01-architecture/security-model.md](../01-architecture/security-model.md) §7) | committed |
| `Tests/Fixtures/update-repos/` | Local, Direct, F-Droid, and GitHub provider fixtures | `scripts/build-fixtures.sh --update-repos`; the F-Droid repository is built with `fdroid update` and `test-fdroid-repo.jks` in CI |
| `Tests/Fixtures/runtime-updates/appcast/`, `Tests/Fixtures/runtime-updates/image-feed/` | the local appcast for `ReleaseUpdateTest` builds 9000 and 9001, and the local image feeds (valid, tampered, replayed sequence, expired) | the `maintenance` job writes the appcast with `generate_appcast` and the test Sparkle key. The T1 feeds are committed and signed with `test-image-ed25519`. The T2 feed that offers image B is written at run time and signed with the lab Mac's development image key (`image-feed.py --key`, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §13 #087) |
| `Tests/Fixtures/schemas/<file>/v<n>.json`, `v<n>.expected.json` | migration golden files ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5) | committed |
| `Tests/Fixtures/linux/` | `/init` of the test initramfs and the test disk scripts | committed; the kernel comes from `scripts/fetch-test-linux.sh`, the initramfs from `scripts/build-test-initramfs.sh` |
| `Tests/Fixtures/fuzz/<target>/` | seed corpora and crash reproducers (§15.2) | committed |
| `Tests/Fixtures/graphics/`, `Tests/Fixtures/compile-fail/` | the recorded `kmscube` command stream; compile-fail sources | committed |
| `Packages/GuestProtocol/testdata/frames/` | golden protocol frames | committed |

A committed fixture file is at most 10 MiB. Larger inputs are generated at test time from a seed or kept in the runner cache with a pinned SHA-256 ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4.1).

### 8.1 Fixture apps

Each fixture app is a Gradle module with a CamelCase name and the package `io.apkrun.fixture.<lowercase name>` (OddName uses `io.apkrun.fixture.odd_name`). The apps, their events, and their users are listed in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4.2. The fixture project may use AndroidX and Compose; the Guest rules of §7.1 do not apply to it. Its AGP and Kotlin versions are the same as in `Guest/`.

| Build rule | Apps |
|---|---|
| one plain APK, signed with `test-fixture-a.jks` | HelloText, HelloCompose, HelloGL, HelloWebView, HelloNotification, HelloClipboard, HelloLinks, HelloFiles, HelloFilesPeer, HelloAudio, OtherInstaller, IconLegacy, OddName, HelloProbe |
| product flavors for the variants of [test-strategy.md](../04-plan/test-strategy.md) §4.3 | HelloUpdate: V1, V2, V2-other-signer (`test-fixture-b.jks`), V3-broken, V4; the rotation variants are signed afterwards with the pinned `apksigner rotate` and `sign --lineage`; the corrupted V2 is written by a script that flips one byte in `classes.dex` |
| an App Bundle, split with the pinned bundletool | HelloSplit (base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, a feature split) and the container fixtures derived from it ([../02-design/package-store.md](../02-design/package-store.md) §4.4, §16) |
| two ABI flavors | HelloNative: `arm64-v8a` and `armeabi-v7a` only |
| v1 signing only, `targetSdk` 29 | HelloLegacySig |

The build is reproducible: the same sources and pinned tools give the same APK bytes, which is what `scripts/check-fixtures.sh` relies on.

`scripts/build-fixtures.sh` also fills `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/` from the HelloUpdate V1 and V2 builds ([../02-design/update-system.md](../02-design/update-system.md) §4.3). `scripts/dev/update-server.py` serves the Local fixtures and the `direct/` variants as Direct manifests on `127.0.0.1` for Debug builds. `--delay <seconds>` holds every answer for that long, for `update-check-launch` and the #074 tests (#050). For every other fixture package of §8.1 it also serves a Direct manifest at the fixture's own versionCode, so a check of that package ends as up to date. `update-check-launch` needs this for its 10 packages with a provider (#074 adds it).

---

## 9. AOSP product build

The APKRun product (`Guest/product/`, [../02-design/android-image.md](../02-design/android-image.md) §11) builds on the Linux builder of [environment-setup.md](environment-setup.md) §5.

`scripts/aosp/build-product.sh --revision <commit> --variant userdebug|user` does the following inside the builder container:

1. Syncs the tree to `Guest/product/manifest/pinned.xml` if it is not already there.
2. Writes `.repo/local_manifests/apkrun.xml`, which adds this repository at `<commit>` and maps `Guest/product/` to `device/apkrun/apkrun_arm64/`. The Rust crate needs its own `Android.bp` in `Guest/vsockd/`, because Soong does not accept `..` in `srcs`. #035 verifies that the mapping makes Kati and Soong see each product file exactly once. If a `repo` `<linkfile>` does not work, the script copies the directories instead, and this section is updated.
3. Runs `scripts/build-guest.sh` and copies the two APKs to `Guest/product/prebuilt/` (git-ignored), which `android_app_import` reads with `certificate: "platform"`, `privileged: true`, `presigned: false`.
4. Runs `lunch apkrun_arm64-trunk_staging-<variant>`, `m`, and `m dist` with `BUILD_NUMBER=ar<counter>`.
5. For `user` builds, signs the target files with the release keys and rebuilds the image zip (the flow is fixed in #035, OQ-36).
6. Writes `build-info.json`: pinned manifest SHA-256, container image digest, APKRun revision, APK SHA-256s, `BUILD_NUMBER`.

The resulting `apkrun_arm64-img-ar<counter>.zip` enters the same pipeline as a stock build (§10). `scripts/check-sepolicy.sh` runs before step 4 for `user` builds (R-13).

---

## 10. Runtime image bundle and archive

### 10.1 Development bundle (#065)

```bash
source Images/tools/.venv/bin/activate
python3 -m apkrun_image keygen --out ~/.config/apkrun/dev-image-key      # once per developer
python3 scripts/inventory-cuttlefish.py Images/work/16373615/download/
python3 -m apkrun_image bundle \
  --manifest Images/manifests/16373615/android-image.json \
  --layout   Images/tools/layouts/cuttlefish-phone-arm64.json \
  --reference Images/reference/16373615/target \
  --image-version 2026.10.0 \
  --sign-key ~/.config/apkrun/dev-image-key \
  --out Images/work/16373615/bundle/
apkrun-dev dev image install Images/work/16373615/bundle/
```

- The bundle is deterministic: the same inputs and tool revision give identical bytes. The T1 job builds the fixture bundle twice and compares `SHA256SUMS` ([../02-design/android-image.md](../02-design/android-image.md) §10.2).
- `kind` is `stock` for ci.android.com builds (development only) and `apkrun` for our product.
- The image version gets its base suffix automatically, for example `2026.10.0-cf16373615-arm64` or `2026.10.0-ar000123-arm64`.
- The development key's ID is trusted only by Debug and `ReleaseUpdateTest` builds (§2.4). Release builds trust the release image keys only.

### 10.2 Release archive (#087)

On a Mac, the image release job packs a bundle that was signed with the release image key:

```bash
aa archive -a lzfse -d Images/work/<buildId>/bundle -o build/release/images/<imageVersion>.aar
shasum -a 256 build/release/images/<imageVersion>.aar
python3 scripts/release/image-feed.py add --channel beta --archive build/release/images/<imageVersion>.aar
```

`image-feed.py` writes the feed entry and signs `feed.json` ([workflow.md](workflow.md) §10). Only `kind: apkrun` bundles built from source are published ([../02-design/android-image.md](../02-design/android-image.md) §2.3).

---

## 11. App bundle assembly

The layout is fixed by [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §4. The `APKRun` target produces it with these phases:

| Phase | Puts | From |
|---|---|---|
| Embed Helpers (copy files) | `Contents/Helpers/apkrund`, `Contents/Helpers/APKRunLauncher.app` | the targets of §2.2 |
| Embed Login Items (copy files) | `Contents/Library/LoginItems/APKRunMenuBar.app` | the `APKRunMenuBar` target |
| `scripts/build/write-launch-agent.sh` | `Contents/Library/LaunchAgents/io.apkrun.apkrund.plist` (`.dev` / `.updatetest` label, Mach service, `BundleProgram` = `Contents/Helpers/apkrund`) | `Daemon/apkrund/LaunchAgent.plist.in` |
| Embed Frameworks | `Contents/Frameworks/Sparkle.framework` | Sparkle package |
| `scripts/build/embed-virgl-runtime.sh` | `Contents/Frameworks/VirGLRuntime/` | `ThirdParty/out/virgl-runtime/<lock hash>/`; fails with the `build-third-party.sh` command if missing |
| `scripts/build/embed-cli.sh` | `Contents/Resources/bin/apkrun` | `swift build -c <debug|release> --product apkrun` (with `--traits EmbeddedRuntime` in Debug), with an embedded Info.plist |
| `scripts/build/embed-tools.sh` | `Contents/Resources/tools/aapt2` | the pinned Maven artifact, hash-checked |
| `scripts/build/embed-guest.sh` | `Contents/Resources/guest/apkrun-guest.apk` | `Guest/build/out/` |
| Copy resources | `compatibility.json` | `Tests/Compatibility/database/compatibility.json`, validated against its schema ([../02-design/diagnostics.md](../02-design/diagnostics.md) §10) |
| `scripts/release/generate-notices.py` | `Contents/Resources/ThirdPartyNotices.html` | `ThirdParty.lock.json`, `Package.resolved`, the Gradle and Cargo locks ([legal-and-licensing.md](legal-and-licensing.md) §6) |
| `scripts/build/write-components.py` | `Contents/Resources/components.json` | §5 |

The runtime image is never inside the app bundle ([../01-architecture/decisions/0011-runtime-image-bundle.md](../01-architecture/decisions/0011-runtime-image-bundle.md)). Release assembly for the release workflow is `scripts/release/assemble-bundle.sh`, which runs `xcodebuild -configuration Release` with `CODE_SIGNING_ALLOWED=NO` and then signs with `scripts/release/sign-bundle.sh` (§12.3).

---

## 12. Signing and notarization

### 12.1 Identities

| Configuration | Identity | Hardened Runtime | Notarized |
|---|---|---|---|
| Debug | "Sign to Run Locally" or the developer's Apple Development certificate | yes (`get-task-allow` added by Xcode for debugging) | no |
| ReleaseUpdateTest | Developer ID Application (CI only) | yes | no |
| Release | Developer ID Application | yes, with secure timestamp | yes (#088) |
| Local wrappers | ad-hoc, per wrapper (§12.5) | yes | no |
| Distribution wrappers | the creator's Developer ID | yes | yes (§12.6) |

All code in one APKRun.app is signed by the same team ID. That is why apkrund needs no `disable-library-validation` for the VirGLRuntime dylibs ([../01-architecture/security-model.md](../01-architecture/security-model.md) §3.2). The XPC code-signing requirements depend on it too ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).

### 12.2 Entitlements

| Binary | File | Entitlements |
|---|---|---|
| APKRun.app | `Apps/APKRun/APKRun.entitlements` | none (App Sandbox off) |
| apkrund | `Daemon/apkrund/apkrund.entitlements` | `com.apple.security.virtualization`; `com.apple.security.device.audio-input` from #084 (Hardened Runtime needs it for the microphone) |
| APKRunLauncher.app, APKRunMenuBar.app | — | none |
| `apkrun` CLI, Release | — | none |
| `apkrun` CLI, Debug | `CLI/apkrun/apkrun-dev.entitlements` | `com.apple.security.virtualization` (embedded mode) |
| APKRunTestHost | `Tests/IntegrationTests/Host/APKRunTestHost.entitlements` | `com.apple.security.virtualization` |

`com.apple.vm.networking` is never used. Adding an entitlement is a security-model change: update [../01-architecture/security-model.md](../01-architecture/security-model.md) §3.2 in the same pull request.

### 12.3 Inside-out signing

`scripts/release/sign-bundle.sh <APKRun.app> <identity>` signs nested code first and the outer bundle last, never with `--deep`. #057 creates it for the `ReleaseUpdateTest` bundles. #088 extends it for the Developer ID release: it confirms the nested-code paths of the pinned Sparkle and fails if a Mach-O file is left unsigned.

```bash
opts=(--force --sign "$IDENTITY" --options runtime --timestamp)
codesign "${opts[@]}" Contents/Frameworks/VirGLRuntime/*.dylib
# Sparkle, in the order Sparkle documents for its nested code
codesign "${opts[@]}" Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
codesign "${opts[@]}" --preserve-metadata=entitlements Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
codesign "${opts[@]}" Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
codesign "${opts[@]}" Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
codesign "${opts[@]}" Contents/Frameworks/Sparkle.framework
codesign "${opts[@]}" --identifier io.apkrun.aapt2 Contents/Resources/tools/aapt2
codesign "${opts[@]}" --identifier io.apkrun.cli Contents/Resources/bin/apkrun
codesign "${opts[@]}" --identifier io.apkrun.apkrund --entitlements Daemon/apkrund/apkrund.entitlements Contents/Helpers/apkrund
codesign "${opts[@]}" Contents/Helpers/APKRunLauncher.app
codesign "${opts[@]}" Contents/Library/LoginItems/APKRunMenuBar.app
codesign "${opts[@]}" --entitlements Apps/APKRun/APKRun.entitlements APKRun.app
codesign --verify --strict --deep --verbose=2 APKRun.app
scripts/check-launcher.sh APKRun.app/Contents/Helpers/APKRunLauncher.app
```

Paths are relative to `APKRun.app` in the sketch. #057 step 1 confirms the Sparkle paths for the pinned version (the XPC services exist only in some Sparkle 2 layouts). The script fails if any Mach-O file in the bundle is left unsigned.

### 12.4 Development signing and VM tests

- Debug builds are signed by Xcode. Scripts that embed code (`embed-cli.sh`, `embed-virgl-runtime.sh`) sign what they copy with `$EXPANDED_CODE_SIGN_IDENTITY`, so the whole bundle has one identity. In development, apkrund checks clients by the cdhashes of the binaries in the same APKRun.app ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).
- Anything that starts a `VZVirtualMachine` needs `com.apple.security.virtualization`. `swift test` runs under a test runner that cannot carry it. Therefore T0 and T1 tests never start a VM, and T2 tests run as the `IntegrationTests` bundle inside the signed `APKRunTestHost`:

```bash
xcodebuild test -project APKRun.xcodeproj -scheme IntegrationTests -testPlan IntegrationTests \
  -configuration Debug -only-test-configuration LinuxGuest \
  APKRUN_TEST_LINUX_DIR="${TMPDIR:-/tmp}/apkrun-test-linux" APKRUN_CI=1 \
  DEVELOPMENT_TEAM="$APKRUN_TEST_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APKRUN_TEST_CODE_SIGN_IDENTITY"
```

- Build the Linux test artifacts in a private temporary directory for local
  T2 runs from `~/Documents`: set `APKRUN_TEST_LINUX_DIR` to
  `${TMPDIR:-/tmp}/apkrun-test-linux` before running the fetch/build scripts,
  and pass the same value as an `xcodebuild` build setting. The hosted tests
  read it from `APKRunTestHost.app/Contents/Info.plist`; a shell export alone
  is not forwarded to the hosted test process. The test host can then open the
  kernel without a macOS Documents-folder access prompt. CI uses `$RUNNER_TEMP`
  for the same reason and passes it as a build setting. Test artifact path
  overrides must be absolute and outside the current account's `~/Documents`,
  even if the shell overrides `HOME`. The fetch/build scripts and test host
  reject direct paths and symlink aliases before looking up anything inside
  Documents or creating artifacts. They resolve external aliases
  component-by-component and stop before a protected Documents lookup. This
  keeps the selected directory consistent when the scripts and test host run
  from different working directories.
- The team and certificate fingerprint come from `APKRUN_TEST_DEVELOPMENT_TEAM` and `APKRUN_TEST_CODE_SIGN_IDENTITY`; CI reads them from repository variables. Xcode's generic `Apple Development` identity name does not reliably select the lab certificate for a manually signed test host, so the fingerprint is explicit.
- `APKRunTestHost` and the hosted test bundles disable hardened runtime to allow XCTest to load the test bundle into the entitled host. This setting is limited to test targets; product targets retain the common hardened-runtime setting of §2.5.
- The test plan `Tests/IntegrationTests/IntegrationTests.xctestplan` has one configuration per suite of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.4 (`LinuxGuest`, `AndroidStock`, `AndroidCustom`, `Maintenance`), each with the test classes and the environment it needs. It sets the automatic retry to one attempt for T2 ([test-strategy.md](../04-plan/test-strategy.md) §2.7).
- The test plan `Tests/AcceptanceTests/AcceptanceTests.xctestplan` has one configuration per gate (`G1`–`G9`, each added by its gate task), plus `ReleaseSmoke` and `Network`. Automatic retry is off, except one retry for `Network` ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.7).
- Tests that go through apkrund use the installed Debug identities (§13). The Maintenance suite builds and installs `ReleaseUpdateTest` bundles instead.

### 12.5 Local wrapper signing

WrapperCore signs each local wrapper at run time, not at build time ([../02-design/wrapper.md](../02-design/wrapper.md) §7.1):

```bash
/usr/bin/codesign --force --sign - --identifier <bundleID> --options runtime --timestamp=none <staging>/<name>.app
```

- No `--deep`; signing is the last write to the bundle. The cdhash goes into the wrapper registry.
- The build's job is to ship a launcher that can be re-signed this way: system frameworks only, arm64 only, no nested code. `scripts/check-launcher.sh` enforces it.
- Before #045, `scripts/dev/make-wrapper.sh <package> <out-dir>` builds a wrapper by hand with the same command and registers it with `apkrun wrapper approve`.

### 12.6 Notarization (#088)

`scripts/release/notarize.sh <path>` handles the app and the DMG:

```bash
ditto -c -k --keepParent APKRun.app build/release/APKRun-notarize.zip
xcrun notarytool submit build/release/APKRun-notarize.zip --keychain-profile apkrun-notary --wait
xcrun stapler staple APKRun.app
spctl --assess --type execute -vv APKRun.app
```

In CI the script uses the API key form (`--key`, `--key-id`, `--issuer`) from the release secrets. After stapling, `scripts/release/make-dmg.sh` builds `APKRun-<version>.dmg` (`hdiutil create -format UDZO`), signs it with the Developer ID, notarizes, and staples it.

Distribution wrappers use the same Apple tools on the creator's Mac through `apkrun wrap <package> --distribution --identity "Developer ID Application: Name (TEAMID)" [--notarize --keychain-profile <profile>]` ([../02-design/wrapper.md](../02-design/wrapper.md) §11). The nightly T3 job creates and notarizes a HelloText distribution wrapper on the lab Mac to keep that path working.

---

## 13. Debug identities and the development install

Debug builds never replace an installed release ([../02-design/runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).

| Item | Release | Debug | ReleaseUpdateTest |
|---|---|---|---|
| App bundle ID | `io.apkrun.APKRun` | `io.apkrun.APKRun.dev` | `io.apkrun.APKRun.updatetest` |
| Other bundle IDs | `io.apkrun.APKRunMenuBar`, `io.apkrun.APKRunLauncher`, `io.apkrun.cli` | same plus `.dev` | same plus `.updatetest` |
| LaunchAgent label | `io.apkrun.apkrund` | `io.apkrun.apkrund.dev` | `io.apkrun.apkrund.updatetest` |
| Mach service | `io.apkrun.apkrund.xpc` | `io.apkrun.apkrund.dev.xpc` | `io.apkrun.apkrund.updatetest.xpc` |
| `APKRUN_HOME` default | `~/Library/Application Support/APKRun/` | `~/Library/Application Support/APKRun-Dev/` | `~/Library/Application Support/APKRun-UpdateTest/` |
| Installed as | `/Applications/APKRun.app` | `~/Applications/APKRun Dev.app` | the build output, lab Mac only |
| CLI name | `apkrun` | `apkrun-dev` | — |

```bash
scripts/dev/install-dev-app.sh          # copies the Debug build, runs "APKRun --register-runtime", links apkrun-dev
launchctl kickstart -k gui/$(id -u)/io.apkrun.apkrund.dev
launchctl print gui/$(id -u)/io.apkrun.apkrund.dev
```

- Registering straight from DerivedData works, but every clean build moves the path. Use the install script.
- `install-dev-app.sh` links `~/.local/bin/apkrun-dev` to the CLI inside the installed Debug app. Release users get `apkrun` through `sudo ln -sf "/Applications/APKRun.app/Contents/Resources/bin/apkrun" /usr/local/bin/apkrun` ([../02-design/cli.md](../02-design/cli.md)).
- Debug builds create wrappers in `~/Applications/APKRun Dev/`. How their bundle IDs differ from release wrappers is decided in #045 together with the mapping in [../02-design/wrapper.md](../02-design/wrapper.md) §4.

---

## 14. Reproducibility

| Artifact | Guarantee | Check |
|---|---|---|
| Generated code (`*.pb.swift`, `ErrorCatalog.generated.swift`, error catalog tables) | byte-identical from the pinned tools | CI diff (§4) |
| Runtime image bundle | byte-identical for the same inputs and tool revision | T1 double build (§10.1) |
| Local wrappers | byte-identical for the same configuration, launcher build, and icon ([../02-design/wrapper.md](../02-design/wrapper.md) §6.5) | T1 in WrapperCore |
| `virgl-runtime` libraries | same inputs → same lock hash; output bytes are not required to match | weekly empty-cache build (§6.3) |
| Guest APKs | same revision → same `versionCode` and content; signatures differ by key | T1 content check |
| APKRun.app | traceable, not bit-for-bit: code signatures carry secure timestamps and a notarization ticket | `components.json` commit, lock hashes, release notes |
| Custom AOSP image | traceable: pinned manifest, container digest, Guest revision | `provenance` in the bundle manifest |

Rules:

- Every input is pinned (§6, [environment-setup.md](environment-setup.md) §2.9). Nothing downloads "latest" during a build.
- The release workflow builds from a clean checkout of a tag, with an empty DerivedData, and refuses a dirty tree.
- Builds do not embed wall-clock timestamps where a tool allows it (`ZERO_AR_DATE=1`, fixed GUIDs and sorted keys in image tooling).

---

## 15. CI jobs by tier

CI runs on GitHub Actions with the runners of [environment-setup.md](environment-setup.md) §6. The tiers, budgets, suites, and retry rules are defined in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2. In short: T0 unit tests without VM, GPU, network, or other processes; T1 host tests with real macOS services, Metal, files, XPC, or local servers, but no VM; T2 tests with a real VM; T3 acceptance, gates, and long or external runs.

Pull request workflows execute source and workflow changes from the pull request, so they run on fresh GitHub-hosted VMs. The required `workflow-policy` job in `ci-policy.yml` checks changes to workflow and CI control files using trusted code from `main`; it does not execute PR source. This gate does not make a persistent self-hosted runner safe for PR jobs. Before registering any persistent runner with GitHub, the repository owner must enforce runner-group access pinned to a separate trusted workflow on `refs/heads/main`, excluding every pull-request workflow. If the account cannot enforce that boundary, do not connect the persistent runner to GitHub Actions. Tests that need self-hosted resources require a separate runner-isolation design before they are added to a pull request gate.

Rows below that use `apkrun-ci` or `apkrun-lab` refer to trusted default-branch or manual runs; use fresh hosted or disposable runners for PR execution. The planned T2 pull-request jobs in `integration.yml` need disposable lab capacity before they can run PR source.

### 15.1 Workflows and jobs

The table describes the planned workflow as its inputs arrive. #062 creates the initial `lint`, `codegen`, `build`, and `test-swift` jobs, plus the required metadata-only `workflow-policy` job; later tasks add the jobs for components and test tiers they introduce. Every job present in `ci.yml` is required by branch protection, as is `workflow-policy` for pull requests to `main`.

| Workflow | Trigger | Job | Tier | Runner | Content |
|---|---|---|---|---|---|
| `ci-policy.yml` | opened, reopened, synchronize, edited, labeled, or unlabeled pull request events targeting `main` | `workflow-policy` | — | `ubuntu-latest` | trusted `main` code checks current PR head/base, changed paths, and reviews through read-only GitHub API; control paths include workflows, Xcode/Gradle build and convention scripts, generators, dependency pins, CI tool/formatter settings, test/build manifests, test trees, and the module graph; the approver must apply `ci-policy-approved`; a new commit, reopen, PR edit, or later label event resets the check, and removing the label revokes it |
| `ci.yml` | every pull request, push to `main` | `lint` | — | `xcode-27` | §3 checks, `buf lint`, `buf breaking` |
| | | `codegen` | — | `xcode-27` | §4 regeneration, `git diff --exit-code` |
| | | `build` | — | `xcode-27` | `swift build`; `xcodebuild` Debug and Release (unsigned); `scripts/check-launcher.sh`; the release checks of §3.1 on the Release build |
| | | `test-swift` | T0 | `xcode-27` | SwiftPM tests excluding `<Module>SystemTests`; no T1 or host-dependent checks |
| | | `test-guest` | T0, T1 | `xcode-27` for T0; disposable T1 runner for PRs; `apkrun-ci` on `main` | `scripts/build-guest.sh`, Gradle `test` for every Guest module, golden frames, `scripts/build-fixtures.sh` |
| | | `test-images` | T0, T1 | `xcode-27` for T0; disposable T1 runner for PRs; `apkrun-ci` on `main` | `pytest Images/tools/tests`, fixture bundle double build (§10.1) |
| | | `test-linux` | T0, T1 | `ubuntu-latest` | `cargo test`, `cargo clippy`, the T1 `vsock_loopback` test (§7.2), `ruff check`, JSON schema checks, the F-Droid test repository build (`fdroid update`) |
| | | `third-party` | — | `xcode-27` for PRs; `apkrun-ci` on `main` | `scripts/check-lock.sh --apply` against clean, pinned sources, `scripts/build-third-party.sh virgl-runtime` (cached), `scripts/release/generate-notices.py --check` ([legal-and-licensing.md](legal-and-licensing.md) §6.1) |
| | | `fuzz-short` | T1 | disposable T1 runner for PRs; `apkrun-ci` on `main` | 60 s per fuzz target whose code the pull request changes (§15.2) |
| `integration.yml` | matching pushes to `main`; manual dispatch from `main` | `linux-guest` | T2 | persistent `apkrun-lab`, trusted `main` only | suite LinuxGuest; exact path filter below; ≤ 15 min. Pull-request runs remain disabled until disposable lab capacity is provisioned |
| | label `t2-android` or `run-t2` | `android-stock` | T2 | disposable `apkrun-lab` for PRs; `apkrun-lab` on `main` | suite AndroidStock, ≤ 60 min |
| | label `t2-android` or `run-t2` | `android-custom` | T2 | disposable `apkrun-lab` for PRs; `apkrun-lab` on `main` | suite AndroidCustom, ≤ 90 min, with the latest custom `userdebug` image from `nightly.yml` `aosp-build` |
| | label `t2-maintenance` or `run-t2` | `maintenance` | T2 | reviewed local run for PRs; `apkrun-lab` on `main`, environment `signing` | suite Maintenance, ≤ 120 min: builds `ReleaseUpdateTest` 9000 and 9001, writes the local appcast, runs N → N+1 and its variants |
| `nightly.yml` | daily at 01:00 UTC, and manually before a release | `aosp-build` | — | `apkrun-aosp` | `scripts/aosp/build-product.sh --variant userdebug` (§9) when `Guest/` changed since the last build. `user` builds never run on a CI runner ([environment-setup.md](environment-setup.md) §5.6) |
| | | `t2-all` | T2 | `apkrun-lab` | all four T2 suites, including quarantined tests (their results are reported but do not fail the job) |
| | | `gates` | T3 | `apkrun-reference` | `scripts/run-gate.sh G<n>` for every closed gate |
| | | `perf` | T3 | `apkrun-lab`, `apkrun-reference` | `swift run apkrun-perf` against `Tests/PerformanceTests/baselines/<model>.json` |
| | | `compatibility` | T3 | `apkrun-lab` | the F-Droid corpus of `Tests/Compatibility/apps.json`; `scripts/dev/verify-corpus.sh` (apksigner differential) |
| | | `network` | T3 | `apkrun-lab` | `Tests/AcceptanceTests/Network`, one retry, `external` classification |
| | | `soak` | T3 | `apkrun-lab` | 60-minute soak run ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §7.3) |
| | | `fuzz-long` | T3 | `apkrun-ci` | 1 h per fuzz target (§15.2) |
| | | `notarize` | T3 | `apkrun-lab`, environment `signing` | nightly notarization (#088): the Release app and a HelloText distribution wrapper are signed, notarized, stapled, and checked with `spctl` (§12.6) |
| | weekly (Sunday) | `release-smoke` | T3 | `apkrun-reference` | `Tests/AcceptanceTests/ReleaseSmoke` on `main` |
| | weekly (Sunday) | `clean-third-party` | — | `apkrun-ci` | `virgl-runtime` with an empty cache |
| `macos-seed.yml` | manual, after the seed lab Mac installs a new macOS build | `seed` | T2, T3 | `apkrun-seed` | the full T2 set and every closed gate check ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §9.4) |
| `release.yml` | tag `v*`; manual on `main` with the input `dry-run` or `promote` | `release` | — | `apkrun-lab`, environment `release` | [workflow.md](workflow.md) §9 |
| `image-release.yml` | manual, with the input `action` (`candidate`, `beta`, `stable`, `rollout`, `remove`); `candidate` takes the `-user` image zip that a maintainer built on the image build machine | `image-release` | — | `apkrun-lab`, environment `release` | [workflow.md](workflow.md) §10 |
| `image-feed-resign.yml` | weekly (Monday 03:00 UTC) | `resign` | — | `ubuntu-latest`, environment `release` | re-signs both channels' feeds ([workflow.md](workflow.md) §10) |
| `third-party-security.yml` | daily | `upstream` | — | `ubuntu-latest` | §6.7 |

The current `linux-guest` trigger uses this path filter for pushes to `main`.
Enable the same filter for pull requests only after a disposable lab runner is
available ([test-strategy.md](../04-plan/test-strategy.md) §2.4):

```yaml
paths:
  - .github/workflows/integration.yml
  - Packages/VirtualMachineCore/**
  - Packages/RuntimeCore/**
  - Packages/RuntimeHost/**
  - Tests/Fixtures/linux/**
  - Tests/IntegrationTests/**
  - ThirdParty/ThirdParty.lock.json
  - project.yml
  - scripts/build-test-initramfs.sh
  - scripts/fetch-test-linux.sh
  - scripts/tools/with-file-lock.py
```

- The label `run-t2` runs every T2 suite. The labels `t2-android` and `t2-maintenance` run only their suites.
- Every T2 and T3 job uploads the artifacts of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.7. Retention: 14 days for pull requests, 30 days for nightly runs. Gate evidence and release candidate artifacts are attached to their issues and kept permanently.
- A lab Mac runs one job at a time (the runner has one slot), because a lab Mac runs one VM at a time.

### 15.2 Fuzzing

| Item | Choice |
|---|---|
| Swift and C engine | libFuzzer, through a swift.org toolchain pinned as `SWIFT_FUZZ_TOOLCHAIN` in `scripts/tool-versions.env`. Xcode's toolchain does not ship the libFuzzer runtime. #091 confirms the toolchain version |
| Swift and C flags | `swift build -c debug --product <Module>Fuzz --sanitize=fuzzer --sanitize=address --sanitize=undefined` with `APKRUN_FUZZ=1` |
| Kotlin engine | Jazzer (`jazzer-junit`, a test-only Gradle dependency) with `@FuzzTest` in `Guest/protocol` and `Guest/guestd` |
| Targets | the list in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §7.2. The malicious-agent target runs at T2 and is not a libFuzzer target |
| libFuzzer options | `-max_total_time=60` in pull requests, `-max_total_time=3600` nightly; `-timeout=10`; `-rss_limit_mb=2048`; `-artifact_prefix=build/fuzz/<target>/` |
| Corpus | seeds in `Tests/Fixtures/fuzz/<target>/`; the nightly working corpus is kept in the runner cache and merged with `-merge=1` |
| Driver | `scripts/run-fuzz.sh <target> \| --changed \| --all [--seconds <n>]`. `--changed` maps changed paths to targets |
| Crash | the job fails and uploads the reproducer. A crash in `fuzz-long` also opens an issue with the label `fuzz-crash`. The fix adds the reproducer to `Tests/Fixtures/fuzz/<target>/` |
| Regression | each target's entry function lives in `<Module>TestSupport`. A T1 test in `<Module>SystemTests` replays every file of `Tests/Fixtures/fuzz/<target>/` through it without libFuzzer, so reproducers run in every pull request |

`APKRUN_FUZZ=1` is read by `Package.swift` to add the `<Module>Fuzz` executable targets. Without it, the manifest has no fuzz targets, so `swift build` with Xcode's toolchain keeps working.

### 15.3 Rules

- A pull request can merge only when every required `ci.yml` job passes. Until disposable lab capacity is provisioned, the closing pull request must link a maintainer-run result for every T2 suite listed by the task, run against the reviewed commit ([workflow.md](workflow.md) §7; [test-strategy.md](../04-plan/test-strategy.md) §2.4).
- The pull request that closes a task includes a linked result for every T2 suite the task lists. Use the `integration.yml` run when it executes on disposable capacity; otherwise link a maintainer-run result for the reviewed commit ([test-strategy.md](../04-plan/test-strategy.md) §2.4).
- T0 and T1 have no automatic retry. T2 has one automatic retry per test, and the report marks every "passed on retry". Gate checks and the release smoke matrix are never retried.
- A runner that lacks a resource a T1 test needs (Metal device, GUI session, APFS scratch volume, a permission) fails the test with `runnerMissing<Resource>`. It never skips it.
- A T2 failure on `main` blocks every merge until the change is fixed or reverted ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §2.7).
- A failure in a nightly run opens an issue with the label `nightly-failure`. The breaking change is fixed or reverted within one working day. Until then no other pull request merges into the affected area ([workflow.md](workflow.md) §7.4).
- A failure on `apkrun-seed` opens an issue with the label `macos-regression` and updates R-16 in [../04-plan/risks.md](../04-plan/risks.md).
- Gates count only when they pass on the reference Mac with a clean build from `main` ([../04-plan/roadmap.md](../04-plan/roadmap.md) §2).
