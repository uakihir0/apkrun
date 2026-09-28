# Package Store

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [update-system.md](update-system.md), [guest-protocol.md](guest-protocol.md) §11, [guest-components.md](guest-components.md) §8, [runtime-daemon.md](runtime-daemon.md), [wrapper.md](wrapper.md), [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §5, [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md), [../01-architecture/security-model.md](../01-architecture/security-model.md) §5, [../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) |
| Tasks | #027, #036, #073, #037–#039 and #041–#043 (store side), #048, #076 (store side), #066 (reinstall after reset) |

This document covers how APKRun keeps Android packages on the host and gets them into Android: importing, inspecting, the on-disk store, journaled transactions, install and uninstall, reconciling with Android, and the store-side mechanics of updates and rollback. *When* to update, providers, the update validation pipeline, and the health check are in [update-system.md](update-system.md).

---

## 1. Responsibilities

| Concern | Owner | Notes |
|---|---|---|
| Package records (`metadata.json`), per-package settings (`settings.json`), artifact directories, the journal | `PackageStore` (APKStoreCore) | The only writer of `Packages/`. Other processes go through `RuntimeService` |
| Import of `.apk`, split sets, `.apks`, `.xapk`, `.apkm`; host preview | `PackageImporter`, `APKInspector` (APKStoreCore) | Works while the VM is stopped (FR-PKG-03) |
| Intrinsic artifact checks (structure, signatures, split consistency, ABI, SDK) | `ArtifactVerifier` (APKStoreCore) | §4.6. Also used by UpdateCore |
| Relational update checks (same package, higher versionCode, signer continuity, provider hash) | UpdateCore | [update-system.md](update-system.md) §6. They are built on the primitives here |
| Getting packages into Android | Store Agent via `StoreAgentChannel` (custom image), `ADBStoreAgentChannel` (stock image) | Always `PackageInstaller` (FR-PKG-01). Never file copies into `/data/app` |
| Canonical package metadata | Android `PackageManager` | FR-PKG-02. Host-parsed values are a preview, and they are replaced by Android's values after install (§9) |
| When to install updates, gentle-update windows, health check, whether to roll back | UpdateCore | The store executes; UpdateCore decides |
| Wrappers | WrapperCore | The store knows nothing about wrapper bundles. It emits `PackageChange` events (§11.3) that WrapperCore consumes |

APKStoreCore reaches the guest only through the `StoreAgentChannel` protocol that RuntimeCore implements and RuntimeHost injects ([../01-architecture/modules.md](../01-architecture/modules.md) §3).

---

## 2. Concepts and types

### 2.1 Identity and versions

```swift
/// An Android package name, validated against the Android grammar:
/// two or more segments of [A-Za-z][A-Za-z0-9_]*, joined with ".", at most 255 characters.
public struct PackageID: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public let rawValue: String
    public init?(rawValue: String)
}

/// Android's longVersionCode: versionCodeMajor in the high 32 bits, versionCode in the low 32 bits.
public typealias VersionCode = Int64

/// Lowercase hex SHA-256 of a DER certificate or a file. Serialized as "sha256:<64 hex>".
public struct SHA256Digest: Codable, Sendable, Hashable { … }
```

- Package names are case-sensitive in Android. The default APFS volume is case-insensitive. The store therefore resolves directories through an in-memory index (§3.2) and never builds `Packages/<id>` paths by string concatenation outside `APKRunPaths`.
- Version comparisons always use `VersionCode` (`longVersionCode`). `versionName` is for display only.

### 2.2 Artifacts

  defines the input shape. The store turns it into a verified set on disk.

```swift
/// What a caller hands to the store (a file import, a provider download, a wrapper bootstrap).
public enum PackageArtifact: Sendable, Hashable {
    case apk(URL)
    case splitSet(base: URL, splits: [URL])
}

/// One file of a verified set.
public struct ArtifactFile: Codable, Sendable, Hashable {
    public var name: String // "base.apk", "split_config.arm64_v8a.apk", "split_feature_camera.apk"
    public var splitName: String? // nil for the base; "config.arm64_v8a", "feature_camera", …
    public var size: Int64
    public var sha256: SHA256Digest
}

/// The content of artifact.json in current/, previous/, staged/.
public struct ArtifactSet: Codable, Sendable, Hashable {
    public var schemaVersion: Int // 1
    public var packageID: PackageID
    public var versionCode: VersionCode
    public var versionName: String?
    public var files: [ArtifactFile] // base first, then splits sorted by splitName
    public var setDigest: SHA256Digest // §3.3
    public var signerDigests: [SHA256Digest] // the signer set Android will use on the guest SDK (§4.5)
    public var lineage: [SHA256Digest] // oldest → newest; empty without rotation
    public var inspection: InspectionProvenance // aapt2 version, verifier version, date, host checks performed
}
```

### 2.3 Package record

`metadata.json` holds a `PackageRecord`. The field-by-field reference, with the JSON schema, is [../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md). The record keeps these field names unchanged.

```swift
public struct PackageRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int // 1
    public var packageId: PackageID
    public var displayName: String // Android label in the guest's locale (§10)
    public var versionCode: VersionCode // what Android reports as installed
    public var versionName: String?
    public var signingCertificates: [SHA256Digest] // current signer set (from Android after install)
    public var signingLineage: [SHA256Digest]
    public var installer: Installer //.apkrun,.external (§9.3)
    public var updateAuthority: UpdateAuthority //.apkrun,.googlePlay,.external,.manual (ADR-0010)
    public var updateProvider: UpdateProviderRef? // {type, configuration}; nil = none (update-system.md §4)
    public var state: PackageState // state-machines.md §5
    public var artifacts: ArtifactSlots // summaries of current / previous / staged (versionCode, versionName,
    // setDigest, size, fileCount; staged adds origin)
    public var android: AndroidPackageFacts // updateOwner, installerOfRecord, first/last install time, min/target SDK,
    // native ABIs, userdataGeneration, lastSyncedAt
    public var source: PackageSource // how it first arrived: file, provider, wrapperBootstrap, adopted
    public var lastOperation: OperationSummary? // last install / update / rollback / uninstall / adopt result, for the UI and doctor
    public var createdAt: Date
    public var updatedAt: Date
}

public enum Installer: String, Codable, Sendable { case apkrun, external }
```

- `ArtifactSlots`, `AndroidPackageFacts`, `PackageSource`, and `OperationSummary` are defined field by field in [../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §2.3.2–§2.3.5.
- `UpdateAuthority` is defined in APKStoreCore because it is stored in the record and decides the install flags (§6.3). UpdateCore owns its policy ([update-system.md](update-system.md) §2).
- A record exists for every package APKRun manages. Packages installed in Android by something else are listed as *unmanaged* and have no record until the user adopts them (§9.3).

### 2.4 Package settings

`settings.json` holds `PackageSettings`, the user's preferences for one package: updates (`update.mode`, `update.autoRollback`, `update.healthCheckLaunch`), window (`window.mode`, `window.closeBehavior`, `window.resizable`, `window.zoom`, `window.defaultWidth`, `window.defaultHeight`, `window.alwaysOnTop`), input overrides (`input.*`), and desktop integrations (`integrations.*`). The keys and defaults are in [../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §3.

- Settings survive updates, rollbacks, reinstalls, and Reset Android. They are deleted on uninstall unless the user keeps the app data (§8).
- The store validates writes against the schema and emits `PackageChange.settingsChanged`. Consumers (sessions, IntegrationCore, UpdateCore) read settings through `PackageStore.settings(for:)`. They do not cache them across that event.

### 2.5 States

`PackageState`, `ReinstallReason`, `BrokenReason`, and the transitions are in [../01-architecture/state-machines.md](../01-architecture/state-machines.md) §5. The store is their owner. This document adds the mechanics behind each edge.

| State | Can launch | Can update | Shown as |
|---|---|---|---|
| `installed` | yes | yes | normal |
| `updating(_)` | yes. The install itself waits until no session is open (gentle update, [update-system.md](update-system.md) §7) | — | progress on the package row |
| `needsReinstall` | no (`openSession` answers `packageNotInstalled` with "Restoring ‹App›…") | no | "Restoring…" |
| `uninstalledKeepingData` | no | no | Settings → Storage → Apps with kept data |
| `broken(_)` | `removedInAndroid`, `artifactMissing`: only if Android still has it. `signerChanged`: yes | no | warning badge with the Repair action |

---

## 3. On-disk layout

### 3.1 Per-package directory

```text
Packages/
├── journal.jsonl
├── .trash/ # directories moved out by committed transactions; purged in the background
│   └── <txn>-<slot>/
└── <dir>/ # usually the package ID (§3.2)
    ├── metadata.json # PackageRecord
    ├── settings.json # PackageSettings
    ├── current/ # what Android should have installed
    │   ├── artifact.json
    │   ├── base.apk
    │   └── split_<splitName>.apk …
    ├── previous/ # last known-good set, present after an update until the next update
    ├── staged/ # verified update waiting for an install window (UpdateCore)
    │   └── validation.json # UpdateCore's validation report (update-system.md §6); not part of setDigest
    ├── incoming/<ticket>/ # imports and downloads being inspected; never referenced by a record
    ├── failed/<versionCode>/ # a set that was rolled back; kept 7 days for diagnostics, then deleted
    └── icon/ # rendered icon layers (§10)
```

- File names in a set are fixed: `base.apk` and `split_<splitName>.apk`. The `PackageInstaller` session names are the same without the extension ([guest-protocol.md](guest-protocol.md) §11.3). The original file names from the user's import are recorded in `source` only.
- `artifact.json` makes each slot self-describing. Recovery (§5.5) identifies a directory by its `setDigest`, never by its name alone.
- At most one set per slot. A newer staged update replaces the older staged set (§5.2, kind `stage`).
- `incoming/<ticket>/` is scratch space. The importer creates it, and an install or `stage` transaction renames it into a slot. Tickets that no transaction references are deleted at `open` and after 24 h.
- `failed/` is deleted after 7 days or when the package is uninstalled. It is included in diagnostics bundles as metadata only (names, sizes, digests), never the APKs.

### 3.2 Directory names

- The directory name is the package ID, as in (`Packages/com.discord/`).
- If another directory already has the same name ignoring case (for example `com.Foo` and `com.foo`), the new directory is `<packageId>~<first 8 hex of SHA-256(packageId)>`. Wrapper bundle IDs use a different, order-independent rule, because they must be the same on every Mac and `~` is not allowed in bundle IDs ([wrapper.md](wrapper.md) §4.1).
- `open` builds the `PackageID → directory` index from each `metadata.json`. A directory without a `metadata.json` is moved to `.trash/` with a health warning after its contents were checked against the journal (§5.5). A directory whose `metadata.json` exists but can't be read is never moved: the package ID comes from the directory name, and the package is read-only (§5.4, [../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §6.3).

### 3.3 Set digest

`setDigest = SHA-256` over the UTF-8 lines `"<name>\t<sha256 hex>\n"` for each file, sorted by `name`. Two sets with the same digest are the same install. The store uses this to make repeated imports and repeated staging no-ops (§4.7), and recovery uses it to identify slots.

### 3.4 Space

| Check | When | Rule |
|---|---|---|
| Host free space before import | `beginImport` | free ≥ 2 × source size + 2 GiB. Otherwise `StoreFailure.insufficientHostSpace(needed, available)` |
| Host free space before staging | `stage` | free ≥ set size + 2 GiB |
| Guest free space | at install | Android decides. `STATUS_FAILURE_STORAGE` becomes `StoreFailure.guestStorageFull` with the remediation "Increase Android storage in Settings → Runtime" (`runtime.userdataGiB`) |
| Store size | Settings → Storage | per package: current + previous + staged + failed + icons. "Remove previous version" frees `previous/` (and disables rollback for that package until the next update) |

Import copies with `clonefile(2)` when the source is on the same APFS volume. Otherwise it streams the copy and computes SHA-256 as it goes. After `beginImport` returns, nothing refers to the source file again. The user may delete the original APK (#048).

---

## 4. Import and inspection

### 4.1 Sources

|---|---|---|
| Files dropped on APKRun.app, the Add sheet, or the Dock icon | `RuntimeService.importPackage` with file handles | The GUI passes open file descriptors over XPC (`FileHandle`, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.1), so apkrund never needs its own TCC consent for `~/Downloads` or `~/Desktop` |
| `apkrun install <file…>` | same, with file handles opened by the CLI | Several `.apk` files form one split set |
| Provider download | UpdateCore gets a ticket with `PackageStore.beginDownloadTicket(id)`, the provider writes into `incoming/<ticket>/`, and UpdateCore calls `PackageStore.inspect(ticket)` | [update-system.md](update-system.md) §5 |
| Portable wrapper bootstrap | the wrapper sends `importBootstrap` with a file handle to `Contents/Resources/bootstrap/` | first import on a new Mac only (#089, [wrapper.md](wrapper.md)) |
| Adoption of an unmanaged package | `adoptPackage(id)` | no artifact (§9.3) |

### 4.2 Container formats

| Format | Detected by | Handling |
|---|---|---|
| `.apk` | ZIP with `AndroidManifest.xml` at the root | one file, or several dropped together as one split set |
| `.apks` (bundletool) | ZIP with `toc.pb` and `splits/` | extract the APKs under `splits/`. Ignore `standalones/`. A `universal.apk` alone is treated as a single APK. The split selection (§4.4) is done from the split manifests, not from `toc.pb` |
| `.xapk` (APKPure) | ZIP with `manifest.json` containing `xapk_version` | extract `split_apks[].file` (or the single APK). **Expansions (OBB) are refused in v1** with `StoreFailure.expansionFilesNotSupported` ([../04-plan/open-questions.md](../04-plan/open-questions.md)) |
| `.apkm` (APKMirror) | ZIP with `info.json` containing `apkm_version` | extract the APKs. Encrypted or non-ZIP files → `unsupportedContainer(.encryptedAPKM)` |
| `.zip` containing APKs only | ZIP whose entries are all `*.apk` | treated like several dropped `.apk` files |
| `.aab` | ZIP with `BundleConfig.pb` | refused: `unsupportedContainer(.appBundle)`. Converting a bundle means re-signing it with another key, which breaks updates of the real app |
| anything else | | `unsupportedContainer(.unknown)` |

Detection looks at content, never at the file extension alone. ZIP reading uses ZIPFoundation (MIT, pinned with an `exact:` version, ADR-0017) through `ContainerReader`, which checks the limits below while streaming and never uses the library's extract-to-directory functions. The signature verifier reads the ZIP structures directly (§4.5).

**Extraction limits** (zip-bomb and path safety). A violation fails the import with `archiveLimitExceeded`:

- at most 512 entries in a container and at most 256 APKs;
- each extracted file ≤ 2 GiB (the transfer limit, [guest-protocol.md](guest-protocol.md) §10), total ≤ 8 GiB;
- compression ratio ≤ 100:1 per entry, checked while streaming;
- names must be valid UTF-8, relative, without `..`, without symlink or device entries. Extracted files get fixed names in `incoming/<ticket>/`.

### 4.3 APKInspector

`APKInspector` produces an `APKFacts` value for each APK. It runs entirely on the host and needs no VM.

| Fact | Tool | Notes |
|---|---|---|
| package, `versionCode` + `versionCodeMajor` → `VersionCode`, `versionName`, split name, `minSdkVersion`, `targetSdkVersion`, labels per locale, icon resource paths per density, `native-code`, `uses-permission`, `uses-feature` | `aapt2 dump badging` | aapt2 is bundled at `Contents/Resources/tools/aapt2` (Apache-2.0, pinned from Google Maven, [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §4) |
| `isFeatureSplit`, `configForSplit`, `isSplitRequired`, `requiredSplitTypes`, `splitTypes`, `dist:module` delivery, `debuggable`, `sharedUserId`, `extractNativeLibs` | `aapt2 dump xmltree --file AndroidManifest.xml` | only the attributes listed are read |
| native libraries by ABI | ZIP central directory (`lib/<abi>/*.so`) | cross-checks `native-code` |
| signer set, lineage, scheme | `APKSignatureVerifier` (§4.5) | native Swift |
| size, SHA-256 | streaming hash | computed during the copy |

- aapt2 runs as a subprocess with a 20 s timeout per call, a 16 MiB output cap, and `LANG=C`. Its output is parsed by a tolerant line parser with golden tests for the pinned aapt2 version. Updating aapt2 needs a re-run of the golden tests (#073).
- aapt2 parses untrusted input. It runs in a `sandbox-exec` profile that denies network and writes and allows reads only of the ticket directory and the tool (hardening item in #091). If `sandbox-exec` is missing, it runs unsandboxed and logs a warning.
- The inspector never executes anything from the APK.

### 4.4 Split sets and split selection

A split set must follow Android's rules: every APK has the same package, versionCode, and signer; split names are unique; there is exactly one base ([PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller)).

When a container holds more splits than the device needs, `SplitSelector` picks them from the split names (`config.<qualifier>`) and the manifests:

| Split kind | Rule |
|---|---|
| base | always |
| feature splits (`isFeatureSplit`) | all present in the container. On-demand features would need Play and are not supported. Install-time features are included |
| ABI config (`config.arm64_v8a`, `config.armeabi_v7a`, `config.x86_64`, …) | only the guest's supported ABIs (from the Guest Agent `Hello`, default `arm64-v8a`) |
| density config (`config.xhdpi`, `config.xxhdpi`, …) | the bucket nearest to 320 dpi (the Retina default density, [display-and-windowing.md](display-and-windowing.md) §6). If none is at least 320, the highest one |
| language config (`config.ja`, `config.en`, …) | all of them. The guest follows the macOS language list, which can change at any time ([desktop-integration.md](desktop-integration.md) §9) |
| other or unknown config splits | included if they are `configForSplit` of an included split and their qualifier is not recognized as an ABI or density |

- When the user drops individual `.apk` files, the selection is not applied. The user's set is installed as given, after the checks in §4.6.
- After selection, `requiredSplitTypes` of the base (API 33+) must be satisfied by the `splitTypes` of the included splits. Otherwise the import fails with `incompleteSplitSet(missing:)`.
- The density choice is a baseline. Its quality effect is measured in #042 and recorded in [../04-plan/open-questions.md](../04-plan/open-questions.md).

### 4.5 Signature verification on the host

`APKSignatureVerifier` is a native Swift implementation in APKStoreCore (`Sources/APKStoreCore/Signing/`). There is no Java on users' Macs. The Go and Rust alternatives are LGPL or do not verify cryptographically (research 2026-09-28).

1. Locate the End of Central Directory, the Central Directory, and the APK Signing Block (magic `APK Sig Block 42`) in front of it.
2. Pick the scheme Android uses on the guest SDK. That is v3.1 (block `0x1b93ad61`) if present and a signer's SDK range covers the guest SDK, else v3 (`0xf05368c0`), else v2 (`0x7109871a`). v3.2 hybrid signatures (API 37) include a classic signature. The verifier checks the classic part and records whether a post-quantum part is present. The ML-DSA part is verified with CryptoKit where the host OS supports it. Otherwise it is left to Android.
3. Verify the content digests: 1 MiB chunks over the ZIP entries, the Central Directory, and the EOCD with the CD offset replaced by the signing block offset. Supported algorithms: RSASSA-PKCS1-v1_5 and RSASSA-PSS with SHA-256/512, and ECDSA with SHA-256/512 (Security.framework `SecKeyVerifySignature`). The verity-based digest is skipped when another digest is present.
4. Verify each signer's signature over its signed data with the certificate's public key, and require the certificate public key to match the one in the signer block.
5. Parse the proof-of-rotation attribute (v3/v3.1) into a lineage: oldest → newest certificate, each node signed by the previous key, with its capability flags (`INSTALLED_DATA`, `SHARED_USER_ID`, `PERMISSION`, `ROLLBACK`, `AUTH`).
6. The **signer set** is the SHA-256 of the DER certificate of each signer Android would use. Multiple signers are allowed (v2). Android then requires the full set to match on update.

Special cases:

| Case | Host result | Why |
|---|---|---|
| No v2+ signature, `targetSdk ≥ 30` | reject: `legacySignatureNotAllowed(targetSdk)` | Android 11+ rejects these |
| v1 (JAR) only, `targetSdk < 30` | accept as `.certificateOnly`: read the signer certificate from `META-INF/*.RSA|EC|DSA` without checking the JAR digests. The preview shows "Legacy signature — verified by Android during install" | implementing JAR verification on the host adds little: Android verifies at install, and the Store Agent checks the expected signer before commit ([guest-protocol.md](guest-protocol.md) §11.3) |
| DSA signer, or an algorithm Security.framework does not support | `.certificateOnly` with a warning | same reason |
| Invalid digest or signature | reject: `invalidSignature(file, reason)` | never staged, never sent to Android |
| Unsigned APK | reject: `unsignedAPK(file)` | Android refuses unsigned APKs |

Security position (NFR-SEC-04): the host check is an early, explainable check. It is not the final authority, and nothing ever bypasses Android's own verification. Android's `PackageManager` verifies every install and enforces signer continuity on update. The Store Agent re-checks the expected package, version, and signer against Android's parser before commit. A host verifier bug can therefore cause a false rejection, but never a successful install of something Android would reject. For false rejections (`invalidSignature` reported for an APK Android accepts), the importer asks the Store Agent's `InspectArchive` when the runtime is ready, and uses Android's verdict with a logged `verifier.disagreement` event. The correctness risk is tracked as a risk item ([../04-plan/risks.md](../04-plan/risks.md)).

Test vectors: the apksig test resources (Apache-2.0) and a differential run against `apksigner verify --print-certs -v` over a corpus of real F-Droid APKs (`scripts/dev/verify-corpus.sh`, CI nightly). Details in §16.

### 4.6 Intrinsic checks

`ArtifactVerifier.verify(set, guest: GuestFacts) → VerifiedArtifactSet` runs these checks on every import, first install or update. UpdateCore adds the relational checks on top ([update-system.md](update-system.md) §6, [../01-architecture/security-model.md](../01-architecture/security-model.md) §5).

| # | Check | Failure |
|---|---|---|
| I1 | Container supported, extraction limits respected (§4.2) | `unsupportedContainer`, `archiveLimitExceeded` |
| I2 | Every file is an APK with a manifest | `notAnAPK(file)` |
| I3 | Exactly one base, unique split names | `missingBase`, `multipleBases`, `duplicateSplit(name)` |
| I4 | Same package and `VersionCode` in every APK | `inconsistentSplits(.package /.versionCode, file)` |
| I5 | Valid signature (§4.5), and the same signer set in every APK | `unsignedAPK`, `invalidSignature`, `legacySignatureNotAllowed`, `inconsistentSplits(.signer, file)` |
| I6 | Required splits present (`requiredSplitTypes`, `isSplitRequired`) | `incompleteSplitSet(missing:)` |
| I7 | ABI: no native code, or native code for at least one guest ABI in the base or the selected ABI split. `arm64-v8a` is the only guest ABI on APKRun images ([../00-product/scope.md](../00-product/scope.md)) | `unsupportedABI(found:, supported:)` |
| I8 | `minSdkVersion ≤` guest SDK (37 on the baseline image) | `minSdkTooHigh(required:, guest:)` |
| I9 | `targetSdkVersion ≥` the guest's install floor: 23 on API 34, 24 on API 35 and later. APKRun never uses `--bypass-low-target-sdk-block` | `targetSdkTooLow(target:, floor:)` |
| I10 | Not an APKRun agent (`io.apkrun.guest`, `io.apkrun.store`) and not a platform package known to the image | `reservedPackage(id)` |
| I11 | Each file ≤ 2 GiB, total ≤ 8 GiB | `tooLarge(bytes:, limit:)` |
| I12 | `targetSdkVersion ≥ 30`: every `resources.arsc` is stored uncompressed and starts on a 4-byte boundary. Android refuses the install otherwise (`INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED`) | `resourcesArscNotAligned(file:)` |

Warnings do not block the install. They appear in the preview and in `apkrun inspect`:

- `uses-feature android:required="true"` for hardware the guest lacks (telephony, NFC, camera before #083/#084, …). Android installs these apps anyway. The app may refuse to run.
- `.certificateOnly` signature verification (§4.5).
- `debuggable="true"` builds.
- Target SDK far below the guest (for example below 28): compatibility behavior applies.

`GuestFacts` (SDK, ABIs, install floor) come from the last Guest Agent `Hello` saved in `Runtime/instance/instance.json`. Before the first boot they come from the installed image's manifest ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md)).

### 4.7 Import results

`beginImport` returns an `ImportPreview`:

```swift
public struct ImportPreview: Codable, Sendable {
    public var ticket: ImportTicket
    public var packageID: PackageID
    public var displayName: String // host label in the best macOS language match
    public var versionCode: VersionCode
    public var versionName: String?
    public var icon: HostIconPreview? // §10.1
    public var files: [ArtifactFile] // after split selection
    public var excludedSplits: [String] // shown in "Details"
    public var signer: SignerSummary // digests, scheme, lineage length, verification level
    public var permissions: [String] // requested permissions, for the "Details" disclosure
    public var warnings: [ImportWarning]
    public var relation: ImportRelation // see below
    public var compatibility: CompatibilityInfo? // the compatibility database entry for this build (#090, diagnostics.md §10.3); nil = none
}

public enum ImportRelation: Codable, Sendable {
    case newPackage
    case sameAsInstalled // same setDigest → nothing to do ("Already installed")
    case reinstallSameVersion // same versionCode, different files (for example other splits)
    case update(from: VersionCode) // routed to UpdateCore as a manual update
    case downgrade(from: VersionCode) // refused (FR-UPD-05)
    case otherSigner // refused: Android would reject it
    case uninstalledWithData(VersionCode) // a record in uninstalledKeepingData: install restores the data
}

public enum ImportWarning: Codable, Sendable, Equatable { // the warnings of §4.6. Not errors: the exit code doesn't change
    case missingHardwareFeature(feature: String) // uses-feature android:required="true" for hardware the guest lacks
    case certificateOnlyVerification // the signature was verified as.certificateOnly (§4.5)
    case debuggable // debuggable="true"
    case lowTargetSDK(target: Int) // the target SDK is below 28
}
```

- An import for a package that is already installed goes to UpdateCore as a *manual update*. It gets the same validation and gentle install as provider updates ([update-system.md](update-system.md) §7). A downgrade is refused with `store.downgradeRefused`: "‹App› ‹version› is older than the installed version ‹installed version›. Keep the installed version, or uninstall ‹App› first." A different signer is refused with "This file is signed by a different developer than the installed app."
- `reinstallSameVersion` is allowed. It installs with mode `REINSTALL` and replaces `current/` in a `reinstall` transaction (§5.2).

---

## 5. Transactions and the journal

Every change to Android or to the artifact slots is a transaction in `Packages/journal.jsonl`. Its purpose is that a crash, a kill, or a power loss at any point leaves a state that `open` can finish or undo without user action. The one exception is that the result of an Android commit that was in flight must be read back from Android after boot.

### 5.1 Journal format

JSON Lines, append-only, one object per line:

```jsonl
{"v":1,"seq":41,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:03.120Z","op":"begin","kind":"update","package":"com.example.app","dir":"com.example.app","from":44,"to":45,"setDigest":"sha256:9f2c…"}
{"v":1,"seq":42,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:03.410Z","op":"step","step":"guestCommitRequested","androidSession":1873}
{"v":1,"seq":43,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:09.002Z","op":"step","step":"guestInstalled","versionCode":45}
{"v":1,"seq":44,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:09.015Z","op":"step","step":"filesPromoted"}
{"v":1,"seq":45,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:09.020Z","op":"step","step":"metadataWritten"}
{"v":1,"seq":46,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:09.021Z","op":"commit"}
```

- `txn` is a ULID. `seq` increases by one per line across the file. A gap or a line that does not parse ends the readable part of the journal (a torn last write). Everything after it is ignored, and `store.journal` health reports it.
- Durability: each line is written with a single `write(2)`, then `fcntl(F_BARRIERFSYNC)`. Renames of slots are followed by `fsync` of the package directory. `metadata.json` and `settings.json` are written to a temporary file in the same directory, barrier-synced, then renamed over the old file. `F_FULLFSYNC` is not used. After a power loss the store relies on ordering, not on the last write reaching the disk.
- Guest steps are journaled **before** the request that changes Android (`…Requested`) and again after the outcome. Host file steps are journaled **after** they are done. Recovery infers half-done file steps from the directories themselves (§5.5).
- Compaction: at `open` and after each commit when the file exceeds 1 MiB, the journal is rewritten (temporary file + rename) with only the lines of unfinished transactions. `seq` continues from the last value.

### 5.2 Transaction kinds

| Kind | Started by | Steps, in order | Files |
|---|---|---|---|
| `firstInstall` | user install of a new package | `begin` → `guestCommitRequested` → `guestInstalled` → `filesPromoted` → `metadataWritten` → `commit` | `incoming/<t>` → `current` |
| `reinstall` | same-version reinstall, `needsReinstall` after reset (§9.2), repair | `begin` → `guestCommitRequested` → `guestInstalled` → [`filesPromoted`] → `metadataWritten` → `commit` | none when it reinstalls `current/`. `incoming/<t>` → `current` (old `current` → `.trash`) for `reinstallSameVersion` |
| `stage` | UpdateCore after validation | `begin` → `filesStaged` → `metadataWritten` → `commit` | old `staged` → `.trash`, `incoming/<t>` → `staged` |
| `update` | UpdateCore in an install window | `begin` → `guestCommitRequested` → `guestInstalled` → `filesPromoted` → `metadataWritten` → `commit` | old `previous` → `.trash`, `current` → `previous`, `staged` → `current` |
| `rollback` | UpdateCore after a failed health check, or the user ("Roll back to ‹version›") | `begin` → `guestRollbackRequested` → `guestRolledBack` → `filesRestored` → `metadataWritten` → `commit` | `current` → `failed/<vc>`, `previous` → `current` |
| `uninstall` | user | `begin` → `guestUninstallRequested` → `guestUninstalled` → `filesRemoved` → `metadataWritten` or `recordRemoved` → `commit` | the package directory → `.trash` (keep data: only the slots, the record stays) |
| `forget` | "Remove from APKRun" for a package that cannot be uninstalled from Android (runtime broken, package already gone) | `begin` → `filesRemoved` → `recordRemoved` → `commit` | package directory → `.trash` |
| `discardStaged` | UpdateCore (candidate withdrawn, authority changed, user "Skip this version") | `begin` → `filesRemoved` → `metadataWritten` → `commit` | `staged` → `.trash` |
| `schemaMigration` | `open` when a record or settings file has an older schema version (§5.4) | `begin` → `migrated` (once per package) → `commit` | `metadata.v<old>.json` and `settings.v<old>.json` backups next to the migrated files ([../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §5.2) |

Rules:

- **Files mirror Android.** `current/` is promoted as soon as Android confirms the install, before the post-update health check. The directories therefore always describe what Android should have, and a rollback is a transaction of its own. The previous set stays in `previous/` until the next successful update.
- A failure before `guestCommitRequested` ends the transaction with `{"op":"abort","reason":…}` and undoes nothing on disk, because nothing has moved yet. The `incoming/` or `staged/` set stays where it was, for a retry or cleanup.
- `update` promotion uses `renamex_np(RENAME_SWAP)` for `staged ↔ current`, then renames the old `current` (now in `staged`) to `previous` after the old `previous` went to `.trash`. Each rename is atomic on APFS, and each intermediate state is recognizable by `setDigest` (§5.5).
- `.trash` is purged by a background task after the commit. A crash leaves at most garbage in `.trash`, which the next `open` purges.
- Some writes change only the record or `settings.json`, never a slot or Android: reconciliation (§9.2), `recordHealth`, adopt (§9.3), `setUpdatePolicy`, and `updatePackageSettings`. They are not transactions. They take the operation lock (§5.3) and write atomically ([../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §6.2).

### 5.3 Concurrency

- One transaction per package at a time. A second request for the same package fails with `operationInProgress(id)`. UI buttons are disabled from the `packages` event stream, so users rarely see this.
- One Android commit at a time across all packages (a FIFO with two priorities: user-initiated operations before background updates). Host-only steps (`stage`, `forget`, `discardStaged`) do not wait for this queue.
- Every transaction that talks to the guest runs inside `StoreRuntimeAccess.withStoreAgent` (§6.1). That ensures the runtime is ready and holds a `storeOperation` activity assertion for the whole transaction ([runtime-daemon.md](runtime-daemon.md) §5.1). It boots or resumes Android only for user-initiated operations, including user-initiated updates. An automatic update install runs only while the runtime is already `ready` ([update-system.md](update-system.md) §3.1, §7.1 GU1). The one exception is `updates.startRuntimeToInstall` ([update-system.md](update-system.md) §3.5).

### 5.4 Opening the store

`PackageStore.open` is startup step 6 of apkrund ([runtime-daemon.md](runtime-daemon.md) §2.2) and runs in embedded mode too. It does not need the VM.

1. Read `journal.jsonl` up to the first unreadable line.
2. Load every `metadata.json`. Build the directory index (§3.2). Migrate older record and settings files in one `schemaMigration` transaction. An unfinished one from an earlier start continues here ([../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md) §5.2).
3. Recover every unfinished transaction in `seq` order (§5.5). Host-only work is done now. Work that needs Android becomes a `PostBootTask`.
4. Compact the journal.
5. Delete orphaned `incoming/<ticket>/` directories, purge `.trash/`, and delete `failed/` sets older than 7 days.
6. Publish the records. Packages with pending post-boot work show `lastOperation.pending = true`, so the UI can say "Finishing install of ‹App›…".

A `metadata.json` or `settings.json` with a newer `schemaVersion` than the binary supports makes the store read-only for that package (`metadataUnreadable`), not the whole store. The file is never written. A journal with a newer `v` makes the whole store read-only, and the host startup step reports it as degraded ([runtime-daemon.md](runtime-daemon.md) §2.2).

### 5.5 Recovery rules

For each unfinished transaction, the last journaled step decides the action.

| Kind | Last step | Recovery |
|---|---|---|
| any | `begin` only | abort. Files were not moved yet (guest kinds), or check the target slot's `setDigest` (host kinds: if the move happened, roll forward) |
| `firstInstall`, `reinstall`, `update` | `guestCommitRequested` | **post-boot**: read the installed version from Android (`GetPackageMetadata`, or `QueryPackage` on stock images). If it equals the target versionCode (and, for `reinstall`, `lastUpdateTime` is after `begin`) → continue as if `guestInstalled`. Otherwise → abort, keep `staged/` for a later retry, delete the `incoming/` set of a first install, and tell the user "Installing ‹App› was interrupted" with a Retry action |
| `firstInstall`, `reinstall`, `update` | `guestInstalled` | roll forward now: promote files (idempotent, see below), write metadata, commit. Android facts are refreshed after boot |
| `update` | `filesPromoted` or partway | finish the renames. Identify slots by `setDigest`: the set with digest `to` belongs in `current/`, the set with digest `from` in `previous/`. Any other set in these slots goes to `.trash` |
| `rollback` | `guestRollbackRequested` | post-boot: read the installed version. `from` version still installed → abort and report "Rollback of ‹App› did not happen" (the package stays in the failed-update state, [update-system.md](update-system.md) §8). Previous version installed → continue |
| `rollback` | `guestRolledBack` | finish `filesRestored` by `setDigest`, then metadata and commit |
| `rollback` (confirmed data-loss fallback, §7.3) | `guestUninstallRequested` or later, before `guestRolledBack` | post-boot: query Android. The package is absent → continue with the first install of `previous/`, because the user already confirmed the data loss. The `from` version is still installed → abort as above |
| `uninstall` | `guestUninstallRequested` | post-boot: query Android. Still installed → abort (the package is `installed` again). Absent → continue |
| `uninstall`, `forget`, `discardStaged` | a file step | roll forward |
| `stage` | `begin` | if `staged/` has the new digest → roll forward, else abort and delete the `incoming/` set |

`PostBootTask`s run in step 5 of readiness ([runtime-daemon.md](runtime-daemon.md) §3.4). Each is one query. They never hold up `ready` for more than the 5 s budget. The rest runs after `ready` under a `storeOperation` assertion. If Android cannot answer (agent unavailable), the task is re-queued for the next boot and the package stays `pending`.

---

## 6. Installing into Android

### 6.1 Channel abstraction

```swift
public protocol StoreAgentChannel: Sendable {
    var capabilities: StoreCapabilities { get } //.install,.metadata,.inspect,.icons,.updateOwnership,.rollback,.downgradeReinstall

    func inspect(_ files: [StagedFile]) async throws -> GuestArchiveInfo
    func install(_ request: StoreInstallRequest, files: [StagedFile],
        progress: @Sendable (StoreInstallProgress) -> Void) async throws -> StoreInstallResult
    func uninstall(_ package: PackageID, keepData: Bool) async throws
    func rollback(_ package: PackageID, from: VersionCode, to: VersionCode) async throws -> StoreRollbackResult
    func relinquishUpdateOwnership(_ package: PackageID) async throws
    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? // nil = not installed
    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageInfo]
    func renderIcon(_ package: PackageID, sizePx: Int) async throws -> RenderedIcon
    nonisolated var packageEvents: AsyncStream<StorePackageEvent> { get } // PackageChanged
}

/// Injected by RuntimeHost. Hides RuntimeCore from APKStoreCore.
public protocol StoreRuntimeAccess: Sendable {
    /// Ensures the runtime is ready (boots it if needed), holds a storeOperation assertion,
    /// and hands over the channel for the current image.
    func withStoreAgent<T: Sendable>(_ reason: StoreOperationReason, operation: OperationID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T) async throws -> T
    func guestFacts() async -> GuestFacts? // SDK, ABIs, install floor, userdataGeneration
    func hasOpenSession(_ package: PackageID) async -> Bool // any AppSession except ended; the check of §7.2 (#038)
    func endSessions(for package: PackageID, reason: SessionEndReason) async
}
```

| Implementation | Image | Transport | Missing capabilities |
|---|---|---|---|
| `ADBStoreAgentChannel` | stock image (M3–M4), and custom images with `--guest-transport adb` for debugging | `adb install-multiple`, `pm uninstall`, Guest Agent `QueryPackage`/`ListPackages` ([guest-protocol.md](guest-protocol.md) §13.2) | `.updateOwnership`, `.icons`, `.rollback`, `.inspect`. It has `.downgradeReinstall` when `ro.debuggable=1` |
| `StoreAgentSupervisor` | custom image (M5+) | vsock 6110/6111, Store Agent protocol ([guest-protocol.md](guest-protocol.md) §11) | none once the Store Agent has every capability. It reports only the capabilities the agent announces in `Hello`: #036 brings `.install`, `.metadata`, and `.inspect`; `.updateOwnership` comes with #039, `.rollback` with #043, and `.icons` with #055 ([guest-protocol.md](guest-protocol.md) §3). `.downgradeReinstall` is never offered (`allow_downgrade` is always false in v1) |

Missing capabilities are not errors. The store records what it could not do (for example `android.updateOwner = nil` and a health note on a stock image) and continues.

### 6.2 First install flow

```text
install(ticket, options)
1. re-check the ticket: preview still valid (files unchanged: sizes and digests), no record, or record in uninstalledKeepingData
2. journal begin(firstInstall) state: inspecting → installing
3. withStoreAgent(.install): boots Android if needed; OperationHandle shows "Starting Android…"
a. BeginInstall(InstallRequest{ expected_package, expected_version_code, expected_signer_sha256,
mode: INSTALL_NEW, request_update_ownership: §6.3,
enable_rollback: false, artifacts, install_reason: USER,
package_source: OTHER })
b. stream every file on the artifact stream (progress: RECEIVING)
c. journal step guestCommitRequested
d. CommitInstall → wait for InstallFinished (progress: VERIFYING, COMMITTING)
4. SUCCESS → journal step guestInstalled(versionCode)
5. rename incoming/<ticket> → current journal step filesPromoted
6. GetPackageMetadata → write metadata.json journal step metadataWritten, commit
state: installing → installed
7. RenderIcon (1024 px) → icon/ (non-fatal, retried on the next boot if it fails)
8. emit PackageChange.installed; optional WrapperCore.generate (the "Create Mac app" choice)
```

- `ADBStoreAgentChannel` performs step 3 as `adb install-multiple -r --no-streaming <files>` after the host verified the digests. Steps 4–6 use `QueryPackage`.
- Timeouts: `BeginInstall` 30 s. Artifact streaming has a stall timeout of 30 s without progress, no total timeout. `InstallFinished` 10 min (Android verifies and optimizes large apps). `GetPackageMetadata` 10 s. A timeout after `guestCommitRequested` is handled like a crash: the outcome is read back from Android (§5.5).
- Cancel: allowed until step 3c. The agent abandons the session (`AbandonInstall`). After 3c, cancel is refused ("Android is finishing the install").
- A failed first install ends the transaction with `abort`, deletes the ticket, and removes the record if it was created. The user gets the mapped error (§12).

### 6.3 Update ownership at install

`request_update_ownership = record.updateAuthority.claimsUpdateOwnership && channel.capabilities.contains(.updateOwnership)`.

| Authority | `claimsUpdateOwnership` | Why |
|---|---|---|
| `apkrun` | true | Other installers may not update the package silently |
| `manual` | true | APKRun is still the only installer. It installs only when the user supplies the APK |
| `googlePlay` | false | Never compete with Play for ownership |
| `external` | false | another installer owns updates |

- The default authority for a file import is `manual`. It becomes `apkrun` when the user attaches an update provider, either in the Add sheet (when the provider is detected, for example an F-Droid package ID match) or later in the package's settings ([update-system.md](update-system.md) §2).
- Authority changes go through `PackageStore.setUpdateAuthority(id, authority, provider:)` under the package's operation lock (§5.3). It is called by UpdateCore's `setUpdatePolicy` and `setUpdateAuthority` ([update-system.md](update-system.md) §2.1, §11.1) and by adopt (§9.3). Changing the authority to `googlePlay` or `external` calls `RelinquishUpdateOwnership` (Store Agent op 109, `PackageManager.relinquishUpdateOwnership`, API 34) first, then writes the record. When the runtime is not `ready`, the call becomes a post-boot task, because an authority change never starts Android. `FAILED_PRECONDITION` (APKRun is not the owner) is not an error. A crash between the call and the write leaves the old authority with no owner: the next reconcile reports `store.ownership`, and the next install requests ownership again. Changing to `apkrun` or `manual` for a package that has no owner requests ownership on the next install APKRun performs. Whether Android grants ownership on an update to a package installed without it is verified in #039, and the result is recorded here.
- After every install the store records `android.updateOwner` from `GetPackageMetadata`. For `apkrun`/`manual` packages whose owner is not `io.apkrun.store`, health reports `store.ownership` as a warning. That happens on stock images and when the enforcement flag is off in the image ([guest-components.md](guest-components.md) §8.2).

### 6.4 Install result mapping

| `InstallFinished.status` | Typical `legacy_status` | `StoreFailure` | User message (short) |
|---|---|---|---|
| `SUCCESS` | — | — | — |
| `CONFLICT` | `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`, `INSTALL_FAILED_DUPLICATE_PERMISSION` | `guestInstallFailed(.conflict, …)` | "Android refused ‹App› because it conflicts with an installed app." |
| `INCOMPATIBLE` | `INSTALL_FAILED_NO_MATCHING_ABIS`, `INSTALL_FAILED_OLDER_SDK`, `INSTALL_FAILED_DEPRECATED_SDK_VERSION`, `INSTALL_FAILED_MISSING_SPLIT` | `guestInstallFailed(.incompatible, …)` | "‹App› is not compatible with this version of Android." (The host checks should have caught this. Each occurrence is logged as `store.hostCheckMissed`) |
| `INVALID` | `INSTALL_PARSE_FAILED_*`, agent pre-commit mismatch | `guestInstallFailed(.invalid, …)` | "The app file is damaged or isn't what was expected." |
| `STORAGE` | `INSTALL_FAILED_INSUFFICIENT_STORAGE` | `guestStorageFull` | "Android is out of storage." + Settings action |
| `BLOCKED` | policy, system package | `guestInstallFailed(.blocked, …)` | "Android does not allow installing ‹App›." |
| `ABORTED` | session abandoned (timeout, disconnect) | `guestInstallFailed(.aborted, …)` | "Installation was interrupted." + Retry |
| `USER_ACTION_REQUIRED` | `STATUS_PENDING_USER_ACTION` | `userActionRequired` | "Android asked for confirmation, which APKRun does not support." (Not expected for a privileged installer. Logged as a bug) |
| `FAILURE` | anything else | `guestInstallFailed(.other, …)` | the Android message in "Details" |

---

## 7. Updates and rollback: store mechanics

UpdateCore decides when to stage, install, health-check, and roll back ([update-system.md](update-system.md) §3–§8). The store provides these operations.

### 7.1 Stage

`stage(ticket, candidate: StagedUpdateInfo) async throws`. The ticket's set already passed the intrinsic checks (§4.6) and UpdateCore's relational checks. It runs the `stage` transaction (§5.2) and records `artifacts.staged` with the candidate's source (provider, release URL, declared hash).

### 7.2 Install a staged update

`installStaged(id, enableRollback: Bool) async throws -> StoreInstallResult` runs the `update` transaction:

- `InstallRequest.mode = UPDATE`, `expected_version_code = staged.versionCode`, `expected_signer_sha256 = staged.signerDigests`, and `request_update_ownership` per §6.3.
- `enable_rollback = enableRollback && channel.capabilities.contains(.rollback)`. UpdateCore passes `true` for every update that will be health-checked. The Store Agent then calls `SessionParams.setEnableRollback(true, ROLLBACK_DATA_POLICY_RETAIN)` ([guest-components.md](guest-components.md) §8.2).
- The caller must have ended or verified the absence of sessions for the package (gentle update, [update-system.md](update-system.md) §7). The store checks again with `StoreRuntimeAccess.hasOpenSession` (§6.1): if a session exists, it fails with `packageInUse(id)` before `BeginInstall`.
- Promotion as in §5.2. On return, `previous/` holds the old set and `current/` the new one. `record.lastOperation` is `update(from:to:, healthPending: true)` until UpdateCore records the health result with `recordHealth(id, result)`.

### 7.3 Rollback

`rollback(id, reason) async throws` runs the `rollback` transaction. It needs `previous/`. Without it, it fails with `rollbackUnavailable(.noPreviousSet)`.

Android refuses a plain downgrade from a privileged installer on a `user` build. It needs `INSTALL_ALLOW_DOWNGRADE`, which only the system uid and debuggable builds or apps can use. So the rollback mechanism depends on the image:

| Image | Mechanism | App data | Capability |
|---|---|---|---|
| Custom image (`user` and `userdebug`) | **Android RollbackManager.** The update was installed with `enable_rollback`. `RollbackPackage` (op 108) finds the available rollback for the package whose `from`/`to` versions match and calls `RollbackManager.commitRollback`. The Store Agent holds `MANAGE_ROLLBACKS` and `TEST_MANAGE_ROLLBACKS` ([guest-components.md](guest-components.md) §8.1) | kept as it is now (`ROLLBACK_DATA_POLICY_RETAIN`). Data changes made by the new version are **not** reverted | `.rollback` |
| Stock `userdebug` image (development) | `adb install-multiple -r -d` with the files from `previous/` (downgrade is allowed on debuggable builds) | kept as it is now | `.downgradeReinstall` |
| Rollback not available (update installed without `enable_rollback`, the rollback expired after about 14 days, or Android dropped it) | **Only with explicit user confirmation:** "Restoring ‹App› ‹old version› requires deleting its data. Continue?" → uninstall, then install `previous/` as a first install | **deleted** | — |

- Without confirmation (background rollback), the fallback is not used. The package stays on the new version. `lastOperation` records `rollbackUnavailable`. The user gets a notification with the choices "Keep ‹new version›" and "Restore ‹old version› (erases app data)" ([update-system.md](update-system.md) §8).
- After a successful rollback, the failed set moves to `failed/<versionCode>/`. UpdateCore marks that version as skipped, so it is not staged again automatically.
- Data rollback (reverting app data to the pre-update state) is not part of v1 (#043). `ROLLBACK_DATA_POLICY_RESTORE` would make it possible on custom images. It is listed as a post-v1 candidate in [../04-plan/open-questions.md](../04-plan/open-questions.md). The UI and the docs state that app data is not rolled back.
- The RollbackManager path uses the `TEST_MANAGE_ROLLBACKS` permission. Android only allows rollbacks for arbitrary packages to installers with that permission, or to allowlisted packages with `MANAGE_ROLLBACKS`, and an allowlist is fixed in the system image. Using this permission in a production image is a deliberate choice. It is verified in #043 and tracked in [../04-plan/risks.md](../04-plan/risks.md).

---

## 8. Uninstall, keep data, forget

The Uninstall dialog (GUI) and `apkrun uninstall` (CLI) offer two choices (FR-PKG-07):

- **Keep app data** (default off). Android uninstalls with `DELETE_KEEP_DATA`. The data stays in Android, and reinstalling the same package signed by the same developer restores it. APKRun keeps `metadata.json` (state `uninstalledKeepingData`) and `settings.json`, and deletes the artifact slots.
- **Also move the Mac app to the Trash** (default on when a wrapper exists). WrapperCore does it after the store transaction commits ([wrapper.md](wrapper.md) §9, #076).

```text
uninstall(id, options)
1. journal begin(uninstall); state → uninstalling
2. withStoreAgent(.uninstall):
a. endSessions(id,.packageUninstalled) wrappers close their windows
b. journal step guestUninstallRequested
c. Uninstall(package, keep_data) → UninstallResult
3. journal step guestUninstalled
4. slots (or the whole directory) →.trash journal step filesRemoved
5. keep data: write metadata (uninstalledKeepingData), else remove the record journal step, commit
6. emit PackageChange.removed(keptData:)
```

- `Uninstall` answers `NOT_FOUND` when Android no longer has the package. The store treats that as success.
- If the runtime cannot start (for example it is not provisioned, or it is in a boot loop), the dialog offers **Remove from APKRun**, which runs `forget`. The package may stay installed in Android, and it shows up as unmanaged after the next successful boot. `apkrun uninstall --forget` does the same.
- `uninstalledKeepingData` records are listed under "Apps with kept data" in Settings → Storage with the actions **Reinstall…** (asks for the APK, and must match the recorded signer) and **Delete data** (`Uninstall` without `keep_data` for the leftover data, then `forget`).

---

## 9. Reconciling with Android

Android is canonical for package metadata (FR-PKG-02). The host record is canonical for what APKRun manages and for the artifacts.

### 9.1 When

- After every Store Agent (or, on stock images, Guest Agent) handshake: `ListManagedPackages(ALL_USER_INSTALLED)` (or `ListPackages(USER_INSTALLED)`), after the post-boot tasks of §5.5.
- On every `PackageChanged` event: `GetPackageMetadata` for that package.
- On `apkrun doctor` and on the Repair action.

### 9.2 Rules

`instance.json` holds `userdataGeneration`, a UUID that ImageCore creates whenever `userdata.img` is provisioned (first run, Reset Android) or restored from a recovery point ([android-image.md](android-image.md) §5). Each record stores the generation it was installed into (`android.userdataGeneration`).

| Host record | Android reports | Action |
|---|---|---|
| installed, same generation, same version | present | refresh `displayName`, `versionName`, `signingCertificates`, `updateOwner`, times, SDKs, ABIs |
| installed, **different generation** | absent | state → `needsReinstall(.userdataReset)`, or `needsReinstall(.userdataRestored)` after a recovery point restore. A `reinstall` transaction of `current/` runs after `ready` under a `storeOperation` assertion ([runtime-daemon.md](runtime-daemon.md) §9.5). App data is gone. Wrappers stay valid |
| installed, different generation | present, lower version (restored recovery point) | reinstall `current/` as an `UPDATE` (data is kept), then refresh |
| installed, same generation | absent | a user or app removed it inside Android (for example through Android Settings opened by an app). State → `broken(.removedInAndroid)`. Actions: **Reinstall** or **Remove from APKRun** |
| installed | present, higher version | someone else updated it (only possible without ownership enforcement, or with authority `googlePlay`/`external`). Take Android's version. `current/` no longer matches (`artifacts.currentMatchesAndroid = false`). For `apkrun`/`manual`, health warns `store.externallyUpdated`. The next APKRun update restores the match |
| installed | present, different signer set | `broken(.signerChanged)`. Only possible through an external uninstall and reinstall. Repair offers **Reinstall APKRun's copy (erases data)** or **Adopt Android's version** (authority `external`) |
| installed, `current/` missing or its file sizes differ from `artifact.json` (checked at `open`; digests are checked before every reinstall) | any | `broken(.artifactMissing)`. The app keeps working while Android has it. Repair asks for the APK again (same package, versionCode, and signer) |
| `uninstalledKeepingData` | absent or data-only | nothing |
| no record | present, user-installed | listed as unmanaged under "Other Android apps" (§9.3) |
| pending transaction | any | the transaction's recovery (§5.5) runs first |

Reinstalls triggered by reconciliation are queued in the one-at-a-time Android queue (§5.3) at background priority. The UI shows "Restoring apps (3 of 12)…".

### 9.3 Unmanaged packages and adoption

- Packages installed by `adb install` (developer mode) or, post-v1, by Google Play have no record. `listPackages(.all)` returns them with `managed = false`.
- **Adopt** (Home → Other Android apps → "Manage with APKRun", or creating a wrapper for such a package) creates a record with `installer: external`, `updateAuthority: external`, no artifact, and `source: adopted`. Such a package can have a wrapper, settings, and integrations. APKRun never updates it. It cannot be restored after Reset Android, because APKRun has no copy, and the adopt sheet says so. After a reset its record becomes `broken(.removedInAndroid)` instead of `needsReinstall`, with the Remove action.
- Post-v1 Google Play support (#097) builds on the same record shape with `updateAuthority: googlePlay`.

---

## 10. Icons and labels

### 10.1 Host preview (no VM)

- The label is the aapt2 label in the best match of the macOS preferred languages, falling back to the default label.
- Icon: aapt2 gives the icon resource for each density. If the best one is a PNG or WebP bitmap, it is decoded with ImageIO. If it is an adaptive icon whose foreground and background are bitmaps or colors, the host composes them on a 108 dp canvas (inner 72 dp shown). If a layer is a vector drawable, the preview shows a generic placeholder until the guest renders the icon. Interpreting VectorDrawables on the host is out of scope (research 2026-09-28).

### 10.2 Rendered icons (after install)

- `RenderIcon(package, 1536)` ([guest-protocol.md](guest-protocol.md) §11.1) returns the adaptive layers (foreground, background, monochrome) or a legacy bitmap. The store writes them to `icon/` with `icon.json {kind, sizePx, renderedForVersionCode, setDigest}`.
- Icons are rendered after the first install and after every update or rollback, because the icon can change with the version. When the composed result differs from the stored one, the store emits `PackageChange.iconChanged`. WrapperCore decides what to do with an existing wrapper ([wrapper.md](wrapper.md) §8). Wrappers are never modified automatically (FR-WRP-04).
- `ADBStoreAgentChannel` has no icon rendering. On stock images the host preview icon is used (§10.1).

### 10.3 Display name

`displayName` is Android's label in the guest locale, which follows macOS (§9.1 refresh). The host preview label is only used before the first install and for unmanaged packages on stock images.

---

## 11. Runtime API surface

The XPC operations are listed with their DTOs in [../03-reference/runtime-api.md](../03-reference/runtime-api.md). Their store semantics are:

### 11.1 Operations

| Operation | Behavior | Long operation |
|---|---|---|
| `importPackage(files: [FileHandle], options)` | copy, extract, inspect, check → `ImportPreview` (§4.7). No VM needed | yes (progress: copying, inspecting) |
| `installImported(ticket, InstallOptions{authority, provider, updateChoice, createWrapper})` | §6.2, or hands the ticket to UpdateCore when `relation == .update`. `updateChoice` (`.automatic` or `.notifyOnly`, from `apkrun install --updates`) is the first update choice of an `apkrun` package ([update-system.md](update-system.md) §2.3). nil keeps the default | yes |
| `cancelImport(ticket)` | deletes the ticket | no |
| `inspectFile(files)` | the same as `importPackage` but deletes the ticket afterwards. For `apkrun inspect` | yes |
| `listPackages(filter:.managed /.all)` | records plus unmanaged packages from the last reconcile. Works while the runtime is stopped (last known Android facts) | no |
| `packageInfo(id)` | `PackageDetails`: record, settings summary, slots, sizes, wrapper count (from WrapperCore), last operation | no |
| `uninstallPackage(id, UninstallOptions{keepData, trashWrappers, forget})` | §8 | yes |
| `repairPackage(id)` | `broken` → `reinstall` of `current/`, or `forget` if the user chose it | yes |
| `rollbackPackage(id, allowDataLoss)` | user-initiated rollback to `previous/` (§7.3). With `allowDataLoss = false`, a rollback that needs the data-loss fallback fails with `rollbackUnavailable` so the client can ask; the client repeats the call with `true` after the user confirms | yes |
| `adoptPackage(id)` | §9.3 | no |
| `updatePackageSettings(id, patch)` | validated JSON merge patch on `PackageSettings` | no |
| `packageIcon(id, sizePx)` | PNG composed from `icon/` (or the host preview) | no |

#027's `install`, `uninstall`, `listInstalled`, and `applicationInfo` map to `importPackage` + `installImported`, `uninstallPackage`, `listPackages(.managed)`, and `packageInfo`. `launch` and `terminate` are session operations ([runtime-daemon.md](runtime-daemon.md) §7).

### 11.2 Authorization

Store operations are available on the `.control` endpoint only. A wrapper endpoint gets `packageInfo` and `packageIcon` for its own package and nothing else (NFR-SEC-07, [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).

### 11.3 Events

Topic `packages` on the event stream ([runtime-daemon.md](runtime-daemon.md) §8.4). On the wire, `PackageState` is sent as `WirePackageState`, and `StoreOperationProgress` is defined in [../03-reference/runtime-api.md](../03-reference/runtime-api.md) §16.2:

```swift
public enum PackageChange: Codable, Sendable {
    case installed(PackageSummary)
    case updated(PackageSummary, from: VersionCode) // also a same-version reinstall (from == to)
    case rolledBack(PackageSummary, from: VersionCode)
    case removed(PackageID, keptData: Bool)
    case stateChanged(PackageID, PackageState)
    case operationProgress(PackageID, OperationID, StoreOperationProgress) // coalesced to 10 Hz
    case iconChanged(PackageID)
    case settingsChanged(PackageID, keys: [String])
    case unmanagedChanged([PackageSummary])
}
```

### 11.4 CLI

The full syntax is in [cli.md](cli.md). The store commands are:

```text
apkrun install <file>… [--yes] [--provider <spec>] [--updates automatic|notify|manual] [--wrap [--output <dir>]]
apkrun uninstall <package> [--keep-data] [--keep-wrapper] [--forget] [--yes]
apkrun list [--all] [--json]
apkrun info <package> [--json]
apkrun inspect <file>… [--json] # no VM, no install
apkrun repair <package>
apkrun rollback <package> [--allow-data-loss] [--yes]
apkrun adopt <package>
```

`--yes` skips the confirmation step of `inspecting → installing` ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §5). Without it, the CLI prints the preview and asks.

---

## 12. Errors

`StoreFailure` is the error domain of APKStoreCore. Codes, user messages, and remediations are listed in [../03-reference/error-catalog.md](../03-reference/error-catalog.md).

```swift
public enum StoreFailure: APKRunError {
    // import and inspection (§4)
    case unsupportedContainer(ContainerKind) //.appBundle,.encryptedAPKM,.unknown
    case unreadableArchive(detail: String)
    case archiveLimitExceeded(ArchiveLimit)
    case notAnAPK(file: String)
    case missingBase, multipleBases, duplicateSplit(name: String)
    case inconsistentSplits(InconsistentField, file: String)
    case incompleteSplitSet(missing: [String])
    case unsignedAPK(file: String)
    case invalidSignature(file: String, reason: String)
    case legacySignatureNotAllowed(targetSdk: Int)
    case unsupportedABI(found: [String], supported: [String])
    case minSdkTooHigh(required: Int, guest: Int)
    case targetSdkTooLow(target: Int, floor: Int)
    case expansionFilesNotSupported
    case reservedPackage(PackageID)
    case tooLarge(bytes: Int64, limit: Int64)
    case resourcesArscNotAligned(file: String)
    case insufficientHostSpace(needed: Int64, available: Int64)
    case importExpired(ImportTicket)
    // relation to an installed package (§4.7)
    case alreadyInstalled(VersionCode)
    case downgradeRefused(installed: VersionCode, candidate: VersionCode)
    case signerMismatch
    // operations
    case packageNotFound(PackageID)
    case operationInProgress(PackageID)
    case packageInUse(PackageID)
    case guestInstallFailed(InstallFailureKind, androidStatus: Int32, legacyStatus: String?, message: String)
    case guestStorageFull
    case userActionRequired
    case uninstallFailed(detail: String)
    case rollbackUnavailable(RollbackUnavailableReason) //.noPreviousSet,.notEnabled,.expired,.capabilityMissing
    case rollbackFailed(detail: String)
    case runtimeUnavailable(RuntimeFailure)
    case capabilityMissing(String)
    // package settings (configuration.md §8.1)
    case unknownSetting(key: String) // a package settings key that does not exist
    case invalidSettingValue(key: String, allowed: String) // a value of the wrong type or outside the allowed values
    // store integrity
    case journalUnreadable(line: Int)
    case metadataUnreadable(PackageID, detail: String)
    case storeReadOnly(reason: String)
    // health findings (§13), never thrown
    case journalLineDropped // store.journal: a torn last line was dropped
    case postBootTaskRequeued // store.pending: a post-boot task was re-queued twice
    case updateOwnerMissing(count: Int) // store.ownership
    case updatedOutsideAPKRun(count: Int) // store.externallyUpdated
    case reinstallPending(count: Int) // store.packages: packages in needsReinstall for more than one boot
    case packagesNeedRepair(count: Int) // store.packages: packages that are broken
}

public enum ArchiveLimit: String, Sendable, Codable { // the extraction limits of §4.2
    case entryCount, apkCount, fileSize, totalSize, compressionRatio, unsafeName
}

public enum InconsistentField: String, Sendable, Codable { // I4, I5 (§4.6)
    case package, versionCode, signer
}

public enum InstallFailureKind: String, Sendable, Codable { // InstallFinished.status (§6.4)
    case conflict, incompatible, invalid, blocked, aborted, other
}
```

Messages never include file paths from the user's disk at `info` level or above. They include the package ID and the file's name inside the set (`split_config.arm64_v8a.apk`).

---

## 13. Logging, markers, health

- `os_log` subsystem `io.apkrun.store`, categories `import`, `transaction`, `channel`, `reconcile`. Logged: transaction begins, steps, commits and aborts with `txn`, package ID, versionCodes, and set digests; channel calls with durations; Android statuses. Not logged: file paths outside `Packages/`, the permission list, or labels at `info` and above.
- Perf markers ([diagnostics.md](diagnostics.md) §4): `PACKAGE_IMPORT_START`, `PACKAGE_INSPECTED`, `PACKAGE_INSTALL_START`, `PACKAGE_INSTALL_COMPLETE`, `PACKAGE_ROLLBACK_COMPLETE`.
- Metrics (in `apkrun doctor --deep` and diagnostics bundles): inspection time per MiB, install throughput (MiB/s from `RECEIVING`), time in `COMMITTING`, verifier disagreements.

| Health check | Warning | Error |
|---|---|---|
| `store.journal` | a torn last line was dropped (`store.journalLineDropped`) | journal unreadable (store read-only, `store.journalUnreadable`) |
| `store.packages` | a package in `needsReinstall` for more than one boot (`store.reinstallPending`) | any package `broken` (`store.packagesNeedRepair`) |
| `store.ownership` | an `apkrun`/`manual` package whose update owner is not `io.apkrun.store` (on a custom image, `store.updateOwnerMissing`) | — |
| `store.externallyUpdated` | an `apkrun`/`manual` package updated by another installer (`store.updatedOutsideAPKRun`) | — |
| `store.hostSpace` | free space below 5 GiB (`diagnostics.lowDiskSpace`) | below 2 GiB (imports and staging refused, `store.insufficientHostSpace`) |
| `store.pending` | a post-boot task re-queued twice (`store.postBootTaskRequeued`) | — |

---

## 14. Security notes

- APKs, containers, and their metadata are untrusted input (NFR-SEC-01). The parsers that see them are the ZIP reader, aapt2 (sandboxed subprocess), and the signature verifier. All three are fuzz targets in #091 (ZIP and signing-block parsers with libFuzzer, aapt2 output parser with the recorded outputs as a seed corpus).
- The host never executes, loads, or `dlopen`s anything from an APK.
- Package IDs from APKs and from the guest are validated against the grammar (§2.1) before they are used in a path, a bundle ID, or a log line.
- Artifacts are sent to the guest only on the Store Agent artifact stream or through `adb install-multiple`. They are never placed in the shared folder.
- The store never offers "install anyway" for a failed signature, ABI, or SDK check. The only way around a check is a different APK.

---

## 15. Implementation steps

Each task lists the store-side steps. Update policy steps for the same task numbers are in [update-system.md](update-system.md) §15.

### #027 RuntimeCore package operations on the stock image (M3)

1. `APKStoreCore` target with `PackageID`, `VersionCode`, `SHA256Digest`, `ArtifactFile`, `ArtifactSet`, `PackageRecord` (fields as in §2.3; `updateAuthority` fixed to `manual`), and `PackageState`.
2. `PackageStore` actor with `open`, the journal (§5.1), and the kinds `firstInstall`, `reinstall`, `uninstall`, and `forget`, including recovery (§5.5) and fault-injection hooks (`APKRUN_STORE_FAULT=<kind>:<step>` crashes the process after that step in debug builds).
3. `APKInspector` v0: single APKs and several `.apk` files as a split set, through aapt2 and SHA-256. The signature check is recorded as `notPerformed`, and Android verifies at install.
4. `ADBStoreAgentChannel` (install, uninstall, `QueryPackage`, `ListPackages`) and a `StoreRuntimeAccess` implementation in `EmbeddedRuntimeService`.
5. `RuntimeService` store operations `importPackage`, `installImported`, `listPackages`, `packageInfo`, and `uninstallPackage`, with CLI commands `install`, `uninstall`, `list`, and `info` in embedded mode.
6. Acceptance: the CLI and the tests use RuntimeCore, not raw shell commands. A CI lint rejects `adb shell` and `pm ` strings outside `ADBStoreAgentChannel`, `AdbClient` (RuntimeCore, built in #015), and the allowlist of [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.3 (development scripts, the compatibility runner, and the reference capture tools). `apkrun install HelloText.apk --yes` produces `Packages/io.apkrun.fixture.hellotext/current/base.apk`, `artifact.json`, and `metadata.json`, and `apkrun list` shows the versionCode that Android reports. A fault-injection run of every step of `firstInstall` and `uninstall` leaves a consistent store after restart (T1).

### #036 Store Agent channel (M5, store side)

1. `StoreAgentSupervisor` implements `StoreAgentChannel` over the Store Agent protocol. Handshake, capabilities, artifact streaming with progress, and `InstallFinished` handling (§6.4).
2. `GetPackageMetadata` refresh after install. Icon rendering (`RenderIcon` → `icon/`, §10.2) follows in #055. Until then the host preview icon is used.
3. Reconciliation v1 (§9.1–§9.2) on Store Agent handshakes and `PackageChanged`.
4. The channel is chosen from the image (custom image → Store Agent).
5. Acceptance: with ADB disabled in the image, `apkrun install HelloText.apk --yes` installs through the Store Agent. The `adb` process counter stays at zero. `apkrun info` shows `io.apkrun.store` as the installer of record.

### #066 Reinstall after Reset Android (M4, store side)

1. `userdataGeneration` in `instance.json` (ImageCore creates it at provisioning and restore) and in records.
2. The reconciliation rule for a different generation (§9.2) and the background reinstall queue with progress.
3. Acceptance: install two fixtures (HelloText and HelloUpdate V1), run Reset Android. After `ready`, both are reinstalled from `current/` without user action, and their settings are unchanged. Launching each one with `apkrun launch` (the generic launcher of #068; wrappers come in M7) shows its first frame.

### #073 Host inspection and import formats (M6)

1. Container detection and extraction with the limits of §4.2 (`.apks`, `.xapk`, `.apkm`, `.zip`; refusals for `.aab`, encrypted `.apkm`, and OBB expansions).
2. `SplitSelector` (§4.4).
3. `APKSignatureVerifier` (§4.5) with test vectors, plus the corpus script.
4. `ArtifactVerifier` intrinsic checks I1–I12 (§4.6) and warnings.
5. `ImportPreview` with host labels and the host icon preview (§10.1). `apkrun inspect`.
6. aapt2 sandbox profile and timeouts.
7. `adoptPackage` and `apkrun adopt` (§9.3, [cli.md](cli.md) §4.2): a record with authority `external` and no artifact.
8. Acceptance: the fixture matrix in §16 passes. For 50 real F-Droid APKs, the verifier's signer digests equal `apksigner`'s, and `apkrun inspect` finishes in under 1 s per APK of 50 MiB on the reference Mac.

### #037 Update types (M6, store side)

1. `UpdateAuthority` and `UpdateProviderRef` in the record. `claimsUpdateOwnership` (§6.3). Default authority `manual` for file imports.
2. The `stage` and `discardStaged` transactions and `artifacts.staged` (§7.1).
3. Acceptance: covered by the acceptance of #037 in [update-system.md](update-system.md) §15 #037 (the LocalProvider finds V2 while V1 is installed), with the staged set visible in `apkrun info`.

### #038 PackageInstaller updates (M6, store side)

1. The `update` transaction with `renamex_np(RENAME_SWAP)` promotion (§5.2, §7.2) on both channels.
2. `ImportRelation.update` hands file imports to UpdateCore.
3. Acceptance: HelloUpdate V1 installed; the fixture writes a known file into its data directory; V2 installed through `installStaged`. `versionCode` increased, the file is still readable by V2, and a V2 signed with another key is refused by the host (`signerMismatch`). Android's own refusal is shown separately: the T2 test installs that V2 over V1 directly with `AdbClient.install(apk:)`, which fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. No build has a switch that disables the host check ([../../AGENTS.md](../../AGENTS.md) §4, invariant 10). Fault injection over every `update` step leaves a consistent store (T1 for host steps, T2 for `guestCommitRequested`).

### #039 Update ownership (M6, store side)

1. `request_update_ownership` from §6.3. `PackageStore.setUpdateAuthority` with `RelinquishUpdateOwnership` (op 109) before the record write, as a post-boot task when the runtime is not ready (§6.3). Record `android.updateOwner`.
2. Verify on the custom image whether ownership is granted on an update of a package that has no owner, and record the result in §6.3.
3. Acceptance: the APKRun-managed fixture reports `updateOwner == io.apkrun.store`. The OtherInstaller fixture app (`io.apkrun.fixture.otherinstaller`, with `REQUEST_INSTALL_PACKAGES`) cannot update it without user action (the session ends with `STATUS_PENDING_USER_ACTION`, and the version stays unchanged). After `apkrun update authority <package> external`, the owner is cleared.

### #041 Package and signature verification (M6, store side)

1. The primitives used by UpdateCore's relational checks: signer-set comparison with lineage capabilities (`INSTALLED_DATA` for updates, `ROLLBACK` for rotation back), `VersionCode` comparison, and set-digest comparison.
2. Acceptance with UpdateCore: valid upgrade, wrong package, wrong signer, downgrade, and a corrupted APK (one flipped byte in `classes.dex` → `invalidSignature`) are covered by T0 tests over fixtures.

### #042 Split APK installation (M6)

1. Split sets on both channels in one `PackageInstaller` session (`adb install-multiple`, Store Agent session with several artifacts).
2. Acceptance: HelloSplit (base + `config.arm64_v8a` + `config.xhdpi` + `config.ja` + an install-time feature split) imported from `.apks` installs and launches. Its native library loads, and with the guest locale set to `ja-JP` (through `AdbClient` in developer mode) it shows the Japanese string. Switching macOS to Japanese needs the locale sync of #085, so that check is made in #085. The density choice is recorded in [../04-plan/open-questions.md](../04-plan/open-questions.md).

### #043 Update rollback (M6, store side)

1. `enable_rollback` in `InstallRequest`, `RollbackPackage` (op 108) in the Store Agent, and the `rollback` transaction (§7.3).
2. The development path (`install-multiple -r -d`), and the confirmed data-loss fallback.
3. Verify on the custom `user` image that `setEnableRollback` with `TEST_MANAGE_ROLLBACKS` makes a rollback available for a third-party package and that `commitRollback` restores the previous version. Record the result in §7.3 and in the risk entry.
4. Acceptance: HelloUpdate V3-broken (crashes 2 s after launch) is installed over V2. The health check fails, and the package is rolled back to V2 on both image kinds. A file written by V2 before the update is still there. The UI and the notification state that app data is not rolled back.

### #048 Wrapper independent of the APK path (M7, store side)

1. Confirm that nothing stores or re-reads the import source after `beginImport` (a T1 test deletes the source right after the call).
2. Acceptance with WrapperCore: the original APK is deleted, and the wrapper still launches the installed package.

### #076 Uninstall with choices (M7, store side)

1. `UninstallOptions` (§8), `DELETE_KEEP_DATA`, `uninstalledKeepingData` records, "Apps with kept data" in Settings → Storage.
2. Acceptance: uninstall with "Keep app data", then reinstall the same APK. The data file written before is back. Uninstall without keeping data removes `Packages/<id>/` and, when chosen, the wrapper is in the Trash.

---

## 16. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | `PackageID` grammar; `VersionCode` from `versionCodeMajor`; set digest stability | #027 |
| T0 | Journal: encode/decode, torn last line, `seq` gap, compaction, newer `v` → read-only | #027 |
| T0 | Recovery table (§5.5): every kind × every step, on a temporary store with a fake channel whose Android state is scripted (installed, not installed, other version) | #027, #038, #043 |
| T0 | Container fixtures: `.apk`, split files, `.apks` from bundletool, `.xapk` without OBB, `.xapk` with OBB (refused), `.apkm` plain, `.apkm` non-ZIP (refused), `.aab` (refused), zip bomb, `../` entry, symlink entry, 600 entries, a ZIP64 container generated at test time (ADR-0017) | #073 |
| T0 | Split selection over a generated `.apks` with 3 ABIs, 6 densities, 10 languages, one feature split, and `requiredSplitTypes` | #042, #073 |
| T0 | Signature verifier: apksig test vectors (v2, v3, v3.1, rotated lineage, multiple signers, RSA/ECDSA SHA-256/512, DSA → certificate-only, v1-only with targetSdk 29 and 30, bad digest, bad signature, truncated block) | #073 |
| T0 | Intrinsic checks I1–I12, one fixture per failure | #073, #041 |
| T0 | Relation classification (§4.7) and routing of updates to UpdateCore | #038 |
| T1 | `PackageStore` with a fake `StoreAgentChannel`: first install, update, rollback, uninstall with and without keep data, forget, concurrent requests (`operationInProgress`), queue priorities | #027, #038, #043, #076 |
| T1 | Crash injection with a real process: `APKRUN_STORE_FAULT` at every host step, restart, `open` result checked | #027, #038 |
| T1 | aapt2 parser golden outputs for the pinned aapt2 version | #073 |
| T1 | Source deleted after `beginImport`, install still succeeds | #048 |
| T2 | Stock image, ADB channel: install, split install, uninstall, reinstall, downgrade reinstall (`-d`) | #027, #042, #043 |
| T2 | Custom image, Store Agent: install without ADB, update ownership and the OtherInstaller fixture, update with data kept, broken update rollback through RollbackManager, keep-data uninstall and restore, icon rendering | #036, #038, #039, #043, #055, #076 |
| T2 | Kill apkrund during `CommitInstall`, restart, check the post-boot resolution (both outcomes, forced by timing the kill before and after commit) | #038 |
| T2 | Reset Android → automatic reinstall of all packages | #066 |
| T3 | 50-APK F-Droid corpus: inspect, install, launch smoke (nightly) | #073, #090 |

Fixtures live in `Tests/Fixtures/AndroidApps/` ([../05-development/build-system.md](../05-development/build-system.md)); the full list is in [../04-plan/test-strategy.md](../04-plan/test-strategy.md) §4. The store tests use HelloText, HelloUpdate V1/V2/V2-other-signer/V3-broken/V4, the corrupted V2, and the rotation variants, HelloSplit, HelloNative (arm64 and 32-bit-only variants), HelloLegacySig (v1 only, targetSdk 29), and OtherInstaller. They are built and signed with test keys checked into the repository, clearly marked as test keys.

---

## 17. Open items

Recorded in [../04-plan/open-questions.md](../04-plan/open-questions.md) and [../04-plan/risks.md](../04-plan/risks.md):

- RollbackManager with `TEST_MANAGE_ROLLBACKS` on `user` builds (#043). If it does not work, rollback on custom images falls back to the confirmed data-loss path, and FR-UPD-11 needs a note.
- Whether Android grants update ownership when an owner-less package is updated with `setRequestUpdateOwnership(true)` (#039).
- OBB expansion files for `.xapk` (v1.x candidate: push through the Store Agent into `Android/obb/<pkg>/`).
- Density split choice for `.apks` (#042).
- Host verifier false rejections in the field (tracked with the `verifier.disagreement` event).
- Data rollback with `ROLLBACK_DATA_POLICY_RESTORE` (post-v1).

---

## 18. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| On the stock image, do install, split install, keep-data uninstall, reinstall, and downgrade reinstall through `ADBStoreAgentChannel` behave as §15 #027 says? | #027 | pending ([guest-protocol.md](guest-protocol.md) §13.2; §15 #027) |
| Does Android grant update ownership when an owner-less package is updated with `setRequestUpdateOwnership(true)`? | #039 | pending (§6.3, OQ-12) |
| Density split choice for `.apks` sets and its quality effect | #042 | pending (§4.4, OQ-14) |
| On the custom `user` image, does `setEnableRollback` with `TEST_MANAGE_ROLLBACKS` make a rollback available, and does `commitRollback` restore the previous version? | #043 | pending (§7.3, OQ-11) |
| Share of the corpus apps that the install floors refuse (R-15) | #090 | pending (§4.6) |
| How often the host verifier rejects what Android would accept (`verifier.disagreement`) | field data after v0.4 | pending (§4.5, OQ-15) |
