# Build System

This document describes how APKRun builds its artifacts: the host app and helpers, guest components, third-party libraries, the runtime image, test fixtures, and the signed release. Machine setup is in [environment-setup.md](environment-setup.md). Items the repository does not have yet are marked *(planned, #NNN)* with the task that adds them.

---

## 1. Quick start

```bash
scripts/bootstrap                                  # pinned tools and Python venv (environment-setup.md §7)
scripts/build-third-party.sh virgl-runtime         # once; later runs use the cache (§6.6)
scripts/build-guest.sh                             # guest agent APK and version record (§7.1)
scripts/generate-project.sh                        # APKRun.xcodeproj from project.yml (§2.2)
swift build && swift test                          # SwiftPM packages and the CLI, tiers T0 and T1
xcodebuild -project APKRun.xcodeproj -scheme APKRun -configuration Debug -derivedDataPath build build
scripts/dev/install-dev-app.sh                     # "~/Applications/APKRun Dev.app" and agent registration (§13)
```

A clean checkout builds and passes `swift test` without manual steps (NFR-DEV-02). A step that needs an artifact outside the repository skips with a message that names the command that produces it. With `APKRUN_CI=1`, the skip is a failure.

---

## 2. Project structure

### 2.1 Package.swift

`Package.swift` in the repository root is the only SwiftPM manifest. The module set is in [modules.md](../01-architecture/modules.md) §1.

| Setting | Value |
|---|---|
| Tools version | `// swift-tools-version: 6.2` |
| Language mode | `swiftLanguageModes: [.v6]` for every target |
| Platform | `.macOS("27.0")` |
| Library products | static only, one per directory in `Packages/` (16), plus the C target `GraphicsBridge` in `Packages/GraphicsCore/Sources/GraphicsBridge/` ([filesystem-layout.md](../01-architecture/filesystem-layout.md) §4) |
| Executables | `apkrun` (`CLI/apkrun`). `apkrun-perf` (`Tests/PerformanceTests/apkrun-perf`) is planned (#71) |
| Test targets | T0: `Packages/<Module>/Tests/<Module>Tests/`, `CLI/apkrun/Tests/` (goldens in `Golden/`). T1: `Packages/<Module>/Tests/<Module>SystemTests/`. `VMRunResourcesTests` compiles `Tests/IntegrationTests/RunResources` ([test-strategy.md](../04-plan/test-strategy.md) §2.2, §2.3, §3.10) |
| Test support | `Packages/<Module>/Tests/<Module>TestSupport/`: the module's protocol fakes. Only test targets depend on them ([test-strategy.md](../04-plan/test-strategy.md) §3.2) |
| Fuzz targets | `Packages/<Module>/Tests/<Module>Fuzz/`, declared only when `APKRUN_FUZZ=1` (planned, #92; §15.2) |
| Dependencies | `swift-protobuf` 1.38.1, `swift-argument-parser` 1.8.2, `ZIPFoundation` 0.9.20 (ADR-0017), all `exact:` |
| Trait `EmbeddedRuntime` | off by default. Adds `RuntimeHost`, `WindowingCore`, `InputCore` to `apkrun`; defines `APKRUN_EMBEDDED_RUNTIME` ([cli.md](../02-design/cli.md) §2) |
| Trait `TestReadback` | off by default. Defines `APKRUN_TEST_READBACK` for GraphicsCore and the CLI ([test-strategy.md](../04-plan/test-strategy.md) §3.3) |

- `Package.resolved` is committed.
- Conditional edges use trait-conditioned dependencies (SE-0450). Keep them in the manifest.
- `GraphicsBridge` takes headers from `ThirdParty/out/virgl-runtime/current/include` and links Foundation, IOSurface, and Metal. Debug links the UBSan runtime that `xcrun clang --print-file-name=libclang_rt.ubsan_osx_dynamic.dylib` reports. Release does not.
- `apkrund` is an Xcode target (§2.2). Its `main` is in `Daemon/apkrund`; its logic is in RuntimeHost.

### 2.2 project.yml and the Xcode project

`project.yml` is the XcodeGen spec for every bundle and everything that needs entitlements. `scripts/generate-project.sh` runs the pinned XcodeGen (2.44.1; [environment-setup.md](environment-setup.md) §2.7) and writes `APKRun.xcodeproj`. That project is git-ignored and never edited by hand. The local package is the package `APKRun`. Sparkle is planned as a remote package with an exact version (#58; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2).

| Target | Type | Release bundle ID | Sources | Links |
|---|---|---|---|---|
| `APKRun` | application | `io.apkrun.APKRun` | `Apps/APKRun` | RuntimeClient, RuntimeAPI, DiagnosticsCore; Sparkle (planned, #58) |
| `APKRunMenuBar` | application (login item) | `io.apkrun.APKRunMenuBar` | `Apps/APKRunMenuBar` | RuntimeClient, RuntimeAPI, DiagnosticsCore |
| `APKRunLauncher` | application | `io.apkrun.APKRunLauncher` | `Apps/APKRunLauncher` | RuntimeClient, RuntimeAPI, WindowingCore, InputCore, DiagnosticsCore |
| `apkrund` | tool, embedded Info.plist (`CREATE_INFOPLIST_SECTION_IN_BINARY`) | `io.apkrun.apkrund` | `Daemon/apkrund` | RuntimeHost |
| `APKRunTestHost` | application hosting the T2 and T3 bundles; hardened runtime off | `io.apkrun.testhost` | `Tests/IntegrationTests/Host` | — |
| `IntegrationTests` | unit-test bundle hosted by `APKRunTestHost` (T2) | `io.apkrun.integration-tests` | `Tests/IntegrationTests/` | VirtualMachineCore, VirtioDeviceCore, GraphicsCore, RuntimeCore, RuntimeHost, ImageCore, InputCore, WindowingCore, RuntimeAPI, DiagnosticsCore |
| `AcceptanceTests` | unit-test bundle hosted by `APKRunTestHost` (T3) | `io.apkrun.acceptance-tests` | `Tests/AcceptanceTests`, some `Tests/IntegrationTests` files | VirtualMachineCore, ImageCore, RuntimeCore, RuntimeHost, DiagnosticsCore |
| `<App>Tests`, `<App>UITests` | planned: T0 and T1 per app | — | `Apps/<App>/Tests/`, `Apps/<App>/UITests/` | the app's modules |

- The CLI is not an Xcode target; the `APKRun` target builds and embeds it (§11).
- The design restricts `APKRunTestHost` to Debug. `project.yml` does not yet.
- Every target that preprocesses an Info.plist with the `BuildStamp.h` prefix depends on the `BuildStamp` aggregate target, including `APKRunTestHost`. `BuildStamp` runs `scripts/build/stamp-commit.sh`, which writes `build/generated/BuildStamp.h`: the seven-character Git revision, plus `-dirty` when the tree has changes.

### 2.3 Schemes

| Scheme | Builds | Action |
|---|---|---|
| `APKRun` | APKRun.app with its helpers | runs APKRun.app |
| `APKRunMenuBar`, `APKRunLauncher`, `apkrund` | the target | XcodeGen creates one scheme per target |
| `apkrund (attach)` | APKRun.app | planned: waits for `apkrund` to launch, for daemon debugging ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6) |
| `IntegrationTests` | `APKRunTestHost`, `IntegrationTests` | T2, test plan `IntegrationTests` (§12.4) |
| `AcceptanceTests` | `APKRunTestHost`, `AcceptanceTests` | T3, test plan `AcceptanceTests` (§12.4); run by `scripts/run-gate.sh` and `nightly.yml` |
| `APKRunUITests` | APKRun.app and the UI test bundle | planned: T1 XCUITest |

### 2.4 Build configurations

| Configuration | Use | Differences |
|---|---|---|
| `Debug` | development | `APKRUN_BUILD_IDENTITY` = `dev`. Test hooks: `APKRUN_TEST_HEADLESS_LAUNCH`, `APKRUN_LAUNCHER_TEST_NO_RUNTIME`, `APKRUN_STORE_FAULT`; planned: `APKRUN_GRAPHICS_FAULT` (#60), `APKRUN_RUNTIME_FAULT` (#60, #61), `APKRUN_TEST_MARKER_TIMEOUT` (#58) and the others of [test-strategy.md](../04-plan/test-strategy.md) §3.3 ([configuration.md](../03-reference/configuration.md) §5.1). The development image key is trusted (§10.1). Development signing (§12.4). `-Onone` |
| `Release` | shipped builds | `APKRUN_BUILD_IDENTITY` = `release`. Developer ID signing (§12). Release image keys only (planned, #66). Sparkle feed and key (planned, #58). `-O`, whole-module optimization. No test hooks (§3.1) |
| `ReleaseUpdateTest` (planned, #58) | the T2 "APKRun N → N+1" test ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §14) | Release settings, plus: `SUFeedURL` at the local appcast server `scripts/dev/appcast-server.py` on `127.0.0.1`; `SUPublicEDKey` from `Tests/Fixtures/signing/test-sparkle-ed25519.pub`; identity suffix `.updatetest`; Developer ID signed, not notarized; honors `APKRUN_TEST_MARKER_TIMEOUT`; Sparkle test user driver; trusts the build machine's development image key and the release image keys ([android-image.md](../02-design/android-image.md) §10.1). The Maintenance suite builds versions 9000 and 9001 (9001 adds `Resources/test-build-marker`) |

- `APKRUN_BUILD_IDENTITY` (`dev`, `release`, `updatetest`) sets the bundle ID suffix, LaunchAgent label, and Mach service name. Each bundle's Info.plist and the embedded Info.plists of `apkrund` and the CLI copy it as `APKRunBuildIdentity`. `RuntimeClient` reads it to pick the service name ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).
- Xcode builds local packages only in Debug or Release. Package code must not use compilation conditions for anything that differs in `ReleaseUpdateTest`.

### 2.5 Common build settings

| Setting | Value |
|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | `27.0` |
| `ARCHS` | `arm64` |
| `SWIFT_VERSION` | `6.0` in `project.yml`; the Swift 6 mode is in `Package.swift` |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS`, `GCC_TREAT_WARNINGS_AS_ERRORS` | `$(APKRUN_CI)`: `YES` in CI, `NO` locally |
| `ENABLE_HARDENED_RUNTIME` | `YES` for product targets; `NO` for `APKRunTestHost` and test bundles (§12.4) |
| `ENABLE_APP_SANDBOX` | `NO` for app targets (§12.2) |
| `DEAD_CODE_STRIPPING` | `YES` (Xcode default for Release; not set in `project.yml`) |
| `MARKETING_VERSION` | `0.1.0` in `project.yml`; the next release version, MAJOR.MINOR.PATCH |
| `CURRENT_PROJECT_VERSION` | `1` in `project.yml`; the release workflow passes the build number ([workflow.md](workflow.md) §8.2) |
| Localization | String Catalogs (`Localizable.xcstrings`), `en` and `ja` (NFR-L10N-01); planned (#45, #93) |

All executables in one APKRun.app carry the same `CFBundleShortVersionString` and `CFBundleVersion` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1).

---

## 3. Static checks

Most checks run without arguments. `scripts/ci/run-checks.sh`, run by the `lint` job, runs the checks marked *yes*. Checks that need build artifacts run at the stage that creates them.

| Script | Checks | Task | `lint` |
|---|---|---|---|
| `scripts/check-module-deps.sh` | `scripts/tools/check-module-deps.swift`: import edges against [modules.md](../01-architecture/modules.md) §3; third-party products used only where the graph names them; trait-conditioned edges only `EmbeddedRuntime` → `apkrun` | #63 | yes |
| `scripts/check-logging.sh` | `scripts/tools/check_logging.py`: no `os.Logger`, `Logger(`, `print(`, `NSLog`, `os_log` outside DiagnosticsCore; every `APKLogger` interpolation has a privacy argument and no `Sensitive` value | #62 | yes |
| `scripts/check-compile-fail.sh` | sources in `Tests/Fixtures/compile-fail/` must fail to compile. Needs Apple silicon | #62 | no |
| `scripts/check-todos.sh` | `scripts/tools/check_todos.py`: each `TODO` or `FIXME` in a tracked source file is followed directly by `(#NNN)` (NFR-DEV-04) | #63 | yes |
| `scripts/check-format.sh` | `swift-format lint --strict` (`.swift-format`, `.swift-format-tests`); `ktfmtCheck`; `cargo fmt --check` for `Guest/vsockd`; `ruff format --check` for `Images/tools`. `--fix` formats ([coding-conventions.md](coding-conventions.md) §2) | #63 | yes |
| `scripts/check-lock.sh` | `ThirdParty/ThirdParty.lock.json` and patches; Swift pins against `Package.resolved` and `project.yml` (§6.1). `--apply` applies patches (§6.2) | #63; `--apply` #21 | yes |
| `scripts/check-protos.sh` | `buf lint` on `Packages/GuestProtocol` | #34 | yes |
| `scripts/tests/run.sh` | self-tests of `scripts/` | #63 | yes |
| `scripts/check-raw-adb.sh` | no `adb shell` or `pm ` outside the allowlist: `ADBStoreAgentChannel.swift`, `AdbClient.swift`, tests, `scripts/dev/`, `Tests/Compatibility/`, `Experiments/`, `Images/tools/reference/`, generated protobuf ([test-strategy.md](../04-plan/test-strategy.md) §3.3) | #28 | yes |
| `scripts/check-launcher.sh` | built APKRunLauncher: `otool -L` lists only `/System/Library` and `/usr/lib`; `lipo -archs` is `arm64`; minimum OS 27.0 | #69 (planned) | no |
| `scripts/check-sepolicy.sh` | compiled policy: userdebug contains the two #36 agent domains as permissive; `user` contains none (R-13) | #36 | no (AOSP build) |
| `scripts/check-fixtures.sh` | APKs in `Tests/Fixtures/apks/` are newer than their sources; no committed fixture over 10 MiB (§8) | #42 (planned) | no |
| `scripts/check-compatibility-db.sh` | `compatibility.json` against `compatibility.schema.json` ([diagnostics.md](../02-design/diagnostics.md) §10) | #91 (planned) | no |
| `scripts/check-licenses.sh` | SPDX license and committed `licenseFiles` for every lock entry, `Package.resolved`, and the Gradle and Cargo locks; allowed licenses per `ships` ([legal-and-licensing.md](legal-and-licensing.md) §4); the `Derived from RiftVM` marker names the pin ([legal-and-licensing.md](legal-and-licensing.md) §3.1) | #94 (planned) | no |
| `scripts/check-strings.sh` | `.xcstrings` and `errors.json`: for Release, no missing `ja`, `stale`, or `needs review`; Debug only warns ([host-ui.md](../02-design/host-ui.md) §13) | #93 (planned) | no |

A new dependency edge or third-party component needs an ADR before its check changes ([decisions/README.md](../01-architecture/decisions/README.md)).

### 3.1 Release checks

`scripts/release/check-release-build.sh <APKRun.app> [<image bundle>]` runs on the Release build in the `build` job and in the release jobs ([workflow.md](workflow.md) §9). Each check has a fixture that fails it ([test-strategy.md](../04-plan/test-strategy.md) §3.3).

| Check | Rule |
|---|---|
| no test hooks | `strings` over Mach-O files finds no `APKRUN_*_FAULT`, `APKRUN_TEST_*` (such as `APKRUN_TEST_HEADLESS_LAUNCH`), `APKRUN_LAUNCHER_TEST_NO_RUNTIME`, or `ReleaseUpdateTest` |
| no test keys | a test keystore is accepted only if its name and full-file SHA-256 match `scripts/release/test-keystore-pins.json`. Bundles are refused if they contain a pinned keystore's bytes, fragments, certificate or public key, or a zip member with them. Other keystores, and `.jks` files not named `test-*` and pinned, fail as unsupported |
| image trust | planned (#66): `ImageTrustStore` of Release holds only release key IDs ([android-image.md](../02-design/android-image.md) §10.1) |
| image manifest | no `androidboot.apkrun.test.*` key ([android-image.md](../02-design/android-image.md) §6.2) |
| notices | `Contents/Resources/ThirdPartyNotices.html` matches the locked components with `ships: app` or `derived` ([legal-and-licensing.md](legal-and-licensing.md) §6) |
| key rotation | planned (#58): the Sparkle key and the Developer ID certificate are not both changed from the previous release (R6, [workflow.md](workflow.md) §9.1) |
| build number | planned (#58): `CFBundleVersion` above every published build on every channel (R1, [workflow.md](workflow.md) §9.1) |
| migration chain | planned (#58): a golden `Tests/Fixtures/schemas/<file>/v<n>.json` for each schema version of stable releases in the last 24 months (R5, [workflow.md](workflow.md) §9.1; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §5) |

The last three rows read the appcast and the `components.json` of published releases ([workflow.md](workflow.md) §9.4) and run only in the release job.

---

## 4. Code generation

Generated files are committed. The `codegen` job runs `scripts/ci/codegen.sh`, which regenerates them and fails on any diff or untracked generated output.

| Output | Source | Command | Pinned by |
|---|---|---|---|
| `Packages/GuestProtocol/Sources/GuestProtocol/Generated/*.pb.swift` | `Packages/GuestProtocol/proto/apkrun/guest/v1/*.proto` | `scripts/generate-protos.sh` | protoc 31.1, protoc-gen-swift ([environment-setup.md](environment-setup.md) §2.7) |
| `Packages/GuestProtocol/testdata/frames/*.bin` | `valid-*.txtpb`; invalid frames are fixed bytes | `scripts/generate-protos.sh` | protoc |
| Kotlin protocol classes in `Guest/protocol/build/` (not committed) | the same `.proto` files | Gradle protobuf plugin, lite option | protoc of the same release (`protobuf` 4.31.1) |
| `Packages/DiagnosticsCore/Sources/DiagnosticsCore/Errors/ErrorCatalog.generated.swift` | `Packages/DiagnosticsCore/ErrorCatalog/errors.json` | `swift scripts/errorgen.swift` | the toolchain |
| tables in [error-catalog.md](../03-reference/error-catalog.md) | `errors.json` | `swift scripts/errorgen.swift --markdown` | the toolchain |
| `APKRun.xcodeproj` (not committed) | `project.yml` | `scripts/generate-project.sh` | XcodeGen 2.44.1 |

### 4.1 Protocol buffers

- File options: `package apkrun.guest.v1`, `java_package "io.apkrun.guest.protocol.v1"`, `java_multiple_files = true`, `swift_prefix "GP"` ([guest-protocol.md](../02-design/guest-protocol.md) §2).
- `scripts/generate-protos.sh` uses only the tools in `build/tools/`, runs `protoc --swift_opt=Visibility=Public,FileNaming=DropPath`, removes stale output first, and writes the golden frames.
- `scripts/bootstrap` builds `protoc-gen-swift` from the swift-protobuf revision in `Package.resolved` (never a branch) and records it in `build/tools/protoc-gen-swift/REVISION`.
- Buf configuration `Packages/GuestProtocol/buf.yaml`: `version: v2`, module `proto`, `lint.use: STANDARD`, `enum_zero_value_suffix: _UNSPECIFIED`, `breaking.use: FILE`.
- `buf breaking` is planned (#34): `buf breaking Packages/GuestProtocol --against ".git#tag=<last v tag>,subdir=Packages/GuestProtocol"`. A breaking change needs a major version, an ADR, and a transition window ([coding-conventions.md](coding-conventions.md) §6.1).
- Swift and Kotlin tests decode the golden frames.

### 4.2 Error catalog

`errors.json` is the source. `errorgen` compiles every language into Swift literals, because the launcher has no resource bundles ([diagnostics.md](../02-design/diagnostics.md) §2). A T0 test checks that `CLI/apkrun/Support/ExitCodes.swift` matches the `cliExit` values.

---

## 5. Build metadata: components.json

The `APKRun` target runs `scripts/build/write-components.py` as a build phase (planned, #58). It writes `Contents/Resources/components.json` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1):

| Field | Taken from |
|---|---|
| `version`, `build` | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |
| `channel` | build setting `APKRUN_CHANNEL`: `stable` in `release.yml` builds, `dev` otherwise. No `beta` build exists: a candidate is published on the beta channel and promoted unchanged ([workflow.md](workflow.md) §9.5) |
| `commit` | `git rev-parse --short=7 HEAD`, plus `-dirty` when the tree has changes |
| `runtimeAPI`, `guestProtocol`, `dataSchemas` | the version constants of RuntimeAPI, GuestProtocol, and the schema owners |
| `agentPlistSHA256` | SHA-256 of the embedded LaunchAgent plist (§11) |
| `components` | `version` of shipped lock entries; the Sparkle version; `devGuestAgentVersionCode` (§7.1) |

A T0 test compares `components.json` of a built bundle with the compiled constants. `BuildInfo` in DiagnosticsCore reads the file at run time.

---

## 6. Third-party builds

Every third-party input is pinned by commit or hash, never by a moving branch (NFR-DEV-01). Pins, licenses, build flags, and patches are in `ThirdParty/ThirdParty.lock.json`.

### 6.1 Lock file

The lock has `"schemaVersion": 1` and a `components` array (76 entries). The `virglrenderer` entry, with real values:

```json
{
  "name": "virglrenderer",
  "group": "virgl-runtime",
  "kind": "source",
  "repository": "https://gitlab.freedesktop.org/virgl/virglrenderer.git",
  "commit": "960bd6674a25a438da2aac8a0af8c6d6e2b3a77e",
  "version": "1.2.0+apkrun.1",
  "license": "MIT",
  "licenseFiles": ["COPYING"],
  "buildFlags": ["-Dplatforms=egl", "-Ddrm-renderers=[]", "-Dvenus=false", "-Dtests=false", "-Dvideo=false", "-Dtracing=none"],
  "patches": ["virglrenderer/0001-add-macos-metal-support.patch", "virglrenderer/0002-downgrade-unsupported-msaa.patch", "virglrenderer/0003-link-metal-runtime.patch"],
  "ships": "app",
  "upstream": { "watch": "commits", "branch": "main" }
}
```

| Field | Meaning |
|---|---|
| `name` | unique; also the directory under `ThirdParty/patches/` |
| `group` | build unit: `virgl-runtime`, `guest-mesa`, `test-linux`, `image-tooling`, `swift-runtime`, `fixture-tooling`; `graphics-reference` is reference only and not a build unit |
| `kind` | `source` (VCS commit), `prebuilt` (downloaded archive), `vendored` (files copied into the tree), `swiftpm`, `gradle`, `cargo` (pinned by their own lock files; listed for licenses) |
| `repository`, `commit` | upstream URL and full commit hash, for `source` and `vendored` entries |
| `url`, `sha256` | download URL and hash of `prebuilt`. A mismatch fails the build |
| `files` | `vendored`: each repository-relative `path` with `sha256` (§6.4) |
| `binaries` | `prebuilt` archives: the executables the entry relies on, each with `path` and `sha256` |
| `bottle`, `relocation` | Homebrew-bottle `prebuilt`: the bottle name and `from` → `to` path rewrites |
| `buildFlags` | flags the build script passes, for `source`. Empty for `ships: reference` |
| `patches` | local patches in order, relative to `ThirdParty/patches/` (§6.2). Empty for `ships: reference` |
| `version` | `components.json` label; for patched code, upstream version plus `+apkrun.<n>` |
| `license`, `licenseFiles` | SPDX identifier and upstream license file paths; copies in `ThirdParty/licenses/<name>/<path>` ([legal-and-licensing.md](legal-and-licensing.md) §6.1) |
| `ships` | `app`, `image`, `tooling`, `derived`, or `reference`; a list when shipped in several places ([legal-and-licensing.md](legal-and-licensing.md) §4.1) |
| `gnTargetPrefixes` | ANGLE dependencies: `//third_party/` GN prefixes that need a license notice (§6.3) |
| `upstream` | what the upstream security check watches (§6.7) |

The **lock hash** of a build group is the SHA-256 over its buildable entries (canonical JSON), patch files, and build scripts. Groups with only `ships: reference` entries are excluded. The cache key combines the lock hash with an environment hash over the Xcode and build, macOS build, SDK, Metal tools, compiler and Python identities, the pinned PyYAML commit and version, Git, Meson, Ninja, and pkg-config. `scripts/build-third-party.sh --print-cache-key <group>` prints it.

### 6.2 Patches

- Patches live in `ThirdParty/patches/<name>/NNNN-short-description.patch`, made with `git format-patch` against the pinned commit and applied in order with `git am`.
- Each header says why the patch exists and whether it went upstream. RiftVM-carried patches keep the original author ([legal-and-licensing.md](legal-and-licensing.md) §3.2).
- A patch that no longer applies fails the build. It is never skipped.
- `scripts/check-lock.sh --apply` serializes with an advisory lock under `ThirdParty/out/`. It requires exact locked commits on a detached HEAD, no working-tree changes, and no symlinked paths. Reference entries are skipped.
- Git ignores system and global configuration, disables fsmonitor and hooks, and rejects clean/smudge filters and merge drivers. Each series is applied first in a disposable clone, then published atomically to `ThirdParty/out/patched-src/<name>/<commit>/<patch-set SHA-256>/`.
- The command never runs `git am --abort` or `git reset --hard`.

### 6.3 virglrenderer, libepoxy, ANGLE

| Library | Pin | License | Build |
|---|---|---|---|
| virglrenderer | `960bd667` + patches (`1.2.0+apkrun.1`) | MIT | Meson, against libepoxy and ANGLE's EGL |
| libepoxy | `1b6d7db` (`1.5.11+apkrun.1`) | MIT | Meson, EGL only |
| ANGLE | `2d91f554` (`chromium/7151`) | BSD-3-Clause | GN and Ninja with pinned `depot_tools`; Metal only (`angle_enable_metal=true`; GL, Vulkan, SwiftShader off) |
| ANGLE ASTC encoder, Vulkan headers, zlib | `2319d9c4`, `c0fe12c8`, `e00f7038` | Apache-2.0, Apache-2.0, Zlib | dependencies of the Metal GLES targets; `angle-astc-encoder`, `angle-vulkan-headers`, `angle-zlib` |
| PyYAML | `49790e73` (`6.0.3`) | MIT | Meson configuration only; tooling; `pyyaml` |
| depot_tools | `f7083527` | BSD-3-Clause | ANGLE build only; `depot_tools` |

```bash
scripts/build-third-party.sh virgl-runtime
# → ThirdParty/out/virgl-runtime/<lock hash>-<environment hash>/{libvirglrenderer.1.dylib, libepoxy.0.dylib, libEGL.dylib, libGLESv2.dylib}
```

- The driver fetches exact commits to `ThirdParty/out/src/<name>/<commit>/`, runs `scripts/check-lock.sh --apply`, and runs `ThirdParty/build/build-angle.sh`, `build-libepoxy.sh`, `build-virglrenderer.sh` in that order ([graphics.md](../02-design/graphics.md) §5.1). ANGLE's `gclient sync` and compilation run in `ThirdParty/out/work/virgl-runtime/<cache key>/`. Meson gets `PYTHONPATH` set to the pinned PyYAML only.
- Before ANGLE links, `gn desc` dependencies of `//:libEGL` and `//:libGLESv2` are compared with the locked `gnTargetPrefixes`. An uncovered `//third_party/` dependency fails the build.
- `build-manifest.json` records the lock and environment hashes and each library's SHA-256. The driver checks four regular, arm64-only files built for macOS 27.0 or later, with `@rpath` install names and no temporary build paths, and publishes the directory atomically. `apkrund` loads them from `@executable_path/../Frameworks/VirGLRuntime`.
- ANGLE needs about 11 GB of checkout and build space. A cache hit is used only after every hash and Mach-O property passes.
- Acceptance: a fresh checkout produces the libraries with this one command and no manual edits. The weekly `clean-third-party` job checks it with an empty cache (§15.1).

### 6.4 Image tooling inputs: mkbootimg and avbtool

`Images/tools/vendor/` holds unmodified copies of `avb/avbtool.py` (from `platform/external/avb`, tag `android-17.0.0_r1`), `mkbootimg/mkbootimg.py`, `mkbootimg/unpack_bootimg.py`, and `mkbootimg/gki/generate_gki_certificate.py` (from `platform/system/tools/mkbootimg`). `mkbootimg.py` builds the synthetic test boot images (#9; [android-image.md](../02-design/android-image.md) §1.2).

- They are `kind: vendored` entries with a `files` array of paths and SHA-256 hashes. The AVB test key `Tests/Fixtures/signing/aosp-avb-testkey-rsa4096.pem` is one of the listed files.
- `scripts/check-lock.sh` fails when a listed file changes without a lock update. Local changes are not allowed; wrap the tools in `apkrun_image`.

### 6.5 Other pinned inputs

| Input | Lock kind | Ships | Notes |
|---|---|---|---|
| aapt2 (`com.android.tools.build:aapt2:8.9.1-12782657:osx`, Google Maven) | prebuilt (planned, #28) | app (`Resources/tools/aapt2`) | arm64 slice checked with `lipo`; golden output tests; runs under `sandbox-exec` ([package-store.md](../02-design/package-store.md) §4.3) |
| Alpine test guest (group `test-linux`: `linux-virt`, minirootfs, `socat`, `libgpiod`, `ssl_client`, `libcrypto3`, `libssl3`, others) | prebuilt | tooling | the test Linux guest ([vm.md](../02-design/vm.md) §12); never shipped. Alpine v3.23 and v3.24 packages |
| Alpine Mesa virgl stack and `kmscube` (`alpine-mesa*`, `alpine-llvm21-libs`, `alpine-kmscube`; `Tests/Fixtures/linux/virgl-packages.list`) | prebuilt | tooling | the virgl check of the test Linux guest ([test-strategy.md](../04-plan/test-strategy.md) §3.4); never shipped |
| RiftVM `riftvm-v0.6.1` (`github.com/riftvm/riftvm`, `51f19193b1d3326b2e164d37a2a59e9970375170`) | source, group `graphics-reference` | reference | analysis source for #19 only; never built, copied, imported, or distributed ([graphics.md](../02-design/graphics.md) §2.3) |
| apksig test vectors | vendored (planned, #74) | tooling | `Packages/APKStoreCore/Tests/APKStoreCoreTests/Resources/apksig/` ([package-store.md](../02-design/package-store.md) §4.5) |
| swift-protobuf, swift-argument-parser, ZIPFoundation | swiftpm | app | exact versions in `Package.swift` (ZIPFoundation: ADR-0017) |
| Sparkle 2 | swiftpm (planned, #58) | app | exact version in `project.yml` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §3.2) |
| Kotlin stdlib, kotlinx-coroutines, protobuf-javalite | gradle (planned) | image and app (`Resources/guest/`) | versions in `Guest/gradle/libs.versions.toml`; resolved in `Guest/<module>/gradle.lockfile` (`./gradlew -p Guest dependencies --write-locks`) |
| libc, log, android_logger crates | cargo | image | `Guest/vsockd/Cargo.lock`; the product uses AOSP `external/rust/crates` |
| Guest Mesa `mesa` 26.1.8, NDK r28c, Ninja, Bison, Flex, m4, Meson, mako, MarkupSafe, packaging, libdrm 2.4.123 | source or prebuilt, group `guest-mesa` | image (Mesa); tooling (rest) | built by `scripts/guest/build-mesa-android.sh` ([decisions/0018-guest-mesa-ndk-build.md](../01-architecture/decisions/0018-guest-mesa-ndk-build.md)) |
| bundletool 1.18.3 (`bundletool-all`) | prebuilt, group `fixture-tooling` | tooling | App Bundle fixtures (§8.1) |
| libsepol 3.11, erofs-utils 1.9.4, `aosp-avbtool`, `aosp-mkbootimg` | prebuilt and vendored, group `image-tooling` | tooling | image tooling; §6.4 |

The lock is the authority for versions and hashes.

### 6.6 Caches

| Cache | Key | Where |
|---|---|---|
| `virgl-runtime` outputs | lock hash + environment hash | `ThirdParty/out/virgl-runtime/<lock hash>-<environment hash>/` |
| third-party sources | commit | `ThirdParty/out/src/` |
| patched sources | patch-set SHA-256 | `ThirdParty/out/patched-src/` |
| pinned tools | version and hash | `build/tools/` |
| Gradle | wrapper and catalog hash | `~/.gradle` |
| Cuttlefish downloads | build ID and artifact hash | `Images/work/<buildId>/download/` |

Caches are an optimization only. Deleting `ThirdParty/out/` or `build/` never changes a result.

### 6.7 Upstream security check

The planned workflow `third-party-security.yml` runs daily ([graphics.md](../02-design/graphics.md) §11):

1. For each `kind: source` or `prebuilt` entry with an `upstream` block, it lists newer upstream commits and tags.
2. It queries OSV for the pinned commit or version.
3. It flags commits whose message or linked issue mentions a CVE, "security", or an OSS-Fuzz crash.
4. It opens or updates one issue per component, labelled `third-party-security`. It never changes the pin.

The issue is triaged within one week. A fix to the virglrenderer command decoder, the largest attack surface, blocks the next release. A pin update is a normal pull request (lock entry, rebased patches, `components.json` label, notices, T1 renderer smoke tests).

### 6.8 Adding or updating a component

1. A component with runtime impact needs an ADR ([decisions/README.md](../01-architecture/decisions/README.md)) and a place in the graph ([modules.md](../01-architecture/modules.md) §3).
2. Add the lock entry with the full commit, license, license files, and `ships`.
3. Check the license against [legal-and-licensing.md](legal-and-licensing.md) §4. An unknown or copyleft license in an app-shipped component needs an ADR decision before merge.
4. Add the build script under `ThirdParty/build/` if built from source.
5. Regenerate the notices (§11) and run the affected tests.

---

## 7. Guest builds

### 7.1 Kotlin agents (Gradle)

```bash
scripts/build-guest.sh            # ./gradlew -p Guest :guestd:assembleRelease, then copies to Guest/build/out/
ls Guest/build/out/               # apkrun-guest.apk  apkrun-guest.json
```

- `Guest/settings.gradle.kts` includes `protocol`, `agentruntime`, and `guestd`. The Store Agent module `APKRunStore` (output `apkrun-store.apk`) is planned (#37; [guest-components.md](../02-design/guest-components.md) §2).
- `minSdk` 34, `compileSdk` 37, `targetSdk` 37, Java and Kotlin JVM target 17. Dependencies: Kotlin stdlib, kotlinx-coroutines, and protobuf-javalite only. Release builds compile out debug logging through `BuildConfig.DEBUG`.
- `versionCode = major × 1,000,000 + minor × 1,000 + patch` of `MARKETING_VERSION`; `versionName` is that plus the short Git revision. `scripts/build-guest.sh --version-code N --out DIR` builds another versionCode for the reinstall test. `apkrun-guest.json` is the record the host reads before install ([guest-components.md](../02-design/guest-components.md) §3.1).
- Signing: the test key `Tests/Fixtures/signing/test-guest-dev.jks` (alias `apkrun-test-guest-dev`). The script fails unless the signer's certificate SHA-256 is `c58db702f39e9b809ad166d173f165478b4c7cb718d4d0cc89ebe8956438c900`. On the custom image the product re-signs with the platform key (planned, #36).
- `scripts/build/embed-guest.sh` copies both files to `APKRun.app/Contents/Resources/guest/`, the development copy for stock images.

### 7.2 apkrun_vsockd (Rust)

The crate `Guest/vsockd` contains the host-testable port table and bridge implementation:

```bash
cd Guest/vsockd
cargo ndk -t arm64-v8a build --release     # target/aarch64-linux-android/release/apkrun_vsockd
cargo test --locked                        # T0 on the host
cargo test --locked --features vsock-loopback --no-run # compile the T1 harness
cargo clippy --locked --all-targets -- -D warnings -D clippy::undocumented_unsafe_blocks -D clippy::unwrap_used
cargo clippy --locked --target aarch64-linux-android --all-targets -- -D warnings -D clippy::undocumented_unsafe_blocks -D clippy::unwrap_used
cargo fmt --all --check
```

- Development builds use cargo-ndk with the pinned NDK ([environment-setup.md](environment-setup.md) §2.6); they serve the #35 validation, pushing the binary with `adb` to a userdebug image.
- The product compiles the same sources with Soong (§9). The crate uses only `std`, `libc`, `log`, and `android_logger`, all in AOSP `external/rust/crates`.
- The ignored `vsock_loopback` test is T1 and exercises production peer dispatch and bidirectional copying over AF_VSOCK to an abstract agent socket. Run it on Linux with the kernel module loaded: `sudo modprobe vsock_loopback && cargo test --locked --features vsock-loopback -- --ignored vsock_loopback`. The `test-vsockd` job compiles this feature test and runs it when its Ubuntu kernel supports `vsock_loopback`; if unavailable, it emits a notice and a Linux host with the module is required to claim T1 passed. T0 tests and host/Android target lint also run in that job.

---

## 8. Test fixtures

The fixture catalog (apps, variants, keys, repositories, golden files) is [test-strategy.md](../04-plan/test-strategy.md) §4. This section gives build rules and locations. Paths marked *(planned)* do not exist yet.

| Path | Content | Built by |
|---|---|---|
| `Tests/Fixtures/AndroidApps/` | Gradle project of the fixture apps, with its own `gradlew` | `scripts/build-fixtures.sh` → `Tests/Fixtures/AndroidApps/out/` (git-ignored, reproducible) |
| `Tests/Fixtures/apks/` (planned, #28) | committed APKs and derived packages that T0 tests read, so `swift test` needs no Gradle (NFR-DEV-02) | `scripts/build-fixtures.sh --refresh-committed` (planned) |
| `Tests/Fixtures/signing/` | test-only keys: `test-fixture-a.jks`, `test-guest-dev.jks`, `test-image-ed25519` (and `.pub`), `test-release-check-ed25519.pub`, `aosp-avb-testkey-rsa4096.pem`, `test-apkrun-image-fixture-rsa.pem`, `test-apkrun-image-fixture.avbpubkey`. Planned: `test-fixture-b.jks`, `test-fdroid-repo.jks` (#52), `test-sparkle-ed25519` (and `.pub`) (#58) | committed ([security-model.md](../01-architecture/security-model.md) §7) |
| `Tests/Fixtures/update-repos/` (planned, #38, #51) | Local, Direct, F-Droid, GitHub provider fixtures | `scripts/build-fixtures.sh --update-repos` (planned); F-Droid repository built with `fdroid update` and `test-fdroid-repo.jks` in CI |
| `Tests/Fixtures/runtime-updates/` (planned, #58, #88) | appcast for `ReleaseUpdateTest` builds 9000 and 9001; image feeds (valid, tampered, replayed sequence, expired) | `maintenance` job writes the appcast with `generate_appcast`. T1 feeds are signed with `test-image-ed25519`. The T2 feed offering image B is written at run time and signed with the lab Mac's development image key (`image-feed.py --key`; [runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1) |
| `Tests/Fixtures/schemas/<file>/v<n>.json`, `v<n>.expected.json` (planned, #58) | migration golden files ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §5) | committed |
| `Tests/Fixtures/linux/` | initramfs `init`, `make-test-disks.sh`, module and network scripts, Alpine package lists | committed; kernel from `scripts/fetch-test-linux.sh`; initramfs from `scripts/build-test-initramfs.sh` |
| `Tests/Fixtures/fuzz/<target>/` (planned, #92) | seed corpora and crash reproducers (§15.2) | committed |
| `Tests/Fixtures/graphics/`, `Tests/Fixtures/compile-fail/` | VirGL replay fixture (`synthetic-virgl-session.json` until a Linux run records `kmscube`), virtio-gpu vectors, EDID block; compile-fail sources | committed |
| `Packages/GuestProtocol/testdata/frames/` | golden protocol frames | generated and committed (§4.1) |

A committed fixture file is at most 10 MiB. Larger inputs are generated from a seed at test time, or kept in the runner cache with a pinned SHA-256 ([test-strategy.md](../04-plan/test-strategy.md) §4.1).

### 8.1 Fixture apps

Each fixture app is a Gradle module with a CamelCase name and package `io.apkrun.fixture.<lowercase name>` (OddName: `io.apkrun.fixture.odd_name`). Events and users are in [test-strategy.md](../04-plan/test-strategy.md) §4.2. The fixture project may use AndroidX and Compose; the Guest rules of §7.1 do not apply.

| Build rule | Apps |
|---|---|
| one plain APK, signed with `test-fixture-a.jks` | HelloText, HelloCompose, HelloGL, HelloWebView, HelloNotification, HelloClipboard, HelloLinks, HelloFiles, HelloFilesPeer, HelloAudio, OtherInstaller, IconLegacy, OddName, HelloProbe |
| product flavors ([test-strategy.md](../04-plan/test-strategy.md) §4.3) | HelloUpdate: V1, V2, V2-other-signer (`test-fixture-b.jks`), V3-broken, V4. Rotation variants are signed with `apksigner rotate` and `sign --lineage`; the corrupted V2 flips one byte in `classes.dex` |
| App Bundle, split with the pinned bundletool | HelloSplit (base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, a feature split) and derived containers ([package-store.md](../02-design/package-store.md) §4.4, §16) |
| two ABI flavors; v1 signing only with `targetSdk` 29 | HelloNative (`arm64-v8a`, `armeabi-v7a`); HelloLegacySig |

The build is reproducible: the same sources and pinned tools give the same APK bytes. `scripts/build-fixtures.sh --check-reproducible` checks it. `--app <name>` builds one app.

`scripts/build-fixtures.sh` fills `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/` from HelloUpdate V1 and V2 (planned; [update-system.md](../02-design/update-system.md) §4.3). `scripts/dev/update-server.py` (planned, #51) serves the Local fixtures and `direct/` variants as Direct manifests on `127.0.0.1` for Debug builds. `--delay <seconds>` holds every answer. Each other fixture package is served at its own versionCode, so a check reports up to date (#75).

---

## 9. AOSP product build (planned)

The APKRun product (`Guest/product/`, [android-image.md](../02-design/android-image.md) §11) builds on the Linux builder of [environment-setup.md](environment-setup.md) §5.

`scripts/aosp/build-product.sh --revision <commit> --variant userdebug|user` runs in the builder container:

1. Validates that `Guest/product/manifest/pinned.xml` is self-contained and every project resolves to a full commit SHA, then syncs that exact tree if needed.
2. Writes `.repo/local_manifests/apkrun.xml`: this repository at `<commit>`, `Guest/product/` mapped to `device/apkrun/apkrun_arm64/`. The Rust crate has its own `Android.bp` in `Guest/vsockd/`, because Soong does not accept `..` in `srcs`. Kati and Soong must each see every product file exactly once. If a `repo` `<linkfile>` cannot do this, the script copies the directories.
3. Runs `scripts/build-guest.sh --for-aosp`, which builds the Guest Agent with `apkrunPersistentAgent=true` and writes `Guest/product/prebuilt/ApkRunGuest.apk` (git-ignored). The container stages that exact APK before Soong runs; `android_app_import` signs it with `certificate: "platform"`, `privileged: true`, `presigned: false`. The ordinary development APK defaults to `apkrunPersistentAgent=false`.
4. Runs `lunch apkrun_arm64-trunk_staging-<variant>` and `m`, then checks the compiled policy with `scripts/check-sepolicy.sh` before running `m dist`, with `BUILD_NUMBER=ar<counter>`.
5. `user` builds fail closed while OQ-36 leaves the release signing flow open. The builder never accepts or mounts unused release keys.
6. Writes `build-info.json`: pinned manifest SHA-256, container digest, APKRun revision, APK SHA-256s and version codes, build target, and the copied archive's name, size, and SHA-256.

The result, `apkrun_arm64-img-ar<counter>.zip`, enters the stock pipeline (§10). `scripts/check-sepolicy.sh` runs for each built variant after `m` and before `m dist` (R-13).

`scripts/aosp/builder.Dockerfile` pins its Ubuntu amd64 base and an immutable Ubuntu archive snapshot, plus the Android command-line tools archive and `repo` client. Update the snapshot only in a reviewed change, then rebuild the container and run the builder checks. The inspected container digest, pinned manifest SHA-256, Guest Agent identity, and dist archive hash are written to `build-info.json`. `remote-build.sh` verifies the transferred files against that sidecar, removes only the transferred archive and sidecar from the builder, and keeps the full build log at `~/aosp/logs/<BUILD_NUMBER>.log`.

---

## 10. Runtime image bundle and archive

### 10.1 Development bundle

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

- The bundle is deterministic. A T1 job builds the fixture bundle twice and compares `SHA256SUMS` (planned, #66; [android-image.md](../02-design/android-image.md) §10.2).
- `kind` is `stock` for ci.android.com builds (development only) and `apkrun` for the product.
- The image version gets a base suffix: `2026.10.0-cf16373615-arm64` or `2026.10.0-ar000123-arm64`.
- The development key is trusted only by Debug and `ReleaseUpdateTest` builds (§2.4). Release builds trust only the release image keys.

### 10.2 Release archive

The image release job packs a bundle signed with the release image key ([workflow.md](workflow.md) §10):

```bash
aa archive -a lzfse -d Images/work/<buildId>/bundle -o build/release/images/<imageVersion>.aar
shasum -a 256 build/release/images/<imageVersion>.aar
python3 scripts/release/image-feed.py add --channel beta --archive build/release/images/<imageVersion>.aar
```

`scripts/release/image-feed.py` (planned, #88) writes the feed entry and signs `feed.json`. Only `kind: apkrun` bundles built from source are published ([android-image.md](../02-design/android-image.md) §2.3).

---

## 11. App bundle assembly

The layout is fixed by [filesystem-layout.md](../01-architecture/filesystem-layout.md) §4. The `APKRun` target runs these build phases, in order:

| Phase | Puts | From |
|---|---|---|
| Embed CLI (`scripts/build/embed-cli.sh`) | `Contents/Resources/bin/apkrun` with an embedded Info.plist | `swift build -c <debug\|release> --product apkrun` (`--traits EmbeddedRuntime` in Debug); signed with `$EXPANDED_CODE_SIGN_IDENTITY` |
| Generate Third-Party Notices (`scripts/release/generate-notices.py`) | `Contents/Resources/ThirdPartyNotices.html` | lock, `Package.resolved`, Gradle and Cargo locks ([legal-and-licensing.md](legal-and-licensing.md) §6.2) |
| Embed VirGL Runtime (`scripts/build/embed-virgl-runtime.sh`) | `Contents/Frameworks/VirGLRuntime/` (four libraries), signed with `$EXPANDED_CODE_SIGN_IDENTITY` | `ThirdParty/out/virgl-runtime/<lock hash>-<environment hash>/`; fails with the `build-third-party.sh` command when missing |
| Embed Guest Agent (`scripts/build/embed-guest.sh`) | `Contents/Resources/guest/apkrun-guest.apk`, `apkrun-guest.json` | `Guest/build/out/` (§7.1) |
| Embed Helpers | `Contents/Helpers/apkrund`, `Contents/Helpers/APKRunLauncher.app` | the `apkrund` and `APKRunLauncher` targets |
| Write LaunchAgent (`scripts/build/write-launch-agent.sh`) | `Contents/Library/LaunchAgents/$(APKRUN_LAUNCH_AGENT_PLIST_FILE)`: label, Mach service, `BundleProgram` = `Contents/Helpers/apkrund` | `Daemon/apkrund/LaunchAgent.plist.in` |
| Embed Login Items | `Contents/Library/LoginItems/APKRunMenuBar.app` | the `APKRunMenuBar` target |
| Embed Frameworks (planned, #58) | `Contents/Frameworks/Sparkle.framework` | Sparkle |
| `scripts/build/embed-tools.sh` (planned, #28) | `Contents/Resources/tools/aapt2` | pinned Maven artifact, hash-checked |
| Copy resources (planned, #91) | `compatibility.json` | `Tests/Compatibility/database/compatibility.json` ([diagnostics.md](../02-design/diagnostics.md) §10) |
| `scripts/build/write-components.py` (planned, #58) | `Contents/Resources/components.json` | §5 |

Release assembly is `scripts/release/assemble-bundle.sh` (planned, #89): `xcodebuild -configuration Release` with `CODE_SIGNING_ALLOWED=NO`, then `scripts/release/sign-bundle.sh` (§12.3). The runtime image is never inside the app bundle ([decisions/0011-runtime-image-bundle.md](../01-architecture/decisions/0011-runtime-image-bundle.md)).

---

## 12. Signing and notarization

### 12.1 Identities

| Configuration | Identity | Hardened Runtime | Notarized |
|---|---|---|---|
| Debug | "Sign to Run Locally" or the Apple Development certificate; Xcode adds `get-task-allow` | yes | no |
| ReleaseUpdateTest (planned, #58) | Developer ID Application, CI only | yes | no |
| Release | Developer ID Application, secure timestamp | yes | yes (planned, #89) |
| Local wrappers | ad-hoc, per wrapper (§12.5) | yes | no |
| Distribution wrappers | the creator's Developer ID | yes | yes (§12.6) |

All code in one APKRun.app has one team ID. For that reason apkrund needs no `disable-library-validation` for the VirGLRuntime dylibs ([security-model.md](../01-architecture/security-model.md) §3.2). XPC code-signing requirements depend on the same rule ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).

### 12.2 Entitlements

| Binary | File | Entitlements |
|---|---|---|
| APKRun.app | `Apps/APKRun/APKRun.entitlements` | none (App Sandbox off) |
| apkrund | `Daemon/apkrund/apkrund.entitlements` | `com.apple.security.virtualization`; `com.apple.security.device.audio-input` (planned, #85) |
| APKRunLauncher.app, APKRunMenuBar.app | — | none |
| `apkrun` CLI, Release | — | none |
| `apkrun` CLI, Debug | `CLI/apkrun/apkrun-dev.entitlements` | `com.apple.security.virtualization` (embedded mode) |
| APKRunTestHost | `Tests/IntegrationTests/Host/APKRunTestHost.entitlements` | `com.apple.security.virtualization` |

`com.apple.vm.networking` is never used. Adding an entitlement is a security-model change: update [security-model.md](../01-architecture/security-model.md) §3.2 in the same pull request.

### 12.3 Inside-out signing

`scripts/release/sign-bundle.sh <APKRun.app> <identity>` signs nested code first and the outer bundle last, never with `--deep`. #58 creates it for `ReleaseUpdateTest`, and #89 extends it for Developer ID. It confirms the nested paths of the pinned Sparkle (its XPC services exist only in some Sparkle 2 layouts) and fails if any Mach-O file is unsigned.

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

Paths are relative to `APKRun.app`. #58 confirms the Sparkle paths for the pinned version.

### 12.4 Development signing and VM tests

- Xcode signs Debug builds. Embed scripts sign their copies with `$EXPANDED_CODE_SIGN_IDENTITY`, so the bundle has one identity. In development, apkrund checks clients by the cdhashes of the binaries in the same APKRun.app ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).
- Anything that starts a `VZVirtualMachine` needs `com.apple.security.virtualization`, which `swift test` cannot carry. T0 and T1 tests never start a VM. T2 tests run as the `IntegrationTests` bundle inside the signed `APKRunTestHost`:

```bash
xcodebuild test -project APKRun.xcodeproj -scheme IntegrationTests -testPlan IntegrationTests \
  -configuration Debug -only-test-configuration LinuxGuest \
  APKRUN_TEST_LINUX_DIR="${TMPDIR:-/tmp}/apkrun-test-linux" \
  APKRUN_ANDROID_HOME="${TMPDIR:-/tmp}/apkrun-test-sdk" APKRUN_CI=1 \
  DEVELOPMENT_TEAM="$APKRUN_TEST_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APKRUN_TEST_CODE_SIGN_IDENTITY"
```

- Path rules: `APKRUN_TEST_LINUX_DIR`, `APKRUN_ANDROID_HOME`, and `-derivedDataPath` are absolute and outside `~/Documents`, even when `HOME` is overridden. The scripts and the test host reject direct paths and symlink aliases into Documents.
- The hosted test reads `APKRUN_TEST_LINUX_DIR` from `APKRunTestHost.app/Contents/Info.plist`. Pass it as a build setting; a shell export is not forwarded to the hosted process.
- Use `-derivedDataPath "${TMPDIR:-/tmp}/apkrun-dd"` and an `APKRUN_ANDROID_HOME` that holds a copy of `platform-tools`. CI uses `$RUNNER_TEMP`. `scripts/run-gate.sh` builds under `build/gates/` in the checkout.
- For the #36 `AndroidCustom` configuration, stage the signed `apkrun_image bundle` output at `/tmp/apkrun-test-android-custom/android-bundle` and `HelloProbe.apk` at `/tmp/apkrun-test-fixtures/HelloProbe.apk`; the test plan supplies these paths. Replace `ar000123` below with the build number produced by the AOSP builder:

```bash
build_number=ar000123
custom_root=/tmp/apkrun-test-android-custom
fixture_root=/tmp/apkrun-test-fixtures
rm -rf "$custom_root/android-bundle" "$fixture_root/HelloProbe.apk"
mkdir -p "$custom_root" "$fixture_root"
cp -R "Images/work/$build_number/bundle" "$custom_root/android-bundle"
scripts/build-fixtures.sh --app HelloProbe
cp Tests/Fixtures/AndroidApps/out/HelloProbe.apk "$fixture_root/HelloProbe.apk"
```

Run `AndroidCustom` with `APKRUN_CI=1` on the required runner so missing staged inputs fail the job rather than skip the checks.
- `APKRUN_TEST_DEVELOPMENT_TEAM` and `APKRUN_TEST_CODE_SIGN_IDENTITY` (the SHA-1 fingerprint of the certificate) come from the environment or from CI repository variables. The fingerprint is explicit, because the generic `Apple Development` name does not reliably select the lab certificate.
- `APKRunTestHost` and the hosted test bundles disable hardened runtime; that exception is limited to test targets.
- `Tests/IntegrationTests/IntegrationTests.xctestplan` has one configuration per test group: `LinuxGuest`, `AndroidADB`, `AndroidPackage`, `AndroidBoot`, `AndroidNetwork`, `AndroidGraphics`, `AndroidGuestAgent`, `AndroidGuestProtocolLaunch`, `AndroidCustom` (#36 product-image checks), `AndroidInput`, and the four input configurations below. The T2 suites of [test-strategy.md](../04-plan/test-strategy.md) §2.4 are `LinuxGuest`, `AndroidStock`, `AndroidCustom`, and `Maintenance`; `AndroidStock` and `Maintenance` remain planned. T2 has one automatic retry ([test-strategy.md](../04-plan/test-strategy.md) §2.7).

Input tests run in their own configurations. Select the configuration and the method together:

| Configuration | Method (`IntegrationTests/AndroidInputTests/…`) | Use and limits |
|---|---|---|
| `AndroidInputInteractive` | `testThreeConsecutiveHundredClickBatchesThroughWindowServer` | three 100-click batches through WindowServer (#103); posts system pointer events; trace off |
| `AndroidInputTrace` | `testOneHundredClickDiagnosticTraceJoinsHostGuestAndFixture` | diagnostic only; its ACKs and debug listener perturb timing; cannot satisfy #25 or #103 |
| `AndroidInputCadence` | `testThreeConsecutiveHundredClickBatchesThroughDirectView` | three batches at 50 ms press and gap through direct view dispatch; posts no system events; cannot satisfy #25 box 3 or #103 |
| `AndroidInputCadence` | `testOneHundredClickDiagnosticTraceJoinsHostGuestAndFixtureThroughDirectView` | diagnostic only; one untraced warm-up, then a traced batch |
| `AndroidInputEdges` | `testDragsBeyondTopAndLeftEdgesCloseTheGuestTouch` | the #25 top and left guest-edge check; `SessionWindowController.show()` activates the window |

- The interactive and edge tests need a dedicated lab GUI session with exactly one display. They activate the test window; the interactive test moves and clicks the desktop pointer. Run them only on a dedicated desktop (typically the reference Mac), never on a desktop used for other work, in unattended CI, or on a self-hosted GUI runner.
- Run each command separately, with a new `-resultBundlePath` per attempt:

```bash
xcodebuild -project APKRun.xcodeproj -scheme IntegrationTests -testPlan IntegrationTests \
  -configuration Debug -derivedDataPath "${TMPDIR:-/tmp}/apkrun-dd" \
  -resultBundlePath "${TMPDIR:-/tmp}/apkrun-input.xcresult" \
  APKRUN_TEST_LINUX_DIR="${TMPDIR:-/tmp}/apkrun-test-linux" \
  APKRUN_ANDROID_HOME="${TMPDIR:-/tmp}/apkrun-test-sdk" \
  DEVELOPMENT_TEAM="$APKRUN_TEST_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APKRUN_TEST_CODE_SIGN_IDENTITY" \
  -only-test-configuration AndroidInputInteractive \
  -only-testing:IntegrationTests/AndroidInputTests/testThreeConsecutiveHundredClickBatchesThroughWindowServer test
```

- On macOS 27, the hosted `APKRunTestHost` checks `CGPreflightPostEventAccess()`. When it fails, enable the exact `APKRunTestHost.app` path from the skip message under System Settings → Privacy & Security → Device Control and Data Access. A grant to Terminal, Xcode, or another app does not satisfy it. Sign the host with the configured identity so its designated requirement stays stable.
- These tests exercise the embedded `DevBoot` and `DevInputRoute` path, not the wrapper-to-apkrund XPC route.
- `Tests/AcceptanceTests/AcceptanceTests.xctestplan` has one configuration per gate (`G1`–`G9`; each gate task adds its own), plus `ReleaseSmoke` and `Network`. Current configurations: `G1`, `G2`, `G3`, `Network`. Automatic retry is off, except one retry for `Network` ([test-strategy.md](../04-plan/test-strategy.md) §2.7).
- Tests through apkrund use the installed Debug identities (§13). The Maintenance suite builds and installs `ReleaseUpdateTest` bundles instead.

### 12.5 Local wrapper signing

WrapperCore signs each local wrapper at run time, not at build time ([wrapper.md](../02-design/wrapper.md) §7.1):

```bash
/usr/bin/codesign --force --sign - --identifier <bundleID> --options runtime --timestamp=none <staging>/<name>.app
```

- No `--deep`. Signing is the last write to the bundle. The cdhash goes into the wrapper registry.
- The launcher must be re-signable this way: system frameworks only, arm64 only, no nested code. `scripts/check-launcher.sh` enforces it (planned, #69).
- `scripts/dev/make-wrapper.sh <package> <out-dir>` (planned, #46) builds a wrapper by hand with the same command and registers it with `apkrun wrapper approve`.

### 12.6 Notarization (planned)

`scripts/release/notarize.sh <path>` handles the app and the DMG:

```bash
ditto -c -k --keepParent APKRun.app build/release/APKRun-notarize.zip
xcrun notarytool submit build/release/APKRun-notarize.zip --keychain-profile apkrun-notary --wait
xcrun stapler staple APKRun.app
spctl --assess --type execute -vv APKRun.app
```

In CI the script uses the API key form (`--key`, `--key-id`, `--issuer`) from the release secrets. `scripts/release/make-dmg.sh` then builds `APKRun-<version>.dmg` (`hdiutil create -format UDZO`), signs it with the Developer ID, notarizes it, and staples it.

Distribution wrappers use the same tools on the creator's Mac: `apkrun wrap <package> --distribution --identity "Developer ID Application: Name (TEAMID)" [--notarize --keychain-profile <profile>]` ([wrapper.md](../02-design/wrapper.md) §11). The nightly `notarize` job (planned) keeps that path working with a HelloText distribution wrapper.

---

## 13. Debug identities and the development install

Debug builds never replace an installed release ([runtime-daemon.md](../02-design/runtime-daemon.md) §2.6).

| Item | Release | Debug | ReleaseUpdateTest (planned) |
|---|---|---|---|
| App bundle ID | `io.apkrun.APKRun` | `io.apkrun.APKRun.dev` | `io.apkrun.APKRun.updatetest` |
| Other bundle IDs | `io.apkrun.APKRunMenuBar`, `io.apkrun.APKRunLauncher`, `io.apkrun.cli` | same, plus `.dev` | same, plus `.updatetest` |
| LaunchAgent label | `io.apkrun.apkrund` | `io.apkrun.apkrund.dev` | `io.apkrun.apkrund.updatetest` |
| Mach service | `io.apkrun.apkrund.xpc` | `io.apkrun.apkrund.dev.xpc` | `io.apkrun.apkrund.updatetest.xpc` |
| `APKRUN_HOME` default | `~/Library/Application Support/APKRun/` | `~/Library/Application Support/APKRun-Dev/` | `~/Library/Application Support/APKRun-UpdateTest/` |
| Installed as | `/Applications/APKRun.app` | `~/Applications/APKRun Dev.app` | the build output, lab Mac only |
| CLI name | `apkrun` | `apkrun-dev` | — |

```bash
scripts/dev/install-dev-app.sh          # copies build/Build/Products/Debug/APKRun.app, registers the agent, links apkrun-dev
launchctl kickstart -k gui/$(id -u)/io.apkrun.apkrund.dev
launchctl print gui/$(id -u)/io.apkrun.apkrund.dev
```

- Registering straight from DerivedData works, but the path differs between machines. Use the install script.
- The quick-start build leaves the Debug app at `build/Build/Products/Debug/APKRun.app`. Set `APKRUN_BUILD_PRODUCTS_DIR` for another DerivedData directory.
- `install-dev-app.sh` links `~/.local/bin/apkrun-dev` to the CLI in the installed Debug app. Release users run `sudo ln -sf "/Applications/APKRun.app/Contents/Resources/bin/apkrun" /usr/local/bin/apkrun` ([cli.md](../02-design/cli.md)).
- Debug wrappers go to `~/Applications/APKRun Dev/`. Their bundle IDs are set by #46 ([wrapper.md](../02-design/wrapper.md) §4).

---

## 14. Reproducibility

| Artifact | Guarantee | Check |
|---|---|---|
| Generated code and error catalog tables | byte-identical from the pinned tools | `codegen` job (§4) |
| Runtime image bundle | byte-identical for the same inputs and tool revision | T1 double build (planned, §10.1) |
| Local wrappers | byte-identical for the same configuration, launcher, and icon ([wrapper.md](../02-design/wrapper.md) §6.5) | T1 in WrapperCore (planned) |
| `virgl-runtime` libraries | same inputs, same composite cache key; output bytes need not match | weekly empty-cache build (§6.3) |
| Guest APKs | same revision, same `versionCode` and content; signatures differ by key | T1 content check (planned) |
| APKRun.app | traceable, not bit-for-bit (secure timestamps, notarization ticket) | `components.json` commit, lock hashes, release notes |
| Custom AOSP image | traceable: pinned manifest, container digest, Guest revision | `provenance` in the bundle manifest |

- Every input is pinned (§6; [environment-setup.md](environment-setup.md) §2.9). No build downloads "latest".
- The release workflow builds from a clean checkout of a tag with an empty DerivedData, and refuses a dirty tree.
- Builds do not embed wall-clock timestamps where a tool allows it (`ZERO_AR_DATE=1`, fixed GUIDs and sorted keys in image tooling).

---

## 15. CI jobs by tier

The tiers, budgets, suites, and retry rules are in [test-strategy.md](../04-plan/test-strategy.md) §2: T0 has no VM, GPU, network, or other processes; T1 has real macOS services, Metal, files, XPC, or local servers, but no VM; T2 has a real VM on a real Apple silicon Mac; T3 is acceptance, gates, and long or external runs.

Pull request workflows run the pull request's source on fresh GitHub-hosted VMs. The `workflow-policy` job of `ci-policy.yml` runs trusted `main` code and never runs pull request source. A persistent self-hosted runner runs only trusted default-branch or manual jobs, with runner-group access pinned to a trusted workflow ([environment-setup.md](environment-setup.md) §6.2). Tests that need self-hosted resources need a runner-isolation design before they join a pull request gate. Every job of `ci.yml` and `workflow-policy` is required by branch protection for pull requests to `main` ([workflow.md](workflow.md) §7.3).

### 15.1 Workflows and jobs

Jobs marked *(planned)* do not exist yet.

| Workflow | Trigger | Job | Tier | Runner | Content |
|---|---|---|---|---|---|
| `ci-policy.yml` | `pull_request_target` to `main`: opened, reopened, synchronize, edited, labeled, unlabeled | `workflow-policy` | — | `ubuntu-latest` | `scripts/ci/check-pr-control-changes.py` from `main`: head, base, changed paths, and reviews through the read-only API. Control paths: workflows, build and convention scripts, generators, pins, formatter and tool settings, test and build manifests, test trees, module graph. The approver applies `ci-policy-approved`; a new commit, reopen, PR edit, or later label event resets the check; removing the label revokes it |
| `ci.yml` | every pull request; push to `main` | `lint` | — | `xcode-27` | `scripts/bootstrap`; `scripts/ci/run-checks.sh` (`tests/run.sh`, `check-module-deps.sh`, `check-logging.sh`, `check-todos.sh`, `check-format.sh`, `check-lock.sh`, `check-protos.sh`) |
| | | `codegen` | — | `xcode-27` | `scripts/ci/codegen.sh` (§4) |
| | | `third-party` | — | `xcode-27` | cache key from `build-third-party.sh --print-cache-key virgl-runtime`; restore; `build-third-party.sh virgl-runtime`; `generate-notices.py --check` |
| | | `build` | — | `xcode-27` | needs `third-party`; `swift build -j 2`; `swift build -j 2 --traits EmbeddedRuntime`; `xcodebuild` Debug and Release (unsigned); `check-release-build.sh` |
| | | `test-swift` | T0 | `xcode-27` | needs `third-party`; `swift test --skip 'SystemTests'`, parallel width 2 |
| | | `test-vsockd` | T0, T1 when supported | `ubuntu-latest` | pinned Rust 1.88.0; `cargo test`, feature-test compile and clippy, conditional `vsock_loopback`, Android-target `cargo clippy`, and `cargo fmt --check` |
| | | `test-graphics` | T1 | `xcode-27` | needs `third-party`; Metal device required; `GraphicsCoreSystemTests` plain, with Address and Undefined Behavior Sanitizers |
| | | `test-images` | T0 (T1 planned) | `xcode-27` | `Images/tools/.venv` (Python 3.12); manifest check; `pytest Images/tools/tests`; `ruff check`; `ruff format --check` |
| | | `test-guest` (planned) | T0, T1 | `xcode-27` (T0); disposable T1 runner for PRs; `apkrun-ci` on `main` | `build-guest.sh`; Gradle `test` per Guest module; golden frames; `build-fixtures.sh` |
| | | `test-linux` (planned) | T1 | `ubuntu-latest` | `vsock_loopback` (§7.2), `ruff check`, JSON Schema checks, F-Droid test repository (`fdroid update`) |
| | | `fuzz-short` (planned) | T1 | disposable runner for PRs; `apkrun-ci` on `main` | 60 s per fuzz target whose code changed (§15.2) |
| `integration.yml` | manual dispatch from `main` only | `linux-guest` | T2 | `apkrun-lab` (self-hosted macOS); trusted `main` only | `build-test-initramfs.sh`; `generate-project.sh`; `xcodebuild test`, `LinuxGuest`; ≤ 15 min; artifacts 30 days |
| | label `t2-android` or `run-t2` (planned) | `android-stock` | T2 | disposable `apkrun-lab` for PRs; `apkrun-lab` on `main` | suite AndroidStock, ≤ 60 min |
| | label `t2-android` or `run-t2` (planned) | `android-custom` | T2 | as `android-stock` | suite AndroidCustom, ≤ 90 min, with the latest custom `userdebug` image from `nightly.yml` `aosp-build` |
| | label `t2-maintenance` or `run-t2` (planned) | `maintenance` | T2 | lab Mac run of the reviewed commit for PRs; `apkrun-lab` on `main`, environment `signing` | suite Maintenance, ≤ 120 min: `ReleaseUpdateTest` 9000 and 9001, local appcast, N → N+1 and variants |
| `nightly.yml` | daily at 01:00 UTC and manual dispatch before a release; manual dispatch only at present | `aosp-build` (planned) | — | `apkrun-aosp` | `build-product.sh --variant userdebug` (§9) when `Guest/` changed. `user` builds never run on CI ([environment-setup.md](environment-setup.md) §5.6) |
| | | `gates` | T3 | `apkrun-reference` | `scripts/run-gate.sh G<n>` for each closed gate (today `G1`); uploads evidence |
| | | `network` | T3 | `apkrun-lab` | generates the project, builds the test Linux guest, runs `AcceptanceTests` `Network` with one retry. The same DNS failure, or the exact BusyBox `wget` socket-connect or download-timeout failure with no HTTP response and no TLS or client diagnostic on both attempts, is classified `external`. Output over 4 KiB fails closed |
| | | `t2-all` (planned) | T2 | `apkrun-lab` | all four T2 suites; quarantined tests report but do not fail the job |
| | | `perf` (planned) | T3 | `apkrun-lab`, `apkrun-reference` | `swift run apkrun-perf` against `Tests/PerformanceTests/baselines/<model>.json` |
| | | `compatibility` (planned) | T3 | `apkrun-lab` | F-Droid corpus of `Tests/Compatibility/apps.json`; `scripts/dev/verify-corpus.sh` (planned, #74) |
| | | `soak` (planned) | T3 | `apkrun-lab` | 60-minute soak ([test-strategy.md](../04-plan/test-strategy.md) §7.3) |
| | | `fuzz-long` (planned) | T3 | `apkrun-ci` | 1 h per fuzz target (§15.2) |
| | | `notarize` (planned) | T3 | `apkrun-lab`, environment `signing` | §12.6 for the Release app and a HelloText distribution wrapper |
| `clean-third-party.yml` | weekly, Sunday 04:23 UTC; manual | `clean-third-party` | — | `xcode-27` | removes `ThirdParty/out`, builds `virgl-runtime` without a cache |
| `macos-seed.yml` (planned) | manual, after the seed Mac installs a macOS build | `seed` | T2, T3 | `apkrun-seed` | full T2 set and every closed gate check ([test-strategy.md](../04-plan/test-strategy.md) §9.4) |
| `release.yml` (planned, #58, #95) | tag `v*`; manual on `main` with `dry-run` or `promote` | `release` | — | `apkrun-lab`, environment `release` | [workflow.md](workflow.md) §9 |
| `image-release.yml` (planned, #88) | manual, input `action`: `candidate`, `beta`, `stable`, `rollout`, `remove` | `image-release` | — | `apkrun-lab`, environment `release` | [workflow.md](workflow.md) §10 |
| `image-feed-resign.yml` (planned, #88) | weekly, Monday 03:00 UTC | `resign` | — | `ubuntu-latest`, environment `release` | re-signs both channels' feeds ([workflow.md](workflow.md) §10) |
| `third-party-security.yml` (planned) | daily | `upstream` | — | `ubuntu-latest` | §6.7 |

The `linux-guest` job's push trigger to `main` uses this path filter. Pull request runs use the same filter, and only on disposable lab runners ([test-strategy.md](../04-plan/test-strategy.md) §2.4):

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

- The label `run-t2` runs every T2 suite; `t2-android` and `t2-maintenance` run only their suites.
- Every T2 and T3 job uploads the artifacts of [test-strategy.md](../04-plan/test-strategy.md) §3.7: 14 days for pull requests, 30 days for nightly runs. Gate evidence and release candidate artifacts are kept permanently.
- A lab Mac has one runner slot and runs one job at a time, because it runs one VM at a time.

### 15.2 Fuzzing (planned)

| Item | Choice |
|---|---|
| Swift and C engine | libFuzzer, through a swift.org toolchain pinned as `SWIFT_FUZZ_TOOLCHAIN` in `scripts/tool-versions.env`. Xcode's toolchain does not ship the libFuzzer runtime |
| Flags | `swift build -c debug --product <Module>Fuzz --sanitize=fuzzer --sanitize=address --sanitize=undefined`, with `APKRUN_FUZZ=1` |
| Kotlin engine | Jazzer (`jazzer-junit`, test-only) with `@FuzzTest` in `Guest/protocol` and `Guest/guestd` |
| Targets | [test-strategy.md](../04-plan/test-strategy.md) §7.2. The malicious-agent target runs at T2 and is not a libFuzzer target |
| libFuzzer options | `-max_total_time=60` in pull requests, `3600` nightly; `-timeout=10`; `-rss_limit_mb=2048`; `-artifact_prefix=build/fuzz/<target>/` |
| Corpus | seeds in `Tests/Fixtures/fuzz/<target>/`; the nightly working corpus is in the runner cache, merged with `-merge=1` |
| Driver | `scripts/run-fuzz.sh <target> \| --changed \| --all [--seconds <n>]`; `--changed` maps changed paths to targets |
| Crash | the job fails and uploads the reproducer; a `fuzz-long` crash also opens an issue labelled `fuzz-crash`. The fix adds the reproducer to `Tests/Fixtures/fuzz/<target>/` |
| Regression | the entry function lives in `<Module>TestSupport`; a T1 test in `<Module>SystemTests` replays every reproducer without libFuzzer |

With `APKRUN_FUZZ=1`, `Package.swift` adds the `<Module>Fuzz` executable targets. Without it, the manifest has none, so `swift build` with Xcode's toolchain keeps working.

### 15.3 Rules

- A pull request merges only when every required `ci.yml` job passes ([workflow.md](workflow.md) §7.1).
- The pull request that closes a task links a T2 result for every T2 suite the task lists: the `integration.yml` run on disposable capacity, or a lab Mac run of the reviewed commit ([test-strategy.md](../04-plan/test-strategy.md) §2.4).
- T0 and T1 have no automatic retry. T2 has one retry per test; the report marks each "passed on retry". Gate checks and the release smoke matrix are never retried.
- A T1 test whose runner lacks a needed resource (Metal device, GUI session, APFS scratch volume, permission) fails with `runnerMissing<Resource>`. It never skips.
- A T2 failure on `main` blocks every merge until it is fixed or reverted ([test-strategy.md](../04-plan/test-strategy.md) §2.7).
- A nightly failure opens an issue labelled `nightly-failure`. It is fixed or reverted within one working day; no other pull request merges into the affected area until then ([workflow.md](workflow.md) §7.4).
- A failure on `apkrun-seed` opens an issue labelled `macos-regression` and updates R-16 in [risks.md](../04-plan/risks.md).
- Gates count only when they pass on the reference Mac with a clean build from `main` ([roadmap.md](../04-plan/roadmap.md) §2).
