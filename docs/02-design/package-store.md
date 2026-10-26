# Package Store

This document covers how APKRun imports Android packages, keeps them on the host, and installs them into Android: the on-disk store, journaled transactions, install and uninstall, reconciliation with Android, and the store side of updates and rollback. When to update, the providers, the validation pipeline, and the health check are in [update-system.md](update-system.md).

---

## 1. Responsibilities

| Concern | Owner | Notes |
|---|---|---|
| Records, settings, artifact directories, the journal | `PackageStore` (APKStoreCore) | The only writer of `Packages/` |
| Import, split sets, containers, host preview | `PackageImporter`, `APKInspector` (APKStoreCore) | Works with the VM stopped (FR-PKG-03) |
| Intrinsic artifact checks | `ArtifactVerifier` (APKStoreCore) | §4.6. UpdateCore uses it too |
| Relational update checks | UpdateCore | [update-system.md](update-system.md) §6 |
| Getting packages into Android | Store Agent through `StoreAgentChannel` (custom image), `ADBStoreAgentChannel` (stock image) | Always `PackageInstaller` (FR-PKG-01). Never copy files into `/data/app` |
| Canonical package metadata | Android `PackageManager` | FR-PKG-02. Host values are a preview until Android's values replace them (§9) |
| When to install, gentle windows, health check, rollback decision | UpdateCore | The store executes. UpdateCore decides |
| Wrappers | WrapperCore | The store emits `PackageChange` events (§11.3) |

APKStoreCore reaches the guest only through `StoreAgentChannel`. RuntimeHost implements the channel and `StoreRuntimeAccess`. APKStoreCore does not import RuntimeCore ([modules.md](../01-architecture/modules.md) §3).

---

## 2. Concepts and types

### 2.1 Identity and versions

```swift
/// An Android package name: two or more segments of [A-Za-z][A-Za-z0-9_]*, joined with ".", at most 255 characters.
public struct PackageID: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public let rawValue: String
    public init?(rawValue: String)
}

/// Android's non-negative longVersionCode: versionCodeMajor in the high 32 bits, versionCode in the low 32 bits.
public typealias VersionCode = Int64

/// Lowercase hex SHA-256 of a DER certificate or a file. Serialized as "sha256:<64 hex>".
public struct SHA256Digest: Codable, Sendable, Hashable { … }
```

- Android package names are case-sensitive. The default APFS volume is not. Resolve directories through the index (§3.2). Never build `Packages/<id>` paths by string concatenation outside `APKRunPaths`.
- `VersionCode` is non-negative. Reject negative values from APK metadata, Android facts, or persisted files. Never normalize them to zero or compare them.
- Compare versions only by `VersionCode` (`longVersionCode`). `versionName` is for display.

### 2.2 Artifacts

`PackageArtifact` is the input. The store turns it into a verified set on disk.

```swift
public enum PackageArtifact: Sendable, Hashable {
    case apk(URL)
    case splitSet(base: URL, splits: [URL])
}

public struct ArtifactFile: Codable, Sendable, Hashable {
    public var name: String          // "base.apk", "split_config.arm64_v8a.apk", …
    public var splitName: String?    // nil for the base; "config.arm64_v8a", "feature_camera", …
    public var size: Int64
    public var sha256: SHA256Digest
}

/// The content of artifact.json in current/, previous/, staged/.
public struct ArtifactSet: Codable, Sendable, Hashable {
    public var schemaVersion: Int              // 1
    public var packageID: PackageID
    public var versionCode: VersionCode
    public var versionName: String?
    public var files: [ArtifactFile]           // base first, then splits sorted by splitName
    public var setDigest: SHA256Digest         // §3.3
    public var signerDigests: [SHA256Digest]   // the signer set Android uses on the guest SDK (§4.5)
    public var lineage: [SHA256Digest]         // oldest → newest; empty without rotation
    public var inspection: InspectionProvenance // aapt2 version, verifier version, date, host checks performed
}
```

### 2.3 Package record

`metadata.json` holds a `PackageRecord`. Its JSON schema is in [package-metadata-json.md](../03-reference/package-metadata-json.md) §2.3.

```swift
public struct PackageRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int                    // 1
    public var packageId: PackageID
    public var displayName: String                   // Android label in the guest locale (§10.3)
    public var versionCode: VersionCode              // what Android reports as installed
    public var versionName: String?
    public var signingCertificates: [SHA256Digest]   // current signer set
    public var signingLineage: [SHA256Digest]
    public var installer: Installer                  // .apkrun, .external
    public var updateAuthority: UpdateAuthority      // .apkrun, .googlePlay, .external, .manual (ADR-0010)
    public var updateProvider: UpdateProviderRef?    // nil = none (update-system.md §4)
    public var state: PackageState                   // state-machines.md §5
    public var artifacts: ArtifactSlots              // summaries of current / previous / staged
    public var android: AndroidPackageFacts          // updateOwner, installerOfRecord, times, SDKs, ABIs, userdataGeneration, lastSyncedAt
    public var source: PackageSource                 // file, provider, wrapperBootstrap, adopted
    public var lastOperation: OperationSummary?      // last install, update, rollback, uninstall, or adopt result
    public var createdAt: Date
    public var updatedAt: Date
}

public enum Installer: String, Codable, Sendable { case apkrun, external }
```

- `ArtifactSlots`, `AndroidPackageFacts`, `PackageSource`, and `OperationSummary` are defined in [package-metadata-json.md](../03-reference/package-metadata-json.md) §2.3.2–§2.3.5.
- `UpdateAuthority` is defined here because the record stores it. UpdateCore owns the policy ([update-system.md](update-system.md) §2).
- A package that Android has but APKRun does not manage has no record. It is unmanaged until adopted (§9.3).

### 2.4 Package settings

`settings.json` holds `PackageSettings`. Keys (groups `update.*`, `window.*`, `input.*`, `integrations.*`) and defaults are in [package-metadata-json.md](../03-reference/package-metadata-json.md) §3.

- Settings survive updates, rollbacks, reinstalls, and Reset Android. Uninstall deletes them unless the user keeps app data (§8).
- The store validates writes and emits `PackageChange.settingsChanged`. Consumers (sessions, IntegrationCore, UpdateCore) read `PackageStore.settings(for:)` and do not cache across that event.

### 2.5 States

`PackageState`, `ReinstallReason`, `BrokenReason`, and their transitions are in [state-machines.md](../01-architecture/state-machines.md) §5. The store owns them.

| State | Can launch | Can update | Shown as |
|---|---|---|---|
| `installed` | yes | yes | normal |
| `updating(_)` | yes. The install waits until no session is open ([update-system.md](update-system.md) §7) | — | progress on the row |
| `needsReinstall` | no. `openSession` answers `packageNotInstalled` | no | "Restoring…" |
| `uninstalledKeepingData` | no | no | Settings → Storage → Apps with kept data |
| `broken(_)` | `removedInAndroid` and `artifactMissing`: only if Android still has the package. `signerChanged`: yes | no | warning badge with Repair |

---

## 3. On-disk layout

### 3.1 Per-package directory

```text
Packages/
├── journal.jsonl
├── android-inventory.json                # last PackageManager inventory returned by the Guest Agent
├── .trash/                               # directories moved out by committed transactions; purged in the background
│   └── <txn>-<slot>/
└── <dir>/                                # usually the package ID (§3.2)
    ├── metadata.json                     # PackageRecord
    ├── settings.json                     # PackageSettings
    ├── current/                          # what Android should have installed
    │   ├── artifact.json
    │   ├── base.apk
    │   └── split_<splitName>.apk …
    ├── previous/                         # last known-good set, present after an update until the next update
    ├── staged/                           # verified update waiting for an install window (UpdateCore)
    │   └── validation.json               # UpdateCore's validation report (update-system.md §6); not part of setDigest
    ├── incoming/<ticket>/                # imports and downloads being inspected; never referenced by a record
    ├── failed/<versionCode>/             # a set that was rolled back; kept 7 days, then deleted
    └── icon/                             # rendered icon layers (§10)
```

- Set file names are fixed: `base.apk` and `split_<splitName>.apk`. `PackageInstaller` session names match without the extension ([guest-protocol.md](guest-protocol.md) §11.3). The original file names of an import appear only in `source`. For example, `apkrun install HelloText.apk --yes` writes `Packages/io.apkrun.fixture.hellotext/current/base.apk`, `artifact.json`, and `metadata.json`.
- `artifact.json` makes each slot self-describing. Recovery identifies a directory by `setDigest`, never by name alone.
- At most one set per slot. A newer staged set replaces the older one (§5.2, kind `stage`).
- `incoming/<ticket>/` is scratch space. An `install` or `stage` transaction renames it into a slot. Tickets that no transaction references are deleted at `open()` and after 24 h.
- `failed/` sets are deleted after 7 days or on uninstall. Diagnostics include them as metadata only (names, sizes, digests).
- `android-inventory.json` is an atomically replaced, schema-versioned copy of the last full Android package list. `listPackages(.all)` uses it while Android is stopped.

