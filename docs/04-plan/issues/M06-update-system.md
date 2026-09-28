# M6 Update system

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.3 |
| Related | [update-system.md](../../02-design/update-system.md), [package-store.md](../../02-design/package-store.md), [guest-protocol.md](../../02-design/guest-protocol.md), [guest-components.md](../../02-design/guest-components.md), [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md), [runtime-api.md](../../03-reference/runtime-api.md), [cli.md](../../02-design/cli.md), [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md), ADR-0010 [0010-update-authority-provider-split.md](../../01-architecture/decisions/0010-update-authority-provider-split.md), [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../open-questions.md](../open-questions.md), [../test-strategy.md](../test-strategy.md), [../traceability.md](../traceability.md) |

Each task below uses the entry format of [README.md](README.md) §2. Titles, dependencies, the milestone, and the gates follow the index in [README.md](README.md) §3.

## Milestone goal

APKRun keeps installed Android apps up to date by itself. A provider finds a newer version. apkrund downloads and validates it on the host, without starting Android, and stages it. The update waits until the app is not in use, then installs through one `PackageInstaller` session with the app's data kept. A health check follows, and a broken update goes back to the previous APK set (M6, gate G7). The host also reads `.apks`, `.xapk`, and `.apkm` files, verifies APK signatures itself, and shows a full preview while Android is stopped (#073).

v0.3 is M5 plus M6: the store and automatic updates ([../roadmap.md](../roadmap.md) §3.3). From here on the custom image of #035 is the image the product is tested on. The stock image stays a development target, and tests marked "both image kinds" run on both.

These rules apply to every task below:

- DirectProvider (#050) is scheduled in M6 to meet the v0.3 Definition of Done. It depends on #037 and #041.
- The update authority and the update provider are separate (ADR-0010 [0010-update-authority-provider-split.md](../../01-architecture/decisions/0010-update-authority-provider-split.md), [update-system.md](../../02-design/update-system.md) §2.1). The authority says who may update a package: `apkrun`, `manual`, `googlePlay`, or `external`. The provider says where APKRun finds candidates: `local` or `direct` in M6. APKRun requests Android update ownership for `apkrun` and `manual` packages and never for `googlePlay` or `external` ([package-store.md](../../02-design/package-store.md) §6.3).
- Every update is validated on the host before Android sees it: the intrinsic checks I1–I12 ([package-store.md](../../02-design/package-store.md) §4.6) and rules V0–V6 ([update-system.md](../../02-design/update-system.md) §6). Provider metadata can only refuse. The values inside the APK decide (FR-UPD-14). Downgrades are always refused. No flag, setting, test hook, or debug build turns off a rule (NFR-SEC-04, [../../../AGENTS.md](../../../AGENTS.md) §4 invariant 10, [../test-strategy.md](../test-strategy.md) §3.3). Android still verifies every install itself.
- Updates never block launch (NFR-PERF-07, [../../../AGENTS.md](../../../AGENTS.md) §4 invariant 9). Checks, downloads, validation, and staging run on the host only. They never boot, resume, or wake Android ([update-system.md](../../02-design/update-system.md) §3.1).
- Rollback is binary only ([../../../AGENTS.md](../../../AGENTS.md) §4 invariant 11). #043 says "reinstall previous artifacts". The design uses Android's `RollbackManager` on custom images, a downgrade reinstall (`adb install-multiple -r -d`) on debuggable stock images, and an uninstall plus reinstall only after the user confirms that the app's data is erased ([package-store.md](../../02-design/package-store.md) §7.3, [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §6). App data is never reverted, and every rollback message says so.
- The CLI uses `--provider <spec>` and `--updates`, and accepts the documented alternate flag spellings (`--update auto|notify|manual`, `--update-provider direct --update-url <url>`) ([update-system.md](../../02-design/update-system.md) §11.3).
- Identifiers use `io.apkrun.*`: the Store Agent is `io.apkrun.store`, and the fixtures are `io.apkrun.fixture.*` ([modules.md](../../01-architecture/modules.md) §5).
- The fixtures are named HelloUpdate V1 and HelloUpdate V2. "Rule V4" is a validation rule, and "HelloUpdate V4" is a fixture. GU1–GU7 are the gentle-update conditions, and G1–G9 are always gates ([../test-strategy.md](../test-strategy.md) §4.3, §4.9).

## Exit criteria

- [ ] All 10 tasks meet their acceptance criteria, or a task is moved to a later milestone with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4 item 1).
- [ ] **G7 passes** ([../roadmap.md](../roadmap.md) §2): on the custom image, with HelloUpdate V1 installed and the LocalProvider serving HelloUpdate V2, APKRun finds and stages V2 in the background. No install happens for 10 minutes while V1's window is open, nor while V1 runs with `keepRunning`. Within 30 s after V1 quits, V2 is installed without user action. The next launch shows V2, which logs `data HELLO`. `Updates/history.jsonl` records each step. `scripts/run-gate.sh G7` (`Tests/AcceptanceTests/G7GentleUpdate`) passes on the reference Mac with a clean build from `main` ([../test-strategy.md](../test-strategy.md) §5).
- [ ] The v0.3 Definition of Done holds ([../roadmap.md](../roadmap.md) §3.3): APK Store (#027, #036, #073), LocalProvider (#037), DirectProvider (#050), automatic updates (#038, #074), update ownership (#039), gentle updates (#040, G7), signature verification (#041), split APK support (#042), and rollback (#043). The APKRun AOSP product (#035) is the image these are tested on.
- [ ] Every `Must` requirement for 0.3 in FR-PKG and FR-UPD is covered by passing tests ([../traceability.md](../traceability.md) §2): FR-PKG-02, FR-PKG-04, FR-PKG-05, FR-UPD-01 to FR-UPD-08, FR-UPD-10 to FR-UPD-12, FR-UPD-14, and FR-UPD-15. The `Should` requirements FR-PKG-03 and FR-PKG-06 are done, or listed in the release notes.
- [ ] Tests ([../roadmap.md](../roadmap.md) §4 item 3): T0 and T1 pass on `main`, including the `fuzz-short` runs of the two fuzz targets of #073. T2 passes on the reference Mac in the `AndroidStock` and `AndroidCustom` suites. The G7 check and the 50-APK F-Droid corpus of #073 are in the nightly T3 run. The v0.3 manual checklist ([../test-strategy.md](../test-strategy.md) §8.4, C03-1 and C03-2) is done and recorded in the release issue.
- [ ] Performance ([../roadmap.md](../roadmap.md) §4 item 4): the perf harness numbers are recorded for M6. `update-check-launch` (a provider that answers after 5 s, 10 packages) shows a launch p50 difference of at most 50 ms (NFR-PERF-07, [../test-strategy.md](../test-strategy.md) §7.1). `apkrun inspect` takes under 1 s per 50 MiB APK on the reference Mac. Any regression against M5 is explained ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §9.4).
- [ ] Risks ([../roadmap.md](../roadmap.md) §4 item 5, [../risks.md](../risks.md)):
  - R-15 has the #041 and #073 results recorded: which install floors the host checks catch, with the fixture that shows each one. It stays `watching` until the #090 corpus measures the real share.
  - R-18 has the #039 and #043 results recorded: update ownership on the custom image, and `RollbackManager` with `TEST_MANAGE_ROLLBACKS` on `user` and `userdebug` builds. Its status is updated. The #058 part stays open.