### 3.2 Directory names

- The directory name is the package ID (`Packages/com.discord/`).
- If another directory has the same name ignoring case (for example `com.Foo` and `com.foo`), the new one is `<packageId>~<first 8 hex of SHA-256(packageId)>`. Wrapper bundle IDs use another rule ([wrapper.md](wrapper.md) §4.1).
- `open()` builds the `PackageID → directory` index from each `metadata.json`. A directory without `metadata.json` moves to `.trash/` with a health warning, after the journal check (§5.5). A directory whose `metadata.json` exists but cannot be read is never moved. Its package ID comes from the name, and the package is read-only (§5.4).

### 3.3 Set digest

`setDigest` is the SHA-256 over the UTF-8 lines `"<name>\t<sha256 hex>\n"`, one per file, sorted by `name`.

The digest proves that two host sets hold the same bytes under the same names. It does not prove that Android still has those bytes. A client must not skip an installation on this digest alone, unless the guest confirms the installed APK bytes.

### 3.4 Space

| Check | When | Rule |
|---|---|---|
| Host free space before import | `beginImport` | free ≥ 2 × source size + 2 GiB. Otherwise `StoreFailure.insufficientHostSpace(needed, available)` |
| Host free space before staging | `stage` | free ≥ set size + 2 GiB |
| Guest free space | at install | Android decides. The Store Agent temporarily keeps one private verification copy alongside the `PackageInstaller` session, so the install set needs additional temporary guest space until pre-commit verification finishes. `STATUS_FAILURE_STORAGE` becomes `StoreFailure.guestStorageFull`. Remediation: Settings → Runtime (`runtime.userdataGiB`) ([error-catalog.md](../03-reference/error-catalog.md) §10) |
| Store size | Settings → Storage | current + previous + staged + failed + icons. "Remove previous version" frees `previous/` and disables rollback until the next update |

Import uses `clonefile(2)` when the source is on the same APFS volume. Otherwise it streams the copy and hashes it. After `beginImport` returns, nothing refers to the source file. The user may delete the original APK (#49).

---

## 4. Import and inspection

### 4.1 Sources

| Source | Entry point | Notes |
|---|---|---|
| Files dropped on APKRun.app, the Add sheet, or the Dock icon | `RuntimeService.importPackage` with file handles | The GUI passes open file descriptors over XPC ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.1). apkrund needs no TCC consent for `~/Downloads` or `~/Desktop` |
| `apkrun install <file…>` | same, with file handles opened by the CLI | Several `.apk` files form one split set |
| Provider download | `PackageStore.beginDownloadTicket(id)` gives a ticket. The provider writes into `incoming/<ticket>/`. UpdateCore calls `PackageStore.inspect(ticket)` | [update-system.md](update-system.md) §5 |
| Portable wrapper bootstrap | `importBootstrap` with a file handle for `Contents/Resources/bootstrap/` | First import on a new Mac only (#90, [wrapper.md](wrapper.md)) |
| Adoption | `adoptPackage(id)` | no artifact (§9.3) |

A set holds at most 256 APKs (§4.2). The daemon's XPC endpoint and `apkrun install` allow 20 file handles per request. That transport limit does not change the store's limit.

### 4.2 Containers

| Format | Detected by | Handling |
|---|---|---|
| `.apk` | ZIP with `AndroidManifest.xml` at the root | one file, or several dropped together as one split set |
| `.apks` (bundletool) | ZIP with `toc.pb` and `splits/` | extract the APKs under `splits/`. Ignore `standalones/`. A lone `universal.apk` is a single APK. Selection (§4.4) uses the split manifests, not `toc.pb` |
| `.xapk` (APKPure) | ZIP with `manifest.json` containing `xapk_version` | extract `split_apks[].file`, or the single APK. **Expansions (OBB) are refused in v1:** `StoreFailure.expansionFilesNotSupported` (OQ-13) |
| `.apkm` (APKMirror) | ZIP with `info.json` containing `apkm_version` | extract the APKs. Encrypted or non-ZIP: `unsupportedContainer(.encryptedAPKM)` |
| `.zip` with APKs only | ZIP whose entries are all `*.apk` | like several dropped `.apk` files |
| `.aab` | ZIP with `BundleConfig.pb` | refused: `unsupportedContainer(.appBundle)`. Converting would re-sign the bundle, which breaks updates |
| anything else | | `unsupportedContainer(.unknown)` |

Detection uses content, never the extension alone. ZIP reading uses ZIPFoundation (MIT, `exact:` pin, ADR-0017) through `ContainerReader`. It checks the limits below while streaming and never uses extract-to-directory functions. The signature verifier reads the ZIP structures directly (§4.5).

**Extraction limits.** A violation fails with `archiveLimitExceeded`:

- at most 512 entries per container and 256 APKs;
- each file ≤ 2 GiB ([guest-protocol.md](guest-protocol.md) §10), total ≤ 8 GiB;
- compression ratio ≤ 100:1 per entry, checked while streaming;
- names are valid UTF-8 and relative, with no `..`. No symlink or device entries. Extracted files get fixed names in `incoming/<ticket>/`.

### 4.3 APKInspector

`APKInspector` produces an `APKFacts` value for each APK, on the host, without a VM.

| Fact | Tool | Notes |
|---|---|---|
| package, `versionCode` + `versionCodeMajor` → `VersionCode`, `versionName`, split name, `minSdkVersion`, `targetSdkVersion`, labels, icon paths per density, `native-code`, `uses-permission`, `uses-feature` | `aapt2 dump badging` | aapt2 is bundled at `Contents/Resources/tools/aapt2` (Apache-2.0, pinned, [filesystem-layout.md](../01-architecture/filesystem-layout.md) §4) |
| `isFeatureSplit`, `configForSplit`, `isSplitRequired`, `requiredSplitTypes`, `splitTypes`, `dist:module`, `debuggable`, `sharedUserId`, `extractNativeLibs` | `aapt2 dump xmltree --file AndroidManifest.xml` | only these attributes are read |
| native libraries by ABI | ZIP central directory (`lib/<abi>/*.so`) | cross-checks `native-code` |
| signer set, lineage, scheme | `APKSignatureVerifier` (§4.5) | native Swift |
| size, SHA-256 | streaming hash | during the copy |

- aapt2 runs as a subprocess: 20 s timeout per call, 16 MiB output cap, `LANG=C`. A tolerant parser reads its output. Golden tests cover the pinned version. Updating aapt2 requires re-running them (#74).
- aapt2 parses untrusted input. It runs under a `sandbox-exec` profile that denies process creation, network, and writes, and allows reads only of the ticket directory, the tool, and the system files it needs (#92). Without `sandbox-exec`, aapt2 runs unsandboxed and a warning is logged.
- `apkrun dev launch <apk>` (development only) uses the same 2 GiB per-file limit. It checks the source size before staging and enforces the limit while it streams the private copy.
- The inspector never executes anything from an APK.

### 4.4 Split sets and split selection

A split set follows Android's rules: every APK has the same package, versionCode, and signer; split names are unique; there is exactly one base ([PackageInstaller](https://developer.android.com/reference/android/content/pm/PackageInstaller)).

When a container holds more splits than the device needs, `SplitSelector` picks them from the split names (`config.<qualifier>`) and the manifests:

| Split kind | Rule |
|---|---|
| base | always |
| feature splits (`isFeatureSplit`) | all present. On-demand features need Play and are not supported |
| ABI config (`config.arm64_v8a`, `config.armeabi_v7a`, `config.x86_64`, …) | only the guest's ABIs (from the Guest Agent `Hello`, default `arm64-v8a`) |
| density config (`config.xhdpi`, `config.xxhdpi`, …) | the bucket nearest to 320 dpi ([display-and-windowing.md](display-and-windowing.md) §6). If none is at least 320, the highest one |
| language config (`config.ja`, `config.en`, …) | all. The guest follows the macOS language list ([desktop-integration.md](desktop-integration.md) §9) |
| other or unknown config splits | included if they are `configForSplit` of an included split and their qualifier is not an ABI or density |

- Individual `.apk` files that the user drops are not selected. They install as given, after §4.6.
- After selection, `requiredSplitTypes` of the base (API 33+) must be satisfied by the included `splitTypes`. Otherwise: `incompleteSplitSet(missing:)`.
- The density rule is a baseline. Its quality effect is open (OQ-14).

### 4.5 Signature verification on the host

`APKSignatureVerifier` is native Swift in `Sources/APKStoreCore/Signing/`. There is no Java on user Macs.

1. Locate the End of Central Directory (EOCD), the Central Directory (CD), and the APK Signing Block (magic `APK Sig Block 42`).
2. Pick the scheme for the guest SDK: v3.1 (block `0x1b93ad61`) if a signer's SDK range covers it, else v3 (`0xf05368c0`), else v2 (`0x7109871a`). A v3.2 hybrid signature includes a classic signature, which the verifier checks. It verifies an ML-DSA part with CryptoKit where the host OS supports it. Otherwise Android verifies it.
3. Verify the content digests over 1 MiB chunks of the ZIP entries, the CD, and the EOCD (CD offset replaced by the signing block offset). Algorithms: RSASSA-PKCS1-v1_5, RSASSA-PSS, and ECDSA with SHA-256 or SHA-512 (`SecKeyVerifySignature`). Skip the verity digest when another is present.
4. Verify each signer's signature. The certificate's public key must match the one in the signer block.
5. Parse the rotation attribute (v3, v3.1) into a lineage, oldest → newest. Each node is signed by the previous key and carries capability flags `INSTALLED_DATA`, `SHARED_USER_ID`, `PERMISSION`, `ROLLBACK`, `AUTH`.
6. The **signer set** is the SHA-256 of the DER certificate of each signer Android uses. Multiple signers are allowed (v2). Android requires the full set to match on update.

| Case | Host result | Reason |
|---|---|---|
| No v2+ signature, `targetSdk ≥ 30` | reject: `legacySignatureNotAllowed(targetSdk)` | Android 11+ rejects these |
| v1 (JAR) only, `targetSdk < 30` | accept as `.certificateOnly`: read the certificate from `META-INF/*.RSA`, `*.EC`, or `*.DSA`, without checking JAR digests. The preview shows "Legacy signature — verified by Android during install" | Android verifies at install ([guest-protocol.md](guest-protocol.md) §11.3) |
| DSA signer, or an algorithm Security.framework lacks | `.certificateOnly` with a warning | same |
| Invalid digest or signature | reject: `invalidSignature(file, reason)` | never staged, never sent to Android |
| Unsigned APK | reject: `unsignedAPK(file)` | Android refuses unsigned APKs |

**Security position** (NFR-SEC-04). The host check is an early, explainable check. It is not the final authority, and nothing bypasses Android's verification. `PackageManager` verifies every install and enforces signer continuity. The Store Agent re-checks the package, version, and signer before commit. A host bug can cause a false rejection, never an install that Android would refuse.

For a false `invalidSignature` (an APK that Android accepts), the importer asks the Store Agent's `InspectArchive` when the runtime is ready. It uses Android's verdict and logs `verifier.disagreement`. The field rate is open (OQ-15).

### 4.6 Intrinsic checks

`ArtifactVerifier.verify(set, guest: GuestFacts) → VerifiedArtifactSet` runs on every import, first install, and update. UpdateCore adds its relational checks ([update-system.md](update-system.md) §6, [security-model.md](../01-architecture/security-model.md) §5).

| # | Check | Failure |
|---|---|---|
| I1 | Container supported and extraction limits respected (§4.2) | `unsupportedContainer`, `archiveLimitExceeded` |
| I2 | Every file is an APK with a manifest | `notAnAPK(file)` |
| I3 | Exactly one base, unique split names | `missingBase`, `multipleBases`, `duplicateSplit(name)` |
| I4 | Same package and `VersionCode` in every APK | `inconsistentSplits(.package / .versionCode, file)` |
| I5 | Valid signature (§4.5), and the same signer set in every APK | `unsignedAPK`, `invalidSignature`, `legacySignatureNotAllowed`, `inconsistentSplits(.signer, file)` |
| I6 | Required splits present (`requiredSplitTypes`, `isSplitRequired`) | `incompleteSplitSet(missing:)` |
| I7 | No native code, or native code for a guest ABI in the base or the selected ABI split. `arm64-v8a` is the only guest ABI ([scope.md](../00-product/scope.md)) | `unsupportedABI(found:, supported:)` |
| I8 | `minSdkVersion ≤` guest SDK (37 on the baseline image) | `minSdkTooHigh(required:, guest:)` |
| I9 | `targetSdkVersion ≥` the install floor: 23 on API 34, 24 on API 35 and later. APKRun never uses `--bypass-low-target-sdk-block` | `targetSdkTooLow(target:, floor:)` |
| I10 | Not an APKRun agent (`io.apkrun.guest`, `io.apkrun.store`) and not a platform package known to the image | `reservedPackage(id)` |
| I11 | Each file ≤ 2 GiB, total ≤ 8 GiB | `tooLarge(bytes:, limit:)` |
| I12 | `targetSdkVersion ≥ 30`: every `resources.arsc` is stored uncompressed and starts on a 4-byte boundary | `resourcesArscNotAligned(file:)` (Android: `INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED`) |

Warnings do not block. They appear in the preview and `apkrun inspect`: `uses-feature android:required="true"` for hardware the guest lacks, `.certificateOnly`, `debuggable="true"`, and a target SDK far below the guest (for example below 28).

`GuestFacts` (SDK, ABIs, install floor) come from the last Guest Agent `Hello`, saved in `Runtime/instance/instance.json`. Before the first boot, they come from the installed image's manifest ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md)). Install floors can refuse older apps (R-15).

### 4.7 Import results

`beginImport` returns an `ImportPreview`:

```swift
public struct ImportPreview: Codable, Sendable {
    public var ticket: ImportTicket
    public var packageID: PackageID
    public var displayName: String                 // host label in the best macOS language match
    public var versionCode: VersionCode
    public var versionName: String?
    public var icon: HostIconPreview?              // §10.1
    public var files: [ArtifactFile]               // after split selection
    public var excludedSplits: [String]
    public var signer: SignerSummary               // digests, scheme, lineage length, verification level
    public var permissions: [String]
    public var warnings: [ImportWarning]
    public var relation: ImportRelation
    public var compatibility: CompatibilityInfo?   // compatibility database entry (#91, diagnostics.md §10.3); nil = none
}

public enum ImportRelation: Codable, Sendable {
    case newPackage
    case sameAsInstalled                           // same host artifact set as the managed record
    case reinstallSameVersion                      // same versionCode, different files
    case update(from: VersionCode)                 // routed to UpdateCore as a manual update
    case downgrade(from: VersionCode)              // refused: store.downgradeRefused
    case otherSigner                               // refused: store.signerMismatch
    case uninstalledWithData(VersionCode)          // install restores the kept data
}

public enum ImportWarning: Codable, Sendable, Equatable {   // the §4.6 warnings. Exit codes do not change
    case missingHardwareFeature(feature: String)
    case certificateOnlyVerification
    case debuggable
    case lowTargetSDK(target: Int)                 // below 28
}
```

- An import of an installed package goes to UpdateCore as a manual update, with the validation and gentle install of provider updates ([update-system.md](update-system.md) §7). A downgrade fails with `store.downgradeRefused`. A different signer fails with `store.signerMismatch`. Texts: [error-catalog.md](../03-reference/error-catalog.md) §10.2.
- The candidate is compared with Android's live versionCode when Android has the package. Otherwise it is compared with the managed record, for example after a retained-data reinstall. A stale preview cannot authorize a lower version. Normal imports always refuse downgrades. The legacy `allowDowngrade` field is ignored.
- `reinstallSameVersion` installs with mode `REINSTALL` and replaces `current/` in a `reinstall` transaction (§5.2).

---

## 5. Transactions and the journal

Every change to Android or to an artifact slot is a transaction in `Packages/journal.jsonl`. A crash, kill, or power loss at any point leaves a state that `open()` finishes or undoes without user action. The one exception: the result of an Android commit that was in flight is read back from Android after boot.

### 5.1 Journal format

JSON Lines, append-only, one object per line:

```json
{"v":1,"seq":41,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:03.120Z","op":"begin","kind":"update","package":"com.example.app","dir":"com.example.app","from":44,"to":45,"setDigest":"sha256:9f2c…"}
{"v":1,"seq":42,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:03.410Z","op":"step","step":"guestCommitRequested","androidSession":1873}
{"v":1,"seq":46,"txn":"01J9ZQ5K7Y3M","at":"2026-10-02T09:12:09.021Z","op":"commit"}
```

- `txn` is a ULID. `seq` increases by one per line across the file. A gap, or a line that does not parse, ends the readable part (a torn last write). Everything after it is ignored, and `store.journal` reports it.
- Each line is one `write(2)`, then `fcntl(F_BARRIERFSYNC)`. A slot rename is followed by `fsync` of the package directory. `metadata.json` and `settings.json` are written to a temporary file in the same directory, barrier-synced, and renamed over the old file. `F_FULLFSYNC` is not used. After a power loss, the store relies on write ordering.
- Guest steps are journaled **before** the request that changes Android (`…Requested`) and again after the outcome. Host file steps are journaled **after** they are done. Recovery infers half-done file steps from the directories (§5.5).
- Compaction runs at `open()` and after a commit when the file exceeds 1 MiB. The journal is rewritten (temporary file, then rename) with only the lines of unfinished transactions. `seq` continues.

### 5.2 Transaction kinds

| Kind | Started by | Steps, in order | Files |
|---|---|---|---|
| `firstInstall` | user install of a new package | `begin` → `guestCommitRequested` → `guestInstalled` → `filesPromoted` → `metadataWritten` → `commit` | `incoming/<t>` → `current` |
| `reinstall` | same-version reinstall, `needsReinstall` after reset (§9.2), repair | `begin` → `guestCommitRequested` → `guestInstalled` → [`filesPromoted`] → `metadataWritten` → `commit` | none when it reinstalls `current/`. For `reinstallSameVersion`: `incoming/<t>` → `current` (old `current` → `.trash`) |
| `stage` | UpdateCore after validation | `begin` → `filesStaged` → `metadataWritten` → `commit` | old `staged` → `.trash`, `incoming/<t>` → `staged` |
| `update` | UpdateCore in an install window | `begin` → `guestCommitRequested` → `guestInstalled` → `filesPromoted` → `metadataWritten` → `commit` | old `previous` → `.trash`, `current` → `previous`, `staged` → `current` |
| `rollback` | UpdateCore after a failed health check, or the user | `begin` → `guestRollbackRequested` → `guestRolledBack` → `filesRestored` → `metadataWritten` → `commit` | `current` → `failed/<vc>`, `previous` → `current` |
| `uninstall` | user | `begin` → `guestUninstallRequested` → `guestUninstalled` → `filesRemoved` → `metadataWritten` or `recordRemoved` → `commit` | package directory → `.trash`. Keep data: only the slots move |
| `forget` | "Remove from APKRun" for a package that cannot be uninstalled from Android | `begin` → `filesRemoved` → `recordRemoved` → `commit` | package directory → `.trash` |
| `discardStaged` | UpdateCore (candidate withdrawn, authority changed, "Skip this version") | `begin` → `filesRemoved` → `metadataWritten` → `commit` | `staged` → `.trash` |
| `schemaMigration` | `open()` when a record or settings file has an older schema (§5.4) | `begin` → `migrated` (once per package) → `commit` | `metadata.v<old>.json` and `settings.v<old>.json` backups ([package-metadata-json.md](../03-reference/package-metadata-json.md) §5.2) |

Rules:

- **Files mirror Android.** `current/` is promoted as soon as Android confirms the install, before the health check. The directories always describe what Android should have. A rollback is its own transaction. `previous/` stays until the next successful update.
- **Cleanup is best effort.** After `commit` and the in-memory update, failures removing the ticket marker, aborting superseded attempts, or purging trash do not turn a successful install into a failure. The result is marked deferred, and RuntimeHost emits `store.cleanupDeferred`.
- A failure before `guestCommitRequested` ends the transaction with `{"op":"abort","reason":…}`. It undoes nothing on disk. The `incoming/` or `staged/` set stays for a retry.
- `update` promotion uses `renamex_np(RENAME_SWAP)` for `staged ↔ current`. Then the old `current` (now in `staged`) is renamed to `previous`, after the old `previous` moved to `.trash`. Each step is atomic on APFS and recognizable by `setDigest` (§5.5).
- `.trash` is purged in the background. A crash leaves at most garbage, which the next `open()` purges.
- Writes that change only a record or `settings.json` are not transactions: reconciliation (§9.2), `recordHealth`, adopt (§9.3), `setUpdatePolicy`, and `updatePackageSettings`. They take the operation lock (§5.3) and write atomically ([package-metadata-json.md](../03-reference/package-metadata-json.md) §6.2).

### 5.3 Concurrency

- One transaction per package. A second request fails with `operationInProgress(id)`.
- One Android commit at a time, across all packages, in a FIFO with two priorities: user-initiated before background. Host-only steps (`stage`, `forget`, `discardStaged`) skip this queue.
- Guest transactions run inside `StoreRuntimeAccess.withStoreAgent` (§6.1). It makes the runtime `ready` and holds a `storeOperation` assertion for the whole transaction ([runtime-daemon.md](runtime-daemon.md) §5.1). It boots or resumes Android only for user-initiated operations, including user updates. An automatic install runs only while the runtime is `ready` ([update-system.md](update-system.md) §3.1, §7.1 GU1). The one exception is `updates.startRuntimeToInstall` ([update-system.md](update-system.md) §3.5).

### 5.4 Opening the store

`PackageStore.open()` is startup step 6 of apkrund ([runtime-daemon.md](runtime-daemon.md) §2.2). It also runs in embedded mode, without the VM.

1. Read `journal.jsonl` up to the first unreadable line.
2. Load every `metadata.json` and build the index (§3.2). Migrate older record and settings files in one `schemaMigration` transaction. An unfinished one continues here ([package-metadata-json.md](../03-reference/package-metadata-json.md) §5.2).
3. Recover every unfinished transaction in `seq` order (§5.5). Host-only work finishes now. Android work becomes a `PostBootTask`.
4. Compact the journal.
5. Delete orphaned `incoming/<ticket>/` directories, purge `.trash/`, and delete `failed/` sets older than 7 days.
6. Publish the records. A package with pending post-boot work shows `lastOperation.pending = true`, so the UI can say "Finishing install of ‹App›…".

A `metadata.json` or `settings.json` with a newer `schemaVersion` makes only that package read-only (`metadataUnreadable`). If the package ID is known, the package stays visible as broken. Import, install, uninstall, and forget for it fail with `store.metadataUnreadable`. The file is never written. Healthy packages remain available. A journal with a newer `v` makes the whole store read-only, and the startup step reports it as degraded ([runtime-daemon.md](runtime-daemon.md) §2.2).

### 5.5 Recovery rules

For each unfinished transaction, the last journaled step decides the action.

| Kind | Last step | Recovery |
|---|---|---|
| any | `begin` only | abort. Guest kinds have not moved files yet. For host kinds, check the target slot's `setDigest`: if the move happened, roll forward. Exception: a `forget` begin with `reason=resolvesUnverifiedUninstall` always rolls forward |
| `forget` with `reason=resolvesUnverifiedUninstall` | any step | abort matching pending uninstall requests with reason `userChoseForgetWithUnverifiedUninstallOutcome`. Then finish moving the directory, remove the record, and commit. The begin is written before the requests are resolved, so recovery completes after a crash at either point |
| `firstInstall`, `reinstall`, `update` | `guestCommitRequested` | **post-boot.** Read the installed version (`GetPackageMetadata`, or `QueryPackage` on stock images). If it equals the target versionCode (and, for `reinstall`, `lastUpdateTime` is after `begin`), continue as if `guestInstalled`. Otherwise abort. Keep `staged/` for a retry, delete a first install's `incoming/` set, and tell the user "Installing ‹App› was interrupted" with Retry |
| `firstInstall`, `reinstall`, `update` | `guestInstalled` | roll forward now: promote files (idempotent), write metadata, commit. Android facts are refreshed after boot |
| `update` | `filesPromoted`, or partway | finish the renames. The set with digest `to` belongs in `current/`, the set with digest `from` in `previous/`. Any other set in these slots goes to `.trash` |
| `rollback` | `guestRollbackRequested` | **post-boot.** If the `from` version is still installed, abort and report "Rollback of ‹App› did not happen". The package stays in the failed-update state ([update-system.md](update-system.md) §8). If the previous version is installed, continue |
| `rollback` (confirmed data-loss fallback, §7.3) | `guestUninstallRequested` or later, before `guestRolledBack` | **post-boot.** If the package is absent, continue with the first install of `previous/`, because the user confirmed the data loss. If the `from` version is still installed, abort |
| `uninstall` | `guestUninstallRequested` | **post-boot.** Still installed: abort, and the package is `installed` again. Absent: keep the transaction pending, because PackageManager absence cannot establish the requested data outcome. Continue with other transactions, and allow Android inventory inspection |
| `uninstall` | `guestUninstalled` | roll forward host cleanup: finish `filesRemoved`, write `metadataWritten` when keeping data or `recordRemoved` otherwise, then commit. Do not send another uninstall request |
| `uninstall`, `forget`, `discardStaged` | a file step | roll forward |
| `stage` | `begin` | if `staged/` has the new digest, roll forward. Else abort and delete the `incoming/` set |

If the `guestCommitRequested` check fails for `reinstallSameVersion`, keep its `incoming/<ticket>/` so the same APK set can be retried. A failed `firstInstall` deletes its incoming set. An `update` keeps `staged/` for a retry.

`PostBootTask`s run in step 5 of readiness ([runtime-daemon.md](runtime-daemon.md) §3.4). Each is one query and never holds `ready` for more than the 5 s budget. The rest run after `ready` under a `storeOperation` assertion. If Android cannot answer, the task is re-queued for the next boot, and the package stays `pending`.

---

## 6. Installing into Android

### 6.1 Channel abstraction

```swift
public protocol StoreAgentChannel: Sendable {
    var capabilities: StoreCapabilities { get }      // .install, .metadata, .inspect, .icons, .updateOwnership, .rollback, .downgradeReinstall

    func inspect(_ files: [StagedFile]) async throws -> GuestArchiveInfo
    func install(_ request: StoreInstallRequest, files: [StagedFile],
                 beforeCommit: @Sendable () async throws -> Void,
                 progress: @Sendable (StoreInstallProgress) -> Void) async throws -> StoreInstallResult
    func uninstall(_ package: PackageID, keepData: Bool) async throws
    func rollback(_ package: PackageID, from: VersionCode, to: VersionCode) async throws -> StoreRollbackResult
    func relinquishUpdateOwnership(_ package: PackageID) async throws
    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo?     // nil = not installed
    func listPackages(_ filter: StorePackageFilter) async throws -> [StorePackageInfo]
    func renderIcon(_ package: PackageID, sizePx: Int) async throws -> RenderedIcon
    nonisolated var packageEvents: AsyncStream<StorePackageEvent> { get }       // PackageChanged
}

/// Injected by RuntimeHost. Hides RuntimeCore from APKStoreCore.
public protocol StoreRuntimeAccess: Sendable {
    /// Ensures the runtime is ready (boots it if needed), holds a storeOperation assertion,
    /// and hands over the channel for the current image.
    func withStoreAgent<T: Sendable>(_ reason: StoreOperationReason, operation: OperationID,
                                     _ body: @Sendable (any StoreAgentChannel) async throws -> T) async throws -> T
    func guestFacts() async -> GuestFacts?             // SDK, ABIs, install floor, userdataGeneration
    func hasOpenSession(_ package: PackageID) async -> Bool   // any AppSession except ended (§7.2)
    func endSessions(for package: PackageID, reason: SessionEndReason) async
}
```

| Implementation | Image | Transport | Missing capabilities |
|---|---|---|---|
| `ADBStoreAgentChannel` | stock image, and custom images with `--guest-transport adb` for debugging | `adb install-multiple`, `pm uninstall`, Guest Agent `QueryPackage` and `ListPackages` ([guest-protocol.md](guest-protocol.md) §13.2) | `.updateOwnership`, `.icons`, `.rollback`, `.inspect`. It has `.downgradeReinstall` when `ro.debuggable=1` |
| `StoreAgentSupervisor` | custom image | RuntimeCore's `GuestStoreAgentClient` owns the Store Agent wire protocol over vsock 6110 and 6111; RuntimeHost adapts it to `StoreAgentChannel` ([guest-protocol.md](guest-protocol.md) §11) | none, once the agent announces every capability. The store uses only what `Hello` announces ([guest-protocol.md](guest-protocol.md) §3). `.downgradeReinstall` is never offered (`allow_downgrade` is always false in v1) |

RuntimeCore owns GuestProtocol framing and Store Agent connections. RuntimeHost's `StoreAgentSupervisor` adapts that client to APKStoreCore's `StoreAgentChannel`; APKStoreCore owns package records, reconciliation, and the rest of the store policy.

- `.updateOwnership`, `.rollback`, and `.icons` arrive with #40, #44, and #56.
- RuntimeHost provides `DevelopmentStoreRuntimeAccess` for the embedded runtime.
- A CI lint rejects raw `adb shell` and `pm` package operations outside `ADBStoreAgentChannel`, RuntimeCore's `AdbClient` helpers, and the allowlist of [test-strategy.md](../04-plan/test-strategy.md) §3.3.
- Missing capabilities are not errors. The store records what it could not do (for example `android.updateOwner = nil` and a health note on a stock image) and continues.

### 6.2 First install flow

```text
install(ticket, options)
  1. re-check the ticket: preview still valid (files unchanged: sizes and digests), no record, or record in uninstalledKeepingData
  2. journal begin(firstInstall)                       state: inspecting → installing
  3. withStoreAgent(.install):                         boots Android if needed; OperationHandle shows "Starting Android…"
     a. BeginInstall(InstallRequest{ expected_package, expected_version_code, expected_signer_sha256,
                                     mode: INSTALL_NEW, request_update_ownership: §6.3,
                                     enable_rollback: false, artifacts, install_reason: USER,
                                     package_source: OTHER })
     b. stream every file on the artifact stream (progress: RECEIVING)
     c. journal step guestCommitRequested; enter the non-cancellable phase
     d. CommitInstall → Android verifies the staged APKs, then wait for InstallFinished
        (progress: VERIFYING, COMMITTING)
  4. SUCCESS → journal step guestInstalled(versionCode)
  5. rename incoming/<ticket> → current                journal step filesPromoted
  6. GetPackageMetadata → write metadata.json           journal step metadataWritten, commit
                                                        state: installing → installed
  7. RenderIcon (1024 px) → icon/  (non-fatal, retried on the next boot if it fails)
  8. emit PackageChange.installed; optional WrapperCore.generate (the "Create Mac app" choice)
```

- `ADBStoreAgentChannel` does step 3 as `adb install-multiple -r --no-streaming <files>`, after the host verified the digests. Steps 4–6 use `QueryPackage`.
- Timeouts: `BeginInstall` 30 s. Artifact streaming has a 30 s stall timeout and no total timeout. `InstallFinished` 10 min. `GetPackageMetadata` 10 s. A timeout after `guestCommitRequested` is handled like a crash: the outcome is read back from Android (§5.5).
- On a custom image, cancel is allowed until step 3c, after artifact streaming and immediately before the host sends `CommitInstall`; cancellation sends `AbandonInstall`. Android's archive inspection runs inside that request. On the ADB channel, the boundary is immediately before `adb install-multiple`. After the boundary, cancel is refused ("Android is finishing the install").
- A failed first install ends with `abort`, deletes the ticket, and removes the record if it was created.

### 6.3 Update ownership at install

`request_update_ownership = record.updateAuthority.claimsUpdateOwnership && channel.capabilities.contains(.updateOwnership)`

| Authority | `claimsUpdateOwnership` | Reason |
|---|---|---|
| `apkrun` | true | Other installers may not update the package silently |
| `manual` | true | APKRun is still the only installer. It installs only files the user supplies |
| `googlePlay` | false | Never compete with Play for ownership |
| `external` | false | Another installer owns updates |

- The default authority of a file import is `manual`. It becomes `apkrun` when a provider is attached, in the Add sheet or later in settings ([update-system.md](update-system.md) §2).
- Authority changes go through `PackageStore.setUpdateAuthority(id, authority, provider:)` under the operation lock (§5.3). Callers are UpdateCore's `setUpdatePolicy` and `setUpdateAuthority` ([update-system.md](update-system.md) §2.1, §11.1), and adopt (§9.3).
- Moving to `googlePlay` or `external` calls `RelinquishUpdateOwnership` (Store Agent op 109, `PackageManager.relinquishUpdateOwnership`, API 34) first, then writes the record. If the runtime is not `ready`, the call becomes a post-boot task, because an authority change never starts Android. `FAILED_PRECONDITION` (APKRun is not the owner) is not an error.
- A crash between the call and the write leaves the old authority with no owner. The next reconcile reports `store.ownership`, and the next install requests ownership again. Moving to `apkrun` or `manual` requests ownership on the next install.
- Whether `setRequestUpdateOwnership(true)` grants ownership on an update of a package that has no owner is open (OQ-12).
- After every install, `android.updateOwner` is read from `GetPackageMetadata`. For `apkrun` and `manual` packages whose owner is not `io.apkrun.store`, health reports `store.ownership` as a warning. This happens on stock images and when the image's enforcement flag is off ([guest-components.md](guest-components.md) §8.2).

### 6.4 Install result mapping

Texts for each row are in [error-catalog.md](../03-reference/error-catalog.md) §10.3.

| `InstallFinished.status` | Typical `legacy_status` | `StoreFailure` |
|---|---|---|
| `SUCCESS` | — | — |
| `CONFLICT` | `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, `INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`, `INSTALL_FAILED_DUPLICATE_PERMISSION` | `guestInstallFailed(.conflict, …)` |
| `INCOMPATIBLE` | `INSTALL_FAILED_NO_MATCHING_ABIS`, `INSTALL_FAILED_OLDER_SDK`, `INSTALL_FAILED_DEPRECATED_SDK_VERSION`, `INSTALL_FAILED_MISSING_SPLIT` | `guestInstallFailed(.incompatible, …)`. The host checks should have caught this. Each occurrence logs `store.hostCheckMissed` |
| `INVALID` | `INSTALL_PARSE_FAILED_*`, agent pre-commit mismatch | `guestInstallFailed(.invalid, …)` |
| `STORAGE` | `INSTALL_FAILED_INSUFFICIENT_STORAGE` | `guestStorageFull` |
| `BLOCKED` | policy, system package | `guestInstallFailed(.blocked, …)` |
| `ABORTED` | session abandoned (timeout, disconnect) | `guestInstallFailed(.aborted, …)` |
| `USER_ACTION_REQUIRED` | `STATUS_PENDING_USER_ACTION` | `userActionRequired`. Not expected for a privileged installer. Logged as a bug |
| `FAILURE` | anything else | `guestInstallFailed(.other, …)`. The Android message goes to "Details" |

---

## 7. Updates and rollback: store mechanics

UpdateCore decides when to stage, install, health-check, and roll back ([update-system.md](update-system.md) §3–§8). The store provides these operations.

### 7.1 Stage

`stage(ticket, candidate: StagedUpdateInfo) async throws`. The ticket's set has passed §4.6 and UpdateCore's relational checks. It runs the `stage` transaction (§5.2) and records `artifacts.staged` with the candidate's source (provider, release URL, declared hash).

### 7.2 Install a staged update

`installStaged(id, enableRollback: Bool) async throws -> StoreInstallResult` runs the `update` transaction:

- `InstallRequest.mode = UPDATE`, `expected_version_code = staged.versionCode`, `expected_signer_sha256 = staged.signerDigests`. `request_update_ownership` follows §6.3.
- `enable_rollback = enableRollback && channel.capabilities.contains(.rollback)`. UpdateCore passes `true` for every health-checked update. The Store Agent then calls `SessionParams.setEnableRollback(true, ROLLBACK_DATA_POLICY_RETAIN)` ([guest-components.md](guest-components.md) §8.2).
- The caller must have ended the package's sessions, or verified that none exists (gentle update, [update-system.md](update-system.md) §7). The store checks again with `StoreRuntimeAccess.hasOpenSession`. If a session exists, it fails with `packageInUse(id)` before `BeginInstall`.
- After promotion, `previous/` holds the old set and `current/` the new one. `record.lastOperation` is `update(from:to:, healthPending: true)` until UpdateCore records the result with `recordHealth(id, result)`.

### 7.3 Rollback

`rollback(id, reason) async throws` runs the `rollback` transaction. It needs `previous/`. Without it, it fails with `rollbackUnavailable(.noPreviousSet)`.

Android refuses a plain downgrade from a privileged installer on `user` builds. Only the system uid and debuggable builds may use `INSTALL_ALLOW_DOWNGRADE`. So the mechanism depends on the image:

| Image | Mechanism | App data | Capability |
|---|---|---|---|
| Custom image (`user` and `userdebug`) | **Android RollbackManager.** The update was installed with `enable_rollback`. `RollbackPackage` (op 108) finds the rollback whose `from` and `to` versions match, and calls `RollbackManager.commitRollback`. The Store Agent holds `MANAGE_ROLLBACKS` and `TEST_MANAGE_ROLLBACKS` ([guest-components.md](guest-components.md) §8.1) | kept as it is now (`ROLLBACK_DATA_POLICY_RETAIN`). Data changes made by the new version are **not** reverted | `.rollback` |
| Stock `userdebug` image (development) | `adb install-multiple -r -d` with the files from `previous/`. Downgrade is allowed on debuggable builds | kept as it is now | `.downgradeReinstall` |
| Rollback not available (installed without `enable_rollback`, expired after about 14 days, or dropped by Android) | **Only with explicit user confirmation:** "Restoring ‹App› ‹old version› requires deleting its data. Continue?" Then uninstall, and install `previous/` as a first install | **deleted** | — |

- A background rollback never uses the data-loss fallback. The package stays on the new version. `lastOperation` records `rollbackUnavailable`. The user gets a notification with "Keep ‹new version›" and "Restore ‹old version› (erases app data)" ([update-system.md](update-system.md) §8.3).
- After a successful rollback, the failed set moves to `failed/<versionCode>/`. UpdateCore marks that version skipped, so it is not staged again automatically.
- Data rollback is not in v1. `ROLLBACK_DATA_POLICY_RESTORE` would enable it on custom images (OQ-16). The UI and documentation state that app data is not rolled back.
- The RollbackManager path needs `TEST_MANAGE_ROLLBACKS`. Android allows rollbacks of arbitrary packages only to installers with that permission. It also allows allowlisted packages with `MANAGE_ROLLBACKS`, and the allowlist is fixed in the system image. Using this permission in production is a deliberate choice. Whether it works on `user` builds is open (OQ-11, R-18).

---

## 8. Uninstall, keep data, forget

The Uninstall dialog and `apkrun uninstall` offer two choices (FR-PKG-07):

- **Keep app data** (default off). Android uninstalls with `DELETE_KEEP_DATA`. Reinstalling the same package, signed by the same developer, restores the data. APKRun keeps `metadata.json` (state `uninstalledKeepingData`) and `settings.json`, and deletes the artifact slots.
- **Move the Mac app to the Trash** (default on when a wrapper exists). WrapperCore does it after the store transaction commits ([wrapper.md](wrapper.md) §9).

```text
uninstall(id, options)
  1. journal begin(uninstall); state → uninstalling
  2. withStoreAgent(.uninstall):
     a. endSessions(id, .packageUninstalled)       wrappers close their windows
     b. journal step guestUninstallRequested
     c. Uninstall(package, keep_data)            → UninstallResult
  3. journal step guestUninstalled
  4. slots (or the whole directory) → .trash    journal step filesRemoved
  5. keep data: write metadata (uninstalledKeepingData), else remove the record   journal step, commit
  6. emit PackageChange.removed(keptData:)
```

- `Uninstall` answers `NOT_FOUND` when Android no longer has the package. The store treats that as success.
- On the stock ADB channel, a failed uninstall followed by `QueryPackage == absent` does not show whether Android kept or deleted app data. Abort the host transaction, keep the record, and report `store.uninstallDataUnverified` for either requested outcome.
- If the host crashes after the uninstall request but before `guestUninstalled`, the same ambiguity holds when the package is absent at recovery. The request stays pending, and the record and slots stay. Recovery continues, so `apkrun list --all` can inspect the PackageManager inventory.
- `apkrun uninstall <package> --forget` discards APKRun's record and APKs after inspection. It writes a durable forget intent before it closes a pending ambiguous uninstall, with an abort reason that records the user's host-side choice. After a crash, the next store open finishes the forget. It never claims or changes whether Android kept the app data.
- If the runtime cannot start (not provisioned, or in a boot loop), the dialog offers **Remove from APKRun**, which runs `forget`. The package may stay in Android and shows as unmanaged after the next successful boot.
- Records in `uninstalledKeepingData` appear under "Apps with kept data" in Settings → Storage, with **Reinstall…** (the APK must match the recorded signer) and **Delete data** (`Uninstall` without `keep_data` for the leftover data, then `forget`).

---

## 9. Reconciling with Android

Android is canonical for package metadata (FR-PKG-02). The host record is canonical for what APKRun manages and for the artifacts.

### 9.1 When

- After every Store Agent handshake (the Guest Agent on stock images): `ListManagedPackages(ALL_USER_INSTALLED)` or `ListPackages(USER_INSTALLED)`, after the post-boot tasks of §5.5.
- On every `PackageChanged` event: `GetPackageMetadata` for that package, then refresh the full Android inventory so unmanaged installs and removals are reflected in `android-inventory.json`.
- On `apkrun doctor` and on Repair.

### 9.2 Rules

`instance.json` holds `userdataGeneration`, a UUID. ImageCore creates it whenever `userdata.img` is provisioned (first run or Reset Android) or restored from a recovery point ([android-image.md](android-image.md) §5). Each record stores the generation it was installed into (`android.userdataGeneration`).

| Host record | Android reports | Action |
|---|---|---|
| installed, same generation, same version | present | refresh `displayName`, `versionName`, `signingCertificates`, `updateOwner`, times, SDKs, ABIs. If `lastUpdateTime` changed or is unavailable, set `artifacts.currentMatchesAndroid = false`; PackageManager metadata cannot prove the installed APK bytes equal `current/` |
| installed, **different generation** | absent | state → `needsReinstall(.userdataReset)`, or `needsReinstall(.userdataRestored)` after a recovery point restore. A `reinstall` of `current/` runs after `ready` under a `storeOperation` assertion ([runtime-daemon.md](runtime-daemon.md) §9.5). App data is gone. Wrappers stay valid |
| installed, different generation | present, lower version (restored recovery point) | reinstall `current/` as an `UPDATE` (data kept), then refresh |
| installed, same generation | absent | removed inside Android. State → `broken(.removedInAndroid)`. Actions: **Reinstall** or **Remove from APKRun** |
| installed | present, higher version | updated by someone else. Possible only without ownership enforcement, or with authority `googlePlay` or `external`. Take Android's version. `artifacts.currentMatchesAndroid = false`. For `apkrun` and `manual`, health warns `store.externallyUpdated`. The next APKRun update restores the match |
| installed | present, different signer set | `broken(.signerChanged)`. Possible only through an external uninstall and reinstall. Repair offers **Reinstall APKRun's copy (erases data)** or **Adopt Android's version** (authority `external`) |
| installed; `current/` missing, or file sizes differ from `artifact.json` (checked at `open()`; digests checked before every reinstall) | any | `broken(.artifactMissing)`. The app keeps working while Android has it. Repair asks for the APK again (same package, versionCode, and signer) |
| `uninstalledKeepingData` | absent or data-only | nothing |
| no record | present, user-installed | unmanaged, under "Other Android apps" (§9.3) |
| pending transaction | any | its recovery (§5.5) runs first |

Reinstalls that reconciliation triggers queue in the one-at-a-time Android queue (§5.3) at background priority, with progress "Restoring apps (3 of 12)…".

### 9.3 Unmanaged packages and adoption

- Packages installed by `adb install` (developer mode) have no record. `listPackages(.all)` returns them with `managed = false`.
- A live `listPackages(.all)` refreshes `android-inventory.json`. While Android is stopped, the operation returns the saved inventory with the managed records. That result is last-known state until a live query replaces it.
- A managed record still `installed` but absent from the full inventory is reported as `broken(.removedInAndroid)`. This is a read-only projection. `source` and `observedAt` show whether the evidence is live or a snapshot.
- **Adopt** (Home → Other Android apps → "Manage with APKRun", or creating a wrapper for such a package) creates a record with `installer: external`, `updateAuthority: external`, no artifact, and `source: adopted`. APKRun never updates the package. After Reset Android, its record becomes `broken(.removedInAndroid)` with the Remove action, because APKRun has no copy. The adopt sheet says so.
- Post-v1 Google Play support (#98) uses the same record shape, with `updateAuthority: googlePlay`.

---

## 10. Icons and labels

### 10.1 Host preview (no VM)

- The label is the aapt2 label in the best match of the macOS preferred languages, falling back to the default label.
- The icon is the best density bitmap, decoded with ImageIO if it is PNG or WebP. An adaptive icon with bitmap or color layers is composed on a 108 dp canvas (72 dp inner area shown). A vector layer shows a generic placeholder until the guest renders the icon. The host does not interpret VectorDrawables.

### 10.2 Rendered icons (after install)

- `RenderIcon(package, 1536)` ([guest-protocol.md](guest-protocol.md) §11.1) returns the adaptive layers (foreground, background, monochrome) or a legacy bitmap. The store writes them to `icon/` with `icon.json {kind, sizePx, renderedForVersionCode, setDigest}`.
- Icons are rendered after the first install and after every update or rollback. When the result differs, the store emits `PackageChange.iconChanged`. WrapperCore decides what to do with an existing wrapper ([wrapper.md](wrapper.md) §8). Wrappers are never modified automatically (FR-WRP-04).
- `ADBStoreAgentChannel` has no icon rendering. Stock images use the host preview.

### 10.3 Display name

`displayName` is Android's label in the guest locale, which follows macOS (refreshed as in §9.2). The host preview label is used only before the first install, and for unmanaged packages on stock images.

---

## 11. Runtime API surface

The XPC operations and DTOs are in [runtime-api.md](../03-reference/runtime-api.md). Their store semantics:

### 11.1 Operations

| Operation | Behavior | Long operation |
|---|---|---|
| `importPackage(files: [FileHandle], options)` | copy, extract, inspect, check → `ImportPreview` (§4.7) | yes |
| `installImported(ticket, InstallOptions{authority, provider, updateChoice, createWrapper})` | §6.2, or hands the ticket to UpdateCore when `relation == .update`. `updateChoice` (`.automatic` or `.notifyOnly`, from `apkrun install --updates`) is the first update choice of an `apkrun` package ([update-system.md](update-system.md) §2.3) | yes |
| `cancelImport(ticket)` | deletes the ticket | no |
| `inspectFile(files)` | as `importPackage`, then deletes the ticket. For `apkrun inspect` | yes |
| `listPackages(filter: .managed / .all)` | records, plus unmanaged packages from the last inventory. A live runtime refreshes the inventory. A stopped runtime uses the saved facts | no |
| `packageInfo(id)` | `PackageDetails`: record, settings summary, slots, sizes, wrapper count (WrapperCore), last operation | no |
| `uninstallPackage(id, UninstallOptions{keepData, trashWrappers, forget})` | §8 | yes |
| `repairPackage(id)` | `broken` → `reinstall` of `current/`, or `forget` if the user chose it | yes |
| `rollbackPackage(id, allowDataLoss)` | user rollback to `previous/` (§7.3). With `allowDataLoss = false`, a rollback needing the data-loss fallback fails with `rollbackUnavailable`. The client repeats the call with `true` after the user confirms | yes |
| `adoptPackage(id)` | §9.3 | no |
| `updatePackageSettings(id, patch)` | validated JSON merge patch on `PackageSettings` | no |
| `packageIcon(id, sizePx)` | PNG composed from `icon/`, or the host preview | no |

`launch()` and `terminate()` are session operations ([runtime-daemon.md](runtime-daemon.md) §7).

### 11.2 Authorization

Store operations are on the `.control` endpoint only. Control clients (APKRun.app, the menu bar app, the CLI) may import and install. The generic launcher and wrappers may not. A wrapper endpoint gets `packageInfo` and `packageIcon` for its own package and nothing else (NFR-SEC-07, [process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2).

### 11.3 Events

Topic `packages` on the event stream ([runtime-daemon.md](runtime-daemon.md) §8.4). On the wire, `PackageState` is sent as `WirePackageState`. `StoreOperationProgress` is defined in [runtime-api.md](../03-reference/runtime-api.md) §16.2.

```swift
public enum PackageChange: Codable, Sendable {
    case installed(PackageSummary)
    case updated(PackageSummary, from: VersionCode)      // also a same-version reinstall (from == to)
    case rolledBack(PackageSummary, from: VersionCode)
    case removed(PackageID, keptData: Bool)
    case stateChanged(PackageID, PackageState)
    case operationProgress(PackageID, OperationID, StoreOperationProgress)   // coalesced to 10 Hz
    case iconChanged(PackageID)
    case settingsChanged(PackageID, keys: [String])
    case unmanagedChanged([PackageSummary])
}
```

### 11.4 CLI

The full syntax is in [cli.md](cli.md). The store commands:

```text
apkrun install <file>… [--yes] [--provider <spec>] [--updates automatic|notify|manual] [--wrap [--output <dir>]]
apkrun uninstall <package> [--keep-data] [--keep-wrapper] [--forget] [--yes]
apkrun list [--all] [--json]
apkrun info <package> [--json]
apkrun inspect <file>… [--json]            # no VM, no install
apkrun repair <package>
apkrun rollback <package> [--allow-data-loss] [--yes]
apkrun adopt <package>
```

`--yes` skips the confirmation of `inspecting → installing` ([state-machines.md](../01-architecture/state-machines.md) §5). Without it, the CLI prints the preview and asks.

---

## 12. Errors

`StoreFailure` is the error domain of APKStoreCore. Codes, user messages, and remediations are in [error-catalog.md](../03-reference/error-catalog.md) §10.

```swift
public enum StoreFailure: APKRunError {
    // import and inspection (§4)
    case unsupportedContainer(ContainerKind)          // .appBundle, .encryptedAPKM, .unknown
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
    case uninstallDataUnverified(PackageID)
    case operationInProgress(PackageID)
    case packageInUse(PackageID)
    case guestInstallFailed(InstallFailureKind, androidStatus: Int32, legacyStatus: String?, message: String)
    case guestStorageFull
    case userActionRequired
    case uninstallFailed(detail: String)
    case rollbackUnavailable(RollbackUnavailableReason)   // .noPreviousSet, .notEnabled, .expired, .capabilityMissing
    case rollbackFailed(detail: String)
    case runtimeUnavailable(RuntimeFailure)
    case capabilityMissing(String)
    // package settings (configuration.md §8.1)
    case unknownSetting(key: String)
    case invalidSettingValue(key: String, allowed: String)   // wrong type, or outside the allowed values
    // store integrity
    case journalUnreadable(line: Int)
    case metadataUnreadable(PackageID, detail: String)
    case storeReadOnly(reason: String)
    // health findings (§13), never thrown
    case journalLineDropped                           // store.journal: a torn last line was dropped
    case postBootTaskRequeued                         // store.pending: a post-boot task was re-queued twice
    case updateOwnerMissing(count: Int)               // store.ownership
    case updatedOutsideAPKRun(count: Int)             // store.externallyUpdated
    case reinstallPending(count: Int)                 // store.packages: in needsReinstall for more than one boot
    case packagesNeedRepair(count: Int)               // store.packages: broken
}

public enum ArchiveLimit: String, Sendable, Codable {        // the extraction limits of §4.2
    case entryCount, apkCount, fileSize, totalSize, compressionRatio, unsafeName
}

public enum InconsistentField: String, Sendable, Codable {   // I4, I5 (§4.6)
    case package, versionCode, signer
}

public enum InstallFailureKind: String, Sendable, Codable {  // InstallFinished.status (§6.4)
    case conflict, incompatible, invalid, blocked, aborted, other
}
```

Messages never include file paths from the user's disk at `info` level or above. They include the package ID and the file's name inside the set, such as `split_config.arm64_v8a.apk`.

---

## 13. Logging, markers, health

- `os_log` subsystem `io.apkrun.store`; categories `import`, `transaction`, `channel`, `reconcile`. Log transaction begins, steps, commits, and aborts with `txn`, package ID, versionCodes, and set digests. Log channel calls with durations and Android statuses. Never log paths outside `Packages/`, the permission list, or labels at `info` and above.
- Perf markers ([diagnostics.md](diagnostics.md) §4): `PACKAGE_IMPORT_START`, `PACKAGE_INSPECTED`, `PACKAGE_INSTALL_START`, `PACKAGE_INSTALL_COMPLETE`, `PACKAGE_ROLLBACK_COMPLETE`.
- Metrics (`apkrun doctor --deep` and diagnostics bundles): inspection time per MiB, install throughput (MiB/s over `RECEIVING`), time in `COMMITTING`, verifier disagreements.

| Health check | Warning | Error |
|---|---|---|
| `store.journal` | a torn last line was dropped (`store.journalLineDropped`) | journal unreadable: store read-only (`store.journalUnreadable`) |
| `store.packages` | a package in `needsReinstall` for more than one boot (`store.reinstallPending`) | any package `broken` (`store.packagesNeedRepair`) |
| `store.ownership` | an `apkrun` or `manual` package whose update owner is not `io.apkrun.store` (on a custom image, `store.updateOwnerMissing`) | — |
| `store.externallyUpdated` | an `apkrun` or `manual` package updated by another installer (`store.updatedOutsideAPKRun`) | — |
| `store.hostSpace` | free space below 5 GiB (`diagnostics.lowDiskSpace`) | below 2 GiB: imports and staging refused (`store.insufficientHostSpace`) |
| `store.pending` | a post-boot task re-queued twice (`store.postBootTaskRequeued`) | — |

---

## 14. Security notes

- APKs, containers, and their metadata are untrusted input (NFR-SEC-01). The parsers that see them are the ZIP reader, aapt2 (in a sandboxed subprocess), and the signature verifier. All three are fuzz targets (#92).
- The host never executes, loads, or `dlopen`s anything from an APK.
- Package IDs from APKs and from the guest are validated against the grammar (§2.1) before they reach a path, a bundle ID, or a log line.
- Artifacts reach the guest only on the Store Agent artifact stream or through `adb install-multiple`. They are never placed in the shared folder.
- The store never offers "install anyway" for a failed signature, ABI, or SDK check. The only way around a check is a different APK. No build flag disables a check ([AGENTS.md](../../AGENTS.md) §4, invariant 10).

---

## 16. Tests

- **T0**, `Packages/APKStoreCore/Tests/APKStoreCoreTests/`: `PackageID` grammar; `VersionCode`; set digest stability; journal encode, decode, torn line, `seq` gap, compaction, newer `v`; recovery (§5.5) for every kind and step with a scripted fake channel; containers (refusals, zip bomb, `../` and symlink entries, 600 entries, ZIP64 made at test time); split selection; signature verifier (apksig vectors); intrinsic checks I1–I12 with one fixture per failure; relation classification (§4.7); aapt2 golden outputs; the corrupted V2 (one flipped byte in `classes.dex`) fails with `invalidSignature`.
- **T1**, `Tests/IntegrationTests/StoreTests/`: `PackageStore` with a fake channel (install, update, rollback, uninstall with and without keep data, forget, `operationInProgress`, queue priorities); crash injection with `APKRUN_STORE_FAULT=<kind>:<step>` at every host step (a debug-build hook that crashes the process after that step); source deleted after `beginImport`.
- **T2**, `Tests/IntegrationTests/StoreTests/`, needs a VM: stock image through ADB (install, split install, uninstall, reinstall, downgrade `-d`); custom image through the Store Agent (install without ADB, ownership with the OtherInstaller fixture, update with data kept, broken-update rollback through RollbackManager, keep-data uninstall and restore, icons); kill apkrund during `CommitInstall` on both sides of the commit; Reset Android followed by automatic reinstall. Android's own refusal: `AdbClient.install(apk:)` of a V2 signed with another key, installed over V1, fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. The OtherInstaller fixture (`io.apkrun.fixture.otherinstaller`, `REQUEST_INSTALL_PACKAGES`) cannot update an APKRun-owned package without user action: its session ends with `STATUS_PENDING_USER_ACTION`, and the version stays unchanged.
- **T3**, nightly: the 50-APK F-Droid corpus (inspect, install, launch smoke). Signer digests equal those of `apksigner verify --print-certs -v` (`scripts/dev/verify-corpus.sh`).

Fixtures are in `Tests/Fixtures/AndroidApps/`, listed in [test-strategy.md](../04-plan/test-strategy.md) §4. Store tests use HelloText, HelloUpdate V1, V2, V2-other-signer, V3-broken, and V4, the corrupted V2, the rotation variants, HelloSplit, HelloNative (arm64 and 32-bit-only), HelloLegacySig (v1 only, targetSdk 29), and OtherInstaller. They are signed with the test keys in `Tests/Fixtures/signing/`.

---

## 17. Open items

- RollbackManager with `TEST_MANAGE_ROLLBACKS` on `user` builds (OQ-11, R-18, §7.3).
- Whether `setRequestUpdateOwnership(true)` grants ownership on an update of a package that has no owner (OQ-12, §6.3).
- Density split choice for `.apks` sets (OQ-14, §4.4).
- OBB expansion files for `.xapk` (OQ-13, §4.2). v1.x candidate: push through the Store Agent into `Android/obb/<pkg>/`.
- Host verifier false rejections in the field (OQ-15, `verifier.disagreement`, §4.5).
- Data rollback with `ROLLBACK_DATA_POLICY_RESTORE` (OQ-16, §7.3).
- Share of corpus apps that the install floors refuse (R-15, §4.6).