- [ ] Questions ([../roadmap.md](../roadmap.md) §4 item 6, [../open-questions.md](../open-questions.md)): the open items of [update-system.md](../../02-design/update-system.md) §17 and [package-store.md](../../02-design/package-store.md) §17 that name an M6 task have their results recorded: `GENTLE_UPDATE` and foreground services (#040), ownership of an owner-less package (#039), `TEST_MANAGE_ROLLBACKS` on `user` builds (#043), and the density split choice (#042). The bundle-ID namespace question ([../open-questions.md](../open-questions.md)) is settled, or explicitly carried over, because #045 in M7 needs it before it starts. Decisions with a deadline in M7 are settled or carried over.
- [ ] Documents ([../roadmap.md](../roadmap.md) §4 item 7): [update-system.md](../../02-design/update-system.md), [package-store.md](../../02-design/package-store.md), [guest-protocol.md](../../02-design/guest-protocol.md), [guest-components.md](../../02-design/guest-components.md), [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md), and [cli.md](../../02-design/cli.md) describe what was built. The verification results of #039 ([package-store.md](../../02-design/package-store.md) §6.3), #040 ([update-system.md](../../02-design/update-system.md) §7.1), #042 ([package-store.md](../../02-design/package-store.md) §4.4), and #043 ([package-store.md](../../02-design/package-store.md) §7.3) are in the design documents. The [../roadmap.md](../roadmap.md) §3.3 items are marked delivered.
- [ ] Version ([../roadmap.md](../roadmap.md) §4 item 8): the v0.3 Definition of Done is checked and v0.3 is tagged.

## Task order

1. #073 Host inspection and import formats. It needs #036 (M5). **Parallel with #037.** Its `apkrun adopt` step needs `UpdateAuthority.external` from #037 step 1 and merges after it. #038, #041, and #042 depend on it, because they use its verifier and split selector.
2. #037 LocalUpdateProvider. It needs #036 (M5). **Parallel with #073.**
3. #038 PackageInstaller updates. After #037 and #073.
4. #039 Update ownership. After #038. **Parallel with #041.**
5. #040 Gentle updates (gate G7). After #039. **Parallel with #041, #042, and #050.**
6. #041 Package and signature verification. After #038 and #073. **Parallel with #039 and #040.**
7. #042 Split APK installation. After #041 and #073. **Parallel with #040 and #050.**
8. #043 Update rollback. After #041 and #042. **Parallel with #050 and #074.**
9. #050 DirectProvider. After #037 and #041. **Parallel with #040, #042, and #043.**
10. #074 Update scheduler. After #037, #040, and #050. **Parallel with #043.** Its slow-provider test and `update-check-launch` use `DirectProvider` and `scripts/dev/update-server.py` from #050.

The critical path is #036 → #037 → #038 → #039 → #040 (G7), with the second branch #038 → #041 → #042 → #043, which feeds #049 (G9) in M7 ([../roadmap.md](../roadmap.md) §1.3). M7 also waits on this milestone at more points: #048 needs #037, #078 needs #073, and #079 needs #039 and #074. The post-v1 task #097 needs #039.

Shared files:

- `Packages/UpdateCore/`: #037 creates the target, `ProviderRegistry`, `UpdateCoordinator`, and `UpdateStateStore`. Later tasks add one component each next to them: #038 (the phases from `downloading` to `installing`), #040 (`GentleUpdateGate`), #041 (`UpdateValidator`), #043 (`UpdateHealthChecker`), #050 (`DirectProvider`), and #074 (`UpdateScheduler`). `UpdateCoordinator` is the shared file. Each task changes only the phases it owns.
- `Packages/APKStoreCore/`: #073 owns `Sources/APKStoreCore/Import/` and `Sources/APKStoreCore/Signing/`. #037, #038, and #043 add transaction kinds to `PackageStore` and the journal. #039 and #043 add `InstallRequest` fields.
- `Packages/GuestProtocol/proto/apkrun/guest/v1/store.proto` and `Guest/APKRunStore/`: #039 (op 109), #040 (op 110), and #043 (op 108 and `enable_rollback`) each add one capability. Each regenerates the Swift code with `scripts/generate-protos.sh`. The changes are additions, so `buf breaking` passes.
- `Packages/RuntimeHost/`: #038 creates a first `UpdateRuntimeAccess` implementation (`runtimeState`, `hasActiveUse`, `ensureReady`) and adds `StoreRuntimeAccess.hasOpenSession`. #040 completes `UpdateRuntimeAccess`, and #043 adds `healthCheckLaunch`.
- `CLI/apkrun/Commands/Update.swift`: #037 creates `apkrun update`. #038, #039, #040, #043, and #074 add subcommands and flags, each with its golden output in `CLI/apkrun/Tests/Golden/`.
- `Packages/DiagnosticsCore/ErrorCatalog/errors.json`: each task adds its `store` and `update` codes and regenerates the catalog with `swift scripts/errorgen.swift --markdown`.
- `scripts/dev/update-server.py`: #050 creates it. `update-check-launch` and #074 use its response delay.

---

## #073 Host inspection and import formats

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #036 |
| Requirements | FR-PKG-02, FR-PKG-03, FR-PKG-06 |
| Design | [package-store.md](../../02-design/package-store.md) §1, §4.1–§4.7, §9.3, §10.1, §11.1, §11.4, §12, §13, §15 #073, §16, §17; [cli.md](../../02-design/cli.md) §4.2 (`install`, `inspect`, `adopt`); [runtime-api.md](../../03-reference/runtime-api.md) §8.1, §8.2, §8.5; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §5; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §4; [error-catalog.md](../../03-reference/error-catalog.md) §10; ADR-0017 [0017-zipfoundation-zip-reading.md](../../01-architecture/decisions/0017-zipfoundation-zip-reading.md) |
| Modules / paths | `Packages/APKStoreCore/Sources/APKStoreCore/Import/` (`ContainerReader`, `SplitSelector`, `APKInspector`, `ArtifactVerifier`, `ImportPreview`, `HostIconPreview`), `Packages/APKStoreCore/Sources/APKStoreCore/Signing/` (`APKSignatureVerifier`), `Packages/APKStoreCore/Tests/APKStoreCoreTests/Resources/apksig/`, `Packages/APKStoreCore/Tests/APKStoreCoreFuzz/`, `Packages/RuntimeHost/` (`inspectFile`, `adoptPackage`), `CLI/apkrun/Commands/` (`inspect`, `adopt`), `scripts/dev/verify-corpus.sh`, `Tests/Fixtures/AndroidApps/`, `Tests/Fixtures/apks/`, `Tests/Fixtures/fuzz/` |
| Risks / questions | R-15 (install floors: the host checks catch them before install). Open items in §17: OBB expansion files (v1.x), host verifier false rejections. None open for this task in [../open-questions.md](../open-questions.md) |

### Goal

`apkrun inspect` and the import preview show a package's name, icon, version, signer, permissions, warnings, and the files that will be installed, while Android is stopped. `.apk` files, `.apks`, `.xapk`, `.apkm`, and ZIPs of APKs import as one split set, unsafe or unsupported containers are refused with a clear reason, and APK signatures are verified on the host with the same signer digests as `apksigner`.

### Scope

- Container detection by content and extraction with the limits of §4.2: `.apk`, `.apks`, `.xapk` without OBB, `.apkm`, and `.zip` of APKs. Refusals: `.aab` (`unsupportedContainer(.appBundle)`), encrypted or non-ZIP `.apkm` (`unsupportedContainer(.encryptedAPKM)`), `.xapk` with OBB (`expansionFilesNotSupported`), and anything else (`unsupportedContainer(.unknown)`).
- `APKInspector` extended from the #027 v0 to the full fact list of §4.3 (`aapt2 dump badging` and `aapt2 dump xmltree`, native libraries from the central directory), with the aapt2 sandbox profile, timeouts, output cap, and golden tests.
- `SplitSelector` (§4.4).
- `APKSignatureVerifier` (§4.5): v2, v3, v3.1, the classic part of v3.2, the lineage with its capability flags, the signer set, and the special cases. The signature check is no longer `notPerformed`.
- `ArtifactVerifier` with the intrinsic checks I1–I12 and the warnings (§4.6). `GuestFacts` from `Runtime/instance/instance.json`, or from the image manifest before the first boot.
- `ImportPreview` (§4.7) with the host label and the host icon preview (§10.1). Host-parsed values are a preview. After install, Android's values replace them (FR-PKG-02, §1).
- `inspectFile` and `apkrun inspect <file>… [--json]` (§11.1, §11.4). It needs apkrund and never starts Android.
- `adoptPackage` and `apkrun adopt <package>` for an unmanaged package (§9.3, [cli.md](../../02-design/cli.md) §4.2).
- Fuzz targets for the container reader and the APK Signing Block parser, run by `fuzz-short` ([../test-strategy.md](../test-strategy.md) §7.2).
- Markers `PACKAGE_IMPORT_START` and `PACKAGE_INSPECTED` for the new formats (§13).

Out of scope:

- The relation classification of §4.7 and the routing of `.update` to UpdateCore (#038). This task does not change how `ImportPreview.relation` is computed.
- The relational checks V1–V6 and the signer-continuity primitives (#041).
- Installing split sets through one session (#042). This task only builds and checks the set.
- Rendered icons from the Store Agent (`RenderIcon`, #055).
- The Add sheet in APKRun.app (#078). The `--provider` and `--updates` flags of `apkrun install` (#037).
- OBB expansion files (v1.x, §17). `.xapk` and `.apkm` in Direct manifests (not allowed, [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §4).
- Hardening beyond the aapt2 profile, and the long fuzz runs (#091).

### Deliverables

- `ContainerReader`, `SplitSelector`, `APKInspector` (full), `ArtifactVerifier`, `ImportPreview`, and `HostIconPreview` in `Packages/APKStoreCore/Sources/APKStoreCore/Import/`.
- `APKSignatureVerifier` in `Packages/APKStoreCore/Sources/APKStoreCore/Signing/`, with the apksig vectors in `Packages/APKStoreCore/Tests/APKStoreCoreTests/Resources/apksig/`.
- The aapt2 `sandbox-exec` profile, shipped next to `Contents/Resources/tools/aapt2`.
- `inspectFile` and `adoptPackage` in RuntimeHost. `apkrun inspect` and `apkrun adopt`, with golden output in `CLI/apkrun/Tests/Golden/`.
- The container fixtures and the generated `.apks` of [../test-strategy.md](../test-strategy.md) §4.3, built by `scripts/build-fixtures.sh` and committed to `Tests/Fixtures/apks/` (each at most 10 MiB; the zip bomb is generated at test time).
- `scripts/dev/verify-corpus.sh`, the nightly differential run against `apksigner verify --print-certs -v` over the corpus of `Tests/Compatibility/apps.json`.
- Fuzz targets in `Packages/APKStoreCore/Tests/APKStoreCoreFuzz/`, seed corpora in `Tests/Fixtures/fuzz/<target>/`.
- The ZIPFoundation dependency with an `exact:` version in `Package.swift` and `Package.resolved`, as ADR-0017 [0017-zipfoundation-zip-reading.md](../../01-architecture/decisions/0017-zipfoundation-zip-reading.md) decides.
- `store` error codes for every new `StoreFailure` case in `errors.json`.

### Implementation steps

The design steps are [package-store.md](../../02-design/package-store.md) §15 #073, steps 1–8.

1. **Containers and limits (design step 1).** Add ZIPFoundation to `Packages/APKStoreCore/Package.swift` with an `exact:` version, as ADR-0017 [0017-zipfoundation-zip-reading.md](../../01-architecture/decisions/0017-zipfoundation-zip-reading.md) decides. Add `ContainerReader.detect(_:)` and `extract(into:)`. `ContainerReader` is the only code that calls ZIPFoundation, uses only its reading API, and never calls its extract-to-directory functions. Detection looks at the content (§4.2 table), never at the extension alone. Extraction streams each entry into `incoming/<ticket>/` under a fixed name and checks the limits entry by entry while streaming (512 entries, 256 APKs, 2 GiB per file, 8 GiB in total, 100:1 per entry, UTF-8 relative names without `..`, no symlink or device entries), failing with `archiveLimitExceeded`. `.apks` ignores `standalones/`, and a lone `universal.apk` is a single APK. Check: the T0 container fixtures pass, including the zip bomb, the `../` entry, the symlink entry, 600 entries, and a ZIP64 container.
2. **`SplitSelector` (design step 2).** Implement the §4.4 rules: the base always, all feature splits, the ABI splits for the guest ABIs, the density bucket nearest to 320 dpi (else the highest), all languages, and unknown `configForSplit` splits of an included split. Files dropped one by one are not filtered. Then check the base's `requiredSplitTypes` against the included `splitTypes` (`incompleteSplitSet(missing:)`). Excluded splits go into `ImportPreview.excludedSplits`. Check: the T0 test over the generated `.apks` (3 ABIs, 6 densities, 10 languages, one feature split, `requiredSplitTypes`) passes.
3. **`APKSignatureVerifier` (design step 3).** Implement steps 1–6 of §4.5 in `Sources/APKStoreCore/Signing/`: locate the EOCD, the central directory, and the signing block; pick v3.1, v3, or v2 for the guest SDK; verify the 1 MiB chunk digests and the signer signatures with `SecKeyVerifySignature`; parse the proof-of-rotation lineage with its flags; and compute the signer set. Add the special cases of the §4.5 table (`legacySignatureNotAllowed`, `.certificateOnly`, `invalidSignature`, `unsignedAPK`). Copy the apksig test resources (Apache-2.0) into the test bundle. Write `scripts/dev/verify-corpus.sh` and add it to the nightly `compatibility` job ([../../05-development/build-system.md](../../05-development/build-system.md) §12). Check: every vector in the §16 list gives the expected result.
4. **`ArtifactVerifier` (design step 4).** Implement `ArtifactVerifier.verify(set, guest:) → VerifiedArtifactSet` with I1–I12 in table order, each failure as its `StoreFailure` case, and the four warnings. Read `GuestFacts` from `Runtime/instance/instance.json`, or from the image manifest before the first boot. Record the host checks performed and the aapt2 and verifier versions in `InspectionProvenance`. Check: one T0 fixture per failure and per warning passes, including HelloNative's 32-bit-only variant (I7) and HelloLegacySig (`.certificateOnly` at targetSdk 29).
5. **Preview and `apkrun inspect` (design step 5).** Fill `ImportPreview`: the label in the best match of the macOS preferred languages, the icon as a PNG or WebP bitmap through ImageIO, an adaptive icon composed from bitmap or color layers on a 108 dp canvas, and the placeholder for vector layers (§10.1). Add `SignerSummary` (digests, scheme, lineage length, verification level) and the permission list. Add the `.control` operation `inspectFile`, which deletes its ticket when it finishes, and `apkrun inspect <file>… [--json]`. Check: the golden output passes, and `apkrun inspect` works with the runtime stopped and starts no VM.
6. **aapt2 sandbox and limits (design step 6).** Run aapt2 under a `sandbox-exec` profile that denies network and writes and allows reads of the ticket directory and the tool only. Keep the 20 s timeout per call, the 16 MiB output cap, and `LANG=C`. If `sandbox-exec` is missing, run unsandboxed and log a warning. Add the aapt2 golden tests for the pinned version. Check: the T1 golden tests pass, and a T1 test shows that an aapt2 run cannot write outside the ticket.
7. **`apkrun adopt` (design step 7).** Add `adoptPackage(id)` (§9.3): a record with `installer: external`, `updateAuthority: external`, no artifact, and `source: adopted`, and the text that says APKRun cannot restore the app after Reset Android. It needs the `UpdateAuthority.external` case from #037 step 1, so this step merges after it. Check: an app installed with `adb install` in developer mode is listed as unmanaged, and after `apkrun adopt` it is managed with authority `external`.
8. **Acceptance (design step 8).** Run the §16 fixture matrix, the F-Droid corpus, and the inspect timing, and record the results. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`): container fixtures (`.apk`, split files, `.apks` from bundletool, `.xapk` without OBB, `.xapk` with OBB refused, `.apkm` plain, `.apkm` non-ZIP refused, `.aab` refused, zip bomb, `../` entry, symlink entry, 600 entries, a ZIP64 container). The ZIP64 container is small, uses ZIP64 records, and is generated at test time (ADR-0017 [0017-zipfoundation-zip-reading.md](../../01-architecture/decisions/0017-zipfoundation-zip-reading.md), "Verification"). Split selection over the generated `.apks`. Signature verifier with the apksig vectors (v2, v3, v3.1, rotated lineage, multiple signers, RSA and ECDSA with SHA-256/512, DSA → certificate-only, v1-only with targetSdk 29 and 30, bad digest, bad signature, truncated block). Intrinsic checks I1–I12, one fixture per failure. Preview label and icon choice.
- **T1** (`Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): aapt2 golden outputs for the pinned aapt2 version, and the sandbox profile. `fuzz-short` (60 s per target) for the container reader and the APK Signing Block parser, in `Packages/APKStoreCore/Tests/APKStoreCoreFuzz/`, with crash reproducers kept in `Tests/Fixtures/fuzz/<target>/`.
- **T2**: none in the matrix. The adopt check of step 7 runs in `Tests/IntegrationTests/StoreTests/` on the stock image.
- **T3** (nightly, `compatibility` job): the 50-APK F-Droid corpus: `scripts/dev/verify-corpus.sh` compares signer digests with `apksigner`, and `apkrun inspect` runs in under 1 s per 50 MiB APK on the reference Mac ([../test-strategy.md](../test-strategy.md) §7.1).

### Acceptance criteria

- [ ] The fixture matrix of §16 passes: every container fixture, the split-selection test, every verifier vector, and one fixture per intrinsic check I1–I12.
- [ ] `.apks`, `.xapk` without OBB, `.apkm`, and a ZIP of APKs import as one split set (FR-PKG-06). `.aab`, encrypted `.apkm`, and `.xapk` with OBB are refused with their own messages.
- [ ] For 50 real F-Droid APKs, the verifier's signer digests equal `apksigner verify --print-certs -v`.
- [ ] `apkrun inspect` shows the name, icon, version, signer, permissions, and warnings with the runtime stopped, and it starts no VM (FR-PKG-03).
- [ ] `apkrun inspect` finishes in under 1 s per 50 MiB APK on the reference Mac.
- [ ] After an install, `apkrun info` shows Android's values (label, version name, signer), not the host preview values (FR-PKG-02).
- [ ] aapt2 runs under the sandbox profile with a 20 s timeout and a 16 MiB output cap. The inspector never executes anything from the APK (NFR-SEC-01).
- [ ] A package with a targetSdk below the install floor, with only a v1 signature and targetSdk 30, or with a compressed `resources.arsc` and targetSdk 30, is refused before install with `targetSdkTooLow`, `legacySignatureNotAllowed`, or `resourcesArscNotAligned` (R-15).
- [ ] `apkrun adopt` turns an unmanaged package into a managed one with authority `external` and no artifact.
- [ ] Both fuzz targets run in `fuzz-short` on every pull request with no open crash.

### Notes

- **Record:** the R-15 result in [../risks.md](../risks.md): the install floors the host catches (I8, I9, I12, `legacySignatureNotAllowed`), each with its fixture. The field share stays open for #090.
- **Record:** the result of the first corpus run (`verify-corpus.sh`) in §4.5, including any APK where the host and `apksigner` disagree.
- ADR-0017 [0017-zipfoundation-zip-reading.md](../../01-architecture/decisions/0017-zipfoundation-zip-reading.md) settles the ZIPFoundation dependency. No other ADR is needed.
- `apkrun inspect` never installs and never classifies an update. Its relation field is informational until #038.
- The host verifier is an early check, not the final authority (§4.5). A false rejection is possible. A successful install of something Android would reject is not.
- **Pitfall:** the zip bomb must not be committed as a large file. Generate it at test time from a seed ([../test-strategy.md](../test-strategy.md) §4.1).
- **Pitfall:** aapt2 output changes between versions. The golden tests pin the version from [../../05-development/build-system.md](../../05-development/build-system.md). Updating aapt2 means re-running and reviewing them.

---

## #037 LocalUpdateProvider

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #036 |
| Requirements | FR-PKG-04, FR-UPD-01, FR-UPD-02, FR-UPD-03 |
| Design | [update-system.md](../../02-design/update-system.md) §1, §2.1, §2.4, §4.1–§4.3, §5, §9, §10, §11.1, §11.3, §13, §14, §15 #037, §16; [package-store.md](../../02-design/package-store.md) §2.2, §2.3, §3, §5.1, §5.2 (`stage`, `discardStaged`), §5.5, §6.3, §7.1, §15 #037; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §6; ADR-0010 [0010-update-authority-provider-split.md](../../01-architecture/decisions/0010-update-authority-provider-split.md); [runtime-api.md](../../03-reference/runtime-api.md) §8.2, §9; [cli.md](../../02-design/cli.md) §4.2 (`install` flags), §4.3; [../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md) §1; [error-catalog.md](../../03-reference/error-catalog.md) §11 |
| Modules / paths | `Packages/UpdateCore/` (new target: `UpdateProvider`, `UpdateCandidate`, `RemoteArtifact`, `ProviderCursor`, `UpdatePhase`, `UpdateFailure`, `ProviderRegistry`, `Providers/LocalProvider.swift`, `UpdateStateStore`, `UpdateCoordinator`), `Packages/APKStoreCore/` (`UpdateAuthority`, `UpdateProviderRef`, `stage` and `discardStaged` transactions, `artifacts.staged`), `Packages/RuntimeAPI/` (update DTOs), `Packages/RuntimeHost/` (`HostNotifier`, UpdateCore wiring), `Daemon/apkrund/`, `Apps/APKRun/` (`HostNotificationClient`), `CLI/apkrun/Commands/Update.swift`, `Tests/Fixtures/update-repos/local/` |
| Risks / questions | None open for this task in [../open-questions.md](../open-questions.md) |

### Goal

With HelloUpdate V1 installed and a local folder that holds V2, `apkrun update --check-only` reports that version 2 is available, with no network. The update architecture exists: the provider protocol, the candidate, the authority in the package record, the persisted update state, and the coordinator up to `available`, plus the store's `stage` and `discardStaged` transactions.

### Scope

- The `UpdateCore` target with the types of §4.1 (`UpdateProvider`, `UpdateProviderRef`, `UpdateCandidate`, `RemoteArtifact`, `ProviderContext`, `ProviderCursor`), `UpdatePhase` ([../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §6), and `UpdateFailure` (§13). `PackageArtifact` is the store type defined in [package-store.md](../../02-design/package-store.md) §2.2, which UpdateCore uses.
- `UpdateAuthority` and `UpdateProviderRef` in `PackageRecord`, `claimsUpdateOwnership` ([package-store.md](../../02-design/package-store.md) §6.3), and the defaults of §2.4: a file import without a provider is `manual`; `apkrun install … --provider <spec>` is `apkrun` with `automatic`, or `notifyOnly` with `--updates notify`.
- `ProviderRegistry` with the spec parser (`local:<path>` in M6; `direct:` is added by #050) and `LocalProvider` (§4.3).
- `UpdateStateStore` (§10): `Updates/state.json` and `Updates/history.jsonl`.
- `UpdateCoordinator` with the phases `checking` and `available`, the cursor rule (§4.2), and `completed(.skipped(.upToDate))` and `completed(.skipped(.checkFailed))`.
- The store's `stage` and `discardStaged` transactions and `artifacts.staged` ([package-store.md](../../02-design/package-store.md) §5.2, §7.1), with recovery. The staged set is shown by `apkrun info`.
- The `.control` operations `checkForUpdates`, `listUpdates`, and `updateHistory` (§11.1), and a first `setUpdatePolicy` that attaches or removes a provider (see Notes). `apkrun update --check-only [--json]`, `apkrun update history`, `apkrun update policy <package> --mode … --provider <spec>`, and the `apkrun install` flags `--provider` and `--updates`, including the alternate flag spellings.
- `HostNotifier` in RuntimeHost with the "update available" notification for `notifyOnly` (§9), sent to connected UI clients. UpdateCore reaches it through an interface that RuntimeHost injects, in the same way as `UpdateRuntimeAccess` (§7.5). APKRun.app (from #066) gets `HostNotificationClient` and the `--notify` background start ([../../02-design/host-ui.md](../../02-design/host-ui.md) §3.3, §11).
- The fixture repository `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/`.
- Logging (`io.apkrun.update`, categories `scheduler` and `provider`) and the markers `UPDATE_CHECK_START` and `UPDATE_CHECK_END` (§14).

Out of scope:

- Downloading, validating, staging a candidate, and installing it (#038). The `stage` transaction exists here, but only T1 tests call it.
- The full authority rules and the UI mapping, Manual mode, and relinquishing ownership (#039).
- Scheduled and opportunistic checks (#074). Here a check runs only when a user or a test asks.
- The Direct, F-Droid, and GitHub providers (#050, #051, #052). Provider detection in the Add sheet (#078).
- The per-app settings UI (#079).

### Deliverables

- `Packages/UpdateCore/` with the types, `ProviderRegistry`, `LocalProvider`, `UpdateStateStore`, and `UpdateCoordinator`, wired into apkrund by RuntimeHost, and `HostNotifier` in `Packages/RuntimeHost/` ([../../01-architecture/modules.md](../../01-architecture/modules.md) §3: UpdateCore depends on APKStoreCore, RuntimeAPI, and DiagnosticsCore only).
- `UpdateAuthority`, `UpdateProviderRef`, `stage`, `discardStaged`, and `artifacts.staged` in `Packages/APKStoreCore/`.
- The update DTOs of [runtime-api.md](../../03-reference/runtime-api.md) §9.2 that these operations use, in `Packages/RuntimeAPI/`.
- `apkrun update --check-only`, `apkrun update history`, `apkrun update policy`, and the `apkrun install` flags, with golden output.
- `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/1/app.apk` and `2/app.apk`, filled by `scripts/build-fixtures.sh` from the HelloUpdate V1 and V2 builds.
- `update` error codes for the `UpdateFailure` cases used here.

### Implementation steps

The design steps are [update-system.md](../../02-design/update-system.md) §15 #037, steps 1–6, and [package-store.md](../../02-design/package-store.md) §15 #037, steps 1–3. They are merged in this order: store step 1 comes first, because the UpdateCore types use `UpdateAuthority` from APKStoreCore.

1. **Authority and provider in the record (store design step 1).** Add `UpdateAuthority` (`.apkrun`, `.manual`, `.googlePlay`, `.external`) and `UpdateProviderRef {type, configuration}` to APKStoreCore, and the fields `updateAuthority` and `updateProvider` to `PackageRecord` ([package-store.md](../../02-design/package-store.md) §2.3). Add `claimsUpdateOwnership` (true for `apkrun` and `manual`). File imports without a provider get `manual`. Existing records from #027 and #036 already hold `manual`. Check: the T0 record round trip passes, and a record written by #036 reads unchanged.
2. **UpdateCore types (design step 1).** Create the `UpdateCore` target with `UpdateProvider`, `UpdateCandidate`, `RemoteArtifact`, `ProviderContext`, `ProviderCursor`, `UpdatePhase`, and `UpdateFailure`, using `UpdateAuthority` and `UpdateProviderRef` from APKStoreCore. Check: the module dependency check of #062 passes.
3. **`ProviderRegistry` and `LocalProvider` (design step 2).** The registry parses `local:<path>` into an `UpdateProviderRef`. The CLI opens the folder and sends a bookmark in `ProviderSpec.bookmark`, because apkrund does not open the path itself ([runtime-api.md](../../03-reference/runtime-api.md) §9.2). `LocalProvider.check` reads `<root>/<packageId>/`, takes the highest numeric directory greater than the installed versionCode, and returns a candidate with `declaredVersionCode` = the directory name and the cursor = the directory name plus its modification time. A directory holds `app.apk`, or `base.apk` plus `split_*.apk`, or one `.apks`. `download` clones the files with `clonefile`, or copies them, into the ticket. Local declares no provider hashes. The provider is hidden in the UI unless developer mode is on ([../../03-reference/configuration.md](../../03-reference/configuration.md) §2.5). Check: the T0 tests over temporary folders pass (none, `1` only, `1` and `2`, `0`, a non-numeric name, an unreadable folder).
4. **State store and coordinator (design step 3).** Add `UpdateStateStore` with the schema-1 `state.json` of §10 (written atomically, at most once per second; a missing file makes every package due) and `history.jsonl` (one line per run, 365 days or 5000 lines, no query URLs or tokens). Add `UpdateCoordinator` with `checking` → `available`, `completed(.skipped(.upToDate))`, and `completed(.skipped(.checkFailed))`, and the cursor rule of §4.2. For `notifyOnly`, `available` stops and `HostNotifier` posts "update available" (§9). Check: the T1 coordinator tests for these transitions and for a restart in `available` pass.
5. **Stage and discard (store design step 2).** Add the `stage` transaction (begin → filesStaged → metadataWritten → commit; the old `staged/` goes to `.trash`, `incoming/<ticket>/` becomes `staged/`) and `discardStaged` (begin → filesRemoved → metadataWritten → commit), with their recovery rows of [package-store.md](../../02-design/package-store.md) §5.5 and the `APKRUN_STORE_FAULT` hooks. `artifacts.staged` records the provider, the release URL, and the declared hash (§7.1). `apkrun info` shows the staged set. Check: the T1 crash-injection run over every step of both kinds leaves a consistent store.
6. **Operations and CLI (design step 4).** Add `checkForUpdates`, `listUpdates`, and `updateHistory`, and a first `setUpdatePolicy` that attaches a provider (authority `apkrun`) or removes it (authority `manual`), and returns `update.providerNotConfigured` for `automatic` or `notifyOnly` without a provider. Add `apkrun update --check-only [--json]`, `apkrun update history [<package>] [--limit <n>] [--json]`, `apkrun update policy <package> --mode … [--provider <spec> | --no-provider]`, and the `apkrun install` flags `--provider` and `--updates automatic|notify|manual` ([cli.md](../../02-design/cli.md) §4.2; `--updates manual` sets `InstallOptions.authority` to `manual`), with the alternate flag spellings translated by the CLI. Check: the golden outputs pass.
7. **Fixture repository (design step 5).** Extend `scripts/build-fixtures.sh` so that it fills `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/1/` and `2/` from the HelloUpdate V1 and V2 builds of `Tests/Fixtures/AndroidApps/` ([../../05-development/build-system.md](../../05-development/build-system.md) §8). Check: the script output matches the committed copies.
8. **Acceptance (design step 6, store design step 3).** Run the acceptance with V1 installed through the store. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`, `Packages/APKStoreCore/Tests/APKStoreCoreTests/`): `LocalProvider` directory rules and cursors over temporary folders, the provider spec parser, the `state.json` round trip, the record round trip with the new fields, and the recovery rows of `stage` and `discardStaged`. The matrix lists no T0 test for this task. These are unit tests of the new types.
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`, `Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): the coordinator end to end with a fake store, a fake runtime, and a fake UI client: `checking` → `available`, `upToDate`, `checkFailed`, `notifyOnly` stops and notifies, a restart in `available` resumes from `state.json`. `APKRUN_STORE_FAULT` at every step of `stage` and `discardStaged`. CLI goldens against a fake `RuntimeService`.
- **T2** (`Tests/IntegrationTests/UpdateTests/`, `AndroidStock` and `AndroidCustom`): HelloUpdate V1 installed, `apkrun update --check-only` reports version 2 with the local provider. The V1 → V2 install with data kept is in the same file and becomes green with #038.

### Acceptance criteria

- [ ] With HelloUpdate V1 installed and the local provider attached, `apkrun update --check-only` reports that version 2 is available: the updater identifies that V2 supersedes V1.
- [ ] With only directory `1` in the repository, it reports "up to date". A directory `0` is never a candidate.
- [ ] `UpdateProvider` and `UpdateCandidate` are in UpdateCore. `UpdateAuthority`, `UpdateProviderRef`, and `PackageArtifact` are in APKStoreCore, and the record stores the authority and the provider as separate fields (FR-UPD-01, FR-UPD-02).
- [ ] `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/` exists and is filled by `scripts/build-fixtures.sh`.
- [ ] The check needs no network: it passes with the network down (FR-UPD-03).
- [ ] A staged set written through `stage` is shown by `apkrun info`, and `discardStaged` removes it. Both survive a crash at every step (FR-PKG-04).
- [ ] A package set to `notifyOnly` stops in `available` and gets one "update available" notification.
- [ ] `state.json` and `history.jsonl` hold the check, its outcome, and the cursor. Deleting `state.json` makes the package due again.

### Notes

- **Record:** nothing to verify on Android in this task.
- `claimsUpdateOwnership` is defined here but used first by #039.
- `setUpdatePolicy` and `apkrun update policy` are shared with #039 ([cli.md](../../02-design/cli.md) §4.3). Build only the part the acceptance needs here: attach or remove a provider. #039 adds the full rules of §2.1–§2.4 and the refusals.
- `apkrun update --check-only` runs one check on demand (§15 #037 step 4). #074 adds the scheduled checks and the waiting and failed lines of the full output ([cli.md](../../02-design/cli.md) §4.3).
- The `apkrun install` flags `--provider` and `--updates` come with this task because they need `ProviderRegistry` ([cli.md](../../02-design/cli.md) §4.2). #073 owns the rest of `apkrun install`.
- This task posts the first host notification ("update available" for `notifyOnly`), so it builds `HostNotifier` and `HostNotificationClient`, including the `--notify` background start ([../../02-design/host-ui.md](../../02-design/host-ui.md) §11, §14). Later tasks add their own notification rows. The v0.3 checklist reads the update notifications (C03-1, C03-2). T1 tests use a fake UI client. Notifications of Android apps come with #054.
- Define `UpdateProviderRef`, `ProviderType`, and `ProviderConfiguration` (§4.1) in APKStoreCore, because the package record stores them ([package-store.md](../../02-design/package-store.md) §2.3) and APKStoreCore must not import UpdateCore (§15 #037 step 1). UpdateCore uses them.
- **Pitfall:** `UpdateAuthority` lives in APKStoreCore, not in UpdateCore, and UpdateCore never imports RuntimeCore ([../../01-architecture/modules.md](../../01-architecture/modules.md) §3). A new dependency fails the #062 check.
- **Pitfall:** the provider spec reaches apkrund as a bookmark. Do not pass a path that apkrund would open itself.

---

## #038 PackageInstaller updates

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #037, #073 |
| Requirements | FR-UPD-15, NFR-REL-01 |
| Design | [update-system.md](../../02-design/update-system.md) §5, §6, §7.2, §7.5, §8.1 (H1), §10, §11.1, §11.3, §13, §14, §15 #038, §16; [package-store.md](../../02-design/package-store.md) §3.1, §3.3, §3.4, §4.7, §5.2, §5.3, §5.5, §6.1, §6.2, §6.4, §7.2, §11.1, §12, §13, §15 #038, §16; [guest-protocol.md](../../02-design/guest-protocol.md) §11.3; [package-metadata-json.md](../../03-reference/package-metadata-json.md) §2.3, §6; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §6; [runtime-api.md](../../03-reference/runtime-api.md) §4.7, §8.2, §9; [cli.md](../../02-design/cli.md) §4.2 (`install`), §4.3; [error-catalog.md](../../03-reference/error-catalog.md) §10, §11 |
| Modules / paths | `Packages/APKStoreCore/` (`installStaged`, `recordHealth`, `beginDownloadTicket`, `inspect(ticket)`, the `update` transaction and its recovery, `ImportRelation` classification), `Packages/UpdateCore/` (`UpdateCoordinator` phases `downloading` to `healthChecking`, a first `UpdateValidator`), `Packages/RuntimeHost/` (first `UpdateRuntimeAccess` implementation, `StoreRuntimeAccess.hasOpenSession`), `Packages/RuntimeAPI/` (`updatePackage`, `CheckForUpdatesRequest.checkOnly`), `CLI/apkrun/Commands/Update.swift`, `CLI/apkrun/Commands/` (`install`), `Tests/IntegrationTests/UpdateTests/`, `Tests/IntegrationTests/StoreTests/` |
| Risks / questions | None open for this task in [../open-questions.md](../open-questions.md) |

### Goal

With HelloUpdate V1 installed and its data written, APKRun downloads HelloUpdate V2 from the local provider, validates it on the host, stages it, and installs it through one `PackageInstaller` session. V2 has a higher versionCode and still reads V1's data. A V2 signed by another key is refused before Android sees it. A newer file from the user takes the same path. A crash at any step leaves the store and Android consistent (NFR-REL-01).

### Scope

- The store's `update` transaction and `installStaged(id, enableRollback:)` on both channels ([package-store.md](../../02-design/package-store.md) §5.2, §7.2), with the promotion by `renamex_np(RENAME_SWAP)`, the recovery rows of [package-store.md](../../02-design/package-store.md) §5.5, `recordHealth(id, result)`, and the `APKRUN_STORE_FAULT=update:<step>` hooks.
- `PackageStore.beginDownloadTicket(id)` and `PackageStore.inspect(ticket)` (§5).
- The coordinator phases `downloading`, `validating`, `staged`, `installing`, and `healthChecking` ([../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §6), with a health check that runs H1 only (§8.1) until #043.
- A first `UpdateValidator` with V0 (the intrinsic checks of #073), V1, V2, and signer equality (the first case of V3, §6).
- An install without the gate: the coordinator installs a staged set only when the package has no session (§15 #038 step 1). A first `UpdateRuntimeAccess` implementation in RuntimeHost with `runtimeState`, `hasActiveUse`, and `ensureReady` (§7.5).
- Manual updates from a file: the relation classification of [package-store.md](../../02-design/package-store.md) §4.7, and `ImportRelation.update` routed to UpdateCore at `validating`.
- `updatePackage(id, UpdateNowOptions)` (§11.1) with and without `files`. `apkrun update <package> [--file <apk>…]`. `apkrun update` without `--check-only` continues `automatic` packages past `available`.
- One history line per run, the `packages.updated` event, and the markers `UPDATE_DOWNLOAD_START`, `UPDATE_DOWNLOAD_END`, `UPDATE_INSTALL_START`, and `UPDATE_INSTALL_END` (§14).

Out of scope:

- `GentleUpdateGate`, the session and install races of §7.2, `--now`, and the "Quit ‹App› and update now?" question (#040).
- Signer rotation (V3 cases 2 and 3), V4, V5, V6, and the full `ValidationReport` (#041).
- Split sets in an update. This task updates single-APK sets only (#042).
- `enable_rollback` on the wire, the full health check, and rollback (#043). `installStaged` is called with `enableRollback: true`, and the store masks it until the channel has `.rollback`.
- Update ownership in the install request (#039). The field stays masked until the channel has `.updateOwnership`.
- `ImportRelation.uninstalledWithData`, which needs the kept-data records of #076 (M7).
- Scheduled checks (#074).

### Deliverables

- In `Packages/APKStoreCore/`: `installStaged`, `recordHealth`, `beginDownloadTicket`, `inspect(ticket)`, the `update` transaction with its recovery rows and fault hooks, and the relation classification in `beginImport`.
- In `Packages/UpdateCore/`: the phases from `downloading` to `healthChecking` in `UpdateCoordinator`, and `UpdateValidator` with V0–V2 and signer equality.
- In `Packages/RuntimeHost/`: the first `UpdateRuntimeAccess` implementation and `StoreRuntimeAccess.hasOpenSession(_:)`.
- In `Packages/RuntimeAPI/`: `updatePackage` with its DTOs, and `CheckForUpdatesRequest.checkOnly` (see Notes).
- `apkrun update <package> [--file <apk>…]`, `apkrun update` without `--check-only`, and the relation lines of `apkrun install`, with golden output in `CLI/apkrun/Tests/Golden/`.
- The T2 update tests in `Tests/IntegrationTests/UpdateTests/` and `Tests/IntegrationTests/StoreTests/`.
- The `store` and `update` error codes used here in `errors.json`, including `store.packageInUse`, `update.downloadFailed`, `update.hashMismatch`, `update.tooLarge`, and the `update.validation` causes of V1 and V2.

### Implementation steps

The design steps are §15 #038, steps 1–3, and [package-store.md](../../02-design/package-store.md) §15 #038, steps 1–3. They are merged in this order: store step 1 comes first, because the coordinator's install phase calls `installStaged`. Design step 1 of this document is split into steps 2–4 below.

1. **The `update` transaction (store design step 1).** Add `installStaged(id, enableRollback:)` with the steps `begin` → `guestCommitRequested` → `guestInstalled` → `filesPromoted` → `metadataWritten` → `commit` ([package-store.md](../../02-design/package-store.md) §5.2). On the custom image it sends `InstallRequest{mode: UPDATE, expected_version_code, expected_signer_sha256, request_update_ownership, enable_rollback}` ([guest-protocol.md](../../02-design/guest-protocol.md) §11.3), with `request_update_ownership` masked by `.updateOwnership` and `enable_rollback` masked by `.rollback`. On the stock image it runs `adb install-multiple -r --no-streaming` and reads the result with `QueryPackage`. Before `BeginInstall`, the store asks the new `StoreRuntimeAccess.hasOpenSession(_:)` and fails with `packageInUse(id)` when a session exists. Promotion: the old `previous/` goes to `.trash`, `staged/` and `current/` swap with `renamex_np(RENAME_SWAP)`, and the old `current/` becomes `previous/`. `lastOperation` becomes `update(from:to:, healthPending: true)`, and `recordHealth(id, result)` clears it as a write outside transactions ([package-metadata-json.md](../../03-reference/package-metadata-json.md) §6.2). Map `InstallFinished` statuses as in [package-store.md](../../02-design/package-store.md) §6.4. A cancel before `guestCommitRequested` abandons the session and keeps `staged/`. Add the recovery rows for `update` and the `APKRUN_STORE_FAULT=update:<step>` hooks. Check: the T0 recovery rows pass for every step against each scripted Android state (target installed, old version installed), and the T1 crash-injection run over every host step leaves a consistent store.
2. **Download ticket (design step 1).** Add `PackageStore.beginDownloadTicket(id)`, which creates `incoming/<ticket>/`. In `downloading`, the coordinator calls `provider.download` into the ticket, hashes while streaming, and caps the size at 8 GiB (`tooLarge`). A declared hash that differs discards the files and retries once from scratch, then fails with `hashMismatch`. Network errors retry twice (after 10 s and 60 s) and then end with `completed(.skipped(.downloadFailed))`. A partial download is deleted. Progress events are coalesced to 10 Hz. Check: the T1 coordinator tests with a fake provider and a manual clock pass (one hash mismatch, two hash mismatches, a network error, an oversized download).
3. **Inspection and the first rules (design step 1).** In `validating`, `PackageStore.inspect(ticket)` runs the intrinsic checks I1–I12 of #073 as V0. `UpdateValidator` adds V1 (package ID), V2 (versionCode against Android's `longVersionCode` from the last reconcile: equal gives `notNewer`, lower gives `downgrade`), and signer equality (*S′ = S*). Any failure ends with `completed(.skipped(.validationFailed(reason)))`, deletes the ticket, and saves the cursor. Check: the T0 rule tests with HelloUpdate V1, V2, V2-other-signer, and HelloText as a wrong package pass.
4. **Stage, install, and H1 (design step 1).** In `staged`, the coordinator calls `PackageStore.stage(ticket, StagedUpdateInfo)` from #037. It then installs at once when `hasActiveUse` is false: `installStaged(id, enableRollback: true)`, then `installing` → `healthChecking`. The health check is H1 only: Android reports the staged versionCode and signer set within 30 s. On success it calls `recordHealth(id,.passed)` and ends with `completed(.updated(from:to:))`. An Android refusal ends with `completed(.skipped(.installFailed))`. Add the first `UpdateRuntimeAccess` in RuntimeHost with `runtimeState`, `hasActiveUse` (GU2 and GU3), and `ensureReady(.update)`. Automatic runs install only while the runtime is `ready`. User-initiated runs call `ensureReady`. A package with a session stays `staged`, and the next `apkrun update <package>` installs it. After a restart, a set in `staged/` resumes as `staged`, and a record with `healthPending` gets its H1 check after `ready` (§10.1). Check: the T1 coordinator tests with a fake store and a fake runtime cover every transition from `downloading` to `completed`, `installing` → `completed(.skipped(.installFailed))`, and a restart in `staged` and with `healthPending`.
5. **Manual updates and relations (design step 2, store design step 2).** Classify every import as in [package-store.md](../../02-design/package-store.md) §4.7: `newPackage`, `sameAsInstalled` (same `setDigest`), `reinstallSameVersion` (the existing `reinstall` transaction with mode `REINSTALL`), `update(from:)`, `downgrade` (`store.downgradeRefused`, exit 5), and `otherSigner` (`store.signerMismatch`, exit 5). `installImported` with `.update` hands the ticket to UpdateCore, which enters at `validating` with trigger `manual` and user-initiated rules. `updatePackage` with `files` imports them and does the same. `apkrun` and `manual` packages accept files. `googlePlay` and `external` packages fail with `update.authorityDoesNotAllowUpdates` and its variant. Add `apkrun update <package> [--file <apk>…]`, the relation line of `apkrun install`, `CheckForUpdatesRequest.checkOnly` for `--check-only`, and `apkrun update` without `--check-only`. Check: the T0 relation classification tests and the CLI goldens pass.
6. **Acceptance (design step 3, store design step 3).** Run the T2 tests on both image kinds, including the kill during `CommitInstall` on the custom image. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Packages/UpdateCore/Tests/UpdateCoreTests/`): relation classification for every `ImportRelation` case and the routing of `.update` to UpdateCore. The recovery rows of `update` with a fake channel whose Android state is scripted. Rules V0–V2 and signer equality over the HelloUpdate fixtures. The authority check for files.
- **T1** (`Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`, `Packages/UpdateCore/Tests/UpdateCoreSystemTests/`): `PackageStore` with a fake `StoreAgentChannel`: update, `packageInUse`, `operationInProgress`, and the commit queue priorities. Crash injection with a real process: `APKRUN_STORE_FAULT=update:<step>` at every host step, restart, `open` result checked. The coordinator end to end with a fake store and a fake runtime for the transitions of step 4. CLI goldens against a fake `RuntimeService`.
- **T2** (`Tests/IntegrationTests/UpdateTests/` and `Tests/IntegrationTests/StoreTests/`, `AndroidStock` and `AndroidCustom`): HelloUpdate V1 is installed and launched once, so it writes `HELLO`. The local provider's V2 is installed through `installStaged`, Android reports versionCode 2, and V2 logs `data HELLO` (the #037 test turns green). V2-other-signer is refused by the host. The same APK installed directly with `AdbClient.install(apk:)` fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (on the stock image, and on the custom image in developer mode). A manual update with `apkrun update <package> --file`. On the custom image only: apkrund is killed during `CommitInstall`, once before and once after the commit, and the post-boot resolution gives the right version for both outcomes.
- **T3**: none.

### Acceptance criteria

- [ ] With HelloUpdate V1 installed, the local provider's V2 is downloaded, validated, staged, and installed through one `PackageInstaller` session, on the stock and on the custom image (FR-UPD-15).
- [ ] After the update, Android reports versionCode 2, and `apkrun info` shows it.
- [ ] V2 reads `files/data.txt` written by V1 and logs `data HELLO`.
- [ ] V2-other-signer is refused by the host before any Android call, with `update.signerMismatch` from the provider and `store.signerMismatch` from a file. Installed directly with `AdbClient.install(apk:)`, the same APK fails in Android with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. No build has a switch that disables the host check ([../../../AGENTS.md](../../../AGENTS.md) §4, invariant 10).
- [ ] A candidate with the installed versionCode is refused as `notNewer`, and a lower one as `downgrade`. A lower file is refused with `store.downgradeRefused` (exit 5).
- [ ] A newer file, from `apkrun install` or `apkrun update <package> --file`, gets the same validation and install as a provider update, and its history line has trigger `manual` (FR-UPD-15).
- [ ] No install starts while the package has a session: `installStaged` fails with `store.packageInUse` before `BeginInstall`, and the set stays in `staged/`.
- [ ] A fault at every `update` step (T1 for the host steps, T2 for `guestCommitRequested`) leaves `current/`, `previous/`, and `staged/` matching Android after restart (NFR-REL-01).
- [ ] Every run appends one line to `Updates/history.jsonl`, whatever its outcome.

### Notes

- **Record:** nothing to verify on Android in this task. The kill test is the contract test for the scripted Android states of the fake channel ([../test-strategy.md](../test-strategy.md) §3.2).
- Until #041, validation is V0–V2 plus signer equality. A rotated V2 is refused until then. That is stricter than the final rule, never looser.
- Until #043, the health check is H1 only. An H1 failure ends with `completed(.keptAfterFailedHealthCheck(.versionNotConfirmed))` and a log entry. #043 replaces this step with `UpdateHealthChecker`.
- `withStoreAgent` boots or resumes Android only for user-initiated operations. An automatic install runs only while the runtime is already `ready` ([package-store.md](../../02-design/package-store.md) §5.3, §3.1). The exception `updates.startRuntimeToInstall` comes with #074.
- The store asks `StoreRuntimeAccess.hasOpenSession(_:)` ([package-store.md](../../02-design/package-store.md) §6.1, §7.2) before `BeginInstall`. RuntimeHost implements it from `SessionRegistry`.
- From this task on, a check continues `automatic` packages past `available`. `apkrun update --check-only` therefore sets `CheckForUpdatesRequest.checkOnly` ([runtime-api.md](../../03-reference/runtime-api.md) §9.2). With `true`, every run stops at `available`, as for `notifyOnly`, and nothing is downloaded.
- Until #040, `apkrun update <package>` with the app open stages the update and exits 75 with `store.packageInUse`. #040 replaces this with the waiting rule of [cli.md](../../02-design/cli.md) §4.3.
- **Pitfall:** do not set `enable_rollback` or `request_update_ownership` on the wire before the channel has the capability. The Store Agent answers `INVALID_ARGUMENT` ([guest-protocol.md](../../02-design/guest-protocol.md) §11.3).
- **Pitfall:** recovery identifies slots by `setDigest`, never by directory name ([package-store.md](../../02-design/package-store.md) §5.5).
- **Pitfall:** tests that need Android's own refusal install through `AdbClient`. No hook skips a host check ([../test-strategy.md](../test-strategy.md) §3.3).

---

## #039 Update ownership

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #038 |
| Requirements | FR-UPD-01, FR-UPD-06 |
| Design | [update-system.md](../../02-design/update-system.md) §2.1–§2.4, §11.1, §11.3, §15 #039, §16; [package-store.md](../../02-design/package-store.md) §6.1, §6.3, §9.3, §11.1, §13, §15 #039, §16, §17, §18; [guest-protocol.md](../../02-design/guest-protocol.md) §5.3, §11.1, §11.3, §16; [guest-components.md](../../02-design/guest-components.md) §5, §8.2, §11, §14; [package-metadata-json.md](../../03-reference/package-metadata-json.md) §2.3, §3, §6.2; ADR-0010 [0010-update-authority-provider-split.md](../../01-architecture/decisions/0010-update-authority-provider-split.md); [runtime-api.md](../../03-reference/runtime-api.md) §9; [cli.md](../../02-design/cli.md) §4.3; [error-catalog.md](../../03-reference/error-catalog.md) §11 |
| Modules / paths | `Guest/APKRunStore/` (`OwnershipService`, `setRequestUpdateOwnership`, the enforcement flag in `Hello`), `Packages/GuestProtocol/` (op 109, `store.ownership.v1`), `Packages/APKStoreCore/` (`request_update_ownership`, `setUpdateAuthority`, `android.updateOwner`, the `store.ownership` health check), `Packages/UpdateCore/` (authority rules, `setUpdatePolicy`, `setUpdateAuthority`), `Packages/RuntimeAPI/` (`setUpdatePolicy`, `setUpdateAuthority`, `SetUpdateAuthorityRequest`), `CLI/apkrun/Commands/Update.swift` (`update policy`, `update authority`), `Tests/Fixtures/AndroidApps/OtherInstaller/`, `Tests/IntegrationTests/StoreTests/` |
| Risks / questions | R-18. The owner-less grant and the enforcement flag: [package-store.md](../../02-design/package-store.md) §17 and [guest-components.md](../../02-design/guest-components.md) §13, recorded in [../open-questions.md](../open-questions.md) §4 |

### Goal

APKRun is the update owner in Android for every package it manages (`apkrun` and `manual`), so another installer inside Android cannot update such a package without the user's approval. APKRun never claims ownership of a `googlePlay` or `external` package, and gives it up when a package moves to one of these authorities. The authority is stored in the package record, and the user's update choice maps onto it (#039).

### Scope

- `RelinquishUpdateOwnership` (op 109) and the capability `store.ownership.v1` ([guest-protocol.md](../../02-design/guest-protocol.md) §5.3, §11.1). `OwnershipService` in the Store Agent and `setRequestUpdateOwnership` in its install sessions ([guest-components.md](../../02-design/guest-components.md) §8.2).
- The enforcement-flag check, reported in `Hello` as part of the `store.ownership.v1` details.
- `request_update_ownership` on every install as in [package-store.md](../../02-design/package-store.md) §6.3: `firstInstall`, `reinstall`, and `update`, when the authority claims ownership and the channel has `.updateOwnership`.
- `android.updateOwner` recorded from `GetPackageMetadata` after every install, and the `store.ownership` health check (warning `store.updateOwnerMissing`).
- Authority changes in the store (`PackageStore.setUpdateAuthority`, [package-store.md](../../02-design/package-store.md) §6.3), with `RelinquishUpdateOwnership` when a package leaves `apkrun` or `manual` for `googlePlay` or `external`.
- The `.control` operation `setUpdateAuthority(id, AuthorityChoice)` (§2.1, §11.1) and `apkrun update authority <package> apkrun|manual|external` ([cli.md](../../02-design/cli.md) §4.3).
- The authority rules and the UI mapping of §2.1–§2.4, and the full `setUpdatePolicy(id, UpdatePolicy{choice, provider})` with its write order (§2.3).
- The full rules behind `apkrun update policy <package> --mode automatic|notify|manual [--provider <spec> | --no-provider]`. The command and its first form (attach or remove a provider) exist from #037.
- The OtherInstaller fixture.
- The owner-less verification of [package-store.md](../../02-design/package-store.md) §6.3 on the custom image.

Out of scope:

- The Updates choice and **Updated by** in the app page (#079), and the Updates choice in the Add sheet (#078). This task gives the model and the CLI.
- Google Play as an authority in practice (#097, post-v1). The authority exists and is refused here, and nothing sets it in M6.
- Gentle updates (#040) and rollback (#043).

### Deliverables

- `OwnershipService` in `Guest/APKRunStore/`, `setRequestUpdateOwnership` in `InstallService`, and the enforcement flag in the `store.ownership.v1` details of `Hello`.
- Op 109 and `store.ownership.v1` in `Packages/GuestProtocol/` (Swift and Kotlin), with the `StoreAgentChannel.relinquishUpdateOwnership(pkg)` call and the `.updateOwnership` capability.
- In `Packages/APKStoreCore/`: `request_update_ownership` from `claimsUpdateOwnership`, `setUpdateAuthority`, the `android.updateOwner` field after every install, and the `store.ownership` health check.
- In `Packages/UpdateCore/`: the authority rules (§2.1), the UI mapping (§2.3), `setUpdatePolicy`, and `setUpdateAuthority`.
- In `Packages/RuntimeAPI/`: `setUpdateAuthority` with `SetUpdateAuthorityRequest` and `AuthorityChoice` ([runtime-api.md](../../03-reference/runtime-api.md) §9.1, §9.2).
- `apkrun update authority`, and golden output in `CLI/apkrun/Tests/Golden/` for it and for the new `apkrun update policy` refusals.
- The OtherInstaller fixture (`io.apkrun.fixture.otherinstaller`) in `Tests/Fixtures/AndroidApps/OtherInstaller/`.
- The T2 ownership tests in `Tests/IntegrationTests/StoreTests/`.
- The results of the verification in [package-store.md](../../02-design/package-store.md) §6.3 and §18, and in [guest-components.md](../../02-design/guest-components.md) §14.
- The `errors.json` entries for `store.updateOwnerMissing`, `update.providerNotConfigured`, and the `update.authorityDoesNotAllowUpdates` variants.

### Implementation steps

The design steps are §15 #039, steps 1–2, and [package-store.md](../../02-design/package-store.md) §15 #039, steps 1–3. They are merged in this order: the store's install request first, then the authority rules, then the verification and the acceptance. Design step 1 of this document is split into steps 3–5 below.

1. **Store Agent side (store design step 1).** Add op 109 and `store.ownership.v1` to the protocol. Add `OwnershipService`, which calls `PackageManager.relinquishUpdateOwnership(package)` and answers `FAILED_PRECONDITION` when the Store Agent is not the owner. Set `setRequestUpdateOwnership(request_update_ownership)` in `InstallService`. Read the `DeviceConfig` flag for update-ownership enforcement at start, and report it in the `store.ownership.v1` details of `Hello` ([guest-components.md](../../02-design/guest-components.md) §8.2). The stock image's ADB channel has no `.updateOwnership`. Check: the T0 argument tests pass (`request_update_ownership` without the capability gives `INVALID_ARGUMENT`), and the Store Agent reports the flag on the custom image.
2. **Ownership on install (store design step 1).** Set `request_update_ownership = record.updateAuthority.claimsUpdateOwnership && channel.capabilities.contains(.updateOwnership)` on `firstInstall`, `reinstall`, and `update` ([package-store.md](../../02-design/package-store.md) §6.3). After every install, record `android.updateOwner` from `GetPackageMetadata` ([package-metadata-json.md](../../03-reference/package-metadata-json.md) §2.3). Add the `store.ownership` health check: an `apkrun` or `manual` package whose owner is not `io.apkrun.store` gives the warning `store.updateOwnerMissing`. Check: the T1 tests with a fake channel show the flag per authority and per capability.
3. **Authority changes in the store (design step 1).** Add `PackageStore.setUpdateAuthority(id, authority, provider:)` under the package's operation lock. When the package leaves `apkrun` or `manual` for `googlePlay` or `external`, it calls `RelinquishUpdateOwnership` first. When the runtime is not `ready`, the call is queued as a post-boot task, because an authority change never starts Android. `FAILED_PRECONDITION` is not an error ([error-catalog.md](../../03-reference/error-catalog.md) §8.2). Then it writes the record. A change to `apkrun` or `manual` touches no Android state. Ownership is requested on the next install. `adoptPackage` writes `external` with no provider ([package-store.md](../../02-design/package-store.md) §9.3). Check: the T1 tests with a fake channel cover the call order, the post-boot task, and `FAILED_PRECONDITION`.
4. **Authority rules and `setUpdatePolicy` (design step 1).** Implement the rules of §2.1 and the mapping of §2.3. A provider can only be attached to an `apkrun` package, attaching one to a `manual` package makes it `apkrun`, and detaching it makes it `manual`. `setUpdatePolicy` validates the provider configuration first and writes nothing on failure. It writes `settings.json` `update.mode` first, then `updateAuthority` and `updateProvider` in the record, so a crash between the two writes never turns on automatic updates. `.automatic` and `.notifyOnly` need a provider (`update.providerNotConfigured`). `googlePlay` and `external` packages refuse every choice with `update.authorityDoesNotAllowUpdates` (§2.3). Their authority changes only through `setUpdateAuthority` (step 5). A package leaving `apkrun` with a staged set discards it with reason `authorityChanged`. `checkForUpdates` skips every package that is not `apkrun`, and `updatePackage` without files on a `manual` package fails with the `manual` variant. Extend the `apkrun update policy` goldens with the refusals. Check: the T0 mapping tests pass, and the T1 test with a counting fake provider shows that a `manual` package gets no provider call from any trigger.
5. **`setUpdateAuthority` and `apkrun update authority` (design step 1).** Add the `.control` operation `setUpdateAuthority(id, AuthorityChoice)` with `SetUpdateAuthorityRequest` ([runtime-api.md](../../03-reference/runtime-api.md) §9.2). `AuthorityChoice` is `.apkrun`, `.manual`, or `.external`. Only #097 sets `googlePlay`. The operation calls `PackageStore.setUpdateAuthority` from step 3 and applies the rules of §2.1. A `googlePlay` package refuses every change (`update.authorityDoesNotAllowUpdates`). A move to `apkrun` needs the provider kept in the record (`update.providerNotConfigured`). A move away from `apkrun` discards a staged provider update, and a move to `external` discards every staged set. The change waits for a running install on the operation lock, and an update that has not started its install ends as `skipped(.authorityChanged)`. Add `apkrun update authority <package> apkrun|manual|external` with golden output. Check: the T0 rule tests and the CLI goldens pass, and the T1 test shows that a move to `external` sends `RelinquishUpdateOwnership` before the record write.
6. **OtherInstaller fixture (store design step 3).** Build `io.apkrun.fixture.otherinstaller` with `REQUEST_INSTALL_PACKAGES`. It carries HelloUpdate V2 in its assets. On first launch, it opens a `PackageInstaller` session for `io.apkrun.fixture.helloupdate` with `USER_ACTION_NOT_REQUIRED`, commits it, and logs `session <status>` ([../test-strategy.md](../test-strategy.md) §4.2). Check: the fixture builds with the test keys and logs a status on the stock image.
7. **Owner-less verification (store design step 2).** On the custom image in developer mode: install HelloUpdate V1 with `AdbClient.install(apk:)` so that it has no owner, `apkrun adopt` it, switch it to `manual` with `apkrun update authority <package> manual`, update it with `apkrun update <package> --file` V2, and read `updateOwner`. Record whether Android grants ownership in [package-store.md](../../02-design/package-store.md) §6.3 and §18, and the enforcement flag in [guest-components.md](../../02-design/guest-components.md) §14. Check: both log rows have a date, the macOS build, the image build, and a result.
8. **Acceptance (store design step 3, design step 2).** Run the T2 tests on the custom image, and the stock-image test for the warning. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`, `Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Packages/GuestProtocol/Tests/GuestProtocolTests/`): the authority mapping of §2.1–§2.4 for every UI choice and every install path. The `claimsUpdateOwnership` table. The `setUpdatePolicy` rules and refusals. The `setUpdateAuthority` rules for every `AuthorityChoice` from every authority. The Store Agent argument rule for `request_update_ownership` ([guest-protocol.md](../../02-design/guest-protocol.md) §16).
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`, `Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): a counting fake provider gets no call for a `manual` package from the startup check, the timer, `apkrun update`, or `checkForUpdates`. `setUpdateAuthority` with a fake channel: the relinquish order, the post-boot task, `FAILED_PRECONDITION`. The `setUpdatePolicy` write order with a crash between the two writes. CLI goldens for `apkrun update policy` and `apkrun update authority`.
- **T2** (`Tests/IntegrationTests/StoreTests/`, `AndroidCustom`, and `AndroidStock` for the warning): HelloUpdate installed and updated by APKRun reports `updateOwner == io.apkrun.store`. OtherInstaller's session ends with `STATUS_PENDING_USER_ACTION`, and HelloUpdate keeps versionCode 1. After `apkrun update authority <package> external`, the owner is cleared. On the stock image, `updateOwner` is empty and `store.ownership` warns. The owner-less verification of step 7.
- **T3**: none.

### Acceptance criteria

- [ ] On the custom image, HelloUpdate installed by APKRun with authority `apkrun` reports `updateOwner == io.apkrun.store`, after the first install and after an update.
- [ ] The OtherInstaller fixture cannot update HelloUpdate without user action: its session ends with `STATUS_PENDING_USER_ACTION`, and HelloUpdate stays at versionCode 1.
- [ ] Every install of an `apkrun` or `manual` package (first install, reinstall, update) requests update ownership when the channel has `store.ownership.v1`.
- [ ] No install of a `googlePlay` or `external` package requests ownership. After the authority of a managed package is switched to `external`, Android reports no owner.
- [ ] `updateAuthority` and `android.updateOwner` are in `metadata.json`, and `apkrun info` shows the authority.
- [ ] Switching a package to Manual stops all provider checks (T1, counting fake provider).
- [ ] `setUpdatePolicy` follows §2.3: Automatic and Notify only need a provider, `googlePlay` and `external` refuse every choice, and a crash between the two writes never leaves automatic updates on.
- [ ] `apkrun update authority` switches a package between `apkrun`, `manual`, and `external`. A move to `external` relinquishes ownership before the record write, as a post-boot task when the runtime is stopped. A move to `apkrun` without a kept provider fails with `update.providerNotConfigured`, and a `googlePlay` package refuses every change.
- [ ] On the stock image, updates work without ownership, and health reports `store.ownership` as a warning.
- [ ] The owner-less grant and the enforcement flag are recorded in [package-store.md](../../02-design/package-store.md) §6.3 and §18, and in [guest-components.md](../../02-design/guest-components.md) §14.

### Notes

- **Record:** the owner-less grant (step 7) and the enforcement flag (step 1). If Android does not grant ownership on an update, owner-less `manual` packages keep the `store.ownership` warning, and the working default of [guest-components.md](../../02-design/guest-components.md) §13 applies.
- A crash between `RelinquishUpdateOwnership` and the record write leaves the old authority with no owner. That state is safe: the next reconcile shows `store.ownership`, and the next install requests ownership again ([package-store.md](../../02-design/package-store.md) §6.3). The T1 crash test covers it.
- In M6, only `apkrun update authority` and `adoptPackage` set `external`. Nothing sets `googlePlay` before #097.
- A file update of an `external` package asks the user to switch to `manual` first (§2.1). On the command line that switch is `apkrun update authority <package> manual`. A declined switch shows the `external` variant of `update.authorityDoesNotAllowUpdates` ([error-catalog.md](../../03-reference/error-catalog.md) §11).
- A provider stays in the record when a package is switched to Manual, so switching back restores it (§2.3).
- **Pitfall:** `STATUS_PENDING_USER_ACTION` alone does not show that enforcement works. The version must also stay unchanged, and the check must run with the enforcement flag on.
- **Pitfall:** the Store Agent reaches `relinquishUpdateOwnership` and the enforcement flag through `SystemServices`. On a new Android base, a missing method fails only `store.ownership.v1` ([guest-components.md](../../02-design/guest-components.md) §6.2, R-18).

---

## #040 Gentle updates

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #039 |
| Gate | G7 |
| Requirements | FR-UPD-07 |
| Design | [update-system.md](../../02-design/update-system.md) §3.1, §7, §9, §10, §11.1, §11.3, §14, §15 #040, §16, §17; [package-store.md](../../02-design/package-store.md) §5.3, §7.2; [guest-protocol.md](../../02-design/guest-protocol.md) §5.3, §11.1, §16; [guest-components.md](../../02-design/guest-components.md) §5, §8.2, §11, §14; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §5.1, §7.1; [runtime-api.md](../../03-reference/runtime-api.md) §4.7, §9.2; [cli.md](../../02-design/cli.md) §4.3; [../../02-design/host-ui.md](../../02-design/host-ui.md) §11; [error-catalog.md](../../03-reference/error-catalog.md) §11 |
| Modules / paths | `Packages/UpdateCore/` (`GentleUpdateGate`, the evaluation triggers, the install queue, the 7-day notice), `Packages/RuntimeHost/` (the full `UpdateRuntimeAccess`), `Packages/RuntimeCore/` (`SessionRegistry` interplay), `Packages/GuestProtocol/` (op 110, `store.constraints.v1`), `Guest/APKRunStore/` (`ConstraintsService`), `Apps/APKRun/` (the "Quit ‹App› and update now?" alert), `CLI/apkrun/Commands/Update.swift` (`--now`), `Tests/IntegrationTests/UpdateTests/`, `Tests/AcceptanceTests/G7GentleUpdate` |
| Risks / questions | The foreground-service behavior of `GENTLE_UPDATE` ([update-system.md](../../02-design/update-system.md) §17) and the `checkInstallConstraints` caller rule ([guest-components.md](../../02-design/guest-components.md) §13), recorded in [../open-questions.md](../open-questions.md) §4 |

### Goal

An update is never installed while its app is in use. A staged update waits while the app has a window, runs in the background with `keepRunning`, or was closed less than 15 s ago. It installs within 30 s after the app quits, without user action. A click on the app during the install has one defined result. The outcome is the same on every image kind (#040, FR-UPD-07). G7 passes.

### Scope

- `CheckInstallConstraints` (op 110), the capability `store.constraints.v1`, and `ConstraintsService` in the Store Agent ([guest-protocol.md](../../02-design/guest-protocol.md) §11.1, [guest-components.md](../../02-design/guest-components.md) §8.2).
- The full `UpdateRuntimeAccess` in RuntimeHost (§7.5), except `healthCheckLaunch` (#043).
- `GentleUpdateGate` with GU1–GU7 (§7.1) and its evaluation triggers (§7.2).
- The session and install interplay of §7.2 in `SessionRegistry`.
- One install at a time, with user-initiated installs first, then the longest waiting (§7.2).
- User-initiated updates (§7.3): `updatePackage` with `closeRunningApp`, `apkrun update <package> --now`, and the "Quit ‹App› and update now?" question in APKRun.app.
- The 7-day notification (§7.4) and the waiting reason in `listUpdates`.
- A log entry for each gate evaluation with the condition that was false, and the `updates.waiting` health check (`update.stagedTooLong`, §14).
- The foreground-service and caller-rule verifications (§7.1).
- The G7 check.

Out of scope:

- The scheduler and its triggers (#074). G7 here uses `apkrun update` as the check trigger (see Notes).
- The health check after the install beyond H1, and rollback (#043). GU7 is in the gate from this task on, and it is always open for `versionOnly`, which is the only level until #043.
- `updates.startRuntimeToInstall` (§3.5, #074).
- The Home and app-page buttons (#078, #079). The notification action and the CLI are the user-initiated entry points in M6.

### Deliverables

- Op 110 and `store.constraints.v1` in `Packages/GuestProtocol/`, and `ConstraintsService` in `Guest/APKRunStore/`.
- `UpdateRuntimeAccess` in `Packages/RuntimeHost/` with `runtimeEvents`, `lastSessionEnd`, `androidAllowsGentleInstall` (op 110 on custom images, `ListTasks` on stock images), `endSessions`, and `reopen`.
- `GentleUpdateGate`, the evaluation triggers, and the install queue in `Packages/UpdateCore/`.
- The §7.2 rules in `SessionRegistry` (`Packages/RuntimeCore/`).
- `apkrun update <package> --now` and the waiting line, with golden output.
- The "Quit ‹App› and update now?" alert in APKRun.app for the **Update Now** notification action.
- The 7-day notification and its text.
- The T2 tests in `Tests/IntegrationTests/UpdateTests/` and the G7 check in `Tests/AcceptanceTests/G7GentleUpdate`.
- The results of the verifications in §7.1 and [guest-components.md](../../02-design/guest-components.md) §14.
- The `errors.json` entries for the waiting reasons and `update.cancelled`.

### Implementation steps

The design steps are §15 #040, steps 1–5. [package-store.md](../../02-design/package-store.md) §15 has no #040 steps. Design step 1 is split into steps 1–3 below.

1. **`CheckInstallConstraints` (design step 1).** Add op 110 and `store.constraints.v1`. `ConstraintsService` builds `InstallConstraints` (API 34) from the request flags, calls `PackageInstaller.checkInstallConstraints`, and answers when the callback arrives, or with `TIMEOUT` after 10 s ([guest-protocol.md](../../02-design/guest-protocol.md) §12.1). It never waits for the constraints to become true. Check: the T2 protocol test shows `satisfied = false` while HelloUpdate has a visible task and `true` after its tasks are removed.
2. **`UpdateRuntimeAccess` (design step 1).** Complete the #038 implementation with the members of §7.5 except `healthCheckLaunch`. `hasActiveUse` covers GU2 (any session that is not `ended`, including `backgrounded`) and GU3 (a `backgroundTask` activity for the package, [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §5.1). `androidAllowsGentleInstall` uses op 110 with `GENTLE_UPDATE` and `app_not_foreground_required` on custom images, and the Guest Agent's `ListTasks` on stock images. A timeout counts as closed. Check: the T1 tests with a fake `SessionRegistry` and fake agents cover each member.
3. **`GentleUpdateGate` (design step 1).** Implement GU1–GU7 (§7.1). Evaluate the gate at stage, 15 s after a session ends, when a keep-running task ends, when the runtime becomes `ready`, and every 10 minutes while updates are staged and the runtime is ready (§7.2). When it opens, call `installStaged(id, enableRollback: true)` under a `storeOperation` assertion. Install one package at a time: user-initiated first, then the longest waiting. `listUpdates` reports the first false condition as the waiting reason, and each evaluation is logged in the `install` category (§14). Add the `updates.waiting` health check. Check: the T1 tests with a manual clock and fakes cover every condition alone, the triggers, and the queue order.
4. **Session and install interplay (design step 2).** In `SessionRegistry`, `openSession` for a package with a store transaction checks the step. Before `guestCommitRequested`, the install is cancelled with `AbandonInstall`, the update goes back to `staged`, and the session opens at once with the old version. After it, the session reports `waitingForPackage` with "Updating ‹App›…" for up to 30 s, then launches the new version ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1). Its first frame counts as H4. Check: the T1 race tests pass for an `openSession` at each transaction step, and the T2 test passes with a click before and after the commit.
5. **User-initiated updates and the 7-day notice (design step 3).** `updatePackage` follows §7.3: a stopped runtime is started, GU5 is not required, and `closeRunningApp = true` ends the session with `.updating` and reopens the app after a successful update. `closeRunningApp = false` with the app open waits in the operation. The CLI never asks: without `--now`, it prints "will update when ‹App› quits" and returns while the operation waits in apkrund. `--now` sets `closeRunningApp = true`. A reopen of the app before the commit request cancels the install, sends the update back to `staged`, and leaves the operation waiting, also after `--now` (§7.3). The **Update Now** notification action shows the §7.3 question in APKRun.app when the app is open. After 7 days staged without the gate opening, post the §7.4 notification once. Check: the CLI goldens and the T1 tests for the 7-day notice with a manual clock pass.
6. **Verifications (design step 4).** On the custom image, start a foreground service in HelloUpdate V1 (the `fgs` extra, see Notes), close its window, and call op 110 with `GENTLE_UPDATE`. Record whether the package is reported as busy. If it is not, add the `ListTasks` rule and a process-importance query to GU5 on custom images, and update §7.1. Also record the exact caller rule of `checkInstallConstraints`. Write both results in §7.1 and in [guest-components.md](../../02-design/guest-components.md) §14. Check: both rows have a date, the macOS build, the image build, and a result.
7. **Acceptance (design step 5).** Run the T2 acceptance tests on the custom image. Check: every acceptance criterion is checked.
8. **G7 check (gate G7).** Add `Tests/AcceptanceTests/G7GentleUpdate` for `scripts/run-gate.sh G7` ([../test-strategy.md](../test-strategy.md) §5), with the condition list of the milestone exit criteria. The check is triggered by `apkrun update`. Check: the gate passes on the reference Mac with a clean build from `main`.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`): the waiting-reason mapping, and the install queue order.
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`, `Packages/RuntimeCore/Tests/RuntimeCoreSystemTests/`): GU1–GU7 each false alone with fakes and a manual clock; every evaluation trigger; the §7.2 races for an `openSession` at each transaction step; `closeRunningApp` true and false; the 7-day notification, posted once. CLI goldens for `apkrun update <package>` with and without `--now`.
- **T2** (`Tests/IntegrationTests/UpdateTests/`, `AndroidCustom`, and `AndroidStock` for the `ListTasks` path): the acceptance of §15 #040 step 5. `CheckInstallConstraints` false with a visible task and true after. The foreground-service case recorded.
- **T3** (`Tests/AcceptanceTests/G7GentleUpdate`): the G7 check, nightly. The v0.3 checklist item C03-2: the update notifications, including the 7-day notification, read correctly ([../test-strategy.md](../test-strategy.md) §8.4).

### Acceptance criteria

- [ ] HelloUpdate V1 is open in a window while V2 is found and staged. No install happens while the window is open (checked for 10 minutes in the T2 test).
- [ ] No install happens while V1 runs with `keepRunning` after its window closed, nor within 15 s after its session ended.
- [ ] Within 30 s after V1 quits, V2 is installed without user action. Opening the app then shows V2, which logs `data HELLO`.
- [ ] A click on the app during the install gives the §7.2 result: before the commit request, the install is cancelled and V1 opens; after it, the session shows "Updating ‹App›…" and opens V2. Both cases pass on every T2 run.
- [ ] On the custom image, GU5 uses `CheckInstallConstraints` with `GENTLE_UPDATE`. On the stock image, it uses `ListTasks`.
- [ ] `apkrun update <package>` with the app open prints "will update when ‹App› quits" and returns, and V2 installs after the app quits. With `--now`, the session ends, V2 is installed, and the app reopens with V2. A reopen before the commit request leaves the operation waiting (§7.3).
- [ ] An update staged for 7 days posts one notification with **Update Now**, and APKRun never closes an app on its own.
- [ ] The foreground-service behavior and the caller rule are recorded in §7.1 and [guest-components.md](../../02-design/guest-components.md) §14.
- [ ] **G7 passes**: `scripts/run-gate.sh G7` passes on the reference Mac with a clean build from `main`.

### Notes

- **Record:** the foreground-service case and the caller rule (step 6).
- G7 in [../test-strategy.md](../test-strategy.md) §4.9 says V2 is found "in the background". The scheduler comes in #074, which depends on this task. Here, the G7 check starts the check with `apkrun update` while V1 is open, and asserts the rest. #074 adds the scheduled trigger to the check.
- Add the intent extra `fgs` to HelloUpdate V1 for step 6: it starts a `mediaPlayback` foreground service and logs `fgs started` ([../test-strategy.md](../test-strategy.md) §4.2).
- The T2 test sets `window.closeBehavior = keepRunning` with `updatePackageSettings` from the test harness, because the settings UI comes in #079.
- The `--now` rule is §7.3: `--now` is **Update Now** without the question. Without `--now`, the CLI prints "will update when ‹App› quits" and returns, and the operation keeps waiting in apkrund until the app quits or the operation is cancelled. A reopen before the commit request sends the update back to `staged`, and the operation waits again ([cli.md](../../02-design/cli.md) §4.3, [runtime-api.md](../../03-reference/runtime-api.md) §4.7, §9.2).
- **Pitfall:** GU5 is only a hint. The host conditions GU2–GU4 and the §7.2 rule make the outcome deterministic. Do not skip GU2 because op 110 said `satisfied`.
- **Pitfall:** the gate is re-evaluated before each install. A result from op 110 is never cached.

---

## #041 Package and signature verification

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #038, #073 |
| Requirements | FR-UPD-04, FR-UPD-05, FR-UPD-14, NFR-SEC-04 |
| Design | [update-system.md](../../02-design/update-system.md) §5, §6, §9, §10.2, §13, §15 #041, §16; [package-store.md](../../02-design/package-store.md) §2.2, §4.5, §4.6, §7.1, §15 #041, §16; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §5; [../../05-development/build-system.md](../../05-development/build-system.md) §8.1; [error-catalog.md](../../03-reference/error-catalog.md) §10, §11 |
| Modules / paths | `Packages/APKStoreCore/` (signer-set comparison with lineage capabilities, `VersionCode` and set-digest comparison), `Packages/UpdateCore/` (`UpdateValidator` V0–V6, `ValidationReport`), `Tests/Fixtures/AndroidApps/HelloUpdate/` (rotation variants, corrupted V2), `scripts/build-fixtures.sh`, `Packages/UpdateCore/Tests/UpdateCoreTests/`, `Packages/APKStoreCore/Tests/APKStoreCoreTests/` |
| Risks / questions | R-15. None open for this task in [../open-questions.md](../open-questions.md) |

### Goal

Every update, from a provider or from a user's file, passes the full host validation before it is staged: the intrinsic checks and rules V0–V6. A wrong package, a wrong signer, a downgrade, a corrupted APK, a changed file, and provider metadata that disagrees with the APK are all refused with a reason the user can read. Key rotation is accepted exactly where Android accepts it. No setting or build turns a rule off (#041, FR-UPD-04, NFR-SEC-04).

### Scope

- The store primitives of [package-store.md](../../02-design/package-store.md) §15 #041 step 1: signer-set comparison with lineage capabilities (`INSTALLED_DATA` for updates, `ROLLBACK` for undoing a rotation), `VersionCode` comparison, and set-digest comparison.
- `UpdateValidator` with V0–V6 in table order (§6), replacing the #038 subset. V3 with all four cases and the `.certificateOnly` rule. V4 re-hashes the stored files. V5 compares the provider-declared package, versionCode, and signer with the APK. V6 checks the skipped versions.
- `ValidationReport`: each check with its inputs and verdict, saved with the staged set and shown under "Details" in the history (§10.2). The UI records: new permissions, a target SDK change, and a size change larger than 50 %.
- The "Update refused" notification when V3 or V5 fails (§9).
- The HelloUpdate rotation variants and the corrupted V2 ([../../05-development/build-system.md](../../05-development/build-system.md) §8.1).
- The R-15 record together with #073.

Out of scope:

- The intrinsic checks themselves (#073). V0 calls them.
- The download-time hash check (`update.hashMismatch`, #038). V4 is the second check on the stored files.
- Split sets in an update (#042). The rules run on the base APK and the set as a whole, and the split cases are tested there.
- Adding versions to `skippedVersions` (#043). V6 reads the list, which is empty until then.

### Deliverables

- The signer-set, lineage, `VersionCode`, and set-digest primitives in `Packages/APKStoreCore/`.
- `UpdateValidator` with V0–V6 and `ValidationReport` in `Packages/UpdateCore/`.
- `staged/validation.json` with the report ([package-store.md](../../02-design/package-store.md) §3.1), and the "Details" field of the history entry.
- The "Update refused" notification text for V3 and V5.
- The HelloUpdate rotation variants and the corrupted V2, built by `scripts/build-fixtures.sh`.
- The `update.validation` causes for every `ValidationFailure` case in `errors.json`.
- The R-15 result in [../risks.md](../risks.md).

### Implementation steps

The design steps are §15 #041, steps 1–2, and [package-store.md](../../02-design/package-store.md) §15 #041, steps 1–2. They are merged in this order: the store primitives first, then the fixtures, the validator, the report, and the shared acceptance.

1. **Store primitives (store design step 1).** Add signer-set comparison: equal sets; a single-signer rotation where the candidate's lineage holds the installed signer with `INSTALLED_DATA`; a rotation being undone where the installed lineage holds the candidate's signer with `ROLLBACK`; everything else refused. Multiple-signer sets must be equal. Add `VersionCode` comparison and set-digest comparison. Check: the T0 tests over hand-built signer sets and lineages pass for every case.
2. **Fixtures (design step 2).** Add the HelloUpdate rotation variants to `scripts/build-fixtures.sh`: V2 signed with lineage A → B with and without `INSTALLED_DATA`, and a rotation back to A with and without `ROLLBACK`, signed with the pinned `apksigner rotate` and `sign --lineage`. Add the corrupted V2, with one flipped byte in `classes.dex`. Check: `scripts/check-fixtures.sh` reproduces the same bytes, and the host verifier reports the lineage flags of each variant.
3. **`UpdateValidator` (design step 1).** Run V0–V6 in table order and stop at the first failure. The rules not run are reported as "not run". V2 compares with Android's `longVersionCode` from the last reconcile. V3 takes *S* from Android and *S′* from the host verifier. When the host verifier ran at the `.certificateOnly` level, V3 compares certificate digests, and Android stays the final check. V4 hashes the stored files again against the declared digests. V5 compares each field the provider declared. V6 refuses a versionCode in `skippedVersions` unless the user chose it. A failure ends with `completed(.skipped(.validationFailed(reason)))`, deletes the ticket, and saves the cursor (§5). Check: the T0 matrix of step 5 passes.
4. **Report and notification (design step 1).** Build the `ValidationReport` with each rule, its inputs, and its verdict, and the three UI records. Save it in `staged/validation.json` and in the history entry's "Details". Post "Update refused" for V3 and V5 failures, always on (§9). Check: the T1 test reads the report back after a restart, and a fake UI client receives the notification.
5. **Acceptance (design step 2, store design step 2).** Run the T0 matrix over the fixtures, and record R-15. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`, `Packages/APKStoreCore/Tests/APKStoreCoreTests/`): rules V0–V6 with the fixtures of [../test-strategy.md](../test-strategy.md) §4.3 against a scripted installed state. Valid upgrade (V1 → V2), wrong package (HelloText), wrong signer (V2-other-signer), downgrade (V1 over V2), same version (`notNewer`), corrupted V2 (`invalidSignature` from V0), rotated with `INSTALLED_DATA` (accepted), rotated without it (`lineageMissingCapability`), rotation undone with and without `ROLLBACK`, a stored file changed after download (`providerHashMismatch`), provider metadata that disagrees on package, versionCode, or signer (`providerMetadataMismatch`), and a skipped version (`skippedVersion`). The signer-set primitives. The "not run" entries of the report.
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`): the report saved in `staged/` and read back after a restart; the "Update refused" notification through a fake UI client. Not in the matrix.
- **T2**: none. The #038 T2 tests keep running with the full validator.
- **T3**: none.

### Acceptance criteria

- [ ] HelloUpdate V2 over V1 passes V0–V6.
- [ ] A candidate with another package ID is refused with `packageMismatch`.
- [ ] V2-other-signer is refused with `signerMismatch`. A rotation without `INSTALLED_DATA` is refused with `lineageMissingCapability`, and one with it is accepted and recorded in the history.
- [ ] A lower versionCode is refused with `downgrade`, always. No flag, setting, or build accepts it (FR-UPD-05).
- [ ] The corrupted V2 is refused with `invalidSignature`.
- [ ] A stored file whose SHA-256 differs from the provider's declared digest is refused with `providerHashMismatch`.
- [ ] ABI and SDK mismatches are refused by V0 with their intrinsic-check reasons.
- [ ] Provider metadata that disagrees with the APK is refused with `providerMetadataMismatch`. The values inside the APK decide (FR-UPD-14).
- [ ] The history of every validated update has a `ValidationReport` with each rule, its inputs, and its verdict.
- [ ] No setting, environment variable, test hook, or build type disables a rule (NFR-SEC-04). The Release binary checks of [../test-strategy.md](../test-strategy.md) §3.3 find no hook that skips a rule.

### Notes

- **Record:** the R-15 result in [../risks.md](../risks.md), together with #073: which install floors the host checks catch, and the fixture that shows each one.
- Store the report as JSON in `staged/validation.json` (§6, [package-store.md](../../02-design/package-store.md) §3.1), so that APKStoreCore needs no UpdateCore type. The store keeps it with the staged set and does not include it in `setDigest`.
- For case 3 of V3, the installed lineage and its `ROLLBACK` flag are needed. `artifact.json` keeps the lineage digests only ([package-store.md](../../02-design/package-store.md) §2.2). This task gets the flags by running the host verifier again on `current/`.
- The design says "Reject downgrade by default". APKRun refuses a downgrade always (FR-UPD-05, §6). Only the binary rollback of #043 installs an older version.
- **Pitfall:** do not compare signers by certificate subject or by key alone. Compare the SHA-256 of the certificate DER, as Android does.
- **Pitfall:** V5 only refuses. A provider value never replaces a value from the APK.

---

## #042 Split APK installation

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #041, #073 |
| Requirements | FR-PKG-05 |
| Design | [package-store.md](../../02-design/package-store.md) §2.2, §4.4, §4.6, §6.1, §6.2, §7.2, §15 #042, §16, §17, §18; [guest-protocol.md](../../02-design/guest-protocol.md) §11.3; [guest-components.md](../../02-design/guest-components.md) §8.2; [update-system.md](../../02-design/update-system.md) §6; [../../05-development/build-system.md](../../05-development/build-system.md) §8.1 |
| Modules / paths | `Packages/APKStoreCore/` (split sets in `firstInstall`, `reinstall`, and `update` on both channels), `Guest/APKRunStore/` (`InstallService` with several artifacts), `Tests/Fixtures/AndroidApps/HelloSplit/`, `Tests/IntegrationTests/StoreTests/` |
| Risks / questions | The density split choice ([package-store.md](../../02-design/package-store.md) §17), recorded in [../open-questions.md](../open-questions.md) §4 |

### Goal

A split set (a base APK and several split APKs) installs, updates, and reinstalls through one `PackageInstaller` session on both channels. HelloSplit, imported from `.apks`, installs and launches. Its native library loads, and its Japanese string shows when Android's language is Japanese (#042, FR-PKG-05).

### Scope

- Split sets on the ADB channel: all files of the set in one `adb install-multiple -r --no-streaming` call ([package-store.md](../../02-design/package-store.md) §6.2).
- Split sets on the Store Agent channel: one `BeginInstall` with one `ArtifactSpec` per file, one artifact stream per file into the same session, then one `CommitInstall` ([guest-protocol.md](../../02-design/guest-protocol.md) §11.3).
- Split sets in `firstInstall`, `reinstall`, and `update`, including the slot layout of `current/`, `previous/`, and `staged/` with several files.
- HelloSplit's runtime behavior: `native ok` from the native library and `string <locale>` from the activity.
- The density-choice record.

Out of scope:

- Split selection and the container formats (#073).
- Locale sync from macOS to Android (#085). The T2 test sets the guest locale directly.
- On-demand feature splits, which need Google Play (§4.4).
- Adding a split to an installed package on its own (`MODE_INHERIT_EXISTING`). Every install sends the full set.

### Deliverables

- Split-set installs on both channels in `Packages/APKStoreCore/`.
- `InstallService` changes in `Guest/APKRunStore/`, if the #036 version handles only one artifact.
- HelloSplit with the native library and the Japanese string, built by `scripts/build-fixtures.sh`.
- The T2 split tests in `Tests/IntegrationTests/StoreTests/`.
- The density record in [../open-questions.md](../open-questions.md) and [package-store.md](../../02-design/package-store.md) §18.

### Implementation steps

The design steps are [package-store.md](../../02-design/package-store.md) §15 #042, steps 1–2. Design step 1 is split into steps 2–4 below. Step 1 prepares the fixture.

1. **HelloSplit behavior.** HelloSplit is built with the pinned bundletool from an App Bundle ([../../05-development/build-system.md](../../05-development/build-system.md) §8.1), and #073 uses it for the container fixtures. Make sure its native library is in `config.arm64_v8a` and logs `native ok` when loaded, and that its activity logs `string <locale>` from a string that `config.ja` translates ([../test-strategy.md](../test-strategy.md) §4.2). Check: `scripts/check-fixtures.sh` passes, and the generated `.apks` holds the base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, and the install-time feature split.
2. **ADB channel (design step 1).** Pass every file of the set to one `adb install-multiple -r --no-streaming` call, the base first. Map the result as in [package-store.md](../../02-design/package-store.md) §6.4, including `INSTALL_FAILED_MISSING_SPLIT`. Check: the T1 test with a fake `AdbClient` shows one call with every file.
3. **Store Agent channel (design step 1).** Send one `ArtifactSpec` per file (`base`, `split_config.arm64_v8a`, …) in `BeginInstall`, stream each file into the same session, and commit once. The agent's pre-commit check covers the whole set. Extend `InstallService` if it handles one artifact only. Check: the T1 test with a fake channel shows one session with every artifact, and a hash mismatch on one split aborts the whole session.
4. **Split sets in updates and reinstalls (design step 1).** `update` and `reinstall` send the full set. `current/`, `previous/`, and `staged/` hold several files, and `setDigest` covers all of them. V0 checks the split rules on an update. Check: the T1 tests with a fake channel for an update and a reinstall of a split set pass.
5. **Acceptance (design step 2).** Run the T2 tests on both image kinds. Set the guest locale to `ja-JP` through `AdbClient` in developer mode, launch HelloSplit, and read its log. Check: every acceptance criterion is checked.
6. **Density record (design step 2).** Record the density bucket that `SplitSelector` picked for HelloSplit, and whether the app looks right in its window. Write it in [../open-questions.md](../open-questions.md) and [package-store.md](../../02-design/package-store.md) §18. Check: the log row has a date, the macOS build, the image build, and a result.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`): split selection over HelloSplit's `.apks` (shared with #073), and the `ArtifactSpec` list for a set.
- **T1** (`Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): one `install-multiple` call with a fake `AdbClient`; one Store Agent session with several artifacts through a fake channel; update and reinstall of a split set. Not in the matrix.
- **T2** (`Tests/IntegrationTests/StoreTests/`, `AndroidStock` and `AndroidCustom`): HelloSplit from `.apks` installs and launches, logs `native ok`, and logs `string` with the Japanese text when the guest locale is `ja-JP`. `QueryPackage` or `GetPackageMetadata` lists the installed splits.
- **T3**: none. The check with macOS set to Japanese needs the locale sync of #085, so it is the v0.5 checklist item C05-9 ([../test-strategy.md](../test-strategy.md) §8.6), made in #085.

### Acceptance criteria

- [ ] HelloSplit (base, `config.arm64_v8a`, `config.xhdpi`, `config.ja`, an install-time feature split) imported from `.apks` installs and launches on both image kinds.
- [ ] The set is installed in one session: one `install-multiple` call on the stock image, one `BeginInstall` and one `CommitInstall` on the custom image.
- [ ] `current/` holds every file of the set, and Android lists the same splits.
- [ ] HelloSplit's native library loads (`native ok`), and with the guest locale set to `ja-JP`, it logs its Japanese string.
- [ ] An update and a reinstall of a split set send the full set in one session.
- [ ] The density choice is recorded in [../open-questions.md](../open-questions.md) and [package-store.md](../../02-design/package-store.md) §18.

### Notes

- **Record:** the density choice (step 6).
- This task sets the guest locale directly ([package-store.md](../../02-design/package-store.md) §15 #042). Do not wait for #085: macOS-to-Android locale sync is built there.
- **Pitfall:** the base must be in the same session as its splits. Installing the splits after the base in a second session gives `INSTALL_FAILED_MISSING_SPLIT` on the first commit.
- **Pitfall:** `setDigest` sorts by file name. Two sets with the same files in another order are the same install.

---

## #043 Update rollback

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #041, #042 |
| Requirements | FR-UPD-10, FR-UPD-11 |
| Design | [update-system.md](../../02-design/update-system.md) §7.2, §7.5, §8, §9, §10, §11.1, §11.3, §13, §14, §15 #043, §16, §17; [package-store.md](../../02-design/package-store.md) §5.2, §5.5, §6.1, §7.2, §7.3, §11.1, §12, §15 #043, §16, §17, §18; [guest-protocol.md](../../02-design/guest-protocol.md) §5.3, §11.1, §11.3, §16; [guest-components.md](../../02-design/guest-components.md) §5, §8.2, §11, §14; [../../01-architecture/state-machines.md](../../01-architecture/state-machines.md) §6; [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md) §3; [package-metadata-json.md](../../03-reference/package-metadata-json.md) §3; [runtime-api.md](../../03-reference/runtime-api.md) §8.4, §9; [cli.md](../../02-design/cli.md) §4.2 (`rollback`), §4.3; [error-catalog.md](../../03-reference/error-catalog.md) §10, §11 |
| Modules / paths | `Packages/UpdateCore/` (`UpdateHealthChecker`, rollback policy, skipped versions), `Packages/RuntimeHost/` (`healthCheckLaunch`), `Packages/APKStoreCore/` (`enable_rollback`, the `rollback` transaction and recovery, the three mechanisms), `Packages/GuestProtocol/` (op 108, `store.rollback.v1`), `Guest/APKRunStore/` (`RollbackService`, `setEnableRollback`), `Apps/APKRun/` (rollback notification actions and the data-loss confirmation), `CLI/apkrun/Commands/` (`rollback`, `update skip`, `update unskip`), `Tests/IntegrationTests/UpdateTests/` |
| Risks / questions | R-18. The `TEST_MANAGE_ROLLBACKS` item ([package-store.md](../../02-design/package-store.md) §17, [guest-components.md](../../02-design/guest-components.md) §13), recorded in [../open-questions.md](../open-questions.md) §4 |

### Goal

After every update, APKRun checks that the new version works: Android reports it, it launches, its process stays alive, and it draws a frame. A broken update goes back to the previous APK set without the user doing anything, and the version is not installed again. Every rollback message says that app data is not rolled back (#043, FR-UPD-10, FR-UPD-11).

### Scope

- `enable_rollback` in `InstallRequest`, `RollbackPackage` (op 108), and the capability `store.rollback.v1`. `RollbackService` and `setEnableRollback(true, ROLLBACK_DATA_POLICY_RETAIN)` in the Store Agent.
- The store's `rollback` transaction with its recovery rows and `APKRUN_STORE_FAULT=rollback:<step>` hooks, and the three mechanisms of [package-store.md](../../02-design/package-store.md) §7.3: RollbackManager on custom images, `adb install-multiple -r -d` on debuggable stock images (`.downgradeReinstall`), and the confirmed data-loss fallback.
- `UpdateHealthChecker` with H1–H4, the three levels, and the 90 s budget (§8.1), replacing the H1-only check of #038.
- `healthCheckLaunch` in RuntimeHost: a DisplayPool lease for `SessionID.system(.updateHealthCheck(package))`, no force-stop, and a user session that takes over H2–H4 (§8.2).
- The outcomes of §8.3 with `update.autoRollback` and `update.healthCheckLaunch`, skipped versions (§8.4), and user-initiated rollback (§8.5).
- The rollback notifications with their actions (§9), and the data-loss confirmation in APKRun.app.
- `apkrun rollback <package> [--allow-data-loss] [--yes]`, `apkrun update skip <package> <versionCode>`, and `apkrun update unskip <package> <versionCode>` ([cli.md](../../02-design/cli.md) §4.2, §4.3).
- The markers `UPDATE_HEALTH_END` and `UPDATE_ROLLBACK_END`, and the `updates.failed` health check (§14).
- The `TEST_MANAGE_ROLLBACKS` verification on the custom `user` and `userdebug` images.

Out of scope:

- "Roll Back to…", `update.autoRollback`, `update.healthCheckLaunch`, and "Try Again" in the package settings (#079). In M6, the settings are changed with `updatePackageSettings`, and "Try Again" is `apkrun update unskip`.
- Data rollback (`ROLLBACK_DATA_POLICY_RESTORE`, post-v1).
- Repair of a `broken` package (#076). This task sets the state and shows **Repair**.

### Deliverables

- Op 108, `store.rollback.v1`, and `enable_rollback` in `Packages/GuestProtocol/` (Swift and Kotlin).
- `RollbackService` and `setEnableRollback` in `Guest/APKRunStore/`.
- The `rollback` transaction, its recovery rows, and the three mechanisms in `Packages/APKStoreCore/`.
- `UpdateHealthChecker`, the rollback policy, and `skipVersion` and `unskipVersion` in `Packages/UpdateCore/`.
- `healthCheckLaunch` in `Packages/RuntimeHost/`.
- The rollback notifications and the data-loss confirmation in APKRun.app.
- `apkrun rollback`, `apkrun update skip`, and `apkrun update unskip`, with golden output.
- The T2 tests in `Tests/IntegrationTests/UpdateTests/`.
- The verification result in [package-store.md](../../02-design/package-store.md) §7.3 and §18, [guest-components.md](../../02-design/guest-components.md) §14, and R-18 in [../risks.md](../risks.md).
- The `errors.json` entries for `update.healthCheckFailed`, `update.rollbackFailed`, `store.rollbackUnavailable` with its variants, `store.rollbackFailed`, and the `HealthCheckFailure` cases.

### Implementation steps

The design steps are §15 #043, steps 1–3, and [package-store.md](../../02-design/package-store.md) §15 #043, steps 1–4. They are merged in this order: the store mechanisms first (store steps 1–2), then the health checker and the policy (design steps 1–2), the verification (store step 3), and the shared acceptance.

1. **Rollback on the custom image (store design step 1).** Add op 108 and `store.rollback.v1`. `InstallService` calls `setEnableRollback(true, ROLLBACK_DATA_POLICY_RETAIN)` when `enable_rollback` is set, and the store stops masking the field. `RollbackService` accepts a request only when an available rollback matches the package and both version codes, calls `commitRollback`, waits for the status intent, and reports the installed version. It answers `NOT_AVAILABLE` when no rollback matches. Add the `rollback` transaction: `begin` → `guestRollbackRequested` → `guestRolledBack` → `filesRestored` → `metadataWritten` → `commit`, with `current/` moved to `failed/<versionCode>/` and `previous/` promoted to `current/`. Add the recovery rows of [package-store.md](../../02-design/package-store.md) §5.5 and the fault hooks. Check: the T0 recovery rows pass for every step, and the T1 crash-injection run leaves a consistent store.
2. **The other mechanisms (store design step 2).** On a debuggable stock image, the ADB channel rolls back with `adb install-multiple -r -d` and the files of `previous/`. When no rollback is available, `rollback` fails with `rollbackUnavailable`. With `allowDataLoss: true`, which only a confirmed user action sets, the store uninstalls the package and installs `previous/` as a first install. A background rollback never uses this fallback. Check: the T1 tests with a fake channel cover each mechanism, `rollbackUnavailable(.noPreviousSet)`, and a background call that never uninstalls.
3. **`UpdateHealthChecker` (design step 1).** Implement H1–H4 with their timeouts and the 90 s budget. Choose the level: `full` for packages with a launcher activity; `processOnly` when the app never produced a first frame in APKRun; `versionOnly` without a launcher activity or with `update.healthCheckLaunch` off. Add `healthCheckLaunch` in RuntimeHost with a DisplayPool lease for `SessionID.system(.updateHealthCheck(package))` at the package's window geometry (default 480 × 850 pt, backing scale 2). Release the lease afterwards without force-stopping the app. A user session that opens during the check takes over H2–H4 with its own launch. Record the level and each step in the history. Check: the T1 tests with fakes and a manual clock cover each level, each step failing alone, the budget, and a user session taking over.
4. **Policy, skipped versions, user rollback, and notifications (design step 2).** Implement §8.3: pass gives `completed(.updated(from:to:))`; a failure with `update.autoRollback` on gives `rollingBack(.healthCheckFailed(reason))` and `PackageStore.rollback`; with it off, `completed(.keptAfterFailedHealthCheck(reason))` with **Roll Back**. Map the store results to the texts of §8.3: rolled back, `rollbackUnavailable` with **Keep ‹new version›** and **Restore ‹old version› (Erases Data)…**, and `rollbackFailed` with the package `broken` and **Repair**. The restore action asks again in APKRun.app before it calls `rollbackPackage(id, allowDataLoss: true)`. Add rolled-back versions to `skippedVersions`, and add `skipVersion` and `unskipVersion` (§8.4). Add `rollbackPackage` for §8.5, which also skips the rolled-back version. Add `apkrun rollback <package> [--allow-data-loss] [--yes]`, `apkrun update skip <package> <versionCode>`, and `apkrun update unskip <package> <versionCode>`, with goldens. Add the markers and the `updates.failed` health check. Check: the T1 tests for every §8.3 row and the CLI goldens pass.
5. **Verification on the `user` image (store design step 3).** On the custom `user` and `userdebug` images, install HelloUpdate V2 over V1 with `enable_rollback`, and check that `getAvailableRollbacks` lists it and that `commitRollback` restores V1. Record the result in [package-store.md](../../02-design/package-store.md) §7.3 and §18, [guest-components.md](../../02-design/guest-components.md) §14, and R-18. If it fails on `user`, custom images use the confirmed data-loss path as the working default. Check: the log rows have a date, the macOS build, the image build, and a result.
6. **Acceptance (design step 3, store design step 4).** Run the T2 tests on both image kinds and the checklist item C03-1. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/APKStoreCore/Tests/APKStoreCoreTests/`, `Packages/UpdateCore/Tests/UpdateCoreTests/`, `Packages/GuestProtocol/Tests/GuestProtocolTests/`): the `rollback` recovery rows with a scripted Android state; the level choice; the §8.3 mapping; the `enable_rollback` argument rules (with `INSTALL_NEW`, and without the capability, give `INVALID_ARGUMENT`).
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`, `Packages/APKStoreCore/Tests/APKStoreCoreSystemTests/`): the health checker levels and timeouts with fakes and a manual clock; crash injection at every `rollback` host step; each rollback mechanism with a fake channel; CLI goldens for `apkrun rollback`, `apkrun update skip`, and `apkrun update unskip`.
- **T2** (`Tests/IntegrationTests/UpdateTests/`, `AndroidStock` and `AndroidCustom`): HelloUpdate V3-broken is installed over V2 by the provider, H3 fails, and the package is rolled back to V2. V3 is in `skippedVersions`, and the file `files/v2.txt` written by V2 is still there. HelloUpdate V4 then installs normally. `RollbackPackage` without an available rollback gives `NOT_AVAILABLE`. The data-loss fallback after confirmation. `apkrun rollback` from V2 to V1.
- **T3** (manual): the v0.3 checklist item C03-1, "the rollback notification and UI say that app data is not rolled back" ([../test-strategy.md](../test-strategy.md) §8.4).

### Acceptance criteria

- [ ] HelloUpdate V3-broken, which crashes 2 s after launch, is installed over V2 by the provider. The health check fails at H3, and the package is rolled back to V2 on both image kinds.
- [ ] The rollback notification, the history entry, and the `apkrun rollback` output say that app data is not rolled back.
- [ ] `previous/` holds the V2 set before V3 is installed, and becomes `current/` after the rollback. The V3 set is in `failed/3/`.
- [ ] The health check runs H1–H4, uses `processOnly` for an app that never drew a frame and `versionOnly` without a launcher activity, and records the level.
- [ ] A file written by V2 before the update is still there after the rollback (`ROLLBACK_DATA_POLICY_RETAIN`).
- [ ] V3 is in `skippedVersions` and is not installed again. HelloUpdate V4 afterwards installs normally. `apkrun update unskip <package> 3` removes V3 from the list, so it can be offered again.
- [ ] Without an available rollback, a background rollback never erases data: the package stays on the new version, and the notification offers **Keep** and **Restore (Erases Data)…**.
- [ ] With `update.autoRollback` off, a failed update is kept, and the notification offers **Roll Back**.
- [ ] `apkrun rollback <package>` restores the previous version and skips the rolled-back one.
- [ ] The `TEST_MANAGE_ROLLBACKS` result on the `user` and `userdebug` images is recorded.

### Notes

- **Record:** the `TEST_MANAGE_ROLLBACKS` result (step 5), in R-18 and the two verification logs.
- The design says "reinstall previous artifacts". The design uses Android's RollbackManager on custom images and a downgrade reinstall on debuggable images. A reinstall after uninstall happens only with the user's confirmation, because it erases data.
- A crash in the data-loss fallback after the uninstall leaves no version installed. Recovery continues with the first install of `previous/`, because the user already confirmed the data loss ([package-store.md](../../02-design/package-store.md) §5.5, the confirmed data-loss row).
- `apkrun update history` exists from #037. This task adds the health and rollback details to its entries.
- A skipped version is offered again after `apkrun update unskip` or the "Try Again" action of #079 (§8.4). `apkrun update <package> --file` with the user's own file also installs it, because V6 accepts a version the user chose.
- **Pitfall:** do not force-stop the app after a health-check launch. A force-stop puts it in Android's stopped state, and its alarms and jobs stop (§8.2).
- **Pitfall:** RollbackManager keeps available rollbacks for about 14 days. A test that waits between the update and the rollback must not depend on the rollback still being there.

---

## #050 DirectProvider

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #037, #041 |
| Requirements | FR-UPD-12 |
| Design | [update-system.md](../../02-design/update-system.md) §3.4, §4.1, §4.4, §5, §6, §11.3, §12, §13, §15 #050, §16; [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §3–§12; [package-metadata-json.md](../../03-reference/package-metadata-json.md) §2.4; [runtime-api.md](../../03-reference/runtime-api.md) §9.2; [cli.md](../../02-design/cli.md) §4.3; [../../05-development/build-system.md](../../05-development/build-system.md) §8.1; [error-catalog.md](../../03-reference/error-catalog.md) §11 |
| Modules / paths | `Packages/UpdateCore/` (`Providers/DirectProvider.swift`, `DirectManifest`, the shared `URLSession`), `docs/03-reference/schemas/direct-provider-manifest.schema.json`, `scripts/dev/update-server.py`, `Tests/Fixtures/update-repos/direct/valid/`, `Tests/Fixtures/update-repos/direct/invalid/`, `CLI/apkrun/` (the `direct:` spec and its alias), `Tests/IntegrationTests/UpdateTests/` |
| Risks / questions | None open for this task in [../open-questions.md](../open-questions.md). The signed manifest is a v1.x candidate (§4.4) |

### Goal

A distributor can publish an APKRun manifest over HTTPS, and APKRun updates the package from it. The manifest lists the package, versionCode, versionName, artifacts, and hashes. The APK's own values decide, and the manifest can only refuse. A local test service updates HelloUpdate V1 to V2 through the Direct path (#050, FR-UPD-12).

### Scope

- `DirectProvider` (§4.4): `check` and `download`. It is the first network provider, so this task creates UpdateCore's shared `URLSession` with the settings of §3.4.
- The `DirectManifest` model with the structural check and the semantic rules D1–D9 ([direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §6), kept in agreement with the published JSON Schema.
- HTTP rules ([direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §5): conditional requests, at most 5 redirects to allowed URLs, a 1 MiB body cap, the cursor, relative artifact URLs, no user info, and the `429`, `503`, other-status, and network error mappings.
- Downloads: hashing while streaming, the declared `size` cap, one retry on a hash mismatch, then `hashMismatch` (§5).
- The candidate mapping ([direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §7), with the manifest inputs of V4 and V5.
- The configuration `{url}` and its checks in `setUpdatePolicy` ([direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §8). The CLI spec `direct:<https-url>` and the alternate flags `--update-provider direct --update-url <url>`.
- `scripts/dev/update-server.py` for Debug builds, with a `--delay <seconds>` option (§15 #050 step 2, [../../05-development/build-system.md](../../05-development/build-system.md) §8.1).
- The Direct fixtures in `Tests/Fixtures/update-repos/direct/`.

Out of scope:

- Signed manifests (v1.x candidate, §4.4).
- The F-Droid and GitHub providers (#051, #052).
- The provider picker in the settings (#079).
- The long fuzz runs of the manifest parser (#091).

### Deliverables

- `DirectProvider` and `DirectManifest` in `Packages/UpdateCore/`, registered in `ProviderRegistry`.
- The model and schema agreement tests, and any fix to `docs/03-reference/schemas/direct-provider-manifest.schema.json` that they show.
- `scripts/dev/update-server.py`: serves the Local fixtures as Direct manifests and the files of `Tests/Fixtures/update-repos/direct/` on `http://127.0.0.1:<port>`, with `--delay`.
- The fixtures `direct/valid/*.json` and `direct/invalid/*.json`: valid (single APK, split set, container), versionCode mismatch, wrong `sha256`, missing `sha256`, `http` URL, relative URL (valid, and one that resolves to `http`), oversized, and wrong package.
- The `direct:` spec in the CLI spec parser of #037, with golden output.
- The T1 and T2 tests.
- The `errors.json` entries for the Direct failures (`update.providerMetadataInvalid` details, `update.providerHTTPStatus`, `update.providerRateLimited`, `update.providerUnreachable`).

### Implementation steps

The design steps are §15 #050, steps 1–3. [package-store.md](../../02-design/package-store.md) §15 has no #050 steps. Design step 1 is split into steps 1–2 below, and step 4 has no design step.

1. **Model and schema (design step 1).** Add the `Codable` model `DirectManifest` and the semantic checks D1–D9 in order. D1–D8 give `providerMetadataInvalid(detail:)` with the field and the rule. D9 gives no candidate, and a `minSdk` above the guest SDK records `noCompatibleArtifact(.sdk)`. Keep the model in agreement with `docs/03-reference/schemas/direct-provider-manifest.schema.json`: every fixture the schema accepts decodes, and every fixture it rejects fails with the expected D-rule. When the two disagree on structure, the schema wins ([direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) header). Check: the T0 schema and model tests pass for every fixture.
2. **HTTP and downloads (design step 1).** Create the shared `URLSession` of §3.4: `waitsForConnectivity`, a 30 s request timeout, the system proxy settings, HTTP/2, at most 4 connections per host, and default ATS. Implement `check` with `If-None-Match` or `If-Modified-Since`, `304` as no candidate, redirects only to allowed URLs and at most 5, the body cap at 1 MiB + 1 byte, and the cursor (the ETag, else `sha256:` + the body's SHA-256). Resolve artifact URLs against the final manifest URL, and refuse user info and non-HTTPS results. Map `429` and `503` with `Retry-After` to `providerRateLimited(retryAfter:)`, other non-2xx statuses to `providerHTTPStatus`, and network failures to `providerUnreachable`. Implement `download` with hashing while streaming, the `size` cap, and the hash retry of §5. A failed check keeps the last good cursor. Check: the T1 tests against `update-server.py` cover each rule.
3. **Local test service (design step 2).** Write `scripts/dev/update-server.py`: it serves `Tests/Fixtures/update-repos/local/` as Direct manifests and the variants of `direct/` on `http://127.0.0.1:<port>`, Debug builds only. `--delay <seconds>` holds every manifest response. Only Debug builds accept `http://127.0.0.1` and `http://localhost` URLs (§12). Check: a Release build refuses a loopback `http` URL in `setUpdatePolicy`.
4. **Configuration and CLI.** Add the `direct:<https-url>` spec to the parser of #037, and map the alternate flags `--update-provider direct --update-url <url>` to it. `setUpdatePolicy` checks the configuration rules before it stores anything. A stored configuration that breaks them makes every check fail with `providerNotConfigured`. Check: the CLI goldens for `apkrun update policy <package> --provider direct:<url>`, `apkrun install <file> --provider direct:<url>`, and the alternate flags on `apkrun install` pass.
5. **Acceptance (design step 3).** Run the T2 test with the local test service. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`): the Direct manifest schema cases of [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §12, and the model and schema agreement over `direct/valid/` and `direct/invalid/`. URL resolution. The candidate mapping.
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`): `DirectProvider` against `update-server.py` on `127.0.0.1` with a fake store: `304`, redirects, the body cap, `429` with `Retry-After`, the cursor. A versionCode mismatch is refused with V5, and a wrong `sha256` ends with `update.hashMismatch` after one retry. CLI goldens.
- **T2** (`Tests/IntegrationTests/UpdateTests/`, `AndroidCustom`): HelloUpdate V1 → V2 through `update-server.py`, with `data HELLO` kept. A versionCode mismatch is refused with V5. A wrong `sha256` is refused while downloading (`update.hashMismatch`).
- **T3**: none.

### Acceptance criteria

- [ ] With HelloUpdate V1 installed and a `direct:` provider pointing to `update-server.py`, V2 is found, downloaded, validated, and installed, and V2 logs `data HELLO`.
- [ ] The manifest holds the package, versionCode, versionName, artifacts, and hashes. The model reads every field of [direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §3, and agrees with the published JSON Schema on every fixture.
- [ ] A manifest whose `versionCode` disagrees with the APK is refused with rule V5 (`providerMetadataMismatch(versionCode)`).
- [ ] A wrong `sha256` is refused while downloading with `update.hashMismatch`, after one retry.
- [ ] Release builds accept only `https` manifest and artifact URLs, after redirects and relative resolution. Debug builds also accept `http://127.0.0.1` and `http://localhost`.
- [ ] Every D-rule failure gives `providerMetadataInvalid` with the field and the rule in its detail, and keeps the last good cursor.
- [ ] `direct:<https-url>` and the alternate flags `--update-provider direct --update-url <url>` attach the same provider.

### Notes

- The Local fixtures are served as Direct manifests ([../../05-development/build-system.md](../../05-development/build-system.md) §8.1), and the variants are in `Tests/Fixtures/update-repos/direct/` ([../test-strategy.md](../test-strategy.md) §4.5). `update-server.py` serves both.
- `--delay <seconds>` holds every manifest response. `update-check-launch` uses 5 s, and the slow-provider test of #074 uses 30 s ([../test-strategy.md](../test-strategy.md) §4.5).
- A wrong `sha256` fails the download with `update.hashMismatch` after one retry (§5). Rule V4 catches only a file that changed after the download, and the #041 T0 matrix covers it.
- The local test service runs in T1 without a VM for the HTTP rules, and in T2 for the install ([direct-provider-manifest.md](../../03-reference/direct-provider-manifest.md) §12).
- **Pitfall:** resolve relative artifact URLs against the final manifest URL after redirects, not against the configured URL.
- **Pitfall:** `signingCertificates` is not a check filter. A rotated signer differs from the installed one, and V3 decides after the download.

---

## #074 Update scheduler

| Field | Value |
|---|---|
| Milestone | M6 (v0.3) |
| Depends on | #037, #040, #050 |
| Requirements | FR-UPD-08, FR-UPD-09, NFR-PERF-07 |
| Design | [update-system.md](../../02-design/update-system.md) §2.2, §3, §7.2, §9, §10, §11.1, §11.3, §14, §15 #074, §16; [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §2.1, §2.4, §7.1; [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.7; [cli.md](../../02-design/cli.md) §3.3, §4.3, §4.6; [../../02-design/diagnostics.md](../../02-design/diagnostics.md) §9; [runtime-api.md](../../03-reference/runtime-api.md) §9; [error-catalog.md](../../03-reference/error-catalog.md) §11, §20.3 |
| Modules / paths | `Packages/UpdateCore/` (`UpdateScheduler`, the network and power rules, `noteLaunched`), `Packages/RuntimeHost/` (the exit rule, the `noteLaunched` call, the §3.5 start), `Packages/RuntimeCore/` (`SessionRegistry` after the reply), `CLI/apkrun/Commands/Update.swift`, `Tests/PerformanceTests/` (`update-check-launch`), `Tests/IntegrationTests/UpdateTests/`, `Tests/AcceptanceTests/G7GentleUpdate` |
| Risks / questions | None open for this task in [../open-questions.md](../open-questions.md) |

### Goal

apkrund checks every `apkrun` package on a schedule, in the background, and never makes a launch wait for a check. The default interval is 6 hours, with jitter, backoff, and network and power rules. A launch triggers a check only after the first frame. apkrund still exits when nothing is due (FR-UPD-08, NFR-PERF-07).

### Scope

- `UpdateScheduler` (§3.2–§3.4): `nextCheckAt` from the interval and a per-cycle jitter of ±10 %, backoff after failures (30 min, 2 h, then the interval), `Retry-After` and reset times, the phases that are not checked, and the replacement of a staged set by a newer candidate.
- The triggers of §3.3: apkrund start, the timer on `ContinuousClock`, Mac wake plus 2 minutes, `noteLaunched`, and the user.
- The resource rules of §3.4: 4 checks in parallel and 2 per host, one background download, `NWPathMonitor` with expensive and constrained paths, Low Power Mode over 50 MiB. They apply to the shared `URLSession` of #050.
- The update mode per package (§2.2) on scheduled checks: `automatic` continues to install, `notifyOnly` stops at `available`, and `manual` is never due (FR-UPD-09).
- The exit-rule term "no work due within the grace period" ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §2.4).
- `noteLaunched` after the `openSession` reply, and the opportunistic check 30 s after the first frame at `utility` priority.
- The settings `updates.checkIntervalHours`, `updates.downloadOnExpensiveNetwork`, `updates.startRuntimeToInstall`, and `updates.notifyInstalled` ([../../03-reference/configuration.md](../../03-reference/configuration.md) §2.7), through `apkrun config`.
- `updates.startRuntimeToInstall` (§3.5).
- The full `apkrun update` output ([cli.md](../../02-design/cli.md) §4.3).
- The `updates.scheduler` and `updates.providers` health checks (§14).
- `update-check-launch` running in the perf harness (NFR-PERF-07).
- The scheduled trigger in the G7 check.

Out of scope:

- The Updates pane of the Settings window ([../../02-design/host-ui.md](../../02-design/host-ui.md) §9.3) and the per-package mode choice on the app page (#079).
- The menu bar update list (#086).
- The "Updated" notification text itself (#037 builds `HostNotifier`). This task only applies `updates.notifyInstalled`.

### Deliverables

- `UpdateScheduler` in `Packages/UpdateCore/`, with the network, power, and concurrency rules.
- The exit-rule query and the `noteLaunched` call in `Packages/RuntimeHost/`.
- The four `updates.*` keys in the configuration store, with `apkrun config get|set`.
- `updates.startRuntimeToInstall` with the AC power and `HIDIdleTime` checks.
- The full `apkrun update` output and exit codes, with golden output.
- `update-check-launch` running in `Tests/PerformanceTests/`, and the up-to-date manifests for the other fixture packages in `scripts/dev/update-server.py` ([../../05-development/build-system.md](../../05-development/build-system.md) §8.1).
- The T2 launch and exit tests in `Tests/IntegrationTests/UpdateTests/`, and the scheduled trigger in `Tests/AcceptanceTests/G7GentleUpdate`.
- The `errors.json` entries for `update.schedulerLate`.

### Implementation steps

The design steps are §15 #074, steps 1–4. [package-store.md](../../02-design/package-store.md) §15 has no #074 steps. Design step 1 is split into steps 1–2 below, design step 3 into steps 4–5, and design step 4 into steps 6–9.

1. **`UpdateScheduler` (design step 1).** Compute `nextCheckAt` per package with the interval and a jitter fixed per package per cycle. Apply the backoff and the provider's `Retry-After` or reset time when it is later. Skip packages in `downloading`, `validating`, `installing`, `healthChecking`, or `rollingBack`, and packages whose authority is not `apkrun`. Keep checking `staged` packages, so a newer candidate replaces the staged set and restarts its 7-day wait. Run the triggers of §3.3 on `ContinuousClock`, with the wake delay of 2 minutes. Apply the resource rules of §3.4. User-initiated checks run first and ignore `nextCheckAt` and backoff. Check: the T1 tests with a manual clock and a fake network path pass.
2. **Exit rule (design step 1).** Give RuntimeHost the query "work due within the grace period" for the exit rule of [../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §2.4. A start by the hourly `StartInterval` runs every due check, then lets apkrund exit. Check: the T1 test of the exit rule with a fake scheduler passes.
3. **`noteLaunched` (design step 2).** `SessionRegistry` calls `UpdateCore.noteLaunched(package)` after it replies to `openSession`, never on the launch path ([../../02-design/runtime-daemon.md](../../02-design/runtime-daemon.md) §7.1). When the package is due, the check starts 30 s after the first frame at `utility` priority. Check: the T1 test shows that `openSession` returns before any UpdateCore call, and the check starts 30 s after the first frame.
4. **Settings (design step 3).** Add `updates.checkIntervalHours` (1, 3, 6, 12, 24, 72, or 168; default 6), `updates.downloadOnExpensiveNetwork` (default off), `updates.startRuntimeToInstall` (default off), and `updates.notifyInstalled` (default off), with the apply rules of [../../03-reference/configuration.md](../../03-reference/configuration.md) §2.7. Changing the interval recomputes every next check time. Turning on expensive-network downloads starts waiting downloads. Check: the T1 tests for each apply rule and the `apkrun config set` goldens pass.
5. **Background install without a running runtime (design step 3).** With `updates.startRuntimeToInstall` on, an update that waited more than 24 h, the Mac on AC power, and at least 15 minutes of `HIDIdleTime`, apkrund boots the runtime headless with `ensureReady(.update)`, installs and health-checks every staged update whose gate is open, and leaves the stop to the idle policy. Check: the T1 tests with fake power and idle sources pass.
6. **`apkrun update` output (design step 4).** `apkrun update` prints one line per `apkrun` package: up to date, available, installed, waiting ("will update when ‹App› quits"), or failed. It exits 2 when some failed ([cli.md](../../02-design/cli.md) §3.3). `--check-only` keeps every run at `available`. Check: the CLI goldens for each line and exit code pass.
7. **`update-check-launch` (design step 4).** Make the scenario run: 10 installed packages get a Direct provider served by `update-server.py --delay 5`, which answers each package other than HelloUpdate with a manifest at its installed versionCode, `apkrun update --check-only` starts the checks, and `warm-launch` runs 30 times while they run ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §9). Check: the scenario reports a p50 difference of at most 50 ms on the reference Mac.
8. **Scheduled trigger in G7 (design step 4).** Extend `Tests/AcceptanceTests/G7GentleUpdate` with a second run in which the scheduler finds V2 instead of `apkrun update`. The provider is attached just before V1 is launched, so the package is due (see Notes), and the `noteLaunched` check 30 s after V1's first frame finds and stages V2 while V1's window is open. Check: `scripts/run-gate.sh G7` passes with both runs.
9. **Acceptance (design step 4).** Run (a) the T1 scheduler tests, (b) the T2 slow-provider launch test, and (c) the T2 exit test. Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md) §6.7):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`): `nextCheckAt` with jitter and backoff; the mode per package on scheduled runs. Not in the matrix.
- **T1** (`Packages/UpdateCore/Tests/UpdateCoreSystemTests/`, `Packages/RuntimeHost/Tests/RuntimeHostSystemTests/`): the scheduler with a manual clock: 20 packages checked on schedule with jitter, a failing provider backs off, a package in `downloading` or `installing` is not checked, and a newer candidate replaces a staged one. The concurrency limits, the fake network path (expensive, constrained, unsatisfied), Low Power Mode. `noteLaunched` after the reply. The exit rule. §3.5 with fake power and idle sources. CLI goldens.
- **T2** (`Tests/IntegrationTests/UpdateTests/`, `AndroidCustom`): with `update-server.py --delay 30`, `apkrun launch` of HelloUpdate reaches `FIRST_FRAME` in the same time as with the provider disabled, within the noise of the #070 harness, and the check starts after the first frame. apkrund started with nothing due and no client exits after the grace period.
- **T3** (`Tests/PerformanceTests/`, `Tests/AcceptanceTests/G7GentleUpdate`): `update-check-launch` (NFR-PERF-07), and the G7 check with the scheduled trigger.

### Acceptance criteria

- [ ] (a) With a manual clock, 20 packages are checked on schedule with jitter, a failing provider backs off (30 min, then 2 h), a package in `downloading` or `installing` is not checked, and a newer candidate replaces a staged one.
- [ ] (b) A launch whose provider is slow (30 s delay) reaches `FIRST_FRAME` in the same time as with the provider disabled, and the check starts after the first frame (FR-UPD-08).
- [ ] (c) apkrund started by the hourly `StartInterval` with nothing due exits after the 2-minute grace period.
- [ ] `openSession` makes no UpdateCore call before its reply. The T1 test shows it, and a code review of the launch path confirms it ([../traceability.md](../traceability.md) §2.7, NFR-PERF-07).
- [ ] `update-check-launch` shows a launch p50 difference of at most 50 ms (NFR-PERF-07).
- [ ] The default interval is 6 hours. `updates.checkIntervalHours` accepts only the allowed values, and a change recomputes the next check times.
- [ ] Background downloads wait on expensive networks unless `updates.downloadOnExpensiveNetwork` is on, and downloads over 50 MiB wait in Low Power Mode. User-initiated downloads always run.
- [ ] Scheduled checks follow the mode of each package: Automatic installs, Notify only stops at "available", and Manual is never checked (FR-UPD-09).
- [ ] `apkrun update` prints one line per package and exits 2 when some failed.
- [ ] G7 passes with the scheduled trigger.

### Notes

- The slow-provider test launches HelloUpdate with `apkrun launch`, which uses the generic launcher (§15 #074 step 4 (b), [cli.md](../../02-design/cli.md) §4.2). Wrappers come in M7, and #049 repeats the check with a wrapper.
- `update-check-launch` needs 10 packages with a provider. HelloUpdate is the only fixture with Direct manifests. `update-server.py` also answers for the other installed fixture packages with a manifest at their installed versionCode, so their checks end as "up to date" after the delay.
- The Updates pane of the Settings window comes with #079 ([../../02-design/host-ui.md](../../02-design/host-ui.md) §9.3, §14). In M6, the four keys are set with `apkrun config set` ([cli.md](../../02-design/cli.md) §4.6).
- The slow-provider test and `update-check-launch` use `DirectProvider` and `update-server.py --delay` of #050 ([../test-strategy.md](../test-strategy.md) §4.5). That is why this task depends on #050.
- A package without a `lastCheckAt` in `Updates/state.json`, for example one whose provider was just attached, is due now (§3.2). The scheduled G7 run depends on it.
- **Pitfall:** use `ContinuousClock`, not `SuspendingClock`, so checks that became due during sleep run after wake.
- **Pitfall:** the jitter is fixed per package per cycle. A new random value on every evaluation moves `nextCheckAt` and breaks the backoff tests.
